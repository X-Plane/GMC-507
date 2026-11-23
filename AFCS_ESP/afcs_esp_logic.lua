-- afcs_esp_logic.lua: Electronic Stability & Protection logic, modelled on the
-- published behaviour of a digital autopilot's ESP (2026-10-28).
--
--   arm      : available, enabled, autopilot not engaged, attitude valid,
--              above 500 ft AGL; disarm below 200 ft AGL. Without AGL height
--              data (esp_agl = 0) ESP arms on the ground too and there is no
--              low-airspeed protection
--   roll     : engages beyond esp_roll_limit (45..60), lets go 15 deg inside
--              it; minimum torque at limit - 15, maximum at limit + 15
--   pitch    : engages beyond esp_pitch_up (10..25) nose up / esp_pitch_down
--              (5..25) nose down, lets go 5 deg inside; torque from limit - 5
--              to limit + 5
--   airspeed : above esp_speed_max or below esp_speed_min (knots) pushes the
--              nose up / down. 0 = the aircraft's VNE for the maximum; for the
--              minimum VS1 x esp_speed_min_margin (default 1.1: our own rule,
--              the manual only says "minimum configured airspeed"), so the
--              nose-down push is at full strength 10 % below that. VS1 is
--              the flaps-up stall speed at 1 g wings level: in a bank the
--              stall speed is higher, so full push is not guaranteed to be
--              above the stall
--   cut-out  : beyond 75 deg bank or 50 deg pitch nothing is applied
--   interrupt: while any held input (AP DISC / TRIM INT, Go Around, the
--              port's esp_interrupt) is held, both forces are 0; armed and
--              engaged keep their values
-- Not modelled: the automatic Level mode after 10 s of ESP, the aural alert.

local U, cfg

local E = {
    enabled = true,     -- pilot's choice (laminar/afcs/esp_enabled)
    armed = false,
    roll = false, pitch_up = false, pitch_dn = false, fast = false, slow = false,
    roll_force = 0,     -- -1..1, + = roll right; |1| = maximum ESP torque
    pitch_force = 0,    -- -1..1, + = nose up
    interrupted = false, -- a held input interrupts ESP (see E.hold)
    afcs_ok = true,     -- autopilot able to run ESP (set by E.update)
}

local holds = {}        -- input name -> true while held
-- an input was pressed since the last update: a pulse whose Begin and End both
-- land between two updates is still seen by the next one
local latched = false
local warned_range = false   -- the derived-minimum warning is logged once

function E.init(util, config)
    U, cfg = util, config
    warned_range = false
    E.limits()
    E.reset()
end

-- configured limits, clamped to the ranges the manual allows
function E.limits()
    E.roll_limit = U.clamp(cfg.esp_roll_limit, 45, 60)
    E.pitch_up_limit = U.clamp(cfg.esp_pitch_up, 10, 25)
    E.pitch_down_limit = U.clamp(cfg.esp_pitch_down, 5, 25)
end

function E.installed()
    return cfg.esp ~= 0
end

-- installed and the AFCS able to run it: not with the autopilot failed, the
-- servos failed or no autopilot power
function E.available()
    return E.installed() and E.afcs_ok
end

function E.reset()
    E.enabled = (cfg.esp_enabled_at_start or 1) ~= 0
    E.armed = false
    E.roll, E.pitch_up, E.pitch_dn, E.fast, E.slow = false, false, false, false, false
    E.roll_force, E.pitch_force = 0, 0
    holds = {}
    latched = false
    E.interrupted = false
end

-- an interrupting input held (on = true) or let go; ESP stays interrupted
-- until every held input has been let go, and for at least one update after
-- the press (a one-frame pulse)
function E.hold(input, on)
    holds[input] = on or nil
    if on then latched = true end
    E.interrupted = latched or next(holds) ~= nil
end

-- nothing armed, engaged or pushing (provider disabled); the pilot's switch stays
function E.idle()
    E.armed = false
    E.roll, E.pitch_up, E.pitch_dn, E.fast, E.slow = false, false, false, false, false
    E.roll_force, E.pitch_force = 0, 0
end

-- laminar/afcs/esp_engaged: 1 roll, 2 pitch, 4 overspeed, 8 underspeed
function E.engaged_mask()
    if not E.armed then return 0 end
    return (E.roll and 1 or 0) + ((E.pitch_up or E.pitch_dn) and 2 or 0)
        + (E.fast and 4 or 0) + (E.slow and 8 or 0)
end

-- laminar/afcs/speed_protect, ESP's half only: 1 high-speed (esp_engaged
-- bit 4), 2 low-speed (bit 8); 0 when not armed, so 0 with the autopilot on
function E.speed_protect()
    if not E.armed then return 0 end
    return (E.fast and 1 or 0) + (E.slow and 2 or 0)
end

local function ramp(v, lo, hi)
    return U.clamp((v - lo) / (hi - lo), 0, 1)
end

-- D: afcs_sim snapshot; att_ok: a valid attitude source (heartbeat or sim)
function E.update(D, att_ok)
    E.limits()
    E.interrupted = latched or next(holds) ~= nil
    latched = false
    E.afcs_ok = not (D.otto_failed or D.servos_failed or D.ap_has_power == 0)
    local agl = D.agl_ft or 0
    local ap = (D.servos_on or 0) ~= 0
    local agl_data = (cfg.esp_agl or 1) ~= 0
    if not E.available() or not E.enabled or ap or not att_ok then
        E.armed = false
    elseif not agl_data then
        E.armed = true      -- no AGL height: armed regardless of height (3.5)
    elseif E.armed then
        if agl < 200 then E.armed = false end
    elseif agl > 500 then
        E.armed = true
    end

    local roll, pitch = D.roll, D.pitch
    if not E.armed or math.abs(roll) > 75 or math.abs(pitch) > 50 then
        E.roll, E.pitch_up, E.pitch_dn, E.fast, E.slow = false, false, false, false, false
        E.roll_force, E.pitch_force = 0, 0
        return
    end

    -- roll (figures 3-26 .. 3-28)
    local L, ar = E.roll_limit, math.abs(roll)
    if E.roll then
        if ar < L - 15 then E.roll = false end
    elseif ar > L then
        E.roll = true
    end
    E.roll_force = E.roll and (-U.sign(roll) * ramp(ar, L - 15, L + 15)) or 0

    -- pitch (figure 3-29)
    local up, dn = E.pitch_up_limit, E.pitch_down_limit
    if E.pitch_up then
        if pitch < up - 5 then E.pitch_up = false end
    elseif pitch > up then
        E.pitch_up = true
    end
    if E.pitch_dn then
        if pitch > -(dn - 5) then E.pitch_dn = false end
    elseif pitch < -dn then
        E.pitch_dn = true
    end
    local pf = 0
    if E.pitch_up then pf = -ramp(pitch, up - 5, up + 5) end
    if E.pitch_dn then pf = ramp(-pitch, dn - 5, dn + 5) end

    -- airspeed (3.5.3): force only while outside the band
    local vmax = (cfg.esp_speed_max > 0) and cfg.esp_speed_max or (D.vne or 0)
    local vmin = (cfg.esp_speed_min > 0) and cfg.esp_speed_min
        or (D.vs1 or 0) * (cfg.esp_speed_min_margin or 1)
    if not warned_range and cfg.esp_speed_min <= 0 and vmax > 0 and vmin > 0 and vmin >= vmax then
        warned_range = true
        U.log("derived low-speed minimum " .. vmin .. " kt (VS1 x esp_speed_min_margin) is not below the maximum "
            .. vmax .. " kt: ESP will push both ways")
    end
    E.fast = vmax > 0 and D.ias > vmax
    -- low-airspeed protection needs AGL height data (3.5 warning)
    E.slow = agl_data and vmin > 0 and D.ias < vmin
    if E.fast then pf = math.max(pf, ramp(D.ias, vmax, vmax * 1.1)) end
    if E.slow then pf = math.min(pf, -ramp(-D.ias, -vmin, -vmin * 0.9)) end
    E.pitch_force = pf

    if E.interrupted then
        E.roll_force, E.pitch_force = 0, 0
    end
end

return E
