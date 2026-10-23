import SwiftUI
import SystemConfiguration

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
    /// Letzte vier Wochen (aeltere Daemon-Versionen liefern das nicht).
    let recent: [StreakDay]?
    let week_streak: WeekStreak?

    var todayDone: Bool { today.state == "done" }
    /// Vergangene Werktage zum Nachtragen, neueste zuerst.
    var editableDays: [StreakDay] {
        (recent ?? week).filter { $0.date < today.date && !deCalendar.isDateInWeekend($0.day) }.reversed()
    }
    var minutesLeftToday: Double { max(0, required_min - today.minutes) }
}

/// Wochen-Streak: pro Woche Buerotage minus Cheat-Day als Lauftage; Wochen ohne Ziel sind neutral.
struct WeekStreak: Decodable {
    let current: Int
    let best: Int
    let weeks_reached: Int
    let cheat_days: Int
    let office_days: Int
    let required_days: Int
    let walk_days: Int
    let state: String      // reached, open, free, missed

    var fraction: Double { required_days > 0 ? min(1, Double(walk_days) / Double(required_days)) : 1 }
    var daysLeft: Int { max(0, required_days - walk_days) }
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

// MARK: - Buero-Erkennung

/// Erkennt das Buero am Router (MAC-Adresse des Standard-Gateways) statt nachzufragen.
/// Der WLAN-Name waere unter macOS 26 nur mit Ortungsfreigabe lesbar, der Router nicht.
enum OfficeNetwork {
    private static let defaults = UserDefaults.standard

    static var known: [String] { defaults.stringArray(forKey: "office.gateways") ?? [] }
    /// Ab diesem Tag werden offene Werktage still beantwortet (yyyy-MM-dd).
    static var since: String? { defaults.string(forKey: "office.since") }
    /// Tage, an denen der Mac im Buero-Netz war.
    static var seenDays: [String] { defaults.stringArray(forKey: "office.seenDays") ?? [] }

    static func remember(_ gateway: String) {
        let today = StreakDay.parser.string(from: .now)
        if !known.contains(gateway) { defaults.set(known + [gateway], forKey: "office.gateways") }
        if since == nil { defaults.set(today, forKey: "office.since") }
        markSeen(today)
    }

    static func forget() {
        for key in ["office.gateways", "office.since", "office.seenDays"] { defaults.removeObject(forKey: key) }
    }

    static func markSeen(_ day: String) {
        guard !seenDays.contains(day) else { return }
        defaults.set(Array((seenDays + [day]).suffix(60)), forKey: "office.seenDays")
    }

    /// MAC-Adresse des Routers im aktuellen Netz, z. B. "bc:cf:4f:d0:b8:99"; nil ohne Netz.
    /// Aus der Netzwerk-Konfiguration des Systems - `arp` sieht die Tabelle ohne Freigabe "Lokales Netzwerk" nicht.
    static func currentGateway() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "Laufband" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let service = global["PrimaryService"] as? String,
              let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(service)/IPv4" as CFString) as? [String: Any]
        else { return nil }
        if let mac = ipv4["ARPResolvedHardwareAddress"] as? String { return mac }
        let prefix = "IPv4.RouterHardwareAddress="
        return (ipv4["NetworkSignature"] as? String)?.split(separator: ";")
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }
}

/// Buero-Netz festlegen; danach fragt die App nicht mehr, ob du im Buero warst.
struct OfficeNetworkRow: View {
    @State private var known = OfficeNetwork.known
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(known.isEmpty ? "Büro-Netz: nicht festgelegt"
                                   : known.count == 1 ? "Büro-Netz: festgelegt" : "Büro-Netz: \(known.count) Netze")
                    .foregroundStyle(Palette.ink2)
                Spacer(minLength: 8)
                if !known.isEmpty {
                    Button("Vergessen") {
                        OfficeNetwork.forget()
                        known = []
                    }
                }
            }
            Button(known.isEmpty ? "Aktuelles Netz ist das Büro" : "Aktuelles Netz auch als Büro") {
                if let gateway = OfficeNetwork.currentGateway() {
                    OfficeNetwork.remember(gateway)
                    known = OfficeNetwork.known
                    note = nil
                } else {
                    note = "Kein Netz gefunden – ist der Mac verbunden?"
                }
            }
            Text(note ?? "Erkennt das Büro am Router, statt nachzufragen. Werktage ohne Büro-Netz zählen als „nicht im Büro“.")
                .font(.caption2)
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Buero-Frage

/// Alle offenen Tage auf einmal statt einer Frage pro Tag.
struct PendingDaysQuestion: View {
    let streak: StreakInfo
    let mark: (String, String) -> Void   // Datum, Status (excused / present)
    private let maxRows = 6

    var body: some View {
        let days = streak.pending.reversed().map { StreakDay(date: $0, state: "pending", minutes: 0) }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle.fill").foregroundStyle(Palette.series)
                Text(days.count == 1 ? "Warst du an diesem Tag im Büro?" : "Warst du an diesen \(days.count) Tagen im Büro?")
                    .font(.callout.weight(.semibold))
            }
            Text("Du bist dort keine \(Fmt.num(streak.required_min, 0)) Minuten gelaufen. Tage ohne Büro zählen nicht gegen deinen Streak.")
                .font(.caption).foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(days.prefix(maxRows), id: \.date) { day in
                OfficeDayRow(day: day, mark: mark)
            }
            if days.count > maxRows {
                Text("… und \(days.count - maxRows) weitere")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            if days.count > 1 {
                HStack {
                    Button { days.forEach { mark($0.date, "excused") } } label: {
                        Label("Alle nicht im Büro", systemImage: "house")
                    }
                    .buttonStyle(.glassProminent)
                    Button { days.forEach { mark($0.date, "present") } } label: {
                        Label("Alle im Büro", systemImage: "building.2")
                    }
                    .buttonStyle(.glass)
                }
                .controlSize(.small)
            }
        }
    }
}

/// Ein Werktag mit der Wahl Buero / nicht im Buero; gelaufene Tage zaehlen ohnehin.
struct OfficeDayRow: View {
    let day: StreakDay
    let mark: (String, String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(day.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(Fmt.de)))
                .font(.caption)
                .foregroundStyle(Palette.ink2)
            Spacer(minLength: 6)
            if day.state == "done" {
                Label("\(Fmt.num(day.minutes, 0)) min gelaufen", systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
            } else {
                choice("Büro", symbol: "building.2", selected: day.state == "missed") { mark(day.date, "present") }
                choice("Nicht im Büro", symbol: "house", selected: day.state == "excused") { mark(day.date, "excused") }
            }
        }
        .controlSize(.mini)
    }

    @ViewBuilder
    private func choice(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        if selected {
            Button(action: action) { Label(title, systemImage: symbol) }.buttonStyle(.glassProminent)
        } else {
            Button(action: action) { Label(title, systemImage: symbol) }.buttonStyle(.glass)
        }
    }
}

/// Buerotage der letzten vier Wochen nachtragen oder korrigieren.
struct OfficeDaysEditor: View {
    let streak: StreakInfo
    let mark: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bürotage eintragen").font(.headline)
            Text("An Tagen ohne Büro musst du nicht laufen – dein Streak bleibt.")
                .font(.caption).foregroundStyle(Palette.ink2)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(streak.editableDays, id: \.date) { day in
                        OfficeDayRow(day: day, mark: mark)
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: 380)
        }
        .padding(16)
        .frame(width: 330)
    }
}

/// Knopf, der den Eintrage-Dialog als Popover oeffnet.
struct OfficeDaysButton: View {
    let streak: StreakInfo
    let mark: (String, String) -> Void
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { Label("Bürotage", systemImage: "calendar") }
            .help("Bürotage der letzten Wochen eintragen")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                OfficeDaysEditor(streak: streak, mark: mark)
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
                OfficeDaysButton(streak: streak, mark: mark)
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            if !streak.pending.isEmpty {
                PendingDaysQuestion(streak: streak, mark: mark)
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
                OfficeDaysButton(streak: streak, mark: mark)
                    .buttonStyle(.glass)
                    .controlSize(.small)
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

            if !streak.pending.isEmpty {
                PendingDaysQuestion(streak: streak, mark: mark)
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
