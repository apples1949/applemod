#include <sourcemod>

#pragma semicolon 1

#define RECONNECT_WINDOW 30.0
#define LOG_FILE         "netmonitor.log"

bool    g_bTimingOut[MAXPLAYERS+1];
float   g_fDisconnectTime[MAXPLAYERS+1];
bool    g_bExcluded[MAXPLAYERS+1];

public Plugin myinfo = 
{
    name        = "连接状态广播",
    author      = "apples1949",
    description = "检测网络超时与快速重连，排除主动断开/踢出/封禁",
    version     = "1.0.0",
    url         = ""
};

public void OnPluginStart()
{
    CreateTimer(1.0, Timer_CheckTimeout, _, TIMER_REPEAT);

    HookEvent("player_disconnect", Event_PlayerDisconnect);
}

void LogNetMonitor(int client, const char[] reason)
{
    char name[MAX_NAME_LENGTH];
    GetClientName(client, name, sizeof(name));

    char time[32];
    FormatTime(time, sizeof(time), "%Y-%m-%d %H:%M:%S");

    LogToFileEx(LOG_FILE, "%s | %s | %s", time, name, reason);
}

public Action Timer_CheckTimeout(Handle timer)
{
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
                LogNetMonitor(client, "超时");
                PrintToChatAll("%s 失去与服务器的连接", name);
            }
            else
            {
                LogNetMonitor(client, "超时回复");
                PrintToChatAll("%s 恢复与服务器的连接", name);
            }
        }
    }
    return Plugin_Continue;
}

public void Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);

    if (client < 1 || client > MaxClients || IsFakeClient(client))
        return;

    char reason[64];
    event.GetString("reason", reason, sizeof(reason));

    if (StrContains(reason, "disconnect", false) != -1 ||
        StrContains(reason, "kick", false)     != -1 ||
        StrContains(reason, "ban", false)      != -1)
    {
        g_bExcluded[client] = true;
        g_fDisconnectTime[client] = 0.0;
    }
    else
    {
        g_bExcluded[client] = false;
        g_fDisconnectTime[client] = GetGameTime();
        LogNetMonitor(client, "非主动离开");
    }
}

public void OnClientPutInServer(int client)
{
    if (client < 1 || client > MaxClients || IsFakeClient(client))
        return;

    if (!g_bExcluded[client] &&
        g_fDisconnectTime[client] != 0.0 &&
        GetGameTime() - g_fDisconnectTime[client] <= RECONNECT_WINDOW)
    {
        char name[MAX_NAME_LENGTH];
        GetClientName(client, name, sizeof(name));
        LogNetMonitor(client, "快速回复");
        PrintToChatAll("%s 恢复与服务器的连接", name);
    }

    g_fDisconnectTime[client] = 0.0;
    g_bExcluded[client] = false;
    g_bTimingOut[client] = false;
}