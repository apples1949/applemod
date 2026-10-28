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
 *    —— 1.2.1 起唯一的例外说明：过关判定本身在引擎里，安全门必须处于「已开启」
 *       状态，引擎才会走「全员进屋 -> 关门 -> 换图」这条链。所以倒计时传送把
 *       人送进关底安全屋之后，如果门是完全关闭的，就对该门发一次标准 Open
 *       输入（等价于玩家自己开门）。仍然不改 spawnflags / lock，不解锁、不锁门，
 *       也不做任何硬换图。可用 l4d2_cptele_saferoom_opendoor 0 关闭。
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
 *      -> [仅关底安全屋] 传送落位 0.2s 后复核安全门状态，门是完全关闭的
 *         就补发一次标准 Open 输入（1.2.1，见 ScheduleSaferoomDoorFix）
 *    同一区域每回合只会触发一次；换图 / round_start / round_end 全部重置。
 *
 *  1.2.0 修复「集合完就往前走」被传送回来（c5m2 之类机关集合点）：
 *    - 倒计时期间每秒记录「到过集合点」的生还者（g_bSeen）。
 *      倒计时结束时只传送「一次都没到过」的人；已经到过、随后离开继续推进
 *      的生还者不再被传送回来（l4d2_cptele_skip_seen 1，默认）。
 *    - 全员都到过集合点 = 集合完毕：倒计时立刻结束（不再空转到 0），
 *      并且一个人都不传送（只把机关按钮解锁按下）。
 *    旧行为（只按「倒计时结束时是否还在区域内」判定）可用
 *    l4d2_cptele_skip_seen 0 还原。
 *
 *  1.2.1 修复「安全门关着时传送后不过关」（需求 #7）：
 *    - 现象：倒计时结束把人传送进关底安全屋，但安全门当时是「完全关闭」状态时，
 *      人已经在屋里却永远不换图；门是开着的时候同样的传送就能正常过关。
 *    - 根因：过关不是插件判定的，而是引擎 info_changelevel 实体的流程。
 *      datamap 里 info_changelevel 带 CheckpointDoorOpened / CheckpointDoorClosed
 *      两个实体输入（引擎 InfoChangelevel::OnCheckpointDoorClosed 里还会逐个
 *      用 CBaseTrigger::IsTouching 判「谁还在安全屋外面」）。门一直处于关闭
 *      状态 = 门没有任何状态变化 = 这两个输入一次都不会触发，引擎的过关链
 *      没有起点，所以人进屋也不会换图。
 *    - 修复：传送落位 0.2 秒后（等物理/触发体积稳定）复核安全屋里确实有人，
 *      再看门 prop_door_rotating_checkpoint 的 m_eDoorState：
 *      不是 DOOR_STATE_OPENED 就对该门发一次标准 Open 输入，把门恢复到
 *      「玩家开门进屋」这个引擎认识的正常状态，后续关门 + 换图交回引擎。
 *      只发 Open，不动 spawnflags / lock / 不解锁不锁门，不调用任何硬换图。
 *    - 相关开关：l4d2_cptele_saferoom_opendoor（默认 1）。
 *
 *  1.2.2 需求 #7 的第二轮补强 + 安全屋区域选点修复：
 *    - 开门不一定够：正常游戏里过关还要"门再关上"那一下（引擎靠
 *      CheckpointDoorClosed 进来才做 IsTouching 逐人检查，然后 ChangelevelThink 换图）。
 *      倒计时传送没人去关门，所以新增第二层：Open 之后 0.6 秒，若**全部存活生还者**
 *      都在安全屋体积内，就把门物理关回去，并补发一次 CheckpointDoorClosed。
 *      少一个人都不发（伪造事件没用，还会误导排查）。
 *      开关：l4d2_cptele_saferoom_forcedoor（默认 1）。
 *    - 安全屋区域原来取"第一个 changelevel"，实测官方图 10 张有 2 个候选、其中 7 张图
 *      第一个是"往回走"那个（spawnflags=2，map 指向上一张图/本图/空），会让区域指到
 *      开局安全屋（开局全员在屋里 -> 立刻算集合完毕 -> 关底传送静默失效）。
 *      现在按 spawnflags & 2 剔回退项 -> m_mapName 指向下一张图 -> nav 最后检查点 ->
 *      最后一个安全门 的顺序判定（见 FindLastChangelevel）。
 *
 *  1.2.3 需求 #7 第三轮修复：两个仍会漏的洞 + 改成状态机 -----------------------
 *    - 用户回报的两种残留现象：
 *        A) 「传送到安全屋后，如果门开着，不会关」
 *        B) 「关着门，可能不会结算」
 *    - A 的根因：1.2.2 的 Timer_SaferoomDoorFix 在门已经是 DOOR_STATE_OPENED 时
 *      直接 return —— 它只考虑"门关着要开"，从来没考虑"门开着要关"。而引擎的过关链
 *      需要的是「Opened + Closed」两次状态变化，门本来就开着时只缺 Closed，
 *      于是永远没人去关，人齐也不会换图。
 *    - B 的根因：1.2.2 的补发关门是 0.2s 后的一次性 0.6s timer，且要求那一瞬间
 *      「全部存活生还者都在安全屋体积内」才发。12v12 有 12 个人挤一个体积，
 *      只要有人被挤出触发体积（引擎挤压/地形很容易做到），这一次就永久放弃，
 *      再也没有第二次机会。
 *    - 修复：把两个一次性 timer 换成一个 0.25s 轮询的状态机（SAFEROOM_SETTLE_TICK），
 *      按「等门开到位 -> 等全员进体积（不够就补传，可重试）-> 关门 -> 等门关到位 ->
 *      补发 CheckpointDoorClosed」推进；每步幂等、有重试上限、有 10 秒超时兜底；
 *      门本来就开着时记成"已开启"后**继续往下走**，不再提前退出。
 *      FinishCountdownAllSeen（人齐、倒计时提前结束）这条路径原来完全不碰门，
 *      现在也接入状态机 —— B 现象有一大半是从这里来的。
 *      仍然只发标准 Open/Close/Teleport 输入，不改 spawnflags / lock，不硬换图。
 *    - 新增开关沿用原有的 l4d2_cptele_saferoom_opendoor / l4d2_cptele_saferoom_forcedoor：
 *      opendoor=0 时完全不动门（连状态机都不启动），兼容"不想让插件碰门"的用法。
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

#define PLUGIN_VERSION      "1.2.3"

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

// 安全门修复：传送落位后等多久再去检查 / 动门（等一帧以上，让 TeleportEntity
// 与 L4D_WarpToValidPositionIfStuck 的落点、以及引擎的触发体积 touching 状态稳定）
#define SAFEROOM_DOOR_DELAY     0.2

// ↑1.2.3 起 SAFEROOM_DOOR_DELAY 已不再被使用（原来那个 0.2s 一次性复核被状态机取代）。
//   保留定义只是为了不删历史注释里的引用；新逻辑请用下面的 SAFEROOM_SETTLE_*。

// 1.2.3：安全屋「结算」改成一个轮询状态机（见 Timer_SaferoomDoorFix 的注释）。
// 原来的两个一次性 timer（0.2s 复核 + 0.6s 补发）有两个覆盖不到的漏洞：
//   ① 门本来就开着 -> Timer_SaferoomDoorFix 直接 return，永远没人去关门，
//      引擎等的那次「门关闭」事件一次都不会来（用户报的「开着门不会关」）；
//   ② 0.6s 太短：门还在开的过程中收到 Close 会被引擎忽略；而且 12v12 有 12 个
//      生还者，只要有一瞬间有 1 个人被挤出安全屋体积，就永远发不出关闭事件
//      （用户报的「关着门可能不会结算」）。
#define SAFEROOM_SETTLE_TICK        0.25    // 状态机轮询间隔（秒）
#define SAFEROOM_SETTLE_TIMEOUT     10.0    // 状态机总超时（秒），超时留日志收尾，不会无限跑
#define SAFEROOM_SETTLE_RETRY_MAX   3       // 掉队者最多补传几次（12 人挤一个体积必然有人被挤出）
#define SAFEROOM_SETTLE_RETRY_DELAY 1.0     // 第 N 次补传最早在第 N*该值 秒之后（给物理/挤压留时间）

// 安全门修复：门到 info_changelevel 体积中心的最大距离（HU）。
// 与 left4dhooks 里 L4D_GetCheckpointLast 判断「末尾那道门」用的是同一个量级
// （DOOR_RANGE_TOLLERANCE = 2000）。超过这个距离说明找到的门不是这间安全屋的，
// 宁可不开门也不能误开别处的门（例如起点安全屋的门）。
#define SAFEROOM_DOOR_MAX_DIST  2000.0

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
ConVar g_cvSkipSeen;
ConVar g_cvSound;
ConVar g_cvChat;
ConVar g_cvSaferoom;
ConVar g_cvSaferoomDoor;        // 关底安全门关闭时，传送后发 Open 让引擎能过关（1.2.1）
ConVar g_cvSaferoomForceDoor;   // 门开不了/开过之后仍不过关时，补发一次 CheckpointDoorClosed（1.2.2）
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

// 1.2.1 安全门复核的挂起状态。一张图最多一个关底安全屋区域，同一时刻也只会
// 有一个倒计时在跑，所以用单槽即可；换图 / 换回合由 ResetRound 统一清掉。
Handle g_hDoorFix;              // 安全屋结算状态机的轮询 timer（1.2.3 起是重复 timer）
int    g_iDoorFixArea = -1;     // 挂起中的区域索引（-1 = 没有挂起）
int    g_iDoorFixRef;           // 挂起中区域实体的 EntRef（防跨回合残影）

// 1.2.3 安全屋结算状态机的进度（原 1.2.2 的两个一次性 timer 已被它取代）
float  g_fSettleDeadline;       // 绝对超时时刻（GetGameTime 口径）
int    g_iSettleRetry;          // 已经补传掉队生还者的次数
float  g_fSettleNextRetry;      // 下次允许补传的时刻
int    g_iSettleOpenTries;      // 已经发过几次 Open（门被锁时用来止损，不无限重发）
float  g_fSettleNextOpenTry;    // 下次允许重发 Open 的时刻（给引擎 think 留时间，避免每 tick 判死）
bool   g_bSettleDoorOpened;     // 门已经历过「开启」（本来就开着也算）
bool   g_bSettleDoorClosed;     // 已经对该门发过 Close
bool   g_bSettleEventFired;     // 已经向 info_changelevel 发过 CheckpointDoorClosed

// 本次倒计时期间「到过该区域」的生还者。倒计时结束时只传送「一次都没到过」的人，
// 已经到过、随后离开继续推进的人不再被传送回来（1.2.0 修复）。
bool   g_bSeen[MAXPLAYERS+1];

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
bool g_bNtvDoorLast;            // L4D_GetCheckpointLast（找关底安全门）
bool g_bNtvLastCp;              // L4D_IsPositionInLastCheckpoint（挑关底那个 info_changelevel）

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

	g_cvSkipSeen = CreateConVar("l4d2_cptele_skip_seen", "1",
		"1=倒计时期间已经到过集合点（哪怕随后离开、继续往前走）的生还者，倒计时结束时不再被传送回来；并且全员都到过时倒计时立即结束。0=旧行为（只看倒计时结束那一刻是否还在区域内）",
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

	// 需求 #7：安全门关着时，倒计时传送把人送进屋也不会过关（引擎侧要门先「已开启」）。
	// 这里默认 1，传送后只对「完全关闭」的安全门发一次标准 Open 输入。
	g_cvSaferoomDoor = CreateConVar("l4d2_cptele_saferoom_opendoor", "1",
		"1=倒计时传送把生还者送进关底安全屋后，若安全门处于完全关闭状态，对该门发送标准 Open 输入（等价玩家开门，不改 spawnflags/lock），让引擎的过关判定能触发。0=完全不碰安全门",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// 1.2.2：光开门不一定够（有的图门开完没人去关，引擎的 CheckpointDoorClosed 就不会来），
	// 所以再补一层「所有存活生还者都在屋内时，补发一次引擎自己的 CheckpointDoorClosed」。
	g_cvSaferoomForceDoor = CreateConVar("l4d2_cptele_saferoom_forcedoor", "1",
		"1=断电补救：安全门原本是关闭状态（说明过关链没起来）时，在全员都进到安全屋体积后，向 info_changelevel 补发一次 CheckpointDoorClosed 输入（就是引擎在门关闭时自己发的那个输入），并把门物理关回去。0=只做 Open，不补发关门事件",
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
	g_bNtvDoorLast      = NtvAvailable("L4D_GetCheckpointLast");
	g_bNtvLastCp        = NtvAvailable("L4D_IsPositionInLastCheckpoint");

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
		PrintToServer("[cptele] native 检查通过: touch=%d finalmap=%d nav=%d revive=%d warp=%d dom=%d release=%d rescue=%d doorlast=%d",
			g_bNtvTouch, g_bNtvFinalMap, g_bNtvNav, g_bNtvRevive,
			g_bNtvWarp, g_bNtvDominating, g_bNtvRelease, g_bNtvRescueVehicle, g_bNtvDoorLast);
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
 * 槽位复用防御：g_bSeen 按客户端索引记录，掉线后新玩家复用同一槽位时
 * 会被误当成「已经到过集合点」（该传不传，甚至提前判定全员到齐）。
 * 连接 / 断线两个时机都清掉，确保标记只属于当前占用该槽位的人。
 */
public void OnClientConnected(int client)
{
	if (client > 0 && client <= MaxClients)
	{
		g_bSeen[client] = false;
	}
}

public void OnClientDisconnect(int client)
{
	if (client > 0 && client <= MaxClients)
	{
		g_bSeen[client] = false;
	}
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
		// 1.2.2：不能只取第一个 changelevel —— 官方图里有 7 张图第一个 changelevel 是
		// 「起点」安全屋体积，取第一个会让安全屋区域指到开局那间屋（见 FindLastChangelevel 注释）
		int entity = FindLastChangelevel();

		if (entity != -1)
		{
			AddArea(entity, AREA_SAFEROOM, SRC_AUTO, NULL_VECTOR, 0.0, NULL_VECTOR, false);

			if (g_cvVerbose.BoolValue)
			{
				char sClass[64];
				GetEntityClassname(entity, sClass, sizeof(sClass));
				PrintToServer("[cptele] 安全屋区域: entity #%d (%s)", entity, sClass);
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

		// 中途集合点：倒计时开始前就要开始累积「到过」标记，
		// 这样「倒计时期间已经走过集合点、跑到前面去」的人不会被传送回来。
		if (g_cvSkipSeen.BoolValue && g_iAreaType[i] == AREA_CHECKPOINT)
		{
			MarkSeenInArea(i);
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

	// 新一轮倒计时：重新记录「到过区域」的人（开局就在区域里的人算已到过）
	//
	// 中途集合点不清零：倒计时「开始之前」就已经走过集合点的人同样算到过，
	// 否则他们会在倒计时结束时被传送回集合点（正是要修的 bug）。
	// 安全屋 / 救援点必须清零：那两类区域在 round_start 时全员可能都站在里面，
	// 不清零会让「全员已到过」立刻成立、功能等于被废掉。
	if (IsSafeAreaType(g_iAreaType[index]))
	{
		ClearSeenFlags();
	}

	MarkSeenInArea(index);

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

	// 记录「本次倒计时期间到过集合点」的人：他们已完成集合这一步，
	// 倒计时结束时不再被传送回来（c5m2 这类「集合完就往前走」地图的修复点）
	MarkSeenInArea(index);

	// 全员都到过集合点 = 集合完毕：倒计时立即结束，一个人都不传送。
	// 否则会出现「人都走远了，倒计时还在空转，结束时把全队传回来」的问题。
	if (g_cvSkipSeen.BoolValue)
	{
		int iAlive = CountAliveSurvivors();

		if (iAlive > 0 && CountSeenSurvivors() >= iAlive)
		{
			FinishCountdownAllSeen(index);
			g_hCountdown = null;
			return Plugin_Stop;
		}
	}

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

			// 本次倒计时期间已经到过集合点的人：视为已集合完毕，
			// 不再把人从前方传送回来（这就是「集合完就往前走」的修复点）
			if (g_cvSkipSeen.BoolValue && g_bSeen[i])
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
	OpenAreaMechanism(index, type);

	// ---- 关底安全屋：门没经历「开 -> 关」就不过关（1.2.1 / 需求 #7）-------
	// 1.2.3 起这里不再区分「门开着还是关着」：
	//   以前只在 moved > 0 时复核，而且门开着就直接 return（没人去关），
	//   门关着又要靠一个 0.6s 的一次性 timer 赌「全员恰好都在体积内」。
	//   现在只要这次倒计时结束时安全屋里确实有人（传送落地了，或者人本来就到齐了），
	//   就交给状态机去补齐「开启 -> 关门 -> 补发 Closed」这条引擎链。
	//   状态机内部会自己校验类型（只处理 AREA_SAFEROOM）、门是否存在、是否全员在屋内。
	if (moved > 0 || CountArrivedSurvivors(index) > 0)
	{
		ScheduleSaferoomDoorFix(index);
	}

	if (g_cvRemoveInfected.BoolValue && bHasDest)
	{
		RemoveInfectedAround(vDest);
	}

	char sName[32];
	char sMsg[192];

	GetAreaTypeName(type, sName, sizeof(sName));

	if (moved <= 0)
	{
		// 一个都没传送：要么全员都到过，要么压根拿不到传送目标
		if (!bHasDest)
		{
			// 区域实体在倒计时期间消失 / 拿不到 nav area：不能假装"无需传送"
			LogError("[cptele] 区域 #%d (%s) 拿不到传送目标，本次未传送任何生还者", index, sName);

			if (g_cvChat.BoolValue)
			{
				PrintToChatAll("\x05[集合点]\x01 倒计时结束，但找不到%s的传送位置，本次不传送。", sName);
			}

			Format(sMsg, sizeof(sMsg), "找不到%s的传送位置，本次不传送", sName);
		}
		else if (IsSafeAreaType(type))
		{
			if (g_cvChat.BoolValue)
			{
				PrintToChatAll("\x05[集合点]\x01 倒计时结束，全员已进入%s，无需传送。", sName);
			}

			Format(sMsg, sizeof(sMsg), "全员已进入%s，无需传送", sName);
		}
		else
		{
			if (g_cvChat.BoolValue)
			{
				PrintToChatAll("\x05[集合点]\x01 倒计时结束，全员已到达集合点，无需传送。");
			}

			Format(sMsg, sizeof(sMsg), "全员已到达集合点，无需传送");
		}
	}
	else if (IsSafeAreaType(type))
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

/**
 * 全员都已经到过集合点：集合完毕，倒计时提前结束，一个人都不传送。
 *
 * 触发场景（用户报的 bug）：机关集合点（如 c5m2）倒计时开始后，玩家在倒计时
 * 结束前就集合完毕并继续往前走，旧逻辑会一直空转到 0 秒，然后把「不在区域内」
 * 的整队人传送回集合点。现在只要所有人都到过，就直接结束本次倒计时。
 */
void FinishCountdownAllSeen(int index)
{
	g_bCountingDown = false;
	g_iSecondsLeft = 0;
	g_iActiveArea = -1;
	g_bAreaFired[index] = true;

	int type = g_iAreaType[index];

	// 集合完毕 = 该按的机关仍然要按下去（电梯 / 渡轮 / 桥等）
	OpenAreaMechanism(index, type);

	// 安全屋「全员已进入」= 引擎那边同样缺「开门 -> 关门」这条链：
	// 人虽然都在屋里，但门要是没人开过、没人关过，引擎照样不会结算。
	// （用户报的「关着门可能不会结算」正是这条路径：人齐了、倒计时提前结束、
	//   然后门一直不动 -> 引擎等 CheckpointDoorClosed 永远等不到。）
	// 这里同样交给状态机，不区分门当前是开还是关。
	if (IsSafeAreaType(type) && g_iAreaType[index] == AREA_SAFEROOM
		&& CountArrivedSurvivors(index) > 0)
	{
		ScheduleSaferoomDoorFix(index);
	}

	char sName[32];
	char sMsg[192];

	GetAreaTypeName(type, sName, sizeof(sName));

	if (IsSafeAreaType(type))
	{
		if (g_cvChat.BoolValue)
		{
			PrintToChatAll("\x05[集合点]\x01 全员已进入%s，倒计时提前结束，无人需要传送。", sName);
		}

		Format(sMsg, sizeof(sMsg), "全员已进入%s，倒计时提前结束", sName);
	}
	else
	{
		if (g_cvChat.BoolValue)
		{
			PrintToChatAll("\x05[集合点]\x01 全员已到达集合点，倒计时提前结束，无人需要传送。");
		}

		Format(sMsg, sizeof(sMsg), "全员已到达集合点，倒计时提前结束");
	}

	PrintHintTextToAll("%s", sMsg);

	if (g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] 区域 #%d 全员已到过集合点，提前结束 (type=%d source=%d)",
			index, type, g_iAreaSource[index]);
	}
}

/**
 * 倒计时结束时要开的机关。
 * 只对「按钮类」实体做 unlock+use：就算管理员误把门写进预设，
 * 这里也不会去动任何门（尤其是安全门）的 lock 状态。
 * 与 alasfourom "L4D Elevator Teleport" 一致：先解锁再按下。
 */
void OpenAreaMechanism(int index, int type)
{
	if (type == AREA_CHECKPOINT)
	{
		int entity = GetAreaEntity(index);

		if (entity == -1)
		{
			return;
		}

		char sClass[64];

		if (GetEntityClassname(entity, sClass, sizeof(sClass)) && IsButtonClass(sClass))
		{
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
	// 1.2.1：安全门「关着导致不过关」的问题不在这里处理，而是传送全部落位后
	// 由 ScheduleSaferoomDoorFix 复核一次安全门状态（只发标准 Open 输入，
	// 同样不改 spawnflags / lock，不解锁、不锁门）。
}

// ===========================================================================
//  关底安全门状态修复（1.2.1 / 需求 #7；1.2.3 改为状态机）
// ===========================================================================
//
//  为什么需要这一整块（引擎侧的根因，三条都已在 server.dll 的 datamap 上核对过）：
//    ① 过关不是插件判定的，是引擎 info_changelevel 实体的流程。datamap 里
//       info_changelevel 带 CheckpointDoorOpened / CheckpointDoorClosed 两个实体输入，
//       引擎 InfoChangelevel::OnCheckpointDoorClosed 里还会逐个用 CBaseTrigger::IsTouching
//       判「谁还在安全屋外面」，然后才走 ChangelevelThink 换图。
//    ② 也就是说过关是**由安全门的状态变化驱动**的：门一直不动 -> 两个输入一次都不来
//       -> 人虽然被传送进屋，引擎根本不会开始过关判定。
//    ③ 正常游戏里这两次状态变化是玩家自己提供的：开门进屋（Opened）、人齐后关门（Closed）。
//       倒计时传送是把人 TeleportEntity 直接塞进屋里，门从来没被开过、也没人去关，
//       于是卡死。表现出来就是用户报的两种现象：
//         · 门开着 -> 没人去关它 -> 引擎等 CheckpointDoorClosed 永远等不到（"开着门不会关"）；
//         · 门关着 -> 门没有任何状态变化 -> 引擎连判定都没开始（"关着门可能不会结算"）。

/**
 * 倒计时传送结束后，启动「安全屋结算」状态机。
 *
 * 只有一种情况会走到这里：区域类型是关底安全屋，并且这次倒计时真的传送了人。
 * 其余类型（救援点 / 中途集合点）一律不碰门。
 *
 * 与 1.2.2 的区别（1.2.2 为什么不够 —— 这两个漏洞正是本次要修的）：
 *   · 1.2.2 的 Timer_SaferoomDoorFix 在「门已经开着」时直接 return，
 *     于是**没有任何东西会去关门**——这正是用户报的「开着门不会关」；
 *   · 1.2.2 的补发关门是 0.2s 后的一个一次性 0.6s timer，而且要求「全部存活生还者
 *     都在屋内」才发。12v12 有 12 个人挤一个安全屋体积，只要那一瞬间有 1 个人被
 *     挤出触发体积（引擎的挤压/地形很容易做到），这一次就永久放弃，再也没有第二次机会
 *     ——这正是「关着门可能不会结算」。
 *
 * 状态机做三件事，每一步都幂等、可重试，且有超时兜底：
 *   1) 让门真正经历一次「开启」（本来就开着的跳过）—— 补上引擎缺的 Opened；
 *   2) 把掉队的人补传回安全屋体积内（最多 SAFEROOM_SETTLE_RETRY_MAX 次，间隔递增），
 *      只有「全员都在屋内」才继续 —— 伪造事件没用，引擎会自己查出谁在屋外；
 *   3) 关门并补发 CheckpointDoorClosed —— 补上引擎缺的 Closed，触发真正的过关链。
 *
 * 安全边界（逐条都有守卫，不改任何地图实体的开关状态）：
 *   · 只发标准实体输入（Open / Close / 传送），绝不改 spawnflags / lock，
 *     不解锁、不锁门、不调用任何硬换图；
 *   · 区域索引 / EntRef 双重校验，换回合、换图后 ResetRound 会清空区域表，
 *     timer 残留时索引对不上就直接放弃；
 *   · 门实体必须存在且 classname 在门类白名单里，才对它发输入；
 *   · 安全屋里一个存活生还者都没有时不做任何动作（说明传送其实没落地）；
 *   · 门被锁住导致 Open 无效时，重发次数有上限（SAFEROOM_SETTLE_RETRY_MAX），
 *     不无限刷，并留一条错误日志说明本回合可能无法过关。
 *
 * @param index 区域索引（timer 每一步都会重新校验，防止跨回合残留）
 */
void ScheduleSaferoomDoorFix(int index)
{
	if (!g_cvEnable.BoolValue || !g_cvSaferoomDoor.BoolValue)
	{
		return;
	}

	if (index < 0 || index >= g_iAreaCount || g_iAreaType[index] != AREA_SAFEROOM)
	{
		return;
	}

	// 纯坐标区域没有实体，也就没有 info_changelevel 可对照，直接跳过
	if (g_iAreaRef[index] == 0)
	{
		return;
	}

	// 已经在跑：不重复启动（同一区域 FinishCountdown 只会走一次，
	// 这里再挡一层，避免任何异常路径下叠加状态机）
	if (g_hDoorFix != null)
	{
		return;
	}

	g_iDoorFixArea     = index;
	g_iDoorFixRef      = g_iAreaRef[index];
	g_fSettleDeadline  = GetGameTime() + SAFEROOM_SETTLE_TIMEOUT;
	g_iSettleRetry     = 0;
	g_fSettleNextRetry = 0.0;
	g_iSettleOpenTries = 0;
	g_fSettleNextOpenTry  = 0.0;
	g_bSettleDoorOpened   = false;
	g_bSettleDoorClosed   = false;
	g_bSettleEventFired   = false;

	// TIMER_REPEAT：状态机每一步都自己判断该不该继续，跑完自己 Stop
	g_hDoorFix = CreateTimer(SAFEROOM_SETTLE_TICK, Timer_SaferoomDoorFix, 0,
		TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);

	if (g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] 启动安全屋结算状态机（区域 #%d，区域实体 #%d）", index, g_iDoorFixRef);
	}
}

/**
 * 安全屋结算状态机（每 SAFEROOM_SETTLE_TICK 跑一步）。
 *
 * 返回值约定：
 *   Plugin_Continue -> 还没结束，下个 tick 继续；
 *   Plugin_Stop     -> 结束（成功、无需处理、或超时），timer 会被回收。
 */
public Action Timer_SaferoomDoorFix(Handle timer)
{
	int index = g_iDoorFixArea;
	int ref   = g_iDoorFixRef;

	// 每一 tick 都重新校验：换图 / 换回合后区域表已被清空，残留 timer 必须立刻退出，
	// 否则会拿着旧索引去读别人的区域数据（甚至越界）
	if (!g_bMapStarted || !g_cvEnable.BoolValue || !g_bReady)
	{
		SettleFinish("地图已结束 / 插件已关闭");
		return Plugin_Stop;
	}

	if (index < 0 || index >= g_iAreaCount)
	{
		SettleFinish("区域表已重置");
		return Plugin_Stop;
	}

	if (g_iAreaRef[index] != ref || g_iAreaType[index] != AREA_SAFEROOM)
	{
		SettleFinish("区域索引/EntRef 对不上（已换回合或换图）");
		return Plugin_Stop;
	}

	int changelevel = GetAreaEntity(index);

	if (changelevel == -1)
	{
		SettleFinish("区域实体已删除");
		return Plugin_Stop;
	}

	// ---- 超时兜底：宁可留一条明确的日志，也不让 timer 无限跑 ----------------
	if (GetGameTime() >= g_fSettleDeadline)
	{
		LogError("[cptele] 安全屋结算超时（%.1f 秒）：区域 #%d，屋内 %d/%d 人，已开门=%d 已关门=%d 已补发事件=%d。本回合可能没有结算，请用 l4d2_cptele_verbose 1 复现并检查门是否被锁",
			SAFEROOM_SETTLE_TIMEOUT, index, CountArrivedSurvivors(index), CountAliveSurvivors(),
			g_bSettleDoorOpened, g_bSettleDoorClosed, g_bSettleEventFired);

		SettleFinish("超时");
		return Plugin_Stop;
	}

	int arrived = CountArrivedSurvivors(index);

	// 传送明明送过人，落位后安全屋里却一个人都没有：说明落点被引擎的
	// WarpToValidPositionIfStuck / 几何体挤到了体积外，这种情况开门关门也救不回来，
	// 直接报错留证据，不假装处理了
	if (arrived <= 0)
	{
		LogError("[cptele] 安全屋结算：区域 #%d 传送后安全屋内没有任何存活生还者，落点可能不在安全屋触发体积内", index);

		SettleFinish("屋内无人");
		return Plugin_Stop;
	}

	int door = FindSaferoomDoor(changelevel);

	if (door == -1)
	{
		// 找不到门就没法提供引擎需要的两次状态变化。仍把事件补发出去，
		// 因为「全员已在屋内」这件事本身对引擎是有意义的输入（引擎会自己再判 IsTouching）。
		if (!g_bSettleEventFired && CountArrivedSurvivors(index) >= CountAliveSurvivors())
		{
			FireCheckpointClosed(changelevel, door, index, arrived, "找不到门，仅补发事件");
		}
		else if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 安全屋结算：找不到本图的安全门实体（区域 #%d），等待全员到齐后只补发事件", index);
		}

		// 门都找不到，继续等下去也不会有进展
		SettleFinish("找不到安全门");
		return Plugin_Stop;
	}

	char sClass[64];

	if (!GetEntityClassname(door, sClass, sizeof(sClass)) || !IsSafeDoorClass(sClass))
	{
		LogError("[cptele] 安全屋结算：实体 #%d 的 classname 是 \"%s\"，不是门类实体，忽略", door, sClass);

		SettleFinish("门类不符");
		return Plugin_Stop;
	}

	// ---- 第 1 步：让门真正经历一次「开启」（补上引擎缺的 Opened）-------------
	// 这一步修的是「门本来就开着，没人去关」那一半：
	// 门本来就开着时我们不需要再开它，但也**不能直接 return**（1.2.2 的 bug），
	// 而是要把它记成「已经开过」，继续往下走关门流程。
	if (!g_bSettleDoorOpened)
	{
		int state = GetEntProp(door, Prop_Data, "m_eDoorState");

		if (state == DOOR_STATE_OPENED)
		{
			// 门已经是「已开启」：这正是玩家开门进屋后引擎能正常过关的状态。
			// 记下来，接着去关门 —— 关键区别就在这，不再提前退出。
			g_bSettleDoorOpened = true;

			if (g_cvVerbose.BoolValue)
			{
				PrintToServer("[cptele] 安全门 #%d 本来就处于开启状态，跳过 Open，继续走关门流程（区域 #%d）", door, index);
			}
		}
		else if (state == DOOR_STATE_OPENING_IN_PROGRESS)
		{
			// 门正在开：等它开到 DOOR_STATE_OPENED 再继续，否则现在发 Close 会被引擎丢掉
			if (g_cvVerbose.BoolValue)
			{
				PrintToServer("[cptele] 安全门 #%d 正在开启中，等待开到位（区域 #%d）", door, index);
			}

			return Plugin_Continue;
		}
		else if (state == DOOR_STATE_CLOSING_IN_PROGRESS)
		{
			// 门正在关：等它关到位，下一 tick 会重新走 Open 分支
			if (g_cvVerbose.BoolValue)
			{
				PrintToServer("[cptele] 安全门 #%d 正在关闭中，等待关到位（区域 #%d）", door, index);
			}

			return Plugin_Continue;
		}
		else
		{
			// state == DOOR_STATE_CLOSED：完全关闭，补一次标准 Open（等价玩家开门进屋）
			// 重发之间要留时间给引擎的 think：Open 被接受后 m_eDoorState 通常下一帧就变
			// DOOR_STATE_OPENING_IN_PROGRESS，但门是被锁住还是被别的插件压回去，得给
			// 引擎几个 tick 才看得出来。间距用 SAFEROOM_SETTLE_RETRY_DELAY，别每 0.25s 就判死。
			if (GetGameTime() < g_fSettleNextOpenTry)
			{
				return Plugin_Continue;
			}

			if (g_iSettleOpenTries >= SAFEROOM_SETTLE_RETRY_MAX)
			{
				// Open 反复无效：门被锁了。仅作诊断记录，绝不解锁
				LogError("[cptele] 安全门 #%d 发送 %d 次 Open 仍然无法开启（locked=%d），本回合可能无法过关；请确认该地图安全门是否被锁住",
					door, g_iSettleOpenTries, view_as<bool>(GetEntProp(door, Prop_Data, "m_bLocked")));

				// 门开不了也要把「全员在屋内」的事件发出去，尽最大努力让引擎能判过关
				if (CountArrivedSurvivors(index) >= CountAliveSurvivors() && !g_bSettleEventFired)
				{
					FireCheckpointClosed(changelevel, door, index, arrived, "门无法开启，仅补发事件");
				}

				SettleFinish("门无法开启");
				return Plugin_Stop;
			}

			g_iSettleOpenTries++;
			g_fSettleNextOpenTry = GetGameTime() + SAFEROOM_SETTLE_RETRY_DELAY;

			AcceptEntityInput(door, "Open");

			if (g_cvVerbose.BoolValue)
			{
				PrintToServer("[cptele] 安全门 #%d 已发送 Open（第 %d 次，state=%d），等待开启完成（区域 #%d）",
					door, g_iSettleOpenTries, state, index);
			}

			return Plugin_Continue;
		}
	}

	// ---- 第 1.5 步：等门真的开到位，再进入关门 ------------------------------
	// 门还在开的过程中就发 Close，引擎会把这次 Close 丢掉（关门动作被打断），
	// 于是「关门 -> 引擎收到 Closed」这条链又断了。必须等 DOOR_STATE_OPENED。
	if (!g_bSettleDoorClosed)
	{
		int state = GetEntProp(door, Prop_Data, "m_eDoorState");

		if (state != DOOR_STATE_OPENED)
		{
			if (g_cvVerbose.BoolValue)
			{
				PrintToServer("[cptele] 安全门 #%d 尚未完全开启（state=%d），暂不关门（区域 #%d）", door, state, index);
			}

			return Plugin_Continue;
		}
	}

	// ---- 第 2 步：把掉队的人补传回安全屋体积内 --------------------------------
	// 引擎的 OnCheckpointDoorClosed 会逐个 IsTouching 判「谁还在屋外」，只要有一个
	// 人被挤出体积，这一次关门就等于白关。12v12 有 12 个人，挤出去很正常，
	// 所以这里允许补传若干次（间隔递增），把所有人真正塞进体积内再关门。
	int alive = CountAliveSurvivors();

	if (alive > 0 && arrived < alive)
	{
		if (g_iSettleRetry >= SAFEROOM_SETTLE_RETRY_MAX)
		{
			// 补传次数用尽还有人在屋外：说明这些人的落点确实进不了体积
			// （或者他们正在被特感拖走 / 挂在边缘）。不伪造事件，留日志收尾。
			LogError("[cptele] 安全屋结算：补传 %d 次后屋内仍只有 %d/%d 人（区域 #%d），本回合可能无法结算；请检查落点是否在安全屋触发体积内、以及是否有生还者被特感控制",
				SAFEROOM_SETTLE_RETRY_MAX, arrived, alive, index);

			SettleFinish("补传后仍不齐");
			return Plugin_Stop;
		}

		if (GetGameTime() < g_fSettleNextRetry)
		{
			// 还没到下次补传的时间（给物理挤压 / 引擎落位留时间）
			return Plugin_Continue;
		}

		g_iSettleRetry++;
		g_fSettleNextRetry = GetGameTime() + SAFEROOM_SETTLE_RETRY_DELAY * float(g_iSettleRetry);

		int moved = SettleGatherSurvivors(index);

		if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 安全屋结算：第 %d 次补传，把 %d 名掉队生还者重新送进安全屋（原屋内 %d/%d 人，区域 #%d）",
				g_iSettleRetry, moved, arrived, alive, index);
		}

		// 传完这一批等下一 tick 重新统计，不要在同一 tick 里连续传
		return Plugin_Continue;
	}

	// ---- 第 3 步：关门 + 补发 CheckpointDoorClosed（补上引擎缺的 Closed）-----
	// 走到这里说明：门已经开到位、所有存活生还者都在安全屋体积内。
	// g_cvSaferoomForceDoor 管的就是"这一层"（1.2.2 起就是这个语义：只做 Open 不补关门）：
	//   0 = 只开门，门交给玩家自己关（老用法），1 = 由插件把关门 + 补发事件做完。
	// 1.2.3 起它管的是整个"关门 + 补发事件"阶段，而不只是 0.6s 后那一次补发。
	if (!g_cvSaferoomForceDoor.BoolValue)
	{
		SettleFinish("forcedoor=0，只开门不补发关门事件");
		return Plugin_Stop;
	}

	if (!g_bSettleDoorClosed)
	{
		// 物理关门是最"正统"的触发源：门自己的 OnClose 只会在关门完成时把事件送给
		// info_changelevel，引擎认这个。发完仍会再补一次实体输入，双保险。
		AcceptEntityInput(door, "Close");
		g_bSettleDoorClosed = true;

		if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 安全屋结算：已对门 #%d 发送 Close，等待关门完成（屋内 %d/%d 人，区域 #%d）",
				door, arrived, alive, index);
		}

		return Plugin_Continue;
	}

	// 关门动作有自己的动画时间（约 0.5~1 秒）。门还没关到位就发事件，
	// 引擎那边 IsTouching 判定是对的，但门自己的 OnClose 会在之后重复发一次事件，
	// 这本身无害（引擎侧 ChangelevelThink 会去重），但为了让画面与逻辑一致，等关到位再发。
	int state = GetEntProp(door, Prop_Data, "m_eDoorState");

	// 门又被玩家（或引擎）开回去了：重发一次 Close，回到「等关门完成」这一步。
	// 不重发的话会一直等到 10 秒超时，白白丢掉一次过关机会。
	if (state == DOOR_STATE_OPENED || state == DOOR_STATE_OPENING_IN_PROGRESS)
	{
		g_bSettleDoorClosed = false;

		if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 安全屋结算：门 #%d 被重新打开（state=%d），重新关门（区域 #%d）", door, state, index);
		}

		return Plugin_Continue;
	}

	// 还在关：等它关到位再发事件
	if (state == DOOR_STATE_CLOSING_IN_PROGRESS)
	{
		if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 安全屋结算：等待门 #%d 关到位（state=%d，区域 #%d）", door, state, index);
		}

		return Plugin_Continue;
	}

	if (!g_bSettleEventFired)
	{
		FireCheckpointClosed(changelevel, door, index, arrived, "关门完成");
	}

	SettleFinish("完成");
	return Plugin_Stop;
}

/**
 * 把安全屋外（或体积判定失败）的存活生还者重新传送进区域，返回实际传送人数。
 *
 * 与 FinishCountdown 里的主传送的区别：这里**不看** g_bSeen / g_cvSkipSeen。
 * 那些开关的语义是「已经到过集合点的人不要再被传回来」，针对的是中途集合点和
 * 已经继续推进的生还者；而这里是终局安全屋结算的最后一步，任何人不在体积内
 * 都会导致引擎判「还有人在屋外」而不换图，所以必须把人补齐。
 */
int SettleGatherSurvivors(int index)
{
	float vDest[3];

	if (!GetAreaDestination(index, vDest))
	{
		return 0;
	}

	bool bFixedDest = g_bAreaDest[index];
	int moved = 0;

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

	return moved;
}

/**
 * 向 info_changelevel 补发「门关闭」这个引擎自己的输入。
 *
 * datamap 里 CBaseTrigger-info_changelevel 那两条 Input 的名字在 dump 里写成
 * "OnCheckpointDoorOpened / OnCheckpointDoorClosed"（同一份 dump 里其它 Input 都带
 * "Input" 前缀，这两条没有），所以两种拼法都发一遍：未知输入会被引擎静默忽略，
 * 不会报错，也不会重复触发过关（引擎侧有 ChangelevelThink 去重）。
 */
void FireCheckpointClosed(int changelevel, int door, int index, int arrived, const char[] sReason)
{
	AcceptEntityInput(changelevel, "OnCheckpointDoorClosed");
	AcceptEntityInput(changelevel, "CheckpointDoorClosed");

	g_bSettleEventFired = true;

	if (g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] 已补发 CheckpointDoorClosed（%s）：门 #%d，info_changelevel #%d，屋内 %d 人（区域 #%d）",
			sReason, door, changelevel, arrived, index);
	}
}

/**
 * 收尾：把状态机挂起槽全部清干净。
 *
 * 这个函数只会从 Timer_SaferoomDoorFix 里调用，而调用点全部紧跟着 return Plugin_Stop，
 * 所以**不能**在这里 delete timer —— 正在执行的重复 timer 由 Plugin_Stop 自己回收。
 * 这里只负责把引用与进度字段清空，让 ScheduleSaferoomDoorFix 的下一次调用能重新启动。
 */
void SettleFinish(const char[] sReason)
{
	if (g_cvVerbose.BoolValue && g_iDoorFixArea >= 0)
	{
		PrintToServer("[cptele] 安全屋结算结束（%s）：区域 #%d", sReason, g_iDoorFixArea);
	}

	g_hDoorFix = null;

	g_iDoorFixArea        = -1;
	g_iDoorFixRef         = 0;
	g_fSettleDeadline     = 0.0;
	g_iSettleRetry        = 0;
	g_fSettleNextRetry    = 0.0;
	g_iSettleOpenTries    = 0;
	g_fSettleNextOpenTry  = 0.0;
	g_bSettleDoorOpened   = false;
	g_bSettleDoorClosed   = false;
	g_bSettleEventFired   = false;
}

/**
 * 找出「关底」那一个 changelevel 实体（作为安全屋区域）。
 *
 * 为什么不能只取第一个（1.2.1 及以前的做法）：
 *   直接遍历 .bsp 的实体 lump 扫了全部官方图，10 张图有 2 个 changelevel 候选，
 *   其中 7 张图的**第一个**是「起点 / 往回走」那个（spawnflags=2，map 指向上一张图、
 *   本图自己或空）：
 *     c1m2_streets     info map=c1m2_streets  flags=2   <- 第一个是回退
 *     c2m4_barns       info map=c2m3_coaster  flags=2   <- 第一个是回退
 *     c3m2_swamp       info map=c3m1_plankcountry flags=2
 *     c3m3_shantytown  info map=c3m2_shantytown flags=2
 *     c5m3_cemetery    info map=c5m3_cemetery flags=2
 *     c5m2_park / c5m4_quarter / c2m3_coaster 同样是 flags=2 的回退项在前
 *   取第一个会让「安全屋区域」指到开局那间屋：开局全员本来就在里面 -> 计数立刻达标
 *   -> 倒计时被立刻结束 -> 关底安全屋传送静默失效（这就是"以为是插件没生效"的真因）。
 *
 * 选择顺序（都基于上表实测出来的特征，有唯一解就早退，绝不靠猜）：
 *   1) 只保留 spawnflags & 2 == 0 的候选（剔掉"往回走"的那个）；
 *   2) 仍多于一个时，用 m_mapName 再筛：关底那个指向"下一张图"，回退项指向本图 / 空
 *      （c1m3_mall 是唯一两张都是 flags=0 的图，就靠这一条区分）；
 *   3) 还多于一个时，用 nav 的「最后一个检查点」判中心点（L4D_IsPositionInLastCheckpoint）；
 *   4) 再不行用「离最后一个安全门最近」（L4D_GetCheckpointLast，2000 HU 内）；
 *   5) 全都不成立才回落到第一个，并打 verbose 提示。
 *
 * @return changelevel 实体索引；一个都没有返回 -1
 */
int FindLastChangelevel()
{
	int aCand[16];
	int iCand = 0;
	int entity = -1;

	while ((entity = FindEntityByClassname(entity, "info_changelevel")) != -1)
	{
		if (iCand < sizeof(aCand))
		{
			aCand[iCand++] = entity;
		}
	}

	// 没有 info_changelevel 才回落到老的 trigger_changelevel
	if (iCand == 0)
	{
		entity = -1;

		while ((entity = FindEntityByClassname(entity, "trigger_changelevel")) != -1)
		{
			if (iCand < sizeof(aCand))
			{
				aCand[iCand++] = entity;
			}
		}
	}

	if (iCand <= 0)
	{
		return -1;
	}

	if (iCand == 1)
	{
		return aCand[0];
	}

	// ---- 1) 剔掉"往回走"的候选（spawnflags & 2）--------------------------
	int aPool[16];
	int iPool = 0;

	for (int i = 0; i < iCand; i++)
	{
		if ((GetEntProp(aCand[i], Prop_Data, "m_spawnflags") & 2) == 0)
		{
			aPool[iPool++] = aCand[i];
		}
	}

	// 整张图都被标成回退（罕见的三方图写法）：退化成原候选全集，别把功能直接关死
	if (iPool <= 0)
	{
		iPool = iCand;

		for (int i = 0; i < iCand; i++)
		{
			aPool[i] = aCand[i];
		}
	}

	if (iPool == 1)
	{
		if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 关底 changelevel 判定: entity #%d（按 spawnflags 剔掉回退项，候选 %d 个）",
				aPool[0], iCand);
		}

		return aPool[0];
	}

	// ---- 2) 用 m_mapName 再筛：关底那个指向"下一张图" --------------------
	char sCurrent[64];
	GetCurrentMap(sCurrent, sizeof(sCurrent));

	int aNext[16];
	int iNext = 0;

	for (int i = 0; i < iPool; i++)
	{
		// m_mapName 是 datamap 字段（char[32]），老版本引擎读不到时跳过，走后面的兜底
		if (!HasEntProp(aPool[i], Prop_Data, "m_mapName"))
		{
			continue;
		}

		char sTarget[64];

		if (GetEntPropString(aPool[i], Prop_Data, "m_mapName", sTarget, sizeof(sTarget)) <= 0)
		{
			continue;
		}

		if (sTarget[0] == '\0' || StrEqual(sTarget, sCurrent, false))
		{
			continue;
		}

		aNext[iNext++] = aPool[i];
	}

	if (iNext == 1)
	{
		if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 关底 changelevel 判定: entity #%d（按 m_mapName 命中下一张图，候选 %d 个）",
				aNext[0], iPool);
		}

		return aNext[0];
	}

	// 后面两步在"m_mapName 筛过之后仍有多个"时，优先在筛过的集合里挑
	if (iNext > 1)
	{
		iPool = iNext;

		for (int i = 0; i < iNext; i++)
		{
			aPool[i] = aNext[i];
		}
	}

	// ---- 3) 中心点是否在「最后一个检查点」体积内 --------------------------
	if (g_bNtvLastCp)
	{
		for (int i = 0; i < iPool; i++)
		{
			float vCenter[3];
			GetEntityCenter(aPool[i], vCenter);

			if (L4D_IsPositionInLastCheckpoint(vCenter))
			{
				if (g_cvVerbose.BoolValue)
				{
					PrintToServer("[cptele] 关底 changelevel 判定: entity #%d 落在最后一个检查点内",
						aPool[i]);
				}

				return aPool[i];
			}
		}
	}

	// ---- 4) 离「最后一个安全门」最近 --------------------------------------
	if (g_bNtvDoorLast)
	{
		int door = L4D_GetCheckpointLast();

		if (door > 0 && IsValidEntity(door))
		{
			float vDoor[3];
			GetEntPropVector(door, Prop_Send, "m_vecOrigin", vDoor);

			int best = -1;
			float fBest = 0.0;

			for (int i = 0; i < iPool; i++)
			{
				float vCenter[3];
				GetEntityCenter(aPool[i], vCenter);

				float fDist = GetVectorDistance(vDoor, vCenter);

				if (best == -1 || fDist < fBest)
				{
					best = aPool[i];
					fBest = fDist;
				}
			}

			if (best != -1 && fBest <= SAFEROOM_DOOR_MAX_DIST)
			{
				if (g_cvVerbose.BoolValue)
				{
					PrintToServer("[cptele] 关底 changelevel 判定: entity #%d 距最后一个安全门 %.0f HU",
						best, fBest);
				}

				return best;
			}
		}
	}

	// ---- 5) 回落 ---------------------------------------------------------
	if (g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] 无法判定关底 changelevel（候选 %d 个，剩余 %d 个），回落到 entity #%d；若本图安全屋传送无效请先查这里",
			iCand, iPool, aPool[0]);
	}

	return aPool[0];
}

/**
 * 找关底安全屋对应的那道安全门。
 *
 * 1) left4dhooks 的 L4D_GetCheckpointLast()：按流量距离挑「接近地图末尾」的
 *    安全门（DOOR_RANGE_TOLLERANCE = 2000 HU），官方图 / 三方图通用；
 * 2) 回落：离 info_changelevel 体积中心最近的 prop_door_rotating_checkpoint。
 *
 * @return 安全门实体索引；找不到返回 -1
 */
int FindSaferoomDoor(int changelevel)
{
	float vCenter[3];

	GetEntityCenter(changelevel, vCenter);

	if (g_bNtvDoorLast)
	{
		int door = L4D_GetCheckpointLast();

		if (door > 0 && IsValidEntity(door))
		{
			// 距离校验：这道门必须就在 info_changelevel 这间安全屋旁边。
			// L4D_GetCheckpointLast 用的是「离地图末尾最近」的粗略判定，
			// 万一判错（三方图常见），宁可回落到下一层，也不去开别处的门。
			float vDoor[3];

			GetEntPropVector(door, Prop_Send, "m_vecOrigin", vDoor);

			if (GetVectorDistance(vDoor, vCenter) <= SAFEROOM_DOOR_MAX_DIST)
			{
				return door;
			}

			if (g_cvVerbose.BoolValue)
			{
				PrintToServer("[cptele] L4D_GetCheckpointLast 返回的门 #%d 离安全屋 %.0f HU，超出 %.0f，改用最近门判定",
					door, GetVectorDistance(vDoor, vCenter), SAFEROOM_DOOR_MAX_DIST);
			}
		}
	}

	int best = -1;
	float fBest = 0.0;
	int entity = -1;

	while ((entity = FindEntityByClassname(entity, "prop_door_rotating_checkpoint")) != -1)
	{
		float vOrigin[3];

		GetEntPropVector(entity, Prop_Send, "m_vecOrigin", vOrigin);

		float fDist = GetVectorDistance(vOrigin, vCenter);

		if (best == -1 || fDist < fBest)
		{
			best = entity;
			fBest = fDist;
		}
	}

	// 最近的那道门也离得太远：说明这间安全屋压根没有 prop_door_rotating_checkpoint
	// （部分三方图用普通门 / func_door），交回调用方只记日志，不乱发输入。
	if (best != -1 && fBest > SAFEROOM_DOOR_MAX_DIST)
	{
		return -1;
	}

	return best;
}

/**
 * 门类实体白名单。「Open」是 CBasePropDoor / CBaseDoor 的标准输入，
 * 只有这几类 classname 接受它；不对其它实体乱发输入。
 */
stock bool IsSafeDoorClass(const char[] sClass)
{
	return StrEqual(sClass, "prop_door_rotating_checkpoint", false)
	    || StrEqual(sClass, "prop_door_rotating", false)
	    || StrEqual(sClass, "func_door", false)
	    || StrEqual(sClass, "func_door_rotating", false);
}

// ===========================================================================
//  计数
// ===========================================================================

void ClearSeenFlags()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		g_bSeen[i] = false;
	}
}

/**
 * 把当前站在区域里的存活生还者标记为「本次倒计时期间到过」。
 * 每秒调用一次，标记后不会再被清掉（离开区域也算到过）。
 */
void MarkSeenInArea(int index)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (g_bSeen[i] || !IsAliveSurvivor(i))
		{
			continue;
		}

		if (IsClientInArea(i, index))
		{
			g_bSeen[i] = true;
		}
	}
}

int CountSeenSurvivors()
{
	int count = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (g_bSeen[i] && IsAliveSurvivor(i))
		{
			count++;
		}
	}

	return count;
}

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

	// 安全屋结算状态机（1.2.3 起是一个 TIMER_REPEAT，必须显式 delete 才能停下）
	// 也要一起清，避免换图 / 换回合后还在旧区域上动作
	delete g_hDoorFix;
	g_hDoorFix = null;
	g_iDoorFixArea = -1;
	g_iDoorFixRef = 0;
	g_fSettleDeadline = 0.0;
	g_iSettleRetry = 0;
	g_fSettleNextRetry = 0.0;
	g_iSettleOpenTries = 0;
	g_fSettleNextOpenTry = 0.0;
	g_bSettleDoorOpened = false;
	g_bSettleDoorClosed = false;
	g_bSettleEventFired = false;

	g_bCountingDown = false;
	g_iSecondsLeft = 0;
	g_iActiveArea = -1;
	g_bRescueReady = false;
	g_bSiteAuthority = false;

	ClearSeenFlags();

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
