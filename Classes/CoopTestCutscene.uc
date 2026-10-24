//=============================================================================
// CoopTestCutscene: remote players watch the host's cutscene, ?CoopTest=cutscene on the host.
// Starts a camera SceneManager of this map for the host, through its CoopSceneGate as a map
// trigger would, while the client is dead, and checks that:
//   - the scene starts anyway, and the dead client is back for it,
//   - the client looks through the host's camera, input off (CoopClientCutscene),
//   - players take no damage meanwhile,
//   - a player who joins during the scene spawns next to the host's pawn (the scene holds it),
//     not at the map's start, and watches the scene too,
//   - after the scene (and the map or newspaper the game may show next) the client is back in
//     PlayerWalking and moves.
//=============================================================================
class CoopTestCutscene extends CoopTestBase;

var SceneManager Scene;
var CoopSceneGate Gate;
var Pawn OldPawn;
var float Dist;
var CoopCutscene Watcher;
var int HealthBefore;
var vector ClientStart;
var float Waited;

// A camera scene of this map with something in it, long enough for the checks made while it
// runs, started through its gate (CoopGame.GateScenes).
function CoopSceneGate FindGate()
{
	local SceneManager SM;
	local CoopSceneGate G, Best;

	foreach AllActors(class'SceneManager', SM)
		log("P2CoopTest: scene"@SM@"tag"@SM.Tag@"affect"@SM.Affect@"actions"@SM.Actions.Length
			@"time"@SM.TotalSceneTime@"running"@SM.bIsRunning);
	foreach DynamicActors(class'CoopSceneGate', G)
	{
		SM = G.Scene;
		log("P2CoopTest: gate"@G@"tag"@G.Tag@"scene"@SM@"time"@SM.TotalSceneTime);
		if (SM != None && SM.Actions.Length > 0 && SM.TotalSceneTime > 6
			&& (Best == None || SM.TotalSceneTime < Best.Scene.TotalSceneTime))
			Best = G;
	}
	return Best;
}

state Running
{
Begin:
	while (Remote.Pawn == None || Lead.Pawn == None)
		Sleep(0.5);
	Sleep(3.0);
	Watcher = CoopGame(Level.Game).Cutscene;
	Gate = FindGate();
	if (Gate == None)
	{
		Check("cutscene-on-map", false, "no gated camera SceneManager of more than 6 s on"@CurrentMap());
		Finish();
		Stop;
	}
	Scene = Gate.Scene;
	// A dead player must not stop the scene (SceneManager.Trigger refuses while a player has no
	// living pawn); he comes back for it.
	OldPawn = Remote.Pawn;
	Kill(Remote.Pawn);
	Sleep(0.5);
	Remote.RespawnTime = Level.TimeSeconds + 60;	// not back by the respawn delay
	Check("client-dead-before-scene", Remote.Pawn == None || Remote.Pawn.Health <= 0, "pawn"@Remote.Pawn);
	log("P2CoopTest: host starts"@Scene@"for"@Scene.TotalSceneTime@"s through"@Gate@"tag"@Gate.Tag);
	TriggerEvent(Gate.Tag, Lead, Lead.Pawn);
	Sleep(2.0);
	Check("host-in-cutscene", Watcher.Scene == Scene, "watching"@Watcher.Scene);
	Check("dead-client-back-for-scene", Remote.Pawn != None && Remote.Pawn != OldPawn && Remote.Pawn.Health > 0
		&& !Remote.bRespawning, "pawn"@Remote.Pawn@"respawning"@Remote.bRespawning);
	bGotCamera = false;
	Remote.ClientTestCamera();
	Sleep(0.5);
	Check("client-watches", bGotCamera && ClientState == "CoopClientCutscene", "state="$ClientState);
	Check("client-camera-is-hosts", bGotCamera && VSize(ClientCam - Watcher.CamLoc) < 300,
		"client"@ClientCam@"host"@Watcher.CamLoc@"distance"@VSize(ClientCam - Watcher.CamLoc));

	HealthBefore = Remote.Pawn.Health;
	Remote.Pawn.TakeDamage(20, None, Remote.Pawn.Location, vect(0,0,0), class'DamageType');
	Check("no-damage-in-cutscene", Remote.Pawn.Health == HealthBefore, "health"@HealthBefore@"->"@Remote.Pawn.Health);

	// A player who joins now (GameInfo.PostLogin -> RestartPlayer, no respawn pending): the
	// leader has no pawn, the scene holds it.
	OldPawn = Remote.Pawn;
	Kill(Remote.Pawn);
	Sleep(0.5);
	Remote.bRespawning = false;
	CoopGame(Level.Game).RestartPlayer(Remote);
	Check("joiner-in-scene-spawned", Remote.Pawn != None && Remote.Pawn != OldPawn && Remote.Pawn.Health > 0,
		"pawn"@Remote.Pawn@"state"@Remote.GetStateName()@"respawning"@Remote.bRespawning);
	Dist = 100000;
	if (Remote.Pawn != None && Scene.OldPawn != None)
		Dist = VSize(Remote.Pawn.Location - Scene.OldPawn.Location);
	Check("joiner-in-scene-near-host", Watcher.Scene == Scene && Lead.Pawn == None && Dist < 800,
		"distance"@Dist@"to"@Scene.OldPawn@"scene"@Watcher.Scene);
	Sleep(1.0);
	bGotCamera = false;
	Remote.ClientTestCamera();
	Sleep(0.5);
	Check("joiner-watches-scene", bGotCamera && (ClientState == "CoopClientCutscene" || Watcher.Scene == None),
		"state="$ClientState@"scene"@Watcher.Scene);

	// Let it run out (or stop it, as travel would).
	for (Waited = 0; Waited < Scene.TotalSceneTime + 5 && Watcher.Scene != None; Waited += 0.5)
		Sleep(0.5);
	if (Watcher.Scene != None)
	{
		log("P2CoopTest: scene still running after"@Waited@"s, stopping it");
		CoopGame(Level.Game).StopSceneManagers();
	}
	Sleep(3.0);
	// This map's scene starts a day: the errands map comes next, for everyone.
	for (EndPresses = 0; EndPresses < 8; EndPresses++)
	{
		Remote.ClientTestEndScreens();
		if (P2Player(Lead).MyMapScreen != None && P2Player(Lead).MyMapScreen.IsRunning())
			P2Player(Lead).MyMapScreen.bPlayerWantsToEnd = true;
		if (P2Player(Lead).MyNewsScreen != None && P2Player(Lead).MyNewsScreen.IsRunning())
			P2Player(Lead).MyNewsScreen.bPlayerWantsToEnd = true;
		Sleep(1.0);
	}
	Sleep(3.0);
	bGotCamera = false;
	Remote.ClientTestCamera();
	Sleep(0.5);
	Check("client-back", bGotCamera && ClientState == "PlayerWalking" && !Remote.bInCutscene, "state="$ClientState);
	if (Remote.Pawn != None)
	{
		ClientStart = Remote.Pawn.Location;
		Remote.ClientTestDrive(6000, 1.5);
		Sleep(3.0);
		Check("client-moves-after", VSize(Remote.Pawn.Location - ClientStart) > 100,
			"moved"@VSize(Remote.Pawn.Location - ClientStart));
	}
	Finish();
}

defaultproperties
{
	TestName="cutscene"
}
