#pragma semicolon 1

#pragma newdecls required
#include <sourcemod>

#define SPRAY_WINDOW_TIME		2.5		// Boomer 存活喷吐的一次性判定窗口(秒)
#define EXPLODE_WINDOW_TIME		1.5		// Boomer 爆炸糊人的判定窗口(秒)
#define PINNED_CHECK_INTERVAL	0.5		// 多控检测间隔(秒)

// ====================================================================================================
// 中文数字表
// ====================================================================================================
// 多控/一撞多使用: 双控、三控、一撞双
char g_NumberText[15][8] =
{
	"双", "三", "四", "五", "六", "七", "八", "九", "十",
	"十一", "十二", "十三", "十四", "十五", "十六"
};

// 喷中/炸到多少"名"生还者使用: 两名、三名
char g_NumberTextGe[15][8] =
{
	"两", "三", "四", "五", "六", "七", "八", "九", "十",
	"十一", "十二", "十三", "十四", "十五", "十六"
};

// ====================================================================================================
// Boomer 存活喷吐状态(按 boomer 玩家索引)
// ====================================================================================================
bool  g_bSprayActive[MAXPLAYERS+1];		// 当前是否处于一次喷吐窗口内
float g_fSprayStart[MAXPLAYERS+1];		// 本次喷吐窗口起始时间
int   g_iSprayCount[MAXPLAYERS+1];		// 本次喷到的不重复生还者数
bool  g_bSprayVictim[MAXPLAYERS+1][MAXPLAYERS+1];

// ====================================================================================================
// Boomer 爆炸糊人状态
// ====================================================================================================
float g_fExplodeWindowEnd = 0.0;		// 爆炸判定窗口截止时间
int   g_iExplodeBoomerUserId = 0;		// 爆炸的 boomer 的 userid
int   g_iExplodeCount = 0;				// 被炸到的不重复生还者数
bool  g_bExplodeVictim[MAXPLAYERS+1];

// ====================================================================================================
// Charger 一撞多状态(按 charger 玩家索引)
// ====================================================================================================
bool  g_bChargerPrint[MAXPLAYERS+1];	// 本次冲撞是否已提示
bool  g_bChargerCarry[MAXPLAYERS+1];	// 本次冲撞是否抓起了生还者
int   g_iChargerCount[MAXPLAYERS+1];	// 本次冲撞撞到的不重复生还者数
bool  g_bChargerHit[MAXPLAYERS+1][MAXPLAYERS+1];
bool  g_bChargerReady[MAXPLAYERS+1];	// 是否处于可计数的冲撞状态

// ====================================================================================================
// 多控达成状态
// ====================================================================================================
bool  g_bMultiPinnedAnnounced = false;	// 当前多控状态是否已提示

// ====================================================================================================
// ConVar
// ====================================================================================================
ConVar g_cvBoomerSprayMin;
ConVar g_cvBoomerExplodeMin;
ConVar g_cvChargerMin;
ConVar g_cvPinnedMin;

int g_iBoomerSprayMin;
int g_iBoomerExplodeMin;
int g_iChargerMin;
int g_iPinnedMin;

// ====================================================================================================
// Plugin Start
// ====================================================================================================

public void OnPluginStart()
{
	g_cvBoomerSprayMin		= CreateConVar("l4d2_infected_highlight_boomer_spray_min",
											"2",
											"Boomer存活状态下一口喷中多少个生还者时提示(>=2).",
											FCVAR_NOTIFY, true, 2.0, true, 16.0);
	g_cvBoomerExplodeMin	= CreateConVar("l4d2_infected_highlight_boomer_explode_min",
											"2",
											"Boomer死亡爆炸一次炸到多少个生还者时提示(>=2).",
											FCVAR_NOTIFY, true, 2.0, true, 16.0);
	g_cvChargerMin			= CreateConVar("l4d2_infected_highlight_charger_min",
											"2",
											"Charger一次冲撞连续撞中多少个生还者时提示(>=2).",
											FCVAR_NOTIFY, true, 2.0, true, 16.0);
	g_cvPinnedMin			= CreateConVar("l4d2_infected_highlight_pinned_min",
											"2",
											"感染者阵营同时控住多少个生还者时提示(>=2).",
											FCVAR_NOTIFY, true, 2.0, true, 4.0);

	GetCvars();

	g_cvBoomerSprayMin.AddChangeHook(OnConVarChanged);
	g_cvBoomerExplodeMin.AddChangeHook(OnConVarChanged);
	g_cvChargerMin.AddChangeHook(OnConVarChanged);
	g_cvPinnedMin.AddChangeHook(OnConVarChanged);

	HookEvent("player_now_it",			Event_PlayerNowIt);
	HookEvent("boomer_exploded",		Event_BoomerExploded);
	HookEvent("ability_use",			Event_AbilityUse);
	HookEvent("player_hurt",			Event_PlayerHurt);
	HookEvent("charger_carry_start",	Event_ChargerCarryStart);
	HookEvent("charger_carry_end",		Event_ChargerCarryEnd);
	HookEvent("player_death",			Event_PlayerDeath);
	HookEvent("player_spawn",			Event_PlayerSpawn);
	HookEvent("player_bot_replace",		Event_PlayerBotReplace);
	HookEvent("bot_player_replace",		Event_BotPlayerReplace);

	CreateTimer(PINNED_CHECK_INTERVAL, Timer_CheckPinned, _, TIMER_REPEAT);

	AutoExecConfig(true, "l4d2_infected_highlight_prompt");
}

public void OnConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	GetCvars();
}

void GetCvars()
{
	g_iBoomerSprayMin	= g_cvBoomerSprayMin.IntValue;
	g_iBoomerExplodeMin	= g_cvBoomerExplodeMin.IntValue;
	g_iChargerMin		= g_cvChargerMin.IntValue;
	g_iPinnedMin		= g_cvPinnedMin.IntValue;
}

public void OnMapEnd()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		ResetSpray(i);
		g_bChargerPrint[i] = false;
		g_bChargerCarry[i] = false;
		g_iChargerCount[i] = 0;
		g_bChargerReady[i] = false;
	}

	g_fExplodeWindowEnd = 0.0;
	g_iExplodeBoomerUserId = 0;
	g_iExplodeCount = 0;
	g_bMultiPinnedAnnounced = false;
}

public void OnClientDisconnect(int client)
{
	ResetSpray(client);
	g_bChargerPrint[client] = false;
	g_bChargerCarry[client] = false;
	g_iChargerCount[client] = 0;
	g_bChargerReady[client] = false;
}

// ====================================================================================================
// Boomer 存活喷中多个 / 死亡爆炸炸到多个
// ====================================================================================================

public void Event_PlayerNowIt(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));

	if (!IsSurvivor(victim) || !IsPlayerAlive(victim))
		return;

	int attacker = GetClientOfUserId(event.GetInt("attacker"));

	// 爆炸糊人: 在爆炸判定窗口内即计入
	if (event.GetBool("exploded"))
	{
		if (g_fExplodeWindowEnd > GetGameTime() && !g_bExplodeVictim[victim])
		{
			g_bExplodeVictim[victim] = true;
			g_iExplodeCount++;
		}
		return;
	}

	// 存活喷吐: attacker 必须是存活中的 boomer 玩家
	if (!IsBoomer(attacker) || !IsPlayerAlive(attacker))
		return;

	float now = GetGameTime();

	if (!g_bSprayActive[attacker])
	{
		g_bSprayActive[attacker] = true;
		g_fSprayStart[attacker] = now;
		CreateTimer(SPRAY_WINDOW_TIME, Timer_EndSpray, GetClientUserId(attacker), TIMER_FLAG_NO_MAPCHANGE);
	}
	else if (now - g_fSprayStart[attacker] > SPRAY_WINDOW_TIME)
	{
		// 窗口已过期但结算计时器尚未运行(如换图被清除), 重新开窗
		ResetSpray(attacker);
		g_bSprayActive[attacker] = true;
		g_fSprayStart[attacker] = now;
		CreateTimer(SPRAY_WINDOW_TIME, Timer_EndSpray, GetClientUserId(attacker), TIMER_FLAG_NO_MAPCHANGE);
	}

	if (!g_bSprayVictim[attacker][victim])
	{
		g_bSprayVictim[attacker][victim] = true;
		g_iSprayCount[attacker]++;
	}
}

public Action Timer_EndSpray(Handle timer, int userid)
{
	int boomer = GetClientOfUserId(userid);

	if (boomer > 0 && g_bSprayActive[boomer] && g_iSprayCount[boomer] >= g_iBoomerSprayMin)
	{
		char name[MAX_NAME_LENGTH];
		GetActorName(boomer, name, sizeof(name));

		PrintToInfectedTeam("\x04[提示] \x05Boomer(\x03%s\x05) \x01一口喷中\x04%s\x05名生还者",
			name, g_NumberTextGe[g_iSprayCount[boomer] - 2]);
	}

	if (boomer > 0)
		ResetSpray(boomer);

	return Plugin_Continue;
}

public void Event_BoomerExploded(Event event, const char[] name, bool dontBroadcast)
{
	int boomer = GetClientOfUserId(event.GetInt("userid"));

	if (!IsBoomer(boomer) || !event.GetBool("splashedbile"))
		return;

	g_fExplodeWindowEnd = GetGameTime() + EXPLODE_WINDOW_TIME;
	g_iExplodeBoomerUserId = event.GetInt("userid");
	g_iExplodeCount = 0;

	for (int i = 1; i <= MaxClients; i++)
		g_bExplodeVictim[i] = false;

	CreateTimer(EXPLODE_WINDOW_TIME, Timer_EndExplode, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_EndExplode(Handle timer)
{
	int boomer = GetClientOfUserId(g_iExplodeBoomerUserId);

	if (boomer > 0 && g_iExplodeCount >= g_iBoomerExplodeMin)
	{
		char name[MAX_NAME_LENGTH];
		GetActorName(boomer, name, sizeof(name));

		PrintToInfectedTeam("\x04[提示] \x05Boomer(\x03%s\x05) \x01爆炸炸到\x04%s\x05名生还者",
			name, g_NumberTextGe[g_iExplodeCount - 2]);
	}

	g_fExplodeWindowEnd = 0.0;
	g_iExplodeBoomerUserId = 0;
	g_iExplodeCount = 0;

	return Plugin_Continue;
}

void ResetSpray(int boomer)
{
	g_bSprayActive[boomer] = false;
	g_fSprayStart[boomer] = 0.0;
	g_iSprayCount[boomer] = 0;

	for (int i = 1; i <= MaxClients; i++)
		g_bSprayVictim[boomer][i] = false;
}

// ====================================================================================================
// Charger 一撞多
// ====================================================================================================

public void Event_AbilityUse(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	if (!IsCharger(client) || !IsPlayerAlive(client))
		return;

	g_bChargerPrint[client] = false;
	g_bChargerCarry[client] = false;
	g_iChargerCount[client] = 0;
	g_bChargerReady[client] = true;

	for (int i = 1; i <= MaxClients; i++)
		g_bChargerHit[client][i] = false;
}

public void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	if (!IsSurvivor(client))
		return;

	int attacker = GetClientOfUserId(event.GetInt("attacker"));

	if (!IsCharger(attacker) || !IsPlayerAlive(attacker) || (!ChargerIsCharging(attacker) && !g_bChargerReady[attacker]))
		return;

	if (g_bChargerPrint[attacker] || !g_bChargerReady[attacker] || g_bChargerHit[attacker][client])
		return;

	if (event.GetInt("dmg_health") < 1)
		return;

	g_bChargerHit[attacker][client] = true;
	g_iChargerCount[attacker]++;
}

public void Event_ChargerCarryStart(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	if (!IsCharger(client) || !IsPlayerAlive(client))
		return;

	int victim = GetClientOfUserId(event.GetInt("victim"));

	if (!IsSurvivor(victim) || !IsPlayerAlive(victim))
		return;

	g_bChargerCarry[client] = true;

	if (g_bChargerHit[client][victim])
		return;

	g_bChargerHit[client][victim] = true;
	g_iChargerCount[client]++;
}

public void Event_ChargerCarryEnd(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	if (!IsCharger(client) || !IsPlayerAlive(client) || g_bChargerPrint[client] || !g_bChargerCarry[client])
		return;

	PrintCharger(client);
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	if (!IsCharger(client) || g_bChargerPrint[client] || !g_bChargerCarry[client])
		return;

	PrintCharger(client);
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	if (IsBoomer(client))
		ResetSpray(client);

	if (!IsCharger(client))
		return;

	g_bChargerPrint[client] = false;
	g_bChargerCarry[client] = false;
	g_iChargerCount[client] = 0;
	g_bChargerReady[client] = false;
}

public void Event_PlayerBotReplace(Event event, const char[] name, bool dontBroadcast)
{
	int bot = GetClientOfUserId(event.GetInt("bot"));

	if (!IsSurvivor(bot) || !IsPlayerAlive(bot))
		return;

	int player = GetClientOfUserId(event.GetInt("player"));

	for (int i = 1; i <= MaxClients; i++)
	{
		if (g_bChargerHit[i][player])
		{
			g_bChargerHit[i][player] = false;
			g_bChargerHit[i][bot] = true;
		}
	}
}

public void Event_BotPlayerReplace(Event event, const char[] name, bool dontBroadcast)
{
	int player = GetClientOfUserId(event.GetInt("player"));

	if (!IsSurvivor(player) || !IsPlayerAlive(player))
		return;

	int bot = GetClientOfUserId(event.GetInt("bot"));

	for (int i = 1; i <= MaxClients; i++)
	{
		if (g_bChargerHit[i][bot])
		{
			g_bChargerHit[i][bot] = false;
			g_bChargerHit[i][player] = true;
		}
	}
}

void PrintCharger(int charger)
{
	g_bChargerReady[charger] = false;

	if (g_iChargerCount[charger] < g_iChargerMin)
		return;

	char name[MAX_NAME_LENGTH];
	GetActorName(charger, name, sizeof(name));

	PrintToInfectedTeam("\x04[提示] \x05Charger(\x03%s\x05) \x01一撞\x04%s\x05",
		name, g_NumberText[g_iChargerCount[charger] - 2]);

	g_bChargerPrint[charger] = true;
}

// ====================================================================================================
// 多控达成
// ====================================================================================================

public Action Timer_CheckPinned(Handle timer)
{
	int pinned = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) &&
			GetClientTeam(i) == 2 &&
			IsPlayerAlive(i) &&
			(GetEntPropEnt(i, Prop_Send, "m_tongueOwner") > 0 ||
			GetEntPropEnt(i, Prop_Send, "m_pounceAttacker") > 0 ||
			GetEntPropEnt(i, Prop_Send, "m_carryAttacker") > 0 ||
			GetEntPropEnt(i, Prop_Send, "m_pummelAttacker") > 0 ||
			GetEntPropEnt(i, Prop_Send, "m_jockeyAttacker") > 0))
		{
			pinned++;
		}
	}

	if (pinned >= g_iPinnedMin)
	{
		if (!g_bMultiPinnedAnnounced)
		{
			PrintToInfectedTeam("\x04[提示] \x03%s控\x05 \x01达成.", g_NumberText[pinned - 2]);
			g_bMultiPinnedAnnounced = true;
		}
	}
	else
	{
		g_bMultiPinnedAnnounced = false;
	}

	return Plugin_Continue;
}

// ====================================================================================================
// 工具函数
// ====================================================================================================

bool IsSurvivor(int client)
{
	return client > 0 && client <= MaxClients && IsClientInGame(client) && GetClientTeam(client) == 2;
}

bool IsBoomer(int client)
{
	return client > 0 &&
			client <= MaxClients &&
			IsClientInGame(client) &&
			GetClientTeam(client) == 3 &&
			GetEntProp(client, Prop_Send, "m_zombieClass") == 2;
}

bool IsCharger(int client)
{
	return client > 0 &&
			client <= MaxClients &&
			IsClientInGame(client) &&
			GetClientTeam(client) == 3 &&
			GetEntProp(client, Prop_Send, "m_zombieClass") == 6;
}

bool ChargerIsCharging(int charger)
{
	int ability = GetEntPropEnt(charger, Prop_Send, "m_customAbility");
	return IsValidEdict(ability) && GetEntProp(ability, Prop_Send, "m_isCharging") != 0;
}

void GetActorName(int client, char[] buffer, int maxlen)
{
	if (IsFakeClient(client))
		strcopy(buffer, maxlen, "AI");
	else
		GetClientName(client, buffer, maxlen);
}

// 只提示非生还者玩家(感染者阵营), 不提示生还者与旁观
void PrintToInfectedTeam(const char[] format, any ...)
{
	char buffer[256];
	VFormat(buffer, sizeof(buffer), format, 2);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && GetClientTeam(i) == 3 && !IsFakeClient(i))
			PrintToChat(i, buffer);
	}
}
