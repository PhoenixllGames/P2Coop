//=============================================================================
// CoopProbe: listen-server measurements written to the log, for test runs only, picked by the
// URL option ?CoopProbe=<scenario> (without it, it only logs the ControllerList):
//   join      log ControllerList and ping for 10 s after a join.
//   savelive  the host saves 5 s after the first join and keeps running: does a
//             save break connected clients, and can more clients join after it?
//   load      standalone: when the player logs in, load slot ?CoopLoadSlot=N the way
//             the game does (P2GameInfoSingle.LoadGame); the harness reads the log.
//             Not on a timer: the day-start map screen pauses a standalone game.
// ?CoopProbeClients=N waits for N joins (default 1); the scenario's clock then
// runs from the last join. Every scenario ends with "P2CoopProbe: DONE" and
// quits the host, because the engine log is buffered and the harness reads it
// after the host exits.
//=============================================================================
class CoopProbe extends Info;

var string Scenario;
var int Expected, Joined;
var float FirstJoinTime, JoinTime;
var bool bSaved;
var PlayerController Remote;

function PostBeginPlay()
{
	Super.PostBeginPlay();
	Scenario = CoopGame(Level.Game).URLOption("CoopProbe");
	if (Scenario == "")
		return;	// a real game: no measuring, and never quit the host
	Expected = Max(1, int(CoopGame(Level.Game).URLOption("CoopProbeClients")));
	log("P2CoopProbe: scenario"@Scenario@"clients"@Expected);
}

function LocalLoggedIn()
{
	if (Scenario != "load")
		return;
	log("P2CoopProbe: loading slot"@CoopGame(Level.Game).URLOption("CoopLoadSlot"));
	CoopGame(Level.Game).LoadGame(int(CoopGame(Level.Game).URLOption("CoopLoadSlot")), false);
}

function LogControllers(string Where)
{
	local Controller C;
	local int i;
	local string Kind;

	log("P2CoopProbe: ControllerList ("$Where$"):");
	for (C = Level.ControllerList; C != None; C = C.NextController)
	{
		if (PlayerController(C) == None)
			continue;
		if (NetConnection(PlayerController(C).Player) != None)
			Kind = "remote";
		else if (PlayerController(C).Player != None)
			Kind = "local";
		else
			Kind = "none";
		log("P2CoopProbe:   #"$i@C.Name@Kind@"pawn="$C.Pawn@"name="$C.PlayerReplicationInfo.PlayerName);
		i++;
	}
}

function string InventoryList(Pawn P)
{
	local Inventory Inv;
	local string S;
	local int n;

	if (P == None)
		return "-";
	for (Inv = P.Inventory; Inv != None && n < 40; Inv = Inv.Inventory)
	{
		S = S $ Inv.Class.Name $ ",";
		n++;
	}
	return n$":"$S;
}

function RemoteJoined(PlayerController P)
{
	if (Scenario == "")
		return;
	Remote = P;
	Joined++;
	JoinTime = Level.TimeSeconds;
	if (Joined == 1)
	{
		FirstJoinTime = JoinTime;
		SetTimer(1.0, true);
	}
	log("P2CoopProbe: join"@Joined$"/"$Expected@P.PlayerReplicationInfo.PlayerName@"saved before="$bSaved);
	if (CoopGame(Level.Game).Leader() != None)
		log("P2CoopProbe: leader inv="$InventoryList(CoopGame(Level.Game).Leader().Pawn));
}

function Timer()
{
	local float T;

	// The probe is saved with the level; after a load its remote player has no connection.
	if (Remote == None || Remote.PlayerReplicationInfo == None || Remote.Player == None)
	{
		log("P2CoopProbe: remote player gone");
		Finish();
		return;
	}
	T = Level.TimeSeconds - JoinTime;
	log("P2CoopProbe: t="$int(T)@"joined="$Joined@"ping="$Remote.PlayerReplicationInfo.Ping@"pawn="$Remote.Pawn
		@"state="$Remote.GetStateName()@"loc="$Remote.Pawn.Location@"health="$Remote.Pawn.Health
		@"inv="$InventoryList(Remote.Pawn));

	if (Scenario == "savelive" && !bSaved && Level.TimeSeconds - FirstJoinTime >= 5)
	{
		bSaved = true;
		log("P2CoopProbe: forcing a save with a client connected");
		log("P2CoopProbe: save result"@CoopGame(Level.Game).ForceSave(21));
	}
	if (Joined >= Expected && T >= 10 && (Scenario != "savelive" || bSaved))
		Finish();
	else if (Level.TimeSeconds - FirstJoinTime > 150)
	{
		log("P2CoopProbe: TIMEOUT waiting for"@Expected@"clients");
		Finish();
	}
}

function Finish()
{
	log("P2CoopProbe: DONE");
	SetTimer(0, false);
	ConsoleCommand("exit");
}
