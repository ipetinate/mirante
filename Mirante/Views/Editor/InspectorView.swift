import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct InspectorView: View {
    @Environment(EditorState.self) private var editor

    var body: some View {
        @Bindable var editor = editor

        Group {
            if let widget = editor.selectedWidget {
                InspectorForm(widget: widget)
            } else if let project = optionalProject {
                ProjectInfoForm(project: project)
            } else {
                ContentUnavailableView(
                    "Nothing Selected",
                    systemImage: "slider.horizontal.3",
                    description: Text("Select a widget to edit its properties.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var optionalProject: WatchFaceProject? { editor.project }
}

struct ProjectInfoForm: View {
    @Environment(EditorState.self) private var editor
    let project: WatchFaceProject

    @State private var name: String
    @FocusState private var nameFocused: Bool

    init(project: WatchFaceProject) {
        self.project = project
        _name = State(initialValue: project.name)
    }

    var body: some View {
        @Bindable var editor = editor

        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("Watchface name"))
                    .focused($nameFocused)
                    .onSubmit { commitName() }
                    .onChange(of: nameFocused) { _, focused in
                        if !focused { commitName() }
                    }
                    .onDisappear { commitName() }
                Picker("Format", selection: $editor.project.format) {
                    ForEach(ProjectFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                LabeledContent("Device", value: project.device.name)
                LabeledContent("Resolution") {
                    Text("\(project.device.width) × \(project.device.height)")
                        .monospacedDigit()
                }
                Toggle("Always-On Display", isOn: $editor.project.usesAOD)
            } header: {
                Text("Project")
            } footer: {
                Text("The format controls the file structure produced when the face is exported.")
            }

            Section("Preview") {
                LivePreviewView(widgets: project.widgets, screen: project.screenSize, images: project.images)
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .padding(.vertical, 8)
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .scrollDismissesKeyboard(.immediately)
        #endif
    }

    /// Commits the typed name back to the project only on Enter or when focus
    /// leaves, so typing never churns the observation/autosave pipeline.
    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            name = editor.project.name
            return
        }
        guard trimmed != editor.project.name else { return }
        editor.project.name = trimmed
    }
}

struct InspectorForm: View {
    @Environment(EditorState.self) private var editor
    let widget: WidgetItem

    private var sources: [DataSource] {
        DataSourceCatalog.forDevice(editor.project.deviceID)
    }

    var body: some View {
        Form {
            Section {
                textFieldRow(
                    "Name",
                    helpTitle: "Name",
                    helpText: "The display name of the widget shown in the layers list.",
                    prompt: "Widget name",
                    \.name
                )
                toggleRow(
                    "Visible",
                    helpTitle: "Visible",
                    helpText: "Whether the widget is drawn on the face. Hides it without deleting it.",
                    \.visible
                )
                opacityRow
            } header: {
                Text("General")
            }

            Section {
                HStack(spacing: 16) {
                    sizeField(
                        "X", \.x, range: -2000...2000,
                        helpTitle: "X Position",
                        helpText: "Horizontal position of the widget's top-left corner, in device pixels."
                    )
                    Spacer(minLength: 0)
                    sizeField(
                        "Y", \.y, range: -2000...2000,
                        helpTitle: "Y Position",
                        helpText: "Vertical position of the widget's top-left corner, in device pixels."
                    )
                }
                HStack(spacing: 16) {
                    sizeField(
                        "W", \.width, range: 1...4096,
                        helpTitle: "Width",
                        helpText: "Width of the widget, in device pixels."
                    )
                    Spacer(minLength: 0)
                    sizeField(
                        "H", \.height, range: 1...4096,
                        helpTitle: "Height",
                        helpText: "Height of the widget, in device pixels."
                    )
                }
                Button {
                    editor.fitWidgetToScreen()
                } label: {
                    Label("Fit to Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                        .frame(maxWidth: .infinity)
                }
            } header: {
                Text("Position & Size")
            } footer: {
                Text("Units are device pixels.")
            }

            if widget.kind.usesColor {
                Section {
                    ColorPicker("Color", selection: colorBinding, supportsOpacity: false)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("The color used to draw the widget on the face.")
                }
            }

            switch widget.kind {
            case .image: imageSection
            case .imageList: imageListSection
            case .digitalNumber: numberSection
            case .analog: analogSection
            case .arc: arcSection
            case .container: containerSection
            case .pointer: pointerSection
            case .polyline: polylineSection
            }
        }
        .formStyle(.grouped)
    }

    private var imageSection: some View {
        Section {
            imageFieldRow(
                "Bitmap",
                helpTitle: "Bitmap",
                helpText: "The image file drawn for this widget. It is referenced by filename and embedded when the face is exported.",
                prompt: "image.png",
                \.bitmap
            )
            dimensionField(
                "Corner Radius",
                helpTitle: "Corner Radius",
                helpText: "Rounds the corners of the widget's image. 0 keeps square corners.",
                \.radius,
                range: 0...1024
            )
        } header: {
            Text(widget.kind.displayName)
        } footer: {
            Text("Images are embedded in the exported face by filename.")
        }
    }

    private var imageListSection: some View {
        Section {
            if widget.bitmapList.isEmpty {
                LabeledContent("Images") {
                    Text("No images yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(widget.bitmapList.indices, id: \.self) { index in
                imageListRow(index)
            }
            Button {
                editor.update({ $0.bitmapList.append("") }, label: "Add image")
            } label: {
                Label("Add Image", systemImage: "plus")
            }
            sourcePickerRow(
                "Index Source",
                helpTitle: "Index Source",
                helpText: "The data source that selects which image in the list is shown. Its value is used as the index into the list.",
                \.indexSourceID
            )
            stepperRow(
                "Default Index",
                helpTitle: "Default Index",
                helpText: "The image shown when the index source supplies no value.",
                value: "\(widget.defaultIndex)",
                \.defaultIndex,
                range: 0...max(0, widget.bitmapList.count - 1)
            )
            dimensionField(
                "Corner Radius",
                helpTitle: "Corner Radius",
                helpText: "Rounds the corners of the displayed image. 0 keeps square corners.",
                \.radius,
                range: 0...1024
            )
        } header: {
            Text(widget.kind.displayName)
        } footer: {
            Text("Each row is one image in the list. Images are embedded in the exported face by filename, so keep them in the folder you export from.")
        }
    }

    private func imageListRow(_ index: Int) -> some View {
        let label = "Image \(index + 1)"
        return LabeledContent(label) {
            HStack(spacing: 8) {
                TextField(label, text: listRowBinding(index), prompt: Text("image.png"))
                    .textFieldStyle(.roundedBorder)
                ImageFileButton(widgetID: widget.id) { url in
                    editor.update({ w in
                        guard w.bitmapList.indices.contains(index) else { return }
                        w.bitmapList[index] = url.lastPathComponent
                    }, label: "Bitmap list")
                }
                Button(role: .destructive) {
                    editor.update({ w in
                        guard w.bitmapList.indices.contains(index) else { return }
                        w.bitmapList.remove(at: index)
                        w.defaultIndex = Swift.min(w.defaultIndex, Swift.max(0, w.bitmapList.count - 1))
                    }, label: "Remove image")
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove this image")
                FieldHelp(
                    title: label,
                    detail: "The image shown at this position in the list. Use Choose… to pick an image file, or type its name."
                )
            }
        }
    }

    private var numberSection: some View {
        Section {
            sourcePickerRow(
                "Value Source",
                helpTitle: "Value Source",
                helpText: "The data source that provides the number displayed by this widget.",
                \.valueSourceID
            )
            stepperRow(
                "Digits",
                helpTitle: "Digits",
                helpText: "How many digit positions the widget shows. Wider values are clipped.",
                value: "\(widget.digits)",
                \.digits,
                range: 1...8
            )
            stepperRow(
                "Spacing",
                helpTitle: "Spacing",
                helpText: "Extra horizontal space between the digits, in device pixels.",
                value: "\(widget.spacing)",
                \.spacing,
                range: 0...64
            )
            pickerRow(
                "Alignment",
                helpTitle: "Alignment",
                helpText: "Horizontal alignment of the digits within the widget.",
                selection: binding(\.alignment, label: "Alignment")
            ) {
                Text("Left").tag(0)
                Text("Center").tag(1)
                Text("Right").tag(2)
            }
            toggleRow(
                "Background",
                helpTitle: "Background",
                helpText: "Draws a translucent rounded box behind the digits. Turn it off to show only the digits themselves.",
                \.digitBackground
            )
        } header: {
            Text(widget.kind.displayName)
        }
    }

    private var analogSection: some View {
        Section {
            imageFieldRow(
                "Hour Hand Image",
                helpTitle: "Hour Hand Image",
                helpText: "Image used for the hour hand. It rotates around the rotation center.",
                prompt: "hour.png",
                \.hourHandImage
            )
            imageFieldRow(
                "Minute Hand Image",
                helpTitle: "Minute Hand Image",
                helpText: "Image used for the minute hand. It rotates around the rotation center.",
                prompt: "minute.png",
                \.minuteHandImage
            )
            imageFieldRow(
                "Second Hand Image",
                helpTitle: "Second Hand Image",
                helpText: "Image used for the second hand. It rotates around the rotation center.",
                prompt: "second.png",
                \.secondHandImage
            )
            imageFieldRow(
                "Background Image",
                helpTitle: "Background Image",
                helpText: "Static image drawn underneath the hands.",
                prompt: "background.png",
                \.background
            )
            imageFieldRow(
                "Foreground Image",
                helpTitle: "Foreground Image",
                helpText: "Static image drawn on top of the hands.",
                prompt: "foreground.png",
                \.foreground
            )
            stepperRow(
                "Center X",
                helpTitle: "Rotation Center X",
                helpText: "Horizontal pivot point the hands rotate around, relative to the widget's top-left corner, in device pixels.",
                value: "\(widget.rotateCenterX)",
                \.rotateCenterX,
                range: -5000...5000
            )
            stepperRow(
                "Center Y",
                helpTitle: "Rotation Center Y",
                helpText: "Vertical pivot point the hands rotate around, relative to the widget's top-left corner, in device pixels.",
                value: "\(widget.rotateCenterY)",
                \.rotateCenterY,
                range: -5000...5000
            )
        } header: {
            Text(widget.kind.displayName)
        } footer: {
            Text("Images are embedded in the exported face by filename. A center of 0,0 is the widget's top-left corner.")
        }
    }

    private var arcSection: some View {
        Section {
            sourcePickerRow(
                "Value Source",
                helpTitle: "Value Source",
                helpText: "The data source whose value drives the arc progress.",
                \.valueSourceID
            )
            LabeledContent("Angles") {
                HStack(spacing: 8) {
                    TextField("Start°", value: binding(\.arcStartAngle, label: "Start angle"), format: .number, prompt: Text("Start°"))
                        .textFieldStyle(.roundedBorder)
                    TextField("End°", value: binding(\.arcEndAngle, label: "End angle"), format: .number, prompt: Text("End°"))
                        .textFieldStyle(.roundedBorder)
                    FieldHelp(
                        title: "Angles",
                        detail: "The arc is drawn from the start angle to the end angle, clockwise. -90 is the top of the widget."
                    )
                }
            }
            stepperRow(
                "Line Width",
                helpTitle: "Line Width",
                helpText: "Thickness of the progress arc, in device pixels.",
                value: "\(widget.arcLineWidth)",
                \.arcLineWidth,
                range: 1...64
            )
            LabeledContent("Range") {
                HStack(spacing: 8) {
                    TextField("Min", value: binding(\.rangeMin, label: "Range min"), format: .number, prompt: Text("Min"))
                        .textFieldStyle(.roundedBorder)
                    TextField("Max", value: binding(\.rangeMax, label: "Range max"), format: .number, prompt: Text("Max"))
                        .textFieldStyle(.roundedBorder)
                    FieldHelp(
                        title: "Range",
                        detail: "At the Min value the arc is empty; at the Max value it is full."
                    )
                }
            }
        } header: {
            Text(widget.kind.displayName)
        }
    }

    private var pointerSection: some View {
        Section {
            imageFieldRow(
                "Pointer Image",
                helpTitle: "Pointer Image",
                helpText: "Image used for the pointer (GMF-style watch).",
                prompt: "pointer.png",
                \.pointerImage
            )
            sourcePickerRow(
                "Value Source",
                helpTitle: "Value Source",
                helpText: "The data source that drives the pointer.",
                \.valueSourceID
            )
        } header: {
            Text(widget.kind.displayName)
        } footer: {
            Text("Images are embedded in the exported face by filename.")
        }
    }

    private var containerSection: some View {
        Section {
            Text("Containers have no editable properties.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } header: {
            Text(widget.kind.displayName)
        }
    }

    private var polylineSection: some View {
        Section {
            LabeledContent("Value Fill") {
                HStack(spacing: 8) {
                    Toggle("Value Fill", isOn: Binding(
                        get: { widget.polylineFilled },
                        set: { newValue in
                            editor.update({ w in
                                guard w.id == widget.id else { return }
                                w.polylineFilled = newValue
                                if newValue && (w.valueSourceID == "0" || w.valueSourceID == "8") {
                                    w.valueSourceID = "20"
                                }
                            }, label: "Value Fill")
                        }
                    ))
                    .labelsHidden()
                    FieldHelp(
                        title: "Value Fill",
                        detail: "Draws only a portion of the line, growing from one end, driven by the value source. Turn it on to make the polyline act as a progress bar."
                    )
                }
            }
            if widget.isValueFilledPolyline {
                sourcePickerRow(
                    "Value Source",
                    helpTitle: "Value Source",
                    helpText: "The data source whose value drives how much of the line is filled.",
                    \.valueSourceID
                )
                LabeledContent("Range") {
                    HStack(spacing: 8) {
                        TextField("Min", value: binding(\.rangeMin, label: "Range min"), format: .number, prompt: Text("Min"))
                            .textFieldStyle(.roundedBorder)
                        TextField("Max", value: binding(\.rangeMax, label: "Range max"), format: .number, prompt: Text("Max"))
                            .textFieldStyle(.roundedBorder)
                        FieldHelp(
                            title: "Range",
                            detail: "At the Min value the line is empty; at the Max value it is fully filled."
                        )
                    }
                }
                pickerRow(
                    "Fill Direction",
                    helpTitle: "Fill Direction",
                    helpText: "Which end of the line grows first: from its bottom edge upward, or from its top edge downward.",
                    selection: binding(\.polylineFillDirection, label: "Fill Direction")
                ) {
                    Text("Bottom to Top").tag(0)
                    Text("Top to Bottom").tag(1)
                }
            }
            stepperRow(
                "Line Width",
                helpTitle: "Line Width",
                helpText: "Thickness of the line, in device pixels.",
                value: "\(widget.lineWidth)",
                \.lineWidth,
                range: 1...64
            )
            rotationRow
            ForEach(widget.pointList.indices, id: \.self) { index in
                polylinePointRow(index)
            }
            Button {
                editor.update({ w in
                    w.pointList.append(CGPoint(x: 0.5, y: 0.5))
                }, label: "Add point")
            } label: {
                Label("Add Point", systemImage: "plus")
            }
        } header: {
            Text(widget.kind.displayName)
        } footer: {
            Text("Each point is a position inside the widget measured in percent. The line is drawn through the points in order. Use it to draw simple bars or icons such as a steps glyph. With Value Fill on, only the part of the line matching the value is drawn.")
        }
    }

    private var rotationRow: some View {
        LabeledContent("Rotation") {
            HStack(spacing: 8) {
                Slider(
                    value: doubleRotationBinding,
                    in: -180...180
                ) { editing in
                    if editing { editor.beginGesture() } else { editor.endGesture() }
                } label: {
                    Text("Rotation")
                }
                Text("\(Int(widget.rotation.rounded()))°")
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
                FieldHelp(
                    title: "Rotation",
                    detail: "Spins the polyline around its center. Drag the rotation handle on the canvas to set it visually."
                )
            }
        }
    }

    private var doubleRotationBinding: Binding<Double> {
        Binding(
            get: { widget.rotation },
            set: { newValue in
                let clamped = Swift.min(Swift.max(newValue, -180), 180)
                editor.update({ $0.rotation = clamped }, label: "Rotation")
            }
        )
    }

    private func polylinePointRow(_ index: Int) -> some View {
        LabeledContent("Point \(index + 1)") {
            HStack(spacing: 8) {
                TextField("X%", value: pointBinding(index, isX: true), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .frame(maxWidth: 60)
                TextField("Y%", value: pointBinding(index, isX: false), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .frame(maxWidth: 60)
                Button(role: .destructive) {
                    editor.update({ w in
                        guard w.pointList.indices.contains(index) else { return }
                        w.pointList.remove(at: index)
                    }, label: "Remove point")
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove this point")
            }
        }
    }

    // MARK: - Rows

    private var opacityRow: some View {
        LabeledContent("Opacity") {
            HStack(spacing: 8) {
                Slider(
                    value: doubleBinding(\.alpha, range: 0...255),
                    in: 0...255
                ) { editing in
                    if editing { editor.beginGesture() } else { editor.endGesture() }
                } label: {
                    Text("Opacity")
                }
                Text("\(widget.alpha)")
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
                FieldHelp(
                    title: "Opacity",
                    detail: "Overall transparency of the widget. 255 is fully opaque, 0 is invisible."
                )
            }
        }
    }

    private func textFieldRow(
        _ label: String,
        helpTitle: String,
        helpText: String,
        prompt: String,
        _ keyPath: WritableKeyPath<WidgetItem, String>
    ) -> some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                TextField(label, text: binding(keyPath, label: label), prompt: Text(prompt))
                    .textFieldStyle(.roundedBorder)
                FieldHelp(title: helpTitle, detail: helpText)
            }
        }
    }

    private func imageFieldRow(
        _ label: String,
        helpTitle: String,
        helpText: String,
        prompt: String,
        _ keyPath: WritableKeyPath<WidgetItem, String>
    ) -> some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                TextField(label, text: binding(keyPath, label: label), prompt: Text(prompt))
                    .textFieldStyle(.roundedBorder)
                ImageFileButton(widgetID: widget.id) { url in
                    editor.update({ $0[keyPath: keyPath] = url.lastPathComponent }, label: label)
                }
                FieldHelp(title: helpTitle, detail: helpText)
            }
        }
    }

    private func toggleRow(
        _ label: String,
        helpTitle: String,
        helpText: String,
        _ keyPath: WritableKeyPath<WidgetItem, Bool>
    ) -> some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Toggle(label, isOn: binding(keyPath, label: label))
                    .labelsHidden()
                FieldHelp(title: helpTitle, detail: helpText)
            }
        }
    }

    private func stepperRow(
        _ label: String,
        helpTitle: String,
        helpText: String,
        value: String,
        _ keyPath: WritableKeyPath<WidgetItem, Int>,
        range: ClosedRange<Int>
    ) -> some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Stepper(value: binding(keyPath, label: label), in: range) {
                    Text(value)
                        .monospacedDigit()
                }
                FieldHelp(title: helpTitle, detail: helpText)
            }
        }
    }

    private func sourcePickerRow(
        _ label: String,
        helpTitle: String,
        helpText: String,
        _ keyPath: WritableKeyPath<WidgetItem, String>
    ) -> some View {
        let selected = sources.first { $0.id == widget[keyPath: keyPath] }
        return LabeledContent {
            HStack(spacing: 8) {
                Picker(label, selection: binding(keyPath, label: label)) {
                    ForEach(sources) { source in
                        Text(source.name).tag(source.id)
                    }
                }
                .labelsHidden()
                FieldHelp(title: helpTitle, detail: helpText)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let selected, !selected.tip.isEmpty {
                    Text(selected.tip)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private func pickerRow<Value: Hashable>(
        _ label: String,
        helpTitle: String,
        helpText: String,
        selection: Binding<Value>,
        @ViewBuilder options: () -> some View
    ) -> some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Picker(label, selection: selection) {
                    options()
                }
                .labelsHidden()
                FieldHelp(title: helpTitle, detail: helpText)
            }
        }
    }

    // MARK: - Bindings

    private func sizeField(
        _ title: String,
        _ keyPath: WritableKeyPath<WidgetItem, Int>,
        range: ClosedRange<Int>,
        helpTitle: String,
        helpText: String
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 12, alignment: .leading)
            TextField(title, value: clampedIntBinding(keyPath, range: range), format: .number)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
            FieldHelp(title: helpTitle, detail: helpText)
        }
    }

    private func dimensionField(
        _ label: String,
        helpTitle: String,
        helpText: String,
        _ keyPath: WritableKeyPath<WidgetItem, Int>,
        range: ClosedRange<Int>
    ) -> some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                TextField(label, value: clampedIntBinding(keyPath, range: range), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 70)
                Stepper(label, value: clampedIntBinding(keyPath, range: range), in: range)
                    .labelsHidden()
                FieldHelp(title: helpTitle, detail: helpText)
            }
        }
    }

    private func clampedIntBinding(
        _ keyPath: WritableKeyPath<WidgetItem, Int>,
        range: ClosedRange<Int>
    ) -> Binding<Int> {
        Binding(
            get: { widget[keyPath: keyPath] },
            set: { newValue in
                let clamped = Swift.min(Swift.max(newValue, range.lowerBound), range.upperBound)
                editor.update({ $0[keyPath: keyPath] = clamped }, label: keyPathLabel(keyPath))
            }
        )
    }

    private func keyPathLabel(_ keyPath: WritableKeyPath<WidgetItem, Int>) -> String {
        switch keyPath {
        case \.x: return "Position X"
        case \.y: return "Position Y"
        case \.width: return "Width"
        case \.height: return "Height"
        case \.alpha: return "Opacity"
        case \.radius: return "Corner Radius"
        case \.rotateCenterX: return "Rotate X"
        case \.rotateCenterY: return "Rotate Y"
        default: return "Value"
        }
    }

    private func binding<T: Equatable>(
        _ keyPath: WritableKeyPath<WidgetItem, T>,
        label: String
    ) -> Binding<T> {
        Binding(
            get: { widget[keyPath: keyPath] },
            set: { newValue in
                editor.update({ $0[keyPath: keyPath] = newValue }, label: label)
            }
        )
    }

    private func doubleBinding(
        _ keyPath: WritableKeyPath<WidgetItem, Int>,
        range: ClosedRange<Int>
    ) -> Binding<Double> {
        Binding(
            get: { Double(widget[keyPath: keyPath]) },
            set: { newValue in
                let clamped = Int(newValue.rounded()).clamped(to: range)
                editor.update({ $0[keyPath: keyPath] = clamped }, label: "Opacity")
            }
        )
    }

    private func listRowBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                guard widget.bitmapList.indices.contains(index) else { return "" }
                return widget.bitmapList[index]
            },
            set: { newValue in
                editor.update({ w in
                    guard w.bitmapList.indices.contains(index) else { return }
                    w.bitmapList[index] = newValue
                }, label: "Bitmap list")
            }
        )
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { widget.widgetColor },
            set: { newColor in
                let (r, g, b) = rgbComponents(of: newColor)
                editor.update({ w in
                    w.colorR = r
                    w.colorG = g
                    w.colorB = b
                }, label: "Color")
            }
        )
    }

    private func rgbComponents(of color: Color) -> (r: Int, g: Int, b: Int) {
        #if os(macOS)
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return (255, 255, 255) }
        return (
            Int((srgb.redComponent * 255).rounded()),
            Int((srgb.greenComponent * 255).rounded()),
            Int((srgb.blueComponent * 255).rounded())
        )
        #else
        guard let components = UIColor(color).cgColor.components, components.count >= 3 else { return (255, 255, 255) }
        return (
            Int((components[0] * 255).rounded()),
            Int((components[1] * 255).rounded()),
            Int((components[2] * 255).rounded())
        )
        #endif
    }

    private func pointBinding(_ index: Int, isX: Bool) -> Binding<Int> {
        Binding(
            get: {
                guard widget.pointList.indices.contains(index) else { return 0 }
                let value = isX ? widget.pointList[index].x : widget.pointList[index].y
                return Int((value * 100).rounded())
            },
            set: { newValue in
                let clamped = Swift.min(Swift.max(newValue, 0), 100)
                editor.update({ w in
                    guard w.pointList.indices.contains(index) else { return }
                    let value = Double(clamped) / 100
                    if isX {
                        w.pointList[index].x = value
                    } else {
                        w.pointList[index].y = value
                    }
                }, label: "Point")
            }
        )
    }
}