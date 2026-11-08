#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <left4dhooks>
#include <l4d2util_infected>

#define PLUGIN_VERSION "4.5.0-edi"

public Plugin myinfo = 
{
	name = "[L4D2] Proper Sack Order (EDI)",
	author = "apples1949",
	description = "Finally fix that pesky spawn rotation not being reliable (EDI: 重复特感另开新池)",
	version = PLUGIN_VERSION,
	url = "https://github.com/SirPlease/L4D2-Competitive-Rework"
};

enum
{
	OverLimit_OK = 0,
	OverLimit_Dominator,
	OverLimit_Class,
	
	MAX_OverLimitReason
};

stock const char g_sOverLimitReason[MAX_OverLimitReason][] = {
	"", "Dominator limit", "Class limit"
};

/* These class numbers are the same ones used internally in L4D2 */

#define SI_GENERIC_BEGIN L4D2Infected_Smoker
#define SI_GENERIC_END L4D2Infected_Witch
#define SI_MAX_SIZE L4D2Infected_Size
#define SI_None L4D2Infected_Common

ArrayList g_SpawnsArray;

bool g_isLive;

ConVar g_cvSILimits[SI_MAX_SIZE];
int g_iInitialSILimits[SI_MAX_SIZE];
int g_Dominators;

int g_iStoredClass[MAXPLAYERS+1];
bool g_bPlayerSpawned[MAXPLAYERS+1];

ConVar g_cvDebug;
// EDI 新增：特感入池模式开关（1 = 重复特感另开新池，0 = 重复特感相邻生成的旧行为）
ConVar g_cvPoolMode;
ConVar director_allow_infected_bots, z_max_player_zombies;

public void OnPluginStart()
{
	HookEvent("round_start", Event_RoundStart);
	HookEvent("round_end", Event_RoundEnd);
	
	HookEvent("versus_round_start", Event_RealRoundStart);
	HookEvent("scavenge_round_start", Event_RealRoundStart);
	
	InitSILimits();
	g_cvDebug = CreateConVar("sackorder_debug", "0", "Debuggin the plugin.", FCVAR_SPONLY|FCVAR_HIDDEN, true, 0.0, true, 1.0);
	
	// EDI 新增：默认 1（新行为，重复特感另开新池）；改为 0 可完全退回 4.4.3 的"重复特感相邻生成"
	g_cvPoolMode = CreateConVar("l4d2_fix_spawn_order_pool_mode", "1", "1 = 重复特感另开新池(默认); 0 = 重复特感相邻生成(旧行为)", FCVAR_NONE, true, 0.0, true, 1.0);
	
	director_allow_infected_bots = FindConVar("director_allow_infected_bots");
	z_max_player_zombies = FindConVar("z_max_player_zombies");
	
	g_SpawnsArray = new ArrayList();

	// 观测指令（只读，见文件末尾 "Pool State Command" 段）：
	//   管理员：sm_sackorder_pool / 别名 sm_si_pool
	//   服务器控制台、rcon：sm_sackorder_pool_sv / 别名 sm_si_pool_sv
	RegAdminCmd("sm_sackorder_pool", Cmd_PoolState, ADMFLAG_GENERIC, "查看特感轮换池当前状态(只读观测)");
	RegAdminCmd("sm_si_pool", Cmd_PoolState, ADMFLAG_GENERIC, "sm_sackorder_pool 的短别名");
	RegServerCmd("sm_sackorder_pool_sv", Cmd_PoolStateServer, "查看特感轮换池当前状态(只读观测，服务器控制台/rcon)");
	RegServerCmd("sm_si_pool_sv", Cmd_PoolStateServer, "sm_sackorder_pool_sv 的短别名");
}

void InitSILimits()
{
	char buffer[64];
	for (int i = SI_GENERIC_BEGIN; i < SI_GENERIC_END; ++i)
	{
		FormatEx(buffer, sizeof(buffer), "z_versus_%c%s_limit", CharToLower(L4D2_InfectedNames[i][0]), L4D2_InfectedNames[i][1]);
		g_cvSILimits[i] = FindConVar(buffer);
	}
}

public void OnConfigsExecuted()
{
	g_Dominators = 53;
	ConVar hDominators = FindConVar("l4d2_dominators");
	if (hDominators != null) g_Dominators = hDominators.IntValue;
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	ToggleEvents(false);
	g_SpawnsArray.Clear();
	g_isLive = false;
}

void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	ToggleEvents(false);
	g_SpawnsArray.Clear();
	g_isLive = false;
}

void Event_RealRoundStart(Event event, const char[] name, bool dontBroadcast)
{
	if (!L4D_HasPlayerControlledZombies())
		return;
	
	if (g_isLive)
		return;
	
	ToggleEvents(true);
	FillQueue();
	g_isLive = true;
}

void ToggleEvents(bool isEnable)
{
	static bool hasEnabled = false;
	
	if (isEnable == hasEnabled)
		return;
	
	if (isEnable)
	{
		HookEvent("player_team", Event_PlayerTeam);
		HookEvent("player_death", Event_PlayerDeath);
		HookEvent("bot_player_replace", Event_BotPlayerReplace);
		HookEvent("player_bot_replace", Event_PlayerBotReplace);
		
		hasEnabled = true;
	}
	else
	{
		UnhookEvent("player_team", Event_PlayerTeam);
		UnhookEvent("player_death", Event_PlayerDeath);
		UnhookEvent("bot_player_replace", Event_BotPlayerReplace);
		UnhookEvent("player_bot_replace", Event_PlayerBotReplace);
		
		hasEnabled = false;
	}
}

//--------------------------------------------------------------------------------- Player Actions
//
// Basic strategy:
//   1. Zombie classes is handled by a queue: pop the beginning, push to the end.
//   2. Return zombie class, based on the player state: ghost to the beginning, materialized to the end.
//

public Action L4D_OnMaterializeFromGhostPre(int client)
{
	PrintDebug("\x05%N \x05materialized \x01as (\x04%s\x01)", client, L4D2_InfectedNames[GetInfectedClass(client)]);

	g_bPlayerSpawned[client] = true;
	return Plugin_Continue;
}

public void L4D_OnMaterializeFromGhost_PostHandled(int client)
{
	PrintDebug("\x05%N \x05got de-materialized because of other plugins' handling.", client);
	
	g_bPlayerSpawned[client] = false;
}

void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	int team = event.GetInt("team");
	int oldteam = event.GetInt("oldteam");
	if (team == oldteam)
		return;
	
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!client || !IsClientInGame(client))
		return;
	
	if (team == 3)
	{
		if (!director_allow_infected_bots.BoolValue)
			return;
		
		if (IsFakeClient(client))
			return;
		
		if (GetSICount(false) + 1 <= z_max_player_zombies.IntValue)
			return;
		
		PrintDebug("Infected Team is \x04going over capacity \x01after \x05%N \x01joined", client);
		
		int lastUserId = 0;
		for (int i = 1; i <= MaxClients; ++i)
		{
			if (!IsClientInGame(i) || !IsPlayerAlive(i))
				continue;
			
			if (!IsFakeClient(i))
				continue;
			
			if (GetClientTeam(i) != 3)
				continue;
			
			if (GetInfectedClass(i) == L4D2Infected_Tank)
				continue;
			
			int userid = GetClientUserId(i);
			if (lastUserId < userid)
				lastUserId = userid;
		}
		
		if (lastUserId > 0)
		{
			int lastBot = GetClientOfUserId(lastUserId);
			
			PrintDebug("\x05%N is selected to cull", lastBot);
			ForcePlayerSuicide(lastBot);
		}
	}
	else if (oldteam == 3)
	{
		if (!IsPlayerAlive(client))
			return;
		
		PrintDebug("\x05%N \x01left Infected Team \x01as (\x04%s\x01)", client, L4D2_InfectedNames[GetInfectedClass(client)]);
		
		QueuePlayerSI(client);
	}
}

void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!client || !IsClientInGame(client))
		return;
	
	if (GetClientTeam(client) != 3)
		return;
	
	PrintDebug("\x05%N \x01died \x01as (\x04%s\x01)", client, L4D2_InfectedNames[GetInfectedClass(client)]);
	
	QueuePlayerSI(client);
}

void Event_BotPlayerReplace(Event event, const char[] name, bool dontBroadcast)
{
	HandlePlayerReplace(GetClientOfUserId(event.GetInt("player")), GetClientOfUserId(event.GetInt("bot")));
}

void Event_PlayerBotReplace(Event event, const char[] name, bool dontBroadcast)
{
	HandlePlayerReplace(GetClientOfUserId(event.GetInt("bot")), GetClientOfUserId(event.GetInt("player")));
}

void HandlePlayerReplace(int replacer, int replacee)
{
	// reported a compatibility issue with confoglcompmod BotKick module
	// well just dont use it which blocks client connection instead of slaying
	if (!replacer || !replacee || !IsClientInGame(replacer) || !IsClientInGame(replacee))
		return;
	
	if (GetClientTeam(replacer) != 3)
		return;
	
	PrintDebug("\x05%N \x01replaced \x05%N \x01as (\x04%s\x01)", replacer, replacee, L4D2_InfectedNames[GetInfectedClass(replacer)]);
	
	if (GetInfectedClass(replacer) == L4D2Infected_Tank && !IsFakeClient(replacer))
	{
		PrintDebug("\x05%N \x01(\x04%s\x01) \x01replaced an \x04AI Tank", replacer, L4D2_InfectedNames[g_iStoredClass[replacer]]);
		
		QueuePlayerSI(replacer);
		return;
	}
	
	g_iStoredClass[replacer] = g_iStoredClass[replacee];
	g_bPlayerSpawned[replacer] = g_bPlayerSpawned[replacee]; // what if replacing ghost? :(
	
	g_iStoredClass[replacee] = SI_None;
	g_bPlayerSpawned[replacee] = false;
	
	if ( !IsPlayerAlive(replacer) // compatible with "l4d2_nosecondchances"
	  || (IsFakeClient(replacer) && !director_allow_infected_bots.BoolValue) ) 
	{
		QueuePlayerSI(replacer);
	}
}

public void L4D_OnReplaceTank(int tank, int newtank)
{
	if (newtank <= 0 || newtank > MaxClients)
		return;
	
	if (!IsClientInGame(newtank) || !IsPlayerAlive(newtank))
		return;
	
	if (GetClientTeam(newtank) != 3)
		return;
	
	PrintDebug("\x05%N \x01(\x04%s\x01) \x01is going to replace \x05%N\x01's \x04Tank", newtank, L4D2_InfectedNames[GetInfectedClass(newtank)], tank);
	
	QueuePlayerSI(newtank);
}

/**
 * Helper to check if the player entering ghost state has committed a despawn.
 */
bool isCulling = false;
public Action L4D_OnEnterGhostStatePre(int client)
{
	static int s_iOffs_m_bPZAbortedControl = -1;
	if (s_iOffs_m_bPZAbortedControl == -1)
		s_iOffs_m_bPZAbortedControl = FindSendPropInfo("CTerrorPlayer", "m_bSurvivorGlowEnabled") + 1;
	
	isCulling = GetEntData(client, s_iOffs_m_bPZAbortedControl, 1) != 0;
	
	return Plugin_Continue;
}

/**
 * Give spawned player an SI from queue and/or remember what their class is.
 */
public void L4D_OnEnterGhostState(int client)
{
	int SI = GetInfectedClass(client);
	
	// Don't mess up when player despawns or round restarts.
	if (!isCulling && g_isLive)
	{
		int temp = PopQueuedSI(client);
		if (temp != SI_None)
		{
			SI = temp;
			L4D_SetClass(client, SI);
		}
	}
	
	PrintDebug("%N %s \x01as (\x04%s\x01)", client, isCulling ? "\x05respawned" : "\x01spawned", L4D2_InfectedNames[SI]);
	
	g_iStoredClass[client] = SI;
	g_bPlayerSpawned[client] = false;
}

//--------------------------------------------------------------------------------- Bot Spawning
//
// Change the bot's class on spawn to the one popped from queue
//

int g_ZombieClass = SI_None;
public Action L4D_OnSpawnSpecial(int &zombieClass, const float vecPos[3], const float vecAng[3])
{
	PrintDebug("Director attempting to spawn (\x04%s\x01)", L4D2_InfectedNames[zombieClass]);
	
	if (!director_allow_infected_bots.BoolValue)
		return Plugin_Continue;
	
	/* 池未建立时直接放行，交回引擎默认行为。
	 * FillQueue() 只在 versus_round_start 且 L4D_HasPlayerControlledZombies() 为真时执行，
	 * 而 round_start / round_end 都会把池清空并置 g_isLive = false。
	 * 若本回合池子始终没建起来（回合开始时感染方没有真人、非对抗模式、事件顺序异常），
	 * 继续往下走会 PopQueuedSI(-1) == SI_None -> Plugin_Handled，
	 * 把 Director 整个回合的 AI 特感生成全部挡掉（表现为"多特感永远不满"）。
	 * 池空 != 应当禁生成：没有额度可用时应当退回引擎原生的随机选职业。 */
	if (!g_isLive)
		return Plugin_Continue;
	
	if (GetSICount(false) + 1 > z_max_player_zombies.IntValue)
	{
		PrintDebug("Blocking director spawn for \x03going over player limit\x01.");
		return Plugin_Handled;
	}
	
	g_ZombieClass = PopQueuedSI(-1);
	if (g_ZombieClass == SI_None)
	{
		PrintDebug("Blocking director spawn for \x04running out of available SI\x01.");
		return Plugin_Handled;
	}
	
	zombieClass = g_ZombieClass;
	PrintDebug("Overriding director spawn to (\x04%s\x01)", L4D2_InfectedNames[g_ZombieClass]);
	
	return Plugin_Changed;
}

public void L4D_OnSpawnSpecial_Post(int client, int zombieClass, const float vecPos[3], const float vecAng[3])
{
	PrintDebug("Director spawned a bot (expected \x05%s\x01, got %s%s\x01)", L4D2_InfectedNames[g_ZombieClass], g_ZombieClass == zombieClass ? "\x05" : "\x04", L4D2_InfectedNames[zombieClass]);
	
	if (!director_allow_infected_bots.BoolValue)
		return;
	
	g_ZombieClass = SI_None;
	g_iStoredClass[client] = zombieClass;
	g_bPlayerSpawned[client] = true;
}

public void L4D_OnSpawnSpecial_PostHandled(int client, int zombieClass, const float vecPos[3], const float vecAng[3])
{
	PrintDebug("Director's spawn was \x04blocked \x01(expected \x05%s\x01, got %s%s\x01)", L4D2_InfectedNames[g_ZombieClass], g_ZombieClass == zombieClass ? "\x05" : "\x04", L4D2_InfectedNames[zombieClass]);
	
	if (!director_allow_infected_bots.BoolValue)
		return;
	
	if (g_ZombieClass != SI_None)
	{
		QueueSI(g_ZombieClass, true);
		g_ZombieClass = SI_None;
	}
}

//--------------------------------------------------------------------------------- Stocks & Such

void QueuePlayerSI(int client)
{
	int SI = g_iStoredClass[client];
	if (IsAbleToQueue(SI, client))
	{
		QueueSI(SI, !g_bPlayerSpawned[client]);
	}
	
	g_iStoredClass[client] = SI_None;
	g_bPlayerSpawned[client] = false;
}

void QueueSI(int SI, bool front)
{
	if (front && g_SpawnsArray.Length)
	{
		g_SpawnsArray.ShiftUp(0);
		g_SpawnsArray.Set(0, SI);
	}
	else
	{
		g_SpawnsArray.Push(SI);
	}
	
	PrintDebug("Queuing (\x05%s\x01) to \x04%s", L4D2_InfectedNames[SI], front ? "the front" : "the end");
}

int PopQueuedSI(int skip_client)
{
	int size = g_SpawnsArray.Length;
	if (!size)
		return SI_None;
	
	for (int i = 0; i < size; ++i)
	{
		int QueuedSI = g_SpawnsArray.Get(i);
		
		int status = IsClassOverLimit(QueuedSI, skip_client);
		if (status == OverLimit_OK)
		{
			g_SpawnsArray.Erase(i);
			PrintDebug("Popped (\x05%s\x01) after \x04%i \x01%s", L4D2_InfectedNames[QueuedSI], i+1, i+1 > 1 ? "tries" : "try");
			return QueuedSI;
		}
		else
		{
			PrintDebug("Popping (\x05%s\x01) but \x03over limit \x01(\x03reason: %s\x01)", L4D2_InfectedNames[QueuedSI], g_sOverLimitReason[status]);
		}
	}
	
	PrintDebug("\x04Failed to pop queued SI! \x01(size = \x05%i\x01)", size);
	return SI_None;
}

/**
 * TODO:
 *   Fill with the remaining first hit classes when the Infected Team isn't full?
 * NOTE:
 *   Director randomly picks a beginning index for the first hit
 *   i.e. if pick is 4, then first hit setup will be Spitter(4),Jockey(5),Charger(6),Smoker(1)
 */
void FillQueue()
{
	int zombies[SI_MAX_SIZE] = {0};
	CollectZombies(zombies);
	
	char classString[255] = "";
	
	if (g_cvPoolMode.IntValue == 1)
	{
		// EDI 新行为：按"轮次(round-robin)"入池。
		//   第 1 轮给每个仍有余额的职业各放一个，第 2 轮再给仍有余额（重复配置）的职业各放一个，依此类推。
		//   这样重复的特感会被排到池子后面的"新池子"，而不是紧挨着同职业生成。
		//   例：smoker1 boomer1 hunter2 spitter1 jockey1 charger1
		//       → smoker, boomer, hunter, spitter, jockey, charger, hunter
		//   例：smoker2 boomer1 hunter1 spitter1 jockey2 charger1
		//       → smoker, boomer, hunter, spitter, jockey, charger, smoker, jockey
		int maxCount = 0;
		for (int SI = SI_GENERIC_BEGIN; SI < SI_GENERIC_END; ++SI)
		{
			g_iInitialSILimits[SI] = g_cvSILimits[SI].IntValue;
			
			int count = g_iInitialSILimits[SI] - zombies[SI];
			if (count > maxCount)
				maxCount = count;
		}
		
		for (int r = 0; r < maxCount; ++r)
		{
			for (int SI = SI_GENERIC_BEGIN; SI < SI_GENERIC_END; ++SI)
			{
				// 该职业还有超过 r 个待放，才在本轮放一个
				if (g_iInitialSILimits[SI] - zombies[SI] > r)
				{
					g_SpawnsArray.Push(SI);
					
					StrCat(classString, sizeof(classString), L4D2_InfectedNames[SI]);
					StrCat(classString, sizeof(classString), ", ");
				}
			}
		}
	}
	else
	{
		// EDI 旧行为（l4d2_fix_spawn_order_pool_mode = 0）：保持 4.4.3 原样，重复的特感相邻进池
		for (int SI = SI_GENERIC_BEGIN; SI < SI_GENERIC_END; ++SI)
		{
			g_iInitialSILimits[SI] = g_cvSILimits[SI].IntValue;
			
			for (int j = 0; j < g_iInitialSILimits[SI] - zombies[SI]; ++j)
			{
				g_SpawnsArray.Push(SI);
				
				StrCat(classString, sizeof(classString), L4D2_InfectedNames[SI]);
				StrCat(classString, sizeof(classString), ", ");
			}
		}
	}
	
	int idx = strlen(classString) - 2;
	if (idx < 0) idx = 0;
	classString[idx] = '\0';
	PrintDebug("Filled queue (%s)", classString);
}

/**
 * Check if specific class can be queued based on initial SI pool.
 *
 * NOTE:
 *   Static limits used here.
 */
bool IsAbleToQueue(int SI, int skip_client)
{
	if (SI >= SI_GENERIC_BEGIN && SI < SI_GENERIC_END)
	{
		int counts[SI_MAX_SIZE] = {0};
		
		// NOTE: We're checking after player actually spawns, it's necessary to ignore his class.
		CollectZombies(counts, skip_client);
		CollectQueuedZombies(counts);
		
		if (counts[SI] < g_iInitialSILimits[SI])
			return true;
	}
	
	PrintDebug("\x04Unexpected class \x01(\x05%s\x01)", SI == -1 ? "INVALID" : L4D2_InfectedNames[SI]);
	return false;
}

/**
 * Check if specific class is over limit based on limit convars and dominator flags.
 *  1.	< class limit
 *  2a.	not dominator
 *  2b.	is dominator
 *  3b.	total dominators < 3
 *
 * NOTE:
 *   Dynamic limits used here.
 *
 * TODO: 
 *   No more redundant collecting zombies in the same frame?
 */
int IsClassOverLimit(int SI, int skip_client)
{
	if (!g_cvSILimits[SI])
		return OverLimit_OK;
	
	int counts[SI_MAX_SIZE] = {0};
	
	// NOTE: We're checking after player actually spawns, it's necessary to ignore his class.
	CollectZombies(counts, skip_client);
	
	if (counts[SI] >= g_cvSILimits[SI].IntValue)
		return OverLimit_Class;
	
	if (!IsDominator(SI))
		return OverLimit_OK;
	
	int dominatorCount = 0;
	for (int i = SI_GENERIC_BEGIN; i < SI_GENERIC_END; ++i)
		if (IsDominator(i)) dominatorCount += counts[i];
	
	if (dominatorCount >= 3)
		return OverLimit_Dominator;
	
	return OverLimit_OK;
}

bool IsDominator(int SI)
{
	return g_Dominators & (1 << (SI-1)) > 0;
}

int CollectZombies(int zombies[SI_MAX_SIZE], int skip_client = -1)
{
	int count = 0;
	
	char classString[255] = "";
	for (int i = 1; i <= MaxClients; ++i)
	{
		if (i == skip_client)
			continue;
		
		if (!IsClientInGame(i) || !IsPlayerAlive(i))
			continue;
		
		if (GetClientTeam(i) != 3)
			continue;
		
		int SI = g_iStoredClass[i];
		if (SI == SI_None)
			continue;
		
		++zombies[SI];
		++count;
		StrCat(classString, sizeof(classString), L4D2_InfectedNames[SI]);
		StrCat(classString, sizeof(classString), ", ");
	}
	
	int idx = strlen(classString) - 2;
	if (idx < 0) idx = 0;
	classString[idx] = '\0';
	PrintDebug("Collect zombies (%s)", classString);
	
	return count;
}

int CollectQueuedZombies(int zombies[SI_MAX_SIZE])
{
	int size = g_SpawnsArray.Length;
	
	char classString[255] = "";
	for (int i = 0; i < size; ++i)
	{
		int SI = g_SpawnsArray.Get(i);
		
		++zombies[SI];
		StrCat(classString, sizeof(classString), L4D2_InfectedNames[SI]);
		StrCat(classString, sizeof(classString), ", ");
	}
	
	int idx = strlen(classString) - 2;
	if (idx < 0) idx = 0;
	classString[idx] = '\0';
	PrintDebug("Collect queued zombies (%s)", classString);
	
	return size;
}

int GetSICount(bool isHumanOnly = true)
{
	int count = 0;
	for (int i = 1; i <= MaxClients; ++i)
	{
		if (!IsClientInGame(i))
			continue;
		
		if (GetClientTeam(i) != 3)
			continue;
		
		if (IsFakeClient(i))
		{
			if (isHumanOnly)
				continue;
			
			if (GetInfectedClass(i) == L4D2Infected_Tank)
				continue;
			
			if (!IsPlayerAlive(i))
				continue;
		}
		
		count++;
	}
	
	return count;
}

stock void PrintDebug(const char[] format, any ...)
{
	if (g_cvDebug.BoolValue)
	{
		char msg[255];
		VFormat(msg, sizeof(msg), format, 2);
		PrintToChatAll("\x04[DEBUG]\x01 %s", msg);
	}
}

//--------------------------------------------------------------------------------- Pool State Command
//
// 只读观测手段：打印轮换池 g_SpawnsArray 的当前状态，以及"下一次生成会被怎么过滤"的预判。
//
// 入口（两个入口共用 DumpSpawnPool()，不存在第二份打印逻辑）：
//   * sm_sackorder_pool / sm_si_pool      -> RegAdminCmd，ADMFLAG_GENERIC（回给发命令的人）
//   * sm_sackorder_pool_sv / sm_si_pool_sv -> RegServerCmd（服务器控制台、rcon）
//
// 红线：本段所有代码只读取全局状态（g_SpawnsArray / g_iInitialSILimits / ConVar / 客户端扫描），
// 不写队列、不写计数、不调用 PopQueuedSI()/QueueSI()/FillQueue()，因此不会改变生成逻辑的行为。
// 唯一"复算"的部分是 PoolReplySimulation() 里的本地副本模拟，它不碰插件状态。
//
// NOTE(skip_client)：预判用 IsClassOverLimit(SI, -1)，即"不排除任何客户端"，
// 对应 L4D_OnSpawnSpecial -> PopQueuedSI(-1) 这条 Director 生成 AI SI 的路径。
// 而人类玩家进入 ghost 时走 L4D_OnEnterGhostState -> PopQueuedSI(client)，
// 会把他自己当前 g_iStoredClass 那一份存活计数排除掉，
// 所以人类 ghost 的实际结果可能比这里的预判"多放过一个"（他自己那个职业）。

#define POOL_DUMP_MAX_ITEMS 30	// 池子顺序最多列出多少个元素，超出截断并提示总数
#define POOL_DUMP_MAX_SKIP 10	// "会被跳过"的预判最多列出多少条
#define POOL_DUMP_MAX_SIM 8		// 模拟最多预测几次生成
#define POOL_DUMP_LINE 118		// 单条聊天正文上限(引擎对一条 chat 约 192 字节，留出前缀/颜色码余量)

public Action Cmd_PoolState(int client, int args)
{
	DumpSpawnPool(client);
	return Plugin_Handled;
}

public Action Cmd_PoolStateServer(int args)
{
	DumpSpawnPool(0); // client = 0 -> 输出走 PrintToServer
	return Plugin_Handled;
}

/**
 * 统一输出通道：给玩家就发聊天，给服务器控制台/rcon 就打服务端控制台。
 */
void PoolReply(int client, const char[] fmt, any ...)
{
	char buffer[256];
	VFormat(buffer, sizeof(buffer), fmt, 3);

	if (client > 0 && client <= MaxClients && IsClientInGame(client))
		PrintToChat(client, " \x04[SackOrder]\x01 %s", buffer);
	else
		PrintToServer("[SackOrder] %s", buffer);
}

void DumpSpawnPool(int client)
{
	int poolSize = g_SpawnsArray.Length;

	// NOTE: CollectZombies()/CollectQueuedZombies() 是"累加到传入数组"，必须自己先清零。
	int alive[SI_MAX_SIZE] = {0};
	int queued[SI_MAX_SIZE] = {0};
	CollectZombies(alive);        // 只按插件记录的 g_iStoredClass 统计"活着"的 SI
	CollectQueuedZombies(queued); // 池中各职业的数量

	int aliveTotal = 0;
	int domAlive = 0;
	for (int SI = SI_GENERIC_BEGIN; SI < SI_GENERIC_END; ++SI)
	{
		aliveTotal += alive[SI];

		if (IsDominator(SI))
			domAlive += alive[SI];
	}

	char zmaxBuf[16];
	if (z_max_player_zombies != null)
		FormatEx(zmaxBuf, sizeof(zmaxBuf), "%d", z_max_player_zombies.IntValue);
	else
		FormatEx(zmaxBuf, sizeof(zmaxBuf), "n/a");

	char aiBotsBuf[16];
	if (director_allow_infected_bots != null)
		FormatEx(aiBotsBuf, sizeof(aiBotsBuf), "%d", director_allow_infected_bots.IntValue);
	else
		FormatEx(aiBotsBuf, sizeof(aiBotsBuf), "n/a");

	PoolReply(client, "==== Proper Sack Order: pool state ====");
	PoolReply(client, "live=%s pool_mode=%d pool_len=%d SI_alive=%d SI_slots=%d z_max=%s ai_bots=%s player_ctrl=%s",
		g_isLive ? "yes" : "no",
		g_cvPoolMode.IntValue,
		poolSize,
		aliveTotal,
		GetSICount(false), // 与 L4D_OnSpawnSpecial 的 z_max 闸同一个口径(含人类 ghost)
		zmaxBuf,
		aiBotsBuf,
		L4D_HasPlayerControlledZombies() ? "yes" : "no");

	// dominator：IsDominator() 用 g_Dominators（OnConfigsExecuted 时缓存），这里额外显示实时 cvar，
	// 两者不一致就说明缓存快照和当前配置已经分叉了。
	ConVar hDominators = FindConVar("l4d2_dominators");
	char domClasses[128] = "";
	for (int SI = SI_GENERIC_BEGIN; SI < SI_GENERIC_END; ++SI)
	{
		if (!IsDominator(SI))
			continue;

		if (domClasses[0] != '\0')
			StrCat(domClasses, sizeof(domClasses), ",");

		StrCat(domClasses, sizeof(domClasses), L4D2_InfectedNames[SI]);
	}
	if (domClasses[0] == '\0')
		StrCat(domClasses, sizeof(domClasses), "none");

	PoolReply(client, "dominator mask(cached)=%d cvar(now)=%d classes=[%s] dom_alive=%d/3",
		g_Dominators,
		hDominators != null ? hDominators.IntValue : -1,
		domClasses,
		domAlive);

	// 每职业一行：实时 limit / 回合初快照 / 当前存活 / 池中数量 / 是否 dominator
	for (int SI = SI_GENERIC_BEGIN; SI < SI_GENERIC_END; ++SI)
	{
		char nameBuf[16];
		FormatEx(nameBuf, sizeof(nameBuf), "%s", L4D2_InfectedNames[SI]);
		while (strlen(nameBuf) < 9)
			StrCat(nameBuf, sizeof(nameBuf), " ");

		int live = g_cvSILimits[SI] != null ? g_cvSILimits[SI].IntValue : -1;

		PoolReply(client, "%s limit=%d snapshot=%d alive=%d queued=%d%s%s",
			nameBuf,
			live,
			g_iInitialSILimits[SI],
			alive[SI],
			queued[SI],
			IsDominator(SI) ? " [dom]" : "",
			(live >= 0 && alive[SI] >= live) ? " [class full]" : "");
	}

	if (!g_isLive)
	{
		PoolReply(client, "pool NOT live: 当前不在对抗/清道夫回合，或回合已经开始但 FillQueue() 未执行(池未建立)。");
		PoolReply(client, "此时 L4D_OnSpawnSpecial 仍会去 PopQueuedSI(-1)，池空会把 Director 的 AI SI 生成挡掉。");

		bool snapshotEmpty = true;
		for (int SI = SI_GENERIC_BEGIN; SI < SI_GENERIC_END; ++SI)
			if (g_iInitialSILimits[SI] != 0)
				snapshotEmpty = false;

		if (snapshotEmpty)
			PoolReply(client, "note: g_iInitialSILimits[] 全为 0 -> FillQueue() 本回合从未执行过。");

		PoolReply(client, "==== end (not live) ====");
		return;
	}

	PoolReplyOrder(client, "pool order", POOL_DUMP_MAX_ITEMS);

	// z_max_player_zombies 这道闸在 L4D_OnSpawnSpecial 里比池子更早，先说清楚。
	// NOTE: 这里用 GetSICount(false) 复算，和 L4D_OnSpawnSpecial 第 356 行的判定口径一致。
	if (z_max_player_zombies != null && GetSICount(false) + 1 > z_max_player_zombies.IntValue)
	{
		PoolReply(client, "note: z_max_player_zombies 已经满了(%d+1 > %d)，Director 生成会先被这道闸挡掉，池子形同不参与。",
			GetSICount(false), z_max_player_zombies.IntValue);
	}

	PoolReplyForecast(client);
	PoolReplySimulation(client, alive, domAlive);

	PoolReply(client, "==== end ====");
}

/**
 * 打印池子顺序（按队列下标顺序），超长截断。
 */
void PoolReplyOrder(int client, const char[] label, int maxItems)
{
	int total = g_SpawnsArray.Length;

	char chunk[192];
	char item[64];

	FormatEx(chunk, sizeof(chunk), "%s (%d): ", label, total);

	if (total == 0)
	{
		StrCat(chunk, sizeof(chunk), "(empty)");
		PoolReply(client, "%s", chunk);
		return;
	}

	int shown = 0;
	for (int i = 0; i < total && i < maxItems; ++i)
	{
		int SI = g_SpawnsArray.Get(i);

		if (SI >= SI_GENERIC_BEGIN && SI < SI_GENERIC_END)
			FormatEx(item, sizeof(item), "%s%s", shown > 0 ? ", " : "", L4D2_InfectedNames[SI]);
		else
			FormatEx(item, sizeof(item), "%s#%d", shown > 0 ? ", " : "", SI);

		if (strlen(chunk) + strlen(item) > POOL_DUMP_LINE)
		{
			PoolReply(client, "%s", chunk);
			FormatEx(chunk, sizeof(chunk), "      "); // 续行缩进
		}

		StrCat(chunk, sizeof(chunk), item);
		++shown;
	}

	if (total > shown)
	{
		FormatEx(item, sizeof(item), " ... (%d more)", total - shown);
		StrCat(chunk, sizeof(chunk), item);
	}

	PoolReply(client, "%s", chunk);
}

/**
 * 对池中每个元素跑一次 IsClassOverLimit(SI, -1)，标出当前会被跳过的元素及原因。
 * NOTE: 这里的判定是"此刻的存活数"，不会随着扫描过程累加（PopQueuedSI 一次只弹一个，所以足够）。
 */
void PoolReplyForecast(int client)
{
	int total = g_SpawnsArray.Length;

	if (total == 0)
	{
		PoolReply(client, "forecast(skip_client=-1): pool is EMPTY -> L4D_OnSpawnSpecial 会 Plugin_Handled 掉生成。");
		return;
	}

	char chunk[192];
	char item[80];

	FormatEx(chunk, sizeof(chunk), "forecast(skip_client=-1) would skip:");

	int okCount = 0;
	int firstOk = -1;
	int skippedTotal = 0;
	int skippedShown = 0;

	for (int i = 0; i < total; ++i)
	{
		int SI = g_SpawnsArray.Get(i);
		if (SI < SI_GENERIC_BEGIN || SI >= SI_GENERIC_END)
			continue;

		int status = IsClassOverLimit(SI, -1);
		if (status == OverLimit_OK)
		{
			++okCount;
			if (firstOk < 0)
				firstOk = i;

			continue;
		}

		++skippedTotal;
		if (skippedShown >= POOL_DUMP_MAX_SKIP)
			continue;

		FormatEx(item, sizeof(item), " [%d]%s=%s", i, L4D2_InfectedNames[SI], g_sOverLimitReason[status]);
		if (strlen(chunk) + strlen(item) > POOL_DUMP_LINE)
		{
			PoolReply(client, "%s", chunk);
			FormatEx(chunk, sizeof(chunk), "      ");
		}

		StrCat(chunk, sizeof(chunk), item);
		++skippedShown;
	}

	if (skippedTotal == 0)
	{
		StrCat(chunk, sizeof(chunk), " none");
	}
	else if (skippedTotal > skippedShown)
	{
		FormatEx(item, sizeof(item), " ... (%d more)", skippedTotal - skippedShown);
		StrCat(chunk, sizeof(chunk), item);
	}

	PoolReply(client, "%s", chunk);

	if (firstOk >= 0)
	{
		int SI = g_SpawnsArray.Get(firstOk);
		PoolReply(client, "next poppable: pool[%d]=%s (%d/%d 个元素现在能出)",
			firstOk, L4D2_InfectedNames[SI], okCount, total);
	}
	else
	{
		PoolReply(client, "next poppable: NONE (0/%d 个元素能出) -> 下一次 AI SI 生成会被挡掉", total);
	}
}

/**
 * 本地模拟：假设池子不变、期间没有人死亡、z_max 没撞上限，
 * 接下来几次 Director 生成会按什么顺序出池（复刻 PopQueuedSI + IsClassOverLimit 的逐刀过滤）。
 * 只操作本地副本，不碰 g_SpawnsArray / 任何插件状态。
 */
void PoolReplySimulation(int client, const int alive[SI_MAX_SIZE], int domAlive)
{
	int total = g_SpawnsArray.Length;
	if (total == 0)
		return;

	ArrayList simPool = new ArrayList();
	for (int i = 0; i < total; ++i)
		simPool.Push(g_SpawnsArray.Get(i));

	int sim[SI_MAX_SIZE];
	for (int i = 0; i < SI_MAX_SIZE; ++i)
		sim[i] = alive[i];

	int simDom = domAlive;

	char seq[160];
	seq[0] = '\0';

	int simCount = 0;
	while (simCount < POOL_DUMP_MAX_SIM && simPool.Length > 0)
	{
		int picked = -1;

		for (int i = 0; i < simPool.Length; ++i)
		{
			int SI = simPool.Get(i);

			if (SI < SI_GENERIC_BEGIN || SI >= SI_GENERIC_END)
			{
				simPool.Erase(i);
				--i;
				continue;
			}

			int live = g_cvSILimits[SI] != null ? g_cvSILimits[SI].IntValue : -1;

			if (live >= 0 && sim[SI] >= live) // = OverLimit_Class
				continue;

			if (IsDominator(SI) && simDom >= 3) // = OverLimit_Dominator
				continue;

			picked = i;
			break;
		}

		if (picked < 0)
			break;

		int SI = simPool.Get(picked);
		simPool.Erase(picked);

		++sim[SI];
		if (IsDominator(SI))
			++simDom;

		char item[32];
		FormatEx(item, sizeof(item), "%s%s", simCount > 0 ? " > " : "", L4D2_InfectedNames[SI]);
		StrCat(seq, sizeof(seq), item);
		++simCount;
	}

	delete simPool;

	if (simCount > 0)
		PoolReply(client, "simulated next %d spawn(s) (无人死亡前提下): %s", simCount, seq);
	else
		PoolReply(client, "simulated next: NONE -> 每个池元素都会被过滤，生成会被 Plugin_Handled 挡掉");
}
