import SwiftUI

@main
struct NaqiApp: App {
    var body: some Scene {
        WindowGroup {
            // The share-inbox drain lives in `RootView` and not here because it
            // needs the destination the user last chose, and `Flow` is what
            // holds it: `ExportTarget.loadLastUsed()` opens a security scope it
            // never closes, so calling it again on every foreground would leak
            // one sandbox extension per activation.
            RootView()
        }
        #if os(macOS)
        .defaultSize(width: 760, height: 820)
        #endif
    }
}
