import Foundation

/// Works out when the sun comes up, so the lights can switch themselves off at dawn.
///
/// Implements the standard sunrise equation (the NOAA/Wikipedia formulation), accurate to
/// about a minute — far better than needed here, and it costs nothing. A fixed clock time
/// would be wrong by well over an hour across the year, which is the whole reason not to
/// hardcode "6am".
///
/// Deliberately does *not* use CoreLocation. This is a wall-mounted kiosk at a fixed address:
/// asking for location permission would put a system prompt in front of guests, and Guided
/// Access is a poor place to handle one. The owner types the coordinates once instead.
nonisolated struct SolarClock: Equatable {
    struct Coordinate: Equatable, Sendable {
        var latitude: Double   // degrees north
        var longitude: Double  // degrees east; the Americas are negative
    }

    /// Nil until the owner enters coordinates, in which case `nextDawn` falls back to a fixed
    /// local hour. Getting a plausible answer out of the box matters more than precision.
    var coordinate: Coordinate?

    /// Used only when `coordinate` is nil.
    var fallbackHour: Int = 6

    /// Sun altitude counted as "up". −0.833° is the standard sunrise/sunset figure: the
    /// sun's upper limb touching the horizon, allowing for refraction.
    static let sunriseAltitude = -0.833

    /// The next dawn strictly after `date`.
    func nextDawn(after date: Date, calendar: Calendar = .current) -> Date {
        guard let coordinate else { return nextFallback(after: date, calendar: calendar) }

        // Scan a window and take the earliest sunrise still ahead of us. It starts a day back
        // because `sunrise(onDayOf:)` works in UTC days: at eastern longitudes the sunrise
        // belonging to the local day falls on the *previous* UTC day, and starting at zero
        // would skip it and answer a full day late. The window extends forward far enough to
        // cross a polar stretch where some days have no sunrise at all.
        let candidates = (-1...3).compactMap { dayOffset -> Date? in
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: date) else {
                return nil
            }
            return sunrise(onDayOf: day, at: coordinate)
        }
        if let next = candidates.filter({ $0 > date }).min() { return next }
        return nextFallback(after: date, calendar: calendar)
    }

    /// Sunrise on the calendar day containing `date`, in UTC terms, or nil when the sun does
    /// not rise that day (inside the polar circles).
    func sunrise(onDayOf date: Date, at coordinate: Coordinate) -> Date? {
        let julianDate = date.timeIntervalSince1970 / 86_400 + 2_440_587.5
        let westLongitude = -coordinate.longitude

        // Julian day count since 2000-01-01, shifted so the "day" is local solar rather than
        // UTC. Note the signs: `n` subtracts the westward offset and the mean solar time adds
        // it back. Flipping them puts solar noon on the wrong side of the globe and lands
        // sunrise ~14 hours out at this longitude — verified against published times.
        let n = (julianDate - (2_451_545.0 + 0.0009) - westLongitude / 360).rounded(.up)
        let meanSolarTime = n + 0.0009 + westLongitude / 360

        let meanAnomaly = (357.5291 + 0.98560028 * meanSolarTime)
            .truncatingRemainder(dividingBy: 360)
        let center = 1.9148 * sin(meanAnomaly.radians)
            + 0.0200 * sin((2 * meanAnomaly).radians)
            + 0.0003 * sin((3 * meanAnomaly).radians)
        let eclipticLongitude = (meanAnomaly + center + 180 + 102.9372)
            .truncatingRemainder(dividingBy: 360)

        let transit = 2_451_545.0 + meanSolarTime
            + 0.0053 * sin(meanAnomaly.radians)
            - 0.0069 * sin((2 * eclipticLongitude).radians)

        let declination = asin(sin(eclipticLongitude.radians) * sin(23.4397.radians))
        let numerator = sin(Self.sunriseAltitude.radians)
            - sin(coordinate.latitude.radians) * sin(declination)
        let denominator = cos(coordinate.latitude.radians) * cos(declination)

        let cosHourAngle = numerator / denominator
        // |cos| > 1 means midnight sun or polar night — there is no sunrise to return.
        guard cosHourAngle >= -1, cosHourAngle <= 1 else { return nil }

        let hourAngle = acos(cosHourAngle).degrees
        let julianRise = transit - hourAngle / 360

        return Date(timeIntervalSince1970: (julianRise - 2_440_587.5) * 86_400)
    }

    private func nextFallback(after date: Date, calendar: Calendar) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = fallbackHour
        components.minute = 0
        components.second = 0
        let today = calendar.date(from: components) ?? date
        if today > date { return today }
        return calendar.date(byAdding: .day, value: 1, to: today) ?? date.addingTimeInterval(86_400)
    }
}

// `nonisolated` because the project defaults to main-actor isolation, and `SolarClock` — which
// is pure arithmetic — is not. Without it every use from that struct warns.
nonisolated private extension Double {
    var radians: Double { self * .pi / 180 }
    var degrees: Double { self * 180 / .pi }
}

/// Where the pool is. Stored on the device only — it is never sent anywhere, and it is not
/// in the repository.
nonisolated enum PoolLocationStore {
    private static let latitudeKey = "pool.latitude"
    private static let longitudeKey = "pool.longitude"

    static func load(from defaults: UserDefaults = .standard) -> SolarClock.Coordinate? {
        guard defaults.object(forKey: latitudeKey) != nil,
              defaults.object(forKey: longitudeKey) != nil
        else { return nil }
        return SolarClock.Coordinate(
            latitude: defaults.double(forKey: latitudeKey),
            longitude: defaults.double(forKey: longitudeKey)
        )
    }

    static func save(_ coordinate: SolarClock.Coordinate?, to defaults: UserDefaults = .standard) {
        guard let coordinate else {
            defaults.removeObject(forKey: latitudeKey)
            defaults.removeObject(forKey: longitudeKey)
            return
        }
        defaults.set(coordinate.latitude, forKey: latitudeKey)
        defaults.set(coordinate.longitude, forKey: longitudeKey)
    }
}
