//=============================================================================
// CoopMenu: host or join a co-op game from the game itself (CoopMenuMain -> "Co-op").
//
// Over Steam the relay P2CoopLink does the networking. P2CoopHk.dll starts it on the console
// command "P2COOP LINK ..." and reports its status line, which this menu polls:
//   host: the relay opens a friends-only lobby ("hosting <lobby>"), then this game starts the
//         first map as a listen server and the relay passes the friends' packets to it;
//   join: the relay finds the friend who hosts ("searching", "choose" when several do,
//         "joining"), checks versions, and gives a local address ("ready 127.0.0.1:<port>")
//         that this game connects to.
// Without the hook (the stock Postal2.exe) the console command returns nothing.
// By address (LAN, or a forwarded port) needs no relay.
//=============================================================================
class CoopMenu extends ShellMenuCW
	config(User);

var ShellMenuChoice SteamHostChoice, SteamJoinChoice, HostChoice, JoinChoice;
var UWindowEditControl AddressEdit;
var ShellWrappedTextControl StatusItem;
var config string LastAddress;

var localized string TitleText;
var localized string SteamHostText, SteamHostHelp, SteamJoinText, SteamJoinHelp;
var localized string HostText, HostHelp, AddressText, AddressHelp, JoinText, JoinHelp;
var localized string StartingText, SearchingText, ChooseText, JoiningText, NoAddressText;
var localized string NoRelayText, TimeoutText, ErrorText;
var localized string CreditText;

var string Waiting;			// "host" or "join" while the relay starts
var float Elapsed, NextPoll, GiveUp;	// Level.TimeSecondsAlways

const StartMap = "suburbs-3";	// Monday, as a new game starts
const Port = "7777";

function CreateMenuContents()
{
	local array<string> Lines;

	class'CoopText'.static.Translate(self, "CoopMenu", "TitleText SteamHostText SteamHostHelp SteamJoinText SteamJoinHelp "
		$ "HostText HostHelp AddressText AddressHelp JoinText JoinHelp StartingText SearchingText ChooseText "
		$ "JoiningText NoAddressText NoRelayText TimeoutText ErrorText CreditText");
	Super.CreateMenuContents();
	TitleAlign = TA_Left;
	ItemAlign = TA_Left;
	AddTitle(TitleText, TitleFont, TitleAlign);
	SteamHostChoice = AddChoice(SteamHostText, SteamHostHelp, ItemFont, ItemAlign);
	SteamJoinChoice = AddChoice(SteamJoinText, SteamJoinHelp, ItemFont, ItemAlign);
	HostChoice = AddChoice(HostText, HostHelp, ItemFont, ItemAlign);
	AddressEdit = AddEditBox(AddressText, AddressHelp, ItemFont);
	AddressEdit.SetValue(LastAddress);
	JoinChoice = AddChoice(JoinText, JoinHelp, ItemFont, ItemAlign);
	BackChoice = AddChoice(BackText, "", ItemFont, ItemAlign, true);
	Lines[0] = " ";
	StatusItem = AddWrappedTextItem(Lines, ItemHeight * 2, ItemFont, TA_Left);
	Lines[0] = CreditText;
	AddWrappedTextItem(Lines, ItemHeight, F_FancyS, TA_Left);
}

function SetStatus(string Text)
{
	StatusItem.Text = Text;
	log("P2Coop: co-op menu:"@Text);
}

function string Relay(string Cmd)
{
	return GetPlayerOwner().ConsoleCommand("P2COOP LINK" @ Cmd);
}

function StartRelay(string Mode, string Cmd, float Timeout)
{
	local string R;

	Elapsed = GetLevel().TimeSecondsAlways;
	R = Relay(Cmd);
	if (R == "")
		SetStatus(NoRelayText);
	else if (Left(R, 5) == "error")
		SetStatus(ErrorText @ Mid(R, 6));
	else
	{
		Waiting = Mode;
		GiveUp = Elapsed + Timeout;
		NextPoll = Elapsed + 0.5;
		SetStatus(StartingText);
	}
}

function Travel(string URL)
{
	log("P2Coop: co-op menu opens"@URL);
	ShellRootWindow(Root).HideMenu();
	GetPlayerOwner().ConsoleCommand("open" @ URL);
}

// Called by CoopRootWindow.Tick every frame while this menu is up (the windows' own Tick does
// not reach it here).
function Poll()
{
	local string R;

	Elapsed = GetLevel().TimeSecondsAlways;	// the menu pauses the game
	if (Waiting == "" || Elapsed < NextPoll)
		return;
	NextPoll = Elapsed + 0.5;
	R = Relay("STATUS");
	if (Left(R, 5) == "error")
	{
		Waiting = "";
		SetStatus(ErrorText @ Mid(R, 6));
	}
	else if (Waiting == "host" && Left(R, 7) == "hosting")
	{
		Waiting = "";
		Travel(StartMap $ "?Game=P2Coop.CoopGame?Listen?Port=" $ Port);
	}
	else if (Waiting == "join" && Left(R, 5) == "ready")
	{
		Waiting = "";
		Travel(Mid(R, 6));
	}
	else if (Elapsed > GiveUp)
	{
		Waiting = "";
		Relay("STOP");
		SetStatus(TimeoutText);
	}
	else if (R == "searching")
		SetStatus(SearchingText);
	else if (R == "choose")
		SetStatus(ChooseText);
	else if (R == "joining")
		SetStatus(JoiningText);
}

// CoopRootWindow.MenuTest.
function TestPick(string Pick)
{
	if (Pick == "host")
		Notify(SteamHostChoice, DE_Click);
	else
		Notify(SteamJoinChoice, DE_Click);
}

function Notify(UWindowDialogControl C, byte E)
{
	local string Address;

	Super.Notify(C, E);
	if (E != DE_Click || C == None)
		return;
	switch (C)
	{
		case SteamHostChoice:
			StartRelay("host", "HOST" @ StartMap @ Port, 30);
			break;
		case SteamJoinChoice:
			StartRelay("join", "JOIN", 180);
			break;
		case HostChoice:
			Travel(StartMap $ "?Game=P2Coop.CoopGame?Listen?Port=" $ Port);
			break;
		case JoinChoice:
			Address = AddressEdit.GetValue();
			if (Address == "")
			{
				SetStatus(NoAddressText);
				break;
			}
			LastAddress = Address;
			SaveConfig();
			Travel(Address);
			break;
		case BackChoice:
			if (Waiting != "")
				Relay("STOP");
			Waiting = "";
			GoBack();
			break;
	}
}

defaultproperties
{
	TitleText="Co-op"
	SteamHostText="Host over Steam"
	SteamHostHelp="Start a new game (Monday) that your Steam friends can join. No ports to open."
	SteamJoinText="Join a friend over Steam"
	SteamJoinHelp="Join the Steam friend who is hosting a co-op game."
	HostText="Host by address"
	HostHelp="Start a new game that others join by your address (LAN, or UDP port 7777 forwarded)."
	AddressText="Address"
	AddressHelp="The host's address, e.g. 192.168.1.10 or 203.0.113.5:7777."
	JoinText="Join by address"
	JoinHelp="Connect to the host at the address above."
	StartingText="Starting the Steam relay..."
	SearchingText="Looking for a Steam friend who is hosting..."
	ChooseText="Several friends are hosting: pick one in the P2Coop Steam window (taskbar)."
	JoiningText="Joining the friend's game..."
	NoAddressText="Type the host's address first."
	NoRelayText="Steam co-op needs the P2Coop launcher (P2Coop.bat or P2CoopHost.exe)."
	TimeoutText="The Steam relay did not get ready. Is Steam running and are you online?"
	ErrorText="Steam co-op:"
	CreditText="P2Coop co-op mod by PhoenixllGames"
}
