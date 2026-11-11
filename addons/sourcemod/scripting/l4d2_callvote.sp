/*
 *	v1.0.0
 *
 *	1:初始版本发布.
 *
 *	v2.0.0 (apples1949)
 *
 *	1:接管游戏内置投票, 转交 votes_applemod 处理(原来的版本只是全部拦掉).
 *	   - 全体语音 (changealltalk)          -> votes_applemod 的投票.内置那个是"切换", 这里按当前
 *	                                          sv_alltalk 选择 开启(votesalltalk) / 关闭(votesalltalk2)
 *	   - 更换地图 (changemission / changechapter) -> votes_applemod 的 votesmap <地图名>, 直接发起
 *	                                          对应地图的投票; 内置投票没带地图名/名字认不出来时,
 *	                                          退回打开插件自己的地图菜单, 不堵死玩家
 *	   - 踢出玩家 (kick)                    -> 只打开 votes_applemod 的选人菜单, 不预选内置投票带上来的目标
 *	   - 其余(changedifficulty) -> 继续拦截, 但提示改成"已由服务器投票系统接管"
 *	   - restartgame(重置地图) / returntolobby(返回大厅) -> **一律阻止**, 不转交也不放给引擎;
 *	     对应 cvar 仅为兼容旧 cfg 保留, 已不生效(见第 5 条)
 *	2:l4d2_enabled_change_alltalk / _change_chapter / _change_mission / _change_playerkick
 *	   默认值改成 1(接管生效); _restartgame / _returntolobby / _change_difficulty 保持 0(拦截).
 *	   =0 时仍然是原来的"已禁用"提示, =1 时转交服务器投票插件.
 *	3:防递归 + 防刷: 转交期间置 g_bForwarding[client], 转交出去的命令若又绕回 callvote 直接放行;
 *	   同一玩家 2 秒内重复 callvote 只处理第一次.
 *	4:votes_applemod 未加载 / builtinvotes 扩展不可用 -> 退回原来的"已禁用"提示, 不会放给引擎原生投票.
 *
 */
#pragma semicolon 1				//添加结束符.
#pragma newdecls required		//强制新语法.
#include <sourcemod>			//加载函数库.
#define PLUGIN_VERSION		"2.0.0"	//定义插件版本.

//同一玩家在这段时间内重复 callvote 只处理第一次(防刷/连点).
#define CALLVOTE_SPAM_WINDOW	2.0
//定义全局变量.
//g_iChangeRestartGame / g_iChangeReturnTolobby 已删除: 这两类投票一律阻止, 不再读 cvar.
int    g_iChangeAlltalk, g_iChangeChapter, g_iChangeDifficulty, g_iChangeMission, g_iChangePlayerKick;
ConVar g_hChangeAlltalk, g_hChangeChapter, g_hChangeDifficulty, g_hChangeMission, g_hChangePlayerKick, g_hChangeRestartGame, g_hChangeReturnTolobby;

float  g_fLastCallvote[MAXPLAYERS + 1];		//上次处理 callvote 的时刻, 0=没有
bool   g_bForwarding[MAXPLAYERS + 1];		//正在把投票转交 votes_applemod, 期间不再接管(防递归)

//定义插件信息.
public Plugin myinfo =  
{
	name = "l4d2_callvote",
	author = "豆瓣酱な",
	description = "接管游戏自带的投票功能,转交 votes_applemod 处理.",
	version = PLUGIN_VERSION,
	url = "N/A"
};

//插件开始.
public void OnPluginStart()
{
	//1=接管并转交服务器投票插件, 0=直接拦截(原来的"已禁用"提示).
	//接管生效的几项默认 1; 服务器投票插件没有对应投票的项保持 0.
	g_hChangeAlltalk		= CreateConVar("l4d2_enabled_change_alltalk", "1", "内置投票接管: 全体语音. 1=转交服务器投票插件, 0=拦截.");
	g_hChangeChapter		= CreateConVar("l4d2_enabled_change_chapter", "1", "内置投票接管: 更换章节. 1=转交服务器投票插件(改发起对应地图投票), 0=拦截.");
	g_hChangeDifficulty		= CreateConVar("l4d2_enabled_change_difficulty", "0", "内置投票接管: 更改难度. 1=只提示难度由服务器管理, 0=拦截.");
	g_hChangeMission		= CreateConVar("l4d2_enabled_change_mission", "1", "内置投票接管: 开始新图. 1=转交服务器投票插件(改发起对应地图投票), 0=拦截.");
	g_hChangePlayerKick		= CreateConVar("l4d2_enabled_change_playerkick", "1", "内置投票接管: 踢出玩家. 1=打开服务器投票插件的选人菜单, 0=拦截.");
	g_hChangeRestartGame	= CreateConVar("l4d2_enabled_change_restartgame", "0", "「重置地图」内置投票: 已强制阻止(0/1 都不再转交, 本 cvar 仅为兼容旧 cfg 保留).");
	g_hChangeReturnTolobby	= CreateConVar("l4d2_enabled_change_returntolobby", "0", "「返回大厅」内置投票: 已强制阻止(0/1 都不再转交, 本 cvar 仅为兼容旧 cfg 保留).");
	
	g_hChangeAlltalk.AddChangeHook(ConVarChangedHook);
	g_hChangeChapter.AddChangeHook(ConVarChangedHook);
	g_hChangeDifficulty.AddChangeHook(ConVarChangedHook);
	g_hChangeMission.AddChangeHook(ConVarChangedHook);
	g_hChangePlayerKick.AddChangeHook(ConVarChangedHook);
	g_hChangeRestartGame.AddChangeHook(ConVarChangedHook);
	g_hChangeReturnTolobby.AddChangeHook(ConVarChangedHook);
	
	//AutoExecConfig(true, "l4d2_callvote");//生成指定文件名的CFG.
	AddCommandListener(Listener_CallVote, "callvote");
}

//地图开始.
public void OnMapStart()
{
	GetConVarChange();

	//换图后玩家索引会复用, 防刷/防递归状态必须清掉
	for (int i = 0; i <= MaxClients; i++)
	{
		g_fLastCallvote[i] = 0.0;
		g_bForwarding[i] = false;
	}
}

//玩家断线时清状态, 避免索引复用后带着旧的冷却时间.
public void OnClientDisconnect(int client)
{
	if (client <= 0 || client > MaxClients)
		return;

	g_fLastCallvote[client] = 0.0;
	g_bForwarding[client] = false;
}

//参数更改回调.
void ConVarChangedHook(ConVar convar, const char[] oldValue, const char[] newValue)
{
	GetConVarChange();
}

//赋值到全局变量.
void GetConVarChange()
{
	g_iChangeAlltalk = g_hChangeAlltalk.IntValue;
	g_iChangeChapter = g_hChangeChapter.IntValue;
	g_iChangeDifficulty = g_hChangeDifficulty.IntValue;
	g_iChangeMission = g_hChangeMission.IntValue;
	g_iChangePlayerKick = g_hChangePlayerKick.IntValue;
	//g_iChangeRestartGame / g_iChangeReturnTolobby 不再赋值: 这两类投票一律阻止.
}

//监听回调.
Action Listener_CallVote(int client, const char[] command, int args)
{
	//服务器控制台发起的投票不接管, 交回引擎.
	if (client <= 0)
		return Plugin_Continue;

	if (!IsValidClient(client) || IsFakeClient(client))
		return Plugin_Continue;

	//我们自己转交出去的命令如果又绕回 callvote, 必须放行, 否则会死循环.
	if (g_bForwarding[client])
		return Plugin_Continue;

	char Msg[64];
	Msg[0] = '\0';
	GetCmdArg(1, Msg, sizeof(Msg));

	//只敲了 callvote 没带类型: 吃掉并引导用 !votes.
	if (Msg[0] == '\0')
	{
		PrintTag(client, " 请用指令 \x04!votes\x05 打开服务器投票菜单.");
		return Plugin_Handled;
	}

	//防刷: 冷却窗口内重复 callvote 直接吞掉(不再提示).
	float fNow = GetGameTime();
	if (g_fLastCallvote[client] > 0.0 && (fNow - g_fLastCallvote[client]) < CALLVOTE_SPAM_WINDOW)
		return Plugin_Handled;

	g_fLastCallvote[client] = fNow;

	//一.全体语音: 内置那个是"切换", 这里按当前 sv_alltalk 决定发起 开启/关闭 投票.
	if (StrEqual(Msg, "changealltalk", false))
	{
		if (g_iChangeAlltalk == 0)
			return BlockAsDisabled(client, "全体语音");

		if (!IsVoteBackendReady(client))
			return Plugin_Handled;

		ConVar hAlltalk = FindConVar("sv_alltalk");
		bool bAlltalkOn = (hAlltalk != null && hAlltalk.BoolValue);

		ForwardVote(client, bAlltalkOn ? "votesalltalk2" : "votesalltalk");
		PrintTag(client, " 已转交服务器投票插件: \x04%s全体语音\x05 投票.", bAlltalkOn ? "关闭" : "开启");
		return Plugin_Handled;
	}

	//三.踢出玩家: 只打开插件的选人菜单, 不预选内置投票带上来的目标
	//   (那个目标名可能已经改名/已经离开, 由插件菜单重新选更可靠).
	if (StrEqual(Msg, "kick", false))
	{
		if (g_iChangePlayerKick == 0)
			return BlockAsDisabled(client, "踢出玩家");

		if (!IsVoteBackendReady(client))
			return Plugin_Handled;

		ForwardVote(client, "voteskick");
		PrintTag(client, " 已转交服务器投票插件: 请在菜单里选择要\x04踢出\x05的玩家.");
		return Plugin_Handled;
	}

	//二.地图: changemission(换战役) / changechapter(换章节) -> 直接发起对应地图的投票.
	bool bIsMission = StrEqual(Msg, "changemission", false);
	bool bIsChapter = StrEqual(Msg, "changechapter", false);
	if (bIsMission || bIsChapter)
	{
		if (bIsMission && g_iChangeMission == 0)
			return BlockAsDisabled(client, "开始新图");

		if (bIsChapter && g_iChangeChapter == 0)
			return BlockAsDisabled(client, "更换章节");

		if (!IsVoteBackendReady(client))
			return Plugin_Handled;

		char sArg[64];
		sArg[0] = '\0';
		if (args >= 2)
			GetCmdArg(2, sArg, sizeof(sArg));

		CleanVoteArg(sArg);

		//changechapter 如果传的是纯数字(章节号而非地图名), 没法安全换算成地图名
		//(哪张战役的第三章要按当前地图推), 直接退化成开菜单让玩家选, 免得落到别的战役.
		bool bNumericArg = IsNumericString(sArg);

		if (sArg[0] != '\0' && !(bIsChapter && bNumericArg))
		{
			//参数可能是章节地图名(c2m3_coaster) / 战役序号(C5) / 关键字(hotel),
			//由 votes_applemod 的 votesmap 负责解析+校验, 这里只做转发.
			ForwardVote(client, "votesmap \"%s\"", sArg);
			PrintTag(client, " 已转交服务器投票插件: 更换地图 \x04%s\x05.", sArg);
		}
		else
		{
			//内置投票没带地图名: 退回打开插件的地图菜单, 别把玩家堵死.
			ForwardVote(client, "votesmapsmenu");
			PrintTag(client, " 已转交服务器投票插件: 请在弹出的\x04地图菜单\x05里选择.");
		}
		return Plugin_Handled;
	}

	//四.其余内置投票: 有对应投票的就转交, 没有的就说明交给服务器管理.
	//需求: 「重置地图」和「返回大厅」两类投票一律阻止 —— 既不转交给服务器投票插件,
	//也不放给引擎原生投票, 没有 cvar 可以打开(对应 cvar 保留只为兼容旧 cfg, 不再生效).
	if (StrEqual(Msg, "restartgame", false))
	{
		PrintTag(client, " 服务器已禁止发起 \x04重置地图\x05 投票.");
		return Plugin_Handled;
	}

	if (StrEqual(Msg, "returntolobby", false))
	{
		PrintTag(client, " 服务器已禁止发起 \x04返回大厅\x05 投票.");
		return Plugin_Handled;
	}

	if (StrEqual(Msg, "changedifficulty", false))
	{
		if (g_iChangeDifficulty == 0)
			return BlockAsDisabled(client, "更改难度");

		//服务器投票插件没有难度投票, 难度由配置统一管理.
		PrintTag(client, " 难度由服务器配置统一管理, \x04不支持投票更改\x05.");
		return Plugin_Handled;
	}

	//未知的内置投票类型: 一律吃掉, 不给引擎原生投票留口子.
	PrintTag(client, " 该投票已由服务器投票系统接管, 请用指令 \x04!votes\x05 查看可发起的投票.");
	return Plugin_Handled;
}

//=0 时的提示(保留原来的"已禁用"语义).
Action BlockAsDisabled(int client, const char[] sName)
{
	PrintTag(client, " 游戏自带的投票\x04%s\x05已禁用, 请用指令 \x04!votes\x05 投票.", sName);
	return Plugin_Handled;
}

//转交前确认服务器投票插件与 builtinvotes 都在, 否则退回"已禁用"提示.
bool IsVoteBackendReady(int client)
{
	if (LibraryExists("votes_applemod")
		&& GetCommandFlags("votesmap") != INVALID_FCVAR_FLAGS
		&& GetFeatureStatus(FeatureType_Native, "CreateBuiltinVote") == FeatureStatus_Available)
	{
		return true;
	}

	PrintTag(client, " 服务器投票插件当前不可用, 游戏自带的投票\x04已禁用\x05, 请稍后再试或联系管理员.");
	return false;
}

//把命令转交给 votes_applemod. 转交期间置标志位, 防止转交出去的命令又绕回 callvote.
void ForwardVote(int client, const char[] fmt, any ...)
{
	char sCmd[192];
	VFormat(sCmd, sizeof(sCmd), fmt, 3);

	g_bForwarding[client] = true;
	FakeClientCommand(client, "%s", sCmd);	//用 "%s" 包一层: 命令里即使有 % 也不会被当格式串
	g_bForwarding[client] = false;
}

//清理内置投票带上来的参数: 去首尾空格, 遇到能注入控制台命令/破坏参数的字符就截断.
void CleanVoteArg(char[] sArg)
{
	TrimString(sArg);

	for (int i = 0; sArg[i] != '\0'; i++)
	{
		if (sArg[i] == ';' || sArg[i] == '"' || sArg[i] == '%' || sArg[i] == '\r' || sArg[i] == '\n')
		{
			sArg[i] = '\0';
			break;
		}
	}

	TrimString(sArg);
}

//是否全由数字组成(用于识别"纯数字章节号"这种没法安全换算的参数).
bool IsNumericString(const char[] sText)
{
	if (sText[0] == '\0')
		return false;

	for (int i = 0; sText[i] != '\0'; i++)
	{
		if (!IsCharNumeric(sText[i]))
			return false;
	}

	return true;
}

//玩家有效性.
stock bool IsValidClient(int client)
{
	return client > 0 && client <= MaxClients && IsClientInGame(client);
}

//带统一前缀(\x04[提示]\x05)的聊天输出. SourcePawn 不支持相邻字符串字面量拼接,
//所以统一走这个封装, 不要在消息里重复写前缀.
void PrintTag(int client, const char[] fmt, any ...)
{
	char sMsg[256];
	VFormat(sMsg, sizeof(sMsg), fmt, 3);
	PrintToChat(client, "\x04[提示]\x05 %s", sMsg);
}
