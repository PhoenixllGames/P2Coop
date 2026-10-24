//=============================================================================
// CoopCutscene: lets remote players watch the host's cutscenes (server side).
//
// A SceneManager (matinee) drives only the first PlayerController, the host's player: it takes
// his pawn away and moves his camera on the server. While one runs, this sends the host's camera
// (PlayerCalcView) to every remote player, whose client looks through it (CoopPlayer state
// CoopClientCutscene) with input off and the HUD hidden. The server also uses that camera to
// decide what each remote player gets replicated (CoopPlayer.PlayerCalcView), so the actors of
// the scene reach him even far from his own pawn. Players take no damage meanwhile
// (CoopGame.ReduceDamage).
//=============================================================================
class CoopCutscene extends Info;

var SceneManager Scene;		// the scene the host is watching, or None
var vector CamLoc;
var rotator CamRot;
var float NextSend;

const SendInterval = 0.05;

function Tick(float DeltaTime)
{
	local PlayerController Lead;
	local SceneManager SM;
	local Controller C;
	local CoopPlayer P;
	local Actor ViewActor;
	local bool bSend;

	if (CoopGame(Level.Game) == None)
		return;
	Lead = CoopGame(Level.Game).Leader();
	if (Lead != None)
		SM = Lead.GetCurrentSceneManager();
	if (SM != Scene)
	{
		if (SM != None)
			log("P2Coop: cutscene"@SM@"tag"@SM.Tag@"starts for everyone");
		else
			log("P2Coop: cutscene"@Scene@"ended");
		Scene = SM;
	}
	if (Scene != None)
	{
		ViewActor = Lead.ViewTarget;
		CamLoc = Lead.Location;
		CamRot = Lead.Rotation;
		Lead.PlayerCalcView(ViewActor, CamLoc, CamRot);
		bSend = Level.TimeSeconds >= NextSend;
		if (bSend)
			NextSend = Level.TimeSeconds + SendInterval;
	}
	for (C = Level.ControllerList; C != None; C = C.NextController)
	{
		P = CoopPlayer(C);
		if (P == None || !P.IsRemote())
			continue;
		if (Scene != None)
		{
			if (!P.bInCutscene)
			{
				P.bInCutscene = true;
				P.ClientCutsceneStart(Scene.bCinematicView, CamLoc, CamRot);
			}
			else if (bSend)
				P.ClientCutsceneView(CamLoc, CamRot);
		}
		else if (P.bInCutscene)
		{
			P.bInCutscene = false;
			P.ClientCutsceneEnd();
		}
	}
}

// True while a cutscene runs and Injured is a player's pawn (the host's is with the scene).
function bool Protects(Pawn Injured)
{
	return Scene != None && Injured != None && (Injured.IsHumanControlled() || Injured == Scene.OldPawn);
}
