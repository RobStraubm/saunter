import Foundation
import MapKit

/// Echter Fussweg einer Route (aus Apple-Karten-Wegbeschreibungen), einmal berechnet und gespeichert.
struct RouteGeometry: Codable {
    /// [Breite, Laenge] je Punkt
    let points: [[Double]]
    /// Kilometer entlang des Weges bis zu jedem Punkt
    let cumKm: [Double]
    /// Kilometer entlang des Weges bis zu jedem Wegpunkt der Route (gleiche Reihenfolge)
    let stageKm: [Double]
    let totalKm: Double
    let walkingSegments: Int
    let segmentCount: Int

    var coordinates: [CLLocationCoordinate2D] {
        points.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
    }
}

@MainActor
final class RouteGeometryStore: ObservableObject {
    static let shared = RouteGeometryStore()

    @Published private(set) var geometries: [String: RouteGeometry] = [:]
    /// Route-ID -> Fortschritt der Berechnung (0…1)
    @Published private(set) var computing: [String: Double] = [:]
    var onComputed: ((String, RouteGeometry) -> Void)?

    private let directory: URL

    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Saunter/Routen", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for route in JourneyRoute.all {
            if let data = try? Data(contentsOf: file(route.id)),
               let geometry = try? JSONDecoder().decode(RouteGeometry.self, from: data) {
                geometries[route.id] = geometry
            }
        }
    }

    private func file(_ id: String) -> URL { directory.appendingPathComponent("\(id).json") }

    func ensure(_ route: JourneyRoute) {
        guard geometries[route.id] == nil, computing[route.id] == nil else { return }
        computing[route.id] = 0
        Task { await compute(route) }
    }

    private func compute(_ route: JourneyRoute) async {
        appLog("Fußweg für \(route.name) wird berechnet (\(route.waypoints.count - 1) Abschnitte)")
        var points: [CLLocationCoordinate2D] = [route.waypoints[0].coordinate]
        var cum: [Double] = [0]
        var stageKm: [Double] = [0]
        var walking = 0
        let pairs = Array(zip(route.waypoints, route.waypoints.dropFirst()))

        for (i, (a, b)) in pairs.enumerated() {
            var segment = [a.coordinate, b.coordinate]
            let straight = haversineKm(a.coordinate, b.coordinate)
            if let walked = await walkingPath(from: a.coordinate, to: b.coordinate) {
                let length = zip(walked, walked.dropFirst()).reduce(0) { $0 + haversineKm($1.0, $1.1) }
                // riesige Umwege (z. B. ueber Paesse ohne kartierte Wanderwege) nicht uebernehmen
                if length <= max(straight * 2.2, straight + 3) {
                    segment = walked
                    walking += 1
                }
            }
            // Wegbeschreibungen starten/enden am naechsten Weg: Wegpunkte selbst einrahmen
            if let first = segment.first, haversineKm(points.last!, first) > 0.001 {
                cum.append(cum.last! + haversineKm(points.last!, first))
                points.append(first)
            }
            for p in segment.dropFirst() {
                cum.append(cum.last! + haversineKm(points.last!, p))
                points.append(p)
            }
            stageKm.append(cum.last!)
            computing[route.id] = Double(i + 1) / Double(pairs.count)
        }

        let geometry = RouteGeometry(points: points.map { [$0.latitude, $0.longitude] }, cumKm: cum, stageKm: stageKm,
                                     totalKm: cum.last ?? route.officialKm, walkingSegments: walking,
                                     segmentCount: pairs.count)
        geometries[route.id] = geometry
        computing[route.id] = nil
        if let data = try? JSONEncoder().encode(geometry) { try? data.write(to: file(route.id)) }
        appLog("Fußweg für \(route.name): \(Fmt.num(geometry.totalKm, 1)) km, \(walking)/\(pairs.count) Abschnitte als echte Wege")
        onComputed?(route.id, geometry)
    }

    /// Fussweg zwischen zwei Punkten; bei Drosselung durch Apple kurz warten und erneut versuchen.
    private func walkingPath(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> [CLLocationCoordinate2D]? {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: from.latitude, longitude: from.longitude), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: to.latitude, longitude: to.longitude), address: nil)
        request.transportType = .walking
        for attempt in 0..<5 {
            do {
                let response = try await MKDirections(request: request).calculate()
                guard let polyline = response.routes.first?.polyline else { return nil }
                let buffer = UnsafeBufferPointer(start: polyline.points(), count: polyline.pointCount)
                return buffer.map(\.coordinate)
            } catch let error as MKError where error.code == .loadingThrottled {
                try? await Task.sleep(for: .seconds(Double(3 << attempt)))
            } catch {
                return nil
            }
        }
        return nil
    }
}
