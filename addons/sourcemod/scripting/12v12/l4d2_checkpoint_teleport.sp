/**
 * ============================================================================
 *  l4d2_checkpoint_teleport.sp  -  Setpoint / saferoom / rescue auto-teleport
 * ============================================================================
 *  applemod12v12 (12v12 versus) 定制插件
 *
 *  需求：
 *    在「安全屋 / 救援点 / 地图中途集合点」这些区域，剩余存活生还者的指定
 *    百分比到齐后开始倒计时；倒计时结束时把还没到的生还者传送进该区域，
 *    并开启对应的机关（电梯按钮 / 开关等）。
 *    —— 绝不改动安全门（safe room door）的 spawnflags / lock 状态，
 *       救援车人齐与否由游戏自己判定。
 *
 *  两类区域：倒计时、到齐比例、提示文案互相独立。 ---------------------------------
 *    A) 安全屋 + 救援点：l4d2_cptele_time              （默认 60 秒）
 *                        l4d2_cptele_percent           （默认 66%）
 *                        —— 保持插件原有设定，不做改动
 *    B) 地图中途集合点：l4d2_cptele_checkpoint_time    （默认 30 秒）
 *                        l4d2_cptele_checkpoint_percent（默认 50%）
 *
 *  集合点区域来源（按优先级；命中高优先级就不再往下一层找中途集合点）： --------
 *    1) 预设地图配置   addons/sourcemod/configs/l4d2_cptele_presets.cfg
 *                      （KeyValues，按地图预置：targetname 实体 / 坐标+半径 /
 *                        固定传送点）。命中本图即以预设为准。
 *    2) 原版按地点检测 内置表（GetLegacySite），搬自 alasfourom
 *                      "L4D Elevator Teleport" 的「地图 → 机关实体 + 传送点」，
 *                      只在预设没有命中本图时才启用。
 *    3) 运行时自动侦测 安全屋 info_changelevel（退回 trigger_changelevel）、
 *                      救援关 m_iEntireTeam == 2 的 trigger_multiple、
 *                      玩家按下「锁住的」func_button 时登记该按钮
 *                      （监听 func_button 的 OnUseLocked 输出）。
 *
 *    安全屋 / 救援点区域始终由第 3 层自动侦测提供（这两类全图通用），
 *    预设文件也可以显式指定 saferoom / rescue 类型的区域。
 *    第 1、2 层一旦提供中途集合点，动态按钮登记会被忽略，避免同一张图上
 *    出现两个互相竞争的集合点。l4d2_cptele_verbose 1 时控制台会打印
 *    每个区域最终走的哪条路径（预设 / 原版地点 / 自动侦测）与回落原因。
 *    排错命令：sm_cptele 查看每个区域的「类型 / 来源 / 已到达人数」，
 *              sm_cptele_reload 重读预设文件并立即重新侦测。
 *
 *  「是否已到达」判定：
 *    - 安全屋 / 救援点 / trigger 类区域：L4D_IsTouchingTrigger(区域实体, client)
 *      （left4dhooks 内部就是 CBaseTrigger::IsTouching，与
 *        L4D_IsInLastCheckpoint 用的是同一条路径）
 *    - 按钮 / 坐标类集合点：玩家到区域中心的三维距离 <= 半径
 *      （半径 = 预设里的 radius；未写时用 l4d2_cptele_mech_radius）
 *
 *  传送目标点（优先级从高到低）：
 *    1) 预设 / 原版内置表给的固定传送点（dest）
 *    2) 已经站在区域内的存活生还者位置（一定可以站立）
 *    3) 区域实体 / 区域中心，用 L4D_GetNearestNavArea +
 *       L4D_FindRandomSpot 取该 nav area 上的随机点
 *    4) 都失败则退化为区域原点本身
 *    传送后统一调用 L4D_WarpToValidPositionIfStuck 兜底。全程不触碰安全门。
 *
 *  状态机：
 *    round_start(延时 3s) -> 侦测区域（预设 -> 原版地点 -> 自动侦测）
 *      -> 1s/次 监控 timer -> 某区域到达人数 >= ceil(该类型比例% × 存活生还者数)
 *      -> 开始该类型的倒计时 -> 倒计时结束 -> 传送未到者 + 开机关
 *      -> 该区域标记为已触发
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

#define PLUGIN_VERSION      "1.1.0"

#define SOUND_COUNTDOWN     "buttons/blip1.wav"

#define TEAM_SURVIVOR       2
#define TEAM_INFECTED       3

#define MAX_AREAS           32          // 一张图最多同时监控的区域数
#define MONITOR_INTERVAL    1.0         // 区域监控间隔（秒）
#define INIT_DELAY          3.0         // round_start 后延迟多久侦测实体
#define CANCEL_COOLDOWN     10.0        // 倒计时被取消后，该区域的冷静期
#define INFECTED_CLEAR_RADIUS 300.0     // 清理传送点周围特感的半径
#define DEST_JITTER         32.0        // 固定传送点附近的散开抖动（HU）

#define PRESET_DEFAULT_FILE "l4d2_cptele_presets.cfg"   // 预设文件名（相对 configs/）

// 预设槽位解析结果：LoadPresetSlot 的返回值
#define PRESET_SLOT_NONE        0       // 未登记（配置写错 / 实体找不到 / 区域已满）
#define PRESET_SLOT_OTHER       1       // 登记了安全屋 / 救援点
#define PRESET_SLOT_CHECKPOINT  2       // 登记了中途集合点

// ---------------------------------------------------------------------------
// 区域类型：决定用哪一组 cvar 与哪一套提示文案
// ---------------------------------------------------------------------------
enum
{
	AREA_SAFEROOM = 0,      // 关底安全屋（info_changelevel / trigger_changelevel）
	AREA_RESCUE,            // 救援点（终局救援车 / 救援关触发器）
	AREA_CHECKPOINT         // 地图中途集合点（预设点 / 原版地点 / 机关按钮）
};

// ---------------------------------------------------------------------------
// 区域来源：只影响日志与 sm_cptele 的显示，说明走了哪条检测路径
// ---------------------------------------------------------------------------
enum
{
	SRC_AUTO = 0,           // 运行时自动侦测
	SRC_LEGACY,             // 原版按地点检测（内置表）
	SRC_PRESET              // 预设地图配置
};

// ---------------------------------------------------------------------------
// ConVar
// ---------------------------------------------------------------------------
ConVar g_cvEnable;
ConVar g_cvPercent;             // 安全屋 / 救援点 到齐比例
ConVar g_cvTime;                // 安全屋 / 救援点 倒计时
ConVar g_cvCpPercent;           // 中途集合点 到齐比例
ConVar g_cvCpTime;              // 中途集合点 倒计时
ConVar g_cvResetOnLeave;
ConVar g_cvSound;
ConVar g_cvChat;
ConVar g_cvSaferoom;
ConVar g_cvRescue;
ConVar g_cvMechanism;
ConVar g_cvMechanismUnlocked;
ConVar g_cvMechRadius;
ConVar g_cvPreset;              // 预设地图检测
ConVar g_cvPresetFile;
ConVar g_cvLegacy;              // 原版按地点检测（内置表）
ConVar g_cvRevive;
ConVar g_cvReleaseSi;
ConVar g_cvRemoveInfected;
ConVar g_cvRescueForce;
ConVar g_cvVerbose;

// ---------------------------------------------------------------------------
// 区域数据（用 EntRef 保存，跨帧/跨回调安全）
// ---------------------------------------------------------------------------
int   g_iAreaRef[MAX_AREAS];        // 0 = 纯坐标区域（无实体）
int   g_iAreaType[MAX_AREAS];       // AREA_*
int   g_iAreaSource[MAX_AREAS];     // SRC_*
bool  g_bAreaFired[MAX_AREAS];
bool  g_bAreaCoord[MAX_AREAS];      // 纯坐标区域，不依赖实体
bool  g_bAreaRadius[MAX_AREAS];     // 用距离判定（否则用 L4D_IsTouchingTrigger）
float g_vAreaPos[MAX_AREAS][3];     // 距离判定的中心点
float g_fAreaRadius[MAX_AREAS];     // 距离判定的半径（<=0 用 l4d2_cptele_mech_radius）
bool  g_bAreaDest[MAX_AREAS];       // 是否带固定传送点
float g_vAreaDest[MAX_AREAS][3];    // 固定传送点
float g_fAreaCooldown[MAX_AREAS];
int   g_iAreaCount;

// ---------------------------------------------------------------------------
// 预设地图配置（每张图读一次，换图释放）
// ---------------------------------------------------------------------------
KeyValues g_hPresets;
bool      g_bPresetsTried;

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
bool   g_bSiteAuthority;        // 本图集合点已由「预设 / 原版地点」提供

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
	description = "安全屋/救援点/中途集合点按类型分别倒计时，结束时传送未到者并开启机关",
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

	// ---- A 组：安全屋 / 救援点（保持插件原有名字与默认值） -----------------
	g_cvPercent = CreateConVar("l4d2_cptele_percent", "66",
		"[安全屋/救援点] 触发倒计时所需的到达比例（%）。所需人数 = 向上取整(该比例 × 当前存活生还者数)。默认 66（原有设定）。中途集合点请用 l4d2_cptele_checkpoint_percent",
		FCVAR_NOTIFY, true, 1.0, true, 100.0);

	g_cvTime = CreateConVar("l4d2_cptele_time", "60",
		"[安全屋/救援点] 到达比例达标后的倒计时秒数，倒计时结束时传送未到达的生还者。默认 60（原有设定）。中途集合点请用 l4d2_cptele_checkpoint_time",
		FCVAR_NOTIFY, true, 1.0, true, 600.0);

	// ---- B 组：地图中途集合点（预设点 / 原版地点 / 机关按钮） --------------
	g_cvCpPercent = CreateConVar("l4d2_cptele_checkpoint_percent", "50",
		"[中途集合点] 触发倒计时所需的到达比例（%）。所需人数 = 向上取整(该比例 × 当前存活生还者数)。默认 50",
		FCVAR_NOTIFY, true, 1.0, true, 100.0);

	g_cvCpTime = CreateConVar("l4d2_cptele_checkpoint_time", "30",
		"[中途集合点] 到达比例达标后的倒计时秒数，倒计时结束时传送未到达的生还者并开启机关。默认 30",
		FCVAR_NOTIFY, true, 1.0, true, 600.0);

	// ---- 检测来源 ---------------------------------------------------------
	g_cvPreset = CreateConVar("l4d2_cptele_preset", "1",
		"1=优先使用预设地图配置（configs 下的 KeyValues 文件）判定地图中途集合点，命中后不再走原版地点表与动态按钮登记。0=不读预设文件",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvPresetFile = CreateConVar("l4d2_cptele_preset_file", PRESET_DEFAULT_FILE,
		"预设地图配置文件名，相对 addons/sourcemod/configs/。文件不存在时静默跳过（不报错），自动回落到原版地点表 / 运行时侦测",
		FCVAR_NOTIFY);

	g_cvLegacy = CreateConVar("l4d2_cptele_legacy", "1",
		"1=启用「原版按地点检测」内置表（搬自 L4D Elevator Teleport：已知电梯/机关图的地图名 → 机关 targetname + 传送点）。仅在预设没有命中本图时生效。0=只用预设与运行时侦测",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// ---- 通用行为 ---------------------------------------------------------
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
		"1=启用「运行时自动侦测」的机关集合点：玩家按下被锁住的 func_button 时把该按钮登记为集合点，比例达标后倒计时并自动解锁+按下按钮。预设或原版地点已覆盖本图时不生效",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvMechanismUnlocked = CreateConVar("l4d2_cptele_mechanism_unlocked", "0",
		"1=额外把「未上锁」的 func_button 正常按下（OnPressed）也当作机关集合点。默认 0：避免地图上普通按钮被误登记后把全队传送。仅在确认地图池存在未上锁的必经机关按钮时才建议打开",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvMechRadius = CreateConVar("l4d2_cptele_mech_radius", "600.0",
		"按钮/坐标类集合点的默认判定半径（三维距离，单位 HU）。生还者到区域中心的距离小于该值即视为「已到达」。预设里写了 radius 时以预设为准",
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
		"1=在服务端控制台输出区域侦测（走了预设 / 原版地点 / 自动侦测哪条路径）与状态流转日志，用于进服排错。0=安静",
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
	RegAdminCmd("sm_cptele_reload", Cmd_ReloadPresets, ADMFLAG_GENERIC,
		"重新读取预设地图配置并立即重新侦测区域（测试/排错用）");
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

	// 换图重新读预设文件（文件可能刚被改过）
	delete g_hPresets;
	g_hPresets = null;
	g_bPresetsTried = false;

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

	delete g_hPresets;
	g_hPresets = null;
	g_bPresetsTried = false;

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
//  区域侦测入口
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

/**
 * 侦测顺序（重要）：
 *   1) 预设地图配置   —— 优先
 *   2) 原版按地点检测 —— 仅当预设没有给出中途集合点
 *   3) 运行时自动侦测 —— 安全屋 / 救援点始终走这条；中途集合点由
 *                        OnUseLocked 动态登记（受 g_bSiteAuthority 抑制）
 */
void DetectAreas()
{
	// 只追加、不清空：机关集合点可能在 INIT_DELAY 之前就被按下登记，
	// 清空会丢掉它们。整份列表由 ResetRound() / OnMapEnd 统一重置。
	g_bSacrificeFinale = false;
	g_bSiteAuthority = false;

	int iSiteAreas = 0;     // 预设/原版地点总共贡献多少个区域
	int iSiteCp = 0;        // 其中「中途集合点」有多少个（决定是否抑制动态登记）

	char sSiteOwner[32];
	strcopy(sSiteOwner, sizeof(sSiteOwner), "运行时侦测");

	// ---- 1) 预设地图配置 ------------------------------------------------
	if (g_cvPreset.BoolValue)
	{
		int iPresetCp = 0;

		iSiteAreas += LoadPresetAreas(iPresetCp);

		if (iPresetCp > 0)
		{
			iSiteCp += iPresetCp;
			strcopy(sSiteOwner, sizeof(sSiteOwner), "预设配置");
		}
	}

	// ---- 2) 原版按地点检测（内置表） ------------------------------------
	if (iSiteCp == 0 && g_cvLegacy.BoolValue)
	{
		int iLegacy = LoadLegacySite();

		iSiteAreas += iLegacy;

		if (iLegacy > 0)
		{
			iSiteCp += iLegacy;
			strcopy(sSiteOwner, sizeof(sSiteOwner), "原版地点表");
		}
	}

	g_bSiteAuthority = (iSiteCp > 0);

	if (g_bSiteAuthority && g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] 本图中途集合点来源: %s，忽略动态按钮登记", sSiteOwner);
	}

	// ---- 3a) 关底安全屋 --------------------------------------------------
	if (g_cvSaferoom.BoolValue)
	{
		int entity = FindEntityByClassname(-1, "info_changelevel");

		if (entity == -1)
		{
			entity = FindEntityByClassname(-1, "trigger_changelevel");
		}

		if (entity != -1)
		{
			AddArea(entity, AREA_SAFEROOM, SRC_AUTO, NULL_VECTOR, 0.0, NULL_VECTOR, false);

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

	// ---- 3b) 救援关 -----------------------------------------------------
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

				AddArea(entity, AREA_RESCUE, SRC_AUTO, NULL_VECTOR, 0.0, NULL_VECTOR, false);

				if (g_cvVerbose.BoolValue)
				{
					PrintToServer("[cptele] 救援关区域: trigger_multiple #%d", entity);
				}
			}
		}
	}

	if (g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] 本轮侦测到 %d 个区域（其中预设/原版地点贡献 %d 个，集合点权威=%d）",
			g_iAreaCount, iSiteAreas, g_bSiteAuthority);

		char sType[16];
		char sSrc[16];

		for (int i = 0; i < g_iAreaCount; i++)
		{
			GetAreaTypeName(g_iAreaType[i], sType, sizeof(sType));
			GetAreaSourceName(g_iAreaSource[i], sSrc, sizeof(sSrc));

			PrintToServer("[cptele]   区域 #%d 类型=%s 来源=%s 实体=%d 距离判定=%d 固定传送点=%d",
				i, sType, sSrc, GetAreaEntity(i), g_bAreaRadius[i], g_bAreaDest[i]);
		}
	}
}

/**
 * 登记一个区域。
 *
 * @param entity    区域实体；<=0 表示「纯坐标区域」（预设里只写了 origin/radius）
 * @param type      AREA_SAFEROOM / AREA_RESCUE / AREA_CHECKPOINT
 * @param source    SRC_AUTO / SRC_LEGACY / SRC_PRESET
 * @param vPos      纯坐标区域的中心点（有实体时传 NULL_VECTOR）
 * @param fRadius   距离判定半径（<=0 用 l4d2_cptele_mech_radius）
 * @param vDest     固定传送点（无则传 NULL_VECTOR）
 * @param bHasDest  是否真的带固定传送点
 * @return          新区域的索引，重复/非法/已满返回 -1
 */
int AddArea(int entity, int type, int source, const float vPos[3],
	float fRadius, const float vDest[3], bool bHasDest)
{
	bool bCoord = (entity <= 0);

	if (!bCoord && !IsValidEntity(entity))
	{
		return -1;
	}

	if (g_iAreaCount >= MAX_AREAS)
	{
		LogError("[cptele] 区域数量超过上限 %d，忽略 entity #%d", MAX_AREAS, entity);
		return -1;
	}

	// 纯坐标区域必须给一个像样的坐标，(0,0,0) 视作配置写错
	if (bCoord && vPos[0] == 0.0 && vPos[1] == 0.0 && vPos[2] == 0.0)
	{
		return -1;
	}

	int ref = bCoord ? 0 : EntIndexToEntRef(entity);

	if (!bCoord)
	{
		for (int i = 0; i < g_iAreaCount; i++)
		{
			if (g_iAreaRef[i] != 0 && g_iAreaRef[i] == ref)
			{
				return -1;
			}
		}
	}

	int index = g_iAreaCount;

	g_iAreaRef[index] = ref;
	g_iAreaType[index] = type;
	g_iAreaSource[index] = source;
	g_bAreaFired[index] = false;
	g_bAreaCoord[index] = bCoord;
	g_bAreaDest[index] = bHasDest;
	g_fAreaCooldown[index] = 0.0;
	g_fAreaRadius[index] = (fRadius > 0.0) ? fRadius : 0.0;   // <=0 表示用全局默认半径

	for (int j = 0; j < 3; j++)
	{
		g_vAreaPos[index][j] = 0.0;
		g_vAreaDest[index][j] = 0.0;
	}

	if (bHasDest)
	{
		CopyVec(vDest, g_vAreaDest[index]);
	}

	// ---- 判定方式：trigger / changelevel 用 IsTouching，其余用距离 --------
	if (bCoord)
	{
		CopyVec(vPos, g_vAreaPos[index]);
		g_bAreaRadius[index] = true;
	}
	else
	{
		char sClass[64];

		if (GetEntityClassname(entity, sClass, sizeof(sClass)) && IsTouchModeClass(sClass))
		{
			g_bAreaRadius[index] = false;
		}
		else
		{
			g_bAreaRadius[index] = true;
			GetEntityCenter(entity, g_vAreaPos[index]);
		}
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

/**
 * 区域是否还活着：纯坐标区域永远活着，实体区域要看实体是否还在。
 */
bool IsAreaAlive(int index)
{
	if (g_bAreaCoord[index])
	{
		return true;
	}

	return GetAreaEntity(index) != -1;
}

// ===========================================================================
//  检测路径 1：预设地图配置（KeyValues）
// ===========================================================================

/**
 * 读取预设文件。文件不存在属于正常情况（不报错、不打日志刷屏），
 * 交由上一级回落到原版地点表 / 运行时侦测。
 */
void LoadPresets()
{
	g_bPresetsTried = true;

	delete g_hPresets;
	g_hPresets = null;

	char sFile[PLATFORM_MAX_PATH];
	char sPath[PLATFORM_MAX_PATH];

	g_cvPresetFile.GetString(sFile, sizeof(sFile));
	TrimString(sFile);

	if (sFile[0] == '\0')
	{
		strcopy(sFile, sizeof(sFile), PRESET_DEFAULT_FILE);
	}

	BuildPath(Path_SM, sPath, sizeof(sPath), "configs/%s", sFile);

	if (!FileExists(sPath, false))
	{
		if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 未找到预设文件 %s，自动回落到原版地点表 / 运行时侦测", sPath);
		}

		return;
	}

	KeyValues kv = CreateKeyValues("cptele_presets");

	if (!FileToKeyValues(kv, sPath))
	{
		delete kv;
		LogError("[cptele] 预设文件 %s 解析失败（KeyValues 语法错误？），本图忽略预设配置", sPath);
		return;
	}

	g_hPresets = kv;

	if (g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] 已载入预设文件 %s", sPath);
	}
}

/**
 * 从预设文件里取出当前地图的区域。
 *
 * @param iCheckpoints  输出：其中「中途集合点」类型的个数
 * @return              成功登记的区域总数
 */
int LoadPresetAreas(int &iCheckpoints)
{
	iCheckpoints = 0;

	if (!g_cvPreset.BoolValue)
	{
		return 0;
	}

	if (g_hPresets == null)
	{
		if (g_bPresetsTried)
		{
			return 0;
		}

		LoadPresets();

		if (g_hPresets == null)
		{
			return 0;
		}
	}

	char sMap[128];
	GetCurrentMap(sMap, sizeof(sMap));

	g_hPresets.Rewind();

	if (!g_hPresets.JumpToKey(sMap))
	{
		if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 预设文件里没有本图 %s 的配置，回落到原版地点表 / 运行时侦测", sMap);
		}

		// 回到根节点，避免下次 Rewind 之外的读取踩到子节点
		g_hPresets.Rewind();

		return 0;
	}

	if (!g_hPresets.GotoFirstSubKey())
	{
		g_hPresets.Rewind();
		return 0;
	}

	int iAdded = 0;

	do
	{
		char sSlot[64];
		g_hPresets.GetSectionName(sSlot, sizeof(sSlot));

		int iResult = LoadPresetSlot(sMap, sSlot);

		if (iResult > 0)
		{
			iAdded++;

			if (iResult == PRESET_SLOT_CHECKPOINT)
			{
				iCheckpoints++;
			}
		}
	}
	while (g_hPresets.GotoNextKey());

	g_hPresets.Rewind();

	return iAdded;
}

/**
 * 解析并登记预设文件里的一个槽位（一个槽位 = 一个集合点）。
 *
 * 支持两种写法：
 *   1) 坐标写法：origin + radius，地图上没有任何合适实体时也能用
 *   2) 实体写法：classname（+ 可选 targetname），站到该实体附近即算到达
 * 两者都支持可选的 dest（倒计时结束时统一传送到该坐标）。
 *
 * @return PRESET_SLOT_NONE = 未登记；PRESET_SLOT_OTHER = 登记了安全屋/救援点；
 *         PRESET_SLOT_CHECKPOINT = 登记了中途集合点
 */
int LoadPresetSlot(const char[] sMap, const char[] sSlot)
{
	char sType[32];
	g_hPresets.GetString("type", sType, sizeof(sType), "checkpoint");

	int type = AREA_CHECKPOINT;

	if (StrEqual(sType, "saferoom", false))
	{
		type = AREA_SAFEROOM;
	}
	else if (StrEqual(sType, "rescue", false))
	{
		type = AREA_RESCUE;
	}

	int iResult = (type == AREA_CHECKPOINT) ? PRESET_SLOT_CHECKPOINT : PRESET_SLOT_OTHER;

	// 半径：预设没写就用全局默认
	float fRadius = g_hPresets.GetFloat("radius", 0.0);

	if (fRadius <= 0.0)
	{
		fRadius = g_cvMechRadius.FloatValue;
	}

	// 固定传送点（可选）
	char sDest[128];
	float vDest[3];
	bool bHasDest = false;

	g_hPresets.GetString("dest", sDest, sizeof(sDest), "");

	if (sDest[0] != '\0')
	{
		bHasDest = ParseVec(sDest, vDest);

		if (!bHasDest && g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 预设 %s/%s 的 dest \"%s\" 解析失败，忽略该传送点", sMap, sSlot, sDest);
		}
	}

	// ---- 1) 坐标写法（优先：有 origin 就不去找实体） ----------------------
	char sOrigin[128];
	float vPos[3];

	g_hPresets.GetString("origin", sOrigin, sizeof(sOrigin), "");

	if (sOrigin[0] != '\0')
	{
		if (!ParseVec(sOrigin, vPos))
		{
			if (g_cvVerbose.BoolValue)
			{
				PrintToServer("[cptele] 预设 %s/%s 的 origin \"%s\" 解析失败，跳过该区域", sMap, sSlot, sOrigin);
			}

			return PRESET_SLOT_NONE;
		}

		if (AddArea(0, type, SRC_PRESET, vPos, fRadius, vDest, bHasDest) == -1)
		{
			if (g_cvVerbose.BoolValue)
			{
				PrintToServer("[cptele] 预设 %s/%s 未登记（坐标无效或区域已满）", sMap, sSlot);
			}

			return PRESET_SLOT_NONE;
		}

		if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 预设坐标区域 %s/%s: %.0f %.0f %.0f 半径 %.0f",
				sMap, sSlot, vPos[0], vPos[1], vPos[2], fRadius);
		}

		return iResult;
	}

	// ---- 2) 实体写法：classname + targetname（targetname 可空） ----------
	char sClass[64];
	char sTarget[128];

	g_hPresets.GetString("classname", sClass, sizeof(sClass), "func_button");
	g_hPresets.GetString("targetname", sTarget, sizeof(sTarget), "");

	int entity = FindEntityByClassTargetName(sClass, sTarget);

	if (entity == -1)
	{
		if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 预设 %s/%s 找不到实体 %s[%s]，跳过", sMap, sSlot, sClass, sTarget);
		}

		return PRESET_SLOT_NONE;
	}

	if (AddArea(entity, type, SRC_PRESET, NULL_VECTOR, fRadius, vDest, bHasDest) == -1)
	{
		if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 预设 %s/%s 未登记（实体无效或区域已满）", sMap, sSlot);
		}

		return PRESET_SLOT_NONE;
	}

	if (g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] 预设实体区域 %s/%s: %s[%s] #%d", sMap, sSlot, sClass, sTarget, entity);
	}

	return iResult;
}

// ===========================================================================
//  检测路径 2：原版按地点检测（内置表）
// ===========================================================================

/**
 * 原版插件的「按地点检测」数据表。
 *
 * 搬自 alasfourom "L4D Elevator Teleport"（参考插件）：那张表把
 *   「地图名 -> 机关实体（classname + targetname） + 统一传送点坐标」
 * 写死在一起，玩家按下/站上该机关即视为到达集合点。
 *
 * 增加一张新地图时优先改预设文件 configs/l4d2_cptele_presets.cfg，
 * 只有希望「服务器默认就带」时才往这里加一条，保持这张表尽量小。
 */
stock bool GetLegacySite(const char[] sMap,
	char[] sClass, int iClassLen, char[] sTarget, int iTargetLen, float vDest[3])
{
	vDest[0] = 0.0;
	vDest[1] = 0.0;
	vDest[2] = 0.0;

	if (StrEqual(sMap, "c1m1_hotel", false))
	{
		strcopy(sClass, iClassLen, "func_button");
		strcopy(sTarget, iTargetLen, "elevator_button");
		vDest[0] = 2171.0;  vDest[1] = 5810.0;  vDest[2] = 2529.0;
		return true;
	}

	if (StrEqual(sMap, "c1m4_atrium", false))
	{
		strcopy(sClass, iClassLen, "func_button");
		strcopy(sTarget, iTargetLen, "button_elev_3rdfloor");
		vDest[0] = -4039.0; vDest[1] = -3402.0; vDest[2] = 598.0;
		return true;
	}

	if (StrEqual(sMap, "c3m1_plankcountry", false))
	{
		strcopy(sClass, iClassLen, "func_button");
		strcopy(sTarget, iTargetLen, "ferry_tram_button");
		vDest[0] = -5246.0; vDest[1] = 6060.0;  vDest[2] = 50.0;
		return true;
	}

	// c4m2 / c4m3 是同一台电梯，targetname 相同、只有高度不同
	if (StrEqual(sMap, "c4m2_sugarmill_a", false))
	{
		strcopy(sClass, iClassLen, "func_button");
		strcopy(sTarget, iTargetLen, "button_inelevator");
		vDest[0] = -1475.0; vDest[1] = -9558.0; vDest[2] = 660.0;
		return true;
	}

	if (StrEqual(sMap, "c4m3_sugarmill_b", false))
	{
		strcopy(sClass, iClassLen, "func_button");
		strcopy(sTarget, iTargetLen, "button_inelevator");
		vDest[0] = -1479.0; vDest[1] = -9558.0; vDest[2] = 175.0;
		return true;
	}

	if (StrEqual(sMap, "c5m2_park", false))
	{
		strcopy(sClass, iClassLen, "trigger_multiple");
		strcopy(sTarget, iTargetLen, "finale_decon_trigger");
		vDest[0] = -9667.0; vDest[1] = -5970.0; vDest[2] = -170.0;
		return true;
	}

	if (StrEqual(sMap, "c6m3_port", false))
	{
		strcopy(sClass, iClassLen, "func_button");
		strcopy(sTarget, iTargetLen, "generator_elevator_button");
		vDest[0] = -744.0;  vDest[1] = -575.0;  vDest[2] = 360.0;
		return true;
	}

	if (StrEqual(sMap, "c7m3_port", false))
	{
		strcopy(sClass, iClassLen, "func_button");
		strcopy(sTarget, iTargetLen, "bridge_start_button");
		vDest[0] = 0.0;     vDest[1] = -1730.0; vDest[2] = 355.0;
		return true;
	}

	// 医院楼顶电梯（L4D1 的 c8m4 / 对战版）
	if (StrEqual(sMap, "c8m4_interior", false)
	 || StrEqual(sMap, "l4d_hospital04_interior", false)
	 || StrEqual(sMap, "l4d_vs_hospital04_interior", false))
	{
		strcopy(sClass, iClassLen, "func_button");
		strcopy(sTarget, iTargetLen, "elevator_button");
		vDest[0] = 13427.0; vDest[1] = 15225.0; vDest[2] = 475.0;
		return true;
	}

	return false;
}

/**
 * 命中内置表就登记集合点区域；地图上没有对应实体时安静回落。
 * @return 登记成功的区域数（0 或 1）
 */
int LoadLegacySite()
{
	char sMap[128];
	GetCurrentMap(sMap, sizeof(sMap));

	char sClass[64];
	char sTarget[128];
	float vDest[3];

	if (!GetLegacySite(sMap, sClass, sizeof(sClass), sTarget, sizeof(sTarget), vDest))
	{
		return 0;
	}

	int entity = FindEntityByClassTargetName(sClass, sTarget);

	if (entity == -1)
	{
		if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 原版地点表命中 %s，但地图上没有 %s[%s]，回落到运行时侦测",
				sMap, sClass, sTarget);
		}

		return 0;
	}

	if (AddArea(entity, AREA_CHECKPOINT, SRC_LEGACY, NULL_VECTOR, 0.0, vDest, true) == -1)
	{
		return 0;
	}

	if (g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] 原版地点集合点 %s: %s[%s] #%d -> 传送点 %.0f %.0f %.0f",
			sMap, sClass, sTarget, entity, vDest[0], vDest[1], vDest[2]);
	}

	return 1;
}

// ===========================================================================
//  检测路径 3：运行时自动侦测 —— 按下被锁住的 func_button
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

	// 预设 / 原版地点已经给了本图的集合点，就不要再加一个竞争的
	if (g_bSiteAuthority)
	{
		if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 本图集合点已由预设/原版地点提供，忽略动态按钮登记 (func_button #%d)", caller);
		}

		return;
	}

	int index = AddArea(caller, AREA_CHECKPOINT, SRC_AUTO, NULL_VECTOR, 0.0, NULL_VECTOR, false);

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
			g_cvCpPercent.IntValue, g_cvCpTime.IntValue);
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

	// 已经在逃离阶段：安全屋 / 集合点没必要再集合。
	// 但救援关正是「逃离阶段车辆到位后」才需要把掉队的传过去，
	// 所以这一条只对非救援区域生效（在下面的循环里逐区域判断）。
	bool bEscape = g_bNtvEscape && L4D_IsFinaleEscapeInProgress();

	int total = CountAliveSurvivors();

	if (total <= 0)
	{
		return Plugin_Continue;
	}

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

		if (!IsAreaAlive(i))
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

		// 安全屋/救援点与中途集合点用不同的到齐比例，必须逐区域算
		int need = AreaRequiredCount(g_iAreaType[i], total);
		int reached = CountArrivedSurvivors(i);

		if (reached >= need)
		{
			StartCountdown(i, reached, total);
			break;
		}
	}

	return Plugin_Continue;
}

void StartCountdown(int index, int reached, int total)
{
	if (g_bCountingDown)
	{
		return;
	}

	if (index < 0 || index >= g_iAreaCount)
	{
		return;
	}

	int type = g_iAreaType[index];
	int need = AreaRequiredCount(type, total);
	int seconds = AreaCountdownSeconds(type);

	if (seconds <= 0)
	{
		return;
	}

	g_bCountingDown = true;
	g_iActiveArea = index;
	g_iSecondsLeft = seconds;

	char sName[32];
	char sHint[192];

	GetAreaTypeName(type, sName, sizeof(sName));

	if (IsSafeAreaType(type))
	{
		// ---- A 组文案：安全屋 / 救援点 ----
		if (g_cvChat.BoolValue)
		{
			PrintToChatAll("\x05[集合点]\x01 %d/%d 名生还者已进入%s（需要 %d 名），%d 秒后把未进入的生还者传送进来。",
				reached, total, sName, need, seconds);
		}

		Format(sHint, sizeof(sHint), "%d 秒后把未进入%s的生还者传送进来", seconds, sName);
	}
	else
	{
		// ---- B 组文案：地图中途集合点 ----
		if (g_cvChat.BoolValue)
		{
			PrintToChatAll("\x05[集合点]\x01 %d/%d 名生还者已到达集合点（需要 %d 名），%d 秒后传送未到的生还者并开启机关。",
				reached, total, need, seconds);
		}

		Format(sHint, sizeof(sHint), "%d 秒后传送未到集合点的生还者", seconds);
	}

	PrintHintTextToAll("%s", sHint);

	if (g_cvSound.BoolValue)
	{
		EmitCountdownSound();
	}

	if (g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] 区域 #%d 开始倒计时 (type=%d source=%d reached=%d total=%d need=%d seconds=%d)",
			index, type, g_iAreaSource[index], reached, total, need, seconds);
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

	int type = g_iAreaType[index];

	// 掉回比例以下的处理策略
	if (g_cvResetOnLeave.BoolValue)
	{
		int total = CountAliveSurvivors();
		int need = AreaRequiredCount(type, total);
		int reached = CountArrivedSurvivors(index);

		if (total <= 0 || reached < need)
		{
			char sName[32];
			GetAreaTypeName(type, sName, sizeof(sName));

			if (IsSafeAreaType(type))
			{
				if (g_cvChat.BoolValue)
				{
					PrintToChatAll("\x05[集合点]\x01 到场人数降到 %d/%d（需要 %d 名），%s传送倒计时取消。",
						reached, total, need, sName);
				}

				PrintHintTextToAll("到场人数不足，%s传送倒计时取消", sName);
			}
			else
			{
				if (g_cvChat.BoolValue)
				{
					PrintToChatAll("\x05[集合点]\x01 到场人数降到 %d/%d（需要 %d 名），集合点传送倒计时取消。",
						reached, total, need);
				}

				PrintHintTextToAll("到场人数不足，集合点传送倒计时取消");
			}

			CancelCountdown(index);
			g_hCountdown = null;
			return Plugin_Stop;
		}
	}

	// 先递减再判断，保证总时长精确等于该类型的倒计时 cvar，
	// 且不会与 StartCountdown 里那次首播重复播报同一个秒数
	g_iSecondsLeft--;

	if (g_iSecondsLeft <= 0)
	{
		FinishCountdown(index);
		g_hCountdown = null;
		return Plugin_Stop;
	}

	char sName[32];
	char sHint[192];

	GetAreaTypeName(type, sName, sizeof(sName));

	if (IsSafeAreaType(type))
	{
		Format(sHint, sizeof(sHint), "%d 秒后把未进入%s的生还者传送进来", g_iSecondsLeft, sName);
	}
	else
	{
		Format(sHint, sizeof(sHint), "%d 秒后传送未到集合点的生还者", g_iSecondsLeft);
	}

	PrintHintTextToAll("%s", sHint);

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
	if (index < 0 || index >= g_iAreaCount)
	{
		g_bCountingDown = false;
		g_iSecondsLeft = 0;
		g_iActiveArea = -1;
		return;
	}

	g_bCountingDown = false;
	g_iSecondsLeft = 0;
	g_iActiveArea = -1;
	g_bAreaFired[index] = true;

	int type = g_iAreaType[index];

	float vDest[3];
	bool bHasDest = GetAreaDestination(index, vDest);
	int moved = 0;

	if (bHasDest)
	{
		bool bFixedDest = g_bAreaDest[index];

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

			// 固定传送点要「每人一份抖动」：12v12 最多 11 个掉队的
			// 同时落地，全挤在一个坐标上会互相挤出去 / 卡进几何体。
			float vClientDest[3];

			CopyVec(vDest, vClientDest);

			if (bFixedDest)
			{
				vClientDest[0] += GetRandomFloat(-DEST_JITTER, DEST_JITTER);
				vClientDest[1] += GetRandomFloat(-DEST_JITTER, DEST_JITTER);
			}

			TeleportSurvivor(i, vClientDest);
			moved++;
		}
	}

	// ---- 开机关 ---------------------------------------------------------
	if (type == AREA_CHECKPOINT)
	{
		int entity = GetAreaEntity(index);

		if (entity != -1)
		{
			char sClass[64];

			// 只对「按钮类」实体做 unlock+use。就算管理员误把门写进预设，
			// 这里也不会去动任何门（尤其是安全门）的 lock 状态。
			// 与 alasfourom "L4D Elevator Teleport" 一致：先解锁再按下。
			if (GetEntityClassname(entity, sClass, sizeof(sClass)) && IsButtonClass(sClass))
			{
				AcceptEntityInput(entity, "unlock");
				AcceptEntityInput(entity, "use");
			}
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

	char sName[32];
	char sMsg[192];

	GetAreaTypeName(type, sName, sizeof(sName));

	if (IsSafeAreaType(type))
	{
		if (g_cvChat.BoolValue)
		{
			PrintToChatAll("\x05[集合点]\x01 倒计时结束，已把 %d 名生还者传送到%s。", moved, sName);
		}

		Format(sMsg, sizeof(sMsg), "已把 %d 名生还者传送到%s", moved, sName);
	}
	else
	{
		if (g_cvChat.BoolValue)
		{
			PrintToChatAll("\x05[集合点]\x01 倒计时结束，已把 %d 名生还者传送到集合点。", moved);
		}

		Format(sMsg, sizeof(sMsg), "已把 %d 名生还者传送到集合点", moved);
	}

	PrintHintTextToAll("%s", sMsg);

	if (g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] 区域 #%d 完成 (type=%d source=%d moved=%d dest=%d)",
			index, type, g_iAreaSource[index], moved, bHasDest);
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

/**
 * 安全屋 / 救援点属于同一类（共用 l4d2_cptele_time / l4d2_cptele_percent），
 * 中途集合点是另一类（l4d2_cptele_checkpoint_time / _percent）。
 */
stock bool IsSafeAreaType(int type)
{
	return type == AREA_SAFEROOM || type == AREA_RESCUE;
}

stock int AreaCountdownSeconds(int type)
{
	return IsSafeAreaType(type) ? g_cvTime.IntValue : g_cvCpTime.IntValue;
}

stock int AreaPercentValue(int type)
{
	return IsSafeAreaType(type) ? g_cvPercent.IntValue : g_cvCpPercent.IntValue;
}

/**
 * 区域类型的中文名，同时用于提示文案与 sm_cptele 输出。
 */
stock void GetAreaTypeName(int type, char[] sName, int iLen)
{
	switch (type)
	{
		case AREA_SAFEROOM:   strcopy(sName, iLen, "安全屋");
		case AREA_RESCUE:     strcopy(sName, iLen, "救援点");
		case AREA_CHECKPOINT: strcopy(sName, iLen, "集合点");
		default:              strcopy(sName, iLen, "未知");
	}
}

stock void GetAreaSourceName(int source, char[] sName, int iLen)
{
	switch (source)
	{
		case SRC_PRESET:      strcopy(sName, iLen, "预设");
		case SRC_LEGACY:      strcopy(sName, iLen, "原版地点");
		default:              strcopy(sName, iLen, "自动侦测");
	}
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

/**
 * 某类型区域在这次需要多少人到场。
 * 安全屋/救援点用 l4d2_cptele_percent，中途集合点用
 * l4d2_cptele_checkpoint_percent。
 */
int AreaRequiredCount(int type, int total)
{
	if (total <= 0)
	{
		return 1;
	}

	int need = RoundToCeil(AreaPercentValue(type) / 100.0 * float(total));

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
	if (g_bAreaRadius[index])
	{
		float vClient[3];
		float fNeeded = g_fAreaRadius[index];

		if (fNeeded <= 0.0)
		{
			fNeeded = g_cvMechRadius.FloatValue;
		}

		GetClientAbsOrigin(client, vClient);

		return GetVectorDistance(vClient, g_vAreaPos[index]) <= fNeeded;
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
	// ---- 0) 预设 / 原版内置表给的固定传送点（最准，优先） ----------------
	// 抖动由 FinishCountdown 按人加，这里只给准确坐标
	if (g_bAreaDest[index])
	{
		CopyVec(g_vAreaDest[index], vDest);

		return true;
	}

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

	if (g_bAreaCoord[index] || g_bAreaRadius[index])
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
	char sSrc[16];
	int total = CountAliveSurvivors();

	ReplyToCommand(client, "[cptele] enable=%d ready=%d 区域数=%d 存活生还者=%d 集合点来源=%s",
		g_cvEnable.BoolValue, g_bReady, g_iAreaCount, total,
		g_bSiteAuthority ? "预设/原版地点" : "运行时侦测");

	ReplyToCommand(client, "[cptele] 安全屋/救援点: %d%%(%d名) %d秒 | 中途集合点: %d%%(%d名) %d秒",
		g_cvPercent.IntValue, AreaRequiredCount(AREA_SAFEROOM, total), g_cvTime.IntValue,
		g_cvCpPercent.IntValue, AreaRequiredCount(AREA_CHECKPOINT, total), g_cvCpTime.IntValue);

	for (int i = 0; i < g_iAreaCount; i++)
	{
		GetAreaTypeName(g_iAreaType[i], sType, sizeof(sType));
		GetAreaSourceName(g_iAreaSource[i], sSrc, sizeof(sSrc));

		ReplyToCommand(client, "  #%d %s/%s ent=%d 距离判定=%d 已到达=%d 已触发=%d",
			i, sType, sSrc, GetAreaEntity(i), g_bAreaRadius[i],
			CountArrivedSurvivors(i), g_bAreaFired[i]);
	}

	if (g_bCountingDown)
	{
		GetAreaTypeName(g_iAreaType[g_iActiveArea], sType, sizeof(sType));
		ReplyToCommand(client, "  倒计时进行中：区域 #%d（%s），剩余 %d 秒",
			g_iActiveArea, sType, g_iSecondsLeft);
	}

	return Plugin_Handled;
}

public Action Cmd_ReloadPresets(int client, int args)
{
	delete g_hPresets;
	g_hPresets = null;
	g_bPresetsTried = false;

	// ResetRound() 会清掉 g_bRescueReady，但排错时重读配置不该把
	// 「救援车已到位」这个事实一起忘掉，否则终局图会重新等一次事件。
	bool bRescueReady = g_bRescueReady;

	ResetRound();
	g_bRescueReady = bRescueReady;

	DetectAreas();
	EnsureMonitor();

	ReplyToCommand(client, "[cptele] 已重新读取预设配置并重新侦测，当前区域数=%d（集合点来源=%s）",
		g_iAreaCount, g_bSiteAuthority ? "预设/原版地点" : "运行时侦测");

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

	StartCountdown(index, CountArrivedSurvivors(index), total);

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
 * trigger / changelevel 这类「体积判定」实体，用 L4D_IsTouchingTrigger；
 * 其余（func_button 等点状实体）与纯坐标区域用距离判定。
 */
stock bool IsTouchModeClass(const char[] sClass)
{
	return StrEqual(sClass, "trigger_multiple", false)
	    || StrEqual(sClass, "trigger_once", false)
	    || StrEqual(sClass, "trigger_hurt", false)
	    || StrEqual(sClass, "trigger_push", false)
	    || StrEqual(sClass, "info_changelevel", false)
	    || StrEqual(sClass, "trigger_changelevel", false);
}

/**
 * 可以「解锁并按下」的按钮类实体。
 * 限定白名单，避免误配时对门 / 其它带 use 输入的实体动手。
 */
stock bool IsButtonClass(const char[] sClass)
{
	return StrEqual(sClass, "func_button", false)
	    || StrEqual(sClass, "func_rot_button", false)
	    || StrEqual(sClass, "prop_button", false);
}

/**
 * 从字符串里读下一个数字（以空格 / 制表符 / 逗号分隔）。
 * 用逐字符扫描而不是 SplitString：SplitString 不改写源串，
 * 遇到连续空格会产生空字段，把 "1  2 3" 解析成 1/0/2。
 */
stock bool NextNumberToken(const char[] sBuf, int &iPos, float &fValue)
{
	int iLen = strlen(sBuf);
	int i = iPos;

	while (i < iLen && (sBuf[i] == ' ' || sBuf[i] == '\t' || sBuf[i] == ','))
	{
		i++;
	}

	if (i >= iLen)
	{
		iPos = i;
		return false;
	}

	int iStart = i;

	while (i < iLen && sBuf[i] != ' ' && sBuf[i] != '\t' && sBuf[i] != ',')
	{
		i++;
	}

	char sNum[48];
	int n = i - iStart;

	if (n >= sizeof(sNum))
	{
		n = sizeof(sNum) - 1;
	}

	for (int k = 0; k < n; k++)
	{
		sNum[k] = sBuf[iStart + k];
	}

	sNum[n] = '\0';
	fValue = StringToFloat(sNum);
	iPos = i;

	return true;
}

/**
 * 解析 "x y z"（也接受 "x,y,z"）。
 */
stock bool ParseVec(const char[] sValue, float vOut[3])
{
	int iPos = 0;

	for (int i = 0; i < 3; i++)
	{
		if (!NextNumberToken(sValue, iPos, vOut[i]))
		{
			return false;
		}
	}

	return true;
}

/**
 * 按 classname（+ 可选 targetname）找实体。
 * targetname 为空时返回该类第一个实体。
 */
stock int FindEntityByClassTargetName(const char[] sClass, const char[] sTarget)
{
	if (sClass[0] == '\0')
	{
		return -1;
	}

	char sName[128];
	int entity = -1;

	while ((entity = FindEntityByClassname(entity, sClass)) != -1)
	{
		if (sTarget[0] == '\0')
		{
			return entity;
		}

		sName[0] = '\0';

		if (!GetEntPropString(entity, Prop_Data, "m_iName", sName, sizeof(sName)))
		{
			continue;
		}

		if (StrEqual(sName, sTarget, false))
		{
			return entity;
		}
	}

	return -1;
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
	g_bSiteAuthority = false;

	for (int i = 0; i < MAX_AREAS; i++)
	{
		g_iAreaRef[i] = 0;
		g_iAreaType[i] = AREA_SAFEROOM;
		g_iAreaSource[i] = SRC_AUTO;
		g_bAreaFired[i] = false;
		g_bAreaCoord[i] = false;
		g_bAreaRadius[i] = false;
		g_bAreaDest[i] = false;
		g_fAreaCooldown[i] = 0.0;
		g_fAreaRadius[i] = 0.0;

		for (int j = 0; j < 3; j++)
		{
			g_vAreaPos[i][j] = 0.0;
			g_vAreaDest[i][j] = 0.0;
		}
	}

	g_iAreaCount = 0;
}
