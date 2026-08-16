#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>

#define PLUGIN_VERSION "1.0.0"

#define TEAM_SURVIVOR        2
#define TEAM_INFECTED        3
#define ZOMBIE_CLASS_TANK    8

// 项目里 "机枪" 指 SMG 类武器（shared_cvars.cfg: ammo_smg_max // 机枪子弹设置）。
// weaponrules 会把 rifle / rifle_desert / rifle_sg552 等替换成这些实体，因此仍会被识别。
static const char g_sMachineGunClasses[][] =
{
    "weapon_smg",
    "weapon_smg_silenced",
    "weapon_smg_mp5"
};

ConVar
    g_hEnabled = null,
    g_hShootersNeeded = null,
    g_hWindow = null,
    g_hMultiplier = null;

bool
    g_bEnabled = true;

int
    g_iShootersNeeded = 4;

float
    g_fWindow = 0.5,
    g_fMultiplier = 0.8;

// [victim][attacker] = 该机枪手最后一次命中该坦克的游戏时间。
float g_fLastMachineGunHit[MAXPLAYERS + 1][MAXPLAYERS + 1];

public Plugin myinfo =
{
    name = "Applemod MG Tank Focus Nerf",
    author = "apples1949",
    description = "四把机枪（SMG）同时或极短时间内命中坦克时，机枪伤害在原修正基础上再乘 0.8。",
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
        "applemod_mg_tank_nerf_enable", \
        "1", \
        "是否启用四把机枪齐射坦克时的机枪伤害二次修正。0=关闭, 1=开启。", \
        FCVAR_NOTIFY, true, 0.0, true, 1.0 \
    );

    g_hShootersNeeded = CreateConVar( \
        "applemod_mg_tank_nerf_shooters", \
        "4", \
        "窗口期内需要多少把不同的机枪命中坦克才触发修正。", \
        FCVAR_NOTIFY, true, 2.0, true, 32.0 \
    );

    g_hWindow = CreateConVar( \
        "applemod_mg_tank_nerf_window", \
        "0.5", \
        "把不同机枪的命中视为同时输出的时间窗口（秒）。", \
        FCVAR_NOTIFY, true, 0.0, false, 0.0 \
    );

    g_hMultiplier = CreateConVar( \
        "applemod_mg_tank_nerf_multiplier", \
        "0.8", \
        "触发修正时机枪伤害的倍率。0.8 表示降低为原来的 80%。", \
        FCVAR_NOTIFY, true, 0.0, true, 1.0 \
    );

    g_hEnabled.AddChangeHook(ConVarChanged);
    g_hShootersNeeded.AddChangeHook(ConVarChanged);
    g_hWindow.AddChangeHook(ConVarChanged);
    g_hMultiplier.AddChangeHook(ConVarChanged);

    ReadCvars();

    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);

    // 可选插件在比赛配置执行时可能是晚加载，补挂已经在场的玩家。
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
    g_iShootersNeeded = g_hShootersNeeded.IntValue;
    g_fWindow = g_hWindow.FloatValue;
    g_fMultiplier = g_hMultiplier.FloatValue;

    if (g_iShootersNeeded < 1) {
        g_iShootersNeeded = 1;
    }
}

public void OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
}

public void OnClientDisconnect(int client)
{
    // 清掉以该槽位为受害者/攻击者的记录，避免短时间内复用槽位造成误判。
    for (int i = 1; i <= MaxClients; i++) {
        g_fLastMachineGunHit[client][i] = 0.0;
        g_fLastMachineGunHit[i][client] = 0.0;
    }
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    for (int victim = 1; victim <= MaxClients; victim++) {
        for (int attacker = 1; attacker <= MaxClients; attacker++) {
            g_fLastMachineGunHit[victim][attacker] = 0.0;
        }
    }
}

public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
    if (!g_bEnabled || damage <= 0.0 || !(damagetype & DMG_BULLET)) {
        return Plugin_Continue;
    }

    if (!IsTank(victim) || !IsSurvivorShooter(attacker) || !IsMachineGun(inflictor, attacker)) {
        return Plugin_Continue;
    }

    float now = GetGameTime();
    g_fLastMachineGunHit[victim][attacker] = now;

    int activeGuns = 0;
    for (int i = 1; i <= MaxClients; i++) {
        float lastHit = g_fLastMachineGunHit[victim][i];
        if (lastHit <= 0.0 || now < lastHit || now - lastHit > g_fWindow) {
            continue;
        }

        if (IsSurvivorShooter(i)) {
            activeGuns++;
        }
    }

    if (activeGuns >= g_iShootersNeeded) {
        // 只对传入的 damage 做乘法，不改动项目通过 sm_weapon /
        // l4d2_weapon_attributes 写入的武器数据。这里的 damage 已经是
        // 项目原先修正后的值，乘 0.8 就是在该基础上的二次修正。
        damage *= g_fMultiplier;
        return Plugin_Changed;
    }

    return Plugin_Continue;
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
        && IsPlayerAlive(client)
        && GetEntProp(client, Prop_Send, "m_isIncapacitated") == 0);
}

bool IsMachineGun(int inflictor, int attacker)
{
    // 子弹伤害的 inflictor 是武器实体，优先按实体 classname 判断，避免切枪误判。
    if (inflictor > MaxClients && IsValidEntity(inflictor)) {
        char classname[64];
        if (GetEntityClassname(inflictor, classname, sizeof(classname))) {
            return IsMachineGunClass(classname);
        }

        return false;
    }

    // inflictor 不是武器实体（异常/其他伤害来源）时，退回判断攻击者当前武器。
    char weapon[64];
    GetClientWeapon(attacker, weapon, sizeof(weapon));
    return IsMachineGunClass(weapon);
}

bool IsMachineGunClass(const char[] classname)
{
    for (int i = 0; i < sizeof(g_sMachineGunClasses); i++) {
        if (StrEqual(classname, g_sMachineGunClasses[i], false)) {
            return true;
        }
    }

    return false;
}
