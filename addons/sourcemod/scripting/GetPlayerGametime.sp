#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <SteamWorks>
#include <left4dhooks>
#include <colors>

#define DEBUG 0

#define APPID_L4D2			 550
#define STATS_PLAYTIME_KEY	 "Stat.TotalPlayTime.Total"
#define SECONDS_PER_HOUR	 3600
#define SECONDS_PER_MINUTE	 60

// 准入下限的看门狗超时估算参数(秒): 单次 HTTP 请求超时 + 两次重试之间的间隔
#define GATE_HTTP_TIMEOUT	10.0
#define GATE_RETRY_STEP		1.0
#define GATE_TIMEOUT_MIN	60.0
#define GATE_TIMEOUT_MAX	120.0

// Steam Web API: 玩家主页(Steam 个人资料)游戏时长
#define PROFILE_GAMETIME_URL "http://api.steampowered.com/IPlayerService/GetOwnedGames/v0001/?format=json&appids_filter[0]=550"

public Plugin myinfo =
{
	name		= "get player gametime",
	author		= "apples1949 , 豆瓣酱な , deepseek",
	description = "",
	version		= "1.6.0",
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
// "准入下限"模式的待判定标记: 时长还没到手时, 该玩家处于"待判定"状态,
// 在结论出来前不允许上生还者(2)/特感(3)队; 数据到手后按结论踢出或放行并清除标记.
bool   b_PendingGate[MAXPLAYERS + 1];
// 待判定期间是否真的被压过旁观(只为在放行时给玩家一句"现在可以进队了"的提示)
bool   b_GateForcedSpec[MAXPLAYERS + 1];
// 压旁观的独立重入标记: ChangeClientToSpec -> ChangeClientTeam 会同步再触发 player_team,
// 用它挡住自己这条链, 不去改动原有 b_IsProcessingLimitPlayer 的语义
bool   b_IsHoldingPending[MAXPLAYERS + 1];
// 该连接是否已因"时长不足"被踢(踢出到真正断线之间别再重复踢/重复压旁观)
bool   b_GateKicked[MAXPLAYERS + 1];
// 该连接是否已经得出结论(达标放行/已踢/超时放行)。
// 必须有这个标记: ConVarChanged 会把全服玩家重新走一遍 OnClientPostAdminCheck 重新查时长,
// 若没有它, 已经放行、正在玩的玩家会被重新置成"待判定"然后被压回旁观。
bool   b_GateResolved[MAXPLAYERS + 1];
// 待判定期间是否已经给玩家发过"正在核对时长"的提示(避免刷屏)
bool   b_GateHoldAnnounced[MAXPLAYERS + 1];
// 玩家主页接口明确返回了 playtime_forever=0(确实拥有该游戏但一分钟都没玩过)。
// 必须和"取不到数据"区分开: 0 小时正是本功能要拦的人, 不能因为值等于 0 就当成失败放行。
// 只采信主页接口: 成就 stat cell 读到 0 有可能是"未同步"的假 0, 据此判定会误踢老玩家。
bool   b_KnownZero[MAXPLAYERS + 1];
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
// 准入下限(小时)的 cvar 原值; 0=关闭该功能
float  f_LimitPlayerRequireMinHours;
// 准入下限换算成秒后的比较阈值, 以及"不足该时长即拦截"的标志
int	   i_LimitPlayerRequireMinGametime;
bool   b_LimitPlayerRequireEnabled;
bool   b_SPLMode;
bool   b_IfNeedLogKickMsg;
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
ConVar c_LimitPlayerRequireMinHours;

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

// 连接刚进服就进入"待判定"。
// 为什么要在 OnClientPostAdminCheck 之外再加这一个: OnClientPostAdminCheck 之前理论上有很短一段时间,
// 玩家可能已经能触发 player_team 去占生还者位; 提前置标记可以把这个窗口也堵上,
// 这样才能保证"数据到手前不允许上 2/3 队"是严格的。
public void OnClientPutInServer(int client)
{
	if (!IsValidClient(client) || IsFakeClient(client)) return;
	StartPendingGate(client);
}

public void OnClientDisconnect(int client)
{
	if (client > 0 && client <= MaxClients)
	{
		b_ClientAuthorized[client]	   = false;
		b_ClientPostAdminCheck[client] = false;
		// 断线必须把准入下限的所有状态清干净, 否则 index 复用给下一个玩家时会带着
		// "待判定/已被压旁观/正在压旁观"的残留标记 —— 那会把正常玩家永久压在旁观
		b_PendingGate[client]		= false;
		b_GateForcedSpec[client]	= false;
		b_IsHoldingPending[client]	= false;
		b_GateKicked[client]		= false;
		b_GateResolved[client]		= false;	// 下一个占用该 index 的玩家重新从"未判定"开始
		b_GateHoldAnnounced[client] = false;
		b_KnownZero[client]			= false;
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
	c_CheckPlayerGameCount	 = CreateConVar("CheckPlayerGameCount", "8", "如果由于任何可能的原因未能获取到玩家的成就统计时长，应重复多少次以获取玩家的成就统计时长？0:不重试", FCVAR_NOTIFY, true, 0.0);
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
	// 准入下限: 与 LimitPlayerMinGametime/MaxGametime 的"禁止区间"语义互不影响, 这是"最低准入时长"语义。
	// 处理方式固定为踢出(用户已确认不做旁观), 所以不再提供 Mode cvar。0=关闭该功能。
	c_LimitPlayerRequireMinHours = CreateConVar("LimitPlayerRequireMinHours", "10.0", "准入下限(单位:小时): 游戏时长不足该小时数的玩家不允许进入服务器(固定为踢出, 1=踢出)。判定为 time <= 该值*3600 即拦下。0=关闭该功能", FCVAR_NOTIFY, true, 0.0);

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
	c_LimitPlayerRequireMinHours.AddChangeHook(ConVarChanged);

	HookEvent("player_team", Event_PlayerTeam);

	RegConsoleCmd("sm_playertime", cmdplayertime);
	RegConsoleCmd("sm_time", cmdplayertime);
	RegConsoleCmd("sm_pt", cmdplayertime);

	AutoExecConfig(true, "GetPlayerGametime");

	if (CheckPluginLate)
	{
		lateload();
	}
}

void ConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	// 换图时 AutoExecConfig 生成的 cfg 会重复执行, 值没变就不用重新查询所有玩家(否则每次换图都会刷一遍时长播报)
	if (StrEqual(oldValue, newValue)) return;
#if DEBUG
	CPrintToChatAll("cvar is change,requite all player gametime");
#endif
	GetCvars();
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientAuthorized(i) && IsClientInGame(i)) OnClientPostAdminCheck(i);
	}
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

	// 准入下限换算成秒: 用 float 秒数四舍五入成整数秒, 避免 cvar 填 9.5 这类值时被截断成 9 小时。
	// 边界语义(用户口径"不超过 10 小时"): i_PlayerTime <= 阈值 即拦下, 阈值 = 10.0 * 3600 = 36000 秒(正好 10 小时整)。
	// 也就是说"时长恰好 10.00 小时"算不足、会被踢; 必须 > 36000 秒才放行。
	f_LimitPlayerRequireMinHours	 = c_LimitPlayerRequireMinHours.FloatValue;
	i_LimitPlayerRequireMinGametime	 = RoundToNearest(f_LimitPlayerRequireMinHours * SECONDS_PER_HOUR);
	b_LimitPlayerRequireEnabled		 = (f_LimitPlayerRequireMinHours > 0.0) && (i_LimitPlayerRequireMinGametime > 0);

	b_StatsSourceEnabled   = b_SteamWorksAvailable && ((i_QueryMode & QUERY_STATS) != 0);
	b_ProfileSourceEnabled = b_SteamWorksAvailable && ((i_QueryMode & QUERY_PROFILE) != 0) && (i_CheckPlayerProfileCount > 0) && (s_APIKey[0] != '\0');

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

	// 运行期证据: 把准入下限到底有没有真的生效打到日志里。
	// 排查"为什么没人被踢"时先看这一行: 若 gate=禁用, 原因就在 enabled 后面括号里的那一条。
	LogMessage("[GetPlayerGametime] 准入下限 LimitPlayerRequireMinHours=%.2f h (阈值 %d 秒, time <= 阈值即踢) | gate=%s (%s) | SteamWorks=%s | 数据源 主页=%s 成就=%s | CheckPluginLate=%s LPLateload=%s",
			   f_LimitPlayerRequireMinHours,
			   i_LimitPlayerRequireMinGametime,
			   IsRequireGateEnabled() ? "启用" : "禁用",
			   IsRequireGateEnabled() ? "正常" :
				   (!b_Enable ? "GetPlayerGametimeEnable=0" :
					!b_LimitPlayerRequireEnabled ? "LimitPlayerRequireMinHours<=0" :
					!b_SteamWorksAvailable ? "SteamWorks 不可用" :
					(!b_StatsSourceEnabled && !b_ProfileSourceEnabled) ? "没有可用数据源" : "晚加载保护生效"),
			   b_SteamWorksAvailable ? "可用" : "不可用",
			   b_ProfileSourceEnabled ? "开" : "关",
			   b_StatsSourceEnabled ? "开" : "关",
			   CheckPluginLate ? "true" : "false",
			   b_LPLateload ? "1" : "0");
}

// 换图时把准入下限的待判定状态全部清掉。
// 必须清的理由: 看门狗定时器带了 TIMER_FLAG_NO_MAPCHANGE, 换图时会被销毁;
// 若此时还留着 b_PendingGate=true, 那个玩家在新图里就再也没人去给结论 —— 会被永久卡在旁观。
// 换图本身就是一次重置, 已在线玩家不重新走 OnClientPostAdminCheck, 所以直接按"放行"处理最安全。
public void OnMapEnd()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		// 还挂着待判定的玩家: 看门狗已被换图销毁, 这里直接按"放行"结案。
		// 同时置 b_GateResolved, 否则之后任何 cvar 变更都会让他重新进待判定并被压回旁观,
		// 而玩家此时正在新图里玩 —— 那属于严重误伤。
		if (b_PendingGate[i] && IsClientInGame(i) && !IsFakeClient(i)) b_GateResolved[i] = true;
		b_PendingGate[i]		= false;
		b_GateForcedSpec[i]		= false;
		b_IsHoldingPending[i]	= false;
		b_GateHoldAnnounced[i]	= false;
	}
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
	b_KnownZero[client] = false;
	// 注意: i_StatsUserID / i_ProfileUserID 不要在这里清, 它们用于防止"同一条连接重复发起请求"

	// 准入下限: 在发起任何异步查询之前就先把玩家置为"待判定", 否则数据先到、标记后设,
	// 会出现"已经放行/已经踢了又补一次判定"的竞态
	StartPendingGate(client);

	// 两个数据源都是异步的: 成就统计需要等待 Steam 回调, 主页需要等待 HTTP 响应
	if (b_StatsSourceEnabled) StartStatsQuery(client);
	if (b_ProfileSourceEnabled) RequestProfileGametime(client);

	OnSourceUpdate(client);
}

// 主页/成就数据晚于另一数据源到达时, 补播一次包含两个时长的完整信息
void OnSourceUpdate(int client, bool bNewData = false)
{
	if (!IsValidClient(client)) return;

	UpdatePlayerTimeState(client);

	// 准入判定必须放在"SteamID 未验证就直接 return"之前:
	// ResolvePendingGate 内部自己会判断验证状态, 但放在这里能保证数据一到就立刻给结论
	ResolvePendingGate(client);

	// SteamID 未通过两个验证流程的玩家: 不播报时长, 也不做任何限制
	if (!IsClientSteamVerified(client)) return;

	if (i_PlayerTime[client] > 0 && (!b_Announced[client] || bNewData))
	{
		AnnouncePlayerTime(client);
	}

	LimitPlayer(client);
}

// 汇总两个数据源, 刷新用于限制/native 的生效时长: >0 成功, -1 获取中, -2 获取失败
// 补充一种情况: 所有数据源都查完了, 而主页接口明确返回了 0 分钟(新号从没玩过)时保持 0, 不降级成 -2。
// 原因: -2 表示"查不到", 而 0 是"查到了, 就是 0 小时" —— 后者恰恰是准入下限要拦的人,
// 若混成 -2 就会按"查不到不误踢"的逻辑被放行, 等于功能对 0 小时新号完全失效。
void UpdatePlayerTimeState(int client)
{
	if (i_StatTime[client] > 0) i_PlayerTime[client] = i_StatTime[client];
	else if (i_ProfileTime[client] > 0) i_PlayerTime[client] = i_ProfileTime[client];
	else if (!AllSourcesFinished(client)) i_PlayerTime[client] = -1;
	else if (b_KnownZero[client]) i_PlayerTime[client] = 0;	// 查到了, 确实 0 小时
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

	if (i_CheckPlayerGameCount > 0)
	{
		i_StatsUserID[client] = userid;
		CreateTimer(1.0, MoreGetPlayerGameTime, userid, TIMER_FLAG_NO_MAPCHANGE);
	}
	else
	{
		i_StatState[client] = SOURCE_FAILED;
	}
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
	// 这里刻意不把"成就 cell 读到 0"记成 b_KnownZero:
	// Steam 的 stat cell 在某些情况下会返回 0 而玩家其实有上千小时(stat 未同步/被重置),
	// 若据此判定就会把老玩家误踢 —— 误踢的代价远大于放进一个新号。
	// 所以"确实 0 小时"只采信主页接口 playtime_forever=0(见 OnProfileHTTPCompleted), 那里有明确字段。

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
					// 记下"明确读到 0 分钟", 供准入判定区分"真的没玩过"和"取不到数据"
					b_KnownZero[client] = (iMinutes <= 0);
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
#if DEBUG
		PrintToServer("[GetPlayerGametime] %N 主页时长查询失败 (http:%d failure:%d successful:%d)", client, eStatusCode, bFailure, bRequestSuccessful);
#endif
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
	// 返回 true 表示"确实读到了 playtime_forever 字段", 值可能是 0.
	// 0 和"读取失败"必须区分: 0 小时的玩家正是准入下限要拦的人.
	return true;
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
#if DEBUG
	CPrintToChatAll("Command executed successfully");
#endif
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
	int client	= GetClientOfUserId(event.GetInt("userid"));

	// 准入下限的时序处理放在最前面: 这套判定与 LimitPlayer(禁止区间) 是两套独立语义,
	// 即使 LimitPlayer=0 也必须能压住"待判定"玩家, 所以不能放到下面的 b_LimitPlayer 早退之后。
	// 玩家试图上生还者(2)/特感(3)队时, 若时长还没到手就把她压回旁观。
	if (IsValidClient(client) && !IsFakeClient(client))
	{
		HoldPendingClient(client);
	}

	if (!b_Enable || !b_LimitPlayer) return;
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

/* ============================ 准入下限 (LimitPlayerRequireMinHours) ============================
 *
 * 与上面的 LimitPlayer(禁止区间: Min < time < Max) 是两套独立语义, 互不覆盖:
 *   LimitPlayer             = "落在区间里就限制"
 *   LimitPlayerRequireMinHours = "低于这个小时数就踢", 即"准入下限"
 *
 * 为什么需要单独一套: 原来的判定是区间内才限制, 表达不了"不足 X 小时一律不许进";
 * 而且它用严格 >, 0 小时/恰好 X 小时的边界会歪, 也无法表达"没有下限、只有下限"。
 *
 * 时序为什么这么绕(核心难点): 游戏时长是异步请求(SteamWorks 向 Steam Web API 要)完成的,
 * 玩家连接瞬间拿不到时长, 所以不能在连接时立刻判定。做法是:
 *   1) 玩家连接后立刻进入"待判定"状态 b_PendingGate=true;
 *   2) 数据到手前, 每次 player_team 试图上 2/3 队都压回旁观(HoldPendingClient);
 *      玩家没试图上队就什么都不用做, 不会打扰她;
 *   3) 有一个看门狗计时器(GateWatchdog)兜底, 防止响应丢失导致永远卡在待判定;
 *   4) 数据到手后 ResolvePendingGate: 不达标 -> 踢出 + 日志; 达标 -> 清标记放行。
 * 任何一条路径都会清掉待判定标记, 所以不会出现"永远卡在旁观", 也不会重复踢。
 * ====================================================================================== */

// 把一个"待判定"玩家压回旁观。重入保护用独立标记 b_IsHoldingPending,
// 不去改 b_IsProcessingLimitPlayer 的语义(那个是给原 LimitPlayer 用的)。
void HoldPendingClient(int client)
{
	if (!b_PendingGate[client]) return;
	if (b_IsHoldingPending[client]) return;
	if (!IsValidClient(client) || IsFakeClient(client)) return;
	if (!IsClientConnected(client)) return;

	// 运行期把功能关掉/SteamWorks 掉了: 立刻停止拦截并释放标记, 不能继续压着玩家
	if (!IsRequireGateEnabled())
	{
		// 功能被关掉属于"管理员决定不限制", 不是"你通过验证", 所以不发通过提示
		ReleasePendingGate(client, false);
		return;
	}

	// 玩家本来就在旁观队: 不需要动她。这同时覆盖了"玩家一直没自动上队就无需动作"的情况
	int iTeam = GetClientTeam(client);
	if (iTeam != 2 && iTeam != 3) return;

	b_IsHoldingPending[client] = true;
	// ChangeClientTeam 会同步再触发一次 player_team 事件, 靠上面的 b_IsHoldingPending 挡住递归
	ChangeClientToSpec(client);
	b_IsHoldingPending[client] = false;

	// ChangeClientToSpec 在玩家已断线时会直接 return, 所以只有真的回到 1 队才算"压过"
	if (IsValidClient(client) && IsClientConnected(client) && GetClientTeam(client) == 1)
	{
		b_GateForcedSpec[client] = true;
		if (!b_GateHoldAnnounced[client])
		{
			b_GateHoldAnnounced[client] = true;
			CPrintToChat(client, "%t", "gateplayerPending", float(i_LimitPlayerRequireMinGametime) / SECONDS_PER_HOUR);
		}
	}
}

// 数据到手(或确认失败)后给结论: 不达标踢出, 达标放行。每条连接只走一次。
void ResolvePendingGate(int client)
{
	if (!b_PendingGate[client]) return;
	if (!IsValidClient(client) || IsFakeClient(client)) return;
	// KickClient 在玩家 IsClientConnected=false 时会静默失败(踢不出去却以为踢了),
	// 所以判定前必须确认连接还在; 连接已断就不用再判, 标记由 OnClientDisconnect 清理
	if (!IsClientConnected(client)) return;
	// SteamID 还没验证完就不下结论(否则会把"等待验证"误判成"取不到时长")
	if (!IsClientSteamVerified(client)) return;
	// -1 = 时长仍在请求中: 既不能下结论也不能踢, 交给看门狗或下一次 OnSourceUpdate
	if (i_PlayerTime[client] == -1) return;

	// "明确读到 0 小时"是有效数据, 不是"还没查完":
	// UpdatePlayerTimeState 会把 0 秒存成 i_PlayerTime=0, 而 0 同时也是"尚未查询"的初值,
	// 所以必须靠 AllSourcesFinished + b_KnownZero 两个条件一起才认。
	// 新号(0 小时)正是本功能要拦的人, 若把它当成"取不到数据"就会直接放行, 等于没生效。
	bool bKnownZero = (i_PlayerTime[client] == 0) && AllSourcesFinished(client) && b_KnownZero[client];
	if (i_PlayerTime[client] == 0 && !bKnownZero) return;	// 还没查完, 等下次

	b_PendingGate[client] = false;
	b_GateResolved[client] = true;	// 结论已出: 之后 ConVar 变更重查时长不会再把该玩家压回旁观

	if (bKnownZero)
	{
		// 0 秒 <= 阈值(阈值恒 > 0), 必然不达标: 按"时长不足"踢出
		b_GateKicked[client] = true;
		KickClient(client, "%t", "kickplayerRequireMinHours", float(i_LimitPlayerRequireMinGametime) / SECONDS_PER_HOUR);
		LogKickPlayer(client, 3);
		return;
	}

	if (i_PlayerTime[client] > 0)
	{
		// 边界语义(用户口径"游戏时长不超过 10 小时不许进"):
		//   i_PlayerTime <= 阈值 一律拦下, 阈值 = round(10.0 * 3600) = 36000 秒。
		// 即"恰好 10.00 小时"也算不足、会被踢; 必须严格大于 36000 秒才放行。
		if (i_PlayerTime[client] <= i_LimitPlayerRequireMinGametime)
		{
			b_GateKicked[client] = true;
			// KickClient 内部会把翻译目标设为该玩家, 所以直接用 %t 就是玩家自己的语言
			KickClient(client, "%t", "kickplayerRequireMinHours", float(i_LimitPlayerRequireMinGametime) / SECONDS_PER_HOUR);
			LogKickPlayer(client, 3);
			return;
		}

		// 达标: 放行。之前被压过旁观的给一句提示, 告诉她现在可以进队了
		if (b_GateForcedSpec[client] && IsClientConnected(client))
		{
			CPrintToChat(client, "%t", "gateplayerPassed");
		}
		b_GateForcedSpec[client] = false;
		return;
	}

	// 走到这里说明 i_PlayerTime == -2: 所有已启用的数据源都失败了, 手里没有任何时长可比。
	// 这里必须显式守住: 默认(LPMWFailureGet=0)一律不踢! 否则 Steam Web API 一挂,
	// 全服玩家都会变成"取不到时长"然后被批量踢掉 —— 这是本功能最危险的误伤路径。
	// 宁可放进一个时长不够的玩家, 也不能因为查不到就把所有人踢了。
	// 需要"查不到也踢"的服务器可以显式把 LPMWFailureGet 设成 1(沿用原有语义与文案)。
	b_GateForcedSpec[client] = false;
	if (i_LPMWFailureGet == 1)
	{
		b_GateKicked[client] = true;
		KickClient(client, "%t", "kickplayerFailureGet");
		LogKickPlayer(client, 1);
	}
}

// 清掉待判定状态并标记本连接已得出结论(放行语义)。所有"不下结论就放弃拦截"的路径都走这里,
// 保证标记一定被清掉 —— 这是"不会永远卡在旁观"的关键。
void ReleasePendingGate(int client, bool bAnnounce = true)
{
	bool bWasHeld = b_GateForcedSpec[client];

	b_PendingGate[client]	 = false;
	b_GateForcedSpec[client] = false;
	b_GateResolved[client]	 = true;

	// 只有真的被压过旁观才需要提示, 否则会打扰正常进队的玩家
	if (bAnnounce && bWasHeld && IsValidClient(client) && IsClientConnected(client))
	{
		CPrintToChat(client, "%t", "gateplayerPassed");
	}
}

// 看门狗: 兜底处理"一直等不到结论"的待判定玩家。
// 没有它的话, 万一 SteamWorks 回调丢失(玩家断网/Steam 抽风/重试链被 early return 掉),
// 玩家会永远带着待判定标记被压在旁观 —— 这正是"不能永远卡在旁观"要求的兜底。
// 超时后按"取不到数据"处理, 与 LPMWFailureGet 语义完全一致(默认放行), 绝不误踢。
void GateWatchdog(int client)
{
	if (!IsValidClient(client) || IsFakeClient(client)) return;
	if (!IsClientConnected(client)) return;	// 连接已断: 不再判定, 标记交给 OnClientDisconnect
	if (!b_PendingGate[client]) return;
	// 功能在等待期间被关掉了: 释放标记, 不要留下残余的"待判定"
	if (!IsRequireGateEnabled())
	{
		ReleasePendingGate(client, false);
		return;
	}

	// SteamID 一直没通过验证(玩家卡在连接阶段 / 验证失败): 绝不下结论也绝不踢,
	// 直接清标记放行 —— 没有时长数据时唯一安全的处理就是"不拦"。
	if (!IsClientSteamVerified(client))
	{
		LogMessage("[GetPlayerGametime] %N 的准入判定超时: SteamID 始终未通过验证, 已放行(不做限制).", client);
		ReleasePendingGate(client);
		return;
	}

	// 数据其实已经到手, 只是没触发到判定: 补一次结论。
	// 判据与 ResolvePendingGate 完全一致(含"明确读到 0 小时"的情况), 否则会出现
	// "看门狗以为没数据就放行, 而实际数据是 0 小时本该踢"的不一致
	if (i_PlayerTime[client] > 0 || i_PlayerTime[client] == -2
		|| (i_PlayerTime[client] == 0 && b_KnownZero[client] && AllSourcesFinished(client)))
	{
		ResolvePendingGate(client);
		return;
	}

	LogMessage("[GetPlayerGametime] %N 的准入判定超时(时长仍在请求中), 按取不到数据处理, 避免永久卡在旁观.", client);

	// 注意顺序: 先踢后放行。ReleasePendingGate 只负责清标记和"可以进队"提示,
	// 而"查不到是否踢人"由 LPMWFailureGet 决定(默认 0 = 不踢)。
	if (i_LPMWFailureGet == 1)
	{
		b_PendingGate[client]	 = false;
		b_GateForcedSpec[client] = false;
		b_GateResolved[client]	 = true;
		b_GateKicked[client]	 = true;
		KickClient(client, "%t", "kickplayerFailureGet");
		LogKickPlayer(client, 1);
		return;
	}

	ReleasePendingGate(client);
}

// 准入下限功能当前是否真的可用。任一前提不成立都不启用, 全部为了防误伤:
//  - cvar <= 0(功能关闭)
//  - 插件总开关关闭
//  - SteamWorks 扩展不可用: 此时根本查不到任何时长, 全员都会变成"取不到", 绝不能据此踢人
//  - 没有任何可用数据源: 同上
//  - 插件晚加载 && LPLateload=1: 沿用原有"晚加载不限制"的保护
bool IsRequireGateEnabled()
{
	if (!b_Enable) return false;
	if (!b_LimitPlayerRequireEnabled) return false;
	if (!b_SteamWorksAvailable) return false;
	if (!b_StatsSourceEnabled && !b_ProfileSourceEnabled) return false;
	if (b_LPLateload && CheckPluginLate) return false;
	return true;
}

// 看门狗超时秒数: 单次请求约 10s(HTTP timeout) / 重试间隔 1s, 按最大重试次数估算并留余量。
// 只用已启用的数据源算, 与 GetRequestMaxCount() 口径一致。
float GetGateTimeout()
{
	int iMaxCount = GetRequestMaxCount();
	if (iMaxCount < 1) iMaxCount = 1;
	float fTimeout = float(iMaxCount) * (GATE_RETRY_STEP + GATE_HTTP_TIMEOUT);
	if (fTimeout < GATE_TIMEOUT_MIN) fTimeout = GATE_TIMEOUT_MIN;
	if (fTimeout > GATE_TIMEOUT_MAX) fTimeout = GATE_TIMEOUT_MAX;
	return fTimeout;
}

// 玩家验证完成 / 开始查询时长时进入"待判定"状态, 并起一个看门狗
void StartPendingGate(int client)
{
	if (!IsValidClient(client) || IsFakeClient(client)) return;
	if (!IsRequireGateEnabled()) return;
	// 本连接已经得出结论就不再重复: ConVarChanged 会把全服玩家重新走一遍 OnClientPostAdminCheck,
	// 没有这个判断的话, 已经放行、正在玩的玩家会被重新置成"待判定"并压回旁观(严重误伤)
	if (b_GateResolved[client]) return;
	if (b_PendingGate[client]) return;
	if (b_GateKicked[client]) return;

	b_PendingGate[client]	  = true;
	b_GateForcedSpec[client]  = false;
	b_GateHoldAnnounced[client] = false;

	// 兜住"标记设好之前就已经在 2/3 队"的情况(例如玩家验证很快、直接占了生还者位):
	// 光靠 player_team 事件是接不住的, 因为那次事件已经过去了
	HoldPendingClient(client);

	CreateTimer(GetGateTimeout(), TimerGateWatchdog, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

Action TimerGateWatchdog(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);
	if (!client) return Plugin_Stop;	// 玩家已离开: userid 不匹配, 新连接不会被误伤
	GateWatchdog(client);
	return Plugin_Stop;
}

bool CheckPlayerGametime(int client)
{
#if DEBUG
	PrintToChatAll("Check Player %N Gametime", client);
#endif
	if (i_PlayerTime[client] > i_LimitPlayerMinGametime && i_PlayerTime[client] < i_LimitPlayerMaxGametime)
	{
#if DEBUG
		CPrintToChatAll("%d %d %d %N,CheckPlayerGametime is ture", i_PlayerTime[client], i_LimitPlayerMinGametime, i_LimitPlayerMaxGametime, client);
#endif
		return true;
	}
#if DEBUG
	CPrintToChatAll("%d %d %d %N,CheckPlayerGametime is false", i_PlayerTime[client], i_LimitPlayerMinGametime, i_LimitPlayerMaxGametime, client);
#endif
	return false;
}

/*
void CheckPlayerGametime(int client)
{
	#if DEBUG
	PrintToChatAll("Check Player %N Gametime",client);
	#endif
	if (i_PlayerTime[client] > i_LimitPlayerMinGametime && i_PlayerTime[client] < i_LimitPlayerMaxGametime && (i_LimitPlayerMode != 0))
	{
		if(b_LPLateload && CheckPluginLate)return;
		#if DEBUG
		CPrintToChatAll("%d %d %d %N,CheckPlayerGametime is ture", i_PlayerTime[client], i_LimitPlayerMinGametime, i_LimitPlayerMaxGametime, client);
		#endif
		if (i_LimitPlayerMode == 1)
		{
			float f_LimitPlayerMinGametime = float(i_LimitPlayerMinGametime) / 3600;
			float f_LimitPlayerMaxGametime = float(i_LimitPlayerMaxGametime) / 3600;
			// KickClient(client, "你因游戏时长不符合服务器规则(%.2f - %.2f)而被自动踢出!",i_LimitPlayerMinGametime,i_LimitPlayerMaxGametime);
			KickClient(client, "%t", "kickplayerUnqualified", f_LimitPlayerMinGametime, f_LimitPlayerMaxGametime);
			LogKickPlayer(client, 2);
		}
		else
		{
			ChangeClientToSpec(client);
			// CPrintToChatAll("{green}[{olive}!{green}]{default}玩家{olive} %N 因游戏时长不符合服务器规则而被强制移动到旁观!", client);
			CPrintToChatAll("%t", "forcespecplayerUnqualified", client);
		}
	}
	#if DEBUG
	CPrintToChatAll("%d %d %d %N,CheckPlayerGametime is false", i_PlayerTime[client], i_LimitPlayerMinGametime, i_LimitPlayerMaxGametime, client);
	#endif
}
*/
void LimitPlayer(int client)
{
	// 防重入: ChangeClientToSpec 移动玩家时会触发 player_team 事件重入本函数,无限递归导致栈溢出
	if (b_IsProcessingLimitPlayer[client]) return;
	if (!IsValidClient(client)) return;
	if (!b_Enable || !b_LimitPlayer || i_PlayerTime[client] == 0) return;
	// SteamID 未通过两个验证流程的玩家, 不返回时长也不做限制(不误判为获取失败)
	if (!IsClientSteamVerified(client)) return;
	// 无可用数据源时不做任何限制
	if (!b_StatsSourceEnabled && !b_ProfileSourceEnabled) return;

	b_IsProcessingLimitPlayer[client] = true;
	LimitPlayerInner(client);
	b_IsProcessingLimitPlayer[client] = false;
}

void LimitPlayerInner(int client)
{
#if DEBUG
	PrintToChatAll("%N i_PlayerTime=%d", client, i_PlayerTime[client]);
#endif
	if (i_PlayerTime[client] == -1)
	{
		if (GetRequestCount(client) < GetRequestMaxCount())
		{
			if (!b_LPWRequesting || (b_LPLateload && CheckPluginLate)) return;
			ChangeClientToSpec(client);
			CPrintToChatAll("%t", "forcespecplayerRequesting", client, GetRequestCount(client), GetRequestMaxCount());
		}
		else
		{
			CPrintToChatAll("%t", "RequestingPlayerGametime", client, GetRequestCount(client) + 1, GetRequestMaxCount());
		}
	}
	else if (i_PlayerTime[client] == -2)
	{
		if ((GetRequestCount(client) >= GetRequestMaxCount()) && (i_LPMWFailureGet != 0))
		{
			if (b_LPLateload && CheckPluginLate) return;
			if (i_LPMWFailureGet == 1)
			{
				KickClient(client, "%t", "kickplayerFailureGet");
				LogKickPlayer(client, 1);
			}
			else if (i_LPMWFailureGet == 2)
			{
				ChangeClientToSpec(client);
				CPrintToChatAll("%t", "forcespecplayerFailureGet", client);
			}
		}
		else if ((GetRequestCount(client) >= GetRequestMaxCount()) && (i_LPMWFailureGet == 0))
		{
			CPrintToChatAll("%t", "FailureGetPlayerGametime", client);
		}
	}
	else if (CheckPlayerGametime(client) && (i_LimitPlayerMode != 0))
	{
#if DEBUG
		PrintToChatAll("Check b_LPLateload && CheckPluginLate: %d&&%d", b_LPLateload, CheckPluginLate);
#endif
		if (b_LPLateload && CheckPluginLate) return;
#if DEBUG
		PrintToChatAll("LimitPlayerMode is %d", i_LimitPlayerMode);
		PrintToChatAll("try to handle %N", client);
#endif
		if (i_LimitPlayerMode == 1)
		{
			float f_LimitPlayerMinGametime = float(i_LimitPlayerMinGametime) / SECONDS_PER_HOUR;
			float f_LimitPlayerMaxGametime = float(i_LimitPlayerMaxGametime) / SECONDS_PER_HOUR;
			KickClient(client, "%t", "kickplayerUnqualified", f_LimitPlayerMinGametime, f_LimitPlayerMaxGametime);
			LogKickPlayer(client, 2);
		}
		else
		{
			ChangeClientToSpec(client);
			CPrintToChatAll("%t", "forcespecplayerUnqualified", client);
		}
	}
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
#if DEBUG
		PrintToChatAll("%N stat:%d profile:%d", client, i_StatTime[client], i_ProfileTime[client]);
#endif
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
		// 晚加载时已经在服里的玩家不进入"待判定": 他们已经在玩了, 突然压回旁观会打断对局。
		// 这也是 IsRequireGateEnabled() 里 "b_LPLateload && CheckPluginLate 直接返回 false" 的同一保护;
		// 这里再显式标记一次, 防止之后 cvar 变更重查时长时把他们压回旁观。
		if (IsClientInGame(i) && !IsFakeClient(i)) b_GateResolved[i] = true;
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

// 准入下限的踢出日志(Mode=3), 复用同样的日志文件
void LogKickPlayer(int client, int Mode)
{
	if (b_IfNeedLogKickMsg)
	{
		char Msg[256], Time[32];
		IsCreateLogFile();
		FormatTime(Time, sizeof(Time), "%Y-%m-%d %H:%M:%S", -1);
		char KickMsg[220];
		if (Mode == 1) Format(KickMsg, sizeof(KickMsg), "%N were auto kicked because failed to get playtime!", client);
		else if (Mode == 3)
		{
			// 准入下限踢出: 记录实际时长和门槛, 便于事后申诉/核对
			float gametime = float(i_PlayerTime[client]) / SECONDS_PER_HOUR;
			Format(KickMsg, sizeof(KickMsg), "%N kicked by gate : %.2fh (require > %.2f h)!", client, gametime, f_LimitPlayerRequireMinHours);
		}
		else
		{
			float f_LimitPlayerMinGametime = float(i_LimitPlayerMinGametime) / SECONDS_PER_HOUR;
			float f_LimitPlayerMaxGametime = float(i_LimitPlayerMaxGametime) / SECONDS_PER_HOUR;
			float gametime				   = float(i_PlayerTime[client]) / SECONDS_PER_HOUR;
			Format(KickMsg, sizeof(KickMsg), "%N kicked : %.2fh (%.2f h - %.2f h)!", client, gametime, f_LimitPlayerMinGametime, f_LimitPlayerMaxGametime);
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
