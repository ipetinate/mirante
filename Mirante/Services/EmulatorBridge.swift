#if os(macOS)
import Foundation
import AppKit

/// Drives the `mirante-emulator` Node CLI — a sibling checkout that boots
/// Xiaomi's official Vela watch emulator and pushes a compiled watchface into
/// its guest. macOS only: the emulator is a desktop process reached through a
/// spawned Node CLI, which the iOS sandbox cannot host.
///
/// The app runs unsandboxed on macOS (`Mirante.entitlements` drops
/// `app-sandbox`) so it can execute the external CLI and the emulator binary
/// under `~/.vela`, and talk to them over adb (5555) / gRPC (8554).
@Observable
@MainActor
final class EmulatorBridge {

    /// Lifecycle of the emulator as far as this app is concerned.
    enum Phase: Equatable {
        case idle
        case starting
        case ready
        case pushing
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .starting, .pushing: return true
            default: return false
            }
        }

        var label: String {
            switch self {
            case .idle: return "Emulator stopped"
            case .starting: return "Starting emulator…"
            case .ready: return "Emulator running"
            case .pushing: return "Sending watchface…"
            case .failed(let message): return "Emulator error: \(message)"
            }
        }
    }

    /// A finished short-lived CLI invocation.
    private struct CLIResult {
        let status: Int32
        let output: String
    }

    private(set) var phase: Phase = .idle
    /// Rolling stdout/stderr from the CLI, shown in the export sheet.
    private(set) var log: String = ""
    /// Most recent screenshot taken from the emulator, if any.
    private(set) var lastScreenshot: URL?

    /// The long-lived `start` process; terminating it tears down the emulator.
    private var startProcess: Process?

    private var resolvedNodePath: String?

    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.terminateImmediately() }
        }
    }

    var isRunning: Bool {
        if case .ready = phase { return true }
        if case .pushing = phase { return true }
        return false
    }

    // MARK: - Configuration

    /// Absolute path to the CLI entry point. Configurable so a checkout can
    /// live anywhere; defaults to the sibling repo beside this project.
    var cliPath: String {
        get {
            let stored = UserDefaults.standard.string(forKey: "emulatorCLIPath")
            return (stored?.isEmpty == false) ? stored! : Self.defaultCLIPath
        }
        set { UserDefaults.standard.set(newValue, forKey: "emulatorCLIPath") }
    }

    static var defaultCLIPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Projects/Xiaomi/mirante-emulator/bin/mirante-emulator"
    }

    var cliExists: Bool {
        FileManager.default.isExecutableFile(atPath: cliPath)
    }

    // MARK: - Commands

    /// Boots the emulator, streaming the CLI log, and waits until adb reports
    /// a device before declaring it ready.
    func start() async {
        guard !phase.isBusy, !isRunning else { return }
        guard cliExists else {
            append("CLI não encontrado em \(cliPath).")
            phase = .failed("CLI não encontrado")
            return
        }
        guard resolveNode() != nil else {
            append("Node.js não encontrado. Instale o Node ou defina MIRANTE_NODE.")
            phase = .failed("Node.js não encontrado")
            return
        }

        phase = .starting
        log = ""

        do {
            let process = try makeProcess(arguments: ["start"])
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in self?.append(text) }
            }
            process.terminationHandler = { [weak self] finished in
                Task { @MainActor in
                    guard let self, self.startProcess === finished else { return }
                    self.startProcess = nil
                    if self.isRunning {
                        self.append("[app] o processo do emulador terminou.")
                        self.phase = .failed("O emulador terminou inesperadamente")
                    }
                }
            }
            try process.run()
            startProcess = process
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        if await waitUntilReady() {
            phase = .ready
        } else if case .starting = phase {
            phase = .failed("Tempo esgotado ao iniciar o emulador")
        }
    }

    /// Kills the emulator and stops the long-lived `start` process.
    func stop() async {
        _ = await runCLI(["stop"])
        startProcess?.terminate()
        startProcess = nil
        phase = .idle
        append("[app] emulador parado.")
    }

    /// Ensures the emulator is running, then pushes the compiled face.
    func push(faceURL: URL) async {
        if !isRunning {
            await start()
        }
        guard isRunning else { return }

        phase = .pushing
        append("[app] enviando \(faceURL.lastPathComponent)…")
        let result = await runCLI(["push", faceURL.path])
        if let result { append(result.output) }

        if let result, result.status == 0 {
            // Grab a fresh screenshot so the result is visible immediately.
            _ = await screenshot()
            phase = .ready
            append("[app] watchface enviada.")
        } else {
            _ = await screenshot()
            phase = .failed("Push falhou (código \(result?.status ?? -1))")
        }
    }

    /// Captures a PNG from the running emulator and remembers its location.
    @discardableResult
    func screenshot() async -> URL? {
        guard isRunning else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirante-emulator-shot.png")
        let result = await runCLI(["screenshot", url.path])
        if let result { append(result.output) }
        if result?.status == 0, FileManager.default.fileExists(atPath: url.path) {
            lastScreenshot = url
            return url
        }
        return nil
    }

    // MARK: - Readiness

    /// Polls the CLI until adb reports a connected device (or we run out of
    /// patience). The CLI's `devices` prints a "nenhum" note when empty.
    private func waitUntilReady() async -> Bool {
        for _ in 0..<75 { // ~150s at 2s intervals
            if Task.isCancelled { return false }
            if case .starting = phase {} else { return false }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let result = await runCLI(["devices"]) else { continue }
            let text = result.output.lowercased()
            if !text.contains("nenhum"), !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
        }
        return false
    }

    // MARK: - Process plumbing

    private func makeProcess(arguments: [String]) throws -> Process {
        guard let node = resolveNode() else { throw BridgeError.nodeNotFound }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [cliPath] + arguments
        var environment = ProcessInfo.processInfo.environment
        let nodeDir = URL(fileURLWithPath: node).deletingLastPathComponent().path
        environment["PATH"] = nodeDir + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["QUIET"] = "1"
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: cliPath).deletingLastPathComponent()
        return process
    }

    /// Runs a short-lived CLI command off the main actor and returns its
    /// status and combined output.
    private func runCLI(_ arguments: [String]) async -> CLIResult? {
        guard cliExists, resolveNode() != nil else { return nil }
        do {
            let process = try makeProcess(arguments: arguments)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(returning: nil)
                        return
                    }
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: CLIResult(status: process.terminationStatus, output: output))
                }
            }
        } catch {
            return nil
        }
    }

    /// Locates a `node` executable: explicit env override, the user's login
    /// shell (so nvm/asdf shims resolve), then the usual install locations.
    private func resolveNode() -> String? {
        if let cached = resolvedNodePath, FileManager.default.isExecutableFile(atPath: cached) {
            return cached
        }

        if let override = ProcessInfo.processInfo.environment["MIRANTE_NODE"],
           FileManager.default.isExecutableFile(atPath: override) {
            resolvedNodePath = override
            return override
        }

        if let fromShell = loginShellLookup("command -v node") {
            resolvedNodePath = fromShell
            return fromShell
        }

        let fixed = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        for candidate in fixed where FileManager.default.isExecutableFile(atPath: candidate) {
            resolvedNodePath = candidate
            return candidate
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let nvmRoot = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            for version in versions.sorted(by: >) {
                let candidate = "\(nvmRoot)/\(version)/bin/node"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    resolvedNodePath = candidate
                    return candidate
                }
            }
        }
        return nil
    }

    private func loginShellLookup(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    /// Synchronous best-effort cleanup at app termination.
    private func terminateImmediately() {
        if cliExists, let node = resolveNode() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: node)
            process.arguments = [cliPath, "stop"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
        startProcess?.terminate()
        startProcess = nil
    }

    private func append(_ text: String) {
        guard !text.isEmpty else { return }
        log += text
        if log.count > 40_000 {
            log = String(log.suffix(20_000))
        }
    }

    private enum BridgeError: LocalizedError {
        case nodeNotFound
        var errorDescription: String? { "Node.js não encontrado" }
    }
}
#endif
