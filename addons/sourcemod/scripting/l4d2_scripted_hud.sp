// ====================================================================================================
// Plugin Info
// ====================================================================================================
public Plugin myinfo =
{
    name        = "[L4D2] Scripted HUD",
    author      = "Mart,apples1949",
    description = "Display boss progress and server info using the scripted HUD",
    version     = "1.4.1",
    url         = "https://forums.alliedmods.net/showthread.php?t=331212"
}

// ====================================================================================================
// Includes
// ====================================================================================================
#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#undef REQUIRE_PLUGIN
#include <witch_and_tankifier>
#include <l4d2_hybrid_scoremod>
#include <l4d2_fix_team_shuffle_edi>

#undef REQUIRE_EXTENSIONS
#include <sendproxy> //core.inc 已定义 AUTOLOAD_EXTENSIONS; 这里让扩展成为可选依赖, 缺失时插件仍可加载.

// ====================================================================================================
// Pragmas
// ====================================================================================================
#pragma semicolon 1
#pragma newdecls required

// ====================================================================================================
// HUD slots
// ====================================================================================================
#define HUD1                          0
#define HUD2                          1
#define HUD_TICKER                    6

// ====================================================================================================
// HUD flags (same bit values used by the L4D2 scripted HUD system)
// ====================================================================================================
#define HUD_FLAG_BLINK                8      // blink the text
#define HUD_FLAG_NOBG                 64     // dont draw the background box
#define HUD_FLAG_ALIGN_LEFT           256    // left justify the text
#define HUD_FLAG_TEXT                 8192   // required to draw text
#define HUD_FLAG_NOTVISIBLE           16384  // keep the slot data but stop displaying it

// HUD1 flags: visible, no background, left aligned. Blinks while a tank is alive.
#define HUD1_FLAGS                    (HUD_FLAG_TEXT | HUD_FLAG_NOBG | HUD_FLAG_ALIGN_LEFT)
// HUD2 flags: visible, no background, left aligned.
#define HUD2_FLAGS                    (HUD_FLAG_TEXT | HUD_FLAG_NOBG | HUD_FLAG_ALIGN_LEFT)

// ====================================================================================================
// HUD layout
// ====================================================================================================
#define HUD1_X                        0.05
#define HUD1_Y                        0.0
#define HUD2_X                        0.65
#define HUD2_Y                        0.0
#define HUD_WIDTH                     1.0
#define HUD_HEIGHT                    0.026
#define HUD_CHECK_INTERVAL            1.0    //按需更新: 低频检查是否有变化, 没变化不发包; 关键事件即时刷新.

// 修复队伍 HUD_TICKER 布局 (带背景: 不设置 HUD_FLAG_NOBG).
#define FIX_HUD_X                      0.25
#define FIX_HUD_Y                      0.08
#define FIX_HUD_WIDTH                  0.5
#define FIX_HUD_HEIGHT                 0.05
#define FIX_HUD_FLAGS                  (HUD_FLAG_TEXT | HUD_FLAG_ALIGN_LEFT)

// 局末趣文独立槽位 (带背景, 与修复队伍提示同风格但不共用槽位).
// 不用 6 号 HUD_TICKER: 那是游戏自带 ticker 的地盘, 回合结束时游戏正在往那里写结算/奖励提示,
// 只写一次会被立刻覆盖 -> 这就是"趣文 HUD 不显示"的原因.
#define FUNFACT_HUD                    2
#define FUNFACT_HUD_X                  0.25
#define FUNFACT_HUD_Y                  0.14
#define FUNFACT_HUD_WIDTH              0.6
#define FUNFACT_HUD_HEIGHT             0.05
#define FUNFACT_HUD_FLAGS              (HUD_FLAG_TEXT | HUD_FLAG_ALIGN_LEFT)

// 趣文轮播: 槽位一次只放一条, 每 FUNFACT_FACT_INTERVAL 秒换成下一条"还没显示过的"
// (池内都显示过后就停在最后一条, 不回头重播). 池子内容由 l4d2_playstats_tranchi 决定:
// 当前是"本回合趣文"(全场趣文走聊天框那一条, 不占 HUD).
#define FUNFACT_FACT_INTERVAL          0.5     // 单条趣文的显示时长(轮播间隔), 与 FUNFACT_REFRESH_INTERVAL 相等.
#define FUNFACT_POOL_MAX               16      // 轮播池上限: 与 l4d2_playstats_tranchi 的 FFACT_MAXTYPES 对齐.

// 趣文显示时长与重写策略.
#define FUNFACT_REFRESH_INTERVAL       0.5     // 重写间隔: 游戏在回合结束/回合开始会整片重置脚本 HUD.
#define FUNFACT_HIDE_DEFAULT           5.0     // 调用方没给时长时的默认显示时间(整个轮播窗口).
#define FUNFACT_ROUNDSTART_SHOW        0.0     // >0: 回合开始后把池内还没显示过的趣文续轮这么多秒;
                                               // 0 = 不跨回合补显 (需求: 回合结束 8 秒即可).
#define FUNFACT_MAX_DISPLAY            30.0    // 兜底上限: 单次趣文最长显示时间, 避免无限重写.
#define FUNFACT_TEXT_MAX               256     // 与本插件 HUD1/HUD2 文本缓冲一致, 与脚本 HUD 单槽字符串长度对齐 (超长截断).
#define FUNFACT_INPUT_MAX              (FUNFACT_TEXT_MAX * FUNFACT_POOL_MAX) // 调用方一次传入的整段趣文文本上限 (每条一行).

// 修正中/完成提示文字与动画参数.
#define FIX_MSG_BASE                   "正在修正队伍 非上一轮游戏的玩家请等待位置修正完成再加入游戏"
#define FIX_MSG_DONE                   "队伍修正完成 可以加入游戏了"
#define FIX_MSG_MAX_DOTS               6
#define FIX_ANIM_INTERVAL              0.5
#define FIX_DONE_HIDE_TIME             5.0

#define TEAM_INFECTED                 3
#define L4D2_ZOMBIECLASS_TANK         8

// ====================================================================================================
// Plugin Variables
// ====================================================================================================
static bool   g_bHUDEnabled = true;
static bool   g_bWitchAndTankSystemAvailable;
static bool   g_bhybridScoringAvailable;
static ConVar g_hVsBossBuffer;
static Handle g_hTimerHUD;

// Left4SendProxy (SendProxy_HookGameRules) 逐客户端 HUD 隐藏支持.
static bool   g_bSendProxyAvailable;
static bool   g_bHUDSendProxyHooked;
static int    g_iHookHUDAttempts;
static bool   g_bHUDHidden[MAXPLAYERS + 1];

// l4d2_fix_team_shuffle_edi 修复队伍 HUD_TICKER 状态.
static bool   g_bFixTeamShuffleAvailable;
static bool   g_bFixTeamShuffleInProgress;
static bool   g_bFixHUDVisible;
static Handle g_hFixAnimTimer;
static Handle g_hFixDoneTimer;
static int    g_iFixDotCount;

// 局末趣文 HUD (独立槽位 FUNFACT_HUD) 状态: 一个轮播池, 槽位里始终只有当前这一条.
static bool   g_bFunFactHUDVisible;
static char   g_sFunFactPool[FUNFACT_POOL_MAX][FUNFACT_TEXT_MAX]; // 待轮播的趣文 (调用方一次给的整段文本按行拆开).
static int    g_iFunFactPoolCount;                              // 池内条数.
static int    g_iFunFactPoolIndex;                              // 当前显示的是第几条.
static Handle g_hFunFactTimer;                                  // 重复重写计时器.
static float  g_fFunFactExpire;                                 // 计划隐藏时间 (GameTime).
static float  g_fFunFactHardExpire;                             // 硬性上限 (GameTime).
static float  g_fFunFactNextSwitch;                             // 下一次换条的时间 (GameTime).
// 池内还有没显示过的条目: 供 FUNFACT_ROUNDSTART_SHOW > 0 时的跨回合续轮用(默认关闭).
static bool   g_bFunFactPending;

// 按需更新缓存: 内容/标志没变化时跳过 GameRules_SetProp*.
static bool   g_bHUDDirty = true;
static char   g_sHUD_LastTextArray[2][256];
static int    g_iHUDLastFlags[2] = { -1, -1 };

static char   g_sHUD_TextArray[2][256];

// ====================================================================================================
// Plugin Start
// ====================================================================================================
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    EngineVersion engine = GetEngineVersion();

    if (engine != Engine_Left4Dead2)
    {
        strcopy(error, err_max, "This plugin only runs in \"Left 4 Dead 2\" game");
        return APLRes_SilentFailure;
    }

    CreateNative("ScriptedHud_ShowRoundFunFact", Native_ShowRoundFunFact);
    RegPluginLibrary("l4d2_scripted_hud");

    return APLRes_Success;
}

// ====================================================================================================
public void OnPluginStart()
{
    g_hVsBossBuffer = FindConVar("versus_boss_buffer");

    LoadTranslations("common.phrases");

    RegConsoleCmd("sm_hud", CommandSwitchHud, "管理员全局开启或关闭HUD显示.");
    RegConsoleCmd("sm_offhud", CommandOffHud, "关闭自己的HUD显示. ROOT管理员可带玩家名关闭指定玩家.");
    RegConsoleCmd("sm_onhud", CommandOnHud, "开启自己的HUD显示. ROOT管理员可带玩家名开启指定玩家.");
    RegConsoleCmd("sm_hud_debug", CommandHudDebug, "调试: 输出SendProxy状态.");

    // 按需更新: 这些事件发生后立即检查HUD内容是否有变化.
    HookEvent("round_start",  Event_HUDRefresh, EventHookMode_PostNoCopy);
    HookEvent("round_end",    Event_HUDRefresh, EventHookMode_PostNoCopy);
    HookEvent("player_team",  Event_HUDRefresh, EventHookMode_PostNoCopy);
    HookEvent("player_spawn", Event_HUDRefresh, EventHookMode_PostNoCopy);
    HookEvent("player_death", Event_HUDRefresh, EventHookMode_PostNoCopy);
    HookEvent("tank_spawn",   Event_HUDRefresh, EventHookMode_PostNoCopy);
    HookEvent("witch_spawn",  Event_HUDRefresh, EventHookMode_PostNoCopy);
}

// ====================================================================================================
public void OnAllPluginsLoaded()
{
    g_bWitchAndTankSystemAvailable = LibraryExists("witch_and_tankifier");
    g_bhybridScoringAvailable = LibraryExists("l4d2_hybrid_scoremod");

    g_bSendProxyAvailable = LibraryExists("sendproxy2");
    if (g_bSendProxyAvailable)
        TryHookHUDSendProxy();

    g_bFixTeamShuffleAvailable = LibraryExists("l4d2_fix_team_shuffle_edi");
    UpdateFixTeamShuffleHUD();
}

public void OnLibraryAdded(const char[] name)
{
    if (StrEqual(name, "witch_and_tankifier"))
        g_bWitchAndTankSystemAvailable = true;
    else if (StrEqual(name, "l4d2_hybrid_scoremod"))
        g_bhybridScoringAvailable = true;
    else if (StrEqual(name, "sendproxy2"))
    {
        g_bSendProxyAvailable = true;
        g_iHookHUDAttempts = 0;
        TryHookHUDSendProxy();
    }
    else if (StrEqual(name, "l4d2_fix_team_shuffle_edi"))
    {
        g_bFixTeamShuffleAvailable = true;
        UpdateFixTeamShuffleHUD();
    }

    UpdateHUD(); //可选插件就绪可能改变HUD1内容.
}

public void OnLibraryRemoved(const char[] name)
{
    if (StrEqual(name, "witch_and_tankifier"))
        g_bWitchAndTankSystemAvailable = false;
    else if (StrEqual(name, "l4d2_hybrid_scoremod"))
        g_bhybridScoringAvailable = false;
    else if (StrEqual(name, "sendproxy2"))
    {
        g_bSendProxyAvailable = false;
        g_bHUDSendProxyHooked = false;

        //扩展卸载后所有隐藏状态失效, 清空避免扩展重新加载后玩家被意外重新隐藏.
        for (int i = 1; i <= MaxClients; i++)
            g_bHUDHidden[i] = false;
    }
    else if (StrEqual(name, "l4d2_fix_team_shuffle_edi"))
    {
        g_bFixTeamShuffleAvailable = false;
        g_bFixTeamShuffleInProgress = false;
        HideFixHUD();
    }

    UpdateHUD(); //可选插件卸载可能改变HUD1内容.
}

// ====================================================================================================
// 每张地图重新注册 SendProxy 的 GameRules hooks（扩展在 map end 时会清空 hooks）.
// ====================================================================================================
public void OnMapStart()
{
    g_bHUDDirty = true;
    g_bHUDSendProxyHooked = false;
    g_iHookHUDAttempts = 0;
    TryHookHUDSendProxy();
}

public void OnMapEnd()
{
    g_bHUDSendProxyHooked = false;
    HideFixHUD();

    // 局末趣文 timer 未加 NO_MAPCHANGE: 换图时清掉并复位状态, 避免句柄悬垂.
    delete g_hFunFactTimer;
    g_hFunFactTimer = null;
    g_bFunFactHUDVisible = false;
    g_iFunFactPoolCount = 0;
    g_iFunFactPoolIndex = 0;

    // 趣文属于上一张图的回合, 换图后不再补显.
    g_bFunFactPending = false;
}

public void OnClientConnected(int client)
{
    UpdateHUD(); //人数(总在线)变化, 立即刷新.
}

public void OnClientPutInServer(int client)
{
    UpdateHUD(); //人数(在线)变化, 立即刷新.
}

public void OnClientDisconnect(int client)
{
    g_bHUDHidden[client] = false;
}

public void OnClientDisconnect_Post(int client)
{
    UpdateHUD(); //此时代客户端已真正移除, 人数计算才是正确的.
}

// ====================================================================================================
public void OnConfigsExecuted()
{
    if (g_bHUDEnabled)
    {
        g_bHUDDirty = true;
        CreateHUDTimer();
        UpdateHUD();
    }
}

// 事件触发: 重新计算并仅在内容变化时发包.
public void Event_HUDRefresh(Event event, const char[] name, bool dontBroadcast)
{
    // OnMapStart 时实体可能还没创建, 借事件再次尝试 hook.
    TryHookHUDSendProxy();
    UpdateFixTeamShuffleHUD();
    UpdateHUD();

    // 回合结束时屏幕上先是记分板/过渡画面, 脚本 HUD 会被盖住; 若池内还有没显示过的趣文,
    // 可在新回合开始时(记分板收起后)接着轮 (FUNFACT_ROUNDSTART_SHOW > 0 才启用, 默认关闭).
    if (StrEqual(name, "round_start") && g_bFunFactPending && !g_bFixTeamShuffleInProgress
        && FUNFACT_ROUNDSTART_SHOW > 0.0)
    {
        ResumeFunFactHUD(FUNFACT_ROUNDSTART_SHOW);
    }
}

// ====================================================================================================
// sm_hud - 全局开启/关闭HUD (管理员, 保持原有行为; votes_applemod 的投票调用它).
// ====================================================================================================
public Action CommandSwitchHud(int client, int args)
{
    if (client != 0 && !(GetUserFlagBits(client) & ADMFLAG_ROOT))
    {
        ReplyToCommand(client, "\x04[提示]\x05你无权使用该指令.");
        return Plugin_Handled;
    }

    char sMsg[32];
    if (g_bHUDEnabled)
    {
        g_bHUDEnabled = false;
        delete g_hTimerHUD;
        RequestFrame(OnNextFrameClearHUD); //延迟一帧清除HUD.
        sMsg = "已关闭HUD显示";
    }
    else
    {
        g_bHUDEnabled = true;
        g_bHUDDirty = true;
        CreateHUDTimer();
        UpdateHUD();
        sMsg = "已开启HUD显示";
    }

    if (client == 0)
        PrintToServer("[提示] %s.", sMsg); //服务端控制台/RCON执行.
    else
        ReplyToCommand(client, "\x04[提示]\x03%s\x05.", sMsg);

    return Plugin_Handled;
}

// ====================================================================================================
// sm_offhud / sm_onhud - 所有玩家可用, 开关自己的HUD.
//   sm_offhud [name|#userid]   : 无参数=自己; ROOT管理员带参数=指定单个玩家.
//   sm_onhud  [name|#userid]   : 同上.
// ====================================================================================================
public Action CommandOffHud(int client, int args)
{
    return CommandSetHud(client, args, false);
}

public Action CommandOnHud(int client, int args)
{
    return CommandSetHud(client, args, true);
}

Action CommandSetHud(int admin, int args, bool bVisible)
{
    if (args > 0)
    {
        if (admin != 0 && !(GetUserFlagBits(admin) & ADMFLAG_ROOT))
        {
            ReplyToCommand(admin, "\x04[提示]\x05你无权指定其他玩家, 只能开关自己的HUD.");
            return Plugin_Handled;
        }

        return CommandSetHudTarget(admin, bVisible);
    }

    if (admin == 0)
    {
        PrintToServer("[提示] 用法: sm_onhud <name|#userid> / sm_offhud <name|#userid>");
        return Plugin_Handled;
    }

    if (!CheckHUDHookReady(admin))
        return Plugin_Handled;

    bool bNewHidden = !bVisible;
    if (g_bHUDHidden[admin] == bNewHidden)
    {
        ReplyToCommand(admin, "\x04[提示]\x05你的HUD已经是%s状态.", bVisible ? "开启" : "关闭");
        return Plugin_Handled;
    }

    g_bHUDHidden[admin] = bNewHidden;
    if (bVisible)
        RestorePlayerHUD(admin);
    ForceHUDUpdate();

    ReplyToCommand(admin, "\x04[提示]\x03已%s\x05 你的HUD显示.", bVisible ? "开启" : "关闭");
    LogAction(admin, admin, "\"%N\" %s了自己的HUD显示", admin, bVisible ? "开启" : "关闭");

    return Plugin_Handled;
}

// ROOT管理员/服务端控制台: 只开关指定单个玩家的HUD显示.
Action CommandSetHudTarget(int admin, bool bVisible)
{
    if (!CheckHUDHookReady(admin))
        return Plugin_Handled;

    char sTarget[64];
    GetCmdArg(1, sTarget, sizeof(sTarget));

    char sTargetName[MAX_TARGET_LENGTH];
    int iTargetList[MAXPLAYERS];
    int iTargetCount;
    bool bTnIsMl;

    if ((iTargetCount = ProcessTargetString(
            sTarget,
            admin,
            iTargetList,
            MAXPLAYERS,
            COMMAND_FILTER_NO_BOTS | COMMAND_FILTER_NO_MULTI,
            sTargetName,
            sizeof(sTargetName),
            bTnIsMl)) <= 0)
    {
        ReplyToTargetError(admin, iTargetCount);
        return Plugin_Handled;
    }

    int target = iTargetList[0];
    bool bNewHidden = !bVisible;

    if (g_bHUDHidden[target] == bNewHidden)
    {
        ReplyToCommand(admin, "\x04[提示]\x03%s\x05 的HUD已经是%s状态.", sTargetName, bVisible ? "开启" : "关闭");
        return Plugin_Handled;
    }

    g_bHUDHidden[target] = bNewHidden;
    if (bVisible)
        RestorePlayerHUD(target);
    ForceHUDUpdate();

    if (bVisible)
    {
        ReplyToCommand(admin, "\x04[提示]\x03%s\x05 的HUD显示已开启.", sTargetName);
        LogAction(admin, target, "\"%N\" 开启了 \"%N\" 的HUD显示", admin, target);
        if (admin != target)
            PrintToChat(target, "\x04[提示]\x05管理员已为你开启HUD显示.");
    }
    else
    {
        ReplyToCommand(admin, "\x04[提示]\x03%s\x05 的HUD显示已关闭.", sTargetName);
        LogAction(admin, target, "\"%N\" 关闭了 \"%N\" 的HUD显示", admin, target);
        if (admin != target)
            PrintToChat(target, "\x04[提示]\x05管理员已为你关闭HUD显示.");
    }

    return Plugin_Handled;
}

bool CheckHUDHookReady(int client)
{
    if (!g_bSendProxyAvailable)
    {
        ReplyToCommand(client, "\x04[提示]\x05此功能需要 SendProxy 扩展 (sendproxy.ext), 请先安装 Left4SendProxy.");
        return false;
    }

    if (GetFeatureStatus(FeatureType_Native, "SendProxy_HookGameRules") != FeatureStatus_Available)
    {
        ReplyToCommand(client, "\x04[提示]\x05SendProxy 扩展尚未完全加载, 请稍后再试.");
        return false;
    }

    if (!g_bHUDSendProxyHooked)
    {
        ReplyToCommand(client, "\x04[提示]\x05SendProxy 的 HUD hook 尚未就绪, 请稍后再试.");
        return false;
    }

    return true;
}

public Action CommandHudDebug(int client, int args)
{
    if (client != 0 && !(GetUserFlagBits(client) & ADMFLAG_ROOT))
    {
        ReplyToCommand(client, "\x04[提示]\x05无权使用.");
        return Plugin_Handled;
    }

    ReplyToCommand(client,
        "[ScriptedHUD] FeatureStatus=%d | LibExists(sendproxy2)=%d | hooked=%d | attempts=%d | myHidden=%d",
        GetFeatureStatus(FeatureType_Native, "SendProxy_HookGameRules"),
        LibraryExists("sendproxy2") ? 1 : 0,
        g_bHUDSendProxyHooked ? 1 : 0,
        g_iHookHUDAttempts,
        g_bHUDHidden[client]);

    return Plugin_Handled;
}

// 标记内容已变并立即发送一次 (用于开关HUD, 即使文字内容没变也要让客户端重收 flags).
void ForceHUDUpdate()
{
    g_bHUDDirty = true;

    if (g_bHUDEnabled)
        UpdateHUD();
}

//延迟一帧清除HUD.
public void OnNextFrameClearHUD(any data)
{
    //同一帧内可能先关后开, 此时不能清除重新开启后的HUD.
    if (!g_bHUDEnabled)
        ClearHUD();
}

// 仅用于恢复之前 hidehud 测试可能隐藏的原生UI; 不再用它隐藏.
void RestorePlayerHUD(int client)
{
    ClientCommand(client, "hidehud 0");
}

// ====================================================================================================
void CreateHUDTimer()
{
    delete g_hTimerHUD;
    // 不能加 TIMER_FLAG_NO_MAPCHANGE: 换图时 SourceMod 会杀掉 timer 但 g_hTimerHUD 仍是旧 Handle,
    // 下一张图 OnConfigsExecuted 再 delete 会报 "Handle is invalid". UpdateHUD 内部已有实体保护.
    g_hTimerHUD = CreateTimer(HUD_CHECK_INTERVAL, TimerUpdateHUD, _, TIMER_REPEAT);
}

public Action TimerUpdateHUD(Handle timer)
{
    UpdateFixTeamShuffleHUD();
    UpdateHUD();
    return Plugin_Continue;
}

// ====================================================================================================
// 清除所有HUD槽位.
void ClearHUD()
{
    if (FindGameRulesEntity() == INVALID_ENT_REFERENCE)
        return; //换图瞬间没有 GameRules proxy, 直接跳过.

    GameRules_SetProp("m_iScriptedHUDFlags", HUD_FLAG_NOTVISIBLE, _, HUD1);
    GameRules_SetPropString("m_szScriptedHUDStringSet", "", _, HUD1);
    GameRules_SetProp("m_iScriptedHUDFlags", HUD_FLAG_NOTVISIBLE, _, HUD2);
    GameRules_SetPropString("m_szScriptedHUDStringSet", "", _, HUD2);
}

// ====================================================================================================
// Left4SendProxy 逐客户端 hook: 只给被标记的客户端发送 HUD_FLAG_NOTVISIBLE.
// ====================================================================================================
public Action SendProxy_HUDFlagsChanged(const char[] prop, int &value, int element, int client)
{
    if (client >= 1 && client <= MaxClients && g_bHUDHidden[client])
    {
        value = HUD_FLAG_NOTVISIBLE;
        return Plugin_Changed;
    }

    return Plugin_Continue;
}

void TryHookHUDSendProxy()
{
    if (!g_bSendProxyAvailable || g_bHUDSendProxyHooked)
        return;

    // 扩展刚注册 library 时 natives 可能还没注册完, 稍后重试.
    if (GetFeatureStatus(FeatureType_Native, "SendProxy_HookGameRules") != FeatureStatus_Available)
    {
        ScheduleHUDHookRetry();
        return;
    }

    // 防止扩展在 GameRules proxy 尚未创建时调用 native 报错.
    if (FindGameRulesEntity() == INVALID_ENT_REFERENCE)
    {
        ScheduleHUDHookRetry();
        return;
    }

    bool bHooked1 = SendProxy_HookGameRules("m_iScriptedHUDFlags", Prop_Int, SendProxy_HUDFlagsChanged, HUD1);
    bool bHooked2 = SendProxy_HookGameRules("m_iScriptedHUDFlags", Prop_Int, SendProxy_HUDFlagsChanged, HUD2);

    if (bHooked1 && bHooked2)
    {
        g_bHUDSendProxyHooked = true;
        return;
    }

    ScheduleHUDHookRetry();
}

void ScheduleHUDHookRetry()
{
    if (g_iHookHUDAttempts++ >= 20)
        return;

    CreateTimer(1.0, Timer_RetryHookHUDSendProxy, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_RetryHookHUDSendProxy(Handle timer)
{
    TryHookHUDSendProxy();
    return Plugin_Stop;
}

// 找到 L4D2 的 CTerrorGameRulesProxy 实体（SendProxy 的 GameRules hook 需要它存在）.
int FindGameRulesEntity()
{
    int entity = FindEntityByClassname(-1, "terror_gamerules");
    if (entity == INVALID_ENT_REFERENCE)
    {
        int maxEntities = GetEntityCount();
        for (int i = MaxClients + 1; i < maxEntities; i++)
        {
            if (!IsValidEntity(i))
                continue;

            char sNetClass[64];
            if (GetEntityNetClass(i, sNetClass, sizeof(sNetClass)) && StrEqual(sNetClass, "CTerrorGameRulesProxy"))
                return i;
        }

        return INVALID_ENT_REFERENCE;
    }

    char sNetClass[64];
    if (GetEntityNetClass(entity, sNetClass, sizeof(sNetClass)) && StrEqual(sNetClass, "CTerrorGameRulesProxy"))
        return entity;

    return INVALID_ENT_REFERENCE;
}

// ====================================================================================================
// l4d2_fix_team_shuffle_edi 修复队伍 HUD_TICKER (槽位6, 带背景)
// ====================================================================================================
void UpdateFixTeamShuffleHUD()
{
    if (!g_bFixTeamShuffleAvailable)
    {
        if (g_bFixHUDVisible)
            HideFixHUD();
        return;
    }

    if (GetFeatureStatus(FeatureType_Native, "L4D2_FixTeamShuffle_IsFixComplete") != FeatureStatus_Available)
        return;

    bool bInProgress = !L4D2_FixTeamShuffle_IsFixComplete();

    if (bInProgress && !g_bFixTeamShuffleInProgress)
    {
        StartFixHUD();
    }
    else if (!bInProgress && g_bFixTeamShuffleInProgress)
    {
        CompleteFixHUD();
    }
}

void StartFixHUD()
{
    g_bFixTeamShuffleInProgress = true;
    g_iFixDotCount = 0;

    // 修复队伍提示优先: 结束仍在展示的局末趣文 (两者位置接近, 同时显示会互相压字).
    if (g_bFunFactHUDVisible)
        HideFunFactHUD();

    g_bFunFactPending = false;

    ShowFixHUDText(FIX_MSG_BASE);

    delete g_hFixAnimTimer;
    g_hFixAnimTimer = null;
    g_hFixAnimTimer = CreateTimer(FIX_ANIM_INTERVAL, Timer_FixAnim, _, TIMER_REPEAT);

    delete g_hFixDoneTimer;
    g_hFixDoneTimer = null;
}

public Action Timer_FixAnim(Handle timer)
{
    if (!g_bFixTeamShuffleInProgress)
        return Plugin_Stop;

    g_iFixDotCount++;
    if (g_iFixDotCount > FIX_MSG_MAX_DOTS)
        g_iFixDotCount = 0;

    char sMsg[512];
    strcopy(sMsg, sizeof(sMsg), FIX_MSG_BASE);
    for (int i = 0; i < g_iFixDotCount; i++)
        StrCat(sMsg, sizeof(sMsg), ".");

    ShowFixHUDText(sMsg);
    return Plugin_Continue;
}

void ShowFixHUDText(const char[] sText)
{
    if (FindGameRulesEntity() == INVALID_ENT_REFERENCE)
        return;

    GameRules_SetProp("m_iScriptedHUDFlags", FIX_HUD_FLAGS, _, HUD_TICKER);
    GameRules_SetPropFloat("m_fScriptedHUDPosX", FIX_HUD_X, HUD_TICKER);
    GameRules_SetPropFloat("m_fScriptedHUDPosY", FIX_HUD_Y, HUD_TICKER);
    GameRules_SetPropFloat("m_fScriptedHUDWidth", FIX_HUD_WIDTH, HUD_TICKER);
    GameRules_SetPropFloat("m_fScriptedHUDHeight", FIX_HUD_HEIGHT, HUD_TICKER);
    GameRules_SetPropString("m_szScriptedHUDStringSet", sText, _, HUD_TICKER);
    g_bFixHUDVisible = true;
}

void CompleteFixHUD()
{
    g_bFixTeamShuffleInProgress = false;

    delete g_hFixAnimTimer;
    g_hFixAnimTimer = null;

    ShowFixHUDText(FIX_MSG_DONE);

    delete g_hFixDoneTimer;
    g_hFixDoneTimer = null;
    g_hFixDoneTimer = CreateTimer(FIX_DONE_HIDE_TIME, Timer_HideFixHUD);
}

public Action Timer_HideFixHUD(Handle timer)
{
    // 不能在回调里 delete 自己; 只清空句柄和 HUD 槽位.
    g_hFixDoneTimer = null;
    ClearFixHUDSlot();
    return Plugin_Stop;
}

void HideFixHUD()
{
    delete g_hFixAnimTimer;
    g_hFixAnimTimer = null;
    delete g_hFixDoneTimer;
    g_hFixDoneTimer = null;

    ClearFixHUDSlot();
}

void ClearFixHUDSlot()
{
    g_bFixTeamShuffleInProgress = false;
    g_iFixDotCount = 0;

    if (FindGameRulesEntity() == INVALID_ENT_REFERENCE)
    {
        g_bFixHUDVisible = false;
        return;
    }

    GameRules_SetProp("m_iScriptedHUDFlags", HUD_FLAG_NOTVISIBLE, _, HUD_TICKER);
    GameRules_SetPropString("m_szScriptedHUDStringSet", "", _, HUD_TICKER);
    g_bFixHUDVisible = false;
}

public void L4D2_FixTeamShuffle_OnFixComplete()
{
    CompleteFixHUD();
}

// ====================================================================================================
// 局末趣文 HUD (独立槽位 FUNFACT_HUD)
//    由 l4d2_playstats_tranchi 在回合结束时调用, 一次把多条趣文(每条一行)传进来, 这里轮播.
//
//    为什么不能"只写一次":
//      1) 6 号 HUD_TICKER 是游戏自带 ticker 的槽位, 回合结束时游戏正在往那里写结算/奖励提示,
//         只写一次会立刻被游戏覆盖;
//      2) 回合结束~下一回合开始这段时间屏幕上先是记分板/过渡画面, 脚本 HUD 会被盖住,
//         即使写进去了玩家也看不到.
//    因此这里: 独立槽位 + 每 FUNFACT_REFRESH_INTERVAL 秒重写当前这条, 直到窗口用完
//    或到达 FUNFACT_MAX_DISPLAY 上限.
//
//    轮播规则: 槽位一次只放一条; 每 FUNFACT_FACT_INTERVAL 秒(0.5 秒)换成池内下一条"还没显示过的"
//    (池内都显示过后就停在最后一条, 不回头重播); 池内只有一条时整段窗口都显示它, 不换条.
//    池子内容由调用方决定 —— l4d2_playstats_tranchi 当前只送"本回合趣文", 全场趣文走它自己的聊天那一条.
// ====================================================================================================
public int Native_ShowRoundFunFact(Handle plugin, int numParams)
{
    if (numParams < 2)
        return 0;

    // 整段文本: 一行一条趣文 (单条调用方传一行, 与旧版行为一致).
    static char sText[FUNFACT_INPUT_MAX];
    GetNativeString(1, sText, sizeof(sText));

    if (sText[0] == '\0')
        return 0;

    float fHideTime = GetNativeCell(2);

    // 修复队伍进行中时, 趣文跳过(修复提示优先).
    if (g_bFixTeamShuffleInProgress)
        return 0;

    if (BuildFunFactPool(sText) <= 0)
        return 0;

    StartFunFactHUD((fHideTime > 0.0) ? fHideTime : FUNFACT_HIDE_DEFAULT);

    return 1;
}

// 把调用方给的整段趣文按行拆成轮播池: 逐条去掉聊天颜色码(\x01-\x05, 脚本 HUD 不解析, 会画成方块)
// 并裁掉首尾空白. 返回实际入池条数.
int BuildFunFactPool(const char[] sFacts)
{
    g_iFunFactPoolCount = 0;
    g_iFunFactPoolIndex = 0;

    // 多出来的行直接丢弃(copyRemainder 默认 false), 只保留前 FUNFACT_POOL_MAX 条.
    int iLines = ExplodeString(sFacts, "\n", g_sFunFactPool, FUNFACT_POOL_MAX, FUNFACT_TEXT_MAX);

    for (int i = 0; i < iLines; i++)
    {
        StripFunFactChatColors(g_sFunFactPool[i]);
        TrimFunFactText(g_sFunFactPool[i]);

        if (g_sFunFactPool[i][0] == '\0')
            continue;

        // 跳过空行后往前压紧.
        if (i != g_iFunFactPoolCount)
            strcopy(g_sFunFactPool[g_iFunFactPoolCount], FUNFACT_TEXT_MAX, g_sFunFactPool[i]);

        g_iFunFactPoolCount++;
    }

    return g_iFunFactPoolCount;
}

// 从池子第一条开始显示(整段窗口重新计时).
void StartFunFactHUD(float fDuration)
{
    if (g_iFunFactPoolCount <= 0)
        return;

    g_iFunFactPoolIndex = 0;
    ResumeFunFactHUD(fDuration);
}

// 开启/重启一次展示窗口: 从当前这条继续轮(跨回合续轮时不重置下标).
void ResumeFunFactHUD(float fDuration)
{
    if (g_iFunFactPoolCount <= 0)
        return;

    float fNow = GetGameTime();
    g_fFunFactExpire = fNow + fDuration;
    g_fFunFactHardExpire = fNow + fDuration + FUNFACT_MAX_DISPLAY;
    g_fFunFactNextSwitch = fNow + FUNFACT_FACT_INTERVAL;
    g_bFunFactHUDVisible = true;
    g_bFunFactPending = (g_iFunFactPoolIndex + 1 < g_iFunFactPoolCount);

    // 立即显示, 不等第一个 tick.
    ShowFunFactHUDText(g_sFunFactPool[g_iFunFactPoolIndex]);

    delete g_hFunFactTimer;
    g_hFunFactTimer = CreateTimer(FUNFACT_REFRESH_INTERVAL, Timer_FunFactHUD, _, TIMER_REPEAT);
}

public Action Timer_FunFactHUD(Handle timer)
{
    float fNow = GetGameTime();

    if (!g_bFunFactHUDVisible || fNow >= g_fFunFactExpire || fNow >= g_fFunFactHardExpire)
    {
        // 不能在回调里 delete 自己; 只清句柄和槽位.
        g_hFunFactTimer = null;
        HideFunFactHUD();
        return Plugin_Stop;
    }

    // 到点换下一条"还没显示过的"; 池内都显示过了就停在最后一条.
    // FUNFACT_FACT_INTERVAL 与重写间隔相等时每次 tick 都该换下一条, 所以放宽 0.01 秒兜住浮点/帧抖动.
    if (fNow + 0.01 >= g_fFunFactNextSwitch && g_iFunFactPoolIndex + 1 < g_iFunFactPoolCount)
    {
        g_iFunFactPoolIndex++;
        g_bFunFactPending = (g_iFunFactPoolIndex + 1 < g_iFunFactPoolCount);

        // 从当前时间重新起步(不追帧): 卡顿/暂停后不会连跳好几条.
        g_fFunFactNextSwitch = fNow + FUNFACT_FACT_INTERVAL;
    }

    // 游戏/其它插件可能已经清掉或改写了该槽位: 每次重新写入整组属性, 保证整段显示时间都可见.
    ShowFunFactHUDText(g_sFunFactPool[g_iFunFactPoolIndex]);
    return Plugin_Continue;
}

void ShowFunFactHUDText(const char[] sText)
{
    if (FindGameRulesEntity() == INVALID_ENT_REFERENCE)
        return;

    GameRules_SetProp("m_iScriptedHUDFlags", FUNFACT_HUD_FLAGS, _, FUNFACT_HUD);
    GameRules_SetPropFloat("m_fScriptedHUDPosX", FUNFACT_HUD_X, FUNFACT_HUD);
    GameRules_SetPropFloat("m_fScriptedHUDPosY", FUNFACT_HUD_Y, FUNFACT_HUD);
    GameRules_SetPropFloat("m_fScriptedHUDWidth", FUNFACT_HUD_WIDTH, FUNFACT_HUD);
    GameRules_SetPropFloat("m_fScriptedHUDHeight", FUNFACT_HUD_HEIGHT, FUNFACT_HUD);
    GameRules_SetPropString("m_szScriptedHUDStringSet", sText, _, FUNFACT_HUD);
    g_bFunFactHUDVisible = true;
}

void HideFunFactHUD()
{
    ClearFunFactHUDSlot();

    g_bFunFactHUDVisible = false;
    g_iFunFactPoolCount = 0;
    g_iFunFactPoolIndex = 0;
    g_bFunFactPending = false;

    delete g_hFunFactTimer;
    g_hFunFactTimer = null;
}

// 当前正在显示的那条趣文(池空时给空串).
void GetFunFactCurrentText(char[] sBuffer, int iLen)
{
    if (g_iFunFactPoolCount <= 0 || g_iFunFactPoolIndex < 0 || g_iFunFactPoolIndex >= g_iFunFactPoolCount)
    {
        sBuffer[0] = '\0';
        return;
    }

    strcopy(sBuffer, iLen, g_sFunFactPool[g_iFunFactPoolIndex]);
}

// 只有当槽位里还是我们写进去的文字时才清空: 若期间游戏/其它插件改写了该槽位, 保持原样不破坏它们.
void ClearFunFactHUDSlot()
{
    if (FindGameRulesEntity() == INVALID_ENT_REFERENCE)
        return;

    char sOurs[FUNFACT_TEXT_MAX];
    GetFunFactCurrentText(sOurs, sizeof(sOurs));

    char sCurrent[FUNFACT_TEXT_MAX];
    GameRules_GetPropString("m_szScriptedHUDStringSet", sCurrent, sizeof(sCurrent), FUNFACT_HUD);

    if (sOurs[0] != '\0' && sCurrent[0] != '\0' && !StrEqual(sCurrent, sOurs))
        return;

    GameRules_SetProp("m_iScriptedHUDFlags", HUD_FLAG_NOTVISIBLE, _, FUNFACT_HUD);
    GameRules_SetPropString("m_szScriptedHUDStringSet", "", _, FUNFACT_HUD);
}

// 去掉聊天颜色控制码 \x01-\x05 (PrintToChat 专用, 脚本 HUD 不认识).
void StripFunFactChatColors(char[] sText)
{
    int iWrite = 0;

    for (int iRead = 0; sText[iRead] != '\0'; iRead++)
    {
        if (sText[iRead] >= 1 && sText[iRead] <= 5)
            continue;

        sText[iWrite++] = sText[iRead];
    }

    sText[iWrite] = '\0';
}

// 去掉首尾空白/换行: HUD 每行是单行框, 换行会撑高并挤掉正文(轮播池里每条都已拆成单独一行).
void TrimFunFactText(char[] sText)
{
    int iStart = 0;
    while (sText[iStart] == ' ' || sText[iStart] == '\t' || sText[iStart] == '\r' || sText[iStart] == '\n')
        iStart++;

    int iEnd = strlen(sText);
    while (iEnd > iStart && (sText[iEnd - 1] == ' ' || sText[iEnd - 1] == '\t' || sText[iEnd - 1] == '\r' || sText[iEnd - 1] == '\n'))
        iEnd--;

    // 统一在这里收尾: 全空白输入也会得到空串.
    int iWrite = 0;
    for (int i = iStart; i < iEnd; i++)
        sText[iWrite++] = sText[i];

    sText[iWrite] = '\0';
}

// ====================================================================================================
// 按需更新: 内容/标志与上次发送的一致且无强制标记时直接跳过, 不调用 GameRules_SetProp*.
// ====================================================================================================
void UpdateHUD()
{
    if (!g_bHUDEnabled)
        return;

    // 开图前/换图瞬间 GameRules proxy 可能不存在, 此时不能调用 GameRules_SetProp*.
    if (FindGameRulesEntity() == INVALID_ENT_REFERENCE)
    {
        g_bHUDDirty = true; //等实体存在后强制补发一次.
        return;
    }

    GetHUD_Texts();

    bool bTankAlive = HasAnyTankAlive();
    int iFlags1 = bTankAlive ? (HUD1_FLAGS | HUD_FLAG_BLINK) : HUD1_FLAGS;
    int iFlags2 = HUD2_FLAGS;

    bool bChanged1 = g_bHUDDirty || iFlags1 != g_iHUDLastFlags[HUD1] || !StrEqual(g_sHUD_TextArray[HUD1], g_sHUD_LastTextArray[HUD1]);
    bool bChanged2 = g_bHUDDirty || iFlags2 != g_iHUDLastFlags[HUD2] || !StrEqual(g_sHUD_TextArray[HUD2], g_sHUD_LastTextArray[HUD2]);

    if (!bChanged1 && !bChanged2)
        return;

    g_bHUDDirty = false;

    if (bChanged1)
    {
        g_iHUDLastFlags[HUD1] = iFlags1;
        strcopy(g_sHUD_LastTextArray[HUD1], sizeof(g_sHUD_LastTextArray[]), g_sHUD_TextArray[HUD1]);

        // HUD1: 进度/坦克/女巫/奖励分. 有坦克存活时闪烁.
        GameRules_SetProp("m_iScriptedHUDFlags", iFlags1, _, HUD1);
        GameRules_SetPropFloat("m_fScriptedHUDPosX", HUD1_X, HUD1);
        GameRules_SetPropFloat("m_fScriptedHUDPosY", HUD1_Y, HUD1);
        GameRules_SetPropFloat("m_fScriptedHUDWidth", HUD_WIDTH, HUD1);
        GameRules_SetPropFloat("m_fScriptedHUDHeight", HUD_HEIGHT * (CountCharInString(g_sHUD_TextArray[HUD1], '\n') + 1), HUD1);
        GameRules_SetPropString("m_szScriptedHUDStringSet", g_sHUD_TextArray[HUD1], _, HUD1);
    }

    if (bChanged2)
    {
        g_iHUDLastFlags[HUD2] = iFlags2;
        strcopy(g_sHUD_LastTextArray[HUD2], sizeof(g_sHUD_LastTextArray[]), g_sHUD_TextArray[HUD2]);

        // HUD2: 服务器名字/人数/时间.
        GameRules_SetProp("m_iScriptedHUDFlags", iFlags2, _, HUD2);
        GameRules_SetPropFloat("m_fScriptedHUDPosX", HUD2_X, HUD2);
        GameRules_SetPropFloat("m_fScriptedHUDPosY", HUD2_Y, HUD2);
        GameRules_SetPropFloat("m_fScriptedHUDWidth", HUD_WIDTH, HUD2);
        GameRules_SetPropFloat("m_fScriptedHUDHeight", HUD_HEIGHT * (CountCharInString(g_sHUD_TextArray[HUD2], '\n') + 1), HUD2);
        GameRules_SetPropString("m_szScriptedHUDStringSet", g_sHUD_TextArray[HUD2], _, HUD2);
    }
}

// ====================================================================================================
void GetHUD_Texts()
{
    GetHUD1_Text(g_sHUD_TextArray[HUD1], sizeof(g_sHUD_TextArray[]));
    GetHUD2_Text(g_sHUD_TextArray[HUD2], sizeof(g_sHUD_TextArray[]));
}

// ====================================================================================================
void GetHUD1_Text(char[] output, int size)
{
    bool IsStaticTank = false, IsStaticWitch = false;
    ConVar cv;
    if (g_bWitchAndTankSystemAvailable)
    {
        cv = FindConVar("sm_tank_can_spawn");
        if (cv != null && cv.IntValue)
        {
            if (IsStaticTankMap())
                IsStaticTank = false;
            else
                IsStaticTank = true;
        }
        cv = FindConVar("sm_witch_can_spawn");
        if (cv != null && cv.IntValue)
        {
            if (IsStaticWitchMap())
                IsStaticWitch = false;
            else
                IsStaticWitch = true;
        }
    }
    FormatEx(output, size, "\0");

    // left4dhooks 卸载/重载瞬间其 native 会解绑, 调用前必须确认可用, 否则报 "Native is not bound".
    bool bL4DReady = LibraryExists("left4dhooks")
        && GetFeatureStatus(FeatureType_Native, "L4D2Direct_GetTerrorNavArea") == FeatureStatus_Available;

    if (bL4DReady)
    {
        int boss_proximity = RoundToNearest(GetBossProximity() * 100.0);
        int g_fWitchPercent, g_fTankPercent;
        g_fTankPercent = RoundToNearest(GetTankFlow(0) * 100.0);
        g_fWitchPercent = RoundToNearest(GetWitchFlow(0) * 100.0);
        FormatEx(output, size, "进度: [ %d%% ]", boss_proximity);
        if (IsStaticTank || (!g_bWitchAndTankSystemAvailable && g_fTankPercent))
        {
            Format(output, size, "%s    坦克: [ %d%% ]", output, g_fTankPercent);
        }
        else if (!IsStaticTank)
        {
            Format(output, size, "%s    坦克: [ 固定 ]", output);
        }
        if (IsStaticWitch || (!g_bWitchAndTankSystemAvailable && g_fWitchPercent))
        {
            Format(output, size, "%s    女巫: [ %d%% ]", output, g_fWitchPercent);
        }
        else if (!IsStaticWitch)
        {
            Format(output, size, "%s    女巫: [ 固定 ]", output);
        }
    }
    else
    {
        // left4dhooks 暂不可用: 进度无法计算, 显示占位; 静态 boss 信息仍可来自 witch_and_tankifier.
        FormatEx(output, size, "进度: [ -- ]");
        if (IsStaticTank)
            Format(output, size, "%s    坦克: [ 固定 ]", output);
        if (IsStaticWitch)
            Format(output, size, "%s    女巫: [ 固定 ]", output);
    }

    if (g_bhybridScoringAvailable)
    {
        float maxBouns = float(SMPlus_GetHealthBonus()) + float(SMPlus_GetDamageBonus()) + float(SMPlus_GetPillsBonus());
        float healthBonusPercent = float(SMPlus_GetHealthBonus()) / float(SMPlus_GetMaxHealthBonus()) * 100;
        float damageBonusPercent = float(SMPlus_GetDamageBonus()) / float(SMPlus_GetMaxDamageBonus()) * 100;
        float pillsBpnusPercent = float(SMPlus_GetPillsBonus()) / float(SMPlus_GetMaxPillsBonus()) * 100;
        Format(output, size, "%s\n奖励分: %.0f [实血分: %.0f%% | 虚血分: %.0f%% | 药分: %.0f%% ]", output, maxBouns, healthBonusPercent, damageBonusPercent, pillsBpnusPercent);
    }
}

// ====================================================================================================
float GetBossProximity()
{
    float proximity = GetMaxSurvivorCompletion() + g_hVsBossBuffer.FloatValue / L4D2Direct_GetMapMaxFlowDistance();

    return (proximity > 1.0) ? 1.0 : proximity;
}

float GetMaxSurvivorCompletion()
{
    float flow = 0.0, tmp_flow = 0.0, origin[3];
    Address pNavArea;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i))
        {
            GetClientAbsOrigin(i, origin);
            pNavArea = L4D2Direct_GetTerrorNavArea(origin);
            if (pNavArea == Address_Null)
                pNavArea = L4D_GetNearestNavArea(origin, 300.0, false, false, false, 2);
            if (pNavArea != Address_Null)
            {
                tmp_flow = L4D2Direct_GetTerrorNavAreaFlow(pNavArea);
                flow = (flow > tmp_flow) ? flow : tmp_flow;
            }
        }
    }

    return (flow / L4D2Direct_GetMapMaxFlowDistance());
}

// 返回指定回合的坦克刷新路程.
float GetTankFlow(int round)
{
    return L4D2Direct_GetVSTankFlowPercent(round);
}

// 返回指定回合的女巫刷新路程.
float GetWitchFlow(int round)
{
    return L4D2Direct_GetVSWitchFlowPercent(round);
}

// 当前在游戏的真人玩家数量（排除连接中）.
int GetPlayerNumber()
{
    int number = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientConnected(i) && IsClientInGame(i) && !IsFakeClient(i))
            number++;
    }
    return number;
}

// 总在线真人玩家数量（包括连接中）.
int GetConnectedNumber()
{
    int number = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientConnected(i) && !IsFakeClient(i))
            number++;
    }
    return number;
}

// ====================================================================================================
void GetHUD2_Text(char[] output, int size)
{
    FormatEx(output, size, "\0");
    int PlayerLimit = GetConVarInt(FindConVar("sv_maxplayers"));
    char hostname[64];
    char sTime[16];
    FindConVar("hostname").GetString(hostname, sizeof(hostname));
    FormatTime(sTime, sizeof(sTime), "%H:%M:%S", GetTime());
    FormatEx(output, size, "%s(%d/%d/%d)\n%s !onhud/!offhud开关HUD", hostname, GetPlayerNumber(), GetConnectedNumber(), PlayerLimit, sTime);
}

// ====================================================================================================
// Helpers
// ====================================================================================================
int GetZombieClass(int client)
{
    return (GetEntProp(client, Prop_Send, "m_zombieClass"));
}

bool IsPlayerGhost(int client)
{
    return (GetEntProp(client, Prop_Send, "m_isGhost") == 1);
}

bool IsPlayerIncapacitated(int client)
{
    return (GetEntProp(client, Prop_Send, "m_isIncapacitated") == 1);
}

bool IsPlayerTank(int client)
{
    if (GetClientTeam(client) != TEAM_INFECTED)
        return false;

    if (GetZombieClass(client) != L4D2_ZOMBIECLASS_TANK)
        return false;

    if (!IsPlayerAlive(client))
        return false;

    if (IsPlayerGhost(client))
        return false;

    return true;
}

// 是否存活中的坦克.
bool HasAnyTankAlive()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client))
            continue;

        if (!IsPlayerTank(client))
            continue;

        if (IsPlayerIncapacitated(client))
            continue;

        return true;
    }

    return false;
}

// 统计字符串中指定字符的出现次数.
int CountCharInString(const char[] str, char c)
{
    int i;
    int count;

    while (str[i] != 0)
    {
        if (str[i++] == c)
            count++;
    }

    return count;
}
