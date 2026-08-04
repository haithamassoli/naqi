import Foundation

/// The user-facing job options. Semantics are identical to Android's
/// `model/FilterOps.kt` — see `docs/apple-port/spec-jobs-ui.md`.
struct FilterOps: Codable, Sendable, Equatable {
    var removeMusic: Bool = false
    var censor: Bool = true

    /// Which gender's face tracks get censored.
    var who: Who = .women
    var censorMode: CensorMode = .regions
    /// 0–100. Feeds the NSFW gate thresholds only — never face blur.
    var strictness: Int = 50
    /// 0–100, mapped to a Gaussian sigma scaled to the output's short side.
    var blurAmount: Int = 60
    var grayscale: Bool = false
    var keepStems: KeepStems = .vocals

    /// `everyone` and `none` are not UI options — the PRD's picker is
    /// Women | Men — but they exist because they make the gender vote free:
    /// with either, no track needs a crop, a tensor or a genderage call at all.
    /// Keeping them in the enum lets the analyze pass express that shortcut,
    /// and matches Android's `censorWho`.
    enum Who: String, Codable, Sendable, CaseIterable {
        case women, men, everyone, none

        /// The two the picker offers.
        static var userSelectable: [Who] { [.women, .men] }

        /// True when the verdict is known without running genderage.
        var skipsGenderVote: Bool { self == .everyone || self == .none }
    }
    enum CensorMode: String, Codable, Sendable, CaseIterable { case regions, wholeFrame }
    enum KeepStems: String, Codable, Sendable, CaseIterable {
        case vocals, vocalsAndOther

        /// Stems written into the output. drums/bass are never kept.
        var stems: [Models.Demucs.Stem] {
            switch self {
            case .vocals: [.vocals]
            case .vocalsAndOther: [.vocals, .other]
            }
        }
    }

    /// At least one operation must be selected.
    var isValid: Bool { removeMusic || censor }

    /// The three job shapes have disjoint performance walls, so the pipeline
    /// branches on this rather than on the two flags (`perf-plan-v4.md` §1).
    enum Shape: Sendable, Equatable {
        /// Audio wall. Video is passthrough.
        case musicOnly
        /// Analyze wall. Audio is passthrough.
        case censorOnly
        /// Audio wall (~65 % of total).
        case both
    }

    var shape: Shape {
        switch (removeMusic, censor) {
        case (true, false): .musicOnly
        case (false, true): .censorOnly
        default: .both
        }
    }

    /// Video track can be copied compressed, untouched.
    var videoPassthrough: Bool { !censor }
    /// Audio track can be copied compressed, untouched.
    var audioPassthrough: Bool { !removeMusic }
}

/// Last-used options, preselected on the next run (PRD user flow).
extension FilterOps {
    private static let key = "naqi.filterOps"

    static func loadLastUsed() -> FilterOps {
        guard let d = UserDefaults.standard.data(forKey: key),
              let ops = try? JSONDecoder().decode(FilterOps.self, from: d)
        else { return FilterOps() }
        return ops
    }

    func saveAsLastUsed() {
        guard let d = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(d, forKey: Self.key)
    }
}
