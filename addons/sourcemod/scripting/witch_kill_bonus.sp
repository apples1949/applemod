#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>

#define IS_VALID_CLIENT(%1)     (%1 > 0 && %1 <= MaxClients)
#define IS_SURVIVOR(%1)         (GetClientTeam(%1) == 2)
#define IS_INFECTED(%1)         (GetClientTeam(%1) == 3)
#define IS_VALID_INGAME(%1)     (IS_VALID_CLIENT(%1) && IsClientInGame(%1))
#define IS_VALID_SURVIVOR(%1)   (IS_VALID_INGAME(%1) && IS_SURVIVOR(%1))
#define IS_VALID_INFECTED(%1)   (IS_VALID_INGAME(%1) && IS_INFECTED(%1))
#define IS_SURVIVOR_ALIVE(%1)   (IS_VALID_SURVIVOR(%1) && IsPlayerAlive(%1))
#define IS_INFECTED_ALIVE(%1)   (IS_VALID_INFECTED(%1) && IsPlayerAlive(%1))

bool g_bLateLoad;
bool g_bIsVersus;
bool g_bBonusAwarded;
int g_iOriginalPenalty;
ConVar g_hCvarBonus;
ConVar g_hCvarPrint;
ConVar g_hDefibPenalty;
StringMap g_hWitchState;
int g_iRoundBonus;

public Plugin myinfo =
{
    name = "Witch Kill Bonus",
    author = "apples1949",
    description = "对抗模式中，击杀 Witch 可获得额外分数",
    version = "2.0.0",
    url = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    g_bLateLoad = late;
    return APLRes_Success;
}

public void OnPluginStart()
{
    HookEvent("round_start", Event_RoundStart, EventHookMode_Post);
    HookEvent("witch_spawn", Event_WitchSpawn, EventHookMode_Post);
    HookEvent("witch_killed", Event_WitchKilled, EventHookMode_Post);

    g_hCvarBonus = CreateConVar("sm_witch_bonus_score", "25", "击杀 Witch 额外分数", FCVAR_NONE, true, 0.0);
    g_hCvarPrint = CreateConVar("sm_witch_bonus_print", "1", "显示奖励提示", FCVAR_NONE, true, 0.0, true, 1.0);
    g_hDefibPenalty = FindConVar("vs_defib_penalty");

    //AutoExecConfig(true, "witch_kill_bonus");

    g_hWitchState = new StringMap();
    g_iRoundBonus = 0;
    g_bIsVersus = IsVersusMode();

    if (g_hDefibPenalty != INVALID_HANDLE)
    {
        g_iOriginalPenalty = g_hDefibPenalty.IntValue;
    }

    if (g_bLateLoad)
    {
        for (int client = 1; client <= MaxClients; client++)
        {
            if (IS_VALID_INGAME(client))
            {
                SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamageByWitch);
            }
        }
    }
}

public void OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamageByWitch);
}

public void OnClientDisconnect(int client)
{
    SDKUnhook(client, SDKHook_OnTakeDamage, OnTakeDamageByWitch);
}

public void OnEntityDestroyed(int entity)
{
    char witch_key[10];
    FormatEx(witch_key, sizeof(witch_key), "%x", entity);
    g_hWitchState.Remove(witch_key);
}

bool IsVersusMode()
{
    char gamemode[32];
    FindConVar("mp_gamemode").GetString(gamemode, sizeof(gamemode));
    return StrContains(gamemode, "versus") != -1;
}

bool IsWitchEntity(int entity)
{
    if (!IsValidEntity(entity))
        return false;

    char classname[24];
    GetEdictClassname(entity, classname, sizeof(classname));
    return StrEqual(classname, "witch");
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    g_bIsVersus = IsVersusMode();

    g_iRoundBonus = 0;
    g_bBonusAwarded = false;
    g_hWitchState.Clear();

    if (g_hDefibPenalty != INVALID_HANDLE)
    {
        g_hDefibPenalty.SetInt(g_iOriginalPenalty);
    }
}

public void Event_WitchSpawn(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_bIsVersus)
        return;

    int witch = event.GetInt("witchid");
    char witch_key[10];
    FormatEx(witch_key, sizeof(witch_key), "%x", witch);
    g_hWitchState.SetValue(witch_key, 0);
}

public void Event_WitchKilled(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_bIsVersus)
        return;

    int witch = event.GetInt("witchid");
    int userid = event.GetInt("userid");
    int attacker = GetClientOfUserId(userid);

    if (!IS_VALID_SURVIVOR(attacker))
        return;

    if (g_bBonusAwarded)
        return;

    char witch_key[10];
    FormatEx(witch_key, sizeof(witch_key), "%x", witch);

    int damaged;
    bool found = g_hWitchState.GetValue(witch_key, damaged);

    if (found && damaged)
        return;

    int bonus = g_hCvarBonus.IntValue;
    g_iRoundBonus += bonus;
    g_bBonusAwarded = true;

    if (g_hCvarPrint.BoolValue)
    {
        PrintToChatAll("\x01[WitchBonus] \x04%N \x01击杀了 Witch! +\x05%d \x01分", attacker, bonus);
    }
}

public Action L4D2_OnEndVersusModeRound(bool countSurvivors)
{
    if (!g_bIsVersus || g_iRoundBonus <= 0)
        return Plugin_Continue;

    int currentPenalty = g_hDefibPenalty.IntValue;
    int flipped = GameRules_GetProp("m_bAreTeamsFlipped", 4, 0);
    int currentDefibs = GameRules_GetProp("m_iVersusDefibsUsed", 4, flipped);

    int currentBonus = 0;
    if (currentDefibs > 0)
    {
        currentBonus = -currentPenalty * currentDefibs;
    }
    else if (currentPenalty < 0)
    {
        currentBonus = -currentPenalty;
    }

    int totalBonus = currentBonus + g_iRoundBonus;

    g_hDefibPenalty.SetInt(-totalBonus);
    GameRules_SetProp("m_iVersusDefibsUsed", 1, 4, flipped);

    return Plugin_Continue;
}

public Action OnTakeDamageByWitch(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
    if (!g_bIsVersus)
        return Plugin_Continue;

    if (IS_VALID_SURVIVOR(victim) && damage > 0.0)
    {
        if (IsWitchEntity(attacker))
        {
            char witch_key[10];
            FormatEx(witch_key, sizeof(witch_key), "%x", attacker);
            g_hWitchState.SetValue(witch_key, 1);
        }
    }

    return Plugin_Continue;
}
