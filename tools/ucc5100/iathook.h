// Helpers for hook DLLs loaded by a patched copy of Postal2.exe: redirect imports and virtuals.
#pragma once
#include <windows.h>

// Points Module's import slot for Dll!Name at Hook. Returns the original function, or NULL.
static void* HookModuleImport(HMODULE Module, const char* Dll, const char* Name, void* Hook)
{
    BYTE* Base = (BYTE*)Module;
    IMAGE_NT_HEADERS* Nt = (IMAGE_NT_HEADERS*)(Base + ((IMAGE_DOS_HEADER*)Base)->e_lfanew);
    IMAGE_DATA_DIRECTORY Dir = Nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    for (IMAGE_IMPORT_DESCRIPTOR* D = (IMAGE_IMPORT_DESCRIPTOR*)(Base + Dir.VirtualAddress); D->Name; D++)
    {
        if (lstrcmpiA((char*)(Base + D->Name), Dll) != 0)
            continue;
        IMAGE_THUNK_DATA* Names = (IMAGE_THUNK_DATA*)(Base + D->OriginalFirstThunk);
        IMAGE_THUNK_DATA* Slots = (IMAGE_THUNK_DATA*)(Base + D->FirstThunk);
        for (; Names->u1.AddressOfData; Names++, Slots++)
        {
            if (IMAGE_SNAP_BY_ORDINAL(Names->u1.Ordinal))
                continue;
            IMAGE_IMPORT_BY_NAME* N = (IMAGE_IMPORT_BY_NAME*)(Base + Names->u1.AddressOfData);
            if (lstrcmpA((char*)N->Name, Name) != 0)
                continue;
            void* Old = (void*)Slots->u1.Function;
            DWORD Prot;
            VirtualProtect(&Slots->u1.Function, sizeof(void*), PAGE_READWRITE, &Prot);
            Slots->u1.Function = (DWORD_PTR)Hook;
            VirtualProtect(&Slots->u1.Function, sizeof(void*), Prot, &Prot);
            return Old;
        }
    }
    return NULL;
}

// Points the main exe's import slot for Dll!Name at Hook. Returns the original function, or NULL.
static void* HookExeImport(const char* Dll, const char* Name, void* Hook)
{
    return HookModuleImport(GetModuleHandleW(NULL), Dll, Name, Hook);
}

// Replaces the vtable slot that holds Fn with Hook. Returns FALSE if Fn is not in the first 512 slots.
static BOOL HookVtableSlot(void** Vtable, void* Fn, void* Hook)
{
    for (int i = 0; i < 512; i++)
    {
        if (Vtable[i] != Fn)
            continue;
        DWORD Prot;
        VirtualProtect(&Vtable[i], sizeof(void*), PAGE_READWRITE, &Prot);
        Vtable[i] = Hook;
        VirtualProtect(&Vtable[i], sizeof(void*), Prot, &Prot);
        return TRUE;
    }
    return FALSE;
}

// The 5100 DLLs are incrementally linked: an export is a "jmp rel32" thunk, and calls inside the
// DLL go through the same thunk. Retargets that jump to Hook, so every caller is redirected.
// Returns the original target (callable as the real function), or NULL if Fn is not such a thunk.
static void* HookJmpThunk(void* Fn, void* Hook)
{
    BYTE* P = (BYTE*)Fn;
    if (!P || P[0] != 0xE9)
        return NULL;
    void* Original = P + 5 + *(LONG*)(P + 1);
    DWORD Prot;
    VirtualProtect(P + 1, 4, PAGE_EXECUTE_READWRITE, &Prot);
    *(LONG*)(P + 1) = (LONG)((BYTE*)Hook - (P + 5));
    VirtualProtect(P + 1, 4, Prot, &Prot);
    FlushInstructionCache(GetCurrentProcess(), P, 5);
    return Original;
}

// Stand-in for Postal2.exe's only COMDLG32 import, for DLLs that take COMDLG32's place.
extern "C" BOOL WINAPI HkGetSaveFileNameA(void* Ofn)
{
    typedef BOOL (WINAPI *Fn)(void*);
    Fn Real = (Fn)GetProcAddress(LoadLibraryW(L"comdlg32.dll"), "GetSaveFileNameA");
    return Real ? Real(Ofn) : FALSE;
}
