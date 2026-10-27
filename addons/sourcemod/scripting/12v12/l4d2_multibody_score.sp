#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <dhooks>
#include <left4dhooks>
// Optional: read the map's own max_distance from mapinfo.txt. When l4d2lib is
// not loaded the engine value is used as the base instead.
#undef REQUIRE_PLUGIN
#include <l4d2lib>
#define REQUIRE_PLUGIN
#include <l4d2_multibody>
#include <l4d2_multibody_score_policy>

native void G14_PrepareTankScoreSettlement();

// The tank-settlement native is provided by another plugin of the same suite.
// Keep it optional so a missing provider degrades instead of failing the load.
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
    MarkNativeAsOptional("G14_PrepareTankScoreSettlement");
    // flow 距离 native 在 left4dhooks 里是 optional：标可选 + 运行期复核，
    // 老版本 left4dhooks 缺这两个 native 时插件仍能加载（自动退回引擎原生刻度）。
    MarkNativeAsOptional("L4D2Direct_GetFlowDistance");
    MarkNativeAsOptional("L4D2Direct_GetMapMaxFlowDistance");
    return APLRes_Success;
}

DynamicDetour g_CompletionHook, g_TeamScoreHook;
int g_Base[2], g_Route[2], g_Escapes[2];
int g_BodyPoints[2][G14_BODY_COUNT + 1], g_MapMaximum[2];
char g_BodyName[2][G14_BODY_COUNT + 1][MAX_NAME_LENGTH];
bool g_Played[2], g_Final[2], g_Eligible[G14_BODY_COUNT + 1];
bool g_InMap, g_Prepared, g_FinalSnapshot, g_Finalizing, g_Writing;
int g_Side, g_Epoch, g_VehicleEscapes;
int g_EngineMax;                     // last vs_max_completion_score sample
char g_Map[64];
ConVar g_hRawCap;                    // 0 = derive per-survivor full scale from the engine
ConVar g_hFlowRoute;                 // 1 = 用真实 flow 距离采样每人路程（默认），0 = 用引擎完成度原生值
bool   g_bFlowOK;                    // 两个 flow native 是否可用
float  g_fMapMaxFlow;                // 当前地图最大 flow（惰性缓存，换图清零）

public Plugin myinfo =
{
    name = "Multi Survivor Score",
    author = "applemod",
    description = "Multi survivor route shares, escape awards and campaign ledger",
    version = G14_VERSION
};

public void OnPluginStart()
{
    g_hRawCap = CreateConVar("l4d2_multibody_raw_cap", "0",
        "单人完成度满额刻度。0=从引擎推导(vs_max_completion_score/4)；>0=强制指定，用于排查原生返回 0-100 的情况。",
        FCVAR_NOTIFY, true, 0.0, true, 100000.0);

    // 2.1：每人路程分改为直接跟踪真实 flow 距离（不再依赖引擎原生完成度）。
    g_hFlowRoute = CreateConVar("l4d2_multibody_flow_route", "1",
        "1=每个生还者的路程分按真实 flow 距离采样（L4D2Direct_GetFlowDistance / GetMapMaxFlowDistance，默认）；0=退回引擎完成度原生值。",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_bFlowOK = GetFeatureStatus(FeatureType_Native, "L4D2Direct_GetFlowDistance") == FeatureStatus_Available
        && GetFeatureStatus(FeatureType_Native, "L4D2Direct_GetMapMaxFlowDistance") == FeatureStatus_Available;
    GameData data = new GameData("l4d2_multibody_score");
    if (!data)
    {
        // A missing gamedata must not stop the ledger: the score is still
        // computed and written at round end, but the engine's own completion
        // and team-score recomputes cannot be pinned during the round.
        LogError("缺少 gamedata l4d2_multibody_score.txt：引擎计分注入关闭，仅保留账本与 sm_score。");
    }
    else
    {
        g_CompletionHook = DynamicDetour.FromConf(data, "G14_RecomputeCompletion");
        g_TeamScoreHook = DynamicDetour.FromConf(data, "G14_RecomputeTeamScores");
        delete data;
        if (!g_CompletionHook || !g_CompletionHook.Enable(Hook_Pre, Completion_Pre)
            || !g_TeamScoreHook || !g_TeamScoreHook.Enable(Hook_Post, TeamScores_Post))
            LogError("无法安装计分 DHook：引擎计分注入关闭，仅保留账本与 sm_score。");
    }
    HookEvent("finale_vehicle_leaving", VehicleLeaving, EventHookMode_Pre);
    RegConsoleCmd("sm_score", ScoreCommand);
    CreateTimer(0.1, TrackRoute, _, TIMER_REPEAT);
    for (int i = 1; i <= MaxClients; i++) if (IsClientInGame(i)) OnClientPutInServer(i);
    if (!LibraryExists("l4d2_multibody_core"))
        LogError("l4d2_multibody_core 未加载：body 分配与回合 forward 不会到达，本插件不会计分。");
}

public void OnPluginEnd()
{
    if (g_CompletionHook) g_CompletionHook.Disable(Hook_Pre, Completion_Pre);
    if (g_TeamScoreHook) g_TeamScoreHook.Disable(Hook_Post, TeamScores_Post);
    delete g_CompletionHook;
    delete g_TeamScoreHook;
}

public void OnMapStart()
{
    // Plugins survive ordinary chapter transitions under Confogl. Only finalized
    // halves are carried forward; an interrupted live half is not banked.
    for (int side = 0; side < 2; side++)
    {
        if (g_Final[side]) g_Base[side] += Chapter(side);
        g_Route[side] = 0;
        g_Escapes[side] = 0;
        g_Played[side] = false;
        g_Final[side] = false;
        ResetBodyRoute(side);
    }
    GetCurrentMap(g_Map, sizeof(g_Map));
    g_Prepared = false;
    g_InMap = true;
    g_fMapMaxFlow = 0.0;   // 换图后重新采样全图最大 flow
}
public void OnMapEnd() { g_InMap = false; g_Prepared = false; }

public void G14_OnNewCampaign(int campaign)
{
    for (int side = 0; side < 2; side++)
    {
        g_Base[side] = 0;
        g_Route[side] = 0;
        g_Escapes[side] = 0;
        g_Played[side] = false;
        g_Final[side] = false;
        ResetBodyRoute(side);
    }
}

public void G14_OnRoundBegin(int epoch)
{
    g_Epoch = epoch;
    g_Side = G14_GetSurvivorLogicalTeam();
    // Bank a finalized half before its counters are reused. Without
    // this, a side that starts another round on the same map (wipe restart or
    // admin retry) would silently drop the chapter it already settled, because
    // OnMapStart is the only other place that moves Chapter() into g_Base.
    // Each finalized half is banked exactly once: OnMapStart resets g_Final.
    if (g_Final[g_Side]) g_Base[g_Side] += Chapter(g_Side);
    g_Route[g_Side] = 0;
    g_Escapes[g_Side] = 0;
    g_Played[g_Side] = true;
    g_Final[g_Side] = false;
    ResetBodyRoute(g_Side);
    for (int body = 1; body <= G14_BODY_COUNT; body++) g_Eligible[body] = false;
    g_FinalSnapshot = false;
    g_Finalizing = false;
    g_VehicleEscapes = 0;
    g_Prepared = true;
}

void ResetBodyRoute(int side)
{
    g_MapMaximum[side] = 0;
    for (int body = 1; body <= G14_BODY_COUNT; body++)
    {
        g_BodyPoints[side][body] = 0;
        g_BodyName[side][body][0] = '\0';
    }
}

bool Survivor(int client)
{
    return client > 0 && client <= MaxClients && IsClientInGame(client) && GetClientTeam(client) == 2;
}
bool Upright(int client)
{
    return Survivor(client) && IsPlayerAlive(client)
        && !GetEntProp(client, Prop_Send, "m_isIncapacitated")
        && !GetEntProp(client, Prop_Send, "m_isHangingFromLedge");
}
// Escape credit is 25 per survivor: one quarter of the four-survivor escape
// bonus (100 for four survivors), so the proportion stays identical.
int Chapter(int side) { return g_Route[side] + g_Escapes[side] * G14_ESCAPE_ROUTE_POINTS; }
int Total(int side) { return g_Base[side] + (g_Final[side] ? Chapter(side) : 0); }

void UpdateRoute()
{
    if (!g_InMap || !g_Prepared || g_Final[g_Side] || g_Epoch != G14_GetEpoch()) return;
    // ZoneMod freezes scoring by setting map maximum to zero. Keep each body's
    // previous high-water mark during the freeze, including death/replacement.
    int engineMax = L4D_GetVersusMaxCompletionScore();
    if (engineMax <= 0) return;
    if (engineMax < 4) return;
    // The base score is the map's own four-survivor route score, taken from
    // mapinfo.txt (key max_distance) exactly like the rest of the server does.
    // The engine value is only the fallback when mapinfo is unavailable. It can
    // also land after our first sample, so while this half has banked nothing
    // yet (R == 0) keep following it instead of freezing the first value seen.
    int base = MapBaseScore(engineMax);
    if (!g_MapMaximum[g_Side] || (g_Route[g_Side] == 0 && base != g_MapMaximum[g_Side]))
        g_MapMaximum[g_Side] = base;
    g_EngineMax = engineMax;
    int bodyCap = G14_BodyRouteCap(g_MapMaximum[g_Side]);
    int rawCap = G14_RawRouteCap(engineMax, g_hRawCap.IntValue);
    for (int body = 1; body <= G14_BODY_COUNT; body++)
    {
        int client = G14_GetBodyClient(body);
        if (Survivor(client)) GetClientName(client, g_BodyName[g_Side][body], sizeof(g_BodyName[][]));
        if (Survivor(client) && IsPlayerAlive(client))
        {
            // 2.1：优先用"真实 flow 距离"采样这名生还者自己的路程。
            // 引擎原生完成度（L4D2_GetVersusCompletionPlayer）是按队伍槽位算的，
            // 中途团灭/掉线换人时会飘，玩家反馈分数不对就是这个原因；
            // flow 距离是这名生还者当前所在导航区的真实进度，团灭前最后一刻的值
            // 会被 high-water 记住，所以团灭也按"走到多远"结算。
            // 采不到 flow（native 缺失/返回 0）时才退回原生刻度。
            int score;
            if (g_hFlowRoute.BoolValue && g_bFlowOK)
                score = FlowRouteScore(client, bodyCap);

            if (!(g_hFlowRoute.BoolValue && g_bFlowOK) || score <= 0)
            {
                // The native yields points in the engine's four-survivor scale.
                // Retain those raw units per body, then normalize the team sum to
                // the unchanged map maximum. Replacement keeps the same body ID.
                // Samples are converted into "one survivor's share" units
                // (bodyCap = mapinfo max_distance / 4). rawCap follows the CURRENT
                // engine value so a late mapinfo write rescales instead of mixing
                // two scales inside one body's high-water mark.
                score = G14_ConvertSample(L4D2_GetVersusCompletionPlayer(client), rawCap, bodyCap);
            }

            g_BodyPoints[g_Side][body] = G14_RouteHighWater(g_BodyPoints[g_Side][body], score, bodyCap);
        }
    }
    int total = G14_WeightedRoute(g_BodyPoints[g_Side], bodyCap, g_MapMaximum[g_Side]);
    if (total > g_Route[g_Side]) g_Route[g_Side] = total;
}

// 2.1：用真实 flow 距离换算"这一名生还者"的路程分
//   单位与 bodyCap 一致（bodyCap = 地图基础分 / 4 = 单人满额路程分）。
//   全图最大 flow 惰性缓存一次（OnMapStart 清零）；native 不可用/取不到时返回 0，
//   调用方会自动退回引擎原生完成度。
int FlowRouteScore(int client, int bodyCap)
{
    if (bodyCap <= 0) return 0;

    if (g_fMapMaxFlow <= 0.0)
        g_fMapMaxFlow = L4D2Direct_GetMapMaxFlowDistance();

    if (g_fMapMaxFlow <= 0.0) return 0;

    float fFlow = L4D2Direct_GetFlowDistance(client);
    if (fFlow <= 0.0) return 0;

    float fRatio = fFlow / g_fMapMaxFlow;
    if (fRatio > 1.0) fRatio = 1.0;

    return RoundToNearest(fRatio * float(bodyCap));
}

// mapinfo.txt's max_distance for the current map; engine value as the fallback.
int MapBaseScore(int engineMax){
    if (GetFeatureStatus(FeatureType_Native, "L4D2_GetMapValueInt") == FeatureStatus_Available)
    {
        int base = L4D2_GetMapValueInt("max_distance", 0);
        if (base > 0) return base;
    }
    return engineMax;
}

void WriteDistances()
{
    // The engine keeps four 8-bit survivor slots per team; write the team route
    // back in that scale so anything reading the engine sees the same distance.
    int teamCap = G14_TeamRouteCap(g_MapMaximum[g_Side]);
    int engineScore = G14_ToEngineScale(g_Route[g_Side], teamCap, g_EngineMax);
    for (int slot = 0; slot < 4; slot++)
        GameRules_SetProp("m_iVersusDistancePerSurvivor", G14_RouteDisplayBucket(engineScore, slot), 4, g_Side * 4 + slot);
}

MRESReturn Completion_Pre(DHookReturn result, DHookParam params)
{
    if (!g_InMap || !g_Prepared) return MRES_Ignored;
    UpdateRoute();
    WriteDistances();
    result.Value = g_Route[g_Side];
    return MRES_Supercede;
}

// Correct the engine's four-character award after every internal recompute.
// Campaign storage is synchronized separately, only from finalized records.
MRESReturn TeamScores_Post(DHookReturn result, DHookParam params)
{
    if (g_InMap && g_Prepared) WriteScoreboard();
    return MRES_Ignored;
}

void WriteScoreboard()
{
    for (int side = 0; side < 2; side++)
    {
        if (!g_Played[side]) continue;
        GameRules_SetProp("m_iChapterScore", Chapter(side), 4, side);
        GameRules_SetProp("m_iVersusSurvivalMultiplier", g_Escapes[side], 4, side);
    }
}

Action TrackRoute(Handle timer)
{
    if (g_InMap && g_Prepared && G14_IsRoundActive()) UpdateRoute();
    return Plugin_Continue;
}
public void OnClientPutInServer(int client) { SDKHook(client, SDKHook_OnTakeDamageAlive, BeforeDamage); }
Action BeforeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damageType)
{
    if (Survivor(victim) && G14_GetBody(victim) > 0 && G14_GetBody(victim) <= G14_BODY_COUNT) UpdateRoute();
    return Plugin_Continue;
}
public void OnClientDisconnect(int client) { if (Survivor(client)) UpdateRoute(); }
public void G14_OnBodyTransfer(int body, int oldClient, int newClient) { UpdateRoute(); }

int RescueTrigger()
{
    char code[192] = "local t = FindRescueAreaTrigger(); <RETURN>t == null ? -1 : t.GetEntityIndex()</RETURN>";
    char result[16];
    if (!L4D2_GetVScriptOutput(code, result, sizeof(result))) return -1;
    int entity = StringToInt(result);
    return entity > MaxClients && IsValidEntity(entity) ? entity : -1;
}

void VehicleLeaving(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_Prepared || g_FinalSnapshot || !L4D_IsMissionFinalMap()) return;
    g_FinalSnapshot = true;
    int trigger = RescueTrigger();
    if (trigger == -1)
    {
        // Do not award points to everybody alive just because a finale ended.
        LogError("%s epoch=%d: rescue trigger unavailable; escape snapshot requires runtime investigation", g_Map, g_Epoch);
        return;
    }
    for (int body = 1; body <= G14_BODY_COUNT; body++)
    {
        int client = G14_GetBodyClient(body);
        g_Eligible[body] = Upright(client) && L4D_IsTouchingTrigger(trigger, client);
        if (g_Eligible[body]) g_VehicleEscapes++;
    }
}

public Action L4D2_OnEndVersusModeRound(bool countSurvivors)
{
    if (!g_Prepared || g_Final[g_Side] || g_Finalizing) return Plugin_Continue;
    g_Finalizing = true;
    // Explicitly invoke the upstream exception before taking the final route
    // snapshot; this does not depend on forward/plugin load order.
    G14_PrepareTankScoreSettlement();
    UpdateRoute();
    bool finale = L4D_IsMissionFinalMap();
    if (finale)
    {
        g_Escapes[g_Side] = g_FinalSnapshot ? g_VehicleEscapes : 0;
    }
    else if (countSurvivors)
    {
        for (int body = 1; body <= G14_BODY_COUNT; body++)
        {
            int client = G14_GetBodyClient(body);
            g_Eligible[body] = Upright(client) && L4D_IsInLastCheckpoint(client);
            if (g_Eligible[body]) g_Escapes[g_Side]++;
        }
    }
    // Commit before ordinary-room cleanup: any nested death/end callback sees
    // this immutable settlement. Do not touch outside-room or vehicle incaps.
    g_Final[g_Side] = true;
    if (!finale && countSurvivors)
    {
        for (int body = 1; body <= G14_BODY_COUNT; body++)
        {
            int client = G14_GetBodyClient(body);
            if (Survivor(client) && IsPlayerAlive(client) && !Upright(client) && L4D_IsInLastCheckpoint(client))
                ForcePlayerSuicide(client);
        }
    }
    WriteDistances();
    WriteScoreboard();
    return Plugin_Continue;
}

public void L4D2_OnEndVersusModeRound_Post()
{
    if (!g_Prepared || !g_Final[g_Side]) return;
    g_Finalizing = false;
    int scores[2];
    scores[0] = Total(0); scores[1] = Total(1);
    g_Writing = true;
    L4D_SetCampaignScores(scores[0], scores[1]);
    L4D2_SetVersusCampaignScores(scores);
    g_Writing = false;
    WriteScoreboard();
}

public Action L4D_OnSetCampaignScores(int &scoreA, int &scoreB)
{
    if (!g_InMap || !g_Prepared || g_Writing) return Plugin_Continue;
    scoreA = Total(0); scoreB = Total(1);
    return Plugin_Changed;
}

Action ScoreCommand(int client, int args)
{
    if (client && (!IsClientInGame(client) || IsFakeClient(client))) return Plugin_Handled;
    UpdateRoute();
    ReplyToCommand(client, "[SCORE] 战役已结算 A:%d B:%d | 本章 A:%d+%d B:%d+%d（路程+逃生）", Total(0), Total(1), g_Route[0], g_Escapes[0] * G14_ESCAPE_ROUTE_POINTS, g_Route[1], g_Escapes[1] * G14_ESCAPE_ROUTE_POINTS);
    bool chat = client > 0 && GetCmdReplySource() == SM_REPLY_TO_CHAT;
    if (chat) ReplyToCommand(client, "[SCORE] %d 个身体的路程明细已输出控制台；每人占 1/4 路程，团队满分随人数放大。", G14_BODY_COUNT);
    ReplySource previous = SetCmdReplySource(SM_REPLY_TO_CONSOLE);
    PrintBodyRoutes(client);
    SetCmdReplySource(previous);
    return Plugin_Handled;
}

void PrintBodyRoutes(int client)
{
    for (int side = 0; side < 2; side++)
    {
        if (!g_Played[side]) continue;
        int base = g_MapMaximum[side];
        int teamCap = G14_TeamRouteCap(base);
        int bodyCap = G14_BodyRouteCap(base);
        ReplyToCommand(client, "[SCORE] team=%s route=%d/%d final=%d (mapinfo base=%d -> %d each, %d survivors; escape +%d each)", side == 0 ? "A" : "B", g_Route[side], teamCap, g_Final[side], base, bodyCap, G14_BODY_COUNT, G14_ESCAPE_ROUTE_POINTS);
        for (int body = 1; body <= G14_BODY_COUNT; body++)
            ReplyToCommand(client, "body=%02d name=%s route=%d/%d", body,
                g_BodyName[side][body][0] ? g_BodyName[side][body] : "(unassigned)", g_BodyPoints[side][body], bodyCap);
    }
}

public Action ScoreDiagnostics(int client, int args)
{
    ScoreCommand(client, args);
    ReplyToCommand(client, "epoch=%d side=%d final=%d vehicleSnapshot=%d vehicleEscapes=%d", g_Epoch, g_Side, g_Final[g_Side], g_FinalSnapshot, g_VehicleEscapes);
    for (int side = 0; side < 2; side++)
        ReplyToCommand(client, "side=%d engineChapter=%d engineCampaign=%d escapeCount=%d", side,
            GameRules_GetProp("m_iChapterScore", 4, side), GameRules_GetProp("m_iCampaignScore", 4, side), g_Escapes[side]);
    return Plugin_Handled;
}
