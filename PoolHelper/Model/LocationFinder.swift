import CoreLocation
import Foundation

/// Asks the iPad where it is, once, so the owner doesn't have to type coordinates.
///
/// Used only from the setup screen, and only when the owner taps the button — never on
/// launch. The result is written to `PoolLocationStore` and that stored value is what
/// `SolarClock` reads from then on, so location is a one-time convenience rather than a
/// runtime dependency: revoke the permission afterwards and dawn still works.
@MainActor
final class LocationFinder: NSObject, CLLocationManagerDelegate {
    enum Failure: Error, LocalizedError {
        case denied
        case unavailable(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .denied:
                return "Location is off for this app. Enable it in Settings, or type the "
                     + "coordinates below."
            case .unavailable(let why):
                return "Couldn't get a location: \(why)"
            case .timedOut:
                return "Couldn't get a location in time. Try again, or type the coordinates."
            }
        }
    }

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<SolarClock.Coordinate, Error>?

    /// One fix, then done. Times out rather than leaving the setup screen spinning forever.
    func currentCoordinate(timeout: Duration = .seconds(20)) async throws -> SolarClock.Coordinate {
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.finish(.failure(Failure.timedOut))
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            manager.delegate = self
            // Neighbourhood accuracy is ample: a kilometre of error moves sunrise by a
            // couple of seconds. No reason to ask for anything sharper.
            manager.desiredAccuracy = kCLLocationAccuracyKilometer

            switch manager.authorizationStatus {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .denied, .restricted:
                finish(.failure(Failure.denied))
            default:
                manager.requestLocation()
            }
        }
    }

    /// Resumes exactly once; later callbacks are ignored rather than crashing on a
    /// double-resume.
    private func finish(_ result: Result<SolarClock.Coordinate, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                manager.requestLocation()
            case .denied, .restricted:
                self.finish(.failure(Failure.denied))
            case .notDetermined:
                break  // still waiting on the prompt
            @unknown default:
                break
            }
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else { return }
        let coordinate = SolarClock.Coordinate(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
        Task { @MainActor in self.finish(.success(coordinate.coarse)) }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager, didFailWithError error: Error
    ) {
        let message = error.localizedDescription
        Task { @MainActor in self.finish(.failure(Failure.unavailable(message))) }
    }
}

extension SolarClock.Coordinate {
    /// Rounded to about a kilometre before it's stored.
    ///
    /// Sunrise shifts by roughly four minutes per degree of longitude, so two decimal places
    /// is worth a couple of seconds — far finer than this needs. Keeping only that much means
    /// what sits on the iPad is "which town", not "which house".
    var coarse: SolarClock.Coordinate {
        SolarClock.Coordinate(
            latitude: (latitude * 100).rounded() / 100,
            longitude: (longitude * 100).rounded() / 100
        )
    }
}
