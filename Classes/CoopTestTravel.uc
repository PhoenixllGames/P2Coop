//=============================================================================
// CoopTestTravel: map travel for the group, ?CoopTest=travel on the host.
// Phase "travel" (start map): gives the leader a shotgun and the client a pistol,
//   then the *client's* touch sends everyone through the first telepad.
// Phase "travel2" (next map), "travel3" (back): after the client rejoins, checks
//   that the leader still has the GameState (same day), both kept their items,
//   the client stands near the leader, and the client sees the leader.
//   travel2 goes back through the telepad that leads to the start map.
//=============================================================================
class CoopTestTravel extends CoopTestBase;

var string Phase, StartMap, ClientName;
var int StartDay;
var Telepad Pad;
var float Dist;
var int Tries;		// state code loop counter (no locals there)

function PostBeginPlay()
{
	Super.PostBeginPlay();
	Phase = CoopGame(Level.Game).URLOption("CoopTest");
	StartMap = CoopGame(Level.Game).URLOption("CoopStartMap");
	StartDay = int(CoopGame(Level.Game).URLOption("CoopStartDay"));
	ClientName = CoopGame(Level.Game).URLOption("CoopClient");
	log("P2CoopTest: travel phase"@Phase@"map"@CurrentMap()@"client"@ClientName);
}

// After a travel the clients reconnect in any order: follow the one that got the items.
function RemoteJoined(PlayerController P)
{
	if (ClientName == "" || P.PlayerReplicationInfo.PlayerName == ClientName)
		Super.RemoteJoined(P);
}

// "" if every weapon has its ammo and no item is there twice; otherwise what is wrong.
function string InventoryProblem(Pawn P)
{
	local Inventory A, B;
	local string S;

	for (A = P.Inventory; A != None; A = A.Inventory)
	{
		if (Weapon(A) != None && (Weapon(A).AmmoType == None || Weapon(A).AmmoType.bDeleteMe))
			S = S @ A.Class.Name $ ":no-ammo";
		for (B = A.Inventory; B != None; B = B.Inventory)
			if (B.Class == A.Class)
				S = S @ A.Class.Name $ ":twice";
	}
	return S;
}

function Travel(string NextPhase, string MapName)
{
	Pad = FindPad(MapName);
	if (Pad == None)
	{
		Check("telepad-found", false, "no telepad on"@CurrentMap());
		Finish();
		return;
	}
	log("P2CoopTest: client"@Remote@"triggers travel through"@Pad@Pad.URL);
	// The client is the one who "touched" the telepad: CoopGame must still move everyone.
	CoopGame(Level.Game).TravelOptions = CarryOptions(NextPhase)
		$ "?CoopStartMap="$StartMap$"?CoopStartDay="$StartDay
		$ "?CoopClient="$Remote.PlayerReplicationInfo.PlayerName;
	CoopGame(Level.Game).SendPlayerTo(Remote, Pad.URL);
}

state Running
{
Begin:
	while (Remote.Pawn == None || Lead.Pawn == None)
		Sleep(0.5);
	Sleep(3.0);
	if (Phase == "travel")
	{
		StartMap = CurrentMap();
		StartDay = CoopGame(Level.Game).TheGameState.CurrentDay;
		Give(Lead.Pawn, class'Inventory.ShotGunWeapon');
		Give(Remote.Pawn, class'Inventory.PistolWeapon');
		Sleep(1.0);
		Travel("travel2", "");
		Stop;
	}

	// travel2 / travel3: we arrived together on a new map
	Check(Phase$"-gamestate", CoopGame(Level.Game).TheGameState != None
		&& CoopGame(Level.Game).TheGameState.CurrentDay == StartDay,
		"day"@CoopGame(Level.Game).TheGameState.CurrentDay@"start day"@StartDay);
	Check(Phase$"-leader-items", Has(Lead.Pawn, class'Inventory.ShotGunWeapon'), "");
	Check(Phase$"-client-items", Has(Remote.Pawn, class'Inventory.PistolWeapon')
		&& Has(Remote.Pawn, class'Inventory.MapInv'), "");
	Check(Phase$"-client-inventory-whole", InventoryProblem(Remote.Pawn) == "", InventoryProblem(Remote.Pawn));
	Dist = VSize(Remote.Pawn.Location - Lead.Pawn.Location);
	Check(Phase$"-client-near-leader", Dist < 800, "distance"@Dist);
	Check(Phase$"-both-alive", Lead.Pawn.Health > 0 && Remote.Pawn.Health > 0,
		"health"@Lead.Pawn.Health@Remote.Pawn.Health);
	// Right after a join the client can still be settling in (a slow machine answers late, and the
	// leader's pawn may not be his yet): ask again every 2 seconds until he reports the leader,
	// for up to 20 seconds.
	bGotReport = false;
	bSawLeader = false;
	for (Tries = 0; Tries < 40 && !(bGotReport && bSawLeader); Tries++)
	{
		if (Tries % 4 == 0)
			Remote.ClientTestLook(Lead.PlayerReplicationInfo.PlayerName);
		Sleep(0.5);
	}
	log("P2CoopTest: leader report after"@Tries * 0.5@"s");
	Check(Phase$"-client-sees-leader", bGotReport && bSawLeader
		&& VSize(SeenLeaderLoc - Lead.Pawn.Location) < 64, "client"@SeenLeaderLoc@"server"@Lead.Pawn.Location);

	if (Phase == "travel2")
	{
		Check("travel2-left-start-map", CurrentMap() != StartMap, "map"@CurrentMap()@"start"@StartMap);
		Travel("travel3", StartMap);
		Stop;
	}
	Check("travel3-back-on-start-map", CurrentMap() ~= StartMap, "map"@CurrentMap()@"start"@StartMap);
	Finish();
}

defaultproperties
{
	TestName="travel"
}
