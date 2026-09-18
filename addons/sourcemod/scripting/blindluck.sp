// Blind Luck - A modification for the game Left4Dead */
// Copyright 2009 James Richardson */
// 1.2.0 起由 apples1949 接续修改维护（原始版本与作者信息见下方更新日志 / GPL 声明）。

/*
This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

/*
* Version 1.0
* 		- Initial release.
* Version 1.0.1
* 		- Now works with sv_cheats off (thanks TESLA-X4 for the idea).
* Version 1.0.2
* 		- Fixed the two ConVars so they no longer cause error messages in client consoles when connecting.
* 		- Corrected some spelling mistakes in the comments that were bugging me.
* Version 1.0.3
* 		- Fixed ArrayOutOfBounds error.
*			- Seperated Blind Luck configuation into cfg/sourcemod/plugin.blindluck.
* Version 1.1.0
*     - No longer requires the spoofing of sv_cheats. This gets rid of the client messages.
*     - Added ConVar 'bl_hud_to_apply' to allow administrators to decide which parts of the HUD to hide.
*     - Event 'player_no_longer_it' is now unhooked when it is not needed. 
*     - Added minimum and maximum values to 'bl_blind_time'. The maximum time is 25 seconds with the minimum being 5 seconds.
*     - Now compiles without indentation warnings.
* Version 1.1.1
*     - Fixes error when restoring the HUD on some entities.
* Version 1.1.2
*     - Transferred to the new syntax.
* Version 1.2.0 (apples1949)
*     - 默认配置改为 bl_hide_until_dry = 0、bl_blind_time = 10、bl_hud_to_apply = 200（= 8|64|128，喷中后失明 10 秒）。
*     - 所有 ConVar 说明改为中文；不再使用 AutoExecConfig / OnConfigsExecuted，插件不生成也不执行任何 cfg 文件。
*     - 修复重复中弹时定时器叠加：旧定时器会提前解除新的失明，现在改为覆盖计时并重新计时。
*     - 修复潜藏的"永久失明"：运行中把 bl_hide_until_dry 由 0 改成 1 时 player_no_longer_it 未挂钩；
*       事件改为一次性全部挂钩、在回调内部按配置判断，结构上消除该问题。
*     - 修复配置变更 / 关闭插件 / 卸载插件 / 回合重开 / 玩家死亡时隐藏状态残留（HUD 永久隐藏）的问题。
*     - m_iHideHUD 改为按位叠加、按位清除，不再覆盖其它插件或引擎设置的隐藏位。
*     - 客户端状态数组改为 MAXPLAYERS+1，消除客户端索引越界隐患。
*     - bl_hud_to_apply 上限由 256 放宽到 4095，与 m_iHideHUD 的 12 bit 实际上限一致。
* Version 1.2.1 (apples1949)
*     - 新增"中途接管"处理：玩家接管一具正被胆汁覆盖的生还者身体时（bot_player_replace），补上这次失明。
*     - 身体控制权转移（player_bot_replace / bot_player_replace）时，胆汁状态与失明剩余时间随身体走，
*       HUD 隐藏位在旧身体上立即撤销，避免残留给之后接管这具身体的玩家。
*     - 胆汁状态对所有槽位（含 bot）记录：bot 被喷期间玩家加入并接管，也能正确失明。
*     - 断线时保留胆汁状态、清掉计时器与位记录，并在实体还在游戏里时先还原 HUD。
*     - 死亡 / 胆汁干掉 / 回合重开 / 换图时，同时清理 bot 身体的隐藏位与胆汁记录。
*/

#pragma semicolon 1
#pragma newdecls required

// Define constants
#define PLUGIN_VERSION    "1.2.1"
#define PLUGIN_NAME       "Blind Luck"
#define CVAR_FLAGS        FCVAR_NOTIFY
#define BLIND_TIME_MIN    5.0      // bl_blind_time 下限（秒）
#define BLIND_TIME_MAX    25.0     // bl_blind_time 上限（秒）
#define HUD_MASK_MAX      4095.0   // m_iHideHUD 为 12 bit 无符号，最大 4095
#define TEAM_SURVIVOR     2        // L4D2 队伍编号：1 = 旁观，2 = 生还者，3 = 感染

// Include necessary files
#include <sourcemod>
#include <sdktools>

// m_iHideHUD 隐藏位定义（Source 引擎 HIDEHUD_* 位；若编译环境已定义则直接复用，避免重复定义）
// m_iHideHUD 是 12 bit 无符号数，取值 0-4095；bl_hud_to_apply 就是这些位相加的组合。
#if !defined HIDEHUD_ALL
#define HIDEHUD_WEAPONSELECTION     (1 << 0)   // 1     隐藏弹药数 / 武器选择栏（L4D2 未实测）
#define HIDEHUD_FLASHLIGHT          (1 << 1)   // 2     隐藏手电筒（L4D2 未实测）
#define HIDEHUD_ALL                 (1 << 2)   // 4     隐藏整个 HUD（通用"全隐藏"位，L4D2 需进服实测）
#define HIDEHUD_HEALTH              (1 << 3)   // 8     隐藏生命 / 电池显示（默认 200 含此位；L4D2 可用：vi-l4d2 胆汁遮罩、l4d_fix_deathfall_cam 都在用）
#define HIDEHUD_PLAYERDEAD          (1 << 4)   // 16    本地玩家死亡时隐藏（L4D2 未实测）
#define HIDEHUD_NEEDSUIT            (1 << 5)   // 32    没有 HEV 防护服时隐藏（L4D2 没有防护服 → 无意义）
#define HIDEHUD_MISCSTATUS          (1 << 6)   // 64    隐藏杂项状态（拾取提示 / 死亡提示等；默认 200 含此位）
#define HIDEHUD_CHAT                (1 << 7)   // 128   隐藏通讯元素（聊天 / 语音图标；默认 200 含此位）
#define HIDEHUD_CROSSHAIR           (1 << 8)   // 256   隐藏准星（L4D2 可用：fortnite_emotes_extended 在用）
#define HIDEHUD_VEHICLE_CROSSHAIR   (1 << 9)   // 512   隐藏载具准星（L4D2 没有可驾驶载具 → 无意义）
#define HIDEHUD_INVEHICLE           (1 << 10)  // 1024  在载具内时隐藏（L4D2 没有可驾驶载具 → 无意义）
#define HIDEHUD_BONUS_PROGRESS      (1 << 11)  // 2048  奖励进度（l4d_fix_deathfall_cam 在 L4D2 里也在用）
#endif

// 常用 bl_hud_to_apply 取值（数值 = 需要隐藏的位相加）：
//   200   8|64|128 = 生命显示 + 杂项状态 + 聊天（本插件默认值；vi-l4d2 的 Bile Mask 也用这个值，已在 L4D2 实机验证）
//   456   200|256 = 上面三项再加上准星
//   4     HIDEHUD_ALL：通用"整个 HUD"位，L4D2 下效果需进服实测
//   64    只隐藏杂项状态（原版 1.1.2 的默认值）

// Create ConVar handles
ConVar blindluck_on, blind_time, hide_until_dry, hud_to_apply;
bool bPluginOn = false, bHideUntilDry = false;
float fBlindTime = 0.0;
int iHudToApply = 0;

// 每个槽位（一具身体）的状态
Handle g_hBlindTimer[MAXPLAYERS + 1];   // 失明计时器
int g_iHiddenBits[MAXPLAYERS + 1];      // 本插件实际加上去的隐藏位（恢复时只清这些位）
bool g_bIsIt[MAXPLAYERS + 1];           // 这具身体当前是否被胆汁覆盖（含 bot：bot 被喷后可能被玩家接管）
float g_flBlindEnd[MAXPLAYERS + 1];     // 本次失明的结束时刻（GetGameTime 基准，0 = 当前没有失明）

// Metadata for the mod
public Plugin myinfo =
{
	name = PLUGIN_NAME,
	author = "apples1949",
	description = "Hides the majority of a survivors HUD when he is vomitted on",
	version = PLUGIN_VERSION,
	url = "http://code.james.richardson.name"
}

public void OnPluginStart()
{
	// Create ConVars
	CreateConVar("bl_version", PLUGIN_VERSION, "Blind Luck 插件版本号。", CVAR_FLAGS|FCVAR_SPONLY|FCVAR_DONTRECORD);
	blindluck_on = CreateConVar("bl_plugin_on", "1", "总开关：1 = 玩家被胆汁喷中后隐藏其 HUD，0 = 关闭本插件效果。", CVAR_FLAGS, true, 0.0, true, 1.0);
	blind_time = CreateConVar("bl_blind_time", "10.0", "被胆汁喷中后隐藏 HUD 的秒数（仅在 bl_hide_until_dry = 0 时生效，范围 5-25）。", CVAR_FLAGS, true, BLIND_TIME_MIN, true, BLIND_TIME_MAX);
	hide_until_dry = CreateConVar("bl_hide_until_dry", "0", "恢复方式：1 = 一直隐藏到胆汁被吹干（时间不确定）；0 = 只隐藏 bl_blind_time 秒。", CVAR_FLAGS, true, 0.0, true, 1.0);
	hud_to_apply = CreateConVar("bl_hud_to_apply", "200", "要隐藏的 HUD 位掩码，多个位可相加（取值 0-4095）；默认 200 = 生命显示 + 杂项状态 + 聊天，各位含义见源码中的 HIDEHUD_* 注释。", CVAR_FLAGS, true, 0.0, true, HUD_MASK_MAX);

	blindluck_on.AddChangeHook(ConVarPluginOnChanged);
	blind_time.AddChangeHook(ConVarChanged);
	hide_until_dry.AddChangeHook(ConVarChanged);
	hud_to_apply.AddChangeHook(ConVarChanged);

	// 事件一次性全部挂钩，是否生效在回调内部按 bl_plugin_on / bl_hide_until_dry 判断。
	// 这样运行中切换配置不需要增删挂钩，避免"模式开了但事件没挂上导致 HUD 永久隐藏"。
	HookEvent("player_now_it", Event_PlayerWet);
	HookEvent("player_no_longer_it", Event_PlayerDry);
	HookEvent("player_death", Event_PlayerDeath);
	HookEvent("round_start", Event_RoundStart);
	HookEvent("bot_player_replace", Event_PlayerReplacedBot);   // 玩家接管了 bot
	HookEvent("player_bot_replace", Event_BotReplacedPlayer);   // bot 接管了玩家

	// 本插件不生成、也不执行任何 cfg 文件，因此不使用 AutoExecConfig / OnConfigsExecuted：
	// 默认值就是最终配置，需要按服改值就直接写进 server.cfg / sourcemod.cfg（cvar 变更钩子会即时生效）。
	// 先套用一次默认值，避免事件回调拿到空配置
	RefreshSettings();
}

// 读取 ConVar 到缓存
void RefreshSettings()
{
	fBlindTime = blind_time.FloatValue;
	iHudToApply = hud_to_apply.IntValue;
	bHideUntilDry = hide_until_dry.BoolValue;
	bPluginOn = blindluck_on.BoolValue;
}

// 开关变化：关闭插件时立刻把 HUD 还给所有玩家，避免隐藏状态残留到插件之外
void ConVarPluginOnChanged(ConVar cvar, const char[] OldValue, const char[] NewValue)
{
	bool bWasOn = bPluginOn;

	RefreshSettings();

	if (bWasOn && !bPluginOn)
	{
		RestoreAllHud();
	}
}

// 其它配置变化：先结束当前所有失明（清掉旧掩码/旧模式留下的状态），再套用新配置
void ConVarChanged(ConVar cvar, const char[] OldValue, const char[] NewValue)
{
	RestoreAllHud();
	RefreshSettings();
}

// 有人被胆汁喷中（Boomer 呕吐、Boomer 爆炸、胆汁瓶命中都会触发，插件不区分来源）
public Action Event_PlayerWet(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	if (client <= 0 || client > MaxClients)
	{
		return Plugin_Continue;
	}

	// 胆汁状态对所有槽位都记录（含 bot）：bot 被喷期间玩家加入并接管，要靠这条记录补上失明
	g_bIsIt[client] = true;

	// bot 没有 HUD，只有真人玩家才需要隐藏
	if (bPluginOn && IsValidRealClient(client))
	{
		StartBlind(client, bHideUntilDry ? 0.0 : fBlindTime);
	}

	return Plugin_Continue;
}

// 胆汁被吹干：只有"隐藏到胆汁干掉"模式才在这里恢复（按时间模式必须撑满 bl_blind_time）
public Action Event_PlayerDry(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	if (client <= 0 || client > MaxClients)
	{
		return Plugin_Continue;
	}

	g_bIsIt[client] = false;

	if (bPluginOn && bHideUntilDry)
	{
		RestoreHud(client);
	}

	return Plugin_Continue;
}

// 死亡：死亡会清掉胆汁状态，但不保证触发 player_no_longer_it，这里清记录并恢复一次
public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	if (client <= 0 || client > MaxClients)
	{
		return Plugin_Continue;
	}

	g_bIsIt[client] = false;
	RestoreHud(client);

	return Plugin_Continue;
}

// 回合重开（mp_restartgame、章节重开等）：全部重置，避免上一回合的状态残留
public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	RestoreAllHud();
	ClearAllItState();

	return Plugin_Continue;
}

// 玩家接管了 bot：这是"中途加入的玩家接管一具被胆汁喷中的生还者"的主路径
public Action Event_PlayerReplacedBot(Event event, const char[] name, bool dontBroadcast)
{
	int player = GetClientOfUserId(event.GetInt("player"));
	int bot = GetClientOfUserId(event.GetInt("bot"));

	// 身体从 bot 槽位转到玩家槽位：胆汁状态与失明剩余时间跟着走
	if (TransferBodyState(bot, player) && player > 0 && player <= MaxClients)
	{
		// 延迟一帧再确认：等引擎把身体切换做完再读队伍/实体状态（control_zombies 同款做法）
		RequestFrame(Frame_TakeOverCheck, GetClientUserId(player));
	}

	return Plugin_Continue;
}

// bot 接管了玩家（掉线 / 挂机 / 换队旁观）：身体交给 bot，状态保留，之后玩家再接管时可继续
public Action Event_BotReplacedPlayer(Event event, const char[] name, bool dontBroadcast)
{
	int player = GetClientOfUserId(event.GetInt("player"));
	int bot = GetClientOfUserId(event.GetInt("bot"));

	TransferBodyState(player, bot);

	return Plugin_Continue;
}

// 一帧后确认接管结果：这具身体还在被胆汁覆盖的话，接管者要补上这次失明
void Frame_TakeOverCheck(any userid)
{
	int client = GetClientOfUserId(userid);

	if (!bPluginOn || !IsValidRealClient(client) || !g_bIsIt[client] || GetClientTeam(client) != TEAM_SURVIVOR)
	{
		return;
	}

	// 胆汁是在 bot（或上一名玩家）手上喷的：能接上就按剩余时间，已经过期就按完整时长补
	float fSeconds = 0.0;
	if (!bHideUntilDry)
	{
		fSeconds = (g_flBlindEnd[client] > GetGameTime()) ? (g_flBlindEnd[client] - GetGameTime()) : fBlindTime;
	}

	// 这具身体上可能残留上一任主人留下的、属于本插件掩码的隐藏位（位记录可能在断线/换人时丢了），
	// 先把掩码内的位清干净再重新施加，避免"记录为 0 但 HUD 是隐藏的"这种无法恢复的残留。
	int iCurrent = GetEntProp(client, Prop_Send, "m_iHideHUD");
	int iStaleBits = iCurrent & iHudToApply;

	if (iStaleBits != 0)
	{
		SetEntProp(client, Prop_Send, "m_iHideHUD", iCurrent & ~iStaleBits);
	}

	g_iHiddenBits[client] = 0;

	StartBlind(client, fSeconds);
}

// 身体控制权转移：body = 失去控制权的一方，owner = 接管这具身体的一方。
// 胆汁状态与失明剩余时间随身体走；HUD 隐藏位在旧身体上就地撤销（旧身体随后由 bot 或新玩家使用）
// 返回值：是否真的发生了转移（调用方据此决定要不要做接管后的补判）
bool TransferBodyState(int body, int owner)
{
	if (body <= 0 || body > MaxClients || owner <= 0 || owner > MaxClients || body == owner)
	{
		return false;
	}

	bool bWasIt = g_bIsIt[body];
	float flBlindEnd = g_flBlindEnd[body];

	RestoreHud(body);

	g_bIsIt[body] = false;
	g_bIsIt[owner] = bWasIt;
	g_flBlindEnd[owner] = flBlindEnd;

	return true;
}

// 开始一次失明：叠加隐藏位；fSeconds > 0 表示按时间恢复，0 表示等胆汁干掉（由事件恢复）
void StartBlind(int client, float fSeconds)
{
	ApplyBlindHud(client);

	if (fSeconds > 0.0)
	{
		g_flBlindEnd[client] = GetGameTime() + fSeconds;
		// TIMER_FLAG_NO_MAPCHANGE：失明是当前地图的事，换图时直接销毁（新地图身体全部重建）
		g_hBlindTimer[client] = CreateTimer(fSeconds, Timer_RestoreHud, client, TIMER_FLAG_NO_MAPCHANGE);
	}
	else
	{
		g_flBlindEnd[client] = 0.0;
	}
}

// 施加失明：只叠加"当前没有被隐藏的位"，因此不会覆盖其它插件或引擎设置的隐藏位
void ApplyBlindHud(int client)
{
	if (iHudToApply == 0)
	{
		return;
	}

	// 重复中弹：取消旧计时器并重新计时，否则旧计时器会提前解除这一次的失明
	KillBlindTimer(client);

	int iCurrent = GetEntProp(client, Prop_Send, "m_iHideHUD");
	int iAddBits = iHudToApply & ~iCurrent;

	if (iAddBits != 0)
	{
		SetEntProp(client, Prop_Send, "m_iHideHUD", iCurrent | iAddBits);
	}

	// 累积记录本插件加的位（再次中弹时不能把上一次的记录冲掉）
	g_iHiddenBits[client] |= iAddBits;
}

// 恢复 HUD：只清除本插件加的位，其它插件设置的隐藏位保持不动
// bot 的身体同样要清干净：它之后可能被中途加入的玩家接管
void RestoreHud(int client)
{
	KillBlindTimer(client);
	g_flBlindEnd[client] = 0.0;

	int iOwnBits = g_iHiddenBits[client];
	if (iOwnBits == 0)
	{
		return;
	}

	g_iHiddenBits[client] = 0;

	if (client > 0 && client <= MaxClients && IsClientInGame(client))
	{
		int iCurrent = GetEntProp(client, Prop_Send, "m_iHideHUD");
		SetEntProp(client, Prop_Send, "m_iHideHUD", iCurrent & ~iOwnBits);
	}
}

// 取消某个槽位的失明计时器
void KillBlindTimer(int client)
{
	if (g_hBlindTimer[client] != null)
	{
		KillTimer(g_hBlindTimer[client]);
		g_hBlindTimer[client] = null;
	}
}

// 恢复所有玩家的 HUD（改配置 / 关插件 / 卸载插件 / 回合重开时调用）
void RestoreAllHud()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		RestoreHud(i);
	}
}

// 清空所有胆汁记录
void ClearAllItState()
{
	for (int i = 0; i <= MaxClients; i++)
	{
		g_bIsIt[i] = false;
		g_flBlindEnd[i] = 0.0;
	}
}

// 一次性计时器到期：恢复正常 HUD
public Action Timer_RestoreHud(Handle timer, any client)
{
	// 定时器已经触发，句柄由 SourceMod 回收，这里只清引用，避免 RestoreHud 里重复 KillTimer
	g_hBlindTimer[client] = null;

	RestoreHud(client);

	return Plugin_Stop;
}

public void OnClientDisconnect(int client)
{
	// 先在实体还在游戏里时还原 HUD，避免隐藏位残留给之后接管这具身体的玩家
	float flBlindEnd = g_flBlindEnd[client];

	RestoreHud(client);

	// 计时器与位记录不能留给下一个占用该槽位的玩家；
	// 但胆汁状态（g_bIsIt / g_flBlindEnd）要保留：这具身体会由 bot 接着开，
	// 中途加入的玩家接管时（bot_player_replace）再判断要不要继续失明。
	KillBlindTimer(client);
	g_iHiddenBits[client] = 0;
	g_flBlindEnd[client] = flBlindEnd;
}

public void OnMapEnd()
{
	// 换图后客户端与身体全部重建：清空所有记录。
	// 失明计时器带 TIMER_FLAG_NO_MAPCHANGE，SourceMod 会在换图时销毁它们，这里只需丢掉引用。
	ClearAllItState();

	for (int i = 0; i <= MaxClients; i++)
	{
		g_hBlindTimer[i] = null;
		g_iHiddenBits[i] = 0;
	}
}

public void OnPluginEnd()
{
	// 卸载/重载插件前把 HUD 还给所有玩家，避免失明状态残留
	RestoreAllHud();
}

bool IsValidRealClient(int client)
{
	return client > 0 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client);
}
