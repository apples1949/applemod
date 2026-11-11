/*
 * ============================================================================
 * L4D2 Bot Low HP Guard (12v12)
 *
 * 面向 applemod12v12 配置：只处理"非玩家操控的生还者"（AI 生还者 / bot）。
 *
 * 核心逻辑：
 *   当 AI 生还者的"总血量"（实血 m_iHealth + 虚血 / 临时血量 healthBuffer）
 *   合计 <= 阈值（1.2.0 起默认 10）时进入"守护状态"：
 *     1. 间歇性闪【白色】轮廓（参考 l4d2_tank_defib_revive / LMC_Black_and_White_Notifier
 *        的写法：m_iGlowType=3 + m_glowColorOverride + m_nGlowRange，
 *        1.1.0 起再补 m_nGlowRangeMin（witch_glow 同款）+ m_bFlashing，
 *        由定时器按固定节奏开关，形成"闪"的效果）；
 *     2. 免疫任何伤害（SDKHook_OnTakeDamage 直接 Handled，参考 rygive 的 OnTakeDamage）；
 *     3. 免疫任何特殊感染者的控制技能（舌头/扑击/骑乘/冲撞，走 Left4DHooks 的前置
 *        forward，参考 rygive 的 ReleaseControl 用法）；
 *     4. 若进入守护状态时已经被控住，立即解控（舌头拖拽 / 猎人扑倒 / 猴子骑乘 /
 *        牛冲撞与捶打）；
 *     5. 虚血冻结：守护期间虚血不再自然流失（按定时器把 healthBuffer 写回原值）。
 *
 *   另外（与血量无关的兜底）：
 *     未被玩家操控的生还者倒地后自动救起，每次数上限（默认 1 次 / 回合）。
 *     这条是为了应付"生还者被控倒地后玩家离开服务器，变成无人接管的 bot，
 *     没人来救"的情况。次数在回合开始时重置。
 *
 *   1.1.0 变更（按玩家反馈）：
 *     - 蓝色轮廓在游戏里看不出来 -> 改成白色（默认 "255 255 255"），并补上
 *       m_nGlowRangeMin（witch_glow 用的是 type3+color+rangeMin+range 四件套）；
 *       去掉 1.0.0 里那道 HasEntProp 门（它把整段发光静默跳过了），
 *       改成直接写属性（与 LMC / extendedsight / witch_glow 同款做法）。
 *     - 闪烁：默认同时写 m_bFlashing 让引擎闪，并由定时器按 0.9s 节奏开关兜底。
 *     - 新规则：场上"非玩家操控的生还者"数量 **超过** l4d2_bot_guard_max_bots（默认 3）时，
 *       免伤 / 免控 / 自动救起 全部不生效（轮廓仍保留，方便看出谁血量低）。
 *     - 新增排查命令 sm_botguard_status / sm_botguard_test（管理员）。
 *
 *   1.2.2 变更（玩家反馈修复）：
 *     - "其他生还者死完了、三个人机还无敌"：可守护数计算新增前置判定——
 *       场上没有任何"玩家操控的存活生还者"（真人全灭/全在旁观）时，可守护数直接 0。
 *     - "无敌状态还会被牛概率撞伤/概率扛走"：守护期间除了 SDKHook_OnTakeDamage，
 *       同时把 m_takedamage 置 0（引擎层免伤，rygive 的 god mode 同款），
 *       离开守护/插件卸载时恢复原值；并新增 L4D2_OnSlammedSurvivor 前置拦截，
 *       挡掉牛把守护中的生还者撞墙致残的那条路径。
 *
 *   1.3.4 变更（按需求）：计算「在场未倒地生还者」时排除终点安全屋内的生还者
 *     - 旧口径：未倒地生还者数 = 存活生还者总数 - 倒地人数（全队 team 2）。
 *     - 新口径：未倒地生还者数 = 存活 + 未倒地 + **不在本关终点安全屋**。
 *       终点安全屋用 Left4DHooks 的 L4D_IsInLastCheckpoint(client) 判定
 *       （left4dhooks.inc:3977-3984：用 info_changelevel 实体的 mins/maxs 做体积判定），
 *       它判的是"结束安全屋"，起点安全屋是另一个 native（L4D_IsInFirstCheckpoint），不会混淆。
 *     - 只改 ratio 的**分子**，分母仍是「存活生还者总数」（用户字面要求只排除这一项）。
 *       因此 ratio 只会持平或变小 → 可守护数只会持平或变少，不会因为这次改动变大。
 *     - 开关 l4d2_bot_guard_exclude_end_saferoom（默认 1），=0 完全回到旧口径。
 *     - 救援关（终局图）没有 info_changelevel 也就没有终点安全屋 → 一律不排除；
 *       native 拿不到时同样自动退回旧口径，不会出现"所有人都在安全屋、守护数为 0"的误判。
 *     - 已经进屋的人只是**不参与名额计算**，不会被强行取消守护（名额缩小时仍按
 *       UpdateGuardSet 的"已守护优先保留"规则处理，不额外踢人）。
 *
 *   1.3.3 变更（按需求）：守护中的 AI 生还者不得自行使用医疗物品
 *     - 接 Actions 扩展（可选依赖，缺失时插件照常工作、只跳过拦截）拦两个引擎 action：
 *         SurvivorTakePills —— 吃药(weapon_pain_pills) 与打针(weapon_adrenaline) 共用这一个
 *                              action（server.dll 里没有独立的 SurvivorUseAdrenaline）；
 *         SurvivorHealSelf  —— 给自己打包(weapon_first_aid_kit)。
 *       OnStart / Update 里直接 result.type = DONE 取消动作（Update 兜住"动作开始后
 *       才进入守护"的情况）；**不拦** SurvivorHealFriend / SurvivorGivePillsToFriend，
 *       那是给队友包扎/递药，守护中的人机照样可以做。
 *     - player_bot_replace 兜底（参考 l4d2_block_bot_pills.sp）：玩家离开、身体交给 bot
 *       接管时，bot 会"继承"玩家手里正在被使用的止痛药/肾上腺素并立刻吃掉。新 bot 满足
 *       ShouldGuard() 且手持 weapon_pain_pills / weapon_adrenaline 时，先 Kill 掉当前物品
 *       实体，再 CreateEntityByName + DispatchSpawn + EquipPlayerWeapon 换一件同款新物品，
 *       打断这次自动服用（物品种类与数量都不变，只是换了实体）。
 *     - 新增 cvar l4d2_bot_guard_block_items（默认 1，中文描述），sm_botguard_status
 *       增加一行显示物品拦截开关 + Actions 扩展是否可用。
 *
 *   1.3.2 变更（按需求）：提示音/文字节流(l4d2_bot_guard_warn_cooldown)默认 3 秒改 1 秒，
 *     打无敌 bot 的提示更及时。
 *
 *   1.3.1 修复（用户实测日志报"音效不存在"，但音效确实存在）：
 *     - 取消 RefreshWarnSound 里的 FileExists 门禁：srcds 端 FileExists（valve 文件系统 +
 *       普通文件系统）对 ui/beep_error01.wav 都返回 false，但 EmitSoundToClient 照样能播
 *       （库存音效由客户端本地文件提供）。现在不再刷假报错、也不再因此跳过预缓存/播放；
 *       诊断结果只由 sm_botguard_status / sm_botguard_warntest 打印。
 *
 *   1.3.0 变更（玩家反馈"打无敌 bot 一脸懵"）：
 *     - 玩家操控的特殊感染者攻击"守护中的 AI 生还者"时，给该特感玩家三渠道提示：
 *         ① 聊天框  ② PrintHintText 屏幕提示  ③ HUD 文字（SetHudTextParams/ShowHudText）
 *       三渠道各自有开关（l4d2_bot_guard_warn_chat / _hint / _hud），默认全开。
 *     - 同时播放"投票失败提示音"（默认 ui/beep_error01.wav，与本仓库 l4d_votes_5_VS
 *       的投票未通过音效同一个文件；可用 l4d2_bot_guard_warn_sound 换成任意 game_sounds 路径）。
 *     - 提示音与文字共用一条节流：同一名特感玩家默认 1 秒内只会被提示一次
 *       （l4d2_bot_guard_warn_cooldown，0 = 不节流），避免连点爪击时刷屏刷音。
 *     - 覆盖的触发点：SDKHook_OnTakeDamage（守护中吃伤害 / 保命判定）、
 *       舌头 / 扑击 / 骑乘 / 牛抱人 / 牛捶打 / 牛撞墙 六个前置拦截 forward。
 *     - 新增管理员命令 sm_botguard_warntest [目标]，不节流地演示一遍提示（验证音效是否存在）。
 *
 *   1.2.0 变更（四条新需求，全部实装）：
 *     - 需求1 移速：所有"未被玩家接管的生还者"（生还者队里 IsFakeClient 的客户端）
 *       移动速度按 m_flLaggedMovementValue 放大，
 *       倍率 = l4d2_bot_guard_bot_speed / l4d2_bot_guard_base_speed（默认 330 / 220 = 1.5）。
 *       只在存活、未倒地、未挂边时写；被真人接管 / 死亡 / 倒地 / 挂边 / 插件卸载
 *       立刻把 m_flLaggedMovementValue 恢复成 1.0，绝不残留。
 *       移速与"是否被守护"无关，也不受守护名额限制。
 *     - 需求2 守护上限：同一时刻最多 l4d2_bot_guard_max_count（默认 3）个未接管生还者
 *       处于守护状态（免疫 / 免控 / 自动救起那套）。**删除** 1.1.0 的
 *       "AI 生还者数量 > l4d2_bot_guard_max_bots 就全部关掉"旧规则（它和新阶梯矛盾），
 *       cvar 同时改名成 l4d2_bot_guard_max_count，语义 = 守护数量硬上限。
 *     - 需求3 守护名额：1.2.1 起改为**按比例**分配（1.2.0 的三条固定阶梯 cvar 已删除）
 *         base  = min(l4d2_bot_guard_max_count(3), 当前存活未接管生还者数量)
 *         ratio = 未倒地生还者数 / 存活生还者总数
 *         可守护数 = round(base * ratio)
 *       两条硬约束：
 *         ① 只剩 1 个（或 0 个）生还者没倒地 -> 取消最后一个守护，直接 0；
 *         ② 还有 >= 2 个生还者站着 -> 至少保留 1 个守护。
 *       推演（12 人满编）：
 *         9 真人 + 3 bot：倒地 0~2 -> 3；3~6 -> 2；7~10 -> 1；11+ -> 0
 *         10 真人 + 2 bot：倒地 0~3 -> 2；4~10 -> 1；11 -> 0
 *       名额分配：已处于守护状态的优先保留；剩余名额按「总血量升序 -> 客户端索引升序」
 *       挑选；名额变少时用 LeaveGuard 释放多余的人（连同发光 netprop 一起还原）。
 *     - 需求4 触发条件：阈值 l4d2_bot_guard_health 默认改为 10（总血量 <= 10 进入守护）；
 *       另外在 SDKHook_OnTakeDamage 里加"保命"：非玩家操控 + 存活未倒地 +
 *       本次伤害 >= 当前总血量 + 还有守护名额 -> 吃掉本次伤害（damage=0 / Handled）、
 *       把虚血清 0、实血设为阈值（默认 10）并立即进入守护状态。
 *       不在守护名额内的 bot 不做保命，照常掉血 / 倒地（否则全队 bot 永远打不死）。
 *
 * 安全设计（重要，改动前请先读）：
 *   - 守护状态只对"存活且未倒地"的 bot 生效。倒地后守护会自动关闭，
 *     避免"倒地 + 免伤 + 不能流血死亡"造成永久卡关；倒地由自动救起兜底
 *     （次数用完后按正常规则流血死亡）。
 *   - 守护结束时会把进入守护前的四个发光 netprop 原值写回去，
 *     避免污染其它插件的发光效果。
 *   - 移速是独立于守护状态的另一套状态（g_bSpeedApplied 记录写过谁），
 *     任何失效条件都会把 m_flLaggedMovementValue 写回 1.0。
 * ============================================================================
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>

// 1.3.3：Actions 扩展（可选依赖）—— 用来拦"守护中的 AI 生还者自行吃药/打针/打包"。
// 用 SourceMod 的标准写法把扩展降级成"可选"：REQUIRE_EXTENSIONS 未定义时，
// actions.inc 里的 __ext_actions 以 required=0 注册、并把原生函数全部 MarkNativeAsOptional，
// 于是扩展缺失时插件照常加载、其余功能照常工作，只有物品拦截不生效
// （OnPluginStart 里用 LibraryExists("actionslib") 判定，缺失时只打一条控制台提示）。
#undef REQUIRE_EXTENSIONS
#include <actions>
#define REQUIRE_EXTENSIONS

#define PLUGIN_VERSION		"1.3.4"

#define TEAM_SURVIVOR		2
#define TEAM_INFECTED		3

// m_iGlowType = 3 是 L4D2 的"常亮轮廓"（参考 l4d2_tank_defib_revive 的写法）
#define GLOW_TYPE_CONSTANT	3

// 移速：接管的判定用 IsFakeClient（真人接管 bot 后该客户端 IsFakeClient 会变 false），
// 倍率写进 m_flLaggedMovementValue（DT_BasePlayer，float，Prop_Send）
#define MOVEMENT_PROP		"m_flLaggedMovementValue"
#define MOVEMENT_DEFAULT	1.0

ConVar g_cvEnabled;			// 总开关
ConVar g_cvHealth;			// 触发阈值（实血 + 虚血 合计 <= 该值）
ConVar g_cvGlow;			// 是否闪白色轮廓
ConVar g_cvGlowColor;		// 轮廓颜色 "R G B"
ConVar g_cvGlowRange;		// 轮廓可见距离上限
ConVar g_cvGlowRangeMin;	// 轮廓可见距离下限（witch_glow 同款，不写这个有的图不显示）
ConVar g_cvGlowFlash;		// 是否额外写 m_bFlashing（交给引擎闪）
ConVar g_cvInterval;		// 检测/闪烁节奏（秒）
ConVar g_cvProtectInterval;	// 1.2.3：守护中 bot 的解控/血量回锁节奏（秒），与闪烁节奏分开
ConVar g_cvInvincible;		// 免疫任何伤害
ConVar g_cvBlockControl;	// 免疫特感控制 + 已控则解控
ConVar g_cvMaxCount;		// 1.2.0：同时处于守护状态的未接管生还者数量硬上限（原 max_bots）
ConVar g_cvExcludeEndSaferoom;	// 1.3.4：计算守护名额时排除终点安全屋内的生还者
ConVar g_cvBotSpeed;		// 1.2.0：未接管生还者移速（游戏单位，默认 330）
ConVar g_cvBaseSpeed;		// 1.2.0：正常走路速度基数（默认 220），倍率 = bot_speed / base_speed
ConVar g_cvReviveTimes;		// 每回合自动救起次数
ConVar g_cvReviveHealth;	// 自动救起后的血量
ConVar g_cvReviveDelay;		// 倒地后延迟多久救起（秒）
ConVar g_cvNotify;			// 自动救起时是否聊天框提示

// 1.3.0：玩家特感攻击"守护中的 AI 生还者"时的提示（提示音 + 三渠道文字）
ConVar g_cvWarn;			// 总开关
ConVar g_cvWarnCooldown;	// 同一名特感玩家的提示间隔下限（秒），默认 1.0
ConVar g_cvWarnSound;		// 提示音路径（相对 sound/ 目录）
ConVar g_cvWarnChat;		// 渠道① 聊天框
ConVar g_cvWarnHint;		// 渠道② PrintHintText
ConVar g_cvWarnHud;			// 渠道③ HUD 文字

// 1.3.3：守护中的 AI 生还者禁止自行吃药/打针/打包（需要 Actions 扩展）
ConVar g_cvBlockItems;	// 是否拦截"守护中自行使用医疗物品"

bool	g_bGuarded[MAXPLAYERS + 1];			// 当前是否处于守护状态（只看血量）
bool	g_bGlowProps[MAXPLAYERS + 1];		// 该客户端是否有完整的发光 netprop（仅作诊断用，不再作为写入门的开关）
int		g_iOrigGlowType[MAXPLAYERS + 1];	// 进入守护前的 m_iGlowType
int		g_iOrigGlowColor[MAXPLAYERS + 1];	// 进入守护前的 m_glowColorOverride
int		g_iOrigGlowRange[MAXPLAYERS + 1];	// 进入守护前的 m_nGlowRange
int		g_iOrigGlowRangeMin[MAXPLAYERS + 1];	// 进入守护前的 m_nGlowRangeMin
int		g_iOrigTakeDamage[MAXPLAYERS + 1];		// 进入守护前的 m_takedamage（1.2.2：守护期间引擎层免伤）
float	g_fTempStash[MAXPLAYERS + 1];		// 守护开始时冻结的虚血值
int		g_iReviveLeft[MAXPLAYERS + 1];		// 本回合剩余的自动救起次数
float	g_fTestGlowUntil[MAXPLAYERS + 1];	// 调试用：到该时刻前强制给该客户端上轮廓
bool	g_bSpeedApplied[MAXPLAYERS + 1];	// 1.2.0：本插件是否给该客户端写过移速（退出/失效时要还原）

float	g_fWarnLast[MAXPLAYERS + 1];		// 1.3.0：该特感玩家上次收到"打不动"提示的游戏时间
char	g_sWarnSound[PLATFORM_MAX_PATH];	// 1.3.0：解析后的提示音路径（空 = 不播放）

int		g_iGlowColorPacked;					// 打包后的颜色值（R | G<<8 | B<<16）
bool	g_bBlinkPhase;						// 闪烁相位（每 tick 取反）

// 1.3.3：Actions 扩展是否可用（LibraryExists("actionslib")，含晚加载/卸载刷新）。
// false 时物品拦截整段跳过，插件其余功能完全不受影响。
bool g_bActionsAvailable;

// 1.2.0：守护名额相关的统计值（每 tick 刷新，sm_botguard_status 直接读）
int		g_iAiSurvivors;						// 当前"存活且未被玩家接管"的生还者数量
int		g_iDownCount;						// 全队（team 2）倒地人数（m_isIncapacitated=1）
int		g_iGuardAllowed;					// 可守护数（1.2.1 起按比例计算，见 ComputeAllowedGuards）
int		g_iGuardCount;						// 当前实际处于守护状态的人数

Handle	g_hTickTimer;
Handle	g_hProtectTimer;					// 1.2.3：高频保护定时器（守护中的 bot 每 0.1s 解控 + 血量回锁）
int		g_iGuardHealth[MAXPLAYERS + 1];		// 守护期间锁定的实血值（挡住不走 OnTakeDamage 的掉血，例如 spitter 酸液）

// 1.3.4：终点安全屋排除的运行期状态
//   g_bNtvLastCheckpoint   L4D_IsInLastCheckpoint 是否可用（inc 里是 MarkNativeAsOptional）
//   g_bHasEndSaferoom      本图是否存在终点安全屋（存在 info_changelevel 实体才算）
//   g_bEndSaferoomChecked  本回合是否已经算过上面两项（换图 / round_start 会重置）
bool g_bNtvLastCheckpoint;
bool g_bHasEndSaferoom;
bool g_bEndSaferoomChecked;
bool g_bNtvLastCheckpointWarned;	// "native 不可用"的控制台提示只打一次

public Plugin myinfo =
{
	name        = "L4D2 Bot Low HP Guard (12v12)",
	author      = "apples1949",
	description = "非玩家操控的生还者总血量<=阈值时闪白色轮廓（可闪烁）/免疫伤害/免疫特感控制/被控即解控，并支持每回合一次自动救起；1.2.0 追加未接管生还者移速与守护数量阶梯；1.3.0 追加玩家特感攻击守护中的人机时的投票失败提示音+三渠道无敌提示（1.3.2 起节流默认 1 秒）；1.3.3 追加守护中禁止吃药/打包/打针（需 Actions 扩展）；1.3.4 计算在场未倒地生还者时排除终点安全屋内的生还者",
	version     = PLUGIN_VERSION,
	url         = "N/A"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	if (GetEngineVersion() != Engine_Left4Dead2)
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 2.");
		return APLRes_SilentFailure;
	}

	return APLRes_Success;
}

public void OnPluginStart()
{
	g_cvEnabled = CreateConVar("l4d2_bot_guard_enabled",
		"1",
		"总开关. 0=关闭, 1=启用.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// 1.2.0：触发阈值默认 25 -> 10（总血量 = 实血 + 虚血）
	g_cvHealth = CreateConVar("l4d2_bot_guard_health",
		"10",
		"AI 生还者总血量(实血 + 虚血)低于或等于该值时进入守护状态（1.2.0 起默认 10）.",
		FCVAR_NOTIFY, true, 1.0, true, 200.0);

	g_cvGlow = CreateConVar("l4d2_bot_guard_glow",
		"1",
		"守护状态下是否间歇闪蓝色轮廓. 0=关闭, 1=启用.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvGlowColor = CreateConVar("l4d2_bot_guard_glow_color",
		"255 255 255",
		"轮廓颜色, 格式 \"R G B\"（默认 255 255 255 = 白色）.");

	g_cvGlowRange = CreateConVar("l4d2_bot_guard_glow_range",
		"800",
		"轮廓可见距离上限（游戏单位）.",
		FCVAR_NOTIFY, true, 0.0, true, 10000.0);

	g_cvGlowRangeMin = CreateConVar("l4d2_bot_guard_glow_range_min",
		"0",
		"轮廓可见距离下限（游戏单位）: 0=从贴身就开始显示（与 witch_glow 同样写 m_nGlowRangeMin）.",
		FCVAR_NOTIFY, true, 0.0, true, 10000.0);

	g_cvGlowFlash = CreateConVar("l4d2_bot_guard_glow_flash",
		"1",
		"1=同时写 m_bFlashing 让引擎自己闪（默认）；0=只靠定时器开关轮廓来闪.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvInterval = CreateConVar("l4d2_bot_guard_interval",
		"0.9",
		"检测与闪烁节奏（秒）: 每该间隔检查一次状态并切换一次轮廓开关（默认 0.9 = 约 1.1Hz 闪烁，太快的开关会让人以为没光）.",
		FCVAR_NOTIFY, true, 0.05, true, 5.0);

	// 1.2.3：上面那条是"状态检测 + 闪烁"节奏（0.9s），拿来做保护太慢 ——
	// charger 捶打/扛走、spitter 酸液在这 0.9s 里仍然能生效。所以单独开一条高频线程，
	// 只做"立刻解控 + 血量回锁"两件事，开销极小（每个守护中的 bot 两次属性读写）。
	g_cvProtectInterval = CreateConVar("l4d2_bot_guard_protect_interval",
		"0.1",
		"守护中 bot 的解控/血量回锁节奏（秒）。默认 0.1：被 charger 捶打/扛走、被 spitter 酸液掉血都会在 0.1 秒内被纠正.",
		FCVAR_NOTIFY, true, 0.02, true, 1.0);

	g_cvInvincible = CreateConVar("l4d2_bot_guard_invincible",
		"1",
		"守护状态下免疫任何伤害. 0=关闭, 1=启用.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvBlockControl = CreateConVar("l4d2_bot_guard_block_control",
		"1",
		"守护状态下免疫特感控制(舌头/扑击/骑乘/冲撞), 且已被控时立即解控. 0=关闭, 1=启用.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// 1.2.0：l4d2_bot_guard_max_bots 改名成 l4d2_bot_guard_max_count，
	// 语义从"AI 数量超过就全关"改成"同时守护的数量硬上限"
	g_cvMaxCount = CreateConVar("l4d2_bot_guard_max_count",
		"3",
		"同时处于守护状态的未接管生还者数量硬上限（1.2.0 由 l4d2_bot_guard_max_bots 改名而来）。默认 3.",
		FCVAR_NOTIFY, true, 0.0, true, 24.0);

	// 1.3.4：计算「在场未倒地生还者」时排除已经进入终点安全屋的人
	// （只影响分子，分母仍是存活生还者总数；关掉即完全回到 1.3.3 的口径）
	g_cvExcludeEndSaferoom = CreateConVar("l4d2_bot_guard_exclude_end_saferoom",
		"1",
		"计算可守护名额时，是否把「已经进入本关终点安全屋」的生还者从『未倒地生还者数』里排除. 1=排除(默认): 进屋的人不再计入分子(分母仍是存活生还者总数), 可守护数只会持平或变少; 0=旧口径(存活 - 倒地). 救援关/终局图没有终点安全屋时自动不排除.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// 1.2.1：可守护数改为"按比例"计算（见 ComputeAllowedGuards），
	// 1.2.0 的三条固定阶梯 cvar（down_tier1/2/3）已删除

	// 1.2.0：未接管生还者移速（写 m_flLaggedMovementValue = bot_speed / base_speed）
	g_cvBotSpeed = CreateConVar("l4d2_bot_guard_bot_speed",
		"330",
		"未被玩家接管的生还者移动速度（游戏单位）。正常走路 220，默认 330 = 1.5 倍.",
		FCVAR_NOTIFY, true, 0.0, true, 1000.0);

	g_cvBaseSpeed = CreateConVar("l4d2_bot_guard_base_speed",
		"220",
		"正常走路速度基数（游戏单位），用于换算 m_flLaggedMovementValue 倍率。默认 220.",
		FCVAR_NOTIFY, true, 1.0, true, 1000.0);

	g_cvReviveTimes = CreateConVar("l4d2_bot_guard_revive_times",
		"1",
		"AI 生还者每回合可自动救起次数（0=关闭自动救起）.",
		FCVAR_NOTIFY, true, 0.0, true, 10.0);

	g_cvReviveHealth = CreateConVar("l4d2_bot_guard_revive_health",
		"30",
		"自动救起后设置的血量.",
		FCVAR_NOTIFY, true, 1.0, true, 100.0);

	g_cvReviveDelay = CreateConVar("l4d2_bot_guard_revive_delay",
		"1.0",
		"AI 生还者倒地后延迟多少秒自动救起.",
		FCVAR_NOTIFY, true, 0.0, true, 30.0);

	g_cvNotify = CreateConVar("l4d2_bot_guard_notify",
		"1",
		"自动救起时是否在聊天框提示. 0=关闭, 1=启用.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// 1.3.0：玩家特感打守护中的 bot 时，提示音 + 三渠道文字
	g_cvWarn = CreateConVar("l4d2_bot_guard_warn",
		"1",
		"玩家特感攻击守护中的 AI 生还者时, 是否给该特感玩家提示(提示音 + 三渠道文字). 0=关闭, 1=启用.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvWarnCooldown = CreateConVar("l4d2_bot_guard_warn_cooldown",
		"1.0",
		"同一名特感玩家两次提示的最小间隔(秒). 默认 1.0 = 1 秒, 防止连点爪击时提示音刷屏. 0 = 不节流.",
		FCVAR_NOTIFY, true, 0.0, true, 60.0);

	g_cvWarnSound = CreateConVar("l4d2_bot_guard_warn_sound",
		"ui/beep_error01.wav",
		"提示音路径(相对游戏 sound/ 目录). 默认 ui/beep_error01.wav = 服务器现有投票插件[l4d_votes_5_VS]投票未通过用的同一个音效; 留空 = 不播放.",
		FCVAR_NOTIFY);

	g_cvWarnChat = CreateConVar("l4d2_bot_guard_warn_chat",
		"1",
		"提示渠道①: 聊天框(只发给攻击的特感玩家). 0=关闭, 1=启用.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvWarnHint = CreateConVar("l4d2_bot_guard_warn_hint",
		"1",
		"提示渠道②: 屏幕提示(PrintHintText, 只发给攻击的特感玩家). 0=关闭, 1=启用.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvWarnHud = CreateConVar("l4d2_bot_guard_warn_hud",
		"1",
		"提示渠道③: HUD 文字(ShowHudText, 画面上方, 只发给攻击的特感玩家). 0=关闭, 1=启用.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// 按 workspace 约定：不生成插件 cfg（不用 AutoExecConfig），
	// 全部参数由 applemod12v12 的 confogl_addcvar 下发
	ParseGlowColor();
	// 1.3.3：守护中的 AI 生还者禁止自行吃药/打针/打包
	// （超管想让人机自己吃药时把它关掉；关闭不影响其它任何功能）
	g_cvBlockItems = CreateConVar("l4d2_bot_guard_block_items",
		"1",
		"守护中的 AI 生还者是否禁止自行使用医疗物品(吃药/打针/打包). 0=关闭, 1=启用. 需要服务器的 Actions 扩展.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvGlowColor.AddChangeHook(OnConVarChanged);
	g_cvInterval.AddChangeHook(OnConVarChanged);
	g_cvProtectInterval.AddChangeHook(OnConVarChanged);
	// 1.2.0：移速倍率改了要立刻重写一遍（不必等下一 tick）
	g_cvBotSpeed.AddChangeHook(OnConVarChanged);
	g_cvBaseSpeed.AddChangeHook(OnConVarChanged);
	// 1.3.0：提示音路径改了要重新解析/预缓存
	g_cvWarnSound.AddChangeHook(OnConVarChanged);

	// 1.3.3：Actions 扩展是**可选**的 —— 没有它插件其余功能全部照常，
	// 只是不拦"守护中的 AI 生还者自行吃药/打针/打包"（绝不 SetFailState）
	g_bActionsAvailable = LibraryExists("actionslib");

	if (!g_bActionsAvailable)
	{
		PrintToServer("[BotGuard] 未检测到 Actions 扩展 (actionslib)：守护中的 AI 生还者仍会自行吃药/打针/打包。插件其余功能不受影响。");
	}

	HookEvent("player_incapacitated", Event_PlayerIncapacitated, EventHookMode_Post);
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);

	// 1.3.3：玩家离开、身体被 bot 接管时，打断"继承"过来的自动吃药/打针
	HookEvent("player_bot_replace", Event_PlayerBotReplace, EventHookMode_Post);

	// 晚加载：已经连进来的客户端也要补挂伤害钩子
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
			OnClientPutInServer(i);
	}

	// 排查/验证用（不给玩家用）：状态查询 + 强制上轮廓
	RegAdminCmd("sm_botguard_status", Cmd_Status, ADMFLAG_GENERIC,
		"打印低血 AI 生还者守护状态：血量、存活未接管数量、倒地数、阶梯值、可守护数、守护名单、移速");
	RegAdminCmd("sm_botguard_test", Cmd_TestGlow, ADMFLAG_GENERIC,
		"强制给目标客户端闪轮廓，用于确认发光是否可见: sm_botguard_test <#userid|名字> [秒]");

	// 1.3.0：不节流地演示一遍"打守护 bot"的提示（提示音 + 三渠道文字），用来验证音效是否存在
	RegAdminCmd("sm_botguard_warntest", Cmd_WarnTest, ADMFLAG_GENERIC,
		"演示一次守护拦截提示(提示音+三渠道文字), 不节流: sm_botguard_warntest [目标 #userid|名字]，默认发给自己");

	// 1.3.4：终点安全屋排除的运行期条件先算一次（换图/每回合由 OnMapStart + round_start 重算）
	RefreshEndSaferoomState();

	StartTickTimer();
	StartProtectTimer();
}

// 1.3.3：Actions 扩展晚加载 / 被卸载时刷新可用标记。
// 插件本体绝不因为扩展缺失而 SetFailState —— 只把物品拦截整段跳过。
public void OnLibraryAdded(const char[] name)
{
	if (strcmp(name, "actionslib") == 0)
		g_bActionsAvailable = true;
}

public void OnLibraryRemoved(const char[] name)
{
	if (strcmp(name, "actionslib") == 0)
		g_bActionsAvailable = false;
}

// 1.3.0：配置(cfg)下发完后再解析一次提示音路径，保证拿到的是 confogl_addcvar 之后的值
public void OnConfigsExecuted()
{
	RefreshWarnSound(false);
}

public void OnMapStart()
{
	g_bBlinkPhase = false;
	g_iAiSurvivors = 0;
	g_iDownCount = 0;
	g_iGuardAllowed = 0;
	g_iGuardCount = 0;

	// 1.3.4：换图后终点安全屋实体重建，等下一次 round_start 重新判定
	g_bHasEndSaferoom = false;
	g_bEndSaferoomChecked = false;

	// 1.3.0：解析 + 预缓存提示音（换图后重置节流时间戳）
	RefreshWarnSound(true);

	for (int i = 0; i <= MaxClients; i++)
	{
		g_bGuarded[i] = false;
		g_fTempStash[i] = 0.0;
		// 换图后实体重建，m_flLaggedMovementValue 自然是 1.0，只需要清掉标记
		g_bSpeedApplied[i] = false;
		g_fWarnLast[i] = 0.0;
	}
}

public void OnPluginEnd()
{
	if (g_hTickTimer != null)
	{
		delete g_hTickTimer;
		g_hTickTimer = null;
	}

	if (g_hProtectTimer != null)
	{
		delete g_hProtectTimer;
		g_hProtectTimer = null;
	}

	// 卸载时把轮廓恢复成进入守护前的样子，避免残留
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && g_bGuarded[i])
		{
			SetEntProp(i, Prop_Send, "m_iGlowType", g_iOrigGlowType[i]);
			SetEntProp(i, Prop_Send, "m_glowColorOverride", g_iOrigGlowColor[i]);
			SetEntProp(i, Prop_Send, "m_nGlowRange", g_iOrigGlowRange[i]);
			SetEntProp(i, Prop_Send, "m_nGlowRangeMin", g_iOrigGlowRangeMin[i]);

			// 1.2.2：卸载时也必须把引擎层受击状态恢复，否则会留下永久 god mode
			SetEntProp(i, Prop_Data, "m_takedamage", g_iOrigTakeDamage[i] > 0 ? g_iOrigTakeDamage[i] : 2, 1);

			if (g_cvGlowFlash.BoolValue)
				SetEntProp(i, Prop_Send, "m_bFlashing", 0, 1);

			g_bGuarded[i] = false;
		}
	}

	// 1.2.0：卸载时把移速还原成 1.0，绝不给后来的插件留一份 1.5 倍速
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && g_bSpeedApplied[i])
		{
			SetEntPropFloat(i, Prop_Send, MOVEMENT_PROP, MOVEMENT_DEFAULT);
			g_bSpeedApplied[i] = false;
		}
	}
}

public void OnClientPutInServer(int client)
{
	g_bGuarded[client] = false;
	g_bGlowProps[client] = false;
	g_fTempStash[client] = 0.0;
	g_iReviveLeft[client] = g_cvReviveTimes.IntValue;
	g_bSpeedApplied[client] = false;
	g_fWarnLast[client] = 0.0;

	// 每个客户端都要挂伤害钩子（r ygive 同款做法：进服即挂）
	SDKHook(client, SDKHook_OnTakeDamage, Hook_OnTakeDamage);
}

public void OnClientDisconnect(int client)
{
	g_bGuarded[client] = false;
	g_bGlowProps[client] = false;
	g_fTempStash[client] = 0.0;
	g_iReviveLeft[client] = 0;
	// 客户端已经离开，实体随后销毁，不需要再写属性，只清标记
	g_bSpeedApplied[client] = false;
	g_fWarnLast[client] = 0.0;
}

public void OnConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (convar == g_cvGlowColor)
	{
		ParseGlowColor();
		for (int i = 1; i <= MaxClients; i++)
		{
			if (g_bGuarded[i])
				ApplyGlow(i, true);
		}
	}
	else if (convar == g_cvInterval)
	{
		StartTickTimer();
	}
	else if (convar == g_cvProtectInterval)
	{
		StartProtectTimer();
	}
	else if (convar == g_cvBotSpeed || convar == g_cvBaseSpeed)
	{
		// 1.2.0：倍率变了立刻生效，不用等下一 tick
		UpdateBotSpeed();
	}
	else if (convar == g_cvWarnSound)
	{
		// 1.3.0：换提示音后立刻重新解析（这张图已经开过，不再预缓存，音效文件本身是库存音效）
		RefreshWarnSound(false);
	}
}

void StartTickTimer()
{
	if (g_hTickTimer != null)
	{
		delete g_hTickTimer;
		g_hTickTimer = null;
	}

	float fInterval = g_cvInterval.FloatValue;
	if (fInterval < 0.05)
		fInterval = 0.05;

	g_hTickTimer = CreateTimer(fInterval, Timer_Tick, _, TIMER_REPEAT);
}

void StartProtectTimer()
{
	if (g_hProtectTimer != null)
	{
		delete g_hProtectTimer;
		g_hProtectTimer = null;
	}

	float fInterval = g_cvProtectInterval.FloatValue;
	if (fInterval < 0.02)
		fInterval = 0.02;

	g_hProtectTimer = CreateTimer(fInterval, Timer_Protect, _, TIMER_REPEAT);
}

/* 1.2.3：高频保护（默认 0.1s 一次）。守护中的 bot：
   ① 立刻解掉任何控制 —— charger 的「捶打/扛走」引擎没有"开始捶打"的前置 forward 可拦，
      只能靠这条快线程抢在伤害与位移之前打断（舌头/扑击/骑乘/撞墙另有一级前置拦截）；
   ② 血量回锁 —— spitter 酸液这类伤害不一定经过 OnTakeDamage（SDKHook 拦不到），
      这里把实血顶回进入守护时的值，保证"守护中绝不掉血"。 */
public Action Timer_Protect(Handle timer)
{
	if (!g_cvEnabled.BoolValue)
		return Plugin_Continue;

	bool bBlockControl = g_cvBlockControl.BoolValue;
	bool bInvincible   = g_cvInvincible.BoolValue;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!g_bGuarded[i] || !IsClientInGame(i) || !IsPlayerAlive(i))
			continue;

		if (bBlockControl)
			ReleaseControl(i);

		if (bInvincible && g_iGuardHealth[i] > 0 && GetClientHealth(i) < g_iGuardHealth[i])
			SetEntityHealth(i, g_iGuardHealth[i]);
	}

	return Plugin_Continue;
}

// ============================================================================
// 状态机
// ============================================================================

public Action Timer_Tick(Handle timer)
{
	// 1.3.4：本回合还没判定过「终点安全屋」（插件晚加载 / 漏接 round_start）→ 这里补一次，
	// 每回合只会真正扫一次实体（g_bEndSaferoomChecked 为 true 后直接跳过）。
	if (!g_bEndSaferoomChecked)
		RefreshEndSaferoomState();

	// 1.2.1：先统计"存活未接管生还者数量"与"倒地人数"，再按比例算出可守护名额。
	// 1.1.0 的"AI 生还者数量 > max_bots 就全部关掉"规则与 1.2.0 的固定阶梯都已删除。
	g_iAiSurvivors = CountAiSurvivors();
	g_iDownCount = CountDownedSurvivors();
	g_iGuardAllowed = ComputeAllowedGuards();

	// 第一步：先释放"已经不该守护"的人（死亡 / 倒地 / 被真人接管 / 血量回升 / 总开关关闭）
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
		{
			g_bGuarded[i] = false;
			continue;
		}

		if (g_bGuarded[i] && !ShouldGuard(i))
			LeaveGuard(i);
	}

	// 第二步：按名额重新分配（已守护优先保留，其余按 总血量升序 -> 索引升序）
	UpdateGuardSet(g_iGuardAllowed);

	g_iGuardCount = CountGuarded();

	// 第三步：守护中的每个 bot 做维护 —— 虚血冻结 + 已被控则立即解控
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !g_bGuarded[i])
			continue;

		// 虚血冻结：引擎会按时间自然扣减 healthBuffer，
		// 这里按节奏把它写回守护开始时的值（L4D_SetTempHealth 同时刷新 m_healthBufferTime）
		if (g_fTempStash[i] > 0.0 && L4D_GetTempHealth(i) < g_fTempStash[i])
			L4D_SetTempHealth(i, g_fTempStash[i]);

		// 已被控住的立即解控（"被控时血量掉到阈值及以下就取消控制"）
		if (g_cvBlockControl.BoolValue)
			ReleaseControl(i);
	}

	// 第四步：移速 —— 所有未接管生还者都生效，与是否被守护无关，也不受名额限制
	UpdateBotSpeed();

	// 间歇闪烁：每 tick 翻转一次相位（闪烁不受名额限制影响，只受 g_cvGlow 控制）
	if (g_cvGlow.BoolValue)
	{
		g_bBlinkPhase = !g_bBlinkPhase;

		float fNow = GetGameTime();

		for (int i = 1; i <= MaxClients; i++)
		{
			if (!IsClientInGame(i))
				continue;

			if (g_bGuarded[i] || fNow < g_fTestGlowUntil[i])
				ApplyGlow(i, g_bBlinkPhase);
		}
	}

	return Plugin_Continue;
}

// ============================================================================
// 1.2.0：守护名额统计与分配
// ============================================================================

// 场上非玩家操控的生还者数量（只看存活、在生还者队的 bot）
// 1.2.0：同时作为"当前存活未接管生还者数量"，参与可守护数的 min() 收敛
int CountAiSurvivors()
{
	int iCount = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
			continue;

		if (GetClientTeam(i) != TEAM_SURVIVOR)
			continue;

		if (!IsFakeClient(i))
			continue;

		if (!IsPlayerAlive(i))
			continue;

		iCount++;
	}

	return iCount;
}

// 1.2.0：全队（team 2）里 m_isIncapacitated=1 的人数 —— 阶梯的唯一输入
int CountDownedSurvivors()
{
	int iCount = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
			continue;

		// 真人、bot 都算（需求写的是"全队 team 2 里 m_isIncapacitated=1 的人数"）
		if (GetClientTeam(i) != TEAM_SURVIVOR)
			continue;

		if (IsIncapacitated(i))
			iCount++;
	}

	return iCount;
}

// 1.2.1：全队（team 2）存活生还者数量（真人 + bot，含倒地者）
int CountAliveSurvivors()
{
	int iCount = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
			continue;

		if (GetClientTeam(i) != TEAM_SURVIVOR)
			continue;

		if (IsPlayerAlive(i))
			iCount++;
	}

	return iCount;
}

// 1.2.2：全队（team 2）存活且"玩家操控"的生还者数量（排除 bot）。
// 用来判定"真人已经全灭/全在旁观"——那种情况下不该再给 AI 无敌。
int CountAliveHumanSurvivors()
{
	int iCount = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
			continue;

		if (GetClientTeam(i) != TEAM_SURVIVOR)
			continue;

		if (IsFakeClient(i))
			continue;

		if (IsPlayerAlive(i))
			iCount++;
	}

	return iCount;
}

// ============================================================================
// 1.3.4：终点安全屋排除
// ============================================================================

// 该客户端此刻是否在「本关终点安全屋」的体积内。
//
// 判定用 Left4DHooks 的 L4D_IsInLastCheckpoint(client)
// （left4dhooks.inc:3977-3984：@brief Returns true when the specified Survivor or Special
//   Infected is in the ending checkpoint area；@remarks This uses the "info_changelevel"
//   entity, and checks the player is within the vector mins and vector maxs of the entity）。
// 也就是关卡终点安全屋的触发体积：站在门口体积外、门还没开、还没走进去都不算在屋里。
// 起点安全屋是另一个 native（L4D_IsInFirstCheckpoint），两者不会混淆。
//
// 三层安全门（任何一条不满足就退回旧口径，绝不硬判）：
//   ① cvar l4d2_bot_guard_exclude_end_saferoom = 0；
//   ② 运行期拿不到 L4D_IsInLastCheckpoint（inc 里 MarkNativeAsOptional，left4dhooks 缺失/太旧）；
//   ③ 本图没有 info_changelevel → 是救援关/终局图，没有"终点安全屋"这个概念。
bool IsInEndSaferoom(int client)
{
	if (!g_cvExcludeEndSaferoom.BoolValue)
		return false;

	if (!g_bNtvLastCheckpoint || !g_bHasEndSaferoom)
		return false;

	return L4D_IsInLastCheckpoint(client);
}

// 1.3.4：新口径「在场未倒地生还者数」= 存活 + 未倒地 + 不在终点安全屋。
// 它就是 ComputeAllowedGuards() 里 ratio 的分子（旧写法是 CountAliveSurvivors() - CountDownedSurvivors()）。
// cvar 关掉 / native 不可用 / 本图没有终点安全屋时，结果与旧写法完全一致。
//
// 注意：这里**不**把已经进屋的人从守护状态里踢出去 —— 本函数只决定名额，
// 名额分配仍走 UpdateGuardSet（已守护者优先保留）。见开头 1.3.4 的说明。
int CountStandingSurvivors()
{
	int iCount = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
			continue;

		if (GetClientTeam(i) != TEAM_SURVIVOR)
			continue;

		if (!IsPlayerAlive(i))
			continue;

		// 倒地："未倒地"的定义与旧口径完全一致（只看 m_isIncapacitated，挂边不算倒地）
		if (IsIncapacitated(i))
			continue;

		// 1.3.4：已经进了终点安全屋的人不算"在场"，不参与名额计算
		if (IsInEndSaferoom(i))
			continue;

		iCount++;
	}

	return iCount;
}

// 1.3.4：只给 sm_botguard_status 用 —— 有多少"存活未倒地"的人被终点安全屋排除掉了。
// 与 CountStandingSurvivors 的跳过条件严格对应，保证 存活未倒地 - 排除 = 在场未倒地。
int CountExcludedInEndSaferoom()
{
	int iCount = 0;

	if (!g_cvExcludeEndSaferoom.BoolValue || !g_bNtvLastCheckpoint || !g_bHasEndSaferoom)
		return 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
			continue;

		if (GetClientTeam(i) != TEAM_SURVIVOR)
			continue;

		if (!IsPlayerAlive(i) || IsIncapacitated(i))
			continue;

		if (L4D_IsInLastCheckpoint(i))
			iCount++;
	}

	return iCount;
}

// 1.3.4：刷新「native 在不在 / 本图有没有终点安全屋」这两个运行期条件。
// 每回合（round_start）重算一次即可：那时地图实体一定已经加载完（和 1.2.1 的区域侦测同理）。
//
// 为什么用 info_changelevel 来判断"有没有终点安全屋"：
//   L4D_IsInLastCheckpoint 本身就是拿 info_changelevel 的 mins/maxs 做体积判定
//   （见上面 native 的 @remarks），所以图里没有这个实体时它必然对所有人返回 false。
//   救援关/终局图只有 trigger_finale / 救援载具，没有 info_changelevel，在这里被识别出来，
//   于是不排除任何人 —— 避免"全员被判成在安全屋 → 可守护数变 0"的误判。
void RefreshEndSaferoomState()
{
	g_bEndSaferoomChecked = true;
	g_bHasEndSaferoom = false;

	// native 可用性每回合复核一次：left4dhooks 可能比本插件晚注册 native，
	// OnPluginStart 那一刻查不到，等它注册完成后这里就能拿到。
	g_bNtvLastCheckpoint = (GetFeatureStatus(FeatureType_Native, "L4D_IsInLastCheckpoint") == FeatureStatus_Available);

	if (!g_bNtvLastCheckpoint)
	{
		// 只有真的要用"排除"功能时才提示；cvar=0 的服不该看到这条噪音
		if (g_cvExcludeEndSaferoom.BoolValue && !g_bNtvLastCheckpointWarned)
		{
			g_bNtvLastCheckpointWarned = true;
			PrintToServer("[BotGuard] 未检测到 L4D_IsInLastCheckpoint（Left4DHooks 缺失或版本太旧）：l4d2_bot_guard_exclude_end_saferoom 不生效，仍按旧口径（存活 - 倒地）计算守护名额。");
		}

		return;
	}

	// 不管 cvar 当前开没开都记下"本图有没有终点安全屋"，
	// 这样管理员运行中把 cvar 从 0 改成 1 也能立刻生效（不用等下一回合）。
	if (FindEntityByClassname(-1, "info_changelevel") != -1)
		g_bHasEndSaferoom = true;
}

// 1.2.1：可守护数 —— 按比例算（取代 1.2.0 的三条固定阶梯）
//
//   基础名额 base = min(max_count, 当前存活未接管生还者数量)
//   比例 ratio   = 未倒地生还者数 / 存活生还者总数
//   可守护数     = round(base * ratio)
//
// 两条硬约束（用户明确要求）：
//   ① 只剩 1 个（或 0 个）生还者没倒地 -> 取消最后一个守护，直接 0；
//   ② 还有 >= 2 个生还者站着 -> 至少保留 1 个守护（避免"全员都在爬"时保护突然清零）。
//
// 推演（12 人满编，base = 未接管生还者数，取 min(3, base)）：
//   9 真人 + 3 bot：倒地 0~2 -> 3；3~6 -> 2；7~10 -> 1；11+ -> 0
//   10 真人 + 2 bot：倒地 0~3 -> 2；4~10 -> 1；11 -> 0
int ComputeAllowedGuards()
{
	int iAlive = CountAliveSurvivors();

	// 1.3.4：分子从「存活 - 倒地」改成「在场未倒地」（= 存活 + 未倒地 + 不在终点安全屋）。
	// 分母 iAlive 保持「存活生还者总数」不变 —— 用户只要求排除"未倒地生还者"这一项。
	// 这样 ratio 只会持平或变小，可守护数只会持平或变少，不会出现守护数异常变大。
	int iStanding = CountStandingSurvivors();
	int iBots = CountAiSurvivors();

	int iBase = g_cvMaxCount.IntValue;

	if (iBots < iBase)
		iBase = iBots;

	if (iBase <= 0 || iAlive <= 0)
		return 0;

	// 1.2.2：场上已经没有任何"玩家操控的生还者"（真人全灭 / 全在旁观）时，
	// 不能再让几个人机靠无敌顶着 —— 玩家反馈过"其他生还者死完了，三个人机还无敌"。
	if (CountAliveHumanSurvivors() <= 0)
		return 0;

	// 只剩一个（或零个）人没倒：连最后一个守护也取消
	if (iStanding <= 1)
		return 0;

	float fRatio = float(iStanding) / float(iAlive);

	int iAllowed = RoundHalfUp(float(iBase) * fRatio);

	// 还有两个人以上站着就至少留一个守护
	if (iAllowed < 1)
		iAllowed = 1;

	if (iAllowed > iBase)
		iAllowed = iBase;

	return iAllowed;
}

// 1.2.1：四舍五入（.5 一律进位）
// SourceMod 的 RoundToNearest 是 IEEE 银行家舍入（2.5 -> 2、1.5 -> 2），
// 而这里要的是 2.5 -> 3（否则"12 人满编、倒地 2 人"就从 3 个守护掉到 2 个，与需求示例不符）
int RoundHalfUp(float fValue)
{
	int iFloor = RoundToFloor(fValue);

	if (fValue - float(iFloor) >= 0.5)
		iFloor++;

	return iFloor;
}

// 1.2.1：当前实际处于守护状态的人数
int CountGuarded()
{
	int iCount = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && g_bGuarded[i])
			iCount++;
	}

	return iCount;
}

// 1.2.0：按名额重新分配守护状态
//   - 已处于守护状态的人优先保留名额
//   - 剩余名额按「总血量升序 -> 客户端索引升序」分配给其它候选
//   - 名额不够时，多出来的已守护者用 LeaveGuard 完整释放（发光 netprop 一并还原）
void UpdateGuardSet(int iAllowed)
{
	int aCandidates[MAXPLAYERS + 1];
	int iCount = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!ShouldGuard(i))
			continue;

		aCandidates[iCount++] = i;
	}

	SortGuardCandidates(aCandidates, iCount);

	int iSlots = iAllowed;

	// 第一轮：已守护的优先保留
	for (int k = 0; k < iCount; k++)
	{
		int iClient = aCandidates[k];

		if (!g_bGuarded[iClient])
			continue;

		if (iSlots > 0)
		{
			iSlots--;
			continue;
		}

		LeaveGuard(iClient);
	}

	// 第二轮：剩余名额发给未守护的候选（已按总血量/索引排好序）
	for (int k = 0; k < iCount; k++)
	{
		if (iSlots <= 0)
			break;

		int iClient = aCandidates[k];

		if (g_bGuarded[iClient])
			continue;

		EnterGuard(iClient);
		iSlots--;
	}
}

// 1.2.0：候选排序（插入排序，最多 24 个元素，不值得走 SortCustom1D）
// 排序键：总血量升序 -> 客户端索引升序
void SortGuardCandidates(int[] aCandidates, int iCount)
{
	for (int i = 1; i < iCount; i++)
	{
		int iKey = aCandidates[i];
		int iKeyHealth = GetTotalHealth(iKey);
		int j = i - 1;

		while (j >= 0 && IsCandidateBefore(iKey, iKeyHealth, aCandidates[j]))
		{
			aCandidates[j + 1] = aCandidates[j];
			j--;
		}

		aCandidates[j + 1] = iKey;
	}
}

// 1.2.0：iClient 是否应排在 iOther 前面（总血量更少，或血量相同但索引更小）
bool IsCandidateBefore(int iClient, int iHealth, int iOther)
{
	int iOtherHealth = GetTotalHealth(iOther);

	if (iHealth != iOtherHealth)
		return iHealth < iOtherHealth;

	return iClient < iOther;
}

// ============================================================================
// 1.2.0：未接管生还者移速（m_flLaggedMovementValue）
// ============================================================================

// 倍率 = l4d2_bot_guard_bot_speed / l4d2_bot_guard_base_speed（默认 330/220 = 1.5）
float GetBotSpeedScale()
{
	float fBase = g_cvBaseSpeed.FloatValue;

	if (fBase <= 0.0)
		return MOVEMENT_DEFAULT;

	float fScale = g_cvBotSpeed.FloatValue / fBase;

	// 兜底：配置写坏了也不能把 bot 变成钉子/火箭
	if (fScale < 0.1)
		fScale = 0.1;

	if (fScale > 5.0)
		fScale = 5.0;

	return fScale;
}

// 是否该给该生还者上移速：存活、未倒地、未挂边、未被真人接管
bool ShouldApplyBotSpeed(int client)
{
	if (!g_cvEnabled.BoolValue)
		return false;

	if (GetClientTeam(client) != TEAM_SURVIVOR)
		return false;

	// 被真人接管后 IsFakeClient 变成 false，这里直接排除
	if (!IsFakeClient(client))
		return false;

	if (!IsPlayerAlive(client))
		return false;

	if (IsIncapacitated(client))
		return false;

	if (IsHangingFromLedge(client))
		return false;

	return true;
}

// 每 tick 刷新一遍全部客户端的移速状态。
// 注意：只要有任何一个条件失效（被接管 / 死亡 / 倒地 / 挂边 / 总开关关闭），
// 就把 m_flLaggedMovementValue 写回 1.0，绝不残留。
void UpdateBotSpeed()
{
	float fScale = GetBotSpeedScale();

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
		{
			g_bSpeedApplied[i] = false;
			continue;
		}

		if (ShouldApplyBotSpeed(i))
		{
			SetEntPropFloat(i, Prop_Send, MOVEMENT_PROP, fScale);
			g_bSpeedApplied[i] = true;
		}
		else if (g_bSpeedApplied[i])
		{
			SetEntPropFloat(i, Prop_Send, MOVEMENT_PROP, MOVEMENT_DEFAULT);
			g_bSpeedApplied[i] = false;
		}
	}
}

// ============================================================================
// 1.3.0：玩家特感攻击"守护中的 AI 生还者"时的提示
//
//   - 提示音：默认 ui/beep_error01.wav（= 本仓库 l4d_votes_5_VS 投票未通过用的同一个
//     音效文件，服务器上绝对存在）。改 l4d2_bot_guard_warn_sound 可换成任意
//     game_sounds 路径（相对 sound/ 目录），留空则不播。
//   - 三渠道文字：① 聊天框 ② PrintHintText ③ HUD 文字，各自有开关。
//   - 节流：同一名特感玩家默认 1 秒内只提示一次（提示音也一起节流），
//     连点爪击不会刷屏刷音。
// ============================================================================

// 解析 l4d2_bot_guard_warn_sound，并（在地图开始时可）预缓存。
//
// 1.3.1 修复（用户实测：日志报"音效不存在: ui/beep_error01.wav"，但游戏里确实有这个音效）：
//   **不再**用 FileExists 当门禁。实测该文件在服务器上 FileExists（valve 文件系统 +
//   普通文件系统两条路）都返回 false —— srcds 端的音效可能只存在于 VPK、或纯靠
//   客户端本地文件播放，服务器端查文件既不可靠，又会在每次换图刷一条假报错。
//   现在：
//     - 播放不做存在性检查，直接 EmitSoundToClient（路径写错最多是没声音，文字提示照常）；
//     - 预缓存照做（自定义音效要预缓存才能下发，库存音效是 no-op）；
//     - 诊断只在 sm_botguard_status / sm_botguard_warntest 里打印，且明确说明
//       "服务器端查不到 ≠ 播放不了"。
void RefreshWarnSound(bool bPrecache)
{
	g_cvWarnSound.GetString(g_sWarnSound, sizeof(g_sWarnSound));

	if (g_sWarnSound[0] == '\0')
		return;

	if (bPrecache)
		PrecacheSound(g_sWarnSound, true);
}

// 仅用于诊断显示：服务器端能否找到这个音效文件（false 也不代表播放不了）
bool WarnSoundFoundOnServer()
{
	if (g_sWarnSound[0] == '\0')
		return false;

	char sDiskPath[PLATFORM_MAX_PATH];
	Format(sDiskPath, sizeof(sDiskPath), "sound/%s", g_sWarnSound);

	if (FileExists(sDiskPath, true) || FileExists(sDiskPath))
		return true;

	// 兼容"配置里自己带了 sound/ 前缀"的写法
	if (FileExists(g_sWarnSound, true) || FileExists(g_sWarnSound))
		return true;

	return false;
}

// 只有"玩家操控的特感"才需要提示（AI 特感不刷屏）
bool IsWarnTarget(int client)
{
	if (client < 1 || client > MaxClients)
		return false;

	if (!IsClientInGame(client) || IsFakeClient(client))
		return false;

	return GetClientTeam(client) == TEAM_INFECTED;
}

// 带节流的入口：守护中的 AI 生还者被玩家特感攻击时调用
void NotifyGuardBlocked(int attacker, int victim)
{
	if (!g_cvWarn.BoolValue)
		return;

	if (!IsWarnTarget(attacker))
		return;

	float fNow = GetGameTime();
	float fCooldown = g_cvWarnCooldown.FloatValue;
	if (fCooldown < 0.0)
		fCooldown = 0.0;

	// 1 秒播放检测：同一个人在这个窗口内只提示一次（提示音与三渠道文字共用）
	if (fCooldown > 0.0 && g_fWarnLast[attacker] > 0.0 && fNow - g_fWarnLast[attacker] < fCooldown)
		return;

	g_fWarnLast[attacker] = fNow;

	ShowGuardBlockedHint(attacker, victim);
}

// 真正发提示（节流在 NotifyGuardBlocked 里做；管理员命令 sm_botguard_warntest 直接调它）
void ShowGuardBlockedHint(int attacker, int victim)
{
	if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker))
		return;

	// 被守护的生还者名字（找不到就退化成通用说法，管理员命令单独测试时也好看）
	char sName[MAX_NAME_LENGTH];
	if (victim > 0 && victim <= MaxClients && IsClientInGame(victim))
		Format(sName, sizeof(sName), "%N", victim);
	else
		strcopy(sName, sizeof(sName), "该 AI 生还者");

	// 提示音（默认 = 投票失败音效）
	if (g_sWarnSound[0] != '\0')
		EmitSoundToClient(attacker, g_sWarnSound, SOUND_FROM_PLAYER, SNDCHAN_AUTO,
			SNDLEVEL_NORMAL, SND_NOFLAGS, 1.0);

	// 渠道① 聊天框
	if (g_cvWarnChat.BoolValue)
	{
		PrintToChat(attacker, "\x04[人机守护]\x01 \x03%s\x01 处于守护状态：\x04免疫伤害 / 免疫控制\x01，攻击与技能都不会生效。",
			sName);
	}

	// 渠道② 屏幕提示（PrintHintText）
	if (g_cvWarnHint.BoolValue)
	{
		PrintHintText(attacker, "人机守护中：%s 无敌（免疫伤害与控制）", sName);
	}

	// 渠道③ HUD 文字（画面上方，2.5 秒）
	if (g_cvWarnHud.BoolValue)
	{
		SetHudTextParams(-1.0, 0.12, 2.5, 255, 80, 80, 255, 0, 0.0, 0.0, 0.0);
		ShowHudText(attacker, -1, "[人机守护] %s 免疫伤害 / 免疫控制", sName);
	}
}

// sm_botguard_warntest [目标]：不节流地演示一遍提示，用来确认音效文件是否存在、三渠道是否都能看到
public Action Cmd_WarnTest(int client, int args)
{
	int target = client;

	if (args >= 1)
	{
		char sArg[MAX_NAME_LENGTH];
		GetCmdArg(1, sArg, sizeof(sArg));

		target = FindTarget(client, sArg, false, false);
		if (target == -1)
			return Plugin_Handled;
	}

	if (target < 1 || target > MaxClients || !IsClientInGame(target))
	{
		ReplyToCommand(client, "\x04[BotGuard]\x01 目标无效或不在游戏中。");
		return Plugin_Handled;
	}

	// 找一个当前守护中的 bot 当作"被打的对象"，没有就用通用文案
	int victim = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && g_bGuarded[i])
		{
			victim = i;
			break;
		}
	}

	g_fWarnLast[target] = 0.0;
	ShowGuardBlockedHint(target, victim);

	ReplyToCommand(client, "\x04[BotGuard]\x01 已向 #%d 发送一次演示提示（音效=%s，服务器端文件探测=%d，节流已跳过）。",
		target, (g_sWarnSound[0] != '\0') ? g_sWarnSound : "无", WarnSoundFoundOnServer() ? 1 : 0);
	ReplyToCommand(client, "\x04[BotGuard]\x01 注意：探测=0 不代表播放不了（srcds 上的库存音效常常只存在于 VPK / 由客户端本地提供）；以耳朵听到的为准。");

	return Plugin_Handled;
}

// 是否应该进入守护状态
bool ShouldGuard(int client)
{
	if (!g_cvEnabled.BoolValue)
		return false;

	if (!IsClientInGame(client))
		return false;

	// 只处理生还者队伍里"非玩家操控"的那些
	if (GetClientTeam(client) != TEAM_SURVIVOR)
		return false;

	if (!IsFakeClient(client))
		return false;

	if (!IsPlayerAlive(client))
		return false;

	// 倒地后守护关闭：倒地 + 免伤 + 不能流血会造成永久卡关，
	// 倒地统一交给下面的"自动救起"处理
	if (IsIncapacitated(client))
		return false;

	return GetTotalHealth(client) <= g_cvHealth.IntValue;
}

void EnterGuard(int client)
{
	g_bGuarded[client] = true;

	// HasEntProp 结果只用于诊断（sm_botguard_status 里显示），
	// **不再**作为是否写发光的开关 —— 1.0.0 把它当门用过，结果顾客反馈"看不到光"：
	// 发光属性挂在 DT_BaseEntity 的嵌套表 m_Glow 里，HasEntProp 对嵌套表判 false 时
	// 整个发光就被静默跳过了。其它成熟插件（LMC / extendedsight / defib_revive）
	// 都是直接 SetEntProp，没有这道门。
	g_bGlowProps[client] = HasEntProp(client, Prop_Send, "m_iGlowType")
		&& HasEntProp(client, Prop_Send, "m_glowColorOverride")
		&& HasEntProp(client, Prop_Send, "m_nGlowRange");

	// 记录进入守护前的发光状态，退出时原样写回
	g_iOrigGlowType[client] = GetEntProp(client, Prop_Send, "m_iGlowType");
	g_iOrigGlowColor[client] = GetEntProp(client, Prop_Send, "m_glowColorOverride");
	g_iOrigGlowRange[client] = GetEntProp(client, Prop_Send, "m_nGlowRange");
	g_iOrigGlowRangeMin[client] = GetEntProp(client, Prop_Send, "m_nGlowRangeMin");

	// 冻结当前虚血
	g_fTempStash[client] = L4D_GetTempHealth(client);

	// 1.2.3：锁定实血。守护期间 Timer_Protect 会把实血顶回这个值，
	// 挡住 spitter 酸液这类不经过 OnTakeDamage 的掉血
	g_iGuardHealth[client] = GetClientHealth(client);
	if (g_iGuardHealth[client] < 1)
		g_iGuardHealth[client] = 1;

	// 1.2.2：引擎层免伤。只用 SDKHook_OnTakeDamage 拦截挡不住所有路径
	// （玩家反馈"无敌状态下 charger 概率造成伤害/概率控中"），这里同时把
	// m_takedamage 置 0（rygive 的 god mode 同款写法），让引擎自己就不接伤害。
	g_iOrigTakeDamage[client] = GetEntProp(client, Prop_Data, "m_takedamage", 1);
	SetEntProp(client, Prop_Data, "m_takedamage", 0, 1);

	if (g_cvGlow.BoolValue)
		ApplyGlow(client, true);

	// 进入守护的瞬间若正被控制，立即解控
	// 1.2.0：名额已经由 UpdateGuardSet / OnTakeDamage 判定过，这里不再看旧的数量开关
	if (g_cvBlockControl.BoolValue)
		ReleaseControl(client);
}

void LeaveGuard(int client)
{
	g_bGuarded[client] = false;
	g_fTempStash[client] = 0.0;
	g_iGuardHealth[client] = 0;

	if (!IsClientInGame(client))
		return;

	// 1.2.2：恢复引擎层受击状态（进入守护前的值；取不到就按正常 2 = DAMAGE_AIM）
	int iTakeDamage = g_iOrigTakeDamage[client];

	if (iTakeDamage <= 0)
		iTakeDamage = 2;

	SetEntProp(client, Prop_Data, "m_takedamage", iTakeDamage, 1);

	// 恢复进入守护前的发光 netprop
	SetEntProp(client, Prop_Send, "m_iGlowType", g_iOrigGlowType[client]);
	SetEntProp(client, Prop_Send, "m_glowColorOverride", g_iOrigGlowColor[client]);
	SetEntProp(client, Prop_Send, "m_nGlowRange", g_iOrigGlowRange[client]);
	SetEntProp(client, Prop_Send, "m_nGlowRangeMin", g_iOrigGlowRangeMin[client]);

	if (g_cvGlowFlash.BoolValue)
		SetEntProp(client, Prop_Send, "m_bFlashing", 0, 1);
}

// ============================================================================
// 白色轮廓（参考 l4d2_tank_defib_revive / LMC_Black_and_White_Notifier 的写法）
// ============================================================================

void ApplyGlow(int client, bool bOn)
{
	if (bOn)
	{
		SetEntProp(client, Prop_Send, "m_iGlowType", GLOW_TYPE_CONSTANT);
		SetEntProp(client, Prop_Send, "m_glowColorOverride", g_iGlowColorPacked);
		SetEntProp(client, Prop_Send, "m_nGlowRange", g_cvGlowRange.IntValue);
		// 1.1.0：补上 m_nGlowRangeMin —— 服务器上已经在跑的 witch_glow 就是
		// type3 + color + rangeMin + range 这套，缺 rangeMin 时不一定显示
		SetEntProp(client, Prop_Send, "m_nGlowRangeMin", g_cvGlowRangeMin.IntValue);

		// m_bFlashing 是 1 bit 属性，必须显式传 size=1（LMC 同款写法）
		if (g_cvGlowFlash.BoolValue)
			SetEntProp(client, Prop_Send, "m_bFlashing", 1, 1);
	}
	else
	{
		// 闪的"灭"相位：只关类型，颜色留着不动，减少无意义写属性
		SetEntProp(client, Prop_Send, "m_iGlowType", 0);

		if (g_cvGlowFlash.BoolValue)
			SetEntProp(client, Prop_Send, "m_bFlashing", 0, 1);
	}
}

// 把 "R G B" 解析成 L4D2 的打包颜色（R | G<<8 | B<<16，与 LMC 的 GetColor 同口径）
void ParseGlowColor()
{
	char sBuffer[64];
	g_cvGlowColor.GetString(sBuffer, sizeof(sBuffer));

	char sParts[3][8];
	int iR = 255;
	int iG = 255;
	int iB = 255;

	// 手工解析，避免多参数刷屏；解析失败时回落白色（绝不能回落 0 = 黑色，那等于没光）
	if (ExplodeString(sBuffer, " ", sParts, sizeof(sParts), sizeof(sParts[])) == 3)
	{
		iR = ClampInt(StringToInt(sParts[0]));
		iG = ClampInt(StringToInt(sParts[1]));
		iB = ClampInt(StringToInt(sParts[2]));
	}

	g_iGlowColorPacked = iR | (iG << 8) | (iB << 16);

	// 纯黑等于"看不见"，直接把 0 当无效值纠正成白色，避免配置写错后静默失效
	if (g_iGlowColorPacked == 0)
		g_iGlowColorPacked = 0xFFFFFF;
}

int ClampInt(int iValue)
{
	if (iValue < 0)
		return 0;
	if (iValue > 255)
		return 255;
	return iValue;
}

// ============================================================================
// 免疫伤害（参考 rygive 的 OnTakeDamage god mode）
// ============================================================================

public Action Hook_OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage,
	int &damagetype, int &weapon, float damageForce[3], float damagePosition[3], int damagecustom)
{
	if (!g_cvInvincible.BoolValue || victim <= 0 || victim > MaxClients)
		return Plugin_Continue;

	// 已在守护状态：任何伤害一律吃掉，虚血继续冻结（保持 1.1.0 的原有逻辑）
	// 1.2.0 起不再有"AI 数量超限就整段失效"的开关，改由名额本身控制谁能进守护
	if (g_bGuarded[victim])
	{
		// 1.3.0：告诉攻击的玩家特感"这只人机是无敌的"（提示音 + 三渠道文字，带 1 秒节流）
		NotifyGuardBlocked(attacker, victim);

		damage = 0.0;
		return Plugin_Handled;
	}

	// 1.2.0 需求4："保命"判定
	// 只有非玩家操控、存活未倒地的生还者才可能被保命
	if (!IsGuardTarget(victim))
		return Plugin_Continue;

	if (IsIncapacitated(victim))
		return Plugin_Continue;

	// 0 伤害的"记分"事件不是真伤害，不参与保命判定
	if (damage <= 0.0)
		return Plugin_Continue;

	// 本次伤害是否"足够把他打成倒地"（伤害 >= 当前总血量）
	int iTotal = GetTotalHealth(victim);

	if (damage < float(iTotal))
		return Plugin_Continue;

	// 名额判定：现算一遍（不等下一 tick），当前守护人数 < 可守护数才保命。
	// 不在名额内的 bot 不做保命，照常掉血 / 倒地（否则全队 bot 永远打不死）。
	// 顺手刷新状态缓存，让 sm_botguard_status 立刻能看到最新数字
	g_iAiSurvivors = CountAiSurvivors();
	g_iDownCount = CountDownedSurvivors();
	g_iGuardAllowed = ComputeAllowedGuards();

	int iAllowed = g_iGuardAllowed;

	if (CountGuarded() >= iAllowed)
		return Plugin_Continue;

	// 吃伤害 -> 虚血清 0 -> 实血设为阈值（默认 10）-> 立即进入守护状态
	damage = 0.0;

	L4D_SetTempHealth(victim, 0.0);

	int iHealth = g_cvHealth.IntValue;
	if (iHealth < 1)
		iHealth = 1;

	SetEntityHealth(victim, iHealth);

	EnterGuard(victim);
	g_iGuardCount = CountGuarded();

	// 1.3.0：这一击被"保命"吃掉并当场进入守护，同样提示攻击的玩家特感
	NotifyGuardBlocked(attacker, victim);

	return Plugin_Handled;
}

// ============================================================================
// 免控 / 解控
// ============================================================================

// 参考 rygive.sp: ReleaseControl()
void ReleaseControl(int victim)
{
	int attacker;

	attacker = GetEntPropEnt(victim, Prop_Send, "m_tongueOwner");
	if (attacker > 0 && attacker <= MaxClients)
		L4D_Smoker_ReleaseVictim(victim, attacker);

	attacker = GetEntPropEnt(victim, Prop_Send, "m_pounceAttacker");
	if (attacker > 0 && attacker <= MaxClients)
		L4D_Hunter_ReleaseVictim(victim, attacker);

	attacker = GetEntPropEnt(victim, Prop_Send, "m_jockeyAttacker");
	if (attacker > 0 && attacker <= MaxClients)
		L4D2_Jockey_EndRide(victim, attacker);

	attacker = GetEntPropEnt(victim, Prop_Send, "m_carryAttacker");
	if (attacker > 0 && attacker <= MaxClients)
		L4D2_Charger_EndCarry(victim, attacker);

	attacker = GetEntPropEnt(victim, Prop_Send, "m_pummelAttacker");
	if (attacker > 0 && attacker <= MaxClients)
		L4D2_Charger_EndPummel(victim, attacker);
}

// 舌头：前置 forward 拦下等于"抓不到"
public Action L4D_OnGrabWithTongue(int victim, int attacker)
{
	if (BlockControlOn(victim))
	{
		NotifyGuardBlocked(attacker, victim);
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

// 猎人扑击
public Action L4D_OnPouncedOnSurvivor(int victim, int attacker)
{
	if (BlockControlOn(victim))
	{
		NotifyGuardBlocked(attacker, victim);
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

// 猴子骑乘
public Action L4D2_OnJockeyRide(int victim, int attacker)
{
	if (BlockControlOn(victim))
	{
		NotifyGuardBlocked(attacker, victim);
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

// 牛冲撞抱人
public Action L4D2_OnStartCarryingVictim(int victim, int attacker)
{
	if (BlockControlOn(victim))
	{
		NotifyGuardBlocked(attacker, victim);
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

// 牛捶打（charger pummel）：1.2.3 新增。left4dhooks 有前置 forward（注意参数顺序是 attacker, victim），
// 拦下来比"被捶打后再 EndPummel"干净 —— 玩家反馈守护中的 bot 仍会被牛捶打/拖走就是这个缺口
public Action L4D2_OnPummelVictim(int attacker, int victim)
{
	if (BlockControlOn(victim))
	{
		NotifyGuardBlocked(attacker, victim);
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

// 牛把人撞到墙上（会造成倒地/致残伤害）：守护中的生还者直接吃掉这次撞墙
public Action L4D2_OnSlammedSurvivor(int victim, int attacker, bool &bWallSlam, bool &bDeadlyCharge)
{
	if (BlockControlOn(victim))
	{
		NotifyGuardBlocked(attacker, victim);
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

bool BlockControlOn(int victim)
{
	if (!g_cvBlockControl.BoolValue)
		return false;

	if (victim <= 0 || victim > MaxClients)
		return false;

	// 1.2.0：守护名额已经保证"最多 max_count 个"，不需要再另设数量开关
	return g_bGuarded[victim];
}

// ============================================================================
// 自动救起（每回合每名 AI 生还者一次）
// ============================================================================

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	// 回合开始时重置每名客户端的自动救起次数
	for (int i = 0; i <= MaxClients; i++)
		g_iReviveLeft[i] = g_cvReviveTimes.IntValue;

	// 1.3.4：本回合重新判定「终点安全屋」的运行期条件
	// （native 可用性 + 本图有没有 info_changelevel；救援关会自动识别成"没有"）。
	RefreshEndSaferoomState();
}

public void Event_PlayerIncapacitated(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnabled.BoolValue || g_cvReviveTimes.IntValue <= 0)
		return;

	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!IsGuardTarget(client))
		return;

	if (g_iReviveLeft[client] <= 0)
		return;

	float fDelay = g_cvReviveDelay.FloatValue;
	if (fDelay < 0.0)
		fDelay = 0.0;

	CreateTimer(fDelay, Timer_AutoRevive, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_AutoRevive(Handle timer, any iUserId)
{
	int client = GetClientOfUserId(iUserId);

	if (!IsGuardTarget(client))
		return Plugin_Stop;

	// 期间被别人救起 / 已经死亡就不用管了
	if (!IsIncapacitated(client))
		return Plugin_Stop;

	if (g_iReviveLeft[client] <= 0)
		return Plugin_Stop;

	g_iReviveLeft[client]--;

	// Left4DHooks: 让倒地/挂边生还者起身
	L4D_ReviveSurvivor(client);

	int iHealth = g_cvReviveHealth.IntValue;
	if (iHealth < 1)
		iHealth = 1;

	SetEntityHealth(client, iHealth);

	if (g_cvNotify.BoolValue)
	{
		if (g_iReviveLeft[client] > 0)
		{
			PrintToChatAll("\x03[提示] \x01AI 生还者 %N 已自动救起（本回合剩余自动救起 %d 次）。",
				client, g_iReviveLeft[client]);
		}
		else
		{
			PrintToChatAll("\x03[提示] \x01AI 生还者 %N 已自动救起（本回合自动救起次数已用完）。", client);
		}
	}

	return Plugin_Stop;
}

// ============================================================================
// 1.3.3：守护中的 AI 生还者禁止自行使用医疗物品（吃药 / 打针 / 打包）
//
//   Actions 扩展把引擎里生还者的"行为动作"暴露成具名 action，拦截手法就是给对应的
//   action 挂 OnStart / Update 回调，把 result.type 设成 DONE 来取消这个动作：
//     - SurvivorTakePills  吃药(weapon_pain_pills) 与 打针(weapon_adrenaline) 共用
//                          这一个 action —— server.dll 里没有独立的 SurvivorUseAdrenaline；
//     - SurvivorHealSelf   给自己打包(weapon_first_aid_kit)。
//   **不拦** SurvivorHealFriend / SurvivorGivePillsToFriend：那是给队友包扎/递药，
//   需求只要求"守护中不得自行使用"，救队友的行为保持原样。
//
//   参考实现：仓库里的 l4d2_block_bot_pills.sp（SurvivorTakePills 的 OnStart 拦截）
//   与 l4d_bot_healing.sp（SurvivorHealSelf / SurvivorTakePills 的 OnStart 写法）。
// ============================================================================

// 该 actor 的"自行用药"动作是否要拦：扩展可用 + 两个开关都开着 + 确实处于守护状态
bool ShouldBlockItemUse(int client)
{
	if (!g_bActionsAvailable || !g_cvBlockItems.BoolValue || !g_cvEnabled.BoolValue)
		return false;

	if (client < 1 || client > MaxClients)
		return false;

	// 只拦"守护中"的人机（守护状态由主状态机维护，见 EnterGuard / LeaveGuard）
	return g_bGuarded[client];
}

// 每个动作创建时挂回调。
// 注意：这里不能只按 g_bGuarded 决定挂不挂 —— 动作有可能在进入守护之前就创建好了，
// 所以按"动作名"挂上，真正是否拦截放到回调里用 ShouldBlockItemUse() 再判一次。
public void OnActionCreated(BehaviorAction action, int actor, const char[] name)
{
	if (!g_bActionsAvailable || !g_cvBlockItems.BoolValue)
		return;

	if (actor < 1 || actor > MaxClients || !IsClientInGame(actor))
		return;

	// 只关心"给自己用医疗物品"的两个 action（吃药/打针 共用 SurvivorTakePills）
	if (strcmp(name, "SurvivorTakePills") != 0 && strcmp(name, "SurvivorHealSelf") != 0)
		return;

	action.OnStart = OnGuardItemActionStart;
	action.Update  = OnGuardItemActionUpdate;
}

// 动作开始：守护中的直接取消（result.type = DONE）
public Action OnGuardItemActionStart(BehaviorAction action, int actor, BehaviorAction priorAction, ActionResult result)
{
	if (!ShouldBlockItemUse(actor))
		return Plugin_Continue;

	result.type = DONE;
	return Plugin_Changed;
}

// 动作进行中：守护状态可能在动作开始之后才生效（例如刚好被"保命"打进守护），
// 这里再拦一次，避免"已经开始吃"的人机把药吃完/把包打完。
public Action OnGuardItemActionUpdate(BehaviorAction action, int actor, float interval, ActionResult result)
{
	if (!ShouldBlockItemUse(actor))
		return Plugin_Continue;

	result.type = DONE;
	return Plugin_Changed;
}

// player_bot_replace 兜底（参考 l4d2_block_bot_pills.sp 的同名处理）：
// 玩家离开、身体交给 bot 接管时，bot 会"继承"玩家手里正在被使用的那件止痛药/肾上腺素，
// 于是刚接管的人机立刻把药吃掉。这里把新 bot 手上那件物品的实体换掉，打断这次自动服用。
public void Event_PlayerBotReplace(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnabled.BoolValue || !g_cvBlockItems.BoolValue)
		return;

	int bot = GetClientOfUserId(event.GetInt("bot"));

	if (bot < 1 || bot > MaxClients || !IsClientInGame(bot))
		return;

	// 只处理"接管后应当被守护"的人机（总血量已经掉到阈值以下的那批）
	if (!ShouldGuard(bot))
		return;

	RefreshHeldHealItem(bot);
}

// 把 client 手上正拿着的止痛药/肾上腺素换成一件同款新实体（打断"继承"过来的使用动作）。
//   - 只看 slot 4（L4D2 的临时物品槽，止痛药与肾上腺素都在这一格），医疗包/除颤器不动；
//   - 先取类名再 Kill（Kill 之后旧实体句柄就悬空了）；
//   - 物品种类与数量都不变，只是换了个实体，bot 之后照样能用（只是这一口吃不成了）。
void RefreshHeldHealItem(int client)
{
	char sWeapon[64];
	GetClientWeapon(client, sWeapon, sizeof(sWeapon));

	// 只处理会"自动吃"的两件（药与针共用 SurvivorTakePills）
	if (strcmp(sWeapon, "weapon_pain_pills") != 0 && strcmp(sWeapon, "weapon_adrenaline") != 0)
		return;

	int iOld = GetPlayerWeaponSlot(client, 4);

	if (iOld <= 0 || !IsValidEntity(iOld))
		return;

	char sClass[64];
	GetEdictClassname(iOld, sClass, sizeof(sClass));

	if (sClass[0] == '\0')
		return;

	AcceptEntityInput(iOld, "Kill");

	int iNew = CreateEntityByName(sClass);

	if (iNew <= 0 || !IsValidEntity(iNew))
		return;

	DispatchSpawn(iNew);
	EquipPlayerWeapon(client, iNew);
}

// ============================================================================
// 工具
// ============================================================================

// 是否是"非玩家操控的生还者"（自动救起的目标）
bool IsGuardTarget(int client)
{
	if (client <= 0 || client > MaxClients)
		return false;

	if (!IsClientInGame(client))
		return false;

	if (GetClientTeam(client) != TEAM_SURVIVOR)
		return false;

	if (!IsFakeClient(client))
		return false;

	return IsPlayerAlive(client);
}

bool IsIncapacitated(int client)
{
	return GetEntProp(client, Prop_Send, "m_isIncapacitated", 1) != 0;
}

// 1.2.0：是否挂在边缘（挂边时不能走路，移速要还原成 1.0）
bool IsHangingFromLedge(int client)
{
	return GetEntProp(client, Prop_Send, "m_isHangingFromLedge", 1) != 0;
}

// 总血量 = 实血 + 虚血（临时血量，已扣减自然衰减）
int GetTotalHealth(int client)
{
	int iReal = GetClientHealth(client);
	float fTemp = L4D_GetTempHealth(client);

	if (iReal < 0)
		iReal = 0;

	if (fTemp < 0.0)
		fTemp = 0.0;

	return iReal + RoundToNearest(fTemp);
}

// ============================================================================
// 排查 / 验证命令（管理员）
// ============================================================================

// sm_botguard_status：把插件"眼里的状态"全部打印出来。
// 之前出现"看不到光"时只能猜，这条命令让排查变成读数：
//   - 存活未接管生还者数量 / 倒地人数 / 阶梯值 / 可守护数 / 当前守护名单 / 阈值
//   - 每个 bot 的实血、虚血、总血、是否被接管、移速值、守护状态、剩余救起次数
//   - 发光 netprop 当前值 + HasEntProp 结果（false 说明该客户端读不到属性表，但插件仍会照写）
public Action Cmd_Status(int client, int args)
{
	ReplyToCommand(client, "\x04[BotGuard]\x01 版本 %s | 开关=%d 阈值=%d 轮廓=%d(颜色=%d) 闪烁=%d 节奏=%.2fs | 免伤=%d 免控=%d 自动救起=%d/回合 | 守护上限=%d（按未倒地比例分配） | 移速 %.0f/%.0f = x%.2f",
		PLUGIN_VERSION,
		g_cvEnabled.IntValue,
		g_cvHealth.IntValue,
		g_cvGlow.IntValue,
		g_iGlowColorPacked,
		g_cvGlowFlash.IntValue,
		g_cvInterval.FloatValue,
		g_cvInvincible.IntValue,
		g_cvBlockControl.IntValue,
		g_cvReviveTimes.IntValue,
		g_cvMaxCount.IntValue,
		g_cvBotSpeed.FloatValue,
		g_cvBaseSpeed.FloatValue,
		GetBotSpeedScale());

	// 1.3.0：打守护 bot 的提示配置（提示音路径 + 三渠道开关 + 节流）
	// 1.3.1：附上"服务器端文件探测"结果，仅作诊断（0 也可能正常播放）
	ReplyToCommand(client, "\x04[BotGuard]\x01 拦截提示: 开关=%d 节流=%.1fs 音效=%s (服务器端探测=%d) | 渠道 聊天=%d 屏幕=%d HUD=%d",
		g_cvWarn.IntValue,
		g_cvWarnCooldown.FloatValue,
		(g_sWarnSound[0] != '\0') ? g_sWarnSound : "（无）",
		WarnSoundFoundOnServer() ? 1 : 0,
		g_cvWarnChat.IntValue,
		g_cvWarnHint.IntValue,
		g_cvWarnHud.IntValue);

	// 1.3.3：守护中禁止自行使用医疗物品（吃药 / 打针 / 打包）—— 需要 Actions 扩展
	ReplyToCommand(client, "\x04[BotGuard]\x01 物品拦截: 开关=%d 实际生效=%d | Actions 扩展=%d (actionslib) | %s",
		g_cvBlockItems.IntValue,
		(g_cvBlockItems.BoolValue && g_bActionsAvailable) ? 1 : 0,
		g_bActionsAvailable ? 1 : 0,
		g_bActionsAvailable ? "拦截 SurvivorTakePills(吃药/打针) + SurvivorHealSelf(打包)" : "扩展缺失，不拦截（其余功能正常）");

	// 1.2.0：当前守护名单（#client 索引列表）
	char sGuardList[256];
	int iPos = 0;
	int iGuardNameCount = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !g_bGuarded[i])
			continue;

		if (iGuardNameCount > 0)
			iPos += Format(sGuardList[iPos], sizeof(sGuardList) - iPos, ", #%d", i);
		else
			iPos += Format(sGuardList[iPos], sizeof(sGuardList) - iPos, "#%d", i);

		iGuardNameCount++;
	}

	if (iGuardNameCount == 0)
		strcopy(sGuardList, sizeof(sGuardList), "（无）");

	ReplyToCommand(client, "\x04[BotGuard]\x01 倒地人数=%d / 存活生还者=%d（在场未倒地 %d，终点安全屋内已排除 %d）→ 可守护数=%d；存活未接管生还者=%d；当前守护人数=%d 名单: %s",
		g_iDownCount,
		CountAliveSurvivors(),
		CountStandingSurvivors(),
		CountExcludedInEndSaferoom(),
		g_iGuardAllowed,
		g_iAiSurvivors,
		g_iGuardCount,
		sGuardList);

	// 1.3.4：终点安全屋排除的生效条件（排查用）
	ReplyToCommand(client, "\x04[BotGuard]\x01 终点安全屋排除: 开关=%d native可用=%d 本图有终点安全屋=%d（救援关/终局图没有 info_changelevel，自动不排除）",
		g_cvExcludeEndSaferoom.IntValue,
		g_bNtvLastCheckpoint ? 1 : 0,
		g_bHasEndSaferoom ? 1 : 0);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR)
			continue;

		char sName[MAX_NAME_LENGTH];
		GetClientName(i, sName, sizeof(sName));

		ReplyToCommand(client,
			"\x04[BotGuard]\x01 #%d %s 接管=%d bot=%d alive=%d incap=%d hang=%d | 实血=%d 虚血=%.1f 总血=%d | 移速=%.2f | 守护=%d(免伤位=%d) 本回合剩余救起=%d | glow type=%d color=%d range=%d rangeMin=%d flash=%d | 属性存在=%d",
			i, sName,
			IsFakeClient(i) ? 0 : 1,
			IsFakeClient(i) ? 1 : 0,
			IsPlayerAlive(i) ? 1 : 0,
			IsIncapacitated(i) ? 1 : 0,
			IsHangingFromLedge(i) ? 1 : 0,
			GetClientHealth(i),
			L4D_GetTempHealth(i),
			GetTotalHealth(i),
			GetEntPropFloat(i, Prop_Send, MOVEMENT_PROP),
			g_bGuarded[i] ? 1 : 0,
			GetEntProp(i, Prop_Data, "m_takedamage", 1),
			g_iReviveLeft[i],
			GetEntProp(i, Prop_Send, "m_iGlowType"),
			GetEntProp(i, Prop_Send, "m_glowColorOverride"),
			GetEntProp(i, Prop_Send, "m_nGlowRange"),
			GetEntProp(i, Prop_Send, "m_nGlowRangeMin"),
			GetEntProp(i, Prop_Send, "m_bFlashing", 1),
			g_bGlowProps[i] ? 1 : 0);
	}

	return Plugin_Handled;
}

// sm_botguard_test <#userid|名字> [秒]：不管血量，强制给目标闪轮廓若干秒（默认 30），
// 用来单独验证"发光到底能不能被看见"，不用等血量掉到阈值。
public Action Cmd_TestGlow(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "\x04[BotGuard]\x01 用法: sm_botguard_test <#userid|名字> [秒]");
		return Plugin_Handled;
	}

	char sTarget[64];
	GetCmdArg(1, sTarget, sizeof(sTarget));

	int iTarget = FindTarget(client, sTarget, false, false);

	if (iTarget <= 0)
		return Plugin_Handled;

	float fSeconds = 30.0;

	if (args >= 2)
	{
		char sSeconds[16];
		GetCmdArg(2, sSeconds, sizeof(sSeconds));

		float fValue = StringToFloat(sSeconds);

		if (fValue > 0.0)
			fSeconds = fValue;
	}

	g_fTestGlowUntil[iTarget] = GetGameTime() + fSeconds;

	ReplyToCommand(client, "\x04[BotGuard]\x01 已对 %N 强制开启轮廓 %.1f 秒（颜色=%d，闪烁=%d）",
		iTarget, fSeconds, g_iGlowColorPacked, g_cvGlowFlash.IntValue);

	return Plugin_Handled;
}
