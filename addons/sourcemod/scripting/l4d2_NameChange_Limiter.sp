#pragma semicolon 1
#pragma newdecls required

//参考: 自选-禁止玩家控制台改名(蛋疼哥,sorallll)/l4d2_NameChange_Blocker.sp
//
//和参考版本的区别:
//	1:不阻止改名(不再把名字改回去),只统计次数.玩家改完名字立即生效;
//	2:只统计"真正的队伍"(生还者2/感染者3)里的改名;未分配队伍(0)一律不统计;
//	  旁观(1)是否统计由 change_name_count_spectator 决定(默认不统计);
//	3:l4d_spectator_prefix 自己造成的改名永远不统计(旁观时它只会加前缀,队伍里它只会去掉前缀);
//	4:次数超过上限直接踢出.

#include <sourcemod>

#define PLUGIN_VERSION "1.0"

#define TEAM_SPECTATOR 1

ConVar g_hChangeNameLimit;
ConVar g_hCountSpectator;
ConVar g_hPrefixType;	//l4d_spectator_prefix 的前缀cvar(可选,没装就是null)

int g_iChangeNameTries[MAXPLAYERS + 1];

public Plugin myinfo =
{
	name = "NameChange Limiter",
	author = "apples1949(重写自 蛋疼哥,sorallll)",
	description = "不阻止改名,只统计改名次数(旁观可选),超过上限踢出",
	version = PLUGIN_VERSION,
	url = "https://github.com/apples1949/l4dplugins"
}

public void OnPluginStart()
{
	g_hChangeNameLimit = CreateConVar("change_name_limit", "10", "允许改名的次数,超过该次数踢出", _, true, 1.0);
	g_hCountSpectator = CreateConVar("change_name_count_spectator", "0", "0=不统计旁观时的改名(默认), 1=旁观时的改名也统计", _, true, 0.0, true, 1.0);

	//不生成单独的CFG. cvar写在 cfg/sharedplugins.cfg 里
	//(confogl 每个比赛模式启动时执行一次, 所有配置都引用它, 本插件由那份配置 sm plugins load 加载)
	//AutoExecConfig(true, "l4d2_NameChange_Limiter");

	//用 Pre 而不是 Post: 别的插件(例如 bequiet.sp 的 bq_name_change_suppress)会在 Pre 里
	//Plugin_Handled 屏蔽改名播报,那时候 Post 钩子不一定还会被调用,而本插件必须保证统计到.
	//(Pre 钩子必须返回 Action,返回 Plugin_Continue 表示不干预)
	HookEvent("player_changename", Event_PlayerChangename, EventHookMode_Pre);

	FindPrefixCvar();
}

public void OnConfigsExecuted()
{
	//插件加载顺序不定,配置执行时再找一次前缀cvar
	FindPrefixCvar();
}

void FindPrefixCvar()
{
	if (g_hPrefixType == null)
		g_hPrefixType = FindConVar("l4d_spectator_prefix_type");
}

public void OnClientPutInServer(int client)
{
	if (IsFakeClient(client))
		return;

	g_iChangeNameTries[client] = 0;
}

public Action Event_PlayerChangename(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	//玩家已掉线 或 不是真人玩家
	if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
		return Plugin_Continue;

	int iTeam = GetClientTeam(client);

	//未分配队伍(0): 玩家连接时的初始名字变化都在这个阶段,一律不统计
	if (iTeam <= 0)
		return Plugin_Continue;

	//旁观(1): 是否统计由 change_name_count_spectator 决定
	if (iTeam == TEAM_SPECTATOR && !g_hCountSpectator.BoolValue)
		return Plugin_Continue;

	char sOldName[MAX_NAME_LENGTH], sNewName[MAX_NAME_LENGTH];
	event.GetString("oldname", sOldName, sizeof(sOldName));
	event.GetString("newname", sNewName, sizeof(sNewName));

	//新旧名字一样(引擎回声)不计
	if (strcmp(sOldName, sNewName) == 0)
		return Plugin_Continue;

	//l4d_spectator_prefix 自己改的名字永远不计
	if (IsPrefixPluginRename(sOldName, sNewName, iTeam))
		return Plugin_Continue;

	if (g_iChangeNameTries[client] >= g_hChangeNameLimit.IntValue)
	{
		KickClient(client, "[提示] 本服禁止频繁更改游戏名字");
		g_iChangeNameTries[client] = 0;
		return Plugin_Continue;
	}

	g_iChangeNameTries[client]++;

	return Plugin_Continue;
}

//判断这次改名是不是 l4d_spectator_prefix 干的(按它自己的两个分支逐一对上)
bool IsPrefixPluginRename(const char[] sOldName, const char[] sNewName, int iTeam)
{
	FindPrefixCvar();

	if (g_hPrefixType == null)
		return false;

	char sPrefix[32];
	g_hPrefixType.GetString(sPrefix, sizeof(sPrefix));

	if (sPrefix[0] == '\0')
		return false;

	if (iTeam == TEAM_SPECTATOR)
	{
		//旁观分支(L298-305): 只会把前缀加到名字前面
		char sAdded[MAX_NAME_LENGTH];
		FormatEx(sAdded, sizeof(sAdded), "%s%s", sPrefix, sOldName);

		return (strcmp(sAdded, sNewName) == 0);
	}

	//队伍分支(L306-316): 只会把名字里的前缀去掉
	char sStripped[MAX_NAME_LENGTH];
	strcopy(sStripped, sizeof(sStripped), sOldName);

	//和 l4d_spectator_prefix 里一样: 大小写敏感,替换全部
	if (ReplaceString(sStripped, sizeof(sStripped), sPrefix, "", true) == 0)
		return false;

	return (strcmp(sStripped, sNewName) == 0);
}
