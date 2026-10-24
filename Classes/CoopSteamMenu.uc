//=============================================================================
// CoopSteamMenu: co-op over Steam (CoopMenu -> "Play over Steam"). One page: the Steam friends
// who host a co-op game, each joined with one click, and "Create game".
//
// The relay P2CoopLink does the networking. P2CoopHk starts it on the console command
// "P2COOP LINK ..." and reports its status line, which this page polls (CoopRootWindow.Tick):
//   list: while the page is up the relay lists the friends' games ("hosts", then a tab before
//         each lobby id and host name); a Steam invite the player accepts joins right away;
//   join: a click on a friend's game: the relay joins that lobby ("joining"), checks versions and
//         gives a local address ("ready 127.0.0.1:<port>") that this game connects to;
//   host: "Create game": the relay opens a friends-only lobby ("hosting <lobby>"), then this game
//         starts Monday as a listen server (CoopStart) and the relay passes the friends' packets on.
// Leaving the page (Back or Escape) stops a relay that is not in a game yet.
// Without P2CoopHk (System\dinput8.dll) the console command gives no answer it knows.
//=============================================================================
class CoopSteamMenu extends ShellMenuCW;

var ShellMenuChoice CreateChoice;
var ShellMenuChoice GameChoices[6];
var string GameLobbies[6];
var ShellWrappedTextControl StatusItem;

var localized string TitleText, CreateText, CreateHelp, JoinGameText, JoinGameHelp;
var localized string StartingText, SearchingText, NoGamesText, GamesText, CreatingText, JoiningText;
var localized string NoRelayText, TimeoutText, ErrorText;

var string Waiting;		// "list", "join" or "host" while the relay works for this page
var bool bListed;		// the relay has reported the friends' games at least once
var string LastHosts;	// the last "hosts" line shown
var float NextPoll, GiveUp;	// Level.TimeSecondsAlways
var bool bTestJoin;		// tests (CoopRootWindow.MenuTest): join the first game listed
var bool bTestLeave;	// tests: press Escape 5 s after the games are listed
var float TestLeaveAt;

const Port = "7777";
const ListTimeout = 30.0;	// until the first list: Steam not answering
const JoinTimeout = 90.0;	// lobby join (3 x 15 s) and version check (20 s)
const HostTimeout = 30.0;

function CreateMenuContents()
{
	local array<string> Lines;
	local int i;

	class'CoopText'.static.Translate(self, "CoopSteamMenu", "TitleText CreateText CreateHelp JoinGameText "
		$ "JoinGameHelp StartingText SearchingText NoGamesText GamesText CreatingText JoiningText NoRelayText "
		$ "TimeoutText ErrorText");
	Super.CreateMenuContents();
	TitleAlign = TA_Left;
	ItemAlign = TA_Left;
	AddTitle(TitleText, TitleFont, TitleAlign);
	CreateChoice = AddChoice(CreateText, CreateHelp, ItemFont, ItemAlign);
	for (i = 0; i < ArrayCount(GameChoices); i++)
	{
		GameChoices[i] = AddChoice(" ", JoinGameHelp, ItemFont, ItemAlign);
		GameChoices[i].HideWindow();
	}
	Lines[0] = " ";
	StatusItem = AddWrappedTextItem(Lines, ItemHeight * 2, ItemFont, TA_Left);
	BackChoice = AddChoice(BackText, "", ItemFont, ItemAlign, true);
	Relayout();
}

function AfterCreate()
{
	Super.AfterCreate();
	StartRelay("list", "LIST", ListTimeout);
}

function SetStatus(string Text)
{
	if (StatusItem.Text == Text)
		return;
	StatusItem.Text = Text;
	log("P2Coop: co-op menu:"@Text);
}

function string Relay(string Cmd)
{
	return GetPlayerOwner().ConsoleCommand("P2COOP LINK" @ Cmd);
}

function StopRelay()
{
	if (Waiting != "")
		Relay("STOP");
	Waiting = "";
}

function StartRelay(string Mode, string Cmd, float Timeout)
{
	local string R;
	local float Now;

	Now = GetLevel().TimeSecondsAlways;
	Waiting = "";
	R = Relay(Cmd);
	if (Left(R, 5) == "error")
		SetStatus(ErrorText @ Mid(R, 6));
	else if (R != "started")
		SetStatus(NoRelayText);
	else
	{
		Waiting = Mode;
		GiveUp = Now + Timeout;
		NextPoll = Now + 0.5;
		if (Mode == "host")
			SetStatus(CreatingText);
		else if (Mode == "list")
			SetStatus(StartingText);
	}
}

// Back and Escape (ShellMenuCW.KeyEvent) both end here.
function GoBack()
{
	if (Waiting != "")
		log("P2Coop: co-op menu leaves the Steam page and stops the relay ("$Waiting$")");
	StopRelay();
	Super.GoBack();
}

function Travel(string URL)
{
	log("P2Coop: co-op menu opens"@URL);
	ShellRootWindow(Root).HideMenu();
	GetPlayerOwner().ConsoleCommand("open" @ URL);
}

// Stacks the visible items from the top, so hidden game slots leave no gap.
function Relayout()
{
	local int i;
	local float Y;

	if (MenuItems.Length == 0)
		return;
	Y = MenuItems[0].PosY;
	for (i = 0; i < MenuItems.Length; i++)
	{
		if (!MenuItems[i].Window.bWindowVisible)
			continue;
		MenuItems[i].PosY = Y;
		MenuItems[i].Window.WinTop = Y;
		MenuItems[i].Window.SavedWinTop = Y;
		Y += MenuItems[i].Height;
	}
}

// The stock keyboard and joystick navigation, but over visible items only.
function NextMenuItem(int Offset)
{
	local UWindowWindow CurrentWindow;
	local int i, Tries;

	if (!bWindowVisible)
		return;
	CurrentWindow = Root.MouseWindow;
	for (i = 0; i < MenuItems.Length; i++)
		if (MenuItems[i].Window == CurrentWindow)
			break;
	while (Tries < MenuItems.Length * 2 && (i < 0 || i >= MenuItems.Length || MenuItems[i].Window == CurrentWindow
		|| ShellWrappedTextControl(MenuItems[i].Window) != None || !MenuItems[i].Window.bWindowVisible))
	{
		Tries++;
		i += Offset;
		if (i < 0)
			i = MenuItems.Length - 1;
		else if (i >= MenuItems.Length)
			i = 0;
	}
	if (i >= 0 && i < MenuItems.Length)
		SnapCursorTo(MenuItems[i].Window);
}

// Cuts S at its first tab: returns the part before, S keeps the rest ("" at the end).
function string NextField(out string S)
{
	local int i;
	local string F;

	i = InStr(S, Chr(9));
	if (i < 0)
	{
		F = S;
		S = "";
		return F;
	}
	F = Left(S, i);
	S = Mid(S, i + 1);
	return F;
}

// "hosts", then "<tab><lobby id><tab><host name>" for each friend's game.
function ShowGames(string R)
{
	local string Rest, Lobby, HostName;
	local int i, n;

	bListed = true;
	if (R == LastHosts)
		return;
	LastHosts = R;
	Rest = Mid(R, 6);
	while (Rest != "" && n < ArrayCount(GameChoices))
	{
		Lobby = NextField(Rest);
		HostName = NextField(Rest);
		if (Lobby == "")
			break;
		GameLobbies[n] = Lobby;
		GameChoices[n].SetText(JoinGameText @ HostName);
		GameChoices[n].ShowWindow();
		n++;
	}
	for (i = n; i < ArrayCount(GameChoices); i++)
	{
		GameLobbies[i] = "";
		GameChoices[i].HideWindow();
	}
	Relayout();
	if (n == 0)
		SetStatus(NoGamesText);
	else
		SetStatus(GamesText);
	if (bTestJoin && n > 0)
	{
		bTestJoin = false;
		JoinGame(0);
	}
	if (bTestLeave)
	{
		bTestLeave = false;
		TestLeaveAt = GetLevel().TimeSecondsAlways + 5.0;
	}
}

// Tests: the Escape key, as ShellMenuCW.execBackButton sends it.
function TestEscape()
{
	local EInputKey Key;
	local EInputAction Action;

	Key = IK_Escape;
	Action = IST_Release;
	KeyEvent(Key, Action, 0);
}

function JoinGame(int i)
{
	if (GameLobbies[i] == "")
		return;
	log("P2Coop: co-op menu joins lobby"@GameLobbies[i]@GameChoices[i].Text);
	StopRelay();
	StartRelay("join", "JOIN" @ GameLobbies[i], JoinTimeout);
	if (Waiting == "join")
		SetStatus(JoiningText);
}

// Called by CoopRootWindow.Tick every frame while this page is up (the windows' own Tick does
// not reach it here).
function Poll()
{
	local string R;
	local float Now;

	Now = GetLevel().TimeSecondsAlways;	// the menu pauses the game
	if (TestLeaveAt > 0 && Now > TestLeaveAt)
	{
		TestLeaveAt = 0;
		TestEscape();
		return;
	}
	if (Waiting == "" || Now < NextPoll)
		return;
	NextPoll = Now + 0.5;
	R = Relay("STATUS");
	if (Left(R, 5) == "error")
	{
		StopRelay();
		SetStatus(ErrorText @ Mid(R, 6));
	}
	else if (Waiting == "host" && Left(R, 7) == "hosting")
	{
		Waiting = "";
		class'CoopStart'.static.NewGame(self, Port);
	}
	else if (Waiting != "host" && Left(R, 5) == "ready")
	{
		Waiting = "";
		Travel(Mid(R, 6));
	}
	else if (Waiting == "list" && Left(R, 5) == "hosts")
		ShowGames(R);
	else if (Now > GiveUp && (Waiting != "list" || !bListed))
	{
		StopRelay();
		SetStatus(TimeoutText);
	}
	else if (R == "searching" && Waiting == "list")
		SetStatus(SearchingText);
	else if (R == "joining")
		SetStatus(JoiningText);
}

// CoopRootWindow.MenuTest.
function TestPick(string Pick)
{
	if (Pick == "host")
		Notify(CreateChoice, DE_Click);
	else if (Pick == "leave")
		bTestLeave = true;	// see ShowGames and Poll
	else
		bTestJoin = true;
}

function Notify(UWindowDialogControl C, byte E)
{
	local int i;

	Super.Notify(C, E);
	if (E != DE_Click || C == None)
		return;
	if (C == CreateChoice)
	{
		StopRelay();
		StartRelay("host", "HOST" @ class'CoopStart'.static.StartMap() @ Port, HostTimeout);
		return;
	}
	if (C == BackChoice)
	{
		GoBack();
		return;
	}
	for (i = 0; i < ArrayCount(GameChoices); i++)
		if (C == GameChoices[i])
			JoinGame(i);
}

defaultproperties
{
	TitleText="Co-op over Steam"
	CreateText="Create game"
	CreateHelp="Start a new game (Monday) that your Steam friends can join."
	JoinGameText="Join"
	JoinGameHelp="Join this Steam friend's co-op game."
	StartingText="Starting the Steam relay..."
	SearchingText="Looking for Steam friends who are hosting..."
	NoGamesText="No Steam friend is hosting right now. Their games show up here as they create them."
	GamesText="Pick a friend's game, or create your own."
	CreatingText="Opening a friends-only Steam lobby..."
	JoiningText="Joining the friend's game..."
	NoRelayText="Steam co-op is not installed (P2Coop's dinput8.dll in System, the P2CoopLink folder)."
	TimeoutText="The Steam relay did not answer. Is Steam running and are you online?"
	ErrorText="Steam co-op:"
}
