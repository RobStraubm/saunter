import SwiftUI
import Charts
import AppKit

// MARK: - Kopf & Status

struct ConnectionPill: View {
    let status: Status?

    var body: some View {
        let (text, color): (String, Color) = {
            switch status?.phase {
            case nil: return ("Daemon aus", Palette.critical)
            case "offline": return ("Laufband nicht verbunden", Palette.muted)
            case "running": return ("Läuft", Palette.statusGood)
            case "countdown": return ("Startet", Palette.statusGood)
            case "paused": return ("Pausiert", Palette.muted)
            case "error": return ("Gerätefehler", Palette.critical)
            default: return ("Verbunden", Palette.statusGood)
            }
        }()
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.medium)).foregroundStyle(Palette.ink2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Palette.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.border))
    }
}

/// Laesst den Daemon das Laufband neu suchen; nur zeigen, solange keine Verbindung besteht.
struct ReconnectButton: View {
    @ObservedObject var model: TreadmillModel

    var body: some View {
        Button { model.reconnect() } label: {
            if model.reconnecting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Suche …")
                }
            } else {
                Label("Neu suchen", systemImage: "arrow.clockwise")
            }
        }
        .disabled(model.reconnecting)
        .help("Daemon neu starten und das Laufband neu suchen")
    }
}

struct OfflineNotice: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.critical)
            Text("Der Laufband-Daemon ist nicht erreichbar – Daten sind evtl. nicht aktuell. Details: laufband log")
                .foregroundStyle(Palette.ink2)
        }
        .font(.callout)
        .card(padding: 14)
    }
}

struct LivePill: View {
    var paused = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(paused ? Palette.muted : Palette.statusGood)
                .symbolEffect(.pulse, isActive: !paused)
            Text(paused ? "PAUSE" : "LIVE")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Palette.ink)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Palette.grid, in: Capsule())
    }
}

struct LiveBanner: View {
    let status: Status
    let session: SessionInfo

    var body: some View {
        HStack(alignment: .center, spacing: 28) {
            LivePill(paused: session.paused)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(Fmt.num(session.paused ? 0 : status.speed, 1))
                    .font(.system(size: 40, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: status.speed))
                VStack(alignment: .leading, spacing: 0) {
                    Text("km/h").foregroundStyle(Palette.ink2)
                    Text("Ziel \(Fmt.num(status.target_speed, 1))").font(.caption).foregroundStyle(Palette.muted)
                }
            }
            Divider().frame(height: 44)
            value("Zeit", Fmt.clock(session.active_s))
            value("Distanz", "\(Fmt.num(session.distance_km, 2)) km")
            value("Aktive Energie", "\(Fmt.int(session.kcal)) kcal")
            value("Schritte", Fmt.int(session.steps))
            Spacer(minLength: 0)
        }
        .animation(.snappy, value: status.speed)
        .card(padding: 18)
    }

    private func value(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(Palette.ink2)
        }
    }
}

// MARK: - Bausteine

struct CardTitle: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline).foregroundStyle(Palette.ink)
            if let subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(Palette.ink2)
            }
        }
    }
}

struct DeltaLabel: View {
    let delta: Double
    let text: String
    var context: String = ""

    var body: some View {
        let up = delta > 0.0005
        let down = delta < -0.0005
        HStack(spacing: 4) {
            Image(systemName: up ? "arrow.up.right" : down ? "arrow.down.right" : "arrow.right")
                .font(.caption2.weight(.bold))
            Text(text).fontWeight(.semibold)
            if !context.isEmpty {
                Text(context).foregroundStyle(Palette.muted)
            }
        }
        .font(.caption)
        .foregroundStyle(up ? Palette.good : Palette.ink2)
        .lineLimit(1)
    }
}

struct LegendKey: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 14, height: 3)
            Text(label).font(.caption).foregroundStyle(Palette.ink2)
        }
    }
}

struct EndDot: View {
    var color: Color = Palette.series

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .padding(2)
            .background(Circle().fill(Palette.surface))
    }
}

struct TipRow: Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

struct ChartTooltip: View {
    let title: String
    let rows: [TipRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Palette.ink)
            ForEach(rows) { row in
                HStack(spacing: 14) {
                    Text(row.label).foregroundStyle(Palette.ink2)
                    Spacer(minLength: 0)
                    Text(row.value).monospacedDigit().foregroundStyle(Palette.ink)
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.border))
        .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
        .fixedSize()
    }
}

struct StatTile: View {
    let label: String
    let value: String
    var unit: String?
    var delta: Double?
    var deltaText: String = ""
    var footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.subheadline).foregroundStyle(Palette.ink2)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit).font(.callout.weight(.medium)).foregroundStyle(Palette.ink2)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            if let delta {
                DeltaLabel(delta: delta, text: deltaText)
            } else if let footnote {
                Text(footnote).font(.caption).foregroundStyle(Palette.muted)
            }
        }
        .card(padding: 16)
    }
}

struct Meter: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.seriesTrack)
                Capsule().fill(Palette.series)
                    .frame(width: progress > 0 ? max(10, geo.size.width * progress) : 0)
            }
        }
        .frame(height: 10)
        .animation(.smooth, value: progress)
    }
}

extension View {
    /// Hover statt Klick fuer Tooltips: liefert die Zeigerposition relativ zur Plotflaeche.
    func chartHover(_ handler: @escaping (ChartProxy, CGPoint?) -> Void) -> some View {
        chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let location) = phase, let anchor = proxy.plotFrame else {
                            handler(proxy, nil)
                            return
                        }
                        let frame = geo[anchor]
                        guard frame.contains(location) else {
                            handler(proxy, nil)
                            return
                        }
                        handler(proxy, CGPoint(x: location.x - frame.minX, y: location.y - frame.minY))
                    }
            }
        }
    }
}

func valueAxis(digits: Int = 1, suffix: String = "") -> some AxisContent {
    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
        AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
            .foregroundStyle(Palette.grid)
        AxisValueLabel {
            if let v = value.as(Double.self) {
                Text(Fmt.num(v, digits) + suffix)
            }
        }
        .font(.caption2)
        .foregroundStyle(Palette.muted)
    }
}
