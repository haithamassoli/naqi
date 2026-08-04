import SwiftUI

/// Attribution has to be reachable from the app itself, not only from the
/// repository — GPL-3.0 and an AGPL-3.0 model are not obligations a README
/// discharges.
struct AboutScreen: View {
    var body: some View {
        ScrollView {
            ReadableColumn {
                VStack(alignment: .leading, spacing: Naqi.S.s5) {
                    wordmark
                    NaqiCard {
                        Text(.aboutVersion(Self.shortVersion, Self.build))
                            .font(Naqi.F.bodyMedium)
                            .foregroundStyle(Naqi.C.onSurface)
                        Text(.aboutLicense)
                            .font(Naqi.F.bodySmall)
                            .foregroundStyle(Naqi.C.onSurfaceVariant)
                            .padding(.top, Naqi.S.s2)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        SectionHeader(.aboutEyebrowUpdates)
                        NaqiCard {
                            Text(.aboutReleasesTitle)
                                .font(Naqi.F.titleSmall)
                                .foregroundStyle(Naqi.C.onSurface)
                            Text(.aboutReleasesDesc)
                                .font(Naqi.F.bodySmall)
                                .foregroundStyle(Naqi.C.onSurfaceVariant)
                                .padding(.top, 2)
                        }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        SectionHeader(.pickDiagTitle)
                        NavigationLink(value: Flow.Step.diagnostics) {
                            NaqiCard {
                                Text(.diagRun)
                                    .font(Naqi.F.titleSmall)
                                    .foregroundStyle(Naqi.C.primary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, Naqi.S.gutter)
            .padding(.vertical, Naqi.S.s5)
        }
        .background(Naqi.C.background)
        .navigationTitle(Text(.aboutTitle))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var wordmark: some View {
        VStack(alignment: .leading, spacing: Naqi.S.s2) {
            NaqiMark().fill(Naqi.C.primary).frame(width: 56, height: 56)
            Text(.pickWordmarkAr)
                .font(Naqi.F.display)
                .foregroundStyle(Naqi.C.primary)
            Text(.pickWordmarkLatin)
                .font(Naqi.F.titleMedium)
                .foregroundStyle(Naqi.C.onSurfaceVariant)
            Text(.pickTagline)
                .font(Naqi.F.bodySmall)
                .foregroundStyle(Naqi.C.onSurfaceVariant)
                .padding(.top, Naqi.S.s2)
        }
    }

    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
    static var build: Int32 {
        Int32(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }
}

/// The M0 device-runtime panel: the only way to run the model smoke test on a
/// real phone. It stays reachable from the overflow menu and from About.
struct DeviceRuntimeView: View {
    @State private var results: [ModelSmoke.Result] = []
    @State private var running = false
    @State private var compute: ComputeUnit = .cpu

    var body: some View {
        List {
            Section {
                LabeledContent("CoreML EP", value: Ort.coreMLAvailable ? "available" : "unavailable")
                LabeledContent(String(localized: .diagCores),
                               value: "\(ProcessInfo.processInfo.activeProcessorCount)")
                LabeledContent(String(localized: .diagMemory),
                               value: ByteCountFormatter.string(
                                fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory),
                                countStyle: .memory))
                Picker(String(localized: .diagCompute), selection: $compute) {
                    Text(verbatim: "CPU").tag(ComputeUnit.cpu)
                    Text(verbatim: "CoreML").tag(ComputeUnit.coreML)
                    Text(verbatim: "CoreML−ANE").tag(ComputeUnit.coreMLNoANE)
                }
                .pickerStyle(.segmented)
            }

            Section {
                ForEach(results, id: \.model) { (r: ModelSmoke.Result) in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: r.ok ? "checkmark.seal.fill" : "xmark.octagon.fill")
                                .foregroundStyle(r.ok ? Naqi.C.primary : Naqi.C.error)
                            Text(r.model).font(.headline)
                            Spacer()
                            Text(verbatim: "\(Int(r.loadMs))ms load · \(Int(r.inferMs))ms run")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text(r.error ?? r.detail)
                            .font(.caption.monospaced())
                            .foregroundStyle(r.ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(Naqi.C.error))
                    }
                    .padding(.vertical, 2)
                }
                if results.isEmpty {
                    Text(running ? .pickDiagRunning : .diagNotRun).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(Text(.pickDiagTitle))
        .toolbar {
            Button { run() } label: { Text(running ? .pickDiagRunning : .diagRun) }
                .disabled(running)
        }
        // Deliberately NOT `.task { run() }`. The smoke loads htdemucs, whose
        // session is ~1.3 GB resident for the process lifetime — held while the
        // user is only browsing, and overlapping the first real job's use of
        // the same graph. It also made every media test suite flaky, because
        // the test host runs this view. It stays behind the button.
    }

    private func run() {
        guard !running else { return }
        running = true
        results = []
        let unit = compute
        Task.detached(priority: .userInitiated) {
            let r = ModelSmoke.runAll(compute: unit)
            // The panel is diagnostics, not a job: give the memory straight back.
            ModelRegistry.evict(Models.Demucs.file)
            await MainActor.run { results = r; running = false }
        }
    }
}

extension ComputeUnit: Hashable {}
