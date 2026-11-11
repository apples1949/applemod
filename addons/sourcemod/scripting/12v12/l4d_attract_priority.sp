/*
 *	l4d_attract_priority —— 让「胆汁地面」的吸引力压过「土制炸弹(雷)」
 *
 *	用户需求（原始）：普通感染者被吸引的优先级 雷 > 被胆汁的玩家 > 胆汁，
 *	要改成 胆汁 > 雷 > 被胆汁的玩家。
 *
 *	====================== 能力边界（务必先读） ======================
 *	本插件只实现「胆汁 > 雷」这一层，且**只压制雷**，不改变「被胆汁的玩家」的优先级。
 *	「胆汁 > 被胆汁的玩家」纯 SourceMod **做不到**：那一段在引擎里是
 *	  ChaseVictim::Update -> CDirectorTacticalServices::GetClosestCharacterWhoIsIT
 *	  （Linux server_srv.so VA 0x8B0EF0 / Windows server.dll VA 0x10290150）
 *	由引擎每帧直接调用，没有任何 netprop / input / event 能让它返回 null，
 *	只能在服务器二进制上做 DHooks detour。详见
 *	  `私人文件/逆向报告-胆汁吸引优先级.md` 第 2.2 / 3.3 节。
 *	=================================================================
 *
 *	------------------------ 实现机制与取证 ------------------------
 *	逆向结论（同一份源码，两个平台已交叉验证）：
 *	  1) 雷之所以最高，是因为 ChaseVictim::Update 里有一条硬短路：
 *	         if ( ClassMatchesComplex(enemy, "pipe_bomb*") ) victim = enemy;   // 不再查 IT
 *	     判定点：Linux 0xA1B77B / Windows 0x104129B4；字符串 "pipe_bomb*" 在
 *	     server_srv.so VA 0xD125EE、server.dll 文件偏移 0x6DBAB8。
 *	  2) 胆汁地面（vomitjar 炸开）由 CVomitJarProjectile::ExplodeVomit（Linux 0x569440，
 *	     0x569A56 处引用类名）生成一个 `info_goal_infected_chase`，
 *	     该实体 CInfoGoalInfectedChase::AttractInfectedThink（Linux 0x8C3090）每 0.5 秒
 *	     EmitSound("InfectedChaseGoal.Attract") —— 也就是说胆汁地面**只能靠声音吸引**，
 *	     它从来不是一个可被 chase 的 victim，引擎里没有它的「权重」可调。
 *	  3) 雷同样是靠声音把普通感染者引过去的：CPipeBombProjectile::BeepThink
 *	     （Linux 0x543870）里 EmitSound(this, "PipeBomb.TimerBeep", ...)。
 *
 *	所以本插件的做法是：**在胆汁吸引点存活的时间窗内，只把雷的蜂鸣声掐掉**，
 *	让普通感染者听不到雷、继续跟着胆汁地面的 "InfectedChaseGoal.Attract" 走。
 *	不写任何 netprop、不改任何实体状态、不加任何 detour、不需要 gamedata。
 *	同款思路的现成先例：`l4d2_fireworks_noise_block.sp`（Visor）用同一个
 *	NormalSHook 掐掉烟花声，避免普通感染者被烟花带走。
 *
 *	------------------ 另外两种做法：评估后否决 --------------------
 *	(A) AcceptEntityInput(pipebomb, "Disable")
 *	    → 否决。CPipeBombProjectile 的 datamap（datamap-dump：`CPipeBombProjectile - pipe_bomb_projectile`）
 *	      只有 CBaseGrenade 系列函数表和 m_bIsLive / m_flDetonateTime / m_flWarnAITime /
 *	      m_bHasWarnedAI / m_iszBounceSound / m_hThrower / m_DmgRadius / m_flDamage，
 *	      **没有 InputDisable**，发这个 input 是空操作。
 *	(B) 写 m_bIsLive = 0（netprop，offset 6725，bits 1）
 *	    → 否决。反编译 CPipeBombProjectile::BeepThink 与 Detonate 都不读 m_bIsLive，
 *	      写它既停不住蜂鸣，又可能影响别处对「引信是否有效」的判断，属于无效且有风险。
 *	(C) 写普通感染者的 m_Gender = 13（L4D2Gender_Undistractable / Workman，
 *	    常量表注释写着 "class not reacting to the pipe bomb"）
 *	    → 否决，理由有两条：
 *	      · 反编译 InfectedAlert::OnSound（Linux 0xA095C0）只对 gender 16/17
 *	        （Clown / Jimmy）做特殊处理，**没有 gender==13 的分支**，所以「写 13 就听不见雷」
 *	        在本 build 里找不到落点，写进去很可能什么也不发生（等于假实现）；
 *	      · 反编译 ChaseVictim::Update 里确实有一处 `GetGender(a4) == 17`（Jimmy）
 *	        的副作用（会清 ZombieManager 的 pending mob 标记），说明改 gender 是有连带影响的，
 *	        在没定位到 13 的判定点之前不该乱写。
 *	(D) 改写 pipe_bomb_projectile 的 m_iClassname 让 "pipe_bomb*" 匹配失败
 *	    → 否决。短路只决定「已锁定的敌人要不要保留」；改名后函数会落到
 *	      victim = GetClosestCharacterWhoIsIT()，**失败时仍然回退到 enemy（还是那颗雷）**，
 *	      所以对已经追着雷的普通感染者无效，达不到「胆汁 > 雷」。
 *
 *	----------------------------- 副作用 -----------------------------
 *	· 只拦 "…beep…" 且属于被压制雷的样本；爆炸声不含 beep/pipebomb+timerbeep 关键字，
 *	  不会被误拦（若实机发现爆炸声也被拦，把 debug 打开看 sample 再收窄关键字）。
 *	· 被压制的雷照常计时、照常爆炸、照常造成伤害与尸潮，只是**听不见**。
 *	· NormalSHook 是全局声音钩子，本插件在 g_iMutedCount == 0（绝大多数时间）时
 *	  第一行就返回，不进 StrContains。
 *	· 生效窗口内如果胆汁点离雷超过 l4d_attract_priority_radius，不做任何处理。
 *	· **作用范围有限**：掐声音只能阻止雷「继续/新建」听觉吸引。按逆向结论
 *	  ChaseVictim::Update 每帧都会把「当前 enemy 是 pipe_bomb*」的感染者锁在原目标上，
 *	  所以**在胆汁出现之前就已经锁死雷的那批普通感染者，本插件救不回来**（要救必须
 *	  detour 那条短路）。本插件最有效的场景是：胆汁先落地（或同时），雷随后才扔。
 *	· 地图里 hammer 摆的 info_goal_infected_chase（无父级）也会被当成胆汁点，
 *	  它的窗口从「实体生成」算起（通常是换图瞬间），影响很小；如需彻底排除可改成
 *	  只认 vomitjar 爆炸后 1 秒内生成的目标，等实机确认后再定。
 *
 *	----------------------- 仍需实机验证的项 -----------------------
 *	1. 掐掉 "PipeBomb.TimerBeep" 后，普通感染者是否真的不再转向雷（本插件最大不确定项；
 *	   mode 0 = 只检测不屏蔽，可先用来确认检测面是否正常）。
 *	2. 引擎发给 NormalSHook 的 sample / soundEntry 到底是解析后的 wav 路径还是
 *	   soundscript 名，需要开 debug 看一眼实际字符串，必要时再收窄 IsPipeBombBeep()。
 *	3. 12v12 人数下 NormalSHook 的额外开销（预期可忽略，需实测 tickrate）。
 *
 *	本插件**没有被加入任何 cfg**，也没有被加载；以上全部结论均为静态分析 + 编译验证，
 *	不含实机验证。
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_VERSION "1.0.0"

// 胆汁吸引点：vomitjar 炸开时由 CVomitJarProjectile::ExplodeVomit 生成
#define CLASS_BILE_GOAL     "info_goal_infected_chase"
// 土制炸弹投掷物
#define CLASS_PIPE_PROJ     "pipe_bomb_projectile"
// 父实体（用来把「小丑/Jimmy 身上挂的吸引点」排除掉）
#define ENTPROP_PARENT      "m_pParent"
// 坐标
#define ENTPROP_ORIGIN      "m_vecOrigin"

// L4D2 的 edict 上限
#define MAX_ENTITIES        2048
// 一次扫描最多记多少个生效中的胆汁吸引点
#define MAX_ACTIVE_GOALS    32
// 扫描间隔（秒）
#define SCAN_INTERVAL       0.2

ConVar g_cvEnable;
ConVar g_cvWindow;
ConVar g_cvRadius;
ConVar g_cvMode;
ConVar g_cvDebug;

bool  g_bEnable;
float g_fWindow;
float g_fRadius;
int   g_iMode;   // 0 = 只检测（不屏蔽）；1 = 屏蔽雷蜂鸣
bool  g_bDebug;
bool  g_bLateLoad;

int   g_iMaxEntities;

// 吸引点生成时间（0 = 不是吸引点）
float g_flGoalSpawn[MAX_ENTITIES + 1];
// 当前被压制的雷
bool  g_bMutedBomb[MAX_ENTITIES + 1];
// 上一轮被压制的雷数量（0 时快速返回）
int   g_iMutedCount;

public Plugin myinfo =
{
	name = "l4d_attract_priority",
	author = "apples1949",
	description = "胆汁地面存在时压掉土制炸弹对普通感染者的吸引（实现 胆汁>雷 这一层；胆汁>被胆汁的玩家 需引擎 detour，纯 SourceMod 做不到）",
	version = PLUGIN_VERSION,
	url = "https://github.com/apples1949"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	if (GetEngineVersion() != Engine_Left4Dead2)
	{
		strcopy(error, err_max, "l4d_attract_priority 只支持 Left 4 Dead 2");
		return APLRes_SilentFailure;
	}

	g_bLateLoad = late;

	return APLRes_Success;
}

public void OnPluginStart()
{
	g_cvEnable = CreateConVar("l4d_attract_priority_enable", "1",
		"1=启用；0=完全停用（不检测也不屏蔽）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvWindow = CreateConVar("l4d_attract_priority_bile_window", "12.0",
		"胆汁吸引点生成后，压制土制炸弹的秒数", FCVAR_NOTIFY, true, 1.0, true, 60.0);
	g_cvRadius = CreateConVar("l4d_attract_priority_radius", "800.0",
		"胆汁吸引点的作用半径：这个范围内的土制炸弹才会被压制", FCVAR_NOTIFY, true, 100.0, true, 4000.0);
	g_cvMode = CreateConVar("l4d_attract_priority_mode", "1",
		"0=只检测并在控制台打印（不屏蔽，用来确认检测面）；1=真屏蔽土制炸弹蜂鸣", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvDebug = CreateConVar("l4d_attract_priority_debug", "0",
		"1=在服务器控制台打印检测/屏蔽细节", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvEnable.AddChangeHook(ConVarChanged_Cvars);
	g_cvWindow.AddChangeHook(ConVarChanged_Cvars);
	g_cvRadius.AddChangeHook(ConVarChanged_Cvars);
	g_cvMode.AddChangeHook(ConVarChanged_Cvars);
	g_cvDebug.AddChangeHook(ConVarChanged_Cvars);

	GetCvars();

	g_iMaxEntities = GetMaxEntities();
	if (g_iMaxEntities > MAX_ENTITIES)
	{
		g_iMaxEntities = MAX_ENTITIES;
	}

	// 全局声音钩子：只拦「被压制的那颗雷」发出的蜂鸣
	AddNormalSoundHook(OnNormalSound);

	CreateTimer(SCAN_INTERVAL, Timer_Scan, INVALID_HANDLE, TIMER_REPEAT);

	// 晚加载时把已经在场的胆汁吸引点补登记一遍
	if (g_bLateLoad)
	{
		LateLoadGoals();
	}
}

public void OnMapStart()
{
	ClearAllState();
}

public void OnMapEnd()
{
	ClearAllState();
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (entity < 1 || entity > g_iMaxEntities)
	{
		return;
	}

	if (!StrEqual(classname, CLASS_BILE_GOAL))
	{
		return;
	}

	// OnEntityCreated 阶段 parent 还没挂上，等 SpawnPost 再判
	SDKHook(entity, SDKHook_SpawnPost, OnGoalSpawnPost);
}

public void OnGoalSpawnPost(int entity)
{
	if (entity < 1 || entity > g_iMaxEntities || !IsValidEntity(entity))
	{
		return;
	}

	// 带父级的是 CreateAttractGoal 给小丑(16)/Jimmy(17) 普通感染者挂的那种，
	// 不属于「胆汁地面」，跳过（判定依据：CreateAttractGoal 里会 SetParent(infected, -1)）
	if (GetEntPropEnt(entity, Prop_Data, ENTPROP_PARENT) != -1)
	{
		return;
	}

	g_flGoalSpawn[entity] = GetGameTime();

	if (g_bDebug)
	{
		PrintToServer("[l4d_attract_priority] 登记胆汁吸引点 ent=%d（压制雷 %.1f 秒，半径 %.0f）",
			entity, g_fWindow, g_fRadius);
	}
}

public void OnEntityDestroyed(int entity)
{
	if (entity < 1 || entity > g_iMaxEntities)
	{
		return;
	}

	if (g_flGoalSpawn[entity] > 0.0)
	{
		g_flGoalSpawn[entity] = 0.0;
	}

	if (g_bMutedBomb[entity])
	{
		g_bMutedBomb[entity] = false;
		if (g_iMutedCount > 0)
		{
			g_iMutedCount--;
		}
	}
}

void ConVarChanged_Cvars(ConVar convar, const char[] oldValue, const char[] newValue)
{
	GetCvars();
}

void GetCvars()
{
	g_bEnable = g_cvEnable.BoolValue;
	g_fWindow = g_cvWindow.FloatValue;
	g_fRadius = g_cvRadius.FloatValue;
	g_iMode   = g_cvMode.IntValue;
	g_bDebug  = g_cvDebug.BoolValue;
}

void ClearAllState()
{
	for (int i = 0; i <= MAX_ENTITIES; i++)
	{
		g_flGoalSpawn[i] = 0.0;
		g_bMutedBomb[i] = false;
	}

	g_iMutedCount = 0;
}

void LateLoadGoals()
{
	char classname[64];
	int entity = -1;
	while ((entity = FindEntityByClassname(entity, CLASS_BILE_GOAL)) != -1)
	{
		if (entity < 1 || entity > g_iMaxEntities || !IsValidEntity(entity))
		{
			continue;
		}

		if (GetEntPropEnt(entity, Prop_Data, ENTPROP_PARENT) != -1)
		{
			continue;
		}

		g_flGoalSpawn[entity] = GetGameTime();

		if (g_bDebug)
		{
			GetEntityClassname(entity, classname, sizeof(classname));
			PrintToServer("[l4d_attract_priority] 晚加载补登记吸引点 ent=%d (%s)", entity, classname);
		}
	}
}

public Action Timer_Scan(Handle timer)
{
	if (!g_bEnable)
	{
		ClearMutes();
		return Plugin_Continue;
	}

	float now = GetGameTime();
	float goalPos[3];

	int goals[MAX_ACTIVE_GOALS];
	int nGoals = 0;

	for (int entity = 1; entity <= g_iMaxEntities; entity++)
	{
		if (g_flGoalSpawn[entity] <= 0.0)
		{
			continue;
		}

		if (!IsValidEntity(entity))
		{
			g_flGoalSpawn[entity] = 0.0;
			continue;
		}

		if (now > g_flGoalSpawn[entity] + g_fWindow)
		{
			g_flGoalSpawn[entity] = 0.0;
			continue;
		}

		if (nGoals < MAX_ACTIVE_GOALS)
		{
			goals[nGoals++] = entity;
		}
	}

	if (nGoals == 0)
	{
		ClearMutes();
		return Plugin_Continue;
	}

	// 先把上一轮的压制全部清掉，再按本轮重新标（mode 0 也照样标，只是声音钩子不生效，
	// 这样 debug 能完整看到「本来会压制谁」）
	ClearMutes();

	int bomb = -1;
	while ((bomb = FindEntityByClassname(bomb, CLASS_PIPE_PROJ)) != -1)
	{
		if (bomb < 1 || bomb > g_iMaxEntities || !IsValidEntity(bomb))
		{
			continue;
		}

		float bombPos[3];
		GetEntPropVector(bomb, Prop_Send, ENTPROP_ORIGIN, bombPos);

		for (int g = 0; g < nGoals; g++)
		{
			GetEntPropVector(goals[g], Prop_Send, ENTPROP_ORIGIN, goalPos);

			float dist = GetVectorDistance(bombPos, goalPos, false);
			if (dist > g_fRadius)
			{
				continue;
			}

			g_bMutedBomb[bomb] = true;
			g_iMutedCount++;

			if (g_bDebug)
			{
				PrintToServer("[l4d_attract_priority] 胆汁点 %d 覆盖土制炸弹 %d（距离 %.0f / 半径 %.0f，mode=%d）",
					goals[g], bomb, dist, g_fRadius, g_iMode);
			}

			break;
		}
	}

	return Plugin_Continue;
}

void ClearMutes()
{
	if (g_iMutedCount == 0)
	{
		return;
	}

	for (int entity = 1; entity <= g_iMaxEntities; entity++)
	{
		g_bMutedBomb[entity] = false;
	}

	g_iMutedCount = 0;
}

// 全局普通声音钩子：只处理「被压制的那颗雷」的蜂鸣
public Action OnNormalSound(int clients[MAXPLAYERS], int &numClients, char sample[PLATFORM_MAX_PATH],
	int &entity, int &channel, float &volume, int &level, int &pitch, int &flags,
	char soundEntry[PLATFORM_MAX_PATH], int &seed)
{
	// 绝大多数时间直接返回：没有胆汁点在压制任何雷
	if (g_iMutedCount == 0 || !g_bEnable || g_iMode == 0)
	{
		return Plugin_Continue;
	}

	if (entity < 1 || entity > g_iMaxEntities || !g_bMutedBomb[entity])
	{
		return Plugin_Continue;
	}

	if (!IsPipeBombBeep(sample, soundEntry))
	{
		return Plugin_Continue;
	}

	if (g_bDebug)
	{
		PrintToServer("[l4d_attract_priority] 静音雷蜂鸣 ent=%d sample=\"%s\" entry=\"%s\"",
			entity, sample, soundEntry);
	}

	return Plugin_Stop;
}

// 判定是否土制炸弹的蜂鸣
// 证据：CPipeBombProjectile::BeepThink（Linux server_srv.so VA 0x543870）
//       EmitSound(this, "PipeBomb.TimerBeep", ...)
// 引擎可能把解析后的 wav 路径给 sample、把 soundscript 名给 soundEntry，
// 所以两个都看，并加一条「同时含 pipebomb 与 beep」的宽松兜底。
bool IsPipeBombBeep(const char[] sample, const char[] soundEntry)
{
	if (StrContains(sample, "TimerBeep", false) != -1)
	{
		return true;
	}

	if (StrContains(soundEntry, "TimerBeep", false) != -1)
	{
		return true;
	}

	if (StrContains(sample, "pipebomb", false) != -1 && StrContains(sample, "beep", false) != -1)
	{
		return true;
	}

	if (StrContains(soundEntry, "pipebomb", false) != -1 && StrContains(soundEntry, "beep", false) != -1)
	{
		return true;
	}

	return false;
}
