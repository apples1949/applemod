// 1.11.0 合并记录（接入 LuxLuma/Left-4-fix 的两个引擎内联补丁）：
//  1) 把上游 witch_target_patch 1.4 与 witch_prevent_target_loss 1.1.1 的补丁逻辑
//     并进本插件，产出一个插件 + 一份 gamedata（gamedata/witch_target_override.txt，
//     left4dead2 段同时给 Windows / Linux）。
//  2) witch_target_patch 的那 4 个点（GetVictim / OnStart / OnAnimationEvent / Update）
//     改的是"引擎在哪儿取她的受害者"：WitchAttack 把受害者同时存在两处 ——
//     +0x34 的 CBaseHandle（带序列号，SetVictim() 写入）和 +0x38 的幸存者角色号；
//     原版 GetVictim 在角色号 != 8 时走 CTerrorPlayer::GetPlayerByCharacter(角色号)，
//     12v12 里同一角色会有好几个玩家 ⇒ 返回的是"第一个该角色的玩家"，也就是错的人。
//     补丁把那处条件跳转改成"永远走句柄分支"，取回的就是她真正记着的实体。
//  3) witch_prevent_target_loss 的 2 个点（OnMoveToFailure 里的两个跳转）让寻路失败
//     不再上报（不再返回 "Attacker out of reach" / "Attack path failed while we're on fire"），
//     女巫不会因为一次走不过去就放弃目标。
//  4) 两个补丁组各用一个 ConVar 控制（_engine_patch / _prevent_loss），改 ConVar 即时
//     应用或还原；OnPluginEnd 把每个补丁点写回原始字节。
//  5) 与既有逻辑的关系（详见 私人文件/docs/witch_target_override_合并评估.md）：
//     - 引擎补丁只改"读目标"的路径，不改"写目标"的路径；本插件的目标接力靠一记
//       0 伤害 DMG_BURN 让引擎自己调用 SetVictim() 写 +0x34/+0x38 ⇒ 换目标照旧生效，
//       而且换完之后取回来的一定是那个玩家本体（不再被角色号查到别人身上）。
//     - OnMoveToFailure 补丁让引擎不再主动丢目标，和 keep_aggro 的"接力"是同一方向的
//       两层保险，不互相抵消；但引擎自己给不出"放弃"之后，追不到的人会一直被追，
//       这是它唯一的代价（见文档"默认值取舍"）。
//
// 1.10.1 修复记录（玩家反馈"女巫身上出现燃烧效果"）：
//  1) 根因：换目标用的是"对女巫本身发一记 0 伤害 DMG_BURN"来骗引擎把 target 记成攻击者，
//     而引擎不看伤害值、只看伤害类型 —— 这一记假命中会真的把她点燃（m_bIsBurning=1、
//     FL_ONFIRE 置位、并生成 entityflame 挂到 m_hEffectEntity），于是她带着火光到处跑。
//  2) 原来的清理只在"下一帧"做（一次性 ThinkPost + KillEntNextFrame），而引擎的火苗实体
//     常常比那一帧还晚建出来 ⇒ 清不到，火光一直留着。现在：
//       - 假命中发完 **同一帧内** 立刻 ClearWitchFire（灭火 + 清 m_bIsBurning/FL_ONFIRE + 删火苗实体）；
//       - 之后 FAKE_BURN_CLEAR_TIME(0.25s) 窗口内由 ThinkWitch 每帧兜底再清一次，
//         晚建出来的火苗也能被收掉；人手点的火不在窗口内，不会被误灭。
//  3) 顺带修掉一个隐藏冲突：原来用 SDKHook(ThinkPost, PostThink) 做那条一次性清理，
//     而 ThinkPost 同一实体只能挂一个回调 ⇒ 它把 ThinkWitch（跟随 + 目标接力）顶掉了，
//     之后这只女巫就再也不接力。现在 ThinkPost 只挂 ThinkWitch，清理走上面的窗口。
//  4) 假命中会把她切到"着火"动作序列，现在清完火会把原来的 m_nSequence 还原（原本没着火时）。
//
// 1.10.0 修复记录：
//  1) 目标接力（本版本核心）：原来只有 player_incapacitated / player_death 两个事件会换目标，
//     而"主动跟随"这条线一旦被以下任意一件事打断就永久失效 —— 被生还者打中、受惊
//     (witch_harasser_set)、硬直/燃烧动作序列 —— 之后就只剩引擎 AI。引擎在目标倒地/死亡后
//     会让女巫进入"无仇恨"状态，她就站起来走开（玩家反馈的"击倒两人后丢仇恨跑路"）。
//     现在：ThinkPost 对每只女巫无条件常驻，每帧检查"她恨的那个人"是否还是可追目标
//     （在游戏内、活着、生还者、没倒/没挂边），不是就立刻换下一个站着的生还者。
//  2) 本插件自己发的那记 0 伤害 DMG_BURN 会同步触发 witch_harasser_set，原来会把
//     bWitchScared 置真 ⇒ 每次换目标都顺手把跟随/接力一起关掉。现在用 g_bFakeBurnHit 挡住。
//  3) 同一记假伤害也会走 OnTakeDamageWitchPost 的"被生还者打中就停跟随"分支，同样用
//     g_bFakeBurnHit 挡住（原来那个判断在假伤害之后才做，等于每次换目标都自杀一次跟随）。
//  4) 新增 witch_target_override_skip_incapped（默认 1）：换目标时跳过倒地/挂边的生还者，
//     12v12 倒地仍算存活，不跳过的话女巫会围着倒地的人转，不去追站着的人。
//  5) 主动跟随还剩一层：看不见人（Enemy == 0）但仍有有效仇恨目标时，朝那个目标继续走，
//     不再原地不动等引擎把她带回"坐下/走开"。
//  6) 新增 witch_target_override_keep_aggro / _retarget_delay 控制目标接力的开关与冷却。
//
//Harry @ 2021~2022
//原作者: xZk, BHaType, HarryPotter
//
// 1.9.0 (apples1949) 修复记录：
//   1) 换目标时那记 0 伤害 DMG_BURN 假命中会被自己的 OnTakeDamageAlivePost 当成"真的着火"，
//      从而建一个 z_witch_burn_time 计时器，到点用 point_hurt 99999 把女巫打死。
//      现在用 g_bFakeBurnHit[] 标记自己发的那一记，只有真实燃烧伤害才会建计时器。
//   2) witch_target_override_recalculate_burn_time 语义反了（默认 0 反而建计时器、设 1 却在
//      女巫刷新时删计时器）。现在改为：0=保持原定燃烧死亡时间（不动计时器）；
//      1=换目标时把燃烧时间重新计一遍。
//   3) 跟随用的 TeleportEntity 原来只算水平方向、没有任何射线/贴地检查，会把女巫推进墙里、
//      推进地板或让她悬空。现在先做 hull 射线，被挡住就转向，并用向下射线贴地。
//   4) 燃烧计时器回调在 entref 失效时没有清句柄，槽位永久失效。现在用 DataPack 一起带
//      实体号+entref，回调里无条件清槽位。
//   5) m_iHealth < 0 的存活判断改成 <= 0（0 血即死）。
//   6) GetRage() 原来按值传参，调用方的 m_rage/m_wanderrage 永远是 0，导致 "m_rage == 1.0"
//      这条永远为假。现在改成单返回值，删掉死条件。
//   7) 跟随几率 GetRandomInt(0,100) 的边界修正；并且 damage 钩子不再受几率控制
//      （原来没中签的 return 会把后面 SDKHook 一起跳过，导致那类女巫既不能换目标也没有燃烧计时）。
//   8) OnEntityCreated 里原来有 g_bConfigLoaded 门控，配置执行前刷出的女巫/特感不会被标记成
//      "不参与视线检测"，那段时间 TraceFilter 会把它们当遮挡物 → 女巫"看不见人"。
//      现在去掉门控，并在 OnConfigsExecuted 补扫一次已存在的实体。
//   9) "被生还者打中就停止主动跟随"原来借用 EnemyTime>0 做标志，现在拆成显式 bWitchFollowing[]
//      （行为不变，只是意图可读）。
//  10) IsValidEntityIndex 改成显式 && 并加上 MAXENTITY 上限，ResetTimer 循环上限也 clamp。
//  11) TraceFilter 原来把 entity 0（世界/刷子几何体）也排除掉了 ⇒ 视线检测形同虚设（隔墙也算
//      看得见）。现在世界几何体会正常遮挡视线。

#pragma semicolon 1
#pragma newdecls required
#define PLUGIN_VERSION "1.11.0"
// 1.11.0：引擎内联补丁用的 gamedata（addons/sourcemod/gamedata/witch_target_override.txt）
#define WITCH_ENGINE_GAMEDATA "witch_target_override"
// 补丁点编号（顺序只是为了数组下标，含义见下方 g_sEnginePatchName）
enum
{
	WITCH_PATCH_GETVICTIM = 0,
	WITCH_PATCH_ONSTART,
	WITCH_PATCH_ONANIMATIONEVENT,
	WITCH_PATCH_UPDATE,
	WITCH_PATCH_MOVE_FAILURE_1,
	WITCH_PATCH_MOVE_FAILURE_2,
	WITCH_PATCH_MAX
}
// 1.10.1：假命中后持续灭火的时长（秒）。引擎的火苗实体经常晚一两帧才建出来，
// 只清一帧会漏 —— 这里留一个短窗口，由 ThinkWitch 每帧兜（见 ClearWitchFire）。
#define FAKE_BURN_CLEAR_TIME 0.25
#define DEBUG 0

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#define L4D_TEAM_SPECTATOR		1
#define L4D_TEAM_SURVIVORS 		2
#define L4D_TEAM_INFECTED 		3
#define Pai 3.14159265358979323846 
#define MAXENTITY 2048

public Plugin myinfo = 
{
	name = "Witch Target Override",
	author = "apples1949",
	description = "Change target when the witch incapacitates or kills victim + witchs auto follow survivors (原作者 xZk, BHaType, HarryPotter)",
	version = PLUGIN_VERSION,
	url = "https://steamcommunity.com/profiles/76561198026784913/"
};

bool L4D2Version;
int anim_ducking, anim_walk;
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) 
{
	EngineVersion test = GetEngineVersion();
	
	if( test == Engine_Left4Dead )
	{
		L4D2Version = false;
		anim_ducking = 2;
		anim_walk=6; 
	}
	else if( test == Engine_Left4Dead2 )
	{
		L4D2Version = true;
		anim_ducking = 4; 
		anim_walk=10; 
	}
	else
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 1 & 2.");
		return APLRes_SilentFailure;
	}
	
	return APLRes_Success; 
}

ConVar g_hCvarAllow, g_hCvarIncapOverride, g_hCvarKillOverride,
    g_hCvarIncapOverrideHealth, g_hCvarKillOverrideHealth, g_hRequiredRange, g_hCvarReCalculateBurnOverride,
    g_hWitchChanceFollowsurvivor, g_hWitchFollowRange, g_hWitchFollowSpeed;
ConVar z_witch_burn_time;
int g_iCvarIncapOverrideHealth, g_iCvarKillOverrideHealth, g_iWitchChanceFollowsurvivor;
bool g_bCvarAllow, g_bCvarIncapOverride, g_bCvarKillOverride, g_bCvarReCalculateBurnOverride;
float g_fRequiredRange, g_fWitchFollowRange, g_fWitchFollowSpeed;
float witch_burn_time;

// 1.10.0 新增 ConVar：目标接力（不丢仇恨）
ConVar g_hCvarKeepAggro, g_hCvarSkipIncapped, g_hCvarRetargetDelay;
bool g_bKeepAggro, g_bSkipIncapped;
float g_fRetargetDelay;

// 1.11.0 新增 ConVar：引擎内联补丁（合并自 LuxLuma/Left-4-fix 的
// witch_target_patch 1.4 与 witch_prevent_target_loss 1.1.1）
ConVar g_hCvarEnginePatch, g_hCvarPreventLoss;

// 1.11.0：引擎补丁运行时状态。每个补丁点保存"原始 2 字节"，OnPluginEnd 逐字节写回。
Handle  g_hEngineGamedata = null;
Address g_aPatchAddr[WITCH_PATCH_MAX];
int     g_iPatchOffset[WITCH_PATCH_MAX];
int     g_iPatchOrig[WITCH_PATCH_MAX][2];
bool    g_bPatchApplied[WITCH_PATCH_MAX];
bool    g_bEnginePatchReady;   // gamedata 已载入并解析过

int Enemy[MAXENTITY+1];
float ActionTime[MAXENTITY+1], EnemyTime[MAXENTITY+1], StuckTime[MAXENTITY+1], PauseTime[MAXENTITY+1], LastTime[MAXENTITY+1], 
    TargetDir[MAXENTITY+1][3], LastPos[MAXENTITY+1][3], LastSetPos[MAXENTITY+1][3];
bool bWitchScared[MAXENTITY+1], bWitchSit[MAXENTITY+1], bWitchFollowing[MAXENTITY+1];
Handle BurnWitchTimer[MAXENTITY+1] = {null};
bool ge_bInvalidTrace[MAXENTITY+1];
bool g_bFakeBurnHit[MAXENTITY+1];   // 本插件自己发出去的那一记 0 伤害 DMG_BURN，不算真着火
// 1.10.1 新增：假命中"灭火窗口"。引擎会把这一记 0 伤害 DMG_BURN 当成真的点燃
// （m_bIsBurning=1 / FL_ONFIRE / 生成 entityflame 挂到 m_hEffectEntity），
// 所以发完之后在这个时间点之前，每帧都要确认她没被点着（见 ClearWitchFire / ThinkWitch）。
float g_fFakeBurnClearAt[MAXENTITY+1];
// 1.10.0 新增状态：目标接力（不丢仇恨）
int   g_iAggroTarget[MAXENTITY+1];     // 当前"她恨谁"（witch_harasser_set / 本插件换目标时维护）
float g_fRetargetAt[MAXENTITY+1];      // 下次允许补换目标/补换仇恨的引擎时间（冷却，防同帧重复）
bool  g_bFollowAllowed[MAXENTITY+1];   // 这只女巫是否允许"主动跟随"（witch_spawn 时按几率决定）

float  g_fVPlayerMins[3] = {-16.0, -16.0,  0.0};
float  g_fVPlayerMaxs[3] = { 16.0,  16.0, 71.0};
static bool   g_bTracesMarked;

public void OnPluginStart()
{
	g_hCvarAllow = CreateConVar("witch_target_override_on", "1", "1=插件启用 0=插件禁用", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hCvarIncapOverride = CreateConVar("witch_target_override_incap", "1", "如果为1，则目标玩家倒地之后继续追杀其他生还者", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hCvarKillOverride = CreateConVar("witch_target_override_kill", "0", "如果为1，则目标玩家死亡之后继续追杀其他生还者", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hCvarIncapOverrideHealth = CreateConVar("witch_target_override_incap_health_add", "0", " 如果女巫在目标玩家倒地之后继续追杀其他生还者，增加数值血量. (0=关闭)", FCVAR_NOTIFY, true, 0.0, true, 9999.0);
	g_hCvarKillOverrideHealth = CreateConVar("witch_target_override_kill_health_add", "0", "如果女巫在目标玩家死亡之后继续追杀其他生还者，增加数值血量. (0=关闭)", FCVAR_NOTIFY, true, 0.0, true, 9999.0);
	g_hRequiredRange = CreateConVar("witch_target_override_range", "9999", "女巫准备追杀的另外一名生还者并须在这个范围之内 [1.0, 9999.0] (如果范围内没有生还者, 那女巫继续游戏预设行为)", FCVAR_NOTIFY, true, 1.0, true, 9999.0);
	g_hCvarReCalculateBurnOverride = CreateConVar("witch_target_override_recalculate_burn_time", "0", "如果为1，当女巫身上着火并且准备转移目标之时，重新计算女巫烧伤的时间 (0=官方预设模式下女巫会在着火固定时间后死亡)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hWitchChanceFollowsurvivor = CreateConVar("witch_target_override_chance_followsurvivor", "100", "女巫会跟踪生还者的几率", FCVAR_NOTIFY, true, 0.0, true, 100.0);
	g_hWitchFollowRange = CreateConVar("witch_target_override_followsurvivor_range", "500.0", "生还者距离女巫的一定可见范围内，女巫会跟踪生还者 [100.0, 9999.0] ", FCVAR_NOTIFY, true, 100.0, true, 9999.0);
	g_hWitchFollowSpeed = CreateConVar("witch_target_override_followsurvivor_speed", "55.0", "女巫的跟踪速度", FCVAR_NOTIFY, true, 1.0);

	// 目标接力：目标倒地/死亡/挂边后立刻换下一个站着的生还者，避免引擎把她放回"无仇恨"状态后自己走开
	g_hCvarKeepAggro = CreateConVar("witch_target_override_keep_aggro", "1", "1=女巫目标失效(倒地/死亡/挂边/掉线)时立刻换下一个站着的生还者, 0=只在目标倒地(incap)事件里换", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hCvarSkipIncapped = CreateConVar("witch_target_override_skip_incapped", "1", "1=换目标时跳过已倒地/挂边的生还者(12v12 倒地仍算存活, 不跳过会围着倒地的人转), 0=允许把倒地者当目标(旧行为)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hCvarRetargetDelay = CreateConVar("witch_target_override_retarget_delay", "0.6", "两次换目标之间的最小间隔(秒), 防止同一帧重复补伤害 [0.1, 5.0]", FCVAR_NOTIFY, true, 0.1, true, 5.0);

	// 1.11.0 新增：引擎内联补丁（合并自 LuxLuma/Left-4-fix 的 witch_target_patch 1.4
	// 与 witch_prevent_target_loss 1.1.1）。默认两个都开：本插件存在的意义就是"让女巫咬住
	// 正确的那个人"，这两个引擎补丁修的是同一件事的引擎侧根因。
	// 关掉任何一个都会即时把对应补丁点的原始字节写回去，不需要换图或重启。
	g_hCvarEnginePatch = CreateConVar("witch_target_override_engine_patch", "1", "1=打引擎补丁: 女巫取目标时永远用她自己记着的实体句柄(修同角色多人时锁定错人), 0=不打并还原原始字节", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hCvarPreventLoss = CreateConVar("witch_target_override_prevent_loss", "1", "1=打引擎补丁: 女巫寻路失败时不再上报失败(不会因为走不过去就丢目标), 0=不打并还原原始字节", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	z_witch_burn_time = FindConVar("z_witch_burn_time");

	GetCvars();
	g_hCvarAllow.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarIncapOverride.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarKillOverride.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarIncapOverrideHealth.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarKillOverrideHealth.AddChangeHook(ConVarChanged_Cvars);
	g_hRequiredRange.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarReCalculateBurnOverride.AddChangeHook(ConVarChanged_Cvars);
	g_hWitchChanceFollowsurvivor.AddChangeHook(ConVarChanged_Cvars);
	g_hWitchFollowRange.AddChangeHook(ConVarChanged_Cvars);
	g_hWitchFollowSpeed.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarKeepAggro.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarSkipIncapped.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarRetargetDelay.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarEnginePatch.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarPreventLoss.AddChangeHook(ConVarChanged_Cvars);
	z_witch_burn_time.AddChangeHook(ConVarChanged_Cvars);


	// 1.11.0：引擎内联补丁。先解析 gamedata（拿地址+offset），再按 ConVar 决定打不打。
	// 任何一步失败都只记录日志并降级（插件其余功能照常），不会 SetFailState 崩服。
	LoadEngineGamedata();
	ApplyEnginePatches();

	#if DEBUG
		RegConsoleCmd("sm_test", sm_insult);
	#endif

	HookEvent("player_incapacitated", Player_Incapacitated);
	HookEvent("player_death", Player_Death);
	HookEvent("witch_spawn", witch_spawn);
	HookEvent("witch_harasser_set", WitchHarasserSet_Event);
	HookEvent("round_end",			Event_RoundEnd,		EventHookMode_PostNoCopy); //對抗模式下會觸發兩次 (第一次人類滅團之時 第二次隊伍換邊之時)
	HookEvent("map_transition", Event_RoundEnd,		EventHookMode_PostNoCopy); //戰役模式下過關到下一關的時候 (沒有觸發round_end)
	HookEvent("mission_lost", Event_RoundEnd,		EventHookMode_PostNoCopy); //戰役模式下滅團重來該關卡的時候 (之後有觸發round_end)
	HookEvent("finale_vehicle_leaving", Event_RoundEnd,	EventHookMode_PostNoCopy); //救援載具離開之時  (沒有觸發round_end)

	//Autoconfig for plugin
	//AutoExecConfig(true, "witch_target_override");
}

public void OnPluginEnd()
{
	// 1.11.0：卸载前先把引擎补丁点的原始字节写回去（顺序在别的清理之前，
	// 免得下面的清理回调里再碰到被补丁改过的引擎代码）。
	RestoreEnginePatches();
	ResetTimer();

	if (g_hEngineGamedata != null)
	{
		delete g_hEngineGamedata;
		g_hEngineGamedata = null;
	}
}

public void OnMapEnd()
{
	ResetTimer();
	ResetWitchStates();
	g_bTracesMarked = false;
}

public void OnConfigsExecuted()
{
	// 插件晚加载、或配置执行前就已经刷出来的实体不会走 OnEntityCreated，这里补扫一次
	MarkExistingTraceEntities();
}

public void ConVarChanged_Cvars(ConVar convar, const char[] oldValue, const char[] newValue)
{
	GetCvars();

	// 1.11.0：只有这两个开关变化才需要碰引擎字节（ApplyEnginePatches 本身也是幂等的），
	// 其它 ConVar（含别的插件会改的 z_witch_burn_time）变化时不去重复写补丁点。
	if (convar == g_hCvarEnginePatch || convar == g_hCvarPreventLoss)
	{
		ApplyEnginePatches();
	}
}

void GetCvars()
{
	g_bCvarAllow = g_hCvarAllow.BoolValue;
	g_bCvarIncapOverride = g_hCvarIncapOverride.BoolValue;
	g_bCvarKillOverride = g_hCvarKillOverride.BoolValue;
	g_iCvarIncapOverrideHealth = g_hCvarIncapOverrideHealth.IntValue;
	g_iCvarKillOverrideHealth = g_hCvarKillOverrideHealth.IntValue;
	g_fRequiredRange = g_hRequiredRange.FloatValue;
	g_bCvarReCalculateBurnOverride = g_hCvarReCalculateBurnOverride.BoolValue;
	g_iWitchChanceFollowsurvivor = g_hWitchChanceFollowsurvivor.IntValue;
	g_fWitchFollowRange = g_hWitchFollowRange.FloatValue;
	g_fWitchFollowSpeed = g_hWitchFollowSpeed.FloatValue;
	g_bKeepAggro = g_hCvarKeepAggro.BoolValue;
	g_bSkipIncapped = g_hCvarSkipIncapped.BoolValue;
	g_fRetargetDelay = g_hCvarRetargetDelay.FloatValue;
	witch_burn_time = z_witch_burn_time.FloatValue;
}

public Action sm_insult ( int client, int args )
{
    if(client == 0 || g_bCvarAllow == false) return Plugin_Handled;

    int target = GetClientAimTarget(client);
    
    if ( target == -1 )
        return Plugin_Handled;

    int witch = -1;
    while ( (witch = FindEntityByClassname(witch, "witch")) && IsValidEntity(witch) )
    {
        WitchAttackTarget(witch, target, 0);
    }

    return Plugin_Handled;
}

public void Player_Incapacitated(Event event, const char[] event_name, bool dontBroadcast)
{
    if(g_bCvarAllow == false || g_bCvarIncapOverride == false) return;

    int victim = GetClientOfUserId(event.GetInt("userid"));
    int entity = event.GetInt("attackerentid");
    if (IsWitch(entity) && victim > 0 && victim <= MaxClients && IsSurvivor(victim))
    {
        int target = GetNearestSurvivorDist(entity);
        if(target == 0) return;

        WitchAttackTarget(entity, target, g_iCvarIncapOverrideHealth);
    }
}

public void Player_Death(Event event, const char[] event_name, bool dontBroadcast)
{
    if(g_bCvarAllow == false || g_bCvarKillOverride == false ) return;

    int victim = GetClientOfUserId(event.GetInt("userid"));
    int entity = event.GetInt("attackerentid");
    if (IsWitch(entity) && victim > 0 && victim <= MaxClients && IsSurvivor(victim))
    {
        int target = GetNearestSurvivorDist(entity);
        if(target == 0) return;

        WitchAttackTarget(entity, target, g_iCvarKillOverrideHealth);
    }
}

void WitchAttackTarget(int witch, int target, int addHealth)
{
	if (!IsWitch(witch)) return;
	if (target <= 0 || target > MaxClients) return;
	if (GetEntProp(witch, Prop_Data, "m_iHealth") <= 0) return;   // 0 血 = 已死，不要再动

	// 1.10.0：记录"她此刻恨谁" + 换目标冷却。
	// 目标接力（WitchKeepAggro）靠这两个值判断要不要补换，有了冷却就不会在
	// 同一帧里被事件回调与 Think 各换一次。
	g_iAggroTarget[witch] = target;
	g_fRetargetAt[witch] = GetEngineTime() + g_fRetargetDelay;

	#if DEBUG
		PrintToChatAll("witch attacking new target %N, her max health: %d, now health: %d", target, GetEntProp(witch, Prop_Data, "m_iMaxHealth"), GetEntProp(witch, Prop_Data, "m_iHealth"));
	#endif

	if(addHealth > 0)
	{
		SetEntProp(witch, Prop_Data, "m_iHealth", GetEntProp(witch, Prop_Data, "m_iHealth") + addHealth);
	}

	// 真着火判定：火焰状态标记（引擎给女巫点火时会写 m_bIsBurning）
	bool burning = (GetEntityFlags(witch) & FL_ONFIRE) != 0 || GetEntProp(witch, Prop_Send, "m_bIsBurning") != 0;

	// 假命中会把她切到"着火"动作序列，先记下来，清完火再按需还原
	int anim = GetEntProp(witch, Prop_Send, "m_nSequence");

	// 1.10.0：这一记 0 伤害只是为了骗引擎把 target 认成攻击者（女巫才会改追他），
	// 不是真的燃烧伤害；用标志位挡掉 OnTakeDamageWitchPost 里的"中弹着火"分支
	g_bFakeBurnHit[witch] = true;
	SDKHooks_TakeDamage(witch, target, target, 0.0, DMG_BURN);
	g_bFakeBurnHit[witch] = false;

	if (!IsWitch(witch)) return;   // 这一记万一把她打没了，后面的写入就别做了

	// 1.10.1（核心修复）：上面那一记假命中会被引擎当成"被点燃"——
	// m_bIsBurning 置 1、FL_ONFIRE 置位、并生成一个 entityflame 挂在 m_hEffectEntity 上，
	// 于是女巫身上出现"燃烧效果"。原来只在下一帧（KillEntNextFrame / 一次性 ThinkPost）里清，
	// 而引擎的火苗实体往往比那一帧还晚建出来 ⇒ 清不到，火光一直留着。
	// 现在：发完假命中立刻灭火，并开一个 FAKE_BURN_CLEAR_TIME 的窗口让 ThinkWitch 每帧兜底。
	ClearWitchFire(witch);
	g_fFakeBurnClearAt[witch] = GetEngineTime() + FAKE_BURN_CLEAR_TIME;

	if(burning)
	{
		// recalculate_burn_time = 1：换目标时把烧伤时间重新计一遍（0 = 保持原定死亡时间）
		if (g_bCvarReCalculateBurnOverride)
		{
			delete BurnWitchTimer[witch];
			BurnWitchTimer[witch] = null;
			if (witch_burn_time > 0.0)
			{
				BurnWitchTimer[witch] = CreateTimer(witch_burn_time, BurnWitchDead_Timer, MakeBurnTimerData(witch), TIMER_DATA_HNDL_CLOSE);
			}
		}
	}
	else
	{
		// 原本没着火：把假命中顶掉的走路/站立动作序列还原回来
		SetEntProp(witch, Prop_Send, "m_nSequence", anim);
	}
}

// 1.10.1：清掉女巫身上"被点燃"的全部痕迹。
//   - ExtinguishEntity 灭火（引擎侧去掉燃烧状态与火苗）；
//   - m_bIsBurning / FL_ONFIRE 兜底清零（netprop 与 flags 两条路都可能残留）；
//   - m_hEffectEntity 上挂的 entityflame 实体真正删掉 —— 这一步必须走 KillEntNextFrame
//     （延迟到下一帧删，队列内去重），不能在实体回调中途当帧 delete。
// 所有写入前都重新校验实体，女巫随时可能被这一记伤害打死。
void ClearWitchFire(int witch)
{
	if (witch <= MaxClients || !IsValidEntity(witch)) return;
	if (!IsWitch(witch)) return;

	bool bWasBurning = (GetEntityFlags(witch) & FL_ONFIRE) != 0 || GetEntProp(witch, Prop_Send, "m_bIsBurning") != 0;

	ExtinguishEntity(witch);

	if (GetEntProp(witch, Prop_Send, "m_bIsBurning") != 0)
		SetEntProp(witch, Prop_Send, "m_bIsBurning", 0);

	int flags = GetEntityFlags(witch);
	if (flags & FL_ONFIRE)
		SetEntityFlags(witch, flags & ~FL_ONFIRE);

	// 火苗实体：只删 entityflame（引擎点火时建的就是这个类）。
	// 别把别的插件挂在 m_hEffectEntity 上的特效一起删了 —— 例外是"她确实在着火"，
	// 那种情况挂着的特效就是火，直接删。
	int flame = GetEntPropEnt(witch, Prop_Send, "m_hEffectEntity");
	if (flame > 0 && IsValidEntity(flame))
	{
		if (bWasBurning || IsFlameEntity(flame))
			KillEntNextFrame(flame);
	}
}

// 1.10.1：是不是引擎的火焰特效实体（CBaseEntity 点火时建的就是 entityflame）
bool IsFlameEntity(int entity)
{
	if (entity <= 0 || !IsValidEntity(entity)) return false;

	char sClass[32];
	GetEdictClassname(entity, sClass, sizeof(sClass));

	return strcmp(sClass, "entityflame", false) == 0;
}

int GetNearestSurvivorDist(int entity)
{
    int target = 0, IncapTarget= 0;
    float s_fRequiredRange = Pow (g_fRequiredRange, 2.0);
    float Origin[3], TOrigin[3], distance = 0.0;
    float fMinDistance = 0.0, fMinIncapDistance = 0.0;
    GetEntPropVector(entity, Prop_Send, "m_vecOrigin", Origin);
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsSurvivor(i) && IsPlayerAlive(i))
        {
            GetEntPropVector(i, Prop_Send, "m_vecOrigin", TOrigin);
            distance = GetVectorDistance(Origin, TOrigin, true);
            if (s_fRequiredRange >= distance)
            {
                if(IsPlayerIncapOrHanging(i))
                {
                    // 1.10.0：默认跳过倒地/挂边的人。12v12 倒地仍算存活，不跳过的话
                    // 女巫会一直围着倒地的人转（或把倒地者当新目标反复爪），
                    // 而不是去追还站着的那个人。
                    if (g_bSkipIncapped) continue;

                    if (fMinIncapDistance == 0.0 || fMinIncapDistance > distance)
                    {
                        fMinIncapDistance = distance;
                        IncapTarget = i;
                    } 
                }
                else
                {
                    if (fMinDistance == 0.0 || fMinDistance > distance)
                    {
                        fMinDistance = distance;
                        target = i;
                    } 
                }
            }
        }
    }

    if(target == 0) return IncapTarget;

    return target;
}

// 1.10.0：这个生还者还能不能当她"当前要追的人"。
// 只认站着、活着、在游戏内的生还者——倒地/挂边的交给引擎处理，不重复当目标。
bool IsValidChaseTarget(int client)
{
	if (client <= 0 || client > MaxClients) return false;
	if (!IsClientInGame(client)) return false;
	if (GetClientTeam(client) != L4D_TEAM_SURVIVORS) return false;
	if (!IsPlayerAlive(client)) return false;
	if (g_bSkipIncapped && IsPlayerIncapOrHanging(client)) return false;

	return true;
}

bool IsSurvivor(int client)
{
	if (IsClientInGame(client) && GetClientTeam(client) == L4D_TEAM_SURVIVORS)
	{
		return true;
	}
	return false;   
}


bool IsPlayerIncapOrHanging(int client)
{
	if (GetEntProp(client, Prop_Send, "m_isIncapacitated")) 
		return true;
	if (GetEntProp(client, Prop_Send, "m_isHangingFromLedge") || GetEntProp(client, Prop_Send, "m_isFallingFromLedge"))
		return true;

	return false;
}


public void WitchHarasserSet_Event(Event event, const char[] name, bool dontBroadcast)
{
	int witchid = event.GetInt("witchid");
	if (witchid <= MaxClients || !IsValidEntityIndex(witchid)) return;

	// 1.10.0：记下"她此刻恨谁"，目标接力要用这个值判断当前目标还有没有效
	int harasser = GetClientOfUserId(event.GetInt("userid"));
	if (IsSurvivor(harasser)) g_iAggroTarget[witchid] = harasser;

	// 本插件为了换目标发的那记 0 伤害 DMG_BURN 会同步触发这个事件（引擎在
	// SetHarasser 里抛事件），不能把它当"生还者惊动了女巫"——否则每次换目标都会
	// 顺手把主动跟随一起关掉，女巫换完目标就不动了。
	if (g_bFakeBurnHit[witchid]) return;

	bWitchScared[witchid] = true;
}

//witch follows survivor
public void witch_spawn(Event event, const char[] event_name, bool dontBroadcast)
{
	if(g_bCvarAllow == false) return;

	int witchid = event.GetInt("witchid");
	if (witchid <= MaxClients || !IsValidEntityIndex(witchid)) return;

	bWitchScared[witchid] = false;
	bWitchSit[witchid] = false;
	bWitchFollowing[witchid] = false;
	g_bFakeBurnHit[witchid] = false;
	g_fFakeBurnClearAt[witchid] = 0.0;   // 1.10.1：新刷出的女巫不该继承上一只的灭火窗口
	ResetWitchAggro(witchid);   // 实体号会被复用：仇恨目标/冷却/跟随许可都要重新开始

	// 实体号可能被复用：新刷出的女巫不该继承上一个实体的燃烧计时器
	delete BurnWitchTimer[witchid];
	BurnWitchTimer[witchid] = null;

	// 跟随是否生效由几率决定；但 damage 钩子必须无条件挂上（换目标 / 燃烧计时都靠它）。
	// 而且等实体就绪后再挂 —— witch_spawn 事件这一刻实体不一定已经完全建好。
	bool bFollow = (GetRandomInt(1, 100) <= g_iWitchChanceFollowsurvivor);

	DataPack dp = CreateDataPack();
	WritePackCell(dp, EntIndexToEntRef(witchid));
	WritePackCell(dp, bFollow ? 1 : 0);
	CreateTimer(0.5, DelayHookWitch, dp, TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);
}

public Action DelayHookWitch(Handle timer, DataPack dp)
{
	ResetPack(dp);
	int ref = ReadPackCell(dp);
	bool bFollow = ReadPackCell(dp) != 0;

	int witch = EntRefToEntIndex(ref);
	if (witch == INVALID_ENT_REFERENCE || !IsWitch(witch)) return Plugin_Continue;

	SDKHook(witch, SDKHook_OnTakeDamageAlivePost, OnTakeDamageWitchPost);

	// 1.10.0：目标接力(不丢仇恨)必须对每只女巫都成立，所以 ThinkPost 无条件常驻；
	// "主动跟随"只是 ThinkWitch 里的一个子模式，由 bWitchFollowing 单独开关。
	// （原来只有抽中"跟随"几率的女巫才挂 ThinkPost，抽不中的女巫一旦丢了目标就没人管了）
	SDKHook(witch, SDKHook_ThinkPost, ThinkWitch);
	ResetWitchAggro(witch);

	// NOTE: ResetWitchAggro() 会把 g_bFollowAllowed 清成 false，所以赋值必须在它之后
	g_bFollowAllowed[witch] = (bFollow && g_bCvarAllow);

	if (g_bFollowAllowed[witch]) StartHookWitch(witch);

	return Plugin_Continue;
}

public void OnEntityCreated(int entity, const char[] classname)
{
    if (!IsValidEntityIndex(entity))
        return;

    // 不再受 g_bConfigLoaded 门控：配置执行前刷出的女巫/特感同样要参与视线过滤，
    // 否则那段时间 TraceFilter 会把它们当遮挡物（女巫"看不见人"）。
    switch (classname[0])
    {
        case 't', 'i', 'w':
        {
            if (IsTraceInvalidClass(classname))
                ge_bInvalidTrace[entity] = true;
        }
    }
}

static bool IsTraceInvalidClass(const char[] classname)
{
    return StrEqual(classname, "infected", false)
        || StrEqual(classname, "witch", false)
        || StrEqual(classname, "tank_rock", false);
}

void MarkExistingTraceEntities()
{
    // 配置执行（含插件晚加载）时补扫一次地图上已存在的实体
    if (g_bTracesMarked) return;
    g_bTracesMarked = true;

    int maxents = GetMaxEntities();
    if (maxents > MAXENTITY) maxents = MAXENTITY;

    char classname[16];
    for (int entity = MaxClients + 1; entity <= maxents; entity++)
    {
        if (!IsValidEntity(entity)) continue;
        GetEdictClassname(entity, classname, sizeof(classname));
        if (IsTraceInvalidClass(classname))
            ge_bInvalidTrace[entity] = true;
    }
}


public void OnEntityDestroyed(int entity)
{
	if (!IsValidEntityIndex(entity))
		return;

	SDKUnhook(entity, SDKHook_ThinkPost, ThinkWitch);   // 1.10.0：ThinkPost 现在常驻，销毁时必须显式解掉
	StopHookWitch(entity);
	bWitchScared[entity] = false;
	bWitchSit[entity] = false;
	bWitchFollowing[entity] = false;
	g_bFakeBurnHit[entity] = false;
	g_fFakeBurnClearAt[entity] = 0.0;   // 1.10.1：清掉灭火窗口，实体号复用时不继承
	ResetWitchAggro(entity);
	delete BurnWitchTimer[entity];
	BurnWitchTimer[entity] = null;   // delete 之后槽位里仍残留旧句柄值，必须显式清掉

	ge_bInvalidTrace[entity] = false;
}

public void StartHookWitch(int witch)
{
	StopHookWitch(witch);

	EnemyTime[witch] = GetEngineTime(); 
	Enemy[witch] = 0; 
	LastTime[witch] = GetEngineTime()-0.01;
	StuckTime[witch] = 0.0;
	PauseTime[witch] = 0.0; 
	ActionTime[witch] = 0.0;
	
	GetEntPropVector(witch, Prop_Send, "m_vecOrigin", LastPos[witch]);
	SetVector(TargetDir[witch], GetRandomFloat(-1.0, 1.0), GetRandomFloat(-1.0, 1.0), 0.0);
	SetVector(LastSetPos[witch], 0.0, 0.0, 0.0);
	NormalizeVector(TargetDir[witch], TargetDir[witch]); 
	SDKHook(witch, SDKHook_ThinkPost, ThinkWitch);
	bWitchFollowing[witch] = true;

	if(GetEntProp(witch, Prop_Send, "m_nSequence") == anim_ducking)
	{
		#if DEBUG
			PrintToChatAll("witch %d is sitting", witch);
		#endif
		bWitchSit[witch] = true;
	}
}

public void StopHookWitch(int witch)
{
    // 1.10.0：这里不再 Unhook ThinkPost。目标接力（WitchKeepAggro）必须一直跑，
    // 否则"被生还者打中 / 受惊 / 硬直"之后她丢了目标也没人补，就回到引擎的
    // "无仇恨 -> 站起来走开"（玩家反馈的跑路）。现在只关闭"主动跟随"这一层，
    // 把搬运权交回引擎，但仇恨接力继续。
    DeleteWitch(witch);
}

public void DeleteWitch(int witch)
{
    bWitchFollowing[witch] = false;
    Enemy[witch] = 0;
    EnemyTime[witch] = 0.0;
    LastTime[witch] = 0.0;
    StuckTime[witch] = 0.0;
    PauseTime[witch] = 0.0;
    ActionTime[witch] = 0.0;
    LastPos[witch][0] = LastPos[witch][1] = LastPos[witch][2] = 0.0;
    TargetDir[witch][0] = TargetDir[witch][1] = TargetDir[witch][2] = 0.0;
    LastSetPos[witch][0] = LastSetPos[witch][1] = LastSetPos[witch][2] = 0.0;
}

//---------------------------------------------------------------------------------
// 1.10.0：目标接力（不丢仇恨 / 不跑路）
//
// 现象：女巫把目标击倒或击杀之后，引擎会让 harasser 失效、m_rage 慢慢归零，随后她自己
//       站起来走开（玩家反馈的"击倒两人后掉仇恨跑路"）。
// 原因：
//   1) 原来只有 player_incapacitated / player_death 两个事件会换目标，而且必须先满足
//      "攻击者是女巫"；目标以别的方式消失（掉线、挂边、被别的特感顶掉、事件没打中）
//      就没人补；
//   2) "主动跟随"这条线一旦被 受惊(witch_harasser_set) / 被生还者打中 / 硬直动作序列
//      打断就永久失效，第二次击倒之后她已经完全交给引擎，而引擎此刻没有可用的目标。
// 做法：ThinkPost 对每只女巫常驻，每帧检查"她恨的那个人"是否还是可追目标
//      （在游戏内 / 活着 / 生还者 / 没倒地没挂边），不是就立刻换成本回合最近的站着的人。
// 换目标仍然走插件原有的机制：对他做一记 0 伤害 DMG_BURN，骗引擎把 harasser 认成他。
// 证据：DT_Witch 的 netprop 里没有可写的 target 字段（只有 m_rage / m_wanderrage /
//       m_mobRush / m_bIsBurning / m_nSequence 等），Left4DHooks 也没有 witch target
//       native，所以"骗引擎换 harasser"是当前唯一可用的路线，本插件原本就是这么做的。

void ResetWitchAggro(int witch)
{
    g_iAggroTarget[witch] = 0;
    g_fRetargetAt[witch] = 0.0;
    g_bFollowAllowed[witch] = false;
}

// 引擎是否正在自己驱动她（激怒 / 硬直 / 扑击动作）：这种时刻不要插手搬运
bool WitchIsEngineAggro(int witch)
{
    if(GetRage(witch) > 0.5) return true;

    int seq = GetEntProp(witch, Prop_Send, "m_nSequence");
    if(L4D2Version)
    {
        // 39: no target burn, 44 ~ 51: stumble
        if(seq == 39 || (44 <= seq && seq <= 51)) return true;
    }
    else
    {
        if(seq == 31 || (36 <= seq && seq <= 39)) return true;
    }

    return false;
}

// 目标失效的原因决定能不能接力：倒地看 incap 开关、死亡看 kill 开关、
// 掉线/换边/换图不算失效（直接接力）。这样两个既有 ConVar 的语义不会被破坏。
bool AllowRetargetFor(int old)
{
    if (old <= 0 || old > MaxClients) return true;
    if (!IsClientInGame(old)) return true;
    if (GetClientTeam(old) != L4D_TEAM_SURVIVORS) return true;
    if (!IsPlayerAlive(old)) return g_bCvarKillOverride;
    if (IsPlayerIncapOrHanging(old)) return g_bCvarIncapOverride;

    return true;
}

void WitchKeepAggro(int witch, float time)
{
    if(!g_bCvarAllow || !g_bKeepAggro) return;
    if(time < g_fRetargetAt[witch]) return;

    // 只在"已经被惹上"之后才接力。
    // g_iAggroTarget 只会被 witch_harasser_set（生还者成为她的 harasser）和本插件的换目标
    // 写入，从没被惹过的女巫这里是 0 —— 不能把她叫起来从地图另一头追人。
    int old = g_iAggroTarget[witch];
    if(old == 0) return;

    // 她现在恨的人还能追 -> 不打扰，引擎自己会带她过去
    if(IsValidChaseTarget(old)) return;

    // 旧目标倒地/死亡时，是否继续追由原来的 incap / kill 开关决定
    if(!AllowRetargetFor(old)) return;

    int next = GetNearestSurvivorDist(witch);
    if(next == 0) return;   // 没有站着的生还者了（全倒地 / 全灭）-> 交回引擎，别硬追

    // 先上冷却：即使下面 WitchAttackTarget 因为条件不满足提前 return，
    // 也不会变成每帧重试。
    g_fRetargetAt[witch] = time + g_fRetargetDelay;

    #if DEBUG
        PrintToChatAll("witch %d keep aggro: %d -> %N", witch, old, next);
    #endif

    WitchAttackTarget(witch, next, 0);

    // 主动跟随被"受惊 / 中弹 / 硬直"打断过的话，在安全时机重新接上，
    // 免得她换完目标还是站着不动（引擎正处在激怒/硬直动作时不要插手）。
    if(g_bFollowAllowed[witch] && !bWitchFollowing[witch] && !bWitchScared[witch] && !WitchIsEngineAggro(witch))
    {
        StartHookWitch(witch);
    }
}

public Action ThinkWitch(int witch)
{
	float time = GetEngineTime();
	float duration = time-LastTime[witch];
	if(duration>0.1) duration = 0.1;
	LastTime[witch] = time;

	// 1.10.1：假命中的灭火窗口。引擎可能在我们清完之后的下一两帧才把火苗实体建出来，
	// 所以这里在窗口期内每帧都再确认一次（人手点的火不在窗口内，不会被误灭）。
	if (g_fFakeBurnClearAt[witch] > 0.0)
	{
		if (time >= g_fFakeBurnClearAt[witch])
		{
			g_fFakeBurnClearAt[witch] = 0.0;
		}
		else if (!IsWitch(witch))
		{
			g_fFakeBurnClearAt[witch] = 0.0;
		}
		else if ((GetEntityFlags(witch) & FL_ONFIRE) != 0 || GetEntProp(witch, Prop_Send, "m_bIsBurning") != 0)
		{
			ClearWitchFire(witch);
		}
		else
		{
			// 没着火标记也再确认一次火苗实体（引擎偶尔只建实体不写标记）。
			// 只删 entityflame，别的特效不碰。
			int iFlame = GetEntPropEnt(witch, Prop_Send, "m_hEffectEntity");
			if (iFlame > 0 && IsFlameEntity(iFlame))
				KillEntNextFrame(iFlame);
		}
	}

	// 1.10.0：不管"主动跟随"还在不在，每帧都先跑目标接力。
	// 这是"击倒两人后不丢仇恨、不跑路"的关键：目标一失效就换下一个站着的人，
	// 让引擎始终有 harasser 可用，不会退回"无仇恨 -> 站起来走开"。
	WitchKeepAggro(witch, time);

	if(!bWitchFollowing[witch])
		return Plugin_Continue;

	if(bWitchScared[witch])
	{
		bWitchFollowing[witch] = false;
		return Plugin_Continue;
	}
	
	if(time-ActionTime[witch]>5.0)
	{	
		ActionTime[witch] = time;
	}

	int m_nSequence = GetEntProp(witch, Prop_Send, "m_nSequence");
	int m_mobRush = GetEntProp(witch, Prop_Send, "m_mobRush");

	int flag = GetEntProp(witch, Prop_Send, "m_fFlags");
	bool onground = !(GetEntPropEnt(witch, Prop_Data, "m_hGroundEntity") == -1);
	
	float witchAngle[3]; 
	float witchPos[3];
	GetEntPropVector(witch, Prop_Send, "m_angRotation", witchAngle);
 	GetEntPropVector(witch, Prop_Send, "m_vecOrigin", witchPos);	
	CopyVector(witchPos, LastPos[witch]);
	int m_hOwnerEntity = GetEntProp(witch, Prop_Send, "m_hOwnerEntity"); 
	#if DEBUG
		PrintToChatAll("witch m_nSequence: %d, m_mobRush: %d", m_nSequence, m_mobRush);
	#endif
	if(L4D2Version)
	{
		// 39: no target burn, 44 ~ 51: stumble 
		if( m_nSequence == 39 || ( 44 <= m_nSequence && m_nSequence <= 51) )
		{		
			// 1.10.0：只停"主动跟随"这一层，ThinkPost 留着继续跑目标接力
			bWitchFollowing[witch] = false;
			return Plugin_Continue;
		}
	}
	else
	{
		if( m_nSequence == 31 || ( 36 <= m_nSequence && m_nSequence <= 39) )
		{		
			// 1.10.0：只停"主动跟随"这一层，ThinkPost 留着继续跑目标接力
			bWitchFollowing[witch] = false;
			return Plugin_Continue;
		}
	}

	float rage = GetRage(witch);
	#if DEBUG
		PrintToChatAll("rage: %.2f", rage);
	#endif
	if(rage > 0.5)
	{
		StuckTime[witch] = 0.0;
		return Plugin_Continue;
	}
	
	if( !onground || m_hOwnerEntity > 0 || m_mobRush == 1 )
	{		
		StuckTime[witch] = 0.0;
		return Plugin_Continue;
	}

	float up[3];  
 
	float newWitchPos[3];
	float newWitchAngle[3]; 
	 
	float moveDir[3]; 
	
	float temp[3]; 
	float temp2[3];
	
	SetVector(up, 0.0, 0.0, 1.0); 
 
	float targetPos[3];
	if(time-EnemyTime[witch] > 1.0)
	{	
		Enemy[witch] = FindNextEnemy(witchPos);
		EnemyTime[witch] = time;  
	} 
	PauseTime[witch] -= duration; 
	Enemy[witch] = FreshEnemy(Enemy[witch], targetPos);

	// 1.10.0：看不见人（Enemy == 0）时，退回"无视线要求"的仇恨目标继续朝他走。
	// 原来是直接返回/坐下，等于把人交给引擎 AI；引擎在目标丢失后会让她站在原地，
	// 然后慢慢走开（跑路）。这里保证只要还有站着的仇人，她就一直在往那边磨。
	if(Enemy[witch] == 0 && g_bKeepAggro && IsValidChaseTarget(g_iAggroTarget[witch]))
	{
		Enemy[witch] = g_iAggroTarget[witch];
		GetClientAbsOrigin(Enemy[witch], targetPos);
	}
	if(Enemy[witch] > 0)
	{ 
		#if DEBUG
			PrintToChatAll("%d witch enemy %d", witch, Enemy[witch]);
		#endif	
		if(PauseTime[witch] <= 0.0)
		{
			SubtractVectors(targetPos, witchPos, TargetDir[witch]);
			TargetDir[witch][2] = 0.0;
			NormalizeVector(TargetDir[witch], TargetDir[witch]);
		}
	}
	else
	{
		if(L4D2Version && !bWitchSit[witch]) return Plugin_Continue;

		int newFlag = flag | FL_DUCKING; 
		
		SetEntProp(witch, Prop_Send, "m_fFlags",newFlag);
		if(m_nSequence != anim_ducking)
		{
			SetEntProp(witch, Prop_Send, "m_nSequence" , anim_ducking); 
			SetEntPropFloat(witch, Prop_Send, "m_flPlaybackRate" ,1.0); 
		}

		return Plugin_Continue;
	}

	StuckTime[witch] += duration; 
	if(StuckTime[witch]>0.5)
	{
		StuckTime[witch] = 0.0;
		CopyVector(witchPos, temp);
		CopyVector(LastSetPos[witch], temp2);
		CopyVector(witchPos, LastSetPos[witch] );
		temp2[2] = temp[2] = 0.0;  
		float a = GetVectorDistance(temp2, temp, true); 
		if(a< 10.0 * 10.0)
		{ 
			RotateVector(up, TargetDir[witch], GetRandomFloat(50.0, 310.0)*Pai/180.0, TargetDir[witch]);
			
			TargetDir[witch][2] = 0.0;
			NormalizeVector(TargetDir[witch],TargetDir[witch]); 
			PauseTime[witch] = 2.0;
		}
	} 

	int newFlag = flag & ~FL_DUCKING; 

	CopyVector(TargetDir[witch],moveDir);	 	
	
	GetVectorAngles(moveDir,newWitchAngle);
	newWitchAngle[0] = 0.0;
	
	CopyVector(moveDir,temp);
	ScaleVector(temp, g_fWitchFollowSpeed*duration);
	AddVectors(witchPos,temp,newWitchPos);

	// 搬运前先确认这一步走得到：hull 射线防穿墙 + 向下射线贴地。
	// 原来直接 TeleportEntity 会把女巫推进墙/地板里，或者让她悬空。
	if (!ComputeSafeWitchPos(witch, witchPos, newWitchPos))
	{
		// 前方走不通：立刻换个方向，别贴着墙磨到永远
		RotateVector(up, TargetDir[witch], GetRandomFloat(50.0, 310.0)*Pai/180.0, TargetDir[witch]);
		TargetDir[witch][2] = 0.0;
		NormalizeVector(TargetDir[witch], TargetDir[witch]);
		PauseTime[witch] = 1.0;
		StuckTime[witch] = 0.0;
		return Plugin_Continue;
	}

	TeleportEntity(witch, newWitchPos, newWitchAngle,  NULL_VECTOR);
	SetEntProp(witch, Prop_Send, "m_fFlags",newFlag);
	 
	if(m_nSequence != anim_walk)
	{
		SetEntProp(witch, Prop_Send, "m_nSequence" , anim_walk); 
		SetEntPropFloat(witch, Prop_Send, "m_flPlaybackRate" ,1.0); 
	}

	return Plugin_Continue;
}

int FreshEnemy(int enemy, float enemyPos[3] )
{
	if(g_fRequiredRange == 0.0) return 0; 

	if(enemy> 0 && IsClientInGame(enemy) && IsPlayerAlive(enemy) && GetClientTeam(enemy) == L4D_TEAM_SURVIVORS)
	{ 
		GetClientAbsOrigin(enemy, enemyPos);  
	}
	else enemy = 0;
	return enemy;
}

int FindNextEnemy(float witchPos[3] )
{ 
	float s_fRequiredRange = Pow(g_fWitchFollowRange, 2.0);
 		 
	float minDis = 0.0, dislength, distanceHeight;
	int selectedPlayer = 0;
	float playerPos[3];
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i) && GetClientTeam(i) == L4D_TEAM_SURVIVORS && IsPlayerAlive(i) )
		{
			GetClientEyePosition(i, playerPos);

			distanceHeight = (witchPos[2] - playerPos[2]);
			if(Absolute(distanceHeight) > 500) continue;
			if(IsVisibleTo(witchPos, playerPos, i) == false) continue;

			dislength = GetVectorDistance(playerPos, witchPos, true);  
			if( dislength <= s_fRequiredRange && (dislength <= minDis || minDis == 0.0) )
			{
				selectedPlayer = i ;
				minDis = dislength;	
			}
		}
	} 
 
	return selectedPlayer;	 
}

void CopyVector(float source[3], float target[3])
{
	target[0] = source[0];
	target[1] = source[1];
	target[2] = source[2];
}

void SetVector(float target[3], float x, float y, float z)
{
	target[0] = x;
	target[1] = y;
	target[2] = z;
}

// 计算这一步的安全落点：
//   1) 水平方向做 hull 射线，被墙/道具挡住就返回 false（这一步不走，调用方转向）
//   2) 起点与终点各贴一次地，用两者的地面高差修正 z
//      （不直接把 z 设成地面高度 —— 女巫 origin 到底在脚底还是身体中心由模型决定，
//        用"相对地面高度"平移才不会被抬高或埋进地里）
bool ComputeSafeWitchPos(int witch, const float from[3], float to[3])
{
	float hullMins[3] = {-13.0, -13.0,  8.0};   // 底部抬高 8：小台阶/缓坡不算阻挡
	float hullMaxs[3] = { 13.0,  13.0, 72.0};
	float flatPos[3];

	Handle trace = TR_TraceHullFilterEx(from, to, hullMins, hullMaxs, MASK_PLAYERSOLID, TraceFilter_WitchSelf, witch);
	bool blocked = TR_DidHit(trace);
	TR_GetEndPosition(flatPos, trace);
	delete trace;

	if (blocked) return false;   // 前方有墙/护栏/道具：这一步不走

	float fromGround[3], toGround[3];
	if (!TraceGroundZ(witch, from, fromGround)) return false;   // 现在脚下就没地面（异常）
	if (!TraceGroundZ(witch, flatPos, toGround)) return false;   // 目的地脚下是空的（悬崖/地图外）

	to[0] = flatPos[0];
	to[1] = flatPos[1];
	to[2] = from[2] + (toGround[2] - fromGround[2]);
	return true;
}

// 在 pos 处向下找地面，返回地面高度（hull 底部 = 地面）
bool TraceGroundZ(int witch, const float pos[3], float ground[3])
{
	float hullMins[3] = {-13.0, -13.0,  0.0};
	float hullMaxs[3] = { 13.0,  13.0, 72.0};
	float start[3], end[3];

	start[0] = pos[0]; start[1] = pos[1]; start[2] = pos[2] + 18.0;
	end[0]   = pos[0]; end[1]   = pos[1]; end[2]   = pos[2] - 96.0;

	Handle trace = TR_TraceHullFilterEx(start, end, hullMins, hullMaxs, MASK_PLAYERSOLID, TraceFilter_WitchSelf, witch);
	bool hit = TR_DidHit(trace);
	TR_GetEndPosition(ground, trace);
	delete trace;

	return hit;
}

// 搬运用的射线过滤：忽略女巫自己和玩家，其它（世界几何体/道具/特感小怪）都算阻挡
public bool TraceFilter_WitchSelf(int entity, int contentsMask, int witch)
{
	if (entity == witch)
		return false;

	if (IsValidClientIndex(entity))
		return false;

	return true;
}

// 返回 m_rage 与 m_wanderrage 的最大值
// （原来是按值传参，调用方拿到的 m_rage/m_wanderrage 永远是 0，那条 "m_rage == 1.0" 永远是假）
float GetRage(int witch)
{
	float rage = GetEntPropFloat(witch, Prop_Send, "m_rage");
	float wanderRage = 0.0;
	if(L4D2Version)
	{
		wanderRage = GetEntPropFloat(witch, Prop_Send, "m_wanderrage");
	}

	return (rage > wanderRage) ? rage : wanderRage;
}

bool IsWitch(int entity)
{
	if (entity > MaxClients && IsValidEntity(entity))
	{
		static char classname[16];
		GetEdictClassname(entity, classname, sizeof(classname));
		if (strcmp(classname, "witch", false) == 0)
			return true;
	}
	return false;
}

void RotateVector(float direction[3], float vec[3], float alfa, float result[3])
{
    float v[3];
    CopyVector(vec,v);

    float u[3];
    CopyVector(direction,u);
    NormalizeVector(u,u);

    float uv[3];
    GetVectorCrossProduct(u,v,uv);

    float sinuv[3];
    CopyVector(uv, sinuv);
    ScaleVector(sinuv, Sine(alfa));

    float uuv[3];
    GetVectorCrossProduct(u,uv,uuv);
    ScaleVector(uuv, 2.0*Pow(Sine(alfa*0.5), 2.0));	

    AddVectors(v, sinuv, result);
    AddVectors(result, uuv, result);
}

public void OnTakeDamageWitchPost(int witch, int attacker, int inflictor, float damage, int damagetype)
{
	// 本插件自己发的那记 0 伤害 DMG_BURN 只是为了让引擎把她换成 target 的攻击者，
	// 既不是真的着火（不能拿它建燃烧计时器，否则换完目标 15 秒后她会被自己打死），
	// 也不是"被生还者打中"（不能拿它停跟随，否则每次换目标都会顺手把跟随关掉）。
	// 1.10.0：这个判断必须在下面两个分支之前做。
	if(g_bFakeBurnHit[witch]) return;

	// 被生还者打中 ⇒ 停掉"主动跟随"，把控制权交回引擎 AI
	// （原来是借用 EnemyTime > 0 当"曾跟随"的标志，现在用显式状态位，意图明确）
	// NOTE: 只停"主动跟随"，目标接力(WitchKeepAggro)继续在 ThinkPost 里跑。
	if(bWitchFollowing[witch] && attacker > 0 && attacker <= MaxClients && IsClientInGame(attacker) && GetClientTeam(attacker) == L4D_TEAM_SURVIVORS)
	{
		StopHookWitch(witch);
	}

	if( (damagetype & DMG_BURN) && BurnWitchTimer[witch] == null && witch_burn_time > 0.0 )
	{
		BurnWitchTimer[witch] = CreateTimer(witch_burn_time, BurnWitchDead_Timer, MakeBurnTimerData(witch), TIMER_DATA_HNDL_CLOSE);
	}
}

// 计时器数据同时带上"创建时的实体号"和"entref"：
// 这样回调里不管实体还在不在，都能把对应槽位的句柄清干净
// （原来实体失效时干脆不清，槽位里留着旧句柄，之后 "== null" 永远为假）
DataPack MakeBurnTimerData(int witch)
{
	DataPack dp = CreateDataPack();
	WritePackCell(dp, witch);
	WritePackCell(dp, EntIndexToEntRef(witch));
	return dp;
}

public Action BurnWitchDead_Timer(Handle timer, DataPack dp)
{
	ResetPack(dp);
	int slot = ReadPackCell(dp);
	int ref = ReadPackCell(dp);

	if (slot < 0 || slot > MAXENTITY) return Plugin_Continue;

	BurnWitchTimer[slot] = null;   // 句柄无条件清掉

	// 只有"同一个实体实例"还在时才真的打死她（实体号可能已经被别的实体复用）
	if (ref && witch_burn_time > 0.0 && EntIndexToEntRef(slot) == ref)
	{
		int witch = EntRefToEntIndex(ref);
		if (witch != INVALID_ENT_REFERENCE && IsWitch(witch))
		{
			ForceDamageEntity(-1, 99999, witch);
		}
	}

	return Plugin_Continue;	
}

void ForceDamageEntity(int causer, int damage, int victim)
{
	float victim_origin[3];
	char rupture[32];
	char damage_victim[32];
	IntToString(damage, rupture, sizeof(rupture));
	Format(damage_victim, sizeof(damage_victim), "hurtme%d", victim);
	GetEntPropVector(victim, Prop_Send, "m_vecOrigin", victim_origin);
	int entity = CreateEntityByName("point_hurt");
	DispatchKeyValue(victim, "targetname", damage_victim);
	DispatchKeyValue(entity, "DamageTarget", damage_victim);
	DispatchKeyValue(entity, "Damage", rupture);
	DispatchSpawn(entity);
	TeleportEntity(entity, victim_origin, NULL_VECTOR, NULL_VECTOR);
	AcceptEntityInput(entity, "Hurt", (causer > 0 && causer <= MaxClients) ? causer : -1);
	DispatchKeyValue(entity, "classname", "point_hurt");
	DispatchKeyValue(victim, "targetname", "null");
	KillEntNextFrame(entity);
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast) 
{
	ResetTimer();
}

void ResetTimer()
{
	int maxents = GetMaxEntities();
	if (maxents > MAXENTITY) maxents = MAXENTITY;

	for (int entity = MaxClients + 1; entity <= maxents; entity++)
	{
		delete BurnWitchTimer[entity];
		BurnWitchTimer[entity] = null;   // delete 之后要把槽位清干净，不能只 delete
	}
}

// 换图时同步清状态：实体号会被复用，残留的跟随/静止/视线标记会套到新实体上
void ResetWitchStates()
{
	int maxents = GetMaxEntities();
	if (maxents > MAXENTITY) maxents = MAXENTITY;

	for (int entity = MaxClients + 1; entity <= maxents; entity++)
	{
		// 1.10.0：ThinkPost 现在对每只女巫常驻，不能再靠 bWitchFollowing 判断要不要解
		SDKUnhook(entity, SDKHook_ThinkPost, ThinkWitch);

		bWitchScared[entity] = false;
		bWitchSit[entity] = false;
		bWitchFollowing[entity] = false;
		g_bFakeBurnHit[entity] = false;
		g_fFakeBurnClearAt[entity] = 0.0;   // 1.10.1
		ge_bInvalidTrace[entity] = false;
		ResetWitchAggro(entity);
		Enemy[entity] = 0;
		EnemyTime[entity] = 0.0;
		LastTime[entity] = 0.0;
		StuckTime[entity] = 0.0;
		PauseTime[entity] = 0.0;
		ActionTime[entity] = 0.0;
	}
}

bool IsValidEntityIndex(int entity)
{
    // 显式 && ，并加上 MAXENTITY 上限（数组是按 MAXENTITY+1 开的）
    return entity > MaxClients && entity <= MAXENTITY && entity <= GetMaxEntities();
}

float Absolute(float number)
{
	if (number < 0) return -number;
	return number;
}

bool IsVisibleTo(float fWitchPos[3], float fPlayerPos[3], int player)
{
    float vLookAt[3];
    float vAng[3];

    MakeVectorFromPoints(fWitchPos, fPlayerPos, vLookAt);
    GetVectorAngles(vLookAt, vAng);

    Handle trace = TR_TraceRayFilterEx(fWitchPos, vAng, MASK_PLAYERSOLID, RayType_Infinite, TraceFilter, player);

    bool isVisible;

    if (TR_DidHit(trace))
    {
        isVisible = (TR_GetEntityIndex(trace) == player);

        if (!isVisible)
        {
            fPlayerPos[2] -= 62.0; // results the same as GetClientAbsOrigin

            delete trace;
            trace = TR_TraceHullFilterEx(fWitchPos, fPlayerPos, g_fVPlayerMins, g_fVPlayerMaxs, MASK_PLAYERSOLID, TraceFilter, player);

            if (TR_DidHit(trace))
                isVisible = (TR_GetEntityIndex(trace) == player);
        }
    }

    delete trace;

    return isVisible;
}

public bool TraceFilter(int entity, int contentsMask, int client)
{
    if (entity == client)
        return true;

    // 世界/刷子几何体（entity 0）必须参与遮挡。
    // 原来这里把 0 也一起排掉了，导致 IsVisibleTo 隔墙也会认为"看得见"。
    if (entity == 0)
        return true;

    if (IsValidClientIndex(entity))
        return false;

    if( !IsValidEntityIndex(entity) )
        return false;

    return ge_bInvalidTrace[entity] ? false : true;
}

bool IsValidClientIndex(int client)
{
    return (1 <= client <= MaxClients);
}

// ===========================================================================
//  延迟删除：把删实体推迟到下一帧（RequestFrame），并对同一实体去重。
//  目的：避免在引擎回调/实体遍历中途删实体；同时避免同一帧把同一实体重复入队
//  （引擎 release 版的入队去重被编掉了，重复入队会在 CleanupDeleteList 里二次 delete）。
// ===========================================================================
static int g_iKillPending[64];
static int g_iKillPendingCount;

void KillEntNextFrame(int entity)
{
	if (entity <= 0 || !IsValidEntity(entity))
		return;

	int ref = EntIndexToEntRef(entity);
	for (int i = 0; i < g_iKillPendingCount; i++)
	{
		if (g_iKillPending[i] == ref)
			return;   // 已经在队列里，去重
	}

	if (g_iKillPendingCount >= sizeof(g_iKillPending))
	{
		AcceptEntityInput(entity, "Kill");   // 队列满：退回当帧删，避免漏删
		return;
	}

	g_iKillPending[g_iKillPendingCount++] = ref;
	RequestFrame(Frame_KillEntNextFrame);
}

public void Frame_KillEntNextFrame()
{
	for (int i = 0; i < g_iKillPendingCount; i++)
	{
		int ent = EntRefToEntIndex(g_iKillPending[i]);
		if (ent != INVALID_ENT_REFERENCE && ent > 0 && IsValidEntity(ent))
			AcceptEntityInput(ent, "Kill");
	}
	g_iKillPendingCount = 0;
}
// ===========================================================================
//  1.11.0：引擎内联补丁（合并自 LuxLuma/Left-4-fix 的两个插件）
//
//  为什么改字节而不是 SDKHook / netprop：
//    WitchAttack（DT_Witch 的行为类）把"我恨谁"同时存在两处：
//      +0x34  CBaseHandle           —— SetVictim() 写入，带序列号校验，取回来是**那个实体**
//      +0x38  SurvivorCharacterType —— 0..7 角色号，8 表示"没有"
//    原版 GetVictim()：
//        eax = [this+0x38]
//        cmp eax, 8
//        j(n)e -> 走"角色号模式"：CTerrorPlayer::GetPlayerByCharacter(角色号)
//        ...      走"句柄模式"：校验 +0x34 的 CBaseHandle 序列号后取实体
//    12v12 同一个角色可以有多个玩家，GetPlayerByCharacter 只返回其中第一个 ⇒
//    她锁的对象和该追的人不是同一个（"女巫锁定错人"）。把这一处条件跳转固定成
//    "永远走句柄分支"，取回的就一定是她自己记着的实体。
//    DT_Witch 上没有可写的 target 字段、Left4DHooks 也没有 witch target native，
//    所以这条路是唯一能在引擎层修根因的办法（本插件的 0 伤害换目标也是同一思路：
//    都是让引擎自己去 SetVictim）。
//
//  补丁点（全部来自 gamedata/witch_target_override.txt）：
//    WitchAttack::GetVictim          +6  (win) / +12 (linux)  跳转极性 0x75 / 0x74
//    WitchAttack::OnStart            +76 (win)                0x75
//    WitchAttack::OnAnimationEvent   +17 (win)                0x75
//    WitchAttack::Update             +60 (win)                0x75
//    WitchAttack::OnMoveToFailure_1  +9  (win) / +19 (linux)  0x74
//    WitchAttack::OnMoveToFailure_2  +14 (win) / +24 (linux)  0x75
//    Linux 上 OnStart / OnAnimationEvent / Update 都是 **call** GetVictim（编译器没有
//    内联），只补 GetVictim 一个点即可覆盖，所以这三个点只有 windows offset。
//
//  两条铁律：
//    1) 读原字节 → 校验是不是预期的 0x74/0x75 → 才写；不是就 LogError 跳过
//       （二进制更新过 / 被别的插件改过），绝不盲写。
//    2) 每个点都记住原始 2 字节，OnPluginEnd 或 ConVar 关掉时原样写回。
// ===========================================================================

// 每个补丁点的 gamedata key（既是 Addresses 段的名字，也是 Offsets 段的名字）
// 注意 OnMoveToFailure 的两个点：Addresses 段共用一个 key，Offsets 段分成 _1/_2。
static const char g_sEnginePatchName[WITCH_PATCH_MAX][] =
{
	"WitchAttack::GetVictim",
	"WitchAttack::OnStart",
	"WitchAttack::OnAnimationEvent",
	"WitchAttack::Update",
	"WitchAttack::OnMoveToFailure_1",
	"WitchAttack::OnMoveToFailure_2"
};

// 该点属于哪一组开关：true = _engine_patch（取目标组），false = _prevent_loss（寻路失败组）
static const bool g_bEnginePatchGroup[WITCH_PATCH_MAX] =
{
	true, true, true, true, false, false
};

// 载入 gamedata 并解析出每个补丁点的基址 + offset。
// 任一步失败只 LogError（插件其余功能继续跑），绝不 SetFailState。
void LoadEngineGamedata()
{
	g_bEnginePatchReady = false;

	// 引擎补丁只在 L4D2 上验证过（gamedata 里也只写了 left4dead2 段）
	if (!L4D2Version)
	{
		PrintToServer("[witch_target_override] 引擎补丁仅支持 L4D2，当前为 L4D1，已跳过。");
		return;
	}

	g_hEngineGamedata = LoadGameConfigFile(WITCH_ENGINE_GAMEDATA);
	if (g_hEngineGamedata == null)
	{
		LogError("[witch_target_override] 载入 gamedata \"%s.txt\" 失败，引擎补丁不启用（插件其余功能照常）。", WITCH_ENGINE_GAMEDATA);
		return;
	}

	Address addrs[WITCH_PATCH_MAX];
	int     offs[WITCH_PATCH_MAX];

	// 顺序：先取 offset（哪几个点在这个平台上有），再去取地址。
	// 这样在没有该点的平台上（Linux 的 OnStart/OnAnimationEvent/Update）连签名都不会去查，
	// 不会在日志里留下无意义的 "signature not found"。
	offs[WITCH_PATCH_GETVICTIM]        = GameConfGetOffset(g_hEngineGamedata, "WitchAttack::GetVictim");
	offs[WITCH_PATCH_ONSTART]          = GameConfGetOffset(g_hEngineGamedata, "WitchAttack::OnStart");
	offs[WITCH_PATCH_ONANIMATIONEVENT] = GameConfGetOffset(g_hEngineGamedata, "WitchAttack::OnAnimationEvent");
	offs[WITCH_PATCH_UPDATE]           = GameConfGetOffset(g_hEngineGamedata, "WitchAttack::Update");
	offs[WITCH_PATCH_MOVE_FAILURE_1]   = GameConfGetOffset(g_hEngineGamedata, "WitchAttack::OnMoveToFailure_1");
	offs[WITCH_PATCH_MOVE_FAILURE_2]   = GameConfGetOffset(g_hEngineGamedata, "WitchAttack::OnMoveToFailure_2");

	// OnMoveToFailure 的两个 offset 共用同一个 Addresses 项，只查一次
	Address addrMoveFail = Address_Null;
	if (offs[WITCH_PATCH_MOVE_FAILURE_1] >= 0 || offs[WITCH_PATCH_MOVE_FAILURE_2] >= 0)
		addrMoveFail = GameConfGetAddress(g_hEngineGamedata, "WitchAttack::OnMoveToFailure");

	addrs[WITCH_PATCH_GETVICTIM]        = (offs[WITCH_PATCH_GETVICTIM]        >= 0) ? GameConfGetAddress(g_hEngineGamedata, "WitchAttack::GetVictim")        : Address_Null;
	addrs[WITCH_PATCH_ONSTART]          = (offs[WITCH_PATCH_ONSTART]          >= 0) ? GameConfGetAddress(g_hEngineGamedata, "WitchAttack::OnStart")          : Address_Null;
	addrs[WITCH_PATCH_ONANIMATIONEVENT] = (offs[WITCH_PATCH_ONANIMATIONEVENT] >= 0) ? GameConfGetAddress(g_hEngineGamedata, "WitchAttack::OnAnimationEvent") : Address_Null;
	addrs[WITCH_PATCH_UPDATE]           = (offs[WITCH_PATCH_UPDATE]           >= 0) ? GameConfGetAddress(g_hEngineGamedata, "WitchAttack::Update")           : Address_Null;
	addrs[WITCH_PATCH_MOVE_FAILURE_1]   = addrMoveFail;
	addrs[WITCH_PATCH_MOVE_FAILURE_2]   = addrMoveFail;

	for (int i = 0; i < WITCH_PATCH_MAX; i++)
	{
		g_iPatchOrig[i][0] = -1;
		g_iPatchOrig[i][1] = -1;
		g_bPatchApplied[i] = false;

		g_aPatchAddr[i]   = addrs[i];
		g_iPatchOffset[i] = offs[i];

		// offset 缺项 = 这个平台本来就没有这个补丁点（Linux 的 OnStart/OnAnimationEvent/
		// Update 就是），属正常，静默跳过。
		if (g_iPatchOffset[i] < 0)
		{
			g_aPatchAddr[i]   = Address_Null;
			g_iPatchOffset[i] = -1;
			continue;
		}

		// 有 offset 却没有地址 = 签名没命中当前二进制 → 这才是真的有问题，必须报出来。
		if (g_aPatchAddr[i] == Address_Null)
		{
			LogError("[witch_target_override] 签名 \"%s\" 未命中当前 server 二进制，该补丁点跳过（其余补丁点照常）。",
				g_sEnginePatchName[i]);
			g_iPatchOffset[i] = -1;
		}
	}

	g_bEnginePatchReady = true;
}

// 按 ConVar 决定每个补丁点打不打：开着没打的补上，关着已打的还原。
// 幂等：已在目标状态的点不动，所以任何 ConVar 变化都能安全调用。
void ApplyEnginePatches()
{
	if (!g_bEnginePatchReady)
		return;

	// ConVar 还没建（OnPluginStart 早期）时不动作
	if (g_hCvarEnginePatch == null || g_hCvarPreventLoss == null)
		return;

	bool bWantGetVictimGroup = g_hCvarEnginePatch.BoolValue;
	bool bWantPreventGroup   = g_hCvarPreventLoss.BoolValue;

	for (int i = 0; i < WITCH_PATCH_MAX; i++)
	{
		bool bWant = g_bEnginePatchGroup[i] ? bWantGetVictimGroup : bWantPreventGroup;

		if (bWant)
			PatchOne(i);
		else
			RestoreOne(i);
	}
}

// 还原全部补丁点（卸载时无条件调用，不看 ConVar）
void RestoreEnginePatches()
{
	for (int i = 0; i < WITCH_PATCH_MAX; i++)
		RestoreOne(i);

	g_bEnginePatchReady = false;
}

// 打一个补丁点：读原 2 字节 → 校验极性 → 写。
// 校验不过就 LogError 并留原样，绝不盲写。
void PatchOne(int idx)
{
	if (g_bPatchApplied[idx])
		return;   // 已经打过了

	if (g_aPatchAddr[idx] == Address_Null || g_iPatchOffset[idx] < 0)
		return;   // 该平台/该二进制上没有这个点，静默跳过

	Address patch = g_aPatchAddr[idx] + view_as<Address>(g_iPatchOffset[idx]);

	int b0 = LoadFromAddress(patch, NumberType_Int8);
	int b1 = LoadFromAddress(patch + view_as<Address>(1), NumberType_Int8);

	if (b0 != 0x74 && b0 != 0x75)
	{
		// 不是条件短跳 ⇒ 这个 offset 在当前二进制上已经不对了（游戏更新 / 别的插件
		// 改过这里 / gamedata 与实际版本不匹配）。绝不盲写。
		LogError("[witch_target_override] \"%s\" offset=%d 处原字节为 0x%02X（期望 0x74/0x75），该补丁点跳过，请核对 gamedata。",
			g_sEnginePatchName[idx], g_iPatchOffset[idx], b0);
		return;
	}

	// 留档原始 2 字节（还原时逐字节写回；只改写 1 字节时第二字节原样保留）
	g_iPatchOrig[idx][0] = b0;
	g_iPatchOrig[idx][1] = b1;

	// 改写规则（与上游插件逐字节一致）：
	//  0x74(jz/je)  + rel8  → 0x90 0x90   抹掉这个条件跳（无条件顺序执行）
	//                         或 0xEB      改成无条件短跳（跳到 je 原目标）
	//  0x75(jnz/jne) + rel8 → 0x90 0x90   抹掉这个条件跳
	//                         或 0xEB      改成无条件短跳（保留原 rel8 = 跳原目标）
	switch (idx)
	{
		case WITCH_PATCH_GETVICTIM:
		{
			// Windows 是 jnz -> 角色号模式（0x75），抹掉即永远走句柄分支。
			// Linux 是 jz -> 句柄分支（0x74），改成 EB 即永远跳到句柄分支。
			if (b0 == 0x75)
			{
				StoreToAddress(patch, 0x90, NumberType_Int8);
				StoreToAddress(patch + view_as<Address>(1), 0x90, NumberType_Int8);
			}
			else
			{
				StoreToAddress(patch, 0xEB, NumberType_Int8);   // 第二字节 rel8 保留
			}
		}
		case WITCH_PATCH_ONSTART,
		     WITCH_PATCH_ONANIMATIONEVENT,
		     WITCH_PATCH_UPDATE:
		{
			// 这三个点只有 Windows（Linux 是 call GetVictim），上游只处理 0x75
			if (b0 != 0x75)
			{
				LogError("[witch_target_override] \"%s\" 处跳转极性为 0x%02X（期望 0x75），该补丁点跳过。",
					g_sEnginePatchName[idx], b0);
				g_iPatchOrig[idx][0] = -1;
				return;
			}
			StoreToAddress(patch, 0x90, NumberType_Int8);
			StoreToAddress(patch + view_as<Address>(1), 0x90, NumberType_Int8);
		}
		case WITCH_PATCH_MOVE_FAILURE_1:
		{
			// Windows/Linux 这里都是 0x74(je)：MoveToFailureType==0 时跳到
			// 0x41EB2D / 0xA2D3E0 那条"上报失败"的分支（返回 "Attacker out of reach" /
			// "Attack path failed while we're on fire"）。抹掉它 = type 0 不再上报。
			if (b0 == 0x74)
			{
				StoreToAddress(patch, 0x90, NumberType_Int8);
				StoreToAddress(patch + view_as<Address>(1), 0x90, NumberType_Int8);
			}
			else
			{
				StoreToAddress(patch, 0xEB, NumberType_Int8);   // 第二字节 rel8 保留，跳原目标
			}
		}
		case WITCH_PATCH_MOVE_FAILURE_2:
		{
			// 0x75(jne)：「MoveToFailureType != 2 就跳到 0x41EB0B / 0xA2D3B9」那个
			// 恒返回 {0,0,0,1}（无动作）的出口。改成 EB = 无条件跳过去，于是
			// 任何 type 都不再走失败上报 / type 2 处理，OnMoveToFailure 变成空操作。
			if (b0 != 0x75)
			{
				LogError("[witch_target_override] \"%s\" 处跳转极性为 0x%02X（期望 0x75），该补丁点跳过。",
					g_sEnginePatchName[idx], b0);
				g_iPatchOrig[idx][0] = -1;
				return;
			}
			StoreToAddress(patch, 0xEB, NumberType_Int8);   // 第二字节 rel8 保留，跳原目标
		}
	}

	g_bPatchApplied[idx] = true;
	PrintToServer("[witch_target_override] 引擎补丁已应用 '%s' (offset=%d, 0x%02X 0x%02X -> 已改写)",
		g_sEnginePatchName[idx], g_iPatchOffset[idx], b0, b1);
}

// 还原一个补丁点：把留档的原始 2 字节逐字节写回。
// 只在确实打过补丁且地址仍有效时动作。
void RestoreOne(int idx)
{
	if (!g_bPatchApplied[idx])
		return;

	if (g_aPatchAddr[idx] == Address_Null || g_iPatchOffset[idx] < 0 || g_iPatchOrig[idx][0] < 0)
	{
		g_bPatchApplied[idx] = false;
		return;
	}

	Address patch = g_aPatchAddr[idx] + view_as<Address>(g_iPatchOffset[idx]);
	StoreToAddress(patch, g_iPatchOrig[idx][0], NumberType_Int8);
	StoreToAddress(patch + view_as<Address>(1), g_iPatchOrig[idx][1], NumberType_Int8);

	g_bPatchApplied[idx] = false;
	PrintToServer("[witch_target_override] 引擎补丁已还原 '%s' (offset=%d)", g_sEnginePatchName[idx], g_iPatchOffset[idx]);
}
