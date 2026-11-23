-- gmc507_logic.lua: pure logic of the GMC 507 (no XPLM calls; everything goes
-- through the `api` table, so the headless tests can drive it).
--   api.geti(name) / api.getf(name)   0 when the dataref does not exist
--   api.seti(name, v) / api.setf(name, v)
--   api.has(name)                     true when the dataref exists now
--   api.fire(command_name)            one-shot a command (misses are not cached)
--   api.now()                         sim seconds
--   api.log(msg)
-- Design: docs/gmc507_xp_mapping.md (M); numbers like L2 / L13 are its patches.
-- Where M section 4.3 (probe results 2026-11-12) overrides an earlier row, the
-- 4.3 result is what is coded here.

local Logic = {}

local AP = "sim/cockpit2/autopilot/"
local SA = "sim/autopilot/"
local YD_SWITCH = "sim/cockpit2/switches/yaw_damper_on"
local IAS_PILOT = "sim/cockpit2/gauges/indicators/airspeed_kts_pilot"
-- HSI source: 0 Nav1, 1 Nav2, 2 GPS1, 3 GPS2 (DataRefs.txt, found 2026-11-12)
local HSI_SOURCE = "sim/cockpit2/radios/actuators/HSI_source_select_pilot"
-- ground track, degrees magnetic (DataRefs.txt: exists; found 2026-11-12). The
-- fallback below is only for a sim build that lacks it.
local TRACK_MAG = "sim/cockpit2/gauges/indicators/ground_track_mag_pilot"
local HPATH_TRUE = "sim/flightmodel/position/hpath"
local MAG_VAR = "sim/flightmodel/position/magnetic_variation"
local ALT_STEP = "sim/aircraft/autopilot/alt_step_ft"   -- note: sim/aircraft/..., not aircraft/...
local VVI_STEP = "sim/aircraft/autopilot/vvi_step_ft"
-- power and brightness (2026-11-18). Powered = the autopilot computer has power (0 = none; follows the avionics
-- master). Brightness = X-Plane's pilot panel dimmer. key_light = powered x level, the one value the 3D model and
-- the popup read (the GTX 327 pattern, laminar/gfc500/key_light). The 3D model used to map the dimmer itself with
-- ATTR_light_level -0.25 2.5 <dimmer>, i.e. level = (dimmer + 0.25) / 2.75 clamped to 0..1 (0.091 at dimmer 0,
-- 0.455 at dimmer 1); the same curve is computed here so the lit 3D result is identical.
local POWER = "sim/cockpit2/autopilot/autopilot_has_power"
local DIMMER = "sim/cockpit2/switches/instrument_brightness_ratio"     -- float[], index 0
local DIM_LO, DIM_HI = -0.25, 2.5      -- the old ATTR_light_level range: dataref DIM_LO -> level 0, DIM_HI -> level 1

-- lamp array order (M section 0)
Logic.KEYS = { "ap", "fd", "yd", "lvl", "hdg", "trk", "nav", "apr", "ias", "alt", "vs", "vnav" }
Logic.KEY_INDEX = {}
for i, k in ipairs(Logic.KEYS) do Logic.KEY_INDEX[k] = i end

-- every status that ends the LVL latch when it is 2 (M section 2; TOGA ones are
-- extra compared with G3X_AFCS)
local LVL_EXIT = { "heading_status", "heading_hold_status", "track_status", "nav_status", "gpss_status",
    "approach_status", "speed_status", "altitude_hold_status", "vvi_status", "vnav_status",
    "glideslope_status", "TOGA_status", "TOGA_lateral_status" }

-- the single X-Plane command a mode key sends. A second press sends the same
-- command again: X-Plane cancels the mode itself (M 4.3 P13, L7 deleted).
local ENTER = {
    hdg = SA .. "heading", trk = SA .. "track", apr = SA .. "approach", ias = SA .. "level_change",
    vs = SA .. "vertical_speed", vnav = SA .. "vnav",
}

function Logic.new(api, cfg)
    local L = { lamp = {}, anim_val = {}, knob = { hdg = 0, alt = 0, wheel = 0 }, act = {}, KEY_INDEX = Logic.KEY_INDEX,
        powered = true, key_light = 0 }
    for i = 1, #Logic.KEYS do L.lamp[i] = 0 L.anim_val[i] = 0 end

    local lvl_latch = false
    local prev_servos, prev_speed, prev_vvi = nil, nil, nil     -- nil = not seen yet (seeded by the first update)
    local flash_until = 0
    local disc_pending = false
    local anim_until = {}
    local orig_step = {}
    local installed_try, installed_wrote = -1e9, false
    local cap_warned, prev_port_ver = false, nil
    local PORT = "laminar/afcs/"
    local lvl_prev = {}      -- M7: last status values seen since the LVL latch was set

    -- powered: autopilot_has_power ~= 0. A sim without that dataref (not X-Plane 12) counts as powered, so the unit
    -- is never dead for a missing name. key_light: 0 unpowered, else the dimmer curve above (dimmer missing = 1.0).
    local function read_power()
        if not api.has(POWER) then return true end
        return api.geti(POWER) ~= 0
    end
    local function read_key_light()
        if not L.powered then return 0 end
        local d = 1.0
        if api.getfa and api.has(DIMMER) then d = api.getfa(DIMMER, 0) or 1.0 end
        local v = (d - DIM_LO) / (DIM_HI - DIM_LO)
        return v < 0 and 0 or (v > 1 and 1 or v)
    end

    local function st(n) return api.geti(AP .. n) end
    local function servos() return st("servos_on") ~= 0 end
    local function fd_on() return st("flight_director_mode") > 0 end
    local function fire(c)
        if cfg.log_keys ~= 0 then api.log("fire " .. c) end
        api.fire(c)
    end
    local function pulse(id) anim_until[id] = api.now() + 0.12 end

    -- LVL: no status of its own; lit from the return_to_level listener until
    -- another mode is active or AP and FD are both off (M section 2)
    -- M7: only a status EDGE into 2 after the latch was set clears it; a status
    -- that was already 2 when the latch was set (the sim refreshes statuses a
    -- frame after the command) does not. lvl_prev is seeded in on_return_to_level.
    local function lvl_lit()
        if not lvl_latch then return false end
        if not servos() and st("flight_director_mode") == 0 then
            lvl_latch = false
        else
            local cleared = false
            for _, k in ipairs(LVL_EXIT) do
                local v = st(k)
                if v == 2 and lvl_prev[k] ~= 2 then cleared = true end
                lvl_prev[k] = v
            end
            if cleared then lvl_latch = false end
        end
        return lvl_latch
    end
    L.lvl_lit = lvl_lit

    -- engage guard (min_engage_kias 0 = off)
    local function engage_blocked()
        local m = cfg.min_engage_kias
        return m > 0 and not servos() and api.getf(IAS_PILOT) < m
    end

    local function bump(which, dir)
        -- the 3D model's ANIM_rotate keys are in revolutions (1.0 = 360 deg, loops at 1.0)
        L.knob[which] = (L.knob[which] + dir * cfg.knob_anim_deg / 360) % 1
    end

    -- greyed controls (popup and 3D model): FD key while AP on, wheel while FD off
    function L.enabled(id)
        if id == "fd" then return not servos() end
        if id == "wheel_up" or id == "wheel_dn" then return fd_on() end
        return true
    end

    ---------------------------------------------------------------- keys
    L.act.ap = function()
        pulse("ap")
        if servos() then
            fire(SA .. "servos_toggle")       -- AP on: manual disconnect, FD and YD stay (P1)
        elseif not engage_blocked() then
            fire(SA .. "servos_on")           -- idempotent; from FD-only keeps the FD modes (P15)
        end
    end
    L.act.fd = function()
        pulse("fd")
        if servos() then return end           -- key is dead while AP is engaged (X-Plane refuses too)
        fire(SA .. "fdir_toggle")
    end
    L.act.yd = function()
        pulse("yd")
        fire("sim/systems/yaw_damper_toggle")
    end
    L.act.lvl = function()
        pulse("lvl")
        if servos() and lvl_lit() then return end
        if engage_blocked() then return end
        fire(SA .. "return_to_level")         -- the listener (on_return_to_level) sets the latch
    end
    for id, cmd in pairs(ENTER) do
        L.act[id] = function()
            pulse(id)
            fire(cmd)
        end
    end
    -- M2: ALT while ALTS is capturing: altitude_hold_status is already 2 and a second
    -- altitude_hold would cancel to PIT (M 4.3 P13, P16b). pitch_sync drops the capture
    -- (and arms ALT, P13), then altitude_hold holds the current altitude. [assumption:
    -- the pair is not probed together] ALT hold without capture keeps the toggle.
    L.act.alt = function()
        pulse("alt")
        if st("altitude_hold_status") == 2 and st("alts_captured") ~= 0 then
            fire(SA .. "pitch_sync")
            fire(SA .. "altitude_hold")
        else
            fire(SA .. "altitude_hold")
        end
    end
    L.act.nav = function()
        pulse("nav")
        -- L6 (cancel only GS first) is not implemented: no GS-only command is
        -- known (M 4.3 "P14"), and "NAV again" is just this command.
        if api.geti(HSI_SOURCE) >= 2 then
            -- H1: gpss is enter-only in X-Plane (xp_ap_inventory, gpss row): a second press
            -- leaves gpss_status at 2. With GPSS armed or active send wing_leveler to
            -- cancel. [unverified in the sim: the effect of wing_leveler on GPSS, and on an
            -- ARMED (status 1) GPSS; P13 only showed it cancels engaged modes]
            if st("gpss_status") ~= 0 then fire(SA .. "wing_leveler") else fire(SA .. "gpss") end
        else
            fire(SA .. "NAV")
        end
    end

    ---------------------------------------------------------------- knobs
    L.act.hdg_knob_left = function() fire(SA .. "heading_down") bump("hdg", -1) end
    L.act.hdg_knob_right = function() fire(SA .. "heading_up") bump("hdg", 1) end
    L.act.hdg_knob_push = function()
        if st("track_status") == 2 then
            -- L5: heading_sync syncs the heading; in TRK sync to the ground track
            local t
            if api.has(TRACK_MAG) then
                t = api.getf(TRACK_MAG)
            else
                t = api.getf(HPATH_TRUE) - api.getf(MAG_VAR)
            end
            api.setf(AP .. "heading_dial_deg_mag_pilot", t % 360)
        else
            fire(SA .. "heading_sync")
        end
    end

    -- L13: turning ALT SEL during an ALTS capture must return to PIT and re-arm
    -- ALTS; X-Plane does neither (P16). pitch_sync alone does both: it leaves ALT
    -- and sets altitude_hold_armed = 1 (P13), so no altitude_arm (M8). Checked
    -- before the change: altitude_down clears alts_captured by itself.
    local function alt_sel(cmd)
        local was_captured = st("alts_captured") ~= 0
        fire(cmd)
        if was_captured then
            fire(SA .. "pitch_sync")
        end
    end
    L.act.alt_sel_knob_left = function() alt_sel(SA .. "altitude_down") bump("alt", -1) end
    L.act.alt_sel_knob_right = function() alt_sel(SA .. "altitude_up") bump("alt", 1) end
    L.act.alt_sel_knob_push = function() alt_sel(SA .. "altitude_sync") end

    ---------------------------------------------------------------- wheel
    -- current vertical mode, first hit wins (M section 1.16)
    function L.vertical_mode()
        if lvl_lit() then return "lvl" end
        if st("vnav_status") == 2 then return "vnav" end
        if st("glideslope_status") == 2 then return "gs" end
        if st("TOGA_status") == 2 then return "toga" end
        if st("speed_status") == 2 then return "ias" end
        if st("altitude_hold_status") == 2 then return st("alts_captured") ~= 0 and "alts" or "alt" end
        if st("vvi_status") == 2 then return "vs" end
        return "pit"
    end
    -- PIT / VS / IAS: X-Plane's own nose_up/down does the right step (P7); ALT
    -- hold, ALTS, LVL, VNAV, GS, TO/GA: ignored (M 4.3, gap 14)
    local WHEEL_OK = { pit = true, vs = true, ias = true }
    -- M6: PIT is limited to -15..+20 deg by us; VS and IAS limits are X-Plane's
    local PIT_MAX, PIT_MIN = 20, -15
    local function wheel(cmd, dir)
        if not fd_on() then return end
        local mode = L.vertical_mode()
        if WHEEL_OK[mode] then
            local pitch = api.getf(AP .. "sync_hold_pitch_deg")
            if mode == "pit" and ((dir > 0 and pitch >= PIT_MAX) or (dir < 0 and pitch <= PIT_MIN)) then
                -- at the limit: ignored
            else
                fire(cmd)
            end
        end
        bump("wheel", dir)
    end
    L.act.wheel_up = function() wheel(SA .. "nose_up", 1) end
    L.act.wheel_dn = function() wheel(SA .. "nose_down", -1) end

    -- unpowered: keys, knobs and wheel do nothing (no command, no key animation, no knob turn). Every action is
    -- wrapped here, so the popup, the 3D clicks and a key bound to a laminar/gfc500/* command all go dead together.
    for id, fn in pairs(L.act) do
        L.act[id] = function(...)
            if not L.powered then return end
            return fn(...)
        end
    end

    ---------------------------------------------------------------- listeners
    function L.on_return_to_level()
        lvl_latch = true
        for _, k in ipairs(LVL_EXIT) do lvl_prev[k] = st(k) end
    end
    function L.on_disc() disc_pending = true end

    ---------------------------------------------------------------- lifecycle
    -- one-time step settings, restored by shutdown() (M 1.15, plan A)
    function L.setup()
        -- Review C3 (2026-11-13): edge state belongs to one enabled session. After a Disable / Enable the
        -- autopilot may have changed meanwhile; the first frame only SEEDS the previous values, so it cannot
        -- see a servos edge (amber flash, YD toggle), a VS / IAS entry (dial snap) or a stale LVL latch.
        prev_servos, prev_vvi, prev_speed = nil, nil, nil
        lvl_latch, lvl_prev = false, {}
        flash_until, disc_pending = 0, false
        L.powered = read_power()
        L.key_light = read_key_light()
        local function put(name, v)
            if api.has(name) and v > 0 then
                orig_step[name] = api.getf(name)
                api.setf(name, v)
            end
        end
        put(ALT_STEP, cfg.alt_sel_step_ft)
        put(VVI_STEP, cfg.vs_wheel_fpm)
        local t = api.geti("sim/aircraft/autopilot/preconfigured_ap_type")
        if t ~= 2 then
            api.log("WARNING: autopilot type is " .. t .. ", not GFC-700 (2): the key table assumes GFC-700 logic")
        end
    end
    function L.shutdown()
        for name, v in pairs(orig_step) do api.setf(name, v) end
        orig_step = {}
        -- unpowered: lamps and key animations go dark (the 3D model reads these datarefs)
        for i = 1, #Logic.KEYS do L.lamp[i] = 0 L.anim_val[i] = 0 end
        L.powered, L.key_light = false, 0
    end

    local function tri(v) return v >= 2 and 2 or (v == 1 and 1 or 0) end
    local function max2(a, b) return a > b and a or b end

    -- once per frame
    function L.update()
        local now = api.now()
        local sv = servos()
        L.powered = read_power()
        L.key_light = read_key_light()

        if prev_servos == nil then
            prev_servos = sv
        elseif sv and not prev_servos then
            -- L2: the sim does not turn YD on when the AP engages (P2)
            flash_until = 0
            if api.geti(YD_SWITCH) == 0 then fire("sim/systems/yaw_damper_toggle") end
        elseif prev_servos and not sv then
            -- H3: every servos_on 1->0 edge flashes the AP lamp amber. No
            -- autopilot_on_or_cws gate: never probed, CWS is out of scope for v1.
            flash_until = now + cfg.disc_flash_s
        end
        prev_servos = sv
        if not L.powered then flash_until = 0 end     -- a power loss is not a disconnect: no amber flash when power returns

        -- L3: AP DISC also turns YD off (the AP DISC listener only sets this flag)
        if disc_pending then
            disc_pending = false
            if api.geti(YD_SWITCH) ~= 0 then fire("sim/systems/yaw_damper_off") end
        end

        -- L9a / L9b: round the reference the sim took on entering VS / IAS
        local vvi, spd = st("vvi_status"), st("speed_status")
        if prev_vvi == nil then prev_vvi, prev_speed = vvi, spd end
        if vvi == 2 and prev_vvi ~= 2 then
            api.setf(AP .. "vvi_dial_fpm", math.floor(api.getf(AP .. "vvi_dial_fpm") / 100 + 0.5) * 100)
        end
        if spd == 2 and prev_speed ~= 2 then
            api.setf(AP .. "airspeed_dial_kts", math.floor(api.getf(AP .. "airspeed_dial_kts") + 0.5))
        end
        prev_vvi, prev_speed = vvi, spd

        -- lamps: 0 off, 1 armed, 2 active, 3 amber flash (AP only)
        local l = L.lamp
        if not L.powered then
            -- no power: the unit is dark; the lamps resume from the autopilot state when power returns
            for k = 1, #Logic.KEYS do l[k] = 0 L.anim_val[k] = 0 end
        else
            l[1] = sv and 2 or (now < flash_until and 3 or 0)
            l[2] = fd_on() and 2 or 0
            l[3] = api.geti(YD_SWITCH) ~= 0 and 2 or 0
            l[4] = lvl_lit() and 2 or 0
            l[5] = (st("heading_status") == 2 or st("heading_hold_status") == 2) and 2 or 0
            l[6] = st("track_status") == 2 and 2 or 0
            l[7] = tri(max2(st("nav_status"), st("gpss_status")))
            l[8] = st("glideslope_status") == 2 and 2 or tri(st("approach_status"))
            l[9] = spd == 2 and 2 or 0
            l[10] = st("altitude_hold_status") == 2 and 2 or 0
            l[11] = vvi == 2 and 2 or 0
            l[12] = tri(st("vnav_status"))

            for i, k in ipairs(Logic.KEYS) do
                L.anim_val[i] = (anim_until[k] and now < anim_until[k]) and 1 or 0
            end
        end

        -- gfc500/installed belongs to the G5; we never create it. Once a second:
        -- decide the target, re-find the dataref (the G5 may have reloaded and recreated
        -- it), compare and write when it differs. A read-back is not proof of success
        -- (int accessor of a float-only dataref reads 0), so write both ways and
        -- check again next second.
        -- Target (afcs SPEC v2 / INTEGRATION 4b): laminar/afcs/cap_digital when the port is
        -- live, port_version >= 2 and the name resolves; else ap_type from config.ini.
        -- Supported and 0 is the provider's answer, never a fall-back trigger. Everything is
        -- looked up fresh each second (handles forgotten first), so a provider that appears on
        -- its first flight loop, or a port_version change, is picked up within a second.
        -- Read-only on laminar/afcs/*.
        if now - installed_try >= 1 then
            installed_try = now
            local own = cfg.ap_type == "analog" and 0 or 1
            local target = own
            api.forget(PORT .. "port_version")
            if api.has(PORT .. "port_version") then
                local ver = api.geti(PORT .. "port_version")
                if ver >= 1 and ver ~= prev_port_ver then
                    prev_port_ver = ver
                    api.log("laminar/afcs port_version " .. ver)
                elseif ver < 1 then
                    prev_port_ver = nil
                end
                if ver >= 2 then
                    api.forget(PORT .. "cap_digital")
                    if api.has(PORT .. "cap_digital") then
                        target = api.geti(PORT .. "cap_digital") ~= 0 and 1 or 0
                        if target ~= own and not cap_warned then
                            cap_warned = true
                            api.log("WARNING: AFCS cap_digital = " .. target .. " but config.ini ap_type = " ..
                                (own == 1 and "digital" or "analog") .. "; following cap_digital")
                        end
                    end
                end
            else
                prev_port_ver = nil
            end
            local name = "laminar/gfc500/installed"
            api.forget(name)
            if api.has(name) then
                local v = target
                if api.getf(name) ~= v then
                    api.seti(name, v)
                    api.setf(name, v)
                    installed_wrote = true
                end
            end
        end
    end

    function L.installed_written() return installed_wrote end
    return L
end

return Logic
