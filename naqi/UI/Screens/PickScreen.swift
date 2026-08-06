import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import os

/// Step 1. One video, one pair of operations, one promise.
struct PickScreen: View {
    @Bindable var flow: Flow
    #if canImport(UIKit)
    @Environment(\.horizontalSizeClass) private var hSize
    #endif

    @State private var showSourceChoice = false
    @State private var showPhotosPicker = false
    @State private var showFileImporter = false
    @State private var photoItem: PhotosPickerItem?
    @State private var isDropTargeted = false

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
                if wide {
                    HStack(alignment: .top, spacing: Naqi.S.s6) {
                        brandPanel.frame(maxWidth: 300)
                        controls
                    }
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Naqi.S.gutter)
                    .padding(.top, Naqi.S.s5)
                    .padding(.bottom, Naqi.S.s5)
                } else {
                    ReadableColumn {
                        VStack(spacing: 0) {
                            TrustSeal().padding(.bottom, Naqi.S.s5)
                            controls
                        }
                    }
                    .padding(.horizontal, Naqi.S.gutter)
                    .padding(.top, Naqi.S.s2)
                    .padding(.bottom, Naqi.S.s5)
                }
            }
            NaqiBottomAction(title: .actionContinue,
                             enabled: flow.canContinue,
                             action: { flow.path = [.options] }) {
                NoteLine(icon: .check, text: .pickReassurance)
            }
        }
        .background(Naqi.C.background)
        .navigationTitle(Text(.appName))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Naqi.C.background, for: .navigationBar)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: Naqi.S.s1) {
                    NaqiMark().fill(Naqi.C.primary).frame(width: 22, height: 22)
                    Text(.appName)
                        .font(Naqi.F.titleLarge)
                        .foregroundStyle(Naqi.C.onSurface)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { flow.path = [.about] } label: { Text(.aboutOpen) }
                    // The device-runtime panel is how the model smoke test is
                    // run on a real phone; it stays one tap from the first
                    // screen for exactly that reason.
                    Button { flow.path = [.diagnostics] } label: { Text(.pickDiagTitle) }
                } label: {
                    Image(systemName: "ellipsis")
                        .accessibilityLabel(Text(.actionMore))
                }
            }
        }
        // `preferredItemEncoding: .current` is the whole "does the picker hand
        // over the ORIGINAL?" question, and the default does not.
        // `.automatic` lets Photos transcode on the way out — an HEVC or HDR
        // capture arrives as a re-encoded H.264 copy, so the app would filter a
        // generation-lossy source and hand it back as the user's video. This
        // app's promise is that the picture it does not censor is untouched, so
        // it has to be the original bytes.
        .photosPicker(isPresented: $showPhotosPicker, selection: $photoItem,
                      matching: .videos, preferredItemEncoding: .current)
        // The two roots, not a list of containers: `.video`, `.mpeg4Movie` and
        // `.quickTimeMovie` all conform to `.movie`, and `.mp3`, `.wav`,
        // `.mpeg4Audio` and the rest to `.audio`. A bare audio file is a job
        // shape of its own (`Job.shape`, `audioOnly`) — music removal only.
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.movie, .audio]) { result in
            if case .success(let url) = result { flow.adoptFileImport(url) }
        }
        .confirmationDialog(Text(.pickVideoNone), isPresented: $showSourceChoice, titleVisibility: .visible) {
            Button { showPhotosPicker = true } label: { Text(.pickSourcePhotos) }
            Button { showFileImporter = true } label: { Text(.pickSourceFiles) }
            Button(role: .cancel) {} label: { Text(.actionCancel) }
        }
        .onChange(of: photoItem) { adoptPhotoPick() }
    }

    // MARK: - Panels

    private var brandPanel: some View {
        VStack(spacing: Naqi.S.s2) {
            NaqiMark().fill(Naqi.C.primary).frame(width: 56, height: 56)
            Text(.pickWordmarkAr)
                .font(Naqi.F.display)
                .foregroundStyle(Naqi.C.primary)
            // The gap exists because the ن of نقي drops a dot below its
            // baseline and the Latin line would otherwise sit in it.
            Text(.pickWordmarkLatin)
                .font(Naqi.F.titleMedium)
                .foregroundStyle(Naqi.C.onSurfaceVariant)
            Text(.pickTagline)
                .font(Naqi.F.bodySmall)
                .foregroundStyle(Naqi.C.onSurfaceVariant)
                .padding(.top, Naqi.S.s2)
            TrustSeal().padding(.top, Naqi.S.s4)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 0) {
            pickCard
            #if os(macOS)
            // Drag-and-drop is the Mac way in; the card accepts a drop on every
            // platform but only says so where a pointer exists to do it with.
            NoteLine(icon: .video, text: .pickDropHint)
                .padding(.top, Naqi.S.s2)
            #endif
            Spacer().frame(height: Naqi.S.s5)

            SectionHeader(.pickEyebrowChoose)
            operationCard
        }
    }

    /// A wide, unmistakable target that also reports what is picked. Every
    /// colour springs on the `picked` flag.
    private var pickCard: some View {
        let picked = flow.source != nil
        return Button {
            #if os(macOS)
            showFileImporter = true
            #else
            showSourceChoice = true
            #endif
        } label: {
            HStack(spacing: 0) {
                ZStack {
                    RoundedRectangle(cornerRadius: Naqi.R.button)
                        .fill(picked ? Naqi.C.primary : Naqi.C.surfaceContainerHighest)
                    NaqiIcon(picked ? .check : .video)
                        .fill(picked ? Naqi.C.onPrimary : Naqi.C.onSurfaceVariant)
                        .frame(width: 26, height: 26)
                }
                .frame(width: 52, height: 52)
                .padding(.trailing, Naqi.S.s4)

                VStack(alignment: .leading, spacing: 2) {
                    // The filename falls back to a *selected* label, not the
                    // unpicked one: a provider may not expose a display name
                    // and the video is still picked.
                    Group {
                        if let name = flow.source?.name {
                            Text(name)
                        } else {
                            Text(picked ? .pickVideoSelected : .pickVideoNone)
                        }
                    }
                    .font(Naqi.F.titleMedium)
                    .foregroundStyle(Naqi.C.onSurface)
                    .lineLimit(1)
                    .truncationMode(.tail)

                    Text(picked ? .pickVideoChange : .pickVideoFormats)
                        .font(Naqi.F.bodySmall)
                        .foregroundStyle(Naqi.C.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Naqi.S.s4)
            .background(picked ? Naqi.C.primary.opacity(0.08) : Naqi.C.surfaceContainer,
                        in: .rect(cornerRadius: Naqi.R.card))
            .overlay(RoundedRectangle(cornerRadius: Naqi.R.card)
                .strokeBorder(isDropTargeted ? Naqi.C.primary
                              : (picked ? Naqi.C.primary : Naqi.C.outlineVariant),
                              lineWidth: Naqi.Border.emphasis))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(Naqi.spring, value: picked)
        .animation(Naqi.spring, value: isDropTargeted)
        // Returning `false` is the whole rejection: the system slides the item
        // back to where it came from, which is what every Mac app does with a
        // drop it cannot take, and it needs no error state of our own. There is
        // no hover-time filter available — `dropDestination(for: URL.self)`
        // reports `isTargeted` without ever showing the payload — so the target
        // highlights for a PDF and then refuses it.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: isDroppableSource) else { return false }
            flow.adoptFileImport(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    /// One card, two rows — the pair is a single decision about what this run
    /// does, so it is one card and not two.
    ///
    /// An audio file drops to one row. The censor row is *removed* rather than
    /// disabled: unlike the Photos row on Options, which is greyed with a
    /// caption explaining why, there is nothing to explain here beyond "this
    /// file has no picture", which the row's own absence says.
    private var operationCard: some View {
        NaqiCard(padding: 0) {
            ToggleTile(icon: .musicOff,
                       title: .pickOpMusicTitle,
                       desc: .pickOpMusicDesc,
                       isOn: $flow.ops.removeMusic)
            if !flow.isAudioOnly {
                NaqiRowDivider()
                ToggleTile(icon: .shield,
                           title: .pickOpFacesTitle,
                           // The substituted line asserts what IS happening; the
                           // off line describes what turning it on would do. An off
                           // row reading "Women · and flagged scenes." would assert
                           // censoring that is not running.
                           desc: flow.ops.censor
                               ? .pickOpFacesDesc(String(localized: flow.ops.who.label))
                               : .pickOpFacesDescOff,
                           isOn: $flow.ops.censor)
            }
        }
        .animation(Naqi.spring, value: flow.isAudioOnly)
    }

    // MARK: - Photos

    private func adoptPhotoPick() {
        guard let item = photoItem else { return }
        Task {
            do {
                guard let movie = try await item.loadTransferable(type: MovieFile.self) else { return }
                flow.setSource(PickedSource(url: movie.url,
                                            name: movie.url.lastPathComponent,
                                            // Present only when the app has
                                            // library read access; nil is the
                                            // normal case and simply means
                                            // "Delete original" has no target.
                                            assetID: item.itemIdentifier))
            } catch {
                Log.app.error("photos pick failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

#Preview { RootView() }
