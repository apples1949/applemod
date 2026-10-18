/**
 * applemod12v12 - 路程分按生还者人数缩放（12 人专属，最小实现）
 *
 * 只做一件事：把本图的「路程分/距离分上限」按实际生还者人数缩放。
 * 不计算、不修改：血量分、医疗包分、药分、投掷物分、坦克分、奖励分。
 * （applemod12v12 明确关闭了 l4d2_applemod_scoremod 的奖励分，本插件不引入。）
 *
 * 公式（与原 4 人制口径对齐）：
 *     目标分数 = max_distance × survivor_limit / base_teamsize
 * 默认 base_teamsize = 4：
 *     max_distance 300、4 人  -> 300        （原口径，1 人满路程 = 75）
 *     max_distance 300、12 人 -> 900        （= 300 * 3）
 *     max_distance 400、12 人 -> 1200
 *
 * 为什么改 vs_max_completion_score：
 *     L4D2 的「团队路程分」= 本图 max completion score × 完成度。
 *     `m_iVersusDistancePerSurvivor` 只有 4 个槽位（引擎硬编码，
 *      见 spechud_appledmod.sp:1534-1542 的 for (i < 4) 累加），
 *     12 人生还者里超出的 8 人推进不会进这个数组，也不会额外加成分数。
 *     所以「人数」这个乘数只能通过 vs_max_completion_score（GameRules 成员）
 *     来做，这也是 l4d2_applemod_scoremod.sp:143 /
 *     confoglcompmod_edi ScoreMod.sp:143-148 的同一个写入点。
 *
 * 与其它插件的交互：
 *     l4d_tank_rush.sp:173-209（12v12 已加载）在坦克在场时会把
 *     vs_max_completion_score 临时置 0（FreezePoints），坦克死后还原。
 *     本插件不逐帧强守：只要读到当前值已经被别人置成 0，就认定是「被有意冻结」，
 *     直接放弃本次写入，绝不与 tank_rush 抢。
 *
 *     spechud_appledmod.sp:379 面板是
 *         iMaxDistance = L4D_GetVersusMaxCompletionScore() / 4 * iSurvivorLimit;
 *     它自己就按 /4*人数 放大了一次。本插件写入缩放后的值以后，
 *     面板会再乘一次（300 图 → 面板显示 2700 而非 900）。
 *     面板要显示 900，应把该行改成直接读 L4D_GetVersusMaxCompletionScore()。
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <left4dhooks>

#undef REQUIRE_PLUGIN
#include <l4d2lib>
#define REQUIRE_PLUGIN

#define PLUGIN_VERSION "1.0.0"

#define DEFAULT_BASE_TEAMSIZE 4
#define MAX_TEAMSIZE          32

// 对外暴露的库名（RegPluginLibrary）。面板靠它区分「本图路程分已按人数缩放」
// 与「引擎原始值」，避免二次放大。改这个名字必须同步改 spechud_appledmod.sp。
#define PLUGIN_LIBRARY "l4d2_applemod_scoremod_12v12"

// 地图载入初期引擎/其它插件仍可能改写 GameRules，
// 因此写完之后在 PATROL_TICKS * PATROL_INTERVAL 秒内持续校验并补写。
#define PATROL_TICKS    12
#define PATROL_INTERVAL 0.5

ConVar g_hEnable;
ConVar g_hBaseTeamSize;
ConVar g_hMapKey;
ConVar g_hDebug;

ConVar g_hSurvivorLimit;
ConVar g_hGameMode;

bool g_bEnabled      = true;
bool g_bDebug        = false;
int  g_iBaseTeamSize = DEFAULT_BASE_TEAMSIZE;
char g_sMapKey[64]   = "max_distance";

bool g_bMapActive;
bool g_bFrameQueued;
bool g_bVerboseOnce;
char g_sMapName[128];

int  g_iEngineBase;             // 首次写入前引擎自带的值（mapinfo 读不到时的回退基准）
bool g_bEngineBaseCaptured;

int  g_iTargetScore;            // 本图目标分数（写入值）
bool g_bApplied;                // 本图是否已至少成功对齐过一次
int  g_iRewriteCount;

Handle g_hPatrol;
int    g_iPatrolTick;


public Plugin myinfo =
{
	name        = "Applemod 12v12 Distance Score",
	author      = "apples1949",
	description = "按生还者人数缩放本图路程分（12 人制），不含任何奖励分逻辑。",
	version     = PLUGIN_VERSION,
	url         = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	if (GetEngineVersion() != Engine_Left4Dead2)
	{
		strcopy(error, err_max, "This plugin only runs in \"Left 4 Dead 2\" game.");
		return APLRes_SilentFailure;
	}
	return APLRes_Success;
}

public void OnPluginStart()
{
	g_hEnable = CreateConVar("applemod12v12_distance_score_enable", "1",
		"1=启用路程分按人数缩放，0=完全不改 vs_max_completion_score（保持引擎默认）。",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_hBaseTeamSize = CreateConVar("applemod12v12_distance_score_base_teamsize", "4",
		"基准人数：该人数下满路程分 = max_distance（原 4 人制口径）。最终分数 = max_distance * survivor_limit / 本值。",
		FCVAR_NOTIFY, true, 1.0, true, float(MAX_TEAMSIZE));

	g_hMapKey = CreateConVar("applemod12v12_distance_score_map_key", "max_distance",
		"从 mapinfo.txt 当前地图段读取路程基准分所用的键名。",
		FCVAR_NOTIFY);

	g_hDebug = CreateConVar("applemod12v12_distance_score_debug", "0",
		"1=把每次写入/校验结果打印到服务端控制台，用于进服排查。",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_hSurvivorLimit = FindConVar("survivor_limit");
	g_hGameMode      = FindConVar("mp_gamemode");

	ReadCvars();

	g_hEnable.AddChangeHook(ConVarChanged);
	g_hBaseTeamSize.AddChangeHook(ConVarChanged);
	g_hMapKey.AddChangeHook(ConVarChanged);
	g_hDebug.AddChangeHook(ConVarChanged);

	if (g_hSurvivorLimit != null)
		g_hSurvivorLimit.AddChangeHook(ConVarChanged);

	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);

	// 暴露库名，供面板（spechud_appledmod.sp）判定「12v12 路程分缩放已生效」。
	// 注意：绝不注册 "l4d2_hybrid_scoremod" / "l4d2_scoremod" 之类的旧库名——
	// 那会让 spechud / scripted hud 去调用本插件并不提供的 SMPlus_* / SMNext_* native。
	RegPluginLibrary(PLUGIN_LIBRARY);

	// 晚加载：地图已经在跑时补一次。
	if (IsMapStarted())
	{
		g_bMapActive = true;
		RequestApply(true);
	}

	if (g_bDebug)
		PrintToServer("[applemod12v12-distance] 已加载（late=%d，survivor_limit=%d）",
			IsMapStarted(), GetSurvivorLimit());
}

public void OnMapStart()
{
	KillPatrol();
	g_bMapActive          = true;
	g_bEngineBaseCaptured = false;
	g_bApplied            = false;
	g_iEngineBase         = 0;
	g_iTargetScore        = 0;
	g_iRewriteCount       = 0;
	GetCurrentMap(g_sMapName, sizeof(g_sMapName));
	RequestApply(false);
}

public void OnMapEnd()
{
	g_bMapActive   = false;
	g_bFrameQueued = false;
	g_hPatrol      = null;   // TIMER_FLAG_NO_MAPCHANGE 会自己收掉
}

// 配置执行（confogl 开赛/换图会多次 exec 配置）。
public void OnConfigsExecuted()
{
	RequestApply(false);
}

// 本插件卸载时故意不做任何「还原」：
//   1) vs_max_completion_score 是 GameRules 成员，每次地图载入由引擎重新初始化，
//      不还原也会在下一张图自动回到引擎值；
//   2) 如果在 OnPluginEnd 写回一个快照值，遇到「快照本身已被别的插件改过」
//      （confoglcompmod_edi ScoreMod.sp:250 的旧坑）会把错误值固化下来。
// 因此这里不实现 OnPluginEnd。


// --------------------------------------------------------------------------
// 驱动
// --------------------------------------------------------------------------

void RequestApply(bool bVerbose)
{
	if (!g_bMapActive || !g_bEnabled)
		return;

	if (bVerbose)
		g_bVerboseOnce = true;

	if (g_bFrameQueued)
		return;
	g_bFrameQueued = true;
	RequestFrame(Frame_Apply);
}

public void Frame_Apply(any data)
{
	g_bFrameQueued = false;

	bool bVerbose = g_bVerboseOnce;
	g_bVerboseOnce = false;

	StartPatrol();

	// 立刻来一次，避免第一帧就白等 0.5 秒。
	TryApplyScore(bVerbose);
}

void StartPatrol()
{
	if (!g_bMapActive || !g_bEnabled || !CanScore())
		return;

	if (g_hPatrol != null)
		return;   // 已经在跑，别重开

	g_iPatrolTick   = 0;
	g_iRewriteCount = 0;
	g_hPatrol = CreateTimer(PATROL_INTERVAL, Timer_Patrol, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void KillPatrol()
{
	if (g_hPatrol != null)
	{
		KillTimer(g_hPatrol);
		g_hPatrol = null;
	}
}

public Action Timer_Patrol(Handle timer)
{
	if (!g_bMapActive || !g_bEnabled || !CanScore())
	{
		g_hPatrol = null;
		return Plugin_Stop;
	}
	g_iPatrolTick++;

	bool bMatched = TryApplyScore(g_iPatrolTick == 1);

	if (g_iPatrolTick >= PATROL_TICKS)
	{
		g_hPatrol = null;

		if (!bMatched)
		{
			// 读回值也要走 map-started 守卫，否则在地图收尾的边界帧上
			// L4D_GetVersusMaxCompletionScore() 会 ThrowNativeError。
			int iNow = IsMapStarted() ? L4D_GetVersusMaxCompletionScore() : -1;

			if (g_iTargetScore <= 0)
			{
				// 连基准都没拿到（GameRules 未初始化 / mapinfo 未载入 /
				// 被 tank_rush 冻结），这不是错误，只是时机没到：
				// 后续 round_start 与 OnConfigsExecuted 还会重新起一轮校验。
				if (g_bDebug)
				{
					PrintToServer("[applemod12v12-distance] 本轮校验未取到基准（当前=%d，map=%s），等下次触发。",
						iNow, g_sMapName);
				}
			}
			else
			{
				LogError("[applemod12v12-distance] 校验结束仍未对齐：当前=%d 目标=%d（map=%s，重写 %d 次）",
					iNow, g_iTargetScore, g_sMapName, g_iRewriteCount);
			}
		}
		else if (g_bDebug)
		{
			PrintToServer("[applemod12v12-distance] 校验完成：%s 路程分=%d（重写 %d 次）",
				g_sMapName, g_iTargetScore, g_iRewriteCount);
		}

		return Plugin_Stop;
	}

	return Plugin_Continue;
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	// 同一张图内回合重开时补一次（不重开长校验，只做一次即时纠正）。
	if (!g_bMapActive)
		g_bMapActive = true;

	if (g_bApplied)
	{
		TryApplyScore(false);
		return;
	}

	RequestApply(false);
}

public void ConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	ReadCvars();
	KillPatrol();
	RequestApply(false);
}


// --------------------------------------------------------------------------
// 核心
// --------------------------------------------------------------------------

/**
 * 算出并写入目标分数。
 * @return 返回时当前值是否已经等于本插件的目标值
 */
bool TryApplyScore(bool bVerbose)
{
	if (!g_bEnabled || !g_bMapActive || !CanScore())
		return false;

	// 必须的双重守卫：Left4DHooks 的 g_bMapStarted 未置位时调用
	// L4D_Get/SetVersusMaxCompletionScore 会 ThrowNativeError。
	if (!IsMapStarted())
		return false;

	if (!IsVersusLikeMode())
	{
		if (bVerbose && g_bDebug)
			PrintToServer("[applemod12v12-distance] 当前不是对抗模式，跳过。");
		return false;
	}

	int iCurrent = L4D_GetVersusMaxCompletionScore();

	// 当前值 <= 0 只有两种可能，任何一种都不该写入：
	//   a) GameRules 还没初始化 —— 先等下一个 tick（返回 false，巡逻继续）；
	//   b) 被别的插件有意冻结 —— 12v12 加载的 l4d_tank_rush.sp:173-209
	//      FreezePoints() 在坦克在场时把本值置 0，UnFreezePoints() 再还原。
	//      写进去会破坏它的冻结/还原逻辑（它还原文保存了自己的旧值）。
	if (iCurrent <= 0)
		return (g_bApplied || g_bEngineBaseCaptured);

	// 记录引擎原值，只作为「mapinfo 读不到」时的回退基准；
	// 必须在任何写入之前捕捉，否则会把自己的写入当成基准反复放大。
	if (!g_bEngineBaseCaptured && iCurrent > 0)
	{
		g_iEngineBase = iCurrent;
		g_bEngineBaseCaptured = true;
	}

	int iMapDistance = 0;

	if (HasNative("L4D2_GetMapValueInt"))
		iMapDistance = L4D2_GetMapValueInt(g_sMapKey, 0);

	if (iMapDistance <= 0)
		iMapDistance = g_iEngineBase;

	// 基准还没就绪（mapinfo 未载入 / GameRules 未初始化），等下一个 tick。
	if (iMapDistance <= 0)
		return false;

	int iTeamSize = GetSurvivorLimit();

	int iTarget = RoundToNearest(float(iMapDistance) * float(iTeamSize) / float(g_iBaseTeamSize));
	if (iTarget < 1)
		iTarget = 1;

	g_iTargetScore = iTarget;

	if (iTarget == iCurrent)
	{
		g_bApplied = true;
		return true;
	}

	// include 的 @remarks 原文：Use this function before changing networked members
	// of GameRules, like with L4D_SetVersusMaxCompletionScore()。所以必须先通知再写。
	if (HasNative("L4D_NotifyNetworkStateChanged"))
		L4D_NotifyNetworkStateChanged();

	L4D_SetVersusMaxCompletionScore(iTarget);

	g_iRewriteCount++;
	g_bApplied = true;

	if (bVerbose || g_bDebug)
	{
		PrintToServer("[applemod12v12-distance] %s: 基准 %d × 人数 %d ÷ 基准人数 %d = %d（原值 %d）",
			g_sMapName, iMapDistance, iTeamSize, g_iBaseTeamSize, iTarget, iCurrent);
	}

	if (!IsMapStarted())
		return false;

	return (L4D_GetVersusMaxCompletionScore() == iTarget);
}

void ReadCvars()
{
	g_bEnabled      = (g_hEnable       == null) ? true  : g_hEnable.BoolValue;
	g_bDebug        = (g_hDebug        == null) ? false : g_hDebug.BoolValue;
	g_iBaseTeamSize = (g_hBaseTeamSize == null) ? DEFAULT_BASE_TEAMSIZE : g_hBaseTeamSize.IntValue;

	if (g_iBaseTeamSize < 1)
		g_iBaseTeamSize = 1;
	if (g_iBaseTeamSize > MAX_TEAMSIZE)
		g_iBaseTeamSize = MAX_TEAMSIZE;

	if (g_hMapKey != null)
	{
		g_hMapKey.GetString(g_sMapKey, sizeof(g_sMapKey));
		if (g_sMapKey[0] == '\0')
			strcopy(g_sMapKey, sizeof(g_sMapKey), "max_distance");
	}
	else
	{
		strcopy(g_sMapKey, sizeof(g_sMapKey), "max_distance");
	}
}

int GetSurvivorLimit()
{
	int iSize = 0;

	if (g_hSurvivorLimit != null)
	{
		iSize = g_hSurvivorLimit.IntValue;
	}
	else
	{
		ConVar hLimit = FindConVar("l4d_survivor_limit");   // l4d_superversus 的别名
		if (hLimit != null)
			iSize = hLimit.IntValue;
	}

	if (iSize < 1)
		iSize = DEFAULT_BASE_TEAMSIZE;
	if (iSize > MAX_TEAMSIZE)
		iSize = MAX_TEAMSIZE;

	return iSize;
}

bool IsVersusLikeMode()
{
	if (HasNative("L4D_IsVersusMode"))
		return L4D_IsVersusMode();

	if (g_hGameMode != null)
	{
		char sMode[32];
		g_hGameMode.GetString(sMode, sizeof(sMode));
		return StrEqual(sMode, "versus", false) || StrEqual(sMode, "mutation12", false);
	}

	return false;
}

bool IsMapStarted()
{
	if (HasNative("L4D_HasMapStarted"))
		return L4D_HasMapStarted();

	return true;   // 没有 Left4DHooks 探测手段时依赖上层 defer
}

bool CanScore()
{
	return HasNative("L4D_GetVersusMaxCompletionScore") && HasNative("L4D_SetVersusMaxCompletionScore");
}

bool HasNative(const char[] sName)
{
	return GetFeatureStatus(FeatureType_Native, sName) == FeatureStatus_Available;
}
