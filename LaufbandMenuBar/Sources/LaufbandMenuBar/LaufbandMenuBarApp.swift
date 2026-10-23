import SwiftUI
import AppKit
import Combine

let apiBase = URL(string: "http://127.0.0.1:8765/api/")!
let openDashboardNotification = Notification.Name("de.straubmueller.laufband.openDashboard")
let openStoryNotification = Notification.Name("de.straubmueller.laufband.openStory")
let openJourneyNotification = Notification.Name("de.straubmueller.laufband.openJourney")
let openSetupNotification = Notification.Name("de.straubmueller.laufband.openSetup")

func postOpen(_ name: Notification.Name) {
    DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: nil, deliverImmediately: true)
}

/// Nimmt laufband://-Links entgegen (Kurzbefehle, Kontrollzentrum, Spotlight, Raycast …).
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: TreadmillModel?

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls { AppDelegate.model?.handleURL(url) }
        }
    }
}

// MARK: - API

struct SessionInfo: Decodable {
    let id: Int
    let start_ts: Double
    let active_s: Int
    let distance_km: Double
    let kcal: Double
    let steps: Int
    let max_speed: Double
    let paused: Bool
    let paused_for_s: Int?
}

struct FinishedInfo: Decodable {
    let duration_s: Int
    let distance_km: Double
    let kcal: Double
    let logged: Bool
}

struct PeriodSum: Decodable {
    let km: Double
    let s: Double
    let steps: Int
    let n: Int
}

struct DistanceTotals: Decodable {
    let today: PeriodSum
    let week: PeriodSum
    let total: PeriodSum
}

struct Status: Decodable {
    let phase: String
    let connected: Bool
    let countdown: Int?
    let speed: Double
    let target_speed: Double
    let min_speed: Double
    let max_speed: Double
    let session: SessionInfo?
    let last_finished: FinishedInfo?
    let last_error: String?
    let auto_finish_after_s: Int
    let daily_step_goal: Int?
    let totals: DistanceTotals?
    let streak: StreakInfo?
    let setup: SetupInfo?
}

struct CommandResponse: Decodable {
    let ok: Bool
    let error: String?
    let status: Status?
}

// MARK: - Scrollrad / Trackpad

/// Faengt per lokalem Event-Monitor jedes Scroll-Ereignis ab, solange der
/// Zeiger ueber dieser View ist - unabhaengig davon, welche SwiftUI-Ebene
/// darueber liegt. Eine begonnene Trackpad-Geste bleibt bis zum Loslassen
/// "unsere", auch wenn der Zeiger dabei aus dem Feld rutscht.
final class ScrollCatcherView: NSView {
    var onScroll: ((NSEvent) -> Void)?
    private var monitor: Any?
    private var capturing = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            let inside = self.bounds.contains(self.convert(event.locationInWindow, from: nil))
            if event.phase.contains(.mayBegin) || event.phase.contains(.began) {
                self.capturing = inside
            }
            let isMomentum = !event.momentumPhase.isEmpty
            guard self.capturing || inside else { return event }
            if !isMomentum { self.onScroll?(event) }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                self.capturing = false
            }
            return nil
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

struct ScrollCatcher: NSViewRepresentable {
    var onScroll: (NSEvent) -> Void

    func makeNSView(context: Context) -> ScrollCatcherView {
        let view = ScrollCatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ScrollCatcherView, context: Context) {
        nsView.onScroll = onScroll
    }
}

// MARK: - Modell

@MainActor
final class TreadmillModel: ObservableObject {
    @Published var status: Status?
    @Published var daemonReachable = false
    @Published var errorText: String?
    /// Angezeigter Zielwert (0,1-Raster), solange er noch nicht beim Daemon ist.
    @Published private(set) var pendingTarget: Double?
    /// Ungerundeter Wert waehrend des Scrollens - fuer die fliessende Anzeige.
    @Published private(set) var rawTarget: Double?
    @Published private(set) var scrubbing = false
    @Published private(set) var sending = false
    /// "Neu suchen" laeuft, bis das Laufband verbunden ist oder die Frist ablaeuft.
    @Published private(set) var reconnecting = false

    @Published var pauseOnLock = UserDefaults.standard.object(forKey: "pauseOnLock") as? Bool ?? true {
        didSet { UserDefaults.standard.set(pauseOnLock, forKey: "pauseOnLock") }
    }
    @Published var resumeOnUnlock = UserDefaults.standard.object(forKey: "resumeOnUnlock") as? Bool ?? false {
        didSet { UserDefaults.standard.set(resumeOnUnlock, forKey: "resumeOnUnlock") }
    }
    @Published var showDesktopWidget = UserDefaults.standard.object(forKey: "showDesktopWidget") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showDesktopWidget, forKey: "showDesktopWidget")
            DesktopWidgetController.shared.setVisible(showDesktopWidget, model: self)
        }
    }
    @Published var autoPauseNote: String?
    var pausedByLock = false
    var autoPausedAt: Date?
    var integrationEnabled = false
    var lastTodayDone: Bool?
    var lastReminderCheck = Date.distantPast
    var lastOfficeCheck = Date.distantPast
    var setupShown = false
    var hotKeys: HotKeyCenter?
    var observers: [NSObjectProtocol] = []

    private var commitTask: Task<Void, Never>?
    private var timer: Timer?

    private let trackpadKmhPerPoint = 0.004
    private let wheelKmhPerNotch = 0.1
    /// Kurze Nachfrist nach dem Loslassen: schnell aufeinanderfolgende Wischer ergeben einen Befehl.
    private let releaseGrace = 0.45
    private let wheelIdle = 0.6

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    var target: Double { pendingTarget ?? status?.target_speed ?? 2.0 }
    var displayRaw: Double { rawTarget ?? target }

    func refresh() async {
        var req = URLRequest(url: apiBase.appendingPathComponent("status"))
        req.timeoutInterval = 2
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            status = try JSONDecoder().decode(Status.self, from: data)
            daemonReachable = true
            clearAutoPauseNoteIfResolved()
            afterStatusUpdate()
        } catch {
            daemonReachable = false
        }
    }

    /// Hinweis "automatisch pausiert" verschwindet, sobald wieder gelaufen oder das Training beendet wird.
    private func clearAutoPauseNoteIfResolved() {
        guard autoPauseNote != nil, let phase = status?.phase else { return }
        let settled = autoPausedAt.map { Date().timeIntervalSince($0) > 5 } ?? true
        if phase == "idle" || (phase == "running" && settled) {
            autoPauseNote = nil
            pausedByLock = false
        }
    }

    /// quiet: fuer automatische Aktionen - Fehler nicht im Panel anzeigen.
    @discardableResult
    func send(_ action: String, _ body: [String: Any] = [:], quiet: Bool = false) async -> Bool {
        if !quiet && ["start", "resume", "stop"].contains(action) {
            autoPauseNote = nil
            pausedByLock = false
        }
        var req = URLRequest(url: apiBase.appendingPathComponent(action))
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let resp = try JSONDecoder().decode(CommandResponse.self, from: data)
            if let s = resp.status { status = s }
            if !quiet { errorText = resp.ok ? nil : resp.error }
            daemonReachable = true
            return resp.ok
        } catch {
            if !quiet { errorText = "Daemon nicht erreichbar" }
            daemonReachable = false
            return false
        }
    }

    func run(_ action: String, _ body: [String: Any] = [:]) {
        Task { await send(action, body) }
    }

    /// Startet den Daemon neu, damit er das Laufband frisch sucht. Hilft, wenn seine
    /// Bluetooth-Verbindung haengt, obwohl das Band an ist. Nur auf Knopfdruck, nie automatisch.
    func reconnect() {
        guard !reconnecting else { return }
        reconnecting = true
        errorText = nil
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", "-k", "gui/\(getuid())/de.straubmueller.laufbanddaemon"]
        do {
            try p.run()
        } catch {
            errorText = "Neustart fehlgeschlagen: \(error.localizedDescription)"
            reconnecting = false
            return
        }
        Task {
            for _ in 0..<20 {
                try? await Task.sleep(for: .seconds(1))
                if daemonReachable, status?.connected == true { break }
            }
            if status?.connected != true {
                errorText = "Laufband nicht gefunden – ist es an und die FitShow-App geschlossen?"
            }
            reconnecting = false
        }
    }

    /// status: excused (nicht im Buero), present (war im Buero), clear (Markierung entfernen)
    func markStreakDay(_ date: String, _ status: String) {
        run("streak", ["date": date, "status": status])
    }

    /// Trackpad/Magic Mouse: Wert folgt den Fingern, gesendet wird beim Loslassen.
    /// Klassisches Mausrad (ohne Gesten-Phasen): gesendet wird nach kurzer Ruhe.
    func handleScroll(_ event: NSEvent) {
        let up = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        let isGesture = !event.phase.isEmpty

        if event.phase.contains(.mayBegin) || event.phase.contains(.began) {
            commitTask?.cancel()
        }
        if event.phase.contains(.began) {
            scrubbing = true
        }
        if up != 0 {
            // Klassisches Mausrad: feste 0,1 pro Raste, egal wie stark macOS beschleunigt
            let delta = event.hasPreciseScrollingDeltas
                ? Double(up) * trackpadKmhPerPoint
                : (up > 0 ? wheelKmhPerNotch : -wheelKmhPerNotch)
            adjustTarget(by: delta)
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            scheduleCommit(after: releaseGrace)
        } else if !isGesture && up != 0 {
            scrubbing = true
            scheduleCommit(after: wheelIdle)
        }
    }

    func step(by delta: Double) {
        adjustTarget(by: delta)
        scheduleCommit(after: 0.4)
    }

    private func adjustTarget(by delta: Double) {
        let lo = status?.min_speed ?? 1.0, hi = status?.max_speed ?? 8.0
        let raw = min(hi, max(lo, (rawTarget ?? target) + delta))
        rawTarget = raw
        pendingTarget = (raw * 10).rounded() / 10
    }

    private func scheduleCommit(after seconds: Double) {
        commitTask?.cancel()
        commitTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            commitTarget()
        }
    }

    func commitTarget() {
        commitTask?.cancel()
        scrubbing = false
        guard let value = pendingTarget else { return }
        if value == status?.target_speed {
            pendingTarget = nil
            rawTarget = nil
            return
        }
        sending = true
        Task { @MainActor in
            await send("speed", ["value": value])
            sending = false
            if pendingTarget == value && !scrubbing {
                pendingTarget = nil
                rawTarget = nil
            }
        }
    }
}

// MARK: - Menueleisten-Panel

struct PanelStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(.title3, design: .default).weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(Palette.ink2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SpeedControl: View {
    @ObservedObject var model: TreadmillModel
    let status: Status

    var body: some View {
        let lo = status.min_speed, hi = status.max_speed
        let span = max(hi - lo, 0.1)
        let fraction = min(max((model.displayRaw - lo) / span, 0), 1)
        let actual = min(max((status.speed - lo) / span, 0), 1)

        VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 12) {
                HStack {
                    Button { model.step(by: -0.5) } label: {
                        Image(systemName: "minus").frame(width: 24, height: 24)
                    }
                    Spacer()
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(Fmt.num(model.target, 1))
                            .font(.system(size: 32, weight: .semibold))
                            .monospacedDigit()
                            .contentTransition(.numericText(value: model.target))
                        Text("km/h").font(.callout).foregroundStyle(Palette.ink2)
                    }
                    .animation(model.scrubbing ? nil : .snappy(duration: 0.16), value: model.target)
                    Spacer()
                    Button { model.step(by: 0.5) } label: {
                        Image(systemName: "plus").frame(width: 24, height: 24)
                    }
                }
                .buttonStyle(.borderless)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.seriesTrack)
                        Capsule().fill(Palette.series)
                            .frame(width: max(6, geo.size.width * fraction))
                        if status.phase == "running" {
                            Capsule().fill(Palette.ink)
                                .frame(width: 2, height: 12)
                                .offset(x: geo.size.width * actual - 1)
                        }
                    }
                    .frame(height: 6)
                    .frame(maxHeight: .infinity)
                }
                .frame(height: 12)
            }
            .padding(12)
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(model.scrubbing ? Palette.series : Color.clear, lineWidth: 1.5)
            )
            .background(ScrollCatcher { model.handleScroll($0) })
            .animation(.easeOut(duration: 0.15), value: model.scrubbing)

            caption
        }
    }

    @ViewBuilder
    private var caption: some View {
        if model.scrubbing {
            Text("Loslassen übernimmt \(Fmt.num(model.target, 1)) km/h")
                .font(.caption).foregroundStyle(Palette.ink2)
        } else if model.sending {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Wird übertragen …").font(.caption).foregroundStyle(Palette.ink2)
            }
        } else {
            Text("Zieltempo – scrollen oder +/−")
                .font(.caption).foregroundStyle(Palette.muted)
        }
    }
}

struct PanelView: View {
    @ObservedObject var model: TreadmillModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let s = model.status, model.daemonReachable {
                header(s)
                if let note = model.autoPauseNote {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "lock.fill").foregroundStyle(Palette.ink2)
                        Text(note).foregroundStyle(Palette.ink2)
                    }
                    .font(.caption)
                }
                WeekCompactView(progress: WeekProgress(status: s, sessions: []))
                    .padding(12)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                if let streak = s.streak {
                    PanelStreakRow(streak: streak) { date, status in model.markStreakDay(date, status) }
                }
                if let session = s.session {
                    sessionStats(session, s)
                } else if let last = s.last_finished {
                    Text("Letztes Training: \(Fmt.clock(last.duration_s)) · \(Fmt.num(last.distance_km, 2)) km · \(Fmt.int(last.kcal)) kcal"
                         + (last.logged ? "" : " (zu kurz, nicht in Health)"))
                        .font(.caption).foregroundStyle(Palette.ink2)
                }
                SpeedControl(model: model, status: s)
                buttons(s)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.critical)
                    Text("Daemon läuft nicht").font(.headline)
                }
                Text("Details: laufband log").font(.caption.monospaced()).foregroundStyle(Palette.ink2)
                ReconnectButton(model: model)
                    .buttonStyle(.glass)
            }

            if let err = model.errorText ?? model.status?.last_error {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.critical)
                    Text(err).foregroundStyle(Palette.ink2)
                }
                .font(.caption)
            }

            Divider()
            AutomationSection(model: model)
            HStack {
                Button {
                    openWindow(id: "dashboard")
                    NSApp.activate()
                } label: {
                    Label("Übersicht", systemImage: "chart.bar.xaxis")
                }
                Spacer()
                Button("Beenden") { NSApplication.shared.terminate(nil) }
                    .foregroundStyle(Palette.ink2)
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(16)
        .frame(width: 300)
        .task { await model.refresh() }
    }

    private func header(_ s: Status) -> some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(spacing: 7) {
                Circle().fill(dotColor(s)).frame(width: 8, height: 8)
                Text(title(s)).font(.headline)
            }
            Spacer()
            if s.phase == "running" {
                Text("\(Fmt.num(s.speed, 1)) km/h")
                    .font(.headline)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: s.speed))
                    .animation(.snappy, value: s.speed)
            }
        }
    }

    private func sessionStats(_ session: SessionInfo, _ s: Status) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
                GridRow {
                    PanelStat(label: "Zeit", value: Fmt.clock(session.active_s))
                    PanelStat(label: "km", value: Fmt.num(session.distance_km, 2))
                }
                GridRow {
                    PanelStat(label: "Aktive kcal", value: Fmt.int(session.kcal))
                    PanelStat(label: "Schritte", value: Fmt.int(session.steps))
                }
            }
            if session.paused, let pausedFor = session.paused_for_s {
                Text("Endet automatisch in \(Fmt.clock(max(0, s.auto_finish_after_s - pausedFor)))")
                    .font(.caption).foregroundStyle(Palette.ink2)
            }
        }
    }

    @ViewBuilder
    private func buttons(_ s: Status) -> some View {
        switch s.phase {
        case "offline":
            if s.setup?.done == false || s.setup?.address.isEmpty == true {
                Button {
                    openWindow(id: "setup")
                    NSApp.activate()
                } label: {
                    Label("Laufband einrichten", systemImage: "gearshape").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.glassProminent)
            } else {
                Text("Laufband einschalten – verbindet sich automatisch. Die FitShow-App muss geschlossen sein.")
                    .font(.caption).foregroundStyle(Palette.ink2)
            }
            HStack {
                ReconnectButton(model: model)
                if s.session != nil {
                    Button("Training beenden") { model.run("stop") }
                }
            }
            .buttonStyle(.glass)
        case "idle", "error":
            Button {
                model.commitTarget()
                model.run("start", ["speed": model.target])
            } label: {
                Label("Start", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
        case "countdown", "running":
            GlassEffectContainer(spacing: 8) {
                HStack {
                    Button { model.run("pause") } label: {
                        Label("Pause", systemImage: "pause.fill").frame(maxWidth: .infinity)
                    }
                    Button { model.run("stop") } label: {
                        Label("Stopp", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        case "paused":
            GlassEffectContainer(spacing: 8) {
                HStack {
                    Button { model.run("resume") } label: {
                        Label("Weiter", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!s.connected)
                    Button { model.run("stop") } label: {
                        Label("Beenden", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
                .controlSize(.large)
            }
        default:
            EmptyView()
        }
    }

    private func title(_ s: Status) -> String {
        switch s.phase {
        case "offline": return "Nicht verbunden"
        case "idle": return "Bereit"
        case "countdown": return "Startet … \(s.countdown ?? 0)"
        case "running": return "Läuft"
        case "paused": return "Pausiert"
        case "error": return "Fehler am Gerät"
        default: return s.phase
        }
    }

    private func dotColor(_ s: Status) -> Color {
        switch s.phase {
        case "idle", "running", "countdown": return Palette.statusGood
        case "error": return Palette.critical
        default: return Palette.muted
        }
    }
}

struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Palette.grid))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Palette.border))
    }
}

struct AutomationSection: View {
    @ObservedObject var model: TreadmillModel
    @AppStorage("panelShowShortcuts") private var expanded = false
    @AppStorage("celebration.sound") private var celebrationSound = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(AppShortcut.all) { shortcut in
                    HStack {
                        Text(shortcut.label).foregroundStyle(Palette.ink2)
                        Spacer(minLength: 8)
                        Keycap(text: shortcut.display)
                    }
                    .font(.caption)
                }
                Divider().padding(.vertical, 2)
                Toggle("Schreibtisch-Widget", isOn: $model.showDesktopWidget)
                Toggle("Applaus bei Erfolgen", isOn: $celebrationSound)
                Toggle("Bei gesperrtem Mac pausieren", isOn: $model.pauseOnLock)
                Toggle("Beim Entsperren weiterlaufen", isOn: $model.resumeOnUnlock)
                    .disabled(!model.pauseOnLock)
                Text("Auch vor dem Ruhezustand wird pausiert. Automatisches Weiterlaufen startet das Band ohne Rückfrage – nur einschalten, wenn du beim Entsperren auf dem Band stehst.")
                    .font(.caption2)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Divider().padding(.vertical, 2)
                OfficeNetworkRow()
                Divider().padding(.vertical, 2)
                Button {
                    postOpen(openSetupNotification)
                } label: {
                    Label("Einrichtung (Laufband, Körperdaten, Health) …", systemImage: "gearshape")
                }
                .buttonStyle(.borderless)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.caption)
            .padding(.top, 6)
        } label: {
            Label("Tastenkürzel & Automatik", systemImage: "keyboard")
                .font(.callout)
                .foregroundStyle(Palette.ink2)
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: TreadmillModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        content
            .onReceive(DistributedNotificationCenter.default().publisher(for: openDashboardNotification)) { _ in
                openWindow(id: "dashboard")
                NSApp.activate()
            }
            .onReceive(DistributedNotificationCenter.default().publisher(for: openJourneyNotification)) { _ in
                UserDefaults.standard.set(DashboardTab.journey.rawValue, forKey: "dashboard.tab")
                openWindow(id: "dashboard")
                NSApp.activate()
            }
            .onReceive(DistributedNotificationCenter.default().publisher(for: openStoryNotification)) { _ in
                openWindow(id: "story")
                NSApp.activate()
            }
            .onReceive(DistributedNotificationCenter.default().publisher(for: openSetupNotification)) { _ in
                openWindow(id: "setup")
                NSApp.activate()
            }
            .onChange(of: model.status?.setup?.done) { _, done in
                // Erster Start ohne Einrichtung: das Fenster einmal von selbst oeffnen
                if done == false, !model.setupShown {
                    model.setupShown = true
                    openWindow(id: "setup")
                    NSApp.activate()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        let s = model.status
        switch s?.phase {
        case "running":
            HStack(spacing: 4) {
                Image(systemName: "figure.walk.motion")
                Text("\(Fmt.num(s!.speed, 1)) · \(Fmt.clock(s!.session?.active_s ?? 0))")
                    .monospacedDigit()
            }
        case "countdown":
            HStack(spacing: 4) {
                Image(systemName: "figure.walk.motion")
                Text("\(s!.countdown ?? 0)")
            }
        case "paused":
            Image(systemName: "pause.circle")
        case "offline", nil:
            Image(systemName: "figure.stand")
        default:
            if let streak = s?.streak, streak.current > 0 || streak.at_risk {
                HStack(spacing: 3) {
                    Image(systemName: streak.todayDone ? "flame.fill" : "flame")
                    Text("\(streak.current)").monospacedDigit()
                }
            } else {
                Image(systemName: "figure.walk")
            }
        }
    }
}

@main
struct LaufbandMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: TreadmillModel

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let model = TreadmillModel()
        _model = StateObject(wrappedValue: model)
        AppDelegate.model = model
        if !Snapshot.runIfRequested() {
            model.enableSystemIntegration()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Laufband", id: "dashboard") {
            DashboardView(live: model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 980)
        .defaultLaunchBehavior(.suppressed)
        .handlesExternalEvents(matching: [])

        Window("Einrichtung", id: "setup") {
            SetupView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .handlesExternalEvents(matching: [])

        Window("Rückblick", id: "story") {
            StoryWindow(live: model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .handlesExternalEvents(matching: [])
    }
}
