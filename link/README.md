# P2CoopLink: POSTAL 2 co-op over Steam (Spacewar, AppID 480)

A small console relay. The game keeps its own UDP netcode; P2CoopLink carries those packets over
Steam's relay network (`ISteamNetworkingMessages`), so nobody needs an IP address or an open port.

```
host:  Postal2.exe (listen, 127.0.0.1:7777) <-UDP-> P2CoopLink host ==Steam== P2CoopLink join <-UDP-> Postal2.exe
```

Based on HXCoop's relay (`steamlink/hxcoop.c` in
[cranebeaker/deus-ex-coop](https://github.com/cranebeaker/deus-ex-coop), MIT), with "P2Coop:"
changes:
- It starts the POSTAL 2 exes, without SteamAppId/SteamGameId in their environment, so the game keeps its own app id.
- Before any game traffic, the joiner and the host compare `link=<protocol> game=<Version.ini> p2coop=<SHA-256 of System\P2Coop.u> hook=<SHA-256 of System\dinput8.dll> pkgs=<SHA-256 over the names and header GUIDs of the Textures, Sounds, StaticMeshes, Animations and System packages> lang=<Steam language>`, field by field. A mismatch is refused with a readable reason: another game language (its localized packages, e.g. `Textures\STV2.utx`, have other GUIDs) is named as such, with both Steam languages (from `steamapps\appmanifest_223470.acf`). The language itself is not compared. Only checked peers get their packets relayed.
- The host takes Steam sessions and peers only from members of its lobby (a session from someone else waits up to 10 s for the lobby entry, then it is closed), drops a peer that has not passed the version check within 5 s, and remembers who passed it while they stay in the lobby, so a peer that comes back after a Steam hiccup or a stall is relayed again.
- A joiner leaves the lobby as soon as the host says goodbye or leaves it (status `error the host closed the game`), then closes. Only lobbies tagged `p2coop` with this protocol are listed or joined (other Spacewar tools use AppID 480 too).
- `--stop-event <name>`: the game's menu sets this event to close the relay the way it closes when the game quits (goodbye, out of the lobby, off Steam); P2CoopHk kills it only if it has not gone after 3 s.
- The sender identity is read at offset 12 first, as in the real 32-bit `steam_api.dll`.
- The game's Co-op menu runs it (P2CoopHk, `System\dinput8.dll`) without a console window: `--no-launch`
  for the game that is already running, `--game-pid` to quit with it, `--log` for its output, and
  `--status-file` for the menu to read (`hosting <lobby>`, `searching`, `hosts` with a tab before each
  lobby id and host name, `joining`, `ready 127.0.0.1:<port>`, `error <message>`).
- `list` (the menu's Steam page) reports the friends' games and waits: the player clicks one there,
  and the menu starts `join <lobby id>`; an accepted Steam invite joins right away. A lobby is listed
  once, under the host's name from the lobby data, although every player in it shows it to their friends.
- Started by the menu (`--status-file` or `--game-pid`) it never waits for a key; an error leaves
  the lobby, clears the rich presence and shuts Steam down before it exits.
- The lobby tag is `p2coop`. It sets `RecvMaxMessageSize`, writes unbuffered output, prints a status line with the relayed packet count, and doesn't wait for a key when its output is redirected.

## Layout

```
<POSTAL 2>\P2CoopLink\P2CoopLink.exe
<POSTAL 2>\P2CoopLink\steam_api.dll     Steamworks.NET Standalone 2025.164.1, Windows-x86
<POSTAL 2>\P2CoopLink\steam_appid.txt   480
```

`steam_api.dll` is not in git (`link/redist/`). It comes from
https://github.com/rlabrecque/Steamworks.NET/releases/tag/2025.164.1,
`Steamworks.NET-Standalone_2025.164.1.zip` (SHA-256 9412348c…537d, which matches GitHub's digest),
file `Windows-x86/steam_api.dll`, SHA-256 `fdafb7c65ec7d4182b42bf92cc8671c68e4dc547cc6e613899d2618a47eb65da`.

## Use

```bat
P2CoopLink.exe host [map]        :: default suburbs-3 (Monday)
P2CoopLink.exe join [lobby id]   :: no id: a Steam friend who is hosting
P2CoopLink.exe list              :: the friends' games, for the game's Co-op menu
```
Players never need these: the game's Co-op menu starts the relay. From a console they start the
game too (`System\Postal2.exe`, `--game-args` for its arguments).

## Build and test

`link\build.bat <POSTAL 2 folder>` builds with Visual Studio (x86) and installs `P2CoopLinkMock\`
(the mock `steam_api.dll` from `mock\`, for tests) and, when `link\redist\steam_api.dll` exists,
`P2CoopLink\` with the real DLL.

`tools\run_local.ps1 -Relay ...` runs the same in-game tests with every copy going through
P2CoopLink and the mock.
