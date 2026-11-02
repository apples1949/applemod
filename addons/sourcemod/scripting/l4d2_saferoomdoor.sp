#pragma semicolon 1
//強制1.7以後的新語法
#pragma newdecls required
#include <sourcemod>
#include <sdktools>

//==================== 安全门卡住检测(终点安全门) ====================
// 关卡切换门(终点安全门)的实体类名, 见 datamap: CPropDoorRotatingCheckpoint
#define CHECKPOINT_DOOR_CLASS		"prop_door_rotating_checkpoint"
#define MAX_CHECKPOINT_DOORS		8		// 一张图里同时监视的安全门上限
#define STUCK_DOOR_USE_RANGE		110.0	// 玩家按 USE 时与门的最大交互距离(HU)
#define STUCK_DOOR_REACT_DELAY		0.8		// 按下 USE 后等这么久再检查门有没有反应
#define STUCK_DOOR_ATTEMPT_INTERVAL	0.3		// 两次有效交互的最小间隔, 防止一次按键重复计数
#define STUCK_DOOR_RETRY_MAX		3		// 强制开启最多连续重试次数
#define STUCK_DOOR_RETRY_DELAY		1.0		// 强制开启重试间隔
#define STUCK_DOOR_SCAN_INTERVAL	5.0		// 重扫安全门实体的最短间隔

// CBasePropDoor 的 m_eDoorState (datamap) 取值
enum
{
	DoorState_Closed = 0,		// 完全关闭
	DoorState_Opening,			// 正在打开
	DoorState_Opened,			// 已经打开
	DoorState_Closing			// 正在关闭
};

char clientName[32];

int l4d2_dooropen_kick[MAXPLAYERS+1];

ConVar EnableHandle_a, EnableHandle_b, EnableHandle_c, EnableHandle_d, EnableHandle_e, EnableHandle_f;

int g_EnableHandle_a, g_EnableHandle_b, g_EnableHandle_c, g_EnableHandle_e;

float g_EnableHandle_d, g_EnableHandle_f;

float g_fDoorDelayTimes[MAXPLAYERS + 1];

//==================== 安全门卡住检测状态 ====================
ConVar EnableHandle_g, EnableHandle_h, EnableHandle_i;

int g_EnableHandle_g, g_EnableHandle_h;

float g_EnableHandle_i;

int g_iCheckpointDoors[MAX_CHECKPOINT_DOORS];		// 本图所有终点安全门, 存的是实体引用(entref)不是索引
int g_iCheckpointDoorCount;

int g_iStuckDoorFails[MAX_CHECKPOINT_DOORS];		// 连续无效交互次数
float g_fStuckDoorLastAttempt[MAX_CHECKPOINT_DOORS];	// 上次计入的交互时间
float g_fStuckDoorLockSince[MAX_CHECKPOINT_DOORS];	// 引擎以"等玩家加载"为由锁门的起始时间, 0=没锁过
bool g_bStuckDoorForced[MAX_CHECKPOINT_DOORS];		// 本回合是否已强制开启过
bool g_bStuckDoorAnnounced[MAX_CHECKPOINT_DOORS];	// 是否已经提示过玩家
int g_iStuckDoorRetry[MAX_CHECKPOINT_DOORS];		// 强制开启重试次数

bool g_bClientUsing[MAXPLAYERS + 1];				// 上一帧是否按着 USE, 用于取按下沿
bool g_bSafeDoorRoundEnded;							// 本回合是否已经 round_end
float g_fSafeDoorNextScan;

public void OnPluginStart()
{
	EnableHandle_a	= CreateConVar("l4d2_enabled_safeRoomDoor_a", "2", "启用幸存者开关安全门提示+开关安全门次数限制? 0=禁用, 1=启用, 2=禁用限制,只显示幸存者开关安全门.", FCVAR_NOTIFY);
	EnableHandle_b	= CreateConVar("l4d2_enabled_safeRoomDoor_b", "1", "设置玩门超过次数后的处理方式. 1=处死, 2=踢出, 3=封禁(由于盗版没有唯一的64位ID所以使用永久封禁是无效的).", FCVAR_NOTIFY);
	EnableHandle_c	= CreateConVar("l4d2_enabled_safeRoomDoor_c", "5", "设置玩门达到次数的封禁时间/分钟. 0=永久封禁(删除文件  banned_user.cfg  里的对应玩家ID然后重启服务器即可解封).", FCVAR_NOTIFY);
	EnableHandle_d	= CreateConVar("l4d2_enabled_safeRoomDoor_d", "1", "设置开局时延迟多久提示玩门的后果(秒).(必须大于1)", FCVAR_NOTIFY);
	EnableHandle_e	= CreateConVar("l4d2_enabled_safeRoomDoor_e", "5", "设置每个章节幸存者开关安全门的次数.", FCVAR_NOTIFY);
	EnableHandle_f	= CreateConVar("l4d2_enabled_safeRoomDoor_f", "2.0", "设置每次开关安全门后的冷却时间(秒).", FCVAR_NOTIFY);
	EnableHandle_g	= CreateConVar("l4d2_enabled_safeRoomDoor_g", "1", "检测终点安全门是否卡住(玩家反复按USE却没有任何反应时强制开启安全门). 0=禁用, 1=启用.", FCVAR_NOTIFY);
	EnableHandle_h	= CreateConVar("l4d2_enabled_safeRoomDoor_h", "3", "连续多少次USE交互都没有任何反应判定为安全门卡住.", FCVAR_NOTIFY);
	EnableHandle_i	= CreateConVar("l4d2_enabled_safeRoomDoor_i", "20.0", "安全门被引擎以(等待玩家加载完成)为由锁住时, 这段时间(秒)内不判定为卡住.", FCVAR_NOTIFY);
	
	EnableHandle_a.AddChangeHook(CVARDoorChanged);
	EnableHandle_b.AddChangeHook(CVARDoorChanged);
	EnableHandle_c.AddChangeHook(CVARDoorChanged);
	EnableHandle_d.AddChangeHook(CVARDoorChanged);
	EnableHandle_e.AddChangeHook(CVARDoorChanged);
	EnableHandle_f.AddChangeHook(CVARDoorChanged);
	EnableHandle_g.AddChangeHook(CVARDoorChanged);
	EnableHandle_h.AddChangeHook(CVARDoorChanged);
	EnableHandle_i.AddChangeHook(CVARDoorChanged);
	
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);//回合开始.
	HookEvent("round_end", Event_RoundEnd);//回合结束.
	HookEvent("door_open", Event_DoorOpen);//打开安全门.
	HookEvent("door_close", Event_DoorClose);//关上安全门.
	HookEvent("waiting_checkpoint_door_used", Event_WaitingDoorUsed);//安全门锁定中(等待玩家加载完成).
	HookEvent("waiting_door_used_versus", Event_WaitingDoorUsed);//同上, 对抗模式用的是这个事件.
	
	HookEvent("door_open", Event_DoorAction, EventHookMode_Pre);
	HookEvent("door_close", Event_DoorAction, EventHookMode_Pre);
	
	AddCommandListener(DoorIntercept, "choose_opendoor");
	AddCommandListener(DoorIntercept, "choose_closedoor");
	
	//AutoExecConfig(true, "l4d2_saferoomdoor");//生成指定文件名的CFG.
}

public void OnMapStart()
{
	l4d2_DoorGetCvars();
}

public void CVARDoorChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	l4d2_DoorGetCvars();
}

void l4d2_DoorGetCvars()
{
	g_EnableHandle_a = EnableHandle_a.IntValue;
	g_EnableHandle_b = EnableHandle_b.IntValue;
	g_EnableHandle_c = EnableHandle_c.IntValue;
	g_EnableHandle_d = EnableHandle_d.FloatValue;
	g_EnableHandle_e = EnableHandle_e.IntValue;
	g_EnableHandle_f = EnableHandle_f.FloatValue;
	g_EnableHandle_g = EnableHandle_g.IntValue;
	g_EnableHandle_h = EnableHandle_h.IntValue;
	g_EnableHandle_i = EnableHandle_i.FloatValue;

	//兜底: 判定次数 / 宽限期给个下限, 免得填 0 之后对着关门按一次 USE 就强制开门.
	if (g_EnableHandle_h < 1)
		g_EnableHandle_h = 1;

	if (g_EnableHandle_i < 0.0)
		g_EnableHandle_i = 0.0;
}

public Action DoorIntercept(int client, const char[] command, int args)
{
	if(client == 0 || !IsClientInGame(client) || IsFakeClient(client) || GetClientTeam(client) != 2 || !IsPlayerAlive(client))
		return Plugin_Continue;
	
	if(GetEngineTime() - g_fDoorDelayTimes[client] < g_EnableHandle_f)
	{
		return Plugin_Handled;
	}
	return Plugin_Continue;	
}

public void Event_DoorAction(Event event, const char[] name, bool dontBroadcast)
{
	if(!event.GetBool("checkpoint"))
		return;

	int client = GetClientOfUserId(event.GetInt("userid"));
	if(client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client) || GetClientTeam(client) != 2 || !IsPlayerAlive(client))
		return;

	if(GetEngineTime() - g_fDoorDelayTimes[client] >= g_EnableHandle_f)
		g_fDoorDelayTimes[client] = GetEngineTime();
}

//玩家连接成功.
public void OnClientPostAdminCheck(int client)
{
	g_bClientUsing[client] = false;//重置按下沿记录.

	if(IsFakeClient(client))
		return;
		
	if(g_EnableHandle_a == 0)
		return;
		
	if(g_EnableHandle_a == 1)
	{
		l4d2_dooropen_kick[client] = 0;//开局时重置幸存者开关安全门次数.
		CreateTimer(g_EnableHandle_d, l4d2_EnableHandle, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);//显示玩门的处罚方式.
	}
}

//回合开始.
public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	g_bSafeDoorRoundEnded = false;

	//重置卡住检测状态并重新抓取本图的安全门实体.
	//不管功能当前是否启用都重置一遍, 免得中途把 _g 从 0 改回 1 时沿用上一回合的旧计数.
	l4d2_SafeDoorReset();
	l4d2_SafeDoorScan();
}

//回合结束.
public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	g_bSafeDoorRoundEnded = true;//回合已经结束, 不再做安全门卡住判定.

	if(g_EnableHandle_a == 0)
		return;
	
	if(g_EnableHandle_a == 1)
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			if(IsClientInGame(i) && !IsFakeClient(i))
			{
				l4d2_dooropen_kick[i] = 0;
			}
		}
	}
}

public Action l4d2_EnableHandle(Handle timer, any client) 
{
	if ((client = GetClientOfUserId(client)) && IsClientInGame(client) && !IsFakeClient(client))
	{
		if (GetClientTeam(client) == 3)
			return Plugin_Continue;
		
		switch(g_EnableHandle_b)
		{
			case 1:
			{
				PrintToChat(client, "\x04[提示]\x05玩门达到\x03%d\x05次将被处死.", g_EnableHandle_e);//聊天窗提示.
			}
			case 2:
			{
				PrintToChat(client, "\x04[提示]\x05玩门达到\x03%d\x05次将被踢出.", g_EnableHandle_e);//聊天窗提示.
			}
			case 3:
			{
				if (g_EnableHandle_c <= 0)
					PrintToChat(client, "\x04[提示]\x05玩门达到\x03%d\x05次将被永久封禁.", g_EnableHandle_e);//聊天窗提示.
				else
					PrintToChat(client, "\x04[提示]\x05玩门达到\x03%d\x05次将被封禁\x03%d\x05分钟.", g_EnableHandle_e, g_EnableHandle_c);//聊天窗提示.
			}
		}
	}
	return Plugin_Continue;
}

//打开安全门.
public void Event_DoorOpen(Event event, const char[] name, bool dontBroadcast)
{
	//安全门正常打开了: 清掉卡住检测的计数, 说明本图的安全门是好的.
	if(GetEventBool(event, "checkpoint"))
		l4d2_SafeDoorResetCounters();

	if(g_EnableHandle_a == 0)
		return;
	
	int client = GetClientOfUserId(event.GetInt("userid"));
	
	if(IsValidClient(client))
	{
		GetTrueName(client, clientName);
		if (GetEventBool(event, "checkpoint"))
		{
			if(IsFakeClient(client))
			{
				PrintToChatAll("\x04[提示]\x03%s\x05打开了安全门.", clientName);//聊天窗提示.
			}
			else
			{
				switch(g_EnableHandle_a)
				{
					case 1:
					{
						l4d2_dooropen_kick[client]++;
						if (l4d2_dooropen_kick[client] > g_EnableHandle_e)
						{
							switch(g_EnableHandle_b)
							{
								case 1:
								{
									ForcePlayerSuicide(client);
									PrintToChatAll("\x04[提示]\x03%s\x05玩门达到限制\x03%d\x05次而被处死.", clientName, g_EnableHandle_e);//聊天窗提示.
								}
								case 2:
								{
									KickClient(client, "[提示]服务器自动踢出玩门达到 %d 次的玩家", g_EnableHandle_e);
									PrintToChatAll("\x04[提示]\x03%s\x05玩门达到限制\x03%d\x05次而被踢出.", clientName, g_EnableHandle_e);//聊天窗提示.
								}
								case 3:
								{
									if (g_EnableHandle_c <= 0)
									{
										BanClient(client, g_EnableHandle_c, BANFLAG_AUTO, "", "[提示]服务器自动永久封禁玩门的玩家");
										PrintToChatAll("\x04[提示]\x03%s\x05玩门达到限制\x03%d\x05次而被永久封禁.", clientName, g_EnableHandle_e);//聊天窗提示.
									}
									else
									{
										BanClient(client, g_EnableHandle_c, BANFLAG_AUTO, "", "[提示]服务器自动临时封禁玩门的玩家");
										PrintToChatAll("\x04[提示]\x03%s\x05玩门达到限制\x03%d\x05次而被封禁\x03%d\x05分钟.", clientName, g_EnableHandle_e, g_EnableHandle_c);//聊天窗提示.
									}
								}
							}
							l4d2_dooropen_kick[client] = 0;
						}
						else
							PrintToChatAll("\x04[提示]\x03%s\x05打开了安全门\x04(\x03%d\x05/\x03%d\x04)\x05.", clientName, g_EnableHandle_e - l4d2_dooropen_kick[client], g_EnableHandle_e);//聊天窗提示.
					}
					case 2:
					{
						PrintToChatAll("\x04[提示]\x03%s\x05打开了安全门.", clientName);//聊天窗提示.
					}
				}
			}
		}
	}
}

//关上安全门.
public void Event_DoorClose(Event event, const char[] name, bool dontBroadcast)
{
	if(g_EnableHandle_a == 0)
		return;
	
	int client = GetClientOfUserId(event.GetInt("userid"));
	
	if(IsValidClient(client))
	{
		GetTrueName(client, clientName);
		if (GetEventBool(event, "checkpoint"))
		{
			if(IsFakeClient(client))
			{
				PrintToChatAll("\x04[提示]\x03%s\x05关上了安全门.", clientName);//聊天窗提示.
			}
			else
			{
				switch(g_EnableHandle_a)
				{
					case 1:
					{
						l4d2_dooropen_kick[client]++;
						if (l4d2_dooropen_kick[client] > g_EnableHandle_e)
						{
							switch(g_EnableHandle_b)
							{
								case 1:
								{
									ForcePlayerSuicide(client);
									PrintToChatAll("\x04[提示]\x03%s\x05玩门达到限制\x03%d\x05次而被处死.", clientName, g_EnableHandle_e);//聊天窗提示.
								}
								case 2:
								{
									KickClient(client, "[提示]服务器自动踢出玩门达到 %d 次的玩家", g_EnableHandle_e);
									PrintToChatAll("\x04[提示]\x03%s\x05玩门达到限制\x03%d\x05次而被踢出.", clientName, g_EnableHandle_e);//聊天窗提示.
								}
								case 3:
								{
									if (g_EnableHandle_c <= 0)
									{
										BanClient(client, g_EnableHandle_c, BANFLAG_AUTO, "", "[提示]服务器自动永久封禁玩门的玩家");
										PrintToChatAll("\x04[提示]\x03%s\x05玩门达到限制\x03%d\x05次而被永久封禁.", clientName, g_EnableHandle_e);//聊天窗提示.
									}
									else
									{
										BanClient(client, g_EnableHandle_c, BANFLAG_AUTO, "", "[提示]服务器自动临时封禁玩门的玩家");
										PrintToChatAll("\x04[提示]\x03%s\x05玩门达到限制\x03%d\x05次而被封禁\x03%d\x05分钟.", clientName, g_EnableHandle_e, g_EnableHandle_c);//聊天窗提示.
									}
								}
							}
							l4d2_dooropen_kick[client] = 0;
						}
						else
							PrintToChatAll("\x04[提示]\x03%s\x05关上了安全门\x04(\x03%d\x05/\x03%d\x04)\x05.", clientName, g_EnableHandle_e - l4d2_dooropen_kick[client], g_EnableHandle_e);//聊天窗提示.
					}
					case 2:
					{
						PrintToChatAll("\x04[提示]\x03%s\x05关上了安全门.", clientName);//聊天窗提示.
					}
				}
			}
		}
	}
}

bool IsValidClient(int client)
{
	return (client > 0 && client <= MaxClients && IsClientInGame(client) && GetClientTeam(client) == 2);
}

void GetTrueName(int bot, char[] savename)
{
	int tbot = IsClientIdle(bot);
	
	if(tbot != 0)
	{
		Format(savename, 32, "★AI:%N★", tbot);
	}
	else
	{
		GetClientName(bot, savename, 32);
	}
}

int IsClientIdle(int bot)
{
	if(IsClientInGame(bot) && GetClientTeam(bot) == 2 && IsFakeClient(bot))
	{
		char sNetClass[12];
		GetEntityNetClass(bot, sNetClass, sizeof(sNetClass));

		if(strcmp(sNetClass, "SurvivorBot") == 0)
		{
			int client = GetClientOfUserId(GetEntProp(bot, Prop_Send, "m_humanSpectatorUserID"));			
			if(client > 0 && IsClientInGame(client))
			{
				return client;
			}
		}
	}
	return 0;
}

/*==============================================================================
 *  安全门卡住检测
 *  ----------------------------------------------------------------------------
 *  场景: 终点安全门(关卡切换门, prop_door_rotating_checkpoint)因为实体状态错乱,
 *        玩家对着门狂按 USE 也完全没有反应, 于是本章始终进不了安全屋,
 *        round_end 永远等不到, 服务器只能等超时.
 *
 *  判定: 玩家对着安全门按下 USE 后等 STUCK_DOOR_REACT_DELAY 再看门的 m_eDoorState,
 *        只要不是"完全关闭"就说明门有反应, 计数清零;
 *        连续 l4d2_enabled_safeRoomDoor_h 次都没反应 => 判定为卡住.
 *
 *  处理: 对门补发 Unlock(仅在门被引擎锁住时) + Open 强制开启, 并重试若干次.
 *
 *  例外: 引擎在"等待其他玩家加载完成"期间会主动锁住安全门并抛
 *        waiting_checkpoint_door_used 事件, 那是正常锁定, 宽限期
 *        l4d2_enabled_safeRoomDoor_i 秒内不参与判定.
 *============================================================================*/

//重置一份干净的检测状态.
void l4d2_SafeDoorReset()
{
	for (int i = 0; i < MAX_CHECKPOINT_DOORS; i++)
	{
		g_iCheckpointDoors[i] = INVALID_ENT_REFERENCE;
		g_iStuckDoorFails[i] = 0;
		g_fStuckDoorLastAttempt[i] = 0.0;
		g_fStuckDoorLockSince[i] = 0.0;
		g_bStuckDoorForced[i] = false;
		g_bStuckDoorAnnounced[i] = false;
		g_iStuckDoorRetry[i] = 0;
	}

	g_iCheckpointDoorCount = 0;
	g_fSafeDoorNextScan = 0.0;

	for (int i = 1; i <= MaxClients; i++)
	{
		g_bClientUsing[i] = false;
	}
}

//抓取本图所有的终点安全门实体.
void l4d2_SafeDoorScan()
{
	int entity = -1;

	while ((entity = FindEntityByClassname(entity, CHECKPOINT_DOOR_CLASS)) != -1)
	{
		if (g_iCheckpointDoorCount >= MAX_CHECKPOINT_DOORS)
			break;

		if (!IsValidEntity(entity))
			continue;

		int slot = g_iCheckpointDoorCount++;

		g_iCheckpointDoors[slot] = EntIndexToEntRef(entity);
		g_iStuckDoorFails[slot] = 0;
		g_fStuckDoorLastAttempt[slot] = 0.0;
		g_fStuckDoorLockSince[slot] = 0.0;
		g_bStuckDoorForced[slot] = false;
		g_bStuckDoorAnnounced[slot] = false;
		g_iStuckDoorRetry[slot] = 0;
	}
}

//还没有门列表时补一次扫描(插件中途加载 / 实体晚生成).
void l4d2_SafeDoorEnsureScan()
{
	if (g_iCheckpointDoorCount > 0)
		return;

	float now = GetGameTime();

	if (now < g_fSafeDoorNextScan)
		return;

	g_fSafeDoorNextScan = now + STUCK_DOOR_SCAN_INTERVAL;
	l4d2_SafeDoorScan();
}

//只清计数, 保留实体列表.
void l4d2_SafeDoorResetCounters()
{
	for (int i = 0; i < g_iCheckpointDoorCount; i++)
	{
		g_iStuckDoorFails[i] = 0;
		g_fStuckDoorLastAttempt[i] = 0.0;
		g_fStuckDoorLockSince[i] = 0.0;
		g_bStuckDoorForced[i] = false;
		g_iStuckDoorRetry[i] = 0;
	}
}

/**
 * 校验门实体还是不是那道安全门.
 * 传进来的是实体索引(计时器里存的是实体引用, 调用方先 EntRefToEntIndex 转回来),
 * 实体被移除后索引可能被别的实体顶替, 这时候再去读 m_eDoorState 会刷一堆
 * 属性找不到的报错, 所以先认一下 classname.
 */
bool l4d2_SafeDoorIsValid(int door)
{
	if (door <= 0 || !IsValidEntity(door))
		return false;

	char sClass[64];

	if (!GetEntityClassname(door, sClass, sizeof(sClass)))
		return false;

	return StrEqual(sClass, CHECKPOINT_DOOR_CLASS, false);
}

//由实体索引反查槽位(比较实体引用, 索引被复用也不会认错门).
int l4d2_SafeDoorFindSlot(int door)
{
	if (door <= 0)
		return -1;

	int ref = EntIndexToEntRef(door);

	for (int i = 0; i < g_iCheckpointDoorCount; i++)
	{
		if (g_iCheckpointDoors[i] == ref)
			return i;
	}

	return -1;
}

//引擎告知: 这道安全门正在等玩家加载完成, 属于正常锁定.
public void Event_WaitingDoorUsed(Event event, const char[] name, bool dontBroadcast)
{
	if (g_EnableHandle_g == 0)
		return;

	int slot = l4d2_SafeDoorFindSlot(event.GetInt("entindex"));

	if (slot == -1)
		return;

	//只记第一次锁定的时间, 否则玩家一直按就会一直续期, 永远判不出卡住.
	if (g_fStuckDoorLockSince[slot] <= 0.0)
		g_fStuckDoorLockSince[slot] = GetGameTime();

	//这里不清计数: 玩家一直按就说明门一直没开, 宽限期一过就该按卡住处理.
}

//玩家按住 USE 的那一刻, 检查准星是不是对着安全门.
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	if (client < 1 || client > MaxClients)
		return Plugin_Continue;

	bool pressed = (buttons & IN_USE) != 0;
	bool justPressed = pressed && !g_bClientUsing[client];

	g_bClientUsing[client] = pressed;

	if (!justPressed || g_EnableHandle_g == 0 || g_bSafeDoorRoundEnded)
		return Plugin_Continue;

	if (!IsClientInGame(client) || IsFakeClient(client) || GetClientTeam(client) != 2 || !IsPlayerAlive(client))
		return Plugin_Continue;

	l4d2_SafeDoorEnsureScan();

	if (g_iCheckpointDoorCount == 0)
		return Plugin_Continue;

	int door = l4d2_SafeDoorGetAimDoor(client);

	if (door == -1)
		return Plugin_Continue;

	l4d2_SafeDoorOnUseAttempt(door);

	return Plugin_Continue;
}

//返回玩家准星上、交互距离内的安全门实体, 没有则 -1.
int l4d2_SafeDoorGetAimDoor(int client)
{
	float vPos[3], vAng[3], vEnd[3];

	GetClientEyePosition(client, vPos);
	GetClientEyeAngles(client, vAng);

	TR_TraceRayFilter(vPos, vAng, MASK_SOLID, RayType_Infinite, TraceFilter_SafeDoor, GetClientUserId(client));

	if (!TR_DidHit())
		return -1;

	int entity = TR_GetEntityIndex();

	if (entity <= 0 || l4d2_SafeDoorFindSlot(entity) == -1)
		return -1;

	TR_GetEndPosition(vEnd);

	if (GetVectorDistance(vPos, vEnd) > STUCK_DOOR_USE_RANGE)
		return -1;

	return entity;
}

//过滤掉玩家自己, 其余实体都参与命中.
public bool TraceFilter_SafeDoor(int entity, int contentsMask, any data)
{
	if (entity <= 0)
		return false;

	int client = GetClientOfUserId(data);

	if (client > 0 && entity == client)
		return false;

	return true;
}

//记一次"对安全门按 USE", 稍后再看门有没有反应.
void l4d2_SafeDoorOnUseAttempt(int door)
{
	int slot = l4d2_SafeDoorFindSlot(door);

	if (slot == -1 || g_bStuckDoorForced[slot])
		return;

	//门本来就不是关着的(正在开 / 已开 / 正在关): 说明它是好的.
	if (GetEntProp(door, Prop_Data, "m_eDoorState") != DoorState_Closed)
	{
		g_iStuckDoorFails[slot] = 0;
		return;
	}

	float now = GetGameTime();

	//门被引擎锁着(等玩家加载完成)或被别的机制锁着: 宽限期内不参与判定.
	if (g_fStuckDoorLockSince[slot] > 0.0 || GetEntProp(door, Prop_Data, "m_bLocked") != 0)
	{
		//锁定起点只盖一次章: 之后玩家一直按也不会续期, 宽限期一到就自然进入计数.
		if (g_fStuckDoorLockSince[slot] <= 0.0)
			g_fStuckDoorLockSince[slot] = now;

		if (now - g_fStuckDoorLockSince[slot] < g_EnableHandle_i)
			return;
	}

	//一次按键只算一次.
	if (now - g_fStuckDoorLastAttempt[slot] < STUCK_DOOR_ATTEMPT_INTERVAL)
		return;

	g_fStuckDoorLastAttempt[slot] = now;
	g_iStuckDoorFails[slot]++;

	CreateTimer(STUCK_DOOR_REACT_DELAY, Timer_SafeDoorReactCheck, g_iCheckpointDoors[slot], TIMER_FLAG_NO_MAPCHANGE);
}

//按下 USE 之后回查: 门动了没有.
public Action Timer_SafeDoorReactCheck(Handle timer, any ref)
{
	int door = EntRefToEntIndex(ref);

	if (!l4d2_SafeDoorIsValid(door))
		return Plugin_Stop;

	int slot = l4d2_SafeDoorFindSlot(door);

	if (slot == -1 || g_bStuckDoorForced[slot])
		return Plugin_Stop;

	//门动了, 这次交互是有效的.
	if (GetEntProp(door, Prop_Data, "m_eDoorState") != DoorState_Closed)
	{
		g_iStuckDoorFails[slot] = 0;
		return Plugin_Stop;
	}

	if (g_iStuckDoorFails[slot] < g_EnableHandle_h)
		return Plugin_Stop;

	l4d2_SafeDoorForceOpen(slot);

	return Plugin_Stop;
}

//强制开启安全门.
void l4d2_SafeDoorForceOpen(int slot)
{
	int door = EntRefToEntIndex(g_iCheckpointDoors[slot]);

	if (!l4d2_SafeDoorIsValid(door))
		return;

	g_bStuckDoorForced[slot] = true;
	g_iStuckDoorRetry[slot] = 0;

	PrintToServer("[safeRoomDoor] 安全门 #%d 连续 %d 次 USE 无反应(state=%d, locked=%d), 强制开启.",
		door, g_iStuckDoorFails[slot],
		GetEntProp(door, Prop_Data, "m_eDoorState"),
		GetEntProp(door, Prop_Data, "m_bLocked"));

	if (!g_bStuckDoorAnnounced[slot])
	{
		g_bStuckDoorAnnounced[slot] = true;
		PrintToChatAll("\x04[提示]\x05检测到安全门卡住，正在强制开启安全门.");
	}

	l4d2_SafeDoorSendOpenInputs(door);
	CreateTimer(STUCK_DOOR_RETRY_DELAY, Timer_SafeDoorOpenRetry, g_iCheckpointDoors[slot], TIMER_FLAG_NO_MAPCHANGE);
}

/**
 * 给门补发开启输入.
 * "Open" 是 CBasePropDoor / CBaseDoor 的标准输入(datamap: InputOpen),
 * 被 forceclosed 或被锁住时引擎会直接忽略, 所以先清掉这两个状态.
 */
void l4d2_SafeDoorSendOpenInputs(int door)
{
	if (!l4d2_SafeDoorIsValid(door))
		return;

	if (GetEntProp(door, Prop_Data, "m_bForceClosed") != 0)
		SetEntProp(door, Prop_Data, "m_bForceClosed", 0);

	if (GetEntProp(door, Prop_Data, "m_bLocked") != 0)
		AcceptEntityInput(door, "Unlock");

	AcceptEntityInput(door, "Open");
}

//强制开启后复查: 门还是没动就再补几次.
public Action Timer_SafeDoorOpenRetry(Handle timer, any ref)
{
	int door = EntRefToEntIndex(ref);

	if (!l4d2_SafeDoorIsValid(door))
		return Plugin_Stop;

	int slot = l4d2_SafeDoorFindSlot(door);

	if (slot == -1)
		return Plugin_Stop;

	//门已经在动了, 强制开启生效.
	if (GetEntProp(door, Prop_Data, "m_eDoorState") != DoorState_Closed)
	{
		g_iStuckDoorFails[slot] = 0;
		return Plugin_Stop;
	}

	if (g_iStuckDoorRetry[slot] >= STUCK_DOOR_RETRY_MAX)
	{
		PrintToServer("[safeRoomDoor] 安全门 #%d 补发 %d 次开启输入仍然没有反应.",
			door, STUCK_DOOR_RETRY_MAX);

		//放开限制, 让后面(比如挡门的玩家走开之后)还能重新累计判定.
		g_bStuckDoorForced[slot] = false;
		g_iStuckDoorFails[slot] = 0;
		return Plugin_Stop;
	}

	g_iStuckDoorRetry[slot]++;
	l4d2_SafeDoorSendOpenInputs(door);
	CreateTimer(STUCK_DOOR_RETRY_DELAY, Timer_SafeDoorOpenRetry, g_iCheckpointDoors[slot], TIMER_FLAG_NO_MAPCHANGE);

	return Plugin_Stop;
}