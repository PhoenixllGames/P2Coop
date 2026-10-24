//=============================================================================
// CoopHUD: the SP HUD; on a client it draws the host's game state too.
//
// P2HUD reads Level.Game directly (wanted meter, death hints, time), and a client has none. While
// a client's HUD renders, Level.Game is the shadow game (CoopReplicationInfo) and is put back to
// None right after: drawing only reads it, and nothing else runs in between.
// After the stock HUD it draws the teammates' nameplates with health bars and, for a downed
// player, the bleed-out time (DrawTeammates); on the host it also draws once a ragdoll body his
// view has not drawn (DrawBodies, for CoopRagdollSync).
//=============================================================================
class CoopHUD extends AWWrapHUD;

var CoopShadowGame Shadow;
var float LastWanted;		// what the wanted meter last showed (tests)
var array<Actor> Bodies;	// to be drawn once for their skeletons (DrawBody)
var array<float> BodySince;	// when each one was asked for
var localized string ReviveHint, BleedHint;

simulated function PostBeginPlay()
{
	Super.PostBeginPlay();
	class'CoopText'.static.Translate(self, "CoopHUD", "ReviveHint BleedHint");
}

simulated event PostRender(canvas Canvas)
{
	if (Level.NetMode != NM_Client || Level.Game != None)
	{
		Super.PostRender(Canvas);
		DrawBodies(Canvas);
		DrawTeammates(Canvas);
		return;
	}
	if (Shadow == None || Shadow.bDeleteMe)
		Shadow = class'CoopReplicationInfo'.static.ShadowFor(self);
	if (Shadow == None)
	{
		Super.PostRender(Canvas);
		DrawTeammates(Canvas);
		return;
	}
	Level.Game = Shadow;
	Super.PostRender(Canvas);
	Level.Game = None;
	DrawTeammates(Canvas);
}

// Shared by drawing and the client test report. Always trace from the actual camera.
simulated function bool NameplateFor(CoopPlayerStatus S, out vector Head, out float Fraction)
{
	local Actor ViewActor;
	local vector Cam, X, Y, Z, Delta;
	local vector TracePoint;
	local coords HeadBone;
	local rotator ViewRot;
	local float Depth, HalfWidth;

	if (S == None || S.PRI == None || S.PRI == PlayerOwner.PlayerReplicationInfo
		|| S.PlayerPawn == None || S.CurrentHealth <= 0)
		return false;
	PlayerOwner.PlayerCalcView(ViewActor, Cam, ViewRot);
	Head = S.PlayerPawn.Location;
	TracePoint = Head;
	if (CoopPawn(S.PlayerPawn) != None && CoopPawn(S.PlayerPawn).bDowned)
	{
		HeadBone = S.PlayerPawn.GetBoneCoords('Bip01 Head');
		TracePoint = HeadBone.Origin;
		Head = TracePoint + vect(0,0,24);
	}
	else
		Head.Z += S.PlayerPawn.CollisionHeight + 16;
	if (VSize(Head - Cam) > 2500 || (Head - Cam) dot vector(ViewRot) <= 0
		|| !FastTrace(TracePoint, Cam) || !FastTrace(Head, Cam))
		return false;
	GetAxes(ViewRot, X, Y, Z);
	Delta = Head - Cam;
	Depth = Delta dot X;
	HalfWidth = Depth * Tan(PlayerOwner.FOVAngle * Pi / 360);
	if (Abs(Delta dot Y) > HalfWidth || (CanvasWidth > 0 && CanvasHeight > 0
		&& Abs(Delta dot Z) > HalfWidth * CanvasHeight / CanvasWidth))
		return false;
	Fraction = S.HealthFraction();
	return true;
}

simulated function DrawTeammates(Canvas C)
{
	local CoopPlayerStatus S;
	local vector Head, Screen, Cam;
	local Actor ViewActor;
	local rotator ViewRot;
	local float Fraction, Scale, W, H, TW, TH;
	local color SavedColor;
	local Font SavedFont;
	local byte SavedStyle;
	local float SavedX, SavedY;
	local CoopPawn Down;

	if (bHideHUD || bCinematicView || AreAnyRootWindowsRunning()
		|| (OurPlayer.CurrentScreen != None && !OurPlayer.CurrentScreen.ShouldDrawHUD()))
		return;
	SavedColor = C.DrawColor;
	SavedFont = C.Font;
	SavedStyle = C.Style;
	SavedX = C.FontScaleX;
	SavedY = C.FontScaleY;
	PlayerOwner.PlayerCalcView(ViewActor, Cam, ViewRot);
	C.Font = MyFont.GetFont(1, false, C.ClipX);
	C.Style = 1;
	foreach DynamicActors(class'CoopPlayerStatus', S)
	{
		if (!NameplateFor(S, Head, Fraction))
			continue;
		Screen = C.WorldToScreen(Head, Cam, ViewRot);
		if (Screen.X < 0 || Screen.X > C.ClipX || Screen.Y < 0 || Screen.Y > C.ClipY)
			continue;
		Scale = FClamp(600 / FMax(1, VSize(Head - Cam)), 0.55, 1.2) * C.ClipX / 800;
		C.FontScaleX = Scale;
		C.FontScaleY = Scale;
		C.StrLen(S.PRI.PlayerName, TW, TH);
		C.DrawColor = WhiteColor;
		C.SetPos(Screen.X - TW / 2, Screen.Y - TH - 8 * Scale);
		C.DrawText(S.PRI.PlayerName, false);
		Down = CoopPawn(S.PlayerPawn);
		if (Down != None && Down.bDowned)
		{
			C.StrLen(ReviveHint, TW, TH);
			C.SetPos(Screen.X - TW / 2, Screen.Y + 4 * Scale);
			C.DrawText(ReviveHint, false);
		}
		W = 64 * Scale;
		H = 6 * Scale;
		C.DrawColor.R = 0;
		C.DrawColor.G = 0;
		C.DrawColor.B = 0;
		C.SetPos(Screen.X - W / 2 - 1, Screen.Y - H - 1);
		C.DrawRect(Texture'Engine.WhiteSquareTexture', W + 2, H + 2);
		C.DrawColor.R = byte(255 * (1 - Fraction));
		C.DrawColor.G = byte(255 * Fraction);
		C.DrawColor.B = 0;
		C.DrawColor.A = 255;
		C.SetPos(Screen.X - W / 2, Screen.Y - H);
		C.DrawRect(Texture'Engine.WhiteSquareTexture', W * Fraction, H);
	}
	Down = CoopPawn(PlayerOwner.Pawn);
	if (Down != None && Down.bDowned)
	{
		C.FontScaleX = C.ClipX / 800;
		C.FontScaleY = C.FontScaleX;
		C.DrawColor = WhiteColor;
		C.StrLen(BleedHint @ int(Down.BleedRemaining + 0.99), TW, TH);
		C.SetPos((C.ClipX - TW) / 2, C.ClipY * 0.7);
		C.DrawText(BleedHint @ int(Down.BleedRemaining + 0.99), false);
	}
	C.DrawColor = SavedColor;
	C.Font = SavedFont;
	C.Style = SavedStyle;
	C.FontScaleX = SavedX;
	C.FontScaleY = SavedY;
}

// Renders A once even when the host's own view does not: the engine brings a skeleton's place in
// the world up to date only when it is drawn, and a ragdoll the host has never drawn (killed out
// of his view) reads its bones far from its Karma bodies until then (CoopRagdollSync.StartRagdoll).
// The body is drawn where it is, behind what is in front of it: out of view it is clipped away.
function DrawBody(Actor A)
{
	local int i;

	for (i = 0; i < Bodies.Length; i++)
		if (Bodies[i] == A)
			return;
	Bodies[Bodies.Length] = A;
	BodySince[BodySince.Length] = Level.TimeSeconds;
}

function DrawBodies(canvas Canvas)
{
	local int i;
	local Actor A;

	for (i = Bodies.Length - 1; i >= 0; i--)
	{
		A = Bodies[i];
		// Done once it was rendered after the ask (by the view or by this); given up after a while.
		if (A == None || A.bDeleteMe || A.LastRenderTime > BodySince[i] || Level.TimeSeconds - BodySince[i] > 2.0)
		{
			Bodies.Remove(i, 1);
			BodySince.Remove(i, 1);
			continue;
		}
		Canvas.DrawActor(A, false, false);
	}
}

simulated function DrawPlayerWantedStatus(canvas Canvas, float Scale)
{
	if (P2GameInfoSingle(Level.Game) != None && P2GameInfoSingle(Level.Game).TheGameState != None)
		LastWanted = P2GameInfoSingle(Level.Game).TheGameState.CopsWantPlayer();
	Super.DrawPlayerWantedStatus(Canvas, Scale);
}

defaultproperties
{
	ReviveHint="Pee on him to revive"
	BleedHint="Bleeding out! Seconds left:"
}
