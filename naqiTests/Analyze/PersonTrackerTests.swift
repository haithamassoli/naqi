import CoreGraphics
import Foundation
import Testing
@testable import naqi

struct PersonTrackerTests {
    private let size = CGSize(width: 640, height: 640)
    private let body = CGRect(x: 60, y: 60, width: 220, height: 500)
    private let face = CGRect(x: 100, y: 80, width: 100, height: 100)

    @Test("classification survives a hidden face and policy changes preserve evidence")
    func hiddenFaceAndPolicies() throws {
        let tracker = PersonTracker(frameRate: 30)
        let other = CGRect(x: 360, y: 60, width: 220, height: 500)
        let otherFace = CGRect(x: 400, y: 80, width: 100, height: 100)
        for t: Int64 in [0, 33, 66] {
            tracker.onFrame(bodies: [body, other], faces: [face, otherFace], uprightSize: size,
                            ptsMs: t, voter: { $0.left < 0.5 ? -1 : 1 })
        }
        tracker.onFrame(bodies: [body, other], faces: [], uprightSize: size, ptsMs: 100)
        let people = tracker.finish()
        try #require(people.count == 2)
        #expect(people.map(\.classification) == [.female, .male])
        var edl = Edl(personTracks: people, personWho: .women)
        #expect(edl.regions(at: 100).count == 1)
        #expect((edl.regions(at: 100).first?.left ?? 1) < 0.5)
        edl.personWho = .men
        #expect(edl.regions(at: 100).count == 1)
        #expect((edl.regions(at: 100).first?.left ?? 0) > 0.5)
        edl.personWho = .everyone
        #expect(edl.regions(at: 100).count == 2)
        #expect(try Edl.fromJSONData(edl.toJSONData()) == edl)
    }

    @Test("a shot cut at the same position never inherits the previous votes")
    func sceneCut() throws {
        let tracker = PersonTracker(frameRate: 30)
        tracker.onFrame(bodies: [body], faces: [face], uprightSize: size, ptsMs: 0, voter: { _ in 1 })
        tracker.onFrame(bodies: [body], faces: [face], uprightSize: size, ptsMs: 33, voter: { _ in 1 })
        tracker.onFrame(bodies: [body], faces: [face], uprightSize: size, ptsMs: 50, voter: { _ in 1 })
        tracker.onFrame(bodies: [body], faces: [], uprightSize: size, ptsMs: 66, sceneCut: true)
        let people = tracker.finish()
        try #require(people.count == 2)
        #expect(people[0].classification == .male)
        #expect(people[1].classification == .unknown)
        #expect(people[0].shot != people[1].shot)
        #expect(people[0].geometry.endMs < 66)
        #expect(people[1].geometry.startMs == 66)
        #expect(Edl(personTracks: people, personWho: .women).regions(at: 66).count == 1)
    }

    @Test("an ambiguous crossing resets identity, and an unmatched face still gets covered")
    func ambiguityAndFallback() throws {
        let tracker = PersonTracker(frameRate: 30)
        let a = CGRect(x: 100, y: 60, width: 200, height: 500)
        let b = CGRect(x: 300, y: 60, width: 200, height: 500)
        for t: Int64 in [0, 33] {
            tracker.onFrame(bodies: [a, b], faces: [face.offsetBy(dx: 40, dy: 0), face.offsetBy(dx: 240, dy: 0)],
                            uprightSize: size, ptsMs: t, voter: { $0.left < 0.5 ? -1 : 1 })
        }
        tracker.onFrame(bodies: [CGRect(x: 200, y: 60, width: 200, height: 500)], faces: [],
                        uprightSize: size, ptsMs: 66)
        let people = tracker.finish()
        let current = people.filter { $0.geometry.startMs <= 66 && $0.geometry.endMs >= 66 }
        try #require(current.count == 1)
        #expect(current[0].classification == .unknown)

        let fallback = PersonTracker(frameRate: 30)
        fallback.onFrame(bodies: [], faces: [face], uprightSize: size, ptsMs: 0)
        let tracks = fallback.finish()
        #expect(tracks.first?.faceOnly == true)
        for who in FilterOps.Who.userSelectable {
            #expect(Edl(personTracks: tracks, personWho: who).fullFrame(at: 0))
        }
    }

    @Test("short detector gaps stay covered, while an expired track cannot continue forever")
    func boundedHold() throws {
        let tracker = PersonTracker(frameRate: 30)
        tracker.onFrame(bodies: [body], faces: [], uprightSize: size, ptsMs: 0)
        for t: Int64 in [33, 100, 200, 300, 400] {
            tracker.onFrame(bodies: [], faces: [], uprightSize: size, ptsMs: t)
        }
        let edl = Edl(personTracks: tracker.finish(), personWho: .women)
        #expect(edl.regions(at: 200).isEmpty == false)
        #expect(edl.regions(at: 400).isEmpty)
        #expect(try Edl.fromJSONData(Data("{\"faceTracks\":[],\"censorIntervalsMs\":[]}".utf8)).isEmpty)
    }

    @Test("a body containing several faces cannot have its earlier verdict rewritten")
    func severalFacesNeverRewritePast() throws {
        let tracker = PersonTracker(frameRate: 30)
        for t: Int64 in [0, 33, 50] {
            tracker.onFrame(bodies: [body], faces: [face], uprightSize: size, ptsMs: t, voter: { _ in -1 })
        }
        tracker.onFrame(bodies: [body], faces: [face, face.offsetBy(dx: 50, dy: 0)],
                        uprightSize: size, ptsMs: 66)
        for t: Int64 in [99, 132, 165] {
            tracker.onFrame(bodies: [body], faces: [face], uprightSize: size, ptsMs: t, voter: { _ in 1 })
        }
        let bodies = tracker.finish().filter { $0.faceOnly == false }
        try #require(bodies.count == 3)
        #expect(bodies.map(\.classification) == [.female, .unknown, .male])
        #expect(bodies[0].geometry.endMs < 66)
        #expect(bodies[1].geometry.startMs == 66)
        #expect(bodies[1].geometry.endMs < 99)
        #expect(bodies[2].geometry.startMs == 99)
    }

    @Test("one occluded face vote remains unknown in both selective policies")
    func singleVoteNeverSpares() throws {
        let tracker = PersonTracker(frameRate: 30)
        for t: Int64 in [0, 33] {
            tracker.onFrame(bodies: [body], faces: [face], uprightSize: size, ptsMs: t, voter: { _ in 1 })
        }
        let person = try #require(tracker.finish().first)
        #expect(person.maleVotes == 1)
        #expect(person.classification == .unknown)
        #expect(person.shouldCensor(.women))
        #expect(person.shouldCensor(.men))
    }

    @Test("old saved options retain face mode; new options and checkpoint keys include bodies")
    func compatibility() throws {
        let current = FilterOps()
        #expect(current.censorTarget == .person)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        object.removeValue(forKey: "censorTarget")
        let old = try JSONDecoder().decode(FilterOps.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.censorTarget == .face)
        let source = URL(fileURLWithPath: "/tmp/person-policy.mp4")
        #expect(Checkpoint.key(source: source, ops: old) != Checkpoint.key(source: source, ops: current))
    }
}
