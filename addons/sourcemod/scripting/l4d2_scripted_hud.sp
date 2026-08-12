/**
// ====================================================================================================
Change Log:

1.1.0 (11-Aug-2026)
    - Simplified: removed all cvar controls (texts/positions/flags are hardcoded in code).
    - Simplified: removed HUD3/HUD4, kept only HUD1 (boss progress / tank / witch / bonus score) and HUD2 (server name / player counts).
    - Added "sm_hud" admin command to toggle the HUD display on/off (approach from "l4d2_emshud_info" by 豆瓣酱な).
    - HUD2 now shows "服务器名(在线/总在线/上限)": 在线 excludes connecting players, 总在线 includes them (computed live, no state variable).

1.0.2 (01-May-2021)
    - Added support to special characters in static HUD texts through a data file. (thanks "Voevoda" for requesting)
    - Added a required file at data folder.

1.0.1 (13-March-2021)
    - Added cvars to make the next animated. (thanks "Source" for requesting)
    - Increased some cvars min/max bounds to fit more screen resolutions.

1.0.0 (10-March-2021)
    - Initial release.

// ====================================================================================================
*/

// ====================================================================================================
// Plugin Info
// ====================================================================================================
public Plugin myinfo =
{
    name        = "[L4D2] Scripted HUD",
    author      = "Mart",
    description = "Display boss progress and server info using the scripted HUD",
    version     = "1.1.0",
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
#define HUD_UPDATE_INTERVAL           0.1

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

static char   g_sHUD_TextArray[2][128];

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

    return APLRes_Success;
}

// ====================================================================================================
public void OnPluginStart()
{
    g_hVsBossBuffer = FindConVar("versus_boss_buffer");

    RegConsoleCmd("sm_hud", CommandSwitchHud, "开启或关闭HUD显示.");
}

// ====================================================================================================
public void OnAllPluginsLoaded()
{
    g_bWitchAndTankSystemAvailable = LibraryExists("witch_and_tankifier");
    g_bhybridScoringAvailable = LibraryExists("l4d2_hybrid_scoremod");
}

public void OnLibraryAdded(const char[] name)
{
    if (StrEqual(name, "witch_and_tankifier"))
        g_bWitchAndTankSystemAvailable = true;
    else if (StrEqual(name, "l4d2_hybrid_scoremod"))
        g_bhybridScoringAvailable = true;
}

public void OnLibraryRemoved(const char[] name)
{
    if (StrEqual(name, "witch_and_tankifier"))
        g_bWitchAndTankSystemAvailable = false;
    else if (StrEqual(name, "l4d2_hybrid_scoremod"))
        g_bhybridScoringAvailable = false;
}

// ====================================================================================================
public void OnConfigsExecuted()
{
    if (g_bHUDEnabled)
        CreateHUDTimer();
}

// ====================================================================================================
// sm_hud - 开启/关闭HUD (管理员)
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
        CreateHUDTimer();
        sMsg = "已开启HUD显示";
    }

    if (client == 0)
        PrintToServer("[提示] %s.", sMsg); //服务端控制台/RCON执行.
    else
        ReplyToCommand(client, "\x04[提示]\x03%s\x05.", sMsg);

    return Plugin_Handled;
}

//延迟一帧清除HUD.
public void OnNextFrameClearHUD(any data)
{
    ClearHUD();
}

// ====================================================================================================
void CreateHUDTimer()
{
    delete g_hTimerHUD;
    g_hTimerHUD = CreateTimer(HUD_UPDATE_INTERVAL, TimerUpdateHUD, _, TIMER_REPEAT);
}

public Action TimerUpdateHUD(Handle timer)
{
    UpdateHUD();
    return Plugin_Continue;
}

// ====================================================================================================
// 清除所有HUD槽位.
void ClearHUD()
{
    GameRules_SetProp("m_iScriptedHUDFlags", HUD_FLAG_NOTVISIBLE, _, HUD1);
    GameRules_SetPropString("m_szScriptedHUDStringSet", "", _, HUD1);
    GameRules_SetProp("m_iScriptedHUDFlags", HUD_FLAG_NOTVISIBLE, _, HUD2);
    GameRules_SetPropString("m_szScriptedHUDStringSet", "", _, HUD2);
}

// ====================================================================================================
void UpdateHUD()
{
    GetHUD_Texts();

    bool bTankAlive = HasAnyTankAlive();

    // HUD1: 进度/坦克/女巫/奖励分. 有坦克存活时闪烁.
    GameRules_SetProp("m_iScriptedHUDFlags", bTankAlive ? HUD1_FLAGS | HUD_FLAG_BLINK : HUD1_FLAGS, _, HUD1);
    GameRules_SetPropFloat("m_fScriptedHUDPosX", HUD1_X, HUD1);
    GameRules_SetPropFloat("m_fScriptedHUDPosY", HUD1_Y, HUD1);
    GameRules_SetPropFloat("m_fScriptedHUDWidth", HUD_WIDTH, HUD1);
    GameRules_SetPropFloat("m_fScriptedHUDHeight", HUD_HEIGHT * (CountCharInString(g_sHUD_TextArray[HUD1], '\n') + 1), HUD1);
    GameRules_SetPropString("m_szScriptedHUDStringSet", g_sHUD_TextArray[HUD1], _, HUD1);

    // HUD2: 服务器名字/人数/时间.
    GameRules_SetProp("m_iScriptedHUDFlags", HUD2_FLAGS, _, HUD2);
    GameRules_SetPropFloat("m_fScriptedHUDPosX", HUD2_X, HUD2);
    GameRules_SetPropFloat("m_fScriptedHUDPosY", HUD2_Y, HUD2);
    GameRules_SetPropFloat("m_fScriptedHUDWidth", HUD_WIDTH, HUD2);
    GameRules_SetPropFloat("m_fScriptedHUDHeight", HUD_HEIGHT * (CountCharInString(g_sHUD_TextArray[HUD2], '\n') + 1), HUD2);
    GameRules_SetPropString("m_szScriptedHUDStringSet", g_sHUD_TextArray[HUD2], _, HUD2);
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
        if (cv.IntValue)
        {
            if (IsStaticTankMap())
                IsStaticTank = false;
            else
                IsStaticTank = true;
        }
        cv = FindConVar("sm_witch_can_spawn");
        if (cv.IntValue)
        {
            if (IsStaticWitchMap())
                IsStaticWitch = false;
            else
                IsStaticWitch = true;
        }
    }
    FormatEx(output, size, "\0");
    int boss_proximity = RoundToNearest(GetBossProximity() * 100.0);
    int g_fWitchPercent, g_fTankPercent;
    g_fTankPercent = RoundToNearest(GetTankFlow(0) * 100.0);
    g_fWitchPercent = RoundToNearest(GetWitchFlow(0) * 100.0);
    FormatEx(output, size, "进度: [ %d%% ]", boss_proximity);
    if (IsStaticTank || (!g_bWitchAndTankSystemAvailable && g_fTankPercent))
    {
        FormatEx(output, size, "%s    坦克: [ %d%% ]", output, g_fTankPercent);
    }
    else if (!IsStaticTank)
    {
        FormatEx(output, size, "%s    坦克: [ 固定 ]", output);
    }
    if (IsStaticWitch || (!g_bWitchAndTankSystemAvailable && g_fWitchPercent))
    {
        FormatEx(output, size, "%s    女巫: [ %d%% ]", output, g_fWitchPercent);
    }
    else if (!IsStaticWitch)
    {
        FormatEx(output, size, "%s    女巫: [ 固定 ]", output);
    }
    if (g_bhybridScoringAvailable)
    {
        float maxBouns = float(SMPlus_GetHealthBonus()) + float(SMPlus_GetDamageBonus()) + float(SMPlus_GetPillsBonus());
        float healthBonusPercent = float(SMPlus_GetHealthBonus()) / float(SMPlus_GetMaxHealthBonus()) * 100;
        float damageBonusPercent = float(SMPlus_GetDamageBonus()) / float(SMPlus_GetMaxDamageBonus()) * 100;
        float pillsBonus = float(SMPlus_GetPillsBonus());
        float pillsBpnusPercent = float(SMPlus_GetPillsBonus()) / float(SMPlus_GetMaxPillsBonus()) * 100;
        FormatEx(output, size, "%s\n奖励分: %.0f [实血分: %.0f%% | 倒地分: %.0f%% | 药分: %.0f / %.0f%% ]", output, maxBouns, healthBonusPercent, damageBonusPercent, pillsBonus, pillsBpnusPercent);
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
    FindConVar("hostname").GetString(hostname, sizeof(hostname));
    FormatEx(output, size, "%s(%d/%d/%d)\n", hostname, GetPlayerNumber(), GetConnectedNumber(), PlayerLimit);
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
