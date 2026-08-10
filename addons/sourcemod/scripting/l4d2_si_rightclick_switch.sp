#include <sourcemod>
#include <left4dhooks>

#pragma semicolon 1
#pragma newdecls required

#define ZC_SMOKER               1
#define ZC_BOOMER               2
#define ZC_HUNTER               3
#define ZC_SPITTER              4
#define ZC_JOCKEY               5
#define ZC_CHARGER              6

#define INFECTED_PLAYER_LIMIT   3

char g_szClassNames[ZC_CHARGER + 1][] =
{
	"", "Smoker", "Boomer", "Hunter", "Spitter", "Jockey", "Charger"
};

bool g_bSurvivorsLeftSafeArea;
bool g_bAttack2[MAXPLAYERS + 1];

public Plugin myinfo =
{
	name = "L4D2 SI Right Click Switch",
	author = "apples1949",
	description = "Survivors left safe area and infected players < 3: switch SI class by right click (Left4DHooks)",
	version = "1.1.0",
	url = ""
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	char sGame[12];
	GetGameFolderName(sGame, sizeof(sGame));
	if (!StrEqual(sGame, "left4dead2"))
	{
		strcopy(error, err_max, "Plugin only supports L4D2");
		return APLRes_Failure;
	}
	return APLRes_Success;
}

public void OnPluginStart()
{
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	CreateTimer(0.5, Timer_CheckSafeArea, _, TIMER_REPEAT);

	if (GetFeatureStatus(FeatureType_Native, "L4D_SetClass") != FeatureStatus_Available)
		SetFailState("L4D_SetClass native unavailable, is Left4DHooks installed?");
	if (GetFeatureStatus(FeatureType_Native, "L4D_HasAnySurvivorLeftSafeArea") != FeatureStatus_Available)
		SetFailState("L4D_HasAnySurvivorLeftSafeArea native unavailable, is Left4DHooks installed?");
}

public void OnClientDisconnect(int client)
{
	g_bAttack2[client] = false;
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	g_bSurvivorsLeftSafeArea = false;
	for (int i = 1; i <= MaxClients; i++)
		g_bAttack2[i] = false;
}

public Action Timer_CheckSafeArea(Handle timer)
{
	if (g_bSurvivorsLeftSafeArea) return Plugin_Continue;
	if (!L4D_HasAnySurvivorLeftSafeArea()) return Plugin_Continue;

	g_bSurvivorsLeftSafeArea = true;

	if (CountInfectedPlayers() < INFECTED_PLAYER_LIMIT)
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsEligibleInfectedPlayer(i))
				PrintHintText(i, "感染者少于 %d 人, 按右键可切换特感", INFECTED_PLAYER_LIMIT);
		}
	}

	return Plugin_Continue;
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon)
{
	if (!IsEligibleInfectedPlayer(client)) return Plugin_Continue;
	if (!g_bSurvivorsLeftSafeArea) return Plugin_Continue;
	if (CountInfectedPlayers() >= INFECTED_PLAYER_LIMIT) return Plugin_Continue;

	if (buttons & IN_ATTACK2)
	{
		if (!g_bAttack2[client])
		{
			g_bAttack2[client] = true;

			int class = GetEntProp(client, Prop_Send, "m_zombieClass");
			if (class >= ZC_SMOKER && class <= ZC_CHARGER)
			{
				int next = class % ZC_CHARGER + 1;
				L4D_SetClass(client, next);
				PrintHintText(client, "已切换到 %s (右键继续切换)", g_szClassNames[next]);
			}
		}
	}
	else
	{
		g_bAttack2[client] = false;
	}

	return Plugin_Continue;
}

bool IsEligibleInfectedPlayer(int client)
{
	if (client <= 0 || client > MaxClients) return false;
	if (!IsClientInGame(client)) return false;
	if (IsFakeClient(client)) return false;
	if (GetClientTeam(client) != 3) return false;
	return true;
}

int CountInfectedPlayers()
{
	int count;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsEligibleInfectedPlayer(i))
			count++;
	}
	return count;
}
