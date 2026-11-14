/**
 * ============================================================================
 *  插件: l4d2_server_report
 *  功能: 读 configs/hostname/l4d2_hostname.txt 里形如 "IPv4:端口" 的配置段当服务器列表,
 *        用 A2S_INFO(UDP) 查询各服当前人数/人数上限,
 *          - 定时(默认 300 秒)查询一轮, 服务器里有人类玩家时在聊天里播报可加入的服;
 *          - 聊天打 !servers / 控制台 sm_servers 按需查询一轮, 只回给发起者.
 *
 *  输出格式(每台可加入的服务器一行):
 *      [server]抽象进阶包抗服1服[进阶包抗] 1.15.122.209:27015 1/12
 *      即: [server]<A2S里的服名> <IP:端口> <当前人数/人数上限>
 *      已满 / 查询不到(超时/休眠) / maxplayers=0 的服整行不输出.
 *
 *  为什么用 socket 扩展而不是 SteamWorks:
 *      SteamWorks 扩展只封装了 Steam 客户端/服务器 API(认证、VAC、服务器查询走
 *      ISteamMatchmaking 的服务器浏览器接口), 并不提供 A2S(UDP) 报文收发能力,
 *      所以这里用 socket 扩展自己构造/解析 A2S 报文.
 *
 *  socket 扩展用法要点(与扩展源码行为一致, 别凭直觉写):
 *      1. SocketCreate(SOCKET_UDP, ...) 只是建了个对象, 这时还没有真正的 UDP socket;
 *      2. 必须再调 SocketConnect() 才会 InitializeSocket() 并挂上接收回调(ReceiveHandler);
 *         **只调 SocketSendTo() 是收不到任何回复的**;
 *      3. UDP 的 connect 不握手, 只是记录默认对端, 所以可以直接 connect 一个自己不存在的服;
 *      4. 不需要 SocketBind: 扩展内部用 endpoint(0.0.0.0:0) 自动绑定临时端口;
 *      5. 接收回调不带来源地址, 所以每台服务器用一个独立 socket, 用 SocketSetArg() 带索引区分;
 *      6. 接收回调是按块投递的, 单包可能被拆成多次回调(split packet), 本插件只处理单包 INFO.
 *
 *  A2S_INFO 报文格式(多字节字段均为小端):
 *    请求: FF FF FF FF 54 "Source Engine Query" 00 [+ 4 字节 challenge]
 *    应答: FF FF FF FF 49 protocol(1) name(cstr) map(cstr) folder(cstr) game(cstr)
 *          appid(u16) players(u8) maxplayers(u8) bots(u8) [EDF...]
 *    挑战: FF FF FF FF 41 challenge(4)     <- 收到这个就把 4 字节 challenge 追在请求的 \0 后面重发
 *    下面的解析偏移量已用 python 假服务器/客户端对拍验证(见 私人文件\_tmp\).
 *
 *  本地验证: 编译零错误零警告; A2S 报文构造/解析/challenge 流程见 python 测试脚本.
 *  注意: L4D2 空服休眠(sv_hibernate_when_empty=1)时不答 A2S, 查询会超时, 属于正常现象;
 *        想让空服也出现在列表里, 需要在各服上设 sv_hibernate_when_empty 0.
 * ============================================================================
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <socket>

#define PLUGIN_VERSION      "1.1.0"

// L4D2 聊天颜色码: 仓库里其它插件只用到这 4 个, 均已验证显示正常, 不自行发明别的码.
//   \x01 = 默认(灰白)   \x03 = 队伍色(浅绿/浅蓝)   \x04 = 亮绿(最醒目)   \x05 = 白
// 注意: SourcePawn 不支持相邻字符串自动拼接("a" "b" 会报错), 所以这里整条格式串定义成宏.
#define FMT_TITLE   "\x04[多服消息]\x05 当前可加入的服务器: \x03%d\x05 台"
#define FMT_LINE    "\x01[server]\x05%s \x03%s \x04%s"
#define FMT_NONE    "\x04[server]\x01 暂时没有可加入的服务器(可能都在休眠或已满)."
#define FMT_INFO    "\x04[server]\x01 %s"
#define MAX_SERVERS         32
#define HOSTNAME_CONFIG     "configs/hostname/l4d2_hostname.txt"

// ---- A2S_INFO 相关常量 ----
#define A2S_INFO_QUERY      "\xFF\xFF\xFF\xFFTSource Engine Query\0"
#define A2S_INFO_QUERY_LEN  25      // 4(头) + 1('T') + 19("Source Engine Query") + 1(结尾 \0)
#define A2S_TYPE_CHALLENGE  0x41    // 'A'
#define A2S_TYPE_INFO       0x49    // 'I'

// 一轮播报的方式
enum
{
	BATCH_SCHEDULED = 0,    // 定时轮: 有人类玩家时播报给所有人
	BATCH_CLIENT,           // !servers: 只回给发起者
	BATCH_CONSOLE           // 控制台 sm_servers: 打到服务器控制台
};

// 单台服务器在本轮里的状态
enum
{
	SRV_FREE = 0,           // 本轮没用到
	SRV_WAIT,               // 已发查询, 等回复
	SRV_READY,              // 拿到可用数据, 要播报
	SRV_SKIP                // 跳过(超时/已满/无位/报文异常/socket 出错)
};

// 跳过原因(只用于日志统计)
enum
{
	SKIP_NONE = 0,
	SKIP_TIMEOUT,           // 超时 / 无回复(空服休眠时是常态)
	SKIP_FULL,              // 已满: players >= maxplayers
	SKIP_NO_SLOT,           // maxplayers == 0
	SKIP_PACKET,            // 报文异常(非 A2S、解析失败、重复 challenge)
	SKIP_SOCKET             // socket 出错/创建失败
};

// ---------------- 服务器列表(从配置文件读) ----------------
char g_sIP[MAX_SERVERS][32];
int  g_iPort[MAX_SERVERS];
int  g_iServerCount;

// ---------------- 单台服务器在一轮里的数据 ----------------
int   g_iState[MAX_SERVERS];
int   g_eSkipReason[MAX_SERVERS];
char  g_sName[MAX_SERVERS][128];    // A2S INFO 里的真实服名
int   g_iPlayers[MAX_SERVERS];
int   g_iMaxPlayers[MAX_SERVERS];
float g_fDeadline[MAX_SERVERS];     // 这一台最晚等到什么时候
bool  g_bChallengeSent[MAX_SERVERS];// 已经为这台发过带 challenge 的请求
Handle g_hSocket[MAX_SERVERS];

// ---------------- 当前这一轮 ----------------
bool   g_bBatchActive;
int    g_iBatchMode;
int    g_iRequesterUserId;
int    g_iPending;                  // 还没出结果的台数
int    g_iReplyCount;               // 本轮收到过多少个 A2S 报文(诊断用)
int    g_iConnectCount;             // 本轮 socket connect 回调次数(诊断用)
Handle g_hWatchdog;                 // 超时兜底定时器

// ---------------- ConVar / 定时器 ----------------
Handle g_hReportTimer;
ConVar g_cvEnable;
ConVar g_cvInterval;
ConVar g_cvTimeout;

// ---------------- 只报一次的诊断标记(不刷屏) ----------------
bool g_bSocketMissingLogged;
bool g_bSocketCreateLogged;
bool g_bConfigMissingLogged;
bool g_bConfigParseLogged;

char g_sConfigPath[PLATFORM_MAX_PATH];

public Plugin myinfo =
{
	name = "L4D2 Server Report",
	author = "apples1949",
	description = "按 l4d2_hostname 配置查询各服人数并播报, 支持 !servers",
	version = PLUGIN_VERSION,
	url = ""
};

// ============================================================================
//  生命周期
// ============================================================================

// 说明: 这份 include 集里 core.inc 定义了 REQUIRE_EXTENSIONS + AUTOLOAD_EXTENSIONS,
// 所以 socket.inc 里的 __ext_socket 是 required=1 + autoload=1:
// 服务器没装 socket 扩展时本插件会直接加载失败(控制台有明确提示), 不会悄悄不工作.
// 也就不能用 __ext_socket_SetNTVOptional() (REQUIRE_EXTENSIONS 下它不存在).

public void OnPluginStart()
{
	g_cvEnable = CreateConVar("l4d2_server_report_enable", "1",
		"开关: 1=启用定时查询并播报, 0=关闭定时播报(手动 sm_servers/!servers 仍可用).",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvInterval = CreateConVar("l4d2_server_report_interval", "300",
		"定时查询播报的间隔(秒), 最小 60.",
		FCVAR_NOTIFY, true, 60.0, true, 3600.0);
	g_cvTimeout = CreateConVar("l4d2_server_report_timeout", "2.0",
		"单台服务器等待 A2S 回复的上限(秒).",
		FCVAR_NOTIFY, true, 0.5, true, 10.0);

	g_cvEnable.AddChangeHook(OnConVarChanged);
	g_cvInterval.AddChangeHook(OnConVarChanged);

	RegConsoleCmd("sm_servers", Cmd_Servers, "查询服务器列表并显示各服人数(聊天输入 !servers)");

	for (int i = 0; i < MAX_SERVERS; i++)
		g_hSocket[i] = INVALID_HANDLE;

	BuildPath(Path_SM, g_sConfigPath, sizeof(g_sConfigPath), HOSTNAME_CONFIG);
}

public void OnMapStart()
{
	RestartReportTimer();
}

public void OnMapEnd()
{
	// 换图时正在跑的查询没意义了: 静默收尾, 别把上一局的数据播报到下一局.
	AbortBatch("换图");
	StopReportTimer();
}

public void OnPluginEnd()
{
	AbortBatch("插件卸载");
	StopReportTimer();
	CloseAllSockets();
}

public void OnConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	// 间隔/开关变了就重开定时器, 让新值立刻生效.
	RestartReportTimer();
}

// ============================================================================
//  定时播报
// ============================================================================

void RestartReportTimer()
{
	StopReportTimer();

	if (!g_cvEnable.BoolValue)
		return;

	g_hReportTimer = CreateTimer(GetInterval(), Timer_Round, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void StopReportTimer()
{
	if (g_hReportTimer != INVALID_HANDLE)
	{
		KillTimer(g_hReportTimer);
		g_hReportTimer = INVALID_HANDLE;
	}
}

public Action Timer_Round(Handle timer)
{
	if (!g_cvEnable.BoolValue)
		return Plugin_Continue;

	StartBatch(BATCH_SCHEDULED, 0);
	return Plugin_Continue;
}

// ============================================================================
//  指令
// ============================================================================

public Action Cmd_Servers(int client, int args)
{
	if (client == 0)
		StartBatch(BATCH_CONSOLE, 0);
	else
		StartBatch(BATCH_CLIENT, GetClientUserId(client));

	return Plugin_Handled;
}

// ============================================================================
//  一轮查询: 开始 / 收发 / 收尾
// ============================================================================

void StartBatch(int mode, int requesterUserId)
{
	// 同一时间只跑一轮: 已经有轮次在跑就忽略这次触发.
	if (g_bBatchActive)
		return;

	// socket 扩展是"扩展"不是"插件库", 所以 LibraryExists() 对它永远是 false(之前误用了它);
	// 正确做法是用 GetFeatureStatus 判断扩展提供的 native 是否可用.
	if (GetFeatureStatus(FeatureType_Native, "SocketCreate") != FeatureStatus_Available)
	{
		if (!g_bSocketMissingLogged)
		{
			LogError("[server_report] socket 扩展不可用(GetFeatureStatus(SocketCreate)!=Available), 无法查询服务器列表; 请确认 addons/sourcemod/extensions/socket.ext.* 存在并且 sm exts list 里已加载.");
			g_bSocketMissingLogged = true;
		}
		TellBatchMode(mode, requesterUserId, "socket 扩展不可用, 无法查询服务器.");
		return;
	}

	g_iServerCount = LoadServerList();
	if (g_iServerCount <= 0)
	{
		TellBatchMode(mode, requesterUserId, "配置里没有可查询的服务器(只认 IPv4:端口 的段).");
		return;
	}

	g_bBatchActive = true;
	g_iBatchMode = mode;
	g_iRequesterUserId = requesterUserId;
	g_iPending = 0;
	g_iReplyCount = 0;
	g_iConnectCount = 0;

	for (int i = 0; i < g_iServerCount; i++)
	{
		g_iState[i] = SRV_WAIT;
		g_eSkipReason[i] = SKIP_NONE;
		g_sName[i][0] = '\0';
		g_iPlayers[i] = 0;
		g_iMaxPlayers[i] = 0;
		g_bChallengeSent[i] = false;
		g_hSocket[i] = INVALID_HANDLE;

		if (!OpenServerSocket(i))
		{
			// socket 建不起来(扩展异常): OpenServerSocket 里已经 LogError 过一次, 这里静默跳过.
			g_iState[i] = SRV_SKIP;
			g_eSkipReason[i] = SKIP_SOCKET;
			continue;
		}

		g_iPending++;
		SendInfoQuery(i, false, 0);
	}

	if (g_iPending <= 0)
	{
		// 一台都没发出去(比如 socket 全部创建失败): 直接收尾, 只留日志.
		FinishBatch(false);
		return;
	}

	g_hWatchdog = CreateTimer(0.2, Timer_Watchdog, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

// 建一台服务器用的 UDP socket, 并把查询发出去.
bool OpenServerSocket(int idx)
{
	Socket sock = SocketCreate(SOCKET_UDP, OnSocketError);
	if (view_as<Handle>(sock) == INVALID_HANDLE)
	{
		if (!g_bSocketCreateLogged)
		{
			LogError("[server_report] SocketCreate(SOCKET_UDP) 失败, 无法查询服务器列表; 检查 socket 扩展是否加载成功.");
			g_bSocketCreateLogged = true;
		}
		return false;
	}

	g_hSocket[idx] = view_as<Handle>(sock);
	SocketSetArg(g_hSocket[idx], idx);

	// 关键: 必须 Connect 之后扩展才会挂接收回调; UDP 的 connect 不握手, 只是记录默认对端.
	SocketConnect(g_hSocket[idx], OnSocketConnect, OnSocketReceive, OnSocketDisconnect, g_sIP[idx], g_iPort[idx]);
	return true;
}

// 发 A2S_INFO 请求; bWithChallenge=true 时在结尾 \0 后面追加 4 字节 challenge 重发.
void SendInfoQuery(int idx, bool bWithChallenge, int iChallenge)
{
	char packet[64];
	strcopy(packet, sizeof(packet), A2S_INFO_QUERY);

	int len = A2S_INFO_QUERY_LEN;
	if (bWithChallenge)
	{
		packet[len++] = view_as<char>(iChallenge & 0xFF);
		packet[len++] = view_as<char>((iChallenge >> 8) & 0xFF);
		packet[len++] = view_as<char>((iChallenge >> 16) & 0xFF);
		packet[len++] = view_as<char>((iChallenge >> 24) & 0xFF);
	}

	SocketSendTo(g_hSocket[idx], packet, len, g_sIP[idx], g_iPort[idx]);
	g_fDeadline[idx] = GetGameTime() + GetQueryTimeout();
}

// 一台服务器出结果(READY 或 SKIP)后登记; 注意这里**不关 socket**, 统一等定时器收尾时关,
// 避免在扩展的回调里销毁正在回调的 socket 对象.
void EndServer(int idx, int iState, int eReason)
{
	if (g_iState[idx] != SRV_WAIT)
		return;     // 已经出过结果了, 防止重复计数

	g_iState[idx] = iState;
	g_eSkipReason[idx] = eReason;

	if (g_iPending > 0)
		g_iPending--;
}

// 超时兜底: 每 0.2 秒检查一次还没出结果的服务器, 超时就标记跳过; 全都有结果了就收尾.
public Action Timer_Watchdog(Handle timer)
{
	if (!g_bBatchActive)
	{
		g_hWatchdog = INVALID_HANDLE;
		return Plugin_Stop;
	}

	float fNow = GetGameTime();
	for (int i = 0; i < g_iServerCount; i++)
	{
		if (g_iState[i] != SRV_WAIT)
			continue;

		if (fNow >= g_fDeadline[i])
			EndServer(i, SRV_SKIP, SKIP_TIMEOUT);
	}

	if (g_iPending > 0)
		return Plugin_Continue;

	// 全部都有结果了: 在定时器里收尾(关 socket 不在 socket 回调里做).
	FinishBatch(true);
	return Plugin_Stop;
}

// 收尾: 关掉所有 socket, 停掉兜底定时器, 然后播报/记录这一轮.
void FinishBatch(bool fromWatchdog)
{
	if (!g_bBatchActive)
		return;

	g_bBatchActive = false;

	if (g_hWatchdog != INVALID_HANDLE)
	{
		if (!fromWatchdog)
			KillTimer(g_hWatchdog);

		g_hWatchdog = INVALID_HANDLE;
	}

	CloseAllSockets();

	if (g_iReplyCount == 0 && g_iConnectCount == 0 && g_iServerCount > 0)
	{
		// 真机排查线索: 一台都没收到过 connect 回调, 说明 socket 扩展的 UDP 链路没通.
		LogError("[server_report] 本轮没有收到任何 socket connect 回调, 也没收到 A2S 报文; 若所有服都超时, 请检查 socket 扩展的 UDP 支持(SocketCreate(SOCKET_UDP)+SocketConnect).");
	}

	ReportRound();
}

// 中途放弃(换图/卸载): 不播报, 只留一条日志.
void AbortBatch(const char[] sReason)
{
	if (!g_bBatchActive)
	{
		CloseAllSockets();
		return;
	}

	g_bBatchActive = false;

	if (g_hWatchdog != INVALID_HANDLE)
	{
		KillTimer(g_hWatchdog);
		g_hWatchdog = INVALID_HANDLE;
	}

	CloseAllSockets();
	LogMessage("[server_report] %s, 放弃本轮查询(已出结果 %d 台).", sReason, g_iServerCount - g_iPending);
}

void CloseAllSockets()
{
	for (int i = 0; i < MAX_SERVERS; i++)
	{
		if (g_hSocket[i] != INVALID_HANDLE)
		{
			CloseHandle(g_hSocket[i]);
			g_hSocket[i] = INVALID_HANDLE;
		}
	}
}

// ============================================================================
//  播报与日志
// ============================================================================

void ReportRound()
{
	int iReady = 0;
	int iTimeout = 0, iFull = 0, iNoSlot = 0, iPacket = 0, iSocket = 0;

	for (int i = 0; i < g_iServerCount; i++)
	{
		if (g_iState[i] == SRV_READY)
		{
			iReady++;
			continue;
		}

		if (g_iState[i] != SRV_SKIP)
			continue;

		// 用 if/else 而不是 switch: 计数器累加逻辑不依赖 Pawn 的 switch 语义, 读起来也更直白.
		if (g_eSkipReason[i] == SKIP_TIMEOUT)
			iTimeout++;
		else if (g_eSkipReason[i] == SKIP_FULL)
			iFull++;
		else if (g_eSkipReason[i] == SKIP_NO_SLOT)
			iNoSlot++;
		else if (g_eSkipReason[i] == SKIP_PACKET)
			iPacket++;
		else
			iSocket++;
	}
	// 每轮都在日志里留一份, 没有玩家时也能查(需求: 便于无人在线时验证).
	char sMode[16];
	GetBatchModeName(sMode, sizeof(sMode));

	LogMessage("[server_report] 本轮(%s) 查询 %d 台, 可加入 %d 台; 跳过: 超时%d 已满%d 无位%d 报文异常%d socket出错%d.",
		sMode, g_iServerCount, iReady, iTimeout, iFull, iNoSlot, iPacket, iSocket);

	for (int i = 0; i < g_iServerCount; i++)
	{
		if (g_iState[i] != SRV_READY)
			continue;

		char sLine[192];
		FormatServerLine(i, sLine, sizeof(sLine), false);//日志里必须纯文本, 不带颜色码.
		LogMessage("%s", sLine);
	}

	// 输出: 定时轮要有人类玩家才播, 指令轮只回给发起者.
	if (g_iBatchMode == BATCH_SCHEDULED)
	{
		// 一台可用都没有: 不播报, 上面的汇总日志已经记了(只写日志).
		if (iReady <= 0)
			return;

		if (!HasHumanPlayers())
		{
			LogMessage("[server_report] 服务器内没有人类玩家, 跳过聊天播报.");
			return;
		}

		PrintReadyServers(-1);
		return;
	}

	if (g_iBatchMode == BATCH_CLIENT)
	{
		int client = GetClientOfUserId(g_iRequesterUserId);
		if (client <= 0 || !IsClientInGame(client))
		{
			LogMessage("[server_report] 发起者已离开, 本轮结果不回给任何人.");
			return;
		}

		if (iReady <= 0)
		{
			PrintToChat(client, FMT_NONE);
			return;
		}

		PrintReadyServers(client);
		return;
	}

	// BATCH_CONSOLE
	if (iReady <= 0)
	{
		PrintToServer("[server] 暂时没有可加入的服务器(可能都在休眠或已满).");
		return;
	}

	PrintReadyServers(0);
}

// client > 0 只发给指定玩家, client == 0 打到服务器控制台.
void PrintReadyServers(int client)
{
	bool bChat = (client != 0);//只有聊天栏才上颜色; 控制台要纯文本.
	int iReady = 0;

	for (int i = 0; i < g_iServerCount; i++)
	{
		if (g_iState[i] == SRV_READY)
			iReady++;
	}

	char sLine[192];

	FormatTitleLine(iReady, sLine, sizeof(sLine), bChat);//标题行.
	PrintLine(client, sLine);

	for (int i = 0; i < g_iServerCount; i++)
	{
		if (g_iState[i] != SRV_READY)
			continue;

		FormatServerLine(i, sLine, sizeof(sLine), bChat);
		PrintLine(client, sLine);
	}
}

// 生成单行输出: [server]服名 IP:端口 人数/上限
// bColor=true 时给每一段上不同颜色(只用于聊天栏; 控制台/日志必须用纯文本).
void FormatServerLine(int idx, char[] sLine, int iMax, bool bColor)
{
	char sName[128];
	char sEndPoint[48];
	char sCount[16];

	strcopy(sName, sizeof(sName), g_sName[idx]);
	FormatEx(sEndPoint, sizeof(sEndPoint), "%s:%d", g_sIP[idx], g_iPort[idx]);
	FormatEx(sCount, sizeof(sCount), "%d/%d", g_iPlayers[idx], g_iMaxPlayers[idx]);

	// 颜色码本身也占字节(引擎按原始字节数截断), 所以算余量时把 5 个颜色码一起算进去.
	int iFixed = strlen("[server]") + strlen(sEndPoint) + strlen(sCount) + 3;

	if (bColor)
		iFixed += 4;//FMT_LINE 里的 4 个颜色码

	// 服名可能很长(比如带了中文配置后缀), 超长就按 UTF-8 边界截短, 保证 IP 和人数段完整.
	int iRoom = iMax - 1 - iFixed;

	if (iRoom < 0)
		iRoom = 0;

	TruncateUTF8(sName, iRoom);

	if (bColor)
		FormatEx(sLine, iMax, FMT_LINE, sName, sEndPoint, sCount);
	else
		FormatEx(sLine, iMax, "[server]%s %s %s", sName, sEndPoint, sCount);
}

// 标题行: [多服消息] 当前可加入的服务器: N 台
void FormatTitleLine(int iReady, char[] sLine, int iMax, bool bColor)
{
	if (bColor)
		FormatEx(sLine, iMax, FMT_TITLE, iReady);
	else
		FormatEx(sLine, iMax, "[多服消息] 当前可加入的服务器: %d 台", iReady);
}

// 按 UTF-8 字符边界截断(不会把一个汉字切成两半, 避免聊天栏乱码).
stock void TruncateUTF8(char[] sText, int iMaxBytes)
{
	int iLen = strlen(sText);

	if (iLen <= iMaxBytes)
		return;

	int iCut = (iMaxBytes < 0) ? 0 : iMaxBytes;

	// 0x80..0xBF 是 UTF-8 的后续字节; 切在它前面说明切断了字符, 往前退一个.
	while (iCut > 0 && (sText[iCut] & 0xC0) == 0x80)
		iCut--;

	sText[iCut] = '\0';
}

void PrintLine(int client, const char[] sLine)
{
	if (client > 0)
		PrintToChat(client, "%s", sLine);
	else if (client == 0)
		PrintToServer("%s", sLine);
	else
		PrintToChatAll("%s", sLine);
}

// 查询还没开始就失败时, 告诉发起者一声(定时轮则什么都不做).
void TellBatchMode(int mode, int requesterUserId, const char[] sMessage)
{
	if (mode == BATCH_CLIENT)
	{
		int client = GetClientOfUserId(requesterUserId);
		if (client > 0 && IsClientInGame(client))
			PrintToChat(client, FMT_INFO, sMessage);

		return;
	}

	if (mode == BATCH_CONSOLE)
	{
		PrintToServer("[server] %s", sMessage);
		return;
	}

	LogMessage("[server_report] %s", sMessage);
}

void GetBatchModeName(char[] sBuf, int iLen)
{
	if (g_iBatchMode == BATCH_CLIENT)
		strcopy(sBuf, iLen, "指令");
	else if (g_iBatchMode == BATCH_CONSOLE)
		strcopy(sBuf, iLen, "控制台");
	else
		strcopy(sBuf, iLen, "定时");
}

bool HasHumanPlayers()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
			return true;
	}

	return false;
}

// ============================================================================
//  配置读取
// ============================================================================

// 读 l4d2_hostname.txt 的根节点, 只取键形如 "IPv4:端口" 的段; default 和含 * 的通配键全部跳过.
int LoadServerList()
{
	g_iServerCount = 0;

	if (g_sConfigPath[0] == '\0')
		BuildPath(Path_SM, g_sConfigPath, sizeof(g_sConfigPath), HOSTNAME_CONFIG);

	if (!FileExists(g_sConfigPath))
	{
		if (!g_bConfigMissingLogged)
		{
			LogError("[server_report] 找不到配置文件 %s, 无法查询服务器列表.", g_sConfigPath);
			g_bConfigMissingLogged = true;
		}
		return 0;
	}

	KeyValues kv = new KeyValues("hostname");
	if (!kv.ImportFromFile(g_sConfigPath))
	{
		delete kv;

		if (!g_bConfigParseLogged)
		{
			LogError("[server_report] 配置文件 %s 解析失败, 无法查询服务器列表.", g_sConfigPath);
			g_bConfigParseLogged = true;
		}
		return 0;
	}

	int iCount = 0;
	char sKey[64];
	char sIP[32];
	int iPort;

	if (kv.GotoFirstSubKey())
	{
		do
		{
			if (!kv.GetSectionName(sKey, sizeof(sKey)))
				continue;

			if (!ParseServerKey(sKey, sIP, sizeof(sIP), iPort))
				continue;

			if (iCount >= MAX_SERVERS)
			{
				LogMessage("[server_report] 配置里的服务器超过 %d 台, 只查询前 %d 台.", MAX_SERVERS, MAX_SERVERS);
				break;
			}

			strcopy(g_sIP[iCount], sizeof(g_sIP[]), sIP);
			g_iPort[iCount] = iPort;
			iCount++;
		} while (kv.GotoNextKey());
	}

	delete kv;

	return iCount;
}

// 只接受形如 "1.2.3.4:27015" 的键: default / 含 * 的通配键 / 非法 IP / 非法端口都跳过.
bool ParseServerKey(const char[] sKey, char[] sIP, int iIPLen, int &iPort)
{
	if (sKey[0] == '\0')
		return false;

	if (StrEqual(sKey, "default", false))
		return false;

	if (StrContains(sKey, "*") != -1)
		return false;

	int iColon = FindCharInString(sKey, ':');
	if (iColon <= 0 || iColon >= iIPLen - 1)
		return false;

	// 端口部分不能再有冒号(IPv6 之类的一律不处理).
	if (FindCharInString(sKey[iColon + 1], ':') != -1)
		return false;

	strcopy(sIP, iIPLen, sKey);
	sIP[iColon] = '\0';

	if (!IsIPv4(sIP))
		return false;

	char sPort[8];
	strcopy(sPort, sizeof(sPort), sKey[iColon + 1]);
	if (sPort[0] == '\0')
		return false;

	for (int i = 0; sPort[i] != '\0'; i++)
	{
		if (sPort[i] < '0' || sPort[i] > '9')
			return false;
	}

	iPort = StringToInt(sPort);
	if (iPort <= 0 || iPort > 65535)
		return false;

	return true;
}

bool IsIPv4(const char[] sIP)
{
	int iLen = strlen(sIP);
	if (iLen < 7 || iLen > 15)
		return false;

	int iParts = 0;
	int iDigits = 0;
	int iValue = 0;

	for (int i = 0; i < iLen; i++)
	{
		char c = sIP[i];

		if (c == '.')
		{
			if (iDigits == 0)
				return false;

			iParts++;
			iDigits = 0;
			iValue = 0;
			continue;
		}

		if (c < '0' || c > '9')
			return false;

		iValue = iValue * 10 + (c - '0');
		iDigits++;

		if (iDigits > 3 || iValue > 255)
			return false;
	}

	return (iParts == 3 && iDigits > 0);
}

float GetInterval()
{
	float fInterval = g_cvInterval.FloatValue;
	if (fInterval < 60.0)
		fInterval = 60.0;

	return fInterval;
}

float GetQueryTimeout()
{
	float fTimeout = g_cvTimeout.FloatValue;
	if (fTimeout < 0.5)
		fTimeout = 0.5;

	return fTimeout;
}

// ============================================================================
//  A2S 报文解析
// ============================================================================

// 从 idx 位置读一个 C 字符串(以 \0 结尾), pos 前进到 \0 之后.
bool ReadA2SString(const char[] data, const int dataSize, int &pos, char[] out, const int outLen)
{
	int iStart = pos;

	while (pos < dataSize && data[pos] != '\0')
		pos++;

	if (pos >= dataSize)
		return false;   // 报文被截断, 没有结尾的 \0

	strcopy(out, outLen, data[iStart]);
	pos++;
	return true;
}

// 解析 A2S_INFO(0x49) 应答, 只取 name / players / maxplayers.
// 偏移: [0..3]头 [4]类型 [5]protocol [6]name\0 map\0 folder\0 game\0 appid(2) players(1) maxplayers(1) bots(1)
bool ParseA2SInfo(const char[] data, const int dataSize, int idx)
{
	if (dataSize < 6)
		return false;

	char sTmp[128];
	int pos = 6;    // 跳过 4 字节头 + 类型字节 + protocol

	if (!ReadA2SString(data, dataSize, pos, g_sName[idx], sizeof(g_sName[])))
		return false;

	if (!ReadA2SString(data, dataSize, pos, sTmp, sizeof(sTmp)))     // map
		return false;

	if (!ReadA2SString(data, dataSize, pos, sTmp, sizeof(sTmp)))     // folder
		return false;

	if (!ReadA2SString(data, dataSize, pos, sTmp, sizeof(sTmp)))     // game
		return false;

	if (pos + 2 > dataSize)     // appid
		return false;

	pos += 2;

	if (pos + 2 > dataSize)     // players + maxplayers
		return false;

	g_iPlayers[idx] = data[pos] & 0xFF;
	g_iMaxPlayers[idx] = data[pos + 1] & 0xFF;

	return true;
}

bool HasA2SHeader(const char[] data, const int dataSize)
{
	if (dataSize < 5)
		return false;

	return ((data[0] & 0xFF) == 0xFF && (data[1] & 0xFF) == 0xFF
		&& (data[2] & 0xFF) == 0xFF && (data[3] & 0xFF) == 0xFF);
}

// ============================================================================
//  socket 回调
// ============================================================================

public void OnSocketConnect(Socket socket, any arg)
{
	int idx = arg;
	if (!g_bBatchActive || idx < 0 || idx >= g_iServerCount)
		return;

	if (view_as<Handle>(socket) != g_hSocket[idx])
		return;     // 上一轮残留的 socket 回调, 忽略

	// UDP 的 connect 只是记录默认对端; 查询在 StartBatch 里已经发出去了, 这里只做诊断计数.
	g_iConnectCount++;
}

public void OnSocketReceive(Socket socket, const char[] receiveData, const int dataSize, any arg)
{
	int idx = arg;
	if (!g_bBatchActive || idx < 0 || idx >= g_iServerCount)
		return;

	if (g_iState[idx] != SRV_WAIT)
		return;     // 已经出过结果, 忽略重复/迟到的报文

	if (view_as<Handle>(socket) != g_hSocket[idx])
		return;     // 不是本轮这个 socket 的回调

	g_iReplyCount++;

	if (!HasA2SHeader(receiveData, dataSize))
	{
		LogMessage("[server_report] %s:%d 收到的不是 A2S 报文(长度 %d), 跳过这台.", g_sIP[idx], g_iPort[idx], dataSize);
		EndServer(idx, SRV_SKIP, SKIP_PACKET);
		return;
	}

	int iType = receiveData[4] & 0xFF;

	// ---- 挑战应答: 把 4 字节 challenge 追在请求的 \0 后面重发 ----
	if (iType == A2S_TYPE_CHALLENGE)
	{
		if (dataSize < 9)
		{
			LogMessage("[server_report] %s:%d 的 challenge 报文长度不对(%d), 跳过这台.", g_sIP[idx], g_iPort[idx], dataSize);
			EndServer(idx, SRV_SKIP, SKIP_PACKET);
			return;
		}

		if (g_bChallengeSent[idx])
		{
			// 带了 challenge 还继续被要求挑战, 不再纠缠.
			LogMessage("[server_report] %s:%d 重复要求 challenge, 跳过这台.", g_sIP[idx], g_iPort[idx]);
			EndServer(idx, SRV_SKIP, SKIP_PACKET);
			return;
		}

		int iChallenge = ((receiveData[5] & 0xFF))
						| ((receiveData[6] & 0xFF) << 8)
						| ((receiveData[7] & 0xFF) << 16)
						| ((receiveData[8] & 0xFF) << 24);

		g_bChallengeSent[idx] = true;
		SendInfoQuery(idx, true, iChallenge);
		return;
	}

	if (iType != A2S_TYPE_INFO)
	{
		LogMessage("[server_report] %s:%d 的应答类型未知(0x%02X), 跳过这台.", g_sIP[idx], g_iPort[idx], iType);
		EndServer(idx, SRV_SKIP, SKIP_PACKET);
		return;
	}

	if (!ParseA2SInfo(receiveData, dataSize, idx))
	{
		LogMessage("[server_report] %s:%d 的 A2S_INFO 报文解析失败(长度 %d), 跳过这台.", g_sIP[idx], g_iPort[idx], dataSize);
		EndServer(idx, SRV_SKIP, SKIP_PACKET);
		return;
	}

	// ---- 过滤: 没有人数上限 / 已满 ----
	if (g_iMaxPlayers[idx] <= 0)
	{
		EndServer(idx, SRV_SKIP, SKIP_NO_SLOT);
		return;
	}

	if (g_iPlayers[idx] >= g_iMaxPlayers[idx])
	{
		EndServer(idx, SRV_SKIP, SKIP_FULL);
		return;
	}

	EndServer(idx, SRV_READY, SKIP_NONE);
}

public void OnSocketDisconnect(Socket socket, any arg)
{
	int idx = arg;
	if (!g_bBatchActive || idx < 0 || idx >= g_iServerCount)
		return;

	if (g_iState[idx] != SRV_WAIT)
		return;

	if (view_as<Handle>(socket) != g_hSocket[idx])
		return;     // 上一轮残留的 socket 回调, 忽略

	// UDP 下常见于对端不可达(ICMP port unreachable), 当作这台没回复.
	LogMessage("[server_report] %s:%d socket 断开, 跳过这台.", g_sIP[idx], g_iPort[idx]);
	EndServer(idx, SRV_SKIP, SKIP_TIMEOUT);
}

public void OnSocketError(Socket socket, const int errorType, const int errorNum, any arg)
{
	int idx = arg;
	if (!g_bBatchActive || idx < 0 || idx >= g_iServerCount)
		return;

	if (g_iState[idx] != SRV_WAIT)
		return;

	if (view_as<Handle>(socket) != g_hSocket[idx])
		return;     // 上一轮残留的 socket 回调, 忽略

	LogMessage("[server_report] %s:%d socket 出错(类型 %d, 错误号 %d), 跳过这台.",
		g_sIP[idx], g_iPort[idx], errorType, errorNum);
	EndServer(idx, SRV_SKIP, SKIP_SOCKET);
}
