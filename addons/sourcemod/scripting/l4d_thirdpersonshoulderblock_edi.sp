#pragma semicolon 1
#pragma newdecls required

#include <colors>
#include <sourcemod>
#define PLUGIN_VERSION "1.5"

#define L4D_TEAM_SPECTATOR 1

ConVar cvar_enabled;
ConVar cvar_action;

public Plugin myinfo =
{
	name        = "Thirdpersonshoulder Block",
	author      = "Don apples1949 edi",
	description = "Kicks clients who enable the thirdpersonshoulder mode on L4D1/2 to prevent them from looking around corners, through walls etc.",
	version     = PLUGIN_VERSION,
	url         = "http://forums.alliedmods.net/showthread.php?t=159582"


}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	/* Only load the plugin if the server is running Left 4 Dead or Left 4 Dead 2.
	 * Loading the plugin on Counter-Strike: Source or Team Fortress 2 would cause all clients to get kicked,
	 * because the thirdpersonshoulder mode and the corresponding ConVar that we check do not exist there.
	 */
	EngineVersion g_iEngine = GetEngineVersion();
	if (g_iEngine != Engine_Left4Dead && g_iEngine != Engine_Left4Dead2)
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 1 & 2.");
		return APLRes_SilentFailure;
	}
	return APLRes_Success;
}

public void OnPluginStart()
{
	CreateConVar("l4d_tpsblock_version", PLUGIN_VERSION, "Version of the Thirdpersonshoulder Block plugin", FCVAR_NOTIFY | FCVAR_DONTRECORD);

	cvar_enabled = CreateConVar("l4d_tpsblock_enabled", "1", "是否启用插件?", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	cvar_action = CreateConVar("l4d_tpsblock_action", "1", "如何处理启用第三人称的玩家? 1 - 移动到旁观, 0 - 踢出服务器", _, true, 0.0, true, 1.0);
	CreateTimer(GetRandomFloat(2.5, 3.5), CheckClients, _, TIMER_REPEAT);
}

public Action CheckClients(Handle timer)
{
	if (GetConVarBool(cvar_enabled))
	{
		for (int iClientIndex = 1; iClientIndex <= MaxClients; iClientIndex++)
		{
			if (IsClientInGame(iClientIndex) && !IsFakeClient(iClientIndex))
			{	// Only query clients on survivor or infected team, ignore spectators.
				if (GetClientTeam(iClientIndex) != L4D_TEAM_SPECTATOR)
				{
					QueryClientConVar(iClientIndex, "c_thirdpersonshoulder", QueryClientConVarCallback);
				}
			}
		}
	}
	return Plugin_Handled;
}

public void QueryClientConVarCallback(QueryCookie cookie, int client, ConVarQueryResult result, char[] cvarName, char[] cvarValue)
{
	if (IsClientInGame(client) && !IsClientInKickQueue(client))
	{
		/* If the ConVar was somehow not found on the client, is not valid or is protected, kick the client.
		 * The ConVar should always be readable unless the client is trying to prevent it from being read out.
		 */
		if (result != ConVarQuery_Okay)

		{
			if (cvar_action.IntValue == 0) {
				KickClient(client, "服务器不允许开启第三人称!请在控制台输入 c_thirdpersonshoulder 0 再进入游戏!");
				CPrintToChatAll("[{green}!{default}]{orange} %N 试图开启第三人称被服务器自动踢出!服务器不允许开启第三人称!",client);
			} else {
				ChangeClientTeam(client, L4D_TEAM_SPECTATOR);
				CPrintToChat(client, "[{green}!{default}]命令 {olive}c_thirdpersonshoulder{default} 是无效或者被保护的. 请你在控制台输入 c_thirdpersonshoulder 0 再加入游戏!");
				PrintHintText(client, "命令 c_thirdpersonshoulder 是无效或者被保护的. 请你在控制台输入 c_thirdpersonshoulder 0 再加入游戏!");
				PrintCenterText(client, "命令 {olive}c_thirdpersonshoulder 是无效或者被保护的. 请你在控制台输入 c_thirdpersonshoulder 0 再加入游戏!");
				CPrintToChatAll("[{green}!{default}]{orange} %N 试图开启第三人称被服务器强制旁观!服务器不允许开启第三人称! 请ta在控制台输入 c_thirdpersonshoulder 0 再加入游戏!",client);
			}
		}
		/* If the ConVar was found on the client, but is not set to either "false" or "0",
		 * kick the client as well, as he might be using thirdpersonshoulder.
		 */
		else if (!StrEqual(cvarValue, "false") && !StrEqual(cvarValue, "0"))
		{
			if (cvar_action.IntValue == 0) {
				KickClient(client, "服务器不允许开启第三人称!请在控制台输入 c_thirdpersonshoulder 0 再进入游戏!");
				CPrintToChatAll("[{green}!{default}]{orange} %N 因处于开启第三人称进入被服务器自动踢出!服务器不允许开启第三人称!",client);
			} else {
				ChangeClientTeam(client, L4D_TEAM_SPECTATOR);
				CPrintToChat(client, "[{green}!{default}]服务器不允许开启第三人称， 为了正常游玩，请你在控制台输入 {olive}c_thirdpersonshoulder 0 {default}再加入游戏.");
				PrintHintText(client, "服务器不允许开启第三人称， 为了正常游玩，请你在控制台输入 c_thirdpersonshoulder 0 再加入游戏.");
				PrintCenterText(client, "服务器不允许开启第三人称， 为了正常游玩，请你在控制台输入 c_thirdpersonshoulder 0 再加入游戏.");
				CPrintToChatAll("[{green}!{default}]{orange} %N 因处于开启第三人称的状态下进入服务器而被强制旁观!服务器不允许开启第三人称! 请ta在控制台输入 c_thirdpersonshoulder 0 再加入游戏!",client);
			}
		}
	}
}
