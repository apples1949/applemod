#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <left4dhooks>
#include <readyup>
#include <colors>

#define TAG	  "{olive}[{lightred}!{olive}]{orange}"
#define DEBUG 0

char TAG_WEAPON_NAME[][][] =
{
	{"SG552突击步枪"	,"weapon_rifle_sg552"},
	{"MP5冲锋枪"		,"weapon_smg_mp5"},
	{"木狙"			,"weapon_hunting_rifle"},
	{"awp"			,"weapon_sniper_awp"},
	{"鸟狙"			,"weapon_sniper_scout"},
	{"可以捡子弹的电锯"				,"weapon_chainsaw"}
};

public Plugin myinfo =
{
	name		= "give weapon before readyup",
	author		= "apples1949,游而戏之",
	description = "none",
	version		= "1.0",
	url			= "none",
}

int	 Select[MAXPLAYERS + 1]		   = { -1, ... };
bool PlayerHaveWpn[MAXPLAYERS + 1] = { false, ... };

public void OnPluginStart()
{
	HookEvent("round_start", clearcvar);
	HookEvent("map_transition", clearcvar);
	HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Pre);

	RegConsoleCmd("sm_wpn", cmdwpn);
}

bool g_enb;

public void OnRoundIsLive()
{
	g_enb = false;
}

public void OnReadyUpInitiate()
{
	g_enb = true;
}

public Action cmdwpn(int client, int args)
{
#if DEBUG
	PrintToChatAll("IsFakeClient:%d GetClientTeam:%d PlayerHaveWpn:%d !g_enb:%d", IsFakeClient(client), GetClientTeam(client), PlayerHaveWpn[client], !g_enb);
#endif
	// if (IsFakeClient(client) || GetClientTeam(client) != 2 || PlayerHaveWpn[client] || !g_enb) return Plugin_Handled;
	if (IsFakeClient(client) || GetClientTeam(client) != 2) return Plugin_Handled;
	if (PlayerHaveWpn[client])
	{
		CPrintToChat(client, "%s你已获取过武器!", TAG);
		return Plugin_Handled;
	}
	if (!g_enb)
	{
		CPrintToChat(client, "%s游戏已开始!请在游戏开始前获取武器!", TAG);
		return Plugin_Handled;
	}
	Menu menu = new Menu(givewpn);
	menu.SetTitle("请选择你的武器(1次机会)");
	for (int i; i < sizeof TAG_WEAPON_NAME; i++)
		menu.AddItem("", TAG_WEAPON_NAME[i][0]);
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
	return Plugin_Handled;
}

public int givewpn(Menu menu, MenuAction action, int client, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			switch (param2)
			{
				case 0, 1, 2, 3, 4, 5:
				{
					Select[client] = param2;
					Give(client);
				}
			}
		}
	}

	return 0;
}

void clearcvar(Event event, const char[] name, bool dontBroadcast)
{
	for (int i = 1; i <= MaxClients; i++) Reset(i);
}
void Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	if (client != 0)
		Reset(client);
}

public void Give(int client)

{
	CPrintToChatAll("%s玩家 {lightgreen}%N {lightred}通过指令!wpn获取武器: {lightgreen}%s", TAG, client, TAG_WEAPON_NAME[Select[client]][0]);
	CheatCommand(client, "give", TAG_WEAPON_NAME[Select[client]][1]);
	PlayerHaveWpn[client] = true;
}

stock void CheatCommand(int client, char[] command, char[] arguments)
{
	if (!client) return;
	int admin = GetUserFlagBits(client);
	int flags = GetCommandFlags(command);

	SetUserFlagBits(client, ADMFLAG_ROOT);
	SetCommandFlags(command, flags & ~FCVAR_CHEAT);

	FakeClientCommand(client, "%s %s", command, arguments);

	SetCommandFlags(command, flags);
	SetUserFlagBits(client, admin);
}

void Reset(int client)
{
#if DEBUG
	PrintToChatAll("before Reset Select:%d PlayerHaveWpn:%d", Select[client], PlayerHaveWpn[client]);
#endif
	Select[client]		  = -1;
	PlayerHaveWpn[client] = false;
#if DEBUG
	PrintToChatAll("After Reset Select:%d PlayerHaveWpn:%d", Select[client], PlayerHaveWpn[client]);
#endif
}