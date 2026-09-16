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
#define CTRL_WATCH_TIME	   0.8	/* 命中后观察引擎改动控制权的时长(秒) */
#define CTRL_HOLD_TIME	   1.0	/* 补正后钉住目标值的时长(秒) */

/* 技能扣血通报类型: 枚举值必须与 Apex.inc 的 ApexSkillCostType 保持一致(消费方包含 Apex.inc) */
enum ApexSkillCostType
{
	ApexSkillCost_Bhop = 0,	  /* !bhop 开启费 */
	ApexSkillCost_TracEnable, /* !trac 开启费 */
	ApexSkillCost_TracThrow,  /* 跟踪石掷出预扣(命中生还者退还时为负数) */
	ApexSkillCost_BhopDetect  /* 未开启 !bhop 却连续连跳被抓的补扣 */
}

Handle g_hFwdSkillCost;

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

ConVar Apex[13];

/* -----------------------------------------------------------
	跟踪石平衡功能(原 l4d_tracerock.sp 新增功能迁移至此)
----------------------------------------------------------- */
bool  g_bHasTracePlugin;					  /* l4d_tracerock.smx 是否已加载(未加载时跟踪功能不存在) */
bool  g_bLateLoad;
bool  g_bTraceRock[TRAC_ROCK_MAX + 1];		  /* 该 tank_rock 是否为跟踪石 */
float g_fRockDamage[TRAC_ROCK_MAX + 1];		  /* 跟踪石累计承受的伤害 */
int	  g_iRockCharge[TRAC_ROCK_MAX + 1];		  /* 掷出该跟踪石时已扣的血量(命中生还者则退还) */
int	  g_iLastTracTarget[MAXPLAYERS + 1];	  /* 该坦克上一发跟踪石命中的生还者(禁止连续命中同一人) */
int	  g_iCtrlSnapMeter[MAXPLAYERS + 1];	  /* 每帧快照: 控制权 m_frustration */
float g_fCtrlSnapTimer[MAXPLAYERS + 1];		  /* 每帧快照: 怒气计时器剩余时间 */
int	  g_iCtrlPreMeter[MAXPLAYERS + 1];		  /* 命中前的 m_frustration 基准 */
float g_fCtrlPreTimer[MAXPLAYERS + 1];		  /* 命中前的怒气计时器基准 */
int	  g_iCtrlWantMeter[MAXPLAYERS + 1];		  /* 补正后要钉住的 m_frustration */
bool  g_bCtrlGotMeter[MAXPLAYERS + 1];		  /* 已检测到引擎改了 m_frustration */
bool  g_bCtrlGotTimer[MAXPLAYERS + 1];		  /* 已检测到引擎改了怒气计时器 */
bool  g_bCtrlWatch[MAXPLAYERS + 1];			  /* 是否处于命中后的观察窗口 */
float g_fCtrlWatchUntil[MAXPLAYERS + 1];	  /* 观察窗口截止 */
float g_fCtrlHoldUntil[MAXPLAYERS + 1];		  /* 钉住截止 */

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
	CreateNative("Apex_GetTracBlockedTarget", Native_GetTracBlockedTarget);
	/* 技能扣血 forward: 把不经由伤害事件的技能扣血/退还告知伤害统计类插件(如 tank_damage) */
	g_hFwdSkillCost = CreateGlobalForward("Apex_OnSkillCostCharged", ET_Ignore, Param_Cell, Param_Cell, Param_Cell);
	g_bLateLoad = late;
	return APLRes_Success;
}

/* 通报技能扣血/退还: cost 为本次血量变化量(扣血为正, 退还为负), 0 不通报 */
void FireSkillCost(int client, ApexSkillCostType type, int cost)
{
	if (g_hFwdSkillCost == null || cost == 0 || !IsValidClient(client))
		return;

	Call_StartForward(g_hFwdSkillCost);
	Call_PushCell(client);
	Call_PushCell(view_as<int>(type));
	Call_PushCell(cost);
	Call_Finish();
}

/* 供 l4d_tracerock.sp 选人使用: 返回该坦克本发跟踪石应排除的生还者(0=无约束) */
public int Native_GetTracBlockedTarget(Handle plugin, int numParams)
{
	int tank = GetNativeCell(1);
	if (tank < 1 || tank > MaxClients)
		return 0;

	return g_iLastTracTarget[tank];
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
	Apex[7] = CreateConVar("l4d_tracerock_ctrl_base", "5.0", "游戏默认: 跟踪石命中生还者时坦克控制权的单次变化量(%). 只用于换算比例, 不会写进游戏");
	Apex[8] = CreateConVar("l4d_tracerock_ctrl_step", "6.0", "期望: 跟踪石命中生还者时坦克控制权的单次变化量(%%). 按 base->step 的比例放大引擎本次改动, 与引擎方向无关. 等于 base 则不调整");
	Apex[9] = CreateConVar("l4d_tracerock_debug", "0", "跟踪石调试日志 0=关闭 1=输出到服务器控制台", _, true, 0.0, true, 1.0);
	Apex[10] = CreateConVar("tank_bhop_detect", "1", "坦克连跳检测: 未开启!bhop技能的坦克成功连跳时补扣技能血量并通报全场 0=禁用 1=启用", _, true, 0.0, true, 1.0);
	Apex[11] = CreateConVar("tank_bhop_detect_count", "10", "连续完美连跳达到该次数即判定为成功连跳(参考liac的min档位).0=禁用", _, true, 0.0);
	Apex[12] = CreateConVar("tank_bhop_detect_air", "0.3", "两次连跳之间的最小滞空时间(秒), 参考liac的air设置(>1.0按1.0算)", _, true, 0.0, true, 1.0);

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
		FireSkillCost(client, ApexSkillCost_TracEnable, mumhp);
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
		FireSkillCost(client, ApexSkillCost_Bhop, mumhp);
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
	CPrintToChat(client, "%s指令{lightgreen}!bhop{darkred}开启自动连跳", TAG);
	CPrintToChat(client, "%s指令{lightgreen}!trac{darkred}开启跟踪石头(开启扣%d血, 未命中扣%d血)", TAG, Apex[4].IntValue, Apex[5].IntValue);
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
	float air = Apex[12].FloatValue;
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

	int need = Apex[11].IntValue;

	/* 检测关闭 / 阈值非法 / 技能本身不扣血: 不判定 */
	if (!Apex[10].BoolValue || need <= 0 || Apex[3].IntValue <= 0)
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

	FireSkillCost(client, ApexSkillCost_BhopDetect, cost);
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
}

/* 掷出跟踪石头扣血: 最多扣到只剩 1 血, 技能不会把坦克扣死. 返回实际扣除的血量(0=没扣) */
int ChargeTracThrow(int client)
{
	int cost = Apex[5].IntValue;
	if (cost <= 0 || !IsTank(client))
		return 0;

	int hp = GetEntProp(client, Prop_Data, "m_iHealth");
	if (hp <= 1)
		return 0;

	if (cost > hp - 1)
		cost = hp - 1;

	SetEntProp(client, Prop_Data, "m_iHealth", hp - cost);

	FireSkillCost(client, ApexSkillCost_TracThrow, cost);

	return cost;
}

/* 跟踪石命中生还者: 退还掷出时扣的血(即"命中则不扣血", 只有未命中才真正扣) */
void RefundTracThrow(int tank, int rock, int victim)
{
	int charge = g_iRockCharge[rock];
	if (charge <= 0)
		return;

	g_iRockCharge[rock] = 0;

	if (!IsTank(tank))
		return;

	int hp	  = GetEntProp(tank, Prop_Data, "m_iHealth");
	int maxhp = GetEntProp(tank, Prop_Data, "m_iMaxHealth");

	int newhp = hp + charge;
	if (maxhp > 0 && newhp > maxhp)
		newhp = maxhp;

	if (newhp != hp)
	{
		SetEntProp(tank, Prop_Data, "m_iHealth", newhp);
		/* 通报退还(负数): 命中则不扣血, 伤害统计侧据此把预扣的血扣回去 */
		FireSkillCost(tank, ApexSkillCost_TracThrow, newhp - hp);
	}

	if (Apex[9].BoolValue)
		PrintToServer("[Apex] 跟踪石命中 %N, 退还掷出扣血 %d (坦克 %d -> %d)", victim, charge, hp, newhp);
}

/* -----------------------------------------------------------
	跟踪石平衡功能: 血量 / 禁止连续命中同一人 / 控制权扣除
	(石头是否为"跟踪石"在此判定: 出石瞬间坦克开着 !trac)
----------------------------------------------------------- */

/* l4d_tracerock.smx 是否加载(未加载则不存在跟踪石, 平衡功能不生效); 懒检查以兼容插件后加载 */
bool HasTracePlugin()
{
	if (!g_bHasTracePlugin)
		g_bHasTracePlugin = LibraryExists("L4D_OnTraceRockCreated");

	return g_bHasTracePlugin;
}

/* 跟踪功能当前是否真的生效(插件已加载 且 l4d_tracerock_enable 开着) */
bool TracFeatureActive()
{
	if (!HasTracePlugin())
		return false;

	ConVar cv = FindConVar("l4d_tracerock_enable");
	return (cv == null) ? true : cv.BoolValue;
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
	g_iRockCharge[rock] = 0;

	int owner = GetEntPropEnt(rock, Prop_Data, "m_hOwnerEntity");

	/* 只有"坦克开着跟踪、且跟踪功能确实生效"时掷出的石头才算跟踪石 */
	if (!TracFeatureActive() || !IsTank(owner) || !IsTrac[owner])
		return;

	g_bTraceRock[rock] = true;

	/* 掷出即扣血, 命中生还者时再退还(见 RefundTracThrow) */
	g_iRockCharge[rock] = ChargeTracThrow(owner);

	/* 跟踪石血量: 交给引擎 40 点血, 同时自行累计伤害兜底(见 OnRockTakeDamage) */
	int health = Apex[6].IntValue;
	if (health > 0)
	{
		SetEntProp(rock, Prop_Data, "m_iHealth", health);
		SetEntProp(rock, Prop_Data, "m_takedamage", 2);	   // DAMAGE_YES: 确保子弹能打到石头(原本已开启则无影响)
		SDKHook(rock, SDKHook_OnTakeDamage, OnRockTakeDamage);
	}
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_OnTakeDamage, OnClientTakeDamage);
}

public void OnClientDisconnect(int client)
{
	SDKUnhook(client, SDKHook_OnTakeDamage, OnClientTakeDamage);

	g_iLastTracTarget[client] = 0;
	g_iCtrlSnapMeter[client]  = 0;
	g_fCtrlSnapTimer[client]  = 0.0;
	g_iCtrlPreMeter[client]	  = 0;
	g_fCtrlPreTimer[client]	  = 0.0;
	g_iCtrlWantMeter[client]  = 0;
	g_bCtrlGotMeter[client]	  = false;
	g_bCtrlGotTimer[client]	  = false;
	g_bCtrlWatch[client]	  = false;
	g_fCtrlWatchUntil[client] = 0.0;
	g_fCtrlHoldUntil[client]  = 0.0;
}

/**
 * 跟踪石命中生还者:
 *  1. 命中则不扣血: 退还掷出时预扣的血量
 *  2. 记下命中目标: 该坦克下一发跟踪石不再选他(禁止连续命中同一人)
 *  3. 控制权: 扣除 ctrl_step% 的坦克控制权(m_frustration)
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

	int tank = GetEntPropEnt(inflictor, Prop_Data, "m_hOwnerEntity");
	if (!IsTank(tank))
		return Plugin_Continue;

	/* 1. 命中生还者 -> 退还掷出时扣的血 */
	RefundTracThrow(tank, inflictor, victim);

	/* 2. 下一发跟踪石不再选中他(选人逻辑在 l4d_tracerock.sp, 通过 Apex_GetTracBlockedTarget 查询) */
	g_iLastTracTarget[tank] = victim;

	/* 3. 控制权: 把本次命中的扣除总量钉在 ctrl_step%(覆盖引擎自己的扣除写入, 见 OnGameFrame) */
	ApplyCtrlLoss(tank);

	return Plugin_Continue;
}

/**
 * 命中后的"控制权"调整（参考 l4d2_tankrage.sp / l4d2_godframes_control_merge.sp）:
 *
 * 坦克控制权由 m_frustration(netprop) 与紧跟其后的 m_frustrationTimer 共同驱动,
 * 命中时引擎会改动其中之一或两者(本服务器观测到的默认量就是 ctrl_base = 5%)。
 * 本插件不写死绝对值, 而是:
 *   1. 命中瞬间记下"命中前"的 m_frustration 与 timer 剩余时间(每帧快照);
 *   2. 之后 CTRL_WATCH_TIME 秒内观察引擎到底改了哪个(引擎可能是延迟落盘的);
 *   3. 谁变了就把谁的改动量按 ctrl_step / ctrl_base 放大(5% -> 6%), 并钉住一小段时间。
 * 这样与引擎方向无关: 引擎扣 5 就变扣 6, 引擎加 5 就变加 6。
 */
void ApplyCtrlLoss(int tank)
{
	if (!CtrlAdjustEnabled())
		return;

	/* 窗口内再次命中: 以上一次的目标值为基准, 保证叠加 */
	if (g_bCtrlWatch[tank])
	{
		g_iCtrlPreMeter[tank] = g_iCtrlWantMeter[tank];
		g_fCtrlPreTimer[tank] = g_fCtrlSnapTimer[tank];
	}
	else
	{
		g_iCtrlPreMeter[tank] = g_iCtrlSnapMeter[tank];
		g_fCtrlPreTimer[tank] = g_fCtrlSnapTimer[tank];
	}

	g_bCtrlGotMeter[tank] = false;
	g_bCtrlGotTimer[tank] = false;
	g_bCtrlWatch[tank]	  = true;
	g_fCtrlWatchUntil[tank] = GetGameTime() + CTRL_WATCH_TIME;
	g_fCtrlHoldUntil[tank]	= 0.0;

	if (Apex[9].BoolValue)
		PrintToServer("[Apex] 跟踪石命中: 观察控制权改动 (基准 m_frustration=%d, timer=%.2fs, 目标 %.1f%%/默认 %.1f%%)",
					  g_iCtrlPreMeter[tank], g_fCtrlPreTimer[tank], Apex[8].FloatValue, Apex[7].FloatValue);
}

bool CtrlAdjustEnabled()
{
	float base = Apex[7].FloatValue;
	float step = Apex[8].FloatValue;

	return (base > 0.0 && step > 0.0 && step != base);
}

/* 每帧: 给坦克记录快照; 命中后的观察窗口内检测引擎改动并等比放大 */
public void OnGameFrame()
{
	float now = GetGameTime();

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsTank(i))
			continue;

		int	  curMeter = GetEntProp(i, Prop_Send, "m_frustration");
		float curTimer = FrustrationTimerRemaining(i);

		if (g_bCtrlWatch[i])
		{
			float ratio = (Apex[8].FloatValue / Apex[7].FloatValue) - 1.0;	  /* 需要额外补的比例(5->6 即 +20%) */

			/* 引擎改了 m_frustration: 按比例多补一段 */
			if (!g_bCtrlGotMeter[i] && curMeter != g_iCtrlPreMeter[i])
			{
				int delta = curMeter - g_iCtrlPreMeter[i];
				int extra = RoundToNearest(float(delta) * ratio);
				if (extra == 0)
					extra = (delta > 0) ? 1 : -1;

				int want = curMeter + extra;
				if (want > 100)
					want = 100;
				if (want < 0)
					want = 0;

				g_iCtrlWantMeter[i]	 = want;
				g_bCtrlGotMeter[i]	 = true;
				g_fCtrlHoldUntil[i]	 = now + CTRL_HOLD_TIME;

				if (Apex[9].BoolValue)
					PrintToServer("[Apex] 跟踪石控制权: 引擎 %d -> %d (改动 %d), 补到 %d", g_iCtrlPreMeter[i], curMeter, delta, want);
			}

			/* 引擎改了怒气计时器: 同样按比例补时间(l4d2_tankrage 同款写法) */
			if (!g_bCtrlGotTimer[i] && FloatAbs(curTimer - g_fCtrlPreTimer[i]) > 0.01)
			{
				float delta = curTimer - g_fCtrlPreTimer[i];
				float want	= g_fCtrlPreTimer[i] + delta * (1.0 + ratio);

				if (want < 0.0)
					want = 0.0;

				CTimer_Start(GetFrustrationTimer(i), want);
				g_bCtrlGotTimer[i] = true;

				if (Apex[9].BoolValue)
					PrintToServer("[Apex] 跟踪石怒气计时器: 引擎 %.2fs -> %.2fs (改动 %.2fs), 补到 %.2fs", g_fCtrlPreTimer[i], curTimer, delta, want);
			}

			/* 钉住 m_frustration 目标值, 防止引擎/其它插件随后又改回去 */
			if (g_bCtrlGotMeter[i] && g_fCtrlHoldUntil[i] > now && curMeter != g_iCtrlWantMeter[i])
			{
				SetEntProp(i, Prop_Send, "m_frustration", g_iCtrlWantMeter[i]);

				if (Apex[9].BoolValue)
					PrintToServer("[Apex] 跟踪石控制权被改写为 %d, 已压回 %d (坦克 %N)", curMeter, g_iCtrlWantMeter[i], i);
			}

			/* 观察窗口结束 */
			if (now > g_fCtrlWatchUntil[i] && now > g_fCtrlHoldUntil[i])
			{
				g_bCtrlWatch[i] = false;

				if (Apex[9].BoolValue && !g_bCtrlGotMeter[i] && !g_bCtrlGotTimer[i])
					PrintToServer("[Apex] 跟踪石控制权: %.1f 秒内未检测到引擎改动(m_frustration 仍为 %d) —— 该服务器的控制权可能不由这两个字段驱动",
								  CTRL_WATCH_TIME, curMeter);
			}

			continue;
		}

		g_iCtrlSnapMeter[i] = curMeter;
		g_fCtrlSnapTimer[i] = curTimer;
	}
}

/* 怒气计时器剩余时间(参考 l4d2_tankrage.sp: m_frustration 偏移 +4) */
float FrustrationTimerRemaining(int client)
{
	float remain = CTimer_GetRemainingTime(GetFrustrationTimer(client));
	return (remain > 0.0) ? remain : 0.0;
}

CountdownTimer GetFrustrationTimer(int client)
{
	static int s_iOffs = -1;
	if (s_iOffs == -1)
		s_iOffs = FindSendPropInfo("CTerrorPlayer", "m_frustration") + 4;

	return view_as<CountdownTimer>(GetEntityAddress(client) + view_as<Address>(s_iOffs));
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

	if (Apex[9].BoolValue)
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
	g_iRockCharge[rock] = 0;

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
		g_iRockCharge[rock] = 0;
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

	/* 新一条命/新回合不继承跟踪石的连续命中约束与控制权观察状态 */
	g_iLastTracTarget[client] = 0;
	g_iCtrlSnapMeter[client]  = 0;
	g_fCtrlSnapTimer[client]  = 0.0;
	g_iCtrlPreMeter[client]	  = 0;
	g_fCtrlPreTimer[client]	  = 0.0;
	g_iCtrlWantMeter[client]  = 0;
	g_bCtrlGotMeter[client]	  = false;
	g_bCtrlGotTimer[client]	  = false;
	g_bCtrlWatch[client]	  = false;
	g_fCtrlWatchUntil[client] = 0.0;
	g_fCtrlHoldUntil[client]  = 0.0;
}