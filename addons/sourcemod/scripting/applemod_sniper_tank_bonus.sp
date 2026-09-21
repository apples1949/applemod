#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>

#define PLUGIN_VERSION "1.0.0"

#define TEAM_SURVIVOR        2
#define TEAM_INFECTED        3
#define ZOMBIE_CLASS_TANK    8

// 狙击类武器。项目里 l4d2_weaponrules 会把地图上的 sniper_military / sniper_scout /
// sniper_awp 生成点改写成 hunting_rifle，但 givewpn.smx 仍会把 awp / 鸟狙直接发到玩家手上，
// 所以四种狙击都要识别。
static const char g_sSniperClasses[][] =
{
    "weapon_hunting_rifle",
    "weapon_sniper_military",
    "weapon_sniper_awp",
    "weapon_sniper_scout"
};

ConVar
    g_hEnabled = null,
    g_hMultiplier = null,
    g_hMaxSpeed = null;

bool
    g_bEnabled = true;

float
    g_fMultiplier = 1.5,
    g_fMaxSpeed = 10.0;

public Plugin myinfo =
{
    name = "Applemod Sniper Stationary Tank Bonus",
    author = "apples1949",
    description = "狙击武器命中处于未移动状态的坦克时，伤害乘以倍率（默认 1.5 倍）。",
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
    g_hEnabled = CreateConVar( \
        "applemod_sniper_tank_bonus_enable", \
        "1", \
        "是否启用狙击命中静止坦克的伤害加成。0=关闭, 1=开启。", \
        FCVAR_NOTIFY, true, 0.0, true, 1.0 \
    );

    g_hMultiplier = CreateConVar( \
        "applemod_sniper_tank_bonus_multiplier", \
        "1.5", \
        "坦克未移动时狙击伤害的倍率。1.5 表示变成原来的 150%。", \
        FCVAR_NOTIFY, true, 0.0, false, 0.0 \
    );

    g_hMaxSpeed = CreateConVar( \
        "applemod_sniper_tank_bonus_speed", \
        "10.0", \
        "坦克速度低于该值（单位/秒）时视为\"未移动\"。正常行走约 220，站着不动接近 0。", \
        FCVAR_NOTIFY, true, 0.0, false, 0.0 \
    );

    g_hEnabled.AddChangeHook(ConVarChanged);
    g_hMultiplier.AddChangeHook(ConVarChanged);
    g_hMaxSpeed.AddChangeHook(ConVarChanged);

    ReadCvars();

    // 可选插件在比赛配置执行时可能是晚加载，补挂已经在场的玩家（含 AI 坦克所在槽位）。
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i)) {
            SDKHook(i, SDKHook_OnTakeDamage, OnTakeDamage);
        }
    }
}

void ConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    ReadCvars();
}

void ReadCvars()
{
    g_bEnabled = g_hEnabled.BoolValue;
    g_fMultiplier = g_hMultiplier.FloatValue;
    g_fMaxSpeed = g_hMaxSpeed.FloatValue;

    if (g_fMultiplier <= 0.0) {
        g_fMultiplier = 1.0;
    }

    if (g_fMaxSpeed < 0.0) {
        g_fMaxSpeed = 0.0;
    }
}

public void OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
}

public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
    if (!g_bEnabled || damage <= 0.0 || !(damagetype & DMG_BULLET)) {
        return Plugin_Continue;
    }

    if (!IsTank(victim) || !IsSurvivorShooter(attacker) || !IsSniper(inflictor, attacker)) {
        return Plugin_Continue;
    }

    if (!IsTankStationary(victim)) {
        return Plugin_Continue;
    }

    // 只对传入的 damage 做乘法，不改动 sm_weapon / l4d2_weapon_attributes 写入的武器数据。
    // 这里的 damage 已经是引擎与其它插件修正后的值，乘倍率就是在该基础上的二次修正。
    damage *= g_fMultiplier;
    return Plugin_Changed;
}

bool IsTank(int client)
{
    return (client > 0
        && client <= MaxClients
        && IsClientInGame(client)
        && GetClientTeam(client) == TEAM_INFECTED
        && IsPlayerAlive(client)
        && GetEntProp(client, Prop_Send, "m_zombieClass") == ZOMBIE_CLASS_TANK);
}

bool IsSurvivorShooter(int client)
{
    return (client > 0
        && client <= MaxClients
        && IsClientInGame(client)
        && GetClientTeam(client) == TEAM_SURVIVOR
        && IsPlayerAlive(client));
}

// 用三维速度模长判定"未移动"：
// - 站着不动 → 接近 0，命中加成生效；
// - 走/跑/被撞飞 → 水平速度很大，不生效；
// - 跳跃、坠落 → 垂直速度很大，同样算在移动，所以不用再额外判断 FL_ONGROUND。
bool IsTankStationary(int tank)
{
    float vecVelocity[3];
    GetEntPropVector(tank, Prop_Data, "m_vecVelocity", vecVelocity);

    return GetVectorLength(vecVelocity) <= g_fMaxSpeed;
}

bool IsSniper(int inflictor, int attacker)
{
    // 子弹伤害的 inflictor 是武器实体，优先按实体 classname 判断，避免切枪误判。
    if (inflictor > MaxClients && IsValidEntity(inflictor)) {
        char classname[64];
        if (GetEntityClassname(inflictor, classname, sizeof(classname))) {
            return IsSniperClass(classname);
        }

        return false;
    }

    // inflictor 不是武器实体（异常/其他伤害来源）时，退回判断攻击者当前武器。
    char weapon[64];
    GetClientWeapon(attacker, weapon, sizeof(weapon));
    return IsSniperClass(weapon);
}

bool IsSniperClass(const char[] classname)
{
    for (int i = 0; i < sizeof(g_sSniperClasses); i++) {
        if (StrEqual(classname, g_sSniperClasses[i], false)) {
            return true;
        }
    }

    return false;
}
