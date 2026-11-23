# AFCS_ESP

An optional xLua script for an aircraft. It provides ESP (Electronic Stability & Protection) and the `laminar/afcs/` autopilot interface, version 2, that displays and mode controllers read. The interface is described in [SPEC.md](SPEC.md). It is optional for the GMC 507. The [G5](https://github.com/X-Plane/G5) add-on is one example of a display that reads the interface.

## Install

Copy this folder to `<aircraft>/plugins/xlua/scripts/AFCS_ESP/`. Settings are in `config.ini`; each key is explained in the file. Do not run another script that writes X-Plane's artificial-stability input.

## For an aircraft with the GMC 507

Three keys in `config.ini` are shipped commented out. Remove the leading `;` and set them as follows:

| Key | Value |
|---|---|
| `cap_digital` | 1 |
| `cap_ias_mode` | 1 |
| `pft_s` | 5 |

A key that is not set is not published.

## Artificial-stability takeover

With `actuator = artstab` (the default) the script writes X-Plane's artificial-stability input every frame. It takes the channel over completely, so the art-stab gains in the aircraft's own `.acf` have no effect while it runs, and nothing else may write that input. If the aircraft needs its own art-stab, set `actuator = none`. Then the script writes nothing, and the aircraft has to apply `laminar/afcs/esp_roll_force` and `esp_pitch_force` itself.
