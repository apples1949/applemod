#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>
#include <colors>

#define PLUGIN_VERSION "1.1.1"

public Plugin myinfo = {
    name        = "L4D2 Pipe Bomb Cooldown",
    author      = "apples1949",
    description = "Multi-layer defense: blocks pipe bomb throws for a configurable cooldown after any survivor throws one",
    version     = PLUGIN_VERSION,
    url         = ""
};

ConVar  g_cvEnable;
ConVar  g_cvCooldownTime;

bool    g_bInCooldown;
Handle  g_hCooldownTimer;
float   g_fLastHintTime[MAXPLAYERS + 1];

// ============================================================================
// Plugin Lifecycle
// ============================================================================

public void OnPluginStart()
{
    g_cvEnable       = CreateConVar("sm_grenade_cooldown_enable", "1",
                        "Enable pipe bomb cooldown (1=On 0=Off)");
    g_cvCooldownTime = CreateConVar("sm_grenade_cooldown_time",  "16.0",
                        "Cooldown duration in seconds after a pipe bomb is thrown", _, true, 0.0);

    // Late-load: hook all already-connected survivors
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i)) {
            OnClientPutInServer(i);
        }
    }
}

public void OnPluginEnd()
{
    EndCooldown();

    // Unhook all clients
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i)) {
            SDKUnhook(i, SDKHook_WeaponSwitch, OnWeaponSwitch);
        }
    }
}

public void OnMapEnd()
{
    EndCooldown();
}

public void OnClientPutInServer(int client)
{
    // Layer 2 - prevent equipping pipe bomb during cooldown
    SDKHook(client, SDKHook_WeaponSwitch, OnWeaponSwitch);
}

public void OnClientDisconnect(int client)
{
    SDKUnhook(client, SDKHook_WeaponSwitch, OnWeaponSwitch);
    g_fLastHintTime[client] = 0.0;
}

// ============================================================================
// Cooldown Management
// ============================================================================

void EndCooldown()
{
    g_bInCooldown = false;
    if (g_hCooldownTimer != null) {
        KillTimer(g_hCooldownTimer);
        g_hCooldownTimer = null;
    }
}

void StartCooldown(int thrower)
{
    g_bInCooldown = true;

    if (g_hCooldownTimer != null) {
        KillTimer(g_hCooldownTimer);
    }
    g_hCooldownTimer = CreateTimer(g_cvCooldownTime.FloatValue, Timer_EndCooldown);

    float cooldown = g_cvCooldownTime.FloatValue;

    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i)) {
            CPrintToChat(i, "{green}[土雷冷却] {default}%N 扔出了土制炸弹，{olive}%.0f 秒{default}内所有人不能扔土雷！", thrower, cooldown);
        }
    }
}

// ============================================================================
// Layer 1 - Detect throw → start cooldown (after projectile is successfully created)
// ============================================================================

public void L4D_PipeBombProjectile_Post(int client, int projectile, const float vecPos[3], const float vecAng[3], const float vecVel[3], const float vecRot[3])
{
    if (!g_cvEnable.BoolValue)
        return;

    // _Post only fires when _Pre wasn't blocked, so this is always a legitimate first throw
    StartCooldown(client);
}

// ============================================================================
// Layer 2 - Prevent switching to pipe bomb during cooldown (SDKHook)
// ============================================================================

Action OnWeaponSwitch(int client, int weapon)
{
    if (!g_cvEnable.BoolValue || !g_bInCooldown)
        return Plugin_Continue;

    if (client < 1 || client > MaxClients || !IsClientInGame(client))
        return Plugin_Continue;
    if (GetClientTeam(client) != 2 || !IsPlayerAlive(client))
        return Plugin_Continue;

    if (weapon == -1 || !IsValidEntity(weapon))
        return Plugin_Continue;

    char classname[64];
    GetEdictClassname(weapon, classname, sizeof(classname));

    if (StrEqual(classname, "weapon_pipe_bomb")) {
        // Rate-limited hint
        float currentTime = GetGameTime();
        if (currentTime - g_fLastHintTime[client] > 2.0) {
            g_fLastHintTime[client] = currentTime;
            CPrintToChat(client, "{green}[土雷冷却] {default}冷却中，无法切换土制炸弹！");
        }
        return Plugin_Handled; // Block the switch
    }

    return Plugin_Continue;
}

// ============================================================================
// Layer 3 - Block pipe bomb projectile creation (Left4DHooks)
// ============================================================================

public Action L4D_PipeBombProjectile_Pre(int client, float vecPos[3], float vecAng[3], float vecVel[3], float vecRot[3])
{
    if (!g_cvEnable.BoolValue || !g_bInCooldown)
        return Plugin_Continue;

    return Plugin_Handled; // Block projectile creation at engine level
}

// ============================================================================
// Layer 4 - Block IN_ATTACK during cooldown (OnPlayerRunCmd, client-side)
// ============================================================================

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3],
                              int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
    if (!g_cvEnable.BoolValue || !g_bInCooldown)
        return Plugin_Continue;

    if (client < 1 || client > MaxClients || !IsClientInGame(client))
        return Plugin_Continue;
    if (GetClientTeam(client) != 2 || !IsPlayerAlive(client))
        return Plugin_Continue;

    // The pipe bomb can be detected in two places:
    //   1. m_hActiveWeapon  - the weapon the server currently considers active.
    //   2. weapon parameter - the weapon the client is switching to right now
    //      (usercmd.weaponselect).
    // The server's active weapon lags behind the client's selection, so a player
    // who switches to the pipe bomb slot and throws in the same tick would slip
    // through a check that only looks at m_hActiveWeapon.
    bool bHasPipeBomb = IsPipeBomb(GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon"));
    if (!bHasPipeBomb && weapon > 0 && IsValidEntity(weapon))
        bHasPipeBomb = IsPipeBomb(weapon);

    if (!bHasPipeBomb)
        return Plugin_Continue;

    bool bThrowing = (buttons & IN_ATTACK) != 0;

    // Cancel the pending switch so the pipe bomb can't even be equipped.
    if (weapon > 0 && IsPipeBomb(weapon))
        weapon = 0;

    // Strip the throw itself.
    if (bThrowing)
        buttons &= ~IN_ATTACK;

    float currentTime = GetGameTime();
    if (currentTime - g_fLastHintTime[client] > 2.0) {
        g_fLastHintTime[client] = currentTime;
        if (bThrowing)
            CPrintToChat(client, "{green}[土雷冷却] {default}请等待冷却结束再扔土雷！");
        else
            CPrintToChat(client, "{green}[土雷冷却] {default}冷却中，无法切换土制炸弹！");
    }

    return Plugin_Changed;
}

bool IsPipeBomb(int entity)
{
    if (entity <= 0 || !IsValidEntity(entity))
        return false;

    char classname[64];
    GetEdictClassname(entity, classname, sizeof(classname));
    return StrEqual(classname, "weapon_pipe_bomb");
}

// ============================================================================
// Timer Callback
// ============================================================================

Action Timer_EndCooldown(Handle timer)
{
    g_hCooldownTimer = null;
    g_bInCooldown = false;

    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i)) {
            CPrintToChat(i, "{green}[土雷冷却] {default}冷却结束，可以再次扔土雷了！");
        }
    }

    return Plugin_Stop;
}
