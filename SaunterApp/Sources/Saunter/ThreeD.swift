import SwiftUI
import Charts
import Spatial

private let heightGradient = Gradient(colors: [
    Color.adaptive(0xCDE2FB, 0x184F95), Color.adaptive(0x6DA7EC, 0x2A78D6),
    Color.adaptive(0x2A78D6, 0x6DA7EC), Color.adaptive(0x104281, 0xCDE2FB),
])

/// Wochentag x Uhrzeit als "Aktivitaetslandschaft": Gipfel = Zeiten, zu denen du gehst.
struct Landscape3DChart: View {
    let heat: [HeatCell]
    let heatMax: Double
    @State private var pose = Chart3DPose(azimuth: .degrees(-20), inclination: .degrees(32))

    /// Geglaettete Hoehenfunktion (Gauss-Kern um jede Zelle) und ihr Maximum.
    /// Montag liegt vorne (z = 6,5), Sonntag hinten (z = 0,5).
    static func surface(for heat: [HeatCell]) -> (height: @Sendable (Double, Double) -> Double, peak: Double) {
        let cells: [SIMD3<Double>] = heat.filter { $0.minutes > 0 }
            .map { SIMD3(Double($0.hour) + 0.5, Double(6 - $0.dayIndex) + 0.5, $0.minutes) }
        let height: @Sendable (Double, Double) -> Double = { hour, day in
            var sum = 0.0
            for c in cells {
                let dx = (hour - c.x) / 1.4, dz = (day - c.y) / 0.7
                sum += c.z * exp(-0.5 * (dx * dx + dz * dz))
            }
            return sum
        }
        var peak = 1.0
        for h in stride(from: 0.0, through: 24.0, by: 0.25) {
            for d in stride(from: 0.0, through: 7.0, by: 0.25) {
                peak = max(peak, height(h, d))
            }
        }
        return (height, peak)
    }

    var body: some View {
        let surface = Self.surface(for: heat)
        VStack(alignment: .leading, spacing: 6) {
            Chart3D {
                SurfacePlot(x: "Uhrzeit", y: "Minuten", z: "Wochentag", function: surface.height)
                    .foregroundStyle(.heightBased(heightGradient, yRange: 0...CGFloat(surface.peak)))
                    .roughness(0.35)
            }
            // Wertebereiche steuern die Ausdehnung der 3D-Box: breit (Uhrzeit), mittel (Tage), flach (Minuten)
            .chartXScale(domain: 0...24, range: -0.9...0.9)
            .chartZScale(domain: 0...7, range: -0.4...0.4)
            .chartYScale(domain: 0...(surface.peak * 1.08), range: -0.3...0.3)
            .chartZAxis(.hidden)
            .chartXAxisLabel("Uhrzeit")
            .chartYAxisLabel("Minuten")
            .chart3DPose($pose)
            .chart3DCameraProjection(.perspective)

            Text("Breite: Uhrzeit 0–24 Uhr · Tiefe: vorne Montag, hinten Sonntag · Höhe: aktive Minuten")
                .font(.caption)
                .foregroundStyle(Palette.muted)
        }
    }
}

/// Tempo-Verlaeufe mehrerer Trainings hintereinander als "Tempo-Gebirge".
struct SpeedRidge3DChart: View {
    let profiles: [(label: String, points: [SpeedPoint])]
    @State private var pose = Chart3DPose(azimuth: .degrees(-20), inclination: .degrees(30))

    var body: some View {
        let maxMinute = profiles.flatMap { $0.points.map(\.minute) }.max() ?? 1
        let step = max(maxMinute / 160, 1.0 / 60)
        // Raster: je Training das Tempo alle `step` Minuten (Treppen-Semantik); neuestes Training vorne
        let grid: [[Double]] = profiles.map { profile in
            stride(from: 0.0, through: maxMinute, by: step).map { profile.points.speed(at: $0) ?? 0 }
        }
        let columns = grid.first?.count ?? 1
        let rows = grid.count
        let topSpeed = max(grid.flatMap { $0 }.max() ?? 1, 1)

        VStack(alignment: .leading, spacing: 6) {
            Chart3D {
                SurfacePlot(x: "Minute", y: "km/h", z: "Training") { minute, index in
                    let col = min(max(Int((minute / step).rounded()), 0), columns - 1)
                    let r = min(max(index, 0), Double(rows - 1))
                    let r0 = Int(r.rounded(.down)), r1 = min(r0 + 1, rows - 1)
                    let t = r - Double(r0)
                    return grid[r0][col] * (1 - t) + grid[r1][col] * t
                }
                .foregroundStyle(.heightBased(heightGradient, yRange: 0...CGFloat(topSpeed)))
                .roughness(0.3)
            }
            .chartXScale(domain: 0...maxMinute, range: -0.9...0.9)
            .chartZScale(domain: 0...Double(max(rows - 1, 1)), range: -0.45...0.45)
            .chartYScale(domain: 0...(topSpeed * 1.1), range: -0.3...0.3)
            .chartZAxis(.hidden)
            .chartXAxisLabel("Minute")
            .chartYAxisLabel("km/h")
            .chart3DPose($pose)
            .chart3DCameraProjection(.perspective)

            Text("Tiefe: \(profiles.count) Trainings – hinten \(profiles.first?.label ?? ""), vorne \(profiles.last?.label ?? "")")
                .font(.caption)
                .foregroundStyle(Palette.muted)
        }
    }
}

struct ThreeDHint: View {
    var body: some View {
        Label("Zum Drehen ziehen", systemImage: "rotate.3d")
            .font(.caption)
            .foregroundStyle(Palette.muted)
    }
}
