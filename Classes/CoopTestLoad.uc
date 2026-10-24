//=============================================================================
// CoopTestLoad: loading a save, ?CoopTest=load on the host.
// Before: gives the client a shotgun, saves (slot 22), then gives it a pistol and the
//   leader loads slot 22 through the stock LoadGame. The clients are dropped by the load.
// After (a new test actor, spawned by CoopGame.PostLoadGame from the class defaults,
//   which outlive the load but are not in the save): the client reconnects by itself,
//   gets back its saved pawn (shotgun, no pistol), and the leader has the GameState.
//=============================================================================
class CoopTestLoad extends CoopTestBase;

const SaveSlot = 22;

// Carried across the load in the class defaults.
var bool bAwaitingLoad;
var string ClientName;
var int PassedBefore, FailedBefore;

var bool bAfterLoad;
var float LoadedTime;
var int Tries;
var vector ClientStart;

function PostBeginPlay()
{
	Super.PostBeginPlay();
	if (default.bAwaitingLoad)
	{
		bAfterLoad = true;
		Passed = default.PassedBefore;
		Failed = default.FailedBefore;
		default.bAwaitingLoad = false;
		LoadedTime = Level.TimeSeconds;
		log("P2CoopTest: after the load, waiting for"@default.ClientName);
		SetTimer(1.0, true);
	}
}

function RemoteJoined(PlayerController P)
{
	if (!bAfterLoad || P.PlayerReplicationInfo.PlayerName == default.ClientName)
		Super.RemoteJoined(P);
}

// After the load: give up if the client does not come back.
function Timer()
{
	if (Remote == None && Level.TimeSeconds - LoadedTime > 90)
	{
		Check("client-reconnected", false, "no"@default.ClientName@"within 90 s");
		Finish();
	}
}

state Running
{
Begin:
	while (Remote.Pawn == None)
		Sleep(0.5);
	Sleep(3.0);
	if (!bAfterLoad)
	{
		Give(Remote.Pawn, class'Inventory.ShotGunWeapon');
		Sleep(1.0);
		Check("save", CoopGame(Level.Game).ForceSave(SaveSlot), "slot"@SaveSlot);
		Give(Remote.Pawn, class'Inventory.PistolWeapon');
		default.bAwaitingLoad = true;
		default.ClientName = Remote.PlayerReplicationInfo.PlayerName;
		default.PassedBefore = Passed;
		default.FailedBefore = Failed;
		log("P2CoopTest: loading slot"@SaveSlot);
		CoopGame(Level.Game).LoadGame(SaveSlot, false);
		Stop;
	}

	Check("client-reconnected", true, Remote.PlayerReplicationInfo.PlayerName@"after"@(Level.TimeSeconds - LoadedTime)@"s");
	Check("leader-gamestate", CoopGame(Level.Game).TheGameState != None && Lead.Pawn != None && Lead.Pawn.Health > 0, "");
	Check("client-has-saved-item", Has(Remote.Pawn, class'Inventory.ShotGunWeapon'), "");
	Check("client-lost-unsaved-item", !Has(Remote.Pawn, class'Inventory.PistolWeapon'), "");
	Check("client-alive", Remote.Pawn.Health > 0, "health"@Remote.Pawn.Health);
	// The client may still be loading the level it just downloaded: ask again for a while.
	for (Tries = 0; Tries < 8 && !(bGotReport && bSawLeader); Tries++)
	{
		bGotReport = false;
		Remote.ClientTestLook(Lead.PlayerReplicationInfo.PlayerName);
		Sleep(2.0);
	}
	Check("client-sees-leader", bGotReport && bSawLeader && VSize(SeenLeaderLoc - Lead.Pawn.Location) < 64,
		"client"@SeenLeaderLoc@"server"@Lead.Pawn.Location);
	ClientStart = Remote.Pawn.Location;
	Remote.ClientTestDrive(6000, 1.5);
	Sleep(3.0);
	Check("client-moves-after-load", VSize(Remote.Pawn.Location - ClientStart) > 100,
		"moved"@VSize(Remote.Pawn.Location - ClientStart));
	Finish();
}

defaultproperties
{
	TestName="load"
}
