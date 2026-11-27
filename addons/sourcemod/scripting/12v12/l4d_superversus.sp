#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#undef REQUIRE_PLUGIN
#include <l4d2_fix_team_shuffle_edi>
#define REQUIRE_PLUGIN

/* 可选的 readyup 依赖。readyup-applemod 暴露了 IsInReady native（GetFeatureStatus 探到才调用），
   只用来实现"准备阶段不要跟准备面板抢屏幕"，readyup 不在时这条分支自动跳过。
   注意：readyup 另外内部有个 IsPlayerHiddenPanel（!hide/!show 用），它是插件内部函数、没有对外
   暴露 native，所以这里无法调用；面板兼容性靠下面的 GetClientMenu 判断 + IsInReady 两道门。 */
native bool IsInReady();

/* 可选依赖 spechud_appledmod（12v12 下"坦克HUD / tankhud"就是它画的 Panel）。
   坦克刷出 / 接管时，本插件要"关闭所有玩家的 tankhud"，靠这个 native 通知它：
     client = 0 → 关掉所有玩家的 tankhud；client > 0 → 只关这一名玩家的。
   该插件不在时 native 保持未绑定，调用前一律用 SiHud_NativeAvailable 探一次
   （与上面 IsInReady 同一套处理，见 AskPluginLoad2 的 MarkNativeAsOptional）。 */
native void SpecHud_TankHudDisable(int client);

#pragma semicolon 1; // Force strict semicolon mode.
#pragma newdecls required; 

// *********************************************************************************
// CONSTANTS
// *********************************************************************************
#define PLUGIN_VERSION "2.6.2-12v12"
#define CVAR_FLAGS			FCVAR_NOTIFY
#define TEAM_SPECTATOR	               1
#define TEAM_SURVIVOR	               2
#define TEAM_INFECTED	               3
#define DELAY_KICK_NONEEDBOT         0.7
/* 只给降级分支用：gamedata/签名不可用时退回去的 CreateFakeClient 两段式流程，
   必须把假客户端踢掉才会由引擎补上一个真正的 bot。主路径（NextBotCreatePlayerBot）
   完全不经过这里。 */
#define DELAY_KICK_FAKECLIENT        0.1
/* 队伍修正插件锁队还原队伍期间，自动进队要无限期等待（不消耗 JoinAttempts 的次数）。
   这里给一个独立的秒数上限，正常换图还原几秒内就结束，120 秒足以覆盖最慢的情况。 */
#define LOCK_WAIT_MAX_SECONDS        120
#define ZC_ZOMBIE                      0
#define ZC_SMOKER                      1
#define ZC_BOOMER                      2
#define ZC_HUNTER                      3
#define ZC_SPITTER                     4
#define ZC_JOCKEY                      5
#define ZC_CHARGER                     6
#define ZC_WITCH                       7
#define ZC_TANK                        8

// ---------------------------------------------------------------------------
// 特感辅助面板（sm_sihud）常量
// ---------------------------------------------------------------------------
#define SIHUD_TITLE              "特感辅助面板"
#define SIHUD_TXT_HINT           "输入!sihud或!infhud开关面板"
#define SIHUD_TXT_BLANK          " "
#define SIHUD_TXT_TANK_FIXED     "固定"    // 坦克行：本回合坦克不是按 flow 刷的（静态/事件刷出）
#define SIHUD_TXT_WITCH_FIXED    "固定"    // 女巫行：同上
#define SIHUD_PANEL_SECONDS      3      // 面板显示时长（秒）；比刷新间隔长，画面才连续
#define SIHUD_REFRESH_SECONDS    1.0    // 刷新间隔（秒）：需求 1 秒刷新
#define SIHUD_FORCE_SECONDS      2.0    // 需求：离开安全区 / 坦克刷出与接管时，强制显示面板的秒数
#define SIHUD_FORCE_REDRAW       0.25   // 强制期间的重画间隔（秒）：远小于 1 秒，
                                        // 这 2 秒里面板才一直压在最上面（被别的面板顶掉能立刻顶回来）
#define SIHUD_TEXT_BUDGET        510    // 面板总预算 511 字节，单行留 1 字节给换行
#define SIHUD_NAME_CHARS         2      // 玩家名保留的字符数（需求：只显示前两个字符）
#define SIHUD_SAFE_HEALTH        40     // "总血量>40"的门槛（倒地人数那一列用）
// 坦克玩家"让位给克面板"的时长：= 克面板显示总时间 + 1 秒。
//   克面板（坦克面板 / tankhud）由 spechud_appledmod 画，机制是"每秒重发 + 每次显示 3 秒"
//   （spechud_appledmod.sp:37 SPECHUD_DRAW_INTERVAL 1.0；spechud_appledmod.sp:764 tankHud.Send(..., 3)），
//   所以从坦克刷出到这块面板真正从屏幕上消失，总时间 = 最多 1 秒等待重发 + 3 秒显示 = 4~5 秒，
//   按需求口径取 5 秒；再 + 1 秒余量 = 6 秒，到点才关 tankhud、把本面板交给他。
//   这 6 秒里面板让位（g_fSiHudTankLockUntil），不受让位限制的只有那 2 秒强制显示。
#define SIHUD_TANKHUD_SECONDS    5      // 克面板在坦克玩家屏幕上的显示总时间（秒，用户口径）
#define SIHUD_DEFAULT_TANK_DELAY (SIHUD_TANKHUD_SECONDS + 1)    // sm_sihud_tank_delay 默认值 = 5 + 1 = 6
#define SIHUD_MAX_TANK_LINES     3      // 坦克行最多画几只（2.6.0：多坦克同时存活时逐只一行）
// 2.6.1（需求）：坦克行改成 `坦克1:4000 (1控/35%)` ——
//   ① **不显示玩家名称**（原 2.6.0 是"前两个字符 + *"，玩家要求去掉）；
//   ② 血量从"百分比"改成**具体血量**，且不显示上限（原来 `78%`，现在 `3120`）；
//   ③ 一控/二控后面补上**具体控制权（怒气）百分比**，参考 spechud 的 tankhud（`怒气: %d%%`）；
//   ④ 行首带序号 坦克1 / 坦克2 / 坦克3，多坦克同时存活时逐只一行，序号与行序一致。
// 完整形式：`坦克1:4000 (1控/35%)`；AI 坦克没有"几控"，写成 `坦克1:4000 (AI/35%)`。
#define SIHUD_TXT_TANK_AI        "AI"   // AI 坦克：没有"几控"，这一格用它顶替
#define SIHUD_TXT_TANK_AI_PC     "电脑"  // AI 坦克的怒气：与 spechud 的"怒气: 电脑"同口径，不报数字
#define SIHUD_TXT_TANK_CTRL_FIRST  "1控" // 该玩家本回合第 1 段完整控制权
#define SIHUD_TXT_TANK_CTRL_SECOND "2控" // 该玩家本回合第 2 段及以上完整控制权（同一玩家拿回同一辆坦克）
// 坦克玩家的面板交接状态（g_iSiHudTankPanel 的取值；见 SiHud_TankHandoverPanel）
#define SIHUD_TANKPANEL_NONE     0      // 这只坦克还没替他处理过
#define SIHUD_TANKPANEL_AUTO     1      // 面板是我们替他自动打开的（坦克结束后收回）
#define SIHUD_TANKPANEL_DONE     2      // 已经处理过：之后完全听玩家自己的 !sihud
/* 2.5.22 删掉的常量，改需求时别照着旧代码加回来：
   · SIHUD_SPAWN_LINES / SIHUD_MAX_SPAWNS / SIHUD_SPAWN_SCAN_ATTEMPTS / SIHUD_SPAWN_AHEAD_EPS：
     面板底部那两个刷新点行被"坦克 / 女巫"两行取代（百分比口径走 Versus Director 的
     boss flow percent，与顶部 HUD 一致），info_zombie_spawn 的 flow 采样整段删除；
   · SIHUD_EARLY_CLOSE_SLACK：SourceMod 的 Panel 只要收到按键（数字键也算）就会被关掉，
     按"提前多少秒消失"反推"玩家自己关的"必然误判 —— 玩家一按数字键面板就被永久关死；
   · SIHUD_TXT_WITCH_ALIVE：女巫"已生成"那行同样因为"刷出过就整行不画"被删。
   （SIHUD_TXT_TANK_AI / SIHUD_TXT_TANK_CTRL_FIRST / SIHUD_TXT_TANK_CTRL_SECOND 已在 2.6.0 按新需求恢复。） */
#define SIHUD_WPN_AWP            "weapon_sniper_awp"
#define SIHUD_WPN_SCOUT          "weapon_sniper_scout"

// ---------------------------------------------------------------------------
// 生还者 bot 创建失败统计（NextBotCreatePlayerBot 返回无效槽位 -1 的防御与日志限频）
// ---------------------------------------------------------------------------
#define NEXTBOT_FAIL_LOG_SECONDS   5.0	// "无效槽位"日志最短间隔（秒），需求：每 N 秒最多一条
#define NEXTBOT_FAIL_LOUD_COUNT    2	// 连续失败到第几次才写 error log（第 1 次只记 notice）
#define NEXTBOT_FAIL_DEGRADE_COUNT 10	// 连续失败次数达到这么多……
#define NEXTBOT_FAIL_DEGRADE_SECS  30.0	// ……且已持续这么久，才彻底降级（避免瞬时失败就降级）
#define NEXTBOT_LEGACY_RETRY_SECS  10.0	// 走 CreateFakeClient 兜底的最短间隔（秒）


char gameMode[16];
char gameName[16];
bool L4D1;
bool InfectedAllowed;

// m_survivorCharacter order in L4D2: Nick, Rochelle, Coach, Ellis,
// Bill, Zoey, Francis, Louis. L4D1 uses the last four models with IDs 0..3.
static const char SurvivorModels[][] =
{
	"models/survivors/survivor_gambler.mdl",
	"models/survivors/survivor_producer.mdl",
	"models/survivors/survivor_coach.mdl",
	"models/survivors/survivor_mechanic.mdl",
	"models/survivors/survivor_namvet.mdl",
	"models/survivors/survivor_teenangst.mdl",
	"models/survivors/survivor_biker.mdl",
	"models/survivors/survivor_manager.mdl"
};
bool SurvivorMapReady;
bool SurvivorModelErrorLogged[8];
int SurvivorModelsReady;
int TakeoverBlocked;
int SurvivorCharacterRepairs;
float NextTakeoverWarning;

ConVar SurvivorLimit;
ConVar InfectedLimit;

ConVar L4DInfectedLimit;
ConVar L4DSurvivorLimit;
ConVar GhostDelayMax;
ConVar L4DHooks;
ConVar L4DTown;
ConVar GameType;
ConVar PainPillsDR;
ConVar MinionLimit;

ConVar KillRes;
ConVar RespawnJoin;
ConVar MoreSiBotsVersus;
ConVar AutoJoin;
ConVar Management;
ConVar AllowSpectate;
ConVar BlockSpecInTank;
ConVar SuppressSpectate;
float NextSpectateNotice[MAXPLAYERS + 1];
int QueuedPummelOffset = -1;

ConVar SiSpMoreDelay;
ConVar cvar_minsurvivor;
ConVar RoundStateCache;

Handle SubDirector					= null;
Handle BotsUpdateTimer				= null;
Handle EmptyServerTimer = null;

// ---------------------------------------------------------------------------
// 特感辅助面板（sm_sihud / 聊天 !sihud）：状态、ConVar。实现见文件后半段
// "特感辅助面板"一节。
// ---------------------------------------------------------------------------
ConVar SiHudEnable;							// sm_sihud_enable：总开关
ConVar SiHudForceShow;						// sm_sihud_force_show：首次离开安全区是否强制显示 2 秒
ConVar SiHudForceKeep;						// sm_sihud_force_keep：强制显示结束后是否保持开启（2.6.0）
ConVar SiHudAutoOpen;						// sm_sihud_auto_open：进感染者队伍自动开启面板（2.6.0）
ConVar SiHudTankDelay;						// sm_sihud_tank_delay：坦克玩家多少秒后才关掉 tankhud
ConVar SiHudDebug;							// sm_sihud_debug：打印诊断日志
ConVar VersusBossBuffer;					// versus_boss_buffer：boss 刷出位置的余量（与 spechud 同口径）
bool g_bSiHudOn[MAXPLAYERS+1];				// 玩家是否开启面板（!sihud / 自动开启 / 坦克交接都会改）
bool g_bSiHudSent[MAXPLAYERS+1];			// 上一次发送成功与否（判断屏幕上的面板是不是我们自己的）
bool g_bSiHudAutoShownRound = false;		// 本回合"首次离开安全区强制显示"是否真的显示出去过
// 2.6.0：玩家自己用 !sihud 关掉过面板 -> 本回合内不再自动替他打开（进队自动开 / 强制显示后保持开启
// 都要看这个闩锁）。换队到生还者、新回合、换图时复位，所以"下回合/下次进特感"仍然会自己打开。
bool g_bSiHudUserOff[MAXPLAYERS+1];
float g_fSiHudTankLockUntil[MAXPLAYERS+1];	// 坦克玩家：到这一刻为止面板让位给他的 tankhud（强制显示不受它限制）
float g_fSiHudLastSendAt[MAXPLAYERS+1];		// 上一次成功发送面板的时刻
// 强制显示窗口（需求：离开安全区 / 坦克事件时对所有能看面板的玩家连续 2 秒强开）
//   g_fSiHudForceUntil > 当前时刻 = 该玩家在强制窗口内；窗口期间由
//   g_hSiHudForceTimer（SIHUD_FORCE_REDRAW 秒一次）按固定的快节奏重画。
float g_fSiHudForceUntil[MAXPLAYERS+1];
Handle g_hSiHudForceTimer = null;
// C：本回合"有人离开安全区"这件事是否已经由事件报过。准备阶段会把那一次强制显示挡掉，
//    由 Timer_SiHudRefresh 里的 1 秒轮询（SiHud_PollForceShow）补发，所以要先记下来。
bool g_bSiHudLeftSafeArea = false;
bool g_bSiHudSafeAreaNative = false;		// Left4DHooks 的 L4D_HasAnySurvivorLeftSafeArea
// 坦克 / 女巫状态（面板最下面"坦克 / 女巫"两行的判定 + "坦克刷出与接管"事件的判定）
int g_iSiHudTankClient = 0;					// 当前坦克玩家（含 AI bot；0=场上没有坦克）
int g_iSiHudTankControl = 0;				// 当前这只坦克已经被几个真人控制过（1=一控 2=二控及以上；调试日志用）
// 2.6.1：一控/二控改成**按"坦克这条命 + 玩家 SteamID"**记（2.6.0 的 g_iSiHudTankCtrl[MAXPLAYERS+1] 已删除）。
//   旧写法为什么"一直显示一控"：
//     旧代码把"第几次拿到坦克"存在 **client 槽位** 上（g_iSiHudTankCtrl[client]），只在 tank_spawn
//     事件和"1 秒轮询发现换了控制者"两条路径里 +1；而 12v12 里玩家转旁观 / 掉线重连 / 换槽位
//     都会占用新槽位、计数从 0 重新开始，加上"AI 坦克 → 真人接手"这类接管路径经常没有 tank_spawn
//     事件，于是绝大多数时候都数到 1 = 永远"一控"。
//   本服"二控"的口径（见 Apex.sp 文件头 1.7.4）：**同一个玩家 A 在控制权被消耗掉之后，又把同一辆
//   坦克拿回来，拿到第二次完整控制权** —— 所以判定必须跟着"坦克 + 玩家身份"走，不能跟着槽位走：
//     · g_sSiHudTankKey[i]   = 这辆坦克（client i）当前这段控制权属于谁（SteamID；"AI"=无人）
//     · g_iSiHudTankSeg[i]   = 该 key 在这辆坦克上已经拿到过几段完整控制权（1=一控 2+=二控）
//     · g_iSiHudTankPrevFrus[i] = 上一次读到的怒气，用来发现"怒气被复位 = 控制权又给了一段"
//   key 用 SteamID 而不是 client：掉线重连 / 换槽位后 SteamID 不变，判定不会被槽位复用打断。
char g_sSiHudTankKey[MAXPLAYERS+1][64];		// 该坦克当前控制者 key（SteamID / "AI" / ""）
int g_iSiHudTankSeg[MAXPLAYERS+1];			// 该 key 在这辆坦克上的完整控制权段数
int g_iSiHudTankPrevFrus[MAXPLAYERS+1];		// 上一帧读到的 m_frustration（检测"被复位"）
float g_fSiHudTankSegAt[MAXPLAYERS+1];		// 上一段被判定"消耗掉"的时刻（抑制抖动重复计数）
// 上一名"真人"控制者的 key 与他的段数：控制权掉给 AI 之后不能把他的段数丢掉，
// 否则同一名玩家从 AI 手里把同一辆坦克拿回来时会被重新数成"一控"（正是要修的 bug）。
char g_sSiHudTankPrevHuman[MAXPLAYERS+1][64];
int g_iSiHudTankPrevHumanSeg[MAXPLAYERS+1];
bool g_bSiHudTankSpawned = false;			// 本回合坦克刷出过（→ 没坦克在场时不再画"坦克"行）
// 2.5.22：面板不再区分"刷出还没死"和"刷出已经死"（刷出过的 boss 整行都不画，见 SiHud_GetBossLine），
// 所以原来的 g_bSiHudTankDead / g_bSiHudWitchDead 两个标记删掉了（留着只会变成编译告警 204）。
bool g_bSiHudWitchSpawned = false;			// 本回合女巫刷出过（→ 不再画"女巫"行）
// 坦克玩家的面板交接：tank_delay 让位窗口结束（他的 tankhud 关掉）后面板必须回到他屏幕上
int g_iSiHudTankPanel[MAXPLAYERS+1];		// SIHUD_TANKPANEL_*（0=没动过 1=替他自动打开 2=已处理）
bool g_bSiHudLimitMissLogged[7];			// 六个 z_versus_*_limit 读不到时"只记一次"
// Left4DHooks native 可用性：left4dhooks.inc 默认把这些 native 标成 optional，必须先探再用
bool g_bSiHudMaxFlowNative = false;			// L4D2Direct_GetMapMaxFlowDistance
bool g_bSiHudClientFlowNative = false;		// L4D2Direct_GetFlowDistance
bool g_bSiHudHighestNative = false;			// L4D_GetHighestFlowSurvivor
bool g_bSiHudFurthestFlowNative = false;	// L4D2_GetFurthestSurvivorFlow
bool g_bSiHudReadyUpNative = false;			// readyup 的 IsInReady（准备阶段不抢屏幕）
bool g_bSiHudBossFlowNative = false;		// 坦克/女巫出生百分比位置（L4D2Direct_GetVS*FlowPercent 等）
// 2.6.1：一控/二控的首选数据源 —— 引擎自己的"传克次数"（spechud 的 tankhud 显示"第N次"读的就是它）。
// left4dhooks.inc:321 把它标成 optional，必须先探再用。
bool g_bSiHudTankPassNative = false;		// L4D2Direct_GetTankPassedCount
bool g_bSiHudSpecHudNative = false;			// spechud_appledmod 的 SpecHud_TankHudDisable（关 tankhud）

// ---------------------------------------------------------------------------
// 生还者 bot 创建失败统计（见 SpawnSurvivorBotNextBot / NextBotNoteFailure）
// ---------------------------------------------------------------------------
float g_fNextBotFailLogAt = 0.0;			// 上次输出"无效槽位"日志的时刻
float g_fNextBotFailSince = 0.0;			// 本轮连续失败开始的时刻
int g_iNextBotFailStreak = 0;				// 连续失败次数
int g_iNextBotFailSuppressed = 0;			// 被限频压掉的日志条数
float g_fNextBotLegacyAt = 0.0;				// 上次走 CreateFakeClient 兜底的时刻
int g_iNextBotLegacyUses = 0;				// 兜底次数（诊断用）
bool g_bNextBotNoSlotNoticed = false;		// 本图"服务端没有空位"的 notice 是否已经记过（每图一条）

// ---------------------------------------------------------------------------
// 六种特感的单类上限 cvar 名（PickSiType 也在用；这里提前声明，因为特感辅助面板要先读它们）
// ---------------------------------------------------------------------------
char L4D1_limits[4][] = {"none", "z_gas_limit",			  "z_exploding_limit",	   "z_hunter_limit"};
char L4D2_limits[7][] = {"none", "z_versus_smoker_limit", "z_versus_boomer_limit", "z_versus_hunter_limit", "z_versus_spitter_limit", "z_versus_jockey_limit", "z_versus_charger_limit"};

Handle JoinTimer[MAXPLAYERS+1];
bool JoinPending[MAXPLAYERS+1];
bool JoinAutomatic[MAXPLAYERS+1];
bool NewConnection[MAXPLAYERS+1];
int JoinTarget[MAXPLAYERS+1];
int JoinAttempts[MAXPLAYERS+1];
int LockWaitSeconds[MAXPLAYERS+1];	// 因队伍修正锁队而等待的秒数（单独计数，不占 JoinAttempts）
bool SurvivorDied[MAXPLAYERS+1];
bool LateLoad;

// ---------------------------------------------------------------------------
// 2.5.20：禁止自动入队名单（l4d_superversus_nojoin_steamids）
//   暖服客户端这类"只站旁观、不该被拉进队伍"的账号写在这里：本插件的
//   连接后自动入队 / 平衡补位 / 入队重试（Join_Wait 每秒重试）都不会再碰它们。
//   支持 SteamID64 / STEAM_X:Y:Z / [U:1:accountid] 三种写法，逗号分隔。
// ---------------------------------------------------------------------------
ConVar NoJoinSteamIds;						// l4d_superversus_nojoin_steamids：名单原文
ConVar NoJoinBlockJoinTeam;					// l4d_superversus_nojoin_block_jointeam：是否连客户端 jointeam 也拦
ConVar NoJoinIps;							// l4d_superversus_nojoin_ips：IP 兜底（前缀匹配）
ConVar NoJoinNames;							// l4d_superversus_nojoin_names：显示名兜底
char g_sNoJoinIds[512];						// 名单原文缓存
char g_sNoJoinIps[256];						// IP 名单缓存
char g_sNoJoinNames[256];					// 名字名单缓存
bool g_bNoJoinClient[MAXPLAYERS+1];			// 该 client 是否命中名单
bool g_bChurnNoJoin[MAXPLAYERS+1];			// 由"反复被搬去旁观"自动判定（身份验证失败时的兜底）
int g_iSpecBounce[MAXPLAYERS+1];			// 10 秒窗口内被搬去旁观的次数
float g_fSpecBounceSince[MAXPLAYERS+1];		// 该窗口的起点
float g_fNoJoinHintAt[MAXPLAYERS+1];		// 提示节流

// ---------------------------------------------------------------------------
// 生还者 bot 创建方式（2.5.19）
//   主路径 = fbef0102 l4dmultislots 的做法：SDKCall NextBotCreatePlayerBot<SurvivorBot>
//   直接造一个 SurvivorBot，再 ChangeClientTeam(bot, TEAM_SURVIVOR)，
//   若 !IsPlayerAlive 再 SDKCall CTerrorPlayer::RoundRespawn。
//   不再有"假客户端 → 踢掉 → 引擎补 bot"的两段式，也没有中间占位状态。
//   两个 SDKCall 都内建在本插件里，不依赖任何独立 native 插件；
//   gamedata = addons/sourcemod/gamedata/l4d2_superversus_bots.txt。
//   任一步准备失败都不 SetFailState，而是退回旧的 CreateFakeClient 流程。
// ---------------------------------------------------------------------------
Handle g_hSDK_NextBotCreatePlayerBot = null;	// CBaseEntity* NextBotCreatePlayerBot<SurvivorBot>(const char *name)
Handle g_hSDK_RoundRespawn = null;				// void CTerrorPlayer::RoundRespawn()
bool g_bNextBotReady = false;					// true = 走新路径；false = 走 CreateFakeClient 降级路径
bool g_bNextBotDegradedWarned = false;			// 降级告警只印一次

enum JoinResult
{
	Join_Success,
	Join_Wait,
	Join_Failed
};

bool RoundStarted = false;

// ---------------------------------------------------------------------------
// 自动补位（2.5.14）：队伍修复完成 / 开门解禁后，把旁观玩家随机补进队伍
// ---------------------------------------------------------------------------
ConVar Autofill;				// 总开关
ConVar AutofillInfected;		// 生还者满员时是否补进特感
ConVar AutofillMinIdle;			// 旁观多少秒后才参与补位
ConVar AutofillDelay;			// 触发后延迟执行
ConVar AutofillDebug;			// 只在日志里打印细节
bool g_bAutofillFixDone = false;	// 本回合"队伍修复完成"这个触发点是否已经用掉
bool g_bAutofillDoorDone = false;	// 本回合"开门解禁"这个触发点是否已经用掉
bool g_bAutofillPending = false;	// 已排队一次补位（避免同一时刻叠多个 timer）
bool g_bFixWasRunning = false;		// 上一 tick 队伍修复是否还在进行中
float g_fSpecSince[MAXPLAYERS+1];	// 进入旁观队的时刻（0 = 不在旁观）

// ---------------------------------------------------------------------------
// 2.5.15：闲置（挂机托管 / 加载中却先占了身体）玩家 → 旁观
// ---------------------------------------------------------------------------
ConVar IdleToSpec;					// 0=关闭 1=释放托管链接(默认) 2=连身体一起移出并回收
ConVar IdleToSpecDelay;				// 进入闲置后等多少秒才处理
ConVar StripInfWeapons;				// 换到感染者时是否清掉残留的生还者武器
float g_fIdleSince[MAXPLAYERS+1];	// 该玩家进入闲置（托管着某具身体）的时刻（0 = 不闲置）
float g_fIdleReleasedAt[MAXPLAYERS+1];	// 上次释放闲置的时刻（防抖：引擎若又挂回链接，5 秒内不再抢）
float g_fIdleNoticeAt[MAXPLAYERS+1];	// 上次给该玩家发"已转为旁观"提示的时刻（30 秒冷却）
float g_fInGameSince[MAXPLAYERS+1];	// 本次进服时刻（GetGameTime，仅供 sm_svidle 诊断）

float SiTimes[MAXPLAYERS+1] = {0.0, ...};


StringMap SteamIDs;
StringMap TransitionPlayers;
StringMap DeadSurvivors;

public Plugin myinfo =
{
	name        = "Super Versus Reloaded",
	author      = "DDRKhat, Marcus101RR, Merudo, Foxhound27, Senip, RainyDagger, Shao",
	description = "Multiplayer capacity, team joining and AI filling; no automatic AFK, item grants or difficulty scaling.",
	version     = PLUGIN_VERSION,
	url         = "https://forums.alliedmods.net/showthread.php?p=2704058#post2704058"
}

// *********************************************************************************
// METHODS FOR GAME START & END
// *********************************************************************************
public void OnPluginStart()
{
	GetGameFolderName(gameName, sizeof(gameName));
	L4D1 = StrEqual(gameName, "left4dead", false);

	ConVar version = CreateConVar("sm_superversus_version", PLUGIN_VERSION, "L4D Super Versus 插件版本", CVAR_FLAGS|FCVAR_DONTRECORD);
	version.SetString(PLUGIN_VERSION); // Existing ConVars survive a plugin reload.
	
	L4DSurvivorLimit = FindConVar("survivor_limit");
	L4DInfectedLimit = FindConVar("z_max_player_zombies");
	SurvivorLimit = CreateConVar("l4d_survivor_limit", "12", "生还者最大人数", CVAR_FLAGS,true, 1.00, true, 24.00);
	InfectedLimit = CreateConVar("l4d_infected_limit", "12", "特感最大人数（不影响 AI 特感）", CVAR_FLAGS, true, 4.00, true, 24.00);
	cvar_minsurvivor = CreateConVar("l4d_static_minimum_survivor", "12", "生还者队最低人数（不足时自动补 AI bot）", CVAR_FLAGS, true, 4.00, true, 24.00);

	// Remove limits for survivor/infected
	SetConVarBounds(L4DSurvivorLimit, ConVarBound_Upper, true, 24.0);
	SetConVarBounds(L4DInfectedLimit, ConVarBound_Upper, true, 24.0);
	HookConVarChange(InfectedLimit, OnInfectedChanged);	HookConVarChange(L4DInfectedLimit, OnInfectedChanged);
	HookConVarChange(SurvivorLimit, OnSurvivorChanged);	HookConVarChange(L4DSurvivorLimit, OnSurvivorChanged);

	KillRes = CreateConVar("l4d_killreservation","0","是否清除大厅预留（需要 Left4Downtown / Left4DHooks）", CVAR_FLAGS,true,0.0,true,1.0);
	
	RespawnJoin = CreateConVar("l4d_respawn_on_join", "1" , "额外生还者加入时是否直接复活。0=否；1=是（仅首次）", CVAR_FLAGS, true, 0.0, true, 1.0);
	MoreSiBotsVersus =  CreateConVar("l4d_versus_si_more", "1" , "对抗/清道夫里真人特感不足 l4d_infected_limit 时，是否用 AI 特感补位", CVAR_FLAGS, true, 0.0, true, 1.0);
	AutoJoin = CreateConVar("l4d_autojoin", "2" , "新连接入队。3=旁观；2=战役进生还者/对抗补真人较少一方，同数随机；1=弹出队伍菜单；0=不处理", CVAR_FLAGS, true, 0.0, true, 3.0);
	Management = CreateConVar("l4d_management", "3", "队伍管理权限。3=队伍菜单+命令；2=仅命令；1=仅 !infected/!survivor/!join；0=无", CVAR_FLAGS, true, 0.0, true, 4.0);
	SiSpMoreDelay  = CreateConVar("director_si_more_delay","5","对抗中 AI 特感出生时，额外加到 z_ghost_delay_max 上的延迟（秒）", CVAR_FLAGS);
	
	//Cache CVArs
	GhostDelayMax = FindConVar("z_ghost_delay_max");
	L4DHooks = FindConVar("left4dhooks_version");
	L4DTown = FindConVar("left4downtown_version");
	GameType = FindConVar("mp_gamemode");
	PainPillsDR = FindConVar("pain_pills_decay_rate");
	MinionLimit = FindConVar("z_minion_limit");
	// 特感辅助面板最下面"坦克 / 女巫"两行（boss 出生位置）要用，与 spechud_appledmod 的算法同口径
	VersusBossBuffer = FindConVar("versus_boss_buffer");
	
	// 入队命令统一门禁：sm_join / sm_jg / sm_survivor / sm_sur / sm_infected / sm_inf
	// 全部经 RequestJoin() -> TryJoinTeam()，在 TryJoinTeam 开头由 TeamChangesLocked()
	// 拦截（l4d2_fix_team_shuffle_edi 尚未修复完队伍时一律返回 Join_Wait），
	// 再由 RequestJoin 的 QueueJoin 逐秒重试，队伍修复完成后的下一次重试才真正换队。
	RegConsoleCmd("sm_join", Join_Game, "Join Survivor or Infected team");
	RegConsoleCmd("sm_jg", Join_Game, "Join Survivor or Infected team");
	//RegConsoleCmd("sm_multistatus", MultiStatus, "Show actual multiplayer limits and pending joins");
	RegConsoleCmd("sm_survivor", Join_Survivor, "Join Survivor Team");
	RegConsoleCmd("sm_sur", Join_Survivor, "Join Survivor Team");
	RegConsoleCmd("sm_infected", Join_Infected, "Join Infected Team");
	RegConsoleCmd("sm_inf", Join_Infected, "Join Infected Team");
	/* 旁观指令：本插件只提供 sm_pg（聊天 !pg / /pg）。
	 *
	 * 原先注册的 sm_spectate / sm_spec / sm_s 已取消：这几个名字在仓库里被多个插件
	 * 重复注册（playermanagement.smx、pause.sp 都会注册同一批名字），谁生效取决于加载
	 * 顺序，导致"点旁观"有时走的是别的插件那套没有门禁的实现。
	 * 改成一个本插件独占的名字后，行为可预期：一定会经过 RequestJoin ->
	 * CanVoluntarilySpectate（坦克/被特感控制/开关禁用时拒绝）。
	 * 注意：其它插件里仍写着 FakeClientCommand(..., "sm_spectate") 的调用点不受影响，
	 * 它们会落到别家的 sm_spectate 上（见交付报告）。 */
	RegConsoleCmd("sm_pg", Join_Spectator, "加入旁观队伍（原 sm_spectate/sm_spec/sm_s 已取消）");
	AllowSpectate = CreateConVar("sm_allow_spectate_command", "1", "Allow the !pg (sm_pg) spectator command");
	// 自动补位（队伍修复完成 / 开门解禁后把旁观玩家随机拉进队伍）
	Autofill = CreateConVar("l4d_superversus_autofill", "1", "队伍修复完成或开局门锁解禁后，自动把旁观玩家随机补进队伍. 0=关闭.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	AutofillInfected = CreateConVar("l4d_superversus_autofill_infected", "0", "生还者名额补满后，剩余名额是否继续补进感染者队. 0=只补生还者(默认).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	AutofillMinIdle = CreateConVar("l4d_superversus_autofill_min_idle", "5.0", "旁观时长达到多少秒的玩家才参与补位（避免刚被转去旁观的人立刻被拉回）.", FCVAR_NOTIFY, true, 0.0, true, 120.0);
	AutofillDelay = CreateConVar("l4d_superversus_autofill_delay", "1.0", "触发后延迟多少秒执行补位.", FCVAR_NOTIFY, true, 0.0, true, 30.0);
	AutofillDebug = CreateConVar("l4d_superversus_autofill_debug", "0", "1=只在服务端日志里打印补位细节（默认不输出任何东西）.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	// 2.5.15：闲置（挂机托管）玩家 → 旁观
	//   玩家按闲置键、或接管流程里 L4D_SetHumanSpec 之后没接管成功，都会让一个生还者 bot 的
	//   m_humanSpectatorUserID 指向他（角色头顶显示"闲置：玩家名"），玩家本人却半挂在旁观。
	//   0 = 关闭本功能；1 = 释放托管（默认，身体交回 AI，人转成真旁观）；2 = 连身体一起移出并回收。
	IdleToSpec = CreateConVar("l4d_superversus_idle_to_spec", "1", "闲置(挂机托管)玩家处理: 0=关闭; 1=释放托管链接并转旁观(默认); 2=连托管的身体一起移出生还者队并回收.", FCVAR_NOTIFY, true, 0.0, true, 2.0);
	IdleToSpecDelay = CreateConVar("l4d_superversus_idle_to_spec_delay", "1.0", "玩家进入闲置(托管身体)后等多少秒才处理（默认 1.0，避开接管瞬间的正常短暂托管）.", FCVAR_NOTIFY, true, 0.0, true, 60.0);
	// 2.5.20：禁止自动入队名单（暖服客户端等）。默认值就是暖服机器人账号，可由 cfg 覆盖成空来关闭。
	NoJoinSteamIds = CreateConVar("l4d_superversus_nojoin_steamids", "76561198760610101",
		"名单内的玩家不会被本插件自动加入任何队伍（连接后自动入队 / 平衡补位 / Join_Wait 每秒重试 全部跳过）。SteamID64 / STEAM_X:Y:Z / [U:1:x]，逗号分隔；留空=关闭。",
		FCVAR_NOTIFY);
	NoJoinBlockJoinTeam = CreateConVar("l4d_superversus_nojoin_block_jointeam", "0",
		"1=名单内玩家自己发的 jointeam(2/3) 也一并拦掉（只能留旁观）；0=只拦本插件的自动入队（默认）。",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);
	// 身份兜底：SteamID 未验证/NoSteam 客户端时按 IP 与显示名识别（AFK 插件同款思路）
	NoJoinIps = CreateConVar("l4d_superversus_nojoin_ips", "",
		"按 IP 识别禁止自动入队的玩家（逗号分隔，支持前缀如 202.189.15.）。给 SteamID 取不到的暖服客户端兜底；留空=不用。",
		FCVAR_NOTIFY);
	NoJoinNames = CreateConVar("l4d_superversus_nojoin_names", "",
		"按显示名识别禁止自动入队的玩家（逗号分隔，精确匹配）。最后一层兜底：名字玩家可改，安全性低于 SteamID/IP；留空=不用。",
		FCVAR_NOTIFY);
	NoJoinSteamIds.AddChangeHook(OnNoJoinListChanged);
	NoJoinIps.AddChangeHook(OnNoJoinListChanged);
	NoJoinNames.AddChangeHook(OnNoJoinListChanged);
	AddCommandListener(Cmd_NoJoinTeam, "jointeam");
	ReloadNoJoinList();
	// 2.5.17：引擎会把新玩家先放进生还者队（活着、拿着手枪），随后平衡器才把他换到感染者；
	// 换队时引擎不清武器，玩家就会"人在感染者队却带着生还者的枪"。换到感染者时统一清一遍。
	StripInfWeapons = CreateConVar("l4d_superversus_strip_infected_weapons", "1", "真人换到感染者队时，清掉身上残留的生还者武器（防止新玩家先被放进生还者队拿枪、随后被换到特感时把枪带过去）. 0=关闭.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	BlockSpecInTank = CreateConVar("sm_blockspecintank", "0", "Block survivor spectating during a Tank", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	SuppressSpectate = CreateConVar("l4d_pm_supress_spectate", "0", "Don't announce spectator moves");
	GameData teamData = new GameData("l4d2_si_ability");
	if (teamData == null) SetFailState("Missing l4d2_si_ability gamedata");
	QueuedPummelOffset = teamData.GetOffset("CTerrorPlayer->m_queuedPummelAttacker");
	delete teamData;
	if (QueuedPummelOffset == -1) SetFailState("Missing CTerrorPlayer->m_queuedPummelAttacker offset");
	/* 特感辅助面板（旧 Team Panel 已删除，这里注册开关命令 sm_sihud / sm_infhud / 聊天 !sihud !infhud） */
	SiHudEnable = CreateConVar("sm_sihud_enable", "1", "特感辅助面板总开关. 0=关闭（所有人都打不开）.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	SiHudForceShow = CreateConVar("sm_sihud_force_show", "1", "生还者每回合首次离开安全区域时，是否给所有能看面板的玩家连续强制显示特感辅助面板 2 秒. 1=强制显示(默认); 0=不强制，只刷新已经开着面板的人.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	SiHudForceKeep = CreateConVar("sm_sihud_force_keep", "1", "强制显示（离开安全区 / 坦克刷出与接管）2 秒结束后，面板是否保持开启. 1=保持开启(默认，玩家自己 !sihud 才关); 0=旧行为（2 秒后自动收起，玩家得自己再输入一次 !sihud）.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	SiHudAutoOpen = CreateConVar("sm_sihud_auto_open", "1", "玩家进入感染者队伍（含中途进服时已经在感染者队）时，是否自动替他打开特感辅助面板. 1=自动打开(默认); 0=不自动打开，必须自己输入 !sihud.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	SiHudTankDelay = CreateConVar("sm_sihud_tank_delay", "6", "坦克玩家刷出/接管后，多少秒后才关掉他的坦克面板(克面板/tankhud)并把特感辅助面板交给他. 默认 6 = 克面板显示总时间 5 秒 + 1 秒（先让他看完自己的克面板）; 0=立刻交接（立刻关克面板、立刻显示本面板）. 大于 0 时这 N 秒里本面板让位; spechud 不在场/他的克面板已被关掉时永远立刻交接.", FCVAR_NOTIFY, true, 0.0, true, 60.0);
	SiHudDebug = CreateConVar("sm_sihud_debug", "0", "1=在服务端日志里打印特感辅助面板的诊断信息（自动开启、强制显示与保持、坦克事件与面板交接、按键不算关面板等）.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	RegConsoleCmd("sm_sihud", Cmd_SiHud, "开关特感辅助面板（聊天 !sihud；也可 sm_sihud on|off）");
	// 2.6.0：单独的开关入口（用户口径里的 infhud = 特感辅助面板），语义与 sm_sihud 完全一致
	RegConsoleCmd("sm_infhud", Cmd_SiHud, "开关特感辅助面板（聊天 !infhud；也可 sm_infhud on|off）");
	RegAdminCmd("sm_createplayer", Create_Player, ADMFLAG_CONVARS, "Create Survivor Bot");
	// 2.5.16：闲置判定体检（谁会被转旁观、谁被"慢加载保护"挡住）
	RegAdminCmd("sm_svidle", Cmd_IdleStatus, ADMFLAG_GENERIC,
		"列出每名玩家的闲置(挂机托管)判定: 队伍/进服时长/是否上过场/托管身体/持续闲置时长/新连接与入队标记");

	HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);
	HookEvent("player_bot_replace", Event_BotReplacedPlayer);
	HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);
	HookEvent("player_left_start_area", Event_PlayerLeftStartArea, EventHookMode_Post);
	HookEvent("player_left_checkpoint", Event_PlayerLeftStartArea, EventHookMode_Post);
	HookEvent("round_start", Event_RoundStart, EventHookMode_Post);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_Pre);
	HookEvent("finale_vehicle_leaving", Event_FinaleVehicleLeaving);
	// 自动补位：记录每个玩家进入旁观队的时刻，供"旁观够久才补位"判断
	HookEvent("player_team", Event_PlayerTeamSpecSince, EventHookMode_Post);
	// 特感辅助面板：坦克刷出 / 被接管 → 关掉所有玩家的 tankhud，并强制显示面板 2 秒
	HookEvent("tank_spawn", Event_TankSpawn, EventHookMode_Post);
	HookEvent("tank_killed", Event_TankKilled, EventHookMode_Post);
	// 特感辅助面板：最后两行的女巫行要不要画（已刷出 / 已死亡）
	HookEvent("witch_spawn", Event_WitchSpawn, EventHookMode_Post);
	HookEvent("witch_killed", Event_WitchKilled, EventHookMode_Post);
	// 常驻轮询用来观察"队伍修复完成"的跳变；句柄不保存（SourceMod 卸载插件时自动回收）
	CreateTimer(0.5, Timer_AutofillWatch, _, TIMER_REPEAT);
	// 2.5.15：常驻轮询把闲置（挂机托管）玩家转成旁观；句柄同样不保存
	CreateTimer(0.5, Timer_IdleToSpec, _, TIMER_REPEAT);
	// 特感辅助面板：1 秒刷新（句柄不保存，插件卸载时由 SourceMod 统一回收）
	CreateTimer(SIHUD_REFRESH_SECONDS, Timer_SiHudRefresh, _, TIMER_REPEAT);

	AddCommandListener(Cmd_JoinTeam, "jointeam");
	AddCommandListener(Cmd_StaySpectator, "sm_pg");
	// sm_afk 命令注册已取消，同名监听一并取消；恢复注册时同时恢复此行。
	//AddCommandListener(Cmd_StaySpectator, "sm_afk");
	AddCommandListener(Cmd_StaySpectator, "go_away_from_keyboard");
	
	SteamIDs = new StringMap();
	TransitionPlayers = new StringMap();
	DeadSurvivors = new StringMap();
	RoundStateCache = CreateConVar("l4d_superversus_round_state", "", "Internal round state for plugin reloads", FCVAR_DONTRECORD|FCVAR_HIDDEN);

	// Core settings are owned by the mode CFG. Do not execute a legacy
	// l4d_superversus.cfg containing removed features or stale team limits.

	/* 12v12 容量初始化必须放在本函数最末尾（所有 ConVar 都建好之后）：
	   给 l4d_survivor_limit 赋值会同步触发 survivor_limit 的变更钩子
	   （scripting/playermanagement.sp::survivor_limitChanged -> FixBotCount），
	   而 FixBotCount 里的 CreateFakeClient() 会让引擎立刻回调本插件的
	   OnClientPostAdminCheck；那一刻 KillRes / AutoJoin 等 ConVar 还没创建（句柄 0），
	   直接读 .BoolValue 就抛 "Invalid convar handle 0 (error 4)"。
	   日志证据：OnPluginStart:150 -> Initialize12v12Capacity:229 -> OnSurvivorChanged:223
	   -> survivor_limitChanged:154 -> FixBotCount:531(CreateFakeClient)
	   -> OnClientPostAdminCheck:755 (KillRes.BoolValue)。
	   注意这条同步回调不是本插件的 bot 制造流程引起的（主路径用 SDKCall 造 SurvivorBot，
	   降级路径才会 CreateFakeClient），但两种方式都会让引擎同步回调
	   OnClientPutInServer / OnClientPostAdminCheck，所以那边的句柄兜底必须留着。 */
	// SDKCall 必须在本函数末尾的容量连锁反应之前准备好。
	InitSurvivorBotSDKCalls();
	Initialize12v12Capacity();
}

public void OnInfectedChanged (Handle c, const char[] o, const char[] n)  {L4DInfectedLimit.IntValue = InfectedLimit.IntValue;}
public void OnSurvivorChanged (Handle c, const char[] o, const char[] n)  {L4DSurvivorLimit.IntValue = SurvivorLimit.IntValue;}

// This binary belongs exclusively to optional/12v12. Existing ConVars survive
// plugin reloads, so defaults alone cannot replace an old 4/4 setting.
void Initialize12v12Capacity()
{
	SurvivorLimit.IntValue = 12;
	InfectedLimit.IntValue = 12;
	cvar_minsurvivor.IntValue = 12;
	SyncTeamLimits();
}

void SyncTeamLimits()
{
	L4DSurvivorLimit.IntValue = SurvivorLimit.IntValue;
	L4DInfectedLimit.IntValue = InfectedLimit.IntValue;
}

public void OnConfigsExecuted()
{
	GameType.GetString(gameMode, sizeof(gameMode));
	InfectedAllowed = AreInfectedAllowed();
	SyncTeamLimits();
	// 所有插件都加载完之后才探得到 Left4DHooks 的可选 native
	SiHud_CheckNatives();
	if (LateLoad)
	{
		LateLoad = false;
		RestoreRunningRound();
	}
	if (!SvBotsAllowed()) QueueEmptyBotCleanup();
}

public void OnClientPutInServer(int client)
{
	NextSpectateNotice[client] = 0.0;
	g_fSpecSince[client] = (GetClientTeam(client) == TEAM_SPECTATOR) ? GetGameTime() : 0.0;
	// 2.5.16：闲置处理后置状态清零（进服时刻用于"慢加载保护"）
	g_fIdleSince[client] = 0.0;
	g_fIdleReleasedAt[client] = 0.0;
	g_fIdleNoticeAt[client] = 0.0;
	g_fInGameSince[client] = GetGameTime();
	SiHud_ResetClient(client);
	CancelJoin(client);
	if (!IsFakeClient(client)) ResumeBotPopulation();
	else if (!SvBotsAllowed()) QueueEmptyBotCleanup();
}

// PutInServer may precede authentication. PostAdminCheck retries this once the
// human is both in game and authenticated; connecting/loading clients do not count.
void ResumeBotPopulation()
{
	if (!SvBotsAllowed()) return;
	delete EmptyServerTimer;
	if (!RoundStarted) return;
	delete BotsUpdateTimer;
	BotsUpdateTimer = CreateTimer(0.2, Timer_BotsUpdate, _, TIMER_FLAG_NO_MAPCHANGE);
	StartInfectedCounter();
}

void QueueEmptyBotCleanup()
{
	// Keep the first deadline so repeated engine bot joins cannot postpone cleanup.
	if (EmptyServerTimer == null)
		EmptyServerTimer = CreateTimer(0.2, Timer_RecycleBotsOnEmpty, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void OnClientConnected(int client)
{
	// PutInServer/PostAdminCheck run again on maps and late plugin loads. Only a
	// connection observed here may override the engine's initial team assignment.
	CancelJoin(client);
	SurvivorDied[client] = false;
	NewConnection[client] = !IsFakeClient(client);
}


public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	LateLoad = late;
	RegPluginLibrary("applemod12v12_multiplayer");
	CreateNative("SV12_CanManageTeams", Native_CanManageTeams);
	CreateNative("SV12_RequestTeam", Native_RequestTeam);
	CreateNative("SV12_GetHumanTeam", Native_GetHumanTeam);
	CreateNative("SV12_ReconcileSurvivors", Native_ReconcileSurvivors);
	MarkNativeAsOptional("L4D_LobbyUnreserve");
	// 传送后的"卡住就推到有效位置"兜底。这是较新的 Left4DHooks native，
	// 旧版插件库没有它；标成 optional 才不会让本插件整体加载失败（调用处还会再探一次状态）。
	MarkNativeAsOptional("L4D_WarpToValidPositionIfStuck");
	// readyup 的 IsInReady：准备阶段跳过特感辅助面板（readyup 未加载时该 native 保持未绑定）
	MarkNativeAsOptional("IsInReady");
	// spechud_appledmod 的坦克HUD 关闭接口：该插件未加载时该 native 保持未绑定
	// （tankhud 关不掉而已，面板其它功能不受影响，调用处用 GetFeatureStatus 探过再调）
	MarkNativeAsOptional("SpecHud_TankHudDisable");
	return APLRes_Success;
}

bool CanManageTeams()
{
	return SurvivorMapReady && Management != null && Management.BoolValue
		&& L4D_IsVersusMode() && !TeamChangesLocked();
}

public any Native_CanManageTeams(Handle plugin, int numParams)
{
	return CanManageTeams();
}

public any Native_GetHumanTeam(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (!IsValidClient(client) || IsFakeClient(client)) return 0;
	return GetBotOfIdle(client) > 0 ? TEAM_SURVIVOR : GetClientTeam(client);
}

public any Native_RequestTeam(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	int team = GetNativeCell(2);
	if (!CanManageTeams() || !IsValidClient(client) || IsFakeClient(client)
		|| team < TEAM_SPECTATOR || team > TEAM_INFECTED) return false;
	NewConnection[client] = false;
	CancelJoin(client);
	// Admin requests still use the same lock, human capacity, owned-bot and
	// death checks. Only the voluntary-spectator policy is skipped.
	JoinResult result = TryJoinTeam(client, team, false, true);
	if (result == Join_Wait && team != TEAM_SPECTATOR)
	{
		QueueJoin(client, team, false, 0.3);
		return true;
	}
	return result == Join_Success;
}

public any Native_ReconcileSurvivors(Handle plugin, int numParams)
{
	if (!CanManageTeams() || !RoundStarted) return false;
	ReconcileSurvivors();
	return true;
}

void ReconcileSurvivors()
{
	int count;
	for (int client = 1; client <= MaxClients; client++)
		if (IsClientInGame(client) && GetClientTeam(client) == TEAM_SURVIVOR
			&& !IsClientInKickQueue(client)) count++;
	int limit = SurvivorLimit.IntValue;
	for (int bot = MaxClients; bot >= 1 && count > limit; bot--)
	{
		if (!IsValidSurvivorBot(bot) || IsClientInKickQueue(bot)
			|| HasIdlePlayer(bot)) continue;
		// Detach before the asynchronous kick, so repeated checks count it once.
		ChangeClientTeam(bot, TEAM_SPECTATOR);
		KickClient(bot, "Removing excess unowned survivor bot");
		count--;
	}
	SpawnCheck();
}

void RestoreRunningRound()
{
	// A late load misses round_start and safe-area exit events. Preserve an ended
	// round across reloads; upgrading from an older build falls back to survivors.
	if (RoundStarted || !IsServerProcessing()) return;
	if (!L4D1 && GameRules_GetProp("m_bIsTransitioningToNextMap")) return;
	char state[PLATFORM_MAX_PATH], expected[PLATFORM_MAX_PATH], map[PLATFORM_MAX_PATH];
	GetCurrentMap(map, sizeof(map));
	RoundStateCache.GetString(state, sizeof(state));
	Format(expected, sizeof(expected), "%s:0", map);
	if (StrEqual(state, expected)) return;
	Format(expected, sizeof(expected), "%s:1", map);
	bool knownActive = StrEqual(state, expected);
	bool aliveSurvivor;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || GetClientTeam(client) != TEAM_SURVIVOR) continue;
		if (IsPlayerAlive(client)) aliveSurvivor = true;
		if (!IsFakeClient(client))
		{
			RecordSteamID(client);
			SetSurvivorDeath(client, !IsPlayerAlive(client));
		}
		else if (GetIdlePlayer(client) > 0)
		{
			int owner = GetIdlePlayer(client);
			RecordSteamID(owner);
			SetSurvivorDeath(owner, !IsPlayerAlive(client));
		}
	}
	if (!knownActive && !aliveSurvivor) return;
	RoundStarted = true;
	CacheRoundState(true);
	StartRoundTimers();
}

void CacheRoundState(bool active)
{
	char map[PLATFORM_MAX_PATH], state[PLATFORM_MAX_PATH];
	GetCurrentMap(map, sizeof(map));
	Format(state, sizeof(state), "%s:%d", map, active);
	RoundStateCache.SetString(state);
}

// ------------------------------------------------------------------------
// Return true if the lobby-unreserve provider is available
// ------------------------------------------------------------------------
bool l4dt()
{
	if(L4DHooks != null || L4DTown != null)
	{
		return true;
	}
	return false;
} // Is Left4DHooks OR Left 4 Downtown 1/2 loaded? 

public void OnMapStart() 
{
	SurvivorMapReady = true;
	SurvivorModelsReady = 0;
	NextTakeoverWarning = 0.0;
	for (int i = 0; i < sizeof(SurvivorModelErrorLogged); i++) SurvivorModelErrorLogged[i] = false;
	EnsureSurvivorModels();
	GameType.GetString(gameMode, sizeof(gameMode));
	InfectedAllowed = AreInfectedAllowed();
	// 2.5.15：GetGameTime 换图后归零，闲置相关时间戳要一起清，
	// 否则上一张图的旧值（更大）会把新图的判断挡住。
	for (int i = 1; i <= MaxClients; i++)
	{
		g_fIdleSince[i] = 0.0;
		g_fIdleReleasedAt[i] = 0.0;
		g_fIdleNoticeAt[i] = 0.0;
		g_fInGameSince[i] = 0.0;
	}
	/* 同一套道理：bot 创建失败的限频/降级时间戳存的是上一张图的 GetGameTime，
	   换图归零后 "now - 旧值" 是负数 —— 新图第一次失败会被限频直接吞掉，
	   降级窗口也算错。这里必须一起清。 */
	g_fNextBotFailLogAt = 0.0;
	g_fNextBotFailSince = 0.0;
	g_iNextBotFailStreak = 0;
	g_iNextBotFailSuppressed = 0;
	g_fNextBotLegacyAt = 0.0;
	g_bNextBotNoSlotNoticed = false;
	if (!LateLoad) CacheRoundState(false);
	SiHud_ResetMap();
}

// ------------------------------------------------------------------------
// OnMapEnd()
// ------------------------------------------------------------------------
public void OnMapEnd()
{
	// Do not restore idle players through TakeOverBot while the map is unloading.
	SurvivorMapReady = false;
	SurvivorModelsReady = 0;
	delete EmptyServerTimer;
	// Some game transitions reconnect players. Preserve those players' teams even
	// when the engine produces another Connected/PostAdminCheck callback pair.
	TransitionPlayers.Clear();
	char auth[MAX_AUTHID_LENGTH];
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientConnected(client) && !IsFakeClient(client)
			&& GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth)))
			TransitionPlayers.SetValue(auth, true);
		NewConnection[client] = false;
	}
	GameEnd();
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	GameEnd();
}

// ------------------------------------------------------------------------
//  Clean up the timers at the game end
// ------------------------------------------------------------------------
void GameEnd()
{
	RoundStarted = false;
	CacheRoundState(false);
	delete SubDirector;
	delete BotsUpdateTimer;
	
	for(int i = 1; i <= MaxClients; i++)
	{
		delete JoinTimer[i];
		if (SurvivorMapReady) TakeOver(i);
	}

	// Reset SteamIDs, so previous players who join next round can respawn alive
	SteamIDs.Clear();
	
	for (int i = 0; i < sizeof(SiTimes); i++) SiTimes[i] = 0.0;
}

// ------------------------------------------------------------------------
// Event_RoundStart
// ------------------------------------------------------------------------
public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	RoundStarted = true;
	CacheRoundState(true);
	DeadSurvivors.Clear();
	for (int client = 1; client <= MaxClients; client++) SurvivorDied[client] = false;
	for (int i = 0; i < sizeof(SiTimes); i++) SiTimes[i] = 0.0;
	delete SubDirector;

	// 自动补位：新回合重置两个触发点，并记下当前是否还在队伍修复中
	g_bAutofillFixDone = false;
	g_bAutofillDoorDone = false;
	g_bFixWasRunning = TeamChangesLocked();

	// 特感辅助面板：新回合不继承上一场的坦克延迟窗口
	SiHud_ResetRound();

	StartRoundTimers();
}

void StartRoundTimers()
{
	for (int client = 1; client <= MaxClients; client++)
	{
		delete JoinTimer[client];
		if (JoinPending[client] && IsClientInGame(client) && !IsFakeClient(client))
		{
			JoinAttempts[client] = 0;
			JoinTimer[client] = CreateTimer(0.5, Timer_AutoJoinTeam, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
		}
	}
	delete BotsUpdateTimer;
	BotsUpdateTimer = CreateTimer(0.2, Timer_BotsUpdate, _, TIMER_FLAG_NO_MAPCHANGE);
	StartInfectedCounter();
}



// ------------------------------------------------------------------------
// Stop filling teams after rescue; the engine decides who actually escaped.
// ------------------------------------------------------------------------
public void Event_FinaleVehicleLeaving(Event event, const char[] name, bool dontBroadcast)
{
	GameEnd();
}

// *********************************************************************************
// METHODS RELATED TO PLAYER/BOT SPAWN AND KICK
// *********************************************************************************

// ------------------------------------------------------------------------
//  Each time a survivor spawns, setup timer to kick / spawn bots a bit later
// ------------------------------------------------------------------------
public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!IsValidClient(client)) return;

	if (IsFakeClient(client) && !SvBotsAllowed())
	{
		QueueEmptyBotCleanup();
		return;
	}
	
	// Adds very brief invulnerability to spawned SI infected bots in versus/scavenge. Otherwise they keep respawning dead
	if (GetClientTeam(client) == TEAM_INFECTED && InfectedAllowed && MoreSiBotsVersus.BoolValue && IsFakeClient(client)) SetGodMode(client, 0.1);

	/* 2.6.0：特感每一次刷出都补一次"面板该开着就开着"的兜底。
	   进队自动开启的主路径是 player_team（Event_PlayerTeamSpecSince），但换图/读图后
	   引擎有时只重发 player_spawn 不再发 player_team —— 用户反馈的"新玩家进入感染者队伍
	   不会自动开启面板"就出在这条缝里。玩家自己 !sihud 关过的照样不打开（g_bSiHudUserOff）。 */
	if (GetClientTeam(client) == TEAM_INFECTED && !IsFakeClient(client))
		SiHud_AutoOpen(client, "感染者出生");
	
	// Each survivor spawn updates bot capacity and records respawn eligibility.
	if (GetClientTeam(client) == TEAM_SURVIVOR)
	{
		if (IsPlayerAlive(client))
		{
			int owner = IsFakeClient(client) ? GetIdlePlayer(client) : client;
			if (owner > 0) SetSurvivorDeath(owner, false);
		}
		if (RoundStarted)
		{
			delete BotsUpdateTimer;
			BotsUpdateTimer = CreateTimer(2.0, Timer_BotsUpdate, _, TIMER_FLAG_NO_MAPCHANGE);
		}
		
		if (!IsFakeClient(client) && !InfectedAllowed && IsFirstTime(client))
			RecordSteamID(client); // Record SteamID of player.
			
		SetGhostStatus(client, false); // Prevents invinsible & invisible survivor bug
	}
	
	//  If Si bot spawns, remove oldest Si in queue
	if (IsFakeClient(client) && GetClientTeam(client) == TEAM_INFECTED
		&& GetSiType(client) >= ZC_SMOKER && GetSiType(client) <= ZC_CHARGER)
	{
		int OldestSi = GetOldestSi();
		if (OldestSi != -1) SiTimes[OldestSi] = 0.0;
	}
}


public int GetClientZC(int client)
{

	if (!IsValidEntity(client) || !IsValidEdict(client))
	{
		return 0;
	}
	return GetEntProp(client, Prop_Send, "m_zombieClass");
}

////////////////////////////////////////////////////////////////////


////////////////////////////////////////////////////////////////////

////////////////////////////////////////////////////////////////////

////////////////////////////////////////////////////////////////////

bool IsValidClient(int client)
{
	if (! (1 <= client <= MaxClients) || !IsClientInGame(client)) return false;

	return true;
}

////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////

// ------------------------------------------------------------------------
// If a player disconnects, update survivor bot capacity.
// ------------------------------------------------------------------------
public void OnClientDisconnect(int client)
{
	CancelJoin(client);
	NewConnection[client] = false;

	// 2.5.20：清掉禁止自动入队名单的后置状态
	g_bNoJoinClient[client] = false;
	g_bChurnNoJoin[client] = false;
	g_iSpecBounce[client] = 0;
	g_fSpecBounceSince[client] = 0.0;
	g_fNoJoinHintAt[client] = 0.0;

	// 2.5.16：清掉闲置处理的后置状态，避免同名/同槽位复用时误判
	g_fIdleSince[client] = 0.0;
	g_fIdleReleasedAt[client] = 0.0;
	g_fIdleNoticeAt[client] = 0.0;
	g_fInGameSince[client] = 0.0;

	SiHud_ResetClient(client);				//	Clean up si-hud panel state

	if(RoundStarted && SvBotsAllowed())
	{
		// Reset the timer, if one exists
		delete BotsUpdateTimer;
		BotsUpdateTimer = CreateTimer(1.0, Timer_BotsUpdate, _, TIMER_FLAG_NO_MAPCHANGE);	// re-update the bots
	}
	
	// The disconnecting client may still be counted here. Check after disconnect.
	if (!IsFakeClient(client))
	{
		delete EmptyServerTimer;
		EmptyServerTimer = CreateTimer(1.5, Timer_RecycleBotsOnEmpty, _, TIMER_FLAG_NO_MAPCHANGE);
	}
}

// ------------------------------------------------------------------------
// 空服回收：真人全走光后延迟一下（等 disconnect 流程收尾）再回收 bot
// ------------------------------------------------------------------------
public Action Timer_RecycleBotsOnEmpty(Handle timer)
{
	EmptyServerTimer = null;
	if (SvBotsAllowed()) return Plugin_Stop;
	delete BotsUpdateTimer;
	delete SubDirector;
	for (int i = 0; i < sizeof(SiTimes); i++) SiTimes[i] = 0.0;
	SvRecycleSurvivorBots();
	SvRecycleInfectedBots();
	return Plugin_Stop;
}

// ------------------------------------------------------------------------
// Bots are kicked/spawned after every survivor spawned and every player joined
// ------------------------------------------------------------------------
public Action Timer_BotsUpdate(Handle hTimer)
{
	BotsUpdateTimer = null;

	if (RoundStarted)
	{

		SpawnCheck();

	}
	return Plugin_Stop;
}


// ------------------------------------------------------------------------
// Check the # of survivors, and kick/spawn bots as needed
// ------------------------------------------------------------------------
void SpawnCheck()
{
	if(RoundStarted != true)  return;      // if during transition, don't do anything
	
	// 只在真人已经完成进服和身份验证后补位；连接中、读图中均不算。
	if (!SvBotsAllowed())
	{
		SvRecycleSurvivorBots();
		return;
	}
	
	int iSurvivor       = GetSurvivorTeam();
	//int iHumanSurvivor  = InfectedAllowed ? GetTeamPlayers(TEAM_SURVIVOR, false) : GetHumanCount();  // survivors excluding bots but including idles. If coop, counts spectators too (may be idles)
	//int iSurvivorLim    = SurvivorLimit.IntValue;
	//int iSurvivorMax    = iHumanSurvivor  >  iSurvivorLim ? iHumanSurvivor  : iSurvivorLim ;
	
	// iSurvivorMax is the maximum # of survivor we allow - we never kick human survivors

	if (iSurvivor >= cvar_minsurvivor.IntValue)  return;
	/* iSurvivor 只在进函数时读一次；每次补位调用内部都会自己重新读 GetSurvivorTeam()
	   并各自守住 SurvivorLimit。new bot 在 SpawnSurvivorBot() 返回时就已计入生还者队
	   （ChangeClientTeam 是同步生效的），所以同一帧连续补位既不会超员、也不会重复补同一格。
	   只有"确实补上了"才继续补下一格：旧循环无论补位成功与否都推进计数，失败一次就等于
	   少补一格（引擎拒绝造 bot 时就是这样）。失败就结束本次补位，交给下一轮触发去补：
	   玩家进服/断线/spawn 都会重新触发 SpawnCheck。 */
	for (int i = iSurvivor; i < cvar_minsurvivor.IntValue; i++)
	{
		if (!SpawnSurvivorBot()) break;
	}
}

// ------------------------------------------------------------------------
// Kick an unused survivor bot
// ------------------------------------------------------------------------

stock bool IsValidSurvivorBot(int client)
{
	if (!client) return false;
	if (!IsClientInGame(client)) return false;
	if (!IsFakeClient(client)) return false;
	if (GetClientTeam(client) != TEAM_SURVIVOR) return false;
	return true;
}
// ------------------------------------------------------------------------
// 生还者 bot 的 SDKCall 准备
//   gamedata: addons/sourcemod/gamedata/l4d2_superversus_bots.txt
//   失败只告警 + 降级，绝不 SetFailState：本插件是 12v12 服的核心，
//   签名随游戏更新失效时不能连累整个模式掉功能。
// ------------------------------------------------------------------------
void InitSurvivorBotSDKCalls()
{
	GameData gameData = LoadGameConfigFile("l4d2_superversus_bots");
	if (gameData == null)
	{
		DegradeSurvivorBotCreation("找不到 gamedata 文件 addons/sourcemod/gamedata/l4d2_superversus_bots.txt");
		return;
	}

	// CTerrorPlayer::RoundRespawn：新造的 SurvivorBot 若没实体化/没血，用它走引擎自己的复活流程
	StartPrepSDKCall(SDKCall_Player);
	bool configured = PrepSDKCall_SetFromConf(gameData, SDKConf_Signature, "CTerrorPlayer::RoundRespawn");
	Handle respawnCall = EndPrepSDKCall();
	g_hSDK_RoundRespawn = configured ? respawnCall : null;
	if (!configured && respawnCall != null) delete respawnCall;

	// NextBotCreatePlayerBot<SurvivorBot>：Windows 的签名落在 `E8 rel32` 这条 call 指令上，
	// 必须先解出 rel32 目标才是真正的函数入口（入口 prologue 各模板实例相同，无法用入口签名）；
	// Linux 用符号名，地址本身就是入口，不能解引用。
	Address addr = gameData.GetAddress("NextBotCreatePlayerBot<SurvivorBot>");
	if (addr != Address_Null)
	{
		if (gameData.GetOffset("OS") == 1) // 1 = windows, 2 = linux
		{
			Address rel32 = view_as<Address>(LoadFromAddress(addr + view_as<Address>(1), NumberType_Int32));
			addr += rel32 + view_as<Address>(5); // 5 = sizeof(E8 rel32)
		}
		StartPrepSDKCall(SDKCall_Static);
		configured = PrepSDKCall_SetAddress(addr);
		if (configured)
		{
			PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
			PrepSDKCall_SetReturnInfo(SDKType_CBasePlayer, SDKPass_Pointer);
		}
		Handle createCall = EndPrepSDKCall();
		g_hSDK_NextBotCreatePlayerBot = configured ? createCall : null;
		if (!configured && createCall != null) delete createCall;
	}
	delete gameData;

	if (g_hSDK_NextBotCreatePlayerBot == null)
	{
		DegradeSurvivorBotCreation("签名 NextBotCreatePlayerBot<SurvivorBot> 无法解析（call-site 未命中或 rel32 解不出函数入口）");
		return;
	}
	if (g_hSDK_RoundRespawn == null)
	{
		DegradeSurvivorBotCreation("签名 CTerrorPlayer::RoundRespawn 无法解析");
		return;
	}

	g_bNextBotReady = true;
	PrintToServer("[SV] 生还者 bot 创建方式: SDKCall NextBotCreatePlayerBot<SurvivorBot> + ChangeClientTeam + RoundRespawn（不再使用 CreateFakeClient 两段式）。");
}

// 关掉新路径并告警；之后 SpawnSurvivorBot() 会走 CreateFakeClient 降级分支。
void DegradeSurvivorBotCreation(const char[] reason)
{
	g_bNextBotReady = false;
	if (g_hSDK_NextBotCreatePlayerBot != null)
	{
		delete g_hSDK_NextBotCreatePlayerBot;
		g_hSDK_NextBotCreatePlayerBot = null;
	}
	if (g_hSDK_RoundRespawn != null)
	{
		delete g_hSDK_RoundRespawn;
		g_hSDK_RoundRespawn = null;
	}
	g_bNextBotDegradedWarned = true;
	PrintToServer("[SV] 警告: 生还者 bot 的 SDKCall 准备失败（%s）。已退回 CreateFakeClient 两段式造 bot，功能仍可用。", reason);
	LogError("[SV] NextBotCreatePlayerBot path disabled: %s", reason);
}

// ------------------------------------------------------------------------
// Spawn a survivor bot
//   manual = true 表示来自 sm_createplayer（管理员显式创建）
//   返回 true = 已造出一个进入生还者队的 AI bot（主路径的实体化/模型校验在下一帧
//   的 Frame_PlaceNewSurvivorBot 里收尾，不合格会当场收回）。
// ------------------------------------------------------------------------
bool SpawnSurvivorBot(const char[] botName = "SurvivorBot", bool manual = false)
{
	// Also covers manual/RCON creation and direct join requests.
	if (!SvBotsAllowed() || !EnsureSurvivorModels()) return false;
	// 生还者队已到上限就不再补。新路径下 ChangeClientTeam 同步生效，刚造好的 bot
	// 立刻会被 GetSurvivorTeam() 计入，所以挡得住同一帧的连续补位。
	if (GetSurvivorTeam() >= SurvivorLimit.IntValue) return false;

	// 主路径：直接让引擎实例化一个 SurvivorBot（没有"假客户端"中间态）
	if (g_bNextBotReady) return SpawnSurvivorBotNextBot(botName, manual);

	// 降级路径：gamedata / 签名 / SDKCall 不可用时退回原来的两段式
	if (!g_bNextBotDegradedWarned)
	{
		PrintToServer("[SV] 警告: 生还者 bot 的 SDKCall 不可用，继续使用 CreateFakeClient 两段式造 bot。");
		g_bNextBotDegradedWarned = true;
	}
	return SpawnSurvivorBotLegacy(botName, manual);
}

// ------------------------------------------------------------------------
// 主路径：NextBotCreatePlayerBot<SurvivorBot> → ChangeClientTeam → 必要时 RoundRespawn
// ------------------------------------------------------------------------
bool SpawnSurvivorBotNextBot(const char[] botName, bool manual)
{
	// 没有空余 player slot 时 CreatePlayerBot 会直接失败，先挡一次省得拿到无效应答
	if (GetClientCount(false) >= MaxClients) return false;

	int bot = SDKCall(g_hSDK_NextBotCreatePlayerBot, botName);

	/* NextBotCreatePlayerBot 内部就是 CreateFakeClient() + Instance()，返回 -1 就等于
	   引擎的 CreateFakeClient() 返回了 NULL（SourceMod 把空的 CBasePlayer 返回值记成 -1）。
	   旧代码在这里"同一 tick 立刻再调一次"，但 player 槽位是引擎帧末才回收的
	   （KickClient 也是下一帧才生效），同帧重试只会拿到同样的 -1，是死代码。
	   现在改成：失败按原因分流（没有可复用槽位 → 静默等下一次触发；该有位置却没造出来
	   → 报错，并按连续失败次数决定是否退回 CreateFakeClient 兜底）。 */
	if (!IsNextBotSlotUsable(bot))
	{
		NextBotReleaseInvalidSlot(bot);
		// 只有"引擎还有位置却没造出来"才退回旧的 CreateFakeClient 两段式补位（内部限频）
		if (NextBotNoteFailure(bot)) return NextBotLegacyFallback(botName, manual);
		return false;
	}

	// 成功：清失败统计
	g_iNextBotFailStreak = 0;
	g_iNextBotFailSuppressed = 0;
	g_fNextBotFailSince = 0.0;

	ChangeClientTeam(bot, TEAM_SURVIVOR);
	if (!IsClientInGame(bot) || GetClientTeam(bot) != TEAM_SURVIVOR)
	{
		LogError("[SV bot] 新建 bot userid=%d 未能进入生还者队（team=%d）",
			GetClientUserId(bot), GetClientTeam(bot));
		KickClient(bot, "Failed to join survivor team");
		return false;
	}

	// 刚 Instance() 出来的 SurvivorBot 可能还没实体化/没血 → 走引擎自己的回合复活流程
	if (!IsPlayerAlive(bot)) SDKCall(g_hSDK_RoundRespawn, bot);

	// 未实体化的 bot 拿不到模型，模型校验留给下一帧（见 Frame_PlaceNewSurvivorBot），
	// 那样判"这家身体能不能用"时 bot 已经完整 spawn 了。
	// 本帧只做一件事：把摆位和最终校验排到下一帧。
	if (manual)
		LogMessage("[SV bot] 管理员创建生还者 bot: userid=%d name='%s'", GetClientUserId(bot), botName);

	/* 摆位留到下一帧：引擎在创建流程收尾时还会自己摆一次位置，
	   上游 l4dmultislots 也是 RequestFrame 到下一帧才传送/补状态，
	   同帧传送可能被引擎覆盖。 */
	QueueSurvivorBotPlacement(bot);
	return true;
}

// 返回值校验：>0 且在 MaxClients 内、还是有效实体。（-1 = 引擎没造出来）
bool IsNextBotSlotUsable(int bot)
{
	if (bot <= 0 || bot > MaxClients) return false;
	return IsValidEntity(bot);
}

// 拿到无效槽位时不要留半成品客户端白占着 player slot
void NextBotReleaseInvalidSlot(int bot)
{
	if (bot > 0 && bot <= MaxClients && IsClientConnected(bot))
		KickClient(bot, "Failed to create survivor bot");
}

/* 引擎那边"还能不能再塞一个 player 客户端"的上限。
   MaxClients 是 sv_maxclients（12v12 必须是 31，见 l4dmultislots 的要求），但 l4dtoolz
   把 sv_maxplayers 写进引擎的玩家槽位表（m_numGameSlots）并通过 GetMaxHumanPlayers()
   暴露出来（本服 cfg/server.cfg 是 mv_maxplayers 30）。L4D2 里旁观者同样是 player，
   30 个 client 连满时再造 bot 引擎就没槽位了 —— 这就是日志里 "clients=30/31"
   却拿到 -1 的原因。没有 l4dtoolz 的服这个值等于 MaxClients。 */
int SvPlayerSlotCapacity()
{
	int capacity = GetMaxHumanPlayers();
	if (capacity > 0 && capacity < MaxClients) return capacity;
	return MaxClients;
}

/* 引擎的假客户端槽位不能复用：CBaseServer::CreateFakeClient() 内部 GetFreeClient()
   会 `if (client->IsFakeClient()) continue;` —— 刚被踢掉的 bot，在引擎把它的 client
   槽 Clear() 掉（m_bFakePlayer 复位）之前，那个槽位对"再造一个 player"是不可用的；
   当 m_Clients.Count() 已经到 MaxClients 时，CreateFakeClient() 就返回 NULL，
   也就是 NextBotCreatePlayerBot 返回的 -1。 */
bool SvHasPendingKickedSlot()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		/* IsClientInKickQueue 要求这个 client 已经在游戏里，否则 native 抛
		   "Client X is not in game"（日志 4 就是这个：
		   SvHasPendingKickedSlot → NextBotNoteFailure → SpawnSurvivorBotNextBot）。
		   空闲槽位、还在连接/读图的槽位本来就不可能处在"刚踢掉 bot、槽位未回收"的状态，跳过即可。 */
		if (!IsClientInGame(i)) continue;
		if (IsClientInKickQueue(i)) return true;
	}
	return false;
}

/* 引擎这次拒绝造 bot 属于常态（没有可复用的 player 槽位）时的处理：
   - 不写 error log：人满 / 槽位刚被回收时每张图都会撞上一次，不是插件故障
   - 不计入连续失败次数，因此也不会把 NextBot 主路径降级成 CreateFakeClient 两段式
   - 不重试：槽位空出来必然伴随客户端变动（OnClientDisconnect / player_spawn 都会重新
     触发 SpawnCheck），不需要自己拿定时器空转 */
void NextBotNoteNoSlot()
{
	if (g_bNextBotNoSlotNoticed) return;
	g_bNextBotNoSlotNoticed = true;
	LogMessage("[SV bot] 服务端暂时没有可复用的 player 槽位，本次补位跳过（clients=%d/%d，可玩槽位=%d，生还者=%d/%d）。客户端变动后由下一次 SpawnCheck 自动补上。",
		GetClientCount(false), MaxClients, SvPlayerSlotCapacity(), GetSurvivorTeam(), SurvivorLimit.IntValue);
}

/* 无效槽位统计 + 限频日志（需求：每 N 秒最多一条）。
   返回 true = "不该失败却失败了"，这次失败值得退回 CreateFakeClient 兜底；
   返回 false = 引擎没有可复用的 player 槽位，属于常态，什么都不用做。
   连续失败次数与持续时间同时达标才彻底降级：分批连刷 12 个 bot 时的一次性瞬时失败
   不该把整条 NextBot 路径废掉。 */
bool NextBotNoteFailure(int bot)
{
	// ① 引擎那边已经没位置（可玩槽位满 / 刚踢掉的 bot 槽位还没回收）：必然一直失败
	if (SvHasPendingKickedSlot() || GetClientCount(false) >= SvPlayerSlotCapacity())
	{
		NextBotNoteNoSlot();
		return false;
	}

	// ② 还有位置却没造出来：这才是异常

	float now = GetGameTime();
	g_iNextBotFailStreak++;
	if (g_fNextBotFailSince == 0.0) g_fNextBotFailSince = now;

	if (g_fNextBotFailLogAt != 0.0 && (now - g_fNextBotFailLogAt) < NEXTBOT_FAIL_LOG_SECONDS)
	{
		g_iNextBotFailSuppressed++;
	}
	else
	{
		char message[288];
		FormatEx(message, sizeof(message),
			"[SV bot] NextBotCreatePlayerBot<SurvivorBot> 返回无效槽位 %d"
			... "（连续第 %d 次；日志已限频=每 5 秒最多一条，本次压掉 %d 条；"
			... "clients=%d/%d，生还者=%d/%d，实体=%d/%d）",
			bot, g_iNextBotFailStreak, g_iNextBotFailSuppressed,
			GetClientCount(false), MaxClients, GetSurvivorTeam(), SurvivorLimit.IntValue,
			GetEntityCount(), GetMaxEntities());

		/* 第 1 次只记 notice：换图/回合开始/刚踢掉 bot 的瞬间撞上一次很常见
		   （引擎的 client 槽位池要下一次帧才回收），不该在 errors_*.log 里留一条 error。
		   第 2 次起仍按 error 记，保留"引擎真的坏了"的可观测性。 */
		if (g_iNextBotFailStreak < NEXTBOT_FAIL_LOUD_COUNT) LogMessage("%s", message);
		else LogError("%s", message);

		g_fNextBotFailLogAt = now;
		g_iNextBotFailSuppressed = 0;
	}

	if (g_iNextBotFailStreak >= NEXTBOT_FAIL_DEGRADE_COUNT
		&& (now - g_fNextBotFailSince) >= NEXTBOT_FAIL_DEGRADE_SECS)
	{
		char reason[192];
		FormatEx(reason, sizeof(reason),
			"连续 %d 次 NextBotCreatePlayerBot<SurvivorBot> 返回无效槽位（已持续 %.0f 秒），最近一次=%d",
			g_iNextBotFailStreak, now - g_fNextBotFailSince, bot);
		DegradeSurvivorBotCreation(reason);
	}
	return true;
}

/* 兜底：SDKCall 连续失败时退回 CreateFakeClient 两段式，保证 12v12 的座位照旧补上
   （SpawnCheck 只按 GetSurvivorTeam() 计数，两段式也是先把座位占住再让引擎换成真 bot）。
   限频：NEXTBOT_LEGACY_RETRY_SECS 内只用一次，避免每个 SpawnCheck 都造一次假客户端。 */
bool NextBotLegacyFallback(const char[] botName, bool manual)
{
	float now = GetGameTime();
	if (g_fNextBotLegacyAt != 0.0 && (now - g_fNextBotLegacyAt) < NEXTBOT_LEGACY_RETRY_SECS)
		return false;
	if (GetClientCount(false) >= MaxClients) return false;
	if (!SvBotsAllowed() || GetSurvivorTeam() >= SurvivorLimit.IntValue) return false;

	if (!SpawnSurvivorBotLegacy(botName, manual)) return false;
	// 限频时间戳只在真的补位成功时写：失败也写会把下一次兜底白锁 10 秒
	g_fNextBotLegacyAt = now;
	g_iNextBotLegacyUses++;
	LogMessage("[SV bot] NextBot 路径失败，本次退回 CreateFakeClient 两段式补位（第 %d 次）。", g_iNextBotLegacyUses);
	return true;
}

// 新 bot"传送到队友身边"的下一帧收尾（见 SpawnSurvivorBotNextBot 的说明）
void QueueSurvivorBotPlacement(int bot)
{
	if (!IsValidClient(bot)) return;
	RequestFrame(Frame_PlaceNewSurvivorBot, GetClientUserId(bot));
}

public void Frame_PlaceNewSurvivorBot(any userid)
{
	int bot = GetClientOfUserId(userid);
	if (!bot || !IsValidClient(bot) || !IsFakeClient(bot)) return;
	if (GetClientTeam(bot) != TEAM_SURVIVOR) return;
	// 这一帧里已经被真人接管/托管，就别再动这具身体
	if (GetIdlePlayer(bot) > 0) return;
	// 创建流程收尾时可能还没实体化/没血，补一次复活
	if (!IsPlayerAlive(bot) && g_hSDK_RoundRespawn != null) SDKCall(g_hSDK_RoundRespawn, bot);
	if (!IsPlayerAlive(bot))
	{
		// 造出来就是个不会活的空位：收回，别让它占着生还者名额
		LogError("[SV bot] 新建 bot userid=%d 实体化失败（始终不是存活状态），已收回", userid);
		KickClient(bot, "Survivor bot never became alive");
		return;
	}
	// 到这里 bot 已经完整 spawn，可以判模型了：不可用（未 precache / 角色 ID 非法）就收回，
	// 不能留一具裸模身体霸占生还者名额（旧路径同样是校验失败即踢）。
	if (!PrepareSurvivorModel(bot))
	{
		KickClient(bot, "Unusable survivor model");
		return;
	}
	TeleportToSurvivor(bot);
}

// ------------------------------------------------------------------------
// 降级路径：原来的 CreateFakeClient 两段式（造假客户端 → 踢掉 → 引擎补一个真 bot）
//   只有 gamedata/签名/SDKCall 失效时才会走到这里；修好 gamedata 之前靠它保底。
// ------------------------------------------------------------------------
bool SpawnSurvivorBotLegacy(const char[] botName, bool manual)
{
	bool fakeclientKicked = false;
	int fakeclient = CreateFakeClient(botName);

	// if entity is valid
	if (fakeclient != 0)
	{
		// move into survivor team
		ChangeClientTeam(fakeclient, TEAM_SURVIVOR);

		// check if entity classname is survivorbot
		if (DispatchKeyValue(fakeclient, "classname", "survivorbot") == true)
		{
			// spawn the client
			if (DispatchSpawn(fakeclient) == true && PrepareSurvivorModel(fakeclient))
			{
				if (manual)
				{
					if (!IsPlayerAlive(fakeclient)) Respawn(fakeclient);
					TeleportToSurvivor(fakeclient);
				}
				// kick the fake client to make the bot take over
				CreateTimer(DELAY_KICK_FAKECLIENT, Timer_KickFakeBot, GetClientUserId(fakeclient), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
				fakeclientKicked = true;
			}
		}
		// if something went wrong, kick the created FakeClient
		if (fakeclientKicked == false) KickClient(fakeclient, "Kicking FakeClient");
	}
	return fakeclientKicked;
}

// ------------------------------------------------------------------------
// If lobby full, unreserve it. Autojoin survivors if coop & spectator
// ------------------------------------------------------------------------
public void OnClientPostAdminCheck(int client)
{
	/* 兜底：任何"造 bot 客户端"的动作（本插件主路径的 SDKCall NextBotCreatePlayerBot、
	   本插件降级分支和 scripting/playermanagement.sp::FixBotCount 的 CreateFakeClient）
	   都会让引擎同步回调到这里。若这次回调发生在 OnPluginStart 的 ConVar 创建链里
	   （Initialize12v12Capacity 赋值 -> survivor_limit 变更钩子 -> 别的插件造 bot），
	   本插件靠后的 ConVar 可能还没创建、句柄为 0，读 .BoolValue/.IntValue 会抛
	   "Invalid convar handle 0 (error 4)"。这里直接返回即可：
	   bot 是 FakeClient，下面本来也不该走真人入队逻辑。 */
	if (KillRes == null || AutoJoin == null) return;

	// 特感辅助面板：本回合已自动显示过时，中途进服的非生还者补一次自动开启
	// （放在所有 return 之前，别被下面的入队流程提前返回掉）
	SiHud_OnClientReady(client);

	// If lobby is full, KillRes is true and l4dt is present, unreserve lobby
	if(KillRes.BoolValue && IsServerLobbyFull() && l4dt())
	{
		L4D_LobbyUnreserve();
	}
	
	if (IsFakeClient(client)) return;
	ResumeBotPopulation();

	// 2.5.20：命中"禁止自动入队"名单的账号（暖服客户端等）不参与任何自动入队。
	// 注意 ResumeBotPopulation() 必须放在前面：这个账号在场同样应该取消"空服清 bot"计时。
	RefreshNoJoinFlag(client);
	if (IsNoJoinClient(client))
	{
		NewConnection[client] = false;
		return;
	}
	
	char auth[MAX_AUTHID_LENGTH];
	int returningPlayer;
	if (!GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth)))
	{
		// Without a stable identity, preserve an existing team rather than risk
		// treating a returning map connection as a new player.
		NewConnection[client] = false;
		return;
	}
	if (TransitionPlayers.GetValue(auth, returningPlayer))
	{
		TransitionPlayers.Remove(auth);
		NewConnection[client] = false;
	}
	if (!NewConnection[client]) return;
	// Initial engine autoassignment can already put a new player on infected.
	// It is not a manual choice and must still pass the human-count balancer.
	if (AutoJoin.IntValue > 0 && AutoJoin.IntValue < 3 && GetBotOfIdle(client) == 0)
		QueueJoin(client, AutoJoin.IntValue == 1 ? 4 : 0, true, 1.0);
	else NewConnection[client] = false;
}

// ------------------------------------------------------------------------
// If connect as spectator, either auto-join survivor or show team menu
// ------------------------------------------------------------------------
public Action Timer_AutoJoinTeam(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client <= 0 || JoinTimer[client] != timer) return Plugin_Stop;
	JoinTimer[client] = null;
	if (!JoinPending[client] || IsFakeClient(client)) return Plugin_Stop;

	// 2.5.20：命中禁止自动入队名单 —— 无论请求从哪条路径进来，立刻收手，不再每秒重试
	if (IsNoJoinClient(client))
	{
		NewConnection[client] = false;
		CancelJoin(client);
		return Plugin_Stop;
	}

	if (!IsClientInGame(client))
	{
		if (++JoinAttempts[client] < 120)
			JoinTimer[client] = CreateTimer(1.0, Timer_AutoJoinTeam, userid, TIMER_FLAG_NO_MAPCHANGE);
		else
		{
			NewConnection[client] = false;
			CancelJoin(client);
		}
		return Plugin_Stop;
	}
	if (JoinAutomatic[client] && (!NewConnection[client]
		|| (JoinTarget[client] == 0 && GetBotOfIdle(client) > 0)
		|| AutoJoin.IntValue == 0 || AutoJoin.IntValue == 3))
	{
		NewConnection[client] = false;
		CancelJoin(client);
		return Plugin_Stop;
	}

	/* 队伍修正插件正在锁队还原换图队伍时，jointeam 会被它整段拦截，此刻既不能判失败、
	   也不能消耗 JoinAttempts 的次数（否则锁队久一点就会提前放弃并刷"没有位置"）。
	   这里单独计时等待，锁队一结束就立刻继续走原来的 SelectBalancedTeam -> TryJoinTeam。 */
	if (TeamChangesLocked())
	{
		if (++LockWaitSeconds[client] < LOCK_WAIT_MAX_SECONDS)
		{
			JoinTimer[client] = CreateTimer(1.0, Timer_AutoJoinTeam, userid, TIMER_FLAG_NO_MAPCHANGE);
			return Plugin_Stop;
		}
		// 等满上限（异常情况）才放弃，避免永久占着一个 pending 请求
		NewConnection[client] = false;
		CancelJoin(client);
		return Plugin_Stop;
	}
	LockWaitSeconds[client] = 0;

	JoinAttempts[client]++;
	JoinResult result = Join_Wait;
	if (RoundStarted)
	{
		{
			if (JoinAutomatic[client] && JoinTarget[client] == 0 && !TeamChangesLocked())
			{
				// Decide once for this request; a delayed bot takeover must not make
				// the same player oscillate between teams on successive retries.
				int team = SelectBalancedTeam(client);
				if (team > 0) JoinTarget[client] = team;
				else
				{
					// An engine/third-party initial assignment must not create a
					// thirteenth human seat after both configured teams are full.
					if (GetClientTeam(client) > TEAM_SPECTATOR) TryJoinTeam(client, TEAM_SPECTATOR, false, true);
					result = Join_Failed;
				}
			}
			if (result != Join_Failed) result = TryJoinTeam(client, JoinTarget[client], false);

			/* 自动入队兜底：选中的那一队刚好塞不进去（最常见的是生还者席位被"已死亡但还躺着"
			   的人占着），就改试另一队的空位，别把新玩家晾在旁观里。 */
			if (JoinAutomatic[client] && result == Join_Failed)
			{
				int other = (JoinTarget[client] == TEAM_SURVIVOR) ? TEAM_INFECTED : TEAM_SURVIVOR;
				bool bOtherOpen = false;

				if (other == TEAM_INFECTED)
					bOtherOpen = InfectedAllowed && GetTeamPlayers(TEAM_INFECTED, false) < InfectedLimit.IntValue;
				else
					bOtherOpen = GetTeamPlayers(TEAM_SURVIVOR, false) < SurvivorLimit.IntValue
						&& (!HasDeadSurvivorSeat() || HasTakeoverSurvivorBot());

				if (bOtherOpen)
				{
					JoinTarget[client] = other;
					result = TryJoinTeam(client, other, false);
				}
			}
		}
	}
	// 脱困：没排进去时不能把人留在"生还者队 + 已死亡"的槽位上，否则客户端会一直
	// 显示原生"点击加入游戏"的闲置提示却点不动，玩家就卡死在这个界面。
	bool rescued = (result != Join_Success) && RescueStuckDeadSurvivor(client);

	if (result == Join_Wait && JoinAttempts[client] < 120)
		JoinTimer[client] = CreateTimer(1.0, Timer_AutoJoinTeam, userid, TIMER_FLAG_NO_MAPCHANGE);
	else
	{
		if (JoinAutomatic[client]) NewConnection[client] = false;
		// 脱困时已经给过"已退回旁观"的提示，不再重复刷一条同样的消息
		if (result != Join_Success && !rescued)
			ExplainJoinFailure(client);
		CancelJoin(client);
	}
	return Plugin_Stop;
}

/* ------------------------------------------------------------------------
* 生还者队里是否有"已死亡但仍占着名额"的成员（真人 / AI Bot / 挂机托管身体统一计入）。
* 有人躺着时，那几个席位要等下一回合复活，此刻把活人加进来就是超额，
* 所以生还者侧不算"有可用的活人位置"。
* 注意与 HasSurvivorDied(client) 区分：那个是"这名玩家本局死过"。
* ---------------------------------------------------------------------- */
/**
 * 生还者队里是否存在"可接管"的 Bot。
 * 接管是换掉一具已有身体（Bot 本来就占着 survivor_limit 里的一个名额），
 * 不会新增名额、也不会超额 —— 所以哪怕有人阵亡躺着，只要有 Bot 可接管就能进。
 */
bool HasTakeoverSurvivorBot()
{
	return FindJoinSurvivorBot(true) > 0;
}

bool HasDeadSurvivorSeat()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && GetClientTeam(i) == TEAM_SURVIVOR && !IsPlayerAlive(i))
			return true;
	}
	return false;
}

/* ------------------------------------------------------------------------
* 脱困处理：新玩家进服时引擎会先按默认把他放进生还者队；如果生还者队只剩死亡身体
* 占位，SafeTakeOverSurvivor 拿不到活 Bot、SpawnSurvivorBot 也因名额被占满
* 而失败，玩家就一直停在"生还者队 + 已死亡"的槽位反复 Join_Wait。
* 此时客户端会显示原生的"点击加入游戏"闲置提示，而对抗没有可用闲置键 → 点了没反应、
* 卡死在那个界面。这里把他退回旁观并清掉残留的跟随观察态，让他能重新 !join / 按 M。
*
* 只处理"本次进服还没安置好"的新连接（NewConnection），
* 本局正常阵亡、正在等救援/复活的生还者不受影响。
* ---------------------------------------------------------------------- */
bool RescueStuckDeadSurvivor(int client)
{
	if (!IsValidClient(client) || IsFakeClient(client) || !IsClientInGame(client)) return false;
	if (!NewConnection[client]) return false;
	if (GetClientTeam(client) != TEAM_SURVIVOR || IsPlayerAlive(client)) return false;
	// 托管着自己 Bot 的玩家是正常的"死亡等复活"状态，不算卡住
	if (GetBotOfIdle(client) > 0) return false;

	ChangeClientTeam(client, TEAM_SPECTATOR);
	if (!IsClientInGame(client) || GetClientTeam(client) != TEAM_SPECTATOR) return false;

	// 伪闲置时代会在玩家身上留下 m_iObserverMode = 5（跟随观察），
	// 那正是"点击加入游戏没反应"的元凶；只在残留时清回 0，不动正常旁观模式。
	if (GetEntProp(client, Prop_Send, "m_iObserverMode") == 5)
		SetEntProp(client, Prop_Send, "m_iObserverMode", 0);

	PrintToChat(client, "\x03[SV] \x01当前没有可加入的位置，已退回旁观，可输入 !jg 重试。");
	return true;
}

int SelectBalancedTeam(int client)
{
	int survivors = GetTeamPlayers(TEAM_SURVIVOR, false);
	int infected = GetTeamPlayers(TEAM_INFECTED, false);
	// Compare everyone already admitted, excluding this new connection's default
	// engine seat. GetTeamPlayers(false) excludes AI but includes idle humans.
	int current = GetClientTeam(client);
	if (current == TEAM_SURVIVOR) survivors--;
	else if (current == TEAM_INFECTED) infected--;

	/* 生还者侧"可用"要同时满足：真人位置没满、且队里没有死亡生还者占着名额。
	   有人躺着时只能去特感；两边都不可用就返回 0，让调用方保持旁观并提示。 */
	bool survivorOpen = survivors < SurvivorLimit.IntValue
		&& (!HasDeadSurvivorSeat() || HasTakeoverSurvivorBot());
	bool infectedOpen = InfectedAllowed && infected < InfectedLimit.IntValue;

	if (!survivorOpen && !infectedOpen) return 0;
	if (!survivorOpen) return TEAM_INFECTED;
	if (!infectedOpen) return TEAM_SURVIVOR;
	if (survivors < infected) return TEAM_SURVIVOR;
	if (infected < survivors) return TEAM_INFECTED;
	return GetRandomInt(TEAM_SURVIVOR, TEAM_INFECTED);
}

/* 自动/手动入队失败时说清原因（玩家反馈"进不去却不知道为什么"）。
   口径与 TryJoinTeam 的判定完全一致：生还者侧可补位 = 真人名额没满 且 没有死亡占位；
   特感侧可补位 = 允许特感 且 真人名额没满。 */
void ExplainJoinFailure(int client)
{
	int survivors = GetTeamPlayers(TEAM_SURVIVOR, false);
	int infected  = GetTeamPlayers(TEAM_INFECTED, false);

	bool bDeadSeat     = HasDeadSurvivorSeat();
	bool bSurvivorFull = survivors >= SurvivorLimit.IntValue;
	bool bInfectedFull = !InfectedAllowed || infected >= InfectedLimit.IntValue;
	bool bDiedThisRound = HasSurvivorDied(client);

	char sReason[192];

	if (bSurvivorFull && bDeadSeat)
		Format(sReason, sizeof(sReason), "生还者真人位已满(%d/%d)，而且还有阵亡玩家的席位要等下一回合复活", survivors, SurvivorLimit.IntValue);
	else if (bSurvivorFull)
		Format(sReason, sizeof(sReason), "生还者真人位已满(%d/%d)", survivors, SurvivorLimit.IntValue);
	else if (bDeadSeat)
		Format(sReason, sizeof(sReason), "生还者席位被阵亡玩家占着（要等下一回合复活才能补位）");
	else if (bDiedThisRound)
		Format(sReason, sizeof(sReason), "你本回合已经阵亡，要等救援/复活或下一回合");
	else
		Format(sReason, sizeof(sReason), "生还者暂时没有可接管的位置");

	if (bInfectedFull)
		PrintToChat(client, "\x03[SV] \x01暂时无法加入：%s；特感位也满了(%d/%d)。等有人退出或下一回合再输入 !jg。",
			sReason, infected, InfectedLimit.IntValue);
	else
		PrintToChat(client, "\x03[SV] \x01本次没能加入：%s。特感还有位置，输入 !jg 会自动进特感。", sReason);
}

void CancelJoin(int client)
{
	delete JoinTimer[client];
	JoinPending[client] = false;
	JoinAutomatic[client] = false;
	JoinAttempts[client] = 0;
	LockWaitSeconds[client] = 0;
}

void QueueJoin(int client, int team, bool automatic, float delay)
{
	// 2.5.20：禁止自动入队名单内的账号，本插件不主动把它塞进队伍（也不会产生每秒重试）
	if (IsNoJoinClient(client))
	{
		CancelJoin(client);
		return;
	}

	CancelJoin(client);
	JoinPending[client] = true;
	JoinAutomatic[client] = automatic;
	JoinTarget[client] = team;
	JoinTimer[client] = CreateTimer(delay, Timer_AutoJoinTeam, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

// *********************************************************************************
// BOT REPLACED PLAYER
// *********************************************************************************

// ------------------------------------------------------------------------
// Bot took over a player: only schedule the "no longer needed bot" cleanup.
// 旧的伪闲置修复链与 AFK 事件监测已整块移除：
// 那套 L4D_SetHumanSpec + m_iObserverMode=5 的写法是给战役模式修引擎 idle bug 的，
// 在对抗里会把玩家置成跟随观察态，玩家只看到原生的"点击加入游戏"闲置提示，
// 而对抗没有可用的闲置键 → 点了没反应、卡死。闲置交给专门的闲置插件处理。
// ------------------------------------------------------------------------
public Action Event_BotReplacedPlayer(Event event, const char[] name, bool dontBroadcast)
{
	// Event is triggered when a bot takes over a player
	int bot		= GetClientOfUserId(event.GetInt("bot"));

	if (!IsValidClient(bot)) return Plugin_Continue;
	if (GetClientTeam(bot) == TEAM_SURVIVOR) CreateTimer(DELAY_KICK_NONEEDBOT, Timer_KickNoNeededBot, GetClientUserId(bot), TIMER_FLAG_NO_MAPCHANGE);

	return Plugin_Continue;
}

// ------------------------------------------------------------------------
// When player dies, forces takeover of the bot
// ------------------------------------------------------------------------
public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	// Event is triggered when a player dies
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!IsValidClient(client)) return Plugin_Continue;
	int owner;
	if (GetClientTeam(client) == TEAM_SURVIVOR)
		owner = IsFakeClient(client) ? GetIdlePlayer(client) : client;
	TakeOver(client);
	// A takeover can emit spawn events. Record the death after that operation.
	if (owner > 0) SetSurvivorDeath(owner, true);
	return Plugin_Continue;
}

void TakeOver(int bot)
{
	if (IsValidClient(bot) && IsFakeClient(bot) && GetClientTeam(bot) == TEAM_SURVIVOR)
	{
		int idleplayer = GetIdlePlayer(bot);
		if (idleplayer > 0) SafeTakeOverSurvivor(idleplayer, bot);
	}
}




// *********************************************************************************
// COMMANDS FOR JOINING TEAMS
// *********************************************************************************

// ------------------------------------------------------------------------
// Join survivor or infected
// ------------------------------------------------------------------------
public Action Join_Game(int client, int args)
{
	return RequestJoin(client, 0);
}

public Action Join_Spectator(int client, int args)
{
	return RequestJoin(client, TEAM_SPECTATOR);
}

public Action Join_Survivor(int client, int args)
{
	return RequestJoin(client, TEAM_SURVIVOR);
}

public Action Join_Infected(int client, int args)
{
	return RequestJoin(client, TEAM_INFECTED);
}

public Action Cmd_JoinTeam(int client, const char[] command, int argc)
{
	if (!IsValidClient(client) || IsFakeClient(client) || argc < 1 || !Management.BoolValue)
		return Plugin_Continue;
	char choice[32];
	GetCmdArg(1, choice, sizeof(choice));
	int team = ParseJoinTeam(choice);
	if (team < 0) return Plugin_Continue;
	return RequestJoin(client, team);
}

public Action Cmd_StaySpectator(int client, const char[] command, int argc)
{
	if (client > 0 && client <= MaxClients)
	{
		NewConnection[client] = false;
		CancelJoin(client);
	}
	return Plugin_Continue;
}

int ParseJoinTeam(const char[] choice)
{
	if (StrEqual(choice, "0") || StrEqual(choice, "auto", false) || StrEqual(choice, "autoassign", false)) return 0;
	if (StrEqual(choice, "1") || StrEqual(choice, "spectator", false) || StrEqual(choice, "spectators", false) || StrEqual(choice, "spectate", false)) return TEAM_SPECTATOR;
	if (StrEqual(choice, "2") || StrEqual(choice, "survivor", false) || StrEqual(choice, "survivors", false)) return TEAM_SURVIVOR;
	if (StrEqual(choice, "3") || StrEqual(choice, "infected", false)) return TEAM_INFECTED;
	return -1;
}

bool TeamChangesLocked()
{
	return GetFeatureStatus(FeatureType_Native, "L4D2_FixTeamShuffle_IsFixComplete") == FeatureStatus_Available
		&& !L4D2_FixTeamShuffle_IsFixComplete();
}

Action RequestJoin(int client, int team)
{
	if (!IsValidClient(client) || IsFakeClient(client)) return Plugin_Handled;
	// Explicit choices cancel an outstanding automatic join, including choosing spectator.
	NewConnection[client] = false;
	CancelJoin(client);
	if (!Management.BoolValue) return Plugin_Continue;
	JoinResult result = TryJoinTeam(client, team, true);
	if (result == Join_Wait && team != TEAM_SPECTATOR)
		QueueJoin(client, team, false, 0.3);
	return Plugin_Handled;
}

JoinResult TryJoinTeam(int client, int team, bool announce, bool adminTransfer = false)
{
	if (!IsValidClient(client) || IsFakeClient(client) || !Management.BoolValue) return Join_Failed;
	if (!IsClientAuthorized(client) || IsClientInKickQueue(client)) return Join_Failed;
	if (!SurvivorMapReady) return Join_Wait;
	if (TeamChangesLocked())
	{
		if (announce) PrintToChat(client, "\x03[SV] \x01正在还原换图队伍，完成后将处理你的入队请求。");
		return Join_Wait;
	}
	int current = GetClientTeam(client);
	if (current == TEAM_SURVIVOR)
		SetSurvivorDeath(client, !IsPlayerAlive(client));
	if (current == TEAM_INFECTED && GetClientZC(client) == ZC_JOCKEY
		&& GetEntProp(client, Prop_Send, "m_jockeyVictim") > 0)
		return Join_Failed;
	if (team == 0)
	{
		// 本回合已阵亡（身体还在生还者队里躺着/或已在旁观）、身上也没有托管身体，
		// 且特感还有真人空位时：!join 直接进特感。
		// 以前这种情况会被下面的"本回合已阵亡"挡住，只能靠 !inf 才能进游戏。
		bool bDeadNoBody = HasSurvivorDied(client) && !IsPlayerAlive(client) && GetBotOfIdle(client) <= 0;
		int iInfectedHumans = GetTeamPlayers(TEAM_INFECTED, false);

		if (bDeadNoBody && InfectedAllowed && iInfectedHumans < InfectedLimit.IntValue)
		{
			team = TEAM_INFECTED;
		}
		// 托管着自己的身体：回生还者队接管自己的 Bot，不占新名额
		else if (GetBotOfIdle(client)) team = TEAM_SURVIVOR;
		// 活着且在生还者队：!jg 不换队
		else if (current == TEAM_SURVIVOR && IsPlayerAlive(client)) team = TEAM_SURVIVOR;
		else if (!InfectedAllowed) team = TEAM_SURVIVOR;
		else if (current == TEAM_INFECTED) team = TEAM_INFECTED;
		else
		{
			int survivors = GetTeamPlayers(TEAM_SURVIVOR, false);
			int infected = GetTeamPlayers(TEAM_INFECTED, false);

			/* 生还者侧"可补位"要同时满足：真人名额没满 + 队里没有"已死亡但还躺着"的人占位。
			   有人躺着时那几个席位要等下一回合复活，此刻把人塞进去就是超额，而且会变成一具
			   死亡身体卡在"点击加入游戏"界面。这种局面下 !jg 应该直接去特感。 */
			bool bSurvivorOpen = survivors < SurvivorLimit.IntValue
				&& (!HasDeadSurvivorSeat() || HasTakeoverSurvivorBot());
			bool bInfectedOpen = infected < InfectedLimit.IntValue;

			if (!bSurvivorOpen && !bInfectedOpen)
			{
				if (announce) ExplainJoinFailure(client);
				return Join_Failed;
			}

			if (!bSurvivorOpen) team = TEAM_INFECTED;
			else if (!bInfectedOpen) team = TEAM_SURVIVOR;
			else team = (infected < survivors) ? TEAM_INFECTED : TEAM_SURVIVOR;
		}
	}
	if (current == team && (team != TEAM_SURVIVOR || IsPlayerAlive(client))
		&& (team != TEAM_SPECTATOR || GetBotOfIdle(client) == 0))
	{
		// 这条捷径不经过 SafeTakeOverSurvivor（引擎已把人放进生还者队且存活），
		// 所以要在这里也排一次补枪检查。
		if (team == TEAM_SURVIVOR) ScheduleLoadoutCheck(client);
		return Join_Success;
	}
	if (team == TEAM_SPECTATOR)
	{
		if (!adminTransfer && !CanVoluntarilySpectate(client, announce)) return Join_Failed;
		int ownedBot = GetBotOfIdle(client);
		if (ownedBot > 0 && !SafeTakeOverSurvivor(client, ownedBot)) return Join_Wait;
		ChangeClientTeam(client, TEAM_SPECTATOR);
		if (!adminTransfer && announce && !SuppressSpectate.BoolValue
			&& GetGameTime() >= NextSpectateNotice[client])
		{
			// 按需求：这条提示不再全体广播，只发给已经处于旁观状态的玩家（刚转去旁观的人自己也包含在内）
			for (int i = 1; i <= MaxClients; i++)
			{
				if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == TEAM_SPECTATOR)
				{
					PrintToChat(i, "\x03[队伍] \x01%N 已加入旁观。输入 !jg 返回游戏（不要按 M，按 M 容易卡住）。", client);
				}
			}
			NextSpectateNotice[client] = GetGameTime() + 7.0;
		}
		return Join_Success;
	}
	if (team == TEAM_INFECTED)
	{
		if (!InfectedAllowed || GetTeamPlayers(TEAM_INFECTED, false) >= InfectedLimit.IntValue)
		{
			if (announce) PrintToChat(client, "\x03[SV] \x01特感队伍的真人位置已满或本模式不允许加入。");
			return Join_Failed;
		}
		if (!MakeInfectedRoom()) return Join_Wait;
		int ownedBot = GetBotOfIdle(client);
		if (ownedBot > 0 && !SafeTakeOverSurvivor(client, ownedBot)) return Join_Wait;
		ChangeClientTeam(client, TEAM_INFECTED);
		// 2.5.17：换到特感后立刻清一次武器（"引擎先给生还者席位拿了枪 → 再换到特感"的竞态）
		// 同时也覆盖 player_team 事件还没来得及触发的情况
		StripSurvivorWeapons(client);
		return GetClientTeam(client) == TEAM_INFECTED ? Join_Success : Join_Wait;
	}
	if (team != TEAM_SURVIVOR) return Join_Failed;
	if (!EnsureSurvivorModels()) return Join_Wait;
	bool died = HasSurvivorDied(client);
	if (died && current == TEAM_SURVIVOR)
	{
		if (announce) PrintToChat(client, "\x03[SV] \x01本回合已阵亡，请等待救援、复活或下一回合。");
		return Join_Failed;
	}
	int bot = GetBotOfIdle(client);
	if (bot <= 0 && current != TEAM_SURVIVOR && GetTeamPlayers(TEAM_SURVIVOR, false) >= SurvivorLimit.IntValue)
	{
		if (announce) PrintToChat(client, "\x03[SV] \x01生还者队伍的真人位置已满。");
		return Join_Failed;
	}
	/* 先找可接管的 Bot：接管是换一具已有身体，不新增名额，所以即使有人阵亡躺着也不算超额。 */
	if (bot <= 0) bot = FindJoinSurvivorBot(!died);

	if (died && bot > 0 && IsPlayerAlive(bot))
	{
		if (announce) PrintToChat(client, "\x03[SV] \x01本回合已阵亡，不能接管存活的 AI。");
		return Join_Failed;
	}

	/* 生还者位置被死亡生还者占着、且**场上没有可接管的 Bot**时，才真的不能塞人进生还者队
	   （否则他会变成一具死亡身体，客户端一直显示原生"点击加入游戏"却点不动）。
	   有 Bot 可接管时走下面的 SafeTakeOverSurvivor，安全。 */
	if (bot <= 0 && HasDeadSurvivorSeat())
	{
		if (announce) PrintToChat(client, "\x03[SV] \x01本回合生还者已无可用位置（有阵亡玩家占位且没有可接管的 Bot），请等待下一回合或加入特感。");
		return Join_Failed;
	}
	if (bot <= 0)
	{
		if (died)
		{
			if (announce) PrintToChat(client, "\x03[SV] \x01本回合已阵亡，不能接管存活的 AI。请等待救援、复活或下一回合。");
			return Join_Failed;
		}
		if (GetSurvivorTeam() < SurvivorLimit.IntValue) SpawnSurvivorBot();
		return Join_Wait;
	}
	// The original jointeam command has its own four-player checks. Bypass only that
	// route after checking our human limit, and reserve exactly this available bot.
	bool canRespawn = !died && !InfectedAllowed && RespawnJoin.BoolValue && IsFirstTime(client);
	int requestUserid = GetClientUserId(client);
	bool taken = SafeTakeOverSurvivor(client, bot);
	if (!IsValidClient(client) || GetClientUserId(client) != requestUserid) return Join_Failed;
	if (!taken || GetClientTeam(client) != TEAM_SURVIVOR)
	{
		ChangeClientTeam(client, TEAM_SPECTATOR);
		return Join_Wait;
	}
	if (!IsPlayerAlive(client) && canRespawn)
	{
		Respawn(client);
		TeleportToSurvivor(client);
		SetGodMode(client, 1.0);
	}
	return Join_Success;
}

bool CanVoluntarilySpectate(int client, bool announce)
{
	if (!AllowSpectate.BoolValue) return false;
	int team = GetClientTeam(client);
	if (team == TEAM_INFECTED && GetClientZC(client) == ZC_TANK)
	{
		if (announce) PrintToChat(client, "\x03[队伍] \x01控制坦克时不能主动转入旁观。");
		return false;
	}
	int survivor = team == TEAM_SURVIVOR ? client : GetBotOfIdle(client);
	if (survivor > 0)
	{
		if (BlockSpecInTank.BoolValue && L4D2_IsTankInPlay()) return false;
		if ((L4D2_GetInfectedAttacker(survivor) != -1 && !L4D_IsPlayerIncapacitated(survivor))
			|| GetEntDataEnt2(survivor, QueuedPummelOffset) != -1)
		{
			if (announce) PrintToChat(client, "\x03[队伍] \x01被特感控制时暂时不能转入旁观。");
			return false;
		}
	}
	return true;
}

int FindJoinSurvivorBot(bool allowAlive = true)
{
	int deadBot = -1;
	for (int bot = 1; bot <= MaxClients; bot++)
	{
		if (!IsBotValid(bot) || GetClientTeam(bot) != TEAM_SURVIVOR) continue;
		if (!PrepareSurvivorModel(bot)) continue;
		if (IsPlayerAlive(bot))
		{
			if (allowAlive) return bot;
		}
		else deadBot = bot;
	}
	return deadBot;
}

bool MakeInfectedRoom()
{
	while (GetTeamPlayers(TEAM_INFECTED, true) >= InfectedLimit.IntValue)
	{
		int candidate = -1;
		for (int bot = MaxClients; bot >= 1; bot--)
		{
			if (IsClientInGame(bot) && IsFakeClient(bot) && !IsClientInKickQueue(bot)
				&& GetClientTeam(bot) == TEAM_INFECTED && GetClientZC(bot) >= ZC_SMOKER
				&& GetClientZC(bot) <= ZC_CHARGER)
			{
				candidate = bot;
				break;
			}
		}
		if (candidate < 1) return false;
		ChangeClientTeam(candidate, TEAM_SPECTATOR);
		KickClient(candidate, "Making room for a human infected player");
	}
	return true;
}

public Action MultiStatus(int client, int args)
{
	char filename[PLATFORM_MAX_PATH];
	GetPluginFilename(null, filename, sizeof(filename));
	ConVar maxPlayers = FindConVar("sv_maxplayers");
	ConVar multiPlayers = FindConVar("mv_maxplayers");
	int waiting, automatic;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (JoinPending[i]) waiting++;
		if (JoinPending[i] && JoinAutomatic[i]) automatic++;
	}
	ReplyToCommand(client, "[Multi] v%s | file=%s | engine=%d/%d | plugin=%d/%d | minsurvivor=%d",
		PLUGIN_VERSION, filename, L4DSurvivorLimit.IntValue, L4DInfectedLimit.IntValue,
		SurvivorLimit.IntValue, InfectedLimit.IntValue, cvar_minsurvivor.IntValue);
	ReplyToCommand(client, "[Multi] MaxClients=%d | sv_maxplayers=%d | mv_maxplayers=%d | mode=%s",
		MaxClients, maxPlayers == null ? -1 : maxPlayers.IntValue, multiPlayers == null ? -1 : multiPlayers.IntValue, gameMode);
	ReplyToCommand(client, "[Multi] survivor humans=%d AI=%d | infected humans=%d AI=%d | auto=%d management=%d | round=%d restorelock=%d | waiting=%d auto_waiting=%d",
		GetTeamPlayers(TEAM_SURVIVOR, false), CountBots(TEAM_SURVIVOR), GetTeamPlayers(TEAM_INFECTED, false),
		CountBots(TEAM_INFECTED), AutoJoin.IntValue, Management.IntValue, RoundStarted, TeamChangesLocked(), waiting, automatic);
	ReplyToCommand(client, "[Multi] ready_humans=%d | bots_allowed=%d | empty_cleanup=%d | bot_create=%s",
		GetReadyHumanCount(), SvBotsAllowed(), EmptyServerTimer != null,
		g_bNextBotReady ? "nextbot" : "fakeclient(fallback)");
	ReplyToCommand(client, "[Multi] survivor_models=%d/%d | map_ready=%d | takeover_blocked=%d | character_repairs=%d",
		SurvivorModelsReady, L4D1 ? 4 : 8, SurvivorMapReady, TakeoverBlocked, SurvivorCharacterRepairs);
	return Plugin_Handled;
}

// ------------------------------------------------------------------------
// Create a bot. Useful if less bots than SurvivorLimit because the later got increased
// ------------------------------------------------------------------------
public Action Create_Player(int client, int args)
{
	if (Management.IntValue < 2) return Plugin_Continue;
	char name[MAX_NAME_LENGTH] = "SurvivorBot";
	if (args > 0) GetCmdArg(1, name, sizeof(name));
	// Named and unnamed requests share the same limit and cleanup. Previously
	// named bots never joined a team, and failed/double dispatches leaked slots.
	if (!SpawnSurvivorBot(name, true))
		ReplyToCommand(client, "[SV] Could not create survivor: no ready human, team full or bot creation failed.");
	return Plugin_Handled;
}

// 只服务降级路径（CreateFakeClient 两段式）：把刚建的假客户端在 DELAY_KICK_FAKECLIENT
// 之后踢掉，让引擎补上一个真正的 SurvivorBot 接管这个位置。主路径不会走到这里。
public Action Timer_KickFakeBot(Handle timer, any userid)
{
	int Bot = GetClientOfUserId(userid);
	if (!Bot || !IsFakeClient(Bot)) return Plugin_Stop;
	if (IsClientConnected(Bot))
	{
		KickClient(Bot, "Kicking FakeClient");		
		return Plugin_Stop;
	}	
	return Plugin_Continue;
}

// *********************************************************************************
// RETURN PROPERTIES OF INFECTED/SURVIVOR TEAMS, BOTS, & PLAYERS
// *********************************************************************************

char survivor_only_modes[23][] =
{
	"coop", "realism", "survival",
	"m60s", "hardcore", "l4d1coop",
	"mutation1",	"mutation2",	"mutation3",	"mutation4",
	"mutation5",	"mutation6",	"mutation7",	"mutation8",
	"mutation9",	"mutation10",	"mutation16",	"mutation17", "mutation20",
	"community1",	"community2",	"community4",	"community5"
};

// ------------------------------------------------------------------------
// Returns true if players in team infected are allowed
// ------------------------------------------------------------------------
bool AreInfectedAllowed()
{
	for (int i = 0; i < sizeof(survivor_only_modes); i++)
	{
		if (StrEqual(gameMode, survivor_only_modes[i], false))
		{
			return false;
		}
	}
	return true;   // includes versus, realism versus, scavenge, & some mutations
}

// ------------------------------------------------------------------------
// Returns true if lobby full. Used to unreserve the lobby
// ------------------------------------------------------------------------
bool IsServerLobbyFull()
{
	int humans = GetHumanCount();

	if (humans >= 8) return true;
	if( !InfectedAllowed && humans >= 4) return true;
	return false;
}

// ------------------------------------------------------------------------
// Returns true if client never spawned as survivor this game. Used to allow 1 free spawn
// ------------------------------------------------------------------------
bool IsFirstTime(int client)
{
	if(!IsClientInGame(client) || IsFakeClient(client)) return false;
	
	char SteamID[64];
	bool valid = GetClientAuthId(client, AuthId_Steam2, SteamID, sizeof(SteamID));		
	
	if (valid == false) return false;

	bool Allowed;
	if (!SteamIDs.GetValue(SteamID, Allowed))  // If can't find the entry in map
	{
		SteamIDs.SetValue(SteamID, true, true);
		Allowed = true;
	}
	return Allowed;
}

// Keep deaths by identity for the round so spectator/team changes and reconnects
// cannot turn a dead survivor into a live bot. A real respawn clears the entry.
void SetSurvivorDeath(int client, bool died)
{
	SurvivorDied[client] = died;
	char auth[MAX_AUTHID_LENGTH];
	if (GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth)))
	{
		if (died) DeadSurvivors.SetValue(auth, true);
		else DeadSurvivors.Remove(auth);
	}
}

bool HasSurvivorDied(int client)
{
	if (SurvivorDied[client]) return true;
	char auth[MAX_AUTHID_LENGTH];
	int died;
	return GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth))
		&& DeadSurvivors.GetValue(auth, died) && died != 0;
}

// ------------------------------------------------------------------------
// Stores the Steam ID, so if reconnect we don't allow free respawn
// ------------------------------------------------------------------------
void RecordSteamID(int client)
{
	// Stores the Steam ID, so if reconnect we don't allow free respawn
	char SteamID[64];
	bool valid = GetClientAuthId(client, AuthId_Steam2, SteamID, sizeof(SteamID));
	if (valid) SteamIDs.SetValue(SteamID, false, true);
}

// ------------------------------------------------------------------------
// Returns the idle player of the bot, returns 0 if none
// ------------------------------------------------------------------------
int GetIdlePlayer(int bot)
{
	if (bot > 0 && IsClientInGame(bot) && GetClientTeam(bot) == TEAM_SURVIVOR && IsFakeClient(bot)
		&& HasEntProp(bot, Prop_Send, "m_humanSpectatorUserID"))
	{
		int client = GetClientOfUserId(GetEntProp(bot, Prop_Send, "m_humanSpectatorUserID"));
		if (client > 0 && IsClientInGame(client) && !IsFakeClient(client) && GetClientTeam(client) == TEAM_SPECTATOR)
			return client;
	}
	return 0;
}

// ------------------------------------------------------------------------
// Returns the bot of the idle client, returns 0 if none 
// ------------------------------------------------------------------------
int GetBotOfIdle(int client)
{
	for(int i = 1; i <= MaxClients; i++)
	{
		if (GetIdlePlayer(i) == client) return i;
	}
	return 0;
}

// ------------------------------------------------------------------------
// Get the number of players on the team (includes idles)
// includeBots == true : counts bots
// ------------------------------------------------------------------------
int GetTeamPlayers(int team, bool includeBots)
{
	int players = 0;
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i) && GetClientTeam(i) == team)
		{
			if(IsFakeClient(i) && !includeBots && !GetIdlePlayer(i))
				continue;
			players++;
		}
	}
	return players;
}

// ------------------------------------------------------------------------
// Get the number of survivors on the team, including bots
// ------------------------------------------------------------------------
int GetSurvivorTeam()
{
	return GetTeamPlayers(TEAM_SURVIVOR, true);
}

int GetHumanCount()
{
	int humans = 0;
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i) && !IsFakeClient(i))
			humans++;
	}
	return humans;
}

// ------------------------------------------------------------------------
// 空服不养 bot：真人完成进服、身份验证且未处于踢出队列后才允许补位。
// ------------------------------------------------------------------------
int GetReadyHumanCount()
{
	int humans;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && IsClientAuthorized(i)
			&& !IsClientInKickQueue(i)) humans++;
	}
	return humans;
}

stock bool SvBotsAllowed()
{
	return GetReadyHumanCount() > 0;
}

// ------------------------------------------------------------------------
// 回收空服里多余的生还者 bot（只踢 AI bot；有真人空闲接管中/已在踢队列里的跳过）。
// ------------------------------------------------------------------------
stock void SvRecycleSurvivorBots()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i)) continue;
		if (!IsFakeClient(i)) continue;
		if (GetClientTeam(i) != TEAM_SURVIVOR) continue;
		if (GetIdlePlayer(i)) continue;              // 有真人 AFK 接管了这个 bot，别踢
		if (IsClientInKickQueue(i)) continue;
		KickClient(i, "空服回收 AI bot");
	}
}

// ------------------------------------------------------------------------
// 回收空服里的 AI 特感 bot。
// ------------------------------------------------------------------------
stock void SvRecycleInfectedBots()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i)) continue;
		if (!IsFakeClient(i)) continue;
		if (GetClientTeam(i) != TEAM_INFECTED) continue;
		if (IsClientInKickQueue(i)) continue;
		KickClient(i, "空服回收 AI 特感");
	}
}

// ------------------------------------------------------------------------
// Is the bot valid? (either survivor or infected)
// ------------------------------------------------------------------------
bool IsBotValid(int client)
{
	if(client > 0 && IsClientInGame(client) && IsFakeClient(client) && !GetIdlePlayer(client) && !IsClientInKickQueue(client))
		return true;
	return false;
}


// ------------------------------------------------------------------------
// Check if how many bots are in a team without idle. Can be dead
// ------------------------------------------------------------------------
stock int CountBots(int team)
{
	int num = 0;
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsBotValid(i) && GetClientTeam(i) == team)
					num++;
	}
	return num;
}

bool AnySurvivorLeftSafeArea()
{
	return L4D_HasAnySurvivorLeftSafeArea();
}

// *********************************************************************************
// 特感辅助面板（sm_sihud / 聊天 !sihud）
//
//   实现方式对齐 readyup-applemod 的面板（panel.inc / doorlock.inc）：
//     · SourceMod Panel（不是 Menu）：SetTitle + DrawText 逐行画；
//     · 1 秒重发一次、面板显示时长 3 秒（与 spechud 的 HudDrawTimer 同款做法），
//       所以玩家开着面板时画面是连续的；
//     · 强制显示窗口里改成 0.25 秒重画一次（SIHUD_FORCE_REDRAW），这 2 秒里就算被别的面板
//       顶掉也会在 0.25 秒内顶回来 —— 这是"离开安全区后只闪一下就再也不显示"的修法；
//     · 发送前跳过"客户端正在看别的菜单"的人（GetClientMenu 非 None），
//       绝不抢 readyup / 门锁 / 内置投票 / 其它插件的面板；
//     · 文本总预算 511 字节（Panel.TextRemaining），逐行裁剪且不切坏中文
//       （SiHud_CopyPanelText 按 UTF-8 字符边界走，与 RU_CopyPanelText 同一套算法）。
//   工具函数（SiHud_CopyPanelText / SiHud_GetFixedName / SiHud_DummyHandler）在本文件内
//   各写一份，刻意**不** include readyup 的 inc，避免跨插件耦合。
//
//   显示规则（与需求逐条对应）：
//     B. 只允许非生还者（感染者 / 旁观 / 未分队）打开并显示；生还者输入 !sihud 只提示、不开面板，
//        已开面板的玩家一旦转成生还者也立刻停掉。
//     C. 生还者**每回合首次**离开安全区域时，给所有能看面板的玩家**连续 2 秒**强制显示
//        （SIHUD_FORCE_SECONDS，2 秒里每 0.25 秒重画一次，被别的面板顶掉也会立刻顶回来）。
//        ★2.6.0：2 秒结束后**面板保持开启**（sm_sihud_force_keep=1，默认）——
//        旧版到这里会 SiHud_ClosePanel 把它收掉，玩家看到的就是"离开安全区后闪一下就没了"。
//        只有玩家自己 !sihud 关过（g_bSiHudUserOff）或者转成生还者时才真的收起来。
//        sm_sihud_force_show=0 时这一步跳过。
//        "首次离开"有两条触发：player_left_start_area / player_left_checkpoint 事件，加
//        Timer_SiHudRefresh 里 1 秒一次的兜底轮询（SiHud_PollForceShow）。引擎在换图 / 读图 /
//        出生点重定位时会误发 player_left_start_area（hdf.sp 里也有同样的记录），准备阶段
//        （readyup / 门锁面板在场）又不该抢屏幕 —— 这两种情况**不消耗**本回合唯一那次机会，
//        否则真实离开时就不会再自动显示了。本回合已经强制显示过之后，中途进服的非生还者
//        补一次同样的 2 秒强制显示。
//     C'.2.6.0：玩家**进入感染者队伍**（player_team）或中途进服时已经在非生还者队伍
//        （OnClientPostAdminCheck）→ 自动打开面板（sm_sihud_auto_open=1，默认）。
//        玩家自己 !sihud 关过则本回合不再自动开（换回合/换图/转生还者后复位）。
//     D. 坦克刷出 / 被接管（tank_spawn、以及 1 秒轮询发现"同一只坦克换了控制者"）：
//          ★2.6.2（需求）：**sihud 已经关着的玩家整段跳过** —— 既不关他的 tankhud，也不强开面板、
//            不替他自动打开（判定 = 面板此刻没开，见 SiHud_PanelIsClosed）。
//            以前是无条件关掉所有人的 tankhud 再强开 2 秒面板，会把"本来就把面板关掉的人"
//            每次刷坦克都弹一次、还顺手关掉他的坦克HUD，两条都不符合他的选择。
//          · 关掉**sihud 开着的玩家**的坦克HUD（tankhud 由 spechud_appledmod 画，走 SpecHud_TankHudDisable）；
//          · 除坦克玩家外的其它玩家：同一时刻起连续 2 秒强制显示本面板；
//          · 坦克玩家：sm_sihud_tank_delay=6（2.6.0 默认 = 克面板显示总时间 5 秒 + 1 秒）→
//            先让他看完自己的克面板（坦克面板），6 秒到点再关掉它并把面板交给他（面板里的坦克行
//            已经显示 名称/血量/一控二控，之后就不需要 tankhud 了）；
//            tank_delay=0 → 立刻关 tankhud、立刻把面板交给他；
//            **没有 tankhud（原生不在场/已被关掉）时永远立刻交棒** —— 否则这 N 秒里他既没有
//            tankhud 也没有面板，就是玩家报的"坦克玩家什么 HUD 都看不到"。
//            交接统一走 SiHud_TankHandoverPanel：他原本开着就重画，原本没开就由插件替他打开一次
//            （g_iSiHudTankPanel = AUTO，坦克结束后收回）。
//        二控（换了一名玩家控制）按当前坦克玩家重新计时，并把交接状态复位。
//     E. 面板最下面两行是"坦克 / 女巫"：
//        ★2.6.1 坦克行（按需求重做，格式 `坦克1:4000 (1控/35%)`）：
//          **有坦克活着**时逐只一行 ——
//            · 行首序号：坦克1 / 坦克2 / 坦克3（与行序一致，方便玩家对上号）；
//            · **不显示玩家名称**（2.6.0 的"前两个字符 + *"按需求整段去掉）；
//            · 血量显示**具体血量**，不显示上限（2.6.0 是 `78%`，现在是 `3120`）；
//            · 括号里是「控数/怒气」：控数 = 该玩家本回合第几段完整控制权（1控/2控，AI 坦克写 AI），
//              怒气 = m_frustration 的百分比（与 spechud 的 tankhud `怒气: %d%%` 同一取法，
//              左右 HUD 对得上；AI 坦克与 spechud 一样写"电脑"不报数字）；
//            · 多只坦克同时存活时一只一行，最多 SIHUD_MAX_TANK_LINES 行，多的用一行"还有 N 只"提示；
//          **没有坦克活着**时才回落到旧口径：按 Versus Director 的 boss flow percent 显示
//          `坦克: 34%`，不是按 flow 刷的就 `坦克: 固定`，本回合已刷出过则整行不画。
//        ★2.6.1 一控/二控判定修复：旧实现按"玩家的客户端槽位"累计次数（g_iSiHudTankCtrl[client]），
//          而 12v12 里玩家换槽位 / 旁观再坐回来 / 掉线重连都会让同一个槽位重新从 1 开始数，
//          于是**永远显示一控**。现在首选读引擎的传克计数 L4D2Direct_GetTankPassedCount()
//          （与 spechud 的 tankhud "第N次"同源），多坦克局或 native 缺失时退回本插件按
//          "坦克这条命 + 该玩家 SteamID"记的段数（见 SiHud_TankSegmentOf / SiHud_PlayerKey），
//          与 Apex / l4d_tank_control_eq 的"二控 = 同一玩家第二段完整控制权"口径完全一致。
//     G. 面板是 HUD，不是菜单：开关只由 !sihud 改变。SourceMod 的 Panel 收到任何按键（数字键、
//        ESC……）都会被引擎关掉，这是引擎行为、改不了；但**不再**把它当成"玩家把面板关了"
//        （2.5.21 之前用"面板提前消失 ⇒ 玩家自己关的"反推 ESC，玩家按数字键切武器就把面板按死，
//        连带那一回合的自动显示一起废掉），下一秒刷新会原样重新发出来。
// *********************************************************************************

// 特感英文名，顺序固定 = m_zombieClass 1..6（需求顺序：smoker/boomer/hunter/spitter/jockey/charger）
static const char SiHudClassNames[6][16] =
{
	"Smoker", "Boomer", "Hunter", "Spitter", "Jockey", "Charger"
};

// m_survivorCharacter 0..7 = Nick, Rochelle, Coach, Ellis, Bill, Zoey, Francis, Louis
// （与文件顶部 SurvivorModels 的模型顺序一致，那边是模型路径，这里是对外显示的名字）
static const char SiHudCharacterNames[8][16] =
{
	"Nick", "Rochelle", "Coach", "Ellis", "Bill", "Zoey", "Francis", "Louis"
};

// ------------------------------------------------------------------------
// 命令入口：sm_sihud / sm_infhud / 聊天 !sihud !infhud
//   无参数 = 开/关切换（旧行为）；on|1 / off|0 = 直接指定（2.6.0 新增，
//   方便绑键或服务器指令一键打开面板）。
// ------------------------------------------------------------------------
public Action Cmd_SiHud(int client, int args)
{
	if (client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
		return Plugin_Handled;

	if (SiHudEnable != null && !SiHudEnable.BoolValue)
	{
		ReplyToCommand(client, "[SV] 特感辅助面板已在本服关闭。");
		return Plugin_Handled;
	}

	// B：只允许非生还者打开/显示面板（感染者、旁观、未分队都可以）
	if (GetClientTeam(client) == TEAM_SURVIVOR)
	{
		PrintToChat(client, "[SV] 特感辅助面板只能由非生还者（特感/旁观）使用。");
		return Plugin_Handled;
	}

	// 屏幕上此刻有没有面板：自己开着，或者正处在强制显示窗口里。
	bool bVisible = g_bSiHudOn[client] || SiHud_IsForced(client, GetGameTime());
	bool bTurnOn = !bVisible;

	if (args >= 1)
	{
		char arg[8];
		GetCmdArg(1, arg, sizeof(arg));
		if (StrEqual(arg, "on", false) || StrEqual(arg, "1", false)) bTurnOn = true;
		else if (StrEqual(arg, "off", false) || StrEqual(arg, "0", false)) bTurnOn = false;
		else
		{
			ReplyToCommand(client, "[SV] 用法：!sihud 或 !infhud 开关面板；sm_sihud on|off 直接指定。");
			return Plugin_Handled;
		}
	}

	if (bTurnOn)
	{
		// D：坦克玩家在 tank_delay 窗口里（sm_sihud_tank_delay>0 且他的 tankhud 还在场）
		//    面板让位，到点由 Timer_SiHudTankRestore 自动交棒；tank_delay=0 时不会有这个窗口。
		//    默认 6 秒 = 克面板显示总时间 5 秒 + 1 秒（见 SIHUD_DEFAULT_TANK_DELAY）。
		if (SiHud_IsTankLocked(client))
		{
			PrintToChat(client, "[SV] 你刚接管坦克，%d 秒后面板会随着坦克HUD关闭自动显示。",
				SiHudTankDelay != null ? SiHudTankDelay.IntValue : SIHUD_DEFAULT_TANK_DELAY);
			return Plugin_Handled;
		}

		SiHud_SetPanel(client, true, SIHUD_TANKPANEL_DONE);	// 自己开的：坦克结束后别收回去
		if (SiHud_ReadyUpActive())
			PrintToChat(client, "[SV] 特感辅助面板已开启（准备阶段结束后显示），再次输入 !sihud 关闭。");
		else
			PrintToChat(client, "[SV] 特感辅助面板已开启，再次输入 !sihud 关闭。");
		return Plugin_Handled;
	}

	// 关：连强制显示窗口一起取消（否则 !sihud 之后面板还会被强制顶回来），
	// 并记"玩家自己关过"的闩锁 —— 本回合不再自动替他打开（换回合/换图/回生还者后复位）。
	SiHud_SetPanel(client, false, SIHUD_TANKPANEL_DONE);
	g_bSiHudUserOff[client] = true;
	PrintToChat(client, "[SV] 特感辅助面板已关闭（本回合不再自动打开，随时输入 !sihud 可再开）。");
	return Plugin_Handled;
}

// ------------------------------------------------------------------------
// 2.6.0：面板开关的唯一入口（需求"增加单独的开关函数"）
//   bOn = true ：打开并立刻画一帧；iTankPanel >= 0 时同时记"这块面板归谁管"
//                （SIHUD_TANKPANEL_DONE = 玩家/自动开启的，坦克结束不收回；
//                  SIHUD_TANKPANEL_AUTO = 替坦克玩家开的，坦克结束收回）
//   bOn = false：关闭、取消强制窗口、把屏幕上的面板顶掉
//   返回 true = 面板状态确实发生了变化
// ------------------------------------------------------------------------
bool SiHud_SetPanel(int client, bool bOn, int iTankPanel = -1)
{
	if (client <= 0 || client > MaxClients) return false;
	if (!IsClientInGame(client) || IsFakeClient(client)) return false;

	if (bOn)
	{
		if (GetClientTeam(client) == TEAM_SURVIVOR) return false;		// B：生还者永远不显示
		bool bChanged = !g_bSiHudOn[client];
		g_bSiHudOn[client] = true;
		g_bSiHudUserOff[client] = false;
		if (iTankPanel >= 0) g_iSiHudTankPanel[client] = iTankPanel;
		SiHud_UpdatePanel();				// 立刻画一次，不必等下一个 1 秒刷新
		return bChanged;
	}

	bool bChanged = g_bSiHudOn[client] || SiHud_IsForced(client, GetGameTime());
	g_bSiHudOn[client] = false;
	g_bSiHudSent[client] = false;
	SiHud_CancelForce(client);				// 连强制显示窗口一起取消（SiHud_CancelForce 会清 g_fSiHudForceUntil）
	if (iTankPanel >= 0) g_iSiHudTankPanel[client] = iTankPanel;
	SiHud_ClosePanel(client, SIHUD_TXT_BLANK);
	return bChanged;
}

// ------------------------------------------------------------------------
// 2.6.0：进入感染者队伍（含中途进服时已经在感染者队）自动打开面板
//   用户反馈"新玩家进入感染者队伍不会自动开启面板" —— 以前只有"本回合已强制
//   显示过"的中途进服才有一次 2 秒强制显示，之后又自动关掉，等于永远看不到面板。
//   规则：
//     · sm_sihud_auto_open=0 -> 不自动开（回到旧行为，全部靠玩家自己 !sihud）；
//     · 玩家自己 !sihud 关过 -> 本回合内不再自动开（g_bSiHudUserOff）；
//     · 生还者 / bot 不开；准备阶段照开（SiHud_DrawFrame 会等准备结束再画）。
// ------------------------------------------------------------------------
void SiHud_AutoOpen(int client, const char[] reason)
{
	if (SiHudEnable == null || !SiHudEnable.BoolValue) return;
	if (SiHudAutoOpen == null || !SiHudAutoOpen.BoolValue) return;
	if (!SiHud_CanSeePanel(client)) return;
	if (g_bSiHudUserOff[client]) return;
	if (g_bSiHudOn[client]) return;					// 已经开着
	if (SiHud_IsTankLocked(client)) return;			// 坦克让位窗口里由 Timer_SiHudTankRestore 交棒

	if (!SiHud_SetPanel(client, true, SIHUD_TANKPANEL_DONE)) return;
	PrintToChat(client, "[SV] 特感辅助面板已自动开启（输入 !sihud 关闭）。");
	if (SiHudDebug != null && SiHudDebug.BoolValue)
		LogMessage("[SV sihud] client=%d %s：自动打开面板。", client, reason);
}

// ------------------------------------------------------------------------
// 1 秒刷新：先更新坦克/女巫状态（刷出、接管、死亡），再重画一次面板
// ------------------------------------------------------------------------
public Action Timer_SiHudRefresh(Handle timer)
{
	SiHud_PollBossState();
	SiHud_PollForceShow();		// C：离开安全区的兜底（事件误发/被准备阶段挡掉时不浪费本回合机会）
	SiHud_UpdatePanel();
	return Plugin_Continue;
}

// ------------------------------------------------------------------------
// 强制显示的固定快节奏重画（SIHUD_FORCE_REDRAW 秒一次）
//   重复 timer：只有返回 Plugin_Stop 才算停掉；没有强制窗口了就自己停，
//   换图时由 TIMER_FLAG_NO_MAPCHANGE 统一回收（SiHud_ResetMap 里把句柄置空）。
// ------------------------------------------------------------------------
public Action Timer_SiHudForceTick(Handle timer)
{
	float now = GetGameTime();
	bool any = false;
	bool bKept = false;
	bool bKeep = (SiHudForceKeep != null && SiHudForceKeep.BoolValue);

	for (int client = 1; client <= MaxClients; client++)
	{
		if (g_fSiHudForceUntil[client] <= 0.0) continue;
		if (g_fSiHudForceUntil[client] > now)
		{
			any = true;
			continue;
		}
		// 窗口到期：解除强制。
		// 2.6.0：默认（sm_sihud_force_keep=1）把面板**留下来**，不再像旧版那样
		// "强制显示 2 秒 -> 自动关闭" —— 用户反馈的"生还者离开安全区后闪一下就没了"、
		// "玩家接管坦克时面板短暂显示又关闭了" 都是这一条造成的。
		// 只有玩家自己关过（g_bSiHudUserOff）或已经转生还者/离线时才真的收起来。
		g_fSiHudForceUntil[client] = 0.0;
		if (!g_bSiHudOn[client] && IsClientInGame(client) && !IsFakeClient(client))
		{
			if (bKeep && !g_bSiHudUserOff[client] && GetClientTeam(client) != TEAM_SURVIVOR)
			{
				g_bSiHudOn[client] = true;	// 保持开启：交给 1 秒常规刷新继续重画
				bKept = true;
			}
			else
			{
				g_bSiHudSent[client] = false;
				SiHud_ClosePanel(client, SIHUD_TXT_BLANK);
			}
		}
		if (SiHudDebug != null && SiHudDebug.BoolValue)
			LogMessage("[SV sihud] client=%d 强制显示结束（保持开启=%d）。", client, bKeep);
	}

	if (!any)
	{
		g_hSiHudForceTimer = null;
		// 刚被"保持开启"的玩家还等着这一拍画面：走常规刷新补一次（强制路径只发给窗口内的玩家）
		if (bKept) SiHud_UpdatePanel();
		return Plugin_Stop;
	}
	SiHud_DrawFrame(true);
	return Plugin_Continue;
}

// ------------------------------------------------------------------------
// 坦克玩家的让位窗口结束（sm_sihud_tank_delay 秒）：先关掉他的坦克HUD，再把面板交还给他
// ------------------------------------------------------------------------
public Action Timer_SiHudTankRestore(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (!client) return Plugin_Stop;

	/* 2.6.2（需求）：这个玩家的 sihud 本来就是关着的 → tankhud 也不要再动。
	   （正常情况下这种玩家压根不会进这个 timer —— SiHud_OnTankEvent 发现面板关着就不建 timer；
	     这里再挡一次，覆盖"延迟期间他自己把面板关掉"的情况。） */
	if (SiHud_PanelIsClosed(client)) return Plugin_Stop;

	// 需求：坦克玩家接管坦克后过 N 秒才关掉他的 tankhud（这 N 秒他先看自己的坦克血量）
	if (IsClientInGame(client)) SiHud_DisableTankHud(client);

	if (!IsClientInGame(client) || IsFakeClient(client)) return Plugin_Stop;
	if (GetClientTeam(client) == TEAM_SURVIVOR) return Plugin_Stop;
	if (SiHud_IsTankLocked(client)) return Plugin_Stop;	// 锁又被延长了，交给更晚的 timer
	SiHud_TankHandoverPanel(client);					// 时间到：面板回到他屏幕上
	return Plugin_Stop;
}

// ------------------------------------------------------------------------
// 坦克玩家的面板交接（问题 4 的修法）
//   tank_delay 到点、他的 tankhud 已经关掉之后调用：
//     · 他原本开着面板 → 什么都不用做，下一秒刷新自然会重画；
//     · 他原本没开（最常见：变成坦克之前压根没输入过 !sihud）→ **替他打开一次**。
//       旧代码在这里 `if (!g_bSiHudOn[client]) return`，结果 tankhud 关了以后他一块 HUD
//       都没有 —— 这就是玩家反馈的"坦克玩家看不到面板"。
//   每只坦克只接管一次（g_iSiHudTankPanel 记状态）：之后玩家自己 !sihud 关掉就不再硬开。
// ------------------------------------------------------------------------
void SiHud_TankHandoverPanel(int client)
{
	if (client <= 0 || client > MaxClients) return;
	if (g_iSiHudTankPanel[client] != SIHUD_TANKPANEL_NONE) return;	// 这只坦克已经处理过
	if (!SiHud_IsTankClient(client)) return;						// 坦克已经没了（死亡 / 换人）：不接管
	if (SiHud_IsTankLocked(client)) return;							// 还在 tankhud 让位窗口里
	if (!SiHud_CanSeePanel(client)) return;							// 已转生还者 / 已离线：不接管

	/* 2.6.2（需求）：他的 sihud 本来关着 → **不替他打开**（也不动 tankhud）。
	   既然没关他的 tankhud，他就不会"什么 HUD 都没有"，不需要再补开面板。
	   标记成 DONE 只是别让 1 秒轮询每秒重试一次；之后他自己 !sihud 打开仍照常生效。 */
	if (SiHud_PanelIsClosed(client))
	{
		g_iSiHudTankPanel[client] = SIHUD_TANKPANEL_DONE;
		if (SiHudDebug != null && SiHudDebug.BoolValue)
			LogMessage("[SV sihud] client=%d 坦克让位结束，但他 sihud 本来关着：不替他打开、tankhud 也未关闭。", client);
		return;
	}

	g_iSiHudTankPanel[client] = SIHUD_TANKPANEL_DONE;
	if (g_bSiHudOn[client])											// 他本来开着：直接重画一拍
	{
		SiHud_UpdatePanel();
		return;
	}

	g_bSiHudOn[client] = true;
	g_iSiHudTankPanel[client] = SIHUD_TANKPANEL_AUTO;
	SiHud_UpdatePanel();
	if (SiHudDebug != null && SiHudDebug.BoolValue)
		LogMessage("[SV sihud] client=%d 坦克让位结束：替他自动打开面板（坦克结束后收回）。", client);
}

// 坦克结束（坦克死亡 / 换人 / 本回合结束）：把替他自动打开的面板收回去，恢复他自己原本的选择
//   2.6.0：sm_sihud_auto_open=1（默认）时"面板就是特感玩家的常驻 HUD" —— 坦克一死就把他的
//   面板收掉会让屏幕立刻又空掉（玩家反馈的"面板自动关闭"）。所以这种情况下保持开启，
//   只把交接状态改成 DONE；只有"不自动开启"或玩家自己关过（g_bSiHudUserOff）时才真的收回去。
void SiHud_ReleaseTankPanel(int client)
{
	if (client < 0 || client > MaxClients) return;
	bool bAuto = (g_iSiHudTankPanel[client] == SIHUD_TANKPANEL_AUTO);
	g_iSiHudTankPanel[client] = SIHUD_TANKPANEL_NONE;
	if (!bAuto) return;

	bool bKeep = (SiHudAutoOpen != null && SiHudAutoOpen.BoolValue && !g_bSiHudUserOff[client]);
	if (bKeep && SiHud_CanSeePanel(client))
	{
		g_iSiHudTankPanel[client] = SIHUD_TANKPANEL_DONE;
		SiHud_UpdatePanel();
		return;
	}

	g_bSiHudOn[client] = false;
	g_bSiHudSent[client] = false;
	if (IsClientInGame(client) && !IsFakeClient(client)) SiHud_ClosePanel(client, SIHUD_TXT_BLANK);
}

// ------------------------------------------------------------------------
// 坦克刷出（tank_spawn）
//   需求：坦克刷出以及被接管时 → 关掉所有玩家的 tankhud，并强制显示面板 2 秒。
//   实际处理在 SiHud_OnTankEvent（事件与 1 秒轮询共用同一条路径）。
// ------------------------------------------------------------------------
public void Event_TankSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int tank = GetClientOfUserId(event.GetInt("userid"));
	if (tank <= 0 || !IsClientInGame(tank) || GetClientTeam(tank) != TEAM_INFECTED)
	{
		// AI 坦克：userid 拿不到客户端时用 tankid（坦克实体的 entindex 与 client index 同号）
		int tankId = event.GetInt("tankid");
		tank = (tankId > 0 && tankId <= MaxClients) ? tankId : 0;
	}

	g_iSiHudTankClient = tank;
	/* 2.6.1：控数改成"坦克这条命 + 玩家 SteamID"（见 SiHud_TankSegmentTick）。
	   ★这里**不清零**、也不按槽位 +1：L4D2 里"AI 坦克交给玩家"和"同一玩家回控"都可能再发一次
	     tank_spawn，在事件里计数/清零都会把二控又数回一控（旧代码正是这么错的）。
	     段数完全由 SiHud_TankSegmentTick 按「控制者 key 变化」和「怒气被复位」两条判据推进，
	     清零只发生在坦克死亡 / 场上没有坦克 / 换回合（见 Event_TankKilled、SiHud_PollBossState、
	     SiHud_ResetBossState）。 */
	if (tank > 0 && tank <= MaxClients) SiHud_TankSegmentTick(tank, GetGameTime());
	g_iSiHudTankControl = SiHud_TankSegmentOf(tank);
	g_bSiHudTankSpawned = true;
	if (tank > 0 && tank <= MaxClients) g_iSiHudTankPanel[tank] = SIHUD_TANKPANEL_NONE;	// 新的一只坦克：交接状态重置

	SiHud_OnTankEvent(tank, false);
}

// 坦克死亡（tank_killed）：本回合刷出过（活着/死了都算）→ 面板不再画"坦克"那一行（需求）
public void Event_TankKilled(Event event, const char[] name, bool dontBroadcast)
{
	g_iSiHudTankClient = 0;
	g_bSiHudTankSpawned = true;
	// 2.6.1：这只坦克死了 = 这条命结束，控数状态清掉（下一只坦克从一控开始数）
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client)) continue;
		if (SiHud_IsTankClient(client)) continue;	// 同时还有另一只坦克活着：它的控数不能清
		SiHud_ResetTankSegment(client);
	}
}

// 女巫刷出 / 死亡：只影响面板最下面"女巫"那一行要不要画（刷出过就整行不画）
public void Event_WitchSpawn(Event event, const char[] name, bool dontBroadcast)
{
	g_bSiHudWitchSpawned = true;
}

public void Event_WitchKilled(Event event, const char[] name, bool dontBroadcast)
{
	g_bSiHudWitchSpawned = true;
}

// ------------------------------------------------------------------------
// 1 秒轮询坦克 / 女巫状态（Timer_SiHudRefresh 里调）
//   · 坦克：事件没覆盖到的"刷出"（插件晚加载、事件丢失）与**接管**（同一只坦克换了控制者）
//     都在这里兜住。接管 = 二控，需求要求按新的坦克玩家重新计时（tank_delay，默认 6 秒）；
//   · 女巫：主线靠 witch_spawn 事件，这里只兜"实体已经在场却没收到事件"的情况。
// ------------------------------------------------------------------------
void SiHud_PollBossState()
{
	if (SiHudEnable == null || !SiHudEnable.BoolValue) return;

	int tank = SiHud_FindTankClient();
	if (tank <= 0)
	{
		// 场上没有坦克：等下一只（死亡由 tank_killed 标记）
		g_iSiHudTankClient = 0;

		/* 2.6.1：tank_killed 事件漏接的兜底 —— 场上确实已经没有坦克了，
		   把所有"已经不是坦克"的槽位的控数状态清掉，下一只坦克从一控重新数。
		   （不清的话，下一只坦克如果坐进同一槽位，会继承上一辆的段数显示成二控。） */
		for (int client = 1; client <= MaxClients; client++)
		{
			if (!IsClientInGame(client)) continue;
			if (SiHud_IsTankClient(client)) continue;
			if (g_sSiHudTankKey[client][0] == '\0') continue;	// 本来就没记过，省掉
			SiHud_ResetTankSegment(client);
		}
	}
	else if (g_iSiHudTankClient == 0)
	{
		// 没收到 tank_spawn（或插件晚加载）：按"刷出"处理
		g_iSiHudTankClient = tank;
		g_iSiHudTankControl = SiHud_IsHumanTank(tank) ? 1 : 0;
		g_bSiHudTankSpawned = true;
		SiHud_TankSegmentTick(tank, GetGameTime());	// 2.6.1：按"坦克+玩家"记控制权段数
		SiHud_OnTankEvent(tank, false);
	}
	else if (tank != g_iSiHudTankClient)
	{
		if (SiHud_IsTankClient(g_iSiHudTankClient))
		{
			/* 上一任现在还是坦克 = 场上同时有多只坦克（决赛/多坦克局）：
			   这里只是"先找到了另一只"，既不是接管也不是新刷出，保持原来的跟踪对象，
			   否则每秒都会误判成一次接管（关 tankhud + 强制 2 秒）。 */
		}
		else
		{
			bool bHuman = SiHud_IsHumanTank(tank);
			g_iSiHudTankClient = tank;

			/* 2.6.1：控制权段数统一由 SiHud_TankSegmentTick 判定（换 key / 怒气复位）。
			   AI 接手（玩家掉线/放弃）也要记：AI 段是这辆坦克这条命的一部分，
			   之后同一名玩家再坐回来时，靠这里的 key 变化才能认出"他拿回了同一辆坦克"。 */
			SiHud_TankSegmentTick(tank, GetGameTime());
			g_iSiHudTankControl = SiHud_TankSegmentOf(tank);

			if (bHuman)
			{
				/* 上一任已经不再是坦克、这只坦克换成了真人控制 = 接管（二控）。
				   需求：二控要按当前坦克玩家重新计时，所以走同一个坦克事件入口。 */
				/* 换了一名控制者 = 新的一段：交接状态复位，否则他上一段留下的
				   SIHUD_TANKPANEL_DONE 会让 SiHud_TankHandoverPanel 直接 return，
				   接管后他的面板就再也不会被打开（用户反馈的"接管坦克后面板短暂显示又关闭"的成因之一）。 */
				g_iSiHudTankPanel[tank] = SIHUD_TANKPANEL_NONE;
				g_bSiHudTankSpawned = true;
				SiHud_OnTankEvent(tank, true);
			}
		}
	}
	else
	{
		// 2.6.1：跟踪对象没变也要每秒推进一次（同一玩家回控 = 怒气被复位 = 二控）
		SiHud_TankSegmentTick(tank, GetGameTime());
		g_iSiHudTankControl = SiHud_TankSegmentOf(tank);
	}

	// 女巫：只在"还没刷出过"时扫一次实体，扫到之后就不再扫
	if (!g_bSiHudWitchSpawned && FindEntityByClassname(-1, "witch") != -1)
	{
		g_bSiHudWitchSpawned = true;
	}

	// 真人坦克的面板交接：让位窗口（tank_delay）结束后必须让他看到面板（问题 4 的修法）。
	// 放在轮询里是因为"AI 坦克被真人接管"、"插件晚加载"这些路径不会再有 tank_spawn 事件。
	if (g_iSiHudTankClient > 0 && SiHud_IsHumanTank(g_iSiHudTankClient))
		SiHud_TankHandoverPanel(g_iSiHudTankClient);

	// 已经不当坦克的人（坦克死亡 / 换人 / 回合结束）：把替他自动打开的面板收回去
	for (int client = 1; client <= MaxClients; client++)
	{
		if (g_iSiHudTankPanel[client] == SIHUD_TANKPANEL_NONE) continue;
		if (client == g_iSiHudTankClient && SiHud_IsTankClient(client)) continue;	// 还是那只坦克：留着
		SiHud_ReleaseTankPanel(client);
	}
}

// 场上坦克玩家（真人或 AI bot）：team 3 + m_zombieClass=ZC_TANK + 活着；0 = 场上没有
int SiHud_FindTankClient()
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || !IsPlayerAlive(client)) continue;
		if (GetSiType(client) != ZC_TANK) continue;
		return client;
	}
	return 0;
}

// 这个 client 现在是不是坦克（活着 + 感染者队 + m_zombieClass=ZC_TANK）
bool SiHud_IsTankClient(int client)
{
	if (client <= 0 || client > MaxClients) return false;
	if (!IsClientInGame(client) || !IsPlayerAlive(client)) return false;
	return GetSiType(client) == ZC_TANK;
}

// 是不是"真人"坦克玩家（client 合法 + 感染者队 + 非 bot）
bool SiHud_IsHumanTank(int client)
{
	if (client <= 0 || client > MaxClients) return false;
	if (!IsClientInGame(client) || IsFakeClient(client)) return false;
	return GetClientTeam(client) == TEAM_INFECTED;
}

// ------------------------------------------------------------------------
// 一控 / 二控：按"坦克这条命 + 玩家 SteamID"记完整控制权段数（2.6.1 重写，见文件头 E 段）
//   每辆坦克（client 槽位）各一份状态：
//     g_sSiHudTankKey[i]     当前这段控制权属于谁（SteamID；AI 坦克 = "AI"；"" = 还没记过）
//     g_iSiHudTankSeg[i]     该 key 在这辆坦克上的完整控制权段数（1 = 一控，2+ = 二控）
//     g_iSiHudTankPrevFrus[i] 上一秒读到的 m_frustration
//   两个"新的一段控制权"的来源：
//     ① **换人**：key 变了（真人接手 / 换另一名玩家 / AI↔真人）→ 新 key 的段数 = 1；
//        同一名玩家（同 SteamID）从别的槽位拿回来 → 沿用他自己的段数 +1；
//     ② **同一玩家回控**：key 没变，但怒气被**复位**了（m_frustration 明显变小）——
//        引擎/控制权插件把已经消耗掉的控制权又给了他一段（本服二控的标准形态）。
//        这里不复位段数，直接 +1，并且只认"从高位掉下来"（>= SIHUD_TANK_SEG_DROP_FROM），
//        避免怒气在 0 附近抖动时被反复计数。
//   段数只在"这只坦克这条命"内累计：坦克死亡 / 插件清理 / 新回合全部清零。
// ------------------------------------------------------------------------
#define SIHUD_TANK_SEG_DROP_FROM  40	// 怒气从 >=40 掉到这个值的一半以下才算"又被给了一段控制权"
#define SIHUD_TANK_SEG_MIN_GAP    1.0	// 两次计数之间至少隔这么多秒，挡住同一帧/相邻秒的重复判定
#define SIHUD_KEY_LEN             64	// 身份 key（SteamID / "AI"）的缓冲区长度
                                        // 注意：数组第二维不要用 sizeof(arr[][]) 取，SourcePawn 会对标量返回 1（warning 252）

// 取玩家的身份 key：真人 = SteamID（掉线重连/换槽位不变）；bot = "AI"；取不到 = ""
void SiHud_PlayerKey(int client, char[] out, int maxlen)
{
	out[0] = '\0';
	if (client <= 0 || client > MaxClients) return;
	if (!IsClientInGame(client)) return;

	if (IsFakeClient(client))
	{
		strcopy(out, maxlen, "AI");
		return;
	}

	if (!GetClientAuthId(client, AuthId_Steam2, out, maxlen, false))
	{
		// SteamID 拿不到（极少见：刚连接/匿名）：退化成槽位号，只保证"不会误判成同一个人"
		FormatEx(out, maxlen, "slot%d", client);
	}
}

// 把这辆坦克的"控制权段"推进一次（由 SiHud_PollBossState 每秒调用一次）
//   ★状态的生命周期（重要，改之前先读）：
//     · **不在 tank_spawn 里清零**。L4D2 里"AI 坦克交给玩家"、"同一玩家回控"都可能再发一次
//       tank_spawn，如果在事件里清零，二控就会被重新数成一控 —— 正是要修的 bug 的翻版。
//     · 清零只有三个入口：Event_TankKilled（这只坦克死了）、轮询发现场上已经没有坦克
//       （事件漏接的兜底）、换回合 / 换图（SiHud_ResetBossState）。
//     · 坦克槽位在"上一条命结束"时一定先变成"不再是坦克"，也就是一定先被清过一次；
//       所以新坦克第一次出现在某个槽位时 key 是空的 → 从第一段开始数，不会继承上一辆坦克的段数。
void SiHud_TankSegmentTick(int tank, float fNow)
{
	if (tank <= 0 || tank > MaxClients) return;

	char key[64];
	SiHud_PlayerKey(tank, key, sizeof(key));

	int frus = GetEntProp(tank, Prop_Send, "m_frustration");
	if (frus < 0) frus = 0;
	else if (frus > 100) frus = 100;

	int prevFrus = g_iSiHudTankPrevFrus[tank];
	g_iSiHudTankPrevFrus[tank] = frus;

	// ① 控制者换了（含 AI -> 真人、真人 -> AI、换另一名玩家、同一名玩家换槽位回来）
	if (!StrEqual(key, g_sSiHudTankKey[tank], false))
	{
		char sOldKey[64];
		strcopy(sOldKey, sizeof(sOldKey), g_sSiHudTankKey[tank]);

		// 控制权从"真人"手里交出去（交给 AI / 交给另一名玩家）：把他的 key 与段数留一份，
		// 这样同一名玩家之后把同一辆坦克拿回来时，能接着往上数成二控。
		if (sOldKey[0] != '\0' && !StrEqual(sOldKey, "AI", false))
		{
			strcopy(g_sSiHudTankPrevHuman[tank], SIHUD_KEY_LEN, sOldKey);
			g_iSiHudTankPrevHumanSeg[tank] = g_iSiHudTankSeg[tank];
		}

		strcopy(g_sSiHudTankKey[tank], SIHUD_KEY_LEN, key);

		if (key[0] == '\0' || StrEqual(key, "AI", false))
		{
			// AI 段 / 还没人：没有"几控"（上一名真人的段数已经存档，不会丢）
			g_iSiHudTankSeg[tank] = 0;
		}
		else if (g_sSiHudTankPrevHuman[tank][0] != '\0'
			&& StrEqual(key, g_sSiHudTankPrevHuman[tank], false)
			&& g_iSiHudTankPrevHumanSeg[tank] > 0)
		{
			/* 同一名真人把同一辆坦克拿回来（中间可能是 AI 段 / 掉线换人 / 换槽位）→ 二控。
			   只认"这条命里他确实控制过"（prevHuman 有存档且有段数），
			   新坦克第一次被占用的槽位 sOldKey 是空的、不会走到这里。 */
			g_iSiHudTankSeg[tank] = g_iSiHudTankPrevHumanSeg[tank] + 1;
		}
		else
		{
			// 换的是另一名玩家 → 这一段是他的第一段
			g_iSiHudTankSeg[tank] = 1;
		}

		g_fSiHudTankSegAt[tank] = fNow;

		if (SiHudDebug != null && SiHudDebug.BoolValue)
		{
			LogMessage("[SV sihud] 坦克 %d 控制者 %s -> %s，记为第 %d 段控制权。",
				tank, (sOldKey[0] == '\0') ? "(空)" : sOldKey, key, g_iSiHudTankSeg[tank]);
		}

		return;
	}

	// ② 同一名玩家、同一辆坦克：怒气被复位 = 引擎/控制权插件又给了他一段完整控制权
	if (key[0] != '\0' && !StrEqual(key, "AI", false))
	{
		bool bDropped = (prevFrus >= SIHUD_TANK_SEG_DROP_FROM) && (frus * 2 < prevFrus);
		bool bGapOk = (fNow - g_fSiHudTankSegAt[tank]) >= SIHUD_TANK_SEG_MIN_GAP;

		if (bDropped && bGapOk)
		{
			g_iSiHudTankSeg[tank]++;
			g_fSiHudTankSegAt[tank] = fNow;
			// 真人段数同步进"上一名真人"的存档：这段被消耗掉之后再回来，还要接着往上数
			strcopy(g_sSiHudTankPrevHuman[tank], SIHUD_KEY_LEN, key);
			g_iSiHudTankPrevHumanSeg[tank] = g_iSiHudTankSeg[tank];

			if (SiHudDebug != null && SiHudDebug.BoolValue)
			{
				LogMessage("[SV sihud] 坦克 %d 怒气 %d -> %d（被复位），%s 拿到第 %d 段控制权。",
					tank, prevFrus, frus, key, g_iSiHudTankSeg[tank]);
			}
		}
	}
}

// 该坦克的控制权段数（1 = 一控，>=2 = 二控）；AI 坦克返回 0（没有"几控"）
//   数据源分两种场合：
//   ① **场上只有一只坦克**（正常对局，99% 的情况）→ 直接读引擎自己的传克计数
//      L4D2Direct_GetTankPassedCount()。spechud 的 tankhud 显示"第N次"读的就是它
//      （spechud_appledmod.sp 的 `int passCount = L4D2Direct_GetTankPassedCount();`），
//      所以两块 HUD 的控数天生一致 —— 玩家要的"参考 spechud 的 tankhud 显示"就是这一条。
//      语义（left4dhooks.inc:5722-5730）：AI 交给玩家的那一次也算一次 pass，
//      pass=1 = 一控、pass=2 = 二控、pass>=3 继续往上数；它由引擎 + 控制权插件
//      （l4d_tank_control_eq 的 L4D2Direct_SetTankPassedCount）共同维护，
//      玩家换槽位 / 掉线重连 / 转旁观再回来都不会清零 —— 这正是"一直显示一控"的根治点。
//   ② **多只坦克同时存活**（终局/多坦克局）→ 改用本插件按"坦克 + SteamID"记的段数。
//      原因：引擎那个计数是**全局一个数**，left4dhooks 文档明确写了"多坦克同时存活时可能出怪事"，
//      两行会显示同一个数字。本插件的段数逐只坦克各算各的，这种场合反而更准。
//   ③ native 不可用（旧版 left4dhooks）→ 一律用本插件自己的段数。
int SiHud_TankSegmentOf(int tank)
{
	if (tank <= 0 || tank > MaxClients) return 0;
	if (IsFakeClient(tank)) return 0;

	bool bUseEngine = g_bSiHudTankPassNative && (SiHud_CountAliveTanks() <= 1);

	if (bUseEngine)
	{
		int pass = L4D2Direct_GetTankPassedCount();
		if (pass < 1) pass = 1;			// 引擎还没记上 / 刚刷出：按一控画
		return pass;
	}

	if (g_iSiHudTankSeg[tank] < 1) return 1;	// 状态还没记上（刷出同一秒就画面板）：按一控画
	return g_iSiHudTankSeg[tank];
}

// 场上活着的坦克数量（含 AI 坦克）
int SiHud_CountAliveTanks()
{
	int count = 0;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || !IsPlayerAlive(client)) continue;
		if (GetSiType(client) != ZC_TANK) continue;
		count++;
	}
	return count;
}

// 清掉一辆坦克的控数状态（坦克死亡 / 玩家离开 / 回合重置时调）
void SiHud_ResetTankSegment(int tank)
{
	if (tank < 0 || tank > MaxClients) return;
	g_sSiHudTankKey[tank][0] = '\0';
	g_iSiHudTankSeg[tank] = 0;
	g_iSiHudTankPrevFrus[tank] = 0;
	g_fSiHudTankSegAt[tank] = 0.0;
	g_sSiHudTankPrevHuman[tank][0] = '\0';
	g_iSiHudTankPrevHumanSeg[tank] = 0;
}

// ------------------------------------------------------------------------
// 坦克事件（刷出 / 接管）统一入口
//   0) ★2.6.2（需求）：**sihud 已经处于关闭状态**的玩家，两个都不动 ——
//      不关他的 tankhud、不强开 sihud 面板、也不替他自动打开（判定见 SiHud_PanelIsClosed）。
//      理由：tankhud 与 sihud 是同一套信息的两个面（本面板里已经有坦克行），
//      玩家既然把面板关了，就不该再被弹面板；此时顺手关掉他的坦克HUD 等于两头都拿走。
//      只有 sihud 开着的玩家才继续走下面 1)~4) 的「关 tankhud + 强开 2 秒」；
//   1) 除坦克玩家外的所有玩家：立刻关掉 tankhud（需求第 2 条）；
//   3) 坦克玩家：克面板先留着（sm_sihud_tank_delay，默认 6 秒 = 克面板 5 秒 + 1 秒，让他看自己的坦克血量），
//      到点由 Timer_SiHudTankRestore 关掉；这 6 秒里面板让位（g_fSiHudTankLockUntil），
//      但那 2 秒强制显示对他同样生效（需求第 4 条）。
//   bTakeover=true 表示同一只坦克被另一名玩家接管（二控）：按新的坦克玩家重新计时。
// ------------------------------------------------------------------------
void SiHud_OnTankEvent(int tank, bool bTakeover)
{
	if (SiHudEnable == null || !SiHudEnable.BoolValue) return;

	int delay = (SiHudTankDelay != null) ? SiHudTankDelay.IntValue : SIHUD_DEFAULT_TANK_DELAY;
	if (delay < 0) delay = 0;

	bool bHuman = SiHud_IsHumanTank(tank);

	/* 2.6.2（需求）：坦克刷出 / 接管时，对**sihud 已经关着**的玩家两个都不动 ——
	   既不关他的 tankhud，也不强开 sihud 面板（也不替他自动打开）。
	   理由：tankhud 与 sihud 是一套东西的两面（面板里已经有坦克行），
	   把面板关了的人本来就不想被弹面板；这时再顺手关掉他的坦克HUD 等于两头都拿走。
	   —— 只有 sihud 开着的玩家才走原来的「关 tankhud + 强开 2 秒」流程。 */

	// 1) 关掉 tankhud（有真人坦克玩家时他除外：他延迟 delay 秒才关）
	bool bTankPanelClosed = (bHuman && SiHud_PanelIsClosed(tank));
	int iSkippedClosed = 0;		// 2.6.2：因为 sihud 本来关着而整段跳过的人数（调试日志用）

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || IsFakeClient(client)) continue;
		if (bHuman && client == tank) continue;
		if (SiHud_PanelIsClosed(client)) { iSkippedClosed++; continue; }	// 2.6.2：sihud 关着 → tankhud 也不碰
		SiHud_DisableTankHud(client);
	}

	// 2) 坦克玩家（2.6.0 重写：保证他任何时刻都有 HUD）
	//    · 没有 tankhud（spechud_appledmod 不在场 / 已经被强制关掉 / tank_delay=0）：
	//      **立刻**交棒 —— 旧版无条件先让他看 7 秒 tankhud，可 tankhud 万一已经被关掉，
	//      那 7 秒里他既没有 tankhud 也没有面板 = 用户反馈的"坦克玩家什么 HUD 都看不到"；
	//    · 有 tankhud 且 tank_delay>0：先让他看完自己的克面板（默认 6 秒 = 克面板 5 秒 + 1 秒，
	//      面板让位），到点关 tankhud 并把面板交棒。
	//    · 2.6.2：他的 sihud 本来就关着 → 整段跳过（tankhud 留着，面板不弹也不接管）。
	if (bHuman && !bTankPanelClosed)
	{
		g_bSiHudSent[tank] = false;
		int iHandoverDelay = (SiHud_SpecHudReady() && delay > 0) ? delay : 0;
		if (iHandoverDelay > 0)
		{
			g_fSiHudTankLockUntil[tank] = GetGameTime() + float(iHandoverDelay);
			/* 不保存 timer 句柄：二控 / 同一玩家连着刷两次坦克时多出来的那个 timer
			   只会再关一次 tankhud、再刷一次面板，不会造成错乱；换图时由引擎统一回收。 */
			CreateTimer(float(iHandoverDelay), Timer_SiHudTankRestore, GetClientUserId(tank), TIMER_FLAG_NO_MAPCHANGE);
		}
		else
		{
			g_fSiHudTankLockUntil[tank] = 0.0;
			if (SiHud_SpecHudReady()) SiHud_DisableTankHud(tank);
			SiHud_TankHandoverPanel(tank);		// 面板立刻接管（含替他自动打开）
		}
	}

	// 3) 除坦克玩家外的所有玩家：连续 2 秒强制显示
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!SiHud_CanSeePanel(client)) continue;
		if (bHuman && client == tank) continue;
		if (SiHud_PanelIsClosed(client)) continue;		// 2.6.2：sihud 关着 → 不弹面板
		SiHud_ForceShowStart(client, SIHUD_FORCE_SECONDS);
	}
	// 4) 坦克玩家本人：同样强制显示 2 秒（让位窗口里也生效）；sihud 关着则不弹
	if (bHuman && !bTankPanelClosed) SiHud_ForceShowStart(tank, SIHUD_FORCE_SECONDS);

	// 立刻画一拍（强制窗口的 timer 下一拍会接着画）
	SiHud_DrawFrame(true);

	if (SiHudDebug != null && SiHudDebug.BoolValue)
		LogMessage("[SV sihud] 坦克%s：tank=%d（%s，%d 控），坦克玩家 tankhud 延迟 %d 秒关，其它玩家强制显示 %.1f 秒；sihud 本来关着而跳过 %d 人（坦克玩家%s）。",
			bTakeover ? "接管" : "刷出", tank, bHuman ? "真人" : "AI", g_iSiHudTankControl, delay, SIHUD_FORCE_SECONDS,
			iSkippedClosed, (bTankPanelClosed ? "也跳过" : "照常处理"));
}

// 关掉某名玩家的 tankhud（"坦克HUD" 由 spechud_appledmod 画；该插件不在时什么也不做）
void SiHud_DisableTankHud(int client)
{
	if (client <= 0 || client > MaxClients) return;
	if (!SiHud_SpecHudReady()) return;
	SpecHud_TankHudDisable(client);
}

// spechud_appledmod 的关闭接口在不在：缓存的是 OnConfigsExecuted 那一刻的探测结果，
// 该插件后来才加载/重载时在这里补探一次（只在坦克事件里调用，几秒钟才一次，开销无所谓）
bool SiHud_SpecHudReady()
{
	if (g_bSiHudSpecHudNative) return true;
	g_bSiHudSpecHudNative = SiHud_NativeAvailable("SpecHud_TankHudDisable");
	return g_bSiHudSpecHudNative;
}

// ------------------------------------------------------------------------
// 强制显示窗口
//   窗口内不管玩家自己的开关、也不管坦克让位窗口，一律画面板（需求："连续 2 秒一直打开"）。
//   窗口由 Timer_SiHudForceTick 按 SIHUD_FORCE_REDRAW（0.25 秒）重画，2 秒里面板不会掉。
//   玩家在窗口内输入 !sihud 关闭 → SiHud_CancelForce 立刻取消窗口，不强抢屏幕；按键/ESC 只是
//   让引擎那块窗口消失，不算"玩家不要面板"（见 SiHud_DummyHandler）。
// ------------------------------------------------------------------------
// 能不能看面板：游戏内、真人、非生还者（规则 B）
bool SiHud_CanSeePanel(int client)
{
	if (client <= 0 || client > MaxClients) return false;
	if (!IsClientInGame(client) || IsFakeClient(client)) return false;
	return GetClientTeam(client) != TEAM_SURVIVOR;
}

// 2.6.2（需求）：玩家此刻的 sihud 是不是**已经处于关闭状态**。
//   判定只看**开关状态** g_bSiHudOn（!sihud 打开的 / 进感染者自动打开的才算"开着"）：
//      · 玩家自己用 !sihud 关掉过 → 关；
//      · 从来没用过 !sihud 的旁观者/中途进服者 → 也是关（面板本来就没显示）。
//   为什么不把"强制显示窗口"算成开着：那种 2 秒窗口是**临时画面**、不是玩家选择。
//   若把它算成开着，会出现"窗口里被关 tankhud → 2 秒后面板消失、tankhud 也没了"的两头落空，
//   正是本次要修的体验问题。所以窗口里的玩家照样按"关"处理：不动 sihud、也不动 tankhud。
//   用途：坦克刷出 / 接管时，对这种玩家**既不碰 sihud、也不碰他的 tankhud**。
bool SiHud_PanelIsClosed(int client)
{
	if (client <= 0 || client > MaxClients) return true;
	return !g_bSiHudOn[client];
}

bool SiHud_IsForced(int client, float now)
{
	if (client <= 0 || client > MaxClients) return false;
	return g_fSiHudForceUntil[client] > now;
}

void SiHud_ForceShowStart(int client, float seconds)
{
	if (client <= 0 || client > MaxClients) return;
	if (seconds <= 0.0) return;
	float until = GetGameTime() + seconds;
	// 已经在窗口里就只延长（两个事件挨在一起时别把它缩短）
	if (until <= g_fSiHudForceUntil[client]) return;
	g_fSiHudForceUntil[client] = until;
	SiHud_EnsureForceTimer();
}

// 对所有能看面板的玩家开强制窗口（离开安全区时用）
//   返回"开出了几个人的窗口"：一个能看面板的玩家都没有（人都没进服 / 全在生还者队）时返回 0，
//   调用方据此**不算用掉**本回合那唯一一次自动显示机会（见 SiHud_TryForceShowAll）。
int SiHud_ForceShowAll(float seconds)
{
	int count = 0;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!SiHud_CanSeePanel(client)) continue;
		SiHud_ForceShowStart(client, seconds);
		count++;
	}
	if (count) SiHud_DrawFrame(true);
	return count;
}

// 取消某人的强制窗口（玩家自己输入 !sihud 关掉面板时调用）
void SiHud_CancelForce(int client)
{
	if (client <= 0 || client > MaxClients) return;
	g_fSiHudForceUntil[client] = 0.0;
}

void SiHud_EnsureForceTimer()
{
	if (g_hSiHudForceTimer != null) return;
	g_hSiHudForceTimer = CreateTimer(SIHUD_FORCE_REDRAW, Timer_SiHudForceTick, _,
		TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

// ------------------------------------------------------------------------
// C：生还者离开安全区域（player_left_start_area / player_left_checkpoint）
//   需求：**每回合首次**离开时，对所有能看面板的玩家（感染者 / 旁观 / 未分队）连续 2 秒
//         强制显示面板（这段时间每 0.25 秒重画一次，被别的面板顶掉也立刻顶回来）；
//         2 秒后解除强制 —— 之后不再自动打开，面板开/关由玩家自己的 !sihud 决定。
//   手动关掉过的玩家同样会被强制这 2 秒（需求原文"所有玩家"），再输入一次 !sihud 可以立刻
//   取消（SiHud_CancelForce）；按键 / ESC 关掉的只是引擎那块窗口，不算玩家关掉了面板。
//   sm_sihud_force_show=0 时不做强制，只刷新已经开着面板的人（旧行为）。
// ------------------------------------------------------------------------
void SiHud_OnSurvivorLeftSafeArea()
{
	if (SiHudEnable == null || !SiHudEnable.BoolValue) return;

	// 先把"本回合有人离开过安全区"记下来：准备阶段会把这一次强制显示挡掉，
	// 由 Timer_SiHudRefresh 里的 1 秒轮询（SiHud_PollForceShow）补发。
	g_bSiHudLeftSafeArea = true;

	// 本回合已经强制显示过 / 关掉了强制显示：只刷新，不再强开
	if (g_bSiHudAutoShownRound || SiHudForceShow == null || !SiHudForceShow.BoolValue)
	{
		SiHud_UpdatePanel();
		return;
	}

	// 事件本身不可信：换图 / 读图 / 出生点重定位时引擎会误发 player_left_start_area
	// （hdf.sp 里有同样的记录）。这里用 Left4DHooks 的"确实有生还者离开安全区"复核一次，
	// 复核不过就先不消耗机会 —— 真离开了由 1 秒轮询补上。
	if (!SiHud_SurvivorsLeftSafeArea())
	{
		SiHud_UpdatePanel();
		return;
	}

	SiHud_TryForceShowAll();
}

// "确实有生还者离开安全区"的二次确认。
//   L4D_HasAnySurvivorLeftSafeArea 在 left4dhooks.inc 里是 optional native（服务器上的
//   Left4DHooks 版本太旧时会没绑定），拿不到就退回"只信事件本身"，绝不因为探测而中断。
bool SiHud_SurvivorsLeftSafeArea()
{
	if (!g_bSiHudSafeAreaNative) return true;
	return AnySurvivorLeftSafeArea();
}

// ------------------------------------------------------------------------
// C'：真正把"本回合首次离开安全区"的强制显示发出去
//   只有**确实发出去了**（至少有一个能看面板的玩家、而且不在准备阶段）才算用掉本回合的机会：
//     · 准备阶段（readyup / 门锁面板在场）不抢屏幕，机会留着等准备结束；
//     · 一个能看面板的玩家都没有（人都没进服 / 全在生还者队）也不算用掉。
//   旧代码在这两种情况下照样把 g_bSiHudAutoShownRound 置 true，于是真正离开安全区时面板
//   再也不会自动显示，玩家只能自己 !sihud —— 这是玩家反馈"离开安全区不会自动显示面板"的主因。
// ------------------------------------------------------------------------
bool SiHud_TryForceShowAll()
{
	if (SiHud_ReadyUpActive()) return false;
	if (SiHud_ForceShowAll(SIHUD_FORCE_SECONDS) <= 0) return false;

	g_bSiHudAutoShownRound = true;
	if (SiHudDebug != null && SiHudDebug.BoolValue)
		LogMessage("[SV sihud] 生还者首次离开安全区：对所有能看面板的玩家强制显示 %.1f 秒。", SIHUD_FORCE_SECONDS);
	return true;
}

// ------------------------------------------------------------------------
// C''：离开安全区的 1 秒兜底轮询（Timer_SiHudRefresh 里调）
//   那两个游戏事件会误发、还会被准备阶段整个挡掉；这里每秒复核一次"事件报过 + 确实有人
//   离开安全区 + 本回合还没真正强制显示过"，满足就补一次。准备阶段里 SiHud_TryForceShowAll
//   会自己返回 false，下一拍照样会再试，直到真的显示出去为止。
//   成功一次后 g_bSiHudAutoShownRound 为 true，之后这里只剩几次 bool 判断，不扫实体。
// ------------------------------------------------------------------------
void SiHud_PollForceShow()
{
	if (g_bSiHudAutoShownRound || !g_bSiHudLeftSafeArea) return;
	if (SiHudEnable == null || !SiHudEnable.BoolValue) return;
	if (SiHudForceShow == null || !SiHudForceShow.BoolValue) return;
	if (!SiHud_SurvivorsLeftSafeArea()) return;

	SiHud_TryForceShowAll();
}

// ------------------------------------------------------------------------
// C'：中途加入的非生还者补一次强制显示
//   本回合已经强制显示过之后，新进服的非生还者也享受同样的 2 秒强制显示 ——
//   让"生还者离开安全区 → 非生还者能看到面板"这条语义对中途加入的玩家同样成立。
//   仍然只在按需条件下生效：force_show=1、非准备阶段、非生还者。
// ------------------------------------------------------------------------
void SiHud_OnClientReady(int client)
{
	if (SiHudEnable == null || !SiHudEnable.BoolValue) return;

	/* 2.6.0：中途进服、且已经在非生还者队伍（感染者/旁观/未分队）→ 自动打开面板。
	   旧版这里只在"本回合已经强制显示过"时才补一次 2 秒强制显示，玩家进队后
	   面板再也不会出现（用户反馈的"新玩家进入感染者队伍不会自动开启面板"）。 */
	SiHud_AutoOpen(client, "中途进服");

	if (!g_bSiHudAutoShownRound) return;							// 还没到首次离开安全区
	if (SiHudForceShow == null || !SiHudForceShow.BoolValue) return;
	if (!SiHud_CanSeePanel(client)) return;						// B：生还者/机器人永远不显示
	if (SiHud_ReadyUpActive()) return;								// 准备阶段不抢屏幕

	SiHud_ForceShowStart(client, SIHUD_FORCE_SECONDS);
	SiHud_DrawFrame(true);
	if (SiHudDebug != null && SiHudDebug.BoolValue)
		LogMessage("[SV sihud] client=%d 中途进服，补一次 %.1f 秒强制显示。", client, SIHUD_FORCE_SECONDS);
}

// ------------------------------------------------------------------------
// 画一帧面板并发送（常规 1 秒刷新）
// ------------------------------------------------------------------------
void SiHud_UpdatePanel()
{
	SiHud_DrawFrame(false);
}

// ------------------------------------------------------------------------
// 画一帧并发送
//   bForce=false：常规路径，只发给"自己开着面板"的玩家，遇到别的插件的菜单不抢；
//   bForce=true ：强制显示路径，只发给"强制窗口内"的玩家，无视玩家开关、也无视坦克让位窗口
//                 （需求：离开安全区 / 坦克事件时连续 2 秒一直显示）。
// ------------------------------------------------------------------------
void SiHud_DrawFrame(bool bForce)
{
	if (SiHudEnable == null || !SiHudEnable.BoolValue) return;
	// 准备阶段（readyup / 门锁面板在场）不重画：那些面板是"主界面"，抢过来只会闪屏。
	// 开关状态照旧保留，准备结束（或生还者离开安全区）后再显示。
	if (SiHud_ReadyUpActive()) return;

	int clients[MAXPLAYERS + 1], count = 0;
	float now = GetGameTime();
	for (int client = 1; client <= MaxClients; client++)
	{
		bool bForced = SiHud_IsForced(client, now);
		if (bForce)
		{
			if (!bForced) continue;			// 强制路径只处理窗口内的玩家
		}
		else
		{
			if (!g_bSiHudOn[client]) continue;
			if (bForced) continue;			// 窗口内的由 0.25 秒的强制 timer 负责，别重复发
		}

		if (!IsClientInGame(client) || IsFakeClient(client))
		{
			SiHud_ResetClient(client);
			continue;
		}
		// B：生还者永远不显示；有人转成生还者时就地关掉（强制窗口一起作废）
		if (GetClientTeam(client) == TEAM_SURVIVOR)
		{
			g_bSiHudOn[client] = false;
			g_bSiHudSent[client] = false;
			g_fSiHudForceUntil[client] = 0.0;
			continue;
		}
		// D：坦克玩家的让位窗口内不显示（那 2 秒强制显示不受这里限制）
		if (!bForced && SiHud_IsTankLocked(client)) continue;
		clients[count++] = client;
	}
	if (!count) return;

	Panel panel = new Panel();
	panel.SetTitle(SIHUD_TITLE);
	SiHud_DrawSurvivorSection(panel);
	SiHud_DrawInfectedSection(panel);

	for (int i = 0; i < count; i++)
	{
		int client = clients[i];
		bool bForced = SiHud_IsForced(client, now);
		MenuSource source = GetClientMenu(client);

		// 外部菜单（SourceTV 等），连强制显示也不抢
		if (source == MenuSource_External) continue;

		if (!bForced)
		{
			// 显示时长（3 秒）比刷新间隔（1 秒）长，所以"屏幕上的面板是我们自己上一块"是常态：
			// 这种情况允许覆盖重发，否则永远收不到刷新；别的菜单在显示时一律不抢。
			bool ours = g_bSiHudSent[client] && (now - g_fSiHudLastSendAt[client]) < float(SIHUD_PANEL_SECONDS);
			if ((source == MenuSource_Normal || source == MenuSource_RawPanel) && !ours)
				continue;					// 别的插件的面板 / 内置投票还在显示，别抢

			/* 2.5.22：这里**不再**用"面板提前消失 ⇒ 玩家自己关的"来反推 ESC。
			   SourceMod 的 Panel 收到任何按键（按数字键切武器也算）都会被引擎关掉，
			   按时间差判定必然误判 —— 玩家一按数字键就被当成"玩家自己关了面板"，
			   开关被置关、本回合的自动显示也跟着一起废掉（玩家反馈的问题 3 / 问题 4）。
			   现在按键只让这块窗口提前消失，下一秒刷新会原样重发；要关面板请用 !sihud。 */
		}

		g_bSiHudSent[client] = panel.Send(client, SiHud_DummyHandler, SIHUD_PANEL_SECONDS);
		if (g_bSiHudSent[client]) g_fSiHudLastSendAt[client] = now;
	}
	delete panel;
}

// ------------------------------------------------------------------------
// 面板回调：故意什么都不做（与 readyup / spechud 的 Dummy 回调同一套语义）
//   2.5.22 起不再从回调里判断"玩家把面板关了"：
//     · MenuCancel_Exit / ExitBack —— 按 ESC 与按数字键都落到这里，两者分不开，
//       而玩家按数字键（切武器）是常规操作，不能因此把面板开关置关（问题 3）；
//     · Interrupted / Timeout / Disconnected —— 被别的面板顶掉 / 3 秒显示时长到期，
//       本来就是我们每秒重发的一部分。
//   开关完全交给 !sihud（Cmd_SiHud）；按键只让这块窗口提前消失，下一秒刷新重发。
// ------------------------------------------------------------------------
int SiHud_DummyHandler(Handle menu, MenuAction action, int param1, int param2)
{
	return 0;
}

// ------------------------------------------------------------------------
// 内容：生还者段（提示行 / 持药人数行 / AWP、Scout / 当前路程百分比）
// ------------------------------------------------------------------------
void SiHud_DrawSurvivorSection(Panel panel)
{
	SiHud_DrawText(panel, SIHUD_TXT_HINT);

	int meds, downed, standing, limit;
	SiHud_CollectSurvivorStats(meds, downed, standing, limit);
	char line[128];
	// 需求：单行四个数字 —— 持药人数 / 倒地且总血量>40 的人数 / 未倒地人数 / 生还者数量上限
	FormatEx(line, sizeof(line), "持药人数：%d/%d/%d/%d", meds, downed, standing, limit);
	// 预算不够时退化成只有三个统计数字（上限最重要，它通常在 12v12 下是 12，先丢它）
	if (strlen(line) + 1 > panel.TextRemaining)
		FormatEx(line, sizeof(line), "持药人数：%d/%d/%d", meds, downed, standing);
	SiHud_DrawText(panel, line);

	SiHud_DrawSniperLines(panel);

	int percent;
	if (SiHud_GetFlowPercent(percent))
	{
		FormatEx(line, sizeof(line), "当前路程：%d%%", percent);
		SiHud_DrawText(panel, line);
	}
}

// ------------------------------------------------------------------------
// 生还者统计（口径与需求逐条对应，四个数字都在这一个函数里算，口径要改只改这里）：
//   N = 持药人数：身上有 药/针/包 任一 的生还者人数（三个医疗物品有其一即算 1 个）
//   a = 倒地（m_isIncapacitated=1）且总血量 > 40 的生还者人数
//       （L4D2 里倒地的人血量 = 300 逐步衰减，>40 表示"还没被救死"）
//   b = 未倒地生还者人数（不看血量）
//   c = survivor_limit（12v12 = 12）
// 已阵亡的生还者三项都不算。
// ------------------------------------------------------------------------
void SiHud_CollectSurvivorStats(int &meds, int &downed, int &standing, int &limit)
{
	meds = 0;
	downed = 0;
	standing = 0;
	limit = (L4DSurvivorLimit != null) ? L4DSurvivorLimit.IntValue
		: ((SurvivorLimit != null) ? SurvivorLimit.IntValue : 0);

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || GetClientTeam(client) != TEAM_SURVIVOR) continue;
		if (!IsPlayerAlive(client)) continue;			// 已阵亡的不参与任何一项

		if (SiHud_HasHealingItem(client)) meds++;

		if (GetEntProp(client, Prop_Send, "m_isIncapacitated"))	// 倒地：只算 a，不算 b
		{
			if (SiHud_RealHealth(client) > SIHUD_SAFE_HEALTH) downed++;
			continue;
		}
		standing++;
	}
}

// 药/针/包：三个医疗武器实体，有其一即算 1 个
bool SiHud_HasHealingItem(int client)
{
	for (int slot = 0; slot <= 5; slot++)
	{
		int weapon = GetPlayerWeaponSlot(client, slot);
		if (weapon <= 0 || !IsValidEdict(weapon)) continue;
		char className[32];
		GetEdictClassname(weapon, className, sizeof(className));
		if (StrEqual(className, "weapon_first_aid_kit", false)
			|| StrEqual(className, "weapon_pain_pills", false)
			|| StrEqual(className, "weapon_adrenaline", false))
			return true;
	}
	return false;
}

// 真实血量（"总血量"）= 永久血 + 当前有效的临时血。
// m_healthBuffer 是临时血缓冲的**起始值**，会按 pain_pills_decay_rate 随时间衰减，
// 所以直接加 m_healthBuffer 会在药品刚过期时高估。这里按插件原有 GetClientRealHealth
// 的同一套衰减算法取"现在这一刻"的临时血，和玩家自己屏幕上看到的总血量一致。
// 若要改成严格的 GetClientHealth + m_healthBuffer（不衰减），只改这一处。
int SiHud_RealHealth(int client)
{
	int permanent = GetClientHealth(client);
	float buffer = GetEntPropFloat(client, Prop_Send, "m_healthBuffer");
	float tempHealth = 0.0;

	if (buffer > 0.0)
	{
		float decay = (PainPillsDR != null) ? PainPillsDR.FloatValue : 0.0;
		if (decay > 0.0)
		{
			float difference = GetGameTime() - GetEntPropFloat(client, Prop_Send, "m_healthBufferTime");
			tempHealth = buffer - (difference / (1.0 / decay));
		}
		else
		{
			tempHealth = buffer;		// 拿不到衰减率时退回不衰减
		}
	}
	if (tempHealth < 0.0) tempHealth = 0.0;

	return permanent + RoundToFloor(tempHealth);
}

// AWP / Scout：只显示当前持有者的「名字前两字符+* / 角色名」，没人持有就不画这一行
void SiHud_DrawSniperLines(Panel panel)
{
	int awp = 0;
	int scout = 0;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || GetClientTeam(client) != TEAM_SURVIVOR) continue;
		if (!IsPlayerAlive(client)) continue;
		int weapon = GetPlayerWeaponSlot(client, 0);
		if (weapon <= 0 || !IsValidEdict(weapon)) continue;
		char className[32];
		GetEdictClassname(weapon, className, sizeof(className));
		if (StrEqual(className, SIHUD_WPN_AWP, false)) awp = client;
		else if (StrEqual(className, SIHUD_WPN_SCOUT, false)) scout = client;
	}
	if (awp > 0) SiHud_DrawSniperLine(panel, "AWP", awp);
	if (scout > 0) SiHud_DrawSniperLine(panel, "Scout", scout);
}

void SiHud_DrawSniperLine(Panel panel, const char[] label, int client)
{
	char shortName[32], character[32], line[96];
	SiHud_ShortName(client, shortName, sizeof(shortName));
	SiHud_CharacterName(client, character, sizeof(character));
	FormatEx(line, sizeof(line), "%s：%s/%s", label, shortName, character);
	SiHud_DrawText(panel, line);
}

// 玩家名只显示前两个字符；多于两个字符时第三位起整体缩成一个 '*'（正好两个字符不加 *）。
// 若要改成"被省掉的每个字符各一个 *"，只改这里的 out[written++] = '*' 那一行。
void SiHud_ShortName(int client, char[] out, int maxlen)
{
	out[0] = '\0';
	char name[MAX_NAME_LENGTH];
	SiHud_GetFixedName(client, name, sizeof(name));

	int length = strlen(name);
	int pos = 0;
	int chars = 0;
	int written = 0;
	while (pos < length && chars < SIHUD_NAME_CHARS && written + 4 < maxlen)
	{
		int bytes = GetCharBytes(name[pos]);
		if (bytes < 1 || pos + bytes > length) break;
		for (int i = 0; i < bytes; i++) out[written++] = name[pos + i];
		pos += bytes;
		chars++;
	}
	if (pos < length && written + 1 < maxlen) out[written++] = '*';
	out[written] = '\0';
}

void SiHud_CharacterName(int client, char[] out, int maxlen)
{
	out[0] = '\0';
	int character = GetEntProp(client, Prop_Send, "m_survivorCharacter");
	if (character < 0 || character >= sizeof(SiHudCharacterNames)) return;
	strcopy(out, maxlen, SiHudCharacterNames[character]);
}

// ------------------------------------------------------------------------
// 当前路程百分比：最远生还者 flow / 全图最大 flow × 100
//   首选 L4D2Direct_GetFlowDistance（配合 L4D_GetHighestFlowSurvivor），
//   退路 L4D2_GetFurthestSurvivorFlow；两者都不可用就不画这一行。
// ------------------------------------------------------------------------
bool SiHud_GetFlowPercent(int &percent)
{
	percent = 0;
	if (!g_bSiHudMaxFlowNative) return false;

	float maxFlow = L4D2Direct_GetMapMaxFlowDistance();
	if (maxFlow <= 0.0) return false;

	float flow;
	if (!SiHud_GetFurthestFlow(flow)) return false;

	percent = RoundToNearest(flow / maxFlow * 100.0);
	if (percent < 0) percent = 0;
	else if (percent > 100) percent = 100;
	return true;
}

// 最远生还者的 flow：客户端 flow 优先，退到 Director 的 furthest flow
bool SiHud_GetFurthestFlow(float &flow)
{
	flow = 0.0;
	if (g_bSiHudClientFlowNative && g_bSiHudHighestNative)
	{
		int furthest = L4D_GetHighestFlowSurvivor();
		if (furthest > 0) flow = L4D2Direct_GetFlowDistance(furthest);
	}
	if (flow <= 0.0 && g_bSiHudFurthestFlowNative) flow = L4D2_GetFurthestSurvivorFlow();
	return flow > 0.0;
}

// ------------------------------------------------------------------------
// 内容：感染者段（感染者人数行 / 六行职业统计 / 最后两行 坦克、女巫）
// ------------------------------------------------------------------------
void SiHud_DrawInfectedSection(Panel panel)
{
	// 需求：`感染者：<当前感染者玩家数>/<infected_limit>`（上限实时读 ConVar，不硬编码 12）
	// 本插件的 l4d_infected_limit 会实时同步到 z_max_player_zombies，这里优先读后者
	// （它就是引擎自己的"感染者玩家上限"），读不到再退回本插件自己的 ConVar。
	int infectedLimit = (L4DInfectedLimit != null) ? L4DInfectedLimit.IntValue
		: ((InfectedLimit != null) ? InfectedLimit.IntValue : 0);
	char line[64];
	FormatEx(line, sizeof(line), "感染者：%d/%d", GetTeamPlayers(TEAM_INFECTED, false), infectedLimit);
	SiHud_DrawText(panel, line);

	SiHud_DrawClassLines(panel);
	SiHud_DrawBossLines(panel);
}

// ------------------------------------------------------------------------
// 面板最下面两行：坦克 / 女巫（需求：风格与游戏顶部 HUD 一致）
//   `坦克: 34%`  本回合坦克按 flow 刷出、还没刷 → 显示它会在哪一段路程刷出
//                （百分比口径与 spechud_appledmod / l4d2_scripted_hud 的顶部 HUD 完全一致，
//                 取数见 SiHud_GetBossLine）；
//   `坦克: 固定` 本回合坦克不是按 flow 刷的（静态 / 事件刷出）；
//   **本回合已经刷出过就整行不画**（活着、死了都一样 —— 需求原文），女巫完全同理。
//   拿不到 Left4DHooks 的 boss flow 数据时也整行不画，不拿 info_zombie_spawn 的采样冒充。
// ------------------------------------------------------------------------
// 一行 boss 的取值结果
enum
{
	SiHudBossLine_Hidden = 0,	// 这一行不画
	SiHudBossLine_Percent,		// 画百分比：`坦克: 34%`
	SiHudBossLine_Fixed			// 画"固定"：`坦克: 固定`
};

// ------------------------------------------------------------------------
// 面板最下面两行：坦克 / 女巫
//   坦克行（2.6.1 按需求重做，格式 `坦克1:4000 (1控/35%)`）：
//     · **有坦克活着**：每只坦克各一行 —— 序号（坦克1/坦克2/坦克3）+ 具体血量 + 「控数/怒气」；
//       **不显示玩家名称**（2.6.0 的"前两个字符 + *"按需求去掉）；
//       控数 = 这条坦克命里该玩家第几段完整控制权（1控/2控，AI 坦克写 AI），
//       按"坦克 + SteamID"记，所以多坦克同时在场、玩家换槽位/掉线重连都不会串；
//     · **没有坦克活着**：沿用旧口径 —— 本回合坦克按 flow 刷出、还没刷 → `坦克: 34%`；
//       不是按 flow 刷的（静态 / 事件刷出）→ `坦克: 固定`；本回合已经刷出过（活着/死了）就整行不画。
//   女巫行不变。
// ------------------------------------------------------------------------
void SiHud_DrawBossLines(Panel panel)
{
	char line[64];
	int percent = 0;

	SiHud_DrawTankLines(panel);

	int witchLine = SiHud_GetBossLine(false, percent);
	if (witchLine == SiHudBossLine_Percent)
	{
		FormatEx(line, sizeof(line), "女巫: %d%%", percent);
		SiHud_DrawText(panel, line);
	}
	else if (witchLine == SiHudBossLine_Fixed)
	{
		FormatEx(line, sizeof(line), "女巫: %s", SIHUD_TXT_WITCH_FIXED);
		SiHud_DrawText(panel, line);
	}
}

// ------------------------------------------------------------------------
// 坦克行（2.6.1：`坦克1:4000 (1控/35%)`）
//   多坦克同时存活时一只一行，最多 SIHUD_MAX_TANK_LINES 行（面板 511 字节预算有限，
//   12v12 里同时 3 只以上坦克的场合极少；超出的用一行"还有 N 只"提示，不会静默丢掉）。
//   血量不显示上限、不显示玩家名称，一行最多约 24 字节，3 行也远在预算内。
// ------------------------------------------------------------------------
void SiHud_DrawTankLines(Panel panel)
{
	char line[64];
	int tanks[SIHUD_MAX_TANK_LINES];
	int shown = 0;
	int total = 0;

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || !IsPlayerAlive(client)) continue;
		if (GetSiType(client) != ZC_TANK) continue;
		total++;
		if (shown < SIHUD_MAX_TANK_LINES) tanks[shown++] = client;
	}

	if (total == 0)
	{
		// 没有坦克活着：沿用旧口径（下一次坦克会在哪刷 / 固定），刷出过就整行不画
		int percent = 0;
		int tankLine = SiHud_GetBossLine(true, percent);
		if (tankLine == SiHudBossLine_Percent)
		{
			FormatEx(line, sizeof(line), "坦克: %d%%", percent);
			SiHud_DrawText(panel, line);
		}
		else if (tankLine == SiHudBossLine_Fixed)
		{
			FormatEx(line, sizeof(line), "坦克: %s", SIHUD_TXT_TANK_FIXED);
			SiHud_DrawText(panel, line);
		}
		return;
	}

	// 2.6.1 坦克行：`坦克1:4000 (1控/35%)`
	//   · 序号 坦克1/坦克2/坦克3 = 行序（多坦克同时存活时逐只一行）；
	//   · 不显示玩家名称（原 2.6.0 的"前两个字符 + *"按需求去掉，SiHud_TankDisplayName 一并删除）；
	//   · 血量 = 具体血量，不显示上限；
	//   · 括号里 = 控数/怒气：控数取 SiHud_TankSegmentOf（1控/2控，AI 坦克写 AI），
	//     怒气取 m_frustration 百分比，与 spechud 的 tankhud `怒气: %d%%` 完全同一取法；
	//     AI 坦克和 spechud 一样不报数字（那边是"怒气: 电脑"），这里写 `坦克1:4000 (AI/电脑)`。
	char control[16];
	char rage[16];
	for (int i = 0; i < shown; i++)
	{
		int tank = tanks[i];
		SiHud_TankControlText(tank, control, sizeof(control));

		int ragePercent = SiHud_TankFrustrationPercent(tank);
		if (ragePercent < 0) strcopy(rage, sizeof(rage), SIHUD_TXT_TANK_AI_PC);
		else FormatEx(rage, sizeof(rage), "%d%%", ragePercent);

		FormatEx(line, sizeof(line), "坦克%d:%d (%s/%s)",
			i + 1, SiHud_TankHealth(tank), control, rage);
		SiHud_DrawText(panel, line);
	}

	if (total > shown)
	{
		FormatEx(line, sizeof(line), "坦克: 还有 %d 只（只显示前 %d 只）", total - shown, shown);
		SiHud_DrawText(panel, line);
	}
}

// 坦克的具体血量（需求：显示血量而不是百分比，不显示上限）。
//   只读 GetClientHealth；取不到（-1 / 已死亡）按 0 处理，绝不显示负数。
int SiHud_TankHealth(int tank)
{
	if (tank <= 0 || tank > MaxClients) return 0;
	if (!IsClientInGame(tank)) return 0;

	int health = GetClientHealth(tank);
	if (health < 0) health = 0;
	return health;
}

// 坦克的"控制权/怒气"百分比（需求：一控二控后面补上具体控制权，参考 spechud 的 tankhud）：
//   与 spechud_appledmod.sp 的坦克HUD 完全同一取法（那里是 `FormatEx(info, ..., "怒气: %d%%",
//   GetTankFrustration(tank))`）——GetTankFrustration 是 l4d2util_tanks.inc 的 stock：
//   100 - m_frustration，也就是屏幕上显示的怒气百分比（怒气越高 = 控制权剩得越少）。
//   左右两块 HUD 的数字因此一致，玩家不会看到两个不同的数。
//   本插件只 include <left4dhooks>，没有引 l4d2util，所以这里按同一公式直接算，不额外加依赖。
//   ★AI 坦克与 spechud 一样不报数字（那边显示"怒气: 电脑"），返回 -1 让调用方写"电脑"。
int SiHud_TankFrustrationPercent(int tank)
{
	if (tank <= 0 || tank > MaxClients) return -1;
	if (!IsClientInGame(tank)) return -1;
	if (IsFakeClient(tank)) return -1;		// AI 坦克：怒气是引擎替身，报数字没有意义

	int frustration = GetEntProp(tank, Prop_Send, "m_frustration");
	if (frustration < 0) frustration = 0;
	else if (frustration > 100) frustration = 100;

	return 100 - frustration;
}

// 这只坦克是"一控"还是"二控"：
//   2.6.1 起按"坦克这条命 + 玩家 SteamID"记（SiHud_TankSegmentOf，见文件头 E 段）——
//   本服"二控"= 同一名玩家在控制权被消耗之后又拿回同一辆坦克；
//   AI 坦克没有"几控"，这一格写 AI（与 spechud 的"控制: 电脑"同义）。
void SiHud_TankControlText(int tank, char[] out, int maxlen)
{
	out[0] = '\0';
	if (tank <= 0 || tank > MaxClients) return;
	if (IsFakeClient(tank))
	{
		strcopy(out, maxlen, SIHUD_TXT_TANK_AI);
		return;
	}

	int count = SiHud_TankSegmentOf(tank);
	if (count < 1) count = 1;
	strcopy(out, maxlen, (count >= 2) ? SIHUD_TXT_TANK_CTRL_SECOND : SIHUD_TXT_TANK_CTRL_FIRST);
}

// ------------------------------------------------------------------------
// 坦克 / 女巫行的取值（bTank 区分两者），返回 SiHudBossLine_*
//   数据源与顶部 HUD 一致（spechud_appledmod 的 GetRoundTankFlow / GetRoundWitchFlow、
//   l4d2_scripted_hud 的 GetTankFlow / GetWitchFlow）：
//     · L4D2Direct_GetVSTankFlowPercent(round) 是 0..1 的 flow percent 小数
//       （个别 left4dhooks 版本也可能直接给 0..100，这里统一归一化），×100 得到百分比；
//     · 再加上 versus_boss_buffer / 全图最大 flow 的余量 —— boss 实际会在稍晚一点的位置刷出；
//     · round 0 = 上半场，1 = 下半场（GameRules 的 m_bInSecondHalfOfRound，非对抗按 0 处理）。
//   本回合这个 boss 不是按 flow 刷出的（静态 / 事件）→ SiHudBossLine_Fixed，与顶部 HUD 的"固定"同义。
// ------------------------------------------------------------------------
int SiHud_GetBossLine(bool bTank, int &percent)
{
	percent = 0;

	// 本回合已经刷出过（活着 / 死了都算）→ 整行不画（需求）
	if (bTank ? g_bSiHudTankSpawned : g_bSiHudWitchSpawned) return SiHudBossLine_Hidden;

	// 下面几个 native 读的是对抗 Director 的 boss flow 数据：拿不到就别瞎猜
	if (!g_bSiHudBossFlowNative) return SiHudBossLine_Hidden;
	if (!L4D_IsVersusMode()) return SiHudBossLine_Hidden;

	int round = SiHud_IsSecondHalf() ? 1 : 0;
	bool bFlowBoss = bTank ? L4D2Direct_GetVSTankToSpawnThisRound(round)
		: L4D2Direct_GetVSWitchToSpawnThisRound(round);
	if (!bFlowBoss) return SiHudBossLine_Fixed;

	float fraction = bTank ? L4D2Direct_GetVSTankFlowPercent(round)
		: L4D2Direct_GetVSWitchFlowPercent(round);

	/* 与顶部 HUD（spechud_appledmod 的 GetRoundTankFlow/GetRoundWitchFlow）**完全同口径**：
	   该 native 读的是引擎的 m_fTankSpawnFlowPercent，给的是 0..100 的百分比，不是 0..1 的
	   flow 比例；顶部 HUD 的算法是 `RoundToNearest(native + versus_boss_buffer/maxFlow)`，
	   余量是直接加在"百分点"上的。旧写法先除 100、加完比例再乘 100，会把余量放大 100 倍
	   （差 1~2 个百分点），画面上下两个 HUD 的数字就对不上了。 */
	if (fraction > 0.0 && fraction < 1.0)	// 个别 left4dhooks 版本给 0..1 的小数：兼容一下
		fraction *= 100.0;

	float maxFlow = L4D2Direct_GetMapMaxFlowDistance();
	float buffer = (VersusBossBuffer != null) ? VersusBossBuffer.FloatValue : 0.0;
	if (maxFlow > 0.0) fraction += buffer / maxFlow;

	percent = RoundToNearest(fraction);
	if (percent < 0) percent = 0;
	else if (percent > 100) percent = 100;
	return SiHudBossLine_Percent;
}

// 当前是不是本图的第二回合（上下半场），与 l4d2util_rounds 的 InSecondHalfOfRound 同一取法；
// 非对抗模式没有上下半场之分，统一按第一回合（round 0）算。
bool SiHud_IsSecondHalf()
{
	if (!L4D_IsVersusMode()) return false;
	return GameRules_GetProp("m_bInSecondHalfOfRound") != 0;
}

// 六行：`特感英文名:非灵魂未死亡数/灵魂状态数/该特感上限`
//   非灵魂未死亡 = team 3 且 m_zombieClass 匹配 且 m_isGhost=0 且活着
//   灵魂状态     = m_isGhost=1（幽灵状态的等待重生体）
//   上限         = 实时读 z_versus_<class>_limit
void SiHud_DrawClassLines(Panel panel)
{
	int normal[6];
	int ghost[6];
	int limits[6];
	for (int i = 0; i < 6; i++)
	{
		normal[i] = 0;
		ghost[i] = 0;
		limits[i] = SiHud_ClassLimit(i + ZC_SMOKER);
	}

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || GetClientTeam(client) != TEAM_INFECTED) continue;
		int siClass = GetSiType(client);
		if (siClass < ZC_SMOKER || siClass > ZC_CHARGER) continue;
		int index = siClass - ZC_SMOKER;
		if (GetEntProp(client, Prop_Send, "m_isGhost"))
		{
			ghost[index]++;
			continue;
		}
		if (!IsPlayerAlive(client)) continue;		// 非灵魂但已死亡：两个数都不算
		normal[index]++;
	}

	char line[64];
	for (int i = 0; i < 6; i++)
	{
		FormatEx(line, sizeof(line), "%s:%d/%d/%d", SiHudClassNames[i], normal[i], ghost[i], limits[i]);
		SiHud_DrawText(panel, line);
	}
}

// 单类上限：12v12 加载了 optional/l4d2_nospitterduringtank.smx，坦克在场时它会把
// z_versus_spitter_limit 置 0、坦克结束后恢复，所以这里实时读 cvar 就自动显示 0，
// 不需要再对 spitter 做坦克特判。读不到 cvar 时兜底 0 并只记一次日志。
int SiHud_ClassLimit(int siClass)
{
	if (siClass < ZC_SMOKER || siClass > ZC_CHARGER) return 0;
	ConVar limit = FindConVar(L4D2_limits[siClass]);
	if (limit == null)
	{
		if (!g_bSiHudLimitMissLogged[siClass])
		{
			g_bSiHudLimitMissLogged[siClass] = true;
			LogError("[SV sihud] 找不到 cvar %s，该特感上限按 0 显示。", L4D2_limits[siClass]);
		}
		return 0;
	}
	return limit.IntValue;
}

// ------------------------------------------------------------------------
// 2.5.22：这里原来是"刷新点1 / 刷新点2"两行（扫描 info_zombie_spawn，再用
// L4D_GetNearestNavArea / L4D2Direct_GetTerrorNavAreaFlow 把点换成 flow 百分比）。
// 需求把这两行换成了"坦克 / 女巫"两行（见 SiHud_DrawBossLines），整段采样随之删除：
//   · 顶部 HUD 的 boss 位置来自 Versus Director 的 boss flow percent，那才是 boss 真正
//     刷出的位置；info_zombie_spawn 只是地图上的刷怪候选点，两者不是一回事，口径也对不上；
//   · 留着不用等于每次换图白扫一遍实体（还带一份 nav native 可用性判断）。
// 以后真需要"最近的刷怪点"再从这个函数的 git 历史取回。
// ------------------------------------------------------------------------

// ------------------------------------------------------------------------
// 工具函数
// ------------------------------------------------------------------------
// 一行文本：先算剩余预算，再按 UTF-8 字符边界裁剪；预算用完就整行不画。
// （Panel 自己也会静默截断，但那是按字节切的，会把中文切成半个字。）
void SiHud_DrawText(Panel panel, const char[] text)
{
	int remaining = panel.TextRemaining - 1;	// 留 1 字节给换行
	if (remaining <= 0) return;
	int limit = (remaining < SIHUD_TEXT_BUDGET) ? remaining : SIHUD_TEXT_BUDGET;
	char line[SIHUD_TEXT_BUDGET + 2];
	SiHud_CopyPanelText(text, line, sizeof(line), limit);
	panel.DrawText(line);
}

// 与 readyup panel.inc 的 RU_CopyPanelText 同一套算法：按字符整块拷贝，
// 放不下时整块丢弃并补一个 '~'，保证不会切出半个 UTF-8 字符。
void SiHud_CopyPanelText(const char[] source, char[] output, int maxlen, int budget)
{
	output[0] = '\0';
	if (budget > maxlen - 1) budget = maxlen - 1;
	if (budget <= 0) return;

	int length = strlen(source);
	bool shortened = length > budget;
	int limit = shortened ? budget - 1 : budget;
	int pos = 0;
	while (pos < length)
	{
		int bytes = GetCharBytes(source[pos]);
		if (bytes < 1 || pos + bytes > length || pos + bytes > limit) break;
		for (int i = 0; i < bytes; i++) output[pos + i] = source[pos + i];
		pos += bytes;
	}
	if (pos < length && pos < budget) output[pos++] = '~';
	output[pos] = '\0';
}

// 去掉名字开头的 '[' 占位（与 readyup player.inc 的 GetClientFixedName 一致）
void SiHud_GetFixedName(int client, char[] name, int length)
{
	GetClientName(client, name, length);
	if (name[0] == '[')
	{
		char temp[MAX_NAME_LENGTH];
		strcopy(temp, sizeof(temp), name);
		temp[sizeof(temp)-2] = 0;
		strcopy(name[1], length-1, temp);
		name[0] = ' ';
	}
}

// 把面板从屏幕上顶掉：Panel 没有"清除"接口，只能发一块新的。
// 用一行内容 + 1 秒显示时长，最短时间内自动消失。
void SiHud_ClosePanel(int client, const char[] note)
{
	if (client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client)) return;
	Panel panel = new Panel();
	panel.DrawText(note);
	panel.Send(client, SiHud_DummyHandler, 1);
	delete panel;
}

bool SiHud_IsTankLocked(int client)
{
	if (client <= 0 || client > MaxClients) return false;
	if (g_fSiHudTankLockUntil[client] <= 0.0) return false;
	if (GetGameTime() < g_fSiHudTankLockUntil[client]) return true;
	g_fSiHudTankLockUntil[client] = 0.0;
	return false;
}

void SiHud_ResetClient(int client)
{
	if (client < 0 || client > MaxClients) return;
	g_bSiHudOn[client] = false;
	g_bSiHudSent[client] = false;
	g_bSiHudUserOff[client] = false;
	SiHud_ResetTankSegment(client);		// 2.6.1：控数按"坦克+SteamID"记，这里清掉该槽位的一份
	g_fSiHudTankLockUntil[client] = 0.0;
	g_fSiHudLastSendAt[client] = 0.0;
	g_fSiHudForceUntil[client] = 0.0;
	g_iSiHudTankPanel[client] = SIHUD_TANKPANEL_NONE;
}

void SiHud_ResetAll()
{
	for (int client = 0; client <= MaxClients; client++) SiHud_ResetClient(client);
}

// 换图：清状态 + 让坦克/女巫缓存失效
void SiHud_ResetMap()
{
	SiHud_ResetAll();
	g_bSiHudAutoShownRound = false;
	g_bSiHudLeftSafeArea = false;
	g_hSiHudForceTimer = null;			// 强制 timer 带 TIMER_FLAG_NO_MAPCHANGE，换图时已被回收
	SiHud_ResetBossState();
	for (int i = 0; i < sizeof(g_bSiHudLimitMissLogged); i++) g_bSiHudLimitMissLogged[i] = false;
}

// 新回合：坦克让位窗口、强制显示窗口、本回合的自动显示机会一起重置
// （需求：这些"每回合一次"的东西都不跨回合；坦克交接状态同理，新回合的坦克重新算）
void SiHud_ResetRound()
{
	g_bSiHudAutoShownRound = false;
	g_bSiHudLeftSafeArea = false;
	SiHud_ResetBossState();
	for (int client = 0; client <= MaxClients; client++)
	{
		g_fSiHudTankLockUntil[client] = 0.0;
		g_fSiHudForceUntil[client] = 0.0;
		g_bSiHudUserOff[client] = false;	// 新回合：允许再次自动打开面板
		SiHud_ResetTankSegment(client);		// 新回合：控数重新从一开始（一控/二控）
		SiHud_ReleaseTankPanel(client);		// 上回合替坦克自动打开的面板不跨回合
	}
}

// 坦克 / 女巫的"本回合刷出过没有 + 死了没有"状态
void SiHud_ResetBossState()
{
	g_iSiHudTankClient = 0;
	g_iSiHudTankControl = 0;
	g_bSiHudTankSpawned = false;
	g_bSiHudWitchSpawned = false;
	// 2.6.1：控数状态跟着"本回合"一起清（坦克换图/换回合后是一辆新的坦克，从一控重新数）
	for (int client = 0; client <= MaxClients; client++) SiHud_ResetTankSegment(client);
}

// Left4DHooks / 跨插件的 native 默认被标成 optional，
// 必须先探状态再用，否则版本偏旧时会抛 "Native is not bound"。
void SiHud_CheckNatives()
{
	g_bSiHudMaxFlowNative = SiHud_NativeAvailable("L4D2Direct_GetMapMaxFlowDistance");
	g_bSiHudClientFlowNative = SiHud_NativeAvailable("L4D2Direct_GetFlowDistance");
	g_bSiHudHighestNative = SiHud_NativeAvailable("L4D_GetHighestFlowSurvivor");
	g_bSiHudFurthestFlowNative = SiHud_NativeAvailable("L4D2_GetFurthestSurvivorFlow");
	g_bSiHudReadyUpNative = SiHud_NativeAvailable("IsInReady");
	g_bSiHudSafeAreaNative = SiHud_NativeAvailable("L4D_HasAnySurvivorLeftSafeArea");
	// 最后两行"坦克 / 女巫"的出生百分比位置（4 个 native 全在才用，缺一个就不画这一行）
	g_bSiHudBossFlowNative = g_bSiHudMaxFlowNative
		&& SiHud_NativeAvailable("L4D2Direct_GetVSTankFlowPercent")
		&& SiHud_NativeAvailable("L4D2Direct_GetVSWitchFlowPercent")
		&& SiHud_NativeAvailable("L4D2Direct_GetVSTankToSpawnThisRound")
		&& SiHud_NativeAvailable("L4D2Direct_GetVSWitchToSpawnThisRound");
	// spechud_appledmod 的坦克HUD 关闭接口（不在场就关不掉 tankhud，面板其它功能不受影响）
	g_bSiHudSpecHudNative = SiHud_NativeAvailable("SpecHud_TankHudDisable");
	// 2.6.1：一控/二控首选读引擎的传克次数（与 spechud 的 tankhud 同源）；不可用时退回自己的段数跟踪
	g_bSiHudTankPassNative = SiHud_NativeAvailable("L4D2Direct_GetTankPassedCount");

	if (!g_bSiHudMaxFlowNative && SiHudDebug != null && SiHudDebug.BoolValue)
		LogError("[SV sihud] L4D2Direct_GetMapMaxFlowDistance 不可用：当前路程百分比与坦克/女巫两行都不会显示。");
	if (!g_bSiHudSpecHudNative && SiHudDebug != null && SiHudDebug.BoolValue)
		LogError("[SV sihud] 找不到 spechud_appledmod 的 SpecHud_TankHudDisable：坦克刷出/接管时无法关闭 tankhud。");
	if (!g_bSiHudTankPassNative && SiHudDebug != null && SiHudDebug.BoolValue)
		LogError("[SV sihud] L4D2Direct_GetTankPassedCount 不可用：一控/二控退回本插件自己的段数跟踪（可能与 spechud 的 tankhud 不一致）。");
}

// 是否处在 readyup 的准备阶段（readyup 没加载时恒为 false）
bool SiHud_ReadyUpActive()
{
	if (!g_bSiHudReadyUpNative) return false;
	return IsInReady();
}

bool SiHud_NativeAvailable(const char[] name)
{
	return GetFeatureStatus(FeatureType_Native, name) == FeatureStatus_Available;
}

// *********************************************************************************
// INFECTED COUNTER, for Versus / Scavenge
// *********************************************************************************

// ------------------------------------------------------------------------
//  Start counter when a survivor leaves safe area
// ------------------------------------------------------------------------
public void Event_PlayerLeftStartArea(Event event, const char[] name, bool dontBroadcast)
{
	StartInfectedCounter();

	// C：生还者离开安全区域 → 每回合首次离开时给所有能看面板的玩家强制显示 2 秒
	// （之后的同类事件只刷新，见 SiHud_OnSurvivorLeftSafeArea）。
	int leaver = GetClientOfUserId(event.GetInt("userid"));
	if (leaver > 0 && IsClientInGame(leaver) && GetClientTeam(leaver) == TEAM_SURVIVOR)
		SiHud_OnSurvivorLeftSafeArea();

	// 有人离开起点安全区域 = readyup/doorlock 已经解禁、可以自由入队。
	// 这个事件每名生还者都会触发一次，所以只用第一次（每回合一次）。
	if (!g_bAutofillDoorDone)
	{
		g_bAutofillDoorDone = true;
		QueueAutofill();
	}
}

// ------------------------------------------------------------------------
// 2.5.15：闲置（挂机托管 / 加载中就被占了席位）玩家 → 旁观
//
// 引擎的"闲置"= 一名玩家的身份挂在一具生还者 bot 身体上（bot 的
// m_humanSpectatorUserID 指向他），角色头顶因此显示"闲置：玩家名"，身体由 AI 顶着。
// 来源有三类：
//   ① 玩家自己按闲置键；
//   ② 接管流程里 L4D_SetHumanSpec 之后没接管成功（伪闲置，玩家会卡在
//      "点击加入游戏点不动"的半旁观状态）；
//   ③ 加载慢 / 刚进服的玩家：引擎先把一具生还者 bot 预留给他，人还在加载，
//      席位却被这具"闲置：名字"的身体占着 —— 这种情况同样要清掉，别占位置。
// 玩家要求：上述三种一律转到旁观（2.5.18 起不再对③做"慢加载保护"）。
//
//   l4d_superversus_idle_to_spec = 1（默认）：清掉托管链接，头顶"闲置：名字"消失，
//       身体交回 AI 正常行动（生还者席位不再被"闲置"标记占着）；
//       玩家本人保持/转为旁观，用 !jg 可以重新加入。
//   = 2：清链接后把身体整只移出生还者队并回收（与 ReconcileSurvivors 清理多余 bot 同款），
//       队伍随后按最低人数补一个新的普通 AI。
//   = 0：关闭。
// 唯一让路：玩家正在插件自己的入队流程里（JoinPending + JoinTimer），抢了会打架。
// 只处理"身体还活着"的情况；身体已死亡时由 Event_PlayerDeath -> TakeOver 把人叫回身体。
// ------------------------------------------------------------------------

public Action Timer_IdleToSpec(Handle timer)
{
	int iMode = IdleToSpec.IntValue;
	if (iMode <= 0)
		return Plugin_Continue;

	if (!SurvivorMapReady || !RoundStarted || !IsServerProcessing())
		return Plugin_Continue;

	// 队伍修正插件正在锁队还原队伍时不动，避免和它抢换队
	if (TeamChangesLocked())
		return Plugin_Continue;

	float fNow = GetGameTime();
	float fDelay = IdleToSpecDelay.FloatValue;

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsValidClient(client) || IsFakeClient(client))
		{
			g_fIdleSince[client] = 0.0;
			continue;
		}

		// 刚释放过：引擎若又把托管链接挂回来，5 秒内不再抢（避免和引擎来回打架）
		if (g_fIdleReleasedAt[client] > 0.0 && fNow - g_fIdleReleasedAt[client] < 5.0)
		{
			g_fIdleSince[client] = 0.0;
			continue;
		}

		/* 只要"玩家的身体还挂在场上、人却不在操作"，一律按闲置处理，立刻让出位置：
		   包括①自己按了闲置键；②接管失败留下的伪闲置；③加载慢/刚进服时引擎先给他
		   预留一具生还者 bot 身体（人还在加载，席位却被这具"闲置：名字"的身体占着）。
		   用户明确要求：这种占位的人直接放旁观，不要保护。
		   唯一让路的情况：他正处在入队流程里（JoinPending + JoinTimer），
		   那是插件自己在做接管，抢了会打架。 */
		int bot = GetBotOfIdle(client);

		if (bot <= 0)
		{
			g_fIdleSince[client] = 0.0;
			continue;
		}

		// 正在入队流程里的不动：接管瞬间会短暂出现托管链接，交给流程自己收尾
		if (JoinPending[client] && JoinTimer[client] != null)
		{
			g_fIdleSince[client] = 0.0;
			continue;
		}

		// 身体已死亡：交给 Event_PlayerDeath -> TakeOver 处理
		if (!IsPlayerAlive(bot))
		{
			g_fIdleSince[client] = 0.0;
			continue;
		}

		if (g_fIdleSince[client] <= 0.0)
		{
			g_fIdleSince[client] = fNow;
			continue;
		}

		if (fNow - g_fIdleSince[client] < fDelay)
			continue;

		g_fIdleSince[client] = 0.0;

		if (iMode >= 2)
			ReleaseIdleBody(client, bot);
		else
			ClearIdleLink(bot, client);

		g_fIdleReleasedAt[client] = fNow;

		// 玩家本人确认为旁观（正常闲置本来就在旁观队，只有异常/伪闲置才会被改队）
		if (IsClientInGame(client) && GetClientTeam(client) != TEAM_SPECTATOR)
		{
			ChangeClientTeam(client, TEAM_SPECTATOR);

			// 伪闲置会在玩家身上残留 m_iObserverMode = 5（跟随观察），
			// 那正是"点击加入游戏点不动"的元凶；只在残留时清回 0。
			if (IsClientInGame(client) && GetClientTeam(client) == TEAM_SPECTATOR
				&& GetEntProp(client, Prop_Send, "m_iObserverMode") == 5)
				SetEntProp(client, Prop_Send, "m_iObserverMode", 0);
		}

		// 提示带 30 秒冷却：引擎如果反复把链接挂回来，不会刷玩家的屏
		if (g_fIdleNoticeAt[client] <= 0.0 || fNow - g_fIdleNoticeAt[client] >= 30.0)
		{
			g_fIdleNoticeAt[client] = fNow;
			PrintToChat(client, "\x03[SV] \x01你处于闲置(挂机托管)状态，已转为旁观；输入 !jg 可以重新加入游戏。");
		}
	}

	return Plugin_Continue;
}

// 清掉"bot 身体被 client 托管"的链接复用本插件已有的 ClearIdleLink(bot, client)
// （见文件末尾"接管"一节；那段注释已说明：对抗里没有主动闲置键，链接一旦残留就只能是 bug）。

// mode 2：清链接后把闲置身体移出生还者队并回收，再让补位逻辑补一个新的普通 AI
void ReleaseIdleBody(int client, int bot)
{
	ClearIdleLink(bot, client);

	if (bot <= 0 || bot > MaxClients || !IsClientInGame(bot))
		return;

	if (!IsFakeClient(bot) || GetClientTeam(bot) != TEAM_SURVIVOR)
		return;

	if (IsClientInKickQueue(bot))
		return;

	ChangeClientTeam(bot, TEAM_SPECTATOR);
	KickClient(bot, "Idle takeover released");

	// 尽快补一个新 bot；延迟一点点，让引擎先处理掉这次 kick
	delete BotsUpdateTimer;
	BotsUpdateTimer = CreateTimer(0.6, Timer_BotsUpdate, _, TIMER_FLAG_NO_MAPCHANGE);
}

// sm_svidle：把"闲置 → 旁观"的判定条件全部摊开。
// 线上排查用：谁现在挂着托管身体、会不会被转旁观，一眼就能看出来。
public Action Cmd_IdleStatus(int client, int args)
{
	float fNow = GetGameTime();

	ReplyToCommand(client, "[SV] 闲置转旁观: 模式=%d 持续闲置=%.1fs 释放防抖=5s | 现在 %.1f",
		IdleToSpec.IntValue, IdleToSpecDelay.FloatValue, fNow);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsValidClient(i) || IsFakeClient(i))
			continue;

		int bot = GetBotOfIdle(i);
		float fInGame = (g_fInGameSince[i] > 0.0) ? (fNow - g_fInGameSince[i]) : -1.0;
		float fIdle = (g_fIdleSince[i] > 0.0) ? (fNow - g_fIdleSince[i]) : -1.0;
		float fReleased = (g_fIdleReleasedAt[i] > 0.0) ? (fNow - g_fIdleReleasedAt[i]) : -1.0;

		ReplyToCommand(client,
			"[SV] #%d %N | 队=%d 进服=%.0fs 新连接=%d 入队中=%d | 托管身体=#%d 持续闲置=%.1fs 上次释放=%.1fs",
			i, i, GetClientTeam(i), fInGame,
			NewConnection[i] ? 1 : 0,
			(JoinPending[i] && JoinTimer[i] != null) ? 1 : 0,
			bot, fIdle, fReleased);
	}

	return Plugin_Handled;
}

// 2.5.17：清掉真人身上残留的生还者武器。
// 竞态来源（实测链路）：引擎把新连接先放进生还者队并让他活着（自带手枪，安全区还能捡枪），
// 1 秒后平衡器才按人数把他换到感染者；ChangeClientTeam 不会回收武器，
// 于是出现"人已经在特感队、身上却带着枪"。换到感染者时统一清一遍即可。
// 只处理生还者武器实体（weapon_*），技能/其它实体一概不碰。
void StripSurvivorWeapons(int client)
{
	if (!StripInfWeapons.BoolValue)
		return;

	if (!IsValidClient(client) || IsFakeClient(client))
		return;

	for (int slot = 0; slot <= 4; slot++)
	{
		int weapon = GetPlayerWeaponSlot(client, slot);
		if (weapon <= 0 || !IsValidEntity(weapon))
			continue;

		char sClass[64];
		GetEntityClassname(weapon, sClass, sizeof(sClass));
		if (StrContains(sClass, "weapon_", false) != 0)
			continue;

		RemovePlayerItem(client, weapon);
		RemoveEntity(weapon);
	}
}

// ------------------------------------------------------------------------
// 自动补位
// ------------------------------------------------------------------------

// 记录旁观起始时刻（player_team 事件）
public void Event_PlayerTeamSpecSince(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client <= 0 || client > MaxClients || !IsClientInGame(client))
		return;

	if (event.GetInt("team") == TEAM_SPECTATOR)
		g_fSpecSince[client] = GetGameTime();
	else
		g_fSpecSince[client] = 0.0;

	/* 2.5.20：身份取不到时的行为兜底。
	   同一玩家 10 秒内被"从可玩队伍搬去旁观"≥4 次，说明"进队 → 被搬走 → 再进队"的拉锯
	   已经开始（AFK 插件强制旁观 + 客户端秒重连就是这种形态）；一旦拉锯成环，实体模型会在
	   hunter.mdl ↔ survivor_*.mdl 之间反复热切换，而 m_nSequence 不随模型复位，最终可能在
	   命中盒测试里让 SlerpBones() 越界崩服。这里直接对本次连接禁用自动入队，从源头掐环。
	   即使 SteamID 没验证成功、IP/名字也对不上，这条兜底依然生效。 */
	if (!IsFakeClient(client) && event.GetInt("team") == TEAM_SPECTATOR)
	{
		int oldTeam = event.GetInt("oldteam");
		if (oldTeam == TEAM_SURVIVOR || oldTeam == TEAM_INFECTED)
		{
			float fNow = GetGameTime();
			if (g_fSpecBounceSince[client] <= 0.0 || fNow - g_fSpecBounceSince[client] > 10.0)
			{
				g_fSpecBounceSince[client] = fNow;
				g_iSpecBounce[client] = 1;
			}
			else
			{
				g_iSpecBounce[client]++;
			}

			if (g_iSpecBounce[client] >= 4 && !g_bChurnNoJoin[client])
			{
				g_bChurnNoJoin[client] = true;
				g_bNoJoinClient[client] = true;
				CancelJoin(client);
				LogMessage("[SV nojoin] %L 在 %.1f 秒内被搬去旁观 %d 次（疑似 AFK/旁观插件与重连拉锯），本次连接已禁用自动入队",
					client, fNow - g_fSpecBounceSince[client], g_iSpecBounce[client]);
			}
		}
	}

	// 2.5.17：换到感染者时清掉身上残留的生还者武器（进服时引擎先给生还者席位、随后被换到特感的竞态）
	if (!IsFakeClient(client) && event.GetInt("team") == TEAM_INFECTED)
		StripSurvivorWeapons(client);

	/* 2.6.0：面板跟随队伍
	   · 换到感染者 -> 自动打开特感辅助面板（新玩家进特感不再需要自己输入 !sihud）；
	   · 换到生还者 -> 面板立刻停掉（规则 B），并清"玩家自己关过"的闩锁，
	     这样他下次回到特感/旁观时仍会按 sm_sihud_auto_open 自动打开。 */
	if (!IsFakeClient(client))
	{
		if (event.GetInt("team") == TEAM_INFECTED)
		{
			SiHud_AutoOpen(client, "进入感染者队伍");
		}
		else if (event.GetInt("team") == TEAM_SURVIVOR)
		{
			if (g_bSiHudOn[client] || SiHud_IsForced(client, GetGameTime()))
				SiHud_SetPanel(client, false, SIHUD_TANKPANEL_DONE);
			g_bSiHudUserOff[client] = false;
		}
	}
}

// 轮询"队伍修复完成"：从"修复进行中"变为"已完成"的那一下触发补位
public Action Timer_AutofillWatch(Handle timer)
{
	if (!Autofill.BoolValue)
	{
		g_bFixWasRunning = TeamChangesLocked();
		return Plugin_Continue;
	}

	bool bRunning = TeamChangesLocked();

	// 从"修复进行中"变为"已完成"的那一下 = 队伍修复完成，触发一次补位
	if (g_bFixWasRunning && !bRunning && !g_bAutofillFixDone)
	{
		g_bAutofillFixDone = true;
		QueueAutofill();
	}

	g_bFixWasRunning = bRunning;
	return Plugin_Continue;
}

// 触发一次补位（两个触发点各自每回合最多一次；延迟执行，避开开门/换队的引擎状态抖动）
void QueueAutofill()
{
	if (!Autofill.BoolValue || g_bAutofillPending)
		return;

	g_bAutofillPending = true;

	float fDelay = AutofillDelay.FloatValue;
	if (fDelay < 0.1)
		fDelay = 0.1;

	CreateTimer(fDelay, Timer_Autofill, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_Autofill(Handle timer)
{
	g_bAutofillPending = false;
	RunAutofill();
	return Plugin_Stop;
}

// 把旁观玩家随机补进队伍：人数 = min(队伍空位, 旁观候选人数)
void RunAutofill()
{
	if (!Management.BoolValue || !RoundStarted || TeamChangesLocked())
		return;

	int aCand[MAXPLAYERS+1];
	int iCount = 0;
	float fNow = GetGameTime();
	float fMinIdle = AutofillMinIdle.FloatValue;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsValidClient(i) || IsFakeClient(i))
			continue;

		if (GetClientTeam(i) != TEAM_SPECTATOR)
			continue;

		// 2.5.20：禁止自动入队的账号（暖服客户端等）永不参与补位
		if (IsNoJoinClient(i))
			continue;

		// 正在入队流程里的不动
		if (NewConnection[i])
			continue;

		// 本回合已阵亡的人不自动拉回生还者队（他们可以自己 !inf 进特感）
		if (HasSurvivorDied(i))
			continue;

		// 旁观时间不够的不动（避免把刚被 AFK 插件转旁观的人立刻拉回来）
		float fSince = g_fSpecSince[i];
		if (fSince > 0.0 && fNow - fSince < fMinIdle)
			continue;

		aCand[iCount++] = i;
	}

	if (iCount <= 0)
		return;

	// 洗牌（Fisher-Yates），再按空位截断
	for (int i = iCount - 1; i > 0; i--)
	{
		int j = GetRandomInt(0, i);
		int iTemp = aCand[i];
		aCand[i] = aCand[j];
		aCand[j] = iTemp;
	}

	int iSurvFree = SurvivorLimit.IntValue - GetTeamPlayers(TEAM_SURVIVOR, false);
	int iInfFree = InfectedLimit.IntValue - GetTeamPlayers(TEAM_INFECTED, false);

	if (iSurvFree < 0)
		iSurvFree = 0;
	if (iInfFree < 0)
		iInfFree = 0;

	int iIdx = 0;

	while (iIdx < iCount && iSurvFree > 0)
	{
		if (TryJoinTeam(aCand[iIdx], TEAM_SURVIVOR, false) == Join_Success)
			iSurvFree--;

		iIdx++;
	}

	if (AutofillInfected.BoolValue)
	{
		while (iIdx < iCount && iInfFree > 0)
		{
			if (TryJoinTeam(aCand[iIdx], TEAM_INFECTED, false) == Join_Success)
				iInfFree--;

			iIdx++;
		}
	}

	if (AutofillDebug.BoolValue)
	{
		LogMessage("[SV autofill] 候选=%d 生还者空位=%d 特感空位=%d 已处理=%d",
			iCount, iSurvFree, iInfFree, iIdx);
	}
}

void StartInfectedCounter()
{
	if(RoundStarted && SvBotsAllowed() && SubDirector == null && InfectedAllowed && AnySurvivorLeftSafeArea())
	{
		SubDirector = CreateTimer(5.0, BotInfectedCounter, true, TIMER_FLAG_NO_MAPCHANGE);
	}
}

// ------------------------------------------------------------------------
//  Counter periodically checks if need to add SI to queue, or spawn extra SI
// ------------------------------------------------------------------------
public Action BotInfectedCounter(Handle timer, bool recheck)
{
	SubDirector = null;

	if (!RoundStarted || (recheck && !AnySurvivorLeftSafeArea())) return Plugin_Stop;
	
	// 空服不养 bot：没有真人时既不排 AI 特感队列，也不补；并把已有的 AI 特感回收掉
	if (!SvBotsAllowed())
	{
		SvRecycleInfectedBots();
		for (int i = 0; i < sizeof(SiTimes); i++) SiTimes[i] = 0.0;
		return Plugin_Stop;
	}
	
	if (!MoreSiBotsVersus.BoolValue || GetTeamPlayers(TEAM_INFECTED, false) >= InfectedLimit.IntValue) // if no extra bots wanted
	{
		SubDirector = CreateTimer(10.0, BotInfectedCounter, false, TIMER_FLAG_NO_MAPCHANGE); // check back in 10 secs to see if setting changed
		return Plugin_Stop;
	}
	
	SiSpawnCheck();
	
	SubDirector = CreateTimer(2.0, BotInfectedCounter, false, TIMER_FLAG_NO_MAPCHANGE);
	return Plugin_Stop;
}

// ------------------------------------------------------------------------
//  Check if Si to be added to respawn Queue, or spawn a Si
// ------------------------------------------------------------------------
void SiSpawnCheck()
{
	if (!SvBotsAllowed()) return;
	// For each missing SI, add to queue
	for (int i = GetTeamPlayers(TEAM_INFECTED, true) + CountSiQueue(); i < InfectedLimit.IntValue; i++)
	{
		AddSiToQueue();
	}
	
	// For each Si over the limit, remove youngest in queue
	for (int i = GetTeamPlayers(TEAM_INFECTED, true) + CountSiQueue(); i > InfectedLimit.IntValue; i--)
	{
		int YoungestSi = GetYoungestSi();
		if (YoungestSi != -1)  	SiTimes[YoungestSi] = 0.0;		
	}
	
	// For each Si over the limit, spawn it
	int OldestSi = GetOldestSi();
	if (OldestSi != -1 && (GetGameTime() - SiTimes[OldestSi]) > GhostDelayMax.FloatValue + SiSpMoreDelay.FloatValue)
	{
		SiSpawn();
	}
}

// ------------------------------------------------------------------------
//  Get Si that has been in the spawn queue the longest
// ------------------------------------------------------------------------
int GetOldestSi()
{
	float fOldest     =  GetGameTime()+1.0; // More recent that any can be
	int   iOldest     =   			    -1;
	for (int i = 0; i < InfectedLimit.IntValue; i++)
	{
		if (SiTimes[i] > 0.0 && SiTimes[i] < fOldest)
		{
			iOldest   = i;
			fOldest   = SiTimes[i];
		}
	}
	return iOldest;
}

// ------------------------------------------------------------------------
//  Get Si that has been in the spawn queue the shortest
// ------------------------------------------------------------------------
int GetYoungestSi()
{
	float fYoungest     =                  0.0; // Older than any can be
	int   iYoungest     =   			    -1;
	for (int i = 0; i < InfectedLimit.IntValue; i++)
	{
		if (SiTimes[i] > fYoungest)
		{
			iYoungest   = i;
			fYoungest   = SiTimes[i];
		}
	}
	return iYoungest;
}

// ------------------------------------------------------------------------
//  Add new Si to spawn queue
// ------------------------------------------------------------------------
void AddSiToQueue()
{
	for (int i = 0; i < InfectedLimit.IntValue; i++)
	{
		if (SiTimes[i] == 0.0)
		{
			SiTimes[i] = GetGameTime();
			return;
		}
	}
}

// ------------------------------------------------------------------------
// Count how many SI are in the queue
// ------------------------------------------------------------------------
int CountSiQueue()
{
	int count = 0;
	for (int i = 0; i < InfectedLimit.IntValue; i++)
	{
		if (SiTimes[i] > 0.0)
		{
			count = count + 1;
		}
	}
	return count;
}

// ------------------------------------------------------------------------
//  Spawn a Special Infected bot
// ------------------------------------------------------------------------
void SetGhostStatus(int client, bool ghost) { SetEntProp(client, Prop_Send, "m_isGhost",   ghost); }

int GetSiType(int client)
{
	if (!IsValidClient(client) || GetClientTeam(client) != TEAM_INFECTED) return 0;
	return GetEntProp(client, Prop_Send, "m_zombieClass");
}

void SiSpawn(int type = -1)
{
	if (!SvBotsAllowed()) return;
	if (type == -1) type = PickSiType();
	if (type < ZC_SMOKER || type > (L4D1 ? ZC_HUNTER : ZC_CHARGER)) return;

	// Spawn an AI directly. z_spawn_old can select human infected and required
	// temporarily corrupting their ghost/life state (including respawn timers).
	// A failed position search/spawn leaves the queue intact for the next tick.
	float pos[3];
	float angles[3];
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || GetClientTeam(client) != TEAM_SURVIVOR
			|| !IsPlayerAlive(client) || IsClientInKickQueue(client)) continue;
		if (!L4D_GetRandomPZSpawnPosition(client, type, 20, pos)) continue;
		L4D2_SpawnSpecial(type, pos, angles);
		return;
	}
}

// ------------------------------------------------------------------------
//  Find which SI should be spawned
// ------------------------------------------------------------------------
int PickSiType()
{
	// first element is nothing, to simplify since enum starts at 1
	//////////////////////////////////////////////////////////////
	int SIleft[7] = {-1,  0,0,0, 0,0,0};
	int maxTypes = L4D1 ? 3 : 6;
	
	// Record SI type limits
	////////////////////////
	int SIfromTypes = 0; // 
	for (int type = 1; type <= maxTypes; type++)
	{
		SIleft[type] = L4D1? FindConVar(L4D1_limits[type]).IntValue : FindConVar(L4D2_limits[type]).IntValue;
		SIfromTypes  = SIfromTypes + SIleft[type] ;
	}

	int iInfected = InfectedLimit.IntValue;
	MinionLimit.IntValue = iInfected; 

	// Check if SI from types are enough
	///////////////////////////////////////
	if (SIfromTypes < iInfected)   // if not enough 
	{
		int extraSiPerType =  RoundToCeil((iInfected - SIfromTypes)/3.0);
		
		for(int i = 1; i <= maxTypes; i++)
		{
			SIleft[i] = SIleft[i] + extraSiPerType;
			if (L4D1) FindConVar(L4D1_limits[i]).IntValue = SIleft[i];  // Increase each SI class limit
			else      FindConVar(L4D2_limits[i]).IntValue = SIleft[i];
		}
	}
	
	// counts infected left that can be spawned.
	//////////////////////////////////////////			
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i) && GetClientTeam(i) == TEAM_INFECTED && IsPlayerAlive(i))
		{			
			int type = GetSiType(i);
			if (type >= 1 && type <= maxTypes) SIleft[type]--;
		}
	}
	
	// Pick available types;
	int nmax = 0;
	int SIfree[7];
	
	for (int type = 1; type <= 6; type++)
	{
		if (SIleft[type] > 0)
		{
			nmax++;
			SIfree[nmax] = type;
		}
	}
		
	if (nmax != 0)  return SIfree[GetRandomInt(1, nmax)];
	else 			return -1;
}

// *********************************************************************************
// SIGNATURE METHODS
// *********************************************************************************

bool EnsureSurvivorModels()
{
	if (!SurvivorMapReady) return false;
	SurvivorModelsReady = 0;
	int first = L4D1 ? 4 : 0;
	for (int i = first; i < sizeof(SurvivorModels); i++)
	{
		if (!IsModelPrecached(SurvivorModels[i]))
		{
			int index = PrecacheModel(SurvivorModels[i], true);
			if (index <= 0 || !IsModelPrecached(SurvivorModels[i]))
			{
				if (!SurvivorModelErrorLogged[i])
				{
					LogError("[SV model guard] Cannot precache %s; survivor creation/takeover blocked.", SurvivorModels[i]);
					SurvivorModelErrorLogged[i] = true;
				}
				continue;
			}
		}
		SurvivorModelsReady++;
	}
	return SurvivorModelsReady == (L4D1 ? 4 : 8);
}

void LogUnsafeSurvivor(int bot, int character, const char[] model, const char[] reason)
{
	TakeoverBlocked++;
	// A broken bot may be considered by several join timers. Keep evidence without
	// flooding the log on every retry. Counters remain visible in sm_multistatus.
	float now = GetEngineTime();
	if (now < NextTakeoverWarning) return;
	NextTakeoverWarning = now + 10.0;
	LogError("[SV model guard] Blocked unsafe survivor: bot=%d userid=%d character=%d model='%s' reason=%s",
		bot, GetClientUserId(bot), character, model, reason);
}

bool PrepareSurvivorModel(int bot)
{
	if (!IsValidClient(bot) || !IsFakeClient(bot) || GetClientTeam(bot) != TEAM_SURVIVOR) return false;
	if (!EnsureSurvivorModels()) return false;
	char model[PLATFORM_MAX_PATH];
	GetClientModel(bot, model, sizeof(model));
	int character = GetEntProp(bot, Prop_Send, "m_survivorCharacter");
	if (!model[0] || !IsModelPrecached(model))
	{
		LogUnsafeSurvivor(bot, character, model, "empty or unprecached current model");
		return false;
	}
	// Restore() chooses a model by character as well as copying the bot's state.
	// Repair an invalid ID only when its existing stock model identifies the role.
	// Do not guess a role for an unknown/custom model or overwrite valid IDs/skins.
	if (character < 0 || character >= (L4D1 ? 4 : 8))
	{
		int first = L4D1 ? 4 : 0;
		for (int i = first; i < sizeof(SurvivorModels); i++)
		{
			if (!StrEqual(model, SurvivorModels[i], false)) continue;
			int repaired = i - first;
			SetEntProp(bot, Prop_Send, "m_survivorCharacter", repaired);
			SurvivorCharacterRepairs++;
			LogMessage("[SV model guard] Repaired bot userid=%d character=%d -> %d from model='%s'",
				GetClientUserId(bot), character, repaired, model);
			return true;
		}
		LogUnsafeSurvivor(bot, character, model, "invalid character with no stock model match");
		return false;
	}
	return true;
}

bool IsTakeoverPairValid(int client, int bot)
{
	if (!SurvivorMapReady || !IsValidClient(client) || IsFakeClient(client)
		|| !IsClientAuthorized(client) || IsClientInKickQueue(client)) return false;
	if (!IsValidClient(bot) || !IsFakeClient(bot) || GetClientTeam(bot) != TEAM_SURVIVOR
		|| IsClientInKickQueue(bot)
		|| !HasEntProp(bot, Prop_Send, "m_humanSpectatorUserID")) return false;
	int owner = GetEntProp(bot, Prop_Send, "m_humanSpectatorUserID");
	return owner == 0 || owner == GetClientUserId(client);
}

int FindReservedSurvivorBot(int client)
{
	if (!IsValidClient(client)) return 0;
	int userid = GetClientUserId(client);
	for (int bot = 1; bot <= MaxClients; bot++)
	{
		if (!IsClientInGame(bot) || !IsFakeClient(bot) || GetClientTeam(bot) != TEAM_SURVIVOR
			|| !HasEntProp(bot, Prop_Send, "m_humanSpectatorUserID")) continue;
		// SetHumanSpec/TakeOverBot can run while the human is on team 0. The normal
		// GetBotOfIdle helper only recognizes spectators (team 1), so cannot be used here.
		if (GetEntProp(bot, Prop_Send, "m_humanSpectatorUserID") == userid) return bot;
	}
	return 0;
}

bool SafeTakeOverSurvivor(int client, int bot)
{
	if (!IsTakeoverPairValid(client, bot) || !PrepareSurvivorModel(bot)) return false;
	int clientUserid = GetClientUserId(client);
	int botUserid = GetClientUserId(bot);
	if (GetClientTeam(client) != TEAM_SPECTATOR && GetClientTeam(client) != 0)
		ChangeClientTeam(client, TEAM_SPECTATOR);
	if (!IsTakeoverPairValid(client, bot) || GetClientUserId(client) != clientUserid
		|| GetClientUserId(bot) != botUserid) return false;
	if (FindReservedSurvivorBot(client) != bot)
	{
		ChangeClientTeam(client, 0);
		// Team changes invoke other plugins synchronously. Recheck the target identity
		// before passing it into an SDKCall, even though no timer has elapsed.
		if (!IsTakeoverPairValid(client, bot) || GetClientUserId(client) != clientUserid || GetClientUserId(bot) != botUserid
			|| !PrepareSurvivorModel(bot) || !L4D_SetHumanSpec(bot, client))
		{
			if (IsValidClient(client) && GetClientUserId(client) == clientUserid && GetClientTeam(client) == 0)
				ChangeClientTeam(client, TEAM_SPECTATOR);
			return false;
		}
	}
	if (!IsTakeoverPairValid(client, bot) || GetClientUserId(client) != clientUserid || GetClientUserId(bot) != botUserid
		|| FindReservedSurvivorBot(client) != bot || !PrepareSurvivorModel(bot))
	{
		if (IsValidClient(client) && GetClientUserId(client) == clientUserid && GetClientTeam(client) == 0)
			ChangeClientTeam(client, TEAM_SPECTATOR);
		return false;
	}
	bool taken = L4D_TakeOverBot(client);

	// 接管失败时必须清掉"该 bot 被该玩家托管"的链接（m_humanSpectatorUserID）：
	// 链接留着的话引擎会把这个玩家判定成闲置（挂机托管），牌子上带闲置、又控制不到身体。
	// 对抗里没有主动闲置键，所以这条链接一旦残留就只能是 bug，直接清掉。
	if (!taken)
		ClearIdleLink(bot, client);

	if (!taken && IsValidClient(client) && GetClientUserId(client) == clientUserid && GetClientTeam(client) == 0)
		ChangeClientTeam(client, TEAM_SPECTATOR);

	bool okay = taken && IsValidClient(client) && GetClientUserId(client) == clientUserid
		&& GetClientTeam(client) == TEAM_SURVIVOR;

	// 接管成功只代表拿到了这具身体，这具身体可能本来就没枪 → 延迟补枪
	if (okay) ScheduleLoadoutCheck(client);

	return okay;
}

// 清掉"bot 被 client 托管"的挂机链接（m_humanSpectatorUserID）。不写日志。
// 只在链接确实指向该 client 时才写，避免误清别人正在用的托管。
void ClearIdleLink(int bot, int client)
{
	if (bot <= 0 || bot > MaxClients || !IsClientInGame(bot))
		return;

	if (!HasEntProp(bot, Prop_Send, "m_humanSpectatorUserID"))
		return;

	if (GetClientOfUserId(GetEntProp(bot, Prop_Send, "m_humanSpectatorUserID")) != client)
		return;

	SetEntProp(bot, Prop_Send, "m_humanSpectatorUserID", 0);
}

// Also protects assigned survivor bots taken over by the engine or another plugin
// (e.g. the map team-restoration timer) while this multiplayer mode is loaded.
public Action L4D_OnTakeOverBot(int client)
{
	if (!EnsureSurvivorModels()) return Plugin_Handled;
	int bot = FindReservedSurvivorBot(client);
	if (bot > 0 && (!IsTakeoverPairValid(client, bot) || !PrepareSurvivorModel(bot)))
		return Plugin_Handled;
	return Plugin_Continue;
}

// ------------------------------------------------------------------------
// 中途加入 / 接管生还者后的补枪兜底
//   加入与接管流程本身不发放任何武器（模型校验、SetHumanSpec/TakeOverBot 都不碰
//   武器槽），所以这里在加入后延迟 1 秒检查主武器槽（槽 0），空手就补一把冲锋枪。
//   缺省武器上限（l4d_weapon_limits）可能拦下 GivePlayerItem，失败时退回 cheat
//   "give"；两次都拿不到就写错误日志，不静默失败。
//   只处理真人：Bot 没枪不该由这里补，也不该因此动到 AI 的装备逻辑。
// ------------------------------------------------------------------------
void ScheduleLoadoutCheck(int client)
{
	if (!IsValidClient(client) || IsFakeClient(client)) return;

	CreateTimer(1.0, Timer_LoadoutCheck, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_LoadoutCheck(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);

	// 这一秒内可能已离开 / 被换边 / 阵亡
	if (!IsValidClient(client) || IsFakeClient(client)) return Plugin_Stop;
	if (GetClientTeam(client) != TEAM_SURVIVOR || !IsPlayerAlive(client)) return Plugin_Stop;

	// 已有主武器：不动
	if (GetPlayerWeaponSlot(client, 0) != -1) return Plugin_Stop;

	GivePlayerItem(client, "weapon_smg");

	// 被武器上限拦住时退回 give 指令
	if (GetPlayerWeaponSlot(client, 0) == -1)
		CheatGiveWeapon(client, "weapon_smg");

	// 仍然没有主武器 → 写日志，便于线上取证
	if (GetPlayerWeaponSlot(client, 0) == -1)
		LogError("[SV] 给 %L 补发 weapon_smg 失败（可能被武器上限/拾取拦截挡住）", client);

	return Plugin_Stop;
}

// 临时去掉 give 的 cheat 标记并临时给 root 权限再执行（与 givewpn.sp 同款写法）
void CheatGiveWeapon(int client, const char[] weapon)
{
	int flags = GetCommandFlags("give");
	if (flags == -1) return;

	int admin = GetUserFlagBits(client);

	SetUserFlagBits(client, ADMFLAG_ROOT);
	SetCommandFlags("give", flags & ~FCVAR_CHEAT);

	FakeClientCommand(client, "give %s", weapon);

	SetCommandFlags("give", flags);
	SetUserFlagBits(client, admin);
}

void Respawn(int client)
{
	L4D_RespawnPlayer(client);
}

// *********************************************************************************
// CHEAT METHODS
// *********************************************************************************

stock void PrintConsoleToAll(const char[] format, any ...) 
{ 
	char text[192];
	VFormat(text, sizeof(text), format, 2);
	
	for (int i = 1; i <= MaxClients; i++)
	{ 
		if (IsClientInGame(i))
		{
			SetGlobalTransTarget(i);
			PrintToConsole(i, "%s", text);
		}
	}
}

// ------------------------------------------------------------------------
// Teleport client to survivor
// ------------------------------------------------------------------------

// 落点的横向偏移量（HU）。直接压在队友 AbsOrigin 上会和队友身体重叠互相顶住（尤其是 Bot），
// 所以统一偏移一点点再传；落点正好压在墙角/栏杆里时，由函数末尾的 Warp 兜底把人推出来。
#define TELEPORT_ANCHOR_OFFSET 20.0

/* 在指定优先级里找传送落点。
 * 优先级由 TeleportToSurvivor 分两轮决定：先只找真人（allowBots=false），再回落到 AI 生还者（allowBots=true）。
 *
 * 同一优先级内挑"离 Bot 最近"的那个，而不是循环里第一个撞见的队员，依据：
 *   1) 按索引取第一个 → 多个占位 Bot / 连续加入的真人会全部叠在同一名队友身上，模型互相卡住，
 *      而那一名队友被反复当作落点，其他存活队友旁边永远是空的；
 *   2) 取最近的落点 → 队友分散时后到的人各贴最近的一个人（自然分散），传送距离最短，
 *      穿墙/掉出地图的概率也最低；同一名队友不会被无脑反复占用。
 *
 * 返回 0 表示本优先级没有可用落点（调用方据此进入下一优先级或直接放弃）。
 */
int FindTeleportAnchor(int Bot, bool allowBots)
{
	float botOrigin[3];
	GetClientAbsOrigin(Bot, botOrigin);

	int best = 0;
	float bestDist = 0.0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (i == Bot) continue;
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR) continue;
		// 存活判定沿用插件自己的 IsAlive（m_lifeState == 0，与 IsPlayerAlive 等价）；
		// 已被排队踢掉的客户端位置没有意义，上面一并排除。
		if (!IsAlive(i) || IsClientInKickQueue(i)) continue;
		if (IsFakeClient(i) != allowBots) continue;
		// 幽灵状态（m_isGhost）的生还者是不可见/无碰撞的残影，不能当落点
		if (GetEntProp(i, Prop_Send, "m_isGhost")) continue;

		float origin[3];
		GetClientAbsOrigin(i, origin);
		float dist = GetVectorDistance(botOrigin, origin);
		if (best == 0 || dist < bestDist)
		{
			best = i;
			bestDist = dist;
		}
	}
	return best;
}

/* 把 Bot（刚造出来的生还者 Bot 或刚复活的真人）传送到队友身边。
 * 只在两处明确需要的地方调用：SpawnSurvivorBot 造出的新 bot（下一帧收尾）、
 * TryJoinTeam 真人中途加入复活。不做任何"定期把人传送"的轮询。 */
void TeleportToSurvivor(int Bot) 
{
	if (!IsValidClient(Bot)) return;

	/* 落点优先级：
	   1) 活着的真人（team 2、存活、非 bot、不是自己）—— 玩家最直接的期望是"就在队友旁边"；
	   2) 没有活着的真人时，回落到活着的 AI 生还者（team 2、存活、非自己、不是幽灵/占位）。
	      旧写法只找真人，找不到就 break 掉、什么都不做 → 全场只剩他一个真人（或其余真人都在旁观/阵亡）时，
	      刚复活出来的人就永远留在起点安全区。这就是"有的时候会被传送到起点安全区"的根因；
	   3) 两类都没有才放弃：无处可传，不硬造坐标（乱造坐标会把人塞进墙里甚至传送到地图外）。 */
	int Anchor = FindTeleportAnchor(Bot, false);
	if (Anchor <= 0) Anchor = FindTeleportAnchor(Bot, true);
	if (Anchor <= 0) return;

	float origin[3];
	// get the position coordinates of any active alive player（原注释保留；落点坐标取自存活队友）
	GetClientAbsOrigin(Anchor, origin);

	// 按 Bot 索引取一个固定方位做偏移：同一个落点上挤多个 Bot 时会散向不同方向，进一步避免叠人
	float rad = DegToRad(float(Bot % 8) * 45.0);
	float dest[3];
	dest[0] = origin[0] + Cosine(rad) * TELEPORT_ANCHOR_OFFSET;
	dest[1] = origin[1] + Sine(rad) * TELEPORT_ANCHOR_OFFSET;
	dest[2] = origin[2];

	TeleportEntity(Bot, dest, NULL_VECTOR, NULL_VECTOR);

	// 偏移后的落点可能正好压在墙角/栏杆里：让引擎把人推到最近的有效可行走位置。
	// 该 native 属于较新的 Left4DHooks，服务器上的旧版可能没有；AskPluginLoad2 已 MarkNativeAsOptional，
	// 这里再探一次特性状态，缺失就只跳过这层兜底，不影响传送本身。
	if (GetFeatureStatus(FeatureType_Native, "L4D_WarpToValidPositionIfStuck") == FeatureStatus_Available)
		L4D_WarpToValidPositionIfStuck(Bot);
}


void SetGodMode(int client, float duration)
{
	if (!IsClientInGame(client)) return;
	
	SetEntProp(client, Prop_Data, "m_takedamage", 0, 1); // god mode
	
	if (duration > 0.0) CreateTimer(duration, Timer_mortal, GetClientUserId(client));
}

public Action Timer_mortal(Handle hTimer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (!client || !IsClientInGame(client)) return Plugin_Stop;
	SetEntProp(client, Prop_Data, "m_takedamage", 2, 1); // mortal
	return Plugin_Stop;
}

stock int TotalSurvivors() // total bots, including players
{
	int l = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i))
		{
			if (IsClientInGame(i) && (GetClientTeam(i) == TEAM_SURVIVOR)) l++;
		}
	}
	return l;
}

public Action Timer_KickNoNeededBot(Handle timer, any userid)
{
	int bot = GetClientOfUserId(userid);
	if (!bot || !IsFakeClient(bot) || !IsClientInGame(bot) || GetClientTeam(bot) != TEAM_SURVIVOR)
		return Plugin_Stop;
	if ((TotalSurvivors() <= cvar_minsurvivor.IntValue)) return Plugin_Handled;
	if (IsClientConnected(bot) && IsClientInGame(bot))
	{
		char BotName[100];
		GetClientName(bot, BotName, sizeof(BotName));				
		if (StrEqual(BotName, "SurvivorBot", true)) return Plugin_Handled;
		if (!HasIdlePlayer(bot))
		{
			StripWeapons(bot);
			KickClient(bot, "Kicking No Needed Bot");
		}
	}
	
	//ServerCommand("sm_kickextrabots");
	
	return Plugin_Handled;
}


stock void StripWeapons(int client) // strip all items from client
{
	int itemIdx;
	for (int x = 0; x <= 3; x++)
	{
		if ((itemIdx = GetPlayerWeaponSlot(client, x)) != -1)
		{  
			RemovePlayerItem(client, itemIdx);
			RemoveEdict(itemIdx);
		}
	}
}

stock bool HasIdlePlayer(int bot)
{
	if (IsValidEntity(bot))
	{
		char sNetClass[12];
		GetEntityNetClass(bot, sNetClass, sizeof(sNetClass));

		if (strcmp(sNetClass, "SurvivorBot") == 0)
		{
			if (!GetEntProp(bot, Prop_Send, "m_humanSpectatorUserID"))
				return false;

			int client = GetClientOfUserId(GetEntProp(bot, Prop_Send, "m_humanSpectatorUserID"));
			if (client)
			{
				// Do not count bots
				// Do not count 3rd person view players
				if (IsClientInGame(client) && !IsFakeClient(client) && (GetClientTeam(client) != TEAM_SURVIVOR)) return true;
			}
			else return false;
		}
	}
	return false;
}


bool IsAlive(int client)
{
	if (!GetEntProp(client, Prop_Send, "m_lifeState")) return true;
	return false;
}

// *********************************************************************************
// 2.5.20：禁止自动入队名单（暖服客户端）
//
//   背景：暖服客户端账号（STEAM_1:1:400172186）本来只该站在旁观"暖服"，
//   但它每次被拉进 / 自己进生还者队后又被 AFK 插件搬回旁观，形成毫秒级的
//   "进队 → 换模型 → 被搬走 → 再进队"循环；这个循环里实体模型在
//   hunter.mdl ↔ survivor_*.mdl 之间反复切换，而 m_nSequence 不随模型复位，
//   最终一次命中盒测试让 SlerpBones() 用越界序列号索引虚拟模型序列表 → 崩服。
//
//   这里把该账号拉进"禁止自动入队"名单：连接后自动入队、平衡补位、
//   Join_Wait 每秒重试都不再碰它，从源头掐掉这个循环。
//   名单可由 l4d_superversus_nojoin_steamids 覆盖（留空 = 关闭本功能）。
// *********************************************************************************

bool IsNoJoinClient(int client)
{
	return (client > 0 && client <= MaxClients && g_bNoJoinClient[client]);
}

public void OnNoJoinListChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	ReloadNoJoinList();
}

void ReloadNoJoinList()
{
	if (NoJoinSteamIds == null)
		return;

	NoJoinSteamIds.GetString(g_sNoJoinIds, sizeof(g_sNoJoinIds));
	NoJoinIps.GetString(g_sNoJoinIps, sizeof(g_sNoJoinIps));
	NoJoinNames.GetString(g_sNoJoinNames, sizeof(g_sNoJoinNames));

	for (int i = 1; i <= MaxClients; i++)
		RefreshNoJoinFlag(i);
}

/**
 * 在逗号分隔的名单里查找 value。
 * prefixOk = true 时同时接受"value 以该条目开头"（IP 段写法，如 202.189.15.）。
 */
bool MatchAnyEntry(const char[] list, const char[] value, bool prefixOk)
{
	if (list[0] == '\0' || value[0] == '\0')
		return false;

	char entries[16][64];
	int n = ExplodeString(list, ",", entries, sizeof(entries), sizeof(entries[]));
	for (int i = 0; i < n; i++)
	{
		TrimString(entries[i]);
		if (entries[i][0] == '\0')
			continue;

		if (StrEqual(entries[i], value, false))
			return true;

		if (prefixOk && StrContains(value, entries[i], false) == 0)
			return true;
	}

	return false;
}

/**
 * 重新判定某玩家是否命中名单。
 * 同时比对 SteamID64 / STEAM_X:Y:Z / [U:1:accountid] 三种写法，方便直接照抄日志里的 auth 串。
 */
void RefreshNoJoinFlag(int client)
{
	if (client <= 0 || client > MaxClients)
		return;

	// "反复被搬去旁观"的自动判定只对本次连接有效，重算身份时不能被清掉
	g_bNoJoinClient[client] = g_bChurnNoJoin[client];

	if (!IsClientConnected(client) || IsFakeClient(client))
		return;

	// 第 1 层：SteamID64 / STEAM_X:Y:Z / [U:1:x] 三种写法
	if (g_sNoJoinIds[0] != '\0')
	{
		char auth64[32], auth2[32], authU[32];

		if (GetClientAuthId(client, AuthId_SteamID64, auth64, sizeof(auth64), false)
			&& MatchAnyEntry(g_sNoJoinIds, auth64, false))
		{
			g_bNoJoinClient[client] = true;
			return;
		}

		if (GetClientAuthId(client, AuthId_Steam2, auth2, sizeof(auth2), false)
			&& MatchAnyEntry(g_sNoJoinIds, auth2, false))
		{
			g_bNoJoinClient[client] = true;
			return;
		}

		if (GetClientAuthId(client, AuthId_Steam3, authU, sizeof(authU), false)
			&& MatchAnyEntry(g_sNoJoinIds, authU, false))
		{
			g_bNoJoinClient[client] = true;
			return;
		}
	}

	// 第 2 层：IP（SteamID 还没验证完 / NoSteam 客户端时的兜底；支持前缀）
	if (g_sNoJoinIps[0] != '\0')
	{
		char ip[64];
		GetClientIP(client, ip, sizeof(ip), true);
		if (MatchAnyEntry(g_sNoJoinIps, ip, true))
		{
			g_bNoJoinClient[client] = true;
			return;
		}
	}

	// 第 3 层：显示名（最后一层兜底；玩家可改名，安全性最低）
	if (g_sNoJoinNames[0] != '\0')
	{
		char name[MAX_NAME_LENGTH];
		GetClientName(client, name, sizeof(name));
		if (MatchAnyEntry(g_sNoJoinNames, name, false))
		{
			g_bNoJoinClient[client] = true;
			return;
		}
	}
}

/**
 * 认证到达后重算一次名单。
 * 引擎的 auth 可能晚到（或验证失败后又回填），只靠 OnClientPostAdminCheck 那一次会漏，
 * 这里补一次；SteamID 始终取不到时还有 IP / 名字 / 行为三层兜底。
 */
public void OnClientAuthorized(int client, const char[] auth)
{
	RefreshNoJoinFlag(client);
}

/**
 * l4d_superversus_nojoin_block_jointeam = 1 时，连客户端自己发的 jointeam(2/3) 也拦掉，
 * 让名单内的账号只能留在旁观。默认 0（只拦本插件的自动入队）。
 */
public Action Cmd_NoJoinTeam(int client, const char[] command, int argc)
{
	if (!NoJoinBlockJoinTeam.BoolValue)
		return Plugin_Continue;

	if (client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
		return Plugin_Continue;

	if (!IsNoJoinClient(client))
		return Plugin_Continue;

	if (argc < 1)
		return Plugin_Continue;

	char arg[16];
	GetCmdArg(1, arg, sizeof(arg));

	int team = StringToInt(arg);
	if (team != TEAM_SURVIVOR && team != TEAM_INFECTED)
		return Plugin_Continue;

	float fNow = GetGameTime();
	if (g_fNoJoinHintAt[client] <= 0.0 || fNow - g_fNoJoinHintAt[client] >= 10.0)
	{
		g_fNoJoinHintAt[client] = fNow;
		PrintToChat(client, "\x03[SV] \x01此账号已设置为不自动加入队伍，请留在旁观。");
	}

	return Plugin_Handled;
}
