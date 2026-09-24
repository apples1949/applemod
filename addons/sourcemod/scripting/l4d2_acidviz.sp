/**
 * L4D2 AcidViz —— Spitter 酸液(口水)判定范围可视化
 *
 * 由 VScript (Squirrel) 版 "AcidViz 0.3.1-green" 移植为 SourceMod 插件。
 *
 * 原理(与原脚本一致): 遍历地图上的 insect_swarm(酸液池), 读取其伤害节点
 *   m_fireCount / m_fireXDelta / m_fireYDelta / m_fireZDelta,
 *   以 节点 + 半径 sm_acidviz_radius 画圆; outline 模式下把水平投影相交、
 *   高度差在 sm_acidviz_mergez 以内的圆合并成并集轮廓, 便于观察酸液覆盖范围。
 *
 * ⚠ 只读绘制: 本插件不写任何实体属性、不改动伤害判定。sm_acidviz_radius 只是
 *   "显示半径", 是否等于实际伤害半径需自行校准(原脚本同样标注 UNVERIFIED)。
 *
 * 与 VScript 版的差异(移植说明):
 *   1. 绘制介质: env_beam 实体 → TE 光束(BeamPoints 临时实体)。不占 edict、
 *      不残留实体、插件卸载/换图无需清理, 因此原版的 Beams/Pending 实体池、
 *      SyncBeams、WorldCount/MaxWorldEntities 全部不再需要。
 *   2. 参数: root table 字段 → ConVar(可在线热调, 改完下一 tick 生效)。
 *   3. !acidstatus → sm_acidstatus(聊天输入 !acidstatus 或 /acidstatus 同样可用)。
 *   4. 保留原版预算保护: 段数超过 sm_acidviz_max_beams 时折半降低绘图段数,
 *      降到 sm_acidviz_min_segments 仍超标 → 本轮隐藏全部线条(下一回合自动恢复)。
 *   5. 新增引擎限流适配: 单帧临时实体数量受 sv_multiplayer_maxtempentities 限制
 *      (L4D2 引擎无此 cvar 时按默认 32 处理), 超出部分会被引擎丢弃。本插件按该额度
 *      分批轮转发送, 并把光束寿命延长到"下一次轮到它"的时刻, 段数多时也完整不闪。
 *   6. 新增 sm_acidviz_dump: 只读打印节点几何与"合并门槛"统计, 用于排查
 *      "为什么画出来是多个独立圆圈而不是一个合并范围"。
 *   7. mergez 默认值由原脚本的 1.0 调整为 30.0: 实测 L4D2 一口水的 10 个伤害节点
 *      高度跨度可达 87 单位(z 增量为整数), 1.0 会让 45 对组合里只有 4 对能合并,
 *      结果是 5 个节点各自画整圆 → 看起来是"多个独立圆圈"。30 在该实测数据上已能
 *      合并成 1 个连通范围(23/45 对合并, 0 个孤立节点), 同时仍能区分高差更大的
 *      上下层口水; 300 = 完全按水平投影合并。
 *   8. 绘制链只跟 sm_acidviz_enable 绑定(修复"战役第一回合不生效"): 原实现照搬脚本,
 *      在 round_end / map_transition 里 Stop(), 并在 OnMapStart 里复位为停止 —— 实测
 *      服务器启动后第一回合里 round_start 并不保证会把这链条重新拉起来(且 map_transition
 *      可能晚于 round_start 触发), 于是整局都不画, 直到团灭/换图才恢复。TE 光束本来
 *      就没有实体需要清理, 因此现在: OnMapStart 直接确保运行、不再因回合事件停链。
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION		"0.4.4"

#define ACID_CLASSNAME		"insect_swarm"						// Spitter 酸液池
#define BEAM_DEFAULT_MODEL	"materials/sprites/laserbeam.vmt"

#define TAU_VALUE			6.283185307179586					// 2 * PI
#define SEGMENTS_MIN		8									// 与原脚本 MinSegments 一致
#define SEGMENTS_MAX		64									// 与原脚本分段校验上限一致
#define MAX_NODES			256									// 节点静态缓冲上限(sm_acidviz_max_nodes 不得超过)
#define MAX_ARCS			(2 * MAX_NODES + 4)					// 并集轮廓弧段上限: 每个节点最多切 2 刀
#define MAX_PENDING			512									// 单次刷新线段静态缓冲上限
#define MAX_BEAMS_CEILING	500									// sm_acidviz_max_beams 上限(预留 1 个溢出探测位)
#define MAX_CHUNKS			16									// 临时实体超预算时最多分批数
#define DEFAULT_TEMPENTS	32									// sv_multiplayer_maxtempentities 缺省值

ConVar
	g_cvEnable,
	g_cvMode,
	g_cvRadius,
	g_cvLift,
	g_cvMergeZ,
	g_cvInterval,
	g_cvSegments,
	g_cvMinSegments,
	g_cvBeamWidth,
	g_cvMaxBeams,
	g_cvMaxNodes,
	g_cvColor,
	g_cvModel,
	g_cvDebug,				// 调试输出开关
	g_cvMaxTempEnts;		// sv_multiplayer_maxtempentities(只读引用)

// ---------------------------------------------------------------------------
// 运行状态
// ---------------------------------------------------------------------------
bool
	g_bEnabled,				// 是否处于绘制状态(定时链存活)
	g_bLimited,				// 段数预算超标, 本轮隐藏全部线条
	g_bPendOverflow;		// 本次构建线段数超过 sm_acidviz_max_beams

int
	g_iGeneration,			// 定时链世代号(防止 Stop/Start 之间出现两条定时链)
	g_iTicks,
	g_iLastPools,
	g_iLastNodes,
	g_iLastSegments,
	g_iLastDrawSegments,
	g_iLastSent,
	g_iLastChunks,
	g_iChunkCursor,
	g_iBeamModel,
	g_iPendCount,
	g_iPendLimit,
	g_iDebugLastPools;		// 调试用: 上次看到的池数量(变化时打印一行)

int
	g_iBeamColor[4] = {30, 60, 0, 255};		// 原脚本 "30 60 0"(黄绿)

float
	g_fRadius,
	g_fLift,
	g_fMergeZ,
	g_fBeamWidth,
	g_fInterval;

char
	g_sFault[192];			// 非空 = 已因错误停绘, 需下一回合/重新启用才能恢复

// ---------------------------------------------------------------------------
// 绘制缓冲
// ---------------------------------------------------------------------------
float
	g_fNodes[MAX_NODES][3],					// 伤害节点世界坐标
	g_fArcLo[MAX_ARCS],						// 并集轮廓: 弧段起点角
	g_fArcHi[MAX_ARCS],						// 并集轮廓: 弧段终点角
	g_fPendStart[MAX_PENDING][3],			// 待发送线段起点
	g_fPendEnd[MAX_PENDING][3];				// 待发送线段终点

int
	g_iNodeCount,
	g_iArcCount;

public Plugin myinfo =
{
	name = "L4D2 AcidViz",
	author = "apples1949",
	description = "可视化 Spitter 酸液(insect_swarm)伤害节点与显示半径(移植自 VScript AcidViz 0.3.1-green)",
	version = PLUGIN_VERSION,
	url = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	char sGame[12];
	GetGameFolderName(sGame, sizeof(sGame));
	if (!StrEqual(sGame, "left4dead2"))
	{
		strcopy(error, err_max, "Plugin only supports L4D2");
		return APLRes_Failure;
	}
	return APLRes_Success;
}

public void OnPluginStart()
{
	g_cvEnable = CreateConVar("sm_acidviz_enable", "1",
		"总开关: 1=回合内自动绘制酸液可视范围, 0=关闭", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvMode = CreateConVar("sm_acidviz_mode", "0",
		"绘制模式: 0=outline(重叠圆合并为并集轮廓) 1=circles(每个节点各画整圆)", _, true, 0.0, true, 1.0);
	g_cvRadius = CreateConVar("sm_acidviz_radius", "75.0",
		"显示半径(游戏单位): 只改变绘图, 不修改实际伤害范围, 需自行校准", _, true, 1.0, true, 300.0);
	g_cvLift = CreateConVar("sm_acidviz_lift", "3.0",
		"光圈相对伤害节点上移的高度, 用于减少埋入地面", _, true, -100.0, true, 100.0);
	g_cvMergeZ = CreateConVar("sm_acidviz_mergez", "30.0",
		"合并节点时允许的高度差(仅影响绘图): 实测口水落点高度跨度可达87(整数z增量), 原脚本默认1.0过严会让每个节点各自成整圆; 30 在实测数据上已能连成一个范围, 300=完全按水平投影合并",
		_, true, 0.0, true, 300.0);
	g_cvInterval = CreateConVar("sm_acidviz_interval", "0.20",
		"刷新间隔(秒)", _, true, 0.05, true, 2.0);
	g_cvSegments = CreateConVar("sm_acidviz_segments", "16",
		"完整圆的分段数(8-64)", _, true, float(SEGMENTS_MIN), true, float(SEGMENTS_MAX));
	g_cvMinSegments = CreateConVar("sm_acidviz_min_segments", "8",
		"段数超预算时允许降到的最低分段数(8-64)", _, true, float(SEGMENTS_MIN), true, float(SEGMENTS_MAX));
	g_cvBeamWidth = CreateConVar("sm_acidviz_beam_width", "1.2",
		"光束宽度(游戏单位), 实际观感还受发光材质与画面设置影响", _, true, 0.1, true, 32.0);
	g_cvMaxBeams = CreateConVar("sm_acidviz_max_beams", "256",
		"一次刷新允许绘制的最大线段数, 超限时降段数, 降至下限仍超限则本轮隐藏全部线条",
		_, true, 1.0, true, float(MAX_BEAMS_CEILING));
	g_cvMaxNodes = CreateConVar("sm_acidviz_max_nodes", "128",
		"全场伤害节点总数上限, 超过则停绘并报错(需下一回合恢复)", _, true, 1.0, true, float(MAX_NODES));
	g_cvColor = CreateConVar("sm_acidviz_color", "30 60 0",
		"光束颜色 \"R G B\"(0-255)");
	g_cvModel = CreateConVar("sm_acidviz_model", BEAM_DEFAULT_MODEL,
		"光束使用的精灵材质");
	g_cvDebug = CreateConVar("sm_acidviz_debug", "0",
		"调试输出: 1=在服务器控制台打印地图/回合/启停/口水数量变化(排查\"某回合不生效\"用)", _, true, 0.0, true, 1.0);

	g_cvMaxTempEnts = FindConVar("sv_multiplayer_maxtempentities");

	g_cvEnable.AddChangeHook(OnEnableChanged);
	g_cvColor.AddChangeHook(OnColorChanged);
	g_cvModel.AddChangeHook(OnModelChanged);

	char colorValue[32];
	g_cvColor.GetString(colorValue, sizeof(colorValue));
	ParseColor(colorValue, false);		// 解析初始颜色, 非法时保留内置默认值

	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);

	RegConsoleCmd("sm_acidstatus", Cmd_AcidStatus, "AcidViz: 显示当前可视化状态");
	RegConsoleCmd("sm_acidviz_dump", Cmd_AcidDump, "AcidViz: 打印口水节点几何与合并门槛统计(诊断为什么没合并)");

	// 原脚本在载入时即 Start(), 这里保持一致(热装载也能立刻看到效果)
	if (g_cvEnable.BoolValue)
		Start();

	PrintToServer("[AcidViz] Loaded %s (mode=%s radius=%.1f); 聊天输入 !acidstatus 查看状态",
		PLUGIN_VERSION, g_cvMode.IntValue == 0 ? "outline" : "circles", g_cvRadius.FloatValue);
}

public void OnPluginEnd()
{
	Stop();
}

public void OnMapStart()
{
	PrecacheBeamModel();

	// 关键: 换图后必须确保链条在跑。原实现这里只把状态复位为停止, 依赖后续 round_start
	// 重新拉起 —— 实测服务器启动后的第一回合并不保证触发 round_start, 于是整局不画。
	DebugMsg("OnMapStart: model=%d enable=%d", g_iBeamModel, g_cvEnable.BoolValue);
	if (g_cvEnable.BoolValue)
		Start();
}

public void OnMapEnd()
{
	Stop();
}

// ---------------------------------------------------------------------------
// 事件
// ---------------------------------------------------------------------------

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	DebugMsg("event round_start (ensure running)");

	if (g_cvEnable.BoolValue)
		Start();			// 幂等: 已在跑则直接返回
}

// ---------------------------------------------------------------------------
// ConVar 变更
// ---------------------------------------------------------------------------

void OnEnableChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (convar.BoolValue)
		Start();
	else
		Stop();
}

void OnColorChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	ParseColor(newValue, true);
}

void OnModelChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	PrecacheBeamModel();
}

// ---------------------------------------------------------------------------
// 启停
// ---------------------------------------------------------------------------

void Start()
{
	if (g_bEnabled)
		return;			// 已有一条定时链在跑, 避免重复建链

	if (g_iBeamModel <= 0)
		PrecacheBeamModel();

	g_sFault[0] = '\0';
	g_bLimited = false;
	g_bPendOverflow = false;
	g_iTicks = 0;
	g_iLastPools = 0;
	g_iLastNodes = 0;
	g_iLastSegments = 0;
	g_iLastDrawSegments = 0;
	g_iLastSent = 0;
	g_iLastChunks = 0;
	g_iChunkCursor = 0;
	g_iDebugLastPools = -1;				// 强制第一 tick 打印一次池数量

	g_iGeneration++;					// 让上一世代的残留定时器自行退出
	g_bEnabled = true;

	// 自续期一次性定时器: 不保存句柄, 世代号 + g_bEnabled 负责收敛,
	// 因此不存在"句柄失效/换图被杀"导致的重复链或 KillTimer 报错。
	CreateTimer(g_cvInterval.FloatValue, Timer_Draw, g_iGeneration, TIMER_FLAG_NO_MAPCHANGE);
	DebugMsg("Start(): 绘制链启动 gen=%d interval=%.2f", g_iGeneration, g_cvInterval.FloatValue);
}

void Stop()
{
	if (g_bEnabled)
		DebugMsg("Stop(): 绘制链将自行结束");

	g_bEnabled = false;			// 定时器下一次触发时自行结束
}

// 调试输出(仅当 sm_acidviz_debug=1), 用于排查"某回合/某张图不生效"
void DebugMsg(const char[] format, any ...)
{
	if (g_cvDebug == null || !g_cvDebug.BoolValue)
		return;

	char buffer[256];
	VFormat(buffer, sizeof(buffer), format, 2);
	PrintToServer("[AcidViz][debug] %s", buffer);
}

void Fault(const char[] format, any ...)
{
	char reason[160];
	VFormat(reason, sizeof(reason), format, 2);

	strcopy(g_sFault, sizeof(g_sFault), reason);
	g_bEnabled = false;
	LogError("[AcidViz] STOPPED: %s", reason);
	PrintToServer("[AcidViz] STOPPED: %s", reason);
}

// ---------------------------------------------------------------------------
// 主循环
// ---------------------------------------------------------------------------

public Action Timer_Draw(Handle timer, int generation)
{
	// 世代号不符 = 上一次 Stop/Start 的残留定时器, 直接退出
	if (!g_bEnabled || generation != g_iGeneration)
		return Plugin_Stop;

	g_iTicks++;

	float radius = g_cvRadius.FloatValue;
	int segments = g_cvSegments.IntValue;
	int minSegments = g_cvMinSegments.IntValue;

	// 与原脚本 Tick() 的配置校验一致(ConVar 已带边界, 这里再兜一层)
	if (radius <= 0.0 || radius > 300.0
		|| segments < SEGMENTS_MIN || segments > SEGMENTS_MAX
		|| minSegments < SEGMENTS_MIN || minSegments > segments)
	{
		Fault("Invalid drawing configuration (radius=%.2f segments=%d min_segments=%d)",
			radius, segments, minSegments);
		return Plugin_Stop;
	}

	if (g_iBeamModel <= 0)
	{
		Fault("Beam material not precached (check sm_acidviz_model)");
		return Plugin_Stop;
	}

	g_fRadius = radius;
	g_fLift = g_cvLift.FloatValue;
	g_fMergeZ = g_cvMergeZ.FloatValue;
	g_fBeamWidth = g_cvBeamWidth.FloatValue;
	g_fInterval = g_cvInterval.FloatValue;

	if (!ReadNodes())
		return Plugin_Stop;			// 失败原因已在 Fault() 中记录

	if (g_iLastPools != g_iDebugLastPools)
	{
		DebugMsg("口水池 %d -> %d (节点=%d)", g_iDebugLastPools, g_iLastPools, g_iLastNodes);
		g_iDebugLastPools = g_iLastPools;
	}

	int drawSegments = segments;
	int maxDrawable = TempEntBudget() * MAX_CHUNKS;		// 引擎限流下能"稳定不闪"绘制的段数上限
	BuildSegments(drawSegments);

	// 超预算时折半降段数重建, 直到降到下限。第一步(线段数超 sm_acidviz_max_beams)与原脚本一致;
	// 第二步(段数超过引擎单帧临时实体上限 × 分批数)是改用 TE 绘制后新增的约束:
	// 否则轮转周期会长于光束寿命, 表现为圆环局部闪烁。
	while ((g_bPendOverflow || g_iPendCount > maxDrawable) && drawSegments > minSegments)
	{
		drawSegments /= 2;
		if (drawSegments < minSegments)
			drawSegments = minSegments;
		BuildSegments(drawSegments);
	}

	if (g_bPendOverflow || g_iPendCount > maxDrawable)
	{
		Limit();
	}
	else
	{
		g_bLimited = false;
		DrawBeams();
	}

	CreateTimer(g_fInterval, Timer_Draw, generation, TIMER_FLAG_NO_MAPCHANGE);
	return Plugin_Stop;
}

// ---------------------------------------------------------------------------
// 读取伤害节点
// ---------------------------------------------------------------------------

bool ReadNodes()
{
	g_iNodeCount = 0;
	g_iLastPools = 0;

	int maxNodes = g_cvMaxNodes.IntValue;

	int entity = -1;
	while ((entity = FindEntityByClassname(entity, ACID_CLASSNAME)) != -1)
	{
		if (!IsValidEntity(entity))
			continue;

		g_iLastPools++;

		int count = GetEntProp(entity, Prop_Send, "m_fireCount");
		if (count < 0)
		{
			Fault("Invalid/unsupported m_fireCount: %d", count);
			return false;
		}

		if (count == 0)
			continue;

		int sizeX = GetEntPropArraySize(entity, Prop_Send, "m_fireXDelta");
		int sizeY = GetEntPropArraySize(entity, Prop_Send, "m_fireYDelta");
		int sizeZ = GetEntPropArraySize(entity, Prop_Send, "m_fireZDelta");
		if (sizeX < count || sizeY < count || sizeZ < count)
		{
			Fault("Unsupported acid node arrays (size=%d/%d/%d count=%d entity=%d)",
				sizeX, sizeY, sizeZ, count, entity);
			return false;
		}

		float origin[3];
		GetEntPropVector(entity, Prop_Send, "m_vecOrigin", origin);

		for (int i = 0; i < count; i++)
		{
			if (g_iNodeCount >= maxNodes)
			{
				Fault("Total node limit exceeded (%d); visualization stopped", maxNodes);
				return false;
			}

			g_fNodes[g_iNodeCount][0] = origin[0] + float(GetEntProp(entity, Prop_Send, "m_fireXDelta", _, i));
			g_fNodes[g_iNodeCount][1] = origin[1] + float(GetEntProp(entity, Prop_Send, "m_fireYDelta", _, i));
			g_fNodes[g_iNodeCount][2] = origin[2] + float(GetEntProp(entity, Prop_Send, "m_fireZDelta", _, i));
			g_iNodeCount++;
		}
	}

	g_iLastNodes = g_iNodeCount;
	return true;
}

// ---------------------------------------------------------------------------
// 构建线段
// ---------------------------------------------------------------------------

void BuildSegments(int drawSegments)
{
	g_iPendCount = 0;
	g_bPendOverflow = false;

	// 只需要判断"是否超过 max_beams", 因此缓冲写到 max_beams + 1 即停
	g_iPendLimit = g_cvMaxBeams.IntValue + 1;
	if (g_iPendLimit > MAX_PENDING)
		g_iPendLimit = MAX_PENDING;

	bool outline = (g_cvMode.IntValue == 0);

	for (int i = 0; i < g_iNodeCount; i++)
	{
		if (g_bPendOverflow)
			break;			// 结论已定, 不必继续算

		if (outline)
			BuildOutline(i, drawSegments);
		else
			Arc(g_fNodes[i], 0.0, TAU_VALUE, drawSegments);
	}

	g_iLastSegments = g_iPendCount;
	g_iLastDrawSegments = drawSegments;
}

// 单个节点的并集轮廓: 从整圆开始, 逐个减掉与其它节点圆重叠的角度区间
void BuildOutline(int index, int drawSegments)
{
	float center[3];
	center = g_fNodes[index];

	g_iArcCount = 1;
	g_fArcLo[0] = 0.0;
	g_fArcHi[0] = TAU_VALUE;

	for (int j = 0; j < g_iNodeCount; j++)
	{
		if (j == index)
			continue;

		float dx = g_fNodes[j][0] - center[0];
		float dy = g_fNodes[j][1] - center[1];
		float dz = g_fNodes[j][2] - center[2];

		// 高度差超过容差: 即使水平投影重叠也各自保留完整轮廓
		if (FloatAbs(dz) > g_fMergeZ)
			continue;

		float d2 = dx * dx + dy * dy;
		if (d2 < 0.000001)
		{
			if (j < index)
				return;					// 同高度且水平重合的节点只保留一份轮廓

			continue;
		}

		if (d2 >= 4.0 * g_fRadius * g_fRadius)
			continue;					// 两圆不相交, 无需削减

		float dist = SquareRoot(d2);

		// 方位角: 用 acos + dy 符号映射到 [0, 2PI), 不使用 ArcTangent2(实参顺序易混淆)
		float angle = ArcCosine(ClampUnit(dx / dist));
		if (dy < 0.0)
			angle = TAU_VALUE - angle;

		float half = ArcCosine(ClampUnit(dist / (2.0 * g_fRadius)));
		float lo = angle - half;
		float hi = angle + half;

		if (lo < 0.0)
		{
			SubtractInterval(0.0, hi);
			SubtractInterval(lo + TAU_VALUE, TAU_VALUE);
		}
		else if (hi > TAU_VALUE)
		{
			SubtractInterval(lo, TAU_VALUE);
			SubtractInterval(0.0, hi - TAU_VALUE);
		}
		else
		{
			SubtractInterval(lo, hi);
		}

		if (g_iArcCount == 0)
			return;						// 被完全覆盖, 本节点不画
	}

	for (int k = 0; k < g_iArcCount; k++)
		Arc(center, g_fArcLo[k], g_fArcHi[k], drawSegments);
}

// 从弧段集合中减去区间 [lo, hi]
void SubtractInterval(float lo, float hi)
{
	static float tmpLo[MAX_ARCS];
	static float tmpHi[MAX_ARCS];

	int count = 0;

	for (int k = 0; k < g_iArcCount; k++)
	{
		float a = g_fArcLo[k];
		float b = g_fArcHi[k];

		if (hi <= a || lo >= b)
		{
			if (count < MAX_ARCS)
			{
				tmpLo[count] = a;
				tmpHi[count] = b;
				count++;
			}
		}
		else
		{
			if (lo > a && count < MAX_ARCS)
			{
				tmpLo[count] = a;
				tmpHi[count] = lo;
				count++;
			}
			if (hi < b && count < MAX_ARCS)
			{
				tmpLo[count] = hi;
				tmpHi[count] = b;
				count++;
			}
		}
	}

	for (int k = 0; k < count; k++)
	{
		g_fArcLo[k] = tmpLo[k];
		g_fArcHi[k] = tmpHi[k];
	}

	g_iArcCount = count;
}

// 把 [lo, hi] 角度区间按 drawSegments 的密度拆成线段
void Arc(const float center[3], float lo, float hi, int drawSegments)
{
	if (hi - lo < 0.00001)
		return;

	float step = TAU_VALUE / float(drawSegments);
	int steps = RoundToCeil((hi - lo) / step);
	if (steps < 1)
		steps = 1;

	float p[3];
	float q[3];

	CirclePoint(center, lo, p);
	for (int k = 1; k <= steps; k++)
	{
		CirclePoint(center, lo + (hi - lo) * float(k) / float(steps), q);
		PendAdd(p, q);
		p = q;
	}
}

void CirclePoint(const float center[3], float angle, float out[3])
{
	out[0] = center[0] + g_fRadius * Cosine(angle);
	out[1] = center[1] + g_fRadius * Sine(angle);
	out[2] = center[2] + g_fLift;
}

void PendAdd(const float a[3], const float b[3])
{
	if (g_iPendCount >= g_iPendLimit)
	{
		g_bPendOverflow = true;
		return;
	}

	g_fPendStart[g_iPendCount] = a;
	g_fPendEnd[g_iPendCount] = b;
	g_iPendCount++;
}

// 浮点比值夹到 [-1, 1], 避免 acos 因误差返回 NaN
float ClampUnit(float value)
{
	if (value > 1.0)
		return 1.0;
	if (value < -1.0)
		return -1.0;
	return value;
}

// ---------------------------------------------------------------------------
// 发送光束
// ---------------------------------------------------------------------------

void DrawBeams()
{
	if (g_iPendCount <= 0)
	{
		g_iChunkCursor = 0;
		g_iLastSent = 0;
		g_iLastChunks = 0;
		return;
	}

	// 单帧临时实体上限(引擎限制), 留 2 个额度给其它插件
	int budget = TempEntBudget();

	int chunks = (g_iPendCount + budget - 1) / budget;
	if (chunks < 1)
		chunks = 1;
	if (chunks > MAX_CHUNKS)
		chunks = MAX_CHUNKS;

	int perTick = (g_iPendCount + chunks - 1) / chunks;
	if (perTick > budget)
		perTick = budget;
	if (perTick < 1)
		perTick = 1;

	// 寿命覆盖整个轮转周期, 保证轮到下一批时这一批还没消失
	float life = g_fInterval * float(chunks) + 0.05;

	for (int k = 0; k < perTick; k++)
	{
		int index = g_iChunkCursor + k;
		if (index >= g_iPendCount)
			index -= g_iPendCount;

		TE_SetupBeamPoints(g_fPendStart[index], g_fPendEnd[index], g_iBeamModel, 0, 0, 0, life,
			g_fBeamWidth, g_fBeamWidth, 0, 0.0, g_iBeamColor, 0);
		TE_SendToAll();
	}

	g_iChunkCursor += perTick;
	if (g_iChunkCursor >= g_iPendCount)
		g_iChunkCursor -= g_iPendCount;

	g_iLastSent = perTick;
	g_iLastChunks = chunks;
}

void Limit()
{
	if (!g_bLimited)
		PrintToServer("[AcidViz] Beam budget exceeded; hiding ALL lines (调低 sm_acidviz_segments, 或调高 sm_acidviz_max_beams / sv_multiplayer_maxtempentities 可恢复)");

	g_bLimited = true;
	g_iLastSent = 0;
}

// 单帧可发送的临时实体数: 受引擎 ConVar sv_multiplayer_maxtempentities 限制(默认 32),
// 超出部分会被引擎直接丢弃, 因此留 2 个额度给其它插件。
// cvar 值异常时(<3, 含 0/被其它插件改坏)按默认值处理, 避免预算塌成 1 导致整轮隐藏。
int TempEntBudget()
{
	int limit = DEFAULT_TEMPENTS;
	if (g_cvMaxTempEnts != null && g_cvMaxTempEnts.IntValue >= 3)
		limit = g_cvMaxTempEnts.IntValue;

	int budget = limit - 2;
	if (budget < 1)
		budget = 1;

	return budget;
}

// ---------------------------------------------------------------------------
// 杂项
// ---------------------------------------------------------------------------

void PrecacheBeamModel()
{
	char model[PLATFORM_MAX_PATH];
	g_cvModel.GetString(model, sizeof(model));
	TrimString(model);

	if (model[0] == '\0')
		strcopy(model, sizeof(model), BEAM_DEFAULT_MODEL);

	g_iBeamModel = PrecacheModel(model, true);
	if (g_iBeamModel <= 0)
		LogError("[AcidViz] 光束材质预缓存失败: %s", model);
}

// 解析 "R G B" 颜色, 失败时保留旧值(log 提示)
bool ParseColor(const char[] value, bool logError)
{
	char parts[3][8];
	int num = ExplodeString(value, " ", parts, sizeof(parts), sizeof(parts[]));

	if (num != 3)
	{
		if (logError)
			LogError("[AcidViz] sm_acidviz_color \"%s\" 无效, 需为 \"R G B\" (0-255), 已保留旧值", value);
		return false;
	}

	for (int i = 0; i < 3; i++)
	{
		int component = StringToInt(parts[i]);
		if (component < 0)
			component = 0;
		if (component > 255)
			component = 255;
		g_iBeamColor[i] = component;
	}
	g_iBeamColor[3] = 255;

	return true;
}

// 只读诊断: 打印当前所有口水池的节点几何 + 合并门槛统计
// 用来回答"为什么画出来是多个独立圆圈, 而不是一个由圆弧拼成的合并范围"
public Action Cmd_AcidDump(int client, int args)
{
	float radius = g_cvRadius.FloatValue;
	float mergeZ = g_cvMergeZ.FloatValue;
	float twoR = 2.0 * radius;

	static float dumpNodes[MAX_NODES][3];		// 全场节点(与绘图逻辑一致: 跨池一起合并)
	int total = 0;
	int pools = 0;
	int overflow = 0;

	int entity = -1;
	while ((entity = FindEntityByClassname(entity, ACID_CLASSNAME)) != -1)
	{
		if (!IsValidEntity(entity))
			continue;

		int count = GetEntProp(entity, Prop_Send, "m_fireCount");
		if (count <= 0)
			continue;

		pools++;

		float origin[3];
		GetEntPropVector(entity, Prop_Send, "m_vecOrigin", origin);
		ReplyToCommand(client, "[AcidViz] pool#%d ent=%d count=%d origin=(%.1f %.1f %.1f)",
			pools, entity, count, origin[0], origin[1], origin[2]);

		for (int i = 0; i < count; i++)
		{
			float node[3];
			node[0] = origin[0] + float(GetEntProp(entity, Prop_Send, "m_fireXDelta", _, i));
			node[1] = origin[1] + float(GetEntProp(entity, Prop_Send, "m_fireYDelta", _, i));
			node[2] = origin[2] + float(GetEntProp(entity, Prop_Send, "m_fireZDelta", _, i));

			ReplyToCommand(client, "[AcidViz]   n%-3d rel=(%6.0f %6.0f %6.0f) world=(%.1f %.1f %.1f)",
				i, node[0] - origin[0], node[1] - origin[1], node[2] - origin[2],
				node[0], node[1], node[2]);

			if (total < MAX_NODES)
			{
				dumpNodes[total] = node;
				total++;
			}
			else
			{
				overflow++;
			}
		}
	}

	if (pools == 0)
	{
		ReplyToCommand(client, "[AcidViz] 当前地图没有口水实体(insect_swarm 且 m_fireCount>0)");
		return Plugin_Handled;
	}

	// 按绘图算法的同一套门槛做统计(水平距离用世界坐标, 高度差用 z)
	int pairs = 0, dzPass = 0, distPass = 0, bothPass = 0, isolated = 0;
	float dzMin = 0.0, dzMax = 0.0, distMin = 0.0, distMax = 0.0;
	bool first = true;

	static int partners[MAX_NODES];
	for (int i = 0; i < total; i++)
		partners[i] = 0;

	for (int i = 0; i < total; i++)
	{
		for (int j = i + 1; j < total; j++)
		{
			pairs++;

			float dz = FloatAbs(dumpNodes[j][2] - dumpNodes[i][2]);
			float dx = dumpNodes[j][0] - dumpNodes[i][0];
			float dy = dumpNodes[j][1] - dumpNodes[i][1];
			float dist = SquareRoot(dx * dx + dy * dy);

			if (first)
			{
				dzMin = dzMax = dz;
				distMin = distMax = dist;
				first = false;
			}
			else
			{
				if (dz < dzMin) dzMin = dz;
				if (dz > dzMax) dzMax = dz;
				if (dist < distMin) distMin = dist;
				if (dist > distMax) distMax = dist;
			}

			bool okZ = (dz <= mergeZ);
			bool okD = (dist < twoR);
			if (okZ) dzPass++;
			if (okD) distPass++;
			if (okZ && okD)
			{
				bothPass++;
				partners[i]++;
				partners[j]++;
			}
		}
	}

	for (int i = 0; i < total; i++)
		if (partners[i] == 0)
			isolated++;

	ReplyToCommand(client, "[AcidViz] 参数 radius=%.1f (2R=%.1f) mergez=%.1f | 节点=%d 池=%d", radius, twoR, mergeZ, total, pools);
	ReplyToCommand(client, "[AcidViz] 组合=%d 通过高度闸=%d 通过距离闸=%d 两者都过(会合并)=%d 孤立节点(画整圆)=%d",
		pairs, dzPass, distPass, bothPass, isolated);
	ReplyToCommand(client, "[AcidViz] 实测 |dz| 范围=%.0f..%.0f ; 水平距离范围=%.1f..%.1f", dzMin, dzMax, distMin, distMax);

	for (int i = 0; i < total; i++)
	{
		if (partners[i] > 0)
			continue;

		int best = -1;
		float bestDist = 0.0;
		for (int j = 0; j < total; j++)
		{
			if (j == i)
				continue;

			float dx = dumpNodes[j][0] - dumpNodes[i][0];
			float dy = dumpNodes[j][1] - dumpNodes[i][1];
			float dist = SquareRoot(dx * dx + dy * dy);
			if (best < 0 || dist < bestDist)
			{
				best = j;
				bestDist = dist;
			}
		}

		if (best >= 0)
		{
			float dz = FloatAbs(dumpNodes[best][2] - dumpNodes[i][2]);
			ReplyToCommand(client, "[AcidViz]   n%d 画整圆 <- 最近邻 n%d: 水平=%.1f (%s 2R=%.1f), |dz|=%.0f (%s mergez=%.1f)",
				i, best, bestDist, bestDist >= twoR ? ">=" : "<", twoR, dz, dz > mergeZ ? ">" : "<=", mergeZ);
		}
	}

	if (overflow > 0)
		ReplyToCommand(client, "[AcidViz] 注意: 节点数超过 %d, 统计只覆盖前 %d 个", MAX_NODES, MAX_NODES);

	return Plugin_Handled;
}

public Action Cmd_AcidStatus(int client, int args)
{
	char status[512];
	FormatEx(status, sizeof(status),
		"[AcidViz %s] mode=%s enabled=%d pools=%d nodes=%d segments=%d draw_segments=%d sent_per_tick=%d chunks=%d limited=%d ticks=%d",
		PLUGIN_VERSION,
		g_cvMode.IntValue == 0 ? "outline" : "circles",
		g_bEnabled ? 1 : 0,
		g_iLastPools,
		g_iLastNodes,
		g_iLastSegments,
		g_iLastDrawSegments,
		g_iLastSent,
		g_iLastChunks,
		g_bLimited ? 1 : 0,
		g_iTicks);

	ReplyToCommand(client, "%s", status);
	ReplyToCommand(client, "[AcidViz] radius=%.1f UNVERIFIED(显示半径, 只影响绘图); lift=%.1f merge_z=%.1f interval=%.2f",
		g_cvRadius.FloatValue, g_cvLift.FloatValue, g_cvMergeZ.FloatValue, g_cvInterval.FloatValue);

	if (g_sFault[0] != '\0')
		ReplyToCommand(client, "[AcidViz] STOPPED: %s", g_sFault);

	return Plugin_Handled;
}
