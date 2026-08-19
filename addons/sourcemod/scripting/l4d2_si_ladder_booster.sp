#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define TEAM_INFECTED			3
#define LADDER_SPEED_MULTIPLIER	2.5
#define NORMAL_SPEED			1.0

public Plugin myinfo =
{
	name = "SI Ladder Booster",
	author = "apples1949",
	description = "非玩家操控的特殊感染者爬梯 2.5 倍加速（8 种特殊感染者，不含小僵尸）",
	version = "1.0.0",
	url = ""
};

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	// 仅处理：游戏内、存活、感染者队伍
	if (!IsClientInGame(client) || GetClientTeam(client) != TEAM_INFECTED || !IsPlayerAlive(client))
	{
		return Plugin_Continue;
	}

	// 仅非玩家操控的感染者（AI 控制的 bot，排除真实玩家）
	if (!IsFakeClient(client))
	{
		return Plugin_Continue;
	}

	// 8 种特殊感染者（Smoker/Boomer/Hunter/Spitter/Jockey/Charger/Witch/Tank = 1~8），排除小僵尸（0）
	int zombieClass = GetEntProp(client, Prop_Send, "m_zombieClass");
	if (zombieClass < 1 || zombieClass > 8)
	{
		return Plugin_Continue;
	}

	if (GetEntityMoveType(client) != MOVETYPE_LADDER)
	{
		// 不在梯子上时恢复默认速度；仅当速度是本插件设置的 2.5 时才恢复，避免覆盖其他插件的修改
		if (GetClientSpeed(client) == LADDER_SPEED_MULTIPLIER)
		{
			SetClientSpeed(client, NORMAL_SPEED);
		}
		return Plugin_Continue;
	}

	// 爬梯中：2.5 倍加速
	SetClientSpeed(client, LADDER_SPEED_MULTIPLIER);
	return Plugin_Continue;
}

void SetClientSpeed(int client, float value)
{
	SetEntPropFloat(client, Prop_Send, "m_flLaggedMovementValue", value);
}

float GetClientSpeed(int client)
{
	return GetEntPropFloat(client, Prop_Send, "m_flLaggedMovementValue");
}
