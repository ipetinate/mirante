import Foundation
import Observation

#if os(iOS)
@preconcurrency import CoreBluetooth
import UIKit
#endif

enum BandConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
}

enum BluetoothAuthorizationStatus: Equatable {
    case allowed
    case denied
    case restricted
    case notDetermined
}

enum GATTDiagnosticsState: Equatable {
    case idle
    case running
    case done
}

enum InstallPhase: Equatable {
    case idle, preparing, connecting, authenticating, negotiating
    case uploading(Double), activating, succeeded, failed(String)
    var isRunning: Bool {
        switch self { case .preparing, .connecting, .authenticating, .negotiating, .uploading, .activating: return true; default: return false }
    }
}

@MainActor
@Observable
final class BandTransport: NSObject, WatchFaceTransport {
    struct DiscoveredBand: Identifiable, Hashable {
        let id: UUID
        let name: String
        let rssi: Int
        let deviceID: String?
        var isConnected: Bool
    }

    private(set) var discoveredBands: [DiscoveredBand] = []
    private(set) var isScanning = false
    private(set) var connectionState: BandConnectionState = .disconnected
    private(set) var connectedDevice: DiscoveredBand?
    private(set) var pendingBandID: UUID?
    private(set) var isBluetoothOn = false
    private(set) var authorizationStatus: BluetoothAuthorizationStatus = .notDetermined
    private(set) var lastErrorMessage: String?
    private(set) var authKey: String?
    private(set) var diagnosticsState: GATTDiagnosticsState = .idle
    private(set) var diagnosticsReport: String?
    /// 0...1 install/upload progress while a face is being pushed to the band.
    private(set) var installProgress: Double?
    private(set) var installPhase: InstallPhase = .idle
    private(set) var installDetail = ""
    private(set) var installDiagnostics: [String] = []

    private func recordInstallDiagnostic(_ message: String) {
        installDiagnostics.append(message)
        if installDiagnostics.count > 100 { installDiagnostics.removeFirst() }
        #if DEBUG
        print("[install] \(message)")
        #endif
    }

    var isConnected: Bool { connectionState == .connected }

    /// The persisted band auth key, read once at startup. Nil means the user
    /// never supplied one and Mirante stays in create/share mode.
    private let keyStore = AuthKeyStore()

    /// Saves (or clears, when `nil`) the band auth key. The value is validated
    /// to 32 hex characters before it is accepted or replaced in storage.
    /// Returns nil when the input is not a valid auth key.
    @discardableResult
    func setAuthKey(_ value: String?) -> String? {
        guard let value, !value.isEmpty else {
            keyStore.clear()
            authKey = nil
            return nil
        }
        guard AuthKeyStore.isValid(value) else { return nil }
        let normalized = AuthKeyStore.normalized(value)
        keyStore.setKey(normalized)
        authKey = normalized
        return normalized
    }

    var isSupported: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }

    var isAvailable: Bool {
        isSupported && isBluetoothOn && authorizationStatus == .allowed
    }

    @ObservationIgnored private var scanSession = 0
    @ObservationIgnored private var pendingScan = false

    #if os(iOS)
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var diagnosticServices: [CBService] = []
    @ObservationIgnored private var diagnosticCharacteristics: [String: [CBCharacteristic]] = [:]
    @ObservationIgnored private var pendingDiagnosticDiscoveries = 0

    /// Install pipeline continuations / state, bridged from the CB delegate.
    @ObservationIgnored private var installServicesContinuation: CheckedContinuation<[CBService], Error>?
    @ObservationIgnored private var installCharacteristicsContinuation: CheckedContinuation<[CBCharacteristic], Error>?
    @ObservationIgnored private var installNotifyContinuation: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var installNotifyCharacteristicUUID: CBUUID?
    @ObservationIgnored private var installWriteContinuation: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var installSession: XiaomiProtocolSession?

    /// Services every Xiaomi-family band registers, used to enumerate devices
    /// that are already connected to the phone (e.g. by Mi Fitness) so Mirante
    /// can pick up the existing connection instead of rescanning from scratch.
    /// 1800 = Generic Access, 180A = Device Information, 1810 = Battery,
    /// plus the Mi Band custom services historically used by Xiaomi/Huami.
    static let connectedDeviceServices: [CBUUID] = [
        CBUUID(string: "1800"),
        CBUUID(string: "180A"),
        CBUUID(string: "1810"),
        CBUUID(string: "FEE0"),
        CBUUID(string: "FEE1"),
        CBUUID(string: "FEE7"),
        CBUUID(string: "FF01"),
    ]
    #endif

    override init() {
        super.init()
        authKey = keyStore.key
        refreshState()
    }

    func activate() {
        #if os(iOS)
        guard let central = ensureCentral() else { return }
        adoptConnectedPeripherals(central: central)
        refreshState()
        #endif
    }

    func startScanning() {
        guard isSupported else { return }
        refreshState()
        guard authorizationStatus == .allowed else {
            lastErrorMessage = TransportError.bluetoothUnavailable.errorDescription
            return
        }
        #if os(iOS)
        guard let central = ensureCentral() else {
            lastErrorMessage = TransportError.bluetoothUnavailable.errorDescription
            return
        }
        refreshState()
        if central.state == .poweredOn {
            pendingScan = false
            performScan()
        } else {
            pendingScan = true
        }
        #else
        lastErrorMessage = TransportError.bluetoothUnavailable.errorDescription
        #endif
    }

    func stopScanning() {
        pendingScan = false
        scanSession += 1
        #if os(iOS)
        central?.stopScan()
        #endif
        isScanning = false
    }

    func connect(to band: DiscoveredBand) {
        #if os(iOS)
        refreshState()
        guard isBluetoothOn, let central = ensureCentral() else {
            lastErrorMessage = TransportError.bluetoothUnavailable.errorDescription
            return
        }
        guard central.state == .poweredOn else {
            lastErrorMessage = TransportError.bluetoothUnavailable.errorDescription
            return
        }
        guard let peripheral = peripherals[band.id] else {
            lastErrorMessage = TransportError.deviceNotPaired.errorDescription
            return
        }
        stopScanning()
        pendingBandID = band.id
        connectionState = .connecting
        lastErrorMessage = nil
        central.connect(peripheral, options: nil)
        #else
        lastErrorMessage = TransportError.bluetoothUnavailable.errorDescription
        #endif
    }

    #if DEBUG && os(iOS)
    func connectHardwareTestBand(id: UUID) {
        guard let central, central.state == .poweredOn,
              let peripheral = central.retrievePeripherals(withIdentifiers: [id]).first else {
            print("[hardware-test] Peripheral is not in CoreBluetooth's known-device cache")
            return
        }
        let name = peripheral.name ?? "Known band"
        store(peripheral, rssi: 0, name: name)
        guard let band = discoveredBands.first(where: { $0.id == id }) else { return }
        print("[hardware-test] Connecting to the requested cached peripheral")
        connect(to: band)
    }
    #endif

    func disconnect() {
        #if os(iOS)
        let targetID = connectedDevice?.id ?? pendingBandID
        if let targetID, let peripheral = peripherals[targetID] {
            central?.cancelPeripheralConnection(peripheral)
        }
        #else
        let targetID = connectedDevice?.id ?? pendingBandID
        #endif
        if let targetID, let index = discoveredBands.firstIndex(where: { $0.id == targetID }) {
            discoveredBands[index].isConnected = false
        }
        connectionState = .disconnected
        connectedDevice = nil
        pendingBandID = nil
        diagnosticsState = .idle
        diagnosticsReport = nil
    }

    /// Connects to the paired band, then enumerates every GATT service and
    /// characteristic on it. The report is written to `diagnosticsReport` and
    /// is used to confirm whether the Xiaomi protocol channel is exposed over
    /// BLE (service `FE95` with notify on `0000005E` and write on `0000005F`).
    func runGATTDiagnostics() {
        guard !installPhase.isRunning else { return }
        #if os(iOS)
        guard let central, central.state == .poweredOn else {
            lastErrorMessage = TransportError.bluetoothUnavailable.errorDescription
            return
        }
        guard let bandID = connectedDevice?.id,
              let peripheral = peripherals[bandID],
              peripheral.state == .connected else {
            lastErrorMessage = String(localized: "Connect to a band before running diagnostics.")
            return
        }
        guard diagnosticsState != .running else { return }
        diagnosticsState = .running
        diagnosticsReport = nil
        diagnosticServices = []
        diagnosticCharacteristics = [:]
        peripheral.delegate = self
        peripheral.discoverServices(nil)
        #else
        lastErrorMessage = TransportError.bluetoothUnavailable.errorDescription
        #endif
    }

    func validate(payload: Data, for device: Device) -> TransportValidation {
        guard !payload.isEmpty else { return .empty }
        guard payload.count <= maxFacePayloadBytes else { return .tooLarge(maxFacePayloadBytes) }
        guard CompiledFaceMagic.matches(payload) else { return .notCompiled }
        return .ok
    }

    func install(payload: Data, on device: Device) async throws {
        guard !installPhase.isRunning else { throw TransportError.transferFailed("Another installation is already in progress.") }
        guard diagnosticsState != .running else { throw TransportError.transferFailed("Wait for Bluetooth diagnostics to finish before installing.") }
        installPhase = .preparing
        installDiagnostics = []
        installDetail = "Preparing installation"
        let validation = validate(payload: payload, for: device)
        guard validation.isOk else { installPhase = .failed(validation.message); throw TransportError.validation(validation) }
        guard let authKey, !authKey.isEmpty else {
            lastErrorMessage = TransportError.authKeyRequired.errorDescription
            installPhase = .failed(TransportError.authKeyRequired.errorDescription ?? "Auth key required.")
            throw TransportError.authKeyRequired
        }
        #if os(iOS)
        guard let central, central.state == .poweredOn else {
            lastErrorMessage = TransportError.bluetoothUnavailable.errorDescription
            installPhase = .failed(TransportError.bluetoothUnavailable.errorDescription ?? "Bluetooth unavailable.")
            throw TransportError.bluetoothUnavailable
        }
        guard let bandID = connectedDevice?.id,
              let peripheral = peripherals[bandID],
              peripheral.state == .connected else {
            lastErrorMessage = TransportError.deviceNotPaired.errorDescription
            installPhase = .failed(TransportError.deviceNotPaired.errorDescription ?? "Device not connected.")
            throw TransportError.deviceNotPaired
        }

        installProgress = 0
        peripheral.delegate = self

        do {
            installPhase = .connecting
            // Find the Xiaomi protocol channel (FE95 service, 5E notify, 5F write).
            let service = try await discoverXiaomiProtocolService(peripheral: peripheral)
            guard let service else {
                throw TransportError.sendingUnavailable
            }
            let characteristics = try await discoverCharacteristicsForInstall(peripheral: peripheral, service: service)
            guard let channel = XiaomiChannel(rx: characteristics.0, tx: characteristics.1) else {
                throw TransportError.sendingUnavailable
            }

            // Keep the proven Xiaomi channel behavior: 005E receives protocol
            // frames; 005F is the write endpoint even when its properties also
            // advertise notify. The known-good hardware install subscribed only
            // to 005E.
            try await waitForInstallNotify(peripheral: peripheral, characteristic: channel.rx)

            // Some firmwares only expose write-without-response on the TX
            // channel (005F), so pick the type the peripheral advertises.
            let writeType: CBCharacteristicWriteType = channel.tx.properties.contains(.write)
                ? .withResponse
                : .withoutResponse
            let maxWrite = peripheral.maximumWriteValueLength(for: writeType)
            // Keep the proven Band 10 Pro framing margin. Although
            // CoreBluetooth reports a payload capacity, this firmware's
            // FE95 characteristic has historically accepted frames reliably
            // only with the 3-byte ATT margin removed.
            let writeChunk = max(20, maxWrite - 3)
            recordInstallDiagnostic(
                "BLE channel; subscribed notify=\(channel.rx.uuid.uuidString), "
                    + "write=\(channel.tx.uuid.uuidString) [\(propertiesString(channel.tx.properties))]"
            )
            recordInstallDiagnostic("BLE v2; write payload capacity=\(writeChunk); withResponse=\(writeType == .withResponse)")

            let session = XiaomiProtocolSession()
            installPhase = .authenticating
            installSession = session
            session.onStage = { [weak self] value in
                self?.installDetail = value
                if value == "Activating watchface" { self?.installPhase = .activating }
            }
            session.onDiagnostic = { [weak self] in self?.recordInstallDiagnostic($0) }
            session.writer = { [weak self] frame in
                guard let self else { throw TransportError.transferFailed("Transport went away.") }
                try await self.writeFrame(peripheral, to: channel.tx, frame, chunk: writeChunk, writeType: writeType)
            }
            session.onProgress = { [weak self] progress in
                self?.installProgress = progress
                self?.installPhase = .uploading(progress)
            }
            defer {
                session.abort(TransportError.abortedByUser)
                installSession = nil
                installProgress = nil
            }

            try await session.runHandshake(
                authKey: authKey,
                phoneName: UIDevice.current.model,
                region: Self.currentRegion()
            )
            installPhase = .negotiating
            try await session.installWatchface(payload: payload)
            installPhase = .succeeded
        } catch {
            failInstallWaits(error)
            recordInstallDiagnostic("Failed: \(error.localizedDescription)")
            // Preserve the established BLE connection after an install error.
            // Canceling here was added after the known-good revision and made
            // every timeout force the user to reconnect before another try.
            lastErrorMessage = error.localizedDescription
            installSession = nil
            installProgress = nil
            installPhase = .failed(error.localizedDescription)
            throw error
        }
        #else
        lastErrorMessage = TransportError.sendingUnavailable.errorDescription
        installPhase = .failed(lastErrorMessage ?? "Installation requires iOS.")
        throw TransportError.sendingUnavailable
        #endif
    }

    func resetInstallStatus() {
        guard !installPhase.isRunning else { return }
        installProgress = nil
        installPhase = .idle
    }

    #if os(iOS)
    private func failInstallWaits(_ error: Error) {
        installSession?.abort(error)
        let services = installServicesContinuation
        let characteristics = installCharacteristicsContinuation
        let notify = installNotifyContinuation
        let write = installWriteContinuation
        installServicesContinuation = nil
        installCharacteristicsContinuation = nil
        installNotifyContinuation = nil
        installNotifyCharacteristicUUID = nil
        installWriteContinuation = nil
        services?.resume(throwing: error)
        characteristics?.resume(throwing: error)
        notify?.resume(throwing: error)
        write?.resume(throwing: error)
    }

    private func installDeadline(_ step: String) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 25_000_000_000) }
            catch { return }
            self?.failInstallWaits(TransportError.transferFailed("Bluetooth timeout: \(step). Reconnect before retrying."))
        }
    }

    private struct XiaomiChannel {
        let rx: CBCharacteristic
        let tx: CBCharacteristic
        init?(rx: CBCharacteristic?, tx: CBCharacteristic?) {
            guard let rx, let tx else { return nil }
            self.rx = rx
            self.tx = tx
        }
    }

    private func ensureCentral() -> CBCentralManager? {
        if let central { return central }
        let manager = CBCentralManager(delegate: self, queue: nil)
        central = manager
        return manager
    }

    /// Discovers every GATT service and returns the Xiaomi protocol service
    /// (FE95), or nil when the device does not expose it.
    private func discoverXiaomiProtocolService(peripheral: CBPeripheral) async throws -> CBService? {
        let deadline = installDeadline("service discovery")
        defer { deadline.cancel() }
        installServicesContinuation = nil
        let services: [CBService] = try await withCheckedThrowingContinuation { continuation in
            installServicesContinuation = continuation
            // Register the continuation before starting discovery. Some
            // peripherals answer synchronously and would otherwise race the
            // delegate callback, leaving install stuck until timeout.
            peripheral.discoverServices(nil)
        }
        return services.first { serviceMatches($0.uuid) }
    }

    private func serviceMatches(_ uuid: CBUUID) -> Bool {
        let raw = uuid.uuidString.uppercased()
        return XiaomiBLEChannel.normalize(raw) == XiaomiBLEChannel.normalize(XiaomiBLEChannel.serviceUUID)
    }

    private func discoverCharacteristicsForInstall(
        peripheral: CBPeripheral,
        service: CBService
    ) async throws -> (rx: CBCharacteristic?, tx: CBCharacteristic?) {
        let deadline = installDeadline("characteristic discovery")
        defer { deadline.cancel() }
        installCharacteristicsContinuation = nil
        let characteristics: [CBCharacteristic] = try await withCheckedThrowingContinuation { continuation in
            installCharacteristicsContinuation = continuation
            peripheral.discoverCharacteristics(nil, for: service)
        }
        var rx: CBCharacteristic?
        var tx: CBCharacteristic?
        for characteristic in characteristics {
            if matches(characteristic: characteristic, shortHex: "0000005E") { rx = characteristic }
            if matches(characteristic: characteristic, shortHex: "0000005F") { tx = characteristic }
        }
        return (rx, tx)
    }

    /// Compares a discovered characteristic UUID against the 16-bit Xiaomi
    /// channel UUID, which CoreBluetooth may report in short (`005E`), padded
    /// (`0000005E`) or full 128-bit expanded form.
    private func matches(characteristic: CBCharacteristic, shortHex: String) -> Bool {
        XiaomiBLEChannel.normalize(characteristic.uuid.uuidString) == XiaomiBLEChannel.normalize(shortHex)
    }

    private func waitForInstallNotify(peripheral: CBPeripheral, characteristic: CBCharacteristic) async throws {
        recordInstallDiagnostic("Enabling notify on \(characteristic.uuid.uuidString); alreadyEnabled=\(characteristic.isNotifying)")
        if characteristic.isNotifying { return }
        let deadline = installDeadline("enabling notifications")
        defer { deadline.cancel() }
        installNotifyContinuation = nil
        installNotifyCharacteristicUUID = characteristic.uuid
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            installNotifyContinuation = continuation
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    /// Writes one packet, split into ATT-sized chunks. Writes never overlap:
    /// with-response chunks each await their own `didWriteValueFor`, and
    /// without-response chunks (no delivery callback exists for those) are
    /// paced so the firmware's RX buffer is not flooded.
    private func writeFrame(
        _ peripheral: CBPeripheral,
        to characteristic: CBCharacteristic,
        _ frame: Data,
        chunk: Int,
        writeType: CBCharacteristicWriteType
    ) async throws {
        let isBulk = frame.count > 8 && frame[2] == 3 && frame[8] == 2
        if !isBulk {
            recordInstallDiagnostic("Writing frame type=\(frame.count > 2 ? Int(frame[2]) : -1) sequence=\(frame.count > 3 ? Int(frame[3]) : -1) bytes=\(frame.count)")
            if frame.count > 2, frame[2] == 2 {
                recordInstallDiagnostic("Session request bytes=\(frame.map { String(format: "%02x", $0) }.joined())")
            }
        }
        var offset = 0
        while offset < frame.count {
            let end = min(offset + chunk, frame.count)
            let piece = frame.subdata(in: frame.startIndex + offset ..< frame.startIndex + end)
            offset = end
            if writeType == .withResponse {
                let deadline = installDeadline("writing packet")
                defer { deadline.cancel() }
                installWriteContinuation = nil
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    installWriteContinuation = continuation
                    peripheral.writeValue(piece, for: characteristic, type: .withResponse)
                }
            } else {
                let started = Date()
                while !peripheral.canSendWriteWithoutResponse {
                    guard peripheral.state == .connected else { throw TransportError.deviceNotPaired }
                    guard Date().timeIntervalSince(started) < 25 else { throw TransportError.transferFailed("Bluetooth send buffer remained full.") }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                peripheral.writeValue(piece, for: characteristic, type: .withoutResponse)
                try await Task.sleep(nanoseconds: 15_000_000)
            }
        }
        if !isBulk { recordInstallDiagnostic("Frame handed to Bluetooth") }
    }

    /// Mirrors Gadgetbridge's region field: the 2-letter language code.
    private static func currentRegion() -> String {
        if let language = Locale.current.language.languageCode?.identifier,
           language.count >= 2 {
            return language.prefix(2).uppercased()
        }
        return "US"
    }
    #endif

    private func refreshState() {
        #if os(iOS)
        switch CBCentralManager.authorization {
        case .allowedAlways: authorizationStatus = .allowed
        case .denied: authorizationStatus = .denied
        case .restricted: authorizationStatus = .restricted
        case .notDetermined: authorizationStatus = .notDetermined
        @unknown default: authorizationStatus = .notDetermined
        }
        isBluetoothOn = central?.state == .poweredOn
        #endif
    }

    #if os(iOS)
    /// Lifts devices already connected to the system (e.g. via Mi Fitness) into
    /// the list so Mirante can reuse an existing pairing instead of rescanning.
    private func adoptConnectedPeripherals(central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        var seen = Set<UUID>()
        for service in Self.connectedDeviceServices {
            for peripheral in central.retrieveConnectedPeripherals(withServices: [service]) {
                guard seen.insert(peripheral.identifier).inserted else { continue }
                let name = peripheral.name ?? String(localized: "Unknown Device")
                guard BandMatcher.isLikelyBand(advertisedName: name) else { continue }
                peripherals[peripheral.identifier] = peripheral
                store(peripheral, rssi: 0, name: name)
                if peripheral.state != .connected {
                    central.connect(peripheral, options: nil)
                }
            }
        }
    }
    #endif

    private func performScan() {
        #if os(iOS)
        guard let central, central.state == .poweredOn else { return }
        discoveredBands = []
        lastErrorMessage = nil
        isScanning = true
        scanSession += 1
        let session = scanSession
        adoptConnectedPeripherals(central: central)
        central.scanForPeripherals(withServices: nil, options: nil)
        Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard self.scanSession == session, self.isScanning else { return }
            self.stopScanning()
        }
        #endif
    }

    #if os(iOS)
    private func store(_ peripheral: CBPeripheral, rssi: Int, name: String) {
        peripherals[peripheral.identifier] = peripheral
        let band = DiscoveredBand(
            id: peripheral.identifier,
            name: name,
            rssi: rssi,
            deviceID: BandMatcher.matches(advertisedName: name)?.id,
            isConnected: peripheral.state == .connected
        )
        if let index = discoveredBands.firstIndex(where: { $0.id == band.id }) {
            discoveredBands[index] = band
        } else {
            discoveredBands.append(band)
        }
        discoveredBands.sort { lhs, rhs in
            if lhs.isConnected != rhs.isConnected { return lhs.isConnected }
            if (lhs.deviceID != nil) != (rhs.deviceID != nil) { return lhs.deviceID != nil }
            return lhs.name < rhs.name
        }
    }
    #endif
}

#if os(iOS)
extension BandTransport: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        refreshState()
        if central.state == .poweredOn {
            if pendingScan {
                pendingScan = false
                performScan()
            }
        } else {
            central.stopScan()
            pendingScan = false
            isScanning = false
            if connectionState != .disconnected {
                connectionState = .disconnected
                connectedDevice = nil
                pendingBandID = nil
            }
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? String(localized: "Unknown Device")
        guard BandMatcher.isLikelyBand(advertisedName: name) else { return }
        store(peripheral, rssi: RSSI.intValue, name: name)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // A successful connection ends discovery. Leaving CoreBluetooth scanning
        // alive causes the sheet to keep collecting peripherals and can race
        // with the install handshake on some Xiaomi firmwares.
        stopScanning()
        let fallback = discoveredBands.first { $0.id == peripheral.identifier }
        let name = peripheral.name ?? fallback?.name ?? String(localized: "Unknown Device")
        connectedDevice = DiscoveredBand(
            id: peripheral.identifier,
            name: name,
            rssi: fallback?.rssi ?? 0,
            deviceID: BandMatcher.matches(advertisedName: name)?.id,
            isConnected: true
        )
        peripheral.delegate = self
        connectionState = .connected
        pendingBandID = nil
        lastErrorMessage = nil
        diagnosticsState = .idle
        diagnosticsReport = nil
        if let index = discoveredBands.firstIndex(where: { $0.id == peripheral.identifier }) {
            discoveredBands[index].isConnected = true
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionState = .disconnected
        connectedDevice = nil
        pendingBandID = nil
        lastErrorMessage = error?.localizedDescription ?? String(localized: "Connection failed.")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if connectedDevice?.id == peripheral.identifier {
            failInstallWaits(error ?? TransportError.deviceNotPaired)
        }
        connectionState = .disconnected
        connectedDevice = nil
        pendingBandID = nil
        diagnosticsState = .idle
        diagnosticsReport = nil
        if let index = discoveredBands.firstIndex(where: { $0.id == peripheral.identifier }) {
            discoveredBands[index].isConnected = false
        }
        if let error { lastErrorMessage = error.localizedDescription }
    }
}
#endif

#if os(iOS)
extension BandTransport: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral.identifier == connectedDevice?.id else { return }
        if let pendingServices = installServicesContinuation {
            if let error {
                pendingServices.resume(throwing: error)
            } else {
                pendingServices.resume(returning: peripheral.services ?? [])
            }
            installServicesContinuation = nil
            return
        }
        guard diagnosticsState == .running else { return }
        if let error {
            finishDiagnostics("Failed to discover services: \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services, !services.isEmpty else {
            finishDiagnostics("No GATT services advertised by this device.")
            return
        }
        diagnosticServices = services
        diagnosticCharacteristics = [:]
        pendingDiagnosticDiscoveries = services.count
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard peripheral.identifier == connectedDevice?.id else { return }
        if installCharacteristicsContinuation != nil, !serviceMatches(service.uuid) { return }
        if let pendingCharacteristics = installCharacteristicsContinuation {
            if let error {
                pendingCharacteristics.resume(throwing: error)
            } else {
                pendingCharacteristics.resume(returning: service.characteristics ?? [])
            }
            installCharacteristicsContinuation = nil
            return
        }
        guard diagnosticsState == .running, pendingDiagnosticDiscoveries > 0 else { return }
        let key = service.uuid.uuidString.uppercased()
        diagnosticCharacteristics[key] = error == nil ? (service.characteristics ?? []) : []
        pendingDiagnosticDiscoveries -= 1
        if pendingDiagnosticDiscoveries == 0 {
            finishDiagnostics(buildDiagnosticsReport(peripheral: peripheral))
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral.identifier == connectedDevice?.id,
              characteristic.uuid == installNotifyCharacteristicUUID else { return }
        if let pendingNotify = installNotifyContinuation {
            if let error {
                pendingNotify.resume(throwing: error)
            } else if characteristic.isNotifying {
                pendingNotify.resume(returning: ())
            } else {
                pendingNotify.resume(throwing: TransportError.transferFailed("The band did not enable notifications."))
            }
            installNotifyContinuation = nil
            installNotifyCharacteristicUUID = nil
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral.identifier == connectedDevice?.id,
              matches(characteristic: characteristic, shortHex: "0000005F") else { return }
        if let pendingWrite = installWriteContinuation {
            if let error {
                pendingWrite.resume(throwing: error)
            } else {
                pendingWrite.resume(returning: ())
            }
            installWriteContinuation = nil
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral.identifier == connectedDevice?.id,
              matches(characteristic: characteristic, shortHex: "0000005E") else { return }
        if installPhase.isRunning {
            recordInstallDiagnostic("BLE notification on \(characteristic.uuid.uuidString); bytes=\(characteristic.value?.count ?? 0), sessionReady=\(installSession != nil), error=\(error?.localizedDescription ?? "none")")
        }
        if let error { failInstallWaits(error); return }
        guard installSession != nil, error == nil, let value = characteristic.value else { return }
        if installDetail == "Starting BLE v2 session" {
            let sample = value.prefix(24).map { String(format: "%02x", $0) }.joined(separator: " ")
            recordInstallDiagnostic("BLE RX during session start; characteristic=\(characteristic.uuid.uuidString), bytes=\(value.count), prefix=\(sample)")
        }
        installSession?.handleIncoming(value)
    }

    private func finishDiagnostics(_ report: String) {
        diagnosticsReport = report
        diagnosticsState = .done
    }

    private func buildDiagnosticsReport(peripheral: CBPeripheral) -> String {
        var lines: [String] = []
        lines.append("GATT: \(peripheral.name ?? "Unnamed")")
        lines.append("ID:   \(peripheral.identifier.uuidString)")
        lines.append("")
        lines.append("Services (\(diagnosticServices.count)):")
        for service in diagnosticServices {
            let key = service.uuid.uuidString.uppercased()
            lines.append("  \(formatUUID(service.uuid))\(annotation(key, forCharacteristic: false))")
            for characteristic in diagnosticCharacteristics[key] ?? [] {
                lines.append(
                    "    - \(formatUUID(characteristic.uuid)) [\(propertiesString(characteristic.properties))]"
                        + annotation(characteristic.uuid.uuidString.uppercased(), forCharacteristic: true)
                )
            }
        }
        lines.append("")
        lines.append("Target channel: FE95 service + notify on 0000005E + write on 0000005F.")
        lines.append("If FE95 (or the 5E/5F pair) is absent, this firmware only speaks Bluetooth Classic.")
        return lines.joined(separator: "\n")
    }

    private func annotation(_ uuid: String, forCharacteristic: Bool) -> String {
        let known: [String: String] = [
            "00001800-0000-1000-8000-00805F9B34FB": "Generic Access",
            "0000180A-0000-1000-8000-00805F9B34FB": "Device Information",
            "00001810-0000-1000-8000-00805F9B34FB": "Battery",
            "0000FEE0-0000-1000-8000-00805F9B34FB": "Huami service (FEE0)",
            "0000FEE1-0000-1000-8000-00805F9B34FB": "Huami service (FEE1)",
            "0000FEE7-0000-1000-8000-00805F9B34FB": "Xiaomi auth service (FEE7)",
            "0000FE95-0000-1000-8000-00805F9B34FB": "Xiaomi protocol service",
            "0000005E-0000-1000-8000-00805F9B34FB": "RX (BLE v2)",
            "0000005F-0000-1000-8000-00805F9B34FB": "TX (BLE v2)",
            "00000051-0000-1000-8000-00805F9B34FB": "v1 characteristic",
            "00000052-0000-1000-8000-00805F9B34FB": "v1 characteristic",
            "00000053-0000-1000-8000-00805F9B34FB": "v1 characteristic",
            "00000055-0000-1000-8000-00805F9B34FB": "v1 characteristic",
        ]
        guard let label = known[uuid] else { return "" }
        return " — \(label)"
    }

    private func formatUUID(_ uuid: CBUUID) -> String {
        return uuid.uuidString.uppercased()
    }

    private func propertiesString(_ properties: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if properties.contains(.read) { parts.append("read") }
        if properties.contains(.write) { parts.append("write") }
        if properties.contains(.writeWithoutResponse) { parts.append("write-no-resp") }
        if properties.contains(.notify) { parts.append("notify") }
        if properties.contains(.indicate) { parts.append("indicate") }
        if properties.contains(.broadcast) { parts.append("broadcast") }
        if properties.contains(.authenticatedSignedWrites) { parts.append("signed-write") }
        if properties.contains(.extendedProperties) { parts.append("extended") }
        if properties.contains(.notifyEncryptionRequired) { parts.append("notify-encr") }
        if properties.contains(.indicateEncryptionRequired) { parts.append("indicate-encr") }
        return parts.isEmpty ? "no-props" : parts.joined(separator: ",")
    }
}
#endif
