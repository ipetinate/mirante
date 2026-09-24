import SwiftUI

#if os(macOS)
import AppKit

/// Forces the hosting window to a fixed frame at launch.
/// Pass `nil` to fill the entire available screen space (visible frame:
/// everything between the menu bar and the Dock). Used because SwiftUI
/// `defaultSize` can be overridden by the window manager's restored frame.
/// Inert on other platforms.
struct ForcedWindowFrame: NSViewRepresentable {
    /// `nil` = fill all available screen space.
    let size: CGSize?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.contentMinSize = CGSize(width: 860, height: 560)
            let screen = window.screen ?? NSScreen.main
            if let size {
                guard let screen else { return }
                let origin = NSPoint(
                    x: screen.visibleFrame.midX - size.width / 2,
                    y: screen.visibleFrame.midY - size.height / 2
                )
                window.setFrame(
                    NSRect(origin: origin, size: size),
                    display: true
                )
            } else if let screen {
                window.setFrame(screen.visibleFrame, display: true)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    /// `size == nil` fills all available screen space.
    func forcedWindowFrame(_ size: CGSize? = nil) -> some View {
        background {
            ForcedWindowFrame(size: size)
        }
    }
}
#endif