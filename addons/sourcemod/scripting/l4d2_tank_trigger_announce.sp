#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <colors>

// Left4DHooks 按"可选依赖"引入：晚加载/重载期间本插件也能正常载入，
// 里程 natives 在真正调用前再用 GetFeatureStatus 确认一次。
#undef REQUIRE_PLUGIN
#include <left4dhooks>
#define REQUIRE_PLUGIN

#define PLUGIN_VERSION "1.0.0"

#define TEAM_SURVIVOR     2

// 同一只坦克的重复生成信号在该时间窗口内只公告一次。
#define ANNOUNCE_DEBOUNCE 2.0

ConVar g_hEnable;

bool
    g_bEnabled = true,
    g_bAnnounced = false,  // 当前这只坦克是否已公告过触发者
    g_bFlowWarned = false; // 本图是否已记录过"里程 natives 不可用"的报错

float g_fLastAnnounce = 0.0;

public Plugin myinfo =
{
    name = "[L4D2] Tank Trigger Announcer",
    author = "apples1949",
    description = "坦克生成时公告是谁触发的（坦克刷出瞬间路程最靠前的生还者）。",
    version = PLUGIN_VERSION,
    url = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    if (GetEngineVersion() != Engine_Left4Dead2) {
        strcopy(error, err_max, "This plugin only runs in \"Left 4 Dead 2\" game.");
        return APLRes_SilentFailure;
    }

    return APLRes_Success;
}

public void OnPluginStart()
{
    LoadTranslations("l4d2_tank_trigger_announce.phrases");

    g_hEnable = CreateConVar( \
        "l4d2_tank_trigger_announce_enable", \
        "1", \
        "是否在坦克生成时公告触发者。0=关闭, 1=开启。", \
        FCVAR_NOTIFY, true, 0.0, true, 1.0 \
    );
    g_hEnable.AddChangeHook(ConVar_EnableChanged);
    g_bEnabled = g_hEnable.BoolValue;

    // 坦克生成信号只用引擎的 tank_spawn 事件：
    // Left4DHooks 的 L4D_OnSpawnTank_Post 在 c7m3_port(Windows) 等场景会每帧重复触发，
    // 会在坦克真正刷出之前就误报触发者，并让真正的那次公告被去重吞掉。
    HookEvent("tank_spawn", Event_TankSpawn, EventHookMode_PostNoCopy);

    // 换回合、坦克死亡后重置，允许下一只坦克重新公告（终局连续刷克同样适用）。
    HookEvent("round_start", Event_ResetAnnounce, EventHookMode_PostNoCopy);
    HookEvent("tank_killed", Event_ResetAnnounce, EventHookMode_PostNoCopy);
}

public void OnMapStart()
{
    g_bFlowWarned = false;
    ResetAnnounce();
}

void ConVar_EnableChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    g_bEnabled = convar.BoolValue;
}

void Event_TankSpawn(Event event, const char[] name, bool dontBroadcast)
{
    AnnounceTankTrigger();
}

void Event_ResetAnnounce(Event event, const char[] name, bool dontBroadcast)
{
    ResetAnnounce();
}

void ResetAnnounce()
{
    g_bAnnounced = false;
    g_fLastAnnounce = 0.0;
}

/**
 * 坦克生成时公告触发者。
 *
 * 判定方式：坦克按路程自然刷出时，是"当时路程最靠前"的生还者越过了刷克点，
 * 所以直接取那一刻路程最远的生还者作为触发者，并附带其所在地图路程百分比。
 *
 * 已知边界：若坦克是被指令/脚本强行刷出（z_spawn tank、director_force_tank、终局脚本坦克等），
 * 该次生成与"谁推进到刷克点"无关，此时公告的仍是当时路程最靠前的生还者，
 * 只作为"坦克生成时谁在最前面"的参考，不代表该玩家主动触发了坦克。
 */
void AnnounceTankTrigger()
{
    if (!g_bEnabled || g_bAnnounced) {
        return;
    }

    if (!IsFlowAvailable()) {
        if (!g_bFlowWarned) {
            g_bFlowWarned = true;
            LogError("Left4DHooks 里程 natives 不可用（L4D2Direct_GetFlowDistance / L4D2Direct_GetMapMaxFlowDistance），本次无法判定坦克触发者。");
        }

        return;
    }

    float now = GetGameTime();
    if (g_fLastAnnounce > 0.0 && (now - g_fLastAnnounce) < ANNOUNCE_DEBOUNCE) {
        return;
    }

    int triggerer = FindFurthestSurvivor();
    if (triggerer == 0) {
        return;
    }

    g_bAnnounced = true;
    g_fLastAnnounce = now;

    int percent = GetSurvivorFlowPercent(triggerer);

    if (IsFakeClient(triggerer)) {
        CPrintToChatAll("%t %t", "Tag", "TriggeredBot", triggerer, percent);
    } else {
        CPrintToChatAll("%t %t", "Tag", "Triggered", triggerer, percent);
    }
}

/**
 * 取当前路程最靠前的存活生还者（含 AI）。
 *
 * @return 生还者索引；没有路程大于 0 的存活生还者时返回 0
 *         （例如全员还在起点安全区，或人都已阵亡）
 */
int FindFurthestSurvivor()
{
    int best = 0;
    float bestFlow = 0.0;

    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR || !IsPlayerAlive(i)) {
            continue;
        }

        // 起点安全区内的生还者路程为 0，不作为触发者。
        float flow = L4D2Direct_GetFlowDistance(i);
        if (flow > bestFlow) {
            bestFlow = flow;
            best = i;
        }
    }

    return best;
}

/**
 * 生还者当前路程占全图最大路程的百分比（0-100）。
 */
int GetSurvivorFlowPercent(int client)
{
    float maxFlow = L4D2Direct_GetMapMaxFlowDistance();
    if (maxFlow <= 0.0) {
        return 0;
    }

    int percent = RoundToNearest(100.0 * L4D2Direct_GetFlowDistance(client) / maxFlow);

    if (percent < 0) {
        percent = 0;
    } else if (percent > 100) {
        percent = 100;
    }

    return percent;
}

bool IsFlowAvailable()
{
    return (GetFeatureStatus(FeatureType_Native, "L4D2Direct_GetFlowDistance") == FeatureStatus_Available
        && GetFeatureStatus(FeatureType_Native, "L4D2Direct_GetMapMaxFlowDistance") == FeatureStatus_Available);
}
