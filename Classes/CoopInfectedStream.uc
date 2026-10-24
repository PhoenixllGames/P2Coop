// Stock infected urine omits the pawn callback used by normal and bloody urine.
class CoopInfectedStream extends GonorrheaPourFeeder;

function HittingPawn(FPSPawn P, vector HitLocation)
{
	Super.HittingPawn(P, HitLocation);
	if (CoopPawn(P) != None)
		CoopPawn(P).AttemptZombieRevival(P2Pawn(MyOwner));
}
