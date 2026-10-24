//=============================================================================
// CoopMapScreen: the map; on a client it reads the shadow game (CoopReplicationInfo).
//=============================================================================
class CoopMapScreen extends MapScreen;

function P2GameInfoSingle GetGameSingle()
{
	if (ViewportOwner.Actor.Level.Game != None)
		return Super.GetGameSingle();
	return class'CoopReplicationInfo'.static.ShadowFor(ViewportOwner.Actor);
}

// On a client a level can go away without PreTravel (a lost connection), and the markers, the
// font and the shadow game are actors of that level: hold none of them while the map is closed.
function ShuttingDown()
{
	Super.ShuttingDown();
	if (ViewportOwner.Actor.Level.NetMode != NM_Client)
		return;
	if (HeadMarker != None)
		HeadMarker.Destroy();
	if (TrailMarker != None)
		TrailMarker.Destroy();
	HeadMarker = None;
	TrailMarker = None;
	gs = None;
	MyFont = None;
	P2P = None;
}

event Initialized()
{
	Super.Initialized();
	if (ViewportOwner.Actor.Level.NetMode == NM_Client)
		MyFont = None;	// Start spawns it again
}
