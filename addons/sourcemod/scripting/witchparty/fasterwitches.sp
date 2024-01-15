#include <sourcemod>
new bool:bIsFaster = false;
new bool:bFastRequest[2] = { false, false };
new String:	g_sTeamName[8][]					= {"Spectator", "" , "Survivor", "Infected", "", "Infected", "Survivors", "Infected"};
const 	NUM_OF_SURVIVORS 	= 4;
const 	TEAM_SURVIVOR		= 2;
const 	TEAM_INFECTED 		= 3;

public Plugin:myinfo = {
    name        = "Speed up the Witch spawn timer",
    author      = "epilimic, credit to ProdigySim - this started as the old BuffSI.",
    version     = "2",
    description = "Use !faster to call a vote to change the Witch spawn timer from 30 to 20 seconds. !forcefaster works for admins."
};

public OnPluginStart()
{
	RegConsoleCmd("sm_faster", RB_Command_FastWitchTimer);
	RegAdminCmd("sm_forcefaster", RB_Command_ForceFastWitchTimer, ADMFLAG_BAN, "Speed up Dem Witches");
}

public Action:RB_Command_FastWitchTimer(client, args)
{
	if(bIsFaster){PrintToChatAll("\x01[\x05Witch Party!\x01] 已加速Witch生成计时!");return Plugin_Handled;}
	
	new iTeam = GetClientTeam(client);
	if((iTeam == 2 || iTeam == 3) && !bFastRequest[iTeam-2])
	{
		bFastRequest[iTeam-2] = true;
	}
	else
	{
		return Plugin_Handled;
	}
	
	if(bFastRequest[0] && bFastRequest[1])
	{
		PrintToChatAll("\x01[\x05Witch Party!\x01] 两边都同意加快Witch计时的速度!");
		bIsFaster = true;
		FastWitchTimer(true);
	}
	else if(bFastRequest[0] || bFastRequest[1])
	{
		PrintToChatAll("\x01[\x05Witch Party!\x01]\x05 %s \x01要求加快女巫产卵的时间.\x05 %s \x01有30秒的时间来接受\x04 !faster \x01指令.",g_sTeamName[iTeam+4],g_sTeamName[iTeam+3]);
		CreateTimer(30.0, FastWitchTimerRequestTimeout);
	}
	
	return Plugin_Handled;
}

public Action:RB_Command_ForceFastWitchTimer(client, args)
{
	if(bIsFaster){PrintToChatAll("\x01[\x05Witch Party!\x01] 已加速Witch生成计时!");return Plugin_Handled;}
	bIsFaster = true;
	FastWitchTimer(true);
	PrintToChatAll("\x01[\x05Witch Party!\x01] 管理员已加速Witch生成计时!");
	return Plugin_Handled;
}

public Action:FastWitchTimerRequestTimeout(Handle:timer)
{
	if(bIsFaster){return;}
	ResetFastWitchTimerRequest();
}

ResetFastWitchTimerRequest()
{
	bFastRequest[0] = false;
	bFastRequest[1] = false;
}

FastWitchTimer(bool:enable)
{
	if(enable)
	{
		SetConVarInt(FindConVar("l4d_multiwitch_spawnfreq"),20);
	}
}

public OnConfigsExecuted()
{
	CreateTimer(2.0, Timer_HoldDaFuqUp);
}

public Action:Timer_HoldDaFuqUp(Handle:timer) 
{
	if(bIsFaster)
	{
		SetConVarInt(FindConVar("l4d_multiwitch_spawnfreq"),20);
	}
}
