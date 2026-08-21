#pragma semicolon 1
#pragma newdecls required

// 头文件
#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#include <colors>

#define CVAR_FLAG FCVAR_NOTIFY
#define INVALID_CLIENT -1
/* 检测吃铁的时间间隔需要少于伤害统计输出时间间隔(0.3s)，否则 round_end 无法检测最后吃铁 */
#define IRON_CHECK_INTERVAL 0.2
// 从 Tank 死亡到开始输出伤害的延迟时间, 如果有插件在这个时间前踢出 Tank 会无法打印伤害
#define DAMAGE_DISPLAY_DELAY 0.3
// Tank 控制权交接事件触发后, 复查"谁是 Tank"的延迟时间（职业切换可能在事件触发后才完成）
#define TANK_PASS_RECHECK_DELAY 0.1

#define SOUND_PATH "ui/pickup_secret01.wav"
#define PLUGIN_PREFIX "[TankDamage]"
/* 排名数据单元格字符串大小(参考插件 l4d2_tank_ranking 的 MAX_SIZE) */
#define DATA_CELL_SIZE 32

// 日志级别（与旧 logger.inc 行为一致: 按位相加, 1=禁用）
#define LOG_LEVEL_OFF (1 << 0)
#define LOG_LEVEL_DEBUG (1 << 1)
#define LOG_LEVEL_INFO (1 << 2)

// 团队类型（原 treeutil.inc 枚举）
enum
{
	TEAM_SPECTATOR = 1,
	TEAM_SURVIVOR,
	TEAM_INFECTED
}

// 感染者类型: Tank（原 treeutil.inc 枚举, 对应 m_zombieClass 值）
enum
{
	ZC_TANK = 8
}

public Plugin myinfo =
{
	name 			= "Tank Damage Announce 3.0",
	author 			= "apples1949",
	description 	= "Tank 伤害统计 3.0 版本: 数据跟随 Tank 实例, 控制权多次交接后死亡仍输出全部数据",
	version 		= "3.1",
	url 			= "https://steamcommunity.com/id/saku_ra/"
}

ConVar
	g_hAllowAnnounce,
	g_hAllowForceKillAnnounce,
	g_hAllowPrintLiveTime,
	g_hMissionFailedAnnounce,
	g_hAllowPrintZeroDamage,
	g_hAllowSound;
ConVar
	g_hLogLevel;

/* Tank 受到来自玩家的伤害，tankId，clientId */
int
	tankHurt[MAXPLAYERS + 1][MAXPLAYERS + 1],
	// Tank 血量记录（生成时的满血基准, 百分比分母）
	tankHealth[MAXPLAYERS + 1];

float
	// 这个 Tank 的存活时间
	tankLiveTime[MAXPLAYERS + 1];

bool
	// 插件是否延迟加载
	lateLoad,
	// 是否已经打印过这个 Tank 的伤害统计
	hasPrintDamage[MAXPLAYERS + 1];

Handle
	ironCheckTimer[MAXPLAYERS + 1][2];

// 当前 Tank 实例的控制者客户端索引（单一 Tank 跟踪, 数据随控制权交接转移）
int
	g_iCurrentTank;

/* 玩家受到来自 Tank 伤害结构体，tankId，clientId */
enum struct PlayerHurt
{
	int punch;
	int rock;
	int iron;
	int gotDamage;
	void init() {
		this.punch = this.rock = this.iron = this.gotDamage = 0;
	}
}
PlayerHurt playerHurts[MAXPLAYERS + 1][MAXPLAYERS + 1];

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {

	EngineVersion version = GetEngineVersion();
	if (version != Engine_Left4Dead2) {
		strcopy(error, err_max, "本插件仅适用于 Left 4 Dead 2");
		return APLRes_SilentFailure;
	}

	lateLoad = late;
	return APLRes_Success;
}

public void OnPluginStart()
{
	g_hAllowAnnounce = CreateConVar("tank_damage_enable", "1", "是否允许在 Tank 死亡后输出生还者对 Tank 的伤害统计", CVAR_FLAG, true, 0.0, true, 1.0);
	g_hAllowForceKillAnnounce = CreateConVar("tank_damage_force_kill_announce", "1", "Tank 被强制处死或自杀时是否输出生还者对 Tank 的伤害统计", CVAR_FLAG, true, 0.0, true, 1.0);
	g_hAllowPrintLiveTime = CreateConVar("tank_damage_print_livetime", "1", "是否显示 Tank 存活时间", CVAR_FLAG, true, 0.0, true, 1.0);
	g_hMissionFailedAnnounce = CreateConVar("tank_damage_failed_announce", "1", "生还者团灭时在场还有 Tank 是否显示生还者对 Tank 的伤害统计", CVAR_FLAG, true, 0.0, true, 1.0);
	g_hAllowPrintZeroDamage = CreateConVar("tank_damage_print_zero", "1", "是否允许显示对 Tank 零伤的玩家", CVAR_FLAG, true, 0.0, true, 1.0);
	g_hAllowSound = CreateConVar("tank_damage_allow_sound", "1", "Tank 生成时是否播放声音", CVAR_FLAG, true, 0.0, true, 1.0);
	// 日志记录（默认 62 = 全部级别: DEBUG+INFO+MESSAGE+SERVER+ERROR）
	g_hLogLevel = CreateConVar("tank_damage_log_level", "62", "插件日志记录级别 (1: 禁用, 2: DEBUG, 4: INFO, 8: MESSAGE, 16: SERVER, 32: ERROR) 数字相加 (62: 全部)", CVAR_FLAG, true, 1.0);

	// HookEvents
	HookEvent("round_start", roundStartHandler);
	HookEvent("player_spawn", playerSpawnHandler);
	HookEvent("player_death", playerDeathHandler);
	HookEvent("round_end", roundEndHandler);
	HookEvent("player_hurt", playerHurtHandler);
	// Tank 控制权交接
	HookEvent("player_now_it", playerNowItHandler);
	HookEvent("player_bot_replace", playerBotReplaceHandler);
	HookEvent("bot_player_replace", botPlayerReplaceHandler);

	// 插件延迟加载
	if (lateLoad) {
		for (int i = 1; i <= MaxClients; i++) {
			if (!IsClientInGame(i))
				continue;
			SDKHook(i, SDKHook_OnTakeDamage, onTakeDamageHandler);
			// 若加载时场上已有 Tank, 从当前时刻开始跟踪
			if (isTank(i) && IsPlayerAlive(i)) {
				g_iCurrentTank = i;
				tankLiveTime[i] = GetGameTime();
			}
		}
	}
}

public void OnAllPluginsLoaded() {
	if (!LibraryExists("left4dhooks")) {
		LogMessage	("\n==========\n本插件需要前置插件 \"[L4D & L4D2] Left 4 DHooks Direct\" 方可运行\n==========\n");
		SetFailState("\n==========\n本插件需要前置插件 \"[L4D & L4D2] Left 4 DHooks Direct\" 方可运行\n==========\n");
	}
	if (LibraryExists("l4d2_tank_swap"))
		LogMessage("已检测到 l4d2_tank_swap: 换克主动告知 forward 已就绪");
}

public void OnClientPutInServer(int client) {
	SDKHook(client, SDKHook_OnTakeDamage, onTakeDamageHandler);
}

public void OnMapStart() {
	PrecacheSound(SOUND_PATH);
}

/* 替代 logger.inc 的 Logger.debugAndInfo: OFF 位(1)置位时静默, DEBUG 位(2)输出到所有控制台, INFO 位(4)写入专属日志文件 tank_damage.log */
void debugAndInfoLog(const char[] message, any ...) {
	int level = g_hLogLevel.IntValue;
	if (level & LOG_LEVEL_OFF)
		return;
	char buffer[512];
	VFormat(buffer, sizeof(buffer), message, 3);
	if (level & LOG_LEVEL_DEBUG)
		PrintToConsoleAll(buffer);
	if (level & LOG_LEVEL_INFO)
		LogToFileEx("tank_damage.log", buffer);
}

/* 检测生还者是否吃铁: 生还者被 Tank 抛掷的可砸物体(带 m_hasTankGlow)击中 */
public Action onTakeDamageHandler(int victim, int& attacker, int& inflictor, float& damage, int& damagetype) {
	// 无效受害者或攻击者: 受害者必须是生还者, 攻击者必须是感染者（吃铁伤害来自 Tank, 定时器回调中还会再校验一次）
	if (!IsValidSurvivor(victim) || !IsValidInfected(attacker))
		return Plugin_Continue;
	// 检查令目标受到伤害的实体是否有效
	if (!IsValidEntity(inflictor) || !IsValidEdict(inflictor))
		return Plugin_Continue;
	// 检查实体是否具有 Tank 可打物体的发光特性
	if (!HasEntProp(inflictor, Prop_Send, "m_hasTankGlow") || GetEntProp(inflictor, Prop_Send, "m_hasTankGlow", 1) != 1)
		return Plugin_Continue;
	/* 生还者吃到的是铁 */
	/* 第一次未创建时钟，需要删除重新创建，后续吃到多次伤害也需要删除重新创建，因此无需判断时钟是否为 null */
	delete ironCheckTimer[victim][0];
	delete ironCheckTimer[victim][1];
	DataPack pack = new DataPack();
	// 存 userid 而非客户端索引: 回调时受害者可能已掉线且索引被复用, 用 userid 解析可避免记错对象
	pack.WriteCell(GetClientUserId(attacker));
	pack.WriteCell(GetClientUserId(victim));
	ironCheckTimer[victim][0] = CreateTimer(IRON_CHECK_INTERVAL, checkIronHandler, pack);
	ironCheckTimer[victim][1] = pack;
	return Plugin_Continue;
}

public Action checkIronHandler(Handle timer, DataPack pack)
{
	if (pack == null)
		return Plugin_Continue;
	pack.Reset();
	int attacker = GetClientOfUserId(pack.ReadCell()), victim = GetClientOfUserId(pack.ReadCell());
	delete pack;
	if (!isTank(attacker) || !IsValidSurvivor(victim))
	{
		// victim 已解析为 0 时(原受害者掉线), 只清理索引 0 的占位槽, 不影响新占用该索引的玩家
		ironCheckTimer[victim][0] = null;
		ironCheckTimer[victim][1] = null;
		return Plugin_Stop;
	}
	playerHurts[attacker][victim].iron++;
	ironCheckTimer[victim][0] = null;
	ironCheckTimer[victim][1] = null;
	return Plugin_Stop;
}

public void playerHurtHandler(Event event, const char[] name, bool dontBroadcast) {

	int attacker,
		victim,
		damage;
	attacker = GetClientOfUserId(event.GetInt("attacker"));
	victim = GetClientOfUserId(event.GetInt("userid"));
	damage = event.GetInt("dmg_health");

	static char weapon[64];
	event.GetString("weapon", weapon, sizeof(weapon));

	if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker))
		return;
	if (victim < 1 || victim > MaxClients || !IsClientInGame(victim))
		return;
	if (!IsPlayerAlive(attacker) || !IsPlayerAlive(victim))
		return;

	// Tank 对玩家造成伤害
	if (isTank(attacker) && IsValidSurvivor(victim)) {
		playerHurts[attacker][victim].gotDamage += damage;
		// 判断玩家是吃拳还是吃石
		if (strcmp(weapon, "tank_claw") == 0)
			playerHurts[attacker][victim].punch++;
		else if (strcmp(weapon, "tank_rock") == 0)
			playerHurts[attacker][victim].rock++;
	} else if (IsValidSurvivor(attacker) && isTank(victim)) {
		// 玩家对 Tank 造成伤害（致死一击的补偿在 player_death 中用"满血基准 - 已统计伤害"的差额计算, 不依赖易失的剩余血量记录）
		tankHurt[victim][attacker] += damage;
	}
}

public void playerSpawnHandler(Event event, const char[] name, bool dontBroadcast) {
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!isTank(client) || !IsPlayerAlive(client))
		return;

	/* 数据初始化只针对全新 Tank 实例:
	   1) 当前跟踪着另一个有数据的 Tank → 交接产生的新 Tank, 数据由转移事件继承, 不初始化;
	   2) 跟踪指针已指向自己且有数据 → 转移事件先于本事件完成, 同样不初始化 */
	bool isTakeover = false;
	if (g_iCurrentTank != 0 && g_iCurrentTank != client && tankDataExists(g_iCurrentTank))
		isTakeover = true;
	if (!isTakeover && g_iCurrentTank == client && tankDataExists(client))
		isTakeover = true;

	if (!isTakeover) {
		/* 全新 Tank 实例生成 */
		g_iCurrentTank = client;
		/* 清空这个 Tank 的伤害统计 */
		clearTankDamage(client);
		tankLiveTime[client] = GetGameTime();
		hasPrintDamage[client] = false;
		/* 延迟一帧获取 Tank 血量，否则可能获取不到 */
		RequestFrame(nextFrameGetTankHealthHandler, client);
	}

	/* 显示 Tank 生成并播放提示音: 全新生成与接管都提示, 与旧版行为一致 */
	if (!IsFakeClient(client))
		CPrintToChatAll("[{green}!{default}] {green}Tank {default}({green}%N{default}) {blue}已经生成", client);
	else
		CPrintToChatAll("[{green}!{default}] {green}Tank {default}({green}AI{default}) {blue}已经生成");
	if (g_hAllowSound.BoolValue)
		EmitSoundToAll(SOUND_PATH);
}

public void nextFrameGetTankHealthHandler(int client)
{
	if (!isTank(client) || !IsPlayerAlive(client))
		return;
	// 若血量已被控制权转移继承（新 Tank 接管后满血基准不变），不覆盖
	if (tankHealth[client] > 0)
		return;
	tankHealth[client] = GetEntProp(client, Prop_Data, "m_iHealth");
	debugAndInfoLog("%s: Tank(%N), 索引 %d, 当前血量 %d", PLUGIN_PREFIX, client, client, tankHealth[client]);
}

public void playerDeathHandler(Event event, const char[] name, bool dontBroadcast) {
	int attacker = GetClientOfUserId(event.GetInt("attacker")), victim = GetClientOfUserId(event.GetInt("userid"));
	if (!isTank(victim))
		return;

	/* 数据已随控制权交接(L4D_OnReplaceTank 前置转移)给了新 Tank:
	   这个"死亡"是换克过程中引擎处死旧克产生的, 该实例仍在由新克续命, 不结算不打印 */
	if (!tankDataExists(victim))
		return;

	/* 当前 Tank 实例死亡, 重置跟踪（数据仍保留在 victim 索引上供 0.3s 后打印）。
	   只有当前跟踪值就是 victim 时才清零, 防止换克后旧克的死亡事件把指向新克的跟踪值清掉 */
	if (g_iCurrentTank == victim)
		g_iCurrentTank = 0;

	/* 致死一击通常不触发 player_hurt, 用差额法补偿击杀者:
	   补偿 = 满血基准 - 已统计的全部生还者伤害。差额法不依赖"最后剩余血量"这种易失状态,
	   控制权转移、事件时序颠倒都不会造成过度补偿, 且每人伤害永远不会超过满血基准 */
	if (IsValidSurvivor(attacker) && IsPlayerAlive(attacker)) {
		int recordedDamage = 0;
		for (int i = 1; i <= MaxClients; i++)
			recordedDamage += tankHurt[victim][i];
		int remainDamage = tankHealth[victim] - recordedDamage;
		if (remainDamage > 0)
			tankHurt[victim][attacker] += remainDamage;
	}
	/* 计算 Tank 存活时间 */
	tankLiveTime[victim] = GetGameTime() - tankLiveTime[victim];
	/* 是否是强制杀死、自杀或被环境杀死（无有效攻击者） */
	if ((!IsValidClient(attacker) || attacker == victim) && !g_hAllowForceKillAnnounce.BoolValue)
		return;
	/* 如果已经显示过了 Tank 伤害，则不再显示 */
	if (hasPrintDamage[victim])
		return;

	// 否则创建时钟准备显示 Tank 的伤害报告
	DataPack pack = new DataPack();
	pack.WriteCell(victim);
	pack.WriteString("死亡");
	CreateTimer(DAMAGE_DISPLAY_DELAY, printTankDamageHandler, pack);
	hasPrintDamage[victim] = true;
}

/* 回合开始，清空所有人的 Tank 伤害统计 */
public void roundStartHandler(Event event, const char[] name, bool dontBroadcast)
{
	clearTankDamage(INVALID_CLIENT);
}

public void roundEndHandler(Event event, const char[] name, bool dontBroadcast) {
	if (!g_hMissionFailedAnnounce.BoolValue)
		return;

	// 检测生还者是否全部死亡，如果全部死亡且场上存在 Tank，显示 Tank 伤害统计
	if (isSurvivorFailed()) {
		for (int i = 1; i <= MaxClients; i++) {
			if (!isTank(i) || !IsPlayerAlive(i))
				continue;
			// 计算 Tank 存活时长
			tankLiveTime[i] = GetGameTime() - tankLiveTime[i];
			if (tankLiveTime[i] < 0)
				continue;

			int health = GetEntProp(i, Prop_Data, "m_iHealth");
			if (health < 0 || tankHealth[i] < 1)
				continue;
			int percent = RoundToNearest(float(health) / float(tankHealth[i]) * 100.0);

			CPrintToChatAll("[{green}!{default}] {green}%N {default}剩余 {green}%d{default}({green}%d%%{default}) {blue}血量", i, health, percent);

			// 如果已经显示过了 Tank 伤害，则不再显示
			if (hasPrintDamage[i])
				continue;

			// 否则创建时钟延迟显示 Tank 伤害(回合结束, 坦克随回合消失)
			DataPack pack = new DataPack();
			pack.WriteCell(i);
			pack.WriteString("消失");
			CreateTimer(DAMAGE_DISPLAY_DELAY, printTankDamageHandler, pack);
			hasPrintDamage[i] = true;
		}
	}
}

public Action printTankDamageHandler(Handle timer, DataPack pack) {
	pack.Reset();
	int client = pack.ReadCell();
	char reason[16];
	pack.ReadString(reason, sizeof(reason));
	delete pack;

	if (!IsValidClient(client))
		return Plugin_Stop;

	doPrintTankDamage(client, reason);
	return Plugin_Stop;
}

/**
* Tank 控制权交接(前置): left4dhooks 在引擎执行 ZombieManager::ReplaceTank 之前调用。
* 覆盖 l4d2_tank_swap 的 L4D_ReplaceTank 主动换克、喷胆汁等引擎内部换克等全部路径,
* 且不依赖 player_death / player_now_it / player_bot_replace 的事件先后顺序。
* 注意: 回调时新克职业可能尚未切换成 Tank, 不能按 isTank 判断, 直接信任 forward 参数。
**/
public void L4D_OnReplaceTank(int oldTank, int newTank)
{
	handleTankPass(oldTank, newTank, "L4D_OnReplaceTank 前置转移");
}

/**
* l4d2_tank_swap 换克成功后的主动告知（双保险, 与引擎 forward 幂等）:
* 引擎 forward 已转移时这里为空操作; 引擎 forward 缺失/未触发时兜底转移。
**/
public void L4D2_TankSwap_OnTankPassed(int oldTank, int newTank)
{
	handleTankPass(oldTank, newTank, "tankswap 主动告知");
}

/**
* 换克数据处理公共入口: 校验参数 → 确定数据持有者 → 转移数据 → 更新跟踪指针。
* 幂等: 数据已被转移(旧索引已清空)时不会重复转移, 只同步跟踪指针。
* @param oldTank 旧 Tank 客户端索引
* @param newTank 新 Tank 客户端索引
* @param logTag  日志来源标识(引擎 forward / tankswap 主动告知)
**/
void handleTankPass(int oldTank, int newTank, const char[] logTag)
{
	if (oldTank <= 0 || oldTank > MaxClients || newTank <= 0 || newTank > MaxClients)
		return;
	if (oldTank == newTank || !IsClientInGame(newTank))
		return;

	// 数据持有者以参数为准; 参数上无数据而当前跟踪值有数据(历史遗留不同步)时回退到跟踪值
	int sourceTank = oldTank;
	if (!tankDataExists(sourceTank)
		&& g_iCurrentTank > 0
		&& g_iCurrentTank != newTank
		&& tankDataExists(g_iCurrentTank))
	{
		sourceTank = g_iCurrentTank;
	}

	if (!tankDataExists(sourceTank))
	{
		// 没有可转移的数据(如目标本就是新生成的 Tank 被再次交接), 只更新跟踪指针
		g_iCurrentTank = newTank;
		return;
	}

	debugAndInfoLog("%s: %s, 由 %N(%d) 转到 %N(%d)", PLUGIN_PREFIX, logTag, sourceTank, sourceTank, newTank, newTank);
	transferTankData(sourceTank, newTank);
	g_iCurrentTank = newTank;
}

/**
* Tank 控制权交接: player_now_it 事件的 userid 即新 Tank。
* 注意事件的 attacker 字段是"造成换人的玩家"（如喷胆汁的 Boomer），不是旧 Tank，因此旧 Tank 取自插件自身跟踪的 g_iCurrentTank。
* @param event 事件
**/
public void playerNowItHandler(Event event, const char[] name, bool dontBroadcast) {
	int newTank = GetClientOfUserId(event.GetInt("userid"));
	int causer = GetClientOfUserId(event.GetInt("attacker"));
	if (IsValidInfected(newTank) && isTank(newTank)) {
		// 事件触发时职业已切换完成, 直接交接
		resolveTankPass(newTank);
	} else {
		// 职业可能尚未切换完成, 延迟复查（pack 同时携带事件触发时跟踪到的旧 Tank, 防时序颠倒导致数据丢失）
		DataPack pack = new DataPack();
		pack.WriteCell(newTank);
		pack.WriteCell(causer);
		pack.WriteCell(g_iCurrentTank);
		CreateTimer(TANK_PASS_RECHECK_DELAY, tankPassRecheckHandler, pack);
	}
}

/**
* Bot 接管了玩家（玩家掉线/挂机, 旧 Tank 交给 Bot 即"变成游戏控制"）
**/
public void playerBotReplaceHandler(Event event, const char[] name, bool dontBroadcast) {
	DataPack pack = new DataPack();
	pack.WriteCell(GetClientOfUserId(event.GetInt("player")));
	pack.WriteCell(GetClientOfUserId(event.GetInt("bot")));
	pack.WriteCell(g_iCurrentTank);
	CreateTimer(TANK_PASS_RECHECK_DELAY, tankPassRecheckHandler, pack);
}

/**
* 玩家接管了 Bot（如玩家接管 AI Tank）
**/
public void botPlayerReplaceHandler(Event event, const char[] name, bool dontBroadcast) {
	DataPack pack = new DataPack();
	pack.WriteCell(GetClientOfUserId(event.GetInt("player")));
	pack.WriteCell(GetClientOfUserId(event.GetInt("bot")));
	pack.WriteCell(g_iCurrentTank);
	CreateTimer(TANK_PASS_RECHECK_DELAY, tankPassRecheckHandler, pack);
}

public Action tankPassRecheckHandler(Handle timer, DataPack pack)
{
	pack.Reset();
	int player = pack.ReadCell(), bot = pack.ReadCell(), oldTank = pack.ReadCell();
	delete pack;

	// 两者中现在是 Tank 的那个就是新 Tank
	int newTank;
	if (IsValidInfected(player) && isTank(player))
		newTank = player;
	else if (IsValidInfected(bot) && isTank(bot))
		newTank = bot;
	else
		return Plugin_Stop;

	resolveTankPass(newTank, oldTank);
	return Plugin_Stop;
}

/**
* 处理 Tank 控制权交接: 把旧控制者的全部数据转移到新控制者, 保证数据跟随 Tank 实例。
* 幂等性: 转移后旧索引数据被清空, 同一对交接的重复事件(如 player_now_it 与换人事件同时触发)再次执行时
* 提示与跟踪值都已失效, 不会重复转移。
* @param newTank 新的 Tank 控制者客户端索引
* @param oldTankHint 交接事件触发时跟踪到的旧 Tank 索引(延迟复查用, 立即路径传 0 回退到当前跟踪值)
**/
void resolveTankPass(int newTank, int oldTankHint = 0)
{
	if (!IsValidInfected(newTank) || !isTank(newTank))
		return;

	// 优先使用事件触发时跟踪到的数据持有者; 其数据已失效时, 若当前跟踪值仍是事件时的那个(局势未变)则回退到它;
	// 局势已变(期间又发生了一次交接)则不强行转移, 只更新跟踪值, 避免把数据转给错误的对象
	int oldTank = oldTankHint;
	if (oldTank == 0 || oldTank == newTank || !tankDataExists(oldTank)) {
		if (oldTankHint == 0 || oldTankHint == g_iCurrentTank)
			oldTank = g_iCurrentTank;
		else
			oldTank = 0;
	}

	if (oldTank != 0 && oldTank != newTank && tankDataExists(oldTank))
		transferTankData(oldTank, newTank);

	g_iCurrentTank = newTank;
}

/**
* 该索引上是否存有 Tank 实例数据（tankHealth 在生成后一帧才有值, 此前用存活时间判断）
* @param client 需要判断的客户端索引
* @return bool 有数据返回 true
**/
bool tankDataExists(int client)
{
	return tankHealth[client] > 0 || tankLiveTime[client] > 0.0;
}

/**
* 把旧 Tank 控制者索引上的全部数据转移到新控制者索引（数据跟随 Tank 实例而非玩家）
* @param oldTank 旧 Tank 控制者客户端索引（可能已掉线, 数据仍在数组中）
* @param newTank 新 Tank 控制者客户端索引
**/
void transferTankData(int oldTank, int newTank)
{
	if (oldTank == newTank)
		return;

	debugAndInfoLog("%s: Tank 控制权转换, 由 %N(%d) 转到 %N(%d), 转移伤害/承伤/血量/存活时间数据", PLUGIN_PREFIX, oldTank, oldTank, newTank, newTank);

	// 转移生还者对 Tank 的伤害与 Tank 对生还者的伤害明细
	for (int i = 1; i <= MaxClients; i++) {
		tankHurt[newTank][i] = tankHurt[oldTank][i];
		tankHurt[oldTank][i] = 0;
		playerHurts[newTank][i] = playerHurts[oldTank][i];
		playerHurts[oldTank][i].init();
	}
	// 转移满血基准、存活时间与打印标记（存活时间沿用最初生成时刻, 保证统计的是整个 Tank 实例的存活时长）
	tankHealth[newTank] = tankHealth[oldTank];
	tankLiveTime[newTank] = tankLiveTime[oldTank];
	hasPrintDamage[newTank] = hasPrintDamage[oldTank];

	// 清空旧控制者的数据
	tankHealth[oldTank] = 0;
	tankLiveTime[oldTank] = 0.0;
	hasPrintDamage[oldTank] = false;
}

/**
* 打印 Tank 伤害报告(输出格式对齐 l4d2_tank_ranking v1.5.9: 标题含总血量/总伤害, 排名行居中排列)
* @param client 需要打印的 Tank 客户端索引
* @param reason 坦克消失原因(死亡 / 消失), 用于标题行
* @return void
**/
void doPrintTankDamage(int client, const char[] reason = "死亡") {
	if (!g_hAllowAnnounce.BoolValue)
		return;
	// 不是有效客户端索引, 返回, 必须要在 DAMAGE_DISPLAY_DELAY 时间后再踢出 Tank
	if (!IsValidClient(client))
		return;
	// 无效的 Tank 血量
	if (tankHealth[client] < 1)
		return;

	// 统计在场生还者数量, 汇总总伤害与总承伤
	int i, index, totalDamage, totalGotDamage;
	for (i = 1; i <= MaxClients; i++) {
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR)
			continue;
		index++;
		totalDamage += tankHurt[client][i];
		totalGotDamage += playerHurts[client][i].gotDamage;
	}
	// 没有生还者在场, 无需统计
	if (index < 1)
		return;

	// 收集每个生还者的排名数据: 0=客户端索引, 1=对 Tank 的伤害
	int[][] survivorDamage = new int[index][2];
	index = 0;
	for (i = 1; i <= MaxClients; i++) {
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR)
			continue;
		survivorDamage[index][0] = i;
		survivorDamage[index++][1] = tankHurt[client][i];
	}
	// 按照玩家对 Tank 的伤害降序排序
	SortCustom2D(survivorDamage, index, sortByDamageDesc);

	// 过滤不需要显示的行(零伤玩家由 ConVar 控制)
	int displayCount = 0;
	for (i = 0; i < index; i++)
		if (g_hAllowPrintZeroDamage.BoolValue || survivorDamage[i][1] > 0)
			displayCount++;
	if (displayCount < 1)
		return;

	/* 预格式化每行数据(列布局与参考插件 l4d2_tank_ranking 一致并扩展全部数据列):
	   0=名次, 1=伤害百分比(1位小数), 2=伤害, 3=名字, 4=拳, 5=石, 6=铁, 7=承伤, 8=承伤百分比 */
	char[][][] sData = new char[displayCount][9][DATA_CELL_SIZE];
	// 百分比分母: 总伤害超过满血基准(含致死一击补偿)时用总伤害, 与参考插件一致
	int iTotalHealth = totalDamage > tankHealth[client] ? totalDamage : tankHealth[client];
	int x = 0;
	for (i = 0; i < index; i++) {
		int survivor = survivorDamage[i][0];
		int damage = survivorDamage[i][1];
		if (damage < 1 && !g_hAllowPrintZeroDamage.BoolValue)
			continue;

		FormatEx(sData[x][0], DATA_CELL_SIZE, "%d", x + 1);
		FormatEx(sData[x][1], DATA_CELL_SIZE, "%.1f", float(damage) / float(iTotalHealth) * 100.0);
		FormatEx(sData[x][2], DATA_CELL_SIZE, "%d", damage);
		GetClientName(survivor, sData[x][3], DATA_CELL_SIZE);
		FormatEx(sData[x][4], DATA_CELL_SIZE, "%d", playerHurts[client][survivor].punch);
		FormatEx(sData[x][5], DATA_CELL_SIZE, "%d", playerHurts[client][survivor].rock);
		FormatEx(sData[x][6], DATA_CELL_SIZE, "%d", playerHurts[client][survivor].iron);
		FormatEx(sData[x][7], DATA_CELL_SIZE, "%d", playerHurts[client][survivor].gotDamage);
		FormatEx(sData[x][8], DATA_CELL_SIZE, "%d", totalGotDamage == 0 ? 0 : RoundToNearest(float(playerHurts[client][survivor].gotDamage) / float(totalGotDamage) * 100.0));

		debugAndInfoLog("%s: %N 对 Tank(%N) 的伤害报告: 总伤害 %d, 拳 %d, 石 %d, 铁 %d, 承伤 %d", PLUGIN_PREFIX, survivor, client, damage, playerHurts[client][survivor].punch, playerHurts[client][survivor].rock, playerHurts[client][survivor].iron, playerHurts[client][survivor].gotDamage);
		x++;
	}

	// 计算各数据列的最大宽度, 用于居中对齐(与参考插件一致: 左右各补 (最大宽度-本行宽度) 个空格)
	int iMax[9];
	for (int y = 0; y < 9; y++)
		iMax[y] = strlen(sData[0][y]);
	for (x = 1; x < displayCount; x++)
		for (int y = 0; y < 9; y++)
			if (strlen(sData[x][y]) > iMax[y])
				iMax[y] = strlen(sData[x][y]);

	// 坦克名字: AI 去掉名字里的 "Tank" 前缀, 人类玩家带队伍色, 与参考插件一致
	char sIndex[32];
	if (IsFakeClient(client)) {
		GetClientName(client, sIndex, sizeof(sIndex));
		SplitString(sIndex, "Tank", sIndex, sizeof(sIndex));
	} else {
		FormatEx(sIndex, sizeof(sIndex), "\x03%N", client);
	}

	// 标题行: 坦克{名}{原因},总血量:{血量}{+超额伤害}HP. 换行 显示伤害排名:(总伤害:{总数})
	char sInfo[128], sTemp[2][64];
	FormatEx(sTemp[0], sizeof(sTemp[]), "\x05总血量\x04:\x03%d", tankHealth[client]);
	if (totalDamage > tankHealth[client])
		FormatEx(sTemp[1], sizeof(sTemp[]), "\x04+\x03%d", totalDamage - tankHealth[client]);
	ImplodeStrings(sTemp, sizeof(sTemp), "", sInfo, sizeof(sInfo));
	PrintToChatAll("\x04坦克%s\x03%s\x04,%s\x05HP\x04.\n\x05显示伤害排名\x04:\x03(\x05总伤害\x04:\x05%d\x03)", sIndex, reason, sInfo, totalDamage);

	// 显示 Tank 存活时间
	if (g_hAllowPrintLiveTime.BoolValue) {
		if (!IsFakeClient(client))
			CPrintToChatAll("{green}%N {blue}存活时间：{green}%s", client, getTime(tankLiveTime[client]));
		else
			CPrintToChatAll("{green}Tank {blue}存活时间：{green}%s", getTime(tankLiveTime[client]));
	}

	// 逐行输出: 名次(居中):[伤害百分比(居中)%](伤害(居中))[拳(居中)][石(居中)][铁(居中)][承伤(居中)(承伤百分比(居中)%] 名字
	char row[512], cell[64];
	for (x = 0; x < displayCount; x++) {
		row[0] = '\0';
		// 名次(居中) + 冒号 + [伤害百分比(居中)%]
		AppendPad(row, sizeof(row), iMax[0] - strlen(sData[x][0]));
		FormatEx(cell, sizeof(cell), "\x04%s", sData[x][0]);
		StrCat(row, sizeof(row), cell);
		AppendPad(row, sizeof(row), iMax[0] - strlen(sData[x][0]));
		FormatEx(cell, sizeof(cell), "\x05:\x03[");
		StrCat(row, sizeof(row), cell);
		AppendPad(row, sizeof(row), iMax[1] - strlen(sData[x][1]));
		FormatEx(cell, sizeof(cell), "\x04%s", sData[x][1]);
		StrCat(row, sizeof(row), cell);
		AppendPad(row, sizeof(row), iMax[1] - strlen(sData[x][1]));
		FormatEx(cell, sizeof(cell), "\x04%%\x03]");
		StrCat(row, sizeof(row), cell);
		// (伤害(居中))
		FormatEx(cell, sizeof(cell), "\x03(\x04");
		StrCat(row, sizeof(row), cell);
		AppendPad(row, sizeof(row), iMax[2] - strlen(sData[x][2]));
		FormatEx(cell, sizeof(cell), "%s", sData[x][2]);
		StrCat(row, sizeof(row), cell);
		AppendPad(row, sizeof(row), iMax[2] - strlen(sData[x][2]));
		FormatEx(cell, sizeof(cell), "\x03)");
		StrCat(row, sizeof(row), cell);
		// [拳(居中)] [石(居中)] [铁(居中)]
		FormatEx(cell, sizeof(cell), "\x03[\x04拳\x03:\x04");
		StrCat(row, sizeof(row), cell);
		AppendPad(row, sizeof(row), iMax[4] - strlen(sData[x][4]));
		FormatEx(cell, sizeof(cell), "%s", sData[x][4]);
		StrCat(row, sizeof(row), cell);
		AppendPad(row, sizeof(row), iMax[4] - strlen(sData[x][4]));
		FormatEx(cell, sizeof(cell), "\x03][\x04石\x03:\x04");
		StrCat(row, sizeof(row), cell);
		AppendPad(row, sizeof(row), iMax[5] - strlen(sData[x][5]));
		FormatEx(cell, sizeof(cell), "%s", sData[x][5]);
		StrCat(row, sizeof(row), cell);
		AppendPad(row, sizeof(row), iMax[5] - strlen(sData[x][5]));
		FormatEx(cell, sizeof(cell), "\x03][\x04铁\x03:\x04");
		StrCat(row, sizeof(row), cell);
		AppendPad(row, sizeof(row), iMax[6] - strlen(sData[x][6]));
		FormatEx(cell, sizeof(cell), "%s", sData[x][6]);
		StrCat(row, sizeof(row), cell);
		AppendPad(row, sizeof(row), iMax[6] - strlen(sData[x][6]));
		// [承伤(居中)(承伤百分比(居中)%]
		FormatEx(cell, sizeof(cell), "\x03][\x04承伤\x03:\x04");
		StrCat(row, sizeof(row), cell);
		AppendPad(row, sizeof(row), iMax[7] - strlen(sData[x][7]));
		FormatEx(cell, sizeof(cell), "%s", sData[x][7]);
		StrCat(row, sizeof(row), cell);
		AppendPad(row, sizeof(row), iMax[7] - strlen(sData[x][7]));
		FormatEx(cell, sizeof(cell), "\x03(\x04");
		StrCat(row, sizeof(row), cell);
		AppendPad(row, sizeof(row), iMax[8] - strlen(sData[x][8]));
		FormatEx(cell, sizeof(cell), "%s", sData[x][8]);
		StrCat(row, sizeof(row), cell);
		AppendPad(row, sizeof(row), iMax[8] - strlen(sData[x][8]));
		FormatEx(cell, sizeof(cell), "\x04%%\x03)]");
		StrCat(row, sizeof(row), cell);
		// 名字
		FormatEx(cell, sizeof(cell), "\x05%s", sData[x][3]);
		StrCat(row, sizeof(row), cell);

		PrintToChatAll("%s", row);
	}
}

/* 追加 N 个空格(居中对齐填充, 与参考插件 l4d2_tank_ranking 的 IsWritesData 行为一致) */
void AppendPad(char[] buffer, int size, int count) {
	if (count < 0)
		count = 0;
	for (int i = 0; i < count; i++)
		StrCat(buffer, size, " ");
}

/* 按照伤害对 survivorDamage[][] 进行降序排序，伤害相同则按照玩家索引降序排序 */
int sortByDamageDesc(int[] elem1, int[] elem2, const int[][] array, Handle hndl)
{
	return elem1[1] > elem2[1] ? -1 : elem1[1] == elem2[1] ? elem1[0] > elem2[0] ? -1 : elem1[0] == elem2[0] ? 0 : 1 : 1;
}

bool isTank(int client) {
	return IsValidInfected(client) && GetEntProp(client, Prop_Send, "m_zombieClass") == ZC_TANK;
}

bool isSurvivorFailed() {
	for (int i = 1; i <= MaxClients; i++) {
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR)
			continue;
		if (IsPlayerAlive(i) && !IsClientIncapped(i))
			return false;
	}
	return true;
}

void clearTankDamage(int client) {
	int i, j;
	/* Tank 生成时，这是个克，清除这个克的伤害统计 */
	if (client != INVALID_CLIENT)
	{
		tankHealth[client] = 0;
		for (i = 1; i <= MaxClients; i++)
		{
			tankHurt[client][i] = 0;
			playerHurts[client][i].init();
		}
	}
	else
	{
		/* 清空所有人的 Tank 伤害统计 */
		g_iCurrentTank = 0;
		for (i = 1; i <= MaxClients; i++)
		{
			hasPrintDamage[i] = false;
			tankHealth[i] = 0;
			tankLiveTime[i] = 0.0;
			for (j = 1; j <= MaxClients; j++)
			{
				tankHurt[i][j] = 0;
				playerHurts[i][j].init();
			}
		}
	}
}

char[] getTime(float time)
{
	char result[64] = {'\0'};
	int exacTime = RoundToNearest(time);
	if (exacTime < 60) { FormatEx(result, sizeof(result), "%d秒", exacTime); }
	else if (exacTime < 3600)
	{
		int minute = exacTime / 60, second = exacTime % 60;
		FormatEx(result, sizeof(result), "%d分钟%d秒", minute, second);
	}
	else
	{
		int hour = exacTime / 3600, minute = (exacTime % 3600) / 60, second = (exacTime % 3600) % 60;
		FormatEx(result, sizeof(result), "%d小时%d分钟%d秒", hour, minute, second);
	}
	return result;
}

/* 判断是否有效玩家 id，有效返回 true，无效返回 false（原 treeutil.inc 库存函数） */
stock bool IsValidClient(int client)
{
	return client > 0 && client <= MaxClients && IsClientInGame(client);
}
/* 判断生还者是否有效，有效返回 true，无效返回 false（原 treeutil.inc 库存函数） */
stock bool IsValidSurvivor(int client)
{
	return IsValidClient(client) && GetClientTeam(client) == TEAM_SURVIVOR;
}
/* 判断玩家是否倒地，倒地返回 true，未倒地返回 false（原 treeutil.inc 库存函数） */
stock bool IsClientIncapped(int client)
{
	if (!IsValidClient(client) || !IsPlayerAlive(client)) { return false; }
	return view_as<bool>(GetEntProp(client, Prop_Send, "m_isIncapacitated"));
}
/* 判断感染者是否有效，有效返回 true，无效返回 false（原 treeutil.inc 库存函数） */
stock bool IsValidInfected(int client)
{
	return IsValidClient(client) && GetClientTeam(client) == TEAM_INFECTED;
}
