import SwiftUI
import EventKit
import AppKit

struct TimelineBlock: Identifiable {
    let title: String
    let start: Date
    let end: Date
    var id: String { "\(title)-\(start.timeIntervalSince1970)" }
}

struct CalendarStats {
    let walkSeconds: Double
    let meetingSeconds: Double
    let day: Date?
    let events: [TimelineBlock]
    let walks: [TimelineBlock]

    var share: Double { walkSeconds > 0 ? meetingSeconds / walkSeconds : 0 }
}

@MainActor
final class CalendarContext: ObservableObject {
    enum Access { case notDetermined, granted, denied }

    @Published var access: Access = .notDetermined
    @Published var stats: CalendarStats?
    private let store = EKEventStore()

    init() { refreshAccess() }

    func refreshAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: access = .granted
        case .notDetermined: access = .notDetermined
        default: access = .denied
        }
    }

    func requestAccess() async {
        _ = try? await store.requestFullAccessToEvents()
        refreshAccess()
    }

    func compute(sessions: [WorkoutSession], from start: Date, to end: Date) {
        guard access == .granted else { return }
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { !$0.isAllDay }
        var walk = 0.0, meeting = 0.0
        for s in sessions where s.start >= start && s.start < end {
            let sEnd = s.start.addingTimeInterval(s.active_s)
            walk += s.active_s
            // parallele Termine nicht doppelt zaehlen
            let overlaps = events.compactMap { e -> (Date, Date)? in
                let a = max(e.startDate, s.start), b = min(e.endDate, sEnd)
                return a < b ? (a, b) : nil
            }.sorted { $0.0 < $1.0 }
            var merged: [(Date, Date)] = []
            for o in overlaps {
                if let last = merged.last, o.0 <= last.1 {
                    merged[merged.count - 1].1 = max(last.1, o.1)
                } else {
                    merged.append(o)
                }
            }
            meeting += merged.reduce(0) { $0 + $1.1.timeIntervalSince($1.0) }
        }

        let cal = deCalendar
        let lastDay = sessions.filter { $0.start >= start && $0.start < end }.map(\.start).max().map { cal.startOfDay(for: $0) }
        var dayEvents: [TimelineBlock] = []
        var dayWalks: [TimelineBlock] = []
        if let lastDay {
            let dayEnd = cal.date(byAdding: .day, value: 1, to: lastDay)!
            dayEvents = events.filter { $0.startDate < dayEnd && $0.endDate > lastDay }
                .map { TimelineBlock(title: $0.title ?? "Termin", start: $0.startDate, end: $0.endDate) }
            dayWalks = sessions.filter { cal.isDate($0.start, inSameDayAs: lastDay) }
                .map { TimelineBlock(title: "\(Fmt.num($0.distance_km, 2)) km", start: $0.start, end: $0.start.addingTimeInterval($0.active_s)) }
        }
        stats = CalendarStats(walkSeconds: walk, meetingSeconds: meeting, day: lastDay, events: dayEvents, walks: dayWalks)
    }
}

struct CalendarContextCard: View {
    let sessions: [WorkoutSession]
    let start: Date
    let end: Date
    @StateObject private var context = CalendarContext()
    @State private var hovered: TimelineBlock?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(title: "Gehen & Termine", subtitle: "Wie viel du in Meetings gehst – lokal aus deinem Kalender")
            switch context.access {
            case .notDetermined:
                VStack(alignment: .leading, spacing: 10) {
                    Text("Verbinde deinen Kalender, um zu sehen, wie viel deiner Gehzeit in Terminen liegt. Die Auswertung bleibt auf diesem Mac.")
                        .font(.callout).foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Task {
                            await context.requestAccess()
                            context.compute(sessions: sessions, from: start, to: end)
                        }
                    } label: {
                        Label("Kalender verbinden", systemImage: "calendar.badge.plus")
                    }
                    .buttonStyle(.glassProminent)
                }
            case .denied:
                VStack(alignment: .leading, spacing: 10) {
                    Text("Kein Zugriff auf den Kalender. Du kannst ihn unter Datenschutz & Sicherheit → Kalender für „Saunter“ erlauben.")
                        .font(.callout).foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Einstellungen öffnen") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                    }
                    .buttonStyle(.glass)
                }
            case .granted:
                granted
            }
        }
        .card()
        .task(id: "\(sessions.count)-\(start.timeIntervalSince1970)") {
            context.compute(sessions: sessions, from: start, to: end)
        }
    }

    @ViewBuilder
    private var granted: some View {
        if let stats = context.stats, stats.walkSeconds > 0 {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(Int((stats.share * 100).rounded())) %")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("deiner Gehzeit lag in Terminen").foregroundStyle(Palette.ink2)
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    if stats.meetingSeconds > 0 {
                        UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                               bottomTrailingRadius: stats.share >= 0.999 ? 4 : 0,
                                               topTrailingRadius: stats.share >= 0.999 ? 4 : 0)
                            .fill(Palette.series)
                            .frame(width: max(2, (geo.size.width - 2) * stats.share))
                    }
                    if stats.share < 0.999 {
                        UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 4, topTrailingRadius: 4)
                            .fill(Palette.baseline)
                    }
                }
            }
            .frame(height: 14)
            HStack(spacing: 16) {
                LegendKey(color: Palette.series, label: "In Terminen · \(Fmt.minutes(stats.meetingSeconds))")
                LegendKey(color: Palette.baseline, label: "Außerhalb · \(Fmt.minutes(stats.walkSeconds - stats.meetingSeconds))")
            }
            if let day = stats.day {
                timeline(day: day, stats: stats)
            }
        } else {
            Text("Noch keine Trainings im Zeitraum.").foregroundStyle(Palette.muted)
        }
    }

    private func timeline(day: Date, stats: CalendarStats) -> some View {
        let from = deCalendar.date(byAdding: .hour, value: 6, to: day)!
        let to = deCalendar.date(byAdding: .hour, value: 22, to: day)!
        let span = to.timeIntervalSince(from)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Tagesverlauf \(Fmt.day(day))").font(.caption.weight(.medium)).foregroundStyle(Palette.ink2)
            GeometryReader { geo in
                let x = { (d: Date) in CGFloat(min(max(d.timeIntervalSince(from) / span, 0), 1)) * geo.size.width }
                ZStack(alignment: .topLeading) {
                    ForEach([6, 9, 12, 15, 18, 21], id: \.self) { h in
                        let d = deCalendar.date(byAdding: .hour, value: h, to: day)!
                        Rectangle().fill(Palette.grid).frame(width: 1, height: 58).offset(x: x(d))
                        Text("\(h)").font(.caption2).foregroundStyle(Palette.muted).offset(x: x(d) + 3, y: 60)
                    }
                    ForEach(stats.events) { e in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Palette.baseline.opacity(hovered?.id == e.id ? 1 : 0.7))
                            .frame(width: max(3, x(e.end) - x(e.start)), height: 22)
                            .offset(x: x(e.start), y: 2)
                            .onHover { if $0 { hovered = e } else if hovered?.id == e.id { hovered = nil } }
                    }
                    ForEach(stats.walks) { w in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Palette.series.opacity(hovered?.id == w.id ? 1 : 0.9))
                            .frame(width: max(3, x(w.end) - x(w.start)), height: 22)
                            .offset(x: x(w.start), y: 30)
                            .onHover { if $0 { hovered = w } else if hovered?.id == w.id { hovered = nil } }
                    }
                }
            }
            .frame(height: 76)
            HStack(spacing: 16) {
                LegendKey(color: Palette.baseline, label: "Termine")
                LegendKey(color: Palette.series, label: "Laufband")
                Spacer()
                if let h = hovered {
                    Text("\(h.title) · \(Fmt.time(h.start))–\(Fmt.time(h.end))").font(.caption).foregroundStyle(Palette.ink2)
                }
            }
        }
    }
}
