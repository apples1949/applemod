/**
 * Applemod 12v12: population-based health for future Tank births.
 *
 * The engine receives a dynamic z_tank_health base value. This plugin never
 * writes a Tank entity's current/max health, so passing control or a population
 * change cannot heal an existing Tank or reset its damage-report baseline.
 *
 * This mode uses Versus' 1.5 health multiplier. z_tank_health must not also be
 * registered as a fixed confogl_addcvar setting. No AutoExecConfig is used.
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#define PLUGIN_VERSION "1.2.0"
#define TEAM_SURVIVOR 2
#define TEAM_INFECTED 3
#define ZOMBIECLASS_TANK 8
#define HARD_MAX_HEALTH 16500
#define DEFAULT_TANK_BASE 4000
#define VERSUS_HEALTH_MULTIPLIER 1.5
#define BASE_PLAYERS 4
#define MAX_CURVE_PLAYERS 12

ConVar g_hEnable;
ConVar g_hBaseHealth;
ConVar g_hMaximum;
ConVar g_hTankBase;
ConVar g_hGameMode;

bool g_bWritingBase;
bool g_bOwnsBase;
bool g_bRefreshQueued;
int g_iHumans;
int g_iBots;
int g_iSurvivors;
int g_iRequestedHealth;
int g_iTargetHealth;
int g_iBaseHealth = DEFAULT_TANK_BASE;

public Plugin myinfo =
{
    name = "Applemod 12v12 Dynamic Tank Health",
    author = "apples1949",
    description = "Set future Tank birth health from all survivors, including AI; never rescale live Tanks",
    version = PLUGIN_VERSION,
    url = "https://github.com/apples1949/applemod"
};

public void OnPluginStart()
{
    if (GetEngineVersion() != Engine_Left4Dead2)
        SetFailState("This plugin requires Left 4 Dead 2.");

    g_hTankBase = FindConVar("z_tank_health");
    g_hGameMode = FindConVar("mp_gamemode");
    if (g_hTankBase == null || g_hGameMode == null)
        SetFailState("Required Tank health or game-mode ConVar is unavailable.");

    g_hEnable = CreateConVar("appletankhp_enable", "1",
        "Enable population-based health for future Versus Tank births; live Tanks keep their health.",
        FCVAR_NONE, true, 0.0, true, 1.0);
    g_hBaseHealth = CreateConVar("appletankhp_base_health", "6000",
        "Actual Tank birth HP at four survivors including AI; scales linearly to the max at twelve.",
        FCVAR_NONE, true, 1.0, true, float(HARD_MAX_HEALTH));
    g_hMaximum = CreateConVar("appletankhp_max", "16500",
        "Maximum actual Tank birth health; the absolute safety cap is 16500.",
        FCVAR_NONE, true, 1.0, true, float(HARD_MAX_HEALTH));

    g_hEnable.AddChangeHook(CvarSettingChanged);
    g_hBaseHealth.AddChangeHook(CvarSettingChanged);
    g_hMaximum.AddChangeHook(CvarSettingChanged);
    g_hTankBase.AddChangeHook(CvarTankBaseChanged);
    g_hGameMode.AddChangeHook(CvarSettingChanged);

    HookEvent("round_start", Event_PopulationChanged, EventHookMode_PostNoCopy);
    HookEvent("player_team", Event_PopulationChanged, EventHookMode_PostNoCopy);
    HookEvent("player_bot_replace", Event_PopulationChanged, EventHookMode_PostNoCopy);
    HookEvent("bot_player_replace", Event_PopulationChanged, EventHookMode_PostNoCopy);

    // These refresh only the global base for future births. In particular,
    // tank_spawn also fires on controller transfers and must never refill HP.
    HookEvent("player_spawn", Event_Birth, EventHookMode_Pre);
    HookEvent("tank_spawn", Event_Birth, EventHookMode_Pre);

    RegConsoleCmd("sm_tankhpstatus", Command_TankHealthStatus,
        "Show total/human/AI survivor counts, future Tank health and existing Tank health.");

    RefreshTankBase();
    QueueRefresh();
}

public void OnAllPluginsLoaded()
{
    RefreshTankBase();
    QueueRefresh();
}

public void OnConfigsExecuted()
{
    RefreshTankBase();
    QueueRefresh();
}

public void OnMapStart()
{
    RefreshTankBase();
    QueueRefresh();
}

public void OnMapEnd()
{
    g_bRefreshQueued = false;
}

public void OnClientPutInServer(int client)
{
    QueueRefresh();
}

public void OnClientDisconnect_Post(int client)
{
    // Wait until ownership/team properties reflect the completed disconnect.
    QueueRefresh();
}

public void OnPluginEnd()
{
    // Do not overwrite a subsequent owner's value while this plugin is off.
    // The mode's confogl_off.cfg also explicitly restores the engine default.
    if (g_hTankBase != null && g_hEnable != null && g_hEnable.BoolValue
        && g_bOwnsBase && g_hTankBase.FloatValue == float(g_iBaseHealth))
    {
        WriteTankBase(DEFAULT_TANK_BASE);
    }
}

public void CvarSettingChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    RefreshTankBase();
    QueueRefresh();
}

public void CvarTankBaseChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (!g_bWritingBase && IsScalingActive())
        RefreshTankBase();
}

public void Event_PopulationChanged(Event event, const char[] name, bool dontBroadcast)
{
    // player_team and idle replacement events can run before all properties
    // settle. Coalesce them into one fresh count on the following frame.
    QueueRefresh();
}

public Action Event_Birth(Event event, const char[] name, bool dontBroadcast)
{
    RefreshTankBase();
    QueueRefresh();
    return Plugin_Continue;
}

public Action L4D_OnSpawnTank(const float vecPos[3], const float vecAng[3])
{
    // Runs before natural Tank construction; c7m3 can invoke this with no
    // successful birth. Re-counting is safe and does not touch entity health.
    RefreshTankBase();
    return Plugin_Continue;
}

void QueueRefresh()
{
    if (g_bRefreshQueued)
        return;

    g_bRefreshQueued = true;
    RequestFrame(Frame_RefreshTankBase);
}

public void Frame_RefreshTankBase(any data)
{
    g_bRefreshQueued = false;
    RefreshTankBase();
}

bool IsVersusMode()
{
    char mode[32];
    g_hGameMode.GetString(mode, sizeof(mode));
    // The dedicated configuration uses Versus. Realism Versus uses the same
    // engine multiplier. Other game modes must retain their own health rules.
    return StrEqual(mode, "versus", false) || StrEqual(mode, "mutation12", false);
}

bool IsScalingActive()
{
    return g_hEnable != null && g_hEnable.BoolValue && IsVersusMode();
}

int CountSurvivors()
{
    g_iHumans = 0;
    g_iBots = 0;
    int survivors;

    // Count survivor bodies, including pure AI and dead team members. An idle
    // human is on spectators, so their survivor AI body contributes only once.
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client) && GetClientTeam(client) == TEAM_SURVIVOR)
        {
            survivors++;
            if (IsFakeClient(client))
                g_iBots++;
            else
                g_iHumans++;
        }
    }

    return survivors;
}

int BoundedSetting(int value)
{
    // Enforce the hard maximum in code too: sm_cvar can temporarily bypass
    // ConVar bounds; health endpoints must remain inside the absolute cap.
    if (value < 1)
        return 1;
    if (value > HARD_MAX_HEALTH)
        return HARD_MAX_HEALTH;
    return value;
}

void RefreshTankBase()
{
    g_iSurvivors = CountSurvivors();
    if (!IsScalingActive())
    {
        if (g_bOwnsBase)
            WriteTankBase(DEFAULT_TANK_BASE);
        g_bOwnsBase = false;
        g_iRequestedHealth = 0;
        g_iTargetHealth = 0;
        g_iBaseHealth = DEFAULT_TANK_BASE;
        return;
    }

    int population = g_iSurvivors > 0 ? g_iSurvivors : 1;
    if (population > MAX_CURVE_PLAYERS)
        population = MAX_CURVE_PLAYERS;

    int maximum = BoundedSetting(g_hMaximum.IntValue);
    int baseHealth = BoundedSetting(g_hBaseHealth.IntValue);
    if (baseHealth > maximum)
        baseHealth = maximum;

    float health;
    if (population <= BASE_PLAYERS)
        health = float(baseHealth) * float(population) / float(BASE_PLAYERS);
    else
        health = float(baseHealth) + float(maximum - baseHealth)
            * float(population - BASE_PLAYERS) / float(MAX_CURVE_PLAYERS - BASE_PLAYERS);
    if (health < 1.0)
        health = 1.0;
    g_iRequestedHealth = RoundToFloor(health);

    // Use an integer engine base and round down, so even nonstandard settings
    // cannot push actual Versus birth health above the configured/hard cap.
    // Divide the unrounded curve value so half-HP steps are rounded only once.
    g_iBaseHealth = RoundToFloor(health / VERSUS_HEALTH_MULTIPLIER);
    if (g_iBaseHealth < 1)
        g_iBaseHealth = 1;
    g_iTargetHealth = RoundToFloor(float(g_iBaseHealth) * VERSUS_HEALTH_MULTIPLIER);

    g_bOwnsBase = true;
    WriteTankBase(g_iBaseHealth);
}

void WriteTankBase(int health)
{
    if (g_hTankBase.FloatValue == float(health))
        return;

    g_bWritingBase = true;
    g_hTankBase.SetInt(health, false, false);
    g_bWritingBase = false;
}

public Action Command_TankHealthStatus(int client, int args)
{
    // A diagnostic refresh updates the future-birth base only. Existing Tank
    // entity health remains untouched, including when this is a late load.
    RefreshTankBase();

    char file[PLATFORM_MAX_PATH], mode[32];
    GetPluginFilename(GetMyHandle(), file, sizeof(file));
    g_hGameMode.GetString(mode, sizeof(mode));
    ReplyToCommand(client, "[TankHP] v%s | file=%s | enabled=%d active=%d | mode=%s",
        PLUGIN_VERSION, file, g_hEnable.BoolValue, IsScalingActive(), mode);
    ReplyToCommand(client, "[TankHP] survivors total=%d humans=%d AI=%d | base_players=4 base_health=%d | max_players=12 max=%d | hard_cap=%d",
        g_iSurvivors, g_iHumans, g_iBots, BoundedSetting(g_hBaseHealth.IntValue),
        BoundedSetting(g_hMaximum.IntValue), HARD_MAX_HEALTH);
    ReplyToCommand(client, "[TankHP] next_birth_target=%d | requested=%d | z_tank_health=%d | versus_multiplier=1.5 | birth_only=1",
        g_iTargetHealth, g_iRequestedHealth, g_hTankBase.IntValue);

    int tanks;
    for (int tank = 1; tank <= MaxClients; tank++)
    {
        if (!IsClientInGame(tank) || GetClientTeam(tank) != TEAM_INFECTED
            || !IsPlayerAlive(tank) || GetEntProp(tank, Prop_Send, "m_zombieClass") != ZOMBIECLASS_TANK)
        {
            continue;
        }

        tanks++;
        ReplyToCommand(client, "[TankHP] existing tank userid=%d client=%d AI=%d | HP=%d max=%d (kept unchanged)",
            GetClientUserId(tank), tank, IsFakeClient(tank), GetClientHealth(tank),
            GetEntProp(tank, Prop_Data, "m_iMaxHealth"));
    }

    ReplyToCommand(client, "[TankHP] live_tanks=%d | Population changes affect future births; existing Tanks and controller transfers keep HP.", tanks);
    return Plugin_Handled;
}
