import SwiftUI
import UniformTypeIdentifiers

/// Step 2. Every control is shown **only when the op it applies to is on** — an
/// option that cannot affect the output would be a lie on screen.
struct OptionsScreen: View {
    @Bindable var flow: Flow
    #if canImport(UIKit)
    @Environment(\.horizontalSizeClass) private var hSize
    #endif

    @State private var showLongJobConfirm = false
    @State private var showFolderPicker = false

    private var wide: Bool {
        #if canImport(UIKit)
        isWideLayout(hSize)
        #else
        true
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Group {
                    if wide && flow.ops.censor && flow.ops.removeMusic {
                        VStack(alignment: .leading, spacing: Naqi.S.s5) {
                            HStack(alignment: .top, spacing: Naqi.S.s5) {
                                censorSection
                                musicSection
                            }
                            // Full width under the two columns, not a third
                            // one: it is one short card and a column of its own
                            // would leave a hole beside it on every shape.
                            destinationSection
                        }
                        .frame(maxWidth: 860)
                    } else {
                        ReadableColumn {
                            VStack(alignment: .leading, spacing: Naqi.S.s5) {
                                if flow.ops.censor { censorSection }
                                if flow.ops.removeMusic { musicSection }
                                destinationSection
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Naqi.S.gutter)
                .padding(.top, Naqi.S.s4)
                .padding(.bottom, Naqi.S.s5)
            }

            NaqiBottomAction(title: .actionStart,
                             enabled: flow.canStart,
                             action: startTapped) {
                // 0 means "too early to say" and the line is hidden entirely
                // rather than showing a number.
                if flow.estimateMs > 0 {
                    Text(.optEtaFloor(String(localized: durationText(ms: flow.estimateMs))))
                        .font(Naqi.F.bodySmall)
                        .foregroundStyle(Naqi.C.onSurfaceVariant)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(Naqi.C.background)
        .navigationTitle(Text(.optTitle))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Naqi.C.background, for: .navigationBar)
        #endif
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { flow.setFolder(url) }
        }
        // Placed in front of any permission dance so the user is never asked
        // for something only to then back out (spec §7.3). It is a warning,
        // never a cap: confirming lands exactly where a short job's Start does.
        .confirmationDialog(Text(.dlgLongJobTitle),
                            isPresented: $showLongJobConfirm,
                            titleVisibility: .visible) {
            Button { Task { await flow.start() } } label: { Text(.actionStart) }
            Button(role: .cancel) {} label: { Text(.actionCancel) }
        } message: {
            Text(.dlgLongJobBody(String(localized: durationText(ms: flow.estimateMs))))
        }
    }

    private func startTapped() {
        if flow.estimateMs > Eta.confirmThresholdMs {
            showLongJobConfirm = true
        } else {
            Task { await flow.start() }
        }
    }

    // MARK: - Censor

    private var censorSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(.optSectionCensorFaces)
            NaqiCard(padding: 0) {
                whoRow
                NaqiRowDivider()
                // Directly under Who: the other "how much gets covered"
                // decision. `regions` is off, `wholeFrame` is on.
                ToggleTile(icon: nil,
                           title: .optWholeFrameTitle,
                           desc: .optWholeFrameDesc,
                           isOn: Binding(get: { flow.ops.censorMode == .wholeFrame },
                                         set: { flow.ops.censorMode = $0 ? .wholeFrame : .regions }))
                NaqiRowDivider()
                SliderRow(title: .optStrictnessTitle,
                          desc: .optStrictnessDesc,
                          value: $flow.ops.strictness)
                NaqiRowDivider()
                SliderRow(title: .optBlurAmountTitle,
                          desc: .optBlurAmountDesc,
                          value: $flow.ops.blurAmount)
                NaqiRowDivider()
                ToggleTile(icon: nil,
                           title: .optGrayscaleTitle,
                           desc: .optGrayscaleDesc,
                           isOn: $flow.ops.grayscale)
            }
        }
    }

    /// Two segments, not three. `NONE` is the step-1 toggle, and an "Off"
    /// segment here would be a control that turns off the card containing it.
    private var whoRow: some View {
        VStack(alignment: .leading, spacing: Naqi.S.s2) {
            Text(.optWhoTitle)
                .font(Naqi.F.titleSmall)
                .foregroundStyle(Naqi.C.onSurface)
            Text(.optWhoDesc)
                .font(Naqi.F.bodySmall)
                .foregroundStyle(Naqi.C.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 0) {
                ForEach(FilterOps.Who.userSelectable, id: \.self) { who in
                    let selected = flow.ops.who == who
                    Button {
                        withAnimation(Naqi.spring) { flow.ops.who = who }
                    } label: {
                        Text(who.label)
                            .font(Naqi.F.titleSmall)
                            .foregroundStyle(selected ? Naqi.C.onPrimary : Naqi.C.onSurfaceVariant)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(selected ? Naqi.C.primary : .clear, in: .capsule)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(3)
            .background(Naqi.C.surfaceContainerHighest, in: .capsule)
        }
        .padding(.horizontal, Naqi.S.s4)
        .padding(.vertical, Naqi.S.s3)
    }

    // MARK: - Destination

    /// The one section that is shown on every shape: unlike the op sections
    /// above, "where does the copy go" is a decision every job has.
    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(.optSectionSaveTo)
            NaqiCard(padding: 0) {
                SelectRow(title: .optDestPhotosTitle,
                          desc: .optDestPhotosDesc,
                          isSelected: flow.destination == .photos) {
                    withAnimation(Naqi.spring) { flow.setDestination(.photos) }
                }
                // Disabled rather than hidden: a row that vanishes teaches
                // nothing, and the caption under the card says why this one
                // cannot be picked.
                .disabled(flow.mustUseFolder)
                .opacity(flow.mustUseFolder ? 0.4 : 1)

                NaqiRowDivider()

                SelectRow(title: .optDestFolderTitle,
                          desc: flow.export.folderName
                              .map { LocalizedStringResource.optDestFolderChosen($0) }
                              ?? .optDestFolderDesc,
                          isSelected: flow.destination == .userFolder) {
                    // Tapping the row that is already chosen re-opens the
                    // picker: it is the only way to change folders, and a
                    // second control on a two-row card would be a third tap
                    // target for a once-a-year action.
                    if flow.destination == .userFolder || flow.export.folder == nil {
                        showFolderPicker = true
                    } else {
                        withAnimation(Naqi.spring) { flow.setDestination(.userFolder) }
                    }
                }
            }
            if flow.mustUseFolder {
                Text(.optDestAudioOnly)
                    .font(Naqi.F.bodySmall)
                    .foregroundStyle(Naqi.C.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Naqi.S.s2)
                    .padding(.horizontal, Naqi.S.s1)
            }
        }
        .animation(Naqi.spring, value: flow.mustUseFolder)
    }

    // MARK: - Music

    /// The two wire values are `vocals` / `vocalsAndOther`; drums and bass are
    /// never kept whichever is picked.
    private var musicSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(.optSectionRemoveMusic)
            NaqiCard(padding: 0) {
                SelectRow(title: .optKeepVocalsTitle,
                          desc: .optKeepVocalsDesc,
                          isSelected: flow.ops.keepStems == .vocals) {
                    withAnimation(Naqi.spring) { flow.ops.keepStems = .vocals }
                }
                NaqiRowDivider()
                SelectRow(title: .optKeepVocalsOtherTitle,
                          desc: .optKeepVocalsOtherDesc,
                          isSelected: flow.ops.keepStems == .vocalsAndOther) {
                    withAnimation(Naqi.spring) { flow.ops.keepStems = .vocalsAndOther }
                }
            }
        }
    }
}
