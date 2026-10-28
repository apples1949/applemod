#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <multicolors>
#include <left4dhooks>
#define PLUGIN_VERSION 	"2.8"
#define PLUGIN_NAME		"l4d_pig_infected_notify"
#define DEBUG 0

public Plugin myinfo = 
{
	name = "[L4D/L4D2] Pig Infected Notify",
	author = "Harry Potter",
	description = "Show who the god teammate boom the Tank, Tank use which weapon(car,pounch,rock) to kill teammates S.I. and Witch , player open door to stun tank",
	version = PLUGIN_VERSION,
	url = "https://steamcommunity.com/profiles/76561198026784913/"
}

int ZC_TANK;
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    EngineVersion test = GetEngineVersion();

    if( test == Engine_Left4Dead )
    {
        ZC_TANK = 5;
    }
    else if( test == Engine_Left4Dead2 )
    {
        ZC_TANK = 8;
    }
    else
    {
        strcopy(error, err_max, "Plugin only supports Left 4 Dead 1 & 2.");
        return APLRes_SilentFailure;
    }

    return APLRes_Success;
}

#define TEAM_SPECTATOR		1
#define TEAM_SURVIVOR		2
#define TEAM_INFECTED		3
#define TEAM_HOLD_OUT		4

#define ZC_SMOKER		1
#define ZC_BOOMER		2
#define ZC_HUNTER		3
#define ZC_SPITTER		4
#define ZC_JOCKEY		5
#define ZC_CHARGER		6

#define ZC_Stumble_Time		1.0

#define TRANSLATION_FILE		PLUGIN_NAME ... ".phrases"

enum EDeathType
{
	eDeath_None,
	eDeath_SurvivorKill,
	eDeath_Suicide,
	eDeath_TankKill,
}

enum struct CBoomerDeath
{
	int attackerid;
	EDeathType eDeathType;
	char sWeapon[64];

	void Clear(){
		this.attackerid = 0;
		this.eDeathType = eDeath_None;
		this.sWeapon[0] = '\0';
	}
}

CBoomerDeath g_cBoomerDeath[MAXPLAYERS+1];

float g_fTankStaggerEngineTime[MAXPLAYERS+1];

public void OnPluginStart()
{
	LoadTranslations(TRANSLATION_FILE);

	HookEvent("player_spawn",           Event_PlayerSpawn);
	HookEvent("player_death", 			Event_PlayerDeath);
}

void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{ 
	int client = GetClientOfUserId(event.GetInt("userid"));
	g_cBoomerDeath[client].Clear();
}

void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));
	g_cBoomerDeath[victim].Clear();
	if( IsWitch(event.GetInt("attackerentid")) && victim != 0 && IsClientInGame(victim) && GetClientTeam(victim) == 3 )
	{
		if(!IsFakeClient(victim))//真人特感 player
		{
			CPrintToChatAll("%t", "l4d_pig_infected2");
		}
		else
		{
			CPrintToChatAll("%t", "l4d_pig_infected3");
		}
		return;
	}
	
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	static char weapon[32];
	GetEventString(event, "weapon", weapon, sizeof(weapon));//殺死人的武器名稱
	static char victimname[8];
	GetEventString(event, "victimname", victimname, sizeof(victimname));
	//PrintToChatAll("attacker: %d - victim: %d - weapon:%s - victimname:%s",attacker,victim,weapon,victimname);
	if((attacker == 0 || attacker == victim)
	&& victim != 0 && IsClientInGame(victim) && GetClientTeam(victim) == 3)//特感自殺
	{
		static char kill_weapon[50];

		if(StrEqual(weapon,"entityflame")||StrEqual(weapon,"env_fire"))//地圖的自然火
			FormatEx(kill_weapon, sizeof(kill_weapon), "%s","killed by fire");
		else if(StrEqual(weapon,"trigger_hurt"))//跳樓 跳海 地圖火 都有可能
			FormatEx(kill_weapon, sizeof(kill_weapon), "%s","killed by map");
		else if(StrEqual(weapon,"inferno") || StrEqual(weapon,"fire_cracker_blast"))//玩家丟的火或煙火盒
			return;
		else if(StrEqual(weapon,"trigger_hurt_g"))//跳樓 跳海 地圖火 都有可能
			FormatEx(kill_weapon, sizeof(kill_weapon), "%s","killed himself");
		// 修正：原本误用 kill_weapon（此时还是未赋值的脏值）做比较，永远命中不了，
		// 导致被 prop 砸死的特感都被说成「被伺服器處死」。这里改为比较真正的武器名 weapon。
		else if(strncmp(weapon, "prop_physics", 12, false) == 0 || strncmp(weapon, "prop_car_alarm", 14, false) == 0)//玩車殺死自己
			FormatEx(kill_weapon, sizeof(kill_weapon), "%s","killed by toy");
		else if(StrEqual(weapon,"pipe_bomb")||StrEqual(weapon,"prop_fuel_barr"))//自然的爆炸(土製炸彈 砲彈 瓦斯罐)
			FormatEx(kill_weapon, sizeof(kill_weapon), "%s","killed by boom");
		else if(StrEqual(weapon,"world"))//玩家使用指令kill 殺死特感
			return;
		else 
			FormatEx(kill_weapon, sizeof(kill_weapon), "%s","killed by server");	//卡住了 由伺服器自動處死特感
			
		if(GetEntProp(victim, Prop_Send, "m_zombieClass") == ZC_TANK)//Tank suicide
		{
			if(!IsFakeClient(victim))//真人SI player
				PrintAllSubPhrase("Tank is killed by something", kill_weapon);
			else
				PrintAllSubPhrase("Tank is killed by something", kill_weapon);
		}
		else if(GetEntProp(victim, Prop_Send, "m_zombieClass") == ZC_BOOMER)
		{
			CreateTimer(0.1, Timer_BoomerSuicideCheck, GetClientUserId(victim));//boomer suicide check
			
			g_cBoomerDeath[victim].attackerid = 0;
			g_cBoomerDeath[victim].eDeathType = eDeath_Suicide;
		}
		else
		{
			PrintAllSubPhraseWithClient("Player is killed by something", victim, kill_weapon);
		}
		return;
	}
	else if (attacker==0 && victim == 0 && StrEqual(victimname,"Witch"))//Witch自己不知怎的自殺了
	{
		CPrintToChatAll("%t", "l4d_pig_infected4");
	}
	
	if( StrEqual(victimname,"Witch") && PlayerIsTank(attacker) )
	{
		static char Tank_weapon[50];
		if(StrEqual(weapon,"tank_claw"))
			FormatEx(Tank_weapon, sizeof(Tank_weapon), "One-Punch");
		else if(StrEqual(weapon,"tank_rock"))
			FormatEx(Tank_weapon, sizeof(Tank_weapon), "Rock-Stone");
		else if(strncmp(weapon, "prop_physics", 12, false) == 0)
			FormatEx(Tank_weapon, sizeof(Tank_weapon), "Toy");
		else if(strncmp(weapon, "prop_car_alarm", 14, false) == 0)
			FormatEx(Tank_weapon, sizeof(Tank_weapon), "Alarm-Car");
		else
			FormatEx(Tank_weapon, sizeof(Tank_weapon), "unknown weapon");//补上默认值，避免脏值当短语名用
			
		// 【多语言修复】Tank_weapon 是短语名，改由辅助函数逐客户端解析后再拼外层
		PrintAllSubPhrase("Tank Kill Witch", Tank_weapon);
		return;
	}
	
	if ( victim == 0 || !IsClientInGame(victim)) return;
	int victimteam = GetClientTeam(victim);
	int victimzombieclass = GetEntProp(victim, Prop_Send, "m_zombieClass");
		
	if (victimteam == 3)//infected dead
	{	
		if(attacker != 0 && IsClientInGame(attacker))//someone kills infected
		{
			int attackerteam = GetClientTeam(attacker);
			if(attackerteam == 2 && victimzombieclass == ZC_BOOMER)//sur kills Boomer
			{
				g_cBoomerDeath[victim].attackerid = GetClientUserId(attacker);
				g_cBoomerDeath[victim].eDeathType = eDeath_SurvivorKill;
			}
			else if (PlayerIsTank(attacker))//Tank kills infected
			{
				static char Tank_weapon[64];
				//Tank weapon
				if(StrEqual(weapon,"tank_claw"))
					FormatEx(Tank_weapon, sizeof(Tank_weapon), "punches");
				else if(StrEqual(weapon,"tank_rock"))
					FormatEx(Tank_weapon, sizeof(Tank_weapon), "smashes");
				else if(strncmp(weapon, "prop_physics", 12, false) == 0)
					FormatEx(Tank_weapon, sizeof(Tank_weapon), "plays toy to kill");
				else if(strncmp(weapon, "prop_car_alarm", 14, false) == 0)
					FormatEx(Tank_weapon, sizeof(Tank_weapon), "plays alarm car to kill");
				else
					FormatEx(Tank_weapon, sizeof(Tank_weapon), "unknown weapon");//补默认值，避免脏值当短语名用
					
				//Tank kill boomer
				if(victimzombieclass == ZC_BOOMER)
				{
					CreateTimer(0.1, Timer_TankKillBoomerCheck, GetClientUserId(victim));//tank kill Boomer check

					g_cBoomerDeath[victim].attackerid = GetClientUserId(attacker);
					g_cBoomerDeath[victim].eDeathType = eDeath_TankKill;
					g_cBoomerDeath[victim].sWeapon = Tank_weapon;
				}
				else if(victimzombieclass == ZC_HUNTER 
				|| victimzombieclass == ZC_SMOKER 
				|| victimzombieclass == ZC_CHARGER  
				|| victimzombieclass == ZC_SPITTER
				|| victimzombieclass == ZC_JOCKEY ) //Tank kills teammates S.I. (Hunter,Smoker,....)	
				{
					// 【多语言修复】拆成真人/AI 两个 key，参数只剩武器子短语，逐客户端解析
					if(!IsFakeClient(victim))//真人SI player
					{	
						PrintAllSubPhrase("Tank kill teammate", Tank_weapon);
					}
					else
					{
						PrintAllSubPhrase("Tank kill teammate AI", Tank_weapon);
					}
				}
				else if(victimzombieclass == ZC_TANK ) //Tank kills Tank
				{
					if(!IsFakeClient(victim))//真人SI player
					{	
						PrintAllSubPhrase("Tank kill Tank", Tank_weapon);
					}
					else
					{
						PrintAllSubPhrase("Tank kill Tank", Tank_weapon);
					}
				}
			}
		}
	}
}

//Left4Dhooks API Forward-------------------------------

// 【多语言修复】把「子短语」先按每个接收者自己的语言解析，再拼进外层短语。
//
// 原来的写法是 CPrintToChatAll("%t", "Tank is killed by something", kill_weapon)，
// 而 kill_weapon 本身是一个短语名（如 "killed by fire"），靠 phrases 里的
// "#format" "{1:t}" 做嵌套翻译。这条嵌套路径不跟随 SetGlobalTransTarget 的
// 每客户端语言，会回落到服务端语言（通常是 en），于是中文客户端看到
// 「外层中文 + 内层英文」的混排。
//
// 现在 phrases 里外层短语改成 {1:s}，由下面两个辅助函数对每个客户端：
//   1) SetGlobalTransTarget(i)
//   2) FormatEx("%t", 子短语)   → 用该客户端语言解析出已本地化的字符串
//   3) CPrintToChat(i, "%t", 外层短语, 已本地化字符串)
// 必须逐个客户端 VFormat，不能先拼好再广播（否则又会退回单语言）。
void PrintAllSubPhrase(const char[] sOuter, const char[] sSubPhrase)
{
	char sSub[MAX_MESSAGE_LENGTH];
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i)) continue;

		SetGlobalTransTarget(i);
		FormatEx(sSub, sizeof(sSub), "%t", sSubPhrase);
		CPrintToChat(i, "%t", sOuter, sSub);
	}
}

// 同上，但外层短语的第 1 个参数是客户端（{1:N}），第 2 个参数是子短语（{2:s}）。
void PrintAllSubPhraseWithClient(const char[] sOuter, int client, const char[] sSubPhrase)
{
	char sSub[MAX_MESSAGE_LENGTH];
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i)) continue;

		SetGlobalTransTarget(i);
		FormatEx(sSub, sizeof(sSub), "%t", sSubPhrase);
		CPrintToChat(i, "%t", sOuter, client, sSub);
	}
}

public void L4D2_OnStagger_Post(int tank, int source)
{
	if(!PlayerIsTank(tank)) return;
	if(g_fTankStaggerEngineTime[tank] > GetEngineTime()) return;

	g_fTankStaggerEngineTime[tank] = GetEngineTime() + ZC_Stumble_Time;

	if(source > 0 && source <= MaxClients && IsClientInGame(source) && GetClientTeam(source) == TEAM_INFECTED )
	{
		if(GetEntProp(source, Prop_Send, "m_zombieClass") == ZC_BOOMER)
		{
			switch(g_cBoomerDeath[source].eDeathType)
			{
				case eDeath_SurvivorKill:
				{
					int surclient = GetClientOfUserId(g_cBoomerDeath[source].attackerid);
					if(!surclient || !IsClientInGame(surclient)) return;

					if(!IsFakeClient(source))//真人boomer player
						CPrintToChatAll("%t", "l4d_pig_infected5", surclient, source);
					else
						CPrintToChatAll("%t", "l4d_pig_infected6", surclient);
				}
				case eDeath_Suicide:
				{
					if(!IsFakeClient(source))//真人boomer player
					{	
						CPrintToChatAll("%t", "l4d_pig_infected13", source);
					}
					else
					{
						CPrintToChatAll("%t", "l4d_pig_infected14");
					}
				}
				case eDeath_TankKill:
				{
					// 【多语言修复】sWeapon 是武器子短语名，第 1 参为客户端，交给带 client 的辅助函数
					if(!IsFakeClient(source))//真人SI player
					{	
						PrintAllSubPhraseWithClient("l4d_pig_infected7", source, g_cBoomerDeath[source].sWeapon);
					}
					else	
					{
						PrintAllSubPhrase("l4d_pig_infected8", g_cBoomerDeath[source].sWeapon);
					}
				}

			}

			g_cBoomerDeath[source].eDeathType = eDeath_None;
		}
	}
	else if(source > MaxClients && IsValidEntity(source))
	{
		static char classname[64];
		GetEntityClassname(source, classname, sizeof(classname));
		if(strncmp(classname, "prop_door_rotating", false) == 0 
			|| strncmp(classname, "prop_door_rotating_checkpoint", false) == 0 )
		{
			CPrintToChatAll("%t", "l4d_pig_infected1");
		}
	}
}

//Timer & Frame-------------------------------

Action Timer_TankKillBoomerCheck(Handle timer, int client)
{
	client = GetClientOfUserId(client);
	
	if(!client || !IsClientInGame(client)) return Plugin_Continue;
	if(g_cBoomerDeath[client].eDeathType == eDeath_None) return Plugin_Continue;

	if(!IsFakeClient(client))//真人SI player
	{
		PrintAllSubPhraseWithClient("l4d_pig_infected9", client, g_cBoomerDeath[client].sWeapon);
	}
	else
	{
		PrintAllSubPhrase("l4d_pig_infected10", g_cBoomerDeath[client].sWeapon);
	}
	
	return Plugin_Continue;
}


Action Timer_BoomerSuicideCheck(Handle timer, any client)
{	
	client = GetClientOfUserId(client);
	if(!client || !IsClientInGame(client)) return Plugin_Continue;
	if(g_cBoomerDeath[client].eDeathType == eDeath_None) return Plugin_Continue;

	if(!IsFakeClient(client))//真人boomer player
	{	
		CPrintToChatAll("%t", "l4d_pig_infected11", client);
	}
	else
	{
		CPrintToChatAll("%t", "l4d_pig_infected12");
	}
	
	return Plugin_Continue;
}

bool PlayerIsTank(int client)
{
	if(client > 0 && client <= MaxClients && IsClientInGame(client) && IsPlayerAlive(client) && GetClientTeam(client) == TEAM_INFECTED && GetEntProp(client, Prop_Send, "m_zombieClass") == ZC_TANK) 
		return true;

	return false;
}

bool IsWitch(int entity)
{
    if (entity > 0 && IsValidEntity(entity) && IsValidEdict(entity))
    {
        static char strClassName[64];
        GetEdictClassname(entity, strClassName, sizeof(strClassName));
        return strcmp(strClassName, "witch", false) == 0;
    }
    return false;
}