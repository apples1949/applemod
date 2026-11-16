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
 *     （只在真的亮过之后才存在）兜底。
 *   · 3.2.1（2026-11-17）修「轮廓冻在半空 / 捡走近战武器轮廓不消失」：
 *       ① 代理不再只摆一次：生成后 2 秒内 0.1 秒一跳跟着宿主重摆（武器这时正在下落、
 *          翻滚），之后每次 2 秒巡检都按宿主当前 m_vecAbsOrigin/m_angAbsRotation 重摆；
 *          已经对齐（位移 ≤1HU 且角度 ≤1°）时一次 TeleportEntity 都不下发。
 *       ② 捡走判据换成「玩家武器槽里确实有这把武器」（本仓库 applemod12v12_weapon_drop.sp
 *          的可靠做法），再叠加 m_hOwner / m_iState 互相印证。旧版只看实体索引是否有效，
 *          而 L4D2 里近战武器被捡走后实体往往还在（只是变成玩家手上的武器），永远清不掉。
 *       ③ 巡检同时校验 classname + melee_script_name，防实体索引被别的实体复用时误判「还在」。
 *   · 开关：l4d2_mitsr_glow（默认 1，=0 时一个 netprop 都不写、一个实体都不建）、
 *     l4d2_mitsr_glow_range（默认 800 HU，0=无限距离）。
 *   · 误发防护：换图/读图/出生点重定位时 player_left_start_area 可能乱发（本仓库 hdf.sp 踩过），
 *     这里用「回合开始后 2 秒内的事件一律不采信」挡住。
 */

#define VERSION "3.2.1"

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

// 3.2.1 代理跟随：武器生成后会因重力落地、翻滚、被玩家/爆炸推挤而移动，
// 而代理是 MOVETYPE_NONE 的静态实体，必须按宿主当前坐标重摆（旧版只摆一次 → 轮廓冻在半空）。
#define GLOW_ALIGN_INTERVAL 0.1     // 生成后快速对齐 timer 的间隔（秒）
#define GLOW_ALIGN_TICKS    20      // 20 × 0.1 = 生成后 2 秒内跟随，之后交给 2 秒巡检
#define GLOW_MOVE_EPS       1.0     // 宿主相对代理位移超过这么多 HU 才重摆（静止就一次都不写）
#define GLOW_TURN_EPS       1.0     // 角度变化超过这么多度才重摆

// 宿主（weapon_melee）与它的发光代理，四个列表严格同长度同下标，一起 Push / 一起 Erase。
// 存 EntRef 而不是裸索引：实体索引会被复用，直接存索引会误杀别人的实体。
// g_aGlowTried 记录「这个宿主有没有尝试建过代理」，避免模型名一直读不到时无限刷实体。
// g_aGlowScripts 记下宿主的 melee_script_name：EntityRef 只能证明索引/序列没被复用成
// 新实体，再比一次 classname + 脚本名才能证明「还是当初那把近战武器」（见 bGlowHostIsOurs）。
ArrayList g_aGlowHosts;
ArrayList g_aGlowProxies;
ArrayList g_aGlowTried;
ArrayList g_aGlowScripts;

// 3.2.1：巡检时一次性收集「当前被任何玩家拿在身上的武器实体」，槽位判断直接查这份列表，
// 避免每个槽位都去遍历一次 客户端 × 武器槽。
ArrayList g_aGlowHeld;

// 3.2.1：生成后 2 秒内的快速对齐 timer（0.1 秒一跳，跳完自动停），以及剩余跳数
Handle g_hGlowAlign;
int    g_iGlowAlignTicks;

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
	g_aGlowScripts = new ArrayList(64);     // 每格一个 melee_script_name（最长不到 32 字节）
	g_aGlowHeld = new ArrayList();

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

	// 先摆到宿主当前所在位置：刻意**不**做 SetParent（SetParent 会保留局部坐标，
	// 父实体不在世界原点时轮廓会画到别处，同 applemod12v12_weapon_drop.sp:805-809）。
	// 既然不 SetParent，代理就不会自己跟着武器走 —— 武器随后会重力落地、翻滚、
	// 被玩家/爆炸推挤，所以这里摆的只是「初始位置」，之后由 bGlowAlignProxy() 持续对齐
	// （生成后 2 秒内 0.1 秒一跳跟随，之后 2 秒巡检时按需重摆）。
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

	if(g_aGlowScripts != null && i < g_aGlowScripts.Length)
		g_aGlowScripts.Erase(i);
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

	// 3.2.1：快速对齐 timer 一并收掉（它的句柄本身不会自己消失）
	if(g_hGlowAlign != null)
	{
		KillTimer(g_hGlowAlign);
		g_hGlowAlign = null;
	}

	if(g_aGlowHeld != null)
		g_aGlowHeld.Clear();

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
 * 读一把 weapon_melee 的 melee_script_name。
 * 依据：datamap-dump.txt:13398-13399 —— 实体类 CTerrorMeleeWeapon（weapon_melee）的
 * m_strMapSetScriptName（Prop_Data），键名就是创建武器时 DispatchKeyValue 的
 * "melee_script_name"。读不到时返回 0，并把 sOut 置成空串（调用方不要据此判否）。
 */
int iGlowReadScriptName(int iEntity, char[] sOut, int iMaxLen)
{
	sOut[0] = '\0';

	if(iEntity <= MaxClients || !IsValidEntity(iEntity))
		return 0;

	if(!HasEntProp(iEntity, Prop_Data, "m_strMapSetScriptName"))
		return 0;

	return GetEntPropString(iEntity, Prop_Data, "m_strMapSetScriptName", sOut, iMaxLen);
}

/**
 * 槽位上的宿主是不是还是我们当初登记的那把近战武器。
 * 返回 false = 实体索引还在，但已经不是那把武器（被复用 / 换了类）→ 必须收掉代理，
 * 否则轮廓会挂在一把完全不相干的新实体上（「属性名对但实体类型不对」那类坑）。
 *
 * 三重证明：① EntRef 有效（调用方已确认）；② classname 仍是 weapon_melee；
 * ③ melee_script_name 与登记值一致（读不到就不判否，避免不同 netclass 下误杀）。
 */
bool bGlowHostIsOurs(int iSlot, int iHost)
{
	char sClass[32];
	if(GetEntityClassname(iHost, sClass, sizeof sClass) && !StrEqual(sClass, "weapon_melee", false))
		return false;

	if(g_aGlowScripts == null || iSlot < 0 || iSlot >= g_aGlowScripts.Length)
		return true;

	char sWant[64];
	if(g_aGlowScripts.GetString(iSlot, sWant, sizeof sWant) <= 0)
		return true;	// 当初就没读到脚本名：只靠 EntRef + classname 判定

	char sNow[64];
	if(iGlowReadScriptName(iHost, sNow, sizeof sNow) <= 0)
		return true;	// 现在读不到了：不据此判否

	return StrEqual(sWant, sNow, false);
}

/**
 * 一次性把「当前被任何玩家（含 bot）拿在身上的武器实体」收进 g_aGlowHeld。
 * 做法照抄本仓库 applemod12v12_weapon_drop.sp:938-957：世界上的可拾取武器
 * m_hOwnerEntity 不一定是 -1（引擎行为不稳定），按玩家武器槽查才是可靠判据；
 * bot 也会自动捡枪，所以不能跳过 bot。每轮巡检只扫一遍（客户端 × 5 个武器槽）。
 */
void vGlowCollectHeld()
{
	if(g_aGlowHeld == null)
		return;

	g_aGlowHeld.Clear();

	for(int i = 1; i <= MaxClients; i++)
	{
		if(!IsClientInGame(i))
			continue;

		for(int slot; slot <= 4; slot++)
		{
			int iWeapon = GetPlayerWeaponSlot(i, slot);
			if(iWeapon > MaxClients && IsValidEntity(iWeapon))
				g_aGlowHeld.Push(iWeapon);
		}
	}
}

/**
 * 宿主近战武器是否已经被玩家捡走（拿在身上）。
 *
 * 为什么不能只看「实体还有效」：L4D2 里近战武器被捡起时实体**往往不会被删除**，
 * 而是直接变成玩家手上的那把武器。旧版 vGlowSweep 只判 EntRef + IsValidEntity，
 * 所以这种「捡走但实体还在」的情况永远检测不到，代理就一直留在安全屋地上 ——
 * 用户反馈的「拾取近战不一定会消除对应的武器轮廓」。
 *
 * 判据（bFull=true 的 2 秒巡检才用）：权威判据只有一条 —— 这把武器此刻在不在
 * 某个玩家（含 bot）的武器槽里（vGlowCollectHeld 每轮巡检收一次，做法照抄
 * applemod12v12_weapon_drop.sp 的可靠实现）。不拿 m_hOwner / m_iState 这类
 * netprop 去猜：赌错的方向是"把地上的武器当成被捡走"，代价是开局一把轮廓都不亮。
 *
 * bFull=false（生成后 2 秒的快速对齐 timer）不做捡走判断，只摆正代理。
 */
bool bGlowHostCarried(int iHost, bool bFull)
{
	/* 只有 2 秒巡检才做"真的摘轮廓"的判断，而且只认一个权威判据：
	   这把武器此刻是否出现在某个玩家的武器槽里（vGlowCollectHeld 每轮巡检收一次）。
	   生成后 2 秒内的快速对齐只负责把代理摆正，**绝不**在这里摘轮廓 ——
	   旧实现（3.2.1 初版）在快速窗口里还叠加了 m_hOwner / m_iState 两次 netprop 读，
	   万一某套引擎对"扔在地上的武器"没有把这两个值清干净，开局就会一把轮廓都不亮。
	   捡走的轮廓最晚多留 2 秒（巡检周期），换掉这个风险是值得的。 */
	if (!bFull)
		return false;

	if (g_aGlowHeld == null)
		return false;

	return g_aGlowHeld.FindValue(iHost) != -1;
}

/**
 * 读一个实体的世界坐标 + 朝向。
 * 优先 datamap 的绝对坐标 m_vecAbsOrigin / m_angAbsRotation（datamap-dump.txt:98/107），
 * 取不到就退回 netprop 的 m_vecOrigin / m_angRotation（DT_BaseEntity，netprop-dump.txt:12/44）。
 * 停在安全屋地上的近战武器与它的代理都没有父实体，两种取法结果等价；
 * 但只要有可用路径就能摆正，不会因为某个属性在这套引擎上查不到就整条对齐链失效。
 */
bool bGlowReadPosAng(int iEntity, float vPos[3], float vAng[3])
{
	if(HasEntProp(iEntity, Prop_Data, "m_vecAbsOrigin") && HasEntProp(iEntity, Prop_Data, "m_angAbsRotation"))
	{
		GetEntPropVector(iEntity, Prop_Data, "m_vecAbsOrigin", vPos);
		GetEntPropVector(iEntity, Prop_Data, "m_angAbsRotation", vAng);
		return true;
	}

	if(HasEntProp(iEntity, Prop_Send, "m_vecOrigin") && HasEntProp(iEntity, Prop_Send, "m_angRotation"))
	{
		GetEntPropVector(iEntity, Prop_Send, "m_vecOrigin", vPos);
		GetEntPropVector(iEntity, Prop_Send, "m_angRotation", vAng);
		return true;
	}

	return false;
}

/**
 * 把代理摆到宿主当前的绝对坐标/角度（3.2.1 的核心修复）。
 *
 * 代理是 MOVETYPE_NONE 的静态实体，不会跟着武器走；而武器生成后会重力落地、翻滚、
 * 被玩家或爆炸推挤。旧版只在创建时摆一次（注释还写着「近战武器生成后不会移动」），
 * 于是武器掉到地上、轮廓还冻在半空 —— 就是用户截图里的现象。
 *
 * 省开销判断：宿主相对代理的位移 ≤ GLOW_MOVE_EPS 且角度变化 ≤ GLOW_TURN_EPS 时，
 * 这里一次 TeleportEntity 都不下发（武器静止之后每一跳都是纯读，没有网络写入）。
 *
 * 返回 true = 这一跳真的摆了。
 */
bool bGlowAlignProxy(int iHost, int iProxy)
{
	float vHostPos[3], vHostAng[3], vProxyPos[3], vProxyAng[3];

	if(!bGlowReadPosAng(iHost, vHostPos, vHostAng) || !bGlowReadPosAng(iProxy, vProxyPos, vProxyAng))
		return false;

	if(GetVectorDistance(vHostPos, vProxyPos) <= GLOW_MOVE_EPS
		&& GetVectorDistance(vHostAng, vProxyAng) <= GLOW_TURN_EPS)
	{
		return false;	// 已经对齐 / 武器已静止：不白摆
	}

	TeleportEntity(iProxy, vHostPos, vHostAng, NULL_VECTOR);
	return true;
}

/**
 * 巡检/对齐共用的单槽处理。返回 false = 这个槽位已被摘掉
 * （调用方倒着遍历，继续处理 i-1 即可）。
 *
 * bFull=true  → 2 秒巡检：查玩家武器槽（权威）、允许补建一次代理；
 * bFull=false → 生成后 2 秒内的快速对齐：只做廉价检查 + 跟随重摆。
 */
bool bGlowServiceSlot(int i, bool bFull)
{
	// 防御：四个列表按设计严格同长度同下标，万一被外部改乱（后期维护手误）就直接摘掉这个槽位，
	// 绝不让 .Get() 抛 "Invalid index" 把插件打成半死状态。
	if(g_aGlowProxies == null || i >= g_aGlowProxies.Length
		|| g_aGlowTried == null || i >= g_aGlowTried.Length)
	{
		vGlowDropSlot(i, true);
		return false;
	}

	int iHost = EntRefToEntIndex(g_aGlowHosts.Get(i));

	// ① 宿主实体真的没了（武器被删除 / 换图）→ 连代理一起收
	if(iHost <= 0 || !IsValidEntity(iHost))
	{
		vGlowDropSlot(i, true);
		return false;
	}

	// ② 索引还在，但已经不是我们登记的那把近战武器 → 同样收掉，避免轮廓挂到别的实体上
	if(!bGlowHostIsOurs(i, iHost))
	{
		vGlowDropSlot(i, true);
		return false;
	}

	// ③ 被玩家捡走了：先把武器本体上的发光撤掉（拿在手里的武器不该继续发光），再收代理
	if(bGlowHostCarried(iHost, bFull))
	{
		vGlowClearProps(iHost);
		vGlowDropSlot(i, true);
		return false;
	}

	int iProxy = EntRefToEntIndex(g_aGlowProxies.Get(i));

	if(g_aGlowProxies.Get(i) != 0 && (iProxy <= 0 || !IsValidEntity(iProxy)))
	{
		g_aGlowProxies.Set(i, 0);
		iProxy = 0;
	}

	// ④ 代理还在 → 让轮廓跟着武器走（旧版这里直接 continue，正是轮廓冻住的根因）
	if(iProxy > 0)
	{
		bGlowAlignProxy(iHost, iProxy);
		return true;
	}

	if(!bFull || g_aGlowTried.Get(i) != 0)
		return true;

	// ⑤ 代理一次都没建起来（生成那帧模型名还没落定）→ 只补一次，不无限刷实体
	g_aGlowTried.Set(i, 1);

	int iRetry = iCreateGlowProxy(iHost, g_hGlowRange.IntValue, true);
	if(iRetry > 0)
		g_aGlowProxies.Set(i, EntIndexToEntRef(iRetry));

	return true;
}

/**
 * 2 秒一次的兜底巡检：
 *   · 宿主武器没了 / 已经不是那把近战武器 / 被玩家捡走 → 连代理一起收掉；
 *   · 代理还在但宿主动了（被推挤、翻滚完）→ 按宿主当前坐标重摆（3.2.1）；
 *   · 代理没了 → 只清记录；
 *   · 代理一次都没建起来 → 只补一次，不无限刷实体。
 */
void vGlowSweep()
{
	if(g_aGlowHosts == null)
		return;

	vGlowCollectHeld();

	for(int i = g_aGlowHosts.Length - 1; i >= 0; i--)
		bGlowServiceSlot(i, true);
}

/**
 * 生成后 2 秒内的快速对齐窗口（3.2.1）。
 * 武器从生成点落地、翻滚、被挤开主要就发生在这一小段时间里，所以要 0.1 秒一跳地跟；
 * 跳完（2 秒）自动停表，之后完全交给 2 秒巡检，不会有任何「每帧」开销。
 * 已经在跑时只续期，不重复建 timer。
 */
void vGlowStartAlign()
{
	g_iGlowAlignTicks = GLOW_ALIGN_TICKS;

	if(g_hGlowAlign != null)
		return;

	g_hGlowAlign = CreateTimer(GLOW_ALIGN_INTERVAL, Timer_vGlowAlign, _, TIMER_REPEAT);
}

public Action Timer_vGlowAlign(Handle timer)
{
	if(timer != g_hGlowAlign)
		return Plugin_Stop;

	if(g_aGlowHosts == null || g_aGlowHosts.Length == 0
		|| !g_hGlow.BoolValue || g_bGlowLeftSafeArea)
	{
		g_hGlowAlign = null;
		return Plugin_Stop;
	}

	// 倒着遍历：bGlowServiceSlot 可能把当前下标摘掉
	for(int i = g_aGlowHosts.Length - 1; i >= 0; i--)
		bGlowServiceSlot(i, false);

	if(--g_iGlowAlignTicks <= 0)
	{
		g_hGlowAlign = null;
		return Plugin_Stop;
	}

	return Plugin_Continue;
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

	// 3.2.1：记下这把武器的 melee_script_name（读不到就是空串，巡检里据此只做 classname 判定）
	char sScript[64];
	iGlowReadScriptName(iHost, sScript, sizeof sScript);
	g_aGlowScripts.PushString(sScript);

	vGlowEnsureSweep();
	vGlowStartAlign();      // 3.2.1：生成后 2 秒内 0.1 秒一跳跟着武器摆正（这段时间正在落地/翻滚）
}

