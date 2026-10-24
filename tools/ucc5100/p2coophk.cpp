// P2CoopHk.dll: engine fixes for co-op. Loaded by P2CoopHost.exe, a copy of Postal2.exe that
// imports this DLL instead of COMDLG32.dll (patchexe.py). The host and the clients both run it.
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
#include "iathook.h"
#include "bgwindows.h"

typedef void (__cdecl *ResetLoadersFn)(void* Pkg, int DynamicOnly, int ForceLazyLoad);
typedef void* (__cdecl *GetPackageLinkerFn)(void* Outer, const wchar_t* File, DWORD Flags, void* Sandbox, void* Guid);
typedef int (__thiscall *SaveGameFn)(void* This, int Position);
typedef void* (__thiscall *DeletingDtorFn)(void* This, unsigned int Flags);
typedef void (__cdecl *LogfFn)(void* This, const wchar_t* Fmt, ...);
typedef void (__cdecl *VoidFn)();
typedef int (__thiscall *ExecFn)(void* This, const wchar_t* Cmd, void* Ar);

static const char* const kResetLoaders = "?ResetLoaders@UObject@@SAXPAV1@HH@Z";
static const DWORD LOAD_NoWarn = 0x0002, LOAD_Quiet = 0x2000;

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

// Fix 3 (a feature): the Co-op menu (CoopMenu.uc) talks to the Steam relay through console
// commands, which UnrealScript sends with ConsoleCommand and which end in UGameEngine::Exec:
//   P2COOP LINK HOST <map> <port>   start P2CoopLink as host of the game this exe is about to run
//   P2COOP LINK JOIN                start P2CoopLink as joiner (it finds the friend who hosts)
//   P2COOP LINK STATUS              the relay's status line ("none" when no relay was started)
//   P2COOP LINK STOP                close the relay
//   P2COOP MENUTEST                 tests: P2COOP_MENU_TEST ("host"/"join": CoopRootWindow picks it)
// The relay runs with --no-launch (this game is the game), --game-pid (it quits with the game) and
// --status-file, which STATUS returns (see link/p2cooplink.c). It gets its own console window,
// minimized, and the environment without SteamAppId/SteamGameId (they would make it POSTAL 2
// instead of Spacewar for Steam).
static ExecFn RealExec;
static PROCESS_INFORMATION GLink;
static wchar_t GLinkDir[MAX_PATH], GStatusFile[MAX_PATH];

// Skips Word (case-insensitive, then a space or the end) at *Cmd.
static BOOL Word(const wchar_t** Cmd, const wchar_t* W)
{
    const wchar_t* C = *Cmd;
    while (*C == L' ')
        C++;
    int N = lstrlenW(W);
    if (CompareStringW(LOCALE_INVARIANT, NORM_IGNORECASE, C, N, W, N) != CSTR_EQUAL || (C[N] && C[N] != L' '))
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

static BOOL LinkRunning()
{
    return GLink.hProcess && WaitForSingleObject(GLink.hProcess, 0) == WAIT_TIMEOUT;
}

static void StopLink()
{
    if (LinkRunning())
        TerminateProcess(GLink.hProcess, 0);
    if (GLink.hProcess)
    {
        CloseHandle(GLink.hProcess);
        CloseHandle(GLink.hThread);
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
        if (CompareStringW(LOCALE_INVARIANT, NORM_IGNORECASE, P, 11, L"SteamAppId=", 11) == CSTR_EQUAL
            || CompareStringW(LOCALE_INVARIANT, NORM_IGNORECASE, P, 12, L"SteamGameId=", 12) == CSTR_EQUAL)
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
// P2COOP_LINK_DIR (tests: the relay with the mock Steam).
static void FindLinkDir()
{
    if (GetEnvironmentVariableW(L"P2COOP_LINK_DIR", GLinkDir, MAX_PATH) - 1 < MAX_PATH - 1)
    {
        wsprintfW(GStatusFile, L"%s\\menu-status.txt", GLinkDir);
        return;
    }
    GetModuleFileNameW(NULL, GLinkDir, MAX_PATH);
    for (int i = 0; i < 2; i++)
    {
        wchar_t* Slash = NULL;
        for (wchar_t* P = GLinkDir; *P; P++)
            if (*P == L'\\')
                Slash = P;
        if (Slash)
            *Slash = 0;
    }
    lstrcatW(GLinkDir, L"\\P2CoopLink");
    wsprintfW(GStatusFile, L"%s\\menu-status.txt", GLinkDir);
}

static const wchar_t* StartLink(const wchar_t* Args)
{
    wchar_t Exe[MAX_PATH], CmdLine[2048];
    StopLink();
    wsprintfW(Exe, L"%s\\P2CoopLink.exe", GLinkDir);
    if (GetFileAttributesW(Exe) == INVALID_FILE_ATTRIBUTES)
        return L"error P2CoopLink is not installed (no P2CoopLink folder next to System)";
    DeleteFileW(GStatusFile);
    wsprintfW(CmdLine, L"\"%s\" %s --no-launch --status-file \"%s\" --game-pid %lu",
              Exe, Args, GStatusFile, GetCurrentProcessId());
    STARTUPINFOW Si;
    ZeroMemory(&Si, sizeof(Si));
    Si.cb = sizeof(Si);
    Si.dwFlags = STARTF_USESHOWWINDOW;
    Si.wShowWindow = SW_SHOWMINNOACTIVE;
    wchar_t* Env = LinkEnvironment();
    BOOL Ok = CreateProcessW(Exe, CmdLine, NULL, NULL, FALSE, CREATE_NEW_CONSOLE | CREATE_UNICODE_ENVIRONMENT,
                             Env, GLinkDir, &Si, &GLink);
    HeapFree(GetProcessHeap(), 0, Env);
    if (!Ok)
    {
        ZeroMemory(&GLink, sizeof(GLink));
        return L"error could not start P2CoopLink";
    }
    return L"started";
}

static void LinkStatus(void* Ar)
{
    char Line[600] = "";
    wchar_t Wide[600];
    HANDLE F = CreateFileW(GStatusFile, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           NULL, OPEN_EXISTING, 0, NULL);
    if (F != INVALID_HANDLE_VALUE)
    {
        DWORD Got = 0;
        ReadFile(F, Line, sizeof(Line) - 1, &Got, NULL);
        Line[Got] = 0;
        CloseHandle(F);
    }
    MultiByteToWideChar(CP_UTF8, 0, Line, -1, Wide, 600);
    if (!GLink.hProcess)
        Logf(Ar, L"none");
    else if (!LinkRunning() && CompareStringW(LOCALE_INVARIANT, 0, Wide, 5, L"error", 5) != CSTR_EQUAL)
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
    if (Word(&C, L"HOST"))
    {
        wchar_t Map[128], Port[16], Args[300];
        Token(&C, Map, 128);
        Token(&C, Port, 16);
        wsprintfW(Args, L"host %s --port %s", Map[0] ? Map : L"suburbs-3", Port[0] ? Port : L"7777");
        Logf(Ar, L"%s", StartLink(Args));
    }
    else if (Word(&C, L"JOIN"))
        Logf(Ar, L"%s", StartLink(L"join"));
    else if (Word(&C, L"STATUS"))
        LinkStatus(Ar);
    else if (Word(&C, L"STOP"))
    {
        StopLink();
        Logf(Ar, L"stopped");
    }
    else
        Logf(Ar, L"usage: P2COOP LINK HOST <map> <port> | JOIN | STATUS | STOP");
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

    // Through Core's own jump thunk: SavePackage calls ResetLoaders inside Core.dll.
    RealResetLoaders = (ResetLoadersFn)HookJmpThunk(GetProcAddress(GCore, kResetLoaders), (void*)&HkResetLoaders);
    // appPreExit calls StaticExit inside Core.dll, through the same kind of thunk.
    RealStaticExit = (VoidFn)HookJmpThunk(GetProcAddress(GCore, "?StaticExit@UObject@@SAXXZ"), (void*)&HkStaticExit);
    GIsCriticalErrorPtr = (int*)GetProcAddress(GCore, "?GIsCriticalError@@3HA");
    RealExec = (ExecFn)HookJmpThunk(GetProcAddress(Engine, "?Exec@UGameEngine@@UAEHPB_WAAVFOutputDevice@@@Z"), (void*)&HkExec);
    FindLinkDir();
    RealSaveGame = (SaveGameFn)GetProcAddress(Engine, "?SaveGame@UGameEngine@@UAEHH@Z");
    void** Vtable = (void**)GetProcAddress(Engine, "??_7UGameEngine@@6BUObject@@@");
    if (!GetPackageLinker || !BeginLoad || !EndLoad || !RealResetLoaders || !RealStaticExit || !RealExec || !RealSaveGame || !Vtable)
        return FALSE;
    return HookVtableSlot(Vtable, (void*)RealSaveGame, (void*)&HkSaveGame);
}

BOOL WINAPI DllMain(HINSTANCE, DWORD Reason, LPVOID)
{
    if (Reason != DLL_PROCESS_ATTACH)
        return TRUE;
    BgInstall();    // tests only (P2COOP_BACKGROUND=1), see bgwindows.h
    if (!Install())
    {
        MessageBoxW(NULL, L"P2CoopHk: could not install the engine hooks for this game build.",
                    L"P2Coop", MB_ICONERROR);
        return FALSE;
    }
    return TRUE;
}
