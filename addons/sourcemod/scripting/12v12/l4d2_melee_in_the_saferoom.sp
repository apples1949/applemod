#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>

/*
 * 3.2.0（2026-11-11）需求：生还者离开安全区域「之前」，安全屋里的近战武器闪烁发光。
 *
 * 做法（自带实现，不依赖别的插件；发光写法照抄本仓库已验证的
 * applemod12v12_weapon_drop.sp 的 netprop + 隐形假模型代理方案，但那份文件没有被修改）：
 *   · 每把生成在安全区的 weapon_melee：生成后下一帧写 5 个发光 netprop
 *     （m_iGlowType=3 常亮型 / m_nGlowRange / m_nGlowRangeMin / m_glowColorOverride / m_bFlashing=1），
 *     并额外挂一个 prop_dynamic_override 隐形代理（复制武器自己的 m_ModelName，
 *     本体 alpha=0，只留轮廓）。两条路互为双保险：本仓库实机结论是「只写武器实体属性
 *     不一定会被渲染出轮廓」，所以代理是主力。
 *   · 检测「有生还者离开安全区」：引擎事件 player_left_start_area（userid），
 *     外加语义更宽的 player_left_safe_area（同字段），两个共用一个处理器。
 *     一旦发生：立刻把全部发光撤掉（武器实体属性 + 代理实体一起清），并且本回合不再加。
 *   · 清理时机：有人离开安全区、round_end、换图、插件卸载，外加 2 秒一次的低频巡检
 *     （只在真的亮过之后才存在）兜底 —— 近战武器被捡走/销毁后，代理最多多留 2 秒。
 *   · 开关：l4d2_mitsr_glow（默认 1，=0 时一个 netprop 都不写、一个实体都不建）、
 *     l4d2_mitsr_glow_range（默认 800 HU，0=无限距离）。
 *   · 误发防护：换图/读图/出生点重定位时 player_left_start_area 可能乱发（本仓库 hdf.sp 踩过），
 *     这里用「回合开始后 2 秒内的事件一律不采信」挡住。
 */

#define VERSION "3.2.0"

ArrayList
	g_aMeleeScripts;

ConVar
	g_hEnabled,
	g_hSpawnType,
	g_hRandomAmount,
	g_hMapBaseAmount,
	g_hMeleeItems[14],
	g_hGlow,            // 3.2.0：安全区近战武器闪烁发光开关
	g_hGlowRange;       // 3.2.0：轮廓可见距离（HU）

int
	g_iRoundStart,
	g_iPlayerSpawn;

static const char 
	g_sMeleeModels[][] =
	{
		"models/weapons/melee/v_fireaxe.mdl",
		"models/weapons/melee/w_fireaxe.mdl",
		"models/weapons/melee/v_frying_pan.mdl",
		"models/weapons/melee/w_frying_pan.mdl",
		"models/weapons/melee/v_machete.mdl",
		"models/weapons/melee/w_machete.mdl",
		"models/weapons/melee/v_bat.mdl",
		"models/weapons/melee/w_bat.mdl",
		"models/weapons/melee/v_crowbar.mdl",
		"models/weapons/melee/w_crowbar.mdl",
		"models/weapons/melee/v_cricket_bat.mdl",
		"models/weapons/melee/w_cricket_bat.mdl",
		"models/weapons/melee/v_tonfa.mdl",
		"models/weapons/melee/w_tonfa.mdl",
		"models/weapons/melee/v_katana.mdl",
		"models/weapons/melee/w_katana.mdl",
		"models/weapons/melee/v_electric_guitar.mdl",
		"models/weapons/melee/w_electric_guitar.mdl",
		"models/v_models/v_knife_t.mdl",
		"models/w_models/weapons/w_knife_t.mdl",
		"models/weapons/melee/v_golfclub.mdl",
		"models/weapons/melee/w_golfclub.mdl",
		"models/weapons/melee/v_shovel.mdl",
		"models/weapons/melee/w_shovel.mdl",
		"models/weapons/melee/v_pitchfork.mdl",
		"models/weapons/melee/w_pitchfork.mdl",
		"models/weapons/melee/v_riotshield.mdl",
		"models/weapons/melee/w_riotshield.mdl"
	},
	g_sMeleeName[][] =
	{
		"fireaxe",			//斧头
		"frying_pan",		//平底锅
		"machete",			//砍刀
		"baseball_bat",		//棒球棒
		"crowbar",			//撬棍
		"cricket_bat",		//球拍
		"tonfa",			//警棍
		"katana",			//武士刀
		"electric_guitar",	//吉他
		"knife",			//小刀
		"golfclub",			//高尔夫球棍
		"shovel",			//铁铲
		"pitchfork",		//草叉
		"riotshield",		//盾牌
	};

// ===========================================================================
//  3.2.0 发光轮廓（安全区近战武器，闪烁；生还者离开安全区后停）
// ===========================================================================
// L4D2 发光类型枚举（left4dhooks_stocks.inc:106-112：None=0 / OnUse=1 / OnLookAt=2 / Constant=3）。
// 这里直接写字面量，不依赖任何第三方 include。
#define GLOW_TYPE_NONE      0
#define GLOW_TYPE_CONSTANT  3

#define GLOW_MODEL_LEN      PLATFORM_MAX_PATH   // 武器世界模型名长度
// 代理实体的 targetname：换图/兜底清扫时用来认领「自己留下的」代理，不会误杀别的插件的同类实体
#define GLOW_PROXY_TARGETNAME "mitsr_glowproxy"

// 误发窗口：回合开始后这么多秒内的 player_left_start_area 一律不采信
// （换图 / 读图 / 出生点重定位时引擎可能乱发，本仓库 hdf.sp 踩过这个坑）
#define LEFT_SAFEAREA_GRACE 2.0

// 宿主（weapon_melee）与它的发光代理，三个列表严格同长度同下标，一起 Push / 一起 Erase。
// 存 EntRef 而不是裸索引：实体索引会被复用，直接存索引会误杀别人的实体。
// g_aGlowTried 记录「这个宿主有没有尝试建过代理」，避免模型名一直读不到时无限刷实体。
ArrayList g_aGlowHosts;
ArrayList g_aGlowProxies;
ArrayList g_aGlowTried;

// 待发光的宿主（生成武器的当帧只登记，下一帧再统一处理：
// 武器实体在 DispatchSpawn 的同一帧里模型名/坐标还没落定）
ArrayList g_aGlowPending;
bool      g_bGlowPendingFrame;

// 有人离开安全区之后置 true，保持到本回合结束：此刻起不再给任何近战武器加发光
bool  g_bGlowLeftSafeArea;
// 回合开始时刻（GetGameTime 口径），0 = 本回合还没开始
float g_fGlowRoundStartAt;

Handle g_hGlowSweep;    // 2 秒一次的兜底巡检，只在真的亮过之后才存在

public Plugin myinfo =
{
	name = "Melee In The Saferoom",
	author = "$atanic $pirit, N3wton, apples1949",
	description = "Spawns a selection of melee weapons in the saferoom, at the start of each round.",
	version = VERSION
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    if(GetEngineVersion() != Engine_Left4Dead2)
    {
        strcopy(error, err_max, "Melee in the Saferoom only supports Left 4 Dead 2.");
        return APLRes_SilentFailure;
    }
    return APLRes_Success;
}

public void OnPluginStart()
{
	g_aMeleeScripts = new ArrayList(64);

	CreateConVar("l4d2_mitsr_version", VERSION, "The version of Melee In The Saferoom"); 
	g_hEnabled = CreateConVar("l4d2_mitsr_enabled", "1", "是否启用插件", _, true, 0.0, true, 1.0);
	g_hSpawnType = CreateConVar("l4d2_mitsr_spawn_type", "1", "0 = 自定义生成, 1 = 随机近战武器 2 = 基于地图设定的近战武器", _, true, 0.0, true, 2.0);
	g_hRandomAmount	= CreateConVar("l4d2_mitsr_random_amount", "12","如果l4d2_mitsr_spawn_type为1，则随机在安全区生成多少近战武器（12v12 默认 12 把）", _, true, 0.0, true, 32.0);
	g_hMapBaseAmount = CreateConVar("l4d2_mitsr_mapbase_amount", "4", "如果l4d2_mitsr_spawn_type为2，则在安全区生成多少近战武器", _, true, 0.0, true, 32.0);
		
	g_hMeleeItems[0] = CreateConVar("l4d2_mitsr_fireaxe", "1", "安全区生成多少斧头(l4d2_mitsr_spawn_type必须为0)", _, true, 0.0, true, 10.0);
	g_hMeleeItems[1] = CreateConVar("l4d2_mitsr_fryingpan", "1", "安全区生成多少平底锅(l4d2_mitsr_spawn_type必须为0)", _, true, 0.0, true, 10.0);
	g_hMeleeItems[2] = CreateConVar("l4d2_mitsr_machete", "1", "安全区生成多少砍刀(l4d2_mitsr_spawn_type必须为0)", _, true, 0.0, true, 10.0);
	g_hMeleeItems[3] = CreateConVar("l4d2_mitsr_baseballbat", "1", "安全区生成多少棒球棒(l4d2_mitsr_spawn_type必须为0)", _, true, 0.0, true, 10.0);
	g_hMeleeItems[4] = CreateConVar("l4d2_mitsr_crowbar", "1", "安全区生成多少撬棍(l4d2_mitsr_spawn_type必须为0)", _, true, 0.0, true, 10.0);
	g_hMeleeItems[5] = CreateConVar("l4d2_mitsr_cricketbat", "1", "安全区生成多少球拍(l4d2_mitsr_spawn_type必须为0)", _, true, 0.0, true, 10.0);
	g_hMeleeItems[6] = CreateConVar("l4d2_mitsr_tonfa", "1", "安全区生成多少警棍(l4d2_mitsr_spawn_type必须为0)", _, true, 0.0, true, 10.0);
	g_hMeleeItems[7] = CreateConVar("l4d2_mitsr_katana", "1", "安全区生成多少武士刀(l4d2_mitsr_spawn_type必须为0)", _, true, 0.0, true, 10.0);
	g_hMeleeItems[8] = CreateConVar("l4d2_mitsr_elecguitar", "1", "安全区生成多少吉他(l4d2_mitsr_spawn_type必须为0)", _, true, 0.0, true, 10.0);
	g_hMeleeItems[9] = CreateConVar("l4d2_mitsr_knife", "1", "安全区生成多少小刀(l4d2_mitsr_spawn_type必须为0)", _, true, 0.0, true, 10.0);
	g_hMeleeItems[10] = CreateConVar("l4d2_mitsr_golfclub", "1", "安全区生成多少高尔夫球棍(l4d2_mitsr_spawn_type必须为0)", _, true, 0.0, true, 10.0);
	g_hMeleeItems[11] = CreateConVar("l4d2_mitsr_shovel", "1", "安全区生成多少铁铲(l4d2_mitsr_spawn_type必须为0)", _, true, 0.0, true, 10.0);
	g_hMeleeItems[12] = CreateConVar("l4d2_mitsr_pitchfork", "1", "安全区生成多少草叉(l4d2_mitsr_spawn_type必须为0)", _, true, 0.0, true, 10.0);
	g_hMeleeItems[13] = CreateConVar("l4d2_mitsr_riotshield", "1", "安全区生成多少盾牌(l4d2_mitsr_spawn_type必须为0)", _, true, 0.0, true, 10.0);
	
	// 按需求：不生成 cfg（不再用 AutoExecConfig），参数统一由模式配置 confogl_addcvar 指定
	
	// ---- 3.2.0 发光轮廓：安全区近战武器闪烁发光 ----
	g_hGlow = CreateConVar("l4d2_mitsr_glow", "1",
		"1=生还者离开安全区之前, 给安全屋里生成的近战武器加闪烁发光轮廓(有生还者离开安全区就立刻全部关掉, 并且本回合不再加). 0=完全不发光",
		_, true, 0.0, true, 1.0);
	g_hGlowRange = CreateConVar("l4d2_mitsr_glow_range", "800",
		"发光轮廓的可见距离(HU). 0=无限距离", _, true, 0.0, true, 10000.0);

	g_aGlowHosts = new ArrayList();
	g_aGlowProxies = new ArrayList();
	g_aGlowTried = new ArrayList();
	g_aGlowPending = new ArrayList();

	HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_PostNoCopy);
	HookEvent("player_left_start_area", Event_PlayerLeftStartArea, EventHookMode_PostNoCopy);
	// 语义更宽的「离开安全区域」事件，字段同样有 userid；两个事件共用一个处理器，
	// g_bGlowLeftSafeArea 只允许置一次，重复触发无副作用（本仓库 hdf.sp 也是成对订阅的）。
	HookEvent("player_left_safe_area", Event_PlayerLeftStartArea, EventHookMode_PostNoCopy);

	RegAdminCmd("sm_melee",	cmdMelee, ADMFLAG_KICK, "列出当前战役中可产生的所有近战武器"); 
}

// 3.2.0：插件被卸载（sm plugins unload / reload）时必须把代理实体收掉。
// 卸载后我们的回调全部消失，留下的隐形代理就再也没人管，会一直亮到换图为止。
public void OnPluginEnd()
{
	vGlowClear();
}

Action cmdMelee(int client, int args)
{	
	if(g_iRoundStart == 0 || g_iPlayerSpawn == 0)
		ReplyToCommand(client, "地图尚未开始");
	else
	{
		ReplyToCommand(client, "当前地图已解锁近战:");

		char sScriptName[64];
		int iLength = g_aMeleeScripts.Length;
		for(int i; i < iLength; i++)
		{
			g_aMeleeScripts.GetString(i, sScriptName, sizeof sScriptName);
			ReplyToCommand(client, "%d : %s", i, sScriptName);
		}
	}

	return Plugin_Handled;
}

public void OnMapStart()
{
	int i;
	int iLength = sizeof g_sMeleeModels;
	for(; i < iLength; i++)
	{
		if(!IsModelPrecached(g_sMeleeModels[i]))
			PrecacheModel(g_sMeleeModels[i], true);
	}

	iLength = sizeof g_sMeleeName;
	char sBuffer[64];
	for(i = 0; i < iLength; i++)
	{
		FormatEx(sBuffer, sizeof sBuffer, "scripts/melee/%s.txt", g_sMeleeName[i]);
		if(!IsGenericPrecached(sBuffer))
			PrecacheGeneric(sBuffer, true);
	}
	
	vGetMeleeWeaponsStringTable();
}

void vGetMeleeWeaponsStringTable()
{
	g_aMeleeScripts.Clear();

	int iTable = FindStringTable("meleeweapons");
	if(iTable != INVALID_STRING_TABLE)
	{
		int iNum = GetStringTableNumStrings(iTable);
		char sMeleeName[64];
		for(int i; i < iNum; i++)
		{
			ReadStringTable(iTable, i, sMeleeName, sizeof sMeleeName);
			g_aMeleeScripts.PushString(sMeleeName);
		}
	}
}

public void OnMapEnd()
{
	g_iRoundStart = 0;
	g_iPlayerSpawn = 0;

	// 3.2.0：换图前把发光全部撤掉，并清掉「已离开安全区 / 回合开始时刻」的状态
	vGlowClear();
	g_bGlowLeftSafeArea = false;
	g_fGlowRoundStartAt = 0.0;
}

void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	OnMapEnd();
}

void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	if(g_iRoundStart == 1 && g_iPlayerSpawn == 0)
		CreateTimer(1.0, tmrStartSpawnMelee, _, TIMER_FLAG_NO_MAPCHANGE);
	g_iPlayerSpawn = 1;
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	if(g_iRoundStart == 0 && g_iPlayerSpawn == 1)
		CreateTimer(1.0, tmrStartSpawnMelee, _, TIMER_FLAG_NO_MAPCHANGE);
	g_iRoundStart = 1;

	// 3.2.0：新回合重新允许发光；记下开始时刻用于挡误发的 player_left_start_area
	g_bGlowLeftSafeArea = false;
	g_fGlowRoundStartAt = GetGameTime();
}

/**
 * 3.2.0 需求：生还者离开安全区域「之后」就不该再发光了。
 * 一旦有人离开：立刻撤掉全部发光（武器实体属性 + 假模型代理），并且本回合不再加。
 *
 * 用引擎事件 player_left_start_area（字段 userid，见 l4d2-events.txt:624-628）：
 * 它就是「某个玩家离开了出生/开局安全区」，与需求完全对应，而且不引入任何第三方依赖。
 */
void Event_PlayerLeftStartArea(Event event, const char[] name, bool dontBroadcast)
{
	if(!g_hGlow.BoolValue || g_bGlowLeftSafeArea)
		return;

	// 本回合还没开始（回合开始时刻未知）→ 不采信
	if(g_fGlowRoundStartAt <= 0.0)
		return;

	// 误发防护：换图 / 读图 / 出生点重定位时引擎可能乱发这个事件
	if(GetGameTime() - g_fGlowRoundStartAt < LEFT_SAFEAREA_GRACE)
		return;

	int client = GetClientOfUserId(event.GetInt("userid"));
	if(client <= 0 || !IsClientInGame(client) || GetClientTeam(client) != 2)
		return;

	g_bGlowLeftSafeArea = true;
	vGlowClear();
}

Action tmrStartSpawnMelee(Handle timer)
{
	vStartSpawnMelee();
	return Plugin_Continue;
}

void vStartSpawnMelee()
{
	if(!g_hEnabled.BoolValue) 
		return;

	int client = ivGetInGameClient();
	if(!client)
		return;

	int iLimit;
	float vOrigin[3]; 
	float vAngles[3];
	GetClientAbsOrigin(client, vOrigin);

	vOrigin[2] += 20.0;
	vAngles[0] = 90.0;

	int iLength = g_aMeleeScripts.Length;
	if(g_hSpawnType.IntValue == 1)
	{
		static ArrayList aRandomMelee;

		if(bIsGameInFirstHalf())
		{
			if(aRandomMelee != null)
				delete aRandomMelee;

			aRandomMelee = g_aMeleeScripts.Clone();
			aRandomMelee.Sort(Sort_Random, Sort_String);
		}

		/* 下半场/同图重开时 aRandomMelee 是第一半场留下的克隆，
		   而 g_aMeleeScripts 已在 OnMapStart 里按本图的 meleeweapons 字符串表重建 ——
		   换图后两者长度可以不同（原来拿 g_aMeleeScripts 的长度去索引克隆表，
		   会抛 "Invalid index 6 (count: 6)"）。
		   下半场如果克隆表还没建（插件晚加载、直接从下半场开始），就用本图列表补建一次。 */
		if(aRandomMelee == null)
		{
			aRandomMelee = g_aMeleeScripts.Clone();
			aRandomMelee.Sort(Sort_Random, Sort_String);
		}

		int iRandomLength = aRandomMelee.Length;
		if(iRandomLength < 1)
			return;	// 本图没有可用的近战武器脚本，直接放弃

		char sScriptName[64];
		iLimit = g_hRandomAmount.IntValue;
		for(int i; i < iLimit; i++)
		{
			aRandomMelee.GetString(i < iRandomLength ? i : GetRandomInt(0, iRandomLength - 1), sScriptName, sizeof sScriptName);
			vSpawnMelee(sScriptName, vOrigin, vAngles);
		}
	}
	else if(g_hSpawnType.IntValue == 2)
	{
		if(iLength < 1)
			return;	// 空列表时下面的取模会除零

		char sScriptName[64];
		iLimit = g_hMapBaseAmount.IntValue;
		for(int i; i < iLimit; i++)
		{
			g_aMeleeScripts.GetString(i < iLength ? i : i - (RoundToFloor(float(i / iLength)) * iLength), sScriptName, sizeof sScriptName);
			vSpawnMelee(sScriptName, vOrigin, vAngles);
		}
	}
	else
		vSpawnCustomList(vOrigin, vAngles);
}

void vSpawnMelee(const char[] sClass, const float vPos[3], const float vAng[3])
{
	float vOrigin[3];
	float vAngles[3];
	vOrigin = vPos;
	vAngles = vAng;
	
	vOrigin[0] += (-10.0 + GetRandomFloat(0.0, 20.0));
	vOrigin[1] += (-10.0 + GetRandomFloat(0.0, 20.0));
	vOrigin[2] += GetRandomFloat(0.0, 10.0);
	vAngles[1] = GetRandomFloat(0.0, 360.0);

	int entity = CreateEntityByName("weapon_melee");
	DispatchKeyValue(entity, "solid", "6");
	DispatchKeyValue(entity, "melee_script_name", sClass);
	DispatchSpawn(entity);
	TeleportEntity(entity, vOrigin, vAngles, NULL_VECTOR);

	// 3.2.0：登记发光（下一帧再真正写属性/建代理，见 vGlowQueue 的注释）
	vGlowQueue(entity);

	//SetEntityMoveType(entity, MOVETYPE_NONE);
}

void vSpawnCustomList(const float vPos[3], const float vAng[3])
{
	if(g_aMeleeScripts.Length < 1)
		return;	// 空列表时 GetRandomInt(0, -1) 会出错

	char sScriptName[64];
	int iLength = sizeof g_hMeleeItems;
	for(int x; x < iLength; x++)
	{
		for(int i; i < g_hMeleeItems[x].IntValue; i++)
		{
			if(g_aMeleeScripts.FindString(g_sMeleeName[x]) != -1)
				strcopy(sScriptName, sizeof sScriptName, g_sMeleeName[x]);
			else
				g_aMeleeScripts.GetString(GetRandomInt(0, g_aMeleeScripts.Length - 1), sScriptName, sizeof sScriptName);
	
			vSpawnMelee(sScriptName, vPos, vAng);
		}
	}
}

int ivGetInGameClient()
{
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i))
			return i;
	}
	return 0;
}

bool bIsGameInFirstHalf()
{
	return GameRules_GetProp("m_bInSecondHalfOfRound") ? false : true;
}

// ===========================================================================
//  3.2.0 发光轮廓实现（安全区近战武器闪烁发光；生还者离开安全区后停）
// ===========================================================================

// 把 5 个发光 netprop 写到一个实体上（顺序照抄 applemod12v12_weapon_drop.sp：
// 先写属性 → StartGlowing → 再幂等重写一遍，防止 StartGlowing 内部按 glowstate 覆盖）。
// 返回 false = 这个实体连 m_iGlowType 都没有。
// 每个属性都先 HasEntProp 守卫：不是所有 netclass 都带齐 m_Glow 子表，
// 对不存在的属性 SetEntProp 会抛 "Property not found"。
bool bGlowWriteProps(int iEntity, int iRange, bool bFlashing)
{
	if(iEntity <= 0 || !IsValidEntity(iEntity))
		return false;

	if(!HasEntProp(iEntity, Prop_Send, "m_iGlowType"))
		return false;

	SetEntProp(iEntity, Prop_Send, "m_iGlowType", GLOW_TYPE_CONSTANT);

	if(HasEntProp(iEntity, Prop_Send, "m_nGlowRange"))
		SetEntProp(iEntity, Prop_Send, "m_nGlowRange", iRange);

	if(HasEntProp(iEntity, Prop_Send, "m_nGlowRangeMin"))
		SetEntProp(iEntity, Prop_Send, "m_nGlowRangeMin", 0);

	if(HasEntProp(iEntity, Prop_Send, "m_glowColorOverride"))
		SetEntProp(iEntity, Prop_Send, "m_glowColorOverride", 0);   // 0 = 用游戏默认发光颜色

	// m_bFlashing 是 1 bit 属性，写 int 0/1
	if(HasEntProp(iEntity, Prop_Send, "m_bFlashing"))
		SetEntProp(iEntity, Prop_Send, "m_bFlashing", bFlashing ? 1 : 0);

	// StartGlowing 只存在于 prop_dynamic / prop_dynamic_override 这类实体。
	// 对没有该 input 的实体（例如 weapon_melee）引擎会直接忽略，不报错、也不清掉属性
	AcceptEntityInput(iEntity, "StartGlowing");

	// 再写第二遍（幂等重写）
	SetEntProp(iEntity, Prop_Send, "m_iGlowType", GLOW_TYPE_CONSTANT);

	if(HasEntProp(iEntity, Prop_Send, "m_nGlowRange"))
		SetEntProp(iEntity, Prop_Send, "m_nGlowRange", iRange);

	if(HasEntProp(iEntity, Prop_Send, "m_nGlowRangeMin"))
		SetEntProp(iEntity, Prop_Send, "m_nGlowRangeMin", 0);

	if(HasEntProp(iEntity, Prop_Send, "m_glowColorOverride"))
		SetEntProp(iEntity, Prop_Send, "m_glowColorOverride", 0);

	if(HasEntProp(iEntity, Prop_Send, "m_bFlashing"))
		SetEntProp(iEntity, Prop_Send, "m_bFlashing", bFlashing ? 1 : 0);

	return true;
}

// 撤掉一个实体上的发光：只动发光相关的 netprop，绝不碰实体本身
void vGlowClearProps(int iEntity)
{
	if(iEntity <= 0 || !IsValidEntity(iEntity))
		return;

	if(!HasEntProp(iEntity, Prop_Send, "m_iGlowType"))
		return;

	AcceptEntityInput(iEntity, "StopGlowing");

	if(HasEntProp(iEntity, Prop_Send, "m_bFlashing"))
		SetEntProp(iEntity, Prop_Send, "m_bFlashing", 0);
	if(HasEntProp(iEntity, Prop_Send, "m_glowColorOverride"))
		SetEntProp(iEntity, Prop_Send, "m_glowColorOverride", 0);
	if(HasEntProp(iEntity, Prop_Send, "m_nGlowRange"))
		SetEntProp(iEntity, Prop_Send, "m_nGlowRange", 0);
	if(HasEntProp(iEntity, Prop_Send, "m_nGlowRangeMin"))
		SetEntProp(iEntity, Prop_Send, "m_nGlowRangeMin", 0);

	SetEntProp(iEntity, Prop_Send, "m_iGlowType", GLOW_TYPE_NONE);
}

/**
 * 造一个隐形假模型代理：复制宿主武器自己的 m_ModelName，摆在同一坐标，
 * 写同样的发光属性，然后把本体渲染成完全透明（alpha=0），只留发光轮廓。
 * 失败返回 0（那一帧武器模型名可能还没落定，由巡检补一次）。
 */
int iCreateGlowProxy(int iHost, int iRange, bool bFlashing)
{
	if(iHost <= 0 || !IsValidEntity(iHost))
		return 0;

	// 模型名直接读宿主实体自己的 m_ModelName，不硬编码模型表。
	// 读到空值 / 不是模型路径时放弃（否则代理会变成 ERROR 模型）。
	char sModel[GLOW_MODEL_LEN];
	if(!HasEntProp(iHost, Prop_Data, "m_ModelName")
		|| GetEntPropString(iHost, Prop_Data, "m_ModelName", sModel, sizeof sModel) <= 1
		|| strncmp(sModel, "models/", 7) != 0)
	{
		return 0;
	}

	// 位置/角度用 datamap 的绝对坐标（m_vecAbsOrigin / m_angAbsRotation），比 m_vecOrigin 可靠
	float vPos[3];
	float vAng[3];
	GetEntPropVector(iHost, Prop_Data, "m_vecAbsOrigin", vPos);
	GetEntPropVector(iHost, Prop_Data, "m_angAbsRotation", vAng);

	int iProxy = CreateEntityByName("prop_dynamic_override");
	if(iProxy == -1)
		return 0;

	DispatchKeyValue(iProxy, "model", sModel);
	DispatchKeyValue(iProxy, "targetname", GLOW_PROXY_TARGETNAME);   // 兜底清扫时认领自己留下的实体
	DispatchKeyValue(iProxy, "disableshadows", "1");
	DispatchKeyValue(iProxy, "solid", "0");

	if(!DispatchSpawn(iProxy))
	{
		AcceptEntityInput(iProxy, "Kill");
		return 0;
	}

	// 直接摆到宿主所在位置：刻意**不**做 SetParent（SetParent 会保留局部坐标，
	// 父实体不在世界原点时轮廓会画到别处）。近战武器生成后不会移动，所以只需摆一次。
	TeleportEntity(iProxy, vPos, vAng, NULL_VECTOR);
	SetEntityMoveType(iProxy, MOVETYPE_NONE);        // 不跟着重力掉下去

	// 不挡子弹 / 不挡路 / 不参与碰撞
	SetEntProp(iProxy, Prop_Send, "m_CollisionGroup", 0);
	SetEntProp(iProxy, Prop_Send, "m_nSolidType", 0);

	if(!bGlowWriteProps(iProxy, iRange, bFlashing))
	{
		// 连 prop_dynamic_override 都没有发光属性：这套平台不支持轮廓，不留下无用实体
		AcceptEntityInput(iProxy, "Kill");
		return 0;
	}

	// 假模型本体必须完全看不见，只留轮廓。
	// 用 RENDER_TRANSCOLOR + alpha=0（而不是 RENDER_NONE）：轮廓走独立的发光渲染通路，
	// 不受本体 alpha 影响（本仓库 l4d2_item_hint.sp 的成熟做法）。
	SetEntityRenderMode(iProxy, RENDER_TRANSCOLOR);
	SetEntityRenderColor(iProxy, 0, 0, 0, 0);

	return iProxy;
}

// 从槽位 i 上摘掉记录；bKillProxy=true 时连代理实体一起删
void vGlowDropSlot(int i, bool bKillProxy)
{
	if(i < 0 || g_aGlowHosts == null || i >= g_aGlowHosts.Length)
		return;

	if(bKillProxy && g_aGlowProxies != null && i < g_aGlowProxies.Length)
	{
		int iProxy = EntRefToEntIndex(g_aGlowProxies.Get(i));
		if(iProxy > 0 && IsValidEntity(iProxy))
			AcceptEntityInput(iProxy, "Kill");
	}

	g_aGlowHosts.Erase(i);

	if(g_aGlowProxies != null && i < g_aGlowProxies.Length)
		g_aGlowProxies.Erase(i);

	if(g_aGlowTried != null && i < g_aGlowTried.Length)
		g_aGlowTried.Erase(i);
}

/**
 * 全量撤掉发光：宿主武器上的发光属性 + 代理实体 + 待处理队列 + 巡检 timer。
 * 有人离开安全区 / round_end / 换图 / 插件卸载都走这里。
 */
void vGlowClear()
{
	if(g_hGlowSweep != null)
	{
		KillTimer(g_hGlowSweep);
		g_hGlowSweep = null;
	}

	if(g_aGlowPending != null)
	{
		g_aGlowPending.Clear();
		g_bGlowPendingFrame = false;
	}

	if(g_aGlowHosts == null)
		return;

	for(int i = g_aGlowHosts.Length - 1; i >= 0; i--)
	{
		int iHost = EntRefToEntIndex(g_aGlowHosts.Get(i));
		if(iHost > 0 && IsValidEntity(iHost))
			vGlowClearProps(iHost);

		vGlowDropSlot(i, true);
	}
}

void vGlowEnsureSweep()
{
	if(g_hGlowSweep != null)
		return;

	g_hGlowSweep = CreateTimer(2.0, Timer_vGlowSweep, _, TIMER_REPEAT);
}

/**
 * 2 秒一次的兜底巡检：
 *   · 宿主武器已经没了（近战武器被捡走就是实体被删）→ 连代理一起收掉；
 *   · 代理没了 → 只清记录；
 *   · 代理一次都没建起来（生成那帧模型名还没落定）→ 只补一次，不无限刷实体。
 */
void vGlowSweep()
{
	if(g_aGlowHosts == null)
		return;

	int iRange = g_hGlowRange.IntValue;

	for(int i = g_aGlowHosts.Length - 1; i >= 0; i--)
	{
		int iHost = EntRefToEntIndex(g_aGlowHosts.Get(i));

		if(iHost <= 0 || !IsValidEntity(iHost))
		{
			vGlowDropSlot(i, true);
			continue;
		}

		int iProxy = EntRefToEntIndex(g_aGlowProxies.Get(i));

		if(g_aGlowProxies.Get(i) != 0 && (iProxy <= 0 || !IsValidEntity(iProxy)))
		{
			g_aGlowProxies.Set(i, 0);
			iProxy = 0;
		}

		if(iProxy > 0)
			continue;

		if(g_aGlowTried.Get(i) != 0)
			continue;

		g_aGlowTried.Set(i, 1);

		int iRetry = iCreateGlowProxy(iHost, iRange, true);
		if(iRetry > 0)
			g_aGlowProxies.Set(i, EntIndexToEntRef(iRetry));
	}
}

public Action Timer_vGlowSweep(Handle timer)
{
	// 运行中把 l4d2_mitsr_glow 改成 0：撤掉现有发光再停表。
	// 先把句柄置 null 再调 vGlowClear()，这样它内部的 KillTimer 不会打到自己。
	if(!g_hGlow.BoolValue)
	{
		g_hGlowSweep = null;
		vGlowClear();
		return Plugin_Stop;
	}

	// 开打（有人离开安全区）之后发光本该已经全清，这里兜一次底
	if(g_bGlowLeftSafeArea)
	{
		g_hGlowSweep = null;
		vGlowClear();
		return Plugin_Stop;
	}

	vGlowSweep();

	if(g_aGlowHosts == null || g_aGlowHosts.Length == 0)
	{
		g_hGlowSweep = null;
		return Plugin_Stop;
	}

	return Plugin_Continue;
}

/**
 * 登记一把刚生成的近战武器，下一帧再加发光。
 * 为什么不在生成的当帧直接写：武器实体在 DispatchSpawn 的同一帧里，
 * 模型索引 / 绝对坐标 / 网络状态还没完全落定，对还没成型的实体写发光属性会白写
 * （applemod12v12_weapon_drop.sp 的注释里记着同一个坑）。
 */
void vGlowQueue(int iHost)
{
	if(!g_hGlow.BoolValue || g_bGlowLeftSafeArea)
		return;

	if(g_aGlowPending == null || iHost <= 0 || !IsValidEntity(iHost))
		return;

	g_aGlowPending.Push(EntIndexToEntRef(iHost));

	if(!g_bGlowPendingFrame)
	{
		g_bGlowPendingFrame = true;
		RequestFrame(Frame_vGlowApplyPending);
	}
}

public void Frame_vGlowApplyPending(any data)
{
	g_bGlowPendingFrame = false;

	if(g_aGlowPending == null)
		return;

	int iCount = g_aGlowPending.Length;
	for(int i; i < iCount; i++)
	{
		int iHost = EntRefToEntIndex(g_aGlowPending.Get(i));
		if(iHost > 0 && IsValidEntity(iHost))
			vGlowApply(iHost);
	}

	g_aGlowPending.Clear();
}

// 给一把近战武器加发光：路径① 直接写武器实体属性，路径② 隐形代理，两条互为双保险
void vGlowApply(int iHost)
{
	// 有人离开安全区之后不再加（此时现存发光已经在那一刻被 vGlowClear 清掉了）
	if(!g_hGlow.BoolValue || g_bGlowLeftSafeArea)
		return;

	if(iHost <= 0 || !IsValidEntity(iHost) || g_aGlowHosts == null)
		return;

	int iRef = EntIndexToEntRef(iHost);

	// 同一把武器重复登记时先摘掉旧记录，避免叠出第二个代理
	for(int i = g_aGlowHosts.Length - 1; i >= 0; i--)
	{
		if(g_aGlowHosts.Get(i) == iRef)
			vGlowDropSlot(i, true);
	}

	int iRange = g_hGlowRange.IntValue;

	bool bDirect = bGlowWriteProps(iHost, iRange, true);
	int iProxy = iCreateGlowProxy(iHost, iRange, true);

	if(!bDirect && iProxy <= 0)
		return;     // 两条路都失败：武器照常生成，只是不亮

	g_aGlowHosts.Push(iRef);
	g_aGlowProxies.Push((iProxy > 0) ? EntIndexToEntRef(iProxy) : 0);
	g_aGlowTried.Push((iProxy > 0) ? 1 : 0);    // 已经建过代理就不再由巡检重试

	vGlowEnsureSweep();
}

