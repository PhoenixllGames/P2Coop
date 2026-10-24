//=============================================================================
// CoopSlotInfoMgr: the names and days of the co-op save slots.
//
// With co-op saves in their own folder (SaveCoop: [Core.System] SavePath in the game ini, as
// tools/mkcoopini.py sets it for test copies) they never overwrite the single-player Save*.usa
// files. The stock slot list (SlotInfoMgr, SavedGameInfo.ini) would still be shared and show
// co-op names for SP saves; this one keeps the co-op list in P2CoopSavedGameInfo.ini. The co-op
// game and the game info of the menu map (CoopRootWindow) use it.
// A player's game runs with his own Postal2.ini (System\dinput8.dll launch), whose save folder
// is the single-player one: there the stock list stays, since a co-op list over the same files
// would show single-player names for co-op saves.
//=============================================================================
class CoopSlotInfoMgr extends SlotInfoMgr
	config(P2CoopSavedGameInfo);

// True when saves go to their own co-op folder ([Core.System] SavePath=..\SaveCoop).
static function bool HasOwnSaveFolder(Actor A)
{
	return Right(A.ConsoleCommand("get Core.System SavePath"), 8) ~= "SaveCoop";
}

// Gives the game info of PC's level the co-op slot list.
static function UseFor(Actor A)
{
	local P2GameInfoSingle G;

	if (A == None)
		return;
	G = P2GameInfoSingle(A.Level.Game);
	if (G == None || CoopSlotInfoMgr(G.MySlotInfoMgr) != None || !HasOwnSaveFolder(A))
		return;
	if (G.MySlotInfoMgr != None)
		G.MySlotInfoMgr.Destroy();
	G.MySlotInfoMgr = G.Spawn(class'CoopSlotInfoMgr');
	log("P2Coop: co-op save slots"@G.MySlotInfoMgr@G.MySlotInfoMgr.NumSlots());
}
