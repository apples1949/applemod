#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <left4dhooks>
#include <l4d2lib>
#include <sdktools>
#include <colors>

#define Z_TANK 8
#define TEAM_INFECTED 3

#define ZOMBIEMANAGER_GAMEDATA "l4d2_zombiemanager"
#define LEFT4FRAMEWORK_GAMEDATA "left4dhooks.l4d2"

#define HORDE_MIN_SIZE_AUDIAL_FEEDBACK 120
#define MAX_CHECKPOINTS 4

#define HORDE_SOUND "/npc/mega_mob/mega_mob_incoming.wav"

ConVar
	hCvarNoEventHordeDuringTanks,
	hCvarHordeCheckpointAnnounce;

Address
	pZombieManager = Address_Null;

int
	commonLimit,
	commonTank,
	commonTotal,
	lastCheckpoint,
	m_nPendingMobCount;

bool
	announcedInChat,
	announcedEventEnd,
	checkpointAnnounced[MAX_CHECKPOINTS];

public Plugin myinfo = 
{
	name = "L4D2 Horde Equaliser",
	author = "Visor (original idea by Sir), A1m`",
	description = "Make certain event hordes finite",
	version = "3.0.10",
	url = "https://github.com/SirPlease/L4D2-Competitive-Rework"
};

public void OnPluginStart()
{
	LoadTranslation("l4d2_horde_equaliser.phrases");
	InitGameData();
	
	hCvarNoEventHordeDuringTanks = CreateConVar("l4d2_heq_no_tank_horde", "0", "有坦克时停止刷新尸潮");
	hCvarHordeCheckpointAnnounce = CreateConVar("l4d2_heq_checkpoint_sound", "1", "在检测点播放尸潮声音(每清理1/4的尸潮),以模拟求生1");

	HookEvent("round_start", RoundStartEvent, EventHookMode_PostNoCopy);
}

void InitGameData()
{
	Handle hDamedata = LoadGameConfigFile(LEFT4FRAMEWORK_GAMEDATA);
	if (!hDamedata) {
		SetFailState("%s gamedata missing or corrupt", LEFT4FRAMEWORK_GAMEDATA);
	}

	pZombieManager = GameConfGetAddress(hDamedata, "ZombieManager");
	if (!pZombieManager) {
		SetFailState("Couldn't find the 'ZombieManager' address");
	}
	
	delete hDamedata;

	Handle hDamedata2 = LoadGameConfigFile(ZOMBIEMANAGER_GAMEDATA);
	if (!hDamedata2) {
		SetFailState("%s gamedata missing or corrupt", ZOMBIEMANAGER_GAMEDATA);
	}
	
	m_nPendingMobCount = GameConfGetOffset(hDamedata2, "ZombieManager->m_nPendingMobCount");
	if (m_nPendingMobCount == -1) {
		SetFailState("Failed to get offset 'ZombieManager->m_nPendingMobCount'.");
	}

	delete hDamedata2;
}

public void OnMapStart()
{
	commonLimit = L4D2_GetMapValueInt("horde_limit", -1);
	commonTank = L4D2_GetMapValueInt("horde_tank", -1);

	PrecacheSound(HORDE_SOUND);
}

void RoundStartEvent(Event hEvent, const char[] name, bool dontBroadcast)
{
	commonTotal = 0;
	lastCheckpoint = 0;
	announcedInChat = false;
	announcedEventEnd = false;
	for (int i = 0; i < MAX_CHECKPOINTS; i++) {
		checkpointAnnounced[i] = false;
	}
}

public void OnEntityCreated(int entity, const char[] classname)
{
	// TO-DO: Find a value that tells wanderers from active event commons?
	if (strcmp(classname, "infected") == 0 && IsInfiniteHordeActive()) {
		// Don't count in boomer hordes, alarm cars and wanderers during a Tank fight
		if (hCvarNoEventHordeDuringTanks.BoolValue && IsTankUp()) {
			return;
		}
		
		// Our job here is done
		if (commonTotal >= commonLimit) {
			if (!announcedEventEnd){
<<<<<<< HEAD
				CPrintToChatAll("<{olive}Horde{default}> {olive}尸潮事件 {default}结束，开始冲锋!");
=======
				CPrintToChatAll("%t %t", "Tag", "NoCommonRemaining");
>>>>>>> 7348c0ae763e6e53210113ee97cb55e4d4d3566b
				announcedEventEnd = true;
			}
			return;
		}
		
		commonTotal++;
		if (hCvarHordeCheckpointAnnounce.BoolValue && 
			(commonTotal >= ((lastCheckpoint + 1) * RoundFloat(float(commonLimit / MAX_CHECKPOINTS))))
		) {
			if (commonLimit >= HORDE_MIN_SIZE_AUDIAL_FEEDBACK) {
				EmitSoundToAll(HORDE_SOUND);
			}
			
			int remaining = commonLimit - commonTotal;
			if (remaining != 0) {
<<<<<<< HEAD
				CPrintToChatAll("<{olive}Horde{default}> 还剩 {olive}%i{default} 个..", remaining);
=======
				CPrintToChatAll("%t %t", "Tag", "CommonRemaining", remaining);
>>>>>>> 7348c0ae763e6e53210113ee97cb55e4d4d3566b
			}
			
			checkpointAnnounced[lastCheckpoint] = true;
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
	if ((hCvarNoEventHordeDuringTanks.BoolValue || commonTank > 0) 
		&& IsTankUp() && IsInfiniteHordeActive()
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
		if (!announcedInChat) {
<<<<<<< HEAD
			CPrintToChatAll("<{olive}Horde{default}> {blue}有限尸潮事件{default} 已经开始, 将刷出 {olive}%i{default} 个僵尸! 冲或者守，决定在于你们!", commonLimit);
=======
			CPrintToChatAll("%t %t", "Tag", "FiniteEventStarted", commonLimit);
>>>>>>> 7348c0ae763e6e53210113ee97cb55e4d4d3566b
			announcedInChat = true;
		}
		
		// ...and it's overlimit...
		if (commonTotal >= commonLimit) {
			SetPendingMobCount(0);
			amount = 0;
			return Plugin_Handled;
		}
		// commonTotal += amount;
	}
	
	// ...or not.
	return Plugin_Continue;
}

bool IsInfiniteHordeActive()
{
	int countdown = GetHordeCountdown();
	return (/*GetPendingMobCount() > 0 &&*/ countdown > -1 && countdown <= 10);
}

/*
int GetPendingMobCount()
{
	return LoadFromAddress(pZombieManager + view_as<Address>(m_nPendingMobCount), NumberType_Int32);
}
*/

void SetPendingMobCount(int count)
{
	StoreToAddress(pZombieManager + view_as<Address>(m_nPendingMobCount), count, NumberType_Int32);
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

	Format(sName, sizeof(sName), "translations/%s.txt", translation);
	BuildPath(Path_SM, sPath, sizeof(sPath), sName);
	if (!FileExists(sPath))
		SetFailState("Missing translation file %s.txt", translation);

	LoadTranslations(translation);
}