#include <sourcemod>
#include <left4dhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "2.3.9-12v12"

#define TEAM_NONE      0
#define TEAM_SPECTATOR 1
#define TEAM_SURVIVOR  2
#define TEAM_INFECTED  3

// 独立日志文件（相对 addons/sourcemod，即 addons/sourcemod/logs/）
#define FIX_LOG_FILE "logs/l4d2_fix_team_shuffle_edi.log"

// ========== 主要状态变量 ==========

// 记录表：SteamID(Steam2) -> 记录时的队伍号（1旁观 2生还者 3特感）
StringMap g_hTeamRecords;
// 尚未还原成功的 SteamID 集合，g_iPendingCount 恒等于其 Size
StringMap g_hPendingRecords;
// final_map_disable=2 时，新章节随机打乱后的 SteamID -> 目标队伍
StringMap g_hShuffleTargets;
// 本次修复冻结下来的最终目标：SteamID -> 目标队伍（启动时算一次，执行期间不再重算）
StringMap g_hTargetTeams;
bool g_bTargetsFrozen;     // 目标是否已冻结（冻结后换边标志再变也不影响已定目标）
bool g_bTargetsFlipped;    // 冻结目标时用的换边标志，用于发现"冻早了"并重算
int g_iRestoredCount;      // 本次修复已经成功归位的人数（判断是否还能安全地重新冻结）
int g_iEvictBudget;        // 本次修复还允许"腾位/踢 AI"的次数上限，防止来回互踢
char g_sTargetsMap[64];    // 冻结目标时所在的地图，防止拿上一张图的目标去改这一张图的人

int g_iPendingCount;      // 尚未还原成功的人数
bool g_bTeamLock;         // 当前是否处于队伍锁定（还原进行中）
bool g_bMapTransition;    // 是否刚发生过记录，允许下一次地图开始时启动还原
bool g_bRoundEnd;         // 当前回合是否已经结束（事件去重）
bool g_bFinalMap;         // 当前地图是否为章节最后一关
bool g_bOldTeamFlipped;   // 记录时游戏规则的 m_bAreTeamsFlipped
bool g_bNewTeamFlipped;   // 新地图该属性值，两者不同即代表发生了换边
bool g_bRecordedAtRoundEnd;    // 记录是否由回合结束触发（回合结束游戏必换边；中途换图不换边）
bool g_bMapChangedSinceRecord; // 记录之后是否真的换过图（OnMapStart 消费换图标记时置位）
bool g_bShuffleMode;           // 本次还原是否使用"随机打乱"而不是按记录归位（final_map_disable=2/3）
bool g_bShuffleSmallLevel;     // 本次打乱是否由 final_map_disable=3（换小关卡就打乱）触发，仅影响公告/日志文案
int g_iShuffleTotal;           // 本次打乱参与人数（公告用）
int g_iShuffleSurvivors;       // 本次打乱后的生还者名额（公告用）
char g_sRecordedMap[64];       // 记录时所在的地图名（同图重开不算跨战役）

char g_sLogFile[PLATFORM_MAX_PATH]; // 独立日志文件的绝对路径（OnPluginStart 里生成）
int g_iRestoreStartTime;            // 本次修复开始的时间戳，日志里算耗时用
bool g_bFixStartLogged;             // 本次修复的"开始修复"表头是否已写过（防止重复）

bool g_bChecked[MAXPLAYERS + 1];      // 某玩家是否正在等待自己的还原计时器
int g_iFailureCount[MAXPLAYERS + 1];  // 某玩家还原失败的次数
bool g_bJoinTeamUsed[MAXPLAYERS + 1]; // 插件自己执行队伍转移期间临时放行 jointeam
int g_iNoAuthTicks[MAXPLAYERS + 1];   // 连续拿不到 SteamID 的秒数（非 Steam 客户端/授权未完成）

Handle g_hCheckTimer = INVALID_HANDLE;   // 5 秒检查计时器
Handle g_hTimeoutTimer = INVALID_HANDLE; // 超时兜底计时器
Handle g_hClientTimer[MAXPLAYERS + 1];   // 每个玩家的 1 秒还原计时器
Handle g_hStartTimer;                   // round_start / OnMapStart 共用的延迟启动
bool g_bMapReady;

bool g_bEventsHooked = false;
bool g_bVoteHooksInstalled = false;

GlobalForward g_hFwdFixComplete;

// ========== ConVar ==========

ConVar g_cvEnabled;
ConVar g_cvNotify;
ConVar g_cvNoVotes;
ConVar g_cvAttempts;
ConVar g_cvTime;
ConVar g_cvFinalMapDisable;
ConVar g_cvChangeMapDisable;
ConVar g_cvIgnoreOffline;
ConVar g_cvLog;
ConVar g_cvNoAuthSpectate;
ConVar g_hZMaxPlayerZombies;

bool g_bCvarEnabled;
bool g_bCvarNotify;
bool g_bCvarNoVotes;
int g_iCvarAttempts;
float g_fCvarTime;
int g_iCvarFinalMapDisable;   // final_map_disable 的整数取值（0/1/2）
bool g_bCvarChangeMapDisable;
bool g_bCvarIgnoreOffline;
bool g_bCvarLog;
bool g_bCvarNoAuthSpectate;   // 拿不到 SteamID 的玩家是否让到旁观（默认 1）
int g_iZMaxPlayerZombies;

// ========== Plugin Info ==========

public Plugin myinfo =
{
	name = "L4D2 - Fix team shuffle (12v12)",
	author = "Altair Sossai, edited by apples1949",
	description = "Restore versus teams after round transitions with team lock, per-player retry timers and bot takeover",
	version = PLUGIN_VERSION,
	url = "https://github.com/SirPlease/L4D2-Competitive-Rework"
};

// ========== API ==========

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	CreateNative("L4D2_FixTeamShuffle_Keep", Native_Keep);
	CreateNative("L4D2_FixTeamShuffle_Start", Native_Start);
	CreateNative("L4D2_FixTeamShuffle_Abort", Native_Abort);
	CreateNative("L4D2_FixTeamShuffle_IsFixComplete", Native_IsFixComplete);

	RegPluginLibrary("l4d2_fix_team_shuffle_edi");
	return APLRes_Success;
}

public any Native_Keep(Handle plugin, int numParams)
{
	KeepTeams(false);
	return 0;
}

public any Native_Start(Handle plugin, int numParams)
{
	// 手动启动不经过 Timer_StartRestore，表头在这里补
	if (StartProcess())
		LogFixStart();
	return 0;
}

public any Native_Abort(Handle plugin, int numParams)
{
	AbortProcess(GetNativeCell(1), "插件调用中止");
	return 0;
}

public any Native_IsFixComplete(Handle plugin, int numParams)
{
	return !IsRestoreLocked();
}

// ========== OnPluginStart ==========

public void OnPluginStart()
{
	LoadTranslations("l4d2_fix_team_shuffle_edi.phrases");

	g_hTeamRecords = new StringMap();
	g_hPendingRecords = new StringMap();
	g_hShuffleTargets = new StringMap();
	g_hTargetTeams = new StringMap();

	g_hFwdFixComplete = new GlobalForward("L4D2_FixTeamShuffle_OnFixComplete", ET_Ignore);

	g_hZMaxPlayerZombies = FindConVar("z_max_player_zombies");

	CreateConVar("l4d2_fix_team_shuffle_version", PLUGIN_VERSION,
		"插件版本（仅展示）", FCVAR_NOTIFY | FCVAR_DONTRECORD | FCVAR_SPONLY);

	g_cvNotify = CreateConVar("l4d2_fix_team_shuffle_notify", "1",
		"还原完成解锁时是否向所有玩家发送聊天公告（0=静默 1=公告）",
		FCVAR_NONE, true, 0.0, true, 1.0);

	g_cvNoVotes = CreateConVar("l4d2_fix_team_shuffle_novotes", "1",
		"启用插件时是否在锁队期间拦截玩家发起的 callvote / vote（0=不拦截 1=拦截）",
		FCVAR_NONE, true, 0.0, true, 1.0);

	// 与 l4d_team_unscramble 实际生效值一致：其源码声明默认 10 但上限 6，
	// SourceMod 会把默认值钳制到 6；这里直接使用 6，避免 readme/配置歧义。
	g_cvAttempts = CreateConVar("l4d2_fix_team_shuffle_attempts", "6",
		"每个玩家还原失败后的最大重试次数（1-6）。玩家未选队时无限等待，不消耗次数",
		FCVAR_NONE, true, 1.0, true, 6.0);

	g_cvTime = CreateConVar("l4d2_fix_team_shuffle_time", "45.0",
		"换图后还原处理的超时秒数，时间到强制解锁（最小 15 秒）",
		FCVAR_NONE, true, 15.0);

	g_cvEnabled = CreateConVar("l4d2_fix_team_shuffle_allow_fix", "1",
		"队伍修正总开关：0=不记录、不还原、不锁队；1=启用",
		FCVAR_NONE, true, 0.0, true, 1.0);

	g_bCvarNotify = g_cvNotify.BoolValue;
	g_bCvarNoVotes = g_cvNoVotes.BoolValue;
	g_iCvarAttempts = g_cvAttempts.IntValue;
	g_fCvarTime = g_cvTime.FloatValue;
	g_bCvarEnabled = g_cvEnabled.BoolValue;

	// 总开关创建后先按当前值挂/卸一次监听
	UM_OnPluginEnabled();

	g_cvNotify.AddChangeHook(OnCvarChange_Notify);
	g_cvNoVotes.AddChangeHook(OnCvarChange_NoVotes);
	g_cvAttempts.AddChangeHook(OnCvarChange_Attempts);
	g_cvTime.AddChangeHook(OnCvarChange_Time);
	g_cvEnabled.AddChangeHook(OnCvarChange_Enabled);

	g_cvFinalMapDisable = CreateConVar("l4d2_fix_team_shuffle_final_map_disable", "0",
		"0=章节最后一关结束仍记录队伍，下一章按记录还原（跨战役按换边处理）；1=章节最后一关结束不记录，下一章按游戏默认分边；2=仍记录队伍，但切换到新章节时把所有非旁观玩家重新随机打乱分队（手动 changelevel 与换图插件自动换图均生效；c6c7、c9c14 两条混图链组内换图不打乱）；3=仍记录队伍，且除同一张图重开外，任何换关都重新随机打乱分队（同战役内换关、c6c7 与 c9c14 混图链组内换图、跨战役换图、三方图换图均打乱）",
		FCVAR_NONE, true, 0.0, true, 3.0);

	g_cvChangeMapDisable = CreateConVar("l4d2_fix_team_shuffle_change_map_disable", "0",
		"为 1 时回合中途（未到回合结束）换图不记录队伍；0=记录并在新图还原（中途换图不发生换边，按原队伍还原）",
		FCVAR_NONE, true, 0.0, true, 1.0);

	g_cvIgnoreOffline = CreateConVar("l4d2_fix_team_shuffle_ignore_offline", "1",
		"为 1 时上一回合的玩家若已不在服务器中，忽略该玩家立即继续修正，不等待其重新进入",
		FCVAR_NONE, true, 0.0, true, 1.0);

	g_cvLog = CreateConVar("l4d2_fix_team_shuffle_log", "1",
		"是否把队伍记录与修复过程写入独立日志 addons/sourcemod/logs/l4d2_fix_team_shuffle_edi.log（0=不写 1=写）",
		FCVAR_NONE, true, 0.0, true, 1.0);

	g_cvNoAuthSpectate = CreateConVar("l4d2_fix_team_shuffle_no_auth_spectate", "1",
		"拿不到 SteamID 的玩家（非 Steam 客户端/授权未完成）是否让到旁观：1=让到旁观（默认，避免其占着队伍名额把该归位的人挤掉）；0=不处理，保持引擎分配的队伍",
		FCVAR_NONE, true, 0.0, true, 1.0);

	g_bCvarLog = g_cvLog.BoolValue;
	InitFixLogFile();

	//AutoExecConfig(true, "l4d2_fix_team_shuffle_edi");

	// 配置文件可能已覆盖默认值，重新读取并给这几个 ConVar 补挂变更钩子
	GetCvars();

	if (g_hZMaxPlayerZombies != null)
		g_hZMaxPlayerZombies.AddChangeHook(OnCvarChange_ZMax);

	g_cvFinalMapDisable.AddChangeHook(OnCvarChange_FinalMapDisable);
	g_cvChangeMapDisable.AddChangeHook(OnCvarChange_ChangeMapDisable);
	g_cvIgnoreOffline.AddChangeHook(OnCvarChange_IgnoreOffline);
	g_cvLog.AddChangeHook(OnCvarChange_Log);
	g_cvNoAuthSpectate.AddChangeHook(OnCvarChange_NoAuthSpectate);

	// jointeam 与 changelevel 监听始终存在；总开关关闭时因无锁队/记录函数
	// 直接返回而不产生效果。
	AddCommandListener(Command_JoinTeam, "jointeam");
	AddCommandListener(Command_Changelevel, "changelevel");

	RegAdminCmd("sm_fixteams_keep", Command_FixTeamsKeep, ADMFLAG_ROOT,
		"立即记录当前全部玩家的队伍，供下一次启动还原使用");
	RegAdminCmd("sm_fixteams_start", Command_FixTeamsStart, ADMFLAG_ROOT,
		"立即启动队伍还原（需要先 sm_fixteams_keep 记录）");
	RegAdminCmd("sm_fixteams_abort", Command_FixTeamsAbort, ADMFLAG_ROOT,
		"立即中止队伍还原并解锁（公告并触发完成前向）");
}

void GetCvars()
{
	g_iCvarFinalMapDisable = g_cvFinalMapDisable.IntValue;
	if (g_iCvarFinalMapDisable < 0 || g_iCvarFinalMapDisable > 3)
		g_iCvarFinalMapDisable = 0;
	g_bCvarChangeMapDisable = g_cvChangeMapDisable.BoolValue;
	g_bCvarIgnoreOffline = g_cvIgnoreOffline.BoolValue;
	g_bCvarLog = g_cvLog.BoolValue;
	g_bCvarNoAuthSpectate = g_cvNoAuthSpectate.BoolValue;

	if (g_hZMaxPlayerZombies != null)
		g_iZMaxPlayerZombies = g_hZMaxPlayerZombies.IntValue;
	else
		g_iZMaxPlayerZombies = 4;
}

public void OnCvarChange_Notify(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_bCvarNotify = convar.BoolValue;
}

public void OnCvarChange_NoVotes(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_bCvarNoVotes = convar.BoolValue;

	// 比 l4d_team_unscramble 更进一步：运行时单独切换 novotes 也会立即
	// 挂/卸投票监听，而不是要等总开关切换一次才生效。
	if (!g_bCvarEnabled)
		return;

	if (g_bCvarNoVotes)
		InstallVoteListeners();
	else
		RemoveVoteListeners();
}

public void OnCvarChange_Attempts(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_iCvarAttempts = convar.IntValue;
}

public void OnCvarChange_Time(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_fCvarTime = convar.FloatValue;
}

public void OnCvarChange_Enabled(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_bCvarEnabled = convar.BoolValue;

	// 静默清空记录表并解除锁定：不公告、不触发完成前向；
	// 正在运行的个人计时器会在下一次触发时因锁队标志为假而自行终止。
	if (g_bTeamLock)
		LogFixSummary("总开关被关闭");

	ClearVars();

	if (g_bCvarEnabled)
		UM_OnPluginEnabled();
	else
		UM_OnPluginDisabled();
}

public void OnCvarChange_FinalMapDisable(ConVar convar, const char[] oldValue, const char[] newValue)
{
	int value = convar.IntValue;
	if (value < 0 || value > 3)
	{
		convar.IntValue = 0;
		value = 0;
	}

	g_iCvarFinalMapDisable = value;
}

public void OnCvarChange_ChangeMapDisable(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_bCvarChangeMapDisable = convar.BoolValue;
}

public void OnCvarChange_IgnoreOffline(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_bCvarIgnoreOffline = convar.BoolValue;
}

public void OnCvarChange_Log(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_bCvarLog = convar.BoolValue;
}

public void OnCvarChange_NoAuthSpectate(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_bCvarNoAuthSpectate = convar.BoolValue;
}

public void OnCvarChange_ZMax(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_iZMaxPlayerZombies = convar.IntValue;
}

// ========== 事件 / 投票监听挂载与卸载 ==========

void UM_OnPluginEnabled()
{
	if (!g_bCvarEnabled)
		return;

	InstallVoteListeners();
	HookEvents();
}

void UM_OnPluginDisabled()
{
	RemoveVoteListeners();
	UnhookEvents();
	ClearVars();
}

void InstallVoteListeners()
{
	if (!g_bCvarNoVotes || g_bVoteHooksInstalled)
		return;

	AddCommandListener(Command_Vote, "callvote");
	AddCommandListener(Command_Vote, "vote");
	g_bVoteHooksInstalled = true;
}

void RemoveVoteListeners()
{
	if (!g_bVoteHooksInstalled)
		return;

	RemoveCommandListener(Command_Vote, "callvote");
	RemoveCommandListener(Command_Vote, "vote");
	g_bVoteHooksInstalled = false;
}

void HookEvents()
{
	if (g_bEventsHooked)
		return;

	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("round_end", Event_RoundEnd);
	HookEvent("map_transition", Event_RoundEnd);
	HookEvent("mission_lost", Event_RoundEnd);
	HookEvent("finale_vehicle_leaving", Event_RoundEnd);
	g_bEventsHooked = true;
}

void UnhookEvents()
{
	if (!g_bEventsHooked)
		return;

	UnhookEvent("round_start", Event_RoundStart);
	UnhookEvent("round_end", Event_RoundEnd);
	UnhookEvent("map_transition", Event_RoundEnd);
	UnhookEvent("mission_lost", Event_RoundEnd);
	UnhookEvent("finale_vehicle_leaving", Event_RoundEnd);
	g_bEventsHooked = false;
}

// ========== 阶段 A：记录队伍 KeepTeams ==========

public void L4D2_OnEndVersusModeRound_Post()
{
	OnVersusRoundEnd();
}

void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	OnVersusRoundEnd();
}

// round_end / map_transition / mission_lost / finale_vehicle_leaving 与
// L4D2_OnEndVersusModeRound_Post 都会走到这里；用 g_bRoundEnd 去重。
// 对抗模式每个回合结束后双方必然换边，因此记录实际队伍 + 换边对调与
// 原插件的胜方/负方名单映射等价。
void OnVersusRoundEnd()
{
	if (!g_bCvarEnabled || !L4D_IsVersusMode())
		return;

	// 最终关且 final_map_disable=1：直接返回，不记录
	// final_map_disable=2 仍需记录（新章节要按记录的人数规模随机打乱）
	if (g_bFinalMap && g_iCvarFinalMapDisable == 1)
		return;

	if (g_bRoundEnd)
		return;

	// 回合结束记录：游戏随后必然换边，跨战役时也按换边处理
	KeepTeams(true);
	g_bRoundEnd = true;
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	g_bRoundEnd = false;

	if (!g_bCvarEnabled || !L4D_IsVersusMode())
		return;

	// 同图第二半场不会触发 OnMapStart。延后一帧以上等待引擎完成换边，
	// 并为已经在线、不会再次触发 OnClientPutInServer 的玩家启动还原。
	ScheduleRestore();
}

public Action Command_Changelevel(int client, const char[] command, int argc)
{
	if (!g_bCvarEnabled || !L4D_IsVersusMode())
		return Plugin_Continue;

	// 最终关且 final_map_disable=1：放行，不记录（=2 仍需记录，供新章节打乱使用）
	if (g_bFinalMap && g_iCvarFinalMapDisable == 1)
		return Plugin_Continue;

	// 回合还没结束就换图（中途投票/管理员换图）且启用 change_map_disable：放行，不记录
	if (!g_bRoundEnd && g_bCvarChangeMapDisable)
		return Plugin_Continue;

	// 只有服务器控制台/插件通过 ServerCommand 执行 changelevel 才记录；
	// 玩家控制台直接执行 changelevel 不会被记录。
	if (client != 0)
		return Plugin_Continue;

	// 正常回合结束的换图已经由 Event_RoundEnd / L4D2_OnEndVersusModeRound_Post
	// 记录过（g_bRoundEnd 为真）；这里只兜底记录“事件未捕获”与“允许中途记录”的情况。
	if (!g_bRoundEnd)
	{
		// 中途换图：游戏不会换边，按原队伍还原
		KeepTeams(false);
		g_bRoundEnd = true;
	}

	return Plugin_Continue;
}

// roundEnded：本次记录是否由回合结束触发（回合结束游戏必换边，中途换图不换边）
// inGameOnly：只记录"确实在游戏中"的玩家（换图兜底记录用，避免读不到实体时把人记成旁观）
void KeepTeams(bool roundEnded = true, bool inGameOnly = false)
{
	if (!g_bCvarEnabled)
		return;

	// 放弃当前可能正在进行的还原（不触发完成前向），准备新的记录
	bool bInterruptedFix = g_bTeamLock;
	int iInterruptedPending = g_iPendingCount;

	CancelProcessTimers();
	ResetClientFlags();

	g_hTeamRecords.Clear();
	g_hPendingRecords.Clear();
	g_hShuffleTargets.Clear();
	g_hTargetTeams.Clear();
	g_bTargetsFrozen = false;
	g_iRestoredCount = 0;
	g_iEvictBudget = MaxClients;
	g_iPendingCount = 0;
	g_bTeamLock = false;
	g_bShuffleMode = false;
	g_bShuffleSmallLevel = false;
	g_bFixStartLogged = false;

	g_bOldTeamFlipped = view_as<bool>(GameRules_GetProp("m_bAreTeamsFlipped"));
	g_bMapTransition = true;

	g_bRecordedAtRoundEnd = roundEnded;
	g_bMapChangedSinceRecord = false;
	GetCurrentMap(g_sRecordedMap, sizeof(g_sRecordedMap));

	if (g_bCvarLog)
	{
		FixLog("===== %s：记录队伍 =====",
			roundEnded ? "回合结束" : (inGameOnly ? "换图前兜底" : "中途换图"));

		if (bInterruptedFix)
			FixLog("[修复] 上一轮修复尚未完成就被这次记录中断（剩余 %d 人未修复）", iInterruptedPending);

		FixLog("[记录] 地图=%s 换边标志=%d final_map_disable=%d",
			g_sRecordedMap, g_bOldTeamFlipped ? 1 : 0, g_iCvarFinalMapDisable);
	}

	bool connectedOnly = true;

	int iSurvivors = 0;
	int iInfected = 0;
	int iSpectators = 0;

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientConnected(client) || IsFakeClient(client))
			continue;

		int team;
		if (IsClientInGame(client))
		{
			team = GetClientTeam(client);

			// 队伍为 0 或大于 3 的玩家跳过，换图后按未记录玩家处理（赶去旁观）
			if (team <= TEAM_NONE || team > TEAM_INFECTED)
				continue;

			// 旁观且正在挂机托管生还者 Bot：按生还者记录
			if (team == TEAM_SPECTATOR && IsClientIdle(client))
				team = TEAM_SURVIVOR;
		}
		else
		{
			// 尚未进游戏但已连接的玩家默认记为旁观；
			// 换图兜底记录时改为跳过：此时可能读不到实体，记成旁观会把玩家误送去旁观
			if (inGameOnly)
				continue;

			team = TEAM_SPECTATOR;
		}

		char auth[MAX_AUTHID_LENGTH];
		if (!GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth)))
			continue;

		if (team != TEAM_SPECTATOR)
			connectedOnly = false;

		g_hTeamRecords.SetValue(auth, team);
		g_hPendingRecords.SetValue(auth, true);

		// 日志：本次记录到的每个玩家（名字 + SteamID + 队伍）
		if (g_bCvarLog)
		{
			char sTeamLabel[16];
			GetTeamLabel(team, sTeamLabel, sizeof(sTeamLabel));

			char sName[MAX_NAME_LENGTH];
			if (!GetClientName(client, sName, sizeof(sName)))
				strcopy(sName, sizeof(sName), "未知玩家");

			FixLog("[记录] %s (%s) 队伍=%s%s", sName, auth, sTeamLabel,
				(team == TEAM_SURVIVOR && GetClientTeam(client) == TEAM_SPECTATOR) ? "（挂机托管，按生还者记录）" : "");
		}

		if (team == TEAM_SURVIVOR)
			iSurvivors++;
		else if (team == TEAM_INFECTED)
			iInfected++;
		else
			iSpectators++;
	}

	// 全场都在旁观或尚未进游戏：丢弃记录，避免空场锁队
	if (connectedOnly)
	{
		g_hTeamRecords.Clear();
		g_hPendingRecords.Clear();
	}

	g_iPendingCount = g_hPendingRecords.Size;

	if (g_bCvarLog)
	{
		FixLog("[记录] 生还者=%d 人 特感=%d 人 旁观=%d 人 合计=%d 人",
			iSurvivors, iInfected, iSpectators, g_iPendingCount);

		if (connectedOnly)
			FixLog("[记录] 全场没有已入队的玩家，已丢弃本次记录（不锁队）");
	}
}

// ========== 阶段 C：冻结目标队伍 ==========

/* 为什么必须冻结：
   个人还原计时器是"每人每秒各自跑一次"，不同玩家会在 1s、2s、3s… 陆续完成。
   若在每次计时器里重读 m_bAreTeamsFlipped 再算 IsTeamSwapped()，一旦引擎在还原
   过程中才完成换边（换图/半场重开/跨战役都会出现），先完成的玩家按"未换边"归位、
   后完成的按"已换边"归位 —— 同一队的人被拆到两边，表现就是"修复不对"。
   现在改为启动时按当时的换边判定算一次最终目标，执行期间只查表、不再重算。 */
void FreezeTargets()
{
	g_hTargetTeams.Clear();
	g_bTargetsFrozen = false;

	bool bSwapped = IsTeamSwapped();

	StringMapSnapshot snapshot = g_hTeamRecords.Snapshot();
	char sAuth[MAX_AUTHID_LENGTH];
	int iRecorded;
	int iSurvivors = 0;
	int iInfected = 0;
	int iSpectators = 0;

	for (int i = 0; i < snapshot.Length; i++)
	{
		snapshot.GetKey(i, sAuth, sizeof(sAuth));
		if (!g_hTeamRecords.GetValue(sAuth, iRecorded))
			continue;

		int target = iRecorded;

		// 打乱模式优先用打乱表；否则按换边对调
		if (g_bShuffleMode)
		{
			int shuffleTeam;
			if (g_hShuffleTargets.GetValue(sAuth, shuffleTeam))
				target = shuffleTeam;
		}
		else if (bSwapped)
		{
			if (target == TEAM_SURVIVOR)
				target = TEAM_INFECTED;
			else if (target == TEAM_INFECTED)
				target = TEAM_SURVIVOR;
		}

		g_hTargetTeams.SetValue(sAuth, target);

		if (target == TEAM_SURVIVOR)
			iSurvivors++;
		else if (target == TEAM_INFECTED)
			iInfected++;
		else
			iSpectators++;

		if (g_bCvarLog)
		{
			char sRecorded[16], sTarget[16];
			GetTeamLabel(iRecorded, sRecorded, sizeof(sRecorded));
			GetTeamLabel(target, sTarget, sizeof(sTarget));

			int owner = FindClientBySteamId(sAuth);
			if (owner > 0)
			{
				char sName[MAX_NAME_LENGTH];
				if (!GetClientName(owner, sName, sizeof(sName)))
					strcopy(sName, sizeof(sName), "未知玩家");
				FixLog("[目标] %s (%s) 记录=%s -> 目标=%s", sName, sAuth, sRecorded, sTarget);
			}
			else
			{
				FixLog("[目标] %s 记录=%s -> 目标=%s（当前不在服务器）", sAuth, sRecorded, sTarget);
			}
		}
	}

	delete snapshot;

	g_bTargetsFrozen = true;
	g_bTargetsFlipped = bSwapped;
	g_iEvictBudget = MaxClients;
	GetCurrentMap(g_sTargetsMap, sizeof(g_sTargetsMap));

	FixLog("[目标] 已冻结 %d 人：生还者 %d / 特感 %d / 旁观 %d（换边=%d，打乱=%d）",
		g_hTargetTeams.Size, iSurvivors, iInfected, iSpectators,
		bSwapped ? 1 : 0, g_bShuffleMode ? 1 : 0);
}

/* 取某个 SteamID 本次修复的目标队伍。
   已冻结就只查表；未冻结（异常路径）退回按记录 + 当前状态实时计算，
   避免"没冻结就全员被当成未记录"这种灾难性回归。 */
bool ResolveTargetTeam(const char[] auth, int &targetTeam)
{
	if (g_bTargetsFrozen)
	{
		// 冻结目标是"某张图那一次"的结论：已经换到别的图就作废，
		// 退回下面的实时计算，绝不能拿上一张图的目标去改这一张图的人
		char sMap[64];
		GetCurrentMap(sMap, sizeof(sMap));
		if (strcmp(sMap, g_sTargetsMap, false) == 0)
			return g_hTargetTeams.GetValue(auth, targetTeam);
	}

	int recorded;
	if (!g_hTeamRecords.GetValue(auth, recorded))
		return false;

	targetTeam = recorded;

	if (g_bShuffleMode)
	{
		int shuffleTeam;
		if (g_hShuffleTargets.GetValue(auth, shuffleTeam))
			targetTeam = shuffleTeam;
	}
	else if (IsTeamSwapped())
	{
		if (targetTeam == TEAM_SURVIVOR)
			targetTeam = TEAM_INFECTED;
		else if (targetTeam == TEAM_INFECTED)
			targetTeam = TEAM_SURVIVOR;
	}

	return true;
}

// ========== 阶段 B：新地图启动还原 ==========

public void OnMapStart()
{
	g_bMapReady = true;
	g_bFinalMap = L4D_IsMissionFinalMap();

	PrecacheSurvivorModels();

	if (!g_bCvarEnabled)
	{
		g_bMapTransition = false;
		return;
	}

	// 本插件只自动处理对抗模式的回合换图；非对抗模式丢弃任何残留的自动记录
	if (!L4D_IsVersusMode())
	{
		AbortProcess(false, "非对抗模式");
		g_bMapTransition = false;
		return;
	}

	// 换图时若上一次还原仍在锁队、但本次没有新的记录（例如中途换图被
	// change_map_disable 放行），必须静默解锁，避免锁队标志永久残留。
	if (g_bTeamLock && !g_bMapTransition)
		AbortProcess(false, "本次没有新记录，清除残留锁队");

	// 本图确实是由上一张图换过来的（KeepTeams 置位、Start 消费）：跨战役判定的前提
	if (g_bMapTransition)
		g_bMapChangedSinceRecord = true;

	ScheduleRestore();
}

public void OnMapEnd()
{
	g_bMapReady = false;
	// 兜底记录：地图要换了，但本次没走"回合结束记录"——换图插件/管理员用
	// ForceChangeLevel、或引擎自动过关都不经过 changelevel 命令监听。
	// 仅在允许中途记录时补一次；读不到实体就放弃（宁可不记录，也不能记错）。
	if (g_bCvarEnabled && L4D_IsVersusMode() && !g_bRoundEnd && !g_bCvarChangeMapDisable
		&& !(g_bFinalMap && g_iCvarFinalMapDisable == 1))
	{
		KeepTeams(false, true);

		if (g_iPendingCount > 0)
			LogMessage("[队伍修正] 换图前兜底记录 %d 人（本次未走回合结束）", g_iPendingCount);
	}

	// NO_MAPCHANGE 计时器在换图时被引擎销毁，句柄不再有效
	g_hCheckTimer = INVALID_HANDLE;
	g_hTimeoutTimer = INVALID_HANDLE;
	g_hStartTimer = null;

	for (int client = 1; client <= MaxClients; client++)
	{
		g_hClientTimer[client] = INVALID_HANDLE;
		g_bChecked[client] = false;
		g_iFailureCount[client] = 0;
		g_bJoinTeamUsed[client] = false;
	}
}

bool IsRestoreLocked()
{
	return g_bTeamLock || g_hStartTimer != null;
}

void ScheduleRestore()
{
	if (!g_bMapReady || !g_bCvarEnabled || !g_bMapTransition || g_iPendingCount <= 0
		|| g_bTeamLock || g_hStartTimer != null)
		return;
	g_hStartTimer = CreateTimer(0.5, Timer_StartRestore, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_StartRestore(Handle timer)
{
	if (timer != g_hStartTimer)
		return Plugin_Stop;
	g_hStartTimer = null;
	// 自动还原不在刚开始加载地图时删除暂未连接的记录，留给 5 秒检查器。
	if (g_bMapReady && StartProcess(false))
	{
		// StartProcess 里已经做过 PrepareShuffleMode + FreezeTargets，
		// 打乱/换边结论已定、每人目标已冻结，表头在这里补写
		LogFixStart();
	}
	return Plugin_Stop;
}

// 启动条件：有记录且刚换图。成功后锁队并创建 5 秒检查与超时兜底计时器。
bool Start()
{
	if (g_iPendingCount <= 0 || !g_bMapTransition)
		return false;

	if (!g_bTeamLock)
	{
		g_bTeamLock = true;

		CancelProcessTimers();
		// 2.3.9：完成检查 5s -> 1s，配合 0.2s 的换队重试，整批归位能在开打前收尾
		g_hCheckTimer = CreateTimer(1.0, Timer_CheckConnected, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
		g_hTimeoutTimer = CreateTimer(g_fCvarTime, Timer_AllowTeamChanges, _, TIMER_FLAG_NO_MAPCHANGE);
	}
	else
	{
		// 已经锁队（例如管理员连续调用 Start）：只补建换图时被销毁的计时器
		if (g_hCheckTimer == INVALID_HANDLE)
			g_hCheckTimer = CreateTimer(1.0, Timer_CheckConnected, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

		if (g_hTimeoutTimer == INVALID_HANDLE)
			g_hTimeoutTimer = CreateTimer(g_fCvarTime, Timer_AllowTeamChanges, _, TIMER_FLAG_NO_MAPCHANGE);
	}

	// 启动成功即消费换图标记：OnMapStart 与管理员/Native Start 两条路径行为一致
	g_bMapTransition = false;

	return true;
}

// 管理员命令 / Native 使用的完整启动：启动成功后立即更新换边标志，
// 并给所有已在游戏内的人类玩家补发个人还原计时器。
bool StartProcess(bool pruneOffline = true)
{
	if (!g_bCvarEnabled || !L4D_IsVersusMode())
		return false;
	delete g_hStartTimer;
	if (pruneOffline && g_bCvarIgnoreOffline)
		DropOfflineTeams();

	if (!Start())
		return false;

	g_bNewTeamFlipped = view_as<bool>(GameRules_GetProp("m_bAreTeamsFlipped"));

	// 打乱判定 + 目标冻结必须在给玩家发计时器之前完成：
	// 个人计时器只查冻结表，若这里漏了冻结，执行期间就会退回实时计算（目标漂移）
	PrepareShuffleMode();
	FreezeTargets();

	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client) && !IsFakeClient(client) && !g_bChecked[client])
			StartClientRestore(client);
	}

	return true;
}

public void OnClientPutInServer(int client)
{
	// 双保险：进服时先清空该 client index 可能残留的旧状态，
	// 避免 client index 复用导致新玩家被旧 checked 标记跳过。
	StopClientRestoreTimer(client);
	g_bChecked[client] = false;
	g_iFailureCount[client] = 0;
	g_bJoinTeamUsed[client] = false;
	g_iNoAuthTicks[client] = 0;

	if (!g_bTeamLock || IsFakeClient(client))
		return;

	StartClientRestore(client);
}

public void OnClientDisconnect(int client)
{
	if (client <= 0 || client > MaxClients)
		return;

	StopClientRestoreTimer(client);
	g_bChecked[client] = false;
	g_iFailureCount[client] = 0;
	g_bJoinTeamUsed[client] = false;
	g_iNoAuthTicks[client] = 0;
}

void StartClientRestore(int client)
{
	StopClientRestoreTimer(client);

	g_bChecked[client] = true;
	g_iFailureCount[client] = 0;

	// 2.3.9：重试间隔 1.0s -> 0.2s。
	// 12v12 满员时换队要靠"腾位→下一个 tick 落位"，1 秒一次会让整队 swap 拖成几十秒，
	// 玩家观感就是"开打半天了才被换走"。0.2s 一次后整批人 1~3 秒内就能归位。
	Handle timer = CreateTimer(0.2, Timer_RestoreClient, GetClientUserId(client), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	if (timer == INVALID_HANDLE)
	{
		// 计时器创建失败：不要留下永远为真的 checked 标记
		g_bChecked[client] = false;
		return;
	}

	g_hClientTimer[client] = timer;
}

void StopClientRestoreTimer(int client)
{
	if (client <= 0 || client > MaxClients)
		return;

	if (g_hClientTimer[client] != INVALID_HANDLE)
	{
		KillTimer(g_hClientTimer[client]);
		g_hClientTimer[client] = INVALID_HANDLE;
	}
}

// 单玩家还原计时器：每 1 秒检查一次，直到成功、放弃或整体解锁
public Action Timer_RestoreClient(Handle timer, any data)
{
	int client = GetClientOfUserId(data);

	if (!g_bTeamLock || client <= 0 || client > MaxClients
		|| !IsClientInGame(client) || IsFakeClient(client))
	{
		if (client > 0 && client <= MaxClients)
		{
			g_hClientTimer[client] = INVALID_HANDLE;
			g_bChecked[client] = false;
			g_iFailureCount[client] = 0;
		}
		return Plugin_Stop;
	}

	int currentTeam = GetClientTeam(client);

	// 队伍为 0 或未完成选队：无限等待，不消耗失败次数
	if (currentTeam < TEAM_SPECTATOR || currentTeam > TEAM_INFECTED)
		return Plugin_Continue;

	char auth[MAX_AUTHID_LENGTH];
	if (!GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth)))
	{
		/* 拿不到 SteamID（非 Steam 客户端 / 授权还没完成）⇒ 无法与记录表比对。
		   以前这里直接返回 Plugin_Continue：这种玩家既不会被当成"换图后新加入"
		   赶去旁观，也不会被腾位逻辑选中，却实实在在占着一个真人名额，
		   12v12 满员时就把本该归位的人挤在旁观里
		   （2026-10-24 23:06 c2m4_barns：无 SteamID 的 JOJO 占了生还者第 12 席，
		   apples1949 一直回不去）。
		   现在给 5 秒授权宽限，之后按"不在记录中"处理：先移到旁观腾出名额；
		   计时器不结束，万一之后授权到位、能对上记录，再按正常流程归位。 */
		g_iNoAuthTicks[client]++;

		// 开关关闭（l4d2_fix_team_shuffle_no_auth_spectate 0）：不处理，
		// 保持引擎分配的队伍（即修复前的旧行为）
		if (!g_bCvarNoAuthSpectate)
			return Plugin_Continue;

		if (g_iNoAuthTicks[client] > 5)
		{
			// 旁观里挂机托管着生还者 Bot 同样占名额：先接管回来，再退回旁观
			if (currentTeam == TEAM_SPECTATOR && IsClientIdle(client))
			{
				L4D_TakeOverBot(client);

				if (g_bCvarLog)
					FixLogClient(client, "修复：拿不到 SteamID 且正挂机托管 Bot，先接管解除托管");
			}

			if (GetClientTeam(client) != TEAM_SPECTATOR)
			{
				g_bJoinTeamUsed[client] = true;
				ChangeClientTeam(client, TEAM_SPECTATOR);
				g_bJoinTeamUsed[client] = false;

				// 玩家视角的提示：突然被移出队伍必须给个原因
				PrintToChat(client, "\x04[队伍修正]\x01 读不到你的 SteamID，无法核对队伍记录，先把你放到旁观；解锁后可以自行选队。");

				if (g_bCvarLog)
				{
					char sBefore[16], sAfter[16];
					GetTeamLabel(currentTeam, sBefore, sizeof(sBefore));
					GetTeamLabel(GetClientTeam(client), sAfter, sizeof(sAfter));

					FixLogClient(client, "修复：拿不到 SteamID，无法核对记录，%s -> %s", sBefore, sAfter);
				}
			}
		}

		return Plugin_Continue;
	}

	// 授权已到位：清空宽限计数
	g_iNoAuthTicks[client] = 0;

	// 本轮的换边目标在延迟启动时冻结；不能在不同玩家的重试之间改变目标。

	/* 防"冻早了"：个别地图/模式引擎比 0.5 秒更晚才翻转 m_bAreTeamsFlipped。
	   只要还没有任何人成功归位（没人被移动过），发现标志变了就重新冻结一次，
	   避免整队人一致地错到同一侧；一旦有人归位就不再改，防止来回翻。 */
	if (g_bTargetsFrozen && g_iRestoredCount == 0)
	{
		bool bNowFlipped = view_as<bool>(GameRules_GetProp("m_bAreTeamsFlipped"));
		if (bNowFlipped != g_bTargetsFlipped)
		{
			g_bNewTeamFlipped = bNowFlipped;

			if (g_bCvarLog)
				FixLog("[目标] 换边标志在冻结后才变成 %d，重新冻结目标（尚未有人归位）",
					bNowFlipped ? 1 : 0);

			FreezeTargets();
		}
	}

	int targetTeam;
	if (!ResolveTargetTeam(auth, targetTeam))
	{
		// 记录表中查不到 = 换图后才新加入的玩家：一次性赶去旁观
		bool isIdle = (currentTeam == TEAM_SPECTATOR && IsClientIdle(client));

		g_bJoinTeamUsed[client] = true;
		if (isIdle)
			L4D_TakeOverBot(client);
		if (GetClientTeam(client) != TEAM_SPECTATOR)
			ChangeClientTeam(client, TEAM_SPECTATOR);
		g_bJoinTeamUsed[client] = false;

		if (g_bCvarLog)
		{
			char sBefore[16], sAfter[16];
			GetTeamLabel(currentTeam, sBefore, sizeof(sBefore));
			GetTeamLabel(GetClientTeam(client), sAfter, sizeof(sAfter));

			FixLogClient(client, "修复：不在记录中，%s -> %s（换图后新加入）", sBefore, sAfter);
		}

		g_hClientTimer[client] = INVALID_HANDLE;
		g_bChecked[client] = false;
		return Plugin_Stop;
	}

	// 打乱目标与"换边对调"都已在 FreezeTargets 里算进 g_hTargetTeams，
	// 这里不再重算，直接用查表结果（避免执行期间目标漂移）

	bool isIdle = (currentTeam == TEAM_SPECTATOR && IsClientIdle(client));

	// 已在目标队伍即完成；唯一例外：目标旁观但玩家正挂机托管 Bot，
	// 需要先接管 Bot 再回旁观（与 l4d_team_unscramble 的组合转移逻辑一致）。
	if (currentTeam == targetTeam && !(targetTeam == TEAM_SPECTATOR && isIdle))
	{
		if (g_bCvarLog)
		{
			char sCurrent[16], sTarget[16];
			GetTeamLabel(currentTeam, sCurrent, sizeof(sCurrent));
			GetTeamLabel(targetTeam, sTarget, sizeof(sTarget));

			FixLogClient(client, "修复：当前队伍 %s 已是目标 %s，无需移动", sCurrent, sTarget);
		}

		MarkClientRestored(client);
		g_hClientTimer[client] = INVALID_HANDLE;
		return Plugin_Stop;
	}

	bool attemptedMove = false;

	// 插件自己的转移操作临时放行 jointeam
	g_bJoinTeamUsed[client] = true;

	if (targetTeam == TEAM_SPECTATOR)
	{
		if (isIdle)
			L4D_TakeOverBot(client);

		if (GetClientTeam(client) != TEAM_SPECTATOR)
			ChangeClientTeam(client, TEAM_SPECTATOR);

		attemptedMove = true;
	}
	else if (targetTeam == TEAM_SURVIVOR)
	{
		if (currentTeam == TEAM_SPECTATOR)
		{
			attemptedMove = TurnClientToSurvivors(client, isIdle);
		}
		else if (currentTeam == TEAM_INFECTED)
		{
			// 先转旁观再找 Bot 接管
			ChangeClientTeam(client, TEAM_SPECTATOR);
			attemptedMove = true;
			TurnClientToSurvivors(client, false);
		}
	}
	else if (targetTeam == TEAM_INFECTED)
	{
		attemptedMove = TurnClientToInfected(client);
	}

	g_bJoinTeamUsed[client] = false;

	/* 满员死锁破局：这一步没能移动（目标队没空位、也没 Bot 可接管）时，
	   先把一个"本该离开这支队伍"的待修复玩家让到旁观腾出名额，
	   下个 tick 双方就都能各自落位。 */
	if (!attemptedMove && (targetTeam == TEAM_SURVIVOR || targetTeam == TEAM_INFECTED))
		TryEvictFromTeam(targetTeam, client, currentTeam);

	int iTeamAfterMove = GetClientTeam(client);

	if (g_bCvarLog && iTeamAfterMove != currentTeam)
	{
		char sBefore[16], sAfter[16], sTarget[16], sMode[128];
		GetTeamLabel(currentTeam, sBefore, sizeof(sBefore));
		GetTeamLabel(iTeamAfterMove, sAfter, sizeof(sAfter));
		GetTeamLabel(targetTeam, sTarget, sizeof(sTarget));
		GetFixModeLabel(sMode, sizeof(sMode));

		FixLogClient(client, "修复：移动 %s -> %s（目标=%s，模式=%s）", sBefore, sAfter, sTarget, sMode);
	}

	if (iTeamAfterMove == targetTeam
		&& !(targetTeam == TEAM_SPECTATOR && IsClientIdle(client)))
	{
		// 走到这里且移动前后队伍相同，只可能是"目标旁观 + 正在挂机托管"：
		// 先接管 Bot 再退回旁观，队伍号不变但确实执行了转移
		if (g_bCvarLog && iTeamAfterMove == currentTeam)
			FixLogClient(client, "修复：接管 Bot 后退回旁观（目标=旁观）");

		MarkClientRestored(client);
		g_hClientTimer[client] = INVALID_HANDLE;
		return Plugin_Stop;
	}

	// 只有执行了转移但队伍仍不对才计数；找不到 Bot / 特感名额已满时
	// 不消耗次数，继续一秒后重试，交给 attempts 上限或超时兜底。
	if (attemptedMove)
	{
		g_iFailureCount[client]++;

		if (g_iFailureCount[client] >= g_iCvarAttempts)
		{
			if (g_bCvarLog)
			{
				char sCurrent[16], sTarget[16];
				GetTeamLabel(iTeamAfterMove, sCurrent, sizeof(sCurrent));
				GetTeamLabel(targetTeam, sTarget, sizeof(sTarget));

				FixLogClient(client, "修复失败：重试 %d 次仍未到达目标 %s（当前 %s），放弃该玩家",
					g_iCvarAttempts, sTarget, sCurrent);
			}

			// 放弃该玩家；5 秒检查器会把其 checked 标记视为已完成并整体解锁
			g_hClientTimer[client] = INVALID_HANDLE;
			g_bChecked[client] = false;
			g_iFailureCount[client] = 0;
			return Plugin_Stop;
		}
	}

	return Plugin_Continue;
}

void MarkClientRestored(int client)
{
	g_bChecked[client] = false;
	g_iFailureCount[client] = 0;
	g_iRestoredCount++;

	char auth[MAX_AUTHID_LENGTH];
	if (GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth))
		&& g_hPendingRecords.Remove(auth)
		&& g_iPendingCount > 0)
	{
		g_iPendingCount--;
	}

	if (g_iPendingCount <= 0)
		ForceToUnlock("全部玩家已归位");
}

// 本张图是否为跨战役换图后的新战役：换到了别的地图，且新图是所在战役的第一关。
// 同一张图重开（半场重打同一关）不算跨战役。
bool IsNewCampaignMap()
{
	char sMap[64];
	GetCurrentMap(sMap, sizeof(sMap));
	if (strcmp(sMap, g_sRecordedMap, false) == 0)
		return false;

	return L4D_IsFirstMapInScenario();
}

// 取地图所属的"战役组"：混图流程把两段战役接成一条链，
// c6/c7（短暂时刻→牺牲）、c9/c14（坠机险途→背水一战）组内换图算同一章节。
// 只识别官方 c<数字>m<数字> 命名；其他地图（三方图）返回 false。
bool GetCampaignChain(const char[] sMap, char[] sChain, int iMaxLen)
{
	if (sMap[0] != 'c' && sMap[0] != 'C')
		return false;

	// 形如 c<数字>m<数字>_<名称>：截到 'm' 之前
	int iLen = 0;
	while (sMap[iLen] != 0 && sMap[iLen] != 'm' && sMap[iLen] != 'M' && iLen < 15)
	{
		if (iLen > 0 && (sMap[iLen] < '0' || sMap[iLen] > '9'))
			return false;
		iLen++;
	}

	// 'm' 之后必须紧跟一位地图编号数字，否则不是标准命名
	if (iLen < 2 || (sMap[iLen] != 'm' && sMap[iLen] != 'M')
		|| sMap[iLen + 1] < '0' || sMap[iLen + 1] > '9')
		return false;

	char sCampaign[16];
	strcopy(sCampaign, sizeof(sCampaign), sMap);
	sCampaign[iLen] = 0;

	if (strcmp(sCampaign, "c6", false) == 0 || strcmp(sCampaign, "c7", false) == 0)
		strcopy(sChain, iMaxLen, "c6c7");
	else if (strcmp(sCampaign, "c9", false) == 0 || strcmp(sCampaign, "c14", false) == 0)
		strcopy(sChain, iMaxLen, "c9c14");
	else
		strcopy(sChain, iMaxLen, sCampaign);

	return true;
}

// 本次换图是否切到了"新的章节"：按战役组比较，而不是按"是否战役第一关"。
//   · 战役组不同（c2m5 -> c3m1、c1m5 -> c2m1、手动跳到别的战役）=> 新章节
//   · 战役组相同且属于混图链 c6c7 / c9c14 => 同一章节，不打乱
//   · 战役组相同的一局结束了又回到本战役第一关（c1m5 -> c1m1）=> 视为新一局，打乱
//   · 三方图命名无法解析 => 退回引擎判定（新图是所在战役第一关即算新章节）
bool IsNewChapterSwitch()
{
	char sCurrentMap[64];
	GetCurrentMap(sCurrentMap, sizeof(sCurrentMap));

	// 同一张图重开（半场重打 / 重载当前关）不算新章节
	if (strcmp(sCurrentMap, g_sRecordedMap, false) == 0)
		return false;

	char sOldChain[32], sNewChain[32];
	bool bOldKnown = GetCampaignChain(g_sRecordedMap, sOldChain, sizeof(sOldChain));
	bool bNewKnown = GetCampaignChain(sCurrentMap, sNewChain, sizeof(sNewChain));

	// 至少一侧是三方图（命名无法解析）：交给引擎判断
	if (!bOldKnown || !bNewKnown)
		return L4D_IsFirstMapInScenario();

	// 换到了另一个战役：新章节
	if (strcmp(sOldChain, sNewChain, false) != 0)
		return true;

	// 混图链组内换图（c6m3 -> c7m1、c9m2 -> c14m1 等）：仍算同一章节
	if (strcmp(sNewChain, "c6c7", false) == 0 || strcmp(sNewChain, "c9c14", false) == 0)
		return false;

	// 同一战役内又回到了第一关：上一局已结束、这是新开的一局，按新章节处理
	return L4D_IsFirstMapInScenario();
}

// final_map_disable=2/3：不按记录归位，而是按记录的人数规模随机重排。
//   模式 2：只在切换到"新章节"时打乱（同战役内换关、同图重开、c6↔c7 与 c9↔c14 混图链内换图都不打乱）
//   模式 3：除同一张图重开外，任何换关都打乱（同战役内换关、c6↔c7 / c9↔c14 混图链内换图、跨战役、三方图换图）
void PrepareShuffleMode()
{
	g_bShuffleMode = false;
	g_bShuffleSmallLevel = false;
	g_bFixStartLogged = false;
	g_hShuffleTargets.Clear();
	g_iShuffleTotal = 0;
	g_iShuffleSurvivors = 0;

	if (g_iCvarFinalMapDisable < 2 || !g_bMapChangedSinceRecord)
		return;

	/* 模式 2 只认"换到新章节"；模式 3 放宽到"同一战役内换小关也打乱"。
	   两道闸门只差这一条判定，其余流程（BuildShuffleTargets 的人数规模、旁观者保持旁观、
	   公告、native/forward）完全复用，不另写一套。 */
	bool bAllow = (g_iCvarFinalMapDisable == 2) ? IsNewChapterSwitch() : IsSmallLevelShuffleAllowed();
	if (!bAllow)
		return;

	g_bShuffleMode = true;
	g_bShuffleSmallLevel = (g_iCvarFinalMapDisable == 3);
	BuildShuffleTargets();
}

// final_map_disable=3：每过一个小关卡就打乱。
// 与模式 2 的唯一区别是不再要求"必须换战役"——同战役内 c2m1 -> c2m2 这种换关也算。
// 唯一不放行的情况是同一张图重开（半场重打 / 重载当前关）；
// c6↔c7 与 c9↔c14 混图链组内换图（c6m3 -> c7m1、c9m2 -> c14m1）在本模式下同样算换关，照常打乱。
bool IsSmallLevelShuffleAllowed()
{
	char sCurrentMap[64];
	GetCurrentMap(sCurrentMap, sizeof(sCurrentMap));

	// 同一张图重开不算换关
	if (strcmp(sCurrentMap, g_sRecordedMap, false) == 0)
		return false;

	// 其余情况（同战役内换关、c6↔c7 / c9↔c14 混图链组内换图、跨战役换图、三方图换图）都算"过了一个小关卡"，打乱
	return true;
}

// 以记录表为基准：旁观者继续旁观；非旁观玩家按记录时的生还者/特感人数规模
// 重新随机分配，而不是回到各自的原始队伍位置。
void BuildShuffleTargets()
{
	char aAuths[MAXPLAYERS + 1][MAX_AUTHID_LENGTH];
	int iTotal = 0;

	StringMapSnapshot snapshot = g_hTeamRecords.Snapshot();
	char sAuth[MAX_AUTHID_LENGTH];
	int iTeam;

	for (int i = 0; i < snapshot.Length; i++)
	{
		snapshot.GetKey(i, sAuth, sizeof(sAuth));
		if (!g_hTeamRecords.GetValue(sAuth, iTeam))
			continue;

		// 旁观者保持旁观，不参与打乱
		if (iTeam == TEAM_SPECTATOR)
		{
			g_hShuffleTargets.SetValue(sAuth, TEAM_SPECTATOR);
			continue;
		}

		if (iTotal < MAXPLAYERS + 1)
			strcopy(aAuths[iTotal], MAX_AUTHID_LENGTH, sAuth);
		iTotal++;
	}

	delete snapshot;

	// 没有需要打乱的玩家：退回按记录归位，避免留下空的打乱表
	if (iTotal <= 0)
	{
		g_bShuffleMode = false;
		return;
	}

	if (iTotal > MAXPLAYERS + 1)
		iTotal = MAXPLAYERS + 1;

	// Fisher-Yates 洗牌
	for (int i = iTotal - 1; i > 0; i--)
	{
		int j = GetRandomInt(0, i);
		char sTemp[MAX_AUTHID_LENGTH];
		strcopy(sTemp, sizeof(sTemp), aAuths[i]);
		strcopy(aAuths[i], MAX_AUTHID_LENGTH, aAuths[j]);
		strcopy(aAuths[j], MAX_AUTHID_LENGTH, sTemp);
	}

	// 记录时有多少生还者，打乱后就保留多少个生还者名额，其余为特感
	int iSurvivorCount = 0;

	snapshot = g_hTeamRecords.Snapshot();
	for (int i = 0; i < snapshot.Length; i++)
	{
		snapshot.GetKey(i, sAuth, sizeof(sAuth));
		if (g_hTeamRecords.GetValue(sAuth, iTeam) && iTeam == TEAM_SURVIVOR)
			iSurvivorCount++;
	}
	delete snapshot;

	// 生还者名额不能超过参与打乱的人数
	if (iSurvivorCount > iTotal)
		iSurvivorCount = iTotal;

	for (int i = 0; i < iTotal; i++)
	{
		int targetTeam = (i < iSurvivorCount) ? TEAM_SURVIVOR : TEAM_INFECTED;
		g_hShuffleTargets.SetValue(aAuths[i], targetTeam);
	}

	// OnMapStart 时玩家往往还没进游戏，聊天公告要延后到他们进来之后
	g_iShuffleTotal = iTotal;
	g_iShuffleSurvivors = iSurvivorCount;
	CreateTimer(5.0, Timer_AnnounceShuffle, _, TIMER_FLAG_NO_MAPCHANGE);

	LogMessage("[队伍修正] %s，随机分队：%d 人，生还者名额 %d（final_map_disable=%d）",
		g_bShuffleSmallLevel ? "换小关卡" : "切换新章节", iTotal, iSurvivorCount, g_iCvarFinalMapDisable);

	// 独立日志：这次打乱给每个玩家分配的目标队伍（此时玩家多半还没进游戏，只有 SteamID）
	if (g_bCvarLog)
	{
		FixLog("===== 随机分队（%s，final_map_disable=%d）=====",
			g_bShuffleSmallLevel ? "换小关卡" : "切换新章节", g_iCvarFinalMapDisable);
		FixLog("[打乱] 参与 %d 人，生还者名额 %d 个，特感名额 %d 个",
			iTotal, iSurvivorCount, iTotal - iSurvivorCount);

		for (int i = 0; i < iTotal; i++)
		{
			int targetTeam = (i < iSurvivorCount) ? TEAM_SURVIVOR : TEAM_INFECTED;

			char sTarget[16];
			GetTeamLabel(targetTeam, sTarget, sizeof(sTarget));

			int owner = FindClientBySteamId(aAuths[i]);
			if (owner > 0)
			{
				char sName[MAX_NAME_LENGTH];
				if (!GetClientName(owner, sName, sizeof(sName)))
					strcopy(sName, sizeof(sName), "未知玩家");
				FixLog("[打乱] %s (%s) 目标=%s", sName, aAuths[i], sTarget);
			}
			else
			{
				FixLog("[打乱] %s 目标=%s（当前不在服务器）", aAuths[i], sTarget);
			}
		}
	}
}

public Action Timer_AnnounceShuffle(Handle timer)
{
	if (!g_bCvarNotify || g_iShuffleTotal <= 0)
		return Plugin_Stop;

	/* 模式 3 是"换小关卡就打乱"，文案要和模式 2 的"切换新章节"区分开，
	   玩家一眼能看出这次是过关换图导致的重新分队 */
	if (g_bShuffleSmallLevel)
		PrintToChatAll("[队伍修正] 本关换图，%d 人随机重新分队（生还者 %d）",
			g_iShuffleTotal, g_iShuffleSurvivors);
	else
		PrintToChatAll("[队伍修正] 已切换到新章节，%d 人随机重新分队（生还者 %d）",
			g_iShuffleTotal, g_iShuffleSurvivors);

	return Plugin_Stop;
}

bool IsTeamSwapped()
{
	// 中途换图（回合没结束、游戏没换边）：不对调
	if (!g_bRecordedAtRoundEnd)
		return false;

	// 跨战役换图：游戏开新比赛会把 m_bAreTeamsFlipped 重置为 0，而不是像同战役内那样翻转，
	// 单看标志会把"被重置"误判成"没换边"；而回合结束后游戏必然换边，因此跨战役一律
	// 按"已换边"处理（上一章的生还者，下一章开局去特感）。
	if (g_bMapChangedSinceRecord && IsNewCampaignMap())
		return true;

	return g_bOldTeamFlipped != g_bNewTeamFlipped;
}

// ========== 5 秒检查与超时兜底 ==========

public Action Timer_CheckConnected(Handle timer)
{
	if (!g_bTeamLock)
	{
		g_hCheckTimer = INVALID_HANDLE;
		return Plugin_Stop;
	}

	if (g_bCvarIgnoreOffline)
		DropOfflineTeams();

	if (g_iPendingCount <= 0 || IsFixComplete())
	{
		g_hCheckTimer = INVALID_HANDLE;
		ForceToUnlock("检查器确认全部完成");
		return Plugin_Stop;
	}

	return Plugin_Continue;
}

public Action Timer_AllowTeamChanges(Handle timer)
{
	g_hTimeoutTimer = INVALID_HANDLE;

	// 时间到：无论是否还有人未还原成功都强制解锁
	ForceToUnlock("超时强制解锁");
	return Plugin_Stop;
}

// 只要存在 checked 为真的玩家，或存在已连接但尚未进游戏的玩家，就返回假；
// 否则返回真（说明已没有需要等待的个人计时器）。
bool IsFixComplete()
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (g_bChecked[client])
			return false;

		if (IsClientConnected(client) && !IsClientInGame(client) && !IsFakeClient(client))
			return false;
	}

	// ignore_offline=0：记录表中的玩家全部都要在服务器内（连接中即可），
	// 否则等待其重新进入，直到超时兜底。
	if (!g_bCvarIgnoreOffline)
	{
		StringMapSnapshot snapshot = g_hTeamRecords.Snapshot();
		char auth[MAX_AUTHID_LENGTH];

		for (int i = 0; i < snapshot.Length; i++)
		{
			snapshot.GetKey(i, auth, sizeof(auth));
			if (FindClientBySteamId(auth) == 0)
			{
				delete snapshot;
				return false;
			}
		}

		delete snapshot;
	}

	return true;
}

// ignore_offline=1：把已经不在服务器中的记录玩家直接移除，不等待其重新进入
void DropOfflineTeams()
{
	// 有已连接但尚未完成 Steam 认证的玩家时暂不判定离线，
	// 避免把正在进入服务器的记录玩家误删（其 SteamID 暂时取不到）。
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientConnected(client) && !IsFakeClient(client) && !IsClientAuthorized(client))
			return;
	}

	StringMapSnapshot snapshot = g_hTeamRecords.Snapshot();
	char auth[MAX_AUTHID_LENGTH];

	for (int i = 0; i < snapshot.Length; i++)
	{
		snapshot.GetKey(i, auth, sizeof(auth));

		if (FindClientBySteamId(auth) != 0)
			continue;

		g_hTeamRecords.Remove(auth);
		g_hPendingRecords.Remove(auth);
	}

	delete snapshot;
	g_iPendingCount = g_hPendingRecords.Size;
}

// ========== 解锁 ==========

// 该队伍是否还有空位（含 Bot 占位）：直接 ChangeClientTeam 前必须先确认，
// 否则会绕过引擎人数限制把人数撑破
bool HasFreeTeamSlot(int team)
{
	ConVar limit = FindConVar(team == TEAM_SURVIVOR ? "survivor_limit" : "z_max_player_zombies");
	if (limit == null)
		return false;

	int current = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && GetClientTeam(i) == team)
			current++;
	}

	return current < limit.IntValue;
}

/* 解锁前的一致性复查：逐人核对"当前队伍 vs 冻结目标"。
   作用有两个：
   1) 把"修复不对"变成可读的日志（谁、期望哪队、实际哪队）；
   2) 对还没走对、但人还在服务器里的玩家再做最后一次直接转移（不再依赖 Bot 名额），
      尽量在解锁前把队伍补齐，而不是把错误状态留给下一回合。 */
void AuditRestoreTargets(const char[] reason)
{
	// 没有冻结目标就没有"期望队伍"，无从复查
	if (!g_bTargetsFrozen)
		return;

	int iChecked = 0;
	int iMismatch = 0;
	int iFixed = 0;

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || IsFakeClient(client))
			continue;

		char auth[MAX_AUTHID_LENGTH];
		if (!GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth)))
			continue;

		int targetTeam;
		if (!ResolveTargetTeam(auth, targetTeam))
			continue;

		iChecked++;

		int actualTeam = GetClientTeam(client);
		if (actualTeam == targetTeam)
			continue;

		// 目标旁观但正挂机托管：算走对了（还原逻辑里这是正常终态）
		if (targetTeam == TEAM_SPECTATOR && IsClientIdle(client))
			continue;

		iMismatch++;

		g_bJoinTeamUsed[client] = true;

		bool bMoved = false;
		if (targetTeam == TEAM_SPECTATOR)
		{
			ChangeClientTeam(client, TEAM_SPECTATOR);
			bMoved = true;
		}
		else if (targetTeam == TEAM_INFECTED)
		{
			bMoved = TurnClientToInfected(client);
		}
		else if (targetTeam == TEAM_SURVIVOR)
		{
			// 先走正常路径（接管空闲 Bot，不会多占一个名额）；
			// 只有在生还者确有空格时才允许直接换队，避免把人数上限撑破
			bMoved = TurnClientToSurvivors(client, false);

			if (!bMoved && HasFreeTeamSlot(TEAM_SURVIVOR))
			{
				ChangeClientTeam(client, TEAM_SURVIVOR);
				bMoved = (GetClientTeam(client) == TEAM_SURVIVOR);
			}
		}

		g_bJoinTeamUsed[client] = false;

		int iNowTeam = GetClientTeam(client);
		bool bOk = (iNowTeam == targetTeam);

		if (bOk && iNowTeam != actualTeam)
			iFixed++;

		char sExpected[16], sActual[16], sNow[16];
		GetTeamLabel(targetTeam, sExpected, sizeof(sExpected));
		GetTeamLabel(actualTeam, sActual, sizeof(sActual));
		GetTeamLabel(iNowTeam, sNow, sizeof(sNow));

		if (bOk)
			FixLogClient(client, "复查：不一致已修正 %s -> %s（期望=%s）", sActual, sNow, sExpected);
		else
			FixLogClient(client, "复查：仍然不一致（期望=%s 实际=%s），已尝试直接转移但失败",
				sExpected, sNow);
	}

	FixLog("[复查] 解锁前核对 %d 人：不一致 %d 人，其中已补正 %d 人（原因=%s）",
		iChecked, iMismatch, iFixed, reason);
}

// 唯一正式的解锁函数：写日志结果 -> 公告（notify=1）-> 触发完成前向 -> 清空记录表并解除锁定
// reason：解锁原因，只用于日志（全部归位 / 检查器确认 / 超时 / 中止）
void ForceToUnlock(const char[] reason = "完成")
{
	if (!g_bTeamLock)
		return;

	// 必须在 ClearVars 之前写：结果名单要读当前队伍，模式/目标标志也还没被清
	AuditRestoreTargets(reason);
	LogFixSummary(reason);

	if (g_bCvarNotify)
		PrintToChatAll("%t", "Fix Completed");

	Call_StartForward(g_hFwdFixComplete);
	Call_Finish();

	ClearVars();
}

void AbortProcess(bool fireForward, const char[] reason = "提前结束")
{
	if (!g_bTeamLock)
	{
		ClearVars();
		return;
	}

	if (fireForward)
	{
		ForceToUnlock(reason);
		return;
	}

	// 提前结束（Ready Up 开始回合 / 换图 / 非对抗模式）：不公告、不触发前向，
	// 但"修复完的队伍"仍然要写进日志，否则最常见的 Ready Up 路径会没有结果记录
	AuditRestoreTargets(reason);
	LogFixSummary(reason);
	ClearVars();
}

void ClearVars()
{
	g_hTeamRecords.Clear();
	g_hPendingRecords.Clear();
	g_hShuffleTargets.Clear();
	g_hTargetTeams.Clear();
	g_bTargetsFrozen = false;

	g_bTeamLock = false;
	g_iPendingCount = 0;
	g_iRestoredCount = 0;
	g_iEvictBudget = MaxClients;
	g_bMapTransition = false;
	g_bRecordedAtRoundEnd = false;
	g_bMapChangedSinceRecord = false;
	g_bShuffleMode = false;
	g_iRestoreStartTime = 0;
	g_bFixStartLogged = false;

	// 公告计数与"本次打乱是否由模式 3 触发"的标志都不在这里清零：
	// 还原可能在 5 秒内完成并走到这里，清掉会让延后的分队公告打不出来或文案说错。
	// 它们由 PrepareShuffleMode 在每张图开头重置。
	CancelProcessTimers();
	ResetClientFlags();
}

void CancelProcessTimers()
{
	delete g_hStartTimer;
	if (g_hCheckTimer != INVALID_HANDLE)
	{
		KillTimer(g_hCheckTimer);
		g_hCheckTimer = INVALID_HANDLE;
	}

	if (g_hTimeoutTimer != INVALID_HANDLE)
	{
		KillTimer(g_hTimeoutTimer);
		g_hTimeoutTimer = INVALID_HANDLE;
	}
}

void ResetClientFlags()
{
	for (int client = 1; client <= MaxClients; client++)
	{
		StopClientRestoreTimer(client);
		g_bChecked[client] = false;
		g_iFailureCount[client] = 0;
		g_bJoinTeamUsed[client] = false;
		g_iNoAuthTicks[client] = 0;
	}
}

// ========== 锁队 / 投票拦截 ==========

public Action Command_JoinTeam(int client, const char[] command, int argc)
{
	if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
		return Plugin_Continue;

	// 锁队期间拦截换队；插件自己执行转移时通过 g_bJoinTeamUsed 临时放行
	if (IsRestoreLocked() && !g_bJoinTeamUsed[client])
		return Plugin_Handled;

	return Plugin_Continue;
}

public Action Command_Vote(int client, const char[] command, int argc)
{
	// 服务器控制台发起的投票放行
	if (client == 0)
		return Plugin_Continue;

	if (!IsRestoreLocked())
		return Plugin_Continue;

	// 非旁观玩家收到提示；旁观玩家直接拦截
	if (IsClientInGame(client) && GetClientTeam(client) != TEAM_SPECTATOR)
		PrintToChat(client, "%t", "Vote Blocked");

	return Plugin_Handled;
}

// ========== 管理员命令 ==========

public Action Command_FixTeamsKeep(int client, int args)
{
	if (!g_bCvarEnabled)
	{
		ReplyToCommand(client, "[队伍修正] 总开关 l4d2_fix_team_shuffle_allow_fix 已关闭");
		return Plugin_Handled;
	}

	KeepTeams(false);
	ReplyToCommand(client, "[队伍修正] 已记录当前玩家队伍（%d 人），可执行 sm_fixteams_start 启动还原", g_iPendingCount);
	return Plugin_Handled;
}

public Action Command_FixTeamsStart(int client, int args)
{
	if (StartProcess())
	{
		// 手动启动不经过 Timer_StartRestore，表头在这里补
		LogFixStart();
		ReplyToCommand(client, "[队伍修正] 已启动队伍还原并锁定换队");
	}
	else
	{
		ReplyToCommand(client, "[队伍修正] 启动失败：请先执行 sm_fixteams_keep 记录队伍");
	}

	return Plugin_Handled;
}

public Action Command_FixTeamsAbort(int client, int args)
{
	AbortProcess(true, "管理员中止");
	ReplyToCommand(client, "[队伍修正] 已中止队伍还原并解锁");
	return Plugin_Handled;
}

// ========== 外部 Ready Up：回合正式开始即解锁 ==========

public void OnRoundIsLive()
{
	AbortProcess(false, "Ready Up 开始回合");
}

// ========== 辅助转移函数 ==========

int GetRestoreTeamLimit(int team)
{
	int limit = g_iZMaxPlayerZombies;
	if (team == TEAM_SURVIVOR)
	{
		ConVar engineLimit = FindConVar("survivor_limit");
		limit = engineLimit != null ? engineLimit.IntValue : 0;
	}
	ConVar multiLimit = FindConVar(team == TEAM_SURVIVOR ? "l4d_survivor_limit" : "l4d_infected_limit");
	if (multiLimit != null && multiLimit.IntValue < limit)
		limit = multiLimit.IntValue;
	return limit;
}

int CountRestoreTeamPlayers(int team, bool includeBots = false)
{
	int count;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != team)
			continue;
		if (!includeBots && IsFakeClient(i) && !(team == TEAM_SURVIVOR && HasIdlePlayer(i)))
			continue;
		count++;
	}
	return count;
}

// 客户端当前是否拿得到 SteamID（拿不到 = 非 Steam 客户端 / 授权还没完成，
// 这种客户端无法与记录表比对，也就无法证明自己该站哪一边）
bool HasSteamAuth(int client)
{
	char auth[MAX_AUTHID_LENGTH];
	return GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth));
}

// 目标队伍里一个"拿不到 SteamID"的占位者（排除 excludeClient 与 AI Bot）
int FindNoAuthTeamOccupant(int team, int excludeClient)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (i == excludeClient || !IsClientInGame(i) || IsFakeClient(i))
			continue;

		if (GetClientTeam(i) != team)
			continue;

		// 能核对记录的人不能动：他们要么本来就该在这边，要么由 TryEvictFromTeam 负责
		if (HasSteamAuth(i))
			continue;

		return i;
	}

	return 0;
}

/* 满员时把"拿不到 SteamID"的占位者让到旁观，腾出一个真人名额。
   这种人既不在记录里、也无法核对，按现有策略本来就不该占队伍名额；
   记录里的玩家必须优先落位。返回 true 表示确实腾出了名额。 */
bool MakeRoomByEvictingNoAuth(int team, int excludeClient)
{
	// 开关关闭时不做任何腾位
	if (!g_bCvarNoAuthSpectate)
		return false;

	if (g_iEvictBudget <= 0)
		return false;

	int intruder = FindNoAuthTeamOccupant(team, excludeClient);
	if (intruder == 0)
		return false;

	g_bJoinTeamUsed[intruder] = true;
	ChangeClientTeam(intruder, TEAM_SPECTATOR);
	g_bJoinTeamUsed[intruder] = false;
	g_iEvictBudget--;

	// 玩家视角的提示：被让出名额同样要说明原因
	PrintToChat(intruder, "\x04[队伍修正]\x01 队伍名额已满，且读不到你的 SteamID 无法核对记录，先把你放到旁观；解锁后可以自行选队。");

	if (g_bCvarLog)
	{
		char sTeam[16];
		GetTeamLabel(team, sTeam, sizeof(sTeam));

		FixLogClient(intruder, "修复：%s 名额被无法核对记录（拿不到 SteamID）的玩家占用，先让出到旁观", sTeam);
	}

	return GetClientTeam(intruder) == TEAM_SPECTATOR;
}

bool TurnClientToSurvivors(int client, bool isIdle)
{
	if (!L4D_IsVersusMode())
		return false;

	if (isIdle)
	{
		L4D_TakeOverBot(client);
		return true;
	}

	// 与多人插件一致：托管身体也占用真人名额，额外 AI 不能变成第 13 个位置。
	int limit = GetRestoreTeamLimit(TEAM_SURVIVOR);
	if (limit <= 0 || CountRestoreTeamPlayers(TEAM_SURVIVOR) >= limit)
	{
		// 满员：先看名额是不是被"拿不到 SteamID"的玩家占着（见 MakeRoomByEvictingNoAuth）
		if (!MakeRoomByEvictingNoAuth(TEAM_SURVIVOR, client))
			return false;

		if (CountRestoreTeamPlayers(TEAM_SURVIVOR) >= limit)
			return false;
	}

	int bot = FindBotToTakeOver(true);
	if (bot == -1)
		bot = FindBotToTakeOver(false);

	// 找不到任何可用 Bot：不转移，交给 attempts 重试或超时解锁
	if (bot == -1)
		return false;

	// 对抗模式：直接设置人类观察者并接管，绕过原生四人入队路径。
	L4D_SetHumanSpec(bot, client);

	// 接管失败要检查：SetHumanSpec 已经把 bot 的 m_humanSpectatorUserID 指到这个玩家，
	// 不接管成功又不清理的话，引擎会把他判定成闲置（挂机托管）。
	if (!L4D_TakeOverBot(client))
	{
		ClearIdleLink(bot, client);
		return false;
	}

	return true;
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

// ========== 腾位：满员死锁破局 ==========

/* 目标队伍满员（没有空位、也没有 Bot 可接管）时，
   先把一个"本来就该离开这支队伍"的待修复玩家挪到旁观腾出名额，
   他的个人计时器随后会把他放到自己的目标队。没有这一步，
   满员打乱时双方都满、谁也进不去，只能干等超时。 */
bool TryEvictFromTeam(int targetTeam, int excludeClient, int preferTeam)
{
	if (g_iEvictBudget <= 0)
		return false;

	char sAuth[MAX_AUTHID_LENGTH];
	int iTarget;

	// 两轮：先找"目标正好是发起方当前所在队"的真交换对手，再退而求其次
	for (int iPass = 0; iPass < 2; iPass++)
	{
		for (int other = 1; other <= MaxClients; other++)
		{
			if (other == excludeClient || !IsClientInGame(other) || IsFakeClient(other))
				continue;

			if (GetClientTeam(other) != targetTeam)
				continue;

			if (!GetClientAuthId(other, AuthId_Steam2, sAuth, sizeof(sAuth)))
				continue;

			// 只动"还没归位"的记录玩家；已归位的人不能被我们拽走
			if (!g_hPendingRecords.ContainsKey(sAuth))
				continue;

			if (!ResolveTargetTeam(sAuth, iTarget) || iTarget == targetTeam)
				continue;

			if (iPass == 0 && iTarget != preferTeam)
				continue;

			g_bJoinTeamUsed[other] = true;
			ChangeClientTeam(other, TEAM_SPECTATOR);
			g_bJoinTeamUsed[other] = false;
			g_iEvictBudget--;

			// 被腾位的人必须保证还有人把他放回目标队：
			// 他的计时器可能早已因重试耗尽而停掉，这里重开一个
			StartClientRestore(other);

			if (g_bCvarLog)
			{
				char sTeam[16], sHisTarget[16];
				GetTeamLabel(targetTeam, sTeam, sizeof(sTeam));
				GetTeamLabel(iTarget, sHisTarget, sizeof(sHisTarget));

				FixLogClient(other, "修复：%s 满员，先让出到旁观腾位（他自己应去 %s）",
					sTeam, sHisTarget);
			}
			return true;
		}
	}

	return false;
}

bool TurnClientToInfected(int client)
{
	// 非对抗模式人类不能加入特感
	if (!L4D_IsVersusMode())
		return false;

	int maxZombies = GetRestoreTeamLimit(TEAM_INFECTED);
	if (maxZombies <= 0)
		return false;

	// 特感名额已满：先看名额是不是被"拿不到 SteamID"的玩家占着，
	// 清不走再返回，交给重试或超时
	if (CountRestoreTeamPlayers(TEAM_INFECTED) >= maxZombies)
	{
		if (!MakeRoomByEvictingNoAuth(TEAM_INFECTED, client))
			return false;

		if (CountRestoreTeamPlayers(TEAM_INFECTED) >= maxZombies)
			return false;
	}

	// 与 SuperVersus 的 MakeInfectedRoom 一致：普通 AI 腾位，Tank 不动。
	while (CountRestoreTeamPlayers(TEAM_INFECTED, true) >= maxZombies)
	{
		int candidate;
		for (int bot = MaxClients; bot >= 1; bot--)
		{
			if (!IsClientInGame(bot) || !IsFakeClient(bot) || IsClientInKickQueue(bot)
				|| GetClientTeam(bot) != TEAM_INFECTED)
				continue;
			int zclass = GetEntProp(bot, Prop_Send, "m_zombieClass");
			if (zclass >= 1 && zclass <= 6)
			{
				candidate = bot;
				break;
			}
		}
		if (candidate == 0)
			return false;
		ChangeClientTeam(candidate, TEAM_SPECTATOR);
		KickClient(candidate, "Making room for restored infected player");
	}

	// 先解除托管，避免把关联 Bot 遗留为被占用的生还者名额。
	if (IsClientIdle(client))
	{
		L4D_TakeOverBot(client);
		if (GetClientTeam(client) != TEAM_SURVIVOR)
			return false;
	}
	ChangeClientTeam(client, TEAM_INFECTED);
	return true;
}

int FindBotToTakeOver(bool aliveOnly)
{
	int candidates[MAXPLAYERS + 1];
	int count = 0;

	for (int bot = 1; bot <= MaxClients; bot++)
	{
		if (!IsClientInGame(bot) || !IsFakeClient(bot) || IsClientInKickQueue(bot)
			|| GetClientTeam(bot) != TEAM_SURVIVOR)
			continue;

		// 已有人挂机托管的 Bot 不可用
		if (HasIdlePlayer(bot))
			continue;

		if (aliveOnly && !IsPlayerAlive(bot))
			continue;

		candidates[count++] = bot;
	}

	if (count == 0)
		return -1;

	// 从符合条件的 Bot 中随机选一个
	return candidates[GetRandomInt(0, count - 1)];
}

/* m_humanSpectatorUserID 只在"正被挂机托管"的 player 实体上才存在，
   未托管的 Bot 直接 GetEntProp 会抛
   'Property "m_humanSpectatorUserID" not found (entity N/player)'，
   所以一律先 HasEntProp 探测再读（Left4DHooks 的 L4D_GetIdlePlayerOfBot 同款做法）。 */
bool HasIdlePlayer(int bot)
{
	if (!HasEntProp(bot, Prop_Send, "m_humanSpectatorUserID"))
		return false;

	int owner = GetClientOfUserId(GetEntProp(bot, Prop_Send, "m_humanSpectatorUserID"));
	return owner > 0 && IsClientInGame(owner) && !IsFakeClient(owner)
		&& GetClientTeam(owner) == TEAM_SPECTATOR;
}

// 托管归属不因身体死亡而丢失；死亡状态只影响后续接管操作。
bool IsClientIdle(int client)
{
	if (!IsClientInGame(client) || GetClientTeam(client) != TEAM_SPECTATOR)
		return false;

	int userId = GetClientUserId(client);

	for (int bot = 1; bot <= MaxClients; bot++)
	{
		if (!IsClientInGame(bot) || !IsFakeClient(bot)
			|| GetClientTeam(bot) != TEAM_SURVIVOR)
			continue;

		if (!HasEntProp(bot, Prop_Send, "m_humanSpectatorUserID"))
			continue;

		if (GetEntProp(bot, Prop_Send, "m_humanSpectatorUserID") == userId)
			return true;
	}

	return false;
}

// ========== 独立日志（addons/sourcemod/logs/） ==========

// 生成日志文件绝对路径；logs 目录不存在时顺手建出来，避免 LogToFileEx 抛错
void InitFixLogFile()
{
	BuildPath(Path_SM, g_sLogFile, sizeof(g_sLogFile), FIX_LOG_FILE);

	char sDir[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sDir, sizeof(sDir), "logs");
	if (!DirExists(sDir))
		CreateDirectory(sDir);
}

// 写一行不带玩家信息的日志（时间戳由 SourceMod 的日志系统自动加）
void FixLog(const char[] format, any ...)
{
	if (!g_bCvarLog || g_sLogFile[0] == '\0')
		return;

	char sMsg[512];
	VFormat(sMsg, sizeof(sMsg), format, 2);

	LogToFileEx(g_sLogFile, "%s", sMsg);
}

// 写一行带玩家名字与 SteamID 的日志
void FixLogClient(int client, const char[] format, any ...)
{
	if (!g_bCvarLog || g_sLogFile[0] == '\0')
		return;

	char sName[MAX_NAME_LENGTH];
	if (!GetClientName(client, sName, sizeof(sName)))
		strcopy(sName, sizeof(sName), "未知玩家");

	char sAuth[MAX_AUTHID_LENGTH];
	if (!GetClientAuthId(client, AuthId_Steam2, sAuth, sizeof(sAuth)))
		strcopy(sAuth, sizeof(sAuth), "无SteamID");

	char sMsg[512];
	VFormat(sMsg, sizeof(sMsg), format, 3);

	LogToFileEx(g_sLogFile, "[%s (%s)] %s", sName, sAuth, sMsg);
}

// 队伍号转中文名
void GetTeamLabel(int team, char[] buffer, int maxlen)
{
	switch (team)
	{
		case TEAM_SURVIVOR:
			strcopy(buffer, maxlen, "生还者");
		case TEAM_INFECTED:
			strcopy(buffer, maxlen, "特感");
		case TEAM_SPECTATOR:
			strcopy(buffer, maxlen, "旁观");
		default:
			strcopy(buffer, maxlen, "未选队");
	}
}

// 本次修复用的是什么模式（按记录归位 / 换边对调 / 随机打乱）
void GetFixModeLabel(char[] buffer, int maxlen)
{
	if (g_bShuffleMode)
	{
		if (g_bShuffleSmallLevel)
			strcopy(buffer, maxlen, "随机打乱（换小关卡，final_map_disable=3）");
		else
			strcopy(buffer, maxlen, "随机打乱（切换新章节，final_map_disable=2）");
	}
	else if (IsTeamSwapped())
	{
		strcopy(buffer, maxlen, "按记录归位（回合结束已换边，生还者/特感对调）");
	}
	else
	{
		strcopy(buffer, maxlen, "按记录归位（未换边）");
	}
}

// 修复开始时写一段表头：地图、人数、换边标志、模式
void LogFixStart()
{
	// 自动换图与管理员/Native 启动两条路径都可能调用，只写一次
	if (!g_bCvarLog || g_bFixStartLogged)
		return;

	g_bFixStartLogged = true;
	g_iRestoreStartTime = GetTime();

	char sMap[64];
	GetCurrentMap(sMap, sizeof(sMap));

	char sMode[128];
	GetFixModeLabel(sMode, sizeof(sMode));

	FixLog("===== 开始修复队伍 =====");
	FixLog("[修复] 地图=%s 记录地图=%s 待修复=%d 人 换边标志：记录时=%d 当前=%d 是否对调=%d 模式=%s",
		sMap, g_sRecordedMap, g_iPendingCount,
		g_bOldTeamFlipped ? 1 : 0, g_bNewTeamFlipped ? 1 : 0, IsTeamSwapped() ? 1 : 0, sMode);
}

// 修复结束（解锁）时写完整结果：模式、耗时、剩余人数、三支队伍最终名单
void LogFixSummary(const char[] reason)
{
	if (!g_bCvarLog)
		return;

	char sMode[128];
	GetFixModeLabel(sMode, sizeof(sMode));

	int iElapsed = 0;
	if (g_iRestoreStartTime > 0)
		iElapsed = GetTime() - g_iRestoreStartTime;

	char sMap[64];
	GetCurrentMap(sMap, sizeof(sMap));

	FixLog("===== 修复结束：%s =====", reason);
	FixLog("[结果] 地图=%s 模式=%s 耗时=%d 秒 剩余未修复=%d 人",
		sMap, sMode, iElapsed, g_iPendingCount);

	LogTeamRoster(TEAM_SURVIVOR);
	LogTeamRoster(TEAM_INFECTED);
	LogTeamRoster(TEAM_SPECTATOR);

	g_iRestoreStartTime = 0;
}

// 输出某支队伍当前的最终名单（只算真人玩家）
void LogTeamRoster(int team)
{
	char sLabel[16];
	GetTeamLabel(team, sLabel, sizeof(sLabel));

	int iCount = 0;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || IsFakeClient(client) || GetClientTeam(client) != team)
			continue;

		char sName[MAX_NAME_LENGTH];
		if (!GetClientName(client, sName, sizeof(sName)))
			strcopy(sName, sizeof(sName), "未知玩家");

		char sAuth[MAX_AUTHID_LENGTH];
		if (!GetClientAuthId(client, AuthId_Steam2, sAuth, sizeof(sAuth)))
			strcopy(sAuth, sizeof(sAuth), "无SteamID");

		FixLog("[结果] %s %d：%s (%s)", sLabel, iCount + 1, sName, sAuth);
		iCount++;
	}

	if (iCount == 0)
		FixLog("[结果] %s：无", sLabel);
}

// ========== 工具函数 ==========

int FindClientBySteamId(const char[] auth)
{
	char clientAuth[MAX_AUTHID_LENGTH];

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientConnected(client) || IsFakeClient(client))
			continue;

		if (!GetClientAuthId(client, AuthId_Steam2, clientAuth, sizeof(clientAuth)))
			continue;

		if (strcmp(auth, clientAuth, false) == 0)
			return client;
	}

	return 0;
}

void PrecacheSurvivorModels()
{
	if (GetEngineVersion() == Engine_Left4Dead2)
	{
		PrecacheModel("models/survivors/survivor_gambler.mdl", true);
		PrecacheModel("models/survivors/survivor_producer.mdl", true);
		PrecacheModel("models/survivors/survivor_coach.mdl", true);
		PrecacheModel("models/survivors/survivor_mechanic.mdl", true);
	}
	else
	{
		PrecacheModel("models/survivors/survivor_namvet.mdl", true);
		PrecacheModel("models/survivors/survivor_biker.mdl", true);
		PrecacheModel("models/survivors/survivor_manager.mdl", true);
		PrecacheModel("models/survivors/survivor_teenangst.mdl", true);
	}
}
