#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <SteamWorks>
#include <colors>

public Plugin myinfo =
{
	name		= "简单获取玩家游戏时长",
	author		= "apples1949 , 豆瓣酱な",
	description = "简单获取玩家游戏时长",
	version		= "1.0",
	url			= "https://github.com/apples1949",
};

int	   i_Count[MAXPLAYERS + 1];
int	   i_PlayerTime[MAXPLAYERS + 1];
bool   CheckPluginLate = false;
int	   i_gametimemode;
int	   i_CheckPlayerGameCount;
int	   b_LimitPlayer;
int	   i_LimitPlayerMinGametime;
int	   i_LimitPlayerMaxGametime;
int	   i_LimitPlayerMode;
int	   i_Playtimedeal[MAXPLAYERS + 1];
bool   b_Enable;
ConVar c_ShowGametimeMode;
ConVar c_CheckPlayerGameCount;
ConVar c_LimitPlayer;
ConVar c_LimitPlayerMinGametime;
ConVar c_LimitPlayerMaxGametime;
ConVar c_LimitPlayerMode;
ConVar c_Enable;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	CheckPluginLate = late;
	return APLRes_Success;
}

public void OnPluginStart()
{
	LoadTranslations("GetPlayerGametime.phrases");
	c_Enable				 = CreateConVar("GetPlayerGametimeEnable", "1", "是否启用插件,0=禁用", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	c_ShowGametimeMode		 = CreateConVar("ShowGametimeMode", "1", "向玩家显示什么类型的游戏时长? 1=小时分钟 2=小时带两位小数", FCVAR_NOTIFY, true, 1.0, true, 2.0);
	c_CheckPlayerGameCount	 = CreateConVar("CheckPlayerGameCount", "8", "如果玩家连接或者插件中途启动获取玩家游戏时长失败,那么重复多少次获取玩家游戏时长? 0=禁用", FCVAR_NOTIFY, true, 0.0);
	c_LimitPlayer			 = CreateConVar("LimitPlayer", "0", "是否禁止符合时长条件的玩家进入服务器或进入对局? 0=禁用 1=启用", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	c_LimitPlayerMinGametime = CreateConVar("LimitPlayerMinGametime", "0", "最低禁止多少秒的玩家进入服务器或进入对局(小时乘3600)", FCVAR_NOTIFY, true, 1.0);
	c_LimitPlayerMaxGametime = CreateConVar("LimitPlayerMaxGametime", "10", "最高禁止多少秒的玩家进入服务器或进入对局(小时乘3600)", FCVAR_NOTIFY, true, 1.0);
	c_LimitPlayerMode		 = CreateConVar("LimitPlayerMode", "2", "如果LimitPlayer不为0,则如何处理符合时长区间的玩家? 1=踢出,2=移动到旁观(如果有补位检测插件不建议选2)", FCVAR_NOTIFY, true, 1.0, true, 2.0);

	c_Enable.AddChangeHook(ConVarChanged);
	c_ShowGametimeMode.AddChangeHook(ConVarChanged);
	c_CheckPlayerGameCount.AddChangeHook(ConVarChanged);
	c_LimitPlayer.AddChangeHook(ConVarChanged);
	c_LimitPlayerMinGametime.AddChangeHook(ConVarChanged);
	c_LimitPlayerMaxGametime.AddChangeHook(ConVarChanged);
	c_LimitPlayerMode.AddChangeHook(ConVarChanged);

	HookEvent("player_team", Event_PlayerTeam);

	RegConsoleCmd("sm_playertime", cmdplayertime);

	// AutoExecConfig(true, "GetPlayerGametime");
	if (CheckPluginLate)
	{
		lateload();
	}
}

public void ConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	GetCvars();
}

void GetCvars()
{
	b_Enable				 = c_Enable.BoolValue;
	i_gametimemode			 = c_ShowGametimeMode.IntValue;
	i_CheckPlayerGameCount	 = c_CheckPlayerGameCount.IntValue;
	b_LimitPlayer			 = c_LimitPlayer.BoolValue;
	i_LimitPlayerMaxGametime = c_LimitPlayerMaxGametime.IntValue;
	i_LimitPlayerMinGametime = c_LimitPlayerMinGametime.IntValue;
	i_LimitPlayerMode		 = c_LimitPlayerMode.IntValue;
}

public void OnClientPostAdminCheck(int client)
{
	if (b_Enable) return;
	if (!IsFakeClient(client))
	{
		i_Count[client]		   = 0;
		i_PlayerTime[client]   = 0;
		i_Playtimedeal[client] = 0;

		if (!GetPlayerGameTime(client))
		{
			// CPrintToChatAll("{green}[{blue}!{green}]{default}玩家{blue} %N {default}已连接,正在获取玩家的实际游戏时长.", client);
			CPrintToChatAll("%t", "PlayerConnect", client);
			CreateTimer(1.0, MoreGetPlayerGameTime, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
		}
		else
		{
			if (CheckPlayerGametime(client) && b_LimitPlayer)
			{
				LimitPlayer(client);
			}
			AnnouncePlayerTime(client);
		}
	}
}

public Action MoreGetPlayerGameTime(Handle timer, any client)
{
	if (i_CheckPlayerGameCount == 0) return Plugin_Stop;
	if ((client = GetClientOfUserId(client)) && IsValidClient(client) && !IsFakeClient(client))
	{
		i_Count[client] += 1;
		if (i_Count[client] >= i_CheckPlayerGameCount)
		{
			i_PlayerTime[client] = -2;
			return Plugin_Stop;
		}
		else
		{
			if (!GetPlayerGameTime(client))
			{
				i_PlayerTime[client] = -1;
				CreateTimer(1.0, MoreGetPlayerGameTime, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
			}
			else
			{
				AnnouncePlayerTime(client);
			}
		}
		return Plugin_Continue;
	}
	return Plugin_Stop;
}

public Action cmdplayertime(int client, int args)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i) && !IsFakeClient(i))
		{
			AnnouncePlayerTime(i);
		}
	}
	return Plugin_Handled;
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	int client	= GetClientOfUserId(event.GetInt("userid"));
	int oldteam = event.GetInt("oldteam");
	int iTeam	= event.GetInt("team");

	if (IsValidClient(client) && !IsFakeClient(client) && (oldteam == 1 || iTeam == 1) && b_LimitPlayer && CheckPlayerGametime(client))
	{
		LimitPlayer(client);
	}
}

public bool GetPlayerGameTime(int client)
{
	SteamWorks_RequestStats(client, 550);
	return SteamWorks_GetStatCell(client, "Stat.TotalPlayTime.Total", i_PlayerTime[client]);
}

public bool IsValidClient(int client)
{
	return client > 0 && client <= MaxClients && IsClientInGame(client);
}

public bool CheckPlayerGametime(int client)
{
	if (i_PlayerTime[client] >= i_LimitPlayerMinGametime && i_PlayerTime[client] <= i_LimitPlayerMaxGametime)
	{
		return true;
	}
	return false;
}

public void LimitPlayer(int client)
{
	if (!CheckPlayerGametime) return;
	if (i_LimitPlayerMode == 1)
	{
		// KickClient(client, "你因游戏时长不符合服务器规则而被自动踢出!");
		KickClient(client, "%t", "kickplayer");
	}
	else
	{
		ChangeClientTeam(client, 1);
		// CPrintToChatAll("{green}[{blue}!{green}]{default}玩家{blue} %N 因游戏时长不符合服务器规则而被强制移动到旁观!", client);
		CPrintToChatAll("%t", "forcespecplayer", "client");
	}
}

public void AnnouncePlayerTime(int client)
{
	if (b_Enable) return;
	if (IsClientConnected(client) && !IsFakeClient(client))
	{
		if (i_PlayerTime[client] > 0)
		{
			if (i_gametimemode == 1)
			{
				// CPrintToChatAll("{green}[{blue}!{green}]{default}玩家{blue} %N 的实际游戏时长是{blue} %d{default} 小时{blue} %d{default} 分钟.", client, i_PlayerTime[client] / 3600, i_PlayerTime[client] / 60 % 60);
				CPrintToChatAll("%t", "announcegametimemode1", client, i_PlayerTime[client] / 3600, i_PlayerTime[client] / 60 % 60);
			}
			else
			{
				float gametime = float(i_PlayerTime[client]);
				// CPrintToChatAll("{green}[{blue}!{green}]{default}玩家{blue} %N {default}的实际游戏时长是{blue} %.2f {default}小时", client, gametime / 3600);
				CPrintToChatAll("%t", "announcegametimemode2", client, gametime / 3600);
			}
			return;
		}
		if (i_PlayerTime[client] == -1)
		{
			// CPrintToChatAll("{green}[{blue}!{green}]{default}正在获取玩家{blue} %N {default}的游戏时长", client);
			CPrintToChatAll("%t", "RequestingPlayerGametime", client);
		}
		else if (i_PlayerTime[client] == -2)
		{
			// CPrintToChatAll("{green}[{blue}!{green}]{default}获取玩家{blue} %N {default}的游戏时长失败", client);
			CPrintToChatAll("%t", "FailureGetPlayerGametime", client);
		}
	}
}

public void lateload()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientAuthorized(i) && IsClientInGame(i)) OnClientPostAdminCheck(i);
	}
	CheckPluginLate = false;
}