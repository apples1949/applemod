#pragma semicolon 1
//強制1.7以後的新語法
#pragma newdecls required
#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#define PLUGIN_VERSION "1.1.0"

// ============================================================================
// 1.1.0 变更（按需求）：倒地/挂边的生还者只有在「终点安全屋里有生还者」时才允许自杀
//
//   新条件（cvar l4d2_suicide_require_saferoom，默认 1=启用）：
//     - 生还者队伍里至少有 1 个生还者正站在「本关终点安全屋」内，才允许倒地/挂边的
//       生还者自杀；一个都没有时提示「请等队友进安全屋后再试」。
//     - 判定用 Left4DHooks 的 L4D_IsInLastCheckpoint(client)
//       （left4dhooks.inc:3977-3984：用 info_changelevel 的 mins/maxs 做体积判定），
//       它判的是「结束安全屋」；起点安全屋是另一个 native（L4D_IsInFirstCheckpoint），
//       两者不混用。
//     - g_iSuicide == 2（无条件自杀）同样受这个条件限制 —— 需求限定的是「倒地玩家
//       自杀」的时机，无条件模式不得绕过安全屋条件。
//
//   两条回落（任何一条成立就退回 1.0.3 的旧行为，绝不因为判定不出来就把自杀彻底禁掉）：
//     - native 缺失：inc 里该 native 是 MarkNativeAsOptional，left4dhooks 太旧/没装时
//       进程里没有它，GetFeatureStatus 探不到 → 不启用新条件，只打一次控制台/日志提示。
//     - 救援关（终局图）：地图里没有 info_changelevel 实体，L4D_IsInLastCheckpoint 必然
//       对所有人返回 false → 识别出来后「救援关一律放行」，否则救援关里倒地/挂边的玩家
//       永远自杀不了，只能一直爬。
//
//   判定链路（IsPlayerSuicide，顺序不可调换）：
//     起点安全屋（原有，保持不动）→ 是否活着 → 倒地/挂边（g_iSuicide）
//       → 终点安全屋条件（本版新增）→ 执行自杀
//
//   1.1.0 同时修掉一个隐患：GetTrueName 原先 return 的是局部数组（栈内存），
//   调用方拿到的是悬空引用，已改成输出参数写法 GetTrueName(client, buffer, maxlen)。
// ============================================================================

int    g_iSuicide, g_iShowTips;
ConVar g_hSuicide, g_hShowTips;
ConVar g_hRequireSaferoom;			//1.1.0：倒地/挂边自杀是否要求终点安全屋里有生还者.

//1.1.0：终点安全屋条件的运行期状态
//  g_bNtvLastCheckpoint   L4D_IsInLastCheckpoint 是否可用（inc 里是 MarkNativeAsOptional）
//  g_bHasEndSaferoom      本图是否存在终点安全屋（存在 info_changelevel 实体才算；救援关没有）
//  g_bEndSaferoomChecked  本回合是否已经算过上面两项（换图 / round_start 会重算）
//  g_bNtvLastCheckpointWarned  "native 不可用"的控制台/日志提示只打一次
bool g_bNtvLastCheckpoint;
bool g_bHasEndSaferoom;
bool g_bEndSaferoomChecked;
bool g_bNtvLastCheckpointWarned;

public Plugin myinfo =  
{
	name = "l4d2_player_suicide",
	author = "apples1949",  
	description = "玩家自杀指令(1.1.0 起: 倒地/挂边自杀要求终点安全屋里已有生还者; 救援关放行)",
	version = PLUGIN_VERSION,
	url = "N/A"
};

public void OnPluginStart()
{
	RegConsoleCmd("sm_zs", Command_Suicide, "玩家自杀指令.");
	RegConsoleCmd("sm_kill", Command_Suicide, "玩家自杀指令.");
	
	g_hSuicide	= CreateConVar("l4d2_player_suicide",		"1", "启用玩家自杀指令. 0=禁用, 1=只限倒地或挂边的生还者, 2=无条件使用.");
	g_hShowTips	= CreateConVar("l4d2_suicide_start_tips",	"7", "设置开局提示自杀指令的延迟显示时间/秒. 0=禁用.");
	g_hRequireSaferoom	= CreateConVar("l4d2_suicide_require_saferoom",	"1", "倒地/挂边的生还者自杀时, 是否要求终点安全屋里已经有生还者. 0=不要求(退回旧行为), 1=要求(救援关一律放行).");
	g_hSuicide.AddChangeHook(IsSuicideConVarChanged);
	g_hShowTips.AddChangeHook(IsSuicideConVarChanged);
	//g_hRequireSaferoom 不需要 ChangeHook：IsAnySurvivorInEndSaferoom 每次都用 BoolValue 现读，改成 0/1 立即生效.

	HookEvent("round_start", IsRoundStartEvent);
	//1.1.0：不在这里判「终点安全屋」—— OnPluginStart 时 left4dhooks 可能还没注册 native，
	//会误报「缺失」。改由 OnMapStart / round_start 先算，第一次用时也会按需补算（见 IsAnySurvivorInEndSaferoom）.
	//AutoExecConfig(true, "l4d2_player_suicide");
}

public void OnMapStart()
{
	//1.1.0：换图后重新判定（救援关在这里被识别出来 → 一律放行）.
	RefreshEndSaferoomState();
}

public void IsRoundStartEvent(Event event, const char[] name, bool dontBroadcast)
{
	//1.1.0：每回合重算一次；那时地图实体一定已经加载完.
	RefreshEndSaferoomState();
}

public void OnConfigsExecuted()
{	
	IsConVarSuicide();
}

public void IsSuicideConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	IsConVarSuicide();
}

void IsConVarSuicide()
{
	g_iSuicide = g_hSuicide.IntValue;
	g_iShowTips = g_hShowTips.IntValue;
}

public Action OnClientSayCommand(int client, const char[] commnad, const char[] args)
{
	if(strlen(args) <= 1 || strncmp(commnad, "say", 3, false) != 0)
		return Plugin_Continue;

	if (StrEqual(args, "自杀", false))
		RequestFrame(IsFrameSuicide, GetClientUserId(client));
	return Plugin_Continue;
}

//玩家连接成功.
public void OnClientPostAdminCheck(int client)
{
	if (!IsFakeClient(client) && g_iShowTips > 0)
		CreateTimer(float(g_iShowTips), IsShowTipsTimer, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action IsShowTipsTimer(Handle timer, any client)
{
	if ((client = GetClientOfUserId(client)))
	{
		if (IsClientInGame(client))
		{
			switch (GetClientTeam(client))
			{
				case 1,3:
					PrintToChat(client, "\x04[提示]\x05输入指令\x03!zs\x05或\x03!kill\x05或\x03自杀\x05可自杀.");//聊天窗提示.
				case 2,4:
				{
					switch (g_iSuicide)
					{
						case 1:
							PrintToChat(client, "\x04[提示]\x05倒地或挂边时输入指令\x03!zs\x05或\x03!kill\x05或\x03自杀\x05可自杀.");//聊天窗提示.
						case 2:
							PrintToChat(client, "\x04[提示]\x05输入指令\x03!zs\x05或\x03!kill\x05或\x03自杀\x05可自杀.");//聊天窗提示.
						default:
							PrintToChat(client, "\x04[提示]\x05输入指令\x03!zs\x05或\x03!kill\x05或\x03自杀\x05可自杀.");//聊天窗提示.
					}
				}
			}
		}
	}
	return Plugin_Stop;
}

public Action Command_Suicide(int client, int args)
{
	RequestFrame(IsFrameSuicide, GetClientUserId(client));
	return Plugin_Handled;
}

void IsFrameSuicide(int client)
{
	if ((client = GetClientOfUserId(client)))
		if(IsClientInGame(client) && !IsFakeClient(client))
			if(g_iSuicide > 0)
				IsRegSuicide(client);
			else
				PrintToChat(client, "\x04[提示]\x05玩家自杀指令未启用.");
}

void IsRegSuicide(int client)
{
	if(IsValidClient(client) && !IsFakeClient(client))
	{
		//1.1.0：GetTrueName 改成输出参数写法（原先返回局部数组不可靠），名字在这里取好再传.
		char g_sName[32];

		switch (GetClientTeam(client))
		{
			case 1:
			{
				int iBot = IsGetBotOfIdlePlayer(client);
				if (iBot != 0)
				{
					GetTrueName(client, g_sName, sizeof(g_sName));
					IsPlayerSuicide(iBot, client, g_sName, "生还者");
				}
				else
					PrintToChat(client, "\x04[提示]\x05旁观者无权使用该指令.");
			}
			case 2:
			{
				GetTrueName(client, g_sName, sizeof(g_sName));
				IsPlayerSuicide(client, client, g_sName, "生还者");
			}
			case 3:
				PrintToChat(client, "\x04[提示]\x05该指令仅限生还者使用.");
			case 4:
			{
				GetTrueName(client, g_sName, sizeof(g_sName));
				IsPlayerSuicide(client, client, g_sName, "生还者");
			}
		}
	}
}

void IsPlayerSuicide(int client, int victim, char[] g_sName, char[] g_sTeam)
{
	//判定链路（顺序不可调换）：
	//   起点安全屋 → 是否活着 → 倒地/挂边 → 终点安全屋条件 → 执行.
	//起点安全屋：1.0.3 的 L4D_IsInFirstCheckpoint 判定逻辑一字未改；
	//只对活着的玩家判断（和 1.0.3 的嵌套结构等价），死在屋里的玩家应当看到「已是死亡状态」.
	if (IsPlayerAlive(client) && IsClientInStartCheckpoint(client))
	{
		PrintToChat(victim, "\x04[提示]\x05在安全区域内不能自杀,请离开安全区域后再试.");
		return;
	}

	if (!IsPlayerAlive(client))
	{
		PrintToChat(victim, "\x04[提示]\x05你当前已是死亡状态.");
		return;
	}

	//0=禁用（IsFrameSuicide 已挡）, 1=只限倒地或挂边, 2=无条件；其他取值按原逻辑不处理.
	if (g_iSuicide != 1 && g_iSuicide != 2)
		return;

	if (g_iSuicide == 1 && IsPlayerState(client))
	{
		PrintToChat(victim, "\x04[提示]\x05该指令只限倒地或挂边的%s使用.", g_sTeam);
		return;
	}

	//1.1.0：终点安全屋条件 —— g_iSuicide==2（无条件）同样受限制，不得绕过.
	//   救援关 / native 缺失 / cvar=0 时本函数返回 true（退回旧行为），见 IsAnySurvivorInEndSaferoom.
	if (!IsAnySurvivorInEndSaferoom())
	{
		PrintToChat(victim, "\x04[提示]\x05终点安全屋里有生还者时才能自杀，请等队友进安全屋后再试.");
		return;
	}

	IsForceSuicide(client, victim, g_sName, g_sTeam);//执行玩家死亡代码.
}

void IsForceSuicide(int client, int victim, char[] g_sName, char[] g_sTeam)
{
	if (IsPlayerAlive(client))
	{
		ForcePlayerSuicide(client);//幸存者自杀代码.
		PrintToChatAll("\x04[提示]\x05(\x04%s\x05)\x03%s\x05突然失去了梦想.", g_sTeam, g_sName);
	}
	else
		PrintToChat(victim, "\x04[提示]\x05你当前已是死亡状态.");
}

stock bool IsValidClient(int client)
{
	return client > 0 && client <= MaxClients && IsClientInGame(client);
}

//正常状态.
stock bool IsPlayerState(int client)
{
	return !GetEntProp(client, Prop_Send, "m_isIncapacitated") && !GetEntProp(client, Prop_Send, "m_isHangingFromLedge");
}

//是否位于起始安全区域内（1.0.3 原样保留，起点安全屋用这个，不要换成 L4D_IsInLastCheckpoint）.
stock bool IsClientInStartCheckpoint(int client)
{
	return GetFeatureStatus(FeatureType_Native, "L4D_IsInFirstCheckpoint") == FeatureStatus_Available && L4D_IsInFirstCheckpoint(client);
}

//1.1.0：生还者队伍里是否至少有 1 个生还者正站在「本关终点安全屋」内.
//
//   判定用 Left4DHooks 的 L4D_IsInLastCheckpoint(client)
//   （left4dhooks.inc:3977-3984：@brief Returns true when the specified Survivor or Special
//   Infected is in the ending checkpoint area；@remarks This uses the "info_changelevel"
//   entity, and checks the player is within the vector mins and vector maxs of the entity）。
//   它判的是「结束安全屋」；起点安全屋是另一个 native（L4D_IsInFirstCheckpoint），不混用。
//   已经倒地的队友只要人在屋里也算（人都已经进屋了，没有理由继续卡自杀）。
//
//   任何一条回落成立就返回 true（= 允许自杀，等价 1.0.3 的旧行为），绝不因为判定不出来就彻底禁掉自杀：
//     ① cvar l4d2_suicide_require_saferoom = 0；
//     ② 运行期拿不到 L4D_IsInLastCheckpoint（left4dhooks 缺失 / 版本太旧）；
//     ③ 本图没有 info_changelevel → 救援关（终局图）一律放行：救援关没有终点安全屋，
//        L4D_IsInLastCheckpoint 对所有人恒为 false，按 false 处理的话救援关里倒地/挂边的
//        玩家永远自杀不了，只能一直爬。
stock bool IsAnySurvivorInEndSaferoom()
{
	if (!g_hRequireSaferoom.BoolValue)
		return true;

	//插件晚加载 / 漏接 round_start 时补一次（算过就直接跳过，不重复扫实体）.
	if (!g_bEndSaferoomChecked)
		RefreshEndSaferoomState();

	//native 不可用 / 救援关（没有 info_changelevel）→ 退回旧行为.
	if (!g_bNtvLastCheckpoint || !g_bHasEndSaferoom)
		return true;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != 2 || !IsPlayerAlive(i))
			continue;

		if (L4D_IsInLastCheckpoint(i))
			return true;
	}

	return false;
}

//1.1.0：刷新「native 在不在 / 本图有没有终点安全屋」两个运行期条件。
//   换图（OnMapStart）与每回合（round_start）各重算一次即可：那时地图实体一定已经加载完。
//
//   为什么用 info_changelevel 判断「有没有终点安全屋」：
//     L4D_IsInLastCheckpoint 本身就是拿 info_changelevel 的 mins/maxs 做体积判定
//     （见上面 native 的 @remarks），图里没有这个实体时它必然对所有人返回 false。
//     救援关/终局图只有 trigger_finale / 救援载具，没有 info_changelevel，在这里被识别出来，
//     于是「救援关一律放行」——避免救援关倒地玩家永远不能自杀。
void RefreshEndSaferoomState()
{
	g_bEndSaferoomChecked = true;
	g_bHasEndSaferoom = false;

	//native 可用性每回合复核一次：left4dhooks 可能比本插件晚注册 native，
	//OnPluginStart 那一刻查不到，等它注册完成后这里就能拿到.
	g_bNtvLastCheckpoint = (GetFeatureStatus(FeatureType_Native, "L4D_IsInLastCheckpoint") == FeatureStatus_Available);

	if (!g_bNtvLastCheckpoint)
	{
		//只有真的要启用新条件时才提示；cvar=0 的服不该看到这条噪音，而且只提示一次.
		if (g_hRequireSaferoom.BoolValue && !g_bNtvLastCheckpointWarned)
		{
			g_bNtvLastCheckpointWarned = true;
			PrintToServer("[Suicide] 未检测到 L4D_IsInLastCheckpoint（Left4DHooks 缺失或版本太旧）：l4d2_suicide_require_saferoom 不生效，仍按旧行为（倒地或挂边即可自杀）。");
			LogMessage("[Suicide] 未检测到 L4D_IsInLastCheckpoint（Left4DHooks 缺失或版本太旧）：l4d2_suicide_require_saferoom 不生效，仍按旧行为（倒地或挂边即可自杀）。");
		}

		return;
	}

	//不管 cvar 当前开没开都记下「本图有没有终点安全屋」，
	//这样管理员运行中把 cvar 从 0 改成 1 也能立刻生效（不用等下一回合）.
	if (FindEntityByClassname(-1, "info_changelevel") != -1)
		g_bHasEndSaferoom = true;
}

//返回对应的内容.
void GetTrueName(int client, char[] buffer, int maxlen)
{
	GetClientName(client, buffer, maxlen);
}

//返回闲置玩家对应的电脑.
int IsGetBotOfIdlePlayer(int client)
{
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && IsFakeClient(i) && GetClientTeam(i) == 2 && IsClientIdle(i) == client)
			return i;

	return 0;
}

//返回电脑幸存者对应的玩家.
int IsClientIdle(int client)
{
	if (!HasEntProp(client, Prop_Send, "m_humanSpectatorUserID"))
		return 0;

	return GetClientOfUserId(GetEntProp(client, Prop_Send, "m_humanSpectatorUserID"));
}
