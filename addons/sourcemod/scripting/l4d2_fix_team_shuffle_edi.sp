#include <sourcemod>
#include <left4dhooks>

#define L4D2_TEAM_NONE      0
#define L4D2_TEAM_SPECTATOR 1
#define L4D2_TEAM_SURVIVOR  2
#define L4D2_TEAM_INFECTED  3

bool fixTeam = false;
bool g_bFixCompleted = false;

ArrayList winners;
ArrayList losers;

GlobalForward g_hFwdFixComplete;
Handle g_hTimeoutTimer = INVALID_HANDLE;

ConVar g_cvIgnoreOffline;
ConVar g_cvTimeoutRound1;
ConVar g_cvTimeoutRound2;
ConVar g_cvMaxAttempts;

bool g_bIgnoreOffline;
float g_fTimeoutRound1;
float g_fTimeoutRound2;
int g_iMaxAttempts;

int g_iSavedRound = 0;        // 保存队伍数据时的回合号（0=第一回合, 1=第二回合）
float g_fLastTimeout = 30.0;  // 最近创建的超时时间（用于提示）
int g_iFixAttempts = 0;       // 当前数据下的修正尝试次数

bool g_bWinnersWereSurvivors;  // 上一回合胜方是否为生还者（换边后用于映射到正确队伍）

public Plugin myinfo =
{
	name = "L4D2 - Fix team shuffle",
	author = "Altair Sossai, edited by apples1949",
	description = "Fix teams shuffling during map switching",
	version = "1.2.3",
	url = "https://github.com/SirPlease/L4D2-Competitive-Rework"
};

// ========== API ==========

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	CreateNative("L4D2_FixTeamShuffle_IsFixComplete", Native_IsFixComplete);
	RegPluginLibrary("l4d2_fix_team_shuffle_edi");
	return APLRes_Success;
}

public int Native_IsFixComplete(Handle plugin, int numParams)
{
	return g_bFixCompleted;
}

// ========== Events ==========

public void OnPluginStart()
{
	HookEvent("round_start", RoundStart_Event, EventHookMode_PostNoCopy);
	HookEvent("player_team", PlayerTeam_Event);

	winners = CreateArray(64);
	losers = CreateArray(64);

	g_hFwdFixComplete = new GlobalForward("L4D2_FixTeamShuffle_OnFixComplete", ET_Ignore);

	// 上一回合玩家已不在服务器时，不等待其重新进入
	g_cvIgnoreOffline = CreateConVar("l4d2_fix_team_shuffle_ignore_offline", "1", "上一回合的玩家若已不在服务器中，忽略该玩家立即进行修正，不等待其重新进入", FCVAR_NONE, true, 0.0, true, 1.0);
	// 对抗第一回合/第二回合结束后修正的超时时间（秒），0=禁用超时
	g_cvTimeoutRound1 = CreateConVar("l4d2_fix_team_shuffle_timeout_round1", "5.0", "对抗第一回合结束后队伍修正的超时时间（秒），0=禁用超时");
	g_cvTimeoutRound2 = CreateConVar("l4d2_fix_team_shuffle_timeout_round2", "15.0", "对抗第二回合结束后队伍修正的超时时间（秒），0=禁用超时");
	// 最大修正次数，超过后不再修正，0=不限制
	g_cvMaxAttempts = CreateConVar("l4d2_fix_team_shuffle_max_attempts", "2", "队伍修正的最大尝试次数，超过后不再修正，0=不限制", FCVAR_NONE, true, 0.0);

	g_cvIgnoreOffline.AddChangeHook(CvarChanged_IgnoreOffline);
	g_cvTimeoutRound1.AddChangeHook(CvarChanged_Timeout);
	g_cvTimeoutRound2.AddChangeHook(CvarChanged_Timeout);
	g_cvMaxAttempts.AddChangeHook(CvarChanged_MaxAttempts);

	g_bIgnoreOffline = g_cvIgnoreOffline.BoolValue;
	g_fTimeoutRound1 = g_cvTimeoutRound1.FloatValue;
	g_fTimeoutRound2 = g_cvTimeoutRound2.FloatValue;
	g_iMaxAttempts = g_cvMaxAttempts.IntValue;
}

void CvarChanged_IgnoreOffline(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_bIgnoreOffline = convar.BoolValue;
}

void CvarChanged_Timeout(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (convar == g_cvTimeoutRound1)
		g_fTimeoutRound1 = convar.FloatValue;
	else if (convar == g_cvTimeoutRound2)
		g_fTimeoutRound2 = convar.FloatValue;
}

void CvarChanged_MaxAttempts(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_iMaxAttempts = convar.IntValue;
}

public void OnRoundIsLive()
{
	DisableFixTeam();
	ClearTeamsData();
	CancelTimeoutTimer();
}

public void L4D2_OnEndVersusModeRound_Post()
{
	SaveTeams();
}

void RoundStart_Event(Handle event, const char[] name, bool dontBroadcast)
{
	// 仅在对抗模式生效，避免在战役/写实等模式下读取对战分数抛错
	if (!L4D_IsVersusMode())
		return;

	DisableFixTeam();
	CancelTimeoutTimer();

	if (L4D_HasMapStarted() && IsNewGame())
	{
		ClearTeamsData();
		return;
	}

	CreateTimer(1.0, EnableFixTeam_Timer);
}

void PlayerTeam_Event(Event event, const char[] name, bool dontBroadcast)
{
	// 仅在对抗模式生效，避免在战役/写实等模式下读取对战分数抛错
	if (!L4D_IsVersusMode())
		return;

	if (!L4D_HasMapStarted())
		return;

	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!IsClientInGame(client) || IsFakeClient(client))
		return;

	int team = event.GetInt("team");
	if (team == L4D2_TEAM_SPECTATOR)
	{
		int oldteam = event.GetInt("oldteam");
		if (oldteam == L4D2_TEAM_NONE)
			CreateTimer(0.5, ReSpec_Timer, client);

		return;
	}

	if (IsNewGame())
	{
		DisableFixTeam();
		ClearTeamsData();
		CancelTimeoutTimer();
		return;
	}

	CreateTimer(1.0, FixTeam_Timer);
}

// ========== Timers ==========

Action ReSpec_Timer(Handle timer, any client)
{
	if (IsClientInGame(client)
	&& GetClientTeam(client) == L4D2_TEAM_SPECTATOR
	&& FindValueInArray(winners, client) == -1
	&& FindValueInArray(losers, client) == -1)
	{
		FakeClientCommand(client, "sm_spectate");
	}
	return Plugin_Stop;
}

void FixTeam_Timer(Handle timer)
{
	FixTeams();
}

void EnableFixTeam_Timer(Handle timer)
{
	// 上一回合玩家已不在服务器中（断线）时，从名单移除，不等待其重新进入
	if (g_bIgnoreOffline)
	{
		RemoveOfflinePlayersFromArray(winners);
		RemoveOfflinePlayersFromArray(losers);
	}

	EnableFixTeam();
	FixTeams();

	// 修正未挂起（已完成/超次数/无数据）时，无需再创建超时定时器
	if (!MustFixTheTeams())
		return;

	// 防止 round_start 多次触发导致超时定时器堆积/残留：先清理旧定时器再创建新的
	CancelTimeoutTimer();

	// 按保存数据时的回合选择超时时间
	g_fLastTimeout = (g_iSavedRound == 0) ? g_fTimeoutRound1 : g_fTimeoutRound2;

	if (g_fLastTimeout > 0.0)
		g_hTimeoutTimer = CreateTimer(g_fLastTimeout, DisableFixTeam_Timer);
}

void DisableFixTeam_Timer(Handle timer)
{
	g_hTimeoutTimer = INVALID_HANDLE;

	// 修正已完成或被其他流程关闭（回合开始/新游戏），不输出超时提示
	// 注意：必须在 DisableFixTeam() 之前读取 fixTeam，否则其恒为 false
	bool wasPending = fixTeam && !g_bFixCompleted;

	DisableFixTeam();

	if (!wasPending)
		return;

	PrintToChatAll("\x01[队伍修正] 队伍修正已超时关闭（%.0f秒），如有问题请联系管理员", g_fLastTimeout);
}

// ========== Team State ==========

void SaveTeams()
{
	ClearTeamsData();

	// 新一轮修正周期，重置修正次数
	g_iFixAttempts = 0;

	// 记录保存数据时的回合号（0=第一回合, 1=第二回合），用于选择对应的超时时间。
	// 必须在此处（回合结束）读取 m_bInSecondHalfOfRound：此刻它仍等于刚结束的回合；
	// 若等到下一个 round_start 才读，值已被新回合覆盖，会选错超时。
	g_iSavedRound = GameRules_GetProp("m_bInSecondHalfOfRound");

	bool survivorsAreWinning = SurvivorsAreWinning();

	// 记录胜方在上回合的角色，换边后据此映射（避免修正时重新用已翻转的比分导致平局判定不一致）
	g_bWinnersWereSurvivors = survivorsAreWinning;

	int winnerTeam = survivorsAreWinning ? L4D2_TEAM_SURVIVOR : L4D2_TEAM_INFECTED;
	int losersTeam = survivorsAreWinning ? L4D2_TEAM_INFECTED : L4D2_TEAM_SURVIVOR;

	CopyClientsToArray(winners, winnerTeam);
	CopyClientsToArray(losers, losersTeam);
}

void CopyClientsToArray(ArrayList arrayList, int team)
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || IsFakeClient(client) || GetClientTeam(client) != team)
			continue;

		PushArrayCell(arrayList, client);
	}
}

// ========== Core Fix Logic ==========

void FixTeams()
{
	if (!MustFixTheTeams())
		return;

	// 超过最大修正次数则不再修正
	if (g_iMaxAttempts > 0 && g_iFixAttempts >= g_iMaxAttempts)
	{
		DisableFixTeam();
		CancelTimeoutTimer();
		PrintToChatAll("\x01[队伍修正] 已超过最大修正次数（%d），停止修正", g_iMaxAttempts);
		return;
	}

	g_iFixAttempts++;

	DisableFixTeam();

	// 使用上一回合保存的胜方角色映射当前队伍：换边后，上回合生还者胜方回到感染者，反之回到生还者
	int winnerTeam = g_bWinnersWereSurvivors ? L4D2_TEAM_INFECTED : L4D2_TEAM_SURVIVOR;
	int losersTeam = g_bWinnersWereSurvivors ? L4D2_TEAM_SURVIVOR : L4D2_TEAM_INFECTED;

	// 优化：如果所有玩家已经在正确队伍，直接完成
	if (PlayersInCorrectTeam(winners, winnerTeam) && PlayersInCorrectTeam(losers, losersTeam))
	{
		MarkFixComplete();
		return;
	}

	PrintToChatAll("\x01[队伍修正] 正在恢复上回合队伍分配...");

	MoveToSpectatorWhoIsNotInTheTeam(winners, winnerTeam);
	MoveToSpectatorWhoIsNotInTheTeam(losers, losersTeam);

	MoveSpectatorsToTheCorrectTeam(winners, winnerTeam);
	MoveSpectatorsToTheCorrectTeam(losers, losersTeam);

	bool winnersInCorrectTeam = PlayersInCorrectTeam(winners, winnerTeam);
	bool losersInCorrectTeam = PlayersInCorrectTeam(losers, losersTeam);

	if (winnersInCorrectTeam && losersInCorrectTeam)
	{
		MarkFixComplete();
		return;
	}

	PrintToChatAll("\x01[队伍修正] 队伍尚未完全归位，等待重试...");
	EnableFixTeam();
}

void MoveToSpectatorWhoIsNotInTheTeam(ArrayList arrayList, int team)
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || IsFakeClient(client) || GetClientTeam(client) != team)
			continue;

		if (FindValueInArray(arrayList, client) == -1)
		{
			MovePlayerToTeam(client, L4D2_TEAM_SPECTATOR);
			PrintToChat(client, "\x01[队伍修正] 你不在上回合的队伍中，已暂时移到旁观");
		}
	}
}

void MoveSpectatorsToTheCorrectTeam(ArrayList arrayList, int team)
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || IsFakeClient(client) || GetClientTeam(client) != L4D2_TEAM_SPECTATOR)
			continue;

		if (FindValueInArray(arrayList, client) != -1)
		{
			MovePlayerToTeam(client, team);
			PrintToChat(client, "\x01[队伍修正] 你已回到上回合的队伍（%s）", team == L4D2_TEAM_SURVIVOR ? "幸存者" : "感染者");
		}
	}
}

bool PlayersInCorrectTeam(ArrayList arrayList, int team)
{
	int arraySize = GetArraySize(arrayList);

	for (int i = 0; i < arraySize; i++)
	{
		int client = GetArrayCell(arrayList, i);

		if (!IsClientInGame(client) || IsFakeClient(client) || GetClientTeam(client) != team)
			return false;
	}

	return true;
}

// ========== Helpers ==========

bool SurvivorsAreWinning()
{
	int flipped = GameRules_GetProp("m_bAreTeamsFlipped");

	int survivorIndex = flipped ? 1 : 0;
	int infectedIndex = flipped ? 0 : 1;

	int survivorScore = L4D2Direct_GetVSCampaignScore(survivorIndex);
	int infectedScore = L4D2Direct_GetVSCampaignScore(infectedIndex);

	return survivorScore >= infectedScore;
}

bool MustFixTheTeams()
{
	return fixTeam && !TeamsDataIsEmpty();
}

void EnableFixTeam()
{
	fixTeam = true;
	g_bFixCompleted = false;
}

void DisableFixTeam()
{
	fixTeam = false;
}

void ClearTeamsData()
{
	winners.Clear();
	losers.Clear();
}

void CancelTimeoutTimer()
{
	if (g_hTimeoutTimer != INVALID_HANDLE)
	{
		KillTimer(g_hTimeoutTimer);
		g_hTimeoutTimer = INVALID_HANDLE;
	}
}

void RemoveOfflinePlayersFromArray(ArrayList arrayList)
{
	for (int i = GetArraySize(arrayList) - 1; i >= 0; i--)
	{
		int client = GetArrayCell(arrayList, i);

		// 断线玩家（连接中的也算在服务器内）无需等待，直接移除
		if (!IsClientConnected(client))
			RemoveFromArray(arrayList, i);
	}
}

bool TeamsDataIsEmpty()
{
	return GetArraySize(winners) == 0 && GetArraySize(losers) == 0;
}

bool IsNewGame()
{
	int teamAScore = L4D2Direct_GetVSCampaignScore(0);
	int teamBScore = L4D2Direct_GetVSCampaignScore(1);

	return teamAScore == 0 && teamBScore == 0;
}

// ========== Fix Complete Notification ==========

void MarkFixComplete()
{
	g_bFixCompleted = true;

	// 修正已完成，取消挂起的超时定时器
	CancelTimeoutTimer();

	PrintToChatAll("\x01[队伍修正] 队伍修正完成！所有玩家已归位。");

	Call_StartForward(g_hFwdFixComplete);
	Call_Finish();
}

// ========== Move Player ==========

void MovePlayerToTeam(int client, int team)
{
	// 队伍已满时不允许移入
	if (team != L4D2_TEAM_SPECTATOR && NumberOfPlayersInTheTeam(team) >= TeamSize(team))
		return;

	// 使用 if-else 替代 switch，避免 SourcePawn 各版本的 fallthrough 行为差异
	if (team == L4D2_TEAM_SPECTATOR)
	{
		ChangeClientTeam(client, L4D2_TEAM_SPECTATOR);
	}
	else if (team == L4D2_TEAM_SURVIVOR)
	{
		FakeClientCommand(client, "jointeam 2");
	}
	else if (team == L4D2_TEAM_INFECTED)
	{
		ChangeClientTeam(client, L4D2_TEAM_INFECTED);
	}
}

int NumberOfPlayersInTheTeam(int team)
{
	int count = 0;

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || IsFakeClient(client) || GetClientTeam(client) != team)
			continue;

		count++;
	}

	return count;
}

int TeamSize(int team)
{
	// 感染者与幸存者的人数上限由不同 ConVar 控制
	if (team == L4D2_TEAM_INFECTED)
		return GetConVarInt(FindConVar("z_max_player_zombies"));

	return GetConVarInt(FindConVar("survivor_limit"));
}
