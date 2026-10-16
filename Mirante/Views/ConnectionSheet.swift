import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct ConnectionSheet: View {
    @Environment(BandTransport.self) private var transport
    @Environment(EditorState.self) private var editor
    @Environment(\.dismiss) private var dismiss

    @State private var showAuthKeySheet = false
    @State private var pendingInstallError: String?
    @State private var isInstalling = false
    @State private var showExtractImporter = false
    @State private var extractedKeys: [MiFitnessKeyExtractor.FoundKey] = []
    @State private var extractNotice: String?
    @State private var extractNoticeIsSuccess = false

    var body: some View {
        NavigationStack {
            Group {
                if transport.isSupported {
                    Form {
                        statusSection
                        if transport.installPhase != .idle {
                            Section("Installation") { InstallStatusView() }
                        }
                        authKeySection
                        scanSection
                        devicesSection
                        if let connected = transport.connectedDevice {
                            connectedSection(connected)
                        }
                        extractKeySection
                        diagnosticsSection
                    }
                    .formStyle(.grouped)
                        #if os(iOS)
                        .scrollDismissesKeyboard(.immediately)
                        #endif
                    .sheet(isPresented: $showAuthKeySheet) {
                        AuthKeySheet()
                    }
                } else {
                    ContentUnavailableView {
                        Label("Bluetooth Unavailable", systemImage: "antenna.radiowaves.left.and.right")
                    } description: {
                        Text("Device connection is only available on iOS.")
                    }
                }
            }
            .navigationTitle("Device")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #else
        .frame(minWidth: 420, minHeight: 420)
        #endif
        .fileImporter(
            isPresented: $showExtractImporter,
            allowedContentTypes: [.folder, .data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            extractKeys(from: url)
        }
        .onAppear {
            transport.activate()
            consumePendingInstall()
        }
        .onChange(of: transport.isConnected) { _, connected in
            if connected { consumePendingInstall() }
        }
        .onChange(of: transport.authKey) { _, newKey in
            if newKey != nil && editor.pendingInstallFace != nil {
                consumePendingInstall()
            }
        }
        .onDisappear { transport.stopScanning() }
        .alert("Install Failed", isPresented: Binding(
            get: { pendingInstallError != nil },
            set: { if !$0 { pendingInstallError = nil } }
        )) {
            Button("OK", role: .cancel) { pendingInstallError = nil }
        } message: {
            Text(pendingInstallError ?? "")
        }
    }

    /// A face the user asked to install before connecting ("Connect & Install")
    /// is pushed automatically as soon as a band is connected and the auth key
    /// is available — no need to tap again.
    private func consumePendingInstall() {
        guard let face = editor.pendingInstallFace,
              transport.isConnected,
              transport.connectedDevice != nil,
              transport.authKey != nil else { return }
        let band = transport.connectedDevice!
        guard let data = try? Data(contentsOf: face.fileURL) else {
            pendingInstallError = String(localized: "The face file could not be read.")
            editor.pendingInstallFace = nil
            return
        }
        let device = band.deviceID.flatMap(Device.find) ?? Device.all[0]
        let validation = transport.validate(payload: data, for: device)
        guard validation.isOk else {
            pendingInstallError = validation.message
            editor.pendingInstallFace = nil
            return
        }
        isInstalling = true
        Task {
            defer { isInstalling = false }
            do {
                try await transport.install(payload: data, on: device)
                editor.pendingInstallFace = nil
            } catch let error as TransportError {
                pendingInstallError = error.errorDescription
            } catch {
                pendingInstallError = error.localizedDescription
            }
            editor.pendingInstallFace = nil
        }
    }

    private func extractKeys(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let found = MiFitnessKeyExtractor.extractKeys(from: url)
        extractedKeys = MiFitnessKeyExtractor.authKeyCandidates(from: found)
        extractNoticeIsSuccess = false
        if extractedKeys.isEmpty {
            extractNotice = String(localized: "No supported band auth key was found. Mirante accepts 32-character hex values from encryptKey, encrypt_key, authKey, or auth_key fields. Beacon and IRQ keys are not auth keys.")
        } else {
            extractNotice = nil
        }
    }

    #if !os(iOS)
    private func chooseOnMac() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose the Mi Fitness registration folder or the registerList file"
        if panel.runModal() == .OK, let url = panel.url {
            extractKeys(from: url)
        }
    }
    #endif

    private var statusSection: some View {
        Section("Status") {
            LabeledContent("Bluetooth") {
                Text(transport.isBluetoothOn ? "On" : "Off")
                    .foregroundStyle(transport.isBluetoothOn ? Color.secondary : Color.orange)
            }
            LabeledContent("Authorization", value: authorizationLabel)
            LabeledContent("Connection", value: connectionLabel)
            if let message = transport.lastErrorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var authKeySection: some View {
        Section {
            Button {
                showAuthKeySheet = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auth Key")
                        Group {
                            if let key = transport.authKey {
                                Text("\(String(key.prefix(4)))…\(String(key.suffix(4)))")
                                    .font(.system(.subheadline, design: .monospaced))
                            } else {
                                Text("Set the band's 32-hex auth key to unlock installation.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                    Group {
                        if transport.authKey != nil {
                            Label("Configured", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("Not set", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Auth Key")
        } footer: {
            Text("The key pairs Mirante with your band. Add it once here — installation becomes available and the file transfer honors the key automatically.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var scanSection: some View {
        Section {
            Button {
                if transport.isScanning {
                    transport.stopScanning()
                } else {
                    transport.startScanning()
                }
            } label: {
                Label(
                    transport.isScanning ? "Stop Scanning" : "Scan for Bands",
                    systemImage: transport.isScanning ? "stop.circle" : "magnifyingglass"
                )
            }
            .disabled(!transport.isBluetoothOn && !transport.isScanning)
        } header: {
            if transport.isScanning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning…")
                }
            }
        } footer: {
            Text("Showing every nearby Bluetooth device. If your band is not highlighted, pick the row with its advertised name.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var devicesSection: some View {
        Section("Nearby Devices") {
            if transport.discoveredBands.isEmpty {
                if transport.isScanning {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    ContentUnavailableView(
                        "No Devices Found",
                        systemImage: "antenna.radiowaves.left.and.right",
                        description: Text("Start a scan to look for your Xiaomi band or watch.")
                    )
                }
            } else {
                ForEach(transport.discoveredBands) { band in
                    bandRow(band)
                }
            }
        }
    }

    private func bandRow(_ band: BandTransport.DiscoveredBand) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(band.name)
                    .lineLimit(1)
                Text(secondaryLine(for: band))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text("\(band.rssi) dBm")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if transport.isConnected, transport.connectedDevice?.id == band.id {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
                Button("Disconnect") { transport.disconnect() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else if transport.connectionState == .connecting, transport.pendingBandID == band.id {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Connect") { transport.connect(to: band) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!transport.isBluetoothOn)
            }
        }
    }

    private func secondaryLine(for band: BandTransport.DiscoveredBand) -> String {
        if let deviceID = band.deviceID, let device = Device.find(deviceID) {
            return "\(device.name) · \(device.width) × \(device.height)"
        }
        if BandMatcher.isLikelyBand(advertisedName: band.name) {
            return String(localized: "Likely a Xiaomi-family device — not in the catalog")
        }
        return String(localized: "Not in device catalog")
    }

    private func connectedSection(_ band: BandTransport.DiscoveredBand) -> some View {
        Section("Connected") {
            LabeledContent("Device", value: band.name)
            if let deviceID = band.deviceID, let device = Device.find(deviceID) {
                LabeledContent("Catalog Match", value: device.name)
                LabeledContent("Screen", value: "\(device.width) × \(device.height)")
            } else {
                Text("This device is not in the Mirante catalog. Pairing still works, but installation targets are unknown.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if isInstalling || transport.installPhase != .idle {
                HStack(spacing: 8) {
                    ProgressView(value: progressValue)
                        .controlSize(.small)
                    Text(installPhaseLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Button("Disconnect") { transport.disconnect() }
        }
    }

    private var extractKeySection: some View {
        Section {
            Button {
                #if os(iOS)
                showExtractImporter = true
                #else
                chooseOnMac()
                #endif
            } label: {
                Label("Import Mi Fitness Data…", systemImage: "key.horizontal")
            }
            if !extractedKeys.isEmpty {
                Label(
                    recommendedAuthKeyID == nil ? "Auth key candidates" : "Recommended auth key",
                    systemImage: recommendedAuthKeyID == nil ? "key.horizontal" : "checkmark.seal.fill"
                )
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(recommendedAuthKeyID == nil ? Color.accentColor : Color.green)
                Text(recommendedAuthKeyID == nil
                     ? "Mi Fitness auth keys use encryptKey/encrypt_key. Beacon and IRQ keys are excluded. Multiple matching bands were found, so choose the record for this band."
                     : "Mi Fitness stores the band auth key as encryptKey (sometimes encrypt_key). Beacon and IRQ keys are excluded. If multiple bands are in the backup, match the record to this band.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                ForEach(Array(extractedKeys.enumerated()), id: \.element.id) { _, found in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(found.key)
                                .font(.subheadline.weight(.medium))
                            if found.id == recommendedAuthKeyID {
                                Text("Recommended")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.green)
                            }
                            Spacer(minLength: 8)
                            Text("••••\(String(found.value.suffix(4))) · \(found.file)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Button(transport.authKey == found.value ? "Auth Key Active" : (found.id == recommendedAuthKeyID ? "Use Recommended Auth Key" : "Use This Auth Key")) {
                            if transport.setAuthKey(found.value) != nil {
                                extractNotice = String(localized: "Auth key saved securely and ready to use.")
                                extractNoticeIsSuccess = true
                            } else {
                                extractNotice = String(localized: "Could not save this value as an auth key. Choose a 32-character hex encryptKey.")
                                extractNoticeIsSuccess = false
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(transport.authKey == found.value)
                    }
                }
            }
            if let extractNotice {
                Label(extractNotice, systemImage: extractNoticeIsSuccess ? "checkmark.circle.fill" : "info.circle")
                    .font(.footnote)
                    .foregroundStyle(extractNoticeIsSuccess ? Color.green : Color.secondary)
            }
        } header: {
            Text("Extract Pairing Key")
        } footer: {
            Text("Pick the Mi Fitness registration folder or the registerList file (pulled from an iPhone backup, or copied to Files) to pull the band's 32-hex auth key automatically. Keep the band paired to Mi Fitness — unpairing invalidates the key.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// A field name can rank one candidate above another, but equally ranked
    /// keys may belong to different bands. In that case, don't pretend Mirante
    /// can identify the user's band from a secret alone.
    private var recommendedAuthKeyID: String? {
        guard let best = extractedKeys.first,
              let bestPriority = best.authKeyPriority else { return nil }
        let tied = extractedKeys.dropFirst().contains { $0.authKeyPriority == bestPriority }
        return tied ? nil : best.id
    }

    private var authorizationLabel: String {
        switch transport.authorizationStatus {
        case .allowed: return "Allowed"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not Determined"
        }
    }

    private var connectionLabel: String {
        switch transport.connectionState {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        }
    }

    private var progressValue: Double? {
        guard let progress = transport.installProgress else { return nil }
        return max(0, min(1, progress))
    }

    private var progressLabel: String {
        if let progress = transport.installProgress {
            return String(localized: "Installing… \(Int(progress * 100))%")
        }
        return String(localized: "Installing…")
    }

    private var installPhaseLabel: String {
        switch transport.installPhase {
        case .idle: return progressLabel
        case .preparing: return "Preparing installation…"
        case .connecting: return "Opening watch connection…"
        case .authenticating: return "Authenticating with band…"
        case .negotiating: return "Negotiating transfer…"
        case .uploading(let value): return "Uploading… \(Int(value * 100))%"
        case .activating: return "Activating watchface…"
        case .succeeded: return "Installation completed"
        case .failed(let message): return "Installation failed: \(message)"
        }
    }

    private var diagnosticsSection: some View {
        Section {
            HStack(spacing: 12) {
                Text("GATT Diagnostics")
                Spacer()
                switch transport.diagnosticsState {
                case .idle:
                    Button("Run") { transport.runGATTDiagnostics() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!transport.isConnected)
                case .running:
                    ProgressView()
                        .controlSize(.small)
                case .done:
                    HStack(spacing: 8) {
                        Text("Done")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Re-run") { transport.runGATTDiagnostics() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
            if let report = transport.diagnosticsReport {
                ScrollView {
                    Text(report)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 220)
                Button("Copy Report") { copyDiagnostics(report) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Lists the band's Bluetooth GATT services and characteristics. Confirms whether the Xiaomi protocol channel (FE95 service + RX 0000005E + TX 0000005F) is exposed over BLE on this unit.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func copyDiagnostics(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        #endif
    }
}
