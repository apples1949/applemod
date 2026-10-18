// l4d2_drop_secondary_edi.sp
//
// EDI 版本 —— 基于 optional/l4d2_drop_secondary.smx（作者 Sir, ProjectSky；初版 Jahze & Visor, v1.1）
// 原插件保持不动、也不再加载，所有配置改用本版本（plugins/optional/another/l4d2_drop_secondary_edi.smx）。
//
// 本版修复：
//   原版在玩家死亡时，把死亡前抄下的 m_strMapSetScriptName 直接写进新建的 weapon_melee，
//   完全不校验该近战脚本名是否在本图注册。若名字为空 / 拼错 / 属于别的地图剧本 / 被
//   IsMeleeWeaponAllowedToExist 过滤，这把武器的 m_hMeleeWeaponInfo 会一直是 -1；
//   换图时引擎 PlayerSaveData 构造函数（server_srv.so 0x8ea685）对 NULL 的近战信息做
//   lea [eax+0xc50] -> KeyValues::SetString("restoreSecondaryWeaponName") -> strlen(0xc50)
//   -> SIGSEGV，服务器崩溃。
//
//   本版在 SpawnSecondary() 里增加 IsMeleeScriptRegistered() 校验（对照引擎网络字符串表
//   "MeleeWeapons"，其容量上限为 16），未注册的名字直接放弃生成；同时在抄名字时把空串
//   归一化为 MELEE_NONE，避免下游再出现歧义。

#pragma semicolon 1
#pragma newdecls required

#include <colors>
#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#define SECONDARY_PISTOL         "weapon_pistol"
#define SECONDARY_PISTOL_MAGNUM  "weapon_pistol_magnum"
#define SECONDARY_MELEE          "weapon_melee"

#define MELEE_NONE               "none"
#define MELEE_NAME_MAX           64

char sSecondary[MAXPLAYERS + 1][64];
char sMeleeScript[MAXPLAYERS + 1][64];

ConVar g_hCvarDebug;
ConVar g_hCvarGuard;
bool bDebug;
bool bGuard;

public Plugin myinfo =
{
	name        = "L4D2 Drop Secondary (EDI)",
	author      = "Sir, ProjectSky (Initial Plugin by Jahze & Visor); EDI fix by apples1949",
	version     = "1.2-edi",
	description = "死亡时掉落副武器；近战脚本名必须在本图注册，避免换图时服务器崩溃"
}

public void OnPluginStart()
{
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("player_use", Event_OnPlayerUse, EventHookMode_Post);
	HookEvent("player_death", Event_OnPlayerDeath, EventHookMode_Pre);

	HookEvent("player_bot_replace", Event_OnPlayerReplacedByBot);
	HookEvent("bot_player_replace", Event_OnBotReplacedByPlayer);

	g_hCvarDebug = CreateConVar("l4d2_drop_secondary_debug", "0", "Enable Debugging? (Print out to all chat)", FCVAR_NONE, true, 0.0, true, 1.0);
	g_hCvarGuard = CreateConVar("l4d2_drop_secondary_guard", "1", "1=只掉落本图已注册的近战脚本（防止换图崩溃） 0=旧行为，不校验", FCVAR_NONE, true, 0.0, true, 1.0);

	bDebug = g_hCvarDebug.BoolValue;
	bGuard = g_hCvarGuard.BoolValue;
	g_hCvarDebug.AddChangeHook(DebugChanged);
	g_hCvarGuard.AddChangeHook(GuardChanged);
}

/*****************************************************************************************
*
*           THESE ARE ONLY USED TO RESET A PLAYER'S STORED SECONDARY WEAPON/MELEE SCRIPT
*
*****************************************************************************************/
public void OnClientDisconnect(int client)
{
	sSecondary[client] = SECONDARY_PISTOL;
	sMeleeScript[client] = MELEE_NONE;
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		sSecondary[i] = SECONDARY_PISTOL;
		sMeleeScript[i] = MELEE_NONE;
	}
}

/*****************************************************************************************
*
*                  THESE ARE USED TO MAKE SURE THE CORRECT PLAYER KEEPS
*                          THEIR SECONDARY AND MELEE SCRIPT
*
*****************************************************************************************/
void Event_OnPlayerReplacedByBot(Event event, const char[] name, bool dontBroadcast)
{
	int bot = GetClientOfUserId(event.GetInt("bot"));
	int player = GetClientOfUserId(event.GetInt("player"));

	if (bot <= 0 || bot > MaxClients || player <= 0 || player > MaxClients) return;

	sSecondary[bot] = sSecondary[player];
	sMeleeScript[bot] = sMeleeScript[player];
	sSecondary[player] = SECONDARY_PISTOL;
	sMeleeScript[player] = MELEE_NONE;

	if (bDebug) CPrintToChatAll("{green}[{olive}OnPlayerReplacedByBot{green}] {default}- {blue}BOT {default}replaced {blue}%N {default}({green}Secondary: {olive}%s{default})", player, sSecondary[bot]);
}

void Event_OnBotReplacedByPlayer(Event event, const char[] name, bool dontBroadcast)
{
	int bot = GetClientOfUserId(event.GetInt("bot"));
	int player = GetClientOfUserId(event.GetInt("player"));

	if (bot <= 0 || bot > MaxClients || player <= 0 || player > MaxClients) return;

	sSecondary[player] = sSecondary[bot];
	sMeleeScript[player] = sMeleeScript[bot];
	sSecondary[bot] = SECONDARY_PISTOL;
	sMeleeScript[bot] = MELEE_NONE;

	if (bDebug) CPrintToChatAll("{green}[{olive}OnBotReplacedByPlayer{green}] {default}- {blue}%N {default}replaced {blue}BOT {default}({green}Secondary: {olive}%s{default})", player, sSecondary[player]);
}

/*****************************************************************************************
*
*                   THIS FIRES AND STORES A PLAYER'S SECONDARY
*
*****************************************************************************************/
void Event_OnPlayerUse(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	int targetid = event.GetInt("targetid");

	if (IsValidSurvivor(client) && IsValidEntity(targetid))
	{
		char sClassname[32];
		GetEntityClassname(targetid, sClassname, sizeof(sClassname));

		if (StrContains(sClassname, "weapon_spawn") != -1)
		{
			L4D2WeaponId weaponID = view_as<L4D2WeaponId>(GetEntProp(targetid, Prop_Send, "m_weaponID"));
			L4D2_GetWeaponNameByWeaponId(weaponID, sClassname, sizeof(sClassname));
		}

		if (StrContains(sClassname, "pistol") != -1 || StrContains(sClassname, "melee") != -1)
		{
			// We do an actual check of what the client has here because we deal with limitations in certain configs.
			// The limitation would cause the secondary to be set on the client while the client didn't even equip it.
			int iWeaponIndex = GetPlayerWeaponSlot(client, 1);

			if (IsValidEntity(iWeaponIndex))
			{
				char sWeaponName[32];
				GetEntityClassname(iWeaponIndex, sWeaponName, sizeof(sWeaponName));

				if (StrEqual(sWeaponName, "weapon_pistol")) sSecondary[client] = SECONDARY_PISTOL;
				else if (StrEqual(sWeaponName, "weapon_pistol_magnum")) sSecondary[client] = SECONDARY_PISTOL_MAGNUM;
				else if (StrEqual(sWeaponName, "weapon_melee")) DetermineMeleeScript(client, iWeaponIndex);

				if (bDebug) CPrintToChatAll("{green}[{olive}OnPlayerUse{green}] {default}- {blue}%N{default}'s picked up a secondary: ({green}Secondary: {olive}%s{default})", client, sSecondary[client]);
			}
		}
	}
}

/*****************************************************************************************
*
*           THIS IS USED TO STORE A PLAYER'S SECONDARY WEAPON ON INCAP,
*                     IN CASE HE/SHE DIES WHILE INCAPACITATED
*
*****************************************************************************************/
Action Event_OnPlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));
	if (IsValidSurvivor(victim))
	{
		if (bDebug) CPrintToChatAll("{green}[{olive}OnPlayerDeath{green}] {default}- {blue}%N {default}({green}Secondary: {olive}%s{default})", victim, sSecondary[victim]);
		SpawnSecondary(victim);
	}

	return Plugin_Continue;
}

bool IsValidSurvivor(int client)
{
	if (client <= 0
	|| client > MaxClients
	|| !IsClientInGame(client)) return false;
	return GetClientTeam(client) == 2;
}

void SpawnSecondary(int client)
{
	int weapon;

	if (StrEqual(sSecondary[client], SECONDARY_PISTOL)) weapon = CreateEntityByName("weapon_pistol");
	else if (StrEqual(sSecondary[client], SECONDARY_PISTOL_MAGNUM)) weapon = CreateEntityByName("weapon_pistol_magnum");
	else
	{
		if (StrEqual(sMeleeScript[client], MELEE_NONE))
		{
			CPrintToChat(client, "{blue}[{default}L4D2 Drop Secondary{blue}]{default}: {green}ERROR {default}- Something went wrong determining the melee script for your secondary weapon, report this issue to the {olive}Plugin Author{default}.");
			return;
		}

		// EDI 修复：只生成「本图已注册」的近战脚本。
		// 未注册的名字会让 m_hMeleeWeaponInfo 永远为 -1，换图时引擎空指针解引用导致服务器崩溃。
		if (bGuard && !IsMeleeScriptRegistered(sMeleeScript[client]))
		{
			if (bDebug) CPrintToChatAll("{green}[{olive}DropSecondary{green}] {default}- 跳过未注册的近战脚本 {olive}%s {default}(%N)", sMeleeScript[client], client);
			return;
		}

		weapon = CreateEntityByName("weapon_melee");
		if (weapon == -1) return;

		DispatchKeyValue(weapon, "melee_script_name", sMeleeScript[client]);
	}

	if (weapon != -1)
	{
		DispatchSpawn(weapon);
		float vOrigin[3];
		GetClientEyePosition(client, vOrigin);
		TeleportEntity(weapon, vOrigin, NULL_VECTOR, NULL_VECTOR);
	}
}

// 判断近战脚本名是否在本图注册（引擎网络字符串表 MeleeWeapons / meleeweapons，最多 16 项）。
bool IsMeleeScriptRegistered(const char[] sScriptName)
{
	if (sScriptName[0] == '\0') return false;
	if (StrEqual(sScriptName, MELEE_NONE, false)) return false;

	int iTable = FindStringTable("MeleeWeapons");
	if (iTable == INVALID_STRING_TABLE) iTable = FindStringTable("meleeweapons");
	if (iTable == INVALID_STRING_TABLE) return false;

	int iCount = GetStringTableNumStrings(iTable);
	char sName[MELEE_NAME_MAX];

	for (int i = 0; i < iCount; i++)
	{
		ReadStringTable(iTable, i, sName, sizeof(sName));
		if (StrEqual(sName, sScriptName, false)) return true;
	}

	return false;
}

void DetermineMeleeScript(int client, int iWeaponIndex)
{
	sSecondary[client] = SECONDARY_MELEE;
	char buffScriptName[MELEE_NAME_MAX];
	GetEntPropString(iWeaponIndex, Prop_Data, "m_strMapSetScriptName", buffScriptName, sizeof(buffScriptName));

	// 空串归一化为 MELEE_NONE，方便下游统一判断（rygive.sp 注释提到防暴警察警棍此处就是空串）
	if (buffScriptName[0] == '\0') sMeleeScript[client] = MELEE_NONE;
	else sMeleeScript[client] = buffScriptName;

	if (bDebug) CPrintToChatAll("{green}[{olive}DetermineMeleeScript{green}] {default}- {blue}%N {default}has {olive}%s {default}- MS: {olive}%s", client, buffScriptName, sMeleeScript[client]);
}

void DebugChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	bDebug = convar.BoolValue;
	CPrintToChatAll("{blue}[{default}L4D2 Drop Secondary{blue}]{default}: {green}Debugging {olive}%s", bDebug ? "Enabled" : "Disabled");
}

void GuardChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	bGuard = convar.BoolValue;
	CPrintToChatAll("{blue}[{default}L4D2 Drop Secondary{blue}]{default}: {green}近战脚本校验 {olive}%s", bGuard ? "Enabled" : "Disabled");
}
