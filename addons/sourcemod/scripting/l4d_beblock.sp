/**
 * ============================================================================
 *  [L4D2] 个人屏蔽（语音 / 文字）        sm_bequiet / sm_quite / sm_bizhi / sm_bz
 * ============================================================================
 *  指令（任意一个都能呼出菜单，游戏内用 !bz 也可以）：
 *     sm_bequiet / sm_quite / sm_bizhi / sm_bz
 *
 *  功能：
 *   1. 菜单顶部显示「选择要屏蔽的玩家」，下面列出服务器内全部真人玩家
 *      （只显示玩家名，不含自己与 Bot，不显示屏蔽状态）。
 *   2. 选中某位玩家后显示两行：接收语音 / 接收文字，
 *      行首按当前屏蔽状态显示 [√]（正常接收）或 [×]（已屏蔽）；
 *      再选一次 [×] 那一行即取消屏蔽。
 *   3. 标记为 [×] 之后：不再接收该玩家的语音（SetListenOverride，
 *      只影响自己，不影响别人）与文字聊天（按接收者过滤聊天输出）。
 *   4. 目标与自己不同队、并且没有开启全体语音时，不显示「接收语音」行。
 *   5. 同一队伍的玩家进服后立刻开始说话、并“连续”说满 20 秒
 *      （进服窗口默认 sm_beblock_automute_joinwindow 秒；中途只要停止说话
 *      就重新计时，所以这条只针对开自由麦/一直连麦的人，正常说话会被忽略），
 *      自动把该玩家的语音屏蔽给同队玩家；被屏蔽者本人不受影响。
 *      解除方式有三种：同队玩家自己用 !bz 把这一项改回 [√]；
 *      或该玩家安静满 60 秒自动恢复（AUTOMUTE_QUIET_RESTORE）；
 *      或他离开服务器（记录立即清除，下次进服从零开始判定，不记忆历史）。
 *
 *  屏蔽状态存放：
 *    - 只存在插件内存里，不写文件、不用数据库、不依赖 clientprefs。
 *    - 客户端换图不掉线、索引不变，所以状态跨地图保留（换图后重新下发语音屏蔽）。
 *    - 被屏蔽的玩家一旦离开服务器，与他相关的记录立即清除；
 *      玩家自己离开/换服时，他自己的屏蔽名单同样不再保留（重连后为空白）。
 *
 *  依赖：
 *    - SourceMod 1.11+（使用 OnClientSpeaking / OnClientSpeakingEnd）
 *    - 可选 hextags：本服聊天由 hextags_lite 统一输出，联用时文字过滤
 *      在它的输出环节生效（见 BeBlock_CanSeeChat native）
 * ============================================================================
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <colors>

#define PLUGIN_VERSION "1.2.1"
#define CVAR_FLAGS     FCVAR_NOTIFY

/* 屏蔽状态位 */
#define BLOCK_TEXT   (1 << 0)   /**< 屏蔽文字聊天 */
#define BLOCK_VOICE  (1 << 1)   /**< 屏蔽语音 */
#define BLOCK_AUTO   (1 << 2)   /**< 该语音屏蔽由“进服语音自动屏蔽”写入，安静够久会自动撤销 */

/* 菜单行首标记：√ = 正常接收，× = 已屏蔽 */
#define MARK_RECEIVE "[√]"
#define MARK_BLOCKED "[×]"

/* 菜单项 info */
#define ITEM_VOICE       "v"
#define ITEM_TEXT        "t"
#define ITEM_UNBLOCK_ALL "u"

/* 自动屏蔽（进服语音）判定：必须是“连续”说话，中途一停就重新计时 */
#define AUTOMUTE_SECONDS       20.0   /**< 进服后连续说话达到该秒数即自动屏蔽 */
#define AUTOMUTE_QUIET_RESTORE 60.0   /**< 被自动屏蔽者安静该秒数后自动恢复接收 */
#define AUTOMUTE_INTERVAL       0.5   /**< 说话时长累计检测间隔 */

ConVar g_hCvarEnable, g_hCvarAutoMute, g_hCvarAutoWindow, g_hCvarAllTalk;

bool  g_bEnable, g_bAutoMute;
float g_fAutoWindow;

/* 会话状态（按客户端索引，跨地图保留；玩家断线即清理，不写文件/数据库） */
int  g_iBlockFlags[MAXPLAYERS+1][MAXPLAYERS+1];
int  g_iVoiceOwn[MAXPLAYERS+1][MAXPLAYERS+1];   /**< 本插件下发语音屏蔽时记住的原覆盖值+1，0 = 未下发 */
int  g_iMenuTarget[MAXPLAYERS+1];                /**< 二级菜单正在处理的玩家 userid */

/* 自动屏蔽（进服语音） */
float  g_fJoinTime[MAXPLAYERS+1];      /**< 进服时刻，-1 = 不再纳入判定 */
bool   g_bAutoTracked[MAXPLAYERS+1];   /**< 已成为“候选”（进服窗口内说过话） */
bool   g_bSpeaking[MAXPLAYERS+1];
float  g_fSpokenTime[MAXPLAYERS+1];
float  g_fSilenceAt[MAXPLAYERS+1];     /**< 最近的停止说话时刻，-1 = 未知 */
bool   g_bAutoDone[MAXPLAYERS+1];      /**< 本局已自动屏蔽过，不重复触发 */
Handle g_hAutoTimer;
float  g_fTimerLast;                   /**< 上一次自动屏蔽检测的时刻，用于按真实时间累计 */

/* 外部插件状态 */
bool g_bChatPluginLoaded;   /**< 已有插件（hextags）统一输出聊天 */

public Plugin myinfo =
{
	name = "[L4D2] BeBlock - 个人屏蔽(语音/文字)",
	author = "apples1949",
	description = "玩家自助屏蔽指定玩家的语音与文字聊天（含进服语音自动屏蔽）",
	version = PLUGIN_VERSION,
	url = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	EngineVersion test = GetEngineVersion();
	if (test != Engine_Left4Dead2 && test != Engine_Left4Dead)
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 1/2.");
		return APLRes_SilentFailure;
	}

	/* native 先创建，再注册库名，避免别的插件拿到库名后调用到未绑定的 native */
	CreateNative("BeBlock_CanSeeChat", Native_CanSeeChat);
	CreateNative("BeBlock_HasChatBlocker", Native_HasChatBlocker);
	RegPluginLibrary("beblock");
	return APLRes_Success;
}

public void OnPluginStart()
{
	LoadTranslations("beblock.phrases");

	CreateConVar("sm_beblock_version", PLUGIN_VERSION, "[L4D2] 个人屏蔽插件版本", CVAR_FLAGS | FCVAR_DONTRECORD);

	g_hCvarEnable     = CreateConVar("sm_beblock_enable", "1", "是否启用个人屏蔽插件 (1 启用 / 0 关闭)", CVAR_FLAGS, true, 0.0, true, 1.0);
	g_hCvarAutoMute   = CreateConVar("sm_beblock_automute", "1", "是否自动屏蔽“进服后立刻持续说话”的玩家语音 (1 启用 / 0 关闭)", CVAR_FLAGS, true, 0.0, true, 1.0);
	g_hCvarAutoWindow = CreateConVar("sm_beblock_automute_joinwindow", "20.0", "进服后多少秒内开始说话才纳入自动屏蔽判定", CVAR_FLAGS, true, 1.0, true, 600.0);
	g_hCvarAllTalk    = FindConVar("sv_alltalk");

	GetCvars();
	g_hCvarEnable.AddChangeHook(ConVarChanged);
	g_hCvarAutoMute.AddChangeHook(ConVarChanged);
	g_hCvarAutoWindow.AddChangeHook(ConVarChanged);

	RegConsoleCmd("sm_bequiet", Command_BeBlock, "打开个人屏蔽菜单，屏蔽指定玩家的语音/文字");
	RegConsoleCmd("sm_quite",   Command_BeBlock, "打开个人屏蔽菜单，屏蔽指定玩家的语音/文字");
	RegConsoleCmd("sm_bizhi",   Command_BeBlock, "打开个人屏蔽菜单，屏蔽指定玩家的语音/文字");
	RegConsoleCmd("sm_bz",      Command_BeBlock, "打开个人屏蔽菜单，屏蔽指定玩家的语音/文字");

	/* 屏蔽状态只放在插件内存里：换图后依然有效（客户端不掉线、索引不变），
	   被屏蔽的玩家一离开就清掉相关记录，不写文件也不依赖 clientprefs */
	for (int i = 1; i <= MAXPLAYERS; i++)
	{
		g_iMenuTarget[i] = 0;
		g_fJoinTime[i]   = -1.0;
		g_fSilenceAt[i]  = -1.0;
	}
}

public void OnAllPluginsLoaded()
{
	g_bChatPluginLoaded = LibraryExists("hextags");
}

public void OnLibraryAdded(const char[] name)
{
	if (StrEqual(name, "hextags"))
		g_bChatPluginLoaded = true;
}

public void OnLibraryRemoved(const char[] name)
{
	if (StrEqual(name, "hextags"))
		g_bChatPluginLoaded = false;
}

public void OnPluginEnd()
{
	/* 卸载/重载时还原本插件下发过的语音屏蔽，避免残留 */
	RevertAllVoiceOverrides();
}

public void OnMapStart()
{
	/* 换图后引擎会重新初始化语音状态，这里重新下发一遍
	   （重复下发是幂等的，且只动本插件自己下发过的组合） */
	ReapplyAllVoice();

	/* 说话检测状态跨图不可信（OnClientSpeakingEnd 可能在换图时丢失），
	   全部复位；进服判定窗口也在本图关闭，避免跨图误判。
	   安静时长从本图重新开始算：被自动屏蔽的人下一张图继续安静，
	   AUTOMUTE_QUIET_RESTORE 秒后就会自动恢复 */
	for (int i = 1; i <= MaxClients; i++)
	{
		g_bSpeaking[i]    = false;
		g_fSpokenTime[i]  = 0.0;
		g_bAutoTracked[i] = false;
		g_fJoinTime[i]    = -1.0;
		g_fSilenceAt[i]   = IsValidClient(i) ? GetGameTime() : -1.0;
	}
}

public void OnConfigsExecuted()
{
	/* 配置执行完毕（地图初始化之后）再补一次，防止等级初始化阶段清空覆盖 */
	ReapplyAllVoice();
}

void ConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	bool bWasEnable = g_bEnable;
	GetCvars();

	if (g_bEnable != bWasEnable)
	{
		/* 总开关切换：打开时补下发，关闭时撤销本插件下发过的语音屏蔽 */
		if (g_bEnable)
			ReapplyAllVoice();
		else
			RevertAllVoiceOverrides();
	}
}

void GetCvars()
{
	g_bEnable        = g_hCvarEnable.BoolValue;
	g_bAutoMute      = g_hCvarAutoMute.BoolValue;
	g_fAutoWindow    = g_hCvarAutoWindow.FloatValue;
}

/* ==========================================================================
 *  客户端事件
 * ========================================================================== */

public void OnClientPutInServer(int client)
{
	/* 索引可能刚被上一位玩家用过，先清掉残留状态 */
	ResetClientState(client);

	if (IsFakeClient(client))
		return;

	g_fJoinTime[client] = GetGameTime();
}

public void OnClientDisconnect(int client)
{
	/* 被屏蔽的玩家一离开就清掉与它相关的所有记录；
	   玩家自己离开时，他自己的屏蔽名单同样不再保留 */
	ResetClientState(client);
}

void ResetClientState(int client)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		g_iBlockFlags[client][i] = 0;
		g_iBlockFlags[i][client] = 0;
		/* 引擎在本玩家断线时已自动清掉与他相关的 ListenOverride，这里同步清掉记录 */
		g_iVoiceOwn[client][i] = 0;
		g_iVoiceOwn[i][client] = 0;
	}

	g_iBlockFlags[client][client] = 0;
	g_iVoiceOwn[client][client]   = 0;
	g_iMenuTarget[client] = 0;
	g_fJoinTime[client]   = -1.0;
	g_fSilenceAt[client]  = -1.0;
	g_bAutoTracked[client] = false;
	g_bSpeaking[client]    = false;
	g_fSpokenTime[client]  = 0.0;
	g_bAutoDone[client]    = false;
}

/* ==========================================================================
 *  屏蔽状态：查询 / 切换 / 下发
 * ========================================================================== */

bool IsBlocked(int listener, int speaker, int iFlag)
{
	return (g_iBlockFlags[listener][speaker] & iFlag) != 0;
}

bool HasAnyBlock(int client)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (i != client && g_iBlockFlags[client][i] != 0)
			return true;
	}
	return false;
}

/** 自己能否听到对方语音（同队，或已开启全体语音 / 全体收听 / 对方全体发言） */
bool CanHearVoice(int listener, int speaker)
{
	if (GetClientTeam(listener) == GetClientTeam(speaker))
		return true;

	if (g_hCvarAllTalk == null)
		g_hCvarAllTalk = FindConVar("sv_alltalk");

	if (g_hCvarAllTalk != null && g_hCvarAllTalk.IntValue != 0)
		return true;

	/* 自己开了“收听全体”，或对方开了“全体发言” */
	if ((GetClientListeningFlags(listener) & VOICE_LISTENALL) != 0)
		return true;

	if ((GetClientListeningFlags(speaker) & VOICE_SPEAKALL) != 0)
		return true;

	return false;
}

/** 真正会被这条聊天消息送达的接收者里，有没有人屏蔽了发言者 */
bool HasChatBlocker(int speaker, bool bTeamChat)
{
	int iSpeakerTeam = GetClientTeam(speaker);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (i == speaker || !IsValidClient(i))
			continue;

		if (bTeamChat)
		{
			int iTeam = GetClientTeam(i);
			/* 队内聊天：同队玩家 + 旁观者（与本服聊天插件的接收范围一致） */
			if (iTeam != iSpeakerTeam && iTeam != 1)
				continue;
		}

		if (IsBlocked(i, speaker, BLOCK_TEXT))
			return true;
	}
	return false;
}

void ToggleBlock(int client, int target, int iFlag)
{
	bool bBlocked = IsBlocked(client, target, iFlag);

	char sName[MAX_NAME_LENGTH];
	GetClientName(target, sName, sizeof(sName));
	StripColorTags(sName, sizeof(sName));

	if (bBlocked)
		g_iBlockFlags[client][target] &= ~iFlag;
	else
		g_iBlockFlags[client][target] |= iFlag;

	if (iFlag & BLOCK_VOICE)
	{
		/* 玩家手动操作过这一项后，就不再算“自动屏蔽”，也不会被自动恢复 */
		g_iBlockFlags[client][target] &= ~BLOCK_AUTO;
		ApplyVoiceOverride(client, target);
	}

	if (iFlag & BLOCK_VOICE)
		CPrintToChat(client, "%t", bBlocked ? "Msg_Voice_Unblocked" : "Msg_Voice_Blocked", sName);
	else
		CPrintToChat(client, "%t", bBlocked ? "Msg_Text_Unblocked" : "Msg_Text_Blocked", sName);
}

void UnblockAll(int client)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (i == client)
			continue;

		g_iBlockFlags[client][i] = 0;
		ApplyVoiceOverride(client, i);   /* 撤销本插件下发过的语音屏蔽 */
	}

	g_iBlockFlags[client][client] = 0;

	CPrintToChat(client, "%t", "Msg_Unblock_All");
}

/** 下发 / 撤销 (listener 听 speaker) 的语音屏蔽 */
void ApplyVoiceOverride(int listener, int speaker)
{
	if (listener == speaker || listener < 1 || speaker < 1)
		return;

	if (!IsClientConnected(listener) || !IsClientConnected(speaker))
		return;

	if (!g_bEnable)
		return;

	if (IsBlocked(listener, speaker, BLOCK_VOICE))
	{
		/* first time: 记住原来的覆盖值，撤销时还原，避免覆盖其它插件
		   （如 SpecLister）对同一组合的设置 */
		if (g_iVoiceOwn[listener][speaker] == 0)
			g_iVoiceOwn[listener][speaker] = view_as<int>(GetListenOverride(listener, speaker)) + 1;

		SetListenOverride(listener, speaker, Listen_No);
	}
	else if (g_iVoiceOwn[listener][speaker] != 0)
	{
		SetListenOverride(listener, speaker, view_as<ListenOverride>(g_iVoiceOwn[listener][speaker] - 1));
		g_iVoiceOwn[listener][speaker] = 0;
	}
}

/** 撤销本插件下发过的全部语音屏蔽（还原为下发前的覆盖值） */
void RevertAllVoiceOverrides()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientConnected(i))
			continue;

		for (int j = 1; j <= MaxClients; j++)
		{
			if (i == j || g_iVoiceOwn[i][j] == 0)
				continue;

			if (IsClientConnected(j))
				SetListenOverride(i, j, view_as<ListenOverride>(g_iVoiceOwn[i][j] - 1));

			g_iVoiceOwn[i][j] = 0;
		}
	}
}

void ReapplyAllVoice()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientConnected(i))
			continue;

		for (int j = 1; j <= MaxClients; j++)
		{
			if (i == j || !IsClientConnected(j))
				continue;

			ApplyVoiceOverride(i, j);
		}
	}
}

/* ==========================================================================
 *  菜单
 * ========================================================================== */

public Action Command_BeBlock(int client, int args)
{
	if (!client)
	{
		ReplyToCommand(client, "[BeBlock] 该指令只能在游戏内使用。");
		return Plugin_Handled;
	}

	if (!g_bEnable)
	{
		CPrintToChat(client, "%t", "Msg_Disabled");
		return Plugin_Handled;
	}

	ShowPlayerMenu(client);
	return Plugin_Handled;
}

void ShowPlayerMenu(int client)
{
	char sUserId[16], sName[MAX_NAME_LENGTH], sLabel[128];
	int iItems = 0;

	Menu menu = new Menu(MenuHandler_Players);
	menu.SetTitle("%T", "Menu_Title", client);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsValidClient(i) || i == client)
			continue;

		/* 一级菜单只列玩家名，不显示任何屏蔽状态 */
		GetClientName(i, sName, sizeof(sName));

		IntToString(GetClientUserId(i), sUserId, sizeof(sUserId));
		menu.AddItem(sUserId, sName);
		iItems++;
	}

	bool bAnyBlock = HasAnyBlock(client);

	if (bAnyBlock)
	{
		FormatEx(sLabel, sizeof(sLabel), "%T", "Menu_Unblock_All", client);
		menu.AddItem(ITEM_UNBLOCK_ALL, sLabel);
	}

	menu.ExitButton = true;

	if (iItems == 0 && !bAnyBlock)
	{
		delete menu;
		CPrintToChat(client, "%t", "Msg_No_Players");
		return;
	}

	menu.Display(client, MENU_TIME_FOREVER);
}

void ShowTargetMenu(int client, int target)
{
	char sTitle[128], sName[MAX_NAME_LENGTH];

	GetClientName(target, sName, sizeof(sName));

	Menu menu = new Menu(MenuHandler_Target);
	FormatEx(sTitle, sizeof(sTitle), "%T", "Menu_Target_Title", client, sName);
	menu.SetTitle("%s", sTitle);   /* 玩家名可能含 %，不能当格式串用 */
	menu.ExitBackButton = true;
	menu.ExitButton = true;

	/* 不同队且没开全体语音时，本来就听不到对方语音 → 不显示该行 */
	if (CanHearVoice(client, target))
	{
		FormatEx(sTitle, sizeof(sTitle), "%s %T",
			IsBlocked(client, target, BLOCK_VOICE) ? MARK_BLOCKED : MARK_RECEIVE,
			"Menu_Receive_Voice", client);
		menu.AddItem(ITEM_VOICE, sTitle);
	}

	FormatEx(sTitle, sizeof(sTitle), "%s %T",
		IsBlocked(client, target, BLOCK_TEXT) ? MARK_BLOCKED : MARK_RECEIVE,
		"Menu_Receive_Text", client);
	menu.AddItem(ITEM_TEXT, sTitle);

	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Players(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char sInfo[16];
			menu.GetItem(param2, sInfo, sizeof(sInfo));

			if (StrEqual(sInfo, ITEM_UNBLOCK_ALL))
			{
				UnblockAll(param1);
				ShowPlayerMenu(param1);
				return 0;
			}

			int target = GetClientOfUserId(StringToInt(sInfo));

			if (!IsValidClient(target))
			{
				CPrintToChat(param1, "%t", "Msg_Target_Left");
				ShowPlayerMenu(param1);
				return 0;
			}

			g_iMenuTarget[param1] = GetClientUserId(target);
			ShowTargetMenu(param1, target);
		}

		case MenuAction_End:
		{
			delete menu;
		}
	}

	return 0;
}

public int MenuHandler_Target(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char sInfo[8];
			menu.GetItem(param2, sInfo, sizeof(sInfo));

			int target = GetClientOfUserId(g_iMenuTarget[param1]);

			if (!IsValidClient(target))
			{
				CPrintToChat(param1, "%t", "Msg_Target_Left");
				ShowPlayerMenu(param1);
				return 0;
			}

			if (StrEqual(sInfo, ITEM_VOICE))
				ToggleBlock(param1, target, BLOCK_VOICE);
			else if (StrEqual(sInfo, ITEM_TEXT))
				ToggleBlock(param1, target, BLOCK_TEXT);

			/* 重新显示，让玩家立刻看到 [√]/[×] 变化 */
			ShowTargetMenu(param1, target);
		}

		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack)
				ShowPlayerMenu(param1);
		}

		case MenuAction_End:
		{
			delete menu;
		}
	}

	return 0;
}

/* ==========================================================================
 *  文字聊天：按接收者过滤
 *  - 本服由 hextags_lite 统一输出聊天，它会在输出前调用 BeBlock_CanSeeChat
 *  - 没有该类插件时，本插件自己接管输出（下面 OnClientSayCommand）
 * ========================================================================== */

public int Native_CanSeeChat(Handle plugin, int numParams)
{
	int listener = GetNativeCell(1);
	int speaker  = GetNativeCell(2);

	if (!g_bEnable || listener == speaker || listener < 1 || speaker < 1)
		return true;

	if (!IsValidClient(listener) || !IsValidClient(speaker))
		return true;

	return !IsBlocked(listener, speaker, BLOCK_TEXT);
}

public int Native_HasChatBlocker(Handle plugin, int numParams)
{
	int speaker = GetNativeCell(1);
	bool bTeamChat = view_as<bool>(GetNativeCell(2));

	if (!g_bEnable || !IsValidClient(speaker))
		return false;

	return HasChatBlocker(speaker, bTeamChat);
}

public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
	/* 有插件统一输出聊天时，由它按接收者过滤，本插件不重复输出 */
	if (g_bChatPluginLoaded || !g_bEnable || !IsValidClient(client))
		return Plugin_Continue;

	char sMessage[MAX_MESSAGE_LENGTH];
	strcopy(sMessage, sizeof(sMessage), sArgs);
	StripQuotes(sMessage);

	if (sMessage[0] == '\0')
		return Plugin_Continue;

	/* !cmd / /cmd 交给 SourceMod 自己处理 */
	if (sMessage[0] == '!' || sMessage[0] == '/')
		return Plugin_Continue;

	bool bTeamChat = StrEqual(command, "say_team", false);

	if (!HasChatBlocker(client, bTeamChat))
		return Plugin_Continue;   /* 没人屏蔽他 → 保持游戏原版显示 */

	PrintFilteredChat(client, bTeamChat, sMessage);
	return Plugin_Handled;
}

void PrintFilteredChat(int speaker, bool bTeamChat, const char[] sMessage)
{
	char sName[MAX_NAME_LENGTH];
	char sClean[MAX_MESSAGE_LENGTH];

	GetClientName(speaker, sName, sizeof(sName));
	StripColorTags(sName, sizeof(sName));

	strcopy(sClean, sizeof(sClean), sMessage);
	StripColorTags(sClean, sizeof(sClean));

	int iSpeakerTeam = GetClientTeam(speaker);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
			continue;

		if (bTeamChat)
		{
			int iTeam = GetClientTeam(i);
			if (iTeam != iSpeakerTeam && iTeam != 1)
				continue;
		}

		if (i != speaker && IsBlocked(i, speaker, BLOCK_TEXT))
			continue;

		CPrintToChatEx(i, speaker, "{teamcolor}%s{default} : %s", sName, sClean);
	}
}

/** 去掉 colors.inc 会解析的颜色标签，避免玩家名字/聊天内容注入颜色或触发异常 */
void StripColorTags(char[] text, int maxlen)
{
	static const char sColorTags[][] = {
		"{default}", "{darkred}", "{green}", "{lightgreen}", "{red}", "{blue}",
		"{olive}", "{lime}", "{lightred}", "{purple}", "{grey}", "{orange}",
		"{teamcolor}"
	};

	for (int i = 0; i < sizeof(sColorTags); i++)
		ReplaceString(text, maxlen, sColorTags[i], "", false);
}

/* ==========================================================================
 *  自动屏蔽：进服后立刻开始、且连续说满 N 秒的语音
 * ========================================================================== */

public void OnClientSpeaking(int client)
{
	g_bSpeaking[client] = true;
	g_fSilenceAt[client] = -1.0;

	if (!g_bAutoMute || !IsValidClient(client) || IsFakeClient(client))
		return;

	/* 已经判定过 / 不在进服窗口内 / 旁观者不参与 */
	if (g_bAutoDone[client] || g_bAutoTracked[client] || g_fJoinTime[client] < 0.0)
		return;

	if (GetClientTeam(client) < 2)
		return;

	if (GetGameTime() - g_fJoinTime[client] > g_fAutoWindow)
	{
		g_fJoinTime[client] = -1.0;
		return;
	}

	g_bAutoTracked[client] = true;
	g_fSpokenTime[client] = 0.0;
	EnsureAutoTimer();
}

public void OnClientSpeakingEnd(int client)
{
	g_bSpeaking[client] = false;
	g_fSilenceAt[client] = GetGameTime();
}

void EnsureAutoTimer()
{
	if (g_hAutoTimer != null)
		return;

	g_hAutoTimer = CreateTimer(AUTOMUTE_INTERVAL, Timer_AutoMuteCheck, _, TIMER_REPEAT);
}

public Action Timer_AutoMuteCheck(Handle timer)
{
	bool bKeep = false;
	float fNow = GetGameTime();
	float fDelta = (g_fTimerLast > 0.0) ? (fNow - g_fTimerLast) : AUTOMUTE_INTERVAL;
	g_fTimerLast = fNow;

	if (fDelta < 0.0)
		fDelta = 0.0;

	for (int i = 1; i <= MaxClients; i++)
	{
		/* 1) “进服后连续说话”判定 */
		if (g_bAutoTracked[i])
		{
			if (!g_bAutoMute || !IsValidClient(i) || IsFakeClient(i))
			{
				g_bAutoTracked[i] = false;
			}
			else
			{
				bKeep = true;

				if (g_bSpeaking[i])
				{
					g_fSpokenTime[i] += fDelta;

					if (g_fSpokenTime[i] >= AUTOMUTE_SECONDS)
					{
						g_bAutoTracked[i] = false;
						TriggerAutoMute(i);
					}
				}
				else
				{
					/* 要求“连续”：中途只要停止说话就重新计时。
					   开自由麦的玩家语音流是全程连续的，不会被这里打断 */
					g_bAutoTracked[i] = false;
					g_fSpokenTime[i] = 0.0;
				}
			}
		}

		/* 2) 被自动屏蔽的人安静够久 → 自动恢复接收其语音 */
		if (!HasAutoVoiceBlock(i))
			continue;

		bKeep = true;

		if (!g_bSpeaking[i] && g_fSilenceAt[i] >= 0.0 && fNow - g_fSilenceAt[i] >= AUTOMUTE_QUIET_RESTORE)
			RestoreAutoBlocks(i);
	}

	if (!bKeep)
	{
		g_hAutoTimer = null;
		g_fTimerLast = 0.0;
		return Plugin_Stop;
	}

	return Plugin_Continue;
}

/** 是否有人正被本插件的“进服语音自动屏蔽”屏蔽着 */
bool HasAutoVoiceBlock(int speaker)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (i != speaker && (g_iBlockFlags[i][speaker] & BLOCK_AUTO))
			return true;
	}
	return false;
}

/** 安静够久了：撤掉所有由自动屏蔽写入的语音屏蔽（手动屏蔽过的别人不动） */
void RestoreAutoBlocks(int speaker)
{
	int iSeconds = RoundToNearest(AUTOMUTE_QUIET_RESTORE);

	char sName[MAX_NAME_LENGTH];
	GetClientName(speaker, sName, sizeof(sName));
	StripColorTags(sName, sizeof(sName));

	for (int i = 1; i <= MaxClients; i++)
	{
		if (i == speaker || !(g_iBlockFlags[i][speaker] & BLOCK_AUTO))
			continue;

		g_iBlockFlags[i][speaker] &= ~(BLOCK_VOICE | BLOCK_AUTO);
		ApplyVoiceOverride(i, speaker);

		if (IsValidClient(i))
			CPrintToChat(i, "%t", "Msg_AutoMute_Restored", sName, iSeconds);
	}

	LogAction(0, speaker, "[BeBlock] 自动恢复接收语音: 已安静 %d 秒", iSeconds);
}

void TriggerAutoMute(int speaker)
{
	if (!IsValidClient(speaker))
		return;

	g_bAutoDone[speaker] = true;

	char sName[MAX_NAME_LENGTH];
	GetClientName(speaker, sName, sizeof(sName));
	StripColorTags(sName, sizeof(sName));

	/* 只写入同队玩家的个人屏蔽名单：进入 [×] 状态，
	   玩家仍旧可以用 !bz 打开菜单自行解除，不做全服禁语音 */
	int iTeam = GetClientTeam(speaker);
	int iSeconds = RoundToNearest(AUTOMUTE_SECONDS);
	bool bAny = false;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsValidClient(i) || i == speaker || GetClientTeam(i) != iTeam)
			continue;

		if (IsBlocked(i, speaker, BLOCK_VOICE))
			continue;

		g_iBlockFlags[i][speaker] |= (BLOCK_VOICE | BLOCK_AUTO);
		ApplyVoiceOverride(i, speaker);
		CPrintToChat(i, "%t", "Msg_AutoMute_Team", sName, iSeconds);
		bAny = true;
	}

	if (bAny)
	{
		LogAction(0, speaker, "[BeBlock] 自动屏蔽语音(同队): 进服 %.1f 秒内开始说话并连续 %d 秒",
			GetGameTime() - g_fJoinTime[speaker], iSeconds);
	}
}

/* ==========================================================================
 *  工具函数
 * ========================================================================== */

bool IsValidClient(int client)
{
	return (client > 0 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client));
}
