#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <builtinvotes>
#include <colors>

Handle g_hVote;
char   g_sSlots[32];
ConVar hMinSlots;
ConVar hMaxSlots;
int    MaxSlots;
int    MinSlots;

public Plugin myinfo =
{
	name        = "[L4D2]slots_edi",
	description = "投票增加位置",
	author      = "apples1949",
	version     = "1.1",
	url         = "https://github.com/NanakaNeko/l4d2_plugins_coop"
};

public void OnPluginStart()
{
	hMinSlots = CreateConVar("sm_slot_vote_min", "4", "投票限制的最小位置数 (玩家投票不能低于此值)", FCVAR_NOTIFY, true, 1.0, true, 31.0);
	hMaxSlots = CreateConVar("sm_slot_vote_max", "16", "最大投票数 (不能超过31)", FCVAR_NOTIFY, true, 1.0, true, 31.0);
	MaxSlots = GetConVarInt(hMaxSlots);
	MinSlots = GetConVarInt(hMinSlots);
	HookConVarChange(hMaxSlots, CVarChanged);
	HookConVarChange(hMinSlots, CVarChanged);
}

public Action SlotsRequest(int client, int args)
{
	if (client < 0)
	{
		return Plugin_Handled;
	}
	if (args == 1)
	{
		char sSlots[64];
		GetCmdArg(1, sSlots, sizeof(sSlots));
		int Int = StringToInt(sSlots);
		if (Int > MaxSlots)
		{
			CPrintToChat(client, "{blue}[{default}Slots{blue}] {default}你不能在这个服务器上开超过 {olive}%i {default}的位置", MaxSlots);
		}
		else
		{
			if(client == 0)
			{
				CPrintToChatAll("{blue}[{default}Slots{blue}] {olive}管理员 {default}将服务器位置设为 {blue}%i {default}个", Int);
				SetConVarInt(FindConVar("sv_maxplayers"), Int);
				SetConVarInt(FindConVar("sv_visiblemaxplayers"), Int);
			}
			else if (GetUserAdmin(client) != INVALID_ADMIN_ID )
			{
				CPrintToChatAll("{blue}[{default}Slots{blue}] {olive}管理员 {default}将服务器位置设为 {blue}%i {default}个", Int);
				SetConVarInt(FindConVar("sv_maxplayers"), Int);
				SetConVarInt(FindConVar("sv_visiblemaxplayers"), Int);
			}
			else if (Int < MinSlots)
			{
				CPrintToChat(client, "{blue}[{default}Slots{blue}] {default}你不能将服务器位置设为小于{blue}%i {default}个.", MinSlots);
			}
			else if (StartSlotVote(client, sSlots))
			{
				strcopy(g_sSlots, sizeof(g_sSlots), sSlots);
				FakeClientCommand(client, "Vote Yes");
			}
		}
	}
	else
	{
		CPrintToChat(client, "{blue}[{default}Slots{blue}] {default}用法: {olive}!slots {default}<{olive}你想要设置的服务器位置数量{default}> {blue}| {default}例子: {olive}!slots 8");
	}
	return Plugin_Handled;
}

bool StartSlotVote(int client, char[] Slots)
{
	if (GetClientTeam(client) == 1)
	{
		PrintToChat(client, "旁观者不允许使用命令.");
		return false;
	}

	if (IsNewBuiltinVoteAllowed())
	{
		int iNumPlayers;
		int[] iPlayers = new int[MaxClients];
		for (int i=1; i<=MaxClients; i++)
		{
			if (!IsClientInGame(i) || IsFakeClient(i) || (GetClientTeam(i) == 1))
			{
				continue;
			}
			iPlayers[iNumPlayers++] = i;
		}

		char sBuffer[64];
		g_hVote = CreateBuiltinVote(VoteActionHandler, BuiltinVoteType_Custom_YesNo, BuiltinVoteAction_Cancel | BuiltinVoteAction_VoteEnd | BuiltinVoteAction_End);
		Format(sBuffer, sizeof(sBuffer), "更改服务器位置到 '%s' 个?", Slots);
		SetBuiltinVoteArgument(g_hVote, sBuffer);
		SetBuiltinVoteInitiator(g_hVote, client);
		SetBuiltinVoteResultCallback(g_hVote, SlotVoteResultHandler);
		DisplayBuiltinVote(g_hVote, iPlayers, iNumPlayers, 20);
		return true;
	}

	PrintToChat(client, "投票功能暂时不能使用.");
	return false;
}

public void SlotVoteResultHandler(Handle vote, int num_votes, int num_clients, const int[][] client_info, int num_items, const int[][] item_info)
{
	for (int i=0; i<num_items; i++)
	{
		if (item_info[i][BUILTINVOTEINFO_ITEM_INDEX] == BUILTINVOTES_VOTE_YES)
		{
			if (item_info[i][BUILTINVOTEINFO_ITEM_VOTES] > (num_votes / 2))
			{
				int Slots = StringToInt(g_sSlots, 10);
				DisplayBuiltinVotePass(vote, "更改服务器位置...");
				SetConVarInt(FindConVar("sv_maxplayers"), Slots);
				SetConVarInt(FindConVar("sv_visiblemaxplayers"), Slots);
				return;
			}
		}
	}
	DisplayBuiltinVoteFail(vote, BuiltinVoteFail_Loses);
}

public void VoteActionHandler(Handle vote, BuiltinVoteAction action, int param1, int param2)
{
	switch (action)
	{
		case BuiltinVoteAction_End:
		{
			g_hVote = INVALID_HANDLE;
			delete vote;
		}
		case BuiltinVoteAction_Cancel:
		{
			DisplayBuiltinVoteFail(vote, view_as<BuiltinVoteFailReason>(param1));
		}
	}
}

public void CVarChanged(Handle cvar, const char[] oldValue, const char[] newValue)
{
	MaxSlots = GetConVarInt(hMaxSlots);
	MinSlots = GetConVarInt(hMinSlots);
}
