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
#define ZC_TANK                 8

#define INFECTED_PLAYER_LIMIT   3

char g_szClassNames[ZC_CHARGER + 1][] =
{
	"", "Smoker", "Boomer", "Hunter", "Spitter", "Jockey", "Charger"
};

bool g_bSurvivorsLeftSafeArea;
bool g_bSwitchAvailable;
bool g_bAttack2[MAXPLAYERS + 1];
bool g_bHintShown[MAXPLAYERS + 1];

public Plugin myinfo =
{
	name = "L4D2 SI Right Click Switch",
	author = "apples1949",
	description = "Survivors left safe area and infected players (player tank excluded) < 3: switch SI class by right click (Left4DHooks)",
	version = "1.3.0",
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
	HookEvent("player_team", Event_PlayerTeam, EventHookMode_Post);
	CreateTimer(0.5, Timer_CheckSwitchAvailability, _, TIMER_REPEAT);

	if (GetFeatureStatus(FeatureType_Native, "L4D_SetClass") != FeatureStatus_Available)
		SetFailState("L4D_SetClass native unavailable, is Left4DHooks installed?");
	if (GetFeatureStatus(FeatureType_Native, "L4D_HasAnySurvivorLeftSafeArea") != FeatureStatus_Available)
		SetFailState("L4D_HasAnySurvivorLeftSafeArea native unavailable, is Left4DHooks installed?");
}

public void OnClientDisconnect(int client)
{
	g_bAttack2[client] = false;
	g_bHintShown[client] = false;
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	g_bSurvivorsLeftSafeArea = false;
	g_bSwitchAvailable = false;
	for (int i = 1; i <= MaxClients; i++)
	{
		g_bAttack2[i] = false;
		g_bHintShown[i] = false;
	}
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	if (event.GetInt("team") != 3) return;

	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client <= 0 || client > MaxClients) return;

	// Someone just joined the infected team: prompt immediately (once per
	// eligibility) instead of waiting up to 0.5s for the next timer tick.
	bool bAvailable = g_bSurvivorsLeftSafeArea && CountInfectedPlayers() < INFECTED_PLAYER_LIMIT;
	TryShowSwitchHint(client, bAvailable);
}

void TryShowSwitchHint(int client, bool bAvailable)
{
	if (!bAvailable) return;
	if (!IsSwitchableInfectedPlayer(client)) return;
	if (g_bHintShown[client]) return;

	g_bHintShown[client] = true;
	if (GetPlayerControlledTankClient() > 0)
		PrintHintText(client, "坦克在场, 其余感染者少于 %d 人, 按右键可切换特感", INFECTED_PLAYER_LIMIT);
	else
		PrintHintText(client, "感染者少于 %d 人, 按右键可切换特感", INFECTED_PLAYER_LIMIT);
}

public Action Timer_CheckSwitchAvailability(Handle timer)
{
	if (!g_bSurvivorsLeftSafeArea)
	{
		if (!L4D_HasAnySurvivorLeftSafeArea()) return Plugin_Continue;
		g_bSurvivorsLeftSafeArea = true;
	}

	bool bAvailable = CountInfectedPlayers() < INFECTED_PLAYER_LIMIT;

	// Switching just became available (survivors left safe area, a player tank
	// spawned and no longer counts, or the infected count dropped below the
	// limit again): every eligible ghost gets prompted once.
	if (bAvailable && !g_bSwitchAvailable)
	{
		for (int i = 1; i <= MaxClients; i++)
			g_bHintShown[i] = false;
	}
	g_bSwitchAvailable = bAvailable;

	if (!bAvailable) return Plugin_Continue;

	// Prompt only players that can actually switch right now (non-tank ghosts).
	// Re-prompt a player when they become a switchable ghost later in the round.
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsSwitchableInfectedPlayer(i))
			TryShowSwitchHint(i, true);
		else
			g_bHintShown[i] = false;
	}

	return Plugin_Continue;
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon)
{
	if (!IsEligibleInfectedPlayer(client)) return Plugin_Continue;
	if (IsPlayerControlledTank(client)) return Plugin_Continue;
	if (!g_bSurvivorsLeftSafeArea) return Plugin_Continue;
	if (CountInfectedPlayers() >= INFECTED_PLAYER_LIMIT) return Plugin_Continue;
	if (!GetEntProp(client, Prop_Send, "m_isGhost")) return Plugin_Continue;

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
				g_bHintShown[client] = true; // Don't let the periodic prompt overwrite the switch confirmation.
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

int GetPlayerControlledTankClient()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsPlayerControlledTank(i))
			return i;
	}
	return 0;
}

bool IsPlayerControlledTank(int client)
{
	if (!IsEligibleInfectedPlayer(client)) return false;
	if (!IsPlayerAlive(client)) return false;
	if (GetEntProp(client, Prop_Send, "m_isGhost")) return false;
	return GetEntProp(client, Prop_Send, "m_zombieClass") == ZC_TANK;
}

bool IsSwitchableInfectedPlayer(int client)
{
	if (!IsEligibleInfectedPlayer(client)) return false;
	if (IsPlayerControlledTank(client)) return false;
	if (!GetEntProp(client, Prop_Send, "m_isGhost")) return false;

	int class = GetEntProp(client, Prop_Send, "m_zombieClass");
	return class >= ZC_SMOKER && class <= ZC_CHARGER;
}

int CountInfectedPlayers()
{
	int count;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsEligibleInfectedPlayer(i) && !IsPlayerControlledTank(i))
			count++;
	}
	return count;
}
