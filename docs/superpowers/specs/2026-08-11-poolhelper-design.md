# PoolHelper — Design

**Date:** 2026-08-11
**Status:** Approved

## Purpose

A single-screen iPad app, permanently signed in to one iAqualink account, giving guests
dead-simple control of a pool. It runs on a shared iPad locked to this app alone.

Guests can:

1. Turn the pool light on/off and pick a color.
2. Warm the pool for a chosen duration.
3. Turn the jets on/off.

Nothing else. No account UI, no settings, no navigation on the guest surface.

## Verified hardware

Discovered live on 2026-08-11 against the real account. These are facts, not assumptions.

- Controller: **Jandy AquaLink RS-4**, `system_type: 1`, `relay_count: 4`
- Pool-only — no spa. All `spa_*` fields return empty.
- `temp_scale: "F"`
- Salt chlorinator present (`swc_info`), running at 50%
- One device on the account, `device_type: "iaqua"`

Configured relays:

| Circuit | Label | type | subtype | Role |
|---|---|---|---|---|
| `aux_1` | Pool Light | 2 | 4 | color light |
| `aux_2` | Aux2 | 0 | 0 | unused |
| `aux_3` | Aux3 | 0 | 0 | unused |
| `aux_4` | Jets | 0 | 0 | on/off relay |

Heat is not an aux relay. It is `pool_heater` (on/off) plus `pool_set_point`.

A OneTouch macro `onetouch_1` = "All OFF" exists and is enabled.

### Known uncertainty: light color table

`aux_1` reports `subtype: 4`. Community API references generally map subtype 4 to Pentair
IntelliBrite and subtype 1 to Jandy Color LED. The owner identifies the fixture as **Jandy
Color LED**, so we ship the Jandy 14-color table.

Because the mapping is contested, the color table lives in one file (`LightColor.swift`) as
plain data. If on-wall behavior disagrees with the labels, correcting it is a single-array
edit with no other code change. This must be confirmed against the physical light before the
iPad goes into service.

## API

Undocumented, reverse-engineered, community-maintained. Treat as unstable.

**Auth** — `POST https://prod.zodiac-io.com/users/v1/login`
with `{api_key, email, password}` → `authentication_token`, `session_id`, `id`.

**Device list** — `GET https://r-api.iaqualink.net/devices.json`
with `api_key`, `authentication_token`, `user_id` → serial numbers.

**Control** — `GET https://p-api.iaqualink.net/v1/mobile/session.json`
with `actionID=command`, `serial`, `sessionID`, and:

| Command | Effect |
|---|---|
| `get_home` | temps, setpoints, pump/heater state |
| `get_devices` | aux circuit states and labels |
| `set_aux_1` / `set_aux_4` | **toggles** that relay |
| `set_light` + `light`, `aux`, `subtype` | sets light color index |
| `set_temps` + `temp1`/`temp2` | sets setpoint |
| `set_pool_heater` | **toggles** the heater |

### Two API traits that shape the design

**Writes are toggles, not assignments.** `set_aux_4` flips the jets; it cannot be told "off".
Every write must therefore read current state first and send the command only if the desired
state differs. A blind toggle on stale state does the opposite of what the guest asked.

**There is no duration parameter anywhere.** "Heat for 2 hours" does not exist in the API.

## Heat model

Guests choose **both** the exact temperature and how long to heat.

1. Guest dials a target temperature with − / + (65–104°F, the controller's own range).
2. Guest picks 1h / 2h / 4h.
3. App writes the setpoint and turns the heater on, in one serialized write.
4. App persists an absolute shutoff deadline to disk.
5. At the deadline, the app turns the heater off.

The temperature dial updates on screen instantly and writes to the controller ~1.2s after the
last tap. Without that debounce, holding − would queue a `set_temps` per degree against a slow
API, and the writes could land out of order. Polling is suppressed while an edit is pending so
a refresh can't yank the number out from under the guest's finger. Tapping a duration folds
any still-pending temperature into that same write, so "+ + + then 2 hours" heats to the
number on screen rather than the previous setpoint.

This makes `set_temps` a hot path rather than an owner-only call, which raises the stakes on
the `temp1`/`temp2` ambiguity noted below.

The deadline is persisted rather than held in memory so that a crash, a force-quit, or an
iPad reboot cannot strand the heater in the on state. On launch the app reads any stored
deadline: if it is in the future it re-arms the timer, if it has already passed it
immediately sends heater-off. This is the single most safety-relevant behavior in the app —
the iPad is the only thing that will ever turn the heater back off.

Guardrail: **4 hours maximum**, enforced in the app regardless of input. No setpoint cap and
no auto-off schedule for lights/jets, per owner decision.

## Architecture

Small units with one job each, so each can be tested without a pool.

- **`IAqualinkClient`** (protocol) — `login`, `devices`, `home`, `auxCircuits`,
  `setAux`, `setLightColor`, `setPoolSetPoint`, `setHeater`.
  - `LiveIAqualinkClient` — real HTTP.
  - `MockIAqualinkClient` — in-memory pool, drives previews and tests.
- **`PoolState`** — plain value type: temps, setpoint, heater, light on/color, jets.
- **`LightColor`** — the color table and its display names/swatches.
- **`CredentialStore`** — Keychain, `.whenUnlockedThisDeviceOnly`, excluded from backup.
- **`HeatSchedule`** — persisted deadline; arm, disarm, restore-on-launch.
- **`PoolStore`** — `@Observable`. Polls every 15s, applies optimistic writes, rolls back on
  failure, and resolves toggle-vs-desired-state.
- **Views** — `ContentView` hosting `LightsCard`, `HeatCard`, `JetsCard`. Plus `SetupView`,
  reachable only via a hidden long-press in a screen corner.

The template's SwiftData stack and `Item.swift` are removed; there is no relational data.

## Behavior under failure

The pool is a slow, flaky, rate-limited remote. The UI must never look broken.

- Taps apply optimistically and roll back with a brief message if the write fails.
- Session expiry (the common case, sessions are short-lived) triggers one silent re-login and
  a retry before any error is shown.
- If the network is down, cards show last-known state dimmed rather than blank or spinning.
- Heater shutoff retries on failure and is re-attempted on next launch if it never landed.

## Testing

Unit tests against `MockIAqualinkClient` and pure logic — the parts where correctness is not
visually obvious:

- `get_home` / `get_devices` parsing, including the empty-string spa fields
- toggle reconciliation: desired state vs. current state produces the right command or none
- heat deadline: arm, expire, restore across a simulated relaunch, 4h clamp
- optimistic write rollback on failure

SwiftUI views are exercised through previews on the mock, not asserted in tests.

## Kiosk deployment

- Guided Access, or Single App Mode via MDM.
- Idle timer disabled; iPad stays powered.
- No account details, email, or token ever rendered on the guest surface.

## Security

iAqualink issues no scoped or per-device credentials, so a token on this iPad is full account
access. Mitigations: Keychain with `.whenUnlockedThisDeviceOnly`, no backup, no credential UI
outside the hidden setup screen, and nothing secret in the repo or in logs.
