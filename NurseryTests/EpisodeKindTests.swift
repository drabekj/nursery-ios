import XCTest
@testable import Nursery

/// Přehled: "Pláč" iff the room word was "Pláče"; the old loudness rule only without a classifier.
final class EpisodeKindTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func episode(seconds: TimeInterval, peak: Float, cried: Bool = false, classified: Bool = false) -> SoundActivity.Episode {
        SoundActivity.Episode(id: UUID(), start: t0, end: t0.addingTimeInterval(seconds), peak: peak,
                              soundSeconds: seconds, cried: cried, classified: classified)
    }

    func testCriedIsCry() {
        XCTAssertEqual(episode(seconds: 3, peak: 0.4, cried: true, classified: true).kind, .cry)
    }

    func testClassifiedWithoutCryIsFussEvenWhenLoud() {
        XCTAssertEqual(episode(seconds: 30, peak: 0.95, classified: true).kind, .fuss)
    }

    func testOldRuleWithoutClassifier() {
        XCTAssertEqual(episode(seconds: 12, peak: 0.4).kind, .cry)
        XCTAssertEqual(episode(seconds: 3, peak: 0.8).kind, .cry)
        XCTAssertEqual(episode(seconds: 3, peak: 0.5).kind, .fuss)
    }

    func testOldSavedEventsDecode() throws {
        // An event as 1.9 saved it: no "cried", no "classified".
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","start":1000,"end":1010,"peak":0.5}]"#
        let events = try JSONDecoder().decode([SoundActivity.Event].self, from: Data(json.utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertFalse(events[0].cried)
        XCTAssertFalse(events[0].classified)
        XCTAssertEqual(events[0].duration, 10)
    }

    func testNewEventsRoundTrip() throws {
        let event = SoundActivity.Event(start: t0, end: t0.addingTimeInterval(5), peak: 0.7, cried: true, classified: true)
        let back = try JSONDecoder().decode(SoundActivity.Event.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(back, event)
    }
}
