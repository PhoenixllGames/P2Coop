//=============================================================================
// CoopTestJail: the whole group goes to jail, ?CoopTest=jail on the host.
// Phase "jail": gives both players a pistol (the client also a shotgun) and has the client
//   arrested (SendPlayerToJail, as the police do).
// Phase "jail2" (the jail map): checks that everyone is there, together, nobody is wanted, and
//   the evidence room took both players' weapons (CoopJailer for the client).
//=============================================================================
class CoopTestJail extends CoopTestBase;

var string Phase, ClientName;
var CoopJailer Jailer;
var float Dist;
var int Pistols;
var P2WeaponPickup WP;

function PostBeginPlay()
{
	Super.PostBeginPlay();
	Phase = CoopGame(Level.Game).URLOption("CoopTest");
	ClientName = CoopGame(Level.Game).URLOption("CoopClient");
	log("P2CoopTest: jail phase"@Phase@"map"@CurrentMap());
}

function RemoteJoined(PlayerController P)
{
	if (ClientName == "" || P.PlayerReplicationInfo.PlayerName == ClientName)
		Super.RemoteJoined(P);
}

// The jail takes this kind of item.
function bool Confiscated(class<Inventory> InvClass)
{
	local int i;

	for (i = 0; i < Jailer.Drops.Length; i++)
		if (Jailer.Drops[i].InvClass == InvClass && !Jailer.Drops[i].bDestroy)
			return true;
	return false;
}

state Running
{
Begin:
	while (Remote.Pawn == None || Lead.Pawn == None)
		Sleep(0.5);
	Sleep(3.0);
	if (Phase == "jail")
	{
		Give(Lead.Pawn, class'Inventory.PistolWeapon');
		Give(Remote.Pawn, class'Inventory.PistolWeapon');
		Give(Remote.Pawn, class'Inventory.ShotGunWeapon');
		Sleep(2.0);
		CoopGame(Level.Game).TravelOptions = CarryOptions("jail2")
			$ "?CoopClient="$Remote.PlayerReplicationInfo.PlayerName;
		log("P2CoopTest: the client is arrested");
		CoopGame(Level.Game).SendPlayerToJail(Remote);
		Stop;
	}
	Sleep(4.0);
	Jailer = CoopGame(Level.Game).Jailer;
	Check("jail-map", Left(CurrentMap(), 6) ~= "police", "map"@CurrentMap());
	Check("jail-evidence-room", Jailer != None && Jailer.Drops.Length > 0, "jailer"@Jailer);
	if (Jailer == None)
	{
		Finish();
		Stop;
	}
	Check("jail-pistol-taken", Confiscated(class'Inventory.PistolWeapon'), "the evidence room takes pistols");
	Check("jail-leader-searched", !Has(Lead.Pawn, class'Inventory.PistolWeapon'), "");
	Check("jail-client-searched", !Has(Remote.Pawn, class'Inventory.PistolWeapon')
		&& (!Confiscated(class'Inventory.ShotGunWeapon') || !Has(Remote.Pawn, class'Inventory.ShotGunWeapon')), "");
	foreach DynamicActors(class'P2WeaponPickup', WP)
		if (WP.InventoryType == class'Inventory.PistolWeapon')
			Pistols++;
	Check("jail-evidence-both", Pistols >= 2, "pistols in the room"@Pistols);
	Dist = VSize(Remote.Pawn.Location - Lead.Pawn.Location);
	Check("jail-together", Dist < 800, "distance"@Dist);
	Check("jail-not-wanted", CoopGame(Level.Game).TheGameState.CopRadioTime <= 0,
		"radio"@CoopGame(Level.Game).TheGameState.CopRadioTime);
	Finish();
}

defaultproperties
{
	TestName="jail"
}
