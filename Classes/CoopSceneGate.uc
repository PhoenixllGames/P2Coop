//=============================================================================
// CoopSceneGate: starts a camera cutscene for the group (see CoopGame.GateScenes).
//
// SceneManager.Trigger does not start a camera scene while any PlayerController has no living
// pawn: in SP that was a dead dude, who reloads anyway. In co-op a player waiting to respawn, or
// still joining, would make the story's trigger do nothing, and a trigger that fires once is
// lost. The gate takes the scene's Tag, so the trigger comes here first: players waiting to
// respawn come back now, and a player still without a pawn lends the leader's for the
// SceneManager's check. The leader's own pawn (the scene's viewer) is checked as in SP.
//=============================================================================
class CoopSceneGate extends Info;

var SceneManager Scene;

function Gate(SceneManager SM)
{
	Scene = SM;
	Tag = SM.Tag;
	SM.Tag = 'P2CoopGatedScene';
	log("P2Coop: scene"@SM@"is started through"@self@"tag"@Tag);
}

function Trigger(Actor Other, Pawn EventInstigator)
{
	local CoopGame G;
	local Controller C;
	local PlayerController L;
	local Pawn Anchor;
	local array<Controller> Lent;
	local array<Pawn> Own;
	local int i;

	if (Scene == None)
		return;
	G = CoopGame(Level.Game);
	if (G == None)
	{
		Scene.Trigger(Other, EventInstigator);
		return;
	}
	L = G.Leader();
	for (C = Level.ControllerList; C != None; C = C.NextController)
		if (CoopPlayer(C) != None && C != L && CoopPlayer(C).bRespawning && (C.Pawn == None || C.Pawn.Health <= 0))
		{
			log("P2Coop:"@C.PlayerReplicationInfo.PlayerName@"respawns now for the cutscene"@Scene);
			G.RestartPlayer(C);
		}
	Anchor = G.LivingPlayerPawn(None);
	if (Anchor != None)
		for (C = Level.ControllerList; C != None; C = C.NextController)
			if (PlayerController(C) != None && C != L && PlayerController(C).GetCurrentSceneManager() == None
				&& (C.Pawn == None || C.Pawn.Health <= 0))
			{
				Lent[Lent.Length] = C;
				Own[Own.Length] = C.Pawn;
				C.Pawn = Anchor;
			}
	if (Lent.Length > 0)
		log("P2Coop:"@Lent.Length@"players without a pawn do not stop the cutscene"@Scene);
	Scene.Trigger(Other, EventInstigator);
	for (i = 0; i < Lent.Length; i++)
		if (Lent[i] != None)
			Lent[i].Pawn = Own[i];
}

function UnTrigger(Actor Other, Pawn EventInstigator)
{
	if (Scene != None)
		Scene.UnTrigger(Other, EventInstigator);
}

defaultproperties
{
	RemoteRole=ROLE_None
}
