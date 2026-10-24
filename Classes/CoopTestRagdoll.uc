//=============================================================================
// CoopTestRagdoll: a ragdoll lies the same for everyone, ?CoopTest=ragdoll on the host.
//   A: an NPC in front of both players is killed; the bones' world positions on the host and on
//      the client are compared while it falls and at rest, then after it is blown up again.
//   B: an NPC whom the host has never rendered is killed out of the host's view while the client
//      looks at him (one far from the host where he stands, or else one behind the host): the body
//      must ragdoll, stay on the ground, read its bones where they are and match on the client.
//   C: the client goes far away (the body leaves his relevancy) and comes back: the body he gets
//      anew must have the current pose.
//   An animal (no ragdoll, a death animation) must lie in the same place.
//   D: one person of each other human body (female, fat, big, mini) rests the same (a mini one
//      dies with its animation).
//=============================================================================
class CoopTestRagdoll extends CoopTestBase;

var Pawn Victim, VictimB, Animal;
var string ClientBones, Before;
var bool bGotBones;
var float Worst;
var vector Front, ClientHome, Side, StartLoc, BSpot;
var rotator HostRot;
var int SettleTries;
var NavigationPoint FarSpot;
var int TypeNum;		// D: the body type being tried
var Pawn TypeVictim;

function ClientBonesReport(CoopPlayer P, string Bones)
{
	if (P != Remote)
		return;
	bGotBones = true;
	ClientBones = Bones;
}

// "x,y,z;x,y,z;..." of the compared bones (every third of the CoopRagdollSync bone list), without
// those of the lost limbs (SeverBits): a bone shrunk away has no place to compare.
static function string BonePositions(Pawn P, int SeverBits)
{
	local int i;
	local vector V;
	local string S;

	for (i = 0; i < class'CoopRagdollSync'.static.BoneCount(); i += 3)
	{
		if (class'CoopRagdollSync'.static.BoneHidden(i, SeverBits))
			continue;
		V = P.GetBoneCoords(class'CoopRagdollSync'.static.BoneName(i)).Origin;
		S = S $ int(V.X) $ "," $ int(V.Y) $ "," $ int(V.Z) $ ";";
	}
	return S;
}

// The host's bone positions of P.
function string HostBones(Pawn P)
{
	return BonePositions(P, class'CoopRagdollSync'.static.SeverBits(P));
}

// The next "a,b,c" group of S (up to the ";"), removed from S, as a vector.
static function bool NextVector(out string S, out vector V)
{
	local int i;
	local string Item;

	if (S == "")
		return false;
	i = InStr(S, ";");
	if (i < 0)
		i = Len(S);
	Item = Left(S, i);
	S = Mid(S, i + 1);
	i = InStr(Item, ",");
	if (i < 0)
		return false;
	V.X = float(Left(Item, i));
	Item = Mid(Item, i + 1);
	i = InStr(Item, ",");
	if (i < 0)
		return false;
	V.Y = float(Left(Item, i));
	V.Z = float(Mid(Item, i + 1));
	return true;
}

// Largest distance between matching bones of two BonePositions strings (-1: they don't match up).
static function float BoneGap(string A, string B)
{
	local vector VA, VB;
	local float Gap;
	local int n;

	while (NextVector(A, VA))
	{
		if (!NextVector(B, VB))
			return -1;
		Gap = FMax(Gap, VSize(VA - VB));
		n++;
	}
	if (n < 2)
		return -1;
	return Gap;
}

// How far the compared bones reach from the pelvis: about 0 for a collapsed skeleton.
static function float Spread(Pawn P)
{
	local string S;
	local vector Pelvis, V;
	local float Reach;

	S = BonePositions(P, 0);
	if (!NextVector(S, Pelvis))
		return 0;
	while (NextVector(S, V))
		Reach = FMax(Reach, VSize(V - Pelvis));
	return Reach;
}

// How far the host reads the pelvis bone from the pawn (a ragdoll's location is its pelvis): a
// skeleton not brought up to date reads it somewhere else.
static function float PelvisOff(Pawn P)
{
	return VSize(P.GetBoneCoords(class'CoopRagdollSync'.static.BoneName(0)).Origin - P.Location);
}

// True when P (its location and bones) stayed within 2 units since the last call.
function bool Settled(Pawn P)
{
	local string Now;
	local bool bSame;

	Now = int(P.Location.X) $ "," $ int(P.Location.Y) $ "," $ int(P.Location.Z) $ ";" $ HostBones(P);
	bSame = BoneGap(Before, Now) >= 0 && BoneGap(Before, Now) < 2;
	Before = Now;
	return bSame;
}

function Pawn NPCAt(vector Spot, float Radius)
{
	local Pawn P, Best;

	foreach DynamicActors(class'Pawn', P)
		if (P.Health > 0 && P.PlayerReplicationInfo == None && P2MoCapPawn(P) != None
			&& VSize(P.Location - Spot) < Radius
			&& (Best == None || VSize(P.Location - Spot) < VSize(Best.Location - Spot)))
			Best = P;
	return Best;
}

// A living person the host has never rendered.
function Pawn UnrenderedNPC()
{
	local Pawn P;

	foreach DynamicActors(class'Pawn', P)
		if (P.Health > 0 && P.PlayerReplicationInfo == None && P2MoCapPawn(P) != None && P != Victim
			&& P.LastRenderTime <= 0)
			return P;
	return None;
}

// A living person the host has never rendered, far from him, with a path node near him in sight
// (also from eye height: a pawn is relevant to a client who sees it) for the client to stand on
// (BSpot).
function Pawn FarUnrenderedNPC()
{
	local Pawn P;
	local NavigationPoint N;

	foreach DynamicActors(class'Pawn', P)
		if (P.Health > 0 && P.PlayerReplicationInfo == None && P2MoCapPawn(P) != None && P != Victim
			&& P.LastRenderTime <= 0 && VSize(P.Location - Lead.Pawn.Location) > 2000)
			foreach AllActors(class'NavigationPoint', N)
				if (PathNode(N) != None && VSize(N.Location - P.Location) > 150 && VSize(N.Location - P.Location) < 500
					&& FastTrace(N.Location, P.Location) && FastTrace(N.Location + vect(0,0,80), P.Location))
				{
					BSpot = N.Location + vect(0,0,20);
					return P;
				}
	return None;
}

static function string TypeName(int Type)
{
	switch (Type)
	{
		case 0: return "female";
		case 1: return "fat";
		case 2: return "big";
		case 3: return "mini";
	}
	return "";
}

// A stock person with that body (mesh Fem_, Fat_, Big_, Mini_).
static function string TypeClass(int Type)
{
	switch (Type)
	{
		case 0: return "People.Librarian_AFW";
		case 1: return "People.JunkyardGuy";
		case 2: return "BasePeople.SWAT";
		case 3: return "People.Gary";
	}
	return "";
}

// A person of body Type, with his AI, near Spot.
function Pawn SpawnPerson(int Type, vector Spot)
{
	local class<Pawn> PClass;
	local Pawn P;
	local int i;

	PClass = class<Pawn>(DynamicLoadObject(TypeClass(Type), class'Class'));
	if (PClass == None)
		return None;
	for (i = 0; i < 4 && P == None; i++)
		P = Spawn(PClass, , , Spot + 60 * i * Side + vect(0,0,30), HostRot + rot(0,32768,0));
	if (P == None)
		return None;
	if (P.Controller == None && P.ControllerClass != None)
		P.Controller = Spawn(P.ControllerClass);
	if (P.Controller != None)
		P.Controller.Possess(P);
	return P;
}

function Pawn NearestAnimal(vector Spot)
{
	local Pawn P, Best;

	foreach DynamicActors(class'Pawn', P)
		if (P.Health > 0 && AnimalPawn(P) != None
			&& (Best == None || VSize(P.Location - Spot) < VSize(Best.Location - Spot)))
			Best = P;
	return Best;
}

// The nearest path node more than 3000 units from Spot: out of a body's relevancy.
function NavigationPoint FarSpotFrom(vector Spot)
{
	local NavigationPoint N, Best;

	foreach AllActors(class'NavigationPoint', N)
		if (PathNode(N) != None && VSize(N.Location - Spot) > 3000
			&& (Best == None || VSize(N.Location - Spot) < VSize(Best.Location - Spot)))
			Best = N;
	return Best;
}

// An animal's Died does nothing while it has health left.
function Kill(Pawn P)
{
	P.Health = 0;
	P.Died(Lead, class'BulletDamage', P.Location);
}

// The gap between the host's bones of P and the client's last report.
function float ClientGap(Pawn P)
{
	Worst = BoneGap(HostBones(P), ClientBones);
	log("P2CoopTest: gap"@Worst@P@"host"@HostBones(P)@"client"@ClientBones);
	return Worst;
}

function string Describe(Pawn P)
{
	if (P == None)
		return "none";
	return P@"loc"@P.Location@"phys"@P.Physics@"render"@P.LastRenderTime@"bones"@HostBones(P);
}

state Running
{
Begin:
	while (Remote.Pawn == None || Lead.Pawn == None)
		Sleep(0.5);
	Sleep(3.0);
	// A: a person the client has (an NPC is replicated only while relevant to him), put in front
	// of the host and the client, as a body usually is when someone shoots it.
	bGotCamera = false;
	Remote.ClientTestCorpse(Remote.Pawn.Location);
	Sleep(1.0);
	if (bGotCamera && ClientState != "no-corpse")
		Victim = NPCAt(ClientCam, 200);
	if (Victim == None)
		Victim = NPCAt(Lead.Pawn.Location, 100000);	// the client's nearest has moved: he gets this one in front of him
	if (Victim == None)
	{
		Check("ragdoll-victim", false, "no person of the client's found near"@ClientCam@ClientState);
		Finish();
		Stop;
	}
	HostRot = Lead.Rotation;
	// The client stands beside the host, as a player who shoots a body is near it (from where he
	// spawned, a house could hide the bodies from him).
	Side = vector(HostRot) cross vect(0,0,1);
	if (!Remote.Pawn.SetLocation(Lead.Pawn.Location - 120 * Side))
		Remote.Pawn.SetLocation(Lead.Pawn.Location - 120 * vector(HostRot));
	Sleep(0.5);
	Front = Lead.Pawn.Location + 250 * vector(HostRot) + vect(0,0,20);
	Victim.SetLocation(Front);
	Remote.ClientTestAim(rotator(Victim.Location - Remote.Pawn.Location));
	Sleep(1.5);
	Kill(Victim);
	Sleep(0.3);		// the ragdoll starts a frame after the death
	if (Victim.Physics != PHYS_KarmaRagDoll)
		Sleep(0.5);	// a death can cost a long frame
	Check("ragdoll-on-host", Victim.Physics == PHYS_KarmaRagDoll, "physics"@Victim.Physics);
	Sleep(0.4);
	// While it falls, the client's bones are compared with the host's of the moment he was asked.
	bGotBones = false;
	Before = HostBones(Victim);
	Remote.ClientTestBones(Victim.Location);
	Sleep(0.3);
	Worst = BoneGap(Before, ClientBones);
	log("P2CoopTest: falling host"@Before@"client"@ClientBones);
	Check("ragdoll-falling-close", bGotBones && Worst >= 0 && Worst < 60, "gap"@Worst);
	// At rest (the body is given up to 8 s to stop moving).
	Sleep(1.0);
	Settled(Victim);
	SettleTries = 0;
	do
	{
		Sleep(0.5);
		SettleTries++;
	} until (SettleTries >= 16 || Settled(Victim));
	bGotBones = false;
	Remote.ClientTestBones(Victim.Location);
	Sleep(0.5);
	Check("ragdoll-rest-same", bGotBones && ClientGap(Victim) >= 0 && Worst < 15, "gap"@Worst);

	// Blown up while lying there (a bullet only nudges a body): it moves on the host and the client
	// follows.
	Before = BonePositions(Victim, 0);
	Victim.TakeDamage(30, Lead.Pawn, Victim.Location + vect(0,0,10), 60000 * (vector(HostRot) + vect(0,0,0.5)), class'ExplodedDamage');
	Sleep(1.0);
	Check("ragdoll-moves-when-shot", BoneGap(Before, BonePositions(Victim, 0)) > 20, "moved"@BoneGap(Before, BonePositions(Victim, 0)));
	Settled(Victim);
	SettleTries = 0;
	do
	{
		Sleep(0.5);
		SettleTries++;
	} until (SettleTries >= 16 || Settled(Victim));
	bGotBones = false;
	Remote.ClientTestBones(Victim.Location);
	Sleep(0.5);
	Check("ragdoll-shot-same", bGotBones && ClientGap(Victim) >= 0 && Worst < 15, "gap"@Worst);

	// B: a person never rendered by the host, killed out of his view while the client looks at him:
	// first one far from the host, killed where he stands. The client goes to him and waits until
	// he has him (a pawn is replicated once relevant to the client); one he does not get is
	// skipped, and after two the person is brought behind the host instead.
	ClientHome = Remote.Pawn.Location;
	for (TypeNum = 0; TypeNum < 3; TypeNum++)
	{
		if (TypeNum < 2)
		{
			VictimB = FarUnrenderedNPC();
			if (VictimB == None)
				continue;
			Remote.Pawn.SetLocation(BSpot);
		}
		else
		{
			VictimB = UnrenderedNPC();
			if (VictimB == None)
				break;
			Remote.Pawn.SetLocation(ClientHome);
			Lead.SetRotation(HostRot + rot(0,32768,0));
			VictimB.SetLocation(Lead.Pawn.Location - 250 * vector(HostRot) + vect(0,0,20));
		}
		Remote.ClientTestAim(rotator(VictimB.Location - Remote.Pawn.Location));
		SettleTries = 0;
		do
		{
			Sleep(0.5);
			bGotCamera = false;
			Remote.ClientTestCorpse(VictimB.Location);
			Sleep(0.5);
			SettleTries++;
		} until (SettleTries >= 10 || (bGotCamera && VSize(ClientCam - VictimB.Location) < 50));
		log("P2CoopTest: B candidate"@VictimB@"tries"@SettleTries);
		if (bGotCamera && VSize(ClientCam - VictimB.Location) < 50)
			break;
		log("P2CoopTest: the client did not get"@VictimB@"at"@VictimB.Location@"from"@Remote.Pawn.Location@"nearest"@ClientCam@ClientState);
		VictimB.LastRenderTime = 1;		// not again
		VictimB = None;
	}
	if (VictimB == None)
		Check("ragdoll-unseen-victim", false, "no person unrendered by the host that the client gets");
	else
	{
		Check("ragdoll-unseen-victim", VictimB.LastRenderTime <= 0, "rendered"@VictimB.LastRenderTime);
		StartLoc = VictimB.Location;
		Kill(VictimB);
		Sleep(0.3);
		if (VictimB.Physics != PHYS_KarmaRagDoll)
			Sleep(0.5);	// a death can cost a long frame
		Check("ragdoll-unseen-on-host", VictimB.Physics == PHYS_KarmaRagDoll, "physics"@VictimB.Physics);
		Sleep(1.0);
		Settled(VictimB);
		SettleTries = 0;
		do
		{
			Sleep(0.5);
			SettleTries++;
		} until (SettleTries >= 16 || Settled(VictimB));
		log("P2CoopTest: B"@Describe(VictimB)@"from"@StartLoc);
		// On the ground where he stood: not below it, nor fallen through the floor out of the
		// standing spot's sight.
		Check("ragdoll-unseen-stays", VictimB.Location.Z > StartLoc.Z - 200 && Spread(VictimB) > 40
			&& FastTrace(VictimB.Location + vect(0,0,10), StartLoc),
			"z"@VictimB.Location.Z@"from"@StartLoc.Z@"spread"@Spread(VictimB)@"in sight"@FastTrace(VictimB.Location + vect(0,0,10), StartLoc));
		Check("ragdoll-unseen-bones-in-place", PelvisOff(VictimB) < 10, "pelvis off by"@PelvisOff(VictimB));
		bGotBones = false;
		Remote.ClientTestBones(VictimB.Location);
		Sleep(0.5);
		Check("ragdoll-unseen-same", bGotBones && ClientGap(VictimB) >= 0 && Worst < 15, "gap"@Worst);
		Remote.Pawn.SetLocation(ClientHome);
		Remote.ClientTestAim(rotator(Victim.Location - ClientHome));
		Sleep(1.0);
	}
	Lead.SetRotation(HostRot);

	// C: the client leaves (the first body goes out of his relevancy) and comes back to it.
	FarSpot = FarSpotFrom(Victim.Location);
	if (FarSpot == None)
		log("P2CoopTest: no far spot in this map");
	else
	{
		Remote.Pawn.SetLocation(FarSpot.Location + vect(0,0,10));
		Remote.ClientTestAim(rotator(FarSpot.Location - Victim.Location));
		Sleep(10.0);
		Remote.Pawn.SetLocation(ClientHome);
		Remote.ClientTestAim(rotator(Victim.Location - ClientHome));
		Sleep(3.0);
		bGotBones = false;
		Remote.ClientTestBones(Victim.Location);
		Sleep(0.5);
		Check("ragdoll-back-same", bGotBones && ClientGap(Victim) >= 0 && Worst < 15, "gap"@Worst);
	}

	// An animal (no ragdoll, a death animation) lies in the same place for everyone.
	Animal = NearestAnimal(Lead.Pawn.Location);
	if (Animal == None)
		log("P2CoopTest: no animal in this map");
	else
	{
		Animal.SetLocation(Front - 150 * Side);
		Remote.ClientTestAim(rotator(Animal.Location - Remote.Pawn.Location));
		Sleep(1.5);
		Kill(Animal);
		Sleep(1.0);
		Settled(Animal);
		SettleTries = 0;
		do
		{
			Sleep(0.5);
			SettleTries++;
		} until (SettleTries >= 16 || Settled(Animal));
		bGotCamera = false;
		Remote.ClientTestCorpse(Animal.Location);
		Sleep(0.5);
		log("P2CoopTest: animal"@Describe(Animal)@"client"@ClientCam@ClientState);
		Check("animal-same-place", bGotCamera && VSize(ClientCam - Animal.Location) < 10, "host"@Animal.Location@"client"@ClientCam);
	}

	// D: the other human bodies, each killed in front of both players a bit further away.
	for (TypeNum = 0; TypeNum < 4; TypeNum++)
	{
		TypeVictim = SpawnPerson(TypeNum, Front + (100 + 90 * TypeNum) * vector(HostRot));
		if (TypeVictim == None)
		{
			Check("ragdoll-" $ TypeName(TypeNum) $ "-same", false, "could not spawn" @ TypeClass(TypeNum));
			continue;
		}
		Remote.ClientTestAim(rotator(TypeVictim.Location - Remote.Pawn.Location));
		Sleep(1.5);
		Kill(TypeVictim);
		Sleep(1.0);
		Settled(TypeVictim);
		SettleTries = 0;
		do
		{
			Sleep(0.5);
			SettleTries++;
		} until (SettleTries >= 16 || Settled(TypeVictim));
		bGotBones = false;
		Remote.ClientTestBones(TypeVictim.Location);
		Sleep(0.5);
		// A mini body has no ragdoll (CoopPlayer.GetNewRagdollSkel): its death animation's pose.
		Check("ragdoll-" $ TypeName(TypeNum) $ "-same", bGotBones && TypeVictim != None
			&& (TypeVictim.Physics == PHYS_KarmaRagDoll) != (TypeNum == 3)
			&& ClientGap(TypeVictim) >= 0 && Worst < 15, TypeVictim@"mesh"@TypeVictim.Mesh@"physics"@TypeVictim.Physics@"gap"@Worst);
	}
	Finish();
}

defaultproperties
{
	TestName="ragdoll"
}
