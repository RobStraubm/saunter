import SwiftUI
import AppKit
import MapKit

/// Karten-Schnappschuss fuer das Widget: eine Live-Karte auf Schreibtisch-Ebene zeichnet macOS
/// nicht zuverlaessig (verdecktes Fenster), ein Snapshot schon.
@MainActor
final class WidgetMapSnapshot: ObservableObject {
    @Published private(set) var snapshot: MKMapSnapshotter.Snapshot?
    private var center: CLLocationCoordinate2D?
    private var routeID: String?
    private var busy = false
    private var latest: (JourneyProgress, CGSize)?

    /// Snapshot-Koordinaten haben unter macOS den Ursprung unten links; SwiftUI zeichnet von oben.
    func point(_ coordinate: CLLocationCoordinate2D, height: CGFloat) -> CGPoint {
        guard let snapshot else { return .zero }
        let p = snapshot.point(for: coordinate)
        return CGPoint(x: p.x, y: height - p.y)
    }

    func update(_ progress: JourneyProgress, size: CGSize) {
        latest = (progress, size)
        if let c = center, routeID == progress.route.id, haversineKm(c, progress.position) < 0.25 { return }
        guard !busy else { return }
        busy = true
        let options = MKMapSnapshotter.Options()
        options.preferredConfiguration = MKHybridMapConfiguration(elevationStyle: .realistic)
        options.camera = MKMapCamera(lookingAtCenter: progress.position, fromDistance: 6500, pitch: 50, heading: 0)
        options.size = size
        options.appearance = NSAppearance(named: .darkAqua)
        let target = progress.position
        let id = progress.route.id
        MKMapSnapshotter(options: options).start { [weak self] snapshot, _ in
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                if let snapshot {
                    self.snapshot = snapshot
                    self.center = target
                    self.routeID = id
                }
                // waehrend der Aufnahme weitergelaufen oder Daten nachgeladen -> neu aufnehmen
                if let (next, nextSize) = self.latest { self.update(next, size: nextSize) }
            }
        }
    }
}

/// Kleine Satellitenkarte: wo du auf deiner Reise gerade waerst.
struct WidgetJourneyMap: View {
    let progress: JourneyProgress
    @StateObject private var map = WidgetMapSnapshot()
    private let size = CGSize(width: 300, height: 150)

    var body: some View {
        ZStack {
            if let snapshot = map.snapshot {
                Image(nsImage: snapshot.image)
                    .resizable()
                Canvas { context, canvasSize in
                    let path = { (coords: [CLLocationCoordinate2D]) -> Path in
                        var p = Path()
                        for (i, c) in coords.enumerated() {
                            let pt = map.point(c, height: canvasSize.height)
                            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                        }
                        return p
                    }
                    context.stroke(path(progress.remainingPath), with: .color(.white.opacity(0.9)),
                                   style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: [1, 5]))
                    context.stroke(path(progress.walkedPath), with: .color(Palette.series),
                                   style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
                YouMarker()
                    .scaleEffect(0.8)
                    .position(map.point(progress.position, height: size.height))
            } else {
                Rectangle().fill(.quaternary)
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear { map.update(progress, size: size) }
        .onChange(of: progress.walkedKm) { map.update(progress, size: size) }
        .onChange(of: progress.route.id) { map.update(progress, size: size) }
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(progress.route.name) · \(Fmt.num(min(progress.walkedKm, progress.lengthKm), 1)) km")
                    .font(.caption.weight(.semibold))
                Text(progress.nextStage.map { "nächster Ort: \($0.name) in \(Fmt.num($0.remainingKm, 1)) km" } ?? "Ziel erreicht")
                    .font(.caption2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(8)
        }
    }
}

/// Glas-Karte auf Schreibtisch-Ebene (hinter allen Fenstern), verschiebbar, Klick oeffnet die Uebersicht.
@MainActor
final class DesktopWidgetController {
    static let shared = DesktopWidgetController()
    private var panel: NSPanel?
    private var moveObserver: NSObjectProtocol?

    func setVisible(_ visible: Bool, model: TreadmillModel) {
        if visible {
            if panel == nil { panel = makePanel(model: model) }
            panel?.orderFront(nil)
        } else {
            panel?.orderOut(nil)
        }
    }

    private func makePanel(model: TreadmillModel) -> NSPanel {
        let controller = NSHostingController(rootView: DesktopWidgetView(model: model))
        controller.sizingOptions = [.preferredContentSize]
        let size = controller.view.fittingSize
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.contentViewController = controller
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true

        let defaults = UserDefaults.standard
        if defaults.object(forKey: "widget.x") != nil {
            p.setFrameOrigin(NSPoint(x: defaults.double(forKey: "widget.x"), y: defaults.double(forKey: "widget.y")))
        } else if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.maxX - max(size.width, 360) - 12, y: f.maxY - max(size.height, 250) - 12))
        }
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { note in
            guard let w = note.object as? NSWindow else { return }
            UserDefaults.standard.set(w.frame.origin.x, forKey: "widget.x")
            UserDefaults.standard.set(w.frame.origin.y, forKey: "widget.y")
        }
        return p
    }
}

struct DesktopWidgetView: View {
    @ObservedObject var model: TreadmillModel
    @StateObject private var data = DashboardData()
    @ObservedObject private var journey = JourneyStore.shared
    @ObservedObject private var routes = RouteGeometryStore.shared

    var body: some View {
        let status = model.status
        let live = status?.session
        let today = data.sessions.filter { deCalendar.isDateInToday($0.start) }
        let liveToday = live.map { deCalendar.isDateInToday(Date(timeIntervalSince1970: $0.start_ts)) } ?? false
        let steps = today.reduce(0) { $0 + $1.steps } + (liveToday ? live?.steps ?? 0 : 0)
        let km = today.reduce(0) { $0 + $1.distance_km } + (liveToday ? live?.distance_km ?? 0 : 0)
        let seconds = today.reduce(0) { $0 + $1.active_s } + (liveToday ? Double(live?.active_s ?? 0) : 0)
        let goal = status?.daily_step_goal ?? 10_000
        let progress = min(1, Double(steps) / Double(max(goal, 1)))

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                if status?.phase == "running", let s = status {
                    HStack(spacing: 6) {
                        Circle().fill(Palette.statusGood).frame(width: 8, height: 8)
                        Text("Läuft").font(.headline)
                    }
                    Spacer()
                    Text("\(Fmt.num(s.speed, 1)) km/h").font(.headline).monospacedDigit()
                        .contentTransition(.numericText(value: s.speed))
                } else {
                    Label(status?.phase == "paused" ? "Pausiert" : "Laufband", systemImage: "figure.walk").font(.headline)
                    Spacer()
                    if let streak = status?.streak {
                        StreakFlame(streak: streak, size: 17)
                    }
                }
            }
            if let streak = status?.streak {
                if streak.pending.first != nil {
                    Label("Offene Frage zu deinem Streak – klicken", systemImage: "questionmark.circle.fill")
                        .font(.caption).foregroundStyle(Palette.series)
                } else if streak.at_risk {
                    Label("Heute noch \(Fmt.num(streak.minutesLeftToday, 0)) min für deinen Streak", systemImage: "flame")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            WidgetJourneyMap(progress: journey.progress(sessions: data.allSessions(live: model)))

            WeekCompactView(progress: WeekProgress(status: status, sessions: data.allSessions(live: model)))

            HStack(spacing: 6) {
                Image(systemName: "figure.walk").font(.caption).foregroundStyle(.secondary)
                Text("\(Fmt.int(steps)) von \(Fmt.int(goal)) Schritten heute · \(Int((progress * 100).rounded())) %")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if let live {
                    Text(Fmt.clock(live.active_s)).font(.caption.weight(.semibold)).monospacedDigit()
                } else {
                    Text("\(Fmt.num(km, 2)) km · \(Fmt.minutes(seconds))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .frame(width: 330)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(15)
        .contentShape(Rectangle())
        .onTapGesture { postOpen(openDashboardNotification) }
        .environment(\.locale, Fmt.de)
        .task {
            while !Task.isCancelled {
                await data.loadSessions()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onChange(of: live?.id) {
            Task { await data.loadSessions() }
        }
    }

    private func widgetStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
