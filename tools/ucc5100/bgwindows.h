// Window placement for test copies of the game (P2CoopHk, System\dinput8.dll). Players never set
// these variables.
//  P2COOP_WINDOW_POS=x,y  the game's top-level windows go to x,y (a slot on a secondary monitor,
//                         chosen by tools/run_local.ps1); focus and activation stay stock.
//  P2COOP_BACKGROUND=1    also never take the foreground or the focus, show windows without
//                         activation and keep them at the bottom of the z-order. Not used by the
//                         tests any more: with activation refused, map changes went wrong.
//
// Implemented by patching the user32 imports of every module loaded from the game's System
// folder: Postal2.exe, Window.dll, Core.dll, Engine.dll and WinDrv.dll when WinDrv.dll loads this
// DLL (again in DirectInput8Create, before WinDrv opens the game window), the rest (D3DDrv.dll...)
// when the engine loads them, through the LoadLibrary imports of Core.dll and Window.dll. The
// splash screen comes before, and was never placed (see BgCbt).
#pragma once
#include <windows.h>
#include <limits.h>
#include "iathook.h"

static int GBgX = INT_MIN, GBgY = INT_MIN;
static BOOL GBgFocus;       // P2COOP_BACKGROUND=1
static wchar_t GBgSystemDir[MAX_PATH];

static BOOL BgTopLevel(HWND h)
{
    return h && !(GetWindowLongW(h, GWL_STYLE) & WS_CHILD);
}

static BOOL WINAPI BgSetForegroundWindow(HWND h) { return GBgFocus ? TRUE : SetForegroundWindow(h); }
static HWND WINAPI BgSetActiveWindow(HWND h) { return GBgFocus ? GetActiveWindow() : SetActiveWindow(h); }
static BOOL WINAPI BgBringWindowToTop(HWND h) { return GBgFocus ? TRUE : BringWindowToTop(h); }
static HWND WINAPI BgSetFocus(HWND h) { return GBgFocus ? GetFocus() : SetFocus(h); }

static int BgShowCmd(int Cmd)
{
    switch (Cmd)
    {
    case SW_SHOW: return SW_SHOWNA;
    case SW_SHOWNORMAL: case SW_RESTORE: case SW_SHOWDEFAULT: case SW_SHOWMAXIMIZED: return SW_SHOWNOACTIVATE;
    case SW_SHOWMINIMIZED: return SW_SHOWMINNOACTIVE;
    default: return Cmd;
    }
}

static BOOL WINAPI BgShowWindow(HWND h, int Cmd)
{
    return ShowWindow(h, GBgFocus && BgTopLevel(h) ? BgShowCmd(Cmd) : Cmd);
}

static BOOL WINAPI BgSetWindowPos(HWND h, HWND After, int X, int Y, int Cx, int Cy, UINT Flags)
{
    if (BgTopLevel(h))
    {
        if (GBgFocus)
        {
            Flags |= SWP_NOACTIVATE;
            if (!(Flags & SWP_NOZORDER))
                After = HWND_BOTTOM;
        }
        if (!(Flags & SWP_NOMOVE) && GBgX != INT_MIN)
        {
            X = GBgX;
            Y = GBgY;
        }
    }
    return SetWindowPos(h, After, X, Y, Cx, Cy, Flags);
}

static BOOL WINAPI BgMoveWindow(HWND h, int X, int Y, int W, int H, BOOL Repaint)
{
    if (BgTopLevel(h) && GBgX != INT_MIN)
    {
        X = GBgX;
        Y = GBgY;
    }
    if (!GBgFocus || !BgTopLevel(h))
        return MoveWindow(h, X, Y, W, H, Repaint);
    return SetWindowPos(h, HWND_BOTTOM, X, Y, W, H, SWP_NOACTIVATE | (Repaint ? 0 : SWP_NOREDRAW));
}

// In background mode a window created with WS_VISIBLE (shown and activated inside
// CreateWindowEx) is created hidden and shown without activation.
static HWND WINAPI BgCreateWindowExW(DWORD Ex, LPCWSTR Class, LPCWSTR Name, DWORD Style, int X, int Y,
                                     int W, int H, HWND Parent, HMENU Menu, HINSTANCE Inst, LPVOID Param)
{
    BOOL Top = !(Style & WS_CHILD), Visible = (Style & WS_VISIBLE) != 0;
    if (Top && GBgX != INT_MIN) { X = GBgX; Y = GBgY; }
    if (Top && GBgFocus)
        Style &= ~WS_VISIBLE;
    HWND h = CreateWindowExW(Ex, Class, Name, Style, X, Y, W, H, Parent, Menu, Inst, Param);
    if (h && Top && GBgFocus && Visible)
        ShowWindow(h, SW_SHOWNOACTIVATE);
    return h;
}

static HWND WINAPI BgCreateWindowExA(DWORD Ex, LPCSTR Class, LPCSTR Name, DWORD Style, int X, int Y,
                                     int W, int H, HWND Parent, HMENU Menu, HINSTANCE Inst, LPVOID Param)
{
    BOOL Top = !(Style & WS_CHILD), Visible = (Style & WS_VISIBLE) != 0;
    if (Top && GBgX != INT_MIN) { X = GBgX; Y = GBgY; }
    if (Top && GBgFocus)
        Style &= ~WS_VISIBLE;
    HWND h = CreateWindowExA(Ex, Class, Name, Style, X, Y, W, H, Parent, Menu, Inst, Param);
    if (h && Top && GBgFocus && Visible)
        ShowWindow(h, SW_SHOWNOACTIVATE);
    return h;
}

static void BgPatchModule(HMODULE M);

static HMODULE WINAPI BgLoadLibraryW(LPCWSTR Name)
{
    HMODULE M = LoadLibraryW(Name);
    BgPatchModule(M);
    return M;
}

static HMODULE WINAPI BgLoadLibraryA(LPCSTR Name)
{
    HMODULE M = LoadLibraryA(Name);
    BgPatchModule(M);
    return M;
}

static HMODULE WINAPI BgLoadLibraryExW(LPCWSTR Name, HANDLE File, DWORD Flags)
{
    HMODULE M = LoadLibraryExW(Name, File, Flags);
    BgPatchModule(M);
    return M;
}

// Patches only the game's own modules (System folder), never Windows or driver DLLs.
static void BgPatchModule(HMODULE M)
{
    wchar_t Path[MAX_PATH];
    if (!M || !GetModuleFileNameW(M, Path, MAX_PATH))
        return;
    wchar_t* Slash = wcsrchr(Path, L'\\');
    if (!Slash)
        return;
    *Slash = 0;
    if (lstrcmpiW(Path, GBgSystemDir) != 0)
        return;

    static const struct { const char* Name; void* Hook; } User32[] = {
        { "SetForegroundWindow", (void*)&BgSetForegroundWindow },
        { "SetActiveWindow", (void*)&BgSetActiveWindow },
        { "BringWindowToTop", (void*)&BgBringWindowToTop },
        { "SetFocus", (void*)&BgSetFocus },
        { "ShowWindow", (void*)&BgShowWindow },
        { "SetWindowPos", (void*)&BgSetWindowPos },
        { "MoveWindow", (void*)&BgMoveWindow },
        { "CreateWindowExW", (void*)&BgCreateWindowExW },
        { "CreateWindowExA", (void*)&BgCreateWindowExA },
    };
    for (int i = 0; i < (int)(sizeof(User32) / sizeof(User32[0])); i++)
        HookModuleImport(M, "USER32.dll", User32[i].Name, User32[i].Hook);
    HookModuleImport(M, "KERNEL32.dll", "LoadLibraryW", (void*)&BgLoadLibraryW);
    HookModuleImport(M, "KERNEL32.dll", "LoadLibraryA", (void*)&BgLoadLibraryA);
    HookModuleImport(M, "KERNEL32.dll", "LoadLibraryExW", (void*)&BgLoadLibraryExW);
}

// Dialogs (splash, loading box #32770) are shown, and activated, inside CreateDialogParam where
// no import hook reaches. In background mode a CBT hook on the main thread refuses activation.
static LRESULT CALLBACK BgCbt(int Code, WPARAM W, LPARAM L)
{
    if (Code == HCBT_ACTIVATE)
        return 1;
    return CallNextHookEx(NULL, Code, W, L);
}

// Returns TRUE if window placement or background mode is on.
static BOOL BgInstall()
{
    char Buf[64];
    GBgFocus = GetEnvironmentVariableA("P2COOP_BACKGROUND", Buf, sizeof(Buf)) && Buf[0] == '1';
    if (GetEnvironmentVariableA("P2COOP_WINDOW_POS", Buf, sizeof(Buf)))
    {
        char* Comma = strchr(Buf, ',');
        if (Comma)
        {
            GBgX = atoi(Buf);
            GBgY = atoi(Comma + 1);
        }
    }
    if (!GBgFocus && GBgX == INT_MIN)
        return FALSE;
    GetModuleFileNameW(NULL, GBgSystemDir, MAX_PATH);
    wchar_t* Slash = wcsrchr(GBgSystemDir, L'\\');
    if (Slash)
        *Slash = 0;

    HMODULE Loaded[] = { GetModuleHandleW(NULL), GetModuleHandleW(L"Window.dll"), GetModuleHandleW(L"Core.dll"),
                         GetModuleHandleW(L"Engine.dll"), GetModuleHandleW(L"WinDrv.dll") };
    for (int i = 0; i < (int)(sizeof(Loaded) / sizeof(Loaded[0])); i++)
        BgPatchModule(Loaded[i]);
    // DllMain runs on the main thread, which creates the game's windows.
    if (GBgFocus)
        SetWindowsHookExW(WH_CBT, BgCbt, NULL, GetCurrentThreadId());
    return TRUE;
}
