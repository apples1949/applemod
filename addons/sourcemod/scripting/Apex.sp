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

#define TRAC_ROCK_MAX	   2048 /* 跟踪石相关数组上限(tank_rock 实体索引) */

bool   IsBhop[MAXPLAYERS + 1];
bool   IsTrac[MAXPLAYERS + 1];

int	   Dir[MAXPLAYERS + 1];
int	   Posture[MAXPLAYERS + 1];
int	   BhopLim[MAXPLAYERS + 1];
int	   TracLim[MAXPLAYERS + 1];

/* 坦克连跳检测(参考 lilac_bhop.sp 的连跳判定) */
int	   BhopBtn[MAXPLAYERS + 1];	   /* 上一帧按键快照(检测 IN_JUMP 按下沿) */
int	   BhopTick[MAXPLAYERS + 1];   /* 下一次连跳允许的最小 tick(lilac: next_bhop) */
int	   BhopChain[MAXPLAYERS + 1];  /* 当前连续完美连跳次数(lilac: perfect_bhops) */

ConVar Apex[14];

/* -----------------------------------------------------------
	跟踪石平衡功能(原 l4d_tracerock.sp 新增功能迁移至此)
----------------------------------------------------------- */
bool  g_bHasTracePlugin;					  /* l4d_tracerock.smx 是否已加载(未加载时跟踪功能不存在) */
bool  g_bLateLoad;
bool  g_bTraceRock[TRAC_ROCK_MAX + 1];		  /* 该 tank_rock 是否为跟踪石 */
float g_fRockDamage[TRAC_ROCK_MAX + 1];		  /* 跟踪石累计承受的伤害 */
float g_fTraceHitLock[MAXPLAYERS + 1];		  /* 命中约束: 生还者免疫追踪石的截止时间 */
int	  g_iCtrlSnapshot[MAXPLAYERS + 1];		  /* 坦克 m_frustration 的上一帧快照 */
int	  g_iCtrlBase[MAXPLAYERS + 1];			  /* 命中瞬间的 m_frustration 基准值 */
bool  g_bCtrlPending[MAXPLAYERS + 1];		  /* 本帧已排入控制权换算(同帧多次命中只算一次) */

public Plugin myinfo =
{
	name		= PLG_NAME,
	author		= PLG_AUTH,
	description = PLG_DESC,
	version		= PLG_VERS,
	url			= PLG_URLS,


}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	RegPluginLibrary("Apex");
	CreateNative("Apex_IsBhopEnabled", Native_IsBhopEnabled);
	CreateNative("Apex_IsTracEnabled", Native_IsTracEnabled);
	g_bLateLoad = late;
	return APLRes_Success;
}

public int Native_IsBhopEnabled(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients)
		return 0;

	return IsBhop[client] ? 1 : 0;
}

public int Native_IsTracEnabled(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients)
		return 0;

	return IsTrac[client] ? 1 : 0;
}

public void
	OnPluginStart()
{
	Apex[0] = CreateConVar("l4d2_block_punch_rock", "1", "阻止坦克同时出拳和扔石头 0-不阻止 1-阻止");
	Apex[1] = CreateConVar("l4d2_block_jump_rock", "0", "阻止坦克同时跳跃和扔石块 0-不阻止 1-阻止");
	Apex[2] = CreateConVar("tank_hp", "0", "坦克设置为多少血量? 0=禁用");
	Apex[3] = CreateConVar("tank_bohp_hp", "1500", "开启坦克连跳时扣血量.0为禁用");
	Apex[4] = CreateConVar("tank_trac_hp", "1000", "开启石头追踪时扣血量.0为禁用");
	Apex[5] = CreateConVar("tank_trac_throw_hp", "50", "每掷出一发跟踪石头扣除的自身血量.0为禁用");
	Apex[6] = CreateConVar("l4d_tracerock_health", "40", "跟踪石血量(点). 生还者打掉这些血量即可在空中打碎跟踪石. 0=不接管(用游戏默认血量)");
	Apex[7] = CreateConVar("l4d_tracerock_hit_lock", "5.0", "命中约束: 生还者被跟踪石命中后, 该秒数内免疫跟踪石伤害(普通石头不受影响). 0=禁用", _, true, 0.0);
	Apex[8] = CreateConVar("l4d_tracerock_ctrl_base", "5.0", "游戏默认的坦克控制权(m_frustration)变化步长(%), 用于换算. 0=禁用控制权调整", _, true, 0.0);
	Apex[9] = CreateConVar("l4d_tracerock_ctrl_step", "6.0", "跟踪石命中生还者后希望的控制权变化步长(%): 把游戏的 ctrl_base 换算成该值", _, true, 0.0);
	Apex[10] = CreateConVar("l4d_tracerock_debug", "0", "跟踪石调试日志 0=关闭 1=输出到服务器控制台", _, true, 0.0, true, 1.0);
	Apex[11] = CreateConVar("tank_bhop_detect", "1", "坦克连跳检测: 未开启!bhop技能的坦克成功连跳时补扣技能血量并通报全场 0=禁用 1=启用", _, true, 0.0, true, 1.0);
	Apex[12] = CreateConVar("tank_bhop_detect_count", "10", "连续完美连跳达到该次数即判定为成功连跳(参考liac的min档位).0=禁用", _, true, 0.0);
	Apex[13] = CreateConVar("tank_bhop_detect_air", "0.3", "两次连跳之间的最小滞空时间(秒), 参考liac的air设置(>1.0按1.0算)", _, true, 0.0, true, 1.0);

	HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Pre);
	HookEvent("player_jump_apex", Event_PlayerJumpApex);
	HookEvent("tank_spawn", Event_TankSpawn);
	HookEvent("round_end", Event_RoundEnd);

	RegConsoleCmd("sm_trac", Call_Trac);
	RegConsoleCmd("sm_bhop", Call_Bohp);
	RegConsoleCmd("sm_gz", Call_Trac);
	RegConsoleCmd("sm_lt", Call_Bohp);

	if (g_bLateLoad)
	{
		for (int i = 1; i <= MaxClients; i++)
			if (IsClientInGame(i))
				OnClientPutInServer(i);
	}
}

public void OnAllPluginsLoaded()
{
	g_bHasTracePlugin = LibraryExists("L4D_OnTraceRockCreated");
	PrintToServer("(%s) Apex插件依赖的插件:l4d_tracerock.smx", g_bHasTracePlugin ? "已加载" : "未加载");
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
	int hp	  = GetEntProp(client, Prop_Data, "m_iHealth");

	/* 已开，那么关闭 */
	if (IsTrac[client])
	{
		IsTrac[client] = false;
		CPrintToChat(client, "%sTank石头追踪已关闭", TAG);

		return Plugin_Handled;
	}

	/* 已关 */
	if (TracLim[client] == 1) /* 本命已经付过开启费，随时开关，不再扣血 */
	{
		IsTrac[client] = true;
		CPrintToChat(client, "%sTank石头追踪已开启(本命已扣过开启费)", TAG);
	}
	else if (mumhp <= 0) /* 开启费为 0，直接开启 */
	{
		IsTrac[client]	 = true;
		TracLim[client]	 = 1;
		CPrintToChat(client, "%sTank石头追踪已开启", TAG);
	}
	else if (hp - mumhp > 0) /* 血足，扣开启费后开启 */
	{
		IsTrac[client]	 = true;
		TracLim[client]	 = 1;
		SetEntProp(client, Prop_Data, "m_iHealth", hp - mumhp);
		CPrintToChat(client, "%sTank石头追踪已开启(扣 %d 血)", TAG, mumhp);
	}
	else /* 血不足，保持关闭 */
	{
		IsTrac[client] = false;
		CPrintToChat(client, "%sTank石头追踪未开启(当前血量不足以扣除 %d 血)", TAG, mumhp);
	}

	return Plugin_Handled;
}
Action Call_Bohp(int client, int args)
{
	if (!IsTank(client))
		return Plugin_Handled;

	int mumhp = Apex[3].IntValue;
	int hp	  = GetEntProp(client, Prop_Data, "m_iHealth");

	/* 已开，那么关闭 */
	if (IsBhop[client])
	{
		IsBhop[client] = false;
		CPrintToChat(client, "%sTank自动连跳已关闭", TAG);
		return Plugin_Handled;
	}

	/* 已关 */
	if (BhopLim[client] == 1) /* 本命已经付过开启费，随时开关，不再扣血 */
	{
		IsBhop[client] = true;
		CPrintToChat(client, "%sTank自动连跳已开启(本命已扣过开启费)", TAG);
	}
	else if (mumhp <= 0) /* 开启费为 0，直接开启 */
	{
		IsBhop[client]	= true;
		BhopLim[client] = 1;
		CPrintToChat(client, "%sTank自动连跳已开启", TAG);
	}
	else if (hp - mumhp > 0) /* 血足，扣开启费后开启 */
	{
		IsBhop[client]	= true;
		BhopLim[client] = 1;
		SetEntProp(client, Prop_Data, "m_iHealth", hp - mumhp);
		CPrintToChat(client, "%sTank自动连跳已开启(扣 %d 血)", TAG, mumhp);
	}
	else /* 血不足，保持关闭 */
	{
		IsBhop[client] = false;
		CPrintToChat(client, "%sTank自动连跳未开启(当前血量不足以扣除 %d 血)", TAG, mumhp);
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
	// 不需要处理横向速度
}
void Event_TankSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	if (!IsTank(client)) return;

	Reset(client);
	if (Apex[2].IntValue > 0) CreateTimer(0.1, SetTankHealth, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	CPrintToChat(client, "%sE 键 -> 低手抛石(砸屋檐下)", TAG);
	CPrintToChat(client, "%s右键 -> 单手抛石(万能姿势)", TAG);
	CPrintToChat(client, "%sR 键 -> 双手抛石(过高墙)", TAG);
	CPrintToChat(client, "%s指令{lightgreen}!bhop{darkred}开启自动连跳(扣%d血量)", TAG, Apex[3].IntValue);
	CPrintToChat(client, "%s指令{lightgreen}!trac{darkred}开启跟踪石头(开启扣%d血, 每发扣%d血)", TAG, Apex[4].IntValue, Apex[5].IntValue);

	if (Apex[11].BoolValue && Apex[12].IntValue > 0 && Apex[3].IntValue > 0)
		CPrintToChat(client, "%s未开启{lightgreen}!bhop{darkred}却连续连跳{lightgreen}%d{darkred}次, 将扣除技能血量{lightgreen}%d{darkred}并通报全场", TAG, Apex[12].IntValue, Apex[3].IntValue);
}

Action SetTankHealth(Handle timer, any client)
{
	if ((client = GetClientOfUserId(client)) && IsValidClient(client) && !IsFakeClient(client))
	{
		SetEntProp(client, Prop_Data, "m_iHealth", Apex[2].IntValue);
		SetEntProp(client, Prop_Data, "m_iMaxHealth", Apex[2].IntValue);
	}
	return Plugin_Continue;
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

	/* 连跳检测用客户端原始按键, 必须放在下面按键改写(清 IN_JUMP)之前 */
	BhopDetect_Check(client, buttons);

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
		if (IsBhop[client] && !(GetEntityFlags(client) & FL_ONGROUND) && !(GetEntityMoveType(client) & MOVETYPE_LADDER))
			buttons &= ~IN_JUMP;
	}

	return Plugin_Continue;
}

/* -----------------------------------------------------------
	坦克连跳检测(参考 lilac 的 lilac_bhop.sp)
	判定"完美连跳": 在地面按下跳跃, 且距上一次起跳的间隔 >= air 秒;
	连续完美连跳达到阈值即视为"成功连跳".
	坦克若本命从未为 !bhop 技能付过血(即血量数据没减), 判定后补扣技能
	血量并通报全场.
	(lilac 的连跳链首跳不计入, min=10 需 11 次起跳; 这里直接按连续完美
	 连跳次数计数, 默认阈值 10 = 第 10 次起跳即判定; 需严格对齐 lilac 可
	 把 tank_bhop_detect_count 设为 11)
----------------------------------------------------------- */

/* 连跳链清零(落地未起跳 / 起跳间隔不足 / 已付费 时调用) */
void BhopDetect_Reset(int client)
{
	BhopChain[client] = 0;
	BhopTick[client]  = GetGameTickCount();
}

/* tank_bhop_detect_air(秒) 换算成 tick(lilac: tick_rate * air) */
int BhopDetect_AirTicks()
{
	float air = Apex[13].FloatValue;
	if (air <= 0.0)
		return 0;
	if (air > 1.0)
		air = 1.0;

	float interval = GetTickInterval();
	if (interval <= 0.0)
		return 0;

	return RoundToCeil(air / interval);
}

/* 每帧判定(由 OnPlayerRunCmd 调用) */
void BhopDetect_Check(int client, int buttons)
{
	int last = BhopBtn[client];
	BhopBtn[client] = buttons;

	int need = Apex[12].IntValue;

	/* 检测关闭 / 阈值非法 / 技能本身不扣血: 不判定 */
	if (!Apex[11].BoolValue || need <= 0 || Apex[3].IntValue <= 0)
	{
		BhopDetect_Reset(client);
		return;
	}

	/* 本命已付费(技能开启中 或 已扣过开启费): 血量数据已减, 不判定 */
	if (IsBhop[client] || BhopLim[client] == 1)
	{
		BhopDetect_Reset(client);
		return;
	}

	/* 只有"在地面按下跳跃"的那一帧才算一次起跳(lilac 同) */
	if ((buttons & IN_JUMP) && !(last & IN_JUMP))
	{
		if (!(GetEntityFlags(client) & FL_ONGROUND))
			return;

		int tick = GetGameTickCount();

		/* 与上一次起跳间隔不足 air 秒: 不是连跳, 计数清零 */
		if (tick <= BhopTick[client])
		{
			BhopDetect_Reset(client);
			return;
		}

		BhopTick[client] = tick + BhopDetect_AirTicks();
		BhopChain[client]++;

		if (BhopChain[client] >= need)
			BhopDetect_Charge(client, BhopChain[client]);

		return;
	}

	/* 落地后没有新的跳跃按下: 连跳链结束 */
	if (GetEntityFlags(client) & FL_ONGROUND)
		BhopDetect_Reset(client);
}

/* 判定为"未付费的成功连跳": 补扣技能血量 + 通报全场(一命只扣一次) */
void BhopDetect_Charge(int client, int chain)
{
	int cost = Apex[3].IntValue;
	if (cost <= 0 || !IsTank(client))
	{
		/* 无法补扣: 结束本次连跳链, 避免每次起跳重复判定 */
		BhopChain[client] = 0;
		return;
	}

	/* 视作本命已付费: 本命不再重复判定, 之后 !bhop 按"已扣过开启费"处理 */
	BhopLim[client] = 1;
	BhopDetect_Reset(client);

	int hp = GetEntProp(client, Prop_Data, "m_iHealth");

	/* 血量不足: 与技能一致, 不把坦克扣死 */
	if (hp <= 1)
	{
		CPrintToChatAll("%s坦克 {lightgreen}%N{darkred} 未开启{lightgreen}!bhop{darkred}技能却连续连跳{lightgreen}%d{darkred}次(血量不足, 未扣血)", TAG, client, chain);
		return;
	}

	if (cost > hp - 1)
		cost = hp - 1;

	SetEntProp(client, Prop_Data, "m_iHealth", hp - cost);

	CPrintToChatAll("%s坦克 {lightgreen}%N{darkred} 未开启{lightgreen}!bhop{darkred}技能却连续连跳{lightgreen}%d{darkred}次, 已扣除技能血量{lightgreen}%d", TAG, client, chain, cost);
}

/* -----------------------------------------------------------
	转发设置
----------------------------------------------------------- */
public Action L4D_OnCThrowActivate(int ability)
{
	if (!IsValidEntity(ability))
		return Plugin_Continue;

	int client = GetEntPropEnt(ability, Prop_Data, "m_hOwnerEntity");

	/* m_hOwnerEntity 可能是 0/-1, GetClientButtons 不做合法性检查, 必须先挡掉 */
	if (!IsValidClient(client))
		return Plugin_Continue;

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

	/* 本次石头会追踪 -> 掷出即扣自身血量 */
	if (trace)
		ChargeTracThrow(client);
}

/* 掷出跟踪石头扣血: 最多扣到只剩 1 血, 技能不会把坦克扣死 */
void ChargeTracThrow(int client)
{
	int cost = Apex[5].IntValue;
	if (cost <= 0 || !IsTank(client))
		return;

	int hp = GetEntProp(client, Prop_Data, "m_iHealth");
	if (hp <= 1)
		return;

	if (cost > hp - 1)
		cost = hp - 1;

	SetEntProp(client, Prop_Data, "m_iHealth", hp - cost);
}

/* -----------------------------------------------------------
	跟踪石平衡功能: 血量 / 命中约束 / 控制权步长
	(石头是否为"跟踪石"在此判定: 出石瞬间坦克开着 !trac)
----------------------------------------------------------- */

/* l4d_tracerock.smx 是否加载(未加载则不存在跟踪石, 平衡功能不生效); 懒检查以兼容插件后加载 */
bool HasTracePlugin()
{
	if (!g_bHasTracePlugin)
		g_bHasTracePlugin = LibraryExists("L4D_OnTraceRockCreated");

	return g_bHasTracePlugin;
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (strcmp(classname, "tank_rock") == 0)
		SDKHook(entity, SDKHook_SpawnPost, OnRockSpawnPost);
}

void OnRockSpawnPost(int rock)
{
	/* 实体索引会被复用, 先复位状态 */
	g_bTraceRock[rock]	= false;
	g_fRockDamage[rock] = 0.0;

	int owner = GetEntPropEnt(rock, Prop_Data, "m_hOwnerEntity");

	/* 只有"坦克开着跟踪、且跟踪插件确实加载"时掷出的石头才算跟踪石 */
	if (!HasTracePlugin() || !IsTank(owner) || !IsTrac[owner])
		return;

	g_bTraceRock[rock] = true;

	/* 跟踪石血量: 交给引擎 40 点血, 同时自行累计伤害兜底(见 OnRockTakeDamage) */
	int health = Apex[6].IntValue;
	if (health > 0)
	{
		SetEntProp(rock, Prop_Data, "m_iHealth", health);
		SetEntProp(rock, Prop_Data, "m_takedamage", 2);	   // DAMAGE_YES: 确保子弹能打到石头(原本已开启则无影响)
		SDKHook(rock, SDKHook_OnTakeDamage, OnRockTakeDamage);
	}

	SDKHook(rock, SDKHook_Think, OnRockThink);
}

/* 每帧记录石头主人(坦克)的控制权 m_frustration, 命中时用于换算步长 */
public void OnRockThink(int rock)
{
	if (!g_bTraceRock[rock])
		return;

	float base = Apex[8].FloatValue;
	if (base <= 0.0 || Apex[9].FloatValue == base)
		return;

	int owner = GetEntPropEnt(rock, Prop_Data, "m_hOwnerEntity");
	if (IsTank(owner))
		g_iCtrlSnapshot[owner] = GetEntProp(owner, Prop_Send, "m_frustration");
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_OnTakeDamage, OnClientTakeDamage);
}

public void OnClientDisconnect(int client)
{
	SDKUnhook(client, SDKHook_OnTakeDamage, OnClientTakeDamage);

	g_fTraceHitLock[client] = 0.0;
	g_iCtrlSnapshot[client] = 0;
	g_iCtrlBase[client]		= 0;
	g_bCtrlPending[client]	= false;
}

/**
 * 跟踪石命中生还者:
 *  1. 命中约束: 刚被跟踪石命中过的生还者, 在免疫时间内不再吃跟踪石伤害(同一人无法被连续命中)
 *  2. 控制权步长: 把引擎本次造成的 m_frustration 变化, 从 ctrl_base% 换算成 ctrl_step%
 */
public Action OnClientTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype,
								 int &weapon, float damageForce[3], float damagePosition[3])
{
	if (!IsSurvivor(victim))
		return Plugin_Continue;

	if (inflictor <= MaxClients || inflictor >= sizeof(g_bTraceRock))
		return Plugin_Continue;

	if (!g_bTraceRock[inflictor])
		return Plugin_Continue;

	/* 只有真正造成伤害的命中才算命中(被无敌帧等挡掉的擦碰不计入免疫) */
	if (damage <= 0.0)
		return Plugin_Continue;

	int tank = GetEntPropEnt(inflictor, Prop_Data, "m_hOwnerEntity");
	if (!IsTank(tank))
		return Plugin_Continue;

	float now = GetGameTime();

	/* 1. 命中约束 */
	float lockTime = Apex[7].FloatValue;
	if (lockTime > 0.0)
	{
		if (g_fTraceHitLock[victim] > now)
		{
			CPrintToChat(tank, "%s跟踪石被{lightgreen}%N{darkred}免疫(剩 %.1f 秒)", TAG, victim, g_fTraceHitLock[victim] - now);
			return Plugin_Handled;
		}

		g_fTraceHitLock[victim] = now + lockTime;
	}

	/* 2. 控制权步长换算(读值放到本帧结束, 此时引擎已经改完 m_frustration) */
	float base = Apex[8].FloatValue;
	if (base > 0.0 && Apex[9].FloatValue != base && !g_bCtrlPending[tank])
	{
		g_bCtrlPending[tank] = true;
		g_iCtrlBase[tank]	 = g_iCtrlSnapshot[tank];
		RequestFrame(Frame_ApplyCtrlStep, GetClientUserId(tank));
	}

	return Plugin_Continue;
}

void Frame_ApplyCtrlStep(any data)
{
	int tank = GetClientOfUserId(data);
	if (!IsTank(tank))
		return;

	g_bCtrlPending[tank] = false;

	int current = GetEntProp(tank, Prop_Send, "m_frustration");
	int delta	= current - g_iCtrlBase[tank];

	if (delta == 0)
	{
		if (Apex[10].BoolValue)
			PrintToServer("[Apex] 跟踪石命中后未检测到控制权变化(tank=%N, 当前值=%d, 基准值=%d)", tank, current, g_iCtrlBase[tank]);
		return;
	}

	/* 引擎步长 delta 对应 ctrl_base%, 多扣/多加的部分 = (ctrl_step/ctrl_base - 1) * delta */
	float scale = (Apex[9].FloatValue / Apex[8].FloatValue) - 1.0;
	int	  extra = RoundToNearest(float(delta) * scale);
	if (extra == 0)
		extra = (delta > 0) ? 1 : -1;

	int result = current + extra;
	if (result > 100)
		result = 100;
	if (result < 0)
		result = 0;

	if (result != current)
		SetEntProp(tank, Prop_Send, "m_frustration", result);

	if (Apex[10].BoolValue)
		PrintToServer("[Apex] 跟踪石控制权 %d -> %d (引擎步长 %d, 目标步长 %.1f%%)", current, result, delta, Apex[9].FloatValue);
}

/**
 * 跟踪石血量: 自行累计伤害, 血量耗尽即打碎石头.
 * (同时已把 m_iHealth 设为 cvar 值; 若引擎自己按血量打碎, 这条路径不会触发)
 */
public Action OnRockTakeDamage(int rock, int &attacker, int &inflictor, float &damage, int &damagetype,
							   int &weapon, float damageForce[3], float damagePosition[3])
{
	int health = Apex[6].IntValue;
	if (!g_bTraceRock[rock] || health <= 0 || damage <= 0.0)
		return Plugin_Continue;

	g_fRockDamage[rock] += damage;

	if (g_fRockDamage[rock] < float(health))
		return Plugin_Continue;

	if (Apex[10].BoolValue)
		PrintToServer("[Apex] 跟踪石(实体 %d)累计承受 %.1f 点伤害, 打碎", rock, g_fRockDamage[rock]);

	BreakTraceRock(rock);

	return Plugin_Handled;
}

void BreakTraceRock(int rock)
{
	if (!g_bTraceRock[rock])
		return;

	g_bTraceRock[rock]	= false;
	g_fRockDamage[rock] = 0.0;

	SDKUnhook(rock, SDKHook_Think, OnRockThink);
	SDKUnhook(rock, SDKHook_OnTakeDamage, OnRockTakeDamage);

	SetEntityRenderFx(rock, RENDERFX_FADE_FAST);
	CreateTimer(0.5, Timer_RemoveRock, EntIndexToEntRef(rock), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_RemoveRock(Handle timer, any ref)
{
	int rock = EntRefToEntIndex(ref);
	if (ref && rock != INVALID_ENT_REFERENCE)
	{
		g_bTraceRock[rock]	= false;
		g_fRockDamage[rock] = 0.0;
		RemoveEntity(rock);
	}

	return Plugin_Continue;
}

bool IsSurvivor(int client)
{
	return (IsValidClient(client) && GetClientTeam(client) == 2);
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

	/* 连跳检测: 新一条命重新开始计数, 按键快照清空 */
	BhopBtn[client] = 0;
	BhopDetect_Reset(client);

	/* 新一条命/新回合不继承跟踪石的命中免疫 */
	g_fTraceHitLock[client] = 0.0;
	g_iCtrlSnapshot[client] = 0;
	g_iCtrlBase[client]		= 0;
	g_bCtrlPending[client]	= false;
}