#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>
#include <l4d2util>
#define PLUGIN_VERSION "1.0.0"

public Plugin myinfo =
{
    name        = "Chainsaw Fuel Refill",
    author      = "apples1949",
    description = "弹药堆补充电锯燃料 + 燃料耗尽不丢弃电锯",
    version     = PLUGIN_VERSION,
    url         = ""
};

bool g_bLate;
bool g_bFuelRecorded;
int g_iChainsawMaxFuel;

public APLRes AskPluginLoad2(Handle me, bool late, char[] err, int m)
{
    g_bLate = late;
    return APLRes_Success;
}

public void OnPluginStart()
{
    g_iChainsawMaxFuel = 30;
    if (g_bLate)
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            if (IsClientInGame(i))
                OnClientPutInServer(i);
        }
    }
}

public void OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_WeaponDrop, OnWeaponDropByPlayer);
}

public void OnEntityCreated(int entity, const char[] classname)
{
    if (StrEqual(classname, "weapon_chainsaw"))
        SDKHook(entity, SDKHook_SpawnPost, OnChainsawSpawnPost);
    else if (StrEqual(classname, "weapon_ammo_spawn"))
        SDKHook(entity, SDKHook_UsePost, OnAmmoPileUsed);
}

public void OnChainsawSpawnPost(int entity)
{
    if (g_bFuelRecorded) return;
    if (!IsValidEntity(entity)) return;

    int fuel = GetEntProp(entity, Prop_Send, "m_iClip1");
    if (fuel > 0)
    {
        g_iChainsawMaxFuel = fuel;
        g_bFuelRecorded = true;
    }
}

public void OnAmmoPileUsed(int entity, int activator, int caller, UseType type, float value)
{
    if (activator < 1 || activator > MaxClients) return;
    if (!IsClientInGame(activator)) return;
    if (GetClientTeam(activator) != TEAM_SURVIVOR) return;
    if (!IsPlayerAlive(activator)) return;

    int weapon = GetEntPropEnt(activator, Prop_Send, "m_hActiveWeapon");
    if (weapon == -1 || !IsValidEntity(weapon)) return;

    char cls[32];
    GetEdictClassname(weapon, cls, sizeof(cls));
    if (!StrEqual(cls, "weapon_chainsaw")) return;

    SetEntProp(weapon, Prop_Send, "m_iClip1", g_iChainsawMaxFuel);
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
    if (!(buttons & IN_ATTACK)) return Plugin_Continue;
    if (GetClientTeam(client) != TEAM_SURVIVOR) return Plugin_Continue;
    if (!IsPlayerAlive(client)) return Plugin_Continue;

    int activeWep = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (activeWep == -1 || !IsValidEntity(activeWep)) return Plugin_Continue;

    static char cls[32];
    GetEdictClassname(activeWep, cls, sizeof(cls));
    if (!StrEqual(cls, "weapon_chainsaw")) return Plugin_Continue;

    int fuel = GetEntProp(activeWep, Prop_Send, "m_iClip1");
    if (fuel <= 1)
        buttons &= ~IN_ATTACK;

    return Plugin_Continue;
}

public void OnGameFrame()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i)) continue;
        if (GetClientTeam(i) != TEAM_SURVIVOR) continue;
        if (!IsPlayerAlive(i)) continue;

        int weapon = GetPlayerWeaponSlot(i, L4D2WeaponSlot_Primary);
        if (weapon == -1 || !IsValidEntity(weapon)) continue;

        char cls[32];
        GetEdictClassname(weapon, cls, sizeof(cls));
        if (!StrEqual(cls, "weapon_chainsaw")) continue;

        int fuel = GetEntProp(weapon, Prop_Send, "m_iClip1");
        if (fuel < 1)
            SetEntProp(weapon, Prop_Send, "m_iClip1", 1);
    }
}

public Action OnWeaponDropByPlayer(int client, int weapon)
{
    if (weapon == -1 || !IsValidEntity(weapon)) return Plugin_Continue;

    char cls[32];
    GetEdictClassname(weapon, cls, sizeof(cls));
    if (!StrEqual(cls, "weapon_chainsaw")) return Plugin_Continue;

    int fuel = GetEntProp(weapon, Prop_Send, "m_iClip1");
    if (fuel > 0) return Plugin_Continue;

    SetEntProp(weapon, Prop_Send, "m_iClip1", 1);
    return Plugin_Handled;
}
