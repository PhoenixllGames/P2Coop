/*
 * P2CoopLink: Steam ("Spacewar", AppID 480) relay for POSTAL 2 co-op (P2Coop).
 *
 * Ported from HXCoop (steamlink/hxcoop.c in https://github.com/cranebeaker/deus-ex-coop,
 * MIT License, Copyright (c) 2026 cranebeaker and contributors). Changes for POSTAL 2 are
 * marked "P2Coop:".
 *
 * Players never deal with IP addresses or port forwarding:
 *  - host:  creates a friends-only Steam lobby, starts System\Postal2.exe as a listen server
 *           bound to 127.0.0.1 and relays every friend's packets between Steam and the game port;
 *  - join:  takes a lobby id (or an invite, or a friend who is hosting), checks versions with the
 *           host, binds a local UDP port and starts System\Postal2.exe connected to it;
 *  - list:  (P2Coop) reports the friends who host to the game's Co-op menu, which then starts
 *           "join <lobby id>"; an accepted Steam invite joins right away.
 * UE2 does its own reliability, so game packets go as unreliable Steam messages on channel 0.
 * Channel 1 carries control messages: K keep-alive (1 s), B goodbye,
 * V<version> version check from a joiner, A accepted / X<reason> refused from the host.
 * P2Coop: the host takes Steam sessions and peers only from members of its lobby, drops a peer
 * that has not passed the version check within 5 s, and remembers who passed it, so a peer that
 * comes back after a Steam hiccup is relayed again. A joiner leaves the lobby when the host says
 * goodbye or leaves it.
 * Game packets carry a 1 byte connection id in both directions. On a map change the game
 * opens a new connection from a new local port while the old one still sends for a moment;
 * each client side source address gets its own id, and the host side gives each id its own
 * socket (so its own source port), or the server takes the new handshake for the old one.
 *
 * steam_api.dll is loaded at runtime through the flat C API (no SDK headers). The relay lives
 * in its own folder with its own steam_api.dll and steam_appid.txt = 480; the game keeps its
 * own Steam app id, because the child process does not inherit SteamAppId/SteamGameId.
 *
 *   P2CoopLink.exe                    menu
 *   P2CoopLink.exe host [map]         host, default map suburbs-3 (Monday)
 *   P2CoopLink.exe join [lobby id]    join (no id: a friend who is hosting)
 *   P2CoopLink.exe list               the friends who host, for the Co-op menu (see below)
 * Options: --game <POSTAL 2 folder>  --port <game port, 7777>  --url-extra <?opts for the host URL>
 *          --game-args <extra game arguments>  --no-launch (relay only)
 *          --version-suffix <text> (tests: pretend to be another version)
 *          --client-exe <exe in System> (the joiner's game exe, default Postal2.exe)
 *          --status-file <path>  --game-pid <pid>  (started by the game's Co-op menu, see below)
 *          --log <path> (the output goes there)
 *          --stop-event <name> (P2Coop: the game's menu sets this event to close the relay the
 *          way it closes when the game quits: goodbye, out of the lobby, off Steam)
 *
 * P2Coop: the game's Co-op menu starts the relay itself (P2CoopHk, "P2COOP LINK ..."), without
 * a console window: with --no-launch for the game that is already running, --game-pid to quit
 * with that game, --log, and --status-file for the menu to read: "hosting <lobby>", "searching",
 * "hosts" followed by "\t<lobby id>\t<host name>" for each friend's game (list), "joining",
 * "ready 127.0.0.1:<port>" (join: the game connects there) or "error <message>". With
 * --status-file or --game-pid it never waits for a key, and an error leaves the lobby and Steam.
 */
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <bcrypt.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <conio.h>
#include <io.h>

#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "bcrypt.lib")

typedef uint64_t u64;

/* P2Coop: protocol version of this relay; a joiner must match the host. */
#define LINK_PROTOCOL "1"

/* ---------------------------------------------------------------- steam flat api */

typedef struct { int32_t user; int32_t callback; uint8_t *param; int32_t param_size; } CallbackMsg;
#pragma pack(push, 8)
typedef struct { u64 call; int32_t callback; uint32_t param_size; } APICallCompleted;
typedef struct { int32_t result; u64 lobby; } LobbyCreated;
typedef struct { u64 lobby; uint32_t perms; bool locked; uint32_t response; } LobbyEnter;
typedef struct { u64 lobby, user_changed, making_change; uint32_t state; } LobbyChatUpdate;
typedef struct { u64 lobby, friend_id; } GameLobbyJoinRequested;
typedef struct { u64 friend_id; char connect[256]; } GameRichPresenceJoinRequested;
typedef struct { u64 game_id; uint32_t ip; uint16_t port, query_port; u64 lobby; } FriendGameInfo;
#pragma pack(pop)

#define CB_LOBBY_JOIN_REQUESTED 333
#define CB_RICH_PRESENCE_JOIN   337
#define CB_LOBBY_ENTER          504
#define CB_LOBBY_CHAT_UPDATE    506
#define CB_LOBBY_CREATED        513
#define CB_CALL_COMPLETED       703
#define CB_SESSION_REQUEST      1251
#define CB_SESSION_FAILED       1252

#define SEND_UNRELIABLE_NO_NAGLE 1
#define SEND_RELIABLE            8
#define IDENT_SIZE               160 /* real size 136, kept opaque */

static struct {
    bool (__cdecl *IsSteamRunning)(void);
    int (__cdecl *InitFlat)(char *err);
    void (__cdecl *Shutdown)(void);
    int32_t (__cdecl *GetHSteamPipe)(void);
    void (__cdecl *DispatchInit)(void);
    void (__cdecl *RunFrame)(int32_t);
    bool (__cdecl *GetNextCallback)(int32_t, CallbackMsg *);
    void (__cdecl *FreeLastCallback)(int32_t);
    bool (__cdecl *GetAPICallResult)(int32_t, u64, void *, int, int, bool *);
    void *(__cdecl *User)(void);
    void *(__cdecl *Matchmaking)(void);
    void *(__cdecl *Friends)(void);
    void *(__cdecl *Messages)(void);
    void *(__cdecl *Utils)(void);
    u64 (__cdecl *GetSteamID)(void *);
    u64 (__cdecl *CreateLobby)(void *, int, int);
    u64 (__cdecl *JoinLobby)(void *, u64);
    void (__cdecl *LeaveLobby)(void *, u64);
    bool (__cdecl *SetLobbyData)(void *, u64, const char *, const char *);
    const char *(__cdecl *GetLobbyData)(void *, u64, const char *);
    bool (__cdecl *RequestLobbyData)(void *, u64);
    u64 (__cdecl *GetLobbyOwner)(void *, u64);
    int (__cdecl *GetNumLobbyMembers)(void *, u64);
    u64 (__cdecl *GetLobbyMemberByIndex)(void *, u64, int);
    bool (__cdecl *SetRichPresence)(void *, const char *, const char *);
    int (__cdecl *GetFriendCount)(void *, int);
    u64 (__cdecl *GetFriendByIndex)(void *, int, int);
    bool (__cdecl *GetFriendGamePlayed)(void *, u64, FriendGameInfo *);
    const char *(__cdecl *GetFriendPersonaName)(void *, u64);
    const char *(__cdecl *GetPersonaName)(void *);
    void (__cdecl *IdentSet)(void *, u64);
    u64 (__cdecl *IdentGet)(const void *);
    int (__cdecl *SendMessageToUser)(void *, const void *, const void *, uint32_t, int, int);
    int (__cdecl *ReceiveMessages)(void *, int, void **, int);
    bool (__cdecl *AcceptSession)(void *, const void *);
    bool (__cdecl *CloseSession)(void *, const void *);
    void (__cdecl *MessageRelease)(void *);
    bool (__cdecl *SetConfigInt)(void *, int, int32_t);
    void (__cdecl *InitRelay)(void *);
} S;

static void *g_user, *g_mm, *g_friends, *g_msgs, *g_utils;
static int32_t g_pipe;
static u64 g_me;
static bool g_console; /* P2Coop: a player at a console (not a test harness, not the game's menu) */
static bool g_steam_up; /* P2Coop: steam_start finished */

static void status(const char *fmt, ...);
static void steam_leave(void);
static void quit_stopped(void);

static void fail(const char *msg)
{
    status("error %s", msg);
    printf("\nP2CoopLink: ERROR: %s\n", msg);
    /* P2Coop: out of the lobby and off Steam before waiting or exiting (friends would still see
       the lobby, and Steam would show the player in Spacewar). */
    if (g_steam_up) steam_leave();
    if (g_console) { printf("\nPress a key to close.\n"); _getch(); }
    exit(1);
}

static FARPROC need(HMODULE m, const char *name)
{
    FARPROC p = GetProcAddress(m, name);
    if (!p) {
        char buf[300];
        snprintf(buf, sizeof(buf), "steam_api.dll is missing %s (too old?).", name);
        fail(buf);
    }
    return p;
}

#define LOAD(field, name) *(FARPROC *)&S.field = need(m, name)
#define LOAD_OPT(field, name) *(FARPROC *)&S.field = GetProcAddress(m, name)

static void steam_start(void)
{
    FILE *f = fopen("steam_appid.txt", "r");
    if (f) fclose(f);
    else if ((f = fopen("steam_appid.txt", "w"))) { fputs("480", f); fclose(f); }

    HMODULE m = LoadLibraryA("steam_api.dll");
    if (!m) fail("steam_api.dll not found next to P2CoopLink.exe.");
    LOAD(IsSteamRunning, "SteamAPI_IsSteamRunning");
    LOAD(InitFlat, "SteamAPI_InitFlat");
    LOAD(Shutdown, "SteamAPI_Shutdown");
    LOAD(GetHSteamPipe, "SteamAPI_GetHSteamPipe");
    LOAD(DispatchInit, "SteamAPI_ManualDispatch_Init");
    LOAD(RunFrame, "SteamAPI_ManualDispatch_RunFrame");
    LOAD(GetNextCallback, "SteamAPI_ManualDispatch_GetNextCallback");
    LOAD(FreeLastCallback, "SteamAPI_ManualDispatch_FreeLastCallback");
    LOAD(GetAPICallResult, "SteamAPI_ManualDispatch_GetAPICallResult");
    LOAD(User, "SteamAPI_SteamUser_v023");
    LOAD(Matchmaking, "SteamAPI_SteamMatchmaking_v009");
    LOAD(Friends, "SteamAPI_SteamFriends_v018");
    LOAD(Messages, "SteamAPI_SteamNetworkingMessages_SteamAPI_v002");
    LOAD(Utils, "SteamAPI_SteamNetworkingUtils_SteamAPI_v004");
    LOAD(GetSteamID, "SteamAPI_ISteamUser_GetSteamID");
    LOAD(CreateLobby, "SteamAPI_ISteamMatchmaking_CreateLobby");
    LOAD(JoinLobby, "SteamAPI_ISteamMatchmaking_JoinLobby");
    LOAD(LeaveLobby, "SteamAPI_ISteamMatchmaking_LeaveLobby");
    LOAD(SetLobbyData, "SteamAPI_ISteamMatchmaking_SetLobbyData");
    LOAD(GetLobbyData, "SteamAPI_ISteamMatchmaking_GetLobbyData");
    LOAD_OPT(RequestLobbyData, "SteamAPI_ISteamMatchmaking_RequestLobbyData");
    LOAD(GetLobbyOwner, "SteamAPI_ISteamMatchmaking_GetLobbyOwner");
    LOAD(GetNumLobbyMembers, "SteamAPI_ISteamMatchmaking_GetNumLobbyMembers");
    LOAD(GetLobbyMemberByIndex, "SteamAPI_ISteamMatchmaking_GetLobbyMemberByIndex");
    LOAD(SetRichPresence, "SteamAPI_ISteamFriends_SetRichPresence");
    LOAD(GetFriendCount, "SteamAPI_ISteamFriends_GetFriendCount");
    LOAD(GetFriendByIndex, "SteamAPI_ISteamFriends_GetFriendByIndex");
    LOAD(GetFriendGamePlayed, "SteamAPI_ISteamFriends_GetFriendGamePlayed");
    LOAD(GetFriendPersonaName, "SteamAPI_ISteamFriends_GetFriendPersonaName");
    LOAD(GetPersonaName, "SteamAPI_ISteamFriends_GetPersonaName");
    LOAD(IdentSet, "SteamAPI_SteamNetworkingIdentity_SetSteamID64");
    LOAD(IdentGet, "SteamAPI_SteamNetworkingIdentity_GetSteamID64");
    LOAD(SendMessageToUser, "SteamAPI_ISteamNetworkingMessages_SendMessageToUser");
    LOAD(ReceiveMessages, "SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel");
    LOAD(AcceptSession, "SteamAPI_ISteamNetworkingMessages_AcceptSessionWithUser");
    LOAD(CloseSession, "SteamAPI_ISteamNetworkingMessages_CloseSessionWithUser");
    LOAD(MessageRelease, "SteamAPI_SteamNetworkingMessage_t_Release");
    LOAD(SetConfigInt, "SteamAPI_ISteamNetworkingUtils_SetGlobalConfigValueInt32");
    LOAD_OPT(InitRelay, "SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess");

    if (!S.IsSteamRunning()) fail("Steam is not running. Start Steam, log in, and try again.");
    char err[1024] = "";
    int r = S.InitFlat(err);
    if (r != 0) {
        char buf[1200];
        snprintf(buf, sizeof(buf), "Could not connect to Steam (code %d): %s", r, err);
        fail(buf);
    }
    S.DispatchInit();
    g_pipe = S.GetHSteamPipe();
    g_user = S.User(); g_mm = S.Matchmaking(); g_friends = S.Friends();
    g_msgs = S.Messages(); g_utils = S.Utils();
    g_me = S.GetSteamID(g_user);
    if (S.InitRelay) S.InitRelay(g_utils);
    g_steam_up = true;
}

static void ident(void *buf, u64 sid) { memset(buf, 0, IDENT_SIZE); S.IdentSet(buf, sid); }

/* P2Coop: sender identity of a received SteamNetworkingMessage_t. The real 32 bit steam_api.dll
   keeps it at offset 12 (seen with two accounts, coop-anything networking-steam-spacewar.md),
   older notes said 16; try 12 first and report once which one worked. */
static u64 msg_sender(void *msg)
{
    static int reported;
    u64 sid = S.IdentGet((char *)msg + 12);
    int at = 12;
    if (!sid) { sid = S.IdentGet((char *)msg + 16); at = 16; }
    if (sid && !reported) { reported = 1; printf("P2CoopLink: message sender identity at offset %d\n", at); }
    return sid;
}

static int send_to(u64 sid, const void *data, int size, int flags, int channel)
{
    unsigned char id[IDENT_SIZE];
    ident(id, sid);
    return S.SendMessageToUser(g_msgs, id, data, (uint32_t)size, flags, channel);
}

static void send_ctl(u64 sid, const char *text) { send_to(sid, text, (int)strlen(text), SEND_RELIABLE, 1); }

static void accept_session(u64 sid)
{
    unsigned char id[IDENT_SIZE];
    ident(id, sid);
    S.AcceptSession(g_msgs, id);
}

static void close_session(u64 sid)
{
    unsigned char id[IDENT_SIZE];
    ident(id, sid);
    S.CloseSession(g_msgs, id);
}

static const char *friend_name(u64 sid)
{
    const char *n = S.GetFriendPersonaName(g_friends, sid);
    return n && *n ? n : "?";
}

/* ---------------------------------------------------------------- options, game launch */

static char g_game_dir[MAX_PATH];   /* POSTAL 2 folder (the one with System\) */
static int g_port = 7777;
static char g_url_extra[512];
static char g_game_args[1024];
static bool g_no_launch;
static HANDLE g_game;
static char g_version[640];         /* P2Coop: what joiner and host must agree on */
static char g_version_suffix[64];   /* P2Coop: --version-suffix, tests the mismatch path */
static char g_client_exe[64] = "Postal2.exe"; /* P2Coop: --client-exe */
static char g_status_file[MAX_PATH]; /* P2Coop: --status-file */
static HANDLE g_stop;               /* P2Coop: --stop-event */

/* P2Coop: one line for the game's Co-op menu (P2CoopHk reads it), replaced each time. */
static void status(const char *fmt, ...)
{
    if (!g_status_file[0]) return;
    char line[2048];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    FILE *f = fopen(g_status_file, "w");
    if (f) { fputs(line, f); fclose(f); }
}

static bool file_exists(const char *p) { return GetFileAttributesA(p) != INVALID_FILE_ATTRIBUTES; }

/* P2Coop: the relay folder sits in the POSTAL 2 folder (next to System\). */
static void find_game_dir(void)
{
    char exe[MAX_PATH], *slash;
    GetModuleFileNameA(NULL, exe, sizeof(exe));
    if ((slash = strrchr(exe, '\\'))) *slash = 0;
    const char *tries[] = { "%s\\..", "%s", "%s\\..\\.." };
    for (int i = 0; i < 3; i++) {
        char p[MAX_PATH], full[MAX_PATH];
        snprintf(p, sizeof(p), tries[i], exe);
        GetFullPathNameA(p, sizeof(full), full, NULL);
        snprintf(p, sizeof(p), "%s\\System\\Postal2.exe", full);
        if (file_exists(p)) { snprintf(g_game_dir, sizeof(g_game_dir), "%s", full); return; }
    }
}

/* P2Coop: SHA-256, hex. */
typedef struct { BCRYPT_ALG_HANDLE alg; BCRYPT_HASH_HANDLE h; bool ok; } Sha;

static bool sha_begin(Sha *c)
{
    memset(c, 0, sizeof(*c));
    if (BCryptOpenAlgorithmProvider(&c->alg, BCRYPT_SHA256_ALGORITHM, NULL, 0) != 0) return false;
    if (BCryptCreateHash(c->alg, &c->h, NULL, 0, NULL, 0, 0) != 0) { BCryptCloseAlgorithmProvider(c->alg, 0); return false; }
    return c->ok = true;
}

static void sha_add(Sha *c, const void *data, size_t n)
{
    if (c->ok && n) BCryptHashData(c->h, (PUCHAR)data, (ULONG)n, 0);
}

static void sha_end(Sha *c, char *out, size_t size)
{
    unsigned char digest[32];
    if (!c->ok) return;
    BCryptFinishHash(c->h, digest, sizeof(digest), 0);
    BCryptDestroyHash(c->h); BCryptCloseAlgorithmProvider(c->alg, 0);
    c->ok = false;
    for (int i = 0; i < 32 && size > (size_t)(i * 2 + 2); i++) sprintf(out + i * 2, "%02x", digest[i]);
}

/* P2Coop: SHA-256 of a file in the POSTAL 2 folder, hex, or "missing". */
static void file_hash(const char *rel, char *out, size_t size)
{
    char path[MAX_PATH + 64];
    snprintf(path, sizeof(path), "%s\\%s", g_game_dir, rel);
    snprintf(out, size, "missing");
    FILE *f = fopen(path, "rb");
    if (!f) return;
    static unsigned char buf[65536];
    Sha c;
    if (sha_begin(&c)) {
        size_t n;
        while ((n = fread(buf, 1, sizeof(buf), f)) > 0) sha_add(&c, buf, n);
        sha_end(&c, out, size);
    }
    fclose(f);
}

static int cmp_names(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }

/* P2Coop: SHA-256 over the game's packages: for each package in Textures, Sounds, StaticMeshes,
   Animations and System (sorted), its lower case "<folder>/<file>" and the GUID from its header,
   which UE2 renews each time a package is saved and which the engine's own "Package version
   mismatch" compares. Another game language (the localized packages, e.g. Textures\STV2.utx), a
   DLC or a mod gives another hash, found here instead of after the game has connected. */
static void packages_hash(char *out, size_t size)
{
    static const char *const kinds[][2] = {
        { "Textures", "utx" }, { "Sounds", "uax" }, { "StaticMeshes", "usx" }, { "Animations", "ukx" }, { "System", "u" }
    };
    char **names = NULL;
    int n = 0, cap = 0;
    snprintf(out, size, "missing");
    for (int k = 0; k < 5; k++) {
        char pattern[MAX_PATH + 64];
        snprintf(pattern, sizeof(pattern), "%s\\%s\\*.%s", g_game_dir, kinds[k][0], kinds[k][1]);
        WIN32_FIND_DATAA fd;
        HANDLE fh = FindFirstFileA(pattern, &fd);
        if (fh == INVALID_HANDLE_VALUE) continue;
        do {
            const char *dot = strrchr(fd.cFileName, '.');
            /* the pattern also finds longer extensions (8.3 names) */
            if ((fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) || !dot || _stricmp(dot + 1, kinds[k][1])) continue;
            if (n == cap) {
                char **more = realloc(names, (cap = cap ? cap * 2 : 256) * sizeof(*names));
                if (!more) break;
                names = more;
            }
            size_t len = strlen(kinds[k][0]) + strlen(fd.cFileName) + 2;
            if (!(names[n] = malloc(len))) break;
            snprintf(names[n], len, "%s/%s", kinds[k][0], fd.cFileName);
            for (char *c = names[n]; *c; c++) if (*c >= 'A' && *c <= 'Z') *c = (char)(*c - 'A' + 'a');
            n++;
        } while (FindNextFileA(fh, &fd));
        FindClose(fh);
    }
    qsort(names, (size_t)n, sizeof(*names), cmp_names);
    Sha c;
    if (sha_begin(&c)) {
        for (int i = 0; i < n; i++) {
            /* Tag 9E2A83C1, FileVersion (16 bit) at 4, the GUID at 36 for FileVersion >= 68 */
            unsigned char head[52], guid[16];
            char path[MAX_PATH + 64];
            memset(guid, 0xFF, sizeof(guid));
            snprintf(path, sizeof(path), "%s\\%s", g_game_dir, names[i]);
            FILE *f = fopen(path, "rb");
            if (f) {
                if (fread(head, 1, sizeof(head), f) == sizeof(head) && *(uint32_t *)head == 0x9E2A83C1u
                    && *(uint16_t *)(head + 4) >= 68)
                    memcpy(guid, head + 36, sizeof(guid));
                fclose(f);
            }
            sha_add(&c, names[i], strlen(names[i]) + 1);
            sha_add(&c, guid, sizeof(guid));
        }
        sha_end(&c, out, size);
    }
    for (int i = 0; i < n; i++) free(names[i]);
    free(names);
}

/* P2Coop: the Steam language of this POSTAL 2 ("language" in steamapps\appmanifest_223470.acf),
   or "unknown" (not a Steam copy). Only for a readable message: the packages hash is what counts. */
static void game_language(char *out, size_t size)
{
    char path[MAX_PATH + 64], line[512];
    snprintf(out, size, "unknown");
    snprintf(path, sizeof(path), "%s\\..\\..\\appmanifest_223470.acf", g_game_dir);
    FILE *f = fopen(path, "r");
    if (!f) return;
    while (fgets(line, sizeof(line), f)) {
        char *q = strstr(line, "\"language\""), *e;
        if (!q || !(q = strchr(q + 10, '"')) || !(e = strchr(++q, '"')) || e == q) continue;
        size_t n = (size_t)(e - q) < size - 1 ? (size_t)(e - q) : size - 1;
        for (size_t i = 0; i < n; i++) {
            char ch = q[i];
            out[i] = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') ? ch : '_';
        }
        out[n] = 0;
        break;
    }
    fclose(f);
}

/* P2Coop: InstalledVersion= from System\Version.ini (5100). */
static void game_version(char *out, size_t size)
{
    char path[MAX_PATH];
    snprintf(path, sizeof(path), "%s\\System\\Version.ini", g_game_dir);
    GetPrivateProfileStringA("Shell.ShellRootWindow", "InstalledVersion", "unknown", out, (DWORD)size, path);
}

/* P2Coop: "link=<protocol> game=<Version.ini> p2coop=<P2Coop.u> hook=<System\dinput8.dll>
   pkgs=<packages_hash> lang=<Steam language>"; the hashes are SHA-256. version_mismatch compares
   it field by field. */
static void make_version(void)
{
    char ver[32], hash[80], hook[80], pkgs[80], lang[32];
    game_version(ver, sizeof(ver));
    for (char *c = ver; *c; c++) if (*c == ' ') *c = '_';
    file_hash("System\\P2Coop.u", hash, sizeof(hash));
    file_hash("System\\dinput8.dll", hook, sizeof(hook));
    packages_hash(pkgs, sizeof(pkgs));
    game_language(lang, sizeof(lang));
    snprintf(g_version, sizeof(g_version), "link=%s game=%s p2coop=%s%s hook=%s pkgs=%s lang=%s",
             LINK_PROTOCOL, ver, hash, g_version_suffix, hook, pkgs, lang);
}

/* P2Coop: the value of "<key>=" in a version string, "" if it has none. */
static void version_field(const char *v, const char *key, char *out, size_t size)
{
    size_t kl = strlen(key);
    out[0] = 0;
    while (v && *v) {
        while (*v == ' ') v++;
        const char *end = strchr(v, ' ');
        size_t len = end ? (size_t)(end - v) : strlen(v);
        if (len > kl && v[kl] == '=' && !strncmp(v, key, kl)) {
            size_t n = len - kl - 1 < size - 1 ? len - kl - 1 : size - 1;
            memcpy(out, v + kl + 1, n); out[n] = 0;
            return;
        }
        v = end;
    }
}

/* P2Coop: false if a joiner's version matches ours, else true and why, for its error message.
   The language is not compared (copies with the same files may name different languages); it
   only names the cause when the packages differ. */
static bool version_mismatch(const char *theirs, char *why, size_t size)
{
    static const char *const keys[] = { "link", "game", "p2coop", "hook", "pkgs" };
    char a[128], b[128], la[32], lb[32];
    for (int i = 0; i < 5; i++) {
        version_field(g_version, keys[i], a, sizeof(a));
        version_field(theirs, keys[i], b, sizeof(b));
        if (b[0] && !strcmp(a, b)) continue;
        if (i == 0 || !b[0])
            snprintf(why, size, "the co-op relays differ (host link=%s, you %s): install the same P2Coop release as the host",
                     a, b[0] ? b : "an older release");
        else if (i == 1)
            snprintf(why, size, "POSTAL 2 versions differ (host %s, you %s): update the game in Steam", a, b);
        else if (i < 4)
            snprintf(why, size, "P2Coop versions differ: install the same P2Coop release as the host");
        else {
            version_field(g_version, "lang", la, sizeof(la));
            version_field(theirs, "lang", lb, sizeof(lb));
            if (strcmp(la, lb) && strcmp(la, "unknown") && strcmp(lb, "unknown") && la[0] && lb[0])
                snprintf(why, size, "game files differ: the host plays POSTAL 2 in %s, you in %s. Set the same game "
                         "language in Steam (POSTAL 2, Properties, Language)", la, lb);
            else if (!strcmp(la, lb) && strcmp(la, "unknown") && la[0])
                snprintf(why, size, "game files differ (Textures, Sounds, StaticMeshes, Animations or System packages; "
                         "both in %s): a DLC, a mod or a changed game file", la);
            else
                snprintf(why, size, "game files differ (Textures, Sounds, StaticMeshes, Animations or System packages; "
                         "game language host %s, you %s): another language, a DLC or a mod", la[0] ? la : "unknown",
                         lb[0] ? lb : "unknown");
        }
        return true;
    }
    return false;
}

/* P2Coop: the environment for the game without SteamAppId/SteamGameId (inherited from Steam or
   from steam_api, they would make POSTAL 2 init Steam as Spacewar). Caller frees. */
static char *game_environment(void)
{
    char *env = GetEnvironmentStringsA(), *out, *o;
    size_t total = 0;
    for (char *p = env; *p; p += strlen(p) + 1) total += strlen(p) + 1;
    out = o = malloc(total + 2);
    for (char *p = env; *p; p += strlen(p) + 1) {
        if (!_strnicmp(p, "SteamAppId=", 11) || !_strnicmp(p, "SteamGameId=", 12)) continue;
        size_t n = strlen(p) + 1;
        memcpy(o, p, n); o += n;
    }
    *o++ = 0;
    if (o == out + 1) *o++ = 0;
    FreeEnvironmentStringsA(env);
    return out;
}

static void launch_game(const char *exe_name, const char *url, const char *args)
{
    if (g_no_launch) return;
    char cmd[4096], exe[MAX_PATH], sys[MAX_PATH];
    snprintf(sys, sizeof(sys), "%s\\System", g_game_dir);
    snprintf(exe, sizeof(exe), "%s\\%s", sys, exe_name);
    /* P2Coop: the installer puts the co-op settings in the player's own Postal2.ini. */
    snprintf(cmd, sizeof(cmd), "\"%s\" \"%s\" %s %s", exe, url, args, g_game_args);
    STARTUPINFOA si; PROCESS_INFORMATION pi;
    memset(&si, 0, sizeof(si)); si.cb = sizeof(si);
    char *env = game_environment();
    BOOL ok = CreateProcessA(exe, cmd, NULL, NULL, FALSE, 0, env, sys, &si, &pi);
    free(env);
    if (!ok) {
        char buf[MAX_PATH + 100];
        snprintf(buf, sizeof(buf), "Could not start %s (error %lu).", exe, GetLastError());
        fail(buf);
    }
    CloseHandle(pi.hThread);
    g_game = pi.hProcess;
    printf("P2CoopLink: started %s %s (pid %lu)\n", exe_name, url, pi.dwProcessId);
}

static bool game_exited(void)
{
    return g_game && WaitForSingleObject(g_game, 0) == WAIT_OBJECT_0;
}

/* P2Coop: the game's menu asked the relay to close (--stop-event). */
static bool stop_requested(void)
{
    return g_stop && WaitForSingleObject(g_stop, 0) == WAIT_OBJECT_0;
}

/* ---------------------------------------------------------------- callbacks */

typedef void (*CbHandler)(int id, void *data);

static void pump(CbHandler h)
{
    CallbackMsg msg;
    S.RunFrame(g_pipe);
    while (S.GetNextCallback(g_pipe, &msg)) {
        if (msg.callback == CB_CALL_COMPLETED) {
            APICallCompleted *done = (APICallCompleted *)msg.param;
            void *buf = calloc(1, done->param_size + 16);
            bool failed = true;
            if (S.GetAPICallResult(g_pipe, done->call, buf, done->param_size, done->callback, &failed) && !failed)
                h(done->callback, buf);
            free(buf);
        } else
            h(msg.callback, msg.param);
        S.FreeLastCallback(g_pipe);
    }
}

/* ---------------------------------------------------------------- udp helpers */

static SOCKET udp_socket(int port)
{
    SOCKET s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    struct sockaddr_in a; memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET; a.sin_addr.s_addr = htonl(INADDR_LOOPBACK); a.sin_port = htons((u_short)port);
    if (bind(s, (struct sockaddr *)&a, sizeof(a)) != 0) { closesocket(s); return INVALID_SOCKET; }
    u_long nb = 1; ioctlsocket(s, FIONBIO, &nb);
    DWORD bytes; BOOL off = FALSE; /* SIO_UDP_CONNRESET: ignore ICMP port unreachable */
    WSAIoctl(s, 0x9800000C, &off, sizeof(off), NULL, 0, &bytes, NULL, NULL);
    int buf = 1 << 20;
    setsockopt(s, SOL_SOCKET, SO_RCVBUF, (char *)&buf, sizeof(buf));
    setsockopt(s, SOL_SOCKET, SO_SNDBUF, (char *)&buf, sizeof(buf));
    return s;
}

static int local_port(SOCKET s)
{
    struct sockaddr_in a; int len = sizeof(a);
    getsockname(s, (struct sockaddr *)&a, &len);
    return ntohs(a.sin_port);
}

static void relay_config(void)
{
    /* k_ESteamNetworkingConfig_SendBufferSize 9, RecvBufferSize 47, RecvMaxMessageSize 49 */
    S.SetConfigInt(g_utils, 9, 4 << 20);
    S.SetConfigInt(g_utils, 47, 4 << 20);
    S.SetConfigInt(g_utils, 49, 4 << 20); /* P2Coop: was only in a comment in HXCoop */
}

/* ---------------------------------------------------------------- host */

#define MAX_PEERS 16
#define MAX_CONNS 8
typedef struct { int id; SOCKET s; DWORD last; } Conn;
typedef struct { u64 sid; bool verified; Conn conns[MAX_CONNS]; DWORD last_heard, last_ping, since; } Peer;
static Peer g_peers[MAX_PEERS];
static u64 g_lobby;
/* P2Coop: who passed the version check while still in the lobby (a dropped peer that comes back
   is relayed again), and Steam sessions from users who are not in the lobby yet. */
#define MAX_VERIFIED 64
#define MAX_PENDING 16
static u64 g_verified[MAX_VERIFIED];
static int g_verified_n;
static struct { u64 sid; DWORD since; } g_pending[MAX_PENDING];
static bool g_lobby_failed;
static unsigned long g_relayed;     /* P2Coop: game packets relayed, for the status line */

static Peer *find_peer(u64 sid)
{
    for (int i = 0; i < MAX_PEERS; i++) if (g_peers[i].sid == sid) return &g_peers[i];
    return NULL;
}

/* P2Coop: only lobby members (the host's friends who joined it) get sessions and peers. */
static bool is_lobby_member(u64 sid)
{
    if (!g_lobby || !sid) return false;
    int n = S.GetNumLobbyMembers(g_mm, g_lobby);
    for (int i = 0; i < n; i++) if (S.GetLobbyMemberByIndex(g_mm, g_lobby, i) == sid) return true;
    return false;
}

static bool was_verified(u64 sid)
{
    for (int i = 0; i < g_verified_n; i++) if (g_verified[i] == sid) return true;
    return false;
}

static void remember_verified(u64 sid)
{
    if (!was_verified(sid) && g_verified_n < MAX_VERIFIED) g_verified[g_verified_n++] = sid;
}

static void forget_verified(u64 sid)
{
    for (int i = 0; i < g_verified_n; i++)
        if (g_verified[i] == sid) { g_verified[i] = g_verified[--g_verified_n]; return; }
}

/* P2Coop: a Steam session request. Steam may report it before the user's lobby entry, so a user
   who is not a member yet waits up to 10 s (check_pending) before the session is closed. */
static void session_request(u64 sid)
{
    int free_slot = -1;
    if (!sid) return;
    if (is_lobby_member(sid)) { accept_session(sid); return; }
    for (int i = 0; i < MAX_PENDING; i++) {
        if (g_pending[i].sid == sid) return;
        if (!g_pending[i].sid && free_slot < 0) free_slot = i;
    }
    if (free_slot < 0) { close_session(sid); return; }
    g_pending[free_slot].sid = sid;
    g_pending[free_slot].since = GetTickCount();
}

static void check_pending(DWORD now)
{
    for (int i = 0; i < MAX_PENDING; i++) {
        u64 sid = g_pending[i].sid;
        if (!sid) continue;
        if (is_lobby_member(sid)) accept_session(sid);
        else if (now - g_pending[i].since > 10000) {
            printf("P2CoopLink: refused a Steam connection from %s (not in the lobby).\n", friend_name(sid));
            close_session(sid);
        } else continue;
        g_pending[i].sid = 0;
    }
}

static void drop_peer(Peer *p, const char *why)
{
    if (!p || !p->sid) return;
    printf("P2CoopLink: %s left (%s).\n", friend_name(p->sid), why);
    for (int i = 0; i < MAX_CONNS; i++) if (p->conns[i].s) closesocket(p->conns[i].s);
    close_session(p->sid);
    memset(p, 0, sizeof(*p));
}

static SOCKET game_socket(void)
{
    SOCKET s = udp_socket(0);
    if (s == INVALID_SOCKET) return s;
    struct sockaddr_in a; memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET; a.sin_addr.s_addr = htonl(INADDR_LOOPBACK); a.sin_port = htons((u_short)g_port);
    connect(s, (struct sockaddr *)&a, sizeof(a));
    return s;
}

static Peer *add_peer(u64 sid)
{
    for (int i = 0; i < MAX_PEERS; i++) {
        Peer *p = &g_peers[i];
        if (p->sid) continue;
        memset(p, 0, sizeof(*p));
        p->sid = sid; p->last_heard = p->last_ping = p->since = GetTickCount();
        p->verified = was_verified(sid);
        printf("P2CoopLink: %s %s through Steam.\n", friend_name(sid), p->verified ? "reconnected" : "connected");
        return p;
    }
    return NULL;
}

/* The socket for one game connection of a peer, created on first use. Connections idle
   for 30 s are closed, the oldest one is reused when all slots are taken. */
static Conn *peer_conn(Peer *p, int id)
{
    Conn *free_slot = NULL, *oldest = &p->conns[0];
    for (int i = 0; i < MAX_CONNS; i++) {
        Conn *c = &p->conns[i];
        if (c->s && c->id == id) return c;
        if (!c->s && !free_slot) free_slot = c;
        if (c->last < oldest->last) oldest = c;
    }
    if (!free_slot) { closesocket(oldest->s); memset(oldest, 0, sizeof(*oldest)); free_slot = oldest; }
    free_slot->s = game_socket();
    if (free_slot->s == INVALID_SOCKET) { free_slot->s = 0; return NULL; }
    free_slot->id = id; free_slot->last = GetTickCount();
    return free_slot;
}

static void host_cb(int id, void *data)
{
    switch (id) {
    case CB_LOBBY_CREATED: {
        LobbyCreated *c = data;
        if (c->result != 1) { g_lobby_failed = true; break; }
        if (g_lobby == c->lobby) break; /* real Steam reports it twice (703 and 513) */
        g_lobby = c->lobby;
        char buf[64];
        S.SetLobbyData(g_mm, g_lobby, "p2coop", LINK_PROTOCOL);
        S.SetLobbyData(g_mm, g_lobby, "host", S.GetPersonaName(g_friends));
        snprintf(buf, sizeof(buf), "+connect_lobby %llu", (unsigned long long)g_lobby);
        S.SetRichPresence(g_friends, "connect", buf);
        S.SetRichPresence(g_friends, "status", "Hosting POSTAL 2 co-op");
        break;
    }
    case CB_SESSION_REQUEST:
        session_request(S.IdentGet(data));
        break;
    case CB_SESSION_FAILED: {
        u64 sid = S.IdentGet((char *)data + 0);
        drop_peer(find_peer(sid), "connection failed");
        break;
    }
    case CB_LOBBY_CHAT_UPDATE: {
        LobbyChatUpdate *u = data;
        if (u->lobby == g_lobby && (u->state & (0x2 | 0x4 | 0x8 | 0x10))) {
            forget_verified(u->user_changed);
            drop_peer(find_peer(u->user_changed), "left the lobby");
        }
        break;
    }
    }
}

/* P2Coop: control message from a peer on channel 1. */
static void host_control(Peer *p, const char *text, int size)
{
    if (size >= 1 && text[0] == 'B') { forget_verified(p->sid); drop_peer(p, "quit"); return; }
    if (size >= 1 && text[0] == 'V') {
        char theirs[1024], why[600];
        int n = size - 1 < (int)sizeof(theirs) - 1 ? size - 1 : (int)sizeof(theirs) - 1;
        memcpy(theirs, text + 1, n); theirs[n] = 0;
        if (!version_mismatch(theirs, why, sizeof(why))) {
            p->verified = true;
            remember_verified(p->sid);
            send_ctl(p->sid, "A");
            printf("P2CoopLink: %s passed the version check.\n", friend_name(p->sid));
        } else {
            char reply[700];
            p->verified = false;
            forget_verified(p->sid);
            snprintf(reply, sizeof(reply), "X%s", why);
            send_ctl(p->sid, reply);
            printf("P2CoopLink: refused %s: %s\nP2CoopLink:   host %s\nP2CoopLink:   them %s\n",
                   friend_name(p->sid), why, g_version, theirs);
        }
    }
}

static int run_host(const char *map)
{
    S.CreateLobby(g_mm, 1 /* friends only */, MAX_PEERS + 1);
    printf("P2CoopLink: creating a friends-only Steam lobby...\n");
    DWORD t0 = GetTickCount();
    while (!g_lobby && !g_lobby_failed && GetTickCount() - t0 < 15000 && !stop_requested()) { pump(host_cb); Sleep(20); }
    if (stop_requested()) quit_stopped();
    if (!g_lobby) fail("Steam did not create a lobby. Check that you are online in Steam.");

    char url[1024];
    snprintf(url, sizeof(url), "%s?Game=P2Coop.CoopGame?Listen?Port=%d%s", map, g_port, g_url_extra);
    launch_game("Postal2.exe", url, "-multihome=127.0.0.1");
    status("hosting %llu", (unsigned long long)g_lobby);

    printf("\nP2CoopLink: hosting. Lobby id: %llu\n"
           "Friends join with P2CoopLink (Join), by Steam invite, or with this lobby id.\n"
           "Keep this window open while you play. Close the game to stop.\n\n",
           (unsigned long long)g_lobby);

    static unsigned char buf[65536];
    DWORD last_status = GetTickCount();
    for (;;) {
        pump(host_cb);
        void *msgs[64];
        int n;
        while ((n = S.ReceiveMessages(g_msgs, 1, msgs, 64)) > 0) {
            for (int i = 0; i < n; i++) {
                u64 sid = msg_sender(msgs[i]);
                Peer *p = find_peer(sid);
                if (!p && is_lobby_member(sid)) p = add_peer(sid);
                if (p) {
                    p->last_heard = GetTickCount();
                    host_control(p, *(char **)msgs[i], *(int *)((char *)msgs[i] + 4));
                }
                S.MessageRelease(msgs[i]);
            }
        }
        while ((n = S.ReceiveMessages(g_msgs, 0, msgs, 64)) > 0) {
            for (int i = 0; i < n; i++) {
                Peer *p = find_peer(msg_sender(msgs[i]));
                unsigned char *data = *(unsigned char **)msgs[i];
                int size = *(int *)((char *)msgs[i] + 4);
                /* P2Coop: game traffic only from peers that passed the version check */
                if (p && p->verified && size > 1) {
                    Conn *c = peer_conn(p, data[0]);
                    p->last_heard = GetTickCount();
                    if (c) { c->last = p->last_heard; send(c->s, (char *)data + 1, size - 1, 0); g_relayed++; }
                }
                S.MessageRelease(msgs[i]);
            }
        }
        DWORD now = GetTickCount();
        check_pending(now);
        for (int i = 0; i < MAX_PEERS; i++) {
            Peer *p = &g_peers[i];
            if (!p->sid) continue;
            if (!p->verified && now - p->since > 5000) { drop_peer(p, "no version check"); continue; }
            for (int k = 0; k < MAX_CONNS; k++) {
                Conn *c = &p->conns[k];
                int got;
                if (!c->s) continue;
                while ((got = recv(c->s, (char *)buf + 1, sizeof(buf) - 1, 0)) > 0) {
                    buf[0] = (unsigned char)c->id;
                    c->last = now;
                    send_to(p->sid, buf, got + 1, SEND_UNRELIABLE_NO_NAGLE, 0);
                    g_relayed++;
                }
                if (c->s && now - c->last > 30000) { closesocket(c->s); memset(c, 0, sizeof(*c)); }
            }
            if (now - p->last_ping > 1000) { p->last_ping = now; send_ctl(p->sid, "K"); }
            if (now - p->last_heard > 20000) drop_peer(p, "timed out");
        }
        if (now - last_status > 10000) {
            int peers = 0;
            for (int i = 0; i < MAX_PEERS; i++) if (g_peers[i].sid && g_peers[i].verified) peers++;
            printf("P2CoopLink: status: %d player(s) connected, %lu game packets relayed\n", peers, g_relayed);
            last_status = now;
        }
        if (game_exited() || stop_requested()) break;
        Sleep(1);
    }
    for (int i = 0; i < MAX_PEERS; i++)
        if (g_peers[i].sid) { send_ctl(g_peers[i].sid, "B"); drop_peer(&g_peers[i], "host closed"); }
    S.LeaveLobby(g_mm, g_lobby);
    S.SetRichPresence(g_friends, "connect", "");
    S.SetRichPresence(g_friends, "status", "");
    for (int i = 0; i < 20; i++) { pump(host_cb); Sleep(10); }
    printf("P2CoopLink: host closed, %lu game packets relayed\n", g_relayed);
    return 0;
}

/* ---------------------------------------------------------------- join */

static u64 g_join_lobby, g_host;
static bool g_join_failed;
static bool g_host_left;            /* P2Coop: the host said goodbye or left the lobby */
static int g_verdict;               /* P2Coop: 0 waiting, 1 accepted, -1 refused */
static char g_refusal[600];

static u64 parse_connect(const char *s)
{
    const char *p = strstr(s, "+connect_lobby");
    if (!p) return 0;
    return strtoull(p + 14, NULL, 10);
}

static void join_cb(int id, void *data)
{
    switch (id) {
    case CB_LOBBY_JOIN_REQUESTED:
        if (!g_join_lobby) g_join_lobby = ((GameLobbyJoinRequested *)data)->lobby;
        break;
    case CB_RICH_PRESENCE_JOIN:
        if (!g_join_lobby) g_join_lobby = parse_connect(((GameRichPresenceJoinRequested *)data)->connect);
        break;
    case CB_LOBBY_ENTER: {
        LobbyEnter *e = data;
        if (e->lobby != g_join_lobby) break;
        if (e->response != 1) { g_join_failed = true; break; }
        g_host = S.GetLobbyOwner(g_mm, e->lobby);
        break;
    }
    case CB_SESSION_REQUEST: {
        u64 sid = S.IdentGet(data);
        if (sid == g_host) accept_session(sid);
        break;
    }
    case CB_LOBBY_CHAT_UPDATE: {
        LobbyChatUpdate *u = data;
        if (g_host && u->lobby == g_join_lobby && u->user_changed == g_host && (u->state & (0x2 | 0x4 | 0x8 | 0x10)))
            g_host_left = true;
        break;
    }
    }
}

/* P2Coop: out of any lobby and off Steam, for fail(). */
static void ignore_cb(int id, void *data) { (void)id; (void)data; }

static void steam_leave(void)
{
    if (g_lobby) {
        S.LeaveLobby(g_mm, g_lobby);
        S.SetRichPresence(g_friends, "connect", "");
        S.SetRichPresence(g_friends, "status", "");
        g_lobby = 0;
    }
    if (g_join_lobby) { S.LeaveLobby(g_mm, g_join_lobby); g_join_lobby = 0; }
    for (int i = 0; i < 20; i++) { pump(ignore_cb); Sleep(10); }
    S.Shutdown();
    g_steam_up = false;
}

/* P2Coop: --stop-event before the relay got going: out of Steam, no error. */
static void quit_stopped(void)
{
    printf("P2CoopLink: stopped by the game.\n");
    if (g_steam_up) steam_leave();
    exit(0);
}

#define MAX_LISTED 16
#define NAME_SIZE 64
static bool g_list;                 /* P2Coop: "list" mode, for the Co-op menu */

/* P2Coop: Name for the menu's status line: no tabs or line breaks, cut at a UTF-8 character. */
static void clean_name(char *out, const char *name)
{
    size_t n = 0;
    for (; name[n] && n < NAME_SIZE - 1; n++) out[n] = (unsigned char)name[n] < 0x20 ? ' ' : name[n];
    if (name[n]) while (n > 0 && ((unsigned char)out[n] & 0xC0) == 0x80) n--;
    out[n] = 0;
}

/* Friends who host: playing AppID 480 in a lobby with the tag p2coop=LINK_PROTOCOL (P2Coop: other
   Spacewar tools use 480 too), checked again after joining.
   P2Coop: everyone in a joinable friends-only lobby shows it, so each lobby is listed once, under
   the host's name from the lobby data once Steam has it (RequestLobbyData), else the friend's.
   While POSTAL 2 runs too, Steam may report the friend as playing POSTAL 2 instead; invites and
   lobby ids still work then. */
static int list_hosting_friends(u64 *lobbies, char names[][NAME_SIZE], int max)
{
    static u64 requested[64];
    static int requested_n;
    int n = 0, count = S.GetFriendCount(g_friends, 0x04 /* immediate */);
    for (int i = 0; i < count && n < max; i++) {
        u64 f = S.GetFriendByIndex(g_friends, i, 0x04);
        FriendGameInfo gi;
        memset(&gi, 0, sizeof(gi));
        if (!S.GetFriendGamePlayed(g_friends, f, &gi)) continue;
        if ((gi.game_id & 0xFFFFFF) != 480 || !gi.lobby) continue;
        int k = 0;
        while (k < n && lobbies[k] != gi.lobby) k++;
        if (k < n) continue;
        int r = 0;
        while (r < requested_n && requested[r] != gi.lobby) r++;
        if (r == requested_n && S.RequestLobbyData && requested_n < 64 && S.RequestLobbyData(g_mm, gi.lobby))
            requested[requested_n++] = gi.lobby;
        /* the lobby data comes some time after RequestLobbyData; until then it is not listed */
        const char *tag = S.GetLobbyData(g_mm, gi.lobby, "p2coop");
        if (S.RequestLobbyData && (!tag || strcmp(tag, LINK_PROTOCOL) != 0)) continue;
        const char *host = S.GetLobbyData(g_mm, gi.lobby, "host");
        lobbies[n] = gi.lobby;
        clean_name(names[n], host && *host ? host : friend_name(f));
        n++;
    }
    return n;
}

/* P2Coop: the friends' games for the Co-op menu: "hosts\t<lobby>\t<name>...", when it changes. */
static void status_hosts(const u64 *lobbies, char names[][NAME_SIZE], int n)
{
    static char last[2048] = "-";
    char line[2048];
    size_t len = (size_t)snprintf(line, sizeof(line), "hosts");
    for (int i = 0; i < n; i++) {
        char item[NAME_SIZE + 32];
        size_t w = (size_t)snprintf(item, sizeof(item), "\t%llu\t%s", (unsigned long long)lobbies[i], names[i]);
        if (len + w >= sizeof(line)) break;
        memcpy(line + len, item, w + 1);
        len += w;
    }
    if (!strcmp(line, last)) return;
    memcpy(last, line, len + 1);
    status("%s", line);
    printf("P2CoopLink: %d friend game(s) hosting\n", n);
}

static void pick_lobby(void)
{
    u64 lobbies[MAX_LISTED];
    static char names[MAX_LISTED][NAME_SIZE];
    int shown = -1;
    printf("P2CoopLink: looking for Steam friends who are hosting...\n"
           "(You can also accept a Steam invite, or type a lobby id and press Enter.)\n");
    char typed[64] = ""; int tl = 0;
    while (!g_join_lobby) {
        if (stop_requested()) quit_stopped();
        if (game_exited()) fail("The game was closed.");
        pump(join_cb);
        int n = list_hosting_friends(lobbies, names, MAX_LISTED);
        /* P2Coop: the Co-op menu lists the games and the player picks one there (the menu then
           starts "join <lobby>"); an accepted Steam invite (join_cb) joins from here. */
        if (g_list) { status_hosts(lobbies, names, n); Sleep(50); continue; }
        if (n == 1) {
            printf("P2CoopLink: found %s.\n", names[0]);
            g_join_lobby = lobbies[0];
            break;
        }
        if (n > 1 && n != shown) {
            printf("\nFriends hosting:\n");
            for (int i = 0; i < n; i++) printf("  %d) %s\n", i + 1, names[i]);
            printf("Type a number and press Enter: ");
            shown = n;
        }
        while (g_console && _kbhit()) {
            int c = _getch();
            if (c == '\r') {
                printf("\n");
                u64 v = strtoull(typed, NULL, 10);
                if (v >= 1 && v <= (u64)n) g_join_lobby = lobbies[v - 1];
                else if (v > 1000) g_join_lobby = v;
                tl = 0; typed[0] = 0;
            } else if (c >= '0' && c <= '9' && tl < 60) { typed[tl++] = (char)c; typed[tl] = 0; putchar(c); }
        }
        Sleep(50);
    }
}

/* P2Coop: enters the lobby, then waits for the host's answer to our version. */
static void join_and_check(void)
{
    for (int attempt = 0; attempt < 3 && !g_host; attempt++) {
        g_join_failed = false;
        printf("P2CoopLink: joining lobby %llu...\n", (unsigned long long)g_join_lobby);
        S.JoinLobby(g_mm, g_join_lobby);
        DWORD t0 = GetTickCount();
        while (!g_host && !g_join_failed && GetTickCount() - t0 < 15000 && !game_exited() && !stop_requested()) { pump(join_cb); Sleep(20); }
        if (stop_requested()) quit_stopped();
    }
    if (!g_host) fail("Could not join the lobby. Is your friend still hosting?");
    const char *tag = S.GetLobbyData(g_mm, g_join_lobby, "p2coop");
    if (!tag || !*tag) fail("That Steam lobby is not a POSTAL 2 co-op game (another Spacewar game).");
    if (strcmp(tag, LINK_PROTOCOL) != 0) fail("That lobby is from another P2CoopLink version.");
    printf("P2CoopLink: host %s\n", friend_name(g_host));
    accept_session(g_host);

    char v[sizeof(g_version) + 2];
    snprintf(v, sizeof(v), "V%s", g_version);
    DWORD t0 = GetTickCount(), sent = 0;
    while (!g_verdict && !g_host_left && GetTickCount() - t0 < 20000 && !game_exited() && !stop_requested()) {
        if (GetTickCount() - sent > 2000) { send_ctl(g_host, v); sent = GetTickCount(); }
        pump(join_cb);
        void *msgs[16]; int n;
        while ((n = S.ReceiveMessages(g_msgs, 1, msgs, 16)) > 0) {
            for (int i = 0; i < n; i++) {
                char *data = *(char **)msgs[i];
                int size = *(int *)((char *)msgs[i] + 4);
                if (msg_sender(msgs[i]) == g_host && size >= 1) {
                    if (data[0] == 'A') g_verdict = 1;
                    else if (data[0] == 'B') g_host_left = true;
                    else if (data[0] == 'X') {
                        g_verdict = -1;
                        int k = size - 1 < (int)sizeof(g_refusal) - 1 ? size - 1 : (int)sizeof(g_refusal) - 1;
                        memcpy(g_refusal, data + 1, k); g_refusal[k] = 0;
                    }
                }
                S.MessageRelease(msgs[i]);
            }
        }
        Sleep(20);
    }
    if (stop_requested()) quit_stopped();
    if (!g_verdict && g_host_left) fail("The host closed the game.");
    if (g_verdict < 0) {
        char buf[700];
        snprintf(buf, sizeof(buf), "The host refused the connection: %s", g_refusal);
        S.LeaveLobby(g_mm, g_join_lobby);
        fail(buf);
    }
    if (!g_verdict) fail("The host did not answer the version check.");
    printf("P2CoopLink: version check passed (%s)\n", g_version);
}

static int run_join(u64 lobby)
{
    g_join_lobby = lobby;
    if (!g_join_lobby) { status("searching"); pick_lobby(); }
    status("joining");
    join_and_check();

    SOCKET s = udp_socket(0);
    if (s == INVALID_SOCKET) fail("Could not open a local UDP port.");
    int port = local_port(s);
    char url[256];
    snprintf(url, sizeof(url), "127.0.0.1:%d", port);
    launch_game(g_client_exe, url, "");
    status("ready %s", url);
    printf("P2CoopLink: relaying 127.0.0.1:%d <-> %s over Steam. Keep this window open.\n", port, friend_name(g_host));

    /* one id per game source address (connection), see the top of the file */
    struct sockaddr_in games[MAX_CONNS]; DWORD games_last[MAX_CONNS]; int games_n = 0;
    unsigned char next_id = 0, ids[MAX_CONNS];
    static unsigned char buf[65536];
    DWORD last_heard = GetTickCount(), last_ping = 0, warned = 0, last_status = GetTickCount(), host_left_at = 0;
    for (;;) {
        pump(join_cb);
        struct sockaddr_in from; int fl = sizeof(from), got;
        while ((got = recvfrom(s, (char *)buf + 1, sizeof(buf) - 1, 0, (struct sockaddr *)&from, &fl)) > 0) {
            int k;
            for (k = 0; k < games_n; k++)
                if (games[k].sin_port == from.sin_port && games[k].sin_addr.s_addr == from.sin_addr.s_addr) break;
            if (k == games_n) {
                if (games_n < MAX_CONNS) games_n++;
                else { k = 0; for (int j = 1; j < MAX_CONNS; j++) if (games_last[j] < games_last[k]) k = j; }
                games[k] = from; ids[k] = next_id++;
            }
            games_last[k] = GetTickCount();
            buf[0] = ids[k];
            send_to(g_host, buf, got + 1, SEND_UNRELIABLE_NO_NAGLE, 0);
            g_relayed++;
            fl = sizeof(from);
        }
        void *msgs[64]; int n;
        while ((n = S.ReceiveMessages(g_msgs, 0, msgs, 64)) > 0) {
            for (int i = 0; i < n; i++) {
                unsigned char *data = *(unsigned char **)msgs[i];
                int size = *(int *)((char *)msgs[i] + 4);
                if (msg_sender(msgs[i]) == g_host && size > 1) {
                    last_heard = GetTickCount();
                    for (int k = 0; k < games_n; k++)
                        if (ids[k] == data[0]) { sendto(s, (char *)data + 1, size - 1, 0, (struct sockaddr *)&games[k], sizeof(games[k])); g_relayed++; break; }
                }
                S.MessageRelease(msgs[i]);
            }
        }
        while ((n = S.ReceiveMessages(g_msgs, 1, msgs, 64)) > 0) {
            for (int i = 0; i < n; i++) {
                if (msg_sender(msgs[i]) == g_host) {
                    last_heard = GetTickCount();
                    if (*(int *)((char *)msgs[i] + 4) >= 1 && (*(char **)msgs[i])[0] == 'B') g_host_left = true;
                }
                S.MessageRelease(msgs[i]);
            }
        }
        DWORD now = GetTickCount();
        /* P2Coop: out of the lobby at once (Steam would make this player its owner, and a friend's
           Join could pick it), then pass the host's last packets on for a moment and close. */
        if (g_host_left && !host_left_at) {
            host_left_at = now;
            printf("P2CoopLink: the host closed the game.\n");
            S.LeaveLobby(g_mm, g_join_lobby);
            g_join_lobby = 0;
            status("error the host closed the game");
        }
        if (host_left_at && now - host_left_at > 3000) break;
        if (!host_left_at && now - last_ping > 1000) { last_ping = now; send_ctl(g_host, "K"); }
        if (now - last_heard > 20000 && now - warned > 20000) { warned = now; printf("P2CoopLink: no answer from the host for 20 s...\n"); }
        if (now - last_status > 10000) {
            printf("P2CoopLink: status: %lu game packets relayed\n", g_relayed);
            last_status = now;
        }
        if (game_exited() || stop_requested()) break;
        if (g_no_launch && g_console && _kbhit() && _getch() == 27) break;
        Sleep(1);
    }
    if (!host_left_at) send_ctl(g_host, "B");
    if (g_join_lobby) { S.LeaveLobby(g_mm, g_join_lobby); g_join_lobby = 0; }
    for (int i = 0; i < 20; i++) { pump(join_cb); Sleep(10); }
    close_session(g_host);
    printf("P2CoopLink: left, %lu game packets relayed\n", g_relayed);
    return 0;
}

/* ---------------------------------------------------------------- main */

int main(int argc, char **argv)
{
    const char *mode = NULL, *arg = NULL, *log_file = NULL;
    bool menu = false;
    setvbuf(stdout, NULL, _IONBF, 0);       /* P2Coop: output may be redirected */
    g_console = _isatty(_fileno(stdin)) && _isatty(_fileno(stdout)); /* no key waits when redirected */
    SetConsoleTitleA("POSTAL 2 Co-op (Steam)");
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--game") && i + 1 < argc) snprintf(g_game_dir, sizeof(g_game_dir), "%s", argv[++i]);
        else if (!strcmp(argv[i], "--port") && i + 1 < argc) g_port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--url-extra") && i + 1 < argc) snprintf(g_url_extra, sizeof(g_url_extra), "%s", argv[++i]);
        else if (!strcmp(argv[i], "--game-args") && i + 1 < argc) snprintf(g_game_args, sizeof(g_game_args), "%s", argv[++i]);
        else if (!strcmp(argv[i], "--no-launch")) g_no_launch = true;
        else if (!strcmp(argv[i], "--version-suffix") && i + 1 < argc) snprintf(g_version_suffix, sizeof(g_version_suffix), "%s", argv[++i]);
        else if (!strcmp(argv[i], "--client-exe") && i + 1 < argc) snprintf(g_client_exe, sizeof(g_client_exe), "%s", argv[++i]);
        else if (!strcmp(argv[i], "--status-file") && i + 1 < argc) snprintf(g_status_file, sizeof(g_status_file), "%s", argv[++i]);
        else if (!strcmp(argv[i], "--game-pid") && i + 1 < argc) { g_game = OpenProcess(SYNCHRONIZE, FALSE, (DWORD)atoi(argv[++i])); menu = true; }
        else if (!strcmp(argv[i], "--log") && i + 1 < argc) log_file = argv[++i];
        else if (!strcmp(argv[i], "--stop-event") && i + 1 < argc) g_stop = OpenEventA(SYNCHRONIZE, FALSE, argv[++i]);
        else if (!strcmp(argv[i], "+connect_lobby") && i + 1 < argc) { mode = "join"; arg = argv[++i]; }
        else if (!mode) mode = argv[i];
        else if (!arg) arg = argv[i];
    }
    /* P2Coop: started by the game's menu there is nobody at a console to press a key. */
    if (menu || g_status_file[0]) g_console = false;
    if (log_file && freopen(log_file, "w", stdout)) setvbuf(stdout, NULL, _IONBF, 0);
    if (!g_game_dir[0]) find_game_dir();
    if (!g_game_dir[0]) fail("POSTAL 2 not found. Put the P2CoopLink folder inside the POSTAL 2 folder (next to System).");
    make_version();

    WSADATA w;
    WSAStartup(MAKEWORD(2, 2), &w);
    steam_start();
    relay_config();
    printf("POSTAL 2 Co-op over Steam - signed in as %s\n%s\n\n", S.GetPersonaName(g_friends), g_version);

    if (!mode) {
        if (!g_console) fail("Usage: P2CoopLink.exe host [map] | join [lobby id]");
        printf("  1) Host a game\n  2) Join a friend's game\n\nChoose 1 or 2: ");
        for (;;) {
            int c = _getch();
            if (c == '1') { mode = "host"; break; }
            if (c == '2') { mode = "join"; break; }
            if (c == 27) return 0;
        }
        printf("%c\n\n", mode[0] == 'h' ? '1' : '2');
    }
    int r;
    if (!_stricmp(mode, "host")) r = run_host(arg ? arg : "suburbs-3");
    else if (!_stricmp(mode, "join")) r = run_join(arg ? strtoull(arg, NULL, 10) : 0);
    else if (!_stricmp(mode, "list")) { g_list = true; r = run_join(0); }
    else fail("Usage: P2CoopLink.exe [host [map] | join [lobby id] | list]");
    S.Shutdown();
    return r;
}
