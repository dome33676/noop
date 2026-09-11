import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Stress Intraday Chart (scrubbable per-minute line, complaint #4)
//
// A purpose-built, SIMPLER scrub chart than `StrandDesign.OverviewHRChart` — no workout/sleep spans, no
// multi-day zoom/pan, just one day's per-minute stress line, drawn the same way `DaytimeLoadLine`
// already draws the hourly one (GeometryReader + Path, the WHOOP blue→green→amber `StressRamp`
// gradient), extended with a drag gesture that snaps to the nearest minute and shows the exact value +
// time under the finger. Feature-scoped (Strand/Screens, not shared StrandDesign) per the ground rules —
// `OverviewHRChart` is a shared file other concurrent tasks may also touch.

struct StressIntradayChart: View {
    let minutes: [IntradayStress.MinutePoint]

    /// The touch/pointer x while actively scrubbing; nil when not touching the chart.
    @State private var dragX: CGFloat?

    private let chartHeight: CGFloat = 140
    private let bubbleWidth: CGFloat = 96

    private struct PlotPoint {
        let x: CGFloat
        let y: CGFloat
        let ts: Int
        let level: Double
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            // x by the minute's actual TIME position across the day's covered span (not its array
            // index), so a masked/no-data gap in the minute grid still reads at its true time instead of
            // being compressed toward its neighbours.
            let lo = minutes.first?.ts ?? 0
            let hi = minutes.last?.ts ?? (lo + 1)
            let span = max(1, hi - lo)
            let x: (Int) -> CGFloat = { ts in w * CGFloat(ts - lo) / CGFloat(span) }
            let y: (Double) -> CGFloat = { level in h - h * CGFloat(min(max(level / 3.0, 0), 1)) }

            let pts: [PlotPoint] = minutes.compactMap { m in
                m.level.map { PlotPoint(x: x(m.ts), y: y($0), ts: m.ts, level: $0) }
            }

            ZStack(alignment: .topLeading) {
                // Baseline (1.5 of 3) reference line — same convention as DaytimeLoadLine.
                Path { p in
                    let yb = y(1.5)
                    p.move(to: CGPoint(x: 0, y: yb))
                    p.addLine(to: CGPoint(x: w, y: yb))
                }
                .stroke(StrandPalette.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                if pts.count >= 2 {
                    areaPath(pts, width: w, height: h)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    StressRamp.calm.opacity(0.20),
                                    StressRamp.calm.opacity(0.02),
                                ]),
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                    linePath(pts)
                        .stroke(
                            LinearGradient(gradient: StressRamp.gradient, startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                        )
                } else if let only = pts.first {
                    Circle()
                        .fill(StressRamp.color(only.level))
                        .frame(width: 6, height: 6)
                        .position(x: only.x, y: only.y)
                }

                // Scrub playhead + floating readout bubble, snapped to the nearest SCORED minute.
                if let dragX, let nearest = nearestPoint(to: dragX, in: pts) {
                    Path { p in
                        p.move(to: CGPoint(x: nearest.x, y: 0))
                        p.addLine(to: CGPoint(x: nearest.x, y: h))
                    }
                    .stroke(StrandPalette.textTertiary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))

                    Circle()
                        .fill(StressRamp.color(nearest.level))
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                        .position(x: nearest.x, y: nearest.y)

                    readoutBubble(nearest, chartWidth: w)
                }
            }
            // Explicit frame: Path-only children have no intrinsic size, so without this the gesture's
            // hit-testing region would not reliably cover the full w × h the point math above assumes.
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            // minimumDistance: 0 so a tap-and-hold pins the readout immediately, matching the "hold to
            // read" touch-scrub idiom `OverviewHRChart`/FullDayChartView already teach elsewhere.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in dragX = min(max(value.location.x, 0), w) }
                    .onEnded { _ in dragX = nil }
            )
        }
        .frame(height: chartHeight)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private func nearestPoint(to x: CGFloat, in pts: [PlotPoint]) -> PlotPoint? {
        pts.min { abs($0.x - x) < abs($1.x - x) }
    }

    private func readoutBubble(_ p: PlotPoint, chartWidth: CGFloat) -> some View {
        let label = "\(String(format: "%.1f", p.level)) · \(timeLabel(p.ts))"
        // Clamp so the bubble never clips past either edge of the chart.
        let centerX = min(max(p.x, bubbleWidth / 2), chartWidth - bubbleWidth / 2)
        return Text(label)
            .font(StrandFont.captionNumber)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(StressRamp.color(p.level)))
            .fixedSize()
            .position(x: centerX, y: max(14, p.y - 20))
    }

    /// Locale-aware "HH:mm" / "h:mm a" — matches `StressView.hourLabel`'s device-locale approach rather
    /// than a hard-coded 24-hour format.
    private func timeLabel(_ ts: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts)).formatted(.dateTime.hour().minute())
    }

    private func linePath(_ pts: [PlotPoint]) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: CGPoint(x: first.x, y: first.y))
        for i in 1..<pts.count {
            let prev = pts[i - 1]
            let cur = pts[i]
            let midX = (prev.x + cur.x) / 2
            path.addCurve(
                to: CGPoint(x: cur.x, y: cur.y),
                control1: CGPoint(x: midX, y: prev.y),
                control2: CGPoint(x: midX, y: cur.y)
            )
        }
        return path
    }

    private func areaPath(_ pts: [PlotPoint], width: CGFloat, height: CGFloat) -> Path {
        var path = linePath(pts)
        if let last = pts.last, let first = pts.first {
            path.addLine(to: CGPoint(x: last.x, y: height))
            path.addLine(to: CGPoint(x: first.x, y: height))
            path.closeSubpath()
        }
        return path
    }

    private var accessibilitySummary: String {
        let scored = minutes.compactMap { m in m.level.map { (m.ts, $0) } }
        guard !scored.isEmpty else { return String(localized: "No minute-level stress data yet for this day.") }
        guard let first = scored.first, let last = scored.last else {
            return String(localized: "No minute-level stress data yet for this day.")
        }
        return String(localized: "Minute-by-minute stress from \(timeLabel(first.0)) to \(timeLabel(last.0)), latest \(String(format: "%.1f", last.1)).")
    }
}

#if DEBUG
#Preview("Stress Intraday Chart") {
    let base = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970) + 8 * 3_600
    let minutes: [IntradayStress.MinutePoint] = (0..<180).map { i in
        let ts = base + i * 60
        if i >= 40 && i < 55 {
            return IntradayStress.MinutePoint(ts: ts, level: nil, meanHR: 138, rmssd: nil, maskedForActivity: true)
        }
        let curve = 1.4 + 1.1 * sin(Double(i) / 22.0)
        return IntradayStress.MinutePoint(ts: ts, level: min(max(curve, 0), 3), meanHR: 64, rmssd: 38)
    }
    return StressIntradayChart(minutes: minutes)
        .padding()
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
}
#endif
