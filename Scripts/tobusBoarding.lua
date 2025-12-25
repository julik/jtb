if PLANE_ICAO == "A319" or PLANE_ICAO == "A20N" or PLANE_ICAO == "A320" or PLANE_ICAO == "A321" or
   PLANE_ICAO == "A21N" or PLANE_ICAO == "A346" or PLANE_ICAO == "A339"
then

local MY_PLANE_ICAO = PLANE_ICAO    -- may be stale now for A321 / A21N
local VERSION = "3.2.2-hotbso"

 --http library import
local json = require("json")
local socket = require "socket"
local http = require "socket.http"
local ltn12 = require "ltn12"
local LIP = require("LIP")

local HTTP_TIMEOUT_SECONDS = 0.5  -- max time for any HTTP request (SimBrief, Hoppie)

-- Create a socket with short total timeout
-- This ensures HTTP requests never block the sim loop for long
local function create_short_timeout_socket()
    local sock = socket.tcp()
    sock:settimeout(HTTP_TIMEOUT_SECONDS, 't')
    return sock
end

local kg2lbs = 2.204622
local wait_until_speak = 0
local speak_string

local tls_pax_no    -- dataref_table AirbusFBW/NoPax
local tank_content_array -- dataref_table
local MAX_PAX_NUMBER = 224

-- SimBrief OFP data (nil = not loaded, table = loaded)
-- Contains: operator, units, taxi_fuel, mzfw, mtow
local ofp_data = nil

local tls_flight_no       -- dataref_table for flight number

-- Operational variables
local pax_no_cur = 0
local pax_no_tgt = 0
local pax_no_deboarding = 0
local nextTimeBoardingCheck = 0
local s_per_pax = 4

local s_per_pax_cfg = 4 -- seconds per pax in cfg
local last_error = nil  -- nil = all good, string = error message (displayed in red)
local SETTINGS_FILENAME = "/tobus/tobus_settings.ini"
local SIMBRIEF_FLIGHTPLAN_FILENAME = "simbrief.json"
local SIMBRIEF_ACCOUNT_NAME = ""
local HOPPIE_LOGON = ""
local HOPPIE_CPDLC = true
local RANDOMIZE_SIMBRIEF_PASSENGER_NUMBER = false
local USE_SECOND_DOOR = false
local CLOSE_DOORS = true
local LEAVE_DOOR1_OPEN = true

local jw1_connected = false     -- set if an opensam jw at the second door is detected
local opensam_door_status = nil
if nil ~= XPLMFindDataRef("opensam/jetway/door/status") then
	opensam_door_status = dataref_table("opensam/jetway/door/status")
end

local delayed_init_delay = 10   -- let the dust settle, seconds before delayed init

-------------------------------------------------------------------------------
-- Logging
-------------------------------------------------------------------------------

local function log_msg(str)
    local temp = os.date("*t", os.time())
    logMsg(string.format("tobus: %02d:%02d:%02d %s", temp.hour, temp.min, temp.sec, str))
end

-------------------------------------------------------------------------------
-- State Machine
-------------------------------------------------------------------------------

local State = {
    READY = "ready",
    BOARDING = "boarding",
    BOARDING_PAUSED = "boarding_paused",
    DEBOARDING = "deboarding",
    DEBOARDING_PAUSED = "deboarding_paused",
}

local current_state = State.READY

-------------------------------------------------------------------------------
-- Timer System
-------------------------------------------------------------------------------

local Timers = {
    active = {},  -- {name -> {fire_at, callback}}
}

function Timers.schedule(name, delay_seconds, callback)
    Timers.active[name] = {
        fire_at = os.time() + delay_seconds,
        callback = callback,
    }
    log_msg(string.format("Timer '%s' scheduled for %ds", name, delay_seconds))
end

function Timers.cancel(name)
    if Timers.active[name] then
        Timers.active[name] = nil
        log_msg(string.format("Timer '%s' cancelled", name))
    end
end

function Timers.cancel_all()
    local count = 0
    for name, _ in pairs(Timers.active) do
        count = count + 1
    end
    if count > 0 then
        log_msg(string.format("Cancelling %d timer(s)", count))
        Timers.active = {}
    end
end

function Timers.tick()
    local now = os.time()
    for name, timer in pairs(Timers.active) do
        if now >= timer.fire_at then
            Timers.active[name] = nil  -- remove before callback (allows reschedule)
            log_msg(string.format("Timer '%s' fired", name))
            timer.callback()
        end
    end
end

local plane_db = {
    A319_160 = {
        cfg = "A319_160",
        max_pax = 160,
        oew = 40820,
        cg_data = {
            pax_tab   = {   0,   20,   40,   60,   80,  100,  120,  140,  160},
            zfwcg_035 = {28.6, 25.6, 23.7, 22.7, 22.6, 23.2, 24.4, 26.2, 28.6},
            zfwcg_050 = {28.6, 28.6, 28.6, 28.6, 28.6, 28.6, 28.6, 28.6, 28.6},
            zfwcg_060 = {28.6, 32.1, 31.9, 32.5, 32.6, 32.2, 31.4, 30.2, 28.6}
        }
    },

    A319 = {
        cfg = "A319",
        max_pax = 145,
        oew = 40820,
        cg_data = {
            pax_tab   = {   0,   20,   40,   60,   80,  100,  120,  145},
            zfwcg_035 = {28.6, 25.6, 23.8, 23.1, 23.2, 24.1, 25.7, 28.6},
            zfwcg_050 = {28.6, 28.6, 28.6, 28.6, 28.6, 28.6, 28.6, 28.6},
            zfwcg_060 = {28.6, 30.6, 31.8, 32.3, 32.2, 31.6, 30.5, 28.6}
        }
    },

    A320 = {
        cfg = "A320",
        max_pax = 176,
        oew = 43420,
        cg_data = {
            pax_tab   = {   0,   25,   50,   75,  100,  125,  150,  175,  186},
            zfwcg_035 = {28.5, 24.4, 21.9, 20.7, 20.8, 21.8, 23.7, 26.3, 28.0 },
            zfwcg_050 = {28.5, 28.4, 28.4, 28.3, 28.3, 28.3, 28.2, 28.0, 28.0 },
            zfwcg_060 = {28.5, 31.1, 32.7, 33.4, 33.3, 32.6, 31.1, 29.3, 28.0 }
        }
    },

    A20N = {
        cfg = "A20N",
        max_pax = 188,
        oew = 44220,
        cg_data = {
            pax_tab   = {   0,   25,   50,   75,  100,  125,  150,  175,  188},
            zfwcg_035 = {29.5, 25.4, 22.9, 21.7, 21.8, 22.8, 24.8, 27.5, 29.2},
            zfwcg_050 = {29.5, 29.4, 29.4, 29.3, 29.3, 29.3, 29.3, 29.2, 29.2},
            zfwcg_060 = {29.5, 32.1, 33.7, 34.4, 34.3, 33.6, 32.2, 30.5, 29.2}
        }
    },

    A321 = {
        cfg = "A321",
        max_pax = 220,
        oew = 47780,
        cg_data = {
            pax_tab   = {   0,   25,   50,   75,  100,  125,  150,  175,  200,  220},
            zfwcg_035 = {27.5, 22.5, 19.2, 17.4, 17.2, 17.5, 19.1, 21.5, 24.8, 27.9},
            zfwcg_050 = {27.5, 27.6, 27.6, 27.7, 27.7, 27.7, 27.8, 27.8, 27.8, 27.9},
            zfwcg_060 = {27.5, 30.9, 33.1, 34.3, 34.5, 34.4, 33.4, 31.9, 29.8, 27.9}
        }
    },

    A21N = {
        cfg = "A21N",
        max_pax = 244,
        oew = 49580,
        cg_data = {
            pax_tab   = {   0,   25,   50,   75,  100,  125,  150,  175,  200,  225, 244},
            zfwcg_035 = {29.1, 24.3, 20.9, 18.9, 18.0, 18.1, 19.0, 20.8, 23.2, 26.2, 28.9},
            zfwcg_050 = {29.1, 29.1, 29.1, 29.1, 29.0, 29.0, 29.0, 29.0, 29.0, 29.0, 28.9},
            zfwcg_060 = {27.5, 32.3, 34.5, 35.8, 36.4, 36.3, 35.7, 34.5, 32.8, 30.8, 29.1}
        }
    },

    -- without third door
    A21N_200 = {
        cfg = "A21N",
        max_pax = 200,
        oew = 49580,
        cg_data = {
            pax_tab   = {   0,   25,   50,   75,  100,  125,  150,  175,  200},
            zfwcg_035 = {29.1, 24.4, 21.4, 19.9, 19.7, 20.9, 22.5, 25.3, 29.0},
            zfwcg_050 = {29.1, 29.1, 29.1, 29.1, 29.0, 29.0, 29.0, 29.0, 29.0},
            zfwcg_060 = {29.1, 32.2, 34.2, 35.2, 35.3, 34.6, 33.3, 31.4, 29.0}
        }
    },

    A339 = {
        cfg = "A339",
        max_pax = 375,
        oew = 134500,
        cg_data = {
            pax_tab   = {   0,   25,   50,   75,  100,  125,  150,  175,  200,  225,  250,  275,  300,  325,  350,  375},
            zfwcg_035 = {27.5, 26.0, 24.8, 23.8, 23.1, 22.6, 22.2, 22.1, 22.2, 22.5, 22.9, 23.5, 24.3, 25.2, 26.3, 27.5},
            zfwcg_050 = {27.5, 27.5, 27.5, 27.5, 27.5, 27.5, 27.5, 27.5, 27.5, 27.5, 27.5, 27.5, 27.5, 27.5, 27.5, 27.5},
            zfwcg_060 = {27.5, 28.5, 29.4, 30.0, 30.5, 30.9, 31.1, 31.2, 31.1, 30.9, 30.6, 30.2, 29.7, 29.0, 28.3, 27.5}
        }
    },

    A346 = {
        cfg = "A346",
        max_pax = 440,
        oew = 185500,
        -- volunteers welcome for building the cg table
    }
}

local plane_data    -- of the current plane

-- gaussian distribution
local function gauss(mu, sigma)
    -- central limit theorem with a sum of 12 should be good enough here
    local s = 0
    for i = 1, 12 do
        s = s + math.random()
    end
    return sigma * (s - 6) + mu
end

local function clamp(val, min, max)
    if val < min then return min end
    if val > max then return max end
    return val
end

-- Set error, log it, and speak it aloud
local function set_last_error(message)
    last_error = message
    log_msg("ERROR: " .. message)
    speak_string = message
    wait_until_speak = os.time() + 0.5
end

-------------------------------------------------------------------------------
-- HTTP Helpers (with short timeouts and retries to avoid blocking sim loop)
-------------------------------------------------------------------------------

local HTTP_MAX_ATTEMPTS = 3  -- max retry attempts for HTTP requests

-- In-progress HTTP requests: {name -> {method, url, form_data, attempts_left, on_done}}
local http_requests = {}

-- Check if an HTTP request is in progress
local function http_in_progress(name)
    return http_requests[name] ~= nil
end

-- Single HTTP attempt (short timeout). Returns body on success, nil on failure.
local function http_try_once(method, url, form_data)
    local response_body = {}
    local request_params = {
        url = url,
        sink = ltn12.sink.table(response_body),
        create = create_short_timeout_socket,
    }
    if method == "POST" then
        request_params.method = "POST"
        request_params.headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
            ["Content-Length"] = tostring(#form_data),
        }
        request_params.source = ltn12.source.string(form_data)
    end

    local result, code = http.request(request_params)
    if code == 200 then
        return table.concat(response_body)
    end
    log_msg(string.format("HTTP %s %s - code=%s", method, url:sub(1, 50), tostring(code)))
    return nil
end

-- Try request, schedule retry on failure
local function http_try(name)
    local req = http_requests[name]
    if not req then return end

    local body = http_try_once(req.method, req.url, req.form_data)
    if body then
        http_requests[name] = nil
        if req.on_done then req.on_done(body) end
        return
    end

    req.attempts_left = req.attempts_left - 1
    if req.attempts_left > 0 then
        Timers.schedule("http_" .. name, 0.5, function() http_try(name) end)
    else
        log_msg(string.format("HTTP %s failed after retries: %s", req.method, name))
        http_requests[name] = nil
        if req.on_done then req.on_done(nil) end
    end
end

-- HTTP GET with automatic retries. on_done(body) called with body or nil on failure.
local function http_get(name, url, on_done)
    http_requests[name] = {method = "GET", url = url, attempts_left = HTTP_MAX_ATTEMPTS, on_done = on_done}
    http_try(name)
end

-- HTTP POST with automatic retries. on_done(body) called with body or nil on failure.
local function http_post(name, url, form_data, on_done)
    http_requests[name] = {method = "POST", url = url, form_data = form_data, attempts_left = HTTP_MAX_ATTEMPTS, on_done = on_done}
    http_try(name)
end

-- Check if aircraft is in motion (unsafe for ground operations)
-- Returns true if groundspeed or rotation rates indicate flight/taxi
local function flight_in_progress()
    -- Groundspeed in m/s (0.5 m/s ≈ 1 knot)
    local groundspeed = get("sim/flightmodel/position/groundspeed")
    if groundspeed > 0.5 then
        return true, string.format("Aircraft moving (%.1f m/s)", groundspeed)
    end

    -- Rotation rates in degrees/second
    local P = math.abs(get("sim/flightmodel/position/P"))  -- roll rate
    local Q = math.abs(get("sim/flightmodel/position/Q"))  -- pitch rate
    local R = math.abs(get("sim/flightmodel/position/R"))  -- yaw rate

    if P > 1.0 or Q > 1.0 or R > 1.0 then
        return true, string.format("Aircraft rotating (P=%.1f Q=%.1f R=%.1f deg/s)", P, Q, R)
    end

    -- Beacon on = ground crew should not approach
    local beacon_on = get("sim/cockpit/electrical/beacon_lights_on") == 1
    if beacon_on then
        return true, "Beacon is on - ground services unavailable"
    end

    return false, nil
end

-- stepwise linear interpolation
local function tab_interpolate(pax_tab, zfwcg_tab, pax_no)
    local n = #pax_tab
    if pax_no >= pax_tab[n] then
        return zfwcg_tab[n]
    end

    for i = 1, n - 1 do
        local pax0 = pax_tab[i]
        local pax1 = pax_tab[i + 1]
        if pax0 <= pax_no and pax_no < pax1 then
            local x = (pax_no - pax0) / (pax1 - pax0)
            return zfwcg_tab[i] + x * (zfwcg_tab[i + 1] - zfwcg_tab[i])
        end
    end
end

-- get the ZFWCG
local function get_zfwcg(cg_data)
    local pax_distrib = get("AirbusFBW/PaxDistrib")
    local pax_no = get("AirbusFBW/NoPax")

    local zfwcg_050 = tab_interpolate(cg_data.pax_tab, cg_data.zfwcg_050, pax_no)

    local zfwcg
    if pax_distrib <= 0.5 then
        local f = (pax_distrib - 0.35) / (0.5 - 0.35)
        local zfwcg_035 = tab_interpolate(cg_data.pax_tab, cg_data.zfwcg_035, pax_no)
        zfwcg = (1 - f) * zfwcg_035 + f * zfwcg_050
    else
        local f = (pax_distrib - 0.5) / (0.6 - 0.5)
        local zfwcg_060 = tab_interpolate(cg_data.pax_tab, cg_data.zfwcg_060, pax_no)
        zfwcg = (1 - f) * zfwcg_050 + f * zfwcg_060
    end

    return pax_no, pax_distrib, zfwcg
end

local function format_ls_row(label, value, digit)
    return label .. string.rep(".", digit - #label - #value) .. " @" .. value .. "@ "
end

local function send_loadsheet(ls_content)
    if not ofp_data then return end  -- guard against missing OFP data

    -- Read flight number fresh from FMGS each time we send
    local flight_no = ""
    if tls_flight_no then
        flight_no = tls_flight_no[0] or ""
    end

    if flight_no == "" then
        set_last_error("Cannot send loadsheet: flight number not set in MCDU INIT page")
        return
    end

    ls_content = ls_content:gsub("\n", "%%0A")

    local form_data
    if HOPPIE_CPDLC then
        form_data = string.format("logon=%s&from=%s&to=%s&type=%s&packet=%s",
            HOPPIE_LOGON,
            ofp_data.operator .. "OPS",
            flight_no,
            'cpdlc',
            "/data2/313//NE/" .. ls_content)
    else
        form_data = string.format("logon=%s&from=%s&to=%s&type=%s&packet=%s",
            HOPPIE_LOGON,
            ofp_data.operator .. "OPS",
            flight_no,
            'telex',
            ls_content)
    end

    log_msg(form_data:gsub("logon=[^&]+", "logon=***"))

    -- Send via Hoppie with automatic retries
    http_post("hoppie_loadsheet", "https://www.hoppie.nl/acars/system/connect.html", form_data,
        function(body)
            if body then
                log_msg("Hoppie response: " .. body)
            else
                set_last_error("Failed to send loadsheet to Hoppie")
            end
        end
    )
end

local function generate_final_loadsheet()
    if not ofp_data or HOPPIE_LOGON == "" then
        log_msg("LOADSHEET UNAVAIL DUE TO NO SIMBRIEF DATA OR MISSING HOPPIE LOGIN")
        return
    end

    local cargo_kg = math.ceil(get("AirbusFBW/FwdCargo") + get("AirbusFBW/AftCargo"))

    local fob_kg = 0
    for i = 0,8 do
        fob_kg = fob_kg + tank_content_array[i]
    end

    local fob_uu
    if ofp_data.units == "lbs" then
        fob_uu = 100 * math.floor(fob_kg * kg2lbs / 100 + 0.35)    -- conservative rounding
    else
        fob_uu = 100 * math.floor(fob_kg / 100 + 0.35)
    end

    local zfw_kg = plane_data.oew + cargo_kg + tls_pax_no[0] * 100 -- hard coded pax weight of 100kg by ToLiss
    local zfw_uu = zfw_kg
    if ofp_data.units == "lbs" then
        zfw_uu = zfw_kg * kg2lbs
    end

    log_msg(string.format("fob_kg: %d, fob_uu: %d, zfw_kg: %d, zfw_uu: %d",
            fob_kg, fob_uu, zfw_kg, zfw_uu))

    local tow_uu = zfw_uu + fob_uu - ofp_data.taxi_fuel

    local zfwcg = "EFB"
    if cargo_kg <= 20 then  -- cargo is currently unsupported, account for rounding errors
        local cg_data = plane_data.cg_data
        if cg_data ~= nil then
            local pn, pd
            pn, pd, zfwcg = get_zfwcg(cg_data)
            log_msg(string.format("get_zfwcg: %s, distrib: %0.1f, pax_no: %d, zfwcg: %0.1f",
                                   plane_data.cfg, pd, pn, zfwcg))
            zfwcg = string.format("%0.1f", zfwcg)
        end
    end

    local ls = {    -- in user units
        title = "Final",
        gwcg = string.format("%0.1f", get("AirbusFBW/CGLocationPercent")),
        zfw = string.format("%0.1f", zfw_uu / 1000),
        zfwcg = zfwcg, -- meaning: ls.zfwcg = zfwcg
        tow = string.format("%0.1f", tow_uu / 1000),
        fob = string.format("%d", fob_uu),
        pax = string.format("%d", tls_pax_no[0])
    }

    if zfw_uu > ofp_data.mzfw or tow_uu > ofp_data.mtow then
        ls.msg = "LOAD+DISCREPANCY:+RETURN+TO+GATE"
    else
        ls.msg = nil
    end

    local ls_content = table.concat({
        "Loadsheet @" .. ls.title .. "@ " .. os.date("%H:%M"),
        format_ls_row("PAX", ls.pax, 9),
        format_ls_row("ZFW",  ls.zfw, 9),
        format_ls_row("ZFWCG", ls.zfwcg, 9),
        format_ls_row("TOW", ls.tow, 9),
        format_ls_row("GWCG", ls.gwcg, 9),
        format_ls_row("FOB", ls.fob, 9),
        format_ls_row("UNITS", ofp_data.units, 9),
    }, "\n")

    if ls.msg ~= nil then
        ls_content = ls_content .. "\n" .. ls.msg
    end

    send_loadsheet(ls_content)
end

local function generate_prelim_loadsheet()
    if not ofp_data or HOPPIE_LOGON == "" then
        log_msg("LOADSHEET UNAVAIL DUE TO NO SIMBRIEF DATA OR MISSING HOPPIE LOGIN")
        return
    end

    local block_fuel_kg = get("toliss_airbus/init/BlockFuel")
    local zfw_kg = plane_data.oew + pax_no_tgt * 100 -- hard coded pax weight of 100kg by ToLiss
    local zfwcg = get("toliss_airbus/init/ZFWCG")

    local block_fuel_uu
    if ofp_data.units == "lbs" then
        block_fuel_uu = 100 * math.floor(block_fuel_kg * kg2lbs / 100 + 0.35)    -- conservative rounding
    else
        block_fuel_uu = 100 * math.floor(block_fuel_kg / 100 + 0.35)
    end

    local zfw_uu = zfw_kg
    if ofp_data.units == "lbs" then
        zfw_uu = zfw_kg * kg2lbs
    end

    log_msg(string.format("block_fuel_kg: %d, block_fuel_uu: %d, zfw_kg: %d, zfw_uu: %d",
            block_fuel_kg, block_fuel_uu, zfw_kg, zfw_uu))

    local tow_uu = zfw_uu + block_fuel_uu - ofp_data.taxi_fuel

    local ls = {    -- in user units
        title = "Prelim",
        -- gwcg = string.format("%0.1f", get("AirbusFBW/CGLocationPercent")),
        zfw = string.format("%0.1f", zfw_uu / 1000),
        zfwcg = string.format("%0.1f", zfwcg), -- meaning: ls.zfwcg = zfwcg
        tow = string.format("%0.1f", tow_uu / 1000),
        fob = string.format("%d", block_fuel_uu),
        pax = string.format("%d", pax_no_tgt)
    }

    if zfw_uu > ofp_data.mzfw or tow_uu > ofp_data.mtow then
        ls.msg = "LOAD+DISCREPANCY:+CHECK"
    else
        ls.msg = nil
    end

    local ls_content = table.concat({
        "Loadsheet @" .. ls.title .. "@ " .. os.date("%H:%M"),
        format_ls_row("PAX", ls.pax, 9),
        format_ls_row("ZFW",  ls.zfw, 9),
        format_ls_row("ZFWCG", ls.zfwcg, 9),
        format_ls_row("TOW", ls.tow, 9),
        -- format_ls_row("GWCG", ls.gwcg, 9),
        format_ls_row("BFUEL", ls.fob, 9),
        format_ls_row("UNITS", ofp_data.units, 9),
    }, "\n")

    if ls.msg ~= nil then
        ls_content = ls_content .. "\n" .. ls.msg
    end

    send_loadsheet(ls_content)
end

local function open_doors()
    passengerDoorArray[0] = 2
    if USE_SECOND_DOOR or jw1_connected then
        if MY_PLANE_ICAO == "A319" or MY_PLANE_ICAO == "A20N" or MY_PLANE_ICAO == "A320" or MY_PLANE_ICAO == "A339" then
            passengerDoorArray[2] = 2
        end
        if MY_PLANE_ICAO == "A321" or MY_PLANE_ICAO == "A21N" or MY_PLANE_ICAO == "A346" then
            passengerDoorArray[6] = 2
        end
    end
    cargoDoorArray[0] = 2
    cargoDoorArray[1] = 2
end

local function close_doors()
    if not CLOSE_DOORS then return end

    if not LEAVE_DOOR1_OPEN then
        passengerDoorArray[0] = 0
    end

    if USE_SECOND_DOOR or jw1_connected then
        if MY_PLANE_ICAO == "A319" or MY_PLANE_ICAO == "A20N" or MY_PLANE_ICAO == "A320" or MY_PLANE_ICAO == "A339" then
            passengerDoorArray[2] = 0
        end

        if MY_PLANE_ICAO == "A321" or MY_PLANE_ICAO == "A21N" or MY_PLANE_ICAO == "A346" or MY_PLANE_ICAO == "A339" then
            passengerDoorArray[6] = 0
        end
    end
    cargoDoorArray[0] = 0
    cargoDoorArray[1] = 0
end

local function play_chime_sound(boarding)
    command_once( "AirbusFBW/CheckCabin" )
    if boarding then
        speak_string = "Boarding Completed"
    else
        speak_string = "Deboarding Completed"
    end

    wait_until_speak = os.time() + 0.5
end

-------------------------------------------------------------------------------
-- State Transitions
-------------------------------------------------------------------------------

local function on_exit_state(state)
    -- Cleanup when leaving a state
    if state == State.BOARDING_PAUSED or state == State.DEBOARDING_PAUSED then
        -- If leaving paused state via Reset, close doors (handled in transition_to)
    end
end

local function on_enter_state(state, from_state)
    if state == State.READY then
        -- Check if we completed an operation
        if from_state == State.BOARDING and pax_no_cur == pax_no_tgt then
            -- Boarding just completed
            play_chime_sound(true)
            Timers.cancel("prelim_loadsheet")  -- final supersedes prelim
            Timers.schedule("close_doors", 30, close_doors)
            Timers.schedule("final_loadsheet", 60, generate_final_loadsheet)
        elseif from_state == State.DEBOARDING and get("AirbusFBW/NoPax") == 0 then
            -- Deboarding just completed
            play_chime_sound(false)
            close_doors()
        elseif from_state == State.BOARDING_PAUSED or from_state == State.DEBOARDING_PAUSED then
            -- User clicked Reset - close doors, no chime
            close_doors()
        end

    elseif state == State.BOARDING then
        open_doors()
        set("AirbusFBW/NoPax", 0)
        pax_no_cur = 0
        set("AirbusFBW/PaxDistrib", clamp(gauss(0.5, 0.1), 0.35, 0.6))
        -- Calculate effective speed based on door configuration
        if USE_SECOND_DOOR or jw1_connected then
            s_per_pax = s_per_pax_cfg / 2
        else
            s_per_pax = s_per_pax_cfg
        end
        nextTimeBoardingCheck = os.time()

    elseif state == State.DEBOARDING then
        open_doors()
        pax_no_deboarding = tls_pax_no[0]
        pax_no_cur = pax_no_deboarding
        -- Calculate effective speed based on door configuration
        if USE_SECOND_DOOR or jw1_connected then
            s_per_pax = s_per_pax_cfg / 2
        else
            s_per_pax = s_per_pax_cfg
        end
        nextTimeBoardingCheck = os.time()

    -- BOARDING_PAUSED and DEBOARDING_PAUSED have no entry actions
    end
end

local function transition_to(new_state)
    if current_state == new_state then
        return  -- No-op if already in this state
    end

    -- Cancel all timers on state transition (user took action)
    Timers.cancel_all()

    -- Run exit actions for old state
    on_exit_state(current_state)

    local old_state = current_state
    current_state = new_state

    -- Run entry actions for new state
    on_enter_state(new_state, old_state)

    log_msg(string.format("State: %s -> %s", old_state, new_state))
end

-- Precondition checks
local function can_start_boarding()
    if current_state ~= State.READY then
        return false, "Operation already in progress"
    end
    local in_flight, reason = flight_in_progress()
    if in_flight then
        return false, reason
    end
    if pax_no_tgt <= 0 then
        return false, "Set passenger target first"
    end
    local current_pax = get("AirbusFBW/NoPax")
    if current_pax > 0 then
        return false, "Deboard all passengers first"
    end
    return true, nil
end

local function can_start_deboarding()
    if current_state ~= State.READY then
        return false, "Operation already in progress"
    end
    local in_flight, reason = flight_in_progress()
    if in_flight then
        return false, reason
    end
    local current_pax = get("AirbusFBW/NoPax")
    if current_pax <= 0 then
        return false, "No passengers to deboard"
    end
    return true, nil
end

local function board_instantly()
    open_doors()
    set("AirbusFBW/NoPax", pax_no_tgt)
    pax_no_cur = pax_no_tgt
    set("AirbusFBW/PaxDistrib", clamp(gauss(0.5, 0.1), 0.35, 0.6))
    command_once("AirbusFBW/SetWeightAndCG")
    -- Transition directly to READY with boarding complete actions
    current_state = State.BOARDING  -- Set temporarily so on_enter_state knows we came from BOARDING
    transition_to(State.READY)
end

local function deboard_instantly()
    open_doors()
    tls_pax_no[0] = 0
    pax_no_cur = 0
    command_once("AirbusFBW/SetWeightAndCG")
    -- Transition directly to READY with deboarding complete actions
    current_state = State.DEBOARDING  -- Set temporarily so on_enter_state knows we came from DEBOARDING
    transition_to(State.READY)
end

-- Instantly set pax to target (bypasses all rules, for setup/edge cases)
-- This resets script state to READY - no chimes, no loadsheets, no timers
local function set_instantly()
    local current_pax = get("AirbusFBW/NoPax")
    if current_pax == pax_no_tgt then
        return  -- Nothing to do
    end

    -- Set pax count directly
    set("AirbusFBW/NoPax", pax_no_tgt)
    pax_no_cur = pax_no_tgt
    set("AirbusFBW/PaxDistrib", clamp(gauss(0.5, 0.1), 0.35, 0.6))
    command_once("AirbusFBW/SetWeightAndCG")

    -- Reset to clean READY state (no state machine side effects)
    current_state = State.READY
    Timers.cancel_all()

    -- Only close doors if we boarded to a target (not if we emptied/reduced)
    if pax_no_tgt > 0 then
        close_doors()
    end

    log_msg(string.format("Instant set: %d -> %d pax (state reset)", current_pax, pax_no_tgt))
end

local function reset_all_parameters()
    pax_no_cur = 0
    pax_no_tgt = 0
    current_state = State.READY
    Timers.cancel_all()
    nextTimeBoardingCheck = os.time()
    -- s_per_pax is calculated when entering BOARDING/DEBOARDING states
    -- to account for both USE_SECOND_DOOR and jw1_connected at that moment
    s_per_pax = s_per_pax_cfg
    jw1_connected = false
end

local function read_settings()
    local f = io.open(SCRIPT_DIRECTORY..SETTINGS_FILENAME)
    if f == nil then return end

    f:close()
    local settings = LIP.load(SCRIPT_DIRECTORY..SETTINGS_FILENAME)

    settings.simbrief = settings.simbrief or {}    -- for backwards compatibility
    settings.hoppie = settings.hoppie or {}    -- for backwards compatibility
    settings.doors = settings.doors or {}
    settings.speed = settings.speed or {}

    if settings.simbrief.username ~= nil then
        SIMBRIEF_ACCOUNT_NAME = settings.simbrief.username
    end

    if settings.hoppie.logon ~= nil then
        HOPPIE_LOGON = settings.hoppie.logon
    end

    if settings.hoppie.cpdlc ~= nil then
        HOPPIE_CPDLC = settings.hoppie.cpdlc
    end

    if settings.simbrief.randomizePassengerNumber ~= nil then
        RANDOMIZE_SIMBRIEF_PASSENGER_NUMBER = settings.simbrief.randomizePassengerNumber
    end

    if settings.doors.useSecondDoor ~= nil then
        USE_SECOND_DOOR = settings.doors.useSecondDoor
    end

    if settings.doors.closeDoors ~= nil then
        CLOSE_DOORS = settings.doors.closeDoors
    end

    if settings.doors.leaveDoor1Open ~= nil then
        LEAVE_DOOR1_OPEN = settings.doors.leaveDoor1Open
    end

    if settings.speed.secondsPerPax ~= nil then
        s_per_pax_cfg = settings.speed.secondsPerPax
    end
end

local function save_settings()
    log_msg("tobus: save_settings...")
    local newSettings = {}
    newSettings.simbrief = {}
    newSettings.simbrief.username = SIMBRIEF_ACCOUNT_NAME
    newSettings.simbrief.randomizePassengerNumber = RANDOMIZE_SIMBRIEF_PASSENGER_NUMBER
    newSettings.speed = {}
    newSettings.speed.secondsPerPax = s_per_pax_cfg

    newSettings.hoppie = {}
    newSettings.hoppie.logon = HOPPIE_LOGON
    newSettings.hoppie.cpdlc = HOPPIE_CPDLC

    newSettings.doors = {}
    newSettings.doors.useSecondDoor = USE_SECOND_DOOR
    newSettings.doors.closeDoors = CLOSE_DOORS
    newSettings.doors.leaveDoor1Open = LEAVE_DOOR1_OPEN
    LIP.save(SCRIPT_DIRECTORY..SETTINGS_FILENAME, newSettings)
    log_msg("tobus: done")
end

-- Process SimBrief response (called on successful fetch)
local function process_simbrief_response(response)
    local f = io.open(SCRIPT_DIRECTORY..SIMBRIEF_FLIGHTPLAN_FILENAME, "w")
    f:write(response)
    f:close()

    log_msg("Simbrief JSON data downloaded")

    -- Parse JSON
    local ofp = json.decode(response)

    if ofp.fetch.status ~= "Success" then
      set_last_error("SimBrief fetch failed: " .. tostring(ofp.fetch.status))
      return
    end

    -- Validate aircraft type matches
    local ofp_icao = ofp.aircraft.icaocode
    log_msg(string.format("OFP aircraft: %s, loaded aircraft: %s", ofp_icao, MY_PLANE_ICAO))

    if ofp_icao ~= MY_PLANE_ICAO then
      set_last_error(string.format("Aircraft mismatch: OFP is for %s, but %s is loaded", ofp_icao, MY_PLANE_ICAO))
      return
    end

    -- Extract OFP data into table
    pax_no_tgt = tonumber(ofp.weights.pax_count)

    local max_pax = ofp.aircraft.max_passengers
    log_msg(string.format("max_pax: '%s'", max_pax))
    MAX_PAX_NUMBER = tonumber(max_pax)
    if MY_PLANE_ICAO == "A319" and MAX_PAX_NUMBER == 160 then
        plane_data = plane_db["A319_160"]
        log_msg("A319 with MAX_PAX_NUMBER 160 variant loaded")
    end

    if MAX_PAX_NUMBER ~= plane_data.max_pax then
        log_msg(string.format("max. pax no mismatch: ofp: %d config: %d", MAX_PAX_NUMBER, plane_data.max_pax))
    end

    if RANDOMIZE_SIMBRIEF_PASSENGER_NUMBER then
        local f = clamp(gauss(1.0, 0.025), 0.96, 1.04)
        pax_no_tgt = math.floor(pax_no_tgt * f + 0.5)
        if pax_no_tgt > MAX_PAX_NUMBER then pax_no_tgt = MAX_PAX_NUMBER end
        log_msg(string.format("randomized pax_no_tgt: %d", pax_no_tgt))
    end

    -- Store OFP data for loadsheet generation
    ofp_data = {
        operator = ofp.general.icao_airline,
        units = ofp.params.units,
        taxi_fuel = tonumber(ofp.fuel.taxi),
        mzfw = tonumber(ofp.weights.max_zfw),
        mtow = tonumber(ofp.weights.max_tow),
    }

    log_msg("SimBrief OFP loaded successfully")
end

local function fetch_data()
    last_error = nil  -- clear any previous error
    ofp_data = nil    -- clear previous OFP data (allows retry)

    if SIMBRIEF_ACCOUNT_NAME == nil or SIMBRIEF_ACCOUNT_NAME == "" then
      set_last_error("No SimBrief username configured")
      return
    end

    local url = "http://www.simbrief.com/api/xml.fetcher.php?username=" .. SIMBRIEF_ACCOUNT_NAME .. "&json=1"

    http_get("simbrief_ofp", url, function(body)
        if body then
            process_simbrief_response(body)
        else
            set_last_error("SimBrief API error after multiple attempts")
        end
    end)
end

local function delayed_init()
    if tls_pax_no ~= nil then return end

    local plane_icao = get("sim/aircraft/view/acf_ICAO")
    local i0 = string.find(plane_icao, "\0")
    if i0 ~= nil then
        MY_PLANE_ICAO = string.sub(plane_icao, 1, i0 - 1)
    else
        MY_PLANE_ICAO = plane_icao
    end

    tls_flight_no = dataref_table("toliss_airbus/init/flight_no")

    tls_pax_no = dataref_table("AirbusFBW/NoPax")
    passengerDoorArray = dataref_table("AirbusFBW/PaxDoorModeArray")
    cargoDoorArray = dataref_table("AirbusFBW/CargoDoorModeArray")
    tank_content_array = dataref_table("toliss_airbus/fuelTankContent_kgs")

    if MY_PLANE_ICAO == "A21N" and get("AirbusFBW/A321ExitConfig") == 3 then    -- no door 3
        plane_data = plane_db["A21N_200"]
        log_msg("A21N with MAX_PAX_NUMBER 200 variant loaded")
    else
        plane_data = plane_db[MY_PLANE_ICAO]
        log_msg(MY_PLANE_ICAO .. " variant loaded")
    end

    MAX_PAX_NUMBER = plane_data.max_pax

    log_msg(string.format("tobus: plane: '%s', MAX_PAX_NUMBER: %d", MY_PLANE_ICAO, MAX_PAX_NUMBER))

    reset_all_parameters()
end

function tobus_on_build(tobus_window, x, y)
    -- Display error prominently at top if any
    if last_error ~= nil then
        imgui.PushStyleColor(imgui.constant.Col.Text, 0xFF4444FF)  -- red
        imgui.TextUnformatted(last_error)
        imgui.PopStyleColor()
    end

    -- Status display based on current state
    if current_state == State.BOARDING then
        imgui.PushStyleColor(imgui.constant.Col.Text, 0xFF95FFF8)
        imgui.TextUnformatted(string.format("Boarding in progress %d / %d boarded", pax_no_cur, pax_no_tgt))
        imgui.PopStyleColor()
    elseif current_state == State.BOARDING_PAUSED then
        imgui.PushStyleColor(imgui.constant.Col.Text, 0xFFFFAA00)
        imgui.TextUnformatted(string.format("Boarding PAUSED %d / %d boarded", pax_no_cur, pax_no_tgt))
        imgui.PopStyleColor()
    elseif current_state == State.DEBOARDING then
        imgui.PushStyleColor(imgui.constant.Col.Text, 0xFF95FFF8)
        imgui.TextUnformatted(string.format("Deboarding in progress %d / %d remaining", pax_no_cur, pax_no_deboarding))
        imgui.PopStyleColor()
    elseif current_state == State.DEBOARDING_PAUSED then
        imgui.PushStyleColor(imgui.constant.Col.Text, 0xFFFFAA00)
        imgui.TextUnformatted(string.format("Deboarding PAUSED %d / %d remaining", pax_no_cur, pax_no_deboarding))
        imgui.PopStyleColor()
    end

    local changed, val
    -- Show controls only when in READY state
    if current_state == State.READY then
        -- Update jetway status first (affects speed calculation)
        jw1_connected = (opensam_door_status ~= nil and opensam_door_status[1] == 1)

        -- Show current pax count
        local current_pax = get("AirbusFBW/NoPax")
        imgui.TextUnformatted(string.format("Onboard: %d pax", current_pax))

        if http_in_progress("simbrief_ofp") then
            imgui.PushStyleColor(imgui.constant.Col.Button, 0xFF666666)
            imgui.Button("Fetching...")
            imgui.PopStyleColor()
        elseif imgui.Button("Get from simbrief") then
            Timers.cancel_all()  -- User action cancels timers
            fetch_data()
        end

        imgui.SameLine()
        changed, val = imgui.SliderInt("Target", pax_no_tgt, 0, MAX_PAX_NUMBER, "%d pax")

        if changed then
            pax_no_tgt = val
            Timers.cancel_all()  -- User adjusted pax, cancel prelim loadsheet timer
        end

        -- Board button - only enabled when plane is empty and target > 0
        local can_board = (current_pax == 0 and pax_no_tgt > 0)
        if not can_board then
            imgui.PushStyleColor(imgui.constant.Col.Button, 0xFF666666)
            imgui.PushStyleColor(imgui.constant.Col.ButtonHovered, 0xFF666666)
            imgui.PushStyleColor(imgui.constant.Col.ButtonActive, 0xFF666666)
        end
        local board_label = string.format("Board to %d", pax_no_tgt)
        if imgui.Button(board_label) and can_board then
            if tobus_start_boarding_cmd() then
                log_msg(string.format("start boarding with %0.1f s/pax", s_per_pax))
                toggle_tobus_window()
                return
            end
        end
        if not can_board then
            imgui.PopStyleColor(3)
            imgui.SameLine()
            imgui.PushStyleColor(imgui.constant.Col.Text, 0xFF888888)
            if current_pax > 0 then
                imgui.TextUnformatted("(deboard first)")
            elseif pax_no_tgt == 0 then
                imgui.TextUnformatted("(set target)")
            end
            imgui.PopStyleColor()
        end

        -- Deboard All button - only enabled when passengers onboard
        local can_deboard = (current_pax > 0)
        if not can_deboard then
            imgui.PushStyleColor(imgui.constant.Col.Button, 0xFF666666)
            imgui.PushStyleColor(imgui.constant.Col.ButtonHovered, 0xFF666666)
            imgui.PushStyleColor(imgui.constant.Col.ButtonActive, 0xFF666666)
        end
        if imgui.Button("Deboard All") and can_deboard then
            if tobus_start_deboarding_cmd() then
                log_msg(string.format("start deboarding with %0.1f s/pax", s_per_pax))
            end
        end
        if not can_deboard then
            imgui.PopStyleColor(3)
        end

        imgui.SameLine()

        -- Instant button - always enabled unless current == target
        local can_instant = (current_pax ~= pax_no_tgt)
        if not can_instant then
            imgui.PushStyleColor(imgui.constant.Col.Button, 0xFF666666)
            imgui.PushStyleColor(imgui.constant.Col.ButtonHovered, 0xFF666666)
            imgui.PushStyleColor(imgui.constant.Col.ButtonActive, 0xFF666666)
        end
        if imgui.Button("Instant board/deboard") and can_instant then
            set_instantly()
        end
        if not can_instant then
            imgui.PopStyleColor(3)
        end
    end

    -- Pause/Resume buttons based on state
    if current_state == State.BOARDING then
        imgui.SameLine()
        if imgui.Button("Pause Boarding") then
            transition_to(State.BOARDING_PAUSED)
        end
    elseif current_state == State.BOARDING_PAUSED then
        imgui.SameLine()
        if imgui.Button("Resume Boarding") then
            transition_to(State.BOARDING)
        end
    end

    if current_state == State.DEBOARDING then
        imgui.SameLine()
        if imgui.Button("Pause Deboarding") then
            transition_to(State.DEBOARDING_PAUSED)
        end
    elseif current_state == State.DEBOARDING_PAUSED then
        imgui.SameLine()
        if imgui.Button("Resume Deboarding") then
            transition_to(State.DEBOARDING)
        end
    end

    -- Reset button (only when paused)
    if current_state == State.BOARDING_PAUSED or current_state == State.DEBOARDING_PAUSED then
        imgui.SameLine()
        if imgui.Button("Reset") then
            transition_to(State.READY)
        end
    end

    if current_state == State.READY then
        local effective_s_per_pax = s_per_pax
        if USE_SECOND_DOOR or jw1_connected then
            imgui.PushStyleColor(imgui.constant.Col.Text, 0xFF00AAFF)
            if jw1_connected then
                imgui.TextUnformatted("A second jetway is connected, using both doors")
            else
                imgui.TextUnformatted("Using both doors")
            end
            effective_s_per_pax = s_per_pax / 2
            imgui.PopStyleColor()
        end

        local minutes = math.floor((pax_no_tgt * effective_s_per_pax) / 60 + 0.5)
        imgui.TextUnformatted(string.format("Expected Boarding time: %d min", minutes))
    end

    imgui.Separator()

    -- Manual loadsheet send button (for testing)
    if not ofp_data then
        imgui.PushStyleColor(imgui.constant.Col.Button, 0xFF666666)
        imgui.PushStyleColor(imgui.constant.Col.ButtonHovered, 0xFF666666)
        imgui.PushStyleColor(imgui.constant.Col.ButtonActive, 0xFF666666)
        imgui.Button("Send Loadsheet Now")
        imgui.PopStyleColor(3)
    else
        if imgui.Button("Send Loadsheet Now") then
            generate_final_loadsheet()
        end
    end

    if imgui.TreeNode("Settings") then
        local changed, newval = imgui.SliderFloat("Boarding speed", s_per_pax_cfg, 1, 6, "s / pax: %.1f")
        if changed then
            s_per_pax_cfg = newval
        end

        changed, newval = imgui.InputText("Simbrief Username", SIMBRIEF_ACCOUNT_NAME, 255)
        if changed then
            SIMBRIEF_ACCOUNT_NAME = newval
        end

        changed, newval = imgui.InputText("Hoppie Logon", HOPPIE_LOGON, 255)
        if changed then
            HOPPIE_LOGON = newval
        end

        imgui.TextUnformatted("Deliver loadsheet via: ")
        imgui.SameLine()
        if imgui.RadioButton("CPDLC", HOPPIE_CPDLC) then
            HOPPIE_CPDLC = true
        end

        imgui.SameLine()

        if imgui.RadioButton("Telex", not HOPPIE_CPDLC) then
            HOPPIE_CPDLC = false
        end

        if not HOPPIE_CPDLC then
            imgui.PushStyleColor(imgui.constant.Col.Text, 0xFF00AAFF)
            imgui.SameLine();
            imgui.TextUnformatted("You MUST send a PDC reqequest prior to boarding for a Telex to arrive")
            imgui.TextUnformatted("If you are not connected to VATSIM/IVAO use a fake station name, e.g. XXXX")
            imgui.PopStyleColor()
        end

        changed, newval = imgui.Checkbox("Simulate some passengers not showing up after simbrief import",
                                         RANDOMIZE_SIMBRIEF_PASSENGER_NUMBER)
        if changed then
            RANDOMIZE_SIMBRIEF_PASSENGER_NUMBER = newval
        end

        changed, newval = imgui.Checkbox(
            "Use front and back door for boarding and deboarding (only front door by default)", USE_SECOND_DOOR)
        if changed then
            USE_SECOND_DOOR = newval
            log_msg("USE_SECOND_DOOR set to " .. tostring(USE_SECOND_DOOR))
        end

        changed, newval = imgui.Checkbox(
            "Close doors after boarding/deboading", CLOSE_DOORS)
        if changed then
            CLOSE_DOORS = newval
            log_msg("CLOSE_DOORS set to " .. tostring(CLOSE_DOORS))
        end

        changed, newval = imgui.Checkbox(
            "Leave door1 open after boarding/deboading", LEAVE_DOOR1_OPEN)
        if changed then
            LEAVE_DOOR1_OPEN = newval
            log_msg("LEAVE_DOOR1_OPEN set to " .. tostring(LEAVE_DOOR1_OPEN))
        end

        if imgui.Button("Save Settings") then
            save_settings()
        end
        imgui.TreePop()
    end
end

local winCloseInProgess = false

function tobus_on_close()
    isTobusWindowDisplayed = false
    winCloseInProgess = false
end

function build_tobus_window()
    delayed_init()

    if (isTobusWindowDisplayed) then
        return
    end
	tobus_window = float_wnd_create(900, 295, 1, true)

    local leftCorner, height, width = XPLMGetScreenBoundsGlobal()

    float_wnd_set_position(tobus_window, width / 2 - 375, height / 2)
	float_wnd_set_title(tobus_window, "TOBUS - Your Toliss Boarding Companion " .. VERSION)
	float_wnd_set_imgui_builder(tobus_window, "tobus_on_build")
    float_wnd_set_onclose(tobus_window, "tobus_on_close")

    isTobusWindowDisplayed = true
end

function toggle_tobus_window()
    if isTobusWindowDisplayed then
        if not winCloseInProgess then
            winCloseInProgess = true
            float_wnd_destroy(tobus_window) -- marks for destroy, destroy is async
        end
        return
    end

    build_tobus_window()
end

-- low freq actions
function tobus_often()
    delayed_init_delay = delayed_init_delay - 1
    if delayed_init_delay >= 0 then return end

    delayed_init()

    -- Process timers
    Timers.tick()

    -- Handle delayed speech
    local now = os.time()
    if speak_string and now > wait_until_speak then
      XPLMSpeakString(speak_string)
      speak_string = nil
    end

    -- for debugging plane_data tables
    if false then
        if plane_data == nil then return end
        local pax_no, pax_distrib, zfwcg = get_zfwcg(plane_data.cg_data)
        log_msg(string.format("%s, distrib: %0.3f, pax_no: %0.1f, ZFWCG: %0.1f",plane_data.cfg, pax_distrib, pax_no, zfwcg))
    end
end

-- frame loop, efficient coding please
function tobus_frame()
    local now = os.time()

    if current_state == State.BOARDING then
        if pax_no_cur < pax_no_tgt and now >= nextTimeBoardingCheck then
            pax_no_cur = pax_no_cur + 1
            tls_pax_no[0] = pax_no_cur
            command_once("AirbusFBW/SetWeightAndCG")
            -- accumulated boarding time has a standard deviation ~sqrt(pax_no) hence we clamp on the high side
            nextTimeBoardingCheck = os.time() + s_per_pax * clamp(gauss(1.0, 0.2), 0.8, 1.15)
        end

        if pax_no_cur == pax_no_tgt then
            -- Boarding complete - transition to READY (entry action handles chime, doors, loadsheet)
            transition_to(State.READY)
        end

    elseif current_state == State.DEBOARDING then
        if pax_no_cur > 0 and now >= nextTimeBoardingCheck then
            pax_no_cur = pax_no_cur - 1
            tls_pax_no[0] = pax_no_cur
            command_once("AirbusFBW/SetWeightAndCG")
            nextTimeBoardingCheck = os.time() + s_per_pax * clamp(gauss(1.0, 0.2), 0.8, 1.15)
        end

        if pax_no_cur == 0 then
            -- Deboarding complete - transition to READY (entry action handles chime, doors)
            transition_to(State.READY)
        end
    end
end

-- main
log_msg("TOBUS " .. VERSION .. " startup")
math.randomseed(os.time())

if not SUPPORTS_FLOATING_WINDOWS then
    -- to make sure the script doesn't stop old FlyWithLua versions
    log_msg("imgui not supported by your FlyWithLua version")
    return
end

read_settings()

function tobus_start_boarding_cmd()
    last_error = nil  -- clear previous error

    local can, reason = can_start_boarding()
    if not can then
        set_last_error("Cannot start boarding: " .. reason)
        return false
    end

    transition_to(State.BOARDING)
    log_msg("Boarding started")
    return true
end

function tobus_start_deboarding_cmd()
    last_error = nil  -- clear previous error

    local can, reason = can_start_deboarding()
    if not can then
        set_last_error("Cannot start deboarding: " .. reason)
        return false
    end

    transition_to(State.DEBOARDING)
    log_msg("Deboarding started")
    return true
end

add_macro("TOBUS - Your Toliss Boarding Companion", "build_tobus_window()")
create_command("FlyWithLua/TOBUS/Toggle_tobus", "Toggle TOBUS window", "toggle_tobus_window()", "", "")

add_macro("TOBUS - Start Boarding", "tobus_start_boarding_cmd()")
create_command("FlyWithLua/TOBUS/start_boarding", "Start Boarding", "tobus_start_boarding_cmd()", "", "")

add_macro("TOBUS - Start Deboarding", "tobus_start_deboarding_cmd()")
create_command("FlyWithLua/TOBUS/start_deboarding", "Start Deboarding", "tobus_start_deboarding_cmd()", "", "")

do_every_frame("tobus_frame()")
do_often("tobus_often()")

end
