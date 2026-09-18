#pragma semicolon 1
#pragma newdecls required

// 头文件
#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#include <colors>
/* Apex 是"可选"前置, 必须显式 #undef REQUIRE_PLUGIN 再 include:
   core.inc 结尾默认 #define REQUIRE_PLUGIN, 不 undef 时 Apex.inc 里的 SharedPlugin 会编译成
   required = 1(必需依赖); 而本插件在 plugins.cfg 里比 Apex 先加载(第 48 行 vs 第 139 行),
   启动加载那会儿还找不到 "Apex" 库, 于是直接失败: Could not find required plugin "Apex"
   —— 表现就是"服务端启动不自动加载, 手动 sm plugins load 却能加载"(那时 Apex 已加载)。
   undef 之后依赖变为可选: Apex 没装/还没加载都不影响本插件加载, Apex 的 forward 照常能收到。
   注意: #undef 会影响其后 include 的文件, 所以这行必须紧跟在 <Apex> 之前。 */
#undef REQUIRE_PLUGIN
#include <Apex>

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
/* 聊天输出前缀(除玩家伤害记录行外, 报告的各行都带此前缀) */
#define CHAT_PREFIX "{green}[坦克伤害]{default} "
#define CHAT_PREFIX_RAW "\x04[坦克伤害]\x01 "
/* 排名数据单元格字符串大小(参考插件 l4d2_tank_ranking 的 MAX_SIZE, 同时满足 MAX_NAME_LENGTH 的玩家名) */
#define DATA_CELL_SIZE 32
/* 排名数据的列数: 0=名次, 1=伤害百分比, 2=伤害, 3=名字, 4=拳, 5=石, 6=铁, 7=承伤, 8=承伤百分比 */
#define DATA_COLUMNS 9
/* 中途退出玩家的记录存档上限(本局内每人最多一条, 正常对局远用不到) */
#define MAX_DEPARTED 32

/* 数字位对齐: 用 '0' 往左补到本列最大数字位数(零填充)
   实测(ChatFont = Tahoma Bold, 2048 units/em): 数字与 '0' 一律 1304 单位, 普通空格只有 600
   数字宽不是空格宽的整数倍(1 个数字 ≈ 2.17 个空格), 所以"按字符个数补普通空格"必然对不齐 ——
   少 1 位数字少 1304 单位, 补 1 个空格只找回 600 单位, 每列欠约 700 单位(约 7 像素), 列一多就整体歪掉。
   用与数字同宽的 '0' 补位后, 每行同列占用的渲染宽度完全相同(实测偏差 0.00 像素);
   且零填充本身就能一眼看出位数对齐(不再依赖不可见空格)。 */

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
	version 		= "3.5",
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

/* Apex 技能扣血: 技能扣血走 SetEntProp 直接改血量, 不产生伤害事件, 只能靠 Apex 的 forward 通报
   tankTracCostOpen  = 跟踪石(!trac)开启费累计, tankTracCostThrow = 跟踪石掷石净扣血(掷出预扣 - 命中退还),
   tankTracThrows    = 跟踪石净扣血发数
   tankBhopCostOpen  = 连跳(!bhop)开启费累计, tankBhopCostDetect = 未开启技能却连跳被抓的补扣累计
   tankSkillCost     = Apex 全部技能累计净扣血(跟踪石 + 连跳), 用于修正致死一击补偿(见 playerDeathHandler)
   以上数据同样跟随 Tank 实例, 换克时随其它数据一起转移 */
int
	tankTracCostOpen[MAXPLAYERS + 1],
	tankTracCostThrow[MAXPLAYERS + 1],
	tankTracThrows[MAXPLAYERS + 1],
	tankBhopCostOpen[MAXPLAYERS + 1],
	tankBhopCostDetect[MAXPLAYERS + 1],
	tankSkillCost[MAXPLAYERS + 1];

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

/* 中途退出玩家的记录(退出后照常列进报告):
   - 玩家退出时不清他的数据, 名字/SteamID 早已记了快照(退出后 GetClientName 拿不到名字)
   - 该索引被新玩家占用(索引复用)时, 旧记录转入存档行 departedHurt/departedHurts, 免得算到新玩家头上
   - 同一位玩家(SteamID 相同)本局内重进, 存档行会并回他名下, 报告里不会出现两行同名 */
int
	departedHurt[MAX_DEPARTED + 1][MAXPLAYERS + 1];		// [存档行][Tank] 该退出玩家对 Tank 造成的伤害
PlayerHurt departedHurts[MAX_DEPARTED + 1][MAXPLAYERS + 1];	// [存档行][Tank] 拳/石/铁/承伤明细
char
	departedNames[MAX_DEPARTED + 1][MAX_NAME_LENGTH],
	departedAuths[MAX_DEPARTED + 1][32],
	playerNames[MAXPLAYERS + 1][MAX_NAME_LENGTH],
	playerAuths[MAXPLAYERS + 1][32];
int
	departedCount;
bool
	// 该索引上有"已退出玩家"的记录(等新玩家占用该索引时转存档)
	playerRecordKept[MAXPLAYERS + 1];

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
	g_hLogLevel = CreateConVar("tank_damage_log_level", "1", "插件日志记录级别 (1: 禁用, 2: DEBUG, 4: INFO, 8: MESSAGE, 16: SERVER, 32: ERROR) 数字相加 (62: 全部)", CVAR_FLAG, true, 1.0);

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
			// 补名字/SteamID 快照: 中途退出后报告要靠它们照常显示/并回记录
			RecordPlayerName(i);
			RecordPlayerAuth(i);
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
	// 补一次名字/SteamID 快照(某些路径下 OnClientAuthorized 已过, 这里兜底)
	RecordPlayerName(client);
	RecordPlayerAuth(client);
}

/**
* 客户端连入(早于 OnClientAuthorized): 该索引上一位玩家的记录若还留着(中途退出), 先转存档,
* 否则新玩家的伤害会记到他的记录上; 转存档时用的仍是旧玩家的名字/SteamID 快照。
* 之后无论有没有记录, 都把索引上的快照清干净, 免得新玩家用了上一位的名字。
**/
public void OnClientConnected(int client) {
	ArchiveDepartedRecord(client, "索引被新玩家占用");
	playerNames[client][0] = '\0';
	playerAuths[client][0] = '\0';
	playerRecordKept[client] = false;
}

/**
* SteamID 就绪: 记快照; 若是本局中途退出的同一位玩家重进, 把他的存档记录并回名下。
**/
public void OnClientAuthorized(int client, const char[] auth) {
	strcopy(playerAuths[client], sizeof(playerAuths[]), auth);
	RestoreDepartedRecord(client, auth);
}

/**
* 玩家中途退出: 不清他的伤害数据(报告照常列出他, 名字用快照),
* 只做标记; 等该索引被新玩家占用时再转存档, 同一位玩家重进则并回名下。
**/
public void OnClientDisconnect(int client) {
	if (client < 1 || client > MaxClients)
		return;

	if (!hasPlayerRecord(client))
		return;

	playerRecordKept[client] = true;
	debugAndInfoLog("%s: 玩家 %s(%d) 中途退出, 保留他对 Tank 的伤害记录(报告照常显示)", PLUGIN_PREFIX, playerNames[client], client);
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
	// varpos=2: 参数栈中 ... 位于参数 2（参数从 1 开始计, 见 string.inc VFormat 文档）
	VFormat(buffer, sizeof(buffer), message, 2);
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
	RecordPlayerName(victim);
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

	/* 名字快照: 玩家中途退出后 GetClientName 拿不到名字, 报告要照常显示他 */
	RecordPlayerName(attacker);
	RecordPlayerName(victim);

	// Tank 对玩家造成伤害
	if (isTank(attacker) && IsValidSurvivor(victim)) {
		playerHurts[attacker][victim].gotDamage += damage;
		// 判断玩家是吃拳还是吃石
		if (strcmp(weapon, "tank_claw") == 0)
			playerHurts[attacker][victim].punch++;
		else if (strcmp(weapon, "tank_rock") == 0)
			playerHurts[attacker][victim].rock++;
	} else if (IsValidSurvivor(attacker) && isTank(victim)) {
		// 玩家对 Tank 造成伤害（致死一击的补偿在 player_death 中用"满血基准 - 已统计伤害 - 技能扣血"的差额计算, 不依赖易失的剩余血量记录）
		tankHurt[victim][attacker] += damage;
	}
}

/**
* Apex 技能扣血回调(Apex.inc 的 Apex_OnSkillCostCharged forward)。
* 坦克使用 Apex 技能(跟踪石 / 连跳)时, 血量由 Apex 用 SetEntProp 直接扣掉, 不产生伤害事件,
* 原生伤害统计看不到这部分血量消耗; 这里累计下来, 供报告显示, 并用于修正致死一击补偿。
* 跟踪石是"掷出预扣、命中生还者退还", 退还时 Apex 会以负数 cost 回调, 因此这里直接相加即得净扣血。
* 数据跟随 Tank 实例: 正常情况下回调者就是当前 Tank; 若跟踪指针已指向别的实例且本索引没有实例数据
* (历史遗留不同步), 则记到实例持有者(跟踪值)上, 避免换克后技能扣血记丢。
* @param client 被扣血的坦克客户端索引
* @param type   类型(连跳 / 跟踪石开启费 / 跟踪石掷出)
* @param cost   本次血量变化量: 扣血为正, 退还为负
**/
public void Apex_OnSkillCostCharged(int client, ApexSkillCostType type, int cost)
{
	if (!IsValidClient(client) || cost == 0)
		return;

	int holder = client;
	if (g_iCurrentTank != 0 && g_iCurrentTank != client && !tankDataExists(client) && tankDataExists(g_iCurrentTank))
		holder = g_iCurrentTank;

	tankSkillCost[holder] += cost;
	if (type == ApexSkillCost_TracEnable) {
		tankTracCostOpen[holder] += cost;
	} else if (type == ApexSkillCost_TracThrow) {
		tankTracCostThrow[holder] += cost;
		/* 净扣血发数 = 掷出数 - 命中退还数(退还的石头不扣血, 不该算进"扣血发数") */
		tankTracThrows[holder] += (cost > 0) ? 1 : -1;
	} else if (type == ApexSkillCost_Bhop) {
		tankBhopCostOpen[holder] += cost;
	} else if (type == ApexSkillCost_BhopDetect) {
		tankBhopCostDetect[holder] += cost;
	}
	/* 防御: 插件中途加载时可能只收到"退还"没收过"预扣", 不让累计值变成负数 */
	if (tankTracCostOpen[holder] < 0)
		tankTracCostOpen[holder] = 0;
	if (tankTracCostThrow[holder] < 0)
		tankTracCostThrow[holder] = 0;
	if (tankTracThrows[holder] < 0)
		tankTracThrows[holder] = 0;
	if (tankBhopCostOpen[holder] < 0)
		tankBhopCostOpen[holder] = 0;
	if (tankBhopCostDetect[holder] < 0)
		tankBhopCostDetect[holder] = 0;
	if (tankSkillCost[holder] < 0)
		tankSkillCost[holder] = 0;

	debugAndInfoLog("%s: Apex 技能扣血 %N(%d), 类型 %d, 本次 %d, 累计技能扣血 %d(跟踪石开启 %d + 掷石净扣 %d, %d 发 | 连跳开启 %d + 连跳被抓 %d)",
		PLUGIN_PREFIX, client, client, type, cost, tankSkillCost[holder], tankTracCostOpen[holder], tankTracCostThrow[holder], tankTracThrows[holder], tankBhopCostOpen[holder], tankBhopCostDetect[holder]);
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
	   补偿 = 满血基准 - 已统计的全部生还者伤害 - Apex 技能扣血。
	   差额法不依赖"最后剩余血量"这种易失状态, 控制权转移、事件时序颠倒都不会造成过度补偿,
	   且每人伤害永远不会超过满血基准。
	   技能扣血(跟踪石 / 连跳)同样消耗坦克血量却不产生伤害事件, 必须一并减掉,
	   否则这部分血量会被当成"致死一击"记到击杀者头上, 报告里总伤害也会凭空超出总血量 */
	if (IsValidSurvivor(attacker) && IsPlayerAlive(attacker)) {
		int recordedDamage = 0;
		for (int i = 1; i <= MaxClients; i++)
			recordedDamage += tankHurt[victim][i];
		int remainDamage = tankHealth[victim] - recordedDamage - tankSkillCost[victim];
		if (remainDamage > 0)
			tankHurt[victim][attacker] += remainDamage;
	}
	/* 计算 Tank 存活时间(只在首次结算时算): round_end 已经算过并排入报告时(坦克在延迟内死亡),
	   这里再减一次会把存活时长算成地图时间, 报告就会显示一个离谱的存活时间 */
	if (!hasPrintDamage[victim])
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
			/* 这个 Tank 的伤害报告已经输出或已排入队列(round_end 会重复触发, 死亡路径也可能已排入):
			   剩余血量属于这份报告, 必须随报告一起走 —— 这里直接跳过, 否则报告打完排名之后
			   又会冒出一行"剩余血量"; 顺带避免存活时间被二次相减算错 */
			if (hasPrintDamage[i])
				continue;

			// 计算 Tank 存活时长
			tankLiveTime[i] = GetGameTime() - tankLiveTime[i];
			if (tankLiveTime[i] < 0)
				continue;

			int health = GetEntProp(i, Prop_Data, "m_iHealth");
			if (health < 0 || tankHealth[i] < 1)
				continue;
			int percent = RoundToNearest(float(health) / float(tankHealth[i]) * 100.0);

			CPrintToChatAll("%s{green}%N {default}剩余 {green}%d{default}({green}%d%%{default}) {blue}血量", CHAT_PREFIX, i, health, percent);

			// 创建时钟延迟显示 Tank 伤害(回合结束, 坦克随回合消失)
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

	char sourceName[MAX_NAME_LENGTH], newName[MAX_NAME_LENGTH];
	FormatClientNameSafe(sourceTank, sourceName, sizeof(sourceName));
	FormatClientNameSafe(newTank, newName, sizeof(newName));
	debugAndInfoLog("%s: %s, 由 %s(%d) 转到 %s(%d)", PLUGIN_PREFIX, logTag, sourceName, sourceTank, newName, newTank);
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

/* 记玩家名快照: 中途退出后 GetClientName 拿不到名字, 报告要靠快照照常显示 */
void RecordPlayerName(int client)
{
	if (client < 1 || client > MaxClients || playerNames[client][0] != '\0')
		return;
	GetClientName(client, playerNames[client], MAX_NAME_LENGTH);
}

/* 记 SteamID 快照: 中途退出后重进时用它把记录并回同一个人名下 */
void RecordPlayerAuth(int client)
{
	if (client < 1 || client > MaxClients || playerAuths[client][0] != '\0')
		return;
	GetClientAuthId(client, AuthId_Steam2, playerAuths[client], sizeof(playerAuths[]), true);
}

/**
* 该索引上是否有玩家伤害记录(有任何一项非零即算; 中途退出判断与转存档都用它)
* @param client 客户端索引
* @return bool 有记录返回 true
**/
bool hasPlayerRecord(int client)
{
	for (int tank = 1; tank <= MaxClients; tank++) {
		if (tankHurt[tank][client] > 0
			|| playerHurts[tank][client].punch > 0
			|| playerHurts[tank][client].rock > 0
			|| playerHurts[tank][client].iron > 0
			|| playerHurts[tank][client].gotDamage > 0)
			return true;
	}
	return false;
}

/* 清掉某客户端索引上的全部伤害记录(转存档后调用, 免得记到新玩家头上) */
void ClearClientRecord(int client)
{
	playerNames[client][0] = '\0';
	playerAuths[client][0] = '\0';
	for (int tank = 1; tank <= MaxClients; tank++) {
		tankHurt[tank][client] = 0;
		playerHurts[tank][client].init();
	}
}

/**
* 把某索引上"已退出玩家"的记录转入存档行(该索引被新玩家占用时调用)
* @param client 原客户端索引(记录与名字快照仍在)
* @param reason 日志用的原因
* @return void
**/
void ArchiveDepartedRecord(int client, const char[] reason)
{
	if (client < 1 || client > MaxClients || !playerRecordKept[client])
		return;
	playerRecordKept[client] = false;

	if (!hasPlayerRecord(client)) {
		// 没有任何数据: 不必占存档位
		ClearClientRecord(client);
		return;
	}

	if (departedCount >= MAX_DEPARTED) {
		// 存档满(正常对局不会发生): 只能丢弃, 至少不让它算到新玩家头上
		debugAndInfoLog("%s: 中途退出玩家记录存档已满(%d), 丢弃 %s 的记录", PLUGIN_PREFIX, MAX_DEPARTED, playerNames[client]);
		ClearClientRecord(client);
		return;
	}

	int row = departedCount++;
	strcopy(departedNames[row], MAX_NAME_LENGTH, playerNames[client]);
	// 机器人没有 SteamID(AuthId 全是 "BOT"), 不留 auth 免得两个机器人互相匹配
	strcopy(departedAuths[row], sizeof(departedAuths[]), IsFakeClient(client) ? "" : playerAuths[client]);
	for (int tank = 1; tank <= MaxClients; tank++) {
		departedHurt[row][tank] = tankHurt[tank][client];
		departedHurts[row][tank] = playerHurts[tank][client];
	}

	debugAndInfoLog("%s: %s(%d) 记录转存档行 %d(%s)", PLUGIN_PREFIX, departedNames[row], client, row, reason);
	ClearClientRecord(client);
}

/**
* 同一位玩家(SteamID 相同)本局内重进: 把存档记录并回他名下, 报告里不会出现两行同名
* @param client 重进的客户端索引
* @param auth   该客户端的 SteamID
* @return void
**/
void RestoreDepartedRecord(int client, const char[] auth)
{
	if (client < 1 || client > MaxClients || auth[0] == '\0' || StrEqual(auth, "BOT", false))
		return;

	for (int d = 0; d < departedCount; d++) {
		if (!StrEqual(departedAuths[d], auth, false))
			continue;

		for (int tank = 1; tank <= MaxClients; tank++) {
			tankHurt[tank][client] += departedHurt[d][tank];
			playerHurts[tank][client].punch += departedHurts[d][tank].punch;
			playerHurts[tank][client].rock += departedHurts[d][tank].rock;
			playerHurts[tank][client].iron += departedHurts[d][tank].iron;
			playerHurts[tank][client].gotDamage += departedHurts[d][tank].gotDamage;
			departedHurt[d][tank] = 0;
			departedHurts[d][tank].init();
		}
		if (playerNames[client][0] == '\0')
			strcopy(playerNames[client], MAX_NAME_LENGTH, departedNames[d]);
		debugAndInfoLog("%s: 玩家 %s(%d) 重进, 中途退出的记录已并回名下", PLUGIN_PREFIX, departedNames[d], client);

		/* 用最后一条存档填坑, 保持存档行连续 */
		int last = departedCount - 1;
		if (d != last) {
			for (int tank = 1; tank <= MaxClients; tank++) {
				departedHurt[d][tank] = departedHurt[last][tank];
				departedHurts[d][tank] = departedHurts[last][tank];
				departedHurt[last][tank] = 0;
				departedHurts[last][tank].init();
			}
			strcopy(departedNames[d], MAX_NAME_LENGTH, departedNames[last]);
			strcopy(departedAuths[d], sizeof(departedAuths[]), departedAuths[last]);
		}
		departedNames[last][0] = '\0';
		departedAuths[last][0] = '\0';
		departedCount--;
		return;
	}
}

/**
* 取某统计行对 Tank 造成的伤害
* 行号 <= MaxClients = 在场玩家(行号即客户端索引); 行号 > MaxClients = 中途退出玩家的存档行
* @param row  统计行号
* @param tank Tank 客户端索引
* @return int 对 Tank 造成的伤害
**/
int GetRowHurt(int row, int tank)
{
	if (row > MaxClients)
		return departedHurt[row - MaxClients - 1][tank];
	return tankHurt[tank][row];
}

/**
* 取某统计行的显示名(中途退出玩家用名字快照, 索引已被新玩家占用则用存档行里的名字)
* @param row    统计行号
* @param buffer 输出缓冲区
* @param size   缓冲区大小
* @return void
**/
void GetRowName(int row, char[] buffer, int size)
{
	if (row > MaxClients) {
		strcopy(buffer, size, departedNames[row - MaxClients - 1]);
		return;
	}
	if (IsClientInGame(row)) {
		/* 机器人接手了中途退出玩家的索引时, 用退出玩家的名字快照, 记录才认得出来是谁打出来的
		   (纯 AI 队友的快照本来就是它自己的名字, 结果一样) */
		if (IsFakeClient(row) && playerNames[row][0] != '\0') {
			strcopy(buffer, size, playerNames[row]);
			return;
		}
		GetClientName(row, buffer, size);
		return;
	}
	// 中途退出、索引还没被占用: 用当时记下的名字快照
	if (playerNames[row][0] != '\0') {
		strcopy(buffer, size, playerNames[row]);
		return;
	}
	FormatEx(buffer, size, "离线(%d)", row);
}

/* 安全的客户端名格式化: 掉线/无效索引时输出 "离线(索引)" 而不是让 %N 抛异常 */
void FormatClientNameSafe(int client, char[] buffer, int size)
{
	if (IsValidClient(client))
		GetClientName(client, buffer, size);
	else
		FormatEx(buffer, size, "离线(%d)", client);
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

	char oldName[MAX_NAME_LENGTH], newName[MAX_NAME_LENGTH];
	FormatClientNameSafe(oldTank, oldName, sizeof(oldName));
	FormatClientNameSafe(newTank, newName, sizeof(newName));
	debugAndInfoLog("%s: Tank 控制权转换, 由 %s(%d) 转到 %s(%d), 转移伤害/承伤/血量/存活时间数据", PLUGIN_PREFIX, oldName, oldTank, newName, newTank);

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
	// Apex 技能扣血同样跟随 Tank 实例
	tankTracCostOpen[newTank] = tankTracCostOpen[oldTank];
	tankTracCostThrow[newTank] = tankTracCostThrow[oldTank];
	tankTracThrows[newTank] = tankTracThrows[oldTank];
	tankBhopCostOpen[newTank] = tankBhopCostOpen[oldTank];
	tankBhopCostDetect[newTank] = tankBhopCostDetect[oldTank];
	tankSkillCost[newTank] = tankSkillCost[oldTank];

	// 清空旧控制者的数据
	tankHealth[oldTank] = 0;
	tankLiveTime[oldTank] = 0.0;
	hasPrintDamage[oldTank] = false;
	tankTracCostOpen[oldTank] = 0;
	tankTracCostThrow[oldTank] = 0;
	tankTracThrows[oldTank] = 0;
	tankBhopCostOpen[oldTank] = 0;
	tankBhopCostDetect[oldTank] = 0;
	tankSkillCost[oldTank] = 0;
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

	/* 收集统计行: 在场生还者(行号 = 客户端索引) + 中途退出玩家的存档行(高位行号)。
	   中途退出的玩家只要对当前 Tank 有记录就照常列出(数据不清理, 名字用快照), 总伤害也把他算进去 */
	int i, index, totalDamage, totalGotDamage;
	int rowIds[MAXPLAYERS + MAX_DEPARTED + 1];
	for (i = 1; i <= MaxClients; i++) {
		if (IsClientInGame(i) && GetClientTeam(i) == TEAM_SURVIVOR) {
			rowIds[index++] = i;
			totalDamage += tankHurt[client][i];
			totalGotDamage += playerHurts[client][i].gotDamage;
		} else if (playerRecordKept[i]
			&& (tankHurt[client][i] > 0 || playerHurts[client][i].gotDamage > 0)) {
			// 中途退出、索引还没被占用的玩家: 记录留着, 照常列出来
			rowIds[index++] = i;
			totalDamage += tankHurt[client][i];
			totalGotDamage += playerHurts[client][i].gotDamage;
		}
	}
	for (int d = 0; d < departedCount; d++) {
		// 这个 Tank 跟他没关系(既没打 Tank 也没被 Tank 打)就不用列
		if (departedHurt[d][client] < 1 && departedHurts[d][client].gotDamage < 1)
			continue;
		rowIds[index++] = MaxClients + 1 + d;
		totalDamage += departedHurt[d][client];
		totalGotDamage += departedHurts[d][client].gotDamage;
	}
	// 一个统计行都没有(没生还者也没退出记录), 无需统计
	if (index < 1)
		return;

	// 收集每行的伤害数据: 0=统计行号, 1=对 Tank 的伤害
	int[][] survivorDamage = new int[index][2];
	for (i = 0; i < index; i++) {
		survivorDamage[i][0] = rowIds[i];
		survivorDamage[i][1] = GetRowHurt(rowIds[i], client);
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
	   列号见 DATA_COLUMNS 定义 */
	char[][][] sData = new char[displayCount][DATA_COLUMNS][DATA_CELL_SIZE];
	// 该行玩家现在是否还在服务器里(中途退出的记录行不在线 -> 名字用默认色)
	bool[] rowOnline = new bool[displayCount];
	// 百分比分母: 总伤害超过满血基准(含致死一击补偿)时用总伤害, 与参考插件一致
	int iTotalHealth = totalDamage > tankHealth[client] ? totalDamage : tankHealth[client];
	int x = 0;
	for (i = 0; i < index; i++) {
		int survivor = survivorDamage[i][0];
		int damage = survivorDamage[i][1];
		if (damage < 1 && !g_hAllowPrintZeroDamage.BoolValue)
			continue;

		// 明细: 在场玩家取索引上的数据, 中途退出玩家取存档行(两个数组的行列方向不同)
		PlayerHurt hurts;
		if (survivor > MaxClients)
			hurts = departedHurts[survivor - MaxClients - 1][client];
		else
			hurts = playerHurts[client][survivor];

		FormatEx(sData[x][0], DATA_CELL_SIZE, "%d", x + 1);
		FormatEx(sData[x][1], DATA_CELL_SIZE, "%.1f", float(damage) / float(iTotalHealth) * 100.0);
		FormatEx(sData[x][2], DATA_CELL_SIZE, "%d", damage);
		GetRowName(survivor, sData[x][3], DATA_CELL_SIZE);
		FormatEx(sData[x][4], DATA_CELL_SIZE, "%d", hurts.punch);
		FormatEx(sData[x][5], DATA_CELL_SIZE, "%d", hurts.rock);
		FormatEx(sData[x][6], DATA_CELL_SIZE, "%d", hurts.iron);
		FormatEx(sData[x][7], DATA_CELL_SIZE, "%d", hurts.gotDamage);
		FormatEx(sData[x][8], DATA_CELL_SIZE, "%d", totalGotDamage == 0 ? 0 : RoundToNearest(float(hurts.gotDamage) / float(totalGotDamage) * 100.0));
		// 在线/离线决定名字颜色: 在线蓝色, 中途退出的记录行不显示颜色
		rowOnline[x] = (survivor <= MaxClients) && IsClientInGame(survivor);

		debugAndInfoLog("%s: %s 对 Tank(%N) 的伤害报告: 总伤害 %d, 拳 %d, 石 %d, 铁 %d, 承伤 %d", PLUGIN_PREFIX, sData[x][3], client, damage, hurts.punch, hurts.rock, hurts.iron, hurts.gotDamage);
		x++;
	}

	/* 每一列按"数字位数"对齐: 取本列最多的数字位数, 谁少几位就在左边补几个 '0'。
	   '0' 与数字同宽, 每行在本列占用的宽度完全一致,
	   不会再出现"数字位数不同(如 1500 与 95)时后面的列跟着左右偏移" */
	int iDigits[DATA_COLUMNS];
	for (int y = 0; y < DATA_COLUMNS; y++) {
		iDigits[y] = 0;
		for (x = 0; x < displayCount; x++) {
			int digits = CountDigits(sData[x][y]);
			if (digits > iDigits[y])
				iDigits[y] = digits;
		}
	}

	// 坦克名字: AI 去掉名字里的 "Tank" 前缀, 人类玩家带队伍色, 与参考插件一致
	char sIndex[32];
	if (IsFakeClient(client)) {
		GetClientName(client, sIndex, sizeof(sIndex));
		SplitString(sIndex, "Tank", sIndex, sizeof(sIndex));
	} else {
		FormatEx(sIndex, sizeof(sIndex), "\x03%N", client);
	}

	// 标题行: [坦克伤害] 坦克{名}{原因},总血量:{血量}{+超额伤害}HP. 换行 [坦克伤害] 显示伤害排名:(总伤害:{总数})
	// (两行在同一条消息里, 换行后的第二行同样带前缀)
	char sInfo[128], sTemp[2][64];
	FormatEx(sTemp[0], sizeof(sTemp[]), "\x05总血量\x04:\x03%d", tankHealth[client]);
	if (totalDamage > tankHealth[client])
		FormatEx(sTemp[1], sizeof(sTemp[]), "\x04+\x03%d", totalDamage - tankHealth[client]);
	ImplodeStrings(sTemp, sizeof(sTemp), "", sInfo, sizeof(sInfo));
	PrintToChatAll("%s\x04坦克%s\x03%s\x04,%s\x05HP\x04.\n%s\x05显示伤害排名\x04:\x03(\x05总伤害\x04:\x05%d\x03)", CHAT_PREFIX_RAW, sIndex, reason, sInfo, CHAT_PREFIX_RAW, totalDamage);

	// 显示 Tank 存活时间
	if (g_hAllowPrintLiveTime.BoolValue) {
		if (!IsFakeClient(client))
			CPrintToChatAll("%s{green}%N {blue}存活时间：{green}%s", CHAT_PREFIX, client, getTime(tankLiveTime[client]));
		else
			CPrintToChatAll("%s{green}Tank {blue}存活时间：{green}%s", CHAT_PREFIX, getTime(tankLiveTime[client]));
	}

	/* Apex 跟踪石技能扣血(开启费 + 掷石净扣血): Apex 是"掷出预扣、命中生还者退还", 所以净扣血只算没打中的石头
	   技能扣血走 SetEntProp 不产生伤害事件, 单独列出便于核对总血量(没装 Apex、或这局没用过跟踪石时不显示) */
	int tracCostOpen = tankTracCostOpen[client], tracCostThrow = tankTracCostThrow[client];
	int tracCost = tracCostOpen + tracCostThrow;
	if (tracCost > 0) {
		char sDetail[96] = "";
		if (tracCostOpen > 0 && tracCostThrow > 0)
			FormatEx(sDetail, sizeof(sDetail), "{default}（{blue}开启费 {green}%d{default} + {blue}未命中掷石 {green}%d{default} 发共 {green}%d{default}）", tracCostOpen, tankTracThrows[client], tracCostThrow);
		else if (tracCostOpen > 0)
			FormatEx(sDetail, sizeof(sDetail), "{default}（{blue}开启费{default}）");
		else if (tankTracThrows[client] > 0)
			FormatEx(sDetail, sizeof(sDetail), "{default}（{blue}未命中掷石 {green}%d{default} 发{default}）", tankTracThrows[client]);
		CPrintToChatAll("%s{blue}跟踪石技能扣血：{green}%d%s", CHAT_PREFIX, tracCost, sDetail);
	}

	/* Apex 连跳技能扣血(开启费 + 未开启技能却连续连跳被抓的补扣), 口径与跟踪石那一行一致, 为 0 时不显示 */
	int bhopCostOpen = tankBhopCostOpen[client], bhopCostDetect = tankBhopCostDetect[client];
	int bhopCost = bhopCostOpen + bhopCostDetect;
	if (bhopCost > 0) {
		char sBhopDetail[96] = "";
		if (bhopCostOpen > 0 && bhopCostDetect > 0)
			FormatEx(sBhopDetail, sizeof(sBhopDetail), "{default}（{blue}开启费 {green}%d{default} + {blue}连跳被抓 {green}%d{default}）", bhopCostOpen, bhopCostDetect);
		else if (bhopCostOpen > 0)
			FormatEx(sBhopDetail, sizeof(sBhopDetail), "{default}（{blue}开启费{default}）");
		else
			FormatEx(sBhopDetail, sizeof(sBhopDetail), "{default}（{blue}连跳被抓{default}）");
		CPrintToChatAll("%s{blue}连跳技能扣血：{green}%d%s", CHAT_PREFIX, bhopCost, sBhopDetail);
	}

	/* 逐行输出: 名次:伤害百分比% (伤害) 拳:x 石:x 铁:x 承伤:x (承伤百分比%) 名字
	   数字位用 '0' 左补到本列最大位数(见 AppendZeroPaddedCell): 同列宽度完全一致, 各列上下对齐;
	   补位用的 '0' 不显示颜色(默认色), 真实数字是绿色, 一眼能分清补位与数据;
	   不再套中括号, 列间用单个普通空格分隔(每行空格数固定, 不影响对齐);
	   名字颜色: 在线玩家蓝色, 中途退出的记录行不显示颜色(默认色) */
	char row[512];
	for (x = 0; x < displayCount; x++) {
		row[0] = '\0';

		// 名次
		StrCat(row, sizeof(row), "\x04");
		AppendZeroPaddedCell(row, sizeof(row), sData[x][0], iDigits[0]);
		// :伤害百分比%
		StrCat(row, sizeof(row), "\x05:\x04");
		AppendZeroPaddedCell(row, sizeof(row), sData[x][1], iDigits[1]);
		StrCat(row, sizeof(row), "\x04%\x01 ");
		// (伤害)
		StrCat(row, sizeof(row), "\x03(\x04");
		AppendZeroPaddedCell(row, sizeof(row), sData[x][2], iDigits[2]);
		StrCat(row, sizeof(row), "\x03)\x01 ");
		// 拳
		StrCat(row, sizeof(row), "\x04拳\x03:\x04");
		AppendZeroPaddedCell(row, sizeof(row), sData[x][4], iDigits[4]);
		StrCat(row, sizeof(row), "\x01 ");
		// 石
		StrCat(row, sizeof(row), "\x04石\x03:\x04");
		AppendZeroPaddedCell(row, sizeof(row), sData[x][5], iDigits[5]);
		StrCat(row, sizeof(row), "\x01 ");
		// 铁
		StrCat(row, sizeof(row), "\x04铁\x03:\x04");
		AppendZeroPaddedCell(row, sizeof(row), sData[x][6], iDigits[6]);
		StrCat(row, sizeof(row), "\x01 ");
		// 承伤
		StrCat(row, sizeof(row), "\x04承伤\x03:\x04");
		AppendZeroPaddedCell(row, sizeof(row), sData[x][7], iDigits[7]);
		StrCat(row, sizeof(row), "\x01 ");
		// (承伤百分比%)
		StrCat(row, sizeof(row), "\x03(\x04");
		AppendZeroPaddedCell(row, sizeof(row), sData[x][8], iDigits[8]);
		StrCat(row, sizeof(row), "\x04%\x03)\x01 ");
		// 名字: 在线蓝色, 不在线(中途退出)不显示颜色
		StrCat(row, sizeof(row), rowOnline[x] ? "\x03" : "\x01");
		StrCat(row, sizeof(row), sData[x][3]);

		PrintToChatAll("%s", row);
	}
}

/**
* 统计文本里的数字个数(按"数字宽度"零填充用; '.' 等更窄的字符不参与补位)
* @param text 待统计文本
* @return 数字字符个数
**/
int CountDigits(const char[] text)
{
	int count = 0;
	for (int i = 0; text[i] != '\0'; i++)
		if (text[i] >= '0' && text[i] <= '9')
			count++;
	return count;
}

/**
* 追加一个数字位左补 '0' 的单元格
* 本列最大数字位数 - 本值数字位数 = 需要补的 '0' 个数; '0' 与任何数字同宽(实测 1304 单位),
* 所以每一行在本列占用的渲染宽度完全相同(偏差 0.00 像素), 且零填充看得见对齐效果。
* 补位用的 '0' 用**默认色**(不显示颜色)打印, 补完再把颜色换回数字色(调用方在单元格前给的是 \x04),
* 这样一眼能分清哪些 0 是补位、哪些是真实数据; 颜色码不占渲染宽度, 对齐不受影响。
* @param buffer 目标缓冲区
* @param size   缓冲区大小
* @param value  单元格文本(数字 / '.')
* @param digits 本列最大数字位数
* @return void
**/
void AppendZeroPaddedCell(char[] buffer, int size, const char[] value, int digits)
{
	int pad = digits - CountDigits(value);

	if (pad > 0)
	{
		StrCat(buffer, size, "\x01");   /* 补位字符: 不显示颜色 */
		for (int i = 0; i < pad; i++)
			StrCat(buffer, size, "0");
		StrCat(buffer, size, "\x04");   /* 换回数字的颜色 */
	}

	StrCat(buffer, size, value);
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
		tankTracCostOpen[client] = 0;
		tankTracCostThrow[client] = 0;
		tankTracThrows[client] = 0;
		tankBhopCostOpen[client] = 0;
		tankBhopCostDetect[client] = 0;
		tankSkillCost[client] = 0;
		for (i = 1; i <= MaxClients; i++)
		{
			tankHurt[client][i] = 0;
			playerHurts[client][i].init();
		}
		/* 中途退出玩家的存档里这个 Tank 那一列也要清掉, 免得算进新 Tank 的报告 */
		for (i = 0; i < departedCount; i++)
		{
			departedHurt[i][client] = 0;
			departedHurts[i][client].init();
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
			tankTracCostOpen[i] = 0;
			tankTracCostThrow[i] = 0;
			tankTracThrows[i] = 0;
			tankBhopCostOpen[i] = 0;
			tankBhopCostDetect[i] = 0;
			tankSkillCost[i] = 0;
			playerNames[i][0] = '\0';
			playerAuths[i][0] = '\0';
			playerRecordKept[i] = false;
			for (j = 1; j <= MaxClients; j++)
			{
				tankHurt[i][j] = 0;
				playerHurts[i][j].init();
			}
		}
		/* 中途退出玩家的存档只统计本回合, 一起清空 */
		for (i = 0; i <= departedCount && i <= MAX_DEPARTED; i++)
		{
			departedNames[i][0] = '\0';
			departedAuths[i][0] = '\0';
			for (j = 1; j <= MaxClients; j++)
			{
				departedHurt[i][j] = 0;
				departedHurts[i][j].init();
			}
		}
		departedCount = 0;
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
