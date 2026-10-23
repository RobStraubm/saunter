import SwiftUI
import AppKit

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension Color {
    /// Eigene Stufe fuer Hell und Dunkel statt automatischer Umkehrung.
    static func adaptive(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: alpha)
        })
    }
}

/// Referenz-Palette (Slot 1 Blau, Blau-Rampe, Status-Farben, Tinte, Flaechen).
enum Palette {
    static let series = Color.adaptive(0x2A78D6, 0x3987E5)
    static let seriesTrack = Color.adaptive(0xCDE2FB, 0x0D366B)
    static let surface = Color.adaptive(0xFCFCFB, 0x1A1A19)
    static let ink = Color.adaptive(0x0B0B0B, 0xFFFFFF)
    static let ink2 = Color.adaptive(0x52514E, 0xC3C2B7)
    static let muted = Color.adaptive(0x898781, 0x898781)
    static let grid = Color.adaptive(0xE1E0D9, 0x2C2C2A)
    static let baseline = Color.adaptive(0xC3C2B7, 0x383835)
    static let good = Color.adaptive(0x006300, 0x0CA30C)
    static let border = Color.adaptive(0x0B0B0B, 0xFFFFFF, alpha: 0.10)
    static let statusGood = Color(nsColor: NSColor(hex: 0x0CA30C))
    static let critical = Color(nsColor: NSColor(hex: 0xD03B3B))

    static var areaWash: LinearGradient {
        LinearGradient(colors: [series.opacity(0.18), series.opacity(0.02)], startPoint: .top, endPoint: .bottom)
    }

    // Sequenzielle Rampe, ein Farbton: wenig -> viel (im Dunkeln von dunkel nach hell)
    private static let rampLight: [UInt32] = [0x86B6EF, 0x6DA7EC, 0x5598E7, 0x3987E5, 0x2A78D6, 0x256ABF, 0x1C5CAB, 0x184F95, 0x104281]
    private static let rampDark: [UInt32] = [0x184F95, 0x1C5CAB, 0x256ABF, 0x2A78D6, 0x3987E5, 0x5598E7, 0x6DA7EC, 0x86B6EF, 0x9EC5F4]

    static func sequential(_ fraction: Double) -> Color {
        let f = min(max(fraction, 0), 1)
        let i = Int((f * Double(rampLight.count - 1)).rounded())
        return .adaptive(rampLight[i], rampDark[i])
    }
}

enum Fmt {
    static let de = Locale(identifier: "de_DE")

    static func num(_ v: Double, _ digits: Int = 1) -> String {
        v.formatted(.number.precision(.fractionLength(digits)).locale(de))
    }

    static func int(_ v: Int) -> String { v.formatted(.number.locale(de)) }
    static func int(_ v: Double) -> String { int(Int(v.rounded())) }

    static func signed(_ v: Double, _ digits: Int = 1) -> String {
        let magnitude = num(abs(v), digits)
        if magnitude == num(0, digits) { return "±\(magnitude)" }
        return v > 0 ? "+\(magnitude)" : "−\(magnitude)"
    }

    static func minutes(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds)) s" }
        let m = Int((seconds / 60).rounded())
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }

    /// Wert + Einheit getrennt fuer grosse Zahlen: "42" "min" bzw. "1:36" "h".
    static func durationParts(_ seconds: Double) -> (String, String) {
        let m = Int((seconds / 60).rounded())
        return m >= 60 ? (String(format: "%d:%02d", m / 60, m % 60), "h") : ("\(m)", "min")
    }

    static func clock(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func day(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(de))
    }

    static func shortDay(_ d: Date) -> String {
        d.formatted(.dateTime.day().month(.abbreviated).locale(de))
    }

    static func time(_ d: Date) -> String {
        d.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(de))
    }
}

struct Card: ViewModifier {
    var padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 14, y: 6)
    }
}

extension View {
    func card(padding: CGFloat = 20) -> some View { modifier(Card(padding: padding)) }
}
