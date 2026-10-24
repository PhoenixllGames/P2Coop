//=============================================================================
// CoopTestErrand: errands done by a client, ?CoopTest=errand on the host.
// Finds an open errand of today that is done by picking up an item lying on this
// map (ErrandGoalGetPickup), moves that pickup onto the client's pawn, and lets the
// client's touch pick it up through the stock pickup code. Checks that:
//   - the errand is completed in the shared GameState,
//   - everyone was told (CoopGame.AnnounceErrand),
//   - the client is not stuck in a screen state (WaitMapScreen) on the server,
//   - the client shows the crossing out on its own map, and plays on once it is closed,
//   - the client still moves afterwards (its input is not swallowed),
//   - an errand crossed out on the host's map is shown and announced to the client too.
//=============================================================================
class CoopTestErrand extends CoopTestBase;

var ErrandBase Errand;
var int ErrandIndex;
var Pickup Item;
var string Announced, AnnouncedByHost;
var int CompletedBefore;
var vector ClientStart;

function ErrandAnnounced(PlayerController Who, string ErrandName)
{
	if (Who == Remote)
		Announced = ErrandName;
	else if (Who == Lead)
		AnnouncedByHost = ErrandName;
}

// Today's first open errand with a GetPickup goal whose pickup is on this map.
function bool FindErrandPickup()
{
	local CoopGame Game;
	local DayBase Day;
	local int e, g;
	local ErrandGoalGetPickup Goal;
	local Pickup P;

	Game = CoopGame(Level.Game);
	Day = Game.Days[Game.TheGameState.CurrentDay];
	for (e = 0; e < Day.Errands.Length; e++)
	{
		log("P2CoopTest: errand"@e@Day.Errands[e].UniqueName@"done="$Day.Errands[e].bCompleted
			@"active="$Day.Errands[e].bActivated@"goals="$Day.Errands[e].Goals.Length);
		if (Day.Errands[e].bCompleted)
			continue;
		for (g = 0; g < Day.Errands[e].Goals.Length; g++)
		{
			Goal = ErrandGoalGetPickup(Day.Errands[e].Goals[g]);
			if (Goal == None)
				continue;
			foreach DynamicActors(class'Pickup', P)
				if ((Goal.PickupTag != '' && P.Tag == Goal.PickupTag)
					|| (Goal.PickupClassName != '' && P.IsA(Goal.PickupClassName)))
				{
					Errand = Day.Errands[e];
					ErrandIndex = e;
					Item = P;
					log("P2CoopTest: using errand"@Errand.UniqueName@"pickup"@P@"tag"@Goal.PickupTag@"class"@Goal.PickupClassName);
					return true;
				}
		}
	}
	return false;
}

// Puts P on a free spot close to Spot with a clear line to it (the item may sit on a shelf).
function bool MoveNear(Pawn P, vector Spot)
{
	local int Ring, i;
	local vector Try, Dir;

	for (Ring = 1; Ring <= 4; Ring++)
		for (i = 0; i < 8; i++)
		{
			Dir.X = Cos(i * 0.7854);
			Dir.Y = Sin(i * 0.7854);
			Try = Spot + Dir * (Ring * P.CollisionRadius) + vect(0,0,1) * P.CollisionHeight;
			if (FastTrace(Spot, Try) && P.SetLocation(Try))
				return true;
		}
	return false;
}

state Running
{
Begin:
	while (Remote.Pawn == None)
		Sleep(0.5);
	Sleep(3.0);
	if (!FindErrandPickup())
	{
		Check("errand-pickup-on-map", false, "no open GetPickup errand with its pickup on this map");
		Finish();
		Stop;
	}
	CompletedBefore = CoopGame(Level.Game).TheGameState.ErrandsCompletedToday;
	log("P2CoopTest: pickup"@Item@"state"@Item.GetStateName()@"at"@Item.Location@"client at"@Remote.Pawn.Location);
	// Put the client's pawn next to the item: the stock Touch picks it up for the client.
	MoveNear(Remote.Pawn, Item.Location);
	Sleep(1.0);
	log("P2CoopTest: client pawn now at"@Remote.Pawn.Location@"distance"@VSize(Remote.Pawn.Location - Item.Location));
	// SetLocation does not raise Touch; run the stock touch with the client's pawn (ValidTouch,
	// PickupQuery, SpawnCopy and the errand check all run as in play).
	if (Item != None && !Item.bDeleteMe)
		Item.Touch(Remote.Pawn);
	Sleep(2.0);
	log("P2CoopTest: after touch: pickup"@Item@"client has milk"@Has(Remote.Pawn, class'Inventory.MilkInv'));
	Check("errand-completed", Errand.bCompleted && CoopGame(Level.Game).IsErrandCompleted(Errand.UniqueName),
		Errand.UniqueName@"bCompleted="$Errand.bCompleted);
	Check("errand-counted", CoopGame(Level.Game).TheGameState.ErrandsCompletedToday == CompletedBefore + 1,
		"today"@CompletedBefore@"->"@CoopGame(Level.Game).TheGameState.ErrandsCompletedToday);
	Check("errand-announced", Announced == Errand.UniqueName, "announced"@Announced);
	Check("client-not-in-screen-state", !Remote.IsInState('WaitMapScreen') && !Remote.IsInState('WaitScreen'),
		"state"@Remote.GetStateName());

	bGotScreens = false;
	Remote.ClientTestScreens();
	Sleep(1.0);
	Check("client-map-crossout", bGotScreens && InStr(ClientOpen, "map") >= 0 && ClientState == "CoopClientScreen",
		"open=["$ClientOpen$"] state="$ClientState);
	// Press the "done" key a few times, as a player would.
	for (EndPresses = 0; EndPresses < 6; EndPresses++)
	{
		Remote.ClientTestEndScreens();
		Sleep(1.0);
	}
	Sleep(5.0);

	ClientStart = Remote.Pawn.Location;
	Remote.ClientTestDrive(6000, 1.5);
	Sleep(3.0);
	Check("client-moves-after", VSize(Remote.Pawn.Location - ClientStart) > 100,
		"moved"@VSize(Remote.Pawn.Location - ClientStart));

	// The host's map crosses an errand out (as when he completes one): the client is told and
	// sees it on his own map.
	P2Player(Lead).DisplayMapCrossOut(ErrandIndex, 'None');
	Sleep(1.5);
	Check("host-errand-announced", AnnouncedByHost == Errand.UniqueName, "announced"@AnnouncedByHost);
	bGotScreens = false;
	Remote.ClientTestScreens();
	Sleep(1.0);
	Check("host-errand-client-crossout", bGotScreens && InStr(ClientOpen, "map") >= 0,
		"open=["$ClientOpen$"] state="$ClientState);
	for (EndPresses = 0; EndPresses < 6; EndPresses++)
	{
		Remote.ClientTestEndScreens();
		if (P2Player(Lead).MyMapScreen != None && P2Player(Lead).MyMapScreen.IsRunning())
			P2Player(Lead).MyMapScreen.bPlayerWantsToEnd = true;
		Sleep(1.0);
	}
	Finish();
}

defaultproperties
{
	TestName="errand"
}
