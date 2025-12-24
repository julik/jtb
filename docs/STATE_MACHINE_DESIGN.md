# TOBUS State Machine Design

## Executive Summary

This document proposes a clean state machine architecture to replace the current ad-hoc state handling in TOBUS. The current implementation uses multiple overlapping boolean flags and timestamps that can enter inconsistent states, leading to bugs around FMGS resets, HTTP blocking, and incomplete cleanup.

## Design Philosophy

**The state machine should represent what the script is currently DOING, not the aircraft's overall state.**

The aircraft's state (passenger count, velocity, beacon) is **external data** that informs what operations are valid. We don't need to track "who loaded the passengers" or "is FMGS initialized" - we just need to know:

1. Is an operation (boarding/deboarding) currently in progress?
2. Is it safe to start an operation? (checked via `flight_in_progress()`)
3. Are there passengers to deboard? (checked via current pax count)

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
5. **HTTP in main loop**: Loadsheet delivery blocks the simulator
6. **No single source of truth**: Must inspect multiple variables to determine "what state are we in?"

---

## Proposed State Machine

### Primary States (Simplified)

The states represent **what TOBUS is currently doing**, not the aircraft lifecycle:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              STATE DIAGRAM                                   │
└─────────────────────────────────────────────────────────────────────────────┘

                        ┌───────────┐
                        │   READY   │  (no operation in progress)
                        └─────┬─────┘
                              │
              ┌───────────────┼───────────────┐
              │               │               │
              ▼               │               ▼
       ┌───────────┐          │        ┌─────────────┐
       │ BOARDING  │◄─────────┴───────►│ DEBOARDING  │
       └─────┬─────┘                   └──────┬──────┘
             │                                │
             ▼                                ▼
       ┌───────────┐                   ┌─────────────┐
       │ BOARDING  │                   │ DEBOARDING  │
       │ _PAUSED   │                   │ _PAUSED     │
       └───────────┘                   └─────────────┘
```

### State Definitions

```lua
local State = {
    READY = "ready",                      -- No operation in progress, can start boarding or deboarding
    BOARDING = "boarding",                -- Actively boarding passengers
    BOARDING_PAUSED = "boarding_paused",  -- Boarding paused by user
    DEBOARDING = "deboarding",            -- Actively deboarding passengers
    DEBOARDING_PAUSED = "deboarding_paused",
}

local current_state = State.READY
```

### Key Insight: External State vs Script State

**External state** (read from datarefs, not tracked by script):
- `current_pax` = `get("AirbusFBW/NoPax")` - How many passengers are aboard RIGHT NOW
- `flight_in_progress()` - Is it safe for ground ops?
- SimBrief data - Optional enhancement, not required for core functionality

**Script state** (what we're currently doing):
- `current_state` - One of: READY, BOARDING, BOARDING_PAUSED, DEBOARDING, DEBOARDING_PAUSED
- `pax_no_tgt` - Target for boarding (only relevant during BOARDING states)

### Valid Operations Based on External State

| Current Pax | Flight In Progress | Can Board? | Can Deboard? |
|-------------|-------------------|------------|--------------|
| 0           | No                | Yes        | No (no pax)  |
| 0           | Yes               | No         | No           |
| > 0         | No                | Yes*       | Yes          |
| > 0         | Yes               | No         | No           |

*Boarding with pax already aboard would add to existing count (edge case, may want to warn user)

## State Transitions

### Transition Table

| From State | Event | To State | Actions |
|------------|-------|----------|---------|
| READY | User clicks "Start Boarding" + `!flight_in_progress()` | BOARDING | Open doors, set pax to 0, init counter |
| READY | User clicks "Start Deboarding" + `!flight_in_progress()` + `pax > 0` | DEBOARDING | Open doors, init counter from current pax |
| BOARDING | User clicks "Pause" | BOARDING_PAUSED | — |
| BOARDING_PAUSED | User clicks "Resume" | BOARDING | — |
| BOARDING_PAUSED | User clicks "Reset" | READY | Close doors, cancel timers |
| BOARDING | `pax_no_cur == pax_no_tgt` | READY | Play chime, close doors, (optionally send loadsheet) |
| DEBOARDING | User clicks "Pause" | DEBOARDING_PAUSED | — |
| DEBOARDING_PAUSED | User clicks "Resume" | DEBOARDING | — |
| DEBOARDING_PAUSED | User clicks "Reset" | READY | Close doors, cancel timers |
| DEBOARDING | `pax_no_cur == 0` | READY | Play chime, close doors |

### Pre-conditions for Starting Operations

```lua
function can_start_boarding()
    if current_state ~= State.READY then return false, "Operation in progress" end
    if flight_in_progress() then return false, reason end
    if pax_no_tgt <= 0 then return false, "Set passenger target first" end
    return true, nil
end

function can_start_deboarding()
    if current_state ~= State.READY then return false, "Operation in progress" end
    if flight_in_progress() then return false, reason end
    local current_pax = get("AirbusFBW/NoPax")
    if current_pax <= 0 then return false, "No passengers to deboard" end
    return true, nil
end
```

### Deboarding External Loads

**Key requirement**: Users must be able to deboard passengers that were loaded externally (via EFB, situation file, etc.).

This works automatically because:
1. We check `get("AirbusFBW/NoPax")` directly - we don't track "who loaded them"
2. If `current_pax > 0` and `!flight_in_progress()`, deboarding is allowed
3. No dependency on SimBrief, FMGS, or any prior TOBUS operations

### Reset Behavior

**Reset** (User clicks "Reset" button during paused state):
- Transition to READY
- Cancel any pending timers
- Close doors
- Does NOT change passenger count (leave aircraft as-is)

---

## Timer Management

### Timer Registry

Replace scattered timestamp variables with a centralized timer system:

```lua
local Timers = {
    active = {},  -- currently scheduled timers: {name -> {fire_at, callback}}
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

| Timer Name | Delay | Triggered By | Action |
|------------|-------|--------------|--------|
| `speak_completion` | 0.5s | Boarding/deboarding reaching target | `XPLMSpeakString()` |
| `close_doors` | 30s | Boarding completion | Close passenger/cargo doors |
| `final_loadsheet` | 60s | Boarding completion | Send final loadsheet via Hoppie |

Note: Timers fire during READY state (after operation completes). They handle post-completion housekeeping.

### Timer Cleanup on State Transition

```lua
local function transition_to(new_state)
    -- Cancel all timers when starting a new operation
    if new_state == State.BOARDING or new_state == State.DEBOARDING then
        Timers.cancel_all()
    end

    -- Run exit actions for old state
    on_exit_state(current_state)

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
    if state == State.READY then
        -- Returned to idle - check if we completed an operation
        if from_state == State.BOARDING and pax_no_cur == pax_no_tgt then
            -- Boarding just completed
            playChimeSound(true)
            Timers.schedule("close_doors", 30, close_doors)
            Timers.schedule("final_loadsheet", 60, generate_final_loadsheet)
        elseif from_state == State.DEBOARDING and get("AirbusFBW/NoPax") == 0 then
            -- Deboarding just completed
            playChimeSound(false)
            close_doors()  -- Immediate for deboarding
        end
        -- Note: If from_state was PAUSED and user clicked Reset, doors are closed
        -- but no chime (operation was cancelled, not completed)

    elseif state == State.BOARDING then
        open_doors()
        set("AirbusFBW/NoPax", 0)
        pax_no_cur = 0
        set("AirbusFBW/PaxDistrib", clamp(gauss(0.5, 0.1), 0.35, 0.6))

    elseif state == State.DEBOARDING then
        open_doors()
        pax_no_cur = get("AirbusFBW/NoPax")  -- Read current count from dataref

    -- BOARDING_PAUSED and DEBOARDING_PAUSED have no entry actions
    -- (state persists, just stops incrementing/decrementing)
    end
end
```

### On Exit State

```lua
local function on_exit_state(state)
    if state == State.BOARDING_PAUSED or state == State.DEBOARDING_PAUSED then
        -- If leaving paused state via Reset, close doors
        -- (If resuming, doors stay open - handled by target state)
    end
    -- Most cleanup is handled by transition_to() or entry actions
end
```

---

## Allowed Transitions Matrix

This matrix defines which state transitions are valid:

```
                    To State →
From State ↓       READY   BOARDING   B_PAUSED   DEBOARDING   D_PAUSED
─────────────────────────────────────────────────────────────────────────
READY                -        ✓          -           ✓           -
BOARDING             ✓        -          ✓           -           -
BOARDING_PAUSED      ✓        ✓          -           -           -
DEBOARDING           ✓        -          -           -           ✓
DEBOARDING_PAUSED    ✓        -          -           ✓           -

Legend:
✓ = Valid transition
- = Invalid/not applicable
```

### Transition Triggers

| Transition | Trigger |
|------------|---------|
| READY → BOARDING | User clicks "Start Boarding" + `can_start_boarding()` returns true |
| READY → DEBOARDING | User clicks "Start Deboarding" + `can_start_deboarding()` returns true |
| BOARDING → BOARDING_PAUSED | User clicks "Pause" |
| BOARDING → READY | Pax count reaches target |
| BOARDING_PAUSED → BOARDING | User clicks "Resume" |
| BOARDING_PAUSED → READY | User clicks "Reset" |
| DEBOARDING → DEBOARDING_PAUSED | User clicks "Pause" |
| DEBOARDING → READY | Pax count reaches 0 |
| DEBOARDING_PAUSED → DEBOARDING | User clicks "Resume" |
| DEBOARDING_PAUSED → READY | User clicks "Reset" |

---

## Safe Reset Implementation

### Reset from Paused State

When user clicks "Reset" during a paused operation:

```lua
local function handle_reset()
    if current_state ~= State.BOARDING_PAUSED and
       current_state ~= State.DEBOARDING_PAUSED then
        return false, "Reset only available when paused"
    end

    -- Close doors
    close_doors()

    -- Transition to READY
    -- Note: Does NOT change passenger count - leaves aircraft as-is
    transition_to(State.READY)

    log_msg("Operation cancelled by user")
    return true
end
```

### Optional: Full Clean Slate Reset

For development/debugging, a full reset could clear SimBrief data too:

```lua
local function clean_slate_reset()
    Timers.cancel_all()

    -- Clear SimBrief data
    SIMBRIEF_LOADED = false
    SIMBRIEF_ERROR = nil
    pax_no_tgt = 0

    -- Reset state
    current_state = State.READY
    pax_no_cur = 0

    close_doors()
    log_msg("Clean slate reset completed")
end
```

Note: This does NOT reset `AirbusFBW/NoPax` - that's the aircraft's truth. If user wants pax removed, they should deboard.

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
local function get_status_message()
    if current_state == State.READY then
        local pax = get("AirbusFBW/NoPax")
        if pax > 0 then
            return string.format("Ready - %d passengers aboard", pax)
        elseif pax_no_tgt > 0 then
            return string.format("Ready - Target: %d passengers", pax_no_tgt)
        else
            return "Ready - Set passenger target or fetch SimBrief"
        end

    elseif current_state == State.BOARDING then
        return string.format("Boarding: %d / %d", pax_no_cur, pax_no_tgt)

    elseif current_state == State.BOARDING_PAUSED then
        return string.format("Boarding PAUSED: %d / %d", pax_no_cur, pax_no_tgt)

    elseif current_state == State.DEBOARDING then
        return string.format("Deboarding: %d remaining", get("AirbusFBW/NoPax"))

    elseif current_state == State.DEBOARDING_PAUSED then
        return string.format("Deboarding PAUSED: %d remaining", get("AirbusFBW/NoPax"))
    end

    return "Unknown state"
end
```

### Button Visibility

| State | Buttons Shown |
|-------|---------------|
| READY | "Start Boarding" (if target set), "Start Deboarding" (if pax > 0), "Get from SimBrief" |
| BOARDING | "Pause" |
| BOARDING_PAUSED | "Resume", "Reset" |
| DEBOARDING | "Pause" |
| DEBOARDING_PAUSED | "Resume", "Reset" |

Buttons should also be disabled (grayed) if `flight_in_progress()` returns true.

---

## Implementation Phases

### Phase 1: State Variable Consolidation
- [ ] Create `current_state` variable with 5 states
- [ ] Create `transition_to()` function with logging
- [ ] Replace `boardingActive`, `boardingPaused`, `deboardingActive`, `deboardingPaused` with state checks
- [ ] Remove `boardingCompleted`, `deboardingCompleted` - use transition to READY instead

### Phase 2: Timer System
- [ ] Implement `Timers` module
- [ ] Replace timestamp comparisons with timer callbacks
- [ ] Ensure timers are cancelled when starting new operations
- [ ] Remove magic `1E20` timestamp values

### Phase 3: Entry/Exit Actions
- [ ] Implement `on_enter_state()` for READY, BOARDING, DEBOARDING
- [ ] Move door open/close logic to state handlers
- [ ] Move chime/speech logic to READY entry (based on `from_state`)

### Phase 4: Pre-condition Checks
- [ ] Implement `can_start_boarding()` with `flight_in_progress()` check
- [ ] Implement `can_start_deboarding()` with pax count check
- [ ] Surface errors to UI via `GROUND_OPS_ERROR`

### Phase 5: UI Updates
- [ ] Single status message based on `get_status_message()`
- [ ] Show/hide buttons per state
- [ ] Gray out buttons when `flight_in_progress()`

---

## Testing Scenarios

1. **Normal boarding flow**: Set target (SimBrief or manual) → Board → Complete → Doors close → Loadsheet
2. **Manual pax target**: Set pax count manually → Board → Complete
3. **Pause/resume boarding**: Start boarding → Pause → Resume → Complete
4. **Pause/reset boarding**: Start boarding → Pause → Reset → Verify doors close, pax count preserved
5. **Deboard external load**: Load situation with passengers → Deboard → Complete
6. **Deboard then board**: Deboard → Complete → Fetch SimBrief → Board new flight
7. **Multiple SimBrief fetches**: Fetch → Fetch again → Verify latest data overwrites
8. **Aircraft mismatch**: Load OFP for wrong aircraft → Verify error shown → Load correct OFP
9. **Flight in progress guard**: Start engines, set beacon → Verify boarding/deboarding blocked
10. **Rapid state changes**: Click buttons quickly → Verify no invalid states
11. **Partial boarding interrupted**: Board halfway → Reset → Deboard to empty → Board again

---

## Appendix: State Inspection Debug Command

```lua
local function debug_state()
    log_msg("=== TOBUS State Debug ===")
    log_msg("  current_state: " .. current_state)
    log_msg("  pax_no_tgt: " .. tostring(pax_no_tgt))
    log_msg("  pax_no_cur (script): " .. tostring(pax_no_cur))
    log_msg("  AirbusFBW/NoPax: " .. tostring(get("AirbusFBW/NoPax")))
    log_msg("  flight_in_progress: " .. tostring(flight_in_progress()))
    log_msg("  SIMBRIEF_LOADED: " .. tostring(SIMBRIEF_LOADED))
    log_msg("  Active timers:")
    for name, timer in pairs(Timers.active) do
        log_msg("    " .. name .. ": fires in " .. (timer.fire_at - os.time()) .. "s")
    end
    log_msg("=========================")
end
```
