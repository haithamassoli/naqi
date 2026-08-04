import AVKit
import SwiftUI

/// Step 4. Where the filtered copy went, and the three things that can be done
/// with it. Deleting the original is opt-in, two-step, and never automatic.
struct DoneScreen: View {
    @Bindable var flow: Flow

    @State private var showPlayer = false
    @State private var showDeleteConfirm = false
    @State private var deleteResult: LocalizedStringResource?

    /// The name the publish actually used — not the job's `title`, which is the
    /// **source** name and would read as the filtered copy's. Available on both
    /// destinations now that the publish records it, including the Photos path
    /// that leaves no file behind to take a name from.
    private var outputName: String? { flow.monitor.outputName }

    /// Only offered when there is something we can actually delete: a photo
    /// library asset, or a file the user imported in place. A Photos pick
    /// without library access hands back a copy in our own container, and
    /// deleting *that* would be a lie.
    private var canDeleteOriginal: Bool {
        guard let source = flow.source else { return false }
        return source.assetID != nil || source.securityScoped
    }

    /// Read off the finished job, not off the picker — the picker is free to
    /// have moved on, and claiming the photo library for a copy that went into
    /// a folder sends the user looking in the wrong app.
    private var savedWhere: LocalizedStringResource {
        if flow.monitor.destination == .userFolder, let folder = flow.monitor.folderName {
            return .jobsSavedFolder(folder)
        }
        return .jobsSavedPhotos
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                ReadableColumn {
                    VStack(alignment: .leading, spacing: Naqi.S.s5) {
                        savedCard
                        if canDeleteOriginal { deleteRow }
                        if let deleteResult {
                            Text(deleteResult)
                                .font(Naqi.F.bodySmall)
                                .foregroundStyle(Naqi.C.onSurfaceVariant)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, Naqi.S.gutter)
                .padding(.top, Naqi.S.s4)
                .padding(.bottom, Naqi.S.s5)
            }
            NaqiBottomAction(title: .jobsNewJob) {
                Task { await flow.finishAndPickAnother() }
            }
        }
        .background(Naqi.C.background)
        .navigationTitle(Text(.doneTitle))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Naqi.C.background, for: .navigationBar)
        #endif
        .navigationBarBackButtonHidden(true)
        .sheet(isPresented: $showPlayer) {
            if let url = flow.monitor.output {
                VideoPlayer(player: AVPlayer(url: url)).ignoresSafeArea()
            }
        }
        .confirmationDialog(Text(.dlgDeleteOriginalTitle),
                            isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button(role: .destructive) { deleteOriginal() } label: { Text(.actionDelete) }
            Button(role: .cancel) { deleteResult = .dlgOriginalKept } label: { Text(.actionKeep) }
        } message: {
            Text(.dlgDeleteOriginalBody(outputName
                ?? String(localized: .dlgDeleteOriginalFallbackName)))
        }
    }

    private var savedCard: some View {
        NaqiCard {
            HStack(spacing: Naqi.S.s3) {
                ZStack {
                    Circle().fill(Naqi.C.primary)
                    NaqiIcon(.check).fill(Naqi.C.onPrimary).frame(width: 20, height: 20)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(.jobsSavedLabel)
                        .font(Naqi.F.titleMedium)
                        .foregroundStyle(Naqi.C.onSurface)
                    Text(savedWhere)
                        .font(Naqi.F.bodySmall)
                        .foregroundStyle(Naqi.C.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let name = outputName {
                Text(name)
                    .font(Naqi.F.bodySmall)
                    .monospaced()
                    .foregroundStyle(Naqi.C.onSurfaceVariant)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, Naqi.S.s3)
            }

            // Open and Share appear only when a shareable file exists.
            if let url = flow.monitor.output {
                HStack(spacing: Naqi.S.s3) {
                    Button { showPlayer = true } label: {
                        Text(.actionOpen)
                            .font(Naqi.F.labelLarge)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(NaqiPrimaryButtonStyle())

                    ShareLink(item: url) {
                        Text(.actionShare)
                            .font(Naqi.F.labelLarge)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(NaqiOutlineButtonStyle())
                }
                .padding(.top, Naqi.S.s4)
            }
        }
    }

    private var deleteRow: some View {
        Button { showDeleteConfirm = true } label: {
            Text(.actionDeleteOriginal)
                .font(Naqi.F.labelLarge)
                .foregroundStyle(Naqi.C.error)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.plain)
        .overlay(RoundedRectangle(cornerRadius: Naqi.R.button)
            .strokeBorder(Naqi.C.outlineVariant, lineWidth: Naqi.Border.hairline))
    }

    private func deleteOriginal() {
        Task {
            // Always reports the outcome. Silently keeping a file the user
            // asked to delete is worse than saying we could not.
            deleteResult = await flow.deleteOriginal() ? .dlgOriginalDeleted : .dlgDeleteOriginalFailed
        }
    }
}
