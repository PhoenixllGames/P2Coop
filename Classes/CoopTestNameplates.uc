class CoopTestNameplates extends CoopTestBase;

var bool bReported, bVisible;
var string SeenName;
var float SeenFraction;
var vector Home;
var bool bPlaced;

function FaceHost()
{
	local vector Head;

	Head = Lead.Pawn.Location;
	Head.Z += Lead.Pawn.CollisionHeight + 16;
	Remote.ClientTestAim(rotator(Head - (Remote.Pawn.Location + Remote.Pawn.EyePosition())));
}

function bool MoveHost(bool bFar)
{
	local NavigationPoint N;
	local float Dist;
	local vector Cam;

	Cam = Remote.Pawn.Location + Remote.Pawn.EyePosition();
	foreach AllActors(class'NavigationPoint', N)
	{
		Dist = VSize(N.Location - Cam);
		if ((bFar && Dist > 2800) || (!bFar && Dist > 300 && Dist < 2000 && !FastTrace(N.Location, Cam)))
			if (Lead.Pawn.SetLocation(N.Location))
				return true;
	}
	return false;
}

function Report(bool bDraw, string PlayerName, float Fraction)
{
	bReported = true;
	bVisible = bDraw;
	SeenName = PlayerName;
	SeenFraction = Fraction;
}

state Running
{
Begin:
	while (Remote.Pawn == None)
		Sleep(0.5);
	Sleep(3);
	FaceHost();
	Lead.Pawn.TakeDamage(40, None, Lead.Pawn.Location, vect(0,0,0), class'BulletDamage');
	Sleep(2);
	Remote.ClientTestNameplate(Lead.PlayerReplicationInfo.PlayerName);
	Sleep(1);
	Check("nameplate-report", bReported, "");
	Check("nameplate-visible", bVisible, "");
	Check("nameplate-name", SeenName == Lead.PlayerReplicationInfo.PlayerName, SeenName);
	Check("nameplate-health", Abs(SeenFraction - float(Lead.Pawn.Health) / FPSPawn(Lead.Pawn).HealthMax) < 0.01,
		"fraction"@SeenFraction@"health"@Lead.Pawn.Health@"max"@FPSPawn(Lead.Pawn).HealthMax);
	bReported = false;
	Remote.ClientTestNameplate(Remote.PlayerReplicationInfo.PlayerName);
	Sleep(1);
	Check("nameplate-hide-self", bReported && !bVisible, "");
	Remote.ClientTestAim(rotator(Remote.Pawn.Location - Lead.Pawn.Location));
	Sleep(1);
	bReported = false;
	Remote.ClientTestNameplate(Lead.PlayerReplicationInfo.PlayerName);
	Sleep(1);
	Check("nameplate-hide-behind-camera", bReported && !bVisible, "");
	Home = Lead.Pawn.Location;
	bPlaced = MoveHost(false);
	Check("nameplate-wall-setup", bPlaced, "");
	FaceHost();
	Sleep(2);
	bReported = false;
	Remote.ClientTestNameplate(Lead.PlayerReplicationInfo.PlayerName);
	Sleep(1);
	Check("nameplate-hide-behind-wall", bPlaced && bReported && !bVisible, "");
	bPlaced = MoveHost(true);
	Check("nameplate-distance-setup", bPlaced, "");
	FaceHost();
	Sleep(2);
	bReported = false;
	Remote.ClientTestNameplate(Lead.PlayerReplicationInfo.PlayerName);
	Sleep(1);
	Check("nameplate-hide-distant", bPlaced && bReported && !bVisible, "");
	Lead.Pawn.SetLocation(Home);
	FaceHost();
	CoopPawn(Lead.Pawn).bFinishingDown = true;
	Lead.Pawn.Health = 0;
	Lead.Pawn.Died(None, class'BulletDamage', Lead.Pawn.Location);
	Sleep(2);
	bReported = false;
	Remote.ClientTestNameplate(Lead.PlayerReplicationInfo.PlayerName);
	Sleep(1);
	Check("nameplate-hide-dead", bReported && !bVisible, "");
	Finish();
}

defaultproperties
{
	TestName="nameplates"
}
