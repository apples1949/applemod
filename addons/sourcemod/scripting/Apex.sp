#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>
#include <colors>

#define PLG_NAME		   "Tank Attack Control Plus"
#define PLG_AUTH		   "游而戏之,apples1949"
#define PLG_DESC		   "-"
#define PLG_VERS		   ""
#define PLG_URLS		   "-"

#define IsValidClient(%1)  (0 < %1 <= MaxClients && IsClientInGame(%1))
#define IsTank(%1)		   (IsValidClient(%1) && !IsFakeClient(%1) && GetClientTeam(%1) == 3 && GetEntProp(%1, Prop_Send, "m_zombieClass") == 8)

#define BHOPMODE_BLOCK	   0  /* 禁用连跳 */
#define BHOPMODE_AUTO	   1  /* 自动连跳 */
#define L				   -1 /* 左向 */
#define R				   1  /* 右向 */

#define TAG				   "{olive}[{lightred}!{olive}]{orange}"

bool   IsBhop[MAXPLAYERS + 1];
bool   IsTrac[MAXPLAYERS + 1];

int	   Dir[MAXPLAYERS + 1];
int	   Posture[MAXPLAYERS + 1];
int	   BhopLim[MAXPLAYERS + 1];
int	   TracLim[MAXPLAYERS + 1];

ConVar Apex[8];

public Plugin myinfo =
{
	name		= PLG_NAME,
	author		= PLG_AUTH,
	description = PLG_DESC,
	version		= PLG_VERS,
	url			= PLG_URLS,


}

public void OnPluginStart()
{
	Apex[0] = CreateConVar("tank_block_claw", "1", "阻止坦克同时出拳和扔石头 0-不阻止 1-阻止");
	Apex[1] = CreateConVar("tank_block_jump", "0", "阻止坦克同时跳跃和扔石块 0-不阻止 1-阻止");
	Apex[2] = CreateConVar("tank_hp", "8000", "坦克多少血量? 0=禁用");
	Apex[3] = CreateConVar("tank_bohp_hp", "4000", "开启坦克连跳时扣血量.0为禁用");
	Apex[4] = CreateConVar("tank_trac_hp", "3000", "开启石头追踪时扣血量.0为禁用");
	Apex[5] = CreateConVar("tank_bohp_mode", "1", "坦克bohp模式 0-禁用 1-自动连跳.");
	Apex[6] = CreateConVar("tank_bohp_set", "1.5", "设置坦克bohp成功的横向速度增益相乘的值.");
	Apex[7] = CreateConVar("tank_bohp_lim", "300.0", "设置坦克bohp横向速度增益最大值.");

	HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Pre);
	HookEvent("player_jump_apex", Event_PlayerJumpApex);
	HookEvent("tank_spawn", Event_TankSpawn);
	HookEvent("round_end", Event_RoundEnd);

	RegConsoleCmd("sm_trac", Call_Trac);
	RegConsoleCmd("sm_bhop", Call_Bohp);
}

public void OnAllPluginsLoaded()
{
	PrintToServer("(%s) Apex插件依赖的插件:l4d_tracerock.smx", LibraryExists("L4D_OnTraceRockCreated") ? "已加载" : "未加载");
}

/* -----------------------------------------------------------
	命令回调
----------------------------------------------------------- */
Action Call_Trac(int client, int args)
{
	if (!IsTank(client))
	{
		return Plugin_Handled;
	}

	int mumhp = Apex[4].IntValue;
	int newhp = GetEntProp(client, Prop_Data, "m_iHealth") - mumhp;

	/* 已开，那么关闭 */
	if (IsTrac[client])
	{
		IsTrac[client] = false;
		CPrintToChat(client, "%sTank石头追踪已关闭", TAG);

		return Plugin_Handled;
	}

	/* 已关 */
	if (newhp > 0) /* 已关，血足，那么打开，如果没之前没扣过血，那么扣血 */
	{
		IsTrac[client] = true;
		if (TracLim[client] == 0)
		{
			TracLim[client] = 1;

			CPrintToChat(client, "%sTank石头追踪已开启(扣 %d 血)", TAG, mumhp);
			SetEntProp(client, Prop_Data, "m_iHealth", newhp);
		}
		else
		{
			CPrintToChat(client, "%sTank石头追踪已开启", TAG, mumhp);
		}
	}
	else
	{
		if (TracLim[client] == 1) /* 已关，血不足，已扣血，那么开启同时不扣血 */
		{
			IsTrac[client] = true;

			CPrintToChat(client, "%sTank石头追踪已关闭", TAG);
		}
		else /* 已关，血不足，未扣血，那么关闭同时不扣血 */
		{
			IsTrac[client] = false;

			CPrintToChat(client, "%sTank石头追踪已关闭(当前血量不足以扣血)", TAG);
		}
	}

	return Plugin_Handled;
}
Action Call_Bohp(int client, int args)
{
	if (Apex[5].IntValue == BHOPMODE_BLOCK || !IsTank(client))
		return Plugin_Handled;

	int mumhp = Apex[3].IntValue;
	int newhp = GetEntProp(client, Prop_Data, "m_iHealth") - mumhp;

	/* 已开，那么关闭 */
	if (IsBhop[client])
	{
		IsBhop[client] = false;
		CPrintToChat(client, "%sTank自动连跳已关闭", TAG);
		return Plugin_Handled;
	}

	/* 已关 */
	if (newhp > 0) /* 已关，血足，那么打开，如果没之前没扣过血，那么扣血 */
	{
		IsBhop[client] = true;
		if (BhopLim[client] == 0)
		{
			BhopLim[client] = 1;

			CPrintToChat(client, "%sTank自动连跳已开启(扣 %d 血)", TAG, mumhp);
			SetEntProp(client, Prop_Data, "m_iHealth", newhp);
		}
		else
		{
			CPrintToChat(client, "%sTank自动连跳已开启", TAG, mumhp);
		}
	}
	else
	{
		if (BhopLim[client] == 1) /* 已关，血不足，已扣血，那么开启同时不扣血 */
		{
			IsBhop[client] = true;

			CPrintToChat(client, "%sTank自动连跳已关闭", TAG);
		}
		else /* 已关，血不足，未扣血，那么关闭同时不扣血 */
		{
			IsBhop[client] = false;

			CPrintToChat(client, "%sTank自动连跳(当前血量不足以扣血)", TAG);
		}
	}

	return Plugin_Handled;
}

/* -----------------------------------------------------------
	事件钩子
----------------------------------------------------------- */
void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (IsValidClient(client)) Reset(client);
}
void Event_PlayerJumpApex(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	if (!IsTank(client) || !IsBhop[client])
		return;

	int button = GetClientButtons(client);

	if (button & IN_MOVELEFT || button & IN_MOVERIGHT)
	{
		if (button & IN_MOVELEFT)
		{
			if (Dir[client] > L)
			{
				Dir[client] = L;
				return;
			}
			else Dir[client] = L;
		}
		else if (button & IN_MOVERIGHT)
		{
			if (Dir[client] < R)
			{
				Dir[client] = R;
				return;
			}
			else Dir[client] = R;
		}

		float ang[3];
		float right[3];
		float front[3];
		float newspeed[3];

		GetEntPropVector(client, Prop_Send, "m_angRotation", ang);
		GetAngleVectors(ang, NULL_VECTOR, right, NULL_VECTOR);
		NormalizeVector(right, right);

		if (button & IN_MOVELEFT) NegateVector(right);

		/* 限制最大速度 */
		GetEntPropVector(client, Prop_Data, "m_vecVelocity", front);
		if (RoundToNearest(GetVectorLength(front)) > Apex[7].FloatValue)
			return;

		ScaleVector(right, GetVectorLength(right) * Apex[6].FloatValue);

		GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", newspeed);
		for (int i = 1; i < 3; i++)
			newspeed[i] += right[i];

		TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, newspeed);
	}
}
void Event_TankSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	if (!IsTank(client))
		return;

	Reset(client);
	if(Apex[2].IntValue > 0)
	{
		SetEntProp(client, Prop_Data, "m_iHealth", Apex[2].IntValue);
		SetEntProp(client, Prop_Data, "m_iMaxHealth", Apex[2].IntValue);
	}
	CPrintToChat(client, "%sE 键 -> 低手抛石(砸屋檐下)", TAG);
	CPrintToChat(client, "%s右键 -> 单手抛石(万能姿势)", TAG);
	CPrintToChat(client, "%sR 键 -> 双手抛石(过高墙)", TAG);
	CPrintToChat(client, "%s指令{lightgreen}!bhop{darkred}开启自动连跳(扣%d血量)", TAG, Apex[3].IntValue);
	CPrintToChat(client, "%s指令{lightgreen}!trac{darkred}开启跟踪石头(扣%d血量)", TAG, Apex[4].IntValue);
}
void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i)) Reset(i);
}

public void OnMapEnd()
{
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i)) Reset(i);
}
/* -----------------------------------------------------------
	按键设置
----------------------------------------------------------- */
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon)
{
	if (!IsTank(client))
		return Plugin_Continue;

	if (buttons & IN_RELOAD)
	{
		Posture[client] = 3;
		buttons |= IN_ATTACK2;
	}
	else if (buttons & IN_USE)
	{
		Posture[client] = 2;	// underhand
		buttons |= IN_ATTACK2;
	}
	else Posture[client] = 1;	 // one hand overhand

	if (buttons & IN_JUMP)
	{
		if (Apex[5].IntValue == BHOPMODE_AUTO && IsBhop[client] && !(GetEntityFlags(client) & FL_ONGROUND) && !(GetEntityMoveType(client) & MOVETYPE_LADDER))
			buttons &= ~IN_JUMP;
	}

	return Plugin_Continue;
}

/* -----------------------------------------------------------
	转发设置
----------------------------------------------------------- */
public Action L4D_OnCThrowActivate(int ability)
{
	if (!IsValidEntity(ability))
		return Plugin_Continue;

	int client = GetEntPropEnt(ability, Prop_Data, "m_hOwnerEntity");

	if (GetClientButtons(client) & IN_ATTACK)
		if (Apex[0].IntValue) return Plugin_Handled;

	return Plugin_Continue;
}

public Action L4D2_OnSelectTankAttack(int client, int &sequence)
{
	if (sequence > 48 && Posture[client])
	{
		sequence = Posture[client] + 48;
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

public void L4D_OnTraceRockCreated(int client, int &trace)
{
	if (IsTank(client))
		trace = IsTrac[client];
}

/* -----------------------------------------------------------
	其他自定义
----------------------------------------------------------- */
void Reset(int client)
{
	IsBhop[client]	= false;
	IsTrac[client]	= false;
	Dir[client]		= 0;
	Posture[client] = 0;
	TracLim[client] = 0;
	BhopLim[client] = 0;
}