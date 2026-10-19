#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#include <builtinvotes>
#include <colors>
#undef REQUIRE_PLUGIN
#include <caster_system>
#undef REQUIRE_PLUGIN
#include <GetPlayerGametime>
#undef REQUIRE_PLUGIN
#include <confogl>

#define PLUGIN_VERSION "10.3.3"

public Plugin myinfo =
{
	name = "L4D2 Ready-Up Applemod",
	author = "apples1949 (fork of CanadaRox, Target; doorlock by Glide Loading, sorallll)",
	description = "准备模式：ReadyUp 准备阶段 + 门锁/加载等待/倒计时开门（原 readyup-applemod 与 l4d2_doorlock 已合并为本插件，中文硬编码）",
	version = PLUGIN_VERSION,
	url = "https://github.com/apples1949"
};

// ========================
//  Defines
// ========================
#define NULL_VELOCITY view_as<float>({0.0, 0.0, 0.0})

#define L4D2Team_None       0
#define L4D2Team_Spectator  1
#define L4D2Team_Survivor   2
#define L4D2Team_Infected   3

#define DEBUG 0

enum
{
	ReadyMode_PlayerReady = 1,
	ReadyMode_AutoStart,
	ReadyMode_TeamReady,
	ReadyMode_DoorLock		// 4 = 门锁准备模式（合并进来的 doorlock 流程：锁门→等全员加载→倒计时→开门）
}

enum
{
	WL_NotInWater = 0,
	WL_Feet,
	WL_Waist,
	WL_Eyes
};

// ========================
//  Plugin Variables
// ========================
// Forwards
GlobalForward
	g_hPreInitiateForward,
	g_hInitiateForward,
	g_hPreCountdownForward,
	g_hCountdownForward,
	g_hPreLiveForward,
	g_hLiveForward,
	g_hCountdownCancelledForward,
	g_hPlayerReadyForward,
	g_hPlayerUnreadyForward;

bool externalReadyNotified, externalReadyActive, externalLiveNotified;

// Game Cvars
ConVar
	director_no_specials,
	god,
	sb_stop,
	survivor_limit,
	z_max_player_zombies,
	sv_infinite_primary_ammo;

// Plugin Cvars
ConVar 
	// basic
	l4d_ready_enabled, l4d_ready_cfg_name, l4d_ready_max_players, l4d_ready_autoready,
	// game
	l4d_ready_disable_spawns, l4d_ready_survivor_freeze,
	// sound
	l4d_ready_enable_sound, l4d_ready_notify_sound, l4d_ready_countdown_sound, l4d_ready_live_sound, l4d_ready_autostart_sound, l4d_ready_chuckle, l4d_ready_secret,
	// action
	l4d_ready_delay, l4d_ready_force_extra, l4d_ready_autostart_delay, l4d_ready_autostart_wait, l4d_ready_autostart_min, l4d_ready_unbalanced_start, l4d_ready_unbalanced_min;

// Ready Panel
#include "readyup-applemod/footer.inc" // sm 1.10 compile fix
Footer
	nativeFooter;
float
	fStartTimestamp;
	
// Standard Ready Up
int
	readyUpMode;
bool
	inLiveCountdown,
	inReadyUp,
	isForceStart,
	readySurvFreeze;

// Spectate Fix
Handle g_hChangeTeamTimer[MAXPLAYERS+1];

// Caster System
bool casterSystemAvailable;

// Reason enum for Countdown cancelling
enum disruptType
{
	readyStatus,
	teamShuffle,
	playerDisconn,
	adminAbort,
	
	disruptType_SIZE
};

// FIXME: Global const array requires static keyword, then how could I share it between modules?
//static const char g_sDisruptReason[disruptType_SIZE][] = 
char g_sDisruptReason[disruptType_SIZE][] =
{
	"取消了准备",
	"切换了阵营",
	"离开了游戏",
	"管理员中止"
};

// Sub modules are included here
#include "readyup-applemod/doorlock.inc"
#include "readyup-applemod/action.inc"
#include "readyup-applemod/command.inc"
#include "readyup-applemod/game.inc"
#include "readyup-applemod/native.inc"
#include "readyup-applemod/panel.inc"
#include "readyup-applemod/player.inc"
#include "readyup-applemod/setup.inc"
#include "readyup-applemod/sound.inc"
#include "readyup-applemod/util.inc"
// 原 optional/12v12/l4d2_doorlock.smx：门锁 + 加载等待 + 倒计时开门，已并入本插件

// ========================
//  Plugin Setup
// ========================
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	SetupNatives();
	SetupForwards();
	RegPluginLibrary("readyup");
	return APLRes_Success;
}

public void OnPluginStart()
{
	SetupConVars();
	SetupCommands();
	
	nativeFooter = new Footer();
	
	readySurvFreeze = l4d_ready_survivor_freeze.BoolValue;
	l4d_ready_survivor_freeze.AddChangeHook(CvarChg_SurvFreeze);

	HookEvent("round_start",			RoundStart_Event, EventHookMode_Pre);
	HookEvent("round_end", ExternalRoundEnd_Event, EventHookMode_PostNoCopy);
	HookEvent("player_team",			PlayerTeam_Event, EventHookMode_Post);
	HookEvent("gameinstructor_draw",	GameInstructorDraw_Event, EventHookMode_PostNoCopy);

	// 门锁模块（原 l4d2_doorlock.smx）
	DL_OnPluginStart();
	l4d_ready_enabled.AddChangeHook(CvarChg_ReadyMode);
	RegAdminCmd("sm_readystatus", ReadyStatus_Cmd, ADMFLAG_CONFIG, "Show ReadyUp / door lock lifecycle state");
}

public void OnPluginEnd()
{
	if (inReadyUp) InitiateLive(false);
	else StopReadyTimers();
	DL_OnPluginEnd();
}

public void OnConfigsExecuted()
{
	DL_OnConfigsExecuted();
}

public void OnAllPluginsLoaded()
{
	FindCasterSystem();
}

public void OnLibraryAdded(const char[] name)
{
	if (StrEqual(name, "caster_system")) casterSystemAvailable = true;
}

public void OnLibraryRemoved(const char[] name)
{
	if (StrEqual(name, "caster_system")) casterSystemAvailable = false;
}

void FindCasterSystem()
{
	casterSystemAvailable = LibraryExists("caster_system");
}

// ========================
//  ConVar Change
// ========================

void CvarChg_ReadyMode(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (inReadyUp) InitiateLive(false);
	readyUpMode = convar.IntValue;
	DL_IsAllowed();
}

Action ReadyStatus_Cmd(int client, int args)
{
	ReplyToCommand(client, "[ReadyUp %s] mode=%d manual=%d external=%d live=%d", PLUGIN_VERSION, l4d_ready_enabled.IntValue, inReadyUp, externalReadyActive, DL_g_bRoundLive);
	ReplyToCommand(client, "[DoorLock] allow=%d effective=%d map=%d configs=%d ended=%d events=%d/%d", DL_g_cAllow.IntValue, DL_g_bCvarAllow, DL_g_bMapStarted, DL_g_bConfigsReady, DL_g_bRoundEnded, DL_g_iRoundStart, DL_g_iPlayerSpawn);
	ReplyToCommand(client, "[DoorLock] human=%d survivor=%d door=%d countdown=%d timer=%d recovery=%d freeze=%d modebits=%d/%d", DL_HasConfirmedHuman(), DL_HasLivingSurvivor(), EntRefToEntIndex(DL_g_iStartDoor), DL_g_iCountDown, DL_g_hTimer != null, DL_g_hRecoveryTimer != null, DL_g_bFreezeAllowed, DL_g_iCurrentMode, DL_g_cModesTog.IntValue);
	// 加载状态面板：现在每一回合都会显示（不再只限第一回合），这里把两个判据打出来便于核对。
	ReplyToCommand(client, "[DoorLock] first_round=%d half=%d displaypanel=%d", DL_g_bFirstRound, GameRules_GetProp("m_bInSecondHalfOfRound"), DL_g_iDisplayPanel);
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || (GetClientTeam(i) != 2 && GetEntityMoveType(i) != MOVETYPE_NONE)) continue;
		ReplyToCommand(client, "[ReadyFreeze] userid=%d team=%d bot=%d alive=%d move=%d owned=%d recent=%d frozenflag=%d speed=%.2f", GetClientUserId(i), GetClientTeam(i), IsFakeClient(i), IsPlayerAlive(i), GetEntityMoveType(i), DL_g_iFrozenUserId[i] == GetClientUserId(i), DL_g_fReleaseUntil > GetGameTime() && DL_g_iReleasedUserId[i] == GetClientUserId(i), (GetEntityFlags(i) & FL_FROZEN) != 0, GetEntPropFloat(i, Prop_Send, "m_flLaggedMovementValue"));
	}
	return Plugin_Handled;
}

void CvarChg_SurvFreeze(ConVar convar, const char[] oldValue, const char[] newValue)
{
	readySurvFreeze = convar.BoolValue;
	
	if (inReadyUp)
	{
		ReturnTeamToSaferoom(L4D2Team_Survivor);
		SetTeamFrozen(L4D2Team_Survivor, readySurvFreeze);
	}
}

// ========================
//  Events
// ========================

void RoundStart_Event(Event event, const char[] name, bool dontBroadcast)
{
	ResetExternalReadyState();
	InitiateReadyUp();
}

void ExternalRoundEnd_Event(Event event, const char[] name, bool dontBroadcast)
{
	ResetExternalReadyState();
	if (inReadyUp) InitiateLive(false);
}

void GameInstructorDraw_Event(Event event, const char[] name, bool dontBroadcast)
{
	// Workaround for restarting countdown after scavenge intro
	CreateTimer(0.1, Timer_RestartCountdowns, false, TIMER_FLAG_NO_MAPCHANGE);
}

void PlayerTeam_Event(Event event, const char[] name, bool dontBroadcast)
{
	int userid = event.GetInt("userid");
	int client = GetClientOfUserId(userid);
	if (!client || IsFakeClient(client))
		return;
	
	SetButtonTime(client);
	
	if (!inReadyUp) return;
	
	SetPlayerReady(client, false);
	
	if (isForceStart)
		return;
	
	int team = event.GetInt("team");
	int oldteam = event.GetInt("oldteam");
	
	// 团队模式 (l4d_ready_enabled=3): 玩家退出/换边/加入队伍改变团队构成,
	// 自动取消对应队伍的准备状态 (整队重置为未准备, 面板团队状态恢复为 [X])
	if (readyUpMode == ReadyMode_TeamReady && team != oldteam)
	{
		if (oldteam == L4D2Team_Survivor || oldteam == L4D2Team_Infected)
			UnreadyTeam(oldteam);
		
		if (team == L4D2Team_Survivor || team == L4D2Team_Infected)
			UnreadyTeam(team);
	}
	
	if (team == L4D2Team_None && oldteam != L4D2Team_Spectator) // Player disconnecting
	{
		CancelFullReady(client, playerDisconn);
	}
	
	else if (!g_hChangeTeamTimer[client]) // Player in-game swapping team
	{
		DataPack dp;
		g_hChangeTeamTimer[client] = CreateDataTimer(0.1, Timer_PlayerTeam, dp);
		dp.WriteCell(client);
		dp.WriteCell(userid);
		dp.WriteCell(oldteam);
	}
}

Action Timer_PlayerTeam(Handle timer, DataPack dp)
{
	dp.Reset();
	
	int client = dp.ReadCell();
	int userid = dp.ReadCell();
	int oldteam = dp.ReadCell();
	
	if (client == GetClientOfUserId(userid))
	{
		if (inLiveCountdown)
		{
			int team = GetClientTeam(client);
			if (team != oldteam)
			{
				if (oldteam != L4D2Team_None || team != L4D2Team_Spectator)
				{
					CancelFullReady(client, teamShuffle);
				}
			}
		}
	}
	
	g_hChangeTeamTimer[client] = null;

	return Plugin_Stop;
}

// ========================
//  Forwards
// ========================

public void OnMapStart()
{
	PrecacheSounds();
	
	for (int client = 1; client <= MAXPLAYERS; client++)
	{
		g_hChangeTeamTimer[client] = null;
	}

	DL_OnMapStart();
}

/* This ensures all cvars are reset if the map is changed during ready-up */
public void OnMapEnd()
{
	ResetExternalReadyState();
	if (inReadyUp)
	{
		InitiateAutoStart(false);
		InitiateLive(false);
	}

	DL_OnMapEnd();
}

public void OnClientPutInServer(int client)
{
	if (inReadyUp && L4D2_IsScavengeMode() && !IsFakeClient(client))
	{
		ToggleCountdownPanel(false, client);
	}
}

public void OnClientDisconnect(int client)
{
	SetPlayerHiddenPanel(client, false);
	SetPlayerReady(client, false);
	g_hChangeTeamTimer[client] = null;

	DL_OnClientDisconnect(client);
}

/* 门锁模块的冻结/倒计时期间保持生还者不动（原来由独立插件自己的 OnPlayerRunCmd 处理） */
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	DL_OnPlayerRunCmd(client);
	return Plugin_Continue;
}

/* 门锁模块需要知道当前游戏模式（原来由独立插件的 L4D_OnGameModeChange 处理） */
public void L4D_OnGameModeChange(int gamemode)
{
	DL_L4D_OnGameModeChange(gamemode);
}

/* No need to do any other checks since it seems like this is required no matter what since the intros unfreezes players after the animation completes */
public void OnPlayerRunCmdPost(int client, int buttons, int impulse, const float vel[3], const float angles[3], int weapon, int subtype, int cmdnum, int tickcount, int seed, const int mouse[2])
{
	if (inReadyUp && IsClientInGame(client))
	{
		if (!IsFakeClient(client))
		{
			static int iLastMouse[MAXPLAYERS+1][2];
			
			// Mouse Movement Check
			if (mouse[0] != iLastMouse[client][0] || mouse[1] != iLastMouse[client][1])
			{
				iLastMouse[client][0] = mouse[0];
				iLastMouse[client][1] = mouse[1];
				SetButtonTime(client);
			}
			else if (buttons || impulse) SetButtonTime(client);
		}
		
		if (GetClientTeam(client) == L4D2Team_Survivor)
		{
			if (readySurvFreeze || inLiveCountdown)
			{
				MoveType iMoveType = GetEntityMoveType(client);
				if (iMoveType != MOVETYPE_NONE && iMoveType != MOVETYPE_NOCLIP)
				{
					SetClientFrozen(client, true);
				}
			}
			else
			{
				if (GetEntProp(client, Prop_Send, "m_nWaterLevel") == WL_Eyes)
				{
					ReturnPlayerToSaferoom(client, false);
				}
			}
		}
	}
}

public Action L4D_OnFirstSurvivorLeftSafeArea(int client)
{
	if (DL_g_bCvarAllow && !DL_g_bRoundLive && !DL_g_bRoundEnded && (externalReadyActive || DL_g_hRecoveryTimer != null))
	{
		// Cover the short recovery interval before the lock timer starts as well.
		ReturnPlayerToSaferoom(client, false);
		return Plugin_Handled;
	}
	if (inReadyUp)
	{
		CreateTimer(0.1, Timer_RestartCountdowns, false, TIMER_FLAG_NO_MAPCHANGE);
		ReturnPlayerToSaferoom(client, false);
		return Plugin_Handled;
	}
	return Plugin_Continue;
}

// ========================
//  Command Listener
// ========================

public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
	// 修复: 服务器控制台说话时 client = 0, 直接调用 SetButtonTime 会触发 "Client index 0 is invalid" 异常
	if (!client) return Plugin_Continue;
	SetButtonTime(client);
	return Plugin_Continue;
}

Action Vote_Callback(int client, const char[] command, int argc)
{
	// Fast ready / unready through default keybinds for voting
	if (!client) return Plugin_Continue;
	if (BuiltinVote_IsVoteInProgress() && IsClientInBuiltinVotePool(client)) return Plugin_Continue;
	
	if (Game_IsVoteInProgress())
	{
		int voteteam = Game_GetVoteTeam();
		if (voteteam == -1 || voteteam == GetClientTeam(client))
		{
			return Plugin_Continue;
		}
	}
	
	char sArg[8];
	GetCmdArg(1, sArg, sizeof(sArg));
	if (strcmp(sArg, "Yes", false) == 0)
		Ready_Cmd(client, 0);
	else if (strcmp(sArg, "No", false) == 0)
		Unready_Cmd(client, 0);

	return Plugin_Continue;
}
