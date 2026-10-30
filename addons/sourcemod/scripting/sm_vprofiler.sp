/**
 * sm_vprofiler —— Valve 性能采集（vprof）自动录制 + 解析
 * 原插件: "[ANY] [Debugger] Valve Profiler" by Alex Dragokas (1.1)
 *          https://github.com/dragokas/
 * 本版修改: apples1949
 * ------------------------------------------------------------------
 * 作用：生还者离开安全区域（回合真正开打）时，自动开一轮 vprof 采样，
 *       到点停止，并把控制台里的采集结果"解析"成一份可读的排名报告。
 *
 * 触发口径：**每张地图只录制一次**。
 *       对抗模式下一张地图要打两个半场（进攻/防守各一次，两次都会重新加载同一张图），
 *       所以额外用引擎属性 m_bInSecondHalfOfRound 判掉后半场 —— 对抗两回合只录 1 回合。
 *       同一张图内团灭重开不会重复录制（标记只在换图时清）。
 *
 * 具体执行的采集动作（与原插件一致，用的是引擎自带 vprof + SourceMod 的 sm prof）：
 *       vprof_on  →  sm prof start vprof
 *       ... 采 vprofiler_duration 秒 ...
 *       sm prof stop vprof  →  sm prof dump vprof  →  vprof_off
 *   注：github.com/xiaolinRM/perfstat 是另一个"进程内按模块采样"的纯引擎插件
 *       （perf_start / perf_top / perf_dump），跟本插件的采集通道无关；本插件只借用它
 *       报告的读表口径（按占比/耗时从大到小排名）来组织解析结果。
 *
 * 日志（默认都在 addons/sourcemod/logs/vprofiler/，可用 vprofiler_log_folder 改）：
 *       vprof_<地图>_<时间>.log      ← 解析后的报告（本插件的最终产物）
 *       raw_vprof_<地图>_<时间>.log  ← 录制期间的原始控制台镜像，**解析成功立刻删除**
 *
 * L4D2 的 con_logfile 是坏的（https://github.com/ValveSoftware/Source-1-Games/issues/3601），
 * 所以 L4D2 上沿用原插件的做法：不改 con_logfile，而是从 console.log 当前位置往后
 * 增量镜像到 raw 文件（需要服务端带 -condebug 启动，否则拿不到控制台输出）。
 *
 * 配置：vprofiler_enabled / vprofiler_duration / vprofiler_log_folder / vprofiler_report_top
 *       （AutoExecConfig 生成 cfg/sourcemod/sm_vprofiler.cfg）
 * ------------------------------------------------------------------
 */

#define PLUGIN_VERSION "2.0.0"

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define LOG_CHECK_INTERVAL  5.0     /* 镜像/等待落盘的轮询间隔(秒) */
#define LOG_MAX_WAITTIME    60.0    /* 停止采集后最多等多久的控制台输出(秒) */
#define MAX_PARSE_LINES     6000    /* 解析前最多收集多少条候选行(防爆内存) */
#define LINE_MAX            512
#define TEAM_SURVIVOR       2
#define TEAM_L4D1_SURVIVOR  4

ConVar g_cvEnabled;
ConVar g_cvDuration;
ConVar g_cvFolder;
ConVar g_cvTop;
ConVar g_cvLogFile;

char g_sFolder[PLATFORM_MAX_PATH];
char g_sRaw[PLATFORM_MAX_PATH];
char g_sParsed[PLATFORM_MAX_PATH];
char g_sConsole[] = "console.log";
char g_sLogFileOrig[PLATFORM_MAX_PATH];
char g_sTrigger[64];

Handle g_hStopTimer;
Handle g_hPollTimer;
int    g_iConsoleOffset = -1;
bool   g_bL4D2;
bool   g_bCapturing;   /* 正在录制 / 等待落盘 */
bool   g_bFired;       /* 本张地图是否已经录过一次 */

/* 解析过程中的临时表: 每项是 "指标|原始行" */
ArrayList g_hRows;

public Plugin myinfo =
{
	name        = "[ANY] [Debugger] Valve Profiler (auto capture)",
	description = "生还者离开安全区时自动录制 vprof，并把控制台采集结果解析成排名报告",
	author      = "Alex Dragokas, apples1949",
	version     = PLUGIN_VERSION,
	url         = "https://github.com/dragokas/"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	g_bL4D2 = (GetEngineVersion() == Engine_Left4Dead2);
	return APLRes_Success;
}

public void OnPluginStart()
{
	CreateConVar("sm_prof_version", PLUGIN_VERSION, "Plugin Version", FCVAR_NOTIFY | FCVAR_DONTRECORD);

	g_cvEnabled  = CreateConVar("vprofiler_enabled", "1",
			"生还者离开安全区域时自动录制 vprof 并解析报告: 0=关闭(只保留手动 sm_debug) 1=开启",
			FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvDuration = CreateConVar("vprofiler_duration", "60.0",
			"每次自动录制的时长(秒): 到点自动 sm prof stop/dump vprof + vprof_off",
			FCVAR_NONE, true, 5.0, true, 600.0);
	g_cvFolder   = CreateConVar("vprofiler_log_folder", "addons/sourcemod/logs/vprofiler",
			"解析报告的存放目录(相对游戏根目录)。原始采集文件也临时放这里, 解析成功后立刻删除");
	g_cvTop      = CreateConVar("vprofiler_report_top", "40",
			"解析报告里最多列出多少条性能行(按占比/耗时降序)",
			FCVAR_NONE, true, 5.0, true, 500.0);

	g_cvLogFile = FindConVar("con_logfile");

	RegAdminCmd("sm_debug", Cmd_Debug, ADMFLAG_ROOT, "手动开始一轮 vprof 采集(不影响自动触发状态)");
	RegAdminCmd("sm_vprofiler_status", Cmd_Status, ADMFLAG_GENERIC, "查看 vprofiler 自动录制状态与目录配置");

	AutoExecConfig(true, "sm_vprofiler");

	if (g_bL4D2)
	{
		HookEvent("player_left_start_area", Event_LeftStartArea, EventHookMode_Post);
	}
	else
	{
		LogMessage("[vprofiler] 非 L4D2 引擎, 没有 player_left_start_area 事件, 自动录制不可用(可用 sm_debug 手动录)。");
	}

	BuildFolderPath();
}

public void OnConfigsExecuted()
{
	if (g_cvLogFile != null)
		g_cvLogFile.GetString(g_sLogFileOrig, sizeof(g_sLogFileOrig));

	BuildFolderPath();
}

public void OnMapStart()
{
	/* 换图才重置"本图已录过", 同一张图内团灭重开不重复录 */
	g_bFired     = false;
	g_bCapturing = false;
}

/* ---------------------------------------------------------------- 触发 */

public void Event_LeftStartArea(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnabled.BoolValue || g_bFired || g_bCapturing)
		return;

	int client = GetClientOfUserId(event.GetInt("userid", 0));

	/* 只认真人玩家: bot 离开安全区不触发(避免机器人热身阶段就吃掉本图唯一一次配额) */
	if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
		return;

	int team = GetClientTeam(client);

	if (team != TEAM_SURVIVOR && team != TEAM_L4D1_SURVIVOR)
		return;

	/* 对抗模式后半场(同一张图打第二遍): 不录, 保证"两回合只执行 1 回合" */
	if (IsSecondHalfOfRound())
	{
		LogMessage("[vprofiler] 本图为对抗后半场, 跳过自动录制(每张图只录一次)。");
		return;
	}

	BeginCapture("player_left_start_area");
}

/* 对抗模式下"本回合是否是后半场" (非对抗模式恒为 false) */
stock bool IsSecondHalfOfRound()
{
	int rules = FindEntityByClassname(-1, "terror_gamerules");

	if (rules == -1)
		return false;

	return view_as<bool>(GetEntProp(rules, Prop_Send, "m_bInSecondHalfOfRound"));
}

/* ---------------------------------------------------------------- 采集 */

void BeginCapture(const char[] reason)
{
	if (g_bCapturing)
		return;

	if (!EnsureFolder())
		return;

	if (g_cvLogFile == null && !g_bL4D2)
	{
		LogError("[vprofiler] 找不到 con_logfile, 无法采集控制台输出。");
		return;
	}

	char sTime[32];
	FormatTime(sTime, sizeof(sTime), "%Y%m%d_%H%M%S", GetTime());

	char sMap[64];
	GetCurrentMap(sMap, sizeof(sMap));
	SanitizeName(sMap, sizeof(sMap));

	FormatEx(g_sRaw, sizeof(g_sRaw), "%s/raw_vprof_%s_%s.log", g_sFolder, sMap, sTime);
	FormatEx(g_sParsed, sizeof(g_sParsed), "%s/vprof_%s_%s.log", g_sFolder, sMap, sTime);

	g_bCapturing = true;
	g_bFired     = true;
	strcopy(g_sTrigger, sizeof(g_sTrigger), reason);

	/* L4D2: 从 console.log 当前位置开始往后镜像; 其它引擎: 直接把 con_logfile 指到 raw */
	g_iConsoleOffset = -1;

	if (g_bL4D2)
	{
		g_iConsoleOffset = FileSize(g_sConsole);

		if (g_iConsoleOffset < 0)
			g_iConsoleOffset = 0;
	}
	else
	{
		SetCvarSilent(g_cvLogFile, g_sRaw);
	}

	PrintToServer("[vprofiler] 开始采集(%s), 时长 %.0f 秒 → %s", reason, g_cvDuration.FloatValue, g_sParsed);
	LogMessage("[vprofiler] capture started (%s), duration %.0fs, raw \"%s\"", reason, g_cvDuration.FloatValue, g_sRaw);

	ServerCommand("vprof_on");
	ServerExecute();
	RequestFrame(OnFrameStartProf);

	delete g_hStopTimer;
	g_hStopTimer = CreateTimer(g_cvDuration.FloatValue, Timer_StopCapture, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void OnFrameStartProf()
{
	ServerCommand("sm prof start vprof");
}

public Action Timer_StopCapture(Handle timer)
{
	g_hStopTimer = null;

	if (!g_bCapturing)
		return Plugin_Continue;

	ServerCommand("sm prof stop vprof");
	ServerCommand("sm prof dump vprof");
	ServerCommand("vprof_off");

	/* 引擎还要一点时间把 dump 打完; L4D2 还要把那段控制台增量镜像出来 */
	delete g_hPollTimer;
	g_hPollTimer = CreateTimer(LOG_CHECK_INTERVAL, Timer_PollConsole, 0.0, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

	return Plugin_Continue;
}

/**
 * 轮询等控制台输出落定, 然后解析。
 * L4D2: 每个周期把 console.log 从上次位置到末尾的增量追加进 raw 文件。
 * 其它引擎: con_logfile 已经直接指向 raw, 这里只等文件不再变大。
 * 连续两个周期大小不变 = 落定。
 */
public Action Timer_PollConsole(Handle timer, float elapsed)
{
	static int  iStable;
	static int  iLastSize;
	static bool bFirst = true;

	if (bFirst)
	{
		bFirst    = false;
		iStable   = 0;
		iLastSize = -1;
	}

	if (elapsed > LOG_MAX_WAITTIME)
	{
		g_hPollTimer = null;
		bFirst       = true;
		FinishCapture("等待控制台输出落盘超时");
		return Plugin_Stop;
	}

	if (g_bL4D2)
		MirrorConsoleDelta();

	int size = FileSize(g_sRaw);

	if (size > 0 && size == iLastSize)
	{
		if (++iStable >= 2)
		{
			g_hPollTimer = null;
			bFirst       = true;
			FinishCapture("");
			return Plugin_Stop;
		}
	}
	else
	{
		iStable   = 0;
		iLastSize = size;
	}

	return Plugin_Continue;
}

/* 把 console.log 里"上次位置之后"的新增内容追加进 raw 文件 */
void MirrorConsoleDelta()
{
	int size = FileSize(g_sConsole);

	if (size <= 0)
		return;

	if (g_iConsoleOffset < 0)
	{
		g_iConsoleOffset = size;
		return;
	}

	if (size <= g_iConsoleOffset)
		return;

	File hr = OpenFile(g_sConsole, "rb");

	if (hr == null)
	{
		LogError("[vprofiler] 打不开 %s (服务端需要 -condebug 才能拿到控制台输出)", g_sConsole);
		return;
	}

	File hw = OpenFile(g_sRaw, "ab");

	if (hw == null)
	{
		LogError("[vprofiler] 打不开 raw 文件 %s", g_sRaw);
		delete hr;
		return;
	}

	hr.Seek(g_iConsoleOffset, SEEK_SET);

	int bytesRead;
	int buff[1024];

	while (!hr.EndOfFile())
	{
		bytesRead = hr.Read(buff, sizeof(buff), 1);

		if (bytesRead <= 0)
			break;

		hw.Write(buff, bytesRead, 1);
	}

	g_iConsoleOffset = hr.Position;

	delete hw;
	delete hr;
}

/* ---------------------------------------------------------------- 收尾: 解析 + 删原始 */

void FinishCapture(const char[] note)
{
	if (!g_bL4D2 && g_cvLogFile != null)
		SetCvarSilent(g_cvLogFile, g_sLogFileOrig);

	/* 停止那一刻的尾巴还在 console.log 里, 最后再补一次 */
	if (g_bL4D2)
		MirrorConsoleDelta();

	g_bCapturing = false;

	if (!ParseRawToReport(note))
	{
		/* 解析不出东西时不能删原始文件, 否则这一轮数据就彻底没了 */
		PrintToServer("[vprofiler] 没解析出性能行, 原始文件保留: %s", g_sRaw);
		LogMessage("[vprofiler] nothing parsed, raw kept: \"%s\" (%s)", g_sRaw, note);
		return;
	}

	DeleteFile(g_sRaw);
	PrintToServer("[vprofiler] 解析完成 → %s (原始文件已删除)", g_sParsed);
	LogMessage("[vprofiler] parsed report written: \"%s\", raw removed", g_sParsed);
}

/**
 * 解析 raw → g_sParsed。
 * 采集结果是控制台文本, 不同版本格式不完全一致, 所以这里用宽容解析:
 * 把"紧贴在 % 前的数字"或"紧贴在 ms 前的数字"当成该行指标, 其余文字当名称;
 * 按指标降序排名输出。一条都解析不出来时返回 false (调用处保留原始文件)。
 */
bool ParseRawToReport(const char[] note)
{
	File hr = OpenFile(g_sRaw, "r");

	if (hr == null)
	{
		LogError("[vprofiler] 读不到 raw 文件 %s", g_sRaw);
		return false;
	}

	delete g_hRows;
	g_hRows = new ArrayList(ByteCountToCells(256));

	int  iLines = 0;
	char line[LINE_MAX];

	while (!hr.EndOfFile() && g_hRows.Length < MAX_PARSE_LINES)
	{
		if (!hr.ReadLine(line, sizeof(line)))
			break;

		iLines++;

		char  name[192];
		float metric;

		if (!ExtractPerfRow(line, name, sizeof(name), metric))
			continue;

		TrimString(name);

		if (name[0] == '\0')
			continue;

		char entry[256];
		FormatEx(entry, sizeof(entry), "%.4f|%s", metric, name);
		g_hRows.PushString(entry);
	}

	delete hr;

	if (g_hRows.Length == 0)
		return false;

	g_hRows.SortCustom(SortByMetricDesc);

	int top = g_cvTop.IntValue;

	if (top < 1)
		top = 1;

	if (top > g_hRows.Length)
		top = g_hRows.Length;

	char sMap[64], sNow[32];
	GetCurrentMap(sMap, sizeof(sMap));
	FormatTime(sNow, sizeof(sNow), "%Y-%m-%d %H:%M:%S", GetTime());

	File hw = OpenFile(g_sParsed, "w");

	if (hw == null)
	{
		LogError("[vprofiler] 无法写解析报告 %s (检查 vprofiler_log_folder)", g_sParsed);
		return false;
	}

	hw.WriteLine("======================================================================");
	hw.WriteLine(" [vprofiler] Valve 性能采集解析报告");
	hw.WriteLine("----------------------------------------------------------------------");
	hw.WriteLine(" 地图        : %s", sMap);
	hw.WriteLine(" 触发        : %s", g_sTrigger);
	hw.WriteLine(" 生成时间    : %s", sNow);
	hw.WriteLine(" 录制时长    : %.0f 秒", g_cvDuration.FloatValue);
	hw.WriteLine(" 采集命令    : vprof_on / sm prof start-stop-dump vprof / vprof_off");
	hw.WriteLine(" 读原始行数  : %d, 解析出 %d 条性能行(同名不合并)", iLines, g_hRows.Length);

	if (note[0] != '\0')
		hw.WriteLine(" 备注        : %s", note);

	hw.WriteLine("----------------------------------------------------------------------");
	hw.WriteLine(" 说明: 指标 = 该行紧贴 %% 或 ms 前的数字(引擎 vprof 的占比/耗时)。");
	hw.WriteLine("       排名只是把原始文本按指标排序, 不做符号还原; 想定位具体函数,");
	hw.WriteLine("       用报告里出现的名字去 IDA / dumpbin / 符号表里查。");
	hw.WriteLine("----------------------------------------------------------------------");
	hw.WriteLine("  #  指标          原始行");
	hw.WriteLine("----------------------------------------------------------------------");

	char  entry[256], shown[192];
	float metric;

	for (int i = 0; i < top; i++)
	{
		g_hRows.GetString(i, entry, sizeof(entry));

		metric = StringToFloat(entry);

		/* 存的格式是 "指标|原始行", 把 '|' 之后的原文取出来显示 */
		int bar = StrContains(entry, "|");

		if (bar >= 0)
			strcopy(shown, sizeof(shown), entry[bar + 1]);
		else
			strcopy(shown, sizeof(shown), entry);

		hw.WriteLine(" %3d %12.4f  %s", i + 1, metric, shown);
	}

	hw.WriteLine("----------------------------------------------------------------------");
	hw.WriteLine(" 共 %d 条, 上面列出前 %d 条。", g_hRows.Length, top);
	hw.WriteLine("======================================================================");

	delete hw;
	delete g_hRows;
	g_hRows = null;

	return true;
}

public int SortByMetricDesc(int index1, int index2, Handle array, Handle hndl)
{
	ArrayList list = view_as<ArrayList>(array);
	char a[256], b[256];

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

/**
 * 从一行控制台输出里抽出"指标 + 名称"。支持(按优先级):
 *   1) 数字紧贴在 % 前      例: "  12.34% SomeFunc"
 *   2) 数字紧贴在 ms 前     例: "  12.34ms SomeFunc"
 *   3) 兜底: 行内至少有 2 列且含浮点数 → 取最后一个浮点当指标, 第一个字段当名称
 */
bool ExtractPerfRow(const char[] line, char[] name, int nameLen, float &metric)
{
	char buf[LINE_MAX];
	strcopy(buf, sizeof(buf), line);
	TrimString(buf);

	if (buf[0] == '\0')
		return false;

	/* 纯分隔线 / 注释行跳过 */
	if (buf[0] == '=' || buf[0] == '-' || buf[0] == '/' || buf[0] == ';' || buf[0] == '#')
		return false;

	/* 1) "%" */
	int pct = FindCharInString(buf, '%', true);

	if (pct > 0)
	{
		int   start;
		float val;

		if (TakeNumberBefore(buf, pct, val, start))
		{
			metric = val;
			strcopy(name, nameLen, buf);
			name[start] = '\0';
			TrimString(name);

			if (name[0] != '\0')
				return true;

			/* 百分号在最前面("12.3% Func"): 名称取 % 之后 */
			strcopy(name, nameLen, buf[pct + 1]);
			TrimString(name);

			return (name[0] != '\0');
		}
	}

	/* 2) "ms" */
	int ms = StrContains(buf, "ms", true);

	if (ms > 0)
	{
		int   start;
		float val;

		if (TakeNumberBefore(buf, ms, val, start))
		{
			metric = val;
			strcopy(name, nameLen, buf);
			name[start] = '\0';
			TrimString(name);

			if (name[0] != '\0')
				return true;
		}
	}

	/* 3) 兜底 */
	int  fields       = 0;
	int  lastNumStart = -1;
	int  lastNumEnd   = -1;
	bool sawFloat     = false;

	for (int i = 0; buf[i] != '\0'; i++)
	{
		if (i > 0 && buf[i - 1] != ' ' && buf[i - 1] != '\t')
			continue;

		int j = i;

		while (buf[j] == ' ' || buf[j] == '\t')
			j++;

		fields++;

		if (buf[j] < '0' || buf[j] > '9')
			continue;

		int  k      = j;
		bool hasDot = false;

		while ((buf[k] >= '0' && buf[k] <= '9') || buf[k] == '.')
		{
			if (buf[k] == '.')
				hasDot = true;

			k++;
		}

		if (hasDot)
		{
			sawFloat     = true;
			lastNumStart = j;
			lastNumEnd   = k;
		}
	}

	if (!sawFloat || fields < 2 || lastNumStart <= 0)
		return false;

	int len = lastNumEnd - lastNumStart;

	if (len <= 0 || len >= sizeof(buf))
		return false;

	char numBuf[32];

	if (len >= sizeof(numBuf))
		return false;

	strcopy(numBuf, len + 1, buf[lastNumStart]);
	metric = StringToFloat(numBuf);

	strcopy(name, nameLen, buf);
	name[lastNumStart] = '\0';
	TrimString(name);

	return (name[0] != '\0');
}

/* 从 idx 位置往前跳过空格后取一段数字; 成功返回 true 并把段起点写到 start */
bool TakeNumberBefore(const char[] buf, int idx, float &val, int &start)
{
	int i = idx - 1;

	while (i >= 0 && (buf[i] == ' ' || buf[i] == '\t'))
		i--;

	int end = i + 1;

	while (i >= 0 && ((buf[i] >= '0' && buf[i] <= '9') || buf[i] == '.' || buf[i] == '-'))
		i--;

	start = i + 1;

	if (start >= end)
		return false;

	int len = end - start;

	if (len <= 0 || len >= 32)
		return false;

	char numBuf[32];
	strcopy(numBuf, len + 1, buf[start]);
	val = StringToFloat(numBuf);

	return true;
}

/* ---------------------------------------------------------------- 目录 / 工具 */

void BuildFolderPath()
{
	if (g_cvFolder == null)
		return;

	g_cvFolder.GetString(g_sFolder, sizeof(g_sFolder));
	TrimString(g_sFolder);

	int len = strlen(g_sFolder);

	while (len > 0 && (g_sFolder[len - 1] == '/' || g_sFolder[len - 1] == '\\'))
		g_sFolder[--len] = '\0';

	if (g_sFolder[0] == '\0')
		strcopy(g_sFolder, sizeof(g_sFolder), "addons/sourcemod/logs/vprofiler");
}

bool EnsureFolder()
{
	if (DirExists(g_sFolder))
		return true;

	/* 逐级创建(CreateDirectory 只建一层) */
	char part[PLATFORM_MAX_PATH];
	part[0] = '\0';

	for (int i = 0; g_sFolder[i] != '\0'; i++)
	{
		if (g_sFolder[i] == '/' || g_sFolder[i] == '\\')
		{
			if (part[0] != '\0' && !DirExists(part))
				CreateDirectory(part, 0777);
		}

		int len = strlen(part);

		if (len + 1 < sizeof(part))
		{
			part[len]     = g_sFolder[i];
			part[len + 1] = '\0';
		}
	}

	if (part[0] != '\0' && !DirExists(part))
		CreateDirectory(part, 0777);

	if (!DirExists(g_sFolder))
	{
		LogError("[vprofiler] 建不了日志目录 \"%s\", 检查 vprofiler_log_folder", g_sFolder);
		return false;
	}

	return true;
}

void SanitizeName(char[] s, int len)
{
	for (int i = 0; i < len && s[i] != '\0'; i++)
	{
		if (s[i] == '/' || s[i] == '\\' || s[i] == ':' || s[i] == ' ' || s[i] == '*'
			|| s[i] == '?' || s[i] == '"' || s[i] == '<' || s[i] == '>' || s[i] == '|')
			s[i] = '_';
	}
}

void SetCvarSilent(ConVar cvar, const char[] value)
{
	if (cvar == null)
		return;

	int flags = cvar.Flags;
	cvar.Flags &= ~FCVAR_NOTIFY;
	cvar.SetString(value);
	cvar.Flags = flags;
}

/* ---------------------------------------------------------------- 指令 */

public Action Cmd_Debug(int client, int args)
{
	if (g_bCapturing)
	{
		ReplyToCommand(client, "[SM] 正在录制中, 等这一轮结束后再手动开始。");
		return Plugin_Handled;
	}

	BeginCapture("手动 sm_debug");

	return Plugin_Handled;
}

public Action Cmd_Status(int client, int args)
{
	ReplyToCommand(client, "[vprofiler] enabled=%d duration=%.0fs top=%d",
			g_cvEnabled.IntValue, g_cvDuration.FloatValue, g_cvTop.IntValue);
	ReplyToCommand(client, "[vprofiler] folder=%s", g_sFolder);
	ReplyToCommand(client, "[vprofiler] 本图已录过=%s 正在录制=%s 后半场=%s",
			g_bFired ? "是" : "否",
			g_bCapturing ? "是" : "否",
			IsSecondHalfOfRound() ? "是" : "否");
	ReplyToCommand(client, "[vprofiler] 最近一份报告: %s", g_sParsed[0] ? g_sParsed : "(还没生成)");

	return Plugin_Handled;
}
