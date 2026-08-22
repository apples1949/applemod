#pragma semicolon 1

#include <sourcemod>
#include <sdkhooks>
#include <left4dhooks>
#include <sdktools>
#include <l4d2lib>
#include <l4d2util_stocks>

#define PLUGIN_TAG "" // \x04[Applemod Bonus]

#define SM2_DEBUG 0

/**
	基于 'l4d2_hybrid_scoremod_zone' (Visor, Sir) 的 applemod 定制版：

	规则1：使用医疗包(打包) → heal_begin 快照打包前 HB/DB 为记录分(收紧式, min 历次)，
	        heal_success 生效；此后 有效分 = min(记录分, 实时分)，HB/DB 独立，每半场重置。
	规则2：药分改为药品倍率制：肾上腺素 x1、药丸 x1.5、医疗包/除颤器 x2（取最高档不叠加），
	        死亡或未携带药品不计；每名玩家药分 = 向下取整(iPillWorth x 倍率)。
	规则3：投掷物额外加成独立生效（不看药品）：雷 +1/10 基础药分、胆汁 +1/5 基础药分，可叠加。
**/

ConVar hCvarBonusPerSurvivorMultiplier;
ConVar hCvarPermanentHealthProportion;
ConVar hCvarPillsHpFactor;
ConVar hCvarPillsMaxBonus;

ConVar hCvarValveSurvivalBonus;
ConVar hCvarValveTieBreaker;

float fMapBonus;
float fMapHealthBonus;
float fMapDamageBonus;
float fMapTempHealthBonus;
float fPermHpWorth;
float fTempHpWorth;
float fSurvivorBonus[2];

int iMapDistance;
int iTeamSize;
int iPillWorth;
int iMaxPillScore;
int iLostTempHealth[2];
int iTempHealth[MAXPLAYERS + 1];
int iSiDamage[2];

// 规则1 状态：每半场医疗包封顶记录（-1.0 = 未锁定）
float fRecordHealthBonus[2];
float fRecordDamageBonus[2];
float fPendingHB[MAXPLAYERS + 1];
float fPendingDB[MAXPLAYERS + 1];
bool bPendingHeal[MAXPLAYERS + 1];

char sSurvivorState[2][32];

bool bLateLoad;
bool bRoundOver;
bool bTiebreakerEligibility[2];

public Plugin myinfo =
{
	name = "L4D2 Applemod Scoremod",
	author = "apples1949",
	description = "Applemod 定制奖励分（医疗包封顶/药品倍率药分/投掷物加成）",
	version = "1.0.0",
	url = ""
};

public APLRes AskPluginLoad2(Handle plugin, bool late, char[] error, int err_max)
{
	CreateNative("SMPlus_GetHealthBonus", Native_GetHealthBonus);
	CreateNative("SMPlus_GetDamageBonus", Native_GetDamageBonus);
	CreateNative("SMPlus_GetPillsBonus", Native_GetPillsBonus);
	CreateNative("SMPlus_GetMaxHealthBonus", Native_GetMaxHealthBonus);
	CreateNative("SMPlus_GetMaxDamageBonus", Native_GetMaxDamageBonus);
	CreateNative("SMPlus_GetMaxPillsBonus", Native_GetMaxPillsBonus);
	RegPluginLibrary("l4d2_hybrid_scoremod");
	bLateLoad = late;
	return APLRes_Success;
}

public void OnPluginStart()
{
	hCvarBonusPerSurvivorMultiplier = CreateConVar("sm2_bonus_per_survivor_multiplier", "0.5", "Total Survivor Bonus = this * Number of Survivors * Map Distance");
	hCvarPermanentHealthProportion = CreateConVar("sm2_permament_health_proportion", "0.75", "Permanent Health Bonus = this * Map Bonus; rest goes for Temporary Health Bonus");
	hCvarPillsHpFactor = CreateConVar("sm2_pills_hp_factor", "6.0", "Unused pills HP worth = map bonus HP value / this");
	hCvarPillsMaxBonus = CreateConVar("sm2_pills_max_bonus", "30", "Unused pills cannot be worth more than this");

	hCvarValveSurvivalBonus = FindConVar("vs_survival_bonus");
	hCvarValveTieBreaker = FindConVar("vs_tiebreak_bonus");

	HookConVarChange(hCvarBonusPerSurvivorMultiplier, CvarChanged);
	HookConVarChange(hCvarPermanentHealthProportion, CvarChanged);

	HookEvent("round_start", RoundStartEvent, EventHookMode_PostNoCopy);
	HookEvent("heal_begin", OnHealBegin, EventHookMode_Post);
	HookEvent("heal_success", OnHealSuccess, EventHookMode_Post);
	HookEvent("heal_interrupted", OnHealInterrupted, EventHookMode_Post);
	HookEvent("player_ledge_grab", OnPlayerLedgeGrab);
	HookEvent("player_incapacitated", OnPlayerIncapped);
	HookEvent("player_hurt", OnPlayerHurt);
	HookEvent("revive_success", OnPlayerRevived, EventHookMode_Post);
	HookEvent("player_death", OnPlayerDeath);

	RegConsoleCmd("sm_health", CmdBonus);
	RegConsoleCmd("sm_damage", CmdBonus);
	RegConsoleCmd("sm_bonus", CmdBonus);
	RegConsoleCmd("sm_mapinfo", CmdMapInfo);

	if (bLateLoad)
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			if (!IsClientInGame(i))
				continue;

			OnClientPutInServer(i);
		}
	}
}

public void OnPluginEnd()
{
	ResetConVar(hCvarValveSurvivalBonus);
	ResetConVar(hCvarValveTieBreaker);
}

public void OnConfigsExecuted()
{
	iTeamSize = GetConVarInt(FindConVar("survivor_limit"));
	SetConVarInt(hCvarValveTieBreaker, 0);

	iMapDistance = L4D2_GetMapValueInt("max_distance", L4D_GetVersusMaxCompletionScore());
	L4D_SetVersusMaxCompletionScore(iMapDistance);

	float fPermHealthProportion = GetConVarFloat(hCvarPermanentHealthProportion);
	float fTempHealthProportion = 1.0 - fPermHealthProportion;
	fMapBonus = iMapDistance * (GetConVarFloat(hCvarBonusPerSurvivorMultiplier) * iTeamSize);
	fMapHealthBonus = fMapBonus * fPermHealthProportion;
	fMapDamageBonus = fMapBonus * fTempHealthProportion;
	fMapTempHealthBonus = iTeamSize * 100/* HP */ / fPermHealthProportion * fTempHealthProportion;
	fPermHpWorth = fMapBonus / iTeamSize / 100 * fPermHealthProportion;
	fTempHpWorth = fMapBonus * fTempHealthProportion / fMapTempHealthBonus; // this should be almost equal to the perm hp worth, but for accuracy we'll keep it separate
	iPillWorth = L4D2Util_Clamp(RoundToNearest(50 * (fPermHpWorth / GetConVarFloat(hCvarPillsHpFactor)) / 5) * 5, 5, GetConVarInt(hCvarPillsMaxBonus)); // make it pretty
	// 规则2/3：每名玩家药分满分 = 医疗包2倍 + 雷1/10（显示上限按携带雷计；携带胆汁时百分比可超过100%）
	iMaxPillScore = 2 * iPillWorth + RoundToFloor(float(iPillWorth) / 10.0);
#if SM2_DEBUG
	PrintToChatAll("\x01Map health bonus: \x05%.1f\x01, temp health bonus: \x05%.1f\x01, perm hp worth: \x03%.1f\x01, temp hp worth: \x03%.1f\x01, pill worth: \x03%i\x01", fMapBonus, fMapTempHealthBonus, fPermHpWorth, fTempHpWorth, iPillWorth);
#endif
}

public void OnMapStart()
{
	OnConfigsExecuted();

	iLostTempHealth[0] = 0;
	iLostTempHealth[1] = 0;
	iSiDamage[0] = 0;
	iSiDamage[1] = 0;
	bTiebreakerEligibility[0] = false;
	bTiebreakerEligibility[1] = false;
	ResetHealRecords();
}

void ResetHealRecords()
{
	fRecordHealthBonus[0] = -1.0;
	fRecordHealthBonus[1] = -1.0;
	fRecordDamageBonus[0] = -1.0;
	fRecordDamageBonus[1] = -1.0;
	for (int i = 0; i <= MAXPLAYERS; i++)
	{
		bPendingHeal[i] = false;
	}
}

void CvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	OnConfigsExecuted();
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
	SDKHook(client, SDKHook_OnTakeDamagePost, OnTakeDamagePost);
}

public void OnClientDisconnect(int client)
{
	SDKUnhook(client, SDKHook_OnTakeDamage, OnTakeDamage);
	SDKUnhook(client, SDKHook_OnTakeDamagePost, OnTakeDamagePost);
	bPendingHeal[client] = false;
}

void RoundStartEvent(Event hEvent, const char[] sEventName, bool bDontBroadcast)
{
	for (int i = 0; i <= MAXPLAYERS; i++)
	{
		iTempHealth[i] = 0;
	}
	bRoundOver = false;
	ResetHealRecords();
}

/**************/
/** 规则1：医疗包封顶 **/
/**************/

// 打包开始：快照打包前(治疗生效前)的实时 HB/DB
void OnHealBegin(Event hEvent, const char[] sEventName, bool bDontBroadcast)
{
	int subject = GetClientOfUserId(hEvent.GetInt("subject"));
	if (!IsSurvivor(subject))
		return;

	fPendingHB[subject] = GetLiveHealthBonus();
	fPendingDB[subject] = GetLiveDamageBonus();
	bPendingHeal[subject] = true;
}

// 打包成功：收紧式提交记录分（只降不升）
void OnHealSuccess(Event hEvent, const char[] sEventName, bool bDontBroadcast)
{
	int subject = GetClientOfUserId(hEvent.GetInt("subject"));
	if (!IsSurvivor(subject) || !bPendingHeal[subject])
		return;

	int team = InSecondHalfOfRound();
	if (fPendingHB[subject] >= 0.0 && (fRecordHealthBonus[team] < 0.0 || fPendingHB[subject] < fRecordHealthBonus[team]))
		fRecordHealthBonus[team] = fPendingHB[subject];
	if (fPendingDB[subject] >= 0.0 && (fRecordDamageBonus[team] < 0.0 || fPendingDB[subject] < fRecordDamageBonus[team]))
		fRecordDamageBonus[team] = fPendingDB[subject];
	bPendingHeal[subject] = false;

#if SM2_DEBUG
	PrintToChatAll("\x01[\x04Medkit Record\x01] team \x04%i\x01: HB record \x05%.1f\x01, DB record \x05%.1f\x01", team, fRecordHealthBonus[team], fRecordDamageBonus[team]);
#endif
}

// 打包被打断：作废本次快照
void OnHealInterrupted(Event hEvent, const char[] sEventName, bool bDontBroadcast)
{
	int subject = GetClientOfUserId(hEvent.GetInt("subject"));
	if (subject > 0 && subject <= MaxClients)
		bPendingHeal[subject] = false;
}

int Native_GetHealthBonus(Handle plugin, int numParams)
{
	return RoundToFloor(GetSurvivorHealthBonus());
}

int Native_GetMaxHealthBonus(Handle plugin, int numParams)
{
	return RoundToFloor(fMapHealthBonus);
}

int Native_GetDamageBonus(Handle plugin, int numParams)
{
	return RoundToFloor(GetSurvivorDamageBonus());
}

int Native_GetMaxDamageBonus(Handle plugin, int numParams)
{
	return RoundToFloor(fMapDamageBonus);
}

int Native_GetPillsBonus(Handle plugin, int numParams)
{
	return RoundToFloor(GetSurvivorPillBonus());
}

int Native_GetMaxPillsBonus(Handle plugin, int numParams)
{
	return iMaxPillScore * iTeamSize;
}

Action CmdBonus(int client, int args)
{
	if (bRoundOver || !client)
		return Plugin_Handled;

	char sCmdType[64];
	GetCmdArg(1, sCmdType, sizeof(sCmdType));

	float fHealthBonus = GetSurvivorHealthBonus();
	float fDamageBonus = GetSurvivorDamageBonus();
	float fPillsBonus = GetSurvivorPillBonus();
	float fMaxPillsBonus = float(iMaxPillScore * iTeamSize);

	if (StrEqual(sCmdType, "full"))
	{
		if (InSecondHalfOfRound())
		{
			PrintToChat(client, "%s\x01R\x04#1\x01 Bonus: \x05%d\x01/\x05%d\x01 <\x03%.1f%%\x01> [%s]", PLUGIN_TAG, RoundToFloor(fSurvivorBonus[0]), RoundToFloor(fMapBonus + fMaxPillsBonus), CalculateBonusPercent(fSurvivorBonus[0]), sSurvivorState[0]);
		}
		PrintToChat(client, "%s\x01R\x04#%i\x01 Bonus: \x05%d\x01 <\x03%.1f%%\x01> [HB: \x05%d\x01 <\x03%.1f%%\x01> | DB: \x05%d\x01 <\x03%.1f%%\x01> | Pills: \x05%d\x01 <\x03%.1f%%\x01>]", PLUGIN_TAG, InSecondHalfOfRound() + 1, RoundToFloor(fHealthBonus + fDamageBonus + fPillsBonus), CalculateBonusPercent(fHealthBonus + fDamageBonus + fPillsBonus, fMapHealthBonus + fMapDamageBonus + fMaxPillsBonus), RoundToFloor(fHealthBonus), CalculateBonusPercent(fHealthBonus, fMapHealthBonus), RoundToFloor(fDamageBonus), CalculateBonusPercent(fDamageBonus, fMapDamageBonus), RoundToFloor(fPillsBonus), CalculateBonusPercent(fPillsBonus, fMaxPillsBonus));
	}
	else if (StrEqual(sCmdType, "lite"))
	{
		PrintToChat(client, "%s\x01R\x04#%i\x01 Bonus: \x05%d\x01 <\x03%.1f%%\x01>", PLUGIN_TAG, InSecondHalfOfRound() + 1, RoundToFloor(fHealthBonus + fDamageBonus + fPillsBonus), CalculateBonusPercent(fHealthBonus + fDamageBonus + fPillsBonus, fMapHealthBonus + fMapDamageBonus + fMaxPillsBonus));
	}
	else
	{
		if (InSecondHalfOfRound())
		{
			PrintToChat(client, "%s\x01R\x04#1\x01 Bonus: \x05%d\x01 <\x03%.1f%%\x01>", PLUGIN_TAG, RoundToFloor(fSurvivorBonus[0]), CalculateBonusPercent(fSurvivorBonus[0]));
		}
		PrintToChat(client, "%s\x01R\x04#%i\x01 Bonus: \x05%d\x01 <\x03%.1f%%\x01> [HB: \x03%.0f%%\x01 | DB: \x03%.0f%%\x01 | Pills: \x03%.0f%%\x01]", PLUGIN_TAG, InSecondHalfOfRound() + 1, RoundToFloor(fHealthBonus + fDamageBonus + fPillsBonus), CalculateBonusPercent(fHealthBonus + fDamageBonus + fPillsBonus, fMapHealthBonus + fMapDamageBonus + fMaxPillsBonus), CalculateBonusPercent(fHealthBonus, fMapHealthBonus), CalculateBonusPercent(fDamageBonus, fMapDamageBonus), CalculateBonusPercent(fPillsBonus, fMaxPillsBonus));
	}
	return Plugin_Handled;
}

Action CmdMapInfo(int client, int args)
{
	float fMaxPillsBonus = float(iMaxPillScore * iTeamSize);
	float fTotalBonus = fMapBonus + fMaxPillsBonus;
	PrintToChat(client, "\x01[\x04Applemod Bonus\x01 :: \x03%iv%i\x01] Map Info", iTeamSize, iTeamSize);
	PrintToChat(client, "\x01Distance: \x05%d\x01", iMapDistance);
	PrintToChat(client, "\x01Total Bonus: \x05%d\x01 <\x03100.0%%\x01>", RoundToFloor(fTotalBonus));
	PrintToChat(client, "\x01Health Bonus: \x05%d\x01 <\x03%.1f%%\x01>", RoundToFloor(fMapHealthBonus), CalculateBonusPercent(fMapHealthBonus, fTotalBonus));
	PrintToChat(client, "\x01Damage Bonus: \x05%d\x01 <\x03%.1f%%\x01>", RoundToFloor(fMapDamageBonus), CalculateBonusPercent(fMapDamageBonus, fTotalBonus));
	PrintToChat(client, "\x01Pills Bonus: \x05%d\x01(base) \x05%d\x01(max/survivor, team \x05%d\x01) <\x03%.1f%%\x01>", iPillWorth, iMaxPillScore, RoundToFloor(fMaxPillsBonus), CalculateBonusPercent(fMaxPillsBonus, fTotalBonus));
	PrintToChat(client, "\x01Tiebreaker: \x05%d\x01", iPillWorth);
	return Plugin_Handled;
}

Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
	if (!IsSurvivor(victim) || IsPlayerIncap(victim)) return Plugin_Continue;

#if SM2_DEBUG
	if (GetSurvivorTemporaryHealth(victim) > 0) PrintToChatAll("\x04%N\x01 has \x05%d\x01 temp HP now(damage: \x03%.1f\x01)", victim, GetSurvivorTemporaryHealth(victim), damage);
#endif
	iTempHealth[victim] = GetSurvivorTemporaryHealth(victim);

	// Small failsafe/workaround for stuff that inflicts more than 100 HP damage (like tank hittables); we don't want to reward that more than it's worth
	if (!IsAnyInfected(attacker)) iSiDamage[InSecondHalfOfRound()] += (damage <= 100.0 ? RoundFloat(damage) : 100);

	return Plugin_Continue;
}

void OnPlayerLedgeGrab(Event hEvent, const char[] sEventName, bool bDontBroadcast)
{
	int client = GetClientOfUserId(hEvent.GetInt("userid"));
	iLostTempHealth[InSecondHalfOfRound()] += L4D2Direct_GetPreIncapHealthBuffer(client);
}

void OnPlayerDeath(Event hEvent, const char[] sEventName, bool bDontBroadcast)
{
	int victim = GetClientOfUserId(hEvent.GetInt("userid"));
	if (IsSurvivor(victim) && !bRoundOver)
	{
		int incaps = GetEntProp(victim, Prop_Send, "m_currentReviveCount");
		int standardPenalty = RoundToFloor((fMapDamageBonus / 100.0) * 5.0 / fTempHpWorth);
		int penalty = 0;

		for (int loops = 2 - incaps; loops > 0; loops--)
		{
			penalty += standardPenalty + 30;
		}

		iLostTempHealth[InSecondHalfOfRound()] += penalty;
		bPendingHeal[victim] = false; // 治疗动画期间死亡不触发 heal_interrupted，作废残留快照

		#if SM2_DEBUG
			PrintToChatAll("\x04[\x01Valid Death\x04] \x03%N \x01had \x03%i \x01incaps and the total penalty is now \x03%i", victim, incaps, penalty);
		#endif
	}
}

void OnPlayerIncapped(Event hEvent, const char[] sEventName, bool bDontBroadcast)
{
	int client = GetClientOfUserId(hEvent.GetInt("userid"));
	if (IsSurvivor(client))
	{
		iLostTempHealth[InSecondHalfOfRound()] += RoundToFloor((fMapDamageBonus / 100.0) * 5.0 / fTempHpWorth);
		bPendingHeal[client] = false; // 治疗中倒地同样作废本次打包快照
	}
}

void OnPlayerRevived(Event hEvent, const char[] sEventName, bool bDontBroadcast)
{
	bool bLedge = hEvent.GetBool("ledge_hang");
	if (!bLedge)
		return;

	int client = GetClientOfUserId(hEvent.GetInt("subject"));
	if (!IsSurvivor(client))
		return;

	RequestFrame(Revival, client);
}

void Revival(int client)
{
	iLostTempHealth[InSecondHalfOfRound()] -= GetSurvivorTemporaryHealth(client);
}

Action OnPlayerHurt(Event hEvent, const char[] sEventName, bool bDontBroadcast)
{
	int victim = GetClientOfUserId(hEvent.GetInt("userid"));
	int attacker = GetClientOfUserId(hEvent.GetInt("attacker"));
	int damage = hEvent.GetInt("dmg_health");
	int damagetype = hEvent.GetInt("type");

	int fFakeDamage = damage;

	// Victim has to be a Survivor.
	// Attacker has to be a Survivor.
	// Player can't be Incapped.
	// Damage has to be from manipulated Shotgun FF. (Plasma)
	// Damage has to be higher than the Survivor's permanent health.
	if (!IsSurvivor(victim) || !IsSurvivor(attacker) || IsPlayerIncap(victim) || damagetype != DMG_PLASMA || fFakeDamage < GetSurvivorPermanentHealth(victim)) return Plugin_Continue;

	iTempHealth[victim] = GetSurvivorTemporaryHealth(victim);
	if (fFakeDamage > iTempHealth[victim]) fFakeDamage = iTempHealth[victim];

	iLostTempHealth[InSecondHalfOfRound()] += fFakeDamage;
	iTempHealth[victim] = GetSurvivorTemporaryHealth(victim) - fFakeDamage;

	return Plugin_Continue;
}

void OnTakeDamagePost(int victim, int attacker, int inflictor, float damage, int damagetype)
{
	if (!IsSurvivor(victim)) return;

#if SM2_DEBUG
	PrintToChatAll("\x03%N\x01\x05 lost %i\x01 temp HP after being attacked(arg damage: \x03%.1f\x01)", victim, iTempHealth[victim] - (IsPlayerAlive(victim) ? GetSurvivorTemporaryHealth(victim) : 0), damage);
#endif
	if (!IsPlayerAlive(victim) || (IsPlayerIncap(victim) && !IsPlayerLedged(victim)))
	{
		iLostTempHealth[InSecondHalfOfRound()] += iTempHealth[victim];
	}
	else if (!IsPlayerLedged(victim))
	{
		iLostTempHealth[InSecondHalfOfRound()] += iTempHealth[victim] ? (iTempHealth[victim] - GetSurvivorTemporaryHealth(victim)) : 0;
	}
	iTempHealth[victim] = IsPlayerIncap(victim) ? 0 : GetSurvivorTemporaryHealth(victim);
}

// Compatibility with Alternate Damage Mechanics plugin
// This plugin(i.e. Scoremod2) will work ideally fine with or without the aforementioned plugin
public void L4D2_ADM_OnTemporaryHealthSubtracted(int client, int oldHealth, int newHealth)
{
	int healthLost = oldHealth - newHealth;
	iTempHealth[client] = newHealth;
	iLostTempHealth[InSecondHalfOfRound()] += healthLost;
	iSiDamage[InSecondHalfOfRound()] += healthLost; // this forward doesn't fire for ledged/incapped survivors so we're good
}

public Action L4D2_OnEndVersusModeRound(bool countSurvivors)
{
#if SM2_DEBUG
	PrintToChatAll("CDirector::OnEndVersusModeRound() called. InSecondHalfOfRound(): %d, countSurvivors: %d", InSecondHalfOfRound(), countSurvivors);
#endif
	if (bRoundOver)
		return Plugin_Continue;

	int team = InSecondHalfOfRound();
	int iSurvivalMultiplier = countSurvivors ? GetAliveSurvivorCount(false) : 0;
	fSurvivorBonus[team] = GetSurvivorHealthBonus() + GetSurvivorDamageBonus() + GetSurvivorPillBonus();
	fSurvivorBonus[team] = float(RoundToFloor(fSurvivorBonus[team] / float(iTeamSize)) * iTeamSize); // make it a perfect divisor of team size value
	if (iSurvivalMultiplier > 0 && RoundToFloor(fSurvivorBonus[team] / iSurvivalMultiplier) >= iTeamSize) // anything lower than team size will result in 0 after division
	{
		SetConVarInt(hCvarValveSurvivalBonus, RoundToFloor(fSurvivorBonus[team] / iSurvivalMultiplier));
		fSurvivorBonus[team] = float(GetConVarInt(hCvarValveSurvivalBonus) * iSurvivalMultiplier);    // workaround for the discrepancy caused by RoundToFloor()
		FormatEx(sSurvivorState[team], 32, "%s%i\x01/\x05%i\x01", (iSurvivalMultiplier == iTeamSize ? "\x05" : "\x04"), iSurvivalMultiplier, iTeamSize);
	#if SM2_DEBUG
		PrintToChatAll("\x01Survival bonus cvar updated. Value: \x05%i\x01 [multiplier: \x05%i\x01]", GetConVarInt(hCvarValveSurvivalBonus), iSurvivalMultiplier);
	#endif
	}
	else
	{
		fSurvivorBonus[team] = 0.0;
		SetConVarInt(hCvarValveSurvivalBonus, 0);
		FormatEx(sSurvivorState[team], 32, "\x04%s\x01", (iSurvivalMultiplier == 0 ? "wiped out" : "bonus depleted"));
		bTiebreakerEligibility[team] = (iSurvivalMultiplier == iTeamSize);
	}

	// Check if it's the end of the second round and a tiebreaker case
	if (team > 0 && bTiebreakerEligibility[0] && bTiebreakerEligibility[1])
	{
		GameRules_SetProp("m_iChapterDamage", iSiDamage[0], _, 0, true);
		GameRules_SetProp("m_iChapterDamage", iSiDamage[1], _, 1, true);

		// That would be pretty funny otherwise
		if (iSiDamage[0] != iSiDamage[1])
		{
			SetConVarInt(hCvarValveTieBreaker, iPillWorth);
		}
	}

	// Scores print
	CreateTimer(3.0, PrintRoundEndStats, _, TIMER_FLAG_NO_MAPCHANGE);

	bRoundOver = true;
	return Plugin_Continue;
}

Action PrintRoundEndStats(Handle timer)
{
	for (int i = 0; i <= InSecondHalfOfRound(); i++)
	{
		PrintToChatAll("%s\x01Round \x04%i\x01 Bonus: \x05%d\x01/\x05%d\x01 <\x03%.1f%%\x01> [%s]", PLUGIN_TAG, (i + 1), RoundToFloor(fSurvivorBonus[i]), RoundToFloor(fMapBonus + float(iMaxPillScore * iTeamSize)), CalculateBonusPercent(fSurvivorBonus[i]), sSurvivorState[i]);
	}

	if (InSecondHalfOfRound() && bTiebreakerEligibility[0] && bTiebreakerEligibility[1])
	{
		PrintToChatAll("%s\x03TIEBREAKER\x01: Team \x04%#1\x01 - \x05%i\x01, Team \x04%#2\x01 - \x05%i\x01", PLUGIN_TAG, iSiDamage[0], iSiDamage[1]);
		if (iSiDamage[0] == iSiDamage[1])
		{
			PrintToChatAll("%s\x05Teams have performed absolutely equal! Impossible to decide a clear round winner", PLUGIN_TAG);
		}
	}

	return Plugin_Stop;
}

/********************/
/** 实时分（未封顶）**/
/********************/

float GetLiveHealthBonus()
{
	float fHealthBonus;
	int survivorCount;
	int survivalMultiplier;
	for (int i = 1; i <= MaxClients && survivorCount < iTeamSize; i++)
	{
		if (IsSurvivor(i))
		{
			survivorCount++;
			if (IsPlayerAlive(i) && !IsPlayerIncap(i) && !IsPlayerLedged(i))
			{
				survivalMultiplier++;
				fHealthBonus += GetSurvivorPermanentHealth(i) * fPermHpWorth;
			#if SM2_DEBUG
				PrintToChatAll("\x01Adding \x05%N's\x01 perm hp bonus contribution: \x05%d\x01 perm HP -> \x03%.1f\x01 bonus; new total: \x05%.1f\x01", i, GetSurvivorPermanentHealth(i), GetSurvivorPermanentHealth(i) * fPermHpWorth, fHealthBonus);
			#endif
			}
		}
	}
	return (fHealthBonus / iTeamSize * survivalMultiplier);
}

float GetLiveDamageBonus()
{
	int survivalMultiplier = GetAliveSurvivorCount();
	float fDamageBonus = (fMapTempHealthBonus - float(iLostTempHealth[InSecondHalfOfRound()])) * fTempHpWorth / iTeamSize * survivalMultiplier;
#if SM2_DEBUG
	PrintToChatAll("\x01Adding temp hp bonus: \x05%.1f\x01 (eligible survivors: \x05%d\x01)", fDamageBonus, survivalMultiplier);
#endif
	return (fDamageBonus > 0.0 && survivalMultiplier > 0) ? fDamageBonus : 0.0;
}

/********************/
/** 有效分（含医疗包封顶）**/
/********************/

float GetSurvivorHealthBonus()
{
	float fLive = GetLiveHealthBonus();
	int team = InSecondHalfOfRound();
	if (fRecordHealthBonus[team] >= 0.0 && fLive > fRecordHealthBonus[team])
		return fRecordHealthBonus[team];
	return fLive;
}

float GetSurvivorDamageBonus()
{
	float fLive = GetLiveDamageBonus();
	int team = InSecondHalfOfRound();
	if (fRecordDamageBonus[team] >= 0.0 && fLive > fRecordDamageBonus[team])
		return fRecordDamageBonus[team];
	return fLive;
}

/********************/
/** 规则2/3：药分 **/
/********************/

float GetSurvivorPillBonus()
{
	int pillsBonus;
	int survivorCount;
	for (int i = 1; i <= MaxClients && survivorCount < iTeamSize; i++)
	{
		if (IsSurvivor(i))
		{
			survivorCount++;
			if (IsPlayerAlive(i) && !IsPlayerIncap(i) && !IsPlayerLedged(i))
			{
				pillsBonus += GetPlayerPillScore(i);
			#if SM2_DEBUG
				PrintToChatAll("\x01Adding \x05%N's\x01 pills contribution, total bonus: \x05%d\x01 pts", i, pillsBonus);
			#endif
			}
		}
	}
	return float(pillsBonus);
}

// 单名玩家药分 = 向下取整(基础药分 x 药品倍率) + 投掷物加成（独立生效，不看药品）
int GetPlayerPillScore(int client)
{
	int score = RoundToFloor(float(iPillWorth) * GetMedicalMultiplier(client));
	score += GetThrowableBonus(client);
	return score;
}

// 药品倍率：医疗包/除颤器 x2 > 药丸 x1.5 > 肾上腺素 x1 > 无 x0（取最高档，不叠加）
float GetMedicalMultiplier(int client)
{
	int item = GetPlayerWeaponSlot(client, L4D2WeaponSlot_HeavyHealthItem); // 3: 医疗包/除颤器
	if (IsValidEdict(item))
	{
		char buffer[64];
		GetEdictClassname(item, buffer, sizeof(buffer));
		if (StrEqual(buffer, "weapon_first_aid_kit") || StrEqual(buffer, "weapon_defibrillator"))
			return 2.0;
	}

	item = GetPlayerWeaponSlot(client, L4D2WeaponSlot_LightHealthItem); // 4: 药丸/肾上腺素
	if (IsValidEdict(item))
	{
		char buffer[64];
		GetEdictClassname(item, buffer, sizeof(buffer));
		if (StrEqual(buffer, "weapon_pain_pills"))
			return 1.5;
		if (StrEqual(buffer, "weapon_adrenaline"))
			return 1.0;
	}

	return 0.0;
}

// 投掷物加成：雷 +1/10 基础药分、胆汁 +1/5 基础药分（火瓶不计），可叠加
int GetThrowableBonus(int client)
{
	int bonus;
	int item = GetPlayerWeaponSlot(client, L4D2WeaponSlot_Throwable); // 2: 投掷物
	if (IsValidEdict(item))
	{
		char buffer[64];
		GetEdictClassname(item, buffer, sizeof(buffer));
		if (StrEqual(buffer, "weapon_pipe_bomb"))
			bonus += RoundToFloor(float(iPillWorth) / 10.0);
		else if (StrEqual(buffer, "weapon_vomitjar"))
			bonus += RoundToFloor(float(iPillWorth) / 5.0);
	}
	return bonus;
}

float CalculateBonusPercent(float score, float maxbonus = -1.0)
{
	return score / (maxbonus == -1.0 ? (fMapBonus + float(iMaxPillScore * iTeamSize)) : maxbonus) * 100;
}

/************/
/** Stocks **/
/************/

int InSecondHalfOfRound()
{
	return GameRules_GetProp("m_bInSecondHalfOfRound");
}

bool IsSurvivor(int client)
{
	return client > 0 && client <= MaxClients && IsClientInGame(client) && GetClientTeam(client) == 2;
}

bool IsAnyInfected(int entity)
{
	if (entity > 0 && entity <= MaxClients)
	{
		return IsClientInGame(entity) && GetClientTeam(entity) == 3;
	}
	else if (entity > MaxClients)
	{
		char classname[64];
		GetEdictClassname(entity, classname, sizeof(classname));
		if (StrEqual(classname, "infected") || StrEqual(classname, "witch"))
		{
			return true;
		}
	}
	return false;
}

bool IsPlayerIncap(int client)
{
	return view_as<bool>(GetEntProp(client, Prop_Send, "m_isIncapacitated"));
}

bool IsPlayerLedged(int client)
{
	return view_as<bool>(GetEntProp(client, Prop_Send, "m_isHangingFromLedge") | GetEntProp(client, Prop_Send, "m_isFallingFromLedge"));
}

int GetAliveSurvivorCount(bool uprightOnly = true)
{
	int survivorCount, aliveCount, uprightCount;

	for (int i = 1; i <= MaxClients && survivorCount < iTeamSize; i++)
	{
		if (IsSurvivor(i))
		{
			survivorCount++;

			if (IsPlayerAlive(i))
				aliveCount++;

			if (!IsPlayerIncap(i) && !IsPlayerLedged(i))
				uprightCount++;
		}
	}

	return uprightOnly ? uprightCount : aliveCount;
}

int GetSurvivorTemporaryHealth(int client)
{
	int temphp = RoundToCeil(GetEntPropFloat(client, Prop_Send, "m_healthBuffer") - ((GetGameTime() - GetEntPropFloat(client, Prop_Send, "m_healthBufferTime")) * GetConVarFloat(FindConVar("pain_pills_decay_rate")))) - 1;
	return (temphp > 0 ? temphp : 0);
}

int GetSurvivorPermanentHealth(int client)
{
	// Survivors always have minimum 1 permanent hp
	// so that they don't faint in place just like that when all temp hp run out
	// We'll use a workaround for the sake of fair calculations
	// Edit 2: "Incapped HP" are stored in m_iHealth too; we heard you like workarounds, dawg, so we've added a workaround in a workaround
	return GetEntProp(client, Prop_Send, "m_currentReviveCount") > 0 ? 0 : (GetEntProp(client, Prop_Send, "m_iHealth") > 0 ? GetEntProp(client, Prop_Send, "m_iHealth") : 0);
}
