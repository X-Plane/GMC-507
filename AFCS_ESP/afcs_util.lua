-- afcs_util.lua: helpers for the AFCS_ESP provider (log, math, ini, datarefs).
-- The dataref / command registration uses a few shared callbacks; the
-- refcon is the entry id.

local U = {}

U.LOG_PREFIX = "[AFCS_ESP] "

function U.log(msg)
    print(U.LOG_PREFIX .. tostring(msg))
end

-----------------------------------------------------------------------------
-- Math
-----------------------------------------------------------------------------

function U.clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

function U.sign(v)
    if v > 0 then return 1 elseif v < 0 then return -1 end
    return 0
end

-- move v toward target by at most step
function U.approach(v, target, step)
    if v < target then return math.min(v + step, target) end
    return math.max(v - step, target)
end

-----------------------------------------------------------------------------
-- config.ini: "key = value" lines, ; or # comments; keys must exist in
-- `defaults` (unknown keys are logged), values take the default's type
-----------------------------------------------------------------------------

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- seen (optional): filled with key -> true for every known key the file sets
function U.read_ini(path, defaults, seen)
    local f = io.open(path, "r")
    if not f then
        U.log(path:match("[^/\\]+$") .. " not found, using defaults: " .. path)
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
                    U.log(path:match("[^/\\]+$") .. ": unknown key '" .. key .. "' ignored")
                elseif type(d) == "number" then
                    if seen then seen[key] = true end
                    local n = tonumber(value)
                    if n == nil then
                        U.log(path:match("[^/\\]+$") .. ": " .. key .. " = '" .. value
                            .. "' is not a number, using " .. tostring(d))
                    elseif n ~= n or n == math.huge or n == -math.huge then
                        -- nan / inf pass tonumber; every comparison on them is false
                        U.log(path:match("[^/\\]+$") .. ": " .. key .. " = '" .. value
                            .. "' is not a finite number, using " .. tostring(d))
                        n = nil
                    end
                    defaults[key] = n or d
                else
                    if seen then seen[key] = true end
                    defaults[key] = string.lower(value)
                end
            end
        end
    end
    f:close()
    return true
end

-----------------------------------------------------------------------------
-- Reading and writing other plugins' / the sim's datarefs. A miss is not
-- cached: a dataref created by a script that loads later is found then.
-----------------------------------------------------------------------------

local found = {}

function U.find(name)
    local h = found[name]
    if h == nil then
        h = XPLMFindDataRef(name)
        if h then found[name] = h end
    end
    return h
end

function U.getf(name, default)
    local h = U.find(name)
    if not h then return default end
    local ok, v = pcall(XPLMGetDataf, h)
    if not ok or v ~= v then return default end   -- error or NaN
    return v
end

function U.geti(name, default)
    local h = U.find(name)
    if not h then return default end
    local ok, v = pcall(XPLMGetDatai, h)
    if not ok then return default end
    return v
end

function U.setf(name, v)
    local h = U.find(name)
    if h then pcall(XPLMSetDataf, h, v) end
end

function U.seti(name, v)
    local h = U.find(name)
    if h then pcall(XPLMSetDatai, h, v) end
end

-----------------------------------------------------------------------------
-- Our own datarefs and commands
-----------------------------------------------------------------------------

local acc = {}           -- id -> { getter, setter }
local acc_id = {}        -- dataref handle -> id
local cmds = {}          -- id -> handler
local next_id = 0

local function dr_get(ref)
    local e = acc[ref]
    if e == nil then return 0 end
    return e[1](ref) or 0
end

local function dr_set(ref, v)
    local e = acc[ref]
    if e and e[2] then e[2](ref, v) end
end

local function cmd_handler(cmd, phase, ref)
    local f = cmds[ref]
    if f == nil then return true end
    return f(cmd, phase, ref) ~= false
end

local function reg(name, int, getter, setter)
    next_id = next_id + 1
    local id = next_id
    acc[id] = { getter, setter }
    local set = setter and dr_set or nil
    local ok, h
    if int then
        ok, h = pcall(XPLMRegisterDataAccessor, name, XPLMDataTypeID.xplmType_Int, setter ~= nil,
            dr_get, set, nil, nil,
            nil, nil, nil, nil, nil, nil, nil, nil, id, id)
    else
        ok, h = pcall(XPLMRegisterDataAccessor, name, XPLMDataTypeID.xplmType_Float, setter ~= nil,
            nil, nil, dr_get, set,
            nil, nil, nil, nil, nil, nil, nil, nil, id, id)
    end
    if not ok then
        acc[id] = nil
        error(h, 0)
    end
    if h == nil then
        acc[id] = nil
    else
        acc_id[h] = id
    end
    return h
end

-- getter(ref) -> value; setter(ref, value) or nil for read-only
function U.reg_int(name, getter, setter) return reg(name, true, getter, setter) end
function U.reg_float(name, getter, setter) return reg(name, false, getter, setter) end

function U.unreg_dataref(h)
    if h == nil then return end
    XPLMUnregisterDataAccessor(h)
    local id = acc_id[h]
    if id then
        acc[id] = nil
        acc_id[h] = nil
    end
end

-- fn(cmd, phase, ref); returns the id to pass to U.unreg_cmd
function U.reg_cmd(cmd, fn)
    next_id = next_id + 1
    cmds[next_id] = fn
    XPLMRegisterCommandHandler(cmd, cmd_handler, true, next_id)
    return next_id
end

function U.unreg_cmd(cmd, id)
    if id == nil then return end
    XPLMUnregisterCommandHandler(cmd, cmd_handler, true, id)
    cmds[id] = nil
end

-- Listening to a sim command: a "before" handler that always returns 1, so
-- X-Plane still runs the command and every other handler still sees it
-- (an error in fn is logged, never swallows the command)
local function listen_handler(cmd, phase, ref)
    local f = cmds[ref]
    if f ~= nil then
        local ok, err = pcall(f, phase)
        if not ok then U.log("listener: " .. tostring(err)) end
    end
    return 1
end

-- fn(phase); returns { cmd, id } for U.unlisten, or nil (logged) when the
-- sim has no such command
function U.listen(name, fn)
    local cmd = XPLMFindCommand(name)
    if cmd == nil then
        U.log("command not found, listener skipped: " .. name)
        return nil
    end
    next_id = next_id + 1
    cmds[next_id] = fn
    XPLMRegisterCommandHandler(cmd, listen_handler, true, next_id)
    return { cmd, next_id }
end

function U.unlisten(l)
    if l == nil then return end
    XPLMUnregisterCommandHandler(l[1], listen_handler, true, l[2])
    cmds[l[2]] = nil
end

-- live entries (tests: nothing may be left after XPluginStop)
function U.live_callbacks()
    local n = 0
    for _ in pairs(acc) do n = n + 1 end
    for _ in pairs(cmds) do n = n + 1 end
    return n
end

return U
