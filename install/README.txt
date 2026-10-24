POSTAL 2 co-op (P2Coop) - play the POSTAL 2 week together over Steam
=====================================================================

Needs: POSTAL 2 from Steam, current build (5100), on every player's PC. Steam running.

Install (every player, with POSTAL 2 closed):
  Right-click install.ps1 > "Run with PowerShell" (it finds POSTAL 2 in your Steam library and
  waits for Enter at the end so you can read the result), or in PowerShell:
    powershell -ExecutionPolicy Bypass -File install.ps1 -Game "C:\...\steamapps\common\POSTAL2Complete"
  It adds files and replaces none: System\P2Coop.u, System\P2CoopRu.int, System\dinput8.dll (the
  co-op engine fixes; the game loads it and it passes DirectInput on to Windows) and the
  P2CoopLink folder (the Steam relay). It also turns on the Co-op menu and co-op network settings
  in System\Postal2.ini, after saving it as System\Postal2.ini.p2coop-backup.
  Add -DryRun to see what it would change without changing anything.
  Remove with:  install.ps1 -Game "..." -Uninstall
  (removes the files and puts the Postal2.ini settings it changed back as they were; it stops
  with a list if a file could not be removed, e.g. because the game is still running).
  Install once: later updates run the same install.ps1 again; your settings stay.
  Single player plays as before.

Play:
  Press Play in Steam as always (no other launcher) and pick Co-op in the main menu:
    Play over Steam        your Steam friends' co-op games: click one to join it. "Create game"
                           starts a new game (Monday) that your friends can join; no ports to
                           open. An accepted Steam invite joins too.
    Host / Join by address LAN, or the host forwards UDP port 7777
  Steam shows you as playing "Spacewar" while the relay runs; that is the free Steam app id it uses.
  The relay has no window; it stops with the game, or when you leave the Steam page before a game
  starts. Its output is in P2CoopLink\P2CoopLink-host.log or P2CoopLink-join.log.
  Everybody needs the same game files: a player with another game language, version or mod is
  refused with a message that says why. The host only accepts players of its own Steam lobby.

How it plays:
  - The host is the leader: the day and the story run on the host's game. Anybody can do
    errands; everyone sees them on their own map and newspaper, and the wanted meter on the HUD.
  - Any player's telepad moves the whole group to the next map.
  - Cutscenes: the others watch through the host's camera.
  - Arrested: the whole group goes to jail, everyone's things go to the evidence room.
  - A dead player comes back next to a living teammate after 10 s. If everybody is dead, the host
    loads the last save.
  - Only the host saves. After loading, the host returns to the saved map with the day and errands;
    the others reconnect by themselves and keep what they carried. Positions start at the map start.
  - A player whose game drops out and who rejoins on the same map gets his things back.

Known limits: Paradise Lost is not supported. Not yet tried with two real Steam accounts (only
with a local Steam stand-in). If another mod already uses System\dinput8.dll, the installer stops
and says so.

P2Coop co-op mod by PhoenixllGames.
