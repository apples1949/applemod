/******************************************************************
*
* v0.1 ~ v1.2 by Visor
* ------------------------
* ------- Details: -------
* ------------------------
* > Creates a timer that runs checks to prevent Survivors from baiting attacks (Which is extremely boring)
* - Keeps track of Readyup, Event Hordes, Tanks, and Pauses to prevent sending in hordes unfairly.
*
* v1.3 by Sir (pointer to hordeDelayChecks by devilesk)
* ------------------------
* ------- Details: -------
* ------------------------
* - Now resets internal "hordeDelayChecks" on Round Live to prevent teams from suddenly getting a horde shortly after the round goes live. (Timer wouldn't even be visible at the top)
* - Now also resets saved "baiting" progress that didn't get reset after Event Hordes / Tank Spawns were triggered (Although, it'd be very unlikely that no SI would go in while these were active)
* - Fixed the Timer from showing up on the top while Tank was alive and SI just weren't attacking (to reset the timer) this was only a visual thing though, as the plugin already didn't spawn in horde when a Tank was up.
*
* v1.4.1-SafeArea by apples1949 (copy of l4d2_antibaiter.sp, modified)
* ------------------------
* ------- Details: -------
* ------------------------
* - 新增限制：本回合没有任何生还者离开起点安全区之前，不会触发时间限制——
*   既不累计 hordeDelayChecks，也不弹出倒计时面板，更不会强制刷尸潮。
* - 放行条件：本回合收到过 player_left_start_area（即确实有玩家离开起点安全区，
*   与插件原本判定“回合开始”用的是同一个信号），收到后本回合一直放行。
* - 目的：readyup 回合 go-live（OnRoundIsLive）时生还者往往还留在安全区里买枪/整理装备，
*   原版会把这段“零进展”当成 baiting 并直接刷尸潮；改后这段时间不再计时。
* - 每回合重新上锁：round_start / round_end 复位标记，不会跨回合残留。
*
******************************************************************/

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <left4dhooks>
#include <sdkhooks>
#include <colors>
#define L4D2UTIL_STOCKS_ONLY 1
#include <l4d2util>
#undef REQUIRE_PLUGIN
#include <pause>
#include <readyup>

#define DEBUG 0

#define CDIRECTOR_GAMEDATA "l4d2_cdirector" //m_PostMobDelayTimer offset

//#define LEFT4FRAMEWORK_GAMEDATA "left4dhooks.l4d2" //left4dhooks gamedata
//#define CDIRECTORSCRIPTEDEVENTMANAGER "ScriptedEventManagerPtr" //left4dhooks gamedata

//#define LEFT4FRAMEWORK_GAMEDATA "l4d2_direct" //l4d2_direct gamedata
//#define CDIRECTORSCRIPTEDEVENTMANAGER "CDirectorScriptedEventManager" //l4d2_direct gamedata

ConVar
	hCvarTimerStartDelay,
	hCvarHordeCountdown,
	hCvarMinProgressThreshold,
	hCvarStopTimerOnBile;

bool
	IsRoundIsActive,
	IsPauseAvailable,
	hasLeftStartArea; // 本回合是否有玩家离开过起点安全区（没有则整条 antibaiter 逻辑不生效）

float
	timerStartDelay,
	hordeCountdown,
	minProgress,
	aliveSince[MAXPLAYERS + 1],
	startingSurvivorCompletion;

int
	m_PostMobDelayTimerOffset,
	z_max_player_zombies,
	hordeDelayChecks,
	zombieclass[MAXPLAYERS + 1];

public Plugin myinfo = 
{
	name = "L4D2 Antibaiter (SafeArea)",
	author = "Visor, Sir (assisted by Devilesk), A1m`, apples1949",
	description = "Makes you think twice before attempting to bait that shit (no timer until a Survivor leaves the start area)",
	version = "1.4.1",
	url = "https://github.com/SirPlease/L4D2-Competitive-Rework"
};

public void OnPluginStart()
{
	InitGameData();
	
	hCvarTimerStartDelay = CreateConVar("l4d2_antibaiter_delay", "20", "Delay in seconds before the antibait algorithm kicks in");
	hCvarHordeCountdown = CreateConVar("l4d2_antibaiter_horde_timer", "60", "Countdown in seconds to the panic horde");
	hCvarMinProgressThreshold = CreateConVar("l4d2_antibaiter_progress", "0.03", "Minimum progress the survivors must make to reset the antibaiter timer");
	hCvarStopTimerOnBile = CreateConVar("l4d2_antibaiter_bile_stop", "0", "Stop timer when a player is biled?");

	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("player_now_it", Event_PlayerBiled, EventHookMode_Post);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
	HookEvent("player_left_start_area", Event_RoundGoesLive, EventHookMode_PostNoCopy);
	
	CreateTimer(1.0, AntibaiterThink, _, TIMER_REPEAT);

#if DEBUG
	RegConsoleCmd("sm_regsi", RegisterSI);
#endif
}

void InitGameData()
{
	Handle hGamedata2 = LoadGameConfigFile(CDIRECTOR_GAMEDATA);
	if (!hGamedata2) {
		SetFailState("Gamedata '%s' missing or corrupt", CDIRECTOR_GAMEDATA);
	}
	
	m_PostMobDelayTimerOffset = GameConfGetOffset(hGamedata2, "CDirectorScriptedEventManager->m_PostMobDelayTimer");
	if (m_PostMobDelayTimerOffset == -1) {
		SetFailState("Invalid offset '%s'.", "CDirectorScriptedEventManager->m_PostMobDelayTimer");
	}
	
	delete hGamedata2;
}

void Event_RoundStart(Event hEvent, const char[] name, bool dontBroadcast)
{
	IsRoundIsActive = false;
	hasLeftStartArea = false; // 新回合重新上锁
}

void Event_RoundEnd(Event hEvent, const char[] name, bool dontBroadcast)
{
	IsRoundIsActive = false;
	hasLeftStartArea = false; // 兜底：即使 round_start 没收到也不会跨回合残留
}

void Event_RoundGoesLive(Event hEvent, const char[] name, bool dontBroadcast)
{
	//This event works great with the plugin readyup.smx (does not conflict)
	//This event works great in different game modes: versus, coop, scavenge and etc

	// 有玩家离开起点安全区了，解除 antibaiter 的前置锁
	// （注意：本回调是 PostNoCopy，事件数据不会被拷贝，所以这里只置位、不读字段）
	hasLeftStartArea = true;

	StartRound();
}

void Event_PlayerBiled(Event hEvent, const char[] name, bool dontBroadcast)
{
	bool byBoom = hEvent.GetBool("by_boomer");
	if (byBoom && hCvarStopTimerOnBile.BoolValue)
	{
		hordeDelayChecks = 0;
		if (IsCountdownRunning()) {
			HideCountdown();
			StopCountdown();
		}
	}
}

public void OnRoundIsLive()
{
	StartRound();
}

#if DEBUG
Action RegisterSI(int client, int args)
{
	StartRound();
	return Plugin_Handled;
}
#endif

void StartRound()
{
	for (int i = 1; i <= MaxClients; i++) {
		if (IsInfected(i) && IsPlayerAlive(i)) {
			zombieclass[i] = GetInfectedClass(i);
			aliveSince[i] = GetGameTime();
		}
	}

	hordeDelayChecks = 0; // Needs to be reset as it's not reset on Round End. (Prevents the Plugin from just picking up where it left off)
	IsRoundIsActive = true;
}

public void OnAllPluginsLoaded()
{
	IsPauseAvailable = LibraryExists("pause");
}

public void OnLibraryRemoved(const char[] szName)
{
	if (strcmp(szName, "pause", true) == 0) {
		IsPauseAvailable = false;
	} 
}

public void OnLibraryAdded(const char[] szName)
{
	if (strcmp(szName, "pause", true) == 0) {
		IsPauseAvailable = true;
	}
}

public void OnConfigsExecuted()
{
	z_max_player_zombies = (FindConVar("z_max_player_zombies")).IntValue;
	timerStartDelay = hCvarTimerStartDelay.FloatValue;
	hordeCountdown = hCvarHordeCountdown.FloatValue;
	minProgress = hCvarMinProgressThreshold.FloatValue;
}

Action AntibaiterThink(Handle hTimer)
{
	if (!IsRoundActive()) {
		return Plugin_Handled;
	}

	// 本回合还没有任何生还者离开起点安全区：不触发时间限制。
	// （readyup 让回合 go-live 时生还者通常还在安全区里，这段时间不该按 baiting 处理）
	if (!hasLeftStartArea) {
		hordeDelayChecks = 0;
		if (IsCountdownRunning()) {
			HideCountdown();
			StopCountdown();
		}
		return Plugin_Handled;
	}

	// These are all Events where we shouldn't even save Antibaiter's current status, invalidate the timer if it is active.
	if (IsPanicEventInProgress() || L4D2Direct_GetTankCount() > 0) {
		hordeDelayChecks = 0;
		if (IsCountdownRunning()) {
			HideCountdown();
			StopCountdown();
		}
		return Plugin_Handled;
	}

	int eligibleZombies;
	for (int i = 1; i <= MaxClients; i++)  {
		if (!IsInfected(i) || IsFakeClient(i)) {
			continue;
		}
		
		if (IsPlayerAlive(i)) {
			zombieclass[i] = GetInfectedClass(i);
			if (zombieclass[i] > L4D2Infected_Common && zombieclass[i] < L4D2Infected_Witch
				&& aliveSince[i] != -1.0 && GetGameTime() - aliveSince[i] >= timerStartDelay
			) {
				#if DEBUG
				PrintToChatAll("\x03[Antibaiter DEBUG] Eligible player \x04%N\x01 is a zombieclass \x05%d\x01 alive for \x05%fs\x01", i, zombieclass[i], GetGameTime() - aliveSince[i]);
				#endif
				
				eligibleZombies++;
			}
		} else {
			aliveSince[i] = -1.0;
			hordeDelayChecks = 0;
			HideCountdown();
			StopCountdown();
		}
	}

	// 5th SI / spectator bug workaround
	if (eligibleZombies > z_max_player_zombies) {
	#if DEBUG
		PrintToChatAll("\x03[Antibaiter DEBUG] Spectator bug detected: \x04eligibleZombies\x01=\x05%d\x01, \x04z_max_player_zombies\x01=\x05%d\x01", eligibleZombies, z_max_player_zombies);
	#endif
		return Plugin_Continue;
	}

	if (eligibleZombies == z_max_player_zombies) {
		float survivorCompletion = GetMaxSurvivorCompletion();
		float progress = survivorCompletion - startingSurvivorCompletion;

		if (progress <= minProgress
			&& hordeDelayChecks >= RoundToNearest(timerStartDelay)
		) {
			#if DEBUG
			PrintToChatAll("\x03[Antibaiter DEBUG] Minimum progress unsatisfied during \x05%d\x01 checks: \x04initial\x01=\x05%f\x01, \x04current\x01=\x05%f\x01, \x04progress\x01=\x05%f\x01", hordeDelayChecks, startingSurvivorCompletion, survivorCompletion, progress);
			#endif
			
			if (IsCountdownRunning()) {
				#if DEBUG
				PrintToChatAll("\x03[Antibaiter DEBUG] Countdown is \x05running\x01");
				#endif
				
				if (HasCountdownElapsed()) {
					#if DEBUG
					PrintToChatAll("\x03[Antibaiter DEBUG] Countdown has \x04elapsed\x01! Launching horde and resetting checks counter");
					#endif
					
					HideCountdown();
					LaunchHorde();
					hordeDelayChecks = 0;
					CPrintToChatAll("{blue}[{default}Anti-baiter{blue}]{default} Prepare for the incoming horde!");
				}
			} else {
				#if DEBUG
				PrintToChatAll("\x03[Antibaiter DEBUG] Countdown is \x05not running\x01. Initiating it...");
				#endif
				
				InitiateCountdown();
			}
		} else {
			if (hordeDelayChecks == 0) {
				startingSurvivorCompletion = survivorCompletion;
			}
			
			if (progress > minProgress) {
				#if DEBUG
				PrintToChatAll("\x03[Antibaiter DEBUG] Survivor progress has \x05increased\x01 beyond the minimum threshold. Resetting the algorithm...");
				#endif

				startingSurvivorCompletion = survivorCompletion;
				hordeDelayChecks = 0;
			}

			hordeDelayChecks++;
			HideCountdown();
			StopCountdown();
		}
	}

	return Plugin_Handled;
}

public void L4D_OnEnterGhostState(int client)
{
	zombieclass[client] = GetInfectedClass(client);
	aliveSince[client] = GetGameTime();
}

/*******************************/
/** Horde/countdown functions **/
/*******************************/

void InitiateCountdown()
{
	for (int i = 1; i <= MaxClients; i++) {
		if (IsClientInGame(i) && !IsFakeClient(i)) {
			ShowVGUIPanel(i, "ready_countdown", _, true);
		}
	}

	CTimer_Start(CountdownPointer(), hordeCountdown);
}

bool IsCountdownRunning()
{
	return CTimer_HasStarted(CountdownPointer());
}

bool HasCountdownElapsed()
{
	return CTimer_IsElapsed(CountdownPointer());
}

void StopCountdown()
{
	CTimer_Invalidate(CountdownPointer());
}

void HideCountdown()
{
	for (int i = 1; i <= MaxClients; i++) {
		if (IsClientInGame(i) && !IsFakeClient(i)) {
			ShowVGUIPanel(i, "ready_countdown", _, false);
		}
	}
}

void LaunchHorde()
{
	int client = -1;
	for (int i = 1; i <= MaxClients; i++) {
		if (IsClientInGame(i) && !IsFakeClient(i)) {
			client = i;
			break;
		}
	}

	if (client == -1) {
		return;
	}
	
	#if DEBUG
	PrintToChatAll("m_PanicTimer - duration: %f, timestamp: %f", CTimer_GetDuration(PanicTimer()), CTimer_GetTimestamp(PanicTimer()));
	#endif
	
	int info_director = MaxClients+1;
	if ((info_director = FindEntityByClassname(info_director, "info_director")) != INVALID_ENT_REFERENCE)
	{
		AcceptEntityInput(info_director, "ForcePanicEvent");
	}
}

CountdownTimer CountdownPointer()
{
	return L4D2Direct_GetScavengeRoundSetupTimer();
}

CountdownTimer PostMobDelayTimer()
{
	return view_as<CountdownTimer>(L4D_GetPointer(POINTER_EVENTMANAGER) + view_as<Address>(m_PostMobDelayTimerOffset));
}

/************/
/** Stocks **/
/************/
float GetMaxSurvivorCompletion()
{
	float flow = 0.0;
	for (int i = 1; i <= MaxClients; i++) {
		// Prevent rushers from convoluting the logic
		if (IsSurvivor(i) && IsPlayerAlive(i) && !IsIncapacitated(i)) {
			flow = L4D2Util_GetMaxFloat(flow, L4D2Direct_GetFlowDistance(i));
		}
	}

	return (flow / L4D2Direct_GetMapMaxFlowDistance());
}

//Сan use prop 'm_bPanicEventInProgress' better?
// director_force_panic_event & car alarms etc.
bool IsPanicEventInProgress()
{
	CountdownTimer pPanicCountdown = PostMobDelayTimer();
	
	#if DEBUG
	PrintToChatAll("m_PostMobDelay - duration: %f, timestamp: %f", CTimer_GetDuration(pPanicCountdown), CTimer_GetTimestamp(pPanicCountdown));
	#endif
	
	if (!CTimer_IsElapsed(pPanicCountdown)) {
		return true;
	}
	
	if (CTimer_HasStarted(L4D2Direct_GetMobSpawnTimer())) {
		return (RoundFloat(CTimer_GetRemainingTime(L4D2Direct_GetMobSpawnTimer())) <= 10.0);
	}
	
	return false;
}

bool IsRoundActive()
{
	if (!IsRoundIsActive || IsPauseAvailable && IsInPause()) {
		return false;
	}
	
	return true;
}
