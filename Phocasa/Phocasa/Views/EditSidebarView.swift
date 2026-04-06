import SwiftUI

// MARK: - Edit Sidebar

struct EditSidebarView: View {
    @Bindable var viewModel: PhotoLibraryViewModel

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

                    if viewModel.editingRAW {
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
                Text(viewModel.editingRAW ? "RAW Edit" : "JPG Edit")
                    .font(.headline)
                    .foregroundStyle(viewModel.editingRAW ? .blue : .orange)

                Spacer()

                Button(action: { viewModel.enterCropMode() }) {
                    Image(systemName: "crop")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .help("Crop & Rotate")

                Button(action: {
                    viewModel.showSideBySide.toggle()
                    if viewModel.showSideBySide {
                        viewModel.showJPGComparison = false
                        viewModel.jpgComparisonImage = nil
                    }
                }) {
                    Image(systemName: viewModel.showSideBySide ? "square.split.2x1.fill" : "square.split.2x1")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .help("Side-by-side comparison")

                if viewModel.editingRAW && viewModel.selectedDetailPhoto?.hasRawPair == true {
                    Button(action: { viewModel.toggleJPGComparison() }) {
                        Image(systemName: viewModel.showJPGComparison ? "photo.on.rectangle.fill" : "photo.on.rectangle")
                            .font(.body)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(viewModel.showJPGComparison ? .blue : .primary)
                    .help("Compare with JPG")
                }

                if viewModel.canExport {
                    Button(action: { viewModel.showExportOptions = true }) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.body)
                    }
                    .buttonStyle(.plain)
                    .help("Export")
                }
            }

            HStack(spacing: 8) {
                Button("Reset All") {
                    viewModel.resetAllParameters()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Reset all sliders to zero")

                Button("Revert") {
                    viewModel.revertEdits()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .help("Revert and clear saved edits")

                if viewModel.canCopyFromJPG {
                    Button("JPG Settings") {
                        viewModel.copyJPGSettingsToRAW()
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
            EditSlider(label: "Exposure", value: $viewModel.editParameters.exposure,
                       range: -5...5, format: "%.1f")
            EditSlider(label: "Highlights", value: $viewModel.editParameters.highlights)
            EditSlider(label: "Shadows", value: $viewModel.editParameters.shadows)
            EditSlider(label: "Brightness", value: $viewModel.editParameters.brightness)
            EditSlider(label: "Contrast", value: $viewModel.editParameters.contrast)
        }
    }

    private var colorSection: some View {
        EditSection(title: "Color") {
            EditSlider(label: "Temperature", value: $viewModel.editParameters.temperature)
            EditSlider(label: "Tint", value: $viewModel.editParameters.tint)
            EditSlider(label: "Saturation", value: $viewModel.editParameters.saturation)
            EditSlider(label: "Vibrance", value: $viewModel.editParameters.vibrance)
        }
    }

    private var detailSection: some View {
        EditSection(title: "Detail") {
            EditSlider(label: "Sharpness", value: $viewModel.editParameters.sharpness,
                       range: 0...100)
            EditSlider(label: "Noise Reduction", value: $viewModel.editParameters.noiseReduction,
                       range: 0...100)
            EditSlider(label: "Color NR", value: $viewModel.editParameters.colorNoiseReduction,
                       range: 0...100)
        }
    }

    private var effectsSection: some View {
        EditSection(title: "Effects") {
            EditSlider(label: "Clarity", value: $viewModel.editParameters.clarity)
            EditSlider(label: "Vignette", value: $viewModel.editParameters.vignetteAmount)
        }
    }

    private var rawSection: some View {
        EditSection(title: "RAW") {
            EditSlider(label: "Local Tone Map", value: $viewModel.editParameters.localToneMap,
                       range: 0...100)
            EditSlider(label: "Moiré Reduction", value: $viewModel.editParameters.moireReduction,
                       range: 0...100)
            Toggle("Lens Correction", isOn: $viewModel.editParameters.enableLensCorrection)
                .font(.caption)
                .toggleStyle(.switch)
                .controlSize(.mini)
            Toggle("Gamut Mapping", isOn: $viewModel.editParameters.enableGamutMapping)
                .font(.caption)
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }

    private var transformSection: some View {
        EditSection(title: "Transform") {
            EditSlider(label: "Rotation", value: $viewModel.editParameters.rotation,
                       range: -45...45, format: "%.1f°")

            HStack(spacing: 12) {
                Button(action: { viewModel.editParameters.flipHorizontal.toggle() }) {
                    Label("Flip H", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(viewModel.editParameters.flipHorizontal ? .accentColor : nil)

                Button(action: { viewModel.editParameters.flipVertical.toggle() }) {
                    Label("Flip V", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(viewModel.editParameters.flipVertical ? .accentColor : nil)

                Spacer()

                if !viewModel.editParameters.isDefault {
                    Button("Reset Transform") {
                        viewModel.editParameters.resetTransform()
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

            Slider(value: $value, in: range) { EmptyView() }
                .controlSize(.small)
                .onTapGesture(count: 2) { value = defaultValue }
        }
    }
}
