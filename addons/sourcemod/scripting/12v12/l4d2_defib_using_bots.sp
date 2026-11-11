/**
 * ============================================================================
 *  [L4D2] Defibrillator Using Bots / 机器人替你用电击器救人
 * ============================================================================
 *  原版： "[L4D2] Defib using bots" v1.7 by DeathChaos25
 *          https://forums.alliedmods.net/showthread.php?t=261566
 *  本文件：modernized for SourceMod 1.12（按 SourcePawn 现代语法重写，行为对齐原版 1.7）
 *
 *  ---- 玩法意图（原版真实机制，不是"AI 自动对玩家电击"）----
 *  每 interval 秒扫描全图的 survivor_death_model（阵亡生还者留下的、可被电击器救回的尸体），
 *  为每具尸体指派一名「最近的可用 AI 生还者」：
 *    · 距离 > use_range 且 <= chase_range：用 VScript 的 CommandABot({cmd=1}) 指挥机器人
 *      走到尸体旁边；
 *    · 距离 <= use_range：机器人切到电击器 → 视角对准尸体 → 0.2 秒后由 OnPlayerRunCmd
 *      替它按住 IN_ATTACK，完成电击复活；
 *    · defibrillator_used / _used_fail / _interrupted → 立刻松开按键，并用
 *      CommandABot({cmd=3}) 复位机器人 AI。
 *  ⇒ 也就是说：电击这个动作由「AI 队友代替人类玩家跑位去做」，人类玩家自己手电电击完全
 *    不受影响（本插件对真人玩家不做任何按键干预）。
 *
 *  ---- 相对原版 1.7 的改动（逐条对应"翻新 / 检查其他问题"）----
 *  1. 现代语法： #pragma newdecls required、char[]/float 变量、方法调用式 API
 *     （event.GetInt、convar.BoolValue），全部旧式 new/String/Float: 声明已移除。
 *  2. 去硬编码：武器槽 3 → 自动扫描全部槽位查找 weapon_defibrillator；
 *     100 / 800 距离 → cvar（sm_defib_bots_use_range / _chase_range）；
 *     1 秒扫描间隔 → cvar（sm_defib_bots_interval）；
 *     人数一律用 MaxClients，不再假设 4 人。
 *  3. 修 bug：原版对"第一具尸体"处理完就 break 跳出尸体遍历，
 *     场上多名阵亡者时其余尸体永远不会被救。现在遍历全部尸体，一具尸体指派一名机器人。
 *  4. 修 bug：原版机器人被强制按住开火后，若既不触发成功事件也不触发失败事件
 *     （例如尸体实体被别的系统移除），会永久卡在"持续开火"状态。
 *     现在有 5 秒超时强制松手 + 复位 AI。
 *  5. 修 bug：原版 AllowDefib 计时器回调里没有校验 client —— 机器人在 0.2 秒内断线时
 *     GetClientOfUserId 返回 0，会污染数组。现在整个流程都做 client 校验。
 *  6. 修 bug：原版用 flags ^ FCVAR_CHEAT 临时去掉 script 的作弊标记，若该命令本来不带
 *     作弊标记会把标记"加上"；改用 flags & ~FCVAR_CHEAT 临时解除、结束后还原原始 flags。
 *  7. 原版 IsAssistNeeded() 的语义是"全队任何一人倒地/被控就禁止电击救人"。
 *     12v12（survivor_limit=12）下几乎总有人倒地，等于插件永不生效；
 *     改为可配置 sm_defib_bots_assist_gate，默认 0（关闭），需要保守策略时再开。
 *  8. 边缘情况补全：倒地 / 挂边 / 被控 / 已死亡 / 非 AI / 卡在踢人队列 /
 *     生还者全灭 / 换图 / 晚加载（late load）安全 / 尸体实体被复用。
 *  9. 前置限制条件（需求）：扫描循环开头的硬门槛 —— 必须同时满足
 *     ①「有生还者阵亡」：场上存在 survivor_death_model 尸体实体（没有尸体就不检测、不遍历）；
 *     ②「场上有非玩家操控（AI）生还者」：存在 IsFakeClient 且可被指挥的存活生还者。
 *     两个条件任一不满足就立刻释放已在工作的机器人并退出，绝不干预真人玩家；
 *     全是真人、或还没人死的时候，本插件每个 tick 什么都不做。
 *
 *  ---- 依赖 ----
 *  仅 sourcemod + sdktools，无 gamedata、无 DHooks、无 Left4DHooks。
 *  建议与 12v12/Defib_Fix.sp 同时启用（它修引擎层"电击索引失效"的 bug，能让电击更可靠）。
 *
 *  ---- 已知限制 ----
 *  机器人走位依赖引擎 VScript 的 CommandABot；尸体在不可达位置（半空/墙内）时机器人会
 *  反复走向同一点直到 chase_range 判定放弃，属引擎寻路限制。
 * ============================================================================
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "1.0.0"

#define TEAM_SURVIVOR 2
#define TEAM_INFECTED 3

#define DEATH_MODEL "survivor_death_model"
#define DEFIB_CLASSNAME "weapon_defibrillator"

// 机器人 AI 指令（VScript CommandABot 的 cmd 参数，与原版一致）
#define CMDBOT_ATTACK 0
#define CMDBOT_MOVE 1
#define CMDBOT_RETREAT 2
#define CMDBOT_RESET 3

// 强制按住开火的状态
enum
{
	SHOOT_OFF = 0, // 不干预
	SHOOT_ON = 1   // 由本插件替机器人按住 IN_ATTACK
}

// 切武器 / 转向 到真正按住按键之间的等待（秒），让引擎先完成武器切换与视角同步
#define DEFIB_ARM_DELAY 0.2
// 单次电击尝试的最长强制开火时间（秒），超时即松手，防止机器人永久卡在开火状态
#define DEFIB_FIRE_TIMEOUT 5.0

int g_iShoot[MAXPLAYERS + 1];           // 当前是否由本插件替该机器人按住开火
int g_iTarget[MAXPLAYERS + 1];          // 该机器人正在处理的尸体实体索引（0 = 空闲）
float g_flArmAt[MAXPLAYERS + 1];        // 允许开始按键的游戏时间
float g_flFireDeadline[MAXPLAYERS + 1]; // 强制开火的超时时刻
float g_flRetryAfter[MAXPLAYERS + 1];   // 冷却结束前不再被指派

ConVar g_cvEnabled;
ConVar g_cvInterval;
ConVar g_cvChaseRange;
ConVar g_cvUseRange;
ConVar g_cvRequireQuiet;
ConVar g_cvAssistGate;
ConVar g_cvRetryDelay;

Handle g_hScanTimer;

public Plugin myinfo =
{
	name = "[L4D2] Defib Using Bots",
	author = "apples1949",
	description = "让 AI 生还者自动走到阵亡队友尸体旁，用电击器把队友救回来（12v12 适配）",
	version = PLUGIN_VERSION,
	url = "https://forums.alliedmods.net/showthread.php?t=261566"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	if (GetEngineVersion() != Engine_Left4Dead2)
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 2");
		return APLRes_Failure;
	}
	return APLRes_Success;
}

public void OnPluginStart()
{
	CreateConVar("sm_defib_bots_version", PLUGIN_VERSION,
		"l4d2_defib_using_bots 插件版本号（只读）", FCVAR_NOTIFY | FCVAR_DONTRECORD);

	g_cvEnabled = CreateConVar("sm_defib_bots_enabled", "1",
		"总开关。1=允许 AI 生还者使用电击器救人，0=完全关闭本插件（不扫描尸体、清空所有已指派状态）。");
	g_cvInterval = CreateConVar("sm_defib_bots_interval", "1.0",
		"扫描间隔（秒）。每隔这么久重新评估一次「哪具尸体该由哪个机器人去救」。范围 0.2~5.0，越小越灵敏但开销越大。",
		_, true, 0.2, true, 5.0);
	g_cvChaseRange = CreateConVar("sm_defib_bots_chase_range", "800.0",
		"追击半径（游戏单位，1 单位≈1.9 厘米）。只有与尸体距离不超过该值的机器人才会被指派前往。建议 500~1200。",
		_, true, 100.0, true, 3000.0);
	g_cvUseRange = CreateConVar("sm_defib_bots_use_range", "120.0",
		"使用半径（游戏单位）。机器人走到离尸体不超过该值时才切换电击器并按住开火。必须明显小于 chase_range。建议 80~200。",
		_, true, 32.0, true, 800.0);
	g_cvRequireQuiet = CreateConVar("sm_defib_bots_require_quiet", "1",
		"是否要求机器人当前没有可见威胁才去救人。1=身边有可见敌人时优先战斗（原版行为），0=再危险也去电。");
	g_cvAssistGate = CreateConVar("sm_defib_bots_assist_gate", "0",
		"队友倒地/挂边/被控时是否禁止电击救人。1=先救活着的人再电（原版行为，12v12 下几乎永不触发），0=照常去电（12v12 推荐默认）。");
	g_cvRetryDelay = CreateConVar("sm_defib_bots_retry_delay", "6.0",
		"电击失败或被打断后，同一机器人重新尝试的冷却时间（秒）。范围 1.0~30.0。",
		_, true, 1.0, true, 30.0);

	g_cvInterval.AddChangeHook(OnIntervalChanged);

	HookEvent("defibrillator_used", Event_DefibUsed, EventHookMode_Post);
	HookEvent("defibrillator_used_fail", Event_DefibFailed, EventHookMode_Post);
	HookEvent("defibrillator_interrupted", Event_DefibFailed, EventHookMode_Post);

	RegAdminCmd("sm_resetbots", Cmd_ResetBots, ADMFLAG_ROOT, "复位全部 AI 生还者的行动（取消当前 AI 指令）");
	RegAdminCmd("sm_regroup", Cmd_Regroup, ADMFLAG_ROOT, "命令全部 AI 生还者移动到你的位置");
	RegAdminCmd("sm_attack", Cmd_AttackSI, ADMFLAG_ROOT, "命令全部 AI 生还者攻击你准星指向的特殊感染者");
	RegAdminCmd("sm_retreat", Cmd_Retreat, ADMFLAG_ROOT, "命令全部 AI 生还者远离你准星指向的特殊感染者");

	// 晚加载（回合中途 load 插件）安全：本插件不重建任何实体/回合状态，
	// 计时器下一拍会自己发现场上已有的尸体；这里只需保证数组是干净的初始状态。
	ResetAllBots(false, false);

	StartScanTimer();
}

public void OnPluginEnd()
{
	if (g_hScanTimer != null)
	{
		KillTimer(g_hScanTimer);
		g_hScanTimer = null;
	}

	// 被我们按住开火的机器人，卸载时立刻松手并复位 AI，避免留下"卡着开火"的机器人
	ResetAllBots(true, true);
}

public void OnMapEnd()
{
	// 换图：实体索引会失效，清空全部指向尸体的状态
	ResetAllBots(true, false);

	if (g_hScanTimer != null)
	{
		KillTimer(g_hScanTimer);
		g_hScanTimer = null;
	}
}

public void OnMapStart()
{
	if (g_hScanTimer == null)
	{
		StartScanTimer();
	}
}

void StartScanTimer()
{
	if (g_hScanTimer != null)
	{
		KillTimer(g_hScanTimer);
		g_hScanTimer = null;
	}

	float flInterval = g_cvInterval.FloatValue;
	if (flInterval < 0.2)
	{
		flInterval = 0.2;
	}

	g_hScanTimer = CreateTimer(flInterval, Timer_Scan, _, TIMER_REPEAT);
}

public void OnIntervalChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	StartScanTimer();
}

// ============================================================================
// 主循环
// ============================================================================

public Action Timer_Scan(Handle timer)
{
	if (!g_cvEnabled.BoolValue)
	{
		ResetAllBots(true, false);
		return Plugin_Continue;
	}

	// 服务器暂停 / 关卡结算 / 生还者全灭时不处理
	if (!IsServerProcessing() || !HasAliveSurvivor())
	{
		ResetAllBots(true, false);
		return Plugin_Continue;
	}

	// 前置限制条件（需求）：必须「有生还者阵亡」且「场上有非玩家操控（AI bot）生还者」才开始检测。
	//   1) 生还者阵亡 → 场上有 survivor_death_model 尸体实体；没有尸体就根本没东西可电，
	//      直接退出，连遍历都不做（每 1 秒一次，省掉空转）。
	//   2) 非玩家操控的生还者 → 存在 IsFakeClient 的存活生还者；全是真人时本插件无从下手，
	//      立刻释放已经在干活的机器人并退出，绝不干预真人。
	if (!HasBotSurvivor())
	{
		ResetAllBots(true, false);
		return Plugin_Continue;
	}

	if (!HasDeathModel())
	{
		ResetAllBots(true, false);
		return Plugin_Continue;
	}

	float flNow = GetGameTime();
	MaintainAssignedBots(flNow);
	AssignBotsToBodies(flNow);

	return Plugin_Continue;
}

// 场上是否有「非玩家操控（AI）且可被指挥」的存活生还者。
// 这是本插件的工作前提：真人玩家一律不碰（见 IsStillValidBot 的 IsFakeClient 判定）。
bool HasBotSurvivor()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsStillValidBot(i))
		{
			return true;
		}
	}

	return false;
}

// 场上是否还有阵亡生还者的尸体（survivor_death_model）。
// 它就是「有生还者死亡且尸体还在」的判据；尸体被救活/被系统移除后自然变 false。
bool HasDeathModel()
{
	return FindEntityByClassname(-1, DEATH_MODEL) != -1;
}

// 校验已经在处理某具尸体的机器人：还合不合法、尸体还在不在、要不要重新切枪/重新瞄准、是否超时
void MaintainAssignedBots(float flNow)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (g_iTarget[i] == 0)
		{
			g_iShoot[i] = SHOOT_OFF;
			g_flArmAt[i] = 0.0;
			g_flFireDeadline[i] = 0.0;
			continue;
		}

		// 硬性条件不再满足（死亡/倒地/挂边/被控/掉线/变真人）
		if (!IsStillValidBot(i))
		{
			ReleaseBot(i, 0.0, true);
			continue;
		}

		// 尸体没了（已救活 / 被系统移除 / 实体索引被复用）
		if (!IsDeathModel(g_iTarget[i]))
		{
			ReleaseBot(i, 0.0, false);
			continue;
		}

		if (g_iShoot[i] != SHOOT_ON)
		{
			continue; // 还在赶路，交给 AssignBotsToBodies 下发移动指令
		}

		// 已经在强制开火：超时保护
		if (flNow > g_flFireDeadline[i])
		{
			ReleaseBot(i, 1.0, true);
			continue;
		}

		// 机器人把武器换回去了 / 电击器被别的东西切走 → 重新切
		if (!IsHoldingActiveDefib(i))
		{
			if (FindDefibWeapon(i) == 0)
			{
				ReleaseBot(i, 0.0, true); // 电击器已经用掉了
				continue;
			}
			FakeClientCommand(i, "use %s", DEFIB_CLASSNAME);
		}

		// 机器人自身动作会让视角漂移，每拍重新对准一次，保证 +attack 打在尸体上
		AimAtBody(i, g_iTarget[i]);
	}
}

// 为每具尸体指派机器人；已在赶路的机器人继续下达移动指令
void AssignBotsToBodies(float flNow)
{
	int iBody = -1;

	while ((iBody = FindEntityByClassname(iBody, DEATH_MODEL)) != -1)
	{
		if (!IsValidEntity(iBody))
		{
			continue;
		}

		float vecBody[3];
		GetEntPropVector(iBody, Prop_Send, "m_vecOrigin", vecBody);

		// 这具尸体是否已经有机器人在处理（最多一名，避免全部机器人挤在一起）
		int iAssigned = 0;
		for (int i = 1; i <= MaxClients; i++)
		{
			if (g_iTarget[i] == iBody)
			{
				iAssigned = i;
				break;
			}
		}

		if (iAssigned != 0)
		{
			if (g_iShoot[iAssigned] == SHOOT_ON)
			{
				continue; // 正在电，别打断
			}

			float vecBot[3];
			GetClientAbsOrigin(iAssigned, vecBot);
			float flDist = GetVectorDistance(vecBot, vecBody);

			if (flDist > g_cvChaseRange.FloatValue)
			{
				ReleaseBot(iAssigned, 0.0, true); // 越追越远，放弃这具尸体
				continue;
			}

			if (flDist > g_cvUseRange.FloatValue)
			{
				CommandABotMove(iAssigned, vecBody); // 继续走过去
				continue;
			}

			BeginDefib(iAssigned, iBody);
			continue;
		}

		// 没有机器人负责 → 挑最近的、空闲的、符合条件的机器人
		int iBest = 0;
		float flBestDist = 0.0;

		for (int i = 1; i <= MaxClients; i++)
		{
			if (g_iTarget[i] != 0)
			{
				continue;
			}
			if (flNow < g_flRetryAfter[i])
			{
				continue;
			}
			if (!IsEligibleBot(i))
			{
				continue;
			}

			float vecBot[3];
			GetClientAbsOrigin(i, vecBot);
			float flDist = GetVectorDistance(vecBot, vecBody);

			if (flDist > g_cvChaseRange.FloatValue)
			{
				continue;
			}

			if (iBest == 0 || flDist < flBestDist)
			{
				iBest = i;
				flBestDist = flDist;
			}
		}

		if (iBest == 0)
		{
			continue;
		}

		if (flBestDist <= g_cvUseRange.FloatValue)
		{
			BeginDefib(iBest, iBody);
		}
		else
		{
			g_iTarget[iBest] = iBody;
			CommandABotMove(iBest, vecBody);
		}
	}
}

// 切枪 + 对准 + 进入"0.2 秒后开始按住开火"状态
void BeginDefib(int client, int iBody)
{
	if (!IsHoldingActiveDefib(client))
	{
		if (FindDefibWeapon(client) == 0)
		{
			ReleaseBot(client, 0.0, false); // 手上已经没电击器了
			return;
		}
		FakeClientCommand(client, "use %s", DEFIB_CLASSNAME);
	}

	AimAtBody(client, iBody);

	float flNow = GetGameTime();
	g_iTarget[client] = iBody;
	g_iShoot[client] = SHOOT_ON;
	g_flArmAt[client] = flNow + DEFIB_ARM_DELAY;
	g_flFireDeadline[client] = flNow + DEFIB_FIRE_TIMEOUT;
}

void AimAtBody(int client, int iBody)
{
	float vecEye[3], vecBody[3], vecAim[3], vecAng[3];

	GetClientEyePosition(client, vecEye);
	GetEntPropVector(iBody, Prop_Send, "m_vecOrigin", vecBody);
	vecBody[2] += 10.0; // 瞄尸体上半身，让电击器射线稳定命中死亡模型

	MakeVectorFromPoints(vecEye, vecBody, vecAim);
	GetVectorAngles(vecAim, vecAng);
	TeleportEntity(client, NULL_VECTOR, vecAng, NULL_VECTOR);
}

// 清掉某个机器人的指派状态；bOrderReset=true 时顺手让它退出 VScript AI 指令
void ReleaseBot(int client, float flCooldown, bool bOrderReset)
{
	if (client < 1 || client > MaxClients)
	{
		return;
	}

	g_iShoot[client] = SHOOT_OFF;
	g_iTarget[client] = 0;
	g_flArmAt[client] = 0.0;
	g_flFireDeadline[client] = 0.0;
	g_flRetryAfter[client] = (flCooldown > 0.0) ? GetGameTime() + flCooldown : 0.0;

	if (bOrderReset)
	{
		CommandABotReset(client);
	}
}

// bFullReset=false 时只清状态、不碰冷却（用于 OnPluginStart 的初始化）
void ResetAllBots(bool bOrderReset, bool bFullReset)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		bool bWasShooting = (g_iShoot[i] == SHOOT_ON) || (g_iTarget[i] != 0);

		g_iShoot[i] = SHOOT_OFF;
		g_iTarget[i] = 0;
		g_flArmAt[i] = 0.0;
		g_flFireDeadline[i] = 0.0;

		if (bFullReset)
		{
			g_flRetryAfter[i] = 0.0;
		}

		if (bOrderReset && bWasShooting)
		{
			CommandABotReset(i);
		}
	}
}

// ============================================================================
// 玩家指令
// ============================================================================

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3],
                             int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	if (client < 1 || client > MaxClients)
	{
		return Plugin_Continue;
	}

	if (g_iShoot[client] != SHOOT_ON)
	{
		return Plugin_Continue;
	}

	if (!IsFakeClient(client))
	{
		return Plugin_Continue; // 永远不碰真人玩家的按键
	}

	// 武器还没切好 / 视角还没同步，先别按
	if (GetGameTime() < g_flArmAt[client])
	{
		return Plugin_Continue;
	}

	// 只有确认手里拿的是电击器才敢按，避免机器人朝队友开枪
	if (!IsHoldingActiveDefib(client))
	{
		return Plugin_Continue;
	}

	buttons |= IN_ATTACK;

	return Plugin_Continue;
}

public void Event_DefibUsed(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	// 成功救人：立即松手，0.4 秒后复位 AI（等电击结束动画收尾）
	CancelForcedFire(client, 0.0, 0.4);
}

public void Event_DefibFailed(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	// 失败 / 被打断：松手并进入冷却，避免原地反复电
	float flDelay = g_cvRetryDelay.FloatValue;
	if (flDelay < 1.0)
	{
		flDelay = 1.0;
	}

	CancelForcedFire(client, flDelay, flDelay);
}

void CancelForcedFire(int client, float flCooldown, float flResetDelay)
{
	if (client < 1 || client > MaxClients)
	{
		return;
	}

	if (!IsClientInGame(client) || !IsFakeClient(client))
	{
		return; // 真人的电击事件跟本插件无关
	}

	if (g_iShoot[client] != SHOOT_ON)
	{
		return; // 不是我们在替他按开火（别的插件/人类在操作）
	}

	ReleaseBot(client, flCooldown, false);
	CreateTimer(flResetDelay, Timer_ResetBotAI, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_ResetBotAI(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);

	if (client < 1 || client > MaxClients)
	{
		return Plugin_Stop;
	}

	if (!IsClientInGame(client) || !IsFakeClient(client))
	{
		return Plugin_Stop;
	}

	// 冷却结束前可能已经被派了新任务，别把新的移动指令撤销掉
	if (g_iShoot[client] == SHOOT_ON || g_iTarget[client] != 0)
	{
		return Plugin_Stop;
	}

	CommandABotReset(client);

	return Plugin_Stop;
}

// ============================================================================
// 管理命令（沿用原版的 4 个指令）
// ============================================================================

public Action Cmd_ResetBots(int client, int args)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsStillValidBot(i))
		{
			CommandABotReset(i);
		}
	}

	ReplyToCommand(client, "[SM] 已复位全部 AI 生还者的行动。");

	return Plugin_Continue;
}

public Action Cmd_Regroup(int client, int args)
{
	if (client < 1 || !IsClientInGame(client))
	{
		ReplyToCommand(client, "[SM] 该指令只能由游戏内玩家执行。");
		return Plugin_Continue;
	}

	float vecOrigin[3];
	GetClientAbsOrigin(client, vecOrigin);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsStillValidBot(i))
		{
			CommandABotMove(i, vecOrigin);
		}
	}

	ReplyToCommand(client, "[SM] 已命令 AI 生还者向你集合。");

	return Plugin_Continue;
}

public Action Cmd_AttackSI(int client, int args)
{
	if (client < 1 || !IsClientInGame(client) || GetClientTeam(client) != TEAM_SURVIVOR)
	{
		ReplyToCommand(client, "[SM] 该指令只能由生还者执行。");
		return Plugin_Continue;
	}

	int iTarget = GetClientAimTarget(client, true);

	if (iTarget < 1 || !IsClientInGame(iTarget) || GetClientTeam(iTarget) != TEAM_INFECTED)
	{
		ReplyToCommand(client, "[SM] 准星没有指向特殊感染者。");
		return Plugin_Continue;
	}

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsStillValidBot(i))
		{
			CommandABotAttack(i, iTarget, CMDBOT_ATTACK);
		}
	}

	ReplyToCommand(client, "[SM] 已命令 AI 生还者攻击目标。");

	return Plugin_Continue;
}

public Action Cmd_Retreat(int client, int args)
{
	if (client < 1 || !IsClientInGame(client) || GetClientTeam(client) != TEAM_SURVIVOR)
	{
		ReplyToCommand(client, "[SM] 该指令只能由生还者执行。");
		return Plugin_Continue;
	}

	int iTarget = GetClientAimTarget(client, true);

	if (iTarget < 1 || !IsClientInGame(iTarget) || GetClientTeam(iTarget) != TEAM_INFECTED)
	{
		ReplyToCommand(client, "[SM] 准星没有指向特殊感染者。");
		return Plugin_Continue;
	}

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsStillValidBot(i))
		{
			CommandABotAttack(i, iTarget, CMDBOT_RETREAT);
		}
	}

	ReplyToCommand(client, "[SM] 已命令 AI 生还者远离目标。");

	return Plugin_Continue;
}

// ============================================================================
// VScript CommandABot 封装（机器人 AI 指令）
// ============================================================================

void CommandABotMove(int client, const float vecPos[3])
{
	char sCode[PLATFORM_MAX_PATH];

	Format(sCode, sizeof(sCode), "CommandABot({cmd = %d, pos = Vector(%f, %f, %f), bot = GetPlayerFromUserID(%i)})",
		CMDBOT_MOVE, vecPos[0], vecPos[1], vecPos[2], GetClientUserId(client));

	ExecuteScript(client, sCode);
}

void CommandABotAttack(int client, int iTarget, int iCmd)
{
	char sCode[PLATFORM_MAX_PATH];

	Format(sCode, sizeof(sCode), "CommandABot({cmd = %d, bot = GetPlayerFromUserID(%i), target = GetPlayerFromUserID(%i)})",
		iCmd, GetClientUserId(client), GetClientUserId(iTarget));

	ExecuteScript(client, sCode);
}

void CommandABotReset(int client)
{
	if (client < 1 || client > MaxClients || !IsClientInGame(client) || !IsFakeClient(client))
	{
		return;
	}

	char sCode[PLATFORM_MAX_PATH];

	Format(sCode, sizeof(sCode), "CommandABot({cmd = %d, bot = GetPlayerFromUserID(%i)})",
		CMDBOT_RESET, GetClientUserId(client));

	ExecuteScript(client, sCode);
}

// 以该机器人的身份执行一段 VScript 代码
void ExecuteScript(int client, const char[] sCode)
{
	if (client < 1 || client > MaxClients || !IsClientInGame(client) || !IsFakeClient(client))
	{
		return;
	}

	int iFlags = GetCommandFlags("script");

	if (iFlags == INVALID_FCVAR_FLAGS)
	{
		return; // 该引擎版本没有 script 命令，直接放弃
	}

	SetCommandFlags("script", iFlags & ~FCVAR_CHEAT);
	FakeClientCommand(client, "script %s", sCode);
	SetCommandFlags("script", iFlags);
}

// ============================================================================
// 判定辅助
// ============================================================================

// 完整门槛：只用于"新指派"
bool IsEligibleBot(int client)
{
	if (!IsStillValidBot(client))
	{
		return false;
	}

	if (g_cvRequireQuiet.BoolValue && HasVisibleThreats(client))
	{
		return false;
	}

	if (g_cvAssistGate.BoolValue && IsAnySurvivorInNeed(client))
	{
		return false;
	}

	return true;
}

// 硬性门槛：生还者方、AI、活着、未倒地、未挂边、未被控
bool IsStillValidBot(int client)
{
	if (client < 1 || client > MaxClients)
	{
		return false;
	}

	if (!IsClientInGame(client) || IsClientInKickQueue(client))
	{
		return false;
	}

	if (GetClientTeam(client) != TEAM_SURVIVOR)
	{
		return false;
	}

	if (!IsFakeClient(client))
	{
		return false; // 只指挥 AI 生还者
	}

	if (!IsPlayerAlive(client))
	{
		return false;
	}

	if (IsIncapacitated(client) || IsHangingFromLedge(client) || IsPlayerHeld(client))
	{
		return false;
	}

	return true;
}

bool HasAliveSurvivor()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && GetClientTeam(i) == TEAM_SURVIVOR && IsPlayerAlive(i))
		{
			return true;
		}
	}

	return false;
}

// 除自己以外，是否还有队友正倒地/挂边/被控（原版 IsAssistNeeded 的 12v12 版本）
bool IsAnySurvivorInNeed(int iExcept)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (i == iExcept)
		{
			continue;
		}

		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR || !IsPlayerAlive(i))
		{
			continue;
		}

		if (IsIncapacitated(i) || IsHangingFromLedge(i) || IsPlayerHeld(i))
		{
			return true;
		}
	}

	return false;
}

int FindDefibWeapon(int client)
{
	char sClassname[64];

	for (int iSlot = 0; iSlot <= 5; iSlot++)
	{
		int iWeapon = GetPlayerWeaponSlot(client, iSlot);

		if (!IsValidEntity(iWeapon))
		{
			continue;
		}

		GetEntityClassname(iWeapon, sClassname, sizeof(sClassname));

		if (StrEqual(sClassname, DEFIB_CLASSNAME, false))
		{
			return iWeapon;
		}
	}

	return 0;
}

bool IsHoldingActiveDefib(int client)
{
	int iWeapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");

	if (!IsValidEntity(iWeapon))
	{
		return false;
	}

	char sClassname[64];
	GetEntityClassname(iWeapon, sClassname, sizeof(sClassname));

	return StrEqual(sClassname, DEFIB_CLASSNAME, false);
}

bool IsDeathModel(int iEntity)
{
	if (!IsValidEntity(iEntity))
	{
		return false;
	}

	char sClassname[64];
	if (!GetEntityClassname(iEntity, sClassname, sizeof(sClassname)))
	{
		return false;
	}

	return StrEqual(sClassname, DEATH_MODEL, false);
}

bool IsIncapacitated(int client)
{
	return GetEntProp(client, Prop_Send, "m_isIncapacitated") != 0;
}

bool IsHangingFromLedge(int client)
{
	return GetEntProp(client, Prop_Send, "m_isHangingFromLedge") != 0;
}

bool IsPlayerHeld(int client)
{
	return GetEntPropEnt(client, Prop_Send, "m_jockeyAttacker") > 0
		|| GetEntPropEnt(client, Prop_Send, "m_pummelAttacker") > 0
		|| GetEntPropEnt(client, Prop_Send, "m_pounceAttacker") > 0
		|| GetEntPropEnt(client, Prop_Send, "m_tongueOwner") > 0;
}

bool HasVisibleThreats(int client)
{
	return GetEntProp(client, Prop_Send, "m_hasVisibleThreats") != 0;
}
