import SwiftUI
import Charts

// MARK: - Distanz (Hero) mit kumuliertem Vergleich

struct HeroCard: View {
    let stats: PeriodStats
    @State private var hoverDate: Date?

    private let currentName = "Dieser Zeitraum"
    private let previousName = "Zeitraum davor"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Distanz · \(stats.range.caption)")
                        .font(.subheadline)
                        .foregroundStyle(Palette.ink2)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Fmt.num(stats.totals.distance, 2))
                            .font(.system(size: 56, weight: .semibold))
                            .contentTransition(.numericText(value: stats.totals.distance))
                        Text("km")
                            .font(.title2.weight(.medium))
                            .foregroundStyle(Palette.ink2)
                    }
                    .foregroundStyle(Palette.ink)
                    if let prev = stats.prevTotals {
                        let delta = stats.totals.distance - prev.distance
                        DeltaLabel(delta: delta, text: "\(Fmt.signed(delta, 2)) km", context: stats.range.previousCaption)
                    }
                }
                Spacer()
                if !stats.cumulativePrevious.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        LegendKey(color: Palette.series, label: currentName)
                        LegendKey(color: Palette.muted, label: previousName)
                    }
                    .padding(.top, 4)
                }
            }
            chart.frame(height: 210)
        }
        .card()
    }

    private var chart: some View {
        Chart {
            previousLine
            currentArea
            if let hoverDate {
                hoverMarks(hoverDate)
            } else if let last = stats.cumulativeCurrent.last {
                PointMark(x: .value("Datum", last.date), y: .value("km", last.km))
                    .symbol { EndDot() }
                    .annotation(position: .topLeading, spacing: 2) {
                        Text("\(Fmt.num(last.km, 1)) km")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Palette.ink)
                    }
            }
        }
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(preset: .aligned, values: .automatic(desiredCount: 5)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .font(.caption2)
                    .foregroundStyle(Palette.muted)
            }
        }
        .chartYAxis { valueAxis(digits: 1) }
        .chartHover { proxy, point in
            guard let point, let date: Date = proxy.value(atX: point.x) else {
                hoverDate = nil
                return
            }
            let all = stats.cumulativeCurrent + stats.cumulativePrevious
            hoverDate = all.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }?.date
        }
    }

    @ChartContentBuilder
    private var previousLine: some ChartContent {
        ForEach(stats.cumulativePrevious) { p in
            LineMark(x: .value("Datum", p.date), y: .value("km", p.km), series: .value("Zeitraum", previousName))
                .foregroundStyle(Palette.muted)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
        }
    }

    @ChartContentBuilder
    private var currentArea: some ChartContent {
        ForEach(stats.cumulativeCurrent) { p in
            AreaMark(x: .value("Datum", p.date), y: .value("km", p.km))
                .foregroundStyle(Palette.areaWash)
                .interpolationMethod(.monotone)
            LineMark(x: .value("Datum", p.date), y: .value("km", p.km), series: .value("Zeitraum", currentName))
                .foregroundStyle(Palette.series)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
        }
    }

    @ChartContentBuilder
    private func hoverMarks(_ date: Date) -> some ChartContent {
        let cur = stats.cumulativeCurrent.first { $0.date == date }
        let prev = stats.cumulativePrevious.first { $0.date == date }
        RuleMark(x: .value("Datum", date))
            .foregroundStyle(Palette.baseline)
            .lineStyle(StrokeStyle(lineWidth: 1))
            .annotation(position: .top, spacing: 0,
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                ChartTooltip(title: tooltipTitle(date), rows: tooltipRows(cur, prev))
            }
        if let cur {
            PointMark(x: .value("Datum", cur.date), y: .value("km", cur.km)).symbol { EndDot() }
        }
        if let prev {
            PointMark(x: .value("Datum", prev.date), y: .value("km", prev.km)).symbol { EndDot(color: Palette.muted) }
        }
    }

    private func tooltipTitle(_ date: Date) -> String {
        date <= stats.start ? "Beginn" : "bis \(Fmt.day(date.addingTimeInterval(-1)))"
    }

    private func tooltipRows(_ cur: CumPoint?, _ prev: CumPoint?) -> [TipRow] {
        var rows: [TipRow] = []
        if let cur { rows.append(TipRow(label: currentName, value: "\(Fmt.num(cur.km, 2)) km")) }
        if let prev { rows.append(TipRow(label: previousName, value: "\(Fmt.num(prev.km, 2)) km")) }
        return rows
    }
}

// MARK: - Heute

struct TodayCard: View {
    let today: Totals
    let goal: Int
    let week: [DaySteps]
    @State private var hoveredDay: DaySteps?

    var body: some View {
        let progress = goal > 0 ? min(1, Double(today.steps) / Double(goal)) : 0
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(title: "Heute",
                      subtitle: Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Fmt.de)))
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Fmt.int(today.steps))
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .contentTransition(.numericText())
                    Text("Schritte").font(.title3).foregroundStyle(Palette.ink2)
                }
                Text("Tagesziel \(Fmt.int(goal))").font(.caption).foregroundStyle(Palette.muted)
            }
            Meter(progress: progress)
            if progress >= 1 {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.statusGood)
                    Text("Tagesziel erreicht").foregroundStyle(Palette.ink)
                }
                .font(.caption.weight(.semibold))
            } else {
                Text("Noch \(Fmt.int(goal - today.steps)) Schritte · \(Int((progress * 100).rounded())) % geschafft")
                    .font(.caption)
                    .foregroundStyle(Palette.ink2)
            }
            Spacer(minLength: 0)
            weekChart
            HStack {
                mini("Distanz", "\(Fmt.num(today.distance, 2)) km")
                mini("Aktive Zeit", Fmt.minutes(today.seconds))
                mini("Energie", "\(Fmt.int(today.kcal)) kcal")
            }
        }
        .card()
    }

    private func mini(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.callout.weight(.semibold)).foregroundStyle(Palette.ink).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(Palette.ink2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Heute hervorgehoben, die Vortage als ruhiger Kontext.
    private var weekChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(hoveredDay.map { "\(Fmt.day($0.day)): \(Fmt.int($0.steps)) Schritte" } ?? "Schritte der letzten 7 Tage")
                .font(.caption)
                .foregroundStyle(Palette.ink2)
                .monospacedDigit()
            Chart(week) { d in
                BarMark(x: .value("Tag", d.day, unit: .day), y: .value("Schritte", d.steps), width: .fixed(20))
                    .foregroundStyle(deCalendar.isDateInToday(d.day) ? Palette.series : Palette.baseline)
                    .cornerRadius(4)
                    .opacity(hoveredDay == nil || hoveredDay?.id == d.id ? 1 : 0.45)
            }
            .chartXAxis {
                AxisMarks(values: week.map { $0.day.addingTimeInterval(12 * 3600) }) { value in
                    AxisValueLabel(anchor: .top) {
                        if let d = value.as(Date.self) {
                            Text(d.formatted(.dateTime.weekday(.abbreviated).locale(Fmt.de)))
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(Palette.muted)
                }
            }
            .chartYAxis(.hidden)
            .chartHover { proxy, point in
                guard let point, let date: Date = proxy.value(atX: point.x) else {
                    hoveredDay = nil
                    return
                }
                hoveredDay = week.first { deCalendar.isDate($0.day, inSameDayAs: date) }
            }
            .frame(height: 74)
        }
    }
}

// MARK: - Distanz pro Tag / Woche

struct DistanceBarsCard: View {
    let stats: PeriodStats
    @State private var hovered: DistanceBin?

    private var perLabel: String { stats.unit == .day ? "Tag" : "Woche" }
    private var average: Double { stats.bins.isEmpty ? 0 : stats.totals.distance / Double(stats.bins.count) }
    private var barWidth: MarkDimension { stats.bins.count <= 14 ? .fixed(24) : .ratio(0.62) }

    private var labelDates: [Date] {
        let every: Int
        switch (stats.unit, stats.bins.count) {
        case (.day, ...8): every = 1
        case (.day, _): every = 5
        case (_, ...14): every = 1
        default: every = max(1, stats.bins.count / 10)
        }
        // Mitte des Tages/der Woche, damit das Label unter der Balkenmitte steht;
        // bei ausgeduennten Labels vom Rand weg starten, damit nichts abgeschnitten wird
        let half: TimeInterval = stats.unit == .day ? 12 * 3600 : 3.5 * 86400
        let first = every > 1 ? every / 2 : 0
        return stats.bins.enumerated()
            .filter { $0.offset >= first && ($0.offset - first) % every == 0 }
            .map { $0.element.start.addingTimeInterval(half) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(title: "Distanz pro \(perLabel)",
                      subtitle: "Ø \(Fmt.num(average, 2)) km pro \(perLabel) · \(stats.range.caption)")
            Chart {
                bars
                if average > 0 {
                    RuleMark(y: .value("Durchschnitt", average))
                        .foregroundStyle(Palette.muted)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: .top, alignment: .trailing, spacing: 2) {
                            Text("Ø \(Fmt.num(average, 2)) km").font(.caption2).foregroundStyle(Palette.muted)
                        }
                }
                if let hovered {
                    RuleMark(x: .value("Zeitraum", hovered.start, unit: stats.unit))
                        .foregroundStyle(Color.clear)
                        .annotation(position: .top, spacing: 0,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            ChartTooltip(title: title(for: hovered), rows: [
                                TipRow(label: "Distanz", value: "\(Fmt.num(hovered.km, 2)) km"),
                                TipRow(label: "Aktive Zeit", value: Fmt.minutes(hovered.seconds)),
                                TipRow(label: "Trainings", value: "\(hovered.count)"),
                            ])
                        }
                }
            }
            .chartXAxis {
                AxisMarks(values: labelDates) { value in
                    AxisValueLabel(anchor: .top) {
                        if let d = value.as(Date.self) { Text(axisLabel(d)) }
                    }
                    .font(.caption2)
                    .foregroundStyle(Palette.muted)
                }
            }
            .chartYAxis { valueAxis(digits: 1) }
            .chartHover { proxy, point in
                guard let point, let date: Date = proxy.value(atX: point.x) else {
                    hovered = nil
                    return
                }
                hovered = stats.bins.last { $0.start <= date }
            }
            .frame(height: 230)
        }
        .card()
    }

    @ChartContentBuilder
    private var bars: some ChartContent {
        ForEach(stats.bins) { bin in
            BarMark(x: .value("Zeitraum", bin.start, unit: stats.unit),
                    y: .value("km", bin.km),
                    width: barWidth)
                .foregroundStyle(Palette.series)
                .cornerRadius(4)
                .opacity(hovered == nil || hovered == bin ? 1 : 0.35)
        }
    }

    private func axisLabel(_ d: Date) -> String {
        if stats.unit == .day {
            return stats.bins.count <= 8
                ? d.formatted(.dateTime.weekday(.abbreviated).locale(Fmt.de))
                : Fmt.shortDay(d)
        }
        return "KW \(deCalendar.component(.weekOfYear, from: d))"
    }

    private func title(for bin: DistanceBin) -> String {
        if stats.unit == .day { return Fmt.day(bin.start) }
        let endDay = deCalendar.date(byAdding: .day, value: 6, to: bin.start)!
        return "KW \(deCalendar.component(.weekOfYear, from: bin.start)) · \(Fmt.shortDay(bin.start)) – \(Fmt.shortDay(endDay))"
    }
}

// MARK: - Tempo-Verlauf eines Trainings

struct SpeedProfileCard: View {
    let title: String
    let subtitle: String
    let points: [SpeedPoint]
    let isLive: Bool
    @State private var hoverMinute: Double?

    private var maxPoint: SpeedPoint? { points.max { $0.speed < $1.speed } }
    private var yMax: Double { max(3, ((maxPoint?.speed ?? 0) + 1).rounded(.up)) }

    /// Zeitgewichteter Schnitt ueber die Laufphasen (Pausen = 0 km/h zaehlen nicht).
    private var movingAverage: Double? {
        var weighted = 0.0, total = 0.0
        for (a, b) in zip(points, points.dropFirst()) where a.speed > 0 {
            weighted += a.speed * (b.minute - a.minute)
            total += b.minute - a.minute
        }
        return total > 0 ? weighted / total : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                CardTitle(title: title, subtitle: subtitle)
                Spacer()
                if isLive { LivePill() }
            }
            if points.count < 2 {
                ContentUnavailableView {
                    Label("Kein Tempo-Verlauf", systemImage: "chart.xyaxis.line")
                } description: {
                    Text(isLive
                         ? "Die Kurve erscheint, sobald das Band läuft."
                         : "Für Trainings aus der Zeit vor dem Daemon gibt es keine Sekundenwerte. Wähle unten ein neueres Training.")
                }
                .frame(height: 240)
            } else {
                chart.frame(height: 240)
            }
        }
        .card()
    }

    private var chart: some View {
        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Minute", p.minute), y: .value("km/h", p.speed))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(Palette.areaWash)
                LineMark(x: .value("Minute", p.minute), y: .value("km/h", p.speed))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(Palette.series)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            if let avg = movingAverage {
                RuleMark(y: .value("Durchschnitt", avg))
                    .foregroundStyle(Palette.muted)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        Text("Ø \(Fmt.num(avg, 1)) km/h").font(.caption2).foregroundStyle(Palette.muted)
                    }
            }
            if let hoverMinute, let speed = points.speed(at: hoverMinute) {
                RuleMark(x: .value("Minute", hoverMinute))
                    .foregroundStyle(Palette.baseline)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 0,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        ChartTooltip(title: "bei \(Fmt.clock(Int(hoverMinute * 60))) min",
                                     rows: [TipRow(label: "Tempo", value: "\(Fmt.num(speed, 1)) km/h")])
                    }
                PointMark(x: .value("Minute", hoverMinute), y: .value("km/h", speed))
                    .symbol { EndDot() }
            } else {
                if let m = maxPoint, m.speed > 0 {
                    PointMark(x: .value("Minute", m.minute), y: .value("km/h", m.speed))
                        .symbol { EndDot() }
                        .annotation(position: .top, spacing: 4) {
                            Text("max \(Fmt.num(m.speed, 1))")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Palette.ink)
                        }
                }
                if isLive, let last = points.last {
                    PointMark(x: .value("Minute", last.minute), y: .value("km/h", last.speed))
                        .symbol { EndDot() }
                }
            }
        }
        .chartYScale(domain: 0...yMax)
        .chartXAxis {
            AxisMarks(preset: .aligned, values: .automatic(desiredCount: 6)) { value in
                AxisValueLabel {
                    if let m = value.as(Double.self) { Text(Fmt.clock(Int((m * 60).rounded()))) }
                }
                .font(.caption2)
                .foregroundStyle(Palette.muted)
            }
        }
        .chartYAxis { valueAxis(digits: 0) }
        .chartHover { proxy, point in
            guard let point, let minute: Double = proxy.value(atX: point.x) else {
                hoverMinute = nil
                return
            }
            hoverMinute = min(max(minute, points.first?.minute ?? 0), points.last?.minute ?? 0)
        }
    }
}

// MARK: - Bestwerte

struct RecordsCard: View {
    let sessions: [WorkoutSession]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(title: "Bestwerte", subtitle: "über alle Trainings")
            if sessions.isEmpty {
                Text("Noch keine Trainings").foregroundStyle(Palette.muted)
            } else {
                if let s = sessions.max(by: { $0.distance_km < $1.distance_km }) {
                    RecordRow(icon: "point.topleft.down.to.point.bottomright.curvepath",
                              label: "Weiteste Strecke", value: "\(Fmt.num(s.distance_km, 2)) km", date: s.start)
                }
                if let s = sessions.max(by: { $0.active_s < $1.active_s }) {
                    RecordRow(icon: "timer", label: "Längstes Training", value: Fmt.minutes(s.active_s), date: s.start)
                }
                if let s = sessions.filter({ $0.active_s >= 300 }).max(by: { $0.avgSpeed < $1.avgSpeed }) {
                    RecordRow(icon: "hare", label: "Schnellster Schnitt", value: "\(Fmt.num(s.avgSpeed, 1)) km/h", date: s.start)
                }
                if let best = bestDay {
                    RecordRow(icon: "calendar", label: "Stärkster Tag", value: "\(Fmt.num(best.km, 2)) km", date: best.day)
                }
                let total = Totals(sessions)
                RecordRow(icon: "sum", label: "Insgesamt",
                          value: "\(Fmt.num(total.distance, 1)) km", detail: "\(total.count) Trainings · \(Fmt.minutes(total.seconds))")
            }
        }
        .card()
    }

    private var bestDay: (day: Date, km: Double)? {
        let byDay = Dictionary(grouping: sessions) { deCalendar.startOfDay(for: $0.start) }
            .mapValues { $0.reduce(0) { $0 + $1.distance_km } }
        return byDay.max { $0.value < $1.value }.map { ($0.key, $0.value) }
    }
}

struct RecordRow: View {
    let icon: String
    let label: String
    let value: String
    var date: Date?
    var detail: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.series)
                .frame(width: 32, height: 32)
                .background(Palette.seriesTrack.opacity(0.45), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.subheadline).foregroundStyle(Palette.ink)
                if let text = detail ?? date.map(Fmt.day) {
                    Text(text).font(.caption).foregroundStyle(Palette.muted)
                }
            }
            Spacer(minLength: 8)
            Text(value)
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Palette.ink)
        }
    }
}

// MARK: - Heatmap Wochentag x Uhrzeit

struct HeatmapCard: View {
    let stats: PeriodStats
    var threeD = false
    @State private var hovered: HeatCell?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                CardTitle(title: threeD ? "Aktivitätslandschaft" : "Wann du läufst",
                          subtitle: "Aktive Minuten je Wochentag und Uhrzeit · \(stats.range.caption)")
                Spacer()
                if threeD { ThreeDHint() }
            }
            if threeD {
                if stats.heatMax > 0 {
                    Landscape3DChart(heat: stats.heat, heatMax: stats.heatMax).frame(height: 340)
                } else {
                    Text("Noch keine Trainings im Zeitraum.").foregroundStyle(Palette.muted).frame(height: 300)
                }
            } else {
                flatChart
            }
        }
        .card()
    }

    private var flatChart: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Numerische Achsen statt Kategorien: Zellen fuellen ihr Raster exakt (Montag oben)
            Chart(stats.heat) { cell in
                let row = Double(6 - cell.dayIndex)
                RectangleMark(xStart: .value("Stunde", Double(cell.hour) + 0.07),
                              xEnd: .value("Stunde", Double(cell.hour) + 0.93),
                              yStart: .value("Tag", row + 0.09),
                              yEnd: .value("Tag", row + 0.91))
                    .foregroundStyle(color(for: cell))
                    .cornerRadius(3)
                    .opacity(hovered == nil || hovered == cell ? 1 : 0.6)
            }
            .chartXScale(domain: 0...24)
            .chartYScale(domain: 0...7)
            .chartXAxis {
                AxisMarks(preset: .aligned, values: [0.0, 6.0, 12.0, 18.0, 24.0]) { value in
                    AxisValueLabel {
                        if let h = value.as(Double.self) { Text("\(Int(h)) Uhr") }
                    }
                    .font(.caption2)
                    .foregroundStyle(Palette.muted)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: (0..<7).map { Double($0) + 0.5 }) { value in
                    AxisValueLabel {
                        if let y = value.as(Double.self) { Text(weekdayLabels[6 - Int(y)]) }
                    }
                    .font(.caption2)
                    .foregroundStyle(Palette.muted)
                }
            }
            .chartHover { proxy, point in
                guard let point,
                      let x: Double = proxy.value(atX: point.x),
                      let y: Double = proxy.value(atY: point.y),
                      (0..<24).contains(Int(x)), (0..<7).contains(Int(y)) else {
                    hovered = nil
                    return
                }
                let day = 6 - Int(y)
                hovered = stats.heat.first { $0.dayIndex == day && $0.hour == Int(x) }
            }
            .frame(height: 210)

            HStack {
                Text(hoverText).font(.caption).foregroundStyle(Palette.ink2).monospacedDigit()
                Spacer()
                ScaleLegend()
            }
        }
    }

    private func color(for cell: HeatCell) -> Color {
        guard cell.minutes > 0, stats.heatMax > 0 else { return Palette.grid }
        return Palette.sequential(cell.minutes / stats.heatMax)
    }

    private var hoverText: String {
        if stats.heatMax == 0 { return "Noch keine Trainings im Zeitraum" }
        guard let h = hovered else { return "Zeiger auf ein Feld für Details" }
        return "\(h.weekday), \(h.hour)–\(h.hour + 1) Uhr: \(Fmt.int(h.minutes)) min"
    }
}

struct ScaleLegend: View {
    var body: some View {
        HStack(spacing: 4) {
            Text("wenig").font(.caption2).foregroundStyle(Palette.muted)
            ForEach(1...5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Palette.sequential(Double(i) / 5))
                    .frame(width: 12, height: 12)
            }
            Text("viel").font(.caption2).foregroundStyle(Palette.muted)
        }
    }
}

// MARK: - Tempo-Entwicklung ueber die Trainings

struct TrendCard: View {
    let sessions: [WorkoutSession]
    @State private var hovered: WorkoutSession?

    private var yDomain: ClosedRange<Double> {
        let speeds = sessions.map(\.avgSpeed)
        let lo = max(0, ((speeds.min() ?? 0) - 0.5).rounded(.down))
        let hi = max(lo + 1, ((speeds.max() ?? 1) + 0.5).rounded(.up))
        return lo...hi
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(title: "Tempo-Entwicklung", subtitle: "Ø km/h je Training")
            if sessions.count < 2 {
                ContentUnavailableView {
                    Label("Zu wenige Trainings", systemImage: "chart.line.uptrend.xyaxis")
                } description: {
                    Text("Ab zwei Trainings im Zeitraum.")
                }
                .frame(height: 210)
            } else {
                chart.frame(height: 210)
            }
            Spacer(minLength: 0)
        }
        .card()
    }

    /// Gleichmaessige Abstaende je Training (mehrere Trainings am selben Tag zacken sonst senkrecht).
    private var indexed: [(position: Double, session: WorkoutSession)] {
        sessions.enumerated().map { (Double($0.offset + 1), $0.element) }
    }

    /// Datum nur am ersten Training eines Tages beschriften, hoechstens ~6 Labels.
    private var labelPositions: [Double] {
        var seen = Set<Date>()
        let firsts = indexed.filter { seen.insert(deCalendar.startOfDay(for: $0.session.start)).inserted }
        let every = max(1, Int((Double(firsts.count) / 6).rounded(.up)))
        return firsts.enumerated().filter { $0.offset % every == 0 }.map(\.element.position)
    }

    private var chart: some View {
        Chart {
            ForEach(indexed, id: \.session.id) { item in
                LineMark(x: .value("Training", item.position), y: .value("Ø km/h", item.session.avgSpeed))
                    .foregroundStyle(Palette.series)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Training", item.position), y: .value("Ø km/h", item.session.avgSpeed))
                    .symbol { EndDot() }
                    .opacity(hovered == nil || hovered == item.session ? 1 : 0.4)
            }
            if let hovered, let item = indexed.first(where: { $0.session == hovered }) {
                RuleMark(x: .value("Training", item.position))
                    .foregroundStyle(Palette.baseline)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 0,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        ChartTooltip(title: "\(Fmt.day(hovered.start)) · \(Fmt.time(hovered.start)) Uhr", rows: [
                            TipRow(label: "Ø Tempo", value: "\(Fmt.num(hovered.avgSpeed, 1)) km/h"),
                            TipRow(label: "Dauer", value: Fmt.minutes(hovered.active_s)),
                            TipRow(label: "Distanz", value: "\(Fmt.num(hovered.distance_km, 2)) km"),
                        ])
                    }
            }
        }
        .chartXScale(domain: 0.5...(Double(sessions.count) + 0.5))
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(preset: .aligned, values: labelPositions) { value in
                AxisValueLabel {
                    if let x = value.as(Double.self), let s = indexed.first(where: { $0.position == x })?.session {
                        Text(Fmt.shortDay(s.start))
                    }
                }
                .font(.caption2)
                .foregroundStyle(Palette.muted)
            }
        }
        .chartYAxis { valueAxis(digits: 1) }
        .chartHover { proxy, point in
            guard let point, let x: Double = proxy.value(atX: point.x) else {
                hovered = nil
                return
            }
            let i = min(max(Int(x.rounded()), 1), sessions.count)
            hovered = indexed[i - 1].session
        }
    }
}

// MARK: - Trainingsliste (zugleich Tabellenansicht aller Werte)

struct SessionListCard: View {
    let sessions: [WorkoutSession]
    @Binding var selectedID: Int?
    let highlightedID: Int?
    @State private var hoverID: Int?

    var body: some View {
        let maxKm = max(sessions.map(\.distance_km).max() ?? 0, 0.001)
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: "Trainings", subtitle: "\(sessions.count) im Zeitraum · anklicken zeigt den Tempo-Verlauf")
            headerRow
            Divider()
            if sessions.isEmpty {
                Text("Keine Trainings im Zeitraum").foregroundStyle(Palette.muted).padding(.vertical, 8)
            }
            ForEach(sessions) { s in
                row(s, maxKm: maxKm)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedID = s.id }
                    .onHover { inside in
                        if inside { hoverID = s.id } else if hoverID == s.id { hoverID = nil }
                    }
            }
        }
        .card()
    }

    private var headerRow: some View {
        HStack(spacing: 14) {
            Text("Datum").frame(width: 170, alignment: .leading)
            Text("Dauer").frame(width: 80, alignment: .trailing)
            Text("Distanz").frame(maxWidth: .infinity, alignment: .leading)
            Text("Ø Tempo").frame(width: 86, alignment: .trailing)
            Text("Energie").frame(width: 80, alignment: .trailing)
            Text("Schritte").frame(width: 80, alignment: .trailing)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(Palette.muted)
        .padding(.horizontal, 10)
    }

    private func row(_ s: WorkoutSession, maxKm: Double) -> some View {
        let isHighlighted = s.id == highlightedID
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Fmt.day(s.start)).font(.body.weight(.medium)).foregroundStyle(Palette.ink)
                Text("\(Fmt.time(s.start)) Uhr").font(.caption).foregroundStyle(Palette.muted)
            }
            .frame(width: 170, alignment: .leading)
            Text(Fmt.minutes(s.active_s)).frame(width: 80, alignment: .trailing)
            HStack(spacing: 10) {
                GeometryReader { geo in
                    Capsule()
                        .fill(Palette.series)
                        .frame(width: max(4, geo.size.width * s.distance_km / maxKm), height: 6)
                        .frame(maxHeight: .infinity)
                }
                .frame(height: 14)
                Text("\(Fmt.num(s.distance_km, 2)) km").frame(width: 70, alignment: .trailing)
            }
            .frame(maxWidth: .infinity)
            Text("\(Fmt.num(s.avgSpeed, 1)) km/h").frame(width: 86, alignment: .trailing)
            Text("\(Fmt.int(s.kcal)) kcal").frame(width: 80, alignment: .trailing)
            Text(Fmt.int(s.steps)).frame(width: 80, alignment: .trailing)
        }
        .font(.callout)
        .monospacedDigit()
        .foregroundStyle(Palette.ink)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHighlighted ? Palette.series.opacity(0.10)
                      : hoverID == s.id ? Palette.grid.opacity(0.6) : Color.clear)
        )
    }
}
