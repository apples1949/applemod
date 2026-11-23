#define PLUGIN_VERSION		"1.3-edi"

#include <sourcemod>
#include <sdktools>

#define L4D_VOTE_TEAM_ALL			-1
#define L4D2_VOTE_TEAM_ALL			255

public Plugin:myinfo =
{
	name = "[L4D & L4D2] Vote Poll Fix",
	author = "raziEiL [disawar1]",
	description = "Changes number of players eligible to vote",
	version = PLUGIN_VERSION,
	url = "http://steamcommunity.com/id/raziEiL"
}

public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max)
{
	if (late)
		VPF_PrepareToFindVoteEnt();

	return APLRes_Success;
}

static g_iVoteEntity = INVALID_ENT_REFERENCE, bool:g_bVotePoolFixTriggered, g_iVoteTeamAll;

public OnPluginStart()
{
	CreateConVar("l4d_votepoll_fix_version", PLUGIN_VERSION, "Vote Poll Fix plugin version.", FCVAR_NOTIFY|FCVAR_REPLICATED|FCVAR_DONTRECORD);

	decl String:sGameFolder[32];
	GetGameFolderName(sGameFolder, 32);

	if (StrEqual(sGameFolder, "left4dead")){

		g_iVoteTeamAll = L4D_VOTE_TEAM_ALL
		HookEvent("vote_started", VPF_ev_VoteStarted, EventHookMode_Pre);
	}
	else {

		g_iVoteTeamAll = L4D2_VOTE_TEAM_ALL
		HookUserMessage(GetUserMessageId("VoteStart"), VPF_mh_OnVoteStart);
	}

	HookEvent("round_start", VPF_ev_RoundStart, EventHookMode_PostNoCopy);

	AddCommandListener(VPF_cmdh_Vote, "vote");
}

// ----------------------------------------------------------------------------
//  edi 修复（2026-11-23）：
//  报错 [SM] Exception reported: Client 18 is not in game / [0] GetClientTeam
//       Line 53 ... VPF_cmdh_Vote
//
//  根因：SourceMod 1.11+ 的 client native（GetClientTeam 等）在 client 索引
//  合法但「不在游戏中」时会抛异常（旧版只是返回 0）。AddCommandListener 的
//  回调即使在玩家正在断开/进踢出队列的帧里也会被调用（client != 0 但
//  IsClientInGame(client) == false），这里直接用 GetClientTeam(client) 就抛。
//  注意 client == 0 是服务器控制台执行 vote，同样不能传给 GetClientTeam。
//
//  修法：本文件所有「命令/消息回调里拿到的 client」在使用前统一走 VPF_IsUsableClient()
//  （索引范围 + 已连接 + 在游戏 + 不在踢出队列），并且只在 spectators 计数时才需要
//  team 值；其余 GetClientTeam 调用点本来就带 IsClientInGame 守卫，这里再统一成
//  同一个 helper，避免以后漏改。
// ----------------------------------------------------------------------------
stock bool:VPF_IsUsableClient(client)
{
	return (client > 0 && client <= MaxClients
		&& IsClientConnected(client)
		&& IsClientInGame(client)
		&& !IsClientInKickQueue(client));
}

Action:VPF_cmdh_Vote(client, const String:command[], argc)
{
	// 投票被固定成「仅本方队伍」时才需要拦；触发者必须是可用且在看台的玩家。
	if (!g_bVotePoolFixTriggered)
		return Plugin_Continue;

	if (!VPF_IsUsableClient(client))
		return Plugin_Continue;

	if (GetClientTeam(client) == 1)
		return Plugin_Handled;

	return Plugin_Continue;
}

Action:VPF_ev_RoundStart(Handle:event, const String:name[], bool:dontBroadcast)
{
	VPF_PrepareToFindVoteEnt();
}

Action:VPF_ev_VoteStarted(Handle:event, const String:name[], bool:dontBroadcast)
{
	VPF_PrepareToFix(GetEventInt(event, "team"), GetEventInt(event, "initiator"));
}

Action:VPF_mh_OnVoteStart(UserMsg:msg_id, Handle:bf, const players[], playersNum, bool:reliable, bool:init)
{
	new team = BfReadByte(bf);
	new client = BfReadByte(bf);

	VPF_PrepareToFix(team, client);
}

VPF_PrepareToFix(team, client)
{
	decl iPolls;
	if (IsValidInitiator(client) && IsValidVoteEnt() && IsAnyOneSpectator() && ((team == g_iVoteTeamAll && (iPolls = GetTotalPlayers())) || (iPolls = GetTeammateCount(team)))){

		g_bVotePoolFixTriggered = true;
		SetEntProp(g_iVoteEntity, Prop_Send, "m_potentialVotes", iPolls);
	}
	else
		g_bVotePoolFixTriggered = false;
}

VPF_PrepareToFindVoteEnt()
{
	if (!IsValidVoteEnt())
		CreateTimer(0.5, VPF_t_FindVoteContollerEnt, _, TIMER_FLAG_NO_MAPCHANGE);
}

Action:VPF_t_FindVoteContollerEnt(Handle:timer)
{
	g_iVoteEntity = EntIndexToEntRef(FindEntityByClassname(-1, "vote_controller"));
}

GetTotalPlayers()
{
	new players;

	for (new i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && GetClientTeam(i) > 1 && !IsFakeClient(i))
			players++;

	return players;
}

GetTeammateCount(team)
{
	if (team != 2 && team != 3)
		return 0;

	new teammates;

	for (new i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && GetClientTeam(i) == team && !IsFakeClient(i))
			teammates++;

	return teammates;
}

bool:IsValidInitiator(index)
{
	// initiator 来自事件/user message，可能是已离开的 client，也可能是 0/255 这类哨兵值；
	// 语义保持原版：必须是在游戏中、且不是旁观者（team 1）的玩家。
	return VPF_IsUsableClient(index) && GetClientTeam(index) != 1;
}

bool:IsValidVoteEnt()
{
	return EntRefToEntIndex(g_iVoteEntity) != INVALID_ENT_REFERENCE;
}

bool:IsAnyOneSpectator()
{
	for (new i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && GetClientTeam(i) == 1 && !IsFakeClient(i))
			return true;

	return false;
}
