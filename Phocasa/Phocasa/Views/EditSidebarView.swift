import SwiftUI

// MARK: - Edit Sidebar

struct EditSidebarView: View {
    /// The edit: parameters, comparison, crop and export state.
    @Bindable var session: EditSession
    /// Presets, which outlive a session.
    @Bindable var viewModel: PhotoLibraryViewModel
    /// Revert clears the saved edit: asked first.
    @State private var confirmingRevert = false
    /// The preset name field has focus: the Photo menu's shortcuts are off meanwhile (`isTypingInContent`).
    @FocusState private var namingPreset: Bool

    var body: some View {
        VStack(spacing: 0) {
            editToolbar
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    lightSection
                    sectionDivider
                    colorSection
                    sectionDivider
                    detailSection
                    sectionDivider
                    effectsSection

                    if session.isRAW {
                        sectionDivider
                        rawSection
                    }

                    sectionDivider
                    transformSection
                    sectionDivider
                    presetsSection
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .frame(width: 280)
        .background(.ultraThinMaterial)
    }

    // MARK: - Toolbar

    private var editToolbar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Text("\(session.fileKind) Edit")
                    .font(.headline)
                    .foregroundStyle(session.isRAW ? .blue : .orange)

                Spacer()

                Button(action: { session.enterCropMode() }) {
                    Image(systemName: "crop")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .help("Crop & Rotate")
                .accessibilityLabel("Crop and Rotate")

                Button(action: {
                    // Turning it on turns the JPG comparison off.
                    session.showSideBySide.toggle()
                }) {
                    Image(systemName: session.showSideBySide ? "square.split.2x1.fill" : "square.split.2x1")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .help("Side-by-side comparison")
                .accessibilityLabel("Side-by-Side Comparison")
                .accessibilityAddTraits(session.showSideBySide ? .isSelected : [])

                if session.isRAW && session.photo.hasRawPair {
                    Button(action: { session.toggleJPGComparison() }) {
                        Image(systemName: session.showJPGComparison ? "photo.on.rectangle.fill" : "photo.on.rectangle")
                            .font(.body)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(session.showJPGComparison ? .blue : .primary)
                    .help("Compare with JPG")
                    .accessibilityLabel("Compare with JPG")
                    .accessibilityAddTraits(session.showJPGComparison ? .isSelected : [])
                }

                if session.canExport {
                    Button(action: { session.presentExportOptions() }) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.body)
                    }
                    .buttonStyle(.plain)
                    .help("Export")
                    .accessibilityLabel("Export")
                }
            }

            HStack(spacing: 8) {
                Button("Reset All") {
                    session.resetAllParameters()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Reset all sliders to zero")

                Button("Revert…") {
                    confirmingRevert = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .help("Revert and clear saved edits")
                .confirmationDialog("Revert to the original?", isPresented: $confirmingRevert, titleVisibility: .visible) {
                    Button("Revert", role: .destructive) { session.revert() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This photo's saved \(session.isRAW ? "RAW" : "JPG") edit is cleared. The file itself doesn't change.")
                }

                if session.canCopyFromJPG {
                    Button("JPG Settings") {
                        session.copyJPGSettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.orange)
                    .help("Copy edit settings from the paired JPG")
                }

                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Sections

    private var lightSection: some View {
        EditSection(title: "Light") {
            EditSlider(label: "Exposure", value: $session.parameters.exposure,
                       range: -5...5, format: "%.1f")
            EditSlider(label: "Highlights", value: $session.parameters.highlights)
            EditSlider(label: "Shadows", value: $session.parameters.shadows)
            EditSlider(label: "Brightness", value: $session.parameters.brightness)
            EditSlider(label: "Contrast", value: $session.parameters.contrast)
        }
    }

    private var colorSection: some View {
        EditSection(title: "Color") {
            EditSlider(label: "Temperature", value: $session.parameters.temperature)
            EditSlider(label: "Tint", value: $session.parameters.tint)
            EditSlider(label: "Saturation", value: $session.parameters.saturation)
            EditSlider(label: "Vibrance", value: $session.parameters.vibrance)
        }
    }

    private var detailSection: some View {
        EditSection(title: "Detail") {
            EditSlider(label: "Sharpness", value: $session.parameters.sharpness,
                       range: 0...100)
            EditSlider(label: "Noise Reduction", value: $session.parameters.noiseReduction,
                       range: 0...100)
            EditSlider(label: "Color NR", value: $session.parameters.colorNoiseReduction,
                       range: 0...100)
        }
    }

    private var effectsSection: some View {
        EditSection(title: "Effects") {
            EditSlider(label: "Clarity", value: $session.parameters.clarity)
            EditSlider(label: "Vignette", value: $session.parameters.vignetteAmount)
        }
    }

    private var rawSection: some View {
        EditSection(title: "RAW") {
            EditSlider(label: "Local Tone Map", value: $session.parameters.localToneMap,
                       range: 0...100)
            EditSlider(label: "Moiré Reduction", value: $session.parameters.moireReduction,
                       range: 0...100)
            Toggle("Lens Correction", isOn: $session.parameters.enableLensCorrection)
                .font(.caption)
                .toggleStyle(.switch)
                .controlSize(.mini)
            Toggle("Gamut Mapping", isOn: $session.parameters.enableGamutMapping)
                .font(.caption)
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }

    private var transformSection: some View {
        EditSection(title: "Transform") {
            EditSlider(label: "Rotation", value: $session.parameters.rotation,
                       range: -45...45, format: "%.1f°")

            HStack(spacing: 12) {
                Button(action: { session.parameters.flipHorizontal.toggle() }) {
                    Label("Flip H", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(session.parameters.flipHorizontal ? .accentColor : nil)

                Button(action: { session.parameters.flipVertical.toggle() }) {
                    Label("Flip V", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(session.parameters.flipVertical ? .accentColor : nil)

                Spacer()

                if !session.parameters.isDefault {
                    Button("Reset Transform") {
                        session.parameters.resetTransform()
                    }
                    .font(.caption)
                    .controlSize(.small)
                }
            }
        }
    }

    private var presetsSection: some View {
        EditSection(title: "Presets") {
            // Save current
            HStack {
                TextField("Preset name", text: $viewModel.presetNameInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .controlSize(.small)
                    .focused($namingPreset)
                    .onSubmit { viewModel.savePreset() }
                    .onChange(of: namingPreset, initial: true) { viewModel.isTypingInContent = namingPreset }
                    .onDisappear { viewModel.isTypingInContent = false }

                Button("Save") {
                    viewModel.savePreset()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.presetNameInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            // Preset list
            if !viewModel.editPresets.isEmpty {
                VStack(spacing: 4) {
                    ForEach(viewModel.editPresets, id: \.id) { preset in
                        HStack {
                            Button(preset.name) {
                                viewModel.applyPreset(preset)
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())

                            Button(action: { viewModel.deletePreset(preset) }) {
                                Image(systemName: "xmark")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Delete the preset “\(preset.name)”")
                            .accessibilityLabel("Delete Preset \(preset.name)")
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 6)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.5)))
                    }
                }
            }
        }
    }

    private var sectionDivider: some View {
        Divider().padding(.vertical, 2)
    }
}

// MARK: - Reusable Components

struct EditSection<Content: View>: View {
    let title: String
    @State private var isExpanded = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
                HStack {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)

            if isExpanded {
                VStack(spacing: 8) {
                    content()
                }
                .padding(.bottom, 8)
            }
        }
    }
}

struct EditSlider: View {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -100...100
    var defaultValue: Double = 0
    var format: String = "%.0f"

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: format, value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(value == defaultValue ? .tertiary : .secondary)
                    .onTapGesture(count: 2) { value = defaultValue }
            }
            // The slider is read out by its label and value; the row above is what it shows.
            .accessibilityHidden(true)

            Slider(value: $value, in: range) { Text(label) }
                .labelsHidden()
                .accessibilityValue(String(format: format, value))
                .accessibilityAction(named: "Reset") { value = defaultValue }
                .controlSize(.small)
                .onTapGesture(count: 2) { value = defaultValue }
        }
    }
}
