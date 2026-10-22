/**
 * ============================================================================
 *  l4d2_extendedsight.sp  -  击杀坦克 / Witch 后生还者获得「扩展视野」
 * ============================================================================
 *  原插件：[L4D2] Extended Survivor Sight 1.2.2 by Jack'lul
 *          https://forums.alliedmods.net/showthread.php?p=2085325
 *
 *  本服改造（applemod12v12）：
 *    1) 去掉 phrases 翻译文件与 LoadTranslations —— 提示文案改成单条中文硬编码
 *       （不再需要 translations/l4d2_extendedsight.phrases.txt，删掉也不报错）
 *    2) 默认值改为：mode=3（击杀坦克和 Witch 都触发）、duration=5（秒）
 *    3) 「重新发光」：每次触发都把上一次的计时全部清掉，从满色重新开始 5 秒
 *       （旧版是「已在发光中则延长时长」，现在是覆盖 / 重置）
 *    4) 不生成插件 cfg（去掉 AutoExecConfig）—— 参数写在 applemod12v12.cfg 里
 *    其余设置（发光颜色、褪色模式、褪色间隔、模式黑白名单、通知方式、管理命令）保持不变。
 *
 *  ConVar：
 *    l4d2_extendedsight_mode              3    0=关闭 1=坦克 2=witch 3=坦克+witch 4=一直开启
 *    l4d2_extendedsight_duration          5    发光持续秒数
 *    l4d2_extendedsight_notify            1    0=不提示 1=屏幕中央提示 2=聊天框
 *    l4d2_extendedsight_glowcolor         "255 75 75"  发光颜色 RGB
 *    l4d2_extendedsight_glowmode          1    0=持续发光 1=逐渐褪色（脉冲）
 *    l4d2_extendedsight_glowfadeinterval  3    褪色节奏间隔（秒）
 *    l4d2_extendedsight_modes_on          ""   白名单，空=全部
 *    l4d2_extendedsight_modes_off         ...  黑名单
 * ============================================================================
 */

#define PLUGIN_VERSION "2.0.0"

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define TEAM_SURVIVOR   2
#define TEAM_INFECTED   3

enum
{
	MODE_OFF        = 0,
	MODE_TANK       = 1,
	MODE_WITCH      = 2,
	MODE_BOTH       = 3,
	MODE_ALWAYS     = 4
}

ConVar g_cvMode;
ConVar g_cvDuration;
ConVar g_cvNotify;
ConVar g_cvGlowColor;
ConVar g_cvGlowMode;
ConVar g_cvGlowFadeInterval;
ConVar g_cvModesOn;
ConVar g_cvModesOff;

Handle g_hGameMode;

Handle g_hRemoveTimer;      // 到点结束发光
Handle g_hGlowTimer;        // 发光 / 褪色循环

int g_iGlowColor;
int g_iFade1;
int g_iFade2;
int g_iFade3;
int g_iFade4;
int g_iFade5;
int g_iPropGhost;

bool g_bActive;             // 正在发光
bool g_bForever;            // 永久发光（mode 4 或管理命令）

// 「重新发光」的代数：每次 RestartGlow / 结束都 +1。
// 褪色脉冲里的 7 个一次性小 timer 会把「创建时的代数」编码进 data，
// 触发时代数不匹配就丢弃 —— 否则上一次的淡出步骤会把新一轮一路压暗甚至熄灭。
int g_iGlowGen;

char g_sGameName[64];

public Plugin myinfo =
{
	name        = "[L4D2] Extended Survivor Sight",
	author      = "apples1949",
	description = "击杀坦克 / Witch 后生还者可见特感轮廓（基于 Jack'lul 1.2.2 改造：中文硬编码、每次击杀重新发光）",
	version     = PLUGIN_VERSION,
	url         = "https://forums.alliedmods.net/showthread.php?p=2085325"
};

public void OnPluginStart()
{
	GetGameFolderName(g_sGameName, sizeof(g_sGameName));

	if (!StrEqual(g_sGameName, "left4dead2", false))
	{
		SetFailState("Plugin only supports Left 4 Dead 2!");
		return;
	}

	CreateConVar("l4d2_extendedsight_version", PLUGIN_VERSION,
		"Extended Survivor Sight Version",
		FCVAR_NONE|FCVAR_NOTIFY|FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_DONTRECORD);

	g_cvMode = CreateConVar("l4d2_extendedsight_mode", "3",
		"什么时候触发扩展视野? 0=关闭 1=击杀坦克 2=击杀witch 3=击杀坦克和witch 4=一直开启",
		FCVAR_NONE|FCVAR_NOTIFY, true, 0.0, true, 4.0);

	g_cvNotify = CreateConVar("l4d2_extendedsight_notify", "1",
		"如何通知扩展视野? 0=关闭 1=屏幕中央提示 2=聊天框",
		FCVAR_NONE|FCVAR_NOTIFY, true, 0.0, true, 2.0);

	g_cvDuration = CreateConVar("l4d2_extendedsight_duration", "5",
		"扩展视野持续时长（秒），默认 5",
		FCVAR_NONE|FCVAR_NOTIFY, true, 1.0, true, 300.0);

	g_cvGlowColor = CreateConVar("l4d2_extendedsight_glowcolor", "255 75 75",
		"扩展视野颜色，RGB 值（三个 0-255 的整数，空格分开）",
		FCVAR_NONE|FCVAR_NOTIFY);

	g_cvGlowMode = CreateConVar("l4d2_extendedsight_glowmode", "1",
		"扩展视野发光模式：0=持续发光 1=逐渐褪色（脉冲）",
		FCVAR_NONE|FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvGlowFadeInterval = CreateConVar("l4d2_extendedsight_glowfadeinterval", "3",
		"扩展视野褪色之间的间隔（秒）",
		FCVAR_NONE|FCVAR_NOTIFY, true, 1.5, true, 10.0);

	g_cvModesOn = CreateConVar("l4d2_extendedsight_modes_on", "",
		"这些游戏模式将启用插件。空=全部",
		FCVAR_NONE|FCVAR_NOTIFY);

	g_cvModesOff = CreateConVar("l4d2_extendedsight_modes_off",
		"versus,teamversus,scavenge,teamscavenge,mutation12,teamrealismversus,mutation11,mutation13,mutation15,mutation18,mutation19,community3,community6,l4d1vs",
		"在这些游戏模式下，插件将被禁用。空=无",
		FCVAR_NONE|FCVAR_NOTIFY);

	// 本服惯例：参数写在模式 cfg 里，不自动生成 cfg/sourcemod/*.cfg
	//AutoExecConfig(true, "l4d2_extendedsight");

	RegAdminCmd("sm_extendedsight", Command_ExtendedSight, ADMFLAG_BAN,
		"扩展视野开关：sm_extendedsight <on|off>");

	g_iPropGhost = FindSendPropInfo("CTerrorPlayer", "m_isGhost");

	// 事件常驻挂钩，是否生效在回调里按 cvar + 模式黑白名单逐次判定
	HookEvent("tank_killed", Event_TankKilled);
	HookEvent("witch_killed", Event_WitchKilled);
	HookEvent("round_start", Event_RoundStart, EventHookMode_Post);

	// 颜色 / 时长热改：重新解析颜色；发光中则按新参数重新开始
	g_cvGlowColor.AddChangeHook(OnGlowColorChanged);
	g_cvMode.AddChangeHook(OnModeChanged);

	g_bActive = false;
	g_bForever = false;
}

public void OnPluginEnd()
{
	KillTimers();
	DisableGlow();
}

public void OnMapStart()
{
	if (g_cvMode.IntValue == MODE_OFF)
	{
		return;
	}

	g_hGameMode = FindConVar("mp_gamemode");

	KillTimers();
	DisableGlow();

	g_bActive = false;
	g_bForever = false;

	if (g_cvMode.IntValue == MODE_ALWAYS)
	{
		AddForeverSight();
	}
}

public void OnConfigsExecuted()
{
	// 模式 4（一直开启）：每次配置生效后重新点亮
	if (g_cvMode.IntValue == MODE_ALWAYS)
	{
		AddForeverSight();
	}
}

public void OnMapEnd()
{
	KillTimers();
	DisableGlow();

	g_bActive = false;
	g_bForever = false;
}

// ===========================================================================
//  事件挂钩
//
//  事件在 OnPluginStart 里一次性挂上，不在 OnConfigsExecuted 里做「按模式挂/摘」：
//  插件的 OnConfigsExecuted 与 confogl_setcvars 的先后顺序不由本插件控制，
//  一旦顺序反过来就会「模式判定为不允许 -> 永远不挂钩 -> 插件像没装一样」。
//  因此挂钩常驻，真正是否触发在回调里按 cvar + 模式黑白名单逐次判定。
// ===========================================================================

public void OnModeChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (g_cvMode.IntValue == MODE_ALWAYS)
	{
		AddForeverSight();
	}
	else if (g_cvMode.IntValue == MODE_OFF)
	{
		KillTimers();
		DisableGlow();

		g_bActive = false;
		g_bForever = false;
	}
}

public void OnGlowColorChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	SetGlowColor();

	if (g_bActive)
	{
		// 重新发光：按新颜色重新开始一轮
		RestartGlow();
	}
}

// ===========================================================================
//  事件
// ===========================================================================

/**
 * 本次击杀是否该触发扩展视野。
 * @param iModeFlag  MODE_TANK 或 MODE_WITCH
 */
bool CanTrigger(int iModeFlag)
{
	int mode = g_cvMode.IntValue;

	if (mode == MODE_OFF || mode == MODE_ALWAYS)
	{
		return false;
	}

	if (mode != MODE_BOTH && mode != iModeFlag)
	{
		return false;
	}

	return IsAllowedGameMode();
}

public void Event_TankKilled(Event event, const char[] name, bool dontBroadcast)
{
	if (CanTrigger(MODE_TANK))
	{
		RestartGlow();
	}
}

public void Event_WitchKilled(Event event, const char[] name, bool dontBroadcast)
{
	if (CanTrigger(MODE_WITCH))
	{
		RestartGlow();
	}
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	if (g_cvMode.IntValue == MODE_ALWAYS)
	{
		DisableGlow();
		AddForeverSight();

		return;
	}

	// 回合开始：静默清掉上一回合可能残留的发光，不播提示（避免每回合刷一句"已结束"）
	if (g_bActive)
	{
		KillTimers();
		DisableGlow();

		g_bActive = false;
		g_bForever = false;
	}
}

// ===========================================================================
//  管理命令
// ===========================================================================

public Action Command_ExtendedSight(int client, int args)
{
	char arg[8];

	if (args < 1)
	{
		ReplyToCommand(client, "用法：sm_extendedsight <on|off>");
		return Plugin_Handled;
	}

	GetCmdArg(1, arg, sizeof(arg));

	if (StrEqual(arg, "on", false))
	{
		if (g_bActive && g_bForever)
		{
			ReplyToCommand(client, "扩展视野已经是永久开启状态");
		}
		else
		{
			AddForeverSight();
			ReplyToCommand(client, "扩展视野已永久开启");
		}
	}
	else if (StrEqual(arg, "off", false))
	{
		if (!g_bActive)
		{
			ReplyToCommand(client, "扩展视野当前未开启");
		}
		else
		{
			RemoveSight();
			ReplyToCommand(client, "扩展视野已关闭");
		}
	}
	else
	{
		ReplyToCommand(client, "用法：sm_extendedsight <on|off>");
	}

	return Plugin_Handled;
}

// ===========================================================================
//  发光状态
// ===========================================================================

/**
 * 永久发光（mode 4 / 管理命令）：不设定时器，直到回合结束或手动关闭。
 */
void AddForeverSight()
{
	KillTimers();

	// 换一代：作废上一轮遗留的淡出步骤
	g_iGlowGen++;

	g_bActive = true;
	g_bForever = true;

	if (g_cvGlowMode.IntValue == 1)
	{
		ApplyGlow(g_iGlowColor);

		g_hGlowTimer = CreateTimer(g_cvGlowFadeInterval.FloatValue, Timer_GlowFade, 0,
			TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
	}
	else
	{
		ApplyGlow(g_iGlowColor);

		g_hGlowTimer = CreateTimer(0.5, Timer_KeepGlow, 0,
			TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
	}
}

/**
 * 重新发光：清掉上一轮的计时，从满色重新开始「duration」秒。
 * —— 这正是「每次击杀都重新发光」的实现：后一次击杀直接覆盖前一次的剩余时间。
 */
void RestartGlow()
{
	KillTimers();

	float fDuration = g_cvDuration.FloatValue;

	if (fDuration <= 0.0)
	{
		return;
	}

	// 换一代：上一次击杀遗留的淡出步骤全部作废（这是「重新发光」的关键）
	g_iGlowGen++;

	SetGlowColor();

	g_bActive = true;
	g_bForever = false;

	// 立刻上满色，避免等待第一个褪色节拍
	ApplyGlow(g_iGlowColor);

	if (g_cvGlowMode.IntValue == 1)
	{
		g_hGlowTimer = CreateTimer(g_cvGlowFadeInterval.FloatValue, Timer_GlowFade, 0,
			TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
	}
	else
	{
		g_hGlowTimer = CreateTimer(0.5, Timer_KeepGlow, 0,
			TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
	}

	g_hRemoveTimer = CreateTimer(fDuration, Timer_RemoveSight, 0,
		TIMER_FLAG_NO_MAPCHANGE);

	if (g_cvNotify.IntValue != 0)
	{
		NotifyActivated();
	}
}

public Action Timer_RemoveSight(Handle timer)
{
	g_hRemoveTimer = null;

	RemoveSight();

	return Plugin_Stop;
}

/**
 * 褪色模式：每个间隔重复一次「满色 -> 逐级变暗 -> 熄灭」的脉冲。
 *
 * 7 个一次性小 timer 把「本轮代数」编码进 data（高 7 位）：
 *   同一时刻只会有一轮脉冲的代数与 g_iGlowGen 相同，上一轮残留的淡出步骤
 *   触发时会被 Timer_SetGlow 丢弃，不会把「重新发光」压暗 / 熄灭。
 */
public Action Timer_GlowFade(Handle timer)
{
	if (!g_bActive)
	{
		g_hGlowTimer = null;
		return Plugin_Stop;
	}

	CreateTimer(0.1, Timer_SetGlow, PackGlowData(g_iGlowColor), TIMER_FLAG_NO_MAPCHANGE);
	CreateTimer(0.5, Timer_SetGlow, PackGlowData(g_iFade1), TIMER_FLAG_NO_MAPCHANGE);
	CreateTimer(0.7, Timer_SetGlow, PackGlowData(g_iFade2), TIMER_FLAG_NO_MAPCHANGE);
	CreateTimer(0.9, Timer_SetGlow, PackGlowData(g_iFade3), TIMER_FLAG_NO_MAPCHANGE);
	CreateTimer(1.1, Timer_SetGlow, PackGlowData(g_iFade4), TIMER_FLAG_NO_MAPCHANGE);
	CreateTimer(1.3, Timer_SetGlow, PackGlowData(g_iFade5), TIMER_FLAG_NO_MAPCHANGE);
	CreateTimer(1.4, Timer_SetGlow, PackGlowData(0), TIMER_FLAG_NO_MAPCHANGE);

	return Plugin_Continue;
}

/**
 * 把「代数 + 颜色」打包成一个 any。
 * 颜色最大 0xFFFFFF（24 位），代数放高 7 位。
 */
int PackGlowData(int iColor)
{
	return ((g_iGlowGen & 0x7F) << 25) | (iColor & 0x1FFFFFF);
}

/**
 * 持续发光模式：定时重刷满色，避免被其它插件 / 状态覆盖掉。
 */
public Action Timer_KeepGlow(Handle timer)
{
	if (!g_bActive)
	{
		g_hGlowTimer = null;
		return Plugin_Stop;
	}

	ApplyGlow(g_iGlowColor);

	return Plugin_Continue;
}

public Action Timer_SetGlow(Handle timer, any iData)
{
	int iGen = (iData >> 25) & 0x7F;
	int iColor = iData & 0x1FFFFFF;

	// 上一轮脉冲遗留的步骤：直接丢弃
	if (iGen != (g_iGlowGen & 0x7F))
	{
		return Plugin_Stop;
	}

	if (!g_bActive)
	{
		return Plugin_Stop;
	}

	if (iColor == 0)
	{
		DisableGlow();
	}
	else
	{
		ApplyGlow(iColor);
	}

	return Plugin_Stop;
}

void RemoveSight()
{
	KillTimers();

	// 换一代：上一轮还没触发的淡出步骤全部作废
	g_iGlowGen++;

	g_bActive = false;
	g_bForever = false;

	DisableGlow();

	if (g_cvNotify.IntValue != 0)
	{
		NotifyDeactivated();
	}
}

void KillTimers()
{
	delete g_hRemoveTimer;
	g_hRemoveTimer = null;

	delete g_hGlowTimer;
	g_hGlowTimer = null;
}

// ===========================================================================
//  轮廓发光
// ===========================================================================

void ApplyGlow(int iColor)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
		{
			continue;
		}

		// 只给「活着的、非幽灵状态」的特感上轮廓：生还者才看得见特感
		if (GetClientTeam(i) == TEAM_INFECTED
			&& IsPlayerAlive(i)
			&& g_bActive
			&& iColor != 0
			&& GetEntData(i, g_iPropGhost, 1) != 1)
		{
			SetEntProp(i, Prop_Send, "m_iGlowType", 3);
			SetEntProp(i, Prop_Send, "m_glowColorOverride", iColor);
		}
		else
		{
			SetEntProp(i, Prop_Send, "m_iGlowType", 0);
			SetEntProp(i, Prop_Send, "m_glowColorOverride", 0);
		}
	}
}

void DisableGlow()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
		{
			continue;
		}

		SetEntProp(i, Prop_Send, "m_iGlowType", 0);
		SetEntProp(i, Prop_Send, "m_glowColorOverride", 0);
	}
}

// ===========================================================================
//  提示（单条中文，硬编码）
// ===========================================================================

void NotifyActivated()
{
	char sMsg[128];

	FormatEx(sMsg, sizeof(sMsg), "扩展视野已激活：%d 秒内可看见特感轮廓",
		g_cvDuration.IntValue);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR)
		{
			continue;
		}

		if (g_cvNotify.IntValue == 1)
		{
			PrintHintText(i, "%s", sMsg);
		}
		else
		{
			PrintToChat(i, "%s", sMsg);
		}
	}
}

void NotifyDeactivated()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR)
		{
			continue;
		}

		if (g_cvNotify.IntValue == 1)
		{
			PrintHintText(i, "扩展视野已结束");
		}
		else
		{
			PrintToChat(i, "扩展视野已结束");
		}
	}
}

// ===========================================================================
//  颜色 / 模式判定
// ===========================================================================

void SetGlowColor()
{
	char sValue[64];
	char sParts[3][8];

	g_cvGlowColor.GetString(sValue, sizeof(sValue));
	ExplodeString(sValue, " ", sParts, 3, 8);

	int iR = StringToInt(sParts[0]);
	int iG = StringToInt(sParts[1]);
	int iB = StringToInt(sParts[2]);

	g_iGlowColor = iR + 256 * iG + 65536 * iB;

	g_iFade1 = RoundFloat(iR / 1.5) + 256 * RoundFloat(iG / 1.5) + 65536 * RoundFloat(iB / 1.5);
	g_iFade2 = RoundFloat(iR / 2.0) + 256 * RoundFloat(iG / 2.0) + 65536 * RoundFloat(iB / 2.0);
	g_iFade3 = RoundFloat(iR / 2.5) + 256 * RoundFloat(iG / 2.5) + 65536 * RoundFloat(iB / 2.5);
	g_iFade4 = RoundFloat(iR / 3.0) + 256 * RoundFloat(iG / 3.0) + 65536 * RoundFloat(iB / 3.0);
	g_iFade5 = RoundFloat(iR / 3.5) + 256 * RoundFloat(iG / 3.5) + 65536 * RoundFloat(iB / 3.5);
}

// credits: 模式黑白名单逻辑来自 Silvers
bool IsAllowedGameMode()
{
	if (g_hGameMode == null)
	{
		g_hGameMode = FindConVar("mp_gamemode");
	}

	if (g_hGameMode == null)
	{
		return false;
	}

	char sGameModes[256];
	char sGameMode[256];

	g_cvModesOn.GetString(sGameModes, sizeof(sGameModes));

	if (strcmp(sGameModes, "") != 0)
	{
		FormatEx(sGameMode, sizeof(sGameMode), ",%s,", sGameModes);

		char sMode[64];
		GetConVarString(g_hGameMode, sMode, sizeof(sMode));
		FormatEx(sMode, sizeof(sMode), ",%s,", sMode);

		if (StrContains(sGameMode, sMode, false) == -1)
		{
			return false;
		}
	}

	g_cvModesOff.GetString(sGameModes, sizeof(sGameModes));

	if (strcmp(sGameModes, "") != 0)
	{
		FormatEx(sGameMode, sizeof(sGameMode), ",%s,", sGameModes);

		char sMode[64];
		GetConVarString(g_hGameMode, sMode, sizeof(sMode));
		FormatEx(sMode, sizeof(sMode), ",%s,", sMode);

		if (StrContains(sGameMode, sMode, false) != -1)
		{
			return false;
		}
	}

	return true;
}
