/* ============================================================================
 * [L4D2] Tank Defib Revive
 *
 * 坦克死亡后：
 *   - 若有生还者死亡：给离死亡生还者最近的存活生还者一个除颤器。
 *   - 若没有生还者死亡：在坦克死亡处生成一个除颤器。
 *
 * 接管除颤器复活效果（所有除颤器）：
 *   - 复活的生还者初始血量由 cvar 控制，默认 20（虚血模式）。
 *   - 复活后为黑白状态，倒地次数 = survivor_max_incapacitated_count。
 *   - 之后按间隔给血，默认每 3 秒 5 点，共 8 次；期间虚血不自然流失。
 *   - 回满后去掉黑白；中途打包/倒地默认停止后续回血。
 *   - 可在指定回血次数后把倒地次数改为目标值。
 *   - 复活后起身(到完全站立)期间豁免 Spitter 酸液伤害；
 *     若起身中被特殊感染者直接控住(扑倒/骑乘/拖拽/冲撞)，立即取消豁免。
 * ========================================================================== */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>

#define PLUGIN_VERSION		"1.6"

#define TEAM_SURVIVOR		2
#define TEAM_INFECTED		3
#define ZC_TANK				8
#define ZC_SPITTER			4

#define MODEL_DEFIB			"models/w_models/weapons/w_eq_defibrillator.mdl"
#define CLASS_DEFIB_SPAWN	"weapon_defibrillator_spawn"

#define GLOW_COLOR_BLUE		16711680	// 0 0 255
#define GLOW_RANGE			800

// Spitter 酸液伤害：CInsectSwarm::GetDamageType() = 263168 (DMG_RADIATION|DMG_ENERGYBEAM)
#define DMG_TYPE_SPIT		(DMG_RADIATION | DMG_ENERGYBEAM)
#define CLASS_SPIT_GOO		"insect_swarm"
#define CLASS_SPIT_PROJ		"spitter_projectile"

// 起身豁免：电击瞬间与游戏写入起身状态之间可能差几帧，先保证这段宽限不被判结束
#define SPIT_IMMUNE_GRACE		0.3
// 起身豁免：迟迟观察不到起身状态时，最多再等这么久就按兜底收手
#define SPIT_IMMUNE_WAIT_MAX	1.5

ConVar g_cvEnable;
ConVar g_cvGiveMode;
ConVar g_cvTakeover;
ConVar g_cvInitialHealth;
ConVar g_cvInitialHealthType;
ConVar g_cvInitialReviveCount;
ConVar g_cvHealAmount;
ConVar g_cvHealInterval;
ConVar g_cvContinueOnInterrupt;
ConVar g_cvTempDecay;
ConVar g_cvHealCount;
ConVar g_cvReviveCountTick;
ConVar g_cvReviveCountSet;
ConVar g_cvSpitImmune;
ConVar g_cvSpitImmuneMax;

ConVar g_hGameMaxIncap;
ConVar g_hPillsDecayRate;

// 每个客户端的回血状态
bool g_bHealing[MAXPLAYERS + 1];
int g_iHealTick[MAXPLAYERS + 1];
int g_iHealTotal[MAXPLAYERS + 1];
float g_fHealInterval[MAXPLAYERS + 1];
int g_iHealAmount[MAXPLAYERS + 1];
bool g_bHealTypeTemp[MAXPLAYERS + 1];
int g_iReviveCountTick[MAXPLAYERS + 1];
int g_iReviveCountSet[MAXPLAYERS + 1];
bool g_bReviveCountApplied[MAXPLAYERS + 1];
Handle g_hHealTimer[MAXPLAYERS + 1];
int g_iHealingCount;

// 生还者死亡位置（坦克死亡时用于计算最近生还者）
float g_vDeathPos[MAXPLAYERS + 1][3];
bool g_bHasDeathPos[MAXPLAYERS + 1];

// 换克时旧坦克死亡不应触发除颤器掉落
bool g_bSwappedTank[MAXPLAYERS + 1];

// 本插件复活后给黑白生还者加的蓝色轮廓
bool g_bBWOutline[MAXPLAYERS + 1];

// 起身期间 Spitter 酸液豁免（除颤器复活 -> 完全站立）
bool g_bSpitImmune[MAXPLAYERS + 1];			// 豁免生效中（伤害钩子只看这个）
float g_fSpitImmuneStart[MAXPLAYERS + 1];	// 豁免开始时间
bool g_bSpitGetupSeen[MAXPLAYERS + 1];		// 是否已观察到游戏的“正在被电起”起身状态
bool g_bDefibAnimActive[MAXPLAYERS + 1];	// 收到 DEFIB_START 但还没收到 DEFIB_END
int g_iSpitImmuneCount;

bool g_bLateLoad;

public Plugin myinfo =
{
	name		= "[L4D2] Tank Defib Revive",
	author		= "apples1949",
	description = "Tank death drops/gives a defibrillator and takes over defib revive with custom health & revive count handling.",
	version		= PLUGIN_VERSION,
	url			= ""
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	if (GetEngineVersion() != Engine_Left4Dead2)
	{
		strcopy(error, err_max, "This plugin only runs in \"Left 4 Dead 2\" game.");
		return APLRes_SilentFailure;
	}
	g_bLateLoad = late;
	return APLRes_Success;
}

public void OnPluginStart()
{
	g_hGameMaxIncap		= FindConVar("survivor_max_incapacitated_count");
	g_hPillsDecayRate	= FindConVar("pain_pills_decay_rate");

	int defaultReviveCount = 0;
	if (g_hGameMaxIncap != null && g_hGameMaxIncap.IntValue > 0)
	{
		defaultReviveCount = g_hGameMaxIncap.IntValue;
	}

	CreateConVar("l4d2_tank_defib_version", PLUGIN_VERSION, "Tank Defib Revive plugin version.", FCVAR_NOTIFY | FCVAR_SPONLY | FCVAR_DONTRECORD);

	g_cvEnable					= CreateConVar("l4d2_tank_defib_enable", "1", "插件总开关: 0=关闭, 1=开启.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvGiveMode				= CreateConVar("l4d2_tank_defib_give_mode", "0", "除颤器发放方式: 0=按是否有人死亡自动判定(有人死给最近存活生还者,无人死在坦克处生成), 1=始终给离坦克死亡点最近的存活生还者, 2=始终在坦克死亡处生成.", FCVAR_NOTIFY, true, 0.0, true, 2.0);
	g_cvTakeover				= CreateConVar("l4d2_tank_defib_takeover", "1", "是否接管除颤器复活效果(所有除颤器): 0=不接管, 1=接管.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvInitialHealth			= CreateConVar("l4d2_tank_defib_initial_health", "20", "复活后的初始血量.", FCVAR_NOTIFY, true, 1.0, true, 100.0);
	g_cvInitialHealthType		= CreateConVar("l4d2_tank_defib_initial_health_type", "0", "初始血量类型: 0=虚血(实血固定1,虚血=初始血量-1,总血量=初始血量), 1=实血.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvInitialReviveCount		= CreateConVar("l4d2_tank_defib_initial_revive_count", "2", "复活后的初始倒地次数: 0=未倒地状态,设置值不能超过survivor_max_incapacitated_count(运行时自动钳制),默认自动取最大倒地次数.", FCVAR_NOTIFY, true, 0.0, true, 100.0);
	g_cvHealAmount				= CreateConVar("l4d2_tank_defib_heal_amount", "5", "复活后每次回血的血量,血量类型跟随初始血量类型.", FCVAR_NOTIFY, true, 0.0, true, 100.0);
	g_cvHealInterval			= CreateConVar("l4d2_tank_defib_heal_interval", "3.0", "复活后每次回血的间隔(秒).", FCVAR_NOTIFY, true, 0.1, true, 60.0);
	g_cvContinueOnInterrupt		= CreateConVar("l4d2_tank_defib_continue_on_interrupt", "0", "中途打包/倒地后是否继续回血并继续执行后续倒地次数设置: 0=停止, 1=继续.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvTempDecay				= CreateConVar("l4d2_tank_defib_temp_decay", "0", "回血期间虚血是否自然流失: 0=不流失, 1=正常流失.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvHealCount				= CreateConVar("l4d2_tank_defib_heal_count", "8", "复活后的回血次数,回满后去掉黑白状态且不再回血.", FCVAR_NOTIFY, true, 0.0, true, 100.0);
	g_cvReviveCountTick			= CreateConVar("l4d2_tank_defib_revive_count_tick", "-1", "在多少次回血后设置倒地次数: -1=不设置, 0=复活后立即设置,目标值由l4d2_tank_defib_revive_count_set决定.", FCVAR_NOTIFY, true, -1.0, true, 100.0);
	g_cvReviveCountSet			= CreateConVar("l4d2_tank_defib_revive_count_set", "1", "回血达到l4d2_tank_defib_revive_count_tick次数后设置的倒地次数: 0=未倒地状态,设置值不能超过survivor_max_incapacitated_count(运行时自动钳制).", FCVAR_NOTIFY, true, 0.0, true, 100.0);
	g_cvSpitImmune				= CreateConVar("l4d2_tank_defib_spit_immune", "1", "除颤器复活后起身(到完全站立)期间是否豁免 Spitter 酸液伤害: 0=关闭, 1=开启(起身中被特感控住则立即取消豁免).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvSpitImmuneMax			= CreateConVar("l4d2_tank_defib_spit_immune_max", "5.0", "起身豁免的兜底上限(秒): 游戏状态异常、无法判定起身已结束时, 最多豁免这么久.", FCVAR_NOTIFY, true, 0.5, true, 30.0);

	g_cvInitialReviveCount.SetInt(defaultReviveCount, false, false);

	// 总开关/接管开关被关闭时，立即停止正在进行的回血流程
	g_cvEnable.AddChangeHook(CvarFeatureChanged);
	g_cvTakeover.AddChangeHook(CvarFeatureChanged);
	g_cvSpitImmune.AddChangeHook(CvarFeatureChanged);

	HookEvent("player_death", Event_PlayerDeath);
	HookEvent("defibrillator_used", Event_DefibrillatorUsed);
	HookEvent("heal_begin", Event_HealBegin);
	HookEvent("player_incapacitated", Event_PlayerIncapacitated);
	HookEvent("round_start", Event_RoundStart);
	HookEvent("tank_spawn", Event_TankSpawn);

	// 起身中被特感直接控住 -> 取消酸液豁免
	HookEvent("lunge_pounce", Event_SIControl);
	HookEvent("tongue_grab", Event_SIControl);
	HookEvent("jockey_ride", Event_SIControl);
	HookEvent("charger_carry_start", Event_SIControl);
	HookEvent("charger_pummel_start", Event_SIControl);

	// 黑白轮廓：外部把黑白移除时同步移除轮廓
	HookEvent("heal_success", Event_HealSuccess);
	HookEvent("pills_used", Event_PillsUsed);
	HookEvent("adrenaline_used", Event_AdrenalineUsed);
	HookEvent("revive_success", Event_ReviveSuccess);
	HookEvent("player_spawn", Event_PlayerSpawn);
	HookEvent("player_team", Event_PlayerTeam);

	//AutoExecConfig(true, "l4d2_tank_defib_revive");

	// 中途加载插件时，补挂已在线玩家的伤害钩子
	if (g_bLateLoad)
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsClientInGame(i))
			{
				OnClientPutInServer(i);
			}
		}
	}
}

public void OnClientPutInServer(int client)
{
	// 起身酸液豁免靠拦伤害实现，必须给每个玩家挂上伤害钩子
	SDKHook(client, SDKHook_OnTakeDamage, Hook_OnTakeDamage);
}

public void OnMapStart()
{
	PrecacheModel(MODEL_DEFIB, true);
}

public void OnMapEnd()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		ClearHealingState(i);
		ClearSpitImmunity(i);
		g_bHasDeathPos[i] = false;
		g_bSwappedTank[i] = false;
		ResetBWOutline(i);
	}
}

public void OnGameFrame()
{
	// 回血期间虚血不自然流失：每帧刷新 m_healthBufferTime，
	// 只阻止自然衰减计时，不恢复玩家实际受到的伤害。
	if (g_iHealingCount > 0 && !g_cvTempDecay.BoolValue)
	{
		float now = GetGameTime();
		for (int i = 1; i <= MaxClients; i++)
		{
			if (g_bHealing[i] && g_bHealTypeTemp[i] && IsValidSurvivor(i) && IsPlayerAlive(i))
			{
				SetEntPropFloat(i, Prop_Send, "m_healthBufferTime", now);
			}
		}
	}

	// 起身酸液豁免：只有存在豁免窗口时才遍历判定起身是否结束
	if (g_iSpitImmuneCount > 0)
	{
		UpdateSpitImmunity();
	}
}

public void OnClientDisconnect(int client)
{
	ClearHealingState(client);
	ClearSpitImmunity(client);
	g_bHasDeathPos[client] = false;
	g_bSwappedTank[client] = false;
	ResetBWOutline(client);
}

public void CvarFeatureChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (StringToInt(newValue) == 0)
	{
		StopAllHealing();
		StopAllSpitImmunity();
	}
}

void StopAllHealing()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!g_bHealing[i])
		{
			continue;
		}

		if (IsValidSurvivor(i))
		{
			StopHealing(i);
		}
		else
		{
			ClearHealingState(i);
		}
	}
}

// 换克（tank pass）前置：旧坦克即将被替换，标记其死亡不应发放除颤器
public void L4D_OnReplaceTank(int tank, int newTank)
{
	if (tank > 0 && tank <= MaxClients && IsClientInGame(tank))
	{
		g_bSwappedTank[tank] = true;
	}
}

public void Event_TankSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int tank = GetClientOfUserId(event.GetInt("userid"));
	if (tank > 0 && tank <= MaxClients)
	{
		// 如果旧克之后又重新成为坦克，清除残留标记，按正常坦克死亡处理
		g_bSwappedTank[tank] = false;
	}
}

// =============================
// 黑白蓝色轮廓（参考 LMC_Black_and_White_Notifier）
// =============================
void SetBlackWhiteOutline(int client, bool enable)
{
	if (!IsValidSurvivor(client))
	{
		return;
	}

	// 只在存活时开启轮廓；死亡时允许强制关闭
	if (enable && !IsPlayerAlive(client))
	{
		return;
	}

	if (enable == g_bBWOutline[client])
	{
		return;
	}

	g_bBWOutline[client] = enable;

	if (enable)
	{
		SetEntProp(client, Prop_Send, "m_iGlowType", 3);
		SetEntProp(client, Prop_Send, "m_glowColorOverride", GLOW_COLOR_BLUE);
		SetEntProp(client, Prop_Send, "m_nGlowRange", GLOW_RANGE);
	}
	else
	{
		SetEntProp(client, Prop_Send, "m_iGlowType", 0);
		SetEntProp(client, Prop_Send, "m_glowColorOverride", 0);
		SetEntProp(client, Prop_Send, "m_nGlowRange", 0);
	}
}

void ResetBWOutline(int client)
{
	g_bBWOutline[client] = false;
	// 死亡瞬间也要清轮廓，不能依赖 IsPlayerAlive
	if (client > 0 && client <= MaxClients && IsClientInGame(client))
	{
		SetEntProp(client, Prop_Send, "m_iGlowType", 0);
		SetEntProp(client, Prop_Send, "m_glowColorOverride", 0);
		SetEntProp(client, Prop_Send, "m_nGlowRange", 0);

		// 死亡后可见模型可能是 ragdoll，一并清除轮廓
		int ragdoll = GetEntPropEnt(client, Prop_Send, "m_hRagdoll");
		if (ragdoll > MaxClients && IsValidEntity(ragdoll)
			&& HasEntProp(ragdoll, Prop_Send, "m_iGlowType"))
		{
			SetEntProp(ragdoll, Prop_Send, "m_iGlowType", 0);
			SetEntProp(ragdoll, Prop_Send, "m_glowColorOverride", 0);
			SetEntProp(ragdoll, Prop_Send, "m_nGlowRange", 0);
		}
	}
}

void RemoveBWOutlineIfNeeded(int client)
{
	if (!g_bBWOutline[client])
	{
		return;
	}

	if (!IsValidSurvivor(client) || !IsPlayerAlive(client)
		|| GetEntProp(client, Prop_Send, "m_bIsOnThirdStrike") == 0)
	{
		SetBlackWhiteOutline(client, false);
	}
}

public void Event_HealSuccess(Event event, const char[] name, bool dontBroadcast)
{
	int subject = GetClientOfUserId(event.GetInt("subject"));
	RemoveBWOutlineIfNeeded(subject);
}

public void Event_PillsUsed(Event event, const char[] name, bool dontBroadcast)
{
	int userid = GetClientOfUserId(event.GetInt("userid"));
	RemoveBWOutlineIfNeeded(userid);
}

public void Event_AdrenalineUsed(Event event, const char[] name, bool dontBroadcast)
{
	int userid = GetClientOfUserId(event.GetInt("userid"));
	RemoveBWOutlineIfNeeded(userid);
}

public void Event_ReviveSuccess(Event event, const char[] name, bool dontBroadcast)
{
	int subject = GetClientOfUserId(event.GetInt("subject"));
	RemoveBWOutlineIfNeeded(subject);
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int userid = GetClientOfUserId(event.GetInt("userid"));
	// 这里不清起身豁免：复活瞬间也可能触发 player_spawn，
	// 豁免的结束由“起身状态消失/兜底上限”判定，另有死亡/换边/回合开始等清理路径。
	ResetBWOutline(userid);
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	int userid = GetClientOfUserId(event.GetInt("userid"));
	ClearSpitImmunity(userid);
	ResetBWOutline(userid);
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		ClearHealingState(i);
		ClearSpitImmunity(i);
		g_bHasDeathPos[i] = false;
		g_bSwappedTank[i] = false;
		ResetBWOutline(i);
	}
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));
	if (victim <= 0 || victim > MaxClients || !IsClientInGame(victim))
	{
		return;
	}

	if (GetClientTeam(victim) == TEAM_SURVIVOR)
	{
		// 无论插件开关状态都记录死亡位置，避免运行中开启插件后丢失已有死亡信息
		float pos[3];
		if (!GetDeathPosFromEvent(event, pos))
		{
			GetEntPropVector(victim, Prop_Send, "m_vecOrigin", pos);
		}
		g_vDeathPos[victim] = pos;
		g_bHasDeathPos[victim] = true;

		ResetBWOutline(victim);
		ClearHealingState(victim);
		ClearSpitImmunity(victim);
		return;
	}

	if (!g_cvEnable.BoolValue || GetClientTeam(victim) != TEAM_INFECTED)
	{
		return;
	}

	if (GetEntProp(victim, Prop_Send, "m_zombieClass") != ZC_TANK)
	{
		return;
	}

	// 换克产生的旧坦克死亡不是真正的坦克击杀，不发放除颤器
	if (g_bSwappedTank[victim])
	{
		g_bSwappedTank[victim] = false;
		return;
	}

	float tankPos[3];
	if (!GetDeathPosFromEvent(event, tankPos))
	{
		if (!GetEntityPosition(victim, tankPos))
		{
			return;
		}
	}

	HandleTankDeath(tankPos);
}

public void Event_DefibrillatorUsed(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnable.BoolValue || !g_cvTakeover.BoolValue)
	{
		return;
	}

	int subject = GetClientOfUserId(event.GetInt("subject"));
	if (!IsValidSurvivor(subject))
	{
		return;
	}

	// 起身(到完全站立)期间豁免 Spitter 酸液伤害
	if (g_cvSpitImmune.BoolValue)
	{
		StartSpitImmunity(subject);
	}

	// 稍微延迟，确保游戏先完成默认复活流程，再覆盖血量/倒地次数/黑白状态
	CreateTimer(0.1, Timer_ApplyDefibState, GetClientUserId(subject), TIMER_FLAG_NO_MAPCHANGE);
}

public void Event_HealBegin(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnable.BoolValue || !g_cvTakeover.BoolValue || g_cvContinueOnInterrupt.BoolValue)
	{
		return;
	}

	// 中途打包：无论回血中的玩家是被打包者还是正在给别人打包，都停止后续回血
	int subject = GetClientOfUserId(event.GetInt("subject"));
	if (IsValidSurvivor(subject) && g_bHealing[subject])
	{
		StopHealing(subject);
		return;
	}

	int userid = GetClientOfUserId(event.GetInt("userid"));
	if (IsValidSurvivor(userid) && g_bHealing[userid])
	{
		StopHealing(userid);
	}
}

public void Event_PlayerIncapacitated(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));

	// 已经倒地，起身窗口结束，取消酸液豁免
	ClearSpitImmunity(victim);

	if (!g_cvEnable.BoolValue || !g_cvTakeover.BoolValue || g_cvContinueOnInterrupt.BoolValue)
	{
		return;
	}

	if (IsValidSurvivor(victim) && g_bHealing[victim])
	{
		StopHealing(victim);
	}
}

// 起身中被特感直接控住（扑倒/骑乘/拖拽/冲撞）-> 取消豁免
public void Event_SIControl(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("victim"));
	ClearSpitImmunity(victim);
}

public Action Timer_ApplyDefibState(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (!IsValidSurvivor(client) || !IsPlayerAlive(client))
	{
		return Plugin_Stop;
	}

	// 防止“电击事件后、0.1 秒延迟内”插件开关/接管开关被关闭时仍启动回血
	if (!g_cvEnable.BoolValue || !g_cvTakeover.BoolValue)
	{
		return Plugin_Stop;
	}

	StartHealing(client);
	return Plugin_Stop;
}

public Action Timer_HealTick(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (!IsValidSurvivor(client) || !IsPlayerAlive(client) || !g_bHealing[client])
	{
		ClearHealingState(client);
		return Plugin_Stop;
	}

	g_hHealTimer[client] = null;

	// 中途倒地的兜底判断（事件正常会提前停止，这里防竞态）
	if (!g_cvContinueOnInterrupt.BoolValue && IsIncapacitated(client))
	{
		StopHealing(client);
		return Plugin_Stop;
	}

	// 给一次血
	if (g_bHealTypeTemp[client])
	{
		ApplyTempHeal(client);
	}
	else
	{
		ApplyRealHeal(client);
	}

	g_iHealTick[client]++;

	// 到达指定回血次数后，把倒地次数设为目标值
	if (!g_bReviveCountApplied[client]
		&& g_iReviveCountTick[client] >= 0
		&& g_iHealTick[client] >= g_iReviveCountTick[client])
	{
		int maxIncap = GetGameMaxIncap();
		int reviveCountSet = g_iReviveCountSet[client];
		if (reviveCountSet > maxIncap)
		{
			reviveCountSet = maxIncap;
		}
		SetEntProp(client, Prop_Send, "m_currentReviveCount", reviveCountSet);
		SetEntProp(client, Prop_Send, "m_bIsOnThirdStrike", maxIncap > 0 && reviveCountSet >= maxIncap ? 1 : 0);
		SetBlackWhiteOutline(client, maxIncap > 0 && reviveCountSet >= maxIncap);
		g_bReviveCountApplied[client] = true;
	}

	if (g_iHealTick[client] >= g_iHealTotal[client])
	{
		FinishHealing(client);
		return Plugin_Stop;
	}

	g_hHealTimer[client] = CreateTimer(g_fHealInterval[client], Timer_HealTick, userid, TIMER_FLAG_NO_MAPCHANGE);
	return Plugin_Stop;
}

// =============================
// 发放除颤器
// =============================
void HandleTankDeath(const float tankPos[3])
{
	int mode = g_cvGiveMode.IntValue;
	int target = -1;

	if (mode == 0)
	{
		// 自动：有人死亡 -> 给离死亡生还者最近的存活生还者；没人死亡 -> 坦克处生成
		target = FindNearestLivingToAnyDead();
	}
	else if (mode == 1)
	{
		// 始终给离坦克死亡点最近的存活生还者
		target = FindNearestLivingTo(tankPos);
	}

	if (target != -1 && GiveDefibToPlayer(target))
	{
		return;
	}

	// 其余情况（模式2、无存活生还者、目标已有除颤器等）都在坦克死亡处生成
	SpawnDefibAt(tankPos);
}

int FindNearestLivingToAnyDead()
{
	int best = -1;
	float bestDist = 999999.0;

	for (int dead = 1; dead <= MaxClients; dead++)
	{
		if (!IsValidSurvivor(dead) || IsPlayerAlive(dead) || !g_bHasDeathPos[dead])
		{
			continue;
		}

		for (int alive = 1; alive <= MaxClients; alive++)
		{
			if (!IsValidLivingSurvivor(alive))
			{
				continue;
			}

			float alivePos[3];
			GetEntPropVector(alive, Prop_Send, "m_vecOrigin", alivePos);
			float dist = GetVectorDistance(g_vDeathPos[dead], alivePos);
			if (best == -1 || dist < bestDist)
			{
				best = alive;
				bestDist = dist;
			}
		}
	}

	return best;
}

int FindNearestLivingTo(const float refPos[3])
{
	int best = -1;
	float bestDist = 999999.0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsValidLivingSurvivor(i))
		{
			continue;
		}

		float pos[3];
		GetEntPropVector(i, Prop_Send, "m_vecOrigin", pos);
		float dist = GetVectorDistance(refPos, pos);
		if (best == -1 || dist < bestDist)
		{
			best = i;
			bestDist = dist;
		}
	}

	return best;
}

bool GiveDefibToPlayer(int client)
{
	if (!IsValidLivingSurvivor(client) || HasDefibrillator(client))
	{
		return false;
	}

	int flags = GetCommandFlags("give");
	SetCommandFlags("give", flags & ~FCVAR_CHEAT);
	FakeClientCommand(client, "give defibrillator");
	SetCommandFlags("give", flags);

	char name[64];
	GetClientName(client, name, sizeof(name));
	PrintToChatAll("\x03[除颤器] %s 获得了除颤器", name);
	return true;
}

bool HasDefibrillator(int client)
{
	int weapon = GetPlayerWeaponSlot(client, 3);
	if (weapon <= MaxClients || !IsValidEntity(weapon))
	{
		return false;
	}

	char classname[32];
	GetEntityClassname(weapon, classname, sizeof(classname));
	return StrEqual(classname, "weapon_defibrillator", false);
}

void SpawnDefibAt(const float tankPos[3])
{
	float pos[3];
	pos = tankPos;
	pos[2] += 10.0;

	int entity = CreateEntityByName(CLASS_DEFIB_SPAWN);
	if (entity == -1)
	{
		LogError("Failed to create %s at %.2f %.2f %.2f", CLASS_DEFIB_SPAWN, pos[0], pos[1], pos[2]);
		return;
	}

	DispatchKeyValue(entity, "solid", "6");
	DispatchKeyValue(entity, "spawnflags", "1");
	DispatchKeyValue(entity, "count", "1");
	DispatchKeyValue(entity, "spawn_without_director", "1");
	DispatchKeyValue(entity, "body", "0");
	DispatchKeyValueVector(entity, "origin", pos);
	DispatchSpawn(entity);
	ActivateEntity(entity);
	TeleportEntity(entity, pos, NULL_VECTOR, NULL_VECTOR);

	PrintToChatAll("\x03[除颤器] 坦克死亡处已掉落一个除颤器");
}

// =============================
// 回血流程
// =============================
void StartHealing(int client)
{
	// 重复电击（同一客户端再次复活）时，先清掉上一轮
	ClearHealingState(client);

	int maxIncap = GetGameMaxIncap();

	int initialReviveCount = g_cvInitialReviveCount.IntValue;
	if (initialReviveCount < 0)
	{
		initialReviveCount = 0;
	}
	if (initialReviveCount > maxIncap)
	{
		initialReviveCount = maxIncap;
	}

	int reviveCountTick = g_cvReviveCountTick.IntValue;

	int reviveCountSet = g_cvReviveCountSet.IntValue;
	if (reviveCountSet < 0)
	{
		reviveCountSet = 0;
	}
	if (reviveCountSet > maxIncap)
	{
		// cvar 要求不能超过最大倒地次数
		reviveCountSet = maxIncap;
	}

	int initialHealth = g_cvInitialHealth.IntValue;
	bool tempType = g_cvInitialHealthType.BoolValue == false;

	if (tempType)
	{
		// 虚血模式：实血固定 1，虚血 = 初始血量 - 1，总血量 = 初始血量
		SetEntityHealth(client, 1);
		float buffer = initialHealth > 1 ? float(initialHealth - 1) : 0.0;
		SetEntPropFloat(client, Prop_Send, "m_healthBuffer", buffer);
		SetEntPropFloat(client, Prop_Send, "m_healthBufferTime", GetGameTime());
	}
	else
	{
		int maxHealth = GetEntProp(client, Prop_Data, "m_iMaxHealth");
		int health = initialHealth;
		if (health > maxHealth)
		{
			health = maxHealth;
		}
		SetEntityHealth(client, health);
		SetEntPropFloat(client, Prop_Send, "m_healthBuffer", 0.0);
		SetEntPropFloat(client, Prop_Send, "m_healthBufferTime", GetGameTime());
	}

	// 倒地次数 + 黑白状态（倒地次数达到最大倒地次数时为黑白）
	SetEntProp(client, Prop_Send, "m_currentReviveCount", initialReviveCount);
	SetEntProp(client, Prop_Send, "m_bIsOnThirdStrike", maxIncap > 0 && initialReviveCount >= maxIncap ? 1 : 0);
	SetBlackWhiteOutline(client, maxIncap > 0 && initialReviveCount >= maxIncap);

	if (!g_bHealing[client])
	{
		g_iHealingCount++;
	}
	g_bHealing[client]				= true;
	g_iHealTick[client]				= 0;
	g_iHealTotal[client]			= g_cvHealCount.IntValue;
	g_fHealInterval[client]			= g_cvHealInterval.FloatValue;
	g_iHealAmount[client]			= g_cvHealAmount.IntValue;
	g_bHealTypeTemp[client]			= tempType;
	g_iReviveCountTick[client]		= reviveCountTick;
	g_iReviveCountSet[client]		= reviveCountSet;
	g_bReviveCountApplied[client]	= (reviveCountTick == 0);

	if (g_bReviveCountApplied[client])
	{
		// 0 次回血后立即设置
		SetEntProp(client, Prop_Send, "m_currentReviveCount", reviveCountSet);
		SetEntProp(client, Prop_Send, "m_bIsOnThirdStrike", maxIncap > 0 && reviveCountSet >= maxIncap ? 1 : 0);
		SetBlackWhiteOutline(client, maxIncap > 0 && reviveCountSet >= maxIncap);
	}

	if (g_iHealTotal[client] <= 0)
	{
		FinishHealing(client);
		return;
	}

	g_hHealTimer[client] = CreateTimer(g_fHealInterval[client], Timer_HealTick, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

void ApplyRealHeal(int client)
{
	int maxHealth = GetEntProp(client, Prop_Data, "m_iMaxHealth");
	int health = GetClientHealth(client) + g_iHealAmount[client];
	if (health > maxHealth)
	{
		health = maxHealth;
	}
	SetEntityHealth(client, health);
}

void ApplyTempHeal(int client)
{
	float now = GetGameTime();
	float buffer = GetEntPropFloat(client, Prop_Send, "m_healthBuffer");

	if (g_cvTempDecay.BoolValue && g_hPillsDecayRate != null)
	{
		float time = GetEntPropFloat(client, Prop_Send, "m_healthBufferTime");
		buffer -= (now - time) * g_hPillsDecayRate.FloatValue;
	}
	if (buffer < 0.0)
	{
		buffer = 0.0;
	}
	// 不流失模式（cvar10=0）：OnGameFrame 已持续冻结衰减计时，
	// 这里直接读取当前实际虚血，只加上本次回血量，不恢复玩家受到的伤害。

	buffer += g_iHealAmount[client];

	SetEntPropFloat(client, Prop_Send, "m_healthBuffer", buffer);
	SetEntPropFloat(client, Prop_Send, "m_healthBufferTime", now);
}

void FinishHealing(int client)
{
	// 回满：去掉黑白，不再回血，虚血恢复自然流失
	SetEntProp(client, Prop_Send, "m_bIsOnThirdStrike", 0);
	SetBlackWhiteOutline(client, false);
	SetEntPropFloat(client, Prop_Send, "m_healthBufferTime", GetGameTime());
	ClearHealingState(client);
}

void StopHealing(int client)
{
	// 中途打包/倒地：不再给血，虚血恢复自然流失
	SetEntPropFloat(client, Prop_Send, "m_healthBufferTime", GetGameTime());
	ClearHealingState(client);
}

void ClearHealingState(int client)
{
	if (g_bHealing[client] && g_iHealingCount > 0)
	{
		g_iHealingCount--;
	}
	g_bHealing[client]				= false;
	g_iHealTick[client]				= 0;
	g_iHealTotal[client]			= 0;
	g_fHealInterval[client]			= 0.0;
	g_iHealAmount[client]			= 0;
	g_bHealTypeTemp[client]			= false;
	g_iReviveCountTick[client]		= -1;
	g_iReviveCountSet[client]		= 0;
	g_bReviveCountApplied[client]	= false;

	if (g_hHealTimer[client] != null)
	{
		KillTimer(g_hHealTimer[client]);
		g_hHealTimer[client] = null;
	}
}

// =============================
// 起身期间 Spitter 酸液豁免
//
// 窗口 = 除颤器复活瞬间 -> 完全站立：
//   证据1(状态)：起身期间游戏给生还者记 m_iCurrentUseAction = L4D2UseAction_GettingDefibed，
//                起身结束（能重新行动）时清除。
//   证据2(动画)：游戏播放起身动画时发 PLAYERANIMEVENT_DEFIB_START，播放完发 ..._DEFIB_END。
//   两个信号任一仍在，就认为还在起身；两个都结束才取消豁免（避免单一信号异常导致提前漏挡）。
//   兜底：SPIT_IMMUNE_WAIT_MAX 内没等到起身状态、以及 l4d2_tank_defib_spit_immune_max 上限。
// 取消：起身中被特感直接控住 / 倒地 / 死亡 / 换边 / 掉线 / 回合开始。
// =============================
public Action Hook_OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
	// 只有处于起身豁免窗口的玩家才需要进一步判断
	if (victim < 1 || victim > MaxClients || !g_bSpitImmune[victim])
	{
		return Plugin_Continue;
	}

	if (!IsSpitterDamage(inflictor, attacker, damagetype))
	{
		return Plugin_Continue;
	}

	return Plugin_Handled;
}

bool IsSpitterDamage(int inflictor, int attacker, int damagetype)
{
	// 酸液本体(insect_swarm) 与 吐酸投射物(spitter_projectile)
	if (inflictor > MaxClients && IsValidEdict(inflictor))
	{
		char classname[64];
		GetEdictClassname(inflictor, classname, sizeof(classname));

		if (StrEqual(classname, CLASS_SPIT_GOO, false) || StrEqual(classname, CLASS_SPIT_PROJ, false))
		{
			return true;
		}
	}

	// 兜底：酸液伤害类型 + 攻击者是 Spitter
	if ((damagetype & DMG_TYPE_SPIT) == DMG_TYPE_SPIT
		&& attacker > 0 && attacker <= MaxClients && IsClientInGame(attacker)
		&& GetClientTeam(attacker) == TEAM_INFECTED
		&& GetEntProp(attacker, Prop_Send, "m_zombieClass") == ZC_SPITTER)
	{
		return true;
	}

	return false;
}

public Action L4D_OnDoAnimationEvent(int client, int &event, int &variant_param)
{
	// 本回调每个动画事件都会触发，先做最轻的短路
	if (g_iSpitImmuneCount == 0)
	{
		return Plugin_Continue;
	}

	PlayerAnimEvent_t anim = view_as<PlayerAnimEvent_t>(event);
	if (anim != PLAYERANIMEVENT_DEFIB_START && anim != PLAYERANIMEVENT_DEFIB_END)
	{
		return Plugin_Continue;
	}

	if (client < 1 || client > MaxClients || !g_bSpitImmune[client])
	{
		return Plugin_Continue;
	}

	g_bDefibAnimActive[client] = (anim == PLAYERANIMEVENT_DEFIB_START);
	return Plugin_Continue;
}

void StartSpitImmunity(int client)
{
	if (!g_bSpitImmune[client])
	{
		g_iSpitImmuneCount++;
	}

	g_bSpitImmune[client]		= true;
	g_fSpitImmuneStart[client]	= GetGameTime();
	g_bSpitGetupSeen[client]	= false;
	g_bDefibAnimActive[client]	= false;
}

// 幂等：非豁免状态、非法 client 都直接返回
void ClearSpitImmunity(int client)
{
	if (client < 1 || client > MaxClients || !g_bSpitImmune[client])
	{
		return;
	}

	g_iSpitImmuneCount--;
	g_bSpitImmune[client]		= false;
	g_fSpitImmuneStart[client]	= 0.0;
	g_bSpitGetupSeen[client]	= false;
	g_bDefibAnimActive[client]	= false;
}

void StopAllSpitImmunity()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		ClearSpitImmunity(i);
	}
}

void UpdateSpitImmunity()
{
	float now = GetGameTime();
	float maxDuration = g_cvSpitImmuneMax.FloatValue;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!g_bSpitImmune[i])
		{
			continue;
		}

		// 掉线/换边（死亡由 player_death 清理，复活瞬间可能还判定为死亡，这里不判 IsPlayerAlive）
		if (!IsValidSurvivor(i))
		{
			ClearSpitImmunity(i);
			continue;
		}

		float elapsed = now - g_fSpitImmuneStart[i];

		// 兜底上限：状态异常时不会变成永久豁免
		if (elapsed >= maxDuration)
		{
			ClearSpitImmunity(i);
			continue;
		}

		// 电击到游戏写入起身状态之间的宽限期，不做结束判定
		if (elapsed < SPIT_IMMUNE_GRACE)
		{
			continue;
		}

		bool bGettingUp = (L4D2_GetPlayerUseAction(i) == L4D2UseAction_GettingDefibed)
			|| g_bDefibAnimActive[i];

		if (!g_bSpitGetupSeen[i])
		{
			if (bGettingUp)
			{
				g_bSpitGetupSeen[i] = true;
			}
			else if (elapsed >= SPIT_IMMUNE_WAIT_MAX)
			{
				// 一直没观察到起身状态：按兜底收手
				ClearSpitImmunity(i);
			}
			continue;
		}

		// 起身结束（已经完全站立）
		if (!bGettingUp)
		{
			ClearSpitImmunity(i);
		}
	}
}

// =============================
// 辅助函数
// =============================
int GetGameMaxIncap()
{
	if (g_hGameMaxIncap == null)
	{
		return 0;
	}

	int max = g_hGameMaxIncap.IntValue;
	return max > 0 ? max : 0;
}

bool IsValidSurvivor(int client)
{
	return client > 0
		&& client <= MaxClients
		&& IsClientInGame(client)
		&& GetClientTeam(client) == TEAM_SURVIVOR;
}

bool IsValidLivingSurvivor(int client)
{
	return IsValidSurvivor(client)
		&& IsPlayerAlive(client)
		&& !IsIncapacitated(client);
}

bool IsIncapacitated(int client)
{
	return view_as<bool>(GetEntProp(client, Prop_Send, "m_isIncapacitated", 1))
		|| view_as<bool>(GetEntProp(client, Prop_Send, "m_isHangingFromLedge", 1));
}

bool GetDeathPosFromEvent(Event event, float pos[3])
{
	pos[0] = event.GetFloat("victim_x");
	pos[1] = event.GetFloat("victim_y");
	pos[2] = event.GetFloat("victim_z");

	if (pos[0] == 0.0 && pos[1] == 0.0 && pos[2] == 0.0)
	{
		return false;
	}

	return true;
}

bool GetEntityPosition(int entity, float pos[3])
{
	if (!IsValidEntity(entity))
	{
		return false;
	}

	GetEntPropVector(entity, Prop_Send, "m_vecOrigin", pos);
	return true;
}
