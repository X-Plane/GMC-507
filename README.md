# Garmin GMC 507 for X-Plane 12

The mode controller of the Garmin GFC 500 autopilot, the -01 version (twelve keys, the HDG / TRK and ALT SEL knobs and the pitch wheel), as an xLua add-on for X-Plane 12. It has no logic of its own for flying: every key, knob step and wheel step sends the matching command to X-Plane's autopilot (GFC-700 logic), and the lamps show the state X-Plane reports. It has a 3D unit you click in the cockpit and a pop-up window; both send the same `laminar/gfc500/*` commands.

Requires X-Plane 12 (tested on 12.4.4), the xLua 2 runtime in the aircraft, and an aircraft whose autopilot is set to GFC-700 in Plane Maker. A display that shows the autopilot is recommended, normally the [G5](https://github.com/X-Plane/G5) add-on.

## In this repository

| Path | What |
|---|---|
| `GMC507/` | The add-on: scripts, `config.ini`, the pop-up images |
| `GMC507/3D/` | The 3D unit: `GMC507.obj` and its textures |
| `AFCS_ESP/` | Optional: ESP and the `laminar/afcs/` autopilot interface (version 2) that displays such as the G5 read |
| `tools/gmc507_attach_acf.py` | Developer tool (Python 3) that adds the 3D unit to an aircraft's `.acf` |

## Install

1. Copy `GMC507/` to `<aircraft>/plugins/xlua/scripts/GMC507/`.
2. Attach `GMC507/3D/GMC507.obj` to the aircraft as a misc object (Plane Maker, Standard > Objects), entered as `../plugins/xlua/scripts/GMC507/3D/GMC507.obj`, and position it on the panel. `tools/gmc507_attach_acf.py --acf PATH` shows the change for the author's test aircraft without writing; add `--apply` to write it (it makes a backup first). Its offsets, the hide dataref (`sim/cockpit2/switches/custom_slider_on[22]`) and the object flags are that aircraft's: check them in Plane Maker afterwards and set your own.
3. Optional: copy `AFCS_ESP/` to `<aircraft>/plugins/xlua/scripts/AFCS_ESP/`. In an aircraft with the GMC 507, remove the leading `;` of `cap_digital`, `cap_ias_mode` and `pft_s` in `AFCS_ESP/config.ini` and set them to 1, 1 and 5. While it runs with `actuator = artstab` (the default), AFCS_ESP takes over X-Plane's artificial-stability input every frame, so art-stab gains in the aircraft's own `.acf` have no effect. If the aircraft needs them, set `actuator = none`: then nothing is written, and the aircraft has to apply `laminar/afcs/esp_roll_force` / `esp_pitch_force` itself.
4. Do not use it in an aircraft that also runs Laminar's stock GFC 500 script (`GFC500.System`): both create the same commands and datarefs.

Settings are in `GMC507/config.ini`; each key is explained in the file. A manual (PDF) will be added to this repository.

Released under the MIT License (see [LICENSE](LICENSE)).
