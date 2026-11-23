-- afcs_actuator.lua: turns the ESP forces into control inputs through
-- X-Plane's artificial-stability input (config actuator = artstab).
--
-- X-Plane sums stick + art stab into the flight controls (FC_roll / FC_ptch):
--   - the pilot's joystick is not overridden; the pilot overpowers ESP by
--     holding more stick, as against the real servo's limited torque;
--   - the autopilot's servo channel is untouched (ESP is zero with the AP on).
-- Measured on a light single (2026-10-27, AP off, 3000 ft): art stab written
-- without the override is ignored; with it, +0.3 roll gave about 5 deg of
-- aileron and 10 deg/s of roll, +0.2 pitch about 4 deg of nose-up elevator.
--
-- The provider is then the aircraft's only writer of the art-stab channel; an
-- .acf with its own art-stab gains loses them while this runs. With
-- actuator = none nothing here writes to the sim.

local U, cfg

local A = {}

local OVERRIDE = "sim/operation/override/override_artstab"
local ART_ROLL = "sim/joystick/artstab_roll_ratio"
local ART_PITCH = "sim/joystick/artstab_pitch_ratio"

local roll_out, pitch_out = 0, 0

function A.init(util, config)
    U, cfg = util, config
end

function A.active()
    return cfg.actuator == "artstab"
end

-- roll_force / pitch_force: -1..1 from afcs_esp_logic; dt: seconds since last
-- call; cut: true while ESP is interrupted (or failed): the output goes to 0
-- at once, not along the slew limit. When it ends the slew applies again.
function A.update(roll_force, pitch_force, dt, cut)
    if not A.active() then return end
    if cut then
        roll_out, pitch_out = 0, 0
        U.seti(OVERRIDE, 1)
        U.setf(ART_ROLL, 0)
        U.setf(ART_PITCH, 0)
        return
    end
    -- the most the output may change per second (ratio units), so ESP comes
    -- in and lets go as a ramp, never a step
    local step = cfg.actuator_slew_per_s * U.clamp(dt, 0, 0.1)
    local rf = U.clamp(roll_force, -1, 1)
    local pf = U.clamp(pitch_force, -1, 1)
    roll_out = U.approach(roll_out, rf * cfg.actuator_roll_authority, step)
    pitch_out = U.approach(pitch_out, pf * cfg.actuator_pitch_authority, step)
    U.seti(OVERRIDE, 1)
    U.setf(ART_ROLL, roll_out)
    U.setf(ART_PITCH, pitch_out)
end

-- hand the channel back (disable / stop)
function A.release()
    if not A.active() then return end
    roll_out, pitch_out = 0, 0
    U.setf(ART_ROLL, 0)
    U.setf(ART_PITCH, 0)
    U.seti(OVERRIDE, 0)
end

return A
