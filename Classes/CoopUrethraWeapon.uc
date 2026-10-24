class CoopUrethraWeapon extends UrethraWeapon;

function SpawnStream()
{
	local FluidPourFeeder OldStream;

	Super.SpawnStream();
	if (UrineStream == None || UrineStream.Class != class'GonorrheaPourFeeder')
		return;
	OldStream = FluidPourFeeder(UrineStream);
	UrineStream = Spawn(class'CoopInfectedStream', Instigator,,, Rotation);
	if (UrineStream == None)
	{
		UrineStream = OldStream;
		return;
	}
	// Preserve the stock enhanced/elephant settings and effects.
	FluidPourFeeder(UrineStream).InitialPourSpeed = OldStream.InitialPourSpeed;
	FluidPourFeeder(UrineStream).InitialSpeedZPlus = OldStream.InitialSpeedZPlus;
	UrineStream.Emitters[0].StartVelocityRange = OldStream.Emitters[0].StartVelocityRange;
	UrineStream.Emitters[0].StartSizeRange = OldStream.Emitters[0].StartSizeRange;
	UrineStream.MyDamageType = OldStream.MyDamageType;
	OldStream.Destroy();
	SnapUrineStreamToGun(true);
}
