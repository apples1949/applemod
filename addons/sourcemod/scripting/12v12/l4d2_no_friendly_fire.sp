/*
 *	l4d2_no_friendly_fire - 关闭生还者友伤（零提示 / 零输出）
 *
 *	两层都静默，插件不注册任何 cvar、不建 cfg、不打印任何文字：
 *	  1) 引擎层：把 survivor_friendly_fire_factor_(easy|normal|hard|expert) 归零并锁住。
 *	     引擎 CTerrorPlayer::GetFriendlyFireScale 按 z_difficulty 取这四个系数，
 *	     对抗固定为 Normal 难度 ⇒ _normal 是实际生效的那个，四个都归零覆盖全部难度。
 *	     这一步同时覆盖"攻击者不是玩家"的间接友伤（队友点燃的火焰、队友扔的土制炸弹等）。
 *	  2) 伤害层：SDKHook_OnTakeDamage；受害者为生还者、攻击者是同队生还者
 *	     （含闲置玩家对应的 AI 身体）时直接 Plugin_Handled，兜住绕过系数的直接友伤。
 *
 *	每次 OnConfigsExecuted 会再压一次系数（框架换图/加载模式会重设参数）。
 *	插件卸载时把四个系数恢复为进入前的原值，不影响其它模式。
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>

#define PLUGIN_VERSION "1.0.0"

#define TEAM_SURVIVOR 2

ConVar g_hFactor[4];
float  g_fOriginal[4];
bool   g_bHooked;

char g_sFactorName[][] =
{
	"survivor_friendly_fire_factor_easy",
	"survivor_friendly_fire_factor_normal",
	"survivor_friendly_fire_factor_hard",
	"survivor_friendly_fire_factor_expert"
};

public Plugin myinfo =
{
	name = "l4d2_no_friendly_fire",
	author = "apples1949",
	description = "关闭生还者友伤（无提示无输出）",
	version = PLUGIN_VERSION,
	url = "https://github.com/apples1949"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	if (GetEngineVersion() != Engine_Left4Dead2)
		return APLRes_SilentFailure;

	return APLRes_Success;
}

public void OnPluginStart()
{
	// 晚加载：给已在服的玩家补钩子
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client))
			SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
	}

	ApplyNoFriendlyFire();
}

public void OnConfigsExecuted()
{
	// 框架每次加载模式/换图都会重设参数，这里再压一次，保证友伤始终为 0
	ApplyNoFriendlyFire();
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
}

public void OnPluginEnd()
{
	// 静默恢复原值，避免影响其它模式
	for (int i = 0; i < 4; i++)
	{
		if (g_hFactor[i] != null)
			g_hFactor[i].SetFloat(g_fOriginal[i], false, false);
	}
	g_bHooked = false;
}

void ApplyNoFriendlyFire()
{
	for (int i = 0; i < 4; i++)
	{
		if (g_hFactor[i] == null)
		{
			g_hFactor[i] = FindConVar(g_sFactorName[i]);
			if (g_hFactor[i] == null)
				continue;

			g_fOriginal[i] = g_hFactor[i].FloatValue;
		}

		if (g_hFactor[i].FloatValue != 0.0)
			g_hFactor[i].SetFloat(0.0, false, false);
	}

	g_bHooked = true;
}

public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
	if (!g_bHooked)
		return Plugin_Continue;

	if (victim < 1 || victim > MaxClients)
		return Plugin_Continue;

	if (GetClientTeam(victim) != TEAM_SURVIVOR)
		return Plugin_Continue;

	if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker))
		return Plugin_Continue;

	// 同队生还者造成的伤害 = 友伤
	if (GetClientTeam(attacker) == TEAM_SURVIVOR)
		return Plugin_Handled;

	// 闲置玩家的伤害可能记在观察者队的本人头上：看他是否有 AI 身体在生还者队
	if (OwnsSurvivorBot(attacker))
		return Plugin_Handled;

	return Plugin_Continue;
}

// 该玩家（闲置中，位于观察者队）当前是否拥有一个 AI 生还者身体
bool OwnsSurvivorBot(int client)
{
	int userid = GetClientUserId(client);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (i == client || !IsClientInGame(i) || !IsFakeClient(i))
			continue;

		if (GetClientTeam(i) != TEAM_SURVIVOR)
			continue;

		if (!HasEntProp(i, Prop_Send, "m_humanSpectatorUserID"))
			continue;

		if (GetEntProp(i, Prop_Send, "m_humanSpectatorUserID") == userid)
			return true;
	}

	return false;
}
