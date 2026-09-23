#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <dhooks>
#include <sdktools>

/*
 * [L4D2] Steam Auth Bypass
 *
 * A SourceMod port of l4dtoolz's sv_steam_bypass flow, merged with the behaviour of
 * l4d2_block_no_steam_logon. Three independent layers, all switchable at runtime:
 *
 *   layer 1 - the verdict (l4d2_steam_bypass_enable)
 *     The engine registers CSteam3Server::OnValidateAuthTicketResponse as a Steamworks
 *     CCallback inside the CSteam3Server instance (object +0x70, callback pointer at +0x80).
 *     That function looks the client up by the response's SteamID and then branches on the
 *     verdict at +8 of ValidateAuthTicketResponse_t:
 *         code == 0 -> success path: the client is marked fully authenticated
 *         code != 0 -> OnValidateAuthTicketResponseHelper ("No Steam logon" disconnect)
 *     Rewriting that dword to 0 in a pre hook makes the engine run its own success path, so the
 *     client ends up authenticated with the SteamID it claimed and SourceMod's auth gate
 *     (IVEngineServer::IsClientFullyAuthenticated) passes - which is what makes
 *     OnClientAuthorized and OnClientPostAdminCheck fire for these clients.
 *
 *   layer 2 - the certificate (l4d2_steam_bypass_challenge)
 *     Clients that cannot produce a valid authentication certificate never reach layer 1:
 *     CBaseServer::CheckChallengeType (CBaseServer vtable slot 0x39) rejects them before Steam
 *     is even asked. Like l4dtoolz this accepts the certificate, stores the 8 bytes of
 *     self-reported identity it carries into CBaseClient::m_SteamID (+0x7D) and supercedes the
 *     engine's validation - which needs a real Steam session to ever succeed.
 *
 *   layer 3 - the kick (l4d2_steam_bypass_block_kick)
 *     When the verdict is left alone (layer 1 off, or a code we do not rewrite) the engine still
 *     calls the helper to disconnect the client. This layer supercedes that call - the original
 *     l4d2_block_no_steam_logon behaviour - and also keeps a client alive when a real failure
 *     arrives after the bypass already authorised them.
 *
 * SECURITY, read before enabling: layers 1 and 2 trust the identity the client claims, so any
 * client can pick its own SteamID. SteamID based admin lists, bans and the family sharing
 * restriction become meaningless for players who fail real authentication. That is inherent to
 * the technique (l4dtoolz documents the same trade-off), not a defect of this port.
 *
 * Everything below was read out of the shipping binaries and re-verified offline:
 *   engine.dll    PE32 x86, imagebase 0x10000000, 2026-06-30 build
 *   engine_srv.so ELF32, Linux dedicated server build (mangled symbols)
 *   windows: 5/5 byte signatures match exactly one location, each at the expected RVA
 *   linux:   5/5 symbols resolve
 *
 * HOW TO VERIFY ON A LIVE SERVER
 *   Load:    addons/sourcemod/logs/l4d2_steam_bypass.log must show
 *            "---- loaded (version ..., IClient frame offset +N) ----" and
 *            addons/sourcemod/logs/errors_*.log must stay empty.
 *   Layer 1: a client that previously produced "No Steam logon" now produces
 *            "### Forced auth verdict <n> -> OK, client: <name>" followed by
 *            "### OnClientAuthorized: client <i> (<name>) auth \"...\"". Before the fix the
 *            same client only produced "### Found a client with auth problem" and no
 *            OnClientAuthorized at all.
 *   Layer 2: "### Certificate accepted, claimed SteamID 0x... stored at client + 0x7D" for
 *            clients that cannot pass the certificate check.
 *   Layer 3: with l4d2_steam_bypass_enable 0 the old behaviour is visible again:
 *            "### Found a client with auth problem, name: ..." then
 *            "### Bypassing no steaam logon disconnection for client: ...".
 *   Not verifiable without such a client: the end-to-end transition
 *   unauthorised -> authorised (that is what the log lines above record).
 *
 * WHY THE REWRITE IS ENOUGH (verified in the binaries, both platforms)
 *   failure branch: code != 0 -> calls OnValidateAuthTicketResponseHelper and then jumps PAST the
 *                   flag write (linux 0x2013F0 -> 0x201383), so the client stays unauthenticated
 *                   for ever - which is exactly the reported symptom (OnClientPutInServer fires,
 *                   OnClientAuthorized never does).
 *   success branch: code == 0 -> writes CBaseClient + 0x217 = 1 (linux 0x20137C, windows 0x12E78E,
 *                   the same offset on both) .
 *   SourceMod's gate: CVEngineServer::IsClientFullyAuthenticated -> movzx eax, byte ptr [edx+217h],
 *                   i.e. exactly that byte; RunAuthChecks() then calls Authorize() and fires
 *                   OnClientAuthorized (and OnClientPostAdminCheck via DoPostConnectAuthorization).
 *   The plugin now logs that byte before the rewrite and again one second later, so a production
 *   log records the whole chain by itself.
 *
 * COEXISTENCE WITH l4d2_block_no_steam_logon
 *   Both can be loaded at once (verified on the test server: both detours install, no SourceMod
 *   errors, the auth callback hook and the helper hook stay independent). This plugin already
 *   contains that plugin's behaviour and exposes the same OnValidateAuthTicketResponseHelper
 *   forward (same argument order), so running only this one is recommended - running both is
 *   harmless but redundant.
 */

#define PLUGIN_VERSION "1.0.0"

#define GAMEDATA_FILE			"l4d2_steam_bypass"

#define DETOUR_AUTH_RESPONSE	"CSteam3Server::OnValidateAuthTicketResponse"
#define DETOUR_CHALLENGE		"CBaseServer::CheckChallengeType"
#define DETOUR_AUTH_HELPER		"CSteam3Server::OnValidateAuthTicketResponseHelper"

#define SDKCALL_ISTIMINGOUT		"CNetChan::IsTimingOut"
#define SDKCALL_GETNETCHANNEL	"CBaseClient::GetNetChannel"
#define SDKCALL_DISCONNECT		"CBaseClient::Disconnect"
#define SDKCALL_GETCLIENT		"CBaseServer::GetClient"

#define OFFSET_RESPONSE_CODE	"ValidateAuthTicketResponse_t->m_eAuthSessionResponse"
#define OFFSET_M_STEAMID		"CBaseClient->m_SteamID"
#define OFFSET_M_NAME			"CBaseClient->m_Name"
#define OFFSET_AUTH_FLAG		"CBaseClient->m_bFullyAuthenticated"
#define OFFSET_FRAME			"CBaseClient->IClient->frame_offset"

#define CLIENTNAME_TIMED_OUT	"%s timed out."
#define LOG_FILE				"l4d2_steam_bypass.log"

enum EAuthSessionResponse
{
	k_EAuthSessionResponseOK							= 0,	// Steam has verified the user is online, the ticket is valid and ticket has not been reused.
	k_EAuthSessionResponseUserNotConnectedToSteam		= 1,	// The user in question is not connected to steam
	k_EAuthSessionResponseNoLicenseOrExpired			= 2,	// The license has expired.
	k_EAuthSessionResponseVACBanned						= 3,	// The user is VAC banned for this game.
	k_EAuthSessionResponseLoggedInElseWhere				= 4,	// The user account has logged in elsewhere and the session containing the game instance has been disconnected.
	k_EAuthSessionResponseVACCheckTimedOut				= 5,	// VAC has been unable to perform anti-cheat checks on this user
	k_EAuthSessionResponseAuthTicketCanceled			= 6,	// The ticket has been canceled by the issuer
	k_EAuthSessionResponseAuthTicketInvalidAlreadyUsed	= 7,	// This ticket has already been used, it is not valid.
	k_EAuthSessionResponseAuthTicketInvalid				= 8,	// This ticket is not from a user instance currently connected to steam.
}

/* no OS enum is needed: the platform differences live in the gamedata (frame_offset) */

/* ------------------------------------------------------------------ globals */

DynamicDetour	g_hDetour_AuthResponse;
DynamicDetour	g_hDetour_Challenge;
DynamicDetour	g_hDetour_AuthHelper;

Handle			g_hSDKCall_IsTimingOut;
Handle			g_hSDKCall_GetNetChannel;
Handle			g_hSDKCall_Disconnect;
Handle			g_hSDKCall_GetClient;

GlobalForward	g_hFWD_OnValidateAuthTicketResponseHelper;

ConVar			g_hCvar_Enable;
ConVar			g_hCvar_FlipAll;
ConVar			g_hCvar_Challenge;
ConVar			g_hCvar_BlockKick;
ConVar			g_hCvar_CheckTimeOut;
ConVar			g_hCvar_Log;

bool			g_bEnable			= false;
bool			g_bFlipAll			= false;
bool			g_bChallenge		= false;
bool			g_bBlockKick		= false;
bool			g_bCheckTimeOut		= false;
bool			g_bLog				= false;

int				g_iOff_Frame		= -1;
int				g_iOff_ResponseCode	= -1;
int				g_iOff_SteamID		= -1;
int				g_iOff_Name			= -1;
int				g_iOff_AuthFlag		= -1;

/* ------------------------------------------------------------------ engine objects */

methodmap INetChannel
{
	public bool IsTimingOut()
	{
		return SDKCall(g_hSDKCall_IsTimingOut, view_as<Address>(this));
	}
}

methodmap CBaseClient
{
	public INetChannel GetNetChannel()
	{
		return view_as<INetChannel>(SDKCall(g_hSDKCall_GetNetChannel, GetIClientPtr(view_as<Address>(this))));
	}

	public void Disconnect(const char[] reason)
	{
		SDKCall(g_hSDKCall_Disconnect, GetIClientPtr(view_as<Address>(this)), reason);
	}
}

/*
 * Two equivalent routes to the same virtuals, one per platform - see the gamedata comment on
 * CBaseClient->IClient->frame_offset:
 *   windows - IClient virtuals are taken from the subobject frame at (object + 4): GetNetChannel
 *             is slot 18 there, and CBaseClient::Disconnect expects that same adjusted pointer.
 *   linux   - the primary CBaseClient vtable is used (frame offset 0), where GetNetChannel is
 *             slot 8 and Disconnect resolves through its own symbol.
 */
stock Address GetIClientPtr(Address pClient)
{
	return pClient + view_as<Address>(g_iOff_Frame);
}

/* ------------------------------------------------------------------ plugin setup */

public Plugin myinfo =
{
	name		= "[L4D2] Steam Auth Bypass",
	author		= "apples1949",
	description	= "Force failing Steam auth verdicts to OK (so OnClientAuthorized fires), accept the client's certificate and/or suppress the no steam logon kick.",
	version		= PLUGIN_VERSION,
	url			= ""
};

public void OnPluginStart()
{
	CreateConVar("l4d2_steam_bypass_version", PLUGIN_VERSION, "Plugin version", FCVAR_NOTIFY | FCVAR_DONTRECORD);

	g_hCvar_Enable = CreateConVar("l4d2_steam_bypass_enable", "1",
		"1 = force a failing Steam auth verdict to OK, so the engine authorises the client and OnClientAuthorized / OnClientPostAdminCheck fire.",
		_, true, 0.0, true, 1.0);
	g_hCvar_FlipAll = CreateConVar("l4d2_steam_bypass_flip_all", "0",
		"0 = only the no-steam-logon verdicts (1, 6, 7, 8) are forced to OK; 1 = every failing verdict is, including VAC bans and licence failures (VAC secure mode then means nothing).",
		_, true, 0.0, true, 1.0);
	g_hCvar_Challenge = CreateConVar("l4d2_steam_bypass_challenge", "0",
		"1 = accept the client's authentication certificate and store the SteamID it claims. Only needed for clients that fail the certificate check; off by default because a detour with a wrong argument list aborts the server (DHooks cannot find the return address).",
		_, true, 0.0, true, 1.0);
	g_hCvar_BlockKick = CreateConVar("l4d2_steam_bypass_block_kick", "1",
		"1 = also suppress the engine's No Steam logon disconnect (the l4d2_block_no_steam_logon behaviour).",
		_, true, 0.0, true, 1.0);
	g_hCvar_CheckTimeOut = CreateConVar("l4d2_steam_bypass_check_timeout", "1",
		"1 = disconnect a kept client whose net channel already timed out (a dead connection, not an auth problem).",
		_, true, 0.0, true, 1.0);
	g_hCvar_Log = CreateConVar("l4d2_steam_bypass_log", "1",
		"1 = log every rewritten verdict and every OnClientAuthorized to addons/sourcemod/logs/l4d2_steam_bypass.log",
		_, true, 0.0, true, 1.0);

	g_hCvar_Enable.AddChangeHook(OnCvarChanged);
	g_hCvar_FlipAll.AddChangeHook(OnCvarChanged);
	g_hCvar_Challenge.AddChangeHook(OnCvarChanged);
	g_hCvar_BlockKick.AddChangeHook(OnCvarChanged);
	g_hCvar_CheckTimeOut.AddChangeHook(OnCvarChanged);
	g_hCvar_Log.AddChangeHook(OnCvarChanged);
	ReadCvars();

	/* same forward name and argument order as l4d2_block_no_steam_logon, so dependent plugins keep working */
	g_hFWD_OnValidateAuthTicketResponseHelper = new GlobalForward("OnValidateAuthTicketResponseHelper", ET_Event, Param_Any, Param_String);

	GameData gd = new GameData(GAMEDATA_FILE);
	if (gd == null)
	{
		SetFailState("gamedata '%s.txt' could not be loaded", GAMEDATA_FILE);
		return;
	}

	g_iOff_Frame = gd.GetOffset(OFFSET_FRAME);
	g_iOff_ResponseCode = gd.GetOffset(OFFSET_RESPONSE_CODE);
	g_iOff_SteamID = gd.GetOffset(OFFSET_M_STEAMID);
	g_iOff_Name = gd.GetOffset(OFFSET_M_NAME);
	g_iOff_AuthFlag = gd.GetOffset(OFFSET_AUTH_FLAG);
	if (g_iOff_Frame < 0 || g_iOff_ResponseCode < 0 || g_iOff_SteamID < 0 || g_iOff_Name < 0 || g_iOff_AuthFlag < 0)
	{
		SetFailState("missing offset(s): %s=%d %s=%d %s=%d %s=%d %s=%d",
			OFFSET_FRAME, g_iOff_Frame, OFFSET_RESPONSE_CODE, g_iOff_ResponseCode,
			OFFSET_M_STEAMID, g_iOff_SteamID, OFFSET_M_NAME, g_iOff_Name,
			OFFSET_AUTH_FLAG, g_iOff_AuthFlag);
		return;
	}

	InitSDKCalls(gd);
	InitDetours(gd);

	delete gd;

	PrintLog("---- loaded (version %s, IClient frame offset +%d) ----", PLUGIN_VERSION, g_iOff_Frame);
}

void InitSDKCalls(GameData gd)
{
	StartPrepSDKCall(SDKCall_Raw);
	if (!PrepSDKCall_SetFromConf(gd, SDKConf_Virtual, SDKCALL_ISTIMINGOUT))
	{
		SetFailState("virtual '%s' is missing from the gamedata", SDKCALL_ISTIMINGOUT);
		return;
	}
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
	g_hSDKCall_IsTimingOut = EndPrepSDKCall();

	StartPrepSDKCall(SDKCall_Raw);
	if (!PrepSDKCall_SetFromConf(gd, SDKConf_Virtual, SDKCALL_GETNETCHANNEL))
	{
		SetFailState("virtual '%s' is missing from the gamedata", SDKCALL_GETNETCHANNEL);
		return;
	}
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	g_hSDKCall_GetNetChannel = EndPrepSDKCall();

	StartPrepSDKCall(SDKCall_Raw);
	if (!PrepSDKCall_SetFromConf(gd, SDKConf_Signature, SDKCALL_DISCONNECT))
	{
		SetFailState("signature '%s' is missing from the gamedata", SDKCALL_DISCONNECT);
		return;
	}
	PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
	g_hSDKCall_Disconnect = EndPrepSDKCall();

	/* CBaseServer::GetClient is a member function, so sdktools supplies `this` for SDKCall_Server. */
	StartPrepSDKCall(SDKCall_Server);
	if (!PrepSDKCall_SetFromConf(gd, SDKConf_Signature, SDKCALL_GETCLIENT))
	{
		SetFailState("signature '%s' is missing from the gamedata", SDKCALL_GETCLIENT);
		return;
	}
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	g_hSDKCall_GetClient = EndPrepSDKCall();

	if (g_hSDKCall_IsTimingOut == null || g_hSDKCall_GetNetChannel == null || g_hSDKCall_Disconnect == null || g_hSDKCall_GetClient == null)
	{
		SetFailState("could not create one of the SDKCall(s) needed for the timeout check");
	}
}

void InitDetours(GameData gd)
{
	g_hDetour_AuthResponse = DynamicDetour.FromConf(gd, DETOUR_AUTH_RESPONSE);
	if (g_hDetour_AuthResponse == null || !g_hDetour_AuthResponse.Enable(Hook_Pre, OnAuthResponsePre))
	{
		SetFailState("could not detour '%s'", DETOUR_AUTH_RESPONSE);
		return;
	}

	/*
	 * Layer 2 is installed only when it is switched on: it is the riskiest detour (six stack
	 * arguments, and a mis-declared argument list makes DHooks abort the process), and clients
	 * that reach the auth callback at all have already passed this check.
	 */
	if (g_bChallenge)
	{
		g_hDetour_Challenge = DynamicDetour.FromConf(gd, DETOUR_CHALLENGE);
		if (g_hDetour_Challenge == null || !g_hDetour_Challenge.Enable(Hook_Pre, OnChallengePre))
		{
			SetFailState("could not detour '%s'", DETOUR_CHALLENGE);
			return;
		}
	}

	g_hDetour_AuthHelper = DynamicDetour.FromConf(gd, DETOUR_AUTH_HELPER);
	if (g_hDetour_AuthHelper == null || !g_hDetour_AuthHelper.Enable(Hook_Pre, OnAuthHelperPre))
	{
		SetFailState("could not detour '%s'", DETOUR_AUTH_HELPER);
		return;
	}
}

void ReadCvars()
{
	g_bEnable		= g_hCvar_Enable.BoolValue;
	g_bFlipAll		= g_hCvar_FlipAll.BoolValue;
	g_bChallenge	= g_hCvar_Challenge.BoolValue;
	g_bBlockKick	= g_hCvar_BlockKick.BoolValue;
	g_bCheckTimeOut	= g_hCvar_CheckTimeOut.BoolValue;
	g_bLog			= g_hCvar_Log.BoolValue;
}

public void OnCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	ReadCvars();
}

/* ------------------------------------------------------------------ layer 1: the verdict */

public MRESReturn OnAuthResponsePre(DHookParam hParams)
{
	if (!g_bEnable)
	{
		return MRES_Ignored;
	}

	Address pResponse = view_as<Address>(hParams.Get(1));
	if (pResponse == Address_Null)
	{
		return MRES_Ignored;
	}

	int code = LoadFromAddress(pResponse + view_as<Address>(g_iOff_ResponseCode), NumberType_Int32);
	if (code == view_as<int>(k_EAuthSessionResponseOK))
	{
		return MRES_Ignored;	// a real success is never touched
	}

	/*
	 * By default only the "no steam logon" family is rewritten. Those are the verdicts this
	 * plugin exists for: they mean Steam could not confirm the session at all (not connected,
	 * ticket cancelled/reused/invalid). VAC bans, licence failures and "logged in elsewhere"
	 * are real enforcement decisions and stay enforced unless flip_all is switched on.
	 */
	if (!g_bFlipAll && !IsNoSteamLogonVerdict(view_as<EAuthSessionResponse>(code)))
	{
		if (g_bLog)
		{
			PrintLog("### Auth verdict %d left alone (only 1/6/7/8 are rewritten by default)", code);
		}
		return MRES_Ignored;
	}

	/*
	 * The engine reads this dword itself a few instructions later and then takes the success
	 * path, so writing 0 here is all that is needed: no engine call of our own is involved.
	 */
	StoreToAddress(pResponse + view_as<Address>(g_iOff_ResponseCode), k_EAuthSessionResponseOK, NumberType_Int32);

	int client = FindClientBySteamID(LoadFromAddress(pResponse, NumberType_Int32));
	if (g_bLog)
	{
		char sName[64];
		if (client)
		{
			GetClientName(client, sName, sizeof(sName));
		}
		else
		{
			sName = "unknown/not in game";
		}

		PrintLog("### Forced auth verdict %d -> OK, client: %s (claimed SteamID low dword 0x%08X, auth flag before: %d)",
			code, sName, LoadFromAddress(pResponse, NumberType_Int32), client ? ReadAuthFlag(client) : -1);

		/* The engine writes the flag a few instructions further down the success branch, so
		 * reading it again one second later makes this log an end-to-end proof: flag 1 means the
		 * engine really did authorise the client, which is the condition SourceMod's
		 * OnClientAuthorized / OnClientPostAdminCheck wait for. */
		if (client)
		{
			CreateTimer(1.0, Timer_AuthFlagCheck, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
		}
	}

	return MRES_Ignored;
}

/* ------------------------------------------------------------------ layer 2: the certificate */

public MRESReturn OnChallengePre(DHookParam hParams)
{
	if (!g_bChallenge)
	{
		return MRES_Ignored;
	}

	Address pClient	= view_as<Address>(hParams.Get(1));
	Address pCert	= view_as<Address>(hParams.Get(5));
	int length		= hParams.Get(6);

	if (pClient == Address_Null || pCert == Address_Null || length < 8)
	{
		return MRES_Ignored;	// let the engine reject a certificate that is too short anyway
	}

	/*
	 * l4dtoolz semantics: whatever identity the client put into its certificate is what it gets.
	 * m_SteamID is 8 bytes (low dword first) at complete object + 0x7D on both platforms.
	 */
	int low		= LoadFromAddress(pCert, NumberType_Int32);
	int high	= LoadFromAddress(pCert + view_as<Address>(4), NumberType_Int32);

	StoreToAddress(pClient + view_as<Address>(g_iOff_SteamID), low, NumberType_Int32);
	StoreToAddress(pClient + view_as<Address>(g_iOff_SteamID + 4), high, NumberType_Int32);

	if (g_bLog)
	{
		PrintLog("### Certificate accepted, claimed SteamID 0x%08X%08X stored at client + 0x%X",
			high, low, g_iOff_SteamID);
	}

	DHookSetReturn(hParams, true);
	return MRES_Supercede;	// skip the engine's certificate validation
}

/* ------------------------------------------------------------------ layer 3: the kick */

public MRESReturn OnAuthHelperPre(DHookParam hParams)
{
	CBaseClient pBaseClient = view_as<CBaseClient>(hParams.Get(1));
	if (view_as<Address>(pBaseClient) == Address_Null)
	{
		return MRES_Ignored;	// invalid addresses cause crashes
	}

	char sName[128];
	ReadMemoryString(view_as<Address>(pBaseClient) + view_as<Address>(g_iOff_Name), sName, sizeof(sName));

	EAuthSessionResponse response = view_as<EAuthSessionResponse>(hParams.Get(2));
	if (g_bLog)
	{
		PrintLog("### Found a client with auth problem, name: %s, EAuthSessionResponse: %d", sName, response);
	}

	Call_StartForward(g_hFWD_OnValidateAuthTicketResponseHelper);
	Call_PushCell(view_as<int>(response));
	Call_PushString(sName);
	Call_Finish();

	/*
	 * A client whose connection is already dead is not an auth problem - drop it instead of
	 * holding the slot. CNetChan::IsTimingOut uses a 4 second threshold by default.
	 */
	if (g_bCheckTimeOut)
	{
		INetChannel netchan = pBaseClient.GetNetChannel();
		if (netchan && netchan.IsTimingOut())
		{
			char reason[128];
			Format(reason, sizeof(reason), CLIENTNAME_TIMED_OUT, sName);
			if (g_bLog)
			{
				PrintLog("### Disconnecting timed out client, reason: %s", reason);
			}
			pBaseClient.Disconnect(reason);
			return MRES_Supercede;
		}
	}

	if (g_bBlockKick)
	{
		if (g_bLog)
		{
			PrintLog("### Bypassing no steaam logon disconnection for client: %s", sName);
		}
		return MRES_Supercede;
	}

	return MRES_Ignored;
}

/* ------------------------------------------------------------------ proof the layers worked */

public void OnClientAuthorized(int client, const char[] auth)
{
	if (!g_bLog)
	{
		return;
	}

	char sName[64];
	GetClientName(client, sName, sizeof(sName));
	PrintLog("### OnClientAuthorized: client %d (%s) auth \"%s\"", client, sName, auth);
}

/* ------------------------------------------------------------------ helpers */

/*
 * The engine finds the client for a verdict by comparing the response's CSteamID against every
 * connected client's m_SteamID; the same match is done here so the log can name the player.
 * CBaseServer::GetClient is 0 based and returns IClient* = complete object + 4 on both platforms.
 */
int ReadAuthFlag(int client)
{
	int pClient = GetClientObject(client);
	if (pClient <= 0)
	{
		return -1;
	}

	return LoadFromAddress(view_as<Address>(pClient + g_iOff_AuthFlag), NumberType_Int8);
}

public Action Timer_AuthFlagCheck(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client < 1 || !IsClientInGame(client))
	{
		return Plugin_Stop;
	}

	char sName[64];
	GetClientName(client, sName, sizeof(sName));
	PrintLog("### engine fully-authenticated flag for %s is now %d (1 = the engine authorised the client, so OnClientAuthorized follows)",
		sName, ReadAuthFlag(client));
	return Plugin_Stop;
}

int FindClientBySteamID(int lowDword)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientConnected(i) || IsFakeClient(i))
		{
			continue;
		}

		int pClient = GetClientObject(i);
		if (pClient <= 0)
		{
			continue;
		}

		if (LoadFromAddress(view_as<Address>(pClient) + view_as<Address>(g_iOff_SteamID), NumberType_Int32) == lowDword)
		{
			return i;
		}
	}

	return 0;
}

int GetClientObject(int client)
{
	if (client < 1 || client > MaxClients)
	{
		return 0;
	}

	int pIClient = SDKCall(g_hSDKCall_GetClient, client - 1);
	if (pIClient <= 0x10000)
	{
		return 0;	// the client is not fully in the server yet
	}

	return pIClient - 4;	// the engine adds 4 to the stored pointer
}

stock bool IsNoSteamLogonVerdict(EAuthSessionResponse code)
{
	switch (code)
	{
		case k_EAuthSessionResponseUserNotConnectedToSteam,
			k_EAuthSessionResponseAuthTicketCanceled,
			k_EAuthSessionResponseAuthTicketInvalidAlreadyUsed,
			k_EAuthSessionResponseAuthTicketInvalid:
		{
			return true;
		}
	}

	return false;
}

stock void ReadMemoryString(Address addr, char[] buffer, int size)
{
	int i = 0;
	char c;
	do
	{
		c = LoadFromAddress(addr + view_as<Address>(i), NumberType_Int8);
		buffer[i] = c;
		i++;
	}
	while (c != '\0' && i < size - 1);

	buffer[size - 1] = '\0';
}

stock void PrintLog(const char[] message, any...)
{
	char buffer[512];
	char path[PLATFORM_MAX_PATH];
	VFormat(buffer, sizeof(buffer), message, 2);
	/* LogToFileEx resolves relative paths against the game dir, so build the absolute path
	 * inside addons/sourcemod/logs (same convention as l4d2_block_no_steam_logon). */
	BuildPath(Path_SM, path, sizeof(path), "logs/" ... LOG_FILE);
	LogToFileEx(path, "%s", buffer);
	PrintToServer("[l4d2_steam_bypass] %s", buffer);
}
