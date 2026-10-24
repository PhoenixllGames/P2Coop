//=============================================================================
// CoopTestCombat: see, move and shoot, started with ?CoopTest=combat on the host.
// With one client joined it checks, through the client's own input path:
//   see          the client sees the leader's pawn where the server has it, and NPCs
//   leader moves the client sees the leader's pawn move
//   client moves forward input on the client moves its pawn on the server
//   arm          both switch to a pistol (client: "GetWeapon" on its machine)
//   host hits    the leader shoots the client: the client's health drops
//   client hits  the client shoots the leader (Fire() on its machine): health drops
//=============================================================================
class CoopTestCombat extends CoopTestBase;

const DriveForward = 6000.0;

// State code cannot have locals.
var vector LeaderStart, ClientStart;
var int HealthBefore, i;

state Running
{
Begin:
	while (Remote.Pawn == None)
		Sleep(0.5);
	Sleep(3.0);
	log("P2CoopTest: start, leader"@Lead@"state"@Lead.GetStateName()@"client state"@Remote.GetStateName());

	// see
	bGotReport = false;
	Remote.ClientTestLook(Lead.PlayerReplicationInfo.PlayerName);
	Sleep(2.0);
	Check("see-report", bGotReport, "");
	Check("see-leader", bSawLeader && VSize(SeenLeaderLoc - Lead.Pawn.Location) < 64,
		"client"@SeenLeaderLoc@"server"@Lead.Pawn.Location);
	Check("see-npcs", SeenNPCs > 0, "npcs="$SeenNPCs);
	Check("client-pawn-match", VSize(ClientLoc - Remote.Pawn.Location) < 64,
		"client"@ClientLoc@"server"@Remote.Pawn.Location);

	// leader moves (host's own input path, it is local)
	LeaderStart = Lead.Pawn.Location;
	if (CoopPlayer(Lead) != None)
		CoopPlayer(Lead).ClientTestDrive(DriveForward, 1.5);
	Sleep(2.5);
	bGotReport = false;
	Remote.ClientTestLook(Lead.PlayerReplicationInfo.PlayerName);
	Sleep(2.0);
	Check("leader-moves-server", VSize(Lead.Pawn.Location - LeaderStart) > 100,
		"moved"@VSize(Lead.Pawn.Location - LeaderStart));
	Check("leader-moves-client", bGotReport && VSize(SeenLeaderLoc - LeaderStart) > 100
		&& VSize(SeenLeaderLoc - Lead.Pawn.Location) < 64,
		"client sees"@SeenLeaderLoc@"server"@Lead.Pawn.Location);

	// client moves (its forward input, replicated through ServerMove)
	ClientStart = Remote.Pawn.Location;
	Remote.ClientTestDrive(DriveForward, 1.5);
	Sleep(3.0);
	Check("client-moves", VSize(Remote.Pawn.Location - ClientStart) > 100,
		"moved"@VSize(Remote.Pawn.Location - ClientStart));

	// arm both with a pistol
	Give(Lead.Pawn, class'Inventory.PistolWeapon');
	Give(Remote.Pawn, class'Inventory.PistolWeapon');
	// The new weapon reaches the client's inventory chain a moment later; a switch sent in
	// the same tick finds nothing.
	Sleep(2.0);
	// Not "SwitchWeapon 2": P2's group cycling picked the matches on the client.
	Lead.ConsoleCommand("GetWeapon Inventory.PistolWeapon");
	Remote.ClientTestCommand("GetWeapon Inventory.PistolWeapon");
	Sleep(3.0);
	Check("arm-leader", PistolWeapon(Lead.Pawn.Weapon) != None, "weapon"@Lead.Pawn.Weapon);
	Check("arm-client", PistolWeapon(Remote.Pawn.Weapon) != None, "weapon"@Remote.Pawn.Weapon);

	// leader shoots the client
	HealthBefore = Remote.Pawn.Health;
	for (i = 0; i < 3; i++)
	{
		Lead.SetRotation(AimAt(Lead.Pawn, Remote.Pawn));
		Lead.Fire(0);
		Sleep(0.8);
	}
	Sleep(1.0);
	log("P2CoopTest: leader ammo after firing"@Lead.Pawn.Weapon.AmmoType.AmmoAmount);
	Check("host-hits-client", Remote.Pawn != None && Remote.Pawn.Health < HealthBefore,
		"health"@HealthBefore@"->"@Remote.Pawn.Health);

	// client shoots the leader
	HealthBefore = Lead.Pawn.Health;
	for (i = 0; i < 3; i++)
	{
		Remote.ClientTestAim(AimAt(Remote.Pawn, Lead.Pawn));
		Sleep(0.3);
		Remote.ClientTestFire();
		Sleep(0.8);
	}
	Sleep(1.0);
	log("P2CoopTest: client ammo after firing (server copy)"@Remote.Pawn.Weapon.AmmoType.AmmoAmount);
	Check("client-hits-host", Lead.Pawn != None && Lead.Pawn.Health < HealthBefore,
		"health"@HealthBefore@"->"@Lead.Pawn.Health);

	Finish();
}

defaultproperties
{
	TestName="combat"
}
