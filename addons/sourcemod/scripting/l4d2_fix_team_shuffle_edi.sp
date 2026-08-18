#include <sourcemod>
#include <left4dhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "2.0.0"

#define TEAM_NONE      0
#define TEAM_SPECTATOR 1
#define TEAM_SURVIVOR  2
#define TEAM_INFECTED  3

// ========== 主要状态变量 ==========

// 记录表：SteamID(Steam2) -> 记录时的队伍号（1旁观 2生还者 3特感）
StringMap g_hTeamRecords;
// 尚未还原成功的 SteamID 集合，g_iPendingCount 恒等于其 Size
StringMap g_hPendingRecords;

int g_iPendingCount;      // 尚未还原成功的人数
bool g_bTeamLock;         // 当前是否处于队伍锁定（还原进行中）
bool g_bMapTransition;    // 是否刚发生过记录，允许下一次地图开始时启动还原
bool g_bRoundEnd;         // 当前回合是否已经结束（事件去重）
bool g_bFinalMap;         // 当前地图是否为章节最后一关
bool g_bOldTeamFlipped;   // 记录时游戏规则的 m_bAreTeamsFlipped
bool g_bNewTeamFlipped;   // 新地图该属性值，两者不同即代表发生了换边

bool g_bChecked[MAXPLAYERS + 1];      // 某玩家是否正在等待自己的还原计时器
int g_iFailureCount[MAXPLAYERS + 1];  // 某玩家还原失败的次数
bool g_bJoinTeamUsed[MAXPLAYERS + 1]; // 插件自己执行队伍转移期间临时放行 jointeam

Handle g_hCheckTimer = INVALID_HANDLE;   // 5 秒检查计时器
Handle g_hTimeoutTimer = INVALID_HANDLE; // 超时兜底计时器
Handle g_hClientTimer[MAXPLAYERS + 1];   // 每个玩家的 1 秒还原计时器

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
ConVar g_hZMaxPlayerZombies;

bool g_bCvarEnabled;
bool g_bCvarNotify;
bool g_bCvarNoVotes;
int g_iCvarAttempts;
float g_fCvarTime;
bool g_bCvarFinalMapDisable;
bool g_bCvarChangeMapDisable;
bool g_bCvarIgnoreOffline;
int g_iZMaxPlayerZombies;

// ========== Plugin Info ==========

public Plugin myinfo =
{
	name = "L4D2 - Fix team shuffle (unscramble style)",
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
	KeepTeams();
	return 0;
}

public any Native_Start(Handle plugin, int numParams)
{
	StartProcess();
	return 0;
}

public any Native_Abort(Handle plugin, int numParams)
{
	AbortProcess(GetNativeCell(1));
	return 0;
}

public any Native_IsFixComplete(Handle plugin, int numParams)
{
	return !g_bTeamLock;
}

// ========== OnPluginStart ==========

public void OnPluginStart()
{
	LoadTranslations("l4d2_fix_team_shuffle_edi.phrases");

	g_hTeamRecords = new StringMap();
	g_hPendingRecords = new StringMap();

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

	g_cvFinalMapDisable = CreateConVar("l4d2_fix_team_shuffle_final_map_disable", "1",
		"为 1 时章节最后一关结束不记录队伍，下一章按游戏默认分边（0=记录并还原）",
		FCVAR_NONE, true, 0.0, true, 1.0);

	g_cvChangeMapDisable = CreateConVar("l4d2_fix_team_shuffle_change_map_disable", "1",
		"为 1 时回合中途（未到回合结束）换图不记录队伍（0=记录并还原）",
		FCVAR_NONE, true, 0.0, true, 1.0);

	g_cvIgnoreOffline = CreateConVar("l4d2_fix_team_shuffle_ignore_offline", "1",
		"为 1 时上一回合的玩家若已不在服务器中，忽略该玩家立即继续修正，不等待其重新进入",
		FCVAR_NONE, true, 0.0, true, 1.0);

	//AutoExecConfig(true, "l4d2_fix_team_shuffle_edi");

	// 配置文件可能已覆盖默认值，重新读取并给这几个 ConVar 补挂变更钩子
	GetCvars();

	if (g_hZMaxPlayerZombies != null)
		g_hZMaxPlayerZombies.AddChangeHook(OnCvarChange_ZMax);

	g_cvFinalMapDisable.AddChangeHook(OnCvarChange_FinalMapDisable);
	g_cvChangeMapDisable.AddChangeHook(OnCvarChange_ChangeMapDisable);
	g_cvIgnoreOffline.AddChangeHook(OnCvarChange_IgnoreOffline);

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
	g_bCvarFinalMapDisable = g_cvFinalMapDisable.BoolValue;
	g_bCvarChangeMapDisable = g_cvChangeMapDisable.BoolValue;
	g_bCvarIgnoreOffline = g_cvIgnoreOffline.BoolValue;

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
	ClearVars();

	if (g_bCvarEnabled)
		UM_OnPluginEnabled();
	else
		UM_OnPluginDisabled();
}

public void OnCvarChange_FinalMapDisable(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_bCvarFinalMapDisable = convar.BoolValue;
}

public void OnCvarChange_ChangeMapDisable(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_bCvarChangeMapDisable = convar.BoolValue;
}

public void OnCvarChange_IgnoreOffline(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_bCvarIgnoreOffline = convar.BoolValue;
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

	// 最终关且启用 final_map_disable：直接返回，不记录
	if (g_bFinalMap && g_bCvarFinalMapDisable)
		return;

	if (g_bRoundEnd)
		return;

	KeepTeams();
	g_bRoundEnd = true;
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	g_bRoundEnd = false;

	if (!g_bCvarEnabled || !L4D_IsVersusMode())
		return;

	// 兜底刷新换边标志：若游戏在 round_start 时才更新 m_bAreTeamsFlipped，
	// 这里能覆盖 OnMapStart+0.5s 可能过早读取到的旧值。
	g_bNewTeamFlipped = view_as<bool>(GameRules_GetProp("m_bAreTeamsFlipped"));
}

public Action Command_Changelevel(int client, const char[] command, int argc)
{
	if (!g_bCvarEnabled || !L4D_IsVersusMode())
		return Plugin_Continue;

	// 最终关且启用 final_map_disable：放行，不记录
	if (g_bFinalMap && g_bCvarFinalMapDisable)
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
		KeepTeams();
		g_bRoundEnd = true;
	}

	return Plugin_Continue;
}

void KeepTeams()
{
	if (!g_bCvarEnabled)
		return;

	// 放弃当前可能正在进行的还原（不触发完成前向），准备新的记录
	CancelProcessTimers();
	ResetClientFlags();

	g_hTeamRecords.Clear();
	g_hPendingRecords.Clear();
	g_iPendingCount = 0;
	g_bTeamLock = false;

	g_bOldTeamFlipped = view_as<bool>(GameRules_GetProp("m_bAreTeamsFlipped"));
	g_bMapTransition = true;

	bool connectedOnly = true;

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
			// 尚未进游戏但已连接的玩家默认记为旁观
			team = TEAM_SPECTATOR;
		}

		char auth[MAX_AUTHID_LENGTH];
		if (!GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth)))
			continue;

		if (team != TEAM_SPECTATOR)
			connectedOnly = false;

		g_hTeamRecords.SetValue(auth, team);
		g_hPendingRecords.SetValue(auth, true);
	}

	// 全场都在旁观或尚未进游戏：丢弃记录，避免空场锁队
	if (connectedOnly)
	{
		g_hTeamRecords.Clear();
		g_hPendingRecords.Clear();
	}

	g_iPendingCount = g_hPendingRecords.Size;
}

// ========== 阶段 B：新地图启动还原 ==========

public void OnMapStart()
{
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
		AbortProcess(false);
		g_bMapTransition = false;
		return;
	}

	// 换图时若上一次还原仍在锁队、但本次没有新的记录（例如中途换图被
	// change_map_disable 放行），必须静默解锁，避免锁队标志永久残留。
	if (g_bTeamLock && !g_bMapTransition)
		AbortProcess(false);

	// 0.5 秒后读取新地图的换边标志；个人还原计时器 1 秒后才第一次执行
	CreateTimer(0.5, Timer_UpdateTeamFlipped, _, TIMER_FLAG_NO_MAPCHANGE);

	Start();

	// 消费本次换图标记：Start 执行时它必须仍为真
	g_bMapTransition = false;
}

public void OnMapEnd()
{
	// NO_MAPCHANGE 计时器在换图时被引擎销毁，句柄不再有效
	g_hCheckTimer = INVALID_HANDLE;
	g_hTimeoutTimer = INVALID_HANDLE;

	for (int client = 1; client <= MaxClients; client++)
	{
		g_hClientTimer[client] = INVALID_HANDLE;
		g_bChecked[client] = false;
		g_iFailureCount[client] = 0;
		g_bJoinTeamUsed[client] = false;
	}
}

public Action Timer_UpdateTeamFlipped(Handle timer)
{
	g_bNewTeamFlipped = view_as<bool>(GameRules_GetProp("m_bAreTeamsFlipped"));
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
		g_hCheckTimer = CreateTimer(5.0, Timer_CheckConnected, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
		g_hTimeoutTimer = CreateTimer(g_fCvarTime, Timer_AllowTeamChanges, _, TIMER_FLAG_NO_MAPCHANGE);
	}
	else
	{
		// 已经锁队（例如管理员连续调用 Start）：只补建换图时被销毁的计时器
		if (g_hCheckTimer == INVALID_HANDLE)
			g_hCheckTimer = CreateTimer(5.0, Timer_CheckConnected, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

		if (g_hTimeoutTimer == INVALID_HANDLE)
			g_hTimeoutTimer = CreateTimer(g_fCvarTime, Timer_AllowTeamChanges, _, TIMER_FLAG_NO_MAPCHANGE);
	}

	// 启动成功即消费换图标记：OnMapStart 与管理员/Native Start 两条路径行为一致
	g_bMapTransition = false;

	return true;
}

// 管理员命令 / Native 使用的完整启动：启动成功后立即更新换边标志，
// 并给所有已在游戏内的人类玩家补发个人还原计时器。
bool StartProcess()
{
	if (g_bCvarIgnoreOffline)
		DropOfflineTeams();

	if (!Start())
		return false;

	g_bNewTeamFlipped = view_as<bool>(GameRules_GetProp("m_bAreTeamsFlipped"));

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
}

void StartClientRestore(int client)
{
	StopClientRestoreTimer(client);

	g_bChecked[client] = true;
	g_iFailureCount[client] = 0;

	Handle timer = CreateTimer(1.0, Timer_RestoreClient, GetClientUserId(client), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
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
		return Plugin_Continue;

	// 每次执行时刷新当前地图的换边标志。除 OnMapStart+0.5s 外再兜底一次，
	// 防止个别地图在 round_start 之后才更新 m_bAreTeamsFlipped。
	g_bNewTeamFlipped = view_as<bool>(GameRules_GetProp("m_bAreTeamsFlipped"));

	int targetTeam;
	if (!g_hTeamRecords.GetValue(auth, targetTeam))
	{
		// 记录表中查不到 = 换图后才新加入的玩家：一次性赶去旁观
		bool isIdle = (currentTeam == TEAM_SPECTATOR && IsClientIdle(client));

		g_bJoinTeamUsed[client] = true;
		if (isIdle)
			L4D_TakeOverBot(client);
		if (GetClientTeam(client) != TEAM_SPECTATOR)
			ChangeClientTeam(client, TEAM_SPECTATOR);
		g_bJoinTeamUsed[client] = false;

		g_hClientTimer[client] = INVALID_HANDLE;
		g_bChecked[client] = false;
		return Plugin_Stop;
	}

	// 对抗换边：生还者/特感对调，旁观不变
	if (IsTeamSwapped())
	{
		if (targetTeam == TEAM_SURVIVOR)
			targetTeam = TEAM_INFECTED;
		else if (targetTeam == TEAM_INFECTED)
			targetTeam = TEAM_SURVIVOR;
	}

	bool isIdle = (currentTeam == TEAM_SPECTATOR && IsClientIdle(client));

	// 已在目标队伍即完成；唯一例外：目标旁观但玩家正挂机托管 Bot，
	// 需要先接管 Bot 再回旁观（与 l4d_team_unscramble 的组合转移逻辑一致）。
	if (currentTeam == targetTeam && !(targetTeam == TEAM_SPECTATOR && isIdle))
	{
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

	if (GetClientTeam(client) == targetTeam)
	{
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

	char auth[MAX_AUTHID_LENGTH];
	if (GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth))
		&& g_hPendingRecords.Remove(auth)
		&& g_iPendingCount > 0)
	{
		g_iPendingCount--;
	}

	if (g_iPendingCount <= 0)
		ForceToUnlock();
}

bool IsTeamSwapped()
{
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
		ForceToUnlock();
		return Plugin_Stop;
	}

	return Plugin_Continue;
}

public Action Timer_AllowTeamChanges(Handle timer)
{
	g_hTimeoutTimer = INVALID_HANDLE;

	// 时间到：无论是否还有人未还原成功都强制解锁
	ForceToUnlock();
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

// 唯一正式的解锁函数：公告（notify=1）-> 触发完成前向 -> 清空记录表并解除锁定
void ForceToUnlock()
{
	if (!g_bTeamLock)
		return;

	if (g_bCvarNotify)
		PrintToChatAll("%t", "Fix Completed");

	Call_StartForward(g_hFwdFixComplete);
	Call_Finish();

	ClearVars();
}

void AbortProcess(bool fireForward)
{
	if (g_bTeamLock && fireForward)
		ForceToUnlock();
	else
		ClearVars();
}

void ClearVars()
{
	g_hTeamRecords.Clear();
	g_hPendingRecords.Clear();

	g_bTeamLock = false;
	g_iPendingCount = 0;
	g_bMapTransition = false;

	CancelProcessTimers();
	ResetClientFlags();
}

void CancelProcessTimers()
{
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
	}
}

// ========== 锁队 / 投票拦截 ==========

public Action Command_JoinTeam(int client, const char[] command, int argc)
{
	if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
		return Plugin_Continue;

	// 锁队期间拦截换队；插件自己执行转移时通过 g_bJoinTeamUsed 临时放行
	if (g_bTeamLock && !g_bJoinTeamUsed[client])
		return Plugin_Handled;

	return Plugin_Continue;
}

public Action Command_Vote(int client, const char[] command, int argc)
{
	// 服务器控制台发起的投票放行
	if (client == 0)
		return Plugin_Continue;

	if (!g_bTeamLock)
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

	KeepTeams();
	ReplyToCommand(client, "[队伍修正] 已记录当前玩家队伍（%d 人），可执行 sm_fixteams_start 启动还原", g_iPendingCount);
	return Plugin_Handled;
}

public Action Command_FixTeamsStart(int client, int args)
{
	if (StartProcess())
		ReplyToCommand(client, "[队伍修正] 已启动队伍还原并锁定换队");
	else
		ReplyToCommand(client, "[队伍修正] 启动失败：请先执行 sm_fixteams_keep 记录队伍");

	return Plugin_Handled;
}

public Action Command_FixTeamsAbort(int client, int args)
{
	AbortProcess(true);
	ReplyToCommand(client, "[队伍修正] 已中止队伍还原并解锁");
	return Plugin_Handled;
}

// ========== 外部 Ready Up：回合正式开始即解锁 ==========

public void OnRoundIsLive()
{
	AbortProcess(false);
}

// ========== 辅助转移函数 ==========

bool TurnClientToSurvivors(int client, bool isIdle)
{
	if (isIdle)
	{
		L4D_TakeOverBot(client);
		return true;
	}

	int bot = FindBotToTakeOver(true);
	if (bot == -1)
		bot = FindBotToTakeOver(false);

	// 找不到任何可用 Bot：不转移，交给 attempts 重试或超时解锁
	if (bot == -1)
		return false;

	if (L4D_IsVersusMode())
	{
		// 对抗模式：直接设置人类观察者并接管
		L4D_SetHumanSpec(bot, client);
		L4D_TakeOverBot(client);
		return true;
	}

	// 合作/生存/写实：特感先转旁观
	if (GetClientTeam(client) == TEAM_INFECTED)
		ChangeClientTeam(client, TEAM_SPECTATOR);

	if (IsPlayerAlive(bot))
	{
		// Bot 活着：先设为观察者并设置 m_iObserverMode=5，
		// 下一次一秒计时器发现玩家处于空闲托管状态后接管入队
		L4D_SetHumanSpec(bot, client);
		SetEntProp(client, Prop_Send, "m_iObserverMode", 5);
	}
	else
	{
		// Bot 死亡：设置观察者后直接接管
		L4D_SetHumanSpec(bot, client);
		L4D_TakeOverBot(client);
	}

	return true;
}

bool TurnClientToInfected(int client)
{
	// 非对抗模式人类不能加入特感
	if (!L4D_IsVersusMode())
		return false;

	int maxZombies = g_iZMaxPlayerZombies;
	if (maxZombies <= 0)
		return false;

	int humanInfected = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == TEAM_INFECTED)
			humanInfected++;
	}

	// 特感名额已满：返回，交给重试或超时
	if (maxZombies - humanInfected <= 0)
		return false;

	ChangeClientTeam(client, TEAM_INFECTED);
	return true;
}

int FindBotToTakeOver(bool aliveOnly)
{
	int candidates[MAXPLAYERS + 1];
	int count = 0;

	for (int bot = 1; bot <= MaxClients; bot++)
	{
		if (!IsClientInGame(bot) || !IsFakeClient(bot) || GetClientTeam(bot) != TEAM_SURVIVOR)
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

bool HasIdlePlayer(int bot)
{
	return GetEntProp(bot, Prop_Send, "m_humanSpectatorUserID") > 0;
}

// 玩家是否正在挂机托管某个存活的生还者 Bot
bool IsClientIdle(int client)
{
	if (!IsClientInGame(client) || GetClientTeam(client) != TEAM_SPECTATOR)
		return false;

	int userId = GetClientUserId(client);

	for (int bot = 1; bot <= MaxClients; bot++)
	{
		if (!IsClientInGame(bot) || !IsFakeClient(bot) || !IsPlayerAlive(bot)
			|| GetClientTeam(bot) != TEAM_SURVIVOR)
			continue;

		if (GetEntProp(bot, Prop_Send, "m_humanSpectatorUserID") == userId)
			return true;
	}

	return false;
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
