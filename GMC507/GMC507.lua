--[[ XLua 2.0 ]]
--[[
Author Name         : Eric Xu

GMC507: Garmin GMC 507 autopilot mode controller (12 keys, 2 knobs, pitch wheel;
no display) driving X-Plane's built-in GFC-700 autopilot logic. There is a 3D
unit (folder 3D/) plus a 2D popup; both send the same laminar/gfc500/* commands.

Files (same folder): GMC507.lua (this: lifecycle, commands, datarefs, flight
loop), gmc507_logic.lua (all behaviour), gmc507_popup.lua (popup),
gmc507_pick.lua (plugin picking: clicks on the 3D unit), gmc507_face.png (popup
face), config.ini, 3D/ (GMC507.obj and its textures GMC507_ALB.png,
GMC507_LIT.png, GMC507_NRM.png). Design and limits: see the manual
(GMC507_Manual.pdf).

Deviations from the real 507 that this code knowingly accepts (details: the manual
(GMC507_Manual.pdf), chapter Known Limitations):
  - HDG/TRK turn direction is X-Plane's shortest turn, no 330 deg rule; one dial
    serves HDG and TRK (no separate track bug).
  - Engagement roll hold (6/20 deg), LVL arms ALTS, ALT key reference not rounded
    to 10 ft, GP/GS/back-course/>105 deg capture rules, VNAV path: X-Plane's own.
  - Wheel does nothing in ALT hold / ALTS / LVL / VNAV / GS / TO-GA.
  - Wheel limits: in PIT only, wheel_up is ignored at sync_hold_pitch_deg >= 20 and
    wheel_dn at <= -15. VS and IAS limits are left to X-Plane (not probed).
  - NAV "cancel GS first" is not implemented: no GS-only command is known.
  - No MET, CWS, TO/GA, ESP, trim, disconnect annunciations or sounds.
  - The popup has no scroll wheel: knob halves click left/right, centre = push.

3D clicks: X-Plane only picks manipulators of the cockpit object, so GMC507.obj (attached
as a misc object, acf _obja/51) is clicked by gmc507_pick.lua (copied from G5's g5_pick.lua).

Copyright (c) 2026 Eric Xu / Laminar Research. MIT License, see LICENSE.
--]]

require("XPLMDefs")
require("XPLMDataAccess")
require("XPLMDisplay")
require("XPLMPanelGraphics")
require("XPLMProcessing")
require("XPLMUtilities")

local SCRIPT_NAME = "GMC507"
local PREFIX = "laminar/gfc500/"

local function log(msg) print("[GMC507] " .. tostring(msg)) end

local config = {
    ap_type = "digital",
    min_engage_kias = 0,
    popup_at_start = 1,
    disc_flash_s = 3,
    alt_sel_step_ft = 100,
    vs_wheel_fpm = 100,
    knob_anim_deg = 15,
    log_keys = 0,
    pick_mode = 1,             -- gmc507_pick.lua: 0 off, 1 auto (yields to native clicks), 2 always
    pick_pass_misses = 0,
    pick_debug = 0,
}

-----------------------------------------------------------------------------
-- Modules (pattern of AFCS_ESP.lua) and config.ini
-----------------------------------------------------------------------------

local function normalize(p) return (p or ""):gsub("\\", "/") end

local function discover_script_dir()
    local info = debug and debug.getinfo and debug.getinfo(1, "S")
    local src = info and info.source or ""
    if string.sub(src, 1, 1) == "@" then
        local d = normalize(string.sub(src, 2)):match("^(.*)/[^/]*$")
        if d and d ~= "" then return d end
    end
    local model = XPLMGetNthAircraftModel(0)
    local acf = ""
    if type(model) == "table" then acf = normalize(model.outPath or model[2] or "") end
    local aircraft_dir = acf:match("^(.*)/[^/]*$") or "."
    for _, sub in ipairs({ "plugins/xlua/scripts/" .. SCRIPT_NAME, "plugins/xlua2/scripts/" .. SCRIPT_NAME }) do
        local d = aircraft_dir .. "/" .. sub
        local f = io.open(d .. "/" .. SCRIPT_NAME .. ".lua", "r")
        if f then
            f:close()
            return d
        end
    end
    return aircraft_dir .. "/plugins/xlua/scripts/" .. SCRIPT_NAME
end

local script_dir = discover_script_dir()

local function load_module(name)
    local path = script_dir .. "/" .. name .. ".lua"
    if loadfile then
        local chunk, err = loadfile(path)
        if chunk then
            if setfenv and getfenv then setfenv(chunk, getfenv(1)) end
            return chunk()
        end
        log("loadfile failed: " .. tostring(err))
    end
    if package and package.path and not string.find(package.path, script_dir, 1, true) then
        package.path = script_dir .. "/?.lua;" .. package.path
    end
    return require(name)
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- "key = value" lines; ; or # comments; values take the default's type; an
-- invalid value is logged and the default stays
local function read_ini(path, defaults)
    local f = io.open(path, "r")
    if not f then
        log("config.ini not found, using defaults: " .. path)
        return false
    end
    for line in f:lines() do
        local s = trim((line:gsub("[;#].*$", "")))
        if s ~= "" and string.sub(s, 1, 1) ~= "[" then
            local key, value = s:match("^([^=]+)=(.*)$")
            if key then
                key = string.lower(trim(key))
                value = trim(value)
                local d = defaults[key]
                if d == nil then
                    log("config.ini: unknown key '" .. key .. "' ignored")
                elseif type(d) == "number" then
                    local n = tonumber(value)
                    if n then defaults[key] = n else log("config.ini: bad value for " .. key .. ": " .. value) end
                else
                    defaults[key] = string.lower(value)
                end
            end
        end
    end
    f:close()
    return true
end

local Logic = load_module("gmc507_logic")
local Popup = load_module("gmc507_popup")
local Pick = load_module("gmc507_pick")

-----------------------------------------------------------------------------
-- X-Plane access for the logic (a miss is not cached: a script that loads
-- later creates its datarefs later)
-----------------------------------------------------------------------------

local found, cmdh = {}, {}
local function find(name)
    local h = found[name]
    if h == nil then
        h = XPLMFindDataRef(name)
        if h then found[name] = h end
    end
    return h
end

local api = { log = log }
function api.geti(n)
    local h = find(n)
    if not h then return 0 end
    local ok, v = pcall(XPLMGetDatai, h)
    return ok and v or 0
end
function api.getf(n)
    local h = find(n)
    if not h then return 0 end
    local ok, v = pcall(XPLMGetDataf, h)
    if not ok or v ~= v then return 0 end
    return v
end
-- one element of a float array dataref (e.g. sim/cockpit2/switches/instrument_brightness_ratio, index 0); the name
-- is the array's, without [i]. nil when the dataref or the element is not there.
local fa_scratch = {}
function api.getfa(n, idx)
    local h = find(n)
    if not h then return nil end
    fa_scratch[1] = nil
    local ok, count = pcall(XPLMGetDatavf, h, fa_scratch, idx or 0, 1)
    local v = fa_scratch[1]
    if not ok or not count or count <= 0 or v == nil or v ~= v then return nil end
    return v
end
function api.seti(n, v) local h = find(n) if h then pcall(XPLMSetDatai, h, v) end end
function api.setf(n, v) local h = find(n) if h then pcall(XPLMSetDataf, h, v) end end
function api.has(n) return find(n) ~= nil end
function api.fire(name)
    local c = cmdh[name]
    if not c then
        c = XPLMFindCommand(name)
        if c then cmdh[name] = c end
    end
    if c then XPLMCommandOnce(c) else log("command not found: " .. name) end
end
function api.now() return api.getf("sim/time/total_running_time_sec") end

function api.forget(n) found[n] = nil end    -- drop a cached handle (the owner script may have recreated it)

local L = Logic.new(api, config)
local popup = nil
local pick_ready = false     -- Pick.init done (once; the windows are made at the first Enable and kept)

-----------------------------------------------------------------------------
-- Our commands and datarefs. Everything here is created once in XPluginStart
-- and removed in XPluginStop only: xLua keeps every callback it is handed
-- (shared budget of 500), so Disable / Enable must not create new closures or
-- datarefs. Enable / Disable only start and stop the flight loop and the popup.
-----------------------------------------------------------------------------

local ACTIONS = {
    -- command suffix = logic action id (with "button_" cut off); the refcon is the index
    "button_ap", "button_fd", "button_yd", "button_lvl", "button_hdg", "button_trk", "button_nav",
    "button_apr", "button_ias", "button_alt", "button_vs", "button_vnav",
    "hdg_knob_left", "hdg_knob_right", "hdg_knob_push",
    "alt_sel_knob_left", "alt_sel_knob_right", "alt_sel_knob_push",
    "wheel_up", "wheel_dn",
}
local my_cmds = {}      -- { cmd handle, name, refcon } for Stop
local listeners = {}
local my_drs = {}       -- accessor handles
local native = {}       -- name -> xLua storage handle (kept across Disable / Enable)
local enabled = false
local created = false

-- the whole lookup is inside the pcall; the refcon is a number (G5 / AFCS_ESP pattern)
local function run_ctl(ref)
    local name = type(ref) == "number" and ACTIONS[ref] or nil
    if not name then error("bad refcon " .. tostring(ref)) end
    local fn = L.act[(name:gsub("^button_", ""))]
    if not fn then error("no action for " .. name) end
    fn()
end

-- one function for every control command
local function ctl_cb(cmd, phase, ref)
    if phase == XPLMCommandPhase.xplm_CommandBegin and enabled then
        local ok, err = pcall(run_ctl, ref)
        if not ok then log("error in control " .. tostring(ref) .. ": " .. tostring(err)) end
    end
    return 1
end

-- listeners run before the sim and let it continue (return 1)
local function rtl_cb(cmd, phase, ref)
    if phase == XPLMCommandPhase.xplm_CommandBegin and enabled then L.on_return_to_level() end
    return 1
end
local function disc_cb(cmd, phase, ref)
    if phase == XPLMCommandPhase.xplm_CommandBegin and enabled then L.on_disc() end
    return 1
end

local function listen(name, fn)
    local c = XPLMFindCommand(name)
    if not c then log("command not found, listener skipped: " .. name) return end
    XPLMRegisterCommandHandler(c, fn, true, nil)
    listeners[#listeners + 1] = { c, fn }
end

-- output datarefs the 3D model reads: xLua's own storage when this xLua offers it
-- (no Lua callback), else a plain float accessor (one closure per dataref, made once)
local function out_float(name, getter)
    if XLuaCreateDataRef ~= nil and XLuaSetNumber ~= nil then
        local ok, h = pcall(XLuaCreateDataRef, name, "number", "no", nil)
        if ok and h ~= nil then
            native[name] = { h = h, get = getter }
            return
        end
    end
    local h = XPLMRegisterDataAccessor(name, XPLMDataTypeID.xplmType_Float, false,
        nil, nil, function() return getter() end, nil,
        nil, nil, nil, nil, nil, nil, nil, nil, nil, nil)
    if h then my_drs[#my_drs + 1] = h end
end

-- int[12] lamp array (accessor pattern of G5's g5_util.lua reg_int_array)
local function lamp_get_vi(ref, out, offset, max)
    local n = #L.lamp
    if out == nil then return n end
    local m = math.min(max or n, n - (offset or 0))
    for i = 1, m do out[i] = L.lamp[(offset or 0) + i] end
    return math.max(0, m)
end

local function create_outputs()
    local h = XPLMRegisterDataAccessor(PREFIX .. "lamp", XPLMDataTypeID.xplmType_IntArray, false,
        nil, nil, nil, nil, nil, nil, lamp_get_vi, nil, nil, nil, nil, nil, nil, nil)
    if h then my_drs[#my_drs + 1] = h end
    -- read-only int, 1 while the popup shows the flashing amber lamp (2 Hz, the popup's own clock
    -- floor(now*4)%2 == 0), else 0. The 3D model's amber LED hides on it. 0 when disabled.
    local hb = XPLMRegisterDataAccessor(PREFIX .. "lamp_blink", XPLMDataTypeID.xplmType_Int, false,
        function()
            if not enabled then return 0 end
            return (math.floor(api.now() * 4) % 2 == 0) and 1 or 0
        end, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil)
    if hb then my_drs[#my_drs + 1] = hb end
    for i, k in ipairs(Logic.KEYS) do
        out_float(PREFIX .. "button_anim_" .. k, function() return L.anim_val[i] end)
    end
    out_float(PREFIX .. "hdg_knob_val", function() return L.knob.hdg end)   -- revolutions, 0..1
    out_float(PREFIX .. "alt_knob_val", function() return L.knob.alt end)
    out_float(PREFIX .. "wheel_val", function() return L.knob.wheel end)
    -- read-only float 0..1 for the 3D lettering, lamps and knob rings (GTX 327 pattern): powered x dimmer level
    -- (logic: L.key_light). 0 when unpowered and after Disable (L.shutdown zeroes it).
    out_float(PREFIX .. "key_light", function() return L.key_light end)
end

-----------------------------------------------------------------------------
-- Flight loop
-----------------------------------------------------------------------------

local loop = nil
local function loop_cb(elapsed, elapsed_sim, counter, ref)
    local ok, err = pcall(function()
        L.update()
        if popup then popup.set_powered(L.powered) end
        for _, e in pairs(native) do XLuaSetNumber(e.h, e.get()) end
    end)
    if not ok then log("flight loop error: " .. tostring(err)) end
    if pick_ready then
        local pok, perr = pcall(Pick.update)
        if not pok then
            log("pick update error, 3D clicks off: " .. tostring(perr))
            pcall(Pick.disable)
            pick_ready = false
        end
    end
    return -1
end

-----------------------------------------------------------------------------
-- Lifecycle
-----------------------------------------------------------------------------

-- Disable: stop what runs; commands, listeners, datarefs stay (see above)
local function disable_parts()
    enabled = false
    if loop then pcall(XPLMScheduleFlightLoop, loop, 0, true) end   -- 0 = stopped; the loop itself is kept
    if popup then popup.set_powered(false) popup.hide() end
    pcall(Pick.disable)            -- hides the click windows, keeps them
    L.shutdown()
    -- the loop is stopped, so push the zeroed lamps / animations to xLua's storage by hand
    if XLuaSetNumber then
        for _, e in pairs(native) do pcall(function() XLuaSetNumber(e.h, e.get()) end) end
    end
end

-- Stop: remove what Start created
local function destroy_all()
    disable_parts()
    if popup then popup.destroy() end
    pcall(Pick.destroy)            -- the click windows (and their xLua callbacks) go with the script
    pick_ready = false
    if loop then pcall(XPLMDestroyFlightLoop, loop) loop = nil end
    for _, e in ipairs(my_cmds) do pcall(XPLMUnregisterCommandHandler, e[1], ctl_cb, true, e[3]) end
    my_cmds = {}
    for _, e in ipairs(listeners) do pcall(XPLMUnregisterCommandHandler, e[1], e[2], true, nil) end
    listeners = {}
    if popup then popup.unregister() end
    for _, h in ipairs(my_drs) do pcall(XPLMUnregisterDataAccessor, h) end
    my_drs = {}
    native = {}          -- xLua has no destroy for its storage datarefs
    created = false
end

function XPluginStart()
    read_ini(script_dir .. "/config.ini", config)
    if config.ap_type ~= "digital" and config.ap_type ~= "analog" then
        log("config.ini: ap_type must be digital or analog, using digital")
        config.ap_type = "digital"
    end
    if created then return true end
    local ok, err = pcall(function()
        for i, name in ipairs(ACTIONS) do
            local c = XPLMCreateCommand(PREFIX .. name, "GMC 507: " .. name)
            if c then
                XPLMRegisterCommandHandler(c, ctl_cb, true, i)
                my_cmds[#my_cmds + 1] = { c, name, i }
            else
                log("command could not be created, skipped: " .. PREFIX .. name)
            end
        end
        listen("sim/autopilot/return_to_level", rtl_cb)
        listen("sim/autopilot/ap_disc_trim_interrupt", disc_cb)
        create_outputs()
        popup = Popup.new({ L = L, now = api.now, getf = api.getf, has = api.has, log = log,
            key_light = function() return L.key_light end })
        popup.register()
        created = true
    end)
    if not ok then
        log("ERROR XPluginStart: " .. tostring(err))
        destroy_all()
        return false
    end
    return true
end

function XPluginEnable()
    if enabled then return true end
    local ok, err = pcall(function()
        enabled = true
        L.setup()
        popup.set_powered(L.powered)
        popup.create(config.popup_at_start ~= 0)
        -- 3D clicks: an error here leaves the popup and the commands working
        local pok, perr = pcall(function()
            if not pick_ready then
                Pick.init({ log = log }, config)
                pick_ready = true
            end
            local model = XPLMGetNthAircraftModel(0)
            local acf = type(model) == "table" and (model.outPath or model[2]) or model
            Pick.load(script_dir .. "/3D/GMC507.obj", normalize(tostring(acf or "")))
            Pick.enable()
        end)
        if not pok then log("pick: " .. tostring(perr)) end
        if not loop then
            loop = XPLMCreateFlightLoop({
                phase = XPLMFlightLoopPhaseType.xplm_FlightLoop_Phase_AfterFlightModel,
                callbackFunc = loop_cb,
                refcon = nil,
            })
        end
        XPLMScheduleFlightLoop(loop, -1, true)
    end)
    if not ok then
        log("ERROR XPluginEnable: " .. tostring(err))
        disable_parts()
        return false
    end
    -- registrations handed to the SDK: 20 controls + toggle + listeners, 4 avionics, 1 loop, accessors (lamp, lamp_blink, 12 anims,
    -- 3 knob values, key_light), 4 per click window
    local win_cb = (pick_ready and Pick.window_count() or 0) * 4      -- draw, click, cursor, wheel per window
    log(string.format("enabled: %d xLua callbacks (%d commands, %d accessors, 4 avionics, 1 flight loop, %d click window)",
        #my_cmds + 1 + #listeners + #my_drs + 5 + win_cb, #my_cmds + 1 + #listeners, #my_drs, win_cb))
    return true
end

function XPluginDisable() disable_parts() end
function XPluginStop() destroy_all() end

-- headless tests only
GMC507_TEST = {
    L = L, config = config, api = api, Logic = Logic,
    popup = function() return popup end,
    pick = Pick,
    native = function() return native end,
}
