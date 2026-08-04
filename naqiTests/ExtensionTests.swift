import Foundation
import Testing
@testable import naqi
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

/// Guards the three things that can regress in `project.pbxproj` without
/// breaking the build, without failing a single other test, and without
/// producing any runtime error — the app just quietly stops doing something.
///
/// Every one of these was a real no-op in this repo before the targets landed:
/// the share inbox drained a container that could not exist, and
/// `LiveActivity.start` returned at its first guard on every call.
@Suite("Extensions")
struct ExtensionTests {

    /// The `.appex` bundles the app carries. `naqiTests.xctest` lands in the
    /// same folder, hence the filter.
    private var embedded: [URL] {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let all = try? FileManager.default.contentsOfDirectory(
                at: plugins, includingPropertiesForKeys: nil)
        else { return [] }
        return all.filter { $0.pathExtension == "appex" }
    }

    #if os(iOS)
    @Test("both extensions are embedded with a loadable NSExtension dict")
    func extensionsEmbedded() throws {
        let names = Set(embedded.map { $0.deletingPathExtension().lastPathComponent })
        #expect(names.contains("NaqiShare"), "share extension not embedded — share-in cannot work")
        #expect(names.contains("NaqiWidgets"), "widget extension not embedded — no Live Activity can render")

        for appex in embedded {
            let plist = appex.appendingPathComponent("Info.plist")
            let dict = try #require(NSDictionary(contentsOf: plist) as? [String: Any])
            let ext = try #require(dict["NSExtension"] as? [String: Any],
                                   "\(appex.lastPathComponent) has no NSExtension dict")
            // installd rejects the *whole app* over either of these, and the
            // message names the wrong key when it does.
            #expect(ext["NSExtensionPointIdentifier"] as? String != nil)
            if ext["NSExtensionPointIdentifier"] as? String == "com.apple.share-services" {
                let principal = ext["NSExtensionPrincipalClass"] as? String
                #expect(principal == "NaqiShare.ShareViewController",
                        "principal class must be Module.Class; got \(principal ?? "nil")")
                #expect(ext["NSExtensionMainStoryboard"] == nil,
                        "an empty NSExtensionMainStoryboard is not an absent one — installd rejects it")
            }
        }
    }

    /// The App Group is the entire share-in transport. Nil container means every
    /// drain returns 0 forever and nothing anywhere reports a problem.
    @Test("the App Group container resolves")
    func appGroupResolves() {
        #expect(AppGroup.container != nil,
                "no container for \(AppGroup.identifier) — entitlement or group id regressed")
        #expect(AppGroup.defaults != nil, "shared defaults unavailable; share-in would lose last-used options")
    }
    #endif

    #if canImport(ActivityKit) && os(iOS)
    /// `areActivitiesEnabled` is false when `NSSupportsLiveActivities` is absent
    /// from the *app's* Info.plist, which is generated from build settings and
    /// so has no file to review. `LiveActivity.start` guards on exactly this
    /// value, so a regression here silently removes the progress surface.
    @Test("Live Activities are enabled for this app")
    func liveActivitiesEnabled() throws {
        let declared = Bundle.main.object(forInfoDictionaryKey: "NSSupportsLiveActivities") as? Bool
        #expect(declared == true, "NSSupportsLiveActivities missing from the app Info.plist")
        #expect(ActivityAuthorizationInfo().areActivitiesEnabled,
                "activities disabled — either the plist key or the widget target regressed")
    }
    #endif
}
