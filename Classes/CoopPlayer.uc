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

const ScreenMap = 0;		// ClientShowScreen
const ScreenErrands = 1;
const ScreenHaters = 2;
const ScreenCrossOut = 3;
const ScreenNews = 4;
const ScreenDelay = 0.75;
const CutSendInterval = 0.05;	// CoopCutscene.SendInterval
var byte PendingScreen;		// client: screen + 1 to show at PendingScreenTime
var int PendingErrand;
var float PendingScreenTime;

var bool bInCutscene;		// server: CoopCutscene has started the host's cutscene here
var vector CutLoc, CutPrevLoc;	// client: the host's camera, last two samples
var rotator CutRot, CutPrevRot;
var float CutTime;

replication
{
	reliable if (Role == ROLE_Authority)
		ClientSetCoopName, ClientShowScreen, ClientCutsceneStart, ClientCutsceneEnd;
	unreliable if (Role == ROLE_Authority)
		ClientCutsceneView;
	reliable if (Role == ROLE_Authority)
		ClientTestCommand, ClientTestFire, ClientTestDrive, ClientTestAim, ClientTestLook,
		ClientTestScreens, ClientTestEndScreens, ClientTestCamera, ClientTestCorpse;
	reliable if (Role < ROLE_Authority)
		ServerTestSaw, ServerTestScreens, ServerTestCamera;
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
		Super.DisplayMapCrossOut(ErrandIndex, CompletionTrigger_In, SendToURL);
		return;
	}
	ClientShowScreen(ScreenCrossOut, ErrandIndex);
	if (CompletionTrigger_In != 'None')
		foreach AllActors(class'Actor', A, CompletionTrigger_In)
			A.Trigger(None, Pawn);
	if (InterestPawn != None && InterestPawn.Health > 0 && LambController(InterestPawn.Controller) != None)
		LambController(InterestPawn.Controller).DudeErrandComplete();
	if (CoopGame(Level.Game) != None)
	{
		CoopGame(Level.Game).AnnounceErrand(self, ErrandIndex);
		if (SendToURL != "")
			CoopGame(Level.Game).SendPlayerTo(self, SendToURL);
	}
}

// Remote players see the map and the newspaper on their own machine: the server sends the
// request (ClientShowScreen) and the client shows its CoopMapScreen/CoopNewsScreen, which read
// the host's state from CoopReplicationInfo. The story's map and newspaper moments come to the
// host's player (map scripts, the start of a day), so the host passes those to everyone.
function RequestMap()
{
	if (IsRemote())
		ClientShowScreen(ScreenMap, 0);
	else if (Level.NetMode == NM_Client)
		QueueScreen(ScreenMap, 0, 0);
	else
		Super.RequestMap();
}

function RequestNews()
{
	if (IsRemote())
		ClientShowScreen(ScreenNews, 0);
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
		ClientShowScreen(ScreenMap, 0);
	else
		Super.DisplayMap();
}

function DisplayMapErrands(optional String SendToURL, optional bool bWantFancyFadeIn)
{
	if (IsRemote())
	{
		ClientShowScreen(ScreenErrands, 0);
		if (SendToURL != "" && CoopGame(Level.Game) != None)
			CoopGame(Level.Game).SendPlayerTo(self, SendToURL);
		return;
	}
	Super.DisplayMapErrands(SendToURL, bWantFancyFadeIn);
	ShowEveryone(ScreenErrands);
}

function DisplayMapHaters(optional String SendToURL)
{
	if (IsRemote())
	{
		ClientShowScreen(ScreenHaters, 0);
		if (SendToURL != "" && CoopGame(Level.Game) != None)
			CoopGame(Level.Game).SendPlayerTo(self, SendToURL);
		return;
	}
	Super.DisplayMapHaters(SendToURL);
	ShowEveryone(ScreenHaters);
}

function DisplayNews()
{
	if (IsRemote())
	{
		ClientShowScreen(ScreenNews, 0);
		return;
	}
	Super.DisplayNews();
	ShowEveryone(ScreenNews);
}

// Host: show a story screen to the remote players too.
function ShowEveryone(byte Screen)
{
	local Controller C;

	if (Level.NetMode == NM_Client)
		return;
	for (C = Level.ControllerList; C != None; C = C.NextController)
		if (CoopPlayer(C) != None && CoopPlayer(C).IsRemote())
			CoopPlayer(C).ClientShowScreen(Screen, 0);
}

// Client: show the screen a little later, so the host's state that came with it (an errand just
// done, a new day) has arrived in CoopReplicationInfo first.
function ClientShowScreen(byte Screen, int ErrandIndex)
{
	QueueScreen(Screen, ErrandIndex, ScreenDelay);
}

function QueueScreen(byte Screen, int ErrandIndex, float Delay)
{
	PendingScreen = Screen + 1;
	PendingErrand = ErrandIndex;
	PendingScreenTime = Level.TimeSeconds + Delay;
}

event PlayerTick(float DeltaTime)
{
	Super.PlayerTick(DeltaTime);
	if (PendingScreen > 0 && Level.TimeSeconds >= PendingScreenTime && !IsInState('CoopClientCutscene'))
	{
		ShowClientScreen(PendingScreen - 1, PendingErrand);
		PendingScreen = 0;
	}
	// WaitScreen's state code, which would leave the state when the screen ends, does not run
	// on a client.
	if (IsInState('CoopClientScreen') && (CurrentScreen == None || !CurrentScreen.IsRunning()))
	{
		if (MyOldState == '' || MyOldState == 'CoopClientScreen')
			MyOldState = 'PlayerWalking';
		GotoState(MyOldState);
	}
}

function ShowClientScreen(byte Screen, int ErrandIndex)
{
	local CoopShadowGame G;

	G = class'CoopReplicationInfo'.static.ShadowFor(self);
	if (G == None || G.TheGameState == None || Pawn == None || Pawn.Health <= 0)
	{
		log("P2Coop: no screen"@Screen@"now, state"@G@"pawn"@Pawn);
		return;
	}
	ClientSetupScreens();
	if (Screen == ScreenNews)
	{
		if (MyNewsScreen == None || MyNewsScreen.IsRunning())
			return;
		MyNewsScreen.Show(G.TheGameState.bIsApocalypse);
		CurrentScreen = MyNewsScreen;
	}
	else
	{
		if (MyMapScreen == None || MyMapScreen.IsRunning())
			return;
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
	if (!IsRemote())
		Super.DisplayStats(URL);
}

// Stock GameInfo.PostLogin logs every player in as admin ("adminlogin"); a listen server's own
// player always passes. The Admin object that makes is "within PlayerController", and a later map
// change sometimes crashed in garbage collection destroying an old one ("Admin None.AdminN" in
// UObject::Destroy under ServerTravel). Co-op has no use for admin commands, so nobody
// logs in and no Admin object exists. (AdminManager is private to PlayerController.)
exec function AdminLogin(string CmdLine);

// No ragdolls in co-op. A ragdoll is Karma physics run by each machine on its own, so the same
// body ends up in different places for the host and the clients. Without a skeleton the pawn
// dies with its death animation where it stood, the same everywhere (as in SP when every
// ragdoll skeleton is taken). P2MoCapPawn.GetKarmaSkeleton asks the local player for one.
simulated function KarmaParamsSkel GetNewRagdollSkel(FPSPawn NewPawn, name skelname)
{
	return None;
}

// The server gave this player a unique name (CoopGame.Login). Travel items are matched by name,
// so the next connect after a map change must use it too.
function ClientSetCoopName(string NewName)
{
	log("P2Coop: the server calls this player"@NewName);
	UpdateURL("Name", NewName, false);
}

// Runs a console command on this player's own machine.
function ClientTestCommand(string Cmd)
{
	log("P2CoopTest: client runs"@Cmd);
	ConsoleCommand(Cmd);
	LogWeapons();
}

// The exec function the fire key ends in (Weapon.Fire -> ServerFire). ConsoleCommand("Fire")
// does not get there: "Fire" is also an input alias ("Button bFire | Fire").
function ClientTestFire()
{
	log("P2CoopTest: client fires");
	Fire(0);
	LogWeapons();
}

function LogWeapons()
{
	local Inventory Inv;

	if (Pawn == None)
		return;
	log("P2CoopTest: client weapon"@Pawn.Weapon@"state"@Pawn.Weapon.GetStateName()@"pending"@Pawn.PendingWeapon);
	for (Inv = Pawn.Inventory; Inv != None; Inv = Inv.Inventory)
		if (Weapon(Inv) != None)
			log("P2CoopTest:   has"@Inv@"ammo"@Weapon(Inv).AmmoType@Weapon(Inv).AmmoType.AmmoAmount
				@"HasAmmo="$Weapon(Inv).HasAmmo());
}

// Presses "forward" with the given strength for some seconds.
function ClientTestDrive(float Forward, float Seconds)
{
	TestForward = Forward;
	TestDriveUntil = Level.TimeSeconds + Seconds;
}

function ClientTestAim(rotator ViewRot)
{
	SetRotation(ViewRot);
}

// Reports what this machine sees: the named player's pawn and the NPC pawns.
function ClientTestLook(string LeaderName)
{
	local Pawn P;
	local int NPCs;
	local bool bSawLeader;
	local vector LeaderLoc;

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

// Presses the "done" key on the open screens (the first press hurries the map along).
function ClientTestEndScreens()
{
	if (MyMapScreen != None && MyMapScreen.IsRunning())
		MyMapScreen.bPlayerWantsToEnd = true;
	if (MyNewsScreen != None && MyNewsScreen.IsRunning())
		MyNewsScreen.bPlayerWantsToEnd = true;
}

function ServerTestScreens(bool bShadow, int Day, int DoneToday, string Completed, int Haters,
	float Wanted, float HUDWanted, string Open, string StateName)
{
	local CoopTestBase T;

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

	foreach DynamicActors(class'Pawn', P)
		if (P.PlayerReplicationInfo == None	// a client does not get an NPC's health or state
			&& (Best == None || VSize(P.Location - Near) < VSize(Best.Location - Near)))
			Best = P;
	if (Best == None)
		ServerTestCamera(vect(0,0,0), "no-corpse");
	else
		ServerTestCamera(Best.Location, "corpse" @ Best @ "physics" @ Best.Physics @ "anim" @ Best.bPhysicsAnimUpdate);
}

// Reports where this machine's camera is.
function ClientTestCamera()
{
	local Actor ViewActor;
	local vector Loc;
	local rotator Rot;

	PlayerCalcView(ViewActor, Loc, Rot);
	ServerTestCamera(Loc, string(GetStateName()));
}

function ServerTestCamera(vector Loc, string StateName)
{
	local CoopTestBase T;

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
