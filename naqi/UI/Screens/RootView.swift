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
        .task { run() }
    }

    private func run() {
        guard !running else { return }
        running = true
        results = []
        let unit = compute
        Task.detached(priority: .userInitiated) {
            let r = ModelSmoke.runAll(compute: unit)
            await MainActor.run { results = r; running = false }
        }
    }
}

extension ComputeUnit: Hashable {}

#Preview { RootView() }
