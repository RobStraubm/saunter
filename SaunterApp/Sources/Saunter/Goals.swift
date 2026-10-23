import SwiftUI

/// Heute / Woche / Insgesamt plus Wochen-Streak – bevorzugt aus dem Daemon, sonst aus den Trainings berechnet.
struct WeekProgress {
    let todayKm: Double
    let weekKm: Double
    let totalKm: Double
    let todaySeconds: Double
    let weekSeconds: Double
    let totalSessions: Int
    let weekStreak: WeekStreak?
    /// Tage dieser Woche mit Zustand (done, excused, ...) fuer die Punkte unter den Balken.
    let streakWeek: [StreakDay]
    let dayKm: [(date: Date, km: Double)]

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
        weekStreak = status?.streak?.week_streak
        streakWeek = status?.streak?.week ?? []

        dayKm = (0..<7).map { offset in
            let day = cal.date(byAdding: .day, value: offset, to: weekStart)!
            return (day, inWeek.filter { cal.isDate($0.start, inSameDayAs: day) }.reduce(0) { $0 + $1.distance_km })
        }
    }
}

// MARK: - Karte in der Uebersicht

struct WeekGoalCard: View {
    let progress: WeekProgress

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            // Links: die drei Distanzen und die Bodensee-Runde als Gesamtstrecke
            VStack(alignment: .leading, spacing: 16) {
                CardTitle(title: "Wie weit du gekommen bist")
                HStack(alignment: .top, spacing: 30) {
                    distance("Heute", progress.todayKm, Fmt.minutes(progress.todaySeconds))
                    distance("Diese Woche", progress.weekKm, Fmt.minutes(progress.weekSeconds))
                    distance("Insgesamt", progress.totalKm, "\(progress.totalSessions) Trainings")
                }
                Label(bodenseeLine, systemImage: "water.waves")
                    .font(.caption).foregroundStyle(Palette.ink2)
            }
            .fixedSize()

            Divider()

            // Rechts: Wochen-Streak
            VStack(alignment: .leading, spacing: 12) {
                if let week = progress.weekStreak {
                    weekStreak(week)
                } else {
                    Text("Wochen-Streak").font(.headline).foregroundStyle(Palette.ink)
                    Text("Wird nach dem nächsten Neustart des Daemons angezeigt.")
                        .font(.caption).foregroundStyle(Palette.ink2)
                }
            }
        }
        .card()
    }

    @ViewBuilder
    private func weekStreak(_ week: WeekStreak) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Wochen-Streak").font(.headline).foregroundStyle(Palette.ink)
                Text(ruleLine(week)).font(.subheadline).foregroundStyle(Palette.ink2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(week.current)").font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(Palette.ink)
                Text(week.current == 1 ? "Woche in Folge" : "Wochen in Folge").font(.caption).foregroundStyle(Palette.ink2)
            }
            .help("Rekord: \(week.best) \(week.best == 1 ? "Woche" : "Wochen")")
        }

        if week.state == "free" {
            Text("Diese Woche ohne Ziel").font(.system(size: 28, weight: .semibold)).foregroundStyle(Palette.ink)
            Text("Höchstens ein Bürotag – der Cheat-Day deckt ihn ab, die Serie bleibt.")
                .font(.callout).foregroundStyle(Palette.ink2)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(week.walk_days) / \(week.required_days)")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .contentTransition(.numericText())
                Text("Lauftage").foregroundStyle(Palette.ink2)
            }
            Meter(progress: week.fraction)
        }

        HStack(alignment: .bottom, spacing: 16) {
            dayBars
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                switch week.state {
                case "reached":
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.statusGood)
                        Text("Woche geschafft").foregroundStyle(Palette.ink)
                    }
                    .font(.callout.weight(.semibold))
                case "free":
                    EmptyView()
                default:
                    Text("Noch \(week.daysLeft) \(week.daysLeft == 1 ? "Lauftag" : "Lauftage")")
                        .font(.callout.weight(.semibold)).foregroundStyle(Palette.ink)
                    Text("bis Sonntag · Wochenende zählt mit")
                        .font(.caption).foregroundStyle(Palette.ink2)
                }
            }
        }
    }

    private func ruleLine(_ week: WeekStreak) -> String {
        let cheat = week.cheat_days == 1 ? "1 Cheat-Day" : "\(week.cheat_days) Cheat-Days"
        return "\(week.office_days) \(week.office_days == 1 ? "Bürotag" : "Bürotage") · \(cheat) · je mind. 5 min"
    }

    /// Wo du insgesamt auf der Bodensee-Runde waerst (Start in Konstanz, danach Runde um Runde).
    private var bodenseeLine: String {
        let route = JourneyRoute.all[0]
        let geometry = RouteGeometryStore.shared.geometries["bodensee"]
        let lapKm = geometry?.totalKm ?? route.officialKm
        let laps = lapKm > 0 ? Int(progress.totalKm / lapKm) : 0
        let lap = JourneyProgress(route: route, walkedKm: progress.totalKm - Double(laps) * lapKm, geometry: geometry)
        let lapsText = laps > 0 ? "\(laps)× rum, jetzt " : ""
        guard let next = lap.nextStage else { return "Bodensee: \(lapsText)zurück in Konstanz" }
        return "Bodensee: \(lapsText)bis \(lap.lastReachedStage) · nächster Ort \(next.name) in \(Fmt.num(next.remainingKm, 1)) km"
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

// MARK: - Kompakt fuer Panel und Widget

struct WeekCompactView: View {
    let progress: WeekProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let week = progress.weekStreak {
                HStack(alignment: .firstTextBaseline) {
                    Text("Wochen-Streak").font(.caption.weight(.semibold)).foregroundStyle(Palette.ink)
                    Text("\(week.current) \(week.current == 1 ? "Woche" : "Wochen")")
                        .font(.caption).foregroundStyle(Palette.ink2).lineLimit(1)
                    Spacer()
                    Text(week.state == "free" ? "frei" : "\(week.walk_days)/\(week.required_days) Tage")
                        .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(Palette.ink)
                }
                Meter(progress: week.fraction)
            }
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
