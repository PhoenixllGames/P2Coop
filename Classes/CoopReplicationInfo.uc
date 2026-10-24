//=============================================================================
// CoopReplicationInfo: the parts of the host's GameState that clients show.
//
// The map, the newspaper and the HUD's wanted meter read Level.Game and its GameState, and a
// client has neither. The server packs what they need into replicated strings; on each client
// the copy builds a CoopShadowGame (a game info that is not Level.Game) with a GameState filled
// from them. CoopMapScreen, CoopNewsScreen and CoopHUD use it when Level.Game is None.
//
// Errand lists are "day.errand day.errand ...", haters "Class,DesTex,PicTex,Comment;...".
// Which errands and haters a player has already seen written on his map is his own (MapScreen
// marks them), so it stays on the client (CoopShadowGame) and is not sent.
//=============================================================================
class CoopReplicationInfo extends ReplicationInfo;

var int CurrentDay;
var bool bIsApocalypse;
var float CopRadioTime;
var string Completed, Activated, DeActivated, LocActivated, LocDeActivated, Haters;
var int Serial;				// bumped by the server on every change

var float NextUpdate;		// server
var int AppliedSerial;		// client
var CoopShadowGame Shadow;	// client
var bool bSpawnFailed;

const UpdateInterval = 0.5;
const RadioStep = 0.5;		// CopRadioTime changes smaller than this are not sent

replication
{
	reliable if (Role == ROLE_Authority)
		CurrentDay, bIsApocalypse, CopRadioTime, Completed, Activated, DeActivated,
		LocActivated, LocDeActivated, Haters, Serial;
}

// The client's shadow game, or None (no copy yet, or Level.Game exists here).
static function CoopShadowGame ShadowFor(Actor A)
{
	local CoopReplicationInfo R;

	if (A == None || A.Level.Game != None)
		return None;
	foreach A.DynamicActors(class'CoopReplicationInfo', R)
		return R.Shadow;
	return None;
}

simulated function Tick(float DeltaTime)
{
	if (Role == ROLE_Authority)
	{
		if (Level.TimeSeconds >= NextUpdate)
		{
			NextUpdate = Level.TimeSeconds + UpdateInterval;
			ReadGameState();
		}
	}
	else if (Level.NetMode == NM_Client)
	{
		if (Shadow == None)
		{
			Shadow = Spawn(class'CoopShadowGame');
			if (Shadow != None)
				Shadow.Init();
			else if (!bSpawnFailed)
			{
				bSpawnFailed = true;
				log("P2Coop: could not spawn the client's shadow game");
			}
			AppliedSerial = -1;
		}
		if (Shadow != None && AppliedSerial != Serial && Completed != "-")
		{
			AppliedSerial = Serial;
			Shadow.Apply(self);
		}
	}
}

simulated function PostNetBeginPlay()
{
	Super.PostNetBeginPlay();
	log("P2Coop: state info"@self@"role"@Role@"netmode"@Level.NetMode);
}

simulated function Destroyed()
{
	if (Shadow != None)
	{
		Shadow.Remember();
		Shadow.Destroy();
	}
	Super.Destroyed();
}

// Server: copy the GameState into the replicated fields.
function ReadGameState()
{
	local GameState gs;
	local bool bChanged;
	local string S;
	local int i;

	if (P2GameInfoSingle(Level.Game) == None || P2GameInfoSingle(Level.Game).TheGameState == None)
		return;
	gs = P2GameInfoSingle(Level.Game).TheGameState;

	if (CurrentDay != gs.CurrentDay || bIsApocalypse != gs.bIsApocalypse)
	{
		CurrentDay = gs.CurrentDay;
		bIsApocalypse = gs.bIsApocalypse;
		bChanged = true;
	}
	if (Abs(CopRadioTime - gs.CopRadioTime) >= RadioStep || (CopRadioTime != gs.CopRadioTime && gs.CopRadioTime <= 0))
	{
		CopRadioTime = gs.CopRadioTime;
		bChanged = true;
	}
	bChanged = SetList(Completed, ErrandList(gs.CompletedErrands)) || bChanged;
	bChanged = SetList(Activated, ErrandList(gs.ActivatedErrands)) || bChanged;
	bChanged = SetList(DeActivated, ErrandList(gs.DeActivatedErrands)) || bChanged;
	bChanged = SetList(LocActivated, ErrandList(gs.LocationTexActivatedErrands)) || bChanged;
	bChanged = SetList(LocDeActivated, ErrandList(gs.LocationTexDeActivatedErrands)) || bChanged;
	for (i = 0; i < gs.CurrentHaters.Length; i++)
		S = S $ gs.CurrentHaters[i].ClassName $ "," $ gs.CurrentHaters[i].DesTex $ ","
			$ gs.CurrentHaters[i].PicTex $ "," $ gs.CurrentHaters[i].Comment $ ";";
	bChanged = SetList(Haters, S) || bChanged;
	if (bChanged)
		Serial++;
}

function bool SetList(out string Field, string Value)
{
	if (Field == Value)
		return false;
	Field = Value;
	return true;
}

static function string ErrandList(array<GameState.SErrand> Errands)
{
	local string S;
	local int i;

	for (i = 0; i < Errands.Length; i++)
		S = S $ Errands[i].Day $ "." $ Errands[i].Errand $ " ";
	return S;
}

// "1.2 0.3 " -> errand entries.
static function ParseErrands(string S, out array<GameState.SErrand> Errands)
{
	local int i, Dot;
	local string Item;

	Errands.Remove(0, Errands.Length);
	while (S != "")
	{
		i = InStr(S, " ");
		if (i < 0)
			i = Len(S);
		Item = Left(S, i);
		S = Mid(S, i + 1);
		Dot = InStr(Item, ".");
		if (Dot <= 0)
			continue;
		Errands.Insert(Errands.Length, 1);
		Errands[Errands.Length - 1].Day = int(Left(Item, Dot));
		Errands[Errands.Length - 1].Errand = int(Mid(Item, Dot + 1));
	}
}

defaultproperties
{
	Completed="-"
	NetUpdateFrequency=4
	RemoteRole=ROLE_SimulatedProxy
}
