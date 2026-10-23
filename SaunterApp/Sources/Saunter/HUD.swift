import AppKit
import SwiftUI

/// Kurze Einblendung oben am Bildschirm (wie das Lautstaerke-HUD), damit
/// Tastenkuerzel ohne offenes Panel sichtbare Rueckmeldung geben.
@MainActor
final class HUD {
    static let shared = HUD()

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(symbol: String, title: String, detail: String? = nil, progress: Double? = nil) {
        let panel = self.panel ?? makePanel()
        let hosting = NSHostingView(rootView: HUDView(symbol: symbol, title: title, detail: detail, progress: progress))
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        panel.setContentSize(size)

        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 4))
        }

        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }

        hideTask?.cancel()
        hideTask = Task { @MainActor [weak panel] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled, let panel else { return }
            await NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                panel.animator().alphaValue = 0
            }
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel = p
        return p
    }
}

struct HUDView: View {
    let symbol: String
    let title: String
    let detail: String?
    let progress: Double?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Palette.series)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(Palette.ink2)
                }
                if let progress {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.seriesTrack)
                            Capsule().fill(Palette.series)
                                .frame(width: max(5, geo.size.width * min(max(progress, 0), 1)))
                        }
                    }
                    .frame(width: 170, height: 5)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .frame(minWidth: 230, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(24)
    }
}
