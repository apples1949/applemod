#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <left4dhooks>
#include <l4d2lib>
#include <sdktools>
#include <colors>
#undef REQUIRE_PLUGIN
#include <confogl>
#define REQUIRE_PLUGIN

#define Z_TANK 8
#define TEAM_INFECTED 3

#define HORDE_MIN_SIZE_AUDIAL_FEEDBACK 120
#define MAX_CHECKPOINTS 4

#define HORDE_SOUND "/npc/mega_mob/mega_mob_incoming.wav"

ConVar
	hCvarNoEventHordeDuringTanks,
	hCvarHordeCheckpointAnnounce;

int
	commonLimit = -1,
	commonTank,
	commonTotal,
	lastCheckpoint;

bool
	announcedInChat,
	announcedEventEnd,
	finiteHordeActive;

public Plugin myinfo = 
{
	name = "L4D2 Horde Equaliser (tranchi)",
	author = "apples1949",
	description = "Make certain event hordes finite",
	version = "3.0.12-applefix",
	url = "https://github.com/SirPlease/L4D2-Competitive-Rework"
};

public void OnPluginStart()
{
	LoadTranslation("l4d2_horde_equaliser.phrases");
	
	hCvarNoEventHordeDuringTanks = CreateConVar("l4d2_heq_no_tank_horde", "0", "有坦克时停止刷新尸潮");
	hCvarHordeCheckpointAnnounce = CreateConVar("l4d2_heq_checkpoint_sound", "1", "在检测点播放尸潮声音(每清理1/4的尸潮),以模拟求生1");

	HookEvent("round_start", RoundStartEvent, EventHookMode_PostNoCopy);
	RegConsoleCmd("sm_hordestatus", Command_HordeStatus, "Print finite map-event horde state (does not change the event).");
}

void RefreshMapLimits()
{
	// Confogl's map context is authoritative when present. The always-loaded
	// L4D2Lib may have selected its fallback file before the match config loaded.
	if (GetFeatureStatus(FeatureType_Native, "LGO_IsMapDataAvailable") == FeatureStatus_Available
		&& GetFeatureStatus(FeatureType_Native, "LGO_GetMapValueInt") == FeatureStatus_Available
		&& LGO_IsMapDataAvailable()) {
		commonLimit = LGO_GetMapValueInt("horde_limit", -1);
		commonTank = LGO_GetMapValueInt("horde_tank", -1);
	} else {
		commonLimit = L4D2_GetMapValueInt("horde_limit", -1);
		commonTank = L4D2_GetMapValueInt("horde_tank", -1);
	}
}

public void OnMapStart()
{
	RefreshMapLimits();
	ResetHorde();
	PrecacheSound(HORDE_SOUND);
}

void RoundStartEvent(Event hEvent, const char[] name, bool dontBroadcast)
{
	ResetHorde();
	RefreshMapLimits();
}

void ResetHorde()
{
	commonTotal = 0;
	lastCheckpoint = 0;
	announcedInChat = false;
	announcedEventEnd = false;
	finiteHordeActive = false;
}

public void OnMapEnd()
{
	ResetHorde();
	commonLimit = -1;
	commonTank = -1;
}

public void OnConfigsExecuted()
{
	if (!finiteHordeActive) RefreshMapLimits();
}

Action Command_HordeStatus(int client, int args)
{
	if (!finiteHordeActive) RefreshMapLimits();
	char map[128];
	GetCurrentMap(map, sizeof(map));
	ReplyToCommand(client, "[Horde] v3.0.12-applefix | map=%s | limit=%d | spawned=%d | active=%d | finished=%d | countdown=%d | pending=%d | tank_pause=%d",
		map, commonLimit, commonTotal, finiteHordeActive, announcedEventEnd,
		GetHordeCountdown(), L4D2Direct_GetPendingMobCount(), IsHordePausedForTank());
	ReplyToCommand(client, "[Horde] limit=-1: this map has no finite-event override. Boomer/bile hordes and map objective completion use separate rules.");
	return Plugin_Handled;
}

bool IsHordePausedForTank()
{
	return (hCvarNoEventHordeDuringTanks.BoolValue || commonTank > 0) && IsTankUp();
}

void FinishFiniteHorde()
{
	L4D2Direct_SetPendingMobCount(0);
	if (!announcedEventEnd) {
		CPrintToChatAll("<{olive}Horde{default}> {olive}尸潮事件 {default}结束，开始冲锋!");
		announcedEventEnd = true;
	}
}

public void OnEntityCreated(int entity, const char[] classname)
{
	// Arm only from a map-event SpawnMob request. Once queued, its commons can
	// spawn after the Director has reset the countdown above ten seconds.
	if (strcmp(classname, "infected") == 0 && finiteHordeActive && !announcedEventEnd) {
		if (IsHordePausedForTank()) {
			return;
		}
		commonTotal++;
		if (commonTotal >= commonLimit) {
			FinishFiniteHorde();
			return;
		}
		if (hCvarHordeCheckpointAnnounce.BoolValue && lastCheckpoint < MAX_CHECKPOINTS &&
			(commonTotal >= ((lastCheckpoint + 1) * RoundToCeil(float(commonLimit) / float(MAX_CHECKPOINTS))))
		) {
			if (commonLimit >= HORDE_MIN_SIZE_AUDIAL_FEEDBACK) {
				EmitSoundToAll(HORDE_SOUND);
			}
			
			int remaining = commonLimit - commonTotal;
			if (remaining != 0) {
				CPrintToChatAll("<{olive}Horde{default}> 还剩 {olive}%i{default} 个..", remaining);
			}
			
			lastCheckpoint++;
		}
	}
}

public Action L4D_OnSpawnMob(int &amount)
{
	/////////////////////////////////////
	// - Called on Event Hordes.
	// - Called on Panic Event Hordes.
	// - Called on Natural Hordes.
	// - Called on Onslaught (Mini-finale or finale Scripts)

	// - Not Called on Boomer Hordes.
	// - Not Called on z_spawn mob.
	////////////////////////////////////
	
	// "Pause" the infinite horde during the Tank fight
	if (!finiteHordeActive) RefreshMapLimits();

	if (IsHordePausedForTank() && IsInfiniteHordeActive()
	){
		SetPendingMobCount(0);
		amount = 0;
		return Plugin_Handled;
	}

	// Excluded map -- don't block any infinite hordes on this one
	if (commonLimit < 0) {
		return Plugin_Continue;
	}

	// If it's a "finite" infinite horde...
	if (IsInfiniteHordeActive()) {
		// Earlier hooks can block a request (for example during a Tank).
		// Such a request does not begin a new finite event.
		if (amount <= 0 && !finiteHordeActive) return Plugin_Continue;
		finiteHordeActive = true;
		if (!announcedInChat) {
			CPrintToChatAll("<{olive}Horde{default}> {blue}有限尸潮事件{default} 已经开始, 将刷出 {olive}%i{default} 个僵尸! 冲或者守，决定在于你们!", commonLimit);
			announcedInChat = true;
		}
		
		// ...and it's overlimit...
		if (commonTotal >= commonLimit) {
			FinishFiniteHorde();
			amount = 0;
			return Plugin_Handled;
		}
	}
	
	// ...or not.
	return Plugin_Continue;
}

public void L4D_OnSpawnMob_PostHandled(int amount)
{
	// Run after all pre-hooks: another monitor must not revive a completed
	// event's pending queue, regardless of plugin load order.
	if (finiteHordeActive && announcedEventEnd && IsInfiniteHordeActive())
		L4D2Direct_SetPendingMobCount(0);
}

bool IsInfiniteHordeActive()
{
	int countdown = GetHordeCountdown();
	return (countdown > -1 && countdown <= 10);
}

void SetPendingMobCount(int count)
{
	L4D2Direct_SetPendingMobCount(count);
}

int GetHordeCountdown()
{
	return (CTimer_HasStarted(L4D2Direct_GetMobSpawnTimer())) ? RoundFloat(CTimer_GetRemainingTime(L4D2Direct_GetMobSpawnTimer())) : -1;
}

bool IsTankUp()
{
	for (int i = 1; i <= MaxClients; i++) {
		if (IsClientInGame(i) && GetClientTeam(i) == TEAM_INFECTED) {
			if (GetEntProp(i, Prop_Send, "m_zombieClass") == Z_TANK && IsPlayerAlive(i)) {
				return true;
			}
		}
	}

	return false;
}

/**
 * Check if the translation file exists
 *
 * @param translation	Translation name.
 * @noreturn
 */
stock void LoadTranslation(const char[] translation)
{
	char
		sPath[PLATFORM_MAX_PATH],
		sName[64];

	FormatEx(sName, sizeof(sName), "translations/%s.txt", translation);
	BuildPath(Path_SM, sPath, sizeof(sPath), sName);
	if (!FileExists(sPath))
		SetFailState("Missing translation file %s.txt", translation);

	LoadTranslations(translation);
}
