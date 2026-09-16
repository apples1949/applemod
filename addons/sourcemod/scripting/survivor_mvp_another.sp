#pragma semicolon 1
#pragma newdecls required

// 头文件
#include <sourcemod>
#include <sdktools>

// 团队类型
enum
{
	TEAM_SPECTATOR = 1,
	TEAM_SURVIVOR,
	TEAM_INFECTED
}

// 感染者类型
enum
{
	ZC_SMOKER = 1,
	ZC_BOOMER,
	ZC_HUNTER,
	ZC_SPITTER,
	ZC_JOCKEY,
	ZC_CHARGER,
	ZC_WITCH,
	ZC_TANK
}

// 判断是否有效玩家 id，有效返回 true，无效返回 false
stock bool IsValidClient(int client)
{
	return client > 0 && client <= MaxClients && IsClientInGame(client);
}

// 判断生还者是否有效，有效返回 true，无效返回 false
stock bool IsValidSurvivor(int client)
{
	return IsValidClient(client) && GetClientTeam(client) == view_as<int>(TEAM_SURVIVOR);
}

// 判断特感是否有效，有效返回 true，无效返回 false
stock bool IsValidInfected(int client)
{
	return IsValidClient(client) && GetClientTeam(client) == TEAM_INFECTED;
}

// 获取特感类型，成功返回特感类型，失败返回 -1
stock int GetInfectedClass(int client)
{
	return IsValidInfected(client) ? GetEntProp(client, Prop_Send, "m_zombieClass") : -1;
}

#define CVAR_FLAG FCVAR_NOTIFY

// 表格列
enum
{
	COL_SI = 0,		// 特感击杀
	COL_CI,			// 丧尸击杀
	COL_DAMAGE,		// 特感伤害 (伤害/百分比)
	COL_FF,			// 黑枪/被黑
	COL_ACC,		// 爆头率
	COL_MAX
}

// 每列最多两个数字子段 (伤害/百分比, 黑枪/被黑)
#define COL_FIELDS	2

// 对齐方式: 每个数字按"本列最大位数"补前导 0, 使同一列各行的字符构成完全一致 → 0 像素误差
// 依据: L4D2 聊天字体 ChatFont = Tahoma weight 700 (pak01_dir.vpk 内 resource/chatscheme.res),
//       实测 tahomabd.ttf: 数字等宽 (1304/2048 em), 空格只有 600 —— 1 个数字宽不是整数个空格宽,
//       所以"按字符个数补空格"会让位数少的行整格偏窄 (每少 1 位窄 704 单位 ≈ 7px) 并逐列累积;
//       补 0 后同行同列的字符个数与类别完全相同, 列宽数学上相等, 无需估算字体宽度.
#define CHAT_CELL_SIZE		48			// 单元格数值文本缓冲
#define CHAT_CELL_OUT		64			// 单元格输出缓冲 (标签 + 括号 + 数值)

// 已退出玩家记录上限 (本关内每人最多产生 1 条记录, 101 人上限的服务器也够用)
#define MAX_DEPARTED		32
// 统计表行数: 1..MaxClients = 在线玩家(行号即 client), MaxClients+1.. = 已退出玩家记录行
#define MAX_STAT_ROWS		(MAXPLAYERS + MAX_DEPARTED + 1)

enum struct PlayerInfo
{
	int totalDamage;
	int siCount;
	int ciCount;
	int ffCount;
	int gotFFCount;
	int headShotCount;
	void init() {
		this.totalDamage = this.siCount = this.ciCount = this.ffCount = this.gotFFCount = this.headShotCount = 0;
	}
	// 是否没有任何战绩 (退出玩家空战绩不值得留档)
	bool isEmpty() {
		return !this.totalDamage && !this.siCount && !this.ciCount && !this.ffCount && !this.gotFFCount && !this.headShotCount;
	}
} 
// 统一行索引: 1..MaxClients = 在线玩家, MaxClients+1.. = 已退出玩家记录 (同一套排序/统计逻辑)
PlayerInfo playerInfos[MAX_STAT_ROWS];

// 已退出玩家记录 (与 playerInfos 高位行 MaxClients+1+i 一一对应)
static char
	departedNames[MAX_DEPARTED][MAX_NAME_LENGTH],
	departedSteamIds[MAX_DEPARTED][32],
	clientSteamIds[MAXPLAYERS + 1][32];

static int
	departedCount,
	failCount;

static bool
	g_bHasPrint, 
	g_bHasPrintDetails;

static char
	mapName[64];

public Plugin myinfo = 
{
	name 			= "Survivor Mvp & Round Status",
	author 			= "夜羽真白 apples1949",
	description 	= "生还者 MVP 统计",
	version 		= "2026-09-14",
	url 			= "https://steamcommunity.com/id/saku_ra/"
}

ConVar
	g_hAllowShowMvp,
	g_hWhichTeamToShow,
	g_hAllowShowSi,
	g_hAllowShowCi,
	g_hAllowShowFF,
	g_hAllowShowTotalDmg,
	g_hAllowShowAccuracy,
	g_hAllowShowFailCount,
	g_hAllowShowDetails,
	g_hAllowShowRank;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
	EngineVersion test = GetEngineVersion();
	if( test != Engine_Left4Dead2 && test != Engine_Left4Dead) {
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 1 & 2.");
		return APLRes_SilentFailure;
	}

	// 注册插件库函数
	RegPluginLibrary("survivor_mvp");

	// 注册 Natives
	CreateNative("GetTotalDamageMvp", Native_GetTotalDamageMvp);
	CreateNative("GetSiMvp", Native_GetSiMvp);
	CreateNative("GetCiMvp", Native_GetCiMvp);
	CreateNative("GetFFMvp", Native_GetFFMvp);
	CreateNative("GetFFReceiveMvp", Native_GetFFReceiveMvp);
	CreateNative("GetMapFailCount", Native_GetMapFailCount);
	CreateNative("GetClientRank", Native_GetClientRank);

	return APLRes_Success;
}

public void OnPluginStart()
{
	g_hAllowShowMvp = CreateConVar("mvp_allow_show", "1", "是否启用插件", CVAR_FLAG, true, 0.0, true, 1.0);

	g_hWhichTeamToShow = CreateConVar("mvp_witch_team_show", "0", "允许给哪个团队显示 MVP 信息 (0: 所有团队, 1: 仅旁观者团队, 2: 仅生还者团队, 3: 仅特感团队)", CVAR_FLAG, true, 0.0, true, 3.0);
	g_hAllowShowSi = CreateConVar("mvp_allow_show_si", "1", "是否允许显示特感击杀信息", CVAR_FLAG, true, 0.0, true, 1.0);
	g_hAllowShowCi = CreateConVar("mvp_allow_show_ci", "1", "是否允许显示丧尸击杀信息", CVAR_FLAG, true, 0.0, true, 1.0);
	g_hAllowShowFF = CreateConVar("mvp_allow_show_ff", "1", "是否允许显示黑枪与被黑信息", CVAR_FLAG, true, 0.0, true, 1.0);
	g_hAllowShowTotalDmg = CreateConVar("mvp_allow_show_damage", "1", "是否允许显示总伤害信息", CVAR_FLAG, true, 0.0, true, 1.0);
	g_hAllowShowAccuracy = CreateConVar("mvp_allow_show_acc", "0", "是否允许显示准确度信息", CVAR_FLAG, true, 0.0, true, 1.0);

	g_hAllowShowFailCount = CreateConVar("mvp_show_fail_count", "0", "是否在团灭时显示团灭次数", CVAR_FLAG, true, 0.0, true, 1.0);
	g_hAllowShowDetails = CreateConVar("mvp_show_details", "1", "是否在过关或团灭时显示各项 MVP 数据 (每项 MVP 数据显示与否与 mvp_allow_show_xx Cvar 挂钩, 本 Cvar 关闭所有单项数据均不会显示)", CVAR_FLAG, true, 0.0, true, 1.0);
	g_hAllowShowRank = CreateConVar("mvp_show_your_rank", "1", "显示各项 MVP 数据时是否允许显示你的排名", CVAR_FLAG, true, 0.0, true, 1.0);

	// HookEvents
	HookEvent("player_death", siDeathHandler);
	HookEvent("infected_death", ciDeathHandler);
	HookEvent("player_hurt", playerHurtHandler);
	HookEvent("round_start", roundStartHandler);
	HookEvent("round_end", roundEndHandler);
	HookEvent("map_transition", roundEndHandler);
	HookEvent("mission_lost", missionLostHandler);
	HookEvent("finale_vehicle_leaving", roundEndHandler);
	// RegConsoleCmd
	RegConsoleCmd("sm_mvp", showMvpHandler);
}

public void OnMapStart()
{
	g_bHasPrint = g_bHasPrintDetails = false;
	char nowMapName[64];
	GetCurrentMap(nowMapName, sizeof(nowMapName));
	if (strlen(mapName) < 1 || strcmp(mapName, nowMapName) != 0) {
		failCount = 0;
		strcopy(mapName, sizeof(mapName), nowMapName);
	}
	clearStuff();
}

public Action showMvpHandler(int client, int args)
{
	if (!g_hAllowShowMvp.BoolValue)
	{
		ReplyToCommand(client, "[MVP]：当前生还者 MVP 统计数据已禁用");
		return Plugin_Handled;
	}
	if (!IsValidClient(client)) {
		return Plugin_Handled;
	}

	if (GetClientTeam(client) == TEAM_SPECTATOR && (g_hWhichTeamToShow.IntValue != 0 && g_hWhichTeamToShow.IntValue != 1)) {
		PrintToChat(client, "\x03[\x01MVP\x03]\x01: 当前生还者 MVP 统计数据不允许向旁观者显示");
		return Plugin_Handled;
	}
	else if (GetClientTeam(client) == TEAM_SURVIVOR && (g_hWhichTeamToShow.IntValue != 0 && g_hWhichTeamToShow.IntValue != 2)) {
		PrintToChat(client, "\x03[\x01MVP\x03]\x01: 当前生还者 MVP 统计数据不允许向生还者显示");
		return Plugin_Handled;
	}
	else if (GetClientTeam(client) == TEAM_INFECTED && (g_hWhichTeamToShow.IntValue != 0 && g_hWhichTeamToShow.IntValue != 3)) {
		PrintToChat(client, "\x03[\x01MVP\x03]\x01: 当前生还者 MVP 统计数据不允许向感染者显示");
		return Plugin_Handled;
	}
	printMvpStatus(client);
	if (g_hAllowShowDetails.BoolValue) {
		printParticularMvp(client);
	}

	return Plugin_Handled;
}

// 击杀特感
public void siDeathHandler(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid")), attacker = GetClientOfUserId(event.GetInt("attacker"));
	if (!IsValidClient(victim) || !IsValidClient(attacker) || GetClientTeam(victim) != TEAM_INFECTED || GetClientTeam(attacker) != TEAM_SURVIVOR) { return; }
	if (GetInfectedClass(victim) < ZC_SMOKER || GetInfectedClass(victim) > ZC_CHARGER) { return; }
	playerInfos[attacker].siCount++;
	if (event.GetBool("headshot")) { playerInfos[attacker].headShotCount++; }
}

// 击杀丧尸
public void ciDeathHandler(Event event, const char[] name, bool dontBroadcast)
{
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	if (!IsValidSurvivor(attacker)) { return; }
	playerInfos[attacker].ciCount++;
	if (event.GetBool("headshot")) { playerInfos[attacker].headShotCount++; }
}

// 造成伤害
public void playerHurtHandler(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid")), attacker = GetClientOfUserId(event.GetInt("attacker")), damage = event.GetInt("dmg_health");
	if (IsValidSurvivor(attacker) && IsValidSurvivor(victim))
	{
		playerInfos[attacker].ffCount += damage;
		playerInfos[victim].gotFFCount += damage;
	}
	else if (IsValidSurvivor(attacker) && IsValidInfected(victim) && GetInfectedClass(victim) >= ZC_SMOKER && GetInfectedClass(victim) <= ZC_CHARGER) { playerInfos[attacker].totalDamage += damage; }
}

public void OnClientConnected(int client) {
	playerInfos[client].init();
	clientSteamIds[client][0] = '\0';
}

// 先记下 SteamID, 断开连接时用它把战绩存档与"重进的同一个人"对上
public void OnClientAuthorized(int client, const char[] auth) {
	strcopy(clientSteamIds[client], sizeof(clientSteamIds[]), auth);
}

// 客户端完全进场(名字与 SteamID 都已确定)后, 再尝试接回退出记录
public void OnClientPostAdminCheck(int client) {
	if (!IsValidClient(client)) { return; }
	char name[MAX_NAME_LENGTH];
	GetClientName(client, name, sizeof(name));
	restoreDepartedRecord(client, clientSteamIds[client], name);
}

public void OnClientDisconnect(int client) {
	// 玩家退出: 战绩转存为"已退出记录", 本关不过关就一直保留, 过关/团灭输出时一并显示
	saveDepartedRecord(client);
	playerInfos[client].init();
}

public void roundStartHandler(Event event, const char[] name, bool dontBroadcast)
{
	g_bHasPrint = g_bHasPrintDetails = false;
	char nowMapName[64] = {'\0'};
	GetCurrentMap(nowMapName, sizeof(nowMapName));
	if (strlen(mapName) < 1 || strcmp(mapName, nowMapName) != 0) {
		failCount = 0;
		strcopy(mapName, sizeof(mapName), nowMapName);
	}
	clearStuff();
}

/**
* 团灭 MVP 显示
* @param 
* @return void
**/
public void missionLostHandler(Event event, const char[] name, bool dontBroadcast)
{
	if (g_hAllowShowFailCount.BoolValue) {
		PrintToChatAll("\x03[\x01MVP\x03]\x01: 这是你们第 \x04%d\x01 次团灭，请继续努力哦 (*･ω< )", ++failCount);
	}

	if (!g_hAllowShowMvp.BoolValue || g_bHasPrint) {
		return;
	}
	
	roundEndPrint();

	clearStuff();
}

public void roundEndHandler(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_hAllowShowMvp.BoolValue) {
		return;
	}
	// 过关时 round_end 与 map_transition 会先后触发, 只允许打印一次,
	// 否则第二次会因为 clearStuff() 已清空数据而打出一张全 0 的表 (也避免退出记录被提前清掉)
	if (g_bHasPrint) {
		return;
	}

	roundEndPrint();

	clearStuff();
}

// 方法
void clearStuff() {
	for (int i = 1; i <= MaxClients; i++) { playerInfos[i].init(); }
	clearDepartedRecords();
}

/**
* 清空已退出玩家记录 (过关 / 团灭 / 新关卡时调用)
* @param 
* @return void
**/
void clearDepartedRecords() {
	for (int i = 0; i < departedCount; i++) { playerInfos[MaxClients + 1 + i].init(); }
	departedCount = 0;
}

/**
* 玩家退出时把战绩转存为"已退出记录" (BOT 与空战绩不留档)
* 注: 断开回调里不依赖 IsClientInGame (此时客户端可能已在离场流程中), 只按索引 + 战绩判断
* @param client 退出的客户端索引
* @return void
**/
void saveDepartedRecord(int client) {
	if (client < 1 || client > MaxClients || IsFakeClient(client) || playerInfos[client].isEmpty()) { return; }
	if (departedCount >= MAX_DEPARTED) { return; }

	int row = MaxClients + 1 + departedCount;
	playerInfos[row] = playerInfos[client];
	GetClientName(client, departedNames[departedCount], MAX_NAME_LENGTH);
	departedSteamIds[departedCount][0] = '\0';
	if (clientSteamIds[client][0] != '\0') {
		strcopy(departedSteamIds[departedCount], 32, clientSteamIds[client]);
	} else {
		GetClientAuthId(client, AuthId_Steam2, departedSteamIds[departedCount], 32, true);
	}
	departedCount++;
}

/**
* 玩家重进时把退出记录接回本人 (SteamID + 名字都比对, 避免同 ID 服务器张冠李戴)
* 记录只在同一关内存在, 因此要求名字一致不会误伤改名玩家
* @param client 重进的客户端索引
* @param auth   客户端 SteamID
* @param name   客户端名字
* @return void
**/
void restoreDepartedRecord(int client, const char[] auth, const char[] name) {
	if (auth[0] == '\0' || StrEqual(auth, "BOT", false)) { return; }
	for (int i = 0; i < departedCount; i++) {
		if (!StrEqual(departedSteamIds[i], auth, false)) { continue; }
		if (!StrEqual(departedNames[i], name, false)) { continue; }

		int row = MaxClients + 1 + i;
		playerInfos[client].totalDamage += playerInfos[row].totalDamage;
		playerInfos[client].siCount += playerInfos[row].siCount;
		playerInfos[client].ciCount += playerInfos[row].ciCount;
		playerInfos[client].ffCount += playerInfos[row].ffCount;
		playerInfos[client].gotFFCount += playerInfos[row].gotFFCount;
		playerInfos[client].headShotCount += playerInfos[row].headShotCount;

		// 用最后一条记录填坑, 保证记录始终占据连续的高位行
		int last = departedCount - 1;
		if (i != last) {
			playerInfos[row] = playerInfos[MaxClients + 1 + last];
			strcopy(departedNames[i], MAX_NAME_LENGTH, departedNames[last]);
			strcopy(departedSteamIds[i], 32, departedSteamIds[last]);
		}
		playerInfos[MaxClients + 1 + last].init();
		departedNames[last][0] = '\0';
		departedSteamIds[last][0] = '\0';
		departedCount--;
		return;
	}
}

/**
* 判断某个统计行是否是"已退出玩家记录"
* @param row 统计行索引
* @return bool
**/
stock bool IsDepartedRow(int row) {
	return row > MaxClients && row <= MaxClients + departedCount;
}

/**
* 收集统计表行: 在线生还者 + 已退出玩家记录
* @param rows 目标数组 (长度至少 MAX_STAT_ROWS)
* @return 行数
**/
int collectStatRows(int[] rows) {
	int count = 0;
	for (int i = 1; i <= MaxClients; i++) {
		if (!IsValidClient(i) || GetClientTeam(i) != TEAM_SURVIVOR) { continue; }
		rows[count++] = i;
	}
	for (int i = 0; i < departedCount; i++) { rows[count++] = MaxClients + 1 + i; }
	return count;
}

/**
* 取统计表某一行的名字
* 在场玩家用 \x03(队伍色, 配合 PrintChatWithAuthor 的生还者作者 = 蓝色),
* 已退出玩家用 \x01(默认色 = 无颜色), BOT 追加 [BOT]
* @param row  统计行索引
* @param name 名字输出缓冲
* @param len  缓冲长度
* @return void
**/
void getStatRowName(int row, char[] name, int len) {
	if (IsDepartedRow(row)) {
		FormatEx(name, len, "\x01%s", departedNames[row - MaxClients - 1]);
	} else if (IsFakeClient(row)) {
		FormatEx(name, len, "\x03%N \x01[BOT]", row);
	} else {
		FormatEx(name, len, "\x03%N", row);
	}
}

/**
* 找一个在线的生还者作为 SayText2 作者
* L4D2 的聊天色 \x03 是"队伍色", 由消息作者(ent_idx)的队伍决定: 生还者 = 蓝色
* @return 客户端索引, 没有生还者时返回 0
**/
stock int FindSurvivorAuthor() {
	for (int i = 1; i <= MaxClients; i++) {
		if (IsValidClient(i) && GetClientTeam(i) == TEAM_SURVIVOR) { return i; }
	}
	return 0;
}

/**
* 以指定作者发送 SayText2 聊天消息 (消息里的 \x03 会按作者队伍着色)
* 这样"在场玩家名字"才能显示为蓝色; 作者无效时退化为普通 PrintToChat(此时 \x03 不着色)
* @param client  接收者
* @param author  SayText2 作者 (生还者 = 蓝色)
* @param message 消息内容
* @return void
**/
stock void PrintChatWithAuthor(int client, int author, const char[] message) {
	if (!IsValidClient(author)) {
		PrintToChat(client, "%s", message);
		return;
	}

	Handle msg = StartMessageOne("SayText2", client, USERMSG_RELIABLE | USERMSG_BLOCKHOOKS);
	if (msg == null) {
		PrintToChat(client, "%s", message);
		return;
	}

#if SOURCEMOD_V_MAJOR >= 1 && SOURCEMOD_V_MINOR >= 5
	if (GetFeatureStatus(FeatureType_Native, "GetUserMessageType") == FeatureStatus_Available && GetUserMessageType() == UM_Protobuf) {
		Protobuf pb = UserMessageToProtobuf(msg);
		pb.SetInt("ent_idx", author);
		pb.SetBool("chat", true);
		pb.SetString("msg_name", message);
		pb.AddString("params", "");
		pb.AddString("params", "");
		pb.AddString("params", "");
		pb.AddString("params", "");
	} else {
#endif
		BfWrite bf = UserMessageToBfWrite(msg);
		bf.WriteByte(author);
		bf.WriteByte(true);
		bf.WriteString(message);
#if SOURCEMOD_V_MAJOR >= 1 && SOURCEMOD_V_MINOR >= 5
	}
#endif

	EndMessage();
}

/**
* 计算某个统计行的伤害占团队总伤害的百分比
* @param row        统计行索引
* @param teamDamage 团队总伤害
* @return 百分比(整数)
**/
stock int GetDamagePercent(int row, int teamDamage) {
	return teamDamage <= 0 ? 0 : RoundToNearest(float(playerInfos[row].totalDamage) / float(teamDamage) * 100.0);
}

void roundEndPrint() {
	int i;
	for (i = 1; i <= MaxClients; i++) {
		if (!IsValidClient(i)) {
			continue;
		}

		switch (g_hWhichTeamToShow.IntValue) {
			case TEAM_SPECTATOR: {
				if (GetClientTeam(i) != TEAM_SPECTATOR) {
					continue;
				}
			} case TEAM_SURVIVOR: {
				if (GetClientTeam(i) != TEAM_SURVIVOR) {
					continue;
				}
			} case TEAM_INFECTED: {
				if (GetClientTeam(i) != TEAM_INFECTED) {
					continue;
				}
			} default: {

			}
		}

		if (g_bHasPrint) {
			break;
		}
		printMvpStatus(i);
		
		if (g_hAllowShowDetails.BoolValue) {
			if (g_bHasPrintDetails) {
				break;
			}
			printParticularMvp(i);
		}
	}

	g_bHasPrint = true;
	if (g_hAllowShowDetails.BoolValue) {
		g_bHasPrintDetails = true;
	}
}

/**
* 取非负整数的十进制位数 (用于本列补 0 的位宽)
* @param value 非负整数
* @return 位数 (至少 1)
**/
stock int CountDigits(int value) {
	int digits = 1;
	while (value >= 10) {
		value /= 10;
		digits++;
	}
	return digits;
}

/**
* 把非负整数按指定位宽补前导 0 写入缓冲 (位宽不够时按实际位数输出)
* @param buffer 输出缓冲
* @param maxlen 缓冲长度
* @param value  非负整数
* @param digits 目标位宽
* @return void
**/
stock void FormatZeroPadded(char[] buffer, int maxlen, int value, int digits) {
	char num[16];
	FormatEx(num, sizeof(num), "%d", value);

	int len = strlen(num), out = 0;
	for (int i = len; i < digits && out < maxlen - 1; i++) { buffer[out++] = '0'; }
	for (int i = 0; i < len && out < maxlen - 1; i++) { buffer[out++] = num[i]; }
	buffer[out] = '\0';
}

/**
* 显示主 MVP 信息 (特感击杀, 丧尸击杀, 特感伤害/伤害占比, 黑枪/被黑, 爆头率)
* 已退出且本关未回来的玩家记录会一并列出 (与在线玩家同样显示, 不加标记)
* 表格按"本列最大位数补前导 0"输出, 同列各行字符构成一致, 因此严格对齐(0 像素误差)
* @param client 需要显示的客户端索引
* @return void
**/
void printMvpStatus(int client)
{
	int[] rows = new int[MAX_STAT_ROWS];
	int count = collectStatRows(rows);

	PrintToChat(client, "\x03[生还者 MVP 统计]");

	if (count < 1) { return; }	// 没有生还者(也没有退出记录)不打印表格

	SortCustom1D(rows, count, sortByDamageFunction);

	// 团队总伤害, 用于伤害占比 (退出玩家的伤害同样计入)
	int teamDamage = 0;
	for (int i = 0; i < count; i++) { teamDamage += playerInfos[rows[i]].totalDamage; }

	// ① 取每列每个数字子段的最大位数, 作为本列补 0 位宽
	int[][] iDigits = new int[COL_MAX][COL_FIELDS];
	for (int i = 0; i < count; i++) {
		int row = rows[i], digits;

		digits = CountDigits(playerInfos[row].siCount);
		if (digits > iDigits[COL_SI][0]) { iDigits[COL_SI][0] = digits; }

		digits = CountDigits(playerInfos[row].ciCount);
		if (digits > iDigits[COL_CI][0]) { iDigits[COL_CI][0] = digits; }

		digits = CountDigits(playerInfos[row].totalDamage);
		if (digits > iDigits[COL_DAMAGE][0]) { iDigits[COL_DAMAGE][0] = digits; }
		digits = CountDigits(GetDamagePercent(row, teamDamage));
		if (digits > iDigits[COL_DAMAGE][1]) { iDigits[COL_DAMAGE][1] = digits; }

		digits = CountDigits(playerInfos[row].ffCount);
		if (digits > iDigits[COL_FF][0]) { iDigits[COL_FF][0] = digits; }
		digits = CountDigits(playerInfos[row].gotFFCount);
		if (digits > iDigits[COL_FF][1]) { iDigits[COL_FF][1] = digits; }

		if (g_hAllowShowAccuracy.BoolValue) {
			int hits = playerInfos[row].siCount + playerInfos[row].ciCount;
			float accuracy = hits == 0 ? 0.0 : float(playerInfos[row].headShotCount) / float(hits);
			digits = CountDigits(RoundToNearest(accuracy * 100.0));
			if (digits > iDigits[COL_ACC][0]) { iDigits[COL_ACC][0] = digits; }
		}
	}

	// ② 按位宽补 0 生成每行的列数据
	char[][][] sData = new char[count][COL_MAX][CHAT_CELL_SIZE];
	char part[2][16];
	for (int i = 0; i < count; i++) {
		int row = rows[i];
		if (g_hAllowShowSi.BoolValue) {
			FormatZeroPadded(sData[i][COL_SI], CHAT_CELL_SIZE, playerInfos[row].siCount, iDigits[COL_SI][0]);
		}
		if (g_hAllowShowCi.BoolValue) {
			FormatZeroPadded(sData[i][COL_CI], CHAT_CELL_SIZE, playerInfos[row].ciCount, iDigits[COL_CI][0]);
		}
		if (g_hAllowShowTotalDmg.BoolValue) {
			FormatZeroPadded(part[0], sizeof(part[]), playerInfos[row].totalDamage, iDigits[COL_DAMAGE][0]);
			FormatZeroPadded(part[1], sizeof(part[]), GetDamagePercent(row, teamDamage), iDigits[COL_DAMAGE][1]);
			FormatEx(sData[i][COL_DAMAGE], CHAT_CELL_SIZE, "%s/%s%%", part[0], part[1]);
		}
		if (g_hAllowShowFF.BoolValue) {
			FormatZeroPadded(part[0], sizeof(part[]), playerInfos[row].ffCount, iDigits[COL_FF][0]);
			FormatZeroPadded(part[1], sizeof(part[]), playerInfos[row].gotFFCount, iDigits[COL_FF][1]);
			FormatEx(sData[i][COL_FF], CHAT_CELL_SIZE, "%s/%s", part[0], part[1]);
		}
		if (g_hAllowShowAccuracy.BoolValue) {
			int hits = playerInfos[row].siCount + playerInfos[row].ciCount;
			float accuracy = hits == 0 ? 0.0 : float(playerInfos[row].headShotCount) / float(hits);
			FormatZeroPadded(sData[i][COL_ACC], CHAT_CELL_SIZE, RoundToNearest(accuracy * 100.0), iDigits[COL_ACC][0]);
			StrCat(sData[i][COL_ACC], CHAT_CELL_SIZE, "%");
		}
	}

	// ③ 逐行打印: 数值左右各留 1 个空格, 列间 1 个空格, 各行同列字符数完全一致 → 严格对齐
	// \x03 需要生还者作者才会渲染成蓝色, 所以用 PrintChatWithAuthor 发送
	char toPrint[1024], temp[CHAT_CELL_OUT], nameBuf[MAX_NAME_LENGTH + 24];
	int author = FindSurvivorAuthor();
	for (int i = 0; i < count; i++) {
		toPrint[0] = '\0';
		if (g_hAllowShowSi.BoolValue) {
			FormatEx(temp, sizeof(temp), "\x03特感[\x04 %s \x03] ", sData[i][COL_SI]);
			StrCat(toPrint, sizeof(toPrint), temp);
		}
		if (g_hAllowShowCi.BoolValue) {
			FormatEx(temp, sizeof(temp), "\x03丧尸[\x04 %s \x03] ", sData[i][COL_CI]);
			StrCat(toPrint, sizeof(toPrint), temp);
		}
		if (g_hAllowShowTotalDmg.BoolValue) {
			FormatEx(temp, sizeof(temp), "\x03伤害[\x04 %s \x03] ", sData[i][COL_DAMAGE]);
			StrCat(toPrint, sizeof(toPrint), temp);
		}
		if (g_hAllowShowFF.BoolValue) {
			FormatEx(temp, sizeof(temp), "\x03黑/被黑[\x04 %s \x03] ", sData[i][COL_FF]);
			StrCat(toPrint, sizeof(toPrint), temp);
		}
		if (g_hAllowShowAccuracy.BoolValue) {
			FormatEx(temp, sizeof(temp), "\x03爆头率[\x04 %s \x03] ", sData[i][COL_ACC]);
			StrCat(toPrint, sizeof(toPrint), temp);
		}

		getStatRowName(rows[i], nameBuf, sizeof(nameBuf));
		StrCat(toPrint, sizeof(toPrint), nameBuf);

		// 打印一个玩家的 MVP 信息 (在场玩家名字 \x03 = 蓝, 退出玩家 \x01 = 默认色)
		PrintChatWithAuthor(client, author, toPrint);
	}
}

/**
* 显示各项 MVP (SI, CI, FF, RANK)
* @param client 需要显示的客户端索引
* @return void
**/
void printParticularMvp(int client) {
	int siMvpRow, ciMvpRow, ffMvpRow, gotFFMvpRow;
	int dmgTotal, siTotal, ciTotal, ffTotal, gotFFTotal;

	// 在线生还者 + 已退出玩家记录一起参与统计与排名
	int[] rows = new int[MAX_STAT_ROWS];
	int count = collectStatRows(rows);

	for (int i = 0; i < count; i++) {
		int row = rows[i];
		dmgTotal += playerInfos[row].totalDamage;
		siTotal += playerInfos[row].siCount;
		ciTotal += playerInfos[row].ciCount;
		ffTotal += playerInfos[row].ffCount;
		gotFFTotal += playerInfos[row].gotFFCount;

		if (playerInfos[row].siCount > playerInfos[siMvpRow].siCount) {
			siMvpRow = row;
		}
		if (playerInfos[row].ciCount > playerInfos[ciMvpRow].ciCount) {
			ciMvpRow = row;
		}
		if (playerInfos[row].ffCount > playerInfos[ffMvpRow].ffCount) {
			ffMvpRow = row;
		}
		if (playerInfos[row].gotFFCount > playerInfos[gotFFMvpRow].gotFFCount) {
			gotFFMvpRow = row;
		}
	}

	int dmgPercent, killPercent;
	char clientName[MAX_NAME_LENGTH + 24], buffer[512], temp[320];
	// \x03 名字(在场玩家)需要生还者作者才会显示为蓝色
	int mvpAuthor = FindSurvivorAuthor();
	// 允许显示 SI MVP
	if (g_hAllowShowSi.BoolValue) {
		FormatEx(buffer, sizeof(buffer), "\x03[\x01MVP\x03]\x01 SI: ");
		if (siMvpRow < 1 || siTotal <= 0) {
			StrCat(buffer, sizeof(buffer), "\x04本局还没有击杀任何特感");
		} else {

			getStatRowName(siMvpRow, clientName, sizeof(clientName));

			dmgPercent = GetDamagePercent(siMvpRow, dmgTotal);
			killPercent = RoundToNearest(float(playerInfos[siMvpRow].siCount) / float(siTotal) * 100.0);
			FormatEx(temp, sizeof(temp), "%s \x03(\x01%d \x04伤害 \x03[\x01%d%%\x03]\x01, %d \x04击杀 \x03[\x01%d%%\x03])", clientName, playerInfos[siMvpRow].totalDamage, dmgPercent, playerInfos[siMvpRow].siCount, killPercent);
			StrCat(buffer, sizeof(buffer), temp);
		}
		PrintChatWithAuthor(client, mvpAuthor, buffer);
	}
	// 允许显示 CI MVP
	if (g_hAllowShowCi.BoolValue) {
		FormatEx(buffer, sizeof(buffer), "\x03[\x01MVP\x03]\x01 CI: ");
		if (ciMvpRow < 1 || ciTotal <= 0) {
			StrCat(buffer, sizeof(buffer), "\x04本局还没有击杀任何丧尸");
		} else {

			getStatRowName(ciMvpRow, clientName, sizeof(clientName));

			killPercent = RoundToNearest(float(playerInfos[ciMvpRow].ciCount) / float(ciTotal) * 100.0);
			FormatEx(temp, sizeof(temp), "%s \x03(\x01%d \x04丧尸 \x03[\x01%d%%\x03])", clientName, playerInfos[ciMvpRow].ciCount, killPercent);
			StrCat(buffer, sizeof(buffer), temp);
		}
		PrintChatWithAuthor(client, mvpAuthor, buffer);
	}
	// 允许显示 FF MVP
	if (g_hAllowShowFF.BoolValue) {
		FormatEx(buffer, sizeof(buffer), "\x03[\x01LVP\x03]\x01 FF: ");
		if (ffMvpRow < 1 || ffTotal <= 0) {
			StrCat(buffer, sizeof(buffer), "\x04大家都没有黑枪");
		} else {

			getStatRowName(ffMvpRow, clientName, sizeof(clientName));

			killPercent = RoundToNearest(float(playerInfos[ffMvpRow].ffCount) / float(ffTotal) * 100.0);
			FormatEx(temp, sizeof(temp), "%s \x03(\x01%d \x04友伤 \x03[\x01%d%%\x03])", clientName, playerInfos[ffMvpRow].ffCount, killPercent);
			StrCat(buffer, sizeof(buffer), temp);
		}
		PrintChatWithAuthor(client, mvpAuthor, buffer);

		// 被黑 MVP
		FormatEx(buffer, sizeof(buffer), "\x03[\x01MVP\x03]\x01 FF Receive: ");
		if (gotFFMvpRow < 1 || gotFFTotal <= 0) {
			StrCat(buffer, sizeof(buffer), "\x04暂时没有倒霉蛋被黑得最惨");
		} else {

			getStatRowName(gotFFMvpRow, clientName, sizeof(clientName));

			killPercent = RoundToNearest(float(playerInfos[gotFFMvpRow].gotFFCount) / float(gotFFTotal) * 100.0);
			FormatEx(temp, sizeof(temp), "%s \x03(\x01%d \x04被黑 \x03[\x01%d%%\x03])", clientName, playerInfos[gotFFMvpRow].gotFFCount, killPercent);
			StrCat(buffer, sizeof(buffer), temp);
		}
		PrintChatWithAuthor(client, mvpAuthor, buffer);
	}
	// 允许显示你的排名
	if (g_hAllowShowRank.BoolValue) {
		// 不是生还者, 不显示排名
		if (!IsValidClient(client) || GetClientTeam(client) != TEAM_SURVIVOR) {
			return;
		}
		// 你是 SI MVP, 则显示你的 CI 排名, 你是 SI, CI MVP 霸榜了, 除非你想显示你的 FF 排名, 则不显示你的排名
		if (client == siMvpRow && client == ciMvpRow) {
			return;
		}

		// 开始排名 (与表格一致: 在线生还者 + 已退出玩家记录)
		int rank;
		int[] rankRows = new int[MAX_STAT_ROWS];
		int rankCount = collectStatRows(rankRows);

		// 是杀特高手 或 不是杀特高手也不是清僵尸高手, 显示他的杀丧尸排名
		if (client == siMvpRow || client != ciMvpRow) {
			// 没有丧尸击杀, 不显示丧尸排名
			if (ciTotal <= 0) {
				return;
			}

			SortCustom1D(rankRows, rankCount, sortByCiCountFunction);

			for (int i = 0; i < rankCount; i++) {
				if (rankRows[i] == client) {
					rank = i + 1;
					break;
				}
			}

			killPercent = RoundToNearest(float(playerInfos[client].ciCount) / float(ciTotal) * 100.0);
			FormatEx(buffer, sizeof(buffer), "\x03你的排名 \x04CI: \x05#%d \x03(\x01%d \x04击杀 \x03[\x01%d%%\x03])", rank, playerInfos[client].ciCount, killPercent);
		} else {
			// 没有特感击杀, 不显示特感排名
			if (siTotal <= 0) {
				return;
			}

			SortCustom1D(rankRows, rankCount, sortBySiCountFunction);

			for (int i = 0; i < rankCount; i++) {
				if (rankRows[i] == client) {
					rank = i + 1;
					break;
				}
			}

			dmgPercent = GetDamagePercent(client, dmgTotal);
			killPercent = RoundToNearest(float(playerInfos[client].siCount) / float(siTotal) * 100.0);
			FormatEx(buffer, sizeof(buffer), "\x03你的排名 \x04SI: \x05#%d \x03(\x01%d \x04伤害 \x03[\x01%d%%\x03]\x01, %d \x04击杀 \x03[\x01%d%%\x03])", rank, playerInfos[client].totalDamage, dmgPercent, playerInfos[client].siCount, killPercent);
		}
		PrintChatWithAuthor(client, mvpAuthor, buffer);
	}
}

/**
* 按照生还者总伤害击杀特感数量 -> 客户端索引排序
* @param x 第一个参与排序的元素
* @param y 第二个参与排序的元素
* @param array 原数组
* @param hndl 可选句柄
* @return int
**/
stock int sortBySiCountFunction(int x, int y, const int[] array, Handle hndl) {
	return playerInfos[x].siCount > playerInfos[y].siCount ? -1 : playerInfos[x].siCount == playerInfos[y].siCount ? 0 : 1;
}

/**
* 按照生还者击杀丧尸数量 -> 客户端索引排序
* @param x 第一个参与排序的元素
* @param y 第二个参与排序的元素
* @param array 原数组
* @param hndl 可选句柄
* @return int
**/
stock int sortByCiCountFunction(int x, int y, const int[] array, Handle hndl) {
	return playerInfos[x].ciCount > playerInfos[y].ciCount ? -1 : playerInfos[x].ciCount == playerInfos[y].ciCount ? x > y ? -1 : 1 : 1;
}

/**
* 按照生还者总伤害 -> 客户端索引排序
* @param x 第一个参与排序的元素
* @param y 第二个参与排序的元素
* @param array 原数组
* @param hndl 可选句柄
* @return int
**/
stock int sortByTotalDamageFunction(int x, int y, const int[] array, Handle hndl) {
	return playerInfos[x].totalDamage > playerInfos[y].totalDamage ? -1 : playerInfos[x].totalDamage == playerInfos[y].totalDamage ? x > y ? -1 : 1 : 1;
}

/**
* 按照生还者总伤害 -> 爆头率 -> 客户端索引排序
* @param x 第一个参与排序的元素
* @param y 第二个参与排序的元素
* @param array 原数组
* @param hndl 可选句柄
* @return int
**/
stock int sortByDamageFunction(int x, int y, const int[] array, Handle hndl) {
	int xDamage = playerInfos[x].totalDamage, yDamage = playerInfos[y].totalDamage;

	int xCount = playerInfos[x].siCount + playerInfos[x].ciCount,
		yCount = playerInfos[y].siCount + playerInfos[y].ciCount;
	float xAcc = xCount == 0 ? 0.0 : float(playerInfos[x].headShotCount) / float(xCount),
		yAcc = yCount == 0 ? 0.0 : float(playerInfos[y].headShotCount) / float(yCount);
	// 先按总伤害排名，总伤害一样按爆头率排名, 爆头率一样按客户端索引排名
	return xDamage > yDamage ? -1 : xDamage == yDamage ? FloatCompare(xAcc, yAcc) > 0 ? -1 : FloatCompare(xAcc, yAcc) == 0 ? x > y ? -1 : 1 : 1 : 1;
}

/**
* 按照生还者黑枪 -> 被黑 -> 客户端索引排序
* @param x 第一个参与排序的元素
* @param y 第二个参与排序的元素
* @param array 原数组
* @param hndl 可选句柄
* @return int
**/
stock int sortByFriendlyFireFunction(int x, int y, const int[] array, Handle hndl) {
	int xFF = playerInfos[x].ffCount, yFF = playerInfos[y].ffCount;
	int xGotFF = playerInfos[x].gotFFCount, yGotFF = playerInfos[y].gotFFCount;
	// 先按黑枪排名, 友伤一样按被黑排名, 黑枪一样按客户端索引排名
	return xFF > yFF ? -1 : xFF == yFF ? xGotFF > yGotFF ? -1 : xGotFF == yGotFF ? x > y ? -1 : 1 : 1 : 1;
}

/**
* 按照生还者被黑 -> 客户端索引排序
* @param x 第一个参与排序的元素
* @param y 第二个参与排序的元素
* @param array 原数组
* @param hndl 可选句柄
* @return int
**/
stock int sortByFFReceiveFunction(int x, int y, const int[] array, Handle hndl) {
	return playerInfos[x].gotFFCount > playerInfos[y].gotFFCount ? -1 : playerInfos[x].gotFFCount == playerInfos[y].gotFFCount ? x > y ? -1 : 1 : 1;
}

// Natives
any Native_GetTotalDamageMvp(Handle plugin, int numParams) {
	int count;
	int[] players = new int[MaxClients + 1];
	getSurvivorArray(players, count);
	SortCustom1D(players, count, sortByTotalDamageFunction);
	return players[0];
}

any Native_GetSiMvp(Handle plugin, int numParams) {
	int count;
	int[] players = new int[MaxClients + 1];
	getSurvivorArray(players, count);
	SortCustom1D(players, count, sortBySiCountFunction);
	return players[0];
}

any Native_GetCiMvp(Handle plugin, int numParams) {
	int count;
	int[] players = new int[MaxClients + 1];
	getSurvivorArray(players, count);
	SortCustom1D(players, count, sortByCiCountFunction);
	return players[0];
}

any Native_GetFFMvp(Handle plugin, int numParams) {
	int count;
	int[] players = new int[MaxClients + 1];
	getSurvivorArray(players, count);
	SortCustom1D(players, count, sortByFriendlyFireFunction);
	return players[0];
}

any Native_GetFFReceiveMvp(Handle plugin, int numParams) {
	int count;
	int[] players = new int[MaxClients + 1];
	getSurvivorArray(players, count);
	SortCustom1D(players, count, sortByFFReceiveFunction);
	return players[0];
}

any Native_GetMapFailCount(Handle plugin, int numParams) {
	return failCount;
}

any Native_GetClientRank(Handle plugin, int numParams) {
	int client = GetNativeCell(1);
	int type = GetNativeCell(2);

	if (!IsValidClient(client) || GetClientTeam(client) != TEAM_SURVIVOR) {
		ThrowNativeError(SP_ERROR_NATIVE, "Client (%d) is invalid or not a survivor", client);
	}

	int i, count, rank;
	int[] players = new int[MaxClients + 1];
	getSurvivorArray(players, count);

	switch (type) {
		case 1:
			SortCustom1D(players, count, sortByDamageFunction);
		case 2:
			SortCustom1D(players, count, sortBySiCountFunction);
		case 3:
			SortCustom1D(players, count, sortByCiCountFunction);
		case 4:
			SortCustom1D(players, count, sortByFriendlyFireFunction);
		case 5:
			SortCustom1D(players, count, sortByFFReceiveFunction);
		default: {
			return ThrowNativeError(SP_ERROR_NATIVE, "Invalid type (%d), param type should between 1 and 5", type);
		}
	}
	
	for (i = 0; i < count; i++) {
		if (players[i] == client) {
			rank = i + 1;
			break;
		}
	}

	return rank;
}

void getSurvivorArray(int[] arr, int& size) {
	int index = 0, i;
	for (i = 1; i <= MaxClients; i++) {
		if (!IsValidClient(i) || GetClientTeam(i) != TEAM_SURVIVOR) {
			continue;
		}
		arr[index++] = i;
	}
	size = index;
} 