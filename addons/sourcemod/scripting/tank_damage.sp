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
	author 			= "夜羽真白",
	description 	= "Tank 伤害统计 3.0 版本: 数据跟随 Tank 实例, 控制权多次交接后死亡仍输出全部数据",
	version 		= "2024/1/1",
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
	// Tank 血量记录
	tankHealth[MAXPLAYERS + 1],
	// Tank 死亡前血量记录
	tankLastHealth[MAXPLAYERS + 1];

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
	// 日志记录
	g_hLogLevel = CreateConVar("tank_damage_log_level", "1", "插件日志记录级别 (1: 禁用, 2: DEBUG, 4: INFO, 8: MESSAGE, 16: SERVER, 32: ERROR) 数字相加", CVAR_FLAG, true, 1.0);

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
}

public void OnClientPutInServer(int client) {
	SDKHook(client, SDKHook_OnTakeDamage, onTakeDamageHandler);
}

public void OnMapStart() {
	PrecacheSound(SOUND_PATH);
}

/* 替代 logger.inc 的 Logger.debugAndInfo: OFF 位(1)置位时静默, DEBUG 位(2)输出到所有控制台, INFO 位(4)写入日志 */
void debugAndInfoLog(const char[] message, any ...) {
	int level = g_hLogLevel.IntValue;
	if (level & LOG_LEVEL_OFF)
		return;
	char buffer[512];
	VFormat(buffer, sizeof(buffer), message, 3);
	if (level & LOG_LEVEL_DEBUG)
		PrintToConsoleAll(buffer);
	if (level & LOG_LEVEL_INFO)
		LogMessage(buffer);
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
		damage,
		remainHealth;
	attacker = GetClientOfUserId(event.GetInt("attacker"));
	victim = GetClientOfUserId(event.GetInt("userid"));
	damage = event.GetInt("dmg_health");
	remainHealth = event.GetInt("health");

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
		// 玩家对 Tank 造成伤害
		tankHurt[victim][attacker] += damage;
		// Tank 有死亡动画，最后一次伤害不会算入 playerHurt 中，因此需要记录最后一次剩余血量，Tank 死亡时加入到生还者伤害中
		tankLastHealth[victim] = remainHealth;
	}
}

public void playerSpawnHandler(Event event, const char[] name, bool dontBroadcast) {
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!isTank(client) || !IsPlayerAlive(client))
		return;

	/* 若当前仍追踪着另一个有数据的 Tank, 说明这是一次控制权交接产生的新 Tank（如接管 AI Tank、
	   或旧 Tank 掉线后 Bot 补位），数据将由 player_now_it / 换人事件转移过来，这里不做初始化，
	   避免清空或覆盖继承自旧控制者的数据 */
	if (g_iCurrentTank != 0 && g_iCurrentTank != client && tankDataExists(g_iCurrentTank))
		return;
	// 极端时序保护: 若转移事件先于本事件执行(此时跟踪指针已指向该客户端), 数据已继承完毕, 不再初始化
	if (g_iCurrentTank == client && tankDataExists(client))
		return;

	/* 全新 Tank 实例生成 */
	g_iCurrentTank = client;
	/* 清空这个 Tank 的伤害统计 */
	clearTankDamage(client);
	tankLiveTime[client] = GetGameTime();
	hasPrintDamage[client] = false;
	/* 延迟一帧获取 Tank 血量，否则可能获取不到 */
	RequestFrame(nextFrameGetTankHealthHandler, client);
	/* 显示 Tank 生成 */
	if (!IsFakeClient(client))
		CPrintToChatAll("[{green}!{default}] {green}Tank {default}({green}%N{default}) {blue}已经生成", client);
	else
		CPrintToChatAll("[{green}!{default}] {green}Tank {default}({green}AI{default}) {blue}已经生成");
	// 播放声音
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

	/* 当前 Tank 实例死亡, 重置跟踪（数据仍保留在 victim 索引上供 0.3s 后打印）。
	   能走到这里的 victim 必是 Tank 实体, 无条件清零以保证下一个 Tank 正常初始化 */
	g_iCurrentTank = 0;

	/* 谁杀死了克，加 Tank 最后剩余的血量（致死一击不触发 player_hurt, 用最后记录的剩余血量补偿） */
	if (IsValidSurvivor(attacker) && IsPlayerAlive(attacker))
		tankHurt[victim][attacker] += tankLastHealth[victim];
	/* 计算 Tank 存活时间 */
	tankLiveTime[victim] = GetGameTime() - tankLiveTime[victim];
	/* 是否是强制杀死、自杀或被环境杀死（无有效攻击者） */
	if ((!IsValidClient(attacker) || attacker == victim) && !g_hAllowForceKillAnnounce.BoolValue)
		return;
	/* 如果已经显示过了 Tank 伤害，则不再显示 */
	if (hasPrintDamage[victim])
		return;

	// 否则创建时钟准备显示 Tank 的伤害报告
	CreateTimer(DAMAGE_DISPLAY_DELAY, printTankDamageHandler, victim);
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

			// 否则创建时钟延迟显示 Tank 伤害
			CreateTimer(DAMAGE_DISPLAY_DELAY, printTankDamageHandler, i);
			hasPrintDamage[i] = true;
		}
	}
}

public Action printTankDamageHandler(Handle timer, int client) {
	if (!IsValidClient(client))
		return Plugin_Stop;

	doPrintTankDamage(client);
	return Plugin_Stop;
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
		// 职业可能尚未切换完成, 延迟复查
		DataPack pack = new DataPack();
		pack.WriteCell(newTank);
		pack.WriteCell(causer);
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
	CreateTimer(TANK_PASS_RECHECK_DELAY, tankPassRecheckHandler, pack);
}

/**
* 玩家接管了 Bot（如玩家接管 AI Tank）
**/
public void botPlayerReplaceHandler(Event event, const char[] name, bool dontBroadcast) {
	DataPack pack = new DataPack();
	pack.WriteCell(GetClientOfUserId(event.GetInt("player")));
	pack.WriteCell(GetClientOfUserId(event.GetInt("bot")));
	CreateTimer(TANK_PASS_RECHECK_DELAY, tankPassRecheckHandler, pack);
}

public Action tankPassRecheckHandler(Handle timer, DataPack pack)
{
	pack.Reset();
	int player = pack.ReadCell(), bot = pack.ReadCell();
	delete pack;

	// 两者中现在是 Tank 的那个就是新 Tank
	int newTank;
	if (IsValidInfected(player) && isTank(player))
		newTank = player;
	else if (IsValidInfected(bot) && isTank(bot))
		newTank = bot;
	else
		return Plugin_Stop;

	resolveTankPass(newTank);
	return Plugin_Stop;
}

/**
* 处理 Tank 控制权交接: 把旧控制者的全部数据转移到新控制者, 保证数据跟随 Tank 实例。
* 通过 g_iCurrentTank 保证幂等: 同一对交接只执行一次（player_now_it 与换人事件可能同时触发）。
* @param newTank 新的 Tank 控制者客户端索引
**/
void resolveTankPass(int newTank)
{
	if (!IsValidInfected(newTank) || !isTank(newTank))
		return;
	if (newTank == g_iCurrentTank)
		return;

	int oldTank = g_iCurrentTank;
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
	// 转移满血基准、最后剩余血量、存活时间与打印标记（存活时间沿用最初生成时刻, 保证统计的是整个 Tank 实例的存活时长）
	tankHealth[newTank] = tankHealth[oldTank];
	tankLastHealth[newTank] = tankLastHealth[oldTank];
	tankLiveTime[newTank] = tankLiveTime[oldTank];
	hasPrintDamage[newTank] = hasPrintDamage[oldTank];

	// 清空旧控制者的数据
	tankHealth[oldTank] = 0;
	tankLastHealth[oldTank] = 0;
	tankLiveTime[oldTank] = 0.0;
	hasPrintDamage[oldTank] = false;
}

/**
* 打印 Tank 伤害报告
* @param client 需要打印的 Tank 客户端索引
* @return void
**/
void doPrintTankDamage(int client) {
	if (!g_hAllowAnnounce.BoolValue)
		return;
	// 不是有效客户端索引, 返回, 必须要在 DAMAGE_DISPLAY_DELAY 时间后再踢出 Tank
	if (!IsValidClient(client))
		return;
	// 无效的 Tank 血量
	if (tankHealth[client] < 1)
		return;

	// 显示标题
	if (!IsFakeClient(client))
		CPrintToChatAll("[{green}!{default}] {blue}生还者对 {green}Tank {default}({green}%N{default}) {blue}的伤害统计", client);
	else
		CPrintToChatAll("[{green}!{default}] {blue}生还者对 {green}Tank {default}({green}AI{default}) {blue}的伤害统计");

	// 显示 Tank 存活时间
	if (g_hAllowPrintLiveTime.BoolValue) {
		if (!IsFakeClient(client))
			CPrintToChatAll("[{green}!{default}] {green}%N {blue}存活时间：{green}%s", client, getTime(tankLiveTime[client]));
		else
			CPrintToChatAll("[{green}!{default}] {green}Tank {blue}存活时间：{green}%s", getTime(tankLiveTime[client]));
	}

	// 统计在场玩家数量
	int i, count, index;
	count = 0;
	index = 0;
	for (i = 1; i <= MaxClients; i++) {
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR)
			continue;
		count++;
	}
	// 没有生还者在场, 无需统计
	if (count < 1)
		return;

	int totalDamage, totalGotDamage, damagePercent;
	int[][] survivorDamage = new int[count][2];

	for (i = 1; i <= MaxClients; i++) {
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR)
			continue;

		totalDamage += tankHurt[client][i];
		totalGotDamage += playerHurts[client][i].gotDamage;
		damagePercent += getDamageAsPercent(tankHurt[client][i], tankHealth[client]);

		survivorDamage[index][0] = i;
		survivorDamage[index++][1] = tankHurt[client][i];

		debugAndInfoLog("%s: %N 对 Tank(%N) 的伤害报告: 总伤害 %d, 拳 %d, 石 %d, 铁 %d, 承伤 %d", PLUGIN_PREFIX, i, client, tankHurt[client][i], playerHurts[client][i].punch, playerHurts[client][i].rock, playerHurts[client][i].iron, playerHurts[client][i].gotDamage);
	}

	// 按照玩家对 Tank 的伤害降序排序
	SortCustom2D(survivorDamage, index, sortByDamageDesc);
	// 如果使用 getDamageAsPercent 获得的总伤害加起来小于 100 而大于 99.5，调整伤害百分比显示
	int percentAdjust,
		lastPercent,
		exactDamagePercent,
		survivor,
		damage;

	percentAdjust = 0, lastPercent = 100;
	if (damagePercent < 100 && float(totalDamage) > (tankHealth[client] - (tankHealth[client] / 200.0)))
		percentAdjust = 100 - damagePercent;

	char playerName[MAX_NAME_LENGTH];
	// 打印生还者对 Tank 的伤害：[666(%66)][拳:6(%6)][石:6(%6)][铁:6(%6)][承伤:666(%66)] 测试哥
	for (i = 0; i < index; i++) {
		// 获取到生还者索引和他对 Tank 的伤害
		survivor = survivorDamage[i][0];
		damage = survivorDamage[i][1];

		// 当前生还者无效, 跳过
		if (!IsValidClient(survivor) || GetClientTeam(survivor) != TEAM_SURVIVOR)
			continue;

		damagePercent = getDamageAsPercent(damage, tankHealth[client]);
		if (percentAdjust != 0 && damage > 0 && !isExactPercent(damage, tankHealth[client])) {
			exactDamagePercent = damagePercent + percentAdjust;

			if (exactDamagePercent <= lastPercent) {
				damagePercent = exactDamagePercent;
				percentAdjust = 0;
			}
		}

		// 允许显示零伤人员或不允许显示零伤人员但这个人的伤害大于 0，允许输出
		if (g_hAllowPrintZeroDamage.BoolValue || (!g_hAllowPrintZeroDamage.BoolValue && damage > 0)) {
			GetClientName(survivor, playerName, sizeof(playerName));

			debugAndInfoLog("%s: Tank %d, 生还索引: %d, 伤害 %d, 百分比 %d%%, 名字 %s", PLUGIN_PREFIX, client, survivor, damage, damagePercent, playerName);

			CPrintToChatAll("{blue}[{default}%d{blue}({default}%d%%{blue})]\
			 [{green}拳:{default}%d]\
			  [{green}石:{default}%d]\
			   [{green}铁:{default}%d]\
			    [{green}承伤:{default}%d{blue}({default}%d%%{blue})]\
				 {green}%s",
			damage, damagePercent,
			playerHurts[client][survivor].punch,
			playerHurts[client][survivor].rock,
			playerHurts[client][survivor].iron,
			playerHurts[client][survivor].gotDamage, totalGotDamage == 0 ? 0 : RoundToNearest(float(playerHurts[client][survivor].gotDamage) / float(totalGotDamage) * 100.0),
			playerName);
		}
	}
}

/* 按照伤害对 survivorDamage[][] 进行降序排序，伤害相同则按照玩家索引降序排序 */
int sortByDamageDesc(int[] elem1, int[] elem2, const int[][] array, Handle hndl)
{
	return elem1[1] > elem2[1] ? -1 : elem1[1] == elem2[1] ? elem1[0] > elem2[0] ? -1 : elem1[0] == elem2[0] ? 0 : 1 : 1;
}

bool isTank(int client) {
	return IsValidInfected(client) && GetEntProp(client, Prop_Send, "m_zombieClass") == ZC_TANK;
}

int getDamageAsPercent(int damage, int health) {
	if (damage < 1)
		return 0;
	return RoundToNearest((float(damage) / float(health)) * 100.0);
}

bool isExactPercent(int damage, int health) {
	float percent = (float(damage) / float(health)) * 100.0, difference = (getDamageAsPercent(damage, health)) - percent;
	return FloatAbs(difference) < 0.001 ? true : false;
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
		tankLastHealth[client] = 0;
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
			tankLastHealth[i] = 0;
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
