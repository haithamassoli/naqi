import SwiftUI

@main
struct NaqiApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        #if os(macOS)
        .defaultSize(width: 760, height: 820)
        #endif
    }
}
