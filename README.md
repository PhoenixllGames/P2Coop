# P2Coop: co-op for POSTAL 2 (Steam build 5100)

Play the POSTAL 2 week together: one player hosts, friends join over Steam. There are no IP
addresses and no port forwarding; the relay uses the free Spacewar app id.

- `Classes/`: the UnrealScript package `P2Coop.u`.
  - `CoopGame` is the game type on top of the SP game info. It handles the leader, spawning, travel, errands, death, loads and jail.
  - `CoopPlayer` is the controller (remote players' screens and cutscenes, test hooks).
  - `CoopReplicationInfo`/`CoopShadowGame`: the host's day, errands and wanted level for the clients' map, newspaper and HUD.
  - `CoopPlayerStatus`/`CoopHUD`: replicated teammate health and nameplates (camera visibility, up to 2500 units).
  - `CoopPawn`: downed players stay at 1 HP for 30 seconds. Teammates can revive them with 2.5 seconds of urine contact, restoring 25% health. With nobody left standing, everyone dies and the stock game over applies.
  - `CoopRagdollSync`: ragdolls run on the host only and are sent to the clients, so a body lies in the same place for everyone.
  - `CoopRootWindow`, `CoopMenuMain`, `CoopMenu`, `CoopSteamMenu`, `CoopStart`: the menu (MinRes fix, reconnect, the Co-op button, the Steam page with the friends' games, a new game started as the stock New Game does). `CoopTest*` are the in-game tests.
- `link/`: P2CoopLink, the Steam relay (port of HXCoop's), and a mock `steam_api.dll` for tests. The host relays only members of its Steam lobby and only peers whose game files match its own (version, `P2Coop.u`, `dinput8.dll`, texture/sound/mesh/animation packages); a mismatch such as another game language is refused with a readable message. Details in link/README.md.
- `tools/ucc5100/`: built with Visual Studio.
  - P2Ucc: a UCC for 5100 (`make`, `batchexport`).
  - P2CoopHk, built as `dinput8.dll`: the engine fixes (save no longer breaks joins, quitting no longer crashes) and the menu's control of the Steam relay. The stock `Postal2.exe` loads it from `System` (its WinDrv.dll imports DINPUT8.dll), so Steam's Play button starts the game with co-op.
- `tools/`: test launcher (`run_local.ps1`, `run_suite.ps1`), ini generator, mod build.
- `install/`: the player's installer (`install.ps1`, README.txt) and `make_release.ps1`.

## Build (developer)

1. Have a test copy of the game (never the Steam install), for example `D:\POSTAL2-coop-test`. Visual Studio with the x86 tools is required (found with vswhere, or set `VCVARS`).
   The tools default to the copy in `P2COOP_TEST_GAME` (or pass `-System <copy>\System`).
2. `tools\ucc5100\build.bat <copy>\System` builds P2Ucc and P2CoopHk (`System\dinput8.dll`).
3. `tools\build_mod.ps1` builds `P2Coop.u` from `Classes/`.
4. `link\build.bat <copy>` builds P2CoopLink and the mock. The real `steam_api.dll` goes in `link\redist\`; see link/README.md for source and SHA-256.
5. `install\make_release.ps1` writes `release\P2Coop\` (no game files in it).

## Play

See install/README.txt (the file that comes with a release): install once with `install.ps1` (it finds POSTAL 2
by itself, or give `-Game`), press Play in Steam as always, pick Co-op in the main menu. The
relay starts and stops with the game; no separate launcher.

## Test

`tools\run_suite.ps1 [-Relay]` runs the in-game tests with real game copies on this PC. It starts
one host and 1-2 clients of the stock `Postal2.exe`, silent, with the windows side by side on the
primary monitor (`-Display \\.\DISPLAY2` on `run_local.ps1`, or `display=` in `tools\testgame.local`, picks another). Each test prints `RESULT: PASS|FAIL`. With `-Relay` all traffic goes through
P2CoopLink and a mock `steam_api.dll`.
`tools\menu_e2e.ps1` (uses the copy's slot and mock settings from `tools\testgame.local`; fails when a copy crashes) creates a game on the Co-op menu's Steam page and joins it from the list
there, over the mock relay; the host's game must start as a new game (not marked cheated).
`install\install.ps1 -SelfTest` checks the Postal2.ini edit and its undo.
For environments without graphics acceleration, put `renderer=Engine.NullRenderDevice` in
`tools/testgame.local` (or set `P2COOP_TEST_RENDERER`). This runs network and HUD logic without
displaying the rendered scene; visual appearance still needs a normal renderer.

| Test | Checks |
|---|---|
| combat | client sees host and NPCs, both move, weapon switch, damage both ways |
| nameplates | client sees the host's name and damaged health fraction; self, walls, distance, dead players and targets behind the camera are hidden |
| revive | downed controls and prone pose, host/client urine-stream revives, restored movement, full bleed-out, respawn and team wipe |
| travel | client-triggered trip there and back, items and GameState kept |
| errand | client picks up an errand item, errand done for everyone, the client crosses it out on its map |
| screens | client's copy of the day, errands, haters and wanted level; its map (server request and map key), newspaper |
| ragdoll | the host's ragdolls lie in the same place on the client: off-view kills, female, fat, big and mini people, animals |
| cutscene | client watches through the host's camera, no damage meanwhile, plays on afterwards |
| jail | client arrested: everyone in jail together, both players' weapons in the evidence room |
| death | client and leader respawn next to a living teammate, no reload |
| load | host loads a save, clients reconnect and keep their saved items |
| leaderdead | a client takes a level exit while the leader is dead: the leader respawns and the group travels |

Last runs (2026-10-24), each on its own feature branch: the first eight tests 8/8 direct and 8/8
through the relay (mock Steam), menu_e2e PASS; leaderdead, ragdoll, nameplates (11 checks) and
revive (25 checks) passed there too, nameplates and revive with Engine.NullRenderDevice. The
whole suite has not run since they were merged. The new features' graphical appearance and relay
behavior have not been verified; not tried with two real Steam accounts.

## Status

Done: the week in co-op, client screens and HUD, cutscenes, group jail, the
Co-op menu, installer. Not done: Paradise Lost, a bot playing Monday through.
Known: quitting after a co-op session fails in the engine's object cleanup; P2CoopHk contains it,
so the game closes normally.

P2Coop co-op mod by PhoenixllGames. MIT License (LICENSE); third-party parts in THIRD_PARTY.md.
