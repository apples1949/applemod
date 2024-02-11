#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

public Plugin:myinfo =
{
	name = "Witch Always Incaps",
	author = "epilimic",
	//thanks to canadarox, tab, and dr gregory house!
	description = "Makes the witch always incap!",
	version = "1",
	url = ""
};

new bool:isLateLoad;
new Handle:pain_pills_decay_rate;

public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max)
{
	isLateLoad = late;
	return APLRes_Success;
}

public OnPluginStart()
{
	if (isLateLoad)
	{
		for (new client = 1; client <= MaxClients; client++)
		{
			if (IsClientInGame(client))
			{
				OnClientPutInServer(client);
			}
		}
	}
	pain_pills_decay_rate = FindConVar("pain_pills_decay_rate");
}

public OnClientPutInServer(client)
{
	SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
}

public Action: OnTakeDamage(victim, &attacker, &inflictor, &Float:damage, &damagetype)
{
	if (victim > 0 && victim <= MaxClients && !IsPlayerIncap(victim))
	{
		if (IsWitch(attacker))
		{
			damage = GetSurvivorHealth(victim);
			return Plugin_Changed;
		}
	}
	return Plugin_Continue;
}

stock bool: IsWitch(entity)
{
    if ( !IsValidEntity(entity) || !IsValidEdict(entity) ) { return false; }
    
    decl String: classname[24];
    GetEntityClassname(entity, classname, sizeof(classname));
    if ( !StrEqual(classname, "witch") ) { return false; }
    
    return true;
}

stock GetPermHealth(client)
{
    return GetEntProp(client, Prop_Send, "m_iHealth");
}

stock Float:GetTempHealth(client)
{
    new Float:tmp = GetEntPropFloat(client, Prop_Send, "m_healthBuffer") - ((GetGameTime() - GetEntPropFloat(client, Prop_Send, "m_healthBufferTime")) * GetConVarFloat(pain_pills_decay_rate));
    return tmp > 0 ? tmp : 0.0;
}

stock Float:GetSurvivorHealth(client) return GetPermHealth(client) + GetTempHealth(client);

stock bool:IsPlayerIncap(client)
{
    return bool:GetEntProp(client, Prop_Send, "m_isIncapacitated");
}
