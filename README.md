<p align="center">
  <img src="Mirante/Resources/Assets.xcassets/Logo.imageset/logo.png" alt="Mirante" width="112">
</p>

<h1 align="center">Mirante</h1>

<p align="center">
  Design watch faces with care. Preview them, build them, and—on iPhone—send them to your Xiaomi Smart Band.
</p>

<p align="center">
  <a href="#what-you-can-do">Features</a> ·
  <a href="#get-started">Get started</a> ·
  <a href="#formats">Project formats</a> ·
  <a href="docs/SMART_BAND_10_PRO_PROTOCOL.md">Band 10 Pro notes</a> ·
  <a href="docs/STORE_LISTING.md">Store listing copy</a>
</p>

Mirante is a native watch-face editor for **iPhone and Mac**, built for making faces for Xiaomi smart bands. Create a face from a blank canvas, arrange and tune its widgets, preview it at the target screen size, then build a watch-ready `.bin` right in the app.

The Mac app is the comfortable design-and-build workspace. **Bluetooth installation is an iPhone feature**: pair the band with Mi Fitness, add its authentication key to Mirante, and install from the iPhone app.

## What you can do

- Design on a canvas with images, digital time, data widgets, arcs, pointers, analog elements, and more.
- Arrange layers, lock finished elements, and make precise edits in the inspector.
- Keep working with autosaved recent projects and undo/redo.
- Import images, crop them when needed, and compress image assets during build to keep the final bundle lean.
- Preview and compile faces locally without depending on a cloud build service.
- Import and export Mi Create / EasyFace `.fprj` projects, while keeping Mirante's native project format as the recommended format for the fullest Mirante support.
- Browse and publish faces through the GitHub-backed community store.
- On iPhone, connect over Bluetooth and install a compiled face on a supported band.

Widget availability and behavior can vary by face format and band. Mirante validates the generated package, but a preview is not a substitute for checking the face on the target hardware.

## Get started

### Use the app

1. Install Mirante on iPhone or Mac.
2. Choose **New Project**, select the target band, and add widgets and images.
3. Preview the face, then build or export its `.bin` package.
4. To install from iPhone, keep the band paired in Mi Fitness, connect from Mirante, and provide the correct 32-character authentication key when prompted.

Do not unpair the band just to retrieve its key: unpairing may invalidate the key. Mirante can import Mi Fitness registration data exported from an iPhone backup. See the [Smart Band 10 Pro connection notes](docs/SMART_BAND_10_PRO_PROTOCOL.md) for the verified pairing, key, and BLE requirements.

### Build from source

Requirements: macOS 26 or later, Xcode with the iOS 26/macOS 26 SDKs, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
xcodebuild -project Mirante.xcodeproj -scheme Mirante \
  -destination 'platform=macOS' build
```

Run the unit tests with:

```sh
xcodebuild -project Mirante.xcodeproj -scheme Mirante \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO -only-testing:MiranteTests test
```

Open `Mirante.xcodeproj` in Xcode to run the iOS app on a device or simulator. Real BLE installation can only be verified with a physical compatible band.

## Formats

- **Mirante (`.mirante`)** — recommended for projects created in Mirante; preserves the editor's native project data and is the best-supported format here.
- **FPRJ (`.fprj`)** — import/export compatibility for Mi Create / EasyFace projects. Some source-format features may not map perfectly to Mirante or to every band.
- **Compiled face (`.bin`)** — the built artifact. It is ready to install but is not an editable project.

## Publishing faces

The community store is hosted in [`ipetinate/mirante-store`](https://github.com/ipetinate/mirante-store). In Mirante, use Explore to browse faces or the publish flow to submit one. Publishing requires GitHub authorization; only publish work and assets you have the rights to share. A face published to the store is a downloadable artifact—it is not automatically installed on a watch.

## Contributing

Bug reports and focused pull requests are welcome. For protocol-sensitive changes—especially BLE framing, authentication, crypto, packet ordering, or the `.bin` compiler—include regression tests and preserve the hardware-verified behavior documented in [`docs/SMART_BAND_10_PRO_PROTOCOL.md`](docs/SMART_BAND_10_PRO_PROTOCOL.md). A green build alone does not prove compatibility with a physical band.

Mirante is an independent community project and is not affiliated with or endorsed by Xiaomi. Xiaomi and Mi Fitness are trademarks of their respective owners.
