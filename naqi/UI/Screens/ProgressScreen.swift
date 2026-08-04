import SwiftUI

/// Step 3. One card — the pass strip — carrying the stage label, the percent,
/// the wavy bar and Cancel.
struct ProgressScreen: View {
    @Bindable var flow: Flow

    var body: some View {
        ScrollView {
            ReadableColumn {
                VStack(alignment: .leading, spacing: Naqi.S.s5) {
                    if let name = flow.source?.name {
                        Text(name)
                            .font(Naqi.F.bodyMedium)
                            .foregroundStyle(Naqi.C.onSurfaceVariant)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if let failure = flow.monitor.failure {
                        failureCard(failure)
                    } else {
                        passStrip
                        // iOS has no WorkManager: the job stops when the app
                        // does. Saying so is the honest version of Android's
                        // foreground-service notification.
                        NoteLine(icon: .shield, text: .progressKeepOpen)
                    }
                }
            }
            .padding(.horizontal, Naqi.S.gutter)
            .padding(.top, Naqi.S.s4)
            .padding(.bottom, Naqi.S.s5)
        }
        .background(Naqi.C.background)
        .navigationTitle(Text(.progressTitle))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Naqi.C.background, for: .navigationBar)
        #endif
        // Cancel is the only way back. A back button here would leave a job
        // running with nothing on screen that could stop it.
        .navigationBarBackButtonHidden(true)
        // `task(id:)` and not `onChange`: a short clip can finish before this
        // screen ever appears, and an onChange that never fires would strand
        // the user on a bar reading 100 %.
        .task(id: flow.monitor.isDone) {
            if flow.monitor.isDone { flow.path = [.done] }
        }
    }

    private var passStrip: some View {
        NaqiCard {
            HStack(alignment: .firstTextBaseline, spacing: Naqi.S.s3) {
                Text(flow.monitor.stage?.label ?? .jobsStageStarting)
                    .font(Naqi.F.titleMedium)
                    .foregroundStyle(Naqi.C.onSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(.jobsProgressPercent(Int32(flow.monitor.percent)))
                    .font(Naqi.F.titleMedium)
                    .monospacedDigit()
                    .foregroundStyle(Naqi.C.primary)
            }
            .padding(.bottom, Naqi.S.s3)

            WavyProgress(value: Double(flow.monitor.percent) / 100,
                         animating: flow.monitor.isRunning)
                .padding(.bottom, Naqi.S.s3)

            HStack {
                if flow.monitor.etaMs > 0 {
                    Text(.jobsEtaRemaining(String(localized: durationText(ms: flow.monitor.etaMs))))
                        .font(Naqi.F.bodySmall)
                        .foregroundStyle(Naqi.C.onSurfaceVariant)
                }
                Spacer(minLength: 0)
                Button { Task { await flow.cancelJob() } } label: {
                    Text(.actionCancel)
                        .font(Naqi.F.labelLarge)
                        .foregroundStyle(Naqi.C.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func failureCard(_ failure: JobFailure) -> some View {
        NaqiCard {
            Text(failure.sentence)
                .font(Naqi.F.bodyMedium)
                .foregroundStyle(Naqi.C.error)
                .frame(maxWidth: .infinity, alignment: .leading)

            // The hint and the button appear together or not at all: offering
            // Resume when nothing was checkpointed would restart the film from
            // zero while promising the opposite.
            if flow.monitor.isResumable {
                Text(.jobsResumeHint)
                    .font(Naqi.F.bodySmall)
                    .foregroundStyle(Naqi.C.onSurfaceVariant)
                    .padding(.top, Naqi.S.s2)
                Button { Task { await flow.monitor.resume() } } label: {
                    Text(.actionResume)
                        .font(Naqi.F.labelLarge)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(NaqiPrimaryButtonStyle())
                .padding(.top, Naqi.S.s4)
            }

            Button { Task { await flow.finishAndPickAnother() } } label: {
                Text(.jobsNewJob)
                    .font(Naqi.F.labelLarge)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(NaqiOutlineButtonStyle())
            .padding(.top, Naqi.S.s3)
        }
    }
}
