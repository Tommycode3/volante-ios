import CoreLocation
import CoreMotion
import Observation

/// How you drive, and what happened if something happens.
///
/// Two things in the same place because they use the same data. The coach is
/// for fuel consumption: on a Micra a smoother style is easily 10-15% of
/// fuel, and feedback given in one sentence at the end of the trip is the
/// right form. The black box is for the bad day: on violent braking it
/// freezes the preceding minute — speed, decelerations, position — which is
/// exactly what an insurer needs, or what you need to dispute an account of
/// events.
struct DriveEvent: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case brake, accel, turn, severe

        var label: String {
            switch self {
            case .brake: return "frenata brusca"
            case .accel: return "accelerata brusca"
            case .turn: return "curva presa forte"
            case .severe: return "evento violento"
            }
        }
        var penalty: Int {
            switch self {
            case .brake: return 4
            case .accel: return 3
            case .turn: return 2
            case .severe: return 20
            }
        }
    }

    var id = UUID()
    var at = Date()
    var kind: Kind
    var g: Double
    var speedKmh: Double
    var lat: Double?
    var lon: Double?
    /// The minute before, frozen: only for violent events.
    var blackBox: [Sample]?
}

/// One sample per second: light to keep, enough to read later.
struct Sample: Codable, Hashable {
    var t: Date
    var speedKmh: Double
    var g: Double
    var lat: Double?
    var lon: Double?
}

struct Trip: Codable, Identifiable, Hashable {
    var id = UUID()
    var start = Date()
    var end: Date?
    var distanceKm: Double = 0
    var maxSpeedKmh: Double = 0
    var events: [DriveEvent] = []

    var minutes: Int {
        Int(((end ?? Date()).timeIntervalSince(start)) / 60)
    }

    /// A hundred minus what it cost. Not a report card: a number that moves, to
    /// see whether you're changing habits.
    var score: Int {
        max(0, 100 - events.reduce(0) { $0 + $1.kind.penalty })
    }

    func count(_ kind: DriveEvent.Kind) -> Int {
        events.filter { $0.kind == kind }.count
    }

    var hasBlackBox: Bool { events.contains { $0.blackBox != nil } }

    /// Meant to be read aloud on arrival, not looked at.
    var spoken: String {
        var out = "\(minutes) minuti"
        if distanceKm >= 1 { out += ", \(Int(distanceKm)) chilometri" }
        let brakes = count(.brake), accels = count(.accel)
        if brakes == 0 && accels == 0 {
            out += ". Guida pulita, nessuna frenata brusca"
        } else {
            var bits: [String] = []
            if brakes > 0 { bits.append("\(brakes) frenate brusche") }
            if accels > 0 { bits.append("\(accels) accelerate brusche") }
            out += ". " + bits.joined(separator: " e ")
        }
        out += ". Punteggio \(score) su cento"
        // Consumption is the reason this actually matters.
        let waste = min(18, (brakes * 2 + accels * 2))
        if waste >= 4 {
            out += ", e uno stile più fluido varrebbe circa il \(waste) per cento di carburante"
        }
        return out + "."
    }
}

@MainActor
@Observable
final class TripRecorder: NSObject {

    private(set) var current: Trip?
    private(set) var trips: [Trip] = []
    private(set) var speedKmh: Double = 0
    private(set) var authorized = false

    var diagnostics: Diagnostics?
    /// Called when the trip ends: it's the moment for the spoken summary.
    var onTripEnded: ((Trip) -> Void)?
    var enabled = true

    // Thresholds in g. Normal braking stays below 0.25; above 0.6 it's an event
    // worth freezing.
    private let brakeG = 0.32
    private let accelG = 0.30
    private let turnG = 0.34
    private let severeG = 0.60

    @ObservationIgnored private let locations = CLLocationManager()
    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private var ring: [Sample] = []
    @ObservationIgnored private var lastLocation: CLLocation?
    @ObservationIgnored private var lastEventAt = Date.distantPast
    @ObservationIgnored private var slowSince: Date?
    @ObservationIgnored private var peakG: Double = 0
    @ObservationIgnored private var sampleTimer: Timer?

    private var fileURL: URL { Paths.documents.appendingPathComponent("viaggi.json") }

    override init() {
        super.init()
        load()
        locations.delegate = self
        locations.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        locations.activityType = .automotiveNavigation
        locations.pausesLocationUpdatesAutomatically = false
    }

    // MARK: - Startup

    func start() {
        guard enabled else { return }
        switch locations.authorizationStatus {
        case .notDetermined:
            locations.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            authorized = true
            beginUpdates()
        default:
            diagnostics?.log("viaggio", "posizione negata: niente coach né scatola nera")
        }
    }

    private func beginUpdates() {
        // Needed even with Maps in front, which is the normal case.
        locations.allowsBackgroundLocationUpdates = true
        locations.startUpdatingLocation()

        if motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive {
            motion.deviceMotionUpdateInterval = 0.1
            motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
                guard let self, let d = data else { return }
                MainActor.assumeIsolated { self.consume(d) }
            }
        }
        sampleTimer?.invalidate()
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        diagnostics?.log("viaggio", "sensori di viaggio attivi")
    }

    func stop() {
        locations.stopUpdatingLocation()
        motion.stopDeviceMotionUpdates()
        sampleTimer?.invalidate(); sampleTimer = nil
        endTrip()
    }

    // MARK: - Motion

    private func consume(_ d: CMDeviceMotion) {
        let a = d.userAcceleration
        let g = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
        peakG = max(peakG, g)

        // Below 15 km/h a peak is a parking manoeuvre, not a driving style.
        guard current != nil, speedKmh > 15 else { return }
        guard Date().timeIntervalSince(lastEventAt) > 2 else { return }   // one event at a time

        let kind: DriveEvent.Kind?
        if g >= severeG { kind = .severe }
        else if abs(a.y) >= brakeG && a.y < 0 { kind = .brake }
        else if abs(a.y) >= accelG && a.y > 0 { kind = .accel }
        else if abs(a.x) >= turnG { kind = .turn }
        else { kind = nil }

        guard let kind else { return }
        record(kind, g: g)
    }

    private func record(_ kind: DriveEvent.Kind, g: Double) {
        lastEventAt = Date()
        var event = DriveEvent(kind: kind, g: g, speedKmh: speedKmh,
                               lat: lastLocation?.coordinate.latitude,
                               lon: lastLocation?.coordinate.longitude)
        if kind == .severe {
            // The black box: the preceding minute, frozen.
            event.blackBox = ring
            diagnostics?.log("viaggio", String(format: "EVENTO VIOLENTO %.2f g a %.0f km/h — minuto precedente salvato", g, speedKmh))
        } else {
            diagnostics?.log("viaggio", String(format: "%@ %.2f g", kind.label, g))
        }
        current?.events.append(event)
        save()
    }

    private func sample() {
        let s = Sample(t: Date(), speedKmh: speedKmh, g: peakG,
                       lat: lastLocation?.coordinate.latitude,
                       lon: lastLocation?.coordinate.longitude)
        peakG = 0
        ring.append(s)
        if ring.count > 90 { ring.removeFirst(ring.count - 90) }   // a minute and a half
    }

    // MARK: - Trip

    private func updateTrip(with location: CLLocation) {
        let kmh = max(0, location.speed) * 3.6
        speedKmh = kmh

        if current == nil {
            if kmh > 15 {
                current = Trip()
                ring.removeAll()
                diagnostics?.log("viaggio", "iniziato")
            }
        } else {
            if let last = lastLocation {
                let step = location.distance(from: last) / 1000
                if step < 1 { current?.distanceKm += step }      // discard GPS jumps
            }
            current?.maxSpeedKmh = max(current?.maxSpeedKmh ?? 0, kmh)

            if kmh < 5 {
                if slowSince == nil { slowSince = Date() }
                if Date().timeIntervalSince(slowSince ?? Date()) > 180 { endTrip() }
            } else {
                slowSince = nil
            }
        }
        lastLocation = location
    }

    private func endTrip() {
        guard var trip = current else { return }
        trip.end = Date()
        current = nil
        slowSince = nil
        guard trip.minutes >= 2 else { return }        // parking movements, no
        trips.insert(trip, at: 0)
        if trips.count > 300 { trips.removeLast() }
        save()
        diagnostics?.log("viaggio", "concluso: \(trip.spoken)")
        onTripEnded?(trip)
    }

    // MARK: - Persistence

    private func load() {
        guard let d = try? Data(contentsOf: fileURL),
              let t = try? JSONDecoder().decode([Trip].self, from: d) else { return }
        trips = t
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(trips) { try? d.write(to: fileURL) }
    }

    func delete(_ trip: Trip) {
        trips.removeAll { $0.id == trip.id }
        save()
    }

    /// For bookkeeping: the month's kilometres, which would otherwise be reconstructed from memory.
    func kilometers(inLast days: Int) -> Double {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        return trips.filter { $0.start > cutoff }.reduce(0) { $0 + $1.distanceKm }
    }

    var recentAverage: Int? {
        let last = trips.prefix(10)
        guard last.count > 1 else { return nil }
        return last.reduce(0) { $0 + $1.score } / last.count
    }
}

extension TripRecorder: CLLocationManagerDelegate {
    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let last = locs.last else { return }
        Task { @MainActor in self.updateTrip(with: last) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let status = m.authorizationStatus
        Task { @MainActor in
            let ok = status == .authorizedWhenInUse || status == .authorizedAlways
            self.authorized = ok
            if ok { self.beginUpdates() }
        }
    }
}
