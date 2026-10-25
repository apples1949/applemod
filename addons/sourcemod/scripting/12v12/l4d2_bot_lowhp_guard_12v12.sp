/*
 * ============================================================================
 * L4D2 Bot Low HP Guard (12v12)
 *
 * 面向 applemod12v12 配置：只处理"非玩家操控的生还者"（AI 生还者 / bot）。
 *
 * 核心逻辑：
 *   当 AI 生还者的"总血量"（实血 m_iHealth + 虚血 / 临时血量 healthBuffer）
 *   合计 <= 阈值（默认 25）时进入"守护状态"：
 *     1. 间歇性闪蓝色轮廓（参考 l4d2_tank_defib_revive / LMC_Black_and_White_Notifier
 *        的蓝光写法：m_iGlowType=3 + m_glowColorOverride + m_nGlowRange，
 *        由定时器按固定节奏开关，形成"闪"的效果）；
 *     2. 免疫任何伤害（SDKHook_OnTakeDamage 直接 Handled，参考 rygive 的 OnTakeDamage）；
 *     3. 免疫任何特殊感染者的控制技能（舌头/扑击/骑乘/冲撞，走 Left4DHooks 的前置
 *        forward，参考 rygive 的 ReleaseControl 用法）；
 *     4. 若进入守护状态时已经被控住，立即解控（舌头拖拽 / 猎人扑倒 / 猴子骑乘 /
 *        牛冲撞与捶打）；
 *     5. 虚血冻结：守护期间虚血不再自然流失（按定时器把 healthBuffer 写回原值）。
 *
 *   另外（与血量无关的兜底）：
 *     未被玩家操控的生还者倒地后自动救起，每次数上限（默认 1 次 / 回合）。
 *     这条是为了应付"生还者被控倒地后玩家离开服务器，变成无人接管的 bot，
 *     没人来救"的情况。次数在回合开始时重置。
 *
 * 安全设计（重要，改动前请先读）：
 *   - 守护状态只对"存活且未倒地"的 bot 生效。倒地后守护会自动关闭，
 *     避免"倒地 + 免伤 + 不能流血死亡"造成永久卡关；倒地由自动救起兜底
 *     （次数用完后按正常规则流血死亡）。
 *   - 守护结束时会把进入守护前的三个发光 netprop 原值写回去，
 *     避免污染其它插件的发光效果。
 * ============================================================================
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>

#define PLUGIN_VERSION		"1.0.0"

#define TEAM_SURVIVOR		2

// m_iGlowType = 3 是 L4D2 的"常亮轮廓"（参考 l4d2_tank_defib_revive 的写法）
#define GLOW_TYPE_CONSTANT	3

ConVar g_cvEnabled;			// 总开关
ConVar g_cvHealth;			// 触发阈值（实血 + 虚血 合计 <= 该值）
ConVar g_cvGlow;			// 是否闪蓝色轮廓
ConVar g_cvGlowColor;		// 轮廓颜色 "R G B"
ConVar g_cvGlowRange;		// 轮廓可见距离
ConVar g_cvInterval;		// 检测/闪烁节奏（秒）
ConVar g_cvInvincible;		// 免疫任何伤害
ConVar g_cvBlockControl;	// 免疫特感控制 + 已控则解控
ConVar g_cvReviveTimes;		// 每回合自动救起次数
ConVar g_cvReviveHealth;	// 自动救起后的血量
ConVar g_cvReviveDelay;		// 倒地后延迟多久救起（秒）
ConVar g_cvNotify;			// 自动救起时是否聊天框提示

bool	g_bGuarded[MAXPLAYERS + 1];			// 当前是否处于守护状态
bool	g_bGlowProps[MAXPLAYERS + 1];		// 该客户端是否有完整的发光 netprop（没有就不写，避免每 tick 刷属性错误）
int		g_iOrigGlowType[MAXPLAYERS + 1];	// 进入守护前的 m_iGlowType
int		g_iOrigGlowColor[MAXPLAYERS + 1];	// 进入守护前的 m_glowColorOverride
int		g_iOrigGlowRange[MAXPLAYERS + 1];	// 进入守护前的 m_nGlowRange
float	g_fTempStash[MAXPLAYERS + 1];		// 守护开始时冻结的虚血值
int		g_iReviveLeft[MAXPLAYERS + 1];		// 本回合剩余的自动救起次数

int		g_iGlowColorPacked;					// 打包后的颜色值（R | G<<8 | B<<16）
bool	g_bBlinkPhase;						// 闪烁相位（每 tick 取反）

Handle	g_hTickTimer;

public Plugin myinfo =
{
	name        = "L4D2 Bot Low HP Guard (12v12)",
	author      = "apples1949",
	description = "非玩家操控的生还者总血量<=25时闪蓝光/免疫伤害/免疫特感控制/被控即解控，并支持每回合一次自动救起",
	version     = PLUGIN_VERSION,
	url         = "N/A"
};

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
	g_cvEnabled = CreateConVar("l4d2_bot_guard_enabled",
		"1",
		"总开关. 0=关闭, 1=启用.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvHealth = CreateConVar("l4d2_bot_guard_health",
		"25",
		"AI 生还者总血量(实血 + 虚血)低于或等于该值时进入守护状态.",
		FCVAR_NOTIFY, true, 1.0, true, 200.0);

	g_cvGlow = CreateConVar("l4d2_bot_guard_glow",
		"1",
		"守护状态下是否间歇闪蓝色轮廓. 0=关闭, 1=启用.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvGlowColor = CreateConVar("l4d2_bot_guard_glow_color",
		"0 0 255",
		"轮廓颜色, 格式 \"R G B\"（默认 0 0 255 = 蓝色）.");

	g_cvGlowRange = CreateConVar("l4d2_bot_guard_glow_range",
		"800",
		"轮廓可见距离（游戏单位）.",
		FCVAR_NOTIFY, true, 0.0, true, 10000.0);

	g_cvInterval = CreateConVar("l4d2_bot_guard_interval",
		"0.25",
		"检测与闪烁节奏（秒）: 每该间隔检查一次状态并切换一次轮廓开关.",
		FCVAR_NOTIFY, true, 0.05, true, 5.0);

	g_cvInvincible = CreateConVar("l4d2_bot_guard_invincible",
		"1",
		"守护状态下免疫任何伤害. 0=关闭, 1=启用.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvBlockControl = CreateConVar("l4d2_bot_guard_block_control",
		"1",
		"守护状态下免疫特感控制(舌头/扑击/骑乘/冲撞), 且已被控时立即解控. 0=关闭, 1=启用.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvReviveTimes = CreateConVar("l4d2_bot_guard_revive_times",
		"1",
		"AI 生还者每回合可自动救起次数（0=关闭自动救起）.",
		FCVAR_NOTIFY, true, 0.0, true, 10.0);

	g_cvReviveHealth = CreateConVar("l4d2_bot_guard_revive_health",
		"30",
		"自动救起后设置的血量.",
		FCVAR_NOTIFY, true, 1.0, true, 100.0);

	g_cvReviveDelay = CreateConVar("l4d2_bot_guard_revive_delay",
		"1.0",
		"AI 生还者倒地后延迟多少秒自动救起.",
		FCVAR_NOTIFY, true, 0.0, true, 30.0);

	g_cvNotify = CreateConVar("l4d2_bot_guard_notify",
		"1",
		"自动救起时是否在聊天框提示. 0=关闭, 1=启用.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// 按 workspace 约定：不生成插件 cfg（不用 AutoExecConfig），
	// 全部参数由 applemod12v12 的 confogl_addcvar 下发
	ParseGlowColor();
	g_cvGlowColor.AddChangeHook(OnConVarChanged);
	g_cvInterval.AddChangeHook(OnConVarChanged);

	HookEvent("player_incapacitated", Event_PlayerIncapacitated, EventHookMode_Post);
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);

	// 晚加载：已经连进来的客户端也要补挂伤害钩子
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
			OnClientPutInServer(i);
	}

	StartTickTimer();
}

public void OnMapStart()
{
	g_bBlinkPhase = false;
	for (int i = 0; i <= MaxClients; i++)
	{
		g_bGuarded[i] = false;
		g_fTempStash[i] = 0.0;
	}
}

public void OnPluginEnd()
{
	if (g_hTickTimer != null)
	{
		delete g_hTickTimer;
		g_hTickTimer = null;
	}

	// 卸载时把轮廓恢复成进入守护前的样子，避免残留
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && g_bGuarded[i])
		{
			if (g_bGlowProps[i])
			{
				SetEntProp(i, Prop_Send, "m_iGlowType", g_iOrigGlowType[i]);
				SetEntProp(i, Prop_Send, "m_glowColorOverride", g_iOrigGlowColor[i]);
				SetEntProp(i, Prop_Send, "m_nGlowRange", g_iOrigGlowRange[i]);
			}

			g_bGuarded[i] = false;
		}
	}
}

public void OnClientPutInServer(int client)
{
	g_bGuarded[client] = false;
	g_bGlowProps[client] = false;
	g_fTempStash[client] = 0.0;
	g_iReviveLeft[client] = g_cvReviveTimes.IntValue;

	// 每个客户端都要挂伤害钩子（r ygive 同款做法：进服即挂）
	SDKHook(client, SDKHook_OnTakeDamage, Hook_OnTakeDamage);
}

public void OnClientDisconnect(int client)
{
	g_bGuarded[client] = false;
	g_bGlowProps[client] = false;
	g_fTempStash[client] = 0.0;
	g_iReviveLeft[client] = 0;
}

public void OnConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (convar == g_cvGlowColor)
	{
		ParseGlowColor();
		for (int i = 1; i <= MaxClients; i++)
		{
			if (g_bGuarded[i])
				ApplyGlow(i, true);
		}
	}
	else if (convar == g_cvInterval)
	{
		StartTickTimer();
	}
}

void StartTickTimer()
{
	if (g_hTickTimer != null)
	{
		delete g_hTickTimer;
		g_hTickTimer = null;
	}

	float fInterval = g_cvInterval.FloatValue;
	if (fInterval < 0.05)
		fInterval = 0.05;

	g_hTickTimer = CreateTimer(fInterval, Timer_Tick, _, TIMER_REPEAT);
}

// ============================================================================
// 状态机
// ============================================================================

public Action Timer_Tick(Handle timer)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
		{
			g_bGuarded[i] = false;
			continue;
		}

		bool bWant = ShouldGuard(i);

		if (bWant && !g_bGuarded[i])
		{
			EnterGuard(i);
		}
		else if (!bWant && g_bGuarded[i])
		{
			LeaveGuard(i);
		}

		if (!g_bGuarded[i])
			continue;

		// 虚血冻结：引擎会按时间自然扣减 healthBuffer，
		// 这里按节奏把它写回守护开始时的值（L4D_SetTempHealth 同时刷新 m_healthBufferTime）
		if (g_fTempStash[i] > 0.0 && L4D_GetTempHealth(i) < g_fTempStash[i])
			L4D_SetTempHealth(i, g_fTempStash[i]);

		// 已被控住的立即解控（"被控时血量掉到 25 及以下就取消控制"）
		if (g_cvBlockControl.BoolValue)
			ReleaseControl(i);
	}

	// 间歇闪烁：每 tick 翻转一次相位
	if (g_cvGlow.BoolValue)
	{
		g_bBlinkPhase = !g_bBlinkPhase;

		for (int i = 1; i <= MaxClients; i++)
		{
			if (g_bGuarded[i])
				ApplyGlow(i, g_bBlinkPhase);
		}
	}

	return Plugin_Continue;
}

// 是否应该进入守护状态
bool ShouldGuard(int client)
{
	if (!g_cvEnabled.BoolValue)
		return false;

	if (!IsClientInGame(client))
		return false;

	// 只处理生还者队伍里"非玩家操控"的那些
	if (GetClientTeam(client) != TEAM_SURVIVOR)
		return false;

	if (!IsFakeClient(client))
		return false;

	if (!IsPlayerAlive(client))
		return false;

	// 倒地后守护关闭：倒地 + 免伤 + 不能流血会造成永久卡关，
	// 倒地统一交给下面的"自动救起"处理
	if (IsIncapacitated(client))
		return false;

	return GetTotalHealth(client) <= g_cvHealth.IntValue;
}

void EnterGuard(int client)
{
	g_bGuarded[client] = true;

	// 先确认这个客户端真的有完整的发光 netprop；没有就整段跳过，
	// 否则 4Hz 写不存在的属性会在服务器日志里刷错误
	g_bGlowProps[client] = HasEntProp(client, Prop_Send, "m_iGlowType")
		&& HasEntProp(client, Prop_Send, "m_glowColorOverride")
		&& HasEntProp(client, Prop_Send, "m_nGlowRange");

	// 记录进入守护前的发光状态，退出时原样写回
	if (g_bGlowProps[client])
	{
		g_iOrigGlowType[client] = GetEntProp(client, Prop_Send, "m_iGlowType");
		g_iOrigGlowColor[client] = GetEntProp(client, Prop_Send, "m_glowColorOverride");
		g_iOrigGlowRange[client] = GetEntProp(client, Prop_Send, "m_nGlowRange");
	}

	// 冻结当前虚血
	g_fTempStash[client] = L4D_GetTempHealth(client);

	if (g_cvGlow.BoolValue)
		ApplyGlow(client, true);

	// 进入守护的瞬间若正被控制，立即解控
	if (g_cvBlockControl.BoolValue)
		ReleaseControl(client);
}

void LeaveGuard(int client)
{
	g_bGuarded[client] = false;
	g_fTempStash[client] = 0.0;

	if (!IsClientInGame(client) || !g_bGlowProps[client])
		return;

	// 恢复进入守护前的发光 netprop
	SetEntProp(client, Prop_Send, "m_iGlowType", g_iOrigGlowType[client]);
	SetEntProp(client, Prop_Send, "m_glowColorOverride", g_iOrigGlowColor[client]);
	SetEntProp(client, Prop_Send, "m_nGlowRange", g_iOrigGlowRange[client]);
}

// ============================================================================
// 蓝色轮廓（参考 l4d2_tank_defib_revive 的 SetBlackWhiteOutline）
// ============================================================================

void ApplyGlow(int client, bool bOn)
{
	if (!g_bGlowProps[client])
		return;

	if (bOn)
	{
		SetEntProp(client, Prop_Send, "m_iGlowType", GLOW_TYPE_CONSTANT);
		SetEntProp(client, Prop_Send, "m_glowColorOverride", g_iGlowColorPacked);
		SetEntProp(client, Prop_Send, "m_nGlowRange", g_cvGlowRange.IntValue);
	}
	else
	{
		// 闪的"灭"相位：只关类型，颜色留着不动，减少无意义写属性
		SetEntProp(client, Prop_Send, "m_iGlowType", 0);
	}
}

// 把 "R G B" 解析成 L4D2 的打包颜色（R | G<<8 | B<<16）
void ParseGlowColor()
{
	char sBuffer[64];
	g_cvGlowColor.GetString(sBuffer, sizeof(sBuffer));

	char sParts[3][8];
	int iR = 0;
	int iG = 0;
	int iB = 0;

	// 手工解析，避免多参数刷屏
	if (ExplodeString(sBuffer, " ", sParts, sizeof(sParts), sizeof(sParts[])) == 3)
	{
		iR = ClampInt(StringToInt(sParts[0]));
		iG = ClampInt(StringToInt(sParts[1]));
		iB = ClampInt(StringToInt(sParts[2]));
	}

	g_iGlowColorPacked = iR | (iG << 8) | (iB << 16);
}

int ClampInt(int iValue)
{
	if (iValue < 0)
		return 0;
	if (iValue > 255)
		return 255;
	return iValue;
}

// ============================================================================
// 免疫伤害（参考 rygive 的 OnTakeDamage god mode）
// ============================================================================

public Action Hook_OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage,
	int &damagetype, int &weapon, float damageForce[3], float damagePosition[3], int damagecustom)
{
	if (!g_cvInvincible.BoolValue || victim <= 0 || victim > MaxClients)
		return Plugin_Continue;

	// 守护状态本身已排除"倒地/死亡/真人接管"，这里只要状态在就直接免伤
	if (!g_bGuarded[victim])
		return Plugin_Continue;

	damage = 0.0;
	return Plugin_Handled;
}

// ============================================================================
// 免控 / 解控
// ============================================================================

// 参考 rygive.sp: ReleaseControl()
void ReleaseControl(int victim)
{
	int attacker;

	attacker = GetEntPropEnt(victim, Prop_Send, "m_tongueOwner");
	if (attacker > 0 && attacker <= MaxClients)
		L4D_Smoker_ReleaseVictim(victim, attacker);

	attacker = GetEntPropEnt(victim, Prop_Send, "m_pounceAttacker");
	if (attacker > 0 && attacker <= MaxClients)
		L4D_Hunter_ReleaseVictim(victim, attacker);

	attacker = GetEntPropEnt(victim, Prop_Send, "m_jockeyAttacker");
	if (attacker > 0 && attacker <= MaxClients)
		L4D2_Jockey_EndRide(victim, attacker);

	attacker = GetEntPropEnt(victim, Prop_Send, "m_carryAttacker");
	if (attacker > 0 && attacker <= MaxClients)
		L4D2_Charger_EndCarry(victim, attacker);

	attacker = GetEntPropEnt(victim, Prop_Send, "m_pummelAttacker");
	if (attacker > 0 && attacker <= MaxClients)
		L4D2_Charger_EndPummel(victim, attacker);
}

// 舌头：前置 forward 拦下等于"抓不到"
public Action L4D_OnGrabWithTongue(int victim, int attacker)
{
	if (BlockControlOn(victim))
		return Plugin_Handled;

	return Plugin_Continue;
}

// 猎人扑击
public Action L4D_OnPouncedOnSurvivor(int victim, int attacker)
{
	if (BlockControlOn(victim))
		return Plugin_Handled;

	return Plugin_Continue;
}

// 猴子骑乘
public Action L4D2_OnJockeyRide(int victim, int attacker)
{
	if (BlockControlOn(victim))
		return Plugin_Handled;

	return Plugin_Continue;
}

// 牛冲撞抱人
public Action L4D2_OnStartCarryingVictim(int victim, int attacker)
{
	if (BlockControlOn(victim))
		return Plugin_Handled;

	return Plugin_Continue;
}

bool BlockControlOn(int victim)
{
	if (!g_cvBlockControl.BoolValue)
		return false;

	if (victim <= 0 || victim > MaxClients)
		return false;

	return g_bGuarded[victim];
}

// ============================================================================
// 自动救起（每回合每名 AI 生还者一次）
// ============================================================================

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	// 回合开始时重置每名客户端的自动救起次数
	for (int i = 0; i <= MaxClients; i++)
		g_iReviveLeft[i] = g_cvReviveTimes.IntValue;
}

public void Event_PlayerIncapacitated(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnabled.BoolValue || g_cvReviveTimes.IntValue <= 0)
		return;

	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!IsGuardTarget(client))
		return;

	if (g_iReviveLeft[client] <= 0)
		return;

	float fDelay = g_cvReviveDelay.FloatValue;
	if (fDelay < 0.0)
		fDelay = 0.0;

	CreateTimer(fDelay, Timer_AutoRevive, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_AutoRevive(Handle timer, any iUserId)
{
	int client = GetClientOfUserId(iUserId);

	if (!IsGuardTarget(client))
		return Plugin_Stop;

	// 期间被别人救起 / 已经死亡就不用管了
	if (!IsIncapacitated(client))
		return Plugin_Stop;

	if (g_iReviveLeft[client] <= 0)
		return Plugin_Stop;

	g_iReviveLeft[client]--;

	// Left4DHooks: 让倒地/挂边生还者起身
	L4D_ReviveSurvivor(client);

	int iHealth = g_cvReviveHealth.IntValue;
	if (iHealth < 1)
		iHealth = 1;

	SetEntityHealth(client, iHealth);

	if (g_cvNotify.BoolValue)
	{
		if (g_iReviveLeft[client] > 0)
		{
			PrintToChatAll("\x03[提示] \x01AI 生还者 %N 已自动救起（本回合剩余自动救起 %d 次）。",
				client, g_iReviveLeft[client]);
		}
		else
		{
			PrintToChatAll("\x03[提示] \x01AI 生还者 %N 已自动救起（本回合自动救起次数已用完）。", client);
		}
	}

	return Plugin_Stop;
}

// ============================================================================
// 工具
// ============================================================================

// 是否是"非玩家操控的生还者"（自动救起的目标）
bool IsGuardTarget(int client)
{
	if (client <= 0 || client > MaxClients)
		return false;

	if (!IsClientInGame(client))
		return false;

	if (GetClientTeam(client) != TEAM_SURVIVOR)
		return false;

	if (!IsFakeClient(client))
		return false;

	return IsPlayerAlive(client);
}

bool IsIncapacitated(int client)
{
	return GetEntProp(client, Prop_Send, "m_isIncapacitated", 1) != 0;
}

// 总血量 = 实血 + 虚血（临时血量，已扣减自然衰减）
int GetTotalHealth(int client)
{
	int iReal = GetClientHealth(client);
	float fTemp = L4D_GetTempHealth(client);

	if (iReal < 0)
		iReal = 0;

	if (fTemp < 0.0)
		fTemp = 0.0;

	return iReal + RoundToNearest(fTemp);
}
