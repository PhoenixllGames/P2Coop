//=============================================================================
// CoopHUD: the SP HUD; on a client it draws the host's game state too.
//
// P2HUD reads Level.Game directly (wanted meter, death hints, time), and a client has none. While
// a client's HUD renders, Level.Game is the shadow game (CoopReplicationInfo) and is put back to
// None right after: drawing only reads it, and nothing else runs in between.
//=============================================================================
class CoopHUD extends AWWrapHUD;

var CoopShadowGame Shadow;
var float LastWanted;		// what the wanted meter last showed (tests)

simulated event PostRender(canvas Canvas)
{
	if (Level.NetMode != NM_Client || Level.Game != None)
	{
		Super.PostRender(Canvas);
		return;
	}
	if (Shadow == None || Shadow.bDeleteMe)
		Shadow = class'CoopReplicationInfo'.static.ShadowFor(self);
	if (Shadow == None)
	{
		Super.PostRender(Canvas);
		return;
	}
	Level.Game = Shadow;
	Super.PostRender(Canvas);
	Level.Game = None;
}

simulated function DrawPlayerWantedStatus(canvas Canvas, float Scale)
{
	if (P2GameInfoSingle(Level.Game) != None && P2GameInfoSingle(Level.Game).TheGameState != None)
		LastWanted = P2GameInfoSingle(Level.Game).TheGameState.CopsWantPlayer();
	Super.DrawPlayerWantedStatus(Canvas, Scale);
}
