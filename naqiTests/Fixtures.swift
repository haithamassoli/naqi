import Foundation
import Testing

/// Test media. Staged by `scripts/fetch-models.sh` from the Android repo's
/// `qa-assets/`, gitignored the same way the models are.
enum Fixtures {
    static var qaVideo: URL? {
        Bundle(for: BundleToken.self).url(forResource: "test-video", withExtension: "mp4")
    }

    /// Scratch directory for pipeline outputs, wiped per call.
    static func scratch(_ name: String) -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("naqi-tests", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let u = d.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: u)
        return u
    }

    private final class BundleToken {}
}

/// Skips a test when the QA media has not been staged, instead of failing it —
/// the fixtures are gitignored, so a fresh clone legitimately lacks them.
func requireQAVideo() throws -> URL {
    try #require(Fixtures.qaVideo, "run scripts/fetch-models.sh to stage qa-assets")
}
