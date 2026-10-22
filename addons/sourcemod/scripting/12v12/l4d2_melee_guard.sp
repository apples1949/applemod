/**
 * l4d2_melee_guard.sp
 *
 * 目的：消除「换图 / 重开场景时服务器崩溃」的触发条件。
 *
 * ======================== 崩溃链（server_srv.so 反汇编逐条验证） ========================
 * 调用栈（真实崩溃报告 2.txt，SIGSEGV accessing 0xc50）：
 *   #0 libc.so.6 + 0xad656                        ← _V_strlen
 *   #1 KeyValues::SetString + 0x63                ← 0xb5f3c0 + 0x63
 *   #2 PlayerSaveData::PlayerSaveData + 0x105c     ← 0x8e95b0 + 0x105c
 *   #3 SurvivorBot::OnBeginChangeLevel + 0x131
 *   #4 ForEachTerrorPlayer<PrepareChangelevel> + 0x6e
 *   #5 CTerrorGameRules::OnBeginChangeLevel + 0x6c
 *   #6 CDirector::Restart() + 0x431
 *   #7 CDirector::UpdateScenarioState() + 0x2c0
 *   #8 CDirector::Update() + 0xf3f
 *   #9 CServerGameDLL::GameFrame(bool) + 0x61c
 *   ...
 *
 * 崩溃点 0x8ea5cc ~ 0x8ea60c（PlayerSaveData 构造函数内）：
 *   0x8ea5dc  call [edx+0x638]                       ; 取副武器 CSWeaponID → ebx
 *   0x8ea5e7  call WeaponIDToClassname(ebx)          ; 0x42f950
 *   0x8ea5ec  cmp  ebx, 0x13                         ; 19 = WEAPON_MELEE
 *   0x8ea5f1  je   0x8ea61e                          ; 近战 → 走专用分支
 *   0x8ea5fa  mov  [esp+4], 0xced10f                 ; "restoreSecondaryWeaponName"
 *   0x8ea607  call KeyValues::SetString              ; 崩溃返回地址 0x8ea60c = +0x105c
 *
 * 近战专用分支（这就是 0xc50 的来源）：
 *   0x8ea680  call CTerrorMeleeWeapon::GetMeleeWeaponInfo()   ; 0x558ce0，返回 CMeleeWeaponInfo*
 *   0x8ea685  lea  esi, [eax + 0xc50]                ; ★ eax == NULL 时 esi = 0x00000c50
 *   0x8ea68b  jmp  0x8ea5f3                          ; 带着这个野指针去 SetString
 *
 *   KeyValues::SetString 只对 **NULL** 有兜底：
 *     0xb5f40a  test esi,esi
 *     0xb5f418  cmove esi, ""        ; 只有 NULL 才换成空串
 *     0xb5f41e  call _V_strlen       ; 对 0x00000c50 这种"非空野指针"直接读未映射页
 *   ⇒ SIGSEGV /SEGV_MAPERR accessing 0xc50
 *
 * GetMeleeWeaponInfo() 为什么会返回 NULL：
 *   0x558ce6  mov eax,[ebp+8]
 *   0x558ce9  mov eax,[eax+0x17e0]                    ; ← 读 datamap 字段（下详）
 *   0x558cf6  mov [esp+4], eax
 *   0x558cfa  call CMeleeWeaponInfoStore::GetMeleeWeaponInfo(int)   ; 0x534a70
 *   0x534a8d  call CUtlMap<int, CMeleeWeaponInfo*, int>::Find
 *   0x534a92  cmp eax,-1 / je 0x534ab0 → **xor eax,eax ⇒ return NULL**
 *   CMeleeWeaponInfoStore::GetInvalidHandle() = -1（0x534120）
 *
 * HandleForWeaponName(name, bAdd) @0x534ac0：
 *   0x534ad9  call AllocPooledString(name)            ; 名字池化成 string_t
 *   0x534af3  cmp [ecx],esi / 0x534b00 cmp [ecx+eax*4],esi   ; 在 CUtlVector<string_t> 里线性查
 *   0x534b21  CUtlVector<string_t>::InsertBefore      ; bAdd 且没找到 → 追加
 *   0x534b3d  mov eax,-1                              ; 不追加且没找到 → -1
 *   ⇒ 未注册的名字拿不到有效 key ⇒ Find 失败 ⇒ NULL ⇒ 换图保存 BOT 数据时崩服
 *
 * ============================== 两个字段，别搞混（关键） ==============================
 *  · datamap `m_strMapSetScriptName`  Offset **6112 (0x17E0)**  (Save|Key)(4 Bytes)
 *      —— 类型是 FIELD_STRING（string_t，4 字节）。引擎就是把这个 4 字节值直接当
 *         int handle 传给 GetMeleeWeaponInfo(int) 当 RB 树的 key。
 *      —— SourceMod 只能用 GetEntPropString() 把它解析成"名字字符串"；
 *         用 GetEntProp() 当整数读会抛 "Data field ... is not an integer (2)"。
 *  · netprop `m_hMeleeWeaponInfo`     Offset **6108 (0x17DC)**  (integer)(bits 4)(Unsigned)
 *      —— 只有 4 bit！取值范围 0..15，**永远不可能等于 -1**。
 *      —— 所以它不能当"未解析"的判据（v1.0 就是栽在这里，插件等于空转），
 *         本插件只用它做日志 / strict 模式下的辅助越界信号。
 *
 * ================================ 本插件做的事 ================================
 *   判据（等价于"引擎 Find 会失败"）：
 *     脚本名为空  ⇒ handle = -1 ⇒ 危险
 *     脚本名不在本图 "MeleeWeapons" 表里 ⇒ handle = -1 ⇒ 危险
 *     （strict=1 时额外把 handle/info 越界也算危险；默认关，先用 sm_melee_guard_check 确认）
 *   动作：
 *     1) weapon_melee SpawnPost 立刻校验一次；
 *     2) 每秒扫描所有客户端（**含 BOT**）0~2 号槽 —— 只有 SurvivorBot 会走
 *        SurvivorBot::OnBeginChangeLevel，BOT 手里的坏近战才是崩服的那一把；
 *     3) 命中就 RemovePlayerItem + Kill（dryrun=1 时只记录不删）；
 *     4) 名字表用固定 256 条（旧版 32 条 + "超了整图放弃"是隐患）。
 *
 * 诊断：sm_melee_guard_check
 *   打印本图注册的近战脚本名表 + 每把近战武器的
 *   [handle(名表下标) / 名字 / m_hMeleeWeaponInfo / 判定结果]。
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_VERSION  "2.3.0"

#define MELEE_NAME_MAX  64     // 单个脚本名长度上限
#define MELEE_NAME_CAP  256    // 名表容量（旧版 32，实战里自定义近战一多就会整图放弃判定）

ConVar  g_cvEnable;
ConVar  g_cvStrict;
ConVar  g_cvWarn;
ConVar  g_cvDebug;
ConVar  g_cvDryRun;

char    g_sMeleeNames[MELEE_NAME_CAP][MELEE_NAME_MAX];
int     g_iMeleeNameCount;
bool    g_bTableWarned;
int     g_iRemoved;
int     g_iWouldRemove;

public Plugin myinfo =
{
	name        = "L4D2 Melee Weapon Guard",
	author      = "apples1949",
	description = "移除近战信息解析不出来（GetMeleeWeaponInfo 返回 NULL）的 weapon_melee，防止换图时保存 BOT 数据崩溃",
	version     = PLUGIN_VERSION,
	url         = ""
};

public void OnPluginStart()
{
	g_cvEnable = CreateConVar("l4d2_melee_guard_enable", "1", "1=启用近战武器校验 0=关闭", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvStrict = CreateConVar("l4d2_melee_guard_strict", "0", "1=额外把 handle/info 越界也判为危险（默认 0，只判'解析不出来'；先用 sm_melee_guard_check 确认字段含义再考虑打开）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvDryRun = CreateConVar("l4d2_melee_guard_dryrun", "0", "1=只记录不删除（观察期用，确认不会误杀再改回 0）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvWarn   = CreateConVar("l4d2_melee_guard_warn",   "1", "1=移除武器时提示玩家", FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvDebug  = CreateConVar("l4d2_melee_guard_debug",  "0", "1=输出调试信息", FCVAR_NONE, true, 0.0, true, 1.0);

	AutoExecConfig(true, "l4d2_melee_guard");

	RegConsoleCmd("sm_melee_guard_check", Cmd_Check, "扫描近战武器并打印本图注册的近战脚本表");

	BuildMeleeNameList();

	CreateTimer(1.0, Timer_ValidateClients, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

	LogMessage("[melee_guard] 已加载 v%s，本图已注册近战脚本 %d 个（容量 %d）",
		PLUGIN_VERSION, g_iMeleeNameCount, MELEE_NAME_CAP);
}

public void OnMapStart()
{
	g_iRemoved = 0;
	g_iWouldRemove = 0;
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
				"[melee_guard] %N%s 槽%d handle=%d name=\"%s\" info(4bit)=%d => %s",
				i, IsFakeClient(i) ? "(BOT)" : "", slot, handle, name, info,
				danger ? "危险(换图会崩)" : "正常");
		}
	}

	ReplyToCommand(client, "[melee_guard] 扫描完成：近战 %d 把，危险 %d 把；本次运行已移除 %d 把（dryrun 下应删 %d 把）；strict=%d dryrun=%d",
		total, bad, g_iRemoved, g_iWouldRemove, g_cvStrict.IntValue, g_cvDryRun.IntValue);

	return Plugin_Handled;
}

/**
 * 判据：与引擎等价。
 *
 * 引擎路径：CTerrorMeleeWeapon::GetMeleeWeaponInfo()（0x558ce0）
 *   → 拿 m_strMapSetScriptName(0x17E0) 当 int key
 *   → CMeleeWeaponInfoStore::GetMeleeWeaponInfo(int)（0x534a70）里 CUtlMap::Find
 *   → 未命中返回 NULL → 0x8ea685 lea esi,[eax+0xc50] → strlen(0xc50) → 崩
 *
 * 所以"名字解析不出来"才是真危险；handle 就是名字在本图注册表里的下标：
 *   >= 0  正常
 *   -1    脚本名为空，或不在本图表里 —— 与引擎 Find 失败等价
 *
 * info（m_hMeleeWeaponInfo）只有 4 bit（0..15），**不可能是 -1**，
 * 只作日志 / strict 下的辅助信号。
 */
bool IsDangerousMelee(int handle, int info)
{
	/* 表没建好时一律不判定（绝不能在这里返回 true）：
	   否则换图早期 handle 必然读成 -1，会把所有合法近战全删了。 */
	if (g_iMeleeNameCount <= 0)
		return false;

	// 主判据：解析不出来 ⇒ 引擎必返 NULL ⇒ 换图必崩
	if (handle < 0)
		return true;

	// 严格模式：越界也判危险（进服确认过字段含义后再开）
	if (g_cvStrict.BoolValue)
	{
		if (handle >= g_iMeleeNameCount)
			return true;

		if (info < 0 || info >= g_iMeleeNameCount)
			return true;
	}

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

	int  owner      = GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
	bool ownerValid = (owner > 0 && owner <= MaxClients && IsClientInGame(owner));
	bool isBot      = ownerValid && IsFakeClient(owner);

	if (g_cvDryRun.BoolValue)
	{
		g_iWouldRemove++;
		LogMessage("[melee_guard][DRYRUN] 应删除未解析 melee：handle=%d name=\"%s\" info=%d owner=%d(%s,%s) 来源=%s",
			handle, script, info, owner, ownerValid ? "有效" : "无主", isBot ? "BOT" : "玩家", source);
		return;
	}

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
 * 取这把武器在"近战脚本名注册表"里的下标 —— 这个下标就是引擎 Find 用的 handle。
 *
 * 为什么不用 GetEntProp 读 0x17E0：
 *   datamap 里 `m_strMapSetScriptName` 的类型是 FIELD_STRING（string_t，4 字节），
 *   SourceMod 报的 "Data field m_strMapSetScriptName is not an integer (2)" 里
 *   (2) 就是 PropField_String。当整数读必抛异常、整个 CheckMeleeWeapon 被中断。
 *
 * 正确做法（与引擎一致）：
 *   引擎注册近战时用 HandleForWeaponName() 把名字池化成 string_t 再取下标当 key；
 *   我们在 BuildMeleeNameList() 里读同一张网络字符串表 "MeleeWeapons"，
 *   "名字 -> 下标"即等价于引擎的 key。
 *
 * 返回值：
 *   >= 0  正常下标
 *   -1    读不到脚本名，或名字不在本图表里 —— 等同于引擎 Find 失败（换图会崩）
 */
int ReadMeleeHandle(int entity)
{
	char script[MELEE_NAME_MAX];
	ReadMeleeScriptName(entity, script, sizeof(script));

	if (script[0] == '\0')
		return -1;

	return FindMeleeNameIndex(script);
}

/**
 * 在 g_sMeleeNames 里查脚本名下标，找不到返回 -1。
 * 表还没建好（g_iMeleeNameCount <= 0）时也返回 -1，但调用方在此之前已经
 * 用 g_iMeleeNameCount 做过守卫，不会因此误删。
 */
int FindMeleeNameIndex(const char[] script)
{
	for (int i = 0; i < g_iMeleeNameCount; i++)
	{
		if (StrEqual(g_sMeleeNames[i], script, false))
			return i;
	}

	return -1;
}

/**
 * 读 m_hMeleeWeaponInfo（netprop，4 bit 无符号，0x17DC）。**只做日志 / strict 参考**。
 * 注意：4 bit 取值范围 0..15，读出来不可能是 -1，不能当"未解析"判据。
 */
int ReadMeleeInfoHandle(int entity)
{
	if (!HasEntProp(entity, Prop_Send, "m_hMeleeWeaponInfo"))
		return 0;

	return GetEntProp(entity, Prop_Send, "m_hMeleeWeaponInfo");
}

/**
 * 读出该近战武器的脚本名（datamap m_strMapSetScriptName，类型 string）。
 * 必须用 GetEntPropString；用 GetEntProp 当整数读会抛 "not an integer (2)"。
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
 * 从网络字符串表 "MeleeWeapons" 读出本图注册的近战脚本名（引擎注册近战信息时
 * 同时填这张表，表内条数就是 handle 的合法范围 0..N-1）。
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

	if (count > MELEE_NAME_CAP)
	{
		if (!g_bTableWarned)
		{
			g_bTableWarned = true;
			LogError("[melee_guard] MeleeWeapons 表有 %d 条，超过插件容量 %d，本图放弃判定", count, MELEE_NAME_CAP);
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
		char buf[2048];
		buf[0] = '\0';

		for (int i = 0; i < count; i++)
		{
			StrCat(buf, sizeof(buf), g_sMeleeNames[i]);
			StrCat(buf, sizeof(buf), (i + 1 < count) ? ";" : "");
		}

		LogMessage("[melee_guard] 本图可用近战脚本(%d): %s", count, buf);
	}
}
