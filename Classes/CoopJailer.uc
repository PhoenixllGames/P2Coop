//=============================================================================
// CoopJailer: in jail, everyone's things go to the evidence room, not just the leader's.
//
// Stock CheckToTransferPlayerInventory runs once when the jail level starts and only for the
// leader: it moves his items into the room's "transfer" pickups and destroys the rest. The other
// players come in later (they reconnect after the travel), so CoopGame spawns this first: it
// notes the transfer pickups, and takes each remote player's matching items as he arrives,
// leaving them in new pickups of the same kind in the evidence room.
//=============================================================================
class CoopJailer extends Info;

struct Drop
{
	var class<Pickup> PickupClass;
	var class<Inventory> InvClass;
	var vector Loc;
	var rotator Rot;
	var bool bDestroy;		// the cops keep it (bDestroyAfterTransfer)
};
var array<Drop> Drops;
var array<string> Done;		// players already searched
var float Until;

const Window = 180.0;			// seconds after the level start in which arrivals are searched
const InventoryDelay = 2.0;		// a joiner's inventory needs a moment to arrive

// Before the stock transfer runs: note the evidence room's pickups.
function Record()
{
	local P2PowerupPickup PP;
	local P2WeaponPickup WP;

	foreach DynamicActors(class'P2PowerupPickup', PP)
		if (PP.bForTransferOnly)
			Add(PP, PP.InventoryType, PP.bDestroyAfterTransfer);
	foreach DynamicActors(class'P2WeaponPickup', WP)
		if (WP.bForTransferOnly)
			Add(WP, WP.InventoryType, WP.bDestroyAfterTransfer);
	Until = Level.TimeSeconds + Window;
	log("P2Coop: jail, evidence room takes"@Drops.Length@"kinds of items");
}

function Add(Pickup P, class<Inventory> InvClass, bool bDestroy)
{
	local int i;

	i = Drops.Length;
	Drops.Insert(i, 1);
	Drops[i].PickupClass = P.Class;
	Drops[i].InvClass = InvClass;
	Drops[i].Loc = P.Location;
	Drops[i].Rot = P.Rotation;
	Drops[i].bDestroy = bDestroy;
}

function Tick(float DeltaTime)
{
	local Controller C;
	local CoopPlayer P;

	if (Level.TimeSeconds > Until)
	{
		Destroy();
		return;
	}
	for (C = Level.ControllerList; C != None; C = C.NextController)
	{
		P = CoopPlayer(C);
		if (P != None && P.IsRemote() && P.Pawn != None && P.Pawn.Health > 0
			&& Level.TimeSeconds - P.JoinTime >= InventoryDelay && !Searched(P))
			TakeItems(P);
	}
}

function bool Searched(CoopPlayer P)
{
	local int i;

	for (i = 0; i < Done.Length; i++)
		if (Done[i] == P.PlayerReplicationInfo.PlayerName)
			return true;
	return false;
}

function TakeItems(CoopPlayer P)
{
	local int i, Taken;
	local Inventory Inv;
	local Pickup Pick;
	local P2Weapon W;

	Done[Done.Length] = P.PlayerReplicationInfo.PlayerName;
	for (i = 0; i < Drops.Length; i++)
	{
		Inv = P.Pawn.FindInventoryType(Drops[i].InvClass);
		if (Inv == None)
			continue;
		if (!Drops[i].bDestroy)
		{
			Pick = Spawn(Drops[i].PickupClass,,, Drops[i].Loc + VRand() * 4, Drops[i].Rot);
			if (Pick != None)
			{
				if (P2PowerupInv(Inv) != None)
					P2PowerupInv(Inv).bThrowIndividually = false;
				Pick.InitDroppedPickupFor(Inv);
				if (P2WeaponPickup(Pick) != None)
					P2WeaponPickup(Pick).bPersistent = true;
				else if (P2PowerupPickup(Pick) != None)
					P2PowerupPickup(Pick).bPersistent = true;
			}
		}
		W = P2Weapon(Inv);
		if (W != None && W.AmmoType != None)
		{
			W.AmmoType.DetachFromPawn(P.Pawn);
			P.Pawn.DeleteInventory(W.AmmoType);
		}
		Inv.DetachFromPawn(P.Pawn);
		P.Pawn.DeleteInventory(Inv);
		Taken++;
	}
	P.CheckInventoryAfterItsTaken();
	if (P2Pawn(P.Pawn) != None)
		P2Pawn(P.Pawn).Armor = 0;
	P.ResetHandsToggle();
	P.SwitchToHands(true);
	log("P2Coop: jail took"@Taken@"items from"@P.PlayerReplicationInfo.PlayerName);
}
