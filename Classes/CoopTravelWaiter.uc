//=============================================================================
// CoopTravelWaiter: retries CoopGame's deferred travel (see CoopGame.TryPendingTravel).
//=============================================================================
class CoopTravelWaiter extends Info;

function Timer()
{
	if (CoopGame(Level.Game) != None)
		CoopGame(Level.Game).TryPendingTravel();
}
