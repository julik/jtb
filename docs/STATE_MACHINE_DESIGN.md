# TOBUS State Machine Design

## Executive Summary

This document proposes a clean state machine architecture to replace the current ad-hoc state handling in TOBUS. The current implementation uses multiple overlapping boolean flags and timestamps that can enter inconsistent states, leading to bugs around FMGS resets, HTTP blocking, and incomplete cleanup.

## Current State Analysis

### Current State Variables (The Problem)

The current implementation tracks state through **10+ independent boolean flags** and **5+ timestamps**:

```
Boolean flags:
- boardingActive, deboardingActive
- boardingPaused, deboardingPaused
- boardingCompleted, deboardingCompleted
- SIMBRIEF_LOADED
- prelim_loadsheet_sent, final_loadsheet_sent
- doors_closed

Timestamps:
- fmgs_init_ts (default 1E20 = "disabled")
- boarding_completed_ts (default 1E20)
- nextTimeBoardingCheck
- delayed_init_delay (countdown)
- wait_until_speak
```

**Problems with this approach:**

1. **Invalid state combinations**: Nothing prevents `boardingActive = true` AND `boardingPaused = true` simultaneously
2. **Scattered transitions**: State changes happen in `tobus_often()`, `tobus_frame()`, UI callbacks, and command handlers
3. **Magic timestamps**: Using `1E20` as "disabled" is fragile and unclear
4. **No cleanup on transitions**: When state changes, related timers/flags may not be reset
5. **FMGS reset chaos**: If FMGS resets during boarding, only some state is cleared
6. **HTTP in main loop**: Loadsheet delivery blocks the simulator
7. **No single source of truth**: Must inspect multiple variables to determine "what state are we in?"

---

## Proposed State Machine

### Primary States

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              STATE DIAGRAM                                   │
└─────────────────────────────────────────────────────────────────────────────┘

    ┌──────────────┐
    │ UNINITIALIZED│  (plugin just loaded, waiting for aircraft datarefs)
    └──────┬───────┘
           │ delayed_init() succeeds
           ▼
    ┌──────────────┐
    │    IDLE      │  (ready, no flight plan active)
    └──────┬───────┘
           │ FMGS flight number set (and beacon off)
           ▼
    ┌──────────────┐
    │ FLIGHT_READY │  (FMGS initialized, can fetch SimBrief)
    └──────┬───────┘
           │ fetchData() succeeds
           ▼
    ┌──────────────┐
    │  OFP_LOADED  │  (SimBrief data loaded, ready for operations)
    └──────┬───────┘
           │
     ┌─────┴─────┐
     ▼           ▼
┌─────────┐  ┌───────────┐
│BOARDING │  │DEBOARDING │
└────┬────┘  └─────┬─────┘
     │             │
     ▼             ▼
┌─────────────┐  ┌───────────────┐
│BOARDING_    │  │DEBOARDING_    │
│PAUSED       │  │PAUSED         │
└─────────────┘  └───────────────┘
     │             │
     ▼             ▼
┌─────────────┐  ┌───────────────┐
│BOARDING_    │  │DEBOARDING_    │
│COMPLETED    │  │COMPLETED      │
└─────────────┘  └───────────────┘
     │
     ▼
┌─────────────┐
│POST_BOARDING│  (doors closing, loadsheet pending)
└─────────────┘
```

### State Definitions

```lua
local State = {
    UNINITIALIZED = "uninitialized",     -- Plugin loaded, waiting for init
    IDLE = "idle",                        -- Initialized, no active flight
    FLIGHT_READY = "flight_ready",        -- FMGS has flight number, can fetch OFP
    OFP_LOADED = "ofp_loaded",            -- SimBrief data loaded successfully
    BOARDING = "boarding",                -- Actively boarding passengers
    BOARDING_PAUSED = "boarding_paused",  -- Boarding paused by user
    BOARDING_COMPLETED = "boarding_completed", -- All passengers boarded
    POST_BOARDING = "post_boarding",      -- Doors closing, loadsheet pending
    DEBOARDING = "deboarding",            -- Actively deboarding passengers
    DEBOARDING_PAUSED = "deboarding_paused",
    DEBOARDING_COMPLETED = "deboarding_completed",
}

local current_state = State.UNINITIALIZED
```

---

## State Transitions

### Transition Table

| From State | Event | To State | Actions |
|------------|-------|----------|---------|
| UNINITIALIZED | `delayed_init()` succeeds | IDLE | Initialize datarefs, load settings |
| IDLE | FMGS flight_no set (beacon off) | FLIGHT_READY | Clear OFP data, record timestamp |
| FLIGHT_READY | User clicks "Get from simbrief" (success) | OFP_LOADED | Parse OFP, set pax target |
| FLIGHT_READY | User sets pax manually + starts boarding | BOARDING | (skip OFP) |
| OFP_LOADED | User clicks "Start Boarding" | BOARDING | Open doors, init pax counter |
| BOARDING | User clicks "Pause" | BOARDING_PAUSED | — |
| BOARDING_PAUSED | User clicks "Resume" | BOARDING | — |
| BOARDING | `pax_no_cur == pax_no_tgt` | BOARDING_COMPLETED | Play chime, start post-boarding timer |
| BOARDING_COMPLETED | User clicks "Reset" | FLIGHT_READY or OFP_LOADED | Reset boarding state |
| BOARDING_COMPLETED | Timer expires (30s) | POST_BOARDING | Close doors |
| POST_BOARDING | Timer expires (60s) | OFP_LOADED | Send final loadsheet |
| OFP_LOADED | User clicks "Start Deboarding" | DEBOARDING | Open doors, init counter |
| DEBOARDING | `pax_no_cur == 0` | DEBOARDING_COMPLETED | Play chime, close doors |
| * | FMGS reset (flight_no = "") | IDLE | **Full reset** |
| * | FMGS changed to different flight | FLIGHT_READY | Clear OFP, reset operations |

### Reset Behaviors

#### Soft Reset (User clicks "Reset" button)
Returns to `FLIGHT_READY` or `OFP_LOADED` (depending on whether OFP was loaded):
- Cancel any pending timers
- Reset pax counters
- Close doors (optionally)
- Keep: FMGS flight number, SimBrief data, settings

#### Hard Reset (FMGS cleared or changed)
Returns to `IDLE` or `FLIGHT_READY`:
- Cancel ALL pending timers
- Reset ALL operational state
- Clear SimBrief data
- Reset pax counters
- Preserve: Settings, aircraft data

#### Clean Slate Reset (Manual full reset)
Returns to `IDLE`:
- Everything from Hard Reset
- Additionally allows user to confirm before abrupt pax/fuel changes
- Gradual pax reduction if mid-operation (prevent physics glitches)

---

## Timer Management

### Timer Registry

Replace scattered timestamp variables with a centralized timer system:

```lua
local Timers = {
    -- Timer definition: {callback, fire_time, repeating}
    active = {},  -- currently scheduled timers
}

function Timers.schedule(name, delay_seconds, callback)
    Timers.active[name] = {
        fire_at = os.time() + delay_seconds,
        callback = callback,
    }
end

function Timers.cancel(name)
    Timers.active[name] = nil
end

function Timers.cancel_all()
    Timers.active = {}
end

function Timers.tick()
    local now = os.time()
    for name, timer in pairs(Timers.active) do
        if now >= timer.fire_at then
            Timers.active[name] = nil  -- remove before callback (allows reschedule)
            timer.callback()
        end
    end
end
```

### Defined Timers

| Timer Name | Delay | Triggered In State | Action |
|------------|-------|-------------------|--------|
| `speak_completion` | 0.5s | BOARDING_COMPLETED, DEBOARDING_COMPLETED | `XPLMSpeakString()` |
| `close_doors` | 30s | BOARDING_COMPLETED | Close passenger/cargo doors |
| `final_loadsheet` | 60s | BOARDING_COMPLETED | Send final loadsheet via Hoppie |
| `prelim_loadsheet` | 8s | OFP_LOADED (if auto-enabled) | Send prelim loadsheet |

### Timer Cleanup on State Transition

```lua
local function transition_to(new_state)
    -- Cancel timers that don't apply to new state
    local timers_to_cancel = {
        [State.IDLE] = {"close_doors", "final_loadsheet", "prelim_loadsheet", "speak_completion"},
        [State.FLIGHT_READY] = {"close_doors", "final_loadsheet", "speak_completion"},
        [State.BOARDING] = {"close_doors", "final_loadsheet"},
        -- etc.
    }

    for _, timer_name in ipairs(timers_to_cancel[new_state] or {}) do
        Timers.cancel(timer_name)
    end

    -- Run exit actions for old state
    on_exit_state(current_state)

    -- Update state
    local old_state = current_state
    current_state = new_state

    -- Run entry actions for new state
    on_enter_state(new_state, old_state)

    log_msg(string.format("State: %s -> %s", old_state, new_state))
end
```

---

## Entry/Exit Actions

### On Enter State

```lua
local function on_enter_state(state, from_state)
    if state == State.IDLE then
        -- Clear all operational data
        SIMBRIEF_LOADED = false
        SIMBRIEF_ERROR = nil
        pax_no_tgt = 0
        fmgs_flight_no = ""

    elseif state == State.FLIGHT_READY then
        -- Ready for OFP fetch
        SIMBRIEF_LOADED = false
        SIMBRIEF_ERROR = nil

    elseif state == State.OFP_LOADED then
        -- Could auto-schedule prelim loadsheet here
        -- Timers.schedule("prelim_loadsheet", 8, generate_prelim_loadsheet)

    elseif state == State.BOARDING then
        open_doors()
        pax_no_cur = 0
        set("AirbusFBW/NoPax", 0)
        set("AirbusFBW/PaxDistrib", clamp(gauss(0.5, 0.1), 0.35, 0.6))

    elseif state == State.BOARDING_COMPLETED then
        playChimeSound(true)
        Timers.schedule("close_doors", 30, function()
            close_doors()
            transition_to(State.POST_BOARDING)
        end)

    elseif state == State.POST_BOARDING then
        Timers.schedule("final_loadsheet", 30, function()  -- 60s total from boarding complete
            generate_final_loadsheet()
            transition_to(State.OFP_LOADED)
        end)

    elseif state == State.DEBOARDING then
        open_doors()
        pax_no_deboarding = tls_pax_no[0]
        pax_no_cur = pax_no_deboarding

    elseif state == State.DEBOARDING_COMPLETED then
        playChimeSound(false)
        close_doors()
    end
end
```

### On Exit State

```lua
local function on_exit_state(state)
    if state == State.BOARDING or state == State.BOARDING_PAUSED then
        -- If exiting boarding unexpectedly, ensure clean state

    elseif state == State.POST_BOARDING then
        -- Clear post-boarding timers if leaving early
        Timers.cancel("final_loadsheet")
    end
end
```

---

## Allowed Transitions Matrix

This matrix defines which state transitions are valid:

```
                    To State →
From State ↓    UNINIT  IDLE  FLIGHT  OFP    BOARD  B_PAUSE  B_COMP  POST   DEBOARD  D_PAUSE  D_COMP
─────────────────────────────────────────────────────────────────────────────────────────────────────
UNINITIALIZED     -      ✓      -      -       -       -        -      -       -        -        -
IDLE              -      -      ✓      -       -       -        -      -       -        -        -
FLIGHT_READY      -      ✓      -      ✓       ✓       -        -      -       ✓        -        -
OFP_LOADED        -      ✓      ✓      -       ✓       -        -      -       ✓        -        -
BOARDING          -      ✓      ✓      -       -       ✓        ✓      -       -        -        -
BOARDING_PAUSED   -      ✓      ✓      ✓       ✓       -        -      -       -        -        -
BOARDING_COMP     -      ✓      ✓      ✓       -       -        -      ✓       -        -        -
POST_BOARDING     -      ✓      ✓      ✓       -       -        -      -       -        -        -
DEBOARDING        -      ✓      ✓      -       -       -        -      -       -        ✓        ✓
DEBOARDING_PAUSE  -      ✓      ✓      ✓       -       -        -      -       ✓        -        -
DEBOARDING_COMP   -      ✓      ✓      ✓       -       -        -      -       -        -        -

Legend:
✓ = Valid transition
- = Invalid/not applicable
```

Note: Transitions to IDLE or FLIGHT_READY from any state represent resets (FMGS change or user reset).

---

## Safe Reset Implementation

### Gradual Passenger Adjustment

When resetting mid-operation, don't instantly set passengers to 0 (can cause physics issues):

```lua
local function safe_reset_passengers()
    local current = tls_pax_no[0]
    if current == 0 then return end

    -- Option 1: Instant (current behavior, can cause issues)
    -- tls_pax_no[0] = 0

    -- Option 2: Gradual reduction (safer)
    -- Schedule rapid deboarding at 0.1s per pax
    local function reduce_one()
        if tls_pax_no[0] > 0 then
            tls_pax_no[0] = tls_pax_no[0] - 1
            command_once("AirbusFBW/SetWeightAndCG")
            Timers.schedule("safe_reset_pax", 0.1, reduce_one)
        end
    end
    reduce_one()

    -- Option 3: Just warn the user
    -- "Cannot reset while passengers are aboard. Deboard first."
end
```

### Full Clean Slate Reset

```lua
local function clean_slate_reset()
    -- Cancel all timers
    Timers.cancel_all()

    -- If passengers aboard, handle gracefully
    if tls_pax_no[0] > 0 then
        log_msg("WARNING: Clean slate reset with passengers aboard")
        -- Either: refuse, warn, or gradual reduction
    end

    -- Reset all state
    current_state = State.IDLE

    -- Clear SimBrief data
    SIMBRIEF_LOADED = false
    SIMBRIEF_ERROR = nil
    pax_no_tgt = 0
    units = nil
    operator = nil
    taxiFuel = nil
    mzfw = nil
    mtow = nil

    -- Clear flight data
    fmgs_flight_no = ""

    -- Reset operational state
    pax_no_cur = 0
    pax_no_deboarding = 0

    -- Close doors
    close_doors()

    log_msg("Clean slate reset completed")
end
```

---

## Async HTTP Handling

### Problem
Current code calls `http.request()` synchronously, blocking the simulator.

### Solution
Either:

1. **Accept the block** for SimBrief fetch (user-initiated, one-time)
2. **Queue loadsheet delivery** for background processing
3. **Use coroutines** (if FlyWithLua supports them)

### Loadsheet Queue

```lua
local pending_loadsheet = nil  -- {type = "prelim"|"final", content = "..."}

local function queue_loadsheet(ls_type, content)
    pending_loadsheet = {type = ls_type, content = content}
end

-- Called from do_often, sends one loadsheet per tick if queued
local function process_loadsheet_queue()
    if pending_loadsheet == nil then return end

    local ls = pending_loadsheet
    pending_loadsheet = nil

    -- Now safe to do HTTP (still blocks, but only briefly)
    send_loadsheet(ls.content)
end
```

---

## UI State Display

The UI should reflect the current state clearly:

```lua
local state_messages = {
    [State.UNINITIALIZED] = "Initializing...",
    [State.IDLE] = "Ready - Enter flight number in FMGS",
    [State.FLIGHT_READY] = "Flight %s - Load SimBrief or set passengers",
    [State.OFP_LOADED] = "OFP loaded - %d passengers",
    [State.BOARDING] = "Boarding: %d / %d",
    [State.BOARDING_PAUSED] = "Boarding PAUSED: %d / %d",
    [State.BOARDING_COMPLETED] = "Boarding complete!",
    [State.POST_BOARDING] = "Preparing for departure...",
    [State.DEBOARDING] = "Deboarding: %d / %d",
    [State.DEBOARDING_PAUSED] = "Deboarding PAUSED: %d / %d",
    [State.DEBOARDING_COMPLETED] = "Deboarding complete!",
}

local function get_status_message()
    local msg = state_messages[current_state] or "Unknown state"
    -- Format with current values
    return string.format(msg, fmgs_flight_no, pax_no_cur, pax_no_tgt)
end
```

---

## Implementation Phases

### Phase 1: State Variable Consolidation
- [ ] Create `current_state` enum variable
- [ ] Create `transition_to()` function with logging
- [ ] Map existing boolean combinations to states
- [ ] Add state validation (assert valid transitions)

### Phase 2: Timer System
- [ ] Implement `Timers` module
- [ ] Replace `fmgs_init_ts`, `boarding_completed_ts`, etc.
- [ ] Ensure timers are cancelled on state transitions
- [ ] Add timer status to debug output

### Phase 3: Entry/Exit Actions
- [ ] Implement `on_enter_state()` for all states
- [ ] Implement `on_exit_state()` for cleanup
- [ ] Move door open/close logic to state handlers
- [ ] Move chime/speech logic to state handlers

### Phase 4: Reset Handling
- [ ] Implement soft reset (user button)
- [ ] Implement hard reset (FMGS change)
- [ ] Implement clean slate reset
- [ ] Add confirmation for resets with passengers aboard

### Phase 5: Async Operations
- [ ] Queue loadsheet delivery
- [ ] Consider SimBrief fetch feedback (loading indicator)

### Phase 6: UI Updates
- [ ] Single status message based on state
- [ ] Disable irrelevant buttons per state
- [ ] Show timer countdowns (doors closing in Xs)

---

## Testing Scenarios

1. **Normal flow**: FMGS init → SimBrief → Board → Complete → Loadsheet
2. **Manual pax**: FMGS init → Set pax manually → Board
3. **Pause/resume**: Start boarding → Pause → Resume → Complete
4. **FMGS reset during boarding**: Board halfway → Clear FMGS → Verify clean state
5. **FMGS change during boarding**: Board halfway → Change flight → Verify reset
6. **Deboard then board**: Deboard → Complete → Reset → Board new flight
7. **Multiple SimBrief fetches**: Fetch → Fetch again → Verify latest data used
8. **Aircraft mismatch**: Load wrong OFP → Verify error → Load correct OFP
9. **Reset with passengers**: Board halfway → Reset → Verify graceful handling
10. **Rapid state changes**: Click buttons quickly → Verify no invalid states

---

## Appendix: State Inspection Debug Command

```lua
local function debug_state()
    log_msg("=== TOBUS State Debug ===")
    log_msg("  current_state: " .. current_state)
    log_msg("  fmgs_flight_no: " .. tostring(fmgs_flight_no))
    log_msg("  SIMBRIEF_LOADED: " .. tostring(SIMBRIEF_LOADED))
    log_msg("  pax_no_cur: " .. tostring(pax_no_cur))
    log_msg("  pax_no_tgt: " .. tostring(pax_no_tgt))
    log_msg("  Active timers:")
    for name, timer in pairs(Timers.active) do
        log_msg("    " .. name .. ": fires in " .. (timer.fire_at - os.time()) .. "s")
    end
    log_msg("=========================")
end
```
