//=============================================================================
// CoopMenu: host or join a co-op game from the game itself (CoopMenuMain -> "Co-op").
//
// Over Steam: the Steam page (CoopSteamMenu) lists the friends who host, and creates games.
// By address (LAN, or a forwarded port) needs no relay. A host starts a new game as the stock
// New Game does (CoopStart).
//=============================================================================
class CoopMenu extends ShellMenuCW
	config(User);

var ShellMenuChoice SteamChoice, HostChoice, JoinChoice;
var UWindowEditControl AddressEdit;
var ShellWrappedTextControl StatusItem;
var config string LastAddress;

var localized string TitleText;
var localized string SteamText, SteamHelp;
var localized string HostText, HostHelp, AddressText, AddressHelp, JoinText, JoinHelp;
var localized string NoAddressText;
var localized string CreditText;

const Port = "7777";

function CreateMenuContents()
{
	local array<string> Lines;

	class'CoopText'.static.Translate(self, "CoopMenu", "TitleText SteamText SteamHelp "
		$ "HostText HostHelp AddressText AddressHelp JoinText JoinHelp NoAddressText CreditText");
	Super.CreateMenuContents();
	TitleAlign = TA_Left;
	ItemAlign = TA_Left;
	AddTitle(TitleText, TitleFont, TitleAlign);
	SteamChoice = AddChoice(SteamText, SteamHelp, ItemFont, ItemAlign);
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

function Travel(string URL)
{
	log("P2Coop: co-op menu opens"@URL);
	ShellRootWindow(Root).HideMenu();
	GetPlayerOwner().ConsoleCommand("open" @ URL);
}

// Also CoopRootWindow.MenuTest, whose pick the Steam page takes.
function OpenSteam()
{
	GoToMenu(class'CoopSteamMenu');
}

function Notify(UWindowDialogControl C, byte E)
{
	local string Address;

	Super.Notify(C, E);
	if (E != DE_Click || C == None)
		return;
	switch (C)
	{
		case SteamChoice:
			OpenSteam();
			break;
		case HostChoice:
			class'CoopStart'.static.NewGame(self, Port);
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
			GoBack();
			break;
	}
}

defaultproperties
{
	TitleText="Co-op"
	SteamText="Play over Steam"
	SteamHelp="Join a Steam friend's game, or create one your friends can join. No ports to open."
	HostText="Host by address"
	HostHelp="Start a new game that others join by your address (LAN, or UDP port 7777 forwarded)."
	AddressText="Address"
	AddressHelp="The host's address, e.g. 192.168.1.10 or 203.0.113.5:7777."
	JoinText="Join by address"
	JoinHelp="Connect to the host at the address above."
	NoAddressText="Type the host's address first."
	CreditText="P2Coop co-op mod by PhoenixllGames"
}
