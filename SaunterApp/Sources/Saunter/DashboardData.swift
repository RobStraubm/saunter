import Foundation
import SwiftUI

struct WorkoutSession: Decodable, Identifiable, Hashable {
    let id: Int
    let start_ts: Double
    let active_s: Double
    let distance_km: Double
    let kcal: Double
    let steps: Int
    let max_speed_kmh: Double
    let avg_speed_kmh: Double?
    let has_samples: Int?

    var start: Date { Date(timeIntervalSince1970: start_ts) }
    var hasSamples: Bool { (has_samples ?? 0) != 0 }

    var avgSpeed: Double {
        if let a = avg_speed_kmh, a > 0 { return a }
        return active_s > 0 ? distance_km / (active_s / 3600) : 0
    }
}

struct SpeedPoint: Identifiable {
    let id: Int
    let minute: Double
    let speed: Double

    /// Behaelt nur Tempowechsel (verlustfrei fuer eine Treppenkurve) und traegt
    /// Luecken > 3 s (Pausen) als 0 km/h ein.
    static func series(from raw: [[Double]]) -> [SpeedPoint] {
        guard let t0 = raw.first?.first else { return [] }
        var out: [SpeedPoint] = []
        func add(_ t: Double, _ v: Double) {
            out.append(SpeedPoint(id: out.count, minute: (t - t0) / 60, speed: v))
        }
        var prevT: Double?
        var prevV: Double?
        for row in raw where row.count >= 2 {
            let t = row[0], v = row[1]
            if let pt = prevT, t - pt > 3 {
                add(pt + 1, 0)
                add(t - 1, 0)
                prevV = 0
            }
            if v != prevV { add(t, v) }
            prevT = t
            prevV = v
        }
        if let pt = prevT, let last = out.last, last.minute < (pt - t0) / 60 {
            add(pt, prevV ?? 0)
        }
        return out
    }
}

extension Array where Element == SpeedPoint {
    /// Tempo zu einer Minute (Treppen-Semantik: letzter Wechsel davor).
    func speed(at minute: Double) -> Double? {
        guard let first, minute >= first.minute else { return nil }
        var lo = 0, hi = count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if self[mid].minute <= minute { lo = mid } else { hi = mid - 1 }
        }
        return self[lo].speed
    }
}

@MainActor
final class DashboardData: ObservableObject {
    @Published var sessions: [WorkoutSession] = []
    @Published var samples: [SpeedPoint] = []
    @Published var samplesFor: Int?
    @Published var reachable = true
    @Published var zones: ZonesResponse?
    @Published var ridge: [(label: String, points: [SpeedPoint])] = []
    private var ridgeKey = ""

    /// Live-Training > Auswahl > letztes Training mit Tempo-Verlauf > letztes Training.
    func profileID(liveID: Int?, selectedID: Int?) -> Int? {
        liveID ?? selectedID ?? sessions.first(where: \.hasSamples)?.id ?? sessions.first?.id
    }

    func loadSessions() async {
        var comps = URLComponents(url: apiBase.appendingPathComponent("sessions"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "limit", value: "10000")]
        do {
            let (data, _) = try await URLSession.shared.data(from: comps.url!)
            sessions = try JSONDecoder().decode([WorkoutSession].self, from: data)
            reachable = true
        } catch {
            reachable = false
        }
        if let result = try? await URLSession.shared.data(from: apiBase.appendingPathComponent("zones")),
           let decoded = try? JSONDecoder().decode(ZonesResponse.self, from: result.0) {
            zones = decoded
        }
    }

    /// Tempo-Verlaeufe fuer das 3D-Gebirge (neueste Trainings mit Sekundenwerten, aelteste vorne).
    func loadRidge(for candidates: [WorkoutSession], limit: Int = 8) async {
        let picked = candidates.filter(\.hasSamples).sorted { $0.start_ts > $1.start_ts }.prefix(limit).reversed()
        let key = picked.map { String($0.id) }.joined(separator: ",")
        guard key != ridgeKey else { return }
        var result: [(String, [SpeedPoint])] = []
        for s in picked {
            let url = apiBase.appendingPathComponent("sessions/\(s.id)/samples")
            guard let data = try? await URLSession.shared.data(from: url),
                  let raw = try? JSONDecoder().decode([[Double]].self, from: data.0) else { continue }
            result.append(("\(Fmt.shortDay(s.start)) \(Fmt.time(s.start))", SpeedPoint.series(from: raw)))
        }
        ridge = result.map { (label: $0.0, points: $0.1) }
        ridgeKey = key
    }

    func loadSamples(for id: Int) async {
        let url = apiBase.appendingPathComponent("sessions/\(id)/samples")
        guard let result = try? await URLSession.shared.data(from: url),
              let raw = try? JSONDecoder().decode([[Double]].self, from: result.0) else { return }
        samples = SpeedPoint.series(from: raw)
        samplesFor = id
    }
}

// MARK: - Auswertung

let deCalendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.locale = Fmt.de
    c.firstWeekday = 2
    c.minimumDaysInFirstWeek = 4
    return c
}()

let weekdayLabels = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]

func lastSevenDaysSteps(_ sessions: [WorkoutSession], now: Date = .now) -> [DaySteps] {
    let today = deCalendar.startOfDay(for: now)
    return (0..<7).reversed().map { offset in
        let day = deCalendar.date(byAdding: .day, value: -offset, to: today)!
        let steps = sessions
            .filter { deCalendar.isDate($0.start, inSameDayAs: day) }
            .reduce(0) { $0 + $1.steps }
        return DaySteps(day: day, steps: steps)
    }
}

enum StatsRange: String, CaseIterable, Identifiable {
    case week = "7 Tage"
    case month = "30 Tage"
    case quarter = "12 Wochen"
    case all = "Gesamt"

    var id: Self { self }

    var caption: String {
        switch self {
        case .week: "letzte 7 Tage"
        case .month: "letzte 30 Tage"
        case .quarter: "letzte 12 Wochen"
        case .all: "gesamt"
        }
    }

    var previousCaption: String {
        switch self {
        case .week: "ggü. den 7 Tagen davor"
        case .month: "ggü. den 30 Tagen davor"
        case .quarter: "ggü. den 12 Wochen davor"
        case .all: ""
        }
    }
}

struct Totals {
    var distance = 0.0
    var seconds = 0.0
    var steps = 0
    var kcal = 0.0
    var count = 0

    init(_ sessions: [WorkoutSession]) {
        for s in sessions {
            distance += s.distance_km
            seconds += s.active_s
            steps += s.steps
            kcal += s.kcal
        }
        count = sessions.count
    }

    var avgSpeed: Double { seconds > 0 ? distance / (seconds / 3600) : 0 }
}

struct DistanceBin: Identifiable, Equatable {
    let start: Date
    let km: Double
    let seconds: Double
    let count: Int
    var id: Date { start }
}

struct CumPoint: Identifiable {
    let date: Date
    let km: Double
    var id: Date { date }
}

struct HeatCell: Identifiable, Equatable {
    let dayIndex: Int
    let hour: Int
    let minutes: Double
    var id: Int { dayIndex * 24 + hour }
    var weekday: String { weekdayLabels[dayIndex] }
}

struct DaySteps: Identifiable {
    let day: Date
    let steps: Int
    var id: Date { day }
}

struct PeriodStats {
    let range: StatsRange
    let unit: Calendar.Component
    let start: Date
    let end: Date
    let current: [WorkoutSession]
    let totals: Totals
    let prevTotals: Totals?
    let bins: [DistanceBin]
    let cumulativeCurrent: [CumPoint]
    let cumulativePrevious: [CumPoint]
    let heat: [HeatCell]
    let heatMax: Double

    init(all: [WorkoutSession], range: StatsRange, now: Date = .now) {
        let cal = deCalendar
        let today = cal.startOfDay(for: now)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        let weekAgo = cal.date(byAdding: .day, value: -6, to: today)!
        var start = weekAgo
        var end = tomorrow
        var unit: Calendar.Component = .day
        var prevStart: Date?

        switch range {
        case .week:
            prevStart = cal.date(byAdding: .day, value: -7, to: start)
        case .month:
            start = cal.date(byAdding: .day, value: -29, to: today)!
            prevStart = cal.date(byAdding: .day, value: -30, to: start)
        case .quarter:
            let week = cal.dateInterval(of: .weekOfYear, for: now)!
            start = cal.date(byAdding: .weekOfYear, value: -11, to: week.start)!
            end = week.end
            unit = .weekOfYear
            prevStart = cal.date(byAdding: .weekOfYear, value: -12, to: start)
        case .all:
            if let first = all.map(\.start).min() {
                start = min(cal.startOfDay(for: first), weekAgo)
            }
            if (cal.dateComponents([.day], from: start, to: today).day ?? 0) > 60 {
                unit = .weekOfYear
                start = cal.dateInterval(of: .weekOfYear, for: start)!.start
                end = cal.dateInterval(of: .weekOfYear, for: now)!.end
            }
        }

        self.range = range
        self.unit = unit
        self.start = start
        self.end = end

        let current = all.filter { $0.start >= start && $0.start < end }
        self.current = current
        totals = Totals(current)
        let previous = prevStart.map { ps in all.filter { $0.start >= ps && $0.start < start } }
        prevTotals = previous.map { Totals($0) }

        func bucket(_ d: Date) -> Date { cal.dateInterval(of: unit, for: d)!.start }
        func next(_ d: Date) -> Date { cal.date(byAdding: unit, value: 1, to: d)! }

        let grouped = Dictionary(grouping: current) { bucket($0.start) }
        var bins: [DistanceBin] = []
        var cursor = start
        while cursor < end {
            let s = grouped[cursor] ?? []
            bins.append(DistanceBin(start: cursor,
                                    km: s.reduce(0) { $0 + $1.distance_km },
                                    seconds: s.reduce(0) { $0 + $1.active_s },
                                    count: s.count))
            cursor = next(cursor)
        }
        self.bins = bins

        // Kumuliert: jeweils am Ende eines Tages/einer Woche; aktueller Zeitraum nur bis jetzt
        var cum = [CumPoint(date: start, km: 0)]
        var run = 0.0
        for b in bins {
            run += b.km
            cum.append(CumPoint(date: min(next(b.start), now), km: run))
        }
        cumulativeCurrent = cum

        var prevCum: [CumPoint] = []
        if let previous, let ps = prevStart {
            let pg = Dictionary(grouping: previous) { bucket($0.start) }
            var prun = 0.0
            var pc = ps
            prevCum.append(CumPoint(date: start, km: 0))
            for b in bins {
                prun += (pg[pc] ?? []).reduce(0) { $0 + $1.distance_km }
                prevCum.append(CumPoint(date: next(b.start), km: prun))
                pc = next(pc)
            }
        }
        cumulativePrevious = prevCum

        // Heatmap: Minuten je Wochentag x Stunde, Trainings ueber Stundengrenzen aufgeteilt
        var minutes: [String: Double] = [:]
        for s in current {
            var t = s.start
            let stop = s.start.addingTimeInterval(s.active_s)
            while t < stop {
                let hourEnd = cal.dateInterval(of: .hour, for: t)!.end
                let segmentEnd = min(stop, hourEnd)
                let weekday = (cal.component(.weekday, from: t) + 5) % 7
                let hour = cal.component(.hour, from: t)
                minutes["\(weekday)-\(hour)", default: 0] += segmentEnd.timeIntervalSince(t) / 60
                t = segmentEnd
            }
        }
        var heat: [HeatCell] = []
        for wd in 0..<7 {
            for h in 0..<24 {
                heat.append(HeatCell(dayIndex: wd, hour: h, minutes: minutes["\(wd)-\(h)"] ?? 0))
            }
        }
        self.heat = heat
        heatMax = heat.map(\.minutes).max() ?? 0
    }
}

struct Streak {
    let current: Int
    let best: Int

    init(sessions: [WorkoutSession], now: Date = .now) {
        let cal = deCalendar
        let days = Set(sessions.map { cal.startOfDay(for: $0.start) })
        func shift(_ d: Date, _ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: d)! }

        var best = 0
        for d in days where !days.contains(shift(d, -1)) {
            var length = 1
            var cursor = shift(d, 1)
            while days.contains(cursor) {
                length += 1
                cursor = shift(cursor, 1)
            }
            best = max(best, length)
        }

        var cursor = cal.startOfDay(for: now)
        if !days.contains(cursor) { cursor = shift(cursor, -1) }
        var current = 0
        while days.contains(cursor) {
            current += 1
            cursor = shift(cursor, -1)
        }
        self.current = current
        self.best = best
    }
}
