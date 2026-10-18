/**
 * Applemod 12v12 - 开局丢枪（替代枪柜）
 *
 * 开局（round_start 与 player_spawn 都发生后延迟 N 秒）把指定武器生成在
 * 「任意一名随机生还者脚下」，每个回合一次。
 *
 * 参考实现：
 *   1) Silvers - [L4D2] Melee In The Saferoom (l4d2_melee_in_the_saferoom.sp)
 *      · round_start / player_spawn 双标志 + CreateTimer(N, ...) 的生成时机
 *      · GetClientAbsOrigin() 取脚下坐标 + 随机抖动 + 随机偏航
 *   2) Silvers - [L4D & L4D2] Gun Cabinet (l4d_gun_cabinet.sp) 的 CreateWeapon()
 *      · L4D2 可拾取枪械实体的正确建法：solid 6 / rendermode 3 / disableshadows 1
 *      · TeleportEntity 后再 DispatchSpawn、m_iExtraPrimaryAmmo 给弹药、MOVETYPE_NONE 防滚
 *
 * 注意：
 *   · 生成时间必须晚于框架 (ConfoglCompMod) 在 round_start+0.3s 的武器清理扫描，
 *     所以默认 delay = 1.0 秒；配合 confogl_remove_chainsaw 0，电锯才不会被删。
 *   · 不生成 cfg（不用 AutoExecConfig），全部 cvar 由 confogl 的 12v12 配置下发。
 *
 * 1.1.0 新增：给生成的武器加「闪烁轮廓（glow）」，颜色 / 距离 / 是否闪烁全部可配。
 *   · 首选「武器实体自己发光」：L4D2_SetEntityGlow()（left4dhooks_stocks.inc:708）
 *     内部先 FindSendPropInfo(netclass, "m_iGlowType")，< 1 时返回 false 表示该
 *     netclass 不支持发光。
 *   · netclass 不支持时用「隐形假模型代理」回退，做法照抄本仓库两个先例：
 *     l4d2_item_hint.sp:1075-1125（CreateEntityModelGlow）
 *     l4d_death_item_glow.sp:179-222（CreateGlowEntity）
 *   · glow_enable=0 时，本文件的原有行为（生成时机 / 生成位置 / 弹药 / 日志）不变：
 *     不建代理、不写任何发光属性、不注册任何 SDKHook。
 *   · 详见文件末尾「发光轮廓（glow）」注释块。
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>          // OnEntityDestroyed（SDKHooks 1.12 提供）
#include <left4dhooks>       // L4D2_SetEntityGlow / L4D2Glow_Constant / L4D2Glow_None

#define PLUGIN_VERSION "1.1.0"

ConVar g_hEnable, g_hWeapons, g_hMode, g_hDelay, g_hSpread, g_hDebug;
ConVar g_hAmmoRifle, g_hAmmoChainsaw, g_hAmmoSniper;
ConVar g_hGlowEnable, g_hGlowColor, g_hGlowRange, g_hGlowMinRange, g_hGlowFlashing, g_hGlowProxy;

bool g_bRoundStart, g_bPlayerSpawn, g_bSpawned;

public Plugin myinfo =
{
	name = "Applemod 12v12 Weapon Drop",
	author = "apples1949",
	version = PLUGIN_VERSION,
	description = "12v12 开局把指定武器（默认电锯/SG552/AWP/鸟狙）生成在随机生还者脚下（可加闪烁轮廓）；参考 Silvers 的 Melee In The Saferoom + Gun Cabinet",
	url = "https://github.com/apples1949/applemod"
};

// ---------------------------------------------------------------------------
// 发光轮廓（glow）所需的模块级状态
// ---------------------------------------------------------------------------
// 槽位数：本插件每回合最多生成 sizeof(aWeapons)=16 把武器，所以 16 就够。
// 不按 GetMaxEntities() 开数组 —— 够用且省内存。
#define GLOW_SLOTS     16
#define GLOW_MODEL_LEN PLATFORM_MAX_PATH     // 武器世界模型名长度（PLATFORM_MAX_PATH=256, files.inc:75）
#define GLOW_COLOR_LEN 32                    // "255 200 0" 级别的颜色字符串

// 代理实体的 targetname：换图/回合兜底扫描时用来精确认领「自己留下的」代理，
// 不会误杀别的插件的同类实体（例如 l4d2_item_hint 的 harry_marked_item）。
#define GLOW_PROXY_TARGETNAME "am12v12_wdrop_glowproxy"

// 每个槽位同时记 ref 和 index，两者不能互相替代：
//   · ref（EntIndexToEntRef）用来判断「这个索引是不是还是原来那个实体」，防索引复用误杀；
//   · index 用于 OnEntityDestroyed(entity) 里做直接匹配 —— 该回调是实体正在销毁时触发的，
//     此时对同一个实体做 EntRefToEntIndex 并不可靠，所以不能靠 ref 反查。
int  g_iGlowHostRef[GLOW_SLOTS];             // 武器实体 ref；0 = 空槽
int  g_iGlowHostIdx[GLOW_SLOTS];             // 武器实体 index
int  g_iGlowProxyRef[GLOW_SLOTS];            // 假模型代理 ref；0 = 本槽没有代理（走直接发光）
int  g_iGlowProxyIdx[GLOW_SLOTS];            // 假模型代理 index
bool g_bGlowSlotUsed[GLOW_SLOTS];

int  g_iGlowColor[3];                        // 解析后的 RGB
bool g_bGlowColorOverride;                   // false = 不覆盖颜色（交给游戏默认发光色）
bool g_bGlowColorWarned;                     // 颜色串解析失败时 LogError 只打一次

// native 守卫：Left4DHooks 未加载 / 版本过旧时只 LogError 一次并退化为不发光
bool g_bGlowNativeOk;                        // true = 已确认 Left4DHooks 可用（成功一次就一直记住）
bool g_bGlowNativeWarned;                    // LogError 只打一次

// 是否真的给实体加过发光。false 时所有 glow 清理 / 残留扫描 / 定时器全部零副作用，
// 保证 glow_enable=0 时与 1.0.0 行为逐字节等价。
bool g_bGlowActive;

// 代理存活巡检定时器句柄。只在发光真正生效之后才创建（见 EnsureGlowSweep）：
// OnEntityDestroyed 不保证对每个实体都跑到（l4d_cloud_screen_fade.sp:713 的教训），
// 所以用低频巡检兜底，避免假模型代理变成永久残留。
Handle g_hGlowSweep;

// 客户端是否已挂 SDKHook_WeaponEquipPost（只有真的加过发光后才会挂，
// 见 EnsureClientGlowHooks —— 保证 glow_enable=0 时不注册任何额外 hook）。
bool g_bClientGlowHooked[MAXPLAYERS + 1];    // MAXPLAYERS=101（1.12 include/clients.inc:72）

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	// 守卫说明（重要，别被「MarkNativeAsOptional 保平安」的套路误导）：
	//   L4D2_SetEntityGlow() 本身是 left4dhooks_stocks.inc:708 里的 **stock**，
	//   不是 native —— 它内部只用 sourcemod 自带的 FindSendPropInfo/SetEntProp，
	//   所以 GetFeatureStatus(FeatureType_Native, "L4D2_SetEntityGlow") 永远返回
	//   Unknown，拿它做守卫是错的。
	//   真正可能缺失的是 Left4DHooks 扩展本身（未加载 / 版本太旧不含该 stock），
	//   因此：①登记 Left4DHooks_Version 为 optional native；②运行期用
	//   LibraryExists("left4dhooks") + GetFeatureStatus(FeatureType_Native,
	//   "Left4DHooks_Version") 双重判定（见 CheckGlowSupport()）。
	//   任一不满足 -> 只 LogError 一次并退化为「不发光」，绝不崩服。
	MarkNativeAsOptional("Left4DHooks_Version");

	return APLRes_Success;
}

public void OnPluginStart()
{
	CreateConVar("am12v12_wdrop_version", PLUGIN_VERSION, "开局丢枪插件版本", FCVAR_NOTIFY|FCVAR_DONTRECORD);
	g_hEnable  = CreateConVar("am12v12_wdrop_enable",  "1", "是否启用", _, true, 0.0, true, 1.0);
	g_hWeapons = CreateConVar("am12v12_wdrop_weapons", "weapon_chainsaw,weapon_rifle_sg552,weapon_sniper_awp,weapon_sniper_scout",
							  "开局生成的武器类名，英文逗号分隔（默认：电锯/SG552/AWP/鸟狙）");
	g_hMode    = CreateConVar("am12v12_wdrop_mode",    "0", "0=全部生成在同一名随机生还者脚下；1=每把各挑一名随机生还者", _, true, 0.0, true, 1.0);
	g_hDelay   = CreateConVar("am12v12_wdrop_delay",   "1.0", "回合开始后延迟多少秒生成（要晚于框架 round_start+0.3s 的武器清理）", _, true, 0.0, true, 30.0);
	g_hSpread  = CreateConVar("am12v12_wdrop_spread",  "20.0", "同一位置生成多把武器时的散开半径（避免叠在一起）", _, true, 0.0, true, 200.0);
	g_hDebug   = CreateConVar("am12v12_wdrop_debug",   "0", "1=在服务端控制台打印生成了什么、生成在谁脚下", _, true, 0.0, true, 1.0);

	// ---- 发光轮廓（glow）----
	g_hGlowEnable   = CreateConVar("am12v12_wdrop_glow_enable",    "1",
								   "是否给开局生成的武器加发光轮廓（闪烁）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hGlowColor    = CreateConVar("am12v12_wdrop_glow_color",     "255 200 0",
								   "轮廓颜色 RGB，空格分隔。留空 = 用游戏默认发光颜色", FCVAR_NOTIFY);
	g_hGlowRange    = CreateConVar("am12v12_wdrop_glow_range",     "800",
								   "轮廓可见距离（HU）", FCVAR_NOTIFY, true, 0.0, true, 10000.0);
	g_hGlowMinRange = CreateConVar("am12v12_wdrop_glow_min_range", "0",
								   "轮廓开始显示的最小距离（HU），0=从最近处就显示", FCVAR_NOTIFY, true, 0.0, true, 10000.0);
	g_hGlowFlashing = CreateConVar("am12v12_wdrop_glow_flashing",  "1",
								   "轮廓是否闪烁。0=常亮", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hGlowProxy    = CreateConVar("am12v12_wdrop_glow_proxy",     "0",
								   "发光方式：0=自动（先直接给武器实体发光，不支持再用隐形假模型代理），1=强制用假模型代理，2=只用直接发光（失败就不发光）",
								   FCVAR_NOTIFY, true, 0.0, true, 2.0);

	// 注意：这里**不**注册任何 cvar 变更钩子。
	// 颜色在 ApplyGlowToWeapon() 里按需解析（每次生成武器时读一次当前值），
	// 这样 glow_enable=0 时本插件注册的 event/hook 与 1.0.0 完全一致，
	// 且改 am12v12_wdrop_glow_color 之后下一把生成的武器自动用新颜色。

	// 弹药取游戏自己的 cvar（与枪柜插件同一套），取不到就不写该属性
	g_hAmmoRifle    = FindConVar("ammo_assaultrifle_max");
	g_hAmmoChainsaw = FindConVar("ammo_chainsaw_max");
	g_hAmmoSniper   = FindConVar("ammo_sniperrifle_max");

	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_PostNoCopy);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
}

// 插件被手动卸载（sm plugins unload / reload）时也必须清一遍：
// 卸载后我们的 OnEntityDestroyed / SDKHook 全部消失，若此时还留着代理假模型，
// 它们就再也没人管了 —— 会一直挂在地上发光到换图为止。
// glow 从未生效时 ClearAllGlow() 只有一次定时器判空就返回，无副作用。
public void OnPluginEnd()
{
	ClearAllGlow();
}

public void OnMapEnd()
{
	// 换图前把代理实体和自己的发光全部撤掉：换图时引擎会销毁所有实体，
	// 但 OnEntityDestroyed 不保证对每个实体都跑到（见 l4d_cloud_screen_fade.sp:713 的教训），
	// 所以这里必须主动全量清理 + 扫描残留。
	ClearAllGlow();
	ResetRound();
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	// 上一回合生成、没被捡走的武器可能还留在地上（虽然通常会被框架清掉）。
	// 先全量撤掉旧发光，避免槽位表和实体状态对不上。
	ClearAllGlow();

	g_bRoundStart = true;
	TrySchedule();
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	g_bPlayerSpawn = true;
	TrySchedule();
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	ClearAllGlow();
	ResetRound();
}

void ResetRound()
{
	g_bRoundStart = false;
	g_bPlayerSpawn = false;
	g_bSpawned = false;
}

// round_start 与 player_spawn 都发生后才排定生成（两者顺序在 L4D2 里不固定）
void TrySchedule()
{
	if (g_bSpawned || !g_bRoundStart || !g_bPlayerSpawn)
		return;

	g_bSpawned = true;
	CreateTimer(g_hDelay.FloatValue, Timer_SpawnWeapons, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_SpawnWeapons(Handle timer)
{
	if (!g_hEnable.BoolValue)
		return Plugin_Continue;

	char sList[512];
	g_hWeapons.GetString(sList, sizeof(sList));

	char aWeapons[16][64];
	int iCount = ExplodeString(sList, ",", aWeapons, sizeof(aWeapons), sizeof(aWeapons[]));
	if (iCount <= 0)
		return Plugin_Continue;

	// 清掉空格
	int iValid;
	for (int i = 0; i < iCount; i++)
	{
		TrimString(aWeapons[i]);
		if (aWeapons[i][0] == '\0')
			continue;

		if (i != iValid)
			strcopy(aWeapons[iValid], sizeof(aWeapons[]), aWeapons[i]);
		iValid++;
	}
	if (iValid <= 0)
		return Plugin_Continue;

	int iAnchor = PickRandomSurvivor();
	if (iAnchor <= 0)
	{
		if (g_hDebug.BoolValue)
			PrintToServer("[12v12 wdrop] 没有可用的生还者，跳过本回合生成");
		return Plugin_Continue;
	}

	float fSpread = g_hSpread.FloatValue;
	float vBase[3];
	GetClientAbsOrigin(iAnchor, vBase);

	// 方形散布（最多 4 把按四角摆放；超过 4 把的用随机抖动兜底）
	float fOff[4][2];
	fOff[0][0] = -fSpread; fOff[0][1] = -fSpread;
	fOff[1][0] =  fSpread; fOff[1][1] = -fSpread;
	fOff[2][0] = -fSpread; fOff[2][1] =  fSpread;
	fOff[3][0] =  fSpread; fOff[3][1] =  fSpread;

	for (int i = 0; i < iValid; i++)
	{
		int iTarget = iAnchor;
		if (g_hMode.IntValue == 1)
		{
			int iRand = PickRandomSurvivor();
			if (iRand > 0)
				iTarget = iRand;
		}

		float vPos[3];
		GetClientAbsOrigin(iTarget, vPos);
		vPos[2] += 15.0;                       // 抬到脚下略上方，避免卡进地板

		if (i < 4)
		{
			vPos[0] += fOff[i][0];
			vPos[1] += fOff[i][1];
		}
		else
		{
			vPos[0] += GetRandomFloat(-fSpread, fSpread);
			vPos[1] += GetRandomFloat(-fSpread, fSpread);
		}
		vPos[2] += GetRandomFloat(0.0, 5.0);

		// 返回值 > 0 才说明生成成功；失败时不动发光逻辑
		int iWeapon = SpawnWeapon(aWeapons[i], vPos, iTarget);
		if (iWeapon > 0)
			ApplyGlowToWeapon(iWeapon);
	}

	if (g_hDebug.BoolValue)
		PrintToServer("[12v12 wdrop] 已在 %N 脚下生成 %d 把武器（mode=%d）", iAnchor, iValid, g_hMode.IntValue);

	return Plugin_Continue;
}

// 生成一把武器实体。返回值：> 0 = 实体索引，0 = 失败（调用方据此决定要不要加发光）
int SpawnWeapon(const char[] sClassname, const float vPos[3], int iTarget)
{
	int iEntity = CreateEntityByName(sClassname);
	if (iEntity == -1)
	{
		LogError("[12v12 wdrop] 创建实体失败: %s", sClassname);
		return 0;
	}

	// 与枪柜插件 CreateWeapon() 一致：world 武器实体、不投影阴影
	DispatchKeyValue(iEntity, "solid", "6");
	DispatchKeyValue(iEntity, "rendermode", "3");
	DispatchKeyValue(iEntity, "disableshadows", "1");

	float vAng[3], vPos2[3];
	vPos2 = vPos;
	vAng[0] = 0.0;
	vAng[1] = GetRandomFloat(0.0, 360.0);
	vAng[2] = 0.0;

	TeleportEntity(iEntity, vPos2, vAng, NULL_VECTOR);
	DispatchSpawn(iEntity);

	int iAmmo = GetAmmoFor(sClassname);
	if (iAmmo >= 0)
		SetEntProp(iEntity, Prop_Send, "m_iExtraPrimaryAmmo", iAmmo, 4);

	SetEntityMoveType(iEntity, MOVETYPE_NONE);   // 防滚动/掉落（枪柜同做法）

	if (g_hDebug.BoolValue)
		PrintToServer("[12v12 wdrop]   %s 生成于 %N 脚下 (%.1f %.1f %.1f), 弹药 %d", sClassname, iTarget, vPos2[0], vPos2[1], vPos2[2], iAmmo);

	// 返回实体索引给调用方。保持与 1.0.0 一致：DispatchSpawn 的返回值不参与流程控制，
	// 实体有效性由 ApplyGlowToWeapon() 里的 IsValidEntity() 兜住。
	return iEntity;
}

// 弹药：步枪类走 ammo_assaultrifle_max；AWP/鸟狙/猎狙走 ammo_sniperrifle_max；电锯走 ammo_chainsaw_max
// 取不到对应 cvar 时返回 -1（不写属性，保留实体自身默认）
int GetAmmoFor(const char[] sClassname)
{
	if (StrEqual(sClassname, "weapon_chainsaw", false))
		return (g_hAmmoChainsaw != null) ? g_hAmmoChainsaw.IntValue : -1;

	if (StrEqual(sClassname, "weapon_sniper_awp", false)
		|| StrEqual(sClassname, "weapon_sniper_scout", false)
		|| StrEqual(sClassname, "weapon_hunting_rifle", false)
		|| StrEqual(sClassname, "weapon_sniper_military", false))
		return (g_hAmmoSniper != null) ? g_hAmmoSniper.IntValue : -1;

	if (StrEqual(sClassname, "weapon_smg", false)
		|| StrEqual(sClassname, "weapon_smg_silenced", false)
		|| StrEqual(sClassname, "weapon_smg_mp5", false))
	{
		ConVar hSmg = FindConVar("ammo_smg_max");
		return (hSmg != null) ? hSmg.IntValue : -1;
	}

	if (StrEqual(sClassname, "weapon_pumpshotgun", false)
		|| StrEqual(sClassname, "weapon_shotgun_chrome", false)
		|| StrEqual(sClassname, "weapon_autoshotgun", false)
		|| StrEqual(sClassname, "weapon_shotgun_spas", false))
	{
		ConVar hShotgun = FindConVar("ammo_shotgun_max");
		return (hShotgun != null) ? hShotgun.IntValue : -1;
	}

	// 其余（步枪类，含 rifle_sg552）
	return (g_hAmmoRifle != null) ? g_hAmmoRifle.IntValue : -1;
}

// 随机取一名在游戏内的生还者（优先活着的；都没有就返回 0）
// 注意：函数名不能叫 GetRandomSurvivor —— 那是 left4dhooks_silver.inc:1314 的 stock
// （#include <left4dhooks> 会把它带进来），同名会导致 error 021: symbol already defined。
// 而且它的语义也不同（带 alive/bots 参数过滤），所以这里保留自己的实现，只换名字。
int PickRandomSurvivor()
{
	int aAlive[MAXPLAYERS + 1], aAny[MAXPLAYERS + 1];
	int iAlive, iAny;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != 2)
			continue;

		aAny[iAny++] = i;
		if (IsPlayerAlive(i))
			aAlive[iAlive++] = i;
	}

	if (iAlive > 0)
		return aAlive[GetRandomInt(0, iAlive - 1)];
	if (iAny > 0)
		return aAny[GetRandomInt(0, iAny - 1)];

	return 0;
}

// ===========================================================================
// 发光轮廓（glow）
// ---------------------------------------------------------------------------
// 两条路径（由 am12v12_wdrop_glow_proxy 选择）：
//
//   ① 直接发光（proxy=0 自动时先试 / proxy=2 只用这条）
//      L4D2_SetEntityGlow(weapon, L4D2Glow_Constant, range, minRange, color, flashing)
//      （left4dhooks_stocks.inc:708）。它内部先
//      FindSendPropInfo(netclass, "m_iGlowType")，< 1 说明该 netclass 没有发光属性，
//      直接 return false —— 这就是「武器实体不支持发光」的判定点，我们据此回退。
//      闪烁由它内部写 m_bFlashing 实现（:798-801）。
//
//   ② 代理回退（proxy=1 强制 / proxy=0 自动且直接发光失败）
//      建一个 prop_dynamic_override 假模型，模型名直接读武器实体的 m_ModelName
//      （不硬编码模型表），设好发光属性后 StartGlowing，再把自己渲染成完全透明，
//      最后 SetParent 到武器实体上跟着武器走。
//      照抄两处先例：
//        l4d2_item_hint.sp:1075-1125 CreateEntityModelGlow()
//        l4d_death_item_glow.sp:179-222 CreateGlowEntity()
//      关键顺序（先例一致）：m_CollisionGroup/m_nSolidType → 发光属性 → StartGlowing
//      → 渲染透明 → SetParent。先设发光再 StartGlowing，否则不亮。
//
// 生命周期（代理必须跟着武器一起消失，否则会留下永久挡视线的假模型）：
//   · SDKHook_WeaponEquipPost —— **最主要**的清理时机。L4D2 里玩家捡起地上的枪时，
//     武器实体并不是被销毁，而是进入玩家武器槽继续存在（L4D2 的 player_weapon 继承），
//     所以 OnEntityDestroyed 根本不会触发；不在这里撤发光的话，玩家会一路扛着一把
//     正在发光的枪跑，代理假模型也会跟着玩家走。先例：l4d_death_item_glow.sp:100/113-116
//   · public void OnEntityDestroyed(entity)  —— 武器真被删除（框架清理/换图）时的清理点
//   · Event_RoundStart / Event_RoundEnd / OnMapEnd / OnPluginEnd —— 全量清理
//   · Timer_GlowSweep（5 秒一次，仅在真的亮过之后才存在）—— 兜底巡检
//   · 每个槽位同时存 EntIndexToEntRef 的 ref（防实体索引复用误杀）和当时的 index
//     （供 OnEntityDestroyed 直接匹配，因为该回调里 ref 反查不可靠）
// ===========================================================================

// 找一个空槽位；满了返回 -1
int FindFreeGlowSlot()
{
	for (int i = 0; i < GLOW_SLOTS; i++)
	{
		if (!g_bGlowSlotUsed[i])
			return i;
	}
	return -1;
}

// 校验 Left4DHooks 是否可用。只要成功确认过一次就缓存，失败则只 LogError 一次。
// 说明：L4D2_SetEntityGlow 是 stock 不是 native，所以不能用
// GetFeatureStatus(FeatureType_Native, "L4D2_SetEntityGlow") 判定（永远是 Unknown）；
// 必须判 Left4DHooks 扩展本身是否存在。
void CheckGlowSupport()
{
	if (g_bGlowNativeOk)
		return;

	if (!LibraryExists("left4dhooks")
		|| GetFeatureStatus(FeatureType_Native, "Left4DHooks_Version") != FeatureStatus_Available)
	{
		if (!g_bGlowNativeWarned)
		{
			g_bGlowNativeWarned = true;
			LogError("[12v12 wdrop] 未检测到可用的 Left4DHooks（LibraryExists / Left4DHooks_Version 均需通过），发光轮廓功能整体禁用；武器仍会正常生成。");
		}
		return;
	}

	g_bGlowNativeOk = true;
	if (g_hDebug.BoolValue)
		PrintToServer("[12v12 wdrop] glow: Left4DHooks 可用，发光功能启用");
}

// 解析 am12v12_wdrop_glow_color。留空 / 解析失败 = 不覆盖颜色（交给游戏默认发光色）。
// 允许空格 / Tab / 逗号任意混排，例如 "255 200 0" 或 "255,200,0"。
void ParseGlowColor()
{
	char sColor[GLOW_COLOR_LEN];
	g_hGlowColor.GetString(sColor, sizeof(sColor));

	// 先把所有空白和逗号统一成空格，后面直接按空格切分
	for (int i = 0; sColor[i] != '\0'; i++)
	{
		if (IsCharSpace(sColor[i]) || sColor[i] == ',')
			sColor[i] = ' ';
	}
	TrimString(sColor);

	g_bGlowColorOverride = false;
	g_iGlowColor[0] = 0;
	g_iGlowColor[1] = 0;
	g_iGlowColor[2] = 0;

	if (sColor[0] == '\0')
		return;                       // 留空 = 用游戏默认发光颜色

	char aParts[8][8];
	int iCount = ExplodeString(sColor, " ", aParts, sizeof(aParts), sizeof(aParts[]));

	int aColor[3];
	int iFound = 0;
	int iNonEmpty = 0;
	bool bBad = false;

	for (int i = 0; i < iCount; i++)
	{
		TrimString(aParts[i]);
		if (aParts[i][0] == '\0')
			continue;                 // 连续空格产生的空段

		iNonEmpty++;

		int iVal = 0;
		int iChars = StringToIntEx(aParts[i], iVal);

		// 必须是整段纯数字：iChars<=0 表示没解析出数字，aParts[i][iChars]!='\0'
		// 表示段内还有残留字符（"255x" 这类半截输入），两种情况都判整串无效。
		if (iChars <= 0 || aParts[i][iChars] != '\0')
		{
			bBad = true;
			break;
		}

		if (iVal < 0)   iVal = 0;
		if (iVal > 255) iVal = 255;

		if (iFound < 3)
			aColor[iFound++] = iVal;
	}

	// 必须正好 3 段：多写一段（"255 200 0 123"）也算配置错误，直接回退默认色，
	// 免得玩家以为写了第 4 个值有用。
	if (bBad || iFound != 3 || iNonEmpty != 3)
	{
		if (!g_bGlowColorWarned)
		{
			g_bGlowColorWarned = true;
			LogError("[12v12 wdrop] am12v12_wdrop_glow_color 无法解析为 3 个 0-255 的数值（当前值 \"%s\"），改用游戏默认发光颜色。正确写法示例：\"255 200 0\"", sColor);
		}
		return;
	}

	g_iGlowColor[0] = aColor[0];
	g_iGlowColor[1] = aColor[1];
	g_iGlowColor[2] = aColor[2];
	g_bGlowColorOverride = true;
}

// 路径①：直接给武器实体自己加发光。返回 false = 该 netclass 不支持发光。
bool TryDirectGlow(int iEntity, int iRange, int iMinRange, bool bFlashing)
{
	// 颜色 override 传 {0,0,0} 表示不覆盖（引擎按默认发光色渲染），
	// 与 L4D2_RemoveEntityGlow 的用法一致（left4dhooks_stocks.inc:863-866）。
	int aColor[3];
	aColor[0] = g_bGlowColorOverride ? g_iGlowColor[0] : 0;
	aColor[1] = g_bGlowColorOverride ? g_iGlowColor[1] : 0;
	aColor[2] = g_bGlowColorOverride ? g_iGlowColor[2] : 0;

	// 内部先 FindSendPropInfo(netclass, "m_iGlowType")，< 1 直接 return false。
	return L4D2_SetEntityGlow(iEntity, L4D2Glow_Constant, iRange, iMinRange, aColor, bFlashing);
}

// 路径②：隐形假模型代理。失败返回 0。
int CreateGlowProxy(int iWeapon, int iRange, int iMinRange, bool bFlashing)
{
	// 模型名直接读武器实体自己的 m_ModelName（datamap CBaseEntity，offset 588），
	// 不硬编码武器模型表 —— 同 l4d_death_item_glow.sp:195。
	// 读之前先 HasEntProp 守卫（同 l4d2_item_hint.sp:2493-2495 的写法），
	// 并校验读到的是真的模型路径（"models/" 开头），否则 SetEntityModel 会拿到垃圾值。
	char sModel[GLOW_MODEL_LEN];
	if (!HasEntProp(iWeapon, Prop_Data, "m_ModelName")
		|| GetEntPropString(iWeapon, Prop_Data, "m_ModelName", sModel, sizeof(sModel)) <= 1
		|| strncmp(sModel, "models/", 7) != 0)
	{
		if (g_hDebug.BoolValue)
			PrintToServer("[12v12 wdrop] glow: 实体 %d 的 m_ModelName 不是可用的模型路径（\"%s\"），无法建代理", iWeapon, sModel);
		return 0;
	}

	// 位置/角度用 datamap 的绝对坐标（CBaseEntity offset 716 / 872），
	// 比 m_vecOrigin/m_angRotation 可靠（同 l4d_death_item_glow.sp:181-184）。
	float vPos[3], vAng[3];
	GetEntPropVector(iWeapon, Prop_Data, "m_vecAbsOrigin", vPos);
	GetEntPropVector(iWeapon, Prop_Data, "m_angAbsRotation", vAng);

	int iProxy = CreateEntityByName("prop_dynamic_override");
	if (iProxy == -1)
	{
		LogError("[12v12 wdrop] glow: 创建 prop_dynamic_override 代理失败");
		return 0;
	}

	DispatchKeyValue(iProxy, "model", sModel);
	DispatchKeyValue(iProxy, "targetname", GLOW_PROXY_TARGETNAME);   // 兜底扫描认领用
	DispatchKeyValue(iProxy, "disableshadows", "1");

	if (!DispatchSpawn(iProxy))
	{
		LogError("[12v12 wdrop] glow: 代理实体 DispatchSpawn 失败（模型 %s）", sModel);
		RemoveEntity(iProxy);
		return 0;
	}

	TeleportEntity(iProxy, vPos, vAng, NULL_VECTOR);
	SetEntityMoveType(iProxy, MOVETYPE_NONE);        // 不跟着重力掉下去

	// 不挡子弹 / 不挡路 / 不参与碰撞（照抄 l4d2_item_hint.sp:1090-1091）
	SetEntProp(iProxy, Prop_Send, "m_CollisionGroup", 0);
	SetEntProp(iProxy, Prop_Send, "m_nSolidType", 0);

	// 先用包装函数把发光属性写好（含 m_iGlowType / m_bFlashing / range / color），
	// 再 StartGlowing —— 顺序与两个先例一致，反了就不亮。
	int aColor[3];
	aColor[0] = g_bGlowColorOverride ? g_iGlowColor[0] : 0;
	aColor[1] = g_bGlowColorOverride ? g_iGlowColor[1] : 0;
	aColor[2] = g_bGlowColorOverride ? g_iGlowColor[2] : 0;

	if (!L4D2_SetEntityGlow(iProxy, L4D2Glow_Constant, iRange, iMinRange, aColor, bFlashing))
	{
		// 连 prop_dynamic_override 都不支持发光 —— 说明这套游戏/平台没有发光属性，
		// 没有任何回退手段了，直接放弃（不留下无用实体）。
		if (g_hDebug.BoolValue)
			PrintToServer("[12v12 wdrop] glow: 代理实体 %d 也不支持发光属性，放弃", iProxy);
		RemoveEntity(iProxy);
		return 0;
	}
	AcceptEntityInput(iProxy, "StartGlowing");

	// 假模型必须完全看不见，只留轮廓。RENDER_NONE 比 alpha=0 更彻底
	// （同 l4d_death_item_glow.sp:213-214），轮廓走独立的发光渲染通路，不受影响。
	SetEntityRenderMode(iProxy, RENDER_NONE);
	SetEntityRenderColor(iProxy, 0, 0, 0, 0);

	// 挂到武器实体上，跟武器一起走、一起被删
	SetVariantString("!activator");
	AcceptEntityInput(iProxy, "SetParent", iWeapon);

	return iProxy;
}

// 销毁一个槽位。bKillProxy=false 时认为代理已经自己没了，只清记录。
// bClearHostGlow=false 用于「武器实体正在被销毁」的场合：此时对垂死实体写 netprop 没有意义，
// 而且 OnEntityDestroyed 里动正在销毁的实体容易踩到引擎的非法访问。
void DestroyGlowSlot(int iSlot, bool bKillProxy, bool bClearHostGlow)
{
	if (iSlot < 0 || iSlot >= GLOW_SLOTS)
		return;

	int iProxy = 0;
	if (bKillProxy && g_iGlowProxyRef[iSlot] != 0)
	{
		int iTmp = EntRefToEntIndex(g_iGlowProxyRef[iSlot]);
		if (iTmp > 0 && IsValidEntity(iTmp))
			iProxy = iTmp;
	}

	int iHost = 0;
	if (g_iGlowHostRef[iSlot] != 0)
	{
		int iTmp = EntRefToEntIndex(g_iGlowHostRef[iSlot]);
		if (iTmp > 0 && IsValidEntity(iTmp))
			iHost = iTmp;
	}

	// 先把槽里的记录全部清掉，再真去删实体：AcceptEntityInput("Kill") 有可能
	// 立刻触发 OnEntityDestroyed，提前清空可避免重入时又匹配到本槽。
	g_iGlowHostRef[iSlot] = 0;
	g_iGlowHostIdx[iSlot] = 0;
	g_iGlowProxyRef[iSlot] = 0;
	g_iGlowProxyIdx[iSlot] = 0;
	g_bGlowSlotUsed[iSlot] = false;

	// 代理先关发光再删（同 l4d2_item_hint.sp:879-891）
	if (iProxy > 0)
	{
		AcceptEntityInput(iProxy, "TurnOff");
		AcceptEntityInput(iProxy, "Kill");
	}

	// 宿主武器还活着时把直接发光撤掉。注意：绝不动武器实体本身，那是玩家的枪。
	// bClearHostGlow=false 表示宿主正在销毁，此时不碰它的 netprop。
	if (iHost > 0 && bClearHostGlow)
		L4D2_RemoveEntityGlow(iHost);
}

// 判断是否还有活跃槽位（巡检定时器据此决定要不要继续跑）
bool HasAnyGlowSlot()
{
	for (int i = 0; i < GLOW_SLOTS; i++)
	{
		if (g_bGlowSlotUsed[i])
			return true;
	}
	return false;
}

// 判断某个实体是不是仍被某个槽位当作代理（兜底扫描时用，防误杀）
bool IsGlowProxyTracked(int iEntity)
{
	for (int i = 0; i < GLOW_SLOTS; i++)
	{
		if (g_bGlowSlotUsed[i] && g_iGlowProxyIdx[i] == iEntity)
			return true;
	}
	return false;
}

// 扫掉「targetname 是我们、但已经没有槽位认领」的代理（引擎连坐删除漏网时兜底）。
// 只处理自己打的 targetname，绝不碰别的插件的同类实体。
void SweepOrphanProxies()
{
	// 删掉实体后索引可能被引擎立刻复用，继续按原索引往后扫会漏实体，
	// 所以每次删完就从头重扫。加一个硬上限防止 RemoveEntity 失效时死循环。
	// 上限取 512 而不是 GLOW_SLOTS 级别：FindEntityByClassname 会把地图里
	// 所有 prop_dynamic_override 都过一遍（不是只有我们的代理），上限太小会扫不到。
	int iGuard = 512;
	int iEnt = -1;
	char sName[64];

	while (iGuard-- > 0 && (iEnt = FindEntityByClassname(iEnt, "prop_dynamic_override")) != -1)
	{
		if (GetEntPropString(iEnt, Prop_Data, "m_iName", sName, sizeof(sName)) <= 0)
			continue;
		if (!StrEqual(sName, GLOW_PROXY_TARGETNAME, false))
			continue;
		if (IsGlowProxyTracked(iEnt))
			continue;

		AcceptEntityInput(iEnt, "TurnOff");
		RemoveEntity(iEnt);

		if (g_hDebug.BoolValue)
			PrintToServer("[12v12 wdrop] glow: 清理残留代理实体 %d", iEnt);

		iEnt = -1;                  // 从头重扫，避免索引复用漏扫
	}
}

// 巡检：宿主没了就把整槽拆掉；代理没了就只清代理记录。
void SweepGlowSlots()
{
	for (int i = 0; i < GLOW_SLOTS; i++)
	{
		if (!g_bGlowSlotUsed[i])
			continue;

		// 宿主武器已被捡走/删除 → 连代理一起清掉。宿主已经没了，不必再给它撤发光。
		int iHost = (g_iGlowHostRef[i] != 0) ? EntRefToEntIndex(g_iGlowHostRef[i]) : 0;
		if (iHost <= 0 || !IsValidEntity(iHost))
		{
			DestroyGlowSlot(i, true, false);
			continue;
		}

		// 宿主还在但代理没了（引擎连坐删除 / 被别的插件清理）→ 只清代理记录
		if (g_iGlowProxyRef[i] != 0)
		{
			int iProxy = EntRefToEntIndex(g_iGlowProxyRef[i]);
			if (iProxy <= 0 || !IsValidEntity(iProxy))
			{
				g_iGlowProxyRef[i] = 0;
				g_iGlowProxyIdx[i] = 0;
			}
		}
	}

	SweepOrphanProxies();
}

// 只在真的亮过之后才开巡检定时器 —— glow 从未生效时零负担、零副作用
void EnsureGlowSweep()
{
	if (g_hGlowSweep != null)
		return;

	g_hGlowSweep = CreateTimer(5.0, Timer_GlowSweep, _, TIMER_REPEAT);
}

public Action Timer_GlowSweep(Handle timer)
{
	// 运行中把 glow_enable 改成 0：把场上已有的代理和发光全撤掉，再停掉巡检。
	// 先把句柄置 null 再调 ClearAllGlow()，这样它内部的 KillTimer 不会打到自己。
	if (!g_hGlowEnable.BoolValue)
	{
		g_hGlowSweep = null;
		ClearAllGlow();
		return Plugin_Stop;
	}

	SweepGlowSlots();

	// 所有槽位都已经收工（武器全被捡走/删掉）→ g_bGlowActive 归 false 并停表，
	// 回到「零负担」状态。下一回合再生成武器时 ApplyGlowToWeapon 会重新拉起来。
	// 注意：必须靠 HasAnyGlowSlot() 而不是 g_bGlowActive 判断 —— 后者要到本函数
	// 后面才可能被改写，用它会让定时器在所有武器都没了之后继续空转一整局。
	if (!HasAnyGlowSlot())
	{
		g_hGlowSweep = null;
		g_bGlowActive = false;
		return Plugin_Stop;
	}

	return Plugin_Continue;
}

// 全量清理：换图 / 回合切换 / 插件卸载时调用。
// glow 从未生效时只有一次定时器判断就返回，保证 glow_enable=0 时行为与 1.0.0 一致。
void ClearAllGlow()
{
	if (g_hGlowSweep != null)
	{
		KillTimer(g_hGlowSweep);
		g_hGlowSweep = null;
	}

	if (!g_bGlowActive)
		return;

	int iCount;
	for (int i = 0; i < GLOW_SLOTS; i++)
	{
		if (!g_bGlowSlotUsed[i])
			continue;
		DestroyGlowSlot(i, true, true);
		iCount++;
	}

	SweepOrphanProxies();
	g_bGlowActive = false;

	if (g_hDebug.BoolValue)
		PrintToServer("[12v12 wdrop] glow: 已清理 %d 个发光槽位", iCount);
}

// 给一把刚生成的武器加发光。由 Timer_SpawnWeapons 在 SpawnWeapon() > 0 后调用。
void ApplyGlowToWeapon(int iWeapon)
{
	// 关掉发光时第一句就返回：不查 native、不建实体、不挂 hook（行为与 1.0.0 一致）
	if (!g_hGlowEnable.BoolValue)
		return;

	if (!IsValidEntity(iWeapon))
		return;

	CheckGlowSupport();
	if (!g_bGlowNativeOk)
		return;                       // native/扩展缺失 → 静默退化为不发光

	// 每次生成武器时重新解析一次颜色 cvar，改颜色后下一把生成的武器立刻用新色，
	// 不需要注册 cvar 变更钩子（见 OnPluginStart 的说明）。
	ParseGlowColor();

	int iSlot = FindFreeGlowSlot();
	if (iSlot < 0)
	{
		if (g_hDebug.BoolValue)
			PrintToServer("[12v12 wdrop] glow: 槽位已满（%d），实体 %d 不加发光", GLOW_SLOTS, iWeapon);
		return;
	}

	int iMode     = g_hGlowProxy.IntValue;          // 0 自动 / 1 强制代理 / 2 只直接发光
	int iRange    = RoundToNearest(g_hGlowRange.FloatValue);
	int iMinRange = RoundToNearest(g_hGlowMinRange.FloatValue);
	bool bFlashing = g_hGlowFlashing.BoolValue;

	bool bDirect = false;
	if (iMode != 1)                                 // 模式 1（强制代理）跳过直接发光
		bDirect = TryDirectGlow(iWeapon, iRange, iMinRange, bFlashing);

	int iProxy = 0;
	if (!bDirect)
	{
		if (iMode == 2)
		{
			// 模式 2：只用直接发光，失败就不发光（这是玩家显式的选择，不再回退）
			if (g_hDebug.BoolValue)
				PrintToServer("[12v12 wdrop] glow: 实体 %d 不支持直接发光，proxy=2 故不加发光", iWeapon);
			return;
		}

		iProxy = CreateGlowProxy(iWeapon, iRange, iMinRange, bFlashing);
		if (iProxy <= 0)
		{
			// 代理也建不出来 → 退化为「不发光」，武器本身照常可用
			if (g_hDebug.BoolValue)
				PrintToServer("[12v12 wdrop] glow: 实体 %d 代理创建失败，退化为不发光", iWeapon);
			return;
		}
	}

	g_iGlowHostRef[iSlot]  = EntIndexToEntRef(iWeapon);
	g_iGlowHostIdx[iSlot]  = iWeapon;
	g_iGlowProxyRef[iSlot] = (iProxy > 0) ? EntIndexToEntRef(iProxy) : 0;
	g_iGlowProxyIdx[iSlot] = iProxy;
	g_bGlowSlotUsed[iSlot] = true;
	g_bGlowActive = true;
	EnsureGlowSweep();
	EnsureClientGlowHooks();     // 捡枪时撤销发光所必需的 hook（只在真的亮过之后才挂）

	if (g_hDebug.BoolValue)
		PrintToServer("[12v12 wdrop] glow: 武器 %d（槽 %d）用%s发光，range=%d，min=%d，flashing=%d，颜色=%s",
			iWeapon, iSlot, bDirect ? "直接" : "假模型代理",
			iRange, iMinRange, bFlashing ? 1 : 0,
			g_bGlowColorOverride ? "配置值" : "游戏默认");
}

// 给所有在游戏内的玩家挂 SDKHook_WeaponEquipPost（只挂一次，用 g_bClientGlowHooked 记）。
// 只在发光真正生效之后才会被调用 —— glow_enable=0 时一个 hook 都不挂。
void EnsureClientGlowHooks()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
			continue;
		if (g_bClientGlowHooked[i])
			continue;

		SDKHook(i, SDKHook_WeaponEquipPost, SDK_OnWeaponEquipPost);
		g_bClientGlowHooked[i] = true;
	}
}

// 玩家刚把一把武器装到身上。如果这把枪正好是我们加了发光的，把发光撤掉：
//   · 直接发光 → L4D2_RemoveEntityGlow()，否则玩家会扛着一把发光的枪跑来跑去
//   · 代理方案 → 代理必须 Kill，否则假模型会跟着玩家走
// 先例：l4d_death_item_glow.sp:113-116 SDK_OnWeaponEquip_Post → RemoveWeaponGlow()
public void SDK_OnWeaponEquipPost(int client, int weapon)
{
	if (!g_bGlowActive || weapon <= 0)
		return;

	for (int i = 0; i < GLOW_SLOTS; i++)
	{
		if (!g_bGlowSlotUsed[i])
			continue;
		if (g_iGlowHostIdx[i] != weapon)
			continue;

		if (g_hDebug.BoolValue)
			PrintToServer("[12v12 wdrop] glow: 武器 %d 被 %N 捡起，撤销发光（槽 %d）", weapon, client, i);

		// 武器还活着（进了玩家背包），所以这里要把直接发光也清掉
		DestroyGlowSlot(i, true, true);
		return;
	}
}

// 中途加入的玩家也要挂上（12v12 一般没人中途进，但漏挂会让该玩家的捡枪撤销失效）。
// glow 从未生效时这里第一句就返回，不产生任何副作用。
public void OnClientPutInServer(int client)
{
	if (!g_bGlowActive)
		return;

	EnsureClientGlowHooks();
}

// 玩家断开时清掉「这个 client 已挂 hook」的标记。
// 必须做：SDKHooks 在客户端断开时会自动摘掉它的全部 hook，但我们的标记位不会自动复位，
// 不复位的话同一个 client 索引下次进服就再也不会重新挂 hook —— 那人的捡枪撤销会永久失效。
public void OnClientDisconnect(int client)
{
	if (client < 0 || client >= sizeof(g_bClientGlowHooked))
		return;

	g_bClientGlowHooked[client] = false;
}

// 武器被捡走 / 被删除时的主动清理点。
// 注意：换图时本回调不保证对每个实体都跑到（l4d_cloud_screen_fade.sp:713 的教训），
// 所以 OnMapEnd / round_start / round_end 的全量清理 + 5 秒巡检都不能省。
public void OnEntityDestroyed(int entity)
{
	// 从没亮过 → 一个字段都不碰
	if (!g_bGlowActive)
		return;

	if (entity <= 0)
		return;

	for (int i = 0; i < GLOW_SLOTS; i++)
	{
		if (!g_bGlowSlotUsed[i])
			continue;

		if (g_iGlowHostIdx[i] == entity)
		{
			// 武器没了：代理必须跟着没。宿主正在销毁，所以不回头去动武器实体的 netprop
			// （bClearHostGlow=false）—— 对垂死实体写属性既没意义也容易踩引擎。
			DestroyGlowSlot(i, true, false);
			return;
		}

		if (g_iGlowProxyIdx[i] == entity)
		{
			// 代理自己没了（多半是父武器被删时引擎连坐删除）：
			// 只清代理记录，宿主可能还活着（例如刚被玩家捡走的瞬间）。
			g_iGlowProxyRef[i] = 0;
			g_iGlowProxyIdx[i] = 0;
			return;
		}
	}
}

// ===========================================================================
// 发光轮廓（glow）：设计说明与运行流程
// ===========================================================================
// 【为什么需要两条路径】
//   L4D2 的发光属性（m_iGlowType / m_nGlowRange / m_nGlowRangeMin /
//   m_glowColorOverride / m_bFlashing）定义在 DT_BaseEntity 的 m_Glow 子表里，
//   理论上所有实体都有。但 DrawModel 侧能不能真的给某个 netclass 画出轮廓，
//   取决于该实体有没有可用的世界模型 —— 武器实体（CBaseAnimating 派生）通常有，
//   但这一点在没有实测前不能当成事实，所以必须有代理兜底。
//
// 【路径① 直接发光】TryDirectGlow()
//   调用 L4D2_SetEntityGlow()（left4dhooks_stocks.inc:708-731）。它是 stock，
//   内部先 FindSendPropInfo(netclass, "m_iGlowType")，返回 < 1 就 return false，
//   表示该 netclass 没有发光属性；否则依次写 type / range / minRange / color /
//   flashing 五个 netprop 并 return true。
//   · 返回 true  → 该武器直接发光，不建任何额外实体。
//   · 返回 false → 该 netclass 不支持，转路径②（proxy != 2 时）。
//
// 【路径② 隐形假模型代理】CreateGlowProxy()
//   建一个 prop_dynamic_override，模型直接用武器自己的 m_ModelName，
//   把发光属性写在代理身上，再把代理渲染成全透明并挂到武器实体下当子实体。
//   玩家看到的是「武器的轮廓」，但实际渲染的是这个看不见的代理。
//   照抄两个先例：l4d2_item_hint.sp:1075-1125、l4d_death_item_glow.sp:179-222。
//   · 代理建不出来 / 代理自己也不支持发光 → 放弃，武器照常可用，只是不亮。
//
// 【am12v12_wdrop_glow_proxy 的三种取值】
//   0 = 自动：先试路径①，false 再走路径②（默认，兼容性最好）
//   1 = 强制代理：直接走路径②，完全不给武器实体写发光属性
//       （给「直接发光在实机上把武器本体也照亮/出现异常」留的逃生门）
//   2 = 只用直接发光：路径①失败就干脆不亮，绝不额外建实体
//       （给「不想在服务器里多出一批实体」的场合用）
//
// 【代理的创建 / 销毁时机 —— 完整清单】
//   创建：ApplyGlowToWeapon()，由 Timer_SpawnWeapons() 在 SpawnWeapon() > 0 后调用。
//   销毁（任一触发即清，且每个都做了防重入）：
//     ① SDK_OnWeaponEquipPost(client, weapon)
//        玩家捡起这把枪。**这是最主要的时机** —— L4D2 里枪被捡走时武器实体
//        不会被销毁，而是进玩家武器槽继续存在，OnEntityDestroyed 不会触发。
//        不在这里撤掉的话，玩家会扛着一把正在发光的枪跑、代理假模型也跟着走。
//        先例：l4d_death_item_glow.sp:113-116。
//     ② OnEntityDestroyed(entity)
//        武器真被删（框架清理 / 换图）。命中宿主 → 连代理一起删；
//        命中代理 → 只清代理记录。
//     ③ Event_RoundStart → ClearAllGlow()
//        上一回合剩下的武器可能还在，先把槽位表和实体状态对齐。
//     ④ Event_RoundEnd → ClearAllGlow()
//     ⑤ OnMapEnd → ClearAllGlow()
//        换图时引擎会销毁所有实体，但 OnEntityDestroyed 不保证对每个实体都跑到
//        （l4d_cloud_screen_fade.sp:713 的教训），所以必须主动全量清理。
//     ⑥ OnPluginEnd → ClearAllGlow()
//        插件被 sm plugins unload/reload 时，我们注册的 OnEntityDestroyed 与全部
//        SDKHook 都随之消失；若此时还留着代理假模型，就再没人能删它们了。
//     ⑦ Timer_GlowSweep（5 秒一次，仅在真的亮过之后才存在）→ SweepGlowSlots()
//        兜底：宿主没了就拆槽，代理没了就清记录，再 SweepOrphanProxies()
//        扫掉「targetname 是我们、但没有槽位认领」的残留代理。
//     ⑧ Timer_GlowSweep 里发现 glow_enable 被改成 0 → 清空并停表。
//
// 【为什么每个槽位同时存 ref 和 index】
//   g_iGlowHostRef / g_iGlowProxyRef 用 EntIndexToEntRef() 存，防止实体索引被
//   引擎复用后误杀别人的实体；g_iGlowHostIdx / g_iGlowProxyIdx 存当时的裸索引，
//   因为 OnEntityDestroyed(entity) 是在实体「正在销毁」时回调的，此时对同一实体
//   做 EntRefToEntIndex 并不可靠，只能拿裸索引直接比对。
//
// 【glow_enable=0 时为什么和 1.0.0 逐字节等价】
//   ApplyGlowToWeapon() 第一句就是 if (!g_hGlowEnable.BoolValue) return; ——
//   不查 native、不解析颜色、不建实体、不写任何 netprop。
//   ClearAllGlow() 第一段只判一个 null 句柄（g_hGlowSweep 从没被创建过）。
//   OnEntityDestroyed / SDK_OnWeaponEquipPost / OnClientPutInServer 第一句都是
//   if (!g_bGlowActive) return; —— g_bGlowActive 从没被置 true 过。
//   不注册任何 cvar 变更钩子；EnsureClientGlowHooks() 永远不会被调用，
//   所以一个 SDKHook 都不挂（SDKHooks forward OnEntityDestroyed 是全局回调，
//   但它第一句就 return，没有副作用）。
// ===========================================================================

