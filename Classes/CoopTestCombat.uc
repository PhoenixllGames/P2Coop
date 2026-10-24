//=============================================================================
// CoopTestCombat: see, move and shoot, started with ?CoopTest=combat on the host.
// With one client joined it checks, through the client's own input path:
//   see          the client sees the leader's pawn where the server has it, and NPCs
//   leader moves the client sees the leader's pawn move
//   client moves forward input on the client moves its pawn on the server
//   arm          both switch to a pistol (client: "GetWeapon" on its machine)
//   host hits    the leader shoots the client: the client's health drops
//   client hits  the client shoots the leader (Fire() on its machine): health drops
//   corpse       an NPC killed on the server lies in the same place on the client
//=============================================================================
class CoopTestCombat extends CoopTestBase;

const DriveForward = 6000.0;

// State code cannot have locals.
var vector LeaderStart, ClientStart;
var int HealthBefore, i;
var Pawn Victim, Brought;
var bool bPickVictim;	// the client's next corpse report picks the victim (ClientCamera)

// The living NPC nearest to Spot, within Radius.
function Pawn NPCAt(vector Spot, float Radius)
{
	local Pawn P, Best;

	foreach DynamicActors(class'Pawn', P)
		if (P.Health > 0 && P.PlayerReplicationInfo == None && VSize(P.Location - Spot) < Radius
			&& (Best == None || VSize(P.Location - Spot) < VSize(Best.Location - Spot)))
			Best = P;
	return Best;
}

// Why no victim was found at Spot: the server's NPC nearest to it, living or not, and the nearest
// living one.
function string NearestNPC(vector Spot)
{
	local Pawn P, Any, Alive;
	local string S;

	foreach DynamicActors(class'Pawn', P)
		if (P.PlayerReplicationInfo == None)
		{
			if (Any == None || VSize(P.Location - Spot) < VSize(Any.Location - Spot))
				Any = P;
			if (P.Health > 0 && (Alive == None || VSize(P.Location - Spot) < VSize(Alive.Location - Spot)))
				Alive = P;
		}
	if (Any == None)
		return "the server has no NPC";
	S = "the server's nearest NPC"@Any@"is"@int(VSize(Any.Location - Spot))@"away at"@Any.Location@"health"@Any.Health;
	if (Alive != None && Alive != Any)
		S = S $ "; the nearest living one" @ Alive @ "is" @ int(VSize(Alive.Location - Spot)) @ "away at" @ Alive.Location;
	return S;
}

// The client's report of the NPC nearest to him (ClientTestCorpse) picks the victim: the server's
// living NPC at that spot, killed right then. A running bystander covers about 400 units a
// second, so a second later the server's NPC was no longer where the client had it.
function ClientCamera(CoopPlayer P, vector Loc, string StateName)
{
	local float Speed;
	local bool bSeen;

	Super.ClientCamera(P, Loc, StateName);
	if (!bPickVictim || P != Remote)
		return;
	bPickVictim = false;
	if (StateName != "no-corpse")
		Victim = NPCAt(Loc, 200);
	if (Victim == None)
	{
		log("P2CoopTest: no NPC of the client's found on the server near"@Loc@StateName$";"@NearestNPC(Loc));
		return;
	}
	Speed = VSize(Victim.Velocity);
	bSeen = FastTrace(Victim.Location, Remote.Pawn.Location + Remote.Pawn.EyePosition());
	// Only one the client sees stays his: a pawn out of his sight stops being relevant to him, and
	// some seconds later (the engine's relevancy timeout) his copy is gone, so the corpse check would
	// compare the server's corpse with another NPC of his. One out of his sight is brought to him.
	if (!bSeen)
	{
		log("P2CoopTest: the client's nearest NPC"@Victim@"at"@Victim.Location@"is out of his sight, not killed");
		Victim = None;
		return;
	}
	Victim.Died(Lead, class'BulletDamage', Victim.Location);
	log("P2CoopTest: killed"@Victim@"at"@Victim.Location@"client had it at"@Loc
		@"("$int(VSize(Victim.Location - Loc))@"apart, speed"@int(Speed)$", in the client pawn's sight)");
}

// The nearest living person, put in front of the client: one the client will have (a hidden one
// is never sent to him).
function Pawn BringNPC()
{
	local Pawn P, Best;
	local vector Dir;
	local int n;

	foreach DynamicActors(class'Pawn', P)
		if (P.Health > 0 && P.PlayerReplicationInfo == None && P2MoCapPawn(P) != None && !P.bHidden
			&& (Best == None || VSize(P.Location - Remote.Pawn.Location) < VSize(Best.Location - Remote.Pawn.Location)))
			Best = P;
	if (Best == None)
		return None;
	Dir = vector(Remote.Pawn.Rotation);
	Dir.Z = 0;
	Dir = Normal(Dir);
	for (n = 0; n < 4; n++)
	{
		if (Best.SetLocation(Remote.Pawn.Location + 200 * Dir + vect(0,0,10)))
			return Best;
		Dir = Dir cross vect(0,0,1);
	}
	return None;
}

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

	// client moves (its forward input, replicated through ServerMove), less far than the leader did:
	// he started 70 units behind him. Driven as long, he ran into the leader's pawn, and in the runs
	// where he got 652 units instead of 605 neither hit the other below.
	ClientStart = Remote.Pawn.Location;
	Remote.ClientTestDrive(DriveForward, 1.0);
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
	log("P2CoopTest: leader at"@Lead.Pawn.Location@"client at"@Remote.Pawn.Location
		@"apart"@int(VSize(Lead.Pawn.Location - Remote.Pawn.Location)));

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

	// A dead NPC lies in the same place for everyone (the host's ragdoll, CoopRagdollSync). The
	// victim is one the client has (an NPC is replicated only while relevant to him): the NPC
	// nearest to the client on his machine, found on the server by its position as his report
	// comes in (ClientCamera).
	Victim = None;
	bGotCamera = false;
	bPickVictim = true;
	Remote.ClientTestCorpse(Remote.Pawn.Location);
	Sleep(1.0);
	bPickVictim = false;
	if (Victim == None)
	{
		// The client's nearest one has moved on the server since he last got it (or is an old
		// copy of someone out of his relevancy, or is out of his sight): one is brought to him.
		log("P2CoopTest: no NPC of the client's near"@ClientCam@ClientState@"- bringing one");
		Brought = BringNPC();
		if (Brought != None)
		{
			log("P2CoopTest: brought"@Brought@"to"@Brought.Location);
			Remote.ClientTestAim(rotator(Brought.Location - Remote.Pawn.Location));
			// He gets it at a net update once it is relevant to him: ask until he has it (5 s at most).
			i = 0;
			do
			{
				Sleep(0.5);
				bGotCamera = false;
				bPickVictim = true;
				Remote.ClientTestCorpse(Brought.Location);
				Sleep(0.5);
				bPickVictim = false;
				i++;
			} until (i >= 5 || Victim != None);
		}
	}
	if (Victim != None)
	{
		Sleep(4.0);
		bGotCamera = false;
		Remote.ClientTestCorpse(Victim.Location);
		Sleep(1.0);
		Check("npc-corpse-same-place", Victim != None && bGotCamera && VSize(ClientCam - Victim.Location) < 64,
			"server"@Victim.Location@"client"@ClientCam@ClientState@"server physics"@Victim.Physics);
	}
	else
		Check("npc-corpse-same-place", false, "no NPC of the client's found on the server near"@ClientCam@ClientState
			@"(report received:"@bGotCamera$")");
	Finish();
}

defaultproperties
{
	TestName="combat"
}
