# AFCS port, version 2 (`laminar/afcs/`)

Status: version 2, locked 2026-11-13. Every version 1 name and meaning is
unchanged. Version 2 adds five fields, decides support field by field, and
says how an autopilot module and the fallback provider share the port. Once a
display or panel ships reading a name, that name is frozen (see Versioning).

## Why

ESP is the autopilot's function, not a display's: a display only shows it,
and a mode controller only has the button. (Example, informative and outside
the rules below: Garmin has ESP on its GFC 500 / 600 / 700 and G3X
autopilots, and the G5, GI 275 and G3X Touch displays only show it.) Version
2 adds the few facts about the autopilot itself that a display needs and
cannot read from X-Plane.

So the port names no device. One headless **provider** owns the port in an
aircraft. Any number of **consumers** (displays, mode controllers, an
aircraft's own servo model) plug into it, and none of them knows which
provider is installed. Device names may appear in an aircraft's
`config.ini`, never in the port or in a provider's code.

## Roles

| Role | Who | Writes | Reads |
|---|---|---|---|
| Provider | Exactly one per aircraft: an autopilot module, or else the fallback provider `AFCS_ESP` (ESP only) | Every port dataref except the two inputs below; registers the commands | Sim datarefs and commands; the inputs |
| Display | A PFD or MFD (e.g. G5, GI 275) | `esp_enabled`, `attitude_heartbeat` | Status and capability datarefs |
| Mode controller | A key panel or controller (e.g. G3X_AFCS, GMC 507) | `esp_enabled` (or the command) | `esp_available`, `esp_enabled`; optionally `cap_digital`, `ap_pft` |
| Actuator | The provider's own art-stab writer (default), or the aircraft's servo model | Control inputs | `esp_roll_force`, `esp_pitch_force` |

## Datarefs

All under `laminar/afcs/`. "ro" = consumers must not write it. "Since" is
the `port_version` that introduced the name.

### Presence

| Name | Type | | Since | Meaning |
|---|---|---|---|---|
| `port_version` | int | ro | 1 | The provider's version: 2 for a version 2 provider. 1 or more = a provider is live. Found but 0 = the orphan of a stopped provider = no provider. |

### ESP status (written by the provider every frame)

| Name | Type | | Since | Meaning |
|---|---|---|---|---|
| `esp_installed` | int | ro | 1 | 1 = ESP is configured in this aircraft. |
| `esp_available` | int | ro | 1 | 1 = installed and the AFCS can run it: autopilot not failed, servos not failed, autopilot powered. Displays show the ESP menu item / key only when 1. |
| `esp_enabled` | int | rw | 1 | The pilot's ESP on/off. 1 at start (provider config `esp_enabled_at_start`). Stays as set even when not available. |
| `esp_armed` | int | ro | 1 | 1 = available, enabled, autopilot off, attitude valid, height rules met. Displays show the roll-limit marks while armed. |
| `esp_engaged` | int | ro | 1 | Bitmask, 0 when not armed: 1 roll, 2 pitch, 4 overspeed, 8 underspeed. |
| `esp_roll_limit` | float | ro | 1 | Degrees, 45..60. Where the displays draw the roll-limit marks. |
| `esp_pitch_up_limit` | float | ro | 1 | Degrees nose up, 10..25. |
| `esp_pitch_down_limit` | float | ro | 1 | Degrees nose down as a positive number, 5..25. |
| `esp_roll_force` | float | ro | 1 | -1..1, + = roll right. 1 = full ESP torque. 0 unless armed and engaged, and 0 while ESP is interrupted. |
| `esp_pitch_force` | float | ro | 1 | -1..1, + = nose up. Same rules. |
| `esp_interrupted` | int | ro | 2 | 1 while ESP is interrupted by a held input (see below). Both forces are then 0; `esp_armed` and `esp_engaged` keep their values. 0 when ESP is not installed. |

### Autopilot (version 2, written by the provider)

| Name | Type | | Since | Values | Static? |
|---|---|---|---|---|---|
| `cap_digital` | int | ro | 2 | 0 / 1 | static, optional (provider config) |
| `cap_ias_mode` | int | ro | 2 | 0 / 1 | static, optional (provider config) |
| `ap_pft` | int | ro | 2 | 0 none · 1 running · 2 failed | dynamic, optional (needs the configured test time) |
| `speed_protect` | int | ro | 2 | bits: 1 = high-speed protection, 2 = low-speed protection | dynamic |

**Optional fields.** `cap_digital`, `cap_ias_mode` and `ap_pft` describe the
aircraft's autopilot, which only the aircraft's configuration knows. A
provider publishes one only when its configuration declares it (the fallback
provider's keys: `cap_digital`, `cap_ias_mode`, `pft_s`). A key that is not
declared: the dataref is not registered, and the provider logs one line saying
the field is not provided. Consumers then treat the field as unsupported (see
Versioning, rule 3) and use their own setting. A declared but invalid value is
logged and replaced by the default (`cap_digital` 1, `cap_ias_mode` 1, `pft_s`
5; `pft_s` outside 0..60 is clamped); a non-finite number (`nan`, `inf`) in any
numeric key is invalid. The fallback provider ships with all three keys
commented out: declare them only for an autopilot you can describe.

**`cap_digital`.** 1 = the aircraft's autopilot is a digital autopilot that
shares data with the displays. A display then offers no GPS steering (GPSS)
item or box, may keep an empty reserved autopilot status bar if its own
installation setting allows it, and shows an integrated autopilot on its
configuration page. 0 = the autopilot is not a digital one. It describes the
autopilot, not the provider: a provider sets it from its configuration and
never infers it from which scripts are installed.

**`cap_ias_mode`.** 1 = the autopilot has an IAS (FLC) mode that uses the
display's airspeed reference. A display shows the airspeed reference bug and
box while X-Plane's autopilot is in that mode (the display reads the mode
and the speed from X-Plane; the port carries only the capability). 0 = no
IAS mode: no airspeed bug or box. Independent of `cap_digital`.

**`ap_pft`.** The autopilot's preflight test, timed by the provider so that
every display shows the same state.
- 0 = no test running: passed, not configured, or no autopilot power.
- 1 = test running. Displays draw their "PFT" annunciation in the AP field.
- 2 = test failed. This is an annunciation only: displays draw their PFT-fail annunciation, and it stays until the next power cycle. The provider does not enforce anything: it does not stop the autopilot from engaging.
- Provider rule: a test starts at a rising edge of `sim/cockpit2/autopilot/autopilot_has_power`, on the provider's first frame if the power is already on, and again on a new flight (X-Plane message 103, and message 102 only when its param is 0). It also restarts when the provider is disabled and enabled again (`ap_pft` reads 0 while disabled). Power off: 0 at once. It lasts the configured time in sim time (`sim/time/total_running_time_sec`, the heartbeat's clock); at the end it is 2 if `sim/operation/failures/rel_otto` or `rel_auto_servos` has failed, else 0. A failed test stays 2 until the power cycles.

**`speed_protect`.** The AFCS is actively protecting the airspeed: bit
value 1 = high-speed protection (nose up; displays show their high-speed
annunciation), bit value 2 = low-speed protection (nose down; the low-speed
annunciation), with the autopilot engaged or not. Both set: displays show the
high-speed one. "Active" means the AFCS is acting, never "would act": a
provider that does not fly a protection leaves its bit 0. Displays never work
it out themselves. It keeps its value while ESP is interrupted (as `esp_armed` and `esp_engaged` do): an interrupt zeroes the forces only.
- The fallback provider reports only ESP's part: bit 1 = `esp_engaged` bit 4, bit 2 = `esp_engaged` bit 8, so it is 0 whenever the autopilot is engaged.
- Known limitation: with the autopilot engaged, X-Plane has no speed-protection dataref, so nobody reports that half until an autopilot module flies the protection itself.

### Inputs (written by consumers)

| Name | Type | | Since | Meaning |
|---|---|---|---|---|
| `attitude_heartbeat` | float | rw | 1 | A display whose attitude is valid writes `sim/time/total_running_time_sec` here every frame. The provider counts the attitude as valid while the value is at most 0.5 s old. Any number of displays may write it, in any order: the newest valid one wins, and a display with no valid attitude simply stops writing. |

The heartbeat replaces a per-device flag, so the provider never has to know
which displays exist. An aircraft with no participating display sets
`attitude_source = sim` in the fallback provider's config (attitude valid
unless the sim's AHRS has failed).

## Commands

| Name | Meaning |
|---|---|
| `laminar/afcs/esp_toggle` | ESP on/off (on press). The display menu item and the mode-controller key. |
| `laminar/afcs/esp_interrupt` | Hold: ESP pushes nothing while held (both forces 0, and the provider's own art-stab output 0 at once, not along its slew limit; when the interrupt ends the slew applies again). |

### Inputs that interrupt ESP

ESP is interrupted (`esp_interrupted` = 1, both forces 0) while any of these
is held, between its Begin and its End:
- `sim/autopilot/ap_disc_trim_interrupt` (AP DISC / TRIM INT);
- `sim/autopilot/take_off_go_around` (the Go Around button);
- `laminar/afcs/esp_interrupt`.

The provider listens to the two sim commands with "before" handlers that
always let the command through, so X-Plane still disconnects the autopilot or
runs TO/GA, and every other listener still sees the command. A consumer
never fires `esp_interrupt` on behalf of a sim command: the provider already
hears it. A sim without one of the commands is logged and skipped.

A press whose Begin and End both fall between two provider updates (a
one-frame pulse, e.g. a command fired once by a panel key) interrupts ESP for
at least the next update.

Only `take_off_go_around` and `ap_disc_trim_interrupt` are heard. The
provider does not hear `sim/autopilot/servos_off_any`, `servos_toggle` or
`autopilot_disconnect`, even when an aircraft binds its AP DISC key to one of
them; a consumer that wants those to interrupt ESP fires
`laminar/afcs/esp_interrupt` itself.

## What the provider reads from the sim

All generic sim datarefs and commands, no device datarefs:

| Use | Dataref / command |
|---|---|
| Attitude | `sim/cockpit2/gauges/indicators/roll_AHARS_deg_pilot`, `pitch_AHARS_deg_pilot` |
| Airspeed | `sim/cockpit2/gauges/indicators/airspeed_kts_pilot` |
| Height | `sim/flightmodel/position/y_agl` |
| Speed limits (when not configured) | `sim/aircraft/view/acf_Vne`, `acf_Vs` |
| Autopilot engaged | `sim/cockpit2/autopilot/servos_on` |
| Autopilot able, preflight test | `sim/cockpit2/autopilot/autopilot_has_power`, `sim/operation/failures/rel_otto`, `rel_auto_servos` |
| Time (heartbeat, preflight test) | `sim/time/total_running_time_sec` |
| AHRS failure (`attitude_source = sim`) | `sim/operation/failures/rel_g_arthorz` (the AHRS the `_AHARS_` indicators come from) |
| ESP interrupt | commands `sim/autopilot/ap_disc_trim_interrupt`, `sim/autopilot/take_off_go_around` |

## What the provider writes to the sim

Only with `actuator = artstab` (the default): `sim/operation/override/override_artstab`,
`sim/joystick/artstab_roll_ratio`, `sim/joystick/artstab_pitch_ratio`.
The provider is then the aircraft's only writer of the art-stab channel. With
`actuator = none` it writes nothing to the sim and the aircraft applies the
two force datarefs itself.

The output follows the force datarefs along a slew limit
(`actuator_slew_per_s`), so ESP comes in and lets go as a ramp. Two cases cut
it to 0 at once, with no ramp: ESP interrupted, and a failed ESP update. Each
stage of a tick (ESP, preflight test, actuator) is guarded: an error in one is
logged and does not skip the others.

## Rules

1. **One provider.** A provider claims the port by registering
   `port_version`. An autopilot module claims in `XPluginStart`; the fallback
   provider claims only on its first flight-loop callback, and only if no
   live port exists. Any provider that finds a live port stays passive, says
   so in Log.txt, and never writes the art-stab channel. An autopilot module
   that finds a live port in `XPluginStart` also logs that two autopilot
   modules are installed: that is an installation error. An autopilot module
   that finds a live port from the fallback provider (which claims only on
   its first frame, so the autopilot module claimed later than
   `XPluginStart`) has the load order wrong: it logs that and does not take
   the port over. There is no handover. A copy keeps its decision through
   `XPluginDisable` / `XPluginEnable`.
   - **No failover.** A passive copy never takes over later: if the live
     provider stops, the port has no provider until a copy is loaded again
     (an orphan `port_version` reading 0 counts as no provider).
   - A fallback copy whose registration fails, or throws half-way, in any part
     of the port (`port_version` included) goes passive: it unregisters what it
     registered, never writes the art-stab channel, and logs that it provides
     nothing. It never logs "provider of".
2. **Consumers look up lazily.** xLua scripts load alphabetically, and the
   fallback provider registers the port only on its first frame. So a
   consumer keeps looking for `port_version` (once a second is enough) and
   never caches a miss forever.
3. **No provider = no ESP.** A consumer that cannot find the port shows no
   ESP menu item, no key, no roll-limit marks. It never falls back to its
   own ESP logic.
4. **Consumers write only the two rw datarefs** and fire the two commands.
5. **"Valid attitude" means usable by the autopilot.** A display sends the
   heartbeat only while its attitude is valid and it has finished aligning.
   (Example: the G5 sends nothing during ALIGNING, decided 2026-10-29.)
6. **ESP while the autopilot is engaged.** While `sim/cockpit2/autopilot/servos_on`
   is not 0, ESP does nothing: `esp_armed` = 0, `esp_engaged` = 0, both
   forces 0. `esp_available` and `esp_enabled` keep reporting normally, so a
   display keeps its ESP menu item. Speed protection with the autopilot
   engaged belongs to `speed_protect`, never to `esp_engaged`.

## Versioning

- `port_version` goes up by one on any change to this document's names or
  meanings.
- Shipped names are never removed or renamed and never change meaning;
  changes are additions.
- A provider that writes `port_version` = N publishes every field with
  Since ≤ N, except an optional field its configuration does not declare.
  Readers accept any N at or above what they need; nobody tests `== N`.

Support is decided **per field**:

1. **Provider live** = `port_version` resolves and reads 1 or more.
2. **Field F supported** = provider live, `port_version` ≥ Since(F), and F resolves.
3. **Unsupported** means "unknown": the reader uses its own configuration for
   that feature and keeps using every other supported field. It never turns
   the whole port off because one field is missing.
4. **Supported and 0** is the provider's answer ("no"). The reader must not
   fall back to its own configuration then.
5. **Lookups.** The version 1 names a reader requires stay all-or-nothing, so
   a version 1 consumer is untouched. Version 2 names are looked up one by
   one, and again whenever the `port_version` value changes (a provider
   swapped by a script reload), at most once a second.

So a version 2 display next to a version 1 provider keeps ESP exactly as
before and takes the autopilot facts from its own configuration; a version 1
display next to a version 2 provider sees no change.

## Outside the port

- **From X-Plane, not the port:** autopilot modes and their annunciations,
  flight director, yaw damper, trim, autopilot failure and disconnect. Level
  mode is X-Plane's `sim/autopilot/return_to_level`.
- **Display installation settings, not the port:** single or dual flight
  director cue, GPS steering, the reserved status bar.
- **Not decided yet:** normal versus abnormal autopilot disconnect, the trim
  alert source, yaw damper presence.
- **Never part of the port:** names proposed before version 2 and never
  registered by any provider: `ap_installed`, `cap_status_bar`, `cap_ias_ref`,
  `cap_pft_s`, `cap_gpss_input`, `ap_label`. Do not register them.

## Not in version 2

- ESP's automatic Level mode after 10 s of engagement, and the aural alert.
- Any autopilot mode logic. Future AFCS functions get their own names under
  `laminar/afcs/` in a later version.
