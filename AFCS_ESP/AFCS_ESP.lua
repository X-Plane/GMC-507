--[[ XLua 2.0 ]]
--[[
*****************************************************************************************
* Program Script Name : AFCS_ESP (headless ESP provider, AFCS port version 2)
*
* Author Name         : Eric Xu
*
* Electronic Stability & Protection as a function of the aircraft's autopilot,
* with no display and no device model. It provides the laminar/afcs/ port
* (SPEC.md): displays and mode controllers read
* it and fire its commands; none of them runs ESP logic of its own.
*
* It is the fallback provider: it claims the port on its first flight-loop
* callback, after every script has started, and only if no other module
* (an autopilot module) provides it already. Otherwise it stays passive.
*
* Files (same folder):
*   AFCS_ESP.lua        this master script: lifecycle, port, flight loop
*   afcs_util.lua       helpers            afcs_sim.lua       sim dataref snapshot
*   afcs_esp_logic.lua  ESP logic          afcs_actuator.lua  forces -> art-stab input
*   afcs_pft.lua        autopilot preflight test
*   config.ini          per-aircraft settings
* (no module may share AFCS_ESP.lua's name in another case: Windows file
* names ignore case)
*****************************************************************************************
*        Copyright (c) 2026 Eric Xu / Laminar Research. MIT License, see LICENSE.
*****************************************************************************************
--]]

require("XPLMDefs")
require("XPLMDataAccess")
require("XPLMPlanes")
require("XPLMProcessing")
require("XPLMUtilities")

local SCRIPT_NAME = "AFCS_ESP"
local PORT = "laminar/afcs/"
local PORT_VERSION = 2
-- a display's heartbeat older than this means no valid attitude (SPEC.md)
local HEARTBEAT_MAX_AGE_S = 0.5

local config = {
    esp = 1,
    esp_enabled_at_start = 1,
    esp_agl = 1,
    esp_roll_limit = 45,
    esp_pitch_up = 20,
    esp_pitch_down = 20,
    esp_speed_max = 0,
    esp_speed_min = 0,
    esp_speed_min_margin = 1.1,
    attitude_source = "heartbeat",
    actuator = "artstab",
    actuator_roll_authority = 0.30,
    actuator_pitch_authority = 0.20,
    actuator_slew_per_s = 0.6,
    -- what the aircraft's autopilot is (port v2, SPEC.md). Optional: a key
    -- that config.ini does not set is not registered (XPluginStart). The
    -- values here are only what a present but invalid value is replaced by
    cap_digital = 1,
    cap_ias_mode = 1,
    pft_s = 5,
}
local OPTIONAL_KEYS = { "cap_digital", "cap_ias_mode", "pft_s" }

-----------------------------------------------------------------------------
-- Modules
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
        print("[AFCS_ESP] loadfile failed: " .. tostring(err))
    end
    if package and package.path and not string.find(package.path, script_dir, 1, true) then
        package.path = script_dir .. "/?.lua;" .. package.path
    end
    return require(name)
end

local U   = load_module("afcs_util")
local Sim = load_module("afcs_sim")
local Esp = load_module("afcs_esp_logic")
local Act = load_module("afcs_actuator")
local Pft = load_module("afcs_pft")

-----------------------------------------------------------------------------
-- Port
-----------------------------------------------------------------------------

-- "start": not decided yet (XPluginStart up to the first flight-loop
-- callback); "provider": this copy owns the port; "passive": another module
-- (or another copy) does. Kept through XPluginDisable / XPluginEnable
local role = "start"
local heartbeat = 0        -- laminar/afcs/attitude_heartbeat
local att_ok = false
local datarefs = {}        -- handles to unregister
local commands = {}        -- { command ref, handler id }
local listeners = {}       -- sim command listeners (U.listen)
local loop = nil

local function b(v) return v and 1 or 0 end

-- { name, "i" | "f", getter, setter (nil = read-only), config key that must be
-- set for the dataref to exist (nil = always) }
local PORT_DATAREFS = {
    { "port_version", "i", function() return PORT_VERSION end },
    { "esp_installed", "i", function() return b(Esp.installed()) end },
    { "esp_available", "i", function() return b(Esp.available()) end },
    { "esp_enabled", "i", function() return b(Esp.enabled) end,
        function(ref, v) Esp.enabled = (v ~= 0) end },
    { "esp_armed", "i", function() return b(Esp.armed) end },
    { "esp_engaged", "i", function() return Esp.engaged_mask() end },
    { "esp_roll_limit", "f", function() return Esp.roll_limit end },
    { "esp_pitch_up_limit", "f", function() return Esp.pitch_up_limit end },
    { "esp_pitch_down_limit", "f", function() return Esp.pitch_down_limit end },
    { "esp_roll_force", "f", function() return Esp.roll_force end },
    { "esp_pitch_force", "f", function() return Esp.pitch_force end },
    { "attitude_heartbeat", "f", function() return heartbeat end,
        function(ref, v) heartbeat = v end },
    -- port v2
    { "cap_digital", "i", function() return config.cap_digital end, nil, "cap_digital" },
    { "cap_ias_mode", "i", function() return config.cap_ias_mode end, nil, "cap_ias_mode" },
    { "ap_pft", "i", function() return Pft.state end, nil, "pft_s" },
    { "speed_protect", "i", function() return Esp.speed_protect() end },
    { "esp_interrupted", "i", function() return b(Esp.installed() and Esp.interrupted) end },
}

-- { name, description, handler(phase) }
local PORT_COMMANDS = {
    { "esp_toggle", "ESP on / off", function(phase)
        if phase == XPLMCommandPhase.xplm_CommandBegin then Esp.enabled = not Esp.enabled end
    end },
    { "esp_interrupt", "ESP interrupt (hold: AP DISC / TRIM INT)", function(phase)
        Esp.hold("esp_interrupt", phase ~= XPLMCommandPhase.xplm_CommandEnd)
    end },
}

-- sim commands that interrupt ESP while held; listened to "before" the sim,
-- which still runs them (the autopilot disconnects, TO/GA engages)
local SIM_INTERRUPTS = {
    "sim/autopilot/ap_disc_trim_interrupt",
    "sim/autopilot/take_off_go_around",
}

-- raises when any part of the port cannot be registered (the caller then
-- unregisters what was registered). A field the config does not provide is
-- skipped, one log line each: consumers treat it as unsupported
local function register_port()
    for _, d in ipairs(PORT_DATAREFS) do
        if d[5] and config[d[5]] == nil then
            U.log("not provided: " .. PORT .. d[1] .. " (" .. d[5]
                .. " is not set in config.ini), dataref not registered")
        else
            local reg = (d[2] == "i") and U.reg_int or U.reg_float
            local h = reg(PORT .. d[1], d[3], d[4])
            if h == nil then error("could not register " .. PORT .. d[1], 0) end
            datarefs[#datarefs + 1] = h
        end
    end
    for _, c in ipairs(PORT_COMMANDS) do
        local fn = c[3]
        local cmd = XPLMCreateCommand(PORT .. c[1], c[2])
        if cmd == nil then error("could not create command " .. PORT .. c[1], 0) end
        local id = U.reg_cmd(cmd, function(_, phase) fn(phase) end)
        commands[#commands + 1] = { cmd, id }
    end
    for _, name in ipairs(SIM_INTERRUPTS) do
        local l = U.listen(name, function(phase)
            Esp.hold(name, phase ~= XPLMCommandPhase.xplm_CommandEnd)
        end)
        if l then listeners[#listeners + 1] = l end
    end
end

local function unregister_port()
    for _, l in ipairs(listeners) do U.unlisten(l) end
    listeners = {}
    for _, c in ipairs(commands) do U.unreg_cmd(c[1], c[2]) end
    commands = {}
    for _, h in ipairs(datarefs) do U.unreg_dataref(h) end
    datarefs = {}
end

-- a live port: port_version found and 1 or more. A provider that stopped
-- leaves an orphan dataref reading 0: that is no provider (SPEC.md rule 1)
local function port_live()
    local h = XPLMFindDataRef(PORT .. "port_version")
    if h == nil then return false, 0 end
    local ok, v = pcall(XPLMGetDatai, h)
    v = (ok and v) or 0
    return v >= 1, v
end

-----------------------------------------------------------------------------
-- Flight loop
-----------------------------------------------------------------------------

local function attitude_valid(D)
    if config.attitude_source == "sim" then return not D.ahrs_failed end
    return heartbeat > 0 and math.abs(D.now - heartbeat) <= HEARTBEAT_MAX_AGE_S
end

-- one stage of the tick; an error is logged (once per distinct message) and
-- does not stop the other stages
local last_err = {}
local function guarded(stage, fn, ...)
    local ok, err = pcall(fn, ...)
    if ok then
        last_err[stage] = nil
        return true
    end
    err = tostring(err)
    if last_err[stage] ~= err then U.log("update (" .. stage .. "): " .. err) end
    last_err[stage] = err
    return false
end

local function tick(dt)
    local D = Sim.read()
    att_ok = attitude_valid(D)
    local esp_ok = guarded("esp", Esp.update, D, att_ok)
    if not esp_ok then
        -- nothing may keep pushing on a failed ESP
        Esp.idle()
    end
    guarded("pft", Pft.update, D)
    -- interrupted (or ESP failed): the output goes to 0 at once
    guarded("actuator", Act.update, Esp.roll_force, Esp.pitch_force, dt,
        (not esp_ok) or Esp.interrupted)
end

-- the first flight-loop callback: every script has started by now, so an
-- autopilot module that provides the port has registered it
local function claim()
    local live, v = port_live()
    if live then
        role = "passive"
        U.log(PORT .. " v" .. tostring(v) .. " is provided by another module: fallback stays passive")
        return
    end
    role = "provider"      -- first: a registration that fails half-way is not retried
    local ok, err = pcall(register_port)
    if not ok then
        -- a port that is not complete is no port: this copy gives it up, never
        -- drives the art stab, and does not say it provides anything
        unregister_port()
        role = "passive"
        U.log(tostring(err) .. ": fallback stays passive, nothing of " .. PORT
            .. " is provided by this copy and ESP does not run")
        return
    end
    local function opt(k) return config[k] == nil and "not provided" or tostring(config[k]) end
    U.log("provider of laminar/afcs v" .. PORT_VERSION .. " (fallback): esp " .. config.esp
        .. ", attitude " .. config.attitude_source .. ", actuator " .. config.actuator
        .. ", cap_digital " .. opt("cap_digital") .. ", cap_ias_mode " .. opt("cap_ias_mode")
        .. ", pft_s " .. opt("pft_s"))
end

-- returns -1 (every frame) while this copy provides the port or has not
-- decided yet, 0 (stop calling) once it is passive
local function loop_cb(since_call, since_loop, counter, refcon)
    if role == "start" then
        local ok, err = pcall(claim)
        if not ok then U.log("claim: " .. tostring(err)) end
        -- ESP runs from the next frame
        return (role == "passive") and 0 or -1
    end
    if role ~= "provider" then return 0 end
    local ok, err = pcall(tick, since_call or 0)
    if not ok then U.log("update: " .. tostring(err)) end   -- Sim.read failed
    return -1
end

-- disabled: nothing armed or pushing while the port stays registered; a
-- copy that is not the provider never touches the art-stab channel (SPEC:
-- one writer)
local function stop_loop()
    if loop then
        XPLMDestroyFlightLoop(loop)
        loop = nil
    end
    if role == "provider" then
        Esp.idle()
        Pft.restart()
        pcall(Act.release)
    end
end

-----------------------------------------------------------------------------
-- Lifecycle
-----------------------------------------------------------------------------

local function check_choice(key, choices)
    for _, c in ipairs(choices) do
        if config[key] == c then return end
    end
    U.log("config.ini: " .. key .. " = '" .. tostring(config[key]) .. "' is not valid ("
        .. table.concat(choices, " | ") .. "), using " .. choices[1])
    config[key] = choices[1]
end

local function check_flag(key, default)
    if config[key] == 0 or config[key] == 1 then return end
    U.log("config.ini: " .. key .. " = '" .. tostring(config[key]) .. "' is not valid (0 | 1), using "
        .. default)
    config[key] = default
end

local function check_range(key, lo, hi)
    local v = U.clamp(config[key], lo, hi)
    if v == config[key] then return end
    U.log("config.ini: " .. key .. " = " .. tostring(config[key]) .. " is outside " .. lo .. ".." .. hi
        .. ", using " .. v)
    config[key] = v
end

-- nothing is registered here: the port is claimed on the first flight-loop
-- callback (claim), after every script has started (SPEC.md rule 1)
function XPluginStart()
    role = "start"
    local seen = {}
    U.read_ini(script_dir .. "/config.ini", config, seen)
    check_choice("attitude_source", { "heartbeat", "sim" })
    check_choice("actuator", { "artstab", "none" })
    -- every numeric value: out of range is logged and replaced (never silently clamped)
    check_flag("esp", 1)
    check_flag("esp_enabled_at_start", 1)
    check_flag("esp_agl", 1)
    check_range("esp_roll_limit", 45, 60)
    check_range("esp_pitch_up", 10, 25)
    check_range("esp_pitch_down", 5, 25)
    check_range("esp_speed_max", 0, 1000)
    check_range("esp_speed_min", 0, 1000)
    check_range("esp_speed_min_margin", 1, 2)
    check_range("actuator_roll_authority", 0, 1)
    check_range("actuator_pitch_authority", 0, 1)
    check_range("actuator_slew_per_s", 0.05, 5)   -- 0 would engage but never push
    if config.esp_speed_max > 0 and config.esp_speed_min >= config.esp_speed_max then
        U.log("config.ini: esp_speed_min = " .. config.esp_speed_min .. " is not below esp_speed_max = "
            .. config.esp_speed_max .. ": ESP will push both ways")
    end
    -- absent = not provided: no dataref (logged when the port is registered).
    -- Present but invalid = logged and replaced by the default
    for _, k in ipairs(OPTIONAL_KEYS) do
        if not seen[k] then config[k] = nil end
    end
    if config.cap_digital ~= nil then check_flag("cap_digital", 1) end
    if config.cap_ias_mode ~= nil then check_flag("cap_ias_mode", 1) end
    if config.pft_s ~= nil then check_range("pft_s", 0, 60) end
    Sim.init(U)
    Esp.init(U, config)
    Act.init(U, config)
    Pft.init(U, config)
    return true
end

function XPluginEnable()
    if role == "passive" or loop then return true end
    loop = XPLMCreateFlightLoop({
        phase = XPLMFlightLoopPhaseType.xplm_FlightLoop_Phase_AfterFlightModel,
        callbackFunc = loop_cb,
        refcon = nil,
    })
    XPLMScheduleFlightLoop(loop, -1, true)
    if role == "provider" then
        U.log("enabled again: provider of laminar/afcs v" .. PORT_VERSION)
    end
    return true
end

function XPluginDisable()
    stop_loop()
end

function XPluginStop()
    stop_loop()
    unregister_port()
end

local MSG_PLANE_LOADED = XPLM_MSG_PLANE_LOADED or 102
local MSG_AIRPORT_LOADED = XPLM_MSG_AIRPORT_LOADED or 103

-- new flight: the pilot's switch back to its start value, nothing engaged,
-- the preflight test runs again. Filtered by message: X-Plane sends others
-- all the time (115 every minute)
function XPluginReceiveMessage(from, msg, param)
    if from ~= XPLM_PLUGIN_XPLANE then return end
    if msg == MSG_AIRPORT_LOADED or (msg == MSG_PLANE_LOADED and (param == 0 or param == nil)) then
        Esp.reset()
        Pft.restart()
    end
end

-- Offline tests only: the harness (tools/headless_test.py, the G5 project's
-- suite) sets AFCS_ESP_HARNESS = true in this script's environment before
-- loading it. In X-Plane that global does not exist and nothing is exported.
if AFCS_ESP_HARNESS == true then
    AFCS_ESP_TEST = {
        Esp = Esp, U = U, Pft = Pft, Act = Act, config = config,
        role = function() return role end,
        passive = function() return role == "passive" end,
        att_ok = function() return att_ok end,
    }
end
