/**
 * l4d2_perf_capture
 * ------------------------------------------------------------------
 * 作用：生还者离开安全屋（回合真正开打）时，在服务器控制台执行一条
 *       可配置的服务端指令，默认 "perf_start 10 60"。
 *
 * 执行频率：**每张地图只执行一次**（换图后重新计数；同图团灭重开不重复执行）。
 *       对抗模式下一张图要打两个半场（两次都会重新加载同一张图），所以额外用引擎属性
 *       m_bInSecondHalfOfRound 判掉后半场 —— 对抗两回合只采 1 回合。
 *
 * 自动导出 + 解析：
 *       1. 采集窗口结束后（默认 70 秒，perf_start 10 60 在 60 秒自动停采样，留 10 秒余量）
 *          自动执行 perf_dump "<原始报告路径>"，把完整报告写到本插件自己的目录下；
 *       2. 再等几秒（等 perfstat 把文件写完），把原始报告**解析**成排名表写进：
 *              addons/sourcemod/logs/perf_capture/perf_<地图>_<时间>.log
 *       3. 解析成功后**删除原始报告**（perf_<地图>... 的 raw_ 文件），只留解析结果；
 *          解析失败时保留原始文件并在日志里报错，避免丢数据。
 *       目录可用 l4d2_perf_capture_log_folder 改。
 *
 * 背景：perf_start 来自引擎插件 perfstat（addons/perfstat.vdf 自动加载，
 *       见 https://github.com/xiaolinRM/perfstat）。
 *       "perf_start 10 60" = 10ms 采样一次、跑 60 秒后自动停止并出报告。
 *       perf_dump [路径] = 把完整报告写到指定路径（相对游戏根目录，目录要事先存在），
 *       不给路径时它自己写到 logs/perfstat-时间.log。
 *       该命令注册时 flags = 0（非 FCVAR_CHEAT、非 FCVAR_CLIENTDLL），
 *       所以服务端控制台可以直接执行，不需要 sv_cheats。
 *
 * 触发信号：游戏事件 player_left_start_area（玩家离开出生/安全区时引擎发出），
 *       这也是 applemod 内部其它插件（l4d2_antibaiter_safearea、
 *       applemod_prespawn_cleaner、l4d2_setscores_edi 等）判定"回合开打"用的信号。
 *       本插件不依赖 left4dhooks，也不调用任何第三方 native。
 *
 * 触发模式（l4d2_perf_capture_mode）：
 *       0 = 第一个生还者离开安全屋就执行（默认，等价于回合开打）
 *       1 = 所有真人玩家生还者都离开安全屋后才执行
 *           - bot 不统计：bot 跟随真人离开，且不保证触发 player_left_start_area；
 *           - 已死亡 / 已断线 / 换到其它队伍的生还者不再需要离开；
 *           - 因此这几种情况发生后会额外重判一次（0.1s 后），
 *             避免"最后一个人在安全屋里掉线，结果这张图都不执行"。
 *
 * 其它行为：
 *       - 指令为空时跳过，并且不占用"本图已执行"的配额。
 *       - 用 InsertServerCommand 而不是 ServerCommand：把命令排到本帧末尾执行，
 *         避免在游戏事件回调里直接重入控制台；用 "%s" 传字符串，避免 % 被当成格式符。
 *       - 管理员可用 sm_perf_capture 手动立刻执行一次（测试用，不影响自动触发状态），
 *         sm_perf_capture_status 查看当前配置与触发状态。
 *
 * 配置：全部走 ConVar 默认值 + AutoExecConfig（cfg/sourcemod/l4d2_perf_capture.cfg）
 * ------------------------------------------------------------------
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "1.3.0"
#define MAX_CMD_LEN 256
#define TEAM_SURVIVOR 2        // L4D2：1=旁观/未分配，2=生还者，3=感染者
#define TEAM_L4D1_SURVIVOR 4   // c7m3_port 这类两代生还者共存的地图会用 4（见 l2d2util_constants.inc）
#define DUMP_DELAY_SECONDS 70.0 // 自动执行 perf 指令后多久导出报告（perf_start 10 60 是 60 秒）
#define PARSE_DELAY_SECONDS 4.0 // 导出后再等多久去解析（等 perfstat 把文件写完）
#define LINE_MAX 512

ConVar gCvarEnabled;
ConVar gCvarCmd;
ConVar gCvarMode;
ConVar gCvarDumpCmd;
ConVar gCvarFolder;
ConVar gCvarTop;

bool g_bFired;                          // 本张地图是否已执行过（每张图只执行一次）
bool g_bAnyLeft;                        // 本回合是否已有过"离开安全屋"事件
bool g_bLeftArea[MAXPLAYERS + 1];       // 模式 1：该生还者本回合是否已离开安全屋

char g_sRaw[PLATFORM_MAX_PATH];         // 原始报告路径（解析后删除）
char g_sParsed[PLATFORM_MAX_PATH];      // 解析报告路径
char g_sMap[64];

/* 解析期间的临时表: "cpu|mem|模块名" */
ArrayList g_hModules;

public Plugin myinfo =
{
	name        = "L4D2 Perf Capture",
	author      = "apples1949",
	description = "生还者离开安全屋时执行服务端性能采集（默认 perf_start 10 60），每张图一次，报告解析后存进专用目录",
	version     = PLUGIN_VERSION,
	url         = "https://github.com/xiaolinRM/perfstat"
};

public void OnPluginStart()
{
	gCvarEnabled = CreateConVar("l4d2_perf_capture_enabled", "1",
			"1=生还者离开安全屋时自动执行采集并出报告，0=关闭（只保留手动 sm_perf_capture）",
			FCVAR_NONE, true, 0.0, true, 1.0);

	gCvarCmd = CreateConVar("l4d2_perf_capture_cmd", "perf_start 10 60",
			"离开安全屋时要执行的服务端指令（可用 ; 串联多条，如 sv_cheats 1; perf_start 10 60）");

	gCvarMode = CreateConVar("l4d2_perf_capture_mode", "0",
			"0=第一个生还者离开安全屋时执行；1=所有真人玩家生还者都离开后执行",
			FCVAR_NONE, true, 0.0, true, 1.0);

	gCvarDumpCmd = CreateConVar("l4d2_perf_capture_dump_cmd", "perf_dump \"%s\"",
			"导出报告用的服务端指令; %s 会被替换成本插件生成的原始报告路径(相对游戏根目录). 指令不支持路径参数时可改成 perf_dump（报告会落到 perfstat 默认位置，本插件就解析不到，只留提示）");

	gCvarFolder = CreateConVar("l4d2_perf_capture_log_folder", "addons/sourcemod/logs/perf_capture",
			"解析报告与原始报告的存放目录(相对游戏根目录). 原始报告解析成功后自动删除");

	gCvarTop = CreateConVar("l4d2_perf_capture_report_top", "25",
			"解析报告里最多列出多少个模块(按 CPU% 降序)",
			FCVAR_NONE, true, 5.0, true, 200.0);

	AutoExecConfig(true, "l4d2_perf_capture");

	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("player_left_start_area", Event_PlayerLeftStartArea, EventHookMode_Post);
	HookEvent("player_death", Event_PlayerDeath, EventHookMode_PostNoCopy);
	HookEvent("player_team", Event_PlayerTeam, EventHookMode_PostNoCopy);

	RegAdminCmd("sm_perf_capture", Cmd_PerfCapture, ADMFLAG_GENERIC,
			"立刻执行一次 perf 采集指令（测试用，不影响每张图一次的自动触发状态）");
	RegAdminCmd("sm_perf_capture_status", Cmd_PerfCaptureStatus, ADMFLAG_GENERIC,
			"查看 l4d2_perf_capture 的配置与当前触发状态");
}

public void OnMapStart()
{
	// 换图才重置"本图已执行"，同图团灭重开不重复执行。
	g_bFired = false;
	g_sRaw[0] = '\0';
	g_sParsed[0] = '\0';
	ResetRoundState();
}

public void OnClientDisconnect(int client)
{
	if (client > 0 && client <= MaxClients)
	{
		g_bLeftArea[client] = false;
	}

	// 模式 1 里"最后还没离开的那个人"掉线了，需要重判一次，否则这张图永远不执行。
	ScheduleAllLeftRecheck();
}

// ---------------------------------------------------------------- 事件

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	ResetRoundState();
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	ScheduleAllLeftRecheck();
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	ScheduleAllLeftRecheck();
}

public void Event_PlayerLeftStartArea(Event event, const char[] name, bool dontBroadcast)
{
	if (!gCvarEnabled.BoolValue || g_bFired)
	{
		return;
	}

	g_bAnyLeft = true;

	int client = GetClientOfUserId(event.GetInt("userid"));

	// 记下"这个人已经离开安全屋"，模式 1 需要用它判满。
	if (client > 0 && client <= MaxClients)
	{
		g_bLeftArea[client] = true;
	}

	// 模式 1：还有人（真人玩家生还者）没离开，先不执行。
	if (gCvarMode.IntValue == 1 && !AllHumanSurvivorsLeft())
	{
		return;
	}

	Trigger("生还者离开安全屋");
}

// ---------------------------------------------------------------- 逻辑

void ResetRoundState()
{
	g_bAnyLeft = false;

	for (int i = 1; i <= MaxClients; i++)
	{
		g_bLeftArea[i] = false;
	}
}

/**
 * 模式 1 用：所有"在游戏内 + 生还者 + 存活 + 真人"的玩家是否都已离开安全屋。
 * bot 不算（bot 跟随真人离开，且不保证触发 player_left_start_area）；
 * 已死亡 / 已断线 / 换队的生还者不再需要离开，自然不计入。
 * 全场没有真人玩家生还者时返回 true（调用处另有 g_bAnyLeft 兜底，
 * 保证"本回合根本没人离开过"时不会执行）。
 */
bool AllHumanSurvivorsLeft()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
		{
			continue;
		}

		int iTeam = GetClientTeam(i);

		if (iTeam != TEAM_SURVIVOR && iTeam != TEAM_L4D1_SURVIVOR)
		{
			continue;
		}

		if (!IsPlayerAlive(i))
		{
			continue;
		}

		if (!g_bLeftArea[i])
		{
			return false;
		}
	}

	return true;
}

/**
 * 模式 1 的补充重判：等待集合里的人（最后一个人）死亡 / 掉线 / 换队之后，
 * 不会再有新的 player_left_start_area 事件来触发判定，所以这里主动补一次。
 * 延迟 0.1s 让客户端状态（IsClientInGame / 队伍 / 存活）先落定。
 */
void ScheduleAllLeftRecheck()
{
	if (!gCvarEnabled.BoolValue || g_bFired || !g_bAnyLeft)
	{
		return;
	}

	if (gCvarMode.IntValue != 1)
	{
		return;
	}

	CreateTimer(0.1, Timer_RecheckAllLeft, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_RecheckAllLeft(Handle timer)
{
	if (!gCvarEnabled.BoolValue || g_bFired || !g_bAnyLeft)
	{
		return Plugin_Continue;
	}

	if (gCvarMode.IntValue != 1 || !AllHumanSurvivorsLeft())
	{
		return Plugin_Continue;
	}

	Trigger("全体生还者已离开安全屋（等待期间有玩家阵亡/掉线/换队）");
	return Plugin_Continue;
}

void Trigger(const char[] reason)
{
	if (g_bFired)
	{
		return;
	}

	// 先确认真的有指令可执行，避免空指令白白吃掉本图的唯一一次机会。
	if (!HasConfiguredCommand())
	{
		PrintToServer("[perf_capture] l4d2_perf_capture_cmd 为空，跳过执行（不占用本图配额）。");
		return;
	}

	// 对抗模式后半场（同一张图打第二遍）：不采，保证"两回合只执行 1 回合"。
	if (IsSecondHalfOfRound())
	{
		PrintToServer("[perf_capture] 本图为对抗后半场，跳过采集（每张图只采一次）。");
		LogMessage("[perf_capture] skip: second half of round");
		return;
	}

	if (!PreparePaths())
	{
		return;
	}

	g_bFired = true;

	DoCommand(reason);

	// 采集跑完后自动导出报告：70 秒后执行 perf_dump "<raw>"。
	// TIMER_FLAG_NO_MAPCHANGE：换图时自动作废，不会把上一张图的报告指令打到新图里。
	CreateTimer(DUMP_DELAY_SECONDS, Timer_DumpReport, _, TIMER_FLAG_NO_MAPCHANGE);
}

/* 生成这一轮的原始/解析路径，并确保目录存在 */
bool PreparePaths()
{
	char folder[PLATFORM_MAX_PATH];

	if (!GetLogFolder(folder, sizeof(folder)))
	{
		return false;
	}

	if (!EnsureFolder(folder))
	{
		LogError("[perf_capture] 建不了日志目录 \"%s\"，检查 l4d2_perf_capture_log_folder。", folder);
		return false;
	}

	char sTime[32];
	FormatTime(sTime, sizeof(sTime), "%Y%m%d_%H%M%S", GetTime());

	GetCurrentMap(g_sMap, sizeof(g_sMap));
	SanitizeName(g_sMap, sizeof(g_sMap));

	FormatEx(g_sRaw, sizeof(g_sRaw), "%s/raw_perf_%s_%s.log", folder, g_sMap, sTime);
	FormatEx(g_sParsed, sizeof(g_sParsed), "%s/perf_%s_%s.log", folder, g_sMap, sTime);

	return true;
}

bool HasConfiguredCommand()
{
	char sCmd[MAX_CMD_LEN];
	gCvarCmd.GetString(sCmd, sizeof(sCmd));

	return sCmd[0] != '\0';
}

void DoCommand(const char[] reason)
{
	char sCmd[MAX_CMD_LEN];
	gCvarCmd.GetString(sCmd, sizeof(sCmd));

	if (sCmd[0] == '\0')
	{
		PrintToServer("[perf_capture] l4d2_perf_capture_cmd 为空，跳过执行。");
		return;
	}

	// 排到本帧末尾再进控制台，避免在游戏事件回调里重入；
	// 用 "%s" 传字符串，防止指令里的 % 被当成格式符。
	InsertServerCommand("%s", sCmd);

	PrintToServer("[perf_capture] %s → 已提交服务端指令: %s", reason, sCmd);
	LogMessage("[perf_capture] %s, submitted server command: %s", reason, sCmd);
}

/**
 * 自动执行采集指令 70 秒后，把完整报告导出到本插件自己的目录（perf_dump "<路径>"）。
 * 固定 70 秒：默认指令 perf_start 10 60 在 60 秒时自动停采样，留 10 秒余量。
 */
public Action Timer_DumpReport(Handle timer)
{
	char sDump[MAX_CMD_LEN * 2];
	gCvarDumpCmd.GetString(sDump, sizeof(sDump));

	if (sDump[0] == '\0')
	{
		PrintToServer("[perf_capture] l4d2_perf_capture_dump_cmd 为空，跳过导出。");
		return Plugin_Continue;
	}

	char sCmd[MAX_CMD_LEN * 2];

	// 模板里带 %s 就替换成原始报告路径；不带的直接把指令原样执行
	if (StrContains(sDump, "%s") >= 0)
	{
		FormatEx(sCmd, sizeof(sCmd), sDump, g_sRaw);
	}
	else
	{
		strcopy(sCmd, sizeof(sCmd), sDump);
	}

	InsertServerCommand("%s", sCmd);

	PrintToServer("[perf_capture] 采集已满 %.0f 秒 → 已提交导出指令: %s",
			DUMP_DELAY_SECONDS, sCmd);
	LogMessage("[perf_capture] perf window finished, submitted dump command: %s", sCmd);

	// 再等几秒让 perfstat 把文件写完，然后解析 + 删原始
	CreateTimer(PARSE_DELAY_SECONDS, Timer_ParseReport, _, TIMER_FLAG_NO_MAPCHANGE);

	return Plugin_Continue;
}

/**
 * 解析原始 perfstat 报告 → 排名表，写进解析日志，成功后删除原始报告。
 * perfstat 的报告格式（见其 README 第 6 节）:
 *   头部: " 采样间隔 : 10 ms  采样次数: 905 ..." 之类 "键 : 值" 行
 *   表体: " 1 66.41  ntdll.dll  1.64  #1  map 1.0 / priv 0.0 / other 0.7"
 *   热点: "     20.79% of module   ServerGameDLL003+0x157D (rva 0x157D)"
 * 解析不出来时保留原始文件并报错。
 */
public Action Timer_ParseReport(Handle timer)
{
	if (g_sRaw[0] == '\0')
	{
		return Plugin_Continue;
	}

	if (!FileExists(g_sRaw))
	{
		PrintToServer("[perf_capture] 没找到原始报告 %s（perf_dump 没写出文件？检查 l4d2_perf_capture_dump_cmd）", g_sRaw);
		LogError("[perf_capture] raw report not found: \"%s\"", g_sRaw);
		return Plugin_Continue;
	}

	if (!ParseRawReport())
	{
		PrintToServer("[perf_capture] 解析失败，原始报告保留: %s", g_sRaw);
		LogError("[perf_capture] parse failed, raw kept: \"%s\"", g_sRaw);
		return Plugin_Continue;
	}

	if (DeleteFile(g_sRaw))
	{
		PrintToServer("[perf_capture] 解析完成 → %s（原始报告已删除）", g_sParsed);
		LogMessage("[perf_capture] parsed report written: \"%s\", raw removed", g_sParsed);
	}
	else
	{
		PrintToServer("[perf_capture] 解析完成 → %s（原始报告删除失败，请手动清理）", g_sParsed);
		LogError("[perf_capture] parsed ok but failed to remove raw: \"%s\"", g_sRaw);
	}

	return Plugin_Continue;
}

bool ParseRawReport()
{
	File hr = OpenFile(g_sRaw, "r");

	if (hr == null)
	{
		LogError("[perf_capture] 读不到原始报告 %s", g_sRaw);
		return false;
	}

	delete g_hModules;
	g_hModules = new ArrayList(ByteCountToCells(192));

	ArrayList aHeader = new ArrayList(ByteCountToCells(256));
	ArrayList aHot    = new ArrayList(ByteCountToCells(256));

	int  iLines = 0;
	char line[LINE_MAX];

	while (!hr.EndOfFile())
	{
		if (!hr.ReadLine(line, sizeof(line)))
			break;

		iLines++;

		char buf[LINE_MAX];
		strcopy(buf, sizeof(buf), line);
		TrimString(buf);

		if (buf[0] == '\0')
			continue;

		// 模块行: 名次 CPU% 模块名 MEM(MB) ...
		char modName[96];
		float cpu, mem;

		if (ParseModuleRow(buf, modName, sizeof(modName), cpu, mem))
		{
			char entry[192];
			FormatEx(entry, sizeof(entry), "%.4f|%.2f|%s", cpu, mem, modName);
			g_hModules.PushString(entry);
			continue;
		}

		// 热点行: "...% of module  符号+偏移"
		if (StrContains(buf, "of module", false) >= 0 && aHot.Length < 60)
		{
			aHot.PushString(buf);
			continue;
		}

		// 头部"键 : 值"行（采样间隔/次数/时长/模块数量...）
		if (aHeader.Length < 16 && StrContains(buf, " : ") >= 0)
		{
			aHeader.PushString(buf);
			continue;
		}
	}

	delete hr;

	if (g_hModules.Length == 0)
	{
		delete aHeader;
		delete aHot;
		return false;
	}

	g_hModules.SortCustom(SortByCpuDesc);

	int top = gCvarTop.IntValue;

	if (top < 1)
		top = 1;

	if (top > g_hModules.Length)
		top = g_hModules.Length;

	char sNow[32];
	FormatTime(sNow, sizeof(sNow), "%Y-%m-%d %H:%M:%S", GetTime());

	File hw = OpenFile(g_sParsed, "w");

	if (hw == null)
	{
		LogError("[perf_capture] 写不了解析报告 %s（检查 l4d2_perf_capture_log_folder）", g_sParsed);
		delete aHeader;
		delete aHot;
		return false;
	}

	hw.WriteLine("======================================================================");
	hw.WriteLine(" [perf_capture] perfstat 报告解析");
	hw.WriteLine("----------------------------------------------------------------------");
	hw.WriteLine(" 地图        : %s", g_sMap);
	hw.WriteLine(" 生成时间    : %s", sNow);
	hw.WriteLine(" 采集指令    : (见 l4d2_perf_capture_cmd)");
	hw.WriteLine(" 原始行数    : %d, 解析出 %d 个模块", iLines, g_hModules.Length);
	hw.WriteLine("----------------------------------------------------------------------");

	char hbuf[256];

	for (int i = 0; i < aHeader.Length; i++)
	{
		aHeader.GetString(i, hbuf, sizeof(hbuf));
		hw.WriteLine(" %s", hbuf);
	}

	hw.WriteLine("----------------------------------------------------------------------");
	hw.WriteLine("  #  CPU%     MEM(MB)  模块");
	hw.WriteLine("----------------------------------------------------------------------");

	char entry[192], shown[128];
	float cpu, mem;

	for (int i = 0; i < top; i++)
	{
		g_hModules.GetString(i, entry, sizeof(entry));

		// 存的是 "cpu|mem|模块名"
		char parts[3][128];
		ExplodeString(entry, "|", parts, 3, 128, true);

		cpu = StringToFloat(parts[0]);
		mem = StringToFloat(parts[1]);
		strcopy(shown, sizeof(shown), parts[2]);

		hw.WriteLine(" %3d %6.2f  %9.2f  %s", i + 1, cpu, mem, shown);
	}

	hw.WriteLine("----------------------------------------------------------------------");
	hw.WriteLine(" 共 %d 个模块，上面按 CPU%% 降序列出前 %d 个。", g_hModules.Length, top);

	if (aHot.Length > 0)
	{
		hw.WriteLine("----------------------------------------------------------------------");
		hw.WriteLine(" 模块内热点(原始报告里的 \"x%% of module\" 行):");

		for (int i = 0; i < aHot.Length; i++)
		{
			aHot.GetString(i, hbuf, sizeof(hbuf));
			hw.WriteLine("   %s", hbuf);
		}
	}

	hw.WriteLine("======================================================================");

	delete hw;
	delete aHeader;
	delete aHot;
	delete g_hModules;
	g_hModules = null;

	return true;
}

/**
 * 解析 perfstat 报告里的一行模块数据:
 *   " 1 26.73  ntdll.dll    1.64  #13   map 1.0 / priv 0.0 / other 0.7"
 * 要求: 前两列分别是整数名次与浮点 CPU%, 第三列是模块名, 第四列是浮点内存(MB)。
 * 成功返回 true。
 */
bool ParseModuleRow(const char[] buf, char[] modName, int nameLen, float &cpu, float &mem)
{
	char parts[6][96];
	int  n = SplitOnSpaces(buf, parts, 6, 96);

	if (n < 4)
		return false;

	// 第 0 列必须是纯整数（名次）
	for (int i = 0; parts[0][i] != '\0'; i++)
	{
		if (parts[0][i] < '0' || parts[0][i] > '9')
			return false;
	}

	if (!IsFloat(parts[1]) || !IsFloat(parts[3]))
		return false;

	cpu = StringToFloat(parts[1]);
	mem = StringToFloat(parts[3]);
	strcopy(modName, nameLen, parts[2]);

	return modName[0] != '\0';
}

/* 按"连续空白"切分(多个空格当成一个分隔符), 返回切出的段数; 每段都会被截断到 maxLen-1 */
int SplitOnSpaces(const char[] buf, char[][] parts, int maxParts, int maxLen)
{
	int n = 0;
	int i = 0;

	while (buf[i] != '\0' && n < maxParts)
	{
		while (buf[i] == ' ' || buf[i] == '\t')
		{
			i++;
		}

		if (buf[i] == '\0')
		{
			break;
		}

		int start = i;

		while (buf[i] != '\0' && buf[i] != ' ' && buf[i] != '\t')
		{
			i++;
		}

		int len = i - start;

		if (len >= maxLen)
		{
			len = maxLen - 1;
		}

		strcopy(parts[n], maxLen, buf[start]);
		parts[n][len] = '\0';
		n++;
	}

	return n;
}

/* 纯数字或带小数点的数字 */
bool IsFloat(const char[] s){
	bool hasDigit = false;
	bool hasDot   = false;

	for (int i = 0; s[i] != '\0'; i++)
	{
		if (s[i] >= '0' && s[i] <= '9')
		{
			hasDigit = true;
			continue;
		}

		if (s[i] == '.' && !hasDot)
		{
			hasDot = true;
			continue;
		}

		return false;
	}

	return hasDigit;
}

public int SortByCpuDesc(int index1, int index2, Handle array, Handle hndl)
{
	ArrayList list = view_as<ArrayList>(array);
	char a[192], b[192];

	list.GetString(index1, a, sizeof(a));
	list.GetString(index2, b, sizeof(b));

	float va = StringToFloat(a);
	float vb = StringToFloat(b);

	if (va < vb)
		return 1;

	if (va > vb)
		return -1;

	return 0;
}

// ---------------------------------------------------------------- 目录 / 工具

/* 读 l4d2_perf_capture_log_folder，去掉结尾斜杠；空则用默认值 */
bool GetLogFolder(char[] folder, int length)
{
	folder[0] = '\0';

	gCvarFolder.GetString(folder, length);
	TrimString(folder);

	int len = strlen(folder);

	while (len > 0 && (folder[len - 1] == '/' || folder[len - 1] == '\\'))
	{
		folder[--len] = '\0';
	}

	if (folder[0] == '\0')
	{
		strcopy(folder, length, "addons/sourcemod/logs/perf_capture");
	}

	return true;
}

/* 逐级建目录（CreateDirectory 只建一层） */
bool EnsureFolder(const char[] folder)
{
	if (DirExists(folder))
	{
		return true;
	}

	char part[PLATFORM_MAX_PATH];
	part[0] = '\0';

	for (int i = 0; folder[i] != '\0'; i++)
	{
		if (folder[i] == '/' || folder[i] == '\\')
		{
			if (part[0] != '\0' && !DirExists(part))
			{
				CreateDirectory(part, 0777);
			}
		}

		int len = strlen(part);

		if (len + 1 < sizeof(part))
		{
			part[len]     = folder[i];
			part[len + 1] = '\0';
		}
	}

	if (part[0] != '\0' && !DirExists(part))
	{
		CreateDirectory(part, 0777);
	}

	return DirExists(folder);
}

void SanitizeName(char[] s, int len)
{
	for (int i = 0; i < len && s[i] != '\0'; i++)
	{
		if (s[i] == '/' || s[i] == '\\' || s[i] == ':' || s[i] == ' ' || s[i] == '*'
			|| s[i] == '?' || s[i] == '"' || s[i] == '<' || s[i] == '>' || s[i] == '|')
		{
			s[i] = '_';
		}
	}
}

/* 对抗模式下"本回合是否是后半场"（非对抗模式恒为 false） */
bool IsSecondHalfOfRound()
{
	int rules = FindEntityByClassname(-1, "terror_gamerules");

	if (rules == -1)
	{
		return false;
	}

	return view_as<bool>(GetEntProp(rules, Prop_Send, "m_bInSecondHalfOfRound"));
}

// ---------------------------------------------------------------- 管理指令

public Action Cmd_PerfCapture(int client, int args)
{
	char sCmd[MAX_CMD_LEN];
	gCvarCmd.GetString(sCmd, sizeof(sCmd));

	if (sCmd[0] == '\0')
	{
		ReplyToCommand(client, "[SM] l4d2_perf_capture_cmd 为空，没有可执行的指令。");
		return Plugin_Handled;
	}

	// 手动触发也走完整的导出+解析流程（但不动"本图已触发"标记）
	if (g_sRaw[0] == '\0' && !PreparePaths())
	{
		ReplyToCommand(client, "[SM] 日志目录不可用，检查 l4d2_perf_capture_log_folder。");
		return Plugin_Handled;
	}

	InsertServerCommand("%s", sCmd);
	CreateTimer(DUMP_DELAY_SECONDS, Timer_DumpReport, _, TIMER_FLAG_NO_MAPCHANGE);

	PrintToServer("[perf_capture] 管理员手动触发 → 已提交服务端指令: %s", sCmd);
	LogMessage("[perf_capture] manual trigger, submitted server command: %s", sCmd);
	ReplyToCommand(client, "[SM] 已提交到服务端控制台: %s（%.0f 秒后自动导出并解析）", sCmd, DUMP_DELAY_SECONDS);

	return Plugin_Handled;
}

public Action Cmd_PerfCaptureStatus(int client, int args)
{
	char sCmd[MAX_CMD_LEN];
	gCvarCmd.GetString(sCmd, sizeof(sCmd));

	ReplyToCommand(client, "[SM] enabled=%d mode=%d top=%d", gCvarEnabled.IntValue, gCvarMode.IntValue, gCvarTop.IntValue);
	ReplyToCommand(client, "[SM] cmd=\"%s\"", sCmd);
	ReplyToCommand(client, "[SM] 本图已触发=%s 本回合已有人离开=%s 后半场=%s",
			g_bFired ? "是" : "否",
			g_bAnyLeft ? "是" : "否",
			IsSecondHalfOfRound() ? "是" : "否");
	ReplyToCommand(client, "[SM] 原始报告=%s", g_sRaw[0] ? g_sRaw : "(本轮还没生成)");
	ReplyToCommand(client, "[SM] 解析报告=%s", g_sParsed[0] ? g_sParsed : "(本轮还没生成)");

	return Plugin_Handled;
}
