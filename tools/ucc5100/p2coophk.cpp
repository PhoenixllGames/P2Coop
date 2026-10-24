// P2CoopHk: engine fixes for co-op and the Co-op menu's control of the Steam relay, built as
// System\dinput8.dll. The game's WinDrv.dll imports DINPUT8.dll, which is not one of Windows'
// KnownDLLs, so the copy in the exe's folder (System) is loaded first. The stock Postal2.exe, as
// Steam's Play button starts it, therefore loads these fixes for single player and co-op alike,
// and no game file is changed. The DirectInput8 exports go on to the system dinput8.dll
// (RealDinput below). The engine loads WinDrv.dll when it creates its client, after Core and Engine
// are up and before any of these hooks is needed, so they go in from DllMain. A build these hooks
// do not fit is logged and left alone: the game still starts (without the fixes or Steam co-op).
//
// Fix 1, save on a listen server: UGameEngine::SaveGame saves through UObject::SavePackage, which
// calls UObject::ResetLoaders(LevelPackage, 0, 1) inside Core.dll. That loads the level's lazy data
// (needed in the save) and then deletes the map's linker. The net driver's master package map keeps
// a pointer to that linker, so the next client JOIN crashes in UPackageMap::Compute, and level
// objects lose their linker index for clients already connected.
// While SaveGame runs, ResetLoaders still runs, but the delete of the level package's linker is
// skipped: the lazy data gets loaded, the linker and the objects' links stay intact. The save goes
// to a different file (Save\SaveNN.usa), so nothing needs the map file closed.
//
// Fix 2, crash on quit: after a co-op session, destroying the objects on exit (UObject::StaticExit
// -> PurgeGarbage) sometimes hits an object that is already broken (GetFullName fails on it), and
// the game shows its crash window while quitting. The stock game does it too. By then
// everything worth keeping is saved, and the config is written later (appExit), so a failure
// inside StaticExit ends just that step: the rest of the object cleanup is skipped.

#include <windows.h>
#include <strsafe.h>
#include "iathook.h"
#include "ue2.h"
#include "bgwindows.h"

typedef void (__cdecl *ResetLoadersFn)(void* Pkg, int DynamicOnly, int ForceLazyLoad);
typedef void* (__cdecl *GetPackageLinkerFn)(void* Outer, const wchar_t* File, DWORD Flags, void* Sandbox, void* Guid);
typedef int (__thiscall *SaveGameFn)(void* This, int Position);
typedef void* (__thiscall *DeletingDtorFn)(void* This, unsigned int Flags);
typedef void (__cdecl *LogfFn)(void* This, const wchar_t* Fmt, ...);
typedef void (__cdecl *VoidFn)();
typedef int (__thiscall *ExecFn)(void* This, const wchar_t* Cmd, void* Ar);

static const char* const kResetLoaders = "?ResetLoaders@UObject@@SAXPAV1@HH@Z";

static HMODULE GCore;
static ResetLoadersFn RealResetLoaders;
static GetPackageLinkerFn GetPackageLinker;
static VoidFn BeginLoad, EndLoad;
static SaveGameFn RealSaveGame;
static DeletingDtorFn RealLinkerDtor;
static void** GLinkerVtable;
static void* GKeepLinker;
static LogfFn Logf;
static void** GLogPtr;
static int GInSave;
static VoidFn RealStaticExit;
static int* GIsCriticalErrorPtr;

static void Log(const wchar_t* Text)
{
    if (Logf && GLogPtr && *GLogPtr)
        Logf(*GLogPtr, L"%s", Text);
}

static BOOL InCore(void* P)
{
    MEMORY_BASIC_INFORMATION Mbi;
    return VirtualQuery(P, &Mbi, sizeof(Mbi)) && Mbi.AllocationBase == (void*)GCore;
}

// UObject vtable: slots 0-2 are FUnknown (QueryInterface, AddRef, Release), slot 3 is the
// (vector) deleting destructor, unnamed in the exports; its code tests the delete flags 2 and 1.
static const int kDeletingDtorSlot = 3;

// ULinkerLoad's deleting destructor.
static void* __fastcall HkLinkerDtor(void* This, void* /*Edx*/, unsigned int Flags)
{
    if (This == GKeepLinker)
    {
        Log(L"P2CoopHk: SaveGame kept the level linker (lazy data loaded, delete skipped)");
        GKeepLinker = NULL;
        return This;
    }
    return RealLinkerDtor(This, Flags);
}

// Hooks the deleting destructor of ULinkerLoad, found through the vtable of a live linker.
static BOOL HookLinkerDtor(void* Linker)
{
    if (RealLinkerDtor)
        return TRUE;
    void** Vtable = *(void***)Linker;
    void** Slot = &Vtable[kDeletingDtorSlot];
    if (!InCore(Vtable) || !InCore(*Slot))
        return FALSE;
    RealLinkerDtor = (DeletingDtorFn)*Slot;
    DWORD Prot;
    VirtualProtect(Slot, sizeof(void*), PAGE_READWRITE, &Prot);
    *Slot = (void*)&HkLinkerDtor;
    VirtualProtect(Slot, sizeof(void*), Prot, &Prot);
    GLinkerVtable = Vtable;
    return TRUE;
}

static void __cdecl HkResetLoaders(void* Pkg, int DynamicOnly, int ForceLazyLoad)
{
    if (GInSave && Pkg && !DynamicOnly)
    {
        // An existing linker is returned as is; nothing is loaded for an already loaded package.
        // GetPackageLinker asserts outside a BeginLoad/EndLoad pair (UnObj.cpp:2215).
        BeginLoad();
        void* Linker = GetPackageLinker(Pkg, NULL, LOAD_NoWarn | LOAD_Quiet, NULL, NULL);
        EndLoad();
        if (Linker && HookLinkerDtor(Linker))
            GKeepLinker = Linker;
        else
            Log(L"P2CoopHk: could not protect the level linker; the next JOIN may crash");
    }
    RealResetLoaders(Pkg, DynamicOnly, ForceLazyLoad);
    GKeepLinker = NULL;
}

// Called through the UGameEngine vtable; __fastcall gets 'this' in ECX like __thiscall
// (EDX is the unused second register argument).
static int __fastcall HkSaveGame(void* This, void* /*Edx*/, int Position)
{
    GInSave++;
    int Result = RealSaveGame(This, Position);
    GInSave--;
    return Result;
}

static void __cdecl HkStaticExit()
{
    __try
    {
        RealStaticExit();
    }
    __except (EXCEPTION_EXECUTE_HANDLER)
    {
        if (GIsCriticalErrorPtr)
            *GIsCriticalErrorPtr = 0;
        Log(L"P2CoopHk: an object failed to shut down on exit; skipped the rest of the object cleanup");
    }
}

// Fix 3 (a feature): the Co-op menu (CoopSteamMenu.uc) talks to the Steam relay through console
// commands, which UnrealScript sends with ConsoleCommand and which end in UGameEngine::Exec:
//   P2COOP LINK LIST                start P2CoopLink listing the friends who host (it takes invites too)
//   P2COOP LINK HOST <map> <port>   start P2CoopLink as host of the game this exe is about to run
//   P2COOP LINK JOIN <lobby id>     start P2CoopLink as joiner of that friend's lobby
//   P2COOP LINK STATUS              the relay's status line ("none" when no relay was started)
//   P2COOP LINK STOP                close the relay
//   P2COOP MENUTEST                 tests: P2COOP_MENU_TEST ("host"/"join": CoopRootWindow picks it)
// The relay runs with --no-launch (this game is the game), --game-pid (it quits with the game and
// never waits for a key), --status-file, which STATUS returns, --log (see link/p2cooplink.c) and
// --stop-event: STOP sets that event and the relay closes the way it does when the game quits
// (goodbye to the peers, out of the lobby and off Steam); it is killed only if it has not
// gone after a few seconds.
// It has no console window, and its environment has no SteamAppId/SteamGameId (they would make
// it POSTAL 2 instead of Spacewar for Steam).
static ExecFn RealExec;
static PROCESS_INFORMATION GLink;
static HANDLE GLinkStop;
static DWORD GLinkCount;
static wchar_t GLinkDir[MAX_PATH], GStatusFile[MAX_PATH];

// TRUE if S starts with Prefix (case-insensitive). CompareStringW with a length does not stop at
// a NUL, so the length of S is checked first.
static BOOL PrefixI(const wchar_t* S, const wchar_t* Prefix)
{
    int N = lstrlenW(Prefix);
    for (int i = 0; i < N; i++)
        if (!S[i])
            return FALSE;
    return CompareStringW(LOCALE_INVARIANT, NORM_IGNORECASE, S, N, Prefix, N) == CSTR_EQUAL;
}

// Skips Word (case-insensitive, then a space or the end) at *Cmd.
static BOOL Word(const wchar_t** Cmd, const wchar_t* W)
{
    const wchar_t* C = *Cmd;
    while (*C == L' ')
        C++;
    int N = lstrlenW(W);
    if (!PrefixI(C, W) || (C[N] && C[N] != L' '))
        return FALSE;
    C += N;
    while (*C == L' ')
        C++;
    *Cmd = C;
    return TRUE;
}

// Copies the next space-separated token of *Cmd into Out.
static void Token(const wchar_t** Cmd, wchar_t* Out, int Size)
{
    const wchar_t* C = *Cmd;
    int N = 0;
    while (*C && *C != L' ' && N < Size - 1)
        Out[N++] = *C++;
    Out[N] = 0;
    while (*C == L' ')
        C++;
    *Cmd = C;
}

// TRUE if Text is 1 to Max characters, all from Allowed: what goes on the relay's command line.
static BOOL Plain(const wchar_t* Text, const wchar_t* Allowed, int Max)
{
    int N = lstrlenW(Text);
    if (N < 1 || N > Max)
        return FALSE;
    for (const wchar_t* P = Text; *P; P++)
    {
        const wchar_t* A = Allowed;
        while (*A && *A != *P)
            A++;
        if (!*A)
            return FALSE;
    }
    return TRUE;
}

static const wchar_t kDigits[] = L"0123456789";
static const wchar_t kMapChars[] = L"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.";

static BOOL LinkRunning()
{
    return GLink.hProcess && WaitForSingleObject(GLink.hProcess, 0) == WAIT_TIMEOUT;
}

static void StopLink()
{
    if (LinkRunning())
    {
        // A relay that does not answer the stop event is killed; either way it is gone before
        // its status file goes and before a new relay starts.
        if (!GLinkStop || !SetEvent(GLinkStop) || WaitForSingleObject(GLink.hProcess, 3000) != WAIT_OBJECT_0)
        {
            TerminateProcess(GLink.hProcess, 0);
            WaitForSingleObject(GLink.hProcess, 2000);
        }
    }
    if (GLinkStop)
    {
        CloseHandle(GLinkStop);
        GLinkStop = NULL;
    }
    if (GLink.hProcess)
    {
        CloseHandle(GLink.hProcess);
        CloseHandle(GLink.hThread);
        DeleteFileW(GStatusFile);
    }
    ZeroMemory(&GLink, sizeof(GLink));
}

// This process's environment without SteamAppId/SteamGameId, as a Unicode block. Caller frees.
static wchar_t* LinkEnvironment()
{
    wchar_t* Env = GetEnvironmentStringsW();
    int Total = 0;
    for (wchar_t* P = Env; *P; P += lstrlenW(P) + 1)
        Total += lstrlenW(P) + 1;
    wchar_t* Out = (wchar_t*)HeapAlloc(GetProcessHeap(), 0, (Total + 2) * sizeof(wchar_t));
    wchar_t* O = Out;
    for (wchar_t* P = Env; *P; P += lstrlenW(P) + 1)
    {
        if (PrefixI(P, L"SteamAppId=") || PrefixI(P, L"SteamGameId="))
            continue;
        lstrcpyW(O, P);
        O += lstrlenW(P) + 1;
    }
    *O++ = 0;
    if (O == Out + 1)
        *O++ = 0;
    FreeEnvironmentStringsW(Env);
    return Out;
}

// The relay folder: <POSTAL 2>\P2CoopLink, next to System\ (where this exe is), or
// P2COOP_LINK_DIR (tests: the relay with the mock Steam). The status file is this game's own:
// two test copies share the mock relay's folder. A path too long for these buffers leaves
// GStatusFile empty, and StartLink refuses to start the relay.
static void FindLinkDir()
{
    GStatusFile[0] = 0;
    if (GetEnvironmentVariableW(L"P2COOP_LINK_DIR", GLinkDir, MAX_PATH) - 1 >= MAX_PATH - 1)
    {
        DWORD N = GetModuleFileNameW(NULL, GLinkDir, MAX_PATH);
        if (N == 0 || N >= MAX_PATH)
        {
            GLinkDir[0] = 0;
            return;
        }
        for (int i = 0; i < 2; i++)
        {
            wchar_t* Slash = NULL;
            for (wchar_t* P = GLinkDir; *P; P++)
                if (*P == L'\\')
                    Slash = P;
            if (Slash)
                *Slash = 0;
        }
        if (FAILED(StringCchCatW(GLinkDir, MAX_PATH, L"\\P2CoopLink")))
        {
            GLinkDir[0] = 0;
            return;
        }
    }
    if (FAILED(StringCchPrintfW(GStatusFile, MAX_PATH, L"%s\\menu-status-%lu.txt", GLinkDir, GetCurrentProcessId())))
        GStatusFile[0] = 0;
}

static const wchar_t* StartLink(const wchar_t* Args, const wchar_t* LogName)
{
    wchar_t Exe[MAX_PATH], LogFile[MAX_PATH], StopName[64], CmdLine[2048];
    StopLink();
    if (!GStatusFile[0]
        || FAILED(StringCchPrintfW(Exe, MAX_PATH, L"%s\\P2CoopLink.exe", GLinkDir))
        || FAILED(StringCchPrintfW(LogFile, MAX_PATH, L"%s\\%s", GLinkDir, LogName)))
        return L"error the game folder path is too long for P2CoopLink";
    if (GetFileAttributesW(Exe) == INVALID_FILE_ATTRIBUTES)
        return L"error P2CoopLink is not installed (no P2CoopLink folder next to System)";
    StringCchPrintfW(StopName, 64, L"Local\\P2CoopLinkStop-%lu-%lu", GetCurrentProcessId(), ++GLinkCount);
    GLinkStop = CreateEventW(NULL, TRUE, FALSE, StopName);
    if (FAILED(StringCchPrintfW(CmdLine, 2048,
                                L"\"%s\" %s --no-launch --status-file \"%s\" --log \"%s\" --game-pid %lu --stop-event %s",
                                Exe, Args, GStatusFile, LogFile, GetCurrentProcessId(), StopName)))
    {
        if (GLinkStop)
            CloseHandle(GLinkStop);
        GLinkStop = NULL;
        return L"error the game folder path is too long for P2CoopLink";
    }
    DeleteFileW(GStatusFile);
    STARTUPINFOW Si;
    ZeroMemory(&Si, sizeof(Si));
    Si.cb = sizeof(Si);
    wchar_t* Env = LinkEnvironment();
    BOOL Ok = CreateProcessW(Exe, CmdLine, NULL, NULL, FALSE, CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT,
                             Env, GLinkDir, &Si, &GLink);
    HeapFree(GetProcessHeap(), 0, Env);
    if (!Ok)
    {
        ZeroMemory(&GLink, sizeof(GLink));
        if (GLinkStop)
            CloseHandle(GLinkStop);
        GLinkStop = NULL;
        return L"error could not start P2CoopLink";
    }
    return L"started";
}

// The relay's status line. "hosts" lists friends' games, tab separated, so it can be long.
static void LinkStatus(void* Ar)
{
    static char Line[4096];
    static wchar_t Wide[4096];
    Line[0] = 0;
    HANDLE F = CreateFileW(GStatusFile, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           NULL, OPEN_EXISTING, 0, NULL);
    if (F != INVALID_HANDLE_VALUE)
    {
        DWORD Got = 0;
        ReadFile(F, Line, sizeof(Line) - 1, &Got, NULL);
        Line[Got] = 0;
        CloseHandle(F);
    }
    if (!MultiByteToWideChar(CP_UTF8, 0, Line, -1, Wide, 4096))
        Wide[0] = 0;
    if (!GLink.hProcess)
        Logf(Ar, L"none");
    else if (!LinkRunning() && !PrefixI(Wide, L"error"))
        Logf(Ar, L"error the Steam relay closed (%s)", Wide[0] ? Wide : L"no status");
    else
        Logf(Ar, L"%s", Wide[0] ? Wide : L"starting");
}

static int __fastcall HkExec(void* This, void* /*Edx*/, const wchar_t* Cmd, void* Ar)
{
    const wchar_t* C = Cmd;
    if (!Word(&C, L"P2COOP"))
        return RealExec(This, Cmd, Ar);
    if (Word(&C, L"MENUTEST"))
    {
        wchar_t Pick[16] = L"";
        GetEnvironmentVariableW(L"P2COOP_MENU_TEST", Pick, 16);
        Logf(Ar, L"%s", Pick[0] ? Pick : L"none");
        return 1;
    }
    if (!Word(&C, L"LINK"))
        return RealExec(This, Cmd, Ar);
    wchar_t Args[300];
    if (Word(&C, L"LIST"))
        Logf(Ar, L"%s", StartLink(L"list", L"P2CoopLink-join.log"));
    else if (Word(&C, L"HOST"))
    {
        wchar_t Map[128], Port[16];
        Token(&C, Map, 128);
        Token(&C, Port, 16);
        if (!Map[0])
            lstrcpyW(Map, L"suburbs-3");
        if (!Port[0])
            lstrcpyW(Port, L"7777");
        if (!Plain(Map, kMapChars, 100) || !Plain(Port, kDigits, 5))
            Logf(Ar, L"error bad map or port");
        else
        {
            StringCchPrintfW(Args, 300, L"host %s --port %s", Map, Port);
            Logf(Ar, L"%s", StartLink(Args, L"P2CoopLink-host.log"));
        }
    }
    else if (Word(&C, L"JOIN"))
    {
        wchar_t Lobby[32];
        Token(&C, Lobby, 32);
        if (!Plain(Lobby, kDigits, 20))
            Logf(Ar, L"error no lobby id to join");
        else
        {
            StringCchPrintfW(Args, 300, L"join %s", Lobby);
            Logf(Ar, L"%s", StartLink(Args, L"P2CoopLink-join.log"));
        }
    }
    else if (Word(&C, L"STATUS"))
        LinkStatus(Ar);
    else if (Word(&C, L"STOP"))
    {
        StopLink();
        Logf(Ar, L"stopped");
    }
    else
        Logf(Ar, L"usage: P2COOP LINK LIST | HOST <map> <port> | JOIN <lobby id> | STATUS | STOP");
    return 1;
}

static BOOL Install()
{
    GCore = GetModuleHandleW(L"Core.dll");
    HMODULE Engine = GetModuleHandleW(L"Engine.dll");
    if (!GCore || !Engine)
        return FALSE;

    Logf = (LogfFn)GetProcAddress(GCore, "?Logf@FOutputDevice@@QAAXPB_WZZ");
    GLogPtr = (void**)GetProcAddress(GCore, "?GLog@@3PAVFOutputDevice@@A");
    GetPackageLinker = (GetPackageLinkerFn)GetProcAddress(GCore,
        "?GetPackageLinker@UObject@@SAPAVULinkerLoad@@PAV1@PB_WKPAVUPackageMap@@PAVFGuid@@@Z");
    BeginLoad = (VoidFn)GetProcAddress(GCore, "?BeginLoad@UObject@@SAXXZ");
    EndLoad = (VoidFn)GetProcAddress(GCore, "?EndLoad@UObject@@SAXXZ");
    GIsCriticalErrorPtr = (int*)GetProcAddress(GCore, "?GIsCriticalError@@3HA");
    RealSaveGame = (SaveGameFn)GetProcAddress(Engine, "?SaveGame@UGameEngine@@UAEHH@Z");
    void** Vtable = (void**)GetProcAddress(Engine, "??_7UGameEngine@@6BUObject@@@");
    BYTE* ResetLoadersThunk = (BYTE*)GetProcAddress(GCore, kResetLoaders);
    BYTE* StaticExitThunk = (BYTE*)GetProcAddress(GCore, "?StaticExit@UObject@@SAXXZ");
    BYTE* ExecThunk = (BYTE*)GetProcAddress(Engine, "?Exec@UGameEngine@@UAEHPB_WAAVFOutputDevice@@@Z");
    // Everything is looked up before anything is patched: a build the hooks do not fit stays stock.
    if (!Logf || !GLogPtr || !GetPackageLinker || !BeginLoad || !EndLoad || !RealSaveGame || !Vtable
        || !ResetLoadersThunk || !StaticExitThunk || !ExecThunk
        || ResetLoadersThunk[0] != 0xE9 || StaticExitThunk[0] != 0xE9 || ExecThunk[0] != 0xE9)
        return FALSE;
    if (!HookVtableSlot(Vtable, (void*)RealSaveGame, (void*)&HkSaveGame))
        return FALSE;
    // Through Core's own jump thunk: SavePackage calls ResetLoaders inside Core.dll.
    RealResetLoaders = (ResetLoadersFn)HookJmpThunk(ResetLoadersThunk, (void*)&HkResetLoaders);
    // appPreExit calls StaticExit inside Core.dll, through the same kind of thunk.
    RealStaticExit = (VoidFn)HookJmpThunk(StaticExitThunk, (void*)&HkStaticExit);
    FindLinkDir();
    RealExec = (ExecFn)HookJmpThunk(ExecThunk, (void*)&HkExec);
    return TRUE;
}

// ---------------------------------------------------------------- dinput8.dll exports

static HMODULE GRealDinput;

// The system's dinput8.dll (SysWOW64 for this 32 bit game), by full path: the bare name would
// find this DLL again.
static FARPROC RealDinput(const char* Name)
{
    if (!GRealDinput)
    {
        wchar_t Path[MAX_PATH];
        UINT N = GetSystemDirectoryW(Path, MAX_PATH);
        if (N == 0 || N > MAX_PATH - 16)
            return NULL;
        lstrcatW(Path, L"\\dinput8.dll");
        GRealDinput = LoadLibraryW(Path);
    }
    return GRealDinput ? GetProcAddress(GRealDinput, Name) : NULL;
}

extern "C" HRESULT WINAPI HkDirectInput8Create(HINSTANCE Inst, DWORD Version, REFIID Iid, void** Out, IUnknown* Outer)
{
    typedef HRESULT (WINAPI *Fn)(HINSTANCE, DWORD, REFIID, void**, IUnknown*);
    Fn Real = (Fn)RealDinput("DirectInput8Create");
    // WinDrv.dll calls this while it sets up, before it opens the game window (tests: placement).
    if (GBgX != INT_MIN || GBgFocus)
        BgPatchModule(GetModuleHandleW(L"WinDrv.dll"));
    if (!Real)
    {
        if (Out)
            *Out = NULL;
        return E_FAIL;
    }
    return Real(Inst, Version, Iid, Out, Outer);
}

extern "C" HRESULT WINAPI HkDllCanUnloadNow()
{
    typedef HRESULT (WINAPI *Fn)();
    Fn Real = GRealDinput ? (Fn)GetProcAddress(GRealDinput, "DllCanUnloadNow") : NULL;
    return Real ? Real() : S_FALSE;
}

extern "C" HRESULT WINAPI HkDllGetClassObject(REFCLSID Clsid, REFIID Iid, void** Out)
{
    typedef HRESULT (WINAPI *Fn)(REFCLSID, REFIID, void**);
    Fn Real = (Fn)RealDinput("DllGetClassObject");
    if (!Real)
    {
        if (Out)
            *Out = NULL;
        return CLASS_E_CLASSNOTAVAILABLE;
    }
    return Real(Clsid, Iid, Out);
}

extern "C" HRESULT WINAPI HkDllRegisterServer()
{
    typedef HRESULT (WINAPI *Fn)();
    Fn Real = (Fn)RealDinput("DllRegisterServer");
    return Real ? Real() : E_FAIL;
}

extern "C" HRESULT WINAPI HkDllUnregisterServer()
{
    typedef HRESULT (WINAPI *Fn)();
    Fn Real = (Fn)RealDinput("DllUnregisterServer");
    return Real ? Real() : E_FAIL;
}

extern "C" const void* WINAPI HkGetdfDIJoystick()
{
    typedef const void* (WINAPI *Fn)();
    Fn Real = (Fn)RealDinput("GetdfDIJoystick");
    return Real ? Real() : NULL;
}

// The installer knows its own dinput8.dll by this export, and leaves any other one alone.
extern "C" int WINAPI P2CoopHkVersion()
{
    return 2;
}

BOOL WINAPI DllMain(HINSTANCE, DWORD Reason, LPVOID)
{
    if (Reason == DLL_PROCESS_DETACH)
    {
        if (GLink.hProcess)
            DeleteFileW(GStatusFile);
        return TRUE;
    }
    if (Reason != DLL_PROCESS_ATTACH)
        return TRUE;
    // Only the game itself (Core and Engine loaded) gets the hooks; anything else that loads this
    // DLL gets plain DirectInput.
    if (!GetModuleHandleW(L"Core.dll") || !GetModuleHandleW(L"Engine.dll"))
        return TRUE;
    BgInstall();    // tests only (P2COOP_WINDOW_POS, P2COOP_BACKGROUND), see bgwindows.h
    if (Install())
        Log(L"P2CoopHk: engine fixes and Steam co-op are on (System\\dinput8.dll)");
    else
        Log(L"P2CoopHk: this game build does not fit the engine hooks; the game runs without them");
    return TRUE;
}
