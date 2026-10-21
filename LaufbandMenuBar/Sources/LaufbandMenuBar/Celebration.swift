import SwiftUI
import AppKit

// MARK: - Applaus (synthetisch: viele kurze, gefilterte Rausch-Klatscher)

enum Applause {
    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Laufband/applaus-v1.wav")
    }

    static func play() {
        guard UserDefaults.standard.object(forKey: "celebration.sound") as? Bool ?? true else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? makeWAV().write(to: url)
        }
        NSSound(contentsOf: url, byReference: true)?.play()
    }

    /// 3,2 s Applaus, 44,1 kHz mono, 16 bit.
    static func makeWAV() -> Data {
        let rate = 44_100.0, seconds = 3.2
        let n = Int(rate * seconds)
        var mix = [Float](repeating: 0, count: n)
        var rng = SystemRandomNumberGenerator()

        func envelope(_ t: Double) -> Double {
            let rise = min(1, t / 0.35)
            let fall = t > 1.9 ? max(0, 1 - (t - 1.9) / 1.3) : 1
            return rise * fall
        }

        for _ in 0..<260 {
            let t = Double.random(in: 0..<seconds - 0.05, using: &rng)
            let level = envelope(t) * Double.random(in: 0.25...1.0, using: &rng)
            guard level > 0.02 else { continue }
            let start = Int(t * rate)
            let length = Int(rate * Double.random(in: 0.012...0.03, using: &rng))
            let tau = rate * Double.random(in: 0.003...0.007, using: &rng)
            // Bandpass (Biquad) fuer den "Klatsch"-Klang je Person unterschiedlich
            let f0 = Double.random(in: 900...2600, using: &rng), q = 1.4
            let w0 = 2 * Double.pi * f0 / rate, alpha = sin(w0) / (2 * q)
            let a0 = 1 + alpha
            let b0 = alpha / a0, b2 = -alpha / a0, a1 = -2 * cos(w0) / a0, a2 = (1 - alpha) / a0
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in 0..<length where start + i < n {
                let x = Double.random(in: -1...1, using: &rng) * exp(-Double(i) / tau)
                let y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = x; y2 = y1; y1 = y
                mix[start + i] += Float(y * level)
            }
        }
        // etwas Raum: zwei kurze Rueckkopplungs-Echos
        for (delay, gain) in [(Int(rate * 0.023), Float(0.35)), (Int(rate * 0.041), Float(0.22))] {
            for i in delay..<n { mix[i] += mix[i - delay] * gain }
        }
        let peak = max(mix.map { abs($0) }.max() ?? 1, 0.0001)
        let samples = mix.map { Int16(max(-1, min(1, $0 / peak * 0.7)) * Float(Int16.max)) }

        var data = Data()
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + byteCount).littleEndian)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16).littleEndian)
        append(UInt16(1).littleEndian); append(UInt16(1).littleEndian)
        append(UInt32(44_100).littleEndian); append(UInt32(88_200).littleEndian)
        append(UInt16(2).littleEndian); append(UInt16(16).littleEndian)
        data.append(contentsOf: Array("data".utf8)); append(byteCount.littleEndian)
        samples.forEach { append($0.littleEndian) }
        return data
    }
}

// MARK: - Konfetti ueber den ganzen Bildschirm

struct ConfettiView: View {
    let start = Date()
    private let pieces: [ConfettiPiece] = (0..<160).map { _ in ConfettiPiece() }

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            Canvas { context, size in
                for p in pieces {
                    let age = t - p.delay
                    guard age > 0 else { continue }
                    let x = p.x * size.width + sin(age * p.wobble + p.phase) * 30 + p.drift * age * 40
                    let y = -20 + age * p.speed * size.height / 3.2
                    guard y < size.height + 20 else { continue }
                    let fade = max(0, min(1, 3.6 - age))
                    var ctx = context
                    ctx.opacity = fade
                    ctx.translateBy(x: x, y: y)
                    ctx.rotate(by: .radians(age * p.spin))
                    let rect = CGRect(x: -p.w / 2, y: -p.h / 2, width: p.w, height: p.h * abs(cos(age * p.flip)))
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(p.color))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct ConfettiPiece {
    let x = Double.random(in: 0...1)
    let delay = Double.random(in: 0...0.8)
    let speed = Double.random(in: 0.9...1.6)
    let wobble = Double.random(in: 2...5)
    let phase = Double.random(in: 0...6)
    let drift = Double.random(in: -0.6...0.6)
    let spin = Double.random(in: -6...6)
    let flip = Double.random(in: 3...9)
    let w = Double.random(in: 6...11)
    let h = Double.random(in: 9...16)
    let color: Color = [0x2A78D6, 0x5598E7, 0xEB6834, 0xFAB219, 0x86B6EF, 0xFFFFFF]
        .map { Color(nsColor: NSColor(hex: $0)) }.randomElement()!
}

struct CelebrationToast: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [Color(nsColor: NSColor(hex: 0xFAB219)), Palette.flame],
                                                startPoint: .top, endPoint: .bottom))
                .symbolEffect(.bounce, options: .repeat(2))
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 18, weight: .bold))
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .frame(width: 420, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(24)
    }
}

// MARK: - Ablauf

@MainActor
final class CelebrationCenter {
    static let shared = CelebrationCenter()

    private var queue: [(String, String, String)] = []
    private var running = false
    private var confettiPanel: NSPanel?
    private var toastPanel: NSPanel?

    /// Konfetti + Glas-Karte + Applaus (+ Mitteilung). Mehrere Erfolge werden nacheinander gefeiert.
    func celebrate(symbol: String, title: String, message: String) {
        queue.append((symbol, title, message))
        guard !running else { return }
        Task { await runQueue() }
    }

    private func runQueue() async {
        running = true
        while !queue.isEmpty {
            let (symbol, title, message) = queue.removeFirst()
            appLog("Feier: \(title)")
            show(symbol: symbol, title: title, message: message)
            Applause.play()
            try? await Task.sleep(for: .seconds(5))
            hide()
            try? await Task.sleep(for: .seconds(0.6))
        }
        running = false
    }

    private func screen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    private func overlayPanel(frame: NSRect) -> NSPanel {
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return p
    }

    private func show(symbol: String, title: String, message: String) {
        guard let screen = screen() else { return }
        let confetti = overlayPanel(frame: screen.frame)
        confetti.contentView = NSHostingView(rootView: ConfettiView())
        confetti.orderFrontRegardless()
        confettiPanel = confetti

        let toastHost = NSHostingView(rootView: CelebrationToast(symbol: symbol, title: title, message: message))
        let size = toastHost.fittingSize
        let visible = screen.visibleFrame
        let toast = overlayPanel(frame: NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 30,
                                               width: size.width, height: size.height))
        toast.contentView = toastHost
        toast.alphaValue = 0
        toast.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            toast.animator().alphaValue = 1
        }
        toastPanel = toast
    }

    private func hide() {
        let toast = toastPanel, confetti = confettiPanel
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            toast?.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                toast?.orderOut(nil)
                confetti?.orderOut(nil)
            }
        })
        toastPanel = nil
        confettiPanel = nil
    }
}

// MARK: - Glas-Banner mit Knoepfen (statt Mitteilungen; die erlaubt macOS nur signierten Apps)

struct BannerAction {
    let title: String
    let prominent: Bool
    let handler: () -> Void
}

/// Eigene Knoepfe: Standard-Stile wirken im nie aktiven Banner-Fenster ausgegraut.
struct BannerButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(prominent ? Color.white : Palette.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(prominent ? Palette.series : Palette.ink.opacity(0.1)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

/// NSHostingView, die schon den ersten Klick annimmt (das Panel wird nie aktiv).
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct BannerView: View {
    let symbol: String
    let title: String
    let message: String
    let actions: [BannerAction]
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [Color(nsColor: NSColor(hex: 0xFAB219)), Palette.flame],
                                                startPoint: .top, endPoint: .bottom))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.headline)
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Schließen")
                }
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                        Button(action.title, action: action.handler)
                            .buttonStyle(BannerButtonStyle(prominent: action.prominent))
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(width: 380, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(16)
    }
}

@MainActor
final class Banner {
    static let shared = Banner()
    private var panel: NSPanel?
    private var currentID: String?

    func show(id: String, symbol: String, title: String, message: String, actions: [BannerAction], sound: Bool = true) {
        if currentID == id, panel?.isVisible == true { return }
        dismiss()
        currentID = id
        let wrapped = actions.map { action in
            BannerAction(title: action.title, prominent: action.prominent) { [weak self] in
                action.handler()
                self?.dismiss()
            }
        }
        let host = FirstClickHostingView(rootView: BannerView(symbol: symbol, title: title, message: message, actions: wrapped) {
            [weak self] in self?.dismiss()
        })
        let size = host.fittingSize
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let p = NSPanel(contentRect: NSRect(x: visible.maxX - size.width - 4, y: visible.maxY - size.height - 4,
                                            width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            p.animator().alphaValue = 1
        }
        if sound { NSSound(named: "Glass")?.play() }
        panel = p
        appLog("Banner: \(title)")
    }

    func dismiss() {
        guard let p = panel else { return }
        panel = nil
        currentID = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            p.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in p.orderOut(nil) }
        })
    }
}
