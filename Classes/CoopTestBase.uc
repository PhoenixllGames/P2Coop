//=============================================================================
// CoopTestBase: shared parts of the in-game co-op tests (?CoopTest=<name>).
// Checks write "P2CoopTest: PASS|FAIL <check> ..." to the host log. A test that
// spans maps carries its counts in the travel URL (?CoopPass=N?CoopFail=M);
// Finish writes "P2CoopTest: DONE <name> pass=N fail=M" and quits the host,
// because the engine log is buffered and the harness reads it afterwards.
//=============================================================================
class CoopTestBase extends Info
	abstract;

var string TestName;
var int Passed, Failed;
var CoopPlayer Remote;
var PlayerController Lead;

// Last report from the client (CoopPlayer.ClientTestLook -> ServerTestSaw).
var bool bGotReport, bSawLeader;
var vector SeenLeaderLoc, ClientLoc;
var int SeenNPCs;

// Last screens report from the client (CoopPlayer.ClientTestScreens -> ServerTestScreens).
var bool bGotScreens, bClientShadow;
var int ClientDay, ClientDoneToday, ClientHaters;
var string ClientCompleted, ClientOpen, ClientState;
var float ClientWanted, ClientHUDWanted;
var bool bGotCamera;		// CoopPlayer.ClientTestCamera
var vector ClientCam;
var int EndPresses;		// state code loop counter (no locals there)

function PostBeginPlay()
{
	Super.PostBeginPlay();
	Passed = int(CoopGame(Level.Game).URLOption("CoopPass"));
	Failed = int(CoopGame(Level.Game).URLOption("CoopFail"));
}

function Check(string Name, bool bOk, string Detail)
{
	if (bOk)
	{
		Passed++;
		log("P2CoopTest: PASS"@Name@Detail);
	}
	else
	{
		Failed++;
		log("P2CoopTest: FAIL"@Name@Detail);
	}
}

// URL options that carry this test's state to the next map.
function string CarryOptions(string NextPhase)
{
	return "?CoopTest="$NextPhase$"?CoopPass="$Passed$"?CoopFail="$Failed;
}

function RemoteJoined(PlayerController P)
{
	if (Remote == None && CoopPlayer(P) != None)
	{
		Remote = CoopPlayer(P);
		Lead = CoopGame(Level.Game).Leader();
		GotoState('Running');
	}
}

function ClientSaw(CoopPlayer P, bool bLeader, vector LeaderLoc, int NPCs, vector MyLoc)
{
	if (P != Remote)
		return;
	bGotReport = true;
	bSawLeader = bLeader;
	SeenLeaderLoc = LeaderLoc;
	SeenNPCs = NPCs;
	ClientLoc = MyLoc;
}

function ClientScreens(CoopPlayer P, bool bShadow, int Day, int DoneToday, string Completed, int Haters,
	float Wanted, float HUDWanted, string Open, string StateName)
{
	if (P != Remote)
		return;
	bGotScreens = true;
	bClientShadow = bShadow;
	ClientDay = Day;
	ClientDoneToday = DoneToday;
	ClientCompleted = Completed;
	ClientHaters = Haters;
	ClientWanted = Wanted;
	ClientHUDWanted = HUDWanted;
	ClientOpen = Open;
	ClientState = StateName;
}

// CoopGame.AnnounceErrand (a remote player completed an errand).
function ErrandAnnounced(PlayerController Who, string ErrandName)
{
}

function rotator AimAt(Pawn From, Pawn To)
{
	return rotator(To.Location - (From.Location + From.EyePosition()));
}

function Inventory Give(Pawn P, class<Inventory> InvClass)
{
	local Inventory Inv;

	Inv = P2Pawn(P).CreateInventoryByClass(InvClass);
	log("P2CoopTest: gave"@Inv@"to"@P);
	return Inv;
}

function bool Has(Pawn P, class<Inventory> InvClass)
{
	return P != None && P.FindInventoryType(InvClass) != None;
}

function ClientCamera(CoopPlayer P, vector Loc, string StateName)
{
	if (P != Remote)
		return;
	bGotCamera = true;
	ClientCam = Loc;
	ClientState = StateName;
}

function string CurrentMap()
{
	local string URL;

	URL = Level.GetLocalURL();
	if (InStr(URL, "/") >= 0)
		URL = Mid(URL, InStr(URL, "/") + 1);
	if (InStr(URL, "?") >= 0)
		URL = Left(URL, InStr(URL, "?"));
	if (InStr(URL, "#") >= 0)
		URL = Left(URL, InStr(URL, "#"));
	return URL;
}

function Finish()
{
	log("P2CoopTest: DONE"@TestName@"pass="$Passed@"fail="$Failed);
	ConsoleCommand("exit");
}

state Running
{
}
