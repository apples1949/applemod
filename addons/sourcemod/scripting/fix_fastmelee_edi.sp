/**
 * fix_fastmelee_edi —— 复刻 sheo 的 "Fast melee fix"(v2.3)，改动只有两点：
 *   1) 只在**场上有存活坦克**时才修复"切副武器近战速砍"，没有坦克存活时完全不干预；
 *   2) 两个 cvar 控制：fix_fastmelee_enable（总开关）、fix_fastmelee_tank_only（是否只在坦克存活时修）。
 *
 * 原插件: https://github.com/SirPlease/L4D2-Competitive-Rework
 * 原作者: sheo
 *
 * 原理（与原版一致，只是加了坦克门控）：
 *   引擎在"切到近战武器"时只按武器脚本给一个很短的 deploy 前摇，玩家靠
 *   切副武器(近战)→立刻攻击 就能连续挥砍（速砍）。这里在每次切换到 weapon_melee
 *   之后，把该武器的 m_flNextPrimaryAttack 压到
 *       max(上一次挥砍时间 + 0.92 秒, 现在 + 0.5 秒)
 *   于是"刚砍完就切回来再砍"会被推迟到正常挥砍节奏，速砍失效。
 *
 * 为什么只在坦克存活时修：
 *   速砍对坦克威胁最大（近战打坦克是坦克最大血量的 5%/刀），而平时打小僵尸/特感
 *   的手感不需要限制；没有坦克时保持原版手感，避免"平时挥砍被拖慢"的体感问题。
 *
 * 注意：本插件不生成 cfg（按 applemod 约定，参数在 confogl 的 cfg 里 confogl_addcvar 设置）。
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <l4d2util_constants>

#define PLUGIN_VERSION        "1.0.0"

#define MELEE_SWING_INTERVAL   0.92   /* 原版挥砍间隔(秒)：两次近战之间至少这么久 */
#define SWITCH_MIN_DELAY       0.5    /* 切枪本身至少给 0.5 秒，避免和引擎 deploy 打架 */

#define TEAM_INFECTED          3

ConVar g_cvEnable;
ConVar g_cvTankOnly;

float g_fLastMeleeSwing[MAXPLAYERS + 1];

/* 坦克死亡动画期间 IsPlayerAlive 仍为 true，用 m_isIncapacitated 判"已经在死" */
int g_iOffsetTankIncap = -1;

public Plugin myinfo =
{
	name        = "Fast melee fix (tank only) - edi",
	author      = "sheo, apples1949 (edi)",
	description = "修复切副武器近战速砍：只在有存活坦克时生效",
	version     = PLUGIN_VERSION,
	url         = "https://github.com/SirPlease/L4D2-Competitive-Rework"
};

public void OnPluginStart()
{
	g_cvEnable = CreateConVar("fix_fastmelee_enable", "1",
		"0=关闭(不修复速砍) 1=启用修复", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvTankOnly = CreateConVar("fix_fastmelee_tank_only", "1",
		"1=只有场上有存活坦克时才修复(默认) 0=任何时候都修复(原版行为)", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("weapon_fire", Event_WeaponFire, EventHookMode_Post);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
			OnClientPutInServer(i);
	}
}

public void OnClientPutInServer(int client)
{
	if (!IsFakeClient(client))
		SDKHook(client, SDKHook_WeaponSwitchPost, OnWeaponSwitched);

	g_fLastMeleeSwing[client] = 0.0;
}

public void OnClientDisconnect(int client)
{
	if (client <= 0 || client > MaxClients)
		return;

	if (!IsFakeClient(client))
		SDKUnhook(client, SDKHook_WeaponSwitchPost, OnWeaponSwitched);

	g_fLastMeleeSwing[client] = 0.0;
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	for (int i = 1; i <= MaxClients; i++)
		g_fLastMeleeSwing[i] = 0.0;
}

void Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
	if (event.GetInt("weaponid") != WEPID_MELEE)
		return;

	int client = GetClientOfUserId(event.GetInt("userid"));

	if (client < 1 || IsFakeClient(client))
		return;

	g_fLastMeleeSwing[client] = GetGameTime();
}

/**
 * 切换到近战武器时把下一刀的允许时间往后压。
 * 只有"该修复"的时候才动手：总开关打开，且（tank_only 关闭 或 场上有存活坦克）。
 */
void OnWeaponSwitched(int client, int weapon)
{
	if (!g_cvEnable.BoolValue || IsFakeClient(client) || !IsValidEdict(weapon))
		return;

	if (g_cvTankOnly.BoolValue && !IsTankAlive())
		return;

	char sClass[64];
	GetEdictClassname(weapon, sClass, sizeof(sClass));

	if (strcmp(sClass, "weapon_melee") != 0)
		return;

	float fShouldbeNextAttack = g_fLastMeleeSwing[client] + MELEE_SWING_INTERVAL;
	float fByServerNextAttack  = GetGameTime() + SWITCH_MIN_DELAY;
	float fNextAttack = (fShouldbeNextAttack > fByServerNextAttack) ? fShouldbeNextAttack : fByServerNextAttack;

	SetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack", fNextAttack);
}

/** 场上是否有"活着的"玩家坦克（死亡动画期间的坦克不算） */
bool IsTankAlive()
{
	if (g_iOffsetTankIncap == -1)
		g_iOffsetTankIncap = FindSendPropInfo("Tank", "m_isIncapacitated");

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_INFECTED || !IsPlayerAlive(i))
			continue;

		if (GetEntProp(i, Prop_Send, "m_zombieClass", 4) != L4D2Infected_Tank)
			continue;

		/* 坦克正在播死亡动画：已经算"没有坦克"了，不再修复 */
		if (g_iOffsetTankIncap > 0 && view_as<bool>(GetEntData(i, g_iOffsetTankIncap)))
			continue;

		return true;
	}

	return false;
}
