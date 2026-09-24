import SwiftUI

struct NewProjectSheet: View {
    @Environment(EditorState.self) private var editor
    @Environment(\.dismiss) private var dismiss

    @State private var name = "Untitled"
    @State private var selectedDevice = Device.all[0]
    @State private var format: ProjectFormat = .fprj
    @State private var searchText = ""

    private var filteredDevices: [Device] {
        if searchText.isEmpty { return Device.all }
        return Device.all.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                if proxy.size.width >= 640 {
                    HStack(spacing: 0) {
                        leftColumn
                        Divider()
                        deviceColumn
                    }
                } else {
                    compactForm
                }
            }
            .navigationTitle("New Watchface")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        editor.newProject(
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            device: selectedDevice
                        )
                        editor.project.format = format
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }
            #if os(macOS)
            .frame(minWidth: 980, minHeight: 620)
            #endif
            #if os(iOS)
            .presentationDetents([.large])
            #endif
        }
    }

    private var compactForm: some View {
        Form {
            projectSection

            Section("Device") {
                Picker("Device", selection: $selectedDevice) {
                    ForEach(filteredDevices) { device in
                        Text(device.name).tag(device)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Preview") {
                previewBody
                    .frame(height: 220)
            }
        }
        .searchable(text: $searchText, prompt: "Search devices")
    }

    private var leftColumn: some View {
        Form {
            projectSection

            Section("Preview") {
                previewBody
                    .frame(height: 300)
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .scrollDismissesKeyboard(.immediately)
        #endif
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var projectSection: some View {
        Section {
            TextField("Name", text: $name)
            Picker("Format", selection: $format) {
                ForEach(ProjectFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
        } header: {
            Text("Project")
        } footer: {
            Text(formatInfo)
        }
    }

    private var previewBody: some View {
        LivePreviewView(widgets: [], screen: selectedDevice.screenSize, device: selectedDevice)
            .frame(maxWidth: .infinity)
    }

    private var formatInfo: String {
        switch format {
        case .fprj:
            return "FPRJ is the Mi-Create (EasyFace) format: an XML document built from widgets — images, image lists, digital numbers, analog hands, arc progress and containers. It is the format Mi-Create reads to assemble the watch face."
        case .gmf:
            return "GMF is a simpler, lighter format used by a few tools. It only supports images, image lists and digital numbers — no analog hands, arcs or containers."
        }
    }

    private var deviceColumn: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search devices", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            .padding(.top, 12)

            deviceList(filteredDevices)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 360)
    }

    private func deviceList(_ devices: [Device]) -> some View {
        List(selection: selectedDeviceBinding) {
            ForEach(devices) { device in
                LabeledContent(device.name) {
                    Text("\(device.width) × \(device.height)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .tag(device)
            }
        }
        .listStyle(.inset)
    }

    private var selectedDeviceBinding: Binding<Device?> {
        Binding(
            get: { selectedDevice },
            set: { if let device = $0 { selectedDevice = device } }
        )
    }
}