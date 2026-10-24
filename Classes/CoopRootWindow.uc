//=============================================================================
// CoopRootWindow: the shell menu for co-op copies of the game ([Engine.Engine]
// BaseMenu=P2Coop.CoopRootWindow, written by tools/mkcoopini.py).
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
// menu map ("startup"). Whenever it stops being a network client it reconnects to the
// same address itself, a few times. (Players leave by closing the game.)
//
// 3. The main menu is CoopMenuMain: the stock one plus "Co-op" (CoopMenu) and the credit line.
//=============================================================================
class CoopRootWindow extends ShellRootWindow;

const MaxReconnects = 10;	// a host loading a save refuses joins for a while (CoopGame.PreLogin)
const ReconnectDelay = 4.0;

var bool bInPostRender;
var string DeferredGameRes;

var string LastServer;		// address of the host while connected ("127.0.0.1:port")
var bool bWasClient;		// we were connected; cleared when the reconnect is sent
var float DroppedTime;		// Level.TimeSeconds when we found ourselves dropped, 0 = not dropped
var int Reconnects;

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
	bInPostRender = true;
	Super.PostRender(Canvas);
	bInPostRender = false;
	WatchConnection();
	if (!bMenuTestDone && MyMenu != None && IsMainMenuShowing())
		bRequiresTick = true;
	// The Co-op menu polls the Steam relay from our Tick.
	if (CoopMenu(MyMenu) != None && CoopMenu(MyMenu).Waiting != "")
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
	if (CoopMenu(MyMenu) != None)
		CoopMenu(MyMenu).Poll();
	if (MenuTestPick != "" && CoopMenu(MyMenu) != None)
	{
		CoopMenu(MyMenu).TestPick(MenuTestPick);
		MenuTestPick = "";
	}
}

// Tests only: with P2COOP_MENU_TEST=host or join (read by P2CoopHk.dll), the first main menu
// opens Co-op and picks Steam host or join, as a click would. The pick waits for the next tick:
// going to the new menu makes it again.
function MenuTest()
{
	local string Pick;

	bMenuTestDone = true;
	Pick = ViewportOwner.Actor.ConsoleCommand("P2COOP MENUTEST");
	if (Pick != "host" && Pick != "join")
		return;
	log("P2Coop: menu test picks"@Pick);
	GoToMenu(MyMenu.Class, class'CoopMenu');
	MenuTestPick = Pick;
	bRequiresTick = true;
}

// Called every frame: remembers the host while connected and reconnects after a drop.
function WatchConnection()
{
	local LevelInfo L;

	L = Root.GetLevel();
	if (L == None || ViewportOwner.Actor == None)
		return;
	if (L.NetMode == NM_Client)
	{
		LastServer = L.GetAddressURL();
		bWasClient = true;
		DroppedTime = 0;
		return;
	}
	if (!bWasClient || LastServer == "" || Reconnects >= MaxReconnects || L.NetMode != NM_Standalone)
		return;
	if (DroppedTime == 0)
	{
		DroppedTime = L.TimeSeconds;
		log("P2Coop: dropped from"@LastServer@"("$L.GetLocalURL()$"), reconnecting in"@ReconnectDelay@"s");
		return;
	}
	if (L.TimeSeconds - DroppedTime < ReconnectDelay)
		return;
	Reconnects++;
	DroppedTime = 0;
	bWasClient = false;
	log("P2Coop: reconnect"@Reconnects$"/"$MaxReconnects@"to"@LastServer);
	HideMenu();
	ViewportOwner.Actor.ConsoleCommand("open"@LastServer);
}
