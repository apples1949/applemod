#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

// Loaded before SuperVersus by generalfixes.cfg. Never fall back to engine
// team changes when the 12v12 owner is absent or still restoring teams.
native bool SV12_CanManageTeams();
native bool SV12_RequestTeam(int client, int team);
native int SV12_GetHumanTeam(int client);
native bool SV12_ReconcileSurvivors();

#define TEAM_SPEC 1
#define TEAM_SURVIVOR 2
#define TEAM_INFECTED 3

int pendingSwaps[MAXPLAYERS + 1];

public Plugin myinfo =
{
	name = "Player Management (12v12)",
	author = "CanadaRox, apples1949",
	description = "Admin team commands delegated to the 12v12 multiplayer owner",
	version = "7.1.4-12v12",
	url = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	MarkNativeAsOptional("SV12_CanManageTeams");
	MarkNativeAsOptional("SV12_RequestTeam");
	MarkNativeAsOptional("SV12_GetHumanTeam");
	MarkNativeAsOptional("SV12_ReconcileSurvivors");
	return APLRes_Success;
}

public void OnPluginStart()
{
	LoadTranslations("common.phrases");
	RegAdminCmd("sm_swap", Swap_Cmd, ADMFLAG_KICK, "sm_swap <player1> [player2] ...");
	RegAdminCmd("sm_swapto", SwapTo_Cmd, ADMFLAG_KICK, "sm_swapto [force] <1|2|3> <player1> ... (12-player limit always applies)");
	RegAdminCmd("sm_swapteams", SwapTeams_Cmd, ADMFLAG_KICK, "Swap the two human teams, including idle owners");
	RegAdminCmd("sm_fixbots", FixBots_Cmd, ADMFLAG_BAN, "Ask the 12v12 multiplayer owner to reconcile survivor bots");
	// !spectate / !spec / !s belong to SuperVersus. This plugin does not create,
	// kick or take over bots and does not register a second spectator handler.
}

public void OnClientDisconnect(int client)
{
	pendingSwaps[client] = 0;
}

bool CheckOwner(int sender)
{
	if (GetFeatureStatus(FeatureType_Native, "SV12_CanManageTeams") != FeatureStatus_Available
		|| GetFeatureStatus(FeatureType_Native, "SV12_RequestTeam") != FeatureStatus_Available
		|| GetFeatureStatus(FeatureType_Native, "SV12_GetHumanTeam") != FeatureStatus_Available
		|| GetFeatureStatus(FeatureType_Native, "SV12_ReconcileSurvivors") != FeatureStatus_Available)
	{
		ReplyToCommand(sender, "[队伍管理] 12V12 多人插件尚未加载，暂时无法操作。");
		return false;
	}
	if (!SV12_CanManageTeams())
	{
		ReplyToCommand(sender, "[队伍管理] 正在加载地图、还原队伍或队伍管理已关闭，请稍后重试。");
		return false;
	}
	return true;
}

void ClearPending()
{
	for (int i = 1; i <= MaxClients; i++) pendingSwaps[i] = 0;
}

int OppositeTeam(int team)
{
	if (team == TEAM_SURVIVOR) return TEAM_INFECTED;
	if (team == TEAM_INFECTED) return TEAM_SURVIVOR;
	return TEAM_SPEC;
}

Action SwapTeams_Cmd(int client, int args)
{
	ClearPending();
	if (!CheckOwner(client)) return Plugin_Handled;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i) || IsClientInKickQueue(i)) continue;
		int team = SV12_GetHumanTeam(i);
		if (team == TEAM_SURVIVOR || team == TEAM_INFECTED)
			pendingSwaps[i] = OppositeTeam(team);
	}
	ApplySwaps(client);
	return Plugin_Handled;
}

Action Swap_Cmd(int client, int args)
{
	ClearPending();
	if (!CheckOwner(client)) return Plugin_Handled;
	if (args < 1)
	{
		ReplyToCommand(client, "用法：sm_swap <玩家1> [玩家2] ...");
		return Plugin_Handled;
	}
	if (CollectTargets(client, 1, args, 0)) ApplySwaps(client);
	ClearPending();
	return Plugin_Handled;
}

Action SwapTo_Cmd(int client, int args)
{
	ClearPending();
	if (!CheckOwner(client)) return Plugin_Handled;
	char arg[32];
	GetCmdArg(1, arg, sizeof(arg));
	int firstTarget = 2;
	if (StrEqual(arg, "force", false))
	{
		firstTarget = 3;
		GetCmdArg(2, arg, sizeof(arg));
	}
	int team = StringToInt(arg);
	if (args < firstTarget || team < TEAM_SPEC || team > TEAM_INFECTED)
	{
		ReplyToCommand(client, "用法：sm_swapto [force] <1旁观|2生还者|3特感> <玩家>；force 不绕过12人上限和队伍还原保护。");
		return Plugin_Handled;
	}
	if (CollectTargets(client, firstTarget, args, team)) ApplySwaps(client);
	ClearPending();
	return Plugin_Handled;
}

bool CollectTargets(int sender, int first, int last, int team)
{
	char arg[MAX_NAME_LENGTH], targetName[MAX_TARGET_LENGTH];
	int targets[MAXPLAYERS + 1];
	bool translated;
	for (int i = first; i <= last; i++)
	{
		GetCmdArg(i, arg, sizeof(arg));
		int count = ProcessTargetString(arg, sender, targets, sizeof(targets), COMMAND_FILTER_NO_BOTS,
			targetName, sizeof(targetName), translated);
		if (count <= 0)
		{
			ReplyToTargetError(sender, count);
			return false;
		}
		for (int j = 0; j < count; j++)
		{
			int target = targets[j];
			if (IsClientInGame(target) && !IsClientInKickQueue(target))
				pendingSwaps[target] = team != 0 ? team : OppositeTeam(SV12_GetHumanTeam(target));
		}
	}
	return true;
}

void ApplySwaps(int sender)
{
	if (!CheckOwner(sender))
	{
		ClearPending();
		return;
	}
	// Validate the complete batch before moving anyone. AFK-owned bodies count
	// as human survivor seats; a force argument never creates a thirteenth seat.
	int finalCount[4];
	int original[MAXPLAYERS + 1];
	int userids[MAXPLAYERS + 1];
	bool staged[MAXPLAYERS + 1];
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i) || IsClientInKickQueue(i)) continue;
		original[i] = SV12_GetHumanTeam(i);
		userids[i] = GetClientUserId(i);
		int target = pendingSwaps[i] != 0 ? pendingSwaps[i] : original[i];
		if (target == TEAM_SURVIVOR || target == TEAM_INFECTED) finalCount[target]++;
	}
	ConVar survivorLimit = FindConVar("l4d_survivor_limit");
	ConVar infectedLimit = FindConVar("l4d_infected_limit");
	if (survivorLimit == null || infectedLimit == null
		|| finalCount[TEAM_SURVIVOR] > survivorLimit.IntValue
		|| finalCount[TEAM_INFECTED] > infectedLimit.IntValue)
	{
		ReplyToCommand(sender, "[队伍管理] 操作取消：换队后会超过队伍人数上限（含闲置玩家的占位）。");
		ClearPending();
		return;
	}
	// Free the outgoing seats first, allowing a full 12-versus-12 exchange.
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!userids[i] || !pendingSwaps[i] || pendingSwaps[i] == original[i]) continue;
		if (GetClientOfUserId(userids[i]) != i || !SV12_RequestTeam(i, TEAM_SPEC))
		{
			// Failed staging must not leave previously moved players stranded.
			for (int j = 1; j <= MaxClients; j++)
				if (staged[j] && GetClientOfUserId(userids[j]) == j) SV12_RequestTeam(j, original[j]);
			ReplyToCommand(sender, "[队伍管理] 有玩家暂时无法换队，已取消并请求还原已移动的玩家。");
			ClearPending();
			return;
		}
		staged[i] = true;
	}
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!staged[i] || GetClientOfUserId(userids[i]) != i) continue;
		if (!SV12_RequestTeam(i, pendingSwaps[i]))
		{
			SV12_RequestTeam(i, original[i]);
			ReplyToCommand(sender, "[队伍管理] %N 暂时无法加入目标队伍，已请求返回原队伍。", i);
		}
	}
	ClearPending();
}

Action FixBots_Cmd(int client, int args)
{
	if (!CheckOwner(client)) return Plugin_Handled;
	if (SV12_ReconcileSurvivors())
		ReplyToCommand(client, "[队伍管理] 已由12V12多人插件检查机器人数量，保留闲置玩家的身体。");
	else
		ReplyToCommand(client, "[队伍管理] 当前回合尚未就绪，请稍后重试。");
	return Plugin_Handled;
}
