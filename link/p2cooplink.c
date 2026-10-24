/*
 * P2CoopLink: Steam ("Spacewar", AppID 480) relay for POSTAL 2 co-op (P2Coop).
 *
 * Ported from HXCoop (steamlink/hxcoop.c in https://github.com/cranebeaker/deus-ex-coop,
 * MIT License, Copyright (c) 2026 cranebeaker and contributors). Changes for POSTAL 2 are
 * marked "P2Coop:".
 *
 * Players never deal with IP addresses or port forwarding:
 *  - host:  creates a friends-only Steam lobby, starts System\P2CoopHost.exe as a listen server
 *           bound to 127.0.0.1 and relays every friend's packets between Steam and the game port;
 *  - join:  takes a lobby id (or an invite, or a friend who is hosting), checks versions with the
 *           host, binds a local UDP port and starts System\Postal2.exe connected to it.
 * UE2 does its own reliability, so game packets go as unreliable Steam messages on channel 0.
 * Channel 1 carries control messages: K keep-alive (1 s), B goodbye,
 * V<version> version check from a joiner, A accepted / X<reason> refused from the host.
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
 * Options: --game <POSTAL 2 folder>  --port <game port, 7777>  --url-extra <?opts for the host URL>
 *          --game-args <extra game arguments>  --no-launch (relay only)
 *          --version-suffix <text> (tests: pretend to be another version)
 *          --client-exe <exe in System> (the joiner's game exe, default P2CoopHost.exe)
 *          --status-file <path>  --game-pid <pid>  (started by the game's Co-op menu, see below)
 *
 * P2Coop: the game's Co-op menu starts the relay itself (P2CoopHk.dll, "P2COOP LINK ..."): with
 * --no-launch for the game that is already running, --game-pid to quit with that game, and
 * --status-file for the menu to read: "hosting <lobby>", "searching", "choose", "joining",
 * "ready 127.0.0.1:<port>" (join: the game connects there) or "error <message>".
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
    u64 (__cdecl *GetLobbyOwner)(void *, u64);
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
static bool g_console; /* P2Coop: stdin is a console (not redirected by a test harness) */

static void status(const char *fmt, ...);

static void fail(const char *msg)
{
    status("error %s", msg);
    printf("\nP2CoopLink: ERROR: %s\n", msg);
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
    LOAD(GetLobbyOwner, "SteamAPI_ISteamMatchmaking_GetLobbyOwner");
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
static char g_version[200];         /* P2Coop: what joiner and host must agree on */
static char g_version_suffix[64];   /* P2Coop: --version-suffix, tests the mismatch path */
static char g_client_exe[64] = "P2CoopHost.exe"; /* P2Coop: --client-exe; the stock exe works too */
static char g_status_file[MAX_PATH]; /* P2Coop: --status-file */

/* P2Coop: one line for the game's Co-op menu (P2CoopHk.dll reads it), replaced each time. */
static void status(const char *fmt, ...)
{
    if (!g_status_file[0]) return;
    char line[600];
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

/* P2Coop: SHA-256 of System\P2Coop.u, hex, or "missing". */
static void package_hash(char *out, size_t size)
{
    char path[MAX_PATH];
    snprintf(path, sizeof(path), "%s\\System\\P2Coop.u", g_game_dir);
    snprintf(out, size, "missing");
    FILE *f = fopen(path, "rb");
    if (!f) return;
    BCRYPT_ALG_HANDLE alg; BCRYPT_HASH_HANDLE h;
    unsigned char digest[32], buf[65536];
    if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, NULL, 0) != 0) { fclose(f); return; }
    BCryptCreateHash(alg, &h, NULL, 0, NULL, 0, 0);
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) BCryptHashData(h, buf, (ULONG)n, 0);
    fclose(f);
    BCryptFinishHash(h, digest, sizeof(digest), 0);
    BCryptDestroyHash(h); BCryptCloseAlgorithmProvider(alg, 0);
    for (int i = 0; i < 32 && size > (size_t)(i * 2 + 2); i++) sprintf(out + i * 2, "%02x", digest[i]);
}

/* P2Coop: InstalledVersion= from System\Version.ini (5100). */
static void game_version(char *out, size_t size)
{
    char path[MAX_PATH];
    snprintf(path, sizeof(path), "%s\\System\\Version.ini", g_game_dir);
    GetPrivateProfileStringA("Shell.ShellRootWindow", "InstalledVersion", "unknown", out, (DWORD)size, path);
}

static void make_version(void)
{
    char ver[32], hash[80];
    game_version(ver, sizeof(ver));
    package_hash(hash, sizeof(hash));
    snprintf(g_version, sizeof(g_version), "link=%s game=%s p2coop=%s%s", LINK_PROTOCOL, ver, hash, g_version_suffix);
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
    /* P2Coop: without --game-args the game uses the co-op ini written by the installer. */
    snprintf(cmd, sizeof(cmd), "\"%s\" \"%s\" %s %s", exe, url, args, g_game_args[0] ? g_game_args : "ini=P2CoopGame.ini");
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
typedef struct { u64 sid; bool verified; Conn conns[MAX_CONNS]; DWORD last_heard, last_ping; } Peer;
static Peer g_peers[MAX_PEERS];
static u64 g_lobby;
static bool g_lobby_failed;
static unsigned long g_relayed;     /* P2Coop: game packets relayed, for the status line */

static Peer *find_peer(u64 sid)
{
    for (int i = 0; i < MAX_PEERS; i++) if (g_peers[i].sid == sid) return &g_peers[i];
    return NULL;
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
        p->sid = sid; p->last_heard = p->last_ping = GetTickCount();
        printf("P2CoopLink: %s connected through Steam.\n", friend_name(sid));
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
    case CB_SESSION_REQUEST: {
        u64 sid = S.IdentGet(data);
        accept_session(sid);
        break;
    }
    case CB_SESSION_FAILED: {
        u64 sid = S.IdentGet((char *)data + 0);
        drop_peer(find_peer(sid), "connection failed");
        break;
    }
    case CB_LOBBY_CHAT_UPDATE: {
        LobbyChatUpdate *u = data;
        if (u->state & (0x2 | 0x4 | 0x8 | 0x10)) drop_peer(find_peer(u->user_changed), "left the lobby");
        break;
    }
    }
}

/* P2Coop: control message from a peer on channel 1. */
static void host_control(Peer *p, const char *text, int size)
{
    if (size >= 1 && text[0] == 'B') { drop_peer(p, "quit"); return; }
    if (size >= 1 && text[0] == 'V') {
        char theirs[256];
        int n = size - 1 < (int)sizeof(theirs) - 1 ? size - 1 : (int)sizeof(theirs) - 1;
        memcpy(theirs, text + 1, n); theirs[n] = 0;
        if (strcmp(theirs, g_version) == 0) {
            p->verified = true;
            send_ctl(p->sid, "A");
            printf("P2CoopLink: %s passed the version check.\n", friend_name(p->sid));
        } else {
            char reply[600];
            snprintf(reply, sizeof(reply), "Xhost has %s, you have %s", g_version, theirs);
            send_ctl(p->sid, reply);
            printf("P2CoopLink: refused %s: version mismatch (%s).\n", friend_name(p->sid), theirs);
        }
    }
}

static int run_host(const char *map)
{
    S.CreateLobby(g_mm, 1 /* friends only */, MAX_PEERS + 1);
    printf("P2CoopLink: creating a friends-only Steam lobby...\n");
    DWORD t0 = GetTickCount();
    while (!g_lobby && !g_lobby_failed && GetTickCount() - t0 < 15000) { pump(host_cb); Sleep(20); }
    if (!g_lobby) fail("Steam did not create a lobby. Check that you are online in Steam.");

    char url[1024];
    snprintf(url, sizeof(url), "%s?Game=P2Coop.CoopGame?Listen?Port=%d%s", map, g_port, g_url_extra);
    launch_game("P2CoopHost.exe", url, "-multihome=127.0.0.1");
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
                if (!p) p = add_peer(sid);
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
        for (int i = 0; i < MAX_PEERS; i++) {
            Peer *p = &g_peers[i];
            if (!p->sid) continue;
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
        if (game_exited()) break;
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
    }
}

/* Friends who host: playing AppID 480 in a lobby (the lobby tag is checked after joining).
   P2Coop: while POSTAL 2 runs too, Steam may report the friend as playing POSTAL 2 instead;
   invites and lobby ids still work then. */
static int list_hosting_friends(u64 *lobbies, u64 *owners, int max)
{
    int n = 0, count = S.GetFriendCount(g_friends, 0x04 /* immediate */);
    for (int i = 0; i < count && n < max; i++) {
        u64 f = S.GetFriendByIndex(g_friends, i, 0x04);
        FriendGameInfo gi;
        memset(&gi, 0, sizeof(gi));
        if (!S.GetFriendGamePlayed(g_friends, f, &gi)) continue;
        if ((gi.game_id & 0xFFFFFF) != 480 || !gi.lobby) continue;
        lobbies[n] = gi.lobby; owners[n] = f; n++;
    }
    return n;
}

static void pick_lobby(void)
{
    u64 lobbies[32], owners[32];
    int shown = -1;
    printf("P2CoopLink: looking for Steam friends who are hosting...\n"
           "(You can also accept a Steam invite, or type a lobby id and press Enter.)\n");
    char typed[64] = ""; int tl = 0;
    while (!g_join_lobby) {
        if (game_exited()) fail("The game was closed.");
        pump(join_cb);
        int n = list_hosting_friends(lobbies, owners, 32);
        if (n == 1) {
            printf("P2CoopLink: found %s.\n", friend_name(owners[0]));
            g_join_lobby = lobbies[0];
            break;
        }
        if (n > 1 && n != shown) {
            printf("\nFriends hosting:\n");
            for (int i = 0; i < n; i++) printf("  %d) %s\n", i + 1, friend_name(owners[i]));
            printf("Type a number and press Enter: ");
            status("choose");
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
        while (!g_host && !g_join_failed && GetTickCount() - t0 < 15000 && !game_exited()) { pump(join_cb); Sleep(20); }
    }
    if (!g_host) fail("Could not join the lobby. Is your friend still hosting?");
    const char *tag = S.GetLobbyData(g_mm, g_join_lobby, "p2coop");
    if (tag && *tag && strcmp(tag, LINK_PROTOCOL) != 0) fail("That lobby is from another P2CoopLink version.");
    printf("P2CoopLink: host %s\n", friend_name(g_host));
    accept_session(g_host);

    char v[300];
    snprintf(v, sizeof(v), "V%s", g_version);
    DWORD t0 = GetTickCount(), sent = 0;
    while (!g_verdict && GetTickCount() - t0 < 20000) {
        if (GetTickCount() - sent > 2000) { send_ctl(g_host, v); sent = GetTickCount(); }
        pump(join_cb);
        void *msgs[16]; int n;
        while ((n = S.ReceiveMessages(g_msgs, 1, msgs, 16)) > 0) {
            for (int i = 0; i < n; i++) {
                char *data = *(char **)msgs[i];
                int size = *(int *)((char *)msgs[i] + 4);
                if (msg_sender(msgs[i]) == g_host && size >= 1) {
                    if (data[0] == 'A') g_verdict = 1;
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
    DWORD last_heard = GetTickCount(), last_ping = 0, warned = 0, last_status = GetTickCount();
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
                    if ((*(char **)msgs[i])[0] == 'B') printf("P2CoopLink: the host closed the game.\n");
                }
                S.MessageRelease(msgs[i]);
            }
        }
        DWORD now = GetTickCount();
        if (now - last_ping > 1000) { last_ping = now; send_ctl(g_host, "K"); }
        if (now - last_heard > 20000 && now - warned > 20000) { warned = now; printf("P2CoopLink: no answer from the host for 20 s...\n"); }
        if (now - last_status > 10000) {
            printf("P2CoopLink: status: %lu game packets relayed\n", g_relayed);
            last_status = now;
        }
        if (game_exited()) break;
        if (g_no_launch && g_console && _kbhit() && _getch() == 27) break;
        Sleep(1);
    }
    send_ctl(g_host, "B");
    S.LeaveLobby(g_mm, g_join_lobby);
    for (int i = 0; i < 20; i++) { pump(join_cb); Sleep(10); }
    close_session(g_host);
    printf("P2CoopLink: left, %lu game packets relayed\n", g_relayed);
    return 0;
}

/* ---------------------------------------------------------------- main */

int main(int argc, char **argv)
{
    const char *mode = NULL, *arg = NULL;
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
        else if (!strcmp(argv[i], "--game-pid") && i + 1 < argc) g_game = OpenProcess(SYNCHRONIZE, FALSE, (DWORD)atoi(argv[++i]));
        else if (!strcmp(argv[i], "+connect_lobby") && i + 1 < argc) { mode = "join"; arg = argv[++i]; }
        else if (!mode) mode = argv[i];
        else if (!arg) arg = argv[i];
    }
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
    else fail("Usage: P2CoopLink.exe [host [map] | join [lobby id]]");
    S.Shutdown();
    return r;
}
