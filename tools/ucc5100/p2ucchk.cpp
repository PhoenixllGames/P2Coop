// P2UccHk.dll: turns a copy of the POSTAL 2 5100 Postal2.exe into a UCC (commandlet runner).
//
// The copy (P2Ucc.exe) imports this DLL instead of COMDLG32.dll (patchexe.py). At load time we
// redirect the exe's import of Core's appInit to AppInitHook. The exe calls appInit with its own
// 5100-built malloc, log, config cache and file manager, so the engine starts exactly as in the
// game. Right after the real appInit we run the commandlet named on the command line and exit,
// before the exe creates a window or an engine.
//
// Usage: P2Ucc.exe <commandlet> [params]   e.g.  P2Ucc.exe make ini=P2Coop.ini
//        P2Ucc.exe batchexport Engine.u class uc ..\Export\Engine
// Engine output goes to P2Ucc.log next to the exe; stdout only gets this launcher's own errors.
// Exit code: the commandlet's result, 1 on an engine error (e.g. "Failed due to errors").

#include <windows.h>
#include "iathook.h"

// ---- Core.dll exports used here (5100 mangled names, TCHAR = wchar_t) ----

typedef void (__cdecl *AppInitFn)(const wchar_t*, const wchar_t*, void*, void*, void*, void*, void*, void* (__cdecl*)(), int);
typedef void* (__cdecl *StaticLoadClassFn)(void* Base, void* Outer, const wchar_t* Name, const wchar_t* File, DWORD Flags, void* Sandbox);
typedef void* (__cdecl *StaticConstructObjectFn)(void* Class, void* Outer, int Name, DWORD Flags, void* Template, void* Error, int Unknown);
typedef void* (__cdecl *GetTransientPackageFn)();
typedef void (__thiscall *InitExecutionFn)(void* This);
typedef void (__thiscall *ParseParmsFn)(void* This, const wchar_t* Parms);
typedef int (__thiscall *MainFn)(void* This, const wchar_t* Parms);
typedef void (__cdecl *VoidFn)();

static const char* const kAppInit = "?appInit@@YAXPB_W0PAVFMalloc@@PAVFOutputDevice@@PAVFOutputDeviceError@@PAVFFeedbackContext@@PAVFFileManager@@P6APAVFConfigCache@@XZH@Z";

static HMODULE GCore;
static AppInitFn RealAppInit;

static FARPROC Core(const char* Name)
{
    FARPROC P = GetProcAddress(GCore, Name);
    if (!P)
    {
        char Msg[512];
        wsprintfA(Msg, "P2UccHk: Core.dll has no export %s\n", Name);
        DWORD W;
        WriteFile(GetStdHandle(STD_ERROR_HANDLE), Msg, lstrlenA(Msg), &W, NULL);
        ExitProcess(3);
    }
    return P;
}

static int* CoreInt(const char* Name) { return (int*)Core(Name); }

static void Print(const wchar_t* Text)
{
    char Buf[2048];
    int N = WideCharToMultiByte(CP_UTF8, 0, Text, -1, Buf, sizeof(Buf) - 1, NULL, NULL);
    if (N > 0)
    {
        DWORD W;
        WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), Buf, N - 1, &W, NULL);
    }
}

// Skips the exe path and returns the rest of the process command line.
static const wchar_t* ArgsAfterExe()
{
    const wchar_t* P = GetCommandLineW();
    if (*P == L'"')
    {
        for (P++; *P && *P != L'"'; P++) {}
        if (*P) P++;
    }
    else
    {
        while (*P && *P != L' ' && *P != L'\t') P++;
    }
    while (*P == L' ' || *P == L'\t') P++;
    return P;
}

// Finds the vtable slot of a virtual function by matching its exported address.
static int VtableIndex(void** Vtable, void* Fn)
{
    for (int i = 0; i < 512; i++)
        if (Vtable[i] == Fn)
            return i;
    return -1;
}

static int RunCommandlet()
{
    const wchar_t* Args = ArgsAfterExe();
    wchar_t Token[256];
    int n = 0;
    while (Args[n] && Args[n] != L' ' && n < 255) { Token[n] = Args[n]; n++; }
    Token[n] = 0;
    const wchar_t* Parms = Args + n;
    while (*Parms == L' ') Parms++;

    if (!Token[0])
    {
        Print(L"usage: P2Ucc.exe <commandlet> [params]\n");
        return 2;
    }

    // Same globals UCC sets before loading a commandlet.
    *CoreInt("?GIsUCC@@3HA") = 1;
    *CoreInt("?GIsClient@@3HA") = 1;
    *CoreInt("?GIsServer@@3HA") = 1;
    *CoreInt("?GIsEditor@@3HA") = 1;
    *CoreInt("?GIsScriptable@@3HA") = 1;
    *CoreInt("?GLazyLoad@@3HA") = 0;

    StaticLoadClassFn LoadClass = (StaticLoadClassFn)Core("?StaticLoadClass@UObject@@SAPAVUClass@@PAV2@PAV1@PB_W2KPAVUPackageMap@@@Z");
    void* CommandletClass = Core("?PrivateStaticClass@UCommandlet@@0VUClass@@A");
    const DWORD LOAD_NoWarn = 0x2000, LOAD_Quiet = 0x4000;

    // "make" -> Editor.MakeCommandlet, like UCC's lookup through the .int registry.
    wchar_t Name[300];
    void* Class = NULL;
    if (!wcschr(Token, L'.'))
    {
        wsprintfW(Name, L"Editor.%sCommandlet", Token);
        Class = LoadClass(CommandletClass, NULL, Name, NULL, LOAD_NoWarn | LOAD_Quiet, NULL);
    }
    if (!Class)
        Class = LoadClass(CommandletClass, NULL, Token, NULL, LOAD_NoWarn | LOAD_Quiet, NULL);
    if (!Class)
    {
        wsprintfW(Name, L"%sCommandlet", Token);
        Class = LoadClass(CommandletClass, NULL, Name, NULL, LOAD_NoWarn | LOAD_Quiet, NULL);
    }
    if (!Class)
    {
        wsprintfW(Name, L"P2Ucc: commandlet '%s' not found\n", Token);
        Print(Name);
        return 2;
    }

    void* Outer = ((GetTransientPackageFn)Core("?GetTransientPackage@UObject@@SAPAVUPackage@@XZ"))();
    void* Error = *(void**)Core("?GError@@3PAVFOutputDeviceError@@A");
    StaticConstructObjectFn Construct = (StaticConstructObjectFn)Core("?StaticConstructObject@UObject@@SAPAV1@PAVUClass@@PAV1@VFName@@K1PAVFOutputDevice@@H@Z");
    void* Commandlet = Construct(Class, Outer, 0 /*NAME_None*/, 0, NULL, Error, 0);

    ((InitExecutionFn)Core("?InitExecution@UObject@@UAEXXZ"))(Commandlet);
    ((ParseParmsFn)Core("?ParseParms@UObject@@QAEXPB_W@Z"))(Commandlet, Parms);

    void** BaseVtable = (void**)Core("??_7UCommandlet@@6B@");
    int Slot = VtableIndex(BaseVtable, (void*)Core("?Main@UCommandlet@@UAEHPB_W@Z"));
    if (Slot < 0)
    {
        Print(L"P2Ucc: UCommandlet::Main not found in its vtable\n");
        return 3;
    }
    MainFn Main = (MainFn)(*(void***)Commandlet)[Slot];
    return Main(Commandlet, Parms);
}

static void __cdecl AppInitHook(const wchar_t* Package, const wchar_t* CmdLine, void* Malloc, void* Log, void* Error,
                                void* Warn, void* FileManager, void* (__cdecl* ConfigFactory)(), int RequireConfig)
{
    RealAppInit(Package, CmdLine, Malloc, Log, Error, Warn, FileManager, ConfigFactory, RequireConfig);
    int Result = RunCommandlet();
    ((VoidFn)Core("?appPreExit@@YAXXZ"))();
    ((VoidFn)Core("?appExit@@YAXXZ"))();
    ExitProcess((UINT)Result);
}

BOOL WINAPI DllMain(HINSTANCE, DWORD Reason, LPVOID)
{
    if (Reason == DLL_PROCESS_ATTACH)
    {
        GCore = GetModuleHandleW(L"Core.dll");
        RealAppInit = GCore ? (AppInitFn)GetProcAddress(GCore, kAppInit) : NULL;
        if (!RealAppInit || !HookExeImport("Core.dll", kAppInit, (void*)&AppInitHook))
            return FALSE;
    }
    return TRUE;
}
