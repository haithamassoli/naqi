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

    @Test("old share manifests still decode without per-item options")
    func oldManifestDecodes() throws {
        let data = Data("""
            {"id":"1D9F0C8E-4A2B-4E15-9C3D-2F6A1B0E7C41",
             "fileName":"clip.mp4","receivedAt":770000000}
            """.utf8)
        let manifest = try JSONDecoder().decode(ShareManifest.self, from: data)
        #expect(manifest.fileName == "clip.mp4")
        #expect(manifest.options == nil)
    }

    @Test("share options stay attached to their own manifest")
    func manifestCarriesOptions() throws {
        let options = ShareOptions(removeMusic: true, censor: false, who: "everyone")
        let manifest = ShareManifest(id: UUID(), fileName: "clip.mp4",
                                     receivedAt: .now, options: options)
        let decoded = try JSONDecoder().decode(ShareManifest.self,
                                               from: JSONEncoder().encode(manifest))
        #expect(decoded.options == options)
    }

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
    @Test("share sheet remembers its last choices")
    func shareOptionsPersist() {
        let before = ShareOptions.loadLastUsed()
        defer { before.saveAsLastUsed() }
        let options = ShareOptions(removeMusic: true, censor: false, who: "everyone")
        options.saveAsLastUsed()
        #expect(ShareOptions.loadLastUsed() == options)
    }

    @Test("background processing is declared in the built app plist")
    func backgroundProcessingDeclared() {
        let ids = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        #expect(ids?.contains(BackgroundWork.identifier) == true)
        #expect(modes?.contains("processing") == true)
    }

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

    /// The one guard on the share sheet's admission rule.
    ///
    /// A predicate here fails **silently and completely**: a typo, a stale UTI
    /// or a bad `BETWEEN` does not fail the build, logs nothing, and shows up
    /// only as Naqi never appearing in the share sheet. So this reads the
    /// string out of the built `.appex` — not a copy of it — and evaluates it
    /// against the same attachment graph the share sheet supplies.
    @Test("the share extension admits video, audio and links, and nothing else")
    func shareActivationRule() throws {
        let appex = try #require(embedded.first { $0.lastPathComponent == "NaqiShare.appex" })
        let dict = try #require(NSDictionary(contentsOf: appex.appendingPathComponent("Info.plist"))
            as? [String: Any])
        let attrs = try #require((dict["NSExtension"] as? [String: Any])?["NSExtensionAttributes"]
            as? [String: Any])
        let rule = try #require(attrs["NSExtensionActivationRule"] as? String,
                                "the rule is not a predicate string — the dictionary form has no audio key")
        let predicate = NSPredicate(format: rule)

        func shares(_ ids: [String], count: Int = 1) -> Bool {
            predicate.evaluate(with: MockContext([MockItem((0..<count).map { _ in MockAttachment(ids) })]))
        }
        for uti in ["public.mpeg-4", "com.apple.quicktime-movie", "public.mp3",
                    "com.apple.m4a-audio", "com.microsoft.waveform-audio", "org.xiph.flac"] {
            #expect(shares([uti]), "\(uti) should reach the extension")
        }
        for uti in ["public.url", "public.plain-text"] {
            #expect(shares([uti]), "\(uti) should reach the extension as a link")
        }
        for uti in ["com.adobe.pdf", "public.jpeg"] {
            #expect(!shares([uti]), "\(uti) must not reach the extension")
        }
        // The cap is the share-in promise — the app's queue is serial — and it
        // is the part of the dictionary form the predicate had to reproduce.
        #expect(shares(["public.mp3"], count: 10))
        #expect(!shares(["public.mp3"], count: 11))
        #expect(!predicate.evaluate(with: MockContext([MockItem([])])))
    }

    /// The share sheet is the one surface the app's own catalog cannot reach:
    /// `String(localized:)` resolves against `Bundle.main`, which inside an
    /// `.appex` is the `.appex`, so the extension carries its own. A catalog
    /// dropped from the target — or a new string added with no Arabic — shows
    /// the English `defaultValue` and reports nothing anywhere.
    @Test("the share extension ships its strings in both languages")
    func shareStringsLocalized() throws {
        let appex = try #require(embedded.first { $0.lastPathComponent == "NaqiShare.appex" })
        func keys(_ lang: String) -> Set<String> {
            let url = appex.appendingPathComponent("\(lang).lproj/Localizable.strings")
            return Set((NSDictionary(contentsOf: url) as? [String: String] ?? [:]).keys)
        }
        let untranslated = keys("en").subtracting(keys("ar"))
        #expect(!keys("en").isEmpty, "no en.lproj in the appex — the catalog left the NaqiShare target")
        #expect(untranslated.isEmpty, "English-only in the share sheet: \(untranslated.sorted())")
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

// MARK: - Activation-rule mocks

/// What the share sheet evaluates `NSExtensionActivationRule` against. Only the
/// three key paths the predicate walks; `@objc` because NSPredicate reaches them
/// through KVC, which pure-Swift properties do not answer.
private final class MockAttachment: NSObject {
    @objc let registeredTypeIdentifiers: [String]
    init(_ ids: [String]) { registeredTypeIdentifiers = ids }
}

private final class MockItem: NSObject {
    @objc let attachments: [MockAttachment]
    init(_ a: [MockAttachment]) { attachments = a }
}

private final class MockContext: NSObject {
    @objc let extensionItems: [MockItem]
    init(_ i: [MockItem]) { extensionItems = i }
}
