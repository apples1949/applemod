#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <sendproxy>

#define HIDDEN_TEAM 1    // 1 = 旁观者

bool g_bEnabled[MAXPLAYERS+1];
int g_iNearbyPlayers[MAXPLAYERS+1][2];  // 缓存的最近 2 个队友
int g_iNextCalc[MAXPLAYERS+1];         // 下次重算距离的时间
int g_iManagerEnt = -1;
int g_iManagerRef = -1;
int g_iTeamOffset = -1;

public Plugin myinfo = {
    name        = "Test Hud Nearest 2 (Forward)",
    author      = "test",
    description = "Show only nearest 2 survivors (persistent)",
    version     = "1.7",
    url         = ""
};

public void OnPluginStart()
{
    RegConsoleCmd("sm_test_hud", Cmd_TestHud);
    HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Pre);
    HookEvent("round_end", Event_RoundEnd, EventHookMode_Pre);
}

public void OnMapStart()
{
    FindManager();
}

void FindManager()
{
    g_iManagerEnt = FindEntityByClassname(-1, "terror_player_manager");
    if (g_iManagerEnt != -1) {
        g_iManagerRef = EntIndexToEntRef(g_iManagerEnt);
        g_iTeamOffset = GetEntSendPropOffs(g_iManagerEnt, "m_iTeam");
        if (g_iTeamOffset == -1) {
            LogError("Could not find m_iTeam offset");
        }
    }
}

public Action Cmd_TestHud(int client, int args)
{
    if (client == 0) return Plugin_Handled;

    g_bEnabled[client] = !g_bEnabled[client];
    if (g_bEnabled[client]) {
        PrintToChat(client, "\x04HUD: \x03Only nearest 2 survivors shown.");
        g_iNextCalc[client] = 0; // 立即更新
    } else {
        PrintToChat(client, "\x04HUD: \x03All survivors shown.");
    }
    return Plugin_Handled;
}

public void OnSendProxyPre()
{
    // 遍历所有客户端，为每个启用的客户端生成修改项
    for (int i = 1; i <= MaxClients; i++) {
        if (g_bEnabled[i] && IsClientInGame(i) && GetClientTeam(i) == 2) {
            UpdateClientHud(i);
        }
    }
}

stock void UpdateClientHud(int client)
{
    if (g_iManagerRef == -1 || g_iTeamOffset == -1) {
        FindManager();
        if (g_iManagerRef == -1 || g_iTeamOffset == -1) return;
    }

    int gameTick = GetGameTickCount();
    // 距离缓存控制
    if (gameTick >= g_iNextCalc[client]) {
        g_iNextCalc[client] = gameTick + 1;
        UpdateNearbyCache(client);
    }

    // 根据缓存隐藏远距离队友
    for (int target = 1; target <= MaxClients; target++) {
        if (target == client || !IsClientInGame(target) || !IsPlayerAlive(target) || GetClientTeam(target) != 2)
            continue;

        bool bNear = false;
        for (int i = 0; i < 2; i++) {
            if (g_iNearbyPlayers[client][i] == target) {
                bNear = true;
                break;
            }
        }

        if (!bNear) {
            // int survivorSlot = GetEntProp(target, Prop_Send, "m_survivorCharacter");
            // if (survivorSlot < 0 || survivorSlot > 3) continue;
            // int offset = g_iTeamOffset + survivorSlot * 4;
			int offset = g_iTeamOffset + target * 4;
            SendProxy.AddChangeCell(client, g_iManagerRef, offset, HIDDEN_TEAM);
        }
    }
	if(GetClientTeam(client) == 1)
		PrintToChat(client, "\x04Error: \x03Change self team incorrectly");
}

void UpdateNearbyCache(int client)
{
    ArrayList survList = new ArrayList();
    for (int target = 1; target <= MaxClients; target++) {
        if (target == client) continue;
        if (IsClientInGame(target) && IsPlayerAlive(target) && GetClientTeam(target) == 2)
            survList.Push(target);
    }

    int count = survList.Length;
    g_iNearbyPlayers[client][0] = 0;
    g_iNearbyPlayers[client][1] = 0;

    if (count > 0) {
        float[] dists = new float[count];
        for (int i = 0; i < count; i++)
            dists[i] = GetClientDistance(client, survList.Get(i));

        for (int i = 0; i < 2 && i < count; i++) {
            int bestIdx = i;
            for (int j = i + 1; j < count; j++)
                if (dists[j] < dists[bestIdx])
                    bestIdx = j;
            if (bestIdx != i) {
                float tmp = dists[i]; dists[i] = dists[bestIdx]; dists[bestIdx] = tmp;
                survList.SwapAt(i, bestIdx);
            }
            g_iNearbyPlayers[client][i] = survList.Get(i);
        }
    }
    delete survList;
}

float GetClientDistance(int client, int target)
{
    float pos1[3], pos2[3];
    GetClientAbsOrigin(client, pos1);
    GetClientAbsOrigin(target, pos2);
    return GetVectorDistance(pos1, pos2);
}

public void Event_PlayerDisconnect(Handle event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (client > 0) {
        g_bEnabled[client] = false;
    }
}

public void Event_RoundEnd(Handle event, const char[] name, bool dontBroadcast)
{
    for (int i = 1; i <= MaxClients; i++) {
        g_bEnabled[i] = false;
    }
}