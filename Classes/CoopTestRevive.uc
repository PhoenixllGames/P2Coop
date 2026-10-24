// Real client movement and the host's UrethraWeapon/UrinePourFeeder collision path.
class CoopTestRevive extends CoopTestBase;

var CoopPawn Victim;
var vector Start;
var int i;
var bool bReported, bClientDown, bClientProne;
var float ClientBleed;
var string DownState;
var PoliceController Cop;
var P2PowerupInv Food;
var int FoodBefore;

function bool TargetDownedPlayer()
{
	foreach DynamicActors(class'PoliceController', Cop)
		if (Cop.Pawn != None && Cop.Pawn.Health > 0)
		{
			Cop.SetAttacker(Victim);
			Cop.InterestPawn = Victim;
			Cop.bFire = 1;
			return true;
		}
	return false;
}

function bool Prone(CoopPawn P)
{
	local name Anim;
	local float Frame, Rate;

	P.GetAnimParams(0, Anim, Frame, Rate);
	return Anim == P.GetAnimDeathCrawl() && !P.bPhysicsAnimUpdate;
}

function Report(bool bDown, float Bleed, string StateName, bool bProne)
{
	bReported = true;
	bClientDown = bDown;
	ClientBleed = Bleed;
	DownState = StateName;
	bClientProne = bProne;
}

function Down(CoopPawn P)
{
	P.Armor = 0;
	P.TakeDamage(10000, None, P.Location, vect(0,0,0), class'BulletDamage');
}

state Running
{
Begin:
	while (Remote.Pawn == None)
		Sleep(0.5);
	Sleep(3);
	Victim = CoopPawn(Remote.Pawn);
	Check("revive-coop-pawn", Victim != None && CoopPawn(Lead.Pawn) != None, "");
	if (Victim == None)
	{
		Finish();
		Stop;
	}
	Food = P2PowerupInv(Give(Victim, class'PizzaInv'));
	FoodBefore = Food.Amount;
	Down(Victim);
	Sleep(2);
	Check("revive-downed", Victim.bDowned && Victim.Health == 1 && Remote.Pawn == Victim,
		"health"@Victim.Health@"state"@Remote.GetStateName());
	Check("revive-no-ragdoll", Victim.Physics != PHYS_KarmaRagdoll && !Victim.bHidden, "physics"@Victim.Physics);
	Victim.TakeDamage(10000, Lead.Pawn, Victim.Location, vect(1000,0,1000), class'BulletDamage');
	Check("revive-invulnerable", Victim.Health == 1 && Victim.bDowned, "");
	Check("revive-cop-setup", TargetDownedPlayer(), "");
	Sleep(0.5);
	Check("revive-cop-forgets", Cop != None && Cop.Attacker != Victim
		&& Cop.InterestPawn != Victim && Cop.bFire == 0 && !Victim.bPlayer, "");
	Remote.ClientTestRevive();
	Start = Victim.Location;
	Remote.ClientTestDrive(6000, 1);
	Remote.ClientTestFire();
	Remote.ClientTestCommand("ActivateItem");
	Remote.ClientTestCommand("NextWeapon");
	Remote.ClientTestCommand("QuickHealth");
	Remote.ClientTestCommand("ActivateInventoryItem Inventory.PizzaInv");
	Sleep(2);
	Check("revive-client-locked", bReported && bClientDown && DownState == "CoopDowned"
		&& ClientBleed > 20 && ClientBleed <= 30, DownState@"timer"@ClientBleed);
	Check("revive-cannot-move", VSize(Victim.Location - Start) < 10, "moved"@VSize(Victim.Location - Start));
	Check("revive-cannot-shoot", Victim.Weapon == None, "weapon"@Victim.Weapon);
	Check("revive-cannot-use-food", Food != None && !Food.bDeleteMe && Food.Amount == FoodBefore, "");
	Check("revive-prone", Prone(Victim), "");
	Check("revive-client-prone", bClientProne, "");

	// Use the real zipper and hold fire. Keep aiming at the downed pawn while the arc updates.
	CoopPlayer(Lead).UseZipper(0);
	Sleep(3);
	Check("revive-host-urethra", UrethraWeapon(Lead.Pawn.Weapon) != None, "weapon"@Lead.Pawn.Weapon);
	Lead.SetRotation(AimAt(Lead.Pawn, Victim));
	Lead.bFire = 1;
	Lead.Fire(0);
	for (i = 0; i < 32 && Victim.bDowned; i++)
	{
		Lead.SetRotation(AimAt(Lead.Pawn, Victim));
		Sleep(0.25);
	}
	Lead.bFire = 0;
	if (P2Weapon(Lead.Pawn.Weapon) != None)
		P2Weapon(Lead.Pawn.Weapon).ForceEndFire();
	Check("revive-pee-contact", Victim.ReviveProgress >= 2.5, "contact"@Victim.ReviveProgress);
	Check("revive-up", !Victim.bDowned && Victim.Health > 1 && Remote.Pawn == Victim, "health"@Victim.Health);
	Sleep(2);
	bReported = false;
	Remote.ClientTestRevive();
	Sleep(1);
	Check("revive-client-up", bReported && !bClientDown && DownState == "PlayerWalking", DownState);
	Start = Victim.Location;
	Remote.ClientTestDrive(6000, 1);
	Sleep(2);
	Check("revive-moves-again", VSize(Victim.Location - Start) > 50, "moved"@VSize(Victim.Location - Start));

	// Reverse roles: remote urine collisions must also revive the host, and observers see prone.
	CoopPlayer(Lead).UseZipper(0);
	Down(CoopPawn(Lead.Pawn));
	Sleep(2);
	bReported = false;
	Remote.ClientTestRevive(Lead.PlayerReplicationInfo.PlayerName);
	Sleep(1);
	Check("revive-client-sees-host-down", bReported && bClientDown && bClientProne, "");
	Give(Remote.Pawn, class'GonorrheaAmmoInv');
	UrethraWeapon(P2Pawn(Remote.Pawn).MyUrethra).GiveAmmo(Remote.Pawn);
	Check("revive-infected-urethra", CoopUrethraWeapon(P2Pawn(Remote.Pawn).MyUrethra) != None
		&& UrethraWeapon(P2Pawn(Remote.Pawn).MyUrethra).IsInfected(), "");
	Remote.ClientTestPee(0);
	Sleep(3);
	Remote.ClientTestAim(AimAt(Remote.Pawn, Lead.Pawn));
	Sleep(0.5);
	Remote.ClientTestPee(1);
	for (i = 0; i < 32 && CoopPawn(Lead.Pawn).bDowned; i++)
	{
		Remote.ClientTestAim(AimAt(Remote.Pawn, Lead.Pawn));
		Sleep(0.25);
	}
	Remote.ClientTestPee(2);
	Check("revive-client-pee-host", !CoopPawn(Lead.Pawn).bDowned && Lead.Pawn.Health > 1,
		"contact"@CoopPawn(Lead.Pawn).ReviveProgress@"health"@Lead.Pawn.Health);

	// No help: use the real 30 second deadline, then existing delayed respawn.
	Down(Victim);
	Check("bleed-downed", Victim.bDowned, "");
	Sleep(31);
	Check("bleed-dead", Victim.Health <= 0 && !Victim.bDowned, "health"@Victim.Health);
	Sleep(CoopGame(Level.Game).RespawnDelay() + 2);
	Check("bleed-respawn", Remote.Pawn != None && Remote.Pawn != Victim && Remote.Pawn.Health > 0, "");

	// Last standing player falls: neither a downed teammate nor a corpse can be an anchor.
	Victim = CoopPawn(Remote.Pawn);
	Down(Victim);
	Down(CoopPawn(Lead.Pawn));
	Sleep(2);
	Check("revive-team-wipe", Lead.IsInState('Dead') && Remote.IsInState('Dead'),
		"host"@Lead.GetStateName()@"client"@Remote.GetStateName());
	Check("revive-no-wipe-respawn", CoopGame(Level.Game).LivingPlayerPawn(None) == None, "");
	Finish();
}

defaultproperties
{
	TestName="revive"
}
