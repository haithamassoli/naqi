import Foundation
import Testing
@testable import naqi

/// M6 exit criteria, at the logic level. Three things can quietly break the UI
/// without breaking the build: an options default drifting from the spec, a
/// string that resolves in English and falls back to its key in Arabic, and a
/// slider handing the pipeline a value outside 0…100.
@Suite("UI")
struct UITests {

    // MARK: - FilterOps

    @Test("At least one operation is required")
    func atLeastOneOp() {
        var ops = FilterOps()
        ops.removeMusic = false
        ops.censor = false
        #expect(!ops.isValid)

        ops.censor = true
        #expect(ops.isValid)
        #expect(ops.shape == .censorOnly)

        ops.censor = false
        ops.removeMusic = true
        #expect(ops.isValid)
        #expect(ops.shape == .musicOnly)

        ops.censor = true
        #expect(ops.shape == .both)
    }

    @Test("Defaults are the ones the options screen opens with")
    func defaults() {
        let d = FilterOps()
        #expect(d.removeMusic == false)
        #expect(d.censor == true)
        #expect(d.who == .women)
        #expect(d.censorMode == .regions)
        #expect(d.blurAmount == 60)
        #expect(d.grayscale == false)
        #expect(d.keepStems == .vocals)
        // Spec §1.1 row 4 / analyze §0.20 — Android's `DEFAULT_STRICTNESS`.
        // The gate interpolates its thresholds from this, so a drift here
        // censors differently than Android at default settings.
        #expect(d.strictness == 40)

        // The picker offers two segments, not Android's three: `none` is the
        // step-1 toggle and `everyone` has no UI.
        #expect(FilterOps.Who.userSelectable == [.women, .men])
    }

    @Test("Last-used options round-trip through UserDefaults")
    func roundTrip() {
        let saved = FilterOps.loadLastUsed()
        defer { saved.saveAsLastUsed() }

        var ops = FilterOps()
        ops.removeMusic = true
        ops.censor = true
        ops.who = .men
        ops.censorMode = .wholeFrame
        ops.strictness = 17
        ops.blurAmount = 83
        ops.grayscale = true
        ops.keepStems = .vocalsAndOther
        ops.saveAsLastUsed()

        #expect(FilterOps.loadLastUsed() == ops)
    }

    // MARK: - Sliders

    @Test("Strictness and blur clamp to 0…100")
    func sliderClamp() {
        #expect(clampedSliderValue(-40) == 0)
        #expect(clampedSliderValue(0) == 0)
        #expect(clampedSliderValue(49.4) == 49)
        #expect(clampedSliderValue(49.6) == 50)
        #expect(clampedSliderValue(100) == 100)
        #expect(clampedSliderValue(140) == 100)
        #expect(clampedSliderValue(.nan) == 0)
        #expect(clampedSliderValue(.infinity) == 100)
    }

    // MARK: - Queue binding

    /// The progress and done screens read nothing but `JobMonitor`, so the one
    /// thing that can silently break them is the snapshot stream not reaching
    /// it. A source that cannot be opened fails inside a second and exercises
    /// the whole path: enqueue → run → queue row → observer → `failure`.
    @Test("A failed job reaches the screens through the queue snapshot")
    @MainActor
    func failureReachesTheUI() async throws {
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("naqi-ui-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: store) }

        let monitor = JobMonitor(queue: JobQueue(storeURL: store))
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-video-\(UUID().uuidString).mp4")
        await monitor.start(source: PickedSource(url: missing, name: missing.lastPathComponent),
                            ops: FilterOps())

        var waited = 0
        while monitor.failure == nil, waited < 100 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        #expect(monitor.failure == .sourceUnreadable)
        #expect(monitor.isDone == false)
        #expect(monitor.output == nil)
        // The sentence the failure card puts on screen, not a developer string.
        #expect(String(localized: try #require(monitor.failure).sentence) != "sourceUnreadable")
    }

    // MARK: - Localization

    /// Both localizations must be in the built product. `ar` is missing from
    /// the project's `knownRegions`, and this is the assertion that catches it
    /// if the string catalog ever stops compensating.
    @Test("The app bundle carries both localizations")
    func bundleHasBothLanguages() {
        let langs = Bundle.main.localizations
        #expect(langs.contains("en"))
        #expect(langs.contains("ar"))
    }

    @Test("Every string the UI shows resolves in English and in Arabic",
          arguments: ["en", "ar"])
    func stringsResolve(_ language: String) {
        for resource in Self.everyUIString {
            var localized = resource
            localized.locale = Locale(identifier: language)
            let value = String(localized: localized)
            // A missing key resolves to the key itself, which is the exact
            // failure that made the Arabic translations of Android's eight
            // error sentences unreachable for a whole release.
            #expect(value != resource.key, "\(resource.key) is missing in \(language)")
            #expect(!value.isEmpty, "\(resource.key) is empty in \(language)")
        }
    }

    @Test("Every pipeline stage has a user-visible name", arguments: ["en", "ar"])
    func stageLabels(_ language: String) {
        for stage in Job.Stage.allCases {
            var r = stage.label
            r.locale = Locale(identifier: language)
            #expect(String(localized: r) != r.key)
        }
    }

    @Test("Every failure has a sentence", arguments: ["en", "ar"])
    func failureSentences(_ language: String) {
        let all: [JobFailure] = [.nothingSelected, .drmProtected, .noVideoTrack, .noAudioTrack,
                                 .unsupportedContainer, .unsupportedCodec, .lowSpace,
                                 .outOfSpace, .sourceUnreadable, .publishFailed, .generic]
        for failure in all {
            var r = failure.sentence
            r.locale = Locale(identifier: language)
            #expect(String(localized: r) != r.key)
        }
    }

    /// One of three whole sentences, never a number glued to a unit.
    @Test("durationText picks the right sentence")
    func duration() {
        #expect(durationText(ms: 0).key == "dur_under_min")
        #expect(durationText(ms: 59_000).key == "dur_under_min")
        #expect(durationText(ms: 60_000).key == "dur_min")
        #expect(durationText(ms: 59 * 60_000).key == "dur_min")
        #expect(durationText(ms: 60 * 60_000).key == "dur_h_min")
        #expect(durationText(ms: 155 * 60_000).key == "dur_h_min")
    }

    @Test("File sizes are decimal, not binary")
    func sizes() {
        #expect(fileSizeText(bytes: 999_000_000).key == "jobs_size_mb")
        #expect(fileSizeText(bytes: 1_000_000_000).key == "jobs_size_gb")
    }

    /// Every resource a screen can put on glass. Listed by hand because the
    /// point of the test is the set the UI *uses*, not the set the catalog
    /// happens to contain — an unused key is untidy, a used one that is missing
    /// is a bug on screen.
    static let everyUIString: [LocalizedStringResource] = [
        // Pick
        .appName, .actionMore, .pickSealOnDevice, .pickSealPrivate,
        .pickVideoNone, .pickVideoSelected, .pickVideoChange, .pickVideoFormats,
        .pickSourcePhotos, .pickSourceFiles, .pickDropHint,
        .pickEyebrowChoose, .pickOpMusicTitle, .pickOpMusicDesc,
        .pickOpFacesTitle, .pickOpFacesDesc("Women"), .pickOpFacesDescOff,
        .actionContinue, .pickReassurance,
        .pickWordmarkAr, .pickWordmarkLatin, .pickTagline,
        // Options
        .optTitle, .actionBack, .optSectionCensorFaces,
        .optWhoTitle, .optWhoDesc, .optWhoWomen, .optWhoMen,
        .optWholeFrameTitle, .optWholeFrameDesc,
        .optStrictnessTitle, .optStrictnessDesc,
        .optBlurAmountTitle, .optBlurAmountDesc,
        .optGrayscaleTitle, .optGrayscaleDesc,
        .optSectionRemoveMusic,
        .optKeepVocalsTitle, .optKeepVocalsDesc,
        .optKeepVocalsOtherTitle, .optKeepVocalsOtherDesc,
        .optSliderValue(50), .optEtaFloor("43 min"), .actionStart,
        .dlgLongJobTitle, .dlgLongJobBody("43 min"),
        // Progress
        .progressTitle, .progressKeepOpen, .jobsStageStarting,
        .jobsProgressPercent(33), .jobsEtaRemaining("22 min"), .actionCancel,
        .jobsResumeHint, .actionResume, .jobsNewJob,
        .durUnderMin, .durMin(43), .durHMin(2, 35),
        // Done
        .doneTitle, .jobsSavedLabel, .jobsSavedPhotos, .jobsSavedFolder("Movies"),
        .actionOpen, .actionShare, .actionDeleteOriginal,
        .dlgDeleteOriginalTitle, .dlgDeleteOriginalBody("clip.mp4"),
        .dlgDeleteOriginalFallbackName, .actionDelete, .actionKeep,
        .dlgOriginalDeleted, .dlgOriginalKept, .dlgDeleteOriginalFailed,
        // About + diagnostics
        .aboutOpen, .aboutTitle, .aboutVersion("1.0", 1), .aboutLicense,
        .aboutEyebrowUpdates, .aboutReleasesTitle, .aboutReleasesDesc,
        .pickDiagTitle, .pickDiagRunning, .diagRun, .diagNotRun,
        .diagCores, .diagMemory, .diagCompute,
        // Failure sentences
        .errDrm, .errUnreadable, .errNoVideo, .errNoAudio,
        .errLowSpace, .errUnsupportedCodec, .errOutOfSpace, .errGeneric,
        // Stage names
        .stagePreparing, .stageAnalyzing, .stageRendering,
        .stageSeparating, .stageMuxing,
        // Library
        .jobsLibrary, .jobsLibraryEmpty, .jobsNoneRunning, .jobsTitle,
        .jobsSizeMb(120), .jobsSizeGb(1.7),
    ]
}
