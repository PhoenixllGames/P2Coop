//=============================================================================
// CoopRagdollSync: one body's ragdoll, the same for everyone.
//
// A ragdoll is Karma physics that each machine would run on its own, so the same body would land
// in different places. Here only the host simulates it (CoopPlayer.GetNewRagdollSkel gives
// clients no skeleton) and this actor sends the host's pose: the pelvis position, the pawn
// rotation and the world rotations of the 20 main bones, packed into a short string, about ten
// times a second while the body moves and not at all while it rests (a Karma body twitches: a
// change below a degree does not count). On a client the dead pawn is posed with bone controllers
// (SetBoneDirection moves a bone's children with it), eased between samples. A late client gets
// the current pose with the actor. A body without a free skeleton dies with its animation; the
// same string poses that too.
//
// A body the host has never rendered (killed by a client out of his view) needs two things: its
// skeleton brought up to date before its ragdoll starts (StartRagdoll), or the ragdoll starts with
// all its bones in one point and falls through the world; and one render after it starts (the HUD
// draws it, CoopHUD.DrawBody), or its bones read far from where its Karma bodies are.
//
// An animal (bAnimal, CoopGame.Killed) has no ragdoll: it falls with its death animation. Its
// pose is its location and rotation, and a client that sees the body later also gets the
// animation, ended.
//=============================================================================
class CoopRagdollSync extends Actor;

var Pawn Corpse;
var string Pose;		// see MakePose, MakeAnimalPose
var int Seq;			// bumped with every new pose
var bool bAnimal;		// Corpse is an AnimalPawn
var name DeathAnim;		// animal: the death animation the host played
var bool bOld;			// the body died a while ago (a death animation seen now is a replay)

// Server
var float NextSample, StillSince, DeathTime;
var string LastPose;
var vector SampledLoc;	// Corpse.Location at the last sample
var bool bStartRagdoll;		// StartRagdoll on the next tick

// Client
var int AppliedSeq;
var Pawn Posed;			// the proxy prepared for posing (a proxy is made anew when it comes back into relevancy)
var array<rotator> FromRot, ToRot;
var vector FromPelvis, ToPelvis;
var rotator PawnRot;
var float BlendStart;
var bool bBonesSet;		// the bone controllers hold the current sample
var int Severed;		// the lost limbs already shrunk on the proxy (SeverBits)
var float NextFind;		// FindCorpse

const MovingInterval = 0.1;
const RestInterval = 0.25;
const LongRestInterval = 1.0;
const RestAfter = 1.0;		// seconds without movement before sampling slows down
const LongRestAfter = 10.0;
const OldAfter = 4.0;		// seconds after the death until bOld
const BlendTime = 0.1;
const NumBones = 20;
const PoseChar0 = 48;		// a pose character carries 6 bits: '0' to 'o'
const PoseOffset = 8388608;	// positions are sent as 24-bit unsigned numbers
const PoseLength = 140;		// 3 x 4 (pelvis) + 6 (pawn rotation) + 20 x 6 (bones) + 2 (lost limbs)
const AnimalPoseLength = 18;	// 3 x 4 (location) + 6 (rotation)
const SeverPos = 138;
const MinMove = 1.5;		// a pose has changed when a position moved this far...
const MinTurn = 182;		// ...or a rotation turned this much (a degree)

replication
{
	reliable if (Role == ROLE_Authority)
		Corpse, Pose, Seq, bAnimal, DeathAnim, bOld;
}

// The ragdoll bodies of the human skeletons (Avg_*_Skel.ka, all named MALE01), fingers left
// out: they follow their hands.
static function name BoneName(int i)
{
	switch (i)
	{
		case 0: return 'MALE01 pelvis';
		case 1: return 'MALE01 spine';
		case 2: return 'MALE01 spine1';
		case 3: return 'MALE01 spine2';
		case 4: return 'MALE01 neck';
		case 5: return 'MALE01 head';
		case 6: return 'MALE01 l clavicle';
		case 7: return 'MALE01 l upperarm';
		case 8: return 'MALE01 l forearm';
		case 9: return 'MALE01 l hand';
		case 10: return 'MALE01 r clavicle';
		case 11: return 'MALE01 r upperarm';
		case 12: return 'MALE01 r forearm';
		case 13: return 'MALE01 r hand';
		case 14: return 'MALE01 l thigh';
		case 15: return 'MALE01 l calf';
		case 16: return 'MALE01 l foot';
		case 17: return 'MALE01 r thigh';
		case 18: return 'MALE01 r calf';
		case 19: return 'MALE01 r foot';
	}
	return '';
}

// The bone the pose places the body by: the pelvis, or for a body without its bottom half (whose
// pelvis and spine are shrunk away, ApplySever) the lowest bone left.
static function name AnchorBone(int SeverBits)
{
	if ((SeverBits & 512) != 0)
		return BoneName(3);
	return BoneName(0);
}

static function int BoneCount()
{
	return NumBones;
}

// Whether bone i is shrunk away by the lost limbs in Bits (SeverBits): a cut at AWPerson's pair
// LEFT_ARM (0), RIGHT_ARM (2), LEFT_LEG (4) or RIGHT_LEG (6) hides the limb below it, a missing
// half everything on that side of the waist. Such a bone has no place of its own to compare.
static function bool BoneHidden(int i, int Bits)
{
	if ((Bits & 256) != 0 && i >= 2 && i <= 13)
		return true;
	if ((Bits & 512) != 0 && (i < 2 || i >= 14))
		return true;
	if ((Bits & 1) != 0 && (i == 8 || i == 9))
		return true;
	if ((Bits & 4) != 0 && (i == 12 || i == 13))
		return true;
	if ((Bits & 16) != 0 && (i == 15 || i == 16))
		return true;
	if ((Bits & 64) != 0 && (i == 18 || i == 19))
		return true;
	return false;
}

// ---------------------------------------------------------------- pose string

// Value as Chars characters of 6 bits each, low bits first.
static function string Pack(int Value, int Chars)
{
	local string S;
	local int i;

	for (i = 0; i < Chars; i++)
	{
		S = S $ Chr(PoseChar0 + (Value & 63));
		Value = Value >>> 6;
	}
	return S;
}

static function int Unpack(string S, int Pos, int Chars)
{
	local int i, V;

	for (i = Chars - 1; i >= 0; i--)
		V = (V << 6) | (Asc(Mid(S, Pos + i, 1)) - PoseChar0);
	return V;
}

// A position to the unit, 24 bits per component.
static function string PackVector(vector V)
{
	return Pack(int(V.X) + PoseOffset, 4) $ Pack(int(V.Y) + PoseOffset, 4) $ Pack(int(V.Z) + PoseOffset, 4);
}

static function vector UnpackVector(string S, int Pos)
{
	local vector V;

	V.X = Unpack(S, Pos, 4) - PoseOffset;
	V.Y = Unpack(S, Pos + 4, 4) - PoseOffset;
	V.Z = Unpack(S, Pos + 8, 4) - PoseOffset;
	return V;
}

// A rotation in 12 bits per component (a tenth of a degree).
static function string PackRot(rotator R)
{
	return Pack((R.Pitch >>> 4) & 4095, 2) $ Pack((R.Yaw >>> 4) & 4095, 2) $ Pack((R.Roll >>> 4) & 4095, 2);
}

static function rotator UnpackRot(string S, int Pos)
{
	local rotator R;

	R.Pitch = Unpack(S, Pos, 2) << 4;
	R.Yaw = Unpack(S, Pos + 2, 2) << 4;
	R.Roll = Unpack(S, Pos + 4, 2) << 4;
	return R;
}

function string MakePose()
{
	local int i, Bits;
	local string S;

	Bits = SeverBits(Corpse);
	S = PackVector(Corpse.GetBoneCoords(AnchorBone(Bits)).Origin);
	// Bone rotations are given in the pawn's frame: the client's pawn must face the same way.
	S = S $ PackRot(Corpse.Rotation);
	for (i = 0; i < NumBones; i++)
		S = S $ PackRot(Corpse.GetBoneRotation(BoneName(i), 1));
	return S $ Pack(Bits, 2);
}

function string MakeAnimalPose()
{
	return PackVector(Corpse.Location) $ PackRot(Corpse.Rotation);
}

// The limbs the body has lost: bit i for a cut at AWPerson.SeverBone[i] (the game shrinks those
// bones away and spawns the limb), bit 8 for the top half, bit 9 for the bottom half.
static function int SeverBits(Pawn P)
{
	local AWPerson A;
	local int i, Bits;

	A = AWPerson(P);
	if (A == None)
		return 0;
	for (i = 0; i < A.BoneArr.Length && i < 8; i++)
		if (A.BoneArr[i] == 0)
			Bits = Bits | (1 << i);
	if (A.bMissingTopHalf)
		Bits = Bits | 256;
	if (A.bMissingBottomHalf)
		Bits = Bits | 512;
	return Bits;
}

// Shrinks the bones of the lost limbs as the game does on the host (AWPerson: a cut at
// SeverBone[i] takes the next bone away and leaves a fifth of that one as the stump; a missing
// half shrinks the spine or everything but the top).
simulated function ApplySever(int Bits)
{
	local AWPerson A;
	local int i;

	A = AWPerson(Corpse);
	if (A != None)
	{
		for (i = 0; i + 1 < A.SeverBone.Length && i < 8; i += 2)
			if ((Bits & (1 << i)) != 0 && (Severed & (1 << i)) == 0)
			{
				A.SetBoneScale(i + 1, 0.0, A.SeverBone[i + 1]);
				A.SetBoneScale(i, 0.2, A.SeverBone[i]);
			}
		if ((Bits & 256) != 0 && (Severed & 256) == 0)
			A.SetBoneScale(9, 0.0, 'MALE01 spine1');
		if ((Bits & 512) != 0 && (Severed & 512) == 0)
		{
			A.SetBoneScale(9, 0.001, 'MALE01 pelvis');
			A.SetBoneScale(10, 1000.0, 'MALE01 spine1');
		}
	}
	Severed = Bits;
}

static function bool ParsePose(string S, out vector Pelvis, out rotator Rot, out array<rotator> Rots)
{
	local int i;

	if (Len(S) < PoseLength)
		return false;
	Pelvis = UnpackVector(S, 0);
	Rot = UnpackRot(S, 12);
	Rots.Remove(0, Rots.Length);
	Rots.Insert(0, NumBones);
	for (i = 0; i < NumBones; i++)
		Rots[i] = UnpackRot(S, 18 + 6 * i);
	return true;
}

static function bool ParseAnimalPose(string S, out vector Loc, out rotator Rot)
{
	if (Len(S) < AnimalPoseLength)
		return false;
	Loc = UnpackVector(S, 0);
	Rot = UnpackRot(S, 12);
	return true;
}

// The largest component of the turn from A to B, in rotation units.
static function int RotDiff(rotator A, rotator B)
{
	local rotator R;

	R = Normalize(A - B);
	if (R.Pitch < 0)
		R.Pitch = -R.Pitch;
	if (R.Yaw < 0)
		R.Yaw = -R.Yaw;
	if (R.Roll < 0)
		R.Roll = -R.Roll;
	return Max(R.Pitch, Max(R.Yaw, R.Roll));
}

// Whether pose B is far enough from pose A to be worth sending.
function bool PoseChanged(string A, string B)
{
	local vector PA, PB;
	local rotator RA, RB;
	local array<rotator> RotsA, RotsB;
	local int i;

	if (A == "")
		return true;
	if (bAnimal)
	{
		if (!ParseAnimalPose(A, PA, RA) || !ParseAnimalPose(B, PB, RB))
			return true;
		return VSize(PA - PB) > MinMove || RotDiff(RA, RB) > MinTurn;
	}
	if (!ParsePose(A, PA, RA, RotsA) || !ParsePose(B, PB, RB, RotsB))
		return true;
	if (VSize(PA - PB) > MinMove || RotDiff(RA, RB) > MinTurn || Unpack(A, SeverPos, 2) != Unpack(B, SeverPos, 2))
		return true;
	for (i = 0; i < NumBones; i++)
		if (RotDiff(RotsA[i], RotsB[i]) > MinTurn)
			return true;
	return false;
}

// ---------------------------------------------------------------- server

function SetCorpse(Pawn P)
{
	Corpse = P;
	bAnimal = AnimalPawn(P) != None;
	NextSample = Level.TimeSeconds;
	StillSince = Level.TimeSeconds;
	DeathTime = Level.TimeSeconds;
}

// The body has just died (or was hit again without a skeleton): its ragdoll starts on the next
// tick (ServerTick), outside of PlayDying.
function StartSoon()
{
	bStartRagdoll = true;
}

// Out of the host's view the HUD draws the body once.
function DrawBody()
{
	local CoopHUD H;

	foreach DynamicActors(class'CoopHUD', H)
	{
		H.DrawBody(Corpse);
		return;
	}
}

// What P2MoCapPawn.PlayDying does when it gets a skeleton, one frame later, plus the push it
// would have given the body.
function StartRagdoll()
{
	local P2MoCapPawn MP;
	local CoopGame Game;
	local vector DeathVel, DeathImpulse;

	MP = P2MoCapPawn(Corpse);
	Game = CoopGame(Level.Game);
	if (MP == None || Game == None || MP.Health > 0 || KarmaParamsSkel(MP.KParams) != None)
		return;
	Game.bRagdollNow = true;
	MP.GetKarmaSkeleton();
	Game.bRagdollNow = false;
	if (KarmaParamsSkel(MP.KParams) == None)
		return;		// no skeleton free: the body lies as its death animation leaves it
	// Brings the skeleton up to date: one nobody has drawn yet (killed out of the host's view) has
	// all its bones in one point, and its ragdoll would fall through the world.
	MP.GetBoneCoords(BoneName(0));
	MP.ShouldCrouch(false);
	MP.ShouldDeathCrawl(false);
	MP.StopAnimating();
	MP.bPhysicsAnimUpdate = false;
	MP.SetPhysics(PHYS_KarmaRagDoll);
	MP.KWake();
	if (!(MP.bIsDeathCrawling || MP.bIsKnockedOut) || ClassIsChildOf(MP.DyingDamageType, class'ExplodedDamage'))
	{
		DeathVel = MP.DeathVelMag * Normal(MP.TearOffMomentum);
		DeathImpulse = MP.Mass * MP.TearOffMomentum;
		MP.CapKarmaMomentum(DeathImpulse, MP.DyingDamageType, 1.0, 1.0);
		MP.KSetSkelVel(DeathVel);
		MP.KAddImpulse(DeathImpulse, MP.TakeHitLocation);
	}
	// A body the host has never drawn reads its bones out of place (the standing pose of its
	// skeleton's last update, below the floor) until it is rendered once as a ragdoll.
	DrawBody();
	StillSince = Level.TimeSeconds;
	NextSample = Level.TimeSeconds;
}

simulated function Tick(float DeltaTime)
{
	if (Role == ROLE_Authority)
		ServerTick();
	else
		ClientTick();
}

function ServerTick()
{
	local string S;
	local float Still, Frame, Rate;
	local name AnimSeq;

	if (Corpse == None || Corpse.bDeleteMe)
	{
		Destroy();
		return;
	}
	// The body points back at this actor: a client that gets the body after this actor (it was
	// not relevant to him at the death, or it comes back into his relevancy) finds it by that,
	// as the reference above is sent only once.
	if (Corpse.Owner != self && Corpse.Controller == None)
		Corpse.SetOwner(self);
	// The pose goes to the clients here. The body's own movement updates (a ragdoll moves, and
	// twitches, every frame) would only fill the connection and pull a client's posed body back.
	if (Corpse.bReplicateMovement)
		Corpse.bReplicateMovement = false;
	if (bStartRagdoll)
	{
		bStartRagdoll = false;
		StartRagdoll();
	}
	if (!bOld && Level.TimeSeconds - DeathTime > OldAfter)
		bOld = true;
	// A body at rest is sampled rarely; one kicked, shot or blown up moves its pelvis (the pawn's
	// location) and is sampled at once.
	if (VSize(Corpse.Location - SampledLoc) > MinMove)
		NextSample = FMin(NextSample, Level.TimeSeconds);
	if (Level.TimeSeconds < NextSample)
		return;
	SampledLoc = Corpse.Location;
	if (bAnimal)
	{
		S = MakeAnimalPose();
		Corpse.GetAnimParams(0, AnimSeq, Frame, Rate);
		if (AnimSeq != '' && AnimSeq != DeathAnim)
			DeathAnim = AnimSeq;
	}
	else
		S = MakePose();
	if (PoseChanged(LastPose, S))
	{
		LastPose = S;
		Pose = S;
		Seq++;
		StillSince = Level.TimeSeconds;
	}
	Still = Level.TimeSeconds - StillSince;
	if (Still > LongRestAfter)
		NextSample = Level.TimeSeconds + LongRestInterval;
	else if (Still > RestAfter)
		NextSample = Level.TimeSeconds + RestInterval;
	else
		NextSample = Level.TimeSeconds + MovingInterval;
}

// ---------------------------------------------------------------- client

simulated function ClientTick()
{
	local float Alpha;
	local int i;
	local vector Pelvis, Now;

	if (Corpse == None && Level.TimeSeconds >= NextFind)
		FindCorpse();
	if (Corpse == None || Pose == "")
		return;
	if (Corpse != Posed)
	{
		// A new proxy (first seen, or back in relevancy): no physics of its own, and for a ragdoll
		// no animation either (an animal keeps its death animation).
		Posed = Corpse;
		Corpse.bPhysicsAnimUpdate = false;
		Corpse.SetPhysics(PHYS_None);
		// Moved by its pelvis (below), which lies on the floor: the pawn's cylinder goes into the
		// ground, and a move checked against the world would fail.
		Corpse.bCollideWorld = false;
		ToRot.Remove(0, ToRot.Length);
		AppliedSeq = Seq - 1;
		Severed = 0;
		if (!bAnimal)
			Corpse.StopAnimating();
	}
	if (bAnimal)
	{
		AnimalTick();
		return;
	}
	if (Corpse.IsAnimating())
	{
		// The death animation arrived after the proxy was prepared (SimAnim): it would move the body.
		Corpse.StopAnimating();
		bBonesSet = false;
	}
	if (Seq != AppliedSeq)
	{
		AppliedSeq = Seq;
		FromRot = ToRot;
		FromPelvis = ToPelvis;
		if (!ParsePose(Pose, ToPelvis, PawnRot, ToRot))
			return;
		if (Unpack(Pose, SeverPos, 2) != Severed)
			ApplySever(Unpack(Pose, SeverPos, 2));
		if (FromRot.Length != ToRot.Length)
		{
			// The first pose is taken as it is.
			FromRot = ToRot;
			FromPelvis = ToPelvis;
		}
		BlendStart = Level.TimeSeconds;
		bBonesSet = false;
	}
	if (ToRot.Length == 0)
		return;
	Alpha = FClamp((Level.TimeSeconds - BlendStart) / BlendTime, 0, 1);
	// The bone controllers stay set: once the sample is reached they are left alone.
	if (!bBonesSet)
	{
		if (Corpse.Rotation != PawnRot)
			Corpse.SetRotation(PawnRot);
		for (i = 0; i < ToRot.Length; i++)
			Corpse.SetBoneDirection(BoneName(i), FromRot[i] + Normalize(ToRot[i] - FromRot[i]) * Alpha, vect(0,0,0), 1.0);
		bBonesSet = Alpha >= 1;
	}
	// The whole pawn moves so that its pelvis lands where the host's is. Checked every pass: the
	// proxy's skeleton takes the controllers only when it is drawn, so a body prepared out of
	// view settles where it should once it is looked at.
	Pelvis = FromPelvis + (ToPelvis - FromPelvis) * Alpha;
	Now = Corpse.GetBoneCoords(AnchorBone(Severed)).Origin;
	if (VSize(Pelvis - Now) > 0.5)
		Corpse.SetLocation(Corpse.Location + (Pelvis - Now));
}

// The body on this machine, by its owner (ServerTick), when the reference did not come with this
// actor.
simulated function FindCorpse()
{
	local Pawn P;

	NextFind = Level.TimeSeconds + 0.5;
	foreach DynamicActors(class'Pawn', P)
		if (P.Owner == self)
		{
			Corpse = P;
			return;
		}
}

// An animal lies where the host's does. One seen a while after its death (a late client, or a
// proxy made anew) replays the death animation from the start (SimAnim): it is ended at once, as
// the game does for a body that starts dead.
simulated function AnimalTick()
{
	local name AnimSeq;
	local float Frame, Rate;

	if (Seq != AppliedSeq)
	{
		AppliedSeq = Seq;
		if (ParseAnimalPose(Pose, ToPelvis, PawnRot))
		{
			Corpse.SetLocation(ToPelvis);
			Corpse.SetRotation(PawnRot);
		}
	}
	if (bOld && DeathAnim != '' && Corpse.IsAnimating(0))
	{
		Corpse.GetAnimParams(0, AnimSeq, Frame, Rate);
		if (AnimSeq == DeathAnim && Frame < 0.95)
			Corpse.PlayAnim(DeathAnim, 10000);
	}
}

defaultproperties
{
	bHidden=true
	bAlwaysRelevant=true
	RemoteRole=ROLE_SimulatedProxy
	NetUpdateFrequency=10
}
