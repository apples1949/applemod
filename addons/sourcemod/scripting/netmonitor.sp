#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define PLUGIN_VERSION "1.0.0"

ConVar g_cvEnabled;
ConVar g_cvInterval;
ConVar g_cvLagThreshold;
ConVar g_cvLossThreshold;
ConVar g_cvCooldown;

bool g_bNetIssue[MAXPLAYERS + 1];    // 该玩家当前是否处于网络异常状态
float g_fLastAnnounce[MAXPLAYERS + 1]; // 上次提示时间（防刷屏）

Handle g_hTimer;

public Plugin myinfo =
{
	name        = "NetMonitor 网络状态监测",
	author      = "apples1949",
	description = "每秒检测玩家网络状态，不佳/恢复时提示所有人",
	version     = PLUGIN_VERSION,
	url         = ""
};

public void OnPluginStart()
{
	g_cvEnabled = CreateConVar("sm_netmon_enabled", "1", "是否启用本插件", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvInterval = CreateConVar("sm_netmon_interval", "1.0", "网络状态检测间隔（秒）", FCVAR_NOTIFY, true, 0.1);
	g_cvLagThreshold = CreateConVar("sm_netmon_lag", "0.5", "延迟阈值（秒），超过视为网络异常", FCVAR_NOTIFY, true, 0.01);
	g_cvLossThreshold = CreateConVar("sm_netmon_loss", "0.10", "丢包阈值（0.0-1.0，0.10 = 10%），超过视为网络异常", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvCooldown = CreateConVar("sm_netmon_cooldown", "1.0", "网络异常/恢复提示的最短间隔（秒），防止刷屏", FCVAR_NOTIFY, true, 1.0);

	g_cvInterval.AddChangeHook(OnIntervalChanged);
	StartCheckTimer();
}

void StartCheckTimer()
{
	if (g_hTimer != null)
	{
		KillTimer(g_hTimer);
		g_hTimer = null;
	}
	g_hTimer = CreateTimer(g_cvInterval.FloatValue, Timer_CheckNetwork, _, TIMER_REPEAT);
}

public void OnIntervalChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	StartCheckTimer();
}

public void OnPluginEnd()
{
	if (g_hTimer != null)
	{
		KillTimer(g_hTimer);
	}
}

public void OnClientDisconnect(int client)
{
	g_bNetIssue[client] = false;
	g_fLastAnnounce[client] = 0.0;
}

public Action Timer_CheckNetwork(Handle timer)
{
	if (g_cvEnabled.BoolValue)
	{
		float lagThreshold = g_cvLagThreshold.FloatValue;
		float lossThreshold = g_cvLossThreshold.FloatValue;
		float cooldown = g_cvCooldown.FloatValue;
		float now = GetGameTime();

		for (int i = 1; i <= MaxClients; i++)
		{
			if (!IsClientInGame(i) || IsFakeClient(i))
			{
				continue;
			}

			// 网络信息不可用时返回 -1，跳过以免误报
			float lag = GetClientLatency(i, NetFlow_Both);
			float loss = GetClientAvgLoss(i, NetFlow_Both);
			if (lag < 0.0 || loss < 0.0)
			{
				continue;
			}

			bool bad = (lag > lagThreshold || loss > lossThreshold);
			if (bad == g_bNetIssue[i])
			{
				continue;
			}

			if (now - g_fLastAnnounce[i] >= cooldown)
			{
				char sName[MAX_NAME_LENGTH];
				GetClientName(i, sName, sizeof(sName));
				if (bad)
				{
					PrintToChatAll("\x04%s\x01 网络状况不佳（延迟 %.0f ms，丢包 %.0f%%）", sName, lag * 1000.0, loss * 100.0);
				}
				else
				{
					PrintToChatAll("\x04%s\x01 网络已恢复正常（延迟 %.0f ms，丢包 %.0f%%）", sName, lag * 1000.0, loss * 100.0);
				}
				g_fLastAnnounce[i] = now;
			}
			g_bNetIssue[i] = bad;
		}
	}

	return Plugin_Continue;
}
