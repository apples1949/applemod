#pragma semicolon 1
#pragma newdecls required

/*

	Created by DJ_WEST - 2020 update by Silvers.

	Web: http://amx-x.ru
	AMX Mod X and SourceMod Russian Community

*/
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "1.3.2.1"
#define CVAR_FLAGS FCVAR_NOTIFY
#define TEAM_INFECTED 3
#define CLASS_CHARGER 6
#define CLASS_TANK 8
#define PROP_CAR (1 << 0)
#define PROP_CAR_ALARM (1 << 1)
#define PROP_CONTAINER (1 << 2)
#define PROP_TRUCK (1 << 3)
#define PUSH_COUNT "m_iHealth"

public Plugin myinfo =
{
	name = "Charger Power",
	author = "DJ_WEST",
	description = "Allows charger to move objects (containers, cars, trucks) by hitting them when using own ability",
	version = PLUGIN_VERSION,
	url = "https://forums.alliedmods.net/showthread.php?p=2841574"
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	EngineVersion engine = GetEngineVersion();
	if(engine != Engine_Left4Dead2)
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 2.");
		return APLRes_SilentFailure;
	}
	return APLRes_Success;
}

PluginData plugin;

enum struct PluginCvars
{
	ConVar g_h_CvarChargerPowerPluginOn;
	ConVar g_h_CvarChargerPower;
	ConVar g_h_CvarChargerCarry;
	ConVar g_h_CvarObjects;
	ConVar g_h_CvarPushLimit;
	ConVar g_h_CvarRemoveObject;
	ConVar g_h_CvarChargerDamage;

	void Init()
	{
		CreateConVar("charger_power_version", PLUGIN_VERSION, "冲锋者力量插件版本", CVAR_FLAGS|FCVAR_DONTRECORD);
		this.g_h_CvarChargerPowerPluginOn = CreateConVar("l4d2_charger_power_on", "1", "启用/禁用插件", CVAR_FLAGS, true, 0.0, true, 1.0);
		this.g_h_CvarChargerPower = CreateConVar("l4d2_charger_power", "100.0", "冲锋者撞击物体的力度", CVAR_FLAGS, true, 0.0, true, 5000.0);
		this.g_h_CvarChargerCarry = CreateConVar("l4d2_charger_power_carry", "1", "冲锋者携带幸存者时是否可推动物体", CVAR_FLAGS, true, 0.0, true, 1.0);
		this.g_h_CvarObjects = CreateConVar("l4d2_charger_power_objects", "7", "可推动的物体类型（1 - 汽车，2 - 报警汽车，4 - 集装箱，8 - 卡车）", CVAR_FLAGS, true, 1.0, true, 15.0);
		this.g_h_CvarPushLimit = CreateConVar("l4d2_charger_power_push_limit", "2", "物体最多可被推动的次数", CVAR_FLAGS, true, 1.0, true, 100.0);
		this.g_h_CvarRemoveObject = CreateConVar("l4d2_charger_power_remove", "0", "在指定秒数后移除被推动的物体（0 为禁用）", CVAR_FLAGS, true, 0.0, true, 100.0);
		this.g_h_CvarChargerDamage = CreateConVar("l4d2_charger_power_damage", "0", "推动物体时冲锋者受到的额外伤害", CVAR_FLAGS, true, 0.0, true, 100.0);

		//Autoconfig for plugin
		//AutoExecConfig(true, "l4d2_charger_power");

		this.g_h_CvarChargerPowerPluginOn.AddChangeHook(OnConVarPluginOnChange);
		this.g_h_CvarChargerPower.AddChangeHook(ConVarChanged_Cvars);
		this.g_h_CvarChargerCarry.AddChangeHook(ConVarChanged_Cvars);
		this.g_h_CvarObjects.AddChangeHook(ConVarChanged_Cvars);
		this.g_h_CvarPushLimit.AddChangeHook(ConVarChanged_Cvars);
		this.g_h_CvarRemoveObject.AddChangeHook(ConVarChanged_Cvars);
		this.g_h_CvarChargerDamage.AddChangeHook(ConVarChanged_Cvars);
	}
}

enum struct PluginData
{
	PluginCvars cvars;
	bool bHooked;
	bool bPluginOn;
	float f_Power;
	bool bChargerCarry;
	int iObjects;
	int iPushLimit;
	float fRemoveObject;
	int iChargerDamage;
	float f_Origin[3];
	float fOrigin[3];
	float f_LastOrigin;
	float f_Angles[3];
	float f_EndOrigin[3];
	float f_Velocity[3];

	void Init()
	{
		this.cvars.Init();
	}

	void GetCvarValues()
	{
		this.f_Power = this.cvars.g_h_CvarChargerPower.FloatValue;
		this.bChargerCarry = this.cvars.g_h_CvarChargerCarry.BoolValue;
		this.iObjects = this.cvars.g_h_CvarObjects.IntValue;
		this.iPushLimit = this.cvars.g_h_CvarPushLimit.IntValue;
		this.fRemoveObject = this.cvars.g_h_CvarRemoveObject.FloatValue;
		this.iChargerDamage = this.cvars.g_h_CvarChargerDamage.IntValue;
	}

	void IsAllowed()
	{
		this.bPluginOn = this.cvars.g_h_CvarChargerPowerPluginOn.BoolValue;
		if(!this.bHooked && this.bPluginOn)
		{
			this.bHooked = true;
			HookEvent("charger_charge_end", Events);
		}
		else if(this.bHooked && !this.bPluginOn)
		{
			this.bHooked = false;
			UnhookEvent("charger_charge_end", Events);
		}
	}
}

public void OnPluginStart()
{
	plugin.Init();
}

public void OnConfigsExecuted()
{
	plugin.IsAllowed();
	plugin.GetCvarValues();
}

void OnConVarPluginOnChange(ConVar cvar, const char[] oldVal, const char[] newVal)
{
	plugin.IsAllowed();
}

void ConVarChanged_Cvars(ConVar cvar, const char[] oldVal, const char[] newVal)
{
	plugin.GetCvarValues();
}

Action Events(Event event, char[] name, bool dontBroadcast)
{
    if(strcmp(name, "charger_charge_end") == 0)
    {
        int i_Client = GetClientOfUserId(event.GetInt("userid"));

        if (!i_Client || !IsClientInGame(i_Client))
            return Plugin_Continue;

        if (!plugin.bChargerCarry && GetEntProp(i_Client, Prop_Send, "m_carryVictim") > 0)
            return Plugin_Continue;

        GetClientAbsOrigin(i_Client, plugin.f_Origin);
        GetClientAbsAngles(i_Client, plugin.f_Angles);
        plugin.f_Origin[2] += 20.0;

        Handle h_Trace = TR_TraceRayFilterEx(plugin.f_Origin, plugin.f_Angles, MASK_ALL, RayType_Infinite, TraceFilterClients, i_Client);

        if (TR_DidHit(h_Trace))
        {
            int i_Target = TR_GetEntityIndex(h_Trace);
            TR_GetEndPosition(plugin.f_EndOrigin, h_Trace);
            delete h_Trace;

            if (i_Target > 0 && IsValidEdict(i_Target) && GetVectorDistance(plugin.f_Origin, plugin.f_EndOrigin) <= 100.0)
            {
                if (GetEntityMoveType(i_Target) != MOVETYPE_VPHYSICS)
                {
                    return Plugin_Continue;
                }

                int i_PushCount = GetEntProp(i_Target, Prop_Data, PUSH_COUNT);

                if (i_PushCount >= plugin.iPushLimit)
                {
                    return Plugin_Continue;
                }

                char s_ClassName[16];
                GetEdictClassname(i_Target, s_ClassName, sizeof(s_ClassName));

                if (StrEqual(s_ClassName, "prop_physics") || StrEqual(s_ClassName, "prop_car_alarm"))
                {
                    char s_ModelName[64];
                    GetEntPropString(i_Target, Prop_Data, "m_ModelName", s_ModelName, sizeof(s_ModelName));

                    if (StrEqual(s_ClassName, "prop_car_alarm") && !(plugin.iObjects & PROP_CAR_ALARM))
                        return Plugin_Continue;
                    else if (StrContains(s_ModelName, "car") != -1 && !(plugin.iObjects & PROP_CAR) && !(plugin.iObjects & PROP_CAR_ALARM))
                        return Plugin_Continue;
                    else if (StrContains(s_ModelName, "dumpster") != -1 && !(plugin.iObjects & PROP_CONTAINER))
                        return Plugin_Continue;
                    else if (StrContains(s_ModelName, "forklift") != -1 && !(plugin.iObjects & PROP_TRUCK))
                        return Plugin_Continue;

                    i_PushCount++;
                    SetEntProp(i_Target, Prop_Data, PUSH_COUNT, i_PushCount);

                    GetAngleVectors(plugin.f_Angles, plugin.f_Velocity, NULL_VECTOR, NULL_VECTOR);
                    plugin.f_Velocity[0] *= plugin.f_Power;
                    plugin.f_Velocity[1] *= plugin.f_Power;
                    plugin.f_Velocity[2] *= plugin.f_Power;
                    SetEntPropEnt(i_Target, Prop_Data, "m_hPhysicsAttacker", i_Client);
                    SetEntPropFloat(i_Target, Prop_Data, "m_flLastPhysicsInfluenceTime", GetGameTime());
                    TeleportEntity(i_Target, NULL_VECTOR, NULL_VECTOR, plugin.f_Velocity);

                    DataPack h_Pack;
                    CreateDataTimer(0.5, CheckEntity, h_Pack);
                    h_Pack.WriteCell(EntIndexToEntRef(i_Target));
                    h_Pack.WriteFloat(plugin.f_EndOrigin[0]);

                    if (plugin.iChargerDamage)
                    {
                        int i_Health = GetClientHealth(i_Client);
                        i_Health -= plugin.iChargerDamage;

                        if (i_Health > 0)
                        {
                            SetEntityHealth(i_Client, i_Health);
                        }
                        else
                        {
                            ForcePlayerSuicide(i_Client);
                        }
                    }

                    if (plugin.fRemoveObject > 0.0)
                    {
                        CreateTimer(plugin.fRemoveObject, TimerRemoveEntity, EntIndexToEntRef(i_Target), TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
                    }
                }
            }
        }
        delete h_Trace;
    }
    return Plugin_Continue;
}

Action TimerRemoveEntity(Handle h_Timer, any i_Ent)
{
	if (EntRefToEntIndex(i_Ent) != INVALID_ENT_REFERENCE)
	{
		if (HasAliveTank())
			return Plugin_Continue;
		else
			RemoveEntity(i_Ent);
	}
	return Plugin_Stop;
}

stock bool TraceFilterClients(int i_Entity, int i_Mask, any i_Data)
{
	return i_Entity != i_Data && i_Entity > 0 && i_Entity > MaxClients && IsValidEdict(i_Entity) && IsValidEntity(i_Entity);
}

Action CheckEntity(Handle h_Timer, DataPack h_Pack)
{
	h_Pack.Reset();
	int i_Ent = EntRefToEntIndex(h_Pack.ReadCell());
	if(i_Ent == INVALID_ENT_REFERENCE)
	{
		return Plugin_Stop;
	}

	plugin.f_LastOrigin = h_Pack.ReadFloat();
	if (IsValidEdict(i_Ent))
	{
		GetEntPropVector(i_Ent, Prop_Data, "m_vecOrigin", plugin.fOrigin);
		if (plugin.fOrigin[0] != plugin.f_LastOrigin)
		{
			DataPack h_NewPack;
			CreateDataTimer(0.1, CheckEntity, h_NewPack);
			h_NewPack.WriteCell(EntIndexToEntRef(i_Ent));
			h_NewPack.WriteFloat(plugin.fOrigin[0]);
			return Plugin_Continue;
		}
		else
		{
			TeleportEntity(i_Ent, NULL_VECTOR, NULL_VECTOR, view_as<float>({0.0, 0.0, 0.0}));
			return Plugin_Stop;
		}
	}
	return Plugin_Stop;
}

stock int IsValidEnt(int i_Ent)
{
	return (IsValidEdict(i_Ent) && IsValidEntity(i_Ent));
}

bool HasAliveTank()
{
	for (int i = 1; i <= MaxClients; i++) {
		if (IsAliveTank(i)) {
			return true;
		}
	}

	return false;
}

bool IsAliveTank(int client)
{
	return (IsClientInGame(client) && GetClientTeam(client) == TEAM_INFECTED && IsPlayerAlive(client) && GetEntProp(client, Prop_Send, "m_zombieClass") == CLASS_TANK);
}