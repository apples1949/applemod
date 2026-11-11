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
#define PLUGIN_VERSION "2.5.19-12v12"
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
#define SIHUD_TXT_HINT           "输入!sihud开关面板"
#define SIHUD_TXT_BLANK          " "
#define SIHUD_TXT_TANK_AI        "AI"      // 坦克行：AI 坦克时"名字"位置显示 AI
#define SIHUD_TXT_WITCH_ALIVE    "已生成"  // 女巫行：已刷出且还活着
#define SIHUD_TXT_CTRL_FIRST     "一控"    // 坦克行：第一次控制
#define SIHUD_TXT_CTRL_SECOND    "二控"    // 坦克行：被第二名玩家接管（二控）
#define SIHUD_PANEL_SECONDS      3      // 面板显示时长（秒）；比刷新间隔长，画面才连续
#define SIHUD_REFRESH_SECONDS    1.0    // 刷新间隔（秒）：需求 1 秒刷新
#define SIHUD_FORCE_SECONDS      2.0    // 需求：离开安全区 / 坦克刷出与接管时，强制显示面板的秒数
#define SIHUD_FORCE_REDRAW       0.25   // 强制期间的重画间隔（秒）：远小于 1 秒，
                                        // 这 2 秒里面板才一直压在最上面（被别的面板顶掉能立刻顶回来）
#define SIHUD_TEXT_BUDGET        510    // 面板总预算 511 字节，单行留 1 字节给换行
#define SIHUD_NAME_CHARS         2      // 玩家名保留的字符数（需求：只显示前两个字符）
#define SIHUD_SAFE_HEALTH        40     // "总血量>40"的门槛（倒地人数那一列用）
#define SIHUD_SPAWN_LINES        2      // 刷新点显示几行
#define SIHUD_MAX_SPAWNS         192    // 缓存的 info_zombie_spawn 上限
#define SIHUD_SPAWN_SCAN_ATTEMPTS 30    // 全图最大 flow 还没就绪时最多重试多少次（每秒一次）
#define SIHUD_SPAWN_AHEAD_EPS    1.0    // flow 余量：与最远生还者齐平的点算"已越过"
#define SIHUD_EARLY_CLOSE_SLACK  0.5    // 面板提前这么多秒消失即认为玩家自己关了
#define SIHUD_DEFAULT_TANK_DELAY 7      // sm_sihud_tank_delay 默认值（需求：接管坦克 7 秒后才关掉他的 tankhud）
#define SIHUD_WPN_AWP            "weapon_sniper_awp"
#define SIHUD_WPN_SCOUT          "weapon_sniper_scout"

// ---------------------------------------------------------------------------
// 生还者 bot 创建失败统计（NextBotCreatePlayerBot 返回无效槽位 -1 的防御与日志限频）
// ---------------------------------------------------------------------------
#define NEXTBOT_FAIL_LOG_SECONDS   5.0	// "无效槽位"日志最短间隔（秒），需求：每 N 秒最多一条
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
ConVar SiHudTankDelay;						// sm_sihud_tank_delay：坦克玩家多少秒后才关掉 tankhud
ConVar SiHudDebug;							// sm_sihud_debug：打印诊断日志
ConVar VersusBossBuffer;					// versus_boss_buffer：boss 刷出位置的余量（与 spechud 同口径）
bool g_bSiHudOn[MAXPLAYERS+1];				// 玩家是否开启面板（只由 !sihud 改变）
bool g_bSiHudSent[MAXPLAYERS+1];			// 上一次发送成功与否（判断屏幕上的面板是不是我们自己的）
bool g_bSiHudSeen[MAXPLAYERS+1];			// 上一 tick 确实看到过我们自己的面板（防止把"没显示出来"误判成 ESC）
bool g_bSiHudAutoShownRound = false;		// 本回合"首次离开安全区强制显示"是否已经用掉
float g_fSiHudTankLockUntil[MAXPLAYERS+1];	// 坦克玩家：到这一刻为止面板让位给他的 tankhud（强制显示不受它限制）
float g_fSiHudLastSendAt[MAXPLAYERS+1];		// 上一次成功发送面板的时刻
// 强制显示窗口（需求：离开安全区 / 坦克事件时对所有能看面板的玩家连续 2 秒强开）
//   g_fSiHudForceUntil > 当前时刻 = 该玩家在强制窗口内；窗口期间由
//   g_hSiHudForceTimer（SIHUD_FORCE_REDRAW 秒一次）按固定的快节奏重画。
float g_fSiHudForceUntil[MAXPLAYERS+1];
Handle g_hSiHudForceTimer = null;
// 坦克 / 女巫状态（面板最后两行 + "坦克刷出与接管"事件的判定）
int g_iSiHudTankClient = 0;					// 当前坦克玩家（含 AI bot；0=场上没有坦克）
int g_iSiHudTankControl = 0;				// 这只坦克已经被几个真人控制过（1=一控 2=二控及以上）
bool g_bSiHudTankSpawned = false;			// 本回合坦克刷出过
bool g_bSiHudTankDead = false;				// 坦克刷出过且已经死（→ 不显示 Tank 行）
bool g_bSiHudWitchSpawned = false;			// 本回合女巫刷出过
bool g_bSiHudWitchDead = false;				// 女巫刷出过且已经死（→ 不显示 Witch 行）
// 地图 info_zombie_spawn 的路程缓存（每张图只扫一次，见 SiHud_EnsureSpawnFlows）
float g_fSiHudSpawnFlow[SIHUD_MAX_SPAWNS];
int g_iSiHudSpawnCount = 0;
int g_iSiHudSpawnAttempts = 0;				// 本图已尝试采样次数（flow 没有就绪时的上限保护）
bool g_bSiHudSpawnScanned = false;
bool g_bSiHudSpawnWarned = false;
bool g_bSiHudLimitMissLogged[7];			// 六个 z_versus_*_limit 读不到时"只记一次"
// Left4DHooks native 可用性：left4dhooks.inc 默认把这些 native 标成 optional，必须先探再用
bool g_bSiHudMaxFlowNative = false;			// L4D2Direct_GetMapMaxFlowDistance
bool g_bSiHudClientFlowNative = false;		// L4D2Direct_GetFlowDistance
bool g_bSiHudHighestNative = false;			// L4D_GetHighestFlowSurvivor
bool g_bSiHudFurthestFlowNative = false;	// L4D2_GetFurthestSurvivorFlow
bool g_bSiHudNavFlowNative = false;			// L4D2Direct_GetTerrorNavAreaFlow
bool g_bSiHudNearestNavNative = false;		// L4D_GetNearestNavArea
bool g_bSiHudDirectNavNative = false;		// L4D2Direct_GetTerrorNavArea
bool g_bSiHudReadyUpNative = false;			// readyup 的 IsInReady（准备阶段不抢屏幕）
bool g_bSiHudBossFlowNative = false;		// 坦克/女巫出生百分比位置（L4D2Direct_GetVS*FlowPercent 等）
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
	// 特感辅助面板最后两行（Tank / Witch 出生位置）要用，与 spechud_appledmod 的算法同口径
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
	/* 特感辅助面板（旧 Team Panel 已删除，这里注册唯一的开关命令 sm_sihud / 聊天 !sihud） */
	SiHudEnable = CreateConVar("sm_sihud_enable", "1", "特感辅助面板总开关. 0=关闭（所有人都打不开）.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	SiHudForceShow = CreateConVar("sm_sihud_force_show", "1", "生还者每回合首次离开安全区域时，是否给所有能看面板的玩家连续强制显示特感辅助面板 2 秒. 1=强制显示(默认); 0=不强制，只刷新已经开着面板的人.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	SiHudTankDelay = CreateConVar("sm_sihud_tank_delay", "7", "坦克玩家接管坦克后，多少秒后才关掉他的坦克HUD(tankhud)；这期间他的特感辅助面板让位给坦克HUD（强制显示的那 2 秒除外）.", FCVAR_NOTIFY, true, 0.0, true, 60.0);
	SiHudDebug = CreateConVar("sm_sihud_debug", "0", "1=在服务端日志里打印特感辅助面板的诊断信息（ESC 关闭、强制显示、坦克事件、刷新点采样等）.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	RegConsoleCmd("sm_sihud", Cmd_SiHud, "开关特感辅助面板（聊天 !sihud）");
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
	   （ChangeClientTeam 是同步生效的），所以同一帧连续补位既不会超员、也不会重复补同一格。 */
	for(; iSurvivor < cvar_minsurvivor.IntValue; iSurvivor++) SpawnSurvivorBot();
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

	/* NextBotCreatePlayerBot 内部就是 CreateFakeClient() + Instance()：空位刚被回收
	   （同一 tick 里刚踢掉的 bot、玩家刚断线）时它会返回无效槽位 -1。这类失败是瞬时的，
	   所以先立刻重试一次 —— 第二次调用时引擎通常已经把空位放出来了。
	   旧代码在这里直接 LogError 后返回，于是每次 SpawnCheck 都刷一条同样的日志，
	   就是用户看到的 "...NextBotCreatePlayerBot<SurvivorBot> 返回无效槽位 -1" 刷屏。 */
	if (!IsNextBotSlotUsable(bot))
	{
		NextBotReleaseInvalidSlot(bot);
		bot = SDKCall(g_hSDK_NextBotCreatePlayerBot, botName);
	}

	if (!IsNextBotSlotUsable(bot))
	{
		NextBotReleaseInvalidSlot(bot);
		NextBotNoteFailure(bot);
		// 连续失败时退回旧的 CreateFakeClient 两段式，把座位照旧补上（内部限频）
		return NextBotLegacyFallback(botName, manual);
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

/* 无效槽位统计 + 限频日志（需求：每 N 秒最多一条）。
   连续失败次数与持续时间同时达标才彻底降级：分批连刷 12 个 bot 时的一次性瞬时失败
   不该把整条 NextBot 路径废掉。 */
void NextBotNoteFailure(int bot)
{
	float now = GetGameTime();
	g_iNextBotFailStreak++;
	if (g_fNextBotFailSince == 0.0) g_fNextBotFailSince = now;

	if (g_fNextBotFailLogAt != 0.0 && (now - g_fNextBotFailLogAt) < NEXTBOT_FAIL_LOG_SECONDS)
	{
		g_iNextBotFailSuppressed++;
	}
	else
	{
		char message[256];
		FormatEx(message, sizeof(message),
			"[SV bot] NextBotCreatePlayerBot<SurvivorBot> 返回无效槽位 %d"
			... "（连续第 %d 次；日志已限频=每 5 秒最多一条，本次压掉 %d 条；"
			... "clients=%d/%d，生还者=%d/%d）",
			bot, g_iNextBotFailStreak, g_iNextBotFailSuppressed,
			GetClientCount(false), MaxClients, GetSurvivorTeam(), SurvivorLimit.IntValue);
		LogError("%s", message);
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

	g_fNextBotLegacyAt = now;
	g_iNextBotLegacyUses++;
	if (!SpawnSurvivorBotLegacy(botName, manual)) return false;
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
//     C. 生还者**每回合首次**离开安全区域（player_left_start_area / player_left_checkpoint）时，
//        给所有能看面板的玩家**连续 2 秒**强制显示（SIHUD_FORCE_SECONDS，2 秒里每 0.25 秒重画一次，
//        被别的面板顶掉也会立刻顶回来），2 秒后解除强制 —— 之后**不再自动打开**，
//        面板是开是关完全由玩家自己 !sihud 决定。sm_sihud_force_show=0 时这一步跳过。
//        本回合已经强制显示过之后，中途进服的非生还者补一次同样的 2 秒强制显示。
//     D. 坦克刷出 / 被接管（tank_spawn、以及 1 秒轮询发现"同一只坦克换了控制者"）：
//          · 关掉**所有玩家**的坦克HUD（tankhud 由 spechud_appledmod 画，走 SpecHud_TankHudDisable）；
//            坦克玩家本人例外：他先看 sm_sihud_tank_delay（默认 7 秒）自己的坦克血量，7 秒后才关；
//          · 除坦克玩家外的其它玩家：同一时刻起连续 2 秒强制显示本面板；
//          · 坦克玩家：这 7 秒里本面板让位（g_fSiHudTankLockUntil），但那 2 秒强制显示对他同样生效。
//        二控（坦克被第二名玩家接管）按当前坦克玩家重新计时。
//     G. 玩家按 ESC 关掉面板后不再自动重开（旧 Team Panel 会重开）；ESC / !sihud 关闭会同时取消
//        该玩家的强制显示窗口，所以"强制 2 秒"也不会和玩家抢屏幕。
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
// 命令入口：反复输入 !sihud / sm_sihud 开关面板
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

	// 判断"看到的面板要不要关"：自己开着面板，或者正处在强制显示窗口里（屏幕上确实有面板）。
	// 这一步必须排在坦克让位窗口判断之前 —— 否则坦克玩家在自己那 7 秒里连强制显示的面板都关不掉。
	if (g_bSiHudOn[client] || SiHud_IsForced(client, GetGameTime()))
	{
		g_bSiHudOn[client] = false;
		g_bSiHudSent[client] = false;
		g_bSiHudSeen[client] = false;
		// 手动关掉 = 连强制显示窗口一起取消（否则 ESC / !sihud 之后面板还会被强制顶回来）
		SiHud_CancelForce(client);
		SiHud_ClosePanel(client, SIHUD_TXT_BLANK);
		PrintToChat(client, "[SV] 特感辅助面板已关闭。");
		return Plugin_Handled;
	}

	// D：坦克玩家在 tank_delay 窗口里面板让位给他的坦克HUD（这段时间不给开）
	if (SiHud_IsTankLocked(client))
	{
		PrintToChat(client, "[SV] 你刚接管坦克，%d 秒后才显示特感辅助面板。",
			SiHudTankDelay != null ? SiHudTankDelay.IntValue : SIHUD_DEFAULT_TANK_DELAY);
		return Plugin_Handled;
	}

	g_bSiHudOn[client] = true;
	SiHud_UpdatePanel();	// 立刻画一次，不必等下一个 1 秒刷新
	if (SiHud_ReadyUpActive())
		PrintToChat(client, "[SV] 特感辅助面板已开启（准备阶段结束后显示），再次输入 !sihud 关闭。");
	else
		PrintToChat(client, "[SV] 特感辅助面板已开启，再次输入 !sihud 关闭。");
	return Plugin_Handled;
}

// ------------------------------------------------------------------------
// 1 秒刷新：先更新坦克/女巫状态（刷出、接管、死亡），再重画一次面板
// ------------------------------------------------------------------------
public Action Timer_SiHudRefresh(Handle timer)
{
	SiHud_PollBossState();
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

	for (int client = 1; client <= MaxClients; client++)
	{
		if (g_fSiHudForceUntil[client] <= 0.0) continue;
		if (g_fSiHudForceUntil[client] > now)
		{
			any = true;
			continue;
		}
		// 窗口到期：解除强制。玩家自己没开面板的，把屏幕上的残影清掉 ——
		// 否则这块面板还会按 SIHUD_PANEL_SECONDS 再挂 3 秒，"2 秒就是 2 秒"。
		g_fSiHudForceUntil[client] = 0.0;
		if (!g_bSiHudOn[client] && IsClientInGame(client) && !IsFakeClient(client))
		{
			g_bSiHudSent[client] = false;
			g_bSiHudSeen[client] = false;
			SiHud_ClosePanel(client, SIHUD_TXT_BLANK);
		}
		if (SiHudDebug != null && SiHudDebug.BoolValue)
			LogMessage("[SV sihud] client=%d 强制显示结束。", client);
	}

	if (!any)
	{
		g_hSiHudForceTimer = null;
		return Plugin_Stop;
	}
	SiHud_DrawFrame(true);
	return Plugin_Continue;
}

// 坦克玩家延迟结束（sm_sihud_tank_delay 秒）：先关掉他的坦克HUD，再按原开关状态恢复面板
public Action Timer_SiHudTankRestore(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (!client) return Plugin_Stop;

	// 需求：坦克玩家接管坦克后过 N 秒才关掉他的 tankhud（这 N 秒他先看自己的坦克血量）
	if (IsClientInGame(client)) SiHud_DisableTankHud(client);

	if (!IsClientInGame(client) || IsFakeClient(client)) return Plugin_Stop;
	if (!g_bSiHudOn[client]) return Plugin_Stop;			// 期间自己关掉了就别再开
	if (GetClientTeam(client) == TEAM_SURVIVOR) return Plugin_Stop;
	if (SiHud_IsTankLocked(client)) return Plugin_Stop;	// 锁又被延长了，交给更晚的 timer
	SiHud_UpdatePanel();								// 时间到，立即恢复
	return Plugin_Stop;
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
	g_iSiHudTankControl = SiHud_IsHumanTank(tank) ? 1 : 0;	// 刷出时算"一控"
	g_bSiHudTankSpawned = true;
	g_bSiHudTankDead = false;

	SiHud_OnTankEvent(tank, false);
}

// 坦克死亡（tank_killed）：本回合刷出过且已死 → 面板不再画 Tank 行（需求）
public void Event_TankKilled(Event event, const char[] name, bool dontBroadcast)
{
	g_iSiHudTankClient = 0;
	g_bSiHudTankSpawned = true;
	g_bSiHudTankDead = true;
}

// 女巫刷出 / 死亡：只影响面板最后一行的 Witch 行要不要画
public void Event_WitchSpawn(Event event, const char[] name, bool dontBroadcast)
{
	g_bSiHudWitchSpawned = true;
	g_bSiHudWitchDead = false;
}

public void Event_WitchKilled(Event event, const char[] name, bool dontBroadcast)
{
	g_bSiHudWitchSpawned = true;
	g_bSiHudWitchDead = true;
}

// ------------------------------------------------------------------------
// 1 秒轮询坦克 / 女巫状态（Timer_SiHudRefresh 里调）
//   · 坦克：事件没覆盖到的"刷出"（插件晚加载、事件丢失）与**接管**（同一只坦克换了控制者）
//     都在这里兜住。接管 = 二控，需求要求按新的坦克玩家重新计时 7 秒；
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
	}
	else if (g_iSiHudTankClient == 0)
	{
		// 没收到 tank_spawn（或插件晚加载）：按"刷出"处理
		g_iSiHudTankClient = tank;
		g_iSiHudTankControl = SiHud_IsHumanTank(tank) ? 1 : 0;
		g_bSiHudTankSpawned = true;
		g_bSiHudTankDead = false;
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
			if (bHuman)
			{
				/* 上一任已经不再是坦克、这只坦克换成了真人控制 = 接管（二控）。
				   需求：二控要按当前坦克玩家重新计时 7 秒，所以走同一个坦克事件入口。
				   AI 接手（玩家掉线/放弃）不触发事件，只更新跟踪对象。 */
				g_iSiHudTankControl++;
				if (g_iSiHudTankControl > 2) g_iSiHudTankControl = 2;	// 面板只分一控/二控
				g_bSiHudTankSpawned = true;
				g_bSiHudTankDead = false;
				SiHud_OnTankEvent(tank, true);
			}
		}
	}

	// 女巫：只在"还没刷出过"时扫一次实体，扫到之后就不再扫
	if (!g_bSiHudWitchSpawned && FindEntityByClassname(-1, "witch") != -1)
	{
		g_bSiHudWitchSpawned = true;
		g_bSiHudWitchDead = false;
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
// 坦克事件（刷出 / 接管）统一入口
//   1) 除坦克玩家外的所有玩家：立刻关掉 tankhud（需求第 2 条）；
//   2) 除坦克玩家外的所有玩家：连续 2 秒强制显示面板（需求第 3 条）；
//   3) 坦克玩家：tankhud 先留着（sm_sihud_tank_delay，默认 7 秒，让他看自己的坦克血量），
//      到点由 Timer_SiHudTankRestore 关掉；这 7 秒里面板让位（g_fSiHudTankLockUntil），
//      但那 2 秒强制显示对他同样生效（需求第 4 条）。
//   bTakeover=true 表示同一只坦克被另一名玩家接管（二控）：按新的坦克玩家重新计时。
// ------------------------------------------------------------------------
void SiHud_OnTankEvent(int tank, bool bTakeover)
{
	if (SiHudEnable == null || !SiHudEnable.BoolValue) return;

	int delay = (SiHudTankDelay != null) ? SiHudTankDelay.IntValue : SIHUD_DEFAULT_TANK_DELAY;
	if (delay < 0) delay = 0;

	bool bHuman = SiHud_IsHumanTank(tank);

	// 1) 关掉所有玩家的 tankhud（有真人坦克玩家时他除外：他延迟 delay 秒才关）
	if (bHuman)
	{
		for (int client = 1; client <= MaxClients; client++)
		{
			if (!IsClientInGame(client) || IsFakeClient(client)) continue;
			if (client == tank) continue;
			SiHud_DisableTankHud(client);
		}
	}
	else
	{
		// AI 坦克：没有"扮演坦克的玩家"，所有人一起关
		SiHud_DisableTankHudAll();
	}

	// 2) 坦克玩家：tankhud 先留着，delay 秒后再关；这段时间面板让位
	if (bHuman)
	{
		g_fSiHudTankLockUntil[tank] = GetGameTime() + float(delay);
		g_bSiHudSent[tank] = false;
		g_bSiHudSeen[tank] = false;
		/* 不保存 timer 句柄：二控 / 同一玩家连着刷两次坦克时多出来的那个 timer
		   只会再关一次 tankhud、再刷一次面板，不会造成错乱；换图时由引擎统一回收。 */
		CreateTimer(float(delay), Timer_SiHudTankRestore, GetClientUserId(tank), TIMER_FLAG_NO_MAPCHANGE);
	}

	// 3) 除坦克玩家外的所有玩家：连续 2 秒强制显示
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!SiHud_CanSeePanel(client)) continue;
		if (bHuman && client == tank) continue;
		SiHud_ForceShowStart(client, SIHUD_FORCE_SECONDS);
	}
	// 4) 坦克玩家本人：同样强制显示 2 秒
	if (bHuman) SiHud_ForceShowStart(tank, SIHUD_FORCE_SECONDS);

	// 立刻画一拍（强制窗口的 timer 下一拍会接着画）
	SiHud_DrawFrame(true);

	if (SiHudDebug != null && SiHudDebug.BoolValue)
		LogMessage("[SV sihud] 坦克%s：tank=%d（%s，%d 控），坦克玩家 tankhud 延迟 %d 秒关，其它玩家强制显示 %.1f 秒。",
			bTakeover ? "接管" : "刷出", tank, bHuman ? "真人" : "AI", g_iSiHudTankControl, delay, SIHUD_FORCE_SECONDS);
}

// 关掉某名玩家的 tankhud（"坦克HUD" 由 spechud_appledmod 画；该插件不在时什么也不做）
void SiHud_DisableTankHud(int client)
{
	if (client <= 0 || client > MaxClients) return;
	if (!SiHud_SpecHudReady()) return;
	SpecHud_TankHudDisable(client);
}

// 一次关掉所有玩家的 tankhud（AI 坦克，没有"扮演坦克的玩家"时用）
void SiHud_DisableTankHudAll()
{
	if (!SiHud_SpecHudReady()) return;
	SpecHud_TankHudDisable(0);
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
//   玩家在窗口内按 ESC 或输入 !sihud 关闭 → SiHud_CancelForce 立刻取消窗口，不强抢屏幕。
// ------------------------------------------------------------------------
// 能不能看面板：游戏内、真人、非生还者（规则 B）
bool SiHud_CanSeePanel(int client)
{
	if (client <= 0 || client > MaxClients) return false;
	if (!IsClientInGame(client) || IsFakeClient(client)) return false;
	return GetClientTeam(client) != TEAM_SURVIVOR;
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
void SiHud_ForceShowAll(float seconds)
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!SiHud_CanSeePanel(client)) continue;
		SiHud_ForceShowStart(client, seconds);
	}
	SiHud_DrawFrame(true);
}

// 取消某人的强制窗口（玩家自己按 ESC / !sihud 关掉时调用）
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
//   手动关掉过的玩家同样会被强制这 2 秒（需求原文"所有玩家"），但他们随时可以按 ESC /
//   再输入 !sihud 立刻取消（SiHud_CancelForce）。
//   sm_sihud_force_show=0 时不做强制，只刷新已经开着面板的人（旧行为）。
// ------------------------------------------------------------------------
void SiHud_OnSurvivorLeftSafeArea()
{
	if (SiHudEnable == null || !SiHudEnable.BoolValue) return;

	// 本回合已经强制显示过 / 关掉了强制显示：只刷新，不再强开
	if (g_bSiHudAutoShownRound || SiHudForceShow == null || !SiHudForceShow.BoolValue)
	{
		SiHud_UpdatePanel();
		return;
	}

	g_bSiHudAutoShownRound = true;
	if (SiHudDebug != null && SiHudDebug.BoolValue)
		LogMessage("[SV sihud] 生还者首次离开安全区：对所有能看面板的玩家强制显示 %.1f 秒。", SIHUD_FORCE_SECONDS);

	SiHud_ForceShowAll(SIHUD_FORCE_SECONDS);
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
//   bForce=false：常规路径，只发给"自己开着面板"的玩家，遇到别人的菜单 / 玩家 ESC 都不抢；
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
			g_bSiHudSeen[client] = false;
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
			if (source == MenuSource_Normal || source == MenuSource_RawPanel)
			{
				if (!ours) continue;			// 别的插件的面板/内置投票还在显示
				// 还看得到我们自己的面板 → 记下"确实显示过"。这一步是为了不把
				// "引擎还没把面板画出来（玩家仍在加载）"误判成下面那条 ESC 判定。
				g_bSiHudSeen[client] = true;
			}

			// 面板本该还在显示，却已经从屏幕上没了 → 玩家自己关掉的（ESC）。
			// 需求 G：ESC 之后不要强制重开，开关就地置关。
			// 必须"之前确实见到过面板"（g_bSiHudSeen）才这么判，否则刚进服还在加载的玩家
			// 会被当成按了 ESC，自动补开的面板就永远出不来。
			if (source == MenuSource_None && ours && g_bSiHudSeen[client]
				&& (now - g_fSiHudLastSendAt[client]) < float(SIHUD_PANEL_SECONDS) - SIHUD_EARLY_CLOSE_SLACK)
			{
				g_bSiHudOn[client] = false;
				g_bSiHudSent[client] = false;
				g_bSiHudSeen[client] = false;
				if (SiHudDebug != null && SiHudDebug.BoolValue)
					LogMessage("[SV sihud] client=%d 面板提前消失（%.2f 秒 < %d 秒），判定为玩家关闭，开关置关。",
						client, now - g_fSiHudLastSendAt[client], SIHUD_PANEL_SECONDS);
				continue;
			}
		}

		g_bSiHudSent[client] = panel.Send(client, SiHud_PanelHandler, SIHUD_PANEL_SECONDS);
		if (g_bSiHudSent[client]) g_fSiHudLastSendAt[client] = now;
	}
	delete panel;
}

// ------------------------------------------------------------------------
// 面板回调：只处理"玩家自己按 ESC 退出面板"这一件事（需求 G：ESC 后不强制重开）
//   MenuCancel_Exit / MenuCancel_ExitBack = 玩家主动退出 → 开关置关、强制窗口一起取消；
//   MenuCancel_Interrupted = 被别的菜单顶掉、MenuCancel_Timeout = 显示时长到期
//   （我们每秒重发，到期属于正常刷新）、Disconnected → 都不当成"玩家关掉了"。
// ------------------------------------------------------------------------
int SiHud_PanelHandler(Handle menu, MenuAction action, int client, int param2)
{
	if (action == MenuAction_Cancel && (param2 == MenuCancel_Exit || param2 == MenuCancel_ExitBack))
	{
		if (client > 0 && client <= MaxClients)
		{
			bool bWasOn = g_bSiHudOn[client];
			g_bSiHudOn[client] = false;
			g_bSiHudSent[client] = false;
			// 强制窗口也必须一起取消，否则 0.25 秒后面板又被强制 timer 顶回来
			SiHud_CancelForce(client);
			if (bWasOn && SiHudDebug != null && SiHudDebug.BoolValue)
				LogMessage("[SV sihud] client=%d 按 ESC 关闭面板（reason=%d），开关置关。", client, param2);
		}
	}
	return 0;
}

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
// 内容：感染者段（感染者人数行 / 六行职业统计 / 两个刷新点路程百分比 / 最后两行 Tank、Witch）
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
	SiHud_FillSpawnFlowLines(panel);
	SiHud_DrawBossLines(panel);
}

// ------------------------------------------------------------------------
// 最后两行：Tank / Witch（需求）
//   · 坦克还没刷出：画"出生位置百分比"（见 SiHud_GetBossFlowPercent，数据源与 l4d_boss_percent 一致）；
//   · 坦克已经刷出：`Tank（<名字前2字符>* / AI） <剩余血量>（一控/二控）`；
//   · 坦克刷出过且已死亡：整行不画；
//   · 女巫同理：没刷出画百分比，刷出没死画"已生成"，刷出且已死整行不画。
// ------------------------------------------------------------------------
void SiHud_DrawBossLines(Panel panel)
{
	char line[96];
	int percent = 0;

	int tank = SiHud_FindTankClient();
	if (tank > 0)
	{
		int health = GetClientHealth(tank);
		if (health < 0) health = 0;

		if (IsFakeClient(tank))
		{
			// AI 坦克：名字位显示 AI，不显示一控/二控（没有真人控制）
			FormatEx(line, sizeof(line), "Tank（%s） %d", SIHUD_TXT_TANK_AI, health);
		}
		else
		{
			char shortName[32];
			SiHud_ShortName(tank, shortName, sizeof(shortName));
			FormatEx(line, sizeof(line), "Tank（%s） %d（%s）", shortName, health,
				(g_iSiHudTankControl >= 2) ? SIHUD_TXT_CTRL_SECOND : SIHUD_TXT_CTRL_FIRST);
		}
		SiHud_DrawText(panel, line);
	}
	else if (g_bSiHudTankSpawned && g_bSiHudTankDead)
	{
		// 已生成且已死亡 → 不画 Tank 行（需求）
	}
	else if (SiHud_GetBossFlowPercent(true, percent))
	{
		FormatEx(line, sizeof(line), "Tank：%d%%", percent);
		SiHud_DrawText(panel, line);
	}

	if (g_bSiHudWitchSpawned)
	{
		if (!g_bSiHudWitchDead)
		{
			FormatEx(line, sizeof(line), "Witch：%s", SIHUD_TXT_WITCH_ALIVE);
			SiHud_DrawText(panel, line);
		}
		// 已生成且已死亡 → 不画 Witch 行（需求）
	}
	else if (SiHud_GetBossFlowPercent(false, percent))
	{
		FormatEx(line, sizeof(line), "Witch：%d%%", percent);
		SiHud_DrawText(panel, line);
	}
}

// ------------------------------------------------------------------------
// Tank / Witch 的出生位置百分比（与 spechud_appledmod 的 GetRoundTankFlow / GetRoundWitchFlow、
// 以及 l4d_boss_percent 的算法完全一致）：
//   L4D2Direct_GetVSTankFlowPercent(round) 是 0..1 的小数（flow percent，不是距离），
//   ×100 之后再加上 versus_boss_buffer / 全图最大 flow 的余量 —— boss 实际会在稍晚一点的位置刷出。
//   round 0 = 上半场，1 = 下半场（GameRules 的 m_bInSecondHalfOfRound，非对抗模式按 0 处理）。
//   本回合这个 boss 不是按 flow 刷出的（静态/事件），或者 native 不可用 → 返回 false，不画百分比。
// ------------------------------------------------------------------------
bool SiHud_GetBossFlowPercent(bool bTank, int &percent)
{
	percent = 0;
	if (!g_bSiHudBossFlowNative) return false;
	// 下面几个 native 读的是对抗 Director 的 boss flow 数据，非对抗模式没有这个概念
	if (!L4D_IsVersusMode()) return false;

	int round = SiHud_IsSecondHalf() ? 1 : 0;
	if (bTank)
	{
		if (!L4D2Direct_GetVSTankToSpawnThisRound(round)) return false;
	}
	else
	{
		if (!L4D2Direct_GetVSWitchToSpawnThisRound(round)) return false;
	}

	float fraction = bTank ? L4D2Direct_GetVSTankFlowPercent(round)
		: L4D2Direct_GetVSWitchFlowPercent(round);

	// 需求「改成百分比」：不同 left4dhooks 版本这个 native 可能给 0..1 的小数，也可能直接给
	// 0..100 的百分数。先统一归一化到 0..1，再算百分比，避免后者被 clamp 成恒 100%。
	// （归一化必须放在加 buffer 之前：buffer / maxFlow 本身就是 0..1 的 flow 比例。）
	if (fraction > 1.0)
		fraction /= 100.0;

	float maxFlow = L4D2Direct_GetMapMaxFlowDistance();
	float buffer = (VersusBossBuffer != null) ? VersusBossBuffer.FloatValue : 0.0;
	if (maxFlow > 0.0) fraction += buffer / maxFlow;

	percent = RoundToNearest(fraction * 100.0);
	if (percent < 0) percent = 0;
	else if (percent > 100) percent = 100;
	return true;
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
// 两个特感刷新点的路程百分比
//   数据源：地图里的 info_zombie_spawn 点（每张图只扫一次，见 SiHud_EnsureSpawnFlows），
//   每个点用 L4D_GetNearestNavArea（退 L4D2Direct_GetTerrorNavArea）取 nav area，
//   再用 L4D2Direct_GetTerrorNavAreaFlow 换成 flow，百分比 = flow / 全图最大 flow × 100。
//   只显示"最远生还者前方最近的两个"点：已越过（flow <= 最远生还者 flow）的不显示。
//   数据不全时返回 false，一行都不画（不影响面板其它内容）。
// ------------------------------------------------------------------------
bool SiHud_FillSpawnFlowLines(Panel panel)
{
	SiHud_EnsureSpawnFlows();
	if (g_iSiHudSpawnCount <= 0) return false;
	if (!g_bSiHudMaxFlowNative) return false;

	float maxFlow = L4D2Direct_GetMapMaxFlowDistance();
	if (maxFlow <= 0.0) return false;

	float furthest;
	if (!SiHud_GetFurthestFlow(furthest)) return false;

	char line[64];
	int drawn = 0;
	for (int i = 0; i < g_iSiHudSpawnCount && drawn < SIHUD_SPAWN_LINES; i++)
	{
		// g_fSiHudSpawnFlow 已按 flow 升序排好，所以第一次命中的就是"前方最近的"两个点
		if (g_fSiHudSpawnFlow[i] <= furthest + SIHUD_SPAWN_AHEAD_EPS) continue;
		int percent = RoundToNearest(g_fSiHudSpawnFlow[i] / maxFlow * 100.0);
		if (percent < 0) percent = 0;
		else if (percent > 100) percent = 100;
		FormatEx(line, sizeof(line), "刷新点%d:%d%%", drawn + 1, percent);
		SiHud_DrawText(panel, line);
		drawn++;
	}
	return drawn > 0;
}

// 扫描并缓存地图 info_zombie_spawn 的 flow（每张图一次；nav mesh 没准备好时下次再试）
void SiHud_EnsureSpawnFlows()
{
	if (g_bSiHudSpawnScanned) return;

	if (!g_bSiHudNavFlowNative || (!g_bSiHudNearestNavNative && !g_bSiHudDirectNavNative)
		|| !g_bSiHudMaxFlowNative)
	{
		if (!g_bSiHudSpawnWarned)
		{
			g_bSiHudSpawnWarned = true;
			LogError("[SV sihud] Left4DHooks 缺少 nav area flow 相关 native，刷新点行不显示（面板其它行不受影响）。");
		}
		g_bSiHudSpawnScanned = true;	// 本图不再重试
		return;
	}

	// nav mesh 还没建好时全图最大 flow 会是 0，隔一秒再试；连续试满上限就放弃本图，
	// 避免"没有 flow 的地图"上每秒白扫一遍实体。
	if (L4D2Direct_GetMapMaxFlowDistance() <= 0.0)
	{
		if (++g_iSiHudSpawnAttempts < SIHUD_SPAWN_SCAN_ATTEMPTS) return;
		g_bSiHudSpawnScanned = true;
		if (SiHudDebug != null && SiHudDebug.BoolValue)
			LogError("[SV sihud] 本图取不到全图最大 flow，刷新点行不显示。");
		return;
	}

	g_iSiHudSpawnCount = 0;
	float origin[3];
	for (int entity = FindEntityByClassname(-1, "info_zombie_spawn");
		entity != -1 && g_iSiHudSpawnCount < SIHUD_MAX_SPAWNS;
		entity = FindEntityByClassname(entity, "info_zombie_spawn"))
	{
		if (!IsValidEntity(entity)) continue;
		GetEntPropVector(entity, Prop_Send, "m_vecOrigin", origin);

		Address area = Address_Null;
		// 先用可靠度更高的 L4D_GetNearestNavArea（anyZ=true，保证空中的刷怪点也能落到脚下 nav area）
		if (g_bSiHudNearestNavNative) area = L4D_GetNearestNavArea(origin, 500.0, true);
		if (area == Address_Null && g_bSiHudDirectNavNative) area = L4D2Direct_GetTerrorNavArea(origin);
		if (area == Address_Null) continue;

		float flow = L4D2Direct_GetTerrorNavAreaFlow(area);
		if (flow <= 0.0) continue;
		g_fSiHudSpawnFlow[g_iSiHudSpawnCount++] = flow;
	}
	if (g_iSiHudSpawnCount > 1) SortFloats(g_fSiHudSpawnFlow, g_iSiHudSpawnCount, Sort_Ascending);
	g_bSiHudSpawnScanned = true;

	if (SiHudDebug != null && SiHudDebug.BoolValue)
		LogMessage("[SV sihud] 本图 info_zombie_spawn 采样完成：%d 个有效刷新点。", g_iSiHudSpawnCount);
}

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
	g_bSiHudSeen[client] = false;
	g_fSiHudTankLockUntil[client] = 0.0;
	g_fSiHudLastSendAt[client] = 0.0;
	g_fSiHudForceUntil[client] = 0.0;
}

void SiHud_ResetAll()
{
	for (int client = 0; client <= MaxClients; client++) SiHud_ResetClient(client);
}

// 换图：清状态 + 让刷新点/坦克/女巫缓存失效
void SiHud_ResetMap()
{
	SiHud_ResetAll();
	g_bSiHudAutoShownRound = false;
	g_iSiHudSpawnCount = 0;
	g_iSiHudSpawnAttempts = 0;
	g_bSiHudSpawnScanned = false;
	g_hSiHudForceTimer = null;			// 强制 timer 带 TIMER_FLAG_NO_MAPCHANGE，换图时已被回收
	SiHud_ResetBossState();
	for (int i = 0; i < sizeof(g_bSiHudLimitMissLogged); i++) g_bSiHudLimitMissLogged[i] = false;
}

// 新回合：坦克让位窗口、强制显示窗口、本回合的自动显示机会一起重置
// （需求：这些"每回合一次"的东西都不跨回合）
void SiHud_ResetRound()
{
	g_bSiHudAutoShownRound = false;
	SiHud_ResetBossState();
	for (int client = 0; client <= MaxClients; client++)
	{
		g_fSiHudTankLockUntil[client] = 0.0;
		g_fSiHudForceUntil[client] = 0.0;
	}
}

// 坦克 / 女巫的"本回合刷出过没有 + 死了没有"状态
void SiHud_ResetBossState()
{
	g_iSiHudTankClient = 0;
	g_iSiHudTankControl = 0;
	g_bSiHudTankSpawned = false;
	g_bSiHudTankDead = false;
	g_bSiHudWitchSpawned = false;
	g_bSiHudWitchDead = false;
}

// Left4DHooks / 跨插件的 native 默认被标成 optional，
// 必须先探状态再用，否则版本偏旧时会抛 "Native is not bound"。
void SiHud_CheckNatives()
{
	g_bSiHudMaxFlowNative = SiHud_NativeAvailable("L4D2Direct_GetMapMaxFlowDistance");
	g_bSiHudClientFlowNative = SiHud_NativeAvailable("L4D2Direct_GetFlowDistance");
	g_bSiHudHighestNative = SiHud_NativeAvailable("L4D_GetHighestFlowSurvivor");
	g_bSiHudFurthestFlowNative = SiHud_NativeAvailable("L4D2_GetFurthestSurvivorFlow");
	g_bSiHudNavFlowNative = SiHud_NativeAvailable("L4D2Direct_GetTerrorNavAreaFlow");
	g_bSiHudNearestNavNative = SiHud_NativeAvailable("L4D_GetNearestNavArea");
	g_bSiHudDirectNavNative = SiHud_NativeAvailable("L4D2Direct_GetTerrorNavArea");
	g_bSiHudReadyUpNative = SiHud_NativeAvailable("IsInReady");
	// 最后两行 Tank / Witch 的出生百分比位置（4 个 native 全在才用，缺一个就不画百分比）
	g_bSiHudBossFlowNative = g_bSiHudMaxFlowNative
		&& SiHud_NativeAvailable("L4D2Direct_GetVSTankFlowPercent")
		&& SiHud_NativeAvailable("L4D2Direct_GetVSWitchFlowPercent")
		&& SiHud_NativeAvailable("L4D2Direct_GetVSTankToSpawnThisRound")
		&& SiHud_NativeAvailable("L4D2Direct_GetVSWitchToSpawnThisRound");
	// spechud_appledmod 的坦克HUD 关闭接口（不在场就关不掉 tankhud，面板其它功能不受影响）
	g_bSiHudSpecHudNative = SiHud_NativeAvailable("SpecHud_TankHudDisable");

	if (!g_bSiHudMaxFlowNative && SiHudDebug != null && SiHudDebug.BoolValue)
		LogError("[SV sihud] L4D2Direct_GetMapMaxFlowDistance 不可用：当前路程百分比与刷新点两行都不会显示。");
	if (!g_bSiHudSpecHudNative && SiHudDebug != null && SiHudDebug.BoolValue)
		LogError("[SV sihud] 找不到 spechud_appledmod 的 SpecHud_TankHudDisable：坦克刷出/接管时无法关闭 tankhud。");
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

	// 2.5.17：换到感染者时清掉身上残留的生还者武器（进服时引擎先给生还者席位、随后被换到特感的竞态）
	if (!IsFakeClient(client) && event.GetInt("team") == TEAM_INFECTED)
		StripSurvivorWeapons(client);
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
