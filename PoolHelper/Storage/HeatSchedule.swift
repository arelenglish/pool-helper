import Foundation

/// Owns the heater shutoff deadline.
///
/// The API has no duration parameter, so the app is the only thing that will ever turn the
/// heater back off. The deadline is therefore written to disk the moment heating starts,
/// not held in memory: a crash, a force-quit, or an iPad reboot must not be able to strand
/// the heater on. On launch `PoolStore` reads it back and either re-arms or fires
/// immediately, depending on whether the deadline has already passed.
nonisolated struct HeatSchedule {
    /// Hard ceiling, applied regardless of what is requested.
    static let maxDuration: TimeInterval = 4 * 60 * 60

    /// What the guest can pick.
    static let presets: [TimeInterval] = [1 * 60 * 60, 2 * 60 * 60, 4 * 60 * 60]

    private static let key = "heat.deadline"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The pending shutoff, or nil when the heater is not on a timer.
    var deadline: Date? {
        get {
            let stamp = defaults.double(forKey: Self.key)
            return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        }
        nonmutating set {
            if let newValue {
                defaults.set(newValue.timeIntervalSince1970, forKey: Self.key)
            } else {
                defaults.removeObject(forKey: Self.key)
            }
        }
    }

    /// Starts the clock, clamped to `maxDuration`. Returns the stored deadline.
    @discardableResult
    func arm(for duration: TimeInterval, now: Date = Date()) -> Date {
        let clamped = min(max(duration, 0), Self.maxDuration)
        let target = now.addingTimeInterval(clamped)
        deadline = target
        return target
    }

    func disarm() { deadline = nil }

    /// True when a deadline exists and has passed — the trigger to send heater-off.
    func hasExpired(now: Date = Date()) -> Bool {
        guard let deadline else { return false }
        return now >= deadline
    }

    func remaining(now: Date = Date()) -> TimeInterval? {
        guard let deadline else { return nil }
        return max(0, deadline.timeIntervalSince(now))
    }
}
