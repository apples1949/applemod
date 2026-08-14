#pragma semicolon 1

#pragma newdecls required
#include <sourcemod>

#define PLUGIN_VERSION	"1.1"

#define SPRAY_WINDOW_TIME		2.5		// Boomer 存活喷吐的一次性判定窗口(秒)
#define EXPLODE_WINDOW_TIME		1.5		// Boomer 爆炸糊人的判定窗口(秒)
#define PINNED_CHECK_INTERVAL	0.5		// 多控检测间隔(秒)

// ====================================================================================================
// Plugin Info
// ====================================================================================================

public Plugin myinfo =
{
	name		= "l4d2_infected_highlight_prompt",
	author		= "apples1949",
	description	= "感染者阵营高光操作提示: 喷中多名/爆炸炸到多名/一撞多/多控达成.",
	version		= PLUGIN_VERSION,
	url			= "N/A"
}

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
// Boomer 爆炸糊人状态(按 boomer 玩家索引)
// ====================================================================================================
bool  g_bExplodeActive[MAXPLAYERS+1];	// 爆炸判定窗口是否开启
int   g_iExplodeCount[MAXPLAYERS+1];	// 被炸到的不重复生还者数
bool  g_bExplodeVictim[MAXPLAYERS+1][MAXPLAYERS+1];
char  g_sExplodeName[MAXPLAYERS+1][MAX_NAME_LENGTH];	// 开窗时记录的特感名(爆炸后 boomer 已死亡)
int   g_iLastExplodedBoomer;			// 最近爆炸的 boomer 的 userid(now_it 攻击者异常时的回退)
float g_fLastExplodedTime;				// 最近爆炸发生的游戏时间

// ====================================================================================================
// Charger 一撞多状态(按 charger 玩家索引)
// ====================================================================================================
bool  g_bChargerReady[MAXPLAYERS+1];	// 本次冲撞是否处于可计数窗口内
int   g_iChargerCount[MAXPLAYERS+1];	// 本次冲撞撞到的不重复生还者数
bool  g_bChargerHit[MAXPLAYERS+1][MAXPLAYERS+1];

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
	HookEvent("charger_charge_end",		Event_ChargerChargeEnd);
	HookEvent("player_hurt",			Event_PlayerHurt);
	HookEvent("charger_carry_start",	Event_ChargerCarryStart);
	HookEvent("charger_carry_end",		Event_ChargerCarryEnd);
	HookEvent("player_death",			Event_PlayerDeath);
	HookEvent("player_spawn",			Event_PlayerSpawn);
	HookEvent("player_bot_replace",		Event_PlayerBotReplace);
	HookEvent("bot_player_replace",		Event_BotPlayerReplace);

	CreateTimer(PINNED_CHECK_INTERVAL, Timer_CheckPinned, _, TIMER_REPEAT);

	//AutoExecConfig(true, "l4d2_infected_highlight_prompt");
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
		ResetExplode(i);
		ResetCharger(i);
	}

	g_iLastExplodedBoomer = 0;
	g_fLastExplodedTime = 0.0;
	g_bMultiPinnedAnnounced = false;
}

public void OnClientDisconnect(int client)
{
	ResetSpray(client);
	ResetExplode(client);
	ResetCharger(client);
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

	// 爆炸糊人: 无论 player_now_it 与 boomer_exploded 事件谁先到达, 都能正确开窗计数
	if (event.GetBool("exploded"))
	{
		int boomer = attacker;

		if (!IsBoomer(boomer))
		{
			// 攻击者异常时的回退: 使用最近一次爆炸的 boomer(需在判定窗口时限内)
			boomer = GetClientOfUserId(g_iLastExplodedBoomer);

			if (!IsBoomer(boomer) || GetGameTime() - g_fLastExplodedTime > EXPLODE_WINDOW_TIME)
				return;
		}

		if (!g_bExplodeActive[boomer])
			OpenExplodeWindow(boomer);

		if (!g_bExplodeVictim[boomer][victim])
		{
			g_bExplodeVictim[boomer][victim] = true;
			g_iExplodeCount[boomer]++;
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

		PrintToInfectedTeam("\x04[\x03!\x04] \x05Boomer(\x03%s\x05) \x01一次性喷中\x04%s\x05名生还者",
			name, g_NumberTextGe[g_iSprayCount[boomer] - 2]);
	}

	if (boomer > 0)
		ResetSpray(boomer);

	return Plugin_Continue;
}

public void Event_BoomerExploded(Event event, const char[] name, bool dontBroadcast)
{
	int boomer = GetClientOfUserId(event.GetInt("userid"));

	if (!IsBoomer(boomer))
		return;

	g_iLastExplodedBoomer = event.GetInt("userid");
	g_fLastExplodedTime = GetGameTime();

	// 若 player_now_it 已先到达并开窗, 则保留已计数, 不重置窗口
	if (!g_bExplodeActive[boomer])
		OpenExplodeWindow(boomer);
}

void OpenExplodeWindow(int boomer)
{
	g_bExplodeActive[boomer] = true;
	g_iExplodeCount[boomer] = 0;

	for (int i = 1; i <= MaxClients; i++)
		g_bExplodeVictim[boomer][i] = false;

	// 爆炸后 boomer 立即死亡, 先记录名字, 结算时不再解析实体
	GetActorName(boomer, g_sExplodeName[boomer], MAX_NAME_LENGTH);

	CreateTimer(EXPLODE_WINDOW_TIME, Timer_EndExplode, GetClientUserId(boomer), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_EndExplode(Handle timer, int userid)
{
	int boomer = GetClientOfUserId(userid);

	if (boomer > 0 && g_bExplodeActive[boomer] && g_iExplodeCount[boomer] >= g_iBoomerExplodeMin)
	{
		PrintToInfectedTeam("\x04[\x03!\x04] \x05Boomer(\x03%s\x05) \x01爆炸炸到\x04%s\x05名生还者",
			g_sExplodeName[boomer], g_NumberTextGe[g_iExplodeCount[boomer] - 2]);
	}

	if (boomer > 0)
		ResetExplode(boomer);

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

void ResetExplode(int boomer)
{
	g_bExplodeActive[boomer] = false;
	g_iExplodeCount[boomer] = 0;

	for (int i = 1; i <= MaxClients; i++)
		g_bExplodeVictim[boomer][i] = false;

	g_sExplodeName[boomer][0] = '\0';
}

// ====================================================================================================
// Charger 一撞多
// ====================================================================================================

public void Event_AbilityUse(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	if (!IsCharger(client) || !IsPlayerAlive(client))
		return;

	char ability[32];
	event.GetString("ability", ability, sizeof(ability));

	if (strcmp(ability, "ability_charge") != 0)
		return;

	// 一次新冲撞的开始: 无条件重开窗口
	StartChargerWindow(client);
}

public void Event_ChargerChargeEnd(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	if (!IsCharger(client))
		return;

	// 冲锋结束(撞墙/撞击停止/被控打断等)即结算本次冲撞
	SettleCharger(client);
}

public void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	if (!IsSurvivor(client))
		return;

	int attacker = GetClientOfUserId(event.GetInt("attacker"));

	if (!IsCharger(attacker) || !IsPlayerAlive(attacker))
		return;

	if (!g_bChargerReady[attacker])
	{
		// 窗口未开: 只有真正处于冲锋状态才开窗计数(AI 特感可能没有 ability_use 事件)
		if (!ChargerIsCharging(attacker))
			return;

		OpenChargerWindow(attacker);
	}

	if (g_bChargerHit[attacker][client] || event.GetInt("dmg_health") < 1)
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

	// 抓取本身不一定产生 player_hurt 伤害, 窗口未开时在此开窗
	if (!g_bChargerReady[client])
		OpenChargerWindow(client);

	if (g_bChargerHit[client][victim])
		return;

	g_bChargerHit[client][victim] = true;
	g_iChargerCount[client]++;
}

public void Event_ChargerCarryEnd(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	if (!IsCharger(client))
		return;

	// 作为 charger_charge_end 未触发时的兜底结算点
	SettleCharger(client);
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	if (!IsCharger(client))
		return;

	// 冲锋途中死亡的兜底结算点
	SettleCharger(client);
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	if (IsBoomer(client))
		ResetSpray(client);

	if (!IsCharger(client))
		return;

	ResetCharger(client);
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

// 一次新冲撞的开始(ability_use 确认发起冲撞): 无条件重开窗口
void StartChargerWindow(int charger)
{
	g_bChargerReady[charger] = true;
	g_iChargerCount[charger] = 0;

	for (int i = 1; i <= MaxClients; i++)
		g_bChargerHit[charger][i] = false;
}

// 冲撞伤害已发生但窗口未开(如 AI 特感没有 ability_use 事件): 补开窗口
void OpenChargerWindow(int charger)
{
	if (g_bChargerReady[charger])
		return;

	StartChargerWindow(charger);
}

void ResetCharger(int charger)
{
	g_bChargerReady[charger] = false;
	g_iChargerCount[charger] = 0;

	for (int i = 1; i <= MaxClients; i++)
		g_bChargerHit[charger][i] = false;
}

// 结算本次冲撞(幂等: 窗口已关闭则直接返回, 不会重复提示)
void SettleCharger(int charger)
{
	if (!g_bChargerReady[charger])
		return;

	g_bChargerReady[charger] = false;
	PrintCharger(charger);
}

void PrintCharger(int charger)
{
	if (g_iChargerCount[charger] < g_iChargerMin)
		return;

	char name[MAX_NAME_LENGTH];
	GetActorName(charger, name, sizeof(name));

	PrintToInfectedTeam("\x04[\x03!\x04] \x05Charger(\x03%s\x05) \x01一撞\x04%s\x05",
		name, g_NumberText[g_iChargerCount[charger] - 2]);
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
			PrintToInfectedTeam("\x04[\x03!\x04] \x03%s控\x05 \x01达成.", g_NumberText[pinned - 2]);
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

// 除生还者外的所有真人玩家都提示输出(感染者阵营与旁观), 不提示生还者与Bot
void PrintToInfectedTeam(const char[] format, any ...)
{
	char buffer[256];
	VFormat(buffer, sizeof(buffer), format, 2);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && GetClientTeam(i) != 2 && !IsFakeClient(i))
			PrintToChat(i, buffer);
	}
}
