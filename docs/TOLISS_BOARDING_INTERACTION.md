# ToLiss Built-in Boarding Interaction

## Background

ToLiss aircraft have their own built-in boarding system accessible via:
- **ISCS** (Integrated Services Control System) - `Plugins → ToLiss → Open ISCS`
- **EFB** (Electronic Flight Bag) ground services page

This system has its own timers that:
1. Automatically set passenger numbers over time
2. Trigger cabin crew announcements ("close doors and arm slides")
3. Control ground service equipment (stairs, baggage loaders)

## Current JTB Behavior

JTB does **NOT** explicitly disable ToLiss's built-in boarding system. Instead, it simply **overwrites** the passenger count dataref every frame:

```lua
-- In jtb_frame() - runs EVERY frame
if boardingActive then
    if pax_no_cur < pax_no_tgt and now >= nextTimeBoardingCheck then
        pax_no_cur = pax_no_cur + 1
        tls_pax_no[0] = pax_no_cur           -- overwrites AirbusFBW/NoPax
        command_once("AirbusFBW/SetWeightAndCG")
    end
end
```

This creates a **race condition** where both systems write to `AirbusFBW/NoPax`. JTB "wins" because it writes more frequently (every frame when active).

## Relevant Datarefs Found

From `docs/toliss-datarefs.txt`:

| Dataref | Purpose |
|---------|---------|
| `AirbusFBW/NoPax` | Current passenger count (both JTB and ToLiss write here) |
| `AirbusFBW/PaxDistrib` | Passenger distribution (affects CG) |
| `AirbusFBW/PaxDoorModeArray` | Door states: 0=Closed, 1=Auto, 2=Open |
| `AirbusFBW/CargoDoorModeArray` | Cargo door states |
| `toliss_airbus/init/ZFW` | Zero fuel weight |
| `toliss_airbus/init/ZFWCG` | Zero fuel weight CG |

## Missing: ISCS Boarding Control Dataref

**No dataref was found to disable ToLiss's internal boarding timer.**

The dataref list (`docs/toliss-datarefs.txt`) does not contain any ISCS-specific datarefs for:
- Enabling/disabling boarding
- Boarding timer state
- Ground services active flag

This could mean:
1. The control is internal to ToLiss (no exposed dataref)
2. The dataref list is incomplete/outdated
3. It's controlled via command rather than dataref

## Investigation Steps

To find the correct dataref (if it exists):

### Option 1: DataRefTool
1. Install DataRefTool plugin
2. Load a ToLiss aircraft
3. Open ISCS and start boarding via the UI
4. Search DataRefTool for: `iscs`, `boarding`, `ground`, `pax`

### Option 2: FlyWithLua Probe Script
```lua
local guesses = {
    "toliss_airbus/iscs/boarding",
    "toliss_airbus/iscs/boarding_active",
    "toliss_airbus/iscs/pax_boarding",
    "toliss_airbus/ground/boarding",
    "AirbusFBW/BoardingActive",
    "AirbusFBW/ISCSBoarding",
    "AirbusFBW/GroundServicesActive",
}

for _, name in ipairs(guesses) do
    if XPLMFindDataRef(name) then
        logMsg("FOUND: " .. name)
    end
end
```

### Option 3: Ask ToLiss Community
Post on X-Plane.org ToLiss subforum asking for the dataref to disable ISCS boarding.

## Recommended Fix

If a control dataref is found (e.g., `toliss_airbus/iscs/boarding_enabled`):

```lua
-- When JTB starts boarding, disable ToLiss's internal boarding
function jtb_start_boarding_cmd()
    -- ... existing checks ...

    -- Disable ToLiss internal boarding (if dataref exists)
    if XPLMFindDataRef("toliss_airbus/iscs/boarding_enabled") then
        set("toliss_airbus/iscs/boarding_enabled", 0)
    end

    -- ... rest of boarding init ...
end
```

If no control dataref exists, the current "overwrite every frame" approach is the only option, but it's fragile and could cause visual glitches if ToLiss's timer fires between JTB updates.

## Related Commands

Commands used by JTB that interact with ToLiss:

| Command | Purpose |
|---------|---------|
| `AirbusFBW/SetWeightAndCG` | Recalculate aircraft weight after pax change |
| `AirbusFBW/CheckCabin` | Trigger cabin chime (boarding complete sound) |
