/**
// ====================================================================================================
Change Log:

1.0.3 (applemod)
    - 修复"有时不会消除屏幕暗淡"(暗屏残留)的问题，新增兜底清除逻辑。
      1) 暗屏状态与 ref 列表解耦：新增 gc_bDark[]，只要本次暗屏是本插件施加的，就一定发清除 Fade，
         不再因为团队过滤/玩家离开原队伍/换到旁观者/变成 bot 而提前 return 导致永久黑屏。
      2) "清除 Fade"不再检查团队过滤（原实现：变暗后用 l4d_cloud_screen_fade_team 过滤，换队后
         永远发不出淡入）。变暗侧仍然遵守团队过滤。
      3) OnEntityDestroyed() 的清除条件由 "count == 1"（擦除前长度）改为 "擦除后列表为空"，
         并只处理"确实持有该 ref"的客户端；原实现既会漏清除（列表长度 > 1 时永远不清）也会误清除。
      4) 新增 1 秒兜底计时器（Timer_FadeSafety）：列表里已无存活 ref、或暗屏时长超过
         life + 10 秒时，强制发一次 alpha = 0 的 FFADE_PURGE|FFADE_IN，保证客户端一定恢复。
      5) OnStartTouch 去重 + 先入列表再发淡出，修复"重复进入同一片烟雾 / 倒地后在烟雾里被救起 /
         在烟雾里死亡再复活"导致的 ref 重复累积（累积后列表永远不空，淡入永远不发）。
      6) 每次清除/兜底前先清理已销毁实体的残留 ref（PurgeDeadFadeRefs）。
      7) 新增 OnMapStart / OnMapEnd 全量状态复位；ge_bTriggerFade[] 在实体销毁后立即复位，
         修复实体索引复用导致的误判。
      8) 插件被关闭（enable 0）时主动清除所有玩家残留暗屏。
      9) GetUserMessageId("Fade") 失败（INVALID_MESSAGE_ID）时不再调用 HookUserMessage。
     10) 新增 l4d_cloud_screen_fade_debug（默认 0）用于进服验证日志。
     11) 新增 OnPluginEnd()：卸载/热重载插件前主动清除所有残留暗屏。
     12) 修正 Fade 拦截的"放行票"语义：只认 gc_bDark 单一真源；放行票改为按条精确计数，
         且先消费票再判定拦截（清除消息通常在 gc_bDark 已为 false 之后才发，顺序反了会漏消费，
         票数单向累积后外部 Fade 被误放行）；票的自增条件与 FadeHook 的注册条件严格一致，
         避免 Fade UserMessage 不可用时票数无消费者。
     13) 非暗屏状态下也周期性清理 gc_alFadeRef 里指向已销毁实体的残留项。

1.0.2 (11-August-2022)
    - Fixed resizing not working. (thanks "HarryPotter" for reporting)

1.0.1 (11-August-2022)
    - Added team filter.
    - Fixed fade not triggering for incapacitated clients.

1.0.0 (10-August-2022)
    - Initial release.

// ====================================================================================================
*/

// ====================================================================================================
// Plugin Info - define
// ====================================================================================================
#define PLUGIN_NAME                   "[L4D1 & L4D2] Smoker Cloud Screen Fade"
#define PLUGIN_AUTHOR                 "Mart"
#define PLUGIN_DESCRIPTION            "Adds a blind fade effect while in Smoker cloud"
#define PLUGIN_VERSION                "1.0.3"
#define PLUGIN_URL                    "https://forums.alliedmods.net/showthread.php?t=339035"

// ====================================================================================================
// Plugin Info
// ====================================================================================================
public Plugin myinfo =
{
    name        = PLUGIN_NAME,
    author      = PLUGIN_AUTHOR,
    description = PLUGIN_DESCRIPTION,
    version     = PLUGIN_VERSION,
    url         = PLUGIN_URL
}

// ====================================================================================================
// Includes
// ====================================================================================================
#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

// ====================================================================================================
// Pragmas
// ====================================================================================================
#pragma semicolon 1
#pragma newdecls required

// ====================================================================================================
// Cvar Flags
// ====================================================================================================
#define CVAR_FLAGS                    FCVAR_NOTIFY
#define CVAR_FLAGS_PLUGIN_VERSION     FCVAR_NOTIFY|FCVAR_DONTRECORD|FCVAR_SPONLY

// ====================================================================================================
// Filenames
// ====================================================================================================
#define CONFIG_FILENAME               "l4d_cloud_screen_fade"

// ====================================================================================================
// Defines
// ====================================================================================================
#define TEAM_SPECTATOR                1
#define TEAM_SURVIVOR                 2
#define TEAM_INFECTED                 3
#define TEAM_HOLDOUT                  4

#define FLAG_TEAM_NONE                (0 << 0) // 0 | 0000
#define FLAG_TEAM_SURVIVOR            (1 << 0) // 1 | 0001
#define FLAG_TEAM_INFECTED            (1 << 1) // 2 | 0010
#define FLAG_TEAM_SPECTATOR           (1 << 2) // 4 | 0100
#define FLAG_TEAM_HOLDOUT             (1 << 3) // 8 | 1000

#define L4D_ZOMBIECLASS_SMOKER        1

#define SOLID_BBOX                    2

#define FFADE_IN                      0x0001
#define FFADE_OUT                     0x0002
#define FFADE_STAYOUT                 0x0008
#define FFADE_PURGE                   0x0010

#define SCREENFADE_FRACBITS           (1 << 9) // 512

#define MAXENTITIES                   2048

// ====================================================================================================
// Plugin Cvars
// ====================================================================================================
ConVar g_hCvar_Enabled;
ConVar g_hCvar_Color;
ConVar g_hCvar_Alpha;
ConVar g_hCvar_FadeOutDuration;
ConVar g_hCvar_FadeInDuration;
ConVar g_hCvar_FadeLife;
ConVar g_hCvar_FadeSize;
ConVar g_hCvar_Block;
ConVar g_hCvar_Team;
ConVar g_hCvar_Debug;

// ====================================================================================================
// bool - Plugin Variables
// ====================================================================================================
bool g_bEventsHooked;
bool g_bCvar_Enabled;
bool g_bCvar_RandomColor;
bool g_bCvar_Block;
bool g_bCvar_Debug;

// ====================================================================================================
// int - Plugin Variables
// ====================================================================================================
int g_iCvar_Color[3];
int g_iCvar_Alpha;
int g_iFadeOutDuration;
int g_iFadeInDuration;
int g_iCvar_Team;

// ====================================================================================================
// float - Plugin Variables
// ====================================================================================================
float g_fCvar_FadeOutDuration;
float g_fCvar_FadeInDuration;
float g_fCvar_FadeLife;
float g_fCvar_FadeSize;
float g_vFadeMins[3];
float g_vFadeMaxs[3];

// ====================================================================================================
// string - Plugin Variables
// ====================================================================================================
char g_sCvar_Color[12];
char g_sKillInput[50];

// ====================================================================================================
// UserMsg - Plugin Variables
// ====================================================================================================
UserMsg g_umFade;

// ====================================================================================================
// client - Plugin Variables
// ====================================================================================================
bool gc_bDark[MAXPLAYERS+1];
float gc_fDarkAt[MAXPLAYERS+1];
// 1.0.3: 用计数代替原来的 bool gc_bFade[] 一次性"豁免票"。
// 同一帧内可能先后发出多条属于本插件的 Fade(先变暗后清除), 单个 bool 会被提前消耗,
// 导致真正需要放行的 Fade 被 FadeHook 拦掉 / 或把外部 Fade 误放行。
int gc_iSelfFade[MAXPLAYERS+1];
int gc_iColor[MAXPLAYERS+1][3];
ArrayList gc_alFadeRef[MAXPLAYERS+1];

// ====================================================================================================
// entity - Plugin Variables
// ====================================================================================================
bool ge_bTriggerFade[MAXENTITIES+1];

// ====================================================================================================
// Timer - Plugin Variables
// ====================================================================================================
Handle g_hFadeSafetyTimer = null;

// ====================================================================================================
// Plugin Start
// ====================================================================================================
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    EngineVersion engine = GetEngineVersion();

    if (engine != Engine_Left4Dead && engine != Engine_Left4Dead2)
    {
        strcopy(error, err_max, "This plugin only runs in \"Left 4 Dead\" and \"Left 4 Dead 2\" game");
        return APLRes_SilentFailure;
    }

    return APLRes_Success;
}

/****************************************************************************************************/

public void OnPluginStart()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        gc_alFadeRef[client] = new ArrayList();
    }

    g_umFade = GetUserMessageId("Fade");

    if (g_umFade == INVALID_MESSAGE_ID)
    {
        // 1.0.3: 拿不到 Fade 消息时无法拦截其它淡入淡出, HookUserMessage 会报错刷屏。
        LogError("[l4d_cloud_screen_fade] 无法获取 \"Fade\" UserMessage (INVALID_MESSAGE_ID), 将跳过 Usermessage 拦截.");
    }

    CreateConVar("l4d_cloud_screen_fade_version", PLUGIN_VERSION, PLUGIN_DESCRIPTION, CVAR_FLAGS_PLUGIN_VERSION);
    g_hCvar_Enabled         = CreateConVar("l4d_cloud_screen_fade_enable", "1", "是否启用插件.\n0 = 禁用, 1 = 启用.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_Color           = CreateConVar("l4d_cloud_screen_fade_color", "20 20 20", "褪色的颜色.\n 使用'random'来获得随机颜色.\n使用三个0-255之间的数值，用空格分隔(\"<0-255> <0-255> <0-255>\").", CVAR_FLAGS);
    g_hCvar_Alpha           = CreateConVar("l4d_cloud_screen_fade_alpha", "245", "淡化阿尔法透明度.\n0 = 不可见, 255 = 完全可见.", CVAR_FLAGS, true, 0.0, true, 255.0);
    g_hCvar_FadeOutDuration = CreateConVar("l4d_cloud_screen_fade_out_duration", "0.5", "淡出(开始)时间，单位是秒.", CVAR_FLAGS, true, 0.0);
    g_hCvar_FadeInDuration  = CreateConVar("l4d_cloud_screen_fade_in_duration", "0.5", "淡出(结束)时间，单位是秒.", CVAR_FLAGS, true, 0.0);
    g_hCvar_FadeLife        = CreateConVar("l4d_cloud_screen_fade_life", "14.0", "触发区域在消失前会存在多长时间.", CVAR_FLAGS, true, 0.0);
    g_hCvar_FadeSize        = CreateConVar("l4d_cloud_screen_fade_size", "100.0", "淡出触发区域大小.", CVAR_FLAGS, true, 0.0);
    g_hCvar_Block           = CreateConVar("l4d_cloud_screen_fade_block", "1", "在插件淡出时，阻止应用于客户端的其他淡出效果.\n例如：受到伤害时的红屏.\n0 = 禁用, 1 = 启用.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_Team            = CreateConVar("l4d_cloud_screen_fade_team", "1", " 哪些队伍应该受到该插件的影响.\n0 = 无, 1 = 生还者, 2 = 感染者, 4 = 旁观者, 8 = HOLDOUT(抵抗者?).\n加入大于0的数字表示多个选项.\n例如:3表示启用生还者和感染者.", CVAR_FLAGS, true, 0.0, true, 15.0);
    g_hCvar_Debug           = CreateConVar("l4d_cloud_screen_fade_debug", "0", "调试日志开关.\n0 = 关闭(默认, 不输出任何日志).\n1 = 把每次变暗、每次清除、每次兜底强制清除、每次跳过都写入日志(用 SourceMod 的 logs 或控制台查看).\n仅用于进服排查\"暗屏不消失\", 正常开服请保持 0 以免刷屏.", CVAR_FLAGS, true, 0.0, true, 1.0);

    // Hook plugin ConVars change
    g_hCvar_Enabled.AddChangeHook(Event_ConVarChanged);
    g_hCvar_Color.AddChangeHook(Event_ConVarChanged);
    g_hCvar_Alpha.AddChangeHook(Event_ConVarChanged);
    g_hCvar_FadeOutDuration.AddChangeHook(Event_ConVarChanged);
    g_hCvar_FadeInDuration.AddChangeHook(Event_ConVarChanged);
    g_hCvar_FadeLife.AddChangeHook(Event_ConVarChanged);
    g_hCvar_FadeSize.AddChangeHook(Event_ConVarChanged);
    g_hCvar_Block.AddChangeHook(Event_ConVarChanged);
    g_hCvar_Team.AddChangeHook(Event_ConVarChanged);
    g_hCvar_Debug.AddChangeHook(Event_ConVarChanged);

    // Load plugin configs from .cfg
    //AutoExecConfig(true, CONFIG_FILENAME);

    // Admin Commands
    RegAdminCmd("sm_cloudfade", CmdCloudFade, ADMFLAG_ROOT, "对自身(无参数)或指定目标添加淡入淡出效果。示例：self -> sm_cloudfade / target -> sm_cloudfade @humanss.");
    RegAdminCmd("sm_print_cvars_l4d_cloud_screen_fade", CmdPrintCvars, ADMFLAG_ROOT, "将插件相关的 cvars 及其各自的值打印到控制台.");
}

/****************************************************************************************************/

public void OnConfigsExecuted()
{
    GetCvars();

    HookEvents();
}

/****************************************************************************************************/

void Event_ConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    GetCvars();

    HookEvents();
}

/****************************************************************************************************/

void GetCvars()
{
    g_bCvar_Enabled = g_hCvar_Enabled.BoolValue;
    g_hCvar_Color.GetString(g_sCvar_Color, sizeof(g_sCvar_Color));
    TrimString(g_sCvar_Color);
    g_bCvar_RandomColor = StrEqual(g_sCvar_Color, "random");
    g_iCvar_Color = ConvertRGBToIntArray(g_sCvar_Color);
    g_iCvar_Alpha = g_hCvar_Alpha.IntValue;
    g_fCvar_FadeOutDuration = g_hCvar_FadeOutDuration.FloatValue;
    g_iFadeOutDuration = RoundFloat(g_fCvar_FadeOutDuration * SCREENFADE_FRACBITS);
    g_fCvar_FadeInDuration = g_hCvar_FadeInDuration.FloatValue;
    g_iFadeInDuration = RoundFloat(g_fCvar_FadeInDuration * SCREENFADE_FRACBITS);
    g_fCvar_FadeLife = g_hCvar_FadeLife.FloatValue;
    FormatEx(g_sKillInput, sizeof(g_sKillInput), "OnUser1 !self:Kill::%.1f:-1", g_fCvar_FadeLife);
    g_fCvar_FadeSize = g_hCvar_FadeSize.FloatValue;
    g_vFadeMins[0] = -g_fCvar_FadeSize;
    g_vFadeMins[1] = -g_fCvar_FadeSize;
    g_vFadeMins[2] = 0.0;
    g_vFadeMaxs[0] = g_fCvar_FadeSize;
    g_vFadeMaxs[1] = g_fCvar_FadeSize;
    g_vFadeMaxs[2] = g_fCvar_FadeSize;
    g_bCvar_Block = g_hCvar_Block.BoolValue;
    g_iCvar_Team = g_hCvar_Team.IntValue;
    g_bCvar_Debug = g_hCvar_Debug.BoolValue;
}

/****************************************************************************************************/

void HookEvents()
{
    if (g_bCvar_Enabled && !g_bEventsHooked)
    {
        g_bEventsHooked = true;

        HookEvent("player_death", Event_PlayerDeath);
        HookEvent("player_team", Event_PlayerTeam);

        // 1.0.3: 拿不到 "Fade" UserMessage 时 HookUserMessage 会执行失败并刷错误日志。
        if (g_umFade != INVALID_MESSAGE_ID)
        {
            HookUserMessage(g_umFade, FadeHook, true);
        }

        if (g_hFadeSafetyTimer == null)
        {
            g_hFadeSafetyTimer = CreateTimer(1.0, Timer_FadeSafety, _, TIMER_REPEAT);
        }

        return;
    }

    if (!g_bCvar_Enabled && g_bEventsHooked)
    {
        g_bEventsHooked = false;

        UnhookEvent("player_death", Event_PlayerDeath);
        UnhookEvent("player_team", Event_PlayerTeam);

        if (g_umFade != INVALID_MESSAGE_ID)
        {
            UnhookUserMessage(g_umFade, FadeHook, true);
        }

        // 1.0.3: 插件被关闭时主动清掉所有残留暗屏, 否则关掉插件后玩家会一直黑屏。
        ResetAllStates(true);

        if (g_hFadeSafetyTimer != null)
        {
            delete g_hFadeSafetyTimer;
            g_hFadeSafetyTimer = null;
        }

        return;
    }
}

/****************************************************************************************************/

// 1.0.3: 调试日志。只有在 l4d_cloud_screen_fade_debug = 1 时才输出, 默认完全静默。
void DebugLog(const char[] sMsg, any ...)
{
    if (!g_bCvar_Debug)
        return;

    char sBuffer[256];
    VFormat(sBuffer, sizeof(sBuffer), sMsg, 2);
    LogMessage("[l4d_cloud_screen_fade] %s", sBuffer);
}

/****************************************************************************************************/

public void OnClientDisconnect(int client)
{
    // 1.0.3: 断线前如果还处于暗屏状态, 先尝试补一次清除(客户端此时通常已收不到消息, 属于尽力而为),
    // 更重要的是把状态彻底重置, 防止客户端索引复用后 gc_bDark 残留 -> 新玩家永远等不到"暗屏开始"
    // 或者更糟: 新玩家一进来就被旧状态判定为"已变暗", 兜底计时器立刻替他发一次清除。
    if (gc_bDark[client])
    {
        DebugLog("OnClientDisconnect: 客户端 %d 断线时仍处于暗屏状态, 强制清除.", client);
        ForceClear(client, "OnClientDisconnect");
    }

    gc_iSelfFade[client] = 0;
    gc_bDark[client] = false;
    gc_fDarkAt[client] = 0.0;
    gc_iColor[client] = {0, 0, 0};
    gc_alFadeRef[client].Clear();
}

/****************************************************************************************************/

public void OnMapStart()
{
    // 1.0.3: 换图时实体全部销毁, 但 OnEntityDestroyed 不一定对每个实体都触发,
    // 且 ge_bTriggerFade[] 是实体索引数组, 复用后必然出问题。这里全量复位。
    ResetAllStates(false);
}

/****************************************************************************************************/

public void OnMapEnd()
{
    ResetAllStates(true);
}

/****************************************************************************************************/

// 1.0.3: 插件被 sm plugins unload / 换图热重载时, FFADE_STAYOUT 造成的黑屏不会自己消失
// (UserMessage 的 hook 会被 SourceMod 自动摘掉, 但客户端屏幕上"保持变暗"的状态是引擎侧的)。
// 这里在卸载前补发一次全透明 Fade, 避免卸载插件反而让玩家永久黑屏。
public void OnPluginEnd()
{
    ResetAllStates(true);
}

/****************************************************************************************************/

public void OnEntityDestroyed(int entity)
{
    if (entity < 0 || entity > MAXENTITIES)
        return;

    if (!ge_bTriggerFade[entity])
        return;

    // 1.0.3: 立即复位标记, 防止实体索引复用后新实体被误判为"本插件的烟雾触发器"。
    ge_bTriggerFade[entity] = false;

    int iRef = EntIndexToEntRef(entity);

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client))
            continue;

        int find = gc_alFadeRef[client].FindValue(iRef);
        if (find == -1)
            continue; // 该客户端本来就没在这个触发器里, 不能碰它的暗屏状态

        gc_alFadeRef[client].Erase(find);

        // 1.0.3: 原实现用 count == 1 (擦除前的长度), 列表长度 > 1 时永远不清除 -> 永久黑屏。
        // 改为"擦除后已无生效 ref", 并顺带清掉其它已失效实体的残留 ref。
        PurgeDeadFadeRefs(client);

        if (gc_alFadeRef[client].Length == 0)
        {
            DebugLog("OnEntityDestroyed: 实体 %d 销毁, 客户端 %d 已离开所有烟雾, 执行清除.", entity, client);
            ForceClear(client, "OnEntityDestroyed");
        }
    }
}

/****************************************************************************************************/

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidClient(client))
        return;

    // 1.0.3: 换队/进旁观/死亡后重生都会走这里。
    // 原实现的 PerformFadeIn 有团队过滤: 生还者被烟雾变暗后如果死亡换到旁观者/感染者,
    // 团队过滤会让清除 Fade 直接 return -> 屏幕永久保持 FFADE_STAYOUT 的黑屏。
    // 现在清除侧不再做任何团队过滤, 只要 gc_bDark 为真就一定清。
    if (!gc_bDark[client])
        return;

    gc_alFadeRef[client].Clear();
    DebugLog("Event_PlayerTeam: 客户端 %d 换队(旧队伍 %d -> 新队伍 %d), 执行清除.", client, event.GetInt("oldteam"), event.GetInt("team"));
    ForceClear(client, "Event_PlayerTeam");
}

/****************************************************************************************************/

// 1.0.3: 兜底计时器。1.0.3 之前任何一次 PerformFadeIn 遗漏(实体销毁顺序、ref 残留、换队、断线、
// 插件关闭……)都会让玩家永久黑屏, 因为 FFADE_STAYOUT 是"一直保持"。
// 这里每 1 秒检查一次:
//   - gc_bDark 为真但 ref 列表已空  -> 说明本该清除却没清, 立刻补发;
//   - gc_bDark 为真且暗屏超过 life + 10 秒 -> 无论如何强制清除(触发器最长也就活 life 秒)。
public Action Timer_FadeSafety(Handle timer)
{
    if (!g_bCvar_Enabled)
        return Plugin_Continue;

    float fNow = GetGameTime();

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!gc_bDark[client])
        {
            // 1.0.3: 非暗屏状态下也顺手清理残留 ref。这类残留(PerformFadeOut 因团队过滤没发、
            // 或 OnEndTouch 与 OnEntityDestroyed 的到达顺序不巧)本身不会造成黑屏, 但会让
            // gc_alFadeRef 长期非空, 干扰 "列表为空 -> 清除" 的判定与 sm_print_cvars 的排查。
            if (IsClientInGame(client))
            {
                PurgeDeadFadeRefs(client);
            }

            continue;
        }

        if (!IsClientInGame(client))
        {
            // 已经不在游戏里了, 静默复位, 等索引复用给新玩家。
            gc_bDark[client] = false;
            gc_fDarkAt[client] = 0.0;
            gc_iSelfFade[client] = 0;
            gc_alFadeRef[client].Clear();
            continue;
        }

        PurgeDeadFadeRefs(client);

        if (gc_alFadeRef[client].Length == 0)
        {
            DebugLog("Timer_FadeSafety: 客户端 %d 暗屏中但已无生效触发器, 兜底清除.", client);
            ForceClear(client, "Timer_FadeSafety/empty");
            continue;
        }

        // 硬超时: 触发器的寿命是 l4d_cloud_screen_fade_life 秒, 再给 10 秒余量,
        // 超过这个时间还暗着必然是漏清了。
        if (gc_fDarkAt[client] > 0.0 && (fNow - gc_fDarkAt[client]) > (g_fCvar_FadeLife + 10.0))
        {
            DebugLog("Timer_FadeSafety: 客户端 %d 暗屏已超过 %.1f 秒(上限 %.1f), 强制清除.",
                client, fNow - gc_fDarkAt[client], g_fCvar_FadeLife + 10.0);
            gc_alFadeRef[client].Clear();
            ForceClear(client, "Timer_FadeSafety/timeout");
        }
    }

    return Plugin_Continue;
}

/****************************************************************************************************/

Action FadeHook(UserMsg msg_id, BfRead bf, const int[] players, int playersNum, bool reliable, bool init)
{
    if (!g_bCvar_Block)
        return Plugin_Continue;

    if (playersNum != 1)
        return Plugin_Continue;

    int client = players[0];

    if (!IsValidClient(client))
        return Plugin_Continue;

    if (IsFakeClient(client))
        return Plugin_Continue;

    // 1.0.3: 先消费"放行票", 再判断拦截条件。
    // 顺序很重要: ClearFade/ForceClear 发出的清除消息大多发生在 gc_bDark 已经为 false、
    // ref 列表已经清空之后, 如果先做下面的暗屏判断就会提前 return, 票永远不被消费 ->
    // 票数单向累积, 之后超过票数条的外部 Fade 会被误放行。
    if (gc_iSelfFade[client] > 0)
    {
        gc_iSelfFade[client]--;
        return Plugin_Continue; // 这是本插件自己发的 Fade, 放行
    }

    // 1.0.3: 判断依据从"ref 列表非空"改成"本插件是否正在让该客户端变暗"(gc_bDark)。
    // 原实现 gc_alFadeRef 可能在 PerformFadeOut 之前就被 Push, 或在清除之后仍残留,
    // 导致拦截窗口与真实暗屏状态错位: 该拦的没拦, 该放的被吞。
    // 现在只认 gc_bDark 一个真源: 只有正在被本插件变暗的玩家才拦外部 Fade。
    if (!gc_bDark[client])
        return Plugin_Continue;

    // 正在被本插件变暗, 且不是本插件自己发的 Fade -> 拦掉(例如受伤红屏会覆盖掉我们的暗屏)。
    return Plugin_Handled;
}

/****************************************************************************************************/

void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    float vPos[3];
    vPos[0] = event.GetFloat("victim_x");
    vPos[1] = event.GetFloat("victim_y");
    vPos[2] = event.GetFloat("victim_z");

    if (client == 0)
        return;

    if (GetClientTeam(client) != TEAM_INFECTED)
        return;

    if (GetZombieClass(client) != L4D_ZOMBIECLASS_SMOKER)
        return;

    CreateTriggerFade(vPos);
}

/****************************************************************************************************/

void PerformFadeOut(int client)
{
    if (!IsValidClient(client))
        return;

    if (IsFakeClient(client))
        return;

    if (!(GetTeamFlag(GetClientTeam(client)) & g_iCvar_Team))
        return;

    if (g_bCvar_RandomColor)
    {
        gc_iColor[client][0] = GetRandomInt(0, 255);
        gc_iColor[client][1] = GetRandomInt(0, 255);
        gc_iColor[client][2] = GetRandomInt(0, 255);
    }
    else
    {
        gc_iColor[client] = g_iCvar_Color;
    }

    gc_bDark[client] = true;
    if (gc_fDarkAt[client] <= 0.0)
    {
        gc_fDarkAt[client] = GetGameTime();
    }
    DebugLog("PerformFadeOut: 客户端 %d 开始暗屏(refs=%d, color=%d %d %d, alpha=%d).",
        client, gc_alFadeRef[client].Length, gc_iColor[client][0], gc_iColor[client][1], gc_iColor[client][2], g_iCvar_Alpha);
    ScreenFade(client, g_iFadeOutDuration, SCREENFADE_FRACBITS, FFADE_PURGE|FFADE_OUT|FFADE_STAYOUT, gc_iColor[client][0], gc_iColor[client][1], gc_iColor[client][2], g_iCvar_Alpha);
}

/****************************************************************************************************/

/**
 * 1.0.3: 清除暗屏。
 *
 * 与旧版 PerformFadeIn 的差别（这四条都是"暗屏不消失"的直接成因）:
 *   1) 不再检查 l4d_cloud_screen_fade_team 团队过滤。变暗侧遵守过滤就够了;
 *      清除侧如果也过滤, 生还者变暗后死亡/换到旁观者就永远收不到清除消息 -> 永久黑屏。
 *   2) 改用 alpha = 0 的 FFADE_IN, 且不再复用 l4d_cloud_screen_fade_alpha。
 *      旧版路径里 g_iCvar_Alpha(默认 245) 被当作"淡入目标", 对客户端而言那是一层
 *      几乎不透明的黑, 名为清除实为加深, 等于没消除。
 *   3) 一律带 FFADE_PURGE, 该位会先清空客户端已有的所有 fade, 保证这条清除指令不被叠加覆盖。
 *      且清除消息**绝不带 FFADE_STAYOUT**, 带上的话每次清除都会变成一次新的永久暗屏。
 *   4) 清除侧完全忽略 l4d_cloud_screen_fade_team 与 l4d_cloud_screen_fade_alpha,
 *      保证"只要曾经被变暗过, 就一定能被清掉"。
 *
 * bForce = true 时忽略 IsFakeClient 与暗屏状态, 用于兜底路径（机器人不需要收 UserMessage）。
 */
void ClearFade(int client, bool bForce)
{
    if (!IsValidClient(client))
        return;

    if (IsFakeClient(client))
        return;

    if (!bForce && !gc_bDark[client])
        return;

    // 1.0.3: 关键修复 —— 清除消息里绝对不能带 FFADE_STAYOUT（该位表示"忽略时长, 一直保持变暗,
    // 直到收到新的 Fade 消息"），否则每次"清除"实际上都是一次新的永久暗屏。
    // 同时 alpha 必须写 0: 旧版复用 l4d_cloud_screen_fade_alpha(默认 245) 作为淡入目标,
    // 对客户端而言那是"淡到几乎不透明的黑", 等于没消除, 这是"暗屏不消失"最直接的成因。
    // 两个短整型(时长/保持)都填一个非零小值, 保证淡入过程真的会发生而不是被引擎当 0 处理。
    int iDuration = g_iFadeInDuration;
    if (iDuration <= 0)
    {
        iDuration = SCREENFADE_FRACBITS / 4; // 0.25 秒
    }

    ScreenFade(client, iDuration, iDuration, FFADE_PURGE|FFADE_IN, 0, 0, 0, 0);
}

/****************************************************************************************************/

// 1.0.3: 兜底二次清除。清除消息偶尔会因为"同一帧里后面还有一条 Fade 把它覆盖掉"而失效,
// 而客户端收到的是一条"保持(FFADE_STAYOUT)"的暗屏, 一旦被覆盖就是永久黑屏。
// 这里在 0.2 秒后再补发一次全透明 Fade。若这期间玩家重新进入烟雾(gc_bDark 变真)则跳过,
// 绝不打断新的暗屏。
public Action Timer_RepeatClear(Handle timer, any iUserId)
{
    int client = GetClientOfUserId(iUserId);
    if (!IsValidClient(client))
        return Plugin_Stop;

    if (gc_bDark[client])
        return Plugin_Stop; // 已经重新进入烟雾, 不要覆盖新效果

    ClearFade(client, true);

    return Plugin_Stop;
}

/****************************************************************************************************/

// 1.0.3: 统一的"结束暗屏"出口。所有路径（正常离开烟雾、实体销毁、换队、断线、超时兜底）都走这里,
// 保证 gc_bDark / gc_fDarkAt / ref 列表三者一定被同步复位。
void ForceClear(int client, const char[] sReason)
{
    if (!IsValidClient(client))
    {
        // 客户端已不在游戏内, 只做状态复位。
        if (IsValidClientIndex(client))
        {
            gc_bDark[client] = false;
            gc_fDarkAt[client] = 0.0;
            gc_iSelfFade[client] = 0;
        }
        return;
    }

    DebugLog("ForceClear: 客户端 %d 结束暗屏(原因: %s).", client, sReason);

    ClearFade(client, true);

    gc_bDark[client] = false;
    gc_fDarkAt[client] = 0.0;
    gc_iColor[client] = {0, 0, 0};

    // 1.0.3: 清除完成后不再需要"放行票"。上面 ClearFade 发出的那条消息已在 EndMessage 期间
    // 同步消费掉自己的票, 这里归零只是防止异常路径(客户端掉线/消息被丢弃)导致票数累积,
    // 让后续外部 Fade 被误判成本插件发的而放行。
    gc_iSelfFade[client] = 0;

    // 1.0.3: 二次兜底。清除 Fade 有可能在同一帧被后续 Fade 覆盖(FFADE_STAYOUT 一旦被覆盖就是永久黑屏),
    // 所以 0.2 秒后再无条件补发一次全透明 Fade。Timer_RepeatClear 内部会检查 gc_bDark,
    // 若这期间玩家又进了新的烟雾则不会打断新效果。
    CreateTimer(0.2, Timer_RepeatClear, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

/****************************************************************************************************/

// 1.0.3: 清掉 gc_alFadeRef 里指向"已不存在的实体"的残留项。
// 实体被 Kill 后并不保证 OnEntityDestroyed 对每个持有者都跑到, 残留 ref 会让
// "列表为空 -> 发送清除" 这个条件永远不成立, 这是"有几率暗屏不消失"的主要残留来源。
void PurgeDeadFadeRefs(int client)
{
    for (int i = gc_alFadeRef[client].Length - 1; i >= 0; i--)
    {
        int iRef = gc_alFadeRef[client].Get(i);
        if (iRef == INVALID_ENT_REFERENCE || EntRefToEntIndex(iRef) == INVALID_ENT_REFERENCE)
        {
            gc_alFadeRef[client].Erase(i);
        }
    }
}

/****************************************************************************************************/

// 1.0.3: 换图/关插件时全量复位。bClearScreen 为 true 时还会给在线玩家发一次清除 Fade。
void ResetAllStates(bool bClearScreen)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (bClearScreen && IsClientInGame(client) && gc_bDark[client])
        {
            ClearFade(client, true);
        }

        gc_iSelfFade[client] = 0;
        gc_bDark[client] = false;
        gc_fDarkAt[client] = 0.0;
        gc_iColor[client] = {0, 0, 0};

        if (gc_alFadeRef[client] != null)
        {
            gc_alFadeRef[client].Clear();
        }
    }

    for (int entity = 0; entity <= MAXENTITIES; entity++)
    {
        ge_bTriggerFade[entity] = false;
    }
}

/****************************************************************************************************/

void OnStartTouch(const char[] output, int caller, int activator, float delay)
{
    int entity = caller;
    int client = activator;

    if (!IsValidClient(client))
        return;

    if (!IsValidEntity(entity))
        return;

    // 1.0.3: 先清理死实体的残留 ref, 再判断是否首次进入。
    PurgeDeadFadeRefs(client);

    int iRef = EntIndexToEntRef(entity);
    if (gc_alFadeRef[client].FindValue(iRef) != -1)
    {
        return; // 同一实体重复触发(倒地后起身、卡在边界反复进出), 不重复累积
    }

    // 1.0.3: 顺序修正 —— 先把 ref 入列表, 再发变暗。
    // 旧版先判断 Length == 0 再 PerformFadeOut, 然后无条件 Push:
    // 若 PerformFadeOut 因团队过滤提前 return, ref 仍被 Push, 之后永远不会 FirstEnter,
    // 而列表又永不为空 -> 清除条件永远不成立。
    gc_alFadeRef[client].Push(iRef);

    if (!gc_bDark[client])
    {
        PerformFadeOut(client);
    }
}

/****************************************************************************************************/

void OnEndTouch(const char[] output, int caller, int activator, float delay)
{
    int entity = caller;
    int client = activator;

    if (!IsValidClient(client))
        return;

    int find = gc_alFadeRef[client].FindValue(EntIndexToEntRef(entity));
    if (find != -1)
    {
        gc_alFadeRef[client].Erase(find);
    }

    PurgeDeadFadeRefs(client);

    if (gc_alFadeRef[client].Length == 0)
    {
        DebugLog("OnEndTouch: 客户端 %d 离开最后一个烟雾.", client);
        ForceClear(client, "OnEndTouch");
    }
}

/****************************************************************************************************/

void CreateTriggerFade(float vPos[3])
{
    int entity = CreateEntityByName("trigger_multiple");
    ge_bTriggerFade[entity] = true;
    DispatchKeyValue(entity, "spawnflags", "1"); // Clients
    DispatchKeyValue(entity, "allowincap", "1"); // Yes
    DispatchKeyValue(entity, "model", "error.mdl"); // Need a model, otherwise resizing doesn't work
    DispatchKeyValueVector(entity, "origin", vPos);
    DispatchSpawn(entity);

    SetEntPropVector(entity, Prop_Send, "m_vecMins", g_vFadeMins);
    SetEntPropVector(entity, Prop_Send, "m_vecMaxs", g_vFadeMaxs);
    SetEntProp(entity, Prop_Send, "m_nSolidType", SOLID_BBOX);

    HookSingleEntityOutput(entity, "OnStartTouch", OnStartTouch);
    HookSingleEntityOutput(entity, "OnEndTouch", OnEndTouch);

    SetVariantString(g_sKillInput);
    AcceptEntityInput(entity, "AddOutput");
    AcceptEntityInput(entity, "FireUser1");
}

// ====================================================================================================
// Admin Commands
// ====================================================================================================
Action CmdCloudFade(int client, int args)
{
    if (!IsValidClient(client))
        return Plugin_Handled;

    float vPos[3];
    GetClientAbsOrigin(client, vPos);

    CreateTriggerFade(vPos);

    return Plugin_Handled;
}

/****************************************************************************************************/

Action CmdPrintCvars(int client, int args)
{
    PrintToConsole(client, "");
    PrintToConsole(client, "======================================================================");
    PrintToConsole(client, "");
    PrintToConsole(client, "---------------- Plugin Cvars (l4d_cloud_screen_fade) ----------------");
    PrintToConsole(client, "");
    PrintToConsole(client, "l4d_cloud_screen_fade_version : %s", PLUGIN_VERSION);
    PrintToConsole(client, "l4d_cloud_screen_fade_enable : %b (%s)", g_bCvar_Enabled, g_bCvar_Enabled ? "true" : "false");
    PrintToConsole(client, "l4d_cloud_screen_fade_color : \"%s\"", g_sCvar_Color);
    PrintToConsole(client, "l4d_cloud_screen_fade_alpha : %i", g_iCvar_Alpha);
    PrintToConsole(client, "l4d_cloud_screen_fade_out_duration : %.1f", g_fCvar_FadeOutDuration);
    PrintToConsole(client, "l4d_cloud_screen_fade_in_duration : %.1f", g_fCvar_FadeInDuration);
    PrintToConsole(client, "l4d_cloud_screen_fade_life : %.1f", g_fCvar_FadeLife);
    PrintToConsole(client, "l4d_cloud_screen_fade_size : %.1f", g_fCvar_FadeSize);
    PrintToConsole(client, "l4d_cloud_screen_fade_block : %b (%s)", g_bCvar_Block, g_bCvar_Block ? "true" : "false");
    PrintToConsole(client, "l4d_cloud_screen_fade_team : %i (SPECTATOR = %s | SURVIVOR = %s | INFECTED = %s | HOLDOUT = %s)", g_iCvar_Team,
    g_iCvar_Team & FLAG_TEAM_SPECTATOR ? "true" : "false", g_iCvar_Team & FLAG_TEAM_SURVIVOR ? "true" : "false", g_iCvar_Team & FLAG_TEAM_INFECTED ? "true" : "false", g_iCvar_Team & FLAG_TEAM_HOLDOUT ? "true" : "false");
    PrintToConsole(client, "");
    PrintToConsole(client, "----------------------------- Array List -----------------------------");
    PrintToConsole(client, "");
    for (int target = 1; target <= MaxClients; target++)
    {
        if (!IsClientInGame(target))
            continue;

        PrintToConsole(client, "gc_alFadeRef[%i].Length: %N (%i)", target, target, gc_alFadeRef[target].Length);
    }
    PrintToConsole(client, "");
    PrintToConsole(client, "======================================================================");
    PrintToConsole(client, "");

    return Plugin_Handled;
}

// ====================================================================================================
// Helpers
// ====================================================================================================
/**
 * Validates if is a valid client index.
 *
 * @param client        Client index.
 * @return              True if client index is valid, false otherwise.
 */
bool IsValidClientIndex(int client)
{
    return (1 <= client <= MaxClients);
}

/****************************************************************************************************/

/**
 * Validates if is a valid client.
 *
 * @param client        Client index.
 * @return              True if client index is valid and client is in game, false otherwise.
 */
bool IsValidClient(int client)
{
    return (IsValidClientIndex(client) && IsClientInGame(client));
}

/****************************************************************************************************/

/**
 * Gets the client L4D1/L4D2 zombie class id.
 *
 * @param client        Client index.
 * @return L4D1         1=SMOKER, 2=BOOMER, 3=HUNTER, 4=WITCH, 5=TANK, 6=NOT INFECTED
 * @return L4D2         1=SMOKER, 2=BOOMER, 3=HUNTER, 4=SPITTER, 5=JOCKEY, 6=CHARGER, 7=WITCH, 8=TANK, 9=NOT INFECTED
 */
int GetZombieClass(int client)
{
    return (GetEntProp(client, Prop_Send, "m_zombieClass"));
}

/****************************************************************************************************/

/**
 * Returns the team flag from a team.
 *
 * @param team          Team index.
 * @return              Team flag.
 */
int GetTeamFlag(int team)
{
    switch (team)
    {
        case TEAM_SURVIVOR:
            return FLAG_TEAM_SURVIVOR;
        case TEAM_INFECTED:
            return FLAG_TEAM_INFECTED;
        case TEAM_SPECTATOR:
            return FLAG_TEAM_SPECTATOR;
        case TEAM_HOLDOUT:
            return FLAG_TEAM_HOLDOUT;
        default:
            return FLAG_TEAM_NONE;
    }
}

/****************************************************************************************************/

/**
 * Returns the integer array value of a RGB string.
 * Format: Three values between 0-255 separated by spaces. "<0-255> <0-255> <0-255>"
 * Example: "255 255 255"
 *
 * @param sColor        RGB color string.
 * @return              Integer array (int[3]) value of the RGB string or {0,0,0} if not in specified format.
 */
int[] ConvertRGBToIntArray(char[] sColor)
{
    int color[3];

    if (sColor[0] == 0)
        return color;

    char sColors[3][4];
    int count = ExplodeString(sColor, " ", sColors, sizeof(sColors), sizeof(sColors[]));

    switch (count)
    {
        case 1:
        {
            color[0] = StringToInt(sColors[0]);
        }
        case 2:
        {
            color[0] = StringToInt(sColors[0]);
            color[1] = StringToInt(sColors[1]);
        }
        case 3:
        {
            color[0] = StringToInt(sColors[0]);
            color[1] = StringToInt(sColors[1]);
            color[2] = StringToInt(sColors[2]);
        }
    }

    return color;
}

/****************************************************************************************************/

// 1.0.3: 参数改名以避免误用。Fade UserMessage 的两个短整型依次是
// "淡入/淡出过程时长"(duration) 与 "保持时长"(hold_time), 单位 1/512 秒,
// 都不是"延迟(delay)"。旧代码把它们叫 delay/duration 容易传错。
// 另外这里统一负责登记"放行票": 只有拦截模式开启时才需要, 且必须在真正
// StartMessageOne 之前 +1, 否则 FadeHook 会把自己发的消息拦掉。
void ScreenFade(int client, int iFadeDuration, int iHoldTime, int type, int red, int green, int blue, int alpha)
{
    // 只有拦截真正生效时才需要放行票。条件必须与 FadeHook 的存在条件完全一致
    // (g_bEventsHooked && g_umFade 有效), 否则票数会单向累积:
    // 例如 block=1 但 GetUserMessageId("Fade") 失败时没人消费, 之后一旦恢复就会连放多条外部 Fade。
    if (g_bCvar_Block && g_bEventsHooked && g_umFade != INVALID_MESSAGE_ID)
    {
        gc_iSelfFade[client]++;
    }

    Handle message = StartMessageOne("Fade", client);
    BfWrite bf = UserMessageToBfWrite(message);
    bf.WriteShort(iFadeDuration);
    bf.WriteShort(iHoldTime);
    bf.WriteShort(type);
    bf.WriteByte(red);
    bf.WriteByte(green);
    bf.WriteByte(blue);
    bf.WriteByte(alpha);
    EndMessage();
}