import SwiftUI
import Charts
import FoundationModels

// MARK: - Jahreskalender (Aktivitaet je Tag, 53 Wochen)

struct CalendarYearCard: View {
    let calendar: YearCalendar
    @State private var hovered: DayCell?

    @State private var availableWidth: CGFloat = 900
    private let gap: CGFloat = 3
    /// Zellgroesse so, dass 53 Wochen die Kartenbreite fuellen.
    private var cell: CGFloat { min(22, max(8, (availableWidth - 26 - 53 * gap) / 53)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                CardTitle(title: "Dein Jahr", subtitle: "Kilometer je Tag · letzte 12 Monate")
                Spacer()
                HStack(spacing: 18) {
                    miniStat("\(calendar.activeDays)", "aktive Tage")
                    miniStat(Fmt.num(calendar.totalKm, 1), "km")
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                    ZStack(alignment: .topLeading) {
                        Color.clear.frame(height: 14)
                        ForEach(calendar.monthStarts, id: \.week) { entry in
                            Text(entry.label)
                                .font(.caption2)
                                .foregroundStyle(Palette.muted)
                                .offset(x: 26 + CGFloat(entry.week) * (cell + gap))
                        }
                    }
                    HStack(alignment: .top, spacing: gap) {
                        VStack(alignment: .trailing, spacing: gap) {
                            ForEach(0..<7, id: \.self) { d in
                                Text(d % 2 == 0 ? weekdayLabels[d] : "")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Palette.muted)
                                    .frame(width: 22, height: cell, alignment: .trailing)
                            }
                        }
                        ForEach(Array(calendar.weeks.enumerated()), id: \.offset) { _, week in
                            VStack(spacing: gap) {
                                ForEach(0..<7, id: \.self) { d in
                                    dayView(week[d])
                                }
                            }
                        }
                    }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { availableWidth = $0 }

            HStack {
                Text(hoverText).font(.caption).foregroundStyle(Palette.ink2).monospacedDigit()
                Spacer()
                ScaleLegend()
            }
        }
        .card()
    }

    @ViewBuilder
    private func dayView(_ day: DayCell?) -> some View {
        if let day {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(day.km > 0 && calendar.maxKm > 0 ? Palette.sequential(day.km / calendar.maxKm) : Palette.grid)
                .frame(width: cell, height: cell)
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Palette.ink.opacity(hovered?.id == day.id ? 0.7 : 0), lineWidth: 1.5)
                )
                .onHover { inside in
                    if inside { hovered = day } else if hovered?.id == day.id { hovered = nil }
                }
        } else {
            Color.clear.frame(width: cell, height: cell)
        }
    }

    private var hoverText: String {
        guard let d = hovered else { return "Zeiger auf einen Tag für Details" }
        return d.km > 0
            ? "\(Fmt.day(d.date)): \(Fmt.num(d.km, 2)) km in \(Fmt.minutes(d.minutes * 60))"
            : "\(Fmt.day(d.date)): kein Training"
    }

    private func miniStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(Palette.ink)
            Text(label).font(.caption).foregroundStyle(Palette.ink2)
        }
    }
}

// MARK: - Tempozonen je Training

struct ZonesCard: View {
    let zones: ZonesResponse?
    let range: ClosedRange<Date>
    @State private var hovered: (session: Int, zone: Int)?

    private var infos: [ZoneInfo] { ZoneInfo.all(bounds: zones?.bounds_kmh ?? [3, 4.5, 6]) }

    private var sessions: [ZoneSession] {
        (zones?.sessions ?? []).filter { range.contains($0.start) && $0.total > 0 }.suffix(12).reversed()
    }

    private var totals: [Double] {
        var sums = Array(repeating: 0.0, count: infos.count)
        for s in (zones?.sessions ?? []).filter({ range.contains($0.start) }) {
            for (i, v) in s.seconds.enumerated() where i < sums.count { sums[i] += v }
        }
        return sums
    }

    var body: some View {
        let sum = totals.reduce(0, +)
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(title: "Tempozonen", subtitle: "Wie viel Zeit du in welchem Tempo gehst")

            HStack(spacing: 14) {
                ForEach(infos) { z in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(Palette.zone(z.index)).frame(width: 12, height: 12)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(z.name).font(.caption.weight(.medium)).foregroundStyle(Palette.ink)
                            Text(z.range).font(.caption2).foregroundStyle(Palette.muted)
                        }
                    }
                }
            }

            if sum > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Gesamt im Zeitraum").font(.caption).foregroundStyle(Palette.ink2)
                    GeometryReader { geo in
                        let gaps = CGFloat(max(totals.filter { $0 > 0 }.count - 1, 0)) * 2
                        HStack(spacing: 2) {
                            ForEach(Array(totals.enumerated()), id: \.offset) { i, v in
                                if v > 0 {
                                    let w = (geo.size.width - gaps) * v / sum
                                    ZStack {
                                        segmentShape(isLast: i == lastNonZero(totals))
                                            .fill(Palette.zone(i))
                                        if w > 58 {
                                            Text("\(Int((v / sum * 100).rounded())) %")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(Palette.zoneLabel(i))
                                        }
                                    }
                                    .frame(width: w)
                                    .help("\(infos[i].name): \(Fmt.minutes(v)) (\(Int((v / sum * 100).rounded())) %)")
                                }
                            }
                        }
                    }
                    .frame(height: 26)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Je Training (neueste oben)").font(.caption).foregroundStyle(Palette.ink2)
                    let maxTotal = sessions.map(\.total).max() ?? 1
                    ForEach(sessions) { s in
                        HStack(spacing: 10) {
                            Text("\(Fmt.shortDay(s.start)) \(Fmt.time(s.start))")
                                .font(.caption).monospacedDigit().foregroundStyle(Palette.ink2)
                                .frame(width: 104, alignment: .leading)
                            GeometryReader { geo in
                                let used = s.seconds.filter { $0 > 0 }
                                let gaps = CGFloat(max(used.count - 1, 0)) * 2
                                let width = max(geo.size.width * s.total / maxTotal - gaps, 4)
                                HStack(spacing: 2) {
                                    ForEach(Array(s.seconds.enumerated()), id: \.offset) { i, v in
                                        if v > 0 {
                                            segmentShape(isLast: i == lastNonZero(s.seconds))
                                                .fill(Palette.zone(i))
                                                .frame(width: max(width * v / s.total, 2))
                                                .opacity(hovered == nil || (hovered?.session == s.id && hovered?.zone == i) ? 1 : 0.5)
                                                .onHover { inside in
                                                    if inside { hovered = (s.id, i) } else if hovered?.session == s.id && hovered?.zone == i { hovered = nil }
                                                }
                                        }
                                    }
                                }
                            }
                            .frame(height: 12)
                            Text(Fmt.minutes(s.total) + (s.estimated ? "*" : ""))
                                .font(.caption).monospacedDigit().foregroundStyle(Palette.ink2)
                                .frame(width: 58, alignment: .trailing)
                        }
                    }
                }

                Text(hoverText)
                    .font(.caption).foregroundStyle(Palette.muted)
            } else {
                Text("Noch keine Trainings im Zeitraum.").foregroundStyle(Palette.muted)
            }
        }
        .card()
    }

    private var hoverText: String {
        guard let h = hovered, let s = sessions.first(where: { $0.id == h.session }) else {
            return (zones?.sessions.contains { $0.estimated } ?? false)
                ? "* ohne Sekundenwerte – Zone aus dem Durchschnittstempo geschätzt"
                : "Zeiger auf einen Abschnitt für Details"
        }
        return "\(Fmt.day(s.start)): \(infos[h.zone].name) (\(infos[h.zone].range)) \(Fmt.minutes(s.seconds[h.zone]))"
    }

    private func lastNonZero(_ values: [Double]) -> Int {
        values.lastIndex { $0 > 0 } ?? 0
    }

    /// Eckig an der Grundlinie, 4 pt gerundet am Datenende.
    private func segmentShape(isLast: Bool) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                               bottomTrailingRadius: isLast ? 4 : 0, topTrailingRadius: isLast ? 4 : 0,
                               style: .continuous)
    }
}

// MARK: - Prognose mit Unsicherheitsband

struct ForecastCard: View {
    let forecast: Forecast
    @State private var hoverDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(title: "Prognose", subtitle: headline)
            if forecast.isUsable {
                HStack(spacing: 16) {
                    LegendKey(color: Palette.series, label: "Bisher")
                    HStack(spacing: 6) {
                        Capsule().fill(Palette.series.opacity(0.5)).frame(width: 14, height: 3)
                        Text("Prognose").font(.caption).foregroundStyle(Palette.ink2)
                    }
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(Palette.series.opacity(0.14)).frame(width: 14, height: 10)
                        Text("80-%-Bereich").font(.caption).foregroundStyle(Palette.ink2)
                    }
                }
                chart.frame(height: 220)
                Text("Annahme: Du gehst weiter wie in den letzten \(forecast.historyDays) Tagen (Ø \(Fmt.num(forecast.dailyMean, 2)) km pro Tag, Schwankung ±\(Fmt.num(forecast.dailySD, 2))).")
                    .font(.caption).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ContentUnavailableView {
                    Label("Noch zu wenig Daten", systemImage: "chart.line.uptrend.xyaxis")
                } description: {
                    Text("Die Prognose erscheint nach ein paar Trainings.")
                }
                .frame(height: 200)
            }
        }
        .card()
    }

    private var headline: String {
        guard forecast.isUsable, let expected = forecast.expected else {
            return "Nächstes Ziel: \(Fmt.num(forecast.milestone, 0)) km"
        }
        var text = "\(Fmt.num(forecast.milestone, 0)) km voraussichtlich am \(Fmt.shortDay(expected))"
        if let e = forecast.earliest, let l = forecast.latest, e != l {
            text += " (zwischen \(Fmt.shortDay(e)) und \(Fmt.shortDay(l)))"
        } else if let e = forecast.earliest, forecast.latest == nil {
            text += " (frühestens \(Fmt.shortDay(e)))"
        }
        return text
    }

    private var chart: some View {
        Chart {
            ForEach(forecast.projection) { p in
                AreaMark(x: .value("Datum", p.date), yStart: .value("unten", p.low), yEnd: .value("oben", p.high))
                    .foregroundStyle(Palette.series.opacity(0.14))
                    .interpolationMethod(.monotone)
            }
            ForEach(forecast.projection) { p in
                LineMark(x: .value("Datum", p.date), y: .value("km", p.mid), series: .value("Reihe", "Prognose"))
                    .foregroundStyle(Palette.series.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4]))
            }
            ForEach(forecast.actual) { p in
                LineMark(x: .value("Datum", p.date), y: .value("km", p.km), series: .value("Reihe", "Bisher"))
                    .foregroundStyle(Palette.series)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            RuleMark(y: .value("Ziel", forecast.milestone))
                .foregroundStyle(Palette.muted)
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(position: .top, alignment: .leading, spacing: 2) {
                    Text("Ziel \(Fmt.num(forecast.milestone, 0)) km").font(.caption2).foregroundStyle(Palette.muted)
                }
            if let expected = forecast.expected, hoverDate == nil {
                PointMark(x: .value("Datum", expected), y: .value("km", forecast.milestone))
                    .symbol { EndDot() }
                    .annotation(position: .bottom, spacing: 4) {
                        Text(Fmt.shortDay(expected)).font(.caption.weight(.semibold)).foregroundStyle(Palette.ink)
                    }
            }
            if let hoverDate, let tip = tooltip(for: hoverDate) {
                RuleMark(x: .value("Datum", hoverDate))
                    .foregroundStyle(Palette.baseline)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 0,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        tip
                    }
            }
        }
        .chartXAxis {
            AxisMarks(preset: .aligned, values: .automatic(desiredCount: 5)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(.caption2).foregroundStyle(Palette.muted)
            }
        }
        .chartYAxis { valueAxis(digits: 0) }
        .chartHover { proxy, point in
            guard let point, let date: Date = proxy.value(atX: point.x) else {
                hoverDate = nil
                return
            }
            hoverDate = date
        }
    }

    private func tooltip(for date: Date) -> ChartTooltip? {
        if let p = forecast.projection.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }),
           date > .now, abs(p.date.timeIntervalSince(date)) < 86400 {
            return ChartTooltip(title: Fmt.day(p.date), rows: [
                TipRow(label: "Erwartet", value: "\(Fmt.num(p.mid, 1)) km"),
                TipRow(label: "80-%-Bereich", value: "\(Fmt.num(p.low, 1))–\(Fmt.num(p.high, 1)) km"),
            ])
        }
        if let a = forecast.actual.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }) {
            return ChartTooltip(title: Fmt.day(a.date.addingTimeInterval(-1)), rows: [TipRow(label: "Gesamt", value: "\(Fmt.num(a.km, 1)) km")])
        }
        return nil
    }
}

// MARK: - Einschaetzung (Regeln + optional Apple Intelligence auf dem Mac)

@MainActor
final class InsightNarrator: ObservableObject {
    enum State: Equatable {
        case idle
        case generating
        case done(String)
        case failed(String)
    }

    @Published var state: State = .idle
    private var lastFacts: String?

    var availabilityNote: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return SystemLanguageModel.default.supportsLocale(Locale(identifier: "de_DE")) ? nil : "Apple Intelligence unterstützt hier kein Deutsch."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Für eine KI-Zusammenfassung: Systemeinstellungen → Apple Intelligence & Siri einschalten. Läuft komplett auf dem Mac."
        case .unavailable(.modelNotReady):
            return "Das Apple-Intelligence-Modell wird noch geladen."
        case .unavailable:
            return "Apple Intelligence ist auf diesem Mac nicht verfügbar."
        }
    }

    var isAvailable: Bool { availabilityNote == nil }

    func summarize(_ insights: [Insight], force: Bool = false) {
        guard isAvailable else { return }
        let facts = insights.map { "- \($0.text)" }.joined(separator: "\n")
        guard force || facts != lastFacts else { return }
        lastFacts = facts
        state = .generating
        Task { @MainActor in
            do {
                let session = LanguageModelSession(instructions: """
                    Du bist ein freundlicher, knapper Trainingscoach für ein Laufband am Schreibtisch.
                    Schreibe auf Deutsch 2–3 kurze Sätze: eine ehrliche Einordnung und ein konkreter, kleiner Vorschlag.
                    Nutze nur die gegebenen Fakten, erfinde keine Zahlen, keine Emojis.
                    """)
                var latest = ""
                for try await snapshot in session.streamResponse(to: "Fakten:\n\(facts)", options: GenerationOptions(temperature: 0.4)) {
                    latest = snapshot.content
                    state = .done(latest)
                }
                state = .done(latest)
            } catch {
                state = .failed("KI-Zusammenfassung fehlgeschlagen: \(error.localizedDescription)")
            }
        }
    }
}

struct InsightsCard: View {
    let insights: [Insight]
    @StateObject private var narrator = InsightNarrator()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                CardTitle(title: "Einschätzung", subtitle: "Automatisch aus deinen Daten")
                Spacer()
                if narrator.isAvailable {
                    Button {
                        narrator.summarize(insights, force: true)
                    } label: {
                        Label("Neu formulieren", systemImage: "apple.intelligence")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }

            if narrator.isAvailable {
                narrative
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(insights.prefix(6)) { insight in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: insight.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(insight.positive ? Palette.series : Palette.ink2)
                            .frame(width: 18)
                        Text(insight.text)
                            .font(.callout)
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if insights.isEmpty {
                    Text("Nach den ersten Trainings erscheinen hier Hinweise.").foregroundStyle(Palette.muted)
                }
            }

            if let note = narrator.availabilityNote {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "apple.intelligence").foregroundStyle(Palette.ink2)
                    Text(note).foregroundStyle(Palette.muted)
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
        .task(id: insights.map(\.text).joined()) {
            narrator.summarize(insights)
        }
    }

    @ViewBuilder
    private var narrative: some View {
        switch narrator.state {
        case .idle:
            EmptyView()
        case .generating:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Apple Intelligence formuliert …").font(.callout).foregroundStyle(Palette.ink2)
            }
        case .done(let text):
            Text(text)
                .font(.body)
                .foregroundStyle(Palette.ink)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.series.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentTransition(.opacity)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(Palette.muted)
        }
    }
}
