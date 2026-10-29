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
#define PLUGIN_VERSION "2.15-12v12"
#define AUTOSPEC_IDS_MAX 512
#define AFK_BLIP_SOUND "buttons/blip1.wav"
// 聊天框同步节流间隔（秒）：中央 Hint 每秒刷新无所谓，聊天框每秒都刷就是刷屏
#define AFK_COUNTDOWN_CHAT_INTERVAL 10.0	// 秒级倒计时提示（"还剩 N 秒"）同步到聊天框的最小间隔
#define AFK_JOIN_HINT_CHAT_INTERVAL 20.0	// 强制旁观后"你正在旁观"循环提示同步到聊天框的最小间隔

// 可选依赖 l4d2_fix_team_shuffle_edi：正在锁队还原队伍时，跳过对旁观玩家的闲置警告与踢出
//（修正期间 jointeam 被拦截，旁观玩家无法自行补位）。该插件未加载时本插件照常运行。
native bool L4D2_FixTeamShuffle_IsFixComplete();


// For cvars
ConVar g_hAfkWarnSpecTime, g_hAfkSpecTime, g_hAfkWarnKickTime, g_hAfkKickTime,
 	g_hAfkCheckInterval, g_hAfkKickEnabled, g_hAfkSaferoomIgnore, g_hAfkSafeRoomExitGrace,
	g_hImmuneAccess, g_hSayResetTime, g_hSpecAfkMsgEnable, g_hAutoSpecSteamIds, g_hImmuneSteamIds, g_hImmuneIps, g_hImmuneNames,
	g_hIgnoreDeadSurvivorSlot, g_hKickNotify;

int afkWarnSpecTime, afkSpecTime, afkWarnKickTime, 
	afkKickTime, afkCheckInterval;
float afkSafeRoomExitGrace;	// 有人离开安全区域后，闲置玩家还要等多少秒才强制旁观（l4d_specafk_saferoom_exit_grace）
bool afkKickEnabled, bAfkSaferoomIgnore, g_bSayResetTime, g_bSpecAfkMsgEnable;
bool g_bIgnoreDeadSurvivorSlot;	// 生还者队有人躺着占名额时，不把生还者侧算作可补位


// work variables
int afkPlayerTimeLeftWarn[MAXPLAYERS + 1];
int afkPlayerTimeLeftAction[MAXPLAYERS + 1];
float afkPlayerLastPos[MAXPLAYERS + 1][3];
float afkPlayerLastEyes[MAXPLAYERS + 1][3];
bool afkPlayerPendingSafeRoomExit[MAXPLAYERS + 1];	// 已判定闲置、正在等"离开安全区域 + 延迟秒数"走完的玩家（原意：在安全屋內就走完倒计时、等待他人离开安全区域的闲置玩家）
int afkPlayerSafeRoomExitGrace[MAXPLAYERS + 1];		// 离开安全区域后的最后行动宽限：-1 = 未在宽限中，>=0 = 当前提示给玩家的剩余秒数
bool g_bLeftSafeRoom;
// 本回合第一个生还者离开安全区域的时刻（GetGameTime 基准）。-1 = 还没有人离开安全区域。
// 强制旁观一律以这个时刻 + l4d_specafk_saferoom_exit_grace 为时间闸门，而不是靠每次检测做秒数递减：
// 递减会受到 l4d_specafk_checkinteral 的影响（间隔 2 秒时 5 秒会被拖成 8 秒），也不覆盖
// "在安全屋内就开始倒计时、倒计时还没走完人就已经离开安全区域"的玩家。
float g_fSafeRoomExitTime = -1.0;
float g_fLastChatWarn[MAXPLAYERS + 1];		// 秒级倒计时提示"同步到聊天框"的节流计时
float g_fLastChatJoinHint[MAXPLAYERS + 1];	// 旁观循环提示"同步到聊天框"的节流计时
bool L4D2Version;
bool g_bFixTeamShuffleLoaded;	// 可选依赖 l4d2_fix_team_shuffle_edi 是否已加载
bool g_bFixTeamShuffleRunning;	// 队伍修正插件是否正处于锁队还原期间（每次闲置检测时缓存，供旁观检测判断）
char g_sAccesslvl[AdminFlags_TOTAL];
char g_sAutoSpecSteamIds[AUTOSPEC_IDS_MAX];
char g_sImmuneSteamIds[AUTOSPEC_IDS_MAX];
char g_sImmuneIps[AUTOSPEC_IDS_MAX];
char g_sImmuneNames[AUTOSPEC_IDS_MAX];
bool g_bRoundActive;
Handle PlayerLeftStartTimer, afkCheckThreadTimer;
Handle g_hStartTimer;
Handle g_hAfkHint[MAXPLAYERS + 1];	// 强制旁观后的提示定时器（原来句柄不保存，旁客观看期间永不回收）
StringMap g_hDeadSurvivors, g_hReplacedBots;
bool g_bSurvivorDied[MAXPLAYERS + 1];

public Plugin myinfo = 
{
	name = "[L4D2] VS Auto-spectate on AFK (12v12)",
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
	MarkNativeAsOptional("L4D2_FixTeamShuffle_IsFixComplete");
	return APLRes_Success;
}

public void OnAllPluginsLoaded()
{
	// 可选依赖：晚于本插件加载 / 卸载重载时在此同步
	g_bFixTeamShuffleLoaded = LibraryExists("l4d2_fix_team_shuffle_edi");
	g_bFixTeamShuffleRunning = false;
}

public void OnLibraryAdded(const char[] name)
{
	if (StrEqual(name, "l4d2_fix_team_shuffle_edi"))
		g_bFixTeamShuffleLoaded = true;
}

public void OnLibraryRemoved(const char[] name)
{
	if (StrEqual(name, "l4d2_fix_team_shuffle_edi"))
	{
		g_bFixTeamShuffleLoaded = false;
		g_bFixTeamShuffleRunning = false;
	}
}

// 队伍修正插件是否正处于锁队还原期间（未加载 = 否）
// 还原期间 jointeam 被拦截，旁观玩家无法自行补位，此时不应警告/踢出旁观闲置玩家
bool IsFixTeamShuffleRunning()
{
	if (!g_bFixTeamShuffleLoaded
		|| GetFeatureStatus(FeatureType_Native, "L4D2_FixTeamShuffle_IsFixComplete") != FeatureStatus_Available)
		return false;

	return !L4D2_FixTeamShuffle_IsFixComplete();
}

public void OnPluginStart()
{
	g_bFixTeamShuffleLoaded = LibraryExists("l4d2_fix_team_shuffle_edi");

	LoadTranslations("L4DVSAutoSpectateOnAFK_12v12.phrases");
	g_hDeadSurvivors = new StringMap();
	g_hReplacedBots = new StringMap();
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
	HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);
	HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);
	HookEvent("player_death", Event_PlayerDeathPost, EventHookMode_Post);
	HookEvent("bot_player_replace", Event_BotPlayerReplace);

	g_hAfkWarnSpecTime 		= CreateConVar("l4d_specafk_warnspectime", 			"10", "游戏中检测到闲置后多少秒出现警告提示", FCVAR_NOTIFY, true, 0.0);
	g_hAfkSpecTime 			= CreateConVar("l4d_specafk_spectime", 				"15", "警告后多少秒强制旁观", FCVAR_NOTIFY, true, 0.0);
	g_hAfkWarnKickTime	 	= CreateConVar("l4d_specafk_warnkicktime", 			"0", "旁观检测到闲置后多少秒出现警告提示", FCVAR_NOTIFY, true, 0.0);
	g_hAfkKickTime 			= CreateConVar("l4d_specafk_kicktime", 				"30", "旁观警告后多少秒踢出", FCVAR_NOTIFY, true, 0.0);
	g_hAfkCheckInterval = CreateConVar("l4d_specafk_checkinteral", "1", "检测/警告间隔（整数秒，最小 1 秒）", FCVAR_NOTIFY, true, 1.0, true, 60.0);
	// ConVars survive plugin reloads, including bounds from the legacy build.
	g_hAfkCheckInterval.SetBounds(ConVarBound_Lower, true, 1.0);
	g_hAfkCheckInterval.SetBounds(ConVarBound_Upper, true, 60.0);
	g_hAfkKickEnabled 		= CreateConVar("l4d_specafk_kickenabled", 			"1", "设为1时，当队伍有空位时，旁观状态下的AFK玩家将被踢出", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hAfkSaferoomIgnore 	= CreateConVar("l4d_specafk_saferoom_ignore", 		"0", "设为1时，无论幸存者是否离开安全屋，AFK玩家都会被强制旁观（不影响旁观踢出判定）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hAfkSafeRoomExitGrace = CreateConVar("l4d_specafk_saferoom_exit_grace", 	"5.0", "本回合第一个生还者离开安全区域后，仍处于闲置状态的玩家再等多少秒才被强制旁观（默认 5.0，精确到秒；0.0 = 离开安全区域后立即判定）", FCVAR_NOTIFY, true, 0.0);
	g_hImmuneAccess 		= CreateConVar("l4d_specafk_immune_access_flag", 	"-1", "拥有这些权限标志的玩家在旁观时不会被踢出（默认 -1 = 不按权限免疫，所有玩家都会被警告/踢出；填权限标志如 z = 拥有该标志的玩家免疫；留空 = 所有人免疫，会关闭旁观踢人功能）", FCVAR_NOTIFY);
	g_hSayResetTime 		= CreateConVar("l4d_specafk_say_reset", 			"1", "设为1时，玩家在聊天框发言将重置计时", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hSpecAfkMsgEnable 	= CreateConVar("l4d_specafk_join_hint_msg", 		"0", "设为1时，向AFK旁观者显示\"你正在旁观，加入任何队伍开始游戏\"的提示", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hAutoSpecSteamIds 	= CreateConVar("l4d_specafk_autospec_steamids", 	"76561198760610101", "符合条件的 SteamID64 玩家将自动被移动到旁观，且不会被本插件踢出（多个用逗号分隔）", FCVAR_NOTIFY);
	g_hImmuneSteamIds 		= CreateConVar("l4d_specafk_immune_steamids", 	"76561198760610101", "这些 SteamID 玩家在旁观时不会被本插件警告/踢出（多个用逗号分隔；支持 SteamID64 / STEAM_1:0:x / [U:1:x] 三种写法，可直接照抄 auth 日志；默认值与 l4d_specafk_autospec_steamids 相同）", FCVAR_NOTIFY);
	g_hImmuneIps 			= CreateConVar("l4d_specafk_immune_ips", 			"", "这些 IP（或 IP 前缀，如 192.168.1.）的玩家在旁观时不会被本插件警告/踢出（多个用逗号分隔；不使用 Steam 认证，用于 NoSteam 客户端兜底）", FCVAR_NOTIFY);
	g_hImmuneNames 		= CreateConVar("l4d_specafk_immune_names", 		"", "这些显示名在旁观时不会被本插件警告/踢出（多个用逗号分隔；默认空 = 关闭）。注意：显示名由玩家自行修改，任何人改成同名即可绕过踢出，仅在 SteamID/IP 都取不到时（如 NoSteam 客户端）才建议填写", FCVAR_NOTIFY);
	g_hIgnoreDeadSurvivorSlot = CreateConVar("l4d_specafk_ignore_dead_survivor_slot", "1", "1=生还者队里还有死亡生还者占着名额时，不把生还者侧算作可补位（默认）；0=沿用旧行为（只要 survivorHumans < survivor_limit 且有存活 AI Bot 就算可补位）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hKickNotify = CreateConVar("l4d_specafk_kick_notify", "0", "1=踢人时全服播报\"某人因旁观不补位被踢出\"；0=不播报（默认，只踢人不出提示）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
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
	g_hIgnoreDeadSurvivorSlot.AddChangeHook(ConVarChanged);

	if(g_bLate)
	{
		g_bRoundActive = true;
		QueueStart();
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
	if (afkCheckInterval < 1) afkCheckInterval = 1;
	afkSafeRoomExitGrace = g_hAfkSafeRoomExitGrace.FloatValue;
	afkKickEnabled = g_hAfkKickEnabled.BoolValue;
	bAfkSaferoomIgnore = g_hAfkSaferoomIgnore.BoolValue;

	g_hImmuneAccess.GetString(g_sAccesslvl,sizeof(g_sAccesslvl));

	g_bSayResetTime = g_hSayResetTime.BoolValue;
	g_bSpecAfkMsgEnable = g_hSpecAfkMsgEnable.BoolValue;
	g_bIgnoreDeadSurvivorSlot = g_hIgnoreDeadSurvivorSlot.BoolValue;

	g_hAutoSpecSteamIds.GetString(g_sAutoSpecSteamIds, sizeof(g_sAutoSpecSteamIds));
	g_hImmuneSteamIds.GetString(g_sImmuneSteamIds, sizeof(g_sImmuneSteamIds));
	g_hImmuneIps.GetString(g_sImmuneIps, sizeof(g_sImmuneIps));
	g_hImmuneNames.GetString(g_sImmuneNames, sizeof(g_sImmuneNames));
}

void ConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	int oldInterval = afkCheckInterval;
	ReadCvars();
	if (afkCheckThreadTimer != null && oldInterval != afkCheckInterval)
	{
		delete afkCheckThreadTimer;
		afkCheckThreadTimer = CreateTimer(float(afkCheckInterval), afkCheckThread, _, TIMER_REPEAT);
	}
}

// 清除"离开安全区域最后行动宽限"相关状态
void ResetSafeRoomExitState(int client)
{
	afkPlayerPendingSafeRoomExit[client] = false;
	afkPlayerSafeRoomExitGrace[client] = -1;
}

// 记录"本回合第一个生还者已经离开安全区域"，并开始计算强制旁观的延迟闸门。
// 两个触发源调用它，谁先到算谁：
//   1) left4dhooks 的 L4D_OnFirstSurvivorLeftSafeArea_Post（正常情况，离开的瞬间就记录，没有轮询延迟）
//   2) PlayerLeftStart 每秒轮询 L4D_HasAnySurvivorLeftSafeArea()（兜底：forward 被别的插件拦截、
//      或 left4dhooks 版本不支持该 forward 时仍能工作）
void MarkSafeRoomExited()
{
	if (g_bLeftSafeRoom)
		return;

	g_bLeftSafeRoom = true;
	g_fSafeRoomExitTime = GetGameTime();
}

// 距离"允许把闲置玩家转到旁观"还剩多少秒：
//   -1.0 = 本回合还没有生还者离开安全区域（无限等待，不做强制旁观）
//   >0.0 = 还要再等这么多秒
//    0.0 = 延迟已满足，可以立刻强制旁观
float GetSafeRoomExitDelayRemain()
{
	if (!g_bLeftSafeRoom)
		return -1.0;

	// 有离开记录但没有起算时刻（理论上不会发生）：按"延迟已满足"处理，保持旧行为
	if (g_fSafeRoomExitTime < 0.0)
		return 0.0;

	// 时钟回退（换图/回合重置本该清掉起算时刻，这里是兜底）：按"延迟已满足"处理，
	// 否则会算出一个巨大的剩余秒数，玩家反而永远等不到强制旁观
	float fElapsed = GetGameTime() - g_fSafeRoomExitTime;
	if (fElapsed < 0.0)
		return 0.0;

	float fRemain = afkSafeRoomExitGrace - fElapsed;
	return fRemain > 0.0 ? fRemain : 0.0;
}

public void OnMapEnd()
{
	ResetPlugin();
	ResetTimer();
	g_hDeadSurvivors.Clear();
	g_hReplacedBots.Clear();
}

public void OnClientPutInServer(int client)
{
	g_bSurvivorDied[client] = false;
	// 新连线玩家：聊天框同步节流从零开始（否则会继承上一个占用这个槽位的玩家的时间戳）
	g_fLastChatWarn[client] = 0.0;
	g_fLastChatJoinHint[client] = 0.0;
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
	if (!L4D_IsVersusMode() || IsFixTeamShuffleRunning()) return;
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

// Match SuperVersus ownership: a dead body still reserves its idle human's seat.
int GetIdleOwner(int bot)
{
	if (!IsClientInGame(bot) || !IsFakeClient(bot) || GetClientTeam(bot) != 2
		|| !HasEntProp(bot, Prop_Send, "m_humanSpectatorUserID"))
		return 0;
	int owner = GetClientOfUserId(GetEntProp(bot, Prop_Send, "m_humanSpectatorUserID"));
	return owner > 0 && IsClientInGame(owner) && !IsFakeClient(owner) && GetClientTeam(owner) == 1 ? owner : 0;
}

void SetSurvivorDeath(int client, bool died)
{
	g_bSurvivorDied[client] = died;
	char auth[MAX_AUTHID_LENGTH];
	if (GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth)))
	{
		if (died) g_hDeadSurvivors.SetValue(auth, true);
		else g_hDeadSurvivors.Remove(auth);
	}
}

bool HasSurvivorDied(int client)
{
	char auth[MAX_AUTHID_LENGTH];
	int died;
	return g_bSurvivorDied[client] || (GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth))
		&& g_hDeadSurvivors.GetValue(auth, died) && died != 0);
}

void Event_BotPlayerReplace(Event event, const char[] name, bool dontBroadcast)
{
	int player = GetClientOfUserId(event.GetInt("player"));
	if (player <= 0 || !IsClientInGame(player) || IsFakeClient(player)) return;
	char key[16];
	IntToString(event.GetInt("bot"), key, sizeof(key));
	g_hReplacedBots.SetValue(key, event.GetInt("player"));
	if (GetClientTeam(player) == 2) SetSurvivorDeath(player, !IsPlayerAlive(player));
}

void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	int owner;
	if (client > 0 && IsClientInGame(client) && GetClientTeam(client) == 2)
		owner = IsFakeClient(client) ? GetIdleOwner(client) : client;
	// SuperVersus may already have taken over and removed the dying bot in its pre-hook.
	char key[16];
	int ownerUserId;
	IntToString(event.GetInt("userid"), key, sizeof(key));
	if (owner == 0 && g_hReplacedBots.GetValue(key, ownerUserId))
		owner = GetClientOfUserId(ownerUserId);
	if (owner > 0 && IsClientInGame(owner)) SetSurvivorDeath(owner, true);
}

void Event_PlayerDeathPost(Event event, const char[] name, bool dontBroadcast)
{
	Event_PlayerDeath(event, name, dontBroadcast);
	char key[16];
	IntToString(event.GetInt("userid"), key, sizeof(key));
	g_hReplacedBots.Remove(key);
}

int GetJoinLimit(const char[] pluginCvar, const char[] engineCvar)
{
	ConVar pluginLimit = FindConVar(pluginCvar);
	ConVar engineLimit = FindConVar(engineCvar);
	if (pluginLimit == null || engineLimit == null) return 0;
	int limit = pluginLimit.IntValue;
	return limit < engineLimit.IntValue ? limit : engineLimit.IntValue;
}

bool CanClientFillTeam(int client)
{
	if (!L4D_IsVersusMode() || GetClientTeam(client) != 1 || !IsClientAuthorized(client)
		|| IsClientInKickQueue(client) || IsFixTeamShuffleRunning())
		return false;
	ConVar management = FindConVar("l4d_management");
	if (management == null || !management.BoolValue || GetCommandFlags("sm_join") == INVALID_FCVAR_FLAGS)
		return false;

	int survivorLimit = GetJoinLimit("l4d_survivor_limit", "survivor_limit");
	int infectedLimit = GetJoinLimit("l4d_infected_limit", "z_max_player_zombies");
	int survivorHumans, infectedHumans, infectedBodies, removableInfected;
	int deadSurvivorSeats;	// 生还者队里"已死亡但仍占着名额"的人数（真人 / AI Bot / 挂机托管身体统一计入）
	bool freeLivingBot, ownsBody;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i)) continue;
		int team = GetClientTeam(i);
		if (team == 2)
		{
			// 死亡的身体同样占着生还者名额，不能当成"可以补位"的空位
			if (!IsPlayerAlive(i)) deadSurvivorSeats++;

			if (!IsFakeClient(i)) survivorHumans++;
			else
			{
				int owner = GetIdleOwner(i);
				if (owner > 0)
				{
					survivorHumans++;
					if (owner == client) ownsBody = true;
				}
				else if (IsPlayerAlive(i) && !IsClientInKickQueue(i)) freeLivingBot = true;
			}
		}
		else if (team == 3)
		{
			infectedBodies++;
			if (!IsFakeClient(i)) infectedHumans++;
			else if (!IsClientInKickQueue(i))
			{
				int zclass = GetEntProp(i, Prop_Send, "m_zombieClass");
				if (zclass >= 1 && zclass <= 6) removableInfected++;
			}
		}
	}
	// An idle owner already occupies a survivor seat, rather than an unfilled spectator seat.
	if (ownsBody) return false;
	if (infectedHumans < infectedLimit && infectedBodies - removableInfected < infectedLimit)
		return true;
	/* 生还者侧可补位必须同时满足：名额没满、有存活 AI Bot 可接管、这名旁观者本局没死过，
	   并且**生还者队里没有任何死亡生还者还躺着占位**。
	   最后一条默认开启：有人躺着时那几个席位要等下一回合复活，此时把活着的人拉进来就是超额，
	   所以不能算作"有空位可补位"，也就不该据此警告/踢出旁观玩家。 */
	return survivorHumans < survivorLimit && freeLivingBot && !HasSurvivorDied(client)
		&& (!g_bIgnoreDeadSurvivorSlot || deadSurvivorSeats == 0);
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
	ResetTimer();
	g_bRoundActive = true;
	g_bLeftSafeRoom = false;
	g_fSafeRoomExitTime = -1.0;	// 新回合重新起算"离开安全区域"计时
	g_hDeadSurvivors.Clear();
	g_hReplacedBots.Clear();
	for (int i = 1; i <= MaxClients; i++) g_bSurvivorDied[i] = false;
	QueueStart();
}

void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client > 0 && IsClientInGame(client))
	{
		if (!IsFakeClient(client) && GetClientTeam(client) == 2)
			SetSurvivorDeath(client, !IsPlayerAlive(client));
		else if (GetIdleOwner(client) > 0)
			SetSurvivorDeath(GetIdleOwner(client), !IsPlayerAlive(client));
		ForceAutoSpec(client);
	}
}

void QueueStart()
{
	if (g_hStartTimer == null)
		g_hStartTimer = CreateTimer(3.0, tmrStart, _, TIMER_FLAG_NO_MAPCHANGE);
}

Action tmrStart(Handle timer)
{
	if (timer != g_hStartTimer) return Plugin_Stop;
	g_hStartTimer = null;
	if (!g_bRoundActive || !L4D_IsVersusMode()) return Plugin_Stop;
	g_bLeftSafeRoom = L4D_HasAnySurvivorLeftSafeArea();
	// 晚加载 / 回合中途接管：已经有生还者离开安全区域时，以"现在"作为延迟的起算点
	//（真实的离开时刻已经过去，玩家最多也只该等满这个延迟，不能因为插件接管就被立刻转旁观）；
	// 如果 forward 已经记下了真实的离开时刻，则保留它，不被这次轮询覆盖。
	if (g_bLeftSafeRoom) MarkSafeRoomExited();
	else g_fSafeRoomExitTime = -1.0;

	for (int client=1;client<=MaxClients;client++)
	{
		ResetSafeRoomExitState(client);
		// 新回合：聊天框同步节流清零，保证第一次提示能进聊天框
		g_fLastChatWarn[client] = 0.0;
		g_fLastChatJoinHint[client] = 0.0;
		if (IsClientInGame(client) && GetClientTeam(client) == 2)
		{
			int owner = IsFakeClient(client) ? GetIdleOwner(client) : client;
			if (owner > 0) SetSurvivorDeath(owner, !IsPlayerAlive(client));
		}

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
	if(!g_bSpecAfkMsgEnable)
	{
		ClearAfkHintTimer(Timer);
		return Plugin_Stop;
	}

	if (!g_bRoundActive || IsFixTeamShuffleRunning()) return Plugin_Continue;

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
			// 聊天框同步：这条提示每 5 秒循环一次，聊天框按 AFK_JOIN_HINT_CHAT_INTERVAL 节流后才输出，
			// 否则旁观期间聊天框会被同一句话刷屏（只发给该玩家本人）
			if (ChatMirrorAllowed(g_fLastChatJoinHint[client], AFK_JOIN_HINT_CHAT_INTERVAL))
				CPrintToChat(client, "%T", "You're spectating. Join any team to play.", client);
			
			return Plugin_Continue;
		}
	}

	ClearAfkHintTimer(Timer);
	return Plugin_Stop;
}

// 定时器自毁时把数组里对应的句柄清空，避免留下失效句柄（也供 ResetTimer/换边时复用）
void ClearAfkHintTimer (Handle Timer)
{
	if (Timer == null)
	{
		return;
	}

	for (int i = 1; i <= MaxClients; i++)
	{
		if (g_hAfkHint[i] == Timer)
		{
			g_hAfkHint[i] = null;
		}
	}
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

		// 已经进队：把"你还在旁观"的重复提示停掉
		delete g_hAfkHint[client];
		g_hAfkHint[client] = null;
	}
	else // if player is on spectators
	{
		afkPlayerTimeLeftWarn[client] = afkWarnKickTime;
		afkPlayerTimeLeftAction[client] = afkKickTime;
	}
	
	GetClientAbsOrigin(client, afkPlayerLastPos[client]);
	GetClientEyeAngles(client, afkPlayerLastEyes[client]);

	// 玩家已行动：倒计时会重新开始，聊天框同步也重新从"立刻可输出"起算
	g_fLastChatWarn[client] = 0.0;
}

// 聊天框同步的节流判断：同一玩家同一类提示，聊天框最多每 fInterval 秒输出一次。
// 中央 Hint 每秒刷新不影响观感，聊天框每秒复制同一句话就是刷屏，所以秒级提示在聊天框要节流。
bool ChatMirrorAllowed(float &fLastTime, float fInterval)
{
	float fNow = GetGameTime();
	if (fLastTime > 0.0 && fNow - fLastTime < fInterval)
		return false;

	fLastTime = fNow;
	return true;
}

// 把一条"只走过 PrintHintText"的翻译提示原样再输出到聊天框（目标人群由调用方决定，
// 单播就用 CPrintToChat 发给该玩家，全服播报就用 CPrintToChatAll，保持与中央 Hint 一致）。
// 内容与原 Hint 完全同源（同一个 phrase），只是把翻译里可能带的换行折叠成空格，
// 避免聊天框里被换行截成两截。颜色标签交由 multicolors 处理。
void AFKChatMirror(int client, const char[] phrase, int seconds, bool bHasSeconds)
{
	if (client <= 0 || client > MaxClients || !IsClientInGame(client))
		return;

	char sBuffer[256];
	SetGlobalTransTarget(client);
	if (bHasSeconds)
		Format(sBuffer, sizeof(sBuffer), "%T", phrase, client, seconds);
	else
		Format(sBuffer, sizeof(sBuffer), "%T", phrase, client);

	ReplaceString(sBuffer, sizeof(sBuffer), "\n", " ");
	CPrintToChat(client, "%s", sBuffer);
}

void AFKPlayBlipSound(int client)
{
	// 生还者还没离开过安全区域：只出文字、不出声。
	// 开局准备阶段/还在安全屋里时闲置检测与补位提示会反复触发，一直响很吵；
	// 一旦有生还者离开安全区域，提示音恢复成原来的行为。
	if (!g_bLeftSafeRoom)
		return;

	if (client > 0 && client <= MaxClients && IsClientInGame(client))
		EmitSoundToClient(client, AFK_BLIP_SOUND);
}

void AFKCountdownWarn(int client, const char[] phrase, int seconds)
{
	// 倒计时提示：Hint 文本 + 提示音
	PrintHintText(client, "%T", phrase, client, seconds);
	// 聊天框同步：这类倒计时是按检测间隔（默认每秒）刷新的，若聊天框也逐秒输出就是刷屏，
	// 因此按 AFK_COUNTDOWN_CHAT_INTERVAL 节流；只发给被倒计时的这个玩家，不打扰其他人
	if (ChatMirrorAllowed(g_fLastChatWarn[client], AFK_COUNTDOWN_CHAT_INTERVAL))
		AFKChatMirror(client, phrase, seconds, true);
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

	// 补位检测跳过：幸存者未离开安全区域且有玩家正在连接中时，不检测/踢出旁观AFK（连接中的玩家即将补位）
	bool bSkipFillDetection = !g_bLeftSafeRoom && IsPlayerConnecting();
	// 队伍修正插件正在锁队还原队伍时不检测/踢出旁观AFK：此时 jointeam 被拦截，旁观玩家无法自行补位
	g_bFixTeamShuffleRunning = IsFixTeamShuffleRunning();

	float pos[3];
	float eyes[3];
	bool isAFK;
	// we check all connected (and alive) clients ...
	for (int i=1;i<=MaxClients;i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
		{
			// 还原期间不强制旁观、不踢人；解锁后给予完整倒计时。
			if (!g_bRoundActive || !L4D_IsVersusMode() || g_bFixTeamShuffleRunning || GetClientTeam(i) == 0)
			{
				afkResetTimers(i);
				continue;
			}
			if (IsAutoSpecPlayer(i))
			{
				ForceAutoSpec(i);
				afkResetTimers(i);
				continue;
			}
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
								// 离开安全区域前就被判定闲置、倒计时已经走完的玩家：本回合有人离开安全区域后，
								// 还要再等满 l4d_specafk_saferoom_exit_grace 秒（默认 5 秒），期间每秒提示，
								// 仍不行动才强制旁观。等待期间玩家一有行动就会走 afkResetTimers 清掉待旁观状态。
								if (afkPlayerPendingSafeRoomExit[i] && g_bLeftSafeRoom && !bAfkSaferoomIgnore)
								{
									// 距离可以强制旁观还剩多少秒：以"第一个离开安全区域的生还者"那一瞬间起算，
									// 不再靠每次检测减秒数，避免 l4d_specafk_checkinteral 把 5 秒拖成 6~8 秒
									float fRemain = GetSafeRoomExitDelayRemain();
									if (fRemain > 0.0)
									{
										// 离开安全区域后每秒提示剩余行动时间
										afkPlayerSafeRoomExitGrace[i] = RoundToCeil(fRemain);
										AFKCountdownWarn(i, "[AFK] Inactivity detected! 6", afkPlayerSafeRoomExitGrace[i]);
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
										// 设了 l4d_specafk_saferoom_ignore 1 时保持旧语义：不看安全区域，直接强制旁观
										if (bAfkSaferoomIgnore)
										{
											afkForceSpectate(i, true);
										}
										// 已经有人离开安全区域，但距离"离开安全区域 + 延迟秒数"还差一点：
										// 同样记为待旁观，交给上面的宽限分支按剩余秒数提示，绝不在这个窗口内转旁观。
										// 这一条覆盖了玩家在安全屋内就已开始倒计时、倒计时还没走完人就已经离开的情况。
										else if (GetSafeRoomExitDelayRemain() > 0.0)
										{
											afkPlayerPendingSafeRoomExit[i] = true;
										}
										// If players leaved safe room we force him to spectate
										else if (g_bLeftSafeRoom)
										{
											afkForceSpectate(i, true);
										}
										else // if players haven't leaved safe room ... we warn this player that he will be forced to spectate as soon as a player leaves
										{
											// 记住：该玩家在安全屋内就被判定闲置，离开安全区域后还有最后宽限时间
											afkPlayerPendingSafeRoomExit[i] = true;

											// 提示里的秒数取自 l4d_specafk_saferoom_exit_grace；
											// 该 cvar 为 0 时没有宽限（离开安全区域即强制旁观），改用无秒数的提示
											if (afkSafeRoomExitGrace > 0.0)
											{
												PrintHintText(i, "%T", "[AFK] Inactivity detected! 2", i, RoundToNearest(afkSafeRoomExitGrace));
												// 同一提示同步进聊天框（只发给该玩家，不打扰其他人）
												AFKChatMirror(i, "[AFK] Inactivity detected! 2", RoundToNearest(afkSafeRoomExitGrace), true);
											}
											else
											{
												PrintHintText(i, "%T", "[AFK] Inactivity detected! 7", i);
												// 同一提示同步进聊天框（只发给该玩家，不打扰其他人）
												AFKChatMirror(i, "[AFK] Inactivity detected! 7", 0, false);
											}
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
			// 旁观检测：仅在对抗双方队伍有空位、不处于"未离开安全区域+有人连接中"、
		// 且队伍修正插件没有正在锁队还原时才触发（生还者有AI机器人 / 感染者有空位）
			else if (afkKickEnabled && !bSkipFillDetection && CanClientFillTeam(i))
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
			else
			{
				// 空位消失或此人无法补位时重新计时，不能恢复后立即踢出。
				afkResetTimers(i);
			}
		} // player is connected and in-game
	}
	
	// We continue with the timer
	return Plugin_Continue;
}


// 单播中央 Hint。注意：它唯一被调用的地方（afkForceSpectate）已经先做过一次同语义的
// CPrintToChat，聊天框的双通道已经存在，这里不再重复镜像，避免同一句话在聊天框出现两次。
void AFKPrintHint(int client, const char[] phrase)
{
	char sBuffer[256];
	SetGlobalTransTarget(client);
	Format(sBuffer, sizeof(sBuffer), "%T", phrase, client);
	CRemoveTags(sBuffer, sizeof(sBuffer));
	PrintHintText(client, "%s", sBuffer);
}

// 全服中央 Hint。同上：调用点 afkForceSpectate 已经用 CPrintToChatAll 输出过同一句，
// 因此这里不重复镜像，避免刷屏。
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
	if (!g_bRoundActive || IsFixTeamShuffleRunning()) return;
	// 已强制旁观：清掉待旁观与离开安全区域宽限状态，避免状态残留
	ResetSafeRoomExitState(client);

	// We force him to spectate
	ChangeClientTeam(client, 1);
	
	// We send him a hint message 5 seconds later, in case he hasn't joined any team
	// 先杀掉上一个提示定时器再建，避免同一客户端叠出多个常驻重复定时器
	delete g_hAfkHint[client];
	g_hAfkHint[client] = CreateTimer(5.0, afkJoinHint, GetClientUserId(client), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	
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
	if (IsFakeClient(client) || !CanClientFillTeam(client))
		return;
	
	// 踢出原因按被踢玩家的语言显示（KickClient 会以该玩家为翻译目标格式化）
	KickClient(client, "%T", "kickplayer", client, afkKickTime);
	
	// Print forced info
	// 播报开关：l4d_specafk_kick_notify 默认 0 = 不播报（只踢人，不再刷"某某因旁观不补位被踢出"）
	if (g_hKickNotify != null && g_hKickNotify.BoolValue)
	{
		char sName[MAX_NAME_LENGTH];
		GetClientName(client, sName, sizeof(sName));
		CPrintToChatAll("%t", "have been kicked from server due to inactivity", sName, afkKickTime);
	}
}

// 本回合第一个生还者离开安全区域的瞬间（left4dhooks 前挂钩，精度高于每秒轮询）
public void L4D_OnFirstSurvivorLeftSafeArea_Post(int client)
{
	MarkSafeRoomExited();
}

Action PlayerLeftStart(Handle Timer)
{
	if (L4D_HasAnySurvivorLeftSafeArea())
	{
		// 兼容旧路径：轮询发现已有人离开安全区域时，记下起算时刻（forward 没触发时的兜底）
		MarkSafeRoomExited();
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
	g_bRoundActive = false;
	g_bLeftSafeRoom = false;
	// 回合结束 / 换图：清掉"离开安全区域"起算时刻，避免下一回合沿用上一回合的时间导致延迟被跳过
	g_fSafeRoomExitTime = -1.0;
}

void ResetTimer()
{
	delete g_hStartTimer;
	delete PlayerLeftStartTimer;
	delete afkCheckThreadTimer;

	for (int i = 1; i <= MaxClients; i++)
	{
		delete g_hAfkHint[i];
		g_hAfkHint[i] = null;
	}
}
