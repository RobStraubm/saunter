import Foundation
import SwiftUI

// MARK: - Tempozonen

struct ZoneSession: Decodable, Identifiable {
    let session_id: Int
    let start_ts: Double
    let estimated: Bool
    let seconds: [Double]

    var id: Int { session_id }
    var start: Date { Date(timeIntervalSince1970: start_ts) }
    var total: Double { seconds.reduce(0, +) }
}

struct ZonesResponse: Decodable {
    let bounds_kmh: [Double]
    let sessions: [ZoneSession]
}

struct ZoneInfo: Identifiable {
    let index: Int
    let name: String
    let range: String
    var id: Int { index }

    static func all(bounds: [Double]) -> [ZoneInfo] {
        let names = ["Locker", "Moderat", "Zügig", "Schnell", "Sehr schnell"]
        let f = { (v: Double) in Fmt.num(v, v.rounded() == v ? 0 : 1) }
        var ranges = ["unter \(f(bounds.first ?? 3))"]
        for (a, b) in zip(bounds, bounds.dropFirst()) { ranges.append("\(f(a))–\(f(b))") }
        ranges.append("ab \(f(bounds.last ?? 6))")
        return ranges.enumerated().map { ZoneInfo(index: $0.offset, name: names[min($0.offset, names.count - 1)], range: "\($0.element) km/h") }
    }
}

extension Palette {
    /// Geordnete Rampe (validiert mit --ordinal): langsam -> schnell, im Dunkeln von dunkel nach hell.
    static func zone(_ index: Int) -> Color {
        let light: [UInt32] = [0x86B6EF, 0x3987E5, 0x1C5CAB, 0x0D366B]
        let dark: [UInt32] = [0x184F95, 0x2A78D6, 0x6DA7EC, 0xB7D3F6]
        let i = min(max(index, 0), light.count - 1)
        return .adaptive(light[i], dark[i])
    }

    /// Schrift auf einer Zonenflaeche: weiss auf dunklen, Tinte auf hellen Stufen.
    static func zoneLabel(_ index: Int) -> Color {
        switch index {
        case 0: return .adaptive(0x0B0B0B, 0xFFFFFF)
        case 1: return .white
        default: return .adaptive(0xFFFFFF, 0x0B0B0B)
        }
    }
}

// MARK: - Prognose

struct ProjectionPoint: Identifiable {
    let date: Date
    let mid: Double
    let low: Double
    let high: Double
    var id: Date { date }
}

struct Forecast {
    let total: Double
    let dailyMean: Double
    let dailySD: Double
    let historyDays: Int
    let milestone: Double
    let expected: Date?
    let earliest: Date?
    let latest: Date?
    let actual: [CumPoint]
    let projection: [ProjectionPoint]

    var isUsable: Bool { dailyMean > 0.001 && historyDays >= 3 }

    init(sessions: [WorkoutSession], now: Date = .now) {
        let cal = deCalendar
        let today = cal.startOfDay(for: now)
        let total = sessions.reduce(0) { $0 + $1.distance_km }
        self.total = total

        let first = sessions.map(\.start).min().map { cal.startOfDay(for: $0) } ?? today
        let span = (cal.dateComponents([.day], from: first, to: today).day ?? 0) + 1
        let n = min(28, max(span, 1))
        historyDays = n

        var daily: [Double] = []
        for offset in (0..<n).reversed() {
            let day = cal.date(byAdding: .day, value: -offset, to: today)!
            daily.append(sessions.filter { cal.isDate($0.start, inSameDayAs: day) }.reduce(0) { $0 + $1.distance_km })
        }
        let mean = daily.reduce(0, +) / Double(daily.count)
        let variance = daily.count > 1 ? daily.reduce(0) { $0 + pow($1 - mean, 2) } / Double(daily.count - 1) : 0
        dailyMean = mean
        dailySD = sqrt(variance)

        let steps: [Double] = [5, 10, 25, 50, 75, 100, 150, 200, 250, 300, 400, 500, 750, 1000, 1500, 2000, 3000, 5000]
        milestone = steps.first { $0 > total + 0.01 } ?? (ceil((total + 1) / 1000) * 1000)

        // Bisher: Gesamtstand am Ende der letzten 30 Tage
        var actual: [CumPoint] = []
        for offset in (0...30).reversed() {
            let dayEnd = cal.date(byAdding: .day, value: 1 - offset, to: today)!
            let km = sessions.filter { $0.start < dayEnd }.reduce(0) { $0 + $1.distance_km }
            actual.append(CumPoint(date: min(dayEnd, now), km: km))
        }
        self.actual = actual

        // Prognose: Tagesschnitt fortgeschrieben, 80-%-Bereich (±1,28 σ·√t)
        var projection: [ProjectionPoint] = [ProjectionPoint(date: now, mid: total, low: total, high: total)]
        var expected: Date?, earliest: Date?, latest: Date?
        if mean > 0.001 {
            let daysToGoal = (milestone - total) / mean
            let horizon = Int(min(180, max(14, ceil(daysToGoal * 1.8))))
            for d in 1...horizon {
                let date = cal.date(byAdding: .day, value: d, to: today)!
                let spread = 1.28 * dailySD * sqrt(Double(d))
                let mid = total + mean * Double(d)
                let point = ProjectionPoint(date: date, mid: mid, low: max(total, mid - spread), high: mid + spread)
                projection.append(point)
                if earliest == nil, point.high >= milestone { earliest = date }
                if expected == nil, point.mid >= milestone { expected = date }
                if latest == nil, point.low >= milestone { latest = date }
            }
        }
        self.projection = projection
        self.expected = expected
        self.earliest = earliest
        self.latest = latest
    }
}

// MARK: - Jahreskalender

struct DayCell: Identifiable {
    let date: Date
    let km: Double
    let minutes: Double
    var id: Date { date }
}

struct YearCalendar {
    /// 53 Wochen-Spalten, je 7 Tage (Mo–So); Tage nach heute sind nil.
    let weeks: [[DayCell?]]
    let monthStarts: [(week: Int, label: String)]
    let maxKm: Double
    let activeDays: Int
    let totalKm: Double

    init(sessions: [WorkoutSession], now: Date = .now) {
        let cal = deCalendar
        let today = cal.startOfDay(for: now)
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: today)!.start
        let firstWeek = cal.date(byAdding: .weekOfYear, value: -52, to: thisWeek)!

        var byDay: [Date: (km: Double, min: Double)] = [:]
        for s in sessions {
            let d = cal.startOfDay(for: s.start)
            let prev = byDay[d] ?? (0, 0)
            byDay[d] = (prev.km + s.distance_km, prev.min + s.active_s / 60)
        }

        var weeks: [[DayCell?]] = []
        var monthStarts: [(Int, String)] = []
        var lastMonth = -1
        for w in 0..<53 {
            let weekStart = cal.date(byAdding: .weekOfYear, value: w, to: firstWeek)!
            var column: [DayCell?] = []
            for d in 0..<7 {
                let day = cal.date(byAdding: .day, value: d, to: weekStart)!
                if day > today {
                    column.append(nil)
                } else {
                    let v = byDay[day] ?? (0, 0)
                    column.append(DayCell(date: day, km: v.km, minutes: v.min))
                }
            }
            let month = cal.component(.month, from: weekStart)
            if month != lastMonth {
                // angeschnittener Monat am Anfang: Label weglassen, sonst ueberlappt es mit dem naechsten
                if let last = monthStarts.last, w - last.0 < 3 { monthStarts.removeLast() }
                monthStarts.append((w, weekStart.formatted(.dateTime.month(.abbreviated).locale(Fmt.de))))
                lastMonth = month
            }
            weeks.append(column)
        }
        self.weeks = weeks
        self.monthStarts = monthStarts
        let cells = weeks.flatMap { $0 }.compactMap { $0 }
        maxKm = cells.map(\.km).max() ?? 0
        activeDays = cells.filter { $0.km > 0 }.count
        totalKm = cells.reduce(0) { $0 + $1.km }
    }
}

// MARK: - Einschaetzungen (regelbasiert, Grundlage auch fuer die KI)

struct Insight: Identifiable {
    let symbol: String
    let text: String
    let positive: Bool
    var id: String { text }
}

enum InsightEngine {
    static func make(sessions: [WorkoutSession], goal: Int, forecast: Forecast, streak: Streak,
                     journey: JourneyProgress?, wanderstreak: StreakInfo? = nil, now: Date = .now) -> [Insight] {
        let cal = deCalendar
        var out: [Insight] = []
        let today = cal.startOfDay(for: now)
        let weekAgo = cal.date(byAdding: .day, value: -6, to: today)!
        let twoWeeksAgo = cal.date(byAdding: .day, value: -13, to: today)!
        let last7 = sessions.filter { $0.start >= weekAgo }
        let prev7 = sessions.filter { $0.start >= twoWeeksAgo && $0.start < weekAgo }
        let km7 = last7.reduce(0) { $0 + $1.distance_km }
        let kmPrev = prev7.reduce(0) { $0 + $1.distance_km }

        if km7 > 0 || kmPrev > 0 {
            if kmPrev < 0.01 {
                out.append(Insight(symbol: "chart.line.uptrend.xyaxis",
                                   text: "Letzte 7 Tage: \(Fmt.num(km7, 1)) km – in der Woche davor warst du gar nicht auf dem Band.",
                                   positive: km7 > 0))
            } else {
                let pct = Int(((km7 - kmPrev) / kmPrev * 100).rounded())
                let change = pct >= 0 ? "\(pct) % mehr" : "\(abs(pct)) % weniger"
                out.append(Insight(symbol: pct >= 0 ? "chart.line.uptrend.xyaxis" : "chart.line.downtrend.xyaxis",
                                   text: "Letzte 7 Tage: \(Fmt.num(km7, 1)) km – \(change) als in der Woche davor.",
                                   positive: pct >= 0))
            }
        }

        let todaySteps = sessions.filter { cal.isDateInToday($0.start) }.reduce(0) { $0 + $1.steps }
        if goal > 0 {
            if todaySteps >= goal {
                out.append(Insight(symbol: "checkmark.seal.fill", text: "Tagesziel geschafft: \(Fmt.int(todaySteps)) Schritte.", positive: true))
            } else {
                // Schrittlaenge 0,747 m (180 cm), bei 4 km/h ≈ 89 Schritte pro Minute
                let minutes = Double(goal - todaySteps) / 89.2
                out.append(Insight(symbol: "figure.walk",
                                   text: "Bis zum Tagesziel fehlen \(Fmt.int(goal - todaySteps)) Schritte – etwa \(Fmt.minutes(minutes * 60)) bei 4 km/h.",
                                   positive: false))
            }
        }

        var minutesBySlot: [String: Double] = [:]
        for s in sessions {
            let wd = (cal.component(.weekday, from: s.start) + 5) % 7
            let block = cal.component(.hour, from: s.start) / 3 * 3
            minutesBySlot["\(wd)|\(block)", default: 0] += s.active_s / 60
        }
        if let best = minutesBySlot.max(by: { $0.value < $1.value }), best.value >= 10 {
            let parts = best.key.split(separator: "|").compactMap { Int($0) }
            let days = ["montags", "dienstags", "mittwochs", "donnerstags", "freitags", "samstags", "sonntags"]
            out.append(Insight(symbol: "clock",
                               text: "Am liebsten gehst du \(days[parts[0]]) zwischen \(parts[1]) und \(parts[1] + 3) Uhr.",
                               positive: true))
        }

        let recent = sessions.filter { $0.active_s >= 120 }.sorted { $0.start_ts < $1.start_ts }
        if recent.count >= 4 {
            let n = min(3, recent.count / 2)
            let newer = recent.suffix(n).map(\.avgSpeed).reduce(0, +) / Double(n)
            let older = recent.dropLast(n).suffix(n).map(\.avgSpeed).reduce(0, +) / Double(n)
            if abs(newer - older) >= 0.2 {
                out.append(Insight(symbol: newer > older ? "hare" : "tortoise",
                                   text: "Dein Tempo \(newer > older ? "steigt" : "sinkt"): Ø \(Fmt.num(newer, 1)) km/h in den letzten \(n) Trainings (davor \(Fmt.num(older, 1))).",
                                   positive: newer > older))
            }
        }

        if let w = wanderstreak {
            let days = "\(w.current) \(w.current == 1 ? "Tag" : "Tage")"
            if let first = w.pending.first, let d = StreakDay.parser.date(from: first) {
                out.append(Insight(symbol: "questionmark.circle",
                                   text: "Offene Frage: Warst du am \(d.formatted(.dateTime.weekday(.wide).locale(Fmt.de))) im Büro? Dein Streak (\(days)) wartet auf die Antwort.",
                                   positive: false))
            } else if w.at_risk {
                out.append(Insight(symbol: "flame",
                                   text: "Wanderstreak \(days): heute noch \(Fmt.num(w.minutesLeftToday, 0)) Minuten laufen, dann bleibt er.",
                                   positive: false))
            } else if w.todayDone {
                let toRecord = w.best - w.current + 1
                out.append(Insight(symbol: "flame.fill",
                                   text: w.current >= w.best
                                       ? "Wanderstreak \(days) – das ist dein Rekord!"
                                       : "Wanderstreak \(days) – noch \(toRecord) \(toRecord == 1 ? "Tag" : "Tage") bis zum Rekord.",
                                   positive: true))
            }
        } else if streak.best > 1 && streak.current > 0 && streak.current <= streak.best {
            let needed = streak.best - streak.current + 1
            out.append(Insight(symbol: "flame",
                               text: "Serie: \(streak.current) \(streak.current == 1 ? "Tag" : "Tage") am Stück – noch \(needed) \(needed == 1 ? "Tag" : "Tage") bis zum neuen Serienrekord.",
                               positive: true))
        } else if let last = sessions.map(\.start).max(), let days = cal.dateComponents([.day], from: cal.startOfDay(for: last), to: today).day, days >= 3 {
            out.append(Insight(symbol: "calendar.badge.clock", text: "Dein letztes Training ist \(days) Tage her.", positive: false))
        }

        if forecast.isUsable, let expected = forecast.expected {
            out.append(Insight(symbol: "flag.checkered",
                               text: "\(Fmt.num(forecast.milestone, 0)) km erreichst du voraussichtlich um den \(expected.formatted(.dateTime.day().month(.wide).locale(Fmt.de))).",
                               positive: true))
        }

        if let journey, let next = journey.nextStage {
            out.append(Insight(symbol: "map",
                               text: "\(journey.route.name): noch \(Fmt.num(next.remainingKm, 1)) km bis \(next.name).",
                               positive: true))
        }
        return out
    }
}
