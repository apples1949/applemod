#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <l4d2util_infected>

#define PLUGIN_VERSION "1.4.0"

#define ZC_SMOKER   1
#define ZC_BOOMER   2
#define ZC_SPITTER  4
#define ZC_JOCKEY   5
#define ZC_CHARGER  6

ConVar g_cvEnable;
ConVar g_cvAttackReduce;

public Plugin myinfo =
{
	name = "AppleMod SI Attack CD Boost",
	author = "apples1949",
	description = "Charger/Jockey/Smoker/Spitter/Boomer 爪击命中生还者时, 特感技能CD加快恢复一秒",
	version = PLUGIN_VERSION,
	url = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	char sGame[12];
	GetGameFolderName(sGame, sizeof(sGame));
	if (!StrEqual(sGame, "left4dead2"))
	{
		strcopy(error, err_max, "Plugin only supports L4D2");
		return APLRes_Failure;
	}
	return APLRes_Success;
}

public void OnPluginStart()
{
	g_cvEnable       = CreateConVar("sm_sicd_enable", "1", "总开关: 1=启用 0=禁用");
	g_cvAttackReduce = CreateConVar("sm_sicd_attack_reduce", "1.0", "爪击命中生还者一次, 特感技能CD加快恢复的秒数 (0=不加快)", _, true, 0.0);

	// 热装载: 补挂已在线玩家
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i))
			OnClientPutInServer(i);
}

public void OnPluginEnd()
{
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i))
			SDKUnhook(i, SDKHook_OnTakeDamage, Hook_OnTakeDamage);
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_OnTakeDamage, Hook_OnTakeDamage);
}

public void OnClientDisconnect(int client)
{
	SDKUnhook(client, SDKHook_OnTakeDamage, Hook_OnTakeDamage);
}

// ============================================================================
// 爪击命中生还者 → 特感技能CD加快恢复 (一次爪击只加快一次)
// ============================================================================

Action Hook_OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype,
		int &weapon, float damageForce[3], float damagePosition[3])
{
	if (!g_cvEnable.BoolValue)
		return Plugin_Continue;
	if (damage <= 0.0)
		return Plugin_Continue;

	if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker))
		return Plugin_Continue;
	if (victim < 1 || victim > MaxClients || !IsClientInGame(victim))
		return Plugin_Continue;
	if (GetClientTeam(victim) != 2) // 只算命中生还者
		return Plugin_Continue;
	if (GetClientTeam(attacker) != 3)
		return Plugin_Continue;

	int zclass = GetEntProp(attacker, Prop_Send, "m_zombieClass");
	switch (zclass)
	{
		case ZC_SMOKER, ZC_BOOMER, ZC_SPITTER, ZC_JOCKEY, ZC_CHARGER:
		{
			// 只算爪击(近战 DMG_CLUB): 舌头/口水/呕吐等技能伤害不算
			if (!(damagetype & DMG_CLUB))
				return Plugin_Continue;

			// charger 例外: 冲锋撞击和压制拍打不算爪击
			if (zclass == ZC_CHARGER)
			{
				if (GetEntProp(attacker, Prop_Send, "m_isCharging"))
					return Plugin_Continue;
				if (GetEntPropEnt(attacker, Prop_Send, "m_pummelVictim") > 0)
					return Plugin_Continue;
			}
		}
		default:
			return Plugin_Continue;
	}

	ApplyHitReduction(attacker);
	return Plugin_Continue;
}

// 把当前特感技能CD(引擎 ability timer)加快恢复 reduce 秒, 最快恢复到就绪
void ApplyHitReduction(int client)
{
	float reduce = g_cvAttackReduce.FloatValue;
	if (reduce <= 0.0)
		return;

	float now = GetGameTime();
	float timestamp, duration;
	if (!GetInfectedAbilityTimer(client, timestamp, duration))
		return;
	if (timestamp <= now)
		return; // 当前没有CD, 无需加快

	timestamp -= reduce;
	if (timestamp < now)
		timestamp = now;
	SetInfectedAbilityTimer(client, timestamp, duration);
}