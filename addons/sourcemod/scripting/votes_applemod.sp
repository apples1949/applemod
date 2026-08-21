#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#include <multicolors>
#include <builtinvotes>

#define MaxHealth               100
#define MENU_TIME               20
#define VOTE_TIME               20
#define L4D_TEAM_SPECTATE       1
#define MAX_CAMPAIGN_LIMIT      64
#define READY_RESTART_MAP_DELAY 2

// 投票广播范围
enum VoteBroadcast
{
	VoteBroadcast_All,		// 全体玩家(含旁观)
	VoteBroadcast_NotSpec,	// 仅游戏中的玩家
	VoteBroadcast_Team,		// 仅投票发起者所在阵营
}

enum voteType
{
	None,
	hp,
	alltalk,
	alltalk2,
	restartmap,
	kick,
	map,
	map2,
	forcespectate,
	forcedellobby,
	forcestartgame,
	hud,
}

bool	 game_l4d2 = false;
Handle	 g_hVote = null;
voteType g_voteType = None;
char	 g_sVotePassText[128];

int		kickplayer_userid;
char	kickplayer_name[MAX_NAME_LENGTH];
char	kickplayer_SteamId[MAX_NAME_LENGTH];
char	votesmaps[MAX_NAME_LENGTH];
char	votesmapsname[MAX_NAME_LENGTH];
int		forcespectateid;
char	forcespectateplayername[MAX_NAME_LENGTH];
int		fsgclient;
static int g_iSpectatePenaltyCounter[MAXPLAYERS + 1];
static int g_votedelay;

ConVar g_Cvar_Limits;
ConVar VotensHpED;
ConVar VotensAlltalkED;
ConVar VotensRestartmapED;
ConVar VotensMapED;
ConVar VotensMap2ED;
ConVar VotensED;
ConVar VotensKickED;
ConVar VotensForceSpectateED;
ConVar VotenForceDelLobby;
ConVar VotensForceStartGameED;
ConVar VotensHudED;
ConVar g_hCvarPlayerLimit;
ConVar g_hKickImmueAccess;
ConVar hforcespectate_penalty;
ConVar hvotedelay_time;

int	 g_iCvarPlayerLimit;
float g_fLimit;
bool VotensHpE_D, VotensAlltalkE_D, VotensRestartmapE_D, VotensMapE_D, VotensMap2E_D;
bool g_bEnable, g_bVotensKickED, g_bVotensForceSpectateED, g_bVotenForceDelLobby, VotensForceStartGameE_D, VotensHudE_D;
char g_sKickImmueAccesslvl[16];
int	 iforcespectate_penalty;
int	 ivotedelay_time;

int	 g_iCount;
char g_sMapinfo[MAX_CAMPAIGN_LIMIT][MAX_NAME_LENGTH];
char g_sMapname[MAX_CAMPAIGN_LIMIT][MAX_NAME_LENGTH];

int		MapRestartDelay;
Handle	MapCountdownTimer;
bool	isMapRestartPending = false;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	EngineVersion test = GetEngineVersion();

	if (test == Engine_Left4Dead) game_l4d2 = false;
	else if (test == Engine_Left4Dead2) game_l4d2 = true;
	else
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 1 & 2.");
		return APLRes_SilentFailure;
	}

	return APLRes_Success;
}

public Plugin myinfo =
{
	name		= "Votes AppleMod",
	author		= "apples1949",
	description = "Votes Commands (builtinvotes)",
	version		= "1.0.0",
	url			= "https://github.com/apples1949/l4dplugins"
};

public void OnPluginStart()
{
	RegConsoleCmd("voteshp", Command_VoteHp);
	RegConsoleCmd("votesalltalk", Command_VoteAlltalk);
	RegConsoleCmd("votesalltalk2", Command_VoteAlltalk2);
	RegConsoleCmd("votesrestartmap", Command_VoteRestartmap);
	RegConsoleCmd("votesmapsmenu", Command_VotemapsMenu);
	RegConsoleCmd("votesmaps2menu", Command_Votemaps2Menu);
	RegConsoleCmd("voteskick", Command_VotesKick);
	RegConsoleCmd("sm_votes", Command_Votes, "open vote menu");
	RegConsoleCmd("sm_callvote", Command_Votes, "open vote menu");
	RegConsoleCmd("sm_callvotes", Command_Votes, "open vote menu");
	RegConsoleCmd("votesforcespectate", Command_Votesforcespectate);
	RegConsoleCmd("votesforcedellobby", Command_Votesforcedellobby);
	RegConsoleCmd("votesforcestartgame", Command_Votesforcestartgame);
	RegConsoleCmd("voteshud", Command_VoteHud);
	RegAdminCmd("sm_restartmap", CommandRestartMap, ADMFLAG_CHANGEMAP, "sm_restartmap - changelevels to the current map");
	RegAdminCmd("sm_rs", CommandRestartMap, ADMFLAG_CHANGEMAP, "sm_restartmap - changelevels to the current map");

	g_Cvar_Limits		   = CreateConVar("sm_votes_s", "0.51", "超过这个百分比才能投票通过", 0, true, 0.05, true, 1.0);
	VotensHpED			   = CreateConVar("l4d_VotenshpED", "1", "如果为1，则开启回血投票选项", FCVAR_NOTIFY);
	VotensAlltalkED		   = CreateConVar("l4d_VotensalltalkED", "1", "如果为1，则开启调整全体语音投票选项", FCVAR_NOTIFY);
	VotensRestartmapED	   = CreateConVar("l4d_VotensrestartmapED", "1", "如果为1，则开启重置当前地图选项", FCVAR_NOTIFY);
	VotensMapED			   = CreateConVar("l4d_VotensmapED", "1", "如果为1，则开启投票更换官图选项", FCVAR_NOTIFY);
	VotensMap2ED		   = CreateConVar("l4d_Votensmap2ED", "0", "如果为1，则开启投票更换三方图选项", FCVAR_NOTIFY);
	VotensED			   = CreateConVar("l4d_Votens", "1", "如果为0，则关闭此插件，反之开启", FCVAR_NOTIFY);
	VotensKickED		   = CreateConVar("l4d_VotesKickED", "1", "如果为1，则开启投票踢出玩家选项", FCVAR_NOTIFY);
	VotensForceSpectateED  = CreateConVar("l4d_VotesForceSpectateED", "1", "如果为1，则开启投票强制玩家旁观选项", FCVAR_NOTIFY);
	VotenForceDelLobby	   = CreateConVar("l4d_VotesForceDelLobby", "1", "如果为1,则开启投票删除大厅选项", FCVAR_NOTIFY);
	VotensForceStartGameED = CreateConVar("l4d_VotesForceStartGame", "1", "如果为1，则开启投票强制开始游戏选项", FCVAR_NOTIFY);
	VotensHudED			   = CreateConVar("l4d_VotensHudED", "1", "如果为1，则开启投票开关顶部HUD选项", FCVAR_NOTIFY);
	g_hCvarPlayerLimit	   = CreateConVar("sm_vote_player_limit", "2", "当有多少玩家才能启动插件", FCVAR_NOTIFY);
	g_hKickImmueAccess	   = CreateConVar("l4d_VotesKick_immue_access_flag", "z", "有这些标识的玩家不会被投票踢出以及强制旁观(无内容=所有人, -1:没有人)", FCVAR_NOTIFY);
	hforcespectate_penalty = CreateConVar("l4d_forcespectate_penalty", "10", "强制旁观多久才能重新加入队伍", FCVAR_NOTIFY);
	hvotedelay_time		   = CreateConVar("l4d_votedelay_time", "30", "多长时间才能发起新投票", FCVAR_NOTIFY);

	HookEvent("round_start", event_Round_Start);

	GetCvars();
	g_Cvar_Limits.AddChangeHook(ConVarChanged_Cvars);
	VotensHpED.AddChangeHook(ConVarChanged_Cvars);
	VotensAlltalkED.AddChangeHook(ConVarChanged_Cvars);
	VotensRestartmapED.AddChangeHook(ConVarChanged_Cvars);
	VotensMapED.AddChangeHook(ConVarChanged_Cvars);
	VotensMap2ED.AddChangeHook(ConVarChanged_Cvars);
	VotensED.AddChangeHook(ConVarChanged_Cvars);
	VotensKickED.AddChangeHook(ConVarChanged_Cvars);
	VotensForceSpectateED.AddChangeHook(ConVarChanged_Cvars);
	VotenForceDelLobby.AddChangeHook(ConVarChanged_Cvars);
	VotensForceStartGameED.AddChangeHook(ConVarChanged_Cvars);
	VotensHudED.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarPlayerLimit.AddChangeHook(ConVarChanged_Cvars);
	g_hKickImmueAccess.AddChangeHook(ConVarChanged_Cvars);
	hforcespectate_penalty.AddChangeHook(ConVarChanged_Cvars);
	hvotedelay_time.AddChangeHook(ConVarChanged_Cvars);

	//AutoExecConfig(true, "votes_applemod");
}

public void ConVarChanged_Cvars(ConVar convar, const char[] oldValue, const char[] newValue)
{
	GetCvars();
}

void GetCvars()
{
	g_fLimit				= g_Cvar_Limits.FloatValue;
	g_iCvarPlayerLimit		= g_hCvarPlayerLimit.IntValue;
	VotensHpE_D				= VotensHpED.BoolValue;
	VotensAlltalkE_D		= VotensAlltalkED.BoolValue;
	VotensRestartmapE_D		= VotensRestartmapED.BoolValue;
	VotensMapE_D			= VotensMapED.BoolValue;
	VotensMap2E_D			= VotensMap2ED.BoolValue;
	g_bVotensKickED			= VotensKickED.BoolValue;
	g_bVotensForceSpectateED = VotensForceSpectateED.BoolValue;
	g_bVotenForceDelLobby	= VotenForceDelLobby.BoolValue;
	VotensForceStartGameE_D = VotensForceStartGameED.BoolValue;
	VotensHudE_D			= VotensHudED.BoolValue;
	g_bEnable				= VotensED.BoolValue;
	g_hKickImmueAccess.GetString(g_sKickImmueAccesslvl, sizeof(g_sKickImmueAccesslvl));
	iforcespectate_penalty = hforcespectate_penalty.IntValue;
	ivotedelay_time		   = hvotedelay_time.IntValue;
}

// 判断对局是否已开始(替代原插件中的 readyup g_enb 判断)
bool IsGameLive()
{
	return L4D_HasAnySurvivorLeftSafeArea();
}

public void event_Round_Start(Event event, const char[] name, bool dontBroadcast)
{
	// 回合开始后重置强制旁观计时器
	for (int i = 1; i <= MaxClients; i++)
	{
		g_iSpectatePenaltyCounter[i] = iforcespectate_penalty;
	}
}

// 开局提示
public void OnClientPutInServer(int client)
{
	if (!IsFakeClient(client))
	{
		CreateTimer(5.0, g_hTimerAnnounce, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	}
	g_iSpectatePenaltyCounter[client] = iforcespectate_penalty;
}

public Action g_hTimerAnnounce(Handle timer, any client)
{
	if ((client = GetClientOfUserId(client)) && IsClientInGame(client))
	{
		CPrintToChat(client, "[{olive}VOTE{default}]{green}游戏自带投票已禁用! 你可以使用指令!votes进行以下投票:开关全体语音 重置地图 开始新图 强制踢出玩家或强制玩家旁观");	//聊天窗提示.
		CPrintToChat(client, "[{olive}VOTE{default}]{green}对了,如果有新手不会F1开始游戏,你也可以投票强制开始游戏哦!");
	}
	return Plugin_Continue;
}

public void OnMapStart()
{
	isMapRestartPending = false;
	MapCountdownTimer	= INVALID_HANDLE;

	if (IsBuiltinVoteInProgress())
	{
		CancelBuiltinVote();
	}

	ParseCampaigns();

	g_votedelay = 15;
	CreateTimer(1.0, Timer_VoteDelay, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

	for (int i = 1; i <= MaxClients; i++)
	{
		g_iSpectatePenaltyCounter[i] = iforcespectate_penalty;
	}
	PrecacheSound("buttons/blip1.wav");
}

// ====================================================
// 主投票菜单 (adminmenu 风格 Menu, 不再使用 Panel)
// ====================================================
public Action Command_Votes(int client, int args)
{
	if (client == 0)
	{
		PrintToServer("[VOTE] sm_votes cannot be used by server.");
		return Plugin_Handled;
	}
	if (GetClientTeam(client) == L4D_TEAM_SPECTATE)
	{
		ReplyToCommand(client, "[VOTE] 旁观无法发起投票.");
		return Plugin_Handled;
	}
	if (!g_bEnable)
	{
		CPrintToChat(client, "[{olive}VOTE{default}]投票菜单插件已关闭!");
		return Plugin_Handled;
	}

	Menu menu = new Menu(Votes_Menu);
	menu.SetTitle("投票菜单");
	menu.AddItem("hp", VotensHpE_D ? "全体回血" : "全体回血 (禁用中)");
	menu.AddItem("alltalk", VotensAlltalkE_D ? "调整全体语音" : "调整全体语音 (禁用中)");
	menu.AddItem("restartmap", VotensRestartmapE_D ? "重置当前地图" : "重置当前地图 (禁用中)");
	menu.AddItem("map", VotensMapE_D ? "投票更换官图" : "投票更换官图 (禁用中)");
	menu.AddItem("map2", VotensMap2E_D ? "投票更换三方图" : "投票更换三方图 (禁用中)");
	menu.AddItem("kick", g_bVotensKickED ? "踢出玩家" : "踢出玩家 (禁用中)");
	menu.AddItem("forcespectate", g_bVotensForceSpectateED ? "强制玩家旁观" : "强制玩家旁观 (禁用中)");
	menu.AddItem("dellobby", g_bVotenForceDelLobby ? "强制删除游戏大厅" : "强制删除游戏大厅 (禁用中)");
	menu.AddItem("forcestart", (VotensForceStartGameE_D && !IsGameLive()) ? "强制开始游戏" : "强制开始游戏 (禁用中)");
	menu.AddItem("hud", VotensHudE_D ? "开关顶部HUD" : "开关顶部HUD (禁用中)");
	menu.ExitButton = true;
	menu.Display(client, MENU_TIME);

	return Plugin_Handled;
}

public int Votes_Menu(Menu menu, MenuAction action, int client, int itemNum)
{
	if (action == MenuAction_Select)
	{
		char item[16];
		menu.GetItem(itemNum, item, sizeof(item));

		if (StrEqual(item, "hp"))
		{
			if (!VotensHpE_D)
			{
				CPrintToChat(client, "[{olive}VOTE{default}]全体回血已禁用");
				FakeClientCommand(client, "sm_votes");
			}
			else
			{
				FakeClientCommand(client, "voteshp");
			}
		}
		else if (StrEqual(item, "alltalk"))
		{
			if (!VotensAlltalkE_D)
			{
				CPrintToChat(client, "[{olive}VOTE{default}]调整全体语音已禁用");
				FakeClientCommand(client, "sm_votes");
			}
			else if (FindConVar("sv_alltalk").IntValue == 0)
			{
				FakeClientCommand(client, "votesalltalk");
			}
			else
			{
				FakeClientCommand(client, "votesalltalk2");
			}
		}
		else if (StrEqual(item, "restartmap"))
		{
			if (!VotensRestartmapE_D)
			{
				CPrintToChat(client, "[{olive}VOTE{default}]重置当前地图已禁用");
				FakeClientCommand(client, "sm_votes");
			}
			else
			{
				FakeClientCommand(client, "votesrestartmap");
			}
		}
		else if (StrEqual(item, "map"))
		{
			if (!VotensMapE_D)
			{
				CPrintToChat(client, "[{olive}VOTE{default}]投票更换官图已禁用,请使用游戏自带投票");
				FakeClientCommand(client, "sm_votes");
			}
			else
			{
				FakeClientCommand(client, "votesmapsmenu");
			}
		}
		else if (StrEqual(item, "map2"))
		{
			if (!VotensMap2E_D)
			{
				CPrintToChat(client, "[{olive}VOTE{default}]投票更换三方图已禁用");
				FakeClientCommand(client, "sm_votes");
			}
			else
			{
				FakeClientCommand(client, "votesmaps2menu");
			}
		}
		else if (StrEqual(item, "kick"))
		{
			if (!g_bVotensKickED)
			{
				CPrintToChat(client, "[{olive}VOTE{default}]踢出玩家已禁用");
				FakeClientCommand(client, "sm_votes");
			}
			else
			{
				FakeClientCommand(client, "voteskick");
			}
		}
		else if (StrEqual(item, "forcespectate"))
		{
			if (!g_bVotensForceSpectateED)
			{
				CPrintToChat(client, "[{olive}VOTE{default}]强制玩家旁观已禁用");
				FakeClientCommand(client, "sm_votes");
			}
			else
			{
				FakeClientCommand(client, "votesforcespectate");
			}
		}
		else if (StrEqual(item, "dellobby"))
		{
			if (!g_bVotenForceDelLobby)
			{
				CPrintToChat(client, "[{olive}VOTE{default}]强制删除游戏大厅已禁用");
				FakeClientCommand(client, "sm_votes");
			}
			else
			{
				FakeClientCommand(client, "votesforcedellobby");
			}
		}
		else if (StrEqual(item, "forcestart"))
		{
			if (!VotensForceStartGameE_D || IsGameLive())
			{
				CPrintToChat(client, "[{olive}VOTE{default}]强制开始已禁用");
				FakeClientCommand(client, "sm_votes");
			}
			else
			{
				FakeClientCommand(client, "votesforcestartgame");
			}
		}
		else if (StrEqual(item, "hud"))
		{
			if (!VotensHudE_D)
			{
				CPrintToChat(client, "[{olive}VOTE{default}]开关顶部HUD已禁用");
				FakeClientCommand(client, "sm_votes");
			}
			else
			{
				FakeClientCommand(client, "voteshud");
			}
		}
	}
	else if (action == MenuAction_Cancel)
	{
		// 原插件在这里重新打开 readyup 面板, 已去除
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}
	return 0;
}

// ====================================================
// builtinvotes 投票 (官方投票界面)
// ====================================================
// 预格式化投票参数并转义 % : builtinvotes 会把 argument 再次当作格式串解析,
// 若文本中含 % 必须转义为 %%, 否则运行时报 "String formatted incorrectly"
void EscapeAndFormat(char[] buffer, int maxlength, const char[] format, const char[] text)
{
	char sEscaped[MAX_NAME_LENGTH];
	strcopy(sEscaped, sizeof(sEscaped), text);
	ReplaceString(sEscaped, sizeof(sEscaped), "%", "%%");
	Format(buffer, maxlength, format, sEscaped);
}

bool StartVote(int client, voteType type, const char[] argument, const char[] passText, VoteBroadcast broadcast, BuiltinVoteType builtinType = BuiltinVoteType_Custom_YesNo)
{
	if (client <= 0 || !IsClientInGame(client)) return false;

	if (IsBuiltinVoteInProgress())
	{
		CPrintToChat(client, "[{olive}VOTE{default}]已经有了一个投票正在进行中");
		return false;
	}

	int  iTeam = GetClientTeam(client);
	int[] iPlayers = new int[MaxClients];
	int  iNumPlayers;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i)) continue;

		switch (broadcast)
		{
			case VoteBroadcast_All:
			{
				// 所有玩家
			}
			case VoteBroadcast_NotSpec:
			{
				if (GetClientTeam(i) == L4D_TEAM_SPECTATE) continue;
			}
			case VoteBroadcast_Team:
			{
				if (GetClientTeam(i) != iTeam) continue;
			}
		}
		iPlayers[iNumPlayers++] = i;
	}

	if (iNumPlayers == 0)
	{
		CPrintToChat(client, "[{olive}VOTE{default}]没有可参与投票的玩家");
		return false;
	}

	g_voteType = type;
	strcopy(g_sVotePassText, sizeof(g_sVotePassText), passText);

	g_hVote = CreateBuiltinVote(VoteActionHandler, builtinType, BuiltinVoteAction_Cancel | BuiltinVoteAction_End);
	if (g_hVote == null)
	{
		CPrintToChat(client, "[{olive}VOTE{default}]无法创建投票(请确认 builtinvotes 扩展已加载)");
		return false;
	}

	SetBuiltinVoteArgument(g_hVote, argument);
	SetBuiltinVoteInitiator(g_hVote, client);
	if (broadcast == VoteBroadcast_Team)
	{
		SetBuiltinVoteTeam(g_hVote, iTeam);
	}
	SetBuiltinVoteResultCallback(g_hVote, VoteResultHandler);

	if (!DisplayBuiltinVote(g_hVote, iPlayers, iNumPlayers, VOTE_TIME))
	{
		delete g_hVote;
		g_hVote = null;
		CPrintToChat(client, "[{olive}VOTE{default}]无法发起投票");
		return false;
	}

	// 发起者默认投同意票(与官方投票行为一致)
	FakeClientCommand(client, "Vote Yes");

	return true;
}

public void VoteActionHandler(Handle vote, BuiltinVoteAction action, int param1, int param2)
{
	switch (action)
	{
		case BuiltinVoteAction_Cancel:
		{
			CPrintToChatAll("[{olive}VOTE{default}]{lightgreen}投票已取消{default}");
			DisplayBuiltinVoteFail(vote, view_as<BuiltinVoteFailReason>(param1));
			g_votedelay = ivotedelay_time;
			CreateTimer(1.0, Timer_VoteDelay, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
		}
		case BuiltinVoteAction_End:
		{
			delete vote;
			g_hVote = null;
		}
	}
}

public void VoteResultHandler(Handle vote, int num_votes, int num_clients, const int[][] client_info, int num_items, const int[][] item_info)
{
	int iYesVotes;
	for (int i = 0; i < num_items; i++)
	{
		if (item_info[i][BUILTINVOTEINFO_ITEM_INDEX] == BUILTINVOTES_VOTE_YES)
		{
			iYesVotes = item_info[i][BUILTINVOTEINFO_ITEM_VOTES];
		}
	}

	g_votedelay = ivotedelay_time;
	CreateTimer(1.0, Timer_VoteDelay, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

	// 未投票的玩家视作反对, 分母为全部可投票人数(num_clients), 而非实际投票人数(num_votes)
	float percent = (num_clients > 0) ? (float(iYesVotes) / float(num_clients)) : 0.0;

	if (num_clients > 0 && FloatCompare(percent, g_fLimit) >= 0)
	{
		CPrintToChatAll("[{olive}VOTE{default}]{lightgreen}投票通过 {default}(同意：{green}%d%%{default}, 同意票：{green}%i/%i{default})", RoundToNearest(100.0 * percent), iYesVotes, num_clients);
		DisplayBuiltinVotePass(vote, g_sVotePassText);
		CreateTimer(3.0, COLD_DOWN, _);
	}
	else
	{
		CPrintToChatAll("[{olive}VOTE{default}]{lightgreen}投票未通过 {default}至少需要{green}%d%%{default}的玩家同意。(同意： {green}%d%%{default}, 同意票： {green}%i/%i {default})", RoundToNearest(100.0 * g_fLimit), RoundToNearest(100.0 * percent), iYesVotes, num_clients);
		DisplayBuiltinVoteFail(vote, BuiltinVoteFail_Loses);
	}
}

// ====================================================
// 各投票命令
// ====================================================
public Action Command_VoteHp(int client, int args)
{
	if (g_bEnable && VotensHpE_D)
	{
		if (!TestVoteDelay(client)) return Plugin_Handled;
		if (!CanStartVotes(client)) return Plugin_Handled;

		char SteamId[35];
		GetClientAuthId(client, AuthId_Steam2, SteamId, sizeof(SteamId));
		LogMessage("%N(%s) 发起了一个投票: 全体回血!", client, SteamId);	//記錄在log文件

		CPrintToChatAll("[{olive}VOTE{default}]{olive} %N {default}发起了一个投票: {blue}全体回血{default}, 只有游戏中的玩家才能参与投票", client);
		StartVote(client, hp, "是否全体回血?", "全体回血", VoteBroadcast_NotSpec);
	}
	else if (!g_bEnable || !VotensHpE_D)
	{
		CPrintToChat(client, "[{olive}VOTE{default}]投票被禁止");
	}
	return Plugin_Handled;
}

public Action Command_Votesforcestartgame(int client, int args)
{
	if (g_bEnable && VotensForceStartGameE_D)
	{
		if (IsGameLive())
		{
			PrintToChatAll("[{olive}VOTE{default}]游戏已开始!");
			return Plugin_Handled;
		}
		if (!TestVoteDelay(client)) return Plugin_Handled;
		if (!CanStartVotes(client)) return Plugin_Handled;

		fsgclient = client;

		char SteamId[35];
		GetClientAuthId(client, AuthId_Steam2, SteamId, sizeof(SteamId));
		LogMessage("%N(%s) 发起了一个投票: 强制开始游戏!", client, SteamId);	//記錄在log文件

		CPrintToChatAll("[{olive}VOTE{default}]{olive} %N {default}发起了一个投票: {blue}强制开始游戏{default}, 只有游戏中的玩家才能参与投票", client);
		StartVote(client, forcestartgame, "是否强制开始游戏?", "强制开始游戏", VoteBroadcast_NotSpec);
	}
	else if (!g_bEnable || !VotensForceStartGameE_D)
	{
		CPrintToChat(client, "[{olive}VOTE{default}]投票被禁止");
	}
	return Plugin_Handled;
}

public Action Command_VoteHud(int client, int args)
{
	if (g_bEnable && VotensHudE_D)
	{
		if (!TestVoteDelay(client)) return Plugin_Handled;
		if (!CanStartVotes(client)) return Plugin_Handled;

		char SteamId[35];
		GetClientAuthId(client, AuthId_Steam2, SteamId, sizeof(SteamId));
		LogMessage("%N(%s) 发起了一个投票: 开关顶部HUD!", client, SteamId);	//記錄在log文件

		CPrintToChatAll("[{olive}VOTE{default}]{olive} %N {default}发起了一个投票: {blue}开关顶部HUD{default}, 所有玩家都可以参与投票", client);
		StartVote(client, hud, "是否开关顶部HUD?", "开关顶部HUD", VoteBroadcast_All);
	}
	else if (!g_bEnable || !VotensHudE_D)
	{
		CPrintToChat(client, "[{olive}VOTE{default}]投票被禁止");
	}
	return Plugin_Handled;
}

public Action Command_Votesforcedellobby(int client, int args)
{
	if (g_bEnable && g_bVotenForceDelLobby)
	{
		if (!TestVoteDelay(client)) return Plugin_Handled;
		if (!CanStartVotes(client)) return Plugin_Handled;

		char SteamId[35];
		GetClientAuthId(client, AuthId_Steam2, SteamId, sizeof(SteamId));
		LogMessage("%N(%s) 发起了一个投票: 删除匹配大厅!", client, SteamId);	//紀錄在log文件

		CPrintToChatAll("[{olive}VOTE{default}]{olive}%N{default}发起了一个投票: {blue}删除匹配大厅 {default}删除大厅用来解决卡大厅问题或者关闭匹配.请慎重投票!", client);
		StartVote(client, forcedellobby, "是否删除匹配大厅?", "删除匹配大厅", VoteBroadcast_All);
	}
	else if (!g_bEnable || !g_bVotenForceDelLobby)
	{
		CPrintToChat(client, "[{olive}VOTE{default}]投票被禁止");
	}
	return Plugin_Handled;
}

public Action Command_VoteAlltalk(int client, int args)
{
	if (g_bEnable && VotensAlltalkE_D)
	{
		if (!TestVoteDelay(client)) return Plugin_Handled;
		if (!CanStartVotes(client)) return Plugin_Handled;

		char SteamId[35];
		GetClientAuthId(client, AuthId_Steam2, SteamId, sizeof(SteamId));
		LogMessage("%N(%s) 发起了一个投票: 开启全体语音!", client, SteamId);	//紀錄在log文件

		CPrintToChatAll("[{olive}VOTE{default}]{olive}%N{default}发起了一个投票: {blue}开启全体语音", client);
		StartVote(client, alltalk, "是否开启全体语音?", "开启全体语音", VoteBroadcast_All);
	}
	else if (!g_bEnable || !VotensAlltalkE_D)
	{
		CPrintToChat(client, "[{olive}VOTE{default}]投票被禁止");
	}
	return Plugin_Handled;
}

public Action Command_VoteAlltalk2(int client, int args)
{
	if (g_bEnable && VotensAlltalkE_D)
	{
		if (!TestVoteDelay(client)) return Plugin_Handled;
		if (!CanStartVotes(client)) return Plugin_Handled;

		char SteamId[35];
		GetClientAuthId(client, AuthId_Steam2, SteamId, sizeof(SteamId));
		LogMessage("%N(%s) 发起了一个投票: 关闭全体语音!", client, SteamId);	//紀錄在log文件

		CPrintToChatAll("[{olive}VOTE{default}]{olive} %N {default}发起投票: {blue}关闭全体语音", client);
		StartVote(client, alltalk2, "是否关闭全体语音?", "关闭全体语音", VoteBroadcast_All);
	}
	else if (!g_bEnable || !VotensAlltalkE_D)
	{
		CPrintToChat(client, "[{olive}VOTE{default}]投票被禁止");
	}
	return Plugin_Handled;
}

public Action Command_VoteRestartmap(int client, int args)
{
	if (g_bEnable && VotensRestartmapE_D)
	{
		if (!TestVoteDelay(client)) return Plugin_Handled;
		if (!CanStartVotes(client)) return Plugin_Handled;

		char SteamId[35];
		GetClientAuthId(client, AuthId_Steam2, SteamId, sizeof(SteamId));
		LogMessage("%N(%s) 发起了一个投票: 重置当前地图!", client, SteamId);	//紀錄在log文件

		CPrintToChatAll("[{olive}VOTE{default}]{olive} %N {default}发起了一个投票: {blue}重置当前地图 {default}, 只有游戏中的玩家才能参与投票", client);
		StartVote(client, restartmap, "是否重置当前地图?", "重置当前地图", VoteBroadcast_NotSpec);
	}
	else if (!g_bEnable || !VotensRestartmapE_D)
	{
		CPrintToChat(client, "[{olive}VOTE{default}]投票被禁止");
	}
	return Plugin_Handled;
}

// 踢出玩家
public Action Command_VotesKick(int client, int args)
{
	if (client == 0) return Plugin_Handled;
	if (g_bEnable && g_bVotensKickED)
	{
		CreateVoteKickMenu(client);
	}
	else if (!g_bEnable || !g_bVotensKickED)
	{
		CPrintToChat(client, "[{olive}VOTE{default}]已禁止踢出玩家");
	}
	return Plugin_Handled;
}

void CreateVoteKickMenu(int client)
{
	int	 team = GetClientTeam(client);
	Menu menu = new Menu(Menu_VotesKick);
	char name[MAX_NAME_LENGTH];
	char playerid[32];
	menu.SetTitle("请选择你要踢出的玩家");
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && (GetClientTeam(i) == team || GetClientTeam(i) == L4D_TEAM_SPECTATE))
		{
			Format(playerid, sizeof(playerid), "%i", GetClientUserId(i));
			if (GetClientName(i, name, sizeof(name)))
			{
				menu.AddItem(playerid, name);
			}
		}
	}
	menu.ExitBackButton = true;
	menu.ExitButton = true;
	menu.Display(client, MENU_TIME);
}

public int Menu_VotesKick(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		char info[32], name[32];
		menu.GetItem(param2, info, sizeof(info), _, name, sizeof(name));
		int player = StringToInt(info);
		player	   = GetClientOfUserId(player);
		if (player && IsClientInGame(player))
		{
			if (player == param1)
			{
				CPrintToChatAll("[{olive}VOTE{default}]你确定要踢你自己吗?请重新选择");
				CreateVoteKickMenu(param1);
				return 0;
			}

			if (HasAccess(player, g_sKickImmueAccesslvl))
			{
				CPrintToChat(param1, "[{olive}VOTE{default}]该玩家无法被踢出，请重新选择你想踢出的玩家!");
				CPrintToChat(player, "[{olive}VOTE{default}]{olive}%N{default}尝试投票将你踢出, 但你拥有权限无法踢出", param1);
				CreateVoteKickMenu(param1);
			}
			else
			{
				kickplayer_userid = GetClientUserId(player);
				kickplayer_name	  = name;
				GetClientAuthId(player, AuthId_Steam2, kickplayer_SteamId, sizeof(kickplayer_SteamId));
				DisplayVoteKickMenu(param1);
			}
		}
		else
		{
			CPrintToChatAll("[{olive}VOTE{default}]该玩家已不在游戏中, 请重新选择!");
			CreateVoteKickMenu(param1);
		}
	}
	else if (action == MenuAction_Cancel)
	{
		if (param2 == MenuCancel_ExitBack)
		{
			FakeClientCommand(param1, "votes");
		}
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void DisplayVoteKickMenu(int client)
{
	if (!TestVoteDelay(client)) return;
	if (!CanStartVotes(client)) return;

	char SteamId[35];
	GetClientAuthId(client, AuthId_Steam2, SteamId, sizeof(SteamId));
	LogMessage("%N(%s) 发起投票: 踢出 %s(%s)", client, SteamId, kickplayer_name, kickplayer_SteamId);	 //紀錄在log文件

	CPrintToChatAll("[{olive}VOTE{default}]{olive} %N {default}发起投票: {blue}踢出 %s {default}, 只有投票发起者的阵营才能参与投票", client, kickplayer_name);
	char sArgument[128], sPassText[MAX_NAME_LENGTH];
	EscapeAndFormat(sArgument, sizeof(sArgument), "是否踢出 %s ?", kickplayer_name);
	EscapeAndFormat(sPassText, sizeof(sPassText), "%s", kickplayer_name);
	StartVote(client, kick, sArgument, sPassText, VoteBroadcast_Team);
}

// 更换地图
public Action Command_VotemapsMenu(int client, int args)
{
	if (g_bEnable && VotensMapE_D)
	{
		if (!TestVoteDelay(client)) return Plugin_Handled;

		Menu menu = new Menu(MapMenuHandler);
		menu.SetTitle("请选择你要更换地图");
		if (game_l4d2)
		{
			menu.AddItem("c1m1_hotel", "死亡中心 C1");
			menu.AddItem("c2m1_highway", "黑色嘉年华 C2");
			menu.AddItem("c3m1_plankcountry", "沼泽激战 C3");
			menu.AddItem("c4m1_milltown_a", "暴风骤雨 C4");
			menu.AddItem("c5m1_waterfront", "教区 C5");
			menu.AddItem("c6m1_riverbank", "短暂时刻 C6");
			menu.AddItem("c7m1_docks", "牺牲 C7");
			menu.AddItem("c8m1_apartment", "毫不留情 C8");
			menu.AddItem("c9m1_alleys", "坠机险途 C9");
			menu.AddItem("c10m1_caves", "死亡丧钟 C10");
			menu.AddItem("c11m1_greenhouse", "寂静时分 C11");
			menu.AddItem("c12m1_hilltop", "血腥收获 C12");
			menu.AddItem("c13m1_alpinecreek", "刺骨寒溪 C13");
			menu.AddItem("c14m1_junkyard", "背水一战 C14");
		}
		else
		{
			menu.AddItem("l4d_vs_hospital01_apartment", "毫不留情 No Mercy");
			menu.AddItem("l4d_garage01_alleys", "坠机险途 Crash Course");
			menu.AddItem("l4d_vs_smalltown01_caves", "死亡丧钟 Death Toll");
			menu.AddItem("l4d_vs_airport01_greenhouse", "寂静时分 Dead Air");
			menu.AddItem("l4d_vs_farm01_hilltop", "血腥收获 Bloody Harvest");
			menu.AddItem("l4d_river01_docks", "牺牲 The Sacrifice");
		}
		menu.ExitBackButton = true;
		menu.ExitButton = true;
		menu.Display(client, MENU_TIME);

		return Plugin_Handled;
	}
	else if (!g_bEnable || !VotensMapE_D)
	{
		CPrintToChat(client, "[{olive}VOTE{default}]官图投票已禁止,请使用自带投票");
	}
	return Plugin_Handled;
}

public Action Command_Votemaps2Menu(int client, int args)
{
	if (g_bEnable && VotensMap2E_D)
	{
		if (!TestVoteDelay(client)) return Plugin_Handled;

		Menu menu = new Menu(MapMenuHandler);
		menu.SetTitle("▲ 选择三方图 <%d map%s>", g_iCount, ((g_iCount > 1) ? "s" : ""));
		for (int i = 0; i < g_iCount; i++)
		{
			menu.AddItem(g_sMapinfo[i], g_sMapname[i]);
		}

		menu.ExitBackButton = true;
		menu.ExitButton = true;
		menu.Display(client, MENU_TIME);

		return Plugin_Handled;
	}
	else if (!g_bEnable || !VotensMap2E_D)
	{
		CPrintToChat(client, "[{olive}VOTE{default}]三方图投票已禁止,请使用自带投票");
	}
	return Plugin_Handled;
}

public int MapMenuHandler(Menu menu, MenuAction action, int client, int itemNum)
{
	if (action == MenuAction_Select)
	{
		char info[32], name[64];
		menu.GetItem(itemNum, info, sizeof(info), _, name, sizeof(name));
		votesmaps	  = info;
		votesmapsname = name;
		DisplayVoteMapsMenu(client);
	}
	else if (action == MenuAction_Cancel)
	{
		if (itemNum == MenuCancel_ExitBack)
		{
			FakeClientCommand(client, "votes");
		}
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void DisplayVoteMapsMenu(int client)
{
	if (!TestVoteDelay(client)) return;
	if (!CanStartVotes(client)) return;

	char SteamId[35];
	GetClientAuthId(client, AuthId_Steam2, SteamId, sizeof(SteamId));
	LogMessage("%N(%s) 发起投票: 更换地图 %s", client, SteamId, votesmapsname);	   //紀錄在log文件

	CPrintToChatAll("[{olive}VOTE{default}]{olive} %N {default}发起投票: {blue}更换地图%s{default}, 只有游戏中的玩家才能参与投票", client, votesmapsname);
	char sArgument[128], sPassText[MAX_NAME_LENGTH];
	// 使用游戏原生 ChgCampaign 投票类型: 官方投票文案会自行拼出"更换战役", argument 传战役/地图显示名
	EscapeAndFormat(sArgument, sizeof(sArgument), "%s", votesmapsname);
	EscapeAndFormat(sPassText, sizeof(sPassText), "%s", votesmapsname);
	StartVote(client, map, sArgument, sPassText, VoteBroadcast_NotSpec, BuiltinVoteType_ChgCampaign);
}

// 强制玩家旁观
public Action Command_Votesforcespectate(int client, int args)
{
	if (client == 0) return Plugin_Handled;
	if (g_bEnable && g_bVotensForceSpectateED)
	{
		CreateVoteforcespectateMenu(client);
	}
	else if (!g_bEnable || !g_bVotensForceSpectateED)
	{
		CPrintToChat(client, "[{olive}VOTE{default}]强制玩家旁观已被禁止");
	}
	return Plugin_Handled;
}

void CreateVoteforcespectateMenu(int client)
{
	Menu menu = new Menu(Menu_Votesforcespectate);
	int	 team = GetClientTeam(client);
	char name[MAX_NAME_LENGTH];
	char playerid[32];
	menu.SetTitle("请选择你要强制旁观的玩家");
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == team)
		{
			Format(playerid, sizeof(playerid), "%d", GetClientUserId(i));
			if (GetClientName(i, name, sizeof(name)))
			{
				menu.AddItem(playerid, name);
			}
		}
	}
	menu.ExitBackButton = true;
	menu.ExitButton = true;
	menu.Display(client, MENU_TIME);
}

public int Menu_Votesforcespectate(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		char info[32], name[32];
		menu.GetItem(param2, info, sizeof(info), _, name, sizeof(name));
		forcespectateid			= StringToInt(info);
		forcespectateplayername = name;

		DisplayVoteforcespectateMenu(param1);
	}
	else if (action == MenuAction_Cancel)
	{
		if (param2 == MenuCancel_ExitBack)
		{
			FakeClientCommand(param1, "votes");
		}
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void DisplayVoteforcespectateMenu(int client)
{
	if (!TestVoteDelay(client)) return;
	if (!CanStartVotes(client)) return;

	char SteamId[35];
	GetClientAuthId(client, AuthId_Steam2, SteamId, sizeof(SteamId));
	LogMessage("%N(%s) 发起投票: 强制玩家 %s 旁观", client, SteamId, forcespectateplayername);	  //紀錄在log文件

	CPrintToChatAll("[{olive}VOTE{default}]{olive} %N {default}发起投票: {blue}强制玩家%s旁观{default}, 只有投票发起者的阵营才能参与投票", client, forcespectateplayername);
	char sArgument[128], sPassText[MAX_NAME_LENGTH];
	EscapeAndFormat(sArgument, sizeof(sArgument), "是否强制%s旁观?", forcespectateplayername);
	EscapeAndFormat(sPassText, sizeof(sPassText), "%s", forcespectateplayername);
	StartVote(client, forcespectate, sArgument, sPassText, VoteBroadcast_Team);
}

// ====================================================
// 管理员命令: 重置地图 (带倒计时)
// ====================================================
public Action CommandRestartMap(int client, int args)
{
	if (!isMapRestartPending)
	{
		CPrintToChatAll("[{olive}VOTE{default}]地图将在{green}%d{default}秒后重置", READY_RESTART_MAP_DELAY + 1);
		RestartMapDelayed();
	}
	return Plugin_Handled;
}

void RestartMapDelayed()
{
	if (MapCountdownTimer == INVALID_HANDLE)
	{
		PrintHintTextToAll("请准备!\n地图将在 %d 秒后重置", READY_RESTART_MAP_DELAY + 1);
		isMapRestartPending = true;
		MapRestartDelay		= READY_RESTART_MAP_DELAY;
		MapCountdownTimer	= CreateTimer(1.0, timerRestartMap, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	}
}

public Action timerRestartMap(Handle timer)
{
	if (MapRestartDelay == 0)
	{
		MapCountdownTimer = INVALID_HANDLE;
		RestartMapNow();
		return Plugin_Stop;
	}
	else
	{
		PrintHintTextToAll("请准备!\n地图将在 %d 秒后重置", MapRestartDelay);
		EmitSoundToAll("buttons/blip1.wav", _, SNDCHAN_AUTO, SNDLEVEL_NORMAL, SND_NOFLAGS, 0.5);
		MapRestartDelay--;
	}
	return Plugin_Continue;
}

void RestartMapNow()
{
	isMapRestartPending = false;
	char currentMap[256];
	GetCurrentMap(currentMap, 256);
	ServerCommand("changelevel %s", currentMap);
}

// ====================================================
// 投票通过后执行
// ====================================================
public Action COLD_DOWN(Handle timer, any client)
{
	switch (g_voteType)
	{
		case hp:
		{
			AnyHp();
			LogMessage("全体回血通过");
		}
		case alltalk:
		{
			ServerCommand("sv_alltalk 1");
			LogMessage("开启全体语音通过");
		}
		case alltalk2:
		{
			ServerCommand("sv_alltalk 0");
			LogMessage("关闭全体语音通过");
		}
		case restartmap:
		{
			ServerCommand("sm_restartmap");
			LogMessage("重置地图通过");
		}
		case map:
		{
			CreateTimer(5.0, Changelevel_Map);
			CPrintToChatAll("[{olive}VOTE{default}]{green}5{default}秒后将切换地图为{blue}%s", votesmapsname);
			LogMessage("更换地图 %s %s 通过", votesmaps, votesmapsname);
		}
		case kick:
		{
			CPrintToChatAll("[{olive}VOTE{default}]%s 已被投票踢出!", kickplayer_name);
			LogMessage("投票踢出玩家%s通过", kickplayer_name);

			int player = GetClientOfUserId(kickplayer_userid);
			if (player && IsClientInGame(player)) KickClient(player, "你已被投票踢出");
			ServerCommand("sm_addban 5 \"%s\" \"你已被投票踢出\" ", kickplayer_SteamId);
		}
		case forcespectate:
		{
			forcespectateid = GetClientOfUserId(forcespectateid);
			if (HasAccess(forcespectateid, g_sKickImmueAccesslvl))
			{
				CPrintToChatAll("[{olive}VOTE{default}]玩家%s因拥有权限而无法强制旁观!", forcespectateplayername);
				LogMessage("玩家%s因拥有权限而无法强制旁观", forcespectateplayername);
				return Plugin_Handled;
			}
			if (forcespectateid && IsClientInGame(forcespectateid))
			{
				CPrintToChatAll("[{olive}VOTE{default}]玩家{blue}%s{default}已被强制旁观!", forcespectateplayername);
				ChangeClientTeam(forcespectateid, 1);
				LogMessage("玩家%s已经被强制旁观", forcespectateplayername);
				CreateTimer(1.0, Timer_forcespectate, forcespectateid, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);	   // Start unpause countdown
			}
			else
			{
				CPrintToChatAll("[{olive}VOTE{default}]无法找到玩家%s", forcespectateplayername);
			}
		}
		case forcedellobby:
		{
			L4D_LobbyUnreserve();
			LogMessage("删除匹配大厅通过");
		}
		case hud:
		{
			ServerCommand("sm_hud");
			LogMessage("开关顶部HUD通过");
		}
		case forcestartgame:
		{
			if (!IsGameLive())
			{
				if (fsgclient <= 0 || !IsClientInGame(fsgclient))
				{
					CPrintToChatAll("[{olive}VOTE{default}]发起投票的玩家已断开连接，无法强制开始游戏!");
					LogMessage("强制开始游戏失败: 发起玩家已断开连接");
				}
				else
				{
					CPrintToChatAll("[{olive}VOTE{default}]注意是给投票发起玩家临时提升权限来强制开始游戏!但他不一定是管理员哦.");
					CheatCommandEx(fsgclient);
					LogMessage("强制开始游戏通过");
				}
			}
			else
			{
				CPrintToChatAll("[{olive}VOTE{default}]对局已开始!无需强制启动游戏!");
			}
		}
	}

	return Plugin_Continue;
}

public Action Changelevel_Map(Handle timer)
{
	ServerCommand("changelevel %s", votesmaps);
	return Plugin_Continue;
}

public Action Timer_forcespectate(Handle timer, any client)
{
	static bool bClientJoinedTeam = false;	  // did the client try to join the infected?

	if (!IsClientInGame(client) || IsFakeClient(client)) return Plugin_Stop;	// if client disconnected or is fake client

	if (g_iSpectatePenaltyCounter[client] != 0)
	{
		if ((GetClientTeam(client) == 3 || GetClientTeam(client) == 2))
		{
			ChangeClientTeam(client, 1);
			CPrintToChat(client, "[{olive}VOTE{default}] 你已被投票强制旁观! 等待 {green}%d {default}秒后重新回到游戏.", g_iSpectatePenaltyCounter[client]);
			bClientJoinedTeam = true;	 // client tried to join the infected again when not allowed
		}
		else if (GetClientTeam(client) == 1 && IsClientIdle(client))
		{
			L4D_TakeOverBot(client);
			ChangeClientTeam(client, 1);
			CPrintToChat(client, "[{olive}VOTE{default}] 你已被投票强制旁观! 等待 {green}%d {default}秒后重新回到游戏.", g_iSpectatePenaltyCounter[client]);
			bClientJoinedTeam = true;	 // client tried to join the infected again when not allowed
		}
		g_iSpectatePenaltyCounter[client]--;
		return Plugin_Continue;
	}
	else if (g_iSpectatePenaltyCounter[client] == 0)
	{
		if (GetClientTeam(client) == 3 || GetClientTeam(client) == 2)
		{
			ChangeClientTeam(client, 1);
			bClientJoinedTeam = true;
		}
		if (GetClientTeam(client) == 1 && bClientJoinedTeam)
		{
			CPrintToChat(client, "[{olive}VOTE{default}]你现在可以按M回到队伍了");	  // only print this hint text to the spectator if he tried to join the infected team, and got swapped before
		}
		bClientJoinedTeam				  = false;
		g_iSpectatePenaltyCounter[client] = iforcespectate_penalty;
		return Plugin_Stop;
	}
	return Plugin_Continue;
}

// 全体回血
void AnyHp()
{
	int flags = GetCommandFlags("give");
	SetCommandFlags("give", flags & ~FCVAR_CHEAT);
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i))
		{
			FakeClientCommand(i, "give health");
			SetEntityHealth(i, MaxHealth);
		}
	}
	SetCommandFlags("give", flags | FCVAR_CHEAT);
}

// 临时提升权限执行 sm_fs (强制开始游戏, 由服务器上其他插件提供该命令)
void CheatCommandEx(int client)
{
	int bits = GetUserFlagBits(client);
	SetUserFlagBits(client, ADMFLAG_ROOT);
	FakeClientCommand(client, "sm_fs");
	SetUserFlagBits(client, bits);
}

// ====================================================
// 投票延迟
// ====================================================
bool TestVoteDelay(int client)
{
	int delay = CheckVoteDelay();
	if (delay > 0)
	{
		CPrintToChat(client, "[{olive}VOTE{default}]你必须等待{red}%i{default}秒后再发起投票!", delay);
		return false;
	}

	delay = CheckBuiltinVoteDelay();
	if (delay > 0)
	{
		CPrintToChat(client, "[{olive}VOTE{default}]你必须等待{red}%i{default}秒后再发起投票!", delay);
		return false;
	}

	delay = g_votedelay;
	if (delay > 0)
	{
		CPrintToChat(client, "[{olive}VOTE{default}]你必须等待{red}%i{default}秒后再发起投票!", delay);
		return false;
	}
	return true;
}

bool CanStartVotes(int client)
{
	if (IsBuiltinVoteInProgress())
	{
		CPrintToChat(client, "[{olive}VOTE{default}]已经有了一个投票正在进行中");
		return false;
	}

	int iNumPlayers;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i) || !IsClientConnected(i)) continue;
		iNumPlayers++;
	}
	if (iNumPlayers < g_iCvarPlayerLimit)
	{
		CPrintToChat(client, "[{olive}VOTE{default}]无法发起投票。需要{red}%d{default}个玩家", g_iCvarPlayerLimit);
		return false;
	}
	return true;
}

public Action Timer_VoteDelay(Handle timer, any client)
{
	g_votedelay--;
	if (g_votedelay <= 0)
	{
		return Plugin_Stop;
	}
	return Plugin_Continue;
}

// ====================================================
// 三方图列表
// ====================================================
void ParseCampaigns()
{
	Handle g_kvCampaigns = CreateKeyValues("VoteCustomCampaigns");

	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), "data/VoteCustomCampaigns.txt");

	if (!FileToKeyValues(g_kvCampaigns, sPath))
	{
		LogError("[VCC] File not found: %s", sPath);
		CloseHandle(g_kvCampaigns);
		return;
	}

	if (!KvGotoFirstSubKey(g_kvCampaigns))
	{
		LogError("[VCC] File can't read: you dumb noob!");
		CloseHandle(g_kvCampaigns);
		return;
	}

	for (int i = 0; i < MAX_CAMPAIGN_LIMIT; i++)
	{
		KvGetString(g_kvCampaigns, "mapinfo", g_sMapinfo[i], sizeof(g_sMapinfo));
		KvGetString(g_kvCampaigns, "mapname", g_sMapname[i], sizeof(g_sMapname));

		if (!KvGotoNextKey(g_kvCampaigns))
		{
			g_iCount = ++i;
			break;
		}
	}
}

// ====================================================
// 权限判断
// ====================================================
bool HasAccess(int client, char[] g_sAcclvl)
{
	if (client <= 0 || !IsClientInGame(client))
		return false;

	// no permissions set
	if (strlen(g_sAcclvl) == 0)
		return true;

	else if (StrEqual(g_sAcclvl, "-1"))
		return false;

	// check permissions
	int iFlag = GetUserFlagBits(client);
	if (iFlag & ReadFlagString(g_sAcclvl) || iFlag & ADMFLAG_ROOT)
	{
		return true;
	}

	return false;
}

bool IsClientIdle(int client)
{
	if (GetClientTeam(client) != 1)
		return false;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && IsFakeClient(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i))
		{
			if (HasEntProp(i, Prop_Send, "m_humanSpectatorUserID"))
			{
				if (GetClientOfUserId(GetEntProp(i, Prop_Send, "m_humanSpectatorUserID")) == client)
					return true;
			}
		}
	}
	return false;
}
