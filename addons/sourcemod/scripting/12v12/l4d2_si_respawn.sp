/*
 *	l4d2_si_respawn - 接管玩家特感（SI）的复活计时
 *
 *	规则（模式配置可改）：
 *	  基准 = 每回合随机取 [base_min, base_max]（默认 16~18 秒）
 *	  感染者玩家不足 infected_ref（默认 12）人：每少 1 人 per_missing（默认 -1 秒）
 *	  生还者倒地：每人 per_incapped（默认 +1 秒）
 *	  生还者死亡：每人 per_dead（默认 +2 秒）
 *	  例：10 名感染者玩家（少 2 人）、1 人倒地、1 人死亡，基准 16~18 ⇒ 16~18 -2 +1 +2
 *	  低于 min（默认 5 秒）时取下限
 *
 *	v1.1.0 修复要点（旧版「有时失效 / 感知时长不对」的根因）：
 *	  旧版只在 player_death(Post) 里 L4D_SetBecomeGhostAt，但引擎是在
 *	  game event "ghost_spawn_time" 里才真正把 z_ghost_delay_min/max
 *	  （本模式 confogl.cfg 设 10~16 秒）写进 m_flBecomeGhostAt 并推给客户端 HUD。
 *	  player_death 与 ghost_spawn_time 的先后顺序不稳定：
 *	    · ghost_spawn_time 在后 ⇒ 引擎覆盖掉插件写的值，插件「失效」，
 *	      而 L4D_OnEnterGhostStatePre 仍按插件自己的时刻拦截 ⇒ 玩家卡在 0 秒；
 *	    · ghost_spawn_time 在前 ⇒ HUD 显示 10~16 秒，实际却被拦到 16~18 秒，
 *	      玩家感知「倒计时归零了还进不去」。
 *	  ⇒ 现在以 ghost_spawn_time(Pre) 为主接管点，同时改写事件字段 spawntime
 *	    （客户端 HUD 立刻同步）与引擎内部 m_flBecomeGhostAt，两者永远一致。
 *
 *	接管链路：
 *	  1) ghost_spawn_time(Pre)：算延迟 → 改写 spawntime → L4D_SetBecomeGhostAt
 *	  2) player_death(Post)：兜底再算一次（事件顺序因引擎/插件而异，两条路幂等）
 *	  3) L4D_OnEnterGhostStatePre：到点前拦住，防止引擎提前放行
 *	  4) 1 秒兜底计时器：到点仍未进 ghost 就 L4D_BecomeGhost 推一把（带重试上限）
 *	  5) 进 ghost / 复活 / 掉线 / 换队 / 换图 / 回合起止 都清理状态
 *
 *	l4d2_sirespawn_debug 默认 0 = 完全静默；设 1 才用 LogMessage 记日志。
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <left4dhooks>

#define PLUGIN_VERSION "1.1.0"

#define TEAM_SURVIVOR 2
#define TEAM_INFECTED 3

#define SAFETY_MAX_RETRY 10

ConVar g_hEnable;
ConVar g_hBaseMin;
ConVar g_hBaseMax;
ConVar g_hInfectedRef;
ConVar g_hPerMissing;
ConVar g_hPerIncapped;
ConVar g_hPerDead;
ConVar g_hCountAI;
ConVar g_hMinValue;
ConVar g_hDebug;

int    g_iBase;
float  g_fGhostAt[MAXPLAYERS + 1];
bool   g_bPending[MAXPLAYERS + 1];
bool   g_bOverride[MAXPLAYERS + 1];
int    g_iRetry[MAXPLAYERS + 1];
Handle g_hSafetyTimer;

bool g_bHasSetGhostAt;
bool g_bHasBecomeGhost;

public Plugin myinfo =
{
	name = "l4d2_si_respawn",
	author = "apples1949",
	description = "玩家特感复活时长：基准 16~18 秒，按双方人数动态增减（默认静默，debug 可开日志）",
	version = PLUGIN_VERSION,
	url = "https://github.com/apples1949"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	if (GetEngineVersion() != Engine_Left4Dead2)
		return APLRes_SilentFailure;

	return APLRes_Success;
}

public void OnPluginStart()
{
	g_hEnable      = CreateConVar("l4d2_sirespawn_enable", "1", "1=接管 SI 复活计时；0=完全不管，恢复引擎原生 z_ghost_delay_min/max", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hBaseMin     = CreateConVar("l4d2_sirespawn_base_min", "16", "基准时长随机下限（秒）。每回合开回合时在 [base_min, base_max] 里随机取一个整数值作为基准", FCVAR_NOTIFY, true, 0.0, true, 120.0);
	g_hBaseMax     = CreateConVar("l4d2_sirespawn_base_max", "18", "基准时长随机上限（秒）。小于 base_min 时按 base_min 处理", FCVAR_NOTIFY, true, 0.0, true, 120.0);
	g_hInfectedRef = CreateConVar("l4d2_sirespawn_infected_ref", "12", "感染者参考人数。当前感染者玩家数少于此值时按 per_missing 扣秒；多于或等于此值不扣不加", FCVAR_NOTIFY, true, 0.0, true, 32.0);
	g_hPerMissing  = CreateConVar("l4d2_sirespawn_per_missing_infected", "-1.0", "每少 1 名感染者玩家调整的秒数。负值=扣秒（人少刷得快），0=不按人数调整", FCVAR_NOTIFY, true, -30.0, true, 30.0);
	g_hPerIncapped = CreateConVar("l4d2_sirespawn_per_incapped", "1.0", "每名倒地生还者增加的秒数。0=不因倒地调整，负值=倒地反而加快", FCVAR_NOTIFY, true, -30.0, true, 30.0);
	g_hPerDead     = CreateConVar("l4d2_sirespawn_per_dead", "2.0", "每名死亡生还者增加的秒数。0=不因死亡调整，负值=死亡反而加快", FCVAR_NOTIFY, true, -30.0, true, 30.0);
	g_hCountAI     = CreateConVar("l4d2_sirespawn_count_ai", "0", "0=只统计真人玩家（AI 不计入人数、也不接管 AI 的复活）；1=AI 一起统计并一并接管", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hMinValue    = CreateConVar("l4d2_sirespawn_min", "5.0", "计算结果下限（秒）。无论如何调整都不会低于这个值", FCVAR_NOTIFY, true, 0.0, true, 120.0);
	g_hDebug       = CreateConVar("l4d2_sirespawn_debug", "0", "0=不输出日志（默认）；1=用 LogMessage 记录基准重算/计时启动/实际放行/被跳过及原因", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// ghost_spawn_time 才是引擎真正设定鬼魂倒计时的时机，必须挂 Pre 才能改写 spawntime
	HookEvent("ghost_spawn_time", Event_GhostSpawnTime, EventHookMode_Pre);
	HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
	HookEvent("player_team", Event_PlayerTeam, EventHookMode_Post);

	// Left4DHooks 的这些 native 是 MarkNativeAsOptional 的，旧版本可能没有
	g_bHasSetGhostAt  = (GetFeatureStatus(FeatureType_Native, "L4D_SetBecomeGhostAt") == FeatureStatus_Available);
	g_bHasBecomeGhost = (GetFeatureStatus(FeatureType_Native, "L4D_BecomeGhost") == FeatureStatus_Available);

	if (!g_bHasSetGhostAt)
		LogError("[sirespawn] Left4DHooks 缺少 L4D_SetBecomeGhostAt，引擎倒计时无法同步，只能靠兜底拦截");

	g_hSafetyTimer = CreateTimer(1.0, Timer_SafetyTick, _, TIMER_REPEAT);

	PickBase();

	for (int i = 1; i <= MaxClients; i++)
		ResetClientState(i, "OnPluginStart");
}

public void OnMapStart()
{
	PickBase();
	for (int i = 1; i <= MaxClients; i++)
		ResetClientState(i, "OnMapStart");
}

public void OnClientDisconnect(int client)
{
	ResetClientState(client, "OnClientDisconnect");
}

public void OnPluginEnd()
{
	delete g_hSafetyTimer;
}

/**
 * 清掉某个 client 的全部状态。reason 只用于 debug 日志。
 */
void ResetClientState(int client, const char[] reason)
{
	if (client < 1 || client > MaxClients)
		return;

	if (g_bPending[client] || g_fGhostAt[client] > 0.0)
		LogDbg("清理 client %L 的待复活状态（原因：%s，剩余 %.1f 秒）",
			client, reason, g_fGhostAt[client] - GetGameTime());

	g_bPending[client]  = false;
	g_fGhostAt[client]  = 0.0;
	g_bOverride[client] = false;
	g_iRetry[client]    = 0;
}

void LogDbg(const char[] fmt, any ...)
{
	if (!g_hDebug.BoolValue)
		return;

	char sBuf[256];
	VFormat(sBuf, sizeof(sBuf), fmt, 2);
	LogMessage("[sirespawn] %s", sBuf);
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	PickBase();

	// 新回合所有人都会重生，上一回合遗留的待复活状态必须清掉
	for (int i = 1; i <= MaxClients; i++)
		ResetClientState(i, "round_start");
}

void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	for (int i = 1; i <= MaxClients; i++)
		ResetClientState(i, "round_end");
}

void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client < 1 || client > MaxClients)
		return;

	// 换队后旧的倒计时不再有意义
	ResetClientState(client, "player_team");
}

/**
 * 引擎真正设置鬼魂倒计时的时机。这里改写 spawntime 让客户端 HUD 立刻同步，
 * 同时调 L4D_SetBecomeGhostAt 把内部 m_flBecomeGhostAt 一起改掉。
 */
public Action Event_GhostSpawnTime(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_hEnable.BoolValue)
		return Plugin_Continue;

	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
		return Plugin_Continue;

	if (GetClientTeam(client) != TEAM_INFECTED)
		return Plugin_Continue;

	// 自己调 L4D_SetBecomeGhostAt 会同步再触发一次本事件（引擎内部 FireEvent("ghost_spawn_time")），
	// 靠这个标记断开递归。注意：这里不能直接 return Plugin_Continue —— 否则引擎那次嵌套触发
	// 仍会把 z_ghost_delay 的原始值写进 HUD，覆盖掉外层刚算好的秒数。
	// 所以仍然改写 spawntime，只是跳过「再调一次 SetBecomeGhostAt」这一步。
	if (g_bOverride[client])
	{
		if (g_fGhostAt[client] > 0.0)
		{
			int iRemain = RoundToNearest(g_fGhostAt[client] - GetGameTime());
			if (iRemain < 0)
				iRemain = 0;

			if (event.GetInt("spawntime") != iRemain)
				event.SetInt("spawntime", iRemain);

			return Plugin_Changed;
		}

		return Plugin_Continue;
	}

	if (!g_hCountAI.BoolValue && IsFakeClient(client))
	{
		LogDbg("跳过 %L：AI 且 count_ai=0", client);
		return Plugin_Continue;
	}

	int iEngineTime = event.GetInt("spawntime");
	float fDelay = ComputeDelay();
	ApplyGhostDelay(client, fDelay, "ghost_spawn_time");

	int iNewTime = RoundToNearest(fDelay);
	event.SetInt("spawntime", iNewTime);

	LogDbg("接管 %L：引擎原倒计时 %d 秒 → 插件 %d 秒（内部时刻 %.2f）",
		client, iEngineTime, iNewTime, g_fGhostAt[client]);

	return Plugin_Changed;
}

void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_hEnable.BoolValue)
		return;

	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
		return;

	if (GetClientTeam(client) != TEAM_INFECTED)
		return;

	if (!g_hCountAI.BoolValue && IsFakeClient(client))
	{
		LogDbg("跳过 %L 的死亡事件：AI 且 count_ai=0", client);
		return;
	}

	// 兜底路径：ghost_spawn_time 因任何原因没触发时，这里仍把倒计时接管住
	float fDelay = ComputeDelay();
	ApplyGhostDelay(client, fDelay, "player_death");

	LogDbg("%L 死亡，先按 player_death 记下 %.1f 秒（等 ghost_spawn_time 复核）",
		client, fDelay);
}

/**
 * 把「延迟秒数」同时写进插件状态与引擎内部计时器。
 * 注意：L4D_SetBecomeGhostAt 收的是**绝对时间**（GetGameTime() 基准），不是剩余秒数。
 */
void ApplyGhostDelay(int client, float fDelay, const char[] source)
{
	g_fGhostAt[client] = GetGameTime() + fDelay;
	g_bPending[client] = true;
	g_iRetry[client]   = 0;

	if (!g_bHasSetGhostAt)
		return;

	g_bOverride[client] = true;
	L4D_SetBecomeGhostAt(client, g_fGhostAt[client]);
	g_bOverride[client] = false;

	LogDbg("%L 倒计时已写入引擎（来源 %s，%.1f 秒）", client, source, fDelay);
}

float ComputeDelay()
{
	bool bAI = g_hCountAI.BoolValue;

	int iInfected = 0;
	int iIncapped = 0;
	int iDead = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
			continue;

		if (!bAI && IsFakeClient(i))
			continue;

		int iTeam = GetClientTeam(i);
		if (iTeam == TEAM_INFECTED)
		{
			iInfected++;
		}
		else if (iTeam == TEAM_SURVIVOR)
		{
			if (!IsPlayerAlive(i))
				iDead++;
			else if (GetEntProp(i, Prop_Send, "m_isIncapacitated") != 0)
				iIncapped++;
		}
	}

	int iMissing = g_hInfectedRef.IntValue - iInfected;
	if (iMissing < 0)
		iMissing = 0;

	float fValue = float(g_iBase)
		+ float(iMissing) * g_hPerMissing.FloatValue
		+ float(iIncapped) * g_hPerIncapped.FloatValue
		+ float(iDead) * g_hPerDead.FloatValue;

	float fMin = g_hMinValue.FloatValue;
	bool bClamped = false;
	if (fValue < fMin)
	{
		fValue = fMin;
		bClamped = true;
	}

	LogDbg("算时长：基准 %d + 缺 %d×%.1f + 倒地 %d×%.1f + 死亡 %d×%.1f = %.1f%s",
		g_iBase, iMissing, g_hPerMissing.FloatValue,
		iIncapped, g_hPerIncapped.FloatValue,
		iDead, g_hPerDead.FloatValue,
		fValue, bClamped ? "（已截到下限）" : "");

	return fValue;
}

void PickBase()
{
	int iMin = g_hBaseMin.IntValue;
	int iMax = g_hBaseMax.IntValue;
	if (iMax < iMin)
		iMax = iMin;

	g_iBase = GetRandomInt(iMin, iMax);

	LogDbg("本回合基准重算：GetRandomInt(%d, %d) = %d", iMin, iMax, g_iBase);
}

public Action L4D_OnEnterGhostStatePre(int client)
{
	if (client < 1 || client > MaxClients)
		return Plugin_Continue;

	if (!g_hEnable.BoolValue || !g_bPending[client])
		return Plugin_Continue;

	// 还没到算出来的时刻：拦住，别让引擎提前进 ghost
	if (GetGameTime() < g_fGhostAt[client])
	{
		LogDbg("拦住 %L 提前进 ghost（还差 %.1f 秒）", client, g_fGhostAt[client] - GetGameTime());
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

public void L4D_OnEnterGhostState(int client)
{
	if (client < 1 || client > MaxClients)
		return;

	LogDbg("%L 进入 ghost 状态，清除待复活标记", client);
	g_bPending[client] = false;
	g_fGhostAt[client] = 0.0;
	g_iRetry[client]   = 0;
}

public void L4D_OnMaterializeFromGhost(int client)
{
	if (client < 1 || client > MaxClients)
		return;

	g_bPending[client] = false;
	g_fGhostAt[client] = 0.0;
	g_iRetry[client]   = 0;
}

Action Timer_SafetyTick(Handle timer)
{
	if (!g_hEnable.BoolValue)
		return Plugin_Continue;

	float fNow = GetGameTime();
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!g_bPending[i])
			continue;

		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_INFECTED)
		{
			ResetClientState(i, "不再是感染者");
			continue;
		}

		// 已经复活/已经进 ghost：没什么可做的
		if (IsPlayerAlive(i) || GetEntProp(i, Prop_Send, "m_isGhost", 1) != 0)
		{
			ResetClientState(i, "已复活或已是 ghost");
			continue;
		}

		if (fNow < g_fGhostAt[i])
			continue;

		// 到点了还没进 ghost：推一把，避免被永久卡在死亡状态
		if (!g_bHasBecomeGhost)
		{
			ResetClientState(i, "到点但缺少 L4D_BecomeGhost");
			continue;
		}

		g_iRetry[i]++;
		if (g_iRetry[i] > SAFETY_MAX_RETRY)
		{
			LogDbg("%L 连续 %d 次推入 ghost 失败，放弃（可能当前不允许刷特感）", i, SAFETY_MAX_RETRY);
			ResetClientState(i, "重试超限");
			continue;
		}

		LogDbg("%L 已到点，第 %d 次推入 ghost", i, g_iRetry[i]);
		L4D_BecomeGhost(i);
	}

	return Plugin_Continue;
}
