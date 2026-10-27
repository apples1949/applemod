/*
 * ============================================================================
 * L4D2 Idle Watch (12v12)  —— 诊断用插件，不改任何游戏行为
 *
 * 目的：玩家反馈"有人被置成闲置（挂机托管）状态，名字上带闲置"。
 *       引擎里"闲置"= 玩家(旁观/未分配)仍拥有一个生还者身体（bot 身上的
 *       m_humanSpectatorUserID 指向他），身体由 AI 接管。
 *       能让玩家进入这个状态的只有两类来源：
 *         ① 玩家自己按闲置键 → 客户端命令 go_away_from_keyboard
 *         ② 插件调用 L4D_SetHumanSpec(bot, client)（或把活着的生还者
 *            ChangeClientTeam 到旁观，引擎顺手做同样的托管）
 *       本插件把这两类来源全部打上时间戳日志，并给一条 sm_idle 现场快照命令，
 *       用来"点名"到底是哪个插件/什么操作让玩家变成闲置。
 *
 * 输出：
 *   - 服务端日志（默认开）：每次进入/退出闲置、每次 go_away_from_keyboard、
 *     每次 player_bot_replace / bot_player_replace、每次队伍变化，都带游戏时间。
 *   - 聊天框（默认关）：只把"进入/退出闲置"播给有 ADMFLAG_GENERIC 的管理员。
 *   - 命令 sm_idle：列出每个玩家的队伍、是否闲置托管、托管的身体、身体是否存活、
 *     观察者模式，便于现场取证。
 * ============================================================================
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION		"1.0.0"

#define TEAM_SPECTATOR		1
#define TEAM_SURVIVOR		2

ConVar g_cvLog;			// 1 = 写服务端日志（默认开）
ConVar g_cvChat;		// 1 = 把进出闲置播给管理员（默认关）

bool g_bIdle[MAXPLAYERS + 1];		// 上一轮采样里该玩家是否处于闲置托管
int  g_iOwnedBot[MAXPLAYERS + 1];	// 该玩家当前拥有（托管）的身体

public Plugin myinfo =
{
	name        = "L4D2 Idle Watch (12v12)",
	author      = "apples1949",
	description = "诊断：记录谁/什么操作让玩家进入闲置(挂机托管)状态，并提供 sm_idle 现场快照",
	version     = PLUGIN_VERSION,
	url         = "N/A"
};

public void OnPluginStart()
{
	g_cvLog = CreateConVar("l4d2_idle_watch_log", "1",
		"1=把闲置相关事件写进服务端日志（默认）。0=只保留 sm_idle 命令",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvChat = CreateConVar("l4d2_idle_watch_chat", "0",
		"1=把玩家进入/退出闲置播给有管理权限的人。0=只在日志里（默认）",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	HookEvent("player_bot_replace", Event_BotReplace, EventHookMode_Post);
	HookEvent("bot_player_replace", Event_PlayerReplace, EventHookMode_Post);
	HookEvent("player_team", Event_PlayerTeam, EventHookMode_Post);

	// 玩家按闲置键（引擎命令）；只记录，不拦截
	AddCommandListener(Cmd_IdleKey, "go_away_from_keyboard");

	RegAdminCmd("sm_idle", Cmd_Idle, ADMFLAG_GENERIC,
		"列出所有玩家的闲置托管状态（队伍 / 是否闲置 / 托管的身体 / 身体是否存活 / 观察者模式）");

	CreateTimer(0.5, Timer_Poll, _, TIMER_REPEAT);
}

// ============================================================================
// 来自客户端的闲置命令
// ============================================================================

public Action Cmd_IdleKey(int client, const char[] command, int argc)
{
	if (client > 0 && client <= MaxClients && IsClientInGame(client))
	{
		LogLine("[闲置诊断] %N(队伍%d) 触发了闲置命令 go_away_from_keyboard", client, GetClientTeam(client));
	}

	return Plugin_Continue;
}

// ============================================================================
// 引擎事件：身体被 bot 接管 / 玩家接管 bot / 换队
// ============================================================================

public void Event_BotReplace(Event event, const char[] name, bool dontBroadcast)
{
	int player = GetClientOfUserId(event.GetInt("player"));
	int bot = GetClientOfUserId(event.GetInt("bot"));

	LogLine("[闲置诊断] player_bot_replace: 玩家 %N(队伍%d) 的身体被 bot %N(#%d) 接管"
		, IsValidClient(player) ? player : 0
		, IsValidClient(player) ? GetClientTeam(player) : -1
		, IsValidClient(bot) ? bot : 0
		, IsValidClient(bot) ? bot : 0);
}

public void Event_PlayerReplace(Event event, const char[] name, bool dontBroadcast)
{
	int player = GetClientOfUserId(event.GetInt("player"));
	int bot = GetClientOfUserId(event.GetInt("bot"));

	LogLine("[闲置诊断] bot_player_replace: 玩家 %N(队伍%d) 接管了 bot #%d"
		, IsValidClient(player) ? player : 0
		, IsValidClient(player) ? GetClientTeam(player) : -1
		, IsValidClient(bot) ? bot : 0);
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!IsValidClient(client))
		return;

	LogLine("[闲置诊断] player_team: %N 队伍 %d -> %d（断开连接=%d）"
		, client
		, event.GetInt("oldteam")
		, event.GetInt("team")
		, event.GetInt("disconnect"));
}

// ============================================================================
// 轮询：发现"进入/退出闲置"的瞬间
// ============================================================================

public Action Timer_Poll(Handle timer)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
		{
			g_bIdle[i] = false;
			g_iOwnedBot[i] = 0;
			continue;
		}

		int owned = GetOwnedSurvivorBot(i);
		bool idle = (owned > 0);

		if (idle && !g_bIdle[i])
		{
			LogLine("[闲置诊断] 进入闲置: %N(队伍%d) 现在托管 bot #%d（身体存活=%d，身体所在队伍=%d）"
				, i, GetClientTeam(i), owned, IsPlayerAlive(owned) ? 1 : 0, GetClientTeam(owned));

			NotifyAdmins("[闲置诊断] %N 进入了闲置（托管 bot #%d）", i, owned);
		}
		else if (!idle && g_bIdle[i])
		{
			LogLine("[闲置诊断] 退出闲置: %N(队伍%d) 不再托管任何身体（上次托管 #%d）"
				, i, GetClientTeam(i), g_iOwnedBot[i]);

			NotifyAdmins("[闲置诊断] %N 退出了闲置", i);
		}

		g_bIdle[i] = idle;
		g_iOwnedBot[i] = owned;
	}

	return Plugin_Continue;
}

// ============================================================================
// sm_idle：现场快照
// ============================================================================

public Action Cmd_Idle(int client, int args)
{
	ReplyToCommand(client, "\x04[闲置诊断]\x01 当前时间 %.1f；‘闲置’判定 = 该玩家仍拥有一个生还者身体（m_humanSpectatorUserID）",
		GetGameTime());

	int iCount = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
			continue;

		int owned = GetOwnedSurvivorBot(i);

		ReplyToCommand(client,
			"\x04[闲置诊断]\x01 #%d %N | 队伍=%d inGame=%d | 闲置=%d 托管身体=%d(存活=%d,队伍=%d) | 观察者模式=%d | 本回合已闲置=%d",
			i,
			i,
			GetClientTeam(i),
			1,
			owned > 0 ? 1 : 0,
			owned,
			(owned > 0 && IsPlayerAlive(owned)) ? 1 : 0,
			(owned > 0) ? GetClientTeam(owned) : -1,
			GetEntProp(i, Prop_Send, "m_iObserverMode"),
			g_bIdle[i] ? 1 : 0);

		if (owned > 0)
			iCount++;
	}

	ReplyToCommand(client, "\x04[闲置诊断]\x01 共 %d 名真人处于闲置托管状态", iCount);

	return Plugin_Handled;
}

// ============================================================================
// 工具
// ============================================================================

// 该玩家当前托管的生还者身体（没有返回 0）
int GetOwnedSurvivorBot(int client)
{
	for (int bot = 1; bot <= MaxClients; bot++)
	{
		if (!IsClientInGame(bot) || !IsFakeClient(bot))
			continue;

		if (!HasEntProp(bot, Prop_Send, "m_humanSpectatorUserID"))
			continue;

		int owner = GetClientOfUserId(GetEntProp(bot, Prop_Send, "m_humanSpectatorUserID"));

		if (owner == client)
			return bot;
	}

	return 0;
}

bool IsValidClient(int client)
{
	return (client > 0 && client <= MaxClients && IsClientInGame(client));
}

void LogLine(const char[] format, any ...)
{
	if (!g_cvLog.BoolValue)
		return;

	char sBuffer[512];
	VFormat(sBuffer, sizeof(sBuffer), format, 2);

	LogMessage("%s", sBuffer);
	PrintToServer("%s", sBuffer);
}

void NotifyAdmins(const char[] format, any ...)
{
	if (!g_cvChat.BoolValue)
		return;

	char sBuffer[512];
	VFormat(sBuffer, sizeof(sBuffer), format, 2);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
			continue;

		if (CheckCommandAccess(i, "sm_idle", ADMFLAG_GENERIC))
			PrintToChat(i, "%s", sBuffer);
	}
}
