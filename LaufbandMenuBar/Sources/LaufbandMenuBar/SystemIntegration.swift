import AppKit
import Foundation

func appLog(_ message: String) {
    let stamp = Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)
        .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits).locale(Fmt.de))
    FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
}

extension TreadmillModel {
    /// Tastenkuerzel + Sperre/Ruhezustand. Nur in der echten App, nicht beim Offscreen-Rendern.
    func enableSystemIntegration() {
        let center = HotKeyCenter()
        for shortcut in AppShortcut.all {
            let ok = center.register(keyCode: shortcut.keyCode, modifiers: AppShortcut.modifiers) { [weak self] in
                guard let self else { return }
                shortcut.action(self)
            }
            if !ok { appLog("Tastenkürzel \(shortcut.display) konnte nicht registriert werden") }
        }
        hotKeys = center

        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenLocked() }
        })
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenUnlocked() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemWillSleep() }
        })
        DesktopWidgetController.shared.setVisible(showDesktopWidget, model: self)

        // Fusswege fuer Bodensee (Gesamtstrecke) und die gewaehlte Reise vorab berechnen
        let routes = RouteGeometryStore.shared
        routes.ensure(JourneyRoute.all[0])
        routes.ensure(JourneyStore.shared.route)

        integrationEnabled = true
        appLog("Tastenkürzel und Sperr-Automatik aktiv")
    }

    /// Nach jedem Status: Erfolge pruefen, Streak feiern/erinnern/fragen.
    func afterStatusUpdate() {
        guard integrationEnabled else { return }
        AchievementCenter.shared.update(status: status)
        guard let streak = status?.streak else { return }

        // Streak heute gesichert (waehrend des Laufens die Mindestzeit geknackt)
        if let before = lastTodayDone, !before, streak.todayDone {
            CelebrationCenter.shared.celebrate(symbol: "flame.fill", title: "Streak gesichert!",
                                               message: "\(streak.current) \(streak.current == 1 ? "Tag" : "Tage") Wanderstreak – die Flamme brennt weiter.")
        }
        lastTodayDone = streak.todayDone

        let now = Date()
        guard now.timeIntervalSince(lastReminderCheck) > 30 else { return }
        lastReminderCheck = now
        let defaults = UserDefaults.standard
        let hour = deCalendar.component(.hour, from: now)

        let officeKnown = !OfficeNetwork.known.isEmpty
        if officeKnown { checkOffice(streak, now: now) }

        // Abend-Erinnerung an Werktagen, falls noch offen (mit Buero-Netz nur, wenn heute im Buero)
        if streak.at_risk, hour >= 17, defaults.string(forKey: "streak.reminded") != streak.today.date,
           !officeKnown || OfficeNetwork.seenDays.contains(streak.today.date) {
            defaults.set(streak.today.date, forKey: "streak.reminded")
            let date = streak.today.date
            Banner.shared.show(id: "streak-heute-\(date)", symbol: "flame",
                               title: "Dein Wanderstreak wartet",
                               message: "Noch \(Fmt.num(streak.minutesLeftToday, 0)) Minuten heute, dann bleibt dein Streak (\(streak.current) \(streak.current == 1 ? "Tag" : "Tage")).",
                               actions: [
                                   BannerAction(title: "Jetzt starten", prominent: true) { [weak self] in self?.hotkeyToggle() },
                                   BannerAction(title: "Heute nicht im Büro", prominent: false) { [weak self] in self?.markStreakDay(date, "excused") },
                               ])
        }
        // Offene Fragen zu vergangenen Werktagen: hoechstens eine Meldung am Tag fuer alle zusammen - nur ohne Buero-Netz
        if !officeKnown, streak.pending.count > 1, hour >= 8, defaults.string(forKey: "streak.asked") != streak.today.date {
            defaults.set(streak.today.date, forKey: "streak.asked")
            let days = streak.pending
            let list = days.suffix(4).compactMap(StreakDay.parser.date(from:))
                .map { $0.formatted(.dateTime.weekday(.abbreviated).day().month(.twoDigits).locale(Fmt.de)) }
                .joined(separator: ", ")
            Banner.shared.show(id: "streak-frage-\(streak.today.date)", symbol: "questionmark.circle.fill",
                               title: "\(days.count) Tage offen – warst du im Büro?",
                               message: (days.count > 4 ? "Zuletzt " : "") + "\(list). Tage ohne Büro zählen nicht gegen deinen Streak.",
                               actions: [
                                   BannerAction(title: "Alle nicht im Büro", prominent: true) { [weak self] in
                                       days.forEach { self?.markStreakDay($0, "excused") }
                                   },
                                   BannerAction(title: "In der App eintragen", prominent: false) { postOpen(openDashboardNotification) },
                               ])
        } else if !officeKnown, streak.pending.count == 1, let first = streak.pending.first, hour >= 8 {
            if defaults.string(forKey: "streak.asked") != streak.today.date, let day = StreakDay.parser.date(from: first) {
                defaults.set(streak.today.date, forKey: "streak.asked")
                Banner.shared.show(id: "streak-frage-\(first)", symbol: "questionmark.circle.fill",
                                   title: "Warst du im Büro?",
                                   message: "Am \(day.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Fmt.de))) bist du keine \(Fmt.num(streak.required_min, 0)) Minuten gelaufen. Warst du nicht im Büro, bleibt dein Streak.",
                                   actions: [
                                       BannerAction(title: "Nicht im Büro", prominent: true) { [weak self] in self?.markStreakDay(first, "excused") },
                                       BannerAction(title: "War im Büro", prominent: false) { [weak self] in self?.markStreakDay(first, "present") },
                                   ])
            }
        }
    }

    /// Buero-Erkennung statt Rueckfrage: offene Vortage still beantworten; den Router hoechstens
    /// alle 10 min pruefen und nach dem ersten Treffer des Tages gar nicht mehr.
    private func checkOffice(_ streak: StreakInfo, now: Date) {
        let today = streak.today.date
        let seen = OfficeNetwork.seenDays
        for day in streak.pending where day >= (OfficeNetwork.since ?? today) {
            markStreakDay(day, seen.contains(day) ? "present" : "excused")
        }
        guard !seen.contains(today), !deCalendar.isDateInWeekend(now),
              now.timeIntervalSince(lastOfficeCheck) > 600 else { return }
        lastOfficeCheck = now
        if let gateway = OfficeNetwork.currentGateway(), OfficeNetwork.known.contains(gateway) {
            OfficeNetwork.markSeen(today)
        }
    }

    // MARK: Tastenkuerzel

    func hotkeyToggle() {
        guard let s = connectedStatusOrHUD() else { return }
        switch s.phase {
        case "idle", "error": startNow()
        case "running", "countdown": pauseNow()
        case "paused": resumeNow()
        default: break
        }
    }

    private func connectedStatusOrHUD() -> Status? {
        guard daemonReachable, let s = status, s.connected else {
            HUD.shared.show(symbol: "antenna.radiowaves.left.and.right.slash", title: "Laufband nicht verbunden",
                            detail: "Einschalten – verbindet sich automatisch")
            return nil
        }
        return s
    }

    func startNow(speed: Double? = nil) {
        if let speed { setTarget(speed, commitDelay: 0) }
        commitTarget()
        let v = target
        run("start", ["speed": v])
        HUD.shared.show(symbol: "play.fill", title: "Start", detail: "bei \(Fmt.num(v, 1)) km/h · Countdown läuft")
    }

    func pauseNow() {
        run("pause")
        HUD.shared.show(symbol: "pause.fill", title: "Pause", detail: "Band hält an – Training bleibt offen")
    }

    func resumeNow() {
        commitTarget()
        let v = target
        run("resume")
        HUD.shared.show(symbol: "play.fill", title: "Weiter", detail: "bei \(Fmt.num(v, 1)) km/h")
    }

    /// Absolutes Zieltempo setzen (Links, Kurzbefehle); gesendet wird nach `commitDelay`.
    func setTarget(_ value: Double, commitDelay: Double = 0.4) {
        let lo = status?.min_speed ?? 1.0, hi = status?.max_speed ?? 8.0
        let clamped = (min(hi, max(lo, value)) * 10).rounded() / 10
        step(by: clamped - displayRaw)
        if commitDelay == 0 { commitTarget() }
    }

    // MARK: laufband://-Links

    func handleURL(_ url: URL) {
        guard url.scheme?.lowercased() == "laufband" else { return }
        let action = (url.host(percentEncoded: false) ?? "").lowercased()
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let number = items.first { ["wert", "value", "speed", "tempo"].contains($0.name.lowercased()) }?.value
            .flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
        appLog("Link: \(url.absoluteString)")

        switch action {
        case "toggle", "startpause":
            hotkeyToggle()
        case "start":
            guard let s = connectedStatusOrHUD() else { return }
            if s.phase == "idle" || s.phase == "error" { startNow(speed: number) } else if s.phase == "paused" { resumeNow() }
        case "pause":
            if let s = connectedStatusOrHUD(), s.phase == "running" || s.phase == "countdown" { pauseNow() }
        case "weiter", "resume":
            if let s = connectedStatusOrHUD(), s.phase == "paused" { resumeNow() }
        case "stopp", "stop", "beenden":
            hotkeyStop()
        case "schneller", "faster":
            hotkeyStep(0.5)
        case "langsamer", "slower":
            hotkeyStep(-0.5)
        case "tempo", "speed":
            guard let number else { return }
            setTarget(number)
            HUD.shared.show(symbol: "speedometer", title: "\(Fmt.num(target, 1)) km/h", detail: "Zieltempo")
        case "uebersicht", "übersicht", "dashboard":
            postOpen(openDashboardNotification)
        case "rueckblick", "rückblick", "story":
            postOpen(openStoryNotification)
        case "reise", "journey":
            postOpen(openJourneyNotification)
        case "debug-banner":
            Banner.shared.show(id: "debug", symbol: "questionmark.circle.fill", title: "Warst du im Büro?",
                               message: "Am Dienstag, 29. September bist du keine 5 Minuten gelaufen. Warst du nicht im Büro, bleibt dein Streak.",
                               actions: [BannerAction(title: "Nicht im Büro", prominent: true) {},
                                         BannerAction(title: "War im Büro", prominent: false) {}],
                               sound: false)
        case "debug-banner-close":
            Banner.shared.dismiss()
        case "debug-capture":
            let value = { (name: String) in items.first { $0.name == name }?.value }
            if let tab = value("tab") { UserDefaults.standard.set(tab, forKey: "dashboard.tab") }
            if let dim = value("dim") { UserDefaults.standard.set(dim, forKey: "dashboard.3d") }
            switch value("window") {
            case "story": postOpen(openStoryNotification)
            case "setup": postOpen(openSetupNotification)
            default: postOpen(openDashboardNotification)
            }
            let prefix = value("out") ?? "/tmp/laufband-capture"
            // nur in Temp-Verzeichnisse schreiben, damit ein fremder Link keine Dateien woanders anlegen kann
            guard prefix.hasPrefix("/tmp/") || prefix.hasPrefix("/private/tmp/"), !prefix.contains("..") else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(Double(value("wait") ?? "4") ?? 4))
                DebugCapture.captureWindows(prefix: prefix)
            }
        default:
            HUD.shared.show(symbol: "questionmark.circle", title: "Unbekannter Link", detail: url.absoluteString)
        }
    }

    func hotkeyStep(_ delta: Double) {
        guard daemonReachable, let s = status else {
            HUD.shared.show(symbol: "exclamationmark.triangle.fill", title: "Daemon nicht erreichbar")
            return
        }
        step(by: delta)
        let span = max(s.max_speed - s.min_speed, 0.1)
        let running = s.phase == "running" || s.phase == "countdown"
        HUD.shared.show(symbol: delta > 0 ? "hare.fill" : "tortoise.fill",
                        title: "\(Fmt.num(target, 1)) km/h",
                        detail: running ? "Zieltempo" : "Zieltempo für den nächsten Start",
                        progress: (target - s.min_speed) / span)
    }

    func hotkeyStop() {
        guard status?.session != nil else {
            HUD.shared.show(symbol: "stop.fill", title: "Kein Training aktiv")
            return
        }
        Task { @MainActor in
            guard await send("stop") else { return }
            if let f = status?.last_finished {
                HUD.shared.show(symbol: "flag.checkered", title: "Training beendet",
                                detail: "\(Fmt.clock(f.duration_s)) · \(Fmt.num(f.distance_km, 2)) km · \(Fmt.int(f.kcal)) kcal"
                                    + (f.logged ? "" : " · zu kurz, nicht in Health"))
            }
        }
    }

    // MARK: Sperre & Ruhezustand

    func screenLocked() {
        appLog("Mac gesperrt")
        guard pauseOnLock else { return }
        Task { @MainActor in
            await refresh()
            guard let phase = status?.phase, phase == "running" || phase == "countdown" else {
                appLog("Band läuft nicht – nichts zu tun")
                return
            }
            pausedByLock = true
            autoPausedAt = Date()
            autoPauseNote = "Automatisch pausiert – der Mac wurde gesperrt."
            await send("pause", quiet: true)
            appLog("Band pausiert (Sperre)")
        }
    }

    func screenUnlocked() {
        appLog("Mac entsperrt")
        guard pausedByLock else { return }
        pausedByLock = false
        Task { @MainActor in
            await refresh()
            guard status?.phase == "paused" else { return }
            if resumeOnUnlock, status?.connected == true {
                autoPauseNote = nil
                run("resume")
                HUD.shared.show(symbol: "play.fill", title: "Weiter", detail: "bei \(Fmt.num(target, 1)) km/h")
                appLog("Band fortgesetzt (Entsperren)")
            } else {
                autoPauseNote = "Pausiert, weil der Mac gesperrt war. Weiter mit ⌃⌥⌘ Leertaste."
            }
        }
    }

    /// Vor dem Ruhezustand synchron pausieren – danach kann der Mac das Band nicht mehr erreichen.
    func systemWillSleep() {
        appLog("Ruhezustand steht bevor")
        guard pauseOnLock, let phase = status?.phase, phase == "running" || phase == "countdown" else { return }
        pausedByLock = true
        autoPausedAt = Date()
        autoPauseNote = "Automatisch pausiert – der Mac ist in den Ruhezustand gegangen."

        var req = URLRequest(url: apiBase.appendingPathComponent("pause"))
        req.httpMethod = "POST"
        req.timeoutInterval = 2
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 2)
        // Der Daemon schickt den BLE-Befehl direkt nach der Antwort; kurz Zeit dafuer lassen
        Thread.sleep(forTimeInterval: 0.6)
        appLog("Band pausiert (Ruhezustand)")
    }
}
