/*
 * =============================================================================
 * l4d2_survivor_route_points_12v12.sp
 * 生还者实时路程 / 路程分统计（applemod12v12）
 * =============================================================================
 *
 * 背景：cfg/cfgogl/applemod12v12/applemod12v12.cfg 里这四条 cvar 以前没有任何
 *       插件注册（全仓 grep 无 CreateConVar），一直是死的：
 *         applemod12v12_distance_score_enable
 *         applemod12v12_distance_score_base_teamsize
 *         applemod12v12_distance_score_map_key
 *         applemod12v12_distance_score_debug
 *       本插件把这四条按原名字注册出来，既有 cfg 立刻生效（不改任何 cfg）。
 *
 * 本插件只做三件事：**统计 + 展示 + 算分**。
 *   - 每 0.5 秒采样每个生还者（团队 2，真人与 bot 都算）的 flow 与 3D 实际行走路程；
 *   - 用"个人最大 flow / 全图最大 flow × 每人满额"算出预估路程分；
 *   - 通过 sm_route / 回合结算日志 / 可选 HUD 把数据展示出来。
 *
 * 与 l4d2_multibody_score.smx 的边界（重要）：
 *   multibody_score 负责"写分"（DHook 接管完成度、写 GameRules
 *   m_iVersusDistancePerSurvivor、结算队伍分）。本插件**只读不写**：
 *   不调用任何会改分数的 native（无 GameRules_SetProp / SetEntProp /
 *   L4D_SetVersusDistance 之类），不 Hook 任何计分函数。
 *   因此两者同时运行不会互相覆盖；本插件的数值只是"预估"，最终入账以
 *   multibody_score 为准。
 *
 * 数据来源与兜底链（逐级降级，任何一级不可用都不会崩）：
 *   1) flow 距离：L4D2Direct_GetFlowDistance(client)                ← 首选
 *                  若该 native 不可用或长期返回 0：L4D2_GetVersusCompletionPlayer(client)
 *                  （它虽有 "0-100" 的文档说法，实际是引擎 CTerrorGameRules::
 *                    GetVersusCompletion 的原始刻度，满额 ≈ vs_max_completion_score/4，
 *                    见 l4d2_multibody_score_policy.inc 的 G14_RawRouteCap；
 *                    本插件按满额刻度归一化后再换算成 flow 单位，
 *                    保证同一回合内所有样本单位一致；换图/换回合重新探测）。
 *                  注意：multibody_score 用 DHook 接管了同一个引擎函数，兜底路径读到
 *                  的值可能已被它改写（比例会被钳到 100%）；首选路径不受影响。
 *   2) 全图最大 flow：L4D2Direct_GetMapMaxFlowDistance()             ← 首选
 *                  不可用或返回 0：本回合观测到的最大 flow（兜底，见
 *                  g_fObservedMaxFlow；此时最远的人必然是 100%）。
 *   3) 基础分：mapinfo.txt[当前地图][map_key]（l4d2lib 的 L4D2_GetMapValueFloat）
 *                  读不到（l4d2lib 未加载 / 地图没这个键）：引擎 cvar
 *                  vs_max_completion_score（再用 L4D_GetVersusMaxCompletionScore 兜底）。
 *
 * 路程分口径（与 l4d2_multibody_score 的 G14_BodyRouteCap 完全一致）：
 *   服务器既有约定（见 include/l4d2_multibody_score_policy.inc）：
 *       mapinfo.txt[地图]["max_distance"] = **4 人制的基础分**（记为 M）
 *       一个生还者的满额路程分         = M / base_teamsize（默认 M / 4）
 *       队伍满额合计                   = 每人满额 × 实际生还者数
 *   所以：
 *       个人路程分 = round(个人最大 flow / 全图最大 flow × (M / base_teamsize))
 *   当 base_teamsize（默认 4）与实际生还者数不同时**不做隐式归一化**，而是
 *   按比例折算口径：队伍满额合计 = M × 实际人数 / base_teamsize
 *   （12 人 + M=400 时 = 400 × 12 / 4 = 1200，与 multibody_score 的队伍总分刻度相同）。
 *   这个折算倍数会在日志里打印（见 LogScaleNote），避免口径含糊。
 *   若线上希望"队伍总分恒等于 M"，把除数从 base_teamsize 换成实际人数即可
 *   （单行改动，函数 FullSharePerSurvivor）。
 *
 * 作者主张：不做 AutoExecConfig —— 参数由 confogl 的 confogl_addcvar 下发。
 *
 * =============================================================================
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

// l4d2lib 是可选依赖：未加载时读不到 mapinfo -> 自动降级到引擎分数。
// 不定义 REQUIRE_PLUGIN，让 l4d2lib.inc 自己把那组 native 标成 optional。
#include <l4d2lib>

#define ROUTE_PLUGIN_VERSION    "1.0.0"

#define ROUTE_SAMPLE_PERIOD     0.5     // 采样周期（秒）
#define ROUTE_TELEPORT_JUMP     500.0   // 单帧 3D 位移超过这个值视为传送，丢弃该帧
#define ROUTE_TEAM_SURVIVOR     2       // 生还者队伍编号
#define ROUTE_KEY_FALLBACK      "max_distance"

// flow 采样来源（每张图锁定一次，保证同回合内单位一致）
enum RouteFlowSource
{
    RouteFlow_None = 0,   // 还没探测出结果（继续探测）
    RouteFlow_Direct,     // L4D2Direct_GetFlowDistance（flow 单位）
    RouteFlow_Percent     // L4D2_GetVersusCompletionPlayer（引擎刻度 -> 换算成 flow）
};

//-------------------------------------------------------------------------
// cvar（前四条与 cfg 里既有名字一字不差）
//-------------------------------------------------------------------------
ConVar g_hEnable;                       // applemod12v12_distance_score_enable
ConVar g_hBaseTeamSize;                 // applemod12v12_distance_score_base_teamsize
ConVar g_hMapKey;                       // applemod12v12_distance_score_map_key
ConVar g_hDebug;                        // applemod12v12_distance_score_debug
ConVar g_hHud;                          // applemod12v12_distance_score_hud（默认 0=关闭）
ConVar g_hEngineMaxBase;                // 引擎 vs_max_completion_score（兜底基础分）

//-------------------------------------------------------------------------
// 依赖 native 的可用性（OnPluginStart / OnMapStart 各探测一次）
//-------------------------------------------------------------------------
bool g_bFlowNative;          // L4D2Direct_GetFlowDistance
bool g_bNavMaxNative;        // L4D2Direct_GetMapMaxFlowDistance
bool g_bCompletionNative;    // L4D2_GetVersusCompletionPlayer
bool g_bEngineMaxNative;     // L4D_GetVersusMaxCompletionScore
bool g_bMapValueNative;      // L4D2_GetMapValueFloat（l4d2lib）

RouteFlowSource g_iFlowSource = RouteFlow_None;

//-------------------------------------------------------------------------
// 每客户端缓存（HUD / 命令 / 结算都读这里）
//-------------------------------------------------------------------------
float g_fMaxFlow[MAXPLAYERS + 1];       // 本轮最大 flow（只增不减：退后不扣分）
float g_fWalked[MAXPLAYERS + 1];        // 本轮累计 3D 实际行走路程
float g_fLastPos[MAXPLAYERS + 1][3];    // 上一帧坐标（OnGameFrame 累加用）
bool  g_bLastPosValid[MAXPLAYERS + 1];
char  g_szNameSnapshot[MAXPLAYERS + 1][MAX_NAME_LENGTH];

//-------------------------------------------------------------------------
// 回合级状态
//-------------------------------------------------------------------------
float g_fMapMaxFlow;          // 全图最大 flow（引擎值或本回合观测兜底）
bool  g_bMapMaxFromEngine;    // 上面那个值是引擎给的还是观测兜底
float g_fObservedMaxFlow;     // 本回合观测到的最大 flow（兜底分母）
int   g_iBaseScore;           // 基础分 M（mapinfo 或引擎兜底）
bool  g_bBaseFromMapInfo;     // 基础分是否已经由 mapinfo 给出（给了就锁定，不再被引擎值覆盖）
int   g_iRoundSurvivorCount;  // 本回合生还者总数（人数口径分母，回合开始快照）

bool g_bInRound;
int  g_iSampleTick;

char g_szMapName[64];            // 当前地图名（日志用）
char g_szFlowSourceText[48];     // flow 来源文字（日志/命令用）
char g_szBaseSourceText[32];     // 基础分来源文字（mapinfo / 引擎）

public Plugin myinfo =
{
    name = "Survivor Route Points (12v12)",
    author = "apples1949",
    description = "实时统计每个生还者的路程(flow)与实际行走，展示并预估路程分（只读，不写引擎分数）",
    version = ROUTE_PLUGIN_VERSION,
    url = ""
};

//-------------------------------------------------------------------------
// 生命周期
//-------------------------------------------------------------------------
public void OnPluginStart()
{
    g_hEnable = CreateConVar("applemod12v12_distance_score_enable", "1",
        "1=启用车程(距离)统计与路程分展示；0=完全关闭采样与结算输出。",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_hBaseTeamSize = CreateConVar("applemod12v12_distance_score_base_teamsize", "4",
        "mapinfo.txt 里 max_distance 对应的人数基准（默认 4 人基础分）：每人满额 = 基础分 / 该值。",
        FCVAR_NOTIFY, true, 1.0, true, 32.0);
    g_hMapKey = CreateConVar("applemod12v12_distance_score_map_key", "max_distance",
        "从 mapinfo.txt 当前地图节点读取基础分用的键名（默认 max_distance）。",
        FCVAR_NOTIFY);
    g_hDebug = CreateConVar("applemod12v12_distance_score_debug", "0",
        "1=每秒把采样与结算写进服务器日志（排查用）。",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_hHud = CreateConVar("applemod12v12_distance_score_hud", "0",
        "1=给活着的真人玩家每 1 秒用 PrintHintText 显示自己的实时路程/百分比/预估分。",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);

    // 兜底基础分用的引擎 cvar（不创建，只查找；找不到再走 native）
    g_hEngineMaxBase = FindConVar("vs_max_completion_score");

    ProbeNatives();

    // 迟到加载时 OnMapStart 不会再触发，这里补一次地图名/来源文字
    GetCurrentMap(g_szMapName, sizeof(g_szMapName));
    strcopy(g_szFlowSourceText, sizeof(g_szFlowSourceText), "未探测");

    // 迟到加载（地图已经在跑）时 OnMapStart 不会再触发，用 l4d2lib 判断一次
    if (GetFeatureStatus(FeatureType_Native, "L4D2_CurrentlyInRound") == FeatureStatus_Available)
    {
        if (L4D2_CurrentlyInRound())
        {
            g_bInRound = true;
            LogMessage("[route] 插件在回合中途加载，立即开始采样。");
        }
    }

    RegConsoleCmd("sm_route", Cmd_Route, "查看每位生还者的实时路程与预估路程分。用法: sm_route | sm_route top");
    HookEvent("round_start",   Event_RoundStart,   EventHookMode_PostNoCopy);
    HookEvent("round_end",     Event_RoundEnd,     EventHookMode_PostNoCopy);
    HookEvent("map_transition", Event_MapTransition, EventHookMode_PostNoCopy);

    // 一个常驻的 0.5s 周期定时器：内部用 g_bInRound 判定，不随换图销毁
    // （不设 TIMER_FLAG_NO_MAPCHANGE，换图后自动继续用；OnMapStart 负责清状态）。
    // 句柄不需要保存：插件卸载时 SourceMod 自行回收插件拥有的 timer。
    CreateTimer(ROUTE_SAMPLE_PERIOD, Timer_Sample, _, TIMER_REPEAT);

    LogMessage("[route] 插件已加载 v%s：flow=%s navMax=%s vsPercent=%s mapinfo=%s engineMax=%s",
        ROUTE_PLUGIN_VERSION,
        g_bFlowNative ? "可用" : "不可用",
        g_bNavMaxNative ? "可用" : "不可用",
        g_bCompletionNative ? "可用" : "不可用",
        g_bMapValueNative ? "可用" : "不可用",
        g_bEngineMaxNative ? "可用" : "不可用");
}

public void OnMapStart()
{
    // 换图：清全部回合状态，重新探测依赖（l4d2lib 可能刚加载/刚卸载）
    ProbeNatives();
    if (g_hEngineMaxBase == null) g_hEngineMaxBase = FindConVar("vs_max_completion_score");

    GetCurrentMap(g_szMapName, sizeof(g_szMapName));
    strcopy(g_szFlowSourceText, sizeof(g_szFlowSourceText), "未探测");
    strcopy(g_szBaseSourceText, sizeof(g_szBaseSourceText), "未读到");

    g_iFlowSource = RouteFlow_None;
    g_fMapMaxFlow = 0.0;
    g_bMapMaxFromEngine = false;
    g_fObservedMaxFlow = 0.0;
    g_iBaseScore = 0;
    g_bBaseFromMapInfo = false;
    g_iRoundSurvivorCount = 0;
    g_bInRound = false;
    g_iSampleTick = 0;
    ClearAllClients();

    // 这里先试一次；mapinfo 有可能还没就绪，采样循环会持续重试到读到为止
    ResolveBaseScore();
}

public void OnClientDisconnect(int client)
{
    // 断线清缓存：重新进服的人（或 bot 接管）从零开始，不继承别人的路程
    ClearOneClient(client);
}

//-------------------------------------------------------------------------
// 事件
//-------------------------------------------------------------------------
public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    ClearAllClients();
    g_fObservedMaxFlow = 0.0;
    g_fMapMaxFlow = 0.0;
    g_bMapMaxFromEngine = false;
    g_iFlowSource = RouteFlow_None;   // 新回合重新探测，保证单位一致
    strcopy(g_szFlowSourceText, sizeof(g_szFlowSourceText), "未探测");
    g_iRoundSurvivorCount = 0;        // 首个采样 tick 里快照
    g_iSampleTick = 0;
    g_bInRound = true;

    if (g_hDebug.BoolValue)
        LogMessage("[route] round_start：清空路程数据，开始采样。");
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    Settle("round_end");
}

public void Event_MapTransition(Event event, const char[] name, bool dontBroadcast)
{
    // 正常流程 round_end 已经结算过（g_bInRound 被置 false），这里只兜底
    Settle("map_transition");
}

//-------------------------------------------------------------------------
// 采样
//-------------------------------------------------------------------------
public Action Timer_Sample(Handle timer)
{
    if (!g_bInRound) return Plugin_Continue;
    if (!g_hEnable.BoolValue) return Plugin_Continue;

    // 基础分/地图最大 flow 可能晚到（mapinfo、navmesh 就绪时间不一致），每 tick 补一次
    ResolveBaseScore();
    ResolveMapMaxFlow();

    // 人数快照：回合开始时可能还没生成生还者，取第一次统计到的非零值
    if (g_iRoundSurvivorCount <= 0) g_iRoundSurvivorCount = CountSurvivors();

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsTrackable(i)) continue;

        float flow = SampleFlow(i);
        if (flow > g_fMaxFlow[i]) g_fMaxFlow[i] = flow;
        if (flow > g_fObservedMaxFlow) g_fObservedMaxFlow = flow;

        if (g_szNameSnapshot[i][0] == '\0')
            GetClientName(i, g_szNameSnapshot[i], MAX_NAME_LENGTH);
    }

    g_iSampleTick++;

    // HUD 1 秒刷新一次（0.5s × 2），并且只在开关打开时
    if (g_hHud.BoolValue && (g_iSampleTick % 2) == 0)
        UpdateHud();

    if (g_hDebug.BoolValue && (g_iSampleTick % 2) == 0)
        LogDebugSample();

    return Plugin_Continue;
}

// 每帧累加 3D 实际行走路程（传送/换图导致的大跳变直接丢弃，防止灌水）
public void OnGameFrame()
{
    if (!g_bInRound) return;
    if (!g_hEnable.BoolValue) return;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsTrackable(i)) continue;

        float pos[3];
        GetClientAbsOrigin(i, pos);

        if (g_bLastPosValid[i])
        {
            float moved = GetVectorDistance(pos, g_fLastPos[i]);
            if (moved <= ROUTE_TELEPORT_JUMP)
            {
                g_fWalked[i] += moved;
            }
            else if (g_hDebug.BoolValue)
            {
                LogMessage("[route] %N 单帧位移 %.0f > %.0f，判定为传送/换图，丢弃该帧。",
                    i, moved, ROUTE_TELEPORT_JUMP);
            }
        }

        g_fLastPos[i] = pos;
        g_bLastPosValid[i] = true;
    }
}

//-------------------------------------------------------------------------
// flow 采样
//-------------------------------------------------------------------------
float SampleFlow(int client)
{
    if (g_iFlowSource == RouteFlow_None)
    {
        // 第一次探测：优先 left4dhooks 的 flow native
        if (g_bFlowNative)
        {
            float flow = L4D2Direct_GetFlowDistance(client);
            if (flow > 0.0)
            {
                g_iFlowSource = RouteFlow_Direct;
                strcopy(g_szFlowSourceText, sizeof(g_szFlowSourceText), "L4D2Direct_GetFlowDistance");
                if (g_hDebug.BoolValue)
                    LogMessage("[route] flow 来源锁定为 L4D2Direct_GetFlowDistance。");
                return flow;
            }
        }
        // 再退一步：用引擎的完成度（原始刻度）换算成 flow 单位
        if (g_bCompletionNative)
        {
            int raw = L4D2_GetVersusCompletionPlayer(client);
            if (raw > 0)
            {
                g_iFlowSource = RouteFlow_Percent;
                strcopy(g_szFlowSourceText, sizeof(g_szFlowSourceText), "L4D2_GetVersusCompletionPlayer(引擎刻度)");
                if (g_hDebug.BoolValue)
                    LogMessage("[route] flow 来源锁定为 L4D2_GetVersusCompletionPlayer（满额刻度 %.0f，已换算成 flow）。",
                        CompletionFullScale());
                return CompletionToFlow(raw);
            }
        }
        // 都没给数（比如所有人都还在安全屋）：保持 None，下个 tick 再探测
        return 0.0;
    }

    if (g_iFlowSource == RouteFlow_Direct)
    {
        float flow = L4D2Direct_GetFlowDistance(client);
        return flow > 0.0 ? flow : 0.0;
    }

    if (g_iFlowSource == RouteFlow_Percent)
        return CompletionToFlow(L4D2_GetVersusCompletionPlayer(client));

    return 0.0;
}

// 百分比 -> flow 单位：让 flow/全图最大 flow 正好等于"完成度比例"
// 注意 L4D2_GetVersusCompletionPlayer 虽然文档写 0-100，实际返回的是
// CTerrorGameRules::GetVersusCompletion 的原始刻度（引擎 4 个生还者槽），
// 满额 ≈ vs_max_completion_score / 4（与 l4d2_multibody_score_policy.inc 的
// G14_RawRouteCap 口径一致）。所以这里按满额刻度归一化，而不是直接当百分比。
float CompletionFullScale()
{
    int engineMax = EngineBaseScore();
    if (engineMax > 0) return float(engineMax) / 4.0;
    return 100.0;   // 引擎值也读不到时才退回文档口径
}

float CompletionToFlow(int raw)
{
    if (raw <= 0) return 0.0;

    float full = CompletionFullScale();
    if (full <= 0.0) full = 100.0;

    // multibody_score 可能改写同一个引擎函数的返回值，比例可能 >1，压回 1
    float ratio = float(raw) / full;
    if (ratio > 1.0) ratio = 1.0;
    if (ratio < 0.0) ratio = 0.0;

    float scale = g_fMapMaxFlow > 0.0 ? g_fMapMaxFlow : 100.0;
    return ratio * scale;
}

// 全图最大 flow：引擎优先，读不到用本回合观测到的最大值兜底
void ResolveMapMaxFlow()
{
    if (g_bNavMaxNative)
    {
        float maxFlow = L4D2Direct_GetMapMaxFlowDistance();
        if (maxFlow > 0.0)
        {
            g_fMapMaxFlow = maxFlow;
            g_bMapMaxFromEngine = true;
            return;
        }
    }

    // 兜底：本回合观测到的最大 flow（此时最远的人必然 100%）
    g_fMapMaxFlow = g_fObservedMaxFlow;
    g_bMapMaxFromEngine = false;
}

//-------------------------------------------------------------------------
// 基础分
//-------------------------------------------------------------------------
void ResolveBaseScore()
{
    // mapinfo 已经给出过基础分 -> 本图锁定，不再被引擎值覆盖
    if (g_bBaseFromMapInfo && g_iBaseScore > 0) return;

    // l4d2lib 可能在本插件之后才加载，这里再探测一次
    ProbeL4D2Lib();

    char key[64];
    if (g_hMapKey != null) g_hMapKey.GetString(key, sizeof(key));
    if (key[0] == '\0') strcopy(key, sizeof(key), ROUTE_KEY_FALLBACK);

    if (g_bMapValueNative)
    {
        float value = L4D2_GetMapValueFloat(key, 0.0);
        if (value > 0.0)
        {
            int resolved = RoundToNearest(value);
            if (resolved != g_iBaseScore || !g_bBaseFromMapInfo)
            {
                g_iBaseScore = resolved;
                strcopy(g_szBaseSourceText, sizeof(g_szBaseSourceText), "mapinfo");
                LogMessage("[route] 基础分 %d 来自 mapinfo.txt[%s] 键 \"%s\"。",
                    g_iBaseScore, g_szMapName, key);
                LogScaleNote();
            }
            g_bBaseFromMapInfo = true;
            return;
        }
    }

    // 兜底：引擎的 vs_max_completion_score
    // 注意：这里**不锁定**结果——mapinfo 有可能在本插件之后才被 l4d2lib 读进来，
    // 下一 tick 还会再试 mapinfo，读到了就改用 mapinfo（上面会置 g_bBaseFromMapInfo）。
    int engineBase = EngineBaseScore();
    if (engineBase > 0 && engineBase != g_iBaseScore)
    {
        g_iBaseScore = engineBase;
        strcopy(g_szBaseSourceText, sizeof(g_szBaseSourceText), "vs_max_completion_score");
        LogMessage("[route] mapinfo 暂无键 \"%s\"（l4d2lib=%s），基础分暂用引擎 vs_max_completion_score=%d；读到 mapinfo 会自动替换。",
            key, g_bMapValueNative ? "已加载" : "未加载", engineBase);
        LogScaleNote();
    }
}

int EngineBaseScore()
{
    if (g_hEngineMaxBase == null)
        g_hEngineMaxBase = FindConVar("vs_max_completion_score");

    if (g_hEngineMaxBase != null)
    {
        int value = g_hEngineMaxBase.IntValue;
        if (value > 0) return value;
    }

    // 某些环境里 cvar 被临时清零（例如冻结计分），再用 native 兜一次
    if (g_bEngineMaxNative)
    {
        int value = L4D_GetVersusMaxCompletionScore();
        if (value > 0) return value;
    }

    return 0;
}

// 一个生还者的满额路程分 = 基础分 / base_teamsize（与 l4d2_multibody_score 的
// G14_BodyRouteCap 完全一致：mapinfo 的 max_distance 是 4 人制基础分，每人吃 1/4）
int FullSharePerSurvivor()
{
    if (g_iBaseScore <= 0) return 0;

    int teamSize = g_hBaseTeamSize != null ? g_hBaseTeamSize.IntValue : 4;
    if (teamSize < 1) teamSize = 4;

    return g_iBaseScore / teamSize;
}

// 队伍满额合计（口径说明用）：每人满额 × 本回合生还者数
int TeamMaxPoints()
{
    int perHead = FullSharePerSurvivor();
    if (perHead <= 0) return 0;

    int count = g_iRoundSurvivorCount > 0 ? g_iRoundSurvivorCount : CountSurvivors();
    return perHead * count;
}

// 把"基础分/人数"的折算口径写进日志，避免线上对不上账
void LogScaleNote()
{
    int teamSize = g_hBaseTeamSize != null ? g_hBaseTeamSize.IntValue : 4;
    if (teamSize < 1) teamSize = 4;

    int count = g_iRoundSurvivorCount > 0 ? g_iRoundSurvivorCount : CountSurvivors();
    int perHead = FullSharePerSurvivor();

    if (count <= 0)
    {
        LogMessage("[route] 口径：基础分 %d 为 %d 人制 -> 每人满额 %d。",
            g_iBaseScore, teamSize, perHead);
        return;
    }

    LogMessage("[route] 口径：基础分 %d 为 %d 人制 -> 每人满额 %d；本回合 %d 人 -> 队伍满额合计 %d (= 基础分 × %d / %d)。",
        g_iBaseScore, teamSize, perHead, count, perHead * count, count, teamSize);
}

//-------------------------------------------------------------------------
// 分数（只算不写）
//-------------------------------------------------------------------------
int EstimatePoints(int client)
{
    if (g_fMapMaxFlow <= 0.0) return 0;
    if (g_fMaxFlow[client] <= 0.0) return 0;

    int perHead = FullSharePerSurvivor();
    if (perHead <= 0) return 0;

    float ratio = g_fMaxFlow[client] / g_fMapMaxFlow;
    if (ratio > 1.0) ratio = 1.0;
    if (ratio < 0.0) ratio = 0.0;

    return RoundToNearest(ratio * float(perHead));
}

float EstimatePercent(int client)
{
    if (g_fMapMaxFlow <= 0.0) return 0.0;

    float ratio = g_fMaxFlow[client] / g_fMapMaxFlow * 100.0;
    if (ratio > 100.0) ratio = 100.0;
    if (ratio < 0.0) ratio = 0.0;
    return ratio;
}

//-------------------------------------------------------------------------
// 展示：sm_route / sm_route top
//-------------------------------------------------------------------------
public Action Cmd_Route(int client, int args)
{
    char arg[16];
    arg[0] = '\0';
    if (args > 0) GetCmdArg(1, arg, sizeof(arg));

    bool sorted = StrEqual(arg, "top", false);

    ReplyToCommand(client, "[路程] 基础分 %d (来源 %s, %d人制) | 每人满额 %d | 本回合 %d 人 | 队伍满额 %d",
        g_iBaseScore,
        g_szBaseSourceText,
        g_hBaseTeamSize != null ? g_hBaseTeamSize.IntValue : 4,
        FullSharePerSurvivor(),
        g_iRoundSurvivorCount,
        TeamMaxPoints());

    ReplyToCommand(client, "[路程] 全图最大 flow %.0f (%s) | flow 来源 %s",
        g_fMapMaxFlow,
        g_bMapMaxFromEngine ? "引擎" : "本回合观测兜底",
        g_szFlowSourceText);

    if (g_fMapMaxFlow <= 0.0)
    {
        ReplyToCommand(client, "[路程] 还没有可用数据：回合未开始，或 flow native 全部不可用。");
        return Plugin_Handled;
    }

    int list[MAXPLAYERS];
    int count = CollectRouteClients(list, sizeof(list));

    if (count <= 0)
    {
        ReplyToCommand(client, "[路程] 当前没有可统计的生还者（团队2）。");
        return Plugin_Handled;
    }

    if (sorted) SortByPointsDesc(list, count);

    for (int n = 0; n < count; n++)
    {
        int i = list[n];
        char name[MAX_NAME_LENGTH];
        GetNameSafe(i, name, sizeof(name));

        ReplyToCommand(client, "[路程] %d. %s%s | 最大路程 %.0f | %.1f%% | 累计行走 %.0f | 预估路程分 %d/%d",
            n + 1,
            name,
            IsPlayerAlive(i) ? "" : "(已亡)",
            g_fMaxFlow[i],
            EstimatePercent(i),
            g_fWalked[i],
            EstimatePoints(i),
            FullSharePerSurvivor());
    }

    return Plugin_Handled;
}

//-------------------------------------------------------------------------
// 结算
//-------------------------------------------------------------------------
void Settle(const char[] reason)
{
    if (!g_bInRound) return;
    g_bInRound = false;

    int list[MAXPLAYERS];
    int count = CollectRouteClients(list, sizeof(list));

    // 服务器日志：每人一行（无论 enable 与否都记，方便事后对账）
    LogMessage("[route] ===== 结算 (%s) 地图 %s | 基础分 %d | 每人满额 %d | 最大flow %.0f(%s) | flow源 %s =====",
        reason, g_szMapName, g_iBaseScore, FullSharePerSurvivor(), g_fMapMaxFlow,
        g_bMapMaxFromEngine ? "引擎" : "观测兜底", g_szFlowSourceText);

    int teamPoints = 0;
    int bestPoints = -1;

    if (g_fMapMaxFlow <= 0.0 || g_iBaseScore <= 0)
    {
        LogMessage("[route] 警告：%s，本回合无法给出路程分（最大flow=%.0f，基础分=%d）。",
            g_fMapMaxFlow <= 0.0 ? "全图最大 flow 不可用" : "基础分不可用",
            g_fMapMaxFlow, g_iBaseScore);
    }

    for (int n = 0; n < count; n++)
    {
        int i = list[n];
        char name[MAX_NAME_LENGTH];
        GetNameSafe(i, name, sizeof(name));

        int points = EstimatePoints(i);
        teamPoints += points;
        if (points > bestPoints) bestPoints = points;

        LogMessage("[route] %s (%d) | 最大flow %.0f | %.1f%% | 累计行走 %.0f | 预估路程分 %d/%d",
            name, GetClientUserId(i), g_fMaxFlow[i], EstimatePercent(i), g_fWalked[i],
            points, FullSharePerSurvivor());
    }

    LogMessage("[route] 队伍合计预估 %d / 队伍满额 %d（%d 人 × 每人满额 %d）",
        teamPoints, TeamMaxPoints(), count, FullSharePerSurvivor());

    if (!g_hEnable.BoolValue) return;

    // 聊天框队伍汇总（只发给生还者队里的真人，避免刷屏感染者/旁观）
    char summary[192];
    Format(summary, sizeof(summary),
        "[路程] 结算: %d 人生还者 | 全队预估 %d/%d | 最高 %d/%d",
        count, teamPoints, TeamMaxPoints(), bestPoints < 0 ? 0 : bestPoints, FullSharePerSurvivor());

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i)) continue;
        if (GetClientTeam(i) != ROUTE_TEAM_SURVIVOR) continue;
        PrintToChat(i, "%s", summary);
    }
}

//-------------------------------------------------------------------------
// HUD（默认关闭）
//-------------------------------------------------------------------------
void UpdateHud()
{
    if (g_fMapMaxFlow <= 0.0) return;   // 还没有可用分母，不刷 0/0

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i)) continue;
        if (IsFakeClient(i)) continue;                    // 只给人看
        if (GetClientTeam(i) != ROUTE_TEAM_SURVIVOR) continue;
        if (!IsPlayerAlive(i)) continue;

        PrintHintText(i, "路程 %.0f / %.0f (%.1f%%)\n累计行走 %.0f\n预估路程分 %d / %d",
            g_fMaxFlow[i], g_fMapMaxFlow, EstimatePercent(i), g_fWalked[i],
            EstimatePoints(i), FullSharePerSurvivor());
    }
}

//-------------------------------------------------------------------------
// 辅助
//-------------------------------------------------------------------------
bool IsTrackable(int client)
{
    if (client < 1 || client > MaxClients) return false;
    if (!IsClientInGame(client)) return false;
    if (GetClientTeam(client) != ROUTE_TEAM_SURVIVOR) return false;
    // IsPlayerAlive 对"倒地"（m_isIncapacitated）仍为 true，符合"存活/倒地都算"
    return IsPlayerAlive(client);
}

int CountSurvivors()
{
    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
        if (IsTrackable(i)) count++;
    return count;
}

int CollectRouteClients(int[] list, int maxSize)
{
    int count = 0;
    for (int i = 1; i <= MaxClients && count < maxSize; i++)
    {
        if (!IsClientInGame(i)) continue;
        if (GetClientTeam(i) != ROUTE_TEAM_SURVIVOR) continue;
        // 有数据的一律列出；还没动过但活着的也列出（显示 0），方便 12 人对照
        if (g_fMaxFlow[i] <= 0.0 && g_fWalked[i] <= 0.0 && !IsPlayerAlive(i)) continue;
        list[count++] = i;
    }
    return count;
}

void SortByPointsDesc(int[] list, int count)
{
    // 人数最多 32，选择排序足够，避免额外 handle
    for (int a = 0; a < count - 1; a++)
    {
        int best = a;
        for (int b = a + 1; b < count; b++)
        {
            int pb = EstimatePoints(list[b]);
            int pa = EstimatePoints(list[best]);
            if (pb > pa || (pb == pa && g_fMaxFlow[list[b]] > g_fMaxFlow[list[best]]))
                best = b;
        }
        if (best != a)
        {
            int tmp = list[a];
            list[a] = list[best];
            list[best] = tmp;
        }
    }
}

void GetNameSafe(int client, char[] buffer, int maxlen)
{
    if (g_szNameSnapshot[client][0] != '\0')
    {
        strcopy(buffer, maxlen, g_szNameSnapshot[client]);
        return;
    }

    if (!GetClientName(client, buffer, maxlen))
        strcopy(buffer, maxlen, "unknown");
}

//-------------------------------------------------------------------------
// 状态清理 / 依赖探测
//-------------------------------------------------------------------------
void ClearOneClient(int client)
{
    if (client < 1 || client > MaxClients) return;

    g_fMaxFlow[client] = 0.0;
    g_fWalked[client] = 0.0;
    g_fLastPos[client][0] = 0.0;
    g_fLastPos[client][1] = 0.0;
    g_fLastPos[client][2] = 0.0;
    g_bLastPosValid[client] = false;
    g_szNameSnapshot[client][0] = '\0';
}

void ClearAllClients()
{
    for (int i = 1; i <= MaxClients; i++)
        ClearOneClient(i);
}

// left4dhooks 的 native 是否可用（gamedata 缺失 / 版本不匹配时会被标成不可用）
void ProbeNatives()
{
    g_bFlowNative       = GetFeatureStatus(FeatureType_Native, "L4D2Direct_GetFlowDistance") == FeatureStatus_Available;
    g_bNavMaxNative     = GetFeatureStatus(FeatureType_Native, "L4D2Direct_GetMapMaxFlowDistance") == FeatureStatus_Available;
    g_bCompletionNative = GetFeatureStatus(FeatureType_Native, "L4D2_GetVersusCompletionPlayer") == FeatureStatus_Available;
    g_bEngineMaxNative  = GetFeatureStatus(FeatureType_Native, "L4D_GetVersusMaxCompletionScore") == FeatureStatus_Available;
}

// l4d2lib 这组 native 是 optional 的：未加载时会变成 unbound，调用前必须复核
void ProbeL4D2Lib()
{
    g_bMapValueNative = GetFeatureStatus(FeatureType_Native, "L4D2_GetMapValueFloat") == FeatureStatus_Available;
}

//-------------------------------------------------------------------------
// 调试日志（debug=1 时每秒一行汇总）
//-------------------------------------------------------------------------
void LogDebugSample()
{
    LogMessage("[route] tick | 地图 %s | 基础分 %d | 每人满额 %d | 最大flow %.0f(%s) | flow源 %s | 人数 %d",
        g_szMapName, g_iBaseScore, FullSharePerSurvivor(), g_fMapMaxFlow,
        g_bMapMaxFromEngine ? "引擎" : "观测兜底", g_szFlowSourceText, g_iRoundSurvivorCount);

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i)) continue;
        if (GetClientTeam(i) != ROUTE_TEAM_SURVIVOR) continue;

        char name[MAX_NAME_LENGTH];
        GetNameSafe(i, name, sizeof(name));

        LogMessage("[route]   %s | flow %.0f | %.1f%% | 行走 %.0f | 分 %d/%d%s",
            name, g_fMaxFlow[i], EstimatePercent(i), g_fWalked[i],
            EstimatePoints(i), FullSharePerSurvivor(),
            IsPlayerAlive(i) ? "" : " | 已亡");
    }
}
