#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <l4d2util_constants>
#undef REQUIRE_PLUGIN
#include <readyup>
#include <left4dhooks>

#define DEBUG					0
#define ENTITY_NAME_MAX_SIZE	64

enum
{
	//L4D2WeaponSlot_HeavyHealthItem
	HEALTH_FIRST_AID_KIT	= (1 << 0), // 1
	HEALTH_DEFIBRILLATOR	= (1 << 1), // 2

	//L4D2WeaponSlot_LightHealthItem
	HEALTH_PAIN_PILLS		= (1 << 2), // 4
	HEALTH_ADRENALINE		= (1 << 3), // 8

	//L4D2WeaponSlot_Throwable
	THROWABLE_PIPE_BOMB		= (1 << 4), // 16
	THROWABLE_MOLOTOV		= (1 << 5), // 32
	THROWABLE_VOMITJAR		= (1 << 6) // 64
};

ConVar
	g_hCvarItemType = null,
	g_hCvarOnLeave = null;

Handle g_hGrantTimer;
float g_fRoundStarted, g_fGrantAfter;
bool g_bRoundActive, g_bLeftStartArea, g_bGrantRequested, g_bTargetsCaptured;
int g_iTargetSerial[MAXPLAYERS + 1], g_iGrantedFlags[MAXPLAYERS + 1];
int g_iSeenStartSerial[MAXPLAYERS + 1];
int g_iRoundFlags, g_iAttempts, g_iGrantedItems, g_iFailedItems;

bool
	g_bReadyUpAvailable = false,
	g_bItemsGivenThisRound = true; // Late loads wait for the next round_start.

public Plugin myinfo =
{
	name = "Starting Items",
	author = "CircleSquared, Jacob, A1m`",
	description = "Gives health items and throwables to survivors at the start of each round",
	version = "2.3.1",
	url = "https://github.com/SirPlease/L4D2-Competitive-Rework"
};

public void OnPluginStart()
{
	g_hCvarItemType = CreateConVar("starting_item_flags", \
		"0", \
		"Item flags to give on leaving the saferoom (0: Disable, 1: Kit, 2: Defib, 4: Pills, 8: Adren, 16: Pipebomb, 32: Molotov, 64: Bile)", \
		_, false, 0.0, true, 127.0 \
	);
	g_hCvarOnLeave = CreateConVar("starting_items_on_leave", "0", \
		"0: legacy ReadyUp live timing; 1: only give after a survivor actually leaves the start area", \
		_, true, 0.0, true, 1.0);

	HookEvent("round_start", RoundStart, EventHookMode_PostNoCopy);
	HookEvent("round_end", RoundEnd, EventHookMode_PostNoCopy);
	HookEvent("player_left_start_area", PlayerLeftStartArea, EventHookMode_PostNoCopy);
	RegAdminCmd("sm_startitemsstatus", Cmd_Status, ADMFLAG_GENERIC, "Show medical item settings and grant state");

#if DEBUG
	RegAdminCmd("sm_give_starting_items", Cmd_GiveStartingItems, ADMFLAG_KICK);
#endif
}

public void OnAllPluginsLoaded()
{
	g_bReadyUpAvailable = LibraryExists("readyup");
}

public void OnLibraryRemoved(const char[] sPluginName)
{
	if (strcmp(sPluginName, "readyup") == 0) {
		g_bReadyUpAvailable = false;
	}
}

public void OnLibraryAdded(const char[] sPluginName)
{
	if (strcmp(sPluginName, "readyup") == 0) {
		g_bReadyUpAvailable = true;
	}
}

public void OnRoundIsLive()
{
	if (!g_hCvarOnLeave.BoolValue) {
		RequestItems();
	}
}

void RoundStart(Event hEvent, const char[] sEventName, bool bDontBroadcast)
{
	StopGrantTimer();
	g_bRoundActive = true;
	g_bItemsGivenThisRound = false;
	g_bLeftStartArea = false;
	g_bGrantRequested = false;
	g_bTargetsCaptured = false;
	g_fRoundStarted = GetGameTime();
	g_fGrantAfter = g_fRoundStarted + 1.25;
	g_iRoundFlags = 0;
	g_iAttempts = 0;
	g_iGrantedItems = 0;
	g_iFailedItems = 0;
	for (int i = 1; i <= MaxClients; i++) {
		g_iTargetSerial[i] = 0;
		g_iGrantedFlags[i] = 0;
		g_iSeenStartSerial[i] = 0;
	}
	g_hGrantTimer = CreateTimer(0.25, Timer_GrantItems, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void RoundEnd(Event hEvent, const char[] sEventName, bool bDontBroadcast)
{
	g_bRoundActive = false;
	StopGrantTimer();
}

public void OnMapEnd()
{
	g_bRoundActive = false;
	StopGrantTimer();
}

void StopGrantTimer()
{
	delete g_hGrantTimer;
	g_hGrantTimer = null;
}

bool IsReadyUpEnabled()
{
	if (!g_bReadyUpAvailable) {
		return false;
	}

	ConVar hReadyEnabled = FindConVar("l4d_ready_enabled");
	return hReadyEnabled == null || hReadyEnabled.BoolValue;
}

void PlayerLeftStartArea(Event hEvent, const char[] sEventName, bool bDontBroadcast)
{
	if (IsPreparing()) {
		return;
	}
	g_bLeftStartArea = true;
	if (g_hCvarOnLeave.BoolValue || !IsReadyUpEnabled()) {
		RequestItems();
	}
}

bool IsPreparing()
{
	return g_bReadyUpAvailable
		&& GetFeatureStatus(FeatureType_Native, "IsInReady") == FeatureStatus_Available
		&& IsInReady();
}

void RequestItems()
{
	if (!g_bRoundActive || g_bItemsGivenThisRound || g_bGrantRequested) {
		return;
	}
	g_bGrantRequested = true;
	// WI runs at 0.3s; ItemTracking and saferoom cleanup run at 1.0s.
	float fAfterEvent = GetGameTime() + 0.1;
	if (fAfterEvent > g_fGrantAfter) {
		g_fGrantAfter = fAfterEvent;
	}
}

Action Timer_GrantItems(Handle hTimer)
{
	if (!g_bRoundActive || g_bItemsGivenThisRound) {
		g_hGrantTimer = null;
		return Plugin_Stop;
	}

	// The global "has left" flag is also set by versus auto-opening a door.
	// Observe a real inside -> outside transition instead; events remain the fallback.
	if (g_hCvarOnLeave.BoolValue
		&& GetFeatureStatus(FeatureType_Native, "L4D_IsPositionInFirstCheckpoint") == FeatureStatus_Available) {
		float vOrigin[3];
		for (int i = 1; i <= MaxClients; i++) {
			if (!IsClientInGame(i) || GetClientTeam(i) != L4D2Team_Survivor || !IsPlayerAlive(i)) {
				continue;
			}
			GetClientAbsOrigin(i, vOrigin);
			int iSerial = GetClientSerial(i);
			if (L4D_IsPositionInFirstCheckpoint(vOrigin)) {
				g_iSeenStartSerial[i] = iSerial;
			} else if (!IsPreparing() && g_iSeenStartSerial[i] == iSerial) {
				g_bLeftStartArea = true;
				RequestItems();
			}
		}
	}
	if (!g_bGrantRequested || IsPreparing() || GetGameTime() < g_fGrantAfter) {
		return Plugin_Continue;
	}
	// A zero default before mode settings execute must not consume the round.
	if (!g_bTargetsCaptured && g_hCvarItemType.IntValue < 1) {
		return Plugin_Continue;
	}
	if (!g_bTargetsCaptured) {
		g_iRoundFlags = g_hCvarItemType.IntValue;
		int iTargets;
		for (int i = 1; i <= MaxClients; i++) {
			if (IsClientInGame(i) && GetClientTeam(i) == L4D2Team_Survivor && IsPlayerAlive(i)) {
				g_iTargetSerial[i] = GetClientSerial(i);
				iTargets++;
			}
		}
		if (!iTargets) {
			return Plugin_Continue;
		}
		g_bTargetsCaptured = true;
	}
	g_iFailedItems = 0;
	DetermineItems();
	g_iAttempts++;
	if (g_iFailedItems > 0 && g_iAttempts < 5) {
		return Plugin_Continue;
	}
	g_bItemsGivenThisRound = true;
	g_hGrantTimer = null;
	if (g_iFailedItems > 0) {
		LogError("[StartingItems] %d item(s) could not be equipped after 5 attempts; use sm_startitemsstatus", g_iFailedItems);
	}
	return Plugin_Stop;
}

void DetermineItems()
{
	int iItemFlags = g_iRoundFlags;

	if (iItemFlags < 1) {
		return;
	}

	StringMap hItemsStringMap = new StringMap();

	if (iItemFlags & HEALTH_FIRST_AID_KIT) {
		hItemsStringMap.SetValue("weapon_first_aid_kit", L4D2WeaponSlot_HeavyHealthItem);
	} else if (iItemFlags & HEALTH_DEFIBRILLATOR) {
		hItemsStringMap.SetValue("weapon_defibrillator", L4D2WeaponSlot_HeavyHealthItem);
	}

	if (iItemFlags & HEALTH_PAIN_PILLS) {
		hItemsStringMap.SetValue("weapon_pain_pills", L4D2WeaponSlot_LightHealthItem);
	} else if (iItemFlags & HEALTH_ADRENALINE) {
		hItemsStringMap.SetValue("weapon_adrenaline", L4D2WeaponSlot_LightHealthItem);
	}

	if (iItemFlags & THROWABLE_PIPE_BOMB) {
		hItemsStringMap.SetValue("weapon_pipe_bomb", L4D2WeaponSlot_Throwable);
	} else if (iItemFlags & THROWABLE_MOLOTOV) {
		hItemsStringMap.SetValue("weapon_molotov", L4D2WeaponSlot_Throwable);
	} else if (iItemFlags & THROWABLE_VOMITJAR) {
		hItemsStringMap.SetValue("weapon_vomitjar", L4D2WeaponSlot_Throwable);
	}

	GiveStartingItems(hItemsStringMap);

	delete hItemsStringMap;
	hItemsStringMap = null;
}

void GiveStartingItems(StringMap &hItemsStringMap)
{
	if (hItemsStringMap.Size < 1) {
		return;
	}

	char sEntName[ENTITY_NAME_MAX_SIZE];
	StringMapSnapshot hItemsSnapshot = hItemsStringMap.Snapshot();
	int iSlotIndex, iSize = hItemsSnapshot.Length;

	for (int i = 1; i <= MaxClients; i++) {
		if (g_iTargetSerial[i] && IsClientInGame(i) && GetClientSerial(i) == g_iTargetSerial[i]
			&& GetClientTeam(i) == L4D2Team_Survivor && IsPlayerAlive(i)) {
			for (int j = 0; j < iSize; j++) {
				hItemsSnapshot.GetKey(j, sEntName, sizeof(sEntName));
				hItemsStringMap.GetValue(sEntName, iSlotIndex);

				int iSlotFlag = 1 << iSlotIndex;
				if (g_iGrantedFlags[i] & iSlotFlag) {
					continue;
				}
				int iExisting = GetPlayerWeaponSlot(i, iSlotIndex);
				if (iExisting != -1) {
					// The explicit departure policy equips the requested kit and pills.
					// Existing matching items stay; defibs/adrenaline use the same slots.
					char sExisting[ENTITY_NAME_MAX_SIZE];
					GetEntityClassname(iExisting, sExisting, sizeof(sExisting));
					if (g_hCvarOnLeave.BoolValue
						&& (StrEqual(sEntName, "weapon_first_aid_kit") || StrEqual(sEntName, "weapon_pain_pills"))
						&& !StrEqual(sExisting, sEntName)) {
						if (RemovePlayerItem(i, iExisting)) {
							RemoveEntity(iExisting);
						} else {
							g_iFailedItems++;
							continue;
						}
					} else {
						g_iGrantedFlags[i] |= iSlotFlag;
						continue;
					}
				}
				GivePlayerWeaponByName(i, sEntName);
				int iGiven = GetPlayerWeaponSlot(i, iSlotIndex);
				if (iGiven != -1) {
					g_iGrantedFlags[i] |= iSlotFlag;
					g_iGrantedItems++;
				} else {
					g_iFailedItems++;
				}
			}
		}
	}

	delete hItemsSnapshot;
	hItemsSnapshot = null;
}

Action Cmd_Status(int iClient, int iArgs)
{
	char sFile[PLATFORM_MAX_PATH];
	GetPluginFilename(null, sFile, sizeof(sFile));
	ReplyToCommand(iClient, "[StartingItems] v2.3.1 | file=%s | flags=%d | on_leave=%d", sFile, g_hCvarItemType.IntValue, g_hCvarOnLeave.IntValue);
	ReplyToCommand(iClient, "[StartingItems] active=%d | left=%d | requested=%d | done=%d | attempts=%d | equipped=%d | failed=%d", g_bRoundActive, g_bLeftStartArea, g_bGrantRequested, g_bItemsGivenThisRound, g_iAttempts, g_iGrantedItems, g_iFailedItems);
	char sVars[][] = {"confogl_replace_startkits", "confogl_replace_finalekits", "confogl_itemtracking_playeritems", "l4d_ready_enabled"};
	for (int i = 0; i < sizeof(sVars); i++) {
		ConVar hVar = FindConVar(sVars[i]);
		if (hVar != null) {
			ReplyToCommand(iClient, "[StartingItems] %s=%d", sVars[i], hVar.IntValue);
		} else {
			ReplyToCommand(iClient, "[StartingItems] %s=unavailable", sVars[i]);
		}
	}
	return Plugin_Handled;
}

void GivePlayerWeaponByName(int iClient, const char[] sWeaponName)
{
#if (SOURCEMOD_V_MINOR >= 12 || (SOURCEMOD_V_MINOR == 11 && SOURCEMOD_V_REV >= 6754))
	GivePlayerItem(iClient, sWeaponName); // Was fixed in v1.11.6754 (https://github.com/alliedmodders/sourcemod/commit/59840685a49a4e85eeb0d7f6271e861)
#else
	int iEntity = CreateEntityByName(sWeaponName);
	if (iEntity == -1) {
		return;
	}

	/*float fClientOrigin[3];
	GetClientAbsOrigin(client, fClientOrigin);
	TeleportEntity(iEntity, fClientOrigin, NULL_VECTOR, NULL_VECTOR);*/
	DispatchSpawn(iEntity);
	EquipPlayerWeapon(iClient, iEntity);
#endif
}

#if DEBUG
Action Cmd_GiveStartingItems(int iClient, int iArgs)
{
	DetermineItems();
	PrintToChat(iClient, "DetermineItems()");

	return Plugin_Handled;
}
#endif
