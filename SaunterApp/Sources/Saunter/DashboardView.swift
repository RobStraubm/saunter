import SwiftUI
import Charts
import AppKit

enum DashboardTab: String, CaseIterable, Identifiable {
    case overview = "Übersicht"
    case analysis = "Analyse"
    case journey = "Reise"
    case achievements = "Erfolge"
    case sessions = "Trainings"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .analysis: "chart.xyaxis.line"
        case .journey: "map"
        case .achievements: "trophy"
        case .sessions: "list.bullet"
        }
    }
}

/// Segmentierte Auswahl als Liquid-Glass-Kapsel mit gleitender Markierung.
struct GlassSegmented<Item: Hashable & Identifiable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String
    var symbol: ((Item) -> String)?
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                let selected = item == selection
                Button {
                    withAnimation(.bouncy(duration: 0.35)) { selection = item }
                } label: {
                    HStack(spacing: 6) {
                        if let symbol { Image(systemName: symbol(item)) }
                        Text(title(item))
                    }
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Palette.ink : Palette.ink2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background {
                        if selected {
                            Capsule()
                                .fill(Palette.series.opacity(0.18))
                                .matchedGeometryEffect(id: "selection", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

enum Dimension: String, CaseIterable, Identifiable {
    case flat = "2D"
    case spatial = "3D"
    var id: Self { self }
}

// MARK: - Fenster

struct DashboardView: View {
    @ObservedObject var live: TreadmillModel
    @StateObject private var data = DashboardData()
    @ObservedObject private var journey = JourneyStore.shared
    @ObservedObject private var routes = RouteGeometryStore.shared
    @AppStorage("dashboard.tab") private var tab: DashboardTab = .overview
    @AppStorage("dashboard.range") private var range: StatsRange = .month
    @AppStorage("dashboard.3d") private var dimension: Dimension = .flat
    @State private var selectedID: Int?
    @Environment(\.openWindow) private var openWindow

    private var liveID: Int? { live.status?.session?.id }
    private var profileID: Int? { data.profileID(liveID: liveID, selectedID: selectedID) }

    var body: some View {
        ZStack(alignment: .top) {
            if tab == .journey {
                let sessions = data.allSessions(live: live)
                JourneyView(sessions: sessions, forecast: Forecast(sessions: sessions), store: journey)
                    .ignoresSafeArea()
            } else {
                ScrollView {
                    DashboardPage(live: live, data: data, journey: journey, tab: tab, range: range,
                                  threeD: dimension == .spatial, selectedID: $selectedID) {
                        withAnimation(.smooth) { tab = .journey }
                    }
                    .padding(.top, 72)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
            header
        }
        .frame(minWidth: 1120, minHeight: 760)
        .containerBackground(.thickMaterial, for: .window)
        .environment(\.locale, Fmt.de)
        .task {
            while !Task.isCancelled {
                await data.loadSessions()
                try? await Task.sleep(for: .seconds(20))
            }
        }
        .task(id: profileID) {
            guard let id = profileID else { return }
            while !Task.isCancelled {
                await data.loadSamples(for: id)
                guard live.status?.session?.id == id else { break }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .task(id: "\(dimension.rawValue)-\(data.sessions.count)-\(range.rawValue)") {
            guard dimension == .spatial else { return }
            let stats = PeriodStats(all: data.sessions, range: range)
            await data.loadRidge(for: stats.current)
        }
        .onChange(of: liveID) {
            Task { await data.loadSessions() }
        }
    }

    private var header: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 12) {
                Text("Saunter")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: Capsule())
                GlassSegmented(items: DashboardTab.allCases, selection: $tab, title: \.rawValue, symbol: \.symbol)
                Spacer(minLength: 8)
                ConnectionPill(status: live.daemonReachable ? live.status : nil)
                if !live.daemonReachable || live.status?.phase == "offline" || live.reconnecting {
                    ReconnectButton(model: live)
                        .buttonStyle(.glass)
                }
                if tab != .journey && tab != .achievements {
                    GlassSegmented(items: StatsRange.allCases, selection: $range, title: \.rawValue)
                    if tab != .sessions {
                        GlassSegmented(items: Dimension.allCases, selection: $dimension, title: \.rawValue,
                                       symbol: { $0 == .flat ? "square" : "cube" })
                            .help("Ausgewählte Diagramme dreidimensional zeigen")
                    }
                }
                Button {
                    openWindow(id: "story")
                    NSApp.activate()
                } label: {
                    Label("Rückblick", systemImage: "play.rectangle.on.rectangle.fill")
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
        }
        .padding(.leading, 84)
        .padding(.trailing, 20)
        .padding(.top, 10)
    }
}

extension DashboardData {
    /// Gespeicherte Trainings plus das gerade laufende.
    func allSessions(live: TreadmillModel) -> [WorkoutSession] {
        guard let s = live.status?.session else { return sessions }
        let current = WorkoutSession(id: s.id, start_ts: s.start_ts, active_s: Double(s.active_s),
                                     distance_km: s.distance_km, kcal: s.kcal, steps: s.steps,
                                     max_speed_kmh: s.max_speed, avg_speed_kmh: nil, has_samples: 1)
        return sessions.filter { $0.id != s.id } + [current]
    }
}

// MARK: - Seiten

struct DashboardPage: View {
    @ObservedObject var live: TreadmillModel
    @ObservedObject var data: DashboardData
    @ObservedObject var journey: JourneyStore
    let tab: DashboardTab
    let range: StatsRange
    let threeD: Bool
    @Binding var selectedID: Int?
    let openJourney: () -> Void

    private var liveID: Int? { live.status?.session?.id }
    private var profileID: Int? { data.profileID(liveID: liveID, selectedID: selectedID) }

    var body: some View {
        let sessions = data.allSessions(live: live)
        let stats = PeriodStats(all: sessions, range: range)

        VStack(alignment: .leading, spacing: 16) {
            if !data.reachable || !live.daemonReachable {
                OfflineNotice()
            }
            if let status = live.status, let session = status.session {
                LiveBanner(status: status, session: session)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            switch tab {
            case .overview: overview(sessions: sessions, stats: stats)
            case .analysis: analysis(sessions: sessions, stats: stats)
            case .sessions: sessionsPage(stats: stats)
            case .achievements: AchievementsPage()
            case .journey: EmptyView()
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 28)
        .frame(maxWidth: 1360)
        .frame(maxWidth: .infinity)
        .animation(.smooth(duration: 0.35), value: range)
        .animation(.smooth(duration: 0.35), value: liveID)
        .animation(.smooth(duration: 0.35), value: threeD)
        .environment(\.locale, Fmt.de)
    }

    // Uebersicht: Stand, heute, Einschaetzung, Verlauf
    @ViewBuilder
    private func overview(sessions: [WorkoutSession], stats: PeriodStats) -> some View {
        let streak = Streak(sessions: sessions)
        let today = Totals(sessions.filter { deCalendar.isDateInToday($0.start) })
        let forecast = Forecast(sessions: sessions)
        let progress = journey.progress(sessions: sessions)
        let insights = InsightEngine.make(sessions: sessions, goal: live.status?.daily_step_goal ?? 10_000,
                                          forecast: forecast, streak: streak, journey: progress,
                                          wanderstreak: live.status?.streak)

        WeekGoalCard(progress: WeekProgress(status: live.status, sessions: sessions))

        HStack(alignment: .top, spacing: 16) {
            HeroCard(stats: stats)
            if let wanderstreak = live.status?.streak {
                StreakCard(streak: wanderstreak) { date, status in live.markStreakDay(date, status) }
                    .frame(width: 350)
            }
        }
        .fixedSize(horizontal: false, vertical: true)

        tiles(stats, streak)

        HStack(alignment: .top, spacing: 16) {
            InsightsCard(insights: insights)
            TodayCard(today: today, goal: live.status?.daily_step_goal ?? 10_000, week: lastSevenDaysSteps(sessions))
                .frame(width: 350)
        }
        .fixedSize(horizontal: false, vertical: true)

        HStack(alignment: .top, spacing: 16) {
            DistanceBarsCard(stats: stats)
            JourneyMiniCard(progress: progress, open: openJourney)
                .frame(width: 350)
        }
        .fixedSize(horizontal: false, vertical: true)

        HStack(alignment: .top, spacing: 16) {
            profileCard(sessions: sessions)
            RecordsCard(sessions: sessions)
                .frame(width: 350)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // Analyse: Jahr, Zonen, Prognose, Rhythmus, Kalender
    @ViewBuilder
    private func analysis(sessions: [WorkoutSession], stats: PeriodStats) -> some View {
        CalendarYearCard(calendar: YearCalendar(sessions: sessions))

        HStack(alignment: .top, spacing: 16) {
            ZonesCard(zones: data.zones, range: stats.start...stats.end)
            ForecastCard(forecast: Forecast(sessions: sessions))
        }
        .fixedSize(horizontal: false, vertical: true)

        HStack(alignment: .top, spacing: 16) {
            HeatmapCard(stats: stats, threeD: threeD)
            TrendCard(sessions: stats.current.sorted { $0.start_ts < $1.start_ts })
                .frame(width: 430)
        }
        .fixedSize(horizontal: false, vertical: true)

        CalendarContextCard(sessions: sessions, start: stats.start, end: stats.end)
    }

    @ViewBuilder
    private func sessionsPage(stats: PeriodStats) -> some View {
        profileCard(sessions: data.allSessions(live: live))
        SessionListCard(sessions: stats.current.sorted { $0.start_ts > $1.start_ts },
                        selectedID: $selectedID, highlightedID: profileID)
    }

    @ViewBuilder
    private func profileCard(sessions: [WorkoutSession]) -> some View {
        if threeD && tab != .sessions {
            SpeedRidgeCard(profiles: data.ridge)
        } else {
            let session = profileID.flatMap { id in sessions.first { $0.id == id } }
            let isLive = profileID != nil && profileID == liveID
            SpeedProfileCard(title: isLive ? "Aktuelles Training" : "Tempo-Verlauf",
                             subtitle: session.map { "\(Fmt.day($0.start)) · \(Fmt.time($0.start)) Uhr · \(Fmt.minutes($0.active_s)) · \(Fmt.num($0.distance_km, 2)) km" }
                                ?? "Noch kein Training aufgezeichnet",
                             points: data.samplesFor == profileID ? data.samples : [],
                             isLive: isLive)
        }
    }

    private func tiles(_ stats: PeriodStats, _ streak: Streak) -> some View {
        let t = stats.totals
        let p = stats.prevTotals
        let (timeValue, timeUnit) = Fmt.durationParts(t.seconds)
        let speedComparable = (p?.count ?? 0) > 0 && t.count > 0

        return HStack(spacing: 16) {
            StatTile(label: "Aktive Zeit", value: timeValue, unit: timeUnit,
                     delta: p.map { (t.seconds - $0.seconds) / 60 },
                     deltaText: p.map { "\(Fmt.signed((t.seconds - $0.seconds) / 60, 0)) min" } ?? "")
            StatTile(label: "Schritte", value: Fmt.int(t.steps),
                     delta: p.map { Double(t.steps - $0.steps) },
                     deltaText: p.map { Fmt.signed(Double(t.steps - $0.steps), 0) } ?? "")
            StatTile(label: "Aktive Energie", value: Fmt.int(t.kcal), unit: "kcal",
                     delta: p.map { t.kcal - $0.kcal },
                     deltaText: p.map { "\(Fmt.signed(t.kcal - $0.kcal, 0)) kcal" } ?? "")
            StatTile(label: "Ø Tempo", value: Fmt.num(t.avgSpeed, 1), unit: "km/h",
                     delta: speedComparable ? p.map { t.avgSpeed - $0.avgSpeed } : nil,
                     deltaText: speedComparable ? p.map { "\(Fmt.signed(t.avgSpeed - $0.avgSpeed, 1)) km/h" } ?? "" : "",
                     footnote: speedComparable ? nil : "kein Vergleich möglich")
            StatTile(label: "Trainings", value: "\(t.count)",
                     delta: p.map { Double(t.count - $0.count) },
                     deltaText: p.map { Fmt.signed(Double(t.count - $0.count), 0) } ?? "")
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Reise-Teaser und 3D-Tempo

struct JourneyMiniCard: View {
    let progress: JourneyProgress
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "Virtuelle Reise", subtitle: progress.route.name)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Int((progress.fraction * 100).rounded())) %")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("\(Fmt.num(min(progress.walkedKm, progress.lengthKm), 1)) von \(Fmt.num(progress.lengthKm, 0)) km")
                    .font(.callout).foregroundStyle(Palette.ink2)
            }
            Meter(progress: progress.fraction)
            if let next = progress.nextStage {
                Text("Nächste Etappe: \(next.name) in \(Fmt.num(next.remainingKm, 1)) km")
                    .font(.callout).foregroundStyle(Palette.ink2)
            } else {
                Text("Ziel erreicht!").font(.callout.weight(.semibold))
            }
            Spacer(minLength: 0)
            Button(action: open) {
                Label("Karte öffnen", systemImage: "map.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
        .card()
    }
}

struct SpeedRidgeCard: View {
    let profiles: [(label: String, points: [SpeedPoint])]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                CardTitle(title: "Tempo-Gebirge", subtitle: "Tempo-Verläufe deiner letzten Trainings hintereinander")
                Spacer()
                ThreeDHint()
            }
            if profiles.count >= 2 {
                SpeedRidge3DChart(profiles: profiles).frame(height: 320)
            } else {
                ContentUnavailableView {
                    Label("Noch zu wenige Tempo-Verläufe", systemImage: "cube.transparent")
                } description: {
                    Text("Das Gebirge erscheint ab zwei Trainings mit Sekundenwerten im Zeitraum.")
                }
                .frame(height: 260)
            }
        }
        .card()
    }
}
