#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#define PLUGIN_VERSION "1.0.0"
#define PLUGIN_TAG "[AppleMod 开局清尸]"

#define TEAM_INFECTED      3
#define ZOMBIE_CLASS_TANK  8

// 0 = 全图清理，1 = 只清理“路程窗口”内的目标（默认）。
#define MODE_ALL  0
#define MODE_FLOW 1

enum ScanState
{
    ScanState_Idle = 0,
    ScanState_Sweeping,
    ScanState_Pausing
}

ConVar
    g_hEnable = null,
    g_hMode = null,
    g_hPercent = null,
    g_hCommons = null,
    g_hWitches = null,
    g_hSpecials = null,
    g_hChunk = null,
    g_hInterval = null,
    g_hPause = null,
    g_hVerbose = null;

ScanState g_eState = ScanState_Idle;

bool
    g_bEnabled = true,
    g_bCleanCommons = true,
    g_bCleanWitches = false,
    g_bCleanSpecials = false,
    g_bVerbose = false,
    g_bMapReady = false,
    g_bMapStartSeen = false,
    g_bLeftSafeArea = false,
    g_bFlowWindowAvailable = true,
    g_bClientFlowAvailable = true,
    g_bNavAreaFlowAvailable = true,
    g_bFlowFallbackWarned = false;

int
    g_iMode = MODE_FLOW,
    g_iChunk = 512, // 2048 / 4：每遍历 512 个实体槽位后休息 0.1 秒。
    g_iMaxEntities = 2048,
    g_iRoundSerial = 0,
    g_iNextEntity = 0,
    g_iKilledThisSweep = 0,
    g_iSweepsCompleted = 0;

float
    g_fPercent = 5.0,
    g_fInterval = 0.1,
    g_fPause = 1.0,
    g_fFlowLimit = -1.0; // < 0 表示不过滤（全图清理）。

public Plugin myinfo =
{
    name = "Applemod Pre-Spawn Zombie Cleaner",
    author = "apples1949",
    description = "玩家离开起点安全区域前，分块循环清理地图僵尸；默认只清理当前路程前方 5% 的普通僵尸。AppleMod 配置专属。",
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
    g_hEnable = CreateConVar( \
        "applemod_preclean_enable", \
        "1", \
        "是否启用开局安全区循环清尸。0=关闭, 1=开启。", \
        FCVAR_NOTIFY, true, 0.0, true, 1.0 \
    );

    g_hMode = CreateConVar( \
        "applemod_preclean_mode", \
        "1", \
        "清理范围模式：0=全图所有目标, 1=只清理路程窗口内目标（默认，需要 Left4DHooks flow 支持）。", \
        FCVAR_NOTIFY, true, 0.0, true, 1.0 \
    );

    g_hPercent = CreateConVar( \
        "applemod_preclean_percent", \
        "5.0", \
        "路程模式窗口大小（%）：清理最远幸存者路程之后、剩余路程的前 N%。开局未出门时即为地图最前端 N%。", \
        FCVAR_NOTIFY, true, 0.1, true, 100.0 \
    );

    g_hCommons = CreateConVar( \
        "applemod_preclean_commons", \
        "1", \
        "是否清理普通僵尸(infected)。0=否, 1=是。", \
        FCVAR_NOTIFY, true, 0.0, true, 1.0 \
    );

    g_hWitches = CreateConVar( \
        "applemod_preclean_witches", \
        "0", \
        "是否清理 Witch（默认关闭，避免破坏对抗模式的 Witch 配置）。0=否, 1=是。", \
        FCVAR_NOTIFY, true, 0.0, true, 1.0 \
    );

    g_hSpecials = CreateConVar( \
        "applemod_preclean_specials", \
        "0", \
        "是否清理 AI 特感（默认关闭；不会清理玩家控制的特感，也不会清理 Tank）。0=否, 1=是。", \
        FCVAR_NOTIFY, true, 0.0, true, 1.0 \
    );

    g_hChunk = CreateConVar( \
        "applemod_preclean_chunk", \
        "512", \
        "每次遍历的实体槽位数量（2048/4=512），遍历完一批后休息一个间隔再继续。", \
        FCVAR_NOTIFY, true, 64.0, true, 2048.0 \
    );

    g_hInterval = CreateConVar( \
        "applemod_preclean_interval", \
        "0.1", \
        "每遍历一批实体后的等待时间（秒）。", \
        FCVAR_NOTIFY, true, 0.05, true, 2.0 \
    );

    g_hPause = CreateConVar( \
        "applemod_preclean_pause", \
        "1.0", \
        "完整遍历清理一遍后、开始下一遍前的等待时间（秒）。", \
        FCVAR_NOTIFY, true, 0.1, true, 10.0 \
    );

    g_hVerbose = CreateConVar( \
        "applemod_preclean_verbose", \
        "0", \
        "是否在服务器控制台输出每遍清理统计。0=否, 1=是。", \
        FCVAR_NOTIFY, true, 0.0, true, 1.0 \
    );

    g_hEnable.AddChangeHook(CvarChanged);
    g_hMode.AddChangeHook(CvarChanged);
    g_hPercent.AddChangeHook(CvarChanged);
    g_hCommons.AddChangeHook(CvarChanged);
    g_hWitches.AddChangeHook(CvarChanged);
    g_hSpecials.AddChangeHook(CvarChanged);
    g_hChunk.AddChangeHook(CvarChanged);
    g_hInterval.AddChangeHook(CvarChanged);
    g_hPause.AddChangeHook(CvarChanged);
    g_hVerbose.AddChangeHook(CvarChanged);

    ReadCvars();

    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
    HookEvent("player_left_start_area", Event_PlayerLeftStartArea, EventHookMode_PostNoCopy);
}

public void OnAllPluginsLoaded()
{
    if (GetFeatureStatus(FeatureType_Native, "L4D_HasAnySurvivorLeftSafeArea") != FeatureStatus_Available) {
        SetFailState("需要 Left4DHooks（L4D_HasAnySurvivorLeftSafeArea 不可用）。");
    }

    // 判断“僵尸路程位置”所需的 flow 接口是否齐全。
    g_bFlowWindowAvailable = IsNativeAvailable("L4D_GetInfectedFlowDistance")
        && IsNativeAvailable("L4D2Direct_GetMapMaxFlowDistance")
        && IsNativeAvailable("L4D2_GetFurthestSurvivorFlow");
    g_bClientFlowAvailable = IsNativeAvailable("L4D2Direct_GetFlowDistance");
    g_bNavAreaFlowAvailable = IsNativeAvailable("L4D_GetNearestNavArea")
        && IsNativeAvailable("L4D2Direct_GetTerrorNavAreaFlow");

    if (!g_bFlowWindowAvailable) {
        LogError("%s 当前 Left4DHooks 无法获取僵尸路程，flow 模式将退回全图清理。", PLUGIN_TAG);
    }

    // 插件晚加载（地图已经在运行时）：补一次启动检查。
    if (!g_bMapStartSeen) {
        CreateTimer(0.5, Timer_LateStart, g_iRoundSerial, TIMER_FLAG_NO_MAPCHANGE);
    }
}

public void OnMapStart()
{
    g_bMapStartSeen = true;
    g_iRoundSerial++;
    g_bMapReady = false;
    g_bLeftSafeArea = false;
    g_eState = ScanState_Idle;
    g_iNextEntity = 0;
    g_iSweepsCompleted = 0;
    g_iKilledThisSweep = 0;
    g_bFlowFallbackWarned = false;

    g_iMaxEntities = GetMaxEntities();
    if (g_iMaxEntities < MaxClients + 1) {
        g_iMaxEntities = 2048;
    }

    // 延迟到 flow 数据可用（Left4DHooks 要求地图开始至少一帧后才能调用）。
    CreateTimer(0.5, Timer_MapReady, g_iRoundSerial, TIMER_FLAG_NO_MAPCHANGE);
}

public void OnConfigsExecuted()
{
    ReadCvars();
}

void CvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    ReadCvars();

    // 让旧定时器失效，并按新参数重新开始（若仍处于应清理状态）。
    if (!g_bMapReady) {
        return;
    }

    g_iRoundSerial++;
    g_eState = ScanState_Idle;

    if (g_bEnabled && !g_bLeftSafeArea) {
        StartCleaning();
    }
}

void ReadCvars()
{
    g_bEnabled = g_hEnable.BoolValue;
    g_iMode = g_hMode.IntValue;
    g_fPercent = g_hPercent.FloatValue;
    g_bCleanCommons = g_hCommons.BoolValue;
    g_bCleanWitches = g_hWitches.BoolValue;
    g_bCleanSpecials = g_hSpecials.BoolValue;
    g_iChunk = g_hChunk.IntValue;
    g_fInterval = g_hInterval.FloatValue;
    g_fPause = g_hPause.FloatValue;
    g_bVerbose = g_hVerbose.BoolValue;

    if (g_iMode != MODE_ALL && g_iMode != MODE_FLOW) {
        g_iMode = MODE_FLOW;
    }

    if (g_iChunk < 1) {
        g_iChunk = 1;
    }

    if (g_fInterval < 0.05) {
        g_fInterval = 0.05;
    }

    if (g_fPause < 0.1) {
        g_fPause = 0.1;
    }
}

bool IsNativeAvailable(const char[] name)
{
    return GetFeatureStatus(FeatureType_Native, name) == FeatureStatus_Available;
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    // 新回合：仅当引擎确认“还没有人离开起点安全区域”时才重新开始清理。
    g_iRoundSerial++;
    g_bFlowFallbackWarned = false;
    g_eState = ScanState_Idle;

    if (g_bMapReady) {
        g_bLeftSafeArea = L4D_HasAnySurvivorLeftSafeArea();
        if (!g_bLeftSafeArea) {
            StartCleaning();
        } else {
            // 可能是上一回合标志还没复位：稍后复查一次，避免错过整个新回合。
            CreateTimer(0.5, Timer_RoundStartRetry, g_iRoundSerial, TIMER_FLAG_NO_MAPCHANGE);
        }
    } else {
        g_bLeftSafeArea = false;
        CreateTimer(0.5, Timer_MapReady, g_iRoundSerial, TIMER_FLAG_NO_MAPCHANGE);
    }
}

Action Timer_RoundStartRetry(Handle timer, int serial)
{
    if (serial != g_iRoundSerial) {
        return Plugin_Stop;
    }

    g_bLeftSafeArea = L4D_HasAnySurvivorLeftSafeArea();
    if (!g_bLeftSafeArea) {
        StartCleaning();
    }

    return Plugin_Stop;
}

void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    // 回合结束：停掉本回合所有清理节奏。
    g_iRoundSerial++;
    g_bLeftSafeArea = true;
    g_eState = ScanState_Idle;
}

void Event_PlayerLeftStartArea(Event event, const char[] name, bool dontBroadcast)
{
    // 备用停手信号；主信号是 Left4DHooks 的 L4D_OnFirstSurvivorLeftSafeArea_Post。
    MarkLeftSafeArea();
}

public void L4D_OnFirstSurvivorLeftSafeArea_Post(int client)
{
    MarkLeftSafeArea(client);
}

void MarkLeftSafeArea(int client = 0)
{
    if (g_bLeftSafeArea) {
        return;
    }

    g_bLeftSafeArea = true;
    g_eState = ScanState_Idle;
    g_iRoundSerial++; // 让暂停/遍历中的旧定时器失效。

    if (g_bVerbose) {
        LogMessage("%s 玩家已离开起点安全区域（client=%d），停止清理。", PLUGIN_TAG, client);
    }
}

Action Timer_MapReady(Handle timer, int serial)
{
    if (serial != g_iRoundSerial) {
        return Plugin_Stop;
    }

    g_bMapReady = true;
    g_bLeftSafeArea = L4D_HasAnySurvivorLeftSafeArea();

    if (!g_bLeftSafeArea) {
        StartCleaning();
    }

    return Plugin_Stop;
}

Action Timer_LateStart(Handle timer, int serial)
{
    if (serial != g_iRoundSerial) {
        return Plugin_Stop;
    }

    if (!g_bMapReady) {
        g_iMaxEntities = GetMaxEntities();
        g_bMapReady = true;
        g_bLeftSafeArea = L4D_HasAnySurvivorLeftSafeArea();
    }

    if (!g_bLeftSafeArea) {
        StartCleaning();
    }

    return Plugin_Stop;
}

void StartCleaning()
{
    if (!g_bEnabled || !g_bMapReady || g_bLeftSafeArea || g_eState != ScanState_Idle) {
        return;
    }

    if (L4D_HasAnySurvivorLeftSafeArea()) {
        MarkLeftSafeArea();
        return;
    }

    RebuildFlowWindow();

    g_iNextEntity = 0;
    g_iKilledThisSweep = 0;
    g_eState = ScanState_Sweeping;

    CreateTimer(g_fInterval, Timer_ScanChunk, g_iRoundSerial, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void RebuildFlowWindow()
{
    // < 0 = 不按路程过滤，即全图清理。
    g_fFlowLimit = -1.0;

    if (g_iMode != MODE_FLOW) {
        return;
    }

    // 无法判断僵尸路程位置时退回全图清理（符合需求中的回退策略）。
    if (!g_bFlowWindowAvailable) {
        WarnFlowFallback("Left4DHooks flow 接口不可用");
        return;
    }

    float maxFlow = L4D2Direct_GetMapMaxFlowDistance();
    if (maxFlow <= 0.0) {
        WarnFlowFallback("无法获取本图最大路程");
        return;
    }

    float furthest = L4D2_GetFurthestSurvivorFlow();
    if (furthest < 0.0) {
        furthest = 0.0;
    } else if (furthest > maxFlow) {
        furthest = maxFlow;
    }

    float percent = g_fPercent;
    if (percent < 0.0) {
        percent = 0.0;
    } else if (percent > 100.0) {
        percent = 100.0;
    }

    // 窗口 = 最远幸存者当前路程之后、剩余路程的前 N%。
    // 尚未出门时最远幸存者路程≈0，也就是地图最前端 N% 的路程。
    g_fFlowLimit = furthest + (maxFlow - furthest) * (percent / 100.0);
}

void WarnFlowFallback(const char[] reason)
{
    if (g_bFlowFallbackWarned) {
        return;
    }

    g_bFlowFallbackWarned = true;
    LogError("%s %s，本回合 flow 模式退回全图清理。", PLUGIN_TAG, reason);
}

Action Timer_ScanChunk(Handle timer, int serial)
{
    if (serial != g_iRoundSerial
        || !g_bEnabled
        || !g_bMapReady
        || g_bLeftSafeArea
        || g_eState != ScanState_Sweeping) {
        return Plugin_Stop;
    }

    // 每批开始前都复查一次，离开安全区域后立即停手。
    if (L4D_HasAnySurvivorLeftSafeArea()) {
        MarkLeftSafeArea();
        return Plugin_Stop;
    }

    int start = g_iNextEntity;
    int end = start + g_iChunk;
    if (end > g_iMaxEntities) {
        end = g_iMaxEntities;
    }

    for (int entity = start; entity < end; entity++) {
        ProcessEntity(entity);
    }

    g_iNextEntity = end;

    if (end >= g_iMaxEntities) {
        // 完整遍历完一遍：统计、等待 g_fPause 秒后重新开始。
        g_iSweepsCompleted++;
        if (g_bVerbose) {
            LogMessage("%s 第 %d 遍遍历完成：扫描 %d 个实体槽位，清理 %d 个目标；%.1f 秒后开始下一遍。", \
                PLUGIN_TAG, g_iSweepsCompleted, g_iMaxEntities, g_iKilledThisSweep, g_fPause);
        }

        g_iKilledThisSweep = 0;
        g_eState = ScanState_Pausing;
        CreateTimer(g_fPause, Timer_RestartScan, serial, TIMER_FLAG_NO_MAPCHANGE);
        return Plugin_Stop;
    }

    return Plugin_Continue;
}

Action Timer_RestartScan(Handle timer, int serial)
{
    if (serial != g_iRoundSerial || !g_bEnabled || !g_bMapReady || g_bLeftSafeArea) {
        return Plugin_Stop;
    }

    g_eState = ScanState_Idle;
    StartCleaning();
    return Plugin_Stop;
}

void ProcessEntity(int entity)
{
    // 客户端槽位（1..MaxClients）：按开关处理 AI 特感。
    if (entity >= 1 && entity <= MaxClients) {
        if (g_bCleanSpecials) {
            TryCleanSpecialClient(entity);
        }
        return;
    }

    if (!IsValidEntity(entity)) {
        return;
    }

    char classname[16];
    if (!GetEntityClassname(entity, classname, sizeof(classname))) {
        return;
    }

    if (StrEqual(classname, "infected", false)) {
        if (g_bCleanCommons) {
            TryCleanCommon(entity);
        }
        return;
    }

    if (StrEqual(classname, "witch", false)) {
        if (g_bCleanWitches) {
            TryCleanWitch(entity);
        }
    }
}

void TryCleanCommon(int entity)
{
    // 普通僵尸有精确的 flow 路程接口：L4D_GetInfectedFlowDistance。
    if (g_iMode == MODE_FLOW && g_fFlowLimit >= 0.0) {
        float flow = L4D_GetInfectedFlowDistance(entity);
        if (flow > g_fFlowLimit) {
            return;
        }
    }

    AcceptEntityInput(entity, "Kill");
    g_iKilledThisSweep++;
}

void TryCleanWitch(int entity)
{
    if (g_iMode == MODE_FLOW && g_fFlowLimit >= 0.0) {
        // Witch 没有精确 flow 接口，用最近 nav area 的路程近似判断。
        float flow = GetEntityFlowByNavArea(entity);
        if (flow < 0.0 || flow > g_fFlowLimit) {
            return;
        }
    }

    AcceptEntityInput(entity, "Kill");
    g_iKilledThisSweep++;
}

void TryCleanSpecialClient(int client)
{
    if (!IsClientInGame(client) || !IsFakeClient(client)) {
        return;
    }

    if (!IsPlayerAlive(client) || GetClientTeam(client) != TEAM_INFECTED) {
        return;
    }

    // 不清理幽灵状态特感、不清理 Tank（Tank=8）。
    if (GetEntProp(client, Prop_Send, "m_isGhost") == 1) {
        return;
    }

    int zombieClass = GetEntProp(client, Prop_Send, "m_zombieClass");
    if (zombieClass < 1 || zombieClass > 6) {
        return;
    }

    if (g_iMode == MODE_FLOW && g_fFlowLimit >= 0.0) {
        if (!g_bClientFlowAvailable) {
            return; // 无法判断该特感路程，宁可不清理。
        }

        float flow = L4D2Direct_GetFlowDistance(client);
        if (flow > g_fFlowLimit) {
            return;
        }
    }

    ForcePlayerSuicide(client);
    g_iKilledThisSweep++;
}

float GetEntityFlowByNavArea(int entity)
{
    if (!g_bNavAreaFlowAvailable) {
        return -1.0;
    }

    float pos[3];
    GetEntPropVector(entity, Prop_Send, "m_vecOrigin", pos);

    Address area = L4D_GetNearestNavArea(pos, 600.0, true, false, false, 2);
    if (area == Address_Null) {
        return -1.0;
    }

    return L4D2Direct_GetTerrorNavAreaFlow(area);
}
