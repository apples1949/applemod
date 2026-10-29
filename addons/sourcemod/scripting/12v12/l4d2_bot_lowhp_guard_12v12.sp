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

#define PLUGIN_VERSION		"1.2.2"

#define TEAM_SURVIVOR		2

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
ConVar g_cvBotSpeed;		// 1.2.0：未接管生还者移速（游戏单位，默认 330）
ConVar g_cvBaseSpeed;		// 1.2.0：正常走路速度基数（默认 220），倍率 = bot_speed / base_speed
ConVar g_cvReviveTimes;		// 每回合自动救起次数
ConVar g_cvReviveHealth;	// 自动救起后的血量
ConVar g_cvReviveDelay;		// 倒地后延迟多久救起（秒）
ConVar g_cvNotify;			// 自动救起时是否聊天框提示

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

int		g_iGlowColorPacked;					// 打包后的颜色值（R | G<<8 | B<<16）
bool	g_bBlinkPhase;						// 闪烁相位（每 tick 取反）

// 1.2.0：守护名额相关的统计值（每 tick 刷新，sm_botguard_status 直接读）
int		g_iAiSurvivors;						// 当前"存活且未被玩家接管"的生还者数量
int		g_iDownCount;						// 全队（team 2）倒地人数（m_isIncapacitated=1）
int		g_iGuardAllowed;					// 可守护数（1.2.1 起按比例计算，见 ComputeAllowedGuards）
int		g_iGuardCount;						// 当前实际处于守护状态的人数

Handle	g_hTickTimer;
Handle	g_hProtectTimer;					// 1.2.3：高频保护定时器（守护中的 bot 每 0.1s 解控 + 血量回锁）
int		g_iGuardHealth[MAXPLAYERS + 1];		// 守护期间锁定的实血值（挡住不走 OnTakeDamage 的掉血，例如 spitter 酸液）

public Plugin myinfo =
{
	name        = "L4D2 Bot Low HP Guard (12v12)",
	author      = "apples1949",
	description = "非玩家操控的生还者总血量<=阈值时闪白色轮廓（可闪烁）/免疫伤害/免疫特感控制/被控即解控，并支持每回合一次自动救起；1.2.0 追加未接管生还者移速与守护数量阶梯",
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

	// 按 workspace 约定：不生成插件 cfg（不用 AutoExecConfig），
	// 全部参数由 applemod12v12 的 confogl_addcvar 下发
	ParseGlowColor();
	g_cvGlowColor.AddChangeHook(OnConVarChanged);
	g_cvInterval.AddChangeHook(OnConVarChanged);
	g_cvProtectInterval.AddChangeHook(OnConVarChanged);
	// 1.2.0：移速倍率改了要立刻重写一遍（不必等下一 tick）
	g_cvBotSpeed.AddChangeHook(OnConVarChanged);
	g_cvBaseSpeed.AddChangeHook(OnConVarChanged);

	HookEvent("player_incapacitated", Event_PlayerIncapacitated, EventHookMode_Post);
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);

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

	StartTickTimer();
	StartProtectTimer();
}

public void OnMapStart()
{
	g_bBlinkPhase = false;
	g_iAiSurvivors = 0;
	g_iDownCount = 0;
	g_iGuardAllowed = 0;
	g_iGuardCount = 0;

	for (int i = 0; i <= MaxClients; i++)
	{
		g_bGuarded[i] = false;
		g_fTempStash[i] = 0.0;
		// 换图后实体重建，m_flLaggedMovementValue 自然是 1.0，只需要清掉标记
		g_bSpeedApplied[i] = false;
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
	int iDown = CountDownedSurvivors();
	int iStanding = iAlive - iDown;
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
		return Plugin_Handled;

	return Plugin_Continue;
}

// 猎人扑击
public Action L4D_OnPouncedOnSurvivor(int victim, int attacker)
{
	if (BlockControlOn(victim))
		return Plugin_Handled;

	return Plugin_Continue;
}

// 猴子骑乘
public Action L4D2_OnJockeyRide(int victim, int attacker)
{
	if (BlockControlOn(victim))
		return Plugin_Handled;

	return Plugin_Continue;
}

// 牛冲撞抱人
public Action L4D2_OnStartCarryingVictim(int victim, int attacker)
{
	if (BlockControlOn(victim))
		return Plugin_Handled;

	return Plugin_Continue;
}

// 牛捶打（charger pummel）：1.2.3 新增。left4dhooks 有前置 forward（注意参数顺序是 attacker, victim），
// 拦下来比"被捶打后再 EndPummel"干净 —— 玩家反馈守护中的 bot 仍会被牛捶打/拖走就是这个缺口
public Action L4D2_OnPummelVictim(int attacker, int victim)
{
	if (BlockControlOn(victim))
		return Plugin_Handled;

	return Plugin_Continue;
}

// 牛把人撞到墙上（会造成倒地/致残伤害）：守护中的生还者直接吃掉这次撞墙
public Action L4D2_OnSlammedSurvivor(int victim, int attacker, bool &bWallSlam, bool &bDeadlyCharge)
{
	if (BlockControlOn(victim))
		return Plugin_Handled;

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

	ReplyToCommand(client, "\x04[BotGuard]\x01 倒地人数=%d / 存活生还者=%d（未倒地 %d）→ 可守护数=%d；存活未接管生还者=%d；当前守护人数=%d 名单: %s",
		g_iDownCount,
		CountAliveSurvivors(),
		CountAliveSurvivors() - g_iDownCount,
		g_iGuardAllowed,
		g_iAiSurvivors,
		g_iGuardCount,
		sGuardList);

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
