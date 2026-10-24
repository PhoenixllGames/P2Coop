# P2Coop: co-op for POSTAL 2 (Steam build 5100)

Play the POSTAL 2 week together: one player hosts, friends join over Steam. There are no IP
addresses and no port forwarding; the relay uses the free Spacewar app id.

- `Classes/`: the UnrealScript package `P2Coop.u`.
  - `CoopGame` is the game type on top of the SP game info. It handles the leader, spawning, travel, errands, death, loads and jail.
  - `CoopPlayer` is the controller (remote players' screens and cutscenes, test hooks).
  - `CoopReplicationInfo`/`CoopShadowGame`: the host's day, errands and wanted level for the clients' map, newspaper and HUD.
  - `CoopRootWindow`, `CoopMenuMain`, `CoopMenu`: the menu (MinRes fix, reconnect, the Co-op button). `CoopTest*` are the in-game tests.
- `link/`: P2CoopLink, the Steam relay (port of HXCoop's), and a mock `steam_api.dll` for tests.
- `tools/ucc5100/`: built with Visual Studio.
  - P2Ucc: a UCC for 5100 (`make`, `batchexport`).
  - P2CoopHost.exe + P2CoopHk.dll: the engine fixes (save no longer breaks joins, quitting no longer crashes) and the menu's control of the Steam relay.
- `tools/`: test launcher (`run_local.ps1`, `run_suite.ps1`), ini generator, mod build.
- `install/`: the player's installer (`install.ps1`, README.txt) and `make_release.ps1`.

## Build (developer)

1. Have a test copy of the game (never the Steam install), for example `D:\POSTAL2-coop-test`. Visual Studio with the x86 tools is required (found with vswhere, or set `VCVARS`).
   The tools default to the copy in `P2COOP_TEST_GAME` (or pass `-System <copy>\System`).
2. `tools\ucc5100\build.bat <copy>\System` builds P2Ucc and P2CoopHost.
3. `tools\build_mod.ps1` builds `P2Coop.u` from `Classes/`.
4. `link\build.bat <copy>` builds P2CoopLink and the mock. The real `steam_api.dll` goes in `link\redist\`; see link/README.md for source and SHA-256.
5. `install\make_release.ps1` writes `release\P2Coop\` (no game files in it).

## Play

See install/README.txt (the file that comes with a release): install with `install.ps1`, run
`P2Coop.bat`, pick Co-op in the main menu.

## Test

`tools\run_suite.ps1 [-Relay]` runs the in-game tests with real game copies on this PC. It starts
one host and 1-2 clients, silent, with the windows on a secondary monitor. Each test prints
`RESULT: PASS|FAIL`. With `-Relay` all traffic goes through P2CoopLink and a mock `steam_api.dll`.
`tools\menu_e2e.ps1` hosts and joins from the Co-op menu over the mock relay.

| Test | Checks |
|---|---|
| combat | client sees host and NPCs, both move, weapon switch, damage both ways |
| travel | client-triggered trip there and back, items and GameState kept, 2 clients with the same name |
| errand | client picks up an errand item, errand done for everyone, the client crosses it out on its map |
| screens | client's copy of the day, errands, haters and wanted level; its map (server request and map key), newspaper |
| cutscene | client watches through the host's camera, no damage meanwhile, plays on afterwards |
| jail | client arrested: everyone in jail together, both players' weapons in the evidence room |
| death | client and leader respawn next to a living teammate, no reload |
| load | host loads a save, clients reconnect and keep their saved items |

Last full run (2026-10-24): 8/8 direct, 8/8 through the relay (mock Steam), menu_e2e PASS.
Not tried with two real Steam accounts.

## Status

Done: the week in co-op, client screens and HUD, cutscenes, group jail, the
Co-op menu, installer. Not done: Paradise Lost, a bot playing Monday through.
Known: quitting after a co-op session fails in the engine's object cleanup; P2CoopHk.dll contains it,
so the game closes normally.

P2Coop co-op mod by PhoenixllGames. MIT License (LICENSE); third-party parts in THIRD_PARTY.md.
