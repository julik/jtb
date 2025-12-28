# JTB - Julik's ToLiss Boarding

A FlyWithLua script that simulates realistic passenger boarding and deboarding for ToLiss aircraft in X-Plane.

## Origins and Credits

This project is based on work by several contributors:

- **Original TOBUS** by [@piotr-tomczyk](https://github.com/piotr-tomczyk) (aka @travisair) - the original boarding simulation concept
- **hotbso's TOBUS fork** at [hotbso/TOBUS](https://github.com/hotbso/TOBUS) - maintenance and improvements
- **@Tom_David** - initial loadsheet implementation
- **Manta32** - CPDLC code (MIT license)
- **@Qlaudie73** and **@Pilot4XP** - additional features and information

Special thanks to hotbso for keeping the project alive and adding functionality when the original author became unreachable.

## Changes from hotbso's Version

JTB includes significant refactoring and improvements:

- **State machine architecture** - clean state transitions replace scattered boolean flags
- **Timer system** - centralized timer management with proper cleanup
- **HTTP improvements** - short timeouts with automatic retries to avoid blocking the sim
- **Turnaround support** - always re-fetches OFP when starting boarding for multi-leg flights
- **Safety checks** - prevents boarding/deboarding when beacon is on, aircraft is moving, or (for deboarding) seatbelt sign is on
- **Improved UI** - separate Instant Board/Instant Deboard buttons, clearer status messages
- **Text-to-speech feedback** - errors and status changes are spoken aloud
- **URL encoding fix** - proper encoding for Hoppie ACARS messages
- **Bug fixes** - boarding speed calculation, timer cancellation, and more

## Features

- Pull passenger count from SimBrief OFP
- Realistic timed boarding/deboarding simulation
- Random passenger variation (no-shows, late bookings)
- Automatic door control
- Loadsheet delivery via Hoppie ACARS (CPDLC or Telex)
- Randomized passenger distribution affecting CG
- Optional second door for faster boarding
- Pause/resume capability
- Works with externally loaded passengers (EFB, situation files)

## Installation

1. Install [FlyWithLua NG+](https://forums.x-plane.org/index.php?/files/file/38445-flywithlua-ng-next-generation-edition-for-x-plane-11-win-lin-mac/)
2. Copy `Scripts/jtbBoarding.lua` and `Scripts/jtb/` folder to `<X-Plane>/Resources/plugins/FlyWithLua/Scripts/`
2. Copy the contents of `Modules/` to `<X-Plane>/Resources/plugins/FlyWithLua/Modules/`

## Usage

Access via FlyWithLua Macros: **JTB - Your Toliss Boarding Companion**
If you are using SimBrief and/or Hoppie - configure your SimBrief _username_ and the Hoppie logon in the "Settings".

Or bind the commands:
- `FlyWithLua/JTB/Toggle_jtb` - Toggle the JTB window
- `FlyWithLua/JTB/start_boarding` - Start boarding (auto-fetches OFP)
- `FlyWithLua/JTB/start_deboarding` - Start deboarding

The script will use X-Plane's speech synthesis to tell you if anything is misconfigured.

## Loadsheet Notes

- Supported aircraft: All ToLiss narrow-bodies and A330-900
- Passenger weight must remain at default (100 kg)
- Cargo weight is read from aircraft but not managed by JTB
- For Telex delivery: send a PDC request first (use fake station like `XXXX` if offline)

## Support

For issues and feature requests, please use the [GitHub Issues](https://github.com/julik/JTB/issues) page.

## License

MIT License - see original credits above for component licensing.
