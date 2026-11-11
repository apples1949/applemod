#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <builtinvotes>
#include <left4dhooks>
#include <colors>
#define L4D2UTIL_STOCKS_ONLY 1
#include <l4d2util>
#undef REQUIRE_PLUGIN
#include <readyup>
#include <pause>
#include <l4d2_boss_percents>
#include <l4d2_hybrid_scoremod>
#include <l4d2_scoremod>
#include <l4d2_health_temp_bonus>
#include <l4d_tank_control_eq>
#include <lerpmonitor>
#include <Apex>
#include <witch_and_tankifier>

#define PLUGIN_VERSION "3.9.3"

public Plugin myinfo =
{
	name = "Hyper-V HUD 管理器",
	author = "Visor, Forgetest",
	description = "为旁观者提供不同的HUD",
	version = PLUGIN_VERSION,
	url = "https://github.com/Target5150/MoYu_Server_Stupid_Plugins"
};

// ======================================================================
//  Macros
// ======================================================================
#define SPECHUD_DRAW_INTERVAL 1.0

// ---- 多人配置（12v12 等 survivor_limit >= 12）下的面板精简 ----
// 聊天面板(radio panel)整块只有 511 字节，多人局要同时列出 12 名生还者 + 12 名感染者。
// 原版每行 "42ms | Nick: 99HP# [Chrome 8/72]" 光延迟和武器就占掉一大半预算，
// 结果排在后面的感染者列表被引擎静默截断（玩家看不到）。这里：
//   1) 按面板剩余字节给每行名字定预算，超出用 '~' 收尾（同 readyup 主面板
//      panel.inc 的 RU_CopyPanelText / doorlock.inc 的 DL_LoadingPanel 做法）；
//   2) 砍掉延迟、武器这类非关键列，特感职业名缩成 1 个汉字；
//   3) 血量 / 状态（倒/挂边/死亡/幽灵/冷却计时）全部保留。
#define MULTIPLAYER_SURVIVOR_LIMIT	12	// 与 l4d2_scripted_hud 的「多人配置」门槛一致
#define PANEL_TEXT_LIMIT			510	// 511 字节面板，留 1 字节给结束符
#define MULTI_NAME_MIN				6	// 名字最少保留 6 字节（约 2 个汉字）
#define MULTI_NAME_MAX				24	// 名字最多 24 字节（约 8 个汉字）
#define MULTI_ROW_OVERHEAD			12	// 每行除名字外的固定开销（空格/血量/状态/换行）
#define MULTI_FIXED_RESERVE			150	// 非玩家列表的固定行（头部/两队标题/坦克或配置行）

// ======================================================================
//  Plugin Vars
// ======================================================================
int g_Gamemode;

//int storedClass[MAXPLAYERS+1];

// Game Var
ConVar survivor_limit, versus_boss_buffer, sv_maxplayers, tank_burn_duration;
int iSurvivorLimit, iMaxPlayers;
float fVersusBossBuffer, fTankBurnDuration;

// Plugin Cvar
ConVar l4d_tank_percent, l4d_witch_percent, hServerNamer, l4d_ready_cfg_name;

// Plugin Var
char sReadyCfgName[64], sHostname[64];
bool bRoundLive;

// 多人配置（survivor_limit >= MULTIPLAYER_SURVIVOR_LIMIT，如 12v12）：
// bMultiPlayer 控制面板精简，g_iMultiNameBudget 是当前每行名字可用的字节数（0 = 不缩名）
bool bMultiPlayer;
int g_iMultiNameBudget = 0;

// Boss Spawn Scheme
StringMap hFirstTankSpawningScheme, hSecondTankSpawningScheme;		// eq_finale_tanks (Zonemod, Acemod, etc.)
StringMap hFinaleExceptionMaps;										// finale_tank_blocker (Promod and older?)
StringMap hCustomTankScriptMaps;									// Handled by this plugin

// Flow Bosses
int iTankCount, iWitchCount;
int iTankFlow, iWitchFlow;
bool bRoundHasFlowTank, bRoundHasFlowWitch, bFlowTankActive, bCustomBossSys;

// Score & Scoremod
//int iFirstHalfScore;
bool bScoremod, bHybridScoremod, bNextScoremod;
int iMaxDistance;

// l4d2_scripted_hud 在场时, 奖励分(含路程分)由屏幕上的 scripted HUD 显示, 本面板整块不画;
// 它不在场时才由本面板显示完整奖励分.
bool bScriptedHud;

// Tank Control EQ
bool bTankSelection;

// Witch and Tankifier
bool bTankifier;
bool bStaticTank, bStaticWitch;

bool bApex;
bool bApexPred; // Apex 是否提供 Apex_IsPredEnabled(旧版 Apex.smx 没有, 不能直接调, 否则刷 native 未找到的报错)

int g_iTankPunch, g_iTankRock, g_iTankHittable, g_iTankDamage;

// Hud Toggle & Hint Message
bool bSpecHudActive[MAXPLAYERS+1], bTankHudActive[MAXPLAYERS+1];
bool bSpecHudHintShown[MAXPLAYERS+1], bTankHudHintShown[MAXPLAYERS+1];
// 本回合坦克事件（刷出 / 接管）已经把 tankhud 强制关掉了：只用于"掉线把槽位重置回开"那一处，
// 见 Event_PlayerTeam / Native_TankHudDisable。每回合开始清掉。
bool g_bTankHudForceOff = false;

// Tank real-time alive tracking
float g_fTankAliveTimestamp = 0.0;	// game time when that tank became alive
bool g_bTankTimerInitialized = false;	// whether the alive-timer has been started for the current tank

/**********************************************************************************************/

// ======================================================================
//  Plugin Load：对外接口
// ======================================================================
// 坦克HUD（tankhud）是本插件画的那块 Panel。l4d_superversus 的 sihud 需要
// "坦克刷出 / 被接管时关掉所有玩家的 tankhud"，走下面这个 native 通知本插件：
//   client = 0 → 所有玩家；client > 0 → 指定玩家。
// 只动 bTankHudActive（玩家自己的 !tankhud 开关），完全不碰旁观面板 bSpecHudActive。
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	RegPluginLibrary("spechud_appledmod");
	CreateNative("SpecHud_TankHudDisable", Native_TankHudDisable);
	return APLRes_Success;
}

// ======================================================================
//  Plugin Start
// ======================================================================
public void OnPluginStart()
{
	(	survivor_limit			= FindConVar("survivor_limit")			).AddChangeHook(GameConVarChanged);
	(	versus_boss_buffer		= FindConVar("versus_boss_buffer")		).AddChangeHook(GameConVarChanged);
	(	sv_maxplayers			= FindConVar("sv_maxplayers")			).AddChangeHook(GameConVarChanged);
	(	tank_burn_duration		= FindConVar("tank_burn_duration")		).AddChangeHook(GameConVarChanged);

	GetGameCvars();
	
	FillBossPercents();
	FillServerNamer();
	FillReadyConfig();
	
	InitTankSpawnSchemeTrie();
	
	RegConsoleCmd("sm_spechud", ToggleSpecHudCmd);
	RegConsoleCmd("sm_tankhud", ToggleTankHudCmd);
	
	HookEvent("round_start",		Event_RoundStart,		EventHookMode_PostNoCopy);
	HookEvent("round_end",			Event_RoundEnd,			EventHookMode_PostNoCopy);
	HookEvent("player_death",		Event_PlayerDeath,		EventHookMode_Post);
	HookEvent("witch_killed",		Event_WitchDeath,		EventHookMode_PostNoCopy);
	HookEvent("player_team",		Event_PlayerTeam,		EventHookMode_Post);
	HookEvent("player_hurt",		Event_PlayerHurt,		EventHookMode_Post);
	HookEvent("player_incapacitated_start",	Event_PlayerIncapStart,	EventHookMode_Post);
	
	for (int i = 1; i <= MaxClients; ++i)
	{
		bSpecHudActive[i] = false;
		bSpecHudHintShown[i] = false;
		bTankHudActive[i] = true;
		bTankHudHintShown[i] = false;
	}
	
	CreateTimer(SPECHUD_DRAW_INTERVAL, HudDrawTimer, _, TIMER_REPEAT);
}

/**********************************************************************************************/

// ======================================================================
//  ConVar Maintenance
// ======================================================================
void GetGameCvars()
{
	iSurvivorLimit		= survivor_limit.IntValue;
	fVersusBossBuffer	= versus_boss_buffer.FloatValue;
	iMaxPlayers			= sv_maxplayers.IntValue;
	fTankBurnDuration	= tank_burn_duration.FloatValue;

	// 多人配置（12v12 等）判据用游戏自己的 survivor_limit: 12v12 配置是 12, 原版/4v4 是 4。
	// 不用 l4d_superversus 的 l4d_survivor_limit —— 它默认就是 12, 插件卸载后值还留着,
	// 会把 4v4 误判成多人局（与 l4d2_scripted_hud 的 IsMultiplayerMode() 口径一致）。
	bMultiPlayer = (iSurvivorLimit >= MULTIPLAYER_SURVIVOR_LIMIT);
}

void GetCurrentGameMode()
{
	g_Gamemode = L4D_GetGameModeType();
}

// ======================================================================
//  Dependency Maintenance
// ======================================================================
void FillBossPercents()
{
	l4d_tank_percent	= FindConVar("l4d_tank_percent");
	l4d_witch_percent	= FindConVar("l4d_witch_percent");
}

void FillServerNamer()
{
	ConVar convar = null;
	if ((convar = FindConVar("l4d_ready_server_cvar")) != null)
	{
		char buffer[64];
		convar.GetString(buffer, sizeof(buffer));
		convar = FindConVar(buffer);
	}
	
	if (convar == null)
	{
		convar = FindConVar("hostname");
	}
	
	if (hServerNamer == null)
	{
		hServerNamer = convar;
		hServerNamer.AddChangeHook(ServerCvarChanged);
	}
	else if (hServerNamer != convar)
	{
		hServerNamer.RemoveChangeHook(ServerCvarChanged);
		hServerNamer = convar;
		hServerNamer.AddChangeHook(ServerCvarChanged);
	}
	
	hServerNamer.GetString(sHostname, sizeof(sHostname));
}

void FillReadyConfig()
{
	if (l4d_ready_cfg_name != null || (l4d_ready_cfg_name = FindConVar("l4d_ready_cfg_name")) != null)
		l4d_ready_cfg_name.GetString(sReadyCfgName, sizeof(sReadyCfgName));
}

void FindScoreMod()
{
	bScoremod = LibraryExists("l4d2_scoremod");
	bHybridScoremod = LibraryExists("l4d2_hybrid_scoremod") || LibraryExists("l4d2_hybrid_scoremod_zone");
	bNextScoremod = LibraryExists("l4d2_health_temp_bonus");
	bScriptedHud = LibraryExists("l4d2_scripted_hud");
}

void FindTankSelection()
{
	bTankSelection = (GetFeatureStatus(FeatureType_Native, "GetTankSelection") != FeatureStatus_Unknown);
}

void FindTankifier()
{
	bTankifier = LibraryExists("witch_and_tankifier");
}

void FindApex()
{
	bApex = LibraryExists("Apex") || (GetFeatureStatus(FeatureType_Native, "Apex_IsBhopEnabled") != FeatureStatus_Unknown);
	bApexPred = (GetFeatureStatus(FeatureType_Native, "Apex_IsPredEnabled") == FeatureStatus_Available);
}

// ======================================================================
//  Dependency Monitor
// ======================================================================
void GameConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	GetGameCvars();
}

void ServerCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	FillServerNamer();
}

public void OnAllPluginsLoaded()
{
	FindScoreMod();

	FillBossPercents();
	FillServerNamer();
	FillReadyConfig();

	FindTankSelection();
	FindTankifier();
	FindApex();
}

public void OnLibraryAdded(const char[] name)
{
	FindScoreMod();
	FillBossPercents();
	FindTankifier();
	FindApex();
}

public void OnLibraryRemoved(const char[] name)
{
	FindScoreMod();
	FillBossPercents();
	FindTankifier();
	FindApex();
}

public void L4D_OnGameModeChange(int gamemode)
{
	GetCurrentGameMode();
}

// ======================================================================
//  Bosses Caching
// ======================================================================
void BuildCustomTrieEntries()
{
	// Haunted Forest 3
	hCustomTankScriptMaps.SetValue("hf03_themansion", true);
}

void InitTankSpawnSchemeTrie()
{
	hFirstTankSpawningScheme	= new StringMap();
	hSecondTankSpawningScheme	= new StringMap();
	hFinaleExceptionMaps		= new StringMap();
	hCustomTankScriptMaps		= new StringMap();
	
	RegServerCmd("tank_map_flow_and_second_event",	SetMapFirstTankSpawningScheme);
	RegServerCmd("tank_map_only_first_event",		SetMapSecondTankSpawningScheme);
	RegServerCmd("finale_tank_default",				SetFinaleExceptionMap);
	
	BuildCustomTrieEntries();
}

Action SetMapFirstTankSpawningScheme(int args)
{
	char mapname[64];
	GetCmdArg(1, mapname, sizeof(mapname));
	hFirstTankSpawningScheme.SetValue(mapname, true);

	return Plugin_Handled;
}

Action SetMapSecondTankSpawningScheme(int args)
{
	char mapname[64];
	GetCmdArg(1, mapname, sizeof(mapname));
	hSecondTankSpawningScheme.SetValue(mapname, true);
	return Plugin_Handled;
}

Action SetFinaleExceptionMap(int args)
{
	char mapname[64];
	GetCmdArg(1, mapname, sizeof(mapname));
	hFinaleExceptionMaps.SetValue(mapname, true);
	return Plugin_Handled;
}

/**********************************************************************************************/

// ======================================================================
//  Forwards
// ======================================================================
public void OnClientDisconnect(int client)
{
	bSpecHudHintShown[client] = false;
	bTankHudHintShown[client] = false;
}

// 传卡/换人控制坦克时的存活计时处理：
//  - 换给真人玩家 -> 清零，重新计新控制者的存活时间
//  - 变成 AI 坦克  -> 不清零（仍是同一只坦克实体，只是无人控制）
public void L4D_OnReplaceTank(int tank, int newtank)
{
	if (IsFakeClient(newtank))
		return;

	g_fTankAliveTimestamp = 0.0;
	g_bTankTimerInitialized = false;
}

Action Timer_RespectateSpecs(Handle hTimer)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == L4D2Team_Spectator)
		{
			FakeClientCommand(i, "sm_spectate");
		}
	}

	return Plugin_Stop;
}

public void OnMapStart() { bRoundLive = false; }
public void OnRoundIsLive()
{
	FillReadyConfig();
	
	bRoundLive = true;
	
	GetCurrentGameMode();
	
	CreateTimer(0.2, Timer_RespectateSpecs);
	
	if (g_Gamemode == GAMEMODE_VERSUS)
	{
		bRoundHasFlowTank = RoundHasFlowTank();
		bRoundHasFlowWitch = RoundHasFlowWitch();
		bFlowTankActive = bRoundHasFlowTank;
		
		bCustomBossSys = IsDarkCarniRemix();
		
		bStaticTank = bTankifier && IsStaticTankMap();
		bStaticWitch = bTankifier && IsStaticWitchMap();
		
		// 12v12 的路程分插件已经把「人数缩放」写进 vs_max_completion_score 本身
		// （900 = 300 × 12/4），这里再 /4*人数 会二次放大成 2700。
		// 其它模式没有该库，继续用旧的 /4*人数 换算，显示不变。
		if (LibraryExists("l4d2_applemod_scoremod_12v12"))
			iMaxDistance = L4D_GetVersusMaxCompletionScore();
		else
			iMaxDistance = L4D_GetVersusMaxCompletionScore() / 4 * iSurvivorLimit;
		
		iTankCount = 0;
		iWitchCount = 0;
		
		if (l4d_tank_percent != null && l4d_tank_percent.BoolValue)
		{
			if (GetFeatureStatus(FeatureType_Native, "GetStoredTankPercent") != FeatureStatus_Unknown)
				iTankFlow = GetStoredTankPercent();
			else
				iTankFlow = GetRoundTankFlow();
				
			iTankCount = 1;
			
			char mapname[64];
			bool dummy;
			GetCurrentMap(mapname, sizeof(mapname));
			
			// TODO: individual plugin served as an interface to tank counts?
			if (hCustomTankScriptMaps.GetValue(mapname, dummy)) iTankCount += 1;
			
			else if (!bCustomBossSys && L4D_IsMissionFinalMap())
			{
				iTankCount = 3
							- view_as<int>(hFirstTankSpawningScheme.GetValue(mapname, dummy))
							- view_as<int>(hSecondTankSpawningScheme.GetValue(mapname, dummy))
							- view_as<int>(hFinaleExceptionMaps.Size > 0 && !hFinaleExceptionMaps.GetValue(mapname, dummy))
							- view_as<int>(bStaticTank);
			}
		}
		
		if (l4d_witch_percent != null && l4d_witch_percent.BoolValue)
		{
			if (GetFeatureStatus(FeatureType_Native, "GetStoredWitchPercent") != FeatureStatus_Unknown)
				iWitchFlow = GetStoredWitchPercent();
			else
				iWitchFlow = GetRoundWitchFlow();
			
			iWitchCount = 1;
		}
	}
}

//public void L4D2_OnEndVersusModeRound_Post() { if (!InSecondHalfOfRound()) iFirstHalfScore = L4D_GetTeamScore(GetRealTeam(0) + 1); }

// ======================================================================
//  Events
// ======================================================================
void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	bRoundLive = false;

	g_iTankPunch = 0;
	g_iTankRock = 0;
	g_iTankHittable = 0;
	g_iTankDamage = 0;

	g_fTankAliveTimestamp = 0.0;
	g_bTankTimerInitialized = false;

	// 新回合：坦克事件带下来的"tankhud 已强制关闭"标记作废（见 Native_TankHudDisable）
	g_bTankHudForceOff = false;
}

void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	bRoundLive = false;
}

void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!client || !IsInfected(client)) return;
	
	if (GetInfectedClass(client) == L4D2Infected_Tank)
	{
		if (iTankCount > 0) iTankCount--;
		if (!RoundHasFlowTank()) bFlowTankActive = false;

		g_fTankAliveTimestamp = 0.0;
		g_bTankTimerInitialized = false;
	}
}

void Event_WitchDeath(Event event, const char[] name, bool dontBroadcast)
{
	if (iWitchCount > 0) iWitchCount--;
}

void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!client) return;

	int team = event.GetInt("team");

	if (team == L4D2Team_None) // Player disconnecting
	{
		bSpecHudActive[client] = false;
		// 坦克事件已经强制关掉过 tankhud 的回合里，别把槽位重置回"开" —— 否则下一个
		// 坐进这个槽位的玩家会在坦克还在场时又看到坦克面板（需求：坦克刷出/接管时关闭 tankhud）
		bTankHudActive[client] = !g_bTankHudForceOff;
	}

	//if (team == L4D2Team_Infected) storedClass[client] = ZC_None;
}

void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));
	if (!victim || GetClientTeam(victim) != L4D2Team_Survivor || IsIncapacitated(victim))
		return;

	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	if (attacker <= 0 || !IsTank(attacker))
		return;

	int dmg = event.GetInt("dmg_health");
	if (dmg <= 0)
		return;
	g_iTankDamage += dmg;

	char weapon[32];
	event.GetString("weapon", weapon, sizeof(weapon));

	if (StrEqual(weapon, "tank_claw"))
		g_iTankPunch++;
	else if (StrEqual(weapon, "tank_rock"))
		g_iTankRock++;
	else
		g_iTankHittable++;
}

void Event_PlayerIncapStart(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));
	if (!victim || GetClientTeam(victim) != L4D2Team_Survivor)
		return;

	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	if (attacker <= 0 || !IsTank(attacker))
		return;

	char weapon[32];
	event.GetString("weapon", weapon, sizeof(weapon));

	if (StrEqual(weapon, "tank_claw"))
		g_iTankPunch++;
	else if (StrEqual(weapon, "tank_rock"))
		g_iTankRock++;
	else
		g_iTankHittable++;
}

/**********************************************************************************************/

// ======================================================================
//  HUD Command Callbacks
// ======================================================================
Action ToggleSpecHudCmd(int client, int args)
{
	if (!IsValidClientIndex(client) || !IsClientInGame(client))
		return Plugin_Handled;
	
	if (GetClientTeam(client) != L4D2Team_Spectator)
		return Plugin_Handled;
	
	bSpecHudActive[client] = !bSpecHudActive[client];

	if (bSpecHudActive[client])
		CPrintToChat(client, "<{olive}HUD{default}> 旁观面板已 {blue}开启{default}");
	else
		CPrintToChat(client, "<{olive}HUD{default}> 旁观面板已 {red}关闭{default}");
	return Plugin_Handled;
}

Action ToggleTankHudCmd(int client, int args)
{
	if (!IsValidClientIndex(client) || !IsClientInGame(client))
		return Plugin_Handled;
	
	if (GetClientTeam(client)  == L4D2Team_Survivor)
		return Plugin_Handled;
	
	bTankHudActive[client] = !bTankHudActive[client];

	if (bTankHudActive[client])
		CPrintToChat(client, "<{olive}HUD{default}> 坦克HUD现在为 {blue}开启{default}");
	else
		CPrintToChat(client, "<{olive}HUD{default}> 坦克HUD现在为 {red}关闭{default}");
	return Plugin_Handled;
}

/**********************************************************************************************/

// ======================================================================
//  Native：坦克HUD 强制关闭（供 l4d_superversus 的 sihud 调用）
// ======================================================================
// 关掉 tankhud：client = 0 → 所有玩家；client > 0 → 指定玩家。
//   · bTankHudActive 就是玩家自己的 "!tankhud" 开关，置 false 之后 HudDrawTimer 不再给他发
//     坦克面板；之后玩家仍然可以用 !tankhud 自己重新打开（本 native 不改这个语义）；
//   · 屏幕上已经显示的那块坦克面板用一行空面板顶掉（Panel 没有"清除"接口）；
//   · 只顶"确实在收坦克面板"的人：旁观者开着 !spechud 旁观面板时，屏幕上那块是旁观面板，
//     拿空面板去顶会把旁观面板打掉（两者共用同一块聊天面板位置），所以跳过。
any Native_TankHudDisable(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	// 只要 sihud 那边来调用，就说明本回合已经有过坦克事件；掉线重置槽位时不要再把 tankhud 打开
	g_bTankHudForceOff = true;

	if (client <= 0)
	{
		for (int i = 1; i <= MaxClients; ++i)
		{
			if (!IsClientInGame(i) || IsFakeClient(i)) continue;
			TankHud_Disable(i);
		}
	}
	else if (client <= MaxClients)
	{
		if (IsClientInGame(client) && !IsFakeClient(client)) TankHud_Disable(client);
	}
	return 0;
}

void TankHud_Disable(int client)
{
	if (client <= 0 || client > MaxClients || !IsClientInGame(client)) return;

	bool bWasActive = bTankHudActive[client];
	bTankHudActive[client] = false;
	if (!bWasActive) return;						// 本来就没开，屏幕上不会有坦克面板

	// 只有"屏幕上那块确实是坦克面板"的人才顶屏（同一块聊天面板位置，顶错会打掉别的面板）：
	//   · 感染者：一直收坦克面板（除非开着别的东西，那也不是我们该管的）；
	//   · 旁观者：只有没开 !spechud 旁观面板时才收坦克面板；
	//   · 生还者 / SourceTV：根本不会收到坦克面板。
	if (IsClientSourceTV(client)) return;
	if (GetClientTeam(client) == L4D2Team_Infected) { /* 继续顶屏 */ }
	else if (GetClientTeam(client) == L4D2Team_Spectator && !bSpecHudActive[client]) { /* 继续顶屏 */ }
	else return;

	Panel blank = new Panel();
	blank.DrawText(" ");
	blank.Send(client, DummyTankHudHandler, 1);
	delete blank;
}

// ======================================================================
//  HUD Handle
// ======================================================================
Action HudDrawTimer(Handle hTimer)
{
	if (IsInReady() || IsInPause())
		return Plugin_Continue;

	// 每秒重算一次缩名预算（两个面板都用到，所以放在这里统一算，避免拿到上一秒的旧值）
	PrepareMultiNameBudget();

	int tankHud_total = 0;
	int[] tankHud_clients = new int[MaxClients];
	int specHud_total = 0;
	int[] specHud_clients = new int[MaxClients];
	
	for (int i = 1; i <= MaxClients; ++i)
	{
		if (!IsClientInGame(i))
			continue;
		
		if (IsClientSourceTV(i))
		{
			specHud_clients[specHud_total++] = i;
			continue;
		}
		
		switch (GetClientTeam(i))
		{
			case L4D2Team_Spectator:
			{
				if (bSpecHudActive[i])
					specHud_clients[specHud_total++] = i;
				else if (bTankHudActive[i])
					tankHud_clients[tankHud_total++] = i;
			}
			case L4D2Team_Infected:
			{
				if (bTankHudActive[i])
					tankHud_clients[tankHud_total++] = i;
			}

		}
	}
	
	if (specHud_total) // Only bother if someone's watching us
	{
		Panel specHud = new Panel();
		
		FillHeaderInfo(specHud);
		FillSurvivorInfo(specHud);
		FillScoreInfo(specHud);
		FillInfectedInfo(specHud);
		if (!FillTankInfo(specHud))
			FillGameInfo(specHud);

		for (int i = 0; i < specHud_total; ++i)
		{
			int client = specHud_clients[i];
			
			switch (GetClientMenu(client))
			{
				case MenuSource_External, MenuSource_Normal: continue;
			}
			
			specHud.Send(client, DummySpecHudHandler, 3);
			if (!bSpecHudHintShown[client])
			{
				bSpecHudHintShown[client] = true;
				CPrintToChat(client, "<{olive}HUD{default}> 聊天输入 {green}!spechud{default} 切换 {blue}旁观面板开关");
			}
		}
		delete specHud;
	}
	
	if (!tankHud_total) return Plugin_Continue;
	
	Panel tankHud = new Panel();
	if (FillTankInfo(tankHud, true)) // No tank -- no HUD
	{
		for (int i = 0; i < tankHud_total; ++i)
		{
			int client = tankHud_clients[i];
			
			switch (GetClientMenu(client))
			{
				case MenuSource_External, MenuSource_Normal: continue;
			}
			
			tankHud.Send(client, DummyTankHudHandler, 3);
			if (!bTankHudHintShown[client])
			{
				bTankHudHintShown[client] = true;
				CPrintToChat(client, "<{olive}HUD{default}> 聊天输入 {green}!tankhud{default} 切换 {red}坦克面板开关");
			}
		}
	}
	
	delete tankHud;
	return Plugin_Continue;
}

int DummySpecHudHandler(Menu hMenu, MenuAction action, int param1, int param2) { return 1; }
int DummyTankHudHandler(Menu hMenu, MenuAction action, int param1, int param2) { return 1; }

/**********************************************************************************************/

// ======================================================================
//  HUD Content
// ======================================================================
void FillHeaderInfo(Panel hSpecHud)
{
	static int iTickrate = 0;
	if (iTickrate == 0 && IsServerProcessing())
		iTickrate = RoundToNearest(1.0 / GetTickInterval());
	
	static char buf[64];
	if (bMultiPlayer)
	{
		// 多人模式：服务器名按字节截断, 并省掉 tickrate, 把字节让给下面的玩家列表
		static char host[64];
		HUD_CopyPanelText(sHostname, host, sizeof(host), 24);
		FormatEx(buf, sizeof(buf), "%s [%i/%i]", host, GetRealClientCount(), iMaxPlayers);
	}
	else
	{
		FormatEx(buf, sizeof(buf), "%s [%i/%i | %iT]", sHostname, GetRealClientCount(), iMaxPlayers, iTickrate);
	}
	HUD_DrawPanelText(hSpecHud, buf);
}

void GetMeleePrefix(int client, char[] prefix, int length)
{
	int secondary = GetPlayerWeaponSlot(client, L4D2WeaponSlot_Secondary);
	if (secondary == -1)
		return;
	
	static char buf[4];
	switch (IdentifyWeapon(secondary))
	{
		case WEPID_NONE: buf = "N";
		case WEPID_PISTOL: buf = (GetEntProp(secondary, Prop_Send, "m_isDualWielding") ? "DP" : "P");
		case WEPID_PISTOL_MAGNUM: buf = "DE";
		case WEPID_MELEE: buf = "M";
		default: buf = "?";
	}

	strcopy(prefix, length, buf);
}

void GetWeaponInfo(int client, char[] info, int length)
{
	static char buffer[32];
	
	int activeWep = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	int primaryWep = GetPlayerWeaponSlot(client, L4D2WeaponSlot_Primary);
	int activeWepId = IdentifyWeapon(activeWep);
	int primaryWepId = IdentifyWeapon(primaryWep);
	
	// Let's begin with what player is holding,
	// but cares only pistols if holding secondary.
	switch (activeWepId)
	{
		case WEPID_PISTOL, WEPID_PISTOL_MAGNUM:
		{
			if (activeWepId == WEPID_PISTOL && !!GetEntProp(activeWep, Prop_Send, "m_isDualWielding"))
			{
				// Dual Pistols Scenario
				// Straight use the prefix since full name is a bit long.
				strcopy(buffer, sizeof(buffer), "DP");
			}
			else GetLongWeaponName(activeWepId, buffer, sizeof(buffer));
			
			FormatEx(info, length, "%s %i", buffer, GetWeaponClipAmmo(activeWep));
		}
		default:
		{
			GetLongWeaponName(primaryWepId, buffer, sizeof(buffer));
			FormatEx(info, length, "%s %i/%i", buffer, GetWeaponClipAmmo(primaryWep), GetWeaponExtraAmmo(client, primaryWep));
		}
	}
	
	// Format our result info
	if (primaryWep == -1)
	{
		// In case with no primary,
		// show the melee full name.
		if (activeWepId == WEPID_MELEE || activeWepId == WEPID_CHAINSAW)
		{
			int meleeWepId = IdentifyMeleeWeapon(activeWep);
			GetLongMeleeWeaponName(meleeWepId, info, length);
		}
	}
	else
	{
		// Default display -> [Primary <In Detail> | Secondary <Prefix>]
		// Holding melee included in this way
		// i.e. [Chrome 8/56 | M]
		if (GetSlotFromWeaponId(activeWepId) != L4D2WeaponSlot_Secondary || activeWepId == WEPID_MELEE || activeWepId == WEPID_CHAINSAW)
		{
			GetMeleePrefix(client, buffer, sizeof(buffer));
			Format(info, length, "%s | %s", info, buffer);
		}

		// Secondary active -> [Secondary <In Detail> | Primary <Ammo Sum>]
		// i.e. [Deagle 8 | Mac 700]
		else
		{
			GetLongWeaponName(primaryWepId, buffer, sizeof(buffer));
			Format(info, length, "%s | %s %i", info, buffer, GetWeaponClipAmmo(primaryWep) + GetWeaponExtraAmmo(client, primaryWep));
		}
	}
}

int SortSurvByCharacter(int elem1, int elem2, const int[] array, Handle hndl)
{
	int sc1 = IdentifySurvivor(elem1);
	int sc2 = IdentifySurvivor(elem2);

	if (sc1 > sc2) { return 1; }
	else if (sc1 < sc2) { return -1; }
	else { return 0; }
}

void GetClientPing(int client, char[] buffer, int bufferSize)
{
	if (IsFakeClient(client))
	{
		strcopy(buffer, bufferSize, "电脑");
	}
	else
	{
		int latency = RoundToNearest(GetClientAvgLatency(client, NetFlow_Both) * 1000.0);
		FormatEx(buffer, bufferSize, "%ims", latency);
	}
}

void FillSurvivorInfo(Panel hSpecHud)
{
	static char info[100];
	static char name[MAX_NAME_LENGTH];
	static char latency[8];

	int SurvivorTeamIndex = GameRules_GetProp("m_bAreTeamsFlipped");

	switch (g_Gamemode)
	{
		case GAMEMODE_SCAVENGE:
		{
			int score = GetScavengeMatchScore(SurvivorTeamIndex);
			// 多人模式省掉 "->1. " 的序号前缀（每段省 5 字节）
			FormatEx(info, sizeof(info), bMultiPlayer ? "生还者 [%d/%d]" : "->1. 生还者 [%d / %d]", score, GetScavengeRoundLimit());
		}
		case GAMEMODE_VERSUS:
		{
			if (bRoundLive)
			{
				FormatEx(info, sizeof(info), bMultiPlayer ? "生还者 [%d]" : "->1. 生还者 [%d]",
							L4D2Direct_GetVSCampaignScore(SurvivorTeamIndex) + GetVersusProgressDistance(SurvivorTeamIndex));
			}
			else
			{
				FormatEx(info, sizeof(info), bMultiPlayer ? "生还者 [%d]" : "->1. 生还者 [%d]",
							L4D2Direct_GetVSCampaignScore(SurvivorTeamIndex));
			}
		}
	}
	
	if (!bMultiPlayer)
		HUD_DrawPanelText(hSpecHud, " ");
	HUD_DrawPanelText(hSpecHud, info);
	
	int total = 0;
	int[] clients = new int[MaxClients];
	for (int i = 1; i <= MaxClients; ++i)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != L4D2Team_Survivor)
			continue;
		
		clients[total++] = i;
	}
	
	SortCustom1D(clients, total, SortSurvByCharacter);
	
	for (int i = 0; i < total; ++i)
	{
		int client = clients[i];
		
		if (bMultiPlayer)
		{
			// 多人模式行：只有 名字 + 血量 + 状态，砍掉延迟和武器（见文件头 MULTIPLAYER_* 注释）。
			// 状态标记: #=流血(有临时血) / n倒=已倒 n 次 / 挂边 / 死亡
			GetClientShortName(client, name, sizeof(name));
			if (!IsPlayerAlive(client))
			{
				FormatEx(info, sizeof(info), "%s 死亡", name);
			}
			else if (IsHangingFromLedge(client))
			{
				FormatEx(info, sizeof(info), "%s %iHP 挂边", name, GetClientHealth(client));
			}
			else if (IsIncapacitated(client))
			{
				// 当前这次倒地还没记进 m_currentReviveCount, 所以显示 已倒次数+1
				FormatEx(info, sizeof(info), "%s %iHP %i倒", name, GetClientHealth(client), GetSurvivorIncapCount(client) + 1);
			}
			else
			{
				int tempHealth = GetSurvivorTemporaryHealth(client);
				int health = GetClientHealth(client) + tempHealth;
				int incapCount = GetSurvivorIncapCount(client);
				if (incapCount == 0)
				{
					FormatEx(info, sizeof(info), "%s %iHP%s", name, health, (tempHealth > 0 ? "#" : ""));
				}
				else
				{
					FormatEx(info, sizeof(info), "%s %iHP# %i倒", name, health, incapCount);
				}
			}

			HUD_DrawPanelText(hSpecHud, info);
			continue;
		}

		GetClientFixedName(client, name, sizeof(name));
		GetClientPing(client, latency, sizeof(latency));
		if (!IsPlayerAlive(client))
		{
			FormatEx(info, sizeof(info), "%s | %s: 死亡", latency, name);
		}
		else
		{
			if (IsHangingFromLedge(client))
			{
				// Nick: <300HP@Hanging>
				FormatEx(info, sizeof(info), "%s | %s: <%iHP@挂边>", latency, name, GetClientHealth(client));
			}
			else if (IsIncapacitated(client))
			{
				int activeWep = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
				GetLongWeaponName(IdentifyWeapon(activeWep), info, sizeof(info));
				// Nick: <300HP@1st> [Deagle 8]
				Format(info, sizeof(info), "%s | %s: <%iHP@%s> [%s %i]", latency, name, GetClientHealth(client), (GetSurvivorIncapCount(client) == 1 ? "2倒" : "1倒"), info, GetWeaponClipAmmo(activeWep));
			}
			else
			{
				GetWeaponInfo(client, info, sizeof(info));
				
				int tempHealth = GetSurvivorTemporaryHealth(client);
				int health = GetClientHealth(client) + tempHealth;
				int incapCount = GetSurvivorIncapCount(client);
				if (incapCount == 0)
				{
					// "#" indicates that player is bleeding.
					// Nick: 99HP# [Chrome 8/72]
					Format(info, sizeof(info), "%s | %s: %iHP%s [%s]", latency, name, health, (tempHealth > 0 ? "#" : ""), info);
				}
				else
				{
					// Player ever incapped should always be bleeding.
					// Nick: 99HP (#1st) [Chrome 8/72]
					Format(info, sizeof(info), "%s | %s: %iHP (#%s) [%s]", latency, name, health, (incapCount == 2 ? "2倒" : "1倒"), info);
				}
			}
		}
		
		HUD_DrawPanelText(hSpecHud, info);
	}
}

void FillScoreInfo(Panel hSpecHud)
{
	static char info[64];
	
	switch (g_Gamemode)
	{
		case GAMEMODE_SCAVENGE:
		{
			bool bSecondHalf = InSecondHalfOfRound();
			bool bTeamFlipped = !!GameRules_GetProp("m_bAreTeamsFlipped");
			
			float fDuration = GetScavengeRoundDuration(bTeamFlipped);
			int iMinutes = RoundToFloor(fDuration / 60);
			
			if (!bMultiPlayer)
				HUD_DrawPanelText(hSpecHud, " ");
				
			FormatEx(info, sizeof(info), "> 累计时间 [%02d:%02.0f]", iMinutes, fDuration - 60 * iMinutes);
			HUD_DrawPanelText(hSpecHud, info);
			
			if (bSecondHalf)
			{
				fDuration = GetScavengeRoundDuration(!bTeamFlipped);
				iMinutes = RoundToFloor(fDuration / 60);
				
				FormatEx(info, sizeof(info), "> 对方用时 [%02d:%05.2f]", iMinutes, fDuration - 60 * iMinutes);
				HUD_DrawPanelText(hSpecHud, info);
			}
		}
		
		case GAMEMODE_VERSUS:
		{
			// l4d2_scripted_hud 在场: 奖励分/路程分由屏幕 HUD 显示, 面板不显示任何奖励分内容;
			// 不在场: 面板显示完整奖励分(血量/伤害/药丸/总加成/距离).
			// (这里是 switch 的最后一个 case, 后面没有别的绘制, 所以直接 return 退出函数.)
			if (bScriptedHud)
				return;
			
			if (bHybridScoremod)
			{
				int healthBonus	= SMPlus_GetHealthBonus(),	maxHealthBonus	= SMPlus_GetMaxHealthBonus();
				int damageBonus	= SMPlus_GetDamageBonus(),	maxDamageBonus	= SMPlus_GetMaxDamageBonus();
				int pillsBonus	= SMPlus_GetPillsBonus(),	maxPillsBonus	= SMPlus_GetMaxPillsBonus();
				
				int totalBonus		= healthBonus		+ damageBonus		+ pillsBonus;
				int maxTotalBonus	= maxHealthBonus	+ maxDamageBonus	+ maxPillsBonus;
				
				if (!bMultiPlayer)
					HUD_DrawPanelText(hSpecHud, " ");
				
				// > HB: 860 <86%> | DB: 420 <84%> | Pills: 60 <60%>
				// > Bonus: 1340 <83.8%>
				// > Dist: 400
				
				FormatEx(	info,
							sizeof(info),
							bMultiPlayer ? "血量: %i <%.0f%%> | 伤害: %i <%.0f%%> | 药丸: %i <%.0f%%>" : "> 血量: %i <%.0f%%> | 伤害: %i <%.0f%%> | 药丸: %i <%.0f%%>",
							healthBonus, L4D2Util_IntToPercentFloat(healthBonus, maxHealthBonus),
							damageBonus, L4D2Util_IntToPercentFloat(damageBonus, maxDamageBonus),
							pillsBonus, L4D2Util_IntToPercentFloat(pillsBonus, maxPillsBonus));
				HUD_DrawPanelText(hSpecHud, info);
				
				FormatEx(info, sizeof(info), bMultiPlayer ? "总加成: %i <%.1f%%>" : "> 总加成: %i <%.1f%%>", totalBonus, L4D2Util_IntToPercentFloat(totalBonus, maxTotalBonus));
				HUD_DrawPanelText(hSpecHud, info);
				
				FormatEx(info, sizeof(info), bMultiPlayer ? "距离: %i" : "> 距离: %i", iMaxDistance);
				//if (InSecondHalfOfRound())
				//{
				//	Format(info, sizeof(info), "%s | R#1: %i <%.1f%%>", info, iFirstHalfScore, L4D2Util_IntToPercentFloat(iFirstHalfScore, L4D_GetVersusMaxCompletionScore() + maxTotalBonus));
				//}
				HUD_DrawPanelText(hSpecHud, info);
			}
			
			else if (bScoremod)
			{
				int healthBonus = HealthBonus();
				
				if (!bMultiPlayer)
					HUD_DrawPanelText(hSpecHud, " ");
				
				// > HB: 860
				// > Dist: 400
				
				FormatEx(info, sizeof(info), bMultiPlayer ? "血量: %i" : "> 血量: %i", healthBonus);
				HUD_DrawPanelText(hSpecHud, info);
				
				FormatEx(info, sizeof(info), bMultiPlayer ? "距离: %i" : "> 距离: %i", iMaxDistance);
				//if (InSecondHalfOfRound())
				//{
				//	Format(info, sizeof(info), "%s | R#1: %i", info, iFirstHalfScore);
				//}
				HUD_DrawPanelText(hSpecHud, info);
			}
			
			else if (bNextScoremod)
			{
				int permBonus	= SMNext_GetPermBonus(),	maxPermBonus	= SMNext_GetMaxPermBonus();
				int tempBonus	= SMNext_GetTempBonus(),	maxTempBonus	= SMNext_GetMaxTempBonus();
				int pillsBonus	= SMNext_GetPillsBonus(),	maxPillsBonus	= SMNext_GetMaxPillsBonus();
				
				int totalBonus		= permBonus		+ tempBonus		+ pillsBonus;
				int maxTotalBonus	= maxPermBonus	+ maxTempBonus	+ maxPillsBonus;
				
				if (!bMultiPlayer)
					HUD_DrawPanelText(hSpecHud, " ");
				
				// > Perm: 114 | Temp: 514 | Pills: 810
				// > Bonus: 114514 <100.0%>
				// > Dist: 191
				// never ever played on Next so take it easy.
				
				FormatEx(	info,
							sizeof(info),
							bMultiPlayer ? "永久: %i | 临时: %i | 药丸: %i" : "> 永久: %i | 临时: %i | 药丸: %i",
							permBonus, tempBonus, pillsBonus);
				HUD_DrawPanelText(hSpecHud, info);
				
				FormatEx(info, sizeof(info), bMultiPlayer ? "总加成: %i <%.1f%%>" : "> 总加成: %i <%.1f%%>", totalBonus, L4D2Util_IntToPercentFloat(totalBonus, maxTotalBonus));
				HUD_DrawPanelText(hSpecHud, info);
				
				FormatEx(info, sizeof(info), bMultiPlayer ? "距离: %i" : "> 距离: %i", iMaxDistance);
				//if (InSecondHalfOfRound())
				//{
				//	Format(info, sizeof(info), "%s | R#1: %i <%.1f%%>", info, iFirstHalfScore, ToPercent(iFirstHalfScore, L4D_GetVersusMaxCompletionScore() + maxTotalBonus));
				//}
				HUD_DrawPanelText(hSpecHud, info);
			}
		}
	}
}

void FillInfectedInfo(Panel hSpecHud)
{
	static char info[80];
	static char buffer[16];
	static char name[MAX_NAME_LENGTH];
	static char latency[8];

	int InfectedTeamIndex = !GameRules_GetProp("m_bAreTeamsFlipped");
	
	switch (g_Gamemode)
	{
		case GAMEMODE_SCAVENGE:
		{
			int score = GetScavengeMatchScore(InfectedTeamIndex);
			FormatEx(info, sizeof(info), bMultiPlayer ? "感染者 [%d/%d]" : "->2. 感染者 [%d / %d]", score, GetScavengeRoundLimit());
		}
		case GAMEMODE_VERSUS:
		{
			FormatEx(info, sizeof(info), bMultiPlayer ? "感染者 [%d]" : "->2. 感染者 [%d]",
						L4D2Direct_GetVSCampaignScore(InfectedTeamIndex));
		}
	}
	
	if (!bMultiPlayer)
		HUD_DrawPanelText(hSpecHud, " ");
	HUD_DrawPanelText(hSpecHud, info);

	int infectedCount = 0;
	for (int client = 1; client <= MaxClients; ++client)
	{
		if (!IsClientInGame(client) || GetClientTeam(client) != L4D2Team_Infected)
			continue;
		
		if (bMultiPlayer)
		{
			// 多人模式行：名字 + 1 字职业 + 血量/状态，冷却计时保留（计时是关键信息）。
			// 职业名从 "Charger"(7 字节) 缩成 1 个汉字，12 行就能省下 60~70 字节。
			GetClientShortName(client, name, sizeof(name));
			if (!IsPlayerAlive(client))
			{
				int timeLeft = RoundToFloor(L4D_GetPlayerSpawnTime(client));
				if (timeLeft > 0)
					FormatEx(info, sizeof(info), "%s 死 %i秒", name, timeLeft);
				else
					FormatEx(info, sizeof(info), "%s 死", name);
			}
			else
			{
				int zClass = GetInfectedClass(client);
				if (zClass == L4D2Infected_Tank)
					continue;

				char zShort[4];
				GetShortInfectedClassName(zClass, zShort, sizeof(zShort));

				int iHP = GetClientHealth(client), iMaxHP = GetEntProp(client, Prop_Send, "m_iMaxHealth");
				if (IsInfectedGhost(client))
				{
					// 幽灵(含带伤复活的残血幽灵)
					if (iHP < iMaxHP)
						FormatEx(info, sizeof(info), "%s %s 幽灵%i", name, zShort, iHP);
					else
						FormatEx(info, sizeof(info), "%s %s 幽灵", name, zShort);
				}
				else
				{
					buffer[0] = '\0';
					
					float fTimestamp, fDuration;
					if (GetInfectedAbilityTimer(client, fTimestamp, fDuration))
					{
						int iCooldown = RoundToCeil(fTimestamp - GetGameTime());
						
						if (iCooldown > 0
							&& fDuration > 1.0
							&& fDuration != 3600
							&& GetInfectedVictim(client) <= 0)
						{
							FormatEx(buffer, sizeof(buffer), " %i秒", iCooldown);
						}
					}
					
					FormatEx(info, sizeof(info), "%s %s %i%s%s",
						name, zShort, iHP,
						(GetEntityFlags(client) & FL_ONFIRE) ? " 火" : "",
						buffer);
				}
			}

			infectedCount++;
			HUD_DrawPanelText(hSpecHud, info);
			continue;
		}

		GetClientFixedName(client, name, sizeof(name));
		GetClientPing(client, latency, sizeof(latency));
		if (!IsPlayerAlive(client))
		{
			int timeLeft = RoundToFloor(L4D_GetPlayerSpawnTime(client));
			if (timeLeft < 0) // Deathcam
			{
				// verygood: Dead
				FormatEx(info, sizeof(info), "%s | %s: 死亡", latency, name);
			}
			else // Ghost Countdown
			{
				FormatEx(buffer, sizeof(buffer), "%i秒", timeLeft);
				// verygood: Dead (15s)
				FormatEx(info, sizeof(info), "%s | %s: 死亡 (%s)", latency, name, (timeLeft ? buffer : "生成中"));
				
				//char zClassName[10];
				//GetInfectedClassName(storedClass[client], zClassName, sizeof zClassName);
				//if (storedClass[client] > L4D2Team_None)
				//{
				//	FormatEx(info, sizeof(info), "%s: Dead (%s) [%s]", name, zClassName, (RoundToNearest(timeLeft) ? buffer : "Spawning..."));
				//} else {
				//	FormatEx(info, sizeof(info), "%s: Dead (%s)", name, (RoundToNearest(timeLeft) ? buffer : "Spawning..."));
				//}
			}
		}
		else
		{
			int zClass = GetInfectedClass(client);
			if (zClass == L4D2Infected_Tank)
				continue;
				
			char zClassName[10];
			GetInfectedClassName(zClass, zClassName, sizeof(zClassName));
			
			int iHP = GetClientHealth(client), iMaxHP = GetEntProp(client, Prop_Send, "m_iMaxHealth");
			if (IsInfectedGhost(client))
			{
				// DONE: Handle a case of respawning chipped SI, show the ghost's health
				if (iHP < iMaxHP)
				{
					// verygood: Charger (G@1HP)
					FormatEx(info, sizeof(info), "%s | %s: %s (幽灵@%iHP)", latency, name, zClassName, iHP);
				}
				else
				{
					// verygood: Charger (G)
					FormatEx(info, sizeof(info), "%s | %s: %s (幽灵)", latency, name, zClassName);
				}
			}
			else
			{
				buffer[0] = '\0';
				
				float fTimestamp, fDuration;
				if (GetInfectedAbilityTimer(client, fTimestamp, fDuration))
				{
					int iCooldown = RoundToCeil(fTimestamp - GetGameTime());
					
					if (iCooldown > 0
						&& fDuration > 1.0
						&& fDuration != 3600
						&& GetInfectedVictim(client) <= 0)
					{
						FormatEx(buffer, sizeof(buffer), " [%i秒]", iCooldown);
					}
				}
				
				if (GetEntityFlags(client) & FL_ONFIRE)
				{
					// verygood: Charger (1HP) [On Fire] [6s]
					FormatEx(info, sizeof(info), "%s | %s: %s (%iHP) [着火]%s", latency, name, zClassName, iHP, buffer);
				}
				else
				{
					// verygood: Charger (1HP) [6s]
					FormatEx(info, sizeof(info), "%s | %s: %s (%iHP)%s", latency, name, zClassName, iHP, buffer);
				}
			}
		}

		infectedCount++;
		HUD_DrawPanelText(hSpecHud, info);
	}
	
	if (!infectedCount)
	{
		HUD_DrawPanelText(hSpecHud, "无特感");
	}
}

float GetTankAliveTime()
{
	// 只在计时器未初始化/被清零点复位后重新起表；
	// 控制权在真人和 AI 之间切换（client index 变化）不会重置存活时间。
	if (!g_bTankTimerInitialized)
	{
		g_fTankAliveTimestamp = GetGameTime();
		g_bTankTimerInitialized = true;
	}
	return GetGameTime() - g_fTankAliveTimestamp;
}

stock void FormatTankAliveTime(float fSeconds, char[] buffer, int maxlen)
{
	int iTotal = RoundToFloor(fSeconds);
	FormatEx(buffer, maxlen, "%d分%02d秒", iTotal / 60, iTotal % 60);
}

stock void GetRockBlockStatus(char[] buffer, int maxlen)
{
	char szJump[8], szPunch[8];
	ConVar cvar;

	if ((cvar = FindConVar("l4d2_block_jump_rock")) != null)
		strcopy(szJump, sizeof(szJump), cvar.BoolValue ? "关闭" : "开启");
	else
		strcopy(szJump, sizeof(szJump), "未知");

	if ((cvar = FindConVar("l4d2_block_punch_rock")) != null)
		strcopy(szPunch, sizeof(szPunch), cvar.BoolValue ? "关闭" : "开启");
	else
		strcopy(szPunch, sizeof(szPunch), "未知");

	FormatEx(buffer, maxlen, "跳砖: %s | 拳砖: %s", szJump, szPunch);
}

stock void GetToggleStatus(bool enabled, char[] buffer, int maxlen)
{
	strcopy(buffer, maxlen, enabled ? "开启" : "关闭");
}

stock void GetApexSkillStatus(int client, char[] buffer, int maxlen)
{
	char szBhop[8], szTrac[8], szPred[8];

	GetToggleStatus(Apex_IsBhopEnabled(client), szBhop, sizeof(szBhop));
	GetToggleStatus(Apex_IsTracEnabled(client), szTrac, sizeof(szTrac));

	/* 旧版 Apex.smx 没有 !pred, 这里不能调它的 native, 直接显示"无" */
	if (bApexPred)
		GetToggleStatus(Apex_IsPredEnabled(client), szPred, sizeof(szPred));
	else
		strcopy(szPred, sizeof(szPred), "无");

	/* 三个技能要挤在坦克面板同一行(坦克面板一行放得下约 34 列), 所以:
	   标签取短的(跟踪 = 跟踪石头 !trac, 轨迹 = 石头轨迹预测 !pred), 分隔只用单空格 */
	FormatEx(buffer, maxlen, "连跳: %s 跟踪: %s 轨迹: %s", szBhop, szTrac, szPred);
}

bool FillTankInfo(Panel hSpecHud, bool bTankHUD = false)
{
	int tank = FindTankClient(-1);
	if (tank == -1 || !IsPlayerAlive(tank))
		return false;

	static char info[96];
	static char name[MAX_NAME_LENGTH];

	if (bTankHUD)
	{
		FormatEx(info, sizeof(info), "%s :: 坦克面板", sReadyCfgName);
		ValvePanel_ShiftInvalidString(info, sizeof(info));
		HUD_DrawPanelText(hSpecHud, info);

		int len = strlen(info);
		for (int i = 0; i < len; ++i) info[i] = '-';
		HUD_DrawPanelText(hSpecHud, info);

		FormatEx(info, sizeof(info), " [拳 %i] [石 %i] [铁 %i] [伤害 %i]", g_iTankPunch, g_iTankRock, g_iTankHittable, g_iTankDamage);
		HUD_DrawPanelText(hSpecHud, info);

		GetRockBlockStatus(info, sizeof(info));
		HUD_DrawPanelText(hSpecHud, info);

		if (bApex)
		{
			GetApexSkillStatus(tank, info, sizeof(info));
			HUD_DrawPanelText(hSpecHud, info);
		}

		int dlen = strlen(info);
		for (int i = 0; i < dlen; ++i) info[i] = '-';
		HUD_DrawPanelText(hSpecHud, info);
	}
	else
	{
		if (!bMultiPlayer)
			HUD_DrawPanelText(hSpecHud, " ");
		HUD_DrawPanelText(hSpecHud, bMultiPlayer ? "坦克" : "->3. 坦克");
	}

	// Draw owner & pass counter
	int passCount = L4D2Direct_GetTankPassedCount();
	switch (passCount)
	{
		case 0: strcopy(info, sizeof(info), "原生");
		case 1: FormatEx(info, sizeof(info), "第%i次", passCount);
		case 2: FormatEx(info, sizeof(info), "第%i次", passCount);
		case 3: FormatEx(info, sizeof(info), "第%i次", passCount);
		default: FormatEx(info, sizeof(info), "第%i次", passCount);
	}

	char sAlive[32];
	FormatTankAliveTime(GetTankAliveTime(), sAlive, sizeof(sAlive));

	if (!IsFakeClient(tank))
	{
		GetClientShortName(tank, name, sizeof(name));
		Format(info, sizeof(info), "控制: %s (%s) [%s]", name, info, sAlive);
	}
	else
	{
		Format(info, sizeof(info), "控制: 电脑 (%s) [%s]", info, sAlive);
	}
	HUD_DrawPanelText(hSpecHud, info);

	// Draw health
	int health = GetClientHealth(tank);
	int maxhealth = GetEntProp(tank, Prop_Send, "m_iMaxHealth");
	float healthPercent = L4D2Util_IntToPercentFloat(health, maxhealth); // * 100 already
	bool isIncapacitated = IsIncapacitated(tank);
	
	if (health <= 0 || isIncapacitated)
	{
		info = "血量: 死亡";
	}
	else
	{
		FormatEx(info, sizeof(info), "血量: %i / %i%%", health, L4D2Util_GetMax(1, RoundFloat(healthPercent)));
	}
	HUD_DrawPanelText(hSpecHud, info);

	// Draw frustration
	if (!IsFakeClient(tank))
	{
		FormatEx(info, sizeof(info), "怒气: %d%%", GetTankFrustration(tank));
	}
	else
	{
		info = "怒气: 电脑";
	}
	HUD_DrawPanelText(hSpecHud, info);

	// Draw network
	if (!IsFakeClient(tank))
	{
		FormatEx(info, sizeof(info), "延迟: %ims / %.1f", RoundToNearest(GetClientAvgLatency(tank, NetFlow_Both) * 1000.0), LM_GetLerpTime(tank) * 1000.0);
	}
	else
	{
		info = "延迟: 电脑";
	}
	HUD_DrawPanelText(hSpecHud, info);

	// Draw fire status
	if (!isIncapacitated && GetEntityFlags(tank) & FL_ONFIRE)
	{
		int timeleft = RoundToCeil(healthPercent / 100.0 * fTankBurnDuration);
		FormatEx(info, sizeof(info), "燃烧: %i秒", timeleft);
		HUD_DrawPanelText(hSpecHud, info);
	}

	// 需求：tankhud 里原来那行 "!gk给克" 的提示整段删除（保留下面 bTankHUD && bApex 的技能提示块）

	if (bTankHUD && bApex)
	{
		ConVar cvar;

		if ((cvar = FindConVar("tank_bohp_hp")) != null)
		{
			FormatEx(info, sizeof(info), "!lt开启自动连跳(扣%d)", cvar.IntValue);
			HUD_DrawPanelText(hSpecHud, info);
		}
		if ((cvar = FindConVar("tank_trac_hp")) != null)
		{
			FormatEx(info, sizeof(info), "!gz开启跟踪石头(扣%d)", cvar.IntValue);
			HUD_DrawPanelText(hSpecHud, info);
		}
		if ((cvar = FindConVar("tank_pred_hp")) != null)
		{
			FormatEx(info, sizeof(info), "!yc/开启石头轨迹预测(扣%d)", cvar.IntValue);
			HUD_DrawPanelText(hSpecHud, info);
		}

		FormatEx(info, sizeof(info), "开启后再次执行相同指令可关闭技能");
		HUD_DrawPanelText(hSpecHud, info);
	}

	return true;
}

void FillGameInfo(Panel hSpecHud)
{
	// Turns out too much info actually CAN be bad, funny ikr
	static char info[64];
	static char buffer[10];
	// 多人模式：配置名按字节裁剪，并省掉 "->3. " 前缀和 " " 空行，把字节让给玩家列表
	static char cfg[64];

	if (bMultiPlayer)
		HUD_CopyPanelText(sReadyCfgName, cfg, sizeof(cfg), 20);
	else
		strcopy(cfg, sizeof(cfg), sReadyCfgName);

	switch (g_Gamemode)
	{
		case GAMEMODE_SCAVENGE:
		{
			FormatEx(info, sizeof(info), bMultiPlayer ? "%s 第%i局" : "->3. %s (第%i局)", cfg, GetScavengeRoundNumber());
			
			if (!bMultiPlayer)
				HUD_DrawPanelText(hSpecHud, " ");
			HUD_DrawPanelText(hSpecHud, info);
			
			FormatEx(info, sizeof(info), "共%i局", GetScavengeRoundLimit());
			HUD_DrawPanelText(hSpecHud, info);
		}
		
		case GAMEMODE_VERSUS:
		{
			FormatEx(info, sizeof(info), bMultiPlayer ? "%s 第%d局" : "->3. %s (第%d局)", cfg, 1 + view_as<int>(InSecondHalfOfRound()));
			if (!bMultiPlayer)
				HUD_DrawPanelText(hSpecHud, " ");
			HUD_DrawPanelText(hSpecHud, info);
			
			if (l4d_tank_percent != null && l4d_witch_percent != null)
			{
				int survivorFlow = GetHighestSurvivorFlow();
				if (survivorFlow == -1)
					survivorFlow = GetFurthestSurvivorFlow();
				
				bool bDivide = false;
				
				if (bMultiPlayer)
				{
					// 多人模式：三段用空格分隔，省掉 " | " 与 ":" 这些分隔符
					if (iTankCount > 0)
					{
						bDivide = true;
						FormatEx(buffer, sizeof(buffer), "%i%%", iTankFlow);
						
						if ((bFlowTankActive && bRoundHasFlowTank) || bCustomBossSys)
							FormatEx(info, sizeof(info), "坦克%s", buffer);
						else
							FormatEx(info, sizeof(info), "坦克%s", (bStaticTank ? "静态" : "事件"));
					}
					
					if (iWitchCount > 0)
					{
						char witchVal[10];
						FormatEx(buffer, sizeof(buffer), "%i%%", iWitchFlow);
						strcopy(witchVal, sizeof(witchVal), ((bRoundHasFlowWitch || bCustomBossSys) ? buffer : (bStaticWitch ? "静态" : "事件")));
						
						if (bDivide)
						{
							Format(info, sizeof(info), "%s 女巫%s", info, witchVal);
						}
						else
						{
							bDivide = true;
							FormatEx(info, sizeof(info), "女巫%s", witchVal);
						}
					}
					
					if (bDivide)
						Format(info, sizeof(info), "%s 当前%i%%", info, survivorFlow);
					else
						FormatEx(info, sizeof(info), "当前%i%%", survivorFlow);
				}
				else
				{
					// tank percent
					if (iTankCount > 0)
					{
						bDivide = true;
						FormatEx(buffer, sizeof(buffer), "%i%%", iTankFlow);
						
						if ((bFlowTankActive && bRoundHasFlowTank) || bCustomBossSys)
						{
							FormatEx(info, sizeof(info), "坦克: %s", buffer);
						}
						else
						{
							FormatEx(info, sizeof(info), "坦克: %s", (bStaticTank ? "静态" : "事件"));
						}
					}
					
					// witch percent
					if (iWitchCount > 0)
					{
						FormatEx(buffer, sizeof(buffer), "%i%%", iWitchFlow);
						
						if (bDivide) {
							Format(info, sizeof(info), "%s | 女巫: %s", info, ((bRoundHasFlowWitch || bCustomBossSys) ? buffer : (bStaticWitch ? "静态" : "事件")));
						} else {
							bDivide = true;
							FormatEx(info, sizeof(info), "女巫: %s", ((bRoundHasFlowWitch || bCustomBossSys) ? buffer : (bStaticWitch ? "静态" : "事件")));
						}
					}
					
					// current
					if (bDivide) {
						Format(info, sizeof(info), "%s | 当前: %i%%", info, survivorFlow);
					} else {
						FormatEx(info, sizeof(info), "当前: %i%%", survivorFlow);
					}
				}
				
				HUD_DrawPanelText(hSpecHud, info);
			}
			
			// tank selection
			if (bTankSelection && iTankCount > 0)
			{
				int tankClient = GetTankSelection();
				if (tankClient > 0 && IsClientInGame(tankClient))
				{
					if (bMultiPlayer)
					{
						static char tankName[MAX_NAME_LENGTH];
						GetClientShortName(tankClient, tankName, sizeof(tankName));
						FormatEx(info, sizeof(info), "坦克: %s", tankName);
					}
					else
					{
						FormatEx(info, sizeof(info), "坦克: %N", tankClient);
					}
					HUD_DrawPanelText(hSpecHud, info);
				}
			}
		}
	}
}

/**
 *	Stocks
**/
// ----------------------------------------------------------------------
//  多人模式面板精简工具
//  HUD_CopyPanelText / HUD_DrawPanelText 的做法与 readyup-applemod/panel.inc 的
//  RU_CopyPanelText / RU_DrawPanelText、doorlock.inc 的 DL_LoadingPanel 缩名一致：
//  聊天面板(radio panel)整块只有 511 字节(含换行)，UTF-8 中文一个字 3 字节，
//  所以按"字节预算"裁剪，多字节字符必须整字保留，超出预算用 '~' 收尾。
// ----------------------------------------------------------------------
stock void HUD_CopyPanelText(const char[] source, char[] output, int maxlen, int budget)
{
	output[0] = '\0';
	if (budget > maxlen - 1) budget = maxlen - 1;
	if (budget <= 0) return;

	int length = strlen(source);
	bool shortened = length > budget;
	int limit = shortened ? budget - 1 : budget;
	int pos = 0;
	while (pos < length)
	{
		int bytes = GetCharBytes(source[pos]);
		if (bytes < 1 || pos + bytes > length || pos + bytes > limit) break;
		for (int i = 0; i < bytes; i++) output[pos + i] = source[pos + i];
		pos += bytes;
	}
	if (pos < length && pos < budget) output[pos++] = '~';
	output[pos] = '\0';
}

// 按面板剩余字节安全地画一行：面板满了就丢掉这一行，避免引擎把一个汉字切一半。
stock void HUD_DrawPanelText(Panel panel, const char[] text, int limit = PANEL_TEXT_LIMIT)
{
	int remaining = panel.TextRemaining;
	if (remaining < 0)	// 非 radio 面板(没有字节预算概念)时保持原样绘制
	{
		if (text[0]) panel.DrawText(text);
		return;
	}

	remaining -= 1;		// 留 1 字节给结束符
	if (remaining <= 0) return;
	if (limit > remaining) limit = remaining;

	static char line[512];
	HUD_CopyPanelText(text, line, sizeof(line), limit);
	if (line[0]) panel.DrawText(line);
}

// 多人模式下按面板字节预算给每行名字定长度：
// 511 字节要装 12 生还者 + 12 感染者，名字只能按人头均分剩下的空间。
// 预算 = (面板总字节 - 固定行预留 - 每行固定开销 × 行数) / 行数，再夹到 [MIN, MAX]。
// 非多人模式或没人时置 0（=不缩名）。
void PrepareMultiNameBudget()
{
	g_iMultiNameBudget = 0;

	if (!bMultiPlayer)
		return;

	int rows = 0;
	for (int client = 1; client <= MaxClients; ++client)
	{
		if (!IsClientInGame(client))
			continue;

		int team = GetClientTeam(client);
		if (team == L4D2Team_Survivor || team == L4D2Team_Infected)
			rows++;
	}
	if (rows <= 0)
		return;

	int available = PANEL_TEXT_LIMIT - MULTI_FIXED_RESERVE - rows * MULTI_ROW_OVERHEAD;
	g_iMultiNameBudget = available / rows;

	if (g_iMultiNameBudget < MULTI_NAME_MIN)
		g_iMultiNameBudget = MULTI_NAME_MIN;
	else if (g_iMultiNameBudget > MULTI_NAME_MAX)
		g_iMultiNameBudget = MULTI_NAME_MAX;
}

// 名字绘制统一入口：多人模式下按 g_iMultiNameBudget 缩短（超出用 '~' 收尾）
stock void GetClientShortName(int client, char[] name, int length)
{
	GetClientFixedName(client, name, length);

	if (g_iMultiNameBudget <= 0)
		return;

	static char shortName[MAX_NAME_LENGTH];
	HUD_CopyPanelText(name, shortName, sizeof(shortName), g_iMultiNameBudget);
	strcopy(name, length, shortName);
}

// 多人模式的特感职业名：只留 1 个汉字，省掉 "Charger"(7 字节) 这类英文名的空间
stock void GetShortInfectedClassName(int zClass, char[] buffer, int maxlen)
{
	switch (zClass)
	{
		case L4D2Infected_Smoker:	strcopy(buffer, maxlen, "烟");
		case L4D2Infected_Boomer:	strcopy(buffer, maxlen, "胖");
		case L4D2Infected_Hunter:	strcopy(buffer, maxlen, "猎");
		case L4D2Infected_Spitter:	strcopy(buffer, maxlen, "喷");
		case L4D2Infected_Jockey:	strcopy(buffer, maxlen, "猴");
		case L4D2Infected_Charger:	strcopy(buffer, maxlen, "冲");
		case L4D2Infected_Witch:	strcopy(buffer, maxlen, "巫");
		case L4D2Infected_Tank:		strcopy(buffer, maxlen, "坦");
		default:					strcopy(buffer, maxlen, "特");
	}
}

/* Reads the reserve slot through the weapon's own ammo type, so every gun
 * (MP5, M60, and any added later) resolves without a hand-kept table. */
stock int GetWeaponExtraAmmo(int client, int weapon)
{
	if (weapon <= 0)
		return -1;

	int ammoType = GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType");
	if (ammoType < 0)
		return -1;

	return GetEntProp(client, Prop_Send, "m_iAmmo", _, ammoType);
}

stock int GetWeaponClipAmmo(int weapon)
{
	return (weapon > 0 ? GetEntProp(weapon, Prop_Send, "m_iClip1") : -1);
}

stock void GetClientFixedName(int client, char[] name, int length)
{
	GetClientName(client, name, length);

	ValvePanel_ShiftInvalidString(name, length);

	if (strlen(name) > 12)
	{
		name[9] = name[10] = name[11] = '.';
		name[12] = '\0';
	}
}

stock bool ValvePanel_ShiftInvalidString(char[] str, int maxlen)
{
	switch (str[0])
	{
	case '[':
		{
			char[] temp = new char[maxlen];
			strcopy(temp, maxlen, str) + 1;
			
			int size = strcopy(str[1], maxlen-1, temp) + 1;
			
			str[0] = ' ';
			str[size < maxlen ? size : maxlen-1] = '\0';
			
			return true;
		}
	}
	
	return false;
}

//stock int GetRealTeam(int team)
//{
//	return team ^ view_as<int>(InSecondHalfOfRound() != GameRules_GetProp("m_bAreTeamsFlipped"));
//}

stock int GetRealClientCount()
{
	int clients = 0;
	for (int i = 1; i <= MaxClients; ++i)
	{
		if (IsClientConnected(i) && !IsFakeClient(i)) clients++;
	}
	return clients;
}

stock int GetVersusProgressDistance(int teamIndex)
{
	int distance = 0;
	for (int i = 0; i < 4; ++i)
	{
		distance += GameRules_GetProp("m_iVersusDistancePerSurvivor", _, i + 4 * teamIndex);
	}
	return distance;
}

/*
 * Future use
 */
stock void FillScavengeScores(int arr[2][5])
{
	for (int i = 1; i <= GetScavengeRoundLimit(); ++i)
	{
		arr[0][i-1] = GetScavengeTeamScore(0, i);
		arr[1][i-1] = GetScavengeTeamScore(1, i);
	}
}

stock int FormatScavengeRoundTime(char[] buffer, int maxlen, int teamIndex, bool nodecimalpoint = false)
{
	float seconds = GetScavengeRoundDuration(teamIndex);
	int minutes = RoundToFloor(seconds) / 60;
	seconds -= 60 * minutes;
	
	return nodecimalpoint ?
				FormatEx(buffer, maxlen, "%d:%02.0f", minutes, seconds) :
				FormatEx(buffer, maxlen, "%d:%05.2f", minutes, seconds);
}

/*
 * GetScavengeRoundDuration & GetScavengeTeamScore
 * credit to ProdigySim
 */
stock float GetScavengeRoundDuration(int teamIndex)
{
	float flRoundStartTime = GameRules_GetPropFloat("m_flRoundStartTime");
	if (teamIndex == view_as<int>(GameRules_GetProp("m_bAreTeamsFlipped")) && flRoundStartTime != 0.0 && GameRules_GetPropFloat("m_flRoundEndTime") == 0.0)
	{
		// Survivor team still playing round.
		return GetGameTime() - flRoundStartTime;
	}
	return GameRules_GetPropFloat("m_flRoundDuration", teamIndex);
}

stock int GetScavengeTeamScore(int teamIndex, int round=-1)
{
	if (!(1 <= round <= 5))
	{
		round = GameRules_GetProp("m_nRoundNumber");
	}
	return GameRules_GetProp("m_iScavengeTeamScore", _, (2*(round-1)) + teamIndex);
}

stock int GetScavengeMatchScore(int teamIndex)
{
	return GameRules_GetProp("m_iScavengeMatchScore", _, teamIndex);
}

stock int GetScavengeRoundNumber()
{
	return GameRules_GetProp("m_nRoundNumber");
}

stock int GetScavengeRoundLimit()
{
	return GameRules_GetProp("m_nRoundLimit");
}

stock int GetFurthestSurvivorFlow()
{
	int flow = RoundToNearest(100.0 * (L4D2_GetFurthestSurvivorFlow() + fVersusBossBuffer) / L4D2Direct_GetMapMaxFlowDistance());
	return flow < 100 ? flow : 100;
}

//stock float GetClientFlow(int client)
//{
//	return (L4D2Direct_GetFlowDistance(client) / L4D2Direct_GetMapMaxFlowDistance());
//}

stock int GetHighestSurvivorFlow()
{
	int flow = -1;
	
	int client = L4D_GetHighestFlowSurvivor();
	if (client > 0) {
		flow = RoundToNearest(100.0 * (L4D2Direct_GetFlowDistance(client) + fVersusBossBuffer) / L4D2Direct_GetMapMaxFlowDistance());
	}
	
	return flow < 100 ? flow : 100;
}

stock int GetRoundTankFlow()
{
	return RoundToNearest(L4D2Direct_GetVSTankFlowPercent(InSecondHalfOfRound()) + fVersusBossBuffer / L4D2Direct_GetMapMaxFlowDistance());
}

stock int GetRoundWitchFlow()
{
	return RoundToNearest(L4D2Direct_GetVSWitchFlowPercent(InSecondHalfOfRound()) + fVersusBossBuffer / L4D2Direct_GetMapMaxFlowDistance());
}

stock bool RoundHasFlowTank()
{
	return L4D2Direct_GetVSTankToSpawnThisRound(InSecondHalfOfRound());
}

stock bool RoundHasFlowWitch()
{
	return L4D2Direct_GetVSWitchToSpawnThisRound(InSecondHalfOfRound());
}
