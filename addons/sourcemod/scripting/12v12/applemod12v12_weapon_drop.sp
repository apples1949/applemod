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
 * ===========================================================================
 * 1.2.0（2026-10-19）修复「闪烁轮廓不显示」
 * ---------------------------------------------------------------------------
 * 1.1.0 的做法是「先给武器实体本身写发光属性，失败了才用假模型代理」。
 * 问题在于：它用 L4D2_SetEntityGlow() 的返回值当成功判据，而这个返回值只等价于
 * FindSendPropInfo(netclass,"m_iGlowType") > 0 —— 只证明「属性写得进去」，
 * 不证明客户端真的把轮廓画出来了。武器实体这一路永远返回 true，
 * 于是代理分支永远不触发；实机上就是「不亮、也不闪」（用户反馈）。
 *
 * 1.2.0 改成「双保险 + 两条独立的发光通路」：
 *   ① 武器实体本身：直接写 m_iGlowType / m_nGlowRange / m_nGlowRangeMin /
 *      m_glowColorOverride / m_bFlashing 五个 netprop（不依赖 Left4DHooks）。
 *   ② 隐形假模型代理：prop_dynamic_override 复制武器的世界模型，同样的五个
 *      发光属性 + StartGlowing，再把自己渲染成完全透明，摆在武器同一坐标上。
 *      这条路是本仓库里被长期验证「能画出轮廓」的做法：
 *      l4d2_item_hint.sp:718-765（CreateEntityModelGlow）、
 *      l4d_death_item_glow.sp:179-222（CreateGlowEntity）、
 *      l4d2_tank_props_glow.sp:333-372。
 *   两条路互不干扰：谁真的渲染出来，玩家就能看到谁的轮廓；都不亮才算失败（会记日志）。
 *   是否用代理由 am12v12_wdrop_glow_proxy 控制（0=双保险，1=只用代理，2=只直接发光）。
 *
 * 另有两点时序修正：发光属性改为「武器生成后下一帧」再写（实体成型后才稳），
 * 且写完 netprop 之后才发 StartGlowing，再幂等重写一遍，避免被输入回调覆盖。
 *
 * 其余行为（生成时机 / 位置 / 弹药 / 清理 / 日志）与 1.0.0 完全一致；
 * am12v12_wdrop_glow_enable=0 时仍然一个 netprop 都不写、一个实体都不建。
 * ===========================================================================
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>          // OnEntityDestroyed / SDKHook_WeaponEquipPost

#define PLUGIN_VERSION "1.2.0"

ConVar g_hEnable, g_hWeapons, g_hMode, g_hDelay, g_hSpread, g_hDebug;
ConVar g_hAmmoRifle, g_hAmmoChainsaw, g_hAmmoSniper;
ConVar g_hGlowEnable, g_hGlowColor, g_hGlowRange, g_hGlowMinRange, g_hGlowFlashing, g_hGlowProxy;

bool g_bRoundStart, g_bPlayerSpawn, g_bSpawned;

public Plugin myinfo =
{
	name = "Applemod 12v12 Weapon Drop",
	author = "apples1949",
	version = PLUGIN_VERSION,
	description = "12v12 开局把指定武器（默认电锯/SG552/AWP/鸟狙）生成在随机生还者脚下，并加闪烁轮廓；参考 Silvers 的 Melee In The Saferoom + Gun Cabinet",
	url = "https://github.com/apples1949/applemod"
};

// ---------------------------------------------------------------------------
// 发光轮廓（glow）所需的模块级状态
// ---------------------------------------------------------------------------
// 槽位数：本插件每回合最多生成 sizeof(aWeapons)=16 把武器，所以 16 就够。
#define GLOW_SLOTS     16
#define GLOW_MODEL_LEN PLATFORM_MAX_PATH     // 武器世界模型名长度（PLATFORM_MAX_PATH=256, files.inc:75）
#define GLOW_COLOR_LEN 32                    // "255 200 0" 级别的颜色字符串

// 代理实体的 targetname：换图/回合兜底扫描时用来精确认领「自己留下的」代理，
// 不会误杀别的插件的同类实体（例如 l4d2_item_hint 的 harry_marked_item）。
#define GLOW_PROXY_TARGETNAME "am12v12_wdrop_glowproxy"

// L4D2 的发光类型枚举（left4dhooks_stocks.inc:106-112：None=0 / OnUse=1 / OnLookAt=2 / Constant=3）。
// 这里直接写字面量 3，不再依赖 Left4DHooks 的头文件 —— 少一个运行期依赖就少一种失败方式。
#define GLOW_TYPE_NONE     0
#define GLOW_TYPE_CONSTANT 3

// 巡检时收集「玩家手上的武器实体」用的列表容量：每个玩家最多 5 个武器槽，
// MAXPLAYERS=101 ⇒ 505 就够，取 512 留余量。
#define HELD_WEAPONS_MAX 512

// 每个槽位同时记 ref 和 index，两者不能互相替代：
//   · ref（EntIndexToEntRef）用来判断「这个索引是不是还是原来那个实体」，防索引复用误杀；
//   · index 用于 OnEntityDestroyed(entity) 里做直接匹配 —— 该回调是实体正在销毁时触发的，
//     此时对同一个实体做 EntRefToEntIndex 并不可靠，所以不能靠 ref 反查。
int  g_iGlowHostRef[GLOW_SLOTS];             // 武器实体 ref；0 = 空槽
int  g_iGlowHostIdx[GLOW_SLOTS];             // 武器实体 index
int  g_iGlowProxyRef[GLOW_SLOTS];            // 假模型代理 ref；0 = 本槽没有代理
int  g_iGlowProxyIdx[GLOW_SLOTS];            // 假模型代理 index
bool g_bGlowSlotUsed[GLOW_SLOTS];
// 本槽是否已经尝试过创建代理。用于「第一帧模型名还没写好导致代理没建起来」时，
// 由 5 秒巡检再补一次（只补一次，避免无限重试刷实体）。
bool g_bGlowProxyTried[GLOW_SLOTS];

int  g_iGlowColor[3];                        // 解析后的 RGB
bool g_bGlowColorOverride;                   // false = 不覆盖颜色（交给游戏默认发光色）
bool g_bGlowColorWarned;                     // 颜色串解析失败时 LogError 只打一次

// 「两条路都没成」的 LogError 只打一次，避免每回合刷日志
bool g_bGlowFailWarned;

// 是否真的给实体加过发光。false 时所有 glow 清理 / 残留扫描 / 定时器全部零副作用，
// 保证 glow_enable=0 时与 1.0.0 行为等价。
bool g_bGlowActive;

// 代理存活巡检定时器句柄。只在发光真正生效之后才创建（见 EnsureGlowSweep）：
// OnEntityDestroyed 不保证对每个实体都跑到（l4d_cloud_screen_fade.sp:713 的教训），
// 所以用低频巡检兜底，避免假模型代理变成永久残留。
Handle g_hGlowSweep;

// 客户端是否已挂 SDKHook_WeaponEquipPost（只有真的加过发光后才会挂）
bool g_bClientGlowHooked[MAXPLAYERS + 1];    // MAXPLAYERS=101（1.12 include/clients.inc:72）

// 待发光的武器：生成武器的当帧只登记，下一帧再统一应用发光。
// 理由：武器实体在 DispatchSpawn 的同一帧里，模型索引 / 绝对坐标 / 网络状态还没完全落定，
// 而发光属性要写给「已经成型的实体」才稳（l4d2_item_hint.sp:631-637 与
// l4d2_random_glow_item.sp:629-643 也都是「实体创建后 RequestFrame 再处理」）。
// 延迟一帧 ≈ 15ms，玩家完全感觉不到。
int  g_iPendingGlowRef[GLOW_SLOTS];
int  g_iPendingGlowCount;
bool g_bPendingGlowFrame;

public void OnPluginStart()
{
	CreateConVar("am12v12_wdrop_version", PLUGIN_VERSION, "开局丢枪插件版本", FCVAR_NOTIFY|FCVAR_DONTRECORD);
	g_hEnable  = CreateConVar("am12v12_wdrop_enable",  "1", "是否启用", _, true, 0.0, true, 1.0);
	g_hWeapons = CreateConVar("am12v12_wdrop_weapons", "weapon_chainsaw,weapon_rifle_sg552,weapon_sniper_awp,weapon_sniper_scout",
							  "开局生成的武器类名，英文逗号分隔（默认：电锯/SG552/AWP/鸟狙）");
	g_hMode    = CreateConVar("am12v12_wdrop_mode",    "0", "0=全部生成在同一名随机生还者脚下；1=每把各挑一名随机生还者", _, true, 0.0, true, 1.0);
	g_hDelay   = CreateConVar("am12v12_wdrop_delay",   "1.0", "回合开始后延迟多少秒生成（要晚于框架 round_start+0.3s 的武器清理）", _, true, 0.0, true, 30.0);
	g_hSpread  = CreateConVar("am12v12_wdrop_spread",  "20.0", "同一位置生成多把武器时的散开半径（避免叠在一起）", _, true, 0.0, true, 200.0);
	g_hDebug   = CreateConVar("am12v12_wdrop_debug",   "0", "1=在服务端控制台打印生成了什么、生成在谁脚下、发光走了哪条路", _, true, 0.0, true, 1.0);

	// ---- 发光轮廓（glow）----
	g_hGlowEnable   = CreateConVar("am12v12_wdrop_glow_enable",    "1",
								   "是否给开局生成的武器加发光轮廓（可闪烁）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hGlowColor    = CreateConVar("am12v12_wdrop_glow_color",     "255 200 0",
								   "轮廓颜色 RGB，空格分隔。留空 = 用游戏默认发光颜色", FCVAR_NOTIFY);
	g_hGlowRange    = CreateConVar("am12v12_wdrop_glow_range",     "800",
								   "轮廓可见距离（HU），0 = 无限距离", FCVAR_NOTIFY, true, 0.0, true, 10000.0);
	g_hGlowMinRange = CreateConVar("am12v12_wdrop_glow_min_range", "0",
								   "轮廓开始显示的最小距离（HU），0=从最近处就显示", FCVAR_NOTIFY, true, 0.0, true, 10000.0);
	g_hGlowFlashing = CreateConVar("am12v12_wdrop_glow_flashing",  "1",
								   "轮廓是否闪烁。0=常亮", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hGlowProxy    = CreateConVar("am12v12_wdrop_glow_proxy",     "0",
								   "发光的实现方式：0=双保险（武器实体自己发光 + 再挂一个隐形假模型代理，最稳）, 1=只挂假模型代理, 2=只给武器实体发光（不额外生成实体，但武器实体在部分版本不会渲染轮廓）",
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

	RegAdminCmd("sm_wdropglow", Cmd_GlowStatus, ADMFLAG_CONFIG,
				"查看开局丢枪的发光状态（每个槽位的武器/代理/发光属性）。加参数 reapply 会把当前武器重新发光一次");
}

// 插件被手动卸载（sm plugins unload / reload）时也必须清一遍：
// 卸载后我们的 OnEntityDestroyed / SDKHook 全部消失，若此时还留着代理假模型，
// 它们就再也没人管了 —— 会一直挂在地上发光到换图为止。
public void OnPluginEnd()
{
	ClearAllGlow();
}

public void OnMapEnd()
{
	// 换图前把代理实体和自己的发光全部撤掉：换图时引擎会销毁所有实体，
	// 但 OnEntityDestroyed 不保证对每个实体都跑到，所以这里必须主动全量清理 + 扫描残留。
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
			QueueGlow(iWeapon);
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
// 注意：函数名不能叫 GetRandomSurvivor —— 那是 left4dhooks_silver.inc:1314 的 stock，
// 且它的语义也不同（带 alive/bots 参数过滤），所以这里用自己实现的名字。
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
// 引擎侧的发光属性全部在 DT_BaseEntity 的 m_Glow 子表里（netprop-dump.txt:23-28）：
//   m_iGlowType        （4 字节整型）0=无 1=使用中? 3=常亮（本插件用 3）
//   m_nGlowRange       （4 字节整型）可见距离，0 = 无限
//   m_nGlowRangeMin    （4 字节整型）开始显示的最小距离
//   m_glowColorOverride（4 字节整型）RGB 打包：R|G<<8|B<<16
//   m_bFlashing        （1 位）      是否闪烁 —— 这是「闪」的唯一开关
// 客户端只对「有世界模型」的实体画轮廓；武器实体（CWeapon*）在部分版本上
// 就算属性写进去也不画，所以本插件同时走两条路：
//
//   ① 直接给武器实体写上面 5 个 netprop（WriteGlowProps）。
//      成本 0、不建实体；能画出来最好。
//   ② 隐形假模型代理（CreateGlowProxy）：
//      prop_dynamic_override + 武器自己的 m_ModelName，写同样的 5 个 netprop，
//      再 AcceptEntityInput("StartGlowing")，然后 RENDER_TRANSCOLOR + alpha 0
//      把自己渲染成完全透明，摆在与武器完全相同的世界坐标上（不做 SetParent，原因见
//      CreateGlowProxy 里的注释）。先例：l4d2_item_hint.sp:718-765、
//      l4d_death_item_glow.sp:179-222、l4d2_tank_props_glow.sp:333-372
//      （都是「先写属性再 StartGlowing」）。
//
// 【为什么不能只靠 L4D2_SetEntityGlow()】
//   它是 left4dhooks_stocks.inc:708 的 stock：FindSendPropInfo(netclass,"m_iGlowType")
//   找到就直接 return true。返回 true 只代表「这个 netclass 有发光属性」，
//   不代表客户端一定画轮廓 —— 1.1.0 就是被这个 true 骗了，代理分支永远不走。
//
// 生命周期（代理绝不能留在地上变成永久残留）：
//   · SDKHook_WeaponEquipPost —— **最主要**的清理时机。L4D2 里玩家捡起地上的枪时，
//     武器实体并不是被销毁，而是进入玩家武器槽继续存在，OnEntityDestroyed 根本不会触发；
//     不在这里撤发光的话，地上会留下一把「看不见的枪」继续亮，直到回合结束。
//     先例：l4d_death_item_glow.sp:100/113-116
//   · public void OnEntityDestroyed(entity) —— 武器真被删除（框架清理/换图）时的清理点
//   · Event_RoundStart / Event_RoundEnd / OnMapEnd / OnPluginEnd —— 全量清理
//   · Timer_GlowSweep（5 秒一次，仅在真的亮过之后才存在）—— 兜底巡检
//   · 每个槽位同时存 EntIndexToEntRef 的 ref（防实体索引复用误杀）和当时的 index
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

	// 必须正好 3 段：多写一段（"255 200 0 123"）也算配置错误，直接回退默认色。
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

// 颜色打包成引擎用的整型值（与 left4dhooks_stocks.inc:786 的算法一致）
int GlowColorInt()
{
	if (!g_bGlowColorOverride)
		return 0;                     // 0 = 不覆盖，引擎用默认发光色
	return g_iGlowColor[0] + (g_iGlowColor[1] * 256) + (g_iGlowColor[2] * 65536);
}

// 把 5 个发光 netprop 写到一个实体上。返回 false = 这个实体连 m_iGlowType 都没有。
// 属性名逐个 HasEntProp 守卫：不是所有 netclass 都带齐 m_Glow 子表，
// 对不存在的属性 SetEntProp 会抛 "Property not found" 错误。
bool WriteGlowProps(int iEntity, int iRange, int iMinRange, bool bFlashing)
{
	if (iEntity <= 0 || !IsValidEntity(iEntity))
		return false;

	if (!HasEntProp(iEntity, Prop_Send, "m_iGlowType"))
		return false;

	SetEntProp(iEntity, Prop_Send, "m_iGlowType", GLOW_TYPE_CONSTANT);

	if (HasEntProp(iEntity, Prop_Send, "m_nGlowRange"))
		SetEntProp(iEntity, Prop_Send, "m_nGlowRange", iRange);

	if (HasEntProp(iEntity, Prop_Send, "m_nGlowRangeMin"))
		SetEntProp(iEntity, Prop_Send, "m_nGlowRangeMin", iMinRange);

	if (HasEntProp(iEntity, Prop_Send, "m_glowColorOverride"))
		SetEntProp(iEntity, Prop_Send, "m_glowColorOverride", GlowColorInt());

	// 闪烁开关。m_bFlashing 是 1 bit 的属性，写 int 值 0/1。
	if (HasEntProp(iEntity, Prop_Send, "m_bFlashing"))
		SetEntProp(iEntity, Prop_Send, "m_bFlashing", bFlashing ? 1 : 0);

	// StartGlowing 只存在于 prop_dynamic / prop_physics / prop_dynamic_override 这类实体。
	// 对没有该 input 的实体（例如武器实体）引擎会直接忽略，不会报错，
	// 也不会清掉上面写好的属性 —— 所以这里可以无条件调用。
	AcceptEntityInput(iEntity, "StartGlowing");

	// 再写第二遍：StartGlowing 内部会按 m_iInitialGlowState / glowstate 重新初始化发光状态，
	// 先写属性再发输入时有可能被它盖掉（不同版本行为不一致）。这里做一次幂等重写，
	// 保证「输入之后」的最终值一定是我们要的 3 / range / min / color / flashing。
	// 代价只有 5 次 SetEntProp，每回合最多 4 把武器，可以忽略。
	SetEntProp(iEntity, Prop_Send, "m_iGlowType", GLOW_TYPE_CONSTANT);
	if (HasEntProp(iEntity, Prop_Send, "m_nGlowRange"))
		SetEntProp(iEntity, Prop_Send, "m_nGlowRange", iRange);
	if (HasEntProp(iEntity, Prop_Send, "m_nGlowRangeMin"))
		SetEntProp(iEntity, Prop_Send, "m_nGlowRangeMin", iMinRange);
	if (HasEntProp(iEntity, Prop_Send, "m_glowColorOverride"))
		SetEntProp(iEntity, Prop_Send, "m_glowColorOverride", GlowColorInt());
	if (HasEntProp(iEntity, Prop_Send, "m_bFlashing"))
		SetEntProp(iEntity, Prop_Send, "m_bFlashing", bFlashing ? 1 : 0);

	return true;
}

// 撤掉一个实体上的发光（武器被捡起 / 插件卸载时用）。
// 只动发光相关 netprop，绝不碰实体本身。
void ClearGlowProps(int iEntity)
{
	if (iEntity <= 0 || !IsValidEntity(iEntity))
		return;

	if (!HasEntProp(iEntity, Prop_Send, "m_iGlowType"))
		return;

	AcceptEntityInput(iEntity, "StopGlowing");

	if (HasEntProp(iEntity, Prop_Send, "m_bFlashing"))
		SetEntProp(iEntity, Prop_Send, "m_bFlashing", 0);
	if (HasEntProp(iEntity, Prop_Send, "m_glowColorOverride"))
		SetEntProp(iEntity, Prop_Send, "m_glowColorOverride", 0);
	if (HasEntProp(iEntity, Prop_Send, "m_nGlowRange"))
		SetEntProp(iEntity, Prop_Send, "m_nGlowRange", 0);
	if (HasEntProp(iEntity, Prop_Send, "m_nGlowRangeMin"))
		SetEntProp(iEntity, Prop_Send, "m_nGlowRangeMin", 0);

	SetEntProp(iEntity, Prop_Send, "m_iGlowType", GLOW_TYPE_NONE);
}

// 路径②：隐形假模型代理。失败返回 0。
int CreateGlowProxy(int iWeapon, int iRange, int iMinRange, bool bFlashing)
{
	// 模型名直接读武器实体自己的 m_ModelName（datamap CBaseEntity，offset 588），
	// 不硬编码武器模型表 —— 同 l4d_death_item_glow.sp:195。
	// 读之前先 HasEntProp 守卫，并校验读到的是真的模型路径（"models/" 开头），
	// 否则 DispatchKeyValue("model") 会拿到垃圾值、代理变成 ERROR 模型。
	char sModel[GLOW_MODEL_LEN];
	if (!HasEntProp(iWeapon, Prop_Data, "m_ModelName")
		|| GetEntPropString(iWeapon, Prop_Data, "m_ModelName", sModel, sizeof(sModel)) <= 1
		|| strncmp(sModel, "models/", 7) != 0)
	{
		if (g_hDebug.BoolValue)
			PrintToServer("[12v12 wdrop] glow: 武器 %d 的 m_ModelName 不是可用的模型路径（\"%s\"），无法建代理", iWeapon, sModel);
		return 0;
	}

	// 位置/角度用 datamap 的绝对坐标，比 m_vecOrigin/m_angRotation 可靠
	// （同 l4d_death_item_glow.sp:181-184）。
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
	DispatchKeyValue(iProxy, "solid", "0");

	if (!DispatchSpawn(iProxy))
	{
		LogError("[12v12 wdrop] glow: 代理实体 DispatchSpawn 失败（模型 %s）", sModel);
		RemoveEntity(iProxy);
		return 0;
	}

	// 先摆到武器所在位置。代理刻意**不**做 SetParent（原因见函数末尾），
	// 所以这一步就是它的最终位置，必须每次都设置。
	TeleportEntity(iProxy, vPos, vAng, NULL_VECTOR);
	SetEntityMoveType(iProxy, MOVETYPE_NONE);        // 不跟着重力掉下去

	// 不挡子弹 / 不挡路 / 不参与碰撞（照抄 l4d2_item_hint.sp:1090-1091）
	SetEntProp(iProxy, Prop_Send, "m_CollisionGroup", 0);
	SetEntProp(iProxy, Prop_Send, "m_nSolidType", 0);

	// 先写发光属性，再 StartGlowing —— 顺序与三个先例一致。
	if (!WriteGlowProps(iProxy, iRange, iMinRange, bFlashing))
	{
		// 连 prop_dynamic_override 都没有发光属性 —— 这套游戏/平台不支持轮廓，
		// 没有任何回退手段了，直接放弃（不留下无用实体）。
		if (g_hDebug.BoolValue)
			PrintToServer("[12v12 wdrop] glow: 代理实体 %d 也没有发光属性，放弃", iProxy);
		RemoveEntity(iProxy);
		return 0;
	}

	// 假模型本体必须完全看不见，只留轮廓。
	// 用 RENDER_TRANSCOLOR + alpha=0（而不是 RENDER_NONE）：l4d2_item_hint.sp:1104-1111
	// 的成熟做法就是这条路径 —— 轮廓走独立的发光渲染通路，不受本体 alpha 影响。
	SetEntityRenderMode(iProxy, RENDER_TRANSCOLOR);
	SetEntityRenderColor(iProxy, 0, 0, 0, 0);

	// 刻意**不**把代理 SetParent 到武器实体上：
	// SetParent 会保留子实体的「局部」坐标，父实体不在世界原点时子物体会被整体平移，
	// 轮廓就会画到别处（看起来还是「没发光」）。本插件的武器是 MOVETYPE_NONE，
	// 生成后不会移动，所以代理只要摆在同一坐标即可；武器被删/被捡起时由
	// OnEntityDestroyed / SDK_OnWeaponEquipPost 把代理解散，不会变成残留。

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
	g_bGlowProxyTried[iSlot] = false;
	g_bGlowSlotUsed[iSlot] = false;

	// 代理先关发光再删（同 l4d2_item_hint.sp:879-891 的清理顺序）
	if (iProxy > 0)
	{
		AcceptEntityInput(iProxy, "StopGlowing");
		RemoveEntity(iProxy);
	}

	// 宿主武器还活着时把直接发光撤掉。注意：绝不动武器实体本身，那是玩家的枪。
	if (iHost > 0 && bClearHostGlow)
		ClearGlowProps(iHost);
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

// 扫掉「targetname 是我们、但已经没有槽位认领」的代理（清理漏网时兜底）。
// 只处理自己打的 targetname，绝不碰别的插件的同类实体。
void SweepOrphanProxies()
{
	// 删掉实体后索引可能被引擎立刻复用，继续按原索引往后扫会漏实体，
	// 所以每次删完就从头重扫。加一个硬上限防止 RemoveEntity 失效时死循环。
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

		AcceptEntityInput(iEnt, "StopGlowing");
		RemoveEntity(iEnt);

		if (g_hDebug.BoolValue)
			PrintToServer("[12v12 wdrop] glow: 清理残留代理实体 %d", iEnt);

		iEnt = -1;                  // 从头重扫，避免索引复用漏扫
	}
}

// 这把武器实体是不是「在某个玩家身上的武器槽里」。
// 世界上的可拾取武器 m_hOwnerEntity 不一定是 -1（引擎行为不稳定），所以按武器槽查更靠谱：
// 遍历玩家 0=主武器槽 1=副武器槽 2=投掷物 3=医疗 4=电锯等近战槽。
bool IsWeaponHeldByPlayer(int iWeapon)
{
	if (iWeapon <= 0 || !IsValidEntity(iWeapon))
		return false;

	for (int i = 1; i <= MaxClients; i++)
	{
		// bot 也会自动捡枪，所以这里不能跳过 bot，否则 bot 捡走的发光枪会留在地上继续亮。
		if (!IsClientInGame(i))
			continue;

		for (int slot = 0; slot <= 4; slot++)
		{
			if (GetPlayerWeaponSlot(i, slot) == iWeapon)
				return true;
		}
	}

	return false;
}

// 一次性把所有「被玩家拿在身上的武器实体」收进一个列表。
// 巡检里每个槽位都调一次 IsWeaponHeldByPlayer 会是 16 × 101 × 5 次 native 调用，
// 这里改成每轮只扫一遍（101 × 5 次），槽位判断直接查这份列表。
// 每个玩家最多 5 个武器槽，所以 HELD_WEAPONS_MAX 个位置一定够（MAXPLAYERS=101）。
int CollectHeldWeapons(int[] aHeld, int iMaxLen)
{
	int iCount;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
			continue;

		for (int slot = 0; slot <= 4; slot++)
		{
			int iWeapon = GetPlayerWeaponSlot(i, slot);
			if (iWeapon <= 0 || iWeapon <= MaxClients)
				continue;
			if (iCount >= iMaxLen)
				return iCount;
			aHeld[iCount++] = iWeapon;
		}
	}
	return iCount;
}

bool IsInHeldList(const int[] aHeld, int iCount, int iWeapon)
{
	for (int i = 0; i < iCount; i++)
	{
		if (aHeld[i] == iWeapon)
			return true;
	}
	return false;
}

// 巡检：宿主没了就把整槽拆掉；代理没了就只清代理记录。
void SweepGlowSlots()
{
	int aHeld[HELD_WEAPONS_MAX];
	int iHeld = CollectHeldWeapons(aHeld, sizeof(aHeld));

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

		// 宿主还在，但已经被玩家拿在身上（例如挂 hook 之前就被捡走）→ 撤掉发光。
		// 判据用「武器槽里确实有这把枪」，比 m_hOwnerEntity 可靠：
		// 世界武器实体的 owner 不一定被引擎清成 -1，用 owner 判会误杀地上的枪。
		if (IsInHeldList(aHeld, iHeld, iHost))
		{
			DestroyGlowSlot(i, true, true);
			continue;
		}

		// 宿主还在但代理没了（引擎/别的插件清理）→ 只清代理记录
		if (g_iGlowProxyRef[i] != 0)
		{
			int iProxy = EntRefToEntIndex(g_iGlowProxyRef[i]);
			if (iProxy <= 0 || !IsValidEntity(iProxy))
			{
				g_iGlowProxyRef[i] = 0;
				g_iGlowProxyIdx[i] = 0;
			}
		}

		// 代理一次都没建起来（多半是创建时武器模型名还没写好）→ 这里补一次。
		// 只补一次：失败后 g_bGlowProxyTried 保持 true，不会变成无限重试刷实体。
		if (g_iGlowProxyRef[i] == 0 && !g_bGlowProxyTried[i] && g_hGlowProxy.IntValue != 2)
		{
			g_bGlowProxyTried[i] = true;
			int iRetry = CreateGlowProxy(iHost, RoundToNearest(g_hGlowRange.FloatValue),
										RoundToNearest(g_hGlowMinRange.FloatValue), g_hGlowFlashing.BoolValue);
			if (iRetry > 0)
			{
				g_iGlowProxyRef[i] = EntIndexToEntRef(iRetry);
				g_iGlowProxyIdx[i] = iRetry;
				if (g_hDebug.BoolValue)
					PrintToServer("[12v12 wdrop] glow: 槽 %d 补建代理成功（实体 %d）", i, iRetry);
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
	if (!HasAnyGlowSlot())
	{
		g_hGlowSweep = null;
		g_bGlowActive = false;
		return Plugin_Stop;
	}

	return Plugin_Continue;
}

// 全部撤掉待应用队列（换回合 / 换图 / 卸载时调用）：
// 队列里的武器可能已经被销毁，留着会让下一帧对无效实体做无用功。
void ClearPendingGlow()
{
	for (int i = 0; i < GLOW_SLOTS; i++)
		g_iPendingGlowRef[i] = 0;
	g_iPendingGlowCount = 0;
}

// 全量清理：换图 / 回合切换 / 插件卸载时调用。
// glow 从未生效时只有一次定时器判断就返回，保证 glow_enable=0 时行为与 1.0.0 一致。
void ClearAllGlow()
{
	ClearPendingGlow();

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

// 把一把刚生成的武器排进「下一帧再加发光」的队列。
void QueueGlow(int iWeapon)
{
	// 关掉发光时连队列都不进（保证 glow_enable=0 时零副作用）
	if (!g_hGlowEnable.BoolValue)
		return;

	if (iWeapon <= 0 || !IsValidEntity(iWeapon))
		return;

	if (g_iPendingGlowCount >= GLOW_SLOTS)
		return;

	g_iPendingGlowRef[g_iPendingGlowCount++] = EntIndexToEntRef(iWeapon);

	if (!g_bPendingGlowFrame)
	{
		g_bPendingGlowFrame = true;
		RequestFrame(Frame_ApplyPendingGlow);
	}
}

// 下一帧统一应用发光。用 ref 而不是裸索引：这一帧内实体索引有可能被复用。
void Frame_ApplyPendingGlow()
{
	g_bPendingGlowFrame = false;

	int iCount = g_iPendingGlowCount;
	g_iPendingGlowCount = 0;
	for (int i = 0; i < iCount; i++)
	{
		int iWeapon = EntRefToEntIndex(g_iPendingGlowRef[i]);
		g_iPendingGlowRef[i] = 0;
		if (iWeapon > 0 && IsValidEntity(iWeapon))
			ApplyGlowToWeapon(iWeapon);
	}
}

// 给一把刚生成的武器加发光。
void ApplyGlowToWeapon(int iWeapon)
{
	// 关掉发光时第一句就返回：不建实体、不写任何 netprop、不挂 hook（行为与 1.0.0 一致）
	if (!g_hGlowEnable.BoolValue)
		return;

	if (iWeapon <= 0 || !IsValidEntity(iWeapon))
		return;

	// 这一帧里已经被玩家捡走（进了武器槽）就别加发光了：本插件只为「地上的枪」
	// 加轮廓，加在玩家手上的枪会跟着玩家跑，还得等 5 秒巡检才清掉。
	if (IsWeaponHeldByPlayer(iWeapon))
	{
		if (g_hDebug.BoolValue)
			PrintToServer("[12v12 wdrop] glow: 武器 %d 已被玩家拿在身上，跳过发光", iWeapon);
		return;
	}

	// 同一把武器已经有槽位时先拆掉再重建：sm_wdropglow reapply 会重复调用本函数，
	// 不先拆就会给同一把枪叠出第二个代理、旧槽位变成没人管的残留。
	for (int i = 0; i < GLOW_SLOTS; i++)
	{
		if (g_bGlowSlotUsed[i] && g_iGlowHostIdx[i] == iWeapon)
		{
			DestroyGlowSlot(i, true, true);
			break;
		}
	}

	int iSlot = FindFreeGlowSlot();
	if (iSlot < 0)
	{
		if (g_hDebug.BoolValue)
			PrintToServer("[12v12 wdrop] glow: 槽位已满（%d），实体 %d 不加发光", GLOW_SLOTS, iWeapon);
		return;
	}

	// 每次生成武器时重新解析一次颜色 cvar，改颜色后下一把生成的武器立刻用新色。
	ParseGlowColor();

	int iMode     = g_hGlowProxy.IntValue;          // 0 双保险 / 1 只代理 / 2 只直接
	int iRange    = RoundToNearest(g_hGlowRange.FloatValue);
	int iMinRange = RoundToNearest(g_hGlowMinRange.FloatValue);
	bool bFlashing = g_hGlowFlashing.BoolValue;

	// 路径①：给武器实体本身写发光属性（模式 1 = 只用代理时跳过）
	bool bDirect = false;
	if (iMode != 1)
		bDirect = WriteGlowProps(iWeapon, iRange, iMinRange, bFlashing);

	// 路径②：隐形假模型代理（模式 2 = 只直接发光时跳过）
	int iProxy = 0;
	if (iMode != 2)
		iProxy = CreateGlowProxy(iWeapon, iRange, iMinRange, bFlashing);

	if (!bDirect && iProxy <= 0)
	{
		// 两条路都失败：武器照常可用，只是不亮。日志只打一次，避免每回合刷屏。
		if (!g_bGlowFailWarned)
		{
			g_bGlowFailWarned = true;
			LogError("[12v12 wdrop] glow: 武器实体与 prop_dynamic_override 代理都无法写入发光属性，本次不发光（武器仍正常生成）。请检查游戏版本是否支持 m_iGlowType。");
		}
		return;
	}

	g_iGlowHostRef[iSlot]  = EntIndexToEntRef(iWeapon);
	g_iGlowHostIdx[iSlot]  = iWeapon;
	g_iGlowProxyRef[iSlot] = (iProxy > 0) ? EntIndexToEntRef(iProxy) : 0;
	g_iGlowProxyIdx[iSlot] = iProxy;
	g_bGlowProxyTried[iSlot] = (iMode == 2) || (iProxy > 0);
	g_bGlowSlotUsed[iSlot] = true;
	g_bGlowActive = true;
	EnsureGlowSweep();
	EnsureClientGlowHooks();     // 捡枪时撤销发光所必需的 hook（只在真的亮过之后才挂）

	if (g_hDebug.BoolValue)
		PrintToServer("[12v12 wdrop] glow: 武器 %d（槽 %d）直接发光=%d 代理=%d，range=%d，min=%d，flashing=%d，颜色=%s",
			iWeapon, iSlot, bDirect ? 1 : 0, iProxy, iRange, iMinRange, bFlashing ? 1 : 0,
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
//   · 直接发光 → ClearGlowProps()，否则玩家会扛着一把发光的枪跑来跑去
//   · 代理方案 → 代理立刻删掉，否则地上会留下一把「看不见的枪」还在发光
//     （代理没有 SetParent，不会跟着玩家走，但会留在原地亮到回合结束）
// 先例：l4d_death_item_glow.sp:113-116
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
public void OnClientPutInServer(int client)
{
	if (!g_bGlowActive)
		return;

	EnsureClientGlowHooks();
}

// 玩家断开时清掉「这个 client 已挂 hook」的标记。
// 必须做：SDKHooks 在客户端断开时会自动摘掉它的全部 hook，但标记位不会自动复位，
// 不复位的话同一个 client 索引下次进服就再也不会重新挂 hook。
public void OnClientDisconnect(int client)
{
	if (client < 0 || client >= sizeof(g_bClientGlowHooked))
		return;

	g_bClientGlowHooked[client] = false;
}

// 武器被删（框架清理 / 换图）时的主动清理点。
// 注意：换图时本回调不保证对每个实体都跑到，所以 OnMapEnd / round_start / round_end
// 的全量清理 + 5 秒巡检都不能省。
public void OnEntityDestroyed(int entity)
{
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
			// 武器没了：代理必须跟着没。宿主正在销毁，所以不回头去动武器实体的 netprop。
			DestroyGlowSlot(i, true, false);
			return;
		}

		if (g_iGlowProxyIdx[i] == entity)
		{
			// 代理自己没了（被别人清理 / 自身被删）：只清代理记录，宿主武器可能还活着。
			g_iGlowProxyRef[i] = 0;
			g_iGlowProxyIdx[i] = 0;
			return;
		}
	}
}

// ---------------------------------------------------------------------------
// 排查用命令：sm_wdropglow        —— 打印每个槽位的武器/代理 + 实际写进去的发光属性
//              sm_wdropglow reapply —— 对当前槽位里的武器重新走一遍发光流程
// ---------------------------------------------------------------------------
public Action Cmd_GlowStatus(int client, int args)
{
	char sArg[16];
	if (args > 0)
		GetCmdArg(1, sArg, sizeof(sArg));

	bool bReapply = StrEqual(sArg, "reapply", false);

	// 1.10/1.12 的 ConVar methodmap 没有 StringValue 属性，只能走 GetString
	char sColor[GLOW_COLOR_LEN];
	g_hGlowColor.GetString(sColor, sizeof(sColor));

	ReplyToCommand(client, "[12v12 wdrop] v%s enable=%d glow_enable=%d mode=%d range=%d min=%d flashing=%d color=%s active=%d",
		PLUGIN_VERSION, g_hEnable.IntValue, g_hGlowEnable.IntValue, g_hGlowProxy.IntValue,
		RoundToNearest(g_hGlowRange.FloatValue), RoundToNearest(g_hGlowMinRange.FloatValue),
		g_hGlowFlashing.IntValue, sColor, g_bGlowActive ? 1 : 0);

	char sHostClass[64];
	for (int i = 0; i < GLOW_SLOTS; i++)
	{
		if (!g_bGlowSlotUsed[i])
			continue;

		int iHost  = (g_iGlowHostRef[i] != 0) ? EntRefToEntIndex(g_iGlowHostRef[i]) : 0;
		int iProxy = (g_iGlowProxyRef[i] != 0) ? EntRefToEntIndex(g_iGlowProxyRef[i]) : 0;

		sHostClass[0] = '\0';
		if (iHost > 0 && IsValidEntity(iHost))
			GetEntityClassname(iHost, sHostClass, sizeof(sHostClass));

		ReplyToCommand(client, "[12v12 wdrop] 槽%d 武器=%d(%s) 发光类型=%d 闪烁=%d | 代理=%d 发光类型=%d 闪烁=%d",
			i, iHost, sHostClass, ReadGlowInt(iHost, "m_iGlowType"), ReadGlowInt(iHost, "m_bFlashing"),
			iProxy, ReadGlowInt(iProxy, "m_iGlowType"), ReadGlowInt(iProxy, "m_bFlashing"));
	}

	if (bReapply)
	{
		// 先把要重做的武器抄进临时数组，再逐个应用：
		// ApplyGlowToWeapon() 会拆掉旧槽位再重新登记，边遍历边改槽位表容易漏/重。
		int aHosts[GLOW_SLOTS], iHostCount;
		for (int i = 0; i < GLOW_SLOTS; i++)
		{
			if (!g_bGlowSlotUsed[i] || g_iGlowHostRef[i] == 0)
				continue;
			int iHost = EntRefToEntIndex(g_iGlowHostRef[i]);
			if (iHost > 0 && IsValidEntity(iHost))
				aHosts[iHostCount++] = iHost;
		}

		for (int i = 0; i < iHostCount; i++)
			ApplyGlowToWeapon(aHosts[i]);

		ReplyToCommand(client, "[12v12 wdrop] 已对 %d 把武器重新应用发光", iHostCount);
	}

	return Plugin_Handled;
}

// 读一个实体的发光 netprop，实体无效 / 没有该属性时返回 -1
int ReadGlowInt(int iEntity, const char[] sProp)
{
	if (iEntity <= 0 || !IsValidEntity(iEntity))
		return -1;
	if (!HasEntProp(iEntity, Prop_Send, sProp))
		return -1;
	return GetEntProp(iEntity, Prop_Send, sProp);
}
