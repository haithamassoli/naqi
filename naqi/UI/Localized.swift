import Foundation

/// Picks **one of three whole sentences** and never glues a number to a unit.
/// Arabic keeps its own digits, word order and unit words, which no
/// `"\(n) min"` can produce (spec contract 6.7.4.1).
func durationText(ms: Int64) -> LocalizedStringResource {
    let minutes = ms / 60_000
    if minutes < 1 { return .durUnderMin }
    if minutes < 60 { return .durMin(Int32(minutes)) }
    return .durHMin(Int32(minutes / 60), Int32(minutes % 60))
}

/// Decimal, not binary — the same rule the Android library rows use.
func fileSizeText(bytes: Int64) -> LocalizedStringResource {
    bytes >= 1_000_000_000
        ? .jobsSizeGb(Float(bytes) / 1e9)
        : .jobsSizeMb(Float(bytes) / 1e6)
}

extension FilterOps.Who {
    var label: LocalizedStringResource {
        switch self {
        case .women: .optWhoWomen
        case .men: .optWhoMen
        // Neither is offered by the picker — the analyze pass uses them as
        // shortcuts — but a value persisted by a debug run must not render as
        // a blank segment.
        case .everyone: .optWhoWomen
        case .none: .optWhoMen
        }
    }
}

extension Job.Stage {
    /// Five user-visible stage names cover six pipeline stages: `concat` and
    /// `publish` are both "Finishing up". Naming the copy into Photos would
    /// mean explaining why a file that is already filtered is still moving.
    var label: LocalizedStringResource {
        switch self {
        case .analyze: .stageAnalyzing
        case .render: .stageRendering
        case .separate: .stageSeparating
        case .mux, .concat, .publish: .stageMuxing
        }
    }
}

extension JobFailure {
    /// One sentence per case. An unrecognised cause has already resolved to
    /// `.generic` in `JobFailure.of` — the throwable's own message never
    /// reaches the screen as untranslated developer text.
    var sentence: LocalizedStringResource {
        switch self {
        case .drmProtected: .errDrm
        case .noVideoTrack: .errNoVideo
        case .noAudioTrack: .errNoAudio
        case .unsupportedContainer, .sourceUnreadable: .errUnreadable
        case .unsupportedCodec: .errUnsupportedCodec
        case .lowSpace: .errLowSpace
        case .outOfSpace: .errOutOfSpace
        // Neither is reachable from the UI's own guards — Start is disabled
        // without an operation, and a publish failure has no sentence the user
        // can act on — so both land on the generic line rather than inventing
        // copy for a state the user cannot fix.
        case .nothingSelected, .publishFailed, .generic: .errGeneric
        }
    }
}
