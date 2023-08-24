#include <sourcemod>
#include <sdkhooks>
#include <l4d2_skill_detect>
#include <colors>

public Plugin:myinfo =
{
	name = "Witch DPer",
	author = "CanadaRox",
	description = "Spawns witches for high damage pounces!",
	version = "1",
	url = ""
};

new Handle:wdp_minimum_height;
new Handle:wdp_per_height;
new Handle:wdp_multiwitch;

new Handle:z_hunter_max_pounce_bonus_damage;

/* First index: survivor, Second index: infected */
new bool:hitNonIncap[MAXPLAYERS+1][MAXPLAYERS+1];
new bool:causedIncap[MAXPLAYERS+1][MAXPLAYERS+1];

public OnPluginStart()
{
	for (new client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client))
		{
			OnClientPutInServer(client);
		}
	}
	wdp_minimum_height = CreateConVar("wdp_minimum_height", "600.0", "Amount of height required to spawn an extra witch", FCVAR_PLUGIN, true, 1.0, false);
	wdp_per_height = CreateConVar("wdp_per_height", "300.0", "Amount of per height to spawn an extra witch", FCVAR_PLUGIN, true, 1.0, false);
	wdp_multiwitch = CreateConVar("wdp_multiwitch", "9999", "Maximun number of witches to spawn for a single pounce.", FCVAR_PLUGIN, true, 0.0);
	z_hunter_max_pounce_bonus_damage = FindConVar("z_hunter_max_pounce_bonus_damage");

	HookEvent("round_start", RoundStart_Event, EventHookMode_PostNoCopy);
}

public RoundStart_Event(Handle:event, const String:name[], bool:dontBroadcast)
{
	for (new i = 0; i <= MAXPLAYERS; i++)
	{
		for (new j = 0; j <= MAXPLAYERS; j++)
		{
			hitNonIncap[i][j] = false;
			causedIncap[i][j] = false;
		}
	}
}

public OnClientPutInServer(client)
{
	SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
	SDKHook(client, SDKHook_OnTakeDamagePost, OnTakeDamagePost);
}

public Action:OnTakeDamage(victim, &attacker, &inflictor, &Float:damage, &damagetype)
{
	
	if (victim > 0 && victim <= MaxClients && attacker > 0 && attacker <= MaxClients)
	{
		if (!hitNonIncap[victim][attacker] && !isPlayerIncap(victim))
		{
			hitNonIncap[victim][attacker] = true;
		}
	}
}

public OnTakeDamagePost(victim, attacker, inflictor, Float:damage, damagetype)
{
	if (victim > 0 && victim <= MaxClients && attacker > 0 && attacker <= MaxClients)
	{
		if (hitNonIncap[victim][attacker] && isPlayerIncap(victim))
		{
			causedIncap[victim][attacker] = true;
			new Handle:pack = CreateDataPack();
			WritePackCell(pack, victim);
			WritePackCell(pack, attacker);
			CreateTimer(0.1, ResetCausedIncapTimer, pack);
		}
		hitNonIncap[victim][attacker] = false;
	}
}

public Action:ResetCausedIncapTimer(Handle:timer, Handle:pack)
{
	ResetPack(pack);
	new victim = ReadPackCell(pack);
	new attacker = ReadPackCell(pack);
	CloseHandle(pack);
	causedIncap[victim][attacker] = false;
}

public OnHunterHighPounce(hunter, survivor, actualDamage, Float:calculatedDamage, Float:height, bool:reportedHigh)
{
	if (!isPlayerIncap(survivor) || causedIncap[survivor][hunter])
	{
		calculatedDamage = calculatedDamage > GetConVarFloat(z_hunter_max_pounce_bonus_damage)+1 ?
			GetConVarFloat(z_hunter_max_pounce_bonus_damage)+1 : calculatedDamage;

		new flags = GetCommandFlags("z_spawn_old");
		SetCommandFlags("z_spawn_old", flags & ~FCVAR_CHEAT);

		new count = 0;
		new Float:pDistance = height;
		for (new i = GetConVarInt(wdp_multiwitch);
				i > 0 && pDistance > GetConVarInt(wdp_minimum_height);
				i--, pDistance -= GetConVarInt(wdp_per_height), count++)
		{
			FakeClientCommand(hunter, "z_spawn_old witch auto");
		}
		if (count >= 1)
		{
		    CPrintToChatAll("{red}%N{default} 以 {red}%.1f{default} 的高度突袭了 {olive}%N{default} , 生成 {green}%d{default} 个{red}Witch{default}!", hunter, height, survivor, count);
		}
		SetCommandFlags("z_spawn_old", flags);
	}
	else
	{
		//PrintToChatAll("%N pounced %N for %f damage!", hunter, survivor, calculatedDamage);
	}
}

stock bool:isPlayerIncap(client)
{
	return bool:GetEntProp(client, Prop_Send, "m_isIncapacitated");
}