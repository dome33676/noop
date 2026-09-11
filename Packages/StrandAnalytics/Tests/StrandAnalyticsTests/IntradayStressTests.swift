import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class IntradayStressTests: XCTestCase {

    /// 1 Hz HR samples filling `[startTs, startTs + seconds)` at a constant bpm.
    private func hr1Hz(from startTs: Int, seconds: Int, bpm: Int) -> [HRSample] {
        (0..<seconds).map { HRSample(ts: startTs + $0, bpm: bpm) }
    }

    /// Gravity samples filling `[startTs, startTs + seconds)`, all clearing
    /// `WorkoutDetector.motionThreshold` (alternating step mirrors `DaytimeStressTests.hourGravity`).
    private func ambulatoryGravity(from startTs: Int, seconds: Int, stepSec: Int = 5) -> [GravitySample] {
        let n = max(1, seconds / stepSec)
        return (0..<n).map { i in
            let x = i % 2 == 0 ? 0.5 : 0.0
            return GravitySample(ts: startTs + i * stepSec, x: x, y: 0, z: 1)
        }
    }

    func testEmptyWhenNoHR() {
        XCTAssertEqual(IntradayStress.analyze(hr: [], rr: []), .empty)
    }

    func testEmptyWhenDayHasNoHourlyReference() {
        // Too little HR for even one DaytimeStress hour to qualify → no reference to score minutes against.
        let hr = hr1Hz(from: 8 * 3_600, seconds: DaytimeStress.minHourHRSamples - 1, bpm: 65)
        XCTAssertEqual(IntradayStress.analyze(hr: hr, rr: []), .empty)
    }

    /// Root-cause regression (#complaint-3): a workout followed by elevated-but-non-ambulatory HR must
    /// move the score WITHIN the same session — not only via the following night's sleep vitals. Three
    /// calm hours (08:00-11:00) anchor the reference; hour 11:00 opens with a 10-minute ambulatory
    /// "workout" (masked, not scored) and closes with 50 minutes of HR that stays high with NO motion —
    /// the shape the shadow-then-score behaviour is meant to catch.
    func testScoreMovesWithinSessionAfterWorkout() {
        var hr: [HRSample] = []
        hr += hr1Hz(from: 8 * 3_600, seconds: 3_600, bpm: 62)
        hr += hr1Hz(from: 9 * 3_600, seconds: 3_600, bpm: 60)
        hr += hr1Hz(from: 10 * 3_600, seconds: 3_600, bpm: 61)
        let workoutStart = 11 * 3_600
        hr += hr1Hz(from: workoutStart, seconds: 600, bpm: 140)                 // the workout, 10 min
        hr += hr1Hz(from: workoutStart + 600, seconds: 3_000, bpm: 115)         // elevated, no motion after

        let gravity = ambulatoryGravity(from: workoutStart, seconds: 600)       // motion ONLY during the workout

        let r = IntradayStress.analyze(hr: hr, rr: [], gravity: gravity)
        XCTAssertFalse(r.minutes.isEmpty)

        // A minute inside the workout window is masked as exertion, not scored as stress.
        let duringWorkout = r.minutes.first { $0.ts >= workoutStart && $0.ts < workoutStart + 600 }
        XCTAssertNotNil(duringWorkout)
        XCTAssertNil(duringWorkout?.level, "an ambulatory minute must not be scored")
        XCTAssertTrue(duringWorkout?.maskedForActivity ?? false)

        // The LATEST minute — well past the workout and its one-bucket shadow, HR still elevated with no
        // motion — must be SCORED (not masked) and read clearly above baseline (1.5), proving the pinned
        // card's number can move within the day instead of waiting for the next night's sleep.
        guard let current = r.current else { return XCTFail("expected a current minute") }
        XCTAssertFalse(current.maskedForActivity, "recovered HR with no motion is stress, not exertion")
        guard let level = current.level else { return XCTFail("the current minute should be scored") }
        XCTAssertGreaterThan(level, 2.0, "sustained elevated HR with no motion should read as HIGH")
        XCTAssertEqual(current.ts, r.minutes.last?.ts)
    }

    func testNoGravityMeansNothingMasked() {
        // Degradation contract mirrors DaytimeStress: with no motion channel, an elevated-HR stretch
        // scores as stress rather than being silently withheld.
        var hr: [HRSample] = []
        hr += hr1Hz(from: 8 * 3_600, seconds: 3_600, bpm: 62)
        hr += hr1Hz(from: 9 * 3_600, seconds: 3_600, bpm: 60)
        hr += hr1Hz(from: 10 * 3_600, seconds: 3_600, bpm: 61)
        hr += hr1Hz(from: 11 * 3_600, seconds: 3_600, bpm: 130)

        let r = IntradayStress.analyze(hr: hr, rr: [])
        XCTAssertFalse(r.minutes.contains { $0.maskedForActivity })
        guard let level = r.current?.level else { return XCTFail("expected a scored current minute") }
        XCTAssertGreaterThan(level, 2.0)
    }
}
