# Third-party parts

- **link/p2cooplink.c** is a port of HXCoop's Steam relay (`steamlink/hxcoop.c` in
  [cranebeaker/deus-ex-coop](https://github.com/cranebeaker/deus-ex-coop)), MIT License,
  Copyright (c) 2026 cranebeaker and contributors. The changes for POSTAL 2 are marked "P2Coop:".
- **steam_api.dll** (Valve's Steamworks API, from the Steamworks.NET 2025.164.1 standalone
  release; source and SHA-256 in link/README.md) is not in this repository. Release archives
  include it in `P2Coop/P2CoopLink/` as the Steam redistributable the relay needs.
- **POSTAL 2** (Running With Scissors) is not included in any form. The repository and the
  release contain no game files, assets or decompiled game scripts. P2CoopHost.exe is made on
  the player's PC from their own `Postal2.exe` by `install/install.ps1`. The game's scripts were
  read locally with [UE Explorer](https://github.com/UE-Explorer/UE-Explorer) for this work (the
  `export/` folder is not published).
- The co-op approach and test tools follow
  [cranebeaker/coop-anything](https://github.com/cranebeaker/coop-anything).
