#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>

#define PLUGIN_VERSION "1.0.0"

#define TEAM_SURVIVOR        2

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
    g_hDamage = null,
    g_hDebug = null;

bool
    g_bEnabled = true,
    g_bDebug = false;

float
    g_fDamage = 2.0;

// 仅用于 debug 诊断：记录本次狙击友伤在钩子里看到/写回的值，
// 再和 player_hurt 实际上报的 dmg_health 对比。
float
    g_fLastSeenDamage[MAXPLAYERS + 1],
    g_fLastSetDamage[MAXPLAYERS + 1];

public Plugin myinfo =
{
    name = "Applemod Sniper Friendly Fire Limit",
    author = "apples1949",
    description = "把狙击类武器造成的友伤固定为指定点数（默认 2 点）。",
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
        "applemod_sniper_ff_limit_enable", \
        "1", \
        "是否启用狙击类友伤固定点数。0=关闭, 1=开启。", \
        FCVAR_NOTIFY, true, 0.0, true, 1.0 \
    );

    g_hDamage = CreateConVar( \
        "applemod_sniper_ff_limit_damage", \
        "2.0", \
        "狙击类武器命中队友时固定造成的伤害点数。", \
        FCVAR_NOTIFY, true, 0.0, false, 0.0 \
    );

    g_hDebug = CreateConVar( \
        "applemod_sniper_ff_limit_debug", \
        "0", \
        "诊断开关：1=在狙击友伤发生时打印钩子内的伤害值与 player_hurt 实际上报的 dmg_health，用于确认落地伤害。", \
        FCVAR_NOTIFY, true, 0.0, true, 1.0 \
    );

    g_hEnabled.AddChangeHook(ConVarChanged);
    g_hDamage.AddChangeHook(ConVarChanged);
    g_hDebug.AddChangeHook(ConVarChanged);

    ReadCvars();

    HookEvent("player_hurt", Event_PlayerHurt, EventHookMode_Post);

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
    g_fDamage = g_hDamage.FloatValue;
    g_bDebug = g_hDebug.BoolValue;

    if (g_fDamage < 0.0) {
        g_fDamage = 0.0;
    }
}

public void OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
    ResetDebugState(client);
}

public void OnClientDisconnect(int client)
{
    ResetDebugState(client);
}

void ResetDebugState(int client)
{
    g_fLastSeenDamage[client] = 0.0;
    g_fLastSetDamage[client] = 0.0;
}

public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
    if (!g_bEnabled || damage <= 0.0 || !(damagetype & DMG_BULLET)) {
        return Plugin_Continue;
    }

    // victim 是被打的生还者，attacker 必须是另一名生还者：
    // 自伤（victim == attacker）不属于友伤，不处理。
    if (!IsSurvivor(victim) || !IsSurvivor(attacker) || victim == attacker) {
        return Plugin_Continue;
    }

    // 只认子弹伤害：狙击的枪托近战是 DMG_CLUB，不归本插件管。
    if (!IsSniper(inflictor, attacker)) {
        return Plugin_Continue;
    }

    if (g_bDebug) {
        g_fLastSeenDamage[victim] = damage;
        g_fLastSetDamage[victim] = g_fDamage;
    }

    // 直接改写伤害值。坦克/特感受伤走的是同一个钩子，这里已按队伍与武器类别过滤干净。
    damage = g_fDamage;
    return Plugin_Changed;
}

// 诊断用：只打印，不修改任何状态。
public void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_bDebug) {
        return;
    }

    int victim = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));

    if (!IsSurvivor(victim) || !IsSurvivor(attacker) || victim == attacker) {
        return;
    }

    if (g_fLastSetDamage[victim] <= 0.0) {
        return;
    }

    char sEventWeapon[64];
    event.GetString("weapon", sEventWeapon, sizeof(sEventWeapon));

    char sActiveWeapon[64];
    GetClientWeapon(attacker, sActiveWeapon, sizeof(sActiveWeapon));

    PrintToServer( \
        "[applemod_sniper_ff_limit] FF: %N -> %N, event weapon %s, active weapon %s, hook saw %.2f, set %.2f, applied dmg_health %d, health %d", \
        attacker, victim, sEventWeapon, sActiveWeapon, \
        g_fLastSeenDamage[victim], g_fLastSetDamage[victim], \
        event.GetInt("dmg_health"), event.GetInt("health") \
    );

    ResetDebugState(victim);
}

bool IsSurvivor(int client)
{
    return (client > 0
        && client <= MaxClients
        && IsClientInGame(client)
        && GetClientTeam(client) == TEAM_SURVIVOR
        && IsPlayerAlive(client));
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
