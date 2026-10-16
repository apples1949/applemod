#include <sourcemod>

#pragma semicolon 1

#define RECONNECT_WINDOW 30
#define AUTH_LENGTH 32

bool    g_bTimingOut[MAXPLAYERS+1];
char    g_sAuth[MAXPLAYERS+1][AUTH_LENGTH];
StringMap g_hDisconnectTimes;

public Plugin myinfo = 
{
    name        = "连接状态广播",
    author      = "apples1949",
    description = "检测网络超时与快速重连，排除主动断开/踢出/封禁",
    version     = "1.1.0",
    url         = ""
};

public void OnPluginStart()
{
    g_hDisconnectTimes = new StringMap();
    CreateTimer(1.0, Timer_CheckTimeout, _, TIMER_REPEAT);

    HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Pre);

    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientConnected(client) && !IsFakeClient(client))
            CacheClientAuth(client);
    }
}

public Action Timer_CheckTimeout(Handle timer)
{
    PurgeExpiredDisconnects();

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
        {
            g_bTimingOut[client] = false;
            continue;
        }

        bool timingOut = IsClientTimingOut(client);

        if (timingOut != g_bTimingOut[client])
        {
            g_bTimingOut[client] = timingOut;

            char name[MAX_NAME_LENGTH];
            GetClientName(client, name, sizeof(name));

            if (timingOut)
            {
                PrintToChatAll("\x04[连接状态]\x01 %s \x03失去与服务器的连接", name);
            }
            else
            {
                PrintToChatAll("\x04[连接状态]\x01 %s \x04恢复与服务器的连接", name);
            }
        }
    }
    return Plugin_Continue;
}

public void Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client != 0 && IsFakeClient(client))
        return;

    // Cache authentication before the client leaves. The event identity also
    // works if the disconnect callback has already cleared the client slot.
    char auth[AUTH_LENGTH];
    if (client != 0)
    {
        CacheClientAuth(client);
        strcopy(auth, sizeof(auth), g_sAuth[client]);
    }
    if (auth[0] == '\0')
        event.GetString("networkid", auth, sizeof(auth));
    if (!IsSteamAuth(auth))
        return;

    char reason[64];
    event.GetString("reason", reason, sizeof(reason));

    if (StrContains(reason, "disconnect", false) != -1 ||
        StrContains(reason, "kick", false)     != -1 ||
        StrContains(reason, "ban", false)      != -1)
    {
        g_hDisconnectTimes.Remove(auth);
    }
    else
    {
        g_hDisconnectTimes.SetValue(auth, GetTime());
    }
}

public void OnClientConnected(int client)
{
    g_sAuth[client][0] = '\0';
    g_bTimingOut[client] = false;
}

public void OnClientAuthorized(int client, const char[] auth)
{
    if (IsFakeClient(client))
        return;

    // Authorization may arrive before or after OnClientPutInServer.
    if (IsSteamAuth(auth))
        strcopy(g_sAuth[client], sizeof(g_sAuth[]), auth);
    TryAnnounceReconnect(client);
}

public void OnClientPutInServer(int client)
{
    g_bTimingOut[client] = false;
    if (IsFakeClient(client))
        return;

    CacheClientAuth(client);
    TryAnnounceReconnect(client);
}

public void OnClientDisconnect(int client)
{
    g_sAuth[client][0] = '\0';
    g_bTimingOut[client] = false;
}

void CacheClientAuth(int client)
{
    if (!IsClientAuthorized(client))
        return;

    char auth[AUTH_LENGTH];
    if (GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth)) && IsSteamAuth(auth))
        strcopy(g_sAuth[client], sizeof(g_sAuth[]), auth);
}

bool IsSteamAuth(const char[] auth)
{
    return StrContains(auth, "STEAM_", false) == 0 && StrContains(auth, ":") != -1;
}

void TryAnnounceReconnect(int client)
{
    if (!IsClientInGame(client) || g_sAuth[client][0] == '\0')
        return;

    int disconnectedAt;
    if (!g_hDisconnectTimes.GetValue(g_sAuth[client], disconnectedAt))
        return;

    // Consume by identity, including expired entries, so a later auth callback
    // cannot broadcast the same reconnect twice.
    g_hDisconnectTimes.Remove(g_sAuth[client]);
    int elapsed = GetTime() - disconnectedAt;
    if (elapsed >= 0 && elapsed <= RECONNECT_WINDOW)
    {
        char name[MAX_NAME_LENGTH];
        GetClientName(client, name, sizeof(name));
        PrintToChatAll("\x04[连接状态]\x01 %s \x04恢复与服务器的连接", name);
    }
}

void PurgeExpiredDisconnects()
{
    int now = GetTime();
    StringMapSnapshot snapshot = g_hDisconnectTimes.Snapshot();
    char auth[AUTH_LENGTH];
    int disconnectedAt;
    for (int index = 0; index < snapshot.Length; index++)
    {
        snapshot.GetKey(index, auth, sizeof(auth));
        if (g_hDisconnectTimes.GetValue(auth, disconnectedAt)
            && (now < disconnectedAt || now - disconnectedAt > RECONNECT_WINDOW))
        {
            g_hDisconnectTimes.Remove(auth);
        }
    }
    delete snapshot;
}
