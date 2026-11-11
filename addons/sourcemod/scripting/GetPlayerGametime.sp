#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <SteamWorks>
#include <left4dhooks>
#include <colors>

#define APPID_L4D2			 550
#define STATS_PLAYTIME_KEY	 "Stat.TotalPlayTime.Total"
#define SECONDS_PER_HOUR	 3600
#define SECONDS_PER_MINUTE	 60

// Steam Web API: 玩家主页(Steam 个人资料)游戏时长
#define PROFILE_GAMETIME_URL "http://api.steampowered.com/IPlayerService/GetOwnedGames/v0001/?format=json&appids_filter[0]=550"

/*
 * 变更记录
 * 1.6.1 (2026-11-11)
 *   修复: 时长限制在"双数据源"下实际只按一路判定。
 *         旧实现把两路结果汇总进 i_PlayerTime(成就统计优先), 而 LimitPlayer/CheckPlayerGametime
 *         只看 i_PlayerTime 这一个值, 所以两路都开启时主页时长命中也拦不住;
 *         两路都开启、其中一路先失败时, 判定还会一直挂着不收敛。
 *         现在 i_ProfileTime / i_StatTime 分别保存两路时长, 限制判定改为联合判定:
 *         任意一路落在 (LimitPlayerMinGametime, LimitPlayerMaxGametime) 区间内就限制;
 *         先到的那一路命中就立即限制(不等另一路), 未命中则等另一路到了再判一次,
 *         每个连接只执行一次限制动作(b_LimitHandled), 不重复踢/不重复转旁观。
 *   修复: 调试输出改由 GetPlayerGametimeDebug(默认 0)控制, 且只写服务器控制台, 不再刷全体玩家聊天。
 *   新增: 时长查询看门狗, 某一路卡住(HTTP 无回调等)时到点按获取失败收尾, 保证判定一定收敛。
 */

public Plugin myinfo =
{
	name		= "get player gametime",
	author		= "apples1949 , 豆瓣酱な , deepseek",
	description = "",
	version		= "1.6.1",
	url			= "https://github.com/apples1949",
};

// 查询的数据源
enum
{
	QUERY_PROFILE = (1 << 0),	// 1: Steam 玩家主页时长
	QUERY_STATS	  = (1 << 1),	// 2: 成就统计时长
}

// 单个数据源的状态
enum
{
	SOURCE_PENDING = 0,	// 仍在请求/重试
	SOURCE_OK,			// 已取到数据
	SOURCE_FAILED,		// 达到最大请求次数仍然失败
}

int	   i_Count[MAXPLAYERS + 1];
int	   i_ProfileCount[MAXPLAYERS + 1];
int	   i_StatsUserID[MAXPLAYERS + 1];
int	   i_ProfileUserID[MAXPLAYERS + 1];
int	   i_PlayerTime[MAXPLAYERS + 1];
int	   i_StatTime[MAXPLAYERS + 1];
int	   i_ProfileTime[MAXPLAYERS + 1];
int	   i_StatState[MAXPLAYERS + 1];
int	   i_ProfileState[MAXPLAYERS + 1];
bool   b_Announced[MAXPLAYERS + 1];
bool   b_IsProcessingLimitPlayer[MAXPLAYERS + 1];
bool   CheckPluginLate = false;
bool   b_SteamWorksAvailable = false;
bool   b_StatsSourceEnabled = false;
bool   b_ProfileSourceEnabled = false;
bool   b_WarnedNoSource = false;
bool   b_WarnedNoKey = false;
bool   b_ConfigsExecuted = false;
bool   b_SteamCheck;
bool   b_ClientAuthorized[MAXPLAYERS + 1];	// 已经过 OnClientAuthorized(SteamID 验证成功)
bool   b_ClientPostAdminCheck[MAXPLAYERS + 1];	// 已经过 OnClientPostAdminCheck
// 本连接是否已经执行过"因时长而限制"(踢出/转旁观): 防止管理员把玩家转回生还者后又被反复处理
bool   b_LimitHandled[MAXPLAYERS + 1];
// 本连接是否已经向全服播报过"正在获取时长"/"获取失败"提示: 防止每次重试都刷屏
bool   b_RequestNotified[MAXPLAYERS + 1];
bool   b_FailureNotified[MAXPLAYERS + 1];
int	   i_LastSourceState = 0;
int	   i_ShowGametimeMode;
int	   i_CheckPlayerGameCount;
int	   i_CheckPlayerProfileCount;
int	   i_QueryMode;
int	   b_LimitPlayer;
int	   i_LimitPlayerMinGametime;
int	   i_LimitPlayerMaxGametime;
int	   i_LimitPlayerMode;
bool   b_Enable;
bool   b_ShowPlayerLerp;
bool   b_LPWRequesting;
bool   b_LPLateload;
int	   i_LPMWFailureGet;
bool   b_SPLMode;
bool   b_IfNeedLogKickMsg;
bool   b_Debug;					// 调试输出开关(GetPlayerGametimeDebug, 默认关闭)
bool   hasTranslations;
ConVar c_ShowGametimeMode;
ConVar c_CheckPlayerGameCount;
ConVar c_LimitPlayer;
ConVar c_LimitPlayerMinGametime;
ConVar c_LimitPlayerMaxGametime;
ConVar c_LimitPlayerMode;
ConVar c_Enable;
ConVar c_ShowPlayerLerp;
ConVar c_LPWRequesting;
ConVar c_LPLateload;
ConVar c_LPMWFailureGet;
ConVar c_SPLMode;
ConVar c_IfNeedLogKickMsg;
ConVar c_QueryMode;
ConVar c_CheckPlayerProfileCount;
ConVar c_SteamCheck;
ConVar c_APIKey;
ConVar c_Debug;

char   chatFile[128];
char   s_APIKey[128];

ConVar
	g_cvMinUpdateRate  = null,
	g_cvMaxUpdateRate  = null,
	g_cvMinInterpRatio = null,
	g_cvMaxInterpRatio = null;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	CheckPluginLate = late;
	RegPluginLibrary("GetPlayerGametime");

	// 供其他插件调用的公共接口 (配合 include/GetPlayerGametime.inc)
	CreateNative("GetPlayerGametime_GetTime", Native_GetPlayerGametime_GetTime);
	CreateNative("GetPlayerGametime_GetLerp", Native_GetPlayerGametime_GetLerp);
	CreateNative("GetPlayerGametime_GetProfileTime", Native_GetPlayerGametime_GetProfileTime);
	CreateNative("GetPlayerGametime_GetStatTime", Native_GetPlayerGametime_GetStatTime);
	CreateNative("GetPlayerGametime_GetSource", Native_GetPlayerGametime_GetSource);

	return APLRes_Success;
}

public void OnClientDisconnect(int client)
{
	if (client > 0 && client <= MaxClients)
	{
		b_ClientAuthorized[client]	   = false;
		b_ClientPostAdminCheck[client] = false;
		// 断线清理限制状态: 否则索引复用给下一个玩家时会带着"已限制过/已提示过"的残留标记
		b_LimitHandled[client]	= false;
		b_RequestNotified[client] = false;
		b_FailureNotified[client] = false;
		i_StatTime[client]		= 0;
		i_ProfileTime[client]	= 0;
		i_PlayerTime[client]	= 0;
		i_StatState[client]		= SOURCE_PENDING;
		i_ProfileState[client]	= SOURCE_PENDING;
		i_StatsUserID[client]	= 0;
		i_ProfileUserID[client] = 0;
		b_Announced[client]		= false;
	}
}

// 返回玩家的游戏时长(秒), <=0 表示未获取到/未知
any Native_GetPlayerGametime_GetTime(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients)
		return 0;
	if (!IsClientSteamVerified(client))
		return 0;
	return i_PlayerTime[client];
}

// 返回玩家的 Lerp 值(秒, 如 0.0156), readyup-applemod 会将其转换为毫秒显示
any Native_GetPlayerGametime_GetLerp(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
		return 0.0;
	return GetPlayerLerp(client);
}

// 返回玩家的主页(Steam 个人资料)游戏时长(秒), <=0 表示未获取到/未知
any Native_GetPlayerGametime_GetProfileTime(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients)
		return 0;
	if (!IsClientSteamVerified(client))
		return 0;
	return i_ProfileTime[client];
}

// 返回玩家的成就统计游戏时长(秒), <=0 表示未获取到/未知
any Native_GetPlayerGametime_GetStatTime(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients)
		return 0;
	if (!IsClientSteamVerified(client))
		return 0;
	return i_StatTime[client];
}

// 返回 GetPlayerGametime_GetTime 当前采用的时长来源: 0=无数据, 1=主页时长, 2=成就统计时长
any Native_GetPlayerGametime_GetSource(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients)
		return 0;
	if (!IsClientSteamVerified(client))
		return 0;
	if (i_StatTime[client] > 0) return 2;
	if (i_ProfileTime[client] > 0) return 1;
	return 0;
}

public void OnPluginStart()
{
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, PLATFORM_MAX_PATH, "translations/GetPlayerGametime.phrases.txt");
	hasTranslations = FileExists(path);
	if (hasTranslations) LoadTranslations("GetPlayerGametime.phrases");
	else LogError("Not translations file GetPlayerGametime.phrases.txt found yet!");

	b_SteamWorksAvailable = (GetExtensionFileStatus("SteamWorks.ext") == 1);
	if (!b_SteamWorksAvailable)
	{
		LogError("SteamWorks isn't installed or failed to load. Player gametime query is disabled. Please install SteamWorks. (https://forums.alliedmods.net/showthread.php?t=229556)");
	}

	c_Enable				 = CreateConVar("GetPlayerGametimeEnable", "1", "启用插件？0:禁用", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	c_ShowGametimeMode		 = CreateConVar("ShowGametimeMode", "2", "向玩家显示什么类型的游戏时长？1:小时和分钟 2=四舍五入到两位小数的小时", FCVAR_NOTIFY, true, 1.0, true, 2.0);
	c_CheckPlayerGameCount	 = CreateConVar("CheckPlayerGameCount", "8", "如果由于任何可能的原因未能获取到玩家的成就统计时长，应重复多少次以获取玩家的成就统计时长？0=禁用成就统计时长查询", FCVAR_NOTIFY, true, 0.0);
	c_LPWRequesting			 = CreateConVar("LPWRequesting", "0", "正在反复获取玩家的游戏时长时，是否将玩家移动到旁观？0:禁用", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	c_LPMWFailureGet		 = CreateConVar("LPMWFailureGet", "0", "反复获取玩家游戏时长失败时如何处理玩家？0:禁用，1:踢出 2=移动到旁观", FCVAR_NOTIFY, true, 0.0, true, 2.0);
	c_LPLateload			 = CreateConVar("LPLateload", "1", "如果 LimitPlayer=1 且插件未正常启动，是否取消各种因游戏时长而限制玩家的插件行为？0:禁用 1:启用", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	c_LimitPlayer			 = CreateConVar("LimitPlayer", "0", "是否禁止符合游戏时长条件的玩家进入服务器或进入游戏？0:禁用 1:启用", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	c_LimitPlayerMinGametime = CreateConVar("LimitPlayerMinGametime", "0", "符合游戏时长条件的玩家进入服务器或进入游戏的最低禁止时长(单位:小时)", FCVAR_NOTIFY, true, 0.0);
	c_LimitPlayerMaxGametime = CreateConVar("LimitPlayerMaxGametime", "10", "符合游戏时长条件的玩家进入服务器或进入游戏的最高禁止时长(单位:小时)", FCVAR_NOTIFY, true, 1.0);
	c_LimitPlayerMode		 = CreateConVar("LimitPlayerMode", "2", "如果 LimitPlayer 不为 0，如何处理符合条件的玩家？1:踢出，2=移动到旁观", FCVAR_NOTIFY, true, 1.0, true, 2.0);
	c_ShowPlayerLerp		 = CreateConVar("ShowPlayerLerp", "1", "显示玩家 Lerp 及游戏时长？0:禁用 1:启用", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	c_SPLMode				 = CreateConVar("SPLMode", "1", "是否按玩家队伍显示玩家游戏时长和 Lerp 信息 0:按玩家顺序输出", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	c_IfNeedLogKickMsg		 = CreateConVar("IfNeedLogKickMsg", "1", "是否记录自动踢出玩家的消息？0:禁用", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	c_QueryMode				 = CreateConVar("QueryGametimeMode", "3", "查询哪些来源的玩家游戏时长？1=玩家主页 2=成就统计 3=两者都查询", FCVAR_NOTIFY, true, 1.0, true, 3.0);
	c_CheckPlayerProfileCount = CreateConVar("CheckPlayerProfileCount", "3", "查询玩家主页游戏时长的次数？0=禁用玩家主页查询", FCVAR_NOTIFY, true, 0.0);
	c_SteamCheck				 = CreateConVar("GetPlayerGametimeSteamCheck", "1", "开启后检测玩家 SteamID 是否验证成功：必须经过 OnClientAuthorized 和 OnClientPostAdminCheck 两个验证流程，否则不返回获取的玩家游戏时长。0:禁用 1:启用", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	c_APIKey				 = CreateConVar("GetPlayerGametimeAPIKey", "", "Steam Web API Key(查询玩家主页游戏时长用)，留空则禁用玩家主页查询，申请: https://steamcommunity.com/dev/apikey", FCVAR_NOTIFY);

	// 调试输出开关: 只写服务器控制台, 不进玩家聊天; 默认关闭(以前是 #if DEBUG 编译期硬编码刷全体聊天)
	c_Debug					 = CreateConVar("GetPlayerGametimeDebug", "0", "调试模式: 是否在服务器控制台打印时长查询与限制判定的内部信息? 0:禁用 1:启用", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvMinUpdateRate		 = FindConVar("sv_minupdaterate");
	g_cvMaxUpdateRate		 = FindConVar("sv_maxupdaterate");
	g_cvMinInterpRatio		 = FindConVar("sv_client_min_interp_ratio");
	g_cvMaxInterpRatio		 = FindConVar("sv_client_max_interp_ratio");

	GetCvars();
	c_Enable.AddChangeHook(ConVarChanged);
	c_ShowGametimeMode.AddChangeHook(ConVarChanged);
	c_CheckPlayerGameCount.AddChangeHook(ConVarChanged);
	c_LPWRequesting.AddChangeHook(ConVarChanged);
	c_LPMWFailureGet.AddChangeHook(ConVarChanged);
	c_LPLateload.AddChangeHook(ConVarChanged);
	c_LimitPlayer.AddChangeHook(ConVarChanged);
	c_LimitPlayerMinGametime.AddChangeHook(ConVarChanged);
	c_LimitPlayerMaxGametime.AddChangeHook(ConVarChanged);
	c_LimitPlayerMode.AddChangeHook(ConVarChanged);
	c_ShowPlayerLerp.AddChangeHook(ConVarChanged);
	c_SPLMode.AddChangeHook(ConVarChanged);
	c_IfNeedLogKickMsg.AddChangeHook(ConVarChanged);
	c_QueryMode.AddChangeHook(ConVarChanged);
	c_CheckPlayerProfileCount.AddChangeHook(ConVarChanged);
	c_SteamCheck.AddChangeHook(ConVarChanged);
	c_APIKey.AddChangeHook(ConVarChanged);
	c_Debug.AddChangeHook(ConVarChanged);

	HookEvent("player_team", Event_PlayerTeam);

	RegConsoleCmd("sm_playertime", cmdplayertime);
	RegConsoleCmd("sm_time", cmdplayertime);
	RegConsoleCmd("sm_pt", cmdplayertime);

	// autoCreate=false: 只执行 cfg/sourcemod/GetPlayerGametime.cfg(取 API Key), 不创建、不回写该文件。
	// 原因: cfg 里除 GetPlayerGametimeAPIKey 外的 cvar 已全部注释掉, 其余值由 confogl 的
	// cfg/cfgogl/applemod12v12/applemod12v12.cfg 用 confogl_addcvar 下发; 若保持 autoCreate=true,
	// SourceMod 会把"文件里没出现的 cvar"(被注释掉的一律算没出现)按代码默认值重新追加回文件,
	// 注释就白写了。autoCreate=false 时 SourceMod 只执行已存在的文件, 不修改它。
	AutoExecConfig(false, "GetPlayerGametime");

	if (CheckPluginLate)
	{
		lateload();
	}
}

void ConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	// 换图时 AutoExecConfig 生成的 cfg 会重复执行, 值没变就不用重新查询所有玩家(否则每次换图都会刷一遍时长播报)
	if (StrEqual(oldValue, newValue)) return;
	GetCvars();
	DebugMsg("cvar 变更, 重新查询所有玩家的游戏时长");
	// 只有"影响时长获取或限制判定"的 cvar 变化才清掉"已限制/已提示"标记(相当于管理员主动要求重新判定);
	// 改 ShowPlayerLerp 这类显示用 cvar 时不要重新判定, 否则会把已经处理过的玩家再处理一遍
	bool bResetLimitState = IsLimitRelevantConVar(convar);
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientAuthorized(i) && IsClientInGame(i))
		{
			if (bResetLimitState)
			{
				b_LimitHandled[i]	 = false;
				b_RequestNotified[i] = false;
				b_FailureNotified[i] = false;
			}
			OnClientPostAdminCheck(i);
		}
	}
}

// 该 cvar 是否影响"时长获取 / 限制判定"
bool IsLimitRelevantConVar(ConVar convar)
{
	if (convar == c_LimitPlayer) return true;
	if (convar == c_LimitPlayerMinGametime) return true;
	if (convar == c_LimitPlayerMaxGametime) return true;
	if (convar == c_LimitPlayerMode) return true;
	if (convar == c_LPMWFailureGet) return true;
	if (convar == c_LPWRequesting) return true;
	if (convar == c_LPLateload) return true;
	if (convar == c_QueryMode) return true;
	if (convar == c_CheckPlayerGameCount) return true;
	if (convar == c_CheckPlayerProfileCount) return true;
	if (convar == c_APIKey) return true;
	if (convar == c_SteamCheck) return true;
	if (convar == c_Enable) return true;
	return false;
}

void GetCvars()
{
	b_Enable				 = c_Enable.BoolValue;
	i_ShowGametimeMode		 = c_ShowGametimeMode.IntValue;
	i_CheckPlayerGameCount	 = c_CheckPlayerGameCount.IntValue;
	b_LPWRequesting			 = c_LPWRequesting.BoolValue;
	i_LPMWFailureGet		 = c_LPMWFailureGet.IntValue;
	b_LPLateload			 = c_LPLateload.BoolValue;
	b_LimitPlayer			 = c_LimitPlayer.BoolValue;
	i_LimitPlayerMinGametime = c_LimitPlayerMinGametime.IntValue * SECONDS_PER_HOUR;
	i_LimitPlayerMaxGametime = c_LimitPlayerMaxGametime.IntValue * SECONDS_PER_HOUR;
	i_LimitPlayerMode		 = c_LimitPlayerMode.IntValue;
	b_ShowPlayerLerp		 = c_ShowPlayerLerp.BoolValue;
	b_SPLMode				 = c_SPLMode.BoolValue;
	b_IfNeedLogKickMsg		 = c_IfNeedLogKickMsg.BoolValue;
	i_QueryMode				 = c_QueryMode.IntValue;
	i_CheckPlayerProfileCount = c_CheckPlayerProfileCount.IntValue;
	b_SteamCheck			  = c_SteamCheck.BoolValue;
	c_APIKey.GetString(s_APIKey, sizeof(s_APIKey));

	// CheckPlayerGameCount=0 / CheckPlayerProfileCount=0 都表示"该数据源禁用", 两路对称处理
	b_StatsSourceEnabled   = b_SteamWorksAvailable && ((i_QueryMode & QUERY_STATS) != 0) && (i_CheckPlayerGameCount > 0);
	b_ProfileSourceEnabled = b_SteamWorksAvailable && ((i_QueryMode & QUERY_PROFILE) != 0) && (i_CheckPlayerProfileCount > 0) && (s_APIKey[0] != '\0');
	b_Debug				   = c_Debug.BoolValue;

	// 配置还没执行完时(OnPluginStart 阶段)读到的还是 cvar 默认值, 此时不做判断也不报错,
	// 否则服务器每次启动都会先误报一次"未设置 GetPlayerGametimeAPIKey"
	if (!b_ConfigsExecuted) return;

	// 数据源启用状态变化时, 往日志里留一条"插件实际读到了什么", 方便对照排查
	int iSourceState = (b_StatsSourceEnabled ? 1 : 0) | (b_ProfileSourceEnabled ? 2 : 0);
	if (iSourceState != i_LastSourceState)
	{
		i_LastSourceState = iSourceState;
		LogMessage("[GetPlayerGametime] QueryGametimeMode=%d | 主页时长查询:%s (APIKey 长度=%d, CheckPlayerProfileCount=%d) | 成就时长查询:%s (CheckPlayerGameCount=%d)",
				   i_QueryMode,
				   b_ProfileSourceEnabled ? "启用" : "禁用", strlen(s_APIKey), i_CheckPlayerProfileCount,
				   b_StatsSourceEnabled ? "启用" : "禁用", i_CheckPlayerGameCount);
	}

	// 没有任何可用数据源时, 关闭时长限制, 否则所有玩家都会被判定成"获取游戏时长失败"
	if (b_Enable && b_LimitPlayer && !b_StatsSourceEnabled && !b_ProfileSourceEnabled)
	{
		if (!b_WarnedNoSource)
		{
			b_WarnedNoSource = true;
			LogError("没有任何可用的游戏时长数据源(QueryGametimeMode=%d, CheckPlayerProfileCount=%d, APIKey 长度=%d), 已暂停因游戏时长而限制玩家的功能.",
					 i_QueryMode, i_CheckPlayerProfileCount, strlen(s_APIKey));
		}
	}
	else
	{
		b_WarnedNoSource = false;
	}

	// 没配主页查询不是错误(这是可选项), 只记一条普通日志
	if (((i_QueryMode & QUERY_PROFILE) != 0) && !b_ProfileSourceEnabled && b_SteamWorksAvailable)
	{
		if (!b_WarnedNoKey)
		{
			b_WarnedNoKey = true;
			LogMessage("[GetPlayerGametime] 玩家主页时长查询未启用: %s (QueryGametimeMode=%d, CheckPlayerProfileCount=%d, APIKey 长度=%d), 输出中只会显示成就统计时长. 需要主页时长时把 GetPlayerGametimeAPIKey 写在 server.cfg 或 cfg/sourcemod/GetPlayerGametime.cfg 里.",
					   (i_CheckPlayerProfileCount <= 0) ? "CheckPlayerProfileCount 不大于 0" : "GetPlayerGametimeAPIKey 读到的值为空",
					   i_QueryMode, i_CheckPlayerProfileCount, strlen(s_APIKey));
		}
	}
	else
	{
		b_WarnedNoKey = false;
	}
}

// AutoExecConfig 的 cfg 是在插件加载之后才执行的, 所以"配置是否配好"的判断要放在这里做
public void OnConfigsExecuted()
{
	b_ConfigsExecuted = true;
	GetCvars();
}

// SteamID 验证开关: 开启时只有 SteamID 验证成功且经过 OnClientAuthorized + OnClientPostAdminCheck
// 两个验证流程的玩家, 才会返回/播报获取到的游戏时长
bool IsClientSteamVerified(int client)
{
	if (!b_SteamCheck) return true;
	if (b_ClientAuthorized[client] && b_ClientPostAdminCheck[client] && IsClientAuthorized(client)) return true;
	return false;
}

public void OnClientAuthorized(int client, const char[] auth)
{
	if (client > 0 && client <= MaxClients && auth[0] != '\0' && !StrEqual(auth, "STEAM_ID_PENDING") && !IsFakeClient(client))
	{
		b_ClientAuthorized[client] = true;
	}
}

public void OnClientPostAdminCheck(int client)
{
	// 经过 OnClientPostAdminCheck 验证流程(与 b_Enable 无关, 验证状态始终记录)
	if (client > 0 && client <= MaxClients && !IsFakeClient(client))
	{
		b_ClientPostAdminCheck[client] = true;
	}

	if (!b_Enable) return;
	if (!IsValidClient(client) || IsFakeClient(client) || !IsClientConnected(client)) return;

	i_Count[client]			 = 0;
	i_ProfileCount[client]	 = 0;
	i_StatTime[client]		 = 0;
	i_ProfileTime[client]	 = 0;
	i_PlayerTime[client]	 = 0;
	i_StatState[client]		 = SOURCE_PENDING;
	i_ProfileState[client]	 = SOURCE_PENDING;
	b_Announced[client]		 = false;
	// 注意: i_StatsUserID / i_ProfileUserID 不要在这里清, 它们用于防止"同一条连接重复发起请求"

	// 两个数据源都是异步的: 成就统计需要等待 Steam 回调, 主页需要等待 HTTP 响应
	if (b_StatsSourceEnabled) StartStatsQuery(client);
	if (b_ProfileSourceEnabled) RequestProfileGametime(client);

	// 查询看门狗: 某一路卡死时到点收尾, 保证"双源都不返回"也能收敛出判定结果
	StartLimitWatchdog(client);

	OnSourceUpdate(client);
}

// 主页/成就数据晚于另一数据源到达时, 补播一次包含两个时长的完整信息
void OnSourceUpdate(int client, bool bNewData = false)
{
	if (!IsValidClient(client)) return;

	UpdatePlayerTimeState(client);

	// SteamID 未通过两个验证流程的玩家: 不播报时长, 也不做任何限制
	if (!IsClientSteamVerified(client)) return;

	if (i_PlayerTime[client] > 0 && (!b_Announced[client] || bNewData))
	{
		AnnouncePlayerTime(client);
	}

	LimitPlayer(client);
}

// 汇总两个数据源, 刷新用于限制/native 的生效时长: >0 成功, -1 获取中, -2 获取失败
void UpdatePlayerTimeState(int client)
{
	if (i_StatTime[client] > 0) i_PlayerTime[client] = i_StatTime[client];
	else if (i_ProfileTime[client] > 0) i_PlayerTime[client] = i_ProfileTime[client];
	else if (!AllSourcesFinished(client)) i_PlayerTime[client] = -1;
	else i_PlayerTime[client] = -2;
}

// 所有已启用的数据源是否都已经结束(成功或失败)
bool AllSourcesFinished(int client)
{
	if (b_StatsSourceEnabled && i_StatState[client] == SOURCE_PENDING) return false;
	if (b_ProfileSourceEnabled && i_ProfileState[client] == SOURCE_PENDING) return false;
	return true;
}

// 已请求次数(取两个数据源中较大者, 用于"请求中"提示)
int GetRequestCount(int client)
{
	return (i_Count[client] > i_ProfileCount[client]) ? i_Count[client] : i_ProfileCount[client];
}

// 只统计已启用的数据源, 否则单独启用某个数据源时永远达不到"最大请求次数"
int GetRequestMaxCount()
{
	int iMax = 0;
	if (b_StatsSourceEnabled && i_CheckPlayerGameCount > iMax) iMax = i_CheckPlayerGameCount;
	if (b_ProfileSourceEnabled && i_CheckPlayerProfileCount > iMax) iMax = i_CheckPlayerProfileCount;
	return iMax;
}

// 释放某条成就时长重试链的占用标记(只释放属于这条链的标记)
void ReleaseStatsChain(int client, int userid)
{
	if (client > 0 && client <= MaxClients && i_StatsUserID[client] == userid) i_StatsUserID[client] = 0;
}

// 数据源一: 成就统计时长(SteamWorks)
void StartStatsQuery(int client)
{
	int userid = GetClientUserId(client);

	// 同一连接已经有重试链在跑就不再重复发起(cvar 变更/中途加载会重复调用到这里)
	if (i_StatsUserID[client] == userid) return;

	i_StatState[client] = SOURCE_PENDING;
	i_StatTime[client]	= 0;

	// SteamWorks_RequestStats 是异步请求, 这里只是发起请求, 数据要等 Steam 回调后才可读
	SteamWorks_RequestStats(client, APPID_L4D2);

	if (SteamWorks_GetStatCell(client, STATS_PLAYTIME_KEY, i_StatTime[client]) && i_StatTime[client] > 0)
	{
		i_StatState[client] = SOURCE_OK;
		return;
	}
	// 注意: 刚发起 RequestStats 就立刻读 cell 的结果不可信(stat 可能还没同步),
	// 所以这里只把 >0 当成成功, 读到 0 一律按"还没拿到"处理, 等重试链。

	i_StatTime[client] = 0;

	// i_CheckPlayerGameCount=0 时 b_StatsSourceEnabled 为 false, 这里不会再被调用, 故不再需要 count=0 的分支
	i_StatsUserID[client] = userid;
	CreateTimer(1.0, MoreGetPlayerGameTime, userid, TIMER_FLAG_NO_MAPCHANGE);
}

Action MoreGetPlayerGameTime(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);
	// 玩家已离开: 标记留在原 userid 上, 新连接 userid 不同, 不会误挡
	if (!client || !IsValidClient(client) || IsFakeClient(client)) return Plugin_Stop;

	if (i_StatState[client] != SOURCE_PENDING)
	{
		ReleaseStatsChain(client, userid);
		return Plugin_Stop;
	}

	i_Count[client] += 1;

	if (i_Count[client] >= i_CheckPlayerGameCount)
	{
		ReleaseStatsChain(client, userid);
		i_StatState[client] = SOURCE_FAILED;
		OnSourceUpdate(client);
		return Plugin_Stop;
	}

	if (SteamWorks_GetStatCell(client, STATS_PLAYTIME_KEY, i_StatTime[client]) && i_StatTime[client] > 0)
	{
		ReleaseStatsChain(client, userid);
		i_StatState[client] = SOURCE_OK;
		OnSourceUpdate(client, true);
		return Plugin_Stop;
	}

	i_StatTime[client] = 0;
	SteamWorks_RequestStats(client, APPID_L4D2);

	OnSourceUpdate(client);

	// 继续下一次重试(单次计时器链, 标记继续由这条链持有)
	CreateTimer(1.0, MoreGetPlayerGameTime, userid, TIMER_FLAG_NO_MAPCHANGE);
	return Plugin_Stop;
}

// 数据源二: 玩家主页时长(Steam Web API, 由 SteamWorks 的 HTTP 接口发起)
void RequestProfileGametime(int client)
{
	if (!b_ProfileSourceEnabled || !IsValidClient(client) || IsFakeClient(client)) return;
	if (i_ProfileState[client] != SOURCE_PENDING) return;

	int userid = GetClientUserId(client);

	// 该连接已经有一个主页请求在飞(例如重试计时器与 cvar 变更/中途加载同时发生)时不再重复发
	if (i_ProfileUserID[client] == userid) return;

	char sSteamID[32];
	if (!GetClientAuthId(client, AuthId_SteamID64, sSteamID, sizeof(sSteamID)))
	{
		OnProfileQueryFailed(client);
		return;
	}

	char sURL[512];
	FormatEx(sURL, sizeof(sURL), "%s&key=%s&steamid=%s", PROFILE_GAMETIME_URL, s_APIKey, sSteamID);

	Handle hRequest = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, sURL);
	if (hRequest == null)
	{
		OnProfileQueryFailed(client);
		return;
	}

	SteamWorks_SetHTTPRequestNetworkActivityTimeout(hRequest, 10);
	SteamWorks_SetHTTPRequestContextValue(hRequest, userid);
	SteamWorks_SetHTTPCallbacks(hRequest, OnProfileHTTPCompleted);

	if (!SteamWorks_SendHTTPRequest(hRequest))
	{
		CloseHandle(hRequest);
		OnProfileQueryFailed(client);
		return;
	}

	i_ProfileUserID[client] = userid;
}

public void OnProfileHTTPCompleted(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode, any data1)
{
	int client = GetClientOfUserId(data1);
	bool bHandled = false;

	// 请求已结束, 释放"在飞"占位
	if (client && i_ProfileUserID[client] == data1) i_ProfileUserID[client] = 0;

	if (!bFailure && bRequestSuccessful && eStatusCode == k_EHTTPStatusCode200OK && client && IsClientInGame(client) && i_ProfileState[client] == SOURCE_PENDING)
	{
		int iSize;
		if (SteamWorks_GetHTTPResponseBodySize(hRequest, iSize) && iSize > 0)
		{
			char[] sBody = new char[iSize + 1];
			sBody[iSize] = '\0';	// 响应体不保证带结束符, 手动补上
			if (SteamWorks_GetHTTPResponseBodyData(hRequest, sBody, iSize))
			{
				int iMinutes;
				if (ParseProfilePlaytime(sBody, iMinutes))
				{
					i_ProfileTime[client]  = iMinutes * SECONDS_PER_MINUTE;
					i_ProfileState[client] = SOURCE_OK;
					bHandled = true;
					OnSourceUpdate(client, true);
				}
			}
		}
	}

	// 一个响应只走一条结局: 成功已处理, 否则按失败重试
	if (!bHandled && client && IsClientInGame(client))
	{
		DebugMsg("%N 主页时长查询失败 (http:%d failure:%d successful:%d)", client, eStatusCode, bFailure, bRequestSuccessful);
		OnProfileQueryFailed(client);
	}

	CloseHandle(hRequest);
}

// 从 GetOwnedGames 返回的 JSON 中取出 playtime_forever(分钟)
// 玩家资料/游戏详情未公开时 Steam 只返回 {"response":{}}, 这里会判定为失败
bool ParseProfilePlaytime(const char[] sData, int &iMinutes)
{
	iMinutes = 0;

	if (StrContains(sData, "\"games\"", false) == -1) return false;

	int iPos = StrContains(sData, "\"playtime_forever\"", false);
	if (iPos == -1) return false;

	iPos += 18;	// strlen("\"playtime_forever\"")

	while (sData[iPos] != '\0' && (sData[iPos] == ' ' || sData[iPos] == '\t' || sData[iPos] == ':' || sData[iPos] == '"')) iPos++;

	if (sData[iPos] < '0' || sData[iPos] > '9') return false;

	iMinutes = StringToInt(sData[iPos]);
	return (iMinutes > 0);
}

void OnProfileQueryFailed(int client)
{
	if (!IsValidClient(client)) return;
	if (i_ProfileState[client] != SOURCE_PENDING) return;

	i_ProfileCount[client] += 1;

	if (i_ProfileCount[client] >= i_CheckPlayerProfileCount)
	{
		i_ProfileState[client] = SOURCE_FAILED;
		OnSourceUpdate(client);
		return;
	}

	OnSourceUpdate(client);
	CreateTimer(1.0, TimerProfileRetry, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

Action TimerProfileRetry(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);
	if (client && IsValidClient(client) && !IsFakeClient(client)) RequestProfileGametime(client);
	return Plugin_Stop;
}

Action cmdplayertime(int client, int args)
{
	DebugMsg("sm_playertime 指令已执行");
	if (b_SPLMode)
	{
		int survivorCount  = 0;
		int infectedCount  = 0;
		int spectatorCount = 0;
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsClientInGame(i) && !IsFakeClient(i))
			{
				if (GetClientTeam(i) == 2) survivorCount = 1;
				if (GetClientTeam(i) == 3) infectedCount = 1;
				if (GetClientTeam(i) == 1) spectatorCount = 1;
			}
		}
		if (survivorCount == 1) CPrintToChatAll("{olive}-------------------------------------------------------------------");
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsClientInGame(i) && !IsFakeClient(i) && IsClientConnected(i) && GetClientTeam(i) == 2)
			{
				AnnouncePlayerTime(i);
			}
		}
		if (survivorCount == 1) CPrintToChatAll("{olive}-------------------------------------------------------------------");
		if (infectedCount == 1) CPrintToChatAll("{green}-------------------------------------------------------------------");
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsClientInGame(i) && !IsFakeClient(i) && IsClientConnected(i) && GetClientTeam(i) == 3)
			{
				AnnouncePlayerTime(i);
			}
		}
		if (infectedCount == 1) CPrintToChatAll("{green}-------------------------------------------------------------------");
		if (spectatorCount == 1) CPrintToChatAll("-------------------------------------------------------------------");
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsClientInGame(i) && !IsFakeClient(i) && IsClientConnected(i) && GetClientTeam(i) == 1)
			{
				AnnouncePlayerTime(i);
			}
		}
		if (spectatorCount == 1) CPrintToChatAll("-------------------------------------------------------------------");
	}
	else
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsValidClient(i) && !IsFakeClient(i))
			{
				AnnouncePlayerTime(i);
			}
		}
	}

	return Plugin_Handled;
}

void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	if (!b_Enable || !b_LimitPlayer) return;
	int client	= GetClientOfUserId(event.GetInt("userid"));
	int oldteam = event.GetInt("oldteam");
	int iTeam	= event.GetInt("team");

	if (IsValidClient(client) && !IsFakeClient(client) && (oldteam == 1 || iTeam == 1))
	{
		LimitPlayer(client);
	}
}

bool IsValidClient(int client)
{
	return client > 0 && client <= MaxClients && IsClientInGame(client);
}

// 双时长联合判定: 只要"玩家主页时长"或"成就统计时长"任意一路落在
// (LimitPlayerMinGametime, LimitPlayerMaxGametime) 开区间内, 就判定该玩家符合限制条件。
// 命中时通过 iUsedTime/iUsedSource 回带"命中哪一路、多少秒", 供踢出提示与日志使用。
// 返回 false 只表示"目前已知的时长都不在区间内", 不代表另一路将来不会有值。
bool CheckPlayerGametime(int client, int &iUsedTime, int &iUsedSource)
{
	iUsedTime   = 0;
	iUsedSource = 0;

	// 成就统计时长(SteamWorks stat: Stat.TotalPlayTime.Total)
	if (i_StatTime[client] > 0
		&& i_StatTime[client] > i_LimitPlayerMinGametime
		&& i_StatTime[client] < i_LimitPlayerMaxGametime)
	{
		iUsedTime   = i_StatTime[client];
		iUsedSource = 2;
		DebugMsg("玩家 %N 命中成就统计时长 %d 秒 (限制区间 %d - %d 秒)", client, iUsedTime, i_LimitPlayerMinGametime, i_LimitPlayerMaxGametime);
		return true;
	}

	// 玩家主页(Steam 个人资料)时长
	if (i_ProfileTime[client] > 0
		&& i_ProfileTime[client] > i_LimitPlayerMinGametime
		&& i_ProfileTime[client] < i_LimitPlayerMaxGametime)
	{
		iUsedTime   = i_ProfileTime[client];
		iUsedSource = 1;
		DebugMsg("玩家 %N 命中主页时长 %d 秒 (限制区间 %d - %d 秒)", client, iUsedTime, i_LimitPlayerMinGametime, i_LimitPlayerMaxGametime);
		return true;
	}

	return false;
}

// 是否已经拿到任意一路时长
bool HasAnyGametime(int client)
{
	return (i_StatTime[client] > 0 || i_ProfileTime[client] > 0);
}

// 调试输出: 由 GetPlayerGametimeDebug(默认 0)控制, 只写服务器控制台, 不刷玩家聊天
void DebugMsg(const char[] fmt, any ...)
{
	if (!b_Debug) return;
	char buffer[512];
	VFormat(buffer, sizeof(buffer), fmt, 2);
	PrintToServer("[GetPlayerGametime] %s", buffer);
}

// 按 LimitPlayerMode 执行限制动作: 1=踢出 2=移动到旁观
void ApplyPlayerLimit(int client, int iUsedTime, int iUsedSource)
{
	if (i_LimitPlayerMode == 1)
	{
		float f_LimitPlayerMinGametime = float(i_LimitPlayerMinGametime) / SECONDS_PER_HOUR;
		float f_LimitPlayerMaxGametime = float(i_LimitPlayerMaxGametime) / SECONDS_PER_HOUR;
		KickClient(client, "%t", "kickplayerUnqualified", f_LimitPlayerMinGametime, f_LimitPlayerMaxGametime);
		LogKickPlayer(client, 2, iUsedTime, iUsedSource);
	}
	else
	{
		ChangeClientToSpec(client);
		CPrintToChatAll("%t", "forcespecplayerUnqualified", client);
	}
}

void LimitPlayer(int client)
{
	// 防重入: ChangeClientToSpec 移动玩家时会触发 player_team 事件重入本函数,无限递归导致栈溢出
	if (b_IsProcessingLimitPlayer[client]) return;
	if (!IsValidClient(client)) return;
	if (!b_Enable || !b_LimitPlayer) return;
	// i_PlayerTime 为 0 表示本连接还没初始化过判定状态(PostAdminCheck 之后恒为 -1/-2/时长), 此时不判定
	if (i_PlayerTime[client] == 0) return;
	// SteamID 未通过两个验证流程的玩家, 不返回时长也不做限制(不误判为获取失败)
	if (!IsClientSteamVerified(client)) return;
	// 无可用数据源时不做任何限制
	if (!b_StatsSourceEnabled && !b_ProfileSourceEnabled) return;

	b_IsProcessingLimitPlayer[client] = true;
	LimitPlayerInner(client);
	b_IsProcessingLimitPlayer[client] = false;
}

// 限制判定的状态机(数据源每变化一次、玩家换队一次都会走到这里):
//   [1] 任意一路命中限制区间        → 立即限制(不等另一路), 置 b_LimitHandled 后不再重复处理
//   [2] 一路时长都没有 + 还有源在请求 → 等待(LPWRequesting 时压旁观), 提示只发一次
//   [3] 一路时长都没有 + 全部源结束  → 按 LPMWFailureGet 处理(踢/转旁观/只提示), 置 b_LimitHandled
//   [4] 已有数据但都不在区间 + 另一路还在路上 → 等另一路到了再判一次
//   [5] 已有数据但都不在区间 + 全部源结束    → 放行, 不做任何处理
void LimitPlayerInner(int client)
{
	// 本连接已经执行过限制动作: 管理员把玩家转回生还者、player_team 再次触发都不重复处理
	if (b_LimitHandled[client]) return;

	int iUsedTime   = 0;
	int iUsedSource = 0;

	// [1] 任一路命中 → 立即限制
	if (CheckPlayerGametime(client, iUsedTime, iUsedSource) && (i_LimitPlayerMode != 0))
	{
		// 插件中途加载 + LPLateload=1: 取消一切因游戏时长产生的限制行为
		if (b_LPLateload && CheckPluginLate) return;

		char sSource[16];
		if (iUsedSource == 1) strcopy(sSource, sizeof(sSource), "主页");
		else strcopy(sSource, sizeof(sSource), "成就");
		DebugMsg("限制玩家 %N: 来源=%s, 时长=%d 秒, LimitPlayerMode=%d", client, sSource, iUsedTime, i_LimitPlayerMode);

		b_LimitHandled[client]	  = true;
		b_RequestNotified[client] = true;
		b_FailureNotified[client] = true;
		ApplyPlayerLimit(client, iUsedTime, iUsedSource);
		return;
	}

	// [2][3] 一路时长都还没拿到
	if (!HasAnyGametime(client))
	{
		if (!AllSourcesFinished(client))
		{
			// 还有源在请求/重试: LPWRequesting=1 时每次进来都压回旁观(玩家可能又占了位置), 提示只发一次
			if (b_LPWRequesting && !(b_LPLateload && CheckPluginLate))
			{
				ChangeClientToSpec(client);
				if (!b_RequestNotified[client])
				{
					b_RequestNotified[client] = true;
					CPrintToChatAll("%t", "forcespecplayerRequesting", client, GetRequestCount(client), GetRequestMaxCount());
				}
			}
			else if (!b_RequestNotified[client] && (GetRequestCount(client) >= GetRequestMaxCount()))
			{
				b_RequestNotified[client] = true;
				CPrintToChatAll("%t", "RequestingPlayerGametime", client, GetRequestCount(client) + 1, GetRequestMaxCount());
			}
			DebugMsg("玩家 %N 时长获取中: 已请求 %d/%d 次", client, GetRequestCount(client), GetRequestMaxCount());
			return;
		}

		// 所有已启用数据源都已结束(失败)且一路都没有值
		if (i_LPMWFailureGet == 0)
		{
			if (!b_FailureNotified[client])
			{
				b_FailureNotified[client] = true;
				CPrintToChatAll("%t", "FailureGetPlayerGametime", client);
			}
			DebugMsg("玩家 %N 两路时长都获取失败(LPMWFailureGet=0, 不做处理)", client);
			return;
		}
		if (b_LPLateload && CheckPluginLate) return;

		b_LimitHandled[client]	  = true;
		b_FailureNotified[client] = true;
		if (i_LPMWFailureGet == 1)
		{
			KickClient(client, "%t", "kickplayerFailureGet");
			LogKickPlayer(client, 1);
		}
		else
		{
			ChangeClientToSpec(client);
			CPrintToChatAll("%t", "forcespecplayerFailureGet", client);
		}
		return;
	}

	// [4][5] 已有数据但都不在限制区间
	if (!AllSourcesFinished(client))
	{
		// 另一路可能还在路上: 等它到了 OnSourceUpdate 会再判一次
		DebugMsg("玩家 %N 已到手的时长都不在限制区间, 继续等另一个来源(成就状态=%d 主页状态=%d)", client, i_StatState[client], i_ProfileState[client]);
		return;
	}

	// 全部来源都结束了, 结论是放行(不设 b_LimitHandled: 换图/cvar 变更重新查询后仍可再判)
	DebugMsg("玩家 %N 时长判定完成(放行): 成就=%d 秒, 主页=%d 秒", client, i_StatTime[client], i_ProfileTime[client]);
}

// 查询看门狗: 某一路查询卡住(HTTP 一直不回调等)时, 到点把没回来的源按"获取失败"收尾,
// 保证"两路都不返回"时也能收敛到 LPMWFailureGet 分支, 而不是永远停在"获取中"
void StartLimitWatchdog(int client)
{
	if (!b_Enable || !b_LimitPlayer) return;
	if (!b_StatsSourceEnabled && !b_ProfileSourceEnabled) return;

	// 估算: 成就每次重试间隔 1 秒; 主页每次请求最多 10 秒超时 + 1 秒重试间隔
	float fSeconds = float(i_CheckPlayerGameCount) + (float(i_CheckPlayerProfileCount) * 11.0) + 10.0;
	CreateTimer(clamp(fSeconds, 20.0, 120.0), TimerLimitWatchdog, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

Action TimerLimitWatchdog(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);
	if (!client || !IsValidClient(client) || IsFakeClient(client)) return Plugin_Stop;
	if (b_LimitHandled[client]) return Plugin_Stop;
	if (AllSourcesFinished(client)) return Plugin_Stop;

	bool bChanged = false;
	if (b_StatsSourceEnabled && i_StatState[client] == SOURCE_PENDING)
	{
		i_StatState[client]   = SOURCE_FAILED;
		i_StatsUserID[client] = 0;
		bChanged			  = true;
	}
	if (b_ProfileSourceEnabled && i_ProfileState[client] == SOURCE_PENDING)
	{
		i_ProfileState[client] = SOURCE_FAILED;
		i_ProfileUserID[client] = 0;
		bChanged			   = true;
	}
	if (!bChanged) return Plugin_Stop;

	LogMessage("[GetPlayerGametime] 玩家 %N 的时长查询超时, 未返回的来源已按获取失败处理", client);
	OnSourceUpdate(client);
	return Plugin_Stop;
}

void AnnouncePlayerTime(int client)
{
	if (!b_Enable) return;
	if (!IsClientInGame(client)) return;
	// SteamID 未通过两个验证流程的玩家, 不播报获取到的游戏时长
	if (!IsClientSteamVerified(client)) return;

	if (i_PlayerTime[client] > 0)
	{
		b_Announced[client] = true;

		// 每个接收者都用自己的语言格式化: 外层语句 + 内层"主页/成就时长"与"Lerp"文本
		for (int receiver = 1; receiver <= MaxClients; receiver++)
		{
			if (!IsClientInGame(receiver) || IsFakeClient(receiver)) continue;

			SetGlobalTransTarget(receiver);

			char g_playertime[160];
			BuildGametimeText(client, g_playertime, sizeof(g_playertime));

			char g_lerp[64];
			if (b_ShowPlayerLerp) FormatEx(g_lerp, sizeof(g_lerp), "%t", "showlerp", GetPlayerLerp(client) * 1000);
			else g_lerp[0] = '\0';

			CPrintToChat(receiver, "%t", "announcegametime", client, g_playertime, g_lerp);
		}
		DebugMsg("%N 成就=%d 秒, 主页=%d 秒", client, i_StatTime[client], i_ProfileTime[client]);
	}
	else
	{
		if (!b_StatsSourceEnabled && !b_ProfileSourceEnabled) return;

		if ((i_PlayerTime[client] == -1 && GetRequestCount(client) < GetRequestMaxCount()))
		{
			CPrintToChatAll("%t", "RequestingPlayerGametime", client, GetRequestCount(client) + 1, GetRequestMaxCount());
		}
		else if ((i_PlayerTime[client] == -2 && GetRequestCount(client) >= GetRequestMaxCount()))
		{
			CPrintToChatAll("%t", "FailureGetPlayerGametime", client);
		}
	}
}

// 组装时长文本: 玩家主页时长\成就统计时长 (缺失的一方不显示)
void BuildGametimeText(int client, char[] buffer, int maxlen)
{
	char sProfile[64];
	char sStats[64];
	sProfile[0] = '\0';
	sStats[0]   = '\0';

	if (i_ProfileTime[client] > 0)
	{
		if (i_ShowGametimeMode == 1) FormatEx(sProfile, sizeof(sProfile), "%t", "timeprofile1", i_ProfileTime[client] / SECONDS_PER_HOUR, i_ProfileTime[client] / SECONDS_PER_MINUTE % SECONDS_PER_MINUTE);
		else FormatEx(sProfile, sizeof(sProfile), "%t", "timeprofile", float(i_ProfileTime[client]) / SECONDS_PER_HOUR);
	}

	if (i_StatTime[client] > 0)
	{
		if (i_ShowGametimeMode == 1) FormatEx(sStats, sizeof(sStats), "%t", "timestats1", i_StatTime[client] / SECONDS_PER_HOUR, i_StatTime[client] / SECONDS_PER_MINUTE % SECONDS_PER_MINUTE);
		else FormatEx(sStats, sizeof(sStats), "%t", "timestats", float(i_StatTime[client]) / SECONDS_PER_HOUR);
	}

	if (sProfile[0] != '\0' && sStats[0] != '\0') FormatEx(buffer, maxlen, "%s\\%s", sProfile, sStats);
	else if (sProfile[0] != '\0') strcopy(buffer, maxlen, sProfile);
	else if (sStats[0] != '\0') strcopy(buffer, maxlen, sStats);
	else buffer[0] = '\0';
}

void lateload()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		// 晚加载时 OnClientAuthorized 不会再触发, 已验证 SteamID 的在线玩家直接补记状态, 否则他们的时长会一直不返回
		if (IsClientAuthorized(i) && IsClientInGame(i) && !IsFakeClient(i)) b_ClientAuthorized[i] = true;
		if (IsClientAuthorized(i) && IsClientInGame(i)) OnClientPostAdminCheck(i);
	}
}
// https://github.com/TouchMe-Inc/l4d2_player_info/blob/main/addons/sourcemod/scripting/player_info.sp#L146
float GetPlayerLerp(int iClient)
{
	char  buffer[32];
	float fLerpRatio, fLerpAmount, fUpdateRate;

	if (GetClientInfo(iClient, "cl_interp_ratio", buffer, sizeof(buffer)))
	{
		fLerpRatio = StringToFloat(buffer);
	}

	if (g_cvMinInterpRatio != null && g_cvMaxInterpRatio != null && GetConVarFloat(g_cvMinInterpRatio) != -1.0)
	{
		fLerpRatio = clamp(fLerpRatio, GetConVarFloat(g_cvMinInterpRatio), GetConVarFloat(g_cvMaxInterpRatio));
	}

	if (GetClientInfo(iClient, "cl_interp", buffer, sizeof(buffer)))
	{
		fLerpAmount = StringToFloat(buffer);
	}

	if (GetClientInfo(iClient, "cl_updaterate", buffer, sizeof(buffer)))
	{
		fUpdateRate = StringToFloat(buffer);
	}

	fUpdateRate = clamp(fUpdateRate, GetConVarFloat(g_cvMinUpdateRate), GetConVarFloat(g_cvMaxUpdateRate));

	return max(fLerpAmount, fLerpRatio / fUpdateRate);
}

float max(float a, float b)
{
	return (a > b) ? a : b;
}

float clamp(float inc, float low, float high)
{
	return (inc > high) ? high : ((inc < low) ? low : inc);
}

// 记一条自动踢出的日志; iUsedTime/iUsedSource 由 CheckPlayerGametime 回带(-1/0 = 用 i_PlayerTime 的口径)
void LogKickPlayer(int client, int Mode, int iUsedTime = -1, int iUsedSource = 0)
{
	if (b_IfNeedLogKickMsg)
	{
		char Msg[256], Time[32];
		IsCreateLogFile();
		FormatTime(Time, sizeof(Time), "%Y-%m-%d %H:%M:%S", -1);
		char KickMsg[220];
		if (Mode == 1) Format(KickMsg, sizeof(KickMsg), "%N were auto kicked because failed to get playtime!", client);
		else
		{
			float f_LimitPlayerMinGametime = float(i_LimitPlayerMinGametime) / SECONDS_PER_HOUR;
			float f_LimitPlayerMaxGametime = float(i_LimitPlayerMaxGametime) / SECONDS_PER_HOUR;
			int   iGametime				   = (iUsedTime > 0) ? iUsedTime : i_PlayerTime[client];
			float gametime				   = float(iGametime) / SECONDS_PER_HOUR;
			// 日志里用英文来源名, 避免日志文件编码差异导致中文乱码
			char  sSource[16];
			if (iUsedSource == 1) strcopy(sSource, sizeof(sSource), "profile");
			else if (iUsedSource == 2) strcopy(sSource, sizeof(sSource), "stats");
			else strcopy(sSource, sizeof(sSource), "current");
			Format(KickMsg, sizeof(KickMsg), "%N kicked : %.2fh (source: %s / %.2f h - %.2f h)!", client, gametime, sSource, f_LimitPlayerMinGametime, f_LimitPlayerMaxGametime);
		}
		Format(Msg, sizeof(Msg), "[%s] %s", Time, KickMsg);
		IsSaveMessage(Msg);
	}
}

void IsCreateLogFile()
{
	char Date[32], logFile[128];
	FormatTime(Date, sizeof(Date), "%y%m%d", -1);
	Format(logFile, sizeof(logFile), "/logs/GetPlayerGameTime%s.log", Date);
	BuildPath(Path_SM, chatFile, PLATFORM_MAX_PATH, logFile);
}

void IsSaveMessage(const char[] Message)
{
	File fileHandle = OpenFile(chatFile, "a"); /* Append */
	fileHandle.WriteLine(Message);
	delete fileHandle;
}

//thank sorallll
void ChangeClientToSpec(int client)
{
	// 客户端可能在定时器/事件延迟期间进入断线状态(IsClientInGame 仍为 true 但连接已断),此时 ChangeClientTeam 会报 "Client X is not connected"
	if (!IsClientConnected(client) || !IsClientInGame(client)) return;
	// 已经在旁观队就不用再动(降少无意义的事件); 但仍要把空闲玩家身上的 bot 接管回来
	if (GetClientTeam(client) == 1 && GetBotOfIdlePlayer(client)) L4D_TakeOverBot(client);
	if (!IsClientConnected(client) || !IsClientInGame(client)) return;
	ChangeClientTeam(client, 1);
}

int GetBotOfIdlePlayer(int client) {
	for (int i = 1; i <= MaxClients; i++) {
		if (IsClientInGame(i) && IsFakeClient(i) && GetClientTeam(i) == 2 && GetIdlePlayerOfBot(i) == client)
			return i;
	}
	return 0;
}

int GetIdlePlayerOfBot(int client) {
	if (!HasEntProp(client, Prop_Send, "m_humanSpectatorUserID"))
		return 0;

	return GetClientOfUserId(GetEntProp(client, Prop_Send, "m_humanSpectatorUserID"));
}
