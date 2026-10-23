import SwiftUI
import AppKit

/// Entwickler-Werkzeug: fotografiert die eigenen Fenster der laufenden App
/// (inkl. 3D/Glas/Karte, die sich offscreen nicht rendern lassen).
enum DebugCapture {
    private typealias CreateImage = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> Unmanaged<CGImage>?

    @MainActor
    static func captureWindows(prefix: String) {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            appLog("Capture: Funktion nicht verfügbar")
            return
        }
        let create = unsafeBitCast(sym, to: CreateImage.self)
        for window in NSApp.windows where window.isVisible && window.frame.width > 300 {
            guard let image = create(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                     [.boundsIgnoreFraming, .bestResolution])?.takeRetainedValue() else {
                appLog("Capture: kein Bild für \(window.title)")
                continue
            }
            let rep = NSBitmapImageRep(cgImage: image)
            let name = window.title.isEmpty ? "fenster\(window.windowNumber)" : window.title
            let url = URL(fileURLWithPath: "\(prefix)-\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            appLog("Capture: \(url.path) (\(image.width)×\(image.height))")
        }
    }
}

struct AppIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                .fill(MeshGradient(width: 3, height: 3,
                                   points: [[0, 0], [0.5, 0], [1, 0], [0, 0.5], [0.62, 0.45], [1, 0.5], [0, 1], [0.5, 1], [1, 1]],
                                   colors: [0x5598E7, 0x3987E5, 0x2A78D6, 0x3987E5, 0x256ABF, 0x1C5CAB, 0x1C5CAB, 0x104281, 0x0D366B]
                                       .map { Color(nsColor: NSColor(hex: $0)) }))
                .overlay(
                    RoundedRectangle(cornerRadius: 186, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0)], startPoint: .top, endPoint: .center))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 186, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08)], startPoint: .top, endPoint: .bottom),
                                      lineWidth: 5)
                )
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.28), radius: 18, y: 10)

            // Tempo-Bogen hinter der Figur
            Circle()
                .trim(from: 0.12, to: 0.62)
                .stroke(.white.opacity(0.35), style: StrokeStyle(lineWidth: 34, lineCap: .round))
                .frame(width: 560, height: 560)
                .rotationEffect(.degrees(96))
            Image(systemName: "figure.walk.motion")
                .font(.system(size: 400, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
                .offset(x: -8, y: 6)
        }
        .frame(width: 1024, height: 1024)
    }
}

/// Entwickler-Werkzeug: `Saunter --render-dashboard|--render-panel <datei.png> [--dark] [--range 7|30|12w|all]`
/// rendert die Uebersicht bzw. das Menueleisten-Panel offscreen als Bild und beendet sich.
enum Snapshot {
    /// true, wenn gerendert wird (die App beendet sich danach selbst).
    @MainActor
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-applause"), i + 1 < args.count {
            try? Applause.makeWAV().write(to: URL(fileURLWithPath: args[i + 1]))
            print("Applaus erzeugt: \(args[i + 1])")
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count {
            let renderer = ImageRenderer(content: AppIconView())
            renderer.scale = 1
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: args[i + 1]))
                print("Icon gerendert: \(args[i + 1])")
            }
            exit(0)
        }
        let panel = args.contains("--render-panel")
        guard let i = args.firstIndex(where: { $0 == "--render-dashboard" || $0 == "--render-panel" }),
              i + 1 < args.count else { return false }
        let url = URL(fileURLWithPath: args[i + 1])
        let dark = args.contains("--dark")
        let range: StatsRange = {
            guard let r = args.firstIndex(of: "--range"), r + 1 < args.count else { return .month }
            switch args[r + 1] {
            case "7": return .week
            case "12w": return .quarter
            case "all": return .all
            default: return .month
            }
        }()

        Task { @MainActor in
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            NSApp.appearance = appearance
            let live = TreadmillModel()
            await live.refresh()
            let data = DashboardData()
            await data.loadSessions()
            let selected = args.firstIndex(of: "--select").flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil }
            if let id = data.profileID(liveID: live.status?.session?.id, selectedID: selected) {
                await data.loadSamples(for: id)
            }

            let tab: DashboardTab = {
                guard let t = args.firstIndex(of: "--tab"), t + 1 < args.count else { return .overview }
                return DashboardTab.allCases.first { $0.rawValue.lowercased().hasPrefix(args[t + 1].lowercased()) } ?? .overview
            }()
            let journey = JourneyStore.shared
            await data.loadRidge(for: data.sessions)
            let content = Group {
                if panel {
                    PanelView(model: live)
                } else if args.contains("--story") {
                    StorySlide(index: Int(args.firstIndex(of: "--story").map { args.indices.contains($0 + 1) ? args[$0 + 1] : "0" } ?? "0") ?? 0,
                               summary: StorySummary(sessions: data.sessions, zones: data.zones, period: .month))
                        .frame(width: 450, height: 800)
                } else if args.contains("--widget") {
                    DesktopWidgetView(model: live).frame(width: 360, height: 236)
                } else {
                    DashboardPage(live: live, data: data, journey: journey, tab: tab, range: range,
                                  threeD: args.contains("--3d"), selectedID: .constant(selected)) {}
                        .frame(width: 1320)
                }
            }
            .background(Color.adaptive(0xECECEA, 0x232322))
            .environment(\.colorScheme, dark ? .dark : .light)

            appearance.performAsCurrentDrawingAppearance {
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                if let image = renderer.nsImage,
                   let tiff = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff),
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    try? png.write(to: url)
                    print("gerendert: \(url.path)")
                } else {
                    print("Rendern fehlgeschlagen")
                }
            }
            exit(0)
        }
        return true
    }
}
