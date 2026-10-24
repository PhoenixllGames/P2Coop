//=============================================================================
// CoopRootWindow: the shell menu of the game with P2Coop ([Engine.Engine]
// BaseMenu=P2Coop.CoopRootWindow, which the installer puts in Postal2.ini; tests:
// tools/mkcoopini.py).
//
// 1. Below the menu's MinRes (1024 wide) the stock menu switches to MinRes while it
// shows and, in MenuShowing.EndState, switches back with "SetRes" if
// GetLowGameRes() is set. When a client joins a server, PostRender closes the
// menu, and SetRes during rendering kills the game: "Can't change resolution
// while render device is locked!".
// The menu states (MainMenuShowing, GameMenuShowing, ...) extend the parent's
// MenuShowing, so overriding that state here would not reach them. Instead,
// GetLowGameRes reports no low res while PostRender runs, and Tick restores the
// resolution next frame, outside rendering.
//
// 2. Reconnect: a client that drops out of the host's game (a map change it could
// not follow, the host loading a save, a network hiccup) lands in Entry or the main
// menu map ("startup"). There it reconnects to the same address itself, a few times.
// Only a drop does that: the player who quits to the menu, opens the Co-op menu, hosts
// or plays his own game is never pulled back (ForgetServer), and neither after the last
// attempt failed. When the connection goes, open co-op screens are closed at once
// (CloseCoopScreens): they hold actors of the level that went.
//
// 3. The main menu is CoopMenuMain: the stock one plus "Co-op" (CoopMenu) and the credit line.
//=============================================================================
class CoopRootWindow extends ShellRootWindow;

const MaxReconnects = 10;	// a host loading a save refuses joins for a while (CoopGame.PreLogin)
const FirstReconnectWait = 15.0;	// see WatchConnection
const RetryReconnectWait = 30.0;

var bool bInPostRender;
var string DeferredGameRes;

var string LastServer;		// address of the host while connected ("127.0.0.1:port")
var bool bWasClient;		// we were connected and dropped out: reconnect (ForgetServer clears it)
var float ReconnectAt;		// RealSeconds of the next reconnect, 0 = connected
var float ReconnectSetAt;	// RealSeconds when it was set: a clock that went back starts it again
var int Reconnects;
var bool bClientFrame;		// the last frame was a network client's

var bool bMenuTestDone;		// tools/menu_e2e.ps1, see MenuTest
var string MenuTestPick;

function class<BaseMenuBig> GetMainMenuClass()
{
	local class<BaseMenuBig> MenuClass;

	MenuClass = Super.GetMainMenuClass();
	if (MenuClass == class'MenuMain')
		return class'CoopMenuMain';
	return MenuClass;
}

function PostRender(Canvas Canvas)
{
	class'CoopSlotInfoMgr'.static.UseFor(ViewportOwner.Actor);
	bInPostRender = true;
	Super.PostRender(Canvas);
	// A reconnect hides the menu, which sets the game resolution: not while rendering
	// ("Can't change resolution while render device is locked"), GetLowGameRes defers it.
	WatchConnection();
	bInPostRender = false;
	if ((!bMenuTestDone && MyMenu != None && IsMainMenuShowing()) || MenuTestPick != "")
		bRequiresTick = true;
	// The Steam page polls the Steam relay from our Tick.
	if (CoopSteamMenu(MyMenu) != None && CoopSteamMenu(MyMenu).Waiting != "")
		bRequiresTick = true;
}

function string GetLowGameRes()
{
	if (bInPostRender && LowGameRes != "")
	{
		DeferredGameRes = LowGameRes;
		bRequiresTick = true;
		return "";
	}
	return LowGameRes;
}

function Tick(float Delta)
{
	Super.Tick(Delta);

	if (DeferredGameRes != "" && !IsInState('MenuShowing') && ViewportOwner.Actor != None)
	{
		log("P2Coop: menu closed while rendering, restoring game resolution"@DeferredGameRes);
		ViewportOwner.Actor.ConsoleCommand("SetRes "$DeferredGameRes);
		DeferredGameRes = "";
	}
	if (!bMenuTestDone && MyMenu != None && IsMainMenuShowing())
		MenuTest();
	if (CoopSteamMenu(MyMenu) != None)
		CoopSteamMenu(MyMenu).Poll();
	if (MenuTestPick != "" && CoopSteamMenu(MyMenu) != None)
	{
		CoopSteamMenu(MyMenu).TestPick(MenuTestPick);
		MenuTestPick = "";
	}
	else if (MenuTestPick != "" && CoopMenu(MyMenu) != None)
		CoopMenu(MyMenu).OpenSteam();
}

// Tests only: with P2COOP_MENU_TEST=host, join or leave (read by P2CoopHk), the first main menu
// opens Co-op, then its Steam page, and picks "Create game" or the first friend's game listed,
// as a click would, or presses Escape once the games are listed. Each step waits for the next
// tick: going to a new menu makes it again.
function MenuTest()
{
	local string Pick;

	bMenuTestDone = true;
	Pick = ViewportOwner.Actor.ConsoleCommand("P2COOP MENUTEST");
	if (Pick != "host" && Pick != "join" && Pick != "leave")
		return;
	log("P2Coop: menu test picks"@Pick);
	GoToMenu(MyMenu.Class, class'CoopMenu');
	MenuTestPick = Pick;
	bRequiresTick = true;
}

// The player has chosen what to do next himself, or the last attempt failed: no more reconnects.
function ForgetServer(string Why)
{
	if (bWasClient)
		log("P2Coop: no reconnect to"@LastServer$":"@Why);
	bWasClient = false;
	LastServer = "";
	ReconnectAt = 0;
	Reconnects = 0;
}

// The game menu's quit (Leave game on a client): the player leaves on purpose.
function QuitCurrentGame()
{
	if (IsGameMenu())
		ForgetServer("the player quit the game");
	Super.QuitCurrentGame();
}

// A new game, a loaded save or a custom map of the player's own (P2GameInfoSingle, the start
// menus): he plays his own game now, even before its level is loaded.
function StartingGame()
{
	ForgetServer("the player starts his own game");
	Super.StartingGame();
}

// The menu can open on the new level before its first PostRender (WatchConnection).
function ShowMenu()
{
	if (bClientFrame && Root.GetLevel() != None && Root.GetLevel().NetMode != NM_Client)
	{
		bClientFrame = false;
		CloseCoopScreens();
	}
	Super.ShowMenu();
}

// Entry or the main menu map: where a dropped client lands.
function bool IsDropLevel(LevelInfo L)
{
	local string Map;

	Map = ParseLevelName(L.GetLocalURL());
	if (Right(Map, 4) ~= ".fuk")
		Map = Left(Map, Len(Map) - 4);
	return Map ~= "Entry" || Map ~= "Index" || Map ~= GetStartupMap() || Left(Map, 7) ~= "Startup";
}

// A client's map and newspaper (CoopPlayer) hold actors of the level they show. A lost
// connection or the host loading a save frees that level without PreClientTravel: end them
// at once and let go of those actors.
function CloseCoopScreens()
{
	local int i;
	local P2Screen S;

	if (ViewportOwner == None)
		return;
	for (i = 0; i < ViewportOwner.LocalInteractions.Length; i++)
	{
		S = P2Screen(ViewportOwner.LocalInteractions[i]);
		if (CoopMapScreen(S) == None && CoopNewsScreen(S) == None)
			continue;
		if (S.IsRunning())
		{
			log("P2Coop: the level went with"@S@"open, closing it");
			if (S.SongHandle != 0 && ViewportOwner.Actor != None)
				ViewportOwner.Actor.StopMusic(S.SongHandle, 0.0);
			S.SongHandle = 0;
			if (S.SavedRes != "")
			{
				DeferredGameRes = S.SavedRes;	// not while rendering, Tick sets it
				bRequiresTick = true;
				S.SavedRes = "";
			}
			if (!S.bDontPauseGame)
			{
				ViewportOwner.bShowWindowsMouse = false;
				ViewportOwner.bSuspendPrecaching = false;
			}
			S.bIsRunning = false;
			S.bActive = false;
			S.bVisible = false;
			S.bRequiresTick = false;
			S.GotoState('');
		}
		if (CoopMapScreen(S) != None)
			CoopMapScreen(S).DropLevelActors();
		else
			CoopNewsScreen(S).DropLevelActors();
	}
}

// Called every frame: remembers the host while connected and reconnects after a drop.
// The wall clock in seconds (within a month). The reconnect waits do not use Level.TimeSeconds:
// Entry's jumps ahead after a load hitch, so a wait could end at once, while the engine's own
// connection to the host's new level is still on its way.
function float RealSeconds(LevelInfo L)
{
	return L.Day * 86400.0 + L.Hour * 3600.0 + L.Minute * 60.0 + L.Second + L.Millisecond / 1000.0;
}

function WatchConnection()
{
	local LevelInfo L;
	local float Now;

	L = Root.GetLevel();
	if (L == None || ViewportOwner.Actor == None)
		return;
	if (L.NetMode == NM_Client)
	{
		LastServer = L.GetAddressURL();
		bWasClient = true;
		bClientFrame = true;
		ReconnectAt = 0;
		Reconnects = 0;
		return;
	}
	if (bClientFrame)
	{
		bClientFrame = false;
		CloseCoopScreens();
	}
	if (!bWasClient)
		return;
	if (LastServer == "")
		ForgetServer("no address");
	else if (L.NetMode != NM_Standalone)
		ForgetServer("the player hosts a game");
	else if (!IsDropLevel(L))
		ForgetServer("the player plays his own game ("$ParseLevelName(L.GetLocalURL())$")");
	else if (IsInState('MenuShowing') && (CoopMenu(MyMenu) != None || CoopSteamMenu(MyMenu) != None) && MyMenu.bWindowVisible)
		ForgetServer("the player is in the Co-op menu");
	else if (Reconnects >= MaxReconnects)
		ForgetServer("no attempts left after"@MaxReconnects);
	if (!bWasClient)
		return;
	Now = RealSeconds(L);
	if (ReconnectAt != 0 && Now < ReconnectSetAt)
		ReconnectAt = 0;
	// A map change also passes through Entry ("Failed; returning to Entry" when the server's old
	// level closes the connection first), and the engine's own connection to the new map is
	// still on its way. Opening another one then would cut it off, so wait long enough.
	if (ReconnectAt == 0)
	{
		ReconnectAt = Now + FirstReconnectWait;
		ReconnectSetAt = Now;
		log("P2Coop: not connected to"@LastServer@"("$L.GetLocalURL()$"), reconnecting in"@FirstReconnectWait@"s unless the game gets back by itself");
		return;
	}
	if (Now < ReconnectAt)
		return;
	Reconnects++;
	ReconnectAt = Now + RetryReconnectWait;	// time for this attempt to log in and load
	ReconnectSetAt = Now;
	log("P2Coop: reconnect"@Reconnects$"/"$MaxReconnects@"to"@LastServer);
	HideMenu();
	ViewportOwner.Actor.ConsoleCommand("open"@LastServer);
}
