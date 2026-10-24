//=============================================================================
// CoopShadowGame: a client's local stand-in for the host's game info (see CoopReplicationInfo).
//
// Spawned by the client's CoopReplicationInfo and never made Level.Game: client-side code tests
// Level.Game == None to know it is a client. It does none of a game info's work (no StartUp
// state, no GameReplicationInfo, no timers); it only answers what the map, the newspaper and the
// HUD ask: the day (Days[] are the same objects as on the host), the errands and the GameState.
//=============================================================================
class CoopShadowGame extends CoopGame;

// What this player has already seen written on his map (MapScreen adds to the GameState's
// Revealed lists and sets SHater.Revealed). Kept in the class defaults across levels, where the
// shadow game is spawned again. Same format as CoopReplicationInfo's lists; haters by class.
var string SeenErrands, SeenLocations, SeenHaters;

var name ParsedName;

function PreBeginPlay();
function PostBeginPlay();
event Tick(float DeltaTime);
function Timer();

simulated event SetInitialState()
{
	bScriptInitialized = true;
}

function Init()
{
	TheGameState = Spawn(GameStateClass, self);
	if (TheGameState == None)
		TheGameState = Spawn(class'GameState', self);
	xPatchManagerCheck();
	class'CoopReplicationInfo'.static.ParseErrands(default.SeenErrands, TheGameState.RevealedErrands);
	class'CoopReplicationInfo'.static.ParseErrands(default.SeenLocations, TheGameState.RevealedLocationTex);
	log("P2Coop: client shadow game"@self@"state"@TheGameState);
}

// Take the host's state from R.
function Apply(CoopReplicationInfo R)
{
	local GameState gs;
	local int i, d, e;

	gs = TheGameState;
	Remember();
	gs.CurrentDay = Clamp(R.CurrentDay, 0, Days.Length - 1);
	gs.bIsApocalypse = R.bIsApocalypse;
	gs.CopRadioTime = R.CopRadioTime;
	class'CoopReplicationInfo'.static.ParseErrands(R.Completed, gs.CompletedErrands);
	class'CoopReplicationInfo'.static.ParseErrands(R.Activated, gs.ActivatedErrands);
	class'CoopReplicationInfo'.static.ParseErrands(R.DeActivated, gs.DeActivatedErrands);
	class'CoopReplicationInfo'.static.ParseErrands(R.LocActivated, gs.LocationTexActivatedErrands);
	class'CoopReplicationInfo'.static.ParseErrands(R.LocDeActivated, gs.LocationTexDeActivatedErrands);
	ApplyHaters(R.Haters);

	RestoreDayAndErrands();
	for (i = 0; i < gs.LocationTexActivatedErrands.Length; i++)
	{
		d = gs.LocationTexActivatedErrands[i].Day;
		e = gs.LocationTexActivatedErrands[i].Errand;
		if (d < Days.Length && e < Days[d].Errands.Length)
			Days[d].Errands[e].ActivateLocationTex();
	}
	for (i = 0; i < gs.LocationTexDeActivatedErrands.Length; i++)
	{
		d = gs.LocationTexDeActivatedErrands[i].Day;
		e = gs.LocationTexDeActivatedErrands[i].Errand;
		if (d < Days.Length && e < Days[d].Errands.Length)
			Days[d].Errands[e].DeActivateLocationTex();
	}
	log("P2Coop: client state day"@gs.CurrentDay@"done today"@gs.ErrandsCompletedToday
		@"completed ["$R.Completed$"] haters"@gs.CurrentHaters.Length@"wanted"@gs.CopsWantPlayer());
}

// The host's haters, with this player's own Revealed flags.
function ApplyHaters(string S)
{
	local GameState gs;
	local int i;
	local string Item;
	local array<string> Parts;

	gs = TheGameState;
	gs.CurrentHaters.Remove(0, gs.CurrentHaters.Length);
	while (S != "")
	{
		i = InStr(S, ";");
		if (i < 0)
			i = Len(S);
		Item = Left(S, i);
		S = Mid(S, i + 1);
		SplitString(Item, ",", Parts);
		if (Parts.Length < 4 || Parts[0] == "")
			continue;
		i = gs.CurrentHaters.Length;
		gs.CurrentHaters.Insert(i, 1);
		gs.CurrentHaters[i].ClassName = ToName(Parts[0]);
		gs.CurrentHaters[i].DesTex = ToName(Parts[1]);
		gs.CurrentHaters[i].PicTex = ToName(Parts[2]);
		gs.CurrentHaters[i].Comment = ToName(Parts[3]);
		if (InStr(default.SeenHaters, " " $ Parts[0] $ " ") >= 0)
			gs.CurrentHaters[i].Revealed = 1;
	}
}

function name ToName(string S)
{
	ParsedName = '';
	if (S != "" && S != "None")
		SetPropertyText("ParsedName", S);
	return ParsedName;
}

// Keep what the map has revealed for the next level's shadow game.
function Remember()
{
	local int i;
	local string S;

	if (TheGameState == None)
		return;
	default.SeenErrands = class'CoopReplicationInfo'.static.ErrandList(TheGameState.RevealedErrands);
	default.SeenLocations = class'CoopReplicationInfo'.static.ErrandList(TheGameState.RevealedLocationTex);
	S = default.SeenHaters;
	if (S == "")
		S = " ";
	for (i = 0; i < TheGameState.CurrentHaters.Length; i++)
		if (TheGameState.CurrentHaters[i].Revealed == 1 && InStr(S, " " $ TheGameState.CurrentHaters[i].ClassName $ " ") < 0)
			S = S $ TheGameState.CurrentHaters[i].ClassName $ " ";
	default.SeenHaters = S;
}

// Stock GetNewsTexture also counts the paper as read for an achievement; that is the host's.
function Texture GetNewsTexture()
{
	if (TheGameState.bIsApocalypse)
		return Texture(DynamicLoadObject(String(ApocalypseTex), class'Texture'));
	return GetCurrentDayBase().GetNewsTexture();
}

simulated function Destroyed()
{
	if (TheGameState != None)
		TheGameState.Destroy();
	if (xManager != None)
		xManager.Destroy();
	Super.Destroyed();
}
