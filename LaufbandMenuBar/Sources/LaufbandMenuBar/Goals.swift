import SwiftUI

struct GoalPreset: Identifiable {
    let label: String
    let km: Double
    var id: String { label }

    /// Bodensee-Varianten nutzen die echte Fussweg-Laenge, sobald sie berechnet ist.
    @MainActor static var all: [GoalPreset] {
        let lap = (RouteGeometryStore.shared.geometries["bodensee"]?.totalKm ?? 260).rounded()
        return [
            GoalPreset(label: "1× Bodensee-Runde", km: lap),
            GoalPreset(label: "½ Bodensee-Runde", km: (lap / 2).rounded()),
            GoalPreset(label: "¼ Bodensee-Runde", km: (lap / 4).rounded()),
            GoalPreset(label: "50 km", km: 50),
            GoalPreset(label: "25 km", km: 25),
        ]
    }
}

/// Heute / Woche / Insgesamt plus Wochenziel – bevorzugt aus dem Daemon, sonst aus den Trainings berechnet.
struct WeekProgress {
    let todayKm: Double
    let weekKm: Double
    let totalKm: Double
    let todaySeconds: Double
    let weekSeconds: Double
    let totalSessions: Int
    let goalKm: Double
    let goalLabel: String
    let daysLeft: Int
    let dayKm: [(date: Date, km: Double)]

    var fraction: Double { goalKm > 0 ? weekKm / goalKm : 0 }
    var remainingKm: Double { max(0, goalKm - weekKm) }
    var perDayNeeded: Double { remainingKm / Double(max(daysLeft, 1)) }
    var reached: Bool { weekKm >= goalKm }
    var isBodensee: Bool { goalLabel.localizedCaseInsensitiveContains("bodensee") }

    init(status: Status?, sessions: [WorkoutSession], now: Date = .now) {
        let cal = deCalendar
        let today = cal.startOfDay(for: now)
        let weekStart = cal.dateInterval(of: .weekOfYear, for: now)!.start
        let inWeek = sessions.filter { $0.start >= weekStart }

        if let t = status?.totals {
            todayKm = t.today.km; weekKm = t.week.km; totalKm = t.total.km
            todaySeconds = t.today.s; weekSeconds = t.week.s; totalSessions = t.total.n
        } else {
            let todays = sessions.filter { $0.start >= today }
            todayKm = todays.reduce(0) { $0 + $1.distance_km }
            weekKm = inWeek.reduce(0) { $0 + $1.distance_km }
            totalKm = sessions.reduce(0) { $0 + $1.distance_km }
            todaySeconds = todays.reduce(0) { $0 + $1.active_s }
            weekSeconds = inWeek.reduce(0) { $0 + $1.active_s }
            totalSessions = sessions.count
        }
        goalKm = status?.weekly_goal?.km ?? 260
        goalLabel = status?.weekly_goal?.label ?? "1× Bodensee-Runde"

        let weekday = (cal.component(.weekday, from: now) + 5) % 7   // Mo = 0
        daysLeft = 7 - weekday
        dayKm = (0..<7).map { offset in
            let day = cal.date(byAdding: .day, value: offset, to: weekStart)!
            return (day, inWeek.filter { cal.isDate($0.start, inSameDayAs: day) }.reduce(0) { $0 + $1.distance_km })
        }
    }
}

// MARK: - Karte in der Uebersicht

struct WeekGoalCard: View {
    let progress: WeekProgress
    let setGoal: (Double, String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            // Links: die drei Distanzen
            VStack(alignment: .leading, spacing: 16) {
                CardTitle(title: "Wie weit du gekommen bist")
                HStack(alignment: .top, spacing: 30) {
                    distance("Heute", progress.todayKm, Fmt.minutes(progress.todaySeconds))
                    distance("Diese Woche", progress.weekKm, Fmt.minutes(progress.weekSeconds))
                    distance("Insgesamt", progress.totalKm, "\(progress.totalSessions) Trainings")
                }
            }
            .fixedSize()

            Divider()

            // Rechts: Wochenziel
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wochenziel").font(.headline).foregroundStyle(Palette.ink)
                        Text("\(progress.goalLabel) · \(Fmt.num(progress.goalKm, progress.goalKm < 10 ? 1 : 0)) km bis Sonntag")
                            .font(.subheadline).foregroundStyle(Palette.ink2)
                    }
                    Spacer()
                    GoalMenu(current: progress.goalKm, setGoal: setGoal)
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(Fmt.num(progress.fraction * 100, progress.fraction < 0.1 ? 1 : 0)) %")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .contentTransition(.numericText())
                    Text("\(Fmt.num(progress.weekKm, 1)) von \(Fmt.num(progress.goalKm, 0)) km geschafft")
                        .foregroundStyle(Palette.ink2)
                }
                Meter(progress: min(progress.fraction, 1))

                HStack(alignment: .bottom, spacing: 16) {
                    dayBars
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 4) {
                        if progress.reached {
                            HStack(spacing: 5) {
                                Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.statusGood)
                                Text("Wochenziel erreicht").foregroundStyle(Palette.ink)
                            }
                            .font(.callout.weight(.semibold))
                        } else {
                            Text("Noch \(Fmt.num(progress.remainingKm, 1)) km")
                                .font(.callout.weight(.semibold)).foregroundStyle(Palette.ink)
                            Text("≈ \(Fmt.num(progress.perDayNeeded, 1)) km pro Tag · \(Fmt.minutes(progress.perDayNeeded / 4 * 3600)) bei 4 km/h")
                                .font(.caption).foregroundStyle(Palette.ink2)
                        }
                        if progress.isBodensee {
                            Text(bodenseeLine)
                                .font(.caption).foregroundStyle(Palette.muted)
                        }
                    }
                }
            }
        }
        .card()
    }

    /// Wo du diese Woche auf der Bodensee-Runde waerst (Start jede Woche in Konstanz).
    private var bodenseeLine: String {
        let lap = JourneyProgress(route: JourneyRoute.all[0], walkedKm: progress.weekKm,
                                  geometry: RouteGeometryStore.shared.geometries["bodensee"])
        let start = JourneyRoute.all[0].waypoints[0].name
        guard let next = lap.nextStage else { return "Einmal rum – zurück in Konstanz!" }
        let nextText = "nächster Ort: \(next.name) in \(Fmt.num(next.remainingKm, 1)) km"
        return lap.lastReachedStage == start
            ? "Diese Woche ab \(start) unterwegs · \(nextText)"
            : "Diese Woche bis \(lap.lastReachedStage) · \(nextText)"
    }

    private func distance(_ label: String, _ km: Double, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.subheadline).foregroundStyle(Palette.ink2)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Fmt.num(km, km < 100 ? 2 : 1))
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .contentTransition(.numericText())
                Text("km").font(.title3.weight(.medium)).foregroundStyle(Palette.ink2)
            }
            Text(detail).font(.caption).foregroundStyle(Palette.muted)
        }
    }

    /// Kilometer je Wochentag; heute hervorgehoben.
    private var dayBars: some View {
        let maxKm = max(progress.dayKm.map(\.km).max() ?? 0, 0.001)
        return HStack(alignment: .bottom, spacing: 8) {
            ForEach(progress.dayKm, id: \.date) { day in
                let isToday = deCalendar.isDateInToday(day.date)
                VStack(spacing: 4) {
                    ZStack(alignment: .bottom) {
                        Color.clear.frame(width: 18, height: 54)
                        UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 4)
                            .fill(isToday ? Palette.series : Palette.baseline)
                            .frame(width: 18, height: day.km > 0 ? max(3, 54 * day.km / maxKm) : 0)
                    }
                    .help("\(Fmt.day(day.date)): \(Fmt.num(day.km, 2)) km")
                    Text(day.date.formatted(.dateTime.weekday(.narrow).locale(Fmt.de)))
                        .font(.caption2.weight(isToday ? .bold : .regular))
                        .foregroundStyle(isToday ? Palette.ink : Palette.muted)
                }
            }
        }
    }
}

struct GoalMenu: View {
    let current: Double
    let setGoal: (Double, String) -> Void
    @State private var showCustom = false
    @State private var customKm: Double = 40

    var body: some View {
        Menu {
            ForEach(GoalPreset.all) { preset in
                Button {
                    setGoal(preset.km, preset.label)
                } label: {
                    if abs(preset.km - current) < 0.05 {
                        Label("\(preset.label) · \(Fmt.num(preset.km, 0)) km", systemImage: "checkmark")
                    } else {
                        Text("\(preset.label) · \(Fmt.num(preset.km, 0)) km")
                    }
                }
            }
            Divider()
            Button("Eigenes Ziel …") {
                customKm = current
                showCustom = true
            }
        } label: {
            Label("Ziel", systemImage: "target")
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
        .popover(isPresented: $showCustom, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Eigenes Wochenziel").font(.headline)
                HStack {
                    TextField("km", value: $customKm, format: .number.precision(.fractionLength(0...1)).locale(Fmt.de))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    Stepper("km pro Woche", value: $customKm, in: 1...2000, step: 5)
                }
                Text("≈ \(Fmt.num(customKm / 7, 1)) km pro Tag").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Übernehmen") {
                        setGoal(customKm, "\(Fmt.num(customKm, customKm.rounded() == customKm ? 0 : 1)) km")
                        showCustom = false
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(width: 300)
        }
    }
}

// MARK: - Kompakt fuer Panel und Widget

struct WeekCompactView: View {
    let progress: WeekProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Wochenziel").font(.caption.weight(.semibold)).foregroundStyle(Palette.ink)
                Text(progress.goalLabel).font(.caption).foregroundStyle(Palette.ink2).lineLimit(1)
                Spacer()
                Text("\(Fmt.num(progress.fraction * 100, progress.fraction < 0.1 ? 1 : 0)) %")
                    .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(Palette.ink)
            }
            Meter(progress: min(progress.fraction, 1))
            HStack {
                compact("Heute", progress.todayKm)
                compact("Woche", progress.weekKm)
                compact("Gesamt", progress.totalKm)
            }
        }
    }

    private func compact(_ label: String, _ km: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(Fmt.num(km, km < 100 ? 2 : 1)) km")
                .font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(Palette.ink)
                .contentTransition(.numericText())
            Text(label).font(.caption2).foregroundStyle(Palette.ink2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
