//=============================================================================
// CoopTestLeaderDead: level changes the leader cannot simply take, ?CoopTest=leaderdead.
// Phase "leaderdead" (start map): the leader is dead (his respawn far off) and new haters wait
//   to be shown, and the *client* takes a real level exit (Telepad's SendPlayerLevelTransition).
//   The leader must respawn at once and take the group along with the GameState; the haters
//   map shows on the host (the stock code would hand the GameState to the client and call the
//   client's map again and again).
// Phase "leaderdead2" (next map): the game went on (same day, not a new game). Right after the
//   client rejoins, the leader takes a telepad: the level change waits for the client to settle
//   before the stock code runs, so the GameState stays the game's while it waits.
// Phase "leaderdead3": the game went on again.
//=============================================================================
class CoopTestLeaderDead extends CoopTestBase;

var string Phase, ClientName, CarryPhase;
var int StartDay;
var Pawn OldPawn;
var Telepad Pad;
var CoopGame G;

function PostBeginPlay()
{
	Super.PostBeginPlay();
	G = CoopGame(Level.Game);
	Phase = G.URLOption("CoopTest");
	StartDay = int(G.URLOption("CoopStartDay"));
	ClientName = G.URLOption("CoopClient");
	log("P2CoopTest: leaderdead phase"@Phase@"map"@CurrentMap());
}

function RemoteJoined(PlayerController P)
{
	if (ClientName == "" || P.PlayerReplicationInfo.PlayerName == ClientName)
		Super.RemoteJoined(P);
}

// Checks made after SetCarry, until the travel goes (CoopGame.TryPendingTravel adds the
// options then), count on the next map too.
function Check(string Name, bool bOk, string Detail)
{
	Super.Check(Name, bOk, Detail);
	if (CarryPhase != "")
		SetCarry(CarryPhase);
}

function SetCarry(string NextPhase)
{
	CarryPhase = NextPhase;
	G.TravelOptions = CarryOptions(NextPhase) $ "?CoopStartDay="$StartDay
		$ "?CoopClient="$Remote.PlayerReplicationInfo.PlayerName;
}

// The game went on across the level change: the leader brought the GameState.
function CheckGameWentOn()
{
	Check(Phase$"-gamestate", G.TheGameState != None && G.TheGameState.CurrentDay == StartDay,
		"day"@G.TheGameState.CurrentDay@"start day"@StartDay);
	Check(Phase$"-not-a-new-game", !G.bTesting, "the stock new-game path ran");
	Check(Phase$"-leader-alive", Lead.Pawn != None && Lead.Pawn.Health > 0, "pawn"@Lead.Pawn);
}

// Adds the first hate group of the week's errands, as finishing that errand would (the map
// shows new haters only if there are some). False if none was added.
function bool AddHater()
{
	local int d, e, k;
	local DayBase Day;
	local ErrandBase Errand;
	local ErrandGoal Goal;

	for (d = 0; d < G.Days.Length; d++)
	{
		Day = G.Days[d];
		for (e = 0; e < Day.Errands.Length; e++)
		{
			Errand = Day.Errands[e];
			for (k = 0; k < Errand.Goals.Length; k++)
			{
				Goal = Errand.Goals[k];
				if (Goal != None && Goal.HateClass != '' && Goal.HateClass != 'None')
				{
					G.TheGameState.AddHaters(Goal.HateClass, Goal.HateDesTex, Goal.HatePicTex, Goal.HateComment);
					log("P2CoopTest: new haters"@Goal.HateClass@"added"@G.TheGameState.bAddedNewHaters);
					return G.TheGameState.bAddedNewHaters;
				}
			}
		}
	}
	return false;
}

// Ends the screens a level change shows on the host and the client.
function EndScreens()
{
	Remote.ClientTestEndScreens();
	if (P2Player(Lead).MyMapScreen != None && P2Player(Lead).MyMapScreen.IsRunning())
		P2Player(Lead).MyMapScreen.bPlayerWantsToEnd = true;
}

state Running
{
Begin:
	if (Phase == "leaderdead2")
	{
		// The client has only just rejoined.
		Sleep(0.5);
		CheckGameWentOn();
		Pad = FindPad("");
		SetCarry("leaderdead3");
		log("P2CoopTest: the leader takes"@Pad@Pad.URL@"right after the client rejoined");
		G.SendPlayerTo(Lead, Pad.URL);
		Check("travel-waits-before-stock-code", G.PendingSendURL != "" && G.TheGameState != None
			&& Lead.Pawn != None && Lead.Pawn.FindInventoryType(G.GameStateClass) == None,
			"pending"@G.PendingSendURL@"gamestate"@G.TheGameState);
		Sleep(1.0);
		Check("level-runs-with-gamestate-while-waiting", G.PendingSendURL != "" && G.TheGameState != None, "");
		Stop;	// the travel goes when the client has settled
	}
	while (Remote.Pawn == None || Lead.Pawn == None)
		Sleep(0.5);
	Sleep(2.0);
	if (Phase == "leaderdead3")
	{
		CheckGameWentOn();
		Finish();
		Stop;
	}

	// leaderdead: the leader dies, the client leaves through a telepad with new haters to show
	StartDay = G.TheGameState.CurrentDay;
	Pad = FindPad("");
	if (Pad == None)
	{
		Check("telepad-found", false, "no telepad on"@CurrentMap());
		Finish();
		Stop;
	}
	OldPawn = Lead.Pawn;
	Kill(Lead.Pawn);
	Sleep(1.0);
	CoopPlayer(Lead).RespawnTime = Level.TimeSeconds + 300;
	Check("leader-dead", Lead.Pawn == None || Lead.Pawn.Health <= 0, "pawn"@Lead.Pawn);
	Check("new-haters-to-show", AddHater(), "haters"@G.TheGameState.CurrentHaters.Length);
	SetCarry("leaderdead2");
	log("P2CoopTest: client"@Remote@"leaves through"@Pad@Pad.URL@"while the leader is dead");
	G.SendPlayerLevelTransition(Remote, Pad.URL, true);
	Check("leader-respawned-to-travel", Lead.Pawn != None && Lead.Pawn != OldPawn && Lead.Pawn.Health > 0,
		"pawn"@Lead.Pawn);
	Check("client-did-not-take-gamestate", Remote.Pawn != None && Remote.Pawn.FindInventoryType(G.GameStateClass) == None, "");
	// The haters map shows on the host (perhaps after the settle wait); end it so the group goes.
	for (EndPresses = 0; EndPresses < 40; EndPresses++)
	{
		EndScreens();
		Sleep(1.0);
	}
	Check("level-changed", false, "still on"@CurrentMap()@"after 40 s");
	Finish();
}

defaultproperties
{
	TestName="leaderdead"
}
