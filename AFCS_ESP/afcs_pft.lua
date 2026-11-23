-- afcs_pft.lua: the autopilot's preflight test (laminar/afcs/ap_pft). The
-- provider times it, so every display shows the same state.
--
--   0 = no test running: passed, not configured (pft_s = 0), or no autopilot
--       power
--   1 = running: pft_s seconds of sim time (total_running_time_sec) from
--       autopilot power-up; also from the first frame when the power is
--       already on, and again on a new flight
--   2 = failed: the autopilot or its servos had failed when the test ended.
--       Stays until the autopilot power is cycled
-- Power off: 0 at once.

local cfg

local P = { state = 0 }

local started = 0       -- sim time the running test began
local powered = nil     -- autopilot power last frame; nil = not seen yet

function P.init(util, config)
    cfg = config
    P.restart()
end

-- the next update starts a test if the autopilot has power (first frame,
-- new flight, provider enabled again)
function P.restart()
    P.state, powered = 0, nil
end

-- D: afcs_sim snapshot
function P.update(D)
    if (D.ap_has_power or 0) == 0 then
        P.state, powered = 0, false
        return
    end
    local now = D.now or 0
    if powered ~= true then
        powered, started = true, now
        P.state = ((cfg.pft_s or 0) > 0) and 1 or 0
    elseif P.state == 1 then
        if now < started then started = now end     -- sim time went back
        if now - started >= cfg.pft_s then
            P.state = (D.otto_failed or D.servos_failed) and 2 or 0
        end
    end
end

return P
