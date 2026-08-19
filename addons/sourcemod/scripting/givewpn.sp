#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
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
	name		= "give weapon in safe area",
	author		= "apples1949,游而戏之",
	description = "none",
	version		= "1.1",
	url			= "none",
}

int	 Select[MAXPLAYERS + 1]		   = { -1, ... };
bool PlayerHaveWpn[MAXPLAYERS + 1] = { false, ... };
bool PlayerInSafeArea[MAXPLAYERS + 1] = { false, ... };

public void OnPluginStart()
{
	HookEvent("round_start", ResetAll);
	HookEvent("map_transition", ResetAll);
	HookEvent("player_spawn", Event_PlayerSpawn);
	HookEvent("player_entered_start_area", Event_SafeArea);
	HookEvent("player_left_start_area", Event_SafeArea);
	HookEvent("player_entered_checkpoint", Event_SafeArea);
	HookEvent("player_left_checkpoint", Event_SafeArea);
	HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Post);

	RegConsoleCmd("sm_wpn", cmdwpn);
}

public Action cmdwpn(int client, int args)
{
#if DEBUG
	PrintToChatAll("IsFakeClient:%d GetClientTeam:%d PlayerHaveWpn:%d PlayerInSafeArea:%d", IsFakeClient(client), GetClientTeam(client), PlayerHaveWpn[client], PlayerInSafeArea[client]);
#endif
	if (IsFakeClient(client) || GetClientTeam(client) != 2) return Plugin_Handled;
	if (!IsPlayerAlive(client))
	{
		CPrintToChat(client, "%s你已死亡,无法获取武器!", TAG);
		return Plugin_Handled;
	}
	if (PlayerHaveWpn[client])
	{
		CPrintToChat(client, "%s你已获取过武器!", TAG);
		return Plugin_Handled;
	}
	if (!PlayerInSafeArea[client])
	{
		CPrintToChat(client, "%s请回到安全区域后再获取武器!", TAG);
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
			// 菜单可能已打开很久, 期间玩家可能已死亡/离开安全区域, 再次校验
			if (!IsPlayerAlive(client))
			{
				CPrintToChat(client, "%s你已死亡,无法获取武器!", TAG);
				return 0;
			}
			if (!PlayerInSafeArea[client])
			{
				CPrintToChat(client, "%s你已离开安全区域,无法获取武器!", TAG);
				return 0;
			}
			if (PlayerHaveWpn[client])
				return 0;
			Select[client] = param2;
			Give(client);
		}
		case MenuAction_End:
		{
			delete menu;
		}
	}

	return 0;
}

void ResetAll(Event event, const char[] name, bool dontBroadcast)
{
	for (int i = 1; i <= MaxClients; i++) Reset(i);
}

void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	if (client > 0 && client <= MaxClients && IsClientInGame(client))
		PlayerInSafeArea[client] = true; // 出生点通常位于安全区域(开局安全屋/检查点)
}

void Event_SafeArea(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	if (client <= 0 || client > MaxClients || !IsClientInGame(client))
		return;

	if (StrEqual(name, "player_entered_start_area") || StrEqual(name, "player_entered_checkpoint"))
		PlayerInSafeArea[client] = true;
	else
		PlayerInSafeArea[client] = false;
}

void Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	if (client != 0)
		Reset(client);
}

public void Give(int client)
{
	if (Select[client] < 0 || Select[client] >= sizeof(TAG_WEAPON_NAME))
		return;

	CPrintToChatAll("%s玩家 {lightgreen}%N {lightred}通过指令!wpn获取武器: {lightgreen}%s", TAG, client, TAG_WEAPON_NAME[Select[client]][0]);
	CheatCommand(client, "give", TAG_WEAPON_NAME[Select[client]][1]);
	PlayerHaveWpn[client] = true;
}

stock void CheatCommand(int client, const char[] command, const char[] arguments)
{
	if (!client) return;
	int flags = GetCommandFlags(command);
	if (flags == -1) return;
	int admin = GetUserFlagBits(client);

	SetUserFlagBits(client, ADMFLAG_ROOT);
	SetCommandFlags(command, flags & ~FCVAR_CHEAT);

	FakeClientCommand(client, "%s %s", command, arguments);

	SetCommandFlags(command, flags);
	SetUserFlagBits(client, admin);
}

void Reset(int client)
{
#if DEBUG
	PrintToChatAll("before Reset Select:%d PlayerHaveWpn:%d PlayerInSafeArea:%d", Select[client], PlayerHaveWpn[client], PlayerInSafeArea[client]);
#endif
	Select[client]			 = -1;
	PlayerHaveWpn[client]	 = false;
	PlayerInSafeArea[client] = false;
#if DEBUG
	PrintToChatAll("After Reset Select:%d PlayerHaveWpn:%d PlayerInSafeArea:%d", Select[client], PlayerHaveWpn[client], PlayerInSafeArea[client]);
#endif
}
