# PoolHelper

A single-screen iPad app for guests to control one pool: lights and their color, jets, and a
timed heat boost. Built for a shared iPad locked to this app alone.

Everything switches itself off. The heater and jets run for a chosen duration; the lights go
off at dawn. Nothing a guest turns on can be left running indefinitely.

Hardware it was written against: **Jandy AquaLink RS-4** driving a 6x10 plunge pool — a
soaker, effectively a large hot tub, so setpoints run up to 104°F. `aux_1` is the color
light, `aux_4` is the jets. See
[the design spec](docs/superpowers/specs/2026-08-11-poolhelper-design.md) for the full
discovery notes and the API reference.

## Entering credentials

**Nothing is compiled into the app and nothing lives in this repo.** You sign in once, on the
iPad, and the credentials go into that device's Keychain with
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — excluded from backups and iCloud, so they
cannot leave the device they were typed on.

To reach the sign-in screen: **press and hold the top-left corner of the screen for three
seconds.** There is no button, no menu, and no other path to it, so a guest will not find it.
The same screen signs out and sets the pool's coordinates (see [dawn](#lights-off-at-dawn)).

Be aware of what a signed-in device is: iAqualink issues no scoped or per-device tokens, so
anything logged in can do everything the account can. On a shared iPad that is the main risk,
and it's why the Keychain item is `ThisDeviceOnly` and nothing in the guest UI mentions the
account. Treat the iPad itself as the credential.

## Running it

```bash
open PoolHelper.xcodeproj
```

Drive the whole interface from an in-memory pool — no credentials, no live controller, nothing
leaves the machine:

```bash
xcodebuild build -scheme PoolHelper \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)'
xcrun simctl launch booted cc.flyway.PoolHelper -demo
```

Tests (the unit target; the UI-test target is an unused Xcode stub):

```bash
xcodebuild test -scheme PoolHelper \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:PoolHelperTests
```

Note that `xcodebuild`'s plain-text `Test case ... passed` lines are an unreliable view of a
Swift Testing run — `-only-testing` on a single test prints no per-test line at all while
still reporting `** TEST SUCCEEDED **`. Read the result bundle instead if you wire this into
CI:

```bash
xcodebuild test ... -resultBundlePath out.xcresult
xcrun xcresulttool get test-results tests --path out.xcresult --format json
```

## Kiosk setup

iPad only (`UIDeviceFamily = [2]`), landscape only.

1. Settings → Accessibility → Guided Access → on, set a passcode.
2. Launch PoolHelper, triple-click the side button, start Guided Access.
   (For several iPads, use Single App Mode via MDM instead.)
3. Leave the iPad on power. The app disables the idle timer so guests never find a black screen.

**The interface is always landscape, however the iPad is held.** Counter-intuitively this
required *allowing* every orientation: a landscape-only app on a portrait iPad doesn't rotate
under iPadOS 26, it gets a landscape-shaped window letterboxed into a portrait screen — black
bars top and bottom, with the cards squeezed and clipped. So the app accepts all orientations
and rotates itself, in [`ForcedLandscape`](PoolHelper/Views/PoolTheme.swift). SwiftUI rotates
hit-testing along with the view, so touches stay correct.

**Guided Access is what keeps this full screen — not a plist key.** `UIRequiresFullScreen` is
deprecated as of iOS 26 and will be ignored, so it was removed rather than relied on. iPadOS
can therefore hand the app a Split View or Slide Over window if Guided Access isn't running,
and the layout degrades on purpose instead of breaking:

| Width | Layout |
|---|---|
| ≥ 1000pt (any iPad, full-screen landscape) | Lights │ Heat │ Jets |
| ≥ 640pt (about half-screen) | Lights │ Heat over Jets |
| below that (Slide Over) | one scrolling column |

The breakpoints are in [`CardLayout.swift`](PoolHelper/Views/CardLayout.swift) and are unit
tested against real iPad widths.

## Still to confirm on-site

**The light color names.** `aux_1` reports `subtype: 4`. Community references usually map
subtype 4 to Pentair IntelliBrite, but this fixture was identified as a Jandy Color LED, so
the Jandy 14-color table ships. Tap through a few colors and check the names match the water.
If they don't, replace the table in
[`LightColor.swift`](PoolHelper/Model/LightColor.swift) — the indices are what the API
consumes, and nothing else depends on the names.

### Resolved: the setpoint parameter

**Confirmed 2026-08-13.** `set_temps` carries `temp1` and
`temp2`, which are two presets for the same body of water — and the controller does not allow
them to hold the same value. Confirmed live by sending `temp1` alone: `spa_set_point` moved
104 → 95 while `pool_set_point` stayed at 104.

```
temp1 -> spa_set_point   (second preset — leave alone)
temp2 -> pool_set_point  (what the system heats to)
```

[`LiveIAqualinkClient`](PoolHelper/Network/LiveIAqualinkClient.swift) sends **`temp2` only**.
An earlier version wrote both slots to the same value, which silently destroyed the other
preset on every guest temperature change.

## How the automatic shutoffs work

**The heater only produces heat when the target is above the current water temperature.** The
controller will happily accept "heater on" with a satisfied thermostat and simply do nothing
— which looks exactly like a broken heater. The app therefore disables the duration buttons
and says "Already 95° — tap + to warm it further" rather than starting a timer that can't
work.

The status line only ever states things the app can check: the setpoint against the water,
and whether the pump is running. It deliberately does **not** try to interpret the raw
`pool_heater` value beyond off/on. An earlier version guessed that `3` meant "burner firing"
and `1` meant "idle", and so reported "pool is at target" while the water sat 11°F below it.
Observed on 2026-08-13: `pool_heater = 1` with the water climbing 93 → 95, i.e. `1` is
heating. Don't narrate the controller's internals; report the numbers.

### Heat

Guests set the exact temperature with − / + (65–104°F, the controller's own limits) and then
pick how long to run. The dial moves instantly and writes to the controller about a second
after the last tap, so holding − doesn't fire a request per degree; tapping a duration folds
any pending temperature into the same write.

The iAqualink API has **no duration parameter**. "Heat for 2 hours" is entirely the app's
doing: it turns the heater on and writes a shutoff deadline to disk.

That makes this iPad the only thing that will ever turn the heater back off. The design
follows from that:

- The deadline is persisted, not held in memory, so a crash or reboot can't strand the heater.
- On launch, a deadline that already passed fires immediately.
- A failed shutoff keeps the deadline armed and retries on the next poll.
- Stopping heat disarms the timer only *after* the controller confirms the heater is off.
- Duration is capped at four hours no matter what is requested.

### Jets

The same mechanism, in minutes rather than hours: 15 / 30 / 60, capped at two. Nobody sits in
a plunge pool for four hours, and a pump left running overnight is noise and wear for nothing.
Every property above applies identically — including that a *failed* stop keeps the deadline
armed, so the pump still gets switched off on a later tick.

### Lights off at dawn

Lights aren't a duration — nobody sets a timer for "until it's light out", and a light left on
overnight is the one that actually gets forgotten. So the shutoff is an absolute time: the
next sunrise.

That is computed with the standard sunrise equation in
[`SolarClock`](PoolHelper/Model/SolarClock.swift), accurate to about a minute and unit-tested
against published times for New York in midsummer, midwinter and at the equinox. A hardcoded
"6am" would be over an hour wrong for much of the year — in New York, sunrise moves more than
four hours between June and December.

It needs the pool's coordinates, entered once on the setup screen. **No location permission is
requested and CoreLocation isn't used**: this is a wall-mounted kiosk at a fixed address, and a
system permission prompt is a poor thing to put in front of guests or to handle inside Guided
Access. The coordinates stay on the device and are not in this repository. Left blank, the
lights simply go off at 6am.

The deadline is armed whenever the app sees the lights on without one — which covers them being
switched on from the official app, or the iPad restarting mid-evening — so a light is adopted
rather than left to burn until morning.

## Type and sizing

This screen is read standing up, from a few feet away, by people who have never seen it and
may be wet. The scale in [`PoolTheme.swift`](PoolHelper/Views/PoolTheme.swift) is a step above
on-device defaults and **nothing is smaller than 15pt**. The colour swatches carry no captions
at all — fourteen 11pt names were unreadable at that distance and crowded the grid, so the
selected colour's name appears once, at 23pt, in the toggle.

An iPad mini in landscape is only 744pt tall, which is what the Heat card is sized against:
it offers a roomy layout and a tighter one via `ViewThatFits` and takes whichever fits, rather
than shrinking the type on every device to satisfy the smallest one. Verified with nothing
clipped on both iPad mini and 13", in both physical orientations.

## Layout

```
PoolHelper/
  Model/       PoolState, LightColor, AuxCircuit — plain values
  Network/     IAqualinkClient protocol, live HTTP client, in-memory mock
  Storage/     Keychain credentials, persisted heat deadline
  PoolStore    observable state: polling, optimistic writes, toggle reconciliation
  Views/       ContentView + Lights / Heat / Jets cards + hidden setup screen
```

The API is undocumented and reverse-engineered; it is confined to `LiveIAqualinkClient` so an
upstream change is a one-file fix.

## If you're adapting this to your own pool

Two things are specific to this installation and will differ on yours:

- **Which relay is what.** `aux_1` is the light and `aux_4` the jets here; iAqualink names
  these per-installation. Query `get_devices` and read the labels before changing
  [`AuxCircuit`](PoolHelper/Model/PoolState.swift).
- **The light's colour table.** `aux_1` reports `subtype: 4`. Community references usually map
  subtype 4 to Pentair IntelliBrite, but this fixture is a Jandy Color LED, so the Jandy table
  ships. The indices are what the API consumes; the names and swatches in
  [`LightColor.swift`](PoolHelper/Model/LightColor.swift) are cosmetic and easy to replace.

Also worth knowing before you trust it: **writes are toggles, not assignments.** `set_aux_4`
flips the jets — it cannot be told "off". Every write has to reconcile against current state
first, or a tap on stale state does the opposite of what was asked.

## Disclaimer

This is an unofficial, independent project. It is not affiliated with, endorsed by, or
supported by Zodiac Pool Systems, Fluidra, or Jandy, and "iAqualink", "Jandy" and "AquaLink"
are their trademarks. The API it speaks is undocumented and community-reverse-engineered; it
can change or break without notice, and using it may not be consistent with the vendor's terms
of service — that's your call to make.

It controls real equipment — a heater, a pump, pool lights. Read [how heat works](#how-heat-works-and-why-it-matters)
before running it unattended, and satisfy yourself that the safety behaviour is adequate for
your installation. Provided as-is, with no warranty; see [LICENSE](LICENSE).

## License

[MIT](LICENSE).
