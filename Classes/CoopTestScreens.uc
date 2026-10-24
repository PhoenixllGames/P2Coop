//=============================================================================
// CoopTestScreens: client map, newspaper and HUD, ?CoopTest=screens on the host.
// Checks that the client:
//   - has a copy of the host's state (CoopReplicationInfo -> CoopShadowGame) with the same day,
//   - gets an errand the host completes and its haters,
//   - shows the host's wanted level on its HUD,
//   - opens its own map when the server asks (the map item) and with the map key,
//   - gets the host's newspaper,
//   - is back in PlayerWalking and moves once the screens are closed.
//=============================================================================
class CoopTestScreens extends CoopTestBase;

var GameState gs;
var DayBase Day;
var int ErrandIndex;
var vector ClientStart;

function Report()
{
	bGotScreens = false;
	Remote.ClientTestScreens();
}

// Today's first errand not done yet.
function int OpenErrand()
{
	local int e;

	for (e = 0; e < Day.Errands.Length; e++)
		if (!Day.Errands[e].bCompleted)
			return e;
	return -1;
}

state Running
{
Begin:
	while (Remote.Pawn == None)
		Sleep(0.5);
	Sleep(3.0);
	gs = CoopGame(Level.Game).TheGameState;
	Day = CoopGame(Level.Game).Days[gs.CurrentDay];

	Report();
	Sleep(1.0);
	Check("client-state-copy", bGotScreens && bClientShadow, "report="$bGotScreens@"copy="$bClientShadow);
	Check("client-day", ClientDay == gs.CurrentDay, "client"@ClientDay@"host"@gs.CurrentDay);

	ErrandIndex = OpenErrand();
	if (ErrandIndex >= 0)
	{
		log("P2CoopTest: host completes"@Day.Errands[ErrandIndex].UniqueName);
		Day.Errands[ErrandIndex].ForceCompletion(gs, P2Player(Lead));
		CoopGame(Level.Game).SaveCompletedErrand(gs.CurrentDay, ErrandIndex);
		gs.ErrandsCompletedToday++;
	}
	gs.CopRadioTime = gs.CopRadioMax * 0.5;
	Sleep(2.5);
	Report();
	Sleep(1.0);
	Check("client-errands", ErrandIndex >= 0 && ClientCompleted == class'CoopReplicationInfo'.static.ErrandList(gs.CompletedErrands)
		&& ClientDoneToday == gs.ErrandsCompletedToday,
		"client ["$ClientCompleted$"]"@ClientDoneToday@"host ["$class'CoopReplicationInfo'.static.ErrandList(gs.CompletedErrands)$"]"@gs.ErrandsCompletedToday);
	Check("client-haters", ClientHaters == gs.CurrentHaters.Length, "client"@ClientHaters@"host"@gs.CurrentHaters.Length);
	Check("client-wanted", Abs(ClientWanted - gs.CopsWantPlayer()) < 0.1 && ClientHUDWanted > 0,
		"client"@ClientWanted@"hud"@ClientHUDWanted@"host"@gs.CopsWantPlayer());

	// The map item on the server (MapInv.Activated -> RequestMap) for the remote player.
	Remote.RequestMap();
	Sleep(2.0);
	Report();
	Sleep(1.0);
	Check("client-map-from-server", InStr(ClientOpen, "map") >= 0 && ClientState == "CoopClientScreen",
		"open=["$ClientOpen$"] state="$ClientState);
	Check("server-not-in-screen-state", !Remote.IsInState('WaitMapScreen') && !Remote.IsInState('WaitScreen'),
		"state"@Remote.GetStateName());
	// Press the "done" key a few times, as a player would.
	for (EndPresses = 0; EndPresses < 6; EndPresses++)
	{
		Remote.ClientTestEndScreens();
		Sleep(1.0);
	}
	Sleep(4.0);
	Report();
	Sleep(1.0);
	Check("client-map-closed", ClientOpen == "" && ClientState == "PlayerWalking", "open=["$ClientOpen$"] state="$ClientState);

	// The map key on the client.
	Remote.ClientTestCommand("QuickUseMap");
	Sleep(2.0);
	Report();
	Sleep(1.0);
	Check("client-map-key", InStr(ClientOpen, "map") >= 0, "open=["$ClientOpen$"] state="$ClientState);
	// Press the "done" key a few times, as a player would.
	for (EndPresses = 0; EndPresses < 6; EndPresses++)
	{
		Remote.ClientTestEndScreens();
		Sleep(1.0);
	}
	Sleep(4.0);

	// A story newspaper for the host's player goes to everyone.
	P2Player(Lead).DisplayNews();
	Sleep(2.0);
	Report();
	Sleep(1.0);
	Check("client-news", InStr(ClientOpen, "news") >= 0, "open=["$ClientOpen$"] state="$ClientState);
	// Press the "done" key a few times, as a player would.
	for (EndPresses = 0; EndPresses < 6; EndPresses++)
	{
		Remote.ClientTestEndScreens();
		if (P2Player(Lead).MyNewsScreen != None && P2Player(Lead).MyNewsScreen.IsRunning())
			P2Player(Lead).MyNewsScreen.bPlayerWantsToEnd = true;
		Sleep(1.0);
	}
	Sleep(5.0);
	Report();
	Sleep(1.0);
	Check("client-news-closed", ClientOpen == "" && ClientState == "PlayerWalking", "open=["$ClientOpen$"] state="$ClientState);

	ClientStart = Remote.Pawn.Location;
	Remote.ClientTestDrive(6000, 1.5);
	Sleep(3.0);
	Check("client-moves-after", VSize(Remote.Pawn.Location - ClientStart) > 100,
		"moved"@VSize(Remote.Pawn.Location - ClientStart));
	Finish();
}

defaultproperties
{
	TestName="screens"
}
