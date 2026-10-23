#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#undef REQUIRE_PLUGIN
#include <l4d2_fix_team_shuffle_edi>
#define REQUIRE_PLUGIN

#pragma semicolon 1; // Force strict semicolon mode.
#pragma newdecls required; 

// *********************************************************************************
// CONSTANTS
// *********************************************************************************
#define PLUGIN_VERSION "2.5.10-12v12"
#define CVAR_FLAGS			FCVAR_NOTIFY
#define TEAM_SPECTATOR	               1
#define TEAM_SURVIVOR	               2
#define TEAM_INFECTED	               3
#define DELAY_KICK_NONEEDBOT         0.7
#define DELAY_KICK_FAKECLIENT        0.1
/* 队伍修正插件锁队还原队伍期间，自动进队要无限期等待（不消耗 JoinAttempts 的次数）。
   这里给一个独立的秒数上限，正常换图还原几秒内就结束，120 秒足以覆盖最慢的情况。 */
#define LOCK_WAIT_MAX_SECONDS        120
#define ZC_ZOMBIE                      0
#define ZC_SMOKER                      1
#define ZC_BOOMER                      2
#define ZC_HUNTER                      3
#define ZC_SPITTER                     4
#define ZC_JOCKEY                      5
#define ZC_CHARGER                     6
#define ZC_WITCH                       7
#define ZC_TANK                        8

char gameMode[16];
char gameName[16];
bool L4D1;
bool InfectedAllowed;

// m_survivorCharacter order in L4D2: Nick, Rochelle, Coach, Ellis,
// Bill, Zoey, Francis, Louis. L4D1 uses the last four models with IDs 0..3.
static const char SurvivorModels[][] =
{
	"models/survivors/survivor_gambler.mdl",
	"models/survivors/survivor_producer.mdl",
	"models/survivors/survivor_coach.mdl",
	"models/survivors/survivor_mechanic.mdl",
	"models/survivors/survivor_namvet.mdl",
	"models/survivors/survivor_teenangst.mdl",
	"models/survivors/survivor_biker.mdl",
	"models/survivors/survivor_manager.mdl"
};
bool SurvivorMapReady;
bool SurvivorModelErrorLogged[8];
int SurvivorModelsReady;
int TakeoverBlocked;
int SurvivorCharacterRepairs;
float NextTakeoverWarning;

ConVar SurvivorLimit;
ConVar InfectedLimit;

ConVar L4DInfectedLimit;
ConVar L4DSurvivorLimit;
ConVar GhostDelayMax;
ConVar L4DHooks;
ConVar L4DTown;
ConVar GameType;
ConVar SurvMaxIncap;
ConVar PainPillsDR;
ConVar MinionLimit;

ConVar KillRes;
ConVar RespawnJoin;
ConVar MoreSiBotsVersus;
ConVar AutoJoin;
ConVar Management;
ConVar AllowSpectate;
ConVar BlockSpecInTank;
ConVar SuppressSpectate;
float NextSpectateNotice[MAXPLAYERS + 1];
int QueuedPummelOffset = -1;

ConVar SiSpMoreDelay;
ConVar cvar_minsurvivor;
ConVar RoundStateCache;

Handle SubDirector					= null;
Handle BotsUpdateTimer				= null;
Handle EmptyServerTimer = null;
Handle TeamPanelTimer[MAXPLAYERS+1];
Handle JoinTimer[MAXPLAYERS+1];
bool JoinPending[MAXPLAYERS+1];
bool JoinAutomatic[MAXPLAYERS+1];
bool NewConnection[MAXPLAYERS+1];
int JoinTarget[MAXPLAYERS+1];
int JoinAttempts[MAXPLAYERS+1];
int LockWaitSeconds[MAXPLAYERS+1];	// 因队伍修正锁队而等待的秒数（单独计数，不占 JoinAttempts）
bool SurvivorPlaceholder[MAXPLAYERS+1];
bool SurvivorDied[MAXPLAYERS+1];
bool LateLoad;

enum JoinResult
{
	Join_Success,
	Join_Wait,
	Join_Failed
};

bool RoundStarted = false;

float SiTimes[MAXPLAYERS+1] = {0.0, ...};


StringMap SteamIDs;
StringMap TransitionPlayers;
StringMap DeadSurvivors;

public Plugin myinfo =
{
	name        = "Super Versus Reloaded",
	author      = "DDRKhat, Marcus101RR, Merudo, Foxhound27, Senip, RainyDagger, Shao",
	description = "Multiplayer capacity, team joining and AI filling; no automatic AFK, item grants or difficulty scaling.",
	version     = PLUGIN_VERSION,
	url         = "https://forums.alliedmods.net/showthread.php?p=2704058#post2704058"
}

// *********************************************************************************
// METHODS FOR GAME START & END
// *********************************************************************************
public void OnPluginStart()
{
	GetGameFolderName(gameName, sizeof(gameName));
	L4D1 = StrEqual(gameName, "left4dead", false);

	ConVar version = CreateConVar("sm_superversus_version", PLUGIN_VERSION, "L4D Super Versus 插件版本", CVAR_FLAGS|FCVAR_DONTRECORD);
	version.SetString(PLUGIN_VERSION); // Existing ConVars survive a plugin reload.
	
	L4DSurvivorLimit = FindConVar("survivor_limit");
	L4DInfectedLimit = FindConVar("z_max_player_zombies");
	SurvivorLimit = CreateConVar("l4d_survivor_limit", "12", "生还者最大人数", CVAR_FLAGS,true, 1.00, true, 24.00);
	InfectedLimit = CreateConVar("l4d_infected_limit", "12", "特感最大人数（不影响 AI 特感）", CVAR_FLAGS, true, 4.00, true, 24.00);
	cvar_minsurvivor = CreateConVar("l4d_static_minimum_survivor", "12", "生还者队最低人数（不足时自动补 AI bot）", CVAR_FLAGS, true, 4.00, true, 24.00);

	// Remove limits for survivor/infected
	SetConVarBounds(L4DSurvivorLimit, ConVarBound_Upper, true, 24.0);
	SetConVarBounds(L4DInfectedLimit, ConVarBound_Upper, true, 24.0);
	HookConVarChange(InfectedLimit, OnInfectedChanged);	HookConVarChange(L4DInfectedLimit, OnInfectedChanged);
	HookConVarChange(SurvivorLimit, OnSurvivorChanged);	HookConVarChange(L4DSurvivorLimit, OnSurvivorChanged);

	KillRes = CreateConVar("l4d_killreservation","0","是否清除大厅预留（需要 Left4Downtown / Left4DHooks）", CVAR_FLAGS,true,0.0,true,1.0);
	
	RespawnJoin = CreateConVar("l4d_respawn_on_join", "1" , "额外生还者加入时是否直接复活。0=否；1=是（仅首次）", CVAR_FLAGS, true, 0.0, true, 1.0);
	MoreSiBotsVersus =  CreateConVar("l4d_versus_si_more", "1" , "对抗/清道夫里真人特感不足 l4d_infected_limit 时，是否用 AI 特感补位", CVAR_FLAGS, true, 0.0, true, 1.0);
	AutoJoin = CreateConVar("l4d_autojoin", "2" , "新连接入队。3=旁观；2=战役进生还者/对抗补真人较少一方，同数随机；1=弹出队伍菜单；0=不处理", CVAR_FLAGS, true, 0.0, true, 3.0);
	Management = CreateConVar("l4d_management", "3", "队伍管理权限。3=队伍菜单+命令；2=仅命令；1=仅 !infected/!survivor/!join；0=无", CVAR_FLAGS, true, 0.0, true, 4.0);
	SiSpMoreDelay  = CreateConVar("director_si_more_delay","5","对抗中 AI 特感出生时，额外加到 z_ghost_delay_max 上的延迟（秒）", CVAR_FLAGS);
	
	//Cache CVArs
	GhostDelayMax = FindConVar("z_ghost_delay_max");
	L4DHooks = FindConVar("left4dhooks_version");
	L4DTown = FindConVar("left4downtown_version");
	GameType = FindConVar("mp_gamemode");
	SurvMaxIncap = FindConVar("survivor_max_incapacitated_count");
	PainPillsDR = FindConVar("pain_pills_decay_rate");
	MinionLimit = FindConVar("z_minion_limit");
	
	// 入队命令统一门禁：sm_join / sm_jg / sm_survivor / sm_sur / sm_infected / sm_inf
	// 全部经 RequestJoin() -> TryJoinTeam()，在 TryJoinTeam 开头由 TeamChangesLocked()
	// 拦截（l4d2_fix_team_shuffle_edi 尚未修复完队伍时一律返回 Join_Wait），
	// 再由 RequestJoin 的 QueueJoin 逐秒重试，队伍修复完成后的下一次重试才真正换队。
	RegConsoleCmd("sm_join", Join_Game, "Join Survivor or Infected team");
	RegConsoleCmd("sm_jg", Join_Game, "Join Survivor or Infected team");
	//RegConsoleCmd("sm_multistatus", MultiStatus, "Show actual multiplayer limits and pending joins");
	RegConsoleCmd("sm_survivor", Join_Survivor, "Join Survivor Team");
	RegConsoleCmd("sm_sur", Join_Survivor, "Join Survivor Team");
	RegConsoleCmd("sm_infected", Join_Infected, "Join Infected Team");
	RegConsoleCmd("sm_inf", Join_Infected, "Join Infected Team");
	RegConsoleCmd("sm_spectate", Join_Spectator, "Join Spectator Team");
	RegConsoleCmd("sm_spec", Join_Spectator, "Join Spectator Team");
	RegConsoleCmd("sm_s", Join_Spectator, "Join Spectator Team");
	AllowSpectate = CreateConVar("sm_allow_spectate_command", "1", "Allow !spectate/!spec/!s");
	BlockSpecInTank = CreateConVar("sm_blockspecintank", "0", "Block survivor spectating during a Tank", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	SuppressSpectate = CreateConVar("l4d_pm_supress_spectate", "0", "Don't announce spectator moves");
	GameData teamData = new GameData("l4d2_si_ability");
	if (teamData == null) SetFailState("Missing l4d2_si_ability gamedata");
	QueuedPummelOffset = teamData.GetOffset("CTerrorPlayer->m_queuedPummelAttacker");
	delete teamData;
	if (QueuedPummelOffset == -1) SetFailState("Missing CTerrorPlayer->m_queuedPummelAttacker offset");
	//RegConsoleCmd("sm_teams", TeamMenu, "Opens Team Panel with Selection");
	//RegConsoleCmd("sm_changeteam", TeamMenu, "Opens Team Panel with Selection");
	RegAdminCmd("sm_createplayer", Create_Player, ADMFLAG_CONVARS, "Create Survivor Bot");

	HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);
	HookEvent("player_bot_replace", Event_BotReplacedPlayer);
	HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);
	HookEvent("player_left_start_area", Event_PlayerLeftStartArea, EventHookMode_Post);
	HookEvent("player_left_checkpoint", Event_PlayerLeftStartArea, EventHookMode_Post);
	HookEvent("round_start", Event_RoundStart, EventHookMode_Post);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_Pre);
	HookEvent("finale_vehicle_leaving", Event_FinaleVehicleLeaving);

	AddCommandListener(Cmd_spec_next, "spec_next");
	AddCommandListener(Cmd_JoinTeam, "jointeam");
	AddCommandListener(Cmd_StaySpectator, "sm_spec");
	AddCommandListener(Cmd_StaySpectator, "sm_s");
	AddCommandListener(Cmd_StaySpectator, "sm_spectate");
	// sm_afk 命令注册已取消，同名监听一并取消；恢复注册时同时恢复此行。
	//AddCommandListener(Cmd_StaySpectator, "sm_afk");
	AddCommandListener(Cmd_StaySpectator, "go_away_from_keyboard");
	
	SteamIDs = new StringMap();
	TransitionPlayers = new StringMap();
	DeadSurvivors = new StringMap();
	RoundStateCache = CreateConVar("l4d_superversus_round_state", "", "Internal round state for plugin reloads", FCVAR_DONTRECORD|FCVAR_HIDDEN);

	// Core settings are owned by the mode CFG. Do not execute a legacy
	// l4d_superversus.cfg containing removed features or stale team limits.

	/* 12v12 容量初始化必须放在本函数最末尾（所有 ConVar 都建好之后）：
	   给 l4d_survivor_limit 赋值会同步触发 survivor_limit 的变更钩子
	   （12v12/playermanagement.sp::survivor_limitChanged -> FixBotCount），
	   而 FixBotCount 里的 CreateFakeClient() 会让引擎立刻回调本插件的
	   OnClientPostAdminCheck；那一刻 KillRes / AutoJoin 等 ConVar 还没创建（句柄 0），
	   直接读 .BoolValue 就抛 "Invalid convar handle 0 (error 4)"。
	   日志证据：OnPluginStart:150 -> Initialize12v12Capacity:229 -> OnSurvivorChanged:223
	   -> survivor_limitChanged:154 -> FixBotCount:531(CreateFakeClient)
	   -> OnClientPostAdminCheck:755 (KillRes.BoolValue)。 */
	Initialize12v12Capacity();
}

public void OnInfectedChanged (Handle c, const char[] o, const char[] n)  {L4DInfectedLimit.IntValue = InfectedLimit.IntValue;}
public void OnSurvivorChanged (Handle c, const char[] o, const char[] n)  {L4DSurvivorLimit.IntValue = SurvivorLimit.IntValue;}

// This binary belongs exclusively to optional/12v12. Existing ConVars survive
// plugin reloads, so defaults alone cannot replace an old 4/4 setting.
void Initialize12v12Capacity()
{
	SurvivorLimit.IntValue = 12;
	InfectedLimit.IntValue = 12;
	cvar_minsurvivor.IntValue = 12;
	SyncTeamLimits();
}

void SyncTeamLimits()
{
	L4DSurvivorLimit.IntValue = SurvivorLimit.IntValue;
	L4DInfectedLimit.IntValue = InfectedLimit.IntValue;
}

public void OnConfigsExecuted()
{
	GameType.GetString(gameMode, sizeof(gameMode));
	InfectedAllowed = AreInfectedAllowed();
	SyncTeamLimits();
	if (LateLoad)
	{
		LateLoad = false;
		RestoreRunningRound();
	}
	if (!SvBotsAllowed()) QueueEmptyBotCleanup();
}

public void OnClientPutInServer(int client)
{
	NextSpectateNotice[client] = 0.0;
	CancelJoin(client);
	SurvivorPlaceholder[client] = false;
	if (!IsFakeClient(client)) ResumeBotPopulation();
	else if (!SvBotsAllowed()) QueueEmptyBotCleanup();
}

// PutInServer may precede authentication. PostAdminCheck retries this once the
// human is both in game and authenticated; connecting/loading clients do not count.
void ResumeBotPopulation()
{
	if (!SvBotsAllowed()) return;
	delete EmptyServerTimer;
	if (!RoundStarted) return;
	delete BotsUpdateTimer;
	BotsUpdateTimer = CreateTimer(0.2, Timer_BotsUpdate, _, TIMER_FLAG_NO_MAPCHANGE);
	StartInfectedCounter();
}

void QueueEmptyBotCleanup()
{
	// Keep the first deadline so repeated engine bot joins cannot postpone cleanup.
	if (EmptyServerTimer == null)
		EmptyServerTimer = CreateTimer(0.2, Timer_RecycleBotsOnEmpty, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void OnClientConnected(int client)
{
	// PutInServer/PostAdminCheck run again on maps and late plugin loads. Only a
	// connection observed here may override the engine's initial team assignment.
	CancelJoin(client);
	SurvivorDied[client] = false;
	NewConnection[client] = !IsFakeClient(client);
}


public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	LateLoad = late;
	RegPluginLibrary("applemod12v12_multiplayer");
	CreateNative("SV12_CanManageTeams", Native_CanManageTeams);
	CreateNative("SV12_RequestTeam", Native_RequestTeam);
	CreateNative("SV12_GetHumanTeam", Native_GetHumanTeam);
	CreateNative("SV12_ReconcileSurvivors", Native_ReconcileSurvivors);
	MarkNativeAsOptional("L4D_LobbyUnreserve");
	return APLRes_Success;
}

bool CanManageTeams()
{
	return SurvivorMapReady && Management != null && Management.BoolValue
		&& L4D_IsVersusMode() && !TeamChangesLocked();
}

public any Native_CanManageTeams(Handle plugin, int numParams)
{
	return CanManageTeams();
}

public any Native_GetHumanTeam(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (!IsValidClient(client) || IsFakeClient(client)) return 0;
	return GetBotOfIdle(client) > 0 ? TEAM_SURVIVOR : GetClientTeam(client);
}

public any Native_RequestTeam(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	int team = GetNativeCell(2);
	if (!CanManageTeams() || !IsValidClient(client) || IsFakeClient(client)
		|| team < TEAM_SPECTATOR || team > TEAM_INFECTED) return false;
	NewConnection[client] = false;
	CancelJoin(client);
	// Admin requests still use the same lock, human capacity, owned-bot and
	// death checks. Only the voluntary-spectator policy is skipped.
	JoinResult result = TryJoinTeam(client, team, false, true);
	if (result == Join_Wait && team != TEAM_SPECTATOR)
	{
		QueueJoin(client, team, false, 0.3);
		return true;
	}
	return result == Join_Success;
}

public any Native_ReconcileSurvivors(Handle plugin, int numParams)
{
	if (!CanManageTeams() || !RoundStarted) return false;
	ReconcileSurvivors();
	return true;
}

void ReconcileSurvivors()
{
	int count;
	for (int client = 1; client <= MaxClients; client++)
		if (IsClientInGame(client) && GetClientTeam(client) == TEAM_SURVIVOR
			&& !IsClientInKickQueue(client)) count++;
	int limit = SurvivorLimit.IntValue;
	for (int bot = MaxClients; bot >= 1 && count > limit; bot--)
	{
		if (!IsValidSurvivorBot(bot) || IsClientInKickQueue(bot) || SurvivorPlaceholder[bot]
			|| HasIdlePlayer(bot)) continue;
		// Detach before the asynchronous kick, so repeated checks count it once.
		ChangeClientTeam(bot, TEAM_SPECTATOR);
		KickClient(bot, "Removing excess unowned survivor bot");
		count--;
	}
	SpawnCheck();
}

void RestoreRunningRound()
{
	// A late load misses round_start and safe-area exit events. Preserve an ended
	// round across reloads; upgrading from an older build falls back to survivors.
	if (RoundStarted || !IsServerProcessing()) return;
	if (!L4D1 && GameRules_GetProp("m_bIsTransitioningToNextMap")) return;
	char state[PLATFORM_MAX_PATH], expected[PLATFORM_MAX_PATH], map[PLATFORM_MAX_PATH];
	GetCurrentMap(map, sizeof(map));
	RoundStateCache.GetString(state, sizeof(state));
	Format(expected, sizeof(expected), "%s:0", map);
	if (StrEqual(state, expected)) return;
	Format(expected, sizeof(expected), "%s:1", map);
	bool knownActive = StrEqual(state, expected);
	bool aliveSurvivor;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || GetClientTeam(client) != TEAM_SURVIVOR) continue;
		if (IsPlayerAlive(client)) aliveSurvivor = true;
		if (!IsFakeClient(client))
		{
			RecordSteamID(client);
			SetSurvivorDeath(client, !IsPlayerAlive(client));
		}
		else if (GetIdlePlayer(client) > 0)
		{
			int owner = GetIdlePlayer(client);
			RecordSteamID(owner);
			SetSurvivorDeath(owner, !IsPlayerAlive(client));
		}
	}
	if (!knownActive && !aliveSurvivor) return;
	RoundStarted = true;
	CacheRoundState(true);
	StartRoundTimers();
}

void CacheRoundState(bool active)
{
	char map[PLATFORM_MAX_PATH], state[PLATFORM_MAX_PATH];
	GetCurrentMap(map, sizeof(map));
	Format(state, sizeof(state), "%s:%d", map, active);
	RoundStateCache.SetString(state);
}

// ------------------------------------------------------------------------
// Return true if the lobby-unreserve provider is available
// ------------------------------------------------------------------------
bool l4dt()
{
	if(L4DHooks != null || L4DTown != null)
	{
		return true;
	}
	return false;
} // Is Left4DHooks OR Left 4 Downtown 1/2 loaded? 

public void OnMapStart() 
{
	SurvivorMapReady = true;
	SurvivorModelsReady = 0;
	NextTakeoverWarning = 0.0;
	for (int i = 0; i < sizeof(SurvivorModelErrorLogged); i++) SurvivorModelErrorLogged[i] = false;
	EnsureSurvivorModels();
	GameType.GetString(gameMode, sizeof(gameMode));
	InfectedAllowed = AreInfectedAllowed();
	if (!LateLoad) CacheRoundState(false);
}

// ------------------------------------------------------------------------
// OnMapEnd()
// ------------------------------------------------------------------------
public void OnMapEnd()
{
	// Do not restore idle players through TakeOverBot while the map is unloading.
	SurvivorMapReady = false;
	SurvivorModelsReady = 0;
	delete EmptyServerTimer;
	// Some game transitions reconnect players. Preserve those players' teams even
	// when the engine produces another Connected/PostAdminCheck callback pair.
	TransitionPlayers.Clear();
	char auth[MAX_AUTHID_LENGTH];
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientConnected(client) && !IsFakeClient(client)
			&& GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth)))
			TransitionPlayers.SetValue(auth, true);
		NewConnection[client] = false;
	}
	GameEnd();
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	GameEnd();
}

// ------------------------------------------------------------------------
//  Clean up the timers at the game end
// ------------------------------------------------------------------------
void GameEnd()
{
	RoundStarted = false;
	CacheRoundState(false);
	delete SubDirector;
	delete BotsUpdateTimer;
	
	for(int i = 1; i <= MaxClients; i++)
	{
		delete JoinTimer[i];
		delete TeamPanelTimer[i];
		if (SurvivorMapReady) TakeOver(i);
	}

	// Reset SteamIDs, so previous players who join next round can respawn alive
	SteamIDs.Clear();
	
	for (int i = 0; i < sizeof(SiTimes); i++) SiTimes[i] = 0.0;
}

// ------------------------------------------------------------------------
// Event_RoundStart
// ------------------------------------------------------------------------
public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	RoundStarted = true;
	CacheRoundState(true);
	DeadSurvivors.Clear();
	for (int client = 1; client <= MaxClients; client++) SurvivorDied[client] = false;
	for (int i = 0; i < sizeof(SiTimes); i++) SiTimes[i] = 0.0;
	delete SubDirector;
	StartRoundTimers();
}

void StartRoundTimers()
{
	for (int client = 1; client <= MaxClients; client++)
	{
		delete JoinTimer[client];
		if (JoinPending[client] && IsClientInGame(client) && !IsFakeClient(client))
		{
			JoinAttempts[client] = 0;
			JoinTimer[client] = CreateTimer(0.5, Timer_AutoJoinTeam, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
		}
	}
	delete BotsUpdateTimer;
	BotsUpdateTimer = CreateTimer(0.2, Timer_BotsUpdate, _, TIMER_FLAG_NO_MAPCHANGE);
	StartInfectedCounter();
}



// ------------------------------------------------------------------------
// Stop filling teams after rescue; the engine decides who actually escaped.
// ------------------------------------------------------------------------
public void Event_FinaleVehicleLeaving(Event event, const char[] name, bool dontBroadcast)
{
	GameEnd();
}

// *********************************************************************************
// METHODS RELATED TO PLAYER/BOT SPAWN AND KICK
// *********************************************************************************

// ------------------------------------------------------------------------
//  Each time a survivor spawns, setup timer to kick / spawn bots a bit later
// ------------------------------------------------------------------------
public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!IsValidClient(client)) return;
	if (IsFakeClient(client) && !SvBotsAllowed())
	{
		QueueEmptyBotCleanup();
		return;
	}
	
	// Adds very brief invulnerability to spawned SI infected bots in versus/scavenge. Otherwise they keep respawning dead
	if (GetClientTeam(client) == TEAM_INFECTED && InfectedAllowed && MoreSiBotsVersus.BoolValue && IsFakeClient(client)) SetGodMode(client, 0.1);
	
	// Each survivor spawn updates bot capacity and records respawn eligibility.
	if (GetClientTeam(client) == TEAM_SURVIVOR)
	{
		if (IsPlayerAlive(client))
		{
			int owner = IsFakeClient(client) ? GetIdlePlayer(client) : client;
			if (owner > 0) SetSurvivorDeath(owner, false);
		}
		if (RoundStarted)
		{
			delete BotsUpdateTimer;
			BotsUpdateTimer = CreateTimer(2.0, Timer_BotsUpdate, _, TIMER_FLAG_NO_MAPCHANGE);
		}
		
		if (!IsFakeClient(client) && !InfectedAllowed && IsFirstTime(client))
			RecordSteamID(client); // Record SteamID of player.
			
		SetGhostStatus(client, false); // Prevents invinsible & invisible survivor bug
	}
	
	//  If Si bot spawns, remove oldest Si in queue
	if (IsFakeClient(client) && GetClientTeam(client) == TEAM_INFECTED
		&& GetSiType(client) >= ZC_SMOKER && GetSiType(client) <= ZC_CHARGER)
	{
		int OldestSi = GetOldestSi();
		if (OldestSi != -1) SiTimes[OldestSi] = 0.0;
	}
}


public int GetClientZC(int client)
{

	if (!IsValidEntity(client) || !IsValidEdict(client))
	{
		return 0;
	}
	return GetEntProp(client, Prop_Send, "m_zombieClass");
}

////////////////////////////////////////////////////////////////////


////////////////////////////////////////////////////////////////////

////////////////////////////////////////////////////////////////////

////////////////////////////////////////////////////////////////////

bool IsValidClient(int client)
{
	if (! (1 <= client <= MaxClients) || !IsClientInGame(client)) return false;

	return true;
}

////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////

// ------------------------------------------------------------------------
// If a player disconnects, update survivor bot capacity.
// ------------------------------------------------------------------------
public void OnClientDisconnect(int client)
{
	CancelJoin(client);
	NewConnection[client] = false;
	SurvivorPlaceholder[client] = false;

	delete TeamPanelTimer[client];			//	Clean up Panel timer

	if(RoundStarted && SvBotsAllowed())
	{
		// Reset the timer, if one exists
		delete BotsUpdateTimer;
		BotsUpdateTimer = CreateTimer(1.0, Timer_BotsUpdate, _, TIMER_FLAG_NO_MAPCHANGE);	// re-update the bots
	}
	
	// The disconnecting client may still be counted here. Check after disconnect.
	if (!IsFakeClient(client))
	{
		delete EmptyServerTimer;
		EmptyServerTimer = CreateTimer(1.5, Timer_RecycleBotsOnEmpty, _, TIMER_FLAG_NO_MAPCHANGE);
	}
}

// ------------------------------------------------------------------------
// 空服回收：真人全走光后延迟一下（等 disconnect 流程收尾）再回收 bot
// ------------------------------------------------------------------------
public Action Timer_RecycleBotsOnEmpty(Handle timer)
{
	EmptyServerTimer = null;
	if (SvBotsAllowed()) return Plugin_Stop;
	delete BotsUpdateTimer;
	delete SubDirector;
	for (int i = 0; i < sizeof(SiTimes); i++) SiTimes[i] = 0.0;
	SvRecycleSurvivorBots();
	SvRecycleInfectedBots();
	return Plugin_Stop;
}

// ------------------------------------------------------------------------
// Bots are kicked/spawned after every survivor spawned and every player joined
// ------------------------------------------------------------------------
public Action Timer_BotsUpdate(Handle hTimer)
{
	BotsUpdateTimer = null;

	if (RoundStarted)
	{

		SpawnCheck();

	}
	return Plugin_Stop;
}


// ------------------------------------------------------------------------
// Check the # of survivors, and kick/spawn bots as needed
// ------------------------------------------------------------------------
void SpawnCheck()
{
	if(RoundStarted != true)  return;      // if during transition, don't do anything
	
	// 只在真人已经完成进服和身份验证后补位；连接中、读图中均不算。
	if (!SvBotsAllowed())
	{
		SvRecycleSurvivorBots();
		return;
	}
	
	int iSurvivor       = GetSurvivorTeam();
	//int iHumanSurvivor  = InfectedAllowed ? GetTeamPlayers(TEAM_SURVIVOR, false) : GetHumanCount();  // survivors excluding bots but including idles. If coop, counts spectators too (may be idles)
	//int iSurvivorLim    = SurvivorLimit.IntValue;
	//int iSurvivorMax    = iHumanSurvivor  >  iSurvivorLim ? iHumanSurvivor  : iSurvivorLim ;
	
	// iSurvivorMax is the maximum # of survivor we allow - we never kick human survivors

	if (iSurvivor >= cvar_minsurvivor.IntValue)  return;
	for(; iSurvivor < cvar_minsurvivor.IntValue; iSurvivor++) SpawnFakeSurvivorClient();
}

// ------------------------------------------------------------------------
// Kick an unused survivor bot
// ------------------------------------------------------------------------

stock bool IsValidSurvivorBot(int client)
{
	if (!client) return false;
	if (!IsClientInGame(client)) return false;
	if (!IsFakeClient(client)) return false;
	if (GetClientTeam(client) != TEAM_SURVIVOR) return false;
	return true;
}
// ------------------------------------------------------------------------
// Spawn a survivor bot
// ------------------------------------------------------------------------

bool SpawnFakeSurvivorClient(const char[] botName = "SurvivorBot", bool manual = false)
{
	// Also covers manual/RCON creation and direct join requests.
	if (!SvBotsAllowed() || !EnsureSurvivorModels()) return false;
	int ClientsCount = GetSurvivorTeam();
	
	bool fakeclientKicked = false;
	
	// create fakeclient
	int fakeclient = 0;

	if (ClientsCount < SurvivorLimit.IntValue)
	{
		fakeclient = CreateFakeClient(botName);
	}
	
	// if entity is valid
	if (fakeclient != 0)
	{
		SurvivorPlaceholder[fakeclient] = true;
		// move into survivor team
		ChangeClientTeam(fakeclient, TEAM_SURVIVOR);
		
		// check if entity classname is survivorbot
		if (DispatchKeyValue(fakeclient, "classname", "survivorbot") == true)
		{
			// spawn the client
			if (DispatchSpawn(fakeclient) == true && PrepareSurvivorModel(fakeclient))
			{	
				if (manual)
				{
					if (!IsPlayerAlive(fakeclient)) Respawn(fakeclient);
					TeleportToSurvivor(fakeclient);
				}
				// kick the fake client to make the bot take over
				CreateTimer(DELAY_KICK_FAKECLIENT, Timer_KickFakeBot, GetClientUserId(fakeclient), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
				fakeclientKicked = true;
			}
		}			
		// if something went wrong, kick the created FakeClient
		if (fakeclientKicked == false) KickClient(fakeclient, "Kicking FakeClient");
	}
	return fakeclientKicked;
}

// ------------------------------------------------------------------------
// If lobby full, unreserve it. Autojoin survivors if coop & spectator
// ------------------------------------------------------------------------
public void OnClientPostAdminCheck(int client)
{
	/* 兜底：OnPluginStart 期间（其它插件给 survivor_limit 赋值 -> FixBotCount ->
	   CreateFakeClient）引擎会同步回调到这里，此时本插件靠后的 ConVar 可能还没创建，
	   句柄为 0，读 .BoolValue/.IntValue 会抛 "Invalid convar handle 0 (error 4)"。
	   等 ConVar 齐了以后的正常进服不受影响。 */
	if (KillRes == null || AutoJoin == null) return;

	// If lobby is full, KillRes is true and l4dt is present, unreserve lobby
	if(KillRes.BoolValue && IsServerLobbyFull() && l4dt())
	{
		L4D_LobbyUnreserve();
	}
	
	if (IsFakeClient(client)) return;
	ResumeBotPopulation();
	
	char auth[MAX_AUTHID_LENGTH];
	int returningPlayer;
	if (!GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth)))
	{
		// Without a stable identity, preserve an existing team rather than risk
		// treating a returning map connection as a new player.
		NewConnection[client] = false;
		return;
	}
	if (TransitionPlayers.GetValue(auth, returningPlayer))
	{
		TransitionPlayers.Remove(auth);
		NewConnection[client] = false;
	}
	if (!NewConnection[client]) return;
	// Initial engine autoassignment can already put a new player on infected.
	// It is not a manual choice and must still pass the human-count balancer.
	if (AutoJoin.IntValue > 0 && AutoJoin.IntValue < 3 && GetBotOfIdle(client) == 0)
		QueueJoin(client, AutoJoin.IntValue == 1 ? 4 : 0, true, 1.0);
	else NewConnection[client] = false;
}

// ------------------------------------------------------------------------
// If connect as spectator, either auto-join survivor or show team menu
// ------------------------------------------------------------------------
public Action Timer_AutoJoinTeam(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client <= 0 || JoinTimer[client] != timer) return Plugin_Stop;
	JoinTimer[client] = null;
	if (!JoinPending[client] || IsFakeClient(client)) return Plugin_Stop;
	if (!IsClientInGame(client))
	{
		if (++JoinAttempts[client] < 120)
			JoinTimer[client] = CreateTimer(1.0, Timer_AutoJoinTeam, userid, TIMER_FLAG_NO_MAPCHANGE);
		else
		{
			NewConnection[client] = false;
			CancelJoin(client);
		}
		return Plugin_Stop;
	}
	if (JoinAutomatic[client] && (!NewConnection[client]
		|| (JoinTarget[client] == 0 && GetBotOfIdle(client) > 0)
		|| AutoJoin.IntValue == 0 || AutoJoin.IntValue == 3))
	{
		NewConnection[client] = false;
		CancelJoin(client);
		return Plugin_Stop;
	}

	/* 队伍修正插件正在锁队还原换图队伍时，jointeam 会被它整段拦截，此刻既不能判失败、
	   也不能消耗 JoinAttempts 的次数（否则锁队久一点就会提前放弃并刷"没有位置"）。
	   这里单独计时等待，锁队一结束就立刻继续走原来的 SelectBalancedTeam -> TryJoinTeam。 */
	if (TeamChangesLocked())
	{
		if (++LockWaitSeconds[client] < LOCK_WAIT_MAX_SECONDS)
		{
			JoinTimer[client] = CreateTimer(1.0, Timer_AutoJoinTeam, userid, TIMER_FLAG_NO_MAPCHANGE);
			return Plugin_Stop;
		}
		// 等满上限（异常情况）才放弃，避免永久占着一个 pending 请求
		NewConnection[client] = false;
		CancelJoin(client);
		return Plugin_Stop;
	}
	LockWaitSeconds[client] = 0;

	JoinAttempts[client]++;
	JoinResult result = Join_Wait;
	if (RoundStarted)
	{
		if (JoinTarget[client] == 4)
		{
			if (!TeamChangesLocked()) DisplayTeamMenu(client);
			result = TeamChangesLocked() ? Join_Wait : Join_Success;
		}
		else
		{
			if (JoinAutomatic[client] && JoinTarget[client] == 0 && !TeamChangesLocked())
			{
				// Decide once for this request; a delayed bot takeover must not make
				// the same player oscillate between teams on successive retries.
				int team = SelectBalancedTeam(client);
				if (team > 0) JoinTarget[client] = team;
				else
				{
					// An engine/third-party initial assignment must not create a
					// thirteenth human seat after both configured teams are full.
					if (GetClientTeam(client) > TEAM_SPECTATOR) TryJoinTeam(client, TEAM_SPECTATOR, false, true);
					result = Join_Failed;
				}
			}
			if (result != Join_Failed) result = TryJoinTeam(client, JoinTarget[client], false);
		}
	}
	// 脱困：没排进去时不能把人留在"生还者队 + 已死亡"的槽位上，否则客户端会一直
	// 显示原生"点击加入游戏"的闲置提示却点不动，玩家就卡死在这个界面。
	bool rescued = (result != Join_Success) && RescueStuckDeadSurvivor(client);

	if (result == Join_Wait && JoinAttempts[client] < 120)
		JoinTimer[client] = CreateTimer(1.0, Timer_AutoJoinTeam, userid, TIMER_FLAG_NO_MAPCHANGE);
	else
	{
		if (JoinAutomatic[client]) NewConnection[client] = false;
		// 脱困时已经给过"已退回旁观"的提示，不再重复刷一条同样的消息
		if (result != Join_Success && !rescued)
			PrintToChat(client, "\x03[SV] \x01当前没有可加入的队伍位置，可按 M 或输入 !join 重试。");
		CancelJoin(client);
	}
	return Plugin_Stop;
}

/* ------------------------------------------------------------------------
* 生还者队里是否有"已死亡但仍占着名额"的成员（真人 / AI Bot / 挂机托管身体统一计入）。
* 有人躺着时，那几个席位要等下一回合复活，此刻把活人加进来就是超额，
* 所以生还者侧不算"有可用的活人位置"。
* 注意与 HasSurvivorDied(client) 区分：那个是"这名玩家本局死过"。
* ---------------------------------------------------------------------- */
bool HasDeadSurvivorSeat()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && GetClientTeam(i) == TEAM_SURVIVOR && !IsPlayerAlive(i))
			return true;
	}
	return false;
}

/* ------------------------------------------------------------------------
* 脱困处理：新玩家进服时引擎会先按默认把他放进生还者队；如果生还者队只剩死亡身体
* 占位，SafeTakeOverSurvivor 拿不到活 Bot、SpawnFakeSurvivorClient 也因名额被占满
* 而失败，玩家就一直停在"生还者队 + 已死亡"的槽位反复 Join_Wait。
* 此时客户端会显示原生的"点击加入游戏"闲置提示，而对抗没有可用闲置键 → 点了没反应、
* 卡死在那个界面。这里把他退回旁观并清掉残留的跟随观察态，让他能重新 !join / 按 M。
*
* 只处理"本次进服还没安置好"的新连接（NewConnection），
* 本局正常阵亡、正在等救援/复活的生还者不受影响。
* ---------------------------------------------------------------------- */
bool RescueStuckDeadSurvivor(int client)
{
	if (!IsValidClient(client) || IsFakeClient(client) || !IsClientInGame(client)) return false;
	if (!NewConnection[client]) return false;
	if (GetClientTeam(client) != TEAM_SURVIVOR || IsPlayerAlive(client)) return false;
	// 托管着自己 Bot 的玩家是正常的"死亡等复活"状态，不算卡住
	if (GetBotOfIdle(client) > 0) return false;

	ChangeClientTeam(client, TEAM_SPECTATOR);
	if (!IsClientInGame(client) || GetClientTeam(client) != TEAM_SPECTATOR) return false;

	// 伪闲置时代会在玩家身上留下 m_iObserverMode = 5（跟随观察），
	// 那正是"点击加入游戏没反应"的元凶；只在残留时清回 0，不动正常旁观模式。
	if (GetEntProp(client, Prop_Send, "m_iObserverMode") == 5)
		SetEntProp(client, Prop_Send, "m_iObserverMode", 0);

	PrintToChat(client, "\x03[SV] \x01当前没有可加入的位置，已退回旁观，可按 M 或输入 !join 重试。");
	return true;
}

int SelectBalancedTeam(int client)
{
	int survivors = GetTeamPlayers(TEAM_SURVIVOR, false);
	int infected = GetTeamPlayers(TEAM_INFECTED, false);
	// Compare everyone already admitted, excluding this new connection's default
	// engine seat. GetTeamPlayers(false) excludes AI but includes idle humans.
	int current = GetClientTeam(client);
	if (current == TEAM_SURVIVOR) survivors--;
	else if (current == TEAM_INFECTED) infected--;

	/* 生还者侧"可用"要同时满足：真人位置没满、且队里没有死亡生还者占着名额。
	   有人躺着时只能去特感；两边都不可用就返回 0，让调用方保持旁观并提示。 */
	bool survivorOpen = survivors < SurvivorLimit.IntValue && !HasDeadSurvivorSeat();
	bool infectedOpen = InfectedAllowed && infected < InfectedLimit.IntValue;

	if (!survivorOpen && !infectedOpen) return 0;
	if (!survivorOpen) return TEAM_INFECTED;
	if (!infectedOpen) return TEAM_SURVIVOR;
	if (survivors < infected) return TEAM_SURVIVOR;
	if (infected < survivors) return TEAM_INFECTED;
	return GetRandomInt(TEAM_SURVIVOR, TEAM_INFECTED);
}

void CancelJoin(int client)
{
	delete JoinTimer[client];
	JoinPending[client] = false;
	JoinAutomatic[client] = false;
	JoinAttempts[client] = 0;
	LockWaitSeconds[client] = 0;
}

void QueueJoin(int client, int team, bool automatic, float delay)
{
	CancelJoin(client);
	JoinPending[client] = true;
	JoinAutomatic[client] = automatic;
	JoinTarget[client] = team;
	JoinTimer[client] = CreateTimer(delay, Timer_AutoJoinTeam, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

// *********************************************************************************
// BOT REPLACED PLAYER
// *********************************************************************************

// ------------------------------------------------------------------------
// Bot took over a player: only schedule the "no longer needed bot" cleanup.
// 旧的伪闲置修复链与 AFK 事件监测已整块移除：
// 那套 L4D_SetHumanSpec + m_iObserverMode=5 的写法是给战役模式修引擎 idle bug 的，
// 在对抗里会把玩家置成跟随观察态，玩家只看到原生的"点击加入游戏"闲置提示，
// 而对抗没有可用的闲置键 → 点了没反应、卡死。闲置交给专门的闲置插件处理。
// ------------------------------------------------------------------------
public Action Event_BotReplacedPlayer(Event event, const char[] name, bool dontBroadcast)
{
	// Event is triggered when a bot takes over a player
	int bot		= GetClientOfUserId(event.GetInt("bot"));

	if (!IsValidClient(bot)) return Plugin_Continue;
	if (GetClientTeam(bot) == TEAM_SURVIVOR) CreateTimer(DELAY_KICK_NONEEDBOT, Timer_KickNoNeededBot, GetClientUserId(bot), TIMER_FLAG_NO_MAPCHANGE);

	return Plugin_Continue;
}

// ------------------------------------------------------------------------
// When player dies, forces takeover of the bot
// ------------------------------------------------------------------------
public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	// Event is triggered when a player dies
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!IsValidClient(client)) return Plugin_Continue;
	int owner;
	if (GetClientTeam(client) == TEAM_SURVIVOR)
		owner = IsFakeClient(client) ? GetIdlePlayer(client) : client;
	TakeOver(client);
	// A takeover can emit spawn events. Record the death after that operation.
	if (owner > 0) SetSurvivorDeath(owner, true);
	return Plugin_Continue;
}

void TakeOver(int bot)
{
	if (IsValidClient(bot) && IsFakeClient(bot) && GetClientTeam(bot) == TEAM_SURVIVOR)
	{
		int idleplayer = GetIdlePlayer(bot);
		if (idleplayer > 0) SafeTakeOverSurvivor(idleplayer, bot);
	}
}




// *********************************************************************************
// COMMANDS FOR JOINING TEAMS
// *********************************************************************************

// ------------------------------------------------------------------------
// If press left mouse button as spectator, show menu to join game. Useful in case of idle bug
// ------------------------------------------------------------------------
public Action Cmd_spec_next(int client, char[] command, int argc)
{
	if (client > 0 && IsClientInGame(client) && GetClientTeam(client) == TEAM_SPECTATOR && !GetBotOfIdle(client))
	{
		// sm_teams 不再注册为控制台命令，直接调用同一入口（TeamMenu 内含
		// l4d_management < 3 的权限判断与重复面板保护，语义与旧 FakeClientCommand 等价）。
		TeamMenu(client, 0);
	}
	return Plugin_Continue;	
}

// ------------------------------------------------------------------------
// Join survivor or infected
// ------------------------------------------------------------------------
public Action Join_Game(int client, int args)
{
	return RequestJoin(client, 0);
}

public Action Join_Spectator(int client, int args)
{
	return RequestJoin(client, TEAM_SPECTATOR);
}

public Action Join_Survivor(int client, int args)
{
	return RequestJoin(client, TEAM_SURVIVOR);
}

public Action Join_Infected(int client, int args)
{
	return RequestJoin(client, TEAM_INFECTED);
}

public Action Cmd_JoinTeam(int client, const char[] command, int argc)
{
	if (!IsValidClient(client) || IsFakeClient(client) || argc < 1 || !Management.BoolValue)
		return Plugin_Continue;
	char choice[32];
	GetCmdArg(1, choice, sizeof(choice));
	int team = ParseJoinTeam(choice);
	if (team < 0) return Plugin_Continue;
	return RequestJoin(client, team);
}

public Action Cmd_StaySpectator(int client, const char[] command, int argc)
{
	if (client > 0 && client <= MaxClients)
	{
		NewConnection[client] = false;
		CancelJoin(client);
	}
	return Plugin_Continue;
}

int ParseJoinTeam(const char[] choice)
{
	if (StrEqual(choice, "0") || StrEqual(choice, "auto", false) || StrEqual(choice, "autoassign", false)) return 0;
	if (StrEqual(choice, "1") || StrEqual(choice, "spectator", false) || StrEqual(choice, "spectators", false) || StrEqual(choice, "spectate", false)) return TEAM_SPECTATOR;
	if (StrEqual(choice, "2") || StrEqual(choice, "survivor", false) || StrEqual(choice, "survivors", false)) return TEAM_SURVIVOR;
	if (StrEqual(choice, "3") || StrEqual(choice, "infected", false)) return TEAM_INFECTED;
	return -1;
}

bool TeamChangesLocked()
{
	return GetFeatureStatus(FeatureType_Native, "L4D2_FixTeamShuffle_IsFixComplete") == FeatureStatus_Available
		&& !L4D2_FixTeamShuffle_IsFixComplete();
}

Action RequestJoin(int client, int team)
{
	if (!IsValidClient(client) || IsFakeClient(client)) return Plugin_Handled;
	// Explicit choices cancel an outstanding automatic join, including choosing spectator.
	NewConnection[client] = false;
	CancelJoin(client);
	if (!Management.BoolValue) return Plugin_Continue;
	JoinResult result = TryJoinTeam(client, team, true);
	if (result == Join_Wait && team != TEAM_SPECTATOR)
		QueueJoin(client, team, false, 0.3);
	return Plugin_Handled;
}

JoinResult TryJoinTeam(int client, int team, bool announce, bool adminTransfer = false)
{
	if (!IsValidClient(client) || IsFakeClient(client) || !Management.BoolValue) return Join_Failed;
	if (!IsClientAuthorized(client) || IsClientInKickQueue(client)) return Join_Failed;
	if (!SurvivorMapReady) return Join_Wait;
	if (TeamChangesLocked())
	{
		if (announce) PrintToChat(client, "\x03[SV] \x01正在还原换图队伍，完成后将处理你的入队请求。");
		return Join_Wait;
	}
	int current = GetClientTeam(client);
	if (current == TEAM_SURVIVOR)
		SetSurvivorDeath(client, !IsPlayerAlive(client));
	if (current == TEAM_INFECTED && GetClientZC(client) == ZC_JOCKEY
		&& GetEntProp(client, Prop_Send, "m_jockeyVictim") > 0)
		return Join_Failed;
	if (team == 0)
	{
		if (GetBotOfIdle(client) || current == TEAM_SURVIVOR || !InfectedAllowed) team = TEAM_SURVIVOR;
		else if (current == TEAM_INFECTED) team = TEAM_INFECTED;
		else
		{
			int survivors = GetTeamPlayers(TEAM_SURVIVOR, false);
			int infected = GetTeamPlayers(TEAM_INFECTED, false);
			if (survivors >= SurvivorLimit.IntValue && infected >= InfectedLimit.IntValue)
			{
				if (announce) PrintToChat(client, "\x03[SV] \x01两支队伍的真人位置都已满。");
				return Join_Failed;
			}
			team = infected >= InfectedLimit.IntValue ? TEAM_SURVIVOR
				: (survivors >= SurvivorLimit.IntValue ? TEAM_INFECTED
				: (infected < survivors ? TEAM_INFECTED : TEAM_SURVIVOR));
		}
	}
	if (current == team && (team != TEAM_SURVIVOR || IsPlayerAlive(client))
		&& (team != TEAM_SPECTATOR || GetBotOfIdle(client) == 0))
	{
		// 这条捷径不经过 SafeTakeOverSurvivor（引擎已把人放进生还者队且存活），
		// 所以要在这里也排一次补枪检查。
		if (team == TEAM_SURVIVOR) ScheduleLoadoutCheck(client);
		return Join_Success;
	}
	if (team == TEAM_SPECTATOR)
	{
		if (!adminTransfer && !CanVoluntarilySpectate(client, announce)) return Join_Failed;
		int ownedBot = GetBotOfIdle(client);
		if (ownedBot > 0 && !SafeTakeOverSurvivor(client, ownedBot)) return Join_Wait;
		ChangeClientTeam(client, TEAM_SPECTATOR);
		if (!adminTransfer && announce && !SuppressSpectate.BoolValue
			&& GetGameTime() >= NextSpectateNotice[client])
		{
			PrintToChatAll("\x03[队伍] \x01%N 已加入旁观。使用 !join、!sur 或 !inf 返回游戏。", client);
			NextSpectateNotice[client] = GetGameTime() + 7.0;
		}
		return Join_Success;
	}
	if (team == TEAM_INFECTED)
	{
		if (!InfectedAllowed || GetTeamPlayers(TEAM_INFECTED, false) >= InfectedLimit.IntValue)
		{
			if (announce) PrintToChat(client, "\x03[SV] \x01特感队伍的真人位置已满或本模式不允许加入。");
			return Join_Failed;
		}
		if (!MakeInfectedRoom()) return Join_Wait;
		int ownedBot = GetBotOfIdle(client);
		if (ownedBot > 0 && !SafeTakeOverSurvivor(client, ownedBot)) return Join_Wait;
		ChangeClientTeam(client, TEAM_INFECTED);
		return GetClientTeam(client) == TEAM_INFECTED ? Join_Success : Join_Wait;
	}
	if (team != TEAM_SURVIVOR) return Join_Failed;
	if (!EnsureSurvivorModels()) return Join_Wait;
	bool died = HasSurvivorDied(client);
	if (died && current == TEAM_SURVIVOR)
	{
		if (announce) PrintToChat(client, "\x03[SV] \x01本回合已阵亡，请等待救援、复活或下一回合。");
		return Join_Failed;
	}
	int bot = GetBotOfIdle(client);
	if (bot <= 0 && current != TEAM_SURVIVOR && GetTeamPlayers(TEAM_SURVIVOR, false) >= SurvivorLimit.IntValue)
	{
		if (announce) PrintToChat(client, "\x03[SV] \x01生还者队伍的真人位置已满。");
		return Join_Failed;
	}
	/* 生还者位置被死亡生还者占着时，不能把人塞进生还者队（否则他会变成一具死亡身体，
	   客户端一直显示原生"点击加入游戏"却点不动）。
	   例外：这名玩家托管着自己的生还者 Bot（从旁观回来接管原来的身体），那不是新增名额。 */
	if (bot <= 0 && HasDeadSurvivorSeat())
	{
		if (announce) PrintToChat(client, "\x03[SV] \x01本回合生还者已无可用位置（有阵亡玩家占位），请等待下一回合或加入特感。");
		return Join_Failed;
	}
	if (died && bot > 0 && IsPlayerAlive(bot))
	{
		if (announce) PrintToChat(client, "\x03[SV] \x01本回合已阵亡，不能接管存活的 AI。");
		return Join_Failed;
	}
	if (bot <= 0) bot = FindJoinSurvivorBot(!died);
	if (bot <= 0)
	{
		if (died)
		{
			if (announce) PrintToChat(client, "\x03[SV] \x01本回合已阵亡，不能接管存活的 AI。请等待救援、复活或下一回合。");
			return Join_Failed;
		}
		if (GetSurvivorTeam() < SurvivorLimit.IntValue) SpawnFakeSurvivorClient();
		return Join_Wait;
	}
	// The original jointeam command has its own four-player checks. Bypass only that
	// route after checking our human limit, and reserve exactly this available bot.
	bool canRespawn = !died && !InfectedAllowed && RespawnJoin.BoolValue && IsFirstTime(client);
	int requestUserid = GetClientUserId(client);
	bool taken = SafeTakeOverSurvivor(client, bot);
	if (!IsValidClient(client) || GetClientUserId(client) != requestUserid) return Join_Failed;
	if (!taken || GetClientTeam(client) != TEAM_SURVIVOR)
	{
		ChangeClientTeam(client, TEAM_SPECTATOR);
		return Join_Wait;
	}
	if (!IsPlayerAlive(client) && canRespawn)
	{
		Respawn(client);
		TeleportToSurvivor(client);
		SetGodMode(client, 1.0);
	}
	return Join_Success;
}

bool CanVoluntarilySpectate(int client, bool announce)
{
	if (!AllowSpectate.BoolValue) return false;
	int team = GetClientTeam(client);
	if (team == TEAM_INFECTED && GetClientZC(client) == ZC_TANK)
	{
		if (announce) PrintToChat(client, "\x03[队伍] \x01控制坦克时不能主动转入旁观。");
		return false;
	}
	int survivor = team == TEAM_SURVIVOR ? client : GetBotOfIdle(client);
	if (survivor > 0)
	{
		if (BlockSpecInTank.BoolValue && L4D2_IsTankInPlay()) return false;
		if ((L4D2_GetInfectedAttacker(survivor) != -1 && !L4D_IsPlayerIncapacitated(survivor))
			|| GetEntDataEnt2(survivor, QueuedPummelOffset) != -1)
		{
			if (announce) PrintToChat(client, "\x03[队伍] \x01被特感控制时暂时不能转入旁观。");
			return false;
		}
	}
	return true;
}

int FindJoinSurvivorBot(bool allowAlive = true)
{
	int deadBot = -1;
	for (int bot = 1; bot <= MaxClients; bot++)
	{
		if (!IsBotValid(bot) || GetClientTeam(bot) != TEAM_SURVIVOR || SurvivorPlaceholder[bot]) continue;
		if (!PrepareSurvivorModel(bot)) continue;
		if (IsPlayerAlive(bot))
		{
			if (allowAlive) return bot;
		}
		else deadBot = bot;
	}
	return deadBot;
}

bool MakeInfectedRoom()
{
	while (GetTeamPlayers(TEAM_INFECTED, true) >= InfectedLimit.IntValue)
	{
		int candidate = -1;
		for (int bot = MaxClients; bot >= 1; bot--)
		{
			if (IsClientInGame(bot) && IsFakeClient(bot) && !IsClientInKickQueue(bot)
				&& GetClientTeam(bot) == TEAM_INFECTED && GetClientZC(bot) >= ZC_SMOKER
				&& GetClientZC(bot) <= ZC_CHARGER)
			{
				candidate = bot;
				break;
			}
		}
		if (candidate < 1) return false;
		ChangeClientTeam(candidate, TEAM_SPECTATOR);
		KickClient(candidate, "Making room for a human infected player");
	}
	return true;
}

public Action MultiStatus(int client, int args)
{
	char filename[PLATFORM_MAX_PATH];
	GetPluginFilename(null, filename, sizeof(filename));
	ConVar maxPlayers = FindConVar("sv_maxplayers");
	ConVar multiPlayers = FindConVar("mv_maxplayers");
	int waiting, automatic;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (JoinPending[i]) waiting++;
		if (JoinPending[i] && JoinAutomatic[i]) automatic++;
	}
	ReplyToCommand(client, "[Multi] v%s | file=%s | engine=%d/%d | plugin=%d/%d | minsurvivor=%d",
		PLUGIN_VERSION, filename, L4DSurvivorLimit.IntValue, L4DInfectedLimit.IntValue,
		SurvivorLimit.IntValue, InfectedLimit.IntValue, cvar_minsurvivor.IntValue);
	ReplyToCommand(client, "[Multi] MaxClients=%d | sv_maxplayers=%d | mv_maxplayers=%d | mode=%s",
		MaxClients, maxPlayers == null ? -1 : maxPlayers.IntValue, multiPlayers == null ? -1 : multiPlayers.IntValue, gameMode);
	ReplyToCommand(client, "[Multi] survivor humans=%d AI=%d | infected humans=%d AI=%d | auto=%d management=%d | round=%d restorelock=%d | waiting=%d auto_waiting=%d",
		GetTeamPlayers(TEAM_SURVIVOR, false), CountBots(TEAM_SURVIVOR), GetTeamPlayers(TEAM_INFECTED, false),
		CountBots(TEAM_INFECTED), AutoJoin.IntValue, Management.IntValue, RoundStarted, TeamChangesLocked(), waiting, automatic);
	ReplyToCommand(client, "[Multi] ready_humans=%d | bots_allowed=%d | empty_cleanup=%d",
		GetReadyHumanCount(), SvBotsAllowed(), EmptyServerTimer != null);
	ReplyToCommand(client, "[Multi] survivor_models=%d/%d | map_ready=%d | takeover_blocked=%d | character_repairs=%d",
		SurvivorModelsReady, L4D1 ? 4 : 8, SurvivorMapReady, TakeoverBlocked, SurvivorCharacterRepairs);
	return Plugin_Handled;
}

// ------------------------------------------------------------------------
// Create a bot. Useful if less bots than SurvivorLimit because the later got increased
// ------------------------------------------------------------------------
public Action Create_Player(int client, int args)
{
	if (Management.IntValue < 2) return Plugin_Continue;
	char name[MAX_NAME_LENGTH] = "SurvivorBot";
	if (args > 0) GetCmdArg(1, name, sizeof(name));
	// Named and unnamed requests share the same limit and cleanup. Previously
	// named bots never joined a team, and failed/double dispatches leaked slots.
	if (!SpawnFakeSurvivorClient(name, true))
		ReplyToCommand(client, "[SV] Could not create survivor: no ready human, team full or bot creation failed.");
	return Plugin_Handled;
}

public Action Timer_KickFakeBot(Handle timer, any userid)
{
	int Bot = GetClientOfUserId(userid);
	if (!Bot || !IsFakeClient(Bot)) return Plugin_Stop;
	if (IsClientConnected(Bot))
	{
		KickClient(Bot, "Kicking FakeClient");		
		return Plugin_Stop;
	}	
	return Plugin_Continue;
}

public Action TeamMenu(int client, int args)
{
	if (Management.IntValue < 3) return Plugin_Continue;
	if (!IsValidClient(client) || IsFakeClient(client)) return Plugin_Handled;
	NewConnection[client] = false;
	CancelJoin(client);

	if(TeamPanelTimer[client] == null)
	{
		DisplayTeamMenu(client);
	}
	return Plugin_Handled;
}

// *********************************************************************************
// RETURN PROPERTIES OF INFECTED/SURVIVOR TEAMS, BOTS, & PLAYERS
// *********************************************************************************

char survivor_only_modes[23][] =
{
	"coop", "realism", "survival",
	"m60s", "hardcore", "l4d1coop",
	"mutation1",	"mutation2",	"mutation3",	"mutation4",
	"mutation5",	"mutation6",	"mutation7",	"mutation8",
	"mutation9",	"mutation10",	"mutation16",	"mutation17", "mutation20",
	"community1",	"community2",	"community4",	"community5"
};

// ------------------------------------------------------------------------
// Returns true if players in team infected are allowed
// ------------------------------------------------------------------------
bool AreInfectedAllowed()
{
	for (int i = 0; i < sizeof(survivor_only_modes); i++)
	{
		if (StrEqual(gameMode, survivor_only_modes[i], false))
		{
			return false;
		}
	}
	return true;   // includes versus, realism versus, scavenge, & some mutations
}

// ------------------------------------------------------------------------
// Returns true if lobby full. Used to unreserve the lobby
// ------------------------------------------------------------------------
bool IsServerLobbyFull()
{
	int humans = GetHumanCount();

	if (humans >= 8) return true;
	if( !InfectedAllowed && humans >= 4) return true;
	return false;
}

// ------------------------------------------------------------------------
// Returns true if client never spawned as survivor this game. Used to allow 1 free spawn
// ------------------------------------------------------------------------
bool IsFirstTime(int client)
{
	if(!IsClientInGame(client) || IsFakeClient(client)) return false;
	
	char SteamID[64];
	bool valid = GetClientAuthId(client, AuthId_Steam2, SteamID, sizeof(SteamID));		
	
	if (valid == false) return false;

	bool Allowed;
	if (!SteamIDs.GetValue(SteamID, Allowed))  // If can't find the entry in map
	{
		SteamIDs.SetValue(SteamID, true, true);
		Allowed = true;
	}
	return Allowed;
}

// Keep deaths by identity for the round so spectator/team changes and reconnects
// cannot turn a dead survivor into a live bot. A real respawn clears the entry.
void SetSurvivorDeath(int client, bool died)
{
	SurvivorDied[client] = died;
	char auth[MAX_AUTHID_LENGTH];
	if (GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth)))
	{
		if (died) DeadSurvivors.SetValue(auth, true);
		else DeadSurvivors.Remove(auth);
	}
}

bool HasSurvivorDied(int client)
{
	if (SurvivorDied[client]) return true;
	char auth[MAX_AUTHID_LENGTH];
	int died;
	return GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth))
		&& DeadSurvivors.GetValue(auth, died) && died != 0;
}

// ------------------------------------------------------------------------
// Stores the Steam ID, so if reconnect we don't allow free respawn
// ------------------------------------------------------------------------
void RecordSteamID(int client)
{
	// Stores the Steam ID, so if reconnect we don't allow free respawn
	char SteamID[64];
	bool valid = GetClientAuthId(client, AuthId_Steam2, SteamID, sizeof(SteamID));
	if (valid) SteamIDs.SetValue(SteamID, false, true);
}

// ------------------------------------------------------------------------
// Returns the idle player of the bot, returns 0 if none
// ------------------------------------------------------------------------
int GetIdlePlayer(int bot)
{
	if (bot > 0 && IsClientInGame(bot) && GetClientTeam(bot) == TEAM_SURVIVOR && IsFakeClient(bot)
		&& HasEntProp(bot, Prop_Send, "m_humanSpectatorUserID"))
	{
		int client = GetClientOfUserId(GetEntProp(bot, Prop_Send, "m_humanSpectatorUserID"));
		if (client > 0 && IsClientInGame(client) && !IsFakeClient(client) && GetClientTeam(client) == TEAM_SPECTATOR)
			return client;
	}
	return 0;
}

// ------------------------------------------------------------------------
// Returns the bot of the idle client, returns 0 if none 
// ------------------------------------------------------------------------
int GetBotOfIdle(int client)
{
	for(int i = 1; i <= MaxClients; i++)
	{
		if (GetIdlePlayer(i) == client) return i;
	}
	return 0;
}

// ------------------------------------------------------------------------
// Get the number of players on the team (includes idles)
// includeBots == true : counts bots
// ------------------------------------------------------------------------
int GetTeamPlayers(int team, bool includeBots)
{
	int players = 0;
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i) && GetClientTeam(i) == team)
		{
			if(IsFakeClient(i) && !includeBots && !GetIdlePlayer(i))
				continue;
			players++;
		}
	}
	return players;
}

// ------------------------------------------------------------------------
// Get the number of survivors on the team, including bots
// ------------------------------------------------------------------------
int GetSurvivorTeam()
{
	return GetTeamPlayers(TEAM_SURVIVOR, true);
}

int GetHumanCount()
{
	int humans = 0;
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i) && !IsFakeClient(i))
			humans++;
	}
	return humans;
}

// ------------------------------------------------------------------------
// 空服不养 bot：真人完成进服、身份验证且未处于踢出队列后才允许补位。
// ------------------------------------------------------------------------
int GetReadyHumanCount()
{
	int humans;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && IsClientAuthorized(i)
			&& !IsClientInKickQueue(i)) humans++;
	}
	return humans;
}

stock bool SvBotsAllowed()
{
	return GetReadyHumanCount() > 0;
}

// ------------------------------------------------------------------------
// 回收空服里多余的生还者 bot（只踢 AI bot；有真人空闲接管中/已在踢队列里的跳过）。
// ------------------------------------------------------------------------
stock void SvRecycleSurvivorBots()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i)) continue;
		if (!IsFakeClient(i)) continue;
		if (GetClientTeam(i) != TEAM_SURVIVOR) continue;
		if (GetIdlePlayer(i)) continue;              // 有真人 AFK 接管了这个 bot，别踢
		if (IsClientInKickQueue(i)) continue;
		if (SurvivorPlaceholder[i]) continue;        // 正在生成中的占位假客户端由它自己的 Timer 收尾
		KickClient(i, "空服回收 AI bot");
	}
}

// ------------------------------------------------------------------------
// 回收空服里的 AI 特感 bot。
// ------------------------------------------------------------------------
stock void SvRecycleInfectedBots()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i)) continue;
		if (!IsFakeClient(i)) continue;
		if (GetClientTeam(i) != TEAM_INFECTED) continue;
		if (IsClientInKickQueue(i)) continue;
		KickClient(i, "空服回收 AI 特感");
	}
}

// ------------------------------------------------------------------------
// Is the bot valid? (either survivor or infected)
// ------------------------------------------------------------------------
bool IsBotValid(int client)
{
	if(client > 0 && IsClientInGame(client) && IsFakeClient(client) && !GetIdlePlayer(client) && !IsClientInKickQueue(client))
		return true;
	return false;
}


// ------------------------------------------------------------------------
// Check if how many alive bots without an idle are available in a team
// ------------------------------------------------------------------------
int CountAvailableBots(int team)
{
	int num = 0;
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsBotValid(i) && GetClientTeam(i) == team && IsPlayerAlive(i))
					num++;
	}
	return num;
}

// ------------------------------------------------------------------------
// Check if how many bots are in a team without idle. Can be dead
// ------------------------------------------------------------------------
stock int CountBots(int team)
{
	int num = 0;
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsBotValid(i) && GetClientTeam(i) == team)
					num++;
	}
	return num;
}

bool AnySurvivorLeftSafeArea()
{
	return L4D_HasAnySurvivorLeftSafeArea();
}

// *********************************************************************************
// TEAM MENU
// *********************************************************************************

void DisplayTeamMenu(int client)
{
	Handle TeamPanel = CreatePanel();

	SetPanelTitle(TeamPanel, "SuperVersus Team Panel");

	char title_spectator[32];
	Format(title_spectator, sizeof(title_spectator), "Spectator (%d)", GetTeamPlayers(TEAM_SPECTATOR, false));
	DrawPanelItem(TeamPanel, title_spectator);
		
	// Draw Spectator Group
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i) && GetClientTeam(i) == TEAM_SPECTATOR)
		{
			char text_client[32];
			char ClientUserName[MAX_TARGET_LENGTH];
			GetClientName(i, ClientUserName, sizeof(ClientUserName));
			ReplaceString(ClientUserName, sizeof(ClientUserName), "[", "");

			Format(text_client, sizeof(text_client), "%s", ClientUserName);
			DrawPanelText(TeamPanel, text_client);
		}
	}

	char title_survivor[32];
	Format(title_survivor, sizeof(title_survivor), "Survivors (%d/%d) - %d Bot(s)", GetTeamPlayers(TEAM_SURVIVOR, false), SurvivorLimit.IntValue, CountAvailableBots(TEAM_SURVIVOR));
	DrawPanelItem(TeamPanel, title_survivor);
	
	// Draw Survivor Group
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i) && GetClientTeam(i) == TEAM_SURVIVOR)
		{
			char text_client[32];
			char ClientUserName[MAX_TARGET_LENGTH];

			GetClientName(i, ClientUserName, sizeof(ClientUserName));
			ReplaceString(ClientUserName, sizeof(ClientUserName), "[", "");

			char m_iHealth[MAX_TARGET_LENGTH];
			if(IsPlayerAlive(i))
			{
				if(GetEntProp(i, Prop_Send, "m_isIncapacitated"))
				{
					Format(m_iHealth, sizeof(m_iHealth), "DOWN - %d HP - ", GetEntData(i, FindDataMapInfo(i, "m_iHealth"), 4));
				}
				else if(GetEntProp(i, Prop_Send, "m_currentReviveCount") == SurvMaxIncap.IntValue)
				{
					Format(m_iHealth, sizeof(m_iHealth), "BLWH - ");
				}
				else
				{
					Format(m_iHealth, sizeof(m_iHealth), "%d HP - ", GetClientRealHealth(i));
				}
	
			}
			else
			{
				Format(m_iHealth, sizeof(m_iHealth), "DEAD - ");
			}

			Format(text_client, sizeof(text_client), "%s%s", m_iHealth, ClientUserName);
			DrawPanelText(TeamPanel, text_client);
		}
	}

	char title_infected[32];
	
	if (GetClientTeam(client) == TEAM_INFECTED || Management.IntValue == 4)
	{
		if ( InfectedAllowed) Format(title_infected, sizeof(title_infected), "Infected (%d/%d) - %d Bot(s)", GetTeamPlayers(TEAM_INFECTED, false), InfectedLimit.IntValue, CountAvailableBots(TEAM_INFECTED));
		if (!InfectedAllowed) Format(title_infected, sizeof(title_infected), "Infected - %d Bot(s)", CountAvailableBots(TEAM_INFECTED));
	}
	else if (!InfectedAllowed)
	{
		Format(title_infected, sizeof(title_infected), "Infected");
	}
	else if ( InfectedAllowed)
	{
		Format(title_infected, sizeof(title_infected), "Infected (%d/%d)", GetTeamPlayers(TEAM_INFECTED, false), InfectedLimit.IntValue);  // doesn't show how many bots are alive
	}
	
	DrawPanelItem(TeamPanel, title_infected);
		
	// Draw Infected Group
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i) && GetClientTeam(i) == TEAM_INFECTED)
		{
			if (GetClientTeam(client) != TEAM_INFECTED && IsFakeClient(i) &&  Management.IntValue != 4) continue ;    // Don't show anything about infected bots to survivors
		
			char text_client[32];
			char ClientUserName[MAX_TARGET_LENGTH];
			
			GetClientName(i, ClientUserName, sizeof(ClientUserName));
			ReplaceString(ClientUserName, sizeof(ClientUserName), "[", "");

			if (GetClientTeam(client) == TEAM_INFECTED || Management.IntValue == 4) // Only show HP of infected to infected
			{
				char m_iHealth[MAX_TARGET_LENGTH];
				if(IsPlayerAlive(i))
				{
					if(GetEntProp(i, Prop_Send, "m_isIncapacitated"))
					{
						Format(m_iHealth, sizeof(m_iHealth), "DOWN - %d HP - ", GetEntData(i, FindDataMapInfo(i, "m_iHealth"), 4));
					}
					if(GetEntProp(i, Prop_Send, "m_isGhost"))
					{
						Format(m_iHealth, sizeof(m_iHealth), "GHOST - ");
					}
					else
					{
						Format(m_iHealth, sizeof(m_iHealth), "%d HP - ", GetEntData(i,  FindDataMapInfo(i, "m_iHealth"), 4));
					}
				}
				else
				{
					Format(m_iHealth, sizeof(m_iHealth), "DEAD - ");
				}
				Format(text_client, sizeof(text_client), "%s%s", m_iHealth, ClientUserName);
			}
			else Format(text_client, sizeof(text_client), "%s", ClientUserName);
			
			DrawPanelText(TeamPanel, text_client);
		}
	}

	DrawPanelItem(TeamPanel, "Close");
		
	SendPanelToClient(TeamPanel, client, TeamMenuHandler, 30);
	CloseHandle(TeamPanel);
	TeamPanelTimer[client] = CreateTimer(1.0, Timer_TeamMenuHandler, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public int TeamMenuHandler(Handle UpgradePanel, MenuAction action, int client, int param2) {
	if (action == MenuAction_Select) {
		if (param2 == 1) {
			FakeClientCommand(client, "sm_spectate");
		}
		else if (param2 == 2) {


				FakeClientCommand(client, "sm_survivor");

		}
		else if (param2 == 3) {
			FakeClientCommand(client, "sm_infected");
		}
		else if (param2 == 4) {
			delete TeamPanelTimer[client];
		}
	}
	else if (action == MenuAction_Cancel) {
		// Nothing
	}
	return 0;
}

public Action Timer_TeamMenuHandler(Handle hTimer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (!IsValidClient(client) || TeamPanelTimer[client] != hTimer) return Plugin_Stop;
	TeamPanelTimer[client] = null;
	DisplayTeamMenu(client);
	return Plugin_Stop;
}

int GetClientRealHealth(int client)
{
	if(!client || !IsValidEntity(client) || !IsClientInGame(client) || !IsPlayerAlive(client) || IsClientObserver(client))
	{
		return -1;
	}
	if(GetClientTeam(client) != TEAM_SURVIVOR)
	{
		return GetClientHealth(client);
	}
  
	float buffer = GetEntPropFloat(client, Prop_Send, "m_healthBuffer");
	float TempHealth;
	int PermHealth = GetClientHealth(client);
	if(buffer <= 0.0)
	{
		TempHealth = 0.0;
	}
	else
	{
		float difference = GetGameTime() - GetEntPropFloat(client, Prop_Send, "m_healthBufferTime");
		float decay = PainPillsDR.FloatValue;
		float constant = 1.0/decay;	TempHealth = buffer - (difference / constant);
	}
	
	if(TempHealth < 0.0)
	{
		TempHealth = 0.0;
	}
	return RoundToFloor(PermHealth + TempHealth);
}

// *********************************************************************************
// INFECTED COUNTER, for Versus / Scavenge
// *********************************************************************************

// ------------------------------------------------------------------------
//  Start counter when a survivor leaves safe area
// ------------------------------------------------------------------------
public void Event_PlayerLeftStartArea(Event event, const char[] name, bool dontBroadcast)
{
	StartInfectedCounter();
}

void StartInfectedCounter()
{
	if(RoundStarted && SvBotsAllowed() && SubDirector == null && InfectedAllowed && AnySurvivorLeftSafeArea())
	{
		SubDirector = CreateTimer(5.0, BotInfectedCounter, true, TIMER_FLAG_NO_MAPCHANGE);
	}
}

// ------------------------------------------------------------------------
//  Counter periodically checks if need to add SI to queue, or spawn extra SI
// ------------------------------------------------------------------------
public Action BotInfectedCounter(Handle timer, bool recheck)
{
	SubDirector = null;

	if (!RoundStarted || (recheck && !AnySurvivorLeftSafeArea())) return Plugin_Stop;
	
	// 空服不养 bot：没有真人时既不排 AI 特感队列，也不补；并把已有的 AI 特感回收掉
	if (!SvBotsAllowed())
	{
		SvRecycleInfectedBots();
		for (int i = 0; i < sizeof(SiTimes); i++) SiTimes[i] = 0.0;
		return Plugin_Stop;
	}
	
	if (!MoreSiBotsVersus.BoolValue || GetTeamPlayers(TEAM_INFECTED, false) >= InfectedLimit.IntValue) // if no extra bots wanted
	{
		SubDirector = CreateTimer(10.0, BotInfectedCounter, false, TIMER_FLAG_NO_MAPCHANGE); // check back in 10 secs to see if setting changed
		return Plugin_Stop;
	}
	
	SiSpawnCheck();
	
	SubDirector = CreateTimer(2.0, BotInfectedCounter, false, TIMER_FLAG_NO_MAPCHANGE);
	return Plugin_Stop;
}

// ------------------------------------------------------------------------
//  Check if Si to be added to respawn Queue, or spawn a Si
// ------------------------------------------------------------------------
void SiSpawnCheck()
{
	if (!SvBotsAllowed()) return;
	// For each missing SI, add to queue
	for (int i = GetTeamPlayers(TEAM_INFECTED, true) + CountSiQueue(); i < InfectedLimit.IntValue; i++)
	{
		AddSiToQueue();
	}
	
	// For each Si over the limit, remove youngest in queue
	for (int i = GetTeamPlayers(TEAM_INFECTED, true) + CountSiQueue(); i > InfectedLimit.IntValue; i--)
	{
		int YoungestSi = GetYoungestSi();
		if (YoungestSi != -1)  	SiTimes[YoungestSi] = 0.0;		
	}
	
	// For each Si over the limit, spawn it
	int OldestSi = GetOldestSi();
	if (OldestSi != -1 && (GetGameTime() - SiTimes[OldestSi]) > GhostDelayMax.FloatValue + SiSpMoreDelay.FloatValue)
	{
		SiSpawn();
	}
}

// ------------------------------------------------------------------------
//  Get Si that has been in the spawn queue the longest
// ------------------------------------------------------------------------
int GetOldestSi()
{
	float fOldest     =  GetGameTime()+1.0; // More recent that any can be
	int   iOldest     =   			    -1;
	for (int i = 0; i < InfectedLimit.IntValue; i++)
	{
		if (SiTimes[i] > 0.0 && SiTimes[i] < fOldest)
		{
			iOldest   = i;
			fOldest   = SiTimes[i];
		}
	}
	return iOldest;
}

// ------------------------------------------------------------------------
//  Get Si that has been in the spawn queue the shortest
// ------------------------------------------------------------------------
int GetYoungestSi()
{
	float fYoungest     =                  0.0; // Older than any can be
	int   iYoungest     =   			    -1;
	for (int i = 0; i < InfectedLimit.IntValue; i++)
	{
		if (SiTimes[i] > fYoungest)
		{
			iYoungest   = i;
			fYoungest   = SiTimes[i];
		}
	}
	return iYoungest;
}

// ------------------------------------------------------------------------
//  Add new Si to spawn queue
// ------------------------------------------------------------------------
void AddSiToQueue()
{
	for (int i = 0; i < InfectedLimit.IntValue; i++)
	{
		if (SiTimes[i] == 0.0)
		{
			SiTimes[i] = GetGameTime();
			return;
		}
	}
}

// ------------------------------------------------------------------------
// Count how many SI are in the queue
// ------------------------------------------------------------------------
int CountSiQueue()
{
	int count = 0;
	for (int i = 0; i < InfectedLimit.IntValue; i++)
	{
		if (SiTimes[i] > 0.0)
		{
			count = count + 1;
		}
	}
	return count;
}

// ------------------------------------------------------------------------
//  Spawn a Special Infected bot
// ------------------------------------------------------------------------
void SetGhostStatus(int client, bool ghost) { SetEntProp(client, Prop_Send, "m_isGhost",   ghost); }

int GetSiType(int client)
{
	if (!IsValidClient(client) || GetClientTeam(client) != TEAM_INFECTED) return 0;
	return GetEntProp(client, Prop_Send, "m_zombieClass");
}

void SiSpawn(int type = -1)
{
	if (!SvBotsAllowed()) return;
	if (type == -1) type = PickSiType();
	if (type < ZC_SMOKER || type > (L4D1 ? ZC_HUNTER : ZC_CHARGER)) return;

	// Spawn an AI directly. z_spawn_old can select human infected and required
	// temporarily corrupting their ghost/life state (including respawn timers).
	// A failed position search/spawn leaves the queue intact for the next tick.
	float pos[3];
	float angles[3];
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || GetClientTeam(client) != TEAM_SURVIVOR
			|| !IsPlayerAlive(client) || IsClientInKickQueue(client)) continue;
		if (!L4D_GetRandomPZSpawnPosition(client, type, 20, pos)) continue;
		L4D2_SpawnSpecial(type, pos, angles);
		return;
	}
}

char L4D1_limits[4][] = {"none", "z_gas_limit",			  "z_exploding_limit",	   "z_hunter_limit"};
char L4D2_limits[7][] = {"none", "z_versus_smoker_limit", "z_versus_boomer_limit", "z_versus_hunter_limit", "z_versus_spitter_limit", "z_versus_jockey_limit", "z_versus_charger_limit"};

// ------------------------------------------------------------------------
//  Find which SI should be spawned
// ------------------------------------------------------------------------
int PickSiType()
{
	// first element is nothing, to simplify since enum starts at 1
	//////////////////////////////////////////////////////////////
	int SIleft[7] = {-1,  0,0,0, 0,0,0};
	int maxTypes = L4D1 ? 3 : 6;
	
	// Record SI type limits
	////////////////////////
	int SIfromTypes = 0; // 
	for (int type = 1; type <= maxTypes; type++)
	{
		SIleft[type] = L4D1? FindConVar(L4D1_limits[type]).IntValue : FindConVar(L4D2_limits[type]).IntValue;
		SIfromTypes  = SIfromTypes + SIleft[type] ;
	}

	int iInfected = InfectedLimit.IntValue;
	MinionLimit.IntValue = iInfected; 

	// Check if SI from types are enough
	///////////////////////////////////////
	if (SIfromTypes < iInfected)   // if not enough 
	{
		int extraSiPerType =  RoundToCeil((iInfected - SIfromTypes)/3.0);
		
		for(int i = 1; i <= maxTypes; i++)
		{
			SIleft[i] = SIleft[i] + extraSiPerType;
			if (L4D1) FindConVar(L4D1_limits[i]).IntValue = SIleft[i];  // Increase each SI class limit
			else      FindConVar(L4D2_limits[i]).IntValue = SIleft[i];
		}
	}
	
	// counts infected left that can be spawned.
	//////////////////////////////////////////			
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i) && GetClientTeam(i) == TEAM_INFECTED && IsPlayerAlive(i))
		{			
			int type = GetSiType(i);
			if (type >= 1 && type <= maxTypes) SIleft[type]--;
		}
	}
	
	// Pick available types;
	int nmax = 0;
	int SIfree[7];
	
	for (int type = 1; type <= 6; type++)
	{
		if (SIleft[type] > 0)
		{
			nmax++;
			SIfree[nmax] = type;
		}
	}
		
	if (nmax != 0)  return SIfree[GetRandomInt(1, nmax)];
	else 			return -1;
}

// *********************************************************************************
// SIGNATURE METHODS
// *********************************************************************************

bool EnsureSurvivorModels()
{
	if (!SurvivorMapReady) return false;
	SurvivorModelsReady = 0;
	int first = L4D1 ? 4 : 0;
	for (int i = first; i < sizeof(SurvivorModels); i++)
	{
		if (!IsModelPrecached(SurvivorModels[i]))
		{
			int index = PrecacheModel(SurvivorModels[i], true);
			if (index <= 0 || !IsModelPrecached(SurvivorModels[i]))
			{
				if (!SurvivorModelErrorLogged[i])
				{
					LogError("[SV model guard] Cannot precache %s; survivor creation/takeover blocked.", SurvivorModels[i]);
					SurvivorModelErrorLogged[i] = true;
				}
				continue;
			}
		}
		SurvivorModelsReady++;
	}
	return SurvivorModelsReady == (L4D1 ? 4 : 8);
}

void LogUnsafeSurvivor(int bot, int character, const char[] model, const char[] reason)
{
	TakeoverBlocked++;
	// A broken bot may be considered by several join timers. Keep evidence without
	// flooding the log on every retry. Counters remain visible in sm_multistatus.
	float now = GetEngineTime();
	if (now < NextTakeoverWarning) return;
	NextTakeoverWarning = now + 10.0;
	LogError("[SV model guard] Blocked unsafe survivor: bot=%d userid=%d character=%d model='%s' reason=%s",
		bot, GetClientUserId(bot), character, model, reason);
}

bool PrepareSurvivorModel(int bot)
{
	if (!IsValidClient(bot) || !IsFakeClient(bot) || GetClientTeam(bot) != TEAM_SURVIVOR) return false;
	if (!EnsureSurvivorModels()) return false;
	char model[PLATFORM_MAX_PATH];
	GetClientModel(bot, model, sizeof(model));
	int character = GetEntProp(bot, Prop_Send, "m_survivorCharacter");
	if (!model[0] || !IsModelPrecached(model))
	{
		LogUnsafeSurvivor(bot, character, model, "empty or unprecached current model");
		return false;
	}
	// Restore() chooses a model by character as well as copying the bot's state.
	// Repair an invalid ID only when its existing stock model identifies the role.
	// Do not guess a role for an unknown/custom model or overwrite valid IDs/skins.
	if (character < 0 || character >= (L4D1 ? 4 : 8))
	{
		int first = L4D1 ? 4 : 0;
		for (int i = first; i < sizeof(SurvivorModels); i++)
		{
			if (!StrEqual(model, SurvivorModels[i], false)) continue;
			int repaired = i - first;
			SetEntProp(bot, Prop_Send, "m_survivorCharacter", repaired);
			SurvivorCharacterRepairs++;
			LogMessage("[SV model guard] Repaired bot userid=%d character=%d -> %d from model='%s'",
				GetClientUserId(bot), character, repaired, model);
			return true;
		}
		LogUnsafeSurvivor(bot, character, model, "invalid character with no stock model match");
		return false;
	}
	return true;
}

bool IsTakeoverPairValid(int client, int bot)
{
	if (!SurvivorMapReady || !IsValidClient(client) || IsFakeClient(client)
		|| !IsClientAuthorized(client) || IsClientInKickQueue(client)) return false;
	if (!IsValidClient(bot) || !IsFakeClient(bot) || GetClientTeam(bot) != TEAM_SURVIVOR
		|| SurvivorPlaceholder[bot] || IsClientInKickQueue(bot)
		|| !HasEntProp(bot, Prop_Send, "m_humanSpectatorUserID")) return false;
	int owner = GetEntProp(bot, Prop_Send, "m_humanSpectatorUserID");
	return owner == 0 || owner == GetClientUserId(client);
}

int FindReservedSurvivorBot(int client)
{
	if (!IsValidClient(client)) return 0;
	int userid = GetClientUserId(client);
	for (int bot = 1; bot <= MaxClients; bot++)
	{
		if (!IsClientInGame(bot) || !IsFakeClient(bot) || GetClientTeam(bot) != TEAM_SURVIVOR
			|| !HasEntProp(bot, Prop_Send, "m_humanSpectatorUserID")) continue;
		// SetHumanSpec/TakeOverBot can run while the human is on team 0. The normal
		// GetBotOfIdle helper only recognizes spectators (team 1), so cannot be used here.
		if (GetEntProp(bot, Prop_Send, "m_humanSpectatorUserID") == userid) return bot;
	}
	return 0;
}

bool SafeTakeOverSurvivor(int client, int bot)
{
	if (!IsTakeoverPairValid(client, bot) || !PrepareSurvivorModel(bot)) return false;
	int clientUserid = GetClientUserId(client);
	int botUserid = GetClientUserId(bot);
	if (GetClientTeam(client) != TEAM_SPECTATOR && GetClientTeam(client) != 0)
		ChangeClientTeam(client, TEAM_SPECTATOR);
	if (!IsTakeoverPairValid(client, bot) || GetClientUserId(client) != clientUserid
		|| GetClientUserId(bot) != botUserid) return false;
	if (FindReservedSurvivorBot(client) != bot)
	{
		ChangeClientTeam(client, 0);
		// Team changes invoke other plugins synchronously. Recheck the target identity
		// before passing it into an SDKCall, even though no timer has elapsed.
		if (!IsTakeoverPairValid(client, bot) || GetClientUserId(client) != clientUserid || GetClientUserId(bot) != botUserid
			|| !PrepareSurvivorModel(bot) || !L4D_SetHumanSpec(bot, client))
		{
			if (IsValidClient(client) && GetClientUserId(client) == clientUserid && GetClientTeam(client) == 0)
				ChangeClientTeam(client, TEAM_SPECTATOR);
			return false;
		}
	}
	if (!IsTakeoverPairValid(client, bot) || GetClientUserId(client) != clientUserid || GetClientUserId(bot) != botUserid
		|| FindReservedSurvivorBot(client) != bot || !PrepareSurvivorModel(bot))
	{
		if (IsValidClient(client) && GetClientUserId(client) == clientUserid && GetClientTeam(client) == 0)
			ChangeClientTeam(client, TEAM_SPECTATOR);
		return false;
	}
	bool taken = L4D_TakeOverBot(client);
	if (!taken && IsValidClient(client) && GetClientUserId(client) == clientUserid && GetClientTeam(client) == 0)
		ChangeClientTeam(client, TEAM_SPECTATOR);

	bool okay = taken && IsValidClient(client) && GetClientUserId(client) == clientUserid
		&& GetClientTeam(client) == TEAM_SURVIVOR;

	// 接管成功只代表拿到了这具身体，这具身体可能本来就没枪 → 延迟补枪
	if (okay) ScheduleLoadoutCheck(client);

	return okay;
}

// Also protects assigned survivor bots taken over by the engine or another plugin
// (e.g. the map team-restoration timer) while this multiplayer mode is loaded.
public Action L4D_OnTakeOverBot(int client)
{
	if (!EnsureSurvivorModels()) return Plugin_Handled;
	int bot = FindReservedSurvivorBot(client);
	if (bot > 0 && (!IsTakeoverPairValid(client, bot) || !PrepareSurvivorModel(bot)))
		return Plugin_Handled;
	return Plugin_Continue;
}

// ------------------------------------------------------------------------
// 中途加入 / 接管生还者后的补枪兜底
//   加入与接管流程本身不发放任何武器（模型校验、SetHumanSpec/TakeOverBot 都不碰
//   武器槽），所以这里在加入后延迟 1 秒检查主武器槽（槽 0），空手就补一把冲锋枪。
//   缺省武器上限（l4d_weapon_limits）可能拦下 GivePlayerItem，失败时退回 cheat
//   "give"；两次都拿不到就写错误日志，不静默失败。
//   只处理真人：Bot 没枪不该由这里补，也不该因此动到 AI 的装备逻辑。
// ------------------------------------------------------------------------
void ScheduleLoadoutCheck(int client)
{
	if (!IsValidClient(client) || IsFakeClient(client)) return;

	CreateTimer(1.0, Timer_LoadoutCheck, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_LoadoutCheck(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);

	// 这一秒内可能已离开 / 被换边 / 阵亡
	if (!IsValidClient(client) || IsFakeClient(client)) return Plugin_Stop;
	if (GetClientTeam(client) != TEAM_SURVIVOR || !IsPlayerAlive(client)) return Plugin_Stop;

	// 已有主武器：不动
	if (GetPlayerWeaponSlot(client, 0) != -1) return Plugin_Stop;

	GivePlayerItem(client, "weapon_smg");

	// 被武器上限拦住时退回 give 指令
	if (GetPlayerWeaponSlot(client, 0) == -1)
		CheatGiveWeapon(client, "weapon_smg");

	// 仍然没有主武器 → 写日志，便于线上取证
	if (GetPlayerWeaponSlot(client, 0) == -1)
		LogError("[SV] 给 %L 补发 weapon_smg 失败（可能被武器上限/拾取拦截挡住）", client);

	return Plugin_Stop;
}

// 临时去掉 give 的 cheat 标记并临时给 root 权限再执行（与 givewpn.sp 同款写法）
void CheatGiveWeapon(int client, const char[] weapon)
{
	int flags = GetCommandFlags("give");
	if (flags == -1) return;

	int admin = GetUserFlagBits(client);

	SetUserFlagBits(client, ADMFLAG_ROOT);
	SetCommandFlags("give", flags & ~FCVAR_CHEAT);

	FakeClientCommand(client, "give %s", weapon);

	SetCommandFlags("give", flags);
	SetUserFlagBits(client, admin);
}

void Respawn(int client)
{
	L4D_RespawnPlayer(client);
}

// *********************************************************************************
// CHEAT METHODS
// *********************************************************************************

stock void PrintConsoleToAll(const char[] format, any ...) 
{ 
	char text[192];
	VFormat(text, sizeof(text), format, 2);
	
	for (int i = 1; i <= MaxClients; i++)
	{ 
		if (IsClientInGame(i))
		{
			SetGlobalTransTarget(i);
			PrintToConsole(i, "%s", text);
		}
	}
}

// ------------------------------------------------------------------------
// Teleport client to survivor
// ------------------------------------------------------------------------
void TeleportToSurvivor(int Bot) 
{
				for (int i = 1; i <= MaxClients; i++)
				{
					if (IsClientInGame(i) && (GetClientTeam(i) == TEAM_SURVIVOR) && !IsFakeClient(i) && IsAlive(i) && i != Bot)
					{						
						// get the position coordinates of any active alive player
						float teleportOrigin[3];
						GetClientAbsOrigin(i, teleportOrigin);			
						TeleportEntity(Bot, teleportOrigin, NULL_VECTOR, NULL_VECTOR);					
						break;
					}
				}
}


void SetGodMode(int client, float duration)
{
	if (!IsClientInGame(client)) return;
	
	SetEntProp(client, Prop_Data, "m_takedamage", 0, 1); // god mode
	
	if (duration > 0.0) CreateTimer(duration, Timer_mortal, GetClientUserId(client));
}

public Action Timer_mortal(Handle hTimer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (!client || !IsClientInGame(client)) return Plugin_Stop;
	SetEntProp(client, Prop_Data, "m_takedamage", 2, 1); // mortal
	return Plugin_Stop;
}

stock int TotalSurvivors() // total bots, including players
{
	int l = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i))
		{
			if (IsClientInGame(i) && (GetClientTeam(i) == TEAM_SURVIVOR)) l++;
		}
	}
	return l;
}

public Action Timer_KickNoNeededBot(Handle timer, any userid)
{
	int bot = GetClientOfUserId(userid);
	if (!bot || !IsFakeClient(bot) || !IsClientInGame(bot) || GetClientTeam(bot) != TEAM_SURVIVOR)
		return Plugin_Stop;
	if ((TotalSurvivors() <= cvar_minsurvivor.IntValue)) return Plugin_Handled;
	if (IsClientConnected(bot) && IsClientInGame(bot))
	{
		char BotName[100];
		GetClientName(bot, BotName, sizeof(BotName));				
		if (StrEqual(BotName, "SurvivorBot", true)) return Plugin_Handled;
		if (!HasIdlePlayer(bot))
		{
			StripWeapons(bot);
			KickClient(bot, "Kicking No Needed Bot");
		}
	}
	
	//ServerCommand("sm_kickextrabots");
	
	return Plugin_Handled;
}


stock void StripWeapons(int client) // strip all items from client
{
	int itemIdx;
	for (int x = 0; x <= 3; x++)
	{
		if ((itemIdx = GetPlayerWeaponSlot(client, x)) != -1)
		{  
			RemovePlayerItem(client, itemIdx);
			RemoveEdict(itemIdx);
		}
	}
}

stock bool HasIdlePlayer(int bot)
{
	if (IsValidEntity(bot))
	{
		char sNetClass[12];
		GetEntityNetClass(bot, sNetClass, sizeof(sNetClass));

		if (strcmp(sNetClass, "SurvivorBot") == 0)
		{
			if (!GetEntProp(bot, Prop_Send, "m_humanSpectatorUserID"))
				return false;

			int client = GetClientOfUserId(GetEntProp(bot, Prop_Send, "m_humanSpectatorUserID"));
			if (client)
			{
				// Do not count bots
				// Do not count 3rd person view players
				if (IsClientInGame(client) && !IsFakeClient(client) && (GetClientTeam(client) != TEAM_SURVIVOR)) return true;
			}
			else return false;
		}
	}
	return false;
}


bool IsAlive(int client)
{
	if (!GetEntProp(client, Prop_Send, "m_lifeState")) return true;
	return false;
}
