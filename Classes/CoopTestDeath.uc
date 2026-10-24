//=============================================================================
// CoopTestDeath: death and respawn, ?CoopTest=death?CoopRespawnDelay=3 on the host.
//   client dies  -> Dead on the server, no reload; after the delay a new living pawn
//                   next to the leader with the default kit, and the client sees it
//   leader dies  -> same, next to the client (the stock game would load the last save)
// That this actor still runs after each death shows that no load happened.
//=============================================================================
class CoopTestDeath extends CoopTestBase;

var Pawn OldPawn;
var float Dist;

function Kill(Pawn P)
{
	log("P2CoopTest: killing"@P@"health"@P.Health);
	P.TakeDamage(10000, None, P.Location, vect(0,0,0), class'BaseFX.BulletDamage');
	if (P.Health > 0)
		P.Died(None, class'BaseFX.BulletDamage', P.Location);
}

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
	Finish();
}

defaultproperties
{
	TestName="death"
}
