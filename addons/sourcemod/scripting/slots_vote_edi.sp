#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <builtinvotes>
#include <colors>

Handle g_hVote;
int g_iVoteSlots;
int g_iMapSerial, g_iVoteMapSerial;
bool g_bMapActive = true;
ConVar g_hMinSlots, g_hMaxSlots, g_hServerSlots;

public Plugin myinfo =
{
	name = "[L4D2]slots_edi",
	description = "投票修改服务器公开席位，并保护队伍容量和已连接玩家",
	author = "apples1949",
	version = "1.2",
	url = "https://github.com/NanakaNeko/l4d2_plugins_coop"
};

public void OnPluginStart()
{
	g_hMinSlots = CreateConVar("sm_slot_vote_min", "8", "允许设置的最小公开席位数（实际下限还包括双方队伍容量及已连接真人）", FCVAR_NOTIFY, true, 1.0, true, 31.0);
	g_hMaxSlots = CreateConVar("sm_slot_vote_max", "30", "允许设置的最大公开席位数（须给管理员保留席位留出空间）", FCVAR_NOTIFY, true, 1.0, true, 31.0);
	g_hServerSlots = FindConVar("sv_maxplayers");
	if (g_hServerSlots == null)
		SetFailState("sv_maxplayers is unavailable; install the server slot extension first.");
	RegConsoleCmd("sm_slots", SlotsRequest, "sm_slots <公开席位数>");
}

public void OnMapStart()
{
	g_iMapSerial++;
	g_bMapActive = true;
}

public void OnMapEnd()
{
	g_iMapSerial++;
	g_bMapActive = false;
	g_iVoteSlots = 0;
}

int MinimumSlots()
{
	int minimum = g_hMinSlots.IntValue;
	ConVar survivors = FindConVar("survivor_limit");
	int capacity = survivors == null ? 0 : survivors.IntValue;
	char mode[64];
	ConVar gamemode = FindConVar("mp_gamemode");
	if (gamemode != null)
		gamemode.GetString(mode, sizeof(mode));
	if (StrContains(mode, "versus", false) != -1 || StrContains(mode, "scavenge", false) != -1)
	{
		ConVar infected = FindConVar("z_max_player_zombies");
		if (infected != null)
			capacity += infected.IntValue;
	}
	if (capacity > minimum)
		minimum = capacity;

	int connected;
	for (int client = 1; client <= MaxClients; client++)
		if (IsClientConnected(client) && !IsFakeClient(client))
			connected++;
	if (connected > minimum)
		minimum = connected;
	return minimum;
}

int MaximumSlots()
{
	int maximum = g_hMaxSlots.IntValue;
	ConVar reserved = FindConVar("l4d_reservedslots_adm");
	int reserveCount = reserved == null ? 0 : reserved.IntValue;
	int engineMaximum = 31 - reserveCount;
	if (maximum > engineMaximum)
		maximum = engineMaximum;
	return maximum;
}

bool ValidSlots(int slots, int client, bool report)
{
	int minimum = MinimumSlots(), maximum = MaximumSlots();
	if (slots >= 1 && slots >= minimum && slots <= maximum)
		return true;
	if (report)
		ReplyToCommand(client, "[Slots] 当前允许 %d～%d 个公开席位；不得低于队伍容量或已连接真人数。", minimum, maximum);
	return false;
}

void ApplySlots(int slots)
{
	g_hServerSlots.IntValue = slots;
	// l4d_reservedslots owns the public/hidden slot display when enabled.
	ConVar reserved = FindConVar("l4d_reservedslots_adm");
	if (reserved == null || reserved.IntValue == 0)
	{
		ConVar visible = FindConVar("sv_visiblemaxplayers");
		if (visible != null)
			visible.IntValue = slots;
	}
}

public Action SlotsRequest(int client, int args)
{
	if (client < 0 || client > MaxClients || (client > 0 && !IsClientInGame(client)))
		return Plugin_Handled;
	if (args != 1)
	{
		ReplyToCommand(client, "[Slots] 用法: !slots <公开席位数>，例如 !slots 24。");
		return Plugin_Handled;
	}

	char argument[64];
	GetCmdArg(1, argument, sizeof(argument));
	int length = strlen(argument);
	bool validNumber = length > 0 && length <= 2;
	for (int i = 0; i < length; i++)
		if (argument[i] < '0' || argument[i] > '9')
			validNumber = false;
	if (!validNumber)
	{
		ReplyToCommand(client, "[Slots] 席位必须是 1～31 的整数。");
		return Plugin_Handled;
	}

	int slots = StringToInt(argument);
	if (!ValidSlots(slots, client, true))
		return Plugin_Handled;
	if (client == 0 || CheckCommandAccess(client, "sm_slots_admin", ADMFLAG_CONFIG))
	{
		ApplySlots(slots);
		CPrintToChatAll("{blue}[{default}Slots{blue}] {default}管理员将公开席位设为 {olive}%d{default} 个。", slots);
	}
	else if (GetClientTeam(client) <= 1)
		ReplyToCommand(client, "[Slots] 旁观者不能发起席位投票。");
	else
		StartSlotVote(client, slots);
	return Plugin_Handled;
}

void StartSlotVote(int client, int slots)
{
	if (!IsNewBuiltinVoteAllowed())
	{
		ReplyToCommand(client, "[Slots] 暂时无法发起投票。");
		return;
	}
	int count;
	int[] players = new int[MaxClients];
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) > 1)
			players[count++] = i;
	if (count == 0)
		return;

	g_iVoteSlots = slots;
	g_iVoteMapSerial = g_iMapSerial;
	g_hVote = CreateBuiltinVote(VoteActionHandler, BuiltinVoteType_Custom_YesNo, BuiltinVoteAction_Cancel | BuiltinVoteAction_VoteEnd | BuiltinVoteAction_End);
	char argument[96];
	FormatEx(argument, sizeof(argument), "将服务器公开席位改为 %d 个?", slots);
	SetBuiltinVoteArgument(g_hVote, argument);
	SetBuiltinVoteInitiator(g_hVote, client);
	SetBuiltinVoteResultCallback(g_hVote, SlotVoteResultHandler);
	DisplayBuiltinVote(g_hVote, players, count, 20);
	FakeClientCommand(client, "Vote Yes");
}

public void SlotVoteResultHandler(Handle vote, int num_votes, int num_clients, const int[][] client_info, int num_items, const int[][] item_info)
{
	// A player may have connected, or the mode/limits changed during the vote.
	if (!g_bMapActive || g_iVoteMapSerial != g_iMapSerial || !ValidSlots(g_iVoteSlots, 0, false))
	{
		DisplayBuiltinVoteFail(vote, BuiltinVoteFail_Generic);
		CPrintToChatAll("{blue}[{default}Slots{blue}] {default}容量已变化，取消此次席位修改。");
		return;
	}
	for (int i = 0; i < num_items; i++)
	{
		if (item_info[i][BUILTINVOTEINFO_ITEM_INDEX] == BUILTINVOTES_VOTE_YES && item_info[i][BUILTINVOTEINFO_ITEM_VOTES] > num_clients / 2)
		{
			ApplySlots(g_iVoteSlots);
			DisplayBuiltinVotePass(vote, "修改服务器公开席位...");
			return;
		}
	}
	DisplayBuiltinVoteFail(vote, BuiltinVoteFail_Loses);
}

public void VoteActionHandler(Handle vote, BuiltinVoteAction action, int param1, int param2)
{
	if (action == BuiltinVoteAction_End)
	{
		g_hVote = null;
		delete vote;
	}
	else if (action == BuiltinVoteAction_Cancel)
		DisplayBuiltinVoteFail(vote, view_as<BuiltinVoteFailReason>(param1));
}
