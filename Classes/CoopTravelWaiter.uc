//=============================================================================
// CoopTravelWaiter: retries CoopGame's deferred level changes (CoopGame.RetryPendingSend,
// CoopGame.TryPendingTravel).
//=============================================================================
class CoopTravelWaiter extends Info;

function Timer()
{
	if (CoopGame(Level.Game) != None)
	{
		CoopGame(Level.Game).RetryPendingSend();
		CoopGame(Level.Game).TryPendingTravel();
	}
}
