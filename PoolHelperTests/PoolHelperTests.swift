import Foundation
import Testing
@testable import PoolHelper

// MARK: - Response parsing

/// Payload shapes here are copied from a real `get_home` / `get_devices` response captured
/// from the RS-4 on 2026-08-11, including its quirks: absent readings arrive as empty
/// strings, and non-string values are mixed into the same array.
@Suite("Screen parsing")
struct ScreenParserTests {
    private let homeScreen: [[String: Any]] = [
        ["status": "Online"],
        ["system_type": "1"],
        ["temp_scale": "F"],
        ["spa_temp": ""],
        ["pool_temp": "89"],
        ["air_temp": "73"],
        ["pool_set_point": "95"],
        ["pool_pump": "1"],
        ["pool_heater": "0"],
        ["spa_heater": "0"],
        ["solar_heater": ""],
        ["swc_info": ["isswcPresent": true, "swcPoolValue": 50]],
        ["icl_custom_color_info": []],
        ["relay_count": "4"],
    ]

    private let devicesScreen: [[String: Any]] = [
        ["status": "Online"],
        ["group": "1"],
        ["aux_1": [["state": "0"], ["label": "Pool Light"], ["icon": "aux_7_0.png"],
                   ["type": "2"], ["subtype": "4"]]],
        ["aux_2": [["state": "0"], ["label": "Aux2"], ["type": "0"], ["subtype": "0"]]],
        ["aux_4": [["state": "1"], ["label": "Jets"], ["type": "0"], ["subtype": "0"]]],
    ]

    @Test("Flattening keeps strings and drops nested objects")
    func flatten() {
        let flat = ScreenParser.flatten(homeScreen)
        #expect(flat["pool_temp"] == "89")
        #expect(flat["temp_scale"] == "F")
        #expect(flat["swc_info"] == nil, "non-string values must not land in the flat map")
        #expect(flat["icl_custom_color_info"] == nil)
    }

    @Test("An empty reading is nil, not zero")
    func emptyReadingIsNil() {
        let flat = ScreenParser.flatten(homeScreen)
        // This matters: spa_temp is always empty on this pool-only system, and pool_temp
        // goes empty when the pump is off. Reading either as 0 would show "0°" on screen.
        #expect(ScreenParser.int(flat, "spa_temp") == nil)
        #expect(ScreenParser.int(flat, "pool_temp") == 89)
        #expect(ScreenParser.int(flat, "missing_key") == nil)
    }

    @Test("Heater state treats any non-zero as on")
    func heaterStates() {
        // "3" means enabled-but-not-currently-firing, which is still on from the guest's view.
        #expect(ScreenParser.bool(["pool_heater": "0"], "pool_heater") == false)
        #expect(ScreenParser.bool(["pool_heater": "1"], "pool_heater") == true)
        #expect(ScreenParser.bool(["pool_heater": "3"], "pool_heater") == true)
        #expect(ScreenParser.bool(["pool_heater": ""], "pool_heater") == false)
        #expect(ScreenParser.bool([:], "pool_heater") == false)
    }

    @Test("Aux circuits resolve to the right relay")
    func auxLookup() {
        let light = ScreenParser.aux(devicesScreen, .light)
        #expect(light?.label == "Pool Light")
        #expect(light?.state == 0)

        let jets = ScreenParser.aux(devicesScreen, .jets)
        #expect(jets?.label == "Jets")
        #expect(jets?.state == 1)
    }

    @Test("A missing relay resolves to nil rather than a wrong default")
    func missingAux() {
        #expect(ScreenParser.aux([["status": "Online"]], .jets) == nil)
    }
}

// MARK: - Heat deadline

@Suite("Shutoff schedule")
struct ShutoffScheduleTests {
    private func freshSchedule() -> (ShutoffSchedule, UserDefaults) {
        let defaults = UserDefaults(suiteName: "heat-tests-\(UUID().uuidString)")!
        return (.heater(defaults: defaults), defaults)
    }

    @Test("Arming stores a deadline the requested distance out")
    func arming() {
        let (schedule, _) = freshSchedule()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let deadline = schedule.arm(for: 2 * 3600, now: now)
        #expect(deadline == now.addingTimeInterval(7200))
        #expect(schedule.remaining(now: now) == 7200)
    }

    @Test("Duration is clamped to the four-hour ceiling")
    func clamping() {
        let (schedule, _) = freshSchedule()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let deadline = schedule.arm(for: 24 * 3600, now: now)
        #expect(deadline == now.addingTimeInterval(schedule.maxDuration!))
    }

    @Test("Expiry flips exactly at the deadline")
    func expiry() {
        let (schedule, _) = freshSchedule()
        let now = Date(timeIntervalSince1970: 1_000_000)
        schedule.arm(for: 3600, now: now)
        #expect(schedule.hasExpired(now: now.addingTimeInterval(3599)) == false)
        #expect(schedule.hasExpired(now: now.addingTimeInterval(3600)) == true)
    }

    @Test("No deadline never counts as expired")
    func noDeadline() {
        let (schedule, _) = freshSchedule()
        #expect(schedule.hasExpired() == false)
        #expect(schedule.remaining() == nil)
    }

    @Test("The deadline survives a relaunch")
    func survivesRelaunch() {
        // The whole point of persisting: a crash or reboot must not strand the heater on.
        let (schedule, defaults) = freshSchedule()
        let now = Date(timeIntervalSince1970: 1_000_000)
        schedule.arm(for: 3600, now: now)

        let afterRelaunch = ShutoffSchedule.heater(defaults: defaults)
        #expect(afterRelaunch.deadline == now.addingTimeInterval(3600))
    }

    @Test("Disarming clears persisted state")
    func disarm() {
        let (schedule, defaults) = freshSchedule()
        schedule.arm(for: 3600)
        schedule.disarm()
        #expect(ShutoffSchedule.heater(defaults: defaults).deadline == nil)
    }
}

// MARK: - Store behavior

@Suite("Pool store")
@MainActor
struct PoolStoreTests {
    private func makeStore(
        state: PoolState = .demo,
        deadline: Date? = nil
    ) -> (PoolStore, MockIAqualinkClient, ShutoffSchedule) {
        let client = MockIAqualinkClient(state: state)
        let defaults = UserDefaults(suiteName: "store-tests-\(UUID().uuidString)")!
        let schedule = ShutoffSchedule.heater(defaults: defaults)
        schedule.deadline = deadline
        let store = PoolStore(
            client: client,
            schedule: schedule,
            jetsSchedule: .jets(defaults: defaults),
            lightsSchedule: .lights(defaults: defaults),
            solar: SolarClock(coordinate: nil),
            credentials: .inMemory(.init(email: "a@b.com", password: "pw")),
            pollInterval: .seconds(60),
            setPointDebounce: .milliseconds(20)
        )
        return (store, client, schedule)
    }

    @Test("Turning the jets on sends exactly one toggle")
    func jetsOn() async {
        var state = PoolState.demo
        state.areJetsOn = false
        let (store, client, _) = makeStore(state: state)
        await store.refresh()

        store.startJets(for: 30 * 60)
        await store.settle()

        #expect(client.commandLog.contains("set_aux_4"))
        #expect(client.commandLog.filter { $0 == "set_aux_4" }.count == 1)
        #expect(store.state.areJetsOn == true)
        #expect(store.jetsDeadline != nil, "the jets get a shutoff like the heater")
    }

    @Test("Asking for a state the pool is already in sends nothing")
    func noRedundantToggle() async {
        // Writes are toggles, so a redundant command would turn the jets OFF — the exact
        // opposite of what was asked.
        var state = PoolState.demo
        state.areJetsOn = true
        let (store, client, _) = makeStore(state: state)
        await store.refresh()

        store.startJets(for: 30 * 60)
        await store.settle()

        #expect(client.commandLog.contains("set_aux_4") == false)
        #expect(store.state.areJetsOn == true)
    }

    @Test("The screen updates before the network answers, then rolls back on failure")
    func optimisticRollback() async {
        var state = PoolState.demo
        state.areJetsOn = false
        let (store, client, _) = makeStore(state: state)
        await store.refresh()

        client.failNextWrite()
        store.startJets(for: 30 * 60)
        #expect(store.state.areJetsOn == true, "should show immediately, before the write lands")

        await store.settle()
        #expect(store.state.areJetsOn == false, "a failed write must not leave a false reading")
        #expect(store.banner != nil)
    }

    @Test("Picking a color turns the light on without a separate toggle")
    func colorImpliesOn() async {
        var state = PoolState.demo
        state.isLightOn = false
        let (store, client, _) = makeStore(state: state)
        await store.refresh()

        store.setLightColor(LightColor.all[3])   // Caribbean Blue, index 4
        await store.settle()

        #expect(client.commandLog.contains("set_light:4"))
        #expect(client.commandLog.contains("set_aux_1") == false)
        #expect(store.state.isLightOn == true)
        #expect(store.state.lightColorIndex == 4)
    }

    @Test("The dialed temperature moves instantly and is written once")
    func temperatureDebounce() async {
        let (store, client, _) = makeStore()
        await store.refresh()
        let commandsBefore = client.commandLog.count

        store.adjustTargetTemperature(to: 90)
        store.adjustTargetTemperature(to: 91)
        store.adjustTargetTemperature(to: 92)
        #expect(store.targetTemperature == 92, "the number must track the finger, not the network")
        #expect(client.commandLog.count == commandsBefore, "no write until the tapping stops")

        try? await Task.sleep(for: .milliseconds(60))
        await store.settle()

        #expect(client.commandLog.contains("set_temps:92"))
        #expect(client.commandLog.contains("set_temps:90") == false, "intermediate steps must not be sent")
        #expect(client.commandLog.contains("set_temps:91") == false)
    }

    @Test("The dialed temperature is clamped to what the controller accepts")
    func temperatureClamping() async {
        let (store, _, _) = makeStore()
        await store.refresh()

        store.adjustTargetTemperature(to: 200)
        #expect(store.targetTemperature == PoolState.maxSetPoint)

        store.adjustTargetTemperature(to: 0)
        #expect(store.targetTemperature == PoolState.minSetPoint)
    }

    @Test("Starting heat right after adjusting sends the chosen temperature")
    func heatUsesPendingTemperature() async {
        // The guest taps "+" then immediately taps a duration. The debounced write hasn't
        // fired yet, so startHeating has to fold it in or the pool heats to the old target.
        let (store, client, _) = makeStore()
        await store.refresh()

        store.adjustTargetTemperature(to: 94)
        store.startHeating(for: 3600)
        await store.settle()

        #expect(client.state.poolSetPoint == 94)
        #expect(client.state.isHeaterOn == true)
        // temp2 carries the pool setpoint; temp1 is a separate preset that must be left alone.
        #expect(client.commandLog.contains("set_temps:94"))
    }

    @Test("Polling doesn't yank the dial out from under the guest")
    func pollingRespectsPendingEdit() async {
        let (store, client, _) = makeStore()
        await store.refresh()

        store.adjustTargetTemperature(to: 93)
        // A poll lands mid-adjustment reporting the old setpoint.
        client.state.poolSetPoint = 88
        await store.refresh()

        #expect(store.targetTemperature == 93, "the in-progress edit must survive a poll")
    }

    @Test("A failed temperature write snaps the dial back to the truth")
    func temperatureRollback() async {
        let (store, client, _) = makeStore()
        await store.refresh()
        let original = store.targetTemperature

        client.failNextWrite()
        store.adjustTargetTemperature(to: 99)
        try? await Task.sleep(for: .milliseconds(60))
        await store.settle()

        #expect(store.targetTemperature == original, "showing 99 when it's not set would lie")
    }

    @Test("Starting heat arms a persisted deadline")
    func heatArms() async {
        let (store, client, schedule) = makeStore()
        await store.refresh()

        store.adjustTargetTemperature(to: 95)   // demo water is 89, so this really heats
        store.startHeating(for: 2 * 3600)
        await store.settle()

        #expect(client.commandLog.contains("set_pool_heater"))
        #expect(schedule.deadline != nil)
        #expect(store.state.isHeaterOn == true)
    }

    @Test("Enabling the heater at or below water temperature won't produce heat")
    func heaterIdleWhenSatisfied() async {
        // Reproduces the live 2026-08-12 reading: water and setpoint both 95.
        var state = PoolState.demo
        state.poolTemp = 95
        state.poolSetPoint = 95
        let (store, client, _) = makeStore(state: state)
        await store.refresh()

        store.startHeating(for: 3600)
        await store.settle()

        #expect(client.state.isHeaterOn == true, "the controller accepts the command")
        #expect(store.state.wouldHeat(target: store.targetTemperature) == false)
    }

    @Test("A target above the water is not reported as 'already at target'")
    func heatingBelowTargetIsNotSatisfied() async {
        // The 2026-08-13 report: water 93, target 104, heater on. The card claimed the pool
        // was at target while it sat 11°F below it.
        var state = PoolState.demo
        state.poolTemp = 93
        state.poolSetPoint = 104
        state.isHeaterOn = true
        state.isPumpOn = true
        let (store, _, _) = makeStore(state: state)
        await store.refresh()

        #expect(store.targetTemperature == 104)
        #expect(store.state.wouldHeat(target: store.targetTemperature),
                "104 is above 93, so this is genuinely heating")
        #expect(store.state.isPumpOn, "and circulation is running, so no pump caveat either")
    }

    @Test("A failed stop leaves the deadline armed")
    func failedStopKeepsDeadline() async {
        // The dangerous case: if stopping fails and we've already dropped the deadline,
        // nothing is left to ever switch the heater off.
        var state = PoolState.demo
        state.isHeaterOn = true
        let (store, client, schedule) = makeStore(
            state: state, deadline: Date().addingTimeInterval(1800)
        )
        await store.refresh()

        client.failNextWrite()
        store.stopHeating()
        await store.settle()

        #expect(store.state.isHeaterOn == true, "rolled back — the heater really is still on")
        #expect(schedule.deadline != nil, "the safety net must survive a failed stop")
    }

    @Test("A failed start disarms the deadline it optimistically set")
    func failedStartDisarms() async {
        let (store, client, schedule) = makeStore()
        await store.refresh()

        client.failNextWrite()
        store.startHeating(for: 3600)
        await store.settle()

        #expect(store.state.isHeaterOn == false)
        #expect(schedule.deadline == nil)
    }

    @Test("An elapsed deadline shuts the heater off")
    func deadlineShutsOff() async {
        var state = PoolState.demo
        state.isHeaterOn = true
        let (store, client, schedule) = makeStore(
            state: state, deadline: Date().addingTimeInterval(-60)
        )
        await store.refresh()

        await store.enforceDeadlines()

        #expect(client.commandLog.contains("set_pool_heater"))
        #expect(store.state.isHeaterOn == false)
        #expect(schedule.deadline == nil)
    }

    @Test("A deadline that elapsed while the app was dead fires on the next tick")
    func deadlineSurvivesDowntime() async {
        // Simulates: guest starts a 1h heat, iPad reboots, app comes back two hours later.
        var state = PoolState.demo
        state.isHeaterOn = true
        let (store, client, _) = makeStore(
            state: state, deadline: Date().addingTimeInterval(-7200)
        )
        await store.refresh()
        await store.enforceDeadlines()

        #expect(client.state.isHeaterOn == false, "the heater must not be left running")
    }

    @Test("A live deadline is left alone")
    func liveDeadlineUntouched() async {
        var state = PoolState.demo
        state.isHeaterOn = true
        let (store, client, schedule) = makeStore(
            state: state, deadline: Date().addingTimeInterval(1800)
        )
        await store.refresh()
        await store.enforceDeadlines()

        #expect(client.commandLog.contains("set_pool_heater") == false)
        #expect(schedule.deadline != nil)
    }

    @Test("An expired session triggers a silent re-login and retry")
    func silentRelogin() async {
        let (store, client, _) = makeStore()
        client.expireNextRead()

        await store.refresh()

        #expect(store.connection == .online, "session expiry is routine, not a visible error")
        #expect(client.commandLog.filter { $0 == "login" }.count >= 1)
    }

    @Test("Missing credentials route to setup instead of an error")
    func needsSetup() async {
        let client = MockIAqualinkClient()
        let store = PoolStore(
            client: client,
            schedule: .heater(defaults: UserDefaults(suiteName: "s-\(UUID())")!),
            credentials: .inMemory(nil),
            pollInterval: .seconds(60)
        )
        await store.refresh()
        #expect(store.connection == .needsSetup)
    }
}

// MARK: - Jets and lights shut themselves off

@Suite("Automatic shutoffs")
@MainActor
struct AutoShutoffTests {
    private func makeStore(
        state: PoolState = .demo,
        coordinate: SolarClock.Coordinate? = nil
    ) -> (PoolStore, MockIAqualinkClient, ShutoffSchedule, ShutoffSchedule) {
        let client = MockIAqualinkClient(state: state)
        let defaults = UserDefaults(suiteName: "auto-\(UUID().uuidString)")!
        let jets = ShutoffSchedule.jets(defaults: defaults)
        let lights = ShutoffSchedule.lights(defaults: defaults)
        let store = PoolStore(
            client: client,
            schedule: .heater(defaults: defaults),
            jetsSchedule: jets,
            lightsSchedule: lights,
            solar: SolarClock(coordinate: coordinate),
            credentials: .inMemory(.init(email: "a@b.com", password: "pw")),
            pollInterval: .seconds(60),
            setPointDebounce: .milliseconds(20)
        )
        return (store, client, jets, lights)
    }

    // MARK: Jets

    @Test("An elapsed jets deadline shuts the pump off")
    func jetsExpire() async {
        var state = PoolState.demo
        state.areJetsOn = true
        let (store, client, jets, _) = makeStore(state: state)
        jets.deadline = Date().addingTimeInterval(-60)
        await store.refresh()

        await store.enforceDeadlines()

        #expect(client.state.areJetsOn == false)
        #expect(jets.deadline == nil)
    }

    @Test("A jets deadline that elapsed while the app was dead fires on the next tick")
    func jetsSurviveDowntime() async {
        var state = PoolState.demo
        state.areJetsOn = true
        let (store, client, jets, _) = makeStore(state: state)
        jets.deadline = Date().addingTimeInterval(-7200)
        await store.refresh()
        await store.enforceDeadlines()

        #expect(client.state.areJetsOn == false, "the pump must not be left running")
    }

    @Test("A live jets deadline is left alone")
    func jetsLiveDeadline() async {
        var state = PoolState.demo
        state.areJetsOn = true
        let (store, client, jets, _) = makeStore(state: state)
        jets.deadline = Date().addingTimeInterval(600)
        await store.refresh()
        await store.enforceDeadlines()

        #expect(client.commandLog.contains("set_aux_4") == false)
        #expect(jets.deadline != nil)
    }

    @Test("A failed jets stop keeps the deadline armed")
    func failedJetsStopKeepsDeadline() async {
        // Same hazard as the heater: dropping the deadline on a failed stop would leave the
        // pump running with nothing left to switch it off.
        var state = PoolState.demo
        state.areJetsOn = true
        let (store, client, jets, _) = makeStore(state: state)
        jets.deadline = Date().addingTimeInterval(600)
        await store.refresh()

        client.failNextWrite()
        store.stopJets()
        await store.settle()

        #expect(store.state.areJetsOn == true, "rolled back — they really are still running")
        #expect(jets.deadline != nil, "the safety net must survive a failed stop")
    }

    @Test("Jets duration is capped at two hours")
    func jetsCap() async {
        let (store, _, jets, _) = makeStore()
        store.startJets(for: 24 * 3600)
        await store.settle()

        let remaining = jets.remaining() ?? 0
        #expect(remaining <= 2 * 3600 + 1)
    }

    // MARK: Lights

    @Test("Turning the lights on arms a dawn shutoff")
    func lightsArmDawn() async {
        var state = PoolState.demo
        state.isLightOn = false
        let (store, _, _, lights) = makeStore(state: state)
        await store.refresh()

        store.setLight(on: true)
        await store.settle()

        #expect(lights.deadline != nil, "a light switched on at night must have an off time")
        #expect(store.lightsDeadline == lights.deadline)
    }

    @Test("Lights found already on get a dawn shutoff too")
    func lightsArmWhenFoundOn() async {
        // Covers the light being switched on from the official app, or the iPad restarting
        // mid-evening: the app adopts it rather than leaving it to burn until morning.
        var state = PoolState.demo
        state.isLightOn = true
        let (store, _, _, lights) = makeStore(state: state)
        await store.refresh()
        await store.enforceDeadlines()

        #expect(lights.deadline != nil)
    }

    @Test("Turning the lights off clears the dawn shutoff")
    func lightsDisarm() async {
        var state = PoolState.demo
        state.isLightOn = true
        let (store, _, _, lights) = makeStore(state: state)
        await store.refresh()
        await store.enforceDeadlines()
        #expect(lights.deadline != nil)

        store.setLight(on: false)
        await store.settle()

        #expect(lights.deadline == nil)
        #expect(store.lightsDeadline == nil)
    }

    @Test("Dawn turns the lights off")
    func lightsExpireAtDawn() async {
        var state = PoolState.demo
        state.isLightOn = true
        let (store, client, _, lights) = makeStore(state: state)
        await store.refresh()
        lights.deadline = Date().addingTimeInterval(-60)

        await store.enforceDeadlines()

        #expect(client.state.isLightOn == false)
        #expect(lights.deadline == nil)
    }

    @Test("Picking a color also arms the dawn shutoff")
    func colorArmsDawn() async {
        var state = PoolState.demo
        state.isLightOn = false
        let (store, _, _, lights) = makeStore(state: state)
        await store.refresh()

        store.setLightColor(LightColor.all[3])
        await store.settle()

        #expect(lights.deadline != nil, "a color tap turns the light on, so it needs an off time")
    }
}

// MARK: - Sunrise

@Suite("Solar clock")
struct SolarClockTests {
    /// New York City. Published sunrise times are the reference; the algorithm is good to
    /// about a minute, so a few minutes of tolerance is plenty.
    private let nyc = SolarClock.Coordinate(latitude: 40.7128, longitude: -74.0060)

    private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (y, mo, d, h, mi)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }

    @Test("Midsummer sunrise in New York")
    func summerSunrise() {
        let clock = SolarClock(coordinate: nyc)
        let rise = clock.sunrise(onDayOf: utc(2026, 6, 21, 12, 0), at: nyc)
        // 2026-06-21: about 05:25 EDT = 09:25 UTC.
        let expected = utc(2026, 6, 21, 9, 25)
        #expect(rise != nil)
        #expect(abs(rise!.timeIntervalSince(expected)) < 300, "got \(rise!)")
    }

    @Test("Midwinter sunrise in New York")
    func winterSunrise() {
        let clock = SolarClock(coordinate: nyc)
        let rise = clock.sunrise(onDayOf: utc(2026, 12, 21, 12, 0), at: nyc)
        // 2026-12-21: about 07:17 EST = 12:17 UTC. Over four hours later in the day than in
        // June, which is exactly why a hardcoded "6am" would be wrong half the year.
        let expected = utc(2026, 12, 21, 12, 17)
        #expect(rise != nil)
        #expect(abs(rise!.timeIntervalSince(expected)) < 300, "got \(rise!)")
    }

    @Test("The next dawn is always in the future")
    func nextDawnIsFuture() {
        let clock = SolarClock(coordinate: nyc)
        for hour in [0, 6, 9, 12, 18, 23] {
            let now = utc(2026, 8, 13, hour, 30)
            #expect(clock.nextDawn(after: now) > now, "hour \(hour)")
        }
    }

    @Test("Without coordinates it falls back to a fixed hour")
    func fallback() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let clock = SolarClock(coordinate: nil, fallbackHour: 6)

        let dawn = clock.nextDawn(after: utc(2026, 8, 13, 23, 0), calendar: calendar)
        #expect(dawn == utc(2026, 8, 14, 6, 0))

        let sameDay = clock.nextDawn(after: utc(2026, 8, 13, 1, 0), calendar: calendar)
        #expect(sameDay == utc(2026, 8, 13, 6, 0))
    }

    @Test("Polar night yields no sunrise rather than a wrong one")
    func polar() {
        // Longyearbyen in December: the sun does not rise at all.
        let svalbard = SolarClock.Coordinate(latitude: 78.22, longitude: 15.65)
        let clock = SolarClock(coordinate: svalbard)
        #expect(clock.sunrise(onDayOf: utc(2026, 12, 21, 12, 0), at: svalbard) == nil)
    }
}

// MARK: - Will the heater actually fire?

@Suite("Heater will fire")
struct WouldHeatTests {
    private func state(water: Int?) -> PoolState {
        var s = PoolState.demo
        s.poolTemp = water
        return s
    }

    @Test("A target above the water heats")
    func aboveWater() {
        #expect(state(water: 89).wouldHeat(target: 90))
        #expect(state(water: 89).wouldHeat(target: 104))
    }

    @Test("A target at or below the water does not heat")
    func atOrBelowWater() {
        // The live case on 2026-08-12: water 95, setpoint 95, heater reported off. Enabling
        // the heater here produces no heat, so the app must not offer to start a timer.
        #expect(state(water: 95).wouldHeat(target: 95) == false)
        #expect(state(water: 89).wouldHeat(target: 88) == false)
        #expect(state(water: 89).wouldHeat(target: 65) == false)
    }

    @Test("An unknown water reading does not block heating")
    func unknownWater() {
        // pool_temp goes empty when the pump is off; refusing to heat then would be its own bug.
        #expect(state(water: nil).wouldHeat(target: 80))
    }
}

// MARK: - Adaptive layout

@Suite("Card layout")
struct CardLayoutTests {
    @Test("Every iPad's full-screen landscape width gets the intended three columns")
    func fullScreenIsThreeColumn() {
        // Narrowest current iPad landscape is ~1024pt; widest ~1376pt.
        for width in [1024.0, 1080.0, 1194.0, 1366.0, 1376.0] {
            #expect(CardLayout.forWidth(width) == .threeColumn, "width \(width)")
        }
    }

    @Test("Half-screen Split View falls back to two columns")
    func splitViewIsTwoColumn() {
        for width in [640.0, 678.0, 750.0, 999.0] {
            #expect(CardLayout.forWidth(width) == .twoColumn, "width \(width)")
        }
    }

    @Test("Slide Over and other narrow windows stack into one scrolling column")
    func narrowIsStacked() {
        for width in [0.0, 320.0, 375.0, 507.0, 639.0] {
            #expect(CardLayout.forWidth(width) == .stacked, "width \(width)")
        }
    }

    @Test("Breakpoints are exact, with no gap between them")
    func breakpointsAreContiguous() {
        #expect(CardLayout.forWidth(999.9) == .twoColumn)
        #expect(CardLayout.forWidth(1000) == .threeColumn)
        #expect(CardLayout.forWidth(639.9) == .stacked)
        #expect(CardLayout.forWidth(640) == .twoColumn)
    }
}

// MARK: - Color table

@Suite("Light colors")
struct LightColorTests {
    @Test("Indices are contiguous from 1, since they're sent verbatim to the API")
    func indices() {
        #expect(LightColor.all.map(\.id) == Array(1...LightColor.all.count))
    }

    @Test("Every color has a swatch")
    func swatches() {
        #expect(LightColor.all.allSatisfy { !$0.swatch.isEmpty })
    }

    @Test("Lookup by index")
    func lookup() {
        #expect(LightColor.named(4)?.name == "Caribbean Blue")
        #expect(LightColor.named(nil) == nil)
        #expect(LightColor.named(99) == nil)
    }
}
