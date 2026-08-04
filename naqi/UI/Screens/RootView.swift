import SwiftUI

/// Pick → Options → Progress → Done, plus two leaf screens off the overflow
/// menu. A straight line does not need a route graph; `path` is an array so a
/// step can replace the stack rather than push onto it — starting a job must
/// not leave Options behind a back button that would re-enqueue it.
struct RootView: View {
    @State private var flow = Flow()

    var body: some View {
        NavigationStack(path: $flow.path) {
            PickScreen(flow: flow)
                .navigationDestination(for: Flow.Step.self) { step in
                    switch step {
                    case .options: OptionsScreen(flow: flow)
                    case .progress: ProgressScreen(flow: flow)
                    case .done: DoneScreen(flow: flow)
                    case .about: AboutScreen()
                    case .diagnostics: DeviceRuntimeView()
                    }
                }
        }
        .tint(Naqi.C.primary)
        #if DEBUG
        .task { flow.seedFromLaunchArguments() }
        #endif
        // Last-used options are what the next run opens with, so every change
        // is persisted as it happens rather than only on Start — a user who
        // backs out of Options still changed their mind.
        .onChange(of: flow.ops) { flow.ops.saveAsLastUsed() }
    }
}

#Preview { RootView() }
