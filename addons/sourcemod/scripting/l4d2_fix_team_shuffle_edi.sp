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

public Plugin myinfo =
{
	name = "L4D2 - Fix team shuffle",
	author = "Altair Sossai, edited by apples1949",
	description = "Fix teams shuffling during map switching",
	version = "1.0.2",
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
}

public void OnRoundIsLive()
{
	DisableFixTeam();
	ClearTeamsData();
}

public void L4D2_OnEndVersusModeRound_Post()
{
	SaveTeams();
}

void RoundStart_Event(Handle event, const char[] name, bool dontBroadcast)
{
	DisableFixTeam();

	if (L4D_HasMapStarted() && IsNewGame())
	{
		ClearTeamsData();
		return;
	}

	CreateTimer(1.0, EnableFixTeam_Timer);
}

void PlayerTeam_Event(Event event, const char[] name, bool dontBroadcast)
{
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

Action FixTeam_Timer(Handle timer)
{
	FixTeams();

	return Plugin_Continue;
}

Action EnableFixTeam_Timer(Handle timer)
{
	EnableFixTeam();
	FixTeams();

	// 防止 round_start 多次触发导致超时定时器堆积
	if (g_hTimeoutTimer == INVALID_HANDLE)
		g_hTimeoutTimer = CreateTimer(30.0, DisableFixTeam_Timer);

	return Plugin_Continue;
}

Action DisableFixTeam_Timer(Handle timer)
{
	g_hTimeoutTimer = INVALID_HANDLE;
	DisableFixTeam();

	// 修正已完成或被其他流程关闭（回合开始/新游戏），不输出超时提示
	if (!fixTeam || g_bFixCompleted)
		return Plugin_Continue;

	PrintToChatAll("\x01[队伍修正] 队伍修正已超时关闭（30秒）");

	return Plugin_Continue;
}

// ========== Team State ==========

void SaveTeams()
{
	ClearTeamsData();

	bool survivorsAreWinning = SurvivorsAreWinning();

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

	DisableFixTeam();

	bool survivorsAreWinning = SurvivorsAreWinning();

	int winnerTeam = survivorsAreWinning ? L4D2_TEAM_SURVIVOR : L4D2_TEAM_INFECTED;
	int losersTeam = survivorsAreWinning ? L4D2_TEAM_INFECTED : L4D2_TEAM_SURVIVOR;

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
	if (g_hTimeoutTimer != INVALID_HANDLE)
	{
		KillTimer(g_hTimeoutTimer);
		g_hTimeoutTimer = INVALID_HANDLE;
	}

	PrintToChatAll("\x01[队伍修正] 队伍修正完成！所有玩家已归位。");

	Call_StartForward(g_hFwdFixComplete);
	Call_Finish();
}

// ========== Move Player ==========

void MovePlayerToTeam(int client, int team)
{
	// 队伍已满时不允许移入
	if (team != L4D2_TEAM_SPECTATOR && NumberOfPlayersInTheTeam(team) >= TeamSize())
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

int TeamSize()
{
	return GetConVarInt(FindConVar("survivor_limit"));
}
