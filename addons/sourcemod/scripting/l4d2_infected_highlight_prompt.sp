#pragma semicolon 1

#pragma newdecls required
#include <sourcemod>

#define PLUGIN_VERSION	"1.8"

#define SPRAY_WINDOW_TIME		2.5		// Boomer 存活喷吐的一次性判定窗口(秒)
#define EXPLODE_WINDOW_TIME		1.5		// Boomer 爆炸糊人的判定窗口(秒)
#define EXPLODE_SAME_WINDOW_TIME	0.5	// 同一次爆炸事件的最大到达时间差(秒): 窗口开启超过此时长后到达的事件视为新一次爆炸
#define EXPLODE_SCAN_INTERVAL	0.25	// 爆炸窗口结算扫描间隔(秒)
#define TANK_HIT_WINDOW_TIME	0.5		// Tank 左键一爪/拍打移动物品的一次性判定窗口(秒)
#define BOOMER_REPORT_DELAY		0.5		// Boomer 死亡后等待爆炸糊人的 player_now_it 事件到齐再播报累积胆汁的延迟(秒)
#define PINNED_CHECK_INTERVAL	0.5		// 多控检测间隔(秒)

// ====================================================================================================
// Plugin Info
// ====================================================================================================

public Plugin myinfo =
{
	name		= "l4d2_infected_highlight_prompt",
	author		= "apples1949",
	description	= "感染者阵营高光操作提示: 喷中多名/爆炸炸到多名/累积胆汁/一撞多/多控达成/坦克一爪多中/坦克拍物多中.",
	version		= PLUGIN_VERSION,
	url			= "N/A"
}

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
float g_fExplodeStart[MAXPLAYERS+1];	// 爆炸判定窗口起始时间
int   g_iExplodeCount[MAXPLAYERS+1];	// 被炸到的不重复生还者数
bool  g_bExplodeVictim[MAXPLAYERS+1][MAXPLAYERS+1];
char  g_sExplodeName[MAXPLAYERS+1][MAX_NAME_LENGTH];	// 开窗时记录的特感名(爆炸后 boomer 已死亡)
int   g_iLastExplodedBoomer;			// 最近爆炸的 boomer 的 userid(now_it 攻击者异常时的回退)
float g_fLastExplodedTime;				// 最近爆炸发生的游戏时间

// ====================================================================================================
// Boomer 一轮生命累积胆汁状态(按 boomer 玩家索引, 生成到死亡)
// ====================================================================================================
bool  g_bBoomerBiledTracked[MAXPLAYERS+1];			// 本轮生命是否已有胆汁命中记录(死亡瞬间类别被重置时的兜底判据)
bool  g_bBoomerBiled[MAXPLAYERS+1][MAXPLAYERS+1];	// 本轮被胆汁命中过的不重复生还者(主动喷吐 + 死亡爆炸)
int   g_iBoomerBiledCount[MAXPLAYERS+1];			// 本轮被胆汁命中的不重复生还者数
bool  g_bBoomerReportPending[MAXPLAYERS+1];			// 死亡后等待爆炸糊人事件到齐再播报
float g_fBoomerDeathTime[MAXPLAYERS+1];				// 死亡时刻(游戏时间)
char  g_sBoomerDeathName[MAXPLAYERS+1][MAX_NAME_LENGTH];	// 死亡时缓存的名字(播报时角色可能已失效)

// ====================================================================================================
// Charger 一撞多状态(按 charger 玩家索引)
// ====================================================================================================
bool  g_bChargerReady[MAXPLAYERS+1];	// 本次冲撞是否处于可计数窗口内
int   g_iChargerCount[MAXPLAYERS+1];	// 本次冲撞撞到的不重复生还者数
bool  g_bChargerHit[MAXPLAYERS+1][MAXPLAYERS+1];

// ====================================================================================================
// Tank 一爪多中 / 拍打移动物品一物多中状态(按 tank 玩家索引)
// ====================================================================================================
enum TankHitType
{
	TankHit_Claw,		// 左键爪子
	TankHit_Prop		// 拍打移动物品
}

bool  g_bTankHitActive[TankHitType][MAXPLAYERS+1];	// 当前是否处于一次攻击窗口内
float g_fTankHitStart[TankHitType][MAXPLAYERS+1];	// 本次攻击窗口起始时间
int   g_iTankHitCount[TankHitType][MAXPLAYERS+1];	// 本次命中的不重复生还者数
bool  g_bTankHitVictim[TankHitType][MAXPLAYERS+1][MAXPLAYERS+1];

// ====================================================================================================
// 多控达成状态
// ====================================================================================================
int   g_iMultiPinnedAnnounced = 0;		// 上次已提示的控住生还者人数(0=未提示)

// ====================================================================================================
// ConVar
// ====================================================================================================
ConVar g_cvBoomerSprayMin;
ConVar g_cvBoomerExplodeMin;
ConVar g_cvBoomerBiledMin;
ConVar g_cvChargerMin;
ConVar g_cvPinnedMin;
ConVar g_cvTankClawMin;
ConVar g_cvTankPropMin;

int g_iBoomerSprayMin;
int g_iBoomerExplodeMin;
int g_iBoomerBiledMin;
int g_iChargerMin;
int g_iPinnedMin;
int g_iTankHitMin[TankHitType];

// ====================================================================================================
// Plugin Start
// ====================================================================================================

public void OnPluginStart()
{
	g_cvBoomerSprayMin		= CreateConVar("l4d2_infected_highlight_boomer_spray_min",
											"2",
											"胖子存活状态下一口喷中多少个生还者时提示(>=2).",
											FCVAR_NOTIFY, true, 2.0, true, 16.0);
	g_cvBoomerExplodeMin	= CreateConVar("l4d2_infected_highlight_boomer_explode_min",
											"2",
											"胖子死亡爆炸一次炸到多少个生还者时提示(>=2).",
											FCVAR_NOTIFY, true, 2.0, true, 16.0);
	g_cvBoomerBiledMin		= CreateConVar("l4d2_infected_highlight_boomer_biled_min",
											"2",
											"胖子一轮生命(生成到死亡)累积喷中多少名生还者时, 死亡后提示(含主动喷吐与死亡爆炸).",
											FCVAR_NOTIFY, true, 1.0, true, 16.0);
	g_cvChargerMin			= CreateConVar("l4d2_infected_highlight_charger_min",
											"2",
											"冲锋者一次冲撞连续撞中多少个生还者时提示(>=2).",
											FCVAR_NOTIFY, true, 2.0, true, 16.0);
	g_cvPinnedMin			= CreateConVar("l4d2_infected_highlight_pinned_min",
											"2",
											"感染者阵营同时控住多少个生还者时提示(>=2).",
											FCVAR_NOTIFY, true, 2.0, true, 4.0);
	g_cvTankClawMin			= CreateConVar("l4d2_infected_highlight_tank_claw_min",
											"2",
											"Tank左键一爪同时拍中多少个生还者时提示(>=2).",
											FCVAR_NOTIFY, true, 2.0, true, 16.0);
	g_cvTankPropMin			= CreateConVar("l4d2_infected_highlight_tank_prop_min",
											"2",
											"Tank拍打移动物品一次同时命中多少个生还者时提示(>=2).",
											FCVAR_NOTIFY, true, 2.0, true, 16.0);

	GetCvars();

	g_cvBoomerSprayMin.AddChangeHook(OnConVarChanged);
	g_cvBoomerExplodeMin.AddChangeHook(OnConVarChanged);
	g_cvBoomerBiledMin.AddChangeHook(OnConVarChanged);
	g_cvChargerMin.AddChangeHook(OnConVarChanged);
	g_cvPinnedMin.AddChangeHook(OnConVarChanged);
	g_cvTankClawMin.AddChangeHook(OnConVarChanged);
	g_cvTankPropMin.AddChangeHook(OnConVarChanged);

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
	CreateTimer(EXPLODE_SCAN_INTERVAL, Timer_ScanExplode, _, TIMER_REPEAT);

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
	g_iBoomerBiledMin	= g_cvBoomerBiledMin.IntValue;
	g_iChargerMin		= g_cvChargerMin.IntValue;
	g_iPinnedMin		= g_cvPinnedMin.IntValue;
	g_iTankHitMin[TankHit_Claw]	= g_cvTankClawMin.IntValue;
	g_iTankHitMin[TankHit_Prop]	= g_cvTankPropMin.IntValue;
}

public void OnMapEnd()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		ResetSpray(i);
		ResetExplode(i);
		ResetBoomerBiled(i);
		ResetCharger(i);
		ResetTankHit(TankHit_Claw, i);
		ResetTankHit(TankHit_Prop, i);
	}

	g_iLastExplodedBoomer = 0;
	g_fLastExplodedTime = 0.0;
	g_iMultiPinnedAnnounced = 0;
}

public void OnClientDisconnect(int client)
{
	ResetSpray(client);
	ResetExplode(client);
	ResetCharger(client);
	ResetTankHit(TankHit_Claw, client);
	ResetTankHit(TankHit_Prop, client);

	// 待播报的累积胆汁记录保留(播报只用已缓存的名字与计数), 否则直接清空
	if (!g_bBoomerReportPending[client])
		ResetBoomerBiled(client);
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

		if (!IsInfectedPlayer(boomer))
		{
			// 攻击者异常(如爆炸瞬间 boomer 已转入灵魂状态、类别被重置)时的回退:
			// 使用最近一次 boomer_exploded 记录的 boomer(需在判定窗口时限内)
			boomer = GetClientOfUserId(g_iLastExplodedBoomer);

			if (!IsInfectedPlayer(boomer) || GetGameTime() - g_fLastExplodedTime > EXPLODE_WINDOW_TIME)
				return;
		}

		// 窗口未开, 或窗口属于上一次爆炸(boomer 极短时间复活再次被打爆): 开新窗结算
		if (!g_bExplodeActive[boomer] || GetGameTime() - g_fExplodeStart[boomer] >= EXPLODE_SAME_WINDOW_TIME)
			OpenExplodeWindow(boomer);

		if (!g_bExplodeVictim[boomer][victim])
		{
			g_bExplodeVictim[boomer][victim] = true;
			g_iExplodeCount[boomer]++;
		}

		// 本轮生命累积: 死亡爆炸糊到的生还者同样计入
		MarkBoomerBiled(boomer, victim);

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

	// 本轮生命累积: 主动喷吐糊到的生还者
	MarkBoomerBiled(attacker, victim);
}

public Action Timer_EndSpray(Handle timer, int userid)
{
	int boomer = GetClientOfUserId(userid);

	if (boomer > 0 && g_bSprayActive[boomer] && g_iSprayCount[boomer] >= g_iBoomerSprayMin)
	{
		char name[MAX_NAME_LENGTH];
		GetActorName(boomer, name, sizeof(name));

		PrintToInfectedTeam("\x04[\x03!\x04] \x05Boomer(\x03%s\x05) \x01一次性喷中\x04%d\x05名生还者",
			name, g_iSprayCount[boomer]);
	}

	if (boomer > 0)
		ResetSpray(boomer);

	return Plugin_Continue;
}

public void Event_BoomerExploded(Event event, const char[] name, bool dontBroadcast)
{
	int boomer = GetClientOfUserId(event.GetInt("userid"));

	// 爆炸瞬间 boomer 可能已转入灵魂状态(m_zombieClass 被重置), 不能按类别判断,
	// 只按"感染者阵营且在游戏中"判断(事件本身已保证 userid 是爆炸的 boomer)
	if (!IsInfectedPlayer(boomer))
		return;

	g_iLastExplodedBoomer = event.GetInt("userid");
	g_fLastExplodedTime = GetGameTime();

	// 爆炸即 boomer 死亡: 安排播报本轮累积喷中的生还者数(与 player_death 互为兜底, 幂等)
	ScheduleBoomerReport(boomer);

	// 同一次爆炸的 player_now_it 已先到达开窗(时间差小于容差)则保留已计数;
	// 时间差达到容差说明是 boomer 复活后的新一次爆炸, 重开窗口(会先结算上一次)
	if (!g_bExplodeActive[boomer] || GetGameTime() - g_fExplodeStart[boomer] >= EXPLODE_SAME_WINDOW_TIME)
		OpenExplodeWindow(boomer);
}

void OpenExplodeWindow(int boomer)
{
	// 上一次爆炸的窗口还未结算(boomer 极短时间复活再次被打爆): 先结算上一次再开新窗
	if (g_bExplodeActive[boomer])
		PrintExplode(boomer);

	g_bExplodeActive[boomer] = true;
	g_fExplodeStart[boomer] = GetGameTime();
	g_iExplodeCount[boomer] = 0;

	for (int i = 1; i <= MaxClients; i++)
		g_bExplodeVictim[boomer][i] = false;

	// 爆炸后 boomer 立即死亡, 先记录名字, 结算时不再解析实体
	GetActorName(boomer, g_sExplodeName[boomer], MAX_NAME_LENGTH);
}

// 周期扫描到期的爆炸窗口并结算(替代一次性结算计时器, 避免极短时间复活再次爆炸时新旧窗口/计时器错配)
public Action Timer_ScanExplode(Handle timer)
{
	float now = GetGameTime();

	for (int i = 1; i <= MaxClients; i++)
	{
		if (g_bExplodeActive[i] && now - g_fExplodeStart[i] >= EXPLODE_WINDOW_TIME)
		{
			PrintExplode(i);
			ResetExplode(i);
		}

		// boomer 死亡后等爆炸糊人事件到齐, 再播报本轮(生成到死亡)累积喷中的生还者数
		if (g_bBoomerReportPending[i] && now - g_fBoomerDeathTime[i] >= BOOMER_REPORT_DELAY)
		{
			PrintBoomerBiled(i);
			ResetBoomerBiled(i);
		}
	}

	return Plugin_Continue;
}

void PrintExplode(int boomer)
{
	if (g_iExplodeCount[boomer] < g_iBoomerExplodeMin)
		return;

	PrintToInfectedTeam("\x04[\x03!\x04] \x05Boomer(\x03%s\x05) \x01爆炸炸到\x04%d\x05名生还者",
		g_sExplodeName[boomer], g_iExplodeCount[boomer]);
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
	g_fExplodeStart[boomer] = 0.0;
	g_iExplodeCount[boomer] = 0;

	for (int i = 1; i <= MaxClients; i++)
		g_bExplodeVictim[boomer][i] = false;

	g_sExplodeName[boomer][0] = '\0';
}

// 记录一次胆汁命中(主动喷吐与死亡爆炸都算), 同一名生还者一轮生命只记一次
void MarkBoomerBiled(int boomer, int victim)
{
	g_bBoomerBiledTracked[boomer] = true;

	if (g_bBoomerBiled[boomer][victim])
		return;

	g_bBoomerBiled[boomer][victim] = true;
	g_iBoomerBiledCount[boomer]++;
}

// boomer 死亡: 缓存名字并挂起播报, 等爆炸糊人的 player_now_it 事件到齐后由周期扫描统一输出
void ScheduleBoomerReport(int boomer)
{
	if (g_bBoomerReportPending[boomer])
		return;

	g_bBoomerReportPending[boomer] = true;
	g_fBoomerDeathTime[boomer] = GetGameTime();

	GetActorName(boomer, g_sBoomerDeathName[boomer], MAX_NAME_LENGTH);
}

void PrintBoomerBiled(int boomer)
{
	if (g_iBoomerBiledCount[boomer] < g_iBoomerBiledMin)
		return;

	PrintToInfectedTeam("\x04[\x03!\x04] \x05Boomer(\x03%s\x05) \x01累积对\x04%d\x05名生还者喷射胆汁",
		g_sBoomerDeathName[boomer], g_iBoomerBiledCount[boomer]);
}

void ResetBoomerBiled(int boomer)
{
	g_bBoomerBiledTracked[boomer] = false;
	g_iBoomerBiledCount[boomer] = 0;
	g_bBoomerReportPending[boomer] = false;
	g_fBoomerDeathTime[boomer] = 0.0;
	g_sBoomerDeathName[boomer][0] = '\0';

	for (int i = 1; i <= MaxClients; i++)
		g_bBoomerBiled[boomer][i] = false;
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

	// Charger 一撞多
	if (IsCharger(attacker) && IsPlayerAlive(attacker))
	{
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
		return;
	}

	// Tank 左键一爪 / 拍打移动物品
	if (!IsTank(attacker) || !IsPlayerAlive(attacker))
		return;

	char weapon[32];
	event.GetString("weapon", weapon, sizeof(weapon));
	int dmg = event.GetInt("dmg_health");

	if (dmg < 1)
		return;

	if (strcmp(weapon, "tank_claw") == 0 || strcmp(weapon, "weapon_tank_claw") == 0)
	{
		CountTankHit(TankHit_Claw, attacker, client);
	}
	else if (strncmp(weapon, "prop_", 5) == 0)
	{
		CountTankHit(TankHit_Prop, attacker, client);
	}
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

	if (client <= 0)
		return;

	// Boomer 死亡: 安排播报本轮(生成到死亡)累积喷中的生还者数
	// (死亡瞬间 m_zombieClass 可能已被重置, 本轮已有胆汁记录时同样认定)
	if (IsBoomer(client) || g_bBoomerBiledTracked[client])
		ScheduleBoomerReport(client);

	if (!IsCharger(client))
		return;

	// 冲锋途中死亡的兜底结算点
	SettleCharger(client);
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	if (client <= 0)
		return;

	// 任何一次生成都是一轮新生命: 清空上一轮的 boomer 累积胆汁记录
	ResetBoomerBiled(client);

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

	PrintToInfectedTeam("\x04[\x03!\x04] \x05Charger(\x03%s\x05) \x01冲撞连续撞中\x04%d\x05名生还者",
		name, g_iChargerCount[charger]);
}

// ====================================================================================================
// Tank 一爪多中 / 拍打移动物品一物多中
// ====================================================================================================

void CountTankHit(TankHitType type, int tank, int victim)
{
	float now = GetGameTime();

	if (!g_bTankHitActive[type][tank])
	{
		g_bTankHitActive[type][tank] = true;
		g_fTankHitStart[type][tank] = now;
		CreateTankHitTimer(type, tank);
	}
	else if (now - g_fTankHitStart[type][tank] > TANK_HIT_WINDOW_TIME)
	{
		// 窗口已过期但结算计时器尚未运行, 重新开窗
		ResetTankHit(type, tank);
		g_bTankHitActive[type][tank] = true;
		g_fTankHitStart[type][tank] = now;
		CreateTankHitTimer(type, tank);
	}

	if (!g_bTankHitVictim[type][tank][victim])
	{
		g_bTankHitVictim[type][tank][victim] = true;
		g_iTankHitCount[type][tank]++;
	}
}

void CreateTankHitTimer(TankHitType type, int tank)
{
	DataPack pack = new DataPack();
	pack.WriteCell(view_as<int>(type));
	pack.WriteCell(GetClientUserId(tank));
	CreateTimer(TANK_HIT_WINDOW_TIME, Timer_EndTankHit, pack, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_EndTankHit(Handle timer, DataPack pack)
{
	pack.Reset();
	TankHitType type = view_as<TankHitType>(pack.ReadCell());
	int userid = pack.ReadCell();
	delete pack;

	int tank = GetClientOfUserId(userid);

	if (tank > 0 && g_bTankHitActive[type][tank] && g_iTankHitCount[type][tank] >= g_iTankHitMin[type])
	{
		char name[MAX_NAME_LENGTH];
		GetActorName(tank, name, sizeof(name));

		if (type == TankHit_Claw)
		{
			PrintToInfectedTeam("\x04[\x03!\x04] \x05Tank(\x03%s\x05) 一次性\x01拍中\x04%d\x05名生还者",
				name, g_iTankHitCount[type][tank]);
		}
		else
		{
			PrintToInfectedTeam("\x04[\x03!\x04] \x05Tank(\x03%s\x05) \x01拍打移动物品连续命中\x04%d\x05名生还者",
				name, g_iTankHitCount[type][tank]);
		}
	}

	if (tank > 0)
		ResetTankHit(type, tank);

	return Plugin_Continue;
}

void ResetTankHit(TankHitType type, int tank)
{
	g_bTankHitActive[type][tank] = false;
	g_fTankHitStart[type][tank] = 0.0;
	g_iTankHitCount[type][tank] = 0;

	for (int i = 1; i <= MaxClients; i++)
		g_bTankHitVictim[type][tank][i] = false;
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
		// 控住人数上升到新档位时逐级提示: 2控 → 3控 → 4控 ...
		if (pinned > g_iMultiPinnedAnnounced)
		{
			PrintToInfectedTeam("\x04[\x03!\x04] \x03特感阵营达成\x04%d\x05控", pinned);
			g_iMultiPinnedAnnounced = pinned;
		}
	}
	else
	{
		g_iMultiPinnedAnnounced = 0;
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

// 感染者阵营玩家(含已死亡/灵魂状态): 不依赖 m_zombieClass, 死亡瞬间类别会被重置
bool IsInfectedPlayer(int client)
{
	return client > 0 && client <= MaxClients && IsClientInGame(client) && GetClientTeam(client) == 3;
}

bool IsCharger(int client)
{
	return client > 0 &&
			client <= MaxClients &&
			IsClientInGame(client) &&
			GetClientTeam(client) == 3 &&
			GetEntProp(client, Prop_Send, "m_zombieClass") == 6;
}

bool IsTank(int client)
{
	return client > 0 &&
			client <= MaxClients &&
			IsClientInGame(client) &&
			GetClientTeam(client) == 3 &&
			GetEntProp(client, Prop_Send, "m_zombieClass") == 8;
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
