import SwiftUI

struct FieldHelp: View {
    let title: String
    let detail: String

    @State private var showPopover = false

    var body: some View {
        #if os(iOS)
        Button {
            showPopover = true
        } label: {
            Image(systemName: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
        .help(detail)
        .popover(isPresented: $showPopover) {
            helpContent
                .padding(14)
                .frame(maxWidth: 300)
        }
        #else
        Image(systemName: "info.circle")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .help(detail)
            .accessibilityLabel(title)
        #endif
    }

    private var helpContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}