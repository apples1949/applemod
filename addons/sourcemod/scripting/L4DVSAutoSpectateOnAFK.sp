/********************************************************************************************
* Plugin	: L4DVSAutoSpectateOnAFK
* Game		: Left 4 Dead 1/2
* Purpose	: This plugins forces AFK players to spectate, and later it kicks them. Admins 
* 			  are inmune to kick.
*********************************************************************************************/
#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#include <multicolors>
#define PLUGIN_VERSION "2.9-2026/10/2"
#define AUTOSPEC_IDS_MAX 512
#define AFK_BLIP_SOUND "buttons/blip1.wav"


// For cvars
ConVar g_hAfkWarnSpecTime, g_hAfkSpecTime, g_hAfkWarnKickTime, g_hAfkKickTime,
 	g_hAfkCheckInterval, g_hAfkKickEnabled, g_hAfkSaferoomIgnore, g_hAfkSafeRoomExitGrace,
	g_hImmuneAccess, g_hSayResetTime, g_hSpecAfkMsgEnable, g_hAutoSpecSteamIds, g_hImmuneSteamIds, g_hImmuneIps, g_hImmuneNames;

int afkWarnSpecTime, afkSpecTime, afkWarnKickTime, 
	afkKickTime, afkCheckInterval, afkSafeRoomExitGrace;
bool afkKickEnabled, bAfkSaferoomIgnore, g_bSayResetTime, g_bSpecAfkMsgEnable;


// work variables
int afkPlayerTimeLeftWarn[MAXPLAYERS + 1];
int afkPlayerTimeLeftAction[MAXPLAYERS + 1];
float afkPlayerLastPos[MAXPLAYERS + 1][3];
float afkPlayerLastEyes[MAXPLAYERS + 1][3];
bool afkPlayerPendingSafeRoomExit[MAXPLAYERS + 1];	// 在安全屋內就走完倒计时、等待他人离开安全区域的闲置玩家
int afkPlayerSafeRoomExitGrace[MAXPLAYERS + 1];		// 离开安全区域后的最后行动宽限：-1 = 未在宽限中，>=0 = 剩余秒数
bool g_bLeftSafeRoom;
bool L4D2Version;
char g_sAccesslvl[AdminFlags_TOTAL];
char g_sAutoSpecSteamIds[AUTOSPEC_IDS_MAX];
char g_sImmuneSteamIds[AUTOSPEC_IDS_MAX];
char g_sImmuneIps[AUTOSPEC_IDS_MAX];
char g_sImmuneNames[AUTOSPEC_IDS_MAX];
int g_iPlayerSpawn, g_iRoundStart;
Handle PlayerLeftStartTimer, afkCheckThreadTimer;

public Plugin myinfo = 
{
	name = "[L4D1/2] VS Auto-spectate on AFK",
	author = "djromero (SkyDavid, David Romero) & Harry",
	description = "Auto-spectate for AFK players on VS mode",
	version = PLUGIN_VERSION,
	url = "https://steamcommunity.com/profiles/76561198026784913/"
}

bool g_bLate;
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) 
{
	// Checks to see if the game is a L4D game. If it is, check if its the sequel. L4DVersion is L4D if false, L4D2 if true.
	EngineVersion test = GetEngineVersion();
	if( test == Engine_Left4Dead)
		L4D2Version = false;
	else if (test == Engine_Left4Dead2 )
		L4D2Version = true;
	else
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 1 & 2.");
		return APLRes_SilentFailure;
	}

	g_bLate = late;
	return APLRes_Success;
}

public void OnPluginStart()
{
	LoadTranslations("L4DVSAutoSpectateOnAFK.phrases");
	// We register the spectate command
	//RegConsoleCmd("spectate", cmd_spectate);
	RegConsoleCmd("say", Command_Say);
	RegConsoleCmd("say_team", Command_Say);
	
	
	// Changed teams
	HookEvent("player_team", afkChangedTeam);
	
	// Player actions
	HookEvent("entity_shoved", afkPlayerAction);
	HookEvent("player_shoved", afkPlayerAction);
	HookEvent("player_shoot", afkPlayerAction);
	HookEvent("player_jump", afkPlayerAction);
	HookEvent("player_hurt", afkPlayerAction);
	HookEvent("player_hurt_concise", afkPlayerAction);
	HookEntityOutput("func_button_timed", "OnPressed", OnButtonPress);
	
	// For roundstart and roundend..
	HookEvent("round_start", 			Event_RoundStart, 	EventHookMode_PostNoCopy);
	HookEvent("round_end", 				Event_RoundEnd,		EventHookMode_PostNoCopy);
	HookEvent("finale_win", 			Event_RoundEnd,		EventHookMode_PostNoCopy);
	HookEvent("mission_lost", 			Event_RoundEnd,		EventHookMode_PostNoCopy);
	HookEvent("map_transition", 		Event_RoundEnd,		EventHookMode_PostNoCopy);
	HookEvent("player_spawn",			Event_PlayerSpawn,	EventHookMode_PostNoCopy);

	g_hAfkWarnSpecTime 		= CreateConVar("l4d_specafk_warnspectime", 			"10", "游戏中检测到闲置后多少秒出现警告提示", FCVAR_NOTIFY, true, 0.0);
	g_hAfkSpecTime 			= CreateConVar("l4d_specafk_spectime", 				"15", "警告后多少秒强制旁观", FCVAR_NOTIFY, true, 0.0);
	g_hAfkWarnKickTime	 	= CreateConVar("l4d_specafk_warnkicktime", 			"0", "旁观检测到闲置后多少秒出现警告提示", FCVAR_NOTIFY, true, 0.0);
	g_hAfkKickTime 			= CreateConVar("l4d_specafk_kicktime", 				"30", "旁观警告后多少秒踢出", FCVAR_NOTIFY, true, 0.0);
	g_hAfkCheckInterval 	= CreateConVar("l4d_specafk_checkinteral", 			"1", "检测/警告的时间间隔", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hAfkKickEnabled 		= CreateConVar("l4d_specafk_kickenabled", 			"1", "设为1时，当队伍有空位时，旁观状态下的AFK玩家将被踢出", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hAfkSaferoomIgnore 	= CreateConVar("l4d_specafk_saferoom_ignore", 		"0", "设为1时，无论幸存者是否离开安全屋，AFK玩家都会被强制旁观（不影响旁观踢出判定）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hAfkSafeRoomExitGrace = CreateConVar("l4d_specafk_saferoom_exit_grace", 	"5", "在安全屋内就被判定闲置的玩家，其他人离开安全区域后给予的最后行动秒数（每秒提示，超时才强制旁观；0 = 离开安全区域后立即强制旁观）", FCVAR_NOTIFY, true, 0.0);
	g_hImmuneAccess 		= CreateConVar("l4d_specafk_immune_access_flag", 	"-1", "拥有这些权限标志的玩家在旁观时不会被踢出（默认 -1 = 不按权限免疫，所有玩家都会被警告/踢出；填权限标志如 z = 拥有该标志的玩家免疫；留空 = 所有人免疫，会关闭旁观踢人功能）", FCVAR_NOTIFY);
	g_hSayResetTime 		= CreateConVar("l4d_specafk_say_reset", 			"1", "设为1时，玩家在聊天框发言将重置计时", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hSpecAfkMsgEnable 	= CreateConVar("l4d_specafk_join_hint_msg", 		"0", "设为1时，向AFK旁观者显示\"你正在旁观，加入任何队伍开始游戏\"的提示", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hAutoSpecSteamIds 	= CreateConVar("l4d_specafk_autospec_steamids", 	"76561198760610101", "符合条件的 SteamID64 玩家将自动被移动到旁观，且不会被本插件踢出（多个用逗号分隔）", FCVAR_NOTIFY);
	g_hImmuneSteamIds 		= CreateConVar("l4d_specafk_immune_steamids", 	"76561198760610101", "这些 SteamID 玩家在旁观时不会被本插件警告/踢出（多个用逗号分隔；支持 SteamID64 / STEAM_1:0:x / [U:1:x] 三种写法，可直接照抄 auth 日志；默认值与 l4d_specafk_autospec_steamids 相同）", FCVAR_NOTIFY);
	g_hImmuneIps 			= CreateConVar("l4d_specafk_immune_ips", 			"", "这些 IP（或 IP 前缀，如 192.168.1.）的玩家在旁观时不会被本插件警告/踢出（多个用逗号分隔；不使用 Steam 认证，用于 NoSteam 客户端兜底）", FCVAR_NOTIFY);
	g_hImmuneNames 		= CreateConVar("l4d_specafk_immune_names", 		"", "这些显示名在旁观时不会被本插件警告/踢出（多个用逗号分隔；默认空 = 关闭）。注意：显示名由玩家自行修改，任何人改成同名即可绕过踢出，仅在 SteamID/IP 都取不到时（如 NoSteam 客户端）才建议填写", FCVAR_NOTIFY);
	CreateConVar("l4d_specafk_version", PLUGIN_VERSION, "L4D VS 自动AFK旁观插件的版本", FCVAR_DONTRECORD|FCVAR_NOTIFY);
	

	ReadCvars();
	g_hAfkWarnSpecTime.AddChangeHook(ConVarChanged);
	g_hAfkSpecTime.AddChangeHook(ConVarChanged);
	g_hAfkWarnKickTime.AddChangeHook(ConVarChanged);
	g_hAfkKickTime.AddChangeHook(ConVarChanged);
	g_hAfkCheckInterval.AddChangeHook(ConVarChanged);
	g_hAfkKickEnabled.AddChangeHook(ConVarChanged);
	g_hAfkSaferoomIgnore.AddChangeHook(ConVarChanged);
	g_hAfkSafeRoomExitGrace.AddChangeHook(ConVarChanged);
	g_hImmuneAccess.AddChangeHook(ConVarChanged);
	g_hSayResetTime.AddChangeHook(ConVarChanged);
	g_hSpecAfkMsgEnable.AddChangeHook(ConVarChanged);
	g_hAutoSpecSteamIds.AddChangeHook(ConVarChanged);
	g_hImmuneSteamIds.AddChangeHook(ConVarChanged);
	g_hImmuneIps.AddChangeHook(ConVarChanged);
	g_hImmuneNames.AddChangeHook(ConVarChanged);

	if(g_bLate)
	{
		CreateTimer(3.0, tmrStart, _, TIMER_FLAG_NO_MAPCHANGE);
	}
}

public void OnPluginEnd()
{
	ResetPlugin();
	ResetTimer();
}

public void OnMapStart()
{
	// 缓存倒计时提示音，避免地图运行时才加载
	PrecacheSound(AFK_BLIP_SOUND, true);
}

void ReadCvars()
{
	// first we read all the variables ...
	afkWarnSpecTime = g_hAfkWarnSpecTime.IntValue;
	afkSpecTime = g_hAfkSpecTime.IntValue;
	afkWarnKickTime = g_hAfkWarnKickTime.IntValue;
	afkKickTime = g_hAfkKickTime.IntValue;
	afkCheckInterval = g_hAfkCheckInterval.IntValue;
	afkSafeRoomExitGrace = g_hAfkSafeRoomExitGrace.IntValue;
	afkKickEnabled = g_hAfkKickEnabled.BoolValue;
	bAfkSaferoomIgnore = g_hAfkSaferoomIgnore.BoolValue;

	g_hImmuneAccess.GetString(g_sAccesslvl,sizeof(g_sAccesslvl));

	g_bSayResetTime = g_hSayResetTime.BoolValue;
	g_bSpecAfkMsgEnable = g_hSpecAfkMsgEnable.BoolValue;

	g_hAutoSpecSteamIds.GetString(g_sAutoSpecSteamIds, sizeof(g_sAutoSpecSteamIds));
	g_hImmuneSteamIds.GetString(g_sImmuneSteamIds, sizeof(g_sImmuneSteamIds));
	g_hImmuneIps.GetString(g_sImmuneIps, sizeof(g_sImmuneIps));
	g_hImmuneNames.GetString(g_sImmuneNames, sizeof(g_sImmuneNames));
}

void ConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	ReadCvars();
}

// 清除"离开安全区域最后行动宽限"相关状态
void ResetSafeRoomExitState(int client)
{
	afkPlayerPendingSafeRoomExit[client] = false;
	afkPlayerSafeRoomExitGrace[client] = -1;
}

public void OnMapEnd()
{
	ResetPlugin();
	ResetTimer();
}

public void OnClientPutInServer(int client)
{
	if(IsFakeClient(client)) return;

	afkPlayerTimeLeftWarn[client] = afkWarnKickTime;
	afkPlayerTimeLeftAction[client] = afkKickTime;
	ResetSafeRoomExitState(client);

	// 符合自动旁观 cvar 的玩家加入时自动移动到旁观
	if (IsAutoSpecPlayer(client))
		CreateTimer(1.0, tmrForceAutoSpec, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

bool HasAccess(int client, char[] sAcclvl)
{
	// no permissions set
	if (strlen(sAcclvl) == 0)
		return true;

	else if (StrEqual(sAcclvl, "-1"))
		return false;

	// check permissions
	int flag = GetUserFlagBits(client);
	if ( flag & ReadFlagString(sAcclvl) || flag & ADMFLAG_ROOT )
	{
		return true;
	}

	return false;
}

// 玩家的 SteamID 是否命中逗号分隔的名单
// 名单项支持三种写法，方便直接照抄 l4d2_steam_bypass.log / OnClientAuthorized 打印的 auth：
//   SteamID64 "76561197960265728"、Steam2 "STEAM_1:0:123456"、Steam3 "[U:1:123456]"
bool IsSteamIdInList(int client, const char[] sList)
{
	if (strlen(sList) == 0)
		return false;

	// NoSteam 客户端在认证完成前可能取不到 auth，此时返回 false（不影响其它免疫名单）
	char sAuth64[32], sAuth2[32], sAuth3[32];
	bool bHas64 = GetClientAuthId(client, AuthId_SteamID64, sAuth64, sizeof(sAuth64));
	bool bHas2 = GetClientAuthId(client, AuthId_Steam2, sAuth2, sizeof(sAuth2));
	bool bHas3 = GetClientAuthId(client, AuthId_Steam3, sAuth3, sizeof(sAuth3));
	if (!bHas64 && !bHas2 && !bHas3)
		return false;

	char sIds[AUTOSPEC_IDS_MAX];
	strcopy(sIds, sizeof(sIds), sList);

	char sParts[16][48];
	int iCount = ExplodeString(sIds, ",", sParts, sizeof(sParts), sizeof(sParts[]));
	for (int i = 0; i < iCount; i++)
	{
		TrimString(sParts[i]);
		if (sParts[i][0] == '\0')
			continue;

		if ((bHas64 && StrEqual(sParts[i], sAuth64, false))
			|| (bHas2 && StrEqual(sParts[i], sAuth2, false))
			|| (bHas3 && StrEqual(sParts[i], sAuth3, false)))
			return true;
	}

	return false;
}

bool IsAutoSpecPlayer(int client)
{
	return IsSteamIdInList(client, g_sAutoSpecSteamIds);
}

void ForceAutoSpec(int client)
{
	if (client <= 0 || client > MaxClients) return;
	if (!IsClientInGame(client) || IsFakeClient(client)) return;
	if (GetClientTeam(client) == 1) return;

	if (IsAutoSpecPlayer(client))
		ChangeClientTeam(client, 1);
}

Action tmrForceAutoSpec(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client)
		ForceAutoSpec(client);

	return Plugin_Continue;
}

// 旁观免疫名单：不再使用玩家可自行修改的显示名做免疫，避免改名绕过踢出
bool IsImmuneSteamId(int client)
{
	return IsSteamIdInList(client, g_sImmuneSteamIds);
}

// 玩家的 IP 是否命中逗号分隔的名单：名单项以 '.' 结尾时按前缀匹配（如 "192.168.1."），
// 否则要求完全相等。IP 与 Steam 认证无关，用于给 NoSteam 客户端（暖服机器人等）兜底
bool IsIpInList(int client, const char[] sList)
{
	if (strlen(sList) == 0)
		return false;

	char sIP[32];
	if (!GetClientIP(client, sIP, sizeof(sIP)))
		return false;

	char sIds[AUTOSPEC_IDS_MAX];
	strcopy(sIds, sizeof(sIds), sList);

	char sParts[16][48];
	int iCount = ExplodeString(sIds, ",", sParts, sizeof(sParts), sizeof(sParts[]));
	for (int i = 0; i < iCount; i++)
	{
		TrimString(sParts[i]);
		int iLen = strlen(sParts[i]);
		if (iLen == 0)
			continue;

		if (sParts[i][iLen - 1] == '.')
		{
			// 前缀匹配（例如 192.168.1.）
			if (StrContains(sIP, sParts[i], false) == 0)
				return true;
		}
		else if (StrEqual(sParts[i], sIP, false))
		{
			return true;
		}
	}

	return false;
}

bool IsImmuneIp(int client)
{
	return IsIpInList(client, g_sImmuneIps);
}

// 按显示名的免疫名单（可选，默认空）。显示名是玩家可自行修改的，所以它只是 SteamID / IP 都不可用
// 时（例如 NoSteam 客户端拿不到 auth）的兜底手段，填了就等于接受"改名即可绕过"这个代价
bool IsImmuneName(int client)
{
	if (strlen(g_sImmuneNames) == 0)
		return false;

	char sName[MAX_NAME_LENGTH];
	GetClientName(client, sName, sizeof(sName));

	char sIds[AUTOSPEC_IDS_MAX];
	strcopy(sIds, sizeof(sIds), g_sImmuneNames);

	char sParts[16][48];
	int iCount = ExplodeString(sIds, ",", sParts, sizeof(sParts), sizeof(sParts[]));
	for (int i = 0; i < iCount; i++)
	{
		TrimString(sParts[i]);
		if (sParts[i][0] == '\0')
			continue;
		if (StrEqual(sParts[i], sName, false))
			return true;
	}

	return false;
}

bool TeamsHaveOpenSlots()
{
	// 生还者队伍有空位：存在"存活"的 AI 机器人（玩家加入可顶替）
	// 已死亡的生还者 bot 席位（等下一回合复活）不算可补位，避免误警告/踢出旁观玩家
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && IsFakeClient(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i))
			return true;
	}

	// 感染者队伍有空位：可加入的插槽未满
	ConVar hMaxInfected = FindConVar("z_max_player_zombies");
	if (hMaxInfected != null)
	{
		int iInfectedCount = 0;
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsClientInGame(i) && GetClientTeam(i) == 3)
				iInfectedCount++;
		}
		if (iInfectedCount < hMaxInfected.IntValue)
			return true;
	}

	return false;
}

bool IsPlayerConnecting()
{
	// 是否存在正在连接中（已连接但尚未进入游戏，如仍在加载地图）的真人玩家
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i) && !IsFakeClient(i) && !IsClientInGame(i))
			return true;
	}

	return false;
}

Action Command_Say(int client, int args)
{
	if(!g_bSayResetTime) return Plugin_Continue;

	if(client && IsClientInGame(client) && !IsFakeClient(client))
		afkResetTimers(client);

	return Plugin_Continue;
}

void Event_RoundStart (Event event, const char[] name, bool dontBroadcast)
{
	g_bLeftSafeRoom = false;
	if( g_iPlayerSpawn == 1 && g_iRoundStart == 0 )
		CreateTimer(3.0, tmrStart, _, TIMER_FLAG_NO_MAPCHANGE);
	g_iRoundStart = 1;
}

void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client)
		ForceAutoSpec(client);

	if( g_iPlayerSpawn == 0 && g_iRoundStart == 1 )
		CreateTimer(3.0, tmrStart, _, TIMER_FLAG_NO_MAPCHANGE);
	g_iPlayerSpawn = 1;
}

Action tmrStart(Handle timer)
{
	ResetPlugin();

	for (int client=1;client<=MaxClients;client++)
	{
		ResetSafeRoomExitState(client);

		if(IsClientInGame(client) && !IsFakeClient(client))
		{
	// If client is not on spec team
			if (GetClientTeam(client)!=1)
			{
				afkPlayerTimeLeftWarn[client] = afkWarnSpecTime;
				afkPlayerTimeLeftAction[client] = afkSpecTime;
			}
			else // if player is on spectators
			{
				afkPlayerTimeLeftWarn[client] = afkWarnKickTime;
				afkPlayerTimeLeftAction[client] = afkKickTime;
			}
			
			GetClientAbsOrigin(client, afkPlayerLastPos[client]);
			GetClientEyeAngles(client, afkPlayerLastEyes[client]);

			// 符合自动旁观 cvar 的玩家（含 late load 时已在游戏中的）强制回到旁观
			ForceAutoSpec(client);
		}
		else
		{
			afkPlayerTimeLeftWarn[client] = afkWarnSpecTime;
			afkPlayerTimeLeftAction[client] = afkSpecTime;
		}
	}

	delete PlayerLeftStartTimer;
	PlayerLeftStartTimer = CreateTimer(1.0, PlayerLeftStart, _, TIMER_REPEAT);

	delete afkCheckThreadTimer;
	afkCheckThreadTimer = CreateTimer(float(afkCheckInterval), afkCheckThread, _, TIMER_REPEAT);

	return Plugin_Continue;
}


void Event_RoundEnd (Event event, const char[] name, bool dontBroadcast)
{
	ResetPlugin();
	ResetTimer();
}

void afkPlayerAction (Event event, const char[] name, bool dontBroadcast)
{
	int client;
	
	// gets the property name
	if (strcmp(name, "entity_shoved", false)==0)
		client = GetClientOfUserId(event.GetInt("attacker"));
	else if (strcmp(name, "player_shoved", false)==0)
		client = GetClientOfUserId(event.GetInt("attacker"));
	else if (strcmp(name, "player_hurt", false)==0)
		client = GetClientOfUserId(event.GetInt("attacker"));
	else if (strcmp(name, "player_hurt_concise", false)==0)
		// 该事件没有 attacker 字段，只有攻击者实体下标（攻击者为玩家时即为客户端下标）
		client = event.GetInt("attackerentid");
	else 
		client = GetClientOfUserId(event.GetInt("userid"));
	
	// resets his timers
	if (client > 0 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client))
		afkResetTimers(client);
}

void OnButtonPress(const char[] name, int caller, int activator, float delay)
{
	if (activator < 1 || activator > MaxClients || !IsClientInGame(activator))
		return;
	
	afkResetTimers(activator);
}

void afkChangedTeam (Event event, const char[] name, bool dontBroadcast)
{
	// we get the victim
	CreateTimer(0.5, ClientReallyChangeTeam, event.GetInt("userid"), TIMER_FLAG_NO_MAPCHANGE); // check delay
}

Action ClientReallyChangeTeam(Handle timer, int victim)
{
	victim = GetClientOfUserId(victim);

	if( victim <= 0 || victim > MaxClients || !IsClientInGame(victim) || IsFakeClient(victim)) return Plugin_Continue;
	
	// Reset his afk status
	afkResetTimers(victim);

	// 符合自动旁观 cvar 的玩家换队后强制回到旁观
	ForceAutoSpec(victim);

	return Plugin_Continue;
}

Action afkJoinHint (Handle Timer, int client)
{
	if(!g_bSpecAfkMsgEnable) return Plugin_Stop;

	client = GetClientOfUserId(client);
	// If player is valid
	// 不再要求"警告计时 > 0"：旁观者的警告计时取自 l4d_specafk_warnkicktime，默认为 0，
	// 旧条件会让本提示每次都立刻 Plugin_Stop，导致 l4d_specafk_join_hint_msg 1 完全无效
	if (client && IsClientInGame(client))
	{
		// If player is still on spectators ...
		if (GetClientTeam(client) == 1)
		{
			// We send him a hint text ...
			PrintHintText(client, "%T", "You're spectating. Join any team to play.", client);
			
			return Plugin_Continue;
		}
	}
	
	return Plugin_Stop;
}

void afkResetTimers (int client)
{
	// 玩家已行动 / 状态变化：清掉待旁观与离开安全区域宽限状态
	ResetSafeRoomExitState(client);

	// If client is not on spec team
	if (GetClientTeam(client)!=1)
	{
		afkPlayerTimeLeftWarn[client] = afkWarnSpecTime;
		afkPlayerTimeLeftAction[client] = afkSpecTime;
	}
	else // if player is on spectators
	{
		afkPlayerTimeLeftWarn[client] = afkWarnKickTime;
		afkPlayerTimeLeftAction[client] = afkKickTime;
	}
	
	GetClientAbsOrigin(client, afkPlayerLastPos[client]);
	GetClientEyeAngles(client, afkPlayerLastEyes[client]);
}

void AFKPlayBlipSound(int client)
{
	if (client > 0 && client <= MaxClients && IsClientInGame(client))
		EmitSoundToClient(client, AFK_BLIP_SOUND);
}

void AFKCountdownWarn(int client, const char[] phrase, int seconds)
{
	// 倒计时提示：Hint 文本 + 提示音
	PrintHintText(client, "%T", phrase, client, seconds);
	AFKPlayBlipSound(client);
}

// 玩家是否适合参与闲置检测
// 死亡 / 倒地 / 挂边时玩家无法正常行动，位置与视角几乎不会变化，
// 继续做检测会被误判为 AFK，因此这些状态一律不检测
bool IsPlayerAfkCheckable(int client)
{
	// 死亡（含死亡后跟随队友视角的状态）
	if (!IsPlayerAlive(client))
		return false;

	// 倒地（Tank 在死亡动画期间也会返回 true）
	if (L4D_IsPlayerIncapacitated(client))
		return false;

	// 挂边：挂在边沿等待救援，无法移动
	if (L4D_IsPlayerHangingFromLedge(client))
		return false;

	return true;
}

int g_iLastTick;
Action afkCheckThread(Handle timer)
{
	//時間被暫停
	if(g_iLastTick == GetGameTickCount()) return Plugin_Continue;
	g_iLastTick = GetGameTickCount();

	bool bTeamsOpen = TeamsHaveOpenSlots(); // 本次检测时对抗双方队伍是否有空位（仅当有空位时才检测旁观闲置）
	// 补位检测跳过：幸存者未离开安全区域且有玩家正在连接中时，不检测/踢出旁观AFK（连接中的玩家即将补位）
	bool bSkipFillDetection = !g_bLeftSafeRoom && IsPlayerConnecting();

	float pos[3];
	float eyes[3];
	bool isAFK;
	// we check all connected (and alive) clients ...
	for (int i=1;i<=MaxClients;i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
		{
			// If player is not on spectators team ...
			if (GetClientTeam(i) > 1)
			{
				// 只有存活且能正常行动的玩家才做闲置检测：
				// 死亡 / 倒地 / 挂边时玩家无法移动，位置与视角不变，继续检测会误判成 AFK
				if (IsPlayerAfkCheckable(i))
				{
					// we get his current coordinates and eyes
					GetClientAbsOrigin(i, pos);
					GetClientEyeAngles(i, eyes);
					
					isAFK = true;
					
					if(GetVectorDistance(pos, afkPlayerLastPos[i]) > 80.0)
					{
						isAFK = false;
					}
					
					if(isAFK)
					{
						if(eyes[0] != afkPlayerLastEyes[i][0] || 
							eyes[1] != afkPlayerLastEyes[i][1]) 
						{
							isAFK = false;
						}
					}

					// if he hasn't moved ..
					if (isAFK)
					{
						// if the player is not trapped (incapacitated, pounced, etc)
						if (GetInfectedAttacker(i) == -1)
						{
							// If player has not been warned ...
							if (afkPlayerTimeLeftWarn[i] > 0) // warn time ...
							{
								// we reduce his warn time ...
								afkPlayerTimeLeftWarn[i] = afkPlayerTimeLeftWarn[i] - afkCheckInterval;
								
								// if his warn time reached 0 ....
								if (afkPlayerTimeLeftWarn[i] <= 0)
								{
									// we set his time left to spectate
									afkPlayerTimeLeftAction[i] = afkSpecTime;
									
									// We warn the player ....
									AFKCountdownWarn(i, "[AFK] Inactivity detected! 1", afkPlayerTimeLeftAction[i]);
								}
							}
							else // player warn timeout reached ...
							{
								// 在安全屋内就被判定闲置、倒计时走完的玩家：其他人离开安全区域后
								// 再给他 afkSafeRoomExitGrace 秒最后行动时间（每秒提示），仍不行动才强制旁观
								if (afkPlayerPendingSafeRoomExit[i] && g_bLeftSafeRoom && !bAfkSaferoomIgnore)
								{
									// 首次进入宽限
									if (afkPlayerSafeRoomExitGrace[i] < 0)
										afkPlayerSafeRoomExitGrace[i] = afkSafeRoomExitGrace;

									if (afkPlayerSafeRoomExitGrace[i] > 0)
									{
										// 离开安全区域后每秒提示剩余行动时间
										AFKCountdownWarn(i, "[AFK] Inactivity detected! 6", afkPlayerSafeRoomExitGrace[i]);
										afkPlayerSafeRoomExitGrace[i] = afkPlayerSafeRoomExitGrace[i] - afkCheckInterval;
									}
									else // 宽限时间用尽 ... 强制旁观
									{
										afkForceSpectate(i, true);
									}
								}
								else
								{
									// we reduce his action time
									afkPlayerTimeLeftAction[i] = afkPlayerTimeLeftAction[i] - afkCheckInterval;
									
									// if his action time reached 0 ...
									if (afkPlayerTimeLeftAction[i] <= 0)
									{
										// If players leaved safe room we force him to spectate
										if (g_bLeftSafeRoom || bAfkSaferoomIgnore)
										{
											afkForceSpectate(i, true);
										}
										else // if players haven't leaved safe room ... we warn this player that he will be forced to spectate as soon as a player leaves
										{
											// 记住：该玩家在安全屋内就被判定闲置，离开安全区域后还有最后宽限时间
											afkPlayerPendingSafeRoomExit[i] = true;

											// 提示里的秒数取自 l4d_specafk_saferoom_exit_grace；
											// 该 cvar 为 0 时没有宽限（离开安全区域即强制旁观），改用无秒数的提示
											if (afkSafeRoomExitGrace > 0)
												PrintHintText(i, "%T", "[AFK] Inactivity detected! 2", i, afkSafeRoomExitGrace);
											else
												PrintHintText(i, "%T", "[AFK] Inactivity detected! 7", i);
										}
									}
									else // we just warn him ...
										AFKCountdownWarn(i, "[AFK] Inactivity detected! 1", afkPlayerTimeLeftAction[i]);
								}
							}
						} // player is not trapped
						else // player is trapped
						{
							afkResetTimers(i);
						}
					} // player hasn't moved ...
					else // player moved ...
					{
						afkResetTimers(i);
					}
				} // player is alive and able to act
				else
				{
					// 死亡 / 倒地 / 挂边：玩家无法正常行动，不检测闲置，仅重置计时
					afkResetTimers(i);
				}
			} // player is not on spectators ...
			else if (afkKickEnabled && bTeamsOpen && !bSkipFillDetection) // 旁观检测：仅当对抗双方队伍有空位且不处于"未离开安全区域+有人连接中"时才触发（生还者有AI机器人 / 感染者有空位）
			{
				// If the player is not registered ...
				if (HasAccess(i, g_sAccesslvl) == false && !IsAutoSpecPlayer(i) && !IsImmuneSteamId(i) && !IsImmuneIp(i) && !IsImmuneName(i)) // 有权限、符合自动旁观 cvar 或在免疫 SteamID / IP / 名字名单里的玩家不警告不踢出
				{
					// If player has not been warned ...
					if (afkPlayerTimeLeftWarn[i] > 0) // warn time ...
					{
						// we reduce his warn time ...
						afkPlayerTimeLeftWarn[i] = afkPlayerTimeLeftWarn[i] - afkCheckInterval;
						
						// if his warn time reached 0 ....
						if (afkPlayerTimeLeftWarn[i] <= 0)
						{
							// We warn the player ....
							AFKCountdownWarn(i, "[AFK] Inactivity detected! 3", afkPlayerTimeLeftAction[i]);
						}
					}
					else // player warn timeout reached ...
					{
						// we reduce his action time
						afkPlayerTimeLeftAction[i] = afkPlayerTimeLeftAction[i] - afkCheckInterval;
						
						// if his action time reached 0 ...
						if (afkPlayerTimeLeftAction[i] <=  0)
						{
							// we kick the player
							afkKickClient(i);
						}
						else // we just warn him ...
							AFKCountdownWarn(i, "[AFK] Inactivity detected! 3", afkPlayerTimeLeftAction[i]);
					}			
				} // player is not admin
			} // player is on spectators
		} // player is connected and in-game
	}
	
	// We continue with the timer
	return Plugin_Continue;
}


void AFKPrintHint(int client, const char[] phrase)
{
	char sBuffer[256];
	SetGlobalTransTarget(client);
	Format(sBuffer, sizeof(sBuffer), "%T", phrase, client);
	CRemoveTags(sBuffer, sizeof(sBuffer));
	PrintHintText(client, "%s", sBuffer);
}

void AFKPrintHintToAll(const char[] phrase, const char[] name)
{
	char sBuffer[256];
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
		{
			SetGlobalTransTarget(i);
			Format(sBuffer, sizeof(sBuffer), "%T", phrase, i, name);
			CRemoveTags(sBuffer, sizeof(sBuffer));
			PrintHintText(i, "%s", sBuffer);
		}
	}
}

void afkForceSpectate (int client, bool advertise)
{
	// 已强制旁观：清掉待旁观与离开安全区域宽限状态，避免状态残留
	ResetSafeRoomExitState(client);

	// We force him to spectate
	ChangeClientTeam(client, 1);
	
	// We send him a hint message 5 seconds later, in case he hasn't joined any team
	CreateTimer(5.0, afkJoinHint, GetClientUserId(client), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	
	// Print forced info
	if (advertise)
	{
		char sName[MAX_NAME_LENGTH];
		GetClientName(client, sName, sizeof(sName));

		// 被强制旁观者：聊天框 + 中央 Hint
		CPrintToChat(client, "%T", "afkForceSpectate", client);
		AFKPrintHint(client, "afkForceSpectate");

		// 所有人：聊天框 + 中央 Hint
		CPrintToChatAll("%t", "[AFK] Inactivity detected! 5", sName);
		AFKPrintHintToAll("[AFK] Inactivity detected! 5", sName);
	}
}

void afkKickClient (int client)
{
	if (IsFakeClient(client))
		return;
	
	// 踢出原因按被踢玩家的语言显示（KickClient 会以该玩家为翻译目标格式化）
	KickClient(client, "%T", "kickplayer", client, afkKickTime);
	
	// Print forced info
	char sName[MAX_NAME_LENGTH];
	GetClientName(client, sName, sizeof(sName));
	CPrintToChatAll("%t", "have been kicked from server due to inactivity", sName, afkKickTime);
}

Action PlayerLeftStart(Handle Timer)
{
	if (L4D_HasAnySurvivorLeftSafeArea())
	{
		g_bLeftSafeRoom = true;
		PlayerLeftStartTimer = null;
		return Plugin_Stop;
	}

	return Plugin_Continue;
}

int GetInfectedAttacker(int client)
{
	int attacker;

	if(L4D2Version)
	{
		/* Charger */
		attacker = GetEntPropEnt(client, Prop_Send, "m_pummelAttacker");
		if (attacker > 0)
		{
			return attacker;
		}

		attacker = GetEntPropEnt(client, Prop_Send, "m_carryAttacker");
		if (attacker > 0)
		{
			return attacker;
		}
		/* Jockey */
		attacker = GetEntPropEnt(client, Prop_Send, "m_jockeyAttacker");
		if (attacker > 0)
		{
			return attacker;
		}
	}

	/* Hunter */
	attacker = GetEntPropEnt(client, Prop_Send, "m_pounceAttacker");
	if (attacker > 0)
	{
		return attacker;
	}

	/* Smoker */
	attacker = GetEntPropEnt(client, Prop_Send, "m_tongueOwner");
	if (attacker > 0)
	{
		return attacker;
	}

	return -1;
}

void ResetPlugin()
{
	g_iRoundStart = 0;
	g_iPlayerSpawn = 0;
}

void ResetTimer()
{
	delete PlayerLeftStartTimer;
	delete afkCheckThreadTimer;
}
