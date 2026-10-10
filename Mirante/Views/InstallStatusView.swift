import SwiftUI

struct InstallStatusView: View {
    @Environment(BandTransport.self) private var transport

    var body: some View {
        switch transport.installPhase {
        case .idle: EmptyView()
        case .uploading(let progress): status("Uploading watchface… \(Int(progress * 100))%", progress: progress, tint: .accentColor)
        case .preparing: status("Preparing installation…", progress: nil, tint: .accentColor)
        case .connecting: status("Opening watch connection…", progress: nil, tint: .accentColor)
        case .authenticating: status("Authenticating with band…", progress: nil, tint: .accentColor)
        case .negotiating: status("Negotiating transfer…", progress: nil, tint: .accentColor)
        case .activating: status("Activating watchface…", progress: nil, tint: .accentColor)
        case .succeeded: status("Installation completed", progress: 1, tint: .green)
        case .failed(let message): status("Installation failed: \(message)", progress: nil, tint: .red)
        }
    }

    private func status(_ text: String, progress: Double?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if transport.installPhase.isRunning { ProgressView().controlSize(.small) }
                Image(systemName: transport.installPhase.isRunning ? "antenna.radiowaves.left.and.right" : (transport.installPhase == .succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"))
                    .foregroundStyle(tint)
                Text(text).font(.callout).foregroundStyle(tint)
            }
            if let progress { ProgressView(value: progress).tint(tint) }
            VStack(alignment: .leading, spacing: 6) {
                if transport.installPhase.isRunning {
                    Text(transport.installDetail).font(.caption).foregroundStyle(.secondary)
                }
                if !transport.installDiagnostics.isEmpty {
                    ShareLink(item: transport.installDiagnostics.joined(separator: "\n")) {
                        Label("Share installation diagnostics", systemImage: "square.and.arrow.up")
                    }.font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
