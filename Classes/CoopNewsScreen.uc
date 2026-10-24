//=============================================================================
// CoopNewsScreen: the newspaper; on a client it reads the shadow game (CoopReplicationInfo).
//=============================================================================
class CoopNewsScreen extends NewsScreen;

function P2GameInfoSingle GetGameSingle()
{
	if (ViewportOwner.Actor.Level.Game != None)
		return Super.GetGameSingle();
	return class'CoopReplicationInfo'.static.ShadowFor(ViewportOwner.Actor);
}

// See CoopMapScreen.ShuttingDown.
function ShuttingDown()
{
	Super.ShuttingDown();
	if (ViewportOwner.Actor.Level.NetMode != NM_Client)
		return;
	if (Paper != None)
		Paper.Destroy();
	Paper = None;
	MyFont = None;
	P2P = None;
}

event Initialized()
{
	Super.Initialized();
	if (ViewportOwner.Actor.Level.NetMode == NM_Client)
		MyFont = None;	// Start spawns it again
}
