#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#include <colors>

#define PLUGIN_VERSION "1.5"

float CONTROL_DELAY_SAFETY             = 0.3;
float CONTROL_RETRY_DELAY              = 2.0;
int TEAM_INFECTED                      = 3;
#define MAX_TANK_ATTEMPTS              5

ConVar cvar_SurrenderTimeLimit         = null;
ConVar cvar_SurrenderChoiceType        = null;
ConVar cvar_SurrenderGhostKill         = null;
ConVar cvar_TankLotteryTime            = null;

Handle surrenderMenu                  = null;
Handle notifyTimer                    = null;
Handle autoMenuTimer                  = null;
Handle timeLimitTimer                 = null;

bool withinTimeLimit                  = false;
int primaryTankPlayer                 = -1;
int tankAttemptsFailed                = 0;
bool g_bIsTankAlive                   = false;
int currentTank                       = 0;

public Plugin myinfo =
{
	name = "L4D Tank Swap",
	author = "AtomicStryker, HarryPotter, Bred",
	description = " Allows a primary Tank Player to surrender control to one of his teammates",
	version = PLUGIN_VERSION,
	url = "https://forums.alliedmods.net/showthread.php?t=326155"
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	if (GetEngineVersion() != Engine_Left4Dead2)
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 2.");
		return APLRes_SilentFailure;
	}

	return APLRes_Success;
}

public void OnPluginStart()
{
	RegConsoleCmd("sm_tankpass", CallSurrenderMenu, "Shows who is becoming the tank.");

	cvar_SurrenderTimeLimit = CreateConVar("l4d_tankswap_timelimit", "15", " 主控坦克玩家可移交控制权的秒数 ", FCVAR_NOTIFY, true, 1.0);
	cvar_SurrenderChoiceType = CreateConVar("l4d_tankswap_choicetype", "2", " 0 - 禁用；1 - 输入 !tankpass 按钮呼出菜单；2 - 每位坦克玩家都会弹出菜单 ", FCVAR_NOTIFY, true, 0.0, true, 2.0);
	cvar_SurrenderGhostKill = CreateConVar("l4d_tankswap_ghostkill", "1", " 0 - 禁用，旧坦克会变成新坦克之前控制的特感（灵魂）；1 - 移交时杀死灵魂 ", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	cvar_TankLotteryTime = FindConVar("director_tank_lottery_selection_time");

	LoadTranslations("common.phrases");
	LoadTranslations("l4d2_tank_swap.phrases");

	HookEvent("tank_spawn", TC_ev_TankSpawn);
	HookEvent("round_start", TC_ev_RoundStart);
	HookEvent("entity_killed", TC_ev_EntityKilled);

	//AutoExecConfig(true, "l4d2_tank_swap");
}

public void OnMapEnd()
{
	ResetRoundState();
}

public void OnClientDisconnect(int client)
{
	if (primaryTankPlayer == client)
	{
		primaryTankPlayer = -1;
		withinTimeLimit = false;

		if (notifyTimer != null)
		{
			KillTimer(notifyTimer);
			notifyTimer = null;
		}

		if (autoMenuTimer != null)
		{
			KillTimer(autoMenuTimer);
			autoMenuTimer = null;
		}

		if (timeLimitTimer != null)
		{
			KillTimer(timeLimitTimer);
			timeLimitTimer = null;
		}

		if (surrenderMenu != null)
		{
			CancelMenu(surrenderMenu);
			surrenderMenu = null;
		}
	}

	// A Tank disconnect does not always fire entity_killed. Make sure a later
	// tank_spawn is not blocked by a stale "tank alive" flag.
	if (g_bIsTankAlive && currentTank == client)
		CreateTimer(0.5, FindAnyTank, 0, TIMER_FLAG_NO_MAPCHANGE);
}

public Action TC_ev_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	ResetRoundState();

	return Plugin_Continue;
}

void ResetRoundState()
{
	if (notifyTimer != null)
	{
		KillTimer(notifyTimer);
		notifyTimer = null;
	}

	if (autoMenuTimer != null)
	{
		KillTimer(autoMenuTimer);
		autoMenuTimer = null;
	}

	if (timeLimitTimer != null)
	{
		KillTimer(timeLimitTimer);
		timeLimitTimer = null;
	}

	if (surrenderMenu != null)
	{
		CancelMenu(surrenderMenu);
		surrenderMenu = null;
	}

	g_bIsTankAlive = false;
	currentTank = 0;
	withinTimeLimit = false;
	primaryTankPlayer = -1;
	tankAttemptsFailed = 0;
}

public Action TC_ev_TankSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int userid = event.GetInt("userid");
	int tankclient = GetClientOfUserId(userid);
	int tankid = event.GetInt("tankid");

	// A duplicate event for the same Tank that we already processed.
	if (tankid != 0 && tankid == currentTank)
		return Plugin_Continue;

	// New Tank: discard anything still pending from the previous Tank.
	if (notifyTimer != null)
	{
		KillTimer(notifyTimer);
		notifyTimer = null;
	}

	if (autoMenuTimer != null)
	{
		KillTimer(autoMenuTimer);
		autoMenuTimer = null;
	}

	if (timeLimitTimer != null)
	{
		KillTimer(timeLimitTimer);
		timeLimitTimer = null;
	}

	if (surrenderMenu != null)
	{
		CancelMenu(surrenderMenu);
		surrenderMenu = null;
	}

	currentTank = tankid;
	g_bIsTankAlive = true;
	withinTimeLimit = false;
	primaryTankPlayer = -1;
	tankAttemptsFailed = 0;

	float PlayerControlDelay = 0.0;
	if (cvar_TankLotteryTime != null)
		PlayerControlDelay = cvar_TankLotteryTime.FloatValue;

	if (IsValidClient(tankclient) && IsFakeClient(tankclient))
	{
		switch (cvar_SurrenderChoiceType.IntValue)
		{
			case 0:     return Plugin_Continue;
			case 1:     notifyTimer = CreateTimer(PlayerControlDelay + CONTROL_DELAY_SAFETY, TS_DisplayNotificationToTank, 0);
			case 2:     autoMenuTimer = CreateTimer(PlayerControlDelay + CONTROL_DELAY_SAFETY, TS_Display_Auto_MenuToTank, 0);
		}
	}
	else
	{
		switch (cvar_SurrenderChoiceType.IntValue)
		{
			case 0:     return Plugin_Continue;
			case 1:     notifyTimer = CreateTimer(CONTROL_DELAY_SAFETY, TS_DisplayNotificationToTank, userid);
			case 2:     autoMenuTimer = CreateTimer(CONTROL_DELAY_SAFETY, TS_Display_Auto_MenuToTank, userid);
		}
	}

	return Plugin_Continue;
}

public Action TS_DisplayNotificationToTank(Handle timer, int clientid)
{
	notifyTimer = null;

	primaryTankPlayer = GetClientOfUserId(clientid);
	if (!IsHumanTank(primaryTankPlayer))
		primaryTankPlayer = FindHumanTankPlayer();

	if (!IsHumanTank(primaryTankPlayer))
	{
		tankAttemptsFailed++;
		if (tankAttemptsFailed < MAX_TANK_ATTEMPTS)
			notifyTimer = CreateTimer(CONTROL_RETRY_DELAY, TS_DisplayNotificationToTank);
		return Plugin_Stop;
	}

	if (cvar_SurrenderChoiceType.IntValue != 1)
		return Plugin_Stop;

	tankAttemptsFailed = 0;
	withinTimeLimit = true;

	float SurrenderTimeLimit = GetSurrenderTimeLimit();
	timeLimitTimer = CreateTimer(SurrenderTimeLimit, TS_TimeLimitIsOver);
	CPrintToChat(primaryTankPlayer, "%t", "Menu_Notice", RoundFloat(SurrenderTimeLimit));
	return Plugin_Stop;
}

public Action TS_TimeLimitIsOver(Handle timer)
{
	timeLimitTimer = null;
	withinTimeLimit = false;

	if (surrenderMenu != null)
	{
		CancelMenu(surrenderMenu);
		surrenderMenu = null;
	}

	return Plugin_Stop;
}

static int FindHumanTankPlayer()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsHumanTank(i))
			return i;
	}

	return 0;
}

bool IsPlayerTank(int client)
{
	if (!IsValidClient(client))
		return false;

	return GetEntProp(client, Prop_Send, "m_zombieClass") == 8;
}

bool IsHumanTank(int client)
{
	return IsValidClient(client)
		&& !IsFakeClient(client)
		&& GetClientTeam(client) == TEAM_INFECTED
		&& IsPlayerTank(client)
		&& IsPlayerAlive(client);
}

public Action CallSurrenderMenu(int client, int args)
{
	if (!IsValidClient(client)
		|| cvar_SurrenderChoiceType.IntValue != 1
		|| !IsHumanTank(client)
		|| client != primaryTankPlayer)
	{
		return Plugin_Handled;
	}

	if (!withinTimeLimit)
	{
		CPrintToChat(client, "%t", "Time_Over");
		return Plugin_Handled;
	}

	if (surrenderMenu != null)
		return Plugin_Handled;

	surrenderMenu = CreateMenu(TS_MenuCallBack);

	char buffer[256];
	Format(buffer, sizeof(buffer), "%T", "Menu_Title", client);
	SetMenuTitle(surrenderMenu, buffer);

	char name[MAX_NAME_LENGTH], number[8];
	int electables;

	Format(buffer, sizeof(buffer), "%T", "Anyone_But_Me", client);
	AddMenuItem(surrenderMenu, "0", buffer);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsEligibleSwapTarget(i)) continue;

		Format(name, sizeof(name), "%N", i);
		Format(number, sizeof(number), "%i", i);
		AddMenuItem(surrenderMenu, number, name);

		electables++;
	}

	if (electables > 0) // only show it if there is someone to swap to
	{
		SetMenuExitButton(surrenderMenu, false);
		if (!DisplayMenu(surrenderMenu, client, RoundToCeil(GetSurrenderTimeLimit())))
		{
			CloseHandle(surrenderMenu);
			surrenderMenu = null;
		}
	}
	else
	{
		CloseHandle(surrenderMenu);
		surrenderMenu = null;
	}

	return Plugin_Handled;
}

public int TS_MenuCallBack(Handle menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_End)
	{
		if (surrenderMenu == menu)
			surrenderMenu = null;
		CloseHandle(menu);
		return 0;
	}

	if (action != MenuAction_Select) return 0; // only allow a valid choice to pass

	if (surrenderMenu != menu)
		return 0;

	if (!withinTimeLimit)
		return 0;

	if (!IsHumanTank(param1) || param1 != primaryTankPlayer)
		return 0;

	char number[8];
	if (!GetMenuItem(menu, param2, number, sizeof(number)))
		return 0;

	int choice = StringToInt(number);
	if (!choice)
	{
		choice = GetRandomEligibleTank();
		if (PerformTankSwap(param1, choice))
			CPrintToChatAll("%t", "Random_Surrend", choice);
	}
	else if (PerformTankSwap(param1, choice))
	{
		CPrintToChatAll("%t", "Surrend", choice);
	}

	return 0;
}

public Action TS_Display_Auto_MenuToTank(Handle timer, int clientid)
{
	autoMenuTimer = null;

	primaryTankPlayer = GetClientOfUserId(clientid);
	if (!IsHumanTank(primaryTankPlayer))
		primaryTankPlayer = FindHumanTankPlayer();

	if (!IsHumanTank(primaryTankPlayer))
	{
		if (!g_bIsTankAlive)
			return Plugin_Stop;

		tankAttemptsFailed++;
		if (tankAttemptsFailed >= MAX_TANK_ATTEMPTS)
			return Plugin_Stop;

		if (HasTeamHumanPlayers(TEAM_INFECTED))
			autoMenuTimer = CreateTimer(CONTROL_RETRY_DELAY, TS_Display_Auto_MenuToTank);
		return Plugin_Stop;
	}

	if (cvar_SurrenderChoiceType.IntValue != 2)
		return Plugin_Stop;

	tankAttemptsFailed = 0;

	if (surrenderMenu != null)
		return Plugin_Stop;

	surrenderMenu = CreateMenu(TS_Auto_MenuCallBack);

	char buffer[256];
	Format(buffer, sizeof(buffer), "%T", "Menu_Title", primaryTankPlayer);
	SetMenuTitle(surrenderMenu, buffer);

	char name[MAX_NAME_LENGTH], number[8];
	int electables;

	Format(buffer, sizeof(buffer), "%T", "Stay_Me", primaryTankPlayer);
	AddMenuItem(surrenderMenu, "0", buffer);
	Format(buffer, sizeof(buffer), "%T", "Anyone_But_Me", primaryTankPlayer);
	AddMenuItem(surrenderMenu, "99", buffer);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsEligibleSwapTarget(i)) continue;

		Format(name, sizeof(name), "%N", i);
		Format(number, sizeof(number), "%i", i);
		AddMenuItem(surrenderMenu, number, name);

		electables++;
	}

	if (electables > 0) // only show it if there is someone to swap to
	{
		SetMenuExitButton(surrenderMenu, false);
		if (!DisplayMenu(surrenderMenu, primaryTankPlayer, RoundToCeil(2.0 * GetSurrenderTimeLimit())))
		{
			CloseHandle(surrenderMenu);
			surrenderMenu = null;
		}
	}
	else
	{
		CloseHandle(surrenderMenu);
		surrenderMenu = null;
	}

	return Plugin_Stop;
}

bool HasTeamHumanPlayers(int team)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i)
			&& GetClientTeam(i) == team
			&& !IsFakeClient(i))
		{
			return true;
		}
	}

	return false;
}

public int TS_Auto_MenuCallBack(Handle menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_End)
	{
		if (surrenderMenu == menu)
			surrenderMenu = null;
		CloseHandle(menu);
		return 0;
	}

	if (action != MenuAction_Select) return 0; // only allow a valid choice to pass

	if (surrenderMenu != menu)
		return 0;

	if (!IsHumanTank(param1) || param1 != primaryTankPlayer)
		return 0;

	char number[8];
	if (!GetMenuItem(menu, param2, number, sizeof(number)))
		return 0;

	int choice = StringToInt(number);
	if (!choice)
	{
		return 0; // "I want to stay Tank"
	}
	else if (choice == 99) // "Anyone but me"
	{
		choice = GetRandomEligibleTank();
		if (PerformTankSwap(param1, choice))
			CPrintToChatAll("%t", "Random_Surrend", choice);
	}
	else if (PerformTankSwap(param1, choice))
	{
		CPrintToChatAll("%t", "Surrend", choice);
	}

	return 0;
}

bool IsPlayerGhost(int client)
{
	return IsValidClient(client) && GetEntProp(client, Prop_Send, "m_isGhost") != 0;
}

static int GetRandomEligibleTank()
{
	int[] pool = new int[MaxClients + 1];
	int count;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsEligibleSwapTarget(i)) continue;

		pool[count++] = i;
	}

	if (!count)
		return 0;

	return pool[GetRandomInt(0, count - 1)];
}

public Action TC_ev_EntityKilled(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_bIsTankAlive)
		return Plugin_Continue;

	int entity = event.GetInt("entindex_killed");
	if (!IsValidClient(entity) || !IsPlayerTank(entity))
		return Plugin_Continue;

	if (entity == currentTank)
		currentTank = 0;

	CreateTimer(1.5, FindAnyTank, 0, TIMER_FLAG_NO_MAPCHANGE);

	return Plugin_Continue;
}

public Action FindAnyTank(Handle timer, int client)
{
	if (!IsTankInGame())
	{
		g_bIsTankAlive = false;
		currentTank = 0;
		tankAttemptsFailed = 0;
		withinTimeLimit = false;

		if (notifyTimer != null)
		{
			KillTimer(notifyTimer);
			notifyTimer = null;
		}

		if (autoMenuTimer != null)
		{
			KillTimer(autoMenuTimer);
			autoMenuTimer = null;
		}

		if (timeLimitTimer != null)
		{
			KillTimer(timeLimitTimer);
			timeLimitTimer = null;
		}

		if (surrenderMenu != null)
		{
			CancelMenu(surrenderMenu);
			surrenderMenu = null;
		}
	}

	return Plugin_Continue;
}

int IsTankInGame(int exclude = 0)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (exclude != i
			&& IsValidClient(i)
			&& GetClientTeam(i) == TEAM_INFECTED
			&& IsPlayerTank(i)
			&& IsInfectedAlive(i)
			&& !IsIncapacitated(i))
		{
			return i;
		}
	}

	return 0;
}

stock bool IsIncapacitated(int client)
{
	return IsValidClient(client) && GetEntProp(client, Prop_Send, "m_isIncapacitated") != 0;
}

stock bool IsInfectedAlive(int client)
{
	return IsValidClient(client) && GetEntProp(client, Prop_Send, "m_iHealth") > 1;
}

stock bool IsValidClient(int client)
{
	return (client > 0 && client <= MaxClients && IsClientInGame(client));
}

bool IsEligibleSwapTarget(int client)
{
	if (!IsValidClient(client)) return false;
	if (client == primaryTankPlayer) return false;
	if (IsFakeClient(client)) return false;
	if (GetClientTeam(client) != TEAM_INFECTED) return false;
	if (IsPlayerTank(client)) return false;
	if (!IsPlayerAlive(client) && !IsPlayerGhost(client)) return false;

	return true;
}

bool PerformTankSwap(int oldTank, int newTank)
{
	if (!IsHumanTank(oldTank) || !IsEligibleSwapTarget(newTank))
		return false;

	if (GetClientHealth(newTank) > 1 && !IsPlayerGhost(newTank))
		L4D_ReplaceWithBot(newTank);

	// Preserves the original manual-menu behavior: after ReplaceWithBot a live
	// target is a ghost, so this is intentionally checked again.
	if (cvar_SurrenderGhostKill.IntValue && IsPlayerGhost(newTank))
		ForcePlayerSuicide(newTank);

	L4D_ReplaceTank(oldTank, newTank);

	primaryTankPlayer = newTank;
	currentTank = newTank;

	// One surrender per Tank spawn: close the manual transfer window.
	withinTimeLimit = false;
	if (timeLimitTimer != null)
	{
		KillTimer(timeLimitTimer);
		timeLimitTimer = null;
	}

	return true;
}

float GetSurrenderTimeLimit()
{
	float limit = cvar_SurrenderTimeLimit.FloatValue;
	return (limit > 0.0) ? limit : 1.0;
}
