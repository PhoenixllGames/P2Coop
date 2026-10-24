//=============================================================================
// CoopVersion: build marker for the P2Coop package.
//=============================================================================
class CoopVersion extends Object;

var const string Version;

static function string GetVersion()
{
	return default.Version;
}

defaultproperties
{
	Version="0.0.1"
}
