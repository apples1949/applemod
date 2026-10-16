/*
 *	l4d2_si_respawn - 接管玩家特感（SI）的复活计时（无提示、无输出）
 *
 *	规则（模式配置可改）：
 *	  基准 = 每回合随机取 [base_min, base_max]（默认 16~18 秒）
 *	  感染者玩家不足 infected_ref（默认 12）人：每少 1 人 per_missing（默认 -1 秒）
 *	  生还者倒地：每人 per_incapped（默认 +1 秒）
 *	  生还者死亡：每人 per_dead（默认 +2 秒）
 *	  例：10 名感染者玩家（少 2 人）、1 人倒地、1 人死亡，基准 16~18 ⇒ 16~18 -2 +1 +2
 *	  低于 min_value（默认 5 秒）时取下限
 *
 *	接管方式（Left4DHooks）：
 *	  1) SI 玩家死亡时按当时人数算出目标等待，写入 L4D_SetBecomeGhostAt（引擎自己的倒计时跟着走）
 *	  2) L4D_OnEnterGhostStatePre 里兜底：还没到时长的直接拦住，防止引擎提前放行
 *	  3) 1 秒兜底计时器：到点仍未进入 ghost 的，用 L4D_BecomeGhost 推一把，避免被永久卡死
 *	  4) 进入 ghost / 复活成功 / 掉线 / 换图 都会清理状态
 *
 *	不注册 cfg（不用 AutoExecConfig），参数由模式配置指定；不打印任何文字。
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <left4dhooks>

#define PLUGIN_VERSION "1.0.0"

#define TEAM_SURVIVOR 2
#define TEAM_INFECTED 3

ConVar g_hEnable;
ConVar g_hBaseMin;
ConVar g_hBaseMax;
ConVar g_hInfectedRef;
ConVar g_hPerMissing;
ConVar g_hPerIncapped;
ConVar g_hPerDead;
ConVar g_hCountAI;
ConVar g_hMinValue;

int   g_iBase;
float g_fGhostAt[MAXPLAYERS + 1];
bool  g_bPending[MAXPLAYERS + 1];
Handle g_hSafetyTimer;

public Plugin myinfo =
{
	name = "l4d2_si_respawn",
	author = "apples1949",
	description = "玩家特感复活时长：基准 16~18 秒，按双方人数动态增减（无输出）",
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
	g_hEnable      = CreateConVar("l4d2_sirespawn_enable", "1", "1=接管 SI 复活计时；0=不管", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hBaseMin     = CreateConVar("l4d2_sirespawn_base_min", "16", "基准时长下限（秒）", FCVAR_NOTIFY, true, 0.0, true, 120.0);
	g_hBaseMax     = CreateConVar("l4d2_sirespawn_base_max", "18", "基准时长上限（秒）", FCVAR_NOTIFY, true, 0.0, true, 120.0);
	g_hInfectedRef = CreateConVar("l4d2_sirespawn_infected_ref", "12", "感染者参考人数（少于此数开始扣秒）", FCVAR_NOTIFY, true, 0.0, true, 32.0);
	g_hPerMissing  = CreateConVar("l4d2_sirespawn_per_missing_infected", "-1.0", "每少 1 名感染者玩家的秒数变化", FCVAR_NOTIFY, true, -30.0, true, 30.0);
	g_hPerIncapped = CreateConVar("l4d2_sirespawn_per_incapped", "1.0", "每名倒地的生还者增加秒数", FCVAR_NOTIFY, true, -30.0, true, 30.0);
	g_hPerDead     = CreateConVar("l4d2_sirespawn_per_dead", "2.0", "每名死亡的生还者增加秒数", FCVAR_NOTIFY, true, -30.0, true, 30.0);
	g_hCountAI     = CreateConVar("l4d2_sirespawn_count_ai", "0", "0=只统计真人玩家；1=连 AI（bot）一起统计", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hMinValue    = CreateConVar("l4d2_sirespawn_min", "5.0", "计算结果下限（秒）", FCVAR_NOTIFY, true, 0.0, true, 120.0);

	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);

	g_hSafetyTimer = CreateTimer(1.0, Timer_SafetyTick, _, TIMER_REPEAT);

	PickBase();
}

public void OnMapStart()
{
	PickBase();
	for (int i = 1; i <= MaxClients; i++)
	{
		g_bPending[i] = false;
		g_fGhostAt[i] = 0.0;
	}
}

public void OnClientDisconnect(int client)
{
	g_bPending[client] = false;
	g_fGhostAt[client] = 0.0;
}

public void OnPluginEnd()
{
	delete g_hSafetyTimer;
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	PickBase();
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
		return;

	float fDelay = ComputeDelay();
	g_fGhostAt[client] = GetGameTime() + fDelay;
	g_bPending[client] = true;

	// 让引擎自己的倒计时也按我们的时长走
	L4D_SetBecomeGhostAt(client, g_fGhostAt[client]);
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
	if (fValue < fMin)
		fValue = fMin;

	return fValue;
}

void PickBase()
{
	int iMin = g_hBaseMin.IntValue;
	int iMax = g_hBaseMax.IntValue;
	if (iMax < iMin)
		iMax = iMin;

	g_iBase = GetRandomInt(iMin, iMax);
}

public Action L4D_OnEnterGhostStatePre(int client)
{
	if (!g_hEnable.BoolValue || !g_bPending[client])
		return Plugin_Continue;

	// 还没到算出来的时刻：拦住，别让引擎提前进 ghost
	if (GetGameTime() < g_fGhostAt[client])
		return Plugin_Handled;

	return Plugin_Continue;
}

public void L4D_OnEnterGhostState(int client)
{
	g_bPending[client] = false;
}

public void L4D_OnMaterializeFromGhost(int client)
{
	g_bPending[client] = false;
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
			g_bPending[i] = false;
			continue;
		}

		// 到点了还没进 ghost：推一把，避免被永久卡在死亡状态
		if (fNow >= g_fGhostAt[i])
		{
			g_bPending[i] = false;
			if (IsPlayerAlive(i) == false)
				L4D_BecomeGhost(i);
		}
	}

	return Plugin_Continue;
}
