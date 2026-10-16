import SwiftUI

#if os(macOS)
import AppKit
#endif

@main
struct MiranteApp: App {
    @State private var editor = EditorState()
    @State private var bandTransport = BandTransport()
    #if DEBUG && os(iOS)
    @State private var hardwareTestFace: CompiledFace?
    @State private var hardwareTestStarted = false
    #endif
    #if os(macOS)
    @State private var emulator = EmulatorBridge()
    #endif

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG && os(iOS)
                if let hardwareTestFace {
                    NavigationStack { CompiledFaceDetailView(face: hardwareTestFace) }
                } else {
                    ContentView()
                }
                #else
                ContentView()
                #endif
            }
                .environment(editor)
                .environment(bandTransport)
                #if DEBUG && os(iOS)
                .task { await runHardwareInstallIfRequested() }
                #endif
                #if os(macOS)
                .environment(emulator)
                #endif
        }
        #if os(macOS)
        .defaultSize(
            width: NSScreen.main?.visibleFrame.width ?? 1440,
            height: NSScreen.main?.visibleFrame.height ?? 900
        )
        .restorationBehavior(.disabled)
        #endif
        .commands {
            #if os(macOS)
            SidebarCommands()
            CommandGroup(after: .newItem) {
                Button("New Watchface…") { editor.showNewProjectSheet = true }
                    .keyboardShortcut("n", modifiers: [.command, .option])
            }
            #endif
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { editor.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!editor.canUndo)
                Button("Redo") { editor.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!editor.canRedo)
            }
        }
    }

    #if DEBUG && os(iOS)
    /// Opt-in developer entry point for a real-device installation. Requires
    /// both an exact library filename and a peripheral UUID; never picks a
    /// nearby band or runs during an ordinary app launch.
    @MainActor
    private func runHardwareInstallIfRequested() async {
        func argument(_ name: String) -> String? {
            let args = ProcessInfo.processInfo.arguments
            guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        guard !hardwareTestStarted,
              let name = argument("-DebugInstallFace"),
              let idString = argument("-DebugInstallBand"), let id = UUID(uuidString: idString) else { return }
        hardwareTestStarted = true
        editor.refreshCompiledFaces()
        guard let face = editor.compiledFaces.first(where: { $0.name == name }) else {
            print("[hardware-test] Requested face is not in the library")
            return
        }
        hardwareTestFace = face
        bandTransport.activate()
        do {
            let deadline = Date().addingTimeInterval(30)
            while !bandTransport.isBluetoothOn && Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            bandTransport.connectHardwareTestBand(id: id)
            while bandTransport.connectedDevice?.id != id && Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            bandTransport.stopScanning()
            guard let band = bandTransport.connectedDevice, band.id == id,
                  let deviceID = band.deviceID, let device = Device.find(deviceID) else {
                print("[hardware-test] Requested band did not connect")
                return
            }
            let data = try Data(contentsOf: face.fileURL)
            print("[hardware-test] Installing library face: \(face.name), bytes=\(data.count)")
            try await bandTransport.install(payload: data, on: device)
            print("[hardware-test] Installation completed and activation confirmed")
        } catch {
            print("[hardware-test] \(error.localizedDescription)")
        }
    }
    #endif
}
