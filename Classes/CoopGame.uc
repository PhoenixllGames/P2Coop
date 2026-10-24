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
var string TravelOptions;	// appended to the next ServerTravel URL (tests carry their state)

const TravelSettleTime = 8.0;	// see TryPendingTravel
const TravelMaxWait = 15.0;
var string PendingTravelURL;
var bool bPendingTravelItems;
var float PendingTravelSince;
var CoopTravelWaiter TravelWaiter;
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
	if (Name ~= "cutscene")
		return Spawn(class'CoopTestCutscene');
	if (Name ~= "screens")
		return Spawn(class'CoopTestScreens');
	if (Name ~= "death")
		return Spawn(class'CoopTestDeath');
	if (Name ~= "load")
		return Spawn(class'CoopTestLoad');
	return None;
}

// Whoever touched the telepad (or whatever sent "the player"), the leader travels:
// his pawn carries the GameState and his machine shows the load screens.
function SendPlayerTo(PlayerController player, String URL, optional bool bMaybePawnless)
{
	local PlayerController L;

	L = Leader();
	if (Level.NetMode == NM_ListenServer && L != None && L != player && L.Pawn != None)
	{
		log("P2Coop: SendPlayerTo from"@player@"-> leader"@L@URL);
		player = L;
	}
	Super.SendPlayerTo(player, URL, bMaybePawnless);
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
		log("P2Coop: leaving the save level:"@URL);
		player.ClientTravel(URL, TRAVEL_Absolute, TravelItems == TRAV_WithItems);
		return;
	}
	// What the stock chain does before its ClientTravel (P2GameInfoSingle, P2GameInfo, FPSGameInfo).
	GS = GameState(P2Pawn(player.Pawn).FindInventoryType(GameStateClass));
	if (GS != None)
		GS.PreTravelTime = Level.GetMillisecondsNow();
	StopSceneManagers();
	StopAllMusicExt(0.0);
	if (InStr(URL, "#") < 0)
		URL = URL $ "#";
	// SendPlayerTo rebuilds the URL, so options added before it are lost.
	URL = URL $ TravelOptions;
	PendingTravelURL = URL;
	bPendingTravelItems = TravelItems == TRAV_WithItems;
	PendingTravelSince = Level.TimeSeconds;
	TryPendingTravel();
}

// A client that joined moments ago is still loading the map; a travel order then fails on
// its side and leaves it on a dead connection. Wait until every client has been in for
// TravelSettleTime seconds (at most TravelMaxWait); CoopTravelWaiter retries every 0.5 s
// (the game info's own Timer belongs to the SP states).
function TryPendingTravel()
{
	local Controller C;
	local float Newest;

	if (PendingTravelURL == "")
		return;
	Newest = -1000;
	for (C = Level.ControllerList; C != None; C = C.NextController)
		if (CoopPlayer(C) != None && NetConnection(CoopPlayer(C).Player) != None)
			Newest = FMax(Newest, CoopPlayer(C).JoinTime);
	if (Level.TimeSeconds - Newest < TravelSettleTime && Level.TimeSeconds - PendingTravelSince < TravelMaxWait)
	{
		log("P2Coop: travel waits for a player who joined"@(Level.TimeSeconds - Newest)@"s ago");
		if (TravelWaiter == None)
			TravelWaiter = Spawn(class'CoopTravelWaiter');
		TravelWaiter.SetTimer(0.5, false);
		return;
	}
	default.Travellers.Remove(0, default.Travellers.Length);
	if (bPendingTravelItems)
		for (C = Level.ControllerList; C != None; C = C.NextController)
			if (CoopPlayer(C) != None && CoopPlayer(C).IsRemote() && C.PlayerReplicationInfo != None)
				default.Travellers[default.Travellers.Length] = C.PlayerReplicationInfo.PlayerName;
	log("P2Coop: ServerTravel"@PendingTravelURL@"items"@bPendingTravelItems@"travellers"@default.Travellers.Length);
	Level.ServerTravel(PendingTravelURL, bPendingTravelItems);
	PendingTravelURL = "";
}

// Every arriving player's TravelPostAccept calls this. Only the leader's pawn carries the
// GameState; for the others the stock code would take the "loaded a saved game" branch.
event PostTravel(P2Pawn PlayerPawn)
{
	local PlayerController L;

	L = Leader();
	if (PlayerPawn != None && L != None && PlayerPawn.Controller != L && TheGameState != None)
	{
		log("P2Coop: PostTravel for"@PlayerPawn@"skipped, the leader carries the GameState");
		return;
	}
	Super.PostTravel(PlayerPawn);
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
function RestartPlayer(Controller aPlayer)
{
	local PlayerController L;
	local Pawn Anchor;

	// A respawn after death (the leader's too): next to a living player, without the start event.
	if (CoopPlayer(aPlayer) != None && CoopPlayer(aPlayer).bRespawning)
	{
		Anchor = LivingPlayerPawn(aPlayer);
		if (Anchor != None)
		{
			aPlayer.Pawn = None;	// the old body stays where it fell
			if (SpawnNear(aPlayer, Anchor))
			{
				CoopPlayer(aPlayer).bRespawning = false;
				return;
			}
		}
	}
	L = Leader();
	if (aPlayer == L || L == None || L.Pawn == None || PlayerController(aPlayer) == None
		|| !SpawnNear(aPlayer, L.Pawn))
		Super.RestartPlayer(aPlayer);
}

// A living human player's pawn other than Except's, the leader's first.
function Pawn LivingPlayerPawn(Controller Except)
{
	local Controller C;
	local PlayerController L;

	L = Leader();
	if (L != None && L != Except && L.Pawn != None && L.Pawn.Health > 0)
		return L.Pawn;
	for (C = Level.ControllerList; C != None; C = C.NextController)
		if (PlayerController(C) != None && C != Except && C.Pawn != None && C.Pawn.Health > 0)
			return C.Pawn;
	return None;
}

// CoopPlayer entered the Dead state on the server. While somebody else lives, the dead player
// comes back next to him after RespawnDelay (?CoopRespawnDelay=<s> overrides it); when
// everybody is dead the stock game over remains: the leader's "fire" loads the last save.
function PlayerDied(CoopPlayer P)
{
	if (LivingPlayerPawn(P) == None)
	{
		log("P2Coop:"@P.PlayerReplicationInfo.PlayerName@"died, nobody left alive: game over");
		return;
	}
	P.bRespawning = true;
	P.RespawnTime = Level.TimeSeconds + RespawnDelay();
	log("P2Coop:"@P.PlayerReplicationInfo.PlayerName@"died, respawns in"@RespawnDelay()@"s");
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
		log("P2Coop: no free spot near"@Anchor@"for"@aPlayer@"- using the PlayerStart");
		return false;
	}

	aPlayer.Pawn.LastStartTime = Level.TimeSeconds;
	aPlayer.PreviousPawnClass = aPlayer.Pawn.Class;
	aPlayer.Possess(aPlayer.Pawn);
	aPlayer.PawnClass = aPlayer.Pawn.Class;
	aPlayer.Pawn.PlayTeleportEffect(true, true);
	aPlayer.ClientSetRotation(aPlayer.Pawn.Rotation);
	if (bLoggingIn && IsTraveller(aPlayer.PlayerReplicationInfo.PlayerName) && CoopPlayer(aPlayer) != None)
	{
		log("P2Coop:"@aPlayer.PlayerReplicationInfo.PlayerName@"brings his things from the last map");
		CoopPlayer(aPlayer).KitCheckTime = Level.TimeSeconds + KitCheckDelay;
		if (Respawner == None)
			Respawner = Spawn(class'CoopRespawner');
	}
	else
		GiveKit(aPlayer.Pawn, aPlayer.PlayerReplicationInfo.PlayerName);
	log("P2Coop: spawned"@aPlayer.Pawn@"for"@aPlayer.PlayerReplicationInfo.PlayerName
		@"near"@Anchor@"ring"@(Ring - 1));
	return true;
}

function bool IsTraveller(string PlayerName)
{
	local int i;

	for (i = 0; i < default.Travellers.Length; i++)
		if (default.Travellers[i] == PlayerName)
			return true;
	return false;
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
		// The day's starting kit (money, map, stats...), as the leader got it in PostTravel.
		if (TheGameState != None && TheGameState.CurrentDay >= 0 && TheGameState.CurrentDay < Days.Length)
			Days[TheGameState.CurrentDay].AddInStartingInventory(P2Pawn(P));
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
	bForbidRagdolls=true	// see CoopPlayer.GetNewRagdollSkel
	MapScreenClassName="P2Coop.CoopMapScreen"
}
