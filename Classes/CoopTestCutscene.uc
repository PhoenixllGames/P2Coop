//=============================================================================
// CoopTestCutscene: remote players watch the host's cutscene, ?CoopTest=cutscene on the host.
// Starts a camera SceneManager of this map for the host and checks that:
//   - the client looks through the host's camera, input off (CoopClientCutscene),
//   - players take no damage meanwhile,
//   - after the scene (and the map or newspaper the game may show next) the client is back in
//     PlayerWalking and moves.
//=============================================================================
class CoopTestCutscene extends CoopTestBase;

var SceneManager Scene;
var CoopCutscene Watcher;
var int HealthBefore;
var vector ClientStart;
var float Waited;

// A camera scene of this map with something in it.
function SceneManager FindScene()
{
	local SceneManager SM, Best;

	foreach AllActors(class'SceneManager', SM)
	{
		log("P2CoopTest: scene"@SM@"tag"@SM.Tag@"affect"@SM.Affect@"actions"@SM.Actions.Length
			@"time"@SM.TotalSceneTime@"running"@SM.bIsRunning);
		if (SM.Affect == AFFECT_ViewportCamera && SM.Actions.Length > 0 && SM.TotalSceneTime > 2
			&& (Best == None || SM.TotalSceneTime < Best.TotalSceneTime))
			Best = SM;
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
	Scene = FindScene();
	if (Scene == None)
	{
		Check("cutscene-on-map", false, "no camera SceneManager on"@CurrentMap());
		Finish();
		Stop;
	}
	log("P2CoopTest: host starts"@Scene@"for"@Scene.TotalSceneTime@"s");
	Scene.Trigger(Lead, Lead.Pawn);
	Sleep(2.0);
	Check("host-in-cutscene", Watcher.Scene == Scene, "watching"@Watcher.Scene);
	bGotCamera = false;
	Remote.ClientTestCamera();
	Sleep(0.5);
	Check("client-watches", bGotCamera && ClientState == "CoopClientCutscene", "state="$ClientState);
	Check("client-camera-is-hosts", bGotCamera && VSize(ClientCam - Watcher.CamLoc) < 300,
		"client"@ClientCam@"host"@Watcher.CamLoc@"distance"@VSize(ClientCam - Watcher.CamLoc));

	HealthBefore = Remote.Pawn.Health;
	Remote.Pawn.TakeDamage(20, None, Remote.Pawn.Location, vect(0,0,0), class'DamageType');
	Check("no-damage-in-cutscene", Remote.Pawn.Health == HealthBefore, "health"@HealthBefore@"->"@Remote.Pawn.Health);

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
