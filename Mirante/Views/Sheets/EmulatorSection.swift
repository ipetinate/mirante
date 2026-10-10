#if os(macOS)
import SwiftUI
import AppKit

/// macOS-only "Emulator" section for the export sheet: boot Xiaomi's Vela
/// watch emulator via the `mirante-emulator` CLI and run the compiled face on
/// it. iOS has no such section — the emulator is a desktop process.
struct EmulatorSection: View {
    @Environment(EmulatorBridge.self) private var emulator
    /// The freshly compiled face to send, or nil until one is built.
    let binURL: URL?

    @State private var showingSettings = false

    var body: some View {
        Section("Emulator (Vela)") {
            HStack(spacing: 8) {
                statusBadge
                Text(emulator.phase.label)
                    .font(.callout)
                Spacer()
                if emulator.phase.isBusy {
                    ProgressView().controlSize(.small)
                }
            }

            if let binURL {
                Button {
                    Task { await emulator.push(faceURL: binURL) }
                } label: {
                    Label("Run on Emulator", systemImage: "play.circle")
                }
                .disabled(emulator.phase.isBusy)
            } else {
                Text("Build a compiled .bin above, then run it on the emulator.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if emulator.isRunning {
                    Button("Stop Emulator") { Task { await emulator.stop() } }
                        .disabled(emulator.phase.isBusy)
                    Button("Screenshot") {
                        Task {
                            if let url = await emulator.screenshot() {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    .disabled(emulator.phase.isBusy)
                } else {
                    Button("Start Emulator") { Task { await emulator.start() } }
                        .disabled(emulator.phase.isBusy)
                }
                Spacer()
                Button { showingSettings.toggle() } label: {
                    Image(systemName: "gearshape")
                }
                .help("Emulator CLI location")
            }

            if let shot = emulator.lastScreenshot, let image = NSImage(contentsOf: shot) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                    .frame(maxWidth: .infinity)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.black)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if showingSettings {
                cliPathField
            }

            if !emulator.log.isEmpty {
                DisclosureGroup("Emulator log") {
                    ScrollView {
                        Text(emulator.log)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
                .font(.footnote)
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch emulator.phase {
        case .idle:
            Image(systemName: "circle").foregroundStyle(.secondary)
        case .starting, .pushing:
            Image(systemName: "circle.dotted").foregroundStyle(.orange)
        case .ready:
            Image(systemName: "circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var cliPathField: some View {
        @Bindable var emulator = emulator
        VStack(alignment: .leading, spacing: 4) {
            TextField("CLI path", text: $emulator.cliPath)
                .font(.system(.caption, design: .monospaced))
                .textFieldStyle(.roundedBorder)
            Text(emulator.cliExists
                 ? "Node.js is located automatically (nvm, Homebrew, or MIRANTE_NODE)."
                 : "No executable found at this path.")
                .font(.caption2)
                .foregroundStyle(emulator.cliExists ? Color.secondary : Color.red)
        }
    }
}
#endif
