//=============================================================================
// CoopMenuMain: the main menu with a "Co-op" choice (CoopMenu) above Options, and the mod's
// credit line. CoopRootWindow shows it in place of the stock MenuMain.
//=============================================================================
class CoopMenuMain extends MenuMain;

var ShellMenuChoice CoopChoice;
var localized string CoopText, CoopHelp;
var localized string CreditText;

function CreateMenuContents()
{
	local array<string> Credit;

	class'CoopText'.static.Translate(self, "CoopMenuMain", "CoopText CoopHelp CreditText");
	Super.CreateMenuContents();
	CoopChoice = AddChoice(CoopText, CoopHelp, ItemFont, ItemAlign);
	MoveItemBefore(CoopChoice, OptionsChoice);
	Credit[0] = CreditText;
	AddWrappedTextItem(Credit, ItemHeight, F_FancyS, TA_Center);
}

// Moves the last added item to the place of Before; the items after it move down.
function MoveItemBefore(UWindowWindow Item, UWindowWindow Before)
{
	local int i, From, To;
	local MenuItem Moved;
	local float Y;

	From = MenuItems.Length - 1;
	for (To = 0; To < From; To++)
		if (MenuItems[To].Window == Before)
			break;
	if (MenuItems[From].Window != Item || To >= From)
		return;
	Moved = MenuItems[From];
	MenuItems.Remove(From, 1);
	MenuItems.Insert(To, 1);
	MenuItems[To] = Moved;
	Y = MenuItems[To + 1].PosY;
	for (i = To; i < MenuItems.Length; i++)
	{
		MenuItems[i].PosY = Y;
		MenuItems[i].Window.WinTop = Y;
		Y += MenuItems[i].Height;
	}
}

function Notify(UWindowDialogControl C, byte E)
{
	Super.Notify(C, E);
	if (E == DE_Click && C != None && C == CoopChoice)
		GoToMenu(class'CoopMenu');
}

defaultproperties
{
	CoopText="Co-op"
	CoopHelp="Play the week together: host a game or join a friend, over Steam or by address."
	CreditText="P2Coop co-op mod by PhoenixllGames"
}
