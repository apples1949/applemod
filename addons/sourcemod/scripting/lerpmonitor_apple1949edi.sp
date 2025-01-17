#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <colors>

#define STEAMID_SIZE 32

#define L4D_TEAM_SPECTATE 1
#define L4D_TEAM_SURVIVORS 2

StringMap
	ArrLerpsValue = null,
	ArrLerpsCountChanges = null;
	
ConVar 
	cVarReadyUpLerpChanges = null,
	cVarAllowedLerpChanges = null,
	cVarLerpChangeSpec = null,
	cVarMinLerp = null,
	cVarMaxLerp = null,
	cVarMinUpdateRate = null,
	cVarMaxUpdateRate = null,
	cVarMinInterpRatio = null,
	cVarMaxInterpRatio = null,
	cVarShowLerpTeamChange = null;

bool
	IsLateLoad = false,
	isFirstHalf = true,
	isMatchLife = true,
	isTransfer = false;

public Plugin myinfo = 
{
	name = "LerpMonitor++",
	author = "ProdigySim, Die Teetasse, vintik, A1m`",
	description = "Keep track of players' lerp settings",
	version = "2.3",
	url = "https://github.com/A1mDev/L4D2-Competitive-Plugins"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	IsLateLoad = late;
	CreateNative("LM_GetLerpTime", LM_GetLerpTime);
	CreateNative("LM_GetCurrentLerpTime", LM_GetCurrentLerpTime);
	RegPluginLibrary("lerpmonitor");
	return APLRes_Success;
}

public int LM_GetLerpTime(Handle plugin, int numParams) 
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients) {
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index %d!", client);
	}
	
	if (!IsClientInGame(client)) {
		return ThrowNativeError(SP_ERROR_NATIVE, "Client %d is not in game!", client);
	}
	
	float fLerpValue = -1.0;
	char sSteamID[STEAMID_SIZE];
	GetClientAuthId(client, AuthId_Steam2, sSteamID, sizeof(sSteamID));
	if (ArrLerpsValue.GetValue(sSteamID, fLerpValue)) {
		return view_as<int>(fLerpValue);
	}
	return view_as<int>(-1.0);
}

public int LM_GetCurrentLerpTime(Handle plugin, int numParams) 
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients) {
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index %d!", client);
	}
	
	if (!IsClientConnected(client)) {
		return ThrowNativeError(SP_ERROR_NATIVE, "Client %d not connected!", client);
	}
	
	return view_as<int>(GetLerpTime(client));
}

public void OnPluginStart()
{
	cVarAllowedLerpChanges = CreateConVar("sm_allowed_lerp_changes", "4", "Allowed number of lerp changes for a half", _, true, 0.0, true, 20.0);
	cVarLerpChangeSpec = CreateConVar("sm_lerp_change_spec", "1", "Move to spectators on exceeding lerp changes count?", _, true, 0.0, true, 1.0);
	cVarReadyUpLerpChanges = CreateConVar("sm_readyup_lerp_changes", "1", "Allow lerp changes during ready-up", _, true, 0.0, true, 1.0);
	cVarShowLerpTeamChange = CreateConVar("sm_show_lerp_team_changes", "1", "show a message about the player's lerp if he changes the team", _, true, 0.0, true, 1.0);
	cVarMinLerp = CreateConVar("sm_min_lerp", "0.000", "Minimum allowed lerp value", _, true, 0.000, true, 0.500);
	cVarMaxLerp = CreateConVar("sm_max_lerp", "0.067", "Maximum allowed lerp value", _, true, 0.000, true, 0.500);
	
	RegConsoleCmd("sm_lerps", Lerps_Cmd, "List the Lerps of all players in game");
	
	cVarMinUpdateRate = FindConVar("sv_minupdaterate");
	cVarMaxUpdateRate = FindConVar("sv_maxupdaterate");
	cVarMinInterpRatio = FindConVar("sv_client_min_interp_ratio");
	cVarMaxInterpRatio = FindConVar("sv_client_max_interp_ratio");
	
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
	HookEvent("player_team", OnTeamChange, EventHookMode_Post);
	HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Post);
	HookEvent("player_left_start_area", Event_RoundGoesLive, EventHookMode_PostNoCopy);
	
	// create arrays
	ArrLerpsValue = new StringMap();
	ArrLerpsCountChanges = new StringMap();
	
	if (IsLateLoad) {
		// process current players
		for (int i = 1; i <= MaxClients; i++) {
			if (IsClientInGame(i) && !IsFakeClient(i)) {
				ProcessPlayerLerp(i, true);
			}
		}
	}
}

public void OnClientPutInServer(int client)
{
	if (IsValidEntity(client) && !IsFakeClient(client)) {
		CreateTimer(1.0, Process, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	}
}

public Action Process(Handle hTimer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client > 0 && GetClientTeam(client) > L4D_TEAM_SPECTATE) {
		ProcessPlayerLerp(client);
	}

	return Plugin_Stop;
}

public void OnMapStart()
{
	isMatchLife = false;
}

public void OnMapEnd()
{
	isFirstHalf = true;
	ArrLerpsValue.Clear();
	ArrLerpsCountChanges.Clear();
}

public void Event_RoundGoesLive(Event hEvent, const char[] name, bool dontBroadcast)
{
	//This event works great with the plugin readyup.smx (does not conflict)
	//This event works great in different game modes: versus, coop, scavenge and etc
	isMatchLife = true;
}

public void OnClientSettingsChanged(int client)
{
	if (IsValidEntity(client) && !IsFakeClient(client)) {
		ProcessPlayerLerp(client);
	}
}

public void Event_PlayerDisconnect(Event hEvent, const char[] name, bool dontBroadcast)
{
	char SteamID[64];
	hEvent.GetString("networkid", SteamID, sizeof(SteamID));
	
	if (StrContains(SteamID, "STEAM") != 0) {
		return;
	}
	
	ArrLerpsValue.Remove(SteamID);
	//ArrLerpsCountChanges.Remove(SteamID);
}

public void OnTeamChange(Event hEvent, const char[] eName, bool dontBroadcast)
{
	if (hEvent.GetInt("team") > L4D_TEAM_SPECTATE) {
		int userid = hEvent.GetInt("userid");
		int client = GetClientOfUserId(userid);
		if (client > 0 && IsClientInGame(client) && !IsFakeClient(client)) {
			if (!isTransfer) {
				CreateTimer(0.1, OnTeamChangeDelay, userid, TIMER_FLAG_NO_MAPCHANGE);
			}
		}
	}
}

public Action OnTeamChangeDelay(Handle hTimer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client > 0) {
		ProcessPlayerLerp(client, false, true);
	}
	return Plugin_Stop;
}

public void Event_RoundEnd(Event hEvent, const char[] name, bool dontBroadcast)
{
	// little delay for other round end used modules
	CreateTimer(0.5, Timer_RoundEndDelay, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_RoundEndDelay(Handle hTimer)
{
	isFirstHalf = false;
	isTransfer = true;
	isMatchLife = false;

	ArrLerpsCountChanges.Clear();

	return Plugin_Stop;
}

public Action Lerps_Cmd(int client, int args)
{
	bool isEmpty = true;
	int survivorCount = 0;
	int infectedCount = 0;
	if (ArrLerpsValue.Size > 0) {
		CPrintToChat(client, "{blue}[{default}!{blue}] {green}玩家Lerp设置列表:");
		for(int rclient=1; rclient <= MaxClients; rclient++)
		{
			if(IsClientInGame(rclient) && !IsFakeClient(rclient))
			{
				if (GetClientTeam(rclient) == 2) survivorCount = 1;
				if (GetClientTeam(rclient) == 3) infectedCount = 1;
			}
		}
		float fLerpValue;
		char sSteamID[STEAMID_SIZE];
		CPrintToChat(client, "{blue}{green}______________________________");
		/*
		for (int i = 1; i <= MaxClients; i++) {
			if (IsClientInGame(i) && !IsFakeClient(i)) {
				GetClientAuthId(i, AuthId_Steam2, sSteamID, sizeof(sSteamID));
				
				if (ArrLerpsValue.GetValue(sSteamID, fLerpValue)) {
					ReplyToCommand(client, "%N [%s]: %.01f", i, sSteamID, fLerpValue * 1000);
					isEmpty = false;
				}
			}
		}
		*/
		for(int rclient=1; rclient <= MaxClients; rclient++)
		{
			if(IsClientInGame(rclient) && !IsFakeClient(rclient) && GetClientTeam(rclient) == 2)
			{
				GetClientAuthId(rclient, AuthId_Steam2, sSteamID, sizeof(sSteamID));
				
				if (ArrLerpsValue.GetValue(sSteamID, fLerpValue)) {
					CPrintToChat(client, "{blue}%N {default}[%s]@ {green}%.01f", rclient, sSteamID, fLerpValue * 1000);
					isEmpty = false;
				}
			}
		}
		if (survivorCount == 1 || infectedCount == 1) CPrintToChat(client, "{blue}{green}______________________________");
		for(int rclient=1; rclient <= MaxClients; rclient++)
		{
			if(IsClientInGame(rclient) && !IsFakeClient(rclient) && GetClientTeam(rclient) == 3)
			{
				GetClientAuthId(rclient, AuthId_Steam2, sSteamID, sizeof(sSteamID));
				
				if (ArrLerpsValue.GetValue(sSteamID, fLerpValue)) {
					CPrintToChat(client, "{red}%N {default}[%s]@ {green}%.01f", rclient, sSteamID, fLerpValue * 1000);
					isEmpty = false;
				}
			}
		}
		CPrintToChat(client, "{blue}{green}______________________________");
	}
	
	if (isEmpty) {
		CPrintToChat(client, "{blue}[{default}!{blue}] {green}未记录到玩家Lerp设置!");
	}
	return Plugin_Handled;
}

public void Event_RoundStart(Event hEvent, const char[] name, bool dontBroadcast)
{
	// delete change count for second half
	if (!isFirstHalf) {
		ArrLerpsCountChanges.Clear();
	}
	
	CreateTimer(0.5, OnTransfer, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action OnTransfer(Handle hTimer)
{
	isTransfer = false;
	return Plugin_Stop;
}

void ProcessPlayerLerp(int client, bool load = false, bool team = false) 
{
	float newLerpTime = GetLerpTime(client); // get lerp
	
	// set lerp for fixing differences between server and client with cl_interp_ratio 0
	SetEntPropFloat(client, Prop_Data, "m_fLerpTime", newLerpTime);
	
	// check lerp first
	if (GetClientTeam(client) < L4D_TEAM_SURVIVORS) {
		return;
	}
	
	// Get steamid
	char steamID[STEAMID_SIZE];
	GetClientAuthId(client, AuthId_Steam2, steamID, sizeof(steamID));

	if ((FloatCompare(newLerpTime, cVarMinLerp.FloatValue) == -1)  || (FloatCompare(newLerpTime, cVarMaxLerp.FloatValue) == 1)) {
		//PrintToChatAll("%N's lerp changed to %.01f", client, newLerpTime * 1000);
		if (!load) {
			float currentLerpTime = 0.0;
			if (ArrLerpsValue.GetValue(steamID, currentLerpTime)) {
				if (currentLerpTime == newLerpTime) { // no change?
					ChangeClientTeam(client, L4D_TEAM_SPECTATE); 
					return;
				}
			}
			
			CPrintToChatAllEx(client, "{default}<{olive}Lerp{default}> {teamcolor}%N {default}因Lerp值为 {teamcolor}%.01f {default}而被移动到旁观!", client, newLerpTime * 1000);
			ChangeClientTeam(client, L4D_TEAM_SPECTATE);
			CPrintToChatEx(client, client, "{default}<{olive}Lerp{default}> 非法Lerp值 (最小: {teamcolor}%.01f{default}, 最大: {teamcolor}%.01f{default})控制台输入'cl_interp 0'以修改lerp值!", cVarMinLerp.FloatValue * 1000, cVarMaxLerp.FloatValue * 1000);
		}
		
		// nothing else to do
		return;
	}
	
	float currentLerpTime = 0.0;
	if (!ArrLerpsValue.GetValue(steamID, currentLerpTime)) {
		// add to array
		if (team && cVarShowLerpTeamChange.BoolValue) {
			CPrintToChatAllEx(client, "{default}<{olive}Lerp{default}> {teamcolor}%N {default}@ {teamcolor}%.01f", client, newLerpTime * 1000);
		}

		ArrLerpsValue.SetValue(steamID, newLerpTime, true);
		//ArrLerpsCountChanges.SetValue(steamID, 0, true); 
		return;
	}
	
	if (currentLerpTime == newLerpTime) { // no change?
		if (team && cVarShowLerpTeamChange.BoolValue) {
			CPrintToChatAllEx(client, "{default}<{olive}Lerp{default}> {teamcolor}%N {default}@ {teamcolor}%.01f", client, newLerpTime * 1000); 
		}
		return;
	}

	if (isMatchLife || !cVarReadyUpLerpChanges.BoolValue) { // Midgame?
		int count = 0;
		ArrLerpsCountChanges.GetValue(steamID, count);
		count++;
		
		int max = cVarAllowedLerpChanges.IntValue;
		CPrintToChatAllEx(client, "{default}<{olive}Lerp{default}> {teamcolor}%N {default}@ {teamcolor}%.01f {default}<== {green}%.01f {default}[%s%d{default}/%d {olive}changes]", client, newLerpTime * 1000, currentLerpTime * 1000, ((count > max) ? "{teamcolor} ": ""), count, max);
	
		if (cVarLerpChangeSpec.BoolValue && (count > max)) {
			CPrintToChatAllEx(client, "{default}<{olive}Lerp{default}> {teamcolor}%N {default}被移动到旁观 (更改非法Lerp值)!", client);
			ChangeClientTeam(client, L4D_TEAM_SPECTATE);
			CPrintToChatEx(client, client, "{default}<{olive}Lerp{default}> 你在游戏中更改非法Lerp值! 请改到 {teamcolor}%.01f {default}及以下!", currentLerpTime * 1000);
			// no lerp update
			return;
		}
		
		ArrLerpsCountChanges.SetValue(steamID, count); // update changes
	} else {
		CPrintToChatAllEx(client, "{default}<{olive}Lerp{default}> {teamcolor}%N {default}@ {teamcolor}%.01f {default}<== {green}%.01f", client, newLerpTime * 1000, currentLerpTime * 1000);
	}
	
	ArrLerpsValue.SetValue(steamID, newLerpTime); // update lerp
	//ArrLerpsCountChanges.SetValue(steamID, 0, true); 
}

float GetLerpTime(int client)
{
	char buffer[64];
	
	if (!GetClientInfo(client, "cl_updaterate", buffer, sizeof(buffer))) {
		buffer = "";
	}
	
	int updateRate = StringToInt(buffer);
	updateRate = RoundFloat(clamp(float(updateRate), cVarMinUpdateRate.FloatValue, cVarMaxUpdateRate.FloatValue));
	
	if (!GetClientInfo(client, "cl_interp_ratio", buffer, sizeof(buffer))) {
		buffer = "";
	}
	
	float flLerpRatio = StringToFloat(buffer);
	
	if (!GetClientInfo(client, "cl_interp", buffer, sizeof(buffer))) {
		buffer = "";
	}
	
	float flLerpAmount = StringToFloat(buffer);
	
	if (cVarMinInterpRatio != null && cVarMaxInterpRatio != null && cVarMinInterpRatio.FloatValue != -1.0) {
		flLerpRatio = clamp(flLerpRatio, cVarMinInterpRatio.FloatValue, cVarMaxInterpRatio.FloatValue);
	}
	
	return maximum(flLerpAmount, flLerpRatio / updateRate);
}

float maximum(float a, float b)
{
	return (a > b) ? a : b;
}

float clamp(float inc, float low, float high)
{
	return (inc > high) ? high : ((inc < low) ? low : inc);
}
