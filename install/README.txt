POSTAL 2 co-op (P2Coop) - play the POSTAL 2 week together over Steam
=====================================================================

Needs: POSTAL 2 from Steam, current build (5100), on every player's PC. Steam running.

Install (every player):
  Right-click install.ps1 > "Run with PowerShell", or in PowerShell:
    powershell -ExecutionPolicy Bypass -File install.ps1 -Game "C:\...\steamapps\common\POSTAL2Complete"
  It only adds files (P2Coop.u, P2CoopHost.exe, P2CoopGame.ini, the P2CoopLink folder, three .bat files).
  Remove with:  install.ps1 -Game "..." -Uninstall

Play:
  Run "P2Coop.bat" in the POSTAL 2 folder and pick Co-op in the main menu:
    Host over Steam        a new game (Monday) that your Steam friends can join, no ports to open
    Join a friend over Steam   finds the Steam friend who hosts (several: pick one in the
                           "POSTAL 2 Co-op (Steam)" window on the taskbar)
    Host / Join by address LAN, or the host forwards UDP port 7777
  Or without the menu: "P2Coop Host.bat" [map] and "P2Coop Join.bat" [lobby id] do the same over Steam
  from a console window (it shows the lobby id; a Steam invite works too).
  Steam shows you as playing "Spacewar" while the relay runs; that is the free Steam app id it uses.

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

Known limits: Paradise Lost is not supported. Not yet tried with two real Steam accounts (only
with a local Steam stand-in).

P2Coop co-op mod by PhoenixllGames.
