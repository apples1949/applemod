#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#include <colors>

#define PLUGIN_VERSION "1.6"

float CONTROL_DELAY_SAFETY             = 0.3;
float CONTROL_RETRY_DELAY              = 2.0;
int TEAM_INFECTED                      = 3;
#define MAX_TANK_ATTEMPTS              5

// 玩家接管坦克后, 在这段时间内反复把面板弹回玩家屏幕上(避免玩家没看到面板)
#define MENU_REFRESH_DURATION          10.0
#define MENU_REFRESH_INTERVAL          2.0

ConVar cvar_SurrenderTimeLimit         = null;
ConVar cvar_SurrenderChoiceType        = null;
ConVar cvar_SurrenderGhostKill         = null;
ConVar cvar_TankLotteryTime            = null;

Handle surrenderMenu                  = null;
Handle notifyTimer                    = null;
Handle autoMenuTimer                  = null;
Handle timeLimitTimer                 = null;
Handle menuRefreshTimer               = null;
Handle g_hForwardTankPassed           = null;

bool withinTimeLimit                  = false;
int primaryTankPlayer                 = -1;
int tankAttemptsFailed                = 0;
bool g_bIsTankAlive                   = false;
int currentTank                       = 0;
int tankNoTargetRetries               = 0;
float menuRefreshUntil                = 0.0;
bool tankMenuChosen                   = false;

public Plugin myinfo =
{
	name = "L4D Tank Swap",
	author = "AtomicStryker, HarryPotter, Bred, apples1949",
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

	RegPluginLibrary("l4d2_tank_swap");

	return APLRes_Success;
}

public void OnPluginStart()
{
	RegConsoleCmd("sm_tankpass", CallSurrenderMenu, "Shows who is becoming the tank.");
	RegConsoleCmd("sm_gk", CallSurrenderMenu, "Shows who is becoming the tank.");
	RegConsoleCmd("sm_rk", CallSurrenderMenu, "Shows who is becoming the tank.");
	RegConsoleCmd("sm_pass", CallSurrenderMenu, "Shows who is becoming the tank.");

	cvar_SurrenderTimeLimit = CreateConVar("l4d_tankswap_timelimit", "15", " 主控坦克玩家可移交控制权的秒数 ", FCVAR_NOTIFY, true, 1.0);
	cvar_SurrenderChoiceType = CreateConVar("l4d_tankswap_choicetype", "2", " 0 - 禁用；1 - 输入 !tankpass 按钮呼出菜单；2 - 每位坦克玩家都会弹出菜单 ", FCVAR_NOTIFY, true, 0.0, true, 2.0);
	cvar_SurrenderGhostKill = CreateConVar("l4d_tankswap_ghostkill", "1", " 0 - 禁用，旧坦克会变成新坦克之前控制的特感（灵魂）；1 - 移交时杀死灵魂 ", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	cvar_TankLotteryTime = FindConVar("director_tank_lottery_selection_time");

	LoadTranslations("common.phrases");
	LoadTranslations("l4d2_tank_swap.phrases");

	// 换克成功后的主动告知 forward, 供 tank_damage 等插件接收（双保险, 与引擎 forward 幂等）
	g_hForwardTankPassed = CreateForward(ET_Ignore, Param_Cell, Param_Cell);

	HookEvent("tank_spawn", TC_ev_TankSpawn);
	HookEvent("player_now_it", TC_ev_PlayerNowIt);
	HookEvent("bot_player_replace", TC_ev_BotPlayerReplace);
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

		StopMenuRefresh();
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

	StopMenuRefresh();

	g_bIsTankAlive = false;
	currentTank = 0;
	withinTimeLimit = false;
	primaryTankPlayer = -1;
	tankAttemptsFailed = 0;
	tankNoTargetRetries = 0;
	tankMenuChosen = false;
}

/* 停止"接管坦克后 10 秒内持续重弹面板"的循环 */
void StopMenuRefresh()
{
	if (menuRefreshTimer != null)
	{
		KillTimer(menuRefreshTimer);
		menuRefreshTimer = null;
	}

	menuRefreshUntil = 0.0;
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

	StopMenuRefresh();

	currentTank = tankid;
	g_bIsTankAlive = true;
	withinTimeLimit = false;
	primaryTankPlayer = -1;
	tankAttemptsFailed = 0;
	tankNoTargetRetries = 0;
	tankMenuChosen = false;

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

/* 玩家通过"接管 AI Tank"或"被喷胆汁"成为 Tank 时, 不一定有新 tank_spawn
   （同一 Tank 实例换控制者, 或 tank_spawn 被 tankid==currentTank 去重吞掉）。
   只靠 tank_spawn 的一次性定时器会错过面板, 这里直接用接管事件触发。 */
public Action TC_ev_BotPlayerReplace(Event event, const char[] name, bool dontBroadcast)
{
	int bot = GetClientOfUserId(event.GetInt("bot"));
	int player = GetClientOfUserId(event.GetInt("player"));

	// 被接管的 bot 就是当前 Tank（双条件兜住 currentTank 可能的失同步）
	if (bot != currentTank && !IsPlayerTank(bot))
		return Plugin_Continue;

	if (IsHumanTank(player))
		ScheduleTakeoverMenu(player);
	else
	{
		// 职业可能尚未切换完成, 延迟复查
		DataPack pack = new DataPack();
		pack.WriteCell(GetClientUserId(player));
		CreateTimer(CONTROL_RETRY_DELAY, TS_TakeoverRecheck, pack);
	}

	return Plugin_Continue;
}

public Action TC_ev_PlayerNowIt(Event event, const char[] name, bool dontBroadcast)
{
	int player = GetClientOfUserId(event.GetInt("userid"));

	// 生还者被喷也会触发 player_now_it, 只处理感染者（被喷即变 Tank 的路径）
	if (!IsValidClient(player) || GetClientTeam(player) != TEAM_INFECTED)
		return Plugin_Continue;

	if (IsHumanTank(player))
		ScheduleTakeoverMenu(player);
	else
	{
		DataPack pack = new DataPack();
		pack.WriteCell(GetClientUserId(player));
		CreateTimer(CONTROL_RETRY_DELAY, TS_TakeoverRecheck, pack);
	}

	return Plugin_Continue;
}

public Action TS_TakeoverRecheck(Handle timer, DataPack pack)
{
	pack.Reset();
	int player = GetClientOfUserId(pack.ReadCell());
	delete pack;

	if (IsHumanTank(player))
		ScheduleTakeoverMenu(player);

	return Plugin_Stop;
}

/* 人类成为 Tank 的接管路径: 重新调度让克面板/通知。
   与 TC_ev_TankSpawn 同时触发时相互覆盖, 幂等无害。 */
void ScheduleTakeoverMenu(int player)
{
	if (cvar_SurrenderChoiceType.IntValue == 0)
		return;

	if (autoMenuTimer != null)
	{
		KillTimer(autoMenuTimer);
		autoMenuTimer = null;
	}

	if (surrenderMenu != null)
	{
		CancelMenu(surrenderMenu);
		surrenderMenu = null;
	}

	StopMenuRefresh();

	primaryTankPlayer = player;
	currentTank = player;
	g_bIsTankAlive = true;
	withinTimeLimit = false;
	tankAttemptsFailed = 0;
	tankNoTargetRetries = 0;
	tankMenuChosen = false;

	int userid = GetClientUserId(player);
	if (cvar_SurrenderChoiceType.IntValue == 1)
		notifyTimer = CreateTimer(CONTROL_DELAY_SAFETY, TS_DisplayNotificationToTank, userid);
	else
		autoMenuTimer = CreateTimer(CONTROL_DELAY_SAFETY, TS_Display_Auto_MenuToTank, userid);
}

/* 除指定玩家外, 是否还有其它人类感染者在场（可能很快变成可移交的 ghost） */
bool HasOtherHumanInfected(int exclude)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (i == exclude)
			continue;
		if (IsValidClient(i) && !IsFakeClient(i) && GetClientTeam(i) == TEAM_INFECTED)
			return true;
	}

	return false;
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

	StopMenuRefresh();

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
		CPrintToChat(client, "%t", "No_Target");
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

	if (ShowAutoMenuToTank(primaryTankPlayer))
	{
		tankNoTargetRetries = 0;
		StartMenuRefresh();
		return Plugin_Stop;
	}

	// 一个可接管的人都没有: 其它人类感染者可能马上变成可移交的 ghost → 短暂重试; 否则明确提示
	if (tankNoTargetRetries < MAX_TANK_ATTEMPTS && HasOtherHumanInfected(primaryTankPlayer))
	{
		tankNoTargetRetries++;
		autoMenuTimer = CreateTimer(CONTROL_RETRY_DELAY, TS_Display_Auto_MenuToTank, GetClientUserId(primaryTankPlayer));
		return Plugin_Stop;
	}

	CPrintToChat(primaryTankPlayer, "%t", "No_Target");

	return Plugin_Stop;
}

/* 构建并弹出克面板. 每次都重建: 队友可能在几秒内才变成 ghost/复活, 重建才能把
   新出现的可接管玩家补进名单(修复面板"人不全"). 返回 false = 当前无人可接管. */
bool ShowAutoMenuToTank(int tank)
{
	// 先数一下可接管的人: 一个都没有就别动已经弹着的面板
	int electables;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsEligibleSwapTarget(i))
			electables++;
	}

	if (electables == 0)
		return false;

	if (surrenderMenu != null)
	{
		// 先摘掉引用再取消: 旧面板的 End 回调不会误清新面板
		Handle oldMenu = surrenderMenu;
		surrenderMenu = null;
		CancelMenu(oldMenu);
	}

	surrenderMenu = CreateMenu(TS_Auto_MenuCallBack);

	char buffer[256];
	Format(buffer, sizeof(buffer), "%T", "Menu_Title", tank);
	SetMenuTitle(surrenderMenu, buffer);

	char name[MAX_NAME_LENGTH], number[8];

	Format(buffer, sizeof(buffer), "%T", "Stay_Me", tank);
	AddMenuItem(surrenderMenu, "0", buffer);
	Format(buffer, sizeof(buffer), "%T", "Anyone_But_Me", tank);
	AddMenuItem(surrenderMenu, "99", buffer);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsEligibleSwapTarget(i)) continue;

		Format(name, sizeof(name), "%N", i);
		Format(number, sizeof(number), "%i", i);
		AddMenuItem(surrenderMenu, number, name);
	}

	SetMenuExitButton(surrenderMenu, false);
	if (DisplayMenu(surrenderMenu, tank, RoundToCeil(2.0 * GetSurrenderTimeLimit())))
		return true;

	CloseHandle(surrenderMenu);
	surrenderMenu = null;

	return false;
}

/* 面板弹给玩家后, 开始"10 秒内持续重弹"的循环 */
void StartMenuRefresh()
{
	if (tankMenuChosen)
		return;

	if (menuRefreshTimer != null)
	{
		KillTimer(menuRefreshTimer);
		menuRefreshTimer = null;
	}

	menuRefreshUntil = GetGameTime() + MENU_REFRESH_DURATION;
	menuRefreshTimer = CreateTimer(MENU_REFRESH_INTERVAL, TS_RefreshAutoMenu);
}

/* 10 秒窗口内反复把面板弹回玩家屏幕上, 避免玩家没看到面板;
   玩家选择过了 / 坦克没了 / 窗口结束 就停下 */
public Action TS_RefreshAutoMenu(Handle timer)
{
	menuRefreshTimer = null;

	if (tankMenuChosen || !g_bIsTankAlive)
		return Plugin_Stop;

	if (cvar_SurrenderChoiceType.IntValue != 2)
		return Plugin_Stop;

	if (!IsHumanTank(primaryTankPlayer))
		return Plugin_Stop;

	if (GetGameTime() >= menuRefreshUntil)
		return Plugin_Stop;

	// 重建面板: 顺便把这几秒内新变成 ghost 的队友补进名单
	ShowAutoMenuToTank(primaryTankPlayer);

	if (!tankMenuChosen && GetGameTime() < menuRefreshUntil)
		menuRefreshTimer = CreateTimer(MENU_REFRESH_INTERVAL, TS_RefreshAutoMenu);

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
		// "我自己玩": 玩家已经做出选择, 不再重复弹面板
		tankMenuChosen = true;
		StopMenuRefresh();
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

	// 换克成功时 PerformTankSwap 内部已置位并停表;
	// 失败(目标这几秒里失效了)则不置位, 刷新循环会在窗口内把面板弹回来给玩家重选

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
		tankNoTargetRetries = 0;
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

		StopMenuRefresh();
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

	// 阵亡(死亡回放中, 还没来得及变 ghost)的队友同样列出:
	// 引擎换克本来就要求目标处于"躺尸/幽灵"状态才拿得到控制权(见 PerformTankSwap),
	// 之前这里额外要求"活着或已是幽灵", 导致面板上经常缺人。
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

	// 主动告知其它插件(如 tank_damage)换克已发生: 与引擎 forward 双保险, 幂等
	Call_StartForward(g_hForwardTankPassed);
	Call_PushCell(oldTank);
	Call_PushCell(newTank);
	Call_Finish();

	primaryTankPlayer = newTank;
	currentTank = newTank;

	// One surrender per Tank spawn: close the manual transfer window.
	withinTimeLimit = false;
	if (timeLimitTimer != null)
	{
		KillTimer(timeLimitTimer);
		timeLimitTimer = null;
	}

	// 已经换过克: 不再重复弹面板
	tankMenuChosen = true;
	StopMenuRefresh();

	return true;
}

float GetSurrenderTimeLimit()
{
	float limit = cvar_SurrenderTimeLimit.FloatValue;
	return (limit > 0.0) ? limit : 1.0;
}
