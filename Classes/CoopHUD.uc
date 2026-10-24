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
var array<Actor> Bodies;	// to be drawn once for their skeletons (DrawBody)
var array<float> BodySince;	// when each one was asked for

simulated event PostRender(canvas Canvas)
{
	if (Level.NetMode != NM_Client || Level.Game != None)
	{
		Super.PostRender(Canvas);
		DrawBodies(Canvas);
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

// Renders A once even when the host's own view does not: the engine brings a skeleton's place in
// the world up to date only when it is drawn, and a ragdoll the host has never drawn (killed out
// of his view) reads its bones far from its Karma bodies until then (CoopRagdollSync.StartRagdoll).
// The body is drawn where it is, behind what is in front of it: out of view it is clipped away.
function DrawBody(Actor A)
{
	local int i;

	for (i = 0; i < Bodies.Length; i++)
		if (Bodies[i] == A)
			return;
	Bodies[Bodies.Length] = A;
	BodySince[BodySince.Length] = Level.TimeSeconds;
}

function DrawBodies(canvas Canvas)
{
	local int i;
	local Actor A;

	for (i = Bodies.Length - 1; i >= 0; i--)
	{
		A = Bodies[i];
		// Done once it was rendered after the ask (by the view or by this); given up after a while.
		if (A == None || A.bDeleteMe || A.LastRenderTime > BodySince[i] || Level.TimeSeconds - BodySince[i] > 2.0)
		{
			Bodies.Remove(i, 1);
			BodySince.Remove(i, 1);
			continue;
		}
		Canvas.DrawActor(A, false, false);
	}
}

simulated function DrawPlayerWantedStatus(canvas Canvas, float Scale)
{
	if (P2GameInfoSingle(Level.Game) != None && P2GameInfoSingle(Level.Game).TheGameState != None)
		LastWanted = P2GameInfoSingle(Level.Game).TheGameState.CopsWantPlayer();
	Super.DrawPlayerWantedStatus(Canvas, Scale);
}
