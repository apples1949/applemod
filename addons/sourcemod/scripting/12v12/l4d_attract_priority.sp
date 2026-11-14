/*
 *	l4d_attract_priority —— 让「胆汁地面」的吸引力压过「土制炸弹(雷)」
 *
 *	用户需求（原始）：普通感染者被吸引的优先级 雷 > 被胆汁的玩家 > 胆汁，
 *	要改成 胆汁 > 雷 > 被胆汁的玩家。
 *
 *	====================== 能力边界（务必先读） ======================
 *	1.2.1 起分三层实现，各自可单独开关：
 *	  ① 胆汁 > 雷            —— 默认开（bomb_mode / mode 控制）。
 *	     做法：胆汁吸引点存活窗口内，(a) 掐掉雷的 "PipeBomb.TimerBeep" 蜂鸣，
 *	     (b) 直接改雷的 AI 警告字段 m_bHasWarnedAI / m_flWarnAITime（写法参考
 *	     l4d_pipebomb_shove.sp 改雷数据字段的做法）。雷照常计时/爆炸/造成伤害。
 *	  ② 胆汁 > 被胆汁的玩家 —— 默认开（l4d_attract_priority_bile_it）。
 *	     做法参考 l4d2_si_bile.sp：它用 player_now_it / player_no_longer_it 事件 +
 *	     left4dhooks 的 L4D_OnITExpired 让"被胆汁的特感"立刻结束 IT（不再吸引小僵尸）。
 *	     这里把同一套用在生还者身上，但**只在有地面胆汁时**才清，
 *	     所以是"让位给地面胆汁"，而不是取消胆汁机制。
 *	     **模糊屏幕是另一条通路**：客户端读 m_vomitStart / m_vomitFadeStart
 *	     （netprop-dump offset 16172 / 16176，float）。清 IT 不必然把它抹掉；
 *	     l4d_attract_priority_keep_blur 默认 1 = 清完 IT 后把这两个字段写回原值，
 *	     做到「不再吸引 + 模糊照旧」；设 0 才是 si_bile 那种"连模糊一起清"。
 *	     ⚠ 这是"移除被胆汁者的吸引"，不等于改了引擎的优先级表：引擎里
 *	     ChaseVictim::Update -> CDirectorTacticalServices::GetClosestCharacterWhoIsIT
 *	     （Linux server_srv.so VA 0x8B0EF0 / Windows server.dll VA 0x10290150）
 *	     仍然会返回 IT；我们做的是"让这个 IT 提前失效"。要真正改写优先级只能做
 *	     DHooks detour，见 `私人文件/逆向报告-胆汁吸引优先级.md` 第 2.2 / 3.3 节。
 *	  ③ 聊天框提示 / 控制台 / 日志 —— l4d_attract_priority_chat、_debug 控制。
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
 *	----------------- 1.1.0 调试与自检（重要） -----------------
 *	旧版所有诊断信息都走 PrintToServer —— 那**只进服务器自身的控制台/stdout**，
 *	在游戏里按 `~` 打开的是**客户端控制台**，看不到，也没写进任何日志文件，
 *	所以「开了 debug 却什么都没看到」是必然的。1.1.0 改为：
 *	  · 所有诊断同时 `PrintToServer` + `LogMessage`（写入
 *	    `addons/sourcemod/logs/L<日期>.log`，可以直接打开/贴出来）；
 *	  · 诊断**默认开启**（l4d_attract_priority_debug 默认 1，屏蔽开关 mode 默认 1）；
 *	  · 新增 `sm_attract_status`（ADMFLAG_ROOT）：当场打印生效参数、
 *	    场上所有 info_goal_infected_chase（含 parent / 是否已登记 / 年龄 / 坐标）、
 *	    所有 pipe_bomb_projectile（含是否被压制 / 坐标）；若一个 goal 都没有，
 *	    还会把所有类名里含 "goal" 的实体列出来，用来确认这张图胆汁点到底叫什么；
 *	  · 胆汁吸引点「生成」时无条件打一条（带 parent 与 targetname），
 *	    再单独打「是否按小丑/Jimmy 挂件跳过」，避免 parent 判据把真胆汁点误杀时无声无息；
 *	  · 土制炸弹实体一生成就打一条，确认扫描器确实能看到雷；
 *	  · 「覆盖土制炸弹」只在**首次**标记时打一条（旧版每 0.2 秒刷一次，会把日志刷爆）。
 *
 *	----------- 1.2.0 / 1.2.1 新增（聊天框 / 改雷 / 被胆汁玩家 / 保留模糊） -----------
 *	  1) **聊天框输出**：l4d_attract_priority_chat（默认 1）。压制某颗雷、清掉某个人的
 *	     IT 时都会 `PrintToChatAll`（颜色：\x05[胆汁]\x01 …），同时照旧写控制台与日志。
 *	  2) **直接改雷**（参考 `l4d_pipebomb_shove.sp` 对雷的数据字段写法）：
 *	     l4d_attract_priority_bomb_mode 默认 **2 = 只改雷、雷的滴滴声照常响**；
 *	     改的是 datamap 字段 `m_bHasWarnedAI`(=1) 与 `m_flWarnAITime`(=0)，
 *	     也就是把「CBaseCSGrenadeProjectileDangerSoundThink」那条"警告 AI"通路关掉。
 *	     不碰 m_bIsLive / m_flDetonateTime / m_DmgRadius / m_flDamage ⇒ 雷照常响引信、
 *	     照常爆炸、照常造成伤害与尸潮。1 = 改雷 + 静音蜂鸣；0 = 只静音蜂鸣。
 *	  3) **被胆汁玩家不再吸引**（参考 `l4d2_si_bile.sp` 对特感的同款做法）：
 *	     l4d_attract_priority_bile_it 默认 1。用 player_now_it / player_no_longer_it
 *	     跟踪 IT 状态，在有地面胆汁时调用 left4dhooks 的 `L4D_OnITExpired()` 结束 IT，
 *	     普通感染者就不再围着这个人转 —— 也就是「胆汁 > 被胆汁的玩家」。
 *	     1.2.1 追加：`l4d_attract_priority_keep_blur` 默认 1，清完 IT 后把
 *	     m_vomitStart / m_vomitFadeStart 写回原值，**只结束吸引、保留屏幕模糊**。
 *	     left4dhooks 未加载/该 native 不可用时自动跳过这一层（g_bLeft4DHooksIT）。
 *
 *	新增自检：`sm_attract_status` 现在还会打印 chat / bomb_mode / bile_it / keep_blur /
 *	left4dhooks_IT 是否可用 / 当前处于 IT 的玩家数。
 *
 *	------------------ 1.3.0：聊天框覆盖每一步（可诊断性） ------------------
 *	旧版聊天只在"检测成功"时发，检测不到就完全静默，无法判断断在哪一步。1.3.0 起
 *	（都受 l4d_attract_priority_chat 控制）：
 *	  · 每张图开场 / 中途加载插件 → `[胆汁] 已就绪：胆汁会压掉土制炸弹的吸引（mode=… bomb_mode=… bile_it=…）`
 *	    —— 看到这条说明插件在跑、chat 是开的；
 *	  · 胆汁吸引点被登记 → `检测到胆汁吸引点 ent=N：X 秒内压制半径 Y 内的土制炸弹`
 *	    —— 说明"胆汁识别"这一步通了；
 *	  · 雷生成时当前没有生效胆汁 → `检测到土制炸弹，但当前没有生效中的胆汁吸引点（雷照常吸引）`
 *	    —— 说明插件看得到雷，只是没有胆汁可压（5 秒限流一次）；
 *	  · 雷被压制 / 被胆汁玩家让位 → 原有那两条。
 *	连第一条"已就绪"都看不到，就是插件没加载或 chat=0，与检测无关。
 *
 *	本插件**没有被加入任何 cfg**，也没有被加载；以上全部结论均为静态分析 + 编译验证，
 *	不含实机验证。
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>

#define PLUGIN_VERSION "1.3.1"

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
ConVar g_cvChat;
ConVar g_cvBombMode;
ConVar g_cvBileIT;
ConVar g_cvKeepBlur;

bool  g_bEnable;
float g_fWindow;
float g_fRadius;
int   g_iMode;   // 0 = 只检测（不屏蔽）；1 = 屏蔽雷蜂鸣
bool  g_bDebug;
bool  g_bChat;      // 聊天框提示
int   g_iBombMode;  // 0=只静音；1=静音+改雷；2=只改雷
bool  g_bBileIT;    // 地面胆汁期间清掉被胆汁玩家的 IT
bool  g_bKeepBlur;  // 清 IT 时保留屏幕模糊（写回 m_vomitStart / m_vomitFadeStart）
bool  g_bIT[MAXPLAYERS + 1];    // 该玩家当前是否处于 IT（被胆汁）状态
bool  g_bLeft4DHooksIT;         // L4D_OnITExpired 是否可用
float g_fLastBombChat;          // 1.3.0：雷没被压制时的聊天限流
float g_fLastReadyChat;         // 1.3.0：「已就绪」去重（reload 会走两条加载路径）
float g_fLastScanLog;           // 1.3.1：扫描诊断日志限流（每 3 秒最多一条）
float g_fLastHeartbeat;         // 1.3.1：心跳日志限流（与扫描诊断分开，互不压制）
bool  g_bLateLoad;

int   g_iMaxEntities;

// 吸引点生成时间（0 = 不是吸引点）
float g_flGoalSpawn[MAX_ENTITIES + 1];
// 当前被压制的雷
bool  g_bMutedBomb[MAX_ENTITIES + 1];
// 已经"处理并播报过"的雷（每颗雷只打一次日志/聊天、只改一次字段）。
// 不能复用 g_bMutedBomb 做这个判断：每轮扫描开头都会 ClearMutes()，
// 那样"首次覆盖"每 0.2 秒都会成立，聊天与日志会被刷爆。
bool  g_bBombNotified[MAX_ENTITIES + 1];
// 上一轮被压制的雷数量（0 时快速返回）
int   g_iMutedCount;

public Plugin myinfo =
{
	name = "l4d_attract_priority",
	author = "apples1949",
	description = "胆汁地面存在时压掉土制炸弹的吸引（静音蜂鸣 + 改雷的 AI 警告字段）；地面胆汁期间被胆汁玩家让位（结束 IT、默认保留屏幕模糊）",
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

	// left4dhooks 的 L4D_OnITExpired：用来清掉「被胆汁玩家」的 IT（参考 l4d2_si_bile.sp
	// 对特感用的同一招）。该插件没加载时这条 native 保持未绑定，调用前用
	// g_bLeft4DHooksIT 探一次，不影响「胆汁 > 雷」那一层。
	MarkNativeAsOptional("L4D_OnITExpired");

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
	g_cvDebug = CreateConVar("l4d_attract_priority_debug", "1",
		"1=打印检测/屏蔽细节（默认开）。输出同时进服务器控制台和 addons/sourcemod/logs/L<日期>.log", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvChat = CreateConVar("l4d_attract_priority_chat", "1",
		"1=在聊天框提示「胆汁压掉了哪颗雷 / 谁的气味让位给地面胆汁」。0=只写控制台和日志", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvBombMode = CreateConVar("l4d_attract_priority_bomb_mode", "2",
		"对雷的处理方式：2=只改雷的 AI 警告字段（默认，雷的滴滴声照常）；1=改雷 + 静音蜂鸣；0=只静音蜂鸣", FCVAR_NOTIFY, true, 0.0, true, 2.0);
	g_cvBileIT = CreateConVar("l4d_attract_priority_bile_it", "1",
		"1=地面胆汁生效期间，清掉被胆汁玩家(player_now_it)的 IT 状态，让他们不再吸引普通感染者（参考 l4d2_si_bile.sp 对特感的同款做法）。0=不改被胆汁玩家", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvKeepBlur = CreateConVar("l4d_attract_priority_keep_blur", "1",
		"1=清 IT 时保留被胆汁玩家的屏幕模糊（只结束 IT 的吸引，不抹掉胆汁观感）。0=连模糊一起清掉（同 l4d2_si_bile.sp 的做法）", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvEnable.AddChangeHook(ConVarChanged_Cvars);
	g_cvWindow.AddChangeHook(ConVarChanged_Cvars);
	g_cvRadius.AddChangeHook(ConVarChanged_Cvars);
	g_cvMode.AddChangeHook(ConVarChanged_Cvars);
	g_cvDebug.AddChangeHook(ConVarChanged_Cvars);
	g_cvChat.AddChangeHook(ConVarChanged_Cvars);
	g_cvBombMode.AddChangeHook(ConVarChanged_Cvars);
	g_cvBileIT.AddChangeHook(ConVarChanged_Cvars);
	g_cvKeepBlur.AddChangeHook(ConVarChanged_Cvars);

	// 强制写回默认值。
	// 原因：SourceMod 的 CreateConVar 在「同名 cvar 已存在」时**不会重置它的值**，
	// 所以上一版残留的运行时改动（例如手测时把 enable 设成 0、把 bomb_mode 设成 1）
	// 会一直跟着插件，表现为"插件在跑但完全不生效、连扫描心跳都没有"。
	// 这里在每次加载/重载时把默认值写回去，保证"插件默认即生效状态"，不需要任何 cfg。
	g_cvEnable.SetInt(1);      // 1 = 启用（0 会让扫描整个跳过）
	g_cvMode.SetInt(1);        // 1 = 真生效
	g_cvBombMode.SetInt(2);    // 2 = 只改雷、不静音
	g_cvBileIT.SetInt(1);      // 被胆汁玩家让位
	g_cvKeepBlur.SetInt(1);    // 保留屏幕模糊
	g_cvChat.SetInt(1);        // 聊天框播报
	g_cvDebug.SetInt(1);       // 控制台 + 日志
	g_cvWindow.SetFloat(12.0); // 压制窗口
	g_cvRadius.SetFloat(800.0);// 作用半径

	GetCvars();

	// left4dhooks 的 L4D_OnITExpired 是否可用（缺了只是不做「胆汁 > 被胆汁玩家」那一层）
	g_bLeft4DHooksIT = (GetFeatureStatus(FeatureType_Native, "L4D_OnITExpired") == FeatureStatus_Available);

	// 被胆汁玩家：只记录 IT 状态，真正的清除在 Timer_Scan 里做（要有地面胆汁才清）
	HookEvent("player_now_it", Event_PlayerNowIt, EventHookMode_Post);
	HookEvent("player_no_longer_it", Event_PlayerNoLongerIt, EventHookMode_Post);
	HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);
	HookEvent("round_start", Event_RoundStart, EventHookMode_Post);

	g_iMaxEntities = GetMaxEntities();
	if (g_iMaxEntities > MAX_ENTITIES)
	{
		g_iMaxEntities = MAX_ENTITIES;
	}

	// 全局声音钩子：只拦「被压制的那颗雷」发出的蜂鸣
	AddNormalSoundHook(OnNormalSound);

	// 自检命令：当场打印生效参数 + 场上胆汁吸引点 / 土制炸弹
	RegAdminCmd("sm_attract_status", Cmd_Status, ADMFLAG_ROOT,
		"打印 l4d_attract_priority 的生效参数与场上实体（排查「什么都没检测到」用）");

	CreateTimer(SCAN_INTERVAL, Timer_Scan, INVALID_HANDLE, TIMER_REPEAT);

	// 晚加载时把已经在场的胆汁吸引点补登记一遍
	if (g_bLateLoad)
	{
		LateLoadGoals();

		// 中途加载时 OnMapStart 不会重跑，这里补一次"已就绪"
		AnnounceReady();
	}
}

public void OnMapStart()
{
	ClearAllState();

	// 1.3.0：每张图开场在聊天框报一次"已就绪"。
	// 作用：立刻确认「插件到底有没有在跑、chat 开关是不是开的」——
	// 旧版只在检测成功时才发聊天，检测失败就完全静默，没法判断断在哪一步。
	AnnounceReady();
}

void AnnounceReady()
{
	// 去重：sm plugins reload 会先后经过 OnPluginStart(late) 与 OnMapStart，
	// 两条路径都会播报一次，这里用 5 秒窗口把重复的那条吞掉。
	float now = GetGameTime();
	if (now - g_fLastReadyChat < 5.0)
	{
		return;
	}

	g_fLastReadyChat = now;

	AttractChat("已就绪：enable=%d 胆汁会压掉土制炸弹的吸引（mode=%d bomb_mode=%d bile_it=%d）",
		g_bEnable ? 1 : 0, g_iMode, g_iBombMode, g_bBileIT ? 1 : 0);
}

// 玩家断线：清掉 IT 标记，避免索引复用
public void OnClientDisconnect(int client)
{
	if (client > 0 && client <= MaxClients)
	{
		g_bIT[client] = false;
	}
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

	// 诊断：雷一生成就记一笔，确认「扫描器到底有没有看到雷」
	if (StrEqual(classname, CLASS_PIPE_PROJ))
	{
		float pos[3];
		GetSafeOrigin(entity, pos);
		AttractDebug("看到土制炸弹实体 ent=%d pos=(%.0f, %.0f, %.0f)", entity, pos[0], pos[1], pos[2]);
		return;
	}

	if (!StrEqual(classname, CLASS_BILE_GOAL))
	{
		return;
	}

	// 诊断：无条件先把「生成」这件事打出来（含 parent 与 targetname）。
	// 旧版只在 parent == -1 时才登记且不打印，一旦 parent 判据把真胆汁点误杀，
	// 现场表现就是"什么都没发生"，无从下手。
	{
		float pos[3];
		GetSafeOrigin(entity, pos);
		char sName[64];
		GetEntPropString(entity, Prop_Data, "m_iName", sName, sizeof(sName));
		AttractDebug("胆汁吸引点生成 ent=%d parent=%d name=\"%s\" pos=(%.0f, %.0f, %.0f)",
			entity, GetEntPropEnt(entity, Prop_Data, ENTPROP_PARENT), sName, pos[0], pos[1], pos[2]);
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
	{
		int iParent = GetEntPropEnt(entity, Prop_Data, ENTPROP_PARENT);
		if (iParent != -1)
		{
			AttractDebug("吸引点 ent=%d 带 parent=%d，按「小丑/Jimmy 挂件」跳过，不当作胆汁地面", entity, iParent);
			return;
		}
	}

	g_flGoalSpawn[entity] = GetGameTime();

	AttractDebug("登记胆汁吸引点 ent=%d（压制雷 %.1f 秒，半径 %.0f，mode=%d）",
		entity, g_fWindow, g_fRadius, g_iMode);

	// 1.3.0：检测成功也在聊天框报一条，确认这一步走通了
	AttractChat("检测到胆汁吸引点 ent=%d：%.0f 秒内压制半径 %.0f 内的土制炸弹",
		entity, g_fWindow, g_fRadius);
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

	// 雷被销毁：清掉"已播报"标记，索引复用时不会继承旧状态
	g_bBombNotified[entity] = false;
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
	g_bChat   = g_cvChat.BoolValue;
	g_iBombMode = g_cvBombMode.IntValue;
	g_bBileIT = g_cvBileIT.BoolValue;
	g_bKeepBlur = g_cvKeepBlur.BoolValue;
}

/**
 * 统一诊断输出。
 *
 * 旧版直接 PrintToServer：那只进服务器自身控制台，游戏里按 ~ 打开的客户端控制台看不到，
 * 也不落盘，所以「debug=1 却什么都没有」是必然结果。
 * 现在一条信息走两路：服务器控制台 + SourceMod 日志文件
 * `addons/sourcemod/logs/L<YYYYMMDD>.log`（LogMessage 会自动带时间与插件名）。
 */
void AttractDebug(const char[] fmt, any ...)
{
	if (!g_bDebug)
	{
		return;
	}

	char buf[256];
	VFormat(buf, sizeof(buf), fmt, 2);

	PrintToServer("[l4d_attract_priority] %s", buf);
	LogMessage("%s", buf);
}

/**
 * 聊天框提示（l4d_attract_priority_chat=1 时生效），同时写一条 debug 日志便于对时间线。
 */
void AttractChat(const char[] fmt, any ...)
{
	char buf[192];
	VFormat(buf, sizeof(buf), fmt, 2);

	AttractDebug("%s", buf);

	if (!g_bChat)
	{
		return;
	}

	PrintToChatAll("\x05[胆汁]\x01 %s", buf);
}

/**
 * 直接改雷：关掉这颗雷的「AI 警告」通路，而不是只在声音出口把它拦掉。
 *
 * 依据（datamap-dump 的 `CPipeBombProjectile - pipe_bomb_projectile`）：
 *   - m_bHasWarnedAI  (Offset 6724, 1 byte)
 *   - m_flWarnAITime  (Offset 6736, 4 bytes)
 *   - 以及 `CBaseCSGrenadeProjectileDangerSoundThink` —— 雷的"危险提示声/吸引"就是这条 think 发的。
 * 写法参考 l4d_pipebomb_shove.sp 改雷（它对 m_DmgRadius / m_flDamage 也是用 Prop_Data 直接写）。
 * 只动这两个字段，**不碰** m_bIsLive / m_flDetonateTime / m_DmgRadius / m_flDamage，
 * 所以雷照常计时、照常爆炸、照常造成伤害与尸潮。
 */
void ApplyBombNoAttract(int entity)
{
	if (entity < 1 || !IsValidEntity(entity))
	{
		return;
	}

	if (!HasEntProp(entity, Prop_Data, "m_bHasWarnedAI"))
	{
		AttractDebug("雷 ent=%d 没有 m_bHasWarnedAI 字段，跳过直接修改", entity);
		return;
	}

	SetEntProp(entity, Prop_Data, "m_bHasWarnedAI", 1);

	bool bWarnTime = HasEntProp(entity, Prop_Data, "m_flWarnAITime");
	if (bWarnTime)
	{
		SetEntPropFloat(entity, Prop_Data, "m_flWarnAITime", 0.0);
	}

	AttractDebug("直接改雷 ent=%d：m_bHasWarnedAI=1%s", entity, bWarnTime ? "、m_flWarnAITime=0" : "");
}

/**
 * 取实体坐标，带兜底。
 *
 * 为什么需要：`info_goal_infected_chase` 是**纯服务端实体**（netprop-dump 里根本没有它），
 * 用 Prop_Send 读 "m_vecOrigin" 会一直返回 (0,0,0)；投掷物在 OnEntityCreated 那一刻
 * 也还没落坐标。所以按 m_vecAbsOrigin(Data) → m_vecOrigin(Data) → m_vecOrigin(Send)
 * 依次尝试，并在读到 (0,0,0) 时认为无效。
 *
 * 这一条是"胆汁明明生成了、雷却没被压制"的直接原因：早先两边都读到 (0,0,0)，
 * 距离算出 0 或者完全无关的值。
 */
bool GetSafeOrigin(int entity, float pos[3])
{
	pos[0] = 0.0;
	pos[1] = 0.0;
	pos[2] = 0.0;

	if (entity < 1 || !IsValidEntity(entity))
	{
		return false;
	}

	if (HasEntProp(entity, Prop_Data, "m_vecAbsOrigin"))
	{
		GetEntPropVector(entity, Prop_Data, "m_vecAbsOrigin", pos);
		if (pos[0] != 0.0 || pos[1] != 0.0 || pos[2] != 0.0)
		{
			return true;
		}
	}

	if (HasEntProp(entity, Prop_Data, "m_vecOrigin"))
	{
		GetEntPropVector(entity, Prop_Data, "m_vecOrigin", pos);
		if (pos[0] != 0.0 || pos[1] != 0.0 || pos[2] != 0.0)
		{
			return true;
		}
	}

	if (HasEntProp(entity, Prop_Send, ENTPROP_ORIGIN))
	{
		GetEntPropVector(entity, Prop_Send, ENTPROP_ORIGIN, pos);
		if (pos[0] != 0.0 || pos[1] != 0.0 || pos[2] != 0.0)
		{
			return true;
		}
	}

	return false;
}

void ClearAllState()
{
	for (int i = 0; i <= MAX_ENTITIES; i++)
	{
		g_flGoalSpawn[i] = 0.0;
		g_bMutedBomb[i] = false;
		g_bBombNotified[i] = false;
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

		GetEntityClassname(entity, classname, sizeof(classname));
		AttractDebug("晚加载补登记吸引点 ent=%d (%s)", entity, classname);
	}
}

public Action Timer_Scan(Handle timer)
{
	if (!g_bEnable)
	{
		ClearMutes();
		return Plugin_Continue;
	}

	// 心跳：每 3 秒一条，用来确认「计时器在跑 / 能找到几个雷 / 有几个已登记的胆汁点」。
	// 看不到这条 = 扫描根本没在跑；看到但"场上雷=0" = FindEntityByClassname 没找到投掷物。
	if (g_bDebug)
	{
		float nowHb = GetGameTime();
		if (nowHb - g_fLastHeartbeat > 3.0)
		{
			g_fLastHeartbeat = nowHb;

			int iBombN = 0;
			int iB = -1;
			while ((iB = FindEntityByClassname(iB, CLASS_PIPE_PROJ)) != -1)
			{
				iBombN++;
				if (iBombN >= 16)
				{
					break;
				}
			}

			int iGoalN = 0;
			for (int e = 1; e <= g_iMaxEntities; e++)
			{
				if (g_flGoalSpawn[e] > 0.0)
				{
					iGoalN++;
				}
			}

			AttractDebug("[心跳] 扫描在跑：已登记胆汁点=%d 场上雷=%d 已压制=%d 半径=%.0f",
				iGoalN, iBombN, g_iMutedCount, g_fRadius);
		}
	}

	float now = GetGameTime();

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

		// 诊断：场上有雷、但当前没有生效中的胆汁点。
		// 注意不能在 OnEntityCreated 里判 —— 那一刻扫描还没跑，g_iMutedCount 必然是 0。
		if (g_bDebug && g_bChat && FindEntityByClassname(-1, CLASS_PIPE_PROJ) != -1)
		{
			float nowNoGoal = GetGameTime();
			if (nowNoGoal - g_fLastBombChat > 5.0)
			{
				g_fLastBombChat = nowNoGoal;
				AttractChat("检测到土制炸弹，但当前没有生效中的胆汁吸引点（雷照常吸引）");
			}
		}

		return Plugin_Continue;
	}

	// 先把上一轮的压制全部清掉，再按本轮重新标（mode 0 也照样标，只是声音钩子不生效，
	// 这样 debug 能完整看到「本来会压制谁」）
	ClearMutes();

	// 胆汁点坐标：任何一条读不出来就记下来，后面退化为"全图压制"而不是静默不生效
	bool bGoalPosOk = false;
	float goalPosFirst[3];
	goalPosFirst[0] = goalPosFirst[1] = goalPosFirst[2] = 0.0;
	{
		float tmp[3];
		if (GetSafeOrigin(goals[0], tmp))
		{
			bGoalPosOk = true;
			goalPosFirst[0] = tmp[0];
			goalPosFirst[1] = tmp[1];
			goalPosFirst[2] = tmp[2];
		}
	}

	int bomb = -1;
	float nowBomb = GetGameTime();

	while ((bomb = FindEntityByClassname(bomb, CLASS_PIPE_PROJ)) != -1)
	{
		if (bomb < 1 || bomb > g_iMaxEntities || !IsValidEntity(bomb))
		{
			continue;
		}

		float bombPos[3];
		bool bBombPosOk = GetSafeOrigin(bomb, bombPos);

		int   iBestGoal  = 0;
		float fBestDist  = -1.0;
		bool  bCovered   = false;
		float fCoverDist = 0.0;

		if (!bBombPosOk && bGoalPosOk)
		{
			AttractDebug("雷 %d 读不到坐标（创建后 m_vecAbsOrigin/m_vecOrigin 仍为 0），本轮跳过", bomb);
			continue;
		}

		if (bBombPosOk && bGoalPosOk)
		{
			for (int g = 0; g < nGoals; g++)
			{
				float goalPos[3];
				if (!GetSafeOrigin(goals[g], goalPos))
				{
					continue;
				}

				float dist = GetVectorDistance(bombPos, goalPos, false);

				if (fBestDist < 0.0 || dist < fBestDist)
				{
					fBestDist = dist;
					iBestGoal = goals[g];
				}

				if (dist <= g_fRadius)
				{
					bCovered   = true;
					fCoverDist = dist;
					iBestGoal  = goals[g];
					break;
				}
			}
		}
		else
		{
			// 兜底：胆汁点或雷的坐标任何一边读不到 → 不做距离判断，直接按"有胆汁就压制"处理。
			// 宁可多压一颗，也不要"胆汁明明在却完全没反应"。
			bCovered   = true;
			fCoverDist = -1.0;
			iBestGoal  = goals[0];
		}

		// 扫描诊断：每 3 秒最多一条，把坐标/距离/判定直接写出来
		if (g_bDebug && nowBomb - g_fLastScanLog > 3.0)
		{
			g_fLastScanLog = nowBomb;
			AttractDebug("[扫描] 胆汁点=%d(首点%d pos=%.0f,%.0f,%.0f 可读=%d) 雷=%d(pos=%.0f,%.0f,%.0f 可读=%d) 最近距离=%.0f 半径=%.0f → 覆盖=%d",
				nGoals, goals[0], goalPosFirst[0], goalPosFirst[1], goalPosFirst[2], bGoalPosOk ? 1 : 0,
				bomb, bombPos[0], bombPos[1], bombPos[2], bBombPosOk ? 1 : 0,
				fBestDist, g_fRadius, bCovered ? 1 : 0);
		}

		if (!bCovered)
		{
			// 离开半径：允许它下次重新进来时再播报一次
			g_bBombNotified[bomb] = false;

			// 诊断：有胆汁点但距离超半径 —— 把最近距离打出来，避免"没压制"说不清原因
			if (g_bDebug && iBestGoal != 0 && nowBomb - g_fLastBombChat > 5.0)
			{
				g_fLastBombChat = nowBomb;
				AttractChat("雷 %d 没被压制：最近的胆汁点 %d 距离 %.0f > 半径 %.0f",
					bomb, iBestGoal, fBestDist, g_fRadius);
			}

			continue;
		}

		if (!g_bBombNotified[bomb])
		{
			g_bBombNotified[bomb] = true;

			AttractDebug("胆汁点 %d 覆盖土制炸弹 %d（距离 %.0f / 半径 %.0f，mode=%d，bomb_mode=%d）",
				iBestGoal, bomb, fCoverDist, g_fRadius, g_iMode, g_iBombMode);

			// bomb_mode 1/2 = 直接改雷（关掉 AI 警告通路）；0 = 只靠声音钩子静音
			if (g_iMode != 0 && (g_iBombMode == 1 || g_iBombMode == 2))
			{
				ApplyBombNoAttract(bomb);
			}

			if (g_iMode == 0)
			{
				AttractChat("检测到胆汁覆盖土制炸弹 %d（mode=0 只检测，未实际压制）", bomb);
			}
			else
			{
				AttractChat("胆汁压掉了土制炸弹的吸引（雷仍会照常倒计时、爆炸、造成伤害）");
			}
		}

		g_bMutedBomb[bomb] = true;
		g_iMutedCount++;
	}

	// ---- 「胆汁 > 被胆汁的玩家」这一层 ----
	// 地面胆汁生效期间，把被胆汁玩家的 IT 清掉（参考 l4d2_si_bile.sp 对特感用的同一招：
	// L4D_OnITExpired 结束 IT 状态，普通感染者就不再围着这个人转）。
	// 只在**有地面胆汁**时做；否则等于把胆汁机制整个取消，不是本插件的意图。
	if (g_bBileIT && g_bLeft4DHooksIT && g_iMode != 0)
	{
		for (int c = 1; c <= MaxClients; c++)
		{
			if (!g_bIT[c])
			{
				continue;
			}

			if (!IsClientInGame(c) || !IsPlayerAlive(c))
			{
				g_bIT[c] = false;
				continue;
			}

			// 模糊屏幕是**另一条通路**：客户端读 m_vomitStart / m_vomitFadeStart
			// （netprop-dump：offset 16172 / 16176，float）。
			// 证据：l4d2_si_bile.sp 在调完 L4D_OnITExpired 之后，还要显式把这两个字段
			// 清零才"确保模糊立即消失" —— 说明清 IT 本身并不必然抹掉模糊。
			// 这里反过来：先记下原值，清完 IT 再写回，做到「IT 结束（不再吸引）+ 模糊保留」。
			float fVomitStart = 0.0;
			float fVomitFadeStart = 0.0;
			bool bHasVomit = HasEntProp(c, Prop_Send, "m_vomitStart");
			bool bHasFade = HasEntProp(c, Prop_Send, "m_vomitFadeStart");

			if (bHasVomit)
			{
				fVomitStart = GetEntPropFloat(c, Prop_Send, "m_vomitStart");
			}

			if (bHasFade)
			{
				fVomitFadeStart = GetEntPropFloat(c, Prop_Send, "m_vomitFadeStart");
			}

			L4D_OnITExpired(c);

			if (g_bKeepBlur && bHasVomit && fVomitStart > 0.0)
			{
				SetEntPropFloat(c, Prop_Send, "m_vomitStart", fVomitStart);

				if (bHasFade)
				{
					SetEntPropFloat(c, Prop_Send, "m_vomitFadeStart", fVomitFadeStart);
				}

				AttractDebug("%N 清 IT 后已写回 m_vomitStart=%.2f / m_vomitFadeStart=%.2f（保留模糊）",
					c, fVomitStart, fVomitFadeStart);
			}

			g_bIT[c] = false;

			AttractChat("%N 的气味让位给地面胆汁（不再吸引普通感染者）", c);
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

// ============================================================================
//  被胆汁玩家（IT）状态跟踪
//  参考 l4d2_si_bile.sp：它用 player_now_it / player_no_longer_it + L4D_OnITExpired
//  让"被胆汁的特感"不再吸引小僵尸。这里把同一套用在地面胆汁存在时的生还者身上，
//  用来实现「胆汁 > 被胆汁的玩家」这一层。
// ============================================================================
public void Event_PlayerNowIt(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client <= 0 || client > MaxClients)
	{
		return;
	}

	g_bIT[client] = true;
	AttractDebug("%N 进入 IT（被胆汁）状态", client);
}

public void Event_PlayerNoLongerIt(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client <= 0 || client > MaxClients)
	{
		return;
	}

	g_bIT[client] = false;
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client > 0 && client <= MaxClients)
	{
		g_bIT[client] = false;
	}
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	for (int i = 0; i <= MaxClients; i++)
	{
		g_bIT[i] = false;
	}
}

// 全局普通声音钩子：只处理「被压制的那颗雷」的蜂鸣
public Action OnNormalSound(int clients[MAXPLAYERS], int &numClients, char sample[PLATFORM_MAX_PATH],
	int &entity, int &channel, float &volume, int &level, int &pitch, int &flags,
	char soundEntry[PLATFORM_MAX_PATH], int &seed)
{
	// 绝大多数时间直接返回：没有胆汁点在压制任何雷
	// bomb_mode==2 时只靠"直接改雷"（改 AI 警告字段），这里不拦声音。
	if (g_iMutedCount == 0 || !g_bEnable || g_iMode == 0 || g_iBombMode == 2)
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

	AttractDebug("静音雷蜂鸣 ent=%d sample=\"%s\" entry=\"%s\"", entity, sample, soundEntry);

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

/**
 * sm_attract_status —— 自检命令（ADMFLAG_ROOT）。
 *
 * 目的：不依赖"扔的时机对不对"，当场把「插件到底看到了什么」打给执行者。
 * 用服务器控制台 / rcon 执行时输出也会进服务器控制台。
 *
 *   1) 生效参数（确认 cvar 真的落到了插件里）；
 *   2) 场上所有 info_goal_infected_chase：parent、是否已登记、年龄、坐标；
 *      一个都没有时，把所有类名含 goal/bile 的实体列出来（确认这张图胆汁点的真实类名）；
 *   3) 场上所有 pipe_bomb_projectile：是否已被压制、坐标。
 */
public Action Cmd_Status(int client, int args)
{
	int iITCount = 0;
	for (int c = 1; c <= MaxClients; c++)
	{
		if (g_bIT[c] && IsClientInGame(c) && IsPlayerAlive(c))
		{
			iITCount++;
		}
	}

	ReplyToCommand(client, "[吸引优先级] enable=%d mode=%d debug=%d chat=%d window=%.1fs radius=%.0f 压制中的雷=%d",
		g_cvEnable.IntValue, g_cvMode.IntValue, g_cvDebug.IntValue, g_cvChat.IntValue,
		g_fWindow, g_fRadius, g_iMutedCount);
	ReplyToCommand(client, "[吸引优先级] bomb_mode=%d(0=只静音 1=静音+改雷 2=只改雷) bile_it=%d keep_blur=%d left4dhooks_IT=%d 被胆汁玩家=%d",
		g_cvBombMode.IntValue, g_cvBileIT.IntValue, g_cvKeepBlur.IntValue,
		g_bLeft4DHooksIT ? 1 : 0, iITCount);

	float now = GetGameTime();

	// ---- 胆汁吸引点 ----
	int iGoalCount = 0;
	int entity = -1;
	while ((entity = FindEntityByClassname(entity, CLASS_BILE_GOAL)) != -1)
	{
		if (entity < 1 || entity > g_iMaxEntities || !IsValidEntity(entity))
		{
			continue;
		}

		float pos[3];
		GetSafeOrigin(entity, pos);
		int iParent = GetEntPropEnt(entity, Prop_Data, ENTPROP_PARENT);
		float fSpawn = g_flGoalSpawn[entity];

		ReplyToCommand(client, "  [goal] ent=%d parent=%d 已登记=%s 年龄=%.1fs pos=(%.0f, %.0f, %.0f)",
			entity, iParent, (fSpawn > 0.0) ? "是" : "否",
			(fSpawn > 0.0) ? (now - fSpawn) : -1.0, pos[0], pos[1], pos[2]);

		iGoalCount++;
	}

	if (iGoalCount == 0)
	{
		ReplyToCommand(client, "  [goal] 场上没有 info_goal_infected_chase —— 胆汁点没生成，或这张图用的是别的类名");

		char classname[64];
		int iFound = 0;
		for (int i = 1; i <= g_iMaxEntities; i++)
		{
			if (!IsValidEntity(i))
			{
				continue;
			}

			GetEntityClassname(i, classname, sizeof(classname));
			if (StrContains(classname, "goal", false) == -1 && StrContains(classname, "bile", false) == -1)
			{
				continue;
			}

			float pos[3];
			GetSafeOrigin(i, pos);
			ReplyToCommand(client, "    ent=%d class=%s pos=(%.0f, %.0f, %.0f)",
				i, classname, pos[0], pos[1], pos[2]);
			iFound++;

			if (iFound >= 32)
			{
				break;
			}
		}

		if (iFound == 0)
		{
			ReplyToCommand(client, "    （类名含 goal/bile 的实体：一个都没有）");
		}
	}

	// ---- 土制炸弹 ----
	int iBombCount = 0;
	int bomb = -1;
	while ((bomb = FindEntityByClassname(bomb, CLASS_PIPE_PROJ)) != -1)
	{
		if (bomb < 1 || bomb > g_iMaxEntities || !IsValidEntity(bomb))
		{
			continue;
		}

		float pos[3];
		GetSafeOrigin(bomb, pos);
		ReplyToCommand(client, "  [pipe] ent=%d 已被压制=%d pos=(%.0f, %.0f, %.0f)",
			bomb, g_bMutedBomb[bomb] ? 1 : 0, pos[0], pos[1], pos[2]);

		iBombCount++;
	}

	if (iBombCount == 0)
	{
		ReplyToCommand(client, "  [pipe] 场上没有 pipe_bomb_projectile（雷还没扔，或者已经炸了）");
	}

	return Plugin_Handled;
}
