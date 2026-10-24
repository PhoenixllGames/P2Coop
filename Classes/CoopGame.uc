//=============================================================================
// CoopGame: co-op game type for the POSTAL 2 week.
//
// Subclasses the single-player game info on purpose: AI and world code casts
// Level.Game to P2GameInfoSingle in hundreds of places.
// The leader is the host's own player: map scripts and GetPlayer() act on it.
//=============================================================================
class CoopGame extends AWPGameInfo;

var CoopProbe Probe;
var CoopCutscene Cutscene;	// remote players watch the host's cutscenes
var CoopJailer Jailer;		// jail: the remote players' things go to the evidence room too
var CoopReplicationInfo StateInfo;	// the host's GameState for the clients' map, newspaper and HUD
var CoopTestBase Test;	// ?CoopTest=<name>
var bool bRagdollNow;	// CoopRagdollSync.StartRagdoll is asking for a skeleton (CoopPlayer.GetNewRagdollSkel)
var string TravelOptions;	// appended to the next ServerTravel URL (tests carry their state)

const TravelSettleTime = 8.0;	// see TravelMustWait
const TravelMaxWait = 15.0;
const LoginTimeout = 20.0;	// a PreLogin without its PostLogin by then has failed
const SceneMaxWait = 120.0;	// see SendPlayerTo
var string PendingTravelURL;
var bool bPendingTravelItems;
var float PendingTravelSince;
var GameState TravelGameState;	// the GameState in the leader's pawn while the ServerTravel waits
var CoopTravelWaiter TravelWaiter;
// A level change that waits before the stock SendPlayerTo runs (see SendPlayerTo): while it
// waits, the GameState stays the game's own and the level runs as before.
var string PendingSendURL;
var bool bPendingSendPawnless;
var PlayerController PendingSendFrom;
var float PendingSendSince;
var bool bSendRetry;		// inside RetryPendingSend
var bool bInStockSendPlayerTo;	// inside the stock SendPlayerTo (CoopPlayer's remote screens)
var int PendingLogins;		// PreLogins whose PostLogin has not come yet
var float LastPreLoginTime;
// Remote players who carried their things through the last ServerTravel (class defaults, so the
// next level's game info sees them). The engine gives a returning traveller his items right after
// PostLogin; a starting kit given in PostLogin as well doubles them, and the engine then deletes
// the doubles while weapons still point at them (a broken weapon state, no control).
var array<string> Travellers;
var bool bLoggingIn;		// inside PostLogin
const KitCheckDelay = 2.0;	// a traveller without items by then gets the kit after all

const DefaultRespawnDelay = 10.0;	// see PlayerDied
var CoopRespawner Respawner;

var string SavedMapName;	// map of the last save (saved with this actor, see PostLoadGame)
var bool bOnSaveLevel;		// this level is a loaded save (PostLoadGame)
// Inventories of the other players' saved pawns, carried from the save level to the map in the
// class defaults: "Name|Class=amount|Class=amount...". Given back when the player rejoins.
var array<string> CarriedInventories;

event PostLogin(PlayerController NewPlayer, string Options)
{
	local bool bHadPawn;

	bHadPawn = NewPlayer.Pawn != None;	// a saved controller handed back by GameInfo.Login
	if (NetConnection(NewPlayer.Player) != None && PendingLogins > 0)
		PendingLogins--;
	bLoggingIn = true;
	Super.PostLogin(NewPlayer, Options);
	bLoggingIn = false;
	if (CoopPlayer(NewPlayer) != None)
		CoopPlayer(NewPlayer).JoinTime = Level.TimeSeconds;

	if (Probe == None)
		Probe = Spawn(class'CoopProbe');
	if (Cutscene == None)
		Cutscene = Spawn(class'CoopCutscene');
	if (StateInfo == None)
		StateInfo = Spawn(class'CoopReplicationInfo');
	if (Test == None)
		Test = SpawnTest(URLOption("CoopTest"));
	// The test hooks of CoopPlayer work on the client only while a test runs.
	if (CoopPlayer(NewPlayer) != None)
		CoopPlayer(NewPlayer).bTestMode = Test != None;
	Probe.LogControllers("PostLogin before reorder");
	MakeHostFirst();
	Probe.LogControllers("PostLogin after reorder");
	if (NetConnection(NewPlayer.Player) != None)
	{
		// After a load, GameInfo.Login hands a returning player his saved controller and pawn
		// without possessing it again, so the client is never told which pawn is his.
		if (bHadPawn && NewPlayer.Pawn != None && NewPlayer.Pawn.Health > 0)
		{
			log("P2Coop:"@NewPlayer.PlayerReplicationInfo.PlayerName@"got his saved pawn back"@NewPlayer.Pawn);
			NewPlayer.Possess(NewPlayer.Pawn);
		}
		// The client reconnects after each travel with its own URL: give it the name it got here.
		if (CoopPlayer(NewPlayer) != None && NewPlayer.PlayerReplicationInfo.PlayerName != ParseOption(Options, "Name"))
			CoopPlayer(NewPlayer).ClientSetCoopName(NewPlayer.PlayerReplicationInfo.PlayerName);
		if (Test != None)
			Test.RemoteJoined(NewPlayer);
		else
			Probe.RemoteJoined(NewPlayer);
	}
	else
		Probe.LocalLoggedIn();
}

// The engine carries each player's pawn and items to the next map under the player's name, and
// finds them again by the name he logs in with there. So names must be stable and unique:
// - the leader (the first login of a level, the host's own player) is always the SP default
//   name, as P2GameInfoSingle.InitGame makes it after the first map (otherwise the first travel
//   exports "Host" and imports "Player", and the leader arrives with nothing);
// - everyone else gets a unique name here and keeps it (PostLogin -> ClientSetCoopName).
event PlayerController Login(string Portal, string Options, out string Error)
{
	local string Wanted, Name;

	Wanted = ParseOption(Options, "Name");
	if (Leader() == None)
		Name = class'GameInfo'.Default.DefaultPlayerName;
	else
		Name = UniqueName(Wanted);
	if (Name != Wanted)
	{
		log("P2Coop: login name"@Wanted@"->"@Name);
		Options = SetURLOption(Options, "Name", Name);
	}
	return Super.Login(Portal, Options, Error);
}

// Wanted, or Wanted plus a number, so that no other player has it and it is not the leader's.
function string UniqueName(string Wanted)
{
	local string Name;
	local int i;

	if (Wanted == "")
		Wanted = class'GameInfo'.Default.DefaultPlayerName;
	Name = Wanted;
	for (i = 2; i < 64 && NameTaken(Name); i++)
		Name = Wanted $ i;
	return Name;
}

// Only connected players count: after a load the saved controllers are in the level without a
// connection, and GameInfo.Login gives a returning player his saved pawn by that very name.
function bool NameTaken(string Name)
{
	local Controller C;

	if (Name ~= class'GameInfo'.Default.DefaultPlayerName)
		return true;
	for (C = Level.ControllerList; C != None; C = C.NextController)
		if (PlayerController(C) != None && PlayerController(C).Player != None && C.PlayerReplicationInfo != None
			&& C.PlayerReplicationInfo.PlayerName ~= Name)
			return true;
	return false;
}

// Loading a save: the engine makes the save file itself the level package (LoadMe_0). Clients
// joining that download it (16 MB) and load it as a map with every saved actor in it, and then
// do not work (no input, no RPCs). So on a listen server the host loads the save
// (GameState, day, errands come back as in SP) and then the leader travels to the saved map
// with the GameState, like any level change; clients wait (PreLogin refuses them on the save
// level) and join the real map. What the GameState carries across level changes comes back
// (dead pawns, gotten pickups, broken doors); positions start from the map's start.
event PostLoadGame()
{
	local CoopTestBase T;

	Super.PostLoadGame();
	bOnSaveLevel = true;
	log("P2Coop: PostLoadGame, saved map"@SavedMapName@"netmode"@Level.NetMode);
	foreach DynamicActors(class'CoopTestBase', T)
		T.Destroy();	// a test restored from the save would resume mid-script
	Test = None;
	if (Level.NetMode == NM_ListenServer && SavedMapName != "")
		Spawn(class'CoopLoadTraveler');
}

event InitGame(out string Options, out string Error)
{
	Super.InitGame(Options, Error);
	class'CoopSlotInfoMgr'.static.UseFor(self);	// co-op saves have their own slot list
}

function PostBeginPlay()
{
	Super.PostBeginPlay();
	GateScenes();
}

// A camera SceneManager refuses to start while any player is dead or has no pawn yet
// (SceneManager.Trigger), and a story trigger that fires once is then lost. Each one gets a
// CoopSceneGate that takes its Tag and starts it for the group (see CoopSceneGate). Scenes that
// another scene starts by its Tag (NextSceneTag) keep it: they follow a running scene.
function GateScenes()
{
	local SceneManager SM, Other;
	local CoopSceneGate Gate;
	local bool bChained;

	foreach DynamicActors(class'CoopSceneGate', Gate)
		break;
	if (Gate != None)
		return;	// a loaded save has them
	foreach AllActors(class'SceneManager', SM)
	{
		if (SM.Affect != AFFECT_ViewportCamera || SM.Tag == '' || SM.Tag == 'None' || SM.Tag == SM.Class.Name)
			continue;
		bChained = false;
		foreach AllActors(class'SceneManager', Other)
			if (Other.NextSceneTag == SM.Tag)
				bChained = true;
		if (bChained)
			continue;
		Gate = Spawn(class'CoopSceneGate',,, SM.Location);
		Gate.Gate(SM);
	}
}

// The map file name of the current level ("suburbs-3"), "" on a save level.
function string MapName()
{
	local string URL;

	URL = Level.GetLocalURL();
	if (InStr(URL, "/") >= 0)
		URL = Mid(URL, InStr(URL, "/") + 1);
	if (InStr(URL, "?") >= 0)
		URL = Left(URL, InStr(URL, "?"));
	if (InStr(URL, "#") >= 0)
		URL = Left(URL, InStr(URL, "#"));
	return URL;
}

// On the save level: the other players' saved pawns cannot travel (they have no connection
// here), so write down what they carry (see CarriedInventories).
function RecordSavedInventories(PlayerController Traveller)
{
	local Controller C;
	local string S;

	default.CarriedInventories.Length = 0;
	for (C = Level.ControllerList; C != None; C = C.NextController)
	{
		if (PlayerController(C) == None || C == Traveller || C.Pawn == None || C.Pawn.Health <= 0
			|| C.PlayerReplicationInfo == None)
			continue;
		S = C.PlayerReplicationInfo.PlayerName $ InventoryCodes(C.Pawn);
		default.CarriedInventories[default.CarriedInventories.Length] = S;
		log("P2Coop: carrying the saved inventory of"@S);
	}
}

// "|Class=amount" for each item (weapons with their ammo, powerups with their amount).
function string InventoryCodes(Pawn P)
{
	local Inventory Inv;
	local string S;
	local int Amount, n;

	for (Inv = P.Inventory; Inv != None && n < 100; Inv = Inv.Inventory)
	{
		n++;
		if (Inv.IsA('Ammunition') || Inv.IsA('GameState'))
			continue;
		Amount = 0;
		if (Weapon(Inv) != None && Weapon(Inv).AmmoType != None)
			Amount = Weapon(Inv).AmmoType.AmmoAmount;
		else if (P2PowerupInv(Inv) != None)
			Amount = P2PowerupInv(Inv).Amount;
		S = S $ "|" $ string(Inv.Class) $ "=" $ Amount;
	}
	return S;
}

// A player who rejoins after a load gets back what his saved pawn carried.
function GiveCarriedInventory(Pawn P, string PlayerName)
{
	local int i;
	local string S, Item, ClassName;
	local int Amount;
	local class<Inventory> InvClass;
	local Inventory Inv;

	for (i = 0; i < default.CarriedInventories.Length; i++)
		if (Left(default.CarriedInventories[i], Len(PlayerName) + 1) == (PlayerName $ "|"))
			break;
	if (i == default.CarriedInventories.Length || P2Pawn(P) == None)
		return;
	S = Mid(default.CarriedInventories[i], Len(PlayerName) + 1) $ "|";
	default.CarriedInventories.Remove(i, 1);
	while (InStr(S, "|") >= 0)
	{
		Item = Left(S, InStr(S, "|"));
		S = Mid(S, InStr(S, "|") + 1);
		if (InStr(Item, "=") < 0)
			continue;
		ClassName = Left(Item, InStr(Item, "="));
		Amount = int(Mid(Item, InStr(Item, "=") + 1));
		InvClass = class<Inventory>(DynamicLoadObject(ClassName, class'Class'));
		if (InvClass == None)
			continue;
		Inv = P2Pawn(P).CreateInventoryByClass(InvClass);
		if (Weapon(Inv) != None && Weapon(Inv).AmmoType != None && Amount > 0)
			Weapon(Inv).AmmoType.AmmoAmount = Amount;
		else if (P2PowerupInv(Inv) != None && Amount > 0)
			P2PowerupInv(Inv).Amount = Amount;
	}
	log("P2Coop: gave"@PlayerName@"his saved inventory back");
}

// The current level's URL options without "load" ("?Game=...?Listen?Port=7777...").
function string ListenOptions()
{
	local string URL, Opt, Out;

	URL = Level.GetLocalURL();
	if (InStr(URL, "#") >= 0)
		URL = Left(URL, InStr(URL, "#"));
	if (InStr(URL, "?") < 0)
		return "?Listen";
	URL = Mid(URL, InStr(URL, "?") + 1);
	while (URL != "")
	{
		if (InStr(URL, "?") >= 0)
		{
			Opt = Left(URL, InStr(URL, "?"));
			URL = Mid(URL, InStr(URL, "?") + 1);
		}
		else
		{
			Opt = URL;
			URL = "";
		}
		if (!(Opt ~= "load") && Left(Caps(Opt), 5) != "LOAD=")
			Out = Out $ "?" $ Opt;
	}
	if (InStr(Caps(Out), "?LISTEN") < 0)
		Out = Out $ "?Listen";
	return Out;
}

// True on the level of a loaded save (set in PostLoadGame; the level's URL is the saved one).
function bool OnSaveLevel()
{
	return bOnSaveLevel;
}

event PreLogin(string Options, string Address, out string Error, out string FailCode)
{
	Super.PreLogin(Options, Address, Error, FailCode);
	if (Error == "" && OnSaveLevel())
		Error = "P2Coop: the host is loading a save, joining in a moment";
	if (Error == "")
	{
		PendingLogins++;	// a level change waits for him (TravelMustWait)
		LastPreLoginTime = Level.TimeSeconds;
	}
}

function CoopTestBase SpawnTest(string Name)
{
	if (OnSaveLevel())
		return None;
	if (class'CoopTestLoad'.default.bAwaitingLoad)
		return Spawn(class'CoopTestLoad');
	if (Name ~= "combat")
		return Spawn(class'CoopTestCombat');
	if (Left(Name, 6) ~= "travel")
		return Spawn(class'CoopTestTravel');
	if (Name ~= "errand")
		return Spawn(class'CoopTestErrand');
	if (Left(Name, 4) ~= "jail")
		return Spawn(class'CoopTestJail');
	if (Name ~= "ragdoll")
		return Spawn(class'CoopTestRagdoll');
	if (Name ~= "cutscene")
		return Spawn(class'CoopTestCutscene');
	if (Name ~= "screens")
		return Spawn(class'CoopTestScreens');
	if (Name ~= "death")
		return Spawn(class'CoopTestDeath');
	if (Name ~= "load")
		return Spawn(class'CoopTestLoad');
	if (Left(Name, 10) ~= "leaderdead")
		return Spawn(class'CoopTestLeaderDead');
	return None;
}

// Whoever touched the telepad (or whatever sent "the player"), the leader travels:
// his pawn carries the GameState and his machine shows the load screens. A remote player never
// goes through the stock SendPlayerTo: it would hand him the GameState, and its load screens
// (CoopPlayer.DisplayMapHaters...) would call this again.
// - The leader is dead: he respawns now, next to the player who leaves.
// - The leader watches a cutscene (his pawn is the scene's): the level change waits for its end.
// - A player joined moments ago or is still logging in: it waits (TravelMustWait).
// Waiting happens before the stock code, so the GameState stays the game's while the level runs.
function SendPlayerTo(PlayerController player, String URL, optional bool bMaybePawnless)
{
	local PlayerController L, From;
	local bool bMayWait;

	L = Leader();
	From = player;
	if (Level.NetMode != NM_ListenServer || L == None)
	{
		StockSendPlayerTo(player, URL, bMaybePawnless);
		return;
	}
	// The stock code has already run for a level change that is under way (its GameState is gone).
	if ((PendingTravelURL != "" || Level.NextURL != "") && !bQuitting && InStr(URL, LOADGAME_URL) < 0)
	{
		log("P2Coop: SendPlayerTo"@URL@"from"@player@"ignored, the group is already travelling");
		return;
	}
	bMayWait = MayDeferSend(URL);
	if (L != player)
	{
		if (L.Pawn == None || L.Pawn.Health <= 0)
		{
			if (bMayWait && L.GetCurrentSceneManager() != None)
			{
				log("P2Coop: SendPlayerTo from"@player@"waits for the leader's cutscene"@URL);
				DeferSend(From, URL, bMaybePawnless);
				return;
			}
			if (!BringLeaderBack(L) && bMayWait)
			{
				log("P2Coop: SendPlayerTo from"@player@"refused, the leader cannot travel"@URL);
				if (player != None)
					player.ClientMessage("The host cannot travel now.");
				PendingSendURL = "";
				return;
			}
		}
		log("P2Coop: SendPlayerTo from"@player@"-> leader"@L@URL);
		player = L;
	}
	// A retry keeps the time of the first request (DeferSend), so the wait stays bounded.
	if (bMayWait && ((bSendRetry && TravelMustWait(PendingSendSince)) || (!bSendRetry && TravelMustWait(Level.TimeSeconds))))
	{
		DeferSend(From, URL, bMaybePawnless);
		return;
	}
	StockSendPlayerTo(player, URL, bMaybePawnless);
}

function StockSendPlayerTo(PlayerController player, String URL, bool bMaybePawnless)
{
	PendingSendURL = "";
	PendingSendFrom = None;
	bInStockSendPlayerTo = true;
	Super.SendPlayerTo(player, URL, bMaybePawnless);
	bInStockSendPlayerTo = false;
}

// Loads, quitting, the save level and the end of the game go at once.
function bool MayDeferSend(string URL)
{
	return !bQuitting && !bGameIsOver && !OnSaveLevel() && InStr(URL, LOADGAME_URL) < 0
		&& Left(URL, Len(MainMenuURL)) != MainMenuURL && Level.NextURL == "" && PendingTravelURL == "";
}

// The dead leader respawns now (not in a cutscene), next to a living player.
function bool BringLeaderBack(PlayerController L)
{
	if (CoopPlayer(L) == None || LivingPlayerPawn(L) == None)
		return false;
	log("P2Coop: the leader is dead, he respawns to take the group along");
	CoopPlayer(L).bRespawning = true;
	RestartPlayer(L);
	return L.Pawn != None && L.Pawn.Health > 0;
}

function DeferSend(PlayerController From, string URL, bool bMaybePawnless)
{
	if (PendingSendURL != "" && PendingSendURL != URL)
		log("P2Coop: level change to"@PendingSendURL@"replaced by"@URL);
	if (PendingSendURL != URL)
		PendingSendSince = Level.TimeSeconds;
	PendingSendURL = URL;
	PendingSendFrom = From;
	bPendingSendPawnless = bMaybePawnless;
	ArmTravelWaiter();
}

// CoopTravelWaiter: the deferred SendPlayerTo, once the leader's cutscene is over and nobody is
// still joining.
function RetryPendingSend()
{
	local PlayerController L, From;
	local string URL;

	if (PendingSendURL == "")
		return;
	L = Leader();
	if (L == None || !MayDeferSend(PendingSendURL))
	{
		PendingSendURL = "";
		return;
	}
	if (L.Pawn == None && L.GetCurrentSceneManager() != None)
	{
		if (Level.TimeSeconds - PendingSendSince < SceneMaxWait)
		{
			ArmTravelWaiter();
			return;
		}
		log("P2Coop: the leader's cutscene lasts too long, level change to"@PendingSendURL@"dropped");
		if (PendingSendFrom != None)
			PendingSendFrom.ClientMessage("The host cannot travel now.");
		PendingSendURL = "";
		return;
	}
	if (L.Pawn != None && TravelMustWait(PendingSendSince))
	{
		ArmTravelWaiter();
		return;
	}
	URL = PendingSendURL;	// stays set: a new wait keeps its time (DeferSend)
	From = PendingSendFrom;
	if (From == None || From.bDeleteMe)
		From = L;
	log("P2Coop: the deferred level change goes now:"@URL);
	bSendRetry = true;
	SendPlayerTo(From, URL, bPendingSendPawnless);
	bSendRetry = false;
}

// A client that joined moments ago is still loading the map; a travel order then fails on its
// side and leaves it on a dead connection. Wait until every client has been in for
// TravelSettleTime seconds and nobody is between PreLogin and PostLogin, at most TravelMaxWait
// from Since.
function bool TravelMustWait(float Since)
{
	local Controller C;
	local float Newest;

	if (Level.TimeSeconds - Since >= TravelMaxWait)
		return false;
	Newest = -1000;
	for (C = Level.ControllerList; C != None; C = C.NextController)
		if (CoopPlayer(C) != None && NetConnection(CoopPlayer(C).Player) != None)
			Newest = FMax(Newest, CoopPlayer(C).JoinTime);
	if (PendingLogins > 0 && Level.TimeSeconds - LastPreLoginTime >= LoginTimeout)
		PendingLogins = 0;	// those logins failed
	if (Level.TimeSeconds - Newest < TravelSettleTime || PendingLogins > 0)
	{
		log("P2Coop: travel waits, newest player joined"@(Level.TimeSeconds - Newest)@"s ago, logging in"@PendingLogins);
		return true;
	}
	return false;
}

// CoopTravelWaiter retries every 0.5 s (the game info's own Timer belongs to the SP states).
function ArmTravelWaiter()
{
	if (TravelWaiter == None)
		TravelWaiter = Spawn(class'CoopTravelWaiter');
	TravelWaiter.SetTimer(0.5, false);
}

// The stock travel is the player's own ClientTravel: on a listen server that takes the host
// away alone. Move the whole group with the server instead, items included. Loads and
// quitting stay stock (absolute, without items).
function SendPlayerEx(PlayerController player, String URL, optional ETravelType TravelType,
	optional ETravelItems TravelItems)
{
	local GameState GS;

	if (Level.NetMode != NM_ListenServer || InStr(URL, LOADGAME_URL) >= 0 || bQuitting || bGameIsOver
		|| player == None || player.Pawn == None)
	{
		Super.SendPlayerEx(player, URL, TravelType, TravelItems);
		return;
	}
	// Leaving a save level (CoopLoadTraveler): its URL carries a host part, so a relative
	// ServerTravel made the host connect to itself. Nobody else is connected here: travel
	// absolute with this level's options (Listen, Game, Port...) minus the load.
	if (OnSaveLevel())
	{
		URL = URL $ ListenOptions();
		RecordSavedInventories(player);
		default.Travellers.Remove(0, default.Travellers.Length);	// the next arrivals bring nothing
		log("P2Coop: leaving the save level:"@URL);
		player.ClientTravel(URL, TRAVEL_Absolute, TravelItems == TRAV_WithItems);
		return;
	}
	// What the stock chain does before its ClientTravel (P2GameInfoSingle, P2GameInfo, FPSGameInfo).
	GS = GameState(P2Pawn(player.Pawn).FindInventoryType(GameStateClass));
	if (GS != None)
		GS.PreTravelTime = Level.GetMillisecondsNow();
	TravelGameState = GS;
	StopSceneManagers();
	StopAllMusicExt(0.0);
	if (InStr(URL, "#") < 0)
		URL = URL $ "#";
	// (SendPlayerTo rebuilds the URL, so options added before it are lost: TravelOptions are
	// added in TryPendingTravel.)
	PendingTravelURL = URL;
	bPendingTravelItems = TravelItems == TRAV_WithItems;
	PendingTravelSince = Level.TimeSeconds;
	TryPendingTravel();
}

// The ServerTravel. Most waiting is done before the stock code (SendPlayerTo); a player who
// starts joining while the load screen shows is still waited for here. Players take no damage
// meanwhile (ReduceDamage), and the leader's pawn must hold the GameState when it goes.
function TryPendingTravel()
{
	local Controller C;

	if (PendingTravelURL == "")
		return;
	if (LeaderHoldsGameState() && TravelMustWait(PendingTravelSince))
	{
		ArmTravelWaiter();
		return;
	}
	KeepGameStateWithLeader();
	default.Travellers.Remove(0, default.Travellers.Length);
	if (bPendingTravelItems)
		for (C = Level.ControllerList; C != None; C = C.NextController)
			if (CoopPlayer(C) != None && CoopPlayer(C).IsRemote() && C.PlayerReplicationInfo != None)
				default.Travellers[default.Travellers.Length] = C.PlayerReplicationInfo.PlayerName;
	// Added now, not in SendPlayerEx, so a test's results up to the very travel go with it.
	PendingTravelURL = PendingTravelURL $ TravelOptions;
	log("P2Coop: ServerTravel"@PendingTravelURL@"items"@bPendingTravelItems@"travellers"@default.Travellers.Length);
	Level.ServerTravel(PendingTravelURL, bPendingTravelItems);
	PendingTravelURL = "";
	TravelGameState = None;
}

function bool LeaderHoldsGameState()
{
	local PlayerController L;

	L = Leader();
	return L != None && L.Pawn != None && L.Pawn.Health > 0 && L.Pawn.FindInventoryType(GameStateClass) != None;
}

// Before the ServerTravel: if the leader died while it waited, he respawns and the GameState
// goes into his new pawn, so the next map continues the game instead of starting a new one.
function KeepGameStateWithLeader()
{
	local PlayerController L;

	if (LeaderHoldsGameState())
		return;
	L = Leader();
	if (L == None)
		return;
	if ((L.Pawn == None || L.Pawn.Health <= 0) && !BringLeaderBack(L))
		return;
	if (TravelGameState == None || TravelGameState.bDeleteMe || L.Pawn.FindInventoryType(GameStateClass) != None)
		return;
	if (Pawn(TravelGameState.Owner) != None)
		Pawn(TravelGameState.Owner).DeleteInventory(TravelGameState);
	if (L.Pawn.AddInventory(TravelGameState))
		log("P2Coop: the GameState goes with the leader's new pawn"@L.Pawn);
}

// Every arriving player's TravelPostAccept calls this. Only the leader's pawn carries the
// GameState; for the others the stock code would take the "loaded a saved game" branch.
event PostTravel(P2Pawn PlayerPawn)
{
	local PlayerController L;
	local bool bNewGame;

	L = Leader();
	if (PlayerPawn != None && L != None && PlayerPawn.Controller != L && TheGameState != None)
	{
		log("P2Coop: PostTravel for"@PlayerPawn@"skipped, the leader carries the GameState");
		return;
	}
	// The stock code starts a new game when the leader brings no GameState (see its comment).
	// (FindInventoryType matches the exact class; the old class is the stock "Groundhog Day" case.)
	bNewGame = TheGameState == None && (PlayerPawn == None || (PlayerPawn.FindInventoryType(GameStateClass) == None
		&& PlayerPawn.FindInventoryType(class'GameState') == None));
	Super.PostTravel(PlayerPawn);
	if (bNewGame)
		ForgetOtherSessions();
}

// A new game: what an earlier session left in the class defaults (other players' saved items,
// last travel's travellers) is not for the players of this one.
function ForgetOtherSessions()
{
	if (default.CarriedInventories.Length > 0 || default.Travellers.Length > 0)
		log("P2Coop: new game, forgetting"@default.CarriedInventories.Length@"carried inventories and"
			@default.Travellers.Length@"travellers");
	default.CarriedInventories.Remove(0, default.CarriedInventories.Length);
	default.Travellers.Remove(0, default.Travellers.Length);
}

// The host's own PlayerController (the one with a viewport, not a net connection).
function PlayerController Leader()
{
	local Controller C;

	for (C = Level.ControllerList; C != None; C = C.NextController)
		if (PlayerController(C) != None && PlayerController(C).Player != None
			&& NetConnection(PlayerController(C).Player) == None)
			return PlayerController(C);
	return None;
}

// Map scripts take "the player" as the first P2Player in Level.ControllerList,
// and every new login is linked in at the head. Re-link the host so it is first again.
function MakeHostFirst()
{
	local PlayerController L;

	L = Leader();
	if (L != None && L != Level.ControllerList)
	{
		L.RemoveController();
		L.AddController();
	}
}

// The stock RestartPlayer spawns at the map's PlayerStart. SP maps have one, and the
// leader stands on it, so the spawn fails ("Couldn't spawn player") and the joiner
// waits dead for a retry. It also fires the start's event (CheckStartDay, the day
// start script) again. Other players therefore spawn next to the leader instead.
// The stock RestartPlayer is used only for the leader's first spawn on a level.
// Everyone else, and the leader after a death, spawns next to a living player (the leader's
// pawn first, also while a cutscene holds it). With nobody to spawn next to: during the
// leader's cutscene, a joiner tries again shortly; otherwise he takes the map's start, without
// its event.
function RestartPlayer(Controller aPlayer)
{
	local PlayerController L;
	local CoopPlayer P;
	local Pawn Anchor;

	L = Leader();
	P = CoopPlayer(aPlayer);
	if (P == None || (aPlayer == L && !P.bRespawning && !P.bSpawnedHere))
	{
		Super.RestartPlayer(aPlayer);
		if (P != None && aPlayer.Pawn != None)
			P.bSpawnedHere = true;
		return;
	}
	if (aPlayer.Pawn != None && aPlayer.Pawn.Health > 0)
		return;	// alive (a late respawn order)
	Anchor = LivingPlayerPawn(aPlayer);
	if (Anchor != None)
	{
		aPlayer.Pawn = None;	// the old body stays where it fell
		if (SpawnNear(aPlayer, Anchor))
			return;
	}
	if (aPlayer == L)
	{
		log("P2Coop: the leader stays dead, nobody to spawn next to");
		return;
	}
	if (Anchor == None && L != None && L.GetCurrentSceneManager() != None)
	{
		log("P2Coop:"@aPlayer.PlayerReplicationInfo.PlayerName@"waits for the leader's cutscene to spawn");
		P.bRespawning = true;
		P.RespawnTime = Level.TimeSeconds + 1.0;
		StartRespawner();
		return;
	}
	if (P.IsInState('Dead') && Anchor == None)
		return;	// everybody is dead: the stock game over
	aPlayer.Pawn = None;
	SpawnAtStart(aPlayer);
}

// A living human player's pawn other than Except's: the leader's first, or the pawn a cutscene
// holds for him.
function Pawn LivingPlayerPawn(Controller Except)
{
	local Controller C;
	local PlayerController L;
	local SceneManager SM;

	L = Leader();
	if (L != None && L != Except)
	{
		if (L.Pawn != None && L.Pawn.Health > 0)
			return L.Pawn;
		if (L.Pawn == None)
			SM = L.GetCurrentSceneManager();
		if (SM != None && SM.OldPawn != None && SM.OldPawn.Health > 0 && (Except == None || SM.OldPawn != Except.Pawn))
			return SM.OldPawn;
	}
	for (C = Level.ControllerList; C != None; C = C.NextController)
		if (PlayerController(C) != None && C != Except && C.Pawn != None && C.Pawn.Health > 0)
			return C.Pawn;
	return None;
}

// A connected player other than Except who has no pawn but is not dead (joining).
function bool PlayerJoining(Controller Except)
{
	local Controller C;

	for (C = Level.ControllerList; C != None; C = C.NextController)
		if (PlayerController(C) != None && C != Except && PlayerController(C).Player != None
			&& C.Pawn == None && !C.IsInState('Dead'))
			return true;
	return false;
}

// CoopPlayer entered the Dead state on the server. While somebody else lives (or is about to:
// joining, or in a cutscene), the dead player comes back next to him after RespawnDelay
// (?CoopRespawnDelay=<s> overrides it); when everybody is dead the stock game over remains:
// the leader's "fire" loads the last save.
function PlayerDied(CoopPlayer P)
{
	if (LivingPlayerPawn(P) == None && !PlayerJoining(P))
	{
		log("P2Coop:"@P.PlayerReplicationInfo.PlayerName@"died, nobody left alive: game over");
		return;
	}
	P.bRespawning = true;
	P.RespawnTime = Level.TimeSeconds + RespawnDelay();
	log("P2Coop:"@P.PlayerReplicationInfo.PlayerName@"died, respawns in"@RespawnDelay()@"s");
	StartRespawner();
}

function StartRespawner()
{
	if (Respawner == None)
		Respawner = Spawn(class'CoopRespawner');
}

function float RespawnDelay()
{
	if (URLOption("CoopRespawnDelay") != "")
		return float(URLOption("CoopRespawnDelay"));
	return DefaultRespawnDelay;
}

// Spawns aPlayer's pawn on a free spot in rings around Anchor, with a clear line to it,
// then does what the stock RestartPlayer does after the spawn, minus the start event.
function bool SpawnNear(Controller aPlayer, Pawn Anchor)
{
	local class<Pawn> PawnClass;
	local vector Spot;
	local rotator Dir;
	local float Dist;
	local int Ring, i;

	PawnClass = aPlayer.PawnClass;
	if (PawnClass == None)
		PawnClass = GetDefaultPlayerClass(aPlayer);

	for (Ring = 1; Ring <= 3 && aPlayer.Pawn == None; Ring++)
	{
		Dist = Ring * 2.5 * Anchor.CollisionRadius;
		for (i = 0; i < 8 && aPlayer.Pawn == None; i++)
		{
			Dir = Anchor.Rotation;
			Dir.Pitch = 0;
			Dir.Yaw += 8192 * i + 32768;	// behind the leader first
			Spot = Anchor.Location + Dist * vector(Dir);
			if (FastTrace(Spot, Anchor.Location))
				aPlayer.Pawn = Spawn(PawnClass,,, Spot, Anchor.Rotation);
		}
	}
	if (aPlayer.Pawn == None)
	{
		log("P2Coop: no free spot near"@Anchor@"for"@aPlayer);
		return false;
	}
	log("P2Coop: spawned"@aPlayer.Pawn@"for"@aPlayer.PlayerReplicationInfo.PlayerName
		@"near"@Anchor@"ring"@(Ring - 1));
	FinishSpawn(aPlayer);
	return true;
}

// The stock RestartPlayer without the start's event (CheckStartDay, the day start script).
function bool SpawnAtStart(Controller aPlayer)
{
	local NavigationPoint StartSpot;
	local class<Pawn> PawnClass;

	StartSpot = FindPlayerStart(aPlayer, 255);
	if (StartSpot == None)
		return false;
	PawnClass = aPlayer.PawnClass;
	if (PawnClass != None)
		aPlayer.Pawn = Spawn(PawnClass,,, StartSpot.Location, StartSpot.Rotation);
	if (aPlayer.Pawn == None)
		aPlayer.Pawn = Spawn(GetDefaultPlayerClass(aPlayer),,, StartSpot.Location, StartSpot.Rotation);
	if (aPlayer.Pawn == None)
	{
		log("P2Coop: no spawn for"@aPlayer.PlayerReplicationInfo.PlayerName@"at"@StartSpot@"either, trying again");
		if (CoopPlayer(aPlayer) != None)
		{
			CoopPlayer(aPlayer).bRespawning = true;
			CoopPlayer(aPlayer).RespawnTime = Level.TimeSeconds + 1.0;
			StartRespawner();
		}
		return false;
	}
	aPlayer.Pawn.LastStartSpot = PlayerStart(StartSpot);
	log("P2Coop: spawned"@aPlayer.Pawn@"for"@aPlayer.PlayerReplicationInfo.PlayerName@"at"@StartSpot@"(without its event)");
	FinishSpawn(aPlayer);
	return true;
}

// What the stock RestartPlayer does after the spawn, minus the start event, plus the kit.
function FinishSpawn(Controller aPlayer)
{
	local CoopPlayer P;

	P = CoopPlayer(aPlayer);
	aPlayer.Pawn.LastStartTime = Level.TimeSeconds;
	aPlayer.PreviousPawnClass = aPlayer.Pawn.Class;
	aPlayer.Possess(aPlayer.Pawn);
	aPlayer.PawnClass = aPlayer.Pawn.Class;
	aPlayer.Pawn.PlayTeleportEffect(true, true);
	aPlayer.ClientSetRotation(aPlayer.Pawn.Rotation);
	if (P != None)
	{
		P.bRespawning = false;
		P.bSpawnedHere = true;
		P.bInCutscene = false;	// CoopCutscene starts the leader's scene on the new pawn's client again
	}
	if (bLoggingIn && IsTraveller(aPlayer.PlayerReplicationInfo.PlayerName) && P != None)
	{
		log("P2Coop:"@aPlayer.PlayerReplicationInfo.PlayerName@"brings his things from the last map");
		ForgetTraveller(aPlayer.PlayerReplicationInfo.PlayerName);	// a rejoin later on this map brings nothing
		P.KitCheckTime = Level.TimeSeconds + KitCheckDelay;
		StartRespawner();
	}
	else
		GiveKit(aPlayer.Pawn, aPlayer.PlayerReplicationInfo.PlayerName);
}

// The host's ragdoll of P, for the clients (CoopRagdollSync), one per body. With bWait the sync
// starts the ragdoll itself on the next tick (CoopPlayer.GetNewRagdollSkel).
function SyncRagdoll(Pawn P, bool bWait)
{
	local CoopRagdollSync S;

	if (Level.NetMode != NM_ListenServer || P == None)
		return;
	foreach DynamicActors(class'CoopRagdollSync', S)
		if (S.Corpse == P)
			break;
	if (S == None)
	{
		S = Spawn(class'CoopRagdollSync');
		if (S == None)
			return;
		S.SetCorpse(P);
		log("P2Coop: ragdoll sync"@S@"for"@P);
	}
	if (bWait)
		S.StartSoon();
}

// An animal dies with an animation, not a ragdoll. AnimalPawn.PlayDying (next in Pawn.Died) would
// tear the body off the network: each client would run its own fall and a player who comes later
// would never see it. Without bPhysicsAnimUpdate it does not, and the body is synced like a
// ragdoll: its location, rotation and death animation.
function Killed(Controller Killer, Controller Killed, Pawn KilledPawn, class<DamageType> damageType)
{
	Super.Killed(Killer, Killed, KilledPawn, damageType);
	if (AnimalPawn(KilledPawn) != None && Level.NetMode == NM_ListenServer)
	{
		KilledPawn.bPhysicsAnimUpdate = false;
		SyncRagdoll(KilledPawn, false);
	}
}

function bool IsTraveller(string PlayerName)
{
	local int i;

	for (i = 0; i < default.Travellers.Length; i++)
		if (default.Travellers[i] == PlayerName)
			return true;
	return false;
}

function ForgetTraveller(string PlayerName)
{
	local int i;

	for (i = default.Travellers.Length - 1; i >= 0; i--)
		if (default.Travellers[i] == PlayerName)
			default.Travellers.Remove(i, 1);
}

// The day's starting kit (money, map, stats...), as the leader got it in PostTravel. It only
// tops amounts up, so giving it to someone who has it does not double it.
function GiveDayKit(Pawn P)
{
	if (P2Pawn(P) != None && TheGameState != None && TheGameState.CurrentDay >= 0
		&& TheGameState.CurrentDay < Days.Length)
		Days[TheGameState.CurrentDay].AddInStartingInventory(P2Pawn(P));
}

// A remote player leaves the level without a map change (his game closed, his connection
// dropped): remember what he carries for his rejoin (GiveKit), and take it from the pawn quietly
// so that its death (PlayerController.Destroyed) does not drop it on the ground as well.
function PlayerLeaving(PlayerController P)
{
	local Inventory Inv, Next;
	local string Name;
	local int i, n;

	if (P.Pawn == None || P.Pawn.Health <= 0 || P.PlayerReplicationInfo == None || Level.NextURL != ""
		|| PendingTravelURL != "" || OnSaveLevel() || P == Leader())
		return;
	Name = P.PlayerReplicationInfo.PlayerName;
	for (i = default.CarriedInventories.Length - 1; i >= 0; i--)
		if (Left(default.CarriedInventories[i], Len(Name) + 1) == (Name $ "|"))
			default.CarriedInventories.Remove(i, 1);
	default.CarriedInventories[default.CarriedInventories.Length] = Name $ InventoryCodes(P.Pawn);
	log("P2Coop:"@Name@"left, keeping his things for his rejoin:"@default.CarriedInventories[default.CarriedInventories.Length - 1]);
	for (Inv = P.Pawn.Inventory; Inv != None && n < 100; Inv = Next)
	{
		n++;
		Next = Inv.Inventory;
		if (!Inv.IsA('GameState'))
			Inv.Destroy();
	}
}

// The starting things of a player's pawn.
function GiveKit(Pawn P, string PlayerName)
{
	AddDefaultInventory(P);
	// SP gives the dude's equipment in P2Player.TravelPostAccept, which a network
	// joiner never gets (and which would rerun PostTravel's GameState handling).
	if (P2Pawn(P) != None)
	{
		P2Pawn(P).AddDefaultInventory();
		GiveDayKit(P);
	}
	if (BaseMod != None)
		BaseMod.ModifyPlayerInventory(P);
	GiveCarriedInventory(P, PlayerName);
}

// Stock takes the leader's things on entering jail (when the level starts); the jailer takes
// everyone else's as they arrive.
function CheckToTransferPlayerInventory()
{
	if (TheGameState != None && TheGameState.bTakePlayerInventory && Jailer == None)
	{
		Jailer = Spawn(class'CoopJailer');
		Jailer.Record();
	}
	Super.CheckToTransferPlayerInventory();
}

function int ReduceDamage(int Damage, Pawn Injured, Pawn InstigatedBy, vector HitLocation,
	out vector Momentum, class<DamageType> DamageType)
{
	local int Result;

	Result = Super.ReduceDamage(Damage, Injured, InstigatedBy, HitLocation, Momentum, DamageType);
	if (Cutscene != None && Cutscene.Protects(Injured))
		Result = 0;
	// A story screen holds the player still while the world goes on (CoopPlayer.SendScreen).
	if (Injured != None && CoopPlayer(Injured.Controller) != None && CoopPlayer(Injured.Controller).ScreenProtected())
		Result = 0;
	// A level change is waiting (SendPlayerTo, TryPendingTravel): the leader must arrive alive with
	// the GameState, and nobody should die on a level that is about to go.
	if ((PendingSendURL != "" || PendingTravelURL != "") && Injured != None && Injured.IsHumanControlled())
		Result = 0;
	if (Test != None && Injured != None && Injured.IsHumanControlled())
		log("P2Coop: damage to"@Injured@"by"@InstigatedBy@DamageType@Damage@"->"@Result);
	return Result;
}

// A remote player completed errand ErrandIndex of today (CoopPlayer.DisplayMapCrossOut):
// tell every player, since only the leader's machine shows the map.
function AnnounceErrand(PlayerController Who, int ErrandIndex)
{
	local Controller C;
	local string Name;

	Name = "#"$ErrandIndex;
	if (TheGameState != None && TheGameState.CurrentDay < Days.Length
		&& ErrandIndex >= 0 && ErrandIndex < Days[TheGameState.CurrentDay].Errands.Length)
		Name = Days[TheGameState.CurrentDay].Errands[ErrandIndex].UniqueName;
	log("P2Coop: errand"@Name@"completed by"@Who.PlayerReplicationInfo.PlayerName);
	for (C = Level.ControllerList; C != None; C = C.NextController)
		if (PlayerController(C) != None)
			PlayerController(C).ClientMessage(Who.PlayerReplicationInfo.PlayerName$": errand done -"@Name);
	if (Test != None)
		Test.ErrandAnnounced(Who, Name);
}

// Option of the current level URL. GetLocalURL starts with the map name, while
// ParseOption expects the string to start at the first '?'; a "#portal" can follow the last option.
function string URLOption(string Key)
{
	local string URL;

	URL = Level.GetLocalURL();
	if (InStr(URL, "#") >= 0)
		URL = Left(URL, InStr(URL, "#"));
	if (InStr(URL, "?") < 0)
		return "";
	return ParseOption(Mid(URL, InStr(URL, "?")), Key);
}

// ?CoopNoSave=1 skips all saves (a save used to break the next JOIN);
// ForceSave bypasses that for probes.
function bool SaveGame(int Slot, bool bShowMessage)
{
	if (URLOption("CoopNoSave") == "1")
	{
		log("P2CoopProbe: SaveGame("$Slot$") skipped (CoopNoSave)");
		return false;
	}
	RememberMap();
	return Super.SaveGame(Slot, bShowMessage);
}

function bool ForceSave(int Slot)
{
	RememberMap();
	return Super.SaveGame(Slot, false);
}

// Goes into the save with this actor (see PostLoadGame).
function RememberMap()
{
	if (MapName() != "")
		SavedMapName = MapName();
}

defaultproperties
{
	GameName="POSTAL 2 Co-op"
	PlayerControllerClassName="P2Coop.CoopPlayer"
	HUDType="P2Coop.CoopHUD"
	MapScreenClassName="P2Coop.CoopMapScreen"
}
