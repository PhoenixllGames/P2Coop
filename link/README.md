# P2CoopLink: POSTAL 2 co-op over Steam (Spacewar, AppID 480)

A small console relay. The game keeps its own UDP netcode; P2CoopLink carries those packets over
Steam's relay network (`ISteamNetworkingMessages`), so nobody needs an IP address or an open port.

```
host:  P2CoopHost.exe (listen, 127.0.0.1:7777) <-UDP-> P2CoopLink host ==Steam== P2CoopLink join <-UDP-> P2CoopHost.exe
```

Based on HXCoop's relay (`steamlink/hxcoop.c` in
[cranebeaker/deus-ex-coop](https://github.com/cranebeaker/deus-ex-coop), MIT), with "P2Coop:"
changes:
- It starts the POSTAL 2 exes, without SteamAppId/SteamGameId in their environment, so the game keeps its own app id.
- Before any game traffic, the joiner and the host compare `link=<protocol> game=<Version.ini> p2coop=<SHA-256 of System\P2Coop.u>`. A mismatch is refused with both versions in the message. Only checked peers get their packets relayed.
- The sender identity is read at offset 12 first, as in the real 32-bit `steam_api.dll`.
- The game's Co-op menu can run it (P2CoopHk.dll): `--no-launch` for the game that is already running,
  `--game-pid` to quit with it, `--status-file` for the menu to read (`hosting`, `searching`, `choose`,
  `joining`, `ready 127.0.0.1:<port>`, `error <message>`).
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
```

## Build and test

`link\build.bat <POSTAL 2 folder>` builds with Visual Studio (x86) and installs `P2CoopLinkMock\`
(the mock `steam_api.dll` from `mock\`, for tests) and, when `link\redist\steam_api.dll` exists,
`P2CoopLink\` with the real DLL.

`tools\run_local.ps1 -Relay ...` runs the same in-game tests with every copy going through
P2CoopLink and the mock.
