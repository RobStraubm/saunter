import SwiftUI
import AppKit

enum StoryPeriod: String, CaseIterable, Identifiable {
    case week = "Woche"
    case month = "Monat"
    var id: Self { self }
}

struct StorySummary {
    let headline: String
    let periodLabel: String
    let totals: Totals
    let previous: Totals
    let dailyKm: [(date: Date, km: Double)]
    let minutesByWeekday: [Double]
    let favoriteSlot: String?
    let longest: WorkoutSession?
    let farthest: WorkoutSession?
    let zoneShares: [Double]

    init(sessions: [WorkoutSession], zones: ZonesResponse?, period: StoryPeriod, now: Date = .now) {
        let cal = deCalendar
        let unit: Calendar.Component = period == .week ? .weekOfYear : .month
        let interval = cal.dateInterval(of: unit, for: now)!
        let prevStart = cal.date(byAdding: unit, value: -1, to: interval.start)!
        let current = sessions.filter { $0.start >= interval.start && $0.start < interval.end }
        let prev = sessions.filter { $0.start >= prevStart && $0.start < interval.start }

        headline = period == .week ? "Deine Woche" : "Dein \(now.formatted(.dateTime.month(.wide).locale(Fmt.de)))"
        let lastDay = min(interval.end.addingTimeInterval(-1), now)
        periodLabel = "\(Fmt.shortDay(interval.start)) – \(lastDay.formatted(.dateTime.day().month(.abbreviated).year().locale(Fmt.de)))"
        totals = Totals(current)
        previous = Totals(prev)

        var days: [(Date, Double)] = []
        var cursor = interval.start
        while cursor <= lastDay {
            let km = current.filter { cal.isDate($0.start, inSameDayAs: cursor) }.reduce(0) { $0 + $1.distance_km }
            days.append((cursor, km))
            cursor = cal.date(byAdding: .day, value: 1, to: cursor)!
        }
        dailyKm = days

        var byWeekday = Array(repeating: 0.0, count: 7)
        var slots: [String: Double] = [:]
        let names = ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"]
        for s in current {
            let wd = (cal.component(.weekday, from: s.start) + 5) % 7
            byWeekday[wd] += s.active_s / 60
            let block = cal.component(.hour, from: s.start) / 3 * 3
            slots["\(names[wd]), \(block)–\(block + 3) Uhr", default: 0] += s.active_s / 60
        }
        minutesByWeekday = byWeekday
        favoriteSlot = slots.max { $0.value < $1.value }?.key
        longest = current.max { $0.active_s < $1.active_s }
        farthest = current.max { $0.distance_km < $1.distance_km }

        var zoneSums = Array(repeating: 0.0, count: 4)
        for z in (zones?.sessions ?? []) where z.start >= interval.start && z.start < interval.end {
            for (i, v) in z.seconds.enumerated() where i < 4 { zoneSums[i] += v }
        }
        let zoneTotal = zoneSums.reduce(0, +)
        zoneShares = zoneTotal > 0 ? zoneSums.map { $0 / zoneTotal } : []
    }
}

// MARK: - Fenster

struct StoryWindow: View {
    @ObservedObject var live: TreadmillModel
    @StateObject private var data = DashboardData()
    @State private var period: StoryPeriod = .month
    @State private var index = 0
    @State private var paused = false
    @State private var exportURL: URL?

    private let slideSeconds = 6.0
    private let slideCount = 8

    var body: some View {
        let summary = StorySummary(sessions: data.sessions, zones: data.zones, period: period)
        ZStack(alignment: .top) {
            StorySlide(index: index, summary: summary)
                .id("\(period.rawValue)-\(index)")
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { location in
                    step(location.x < 150 ? -1 : 1)
                }

            progressBar.padding(.horizontal, 16).padding(.top, 38)

            VStack {
                Spacer()
                controls.padding(.bottom, 22)
            }
        }
        .frame(width: 450, height: 800)
        .background(Color.black)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.space) { paused.toggle(); return .handled }
        .onHover { paused = $0 }
        .task { await data.loadSessions() }
        .task(id: "\(index)-\(paused)-\(period.rawValue)") {
            guard !paused, index < slideCount - 1 else { return }
            try? await Task.sleep(for: .seconds(slideSeconds))
            guard !Task.isCancelled else { return }
            step(1)
        }
        .onChange(of: period) { index = 0 }
    }

    private func step(_ delta: Int) {
        withAnimation(.smooth(duration: 0.45)) {
            index = min(max(index + delta, 0), slideCount - 1)
        }
    }

    private var progressBar: some View {
        HStack(spacing: 4) {
            ForEach(0..<slideCount, id: \.self) { i in
                Capsule()
                    .fill(.white.opacity(i <= index ? 0.95 : 0.3))
                    .frame(height: 3)
            }
        }
    }

    private var controls: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Picker("Zeitraum", selection: $period) {
                    ForEach(StoryPeriod.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)

                if index == slideCount - 1 {
                    Button {
                        exportURL = exportImage()
                    } label: {
                        Label("Als Bild sichern", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.glassProminent)
                    if let exportURL {
                        ShareLink(item: exportURL) { Image(systemName: "square.and.arrow.up") }
                            .buttonStyle(.glass)
                    }
                } else {
                    Button {
                        paused.toggle()
                    } label: {
                        Image(systemName: paused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    @MainActor
    private func exportImage() -> URL? {
        let summary = StorySummary(sessions: data.sessions, zones: data.zones, period: period)
        let renderer = ImageRenderer(content: StorySlide(index: slideCount - 1, summary: summary, forExport: true)
            .frame(width: 360, height: 640))
        renderer.scale = 3
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let name = "Laufband-Rückblick-\(summary.headline.replacingOccurrences(of: " ", with: "-")).png"
        let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
        do {
            try png.write(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return url
        } catch {
            return nil
        }
    }
}

// MARK: - Folien

struct StoryBackground: View {
    let variant: Int

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = Float(context.date.timeIntervalSinceReferenceDate)
            let drift = SIMD2<Float>(sin(t * 0.35 + Float(variant)) * 0.12, cos(t * 0.28 + Float(variant)) * 0.1)
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], SIMD2(0.5, 0.5) + drift, [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ],
                colors: palette
            )
        }
    }

    private var palette: [Color] {
        let blues: [UInt32] = [0x0D366B, 0x104281, 0x184F95, 0x1C5CAB, 0x256ABF, 0x2A78D6, 0x3987E5, 0x5598E7]
        let order = [[0, 2, 1, 3, 6, 2, 1, 4, 0], [1, 0, 3, 5, 2, 4, 3, 1, 0], [2, 3, 0, 4, 7, 1, 0, 2, 3], [0, 1, 4, 2, 5, 3, 1, 0, 2]]
        return order[variant % order.count].map { Color(nsColor: NSColor(hex: blues[$0])) }
    }
}

struct StorySlide: View {
    let index: Int
    let summary: StorySummary
    var forExport = false

    var body: some View {
        ZStack {
            StoryBackground(variant: index)
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: forExport ? 40 : 80)
                content
                Spacer(minLength: 90)
            }
            .padding(.horizontal, forExport ? 30 : 36)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .environment(\.locale, Fmt.de)
    }

    @ViewBuilder
    private var content: some View {
        let t = summary.totals
        switch index {
        case 0:
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "figure.walk.motion")
                    .font(.system(size: 64, weight: .semibold))
                    .symbolEffect(.breathe)
                Text(summary.headline).font(.system(size: 48, weight: .bold)).lineLimit(2).minimumScaleFactor(0.6)
                Text("auf dem Laufband").font(.title.weight(.medium)).opacity(0.85)
                Text(summary.periodLabel).font(.title3).opacity(0.7)
            }
        case 1:
            bigNumber(label: "Du bist gegangen", value: Fmt.num(t.distance, 2), unit: "km",
                      lines: [
                          "≈ \(Fmt.int(t.distance * 1000 / 105)) Fußballfelder",
                          "≈ \(Int((t.distance / 42.195 * 100).rounded())) % eines Marathons",
                          deltaLine(t.distance - summary.previous.distance, unit: "km", digits: 1),
                      ])
        case 2:
            VStack(alignment: .leading, spacing: 22) {
                bigNumber(label: "In Bewegung", value: Fmt.durationParts(t.seconds).0, unit: Fmt.durationParts(t.seconds).1,
                          lines: ["in \(t.count) \(t.count == 1 ? "Training" : "Trainings")"])
                dayBars
            }
        case 3:
            VStack(alignment: .leading, spacing: 18) {
                Text("Dein Rhythmus").font(.title2.weight(.medium)).opacity(0.85)
                Text(summary.favoriteSlot ?? "Noch kein Muster").font(.system(size: 36, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Hier warst du am häufigsten auf dem Band.").opacity(0.8)
                weekdayBars
            }
        case 4:
            VStack(alignment: .leading, spacing: 22) {
                bigNumber(label: "Dein Schnitt", value: Fmt.num(t.avgSpeed, 1), unit: "km/h",
                          lines: [deltaLine(t.avgSpeed - summary.previous.avgSpeed, unit: "km/h", digits: 1)])
                zoneBar
            }
        case 5:
            VStack(alignment: .leading, spacing: 22) {
                Text("Deine Bestwerte").font(.title2.weight(.medium)).opacity(0.85)
                if let f = summary.farthest {
                    record("Weiteste Strecke", "\(Fmt.num(f.distance_km, 2)) km", Fmt.day(f.start))
                }
                if let l = summary.longest {
                    record("Längstes Training", Fmt.minutes(l.active_s), Fmt.day(l.start))
                }
                if summary.farthest == nil {
                    Text("Noch keine Trainings in diesem Zeitraum.").opacity(0.8)
                }
            }
        case 6:
            bigNumber(label: "Aktive Energie", value: Fmt.int(t.kcal), unit: "kcal",
                      lines: [
                          "≈ \(Fmt.num(t.kcal / 250, 1)) Brezeln",
                          "\(Fmt.int(t.steps)) Schritte",
                      ])
        default:
            summaryCard
        }
    }

    private func bigNumber(label: String, value: String, unit: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(.title2.weight(.medium)).opacity(0.85)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value).font(.system(size: 92, weight: .bold)).minimumScaleFactor(0.5).lineLimit(1)
                Text(unit).font(.system(size: 30, weight: .semibold)).opacity(0.85)
            }
            ForEach(lines.filter { !$0.isEmpty }, id: \.self) { line in
                Text(line).font(.title3).opacity(0.85)
            }
        }
    }

    private func deltaLine(_ delta: Double, unit: String, digits: Int) -> String {
        guard summary.previous.count > 0 else { return "" }
        return "\(Fmt.signed(delta, digits)) \(unit) gegenüber dem Zeitraum davor"
    }

    private var dayBars: some View {
        let maxKm = max(summary.dailyKm.map(\.km).max() ?? 0, 0.001)
        return HStack(alignment: .bottom, spacing: summary.dailyKm.count > 10 ? 3 : 8) {
            ForEach(summary.dailyKm, id: \.date) { day in
                UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 3)
                    .fill(.white.opacity(day.km > 0 ? 0.95 : 0.2))
                    .frame(height: max(3, 110 * day.km / maxKm))
            }
        }
        .frame(height: 110, alignment: .bottom)
    }

    private var weekdayBars: some View {
        let maxMin = max(summary.minutesByWeekday.max() ?? 0, 0.001)
        return HStack(alignment: .bottom, spacing: 12) {
            ForEach(0..<7, id: \.self) { i in
                VStack(spacing: 6) {
                    UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 4)
                        .fill(.white.opacity(summary.minutesByWeekday[i] > 0 ? 0.95 : 0.2))
                        .frame(width: 22, height: max(3, 90 * summary.minutesByWeekday[i] / maxMin))
                    Text(weekdayLabels[i]).font(.caption.weight(.semibold)).opacity(0.8)
                }
            }
        }
        .frame(height: 115, alignment: .bottom)
    }

    @ViewBuilder
    private var zoneBar: some View {
        if !summary.zoneShares.isEmpty {
            let names = ZoneInfo.all(bounds: [3, 4.5, 6])
            VStack(alignment: .leading, spacing: 10) {
                Text("So verteilt sich dein Tempo").font(.headline).opacity(0.85)
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(Array(summary.zoneShares.enumerated()), id: \.offset) { i, share in
                            if share > 0 {
                                Rectangle().fill(.white.opacity(0.3 + 0.23 * Double(i)))
                                    .frame(width: max(2, (geo.size.width - 6) * share))
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .frame(height: 18)
                ForEach(Array(summary.zoneShares.enumerated()), id: \.offset) { i, share in
                    if share > 0.005 {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.3 + 0.23 * Double(i))).frame(width: 12, height: 12)
                            Text("\(names[i].name) · \(names[i].range)").opacity(0.9)
                            Spacer()
                            Text("\(Int((share * 100).rounded())) %").monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }

    private func record(_ label: String, _ value: String, _ date: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.headline).opacity(0.8)
            Text(value).font(.system(size: 48, weight: .bold))
            Text(date).opacity(0.75)
        }
    }

    private var summaryCard: some View {
        let t = summary.totals
        return VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.headline).font(.system(size: 38, weight: .bold))
                Text(summary.periodLabel).opacity(0.75)
            }
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 20) {
                GridRow {
                    tile("Distanz", "\(Fmt.num(t.distance, 1)) km")
                    tile("Zeit", Fmt.minutes(t.seconds))
                }
                GridRow {
                    tile("Trainings", "\(t.count)")
                    tile("Ø Tempo", "\(Fmt.num(t.avgSpeed, 1)) km/h")
                }
                GridRow {
                    tile("Schritte", Fmt.int(t.steps))
                    tile("Energie", "\(Fmt.int(t.kcal)) kcal")
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "figure.walk")
                Text("Laufband").fontWeight(.semibold)
            }
            .opacity(0.75)
        }
    }

    private func tile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 26, weight: .bold)).monospacedDigit()
            Text(label).font(.callout).opacity(0.75)
        }
    }
}
