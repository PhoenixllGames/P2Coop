//=============================================================================
// CoopStart: the host starts a co-op game from the main menu the way the stock New Game does
// (MenuStart.StartGame2): the main menu's game sets up a fresh GameState for Monday, which
// travels to the first map in the host's inventory. The co-op map's PostTravel then continues it
// as a new game. Opening the map directly instead made a GameState there, on a map that is not
// the main menu or the intro, which the stock PostTravel takes for "testing a map via the command
// line": the whole week was marked cheated (no achievements, cheated saves).
//=============================================================================
class CoopStart extends Object
	abstract;

// Monday, as a new game starts (GameSinglePlayer.StartFirstDayURL).
static function string StartMap()
{
	return "suburbs-3";
}

// Starts the co-op game as a listen server on Port. From anywhere but the main menu's own game
// (which should not happen) the map is opened directly.
static function NewGame(ShellMenuCW Menu, string Port)
{
	local P2GameInfoSingle UseGame;
	local P2Player P;
	local Texture LoadTex;
	local string URL;

	URL = StartMap() $ "?Game=P2Coop.CoopGame?Listen?Port=" $ Port;
	UseGame = Menu.GetGameSingle();
	if (UseGame != None)
		P = UseGame.GetPlayer();
	if (P != None)
	{
		// What StartGame2 does, with the difficulty and options the player has set.
		P.UnSissy();
		P2RootWindow(Menu.Root).StartingGame();
		// The main menu's scene has the player's pawn; this gives it back.
		UseGame.StopSceneManagers();
	}
	if (P == None || P2Pawn(P.Pawn) == None || P.MyPawn == None)
	{
		log("P2Coop: co-op menu opens"@URL@"(no main menu game to start from)");
		ShellRootWindow(Menu.Root).HideMenu();
		Menu.GetPlayerOwner().ConsoleCommand("open" @ URL);
		return;
	}
	log("P2Coop: co-op menu starts a new game:"@URL);
	UseGame.ChangeGameState(class'CoopGame'.default.GameStateClass);
	UseGame.PrepIniStartVals();
	UseGame.TheGameState.bEGameStart = false;
	UseGame.SetupDifficultyOnce();
	UseGame.TheGameState.TimeElapsed = 0;
	UseGame.TheGameState.TimeStart = UseGame.Level.GetMillisecondsNow();
	P2Pawn(P.Pawn).DestroyAllInventory();
	UseGame.TheGameState.HudArmorClass = None;
	P.MyPawn.Armor = 0;
	// The day changes to Monday when the GameState arrives (PostTravel): the game starts there.
	UseGame.TheGameState.bChangeDayPostTravel = true;
	UseGame.TheGameState.NextDay = 0;
	LoadTex = class'CoopGame'.default.Days[0].GetLoadTexture();
	if (LoadTex != None)
	{
		UseGame.bShowDayDuringLoad = true;
		UseGame.ForcedLoadTex = LoadTex;
	}
	UseGame.SendPlayerTo(P, URL $ "?Mutator=?Workshop=0");
}
