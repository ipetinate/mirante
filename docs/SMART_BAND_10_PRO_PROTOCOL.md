# Xiaomi Smart Band 10 Pro — BLE connection and watchface install

This document records the hardware-verified Mirante path for the Xiaomi Smart
Band 10 Pro. Treat the details below as protocol requirements, not cleanup
opportunities. A physical install succeeded with Mirante **0.1.1 (Build 8)** on
2026-10-16. The watch was identified as `Xiaomi Smart Band 10 Pro D59F`, with a
336 × 480 screen. The user confirmed that the face transferred and worked.

This is reverse-engineered behavior verified against that device. It is not an
official Xiaomi protocol specification, and firmware variants may differ.

## Pairing and auth-key prerequisites

- The band must remain paired in Mi Fitness. Do not unpair it as a troubleshooting
  step: that can invalidate the stored auth key and force a new pairing.
- Mirante needs the band's 16-byte authentication secret, represented as exactly
  32 hexadecimal characters. The key is stored in the iOS Keychain.
- On iOS, Mirante cannot read Mi Fitness's private app container. Import the
  Mi Fitness registration data exported from an iPhone backup: the
  `VirtualDevice_registerList/registerList_<region>` keyed archive, or the
  `manifest.sqlite` that contains it in `manifest.inline_data`.
- Select the record that matches the band. `encryptKey` (or `encrypt_key`) is
  the preferred field; `authKey` and `auth_key` are accepted aliases. Do not use
  `beaconKey`, `irq_key`, IRK, MAC, or another 32-hex value: those are different
  secrets and cannot authenticate the watchface session.
- Grant Bluetooth permission and connect to the band from Mirante. The Mac app
  is for editing/building faces; watchface transfer is an iOS capability.

Implementation: `MiFitnessKeyExtractor.swift`, `AuthKeyStore.swift`, and
`BandTransport.swift`.

## BLE service and characteristics

The tested band exposes the Xiaomi protocol on service `FE95`:

| UUID (short) | Mirante role | Required behavior |
| --- | --- | --- |
| `005E` | RX | Subscribe to notifications and feed received bytes to the protocol session. |
| `005F` | TX | Write complete framed packets, fragmenting only at the negotiated ATT payload size. |

Both characteristics may advertise `write-no-response` and `notify`; that does
not make them interchangeable. Mirante subscribes to `005E` and writes to
`005F`. The physical log showed a maximum write payload of 509 bytes and
`withResponse=false`. Select the write type from the characteristic's actual
properties and respect CoreBluetooth's send-buffer readiness.

The iOS app should not fall back to the older `0051/0052` mapping when this
`005E/005F` pair is present. Nor should it send the classic Bluetooth SPP byte
stream through a separate transport: the tested Band 10 Pro path is the Xiaomi
v2 framed protocol over this GATT service.

## Packet framing and session startup

All v2 packets use an 8-byte header:

```text
A5 A5 | type/flags | sequence | payload length (UInt16 LE) | CRC16/ARC (UInt16 LE) | payload
```

The checksum covers the payload. Packet types used here are NACK `0`, ACK `1`,
session config `2`, and data `3`. A data payload begins with channel and
opcode. The protobuf channel is `1`; the bulk data channel is `2`; plaintext
and encrypted opcodes are `1` and `2` respectively.

On a fresh GATT link:

1. Subscribe to notifications on `005E` before sending protocol data.
2. Send `encodeSessionStartRequest()` as the **first write**, directly through
   the transport writer. Do not put this first write behind previously queued
   frames. Wait for the session-config response before sending auth commands.
3. Keep command writes, packet ACKs, and ATT fragments serialized. Do not let a
   later command overtake a partially written frame or its ACK.
4. ACK each inbound data packet with an ACK packet carrying the received
   sequence number. Match replies by command type/subtype, not merely by the
   fact that some valid protobuf arrived.

The session-start frame and parser are covered by
`testSessionStartEncodesLittleEndianLengthsForEveryTLV` and the packet tests in
`BLETransportTests.swift`.

## Authentication — critical Band 10 Pro difference

The handshake uses the imported auth key and fresh nonces:

1. Send plaintext auth command `type=1, subtype=26` with the phone nonce.
2. Read the watch nonce and HMAC, derive directional session keys using
   `computeAuthStep3Hmac`, and verify the watch's HMAC before proceeding.
3. Encrypt the phone/device info with AES-CCM and send plaintext envelope
   `type=1, subtype=27` containing the encrypted auth fields.
4. Wait for the auth reply. A reply with absent status is valid on the tested
   firmware; do not treat an absent optional status as rejection. A present
   non-success status is rejection.
5. After auth, send the watchface install request immediately. Do not insert
   generic time/device initialization requests before it; on the tested device,
   that altered the working sequence and the install request received no
   approval.

**Do not replace the CCM B0 flags with standards-compliant RFC 3610 flags.**
For this firmware, the 4-byte tag and 12-byte nonce use `L=3`, but the B0
M-prime bits are `M - 2`, giving flags `0x12`; standard CCM uses `(M - 2) / 2`
and would give `0x0A`. The standard variant can make the exchange look as though
authentication completed, while subsequent encrypted commands are interpreted
incorrectly and the watchface approval never arrives. The hardware-validated
implementation is in `XiaomiCrypto.aesCCMEncrypt`; do not normalize it to a
generic CCM library without a new physical-device verification.

Post-auth BLE protobuf commands use AES-CTR with the separately derived
directional keys. Keep encryption and decryption keys in their correct
directions.

## Watchface transfer sequence

The expected request/reply sequence is:

1. Send encrypted watchface command `type=4, subtype=4`, containing the
   compiled face ID and byte size. The nested wire shape is pinned by
   `testWatchfacePrepareMatchesWireShapeThatReceivedHardwareApproval`.
2. Wait specifically for `type=4, subtype=4`. The response's watchface status
   field `0` means accepted; a nonzero value is a firmware rejection. Other
   valid commands (for example `type=10, subtype=3`) are not approval.
   On the tested device, status `5` was observed when the face name was already
   installed. Mirante reports this as a likely duplicate face and advises
   removing the installed copy or rebuilding with a different name. The compiler
   also derives a deterministic package ID from face name + device ID, so
   same-name projects for the same band share that package ID.
3. Send encrypted data-upload negotiation `type=22, subtype=0` with the face
   MD5 and size. Validate the returned MD5, chunk size, and resume position.
   The tested firmware returns `unknown2=1` for an accepted upload; allow that
   value rather than treating every nonzero value as failure.
4. Send the binary via the data channel in numbered chunks, with the expected
   MD5/size header and CRC32. Keep packets serialized and report progress.
5. Activate with encrypted watchface command `type=4, subtype=1`, await the
   activation reply, then refresh the installed-face list.

Do not report install success on BLE write completion alone. Success requires
the protocol replies through activation. If the watch stops notifying or sends
unrelated commands repeatedly, fail with diagnostics; do not pretend the
transfer succeeded or automatically unpair/re-pair the watch.

## Regression protection

The following tests protect the hardware-sensitive behavior:

- `testCCMMatchesBand10ProFirmwareVectors` pins fixed ciphertext-and-tag
  vectors for the nonstandard B0 flags. It must fail if the CCM variant changes.
- `testEncryptedInstallWithImmediateFragmentedReplies` exercises handshake,
  encrypted prepare/approval, upload negotiation, chunking, activation, and
  incoming frames split across notification boundaries.
- `testWatchfacePrepareMatchesWireShapeThatReceivedHardwareApproval` pins the
  protobuf request shape known to have received a hardware approval.
- `testSessionStartEncodesLittleEndianLengthsForEveryTLV` pins the session
  startup packet.
- `testCompleteFramesRemainSerializedAcrossSuspensions` and
  `testQueueStopsAfterWriteFailure` protect packet ordering and failure handling.

Run the unit suite on macOS with:

```sh
xcodebuild -project Mirante.xcodeproj -scheme Mirante \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO -only-testing:MiranteTests test
```

The unit target can run on macOS. The UI-test runner is separate and may require
an available iOS Simulator; a UI-runner launch failure does not invalidate the
unit-test result. Simulator tests cannot verify CoreBluetooth interoperability.
Any changes to
characteristic mapping, session start, auth key derivation, CCM/CTR, ACKs,
encryption choice, protobuf wire shape, chunk framing, or post-auth ordering
require both these regression tests and a physical Smart Band 10 Pro install.
Keep hardware-successful build numbers and logs available for byte-level
comparison; do not infer protocol correctness from a green compile alone.
