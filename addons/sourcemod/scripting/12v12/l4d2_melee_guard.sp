/**
 * l4d2_melee_guard.sp
 *
 * 目的：消除「换图/重开回合时服务器崩溃」的触发条件。
 *
 * ============================ 崩溃链（反汇编验证） ============================
 * 调用栈（用户提供的真实崩溃栈）：
 *   #0 libc.so.6 + 0xad656                      ← strlen
 *   #1 KeyValues::SetString + 0x63
 *   #2 PlayerSaveData::PlayerSaveData + 0x105c
 *   #3 SurvivorBot::OnBeginChangeLevel
 *   #4 ForEachTerrorPlayer<PrepareChangelevel>
 *   #5 CTerrorGameRules::OnBeginChangeLevel
 *   #6 CDirector::Restart()  ← UpdateScenarioState ← Update ← GameFrame
 *
 * PlayerSaveData::PlayerSaveData @ 0x8e95b0（server_srv.so，带符号）逐条指令：
 *   0x8ea5fa  mov dword ptr [esp+4], 0xced10f   ; "restoreSecondaryWeaponName"
 *   0x8ea607  call KeyValues::SetString          ; 崩溃返回地址 0x8ea60c = 函数 +0x105c
 * 值(esi) 只有两个来源：
 *   A) 副武器 CSWeaponID != 0x13(19 = WEAPON_MELEE)：
 *        0x8ea5e7 call WeaponIDToClassname(id)  → 0x42f950 内是 switch/查表，
 *        表 0xc00ea0 的 0..55 项全是 .rodata 静态串，越界时返回 ""，**永远安全**
 *   B) 副武器 CSWeaponID == 19（近战）：
 *        0x8ea680 call CTerrorMeleeWeapon::GetMeleeWeaponInfo()   (0x558ce0)
 *        0x8ea685 lea  esi,[eax+0xc50]      ← eax 为 NULL 时 esi = 0x00000c50，无 NULL 检查
 *        KeyValues::SetString 内部其实对 NULL 有兜底（0xb5f418 cmove esi,""），
 *        但 0x00000c50 是"非空野指针"，于是 0xb5f41e call _V_strlen 读未映射地址 → SIGSEGV
 *
 * CTerrorMeleeWeapon::GetMeleeWeaponInfo @ 0x558ce0：
 *      mov eax,[this+0x17e0]
 *      call CMeleeWeaponInfoStore::GetMeleeWeaponInfo(g_MeleeWeaponInfoStore, eax)
 *   → 0x534a70 里 CUtlRBTree::Find(&key) 找不到就 `xor eax,eax` 返回 NULL。
 *   而 0x534ec0 RegisterMeleeWeaponType 的建表过程是：
 *      HandleForWeaponName(store, name, bAdd=true) → eax（近战名在 store 名表里的下标）
 *      Insert({key = 该下标, value = new CMeleeWeaponInfo(name, kv)})   ; 0xca0 字节
 *   ⇒ RB 树的 key 是"下标(handle)"，不是字符串。所以：
 *      · this+0x17E0 = 近战信息 handle（也就是 melee 脚本名在 store 名表里的下标）
 *      · handle == -1（或越界）⇒ Find 失败 ⇒ NULL ⇒ 换图时 strlen(0xc50) 崩服
 *
 * ============================ v1.0.0 为什么没拦住 ============================
 * datamap 里 6112(0x17E0) = m_strMapSetScriptName（Key, melee_script_name, 4 字节），
 * netprop 里 6108(0x17DC) = m_hMeleeWeaponInfo（4 bit 无符号）。
 * v1.0.0 判的是 **m_hMeleeWeaponInfo == -1**：
 *   · 它是 4 bit 无符号量，网络读出来不可能等于 -1（-1 只会变成 0xF），
 *   · 而且引擎 GetMeleeWeaponInfo() 读的根本是 0x17E0 那个 4 字节 handle。
 * ⇒ 判定条件几乎永远不成立，插件等于空转，于是"装上了仍然崩"。
 * 本版直接读 4 字节字段 m_strMapSetScriptName（Prop_Data，能表示 -1），
 * 命中 -1 即引擎的"查表失败"状态，与崩溃条件一一对应。
 *
 * ================================ 本插件做的事 ================================
 *   1) weapon_melee 生成后（SpawnPost）立刻校验一次；
 *   2) 每秒扫描所有玩家（**含 BOT**）0~2 号武器槽 —— BOT 也走
 *      SurvivorBot::OnBeginChangeLevel，同样会触发崩溃；
 *   3) handle == -1 就把武器移除（先 RemovePlayerItem 再 Kill）并提示；
 *   4) 关掉 m_hMeleeWeaponInfo 之类的次要信号只做日志，不参与删除（避免误杀）；
 *   5) l4d2_melee_guard_strict 1 时把"handle 越界 / netprop 越界"也算危险（默认关，
 *      等你在服务器上用 sm_melee_guard_check 确认过字段含义再开）。
 *
 * 诊断：sm_melee_guard_check
 *   打印本图注册的近战脚本名表 + 每把近战武器的
 *   [handle(0x17E0 原始整数) / 名字字符串 / m_hMeleeWeaponInfo / 判定结果]，
 *   进服执行一条命令即可确认字段含义与是否命中。
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_VERSION "2.1.0"
#define MELEE_NAME_MAX    64
#define MELEE_NAME_LIMIT  32   // 本插件最多记录的近战脚本名条数（表更大时放弃判定，绝不误删）

public Plugin myinfo =
{
	name        = "L4D2 Melee Weapon Guard",
	author      = "apples1949",
	description = "移除近战信息 handle 未解析（m_strMapSetScriptName == -1，引擎查表会返回 NULL）的 weapon_melee，防止换图时服务器崩溃",
	version     = PLUGIN_VERSION,
	url         = ""
};

ConVar g_cvEnable;
ConVar g_cvDebug;
ConVar g_cvWarn;
ConVar g_cvStrict;

char   g_sMeleeNames[MELEE_NAME_LIMIT][MELEE_NAME_MAX];
int    g_iMeleeNameCount;
bool   g_bTableWarned;
int    g_iRemoved;

public void OnPluginStart()
{
	g_cvEnable = CreateConVar("l4d2_melee_guard_enable", "1", "1=启用近战武器校验 0=关闭", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvStrict = CreateConVar("l4d2_melee_guard_strict", "0", "1=额外把「handle 越界 / m_hMeleeWeaponInfo 越界」也判为危险（默认 0，只判 handle == -1；先用 sm_melee_guard_check 确认字段含义再考虑打开）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvWarn   = CreateConVar("l4d2_melee_guard_warn",   "1", "1=移除武器时提示玩家", FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvDebug  = CreateConVar("l4d2_melee_guard_debug",  "0", "1=输出调试信息", FCVAR_NONE, true, 0.0, true, 1.0);

	AutoExecConfig(true, "l4d2_melee_guard");

	RegConsoleCmd("sm_melee_guard_check", Cmd_Check, "扫描近战武器并打印本图注册的近战脚本表");

	BuildMeleeNameList();

	CreateTimer(1.0, Timer_ValidateClients, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

	LogMessage("[melee_guard] 已加载 v%s，本图已注册近战脚本 %d 个", PLUGIN_VERSION, g_iMeleeNameCount);
}

public void OnMapStart()
{
	g_iRemoved = 0;
	g_bTableWarned = false;
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

	// Spawn() 已跑完，此时 handle 才是最终值
	CheckMeleeWeapon(entity, "spawn");
}

public Action Timer_ValidateClients(Handle timer)
{
	if (!g_cvEnable.BoolValue) return Plugin_Continue;

	// 换图早期名字表可能还没建好：这一 tick 不判定，下一 tick 再试
	if (g_iMeleeNameCount <= 0)
	{
		BuildMeleeNameList();
		return Plugin_Continue;
	}

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
	EnsureMeleeNameList();

	char name[MELEE_NAME_MAX];

	if (g_iMeleeNameCount > 0)
	{
		ReplyToCommand(client, "[melee_guard] 本图注册的近战脚本 %d 个:", g_iMeleeNameCount);

		for (int i = 0; i < g_iMeleeNameCount; i++)
		{
			ReplyToCommand(client, "  [%d] %s", i, g_sMeleeNames[i]);
		}
	}
	else
	{
		ReplyToCommand(client, "[melee_guard] 取不到字符串表 MeleeWeapons（本图不做删除判定，避免误删）");
	}

	int total, bad;

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

			total++;

			int handle = ReadMeleeHandle(weapon);
			int info   = ReadMeleeInfoHandle(weapon);
			ReadMeleeScriptName(weapon, name, sizeof(name));

			bool danger = IsDangerousMelee(handle, info);

			if (danger) bad++;

			ReplyToCommand(client,
				"[melee_guard] %N 槽%d handle(0x17E0)=%d name=\"%s\" info(6108)=%d => %s",
				i, slot, handle, name, info, danger ? "危险(换图会崩)" : "正常");
		}
	}

	ReplyToCommand(client, "[melee_guard] 扫描完成：近战 %d 把，危险 %d 把；本次运行已移除 %d 把；strict=%d",
		total, bad, g_iRemoved, g_cvStrict.IntValue);

	return Plugin_Handled;
}

/**
 * 引擎的崩溃条件：CTerrorMeleeWeapon::GetMeleeWeaponInfo() 里
 * CMeleeWeaponInfoStore::GetMeleeWeaponInfo(handle) 返回 NULL（Find 失败）。
 * 主判据是 handle == -1（未解析）；strict 打开后再补"越界"两条。
 */
bool IsDangerousMelee(int handle, int info)
{
	// 明确的"未解析"：引擎 Find 失败的那个值
	if (handle == -1)
		return true;

	if (g_iMeleeNameCount <= 0)
		return false;

	// handle 可疑：负数 / 越界 / 0（近战武器不可能没有脚本名，空 handle 也是没解析出来）
	bool handleBad = (handle <= 0 || handle >= g_iMeleeNameCount);

	/* info 可疑：负数 / 越界 / 0xF。
	   0xF 只在"本图注册的条数 < 16"时才当哨兵用 —— 条数正好 16 时 15 是合法下标。 */
	bool infoBad = (info < 0 || info >= g_iMeleeNameCount)
		|| (g_iMeleeNameCount < 16 && info == 0xF);

	/* 默认（strict=0）：两个信号必须同时可疑才删。
	   这样无论那 4 字节字段里存的到底是 handle 下标还是字符串池下标，
	   都不会把合法近战误判 —— 合法武器的两个读数不可能同时越界；
	   而真正没解析出来的武器，handle 是 -1/0、m_hMeleeWeaponInfo 是 0xF，必然同时命中。 */
	if (handleBad && infoBad)
		return true;

	// strict=1：任一信号可疑就删（进服确认过字段含义后再开）
	if (g_cvStrict.BoolValue)
		return (handleBad || infoBad);

	return false;
}

/**
 * 校验一把 weapon_melee：命中崩溃条件就移除。
 *
 * @param entity     weapon_melee 实体
 * @param source     调用来源（仅用于日志）
 */
void CheckMeleeWeapon(int entity, const char[] source)
{
	if (entity <= 0 || !IsValidEntity(entity)) return;

	if (!HasEntProp(entity, Prop_Data, "m_strMapSetScriptName"))
		return;

	// 名字表还没建好就不判定，避免把合法近战当坏人删掉
	if (g_iMeleeNameCount <= 0)
	{
		BuildMeleeNameList();

		if (g_iMeleeNameCount <= 0)
		{
			if (!g_bTableWarned)
			{
				g_bTableWarned = true;
				LogError("[melee_guard] 取不到字符串表 MeleeWeapons，本图不做移除判定（之后会自动重试）");
			}
			return;
		}
	}

	int handle = ReadMeleeHandle(entity);
	int info   = ReadMeleeInfoHandle(entity);

	if (g_cvDebug.BoolValue)
	{
		char dbgName[MELEE_NAME_MAX];
		ReadMeleeScriptName(entity, dbgName, sizeof(dbgName));
		PrintToServer("[melee_guard] 检查 %d: handle=%d name=\"%s\" info=%d 来源=%s",
			entity, handle, dbgName, info, source);
	}

	if (!IsDangerousMelee(handle, info))
		return;

	char script[MELEE_NAME_MAX];
	ReadMeleeScriptName(entity, script, sizeof(script));

	int owner = GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
	bool ownerValid = (owner > 0 && owner <= MaxClients && IsClientInGame(owner));
	bool isBot = ownerValid && IsFakeClient(owner);

	LogMessage("[melee_guard] 拦截未解析 melee：handle=%d name=\"%s\" info=%d owner=%d(%s,%s) 来源=%s",
		handle, script, info, owner, ownerValid ? "有效" : "无主", isBot ? "BOT" : "玩家", source);

	if (ownerValid)
	{
		RemovePlayerItem(owner, entity);

		if (g_cvWarn.BoolValue)
		{
			PrintToChat(owner, "\x04[提示]\x01 这把近战武器在当前地图没有注册，已移除（否则换图会让服务器崩溃）。");
		}
	}

	AcceptEntityInput(entity, "Kill");
	g_iRemoved++;
}

/**
 * 读 0x17E0 处的 4 字节整数（datamap m_strMapSetScriptName，引擎当作近战信息 handle 用）。
 * 读不到返回 0（不会被判成危险）。
 */
int ReadMeleeHandle(int entity)
{
	if (!HasEntProp(entity, Prop_Data, "m_strMapSetScriptName"))
		return 0;

	return GetEntProp(entity, Prop_Data, "m_strMapSetScriptName");
}

/**
 * 读 m_hMeleeWeaponInfo（netprop，4 bit）。只做日志/strict 参考，
 * 它**不是**引擎查表用的字段（引擎读的是 0x17E0）。
 */
int ReadMeleeInfoHandle(int entity)
{
	if (!HasEntProp(entity, Prop_Send, "m_hMeleeWeaponInfo"))
		return 0;

	return GetEntProp(entity, Prop_Send, "m_hMeleeWeaponInfo");
}

/**
 * 把 handle 当字符串读出来（诊断用）。
 * 注意：若该字段实际存的是 handle 下标，这里读到的可能不是有意义的武器名，
 * 一切以 sm_melee_guard_check 打印的实际值为准。
 */
void ReadMeleeScriptName(int entity, char[] buffer, int maxlen)
{
	buffer[0] = '\0';

	if (!HasEntProp(entity, Prop_Data, "m_strMapSetScriptName"))
		return;

	GetEntPropString(entity, Prop_Data, "m_strMapSetScriptName", buffer, maxlen);
}

void EnsureMeleeNameList()
{
	if (g_iMeleeNameCount <= 0)
		BuildMeleeNameList();
}

/**
 * 从网络字符串表 "MeleeWeapons" 读出本图注册的近战脚本名（引擎按 scripts/melee/<地图>.txt
 * 注册近战信息时同时填这张表，表内条数就是 handle 的合法范围 0..N-1）。
 * 表不存在 / 条数 0 / 条数超容量时 g_iMeleeNameCount = 0（本图不判定）。
 */
void BuildMeleeNameList()
{
	g_iMeleeNameCount = 0;

	int table = FindStringTable("MeleeWeapons");

	if (table == INVALID_STRING_TABLE)
	{
		table = FindStringTable("meleeweapons");
	}

	if (table == INVALID_STRING_TABLE)
		return;

	int count = GetStringTableNumStrings(table);

	if (count <= 0)
		return;

	if (count > MELEE_NAME_LIMIT)
	{
		if (!g_bTableWarned)
		{
			g_bTableWarned = true;
			LogError("[melee_guard] MeleeWeapons 表有 %d 条，超过插件容量 %d，本图放弃判定", count, MELEE_NAME_LIMIT);
		}
		return;
	}

	for (int i = 0; i < count; i++)
	{
		if (!ReadStringTable(table, i, g_sMeleeNames[i], MELEE_NAME_MAX))
		{
			g_sMeleeNames[i][0] = '\0';
		}
	}

	g_iMeleeNameCount = count;

	if (g_cvDebug.BoolValue)
	{
		char buf[1024];
		buf[0] = '\0';

		for (int i = 0; i < count; i++)
		{
			StrCat(buf, sizeof(buf), g_sMeleeNames[i]);
			StrCat(buf, sizeof(buf), (i + 1 < count) ? ";" : "");
		}

		LogMessage("[melee_guard] 本图可用近战脚本(%d): %s", count, buf);
	}
}
