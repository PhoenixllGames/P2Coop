//=============================================================================
// CoopLoadTraveler: after a save is loaded on a listen server, takes the leader (and with
// him the GameState) from the save level to the saved map (see CoopGame.PostLoadGame).
//=============================================================================
class CoopLoadTraveler extends Info;

var int Tries;

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
	L = G.Leader();
	if (L == None || L.Pawn == None)
	{
		if (++Tries > 40)
		{
			log("P2Coop: no leader on the save level, staying here");
			SetTimer(0, false);
		}
		return;
	}
	SetTimer(0, false);
	log("P2Coop: back from the save to"@G.SavedMapName);
	G.SendPlayerTo(L, G.SavedMapName$"#");
}
