# P2Ucc: UCC for POSTAL 2 build 5100

POSTAL 2 5100 ships no `UCC.exe`, and the one in `ShareThePain\System` is built for an older
engine. Its TCHAR is `unsigned short`, while 5100 uses `wchar_t`. Even with the names remapped,
it crashes in `UObject::GetDriverClasses` because its header-only config cache, malloc and file
manager don't match 5100.

P2Ucc reuses the game's own exe instead:

- `P2Ucc.exe` is a byte copy of `Postal2.exe`. The only change is the import name `COMDLG32.dll`, renamed to `P2UccHk.dll` (`patchexe.py`).
- `P2UccHk.dll` (`p2ucchk.cpp`) redirects the exe's import of `Core.dll!appInit`. The exe initialises the engine with its own 5100 objects. The hook then loads the commandlet class, constructs it, calls `UCommandlet::Main` through the vtable and exits. This happens before any window or game engine exists.

## P2CoopHk: the co-op engine fixes, as System\dinput8.dll

The game gets engine fixes that UnrealScript cannot reach without any change to its files:

- `WinDrv.dll` imports `DINPUT8.dll`, which is not one of Windows' KnownDLLs, so a `dinput8.dll` in `System` (the exe's folder) is loaded first. P2CoopHk (`p2coophk.cpp`) is built as that DLL: the stock `Postal2.exe`, as Steam's Play button starts it, loads it for host, clients and single player alike. Its DirectInput8 exports (`DirectInput8Create`, `DllGetClassObject`, ...) go on to the system `dinput8.dll`, loaded by full path.
- The engine loads `WinDrv.dll` when it creates its client, after Core and Engine are up, so the hooks go in from `DllMain`.
- Fix 1: a save on a listen server no longer crashes the next client `JOIN`. During `UGameEngine::SaveGame`, `UObject::ResetLoaders` still loads the level's lazy data, but the level linker is not deleted.
- Fix 2: quitting after a co-op session no longer shows a crash window: a failure inside `UObject::StaticExit` ends the object cleanup, and the game exits normally.
- The Co-op menu starts and watches the Steam relay through console commands (`P2COOP LINK LIST|HOST|JOIN|STATUS|STOP`, a hook on `UGameEngine::Exec`); the relay runs without a console window.
- Tests: `P2COOP_WINDOW_POS` places the game window (`bgwindows.h`), `P2COOP MENUTEST` picks in the menu.
- Hooks go through the exported vtables and the `E9 rel32` jump thunks of the incrementally linked 5100 DLLs (`iathook.h`). Everything is looked up first; if something does not fit (another game build), nothing is hooked, the log says so, and the game runs stock.
- The installer recognises its own `dinput8.dll` by the export `P2CoopHkVersion` and does not overwrite another mod's.

## Build

Visual Studio with the x86 toolset is required. Install into the **test copy** only:

```bat
tools\ucc5100\build.bat <test copy>\System
```

## Use

Run from the game's `System` folder. Output goes to `P2Ucc.log`.

```bat
P2Ucc.exe make ini=P2Coop.ini
P2Ucc.exe batchexport P2Coop.u class uc <out dir>
```

`P2Coop.ini` is `Postal2.ini` with `EditPackages=P2Coop` appended to `[Editor.EditorEngine]`.
`make` compiles `..\P2Coop\Classes\*.uc` into `System\P2Coop.u`.

## Checked (2026-10-24, build 11052972)

- `make ini=P2Coop.ini`: compiles a one-class package, exit 0. A syntax error stops it with "Failed due to errors", exit 1, no dialog and no `.u` written.
- `batchexport` round-trips `P2Coop.u`.
- `batchexport Core.u` exports `Object` and `Subsystem`, then asserts `Class->ScriptText` (UnEdExp.cpp:633). Shipped packages have script text stripped from at least some classes.
