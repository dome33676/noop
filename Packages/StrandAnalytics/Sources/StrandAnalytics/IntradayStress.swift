import Foundation
import WhoopProtocol

// IntradayStress.swift — a per-MINUTE read of the SAME autonomic stress proxy `DaytimeStress` shows
// per-hour, computed from the day's banked HR + R-R via a sliding trailing window.
//
// ROOT CAUSE this exists to fix: the daily Stress Monitor (`StressModel`, StressView.swift) is built
// from `DailyMetric.restingHr` / `.avgHrv` — NIGHTLY, sleep-session-derived values. It cannot move
// intraday; a workout only ever reaches it via the FOLLOWING night's sleep vitals, a full day later.
// `DaytimeStress` already fixed that at the HOUR grain. This fixes it again at the MINUTE grain, so the
// pinned Today/LiquidToday card's number can move WITHIN the day (including right after a workout),
// not just once a night.
//
// Same math, finer grain, same honesty rules as `DaytimeStress`:
//   • mean HR over a trailing 5-minute window, emitted once a minute      (HR up   = stress)
//   • RMSSD over that same window's clean R-R                            (HRV down = stress)
// z-scored against the day's OWN calm-hour reference — deliberately the SAME reference
// `DaytimeStress.analyze` computes internally (re-derived here from its public `Result.scored` hours,
// see `analyze` below), so an hour point and a minute point are directly comparable on the identical
// 0–3 curve. A bare independent per-minute reference would be far noisier than the hourly one; sharing
// it is what keeps a minute-grain read honest (see `DaytimeStress.daytimeRMSSDScoringEnabled`'s comment
// on how artifact-prone raw daytime R-R is off the wrist).
//
// Motion-gated exactly like `DaytimeStress` (same `activityMaskFraction` / `postActivityShadowBPM`,
// just applied at the finer per-minute bucket): an ambulatory minute is EXERTION, masked rather than
// scored, with a one-bucket post-exercise shadow while HR is still elevated. Once the shadow bucket
// passes, a minute whose HR stays elevated WITHOUT motion scores normally — this is the mechanism that
// lets the score move within minutes of a workout ending, instead of waiting for the next night.
//
// APPROXIMATE and non-clinical, same as `DaytimeStress`: a window with too little signal emits nothing,
// never an invented value.

public enum IntradayStress {

    // MARK: - Tunables

    /// Trailing window width (seconds) for both the HR and RMSSD rolling channels. WHOOP's own
    /// intraday-stress cadence is a rolling window emitted per minute, not a disjoint 60 s bucket — a
    /// bare 60 s window would be far noisier than the hourly `DaytimeStress` read it must stay
    /// comparable to (see `HRVAnalyzer.rollingRmssd`, "#803").
    public static let windowSec: Int = 300
    /// Emission cadence (seconds): one point per minute.
    public static let stepSec: Int = 60
    /// Minimum clean R-R intervals a window needs before its RMSSD is trusted (mirrors
    /// `HRVAnalyzer.rollingRmssd`'s own small-window floor — a 5-minute window legitimately holds far
    /// fewer beats than the nightly `HRVAnalyzer.minBeats`).
    public static let minBeatsPerWindow: Int = 8
    /// Minimum HR samples a window needs before its mean HR is trusted. ~10% duty cycle over the
    /// 5-minute window at ~1 Hz — proportionally the same floor `DaytimeStress.minHourHRSamples` (300
    /// samples / 3600 s ≈ 8%) applies at the hourly grain.
    public static let minSamplesPerWindow: Int = 30

    // MARK: - Output

    /// One minute of the intraday timeline. `level` is the shared 0–3 stress proxy, or nil when the
    /// minute had too little signal to score honestly, or was masked as exertion.
    public struct MinutePoint: Equatable, Sendable {
        /// Wall-clock unix seconds at the RIGHT edge of this minute's trailing window.
        public let ts: Int
        /// Shared 0–3 stress proxy for the minute, or nil when unscored.
        public let level: Double?
        /// Mean HR (bpm) over the trailing window, or nil.
        public let meanHR: Double?
        /// RMSSD (ms) over the trailing window's clean R-R, or nil (too few clean beats).
        public let rmssd: Double?
        /// True when this minute was left unscored because it was AMBULATORY (exertion) — or in the
        /// one-bucket shadow right after — rather than because it lacked signal. Mirrors
        /// `DaytimeStress.HourPoint.maskedForActivity` at the finer grain.
        public let maskedForActivity: Bool

        public var hasData: Bool { level != nil }

        public init(ts: Int, level: Double?, meanHR: Double?, rmssd: Double?, maskedForActivity: Bool = false) {
            self.ts = ts
            self.level = level
            self.meanHR = meanHR
            self.rmssd = rmssd
            self.maskedForActivity = maskedForActivity
        }
    }

    /// The full minute-grain read: the timeline plus the latest point.
    public struct Result: Equatable, Sendable {
        /// The minute timeline, earliest → latest. A masked/unscored minute carries `level == nil`.
        public let minutes: [MinutePoint]
        /// The most recent minute in the timeline (scored or not) — the "right now" reading a pinned
        /// card wants. `current?.level` is nil while the latest minute is exertion-masked or unscored;
        /// callers should fall back to the nightly `StressModel` score in that case rather than show
        /// nothing (mirrors `DaytimeStress`'s own "mask, don't invent" rule one level up).
        public let current: MinutePoint?

        public init(minutes: [MinutePoint], current: MinutePoint?) {
            self.minutes = minutes
            self.current = current
        }

        /// The scored minutes only (level non-nil), in time order.
        public var scored: [MinutePoint] { minutes.filter { $0.level != nil } }

        public static let empty = Result(minutes: [], current: nil)
    }

    // MARK: - Public API

    /// Build the minute-grain intraday stress timeline from a day's banked HR + R-R.
    ///
    /// - Parameters:
    ///   - hr: the day's `[HRSample]` (any order).
    ///   - rr: the day's `[RRInterval]`.
    ///   - gravity: the day's `[GravitySample]`, for the motion gate (see the header). Empty → nothing
    ///     masked, matching `DaytimeStress`'s own degradation when no gravity is available.
    ///   - tzOffsetSeconds: seconds east of UTC — folded through to `DaytimeStress.analyze` so the
    ///     shared calm-hour reference is built on the SAME local waking hours.
    ///
    /// Returns `.empty` when the day has no hourly-scorable stretch to anchor a reference to (the same
    /// gate `DaytimeStress` itself applies), or no minute window qualifies.
    public static func analyze(hr: [HRSample], rr: [RRInterval],
                               gravity: [GravitySample] = [],
                               tzOffsetSeconds: Int = 0) -> Result {
        // The day's own calm-hour reference, IDENTICAL to what `DaytimeStress.analyze` computed
        // internally for this same day — re-derived here from its public `scored` hours (waking,
        // non-ambulatory, count-qualified) via the SAME package-internal helpers, rather than a second,
        // independently-tuned per-minute reference. `scored` already excludes masked/under-gate hours,
        // so it reproduces `DaytimeStress`'s own `referenceAggs` exactly.
        let day = DaytimeStress.analyze(hr: hr, rr: rr, gravity: gravity, tzOffsetSeconds: tzOffsetSeconds)
        guard !day.scored.isEmpty else { return .empty }
        let hrMeans = day.scored.compactMap { $0.meanHR }
        let rmssdVals = day.scored.compactMap { $0.rmssd }
        let refHR = DaytimeStress.calmReference(hrMeans, calmIsLow: true)
        let refRMSSD = DaytimeStress.calmReference(rmssdVals, calmIsLow: false)
        let sdHR = DaytimeStress.std(hrMeans, mean: DaytimeStress.mean(hrMeans))
        let sdRMSSD = DaytimeStress.std(rmssdVals, mean: DaytimeStress.mean(rmssdVals))

        // Two independent rolling channels, same window/step, so a minute point and its RMSSD point
        // share a cadence even though the underlying HR and R-R streams tick at different moments.
        let hrPoints = HRVAnalyzer.rollingMeanHR(hr: hr, windowSec: windowSec, stepSec: stepSec,
                                                 minSamplesPerWindow: minSamplesPerWindow)
        let rmssdPoints = HRVAnalyzer.rollingRmssd(rr: rr, windowSec: windowSec, stepSec: stepSec,
                                                    minBeatsPerWindow: minBeatsPerWindow)
        guard !hrPoints.isEmpty || !rmssdPoints.isEmpty else { return .empty }

        // Floor both channels' timestamps onto the same minute grid so an HR sample and an R-R beat that
        // land a few seconds apart still pair into one minute point, rather than never lining up.
        var hrByBucket: [Int: Double] = [:]
        for p in hrPoints { hrByBucket[DaytimeStress.floorDiv(p.ts, stepSec) * stepSec] = p.meanHR }
        var rmssdByBucket: [Int: Double] = [:]
        for p in rmssdPoints { rmssdByBucket[DaytimeStress.floorDiv(p.ts, stepSec) * stepSec] = p.rmssd }

        // Motion gate at the minute grain — the SAME `WorkoutDetector.activitySeries` + threshold
        // `DaytimeStress` reads at the hourly grain, just bucketed finer, so an active workout minute is
        // masked as exertion rather than suddenly scored as "stress" (see the header).
        var activeFracByBucket: [Int: Double] = [:]
        if !gravity.isEmpty {
            var counts: [Int: (active: Int, total: Int)] = [:]
            for p in WorkoutDetector.activitySeries(gravity) {
                let bucket = DaytimeStress.floorDiv(p.ts, stepSec) * stepSec
                var e = counts[bucket] ?? (0, 0)
                e.total += 1
                if p.intensity > WorkoutDetector.motionThreshold { e.active += 1 }
                counts[bucket] = e
            }
            for (b, e) in counts where e.total > 0 {
                activeFracByBucket[b] = Double(e.active) / Double(e.total)
            }
        }
        func isAmbulatory(_ bucket: Int) -> Bool {
            (activeFracByBucket[bucket] ?? 0) >= DaytimeStress.activityMaskFraction
        }

        let buckets = Set(hrByBucket.keys).union(rmssdByBucket.keys).sorted()
        var points: [MinutePoint] = []
        points.reserveCapacity(buckets.count)
        for b in buckets {
            let meanHR = hrByBucket[b]
            let rmssd = rmssdByBucket[b]
            // Post-exercise shadow: ONE bucket deep, gated on HR not yet back at the calm reference —
            // exactly `DaytimeStress`'s own rule, just at 60 s instead of one hour.
            let shadow = isAmbulatory(b - stepSec)
                && meanHR != nil && refHR != nil && meanHR! > refHR! + DaytimeStress.postActivityShadowBPM
            let masked = meanHR != nil && (isAmbulatory(b) || shadow)
            let level: Double? = (meanHR != nil && !masked)
                ? DaytimeStress.squash(DaytimeStress.rawScore(hr: meanHR, meanHR: refHR, sdHR: sdHR,
                                                               rmssd: rmssd, meanRMSSD: refRMSSD, sdRMSSD: sdRMSSD))
                : nil
            points.append(MinutePoint(ts: b, level: level, meanHR: meanHR, rmssd: rmssd, maskedForActivity: masked))
        }
        guard !points.isEmpty else { return .empty }
        return Result(minutes: points, current: points.last)
    }
}
