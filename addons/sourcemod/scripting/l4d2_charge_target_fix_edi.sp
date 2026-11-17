#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <dhooks>
#include <left4dhooks>

/*
 * ============================================================================
 *  本文件是 l4d2_charge_target_fix.smx 的 _edi 修复版(编译产物 fixes/l4d2_charge_target_fix_edi.smx),
 *  原版逻辑来自 Forgetest / SirPlease L4D2-Competitive-Rework 的 [L4D2] Charger Target Fix v1.11.
 *
 *  ---------------------------- 要修的那条报错 ----------------------------
 *  L 11/17/2026 - 17:33:48: SourceMod error session started
 *  L 11/17/2026 - 17:33:48: Info (map "c11m1_greenhouse") (file ".../errors_20261117.log")
 *  L 11/17/2026 - 17:33:48: [SM] Exception reported: Entity -1 (4) is invalid
 *  L 11/17/2026 - 17:33:48: [SM] Blaming: fixes/l4d2_charge_target_fix.smx
 *  L 11/17/2026 - 17:33:48: [SM] Call stack trace:
 *  L 11/17/2026 - 17:33:48: [SM]   [0] GetEntDataFloat
 *  L 11/17/2026 - 17:33:48: [SM]   [1] Line 842, include\left4dhooks_silver.inc::L4D2_GetQueuedPummelStartTime
 *  L 11/17/2026 - 17:33:48: [SM]   [2] Line 869, include\left4dhooks_silver.inc::L4D2_IsInQueuedPummel
 *  L 11/17/2026 - 17:33:48: [SM]   [3] Line 220, l4d2_charge_target_fix.sp::Event_PlayerDeath
 *
 *  ---------------------------- 根因分析 ----------------------------
 *  调用栈最后落在 Event_PlayerDeath 的:
 *      int attacker = g_iChargeAttacker[client];
 *      if (L4D2_IsInQueuedPummel(attacker) && L4D2_GetQueuedPummelVictim(attacker) == client)
 *  这里的 attacker 是「当初撞倒/扛起这个生还者的 Charger 的客户端索引」, 存在本插件自己的
 *  g_iChargeAttacker[] 里。它只是一个数, 没有任何"仍然有效"的保证:
 *    · Charger 在扛着人时断线/被踢 —— 引擎不会补发 charger_carry_end / charger_pummel_end,
 *      本插件也没有 OnClientDisconnect 清理, 这条记录就一直留着;
 *    · 该索引随后被引擎复用给另一个玩家, 或者干脆空着;
 *    · 生还者这一条命结束时, 上面那句就直接拿这个索引去读 CTerrorPlayer 的内存。
 *
 *  L4D2_GetQueuedPummelStartTime() 是 left4dhooks_silver.inc 里的 stock, 内部是裸的
 *  GetEntDataFloat(charger, ...). SourceMod 侧(1.12 core/smn_entities.cpp GetEntity →
 *  IndexToAThings → CHalfLife2::ReferenceToEntity)对「玩家索引」还会额外要求 pPlayer->IsConnected(),
 *  所以传一个已经走人/空槽的索引进去必然抛 "Entity -1 (N) is invalid"(N 就是那个索引, -1 是
 *  ReferenceToIndex 解析失败后的返回值).
 *
 *  这一次日志里 N = 4: 4 号客户端当时的实体已经无效, 但 g_iChargeAttacker[死者] 仍然指着它。
 *
 *  ---------------------------- 修复做法 ----------------------------
 *  1) 新增 IsValidGameClient(): 先确认索引在 1..MaxClients 且 IsClientInGame, 再去碰任何
 *     "按客户端索引读实体内存"的 native/stock (L4D2_IsInQueuedPummel / L4D2_GetQueuedPummel* /
 *     GetEntPropEnt / SetEntProp* / KnockdownPlayer …)。
 *  2) Event_PlayerDeath: attacker 无效时不再走 queued pummel 分支, 但「恢复碰撞 + 清状态」照做
 *     —— 原版一抛异常整段函数就中断了, 死在 Charger 手里的生还者会永久保持 FSOLID_NOT_SOLID。
 *     同时 GetEntPropEnt(attacker,"m_customAbility") 也可能返回 -1, 一并加 IsValidEntity 校验
 *     (原来 -1 也会抛同一条 "Entity ... is invalid")。
 *  3) 新增 OnClientDisconnect: 把「以这个人为 attacker / victim」的数组项一起清掉, 从根上避免
 *     索引被复用时读到别人的数据、或永远挡着 L4D_OnPouncedOnSurvivor / L4D2_OnJockeyRide /
 *     L4D_OnGrabWithTongue 这三条"正在被 Charger 控制, 不许别人抢"的拦截。
 *  4) 其余同类隐患一并加固(都是同一类"缓存索引 + 没有有效性校验"):
 *     Event_PlayerIncap / Event_ChargerKilled / HandlePlayerReplace / Timer_KnockdownRepeat /
 *     SuppressAttacks / ExtendKnockdown / L4D2_OnStartCarryingVictim_Post / L4D2_OnSlammedSurvivor_Post。
 *     HandlePlayerReplace 里原来的 `if (!replacee) replacee = -1;` 之后还会用 -1 去索引数组
 *     (g_iChargeVictim[-1])并调用 L4D2_IsInQueuedPummel(-1) —— 也是同一条报错的另一个来源, 现在
 *     直接返回, 不做任何"没有对象的迁移"。
 *
 *  行为不变的部分: 撞倒/扛人/queued pummel 的计时改写、被撞瞬间的武器压制(1.11 的
 *  SuppressAttacks)、碰撞开关 cvar、get-up 延长逻辑全部照原样; 只是每个入口都先验一遍索引。
 * ============================================================================
 */

#define PLUGIN_VERSION "1.11-edi"

public Plugin myinfo = 
{
	name = "[L4D2] Charger Target Fix (edi)",
	author = "apples1949",
	description = "Fix multiple issues with charger targets. edi(原版 Forgetest): 所有按客户端索引读实体内存的调用都先校验索引, 修复 player_death 里 'Entity -1 (N) is invalid' (见文件头).",
	version = PLUGIN_VERSION,
	url = "https://github.com/SirPlease/L4D2-Competitive-Rework"
};

#define GAMEDATA_FILE "l4d2_charge_target_fix"
#define FUNCTION_NAME "CCharge::HandleCustomCollision"

#define KEY_ANIMSTATE "CTerrorPlayer::m_PlayerAnimState"
#define KEY_FLAG_CHARGED "CTerrorPlayerAnimState::m_bCharged"

int
	m_PlayerAnimState,
	m_bCharged;

enum AnimStateFlag // mid-way start from m_bCharged
{
	AnimState_WallSlammed		= 2,
	AnimState_GroundSlammed		= 3,
}

methodmap AnimState
{
	public AnimState(int client) {
		int ptr = GetEntData(client, m_PlayerAnimState, 4);
		if (ptr == 0)
			ThrowError("Invalid pointer to \"CTerrorPlayer::CTerrorPlayerAnimState\" (client %d).", client);
		return view_as<AnimState>(ptr);
	}
	public bool GetFlag(AnimStateFlag flag) {
		return view_as<bool>(LoadFromAddress(view_as<Address>(this) + view_as<Address>(m_bCharged) + view_as<Address>(flag), NumberType_Int8));
	}
}

#define FSOLID_NOT_SOLID 0x0004 // Are we currently not solid?
#define KNOCKDOWN_DURATION_CHARGER 2.5
#define SLAM_ATTACK_HOLD 0.2
#define SLAM_PUMMEL_MARGIN 0.1

int 
	g_iChargeVictim[MAXPLAYERS+1] = {-1, ...},
	g_iChargeAttacker[MAXPLAYERS+1] = {-1, ...};

bool g_bNotSolid[MAXPLAYERS+1];
float g_flSuppressUntil[MAXPLAYERS+1];

enum
{
	CHARGER_COLLISION_PUMMEL = 1,
	CHARGER_COLLISION_GETUP = (1 << 1)
};
int g_iChargerCollision;
float g_flKnockdownWindow;

public void OnPluginStart()
{
	GameData gd = new GameData(GAMEDATA_FILE);
	if (!gd)
		SetFailState("Missing gamedata \""...GAMEDATA_FILE..."\"");
	
	m_PlayerAnimState = GameConfGetOffset(gd, KEY_ANIMSTATE);
	if (m_PlayerAnimState == -1)
		SetFailState("Missing offset \""...KEY_ANIMSTATE..."\"");
	
	m_bCharged = GameConfGetOffset(gd, KEY_FLAG_CHARGED);
	if (m_bCharged == -1)
		SetFailState("Missing offset \""...KEY_FLAG_CHARGED..."\"");
	
	DynamicDetour hDetour = DynamicDetour.FromConf(gd, FUNCTION_NAME);
	if (!hDetour)
		SetFailState("Missing detour setup \""...FUNCTION_NAME..."\"");
	if (!hDetour.Enable(Hook_Pre, DTR_CCharge__HandleCustomCollision))
		SetFailState("Failed to detour \""...FUNCTION_NAME..."\"");
	
	delete hDetour;
	delete gd;
	
	CreateConVarHook("z_charge_pinned_collision",
				"3",
				"Enable collision to Infected Team on Survivors pinned by charger.\n"
			...	"1 = Enable collision during pummel, 2 = Enable collision during get-up, 3 = Both, 0 = No collision at all.",
				FCVAR_SPONLY,
				true, 0.0, true, 3.0,
				CvarChg_ChargerCollision);
	
	CreateConVarHook("charger_knockdown_getup_window",
				"0.1",
				"Duration between knockdown timer ends and get-up finishes.\n"
			...	"The higher value is set, the earlier Survivors become collideable when getting up from charger.",
				FCVAR_SPONLY,
				true, 0.0, true, 4.0,
				CvarChg_KnockdownWindow);
	
	HookEvent("round_start", Event_RoundStart);
	HookEvent("player_incapacitated", Event_PlayerIncap);
	HookEvent("player_death", Event_PlayerDeath);
	HookEvent("charger_carry_start", Event_ChargerCarryStart);
	HookEvent("charger_carry_end", Event_ChargerCarryEnd);
	HookEvent("charger_pummel_end", Event_ChargerPummelEnd);
	HookEvent("charger_killed", Event_ChargerKilled);
	HookEvent("player_bot_replace", Event_PlayerBotReplace);
	HookEvent("bot_player_replace", Event_BotPlayerReplace);
}

// ============================================================================
//  edi: 索引有效性校验
// ----------------------------------------------------------------------------
//  本插件所有"按客户端索引读实体内存"的调用(L4D2_IsInQueuedPummel /
//  L4D2_GetQueuedPummelStartTime / L4D2_GetQueuedPummelVictim / GetEntPropEnt /
//  SetEntProp* / KnockdownPlayer)都必须先过这一关。
//  原版失败的根因: g_iChargeAttacker/client 里存的是「事件当时的客户端索引」, 而 SourceMod 侧
//  (smn_entities.cpp GetEntity → IndexToAThings → CHalfLife2::ReferenceToEntity)对玩家索引还会额外
//  要求 pPlayer->IsConnected(); 索引对应的玩家已经断线/空槽时, 直接读就抛
//  "Entity -1 (N) is invalid" —— 11/17 那条报错就是这么来的(N=4)。
//  注意 IsClientInGame 在 SM 1.12 里对"索引合法但未连接"返回 false, 所以先判范围再判它。
// ============================================================================
stock bool IsValidGameClient(int client)
{
	return client > 0 && client <= MaxClients && IsClientInGame(client);
}

// Fix charger grabbing victims of other chargers
MRESReturn DTR_CCharge__HandleCustomCollision(int ability, DHookReturn hReturn, DHookParam hParams)
{
	// edi: 被 Detour 的回调里也可能拿到已销毁的能力实体, 先验一遍再读属性.
	if (ability <= 0 || !IsValidEntity(ability))
		return MRES_Ignored;

	if (!GetEntProp(ability, Prop_Send, "m_hasBeenUsed"))
		return MRES_Ignored;
	
	int charger = GetEntPropEnt(ability, Prop_Send, "m_owner");
	if (charger == -1)
		return MRES_Ignored;
	
	int touch = hParams.Get(1);
	if (!touch || touch > MaxClients)
		return MRES_Ignored;
	
	if (g_iChargeAttacker[touch] == -1) // free for attacks
		return MRES_Ignored;
	
	if (g_iChargeAttacker[touch] == charger) // about to slam my victim
		return MRES_Ignored;
	
	// basically invalid calls at here, block
	hReturn.Value = 0;
	return MRES_Supercede;
}

void CvarChg_ChargerCollision(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_iChargerCollision = convar.IntValue;
}

void CvarChg_KnockdownWindow(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_flKnockdownWindow = convar.FloatValue;
}

// Fix anomaly pummel that usually happens when a Charger is carrying someone and round restarts
void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	for (int i = 1; i <= MaxClients; ++i)
	{
		// clear our stuff
		g_bNotSolid[i] = false;
		g_iChargeVictim[i] = -1;
		g_iChargeAttacker[i] = -1;
		
		if (IsClientInGame(i))
		{
			// ~ CDirector::RestartScenario()
			// ~ CDirector::Restart()
			// ~ ForEachTerrorPlayer<RestartCleanup>()
			// ~ CTerrorPlayer::CleanupPlayerState()
			// ~ CTerrorPlayer::OnCarryEnded( (bClearBoth = true), (bSkipPummel = false), (bIsAttacker = true) )
			// ~ CTerrorPlayer::QueuePummelVictim( m_carryVictim.Get(), -1.0 )
			// CTerrorPlayer::UpdatePound()
			SetEntPropEnt(i, Prop_Send, "m_pummelVictim", -1);
			SetEntPropEnt(i, Prop_Send, "m_pummelAttacker", -1);
			
			// perhaps unnecessary
			L4D2_SetQueuedPummelStartTime(i, -1.0);
			L4D2_SetQueuedPummelVictim(i, -1);
			L4D2_SetQueuedPummelAttacker(i, -1);
		}
	}
}

// Remove collision on Survivor going incapped because `CTerrorPlayer::IsGettingUp` returns false in this case
// Thanks to @Alan on discord for reporting.
void Event_PlayerIncap(Event event, const char[] name, bool dontBroadcast)
{
	if (g_iChargerCollision & CHARGER_COLLISION_PUMMEL)
		return;
	
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!client || !IsClientInGame(client))
		return;
	
	if (GetClientTeam(client) != 2)
		return;
	
	int queuedPummelAttacker = L4D2_GetQueuedPummelAttacker(client);
	// edi: queuedPummelAttacker 只是 netprop 里的一个索引, 可能指向已断线的玩家 ——
	// 拿它去 L4D2_IsInQueuedPummel() 会抛 "Entity -1 (N) is invalid", 所以先校验.
	if (!IsValidGameClient(queuedPummelAttacker) || !L4D2_IsInQueuedPummel(queuedPummelAttacker))
	{
		if (GetEntPropEnt(client, Prop_Send, "m_pummelAttacker") == -1)
			return;
	}
	
	SetPlayerSolid(client, false);
	g_bNotSolid[client] = true;
}

// Clear arrays if the victim dies to slams
void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!client || !IsClientInGame(client))
		return;
	
	int attacker = g_iChargeAttacker[client];
	if (attacker == -1)
		return;
	
	// edi(本次报错的现场): attacker 只是缓存的客户端索引, Charger 中途断线/被踢时没有任何事件会清掉它,
	// 索引还可能被引擎复用。原版直接 L4D2_IsInQueuedPummel(attacker) —— 该 stock 内部是裸的
	// GetEntDataFloat(attacker, ...), 玩家已不连接就会抛:
	//     [SM] Exception reported: Entity -1 (4) is invalid
	//     [0] GetEntDataFloat  [1] L4D2_GetQueuedPummelStartTime
	//     [2] L4D2_IsInQueuedPummel  [3] Event_PlayerDeath
	// 异常会把整段函数打断, 下面"恢复 m_usSolidFlags + 清数组"都跑不到, 死者会一直挂在 FSOLID_NOT_SOLID。
	if (IsValidGameClient(attacker) && L4D2_IsInQueuedPummel(attacker) && L4D2_GetQueuedPummelVictim(attacker) == client)
	{
		// edi: m_customAbility 也可能已是 -1(能力实体随 Charger 一起销毁), SetEntPropFloat(-1) 会抛同一条错。
		int ability = GetEntPropEnt(attacker, Prop_Send, "m_customAbility");
		if (ability > 0 && IsValidEntity(ability))
		{
			SetEntPropFloat(ability, Prop_Send, "m_nextActivationTimer", 0.2, 0);
			SetEntPropFloat(ability, Prop_Send, "m_nextActivationTimer", L4D2_GetQueuedPummelStartTime(attacker) + 0.2, 1);
		}
	}
	
	if (g_bNotSolid[client])
	{
		SetPlayerSolid(client, true);
		g_bNotSolid[client] = false;
	}
	
	// edi: 只清「确实指向本死者」的那条反向记录, 不要把 attacker 名下别的受害者也抹掉(原版是无条件 -1)。
	if (attacker > 0 && attacker <= MaxClients && g_iChargeVictim[attacker] == client)
		g_iChargeVictim[attacker] = -1;

	g_iChargeAttacker[client] = -1;
}

void Event_ChargerCarryStart(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("victim"));
	if (!victim || !IsClientInGame(victim))
		return;
	
	int attacker = GetClientOfUserId(event.GetInt("userid"));
	if (!attacker || !IsClientInGame(attacker))
		return;
	
	SetEntPropFloat(victim, Prop_Send, "m_jumpSupressedUntil", GetGameTime() + 0.5);
}

void Event_ChargerCarryEnd(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("victim"));
	if (!victim || !IsClientInGame(victim))
		return;
	
	int attacker = GetClientOfUserId(event.GetInt("userid"));
	if (!attacker || !IsClientInGame(attacker))
		return;
	
	SetEntPropFloat(victim, Prop_Send, "m_jumpSupressedUntil", GetGameTime() + 0.3);
}

// Calls if charger has started pummelling.
void Event_ChargerPummelEnd(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!client)
		return;
	
	int victimId = event.GetInt("victim");
	int victim = GetClientOfUserId(victimId);
	if (!victim || !IsClientInGame(victim))
		return;
	
	if (~g_iChargerCollision & CHARGER_COLLISION_GETUP)
	{
		KnockdownPlayer(victim, KNOCKDOWN_CHARGER);
		ExtendKnockdown(victim, false);
	}
	
	if (g_bNotSolid[victim])
	{
		SetPlayerSolid(victim, true);
		g_bNotSolid[victim] = false;
	}
	
	// Normal processes don't need special care
	g_iChargeVictim[client] = -1;
	g_iChargeAttacker[victim] = -1;
}

// Calls if charger has slammed and before pummel, or simply is cleared before slam. 
void Event_ChargerKilled(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!client || !IsClientInGame(client))
		return;
	
	int victim = g_iChargeVictim[client];
	if (victim == -1)
		return;

	// edi: victim 同样是缓存的索引(生还者可能已断线), 后面 KnockdownPlayer / SetPlayerSolid 都按索引写内存。
	// 无效时只清自己的记录, 不去碰任何人。
	if (!IsValidGameClient(victim))
	{
		g_iChargeVictim[client] = -1;
		return;
	}
	
	if (~g_iChargerCollision & CHARGER_COLLISION_GETUP)
	{
		KnockdownPlayer(victim, KNOCKDOWN_CHARGER);
		
		// a small delay to be compatible with `l4d2_getup_fixes`
		RequestFrame(OnNextFrame_LongChargeKnockdown, GetClientUserId(victim));
	}
	
	if (g_bNotSolid[victim])
	{
		SetPlayerSolid(victim, true);
		g_bNotSolid[victim] = false;
	}
	
	g_iChargeVictim[client] = -1;
	g_iChargeAttacker[victim] = -1;
}

void OnNextFrame_LongChargeKnockdown(int userid)
{
	int client = GetClientOfUserId(userid);
	if (!client || !IsClientInGame(client))
		return;
	
	ExtendKnockdown(client, true);
}

void ExtendKnockdown(int client, bool isLongCharge)
{
	// edi: AnimState(client) 内部是 GetEntData(client, m_PlayerAnimState) —— 按客户端索引读实体内存,
	// 索引无效同样抛 "Entity ... is invalid"(而且它自己还会 ThrowError)。入口先验一遍。
	if (!IsValidGameClient(client))
		return;

	float flExtendTime = 0.0;
	
	if (!isLongCharge)
	{
		float flAnimTime = 85 / 30.0;
		flExtendTime = flAnimTime - KNOCKDOWN_DURATION_CHARGER - g_flKnockdownWindow;
	}
	else
	{
		AnimState pAnim = AnimState(client);
		
		float flAnimTime = 0.0;
		if (((flAnimTime = 116 / 30.0), !pAnim.GetFlag(AnimState_WallSlammed))
		  && ((flAnimTime = 119 / 30.0), !pAnim.GetFlag(AnimState_GroundSlammed)))
		{
			ExtendKnockdown(client, false);
			return;
		}
		
		float flElaspedAnimTime = flAnimTime * GetEntPropFloat(client, Prop_Send, "m_flCycle");
		flExtendTime = flAnimTime - flElaspedAnimTime - KNOCKDOWN_DURATION_CHARGER - g_flKnockdownWindow;
	}
	
	if (flExtendTime >= 0.1)
		CreateTimer(flExtendTime, Timer_ExtendKnockdown, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_ExtendKnockdown(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (!client || !IsClientInGame(client))
		return Plugin_Stop;
	
	KnockdownPlayer(client, KNOCKDOWN_CHARGER);
	
	return Plugin_Stop;
}

void Event_PlayerBotReplace(Event event, const char[] name, bool dontBroadcast)
{
	HandlePlayerReplace(GetClientOfUserId(event.GetInt("bot")), GetClientOfUserId(event.GetInt("player")));
}

void Event_BotPlayerReplace(Event event, const char[] name, bool dontBroadcast)
{
	HandlePlayerReplace(GetClientOfUserId(event.GetInt("player")), GetClientOfUserId(event.GetInt("bot")));
}

void HandlePlayerReplace(int replacer, int replacee)
{
	if (!replacer || !IsClientInGame(replacer))
		return;

	// edi: 原版在这里写 `if (!replacee) replacee = -1;` 之后继续用 replacee 索引数组并调用
	// L4D2_IsInQueuedPummel(replacee) —— replacee 为 -1 时就是 g_iChargeVictim[-1] + GetEntDataFloat(-1),
	// 既越界又直接抛 "Entity -1 (-1) is invalid"。这里没有"被替换者"就没有任何状态可迁移, 直接返回。
	if (replacee <= 0 || replacee > MaxClients)
	{
		if (g_bNotSolid[replacer])
		{
			SetPlayerSolid(replacer, true);
			g_bNotSolid[replacer] = false;
		}

		g_iChargeVictim[replacer] = -1;
		g_iChargeAttacker[replacer] = -1;
		return;
	}

	if (GetClientTeam(replacer) == 3)
	{
		int victim = g_iChargeVictim[replacee];

		if (victim != -1)
		{
			g_iChargeVictim[replacer] = victim;

			if (victim > 0 && victim <= MaxClients)
				g_iChargeAttacker[victim] = replacer;

			g_iChargeVictim[replacee] = -1;

			// edi: L4D2_IsInQueuedPummel / L4D2_GetQueuedPummelStartTime 内部都是裸的 GetEntDataFloat,
			// replacee 必须仍是"在游戏内的客户端"才不会抛错。
			if (IsValidGameClient(replacee) && L4D2_IsInQueuedPummel(replacee))
			{
				float flQueuedPummelTime = L4D2_GetQueuedPummelStartTime(replacee);
				L4D2_SetQueuedPummelStartTime(replacer, flQueuedPummelTime);

				// edi: SetQueuedPummelAttacker 的 client 参数同样是客户端索引, 先验 victim 有效性。
				if (victim > 0 && victim <= MaxClients)
					L4D2_SetQueuedPummelAttacker(victim, replacer);

				L4D2_SetQueuedPummelVictim(replacer, victim);

				L4D2_SetQueuedPummelStartTime(replacee, -1.0);
				L4D2_SetQueuedPummelVictim(replacee, -1);
			}
		}
	}
	else
	{
		if (g_iChargeAttacker[replacee] != -1)
		{
			g_iChargeAttacker[replacer] = g_iChargeAttacker[replacee];
			g_iChargeVictim[g_iChargeAttacker[replacee]] = replacer;
			g_iChargeAttacker[replacee] = -1;
		}

		if (g_bNotSolid[replacee])
		{
			g_bNotSolid[replacer] = true;
			g_bNotSolid[replacee] = false;
		}
	}
}

// edi: 断线时把「以这个人为 attacker / victim」的缓存记录一起清掉。
// 这是本次 "Entity -1 (N) is invalid" 的根因所在: 引擎不会为"扛着人时断线的 Charger"补发
// charger_carry_end / charger_pummel_end, 原版也没有任何断线清理, 于是
//   · g_iChargeAttacker[受害者] 永远指着一个已离开的客户端索引, 受害者下一次死亡/倒地就会踩到;
//   · 该索引被引擎复用后还会读到"另一个人"的 queued pummel 数据(误判);
//   · L4D_OnPouncedOnSurvivor / L4D2_OnJockeyRide / L4D_OnGrabWithTongue 会永远把这个身体
//     当成"正在被 Charger 控制", 导致之后谁都不能扑/骑/拉他。
// 这里只做数组清理, 不再回写实体内存(客户端正在离开, 改它的 solid 没有意义, 也可能已经无效)。
public void OnClientDisconnect(int client)
{
	if (client <= 0 || client > MaxClients)
		return;

	int victim = g_iChargeVictim[client];
	if (victim > 0 && victim <= MaxClients && g_iChargeAttacker[victim] == client)
		g_iChargeAttacker[victim] = -1;

	int attacker = g_iChargeAttacker[client];
	if (attacker > 0 && attacker <= MaxClients && g_iChargeVictim[attacker] == client)
		g_iChargeVictim[attacker] = -1;

	g_iChargeVictim[client] = -1;
	g_iChargeAttacker[client] = -1;
	g_bNotSolid[client] = false;
	g_flSuppressUntil[client] = 0.0;

	SDKUnhook(client, SDKHook_WeaponSwitchPost, SDK_OnWeaponSwitchPost);
}

public Action L4D_OnPouncedOnSurvivor(int victim, int attacker)
{
	if (g_iChargeAttacker[victim] == -1)
		return Plugin_Continue;
	
	return Plugin_Handled;
}

public Action L4D2_OnJockeyRide(int victim, int attacker)
{
	if (g_iChargeAttacker[victim] == -1)
		return Plugin_Continue;
	
	return Plugin_Handled;
}

public Action L4D_OnGrabWithTongue(int victim, int attacker)
{
	if (g_iChargeAttacker[victim] == -1)
		return Plugin_Continue;
	
	return Plugin_Handled;
}

public void L4D2_OnStartCarryingVictim_Post(int victim, int attacker)
{
	if (!victim || !IsClientInGame(victim))
		return;

	if (!IsPlayerAlive(victim))
		return;

	// edi: 两条数组都以 attacker 为下标, 先确认它在合法范围内, 免得越界写。
	if (!IsValidGameClient(attacker))
		return;

	g_iChargeVictim[attacker] = victim;
	g_iChargeAttacker[victim] = attacker;
}

public void L4D2_OnSlammedSurvivor_Post(int victim, int attacker, bool bWallSlam, bool bDeadlyCharge)
{
	if (!victim || !IsClientInGame(victim))
		return;
	
	if (!IsPlayerAlive(victim))
		return;

	// edi: attacker 是数组下标, 同时也是后面 IsPlayerAlive / GetClientUserId / SuppressAttacks 的入参,
	// 一律先确认它还是有效客户端。
	if (!IsValidGameClient(attacker))
		return;

	g_iChargeVictim[attacker] = victim;
	g_iChargeAttacker[victim] = attacker;

	if (~g_iChargerCollision & CHARGER_COLLISION_PUMMEL)
	{
		Handle timer = CreateTimer(1.0, Timer_KnockdownRepeat, GetClientUserId(victim), TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
		TriggerTimer(timer);
	}
	
	if (!IsPlayerAlive(attacker)) // compatibility with competitive 1v1
	{
		Event event = CreateEvent("charger_killed");
		event.SetInt("userid", GetClientUserId(attacker));
		
		Event_ChargerKilled(event, "charger_killed", false);
		
		event.Cancel();
	}
	
	int jockey = GetEntPropEnt(victim, Prop_Send, "m_jockeyAttacker");
	if (jockey != -1)
	{
		Dismount(jockey);
	}
	
	int smoker = GetEntPropEnt(victim, Prop_Send, "m_tongueOwner");
	if (smoker != -1)
	{
		L4D_Smoker_ReleaseVictim(victim, smoker);
	}
	
	SuppressAttacks(victim, attacker);
}

/*
	A survivor slammed on contact pulls out their active weapon for a small window until the
	queued pummel hides it.
	In this window, the survivor can shoot and shove, which can lead to an unfair outcome.
	To fix this, we suppress the survivor's weapon attacks until the pummel starts (with a small buffer)
	A slam that incaps swaps to the pistol a tick later and a deploy resets the attack timers,
	so any weapon switched to before the pummel starts gets the same suppression.
*/
void SuppressAttacks(int client, int attacker)
{
	float flHold = GetGameTime() + SLAM_ATTACK_HOLD;

	// edi: attacker 由 L4D2_OnSlammedSurvivor_Post 传入, 正常是有效客户端; 但 queued pummel 那组
	// stock 是裸的 GetEntDataFloat, 多一道校验成本可以忽略, 却能彻底堵住同类 "Entity ... is invalid"。
	if (IsValidGameClient(attacker) && L4D2_IsInQueuedPummel(attacker))
	{
		float flPummelStart = L4D2_GetQueuedPummelStartTime(attacker) + SLAM_PUMMEL_MARGIN;
		if (flPummelStart > flHold)
			flHold = flPummelStart;
	}
	
	g_flSuppressUntil[client] = flHold;
	SuppressWeapon(GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon"), flHold);
	
	SDKUnhook(client, SDKHook_WeaponSwitchPost, SDK_OnWeaponSwitchPost);
	SDKHook(client, SDKHook_WeaponSwitchPost, SDK_OnWeaponSwitchPost);
}

void SDK_OnWeaponSwitchPost(int client, int weapon)
{
	if (GetGameTime() >= g_flSuppressUntil[client])
	{
		SDKUnhook(client, SDKHook_WeaponSwitchPost, SDK_OnWeaponSwitchPost);
		return;
	}
	
	SuppressWeapon(weapon, g_flSuppressUntil[client]);
}

void SuppressWeapon(int weapon, float flHold)
{
	if (weapon <= MaxClients || !IsValidEntity(weapon))
		return;
	
	if (GetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack") < flHold)
		SetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack", flHold);
	
	if (GetEntPropFloat(weapon, Prop_Send, "m_flNextSecondaryAttack") < flHold)
		SetEntPropFloat(weapon, Prop_Send, "m_flNextSecondaryAttack", flHold);
}

Action Timer_KnockdownRepeat(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (!client || !IsClientInGame(client))
		return Plugin_Stop;
	
	if (GetClientTeam(client) != 2)
		return Plugin_Stop;
	
	if (!IsPlayerAlive(client) || L4D_IsPlayerIncapacitated(client))
		return Plugin_Stop;
	
	int queuedPummelAttacker = L4D2_GetQueuedPummelAttacker(client);
	// edi: 同 Event_PlayerIncap —— 该 netprop 里的索引可能指向已断线玩家, 先验再用。
	if (!IsValidGameClient(queuedPummelAttacker) || !L4D2_IsInQueuedPummel(queuedPummelAttacker))
	{
		if (GetEntPropEnt(client, Prop_Send, "m_pummelAttacker") == -1)
			return Plugin_Stop;
	}
	
	KnockdownPlayer(client, KNOCKDOWN_CHARGER);
	
	return Plugin_Continue;
}

void KnockdownPlayer(int client, int reason)
{
	SetEntProp(client, Prop_Send, "m_knockdownReason", reason);
	SetEntPropFloat(client, Prop_Send, "m_knockdownTimer", GetGameTime(), 0);
}

void SetPlayerSolid(int client, bool solid)
{
	int flags = GetEntProp(client, Prop_Data, "m_usSolidFlags");
	SetEntProp(client, Prop_Data, "m_usSolidFlags", solid ? (flags & ~FSOLID_NOT_SOLID) : (flags | FSOLID_NOT_SOLID));
}

void Dismount(int client)
{
	int flags = GetCommandFlags("dismount");
	SetCommandFlags("dismount", flags & ~FCVAR_CHEAT);
	FakeClientCommand(client, "dismount");
	SetCommandFlags("dismount", flags);
}

ConVar CreateConVarHook(const char[] name,
	const char[] defaultValue,
	const char[] description="",
	int flags=0,
	bool hasMin=false, float min=0.0,
	bool hasMax=false, float max=0.0,
	ConVarChanged callback)
{
	ConVar cv = CreateConVar(name, defaultValue, description, flags, hasMin, min, hasMax, max);
	
	Call_StartFunction(INVALID_HANDLE, callback);
	Call_PushCell(cv);
	Call_PushNullString();
	Call_PushNullString();
	Call_Finish();
	
	cv.AddChangeHook(callback);
	
	return cv;
}
