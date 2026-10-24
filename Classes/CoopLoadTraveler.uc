//=============================================================================
// CoopLoadTraveler: after a save is loaded on a listen server, takes the leader (and with
// him the GameState) from the save level to the saved map (see CoopGame.PostLoadGame).
// It waits for the leader's pawn (a load screen can pause the game). After LongWait tries it
// tells the host and goes on trying, more slowly: joins stay refused meanwhile, because a client
// cannot play on a save level (CoopGame.PostLoadGame).
//=============================================================================
class CoopLoadTraveler extends Info;

var int Tries;
const LongWait = 40;		// tries at 0.5 s
const SlowRetry = 2.0;

function PostBeginPlay()
{
	Super.PostBeginPlay();
	SetTimer(0.5, true);
}

function Timer()
{
	local CoopGame G;
	local PlayerController L;

	G = CoopGame(Level.Game);
	if (G == None)
	{
		Destroy();
		return;
	}
	L = G.Leader();
	if (L == None || L.Pawn == None)
	{
		if (++Tries == LongWait)
		{
			log("P2Coop: no leader pawn on the save level after"@(Tries / 2)@"s, still trying");
			if (L != None)
				L.ClientMessage("P2Coop: the trip to the saved map has not started yet (the host has no pawn). Load again if it does not start.");
			SetTimer(SlowRetry, true);
		}
		return;
	}
	SetTimer(0, false);
	log("P2Coop: back from the save to"@G.SavedMapName);
	G.SendPlayerTo(L, G.SavedMapName$"#");
}
