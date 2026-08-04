import SwiftUI

/// Placeholder shell while M1–M4 land. The device-runtime readout is the M0
/// gate made visible: it mirrors Android's DEVICE RUNTIME panel.
struct RootView: View {
    var body: some View {
        NavigationStack {
            DeviceRuntimeView()
        }
    }
}

struct DeviceRuntimeView: View {
    @State private var results: [ModelSmoke.Result] = []
    @State private var running = false
    @State private var compute: ComputeUnit = .cpu

    var body: some View {
        List {
            Section("Runtime") {
                LabeledContent("CoreML EP", value: Ort.coreMLAvailable ? "available" : "unavailable")
                LabeledContent("Cores", value: "\(ProcessInfo.processInfo.activeProcessorCount)")
                LabeledContent("Memory", value: ByteCountFormatter.string(
                    fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory))
                Picker("Compute", selection: $compute) {
                    Text("CPU").tag(ComputeUnit.cpu)
                    Text("CoreML").tag(ComputeUnit.coreML)
                    Text("CoreML−ANE").tag(ComputeUnit.coreMLNoANE)
                }
                .pickerStyle(.segmented)
            }

            Section("Models") {
                ForEach(results, id: \.model) { (r: ModelSmoke.Result) in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: r.ok ? "checkmark.seal.fill" : "xmark.octagon.fill")
                                .foregroundStyle(r.ok ? .green : .red)
                            Text(r.model).font(.headline)
                            Spacer()
                            Text("\(Int(r.loadMs))ms load · \(Int(r.inferMs))ms run")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text(r.error ?? r.detail)
                            .font(.caption.monospaced())
                            .foregroundStyle(r.ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
                    }
                    .padding(.vertical, 2)
                }
                if results.isEmpty && !running {
                    Text("Not run yet").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Naqi · M0")
        .toolbar {
            Button(running ? "Running…" : "Smoke test") { run() }
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

#Preview { RootView() }
