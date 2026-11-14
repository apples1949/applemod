#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>
#include <colors>

#define PLUGIN_VERSION "1.3.0"

#define TEAM_SURVIVOR 2

/*
 *	投掷物冷却（土雷 / 燃烧瓶 / 胆汁瓶）
 *
 *	v1.2.0 重做了拦截结构，四层 + 一个兜底：
 *	  第 0 层（关键修复）在 *Projectile_Pre 里"放行即置位"：
 *	        旧版只在 _Post（投掷物实体已生成之后）才启动冷却，从
 *	        "引擎决定生成投掷物"到"_Post 执行"之间有一段窗口，窗口内
 *	        再次投掷（同一 tick 的多条 usercmd、投掷动画期间的第二颗）
 *	        都能通过 _Pre 检查，于是出现"几乎同时扔出两颗"。
 *	        现在钩子一确认这一颗合法，立刻把冷却写进去（同一 tick 内
 *	        _Pre 是串行执行的，所以第二颗的 _Pre 必然看到冷却已生效）。
 *	  第 1 层 OnPlayerRunCmd 前置拦截：冷却中且手里/待切的是投掷物时，
 *	        清 IN_ATTACK + 取消切枪请求，投掷动作根本不会开始。
 *	  第 2 层 *Projectile_Pre 兜底：即使某条 usercmd 绕过了第 1 层，
 *	        引擎级投掷物创建也会被 Supercede 掉（不会生成实体）。
 *	  第 3 层 同 tick 二次投掷保护：记录本 tick 已放行过的投掷，本 tick
 *	        内第二次一律拦截（防止 _Pre 竞态/多命令突发）。
 *	  兜底层 _Post：如果 _Pre 因任何原因没被调用到，_Post 仍会补一次
 *	        置位，避免"漏一次冷却"。
 *
 *	覆盖类型：weapon_pipe_bomb / weapon_molotov / weapon_vomitjar 统一判定。
 *	冷却按 client 独立记录（float 数组 + 每 client 的 Timer）。
 *	sm_grenade_cooldown_scope 控制"共享范围"：1=全队共享（默认，与原版
 *	线上语义一致：一段时间内全队只能扔一个），0=每人独立。
 *
 *	sm_grenade_cooldown_enable 0 时完全不拦。
 *
 *	------------------ v1.3.0：冷却时长改为"投掷物持续时长 + 1 秒" ------------------
 *	需求：不需要再配冷却秒数 —— 扔出「雷」或「胆汁」，冷却自动等于该投掷物的
 *	实际持续时长再加 1 秒：
 *	  · 土制炸弹：读投掷物实体的 `m_flDetonateTime`（datamap，CPipeBombProjectile），
 *	    冷却结束时刻 = 引信爆炸时刻 + 1 秒。这样即使服务器用
 *	    `l4d2_pipebomb_duration_offset` 改过引信，冷却也会自动跟着变。
 *	  · 胆汁瓶：等它炸出来的 `info_goal_infected_chase`（胆汁地面吸引点）消失，
 *	    冷却结束时刻 = 胆汁结束时刻 + 1 秒；3 秒内没抓到吸引点则回退到
 *	    BILE_FALLBACK(20) + 1 秒。
 *	  · 燃烧瓶：保持原样，用 sm_grenade_cooldown_time（未改需求）。
 *	投掷瞬间仍会先按"兜底时长"立刻置位（保持 v1.2.0 的"放行即置位"防双扔语义），
 *	随后在 _Post / 胆汁结束回调里把结束时刻**重新校正**成上面算出来的值。
 *	sm_grenade_cooldown_time 现在只对燃烧瓶生效（<=0 时用 MOLOTOV_FALLBACK）。
 */

#define THROWABLE_COUNT 3

// v1.3.0：冷却 = 投掷物实际持续时长 + 这 1 秒
#define COOLDOWN_EXTRA        1.0
// 读不到 m_flDetonateTime 时，土雷引信兜底时长（引擎默认 6 秒）
#define PIPE_FUSE_FALLBACK    6.0
// 3 秒内没抓到胆汁吸引点时，胆汁持续时长兜底
#define BILE_FALLBACK         20.0
// 投掷后多久内出现的 info_goal_infected_chase 算作这颗胆汁瓶炸出来的
#define BILE_WATCH_WINDOW     3.0
// 燃烧瓶：sm_grenade_cooldown_time <= 0 时的兜底冷却
#define MOLOTOV_FALLBACK      7.0

#define CLASS_BILE_GOAL       "info_goal_infected_chase"
#define ENTPROP_PARENT        "m_pParent"

ConVar g_cvEnable;
ConVar g_cvCooldownTime;
ConVar g_cvScope;
ConVar g_cvDebug;

static const char g_sThrowableClasses[THROWABLE_COUNT][] = {
	"weapon_pipe_bomb",
	"weapon_molotov",
	"weapon_vomitjar"
};

float  g_fCooldownEnd[MAXPLAYERS + 1];   // 冷却结束时间（0.0 = 未冷却），真正的判定依据
Handle g_hCooldownTimer[MAXPLAYERS + 1]; // 每 client 一个，只负责播报"冷却结束"
float  g_fLastHintTime[MAXPLAYERS + 1];  // 聊天提示限流
int    g_iLastThrowTick[MAXPLAYERS + 1]; // 本 tick 已放行过投掷（同 tick 保护）
int    g_iArmTick[MAXPLAYERS + 1];       // 该 client 的冷却是在哪个 tick 由我们置位的
bool   g_bBlockedByUs[MAXPLAYERS + 1];   // 该 client 上一次被拦是我们拦的（用于区分退款）

// v1.3.0：胆汁瓶"等胆汁地面消失再结算冷却"的跟踪状态
bool   g_bBileWatch;                     // 正在等这颗胆汁瓶炸出的吸引点
float  g_fBileThrowAt;                   // 胆汁投掷时刻
int    g_iBileGoal;                      // 抓到的 info_goal_infected_chase 实体
float  g_fBileGoalAt;                    // 该实体生成时刻
int    g_iBileThrower;                   // 谁扔的（用于把冷却结算到他/全队）
Handle g_hBileWatchTimer;                // 兜底：抓不到吸引点时按 BILE_FALLBACK 收尾

public Plugin myinfo = {
	name        = "L4D2 Throwable Cooldown",
	description = "土雷/燃烧瓶/胆汁瓶投掷冷却：放行即置位，冷却中从输入层与引擎层双重拦截",
	author      = "apples1949",
	version     = PLUGIN_VERSION,
	url         = ""
};

// ============================================================================
// 生命周期
// ============================================================================

public void OnPluginStart()
{
	g_cvEnable = CreateConVar("sm_grenade_cooldown_enable", "1",
		"1=启用投掷物冷却；0=完全不拦截", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvCooldownTime = CreateConVar("sm_grenade_cooldown_time", "16.0",
		"投掷一颗后的冷却秒数；<=0 表示完全不拦截", _, true, 0.0, true, 600.0);
	g_cvScope = CreateConVar("sm_grenade_cooldown_scope", "1",
		"1=全队共享冷却（一段时间内全队只能扔一个，原版语义）；0=每个玩家各自冷却", _, true, 0.0, true, 1.0);
	g_cvDebug = CreateConVar("sm_grenade_cooldown_debug", "0",
		"1=把放行/拦截原因打到服务器控制台，便于线上确认", _, true, 0.0, true, 1.0);

	RegAdminCmd("sm_grenadecd", Cmd_GrenadeCd, ADMFLAG_GENERIC, "查看投掷物冷却状态：sm_grenadecd");

	// 晚加载：把已经在服的玩家状态初始化干净
	for (int i = 1; i <= MaxClients; i++)
		ResetClientState(i);
}

public void OnMapEnd()
{
	for (int i = 1; i <= MaxClients; i++)
		ResetClientState(i);

	// v1.3.0：换图时清掉胆汁跟踪，避免带着上一张图的实体索引
	g_bBileWatch = false;
	g_iBileGoal = 0;
	g_fBileGoalAt = 0.0;
	g_iBileThrower = 0;

	if (g_hBileWatchTimer != null)
	{
		KillTimer(g_hBileWatchTimer);
		g_hBileWatchTimer = null;
	}
}

public void OnClientPutInServer(int client)
{
	if (client < 1 || client > MaxClients)
		return;

	ResetClientState(client);
}

public void OnClientDisconnect(int client)
{
	if (client < 1 || client > MaxClients)
		return;

	ResetClientState(client);
}

// ============================================================================
// 状态工具
// ============================================================================

void ResetClientState(int client)
{
	if (client < 1 || client > MaxClients)
		return;

	if (g_hCooldownTimer[client] != null) {
		KillTimer(g_hCooldownTimer[client]);
		g_hCooldownTimer[client] = null;
	}

	g_fCooldownEnd[client]   = 0.0;
	g_fLastHintTime[client]  = 0.0;
	g_iLastThrowTick[client] = -1;
	g_iArmTick[client]       = -1;
	g_bBlockedByUs[client]    = false;
}

void ResetCooldownOnly(int client)
{
	if (client < 1 || client > MaxClients)
		return;

	if (g_hCooldownTimer[client] != null) {
		KillTimer(g_hCooldownTimer[client]);
		g_hCooldownTimer[client] = null;
	}

	g_fCooldownEnd[client] = 0.0;
}

bool IsValidClient(int client)
{
	return client >= 1 && client <= MaxClients && IsClientInGame(client);
}

bool IsEnabled()
{
	// v1.3.0：冷却时长不再依赖 sm_grenade_cooldown_time（那个现在只对燃烧瓶生效），
	// 所以自动时长模式下不能因为 time<=0 就整体失效，只看总开关。
	return g_cvEnable.BoolValue;
}

bool IsCoolingDown(int client)
{
	if (!IsEnabled() || !IsValidClient(client))
		return false;

	return g_fCooldownEnd[client] > GetGameTime();
}

// scope=1 时：只要队里还有人在冷却，就算锁定
bool IsTeamCoolingDown()
{
	float now = GetGameTime();

	for (int i = 1; i <= MaxClients; i++) {
		if (IsValidClient(i) && g_fCooldownEnd[i] > now)
			return true;
	}

	return false;
}

// 权威判定：该 client 现在能不能扔
bool IsThrowLocked(int client)
{
	if (!IsEnabled())
		return false;

	if (g_cvScope.IntValue == 1 && IsTeamCoolingDown())
		return true;

	return IsCoolingDown(client);
}

// 同 tick 二次投掷保护
bool IsSameTickThrow(int client)
{
	if (!IsEnabled() || !IsValidClient(client))
		return false;

	return g_iLastThrowTick[client] == GetGameTickCount();
}

void ArmClientCooldown(int client, float duration)
{
	if (!IsValidClient(client))
		return;

	if (duration <= 0.0)
		return;

	g_fCooldownEnd[client] = GetGameTime() + duration;

	if (g_hCooldownTimer[client] != null) {
		KillTimer(g_hCooldownTimer[client]);
		g_hCooldownTimer[client] = null;
	}

	// Timer 只负责播报；真正判定看 g_fCooldownEnd，所以 timer 丢失也不会"卡冷却"
	g_hCooldownTimer[client] = CreateTimer(duration, Timer_CooldownEnd, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

void ArmCooldown(int thrower, float duration)
{
	if (!IsEnabled())
		return;

	// scope=1（全队共享）或拿不到投掷者身份时，给全服存活玩家一起置位，
	// 宁可多拦一次，也不允许"身份不明的那颗雷"绕开限制。
	if (g_cvScope.IntValue == 1 || !IsValidClient(thrower)) {
		for (int i = 1; i <= MaxClients; i++) {
			if (IsValidClient(i))
				ArmClientCooldown(i, duration);
		}
		return;
	}

	ArmClientCooldown(thrower, duration);
}

/**
 * v1.3.0：按"绝对结束时刻"重新校正冷却（用于：
 *   · 土雷 —— 用投掷物真实的 m_flDetonateTime 结算；
 *   · 胆汁 —— 等胆汁地面消失后结算）。
 * 与投掷瞬间置位的兜底时长相比，这里会把结束时刻改成 endTime（早到会缩短，晚到会延长）。
 */
void SetCooldownEnd(int thrower, float endTime)
{
	float remain = endTime - GetGameTime();

	if (remain <= 0.0)
	{
		// 已经到点：直接清掉冷却（兜底时长比真实时长长的情况）
		if (g_cvScope.IntValue == 1 || !IsValidClient(thrower))
		{
			for (int i = 1; i <= MaxClients; i++)
			{
				if (IsValidClient(i))
					ResetCooldownOnly(i);
			}
		}
		else
		{
			ResetCooldownOnly(thrower);
		}

		return;
	}

	ArmCooldown(thrower, remain);
}

/**
 * v1.3.0：投掷瞬间先按兜底时长置位（保住 v1.2.0「放行即置位」的防同 tick 双扔语义），
 * 随后由 _Post / 胆汁结束回调校正成真实时长 + 1 秒。
 */
float GetProvisionalDuration(const char[] sType)
{
	if (StrEqual(sType, "pipebomb", false))
		return PIPE_FUSE_FALLBACK + COOLDOWN_EXTRA;

	if (StrEqual(sType, "vomitjar", false))
		return BILE_FALLBACK + COOLDOWN_EXTRA;

	// 燃烧瓶：维持原行为，用 cvar
	float t = g_cvCooldownTime.FloatValue;
	if (t <= 0.0)
		t = MOLOTOV_FALLBACK;

	return t;
}

void NotifyCooldownStart(int thrower)
{
	// v1.3.0：实际时长在 _Post / 胆汁结束时会校正，这里只报"当前置位的兜底时长"
	float duration = 0.0;
	float now = GetGameTime();

	if (IsValidClient(thrower))
		duration = g_fCooldownEnd[thrower] - now;
	else {
		for (int i = 1; i <= MaxClients; i++) {
			if (IsValidClient(i) && g_fCooldownEnd[i] - now > duration)
				duration = g_fCooldownEnd[i] - now;
		}
	}

	if (duration <= 0.0)
		return;

	if (g_cvScope.IntValue == 1) {
		char name[64];
		if (IsValidClient(thrower))
			GetClientName(thrower, name, sizeof(name));
		else
			strcopy(name, sizeof(name), "有人");

		for (int i = 1; i <= MaxClients; i++) {
			if (IsClientInGame(i) && GetClientTeam(i) == TEAM_SURVIVOR && IsPlayerAlive(i))
				CPrintToChat(i, "{green}[投掷物冷却] {default}%s 扔出了投掷物，{olive}%.0f 秒{default}内全队不能再扔！", name, duration);
		}
		return;
	}

	if (IsValidClient(thrower))
		CPrintToChat(thrower, "{green}[投掷物冷却] {default}已投掷，{olive}%.0f 秒{default}内不能再扔投掷物。", duration);
}

void HintBlocked(int client, bool bThrowAttempt)
{
	float now = GetGameTime();
	if (now - g_fLastHintTime[client] < 2.0)
		return;

	g_fLastHintTime[client] = now;

	float remain = g_fCooldownEnd[client] - now;
	if (remain < 0.0)
		remain = 0.0;

	if (bThrowAttempt)
		CPrintToChat(client, "{green}[投掷物冷却] {default}冷却中，还有 {olive}%.1f 秒{default}才能扔投掷物！", remain);
	else
		CPrintToChat(client, "{green}[投掷物冷却] {default}冷却中，暂时不能切出投掷物！");
}

// ============================================================================
// 投掷物判定
// ============================================================================

bool IsThrowableEntity(int entity)
{
	if (entity <= 0 || !IsValidEntity(entity))
		return false;

	char classname[64];
	GetEdictClassname(entity, classname, sizeof(classname));

	for (int i = 0; i < THROWABLE_COUNT; i++) {
		if (StrEqual(classname, g_sThrowableClasses[i], false))
			return true;
	}

	return false;
}

// ============================================================================
// 第 1 层 - OnPlayerRunCmd 前置拦截（投掷动作发生前）
// ============================================================================

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3],
                             int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	if (!IsEnabled())
		return Plugin_Continue;

	if (!IsValidClient(client))
		return Plugin_Continue;

	if (GetClientTeam(client) != TEAM_SURVIVOR || !IsPlayerAlive(client))
		return Plugin_Continue;

	bool bLocked  = IsThrowLocked(client);
	bool bSameTick = IsSameTickThrow(client);
	if (!bLocked && !bSameTick)
		return Plugin_Continue;

	// 手里拿的是投掷物，或者这条命令正在切向投掷物
	bool bHoldsThrowable = IsThrowableEntity(GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon"));
	bool bSelectingThrowable = (weapon > 0 && IsValidEntity(weapon) && IsThrowableEntity(weapon));

	if (!bHoldsThrowable && !bSelectingThrowable)
		return Plugin_Continue;

	bool bAttacking = (buttons & IN_ATTACK) != 0;

	if (!bAttacking && !bSelectingThrowable)
		return Plugin_Continue;

	// 取消"切出土雷"的请求：避免切出来的同一 tick 直接投掷
	if (bSelectingThrowable)
		weapon = 0;

	// 清掉投掷输入。投掷物没有左键普通攻击，所以这里不会误伤其它操作；
	// 右键（IN_ATTACK2）推搡不受影响。
	if (bAttacking)
		buttons &= ~IN_ATTACK;

	ShortcutBlockLog(client, "RunCmd", bAttacking ? "IN_ATTACK" : "weapon_select");
	HintBlocked(client, bAttacking);

	return Plugin_Changed;
}

// ============================================================================
// 第 0 / 2 / 3 层 - 投掷物创建前的放行与拦截
// ============================================================================

Action HandleProjectilePre(int client, const char[] sType)
{
	if (!IsEnabled())
		return Plugin_Continue;

	// 拿不到投掷者身份：无法按 client 记账，全队共享模式下仍然按队伍状态拦，
	// 每人独立模式下只能放行（避免误拦所有人）。
	if (!IsValidClient(client)) {
		if (g_cvScope.IntValue == 1 && IsTeamCoolingDown()) {
			DebugLog("BLOCK %s: invalid thrower=%d, team cooling down", sType, client);
			return Plugin_Handled;
		}

		DebugLog("ALLOW %s: invalid thrower=%d, cannot attribute", sType, client);
		return Plugin_Continue;
	}

	// 只有幸存者会扔这三种投掷物；非幸存者放行且不记账
	if (GetClientTeam(client) != TEAM_SURVIVOR) {
		DebugLog("ALLOW %s: %N is not survivor", sType, client);
		return Plugin_Continue;
	}

	if (IsThrowLocked(client)) {
		g_bBlockedByUs[client] = true;
		DebugLog("BLOCK %s: %N still cooling down (%.1fs left, tick %d)", sType, client,
			g_fCooldownEnd[client] - GetGameTime(), GetGameTickCount());
		return Plugin_Handled;
	}

	if (IsSameTickThrow(client)) {
		g_bBlockedByUs[client] = true;
		DebugLog("BLOCK %s: %N already threw in tick %d", sType, client, GetGameTickCount());
		return Plugin_Handled;
	}

	// 放行即置位：这一颗合法，冷却立刻生效，本 tick / 后续 tick 的第二颗都会被拦住
	int tick = GetGameTickCount();
	g_iLastThrowTick[client] = tick;
	g_iArmTick[client] = tick;
	g_bBlockedByUs[client] = false;

	float fProvisional = GetProvisionalDuration(sType);
	ArmCooldown(client, fProvisional);
	NotifyCooldownStart(client);

	DebugLog("ALLOW+ARM %s: %N (tick %d, provisional %.1fs)", sType, client, tick, fProvisional);
	return Plugin_Continue;
}

void HandleProjectileCreated(int client, const char[] sType, int projectile)
{
	if (!IsEnabled())
		return;

	if (!IsValidClient(client))
		return;

	g_iArmTick[client] = -1;
	g_bBlockedByUs[client] = false;

	// 兜底：_Pre 万一没被调用到，_Post 也补一次置位（正常路径下这里已经在冷却中）
	if (!IsCoolingDown(client) && !IsTeamCoolingDown()) {
		g_iLastThrowTick[client] = GetGameTickCount();
		ArmCooldown(client, GetProvisionalDuration(sType));
		NotifyCooldownStart(client);
		DebugLog("ALLOW+ARM(late) %s: %N (tick %d)", sType, client, GetGameTickCount());
	}

	// v1.3.0：把兜底时长校正成「该投掷物真实持续时长 + 1 秒」
	if (StrEqual(sType, "pipebomb", false))
	{
		AdjustCooldownByFuse(client, projectile);
	}
	else if (StrEqual(sType, "vomitjar", false))
	{
		StartBileWatch(client);
	}

	DebugLog("CREATED %s: %N (projectile=%d)", sType, client, projectile);
}

// 土雷：冷却结束 = 真实引信爆炸时刻 + COOLDOWN_EXTRA
void AdjustCooldownByFuse(int client, int projectile)
{
	float now = GetGameTime();
	float fuse = PIPE_FUSE_FALLBACK;

	if (projectile > 0 && IsValidEntity(projectile) && HasEntProp(projectile, Prop_Data, "m_flDetonateTime"))
	{
		float det = GetEntPropFloat(projectile, Prop_Data, "m_flDetonateTime");
		if (det > now)
			fuse = det - now;
	}

	SetCooldownEnd(client, now + fuse + COOLDOWN_EXTRA);
	DebugLog("PIPE fuse=%.2fs -> cooldown %.2fs", fuse, fuse + COOLDOWN_EXTRA);
}

// 胆汁：等 info_goal_infected_chase 消失，冷却结束 = 消失时刻 + COOLDOWN_EXTRA
void StartBileWatch(int client)
{
	if (g_hBileWatchTimer != null)
	{
		KillTimer(g_hBileWatchTimer);
		g_hBileWatchTimer = null;
	}

	g_bBileWatch = true;
	g_fBileThrowAt = GetGameTime();
	g_iBileGoal = 0;
	g_fBileGoalAt = 0.0;
	g_iBileThrower = client;

	// 兜底：3 秒内没抓到吸引点（砸空/没炸出胆汁），按 BILE_FALLBACK + 1 收尾
	g_hBileWatchTimer = CreateTimer(BILE_WATCH_WINDOW, Timer_BileWatchTimeout, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_BileWatchTimeout(Handle timer, any userid)
{
	g_hBileWatchTimer = null;

	if (!g_bBileWatch || g_iBileGoal != 0)
		return Plugin_Stop;

	int thrower = GetClientOfUserId(userid);
	g_bBileWatch = false;

	SetCooldownEnd(thrower, GetGameTime() + BILE_FALLBACK + COOLDOWN_EXTRA);
	DebugLog("BILE fallback: no attract goal -> %.0fs", BILE_FALLBACK + COOLDOWN_EXTRA);
	return Plugin_Stop;
}

// 胆汁地面实体出现：认领它（之后以它消失的时刻结算）
public void OnEntityCreated(int entity, const char[] classname)
{
	if (!g_bBileWatch || g_iBileGoal != 0)
		return;

	if (!StrEqual(classname, CLASS_BILE_GOAL))
		return;

	// 胆汁瓶炸出来的吸引点没有父级；小丑/Jimmy 挂身上的那种有 m_pParent
	if (GetEntPropEnt(entity, Prop_Data, ENTPROP_PARENT) != -1)
		return;

	if (GetGameTime() - g_fBileThrowAt > BILE_WATCH_WINDOW)
		return;

	g_iBileGoal = entity;
	g_fBileGoalAt = GetGameTime();
	DebugLog("BILE goal ent=%d claimed, waiting for it to expire", entity);
}

// 胆汁地面消失：结算「胆汁时长 + 1 秒」
public void OnEntityDestroyed(int entity)
{
	if (!g_bBileWatch || g_iBileGoal == 0 || entity != g_iBileGoal)
		return;

	float duration = GetGameTime() - g_fBileGoalAt;
	g_bBileWatch = false;
	g_iBileGoal = 0;

	if (g_hBileWatchTimer != null)
	{
		KillTimer(g_hBileWatchTimer);
		g_hBileWatchTimer = null;
	}

	SetCooldownEnd(g_iBileThrower, GetGameTime() + COOLDOWN_EXTRA);
	DebugLog("BILE expired after %.2fs -> cooldown %.2fs", duration, duration + COOLDOWN_EXTRA);
}

void HandleProjectileBlocked(int client, const char[] sType)
{
	if (client < 1 || client > MaxClients)
		return;

	// 我们自己拦的：保留冷却，什么都不做
	if (g_bBlockedByUs[client]) {
		g_bBlockedByUs[client] = false;
		return;
	}

	// 不是本 tick 由我们放行的那一次，说明与我们无关
	if (g_iArmTick[client] != GetGameTickCount())
		return;

	// 本 tick 我们放行了这一颗，但被别的插件在 _Pre 拦掉了（没有生成实体）：
	// 把冷退还回去，避免"没扔出去却进入 16 秒冷却"。
	g_iArmTick[client] = -1;
	g_iLastThrowTick[client] = -1;
	ResetCooldownOnly(client);

	DebugLog("REFUND %s: %N creation blocked by another plugin", sType, client);
}

// ============================================================================
// Left4DHooks 回调（三种投掷物）
// ============================================================================

public Action L4D_PipeBombProjectile_Pre(int client, float vecPos[3], float vecAng[3], float vecVel[3], float vecRot[3])
{
	return HandleProjectilePre(client, "pipebomb");
}

public void L4D_PipeBombProjectile_Post(int client, int projectile, const float vecPos[3], const float vecAng[3], const float vecVel[3], const float vecRot[3])
{
	HandleProjectileCreated(client, "pipebomb", projectile);
}

public void L4D_PipeBombProjectile_PostHandled(int client, int projectile, const float vecPos[3], const float vecAng[3], const float vecVel[3], const float vecRot[3])
{
	HandleProjectileBlocked(client, "pipebomb");
}

public Action L4D_MolotovProjectile_Pre(int client, float vecPos[3], float vecAng[3], float vecVel[3], float vecRot[3])
{
	return HandleProjectilePre(client, "molotov");
}

public void L4D_MolotovProjectile_Post(int client, int projectile, const float vecPos[3], const float vecAng[3], const float vecVel[3], const float vecRot[3])
{
	HandleProjectileCreated(client, "molotov", projectile);
}

public void L4D_MolotovProjectile_PostHandled(int client, int projectile, const float vecPos[3], const float vecAng[3], const float vecVel[3], const float vecRot[3])
{
	HandleProjectileBlocked(client, "molotov");
}

public Action L4D2_VomitJarProjectile_Pre(int client, float vecPos[3], float vecAng[3], float vecVel[3], float vecRot[3])
{
	return HandleProjectilePre(client, "vomitjar");
}

public void L4D2_VomitJarProjectile_Post(int client, int projectile, const float vecPos[3], const float vecAng[3], const float vecVel[3], const float vecRot[3])
{
	HandleProjectileCreated(client, "vomitjar", projectile);
}

public void L4D2_VomitJarProjectile_PostHandled(int client, int projectile, const float vecPos[3], const float vecAng[3], const float vecVel[3], const float vecRot[3])
{
	HandleProjectileBlocked(client, "vomitjar");
}

// ============================================================================
// 计时器 / 管理命令 / 日志
// ============================================================================

public Action Timer_CooldownEnd(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client < 1 || client > MaxClients)
		return Plugin_Stop;

	g_hCooldownTimer[client] = null;

	// 已经被新的冷却覆盖（时间轴还没到），交给新 timer 播报
	if (g_fCooldownEnd[client] > GetGameTime())
		return Plugin_Stop;

	g_fCooldownEnd[client] = 0.0;

	if (IsClientInGame(client) && GetClientTeam(client) == TEAM_SURVIVOR && IsPlayerAlive(client))
		CPrintToChat(client, "{green}[投掷物冷却] {default}冷却结束，可以再次扔投掷物了！");

	return Plugin_Stop;
}

public Action Cmd_GrenadeCd(int client, int args)
{
	ReplyToCommand(client, "[投掷物冷却] enable=%d time=%.1f scope=%d(1=全队共享 0=每人独立) debug=%d",
		g_cvEnable.BoolValue, g_cvCooldownTime.FloatValue, g_cvScope.IntValue, g_cvDebug.BoolValue);

	float now = GetGameTime();

	for (int i = 1; i <= MaxClients; i++) {
		if (!IsValidClient(i) || GetClientTeam(i) != TEAM_SURVIVOR)
			continue;

		float remain = g_fCooldownEnd[i] - now;
		if (remain < 0.0)
			remain = 0.0;

		ReplyToCommand(client, "[投掷物冷却] %N remaining=%.1fs last_throw_tick=%d arm_tick=%d",
			i, remain, g_iLastThrowTick[i], g_iArmTick[i]);
	}

	return Plugin_Handled;
}

void DebugLog(const char[] fmt, any ...)
{
	if (!g_cvDebug.BoolValue)
		return;

	char buffer[256];
	VFormat(buffer, sizeof(buffer), fmt, 2);
	PrintToServer("[grenade_cooldown] %s", buffer);
}

void ShortcutBlockLog(int client, const char[] sLayer, const char[] sReason)
{
	if (!g_cvDebug.BoolValue)
		return;

	char name[64];
	GetClientName(client, name, sizeof(name));
	PrintToServer("[grenade_cooldown] BLOCK(%s) %s: %s, tick=%d, remain=%.1fs, scope=%d",
		sLayer, name, sReason, GetGameTickCount(), g_fCooldownEnd[client] - GetGameTime(), g_cvScope.IntValue);
}
