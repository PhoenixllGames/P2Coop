//=============================================================================
// CoopPlayer: the co-op player controller (CoopGame.PlayerControllerClassName).
//
// Test hooks: the host's test actor (CoopTest*) makes a client act through its own
// input path, so real client-to-server traffic is exercised: console commands
// ("SwitchWeapon 2", "Fire" -> ServerFire), forward movement (aForward in
// PlayerWalking.PlayerMove -> ServerMove) and view rotation. The client reports
// what it sees with ServerTestSaw.
//=============================================================================
class CoopPlayer extends AWDudePlayer;

var float TestForward;		// client: forward input to apply while TestDriveUntil runs
var float TestDriveUntil;
var float JoinTime;			// server: Level.TimeSeconds of PostLogin (CoopGame defers travel)
var bool bRespawning;		// server: dead, CoopRespawner brings it back at RespawnTime
var float RespawnTime;
var float KitCheckTime;		// server: CoopGame.SpawnNear, a returning traveller's items should be here by then
var bool bSpawnedHere;		// server: had a pawn on this level (CoopGame.RestartPlayer)

const ScreenMap = 0;		// ClientShowScreen
const ScreenErrands = 1;
const ScreenHaters = 2;
const ScreenCrossOut = 3;
const ScreenNews = 4;
const CutSendInterval = 0.05;	// CoopCutscene.SendInterval
const MaxQueuedScreens = 3;
const StateWait = 3.0;			// longest wait for the host's state a screen needs
const ScreenRetry = 0.5;		// a screen that cannot show yet (another one is up, no pawn) tries again
const MaxScreenProtect = 120.0;	// server: a forced screen's protection ends by then at the latest

// Client: screens to show, oldest first.
struct ScreenRequest
{
	var byte Screen;
	var int Errand;
	var int Serial;			// CoopReplicationInfo.Serial of the host's state the screen shows
	var float ShowAt;
	var float StopWaitAt;	// show with the state at hand by then
	var bool bLogged;
};
var array<ScreenRequest> ScreenQueue;
var int ScreenTicketSeen;	// client: highest forced screen received (ClientShowScreen Ticket)
var int ScreenTicketDone;	// client: last one reported closed (ServerScreenClosed)

var int ScreenTicket;			// server: last forced screen sent to this player
var float ScreenProtectUntil;	// server: no damage until then while the forced screen is up

var bool bTestMode;			// set by the server while a test (CoopGame.Test) runs: the ClientTest* calls work

var bool bInCutscene;		// server: CoopCutscene has started the host's cutscene here
var vector CutLoc, CutPrevLoc;	// client: the host's camera, last two samples
var rotator CutRot, CutPrevRot;
var float CutTime;
var bool bClientWatching;	// client: between ClientCutsceneStart and ClientCutsceneEnd

replication
{
	reliable if (Role == ROLE_Authority)
		ClientSetCoopName, ClientShowScreen, ClientCutsceneStart, ClientCutsceneEnd;
	unreliable if (Role == ROLE_Authority)
		ClientCutsceneView;
	reliable if (Role == ROLE_Authority)
		ClientTestCommand, ClientTestFire, ClientTestDrive, ClientTestAim, ClientTestLook,
		ClientTestScreens, ClientTestEndScreens, ClientTestCamera, ClientTestCorpse, ClientTestBones;
	reliable if (Role == ROLE_Authority && bNetOwner)
		bTestMode;
	reliable if (Role < ROLE_Authority)
		ServerTestSaw, ServerTestScreens, ServerTestCamera, ServerTestBones, ServerScreenClosed;
}

// True on the server for a player on another machine. P2's screens (map, news, stats, load) and
// HUD interactions live in the local viewport's InteractionMaster, which a NetConnection lacks.
function bool IsRemote()
{
	return Role == ROLE_Authority && NetConnection(Player) != None;
}

function SetupScreens()
{
	if (!IsRemote())
		Super.SetupScreens();
}

function SetupInteractions()
{
	if (!IsRemote())
		Super.SetupInteractions();
}

function AddWeaponSelector()
{
	if (!IsRemote())
		Super.AddWeaponSelector();
}

function AddInventorySelector()
{
	if (!IsRemote())
		Super.AddInventorySelector();
}

// Stock: show the map with the errand crossed out and wait in WaitMapScreen, whose EndState fires
// the errand's completion trigger (map scripts) and tells the NPC involved. For a remote player
// the screen never comes, so the player would hang in WaitMapScreen and the errand's follow-ups
// would never happen. Do what EndState does right away and tell everyone instead; the client
// shows the crossing out on its own map.
function DisplayMapCrossOut(int ErrandIndex, name CompletionTrigger_In, optional String SendToURL)
{
	local Actor A;

	if (!IsRemote())
	{
		// The host's own errand: his map shows it, the clients show it on theirs.
		Super.DisplayMapCrossOut(ErrandIndex, CompletionTrigger_In, SendToURL);
		ProtectLocalScreen();
		ShowEveryone(ScreenCrossOut, ErrandIndex);
		if (CoopGame(Level.Game) != None)
			CoopGame(Level.Game).AnnounceErrand(self, ErrandIndex);
		return;
	}
	SendScreen(ScreenCrossOut, ErrandIndex);
	if (CompletionTrigger_In != 'None')
		foreach AllActors(class'Actor', A, CompletionTrigger_In)
			A.Trigger(None, Pawn);
	if (InterestPawn != None && InterestPawn.Health > 0 && LambController(InterestPawn.Controller) != None)
		LambController(InterestPawn.Controller).DudeErrandComplete();
	if (CoopGame(Level.Game) != None)
	{
		CoopGame(Level.Game).AnnounceErrand(self, ErrandIndex);
		RemoteSendOn(SendToURL);
	}
}

// A remote player's load screen (it never shows) would send him on to URL when it ends.
// CoopGame.SendPlayerTo hands the travel to the leader; inside the stock SendPlayerTo (only
// reached for the leader, CoopGame.bInStockSendPlayerTo) calling it again would recurse,
// so the travel itself goes on.
function RemoteSendOn(string URL)
{
	local CoopGame G;

	G = CoopGame(Level.Game);
	if (URL == "" || G == None)
		return;
	if (G.bInStockSendPlayerTo)
		G.SendPlayerEx(self, URL);
	else
		G.SendPlayerTo(self, URL);
}

// Remote players see the map and the newspaper on their own machine: the server sends the
// request (ClientShowScreen) and the client shows its CoopMapScreen/CoopNewsScreen, which read
// the host's state from CoopReplicationInfo. The story's map and newspaper moments come to the
// host's player (map scripts, the start of a day), so the host passes those to everyone.
function RequestMap()
{
	if (IsRemote())
		SendScreen(ScreenMap, 0);
	else if (Level.NetMode == NM_Client)
		QueueScreen(ScreenMap, 0, 0);
	else
		Super.RequestMap();
}

function RequestNews()
{
	if (IsRemote())
		SendScreen(ScreenNews, 0);
	else if (Level.NetMode == NM_Client)
		QueueScreen(ScreenNews, 0, 0);
	else
		Super.RequestNews();
}

// The map key: stock activates the map item, whose state code does not run on a client.
exec function QuickUseMap()
{
	local Inventory Inv;

	if (Level.NetMode != NM_Client)
	{
		Super.QuickUseMap();
		return;
	}
	if (Pawn == None || Level.Pauser != None)
		return;
	for (Inv = Pawn.Inventory; Inv != None; Inv = Inv.Inventory)
		if (MapInv(Inv) != None)
		{
			RequestMap();
			return;
		}
}

function DisplayMap()
{
	if (IsRemote())
		SendScreen(ScreenMap, 0);
	else
		Super.DisplayMap();
}

function DisplayMapErrands(optional String SendToURL, optional bool bWantFancyFadeIn)
{
	if (IsRemote())
	{
		SendScreen(ScreenErrands, 0);
		RemoteSendOn(SendToURL);
		return;
	}
	Super.DisplayMapErrands(SendToURL, bWantFancyFadeIn);
	ProtectLocalScreen();
	ShowEveryone(ScreenErrands);
}

function DisplayMapHaters(optional String SendToURL)
{
	if (IsRemote())
	{
		SendScreen(ScreenHaters, 0);
		RemoteSendOn(SendToURL);
		return;
	}
	Super.DisplayMapHaters(SendToURL);
	ProtectLocalScreen();
	ShowEveryone(ScreenHaters);
}

function DisplayNews()
{
	if (IsRemote())
	{
		SendScreen(ScreenNews, 0);
		return;
	}
	Super.DisplayNews();
	ProtectLocalScreen();
	ShowEveryone(ScreenNews);
}

// Host: show a story screen to the remote players too.
function ShowEveryone(byte Screen, optional int ErrandIndex)
{
	local Controller C;

	if (Level.NetMode == NM_Client)
		return;
	for (C = Level.ControllerList; C != None; C = C.NextController)
		if (CoopPlayer(C) != None && CoopPlayer(C).IsRemote())
			CoopPlayer(C).SendScreen(Screen, ErrandIndex);
}

// Server: send a screen to this remote player. With it goes the serial of the host's state it
// shows (the client waits for that state), and a story screen the player did not ask for (all but
// the map) protects him from damage until he closes it (ServerScreenClosed): the world goes on
// while he cannot move.
function SendScreen(byte Screen, int ErrandIndex)
{
	local int Ticket;

	if (Screen != ScreenMap)
	{
		ScreenTicket++;
		Ticket = ScreenTicket;
		ScreenProtectUntil = Level.TimeSeconds + MaxScreenProtect;
	}
	ClientShowScreen(Screen, ErrandIndex, HostStateSerial(), Ticket);
}

// Server: the serial of the host's state as it is now.
function int HostStateSerial()
{
	local CoopGame G;

	G = CoopGame(Level.Game);
	if (G == None || G.StateInfo == None)
		return 0;
	G.StateInfo.ReadGameState();
	return G.StateInfo.Serial;
}

// Host: his own story screen; the protection ends when he leaves WaitScreen (PlayerTick).
function ProtectLocalScreen()
{
	if (!IsRemote() && Level.NetMode != NM_Client)
		ScreenProtectUntil = Level.TimeSeconds + MaxScreenProtect;
}

// Server: CoopGame.ReduceDamage.
function bool ScreenProtected()
{
	if (ScreenProtectUntil <= Level.TimeSeconds)
		return false;
	return IsRemote() || IsInState('WaitScreen');
}

// Server: the client has closed every screen up to Ticket.
function ServerScreenClosed(int Ticket)
{
	if (Ticket >= ScreenTicket && ScreenProtectUntil != 0)
	{
		log("P2Coop:"@PlayerReplicationInfo.PlayerName@"closed his screens, no longer protected");
		ScreenProtectUntil = 0;
	}
}

function ClientShowScreen(byte Screen, int ErrandIndex, int StateSerial, int Ticket)
{
	if (Ticket > ScreenTicketSeen)
		ScreenTicketSeen = Ticket;
	QueueScreen(Screen, ErrandIndex, StateSerial);
}

// Client: queue a screen. The same screen already waiting is not queued twice (a crossing out
// is the same when it is the same errand); a full queue drops the oldest.
function QueueScreen(byte Screen, int ErrandIndex, int StateSerial)
{
	local int i;

	for (i = 0; i < ScreenQueue.Length; i++)
		if (ScreenQueue[i].Screen == Screen && (Screen != ScreenCrossOut || ScreenQueue[i].Errand == ErrandIndex))
		{
			ScreenQueue[i].Serial = Max(ScreenQueue[i].Serial, StateSerial);
			ScreenQueue[i].StopWaitAt = Level.TimeSeconds + StateWait;
			return;
		}
	if (ScreenQueue.Length >= MaxQueuedScreens)
	{
		log("P2Coop: screen queue full, dropping screen"@ScreenQueue[0].Screen);
		ScreenQueue.Remove(0, 1);
	}
	i = ScreenQueue.Length;
	ScreenQueue.Length = i + 1;
	ScreenQueue[i].Screen = Screen;
	ScreenQueue[i].Errand = ErrandIndex;
	ScreenQueue[i].Serial = StateSerial;
	ScreenQueue[i].ShowAt = Level.TimeSeconds;
	ScreenQueue[i].StopWaitAt = Level.TimeSeconds + StateWait;
}

// Client: a CoopMapScreen or CoopNewsScreen is up.
function bool ClientScreenRunning()
{
	return (MyMapScreen != None && MyMapScreen.IsRunning()) || (MyNewsScreen != None && MyNewsScreen.IsRunning());
}

event PlayerTick(float DeltaTime)
{
	Super.PlayerTick(DeltaTime);
	// The host's own screen protection ends with his screen.
	if (ScreenProtectUntil != 0 && Level.NetMode != NM_Client && !IsRemote() && !IsInState('WaitScreen'))
		ScreenProtectUntil = 0;
	// A pawn given during the host's cutscene (a respawn, a join) restarts the client's controller
	// when it arrives, which can be after ClientCutsceneStart: go back to watching.
	if (bClientWatching && Level.NetMode == NM_Client && Pawn != None && !IsInState('CoopClientCutscene')
		&& !IsInState('Dead'))
	{
		log("P2Coop: client back to watching the host's cutscene after a restart");
		if (!IsInState('CoopClientScreen'))
			SetMyOldState();
		GotoState('CoopClientCutscene');
	}
	// WaitScreen's state code, which would leave the state when the screen ends, does not run
	// on a client. Not while another screen is still up.
	if (IsInState('CoopClientScreen') && !ClientScreenRunning())
	{
		if (MyOldState == '' || MyOldState == 'CoopClientScreen')
			MyOldState = 'PlayerWalking';
		GotoState(MyOldState);
	}
	if (ScreenQueue.Length > 0 && Level.TimeSeconds >= ScreenQueue[0].ShowAt && !IsInState('CoopClientCutscene'))
		ShowNextScreen();
	// Every forced screen is closed: the server can stop protecting this player.
	if (Level.NetMode == NM_Client && ScreenTicketSeen > ScreenTicketDone && ScreenQueue.Length == 0
		&& !IsInState('CoopClientScreen') && !ClientScreenRunning())
	{
		ScreenTicketDone = ScreenTicketSeen;
		ServerScreenClosed(ScreenTicketDone);
	}
}

// Client: show the first queued screen once the host's state it needs is here (or after
// StateWait), and once it can show (with another screen up or no pawn it tries again later).
function ShowNextScreen()
{
	local CoopShadowGame G;
	local byte Screen;
	local int Errand;

	if (Level.TimeSeconds < ScreenQueue[0].StopWaitAt
		&& class'CoopReplicationInfo'.static.AppliedSerialFor(self) < ScreenQueue[0].Serial)
		return;
	ClientSetupScreens();
	G = class'CoopReplicationInfo'.static.ShadowFor(self);
	if (G == None || G.TheGameState == None || Pawn == None || Pawn.Health <= 0 || ClientScreenRunning()
		|| MyMapScreen == None || MyNewsScreen == None)
	{
		if (!ScreenQueue[0].bLogged)
			log("P2Coop: screen"@ScreenQueue[0].Screen@"waits, state"@G@"pawn"@Pawn@"screen up"@ClientScreenRunning());
		ScreenQueue[0].bLogged = true;
		ScreenQueue[0].ShowAt = Level.TimeSeconds + ScreenRetry;
		return;
	}
	Screen = ScreenQueue[0].Screen;
	Errand = ScreenQueue[0].Errand;
	ScreenQueue.Remove(0, 1);
	ShowClientScreen(G, Screen, Errand);
}

function ShowClientScreen(CoopShadowGame G, byte Screen, int ErrandIndex)
{
	if (Screen == ScreenNews)
	{
		MyNewsScreen.Show(G.TheGameState.bIsApocalypse);
		CurrentScreen = MyNewsScreen;
	}
	else
	{
		switch (Screen)
		{
			case ScreenErrands:
				MyMapScreen.ShowErrands();
				break;
			case ScreenHaters:
				MyMapScreen.ShowHaters();
				break;
			case ScreenCrossOut:
				MyMapScreen.ShowCrossOut(ErrandIndex);
				break;
			default:
				MyMapScreen.Show();
		}
		CurrentScreen = MyMapScreen;
	}
	log("P2Coop: client shows screen"@Screen@CurrentScreen);
	if (!IsInState('CoopClientScreen'))
	{
		SetMyOldState();
		GotoState('CoopClientScreen');
	}
}

// Client: the stock screens are made by SetupScreens on the server's Possess, which a client's
// controller never runs. The screens live in the viewport and outlast the level.
function ClientSetupScreens()
{
	local int i;

	if (Viewport(Player) == None)
		return;
	for (i = 0; i < Player.LocalInteractions.Length; i++)
	{
		if (CoopMapScreen(Player.LocalInteractions[i]) != None)
			MyMapScreen = CoopMapScreen(Player.LocalInteractions[i]);
		if (CoopNewsScreen(Player.LocalInteractions[i]) != None)
			MyNewsScreen = CoopNewsScreen(Player.LocalInteractions[i]);
	}
	if (MyMapScreen == None)
		MyMapScreen = MapScreen(Player.InteractionMaster.AddInteraction("P2Coop.CoopMapScreen", Player));
	if (MyNewsScreen == None)
		MyNewsScreen = NewsScreen(Player.InteractionMaster.AddInteraction("P2Coop.CoopNewsScreen", Player));
}

// Client: end the screens before the level goes (P2Screen.PreTravel).
event PreClientTravel()
{
	Super.PreClientTravel();
	if (Level.NetMode != NM_Client)
		return;
	if (MyMapScreen != None)
		MyMapScreen.PreTravel();
	if (MyNewsScreen != None)
		MyNewsScreen.PreTravel();
}

function DisplayStats(optional String URL)
{
	if (IsRemote())
		RemoteSendOn(URL);
	else
		Super.DisplayStats(URL);
}

// The load screens live in the local viewport too (see RemoteSendOn).
function DisplayLoad(DayBase day, String URL)
{
	if (IsRemote())
		RemoteSendOn(URL);
	else
		Super.DisplayLoad(day, URL);
}

function DisplayLoadForced(Texture LoadTex, String URL)
{
	if (IsRemote())
		RemoteSendOn(URL);
	else
		Super.DisplayLoadForced(LoadTex, URL);
}

function DisplayLoadForcedNoFade(Texture LoadTex, String URL)
{
	if (IsRemote())
		RemoteSendOn(URL);
	else
		Super.DisplayLoadForcedNoFade(LoadTex, URL);
}

// Server: a remote player's controller goes (his game closed or his connection dropped).
simulated event Destroyed()
{
	if (Role == ROLE_Authority && Viewport(Player) == None && CoopGame(Level.Game) != None)
		CoopGame(Level.Game).PlayerLeaving(self);
	Super.Destroyed();
}

// Stock GameInfo.PostLogin logs every player in as admin ("adminlogin"); a listen server's own
// player always passes. The Admin object that makes is "within PlayerController", and a later map
// change sometimes crashed in garbage collection destroying an old one ("Admin None.AdminN" in
// UObject::Destroy under ServerTravel). Co-op has no use for admin commands, so nobody
// logs in and no Admin object exists. (AdminManager is private to PlayerController.)
exec function AdminLogin(string CmdLine);

// Ragdolls are simulated by the host only (P2MoCapPawn.GetKarmaSkeleton asks the local player
// for a skeleton); CoopRagdollSync sends the host's ragdoll to the clients, so a body lies the
// same for everyone, where a client's own Karma would put it somewhere else. The host hands out
// the skeleton one frame late, from CoopRagdollSync.StartRagdoll, which first brings the body's
// skeleton up to date: a ragdoll started on a body the host has not drawn, as when a client kills
// someone out of the host's view, collapses and falls through the world.
// The mini skeleton (Gary) gets none: creating its Karma skeleton faults in the engine (in the
// stock PlayDying too), which then deletes the body. It dies with its animation, synced as well.
simulated function KarmaParamsSkel GetNewRagdollSkel(FPSPawn NewPawn, name skelname)
{
	local KarmaParamsSkel Skel;
	local CoopGame Game;

	if (Level.NetMode == NM_Client)
		return None;
	Game = CoopGame(Level.Game);
	if (Game == None || Level.NetMode != NM_ListenServer)
		return Super.GetNewRagdollSkel(NewPawn, skelname);
	if (skelname == 'Avg_Mini_Skel')
	{
		Game.SyncRagdoll(NewPawn, false);
		return None;
	}
	if (!Game.bRagdollNow)
	{
		Game.SyncRagdoll(NewPawn, true);
		return None;
	}
	Skel = Super.GetNewRagdollSkel(NewPawn, skelname);
	if (Skel != None)
		Game.SyncRagdoll(NewPawn, false);
	return Skel;
}

// The server gave this player a unique name (CoopGame.Login). Travel items are matched by name,
// so the next connect after a map change must use it too.
function ClientSetCoopName(string NewName)
{
	log("P2Coop: the server calls this player"@NewName);
	UpdateURL("Name", NewName, false);
}

// The test hooks work only while the server runs a test (bTestMode, CoopGame.PostLogin), and the
// test's console commands only from a short list: in a real game no server may run console
// commands (settings, "open", the relay's "P2COOP LINK") on a player's machine.
function bool TestAllowed(string What)
{
	if (bTestMode)
		return true;
	log("P2Coop: ignored"@What@"from the server, no test is running");
	return false;
}

// Server: a test report from a client counts only while a test runs here.
function bool ServerTestRunning()
{
	return CoopGame(Level.Game) != None && CoopGame(Level.Game).Test != None;
}

// "QuickUseMap", "SwitchWeapon <n>", "NextWeapon", "PrevWeapon", "GetWeapon Inventory.<class>".
static function bool TestCommandAllowed(string Cmd)
{
	local string Word, Arg;
	local int i;

	if (InStr(Cmd, "|") >= 0 || InStr(Cmd, ";") >= 0 || InStr(Cmd, "\"") >= 0)
		return false;
	i = InStr(Cmd, " ");
	if (i < 0)
		Word = Cmd;
	else
	{
		Word = Left(Cmd, i);
		Arg = Mid(Cmd, i + 1);
	}
	if (InStr(Arg, " ") >= 0)
		return false;
	Word = Caps(Word);
	if (Word == "QUICKUSEMAP" || Word == "NEXTWEAPON" || Word == "PREVWEAPON")
		return Arg == "";
	if (Word == "SWITCHWEAPON")
		return Arg != "" && string(int(Arg)) == Arg;
	if (Word == "GETWEAPON")
		return Caps(Left(Arg, 10)) == "INVENTORY." && Len(Arg) > 10;
	return false;
}

// Runs a console command (from TestCommandAllowed) on this player's own machine.
function ClientTestCommand(string Cmd)
{
	if (!TestAllowed("ClientTestCommand"))
		return;
	if (!TestCommandAllowed(Cmd))
	{
		log("P2Coop: ignored test command"@Cmd@"(not one a test may run)");
		return;
	}
	log("P2CoopTest: client runs"@Cmd);
	ConsoleCommand(Cmd);
	LogWeapons();
}

// The exec function the fire key ends in (Weapon.Fire -> ServerFire). ConsoleCommand("Fire")
// does not get there: "Fire" is also an input alias ("Button bFire | Fire").
function ClientTestFire()
{
	if (!TestAllowed("ClientTestFire"))
		return;
	log("P2CoopTest: client fires");
	Fire(0);
	LogWeapons();
}

function LogWeapons()
{
	local Inventory Inv;

	if (Pawn == None)
		return;
	if (Pawn.Weapon == None)
		log("P2CoopTest: client weapon None pending"@Pawn.PendingWeapon);
	else
		log("P2CoopTest: client weapon"@Pawn.Weapon@"state"@Pawn.Weapon.GetStateName()@"pending"@Pawn.PendingWeapon);
	for (Inv = Pawn.Inventory; Inv != None; Inv = Inv.Inventory)
		if (Weapon(Inv) != None)
			log("P2CoopTest:   has"@Inv@"ammo"@Weapon(Inv).AmmoType@Weapon(Inv).AmmoType.AmmoAmount
				@"HasAmmo="$Weapon(Inv).HasAmmo());
}

// Presses "forward" with the given strength for some seconds.
function ClientTestDrive(float Forward, float Seconds)
{
	if (!TestAllowed("ClientTestDrive"))
		return;
	TestForward = Forward;
	TestDriveUntil = Level.TimeSeconds + Seconds;
}

function ClientTestAim(rotator ViewRot)
{
	if (!TestAllowed("ClientTestAim"))
		return;
	SetRotation(ViewRot);
}

// Reports what this machine sees: the named player's pawn and the NPC pawns.
function ClientTestLook(string LeaderName)
{
	local Pawn P;
	local int NPCs;
	local bool bSawLeader;
	local vector LeaderLoc;

	if (!TestAllowed("ClientTestLook"))
		return;
	foreach DynamicActors(class'Pawn', P)
	{
		if (P.Health <= 0 || P == Pawn)
			continue;
		if (P.PlayerReplicationInfo != None && P.PlayerReplicationInfo.PlayerName == LeaderName)
		{
			bSawLeader = true;
			LeaderLoc = P.Location;
		}
		else if (P.PlayerReplicationInfo == None)
			NPCs++;
	}
	ServerTestSaw(bSawLeader, LeaderLoc, NPCs, Pawn != None, Pawn.Location);
}

function ServerTestSaw(bool bSawLeader, vector LeaderLoc, int NPCs, bool bHavePawn, vector MyLoc)
{
	local CoopTestBase T;

	if (!ServerTestRunning())
		return;
	log("P2CoopTest:"@PlayerReplicationInfo.PlayerName@"sees leader="$bSawLeader@"at"@LeaderLoc
		@"npcs="$NPCs@"own pawn="$bHavePawn@"at"@MyLoc);
	foreach DynamicActors(class'CoopTestBase', T)
		T.ClientSaw(self, bSawLeader, LeaderLoc, NPCs, MyLoc);
}

// Reports this machine's copy of the host's state, the HUD's wanted meter and open screens.
function ClientTestScreens()
{
	local CoopShadowGame G;
	local string Open;
	local float HUDWanted;

	if (!TestAllowed("ClientTestScreens"))
		return;
	G = class'CoopReplicationInfo'.static.ShadowFor(self);
	if (MyMapScreen != None && MyMapScreen.IsRunning())
		Open = Open $ "map ";
	if (MyNewsScreen != None && MyNewsScreen.IsRunning())
		Open = Open $ "news ";
	if (CoopHUD(myHUD) != None)
		HUDWanted = CoopHUD(myHUD).LastWanted;
	if (G == None || G.TheGameState == None)
		ServerTestScreens(false, -1, 0, "", 0, 0, HUDWanted, Open, string(GetStateName()));
	else
		ServerTestScreens(true, G.TheGameState.CurrentDay, G.TheGameState.ErrandsCompletedToday,
			class'CoopReplicationInfo'.static.ErrandList(G.TheGameState.CompletedErrands),
			G.TheGameState.CurrentHaters.Length, G.TheGameState.CopsWantPlayer(), HUDWanted, Open,
			string(GetStateName()));
}

// Presses the "done" key on the open screens (the first press hurries the map along), or on the map only.
function ClientTestEndScreens(optional bool bMapOnly)
{
	if (!TestAllowed("ClientTestEndScreens"))
		return;
	if (MyMapScreen != None && MyMapScreen.IsRunning())
		MyMapScreen.bPlayerWantsToEnd = true;
	if (!bMapOnly && MyNewsScreen != None && MyNewsScreen.IsRunning())
		MyNewsScreen.bPlayerWantsToEnd = true;
}

function ServerTestScreens(bool bShadow, int Day, int DoneToday, string Completed, int Haters,
	float Wanted, float HUDWanted, string Open, string StateName)
{
	local CoopTestBase T;

	if (!ServerTestRunning())
		return;
	log("P2CoopTest:"@PlayerReplicationInfo.PlayerName@"state copy="$bShadow@"day="$Day
		@"done today="$DoneToday@"completed=["$Completed$"] haters="$Haters@"wanted="$Wanted
		@"hud wanted="$HUDWanted@"open=["$Open$"] state="$StateName);
	foreach DynamicActors(class'CoopTestBase', T)
		T.ClientScreens(self, bShadow, Day, DoneToday, Completed, Haters, Wanted, HUDWanted, Open, StateName);
}

// Reports, through the camera report, where this machine has the NPC nearest to Near (the test kills it first).
function ClientTestCorpse(vector Near)
{
	local Pawn P, Best;

	if (!TestAllowed("ClientTestCorpse"))
		return;
	foreach DynamicActors(class'Pawn', P)
		if (P.PlayerReplicationInfo == None	// a client does not get an NPC's health or state
			&& (Best == None || VSize(P.Location - Near) < VSize(Best.Location - Near)))
			Best = P;
	if (Best == None)
		ServerTestCamera(vect(0,0,0), "no-corpse");
	else
		ServerTestCamera(Best.Location, "corpse" @ Best @ "role" @ Best.Role @ "physics" @ Best.Physics @ "anim" @ Best.bPhysicsAnimUpdate
			@ "speed" @ int(VSize(Best.Velocity)));
}

// Reports the bone positions of the synced body nearest to Near (CoopTestRagdoll).
function ClientTestBones(vector Near)
{
	local CoopRagdollSync S, Best;

	if (!TestAllowed("ClientTestBones"))
		return;
	foreach DynamicActors(class'CoopRagdollSync', S)
		if (S.Corpse != None && (Best == None || VSize(S.Corpse.Location - Near) < VSize(Best.Corpse.Location - Near)))
			Best = S;
	if (Best == None)
		ServerTestBones("none");
	else
		ServerTestBones(class'CoopTestRagdoll'.static.BonePositions(Best.Corpse, Best.Severed));
}

function ServerTestBones(string Bones)
{
	local CoopTestRagdoll T;

	if (!ServerTestRunning())
		return;
	log("P2CoopTest:"@PlayerReplicationInfo.PlayerName@"bones"@Bones);
	foreach DynamicActors(class'CoopTestRagdoll', T)
		T.ClientBonesReport(self, Bones);
}

// Reports where this machine's camera is.
function ClientTestCamera()
{
	local Actor ViewActor;
	local vector Loc;
	local rotator Rot;

	if (!TestAllowed("ClientTestCamera"))
		return;
	PlayerCalcView(ViewActor, Loc, Rot);
	ServerTestCamera(Loc, string(GetStateName()));
}

function ServerTestCamera(vector Loc, string StateName)
{
	local CoopTestBase T;

	if (!ServerTestRunning())
		return;
	log("P2CoopTest:"@PlayerReplicationInfo.PlayerName@"camera at"@Loc@"state="$StateName);
	foreach DynamicActors(class'CoopTestBase', T)
		T.ClientCamera(self, Loc, StateName);
}

state Dead
{
	function BeginState()
	{
		Super.BeginState();
		// Not while the level goes away for a map change (pawns die with it, nobody respawns there).
		if (Role == ROLE_Authority && CoopGame(Level.Game) != None && Level.NextURL == "")
			CoopGame(Level.Game).PlayerDied(self);
	}

	// Stock: load the last save for everyone. While a teammate lives this player respawns instead.
	exec function GameOverRestart(optional float F)
	{
		if (CoopGame(Level.Game) != None && CoopGame(Level.Game).LivingPlayerPawn(self) != None)
			return;
		Super.GameOverRestart(F);
	}

	// Fire (or jump) while dead. Stock respawns at once at the map's start; in co-op the
	// respawn comes after the delay (CoopRespawner), and the press can only bring it on once it is
	// due. When everybody is dead, the leader's press is the game over (load the last save) and
	// a client's does nothing.
	function ServerReStartPlayer()
	{
		local CoopGame G;

		if (Level.NetMode == NM_Client)
			return;
		G = CoopGame(Level.Game);
		if (G == None)
		{
			Super.ServerReStartPlayer();
			return;
		}
		if (G.LivingPlayerPawn(self) == None)
		{
			if (G.Leader() == self)
				GameOverRestart();
			return;
		}
		if (bRespawning && Level.TimeSeconds >= RespawnTime)
			G.RestartPlayer(self);
	}
}

// Cutscenes (CoopCutscene): the client looks through the host's camera until the scene ends.
function ClientCutsceneStart(bool bCinematic, vector Loc, rotator Rot)
{
	log("P2Coop: client watches the host's cutscene");
	CutLoc = Loc;
	CutRot = Rot;
	CutPrevLoc = Loc;
	CutPrevRot = Rot;
	CutTime = Level.TimeSeconds;
	bClientWatching = true;
	if (myHUD != None)
	{
		myHUD.bHideHUD = true;
		myHUD.bCinematicView = bCinematic;
	}
	if (!IsInState('CoopClientCutscene'))
	{
		if (!IsInState('CoopClientScreen'))
			SetMyOldState();
		GotoState('CoopClientCutscene');
	}
}

function ClientCutsceneView(vector Loc, rotator Rot)
{
	CutPrevLoc = CutLoc;
	CutPrevRot = CutRot;
	CutLoc = Loc;
	CutRot = Rot;
	CutTime = Level.TimeSeconds;
}

function ClientCutsceneEnd()
{
	log("P2Coop: client's cutscene ended");
	bClientWatching = false;
	if (myHUD != None)
	{
		myHUD.bHideHUD = false;
		myHUD.bCinematicView = false;
	}
	if (IsInState('CoopClientCutscene'))
	{
		if (MyOldState == '' || MyOldState == 'CoopClientCutscene' || MyOldState == 'CoopClientScreen')
			MyOldState = 'PlayerWalking';
		GotoState(MyOldState);
	}
}

// Server: what a remote player is sent is chosen from his view; during a cutscene that is the
// host's camera.
event PlayerCalcView(out actor ViewActor, out vector CameraLocation, out rotator CameraRotation)
{
	if (bInCutscene && IsRemote() && CoopGame(Level.Game) != None && CoopGame(Level.Game).Cutscene != None)
	{
		ViewActor = self;
		CameraLocation = CoopGame(Level.Game).Cutscene.CamLoc;
		CameraRotation = CoopGame(Level.Game).Cutscene.CamRot;
		return;
	}
	Super.PlayerCalcView(ViewActor, CameraLocation, CameraRotation);
}

state CoopClientCutscene
{
	ignores Fire, Use, Jump, AltFire, UseZipper, RequestMap, QuickUseMap, RequestNews, Suicide,
		DoKick, ThrowWeapon, ThrowPowerup, PrevInvItem, NextInvItem, SwitchWeapon, SwitchToHands,
		ToggleToHands, PressingFire, PressingAltFire;

	function BeginState()
	{
		if (Pawn != None)
			Pawn.Acceleration = vect(0,0,0);
	}

	function PlayerMove(float DeltaTime);

	// Between samples, move from the previous one to the last one.
	event PlayerCalcView(out actor ViewActor, out vector CameraLocation, out rotator CameraRotation)
	{
		local float Alpha;

		Alpha = FClamp((Level.TimeSeconds - CutTime) / CutSendInterval, 0, 1);
		ViewActor = self;
		CameraLocation = CutPrevLoc + (CutLoc - CutPrevLoc) * Alpha;
		CameraRotation = CutPrevRot + Normalize(CutRot - CutPrevRot) * Alpha;
	}
}

// Client: a screen is up (stock WaitScreen, which asks Level.Game to reset the game speed).
state CoopClientScreen extends WaitScreen
{
	function BeginState()
	{
		if (Pawn != None)
			Pawn.Acceleration = vect(0,0,0);
	}

	function EndState()
	{
		CurrentScreen = None;
	}
}

state PlayerWalking
{
	function PlayerMove(float DeltaTime)
	{
		if (TestDriveUntil > Level.TimeSeconds)
			aForward = TestForward;
		Super.PlayerMove(DeltaTime);
	}
}
