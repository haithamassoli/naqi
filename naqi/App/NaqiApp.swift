import SwiftUI

@main
struct NaqiApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                // The share extension leaves manifests in the App Group
                // container; the app is the only thing that can enqueue them.
                // Draining on every activation and not only at launch is what
                // makes a share that arrives while the app is already open show
                // up without the user relaunching it.
                .task { await ShareInbox.drain(into: .shared) }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await ShareInbox.drain(into: .shared) }
                }
        }
        #if os(macOS)
        .defaultSize(width: 760, height: 820)
        #endif
    }
}
