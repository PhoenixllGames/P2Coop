// A downed player stays possessed and alive: no Died, inventory loss or ragdoll until bleed-out.
class CoopPawn extends AWPostalDude;

var bool bDowned;
var float BleedRemaining, ReviveProgress;
var float BleedDeadline, LastPeeTime;
var bool bFinishingDown;
var Weapon StowedWeapon;
var Controller DownKiller;
var class<DamageType> DownDamage;
var bool bAppliedDownPose;

replication
{
	reliable if (Role == ROLE_Authority)
		bDowned, BleedRemaining, ReviveProgress;
}

function bool CanGoDown()
{
	return !bFinishingDown && !bDowned && CoopGame(Level.Game) != None
		&& CoopPlayer(Controller) != None && Level.NextURL == ""
		&& CoopGame(Level.Game).LivingPlayerPawn(Controller) != None;
}

function Inventory CreateInventoryByClass(class<Inventory> MakeMe,
	optional out byte CreatedNow, optional bool bIgnoreDifficulty)
{
	if (MakeMe == class'UrethraWeapon')
		MakeMe = class'CoopUrethraWeapon';
	return Super.CreateInventoryByClass(MakeMe, CreatedNow, bIgnoreDifficulty);
}

function TakeDamage(int Damage, Pawn InstigatedBy, vector HitLocation,
	vector Momentum, class<DamageType> DamageType)
{
	local bool bHeadWasRemovable;

	if (bDowned)
		return;
	// Special head shots can remove the head during damage calculation, before PlayHit.
	bHeadWasRemovable = bHeadCanComeOff;
	if (CanGoDown())
		bHeadCanComeOff = false;
	Super.TakeDamage(Damage, InstigatedBy, HitLocation, Momentum, DamageType);
	bHeadCanComeOff = bHeadWasRemovable;
}

// Health has already passed stock location, armor, god-mode and nonlethal reductions.
// Intercept before PlayHit can dismember a lethal hit or start death effects.
function PlayHit(float Damage, vector HitLocation, class<DamageType> DamageType, vector Momentum)
{
	if (Health <= 0 && CanGoDown())
	{
		GoDown(DamageInstigator, DamageType);
		return;
	}
	Super.PlayHit(Damage, HitLocation, DamageType, Momentum);
}

function GoDown(Pawn InstigatedBy, class<DamageType> DamageType)
{
	bDowned = true;
	Health = 1;
	BleedDeadline = Level.TimeSeconds + 30;
	BleedRemaining = 30;
	ReviveProgress = 0;
	LastPeeTime = -1;
	DownDamage = DamageType;
	DownKiller = None;
	if (InstigatedBy != None)
		DownKiller = InstigatedBy.Controller;
	bCanPickupInventory = false;
	bPlayer = false; // stock police only arrest the active dude
	ShouldCrouch(false);
	ShouldDeathCrawl(true);
	Velocity = vect(0,0,0);
	Acceleration = vect(0,0,0);
	StowedWeapon = Weapon;
	if (P2Weapon(Weapon) != None)
		P2Weapon(Weapon).ForceEndFire();
	if (Weapon != None)
		Weapon.GotoState('Idle');
	PendingWeapon = None;
	Weapon = None;
	ForgetMe();
	CoopPlayer(Controller).SetDownControl(true);
	UpdateDownPose();
}

function ForgetMe()
{
	local Controller C;
	local LambController L;

	for (C = Level.ControllerList; C != None; C = C.NextController)
	{
		L = LambController(C);
		if (L == None || C.Pawn == None || C.Pawn.Health <= 0)
			continue;
		if (L.Attacker != self && L.InterestPawn != self && C.Enemy != self && C.Target != self)
			continue;
		if (PersonController(L) != None)
			PersonController(L).FullClearAttacker();
		L.Attacker = None;
		L.InterestPawn = None;
		C.Enemy = None;
		C.Target = None;
		C.Focus = None;
		C.bFire = 0;
		C.bAltFire = 0;
		if (P2Weapon(C.Pawn.Weapon) != None)
			P2Weapon(C.Pawn.Weapon).ForceEndFire();
		L.GotoState('Thinking');
	}
}

// UrinePourFeeder.HittingPawn calls this with MyOwner after an actual stream collision.
// Count time only between recent hits; multiple stream segments/players in a frame do not
// speed it up, and a gap never counts as contact. Progress survives interrupted peeing.
function AttemptZombieRevival(P2Pawn Other)
{
	local float Since;

	if (!bDowned || Other == None || Other == self || Other.Health <= 0
		|| CoopPlayer(Other.Controller) == None || UrethraWeapon(Other.Weapon) == None
		|| (CoopPawn(Other) != None && CoopPawn(Other).bDowned))
		return;
	Since = Level.TimeSeconds - LastPeeTime;
	if (LastPeeTime >= 0 && Since <= 0.2)
		ReviveProgress += Since;
	LastPeeTime = Level.TimeSeconds;
	if (ReviveProgress >= 2.5)
		Revive();
}

function Revive()
{
	bDowned = false;
	Health = Max(1, int(HealthMax * 0.25));
	BleedRemaining = 0;
	bCanPickupInventory = true;
	bPlayer = true;
	ShouldDeathCrawl(false);
	Weapon = StowedWeapon;
	StowedWeapon = None;
	if (Weapon != None)
		Weapon.BringUp();
	CoopPlayer(Controller).SetDownControl(false);
	UpdateDownPose();
}

function FinishDown()
{
	bFinishingDown = true;
	bDowned = false;
	BleedRemaining = 0;
	bPlayer = true;
	Weapon = StowedWeapon;
	StowedWeapon = None;
	Health = 0;
	if (CoopPlayer(Controller) != None)
		CoopPlayer(Controller).SetDownControl(false);
	UpdateDownPose();
	Died(DownKiller, DownDamage, Location);
}

function Died(Controller Killer, class<DamageType> DamageType, vector HitLocation)
{
	if (bDowned && !bFinishingDown)
		return;
	if (CanGoDown())
	{
		GoDown(None, DamageType);
		DownKiller = Killer;
		return;
	}
	Super.Died(Killer, DamageType, HitLocation);
}

function DownTick(float DeltaTime)
{
	if (!bDowned)
		return;
	Acceleration = vect(0,0,0);
	Velocity.X = 0;
	Velocity.Y = 0;
	Health = 1;
	BleedRemaining = float(int(FMax(0, BleedDeadline - Level.TimeSeconds) + 0.99));
	ForgetMe();
	if (BleedRemaining <= 0 || CoopGame(Level.Game).LivingPlayerPawn(Controller) == None)
		FinishDown();
}

simulated function UpdateDownPose()
{
	if (bAppliedDownPose == bDowned)
		return;
	bAppliedDownPose = bDowned;
	bPhysicsAnimUpdate = !bDowned;
	if (bDowned)
	{
		AnimBlendToAlpha(1, 0, 0.1);
		AnimBlendToAlpha(2, 0, 0.1);
		LoopAnim(GetAnimDeathCrawl(), 0.15, 0.2);
	}
	else
		ChangeAnimation();
}
