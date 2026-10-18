/**
 * l4d2_melee_guard.sp
 *
 * 目的：消除「换图/重开回合时服务器崩溃」的触发条件。
 *
 * 崩溃链（已用 IDA 在 server_srv.so 2.2.4.3 上逐条指令验证）：
 *   CDirector::Restart -> CTerrorGameRules::OnBeginChangeLevel
 *     -> ForEachTerrorPlayer<PrepareChangelevel> -> SurvivorBot::OnBeginChangeLevel
 *     -> PlayerSaveData::PlayerSaveData(CTerrorPlayer*, char const*)
 *        melee 分支：call CTerrorMeleeWeapon::GetMeleeWeaponInfo()
 *                    lea  esi,[eax+0xc50]     <-- 没有 NULL 检查
 *        KeyValues::SetString(kv, "restoreSecondaryWeaponName", esi)
 *        -> _V_strlen(0x00000c50) -> strlen 读未映射地址 -> SIGSEGV
 *
 * 只要玩家/BOT 身上那把 weapon_melee 的 m_hMeleeWeaponInfo（Prop_Send，偏移 0x17e0）
 * 是 -1（即它的 melee 脚本名不在当前地图的 CMeleeWeaponInfoStore 里），下次换图就会崩。
 * 该值是 -1 的成因：melee_script_name 为空、拼错、属于别的地图/剧本、或 melee_reload 后失效。
 *
 * 本插件做的事：在 weapon_melee 生成的下一帧、以及每 5 秒扫描一次玩家武器槽，
 * 一旦发现 m_hMeleeWeaponInfo == -1，就把这把武器移除，从根上掐掉崩溃条件。
 * 已经是 -1 的武器无法就地修复（引擎不会重新解析名字），只能拿掉。
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_VERSION "1.0.0"
#define MELEE_NAME_MAX    64
#define MELEE_NAME_LIMIT  16   // 引擎 MeleeWeapons 字符串表上限就是 16

public Plugin myinfo =
{
	name        = "L4D2 Melee Weapon Guard",
	author      = "applemod crash analysis",
	description = "移除 melee 脚本名未注册（m_hMeleeWeaponInfo == -1）的 weapon_melee，防止换图时服务器崩溃",
	version     = PLUGIN_VERSION,
	url         = ""
};

ConVar g_cvEnable;
ConVar g_cvDebug;
ConVar g_cvWarn;

char   g_sMeleeNames[MELEE_NAME_LIMIT][MELEE_NAME_MAX];
int    g_iMeleeNameCount;
bool   g_bPropMissing;
int    g_iRemoved;

public void OnPluginStart()
{
	g_cvEnable = CreateConVar("l4d2_melee_guard_enable", "1", "1=启用近战武器校验 0=关闭", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvDebug  = CreateConVar("l4d2_melee_guard_debug",  "0", "1=输出调试信息", FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvWarn   = CreateConVar("l4d2_melee_guard_warn",   "1", "1=移除武器时提示玩家", FCVAR_NONE, true, 0.0, true, 1.0);

	AutoExecConfig(true, "l4d2_melee_guard");

	RegConsoleCmd("sm_melee_guard_check", Cmd_Check, "手动扫描一次所有玩家的近战武器");

	BuildMeleeNameList();

	CreateTimer(1.0, Timer_ValidateClients, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

	LogMessage("[melee_guard] 已加载，本图注册的近战脚本 %d 个", g_iMeleeNameCount);
}

public void OnMapStart()
{
	BuildMeleeNameList();
}

public void OnConfigsExecuted()
{
	BuildMeleeNameList();
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (entity <= 0) return;
	if (StrEqual(classname, "weapon_melee", false))
	{
		SDKHook(entity, SDKHook_SpawnPost, OnMeleeSpawnPost);
	}
}

public void OnMeleeSpawnPost(int entity)
{
	if (!g_cvEnable.BoolValue) return;
	// Spawn() 已经跑完，此时 m_hMeleeWeaponInfo 已是最终值
	CheckMeleeWeapon(entity, "spawn");
}

public Action Timer_ValidateClients(Handle timer)
{
	if (!g_cvEnable.BoolValue || g_bPropMissing) return Plugin_Continue;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i)) continue;

		for (int slot = 0; slot <= 2; slot++)
		{
			int weapon = GetPlayerWeaponSlot(i, slot);
			if (weapon <= 0 || !IsValidEntity(weapon)) continue;

			char cls[64];
			if (!GetEntityClassname(weapon, cls, sizeof(cls))) continue;
			if (StrEqual(cls, "weapon_melee", false))
			{
				CheckMeleeWeapon(weapon, "timer");
			}
		}
	}

	return Plugin_Continue;
}

public Action Cmd_Check(int client, int args)
{
	int found = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i)) continue;
		for (int slot = 0; slot <= 2; slot++)
		{
			int weapon = GetPlayerWeaponSlot(i, slot);
			if (weapon <= 0 || !IsValidEntity(weapon)) continue;
			char cls[64];
			if (!GetEntityClassname(weapon, cls, sizeof(cls))) continue;
			if (!StrEqual(cls, "weapon_melee", false)) continue;

			int info = GetEntProp(weapon, Prop_Send, "m_hMeleeWeaponInfo");
			char script[MELEE_NAME_MAX];
			GetEntPropString(weapon, Prop_Data, "m_strMapSetScriptName", script, sizeof(script));

			if (info == -1)
			{
				found++;
				ReplyToCommand(client, "[melee_guard] 危险: 玩家 %d 槽位 %d 的 melee 脚本 \"%s\" 未注册 (info=-1)", i, slot, script);
			}
		}
	}

	ReplyToCommand(client, "[melee_guard] 扫描完成，危险武器 %d 把；本图注册脚本 %d 个；本次运行已移除 %d 把", found, g_iMeleeNameCount, g_iRemoved);
	return Plugin_Handled;
}

void CheckMeleeWeapon(int entity, const char[] source)
{
	if (entity <= 0 || !IsValidEntity(entity)) return;

	if (!HasEntProp(entity, Prop_Send, "m_hMeleeWeaponInfo"))
	{
		if (!g_bPropMissing)
		{
			g_bPropMissing = true;
			LogError("[melee_guard] 找不到属性 m_hMeleeWeaponInfo，插件自动停用（请检查游戏版本）");
		}
		return;
	}

	int info = GetEntProp(entity, Prop_Send, "m_hMeleeWeaponInfo");
	if (info != -1) return;

	char script[MELEE_NAME_MAX];
	GetEntPropString(entity, Prop_Data, "m_strMapSetScriptName", script, sizeof(script));

	int owner = GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
	bool ownerValid = (owner > 0 && owner <= MaxClients && IsClientInGame(owner));
	bool isBot = ownerValid && IsFakeClient(owner);

	LogMessage("[melee_guard] 拦截无效 melee：script=\"%s\" info=-1 owner=%d(%s,%s) 来源=%s",
		script, owner, ownerValid ? "有效" : "无主", isBot ? "BOT" : "玩家", source);

	if (ownerValid)
	{
		RemovePlayerItem(owner, entity);
		if (g_cvWarn.BoolValue)
		{
			PrintToChat(owner, "\x04[提示]\x01 这把近战武器未被当前地图注册，已移除（否则换图会让服务器崩溃）。");
		}
	}

	AcceptEntityInput(entity, "Kill");
	g_iRemoved++;

	if (g_cvDebug.BoolValue)
	{
		PrintToServer("[melee_guard] 已移除无效 weapon_melee (script=\"%s\")", script);
	}
}

void BuildMeleeNameList()
{
	g_iMeleeNameCount = 0;

	int table = FindStringTable("MeleeWeapons");
	if (table == INVALID_STRING_TABLE)
	{
		table = FindStringTable("meleeweapons");
	}
	if (table == INVALID_STRING_TABLE)
	{
		if (!g_bPropMissing)
		{
			LogError("[melee_guard] 找不到 MeleeWeapons 字符串表，本图无法校验（稍后重试）");
		}
		return;
	}

	int count = GetStringTableNumStrings(table);
	if (count > MELEE_NAME_LIMIT) count = MELEE_NAME_LIMIT;

	for (int i = 0; i < count; i++)
	{
		ReadStringTable(table, i, g_sMeleeNames[i], MELEE_NAME_MAX);
	}

	g_iMeleeNameCount = count;

	if (g_cvDebug.BoolValue)
	{
		char buf[512];
		buf[0] = '\0';
		for (int i = 0; i < count; i++)
		{
			StrCat(buf, sizeof(buf), g_sMeleeNames[i]);
			StrCat(buf, sizeof(buf), (i + 1 < count) ? ";" : "");
		}
		LogMessage("[melee_guard] 本图可用近战脚本: %s", buf);
	}
}
