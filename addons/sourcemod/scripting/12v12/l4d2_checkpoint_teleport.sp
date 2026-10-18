/**
 * ============================================================================
 *  l4d2_checkpoint_teleport.sp  -  Setpoint / saferoom / rescue auto-teleport
 * ============================================================================
 *  applemod12v12 (12v12 versus) 定制插件
 *
 *  需求：
 *    在「机关集合点 / 安全屋 / 救援关」这些区域，当剩余生还者总数的 66%
 *    到齐后开始 60 秒倒计时；倒计时结束时把还没到的生还者传送进该区域，
 *    并开启对应的机关（电梯按钮 / 开关等）。
 *    —— 绝不改动安全门（safe room door）的 spawnflags / lock 状态，
 *       救援车人齐与否由游戏自己判定。
 *
 *  区域来源（全部运行时自动侦测，不硬编码地图名 / 坐标 / targetname）：
 *    1) 安全屋（关底）  : info_changelevel，找不到时退回 trigger_changelevel
 *    2) 救援关          : 终局图上 m_iEntireTeam == 2 的 trigger_multiple
 *                         （终局图为牺牲结局时自动跳过）
 *    3) 机关集合点      : 玩家按下「锁住的」func_button 时注册该按钮
 *                         （监听 func_button 的 OnUseLocked 输出，参考
 *                          alasfourom "L4D Elevator Teleport" 的做法）
 *
 *  「是否已到达」判定：
 *    - 安全屋 / 救援关：L4D_IsTouchingTrigger(区域实体, client)
 *      （left4dhooks 内部就是 CBaseTrigger::IsTouching，与
 *        L4D_IsInLastCheckpoint 用的是同一条路径）
 *    - 机关集合点      ：玩家到按钮原点的三维距离 <= l4d2_cptele_mech_radius
 *
 *  传送目标点：
 *    1) 优先取「已经站在区域内的存活生还者」的位置（一定可以站立）
 *    2) 否则取区域实体 / 按钮原点，用 L4D_GetNearestNavArea +
 *       L4D_FindRandomSpot 取该 nav area 上的随机点
 *    3) 都失败则退化为区域原点本身
 *    传送后统一调用 L4D_WarpToValidPositionIfStuck 兜底。全程不触碰安全门。
 *
 *  状态机：
 *    round_start(延时 3s) -> 侦测区域 -> 1s/次 监控 timer
 *      -> 某区域到达人数 >= ceil(percent% * 存活生还者数) -> 开始倒计时
 *      -> 倒计时结束 -> 传送未到者 + 开机关 -> 该区域标记为已触发
 *    同一区域每回合只会触发一次；换图 / round_start / round_end 全部重置。
 *
 *  API 运行期依赖：left4dhooks 的若干 native 在 include 里是
 *  MarkNativeAsOptional，因此 OnAllPluginsLoaded 里用 GetFeatureStatus
 *  逐个复核，关键 native 缺失时自动关掉功能并写日志，而不是崩服。
 * ============================================================================
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#define PLUGIN_VERSION      "1.0.0"

#define SOUND_COUNTDOWN     "buttons/blip1.wav"

#define TEAM_SURVIVOR       2
#define TEAM_INFECTED       3

#define MAX_AREAS           32          // 一张图最多同时监控的区域数
#define MONITOR_INTERVAL    1.0         // 区域监控间隔（秒）
#define INIT_DELAY          3.0         // round_start 后延迟多久侦测实体
#define CANCEL_COOLDOWN     10.0        // 倒计时被取消后，该区域的冷静期
#define INFECTED_CLEAR_RADIUS 300.0     // 清理传送点周围特感的半径

// ---------------------------------------------------------------------------
// 区域类型
// ---------------------------------------------------------------------------
enum
{
	AREA_SAFEROOM = 0,      // 关底安全屋（info_changelevel / trigger_changelevel）
	AREA_RESCUE,            // 救援关（trigger_multiple，m_iEntireTeam == 2）
	AREA_MECHANISM          // 机关集合点（被锁住的 func_button）
};

// ---------------------------------------------------------------------------
// ConVar
// ---------------------------------------------------------------------------
ConVar g_cvEnable;
ConVar g_cvPercent;
ConVar g_cvTime;
ConVar g_cvResetOnLeave;
ConVar g_cvSound;
ConVar g_cvChat;
ConVar g_cvSaferoom;
ConVar g_cvRescue;
ConVar g_cvMechanism;
ConVar g_cvMechanismUnlocked;
ConVar g_cvMechRadius;
ConVar g_cvRevive;
ConVar g_cvReleaseSi;
ConVar g_cvRemoveInfected;
ConVar g_cvRescueForce;
ConVar g_cvVerbose;

// ---------------------------------------------------------------------------
// 区域数据（用 EntRef 保存，跨帧/跨回调安全）
// ---------------------------------------------------------------------------
int   g_iAreaRef[MAX_AREAS];
int   g_iAreaType[MAX_AREAS];
bool  g_bAreaFired[MAX_AREAS];
float g_vAreaPos[MAX_AREAS][3];
float g_fAreaCooldown[MAX_AREAS];
int   g_iAreaCount;

// ---------------------------------------------------------------------------
// 倒计时 / 监控状态
// ---------------------------------------------------------------------------
Handle g_hMonitor;              // 1s 重复监控 timer
Handle g_hCountdown;            // 1s 重复倒计时 timer
bool   g_bCountingDown;
int    g_iSecondsLeft;
int    g_iActiveArea = -1;

bool   g_bMapStarted;
bool   g_bLateLoad;
bool   g_bSacrificeFinale;
bool   g_bRescueReady;          // 救援车是否已到位（finale_vehicle_ready）

// ---------------------------------------------------------------------------
// 运行期 native 可用性
// ---------------------------------------------------------------------------
bool g_bNtvTouch;               // L4D_IsTouchingTrigger
bool g_bNtvFinalMap;            // L4D_IsMissionFinalMap
bool g_bNtvEscape;              // L4D_IsFinaleEscapeInProgress
bool g_bNtvNav;                 // L4D_GetNearestNavArea + L4D_FindRandomSpot
bool g_bNtvRevive;              // L4D_ReviveSurvivor
bool g_bNtvWarp;                // L4D_WarpToValidPositionIfStuck
bool g_bNtvDominating;          // L4D2_GetSpecialInfectedDominatingMe
bool g_bNtvRelease;             // 4 个解控 native
bool g_bNtvRescueVehicle;       // L4D2_SendInRescueVehicle

bool g_bReady;                  // 关键 native 齐全

public Plugin myinfo =
{
	name        = "L4D2 Checkpoint Teleport",
	author      = "apples1949",
	description = "集合点/安全屋/救援关 66% 生还者到齐后倒计时，结束时传送未到者并开启机关",
	version     = PLUGIN_VERSION,
	url         = ""
};

// ===========================================================================
//  插件生命周期
// ===========================================================================

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	if (GetEngineVersion() != Engine_Left4Dead2)
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 2.");
		return APLRes_SilentFailure;
	}

	g_bLateLoad = late;

	return APLRes_Success;
}

public void OnPluginStart()
{
	g_cvEnable = CreateConVar("l4d2_cptele_enable", "1",
		"1=启用「集合点/安全屋/救援关倒计时传送」插件。0=完全关闭（不侦测区域、不传送）",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvPercent = CreateConVar("l4d2_cptele_percent", "66",
		"触发倒计时所需的到达比例（%）。所需人数 = 向上取整(该比例 × 当前存活生还者数)。默认 66",
		FCVAR_NOTIFY, true, 1.0, true, 100.0);

	g_cvTime = CreateConVar("l4d2_cptele_time", "60",
		"到达比例达标后的倒计时秒数，倒计时结束时传送未到达的生还者",
		FCVAR_NOTIFY, true, 1.0, true, 600.0);

	g_cvResetOnLeave = CreateConVar("l4d2_cptele_reset_on_leave", "0",
		"0=倒计时开始后即使到达人数掉回比例以下也继续倒计时（默认）。1=掉回比例以下时取消本次倒计时，等人数再次达标后重新开始",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvSound = CreateConVar("l4d2_cptele_sound", "1",
		"1=倒计时期间每秒给全队播放提示音 buttons/blip1.wav。0=静音",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvChat = CreateConVar("l4d2_cptele_chat", "1",
		"1=倒计时开始与结束时在聊天框输出一行提示（HUD 提示不受此开关影响）。0=只留 HUD 提示",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvSaferoom = CreateConVar("l4d2_cptele_saferoom", "1",
		"1=启用关底安全屋（info_changelevel / trigger_changelevel）的集合传送。0=不处理安全屋。注意：本插件永远不会改动安全门本身",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvRescue = CreateConVar("l4d2_cptele_rescue", "1",
		"1=启用救援关（终局图 m_iEntireTeam==2 的 trigger_multiple）的集合传送。0=不处理救援关",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvMechanism = CreateConVar("l4d2_cptele_mechanism", "1",
		"1=启用机关集合点：玩家按下「被锁住的」func_button 时把该按钮登记为集合点，比例达标后倒计时并自动解锁+按下按钮。0=不处理机关",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvMechanismUnlocked = CreateConVar("l4d2_cptele_mechanism_unlocked", "0",
		"1=额外把「未上锁」的 func_button 正常按下（OnPressed）也当作机关集合点。默认 0：避免地图上普通按钮被误登记后把全队传送。仅在确认地图池存在未上锁的必经机关按钮时才建议打开",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvMechRadius = CreateConVar("l4d2_cptele_mech_radius", "600.0",
		"机关集合点的判定半径（三维距离，单位 HU）。生还者到按钮原点的距离小于该值即视为「已到达」",
		FCVAR_NOTIFY, true, 50.0, true, 5000.0);

	g_cvRevive = CreateConVar("l4d2_cptele_revive", "1",
		"1=传送前自动把挂在边缘（ledge hang）的生还者救起，避免传送到空中摔死。0=不处理",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvReleaseSi = CreateConVar("l4d2_cptele_release_si", "1",
		"1=传送前自动解除特感对生还者的控制（Smoker 拖拽 / Hunter 扑倒 / Jockey 骑乘 / Charger 冲撞与砸击），不杀死特感。0=不处理",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvRemoveInfected = CreateConVar("l4d2_cptele_remove_infected", "0",
		"1=传送结束后清理传送点周围 300 HU 内的 infected / witch。0=不清理（默认）",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvRescueForce = CreateConVar("l4d2_cptele_rescue_force", "0",
		"1=救援关倒计时结束时额外调用一次 L4D2_SendInRescueVehicle（强制叫车）。0=交给游戏自己判定（默认，推荐）",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvVerbose = CreateConVar("l4d2_cptele_verbose", "0",
		"1=在服务端控制台输出区域侦测与状态流转日志，用于进服排错。0=安静",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	CreateConVar("l4d2_cptele_version", PLUGIN_VERSION,
		"l4d2_checkpoint_teleport 版本号",
		FCVAR_NOTIFY|FCVAR_DONTRECORD);

	// 本仓库 12v12 插件的惯例：参数由模式 cfg 指定，不自动生成 cfg/sourcemod/*.cfg
	//AutoExecConfig(true, "l4d2_checkpoint_teleport");

	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
	HookEvent("finale_vehicle_ready", Event_FinaleVehicleReady, EventHookMode_PostNoCopy);

	// 机关集合点：OnUseLocked = 按下「被锁住的」按钮，这是参考A 的主路径，
	// 也是本插件真正想要的信号：游戏本来要求全员到齐才能按，插件给
	// 部分到场的玩家一条「倒计时后自动传送 + 开机关」的路。
	HookEntityOutput("func_button", "OnUseLocked", OnButtonUseLocked);

	// OnPressed = 按钮正常按下（未上锁的机关按钮走这条）。
	// 全局 hook OnPressed 有误报风险：地图上任何普通按钮被按一下都会被
	// 登记成集合点，随后路过的人凑够比例就会把全队传过去。
	// 因此默认关闭（l4d2_cptele_mechanism_unlocked=0），只在地图池里确实
	// 存在「未上锁的必经机关按钮」时才建议打开。
	HookEntityOutput("func_button", "OnPressed", OnButtonPressedOutput);

	RegConsoleCmd("sm_cptele", Cmd_Status, "查看集合点传送插件的区域侦测状态");
	RegAdminCmd("sm_cptele_force", Cmd_Force, ADMFLAG_GENERIC,
		"强制为最后一个侦测到的区域立刻开始倒计时（测试用）");

	ResetRound();
}

public void OnAllPluginsLoaded()
{
	// include 里这些都是 MarkNativeAsOptional，必须运行期复核
	g_bNtvTouch         = NtvAvailable("L4D_IsTouchingTrigger");
	g_bNtvFinalMap      = NtvAvailable("L4D_IsMissionFinalMap");
	g_bNtvEscape        = NtvAvailable("L4D_IsFinaleEscapeInProgress");
	g_bNtvRevive        = NtvAvailable("L4D_ReviveSurvivor");
	g_bNtvWarp          = NtvAvailable("L4D_WarpToValidPositionIfStuck");
	g_bNtvDominating    = NtvAvailable("L4D2_GetSpecialInfectedDominatingMe");
	g_bNtvRescueVehicle = NtvAvailable("L4D2_SendInRescueVehicle");

	g_bNtvNav = NtvAvailable("L4D_GetNearestNavArea") && NtvAvailable("L4D_FindRandomSpot");

	g_bNtvRelease = NtvAvailable("L4D_Smoker_ReleaseVictim")
	             && NtvAvailable("L4D_Hunter_ReleaseVictim")
	             && NtvAvailable("L4D2_Jockey_EndRide")
	             && NtvAvailable("L4D2_Charger_EndCarry")
	             && NtvAvailable("L4D2_Charger_EndPummel");

	// 关键：没有 IsTouchingTrigger 就无法判定安全屋 / 救援关
	g_bReady = g_bNtvTouch && g_bNtvFinalMap;

	if (!g_bReady)
	{
		LogError("[cptele] left4dhooks 关键 native 不可用 (L4D_IsTouchingTrigger=%d, L4D_IsMissionFinalMap=%d)，插件功能已停用。",
			g_bNtvTouch, g_bNtvFinalMap);
	}
	else if (g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] native 检查通过: touch=%d finalmap=%d nav=%d revive=%d warp=%d dom=%d release=%d rescue=%d",
			g_bNtvTouch, g_bNtvFinalMap, g_bNtvNav, g_bNtvRevive,
			g_bNtvWarp, g_bNtvDominating, g_bNtvRelease, g_bNtvRescueVehicle);
	}
}

public void OnMapStart()
{
	g_bMapStarted = true;
	g_bSacrificeFinale = false;

	PrecacheSound(SOUND_COUNTDOWN, true);

	ResetRound();

	// 插件晚加载（sm plugins load / 换图后手动加载）：此时本图的
	// round_start 早就过去了，不会再有事件，必须立刻补一次侦测，
	// 否则本回合完全不起作用。
	if (g_bLateLoad)
	{
		g_bLateLoad = false;
		CreateTimer(1.0, Timer_InitAreas, 0, TIMER_FLAG_NO_MAPCHANGE);
	}

	if (g_cvVerbose.BoolValue)
	{
		char sMap[128];
		GetCurrentMap(sMap, sizeof(sMap));
		PrintToServer("[cptele] OnMapStart: %s", sMap);
	}
}

public void OnMapEnd()
{
	ResetRound();
	g_bMapStarted = false;
	g_bSacrificeFinale = false;
}

// ===========================================================================
//  回合事件
// ===========================================================================

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	ResetRound();

	// 延迟侦测：等实体与 nav 稳定（参考 safearea_teleport 的延后初始化）
	CreateTimer(INIT_DELAY, Timer_InitAreas, 0, TIMER_FLAG_NO_MAPCHANGE);
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	ResetRound();
}

/**
 * 救援车到位。在此之前「救援关区域」不参与判定：
 * 终局战斗期间救援车触发器就在地图上，但那时候它没有任何意义，
 * 提前触发只会把正在打坦克的生还者直接传走。
 */
public void Event_FinaleVehicleReady(Event event, const char[] name, bool dontBroadcast)
{
	g_bRescueReady = true;

	if (g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] 救援车已到位，救援关区域开始参与判定");
	}
}

// ===========================================================================
//  区域侦测
// ===========================================================================

public Action Timer_InitAreas(Handle timer)
{
	if (!g_bMapStarted || !g_bReady || !g_cvEnable.BoolValue)
	{
		return Plugin_Stop;
	}

	DetectAreas();

	// 注意：监控 timer 必须无条件启动。终局救援图可能侦测不到安全屋区域，
	// 而机关集合点是玩家按按钮时才动态登记的，不能依赖 g_iAreaCount > 0。
	EnsureMonitor();

	return Plugin_Stop;
}

/**
 * 幂等地确保监控 timer 在跑。
 * Timer_InitAreas 与 OnButtonUseLocked 都会调用，保证动态登记的区域也能被监控。
 */
void EnsureMonitor()
{
	if (g_hMonitor != null)
	{
		return;
	}

	g_hMonitor = CreateTimer(MONITOR_INTERVAL, Timer_Monitor, 0,
		TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
}

void DetectAreas()
{
	// 只追加、不清空：机关集合点可能在 INIT_DELAY 之前就被按下登记，
	// 清空会丢掉它们。整份列表由 ResetRound() / OnMapEnd 统一重置。
	g_bSacrificeFinale = false;

	// ---- 1) 关底安全屋 --------------------------------------------------
	if (g_cvSaferoom.BoolValue)
	{
		int entity = FindEntityByClassname(-1, "info_changelevel");

		if (entity == -1)
		{
			entity = FindEntityByClassname(-1, "trigger_changelevel");
		}

		if (entity != -1)
		{
			AddArea(entity, AREA_SAFEROOM);

			if (g_cvVerbose.BoolValue)
			{
				PrintToServer("[cptele] 安全屋区域: entity #%d", entity);
			}
		}
		else if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 未找到 info_changelevel / trigger_changelevel");
		}
	}

	// ---- 2) 救援关 ------------------------------------------------------
	if (g_cvRescue.BoolValue && g_bNtvFinalMap && L4D_IsMissionFinalMap())
	{
		// 牺牲结局（c8m3 之类）没有救援车，直接跳过
		int finale = FindEntityByClassname(-1, "trigger_finale");

		if (finale != -1)
		{
			// m_bIsSacrificeFinale 是 (1 Bytes) 字段，必须显式传 size=1，
			// 否则会按默认 4 字节越界读取，把相邻字段的位读进来
			g_bSacrificeFinale = view_as<bool>(
				GetEntProp(finale, Prop_Data, "m_bIsSacrificeFinale", 1));
		}

		if (g_bSacrificeFinale)
		{
			if (g_cvVerbose.BoolValue)
			{
				PrintToServer("[cptele] 终局图为牺牲结局，跳过救援关区域");
			}
		}
		else
		{
			int entity = -1;

			while ((entity = FindEntityByClassname(entity, "trigger_multiple")) != -1)
			{
				if (GetEntProp(entity, Prop_Data, "m_iEntireTeam") != TEAM_SURVIVOR)
				{
					continue;
				}

				AddArea(entity, AREA_RESCUE);

				if (g_cvVerbose.BoolValue)
				{
					PrintToServer("[cptele] 救援关区域: trigger_multiple #%d", entity);
				}
			}
		}
	}

	if (g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] 本轮侦测到 %d 个区域", g_iAreaCount);
	}
}

/**
 * 登记一个区域。返回新区域的索引，重复或已满返回 -1。
 */
int AddArea(int entity, int type)
{
	if (entity <= 0 || !IsValidEntity(entity))
	{
		return -1;
	}

	if (g_iAreaCount >= MAX_AREAS)
	{
		LogError("[cptele] 区域数量超过上限 %d，忽略 entity #%d", MAX_AREAS, entity);
		return -1;
	}

	int ref = EntIndexToEntRef(entity);

	for (int i = 0; i < g_iAreaCount; i++)
	{
		if (g_iAreaRef[i] == ref)
		{
			return -1;
		}
	}

	int index = g_iAreaCount;

	g_iAreaRef[index] = ref;
	g_iAreaType[index] = type;
	g_bAreaFired[index] = false;
	g_fAreaCooldown[index] = 0.0;

	for (int j = 0; j < 3; j++)
	{
		g_vAreaPos[index][j] = 0.0;
	}

	if (type == AREA_MECHANISM)
	{
		GetEntityCenter(entity, g_vAreaPos[index]);
	}

	g_iAreaCount++;

	return index;
}

/**
 * 把 EntRef 解析成当前有效的实体索引，失效返回 -1。
 */
int GetAreaEntity(int index)
{
	int ref = g_iAreaRef[index];

	if (ref == 0)
	{
		return -1;
	}

	int entity = EntRefToEntIndex(ref);

	if (entity <= 0 || entity == INVALID_ENT_REFERENCE || !IsValidEntity(entity))
	{
		return -1;
	}

	return entity;
}

// ===========================================================================
//  机关集合点：按下被锁住的 func_button
// ===========================================================================

public void OnButtonPressedOutput(const char[] output, int caller, int activator, float delay)
{
	if (!g_cvMechanismUnlocked.BoolValue)
	{
		return;
	}

	RegisterMechanism(caller, activator);
}

public void OnButtonUseLocked(const char[] output, int caller, int activator, float delay)
{
	RegisterMechanism(caller, activator);
}

void RegisterMechanism(int caller, int activator)
{
	if (!g_bMapStarted || !g_bReady || !g_cvEnable.BoolValue || !g_cvMechanism.BoolValue)
	{
		return;
	}

	if (caller <= 0 || caller > GetMaxEntities() || !IsValidEntity(caller))
	{
		return;
	}

	char sClass[64];

	if (!GetEntityClassname(caller, sClass, sizeof(sClass)))
	{
		return;
	}

	if (!StrEqual(sClass, "func_button"))
	{
		return;
	}

	int index = AddArea(caller, AREA_MECHANISM);

	if (index == -1)
	{
		// 已经登记过（同一按钮被反复按），交给监控 timer 处理
		EnsureMonitor();
		return;
	}

	// 首次登记：保证监控 timer 在跑（本图可能一个静态区域都没侦测到）
	EnsureMonitor();

	if (g_cvVerbose.BoolValue)
	{
		float vPos[3];
		GetEntityCenter(caller, vPos);
		PrintToServer("[cptele] 注册机关集合点 #%d (func_button #%d @ %.0f %.0f %.0f)",
			index, caller, vPos[0], vPos[1], vPos[2]);
	}

	if (g_cvChat.BoolValue && activator > 0 && activator <= MaxClients && IsClientInGame(activator))
	{
		PrintToChatAll("\x05[集合点]\x01 机关按钮已被按下，需要 %d%% 的生还者到场（%d 秒倒计时）。",
			g_cvPercent.IntValue, g_cvTime.IntValue);
	}
}

// ===========================================================================
//  监控 + 倒计时
// ===========================================================================

public Action Timer_Monitor(Handle timer)
{
	if (!g_bMapStarted)
	{
		g_hMonitor = null;
		return Plugin_Stop;
	}

	if (!g_bReady || !g_cvEnable.BoolValue)
	{
		return Plugin_Continue;
	}

	// 倒计时期间由倒计时 timer 负责，这里不重复判
	if (g_bCountingDown || g_iAreaCount == 0)
	{
		return Plugin_Continue;
	}

	// 已经在逃离阶段：安全屋 / 机关集合点没必要再集合。
	// 但救援关正是「逃离阶段车辆到位后」才需要把掉队的传过去，
	// 所以这一条只对非救援区域生效（在下面的循环里逐区域判断）。
	bool bEscape = g_bNtvEscape && L4D_IsFinaleEscapeInProgress();

	int total = CountAliveSurvivors();

	if (total <= 0)
	{
		return Plugin_Continue;
	}

	int need = RequiredCount(total);

	for (int i = 0; i < g_iAreaCount; i++)
	{
		if (g_bAreaFired[i])
		{
			continue;
		}

		if (GetGameTime() < g_fAreaCooldown[i])
		{
			continue;
		}

		if (GetAreaEntity(i) == -1)
		{
			continue;
		}

		if (g_iAreaType[i] == AREA_RESCUE)
		{
			// 救援车到位之前，终局战斗里那座区域的触发器没有任何意义，
			// 提前触发会把正在打坦克的人直接传走。
			// bEscape 兜底：插件晚加载 / 漏接 finale_vehicle_ready 时，
			// 「逃离阶段已开始」本身就说明救援车已经到位了。
			if (!g_bRescueReady && !bEscape)
			{
				continue;
			}
		}
		else if (bEscape)
		{
			continue;
		}

		int reached = CountArrivedSurvivors(i);

		if (reached >= need)
		{
			StartCountdown(i, reached, total, need);
			break;
		}
	}

	return Plugin_Continue;
}

void StartCountdown(int index, int reached, int total, int need)
{
	if (g_bCountingDown)
	{
		return;
	}

	g_bCountingDown = true;
	g_iActiveArea = index;
	g_iSecondsLeft = g_cvTime.IntValue;

	if (g_cvChat.BoolValue)
	{
		PrintToChatAll("\x05[集合点]\x01 %d/%d 名生还者已到达（需要 %d 名），%d 秒后传送未到达的生还者。",
			reached, total, need, g_iSecondsLeft);
	}

	PrintHintTextToAll("%d 秒后传送未到达集合点的生还者", g_iSecondsLeft);

	if (g_cvSound.BoolValue)
	{
		EmitCountdownSound();
	}

	if (g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] 区域 #%d 开始倒计时 (reached=%d total=%d need=%d type=%d)",
			index, reached, total, need, g_iAreaType[index]);
	}

	delete g_hCountdown;
	g_hCountdown = CreateTimer(1.0, Timer_Countdown, 0,
		TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_Countdown(Handle timer)
{
	if (!g_bCountingDown)
	{
		g_hCountdown = null;
		return Plugin_Stop;
	}

	int index = g_iActiveArea;

	if (index < 0 || index >= g_iAreaCount)
	{
		CancelCountdown(-1);
		g_hCountdown = null;
		return Plugin_Stop;
	}

	// 掉回比例以下的处理策略
	if (g_cvResetOnLeave.BoolValue)
	{
		int total = CountAliveSurvivors();
		int need = RequiredCount(total);
		int reached = CountArrivedSurvivors(index);

		if (total <= 0 || reached < need)
		{
			if (g_cvChat.BoolValue)
			{
				PrintToChatAll("\x05[集合点]\x01 到场人数降到 %d/%d（需要 %d 名），倒计时取消。",
					reached, total, need);
			}

			PrintHintTextToAll("到场人数不足，倒计时取消");

			CancelCountdown(index);
			g_hCountdown = null;
			return Plugin_Stop;
		}
	}

	// 先递减再判断，保证总时长精确等于 l4d2_cptele_time 秒，
	// 且不会与 StartCountdown 里那次首播重复播报同一个秒数
	g_iSecondsLeft--;

	if (g_iSecondsLeft <= 0)
	{
		FinishCountdown(index);
		g_hCountdown = null;
		return Plugin_Stop;
	}

	PrintHintTextToAll("%d 秒后传送未到达集合点的生还者", g_iSecondsLeft);

	if (g_cvSound.BoolValue)
	{
		EmitCountdownSound();
	}

	return Plugin_Continue;
}

void CancelCountdown(int index)
{
	g_bCountingDown = false;
	g_iSecondsLeft = 0;
	g_iActiveArea = -1;

	if (index >= 0 && index < g_iAreaCount)
	{
		g_fAreaCooldown[index] = GetGameTime() + CANCEL_COOLDOWN;
	}

	if (g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] 倒计时取消 (区域 #%d)", index);
	}
}

void FinishCountdown(int index)
{
	g_bCountingDown = false;
	g_iSecondsLeft = 0;
	g_iActiveArea = -1;
	g_bAreaFired[index] = true;

	float vDest[3];
	bool bHasDest = GetAreaDestination(index, vDest);
	int moved = 0;

	if (bHasDest)
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			if (!IsAliveSurvivor(i))
			{
				continue;
			}

			if (IsClientInArea(i, index))
			{
				continue;
			}

			TeleportSurvivor(i, vDest);
			moved++;
		}
	}

	// ---- 开机关 ---------------------------------------------------------
	int type = g_iAreaType[index];

	if (type == AREA_MECHANISM)
	{
		int entity = GetAreaEntity(index);

		if (entity != -1)
		{
			// 与 alasfourom "L4D Elevator Teleport" 一致：先解锁再按下
			AcceptEntityInput(entity, "unlock");
			AcceptEntityInput(entity, "use");
		}
	}
	else if (type == AREA_RESCUE && g_cvRescueForce.BoolValue && g_bNtvRescueVehicle)
	{
		// 默认关闭：救援车人齐由游戏自己触发
		L4D2_SendInRescueVehicle();
	}
	// AREA_SAFEROOM：什么都不做。绝不触碰安全门的 spawnflags / lock 状态。

	if (g_cvRemoveInfected.BoolValue && bHasDest)
	{
		RemoveInfectedAround(vDest);
	}

	if (g_cvChat.BoolValue)
	{
		PrintToChatAll("\x05[集合点]\x01 倒计时结束，已传送 %d 名未到达的生还者。", moved);
	}

	if (g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] 区域 #%d 完成 (type=%d moved=%d dest=%d)", index, type, moved, bHasDest);
	}
}

// ===========================================================================
//  计数
// ===========================================================================

stock bool IsAliveSurvivor(int client)
{
	return IsClientInGame(client)
	    && GetClientTeam(client) == TEAM_SURVIVOR
	    && IsPlayerAlive(client);
}

int CountAliveSurvivors()
{
	int count = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsAliveSurvivor(i))
		{
			count++;
		}
	}

	return count;
}

int CountArrivedSurvivors(int index)
{
	int count = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsAliveSurvivor(i) && IsClientInArea(i, index))
		{
			count++;
		}
	}

	return count;
}

int RequiredCount(int total)
{
	if (total <= 0)
	{
		return 1;
	}

	int need = RoundToCeil(g_cvPercent.FloatValue / 100.0 * float(total));

	if (need < 1)
	{
		need = 1;
	}

	if (need > total)
	{
		need = total;
	}

	return need;
}

bool IsClientInArea(int client, int index)
{
	if (g_iAreaType[index] == AREA_MECHANISM)
	{
		float vClient[3];
		float vArea[3];

		GetClientAbsOrigin(client, vClient);
		CopyVec(g_vAreaPos[index], vArea);

		return GetVectorDistance(vClient, vArea) <= g_cvMechRadius.FloatValue;
	}

	int entity = GetAreaEntity(index);

	if (entity == -1 || !g_bNtvTouch)
	{
		return false;
	}

	return L4D_IsTouchingTrigger(entity, client);
}

// ===========================================================================
//  传送
// ===========================================================================

bool GetAreaDestination(int index, float vDest[3])
{
	int candidates[MAXPLAYERS];
	int count = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsAliveSurvivor(i) && IsClientInArea(i, index))
		{
			candidates[count++] = i;
		}
	}

	// ---- 1) 已经站在区域内的生还者位置（最可靠） -------------------------
	if (count > 0)
	{
		int pick = candidates[GetRandomInt(0, count - 1)];
		GetClientAbsOrigin(pick, vDest);

		// 轻微抖动，避免整队叠在一个点上互相挤
		vDest[0] += GetRandomFloat(-24.0, 24.0);
		vDest[1] += GetRandomFloat(-24.0, 24.0);

		return true;
	}

	// ---- 2) 区域原点 -> 最近 nav area 的随机点 ---------------------------
	float vOrigin[3];

	if (g_iAreaType[index] == AREA_MECHANISM)
	{
		CopyVec(g_vAreaPos[index], vOrigin);
	}
	else
	{
		int entity = GetAreaEntity(index);

		if (entity == -1)
		{
			return false;
		}

		GetEntityCenter(entity, vOrigin);
	}

	if (g_bNtvNav)
	{
		int nav = view_as<int>(L4D_GetNearestNavArea(vOrigin, 1000.0, true));

		if (nav)
		{
			L4D_FindRandomSpot(nav, vDest);

			if (vDest[0] != 0.0 || vDest[1] != 0.0 || vDest[2] != 0.0)
			{
				return true;
			}
		}
	}

	// ---- 3) 兜底：直接站在区域原点 ---------------------------------------
	CopyVec(vOrigin, vDest);

	return true;
}

void TeleportSurvivor(int client, const float vDest[3])
{
	if (g_cvReleaseSi.BoolValue)
	{
		ReleaseDominated(client);
	}

	if (g_cvRevive.BoolValue && g_bNtvRevive && L4D_IsPlayerHangingFromLedge(client))
	{
		L4D_ReviveSurvivor(client);
	}

	// 解冻 + 缩小碰撞体积，避免传送进天花板 / 卡在几何体里
	SetEntityMoveType(client, MOVETYPE_WALK);
	SetEntityFlags(client, GetEntityFlags(client) & ~FL_FROZEN);
	SetEntProp(client, Prop_Send, "m_bDucked", 1);
	SetEntityFlags(client, GetEntityFlags(client) | FL_DUCKING);

	TeleportEntity(client, vDest, NULL_VECTOR, NULL_VECTOR);

	if (g_bNtvWarp)
	{
		L4D_WarpToValidPositionIfStuck(client);
	}
}

/**
 * 解除特感对生还者的控制。不杀死任何玩家。
 */
void ReleaseDominated(int client)
{
	if (!g_bNtvDominating || !g_bNtvRelease)
	{
		return;
	}

	int attacker = L4D2_GetSpecialInfectedDominatingMe(client);

	if (attacker < 1 || attacker > MaxClients)
	{
		return;
	}

	if (!IsClientInGame(attacker) || GetClientTeam(attacker) != TEAM_INFECTED)
	{
		return;
	}

	if (GetEntProp(attacker, Prop_Send, "m_tongueVictim") > 0)
	{
		L4D_Smoker_ReleaseVictim(client, attacker);
	}
	else if (GetEntProp(attacker, Prop_Send, "m_pounceVictim") > 0)
	{
		L4D_Hunter_ReleaseVictim(client, attacker);
	}
	else if (GetEntProp(attacker, Prop_Send, "m_jockeyVictim") > 0)
	{
		L4D2_Jockey_EndRide(client, attacker);
	}
	else if (GetEntProp(attacker, Prop_Send, "m_carryVictim") > 0)
	{
		L4D2_Charger_EndCarry(client, attacker);
	}
	else if (GetEntProp(attacker, Prop_Send, "m_pummelVictim") > 0)
	{
		L4D2_Charger_EndPummel(client, attacker);
	}
}

void RemoveInfectedAround(const float vPos[3])
{
	float vEnt[3];
	int maxEntities = GetMaxEntities();

	for (int i = MaxClients + 1; i < maxEntities; i++)
	{
		if (!IsValidEntity(i))
		{
			continue;
		}

		char sClass[64];

		if (!GetEntityClassname(i, sClass, sizeof(sClass)))
		{
			continue;
		}

		if (!StrEqual(sClass, "infected") && !StrEqual(sClass, "witch"))
		{
			continue;
		}

		GetEntPropVector(i, Prop_Send, "m_vecOrigin", vEnt);

		if (GetVectorDistance(vEnt, vPos) <= INFECTED_CLEAR_RADIUS)
		{
			RemoveEntity(i);
		}
	}
}

// ===========================================================================
//  指令 / 工具
// ===========================================================================

public Action Cmd_Status(int client, int args)
{
	char sType[16];
	int total = CountAliveSurvivors();
	int need = RequiredCount(total);

	ReplyToCommand(client, "[cptele] enable=%d ready=%d 区域数=%d 存活生还者=%d 需要到达=%d%%(%d名) 倒计时=%d秒",
		g_cvEnable.BoolValue, g_bReady, g_iAreaCount, total,
		g_cvPercent.IntValue, need, g_cvTime.IntValue);

	for (int i = 0; i < g_iAreaCount; i++)
	{
		// SourcePawn 的 switch 不会 case 贯穿（每支隐式结束），无需 break
		switch (g_iAreaType[i])
		{
			case AREA_SAFEROOM:  strcopy(sType, sizeof(sType), "安全屋");
			case AREA_RESCUE:    strcopy(sType, sizeof(sType), "救援关");
			case AREA_MECHANISM: strcopy(sType, sizeof(sType), "机关点");
			default:             strcopy(sType, sizeof(sType), "未知");
		}

		ReplyToCommand(client, "  #%d %s ent=%d 已到达=%d 已触发=%d",
			i, sType, GetAreaEntity(i), CountArrivedSurvivors(i), g_bAreaFired[i]);
	}

	if (g_bCountingDown)
	{
		ReplyToCommand(client, "  倒计时进行中：区域 #%d，剩余 %d 秒", g_iActiveArea, g_iSecondsLeft);
	}

	return Plugin_Handled;
}

public Action Cmd_Force(int client, int args)
{
	if (!g_bReady)
	{
		ReplyToCommand(client, "[cptele] 插件未就绪（left4dhooks native 缺失）");
		return Plugin_Handled;
	}

	if (!g_cvEnable.BoolValue)
	{
		ReplyToCommand(client, "[cptele] 插件总开关已关闭（l4d2_cptele_enable 0）");
		return Plugin_Handled;
	}

	if (g_iAreaCount == 0)
	{
		ReplyToCommand(client, "[cptele] 还没有侦测到任何区域");
		return Plugin_Handled;
	}

	if (g_bCountingDown)
	{
		ReplyToCommand(client, "[cptele] 已经在倒计时中（区域 #%d，剩余 %d 秒），忽略",
			g_iActiveArea, g_iSecondsLeft);
		return Plugin_Handled;
	}

	// 可用 sm_cptele_force <区域序号> 指定区域；省略时取最后一个
	int index = g_iAreaCount - 1;

	if (args >= 1)
	{
		index = GetCmdArgInt(1);

		if (index < 0 || index >= g_iAreaCount)
		{
			ReplyToCommand(client, "[cptele] 区域序号越界，有效范围 0..%d", g_iAreaCount - 1);
			return Plugin_Handled;
		}
	}

	int total = CountAliveSurvivors();
	int need = RequiredCount(total);

	StartCountdown(index, CountArrivedSurvivors(index), total, need);

	ReplyToCommand(client, "[cptele] 已强制对区域 #%d 开始倒计时", index);

	return Plugin_Handled;
}

stock bool NtvAvailable(const char[] name)
{
	return GetFeatureStatus(FeatureType_Native, name) == FeatureStatus_Available;
}

/**
 * 播放倒计时提示音。
 *
 * 逐个客户端调用 EmitSoundToClient，而不是 EmitSoundToAll(…, SOUND_FROM_PLAYER …)：
 * SOUND_FROM_PLAYER(-2) 语义是「以接收者自身为发声实体」，只有单客户端调用时
 * 才能被正确解析；一次性传给多个客户端时 -2 不是合法实体索引，表现为听不到声。
 * 参考A / 参考B 也都是逐客户端播放的。
 */
stock void EmitCountdownSound()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
		{
			continue;
		}

		EmitSoundToClient(i, SOUND_COUNTDOWN, SOUND_FROM_PLAYER, SNDCHAN_STATIC,
			SNDLEVEL_NORMAL, SND_NOFLAGS, SNDVOL_NORMAL, SNDPITCH_NORMAL);
	}
}

stock void CopyVec(const float src[3], float dst[3])
{
	dst[0] = src[0];
	dst[1] = src[1];
	dst[2] = src[2];
}

/**
 * 取实体的「几何中心」。
 *
 * brush 实体（trigger_multiple / info_changelevel / trigger_finale）的
 * m_vecOrigin 往往是 (0,0,0)，真正的体积写在 m_vecMins / m_vecMaxs 里，
 * 而且这两个值已经是世界坐标。点实体（如部分 func_button）反过来是
 * m_vecOrigin 有值、mins/maxs 为 0。
 *
 * center = origin + (mins + maxs) / 2 同时覆盖两种情况：
 * 点实体因为 mins = maxs = 0，结果就是 origin。
 */
stock void GetEntityCenter(int entity, float vCenter[3])
{
	float vOrigin[3];
	float vMins[3];
	float vMaxs[3];

	GetEntPropVector(entity, Prop_Send, "m_vecOrigin", vOrigin);
	GetEntPropVector(entity, Prop_Send, "m_vecMins", vMins);
	GetEntPropVector(entity, Prop_Send, "m_vecMaxs", vMaxs);

	for (int i = 0; i < 3; i++)
	{
		vCenter[i] = vOrigin[i] + (vMins[i] + vMaxs[i]) * 0.5;
	}
}

void ResetRound()
{
	delete g_hCountdown;
	g_hCountdown = null;

	delete g_hMonitor;
	g_hMonitor = null;

	g_bCountingDown = false;
	g_iSecondsLeft = 0;
	g_iActiveArea = -1;
	g_bRescueReady = false;

	for (int i = 0; i < MAX_AREAS; i++)
	{
		g_iAreaRef[i] = 0;
		g_iAreaType[i] = AREA_SAFEROOM;
		g_bAreaFired[i] = false;
		g_fAreaCooldown[i] = 0.0;

		for (int j = 0; j < 3; j++)
		{
			g_vAreaPos[i][j] = 0.0;
		}
	}

	g_iAreaCount = 0;
}
