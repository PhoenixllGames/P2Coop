//=============================================================================
// CoopTestDeath: death and respawn, ?CoopTest=death?CoopRespawnDelay=3 on the host.
//   client dies  -> Dead on the server, no reload; after the delay a new living pawn
//                   next to the leader with the default kit, and the client sees it
//   leader dies  -> same, next to the client (the stock game would load the last save)
//   fire while dead does not skip the delay; with everybody dead a client's fire does not
//   spawn him at the map's start (the leader's would load the last save: not pressed here)
// That this actor still runs after each death shows that no load happened.
//=============================================================================
class CoopTestDeath extends CoopTestBase;

var Pawn OldPawn;
var float Dist;

state Running
{
Begin:
	while (Remote.Pawn == None)
		Sleep(0.5);
	Sleep(3.0);

	// client dies
	OldPawn = Remote.Pawn;
	Kill(Remote.Pawn);
	Sleep(1.0);
	Check("client-dead", Remote.IsInState('Dead') || OldPawn.Health <= 0,
		"state"@Remote.GetStateName()@"health"@OldPawn.Health);
	Check("client-respawn-scheduled", Remote.bRespawning, "");
	// Fire while dead (what the client's press sends): ServerRestartPlayer must wait for the delay.
	Sleep(0.5);
	Remote.ServerReStartPlayer();
	Check("fire-does-not-skip-respawn-delay", Remote.Pawn == None || Remote.Pawn == OldPawn || Remote.Pawn.Health <= 0,
		"pawn"@Remote.Pawn@"after"@(Level.TimeSeconds - (Remote.RespawnTime - CoopGame(Level.Game).RespawnDelay()))@"s");
	Sleep(CoopGame(Level.Game).RespawnDelay() + 3.0);
	Check("client-respawned", Remote.Pawn != None && Remote.Pawn != OldPawn && Remote.Pawn.Health > 0,
		"pawn"@Remote.Pawn@"health"@Remote.Pawn.Health);
	Dist = VSize(Remote.Pawn.Location - Lead.Pawn.Location);
	Check("client-respawned-near-leader", Dist < 800, "distance"@Dist);
	Check("client-respawned-with-kit", Has(Remote.Pawn, class'Inventory.HandsWeapon'), "");
	Check("client-state-after", Remote.IsInState('PlayerWalking'), "state"@Remote.GetStateName());
	bGotReport = false;
	Remote.ClientTestLook(Lead.PlayerReplicationInfo.PlayerName);
	Sleep(2.0);
	Check("client-sees-own-new-pawn", bGotReport && VSize(ClientLoc - Remote.Pawn.Location) < 64,
		"client"@ClientLoc@"server"@Remote.Pawn.Location);

	// leader dies while the client lives
	OldPawn = Lead.Pawn;
	Kill(Lead.Pawn);
	Sleep(1.0);
	Check("leader-dead", Lead.IsInState('Dead') || OldPawn.Health <= 0, "state"@Lead.GetStateName());
	// What pressing fire while dead does (after the freeze): must not load the save while the
	// client lives. GameOverRestart exists only in the Dead state, so go through exec.
	Sleep(1.5);
	Lead.ConsoleCommand("GameOverRestart");
	Sleep(CoopGame(Level.Game).RespawnDelay() + 1.5);
	Check("leader-respawned", Lead.Pawn != None && Lead.Pawn != OldPawn && Lead.Pawn.Health > 0,
		"pawn"@Lead.Pawn@"health"@Lead.Pawn.Health);
	Dist = VSize(Remote.Pawn.Location - Lead.Pawn.Location);
	Check("leader-respawned-near-client", Dist < 800, "distance"@Dist);
	Check("no-reload", true, "the test actor survived both deaths");

	// everybody dies: no respawns, and the client's fire does not spawn him at the start
	Sleep(1.0);
	OldPawn = Remote.Pawn;
	Kill(Remote.Pawn);
	Sleep(0.5);
	Kill(Lead.Pawn);
	Sleep(CoopGame(Level.Game).RespawnDelay() + 1.5);
	Check("all-dead-no-respawn", Remote.Pawn == None || Remote.Pawn.Health <= 0, "pawn"@Remote.Pawn);
	Remote.ServerReStartPlayer();
	Sleep(0.5);
	Check("all-dead-client-fire-does-not-spawn", Remote.Pawn == None || Remote.Pawn.Health <= 0,
		"pawn"@Remote.Pawn@"state"@Remote.GetStateName());
	Finish();
}

defaultproperties
{
	TestName="death"
}
