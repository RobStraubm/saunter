import SwiftUI

struct StreakDay: Decodable, Hashable {
    let date: String
    let state: String      // done, open, pending, excused, missed, optional, future
    let minutes: Double

    var day: Date { Self.parser.date(from: date) ?? .now }

    static let parser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = deCalendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

struct StreakInfo: Decodable {
    let current: Int
    let best: Int
    let required_min: Double
    let today: StreakDay
    let at_risk: Bool
    let pending: [String]
    let week: [StreakDay]

    var todayDone: Bool { today.state == "done" }
    var minutesLeftToday: Double { max(0, required_min - today.minutes) }
}

extension Palette {
    /// Flammen-Orange (Kategorie-Slot 2) – nur fuer das Streak-Symbol, nicht fuer Daten.
    static let flame = Color.adaptive(0xEB6834, 0xD95926)
}

// MARK: - Flamme

struct StreakFlame: View {
    let streak: StreakInfo
    var size: CGFloat = 18

    var body: some View {
        HStack(spacing: size * 0.2) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: streak.todayDone ? "flame.fill" : "flame")
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(streak.todayDone ? AnyShapeStyle(flameGradient) : AnyShapeStyle(Palette.muted))
                    .symbolEffect(.bounce, value: streak.todayDone)
                if !streak.pending.isEmpty {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: size * 0.5, weight: .bold))
                        .foregroundStyle(Palette.series)
                        .background(Circle().fill(Palette.surface).padding(1))
                        .offset(x: size * 0.25, y: -size * 0.15)
                }
            }
            Text("\(streak.current)")
                .font(.system(size: size * 0.95, weight: .bold))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(streak.current)))
        }
        .help(helpText)
    }

    private var flameGradient: LinearGradient {
        LinearGradient(colors: [Color(nsColor: NSColor(hex: 0xFAB219)), Palette.flame], startPoint: .top, endPoint: .bottom)
    }

    private var helpText: String {
        if streak.todayDone { return "Wanderstreak: \(streak.current) Tage – heute erledigt" }
        if streak.at_risk { return "Wanderstreak: heute noch \(Fmt.num(streak.minutesLeftToday, 0)) min" }
        return "Wanderstreak: \(streak.current) Tage"
    }
}

// MARK: - Buero-Frage

struct StreakQuestion: View {
    let dateString: String
    let answer: (Bool) -> Void   // true = nicht im Buero (entschuldigt)

    var body: some View {
        let day = StreakDay.parser.date(from: dateString) ?? .now
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle.fill").foregroundStyle(Palette.series)
                Text("Warst du am \(day.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Fmt.de))) im Büro?")
                    .font(.callout.weight(.semibold))
            }
            Text("An dem Tag bist du keine \(Fmt.int(5)) Minuten gelaufen. Warst du nicht im Büro, bleibt dein Streak erhalten.")
                .font(.caption).foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button { answer(true) } label: { Label("Nicht im Büro", systemImage: "house") }
                    .buttonStyle(.glassProminent)
                Button { answer(false) } label: { Label("War im Büro", systemImage: "building.2") }
                    .buttonStyle(.glass)
            }
            .controlSize(.small)
        }
    }
}

// MARK: - Kompakt im Menueleisten-Panel

struct PanelStreakRow: View {
    let streak: StreakInfo
    let mark: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                StreakFlame(streak: streak, size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Wanderstreak").font(.caption.weight(.semibold))
                    Text(line).font(.caption).foregroundStyle(Palette.ink2)
                }
                Spacer()
            }
            if let first = streak.pending.first {
                StreakQuestion(dateString: first) { excused in mark(first, excused ? "excused" : "present") }
            } else if streak.at_risk {
                Button("Heute nicht im Büro") { mark(streak.today.date, "excused") }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
    }

    private var line: String {
        switch streak.today.state {
        case "done": return "Heute erledigt · Rekord \(streak.best)"
        case "open": return "Heute noch \(Fmt.num(streak.minutesLeftToday, 0)) min"
        case "excused": return "Heute nicht im Büro"
        default: return "Wochenende – freiwillig"
        }
    }
}

// MARK: - Karte in der Uebersicht

struct StreakCard: View {
    let streak: StreakInfo
    let mark: (String, String) -> Void   // Datum, Status (excused / present / clear)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                CardTitle(title: "Wanderstreak", subtitle: "Jeden Werktag mind. \(Fmt.num(streak.required_min, 0)) min")
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(streak.best)").font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(Palette.ink)
                    Text("Rekord").font(.caption).foregroundStyle(Palette.ink2)
                }
            }

            HStack(alignment: .center, spacing: 14) {
                StreakFlame(streak: streak, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(streak.current == 1 ? "Tag in Folge" : "Tage in Folge")
                        .font(.headline).foregroundStyle(Palette.ink)
                    Text(statusLine).font(.callout).foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            weekRow

            if let first = streak.pending.first {
                StreakQuestion(dateString: first) { excused in
                    mark(first, excused ? "excused" : "present")
                }
                .padding(12)
                .background(Palette.series.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .card()
    }

    private var statusLine: String {
        switch streak.today.state {
        case "done": return "Heute erledigt (\(Fmt.num(streak.today.minutes, 0)) min) – stark!"
        case "open": return "Heute noch \(Fmt.num(streak.minutesLeftToday, 0)) min laufen, um den Streak zu halten."
        case "excused": return "Heute als „nicht im Büro“ markiert – der Streak bleibt."
        default: return "Wochenende – freiwillig, zählt aber als Bonus."
        }
    }

    private var weekRow: some View {
        HStack(spacing: 10) {
            ForEach(streak.week, id: \.date) { day in
                VStack(spacing: 5) {
                    dayCircle(day)
                    Text(day.day.formatted(.dateTime.weekday(.abbreviated).locale(Fmt.de)))
                        .font(.caption2.weight(day.date == streak.today.date ? .bold : .regular))
                        .foregroundStyle(day.date == streak.today.date ? Palette.ink : Palette.muted)
                }
                .help(help(for: day))
                .contextMenu {
                    if ["pending", "missed", "open"].contains(day.state) {
                        Button("Nicht im Büro (zählt nicht gegen den Streak)") { mark(day.date, "excused") }
                    }
                    if day.state == "excused" {
                        Button("Markierung entfernen") { mark(day.date, "clear") }
                    }
                    if day.state == "pending" {
                        Button("War im Büro") { mark(day.date, "present") }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func dayCircle(_ day: StreakDay) -> some View {
        let size: CGFloat = 30
        switch day.state {
        case "done":
            Circle().fill(Palette.flame).frame(width: size, height: size)
                .overlay(Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(.white))
        case "excused":
            Circle().fill(Palette.grid).frame(width: size, height: size)
                .overlay(Image(systemName: "house.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink2))
        case "pending":
            Circle().strokeBorder(Palette.series, lineWidth: 2).frame(width: size, height: size)
                .overlay(Image(systemName: "questionmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.series))
        case "missed":
            Circle().fill(Palette.grid).frame(width: size, height: size)
                .overlay(Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.muted))
        case "open":
            Circle().strokeBorder(Palette.flame, style: StrokeStyle(lineWidth: 2, dash: [3, 3])).frame(width: size, height: size)
        default: // optional, future
            Circle().strokeBorder(Palette.grid, lineWidth: 2).frame(width: size, height: size)
        }
    }

    private func help(for day: StreakDay) -> String {
        let label = day.day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).locale(Fmt.de))
        switch day.state {
        case "done": return "\(label): \(Fmt.num(day.minutes, 0)) min gelaufen"
        case "excused": return "\(label): nicht im Büro"
        case "pending": return "\(label): Frage offen – im Büro gewesen?"
        case "missed": return "\(label): verpasst"
        case "open": return "\(label): noch offen"
        case "optional": return "\(label): Wochenende (freiwillig)"
        default: return label
        }
    }
}
