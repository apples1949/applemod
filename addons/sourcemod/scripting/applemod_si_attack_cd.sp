#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <l4d2util_infected>

#define PLUGIN_VERSION "1.5.0"

#define ZC_SMOKER   1
#define ZC_BOOMER   2
#define ZC_SPITTER  4
#define ZC_JOCKEY   5
#define ZC_CHARGER  6

// 1.5.0：同类特感(仅 Boomer / Spitter)第二只起使用技能时，额外延长技能CD。
// 引擎在 ability_use 事件之后才写 m_nextActivationTimer（spitter 实测约 1.2s），
// 所以这里用一条短周期重复 timer 轮询，直到读到 CD 再追加，最多重试 PAIR_RETRY_MAX 次。
#define PAIR_RETRY_INTERVAL 0.25
#define PAIR_RETRY_MAX      12   // 0.25s * 12 = 3.0s

ConVar g_cvEnable;
ConVar g_cvAttackReduce;

// 1.5.0：双 Boomer / 双 Spitter 的额外 CD
ConVar g_cvPairEnable;   // 总开关（只影响本功能，不影响爪击减CD）
ConVar g_cvPairPenalty;  // 额外增加的比例（0.5 = 在原有CD上再加一半）
ConVar g_cvPairNotify;   // 是否给被加CD的特感玩家发聊天提示

bool g_bUsedAbility[MAXPLAYERS + 1];   // 本命是否已经用过技能（死亡/重生/换图时清空）
bool g_bPairPending[MAXPLAYERS + 1];   // 是否已有一条等待写入的加CD timer
int  g_iPairRetry[MAXPLAYERS + 1];     // 该 timer 已重试次数

public Plugin myinfo =
{
	name = "AppleMod SI Attack CD Boost",
	author = "apples1949",
	description = "Charger/Jockey/Smoker/Spitter/Boomer 爪击命中生还者时, 特感技能CD加快恢复一秒; 1.5.0 追加: 双 Boomer/双 Spitter 中从第二只起使用技能时技能CD额外+50%",
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

	// 1.5.0：同类特感(仅 Boomer / Spitter)从第二只开始加CD
	g_cvPairEnable  = CreateConVar("sm_sicd_pair_enable", "1",
		"1=启用「同类特感从第二只开始加技能CD」规则（只作用于 Boomer / Spitter）, 0=关闭");
	g_cvPairPenalty = CreateConVar("sm_sicd_pair_penalty", "0.5",
		"第二只同类特感使用技能时, 在原有技能CD上额外增加的比例 (0.5 = 再加一半, 0=不加)",
		_, true, 0.0, true, 3.0);
	g_cvPairNotify  = CreateConVar("sm_sicd_pair_notify", "0",
		"被额外加CD的特感玩家是否收到聊天提示. 0=静默(默认), 1=提示");

	HookEvent("ability_use", Event_AbilityUse, EventHookMode_Post);
	HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);
	HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);

	RegAdminCmd("sm_sicd_status", Cmd_Status, ADMFLAG_GENERIC,
		"打印特感CD加成插件状态: 开关/参数/每只特感的「本命是否用过技能」与当前技能CD剩余");

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

public void OnMapStart()
{
	for (int i = 0; i <= MaxClients; i++)
		ResetAbilityUsed(i);
}

public void OnClientPutInServer(int client)
{
	ResetAbilityUsed(client);
	SDKHook(client, SDKHook_OnTakeDamage, Hook_OnTakeDamage);
}

public void OnClientDisconnect(int client)
{
	ResetAbilityUsed(client);
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
				// m_isCharging 在能力实体(ability_charge)上, 不在玩家身上
				int ability = GetEntPropEnt(attacker, Prop_Send, "m_customAbility");
				if (ability > 0 && IsValidEdict(ability) && GetEntProp(ability, Prop_Send, "m_isCharging"))
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

// ============================================================================
// 1.5.0：双 Boomer / 双 Spitter —— 从第二只开始, 使用技能时技能CD额外 +50%
//
// 规则（用户需求）：
//   场上同时存活两只同类特感（12v12 里 Boomer / Spitter 上限都是 2）时，
//   第一只使用过技能且"没死"的前提下，第二只也使用技能（也没死），
//   那么第二只的技能CD 在原CD上额外增加一半（默认 +50%）。
//   只作用于 Boomer / Spitter，其它特感不参与。
//
// 实现：
//   - ability_use 事件（Post）：记下"这只本命已经用过技能"，并统计是否有
//     另一只同类、仍存活、也已用过技能的特感；有 -> 给这次使用加CD。
//   - 引擎在 ability_use 之后才写 m_nextActivationTimer，所以用 0.25s 的重复
//     timer 轮询，一旦读到"正在CD"就追加，读到就停；最多轮询 3 秒。
//   - 死亡 / 重生(player_spawn) / 断线 / 换图 / 回合开始 都会清掉"用过技能"标记，
//     与"第一个使用过技能没死亡"的语义一致：第一只死了就不再给第二只加CD。
// ============================================================================

public void Event_AbilityUse(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnable.BoolValue || !g_cvPairEnable.BoolValue)
		return;

	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client < 1 || client > MaxClients || !IsClientInGame(client) || !IsPlayerAlive(client))
		return;
	if (GetClientTeam(client) != 3)
		return;

	int zclass = GetEntProp(client, Prop_Send, "m_zombieClass");
	if (zclass != ZC_BOOMER && zclass != ZC_SPITTER)
		return;

	// 先判定"是否有同类先用过技能且还活着"，再记录自己也用过了
	bool bPaired = HasUsedSameClassRival(client, zclass);
	g_bUsedAbility[client] = true;

	if (!bPaired)
		return;

	// 已经有一条等待写入的 timer 就不用再开一条
	if (g_bPairPending[client])
		return;

	g_bPairPending[client] = true;
	g_iPairRetry[client] = 0;

	CreateTimer(PAIR_RETRY_INTERVAL, Timer_ApplyPairPenalty, GetClientUserId(client),
		TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_ApplyPairPenalty(Handle timer, any iUserId)
{
	int client = GetClientOfUserId(iUserId);

	// 死了 / 断线 / 被换类 / 标记被清（重生或回合重置）都直接放弃
	if (client < 1 || client > MaxClients || !IsClientInGame(client) || !IsPlayerAlive(client))
		return Plugin_Stop;

	if (!g_bUsedAbility[client])
	{
		g_bPairPending[client] = false;
		return Plugin_Stop;
	}

	int zclass = GetEntProp(client, Prop_Send, "m_zombieClass");
	if (zclass != ZC_BOOMER && zclass != ZC_SPITTER)
	{
		g_bPairPending[client] = false;
		return Plugin_Stop;
	}

	if (ApplyPairPenalty(client, zclass))
	{
		g_bPairPending[client] = false;
		return Plugin_Stop;
	}

	if (++g_iPairRetry[client] >= PAIR_RETRY_MAX)
	{
		// 3 秒内一直读不到"正在CD"（例如这只特感其实没有CD），放弃，不刷日志
		g_bPairPending[client] = false;
		return Plugin_Stop;
	}

	return Plugin_Continue;
}

// 是否有"同类、存活、本命已用过技能"的另一只特感
bool HasUsedSameClassRival(int client, int zclass)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (i == client)
			continue;
		if (!IsClientInGame(i) || !IsPlayerAlive(i))
			continue;
		if (GetClientTeam(i) != 3)
			continue;
		if (!g_bUsedAbility[i])
			continue;
		if (GetEntProp(i, Prop_Send, "m_zombieClass") != zclass)
			continue;

		return true;
	}

	return false;
}

// 把引擎技能CD延长 penalty 比例。返回 true = 已经写入成功。
// 读不到计时器 / 当前不在CD 都返回 false，交给外层 timer 继续轮询。
bool ApplyPairPenalty(int client, int zclass)
{
	float fExtra = g_cvPairPenalty.FloatValue;
	if (fExtra <= 0.0)
		return false;

	float fNow = GetGameTime();
	float fTimestamp, fDuration;

	if (!GetInfectedAbilityTimer(client, fTimestamp, fDuration))
		return false;
	if (fTimestamp <= fNow || fDuration <= 0.0)
		return false;

	// 防护：duration 明显异常时不追加（防止把 bug 状态下的 3600 秒"冻结CD"再放大一半）
	if (fDuration > 120.0)
		return false;

	float fAdd = fDuration * fExtra;

	fTimestamp += fAdd;
	fDuration  += fAdd;

	if (!SetInfectedAbilityTimer(client, fTimestamp, fDuration))
		return false;

	if (g_cvPairNotify.BoolValue)
	{
		char sClass[8];
		strcopy(sClass, sizeof(sClass), (zclass == ZC_BOOMER) ? "Boomer" : "Spitter");
		PrintToChat(client, "\x04[特感CD]\x01 场上已有另一只存活的 %s 用过技能, 你的技能冷却额外增加 %.0f%%（+%.1f 秒）.",
			sClass, fExtra * 100.0, fAdd);
	}

	return true;
}

void ResetAbilityUsed(int client)
{
	if (client < 0 || client > MaxClients)
		return;

	g_bUsedAbility[client] = false;
	g_bPairPending[client] = false;
	g_iPairRetry[client] = 0;
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	ResetAbilityUsed(GetClientOfUserId(event.GetInt("userid")));
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	ResetAbilityUsed(GetClientOfUserId(event.GetInt("userid")));
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	for (int i = 0; i <= MaxClients; i++)
		ResetAbilityUsed(i);
}

// ============================================================================
// 排查命令：打印每只特感的本命用技能状态与当前技能CD剩余秒数
// ============================================================================
public Action Cmd_Status(int client, int args)
{
	ReplyToCommand(client, "\x04[SICD]\x01 版本 %s | 总开关=%d 爪击减CD=%.1fs | 同类加CD=%d 比例=+%.0f%% 提示=%d",
		PLUGIN_VERSION,
		g_cvEnable.IntValue,
		g_cvAttackReduce.FloatValue,
		g_cvPairEnable.IntValue,
		g_cvPairPenalty.FloatValue * 100.0,
		g_cvPairNotify.IntValue);

	float fNow = GetGameTime();

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != 3)
			continue;

		int zclass = GetEntProp(i, Prop_Send, "m_zombieClass");
		if (zclass != ZC_BOOMER && zclass != ZC_SPITTER)
			continue;

		float fTimestamp = 0.0, fDuration = 0.0;
		bool bOk = GetInfectedAbilityTimer(i, fTimestamp, fDuration);
		float fLeft = bOk ? (fTimestamp - fNow) : 0.0;
		if (fLeft < 0.0)
			fLeft = 0.0;

		ReplyToCommand(client,
			"\x04[SICD]\x01 #%d class=%s alive=%d used=%d pending=%d | 技能CD剩余=%.1fs (duration=%.1fs) | 同类已用存活=%d",
			i,
			(zclass == ZC_BOOMER) ? "Boomer" : "Spitter",
			IsPlayerAlive(i) ? 1 : 0,
			g_bUsedAbility[i] ? 1 : 0,
			g_bPairPending[i] ? 1 : 0,
			fLeft,
			fDuration,
			HasUsedSameClassRival(i, zclass) ? 1 : 0);
	}

	return Plugin_Handled;
}
