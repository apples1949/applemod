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

// 给克时被 ReplaceWithBot 顶替出来的那只 AI 特感: 玩家去开坦克了, 不能把它留在场上占特感位
int g_iSwapLeftoverBotUserId          = 0;
// 被顶替玩家的原特感职业: 换克后玩家的 m_zombieClass 已经变成 Tank(8), 必须换克前先记下来做兜底匹配
int g_iSwapLeftoverZombieClass        = 0;

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
	HookEvent("player_bot_replace", TC_ev_PlayerBotReplace);
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

/* 给克时 ReplaceWithBot 会在玩家原地生成一只同职业 AI 特感顶替他,
   这里记下它的 userid, 换克结束后把这只"残留特感"清掉(不留在场上占特感位)。
   注意方向: player_bot_replace = "机器人替换了玩家"。 */
public Action TC_ev_PlayerBotReplace(Event event, const char[] name, bool dontBroadcast)
{
	int bot = GetClientOfUserId(event.GetInt("bot"));

	if (bot > 0 && bot <= MaxClients)
		g_iSwapLeftoverBotUserId = GetClientUserId(bot);

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

	// 目标正骑着人(Jockey)/扛着人(Charger)时: 先解控。把人质留着被 SI 拖走/卡住,
	// 或让带着"骑乘中"状态的玩家被顶替, 都会留下烂摊子。
	ReleasePinnedSurvivor(newTank);

	g_iSwapLeftoverBotUserId = 0;
	g_iSwapLeftoverZombieClass = 0;
	CacheInfectedBots(); // 记录换克前在场的感染者 bot, 供兜底查找"新出现的 bot"

	if (GetClientHealth(newTank) > 1 && !IsPlayerGhost(newTank))
	{
		// 顶替出来的 bot 与玩家同职业; 换克后玩家已变成 Tank, 这里必须先记
		g_iSwapLeftoverZombieClass = GetEntProp(newTank, Prop_Send, "m_zombieClass");
		L4D_ReplaceWithBot(newTank);
	}

	// Preserves the original manual-menu behavior: after ReplaceWithBot a live
	// target is a ghost, so this is intentionally checked again.
	if (cvar_SurrenderGhostKill.IntValue && IsPlayerGhost(newTank))
		ForcePlayerSuicide(newTank);

	L4D_ReplaceTank(oldTank, newTank);

	// 玩家已经去开坦克, 那只被顶替出来的 AI 特感就地清掉(处死+移除), 不再留在场上
	RemoveSwapLeftoverBot(newTank);

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

/* 目标特感正控制着某个生还者时, 先彻底解除控制, 再走"顶替 → 处死 → 移除"流程。
   不先解控就顶替/处死: 被 Jockey 骑着的玩家状态错乱(见 l4dinfectedbots 的同款注释),
   被 Charger 扛走/压制的生还者会带着"被扛"状态留在原地卡住。
   顺序: Jockey 骑乘 → Charger 扛走(carry 与 pummel 互斥, 扛走优先) → Charger 压制。 */
void ReleasePinnedSurvivor(int si)
{
	if (!IsValidClient(si) || !IsPlayerAlive(si))
		return;

	// Jockey: 正骑着人 → 立即用引擎原生结束骑乘(同步生效), 再补一条 dismount 指令兜底
	int jockeyVictim = GetEntPropEnt(si, Prop_Send, "m_jockeyVictim");
	if (IsValidClient(jockeyVictim))
		EndJockeyRide(jockeyVictim, si);

	int carryVictim = GetEntPropEnt(si, Prop_Send, "m_carryVictim");
	if (IsValidClient(carryVictim))
	{
		L4D2_Charger_EndCarry(carryVictim, si);
		FinishSurvivorRelease(carryVictim, si, MOVETYPE_WALK);
	}
	else
	{
		int pummelVictim = GetEntPropEnt(si, Prop_Send, "m_pummelVictim");
		if (IsValidClient(pummelVictim))
		{
			L4D2_Charger_EndPummel(pummelVictim, si);
			FinishSurvivorRelease(pummelVictim, si, MOVETYPE_WALK);
		}
	}

	// 解控后残留在特感身上的"我在控人"引用一并清掉: 它马上要变成 bot, 不能带着旧状态
	// (Jockey 的 m_jockeyVictim 由引擎结束骑乘时清理, 不在这里硬置 -1)
	SetEntPropEnt(si, Prop_Send, "m_carryVictim", -1);
	SetEntPropEnt(si, Prop_Send, "m_pummelVictim", -1);
}

/* Jockey 解控: 先用引擎原生同步结束骑乘(立刻生效, 不依赖下一帧的指令队列),
   再补一条 dismount 指令走引擎自己的松手流程兜底。 */
void EndJockeyRide(int victim, int jockey)
{
	L4D2_Jockey_EndRide(victim, jockey);

	FinishSurvivorRelease(victim, jockey, MOVETYPE_WALK);
	DismountJockey(jockey);
}

/* 解控收尾: 断开 Charger 的 parent 关系并恢复行走, 否则生还者会被吊在空中/保持被扛的动画。
   (原生内部已做 ClearParent, 这里再兜一次; move type 参考 AI_HardSI/ai_charger.sp 的做法) */
void FinishSurvivorRelease(int survivor, int si, MoveType moveType)
{
	AcceptEntityInput(survivor, "ClearParent");
	SetEntityMoveType(survivor, moveType);

	if (IsValidClient(si) && IsPlayerAlive(si))
		SetEntityMoveType(si, moveType);
}

/* dismount 是 FCVAR_CHEAT 的玩家指令: 临时摘掉 cheat 标记再以客户端身份发指令,
   引擎就会走它自己的"跳蚤松手"流程(本仓库 l4d2_charge_target_fix / l4d2_rock_trace_unblock 同款做法)。 */
void DismountJockey(int jockey)
{
	int flags = GetCommandFlags("dismount");
	SetCommandFlags("dismount", flags & ~FCVAR_CHEAT);
	FakeClientCommand(jockey, "dismount");
	SetCommandFlags("dismount", flags);
}

/* 清掉给克时被顶替出来的那只 AI 特感。
   正常路径: player_bot_replace 事件里记下了它的 userid;
   兜底路径: 万一事件没来(以 userid 找回失败), 就在感染者队伍里找那只"和玩家同职业、且不属于换克前就在场的 bot"。 */
void RemoveSwapLeftoverBot(int newTank)
{
	int bot = GetClientOfUserId(g_iSwapLeftoverBotUserId);
	g_iSwapLeftoverBotUserId = 0;

	if (bot <= 0)
		bot = FindLeftoverBot(newTank);

	if (bot <= 0)
		return;

	// 处死(让引擎走正常的 SI 死亡流程, 不留下半死实体) → 再移除, 确保它不再占着特感名额
	ForcePlayerSuicide(bot);

	if (IsClientInGame(bot))
		KickClient(bot, "Tank swap: victim's special infected removed");
}

/* 兜底查找: 顶替出来的 bot 与玩家换克前的职业(g_iSwapLeftoverZombieClass)一致,
   且换克前不在场。换克前的快照必须在 ReplaceWithBot / ReplaceTank 之前取, 见 PerformTankSwap。 */
int g_iBotsBeforeSwap[MAXPLAYERS + 1];
int g_iBotsBeforeSwapCount = 0;

void CacheInfectedBots()
{
	g_iBotsBeforeSwapCount = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsValidClient(i) && IsFakeClient(i) && GetClientTeam(i) == TEAM_INFECTED)
			g_iBotsBeforeSwap[g_iBotsBeforeSwapCount++] = i;
	}
}

bool WasBotPresentBeforeSwap(int client)
{
	for (int i = 0; i < g_iBotsBeforeSwapCount; i++)
	{
		if (g_iBotsBeforeSwap[i] == client)
			return true;
	}

	return false;
}

int FindLeftoverBot(int newTank)
{
	if (!IsValidClient(newTank) || g_iSwapLeftoverZombieClass <= 0)
		return 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsValidClient(i) || !IsFakeClient(i))
			continue;
		if (GetClientTeam(i) != TEAM_INFECTED)
			continue;
		if (IsPlayerTank(i))
			continue;
		if (WasBotPresentBeforeSwap(i))
			continue;
		if (GetEntProp(i, Prop_Send, "m_zombieClass") != g_iSwapLeftoverZombieClass)
			continue;

		return i;
	}

	return 0;
}

float GetSurrenderTimeLimit()
{
	float limit = cvar_SurrenderTimeLimit.FloatValue;
	return (limit > 0.0) ? limit : 1.0;
}
