#include <sourcemod>
#include <sdktools>
#pragma semicolon 1

#define L4D_TEAM_INFECTED         3 
#define L4D2_ZOMBIECLASS_TANK     8 
//new result_int;

public Plugin:myinfo =
{
	name = "Infected Suicide Booth",
	author = "epilimic",
	//Used code from Impact123, Skorpion1976, Mr. Zero, and purpletreefactory. Some of it worked, none did what I needed until I combined and fixed. Huzzah!
	description = "Suicide as infected if stuck with !kill, !stuck, !suicide, or !insertquarter. </futuramathrowback>",
	version = "1",
	url = "http://buttsecs.org"
}

public OnPluginStart()
{
	RegConsoleCmd("sm_stuck", Command_Kill);
	RegConsoleCmd("sm_kill", Command_Kill);
	RegConsoleCmd("sm_suicide", Command_Kill);
	RegConsoleCmd("sm_insertquarter", Command_Kill);
    
	AddCommandListener(Listener, "kill");
	AddCommandListener(Listener, "explode");
}

public Action:Command_Kill(client, args)
{
	if (client == 0 || !IsClientInGame(client) || GetClientTeam(client) != L4D_TEAM_INFECTED || !IsPlayerAlive(client)) 
	{ 
		return Plugin_Handled;
	} 

	if (!L4D_IsPlayerGhost(client))
	{ 
		new zombieClass = L4D_GetPlayerL4D2ZombieClass(client); 
		if (zombieClass != L4D2_ZOMBIECLASS_TANK)
		{
			ForcePlayerSuicide(client);/*
			result_int = GetURandomInt() % 2;
			if(result_int == 0)
				PrintToChat(client, "\x01-\x05Suicide Booth\x01- You are now dead. Thank you for using Stop-and-Drop, America's favorite suicide booth since 2008!");
			else
				PrintToChat(client, "\x01-\x05Suicide Booth\x01- You are now dead, please take your receipt.");*/
			//自杀就自杀 整什么花里胡哨的？还不如开放我自己的自杀插件
		}
	}
    
	return Plugin_Handled;
}

public Action:Listener(client, const String:command[], argc) 
{
	return Plugin_Handled;
}

stock L4D_GetPlayerL4D2ZombieClass(client) 
{ 
	if (!IsClientInGame(client)) return 0; 
	return GetEntProp(client, Prop_Send, "m_zombieClass"); 
}  

stock bool:L4D_IsPlayerGhost(client) 
{ 
	if (client < 0 ||  
		client > MaxClients ||  
		!IsClientInGame(client) ||  
		GetClientTeam(client) != L4D_TEAM_INFECTED)  
		return false; 

	return bool:GetEntProp(client, Prop_Send, "m_isGhost", 1); 
} 