#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#define PLUGIN_VERSION "1.2.0"

#define TEAM_SURVIVOR 2
#define TEAM_INFECTED 3
#define ZOMBIECLASS_BOOMER 2
#define ZOMBIECLASS_TANK   8

#define MAX_ZONES           16
#define ZONE_TICK_INTERVAL  0.25
#define HEAL_TICK_INTERVAL  1.0
#define SPIT_SCAN_INTERVAL  0.1

#define BILE_POS_HEIGHT_FIX 70.0

#define BOOMER_EXPLOSION_RADIUS 200.0

ConVar g_cvEnable;
ConVar g_cvJarZoneRadius;
ConVar g_cvHealPerSecond;
ConVar g_cvBlockHorde;

ConVar g_hVomitBlindTime;
float  g_fBileDuration;

ConVar g_hVomitRange;
float  g_fVomitRange;

ConVar g_hVomitDuration;
float  g_fVomitDuration;

ConVar g_hVomitTargetDot;
float  g_fVomitTargetDot;

Handle g_hHealTimer;
Handle g_hZoneTimer;

bool  g_bSIBiled[MAXPLAYERS + 1];
float g_fSIBileEnd[MAXPLAYERS + 1];
int   g_iSIBileCount[MAXPLAYERS + 1];
float g_fSIBileHeal[MAXPLAYERS + 1];

bool  g_bSurvivorBiled[MAXPLAYERS + 1];

float g_fSIBileMobBlockUntil;

float g_fBoomerDeathPos[3];
bool  g_bBoomerDeathValid;

float g_fZonePos[MAX_ZONES][3];
float g_fZoneEnd[MAX_ZONES];
int   g_iZoneAttacker[MAX_ZONES];

public Plugin myinfo =
{
	name = "L4D2 Special Infected Bile",
	author = "apples1949",
	description = "Boomer 喷吐/爆炸给特感附胆汁；特感胆汁回血；投掷物胆汁区域持续生效",
	version = PLUGIN_VERSION,
	url = ""
};

public void OnPluginStart()
{
	g_cvEnable = CreateConVar("l4d2_si_bile_enable", "1", "总开关", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvJarZoneRadius = CreateConVar("l4d2_si_bile_jar_zone_radius", "150.0", "投掷物胆汁罐爆炸后区域半径", FCVAR_NOTIFY, true, 0.0);
	g_cvHealPerSecond = CreateConVar("l4d2_si_bile_heal_per_second", "60.0", "特感胆汁基础每秒回复量：坦克满额，非坦克减半，第 2 次胆汁再减半 (0=关)", FCVAR_NOTIFY, true, 0.0);
	g_cvBlockHorde = CreateConVar("l4d2_si_bile_block_horde", "1", "特感被附着胆汁时是否阻止游戏刷新尸潮 (0=允许刷新, 1=阻止刷新)", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_hVomitBlindTime = FindConVar("sb_vomit_blind_time");
	if (g_hVomitBlindTime == null)
	{
		g_fBileDuration = 5.0;
	}
	else
	{
		g_fBileDuration = g_hVomitBlindTime.FloatValue;
		g_hVomitBlindTime.AddChangeHook(OnVomitBlindTimeChanged);
	}

	g_hVomitRange = FindConVar("z_vomit_range");
	g_fVomitRange = (g_hVomitRange != null) ? g_hVomitRange.FloatValue : 300.0;
	if (g_hVomitRange != null)
		g_hVomitRange.AddChangeHook(OnVomitCvarChanged);

	g_hVomitDuration = FindConVar("z_vomit_duration");
	g_fVomitDuration = (g_hVomitDuration != null) ? g_hVomitDuration.FloatValue : 1.5;
	if (g_hVomitDuration != null)
		g_hVomitDuration.AddChangeHook(OnVomitCvarChanged);

	g_hVomitTargetDot = FindConVar("z_vomit_target_dot");
	g_fVomitTargetDot = (g_hVomitTargetDot != null) ? g_hVomitTargetDot.FloatValue : 0.6;
	if (g_hVomitTargetDot != null)
		g_hVomitTargetDot.AddChangeHook(OnVomitCvarChanged);

	//AutoExecConfig(true, "l4d2_si_bile");

	HookEvent("player_death", Event_PlayerDeath);
	HookEvent("boomer_exploded", Event_BoomerExploded);
	HookEvent("ability_use", Event_AbilityUse);
	HookEvent("player_now_it", Event_PlayerNowIt, EventHookMode_Pre);
	HookEvent("player_no_longer_it", Event_PlayerNoLongerIt);
	HookEvent("player_team", Event_PlayerTeam);

	g_hHealTimer = CreateTimer(HEAL_TICK_INTERVAL, Timer_HealBiled, INVALID_HANDLE, TIMER_REPEAT);
	g_hZoneTimer = CreateTimer(ZONE_TICK_INTERVAL, Timer_ZoneTick, INVALID_HANDLE, TIMER_REPEAT);
}

public void OnPluginEnd()
{
	KillTimer(g_hHealTimer);
	KillTimer(g_hZoneTimer);
}

public void OnMapEnd()
{
	g_fSIBileMobBlockUntil = 0.0;
}

public void OnVomitBlindTimeChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_fBileDuration = convar.FloatValue;
}

public void OnVomitCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (convar == g_hVomitRange)
		g_fVomitRange = convar.FloatValue;
	else if (convar == g_hVomitDuration)
		g_fVomitDuration = convar.FloatValue;
	else if (convar == g_hVomitTargetDot)
		g_fVomitTargetDot = convar.FloatValue;
}

bool IsSIGhost(int client)
{
	return GetEntProp(client, Prop_Send, "m_isGhost") != 0;
}

void ClearSIBileState(int client)
{
	g_bSIBiled[client] = false;
	g_fSIBileEnd[client] = 0.0;
	g_fSIBileHeal[client] = 0.0;
}

void ClearSIBileLife(int client)
{
	ClearSIBileState(client);
	g_iSIBileCount[client] = 0;
}

void BileSpecialInfected(int victim, int attacker)
{
	if (victim <= 0 || victim > MaxClients || !IsClientInGame(victim))
		return;
	if (GetClientTeam(victim) != TEAM_INFECTED || !IsPlayerAlive(victim))
		return;
	if (IsSIGhost(victim))
		return;
	if (g_iSIBileCount[victim] >= 2)
		return;

	int zombieClass = GetEntProp(victim, Prop_Send, "m_zombieClass");
	bool alreadyBiled = g_bSIBiled[victim];

	if (!alreadyBiled)
	{
		g_iSIBileCount[victim]++;

		float base = (zombieClass == ZOMBIECLASS_TANK)
			? g_cvHealPerSecond.FloatValue
			: g_cvHealPerSecond.FloatValue * 0.5;

		g_fSIBileHeal[victim] = (g_iSIBileCount[victim] == 1) ? base : base * 0.5;
	}
	else if (g_iSIBileCount[victim] == 1)
	{
		g_iSIBileCount[victim] = 2;
	}
	else
	{
		return;
	}

	// 阻止本次胆汁紧随而来的 IT 尸潮（须在施加胆汁前设窗，覆盖同步触发的 SpawnITMob）
	if (g_cvBlockHorde.BoolValue)
		g_fSIBileMobBlockUntil = GetGameTime() + 0.2;

	L4D2_CTerrorPlayer_OnHitByVomitJar(victim, attacker);

	// 特感不保留胆汁负面效果：立即移除屏幕模糊并结束 IT 状态（小僵尸不再被吸引围攻）
	ClearSIBileEffect(victim);

	g_bSIBiled[victim] = true;
	g_fSIBileEnd[victim] = GetGameTime() + g_fBileDuration;
}

void ClearSIBileEffect(int victim)
{
	// L4D_OnITExpired 会同时清掉屏幕胆汁效果与 IT 状态（小僵尸不再被吸引围攻），
	// 再显式清零 m_vomitStart/m_vomitFadeStart，确保模糊效果立即消失
	L4D_OnITExpired(victim);
	SetEntPropFloat(victim, Prop_Send, "m_vomitStart", 0.0);
	SetEntPropFloat(victim, Prop_Send, "m_vomitFadeStart", 0.0);
}

public Action L4D2_OnHitByVomitJar(int victim, int &attacker)
{
	// 特感被胆汁罐命中时记录窗口，随后由 L4D_OnSpawnITMob 按 cvar 决定是否阻止 IT 尸潮
	if (g_cvEnable.BoolValue && g_cvBlockHorde.BoolValue
		&& victim > 0 && victim <= MaxClients && IsClientInGame(victim)
		&& GetClientTeam(victim) == TEAM_INFECTED)
	{
		g_fSIBileMobBlockUntil = GetGameTime() + 0.2;
	}

	return Plugin_Continue;
}

public void L4D2_OnHitByVomitJar_Post(int victim, int attacker)
{
	// 任何特感（含 Tank）被胆汁罐直接命中后：立即移除屏幕模糊并结束 IT 状态（不吸引小僵尸）
	if (g_cvEnable.BoolValue
		&& victim > 0 && victim <= MaxClients && IsClientInGame(victim)
		&& GetClientTeam(victim) == TEAM_INFECTED)
	{
		ClearSIBileEffect(victim);
	}
}

public Action L4D_OnVomitedUpon(int victim, int &attacker, bool &boomerExplosion)
{
	// Boomer 喷吐/爆炸让特感"成为 it"时直接阻止：不给屏幕模糊、不触发 IT 尸潮、不吸引小僵尸
	if (g_cvEnable.BoolValue
		&& victim > 0 && victim <= MaxClients && IsClientInGame(victim)
		&& GetClientTeam(victim) == TEAM_INFECTED)
	{
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

public Action L4D_OnSpawnITMob(int &amount)
{
	// 只拦截特感胆汁紧随而来的 IT 尸潮，不影响生还者胆汁等正常尸潮
	if (g_cvEnable.BoolValue && g_cvBlockHorde.BoolValue && g_fSIBileMobBlockUntil > GetGameTime())
	{
		g_fSIBileMobBlockUntil = 0.0;
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

public void Event_AbilityUse(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnable.BoolValue)
		return;

	char ability[32];
	event.GetString("ability", ability, sizeof(ability));
	if (!StrEqual(ability, "ability_vomit"))
		return;

	int boomer = GetClientOfUserId(event.GetInt("userid"));
	if (boomer <= 0 || !IsClientInGame(boomer) || GetClientTeam(boomer) != TEAM_INFECTED || !IsPlayerAlive(boomer))
		return;

	DataPack pack = new DataPack();
	pack.WriteCell(boomer);
	pack.WriteFloat(GetGameTime() + g_fVomitDuration);
	CreateTimer(SPIT_SCAN_INTERVAL, Timer_SpitScan, pack, TIMER_REPEAT);
}

public Action Timer_SpitScan(Handle timer, DataPack pack)
{
	pack.Reset();
	int boomer = pack.ReadCell();
	float endTime = pack.ReadFloat();

	if (GetGameTime() >= endTime)
	{
		delete pack;
		return Plugin_Stop;
	}
	if (boomer <= 0 || !IsClientInGame(boomer) || !IsPlayerAlive(boomer) || GetClientTeam(boomer) != TEAM_INFECTED)
	{
		delete pack;
		return Plugin_Stop;
	}

	SpitScan(boomer);
	return Plugin_Continue;
}

void SpitScan(int boomer)
{
	float pos[3], ang[3], dir[3];
	GetClientEyePosition(boomer, pos);
	GetClientEyeAngles(boomer, ang);
	GetAngleVectors(ang, dir, NULL_VECTOR, NULL_VECTOR);

	float range = g_fVomitRange;
	float cosHalf = g_fVomitTargetDot;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (i == boomer)
			continue;
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_INFECTED || !IsPlayerAlive(i))
			continue;
		if (IsSIGhost(i))
			continue;

		float targetPos[3];
		GetClientEyePosition(i, targetPos);

		float to[3];
		SubtractVectors(targetPos, pos, to);
		float dist = GetVectorLength(to);
		if (dist < 1.0 || dist > range)
			continue;

		NormalizeVector(to, to);
		if (GetVectorDotProduct(dir, to) < cosHalf)
			continue;
		if (!IsVisibleTo(pos, targetPos))
			continue;

		BileSpecialInfected(i, boomer);
	}
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client <= 0 || !IsClientInGame(client))
		return;

	int team = GetClientTeam(client);
	if (team == TEAM_INFECTED)
	{
		if (GetEntProp(client, Prop_Send, "m_zombieClass") == ZOMBIECLASS_BOOMER)
		{
			GetClientEyePosition(client, g_fBoomerDeathPos);
			g_bBoomerDeathValid = true;
		}
		ClearSIBileLife(client);
	}
	else if (team == TEAM_SURVIVOR)
	{
		g_bSurvivorBiled[client] = false;
	}
}

public void Event_BoomerExploded(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnable.BoolValue)
		return;

	int boomer = GetClientOfUserId(event.GetInt("userid"));
	if (boomer <= 0 || !IsClientInGame(boomer))
		return;

	float pos[3];
	if (g_bBoomerDeathValid)
	{
		pos = g_fBoomerDeathPos;
		g_bBoomerDeathValid = false;
	}
	else
	{
		GetClientEyePosition(boomer, pos);
	}

	float radius = BOOMER_EXPLOSION_RADIUS;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (i == boomer)
			continue;
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_INFECTED || !IsPlayerAlive(i))
			continue;
		if (IsSIGhost(i))
			continue;

		float targetPos[3];
		GetClientEyePosition(i, targetPos);

		if (GetVectorDistance(pos, targetPos) > radius)
			continue;
		if (!IsVisibleTo(pos, targetPos))
			continue;

		BileSpecialInfected(i, boomer);
	}
}

public Action Timer_HealBiled(Handle timer)
{
	float now = GetGameTime();

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!g_bSIBiled[i])
			continue;

		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_INFECTED || !IsPlayerAlive(i))
		{
			ClearSIBileLife(i);
			continue;
		}
		if (IsSIGhost(i))
		{
			ClearSIBileLife(i);
			continue;
		}
		if (now >= g_fSIBileEnd[i])
		{
			ClearSIBileState(i);
			continue;
		}

		int heal = RoundToNearest(g_fSIBileHeal[i]);
		if (heal > 0)
		{
			int hp = GetEntProp(i, Prop_Send, "m_iHealth");
			int maxHp = GetEntProp(i, Prop_Data, "m_iMaxHealth");
			int newHp = hp + heal;
			if (newHp > maxHp)
				newHp = maxHp;
			if (newHp > hp)
				SetEntProp(i, Prop_Send, "m_iHealth", newHp);
		}
	}
	return Plugin_Continue;
}

public void L4D_OnEnterGhostState(int client)
{
	ClearSIBileLife(client);
}

public void L4D2_VomitJar_Detonate_Post(int entity, int client)
{
	if (!g_cvEnable.BoolValue)
		return;
	if (!IsValidEntity(entity))
		return;

	float pos[3];
	GetEntPropVector(entity, Prop_Send, "m_vecOrigin", pos);
	pos[2] += BILE_POS_HEIGHT_FIX;

	AddBileZone(pos, client);
}

void AddBileZone(const float pos[3], int attacker)
{
	float now = GetGameTime();
	float expire = now + g_fBileDuration;

	int slot = -1;
	float oldest = expire;
	for (int i = 0; i < MAX_ZONES; i++)
	{
		if (g_fZoneEnd[i] <= now)
		{
			slot = i;
			break;
		}
		if (g_fZoneEnd[i] < oldest)
		{
			oldest = g_fZoneEnd[i];
			slot = i;
		}
	}

	g_fZonePos[slot] = pos;
	g_fZoneEnd[slot] = expire;
	g_iZoneAttacker[slot] = attacker;
}

public Action Timer_ZoneTick(Handle timer)
{
	float now = GetGameTime();
	float radius = g_cvJarZoneRadius.FloatValue;

	for (int z = 0; z < MAX_ZONES; z++)
	{
		if (g_fZoneEnd[z] <= now)
			continue;

		for (int i = 1; i <= MaxClients; i++)
		{
			if (!IsClientInGame(i) || !IsPlayerAlive(i))
				continue;

			float pos[3];
			GetClientEyePosition(i, pos);
			if (GetVectorDistance(pos, g_fZonePos[z]) > radius)
				continue;

			int team = GetClientTeam(i);
			if (team == TEAM_SURVIVOR)
			{
				if (g_bSurvivorBiled[i])
					continue;

				int attacker = (g_iZoneAttacker[z] > 0 && g_iZoneAttacker[z] <= MaxClients && IsClientInGame(g_iZoneAttacker[z]))
					? g_iZoneAttacker[z] : i;

				L4D_CTerrorPlayer_OnVomitedUpon(i, attacker);
				g_bSurvivorBiled[i] = true;
			}
			else if (team == TEAM_INFECTED)
			{
				int attacker = (g_iZoneAttacker[z] > 0 && g_iZoneAttacker[z] <= MaxClients && IsClientInGame(g_iZoneAttacker[z]))
					? g_iZoneAttacker[z] : i;

				BileSpecialInfected(i, attacker);
			}
		}
	}

	for (int z = 0; z < MAX_ZONES; z++)
	{
		if (g_fZoneEnd[z] <= now)
			g_fZoneEnd[z] = 0.0;
	}
	return Plugin_Continue;
}

public Action Event_PlayerNowIt(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client > 0 && client <= MaxClients && IsClientInGame(client))
	{
		if (GetClientTeam(client) == TEAM_INFECTED)
		{
			// 特感成为 it（无论来源）→ 立刻移除屏幕模糊并结束 IT 状态，不吸引小僵尸
			if (g_cvEnable.BoolValue)
			{
				ClearSIBileEffect(client);
				return Plugin_Handled;
			}
			return Plugin_Continue;
		}
		g_bSurvivorBiled[client] = true;
	}
	return Plugin_Continue;
}

public void Event_PlayerNoLongerIt(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client > 0 && client <= MaxClients && IsClientInGame(client))
		g_bSurvivorBiled[client] = false;
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client <= 0 || client > MaxClients || !IsClientInGame(client))
		return;

	int team = event.GetInt("team");
	if (team != TEAM_INFECTED)
		ClearSIBileLife(client);
	if (team != TEAM_SURVIVOR)
		g_bSurvivorBiled[client] = false;
}

bool IsVisibleTo(float position[3], float targetposition[3])
{
	float vAngles[3], vLookAt[3];

	MakeVectorFromPoints(position, targetposition, vLookAt);
	GetVectorAngles(vLookAt, vAngles);

	Handle trace = TR_TraceRayFilterEx(position, vAngles, MASK_SHOT, RayType_Infinite, _TraceFilter);
	bool isVisible = false;
	if (TR_DidHit(trace))
	{
		float vStart[3];
		TR_GetEndPosition(vStart, trace);

		if ((GetVectorDistance(position, vStart, false) + 25.0) >= GetVectorDistance(position, targetposition))
		{
			isVisible = true;
		}
	}
	else
	{
		LogError("Tracer Bug: Bile trace did not hit anything");
		isVisible = true;
	}
	delete trace;
	return isVisible;
}

public bool _TraceFilter(int entity, int contentsMask)
{
	if (!entity || !IsValidEntity(entity))
	{
		return false;
	}
	return true;
}
