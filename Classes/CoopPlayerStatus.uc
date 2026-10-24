// Public player vitals: pawn health and controllers are not replicated to observers in SP.
class CoopPlayerStatus extends ReplicationInfo;

var PlayerReplicationInfo PRI;
var Pawn PlayerPawn;
var int CurrentHealth;
var float MaxHealth;
var PlayerController TrackedPlayer;

replication
{
	reliable if (Role == ROLE_Authority)
		PRI, PlayerPawn, CurrentHealth, MaxHealth;
}

simulated function Tick(float DeltaTime)
{
	if (Role < ROLE_Authority)
	{
		if (CoopPawn(PlayerPawn) != None)
			CoopPawn(PlayerPawn).UpdateDownPose();
		return;
	}
	if (TrackedPlayer == None || TrackedPlayer.bDeleteMe || TrackedPlayer.Player == None)
	{
		Destroy();
		return;
	}
	PRI = TrackedPlayer.PlayerReplicationInfo;
	PlayerPawn = TrackedPlayer.Pawn;
	CurrentHealth = 0;
	if (PlayerPawn != None)
	{
		if (CoopPawn(PlayerPawn) != None)
			CoopPawn(PlayerPawn).DownTick(DeltaTime);
		CurrentHealth = PlayerPawn.Health;
		MaxHealth = FPSPawn(PlayerPawn).HealthMax;
	}
}

simulated function float HealthFraction()
{
	return FClamp(float(CurrentHealth) / FMax(1, MaxHealth), 0, 1);
}

defaultproperties
{
	bAlwaysRelevant=true
	RemoteRole=ROLE_SimulatedProxy
	NetUpdateFrequency=10
}
