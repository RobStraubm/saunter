import SwiftUI
import MapKit

// MARK: - Routen

struct Waypoint: Identifiable, Equatable {
    let name: String
    let lat: Double
    let lon: Double
    /// false = reiner Formpunkt (Uferverlauf), ohne Markierung und nicht als Etappe gezaehlt
    var stage = true
    var id: String { "\(name)-\(lat)-\(lon)" }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

struct JourneyRoute: Identifiable {
    let id: String
    let name: String
    let subtitle: String
    let officialKm: Double
    let waypoints: [Waypoint]

    /// Kilometer je Wegpunkt, auf die offizielle Weglaenge skaliert (Luftlinie zwischen Etappen ist kuerzer als der Weg).
    var cumulativeKm: [Double] {
        var raw: [Double] = [0]
        for (a, b) in zip(waypoints, waypoints.dropFirst()) {
            raw.append(raw.last! + haversineKm(a.coordinate, b.coordinate))
        }
        let scale = officialKm / max(raw.last ?? 1, 0.001)
        return raw.map { $0 * scale }
    }

    static let all: [JourneyRoute] = [
        JourneyRoute(id: "bodensee", name: "Bodensee-Runde", subtitle: "Ab Konstanz einmal um den See (wie der Bodensee-Radweg)",
                     officialKm: 260, waypoints: [
            Waypoint(name: "Konstanz", lat: 47.6603, lon: 9.1758),
            Waypoint(name: "Kreuzlingen", lat: 47.6483, lon: 9.1780),
            Waypoint(name: "Bottighofen", lat: 47.6380, lon: 9.2110, stage: false),
            Waypoint(name: "Altnau", lat: 47.6105, lon: 9.2610),
            Waypoint(name: "Romanshorn", lat: 47.5655, lon: 9.3780),
            Waypoint(name: "Arbon", lat: 47.5160, lon: 9.4330),
            Waypoint(name: "Rorschach", lat: 47.4790, lon: 9.4910),
            Waypoint(name: "Altenrhein", lat: 47.4890, lon: 9.5500, stage: false),
            Waypoint(name: "Rheineck", lat: 47.4660, lon: 9.5890),
            Waypoint(name: "Hard", lat: 47.4890, lon: 9.6900),
            Waypoint(name: "Bregenz", lat: 47.5030, lon: 9.7470),
            Waypoint(name: "Lindau", lat: 47.5460, lon: 9.6840),
            Waypoint(name: "Wasserburg", lat: 47.5700, lon: 9.6310, stage: false),
            Waypoint(name: "Langenargen", lat: 47.5985, lon: 9.5420),
            Waypoint(name: "Friedrichshafen", lat: 47.6540, lon: 9.4790),
            Waypoint(name: "Immenstaad", lat: 47.6660, lon: 9.3660),
            Waypoint(name: "Hagnau", lat: 47.6770, lon: 9.3180, stage: false),
            Waypoint(name: "Meersburg", lat: 47.6935, lon: 9.2710),
            Waypoint(name: "Unteruhldingen", lat: 47.7230, lon: 9.2250),
            Waypoint(name: "Überlingen", lat: 47.7680, lon: 9.1590),
            Waypoint(name: "Sipplingen", lat: 47.7970, lon: 9.0970, stage: false),
            Waypoint(name: "Ludwigshafen", lat: 47.8180, lon: 9.0600),
            Waypoint(name: "Bodman", lat: 47.8074, lon: 9.0310),
            Waypoint(name: "Radolfzell", lat: 47.7370, lon: 8.9700),
            Waypoint(name: "Moos", lat: 47.7240, lon: 8.9360, stage: false),
            Waypoint(name: "Gaienhofen", lat: 47.6810, lon: 8.9860),
            Waypoint(name: "Stein am Rhein", lat: 47.6600, lon: 8.8590),
            Waypoint(name: "Steckborn", lat: 47.6690, lon: 8.9830),
            Waypoint(name: "Berlingen", lat: 47.6710, lon: 9.0200, stage: false),
            Waypoint(name: "Ermatingen", lat: 47.6700, lon: 9.0850),
            Waypoint(name: "Gottlieben", lat: 47.6640, lon: 9.1330),
            Waypoint(name: "Konstanz (Ziel)", lat: 47.6600, lon: 9.1750),
        ]),
        JourneyRoute(id: "tegernsee", name: "Tegernsee-Runde", subtitle: "Einmal um den See", officialKm: 20, waypoints: [
            Waypoint(name: "Gmund", lat: 47.7496, lon: 11.7364),
            Waypoint(name: "Kaltenbrunn", lat: 47.7396, lon: 11.7420),
            Waypoint(name: "Ostufer", lat: 47.7255, lon: 11.7503, stage: false),
            Waypoint(name: "Tegernsee", lat: 47.7106, lon: 11.7581),
            Waypoint(name: "Rottach-Egern", lat: 47.6923, lon: 11.7697),
            Waypoint(name: "Weißach", lat: 47.6906, lon: 11.7503),
            Waypoint(name: "Ringsee", lat: 47.6985, lon: 11.7319),
            Waypoint(name: "Bad Wiessee", lat: 47.7163, lon: 11.7198),
            Waypoint(name: "Abwinkl", lat: 47.7291, lon: 11.7178),
            Waypoint(name: "Gmund (Ziel)", lat: 47.7489, lon: 11.7372),
        ]),
        JourneyRoute(id: "e5", name: "Alpenüberquerung E5", subtitle: "Oberstdorf → Meran", officialKm: 120, waypoints: [
            Waypoint(name: "Oberstdorf", lat: 47.4097, lon: 10.2794),
            Waypoint(name: "Spielmannsau", lat: 47.3664, lon: 10.3050),
            Waypoint(name: "Kemptner Hütte", lat: 47.3350, lon: 10.3240),
            Waypoint(name: "Holzgau", lat: 47.2598, lon: 10.3427),
            Waypoint(name: "Memminger Hütte", lat: 47.2178, lon: 10.4278),
            Waypoint(name: "Zams", lat: 47.1575, lon: 10.5896),
            Waypoint(name: "Wenns", lat: 47.1657, lon: 10.7303),
            Waypoint(name: "Mittelberg", lat: 46.9690, lon: 10.8750),
            Waypoint(name: "Braunschweiger Hütte", lat: 46.9180, lon: 10.8970),
            Waypoint(name: "Vent", lat: 46.8578, lon: 10.9120),
            Waypoint(name: "Martin-Busch-Hütte", lat: 46.8250, lon: 10.8960),
            Waypoint(name: "Similaunhütte", lat: 46.7790, lon: 10.8630),
            Waypoint(name: "Vernagt", lat: 46.7340, lon: 10.8470),
            Waypoint(name: "Meran", lat: 46.6713, lon: 11.1594),
        ]),
        JourneyRoute(id: "camino", name: "Jakobsweg", subtitle: "Saint-Jean → Santiago de Compostela", officialKm: 780, waypoints: [
            Waypoint(name: "Saint-Jean-Pied-de-Port", lat: 43.1630, lon: -1.2370),
            Waypoint(name: "Roncesvalles", lat: 43.0090, lon: -1.3190),
            Waypoint(name: "Pamplona", lat: 42.8120, lon: -1.6460),
            Waypoint(name: "Puente la Reina", lat: 42.6720, lon: -1.8150),
            Waypoint(name: "Estella", lat: 42.6710, lon: -2.0320),
            Waypoint(name: "Logroño", lat: 42.4660, lon: -2.4450),
            Waypoint(name: "Nájera", lat: 42.4160, lon: -2.7330),
            Waypoint(name: "Santo Domingo de la Calzada", lat: 42.4400, lon: -2.9530),
            Waypoint(name: "Burgos", lat: 42.3440, lon: -3.6970),
            Waypoint(name: "Castrojeriz", lat: 42.2880, lon: -4.1380),
            Waypoint(name: "Frómista", lat: 42.2670, lon: -4.4060),
            Waypoint(name: "Carrión de los Condes", lat: 42.3380, lon: -4.6030),
            Waypoint(name: "Sahagún", lat: 42.3710, lon: -5.0300),
            Waypoint(name: "León", lat: 42.5980, lon: -5.5670),
            Waypoint(name: "Astorga", lat: 42.4560, lon: -6.0530),
            Waypoint(name: "Ponferrada", lat: 42.5460, lon: -6.5900),
            Waypoint(name: "Villafranca del Bierzo", lat: 42.6060, lon: -6.8110),
            Waypoint(name: "O Cebreiro", lat: 42.7080, lon: -7.0430),
            Waypoint(name: "Sarria", lat: 42.7810, lon: -7.4140),
            Waypoint(name: "Portomarín", lat: 42.8070, lon: -7.6160),
            Waypoint(name: "Palas de Rei", lat: 42.8730, lon: -7.8690),
            Waypoint(name: "Arzúa", lat: 42.9260, lon: -8.1630),
            Waypoint(name: "Santiago de Compostela", lat: 42.8800, lon: -8.5450),
        ]),
    ]
}

func haversineKm(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
    let rad = Double.pi / 180
    let dLat = (b.latitude - a.latitude) * rad
    let dLon = (b.longitude - a.longitude) * rad
    let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.latitude * rad) * cos(b.latitude * rad) * sin(dLon / 2) * sin(dLon / 2)
    return 2 * 6371 * asin(min(1, sqrt(h)))
}

// MARK: - Fortschritt

struct NextStage {
    let name: String
    let remainingKm: Double
}

struct JourneyProgress {
    let route: JourneyRoute
    let walkedKm: Double
    let fraction: Double
    let position: CLLocationCoordinate2D
    let walkedPath: [CLLocationCoordinate2D]
    let remainingPath: [CLLocationCoordinate2D]
    let stageKm: [Double]
    let nextStage: NextStage?
    /// Laenge des Weges: echter Fussweg, falls berechnet, sonst offizielle Laenge
    let lengthKm: Double
    /// true, wenn die Route als echter Fussweg vorliegt
    let followsPaths: Bool
    private let walkedCapped: Double

    var finished: Bool { fraction >= 1 }

    /// Fortschritt entlang des echten Fussweges.
    init(route: JourneyRoute, walkedKm: Double, geometry: RouteGeometry?) {
        guard let geometry, geometry.points.count >= 2 else {
            self = JourneyProgress(route: route, walkedKm: walkedKm)
            return
        }
        self.route = route
        self.walkedKm = walkedKm
        lengthKm = geometry.totalKm
        followsPaths = true
        let walked = min(max(walkedKm, 0), geometry.totalKm)
        walkedCapped = walked
        fraction = geometry.totalKm > 0 ? walked / geometry.totalKm : 0
        stageKm = geometry.stageKm

        let points = geometry.coordinates
        let cum = geometry.cumKm
        // letzter Punkt mit cum <= walked (binaere Suche)
        var lo = 0, hi = cum.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if cum[mid] <= walked { lo = mid } else { hi = mid - 1 }
        }
        let i = min(lo, points.count - 2)
        let segLen = max(cum[i + 1] - cum[i], 0.000_001)
        let t = min(max((walked - cum[i]) / segLen, 0), 1)
        let a = points[i], b = points[i + 1]
        let pos = CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                         longitude: a.longitude + (b.longitude - a.longitude) * t)
        position = pos
        walkedPath = Array(points[0...i]) + [pos]
        remainingPath = [pos] + Array(points[(i + 1)...])
        if let s = geometry.stageKm.indices.first(where: { geometry.stageKm[$0] > walked + 0.0001 && route.waypoints[$0].stage }) {
            nextStage = NextStage(name: route.waypoints[s].name, remainingKm: geometry.stageKm[s] - walked)
        } else {
            nextStage = nil
        }
    }

    func isReached(_ index: Int) -> Bool { stageKm[index] <= walkedCapped + 0.0001 }

    /// Letzte erreichte Etappe (Startort, solange noch keine erreicht ist).
    var lastReachedStage: String {
        let reached = route.waypoints.indices.filter { route.waypoints[$0].stage && isReached($0) }
        return reached.last.map { route.waypoints[$0].name } ?? route.waypoints[0].name
    }

    init(route: JourneyRoute, walkedKm: Double) {
        self.route = route
        let cum = route.cumulativeKm
        let walked = min(max(walkedKm, 0), route.officialKm)
        self.walkedKm = walkedKm
        self.walkedCapped = walked
        self.lengthKm = route.officialKm
        self.followsPaths = false
        self.fraction = route.officialKm > 0 ? walked / route.officialKm : 0
        self.stageKm = cum

        let points = route.waypoints.map(\.coordinate)
        var segment = 0
        while segment < cum.count - 2 && cum[segment + 1] <= walked { segment += 1 }
        let a = points[segment], b = points[min(segment + 1, points.count - 1)]
        let segLen = max(cum[min(segment + 1, cum.count - 1)] - cum[segment], 0.0001)
        let t = min(max((walked - cum[segment]) / segLen, 0), 1)
        let pos = CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                         longitude: a.longitude + (b.longitude - a.longitude) * t)
        position = pos
        walkedPath = Array(points[0...segment]) + [pos]
        remainingPath = [pos] + Array(points[min(segment + 1, points.count - 1)...])

        if let i = cum.indices.first(where: { cum[$0] > walked + 0.0001 && route.waypoints[$0].stage }) {
            nextStage = NextStage(name: route.waypoints[i].name, remainingKm: cum[i] - walked)
        } else {
            nextStage = nil
        }
    }
}

@MainActor
final class JourneyStore: ObservableObject {
    static let shared = JourneyStore()

    @Published var routeID: String {
        didSet { UserDefaults.standard.set(routeID, forKey: "journey.route") }
    }
    /// Nur Trainings ab diesem Zeitpunkt zaehlen fuer die Reise (0 = alle bisherigen).
    @Published var startTs: Double {
        didSet { UserDefaults.standard.set(startTs, forKey: "journey.start") }
    }

    init() {
        routeID = UserDefaults.standard.string(forKey: "journey.route") ?? "bodensee"
        startTs = UserDefaults.standard.double(forKey: "journey.start")
    }

    var route: JourneyRoute { JourneyRoute.all.first { $0.id == routeID } ?? JourneyRoute.all[0] }

    func progress(sessions: [WorkoutSession]) -> JourneyProgress {
        let km = sessions.filter { $0.start_ts >= startTs }.reduce(0) { $0 + $1.distance_km }
        return JourneyProgress(route: route, walkedKm: km, geometry: RouteGeometryStore.shared.geometries[route.id])
    }

    func select(_ id: String, countExisting: Bool) {
        routeID = id
        startTs = countExisting ? 0 : Date().timeIntervalSince1970
    }
}

// MARK: - Karte

struct JourneyView: View {
    let sessions: [WorkoutSession]
    let forecast: Forecast
    @ObservedObject var store: JourneyStore
    @ObservedObject private var routes = RouteGeometryStore.shared
    @State private var camera: MapCameraPosition = .automatic
    @State private var followMe = false

    var body: some View {
        let progress = store.progress(sessions: sessions)
        ZStack(alignment: .bottomLeading) {
            Map(position: $camera) {
                MapPolyline(coordinates: progress.remainingPath)
                    .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [1, 7]))
                MapPolyline(coordinates: progress.walkedPath)
                    .stroke(Palette.series, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                ForEach(Array(progress.route.waypoints.enumerated()).filter { $0.element.stage }, id: \.element.id) { index, wp in
                    Annotation(wp.name, coordinate: wp.coordinate, anchor: .center) {
                        StageDot(reached: progress.isReached(index), isGoal: index == progress.route.waypoints.count - 1)
                    }
                }
                Annotation("Du", coordinate: progress.position, anchor: .center) {
                    YouMarker()
                }
            }
            .mapStyle(.hybrid(elevation: .realistic, pointsOfInterest: .excludingAll))
            .mapControls {
                MapCompass()
                MapZoomStepper()
            }
            .onAppear {
                routes.ensure(store.route)
                fit(progress)
            }
            .onChange(of: store.routeID) {
                routes.ensure(store.route)
                fit(store.progress(sessions: sessions))
            }

            JourneyPanel(progress: progress, forecast: forecast, store: store) {
                withAnimation(.smooth(duration: 1.2)) {
                    camera = .camera(MapCamera(centerCoordinate: progress.position, distance: progress.lengthKm > 200 ? 60_000 : 9_000,
                                               heading: 0, pitch: 62))
                }
            } onOverview: {
                withAnimation(.smooth(duration: 1.2)) { fit(progress) }
            }
            .padding(24)
        }
    }

    /// Ganze Route im Blick, schraeg von Sueden, damit das Relief wirkt.
    private func fit(_ progress: JourneyProgress) {
        var rect = MKMapRect.null
        for wp in progress.route.waypoints {
            let p = MKMapPoint(wp.coordinate)
            rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 1, height: 1))
        }
        let center = MKMapPoint(x: rect.midX, y: rect.midY).coordinate
        let meters = max(rect.size.width, rect.size.height) * MKMetersPerMapPointAtLatitude(center.latitude)
        camera = .camera(MapCamera(centerCoordinate: center, distance: max(meters * 2.6, 5000), heading: 0, pitch: 48))
    }
}

struct StageDot: View {
    let reached: Bool
    let isGoal: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(reached ? Palette.series : Color.white)
                .frame(width: isGoal ? 20 : 14, height: isGoal ? 20 : 14)
                .overlay(Circle().strokeBorder(reached ? Color.white : Palette.series, lineWidth: 2))
            if isGoal {
                Image(systemName: "flag.fill").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(reached ? .white : Palette.series)
            } else if reached {
                Image(systemName: "checkmark").font(.system(size: 7, weight: .heavy)).foregroundStyle(.white)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
    }
}

struct YouMarker: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Palette.series.opacity(0.35))
                .frame(width: 44, height: 44)
                .scaleEffect(pulse ? 1.25 : 0.7)
                .opacity(pulse ? 0 : 1)
            Circle()
                .fill(Palette.series)
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
            Image(systemName: "figure.walk").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

struct JourneyPanel: View {
    let progress: JourneyProgress
    let forecast: Forecast
    @ObservedObject var store: JourneyStore
    let onFollow: () -> Void
    let onOverview: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(progress.route.name).font(.title3.weight(.semibold))
                            Text(progress.route.subtitle).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        routeMenu
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Fmt.num(min(progress.walkedKm, progress.lengthKm), 1))
                            .font(.system(size: 38, weight: .semibold))
                            .contentTransition(.numericText())
                        Text("von \(Fmt.num(progress.lengthKm, 0)) km").foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int((progress.fraction * 100).rounded())) %").font(.title3.weight(.semibold)).monospacedDigit()
                    }
                    Meter(progress: progress.fraction)

                    if let share = RouteGeometryStore.shared.computing[progress.route.id] {
                        HStack(spacing: 8) {
                            ProgressView(value: share).frame(width: 90)
                            Text("Fußweg wird mit Apple Karten berechnet …").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if let g = RouteGeometryStore.shared.geometries[progress.route.id] {
                        Label("Echter Fußweg · \(g.walkingSegments) von \(g.segmentCount) Abschnitten aus Apple Karten",
                              systemImage: "figure.walk.diamond")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if progress.finished {
                        Label("Ziel erreicht – wähle die nächste Reise!", systemImage: "party.popper.fill")
                            .font(.callout.weight(.semibold))
                    } else if let next = progress.nextStage {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Nächste Etappe: **\(next.name)** in \(Fmt.num(next.remainingKm, 1)) km")
                            if forecast.dailyMean > 0.01 {
                                let days = Int(ceil(next.remainingKm / forecast.dailyMean))
                                Text("Bei deinem Schnitt (\(Fmt.num(forecast.dailyMean, 2)) km/Tag) in etwa \(days) \(days == 1 ? "Tag" : "Tagen")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .font(.callout)
                    }
                }
                .padding(18)
                .frame(width: 340, alignment: .leading)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                HStack(spacing: 10) {
                    Button(action: onFollow) { Label("Zu mir", systemImage: "location.fill") }
                    Button(action: onOverview) { Label("Ganze Route", systemImage: "map") }
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        }
    }

    private var routeMenu: some View {
        Menu {
            ForEach(JourneyRoute.all) { route in
                Menu("\(route.name) (\(Fmt.num(RouteGeometryStore.shared.geometries[route.id]?.totalKm ?? route.officialKm, 0)) km)") {
                    Button("Mit allen bisherigen Kilometern") { store.select(route.id, countExisting: true) }
                    Button("Ab heute neu starten") { store.select(route.id, countExisting: false) }
                }
            }
        } label: {
            Image(systemName: "arrow.triangle.swap")
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .help("Andere Route wählen")
    }
}
