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
 * ============================================================================
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

int g_iOffs_m_nMainPathAreaCount;
int g_offs_m_id;

MemoryPatch g_patch_SkipSpawnPosIdx;
Handle g_call_Checkpoint_GetLargestArea;

ConVar g_cvCheck;
ConVar g_cvDebug;

int  g_iFlowDepth = 0;             // ComputeFlowDistances 嵌套深度
bool g_bInComputeFlowDistances = false;
bool g_bPatchedThisBuild = false;  // 本次 flow 计算里本插件是否真的接管过
bool g_bPatchApplied = false;      // 补丁当前是否处于启用状态（与 Enable/Disable 严格配对）

bool g_bBaselineValid = false;
bool g_bCheckActive = false;
bool g_bCheckQueued = false;
int  g_iCheckFrames = 0;
bool g_bReportedThisMap = false;

ArrayList g_SavedRoute;    // 基准 area id 列表（int）
ArrayList g_StableRoute;   // 本轮读到的快照
ArrayList g_PrevRoute;     // 上一帧读到的快照（用于稳定性判定）

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
			"是否启用逃跑路线一致性自检。\n0 = 关闭（不比较、不报错）\n1 = 启用（默认，怀疑路线不一致时会写一条错误日志）",
			FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvDebug = CreateConVar("l4d_escaperoute_debug", "0",
			"是否输出逃跑路线自检的详细过程日志。\n0 = 只输出结论（默认）\n1 = 逐帧输出快照、等待与比较过程",
			FCVAR_NONE, true, 0.0, true, 1.0);

	g_SavedRoute = new ArrayList();
	g_StableRoute = new ArrayList();
	g_PrevRoute = new ArrayList();

	ResetCheckState(false);
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

	if (g_StableRoute != null) g_StableRoute.Clear();
	if (g_PrevRoute != null) g_PrevRoute.Clear();

	if (clearBaseline) {
		g_bBaselineValid = false;
		if (g_SavedRoute != null) g_SavedRoute.Clear();
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

	g_bPatchedThisBuild = true;

	if (!g_bPatchApplied) {
		if (g_patch_SkipSpawnPosIdx.Enable())
			g_bPatchApplied = true;
		else
			LogError("[%s] 无法启用 skip_spawn_position_idx 补丁，本次 flow 计算的出生点索引不会被固定", PLUGIN_TAG);
	}

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

	if (!ReadRoute(entity, g_StableRoute)) {
		RetryRouteCheck("路线尚未就绪（数量为 0 或含空指针）");
		return;
	}

	if (!RoutesEqual(g_StableRoute, g_PrevRoute)) {
		CopyRoute(g_StableRoute, g_PrevRoute);
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

		CopyRoute(g_StableRoute, g_SavedRoute);
		g_bBaselineValid = true;
		LogMessage("[%s] 记录逃跑路线基准：%d 个区域", PLUGIN_TAG, g_SavedRoute.Length);
		return;
	}

	if (RoutesEqual(g_StableRoute, g_SavedRoute)) {
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
		if (g_SavedRoute.Get(i) != g_StableRoute.Get(i)) {
			diffIndex = i;
			break;
		}
	}

	char detail[192];
	if (diffIndex >= 0) {
		FormatEx(detail, sizeof(detail), "第 %d 个区域不一致：基准 #%d，当前 #%d",
				diffIndex + 1, g_SavedRoute.Get(diffIndex), g_StableRoute.Get(diffIndex));
	} else if (savedCount != nowCount) {
		FormatEx(detail, sizeof(detail), "区域数量不一致：基准 %d 个，当前 %d 个", savedCount, nowCount);
	} else {
		FormatEx(detail, sizeof(detail), "区域数量与内容均未发现差异");
	}

	// 真不一致：每张图只报一次错误，避免刷 errors 日志；后续重复走普通日志
	if (!g_bReportedThisMap) {
		g_bReportedThisMap = true;
		LogError("[%s] 逃跑路线与基准不一致（%s）。若本条只出现一次可忽略；反复出现请记录地图名后反馈作者。",
				PLUGIN_TAG, detail);
	} else {
		LogMessage("[%s] 逃跑路线仍与基准不一致（%s）", PLUGIN_TAG, detail);
	}
}

// ----------------------------------------------------------------------------
//  快照读取（全部空指针/越界防护）
// ----------------------------------------------------------------------------
bool ReadRoute(int entity, ArrayList out)
{
	out.Clear();

	Address pRoute = GetEntityAddress(entity);
	if (pRoute == Address_Null)
		return false;

	int count = LoadFromAddress(pRoute + view_as<Address>(g_iOffs_m_nMainPathAreaCount), NumberType_Int32);
	if (count <= 0 || count > MAX_ROUTE_AREAS)
		return false;

	Address pAreas = pRoute + view_as<Address>(g_iOffs_m_nMainPathAreaCount + 8);

	for (int i = 0; i < count; ++i) {
		Address pArea = view_as<Address>(LoadFromAddress(pAreas + view_as<Address>(i * 4), NumberType_Int32));
		if (pArea == Address_Null)
			return false;

		int id = LoadFromAddress(pArea + view_as<Address>(g_offs_m_id), NumberType_Int32);
		if (id <= 0)
			return false;

		out.Push(id);
	}

	return true;
}

bool RoutesEqual(ArrayList a, ArrayList b)
{
	if (a.Length != b.Length)
		return false;

	for (int i = 0, size = a.Length; i < size; ++i) {
		if (a.Get(i) != b.Get(i))
			return false;
	}

	return true;
}

void CopyRoute(ArrayList from, ArrayList to)
{
	to.Clear();
	for (int i = 0, size = from.Length; i < size; ++i)
		to.Push(from.Get(i));
}

methodmap TerrorNavArea < Address
{
	public int GetID() {
		return LoadFromAddress(this + view_as<Address>(g_offs_m_id), NumberType_Int32);
	}
}
