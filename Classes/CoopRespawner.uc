//=============================================================================
// CoopRespawner: brings dead co-op players back (see CoopGame.PlayerDied), and gives a returning
// traveller the starting kit if his things did not come with him (CoopGame.SpawnNear).
//=============================================================================
class CoopRespawner extends Info;

function PostBeginPlay()
{
	Super.PostBeginPlay();
	SetTimer(0.5, true);
}

function Timer()
{
	local Controller C;
	local CoopPlayer P;
	local CoopGame G;

	G = CoopGame(Level.Game);
	if (G == None)
		return;
	for (C = Level.ControllerList; C != None; C = C.NextController)
	{
		P = CoopPlayer(C);
		if (P != None && P.KitCheckTime > 0 && Level.TimeSeconds >= P.KitCheckTime)
		{
			P.KitCheckTime = 0;
			if (P.Pawn != None && P.Pawn.FindInventoryType(class'Inventory.HandsWeapon') == None)
			{
				log("P2Coop:"@P.PlayerReplicationInfo.PlayerName@"came without his things, giving the kit");
				G.GiveKit(P.Pawn, P.PlayerReplicationInfo.PlayerName);
			}
			// His things came; on a new day's first map he also gets the day's starting kit,
			// which the stock PostTravel gives only to the leader.
			else if (P.Pawn != None && G.TheGameState != None && G.TheGameState.bFirstLevelOfDay)
			{
				log("P2Coop:"@P.PlayerReplicationInfo.PlayerName@"gets the day's starting kit");
				G.GiveDayKit(P.Pawn);
			}
		}
		if (P == None || !P.bRespawning || Level.TimeSeconds < P.RespawnTime)
			continue;
		if (P.Pawn != None && P.Pawn.Health > 0)
		{
			P.bRespawning = false;
			continue;
		}
		// Nobody left to spawn next to: everybody is dead, the stock game over takes over.
		// (A player still joining is not dead: RestartPlayer decides where he goes.)
		if (G.LivingPlayerPawn(P) == None && P.IsInState('Dead'))
			continue;
		log("P2Coop: respawning"@P.PlayerReplicationInfo.PlayerName);
		G.RestartPlayer(P);
	}
}
