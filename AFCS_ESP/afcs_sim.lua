-- afcs_sim.lua: the sim datarefs the provider reads, as one snapshot per
-- frame. Generic sim datarefs only, no device datarefs (SPEC.md).

local U

local Sim = {}

local H = {
    roll          = "sim/cockpit2/gauges/indicators/roll_AHARS_deg_pilot",
    pitch         = "sim/cockpit2/gauges/indicators/pitch_AHARS_deg_pilot",
    ias           = "sim/cockpit2/gauges/indicators/airspeed_kts_pilot",
    agl_m         = "sim/flightmodel/position/y_agl",
    vne           = "sim/aircraft/view/acf_Vne",
    vs1           = "sim/aircraft/view/acf_Vs",
    servos_on     = "sim/cockpit2/autopilot/servos_on",
    ap_has_power  = "sim/cockpit2/autopilot/autopilot_has_power",
    rel_otto      = "sim/operation/failures/rel_otto",
    rel_servos    = "sim/operation/failures/rel_auto_servos",
    rel_ahrs      = "sim/operation/failures/rel_g_arthorz",
    run_time      = "sim/time/total_running_time_sec",
}
Sim.NAMES = H

local FAILED = 6   -- failure_enum: inoperative

function Sim.init(util)
    U = util
end

local D = {}

function Sim.read()
    D.roll          = U.getf(H.roll, 0)
    D.pitch         = U.getf(H.pitch, 0)
    D.ias           = U.getf(H.ias, 0)
    D.agl_ft        = U.getf(H.agl_m, 0) * 3.28084
    D.vne           = U.getf(H.vne, 0)
    D.vs1           = U.getf(H.vs1, 0)
    D.servos_on     = U.geti(H.servos_on, 0)
    D.ap_has_power  = U.geti(H.ap_has_power, 1)
    D.otto_failed   = U.geti(H.rel_otto, 0) == FAILED
    D.servos_failed = U.geti(H.rel_servos, 0) == FAILED
    D.ahrs_failed   = U.geti(H.rel_ahrs, 0) == FAILED
    D.now           = U.getf(H.run_time, 0)
    return D
end

return Sim
