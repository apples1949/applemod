/********************************************************************************************
* Plugin	: L4DVSAutoSpectateOnAFK
* Game		: Left 4 Dead 1/2
* Purpose	: This plugins forces AFK players to spectate, and later it kicks them. Admins 
* 			  are inmune to kick.
*********************************************************************************************/
#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#include <multicolors>
#define PLUGIN_VERSION "2.7-2026/8/20"
#define AUTOSPEC_IDS_MAX 512
#define AFK_BLIP_SOUND "buttons/blip1.wav"


// For cvars
ConVar g_hAfkWarnSpecTime, g_hAfkSpecTime, g_hAfkWarnKickTime, g_hAfkKickTime,
 	g_hAfkCheckInterval, g_hAfkKickEnabled, g_hAfkSaferoomIgnore, 
	g_hImmuneAccess, g_hSayResetTime, g_hSpecAfkMsgEnable, g_hAutoSpecSteamIds;

int afkWarnSpecTime, afkSpecTime, afkWarnKickTime, 
	afkKickTime, afkCheckInterval;
bool afkKickEnabled, bAfkSaferoomIgnore, g_bSayResetTime, g_bSpecAfkMsgEnable;


// work variables
int afkPlayerTimeLeftWarn[MAXPLAYERS + 1];
int afkPlayerTimeLeftAction[MAXPLAYERS + 1];
float afkPlayerLastPos[MAXPLAYERS + 1][3];
float afkPlayerLastEyes[MAXPLAYERS + 1][3];
bool g_bLeftSafeRoom;
bool L4D2Version;
char g_sAccesslvl[AdminFlags_TOTAL];
char g_sAutoSpecSteamIds[AUTOSPEC_IDS_MAX];
int g_iPlayerSpawn, g_iRoundStart;
Handle PlayerLeftStartTimer, afkCheckThreadTimer;

public Plugin myinfo = 
{
	name = "[L4D1/2] VS Auto-spectate on AFK",
	author = "djromero (SkyDavid, David Romero) & Harry",
	description = "Auto-spectate for AFK players on VS mode",
	version = PLUGIN_VERSION,
	url = "https://steamcommunity.com/profiles/76561198026784913/"
}

bool g_bLate;
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) 
{
	// Checks to see if the game is a L4D game. If it is, check if its the sequel. L4DVersion is L4D if false, L4D2 if true.
	EngineVersion test = GetEngineVersion();
	if( test == Engine_Left4Dead)
		L4D2Version = false;
	else if (test == Engine_Left4Dead2 )
		L4D2Version = true;
	else
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 1 & 2.");
		return APLRes_SilentFailure;
	}

	g_bLate = late;
	return APLRes_Success;
}

public void OnPluginStart()
{
	LoadTranslations("L4DVSAutoSpectateOnAFK.phrases");
	// We register the spectate command
	//RegConsoleCmd("spectate", cmd_spectate);
	RegConsoleCmd("say", Command_Say);
	RegConsoleCmd("say_team", Command_Say);
	
	
	// Changed teams
	HookEvent("player_team", afkChangedTeam);
	
	// Player actions
	HookEvent("entity_shoved", afkPlayerAction);
	HookEvent("player_shoved", afkPlayerAction);
	HookEvent("player_shoot", afkPlayerAction);
	HookEvent("player_jump", afkPlayerAction);
	HookEvent("player_hurt", afkPlayerAction);
	HookEvent("player_hurt_concise", afkPlayerAction);
	HookEntityOutput("func_button_timed", "OnPressed", OnButtonPress);
	
	// For roundstart and roundend..
	HookEvent("round_start", 			Event_RoundStart, 	EventHookMode_PostNoCopy);
	HookEvent("round_end", 				Event_RoundEnd,		EventHookMode_PostNoCopy);
	HookEvent("finale_win", 			Event_RoundEnd,		EventHookMode_PostNoCopy);
	HookEvent("mission_lost", 			Event_RoundEnd,		EventHookMode_PostNoCopy);
	HookEvent("map_transition", 		Event_RoundEnd,		EventHookMode_PostNoCopy);
	HookEvent("player_spawn",			Event_PlayerSpawn,	EventHookMode_PostNoCopy);

	g_hAfkWarnSpecTime 		= CreateConVar("l4d_specafk_warnspectime", 			"10", "游戏中检测到闲置后多少秒出现警告提示", FCVAR_NOTIFY, true, 0.0);
	g_hAfkSpecTime 			= CreateConVar("l4d_specafk_spectime", 				"15", "警告后多少秒强制旁观", FCVAR_NOTIFY, true, 0.0);
	g_hAfkWarnKickTime	 	= CreateConVar("l4d_specafk_warnkicktime", 			"0", "旁观检测到闲置后多少秒出现警告提示", FCVAR_NOTIFY, true, 0.0);
	g_hAfkKickTime 			= CreateConVar("l4d_specafk_kicktime", 				"30", "旁观警告后多少秒踢出", FCVAR_NOTIFY, true, 0.0);
	g_hAfkCheckInterval 	= CreateConVar("l4d_specafk_checkinteral", 			"1", "检测/警告的时间间隔", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hAfkKickEnabled 		= CreateConVar("l4d_specafk_kickenabled", 			"1", "设为1时，当队伍有空位时，旁观状态下的AFK玩家将被踢出", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hAfkSaferoomIgnore 	= CreateConVar("l4d_specafk_saferoom_ignore", 		"0", "设为1时，无论幸存者是否离开安全屋，AFK玩家都会被强制旁观（不影响旁观踢出判定）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hImmuneAccess 		= CreateConVar("l4d_specafk_immune_access_flag", 	"z", "拥有这些权限标志的玩家在旁观时不会被踢出（留空 = 所有人，-1 = 无人）", FCVAR_NOTIFY);
	g_hSayResetTime 		= CreateConVar("l4d_specafk_say_reset", 			"1", "设为1时，玩家在聊天框发言将重置计时", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hSpecAfkMsgEnable 	= CreateConVar("l4d_specafk_join_hint_msg", 		"0", "设为1时，向AFK旁观者显示\"你正在旁观，加入任何队伍开始游戏\"的提示", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hAutoSpecSteamIds 	= CreateConVar("l4d_specafk_autospec_steamids", 	"76561198760610101", "符合条件的 SteamID64 玩家将自动被移动到旁观，且不会被本插件踢出（多个用逗号分隔）", FCVAR_NOTIFY);
	CreateConVar("l4d_specafk_version", PLUGIN_VERSION, "L4D VS 自动AFK旁观插件的版本", FCVAR_DONTRECORD|FCVAR_NOTIFY);
	

	ReadCvars();
	g_hAfkWarnSpecTime.AddChangeHook(ConVarChanged);
	g_hAfkSpecTime.AddChangeHook(ConVarChanged);
	g_hAfkWarnKickTime.AddChangeHook(ConVarChanged);
	g_hAfkKickTime.AddChangeHook(ConVarChanged);
	g_hAfkCheckInterval.AddChangeHook(ConVarChanged);
	g_hAfkKickEnabled.AddChangeHook(ConVarChanged);
	g_hAfkSaferoomIgnore.AddChangeHook(ConVarChanged);
	g_hImmuneAccess.AddChangeHook(ConVarChanged);
	g_hSayResetTime.AddChangeHook(ConVarChanged);
	g_hSpecAfkMsgEnable.AddChangeHook(ConVarChanged);
	g_hAutoSpecSteamIds.AddChangeHook(ConVarChanged);

	if(g_bLate)
	{
		CreateTimer(3.0, tmrStart, _, TIMER_FLAG_NO_MAPCHANGE);
	}
}

public void OnPluginEnd()
{
	ResetPlugin();
	ResetTimer();
}

public void OnMapStart()
{
	// 缓存倒计时提示音，避免地图运行时才加载
	PrecacheSound(AFK_BLIP_SOUND, true);
}

void ReadCvars()
{
	// first we read all the variables ...
	afkWarnSpecTime = g_hAfkWarnSpecTime.IntValue;
	afkSpecTime = g_hAfkSpecTime.IntValue;
	afkWarnKickTime = g_hAfkWarnKickTime.IntValue;
	afkKickTime = g_hAfkKickTime.IntValue;
	afkCheckInterval = g_hAfkCheckInterval.IntValue;
	afkKickEnabled = g_hAfkKickEnabled.BoolValue;
	bAfkSaferoomIgnore = g_hAfkSaferoomIgnore.BoolValue;

	g_hImmuneAccess.GetString(g_sAccesslvl,sizeof(g_sAccesslvl));

	g_bSayResetTime = g_hSayResetTime.BoolValue;
	g_bSpecAfkMsgEnable = g_hSpecAfkMsgEnable.BoolValue;

	g_hAutoSpecSteamIds.GetString(g_sAutoSpecSteamIds, sizeof(g_sAutoSpecSteamIds));
}

void ConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	ReadCvars();
}

public void OnMapEnd()
{
	ResetPlugin();
	ResetTimer();
}

public void OnClientPutInServer(int client)
{
	if(IsFakeClient(client)) return;

	afkPlayerTimeLeftWarn[client] = afkWarnKickTime;
	afkPlayerTimeLeftAction[client] = afkKickTime;

	// 符合自动旁观 cvar 的玩家加入时自动移动到旁观
	if (IsAutoSpecPlayer(client))
		CreateTimer(1.0, tmrForceAutoSpec, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

bool HasAccess(int client, char[] sAcclvl)
{
	// no permissions set
	if (strlen(sAcclvl) == 0)
		return true;

	else if (StrEqual(sAcclvl, "-1"))
		return false;

	// check permissions
	int flag = GetUserFlagBits(client);
	if ( flag & ReadFlagString(sAcclvl) || flag & ADMFLAG_ROOT )
	{
		return true;
	}

	return false;
}

bool IsAutoSpecPlayer(int client)
{
	if (strlen(g_sAutoSpecSteamIds) == 0)
		return false;

	char sSteamId[32];
	if (!GetClientAuthId(client, AuthId_SteamID64, sSteamId, sizeof(sSteamId)))
		return false;

	char sIds[AUTOSPEC_IDS_MAX];
	strcopy(sIds, sizeof(sIds), g_sAutoSpecSteamIds);

	char sParts[16][32];
	int iCount = ExplodeString(sIds, ",", sParts, sizeof(sParts), sizeof(sParts[]));
	for (int i = 0; i < iCount; i++)
	{
		TrimString(sParts[i]);
		if (StrEqual(sParts[i], sSteamId, false))
			return true;
	}

	return false;
}

void ForceAutoSpec(int client)
{
	if (client <= 0 || client > MaxClients) return;
	if (!IsClientInGame(client) || IsFakeClient(client)) return;
	if (GetClientTeam(client) == 1) return;

	if (IsAutoSpecPlayer(client))
		ChangeClientTeam(client, 1);
}

Action tmrForceAutoSpec(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client)
		ForceAutoSpec(client);

	return Plugin_Continue;
}

bool IsImmuneName(int client)
{
	char sName[MAX_NAME_LENGTH];
	GetClientName(client, sName, sizeof(sName));

	// 硬编码：名称为"暖服机器人"的玩家不警告不踢出（同64id免疫由 l4d_specafk_autospec_steamids 提供）
	return StrEqual(sName, "暖服机器人", false);
}

bool TeamsHaveOpenSlots()
{
	// 生还者队伍有空位：存在 AI 机器人（玩家加入可顶替）
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && IsFakeClient(i) && GetClientTeam(i) == 2)
			return true;
	}

	// 感染者队伍有空位：可加入的插槽未满
	ConVar hMaxInfected = FindConVar("z_max_player_zombies");
	if (hMaxInfected != null)
	{
		int iInfectedCount = 0;
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsClientInGame(i) && GetClientTeam(i) == 3)
				iInfectedCount++;
		}
		if (iInfectedCount < hMaxInfected.IntValue)
			return true;
	}

	return false;
}

bool IsPlayerConnecting()
{
	// 是否存在正在连接中（已连接但尚未进入游戏，如仍在加载地图）的真人玩家
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i) && !IsFakeClient(i) && !IsClientInGame(i))
			return true;
	}

	return false;
}

Action Command_Say(int client, int args)
{
	if(!g_bSayResetTime) return Plugin_Continue;

	if(client && IsClientInGame(client) && !IsFakeClient(client))
		afkResetTimers(client);

	return Plugin_Continue;
}

void Event_RoundStart (Event event, const char[] name, bool dontBroadcast)
{
	g_bLeftSafeRoom = false;
	if( g_iPlayerSpawn == 1 && g_iRoundStart == 0 )
		CreateTimer(3.0, tmrStart, _, TIMER_FLAG_NO_MAPCHANGE);
	g_iRoundStart = 1;
}

void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client)
		ForceAutoSpec(client);

	if( g_iPlayerSpawn == 0 && g_iRoundStart == 1 )
		CreateTimer(3.0, tmrStart, _, TIMER_FLAG_NO_MAPCHANGE);
	g_iPlayerSpawn = 1;
}

Action tmrStart(Handle timer)
{
	ResetPlugin();

	for (int client=1;client<=MaxClients;client++)
	{
		if(IsClientInGame(client) && !IsFakeClient(client))
		{
	// If client is not on spec team
			if (GetClientTeam(client)!=1)
			{
				afkPlayerTimeLeftWarn[client] = afkWarnSpecTime;
				afkPlayerTimeLeftAction[client] = afkSpecTime;
			}
			else // if player is on spectators
			{
				afkPlayerTimeLeftWarn[client] = afkWarnKickTime;
				afkPlayerTimeLeftAction[client] = afkKickTime;
			}
			
			GetClientAbsOrigin(client, afkPlayerLastPos[client]);
			GetClientEyeAngles(client, afkPlayerLastEyes[client]);

			// 符合自动旁观 cvar 的玩家（含 late load 时已在游戏中的）强制回到旁观
			ForceAutoSpec(client);
		}
		else
		{
			afkPlayerTimeLeftWarn[client] = afkWarnSpecTime;
			afkPlayerTimeLeftAction[client] = afkSpecTime;
		}
	}

	delete PlayerLeftStartTimer;
	PlayerLeftStartTimer = CreateTimer(1.0, PlayerLeftStart, _, TIMER_REPEAT);

	delete afkCheckThreadTimer;
	afkCheckThreadTimer = CreateTimer(float(afkCheckInterval), afkCheckThread, _, TIMER_REPEAT);

	return Plugin_Continue;
}


void Event_RoundEnd (Event event, const char[] name, bool dontBroadcast)
{
	ResetPlugin();
	ResetTimer();
}

void afkPlayerAction (Event event, const char[] name, bool dontBroadcast)
{
	int client;
	
	// gets the property name
	if (strcmp(name, "entity_shoved", false)==0)
		client = GetClientOfUserId(event.GetInt("attacker"));
	else if (strcmp(name, "player_shoved", false)==0)
		client = GetClientOfUserId(event.GetInt("attacker"));
	else if (strcmp(name, "player_hurt", false)==0)
		client = GetClientOfUserId(event.GetInt("attacker"));
	else if (strcmp(name, "player_hurt_concise", false)==0)
		client = GetClientOfUserId(event.GetInt("attacker"));
	else 
		client = GetClientOfUserId(event.GetInt("userid"));
	
	// resets his timers
	if (client > 0 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client))
		afkResetTimers(client);
}

void OnButtonPress(const char[] name, int caller, int activator, float delay)
{
	if (activator < 1 || activator > MaxClients || !IsClientInGame(activator))
		return;
	
	afkResetTimers(activator);
}

void afkChangedTeam (Event event, const char[] name, bool dontBroadcast)
{
	// we get the victim
	CreateTimer(0.5, ClientReallyChangeTeam, event.GetInt("userid"), TIMER_FLAG_NO_MAPCHANGE); // check delay
}

Action ClientReallyChangeTeam(Handle timer, int victim)
{
	victim = GetClientOfUserId(victim);

	if( victim <= 0 || victim > MaxClients || !IsClientInGame(victim) || IsFakeClient(victim)) return Plugin_Continue;
	
	// Reset his afk status
	afkResetTimers(victim);

	// 符合自动旁观 cvar 的玩家换队后强制回到旁观
	ForceAutoSpec(victim);

	return Plugin_Continue;
}

Action afkJoinHint (Handle Timer, int client)
{
	if(!g_bSpecAfkMsgEnable) return Plugin_Stop;

	client = GetClientOfUserId(client);
	// If player is valid
	if (client && IsClientInGame(client) && afkPlayerTimeLeftWarn[client] > 0)
	{
		// If player is still on spectators ...
		if (GetClientTeam(client) == 1)
		{
			// We send him a hint text ...
			PrintHintText(client, "%T", "You're spectating. Join any team to play.", client);
			
			return Plugin_Continue;
		}
	}
	
	return Plugin_Stop;
}

void afkResetTimers (int client)
{
	// If client is not on spec team
	if (GetClientTeam(client)!=1)
	{
		afkPlayerTimeLeftWarn[client] = afkWarnSpecTime;
		afkPlayerTimeLeftAction[client] = afkSpecTime;
	}
	else // if player is on spectators
	{
		afkPlayerTimeLeftWarn[client] = afkWarnKickTime;
		afkPlayerTimeLeftAction[client] = afkKickTime;
	}
	
	GetClientAbsOrigin(client, afkPlayerLastPos[client]);
	GetClientEyeAngles(client, afkPlayerLastEyes[client]);
}

void AFKPlayBlipSound(int client)
{
	if (client > 0 && client <= MaxClients && IsClientInGame(client))
		EmitSoundToClient(client, AFK_BLIP_SOUND);
}

void AFKCountdownWarn(int client, const char[] phrase, int seconds)
{
	// 倒计时提示：Hint 文本 + 提示音
	PrintHintText(client, "%T", phrase, client, seconds);
	AFKPlayBlipSound(client);
}

int g_iLastTick;
Action afkCheckThread(Handle timer)
{
	//時間被暫停
	if(g_iLastTick == GetGameTickCount()) return Plugin_Continue;
	g_iLastTick = GetGameTickCount();

	bool bTeamsOpen = TeamsHaveOpenSlots(); // 本次检测时对抗双方队伍是否有空位（仅当有空位时才检测旁观闲置）
	// 补位检测跳过：幸存者未离开安全区域且有玩家正在连接中时，不检测/踢出旁观AFK（连接中的玩家即将补位）
	bool bSkipFillDetection = !g_bLeftSafeRoom && IsPlayerConnecting();

	float pos[3];
	float eyes[3];
	bool isAFK;
	// we check all connected (and alive) clients ...
	for (int i=1;i<=MaxClients;i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
		{
			// If player is not on spectators team ...
			if (GetClientTeam(i) > 1)
			{
				// If client is alive 
				if (IsPlayerAlive(i))
				{
					// we get his current coordinates and eyes
					GetClientAbsOrigin(i, pos);
					GetClientEyeAngles(i, eyes);
					
					isAFK = true;
					
					if(GetVectorDistance(pos, afkPlayerLastPos[i]) > 80.0)
					{
						isAFK = false;
					}
					
					if(isAFK)
					{
						if(eyes[0] != afkPlayerLastEyes[i][0] && 
							eyes[1] != afkPlayerLastEyes[i][1]) 
						{
							isAFK = false;
						}
					}

					// if he hasn't moved ..
					if (isAFK)
					{
						// if the player is not trapped (incapacitated, pounced, etc)
						if (GetInfectedAttacker(i) == -1)
						{
							// If player has not been warned ...
							if (afkPlayerTimeLeftWarn[i] > 0) // warn time ...
							{
								// we reduce his warn time ...
								afkPlayerTimeLeftWarn[i] = afkPlayerTimeLeftWarn[i] - afkCheckInterval;
								
								// if his warn time reached 0 ....
								if (afkPlayerTimeLeftWarn[i] <= 0)
								{
									// we set his time left to spectate
									afkPlayerTimeLeftAction[i] = afkSpecTime;
									
									// We warn the player ....
									AFKCountdownWarn(i, "[AFK] Inactivity detected! 1", afkPlayerTimeLeftAction[i]);
								}
							}
							else // player warn timeout reached ...
							{
								// we reduce his action time
								afkPlayerTimeLeftAction[i] = afkPlayerTimeLeftAction[i] - afkCheckInterval;
								
								// if his action time reached 0 ...
								if (afkPlayerTimeLeftAction[i] <= 0)
								{
									// If players leaved safe room we force him to spectate
									if (g_bLeftSafeRoom || bAfkSaferoomIgnore)
									{
										afkForceSpectate(i, true);
									}
									else // if players haven't leaved safe room ... we warn this player that he will be forced to spectate as soon as a player leaves
									{
										PrintHintText(i, "%T", "[AFK] Inactivity detected! 2", i);
									}
								}
								else // we just warn him ...
									AFKCountdownWarn(i, "[AFK] Inactivity detected! 1", afkPlayerTimeLeftAction[i]);
								
							}
						} // player is not trapped
						else // player is trapped
						{
							afkResetTimers(i);
						}
					} // player hasn't moved ...
					else // player moved ...
					{
						afkResetTimers(i);
					}
				} // player is alive or is infected
			} // player is not on spectators ...
			else if (afkKickEnabled && bTeamsOpen && !bSkipFillDetection) // 旁观检测：仅当对抗双方队伍有空位且不处于"未离开安全区域+有人连接中"时才触发（生还者有AI机器人 / 感染者有空位）
			{
				// If the player is not registered ...
				if (HasAccess(i, g_sAccesslvl) == false && !IsAutoSpecPlayer(i) && !IsImmuneName(i)) // 有权限、符合自动旁观 cvar 或名称匹配免疫列表的玩家不警告不踢出
				{
					// If player has not been warned ...
					if (afkPlayerTimeLeftWarn[i] > 0) // warn time ...
					{
						// we reduce his warn time ...
						afkPlayerTimeLeftWarn[i] = afkPlayerTimeLeftWarn[i] - afkCheckInterval;
						
						// if his warn time reached 0 ....
						if (afkPlayerTimeLeftWarn[i] <= 0)
						{
							// We warn the player ....
							AFKCountdownWarn(i, "[AFK] Inactivity detected! 3", afkPlayerTimeLeftAction[i]);
						}
					}
					else // player warn timeout reached ...
					{
						// we reduce his action time
						afkPlayerTimeLeftAction[i] = afkPlayerTimeLeftAction[i] - afkCheckInterval;
						
						// if his action time reached 0 ...
						if (afkPlayerTimeLeftAction[i] <=  0)
						{
							// we kick the player
							afkKickClient(i);
						}
						else // we just warn him ...
							AFKCountdownWarn(i, "[AFK] Inactivity detected! 3", afkPlayerTimeLeftAction[i]);
					}			
				} // player is not admin
			} // player is on spectators
		} // player is connected and in-game
	}
	
	// We continue with the timer
	return Plugin_Continue;
}


void AFKPrintHint(int client, const char[] phrase)
{
	char sBuffer[256];
	SetGlobalTransTarget(client);
	Format(sBuffer, sizeof(sBuffer), "%T", phrase, client);
	CRemoveTags(sBuffer, sizeof(sBuffer));
	PrintHintText(client, "%s", sBuffer);
}

void AFKPrintHintToAll(const char[] phrase, const char[] name)
{
	char sBuffer[256];
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
		{
			SetGlobalTransTarget(i);
			Format(sBuffer, sizeof(sBuffer), "%T", phrase, i, name);
			CRemoveTags(sBuffer, sizeof(sBuffer));
			PrintHintText(i, "%s", sBuffer);
		}
	}
}

void afkForceSpectate (int client, bool advertise)
{
	// We force him to spectate
	ChangeClientTeam(client, 1);
	
	// We send him a hint message 5 seconds later, in case he hasn't joined any team
	CreateTimer(5.0, afkJoinHint, GetClientUserId(client), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	
	// Print forced info
	if (advertise)
	{
		char sName[MAX_NAME_LENGTH];
		GetClientName(client, sName, sizeof(sName));

		// 被强制旁观者：聊天框 + 中央 Hint
		CPrintToChat(client, "%T", "afkForceSpectate", client);
		AFKPrintHint(client, "afkForceSpectate");

		// 所有人：聊天框 + 中央 Hint
		CPrintToChatAll("%t", "[AFK] Inactivity detected! 5", sName);
		AFKPrintHintToAll("[AFK] Inactivity detected! 5", sName);
	}
}

void afkKickClient (int client)
{
	if (IsFakeClient(client))
		return;
	
	// 踢出原因按被踢玩家的语言显示（KickClient 会以该玩家为翻译目标格式化）
	KickClient(client, "%T", "kickplayer", client, afkKickTime);
	
	// Print forced info
	char sName[MAX_NAME_LENGTH];
	GetClientName(client, sName, sizeof(sName));
	CPrintToChatAll("%t", "have been kicked from server due to inactivity", sName, afkKickTime);
}

Action PlayerLeftStart(Handle Timer)
{
	if (L4D_HasAnySurvivorLeftSafeArea())
	{
		g_bLeftSafeRoom = true;
		PlayerLeftStartTimer = null;
		return Plugin_Stop;
	}

	return Plugin_Continue;
}

int GetInfectedAttacker(int client)
{
	int attacker;

	if(L4D2Version)
	{
		/* Charger */
		attacker = GetEntPropEnt(client, Prop_Send, "m_pummelAttacker");
		if (attacker > 0)
		{
			return attacker;
		}

		attacker = GetEntPropEnt(client, Prop_Send, "m_carryAttacker");
		if (attacker > 0)
		{
			return attacker;
		}
		/* Jockey */
		attacker = GetEntPropEnt(client, Prop_Send, "m_jockeyAttacker");
		if (attacker > 0)
		{
			return attacker;
		}
	}

	/* Hunter */
	attacker = GetEntPropEnt(client, Prop_Send, "m_pounceAttacker");
	if (attacker > 0)
	{
		return attacker;
	}

	/* Smoker */
	attacker = GetEntPropEnt(client, Prop_Send, "m_tongueOwner");
	if (attacker > 0)
	{
		return attacker;
	}

	return -1;
}

void ResetPlugin()
{
	g_iRoundStart = 0;
	g_iPlayerSpawn = 0;
}

void ResetTimer()
{
	delete PlayerLeftStartTimer;
	delete afkCheckThreadTimer;
}
