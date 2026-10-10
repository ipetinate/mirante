import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Crop is an explicit image action. The normal canvas manipulator never
/// enters this mode, so dragging handles remains purely geometric.
struct ImageCropSheet: View {
    let data: Data
    let onApply: (CGRect) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var left = 0.0
    @State private var top = 0.0
    @State private var right = 1.0
    @State private var bottom = 1.0

    private var cropRect: CGRect { CGRect(x: left, y: top, width: max(0.01, right - left), height: max(0.01, bottom - top)) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Preview") { preview.frame(maxWidth: .infinity).frame(height: 250).padding(.vertical, 8) }
                Section("Crop bounds") {
                    slider("Left", value: $left, range: 0...max(0, right - 0.01))
                    slider("Top", value: $top, range: 0...max(0, bottom - 0.01))
                    slider("Right", value: $right, range: min(1, left + 0.01)...1)
                    slider("Bottom", value: $bottom, range: min(1, top + 0.01)...1)
                    Button("Reset crop") { left = 0; top = 0; right = 1; bottom = 1 }
                }
            }
            .navigationTitle("Crop Image")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Apply") { onApply(cropRect); dismiss() } }
            }
        }
        .frame(minWidth: 360, minHeight: 440)
    }

    @ViewBuilder private var preview: some View {
        #if os(macOS)
        if let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit().overlay { overlay } }
        else { ContentUnavailableView("Preview unavailable", systemImage: "photo") }
        #else
        if let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit().overlay { overlay } }
        else { ContentUnavailableView("Preview unavailable", systemImage: "photo") }
        #endif
    }

    private var overlay: some View {
        GeometryReader { proxy in
            let x = left * proxy.size.width, y = top * proxy.size.height
            let w = (right - left) * proxy.size.width, h = (bottom - top) * proxy.size.height
            Rectangle().fill(.black.opacity(0.5))
                .mask { Rectangle().fill(style: FillStyle(eoFill: true)).overlay { Rectangle().frame(width: w, height: h).position(x: x + w / 2, y: y + h / 2).blendMode(.destinationOut) } }
            Rectangle().stroke(.tint, lineWidth: 2).frame(width: w, height: h).position(x: x + w / 2, y: y + h / 2)
        }.allowsHitTesting(false)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading) {
            HStack { Text(title); Spacer(); Text("\(Int(value.wrappedValue * 100))%").monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: value, in: range)
        }
    }
}
