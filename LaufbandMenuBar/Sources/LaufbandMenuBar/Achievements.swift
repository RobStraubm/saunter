import SwiftUI

/// Kennzahlen, aus denen die Erfolge berechnet werden.
struct AchievementStats {
    var totalKm = 0.0
    var totalSteps = 0.0
    var maxDaySteps = 0.0
    var longestMinutes = 0.0
    var farthestKm = 0.0
    var sessions = 0.0
    var streakBest = 0.0
    var weeksGoalReached = 0.0
    var earlyBird = 0.0
    var nightOwl = 0.0
    var fastSessions = 0.0

    init() {}

    init(sessions all: [WorkoutSession], streak: StreakInfo?, weeklyGoalKm: Double) {
        let cal = deCalendar
        totalKm = all.reduce(0) { $0 + $1.distance_km }
        totalSteps = Double(all.reduce(0) { $0 + $1.steps })
        sessions = Double(all.count)
        longestMinutes = (all.map(\.active_s).max() ?? 0) / 60
        farthestKm = all.map(\.distance_km).max() ?? 0
        var byDay: [Date: Int] = [:]
        var byWeek: [Date: Double] = [:]
        for s in all {
            byDay[cal.startOfDay(for: s.start), default: 0] += s.steps
            byWeek[cal.dateInterval(of: .weekOfYear, for: s.start)!.start, default: 0] += s.distance_km
            let hour = cal.component(.hour, from: s.start)
            if hour < 8 && s.active_s >= 300 { earlyBird += 1 }
            if hour >= 21 && s.active_s >= 300 { nightOwl += 1 }
            if s.active_s >= 600 && s.avgSpeed >= 5 { fastSessions += 1 }
        }
        maxDaySteps = Double(byDay.values.max() ?? 0)
        weeksGoalReached = Double(byWeek.values.filter { $0 >= weeklyGoalKm && weeklyGoalKm > 0 }.count)
        streakBest = Double(streak?.best ?? 0)
    }
}

struct Achievement: Identifiable {
    let id: String
    let category: String
    let title: String
    let detail: String
    let message: String
    let symbol: String
    let target: Double
    let unit: String
    let value: (AchievementStats) -> Double
}

struct AchievementState: Identifiable {
    let achievement: Achievement
    let current: Double
    let unlockedAt: Date?
    var id: String { achievement.id }
    var progress: Double { min(1, current / max(achievement.target, 0.0001)) }
}

enum AchievementCatalog {
    @MainActor
    static func all() -> [Achievement] {
        let lap = RouteGeometryStore.shared.geometries["bodensee"]?.totalKm ?? 260
        var list: [Achievement] = []
        func add(_ id: String, _ category: String, _ title: String, _ detail: String, _ message: String,
                 _ symbol: String, _ target: Double, _ unit: String, _ value: @escaping (AchievementStats) -> Double) {
            list.append(Achievement(id: id, category: category, title: title, detail: detail, message: message,
                                    symbol: symbol, target: target, unit: unit, value: value))
        }

        let km = "Kilometer"
        add("km-first", km, "Erste Schritte", "Das erste Training", "Der Anfang ist gemacht – willkommen auf dem Band!", "shoeprints.fill", 1, "Training") { $0.sessions }
        add("km-10", km, "Zehner", "10 km insgesamt", "10 Kilometer! Das ist einmal quer durch Konstanz und zurück.", "10.circle.fill", 10, "km") { $0.totalKm }
        add("km-21", km, "Halbmarathon", "21,1 km insgesamt", "Du bist insgesamt einen Halbmarathon gegangen.", "figure.walk.motion", 21.1, "km") { $0.totalKm }
        add("km-42", km, "Marathon", "42,2 km insgesamt", "Ein ganzer Marathon – Schritt für Schritt am Schreibtisch!", "medal.fill", 42.2, "km") { $0.totalKm }
        add("km-100", km, "Hunderter", "100 km insgesamt", "Dreistellig! 100 Kilometer auf dem Laufband.", "trophy.fill", 100, "km") { $0.totalKm }
        add("km-lap", km, "Seeumrunder", "Einmal die Bodensee-Runde (\(Fmt.num(lap, 0)) km)", "So weit wie einmal rund um den Bodensee!", "water.waves", lap, "km") { $0.totalKm }
        add("km-500", km, "Fünfhunderter", "500 km insgesamt", "500 Kilometer – das ist Konstanz bis Florenz.", "star.circle.fill", 500, "km") { $0.totalKm }
        add("km-1000", km, "Tausender", "1.000 km insgesamt", "Tausend Kilometer. Legendär.", "crown.fill", 1000, "km") { $0.totalKm }

        let steps = "Schritte"
        for (target, title) in [(10_000.0, "10.000 Schritte"), (50_000.0, "50.000 Schritte"), (100_000.0, "100.000 Schritte"),
                                (250_000.0, "250.000 Schritte"), (500_000.0, "Halbe Million"), (1_000_000.0, "Schritt-Millionär")] {
            add("steps-\(Int(target))", steps, title, "\(Fmt.int(target)) Schritte insgesamt",
                "\(Fmt.int(target)) Schritte hast du jetzt insgesamt gesammelt!", "shoeprints.fill", target, "Schritte") { $0.totalSteps }
        }
        add("day-5000", steps, "Guter Tag", "5.000 Schritte an einem Tag", "5.000 Schritte an einem Tag – stark!", "sun.max.fill", 5000, "Schritte") { $0.maxDaySteps }
        add("day-10000", steps, "Tagesziel-Held", "10.000 Schritte an einem Tag", "10.000 Schritte an einem Tag. Genau so!", "sun.max.circle.fill", 10_000, "Schritte") { $0.maxDaySteps }

        let session = "Einzeltraining"
        add("s-30", session, "Halbe Stunde", "30 Minuten am Stück", "30 Minuten am Stück gegangen!", "timer", 30, "min") { $0.longestMinutes }
        add("s-60", session, "Volle Stunde", "60 Minuten am Stück", "Eine ganze Stunde auf dem Band!", "clock.fill", 60, "min") { $0.longestMinutes }
        add("s-90", session, "Ausdauer", "90 Minuten am Stück", "90 Minuten – beeindruckende Ausdauer.", "hourglass", 90, "min") { $0.longestMinutes }
        add("s-5km", session, "Fünfer", "5 km in einem Training", "5 Kilometer in einem einzigen Training!", "figure.walk", 5, "km") { $0.farthestKm }
        add("s-10km", session, "Zehner am Stück", "10 km in einem Training", "10 Kilometer am Stück – Wahnsinn!", "flag.checkered", 10, "km") { $0.farthestKm }
        add("s-fast", session, "Flotter Schritt", "10 min mit Ø ab 5 km/h", "Zügig unterwegs: 10 Minuten mit mehr als 5 km/h Schnitt.", "hare.fill", 1, "Training") { $0.fastSessions }

        let streak = "Wanderstreak"
        for (target, title) in [(3.0, "Dranbleiber"), (5.0, "Arbeitswoche"), (10.0, "Zehn am Stück"),
                                (20.0, "Gewohnheit"), (50.0, "Unaufhaltsam"), (100.0, "Hundert-Tage-Flamme")] {
            add("streak-\(Int(target))", streak, title, "\(Int(target)) Tage Wanderstreak",
                "\(Int(target)) Tage Wanderstreak – die Flamme brennt!", "flame.fill", target, "Tage") { $0.streakBest }
        }

        let special = "Besonderes"
        add("week-goal", special, "Wochenziel geschafft", "Einmal das Wochenziel erreicht", "Wochenziel erreicht – was für eine Woche!", "target", 1, "Woche") { $0.weeksGoalReached }
        add("early", special, "Frühaufsteher", "Training vor 8 Uhr", "Früh auf den Beinen – Training vor 8 Uhr!", "sunrise.fill", 1, "Training") { $0.earlyBird }
        add("night", special, "Nachteule", "Training nach 21 Uhr", "Abends noch eine Runde – Respekt!", "moon.stars.fill", 1, "Training") { $0.nightOwl }

        // Bodensee-Etappen: Gesamtkilometer auf der Runde ab Konstanz
        let stages: [(String, String, String)] = [
            ("Kreuzlingen", "Grenzgänger", "Willkommen in der Schweiz – Kreuzlingen erreicht!"),
            ("Romanshorn", "Romanshorn", "Am Schweizer Ufer bis Romanshorn!"),
            ("Bregenz", "Servus Österreich", "Bregenz erreicht – du bist in Österreich!"),
            ("Lindau", "Inselstadt", "Lindau erreicht – zurück in Deutschland."),
            ("Friedrichshafen", "Zeppelinstadt", "Friedrichshafen erreicht!"),
            ("Meersburg", "Meersburg", "In Meersburg angekommen – mit Blick auf Konstanz."),
            ("Überlingen", "Überlingen", "Überlingen erreicht – der See wird schmaler."),
            ("Stein am Rhein", "Am Rhein", "Stein am Rhein erreicht – fast wieder daheim!"),
        ]
        if let g = RouteGeometryStore.shared.geometries["bodensee"] {
            let route = JourneyRoute.all[0]
            for (name, title, message) in stages {
                if let i = route.waypoints.firstIndex(where: { $0.name == name }) {
                    add("bs-\(name)", "Bodensee-Etappen", title, "\(name) (km \(Fmt.num(g.stageKm[i], 0)))", message,
                        "mappin.circle.fill", g.stageKm[i], "km") { $0.totalKm }
                }
            }
            add("bs-lap", "Bodensee-Etappen", "Einmal rum!", "Zurück in Konstanz", "Einmal rund um den Bodensee – zurück in Konstanz!",
                "arrow.triangle.2.circlepath.circle.fill", g.totalKm, "km") { $0.totalKm }
        }
        return list
    }
}

@MainActor
final class AchievementCenter: ObservableObject {
    static let shared = AchievementCenter()

    @Published private(set) var states: [AchievementState] = []
    private var unlocked: [String: Double]
    private var sessions: [WorkoutSession] = []
    private var lastLoad = Date.distantPast
    private var lastLiveID: Int?
    private var loading = false

    init() {
        unlocked = UserDefaults.standard.dictionary(forKey: "achievements.unlocked") as? [String: Double] ?? [:]
    }

    /// Wird mit jedem Status aufgerufen; Trainingsliste wird hoechstens jede Minute neu geladen.
    func update(status: Status?) {
        let liveID = status?.session?.id
        if !loading && (Date().timeIntervalSince(lastLoad) > 60 || liveID != lastLiveID) {
            loading = true
            lastLiveID = liveID
            Task { @MainActor in
                let data = DashboardData()
                await data.loadSessions()
                if data.reachable { sessions = data.sessions }
                lastLoad = Date()
                loading = false
                evaluate(status: status)
            }
        }
        evaluate(status: status)
    }

    private func evaluate(status: Status?) {
        guard lastLoad != .distantPast else { return }
        var all = sessions
        if let s = status?.session {
            all = all.filter { $0.id != s.id } + [WorkoutSession(id: s.id, start_ts: s.start_ts, active_s: Double(s.active_s),
                                                               distance_km: s.distance_km, kcal: s.kcal, steps: s.steps,
                                                               max_speed_kmh: s.max_speed, avg_speed_kmh: nil, has_samples: 1)]
        }
        let stats = AchievementStats(sessions: all, streak: status?.streak, weeklyGoalKm: status?.weekly_goal?.km ?? 0)
        let firstRun = UserDefaults.standard.object(forKey: "achievements.initialized") == nil
        var newlyUnlocked: [Achievement] = []
        states = AchievementCatalog.all().map { a in
            let value = a.value(stats)
            if value >= a.target, unlocked[a.id] == nil {
                unlocked[a.id] = Date().timeIntervalSince1970
                newlyUnlocked.append(a)
            }
            return AchievementState(achievement: a, current: value, unlockedAt: unlocked[a.id].map { Date(timeIntervalSince1970: $0) })
        }
        if !newlyUnlocked.isEmpty {
            UserDefaults.standard.set(unlocked, forKey: "achievements.unlocked")
        }
        if firstRun {
            // bereits frueher erreichte Erfolge still uebernehmen, nicht alle auf einmal feiern
            UserDefaults.standard.set(true, forKey: "achievements.initialized")
            return
        }
        for a in newlyUnlocked {
            CelebrationCenter.shared.celebrate(symbol: a.symbol, title: "Erfolg: \(a.title)", message: a.message)
        }
    }
}

// MARK: - Seite "Erfolge"

struct AchievementsPage: View {
    @ObservedObject private var center = AchievementCenter.shared

    var body: some View {
        let states = center.states
        let done = states.filter { $0.unlockedAt != nil }.count
        let categories = states.reduce(into: [String]()) { if !$0.contains($1.achievement.category) { $0.append($1.achievement.category) } }

        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(done) von \(states.count) Erfolgen")
                        .font(.system(size: 30, weight: .bold)).foregroundStyle(Palette.ink)
                    Text("Beim Erreichen gibt es Konfetti und Applaus.").foregroundStyle(Palette.ink2)
                }
                Spacer()
                Button {
                    CelebrationCenter.shared.celebrate(symbol: "trophy.fill", title: "Probe-Applaus", message: "So klingt und sieht ein neuer Erfolg aus.")
                } label: {
                    Label("Feier testen", systemImage: "party.popper")
                }
                .buttonStyle(.glass)
            }
            .card()

            if let next = states.filter({ $0.unlockedAt == nil }).max(by: { $0.progress < $1.progress }) {
                HStack(spacing: 14) {
                    Image(systemName: next.achievement.symbol).font(.system(size: 26, weight: .semibold)).foregroundStyle(Palette.series)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Als Nächstes: \(next.achievement.title)").font(.headline).foregroundStyle(Palette.ink)
                        Text("\(next.achievement.detail) · \(progressText(next))").font(.callout).foregroundStyle(Palette.ink2)
                        Meter(progress: next.progress)
                    }
                }
                .card()
            }

            ForEach(categories, id: \.self) { category in
                VStack(alignment: .leading, spacing: 14) {
                    CardTitle(title: category)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], alignment: .leading, spacing: 14) {
                        ForEach(states.filter { $0.achievement.category == category }) { state in
                            badge(state)
                        }
                    }
                }
                .card()
            }
        }
    }

    private func progressText(_ s: AchievementState) -> String {
        let digits = s.achievement.unit == "km" ? 1 : 0
        return "\(Fmt.num(min(s.current, s.achievement.target), digits)) / \(Fmt.num(s.achievement.target, digits)) \(s.achievement.unit)"
    }

    private func badge(_ state: AchievementState) -> some View {
        let unlocked = state.unlockedAt != nil
        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(unlocked ? AnyShapeStyle(LinearGradient(colors: [Color(nsColor: NSColor(hex: 0xFAB219)), Palette.flame],
                                                                  startPoint: .top, endPoint: .bottom))
                                   : AnyShapeStyle(Palette.grid))
                    .frame(width: 44, height: 44)
                if !unlocked {
                    Circle().trim(from: 0, to: state.progress)
                        .stroke(Palette.series, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 44, height: 44)
                }
                Image(systemName: state.achievement.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(unlocked ? .white : Palette.muted)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(state.achievement.title).font(.callout.weight(.semibold)).foregroundStyle(unlocked ? Palette.ink : Palette.ink2)
                Text(unlocked ? "erreicht am \(Fmt.shortDay(state.unlockedAt!))" : progressText(state))
                    .font(.caption).foregroundStyle(Palette.muted).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .help(state.achievement.detail)
    }
}
