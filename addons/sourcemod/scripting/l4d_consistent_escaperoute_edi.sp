#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "2.1-edi"
#define PLUGIN_TAG "l4d_consistent_escaperoute"

#include <sourcemod>
#include <dhooks>
#include <sourcescramble>
#include <sdktools>
#include <left4dhooks>

/*
 * ============================================================================
 *  本文件是 l4d_consistent_escaperoute.smx 的 _edi 修复版（编译产物 fixes/l4d_consistent_escaperoute_edi.smx），
 *  原版逻辑来自 Forgetest / SirPlease L4D2-Competitive-Rework 的 [L4D & 2] Consistent Escape Route v2.1。
 *
 *  ---------------------------- 要修的那条报错 ----------------------------
 *  [fixes/l4d_consistent_escaperoute.smx] Unexpected mismatching escape route. Please report to author.
 *
 *  这条不是引擎报错，是本插件自己 #if DEBUG 自检块里的 LogError()：
 *  它在本图第一次拿到逃跑路线时把 area id 列表存成基准，之后每次重建都拿来对比，不一致就 LogError。
 *  也就是说：看到这行 = 自检认为「两半的逃跑路线不一样」，或者 = 自检本身判断错了。
 *
 *  ---------------------------- 根因分析（两条） ----------------------------
 *  1) 起点补丁会「漏开」：DTR_GetPlayerSpawnPosition 在 pre 钩子里 Enable() 补丁，
 *     在 post 钩子里却要再判一次 g_bInComputeFlowDistances 才 Disable()。
 *     g_bInComputeFlowDistances 是 bool，不是计数器；一旦 ComputeFlowDistances 出现嵌套
 *     （内层 post 先把它清成 false），外层 GetPlayerSpawnPosition 的 post 就不会关补丁，
 *     skip_spawn_position_idx 从此常驻启用：之后所有 GetPlayerSpawnPosition 都被强制走
 *     索引 0，起始区域随之漂移 —— 这会造出**真实的**路线不一致（也就是自检没冤枉它）。
 *
 *  2) 自检的基准可能采在「本插件还没生效」的那次构建上：
 *     插件是比赛配置执行时用 sm plugins load 加载的（cfg/generalfixes.cfg），
 *     晚于地图最初那次 InitializeFlowDistances。若第一次采样正好落在这种构建上，
 *     基准就是原版随机路线，后面每回合都对不上 → 每回合刷一条 "Please report to author"。
 *     另外原自检只读一帧（RequestFrame 一次）、读失败就直接 return 且不重置标志，
 *     既可能与重建过程抢跑，也会把一次坏样本永久锁死成结论。
 *
 *  ---------------------------- 修复做法 ----------------------------
 *  1) 补丁开关严格配对：pre 里 Enable() 成功就记 g_bPatchApplied=true，
 *     post 里只要 g_bPatchApplied 就 Disable()，不再看 g_bInComputeFlowDistances；
 *     OnPluginEnd() 兜底再关一次，插件被 unload/reload 时不会把补丁留在服务器代码段里。
 *  2) ComputeFlowDistances 改成嵌套计数（g_iFlowDepth），内层不会提前清掉「正在算 flow」的状态，
 *     只有最外层返回时才排一次自检。
 *  3) 基准只认「本插件真的接管过」的构建：本次 flow 计算里 GetPlayerSpawnPosition /
 *     Checkpoint::GetSpawnPosition 至少命中过一次（g_bPatchedThisBuild），才允许存基准；
 *     否则跳过并只在 debug 开关打开时打一行说明 —— 晚加载不再污染基准。
 *  4) 自检改成「连续两帧读到同一份快照」才下结论，最多等 MAX_CHECK_FRAMES 帧；
 *     读不到实体 / 数量为 0 / 指针为空都只重试，不 latch、不误报。
 *  5) area 指针先判空再读，避免 LoadFromAddress(Address_Null) 抛 "Invalid address" 的另一类报错。
 *  6) OnMapStart / OnMapEnd 清空基准与全部状态，换图不会拿着上一张图的基准做对比。
 *  7) 真不一致时每张图只 LogError 一次，并带上「基准 N 个 / 当前 M 个 / 第 i 个区域 #x vs #y」，
 *     后续重复只走 LogMessage，不再刷 errors 日志。
 *  8) 新增 l4d_escaperoute_check / l4d_escaperoute_debug 两个 ConVar（默认 1 / 0），
 *     自检可整体关闭，排查时可打开逐帧日志。
 *
 *  ---------------------------- 明确不做的事 ----------------------------
 *  不在运行时用 CEscapeRoute::ResetPath/AddArea/FinishPath 强行重建路线。
 *  已逆向确认（Linux server_srv.so）：AddArea 内部就会 AddNode 并把 [this+0x3448] 指向该 area，
 *  FinishPath 又会把 [this+0x3448] 追加一次并再 AddNode —— 终点 area 天然重复一项。
 *  盲重建得到的节点数量与引擎自己建的不是同一形状，风险远大于「只报告」。
 *
 *  ============================================================================
 *  2026-11-23 追加（修「诊断输出被当成错误在刷屏」）
 *
 *  现象：errors_*.log 每张图刷一条
 *    [l4d_consistent_escaperoute] 逃跑路线与基准不一致（第 N 个区域不一致：基准 #A，当前 #B）
 *  c2m4_barns / c8m1_apartment / c5m2_park / c5m3_cemetery / c2m1_highway / c1m3_mall 等图反复出现，
 *  同一张图还会在「基准 #52590，当前 #38776」与「基准 #38776，当前 #52590」之间反转。
 *
 *  已确认的事实（先排除两个错误猜测）：
 *    1) 本插件的基准【只存在内存里】（ArrayList g_SavedRoute），没有任何 cfg/KeyValues/文件写入，
 *       OnMapStart/OnMapEnd 都会清空 —— 所以不存在「多服共享同一份缓存被互相覆盖」，
 *       仓库里也没有任何 escaperoute 的缓存文件。反转来自「同一张图存在两种合法路线形状」，
 *       而不是某一份缓存被写坏。
 *    2) 路线里的 area id 本身在同一台服务器同一次地图里是稳定的；跨服务器/跨 nav 版本
 *       （自定义 nav、stripper 改动区块、不同 area 编号）才会整体位移，所以 id 不能跨构建当
 *       稳定标识用 —— 但同一次会话内它仍是有效标识。
 *
 *  真正的误报机制：
 *    · 自检对「任何一次 flow 重建后的稳定路线」都做比较，包括【本插件没有接管的构建】。
 *      未接管的构建里 GetPlayerSpawnPosition 走引擎随机索引，起点区域漂移 →
 *      路线本来就该不一样。此时报「不一致」是拿「打过补丁的基准」去比「没打补丁的样本」，
 *      属于必然误报，也正是日志里值来回反转的原因（哪一次构建被采样成基准是随机的）。
 *    · 另外这块输出写在 errors 日志里，等于把诊断信息当错误上报。
 *
 *  本次修复（不改动任何补丁/起点固定逻辑，功能零变化）：
 *    A. 比较前先要求「本次构建也被本插件接管过」（g_bPatchedThisBuild），否则只写 debug，
 *       不再下结论 —— 误报条件从此不成立。
 *    B. 比较改用「稳定标识」：area id 相同即视为同一区域；id 不同时再看该 area 的中心坐标
 *       （量化到 CELL 单位后比对），相同则视为同一地点（nav 重编号/版本不同导致的 id 位移
 *       不再算不一致），只有「地点确实不同」才算真不一致。
 *    C. 新增 ConVar l4d_escaperoute_report：0 = 完全静默（只 debug）、
 *       1 = 每张图首次写一行普通日志（默认，不写 errors）、2 = 每张图首次写 error（旧行为）。
 *    D. 报告里带上地图名，方便按图反馈；同一张图仍然只报一次。
 *  ============================================================================
 */

enum struct SDKCallParamsWrapper {
	SDKType type;
	SDKPassMethod pass;
	int decflags;
	int encflags;
}

methodmap GameDataWrapper < GameData {
	public GameDataWrapper(const char[] file) {
		GameData gd = new GameData(file);
		if (!gd) SetFailState("Missing gamedata \"%s\"", file);
		return view_as<GameDataWrapper>(gd);
	}
	property GameData Super {
		public get() { return view_as<GameData>(this); }
	}
	public int GetOffset(const char[] key) {
		int offset = this.Super.GetOffset(key);
		if (offset == -1) SetFailState("Missing offset \"%s\"", key);
		return offset;
	}
	public Address GetAddress(const char[] key) {
		Address ptr = this.Super.GetAddress(key);
		if (ptr == Address_Null) SetFailState("Missing address \"%s\"", key);
		return ptr;
	}
	public MemoryPatch CreatePatchOrFail(const char[] name, bool enable = false) {
		MemoryPatch hPatch = MemoryPatch.CreateFromConf(this, name);
		if (!(enable ? hPatch.Enable() : hPatch.Validate()))
			SetFailState("Failed to patch \"%s\"", name);
		return hPatch;
	}
	public DynamicDetour CreateDetourOrFail(
			const char[] name,
			DHookCallback preHook = INVALID_FUNCTION,
			DHookCallback postHook = INVALID_FUNCTION) {
		DynamicDetour hSetup = DynamicDetour.FromConf(this, name);
		if (!hSetup)
			SetFailState("Missing detour setup \"%s\"", name);
		if (preHook != INVALID_FUNCTION && !hSetup.Enable(Hook_Pre, preHook))
			SetFailState("Failed to pre-detour \"%s\"", name);
		if (postHook != INVALID_FUNCTION && !hSetup.Enable(Hook_Post, postHook))
			SetFailState("Failed to post-detour \"%s\"", name);
		return hSetup;
	}
	public Handle CreateSDKCallOrFail(
			SDKCallType type,
			SDKFuncConfSource src,
			const char[] name,
			const SDKCallParamsWrapper[] params = {},
			int numParams = 0,
			bool hasReturnValue = false,
			const SDKCallParamsWrapper ret = {}) {
		static const char k_sSDKFuncConfSource[SDKFuncConfSource][] = { "offset", "signature", "address" };
		Handle result;
		StartPrepSDKCall(type);
		if (!PrepSDKCall_SetFromConf(this, src, name))
			SetFailState("Missing %s \"%s\"", k_sSDKFuncConfSource[src], name);
		for (int i = 0; i < numParams; ++i)
			PrepSDKCall_AddParameter(params[i].type, params[i].pass, params[i].decflags, params[i].encflags);
		if (hasReturnValue)
			PrepSDKCall_SetReturnInfo(ret.type, ret.pass, ret.decflags, ret.encflags);
		if (!(result = EndPrepSDKCall()))
			SetFailState("Failed to prep sdkcall \"%s\"", name);
		return result;
	}
}

methodmap Address {}

#define MAX_ROUTE_AREAS   512   // CEscapeRoute 内部上限 0x1FF(511)，+1 给 FinishPath 的终点节点
#define MAX_CHECK_FRAMES  10    // 等路线稳定的最大帧数
#define CELL_SIZE         4.0   // area 中心的量化单位（导航网格 cell 的粗粒度），用于「同一地点」判定

int g_iOffs_m_nMainPathAreaCount;
int g_offs_m_id;

MemoryPatch g_patch_SkipSpawnPosIdx;
Handle g_call_Checkpoint_GetLargestArea;

ConVar g_cvCheck;
ConVar g_cvDebug;
ConVar g_cvReport;

int  g_iFlowDepth = 0;             // ComputeFlowDistances 嵌套深度
bool g_bInComputeFlowDistances = false;
bool g_bPatchedThisBuild = false;  // 本次 flow 计算里本插件是否真的接管过
bool g_bPatchApplied = false;      // 补丁当前是否处于启用状态（与 Enable/Disable 严格配对）

bool g_bBaselineValid = false;
bool g_bCheckActive = false;
bool g_bCheckQueued = false;
int  g_iCheckFrames = 0;
bool g_bReportedThisMap = false;
bool g_bPatchFailReported = false;  // 本图内「补丁启用失败」只报一次，避免每次 flow 都刷 errors
bool g_bDuplicateWarned = false;    // 原版残留只报一次

ArrayList g_SavedRoute;    // 基准 area id 列表（int）
ArrayList g_StableRoute;   // 本轮读到的快照
ArrayList g_PrevRoute;     // 上一帧读到的快照（用于稳定性判定）

// area 中心坐标（float[3]，已量化），与上面三个 id 列表一一对应。
// area id 会随 nav 版本/编号变化，中心坐标才是「同一个地点」的稳定标识。
ArrayList g_SavedCenter;
ArrayList g_StableCenter;
ArrayList g_PrevCenter;

char g_sBaselineMap[64];   // 基准所属地图名（防止跨图残留的基准参与比较）

public Plugin myinfo =
{
	name = "[L4D & 2] Consistent Escape Route (edi)",
	author = "apples1949",
	description = "True L4D. edi(原版 Forgetest): 修复 skip_spawn_position_idx 补丁泄漏与 DEBUG 自检误报 'Unexpected mismatching escape route'（见文件头）。",
	version = PLUGIN_VERSION,
	url = "https://github.com/Target5150/MoYu_Server_Stupid_Plugins"
};

public void OnPluginStart()
{
	GameDataWrapper gd = new GameDataWrapper("l4d_consistent_escaperoute");

	g_iOffs_m_nMainPathAreaCount = gd.GetOffset("CEscapeRoute::m_nMainPathAreaCount");
	g_offs_m_id = gd.GetOffset("CNavArea::m_id");

	g_patch_SkipSpawnPosIdx = gd.CreatePatchOrFail("skip_spawn_position_idx", false);

	SDKCallParamsWrapper params[] = {
		{ SDKType_PlainOldData, SDKPass_Plain },
	};
	g_call_Checkpoint_GetLargestArea = gd.CreateSDKCallOrFail(SDKCall_Raw, SDKConf_Signature, "Checkpoint::GetLargestArea", _, 0, true, params[0]);

	delete gd.CreateDetourOrFail("l4d_consistent_escaperoute::Checkpoint::GetSpawnPosition", _, DTR_Checkpoint_GetSpawnPosition_Post);
	delete gd.CreateDetourOrFail("l4d_consistent_escaperoute::GetPlayerSpawnPosition", DTR_GetPlayerSpawnPosition, DTR_GetPlayerSpawnPosition_Post);
	delete gd.CreateDetourOrFail("l4d_consistent_escaperoute::TerrorNavMesh::ComputeFlowDistances", DTR_ComputeFlowDistances, DTR_ComputeFlowDistances_Post);
	delete gd;

	g_cvCheck = CreateConVar("l4d_escaperoute_check", "1",
			"是否启用逃跑路线一致性自检。\n0 = 关闭（不比较、不报错）\n1 = 启用（默认，只比较本插件真正接管过的构建）",
			FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvDebug = CreateConVar("l4d_escaperoute_debug", "0",
			"是否输出逃跑路线自检的详细过程日志。\n0 = 只输出结论（默认）\n1 = 逐帧输出快照、等待与比较过程",
			FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvReport = CreateConVar("l4d_escaperoute_report", "1",
			"检测到逃跑路线不一致时怎么记。\n0 = 完全静默（只写 debug 日志）\n1 = 每张图首次写一行普通日志（默认，不写 errors）\n2 = 每张图首次写 error（旧行为）",
			FCVAR_NONE, true, 0.0, true, 2.0);

	g_SavedRoute = new ArrayList();
	g_StableRoute = new ArrayList();
	g_PrevRoute = new ArrayList();
	g_SavedCenter = new ArrayList(3);
	g_StableCenter = new ArrayList(3);
	g_PrevCenter = new ArrayList(3);

	ResetCheckState(false);

	// 先立刻查一次；再用 timer 查一次，防止原版插件比本插件晚加载时漏检
	WarnIfOriginalLoaded();
	CreateTimer(1.0, Timer_CheckDuplicate, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_CheckDuplicate(Handle timer)
{
	WarnIfOriginalLoaded();
	return Plugin_Stop;
}

// ----------------------------------------------------------------------------
//  原版插件残留检测
//  原版 l4d_consistent_escaperoute.smx 与本事発版挂的是同一组 DHook、同一份
//  gamedata，并且各自持有同一个 skip_spawn_position_idx 的 MemoryPatch。
//  两份同时在跑时：先 Enable() 的那份成功，另一份 Validation 失败；
//  但两边的 Disable() 都会把自己存下来的“原始字节”写回去 ——
//  真正的补丁状态被打乱，逃跑路线就会真的算出不同的 area 列表。
//  SourceScramble 的 MemoryPatch.Enable() 文档明确：内存已被打过补丁时返回 false，
//  所以只要本插件出现过“无法启用 skip_spawn_position_idx”，就说明还有第二份在跑。
// ----------------------------------------------------------------------------
void WarnIfOriginalLoaded()
{
	if (g_bDuplicateWarned)
		return;

	Handle iter = GetPluginIterator();
	while (MorePlugins(iter))
	{
		Handle pl = ReadPlugin(iter);
		char name[128];
		GetPluginInfo(pl, PlInfo_Name, name, sizeof(name));

		if (StrEqual(name, "[L4D & 2] Consistent Escape Route"))
		{
			LogError("[%s] 检测到原版插件【[L4D & 2] Consistent Escape Route】仍在加载：两份插件会重复挂同一组 DHook 和同一个 skip_spawn_position_idx 补丁，后一份必然启用失败、逃跑路线会真的漂移。请删除或改名 plugins/fixes/l4d_consistent_escaperoute.smx（本仓库已改名为 .smx.off）后重启服务器。", PLUGIN_TAG);
			g_bDuplicateWarned = true;
			break;
		}
	}

	CloseHandle(iter);
}

public void OnPluginEnd()
{
	// 兜底：插件 unload/reload 时不能把代码补丁留在服务器里
	if (g_bPatchApplied) {
		g_patch_SkipSpawnPosIdx.Disable();
		g_bPatchApplied = false;
	}
}

public void OnMapStart()
{
	ResetCheckState(true);
}

public void OnMapEnd()
{
	ResetCheckState(true);
}

void ResetCheckState(bool clearBaseline)
{
	// 换图/卸载时补丁若还开着，先关掉，别把代码补丁带到下一张图
	if (g_bPatchApplied) {
		g_patch_SkipSpawnPosIdx.Disable();
		g_bPatchApplied = false;
	}

	g_iFlowDepth = 0;
	g_bInComputeFlowDistances = false;
	g_bPatchedThisBuild = false;
	g_bCheckActive = false;
	g_bCheckQueued = false;
	g_iCheckFrames = 0;
	g_bReportedThisMap = false;
	g_bPatchFailReported = false;

	if (g_StableRoute != null) g_StableRoute.Clear();
	if (g_PrevRoute != null) g_PrevRoute.Clear();
	if (g_StableCenter != null) g_StableCenter.Clear();
	if (g_PrevCenter != null) g_PrevCenter.Clear();

	if (clearBaseline) {
		g_bBaselineValid = false;
		if (g_SavedRoute != null) g_SavedRoute.Clear();
		if (g_SavedCenter != null) g_SavedCenter.Clear();
		g_sBaselineMap[0] = '\0';
	}
}

void DebugPrint(const char[] fmt, any...)
{
	if (!g_cvDebug.BoolValue)
		return;

	char buffer[256];
	VFormat(buffer, sizeof(buffer), fmt, 2);
	PrintToServer("[%s] %s", PLUGIN_TAG, buffer);
}

// ----------------------------------------------------------------------------
//  flow 计算窗口：用嵌套计数，只有最外层返回时才排自检
// ----------------------------------------------------------------------------
MRESReturn DTR_ComputeFlowDistances(DHookReturn hReturn)
{
	g_iFlowDepth++;
	g_bInComputeFlowDistances = true;

	if (g_iFlowDepth == 1)
		g_bPatchedThisBuild = false;

	return MRES_Ignored;
}

MRESReturn DTR_ComputeFlowDistances_Post(DHookReturn hReturn)
{
	if (g_iFlowDepth > 0)
		g_iFlowDepth--;

	g_bInComputeFlowDistances = (g_iFlowDepth > 0);

	if (g_iFlowDepth == 0) {
		DebugPrint("flow 计算结束（本插件接管过 = %s），下一帧开始自检", g_bPatchedThisBuild ? "是" : "否");
		StartRouteCheck();
	}

	return MRES_Ignored;
}

// ----------------------------------------------------------------------------
//  GetPlayerSpawnPosition：补丁开关严格配对（原版在这里泄漏）
// ----------------------------------------------------------------------------
MRESReturn DTR_GetPlayerSpawnPosition(DHookReturn hReturn, DHookParam hParams)
{
	if (!g_bInComputeFlowDistances)
		return MRES_Ignored;

	if (!g_bPatchApplied) {
		if (g_patch_SkipSpawnPosIdx.Enable()) {
			g_bPatchApplied = true;
		}
		else if (!g_bPatchFailReported) {
			g_bPatchFailReported = true;
			LogError("[%s] 无法启用 skip_spawn_position_idx 补丁：内存里已经是打过补丁的状态，通常说明另一份 escaperoute 插件（原版 l4d_consistent_escaperoute.smx）也在跑。本次 flow 计算不算作本插件接管，不采样基准、不参与一致性自检，避免误报。", PLUGIN_TAG);
		}
	}

	// 只有补丁真的由本插件持有，这次构建才算“本插件接管过”（否则基准会被污染）
	if (g_bPatchApplied)
		g_bPatchedThisBuild = true;

	return MRES_Ignored;
}

MRESReturn DTR_GetPlayerSpawnPosition_Post(DHookReturn hReturn, DHookParam hParams)
{
	// 注意：这里不再判 g_bInComputeFlowDistances —— pre 里开了就必须在这里关掉
	if (g_bPatchApplied) {
		g_patch_SkipSpawnPosIdx.Disable();
		g_bPatchApplied = false;
	}

	return MRES_Ignored;
}

// ----------------------------------------------------------------------------
//  Checkpoint::GetSpawnPosition：把起点固定成起始安全屋的最大区域
// ----------------------------------------------------------------------------
MRESReturn DTR_Checkpoint_GetSpawnPosition_Post(Address pThis, DHookReturn hReturn, DHookParam hParams)
{
	if (!g_bInComputeFlowDistances)
		return MRES_Ignored;

	// NOTE:
	//   GetSpawnPosition always computes a random position within start safe area.
	//   The following makes it always return the largest area instead.
	TerrorNavArea area = SDKCall(g_call_Checkpoint_GetLargestArea, pThis);
	if (area == Address_Null)
		return MRES_Ignored;

	g_bPatchedThisBuild = true;

	if (!hParams.IsNull(1)) {
		float pos[3];
		L4D_GetNavAreaCenter(area, pos);
		hParams.SetVector(1, pos);
	}

	if (!hParams.IsNull(2))
		hParams.SetVector(2, {0.0, 0.0, 0.0});

	if (!hParams.IsNull(3))
		hParams.SetObjectVar(3, 0, ObjectValueType_Int, area);

	DebugPrint("起点区域固定为 #%d", area.GetID());

	hReturn.Value = true;
	return MRES_ChangedOverride;
}

// ----------------------------------------------------------------------------
//  自检：连续两帧读到同一份快照才下结论
// ----------------------------------------------------------------------------
void StartRouteCheck()
{
	if (!g_cvCheck.BoolValue)
		return;

	g_bCheckActive = true;
	g_iCheckFrames = 0;
	g_PrevRoute.Clear();
	g_PrevCenter.Clear();

	QueueRouteCheck();
}

void QueueRouteCheck()
{
	if (g_bCheckQueued)
		return;

	g_bCheckQueued = true;
	RequestFrame(Frame_CheckRoute);
}

void Frame_CheckRoute()
{
	g_bCheckQueued = false;

	if (!g_bCheckActive)
		return;

	int entity = FindEntityByClassname(INVALID_ENT_REFERENCE, "escape_route");
	if (entity == INVALID_ENT_REFERENCE) {
		RetryRouteCheck("找不到 escape_route 实体");
		return;
	}

	if (!ReadRoute(entity, g_StableRoute, g_StableCenter)) {
		RetryRouteCheck("路线尚未就绪（数量为 0 或含空指针）");
		return;
	}

	if (!RoutesEqual(g_StableRoute, g_StableCenter, g_PrevRoute, g_PrevCenter)) {
		CopyRoute(g_StableRoute, g_StableCenter, g_PrevRoute, g_PrevCenter);
		RetryRouteCheck("路线仍在变化，等待稳定");
		return;
	}

	g_bCheckActive = false;
	DebugPrint("路线已稳定，共 %d 个区域", g_StableRoute.Length);
	HandleStableRoute();
}

void RetryRouteCheck(const char[] reason)
{
	if (++g_iCheckFrames >= MAX_CHECK_FRAMES) {
		g_bCheckActive = false;
		DebugPrint("%s，等待 %d 帧后放弃本轮检查", reason, MAX_CHECK_FRAMES);
		return;
	}

	DebugPrint("%s（第 %d/%d 帧）", reason, g_iCheckFrames, MAX_CHECK_FRAMES);
	QueueRouteCheck();
}

void HandleStableRoute()
{
	if (!g_bBaselineValid) {
		if (!g_bPatchedThisBuild) {
			// 这次构建没经过本插件的起点固定，拿它当基准只会制造误报
			DebugPrint("本轮 flow 计算未经本插件接管，跳过基准采样");
			return;
		}

		CopyRoute(g_StableRoute, g_StableCenter, g_SavedRoute, g_SavedCenter);
		g_bBaselineValid = true;
		GetCurrentMap(g_sBaselineMap, sizeof(g_sBaselineMap));
		LogMessage("[%s] 记录逃跑路线基准：地图 %s，%d 个区域", PLUGIN_TAG, g_sBaselineMap, g_SavedRoute.Length);
		return;
	}

	// 【2026-11-23 修复】只比较「本插件接管过」的构建。
	// 未接管的构建里起点是引擎随机选择的，路线本来就该和打过补丁的基准不同；
	// 以前无条件比较，等于把「随机」当成「不一致」上报 —— 这就是 errors 日志里那条反复出现、
	// 且同一张图会在两个值之间来回反转的自检输出。
	if (!g_bPatchedThisBuild) {
		DebugPrint("本轮 flow 计算未经本插件接管，跳过一致性比较（不产生结论）");
		return;
	}

	// 基准必须是同一张图的（OnMapStart 已经清过一次，这里再兜一层）
	char sMap[64];
	GetCurrentMap(sMap, sizeof(sMap));
	if (g_sBaselineMap[0] != '\0' && !StrEqual(sMap, g_sBaselineMap)) {
		DebugPrint("基准属于地图 %s，当前地图 %s，改为重新采样基准", g_sBaselineMap, sMap);
		g_bBaselineValid = false;
		g_SavedRoute.Clear();
		g_SavedCenter.Clear();
		HandleStableRoute();
		return;
	}

	if (RoutesEqual(g_StableRoute, g_StableCenter, g_SavedRoute, g_SavedCenter)) {
		DebugPrint("逃跑路线与基准一致");
		return;
	}

	ReportMismatch();
}

void ReportMismatch()
{
	int savedCount = g_SavedRoute.Length;
	int nowCount = g_StableRoute.Length;
	int diffIndex = -1;

	for (int i = 0, size = (savedCount < nowCount ? savedCount : nowCount); i < size; ++i) {
		if (!RouteEntrySame(i, g_SavedRoute, g_SavedCenter, g_StableRoute, g_StableCenter)) {
			diffIndex = i;
			break;
		}
	}

	char sMap[64];
	GetCurrentMap(sMap, sizeof(sMap));

	char detail[224];
	if (diffIndex >= 0) {
		FormatEx(detail, sizeof(detail), "地图 %s 第 %d 个区域不一致：基准 #%d，当前 #%d",
				sMap, diffIndex + 1, g_SavedRoute.Get(diffIndex), g_StableRoute.Get(diffIndex));
	} else if (savedCount != nowCount) {
		FormatEx(detail, sizeof(detail), "地图 %s 区域数量不一致：基准 %d 个，当前 %d 个",
				sMap, savedCount, nowCount);
	} else {
		FormatEx(detail, sizeof(detail), "地图 %s 区域数量与内容均未发现差异", sMap);
	}

	// 同一张图只出一次结论：默认写普通日志（logs/*.log），不再写 errors_*.log。
	// 想在 errors 里看到旧的报错形式，把 l4d_escaperoute_report 设成 2。
	int level = g_cvReport.IntValue;
	if (level <= 0) {
		DebugPrint("逃跑路线与基准不一致（%s）", detail);
		return;
	}

	if (!g_bReportedThisMap) {
		g_bReportedThisMap = true;
		if (level >= 2) {
			LogError("[%s] 逃跑路线与基准不一致（%s）。若本条只出现一次可忽略；反复出现请记录地图名后反馈作者。",
					PLUGIN_TAG, detail);
		} else {
			LogMessage("[%s] 逃跑路线与基准不一致（%s）。这是诊断信息，不影响服务器运行；如反复出现请记录地图名后反馈作者。",
					PLUGIN_TAG, detail);
		}
	} else {
		DebugPrint("逃跑路线仍与基准不一致（%s）", detail);
	}
}

// ----------------------------------------------------------------------------
//  快照读取（全部空指针/越界防护）
//  同时记录每个 area 的量化中心坐标：area id 会随 nav 版本/编号变化，
//  中心坐标才是「同一个地点」的稳定标识（用于跨构建比较）。
// ----------------------------------------------------------------------------
bool ReadRoute(int entity, ArrayList ids, ArrayList centers)
{
	ids.Clear();
	if (centers != null)
		centers.Clear();

	Address pRoute = GetEntityAddress(entity);
	if (pRoute == Address_Null)
		return false;

	int count = LoadFromAddress(pRoute + view_as<Address>(g_iOffs_m_nMainPathAreaCount), NumberType_Int32);
	if (count <= 0 || count > MAX_ROUTE_AREAS)
		return false;

	Address pAreas = pRoute + view_as<Address>(g_iOffs_m_nMainPathAreaCount + 8);

	float center[3];

	for (int i = 0; i < count; ++i) {
		Address pArea = view_as<Address>(LoadFromAddress(pAreas + view_as<Address>(i * 4), NumberType_Int32));
		if (pArea == Address_Null)
			return false;

		int id = LoadFromAddress(pArea + view_as<Address>(g_offs_m_id), NumberType_Int32);
		if (id <= 0)
			return false;

		ids.Push(id);

		if (centers != null) {
			center[0] = 0.0;
			center[1] = 0.0;
			center[2] = 0.0;
			L4D_GetNavAreaCenter(pArea, center);
			for (int a = 0; a < 3; ++a)
				center[a] = float(RoundToNearest(center[a] / CELL_SIZE)) * CELL_SIZE;
			centers.PushArray(center, sizeof(center));
		}
	}

	return true;
}

// 单个位置是否「同一区域」：id 相同直接算；id 不同时看中心坐标是否落在同一量化格。
bool RouteEntrySame(int i, ArrayList aId, ArrayList aCenter, ArrayList bId, ArrayList bCenter)
{
	int idA = aId.Get(i);
	int idB = bId.Get(i);
	if (idA == idB)
		return true;

	if (aCenter == null || bCenter == null || i >= aCenter.Length || i >= bCenter.Length)
		return false;

	float ca[3], cb[3];
	aCenter.GetArray(i, ca, sizeof(ca));
	bCenter.GetArray(i, cb, sizeof(cb));

	// 量化后完全相同 = 同一地点（nav 重编号/area 版本差异不再误判）
	for (int k = 0; k < 3; ++k)
		if (ca[k] != cb[k])
			return false;

	return true;
}

bool RoutesEqual(ArrayList aId, ArrayList aCenter, ArrayList bId, ArrayList bCenter)
{
	if (aId.Length != bId.Length)
		return false;

	for (int i = 0, size = aId.Length; i < size; ++i)
		if (!RouteEntrySame(i, aId, aCenter, bId, bCenter))
			return false;

	return true;
}

void CopyRoute(ArrayList fromId, ArrayList fromCenter, ArrayList toId, ArrayList toCenter)
{
	toId.Clear();
	for (int i = 0, size = fromId.Length; i < size; ++i)
		toId.Push(fromId.Get(i));

	if (toCenter == null)
		return;

	toCenter.Clear();
	if (fromCenter == null)
		return;

	float c[3];
	for (int i = 0, size = fromCenter.Length; i < size; ++i) {
		fromCenter.GetArray(i, c, sizeof(c));
		toCenter.PushArray(c, sizeof(c));
	}
}

methodmap TerrorNavArea < Address
{
	public int GetID() {
		return LoadFromAddress(this + view_as<Address>(g_offs_m_id), NumberType_Int32);
	}
}
