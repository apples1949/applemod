#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>
#include <colors>

#define PLG_NAME		   "Tank Attack Control Plus"
#define PLG_AUTH		   "游而戏之,apples1949"
#define PLG_DESC		   "-"
#define PLG_VERS		   "1.7.1-applefix"
#define PLG_URLS		   "-"

#define IsValidClient(%1)  (0 < %1 <= MaxClients && IsClientInGame(%1))
#define IsTank(%1)		   (IsValidClient(%1) && !IsFakeClient(%1) && GetClientTeam(%1) == 3 && GetEntProp(%1, Prop_Send, "m_zombieClass") == 8)
/* 含 AI 坦克的判定: 坦克视野只接管真人坦克(IsTank), 但"这辆坦克活了多久"必须连 AI 坦克
   (掉控后引擎接管的那辆)一起累计, 否则二控/给克接手后存活计时会从头开始 */
#define IsTankEntity(%1)   (IsValidClient(%1) && GetClientTeam(%1) == 3 && GetEntProp(%1, Prop_Send, "m_zombieClass") == 8)

#define BHOPMODE_BLOCK	   0  /* 禁用连跳 */
#define BHOPMODE_AUTO	   1  /* 自动连跳 */
#define L				   -1 /* 左向 */
#define R				   1  /* 右向 */

#define TAG				   "{olive}[{lightred}!{olive}]{orange}"

native int TankAttackControl_GetThrowSequence(int client);

/* 控制权插件(修改版 l4d_tank_control_eq)排队的下一位坦克; 插件不存在时用 GetFeatureStatus 先判断 */
native int GetTankSelection();


#define TRAC_ROCK_MAX	   2048 /* 跟踪石相关数组上限(tank_rock 实体索引) */
#define ROCK_FLY_SOUND	   "HulkZombie.Throw.FlyLoop" /* 坦克石头飞行动画循环音效(server.dll 里引擎按这个名字播放) */
#define ROCK_FLY_WAVE	   "player/tank/attack/thrown_missile_loop_1.wav" /* 上面那条 soundscript 实际引用的波形(游戏内松散文件, 213KB) */

/* 技能扣血通报类型: 枚举值必须与 Apex.inc 的 ApexSkillCostType 保持一致(消费方包含 Apex.inc) */
enum ApexSkillCostType
{
	ApexSkillCost_Bhop = 0,	  /* !bhop 开启费 */
	ApexSkillCost_TracEnable, /* !trac 开启费 */
	ApexSkillCost_TracThrow,  /* 跟踪石掷出预扣(命中生还者退还时为负数) */
	ApexSkillCost_BhopDetect, /* 未开启 !bhop 却连续连跳被抓的补扣 */
	ApexSkillCost_PredEnable  /* !pred 开启费(坦克石头轨迹预测) */
}

/* 石头轨迹预测(!pred)的物理参数
   全部取自 Linux 服务端二进制 server_srv.so 的实测(不是猜的):
     * 出石位置 = 坦克 "debris" 骨骼附着点(引擎在 CTankRock::OnRelease 里用
       CBaseAnimating::GetAttachment 取这个点; 这里用左4死钩子提供的
       GetAttachmentVectors(tank, "debris", ...) 取同一个点)。
       实际掷出点确实在这里(调试日志已逐位核对), **但画线起点不用它**: 这个点跟着投掷手臂
       动画走, 站着不动线也会来回抖; 只影响起点位置几十点, 对落点影响可忽略,
       所以画线改用稳定的"眼睛位置 + 前向偏移"(见 GetPredStart)。
       注意: 蓄力期间石头实体本身"并不在手上"——引擎只是把石头 SetParent 到坦克
       (CTankRock::Create 里 FollowEntity(坦克, true), EF_BONEMERGE 的骨骼合并只是
       客户端渲染), 服务端石头的坐标不是出手点, 所以起点也不能用石头坐标。
     * 出石方向 = 坦克眼睛前向 (CBasePlayer::EyeVectors @0x4064D0, 在
       CThrow::UpdateAbility @0x4CF0C1 被调用)
     * 出石初速 = 眼睛前向 * z_tank_throw_force(默认 800) + 坦克自身速度
       (引擎加的是 m_vecAbsVelocity, 偏移 +0x274, 见 0x4CF427; 对没有父实体的玩家
        它与 m_vecVelocity 相等 —— 引擎的 GetAbsVelocity 是"脏标记 + 惰性计算",
        而 SourceMod 直接读属性不会触发那次计算, 所以这里读引擎每帧维护的
        m_vecVelocity, 与引擎行为一致且一定是最新值)
     * 石头重力倍率 m_flGravity = 0.4 (CTankRock::Create 写 +0x2C0),
       即加速度 = sv_gravity * 0.4 (默认 800 * 0.4 = 320 点/秒^2)
     * 石头碰撞盒 ±4 点 (CTankRock::Spawn 写入)
     * 石头凡命中即碎(不反弹, CTankRock::Detonate), 所以只需要算到第一次碰撞 */
#define PRED_HULL_SIZE	   4.0	  /* 石头碰撞盒半径(引擎值 ±4 点) */
#define PRED_FALLBACK_SPEED 800.0 /* 取不到 z_tank_throw_force 时的兜底出石初速 */
#define PRED_PHYS_STEP	   0.02	  /* 物理推进步长(秒): 越小越不容易漏掉薄墙 */
#define PRED_BEAM_LIFE	   0.055 /* 每段光束存活时间(秒): 配合 tank_pred_emit(0.033s) 只叠 1~2 份,
									   刚好连成一条线. 太长会叠出一堆残影(服务器 100tick, 每帧都发的话叠 4~8 份) */
#define PRED_BEAM_SPRITE   "materials/sprites/laserbeam.vmt"
#define PRED_WINDOW		   1.2	  /* 坦克起手扔石后, 预测线最多持续多久(秒); 掷出/取消/超时都会结束 */
#define PRED_MIN_STEP_DIST 2.0	  /* 一步推进不足这个距离就当成"起点自撞(startsolid)"处理, 不算命中 */
#define PRED_SEG_MAX	   64	  /* tank_pred_seg 上限, 也是画线采样点数组尺寸 */
/* 起点自救: 合成出来的起点若插在实心几何里(脚下地面/楼梯/墙角)或贴着地面, 这里往上抬着找空域。
   每次抬 PRED_START_LIFT_STEP 点, 最多抬 PRED_START_LIFT_TRIES 次; 仍不行就退回眼睛锚点
   (见 Pred_FixStart)。只在起点确实不可用时才生效, 正常起点一个坐标都不改。
   PRED_START_CLEAR: 起点正下方要求的最低净空(点), 比"一步推进阈值"略大, 保证第一步不会擦地。 */
#define PRED_START_LIFT_STEP  16.0
#define PRED_START_LIFT_TRIES 8
#define PRED_START_CLEAR	  6.0
/* 世界几何那一次碰撞检测用的掩码: MASK_SOLID 去掉 CONTENTS_MONSTER
   —— 石头的碰撞是 MASK_SOLID 级别, 但会从感染者/普通僵尸身上穿过去(实战验证: 预测在这儿停下而石头继续飞),
   所以感染者不算阻挡; 生还者单独用射线查(见 Pred_SurvivorFilter) */
#define PRED_WORLD_MASK	   ((MASK_SOLID & ~CONTENTS_MONSTER) & ~CONTENTS_PLAYERCLIP)
#define PRED_FORCE_INTERVAL 0.15  /* 即使瞄准/位置完全没变, 也至少这么久重算一次抛物线 */
#define PRED_VIS_UP		   0.0	  /* 画线视觉偏移: 向下让开视线(参考 miwuki 的 Offset_Up) */
#define PRED_OFF_MAX	   150.0 /* 出手偏移的安全上限(点): 实测三种姿势为 41/92/109, 超过这个值一定是取样出了问题,
								   直接夹住, 免得预测线被拉到脚下/天上 */
#define PRED_OFF_SAMPLE_TOL 60.0  /* 同姿势的出手偏移样本与均值差超过这个值(点)就丢弃, 防止被异常样本带偏 */
#define PRED_IMPACT_LIFT   2.0	  /* 落点标记抬高一点, 免得插进地面看不见(参考 miwuki 光圈) */
#define PRED_MARK_WIDTH	   2.0	  /* 落点竖线(光柱)的粗细: 细一点更像"升天光柱" */
#define PRED_MARK_R		   0
#define PRED_MARK_G		   140
#define PRED_MARK_B		   255
#define PRED_COLOR_R	   255
#define PRED_COLOR_G	   96
#define PRED_COLOR_B	   0

/* tank_pred_debug 档位 */
#define PRED_DEBUG_OFF	  0 /* 关 */
#define PRED_DEBUG_KEY	  1 /* 关键事件: !pred 命令结果、掷出时的预测/实际对比 */
#define PRED_DEBUG_FULL	  2 /* 详细: 起手/结束、贴图索引、画了几段、命中与否(写日志+发给玩家) */

/* 调试日志版本标记: 进服看服务器日志里这一行就知道跑的是哪个 build */
#define PRED_BUILD		  "2026-10-20-startsolid"

Handle g_hFwdSkillCost;
Handle g_hFwdTracRockHit;

bool   IsBhop[MAXPLAYERS + 1];
bool   IsTrac[MAXPLAYERS + 1];
bool   IsPred[MAXPLAYERS + 1];

int	   Dir[MAXPLAYERS + 1];
int	   Posture[MAXPLAYERS + 1];
int	   BhopLim[MAXPLAYERS + 1];
int	   TracLim[MAXPLAYERS + 1];
int	   PredLim[MAXPLAYERS + 1];

/* 坦克连跳检测(参考 lilac_bhop.sp 的连跳判定) */
int	   BhopBtn[MAXPLAYERS + 1];	   /* 上一帧按键快照(检测 IN_JUMP 按下沿) */
int	   BhopTick[MAXPLAYERS + 1];   /* 下一次连跳允许的最小 tick(lilac: next_bhop) */
int	   BhopChain[MAXPLAYERS + 1];  /* 当前连续完美连跳次数(lilac: perfect_bhops) */

ConVar Apex[52];

/* -----------------------------------------------------------
	坦克视野(原独立插件 l4d2_tank_vision.sp, 已合并回本插件)
	-----------------------------------------------------------
	为什么必须自己算「看得见」(实测结论, 别再走回头路):
	  玩家控坦克时, 引擎那条“敌人可见性”路径(CTerrorPlayer::CheckEnemySightings)
	  一次都不跑 —— 它属于 AI think, 只有 AI 控特感才走。玩家坦克的 m_frustration
	  是无条件累加的: 看得见看不见都照涨, 到 100 就 tank_frustrated 掉控。
	  所以本插件自己判: 看得见 -> 把引擎原始 m_frustration 写回 0(抑制累积);
	  看不见 -> 不干预引擎自己的累积, 只在“跟踪石命中 / 存活满门限”这两个状态下
	  按原版节奏额外再扣一点(见下面“扣控”说明)。

	判定口径(三条全过才算看得见):
	  距离  : 坦克眼睛 -> 生还者眼睛 <= 当前档位范围(范围按存活时长阶梯收紧)
	  朝向锥: 坦克视线与目标方向点积 >= l4d2_tankvision_dot (0.7≈±45°)
	  视线  : MASK_VISIBLE 射线, 只让世界几何体挡(忽略所有客户端实体)

	扣控规则(2026-11 需求, 最终版):
	  * 接管门槛: 坦克存活满 start_time(默认 240 秒 = 4 分钟)之后, 插件才开始接管控制权;
	    4 分钟之前完全不接管(那段是游戏原生的 5%/秒);
	  * 可见范围(插件判定用): 默认 range(2000); 4.5 分钟 1000 -> 5.5 分钟 750 -> 6.5 分钟 500;
	  * 插件判定"看不见生还者"时, 先分清是谁判定的:
	      a) 游戏自己也在掉怒气(引擎判定看不到) -> 用游戏原生的掉控节奏, 插件不插手;
	      b) 游戏判定"看得见"(怒气不涨)、只有插件判定看不见 -> 由插件强制扣控;
	  * 插件强制扣控的速率(四种情况, 叠加):
	      正常 5% | 存活满 4 分钟 +1% -> 6% | 跟踪石命中 +1% -> 6% | 两者都有 7%;
	  * 按游戏掉控频率(每秒一笔)写入 m_frustration; 已经掉控后本命闩锁, 再看到生还者也不回控。
----------------------------------------------------------- */
#define APEX_TV_ENABLE		28	/* 1=接管(看得见不掉控/看不见按阶梯扣) 0=关闭(原版) */
#define APEX_TV_RANGE		29	/* 基准可见范围(单位), 0=无限 */
#define APEX_TV_DOT			30	/* 朝向锥: 视线点积下限 */
#define APEX_TV_INTERVAL	31	/* 判定间隔(秒) */
#define APEX_TV_DEBUG		32	/* 0=安静 1=每秒一条 2=再加范围/扣控日志 */
#define APEX_TV_T1_TIME		33
#define APEX_TV_T1_RANGE	34
#define APEX_TV_T2_TIME		35
#define APEX_TV_T2_RANGE	36
#define APEX_TV_T3_TIME		37
#define APEX_TV_T3_RANGE	38
#define APEX_TV_NOTIFY		39	/* 范围收紧/开始扣控时通知全体玩家 */
#define APEX_TV_STEP		40	/* 每格基础幅度(%), <=0 自动读 tankcontrol_trac_base */
#define APEX_TV_SEEN_CLEAR	41	/* 看得见时是否把怒气清 0(1=清, 0=不干预) */
#define APEX_TV_START_TIME	42	/* 存活满多少秒后插件才接管控制权(默认 210 = 3.5 分钟) */
#define APEX_TV_ALIVE_TIME	43	/* 存活满多少秒后每秒多扣 1(默认 240 = 4 分钟) */
#define APEX_TV_ALIVE_EXTRA	44	/* 存活满门限后每秒多加的百分点(默认 1) */
#define APEX_TV_TRAC_EXTRA	45	/* 跟踪石命中后每秒多加的百分点(默认 1) */
#define APEX_TV_FORCE		46	/* 0=游戏在掉控时让位 1=不管游戏, 插件总是强制按速率扣 */
#define APEX_TV_GATE		47	/* 0=不碰引擎内存 1=强制打开闸门 2=只在扣满100时打开 */
#define APEX_TV_FORCE_DROP	48	/* 1=扣满100且引擎不判掉控时, 由插件走原生换控(备用) */
#define APEX_TV_FORCE_BLIND	49	/* 1=插件判定看不见时, 把引擎的"最后看见时间"写老, 让引擎自己走原生掉控 */

/* 引擎原始 m_frustration: 0 -> 100 累加, 到顶即掉控(把坦克交给 AI) */
#define TV_FRUSTRATION_MAX	100

ConVar g_hTankVisionControlAfter;    /* tankcontrol_trac_after: 跟踪石命中后的加速持续时间(0=到死亡/交接) */

Handle g_hTVGateConf;						/* gamedata: CTerrorPlayer 怒气闸门偏移 */
int    g_iTVGateOffset = 14984;				/* 默认 Windows 偏移, 加载 gamedata 后覆盖 */
int    g_iTVLastSeenOffset = 12604;			/* 「最后看见生还者时刻」偏移 */
bool   g_bTVGateLogged[MAXPLAYERS + 1];		/* 该坦克已经记过"闸门已打开"日志 */
float  g_fVisionEngAcc[MAXPLAYERS + 1];		/* 引擎怒气速率统计: 窗口内增量 */
float  g_fVisionEngSpan[MAXPLAYERS + 1];	/* 引擎怒气速率统计: 窗口时长 */
float  g_fVisionEngRate[MAXPLAYERS + 1];	/* 引擎怒气速率(%/秒, 每 2 秒结算一次) */

Handle g_hTankVisionTimer;
float  g_fTankCtrlStart[MAXPLAYERS + 1];   /* 该玩家拿到坦克(开始跟踪)的时刻, 0=没在跟踪 */
float  g_fVisionAliveBias[MAXPLAYERS + 1]; /* 调试指令额外加的存活秒数(不改真实起点, 避免把起点算成负数) */
float  g_fVisionRangeMark[MAXPLAYERS + 1]; /* 已通知过的范围(-1=还没观察过这辆坦克) */
bool   g_bVisionDropped[MAXPLAYERS + 1];   /* 这条命已经掉控: 之后一律不再写怒气 */
bool   g_bVisionWroteFull[MAXPLAYERS + 1]; /* 怒气已被我们写到 100(但引擎还没真掉控, 出生保护期常见) */
bool   g_bVisionDropTried[MAXPLAYERS + 1]; /* 已经尝试过插件强制掉控 */
float  g_fVisionFullAt[MAXPLAYERS + 1];    /* 怒气第一次满 100 的时刻 */
float  g_fVisionUnseenAt[MAXPLAYERS + 1];  /* 本轮“看不见”开始时刻(0=看得见/未跟踪) */
bool   g_bVisionPenalty[MAXPLAYERS + 1];   /* 是否已经进入“扣控制权”状态 */
bool   g_bVisionAnnounced[MAXPLAYERS + 1]; /* 该坦克已经全服播报过“插件接管控制权”(每辆坦克只播一次, 与 penalty 的反复切换无关) */
bool   g_bVisionTracHit[MAXPLAYERS + 1];   /* 这辆坦克的跟踪石命中过生还者(加成状态) */
float  g_fVisionTracAt[MAXPLAYERS + 1];    /* 跟踪石命中时刻(tankcontrol_trac_after>0 时用来算到期) */
int    g_iVisionMeter[MAXPLAYERS + 1];     /* 上次观察到的怒气原始值(不含本插件自己的写入) */
float  g_fVisionEngineAt[MAXPLAYERS + 1];   /* 上次观察到"引擎自己让怒气上涨"的时刻(判游戏是否在掉控) */
float  g_fVisionMeterF[MAXPLAYERS + 1];     /* 插件接管时的怒气读数(浮点): 每秒 += 速率, 直接覆盖写 m_frustration */
float  g_fVisionPayAt[MAXPLAYERS + 1];      /* 上次"插件强制扣控"的时刻(与游戏掉控频率一致: 每秒一笔) */
float  g_fVisionSampleAt[MAXPLAYERS + 1];  /* 上次结算时刻 */
float  g_fVisionChatAt[MAXPLAYERS + 1];    /* 每秒一条调试日志的节流 */
float  g_fVisionRangeOverride;             /* 测试指令强制的可见范围(<=0 = 不强制) */
float  g_fVisionRangeOverrideUntil;        /* 强制范围的到期时刻(0 = 不过期) */

/* 存活计时的口径是"一辆坦克", 不是"一个控制者":
   同一辆坦克被给克/二控交给下一位玩家时, 存活秒数必须接着算(否则 start_time /
   alive_time / 阶梯范围这些"按时间生效"的规则每次交接都从头开始 = 时间相关的
   控制权消耗量失效); 只有新 spawn 的一辆坦克才从 0 开始。
   交接信息有两条通道: 交接钩子点名的 carry(控制权交接), 以及"坦克暂时没人控"时
   留下的孤儿记录(掉控瞬间到下一个控制者接手之间)。 */
#define VISION_CARRY_WINDOW	 10.0			   /* 交接/孤儿记录的有效窗口(秒), 过期作废 */
float  g_fVisionCarryAlive[MAXPLAYERS + 1];	   /* 交接钩子交给某个新控制者的"已存活秒数" */
float  g_fVisionCarryAt[MAXPLAYERS + 1];	   /* 上面这条记录的写入时刻(过期校验用) */
bool   g_bVisionCarryValid[MAXPLAYERS + 1];	   /* 该玩家有一条待接手的存活秒数 */
float  g_fVisionOrphanAlive;				   /* 坦克暂时没人控时留下的已存活秒数(等下一个控制者) */
float  g_fVisionOrphanAt;					   /* 上面这条记录的写入时刻(过期校验用) */
bool   g_bVisionCarriedOut[MAXPLAYERS + 1];	   /* 这个控制者的存活秒数已经通过交接钩子交出去了, 不要再存孤儿 */


/* -----------------------------------------------------------
	跟踪石平衡功能(原 l4d_tracerock.sp 新增功能迁移至此)
----------------------------------------------------------- */
bool  g_bHasTracePlugin;					  /* l4d_tracerock.smx 是否已加载(未加载时跟踪功能不存在) */
bool  g_bLateLoad;
bool  g_bTraceRock[TRAC_ROCK_MAX + 1];		  /* 该 tank_rock 是否为跟踪石 */
float g_fRockDamage[TRAC_ROCK_MAX + 1];		  /* 跟踪石累计承受的伤害 */
int	  g_iRockCharge[TRAC_ROCK_MAX + 1];		  /* 掷出该跟踪石时已扣的血量(命中生还者则退还) */
int	  g_iLastTracTarget[MAXPLAYERS + 1];	  /* 该坦克上一发跟踪石命中的生还者(禁止连续命中同一人) */

/* -----------------------------------------------------------
	石头轨迹预测(!pred)状态
----------------------------------------------------------- */
/* 坦克出生提示: 一次性推 7 条聊天会被聊天框挤掉(只看到最后一条), 所以按 0.35 秒一条逐条发 */
int	   g_iHintLine[MAXPLAYERS + 1];
bool   g_bHintActive[MAXPLAYERS + 1];
int	   g_iHeldRock[MAXPLAYERS + 1]; /* 该坦克当前握在手里(还没掷出)的 tank_rock 的 entref, 无则 INVALID_ENT_REFERENCE */
int	   g_iBeamSprite;				/* materials/sprites/laserbeam.vmt 的预缓存索引 */
float  g_fPredLogAt[MAXPLAYERS + 1];	/* 调试日志节流时间戳 */
float  g_fPredTestUntil[MAXPLAYERS + 1]; /* !predtest 测试线截止时间(任何玩家可用) */
float  g_fPredUntil[MAXPLAYERS + 1];	 /* "坦克正在扔石头"窗口截止时间(由起手动作开启, 掷出/超时结束) */
bool   g_bPredActive[MAXPLAYERS + 1];	 /* 上一帧是否处于扔石过程(用于只记一次开始/结束日志) */
/* 按投掷姿势学到的"出手偏移"(车身坐标系: 右/上/前), 下标 = 动作号-48 (49/50/51 -> 1/2/3);
   0 号槽 = 本发起手瞬间的快照。用固定值而不是实时跟随手臂, 线才不会跟挥臂动画一起摆。 */
float  g_fPredPoseOff[MAXPLAYERS + 1][4][3];
bool   g_bPredPoseOk[MAXPLAYERS + 1][4];
int	   g_iPredPoseSlot[MAXPLAYERS + 1];
float  g_fPredVelSmooth[MAXPLAYERS + 1][3]; /* 坦克自身速度平滑值(同样在车身坐标系里) */
bool   g_bPredVelInit[MAXPLAYERS + 1];
float  g_fPredDbgUntil[MAXPLAYERS + 1];	/* 逐帧抖动诊断的输出截止时间 */
float  g_fPredEmitAt[MAXPLAYERS + 1];	/* 上次发射光束的时间(用于发射节流) */
float  g_fPredLockout[MAXPLAYERS + 1];	/* 掷出后的锁定期: 收招阶段引擎还会重选投掷动作, 这段时间不许重开窗口 */
bool   g_bPredStartLogged[MAXPLAYERS + 1];
float  g_fPredPrevStart[MAXPLAYERS + 1][3];
float  g_fPredPrevAng[MAXPLAYERS + 1][3];
float  g_fPredPrevVel[MAXPLAYERS + 1];
bool   g_bPredSmoothInit[MAXPLAYERS + 1];
/* 抛物线缓存: 每帧只重发光束, 重算按 tank_pred_interval 节流(参考 miwuki 的 Calc_Interval)。
   缓存的就是"画线用的采样点", 所以一帧的重发光束开销是固定的十几段, 不含任何 trace。 */
float  g_fPredDraw[MAXPLAYERS + 1][PRED_SEG_MAX + 1][3]; /* 采样后的线段端点 */
int	   g_iPredDrawCount[MAXPLAYERS + 1];				 /* 端点数(>=2 才画) */
float  g_fPredImpact[MAXPLAYERS + 1][3];				 /* 命中点(落点标记用) */
bool   g_bPredHasImpact[MAXPLAYERS + 1];				 /* 是否真的撞到东西(没撞就不画落点标记) */
float  g_fPredCalcAt[MAXPLAYERS + 1];					 /* 上次重算时间 */
float  g_fPredImpactTime[MAXPLAYERS + 1];			 /* 预测的飞行时间(命中时刻, 没命中=最长预测时间) */
int	   g_iPredHitEnt[MAXPLAYERS + 1];				 /* 预测停在哪: 命中的实体索引(0=世界) */
/* 隐形物理阻挡体名单(env_physics_blocker): 只挡物理道具, 石头直接穿过去, 所以预测里要忽略。
   在真实命中时按类名学习, 学到一个就记下来, 之后所有 trace 的过滤器都会跳过它 */
bool   g_bPredIgnoreEnt[2049];
int	   g_iPredIgnored;
bool   g_bPredMarkLogged[MAXPLAYERS + 1];		 /* 本发是否已经记过"落点标记"日志 */
int	   g_iPredSeq[MAXPLAYERS + 1];				 /* 本发的投掷动作号(49/50/51 = 不同姿势) */
float  g_fPredGravity[MAXPLAYERS + 1];			 /* 本次计算用的重力(调试: 确认 sv_gravity*倍率) */
/* 石头实飞记录(调试用): 掷出后逐帧采位置, 石头碎裂时打印"实际落点/实飞时间"与预测的对比 */
int	   g_iFlyRock[MAXPLAYERS + 1];					 /* 在飞的石头 entref */
bool   g_bFlyActive[MAXPLAYERS + 1];
float  g_fFlyStartTime[MAXPLAYERS + 1];
float  g_fFlyLastPos[MAXPLAYERS + 1][3];
float  g_fFlyPredPos[MAXPLAYERS + 1][3];
float  g_fFlyPredTime[MAXPLAYERS + 1];
bool   g_bFlyPredHit[MAXPLAYERS + 1];
float  g_fPredLastStart[MAXPLAYERS + 1][3];				 /* 上次重算时的起点 */
float  g_fPredLastVel[MAXPLAYERS + 1][3];				 /* 上次重算时的初速 */
float  g_fPredLastAng[MAXPLAYERS + 1][3];				 /* 上次重算时的瞄准角度 */
ConVar g_hSvGravity;				/* sv_gravity: 石头重力 = sv_gravity * 0.4 */
ConVar g_hThrowForce;				/* z_tank_throw_force: 石头出石初速 */
ConVar g_hTankSwapMenuSecs;			/* l4d2_tank_swap 的 l4d_tankswap_menudisplay(选克面板显示秒数), 取不到时按 5 秒 */

public Plugin myinfo =
{
	name		= PLG_NAME,
	author		= PLG_AUTH,
	description = PLG_DESC,
	version		= PLG_VERS,
	url			= PLG_URLS,


}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	MarkNativeAsOptional("TankAttackControl_GetThrowSequence");
	MarkNativeAsOptional("GetTankSelection");
	RegPluginLibrary("Apex");
	CreateNative("Apex_IsBhopEnabled", Native_IsBhopEnabled);
	CreateNative("Apex_IsTracEnabled", Native_IsTracEnabled);
	CreateNative("Apex_IsPredEnabled", Native_IsPredEnabled);
	CreateNative("Apex_GetTracBlockedTarget", Native_GetTracBlockedTarget);
	/* 技能扣血 forward: 把不经由伤害事件的技能扣血/退还告知伤害统计类插件(如 tank_damage) */
	g_hFwdSkillCost = CreateGlobalForward("Apex_OnSkillCostCharged", ET_Ignore, Param_Cell, Param_Cell, Param_Cell);
	/* 跟踪石命中 forward: 命中生还者时通知控制权插件(如修改版 l4d_tank_control_eq)做控制权调整 */
	g_hFwdTracRockHit = CreateGlobalForward("Apex_OnTracRockHit", ET_Ignore, Param_Cell, Param_Cell);
	g_bLateLoad = late;

	return APLRes_Success;
}

/* 通报"跟踪石命中生还者": tank = 掷石坦克, victim = 被命中的生还者 */
void FireTracRockHit(int tank, int victim)
{
	/* 坦克视野的"跟踪石命中"加成状态(与控制权插件口径一致: 命中后到坦克死亡/交接为止)。
	   这里先记状态再发通知, 保证即使没人监听 forward 加成也生效。 */
	if (tank > 0 && tank <= MaxClients)
	{
		g_bVisionTracHit[tank] = true;
		g_fVisionTracAt[tank]  = GetGameTime();
	}

	if (g_hFwdTracRockHit == null)
		return;

	Call_StartForward(g_hFwdTracRockHit);
	Call_PushCell(tank);
	Call_PushCell(victim);
	Call_Finish();
}

/* 通报技能扣血/退还: cost 为本次血量变化量(扣血为正, 退还为负), 0 不通报 */
void FireSkillCost(int client, ApexSkillCostType type, int cost)
{
	if (g_hFwdSkillCost == null || cost == 0 || !IsValidClient(client))
		return;

	Call_StartForward(g_hFwdSkillCost);
	Call_PushCell(client);
	Call_PushCell(view_as<int>(type));
	Call_PushCell(cost);
	Call_Finish();
}

/* 供 l4d_tracerock.sp 选人使用: 返回该坦克本发跟踪石应排除的生还者(0=无约束) */
public int Native_GetTracBlockedTarget(Handle plugin, int numParams)
{
	int tank = GetNativeCell(1);
	if (tank < 1 || tank > MaxClients)
		return 0;

	return g_iLastTracTarget[tank];
}

public int Native_IsBhopEnabled(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients)
		return 0;

	return IsBhop[client] ? 1 : 0;
}

public int Native_IsTracEnabled(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients)
		return 0;

	return IsTrac[client] ? 1 : 0;
}

public int Native_IsPredEnabled(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients)
		return 0;

	return IsPred[client] ? 1 : 0;
}

public void
	OnPluginStart()
{
	Apex[0] = CreateConVar("l4d2_block_punch_rock", "1", "阻止坦克同时出拳和扔石头 0-不阻止 1-阻止");
	Apex[1] = CreateConVar("l4d2_block_jump_rock", "0", "阻止坦克同时跳跃和扔石块 0-不阻止 1-阻止");
	Apex[2] = CreateConVar("tank_hp", "0", "坦克设置为多少血量? 0=禁用");
	Apex[3] = CreateConVar("tank_bohp_hp", "1500", "开启坦克连跳时扣血量.0为禁用");
	Apex[4] = CreateConVar("tank_trac_hp", "1000", "开启石头追踪时扣血量.0为禁用");
	Apex[5] = CreateConVar("tank_trac_throw_hp", "50", "每掷出一发跟踪石头扣除的自身血量.0为禁用");
	Apex[6] = CreateConVar("l4d_tracerock_health", "40", "跟踪石血量(点). 生还者打掉这些血量即可在空中打碎跟踪石. 0=不接管(用游戏默认血量)");
	Apex[7] = CreateConVar("tank_bhop_detect", "1", "坦克连跳检测: 未开启!bhop技能的坦克成功连跳时补扣技能血量并通报全场 0=禁用 1=启用", _, true, 0.0, true, 1.0);
	Apex[8] = CreateConVar("tank_bhop_detect_count", "10", "连续完美连跳达到该次数即判定为成功连跳(参考liac的min档位).0=禁用", _, true, 0.0);
	Apex[9] = CreateConVar("tank_bhop_detect_air", "0.3", "两次连跳之间的最小滞空时间(秒), 参考liac的air设置(>1.0按1.0算)", _, true, 0.0, true, 1.0);
	Apex[10] = CreateConVar("l4d_tracerock_fly_sound", "2.0", "跟踪石飞行音效最长播放时间(秒): 超时强制停止石头飞行循环音效(防止绕圈时一直响). 0=不处理", _, true, 0.0);
	Apex[11] = CreateConVar("tank_pred_hp", "500", "开启坦克石头轨迹预测(!pred)时扣血量. 0=禁用");
	Apex[12] = CreateConVar("tank_pred_speed", "0", "石头轨迹预测用的出石初速(点/秒). 0=自动取 z_tank_throw_force", _, true, 0.0);
	Apex[13] = CreateConVar("tank_pred_gravity", "0.4", "石头轨迹预测用的重力倍率(加速度 = sv_gravity * 该值). 实测石头为 0.4", _, true, 0.0, true, 10.0);
	Apex[14] = CreateConVar("tank_pred_time", "4.5", "石头轨迹预测的最长飞行时间(秒)", _, true, 0.1, true, 5.0);
	Apex[15] = CreateConVar("tank_pred_seg", "16", "石头轨迹线最多分几段(段数越多越平滑, 也越耗带宽)", _, true, 2.0, true, 64.0);
	Apex[16] = CreateConVar("tank_pred_debug", "0", "石头轨迹预测调试输出: 0=关 1=关键(命令结果/掷出对比/掷出后实际轨迹回显) 2=详细(每次蓄力是否识别/贴图索引/画线详情)", _, true, 0.0, true, 2.0);
	Apex[17] = CreateConVar("tank_pred_width", "3.0", "石头轨迹线宽度", _, true, 1.0, true, 20.0);
	Apex[18] = CreateConVar("tank_pred_forward", "24.0", "轨迹线起点从眼睛往前推的距离(点): 让线不像从脸上冒出来, 同时避开坦克自身碰撞盒. 0=就从眼睛起", _, true, 0.0, true, 64.0);
	Apex[19] = CreateConVar("tank_pred_smooth", "0.75", "保留项(用于坦克速度平滑权重): 0=不平滑, 越大越稳. 出手偏移已改为按姿势学习, 不再跟手臂动画", _, true, 0.0, true, 0.9);
	Apex[20] = CreateConVar("tank_pred_skip_len", "120.0", "轨迹线靠坦克这一端不画的长度(点): 默认 120(约一个坦克身位), 只挡掉贴脸那一段, 不再按比例砍整条线. 0=全画", _, true, 0.0, true, 600.0);
	Apex[21] = CreateConVar("tank_pred_mark_h", "400.0", "落点标记: 命中处向上的蓝色垂直线(光柱)高度(点). 0=不画", _, true, 0.0, true, 1024.0);
	Apex[22] = CreateConVar("tank_pred_ring", "36.0", "落点标记: 命中处白色圆圈的半径(点). 0=不画", _, true, 0.0, true, 128.0);
	Apex[23] = CreateConVar("tank_pred_interval", "0.01", "抛物线重算最小间隔(秒): 每帧只重发光束, 重算受此节流(越大越省性能)", _, true, 0.0, true, 0.5);
	Apex[24] = CreateConVar("tank_pred_batch", "6.0", "抛物线批量检测步数: 空域一次扫 6 步, 疑似碰撞再逐步精查; 1=禁用批量(最费但最稳)", _, true, 1.0, true, 8.0);
	Apex[27] = CreateConVar("tank_pred_lockout", "0.6", "掷出后的锁定期(秒): 收招阶段引擎还会重选投掷动作, 这段时间内不重开预测窗口(否则石头离手后线会再出现, 而且会取到收招姿势让线画在脚边)", _, true, 0.0, true, 3.0);
	Apex[26] = CreateConVar("tank_pred_emit", "0.033", "光束发射间隔(秒): 越小越跟手但残影越多(残影=多条线叠在一起). 30Hz 配光束寿命 0.055 秒刚好一条线", _, true, 0.01, true, 0.2);
	Apex[25] = CreateConVar("tank_pred_off_r", "14.0", "画线视觉右移(点): 整条线往准星右侧让开避免挡视线, 末端收敛到真实落点. 0=不偏移", _, true, 0.0, true, 64.0);

	/* 坦克视野(原 l4d2_tank_vision.sp): 判定口径 / 范围阶梯 / 额外扣控
	   扣控只有两项加成(跟踪石命中 / 存活满门限); step <=0 时自动读 tankcontrol_trac_base,
	   alive_time <0 时自动读 tankcontrol_trac_longlife_time(读不到就视为关闭)。 */
	Apex[APEX_TV_ENABLE]      = CreateConVar("l4d2_tankvision_enable", "1", "坦克视野: 1=接管(看得见就不掉控; 看不见时按跟踪石命中/存活满门限额外扣控制权) 0=关闭(原版行为)", _, true, 0.0, true, 1.0);
	Apex[APEX_TV_RANGE]       = CreateConVar("l4d2_tankvision_range", "2000.0", "基准可见范围(单位): 未到阶梯门槛时用这个值, 0=无限");
	Apex[APEX_TV_DOT]         = CreateConVar("l4d2_tankvision_dot", "0.7", "朝向锥: 坦克视线与目标方向点积下限. 0.7≈±45°(与引擎 z_alert_dot 同源), 写 -1 只退化成前半球", _, true, -1.0, true, 1.0);
	Apex[APEX_TV_INTERVAL]    = CreateConVar("l4d2_tankvision_interval", "0.2", "视野判定间隔(秒)", _, true, 0.05, true, 1.0);
	Apex[APEX_TV_DEBUG]       = CreateConVar("l4d2_tankvision_debug", "2", "调试输出(聊天框+服务器日志): 0=安静 1=每秒一条(发给坦克本人, 含是否看得见) 2=再加范围收紧/开始扣控/每笔扣控日志", _, true, 0.0, true, 2.0);
	Apex[APEX_TV_T1_TIME]     = CreateConVar("l4d2_tankvision_t1_time", "270.0", "阶梯1: 坦克存活满多少秒开始收紧可见范围(0=禁用该档)");
	Apex[APEX_TV_T1_RANGE]    = CreateConVar("l4d2_tankvision_t1_range", "1000.0", "阶梯1: 收紧后的可见范围(单位)");
	Apex[APEX_TV_T2_TIME]     = CreateConVar("l4d2_tankvision_t2_time", "330.0", "阶梯2: 坦克存活满多少秒进一步收紧(0=禁用该档)");
	Apex[APEX_TV_T2_RANGE]    = CreateConVar("l4d2_tankvision_t2_range", "750.0", "阶梯2: 收紧后的可见范围(单位)");
	Apex[APEX_TV_T3_TIME]     = CreateConVar("l4d2_tankvision_t3_time", "390.0", "阶梯3: 坦克存活满多少秒收到最紧(0=禁用该档)");
	Apex[APEX_TV_T3_RANGE]    = CreateConVar("l4d2_tankvision_t3_range", "500.0", "阶梯3: 收紧后的可见范围(单位)");
	Apex[APEX_TV_NOTIFY]      = CreateConVar("l4d2_tankvision_notify", "1", "可见范围收紧 / 开始扣控制权时通知全体玩家(0=不通知 1=通知)", _, true, 0.0, true, 1.0);
	Apex[APEX_TV_STEP]        = CreateConVar("l4d2_tankvision_step", "5.0", "基础扣控幅度(%%/秒), 默认 5. 这就是「正常 5%%」那一档, 不再自动读别的插件");
	Apex[APEX_TV_SEEN_CLEAR]  = CreateConVar("l4d2_tankvision_seen_clear", "0", "看得见生还者时是否把怒气写回 0(1=清, 坦克不会掉控; 0=不干预, 交给引擎原生判断)", _, true, 0.0, true, 1.0);
	Apex[APEX_TV_START_TIME]  = CreateConVar("l4d2_tankvision_start_time", "240.0", "坦克存活满多少秒后本插件才接管控制权(秒). 默认 240 = 4 分钟", _, true, 0.0);
	Apex[APEX_TV_ALIVE_TIME]  = CreateConVar("l4d2_tankvision_alive_time", "240.0", "坦克存活满多少秒后, 每秒扣控再加 1 个百分点(秒). 默认 240 = 4 分钟", _, true, 0.0);
	Apex[APEX_TV_ALIVE_EXTRA] = CreateConVar("l4d2_tankvision_alive_extra", "1.0", "存活满 alive_time 后每秒多加的百分点", _, true, 0.0, true, 100.0);
	Apex[APEX_TV_TRAC_EXTRA]  = CreateConVar("l4d2_tankvision_trac_extra", "1.0", "跟踪石命中过生还者后, 每秒多加的百分点", _, true, 0.0, true, 100.0);
	Apex[APEX_TV_FORCE]       = CreateConVar("l4d2_tankvision_force", "1", "0=游戏自己也在掉控时让位(用游戏原生的) 1=不管游戏, 插件总是强制按 5/6/7% 每秒扣", _, true, 0.0, true, 1.0);
	Apex[APEX_TV_GATE]        = CreateConVar("l4d2_tankvision_gate", "0", "默认 0=完全不碰引擎内存(怒气闸门保持引擎自己的值). 1=强制打开(引擎恢复原生累积) 2=只在插件扣满100时打开", _, true, 0.0, true, 2.0);
	Apex[APEX_TV_FORCE_DROP]  = CreateConVar("l4d2_tankvision_force_drop", "0", "1=怒气扣满 100 后引擎不判掉控时, 由插件用原生 ReplaceTank 走二控(有玩家)/交给AI(没玩家); 0=只在怒气满时挂着等引擎", _, true, 0.0, true, 1.0);
	Apex[APEX_TV_FORCE_BLIND] = CreateConVar("l4d2_tankvision_force_blind", "1", "1=插件判定看不见时, 把引擎记录的「最后看见生还者时刻」写老, 让引擎自己也判定看不见 -> 走原生掉控(有玩家=二控, 没玩家=AI); 0=不碰引擎内存", _, true, 0.0, true, 1.0);

	/* 版本/关键参数落一条日志: 现场核对"服务器跑的到底是不是这个 build" */
	LogMessage("[tankvision] build %s loaded: enable=%d base=%.1f start=%.0fs alive=%.0fs extra=%.1f/%.1f force=%d seen_clear=%d",
		PLG_VERS, Apex[APEX_TV_ENABLE].IntValue, VisionBaseStep(), VisionStartTime(), VisionAliveTime(),
		Apex[APEX_TV_ALIVE_EXTRA].FloatValue, Apex[APEX_TV_TRAC_EXTRA].FloatValue,
		Apex[APEX_TV_FORCE].IntValue, Apex[APEX_TV_SEEN_CLEAR].IntValue);

	/* -1 = 还没观察过这辆坦克(和“0 = 无限”区分开) */
	for (int i = 1; i <= MaxClients; i++)
		g_fVisionRangeMark[i] = -1.0;

	/* 怒气闸门偏移(用于 l4d2_tankvision_gate): 读不到就用默认 Windows 偏移 */
	g_hTVGateConf = LoadGameConfigFile("apex_tank_vision");
	if (g_hTVGateConf != null)
	{
		int iOff = GameConfGetOffset(g_hTVGateConf, "TankGateOffset");
		if (iOff > 0)
			g_iTVGateOffset = iOff;

		iOff = GameConfGetOffset(g_hTVGateConf, "TankLastSeenOffset");
		if (iOff > 0)
			g_iTVLastSeenOffset = iOff;
		CloseHandle(g_hTVGateConf);
		g_hTVGateConf = null;
	}

	Apex[APEX_TV_ENABLE].AddChangeHook(OnTankVisionCvarChanged);
	Apex[APEX_TV_INTERVAL].AddChangeHook(OnTankVisionCvarChanged);
	StartTankVisionTimer();

	/* 石头轨迹预测用到的游戏 cvar: 缓存句柄, 避免每帧 FindConVar */
	g_hSvGravity  = FindConVar("sv_gravity");		 /* 引擎 cvar, L4D2 恒存在; 取不到时按 800 兜底 */
	g_hThrowForce = FindConVar("z_tank_throw_force"); /* 服务端 cvar, 默认 800; 取不到时按 800 兜底 */

	/* 版本标记 + 重力自检: 只在 tank_pred_debug >= 1 时写日志。
	   默认 0 时插件完全静默(不写日志、不发聊天), 部署核对时临时 sm_cvar tank_pred_debug 1 看一眼再设回 0。 */
	if (Apex[16].IntValue >= PRED_DEBUG_KEY)
	{
		LogMessage("[!pred] 坦克石头轨迹预测 build %s 已加载(tank_pred_debug=%d)", PRED_BUILD, Apex[16].IntValue);

		if (g_hSvGravity == null)
			LogMessage("[!pred] 警告: 没找到 sv_gravity, 重力按 800 兜底(可能与实际不符!)");
		else
			LogMessage("[!pred] sv_gravity=%.1f -> 石头重力=%.1f (倍率 tank_pred_gravity=%.2f)",
					   g_hSvGravity.FloatValue, g_hSvGravity.FloatValue * Apex[13].FloatValue, Apex[13].FloatValue);
	}

	for (int i = 1; i <= MaxClients; i++)
		g_iHeldRock[i] = INVALID_ENT_REFERENCE;

	HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Pre);
	HookEvent("player_jump_apex", Event_PlayerJumpApex);
	HookEvent("tank_spawn", Event_TankSpawn);
	HookEvent("tank_frustrated", Event_TankFrustrated);
	HookEvent("round_end", Event_RoundEnd);

	RegConsoleCmd("sm_trac", Call_Trac);
	RegConsoleCmd("sm_bhop", Call_Bohp);
	RegConsoleCmd("sm_pred", Call_Pred);
	RegConsoleCmd("sm_gz", Call_Trac);
	RegConsoleCmd("sm_lt", Call_Bohp);
	RegConsoleCmd("sm_yc", Call_Pred);
	/* 调试用: 不看技能/不看蓄力, 直接按当前瞄准画线, 用来单独验证"线能不能画出来"(管理员) */
	RegAdminCmd("sm_predtest", Call_PredTest, ADMFLAG_ROOT, "石头轨迹预测自检: 立即画 N 秒预测线 (默认 3 秒)");

	/* 坦克视野测试指令(与原 l4d2_tank_vision.sp 同名, 便于沿用习惯) */
	RegConsoleCmd("sm_tankvision", Cmd_TankVision, "查看当前坦克的视野判定/扣控制权状态");
	RegConsoleCmd("sm_tankvision_dbg", Cmd_TankVisionDebug, "坦克视野调试档位: 0=安静 1=每秒一条(含是否看得见) 2=再加范围/扣控日志");
	RegConsoleCmd("sm_tankvision_set", Cmd_TankVisionSet, "测试: 强制当前坦克可见范围 sm_tankvision_set <范围> [秒], 0=取消");
	RegConsoleCmd("sm_tankvision_time", Cmd_TankVisionTime, "调试: 查看/改插件统计的坦克存活时间 sm_tankvision_time [秒|+N|-N]");
	RegConsoleCmd("sm_tankvision_trac", Cmd_TankVisionTrac, "调试: 查看/改坦克的跟踪石命中加成 sm_tankvision_trac [0|1]");
	RegAdminCmd("sm_tankvision_frust", Cmd_TankVisionFrust, ADMFLAG_ROOT, "查看/设置当前坦克怒气 sm_tankvision_frust [值] (0=满控制权, 100=掉控)");

	if (g_bLateLoad)
	{
		for (int i = 1; i <= MaxClients; i++)
			if (IsClientInGame(i))
				OnClientPutInServer(i);
	}
}

public void OnAllPluginsLoaded()
{
	g_bHasTracePlugin = LibraryExists("L4D_OnTraceRockCreated");

	/* 坦克视野的"参考幅度"来自控制权插件的 cvar: 这里缓存句柄(取不到就按内置默认) */
	g_hTankVisionControlAfter      = FindConVar("tankcontrol_trac_after");
}

/* -----------------------------------------------------------
	命令回调
----------------------------------------------------------- */
Action Call_Trac(int client, int args)
{
	if (!IsTank(client))
	{
		return Plugin_Handled;
	}

	int mumhp = Apex[4].IntValue;
	int hp	  = GetEntProp(client, Prop_Data, "m_iHealth");

	/* 已开，那么关闭 */
	if (IsTrac[client])
	{
		IsTrac[client] = false;
		CPrintToChat(client, "%sTank石头追踪已关闭", TAG);

		return Plugin_Handled;
	}

	/* 与"轨迹预测"互斥: 开跟踪石头就把预测关掉(用户要求: 跟踪开着时不显示预测) */
	if (IsPred[client])
	{
		IsPred[client] = false;
		CPrintToChat(client, "%s已开启跟踪石头, 轨迹预测自动关闭", TAG);
		LogMessage("[!pred] %N: 开启跟踪石头 -> 自动关闭轨迹预测", client);
	}

	/* 已关 */
	if (TracLim[client] == 1) /* 本命已经付过开启费，随时开关，不再扣血 */
	{
		IsTrac[client] = true;
		CPrintToChat(client, "%sTank石头追踪已开启(本命已扣过开启费)", TAG);
	}
	else if (mumhp <= 0) /* 开启费为 0，直接开启 */
	{
		IsTrac[client]	 = true;
		TracLim[client]	 = 1;
		CPrintToChat(client, "%sTank石头追踪已开启", TAG);
	}
	else if (hp - mumhp > 0) /* 血足，扣开启费后开启 */
	{
		IsTrac[client]	 = true;
		TracLim[client]	 = 1;
		SetEntProp(client, Prop_Data, "m_iHealth", hp - mumhp);
		FireSkillCost(client, ApexSkillCost_TracEnable, mumhp);
		CPrintToChat(client, "%sTank石头追踪已开启(扣 %d 血)", TAG, mumhp);
	}
	else /* 血不足，保持关闭 */
	{
		IsTrac[client] = false;
		CPrintToChat(client, "%sTank石头追踪未开启(当前血量不足以扣除 %d 血)", TAG, mumhp);
	}

	return Plugin_Handled;
}
Action Call_Bohp(int client, int args)
{
	if (!IsTank(client))
		return Plugin_Handled;

	int mumhp = Apex[3].IntValue;
	int hp	  = GetEntProp(client, Prop_Data, "m_iHealth");

	/* 已开，那么关闭 */
	if (IsBhop[client])
	{
		IsBhop[client] = false;
		CPrintToChat(client, "%sTank自动连跳已关闭", TAG);
		return Plugin_Handled;
	}

	/* 已关 */
	if (BhopLim[client] == 1) /* 本命已经付过开启费，随时开关，不再扣血 */
	{
		IsBhop[client] = true;
		CPrintToChat(client, "%sTank自动连跳已开启(本命已扣过开启费)", TAG);
	}
	else if (mumhp <= 0) /* 开启费为 0，直接开启 */
	{
		IsBhop[client]	= true;
		BhopLim[client] = 1;
		CPrintToChat(client, "%sTank自动连跳已开启", TAG);
	}
	else if (hp - mumhp > 0) /* 血足，扣开启费后开启 */
	{
		IsBhop[client]	= true;
		BhopLim[client] = 1;
		SetEntProp(client, Prop_Data, "m_iHealth", hp - mumhp);
		FireSkillCost(client, ApexSkillCost_Bhop, mumhp);
		CPrintToChat(client, "%sTank自动连跳已开启(扣 %d 血)", TAG, mumhp);
	}
	else /* 血不足，保持关闭 */
	{
		IsBhop[client] = false;
		CPrintToChat(client, "%sTank自动连跳未开启(当前血量不足以扣除 %d 血)", TAG, mumhp);
	}

	return Plugin_Handled;
}

/* 石头轨迹预测: 本命首次开启扣 tank_pred_hp 血, 之后同一命内开关不再扣血 */
Action Call_Pred(int client, int args)
{
	if (!IsTank(client))
	{
		/* 非坦克时静默返回(与 !trac/!bhop 一致), 但调试档位下要说清楚, 免得以为"插件没反应" */
		if (IsValidClient(client) && Apex[16].IntValue >= PRED_DEBUG_KEY)
		{
			CPrintToChat(client, "%s{olive}[pred]{default} 只有坦克能开这个技能(你现在不是坦克)", TAG);
			LogMessage("[!pred] %N 用了 !pred 但不是坦克, 已忽略", client);
		}
		return Plugin_Handled;
	}

	int mumhp = Apex[11].IntValue;
	int hp	  = GetEntProp(client, Prop_Data, "m_iHealth");

	/* 已开，那么关闭 */
	if (IsPred[client])
	{
		IsPred[client] = false;
		PredLog(client, PRED_DEBUG_KEY, "Tank石头轨迹预测已关闭");
		CPrintToChat(client, "%sTank石头轨迹预测已关闭", TAG);

		return Plugin_Handled;
	}

	/* 与"跟踪石头"互斥: 开预测就把跟踪关掉 */
	if (IsTrac[client])
	{
		IsTrac[client] = false;
		CPrintToChat(client, "%s已开启轨迹预测, 跟踪石头自动关闭", TAG);
		LogMessage("[!pred] %N: 开启轨迹预测 -> 自动关闭跟踪石头", client);
	}

	/* 已关 */
	if (PredLim[client] == 1) /* 本命已经付过开启费，随时开关，不再扣血 */
	{
		IsPred[client] = true;
		PredLog(client, PRED_DEBUG_KEY, "Tank石头轨迹预测已开启(本命已扣过开启费)");
		CPrintToChat(client, "%sTank石头轨迹预测已开启(本命已扣过开启费)", TAG);
	}
	else if (mumhp <= 0) /* 开启费为 0，直接开启 */
	{
		IsPred[client]	= true;
		PredLim[client] = 1;
		PredLog(client, PRED_DEBUG_KEY, "Tank石头轨迹预测已开启(开启费为 0)");
		CPrintToChat(client, "%sTank石头轨迹预测已开启", TAG);
	}
	else if (hp - mumhp > 0) /* 血足，扣开启费后开启 */
	{
		IsPred[client]	= true;
		PredLim[client] = 1;
		SetEntProp(client, Prop_Data, "m_iHealth", hp - mumhp);
		FireSkillCost(client, ApexSkillCost_PredEnable, mumhp);
		PredLog(client, PRED_DEBUG_KEY, "Tank石头轨迹预测已开启(扣 %d 血, 剩 %d)", mumhp, hp - mumhp);
		CPrintToChat(client, "%sTank石头轨迹预测已开启(扣 %d 血)", TAG, mumhp);
	}
	else /* 血不足，保持关闭 */
	{
		IsPred[client] = false;
		PredLog(client, PRED_DEBUG_KEY, "Tank石头轨迹预测未开启(血 %d 不足以扣 %d)", hp, mumhp);
		CPrintToChat(client, "%sTank石头轨迹预测未开启(当前血量不足以扣除 %d 血)", TAG, mumhp);
	}

	return Plugin_Handled;
}

/* 自检指令: 不看技能、不看是否在蓄力, 直接按当前瞄准画 N 秒预测线。
   用来把"线画不出来"和"蓄力/技能判定没通过"两种情况分开。 */
Action Call_PredTest(int client, int args)
{
	if (!IsValidClient(client))
		return Plugin_Handled;

	float duration = (args >= 1) ? float(GetCmdArgInt(1)) : 3.0;
	if (duration < 1.0)
		duration = 1.0;
	if (duration > 10.0)
		duration = 10.0;

	g_fPredTestUntil[client] = GetGameTime() + duration;
	g_bPredSmoothInit[client] = false;
	g_fPredCalcAt[client]	 = 0.0; /* 强制立刻重算一次(自检要马上出线) */
	g_iPredDrawCount[client] = 0;

	float angles[3], start[3], vel[3];
	GetClientEyeAngles(client, angles);
	GetPredStart(client, angles, start);
	GetPredVelocity(client, angles, vel);

	LogMessage("[!pred] %N 自检: %.1f 秒, 起点(%.0f,%.0f,%.0f) 初速(%.0f,%.0f,%.0f) 贴图索引=%d 宽=%.1f 前推=%.0f 平滑=%.2f",
			   client, duration, start[0], start[1], start[2], vel[0], vel[1], vel[2],
			   g_iBeamSprite, Apex[17].FloatValue, Apex[18].FloatValue, Apex[19].FloatValue);
	CPrintToChat(client, "%s{olive}[pred]{default} 自检线开启 %.0f 秒: 起点(%.0f, %.0f, %.0f) 贴图=%d",
				 TAG, duration, start[0], start[1], start[2], g_iBeamSprite);
	if (g_iBeamSprite <= 0)
		CPrintToChat(client, "%s{lightred}[pred]{default} 警告: 光束贴图索引为 0, 线不会显示(需要换图或重启服务器让预缓存生效)", TAG);

	return Plugin_Handled;
}

/* -----------------------------------------------------------
	事件钩子
----------------------------------------------------------- */
void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (IsValidClient(client)) Reset(client);
}
void Event_PlayerJumpApex(Event event, const char[] name, bool dontBroadcast)
{
	// 不需要处理横向速度
}
/* 坦克出生提示的第 line 条 */
void TankHint_Send(int client, int line)
{
	switch (line)
	{
		case 0:
			CPrintToChat(client, "%sE 键 -> 低手抛石(砸屋檐下)", TAG);
		case 1:
			CPrintToChat(client, "%s右键 -> 单手抛石(万能姿势)", TAG);
		case 2:
			CPrintToChat(client, "%sR 键 -> 双手抛石(过高墙)", TAG);
		case 3:
			CPrintToChat(client, "%s指令{lightgreen}!lt{darkred}开启自动连跳(扣%d血)", TAG, Apex[3].IntValue);
		case 4:
			CPrintToChat(client, "%s指令{lightgreen}!gz{darkred}开启跟踪石头(扣%d血, 石头未命中则扣%d血)", TAG, Apex[4].IntValue, Apex[5].IntValue);
		case 5:
			CPrintToChat(client, "%s指令{lightgreen}!yc{darkred}开启石头轨迹预测(扣%d血)", TAG, Apex[11].IntValue);
		case 6:
		{
			/* “给克”=把坦克移交给队友: 服务器上的 l4d2_tank_swap 在 choicetype=2 时会给每位坦克玩家
			   自动弹出选克面板(屏幕左侧, 按数字键选人). 面板显示秒数跟着它的
			   l4d_tankswap_menudisplay(默认 5 秒, 0=不自动关)走, 这里读实时值, 免得改了 cvar 提示还说旧数字;
			   面板自己标题里也带“剩余 N 秒”, 所以这里只报时长不解释倒计时. */
			int iPanel = RoundToNearest(VisionControlCvar(g_hTankSwapMenuSecs, "l4d_tankswap_menudisplay", 5.0));

			if (iPanel > 0)
				CPrintToChat(client, "%s数字键 -> 给克(屏幕左侧面板 %d 秒内选人, 把坦克让给队友)", TAG, iPanel);
			else
				CPrintToChat(client, "%s数字键 -> 给克(屏幕左侧面板选人, 把坦克让给队友)", TAG);
		}
	}
}

#define TANK_HINT_LINES 7

Action Timer_TankHint(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);

	if (!IsValidClient(client) || !IsTank(client))
	{
		if (IsValidClient(client))
			g_bHintActive[client] = false;
		return Plugin_Stop;
	}

	TankHint_Send(client, g_iHintLine[client]);
	g_iHintLine[client]++;

	if (g_iHintLine[client] >= TANK_HINT_LINES)
	{
		g_bHintActive[client] = false;
		return Plugin_Stop;
	}

	return Plugin_Continue;
}

/* 坦克出生时逐条发提示(避免一次推 7 条被聊天框挤掉) */
void TankHints_Start(int client)
{
	if (g_bHintActive[client])
		return; /* 已经有一串在发, 不重复 */

	g_iHintLine[client]	 = 0;
	g_bHintActive[client] = true;
	CreateTimer(0.35, Timer_TankHint, GetClientUserId(client), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void Event_TankSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	if (!IsTank(client)) return;

	/* 坦克视野: 交接过来的存活秒数要在 Reset() 之前读出来 —— Reset -> VisionClearTracking
	   会把整段坦克视野状态(含存活计时)清空。两种时序都要兜住:
	     a) 交接钩子先到: carry 还挂在 g_fVisionCarryAlive 里(下面 VisionTakeHandoverAge 取);
	     b) 交接后本插件已经先跑过一帧: 存活计时已经在 g_fTankCtrlStart/AliveBias 里。 */
	float fAliveBefore = VisionAliveSeconds(client);

	Reset(client);
	if (Apex[2].IntValue > 0) CreateTimer(0.1, SetTankHealth, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);

	/* 坦克视野: 开坦克这一刻记下存活起点, 并兜底启动定时器
	   (万一 cvar 在本插件加载前就已设好, 不会触发变更钩子)。
	   注意: 给克/二控也可能让 tank_spawn 再发一次 —— 那种情况用交接钩子留下的存活秒数,
	   不能把"这辆坦克已经活了多久"清成 0(存活秒数的口径是一辆坦克, 不是一个控制者)。
	   这里只认交接钩子明确点名的 carry; 孤儿记录是给"掉控 -> 下一位接手"用的,
	   新 spawn 的坦克不该继承, 所以不在这里消费。 */
	float fNow = GetGameTime();
	bool  bHandover = false;

	float fCarry = VisionTakeHandoverAge(client, fNow, bHandover, false);

	g_fTankCtrlStart[client]   = fNow;
	g_fVisionAliveBias[client] = (fCarry > fAliveBefore) ? fCarry : fAliveBefore;
	g_bVisionCarriedOut[client] = false;
	StartTankVisionTimer();

	TankHints_Start(client);
}

/* 引擎掉控(原始 m_frustration 到顶)时会发这条事件, userid = 被收走坦克的玩家。
   这是"已经掉控"最可靠的信号: 掉控瞬间玩家可能马上被弹出坦克(IsTank 变 false),
   只靠 0.2 秒轮询会漏掉那个窗口。 */
public void Event_TankFrustrated(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client <= 0 || client > MaxClients)
		return;

	/* AI 坦克不写怒气, 它的掉控闩锁没有意义; 若记在某个 bot 槽位上,
	   之后玩家顶替这个槽位当坦克时会带着这个陈旧闩锁(整辆坦克再也不会被扣控) */
	if (IsFakeClient(client))
		return;

	g_bVisionDropped[client] = true;

	if (Apex[APEX_TV_DEBUG].IntValue >= 1)
		LogMessage("[tankvision] %N 触发 tank_frustrated(引擎已掉控), 这条命不再干预控制权", client);
}

Action SetTankHealth(Handle timer, any client)
{
	if ((client = GetClientOfUserId(client)) && IsValidClient(client) && !IsFakeClient(client))
	{
		SetEntProp(client, Prop_Data, "m_iHealth", Apex[2].IntValue);
		SetEntProp(client, Prop_Data, "m_iMaxHealth", Apex[2].IntValue);
	}
	return Plugin_Continue;
}
void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i)) Reset(i);

	/* 回合结束: 坦克存活计时/交接记录一律作废(下一个回合的坦克从 0 开始) */
	VisionResetHandoverState();
}

public void OnMapEnd()
{
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i)) Reset(i);

	VisionResetHandoverState();
}
/* -----------------------------------------------------------
	按键设置
----------------------------------------------------------- */
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon)
{
	/* 石头轨迹预测放在最前面: 除了坦克的常规预测, 还有"掷出后回显"和"!predtest 自检"两种情况,
	   它们对非坦克也要能画(函数内部自己做判定, 未开启时立即返回, 开销可忽略) */
	Pred_Update(client, angles);

	if (!IsTank(client))
		return Plugin_Continue;

	/* 连跳检测用客户端原始按键, 必须放在下面按键改写(清 IN_JUMP)之前 */
	BhopDetect_Check(client, buttons);

	// Tank Attack Control owns R/E and the !underhand/!overhand commands.
	// Keep the original Apex bindings when it is used on its own.
	if (!HasTankAttackControl())
	{
		if (buttons & IN_RELOAD)
		{
			Posture[client] = 3;
			buttons |= IN_ATTACK2;
		}
		else if (buttons & IN_USE)
		{
			Posture[client] = 2;
			buttons |= IN_ATTACK2;
		}
		else Posture[client] = 1;
	}

	if (buttons & IN_JUMP)
	{
		if (IsBhop[client] && !(GetEntityFlags(client) & FL_ONGROUND) && !(GetEntityMoveType(client) & MOVETYPE_LADDER))
			buttons &= ~IN_JUMP;
	}

	return Plugin_Continue;
}

/* -----------------------------------------------------------
	坦克连跳检测(参考 lilac 的 lilac_bhop.sp)
	判定"完美连跳": 在地面按下跳跃, 且距上一次起跳的间隔 >= air 秒;
	连续完美连跳达到阈值即视为"成功连跳".
	坦克若本命从未为 !bhop 技能付过血(即血量数据没减), 判定后补扣技能
	血量并通报全场.
	(lilac 的连跳链首跳不计入, min=10 需 11 次起跳; 这里直接按连续完美
	 连跳次数计数, 默认阈值 10 = 第 10 次起跳即判定; 需严格对齐 lilac 可
	 把 tank_bhop_detect_count 设为 11)
----------------------------------------------------------- */

/* 连跳链清零(落地未起跳 / 起跳间隔不足 / 已付费 时调用) */
void BhopDetect_Reset(int client)
{
	BhopChain[client] = 0;
	BhopTick[client]  = GetGameTickCount();
}

/* tank_bhop_detect_air(秒) 换算成 tick(lilac: tick_rate * air) */
int BhopDetect_AirTicks()
{
	float air = Apex[9].FloatValue;
	if (air <= 0.0)
		return 0;
	if (air > 1.0)
		air = 1.0;

	float interval = GetTickInterval();
	if (interval <= 0.0)
		return 0;

	return RoundToCeil(air / interval);
}

/* 每帧判定(由 OnPlayerRunCmd 调用) */
void BhopDetect_Check(int client, int buttons)
{
	int last = BhopBtn[client];
	BhopBtn[client] = buttons;

	int need = Apex[8].IntValue;

	/* 检测关闭 / 阈值非法 / 技能本身不扣血: 不判定 */
	if (!Apex[7].BoolValue || need <= 0 || Apex[3].IntValue <= 0)
	{
		BhopDetect_Reset(client);
		return;
	}

	/* 本命已付费(技能开启中 或 已扣过开启费): 血量数据已减, 不判定 */
	if (IsBhop[client] || BhopLim[client] == 1)
	{
		BhopDetect_Reset(client);
		return;
	}

	/* 只有"在地面按下跳跃"的那一帧才算一次起跳(lilac 同) */
	if ((buttons & IN_JUMP) && !(last & IN_JUMP))
	{
		if (!(GetEntityFlags(client) & FL_ONGROUND))
			return;

		int tick = GetGameTickCount();

		/* 与上一次起跳间隔不足 air 秒: 不是连跳, 计数清零 */
		if (tick <= BhopTick[client])
		{
			BhopDetect_Reset(client);
			return;
		}

		BhopTick[client] = tick + BhopDetect_AirTicks();
		BhopChain[client]++;

		if (BhopChain[client] >= need)
			BhopDetect_Charge(client, BhopChain[client]);

		return;
	}

	/* 落地后没有新的跳跃按下: 连跳链结束 */
	if (GetEntityFlags(client) & FL_ONGROUND)
		BhopDetect_Reset(client);
}

/* 判定为"未付费的成功连跳": 补扣技能血量 + 通报全场(一命只扣一次) */
void BhopDetect_Charge(int client, int chain)
{
	int cost = Apex[3].IntValue;
	if (cost <= 0 || !IsTank(client))
	{
		/* 无法补扣: 结束本次连跳链, 避免每次起跳重复判定 */
		BhopChain[client] = 0;
		return;
	}

	/* 视作本命已付费: 本命不再重复判定, 之后 !bhop 按"已扣过开启费"处理 */
	BhopLim[client] = 1;
	BhopDetect_Reset(client);

	int hp = GetEntProp(client, Prop_Data, "m_iHealth");

	/* 血量不足: 与技能一致, 不把坦克扣死 */
	if (hp <= 1)
	{
		CPrintToChatAll("%s坦克 {lightgreen}%N{darkred} 未开启{lightgreen}!bhop{darkred}技能却连续连跳{lightgreen}%d{darkred}次(血量不足, 未扣血)", TAG, client, chain);
		return;
	}

	if (cost > hp - 1)
		cost = hp - 1;

	SetEntProp(client, Prop_Data, "m_iHealth", hp - cost);

	FireSkillCost(client, ApexSkillCost_BhopDetect, cost);
	CPrintToChatAll("%s坦克 {lightgreen}%N{darkred} 未开启{lightgreen}!bhop{darkred}技能却连续连跳{lightgreen}%d{darkred}次, 已扣除技能血量{lightgreen}%d", TAG, client, chain, cost);
}

/* -----------------------------------------------------------
	转发设置
----------------------------------------------------------- */
public Action L4D_OnCThrowActivate(int ability)
{
	if (!IsValidEntity(ability))
		return Plugin_Continue;

	int client = GetEntPropEnt(ability, Prop_Data, "m_hOwnerEntity");

	/* m_hOwnerEntity 可能是 0/-1, GetClientButtons 不做合法性检查, 必须先挡掉 */
	if (!IsValidClient(client))
		return Plugin_Continue;

	if (GetClientButtons(client) & IN_ATTACK)
		if (Apex[0].IntValue) return Plugin_Handled;

	return Plugin_Continue;
}

bool HasTankAttackControl()
{
	return GetFeatureStatus(FeatureType_Native, "TankAttackControl_GetThrowSequence") == FeatureStatus_Available;
}

public Action L4D2_OnSelectTankAttack(int client, int &sequence)
{
	bool changed = false;
	int selectedSequence = sequence;
	if (sequence > 48 && IsTank(client))
	{
		if (HasTankAttackControl())
		{
			int delegated = TankAttackControl_GetThrowSequence(client);
			if (delegated > 48) selectedSequence = delegated;
		}
		else if (Posture[client])
		{
			sequence = Posture[client] + 48;
			selectedSequence = sequence;
			changed = true;
		}
	}
	/* 坦克起手"扔石头"(投掷动作 49/50/51)的一瞬间就开预测窗口, 让线在整个蓄力瞄准期间都在。
	   这里不依赖 tank_rock 实体: 实测它可能创建与掷出几乎同帧(甚至只有一帧),
	   靠"石头还在手上"来判断会完全抓不到蓄力阶段。 */
	if (sequence > 48 && IsTank(client) && !IsTrac[client] && GetGameTime() >= g_fPredLockout[client])
	{
		/* 引擎在准备投掷的整段时间里每一帧都会重选这个动作, 所以:
		   - 窗口只要续时间(不能每帧都当"新一发", 否则缓存被清空、日志刷屏)
		   - 只在"窗口从关闭 -> 打开"这一瞬间清缓存/平滑/记日志 */
		bool fresh = (GetGameTime() > g_fPredUntil[client]);

		g_fPredUntil[client] = GetGameTime() + PRED_WINDOW;
		g_iPredSeq[client]	 = selectedSequence; // Querying the owner also supports reversed plugin load order.

		if (fresh)
		{
			g_bPredMarkLogged[client]  = false;
			g_bPredStartLogged[client] = false;
			g_bPredSmoothInit[client] = false; /* 新一发: 起点平滑从本发重新开始, 不从上发的位置滑过来 */
			g_bPredVelInit[client] = false;
			g_fPredDbgUntil[client] = GetGameTime() + 0.5;
			g_fPredEmitAt[client]  = 0.0; /* 新一发第一帧立刻出线 */
			g_bPredStartLogged[client] = false;

			/* 用当前瞄准预置一次上一帧值, 免得第一帧的"帧间差"是个假的大数 */
			float aim[3];
			GetClientEyeAngles(client, aim);

			/* 本发起手瞬间的手部偏移快照(slot 0): 这个姿势还没学到时用它兜底(同样是固定值, 不跟动画) */
			g_bPredPoseOk[client][0] = GetPredPhysOffset(client, aim, g_fPredPoseOff[client][0]);

			GetPredStart(client, aim, g_fPredPrevStart[client]);
			for (int i = 0; i < 3; i++)
				g_fPredPrevAng[client][i] = aim[i];
			g_fPredPrevVel[client] = 0.0;
			g_fPredCalcAt[client]	  = 0.0;   /* 新一发强制重算, 避免复用上一发的旧轨迹 */
			g_iPredDrawCount[client]  = 0;
			PredLog(client, PRED_DEBUG_FULL, "坦克起手扔石头(动作=%d): 预测窗口 %.1f 秒(技能=%s)",
					sequence, PRED_WINDOW, IsPred[client] ? "开启" : "未开启");
		}
	}

	return changed ? Plugin_Handled : Plugin_Continue;
}

public void L4D_OnTraceRockCreated(int client, int &trace)
{
	if (IsTank(client))
		trace = IsTrac[client];
}

/**
 * 石头掷出(引擎刚给石头赋了初速):
 *  1. 收线: 清掉"手里那颗石头"并关掉预测窗口(预测线只画瞄准/蓄力阶段, 掷出即停)
 *  2. tank_pred_debug >= 1 时, 打一条"我们算的初速/出石点 vs 引擎真正用的"对比(写日志 + 发给坦克)
 */
public void L4D_TankRock_OnRelease_Post(int tank, int rock, const float vecPos[3], const float vecAng[3], const float vecVel[3], const float vecRot[3])
{
	if (IsValidClient(tank) && EntRefToEntIndex(g_iHeldRock[tank]) == rock)
		g_iHeldRock[tank] = INVALID_ENT_REFERENCE;

	if (IsValidClient(tank))
	{
		g_fPredUntil[tank]	= 0.0; /* 掷出即收线 */
		g_fPredLockout[tank] = GetGameTime() + Apex[27].FloatValue; /* 收招期间不许重开窗口 */
	}

	if (!IsTank(tank))
		return;

	float angles[3], pred[3], handPos[3], handAng[3];
	GetClientEyeAngles(tank, angles);
	GetPredVelocity(tank, angles, pred, false); /* 核对用: 用原始速度, 和平滑无关 */
	bool handOk = GetAttachmentVectors(tank, "debris", handPos, handAng);

	/* 校验用: 引擎真正用的点是"debris"附着点(手部); 画线用的是眼睛位置(为了不抖), 两者相差几十点 */
	PredLog(tank, PRED_DEBUG_KEY, "掷出石头(动作=%d): 技能=%s 手部出石点%s(%.1f,%.1f,%.1f) 引擎出石点(%.1f,%.1f,%.1f)",
			g_iPredSeq[tank], IsPred[tank] ? "开启" : "关闭", handOk ? "" : "取不到/", handPos[0], handPos[1], handPos[2],
			vecPos[0], vecPos[1], vecPos[2]);
	PredLog(tank, PRED_DEBUG_KEY, "掷出石头: 预测初速 |%.0f|(%.1f,%.1f,%.1f) 引擎初速 |%.0f|(%.1f,%.1f,%.1f)",
			GetVectorLength(pred), pred[0], pred[1], pred[2],
			GetVectorLength(vecVel), vecVel[0], vecVel[1], vecVel[2]);

	if (Apex[16].IntValue < PRED_DEBUG_KEY)
		return;

	/* 学到这个姿势真正的出手偏移(车身坐标系): 引擎给的出石点 - 眼睛锚点。
	   同姿势多次投掷做加权平均(0.7/0.3), 越用越准; 之后预测就用这个固定值, 不再跟手臂动画。 */
	if (g_iPredSeq[tank] >= 49 && g_iPredSeq[tank] <= 51)
	{
		int	  pose = g_iPredSeq[tank] - 48;
		float vis[3], fwd[3], right[3], up[3], d[3];

		GetPredStart(tank, angles, vis);
		GetAngleVectors(angles, fwd, right, up);
		NormalizeVector(fwd, fwd);
		NormalizeVector(right, right);
		NormalizeVector(up, up);

		d[0] = vecPos[0] - vis[0];
		d[1] = vecPos[1] - vis[1];
		d[2] = vecPos[2] - vis[2];

		float l0 = d[0] * right[0] + d[1] * right[1] + d[2] * right[2];
		float l1 = d[0] * up[0] + d[1] * up[1] + d[2] * up[2];
		float l2 = d[0] * fwd[0] + d[1] * fwd[1] + d[2] * fwd[2];

		float sampleLen = GetVectorLength(d);
		float avgLen	= GetVectorLength(g_fPredPoseOff[tank][pose]);

		if (g_bPredPoseOk[tank][pose] && FloatAbs(sampleLen - avgLen) > PRED_OFF_SAMPLE_TOL)
		{
			PredLog(tank, PRED_DEBUG_KEY, "姿势%d 出手偏移样本异常(本次|%.0f| vs 均值|%.0f|), 已丢弃", g_iPredSeq[tank], sampleLen, avgLen);
		}
		else if (g_bPredPoseOk[tank][pose])
		{
			g_fPredPoseOff[tank][pose][0] = g_fPredPoseOff[tank][pose][0] * 0.7 + l0 * 0.3;
			g_fPredPoseOff[tank][pose][1] = g_fPredPoseOff[tank][pose][1] * 0.7 + l1 * 0.3;
			g_fPredPoseOff[tank][pose][2] = g_fPredPoseOff[tank][pose][2] * 0.7 + l2 * 0.3;
		}
		else
		{
			g_fPredPoseOff[tank][pose][0] = l0;
			g_fPredPoseOff[tank][pose][1] = l1;
			g_fPredPoseOff[tank][pose][2] = l2;
			g_bPredPoseOk[tank][pose]	  = true;
		}

		PredLog(tank, PRED_DEBUG_KEY, "学到姿势%d 出手偏移(车身系): 右%.0f 上%.0f 前%.0f |均值%.0f| 本次测得|%.0f|",
				g_iPredSeq[tank], g_fPredPoseOff[tank][pose][0], g_fPredPoseOff[tank][pose][1],
				g_fPredPoseOff[tank][pose][2], GetVectorLength(g_fPredPoseOff[tank][pose]), GetVectorLength(d));
	}

	/* 开始记录石头实飞: 记下这一发的预测结果, 等石头碎裂时对比 */
	g_iFlyRock[tank]	   = EntIndexToEntRef(rock);
	g_bFlyActive[tank]	   = true;
	g_fFlyStartTime[tank]  = GetGameTime();
	g_bFlyPredHit[tank]	   = g_bPredHasImpact[tank];
	g_fFlyPredTime[tank]   = g_fPredImpactTime[tank];
	g_fFlyPredPos[tank][0] = g_fPredImpact[tank][0];
	g_fFlyPredPos[tank][1] = g_fPredImpact[tank][1];
	g_fFlyPredPos[tank][2] = g_fPredImpact[tank][2];
	GetEntPropVector(rock, Prop_Send, "m_vecOrigin", g_fFlyLastPos[tank]);
}

/* 掷出跟踪石头扣血: 最多扣到只剩 1 血, 技能不会把坦克扣死. 返回实际扣除的血量(0=没扣) */
int ChargeTracThrow(int client)
{
	int cost = Apex[5].IntValue;
	if (cost <= 0 || !IsTank(client))
		return 0;

	int hp = GetEntProp(client, Prop_Data, "m_iHealth");
	if (hp <= 1)
		return 0;

	if (cost > hp - 1)
		cost = hp - 1;

	SetEntProp(client, Prop_Data, "m_iHealth", hp - cost);

	FireSkillCost(client, ApexSkillCost_TracThrow, cost);

	return cost;
}

/* 跟踪石命中生还者: 退还掷出时扣的血(即"命中则不扣血", 只有未命中才真正扣) */
void RefundTracThrow(int tank, int rock)
{
	int charge = g_iRockCharge[rock];
	if (charge <= 0)
		return;

	g_iRockCharge[rock] = 0;

	if (!IsTank(tank))
		return;

	int hp	  = GetEntProp(tank, Prop_Data, "m_iHealth");
	int maxhp = GetEntProp(tank, Prop_Data, "m_iMaxHealth");

	int newhp = hp + charge;
	if (maxhp > 0 && newhp > maxhp)
		newhp = maxhp;

	if (newhp != hp)
	{
		SetEntProp(tank, Prop_Data, "m_iHealth", newhp);
		/* 通报退还(负数): 命中则不扣血, 伤害统计侧据此把预扣的血扣回去 */
		FireSkillCost(tank, ApexSkillCost_TracThrow, hp - newhp);
	}
}
/* -----------------------------------------------------------
	跟踪石平衡功能: 血量 / 禁止连续命中同一人 / 控制权扣除
	(石头是否为"跟踪石"在此判定: 出石瞬间坦克开着 !trac)
----------------------------------------------------------- */

/* l4d_tracerock.smx 是否加载(未加载则不存在跟踪石, 平衡功能不生效); 懒检查以兼容插件后加载 */
bool HasTracePlugin()
{
	if (!g_bHasTracePlugin)
		g_bHasTracePlugin = LibraryExists("L4D_OnTraceRockCreated");

	return g_bHasTracePlugin;
}

/* 跟踪功能当前是否真的生效(插件已加载 且 l4d_tracerock_enable 开着) */
bool TracFeatureActive()
{
	if (!HasTracePlugin())
		return false;

	ConVar cv = FindConVar("l4d_tracerock_enable");
	return (cv == null) ? true : cv.BoolValue;
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (strcmp(classname, "tank_rock") == 0)
		SDKHook(entity, SDKHook_SpawnPost, OnRockSpawnPost);
}

void OnRockSpawnPost(int rock)
{
	/* 实体索引会被复用, 先复位状态 */
	g_bTraceRock[rock]	= false;
	g_fRockDamage[rock] = 0.0;
	g_iRockCharge[rock] = 0;

	int owner = GetEntPropEnt(rock, Prop_Data, "m_hOwnerEntity");

	/* 记下"该坦克手上有一颗还没掷出的石头": !pred 轨迹预测就靠这个判断"正在蓄力掷石"。
	   引擎在蓄力开始时就生成 tank_rock(CTankRock::Create: MOVETYPE_NONE + SOLID_NONE +
	   FollowEntity 坦克), 直到 CThrow::UpdateAbility 走完蓄力才调 CTankRock::OnRelease 赋予初速;
	   这里在 SpawnPost 记下, 在 L4D_TankRock_OnRelease_Post 清除。
	   (注意: 蓄力期间石头的坐标并不是出手点, 出手点要另外取坦克 "debris" 附着点。
	    实测某些情况下石头几乎与掷出同帧, 所以预测线的触发以"起手动作"为主, 这里只作辅助/日志) */
	if (IsValidClient(owner))
		g_iHeldRock[owner] = EntIndexToEntRef(rock);
	if (IsTank(owner))
		PredLog(owner, PRED_DEBUG_FULL, "tank_rock #%d 已生成(owner=%N): 石头存在期间=蓄力期", rock, owner);

	/* 只有"坦克开着跟踪、且跟踪功能确实生效"时掷出的石头才算跟踪石 */
	if (!TracFeatureActive() || !IsTank(owner) || !IsTrac[owner])
		return;

	g_bTraceRock[rock] = true;

	/* 掷出即扣血, 命中生还者时再退还(见 RefundTracThrow) */
	g_iRockCharge[rock] = ChargeTracThrow(owner);

	/* 跟踪石血量: 交给引擎 40 点血, 同时自行累计伤害兜底(见 OnRockTakeDamage) */
	int health = Apex[6].IntValue;
	if (health > 0)
	{
		SetEntProp(rock, Prop_Data, "m_iHealth", health);
		SetEntProp(rock, Prop_Data, "m_takedamage", 2);	   // DAMAGE_YES: 确保子弹能打到石头(原本已开启则无影响)
		SDKHook(rock, SDKHook_OnTakeDamage, OnRockTakeDamage);
	}

	/* 飞行音效限时: 跟踪石会在生还者附近绕圈, 引擎的飞行循环音效会一直响 */
	float flyTime = Apex[10].FloatValue;
	if (flyTime > 0.0)
		CreateTimer(flyTime, Timer_StopFlySound, EntIndexToEntRef(rock), TIMER_FLAG_NO_MAPCHANGE);
}

bool g_bRockFlySoundPrecached;	  /* 本图已预缓存成功 */
bool g_bRockFlySoundFailed;		  /* 本图预缓存失败(已报过一次, 不再重试刷屏) */

/* 停止石头飞行循环音效
   server.dll 里引擎是直接用 soundscript 名 "HulkZombie.Throw.FlyLoop" 播这个循环音的
   (引擎自己播不刷警告, 因为它播之前先预缓存过), 但 StopSound 走的是"按波形名查表"的路子:
     * 传 soundscript 名 -> 引擎当成波形文件名 "sound/HulkZombie.Throw.FlyLoop" 去找, 找不到
       -> 每调用一次就刷一条 "SV_StartSound: ... not precached (0)", 音效还停不掉;
     * 传真正的波形路径 ROCK_FLY_WAVE -> 表里有(已预缓存) -> 不刷警告, 停止事件也能对上。
   所以这里按波形路径停, 并且只停 CHAN_BODY(soundscript 里写的就是它) ——
   原来 AUTO..STATIC 七个频道 × 石头/坦克两个实体 = 一次刷 14 条。 */
void StopRockFlySound(int rock)
{
	PrecacheRockFlySound();

	if (!g_bRockFlySoundPrecached)
		return;

	int owner = GetEntPropEnt(rock, Prop_Data, "m_hOwnerEntity");

	/* 引擎可能把音效挂在石头上, 也可能挂在坦克身上; 两个实体 × soundscript 频道/自动频道 */
	StopSound(rock, SNDCHAN_BODY, ROCK_FLY_WAVE);
	StopSound(rock, SNDCHAN_AUTO, ROCK_FLY_WAVE);

	if (IsValidClient(owner))
	{
		StopSound(owner, SNDCHAN_BODY, ROCK_FLY_WAVE);
		StopSound(owner, SNDCHAN_AUTO, ROCK_FLY_WAVE);
	}
}

public Action Timer_StopFlySound(Handle timer, any ref)
{
	int rock = EntRefToEntIndex(ref);
	if (ref && rock != INVALID_ENT_REFERENCE)
		StopRockFlySound(rock);

	return Plugin_Continue;
}

/* -----------------------------------------------------------
	石头飞行循环音效预缓存

	引擎的循环音效走客户端预测播放, 服务端预缓存表里没有这一条, 于是
	StopSound(石头/坦克, 频道, "HulkZombie.Throw.FlyLoop") 由服务端发出
	SND_STOP 时命中 SV_StartSound 的未预缓存检查, 控制台刷
	"SV_StartSound: HulkZombie.Throw.FlyLoop not precached (0)", 且停音效失败。
	按 soundscript 名预缓存一次即可(PrecacheScriptSound 会连带预缓存该条目
	引用的所有 wav; 该条目定义在游戏内置 game_sounds 脚本里)。

	三个时机都补一遍, 保证"要用之前一定已经预缓存":
	  1. 换图 OnMapStart;
	  2. 中途加载/热重载 OnConfigsExecuted(收不到本图的 OnMapStart);
	  3. 真正去停音效之前 StopRockFlySound 里再兜一次(前两个都没跑到也不会刷警告)。
----------------------------------------------------------- */
void PrecacheRockFlySound()
{
	if (g_bRockFlySoundPrecached || g_bRockFlySoundFailed)
		return;

	/* 两条都预缓存: soundscript 名(引擎播的时候用) + 真正的波形(我们 StopSound 时按波形名查表) */
	bool okScript = PrecacheScriptSound(ROCK_FLY_SOUND);
	bool okWave   = PrecacheSound(ROCK_FLY_WAVE, true);

	g_bRockFlySoundPrecached = (okScript && okWave);

	/* 预缓存失败: 本图不再尝试停音效(不输出任何日志) */
	if (!g_bRockFlySoundPrecached)
		g_bRockFlySoundFailed = true;
}

public void OnMapStart()
{
	g_bRockFlySoundPrecached = false;
	g_bRockFlySoundFailed	 = false;
	PrecacheRockFlySound();

	/* 提示定时器带 TIMER_FLAG_NO_MAPCHANGE, 换图时会被引擎关掉; 标记必须一并清掉,
	   否则那之后坦克出生提示再也不会发(标记一直停在"正在发") */
	for (int i = 0; i <= MaxClients; i++)
		g_bHintActive[i] = false;

	/* 轨迹预测线的贴图(临时光束 TE_SetupBeamPoints 用) */
	g_iBeamSprite = PrecacheModel(PRED_BEAM_SPRITE);

	/* 换图后实体索引全变, 隐形阻挡体名单要重新学 */
	for (int i = 0; i < sizeof(g_bPredIgnoreEnt); i++)
		g_bPredIgnoreEnt[i] = false;
	g_iPredIgnored = 0;
}

/* 插件中途加载(手动 sm plugins load、热重载)收不到本图的 OnMapStart, 这里补一次 */
public void OnConfigsExecuted()
{
	PrecacheRockFlySound();

	if (g_iBeamSprite <= 0)
		g_iBeamSprite = PrecacheModel("materials/sprites/laserbeam.vmt");
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_OnTakeDamage, OnClientTakeDamage);
}

public void OnClientDisconnect(int client)
{
	SDKUnhook(client, SDKHook_OnTakeDamage, OnClientTakeDamage);

	/* 掉线不保留坦克视野的存活计时/扣控状态(客户端索引会被复用, 新玩家不从上一辆坦克继承) */
	VisionClearTracking(client);
	g_bVisionDropped[client] = false;
	g_bVisionWroteFull[client] = false;
	g_bVisionDropTried[client] = false;
	g_fVisionFullAt[client]    = 0.0;
	g_bVisionCarriedOut[client] = false;
	g_bVisionCarryValid[client] = false;
	g_fVisionCarryAlive[client] = 0.0;
	g_fVisionCarryAt[client]    = 0.0;


	/* 跟踪石的连续命中约束(控制权状态已移交 l4d_tank_control_eq 修改版) */
	g_iLastTracTarget[client] = 0;

	/* 掉线后不该再保留"手里那颗石头"/预测窗口/平滑状态 */
	g_iHeldRock[client]	  = INVALID_ENT_REFERENCE;
	g_bPredActive[client] = false;
	g_fPredUntil[client]  = 0.0;
	g_fPredTestUntil[client] = 0.0;
	g_bPredSmoothInit[client] = false;
	g_bFlyActive[client]  = false;
	g_iFlyRock[client]	  = INVALID_ENT_REFERENCE;
	g_bPredVelInit[client] = false;
	g_bHintActive[client]  = false;
	g_fPredDbgUntil[client] = 0.0;
	g_fPredLockout[client]	= 0.0;
	g_bPredStartLogged[client] = false;
	Pred_ResetCache(client);
}

/**
 * 跟踪石命中生还者:
 *  1. 命中则不扣血: 退还掷出时预扣的血量
 *  2. 记下命中目标: 该坦克下一发跟踪石不再选他(禁止连续命中同一人)
 *  3. 控制权: 发 forward Apex_OnTracRockHit, 由控制权插件(修改版 l4d_tank_control_eq)做调整
 */
public Action OnClientTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype,
								 int &weapon, float damageForce[3], float damagePosition[3])
{
	if (!IsSurvivor(victim))
		return Plugin_Continue;

	if (inflictor <= MaxClients || inflictor >= sizeof(g_bTraceRock))
		return Plugin_Continue;

	if (!g_bTraceRock[inflictor])
		return Plugin_Continue;

	int tank = GetEntPropEnt(inflictor, Prop_Data, "m_hOwnerEntity");
	if (!IsTank(tank))
		return Plugin_Continue;

	/* 1. 命中生还者 -> 退还掷出时扣的血 */
	RefundTracThrow(tank, inflictor);

	/* 2. 下一发跟踪石不再选中他(选人逻辑在 l4d_tracerock.sp, 通过 Apex_GetTracBlockedTarget 查询) */
	g_iLastTracTarget[tank] = victim;

	/* 3. 控制权: 只发通知, 具体调整由控制权插件(修改版 l4d_tank_control_eq)负责 */
	FireTracRockHit(tank, victim);

	return Plugin_Continue;
}

/**
 * 跟踪石血量: 自行累计伤害, 血量耗尽即打碎石头.
 * (同时已把 m_iHealth 设为 cvar 值; 若引擎自己按血量打碎, 这条路径不会触发)
 */
public Action OnRockTakeDamage(int rock, int &attacker, int &inflictor, float &damage, int &damagetype,
							   int &weapon, float damageForce[3], float damagePosition[3])
{
	int health = Apex[6].IntValue;
	if (!g_bTraceRock[rock] || health <= 0 || damage <= 0.0)
		return Plugin_Continue;

	g_fRockDamage[rock] += damage;

	if (g_fRockDamage[rock] < float(health))
		return Plugin_Continue;

	BreakTraceRock(rock);

	return Plugin_Handled;
}

void BreakTraceRock(int rock)
{
	if (!g_bTraceRock[rock])
		return;

	g_bTraceRock[rock]	= false;
	g_fRockDamage[rock] = 0.0;
	g_iRockCharge[rock] = 0;

	SDKUnhook(rock, SDKHook_OnTakeDamage, OnRockTakeDamage);

	/* 先停飞行循环音效, 再按引擎方式引爆(比直接删实体更干净: 碎裂效果 + 音效随实体正常结束) */
	StopRockFlySound(rock);

	if (GetFeatureStatus(FeatureType_Native, "L4D_DetonateProjectile") == FeatureStatus_Available)
	{
		L4D_DetonateProjectile(rock);
		CreateTimer(1.0, Timer_RemoveRock, EntIndexToEntRef(rock), TIMER_FLAG_NO_MAPCHANGE);	/* 兜底清理 */
	}
	else
	{
		SetEntityRenderFx(rock, RENDERFX_FADE_FAST);
		CreateTimer(0.5, Timer_RemoveRock, EntIndexToEntRef(rock), TIMER_FLAG_NO_MAPCHANGE);
	}
}

public Action Timer_RemoveRock(Handle timer, any ref)
{
	int rock = EntRefToEntIndex(ref);
	if (ref && rock != INVALID_ENT_REFERENCE)
	{
		StopRockFlySound(rock);
		g_bTraceRock[rock]	= false;
		g_fRockDamage[rock] = 0.0;
		g_iRockCharge[rock] = 0;
		RemoveEntity(rock);
	}

	return Plugin_Continue;
}

bool IsSurvivor(int client)
{
	return (IsValidClient(client) && GetClientTeam(client) == 2);
}

/* -----------------------------------------------------------
	石头轨迹预测(!pred / !yc)
	坦克按下右键(起手扔石头)的那一刻开一个 1.2 秒窗口, 窗口内每帧画一次预测抛物线;
	掷出石头 / 取消 / 窗口到期都会立刻收线(石头离手后不再显示)。
	  起点   = 坦克眼睛位置 + 准星前向 24 点(可用 tank_pred_forward 调, 做时间平滑防抖)
	           —— 不用引擎那个"debris"手部附着点: 它跟着投掷手臂动画摆, 站着不动线也会抖
	  初速   = 眼睛前向 * z_tank_throw_force + 坦克自身速度
	  加速度 = -sv_gravity * 0.4
	石头命中即碎(不反弹), 所以扫到第一次碰撞就收线, 不做反弹预测。
----------------------------------------------------------- */

/* 取该坦克握在手里(还没掷出)的石头, 没有则返回 -1 */
int GetHeldRock(int tank)
{
	int ref = g_iHeldRock[tank];
	if (ref <= 0) /* 0 = 从未记录, -1 = 已清空 */
		return -1;

	int rock = EntRefToEntIndex(ref);
	if (rock == INVALID_ENT_REFERENCE || !IsValidEntity(rock))
		return -1;

	/* 石头必须仍属于这辆坦克(实体索引会被复用, 这里再核一次归属) */
	if (GetEntPropEnt(rock, Prop_Data, "m_hOwnerEntity") != tank)
		return -1;

	return rock;
}

/* 出石初速: 与引擎 CTankRock::OnRelease 的算法一致(眼睛前向 * 出石速度 + 坦克自身速度) */
void GetPredVelocity(int tank, const float angles[3], float vel[3], bool smooth = true)
{
	float fwd[3], right[3], up[3];
	GetAngleVectors(angles, fwd, right, up);
	NormalizeVector(fwd, fwd);
	NormalizeVector(right, right);
	NormalizeVector(up, up);

	float speed = Apex[12].FloatValue;
	if (speed <= 0.0)
		speed = (g_hThrowForce == null) ? PRED_FALLBACK_SPEED : g_hThrowForce.FloatValue;

	ScaleVector(fwd, speed);

	float tankVel[3];
	GetEntPropVector(tank, Prop_Data, "m_vecVelocity", tankVel);

	/* 站着不动时 m_vecVelocity 也不是 0, 会有几到几十 u/s 的来回抖动;
	   它直接叠加进初速 = 方向抖 1~3 度 = 整条线在摆("站着不动都抖"就是它)。
	   所以在车身坐标系里平滑: 抖动被压掉, 真走路(几百 u/s)照样跟得上。 */
	if (smooth && Apex[19].FloatValue > 0.0)
	{
		float keep = Apex[19].FloatValue;
		float loc[3];

		loc[0] = tankVel[0] * right[0] + tankVel[1] * right[1] + tankVel[2] * right[2];
		loc[1] = tankVel[0] * up[0] + tankVel[1] * up[1] + tankVel[2] * up[2];
		loc[2] = tankVel[0] * fwd[0] + tankVel[1] * fwd[1] + tankVel[2] * fwd[2];

		if (!g_bPredVelInit[tank])
		{
			g_fPredVelSmooth[tank][0] = loc[0];
			g_fPredVelSmooth[tank][1] = loc[1];
			g_fPredVelSmooth[tank][2] = loc[2];
			g_bPredVelInit[tank]	 = true;
		}
		else
		{
			for (int i = 0; i < 3; i++)
			{
				loc[i] = loc[i] * (1.0 - keep) + g_fPredVelSmooth[tank][i] * keep;
				g_fPredVelSmooth[tank][i] = loc[i];
			}
		}

		tankVel[0] = right[0] * loc[0] + up[0] * loc[1] + fwd[0] * loc[2];
		tankVel[1] = right[1] * loc[0] + up[1] * loc[1] + fwd[1] * loc[2];
		tankVel[2] = right[2] * loc[0] + up[2] * loc[1] + fwd[2] * loc[2];
	}

	AddVectors(fwd, tankVel, vel);
}

/**
 * 画线起点: 坦克眼睛位置 + 准星前向偏移(默认 24 点)。
 *
 * 为什么不用引擎掷出时那个"debris"骨骼附着点(手部): 它跟着投掷手臂动画走,
 * 站着不动手臂一抬一放, 起点就来回摆, 整条预测线跟着甩(实测抖动很大);
 * 而这个点只影响起点位置(几十点), 对整条抛物线的形状/落点几乎没有贡献,
 * 所以画线用稳定的眼睛位置, 手部点只在调试日志里与引擎实际出石点做对比核对。
 */
void GetPredStart(int client, const float angles[3], float start[3])
{
	float fwd[3];
	GetAngleVectors(angles, fwd, NULL_VECTOR, NULL_VECTOR);
	NormalizeVector(fwd, fwd);

	GetClientEyePosition(client, start);

	float advance = Apex[18].FloatValue;
	if (advance > 0.0)
	{
		start[0] += fwd[0] * advance;
		start[1] += fwd[1] * advance;
		start[2] += fwd[2] * advance;
	}
}

/**
 * 手部出石点相对"眼睛锚点"的偏移, 拆到坦克自身坐标系(右/上/前)输出。
 *
 * 引擎真正用的出石点是手部 "debris" 附着点: 不同姿势(49/50/51)它离眼睛的高度/前后都不同,
 * 抬手姿势在头顶之上 —— 用眼睛点算落点会差出上百点(实测"预测 0.09 秒/误差 700+")。
 * 但手部跟着投掷动画抖, 直接当起点画线会抖到看不清。于是把偏移放在"车身坐标系"里平滑:
 * 动画抖动被压掉、各姿势的平均偏移保留, 而转视角时基向量一起转 -> 零滞后。
 * @return false = 取不到手部附着点(老 left4dhooks / 缺 lux_library.txt), 调用方退回纯眼睛起点
 */
bool GetPredPhysOffset(int client, const float angles[3], float local[3])
{
	float hand[3], vis[3], ang[3];
	float fwd[3], right[3], up[3];

	if (!GetAttachmentVectors(client, "debris", hand, ang))
		return false;

	GetPredStart(client, angles, vis);
	GetAngleVectors(angles, fwd, right, up);
	NormalizeVector(fwd, fwd);
	NormalizeVector(right, right);
	NormalizeVector(up, up);

	float d[3];
	d[0] = hand[0] - vis[0];
	d[1] = hand[1] - vis[1];
	d[2] = hand[2] - vis[2];

	local[0] = d[0] * right[0] + d[1] * right[1] + d[2] * right[2];
	local[1] = d[0] * up[0] + d[1] * up[1] + d[2] * up[2];
	local[2] = d[0] * fwd[0] + d[1] * fwd[1] + d[2] * fwd[2];

	return true;
}

/* 拼出真正用于计算的起点: 眼睛锚点 + 平滑后的手部偏移(转回世界坐标) */
void Pred_ComposeStart(const float vis[3], const float angles[3], const float local[3], float out[3])
{
	float fwd[3], right[3], up[3];
	GetAngleVectors(angles, fwd, right, up);
	NormalizeVector(fwd, fwd);
	NormalizeVector(right, right);
	NormalizeVector(up, up);

	out[0] = vis[0] + right[0] * local[0] + up[0] * local[1] + fwd[0] * local[2];
	out[1] = vis[1] + right[1] * local[0] + up[1] * local[1] + fwd[1] * local[2];
	out[2] = vis[2] + right[2] * local[0] + up[2] * local[1] + fwd[2] * local[2];
}

/* 起点自救专用的碰撞过滤器: 除坦克自己外, 再把所有玩家排除 ——
   别的生还者站在坦克旁边/脚下不该让起点被判定成"贴地", 也不该把起点往上抬。
   隐形物理阻挡体(env_physics_blocker)同样不算(石头从它身上穿过去)。 */
bool Pred_StartFilter(int entity, int contentsMask, any data)
{
	if (entity == data)
		return false;

	if (entity > 0 && entity <= MaxClients)
		return false;

	if (entity > 0 && entity < sizeof(g_bPredIgnoreEnt) && g_bPredIgnoreEnt[entity])
		return false;

	return true;
}

/**
 * 起点是否"没法用": 插在实心几何里, 或者离脚下地面近到石头盒已经贴上了。
 *
 * 为什么必须查这一条: 起点是"眼睛锚点 + 手部偏移"拼出来的, 手部偏移是学来的固定值
 * (起手快照那一档来自动作刚开始时的手部附着点, 那时手臂还在蓄力位置 —— 手比眼睛低得多)。
 * 一旦偏移把起点压到脚边, 就会出现"被脚下挡住"的两种真身:
 *   1) 起点插在地面/台阶里: 石头盒一出生就在实心的, 引擎每次 hull 扫描都返回 startsolid,
 *      整段抛物线在地下走, 玩家看到的线就是"刚出来就被地面切断";
 *   2) 起点离地不足 4+6 点: 石头盒已经贴着地面, 第一个物理步(0.02 秒)的扫描就会和地面
 *      擦上, 距离刚好越过 PRED_MIN_STEP_DIST 被当成真命中 -> 落点光柱插在脚边。
 *
 * 判据用三条, 任一成立就算不可用:
 *   a) 该点的世界内容含实心标志(点在固体里);
 *   b) ±4 石头盒的零长度 hull 扫描报 startsolid(盒子与实心几何重叠);
 *   c) 以 ±4 石头盒向下走 4+6 点, 扫到了东西(脚下贴地/贴着道具)。
 * 掩码跟正式轨迹检测完全一致(去掉感染者与玩家夹子), 结论才能和 Pred_StepTrace 对上;
 * 过滤器额外排除玩家(见 Pred_StartFilter)。
 */
bool Pred_StartBad(int client, const float pos[3])
{
	/* a) 点内容: 只看"实心几何"那几位, 感染者(MONSTER)与玩家夹子(PLAYERCLIP)照旧不算 */
	if ((TR_GetPointContents(pos) & PRED_WORLD_MASK) != 0)
		return true;

	float hullMin[3] = { -PRED_HULL_SIZE, -PRED_HULL_SIZE, -PRED_HULL_SIZE };
	float hullMax[3] = { PRED_HULL_SIZE, PRED_HULL_SIZE, PRED_HULL_SIZE };

	/* b) 零长度 hull: 石头盒在这里放得下吗 */
	TR_TraceHullFilter(pos, pos, hullMin, hullMax, PRED_WORLD_MASK, Pred_StartFilter, client);
	if (TR_StartSolid() || TR_AllSolid())
		return true;

	/* c) 脚下净空: 只向下扫 10 点, 能扫到就说明贴着地/贴着道具 */
	float down[3];
	down[0] = pos[0];
	down[1] = pos[1];
	down[2] = pos[2] - (PRED_HULL_SIZE + PRED_START_CLEAR);

	TR_TraceHullFilter(pos, down, hullMin, hullMax, PRED_WORLD_MASK, Pred_StartFilter, client);
	return TR_DidHit();
}

/**
 * 起点自救: 只在起点"没法用"(见 Pred_StartBad)时才动它, 正常起点一个坐标都不改,
 * 所以平时的轨迹形状和落点跟改动前完全一样。
 *
 * 修法优先小幅上抬(每次 16 点, 最多 8 次 = 128 点):
 *   元凶是水平的地面/台阶, 沿着抛物线方向往前推还在土里, 往上抬一次就出来了;
 *   而且上抬对弹道的影响是"整条线一起抬高一点", 落点只略微变远, 不会像前推那样
 *   把起点塞进坦克正前方的墙里(那会造出一个新的假命中)。
 * 上抬到上限仍然不行(站在低矮夹缝里, 连手部偏移带出来的点被几何包住), 才退回纯眼睛锚点 ——
 * 玩家眼位一定在空域里, 否则他本人早就卡在墙里了。
 *
 * @param start 输入输出: 合成出来的起点, 不可用时在这里被就地改写
 * @param vis   GetPredStart 的眼睛锚点, 最后兜底用
 * @return true = 起点被改写过(日志里能看到改了多少, 便于实测确认)
 */
bool Pred_FixStart(int client, float start[3], const float vis[3])
{
	if (!Pred_StartBad(client, start))
		return false;

	float bad[3];
	bad[0] = start[0];
	bad[1] = start[1];
	bad[2] = start[2];

	/* 1) 上抬: 每次 16 点, 最多 8 次, 找到第一个"能用"的高度就停 */
	for (int i = 1; i <= PRED_START_LIFT_TRIES; i++)
	{
		float probe[3];
		probe[0] = bad[0];
		probe[1] = bad[1];
		probe[2] = bad[2] + PRED_START_LIFT_STEP * float(i);

		if (Pred_StartBad(client, probe))
			continue;

		start[0] = probe[0];
		start[1] = probe[1];
		start[2] = probe[2];

		if (PredLogCanSpam(client))
			PredLog(client, PRED_DEBUG_KEY, "起点自救: 合成起点(%.0f,%.0f,%.0f)卡在脚下几何/贴地里, 上抬 %.0f 点 -> (%.0f,%.0f,%.0f)",
					bad[0], bad[1], bad[2], PRED_START_LIFT_STEP * float(i), start[0], start[1], start[2]);
		return true;
	}

	/* 2) 上抬也救不回来: 退回眼睛锚点(比原起点更靠上、更靠后, 一定比埋在土里强) */
	if (!Pred_StartBad(client, vis))
	{
		start[0] = vis[0];
		start[1] = vis[1];
		start[2] = vis[2];

		if (PredLogCanSpam(client))
			PredLog(client, PRED_DEBUG_KEY, "起点自救: 上抬 %d 次仍不可用, 退回眼睛锚点(%.0f,%.0f,%.0f)(原起点 %.0f,%.0f,%.0f)",
					PRED_START_LIFT_TRIES, vis[0], vis[1], vis[2], bad[0], bad[1], bad[2]);
		return true;
	}

	/* 3) 连眼位都在实心里(极端情况): 保持原起点不动, 只留一条日志说明为什么没救 */
	if (PredLogCanSpam(client))
		PredLog(client, PRED_DEBUG_KEY, "起点自救失败: 眼位(%.0f,%.0f,%.0f)也在实心几何里, 保持原起点不动", vis[0], vis[1], vis[2]);
	return false;
}
/**
 * 石头实飞记录(调试): 掷出后逐帧记住石头位置; 石头碎裂消失(或超过 6 秒)时,
 * 用最后位置当作实际落点, 打印"实际落点/实飞时间 vs 预测落点/预测时间/误差"。
 * 这是唯一能客观回答"预测线准不准、够不够长"的办法, 不靠肉眼判断。
 */
void Pred_TrackFlight(int client)
{
	if (!g_bFlyActive[client])
		return;

	float flight = GetGameTime() - g_fFlyStartTime[client];
	int	  rock	 = EntRefToEntIndex(g_iFlyRock[client]);

	if (rock != INVALID_ENT_REFERENCE && IsValidEntity(rock) && flight < 6.0)
	{
		GetEntPropVector(rock, Prop_Send, "m_vecOrigin", g_fFlyLastPos[client]);
		return;
	}

	g_bFlyActive[client] = false;

	if (flight < 0.05)
		return;

	float err = g_bFlyPredHit[client] ? GetVectorDistance(g_fFlyLastPos[client], g_fFlyPredPos[client]) : -1.0;

	PredLog(client, PRED_DEBUG_KEY, "石头实飞(动作=%d 重力=%.0f): 实际落点(%.0f,%.0f,%.0f) 实飞 %.2f 秒%s | 预测落点(%.0f,%.0f,%.0f) 预测 %.2f 秒 命中=%s | 落点误差 %.0f 点",
			g_iPredSeq[client], g_fPredGravity[client],
			g_fFlyLastPos[client][0], g_fFlyLastPos[client][1], g_fFlyLastPos[client][2], flight,
			(flight >= 6.0) ? "(石头一直没消失, 采到 6 秒)" : "",
			g_fFlyPredPos[client][0], g_fFlyPredPos[client][1], g_fFlyPredPos[client][2], g_fFlyPredTime[client],
			g_bFlyPredHit[client] ? "是" : "否", err);
}

/* 清掉这一发的抛物线缓存与节流时间戳(新一发/重生/掉线/自检开始都调) */
void Pred_ResetCache(int client)
{
	g_iPredDrawCount[client] = 0;
	g_bPredHasImpact[client] = false;
	g_fPredCalcAt[client]	 = 0.0;
	g_fPredEmitAt[client]	 = 0.0;
	g_fPredImpactTime[client] = 0.0;
	g_iPredHitEnt[client]	 = 0;
	g_fPredLastAng[client][0] = 0.0;
	g_fPredLastAng[client][1] = 0.0;
	g_fPredLastAng[client][2] = 0.0;
	g_fPredLastStart[client][0] = 0.0;
	g_fPredLastStart[client][1] = 0.0;
	g_fPredLastStart[client][2] = 0.0;
	g_fPredLastVel[client][0] = 0.0;
	g_fPredLastVel[client][1] = 0.0;
	g_fPredLastVel[client][2] = 0.0;
}

/* 轨迹预测的碰撞过滤: 只忽略坦克自己(线从坦克身上出发, 不忽略的话一出手就撞自己) */
bool TraceFilter_Pred(int entity, int contentsMask, any data)
{
	if (entity == data)
		return false;

	if (entity > 0 && entity < sizeof(g_bPredIgnoreEnt) && g_bPredIgnoreEnt[entity])
		return false; /* 隐形物理阻挡体: 玩家看不见, 石头也穿得过 */

	return true;
}

/**
 * 调试日志: 同时写进服务器日志(可在 addons/sourcemod/logs/L<日期>.log 里 grep "[!pred]")
 * 和发给该玩家(颜色用 CPrintToChat, 会正确解析 TAG 里的 {olive} 标签)。
 * @param level 需要的 tank_pred_debug 档位(PRED_DEBUG_KEY / PRED_DEBUG_FULL)
 */
void PredLog(int client, int level, const char[] fmt, any ...)
{
	if (Apex[16].IntValue < level)
		return;

	char buf[256];
	VFormat(buf, sizeof(buf), fmt, 4);

	LogMessage("[!pred] %N: %s", client, buf);

	if (IsValidClient(client))
		CPrintToChat(client, "%s{olive}[pred]{default} %s", TAG, buf);
}

/* 高频路径(每帧)上的日志节流: 同一玩家每秒最多一条 */
bool PredLogCanSpam(int client)
{
	float now = GetGameTime();
	if (now < g_fPredLogAt[client])
		return false;

	g_fPredLogAt[client] = now + 1.0;
	return true;
}

/* 抛物线求值: start + vel*t - 0.5*gravity*t^2 (重力沿 Z 轴向下) */
void Pred_EvalAt(const float start[3], const float vel[3], float gravity, float t, float out[3])
{
	out[0] = start[0] + vel[0] * t;
	out[1] = start[1] + vel[1] * t;
	out[2] = start[2] + vel[2] * t - 0.5 * gravity * t * t;
}

/**
 * 单步碰撞检测(石头 ±4 碰撞盒)
 * @return true = 真撞上了, 此时 to 被改写成命中点
 *   命中点贴在起点上时视为 startsolid(起点被坦克自己的碰撞盒/命中盒包住):
 *   换只擦世界几何的 MASK_SOLID 重试一次, 仍贴住就当这一步没撞, 让后面几步去撞真墙。
 */
bool Pred_StepTrace(int client, const float from[3], float to[3], const float hullMin[3], const float hullMax[3])
{
	/* 最多重试 4 次: 每次可能学会一个新的"隐形阻挡体"并把它从这一扫里排除掉 */
	for (int attempt = 0; attempt < 4; attempt++)
	{
		if (Pred_StepTraceOnce(client, from, to, hullMin, hullMax))
			return true;
	}

	return false;
}

/* 单次扫描(不含学习重试) */
bool Pred_StepTraceOnce(int client, const float from[3], float to[3], const float hullMin[3], const float hullMax[3])
{
	float endpos[3];
	float best	 = -1.0; /* 本次命中的距离, -1 = 没命中 */
	int	  bestEnt = 0;

	/* 1) 世界几何: ±4 石头碰撞盒扫; 掩码已排除感染者(石头从感染者身上穿过去) */
	TR_TraceHullFilter(from, to, hullMin, hullMax, PRED_WORLD_MASK, TraceFilter_Pred, client);
	if (TR_DidHit())
	{
		/* startsolid 要单独识别: 这一步的起点本身就在实心里(脚下地面/台阶/墙角), 引擎会给出
		   "几乎零距离的命中点"。以前只靠 PRED_MIN_STEP_DIST 这个距离阈值把它挡掉, 但阈值是
		   双刃剑 —— 距离刚好越过 2 点就会被当成真命中, 于是落点光柱插在脚边(坦克自己脚下)。
		   这里显式区分: 起点在实心里的这次命中一律不算, 只跳过世界几何那一路, 第 2 步的生还者
		   射线照旧跑(别漏掉"起点卡在门槛里、前面正好站着生还者"这种组合);
		   起点在空域里、只是贴脸擦过真墙的, 仍然照距离阈值处理, 薄墙不会被放过。 */
		if (TR_StartSolid() || TR_AllSolid())
		{
			if (PredLogCanSpam(client))
				PredLog(client, PRED_DEBUG_FULL, "这一步起点在实心几何里(startsolid), 世界几何不算命中: 从(%.0f,%.0f,%.0f) 到 (%.0f,%.0f,%.0f)",
						from[0], from[1], from[2], to[0], to[1], to[2]);
		}
		else
		{
			TR_GetEndPosition(endpos);
			float d = GetVectorDistance(from, endpos);
			if (d >= PRED_MIN_STEP_DIST)
			{
				best	= d;
				bestEnt = TR_GetEntityIndex();
				to[0]	= endpos[0];
				to[1]	= endpos[1];
				to[2]	= endpos[2];
			}
		}
	}

	/* 2) 生还者: 单独用射线查命中盒。
	   不能用"hull 对命中盒"——引擎对 hull 会把每个 hitbox 摊成 AABB, 擦边也会判成命中,
	   实测就是这样让预测线提前停下的(石头其实从旁边飞过去了)。 */
	TR_TraceRayFilter(from, to, MASK_SHOT, RayType_EndPoint, Pred_SurvivorFilter, 0);
	if (TR_DidHit())
	{
		TR_GetEndPosition(endpos);
		float d = GetVectorDistance(from, endpos);
		if (d >= PRED_MIN_STEP_DIST && (best < 0.0 || d < best))
		{
			best	= d;
			bestEnt = TR_GetEntityIndex();
			to[0]	= endpos[0];
			to[1]	= endpos[1];
			to[2]	= endpos[2];
		}
	}

	if (best < 0.0)
		return false; /* 没撞, 或者命中点贴着起点(卡在几何里): 这一步当没撞, 交给后面几步 */

	/* 学到新的隐形阻挡体: 记进忽略名单, 让上层重扫这一步(石头其实会穿过去) */
	if (bestEnt > 0 && bestEnt < sizeof(g_bPredIgnoreEnt) && !g_bPredIgnoreEnt[bestEnt] && bestEnt > MaxClients)
	{
		char cls[64];
		GetEntityClassname(bestEnt, cls, sizeof(cls));

		if (strcmp(cls, "env_physics_blocker") == 0)
		{
			g_bPredIgnoreEnt[bestEnt] = true;
			g_iPredIgnored++;

			PredLog(client, PRED_DEBUG_FULL, "发现隐形物理阻挡体 %s #%d (只挡物理道具, 石头会穿过去), 已加入忽略名单(共 %d 个)",
					cls, bestEnt, g_iPredIgnored);
			return false; /* 让 Pred_StepTrace 重扫 */
		}
	}

	g_iPredHitEnt[client] = bestEnt;
	return true;
}

/* 生还者过滤器: 只有生还者的命中盒挡石头(感染者/世界几何不走这一路) */
bool Pred_SurvivorFilter(int entity, int contentsMask, any data)
{
	return (entity > 0 && entity <= MaxClients && GetClientTeam(entity) == 2);
}

/**
 * 重算抛物线并缓存"画线采样点"——开销都在这一步, 由 tank_pred_interval 节流
 * (每帧只做 Pred_Emit 重发光束, 不含任何 trace, 参考 miwuki 的 Calc_Interval 思路)
 *
 * 推进采用"批量空域 + 疑似逐步精查": 空域一次弦扫 tank_pred_batch 步;
 * 弦上扫到东西就退化成逐步精确检查, 所以既不会漏薄墙, 也不会被抛物线拱起部分骗到
 * (弦在抛物线上方, 弦撞到不代表抛物线会撞)。石头命中即碎, 只算到第一次碰撞。
 */
void Pred_Calc(int client, const float angles[3], const float start[3], const float vel[3])
{
	g_iPredDrawCount[client] = 0;
	g_bPredHasImpact[client] = false;

	float gravityScale = Apex[13].FloatValue;
	if (gravityScale < 0.0)
		return;

	float gravity = ((g_hSvGravity == null) ? 800.0 : g_hSvGravity.FloatValue) * gravityScale;
	float maxTime = Apex[14].FloatValue;

	g_fPredGravity[client] = gravity; /* 调试: 用来确认 sv_gravity 到底读到多少 */

	/* 光束贴图索引: 插件"中途加载"(sm plugins load / reload)会错过 OnMapStart 与 OnConfigsExecuted,
	   这里再兜一次 PrecacheModel —— 该模型若已被其它插件预缓存, 引擎会直接返回已有索引 */
	if (g_iBeamSprite <= 0)
	{
		g_iBeamSprite = PrecacheModel(PRED_BEAM_SPRITE);
		if (PredLogCanSpam(client))
			PredLog(client, PRED_DEBUG_FULL, "光束贴图索引为 0, 已在本图重新预缓存 -> %d (0=画不出来)", g_iBeamSprite);
	}

	float hullMin[3] = { -PRED_HULL_SIZE, -PRED_HULL_SIZE, -PRED_HULL_SIZE };
	float hullMax[3] = { PRED_HULL_SIZE, PRED_HULL_SIZE, PRED_HULL_SIZE };

	int batch = RoundToNearest(Apex[24].FloatValue);
	if (batch < 1)
		batch = 1;
	if (batch > 8)
		batch = 8;

	/* ---- 1) 求第一次碰撞发生的时间(没撞到就是 maxTime), 顺便拿到命中点 ---- */
	float tHit = maxTime;
	bool  hit  = false;
	float hitPos[3];
	float cur[3], probe[3];

	cur[0] = start[0];
	cur[1] = start[1];
	cur[2] = start[2];

	for (float t = 0.0; t < maxTime;)
	{
		float tNext = t + PRED_PHYS_STEP * float(batch);
		if (tNext > maxTime)
			tNext = maxTime;

		Pred_EvalAt(start, vel, gravity, tNext, probe);

		/* 空域快速通道: 这一段连"拱起的弦"都扫不到东西, 抛物线自然也能过。
		   (起点卡在实心里时这一扫也会"假命中", 会掉进下面的逐步精查 —— 那里已经显式识别
		     startsolid 并当作没撞, 代价只是这几帧多几次短扫描, 换来的是不漏掉真墙和生还者) */
		TR_TraceHullFilter(cur, probe, hullMin, hullMax, PRED_WORLD_MASK, TraceFilter_Pred, client);
		if (!TR_DidHit())
		{
			cur[0] = probe[0];
			cur[1] = probe[1];
			cur[2] = probe[2];
			t	   = tNext;
			continue;
		}

		/* 弦上疑似有东西 -> 逐步精查这一段 */
		bool  segHit = false;
		float ts	 = t;
		for (int s = 1; s <= batch && ts < maxTime; s++)
		{
			ts = t + PRED_PHYS_STEP * float(s);
			if (ts > maxTime)
				ts = maxTime;

			Pred_EvalAt(start, vel, gravity, ts, probe);

			if (Pred_StepTrace(client, cur, probe, hullMin, hullMax))
			{
				hit		  = true;
				tHit	  = ts;
				hitPos[0] = probe[0];
				hitPos[1] = probe[1];
				hitPos[2] = probe[2];
				segHit	  = true;
				break;
			}

			cur[0] = probe[0];
			cur[1] = probe[1];
			cur[2] = probe[2];
		}

		if (segHit)
			break;

		t = ts;
	}

	/* ---- 2) 沿抛物线均匀采样成画线端点(有命中时, 末端直接落在真实命中点上) ---- */
	int seg = Apex[15].IntValue;
	if (seg < 1)
		seg = 1;

	float span = hit ? tHit : maxTime;

	/* 长弹道自动加密采样(每 0.25 秒至少一个端点), 保证 5 秒的弹道也是平滑曲线 */
	int autoSeg = RoundToNearest(span / 0.25);
	if (autoSeg > seg)
		seg = autoSeg;
	if (seg > PRED_SEG_MAX)
		seg = PRED_SEG_MAX;
	for (int k = 0; k <= seg; k++)
		Pred_EvalAt(start, vel, gravity, span * float(k) / float(seg), g_fPredDraw[client][k]);

	if (hit)
	{
		g_fPredDraw[client][seg][0] = hitPos[0];
		g_fPredDraw[client][seg][1] = hitPos[1];
		g_fPredDraw[client][seg][2] = hitPos[2];

		g_bPredHasImpact[client] = true;
		g_fPredImpact[client][0] = hitPos[0];
		g_fPredImpact[client][1] = hitPos[1];
		g_fPredImpact[client][2] = hitPos[2];
	}

	g_iPredDrawCount[client] = seg + 1;
	g_fPredImpactTime[client] = span;

	/* 记下本次输入, 供"瞄准/位置/速度没变就不重算"判断 */
	g_fPredCalcAt[client]	  = GetGameTime();
	g_fPredLastStart[client][0] = start[0];
	g_fPredLastStart[client][1] = start[1];
	g_fPredLastStart[client][2] = start[2];
	g_fPredLastVel[client][0] = vel[0];
	g_fPredLastVel[client][1] = vel[1];
	g_fPredLastVel[client][2] = vel[2];
	g_fPredLastAng[client][0] = angles[0];
	g_fPredLastAng[client][1] = angles[1];
	g_fPredLastAng[client][2] = angles[2];
}

/* 该重算了吗(参考 miwuki: 最小间隔 + 瞄准/位置/速度变化检测 + 强制重算上限) */
bool Pred_NeedCalc(int client, const float angles[3], const float start[3], const float vel[3])
{
	if (g_fPredCalcAt[client] <= 0.0)
		return true; /* 还没算过(刚开技能/刚进入扔石过程/自检) */

	float since = GetGameTime() - g_fPredCalcAt[client];
	if (since < 0.0)
		return true; /* 换图等时间回退保护 */

	if (since < Apex[23].FloatValue)
		return false; /* 还没到最小重算间隔: 用缓存重发光束就行 */

	if (since >= PRED_FORCE_INTERVAL)
		return true; /* 再拖就跟不上瞄准了 */

	return (GetVectorDistance(angles, g_fPredLastAng[client]) >= 0.1
			|| GetVectorDistance(start, g_fPredLastStart[client]) >= 1.0
			|| GetVectorDistance(vel, g_fPredLastVel[client]) >= 4.0);
}

/**
 * 用缓存把线发出去(每帧调用, 不含 trace):
 *  1. 前 tank_pred_skip_len 点(默认 120)不画, 避免线条顶在脸上挡视线
 *  2. 整条线往准星右侧让开 tank_pred_off_r 点(参考 miwuki 的视觉起点偏移), 末端收敛回真实落点
 *  3. 命中处画白色落点标记: 向上竖线(仿生还者死亡升天光柱) + 外圈 + 中心小圈
 */
void Pred_Emit(int client)
{
	int count = g_iPredDrawCount[client];
	if (count < 2)
	{
		if (PredLogCanSpam(client))
			PredLog(client, PRED_DEBUG_FULL, "没画线: 采样点只有 %d 个(计算被跳过或重力倍率<0)", count);
		return;
	}

	/* 发射节流: 服务器 100 tick 时 OnPlayerRunCmd 每秒会来 100~200 次, 每帧都发的话
	   同一条线上会同时叠着 4~8 份残影(错开一点就是"一堆光线")。
	   按 tank_pred_emit(默认 0.033 秒 ≈ 30Hz)节流, 配合光束寿命 0.055 秒刚好连成一条。 */
	float now = GetGameTime();
	if (g_fPredEmitAt[client] > 0.0 && (now - g_fPredEmitAt[client]) < Apex[26].FloatValue)
		return;

	g_fPredEmitAt[client] = now;

	/* 光束寿命跟随发射间隔(1.6 倍): 刚好连成一条线, 又只会叠 1~2 份残影.
	   调大 tank_pred_emit 时残影会同步变少、线更干净 */
	float life = Apex[26].FloatValue * 1.6;
	if (life < 0.02)
		life = 0.02;

	int	  last	  = count - 1;
	int	  first	  = 0;
	float skipLen = Apex[20].FloatValue;

	/* 前 tank_pred_skip_len 点(默认 120)不画: 只挡掉贴脸那一段, 不按比例砍掉整条线 */
	if (skipLen > 0.0)
	{
		float acc = 0.0;
		for (int k = 1; k <= last; k++)
		{
			acc += GetVectorDistance(g_fPredDraw[client][k - 1], g_fPredDraw[client][k]);
			if (acc >= skipLen)
			{
				first = k;
				break;
			}
		}
	}

	if (first < 1)
		first = 1;
	if (first > last - 1)
		first = last - 1;
	if (first < 0)
		return;

	int drawn = last - first + 1;

	/* 视觉偏移用的"右/上"基向量: 由起点朝第一段的方向推出来, 不依赖本帧的瞄准角 */
	float dir[3], right[3], up[3] = { 0.0, 0.0, 1.0 }, shift[3];
	dir[0] = g_fPredDraw[client][1][0] - g_fPredDraw[client][0][0];
	dir[1] = g_fPredDraw[client][1][1] - g_fPredDraw[client][0][1];
	dir[2] = g_fPredDraw[client][1][2] - g_fPredDraw[client][0][2];

	float offR = Apex[25].FloatValue;
	if (GetVectorLength(dir) < 0.001 || offR <= 0.0)
		offR = 0.0;
	else
	{
		NormalizeVector(dir, dir);
		GetVectorCrossProduct(dir, up, right);
		NormalizeVector(right, right);
		GetVectorCrossProduct(right, dir, up);
		NormalizeVector(up, up);
	}

	static float line[PRED_SEG_MAX + 1][3];
	int			 n = 0;

	for (int k = first; k <= last; k++)
	{
		float f = 1.0 - float(k - first) / float(drawn - 1); /* 起点处 1 -> 末端 0 */

		/* 右偏(观感, 末端收敛到准星线) + 手部->眼睛的整体位移(平滑后整条线一起平移, 线不抖) */
		shift[0] = right[0] * offR * f + up[0] * PRED_VIS_UP * f;
		shift[1] = right[1] * offR * f + up[1] * PRED_VIS_UP * f;
		shift[2] = right[2] * offR * f + up[2] * PRED_VIS_UP * f;

		line[n][0] = g_fPredDraw[client][k][0] + shift[0];
		line[n][1] = g_fPredDraw[client][k][1] + shift[1];
		line[n][2] = g_fPredDraw[client][k][2] + shift[2];
		n++;
	}

	int	  color[4]	 = { PRED_COLOR_R, PRED_COLOR_G, PRED_COLOR_B, 255 };
	int	  white[4]	 = { 255, 255, 255, 255 };
	int	  whiteDim[4] = { 255, 255, 255, 190 };
	float width		 = Apex[17].FloatValue;

	for (int i = 1; i < n; i++)
	{
		TE_SetupBeamPoints(line[i - 1], line[i], g_iBeamSprite, 0, 0, 0, life,
						   width, width, 0, 0.0, color, 0);
		TE_SendToClient(client);
	}

	if (PredLogCanSpam(client))
		PredLog(client, PRED_DEBUG_FULL, "已画线: 端点=%d 段=%d(隐藏前 %d 点) 线长=%.0f 点 起点(%.0f,%.0f,%.0f) 命中=%s 落点(%.0f,%.0f,%.0f) 预测飞行 %.2f 秒",
			   count, n - 1, first, GetVectorDistance(line[0], line[n - 1]),
			   line[0][0], line[0][1], line[0][2],
			   g_bPredHasImpact[client] ? "是" : "否(到最长预测时间)",
			   g_fPredImpact[client][0], g_fPredImpact[client][1], g_fPredImpact[client][2],
			   g_fPredImpactTime[client]);

	if (!g_bPredHasImpact[client])
		return;

	/* 光柱/圆圈贴在"画线末端"上(而不是未平移的物理落点), 保证线尾和光柱是一体的 */
	float pos[3];
	pos[0] = line[n - 1][0];
	pos[1] = line[n - 1][1];
	pos[2] = line[n - 1][2] + PRED_IMPACT_LIFT;

	float markH	 = Apex[21].FloatValue;
	float markW	 = (width > PRED_MARK_WIDTH) ? width : PRED_MARK_WIDTH;

	/* 向上的白色竖线(光柱): 仿生还者死亡升天的那道光柱, 所以给得高一点粗一点, 远距离也看得见 */
	if (markH > 0.0)
	{
		float top[3];
		top[0] = pos[0];
		top[1] = pos[1];
		top[2] = pos[2] + markH;

		int markColor[4] = { PRED_MARK_R, PRED_MARK_G, PRED_MARK_B, 255 };

		TE_SetupBeamPoints(pos, top, g_iBeamSprite, 0, 0, 0, life,
						   markW, markW, 0, 0.0, markColor, 0);
		TE_SendToClient(client);

		/* 每发只记一条: 确认光柱发出去了、发在哪个坐标、预测停在了什么东西上 */
		if (!g_bPredMarkLogged[client])
		{
			g_bPredMarkLogged[client] = true;

			char hitName[64];
			int	 hitEnt = g_iPredHitEnt[client];

			if (hitEnt > 0 && hitEnt <= MaxClients)
				FormatEx(hitName, sizeof(hitName), "玩家 %N", hitEnt);
			else if (hitEnt > MaxClients && IsValidEntity(hitEnt))
			{
				char cls[64];
				GetEntityClassname(hitEnt, cls, sizeof(cls));
				FormatEx(hitName, sizeof(hitName), "%s #%d", cls, hitEnt);
			}
			else
				strcopy(hitName, sizeof(hitName), "世界几何");

			PredLog(client, PRED_DEBUG_FULL, "落点标记: 动作=%d 光柱高=%.0f 粗=%.0f 圈半径=%.0f 位置(%.0f,%.0f,%.0f)[物理落点(%.0f,%.0f,%.0f) 位移%.0f] 距起点 %.0f 点 预测飞行 %.2f 秒 重力=%.0f 忽略阻挡=%d 停在=%s",
					g_iPredSeq[client], markH, markW, Apex[22].FloatValue, pos[0], pos[1], pos[2],
					g_fPredImpact[client][0], g_fPredImpact[client][1], g_fPredImpact[client][2],
					GetVectorDistance(pos, g_fPredImpact[client]),
					GetVectorDistance(pos, g_fPredDraw[client][0]), g_fPredImpactTime[client],
					g_fPredGravity[client], g_iPredIgnored, hitName);
		}
	}

	/* 落点圆圈: 外圈(细) + 中心小圈(粗), 形态参考 miwuki 的落点光圈 */
	float ringR = Apex[22].FloatValue;
	if (ringR >= 10.0)
	{
		TE_SetupBeamRingPoint(pos, ringR - 1.0, ringR, g_iBeamSprite, 0, 0, 0, life,
							  1.8, 0.0, whiteDim, 0, 0);
		TE_SendToClient(client);
	}
	if (ringR > 0.0)
	{
		TE_SetupBeamRingPoint(pos, 3.0, 4.0, g_iBeamSprite, 0, 0, 0, life,
							  2.5, 0.0, white, 0, 0);
		TE_SendToClient(client);
	}
}

/* 画预测轨迹: 抛物线受间隔节流重算, 光束每帧重发(所以线不会闪) */
void Pred_DrawPath(int client, const float angles[3], const float start[3], const float vel[3])
{
	if (Pred_NeedCalc(client, angles, start, vel))
		Pred_Calc(client, angles, start, vel);

	Pred_Emit(client);
}

/* 蓄力掷石期间画预测轨迹(angles 为本帧指令的视角角度); 对任何玩家每帧调用一次 */
void Pred_Update(int client, const float angles[3])
{
	/* 0) 调试: 掷出后的石头实飞采样(与预测对比用) */
	Pred_TrackFlight(client);

	/* 1) 自检(!predtest): 不看技能、不看蓄力, 直接按当前瞄准画线 */
	if (GetGameTime() <= g_fPredTestUntil[client])
	{
		float s[3], vis[3], v[3], local[3];

		GetPredStart(client, angles, vis);
		GetPredPhysOffset(client, angles, local); /* 自检: 直接用当前手部偏移, 方便对照 */
		Pred_ComposeStart(vis, angles, local, s);
		Pred_FixStart(client, s, vis); /* 自检也要自救: 蓄力时手部附着点在低处, 起点常被压到脚边 */
		GetPredVelocity(client, angles, v);

		Pred_DrawPath(client, angles, s, v);
		return;
	}

	/* 与跟踪石头互斥(双保险): 跟踪开着时不画预测, 并顺手把状态清掉 */
	if (IsTrac[client] && IsPred[client])
	{
		IsPred[client] = false;
		PredLog(client, PRED_DEBUG_KEY, "检测到跟踪石头技能已开启, 自动关闭轨迹预测");
	}

	/* 2) 是否正在"扔石头": 起手动作开的窗口(主判据) 或 手里确实捏着那颗石头(辅助) */
	int	 rock	 = GetHeldRock(client);
	bool inThrow = (GetGameTime() <= g_fPredUntil[client]) || (rock != -1);

	/* 石头还在手上就续窗(有的情况起手动作不触发/动画不同步) */
	if (rock != -1 && GetGameTime() > g_fPredUntil[client])
		g_fPredUntil[client] = GetGameTime() + PRED_WINDOW;

	/* 进入/离开"扔石头"过程各记一条: 一眼能看出识别到没有、技能开了没有 */
	if (inThrow != g_bPredActive[client])
	{
		g_bPredActive[client] = inThrow;
		if (inThrow)
			PredLog(client, PRED_DEBUG_FULL, "开始预测: 技能=%s, 石头=%s, 贴图=%d, 线宽=%.1f",
					IsPred[client] ? "开启" : "未开启(需先输入 !pred 或 !yc)",
					(rock != -1) ? "已在手上" : "还没生成", g_iBeamSprite, Apex[17].FloatValue);
		else
			PredLog(client, PRED_DEBUG_FULL, "预测结束(掷出/取消/窗口到期)");
	}

	if (!inThrow || !IsPred[client])
		return;

	/* 物理起点用引擎真正的出石点(手部), 落点才准; 画线锚点用稳定的眼睛位置,
	   两者的差值作为"整体位移"平滑后只作用于画面 —— 这样转视角不会滞后, 也不会因为
	   手感抖动把落点算歪(姿势越高手部离眼睛越远, 位移越大, 但落点始终按手部算) */
	float start[3], vis[3], local[3], vel[3];

	GetPredStart(client, angles, vis); /* 稳定的眼睛锚点 */

	/* 出手偏移用"固定值": 优先这个姿势学到过的(来自引擎真实出石点), 否则用本发起手快照。
	   绝不实时跟随手臂动画 —— 挥臂会让起点绕着眼点转约 90 度, 那正是线的抖动来源。 */
	g_iPredPoseSlot[client] = 0;

	if (g_iPredSeq[client] >= 49 && g_iPredSeq[client] <= 51)
	{
		int pose = g_iPredSeq[client] - 48;
		if (g_bPredPoseOk[client][pose])
			g_iPredPoseSlot[client] = pose;
	}

	int slot = g_iPredPoseSlot[client];

	if (g_bPredPoseOk[client][slot])
	{
		local[0] = g_fPredPoseOff[client][slot][0];
		local[1] = g_fPredPoseOff[client][slot][1];
		local[2] = g_fPredPoseOff[client][slot][2];
	}
	else
	{
		local[0] = 0.0; /* 什么都没有(极罕见): 退回纯眼睛锚点, 至少不抖 */
		local[1] = 0.0;
		local[2] = 0.0;
	}

	/* 安全上限: 实测三种姿势偏移 41/92/109 点, 超出 150 一定是取样或状态出了问题, 夹住 */
	float offLen = GetVectorLength(local);
	if (offLen > PRED_OFF_MAX)
	{
		ScaleVector(local, PRED_OFF_MAX / offLen);
		PredLog(client, PRED_DEBUG_FULL, "警告: 出手偏移 |%.0f| 超过上限 %.0f, 已夹住(用%s)", offLen, PRED_OFF_MAX,
				(g_iPredPoseSlot[client] > 0) ? "学到的姿势值" : "起手快照");
	}

	Pred_ComposeStart(vis, angles, local, start);

	/* 起点自救: 合成出来的起点如果插在脚下地面/台阶里(或者贴着地面), 引擎第一步扫描就会
	   当成撞地 —— 线刚出来就被"脚下"切断、落点插在脚边。这里只在起点确实不可用时才上抬,
	   正常起点一个坐标都不改, 所以平时的轨迹形状和落点跟改动前完全一样。
	   (放在"本发起点"日志之前, 日志里打的就是真正拿去算的起点) */
	Pred_FixStart(client, start, vis);

	if (!g_bPredStartLogged[client])
	{
		g_bPredStartLogged[client] = true;
		PredLog(client, PRED_DEBUG_KEY, "本发起点: 动作=%d 偏移|%.0f|(右%.0f 上%.0f 前%.0f, 用%s) 起点(%.0f,%.0f,%.0f) 眼位(%.0f,%.0f,%.0f)",
				g_iPredSeq[client], GetVectorLength(local), local[0], local[1], local[2],
				(g_iPredPoseSlot[client] > 0) ? "学到的姿势值" : "起手快照",
				start[0], start[1], start[2], vis[0], vis[1], vis[2]);
	}

	GetPredVelocity(client, angles, vel);

	/* 逐帧抖动诊断: 扔石窗口刚开始的 0.5 秒内, 每帧把"起点/角度/速度"的帧间变化打出来,
	   这样残余抖动到底来自哪一项, 一条日志就能定案(debug=2) */
	if (Apex[16].IntValue >= PRED_DEBUG_FULL && GetGameTime() <= g_fPredDbgUntil[client])
	{
		float dStart = GetVectorDistance(start, g_fPredPrevStart[client]);
		float dAng	 = GetVectorDistance(angles, g_fPredPrevAng[client]);
		float dVel	 = FloatAbs(GetVectorLength(vel) - g_fPredPrevVel[client]);
		float rawVel[3], loc2[3];

		GetEntPropVector(client, Prop_Data, "m_vecVelocity", rawVel);
		GetAngleVectors(angles, loc2, NULL_VECTOR, NULL_VECTOR);
		NormalizeVector(loc2, loc2);
		float vAlong = rawVel[0] * loc2[0] + rawVel[1] * loc2[1] + rawVel[2] * loc2[2];

		PredLog(client, PRED_DEBUG_FULL, "帧诊断: 起点(%.1f,%.1f,%.1f) 帧间位移=%.2f 角度帧间差=%.3f 初速帧间差=%.2f 坦克速度|%.1f|(前向%.1f) 偏移|%.1f|",
				start[0], start[1], start[2], dStart, dAng, dVel, GetVectorLength(rawVel), vAlong,
				GetVectorLength(local),
				(g_iPredPoseSlot[client] > 0) ? "学到的姿势值" : "起手快照");

		g_fPredPrevStart[client][0] = start[0];
		g_fPredPrevStart[client][1] = start[1];
		g_fPredPrevStart[client][2] = start[2];
		g_fPredPrevAng[client][0]	= angles[0];
		g_fPredPrevAng[client][1]	= angles[1];
		g_fPredPrevAng[client][2]	= angles[2];
		g_fPredPrevVel[client]		= GetVectorLength(vel);
	}

	Pred_DrawPath(client, angles, start, vel);
}

/* -----------------------------------------------------------
	其他自定义
----------------------------------------------------------- */
void Reset(int client)
{
	IsBhop[client]	= false;
	IsTrac[client]	= false;
	IsPred[client]	= false;
	Dir[client]		= 0;
	Posture[client] = 0;
	TracLim[client] = 0;
	BhopLim[client] = 0;
	PredLim[client] = 0;

	/* 连跳检测: 新一条命重新开始计数, 按键快照清空 */
	BhopBtn[client] = 0;
	BhopDetect_Reset(client);

	/* 新一条命/新回合不继承跟踪石的连续命中约束 */
	g_iLastTracTarget[client] = 0;


	/* 新一条命/新回合不继承"手里那颗石头"的记录(实体本身会被引擎清掉) */
	g_iHeldRock[client]	  = INVALID_ENT_REFERENCE;
	g_bPredActive[client] = false;

	/* 轨迹预测的临时状态(扔石窗口/平滑/自检/日志节流/实飞记录)一并清掉 */
	g_fPredUntil[client]	 = 0.0;
	g_fPredTestUntil[client] = 0.0;
	g_fPredLogAt[client]	 = 0.0;
	g_bPredSmoothInit[client] = false;
	g_bFlyActive[client]	 = false;
	g_iFlyRock[client]		 = INVALID_ENT_REFERENCE;
	Pred_ResetCache(client);

	/* 坦克视野: 新一条命/新回合不继承上一辆坦克的存活计时、范围提示、
	   看不见计时、扣控状态与掉控标记(掉控标记只在 Reset 里清, 见 Timer_TankVision 的说明) */
	VisionClearTracking(client);
	g_bVisionDropped[client] = false;
}

/* ===========================================================================
	坦克视野(自 l4d2_tank_vision.sp 合并) —— 实现
   =========================================================================== */

void OnTankVisionCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	StartTankVisionTimer();
}

void StartTankVisionTimer()
{
	/* 换图时引擎可能已经把 TIMER_REPEAT 干掉, 句柄这时是失效的: 先确认有效再 delete,
	   否则会刷 "Invalid Handle"(极端情况下该句柄槽位被复用还会误关别人的定时器) */
	if (g_hTankVisionTimer != null && IsValidHandle(g_hTankVisionTimer))
		delete g_hTankVisionTimer;

	g_hTankVisionTimer = null;

	/* 不论开关都常驻这个定时器(体里自己判断开关): 万一 cvar 在本插件加载前就已设好, 不会触发变更钩子 */
	float fInterval = Apex[APEX_TV_INTERVAL].FloatValue;
	if (fInterval < 0.05)
		fInterval = 0.05;
	if (fInterval > 1.0)
		fInterval = 1.0;

	g_hTankVisionTimer = CreateTimer(fInterval, Timer_TankVision, _, TIMER_REPEAT);
}

/* 清掉某个玩家的坦克视野跟踪状态(不是坦克 / 插件关闭 / Reset 时调用) */
void VisionClearTracking(int client)
{
	if (client < 1 || client > MaxClients)
		return;

	g_fTankCtrlStart[client]   = 0.0;
	g_fVisionAliveBias[client]= 0.0;
	g_fVisionRangeMark[client] = -1.0;
	g_fVisionUnseenAt[client]  = 0.0;
	g_bVisionPenalty[client]   = false;
	g_bVisionAnnounced[client] = false; /* 下一辆坦克重新播报一次“插件接管控制权” */
	g_bVisionTracHit[client]   = false;
	g_fVisionTracAt[client]    = 0.0;
	g_iVisionMeter[client]     = 0;
	g_fVisionEngineAt[client]  = 0.0;
	g_fVisionEngAcc[client]    = 0.0;
	g_fVisionEngSpan[client]   = 0.0;
	g_fVisionEngRate[client]   = 0.0;
	g_bTVGateLogged[client]    = false;
	g_fVisionMeterF[client]    = 0.0;
	g_fVisionPayAt[client]     = 0.0;
	g_fVisionSampleAt[client]  = 0.0;
	g_fVisionChatAt[client]    = 0.0;
}

void VisionClearAll()
{
	for (int i = 1; i <= MaxClients; i++)
		VisionClearTracking(i);
}

/* ===========================================================================
	坦克视野: 存活计时跨控制权交接(给克 / 二控)延续
   ---------------------------------------------------------------------------
   存活秒数是"这辆坦克活了多久", 不是"这个控制者控了多久":
     同一辆坦克交给下一位玩家(给克/二控)时, 存活计时必须接着算, 否则
     l4d2_tankvision_start_time(接管门槛) / l4d2_tankvision_alive_time(存活满门限
     的扣控加成) / t1~t3_time(范围阶梯) 每次交接都从头开始, 这些"按时间生效"的
     控制权消耗量就永远看不到效果(用户反馈的"二控后大概率失效")。
   只有新 spawn 的一辆坦克才从 0 开始。
   =========================================================================== */

/* 某个控制者身上记着的"这辆坦克已存活秒数"(没在跟踪就是 0) */
float VisionTankAgeSeconds(int client)
{
	if (client < 1 || client > MaxClients)
		return 0.0;

	if (g_fTankCtrlStart[client] > 0.0)
		return VisionAliveSeconds(client);

	return 0.0;
}

/* 坦克暂时没人控(掉控到下一个控制者接手之间): 把这辆坦克已经活了多少秒存成"孤儿",
   下一位接手的人接着算。窗口外的旧记录自动作废, 免得串到别的坦克上。 */
void VisionStashTankAge(float fAlive)
{
	if (fAlive <= 0.0)
		return;

	float fNow = GetGameTime();

	/* 同一时刻只留一份: 12v12 多坦克时保留更大的那个(更老的坦克), 小的不覆盖 */
	if (g_fVisionOrphanAt > 0.0 && (fNow - g_fVisionOrphanAt) <= VISION_CARRY_WINDOW
		&& g_fVisionOrphanAlive >= fAlive)
		return;

	g_fVisionOrphanAlive = fAlive;
	g_fVisionOrphanAt	 = fNow;
}

/* 回合结束/换图: 所有"交接中的存活计时"作废, 下一回合的坦克从 0 开始 */
void VisionResetHandoverState()
{
	g_fVisionOrphanAlive = 0.0;
	g_fVisionOrphanAt	 = 0.0;

	for (int i = 1; i <= MaxClients; i++)
	{
		g_fVisionCarryAlive[i] = 0.0;
		g_fVisionCarryAt[i]	   = 0.0;
		g_bVisionCarryValid[i] = false;
		g_bVisionCarriedOut[i] = false;
	}
}

/* 取出"接手过来的存活秒数"(没有/过期就是 0)。
   @param bHandover	输出: 这次是不是控制权交接/接手(交接来的控制段要清掉上一任的 per-life 闩锁)
   @param bAllowOrphan	是否允许使用"孤儿"记录(新 spawn 的坦克不该继承上一辆的孤儿) */
float VisionTakeHandoverAge(int client, float fNow, bool &bHandover, bool bAllowOrphan = true)
{
	bHandover = false;

	if (client < 1 || client > MaxClients)
		return 0.0;

	float fAlive = 0.0;

	/* 1) 交接钩子点名的存活秒数(给克/二控: 旧控制者 -> 新控制者) */
	if (g_bVisionCarryValid[client])
	{
		if ((fNow - g_fVisionCarryAt[client]) <= VISION_CARRY_WINDOW)
		{
			fAlive	 = g_fVisionCarryAlive[client] + (fNow - g_fVisionCarryAt[client]);
			bHandover = true;
		}

		g_bVisionCarryValid[client] = false;
		g_fVisionCarryAlive[client] = 0.0;
		g_fVisionCarryAt[client]	= 0.0;
	}

	/* 2) 掉控到接手之间的孤儿记录(没有交接钩子的路径, 例如 AI 坦克 -> 玩家) */
	if (!bHandover && bAllowOrphan
		&& g_fVisionOrphanAt > 0.0 && (fNow - g_fVisionOrphanAt) <= VISION_CARRY_WINDOW)
	{
		fAlive	 = g_fVisionOrphanAlive + (fNow - g_fVisionOrphanAt);
		bHandover = true;
	}

	if (bHandover)
	{
		/* 孤儿记录只给下一个接手的人用一次 */
		g_fVisionOrphanAlive = 0.0;
		g_fVisionOrphanAt	 = 0.0;
	}

	return (fAlive > 0.0) ? fAlive : 0.0;
}

/* 控制权交接(ZombieManager::ReplaceTank): 把"这辆坦克已经活了多久"交给下一个控制者。
   只记交接信息, 真正的控制段初始化在 VisionBeginControlSegment 里做
   (那一刻引擎还没完成职业切换, 读不到新坦克的怒气)。 */
void VisionCarryTankAge(int iOldTank, int iNewTank)
{
	if (iNewTank < 1 || iNewTank > MaxClients || iOldTank == iNewTank)
		return;

	float fNow   = GetGameTime();
	float fAlive = VisionTankAgeSeconds(iOldTank);

	g_fVisionCarryAlive[iNewTank] = (fAlive > 0.0) ? fAlive : 0.0;
	g_fVisionCarryAt[iNewTank]	  = fNow;
	g_bVisionCarryValid[iNewTank] = true;

	/* 旧控制者的存活秒数已经交出去了: 它之后不再是坦克时不要再存一份孤儿(会串到别的坦克) */
	if (iOldTank >= 1 && iOldTank <= MaxClients)
		g_bVisionCarriedOut[iOldTank] = true;

	VisionLog("%N -> %N 控制权交接: 存活计时延续 %.0f 秒(二控不重置)", iOldTank, iNewTank, fAlive);
}

/* 开一个新的"控制权段": 第一次看到这个玩家开坦克 / 交接后接手 / 掉控后再接手都走这里。
   - 存活计时: 用交接/孤儿记录延续(同一辆坦克跨控制者累计), 没有记录才从 0 开始
   - per-life 闩锁: 交接过来的新控制段必须清掉(否则上一任的掉控闩锁/写满标记会把
     这辆坦克剩下的时间全部锁死, 表现就是二控后按时间增加/减少的消耗量一起失效)
   调用方负责保证 g_fTankCtrlStart[client] <= 0(即"这一段还没开始")。 */
void VisionBeginControlSegment(int client, float fNow)
{
	bool  bHandover = false;
	float fAlive	= VisionTakeHandoverAge(client, fNow, bHandover);
	int   iMeter0	= GetEntProp(client, Prop_Send, "m_frustration");

	g_fTankCtrlStart[client]   = fNow;
	g_fVisionAliveBias[client] = fAlive;
	g_bVisionCarriedOut[client] = false;
	g_fVisionRangeMark[client] = -1.0;
	g_fVisionUnseenAt[client]  = 0.0;
	g_bVisionPenalty[client]   = false;
	g_bVisionAnnounced[client] = false; /* 新的控制权段(没走 spawn 的换人): 这一辆坦克要能再播报一次 */
	g_bVisionTracHit[client]   = false;
	g_fVisionTracAt[client]	   = 0.0;
	g_fVisionChatAt[client]	   = 0.0;
	g_fVisionSampleAt[client]  = fNow;
	g_iVisionMeter[client]	   = iMeter0;
	g_fVisionEngineAt[client]  = 0.0;
	g_fVisionPayAt[client]	   = fNow;
	g_fVisionMeterF[client]	   = float(iMeter0);
	g_fVisionFullAt[client]	   = 0.0;
	g_bVisionWroteFull[client] = false;
	g_bVisionDropTried[client] = false;

	if (bHandover)
	{
		/* 控制权交接: 上一任留下的 per-life 闩锁全部作废(这辆坦克现在归新控制者),
		   但存活计时不清(见上面的 fAlive) */
		g_bVisionDropped[client] = false;
		return;
	}

	/* 不是交接(插件中途加载 / 同一玩家二次拿到同一辆坦克但没经过交接钩子):
	   怒气不满说明这不是"已经掉控的那一辆", 把掉控闩锁解开,
	   否则这一回合就再也不会被本模块惩罚 */
	if (g_bVisionDropped[client] && iMeter0 < 50)
		g_bVisionDropped[client] = false;
}

/*=========================================================================
|                    坦克视野: 控制权交接 forward                         |
=========================================================================*/

/* ZombieManager::ReplaceTank(同一辆坦克换控制者) */
public void L4D_OnReplaceTank(int tank, int newtank)
{
	VisionCarryTankAge(tank, newtank);
}

/* l4d2lib 兼容 forward(由 left4dhooks 发出; 本仓库的 l4d_tank_control_eq 也依赖它):
   掉控 -> AI -> 给克给下一位 这条"接手 AI 坦克"的路径只有它会报告新旧控制者 */
public void L4D2_OnTankPassControl(int iOldTank, int iNewTank, int iPassCount)
{
	VisionCarryTankAge(iOldTank, iNewTank);
}

/* 按"坦克存活时长"给出这一档的可见范围(后加的档覆盖前面的, 基准 = l4d2_tankvision_range)。
   阶梯档的 range <= 0 视为"这一档不生效"(保持上一档), 不把范围放开成无限:
   range = 0 在下面表示"无限", 配置写 0 的语义必须是"不收紧"而不是"全图可见"。 */
float VisionRangeByAlive(float fAlive)
{
	/* 测试指令强制范围优先(绕过阶梯) */
	if (g_fVisionRangeOverride > 0.0)
		return g_fVisionRangeOverride;

	float fRange = Apex[APEX_TV_RANGE].FloatValue;
	float fTime;
	float fTier;

	fTime = Apex[APEX_TV_T1_TIME].FloatValue;
	fTier = Apex[APEX_TV_T1_RANGE].FloatValue;
	if (fTime > 0.0 && fTier > 0.0 && fAlive >= fTime)
		fRange = fTier;

	fTime = Apex[APEX_TV_T2_TIME].FloatValue;
	fTier = Apex[APEX_TV_T2_RANGE].FloatValue;
	if (fTime > 0.0 && fTier > 0.0 && fAlive >= fTime)
		fRange = fTier;

	fTime = Apex[APEX_TV_T3_TIME].FloatValue;
	fTier = Apex[APEX_TV_T3_RANGE].FloatValue;
	if (fTime > 0.0 && fTier > 0.0 && fAlive >= fTime)
		fRange = fTier;

	if (fRange < 0.0)
		fRange = 0.0;

	return fRange;
}

/* 取控制权插件的 cvar 值(句柄缓存; 对方被热卸载时句柄会失效, 这时重新查一次, 仍没有就用 fallback) */
float VisionControlCvar(ConVar &cv, const char[] name, float fFallback)
{
	if (cv == null || !IsValidHandle(cv))
		cv = FindConVar(name);

	return (cv == null) ? fFallback : cv.FloatValue;
}

/* 每格怒气的基础幅度(%): <=0 时自动读控制权插件的 tankcontrol_trac_base, 缺失按 5 */
float VisionBaseStep()
{
	/* 基础扣控幅度只认本插件自己的 l4d2_tankvision_step(默认 5).
	   以前这里会自动读 tankcontrol_trac_base, 那个 cvar 在某些配置下是 0,
	   结果被夹成 1, 面板上就出现"基础 1" —— 现在不再做这种隐式回退. */
	float f = Apex[APEX_TV_STEP].FloatValue;

	if (f <= 0.0 || f > 100.0)
		f = 5.0;

	return f;
}

/* 接管门槛(秒): 坦克存活满这么久之后, 插件才开始接管控制权 */
float VisionStartTime()
{
	float f = Apex[APEX_TV_START_TIME].FloatValue;
	return (f > 0.0) ? f : 0.0;
}

/* 存活加成门限(秒): 存活满这么久后每秒多扣 1 个点 */
float VisionAliveTime()
{
	float f = Apex[APEX_TV_ALIVE_TIME].FloatValue;
	return (f > 0.0) ? f : 0.0;
}

/* 跟踪石加速持续时长(秒): tankcontrol_trac_after; 0 = 直到坦克死亡/控制权交接 */
float VisionTracAfter()
{
	float f = VisionControlCvar(g_hTankVisionControlAfter, "tankcontrol_trac_after", 0.0);
	return (f > 0.0) ? f : 0.0;
}

/* 插件强制扣控时, 每秒扣多少(四种情况, 叠加):
     正常                          = 基础 base(默认 5)
     存活满 alive_time(4 分钟)     + alive_extra(默认 1) -> 6
     跟踪石命中过生还者            + trac_extra(默认 1)  -> 6
     两者都有                      -> 7 */
float VisionRate(int tank, float fAlive)
{
	float fRate = VisionBaseStep();

	float fAliveTime = VisionAliveTime();
	if (fAliveTime > 0.0 && fAlive >= fAliveTime)
		fRate += Apex[APEX_TV_ALIVE_EXTRA].FloatValue;

	if (g_bVisionTracHit[tank])
		fRate += Apex[APEX_TV_TRAC_EXTRA].FloatValue;

	if (fRate < 1.0)
		fRate = 1.0;
	if (fRate > 100.0)
		fRate = 100.0;

	return fRate;
}

/* 是否已经进入"插件接管控制权"的阶段: 存活满 start_time(默认 3.5 分钟) */
bool VisionTakeover(float fAlive)
{
	return (fAlive >= VisionStartTime());
}

/* 插件统计的"坦克存活秒数" = 真实拿到坦克的时间 + 调试指令的偏移 */
float VisionAliveSeconds(int client)
{
	float fAlive = (g_fTankCtrlStart[client] > 0.0) ? (GetGameTime() - g_fTankCtrlStart[client]) : 0.0;
	return fAlive + g_fVisionAliveBias[client];
}

/* 存活时间把可见范围收紧时通知全体玩家一次(每收紧一档提示一次)。
   判定口径: -1 = 还没观察过这辆坦克 -> 只记录不提示; 0 = 无限; 只有变小才算收紧。 */
void VisionNotifyRange(int tank, float fRange, float fAlive)
{
	float fPrev = g_fVisionRangeMark[tank];

	if (fPrev < 0.0)
	{
		g_fVisionRangeMark[tank] = fRange;
		return;
	}

	bool bTightened = (fRange > 0.0) && (fPrev <= 0.0 || fRange < fPrev - 0.5);

	g_fVisionRangeMark[tank] = fRange;

	if (!bTightened)
		return;

	CPrintToChatAll("%s坦克 {lightgreen}%N{default} 存活 {lightgreen}%d{default} 秒, 视野判定范围收紧到 {lightgreen}%d{default} 单位(超出这个距离的生还者不再算“看得见”)",
		TAG, tank, RoundToNearest(fAlive), RoundToNearest(fRange));
}

/* 视线射线的碰撞过滤: 只让世界几何体挡视线, 忽略所有客户端实体(坦克/生还者/其它感染者) */
public bool VisionTraceFilter(int entity, int contentsMask, any data)
{
	if (entity >= 1 && entity <= MaxClients)
		return false;

	return true;
}

bool VisionLineOfSightClear(const float vStart[3], const float vEnd[3])
{
	Handle hTrace = TR_TraceRayFilterEx(vStart, vEnd, MASK_VISIBLE, RayType_EndPoint, VisionTraceFilter);
	bool bClear = !TR_DidHit(hTrace);
	delete hTrace;

	return bClear;
}

/* 判定"这辆坦克现在看得见生还者吗"。fNearest 输出最近的生还者距离(没有生还者时 0, 只用于调试) */
bool VisionCanSeeSurvivor(int tank, float fRange, float &fNearest)
{
	float vTankEye[3];
	GetClientEyePosition(tank, vTankEye);

	float vAngles[3];
	float vFwd[3];
	GetClientEyeAngles(tank, vAngles);
	GetAngleVectors(vAngles, vFwd, NULL_VECTOR, NULL_VECTOR);

	/* 朝向锥恒定生效: 写 -1 也只退化成前半球, 永远不允许"背后的生还者也算看得见" */
	float fDotMin = Apex[APEX_TV_DOT].FloatValue;
	if (fDotMin < 0.0)
		fDotMin = 0.0;
	if (fDotMin > 1.0)
		fDotMin = 1.0;

	fNearest = 0.0;

	for (int j = 1; j <= MaxClients; j++)
	{
		if (j == tank || !IsValidClient(j) || !IsPlayerAlive(j))
			continue;
		if (GetClientTeam(j) != 2)
			continue;

		float vTarget[3];
		GetClientEyePosition(j, vTarget);

		float fDist = GetVectorDistance(vTankEye, vTarget);
		if (fNearest <= 0.0 || fDist < fNearest)
			fNearest = fDist;

		if (fRange > 0.0 && fDist > fRange)
			continue;

		float vDir[3];
		MakeVectorFromPoints(vTankEye, vTarget, vDir);
		NormalizeVector(vDir, vDir);

		if (GetVectorDotProduct(vFwd, vDir) < fDotMin)
			continue;

		if (VisionLineOfSightClear(vTankEye, vTarget))
			return true;
	}

	return false;
}

/* 详细日志(只在 l4d2_tankvision_debug >= 2 时写服务器日志) */
void VisionLog(const char[] fmt, any ...)
{
	if (Apex[APEX_TV_DEBUG].IntValue < 2)
		return;

	char buf[256];
	VFormat(buf, sizeof(buf), fmt, 2);
	LogMessage("[tankvision] %s", buf);
}

/* -----------------------------------------------------------
	坦克视野测试指令(与原 l4d2_tank_vision.sp 同名)
	  sm_tankvision                 查看当前坦克的视野/扣控状态
	  sm_tankvision_dbg <0|1|2>     调试档位(等同 l4d2_tankvision_debug)
	  sm_tankvision_set <范围> [秒]  临时强制可见范围(0=取消)
	  sm_tankvision_time [秒|+N|-N]  调试: 查看/改插件统计的坦克存活时间(各阶段效果不用真等)
	  sm_tankvision_trac [0|1]      调试: 查看/改坦克的"跟踪石命中"加成状态
	  sm_tankvision_frust [值]      管理员: 查看/设置当前坦克怒气(0=满控制权, 100=掉控)
----------------------------------------------------------- */

Action Cmd_TankVision(int client, int args)
{
	ReplyToCommand(client, "[坦克视野] 开关=%d 判定间隔=%.2f 秒 调试=%d 强制范围=%s",
		Apex[APEX_TV_ENABLE].IntValue,
		Apex[APEX_TV_INTERVAL].FloatValue, Apex[APEX_TV_DEBUG].IntValue,
		(g_fVisionRangeOverride > 0.0) ? "有(测试)" : "无");

	int iShown = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsTank(i) || !IsPlayerAlive(i))
			continue;

		iShown++;

		float fAlive   = VisionAliveSeconds(i);
		float fRange   = VisionRangeByAlive(fAlive);
		float fNearest = 0.0;
		bool  bSee     = VisionCanSeeSurvivor(i, fRange, fNearest);
		float fUnseen  = (g_fVisionUnseenAt[i] > 0.0) ? (GetGameTime() - g_fVisionUnseenAt[i]) : 0.0;
		int   iMeter   = GetEntProp(i, Prop_Send, "m_frustration");
		float fBase     = VisionBaseStep();
		float fRateNow  = VisionRate(i, fAlive);
		float fStart    = VisionStartTime();
		float fAliveT   = VisionAliveTime();
		bool  bTakeover = VisionTakeover(fAlive);
		bool  bGameDrop = (g_fVisionEngineAt[i] > 0.0) && ((GetGameTime() - g_fVisionEngineAt[i]) <= 2.0);

		ReplyToCommand(client, "[坦克视野] %N 存活 %.0f 秒 | 范围 %.0f | 看得见 %s(最近 %.0f) | 怒气 %d/100 | 看不见 %.0f 秒 | %s",
			i, fAlive, fRange, bSee ? "是" : "否", fNearest, iMeter, fUnseen,
			g_bVisionPenalty[i] ? "插件正在强制扣控" : "未扣控");

		float fGateVal = -1.0;
		float fLastSeenAgo = -1.0;
		if (GetEntityAddress(i) != Address_Null)
		{
			fGateVal = view_as<float>(LoadFromAddress(GetEntityAddress(i) + view_as<Address>(g_iTVGateOffset), NumberType_Int32));

			float fLastSeen = view_as<float>(LoadFromAddress(GetEntityAddress(i) + view_as<Address>(g_iTVLastSeenOffset), NumberType_Int32));
			fLastSeenAgo = GetGameTime() - fLastSeen;

			/* 明显不合理(没被写过/是别的数据) -> 打 -1 */
			if (fLastSeenAgo < 0.0 || fLastSeenAgo > 3600.0)
				fLastSeenAgo = -1.0;
		}

		ReplyToCommand(client, "[坦克视野]   版本 %s | 基础 %.1f | 引擎速率 %.1f%%/秒(近2秒) | 怒气闸门 %.3f | 引擎最后看见 %.1f 秒前 | 接管门槛 %.0f 秒(%s) | 强制速率 %.1f%%/秒 = 基础 %.1f + 存活 %s + 跟踪石 %s | 游戏自己在掉控=%s | 强制模式=%s | 掉控闩锁=%s",
			PLG_VERS, fBase, g_fVisionEngRate[i], fGateVal, fLastSeenAgo,
			fStart, bTakeover ? "已达" : "未达",
			fRateNow, fBase,
			(fAliveT > 0.0 && fAlive >= fAliveT) ? "1" : "0",
			g_bVisionTracHit[i] ? "1" : "0",
			bGameDrop ? "是" : "否",
			Apex[APEX_TV_FORCE].BoolValue ? "总是强制" : "让位",
			g_bVisionDropped[i] ? "已锁(本命不再写怒气)" : "无");
	}

	if (iShown == 0)
		ReplyToCommand(client, "[坦克视野] 当前没有活着的真人坦克(AI 坦克不接管)");

	return Plugin_Handled;
}

Action Cmd_TankVisionDebug(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "[坦克视野] 当前调试档位 %d (0=安静 1=每秒一条(含是否看得见) 2=再加范围/扣控日志)",
			Apex[APEX_TV_DEBUG].IntValue);
		return Plugin_Handled;
	}

	int iVal = GetCmdArgInt(1);
	if (iVal < 0)
		iVal = 0;
	if (iVal > 2)
		iVal = 2;

	Apex[APEX_TV_DEBUG].SetInt(iVal);
	ReplyToCommand(client, "[坦克视野] 调试档位 = %d", iVal);

	return Plugin_Handled;
}

Action Cmd_TankVisionSet(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "[坦克视野] 用法: sm_tankvision_set <范围> [秒]   0 = 取消强制");
		ReplyToCommand(client, "[坦克视野] 当前强制: %s | 基准 %.0f | 阶梯 %.0f@%.0fs / %.0f@%.0fs / %.0f@%.0fs",
			(g_fVisionRangeOverride > 0.0) ? "有" : "无",
			Apex[APEX_TV_RANGE].FloatValue,
			Apex[APEX_TV_T1_RANGE].FloatValue, Apex[APEX_TV_T1_TIME].FloatValue,
			Apex[APEX_TV_T2_RANGE].FloatValue, Apex[APEX_TV_T2_TIME].FloatValue,
			Apex[APEX_TV_T3_RANGE].FloatValue, Apex[APEX_TV_T3_TIME].FloatValue);
		return Plugin_Handled;
	}

	float fRange = GetCmdArgFloat(1);
	if (fRange < 0.0)
		fRange = 0.0;

	float fSec = (args >= 2) ? GetCmdArgFloat(2) : 0.0;
	if (fSec < 0.0)
		fSec = 0.0;

	g_fVisionRangeOverride = (fRange > 0.0) ? fRange : 0.0;
	g_fVisionRangeOverrideUntil = (fRange > 0.0 && fSec > 0.0) ? (GetGameTime() + fSec) : 0.0;

	if (fRange > 0.0)
		CPrintToChatAll("%s[坦克视野] 测试: 可见范围强制为 {lightgreen}%.0f{default} 单位%s",
			TAG, fRange, (fSec > 0.0) ? " (限时, 到点自动恢复)" : " (常驻, sm_tankvision_set 0 取消)");
	else
		CPrintToChatAll("%s[坦克视野] 测试: 已取消强制范围, 回到阶梯逻辑", TAG);

	return Plugin_Handled;
}

/* 调试: 改插件统计的"坦克存活时间", 这样 3.5/4/4.5/5.5/6.5 分钟各阶段不用真等。
   用法: sm_tankvision_time 300 | sm_tankvision_time +60 | sm_tankvision_time -60 | 不带参数=查看 */
Action Cmd_TankVisionTime(int client, int args)
{
	int iShown = 0;

	if (args < 1)
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			if (!IsTank(i) || !IsPlayerAlive(i))
				continue;

			iShown++;

			float fAlive = VisionAliveSeconds(i);

			ReplyToCommand(client, "[坦克视野] %N 存活 %.0f 秒 | 范围 %.0f | 接管=%s | 存活加成=%s",
				i, fAlive, VisionRangeByAlive(fAlive),
				VisionTakeover(fAlive) ? "是" : "否",
				(VisionAliveTime() > 0.0 && fAlive >= VisionAliveTime()) ? "是" : "否");
		}

		if (iShown == 0)
			ReplyToCommand(client, "[坦克视野] 当前没有活着的真人坦克");

		ReplyToCommand(client, "[坦克视野] 用法: sm_tankvision_time <秒>  (也可 +60 / -60 相对调整)");
		return Plugin_Handled;
	}

	char sArg[32];
	GetCmdArg(1, sArg, sizeof(sArg));

	bool  bRelative = (sArg[0] == '+' || sArg[0] == '-');
	float fValue    = StringToFloat(sArg);
	float fNow      = GetGameTime();

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsTank(i) || !IsPlayerAlive(i))
			continue;

		iShown++;

		/* 只改偏移, 不动真实起点: 直接写 g_fTankCtrlStart = now - 秒数 在地图刚加载
		   (GetGameTime 还很小)时会算成负数, 被下面的"首次识别"逻辑当成 0 重新起算,
		   表现出来就是"存活 X 秒从头开始"。 */
		float fRaw = (g_fTankCtrlStart[i] > 0.0) ? (fNow - g_fTankCtrlStart[i]) : 0.0;
		float fCur = fRaw + g_fVisionAliveBias[i];
		float fNew = bRelative ? (fCur + fValue) : fValue;

		if (fNew < 0.0)
			fNew = 0.0;

		g_fVisionAliveBias[i] = fNew - fRaw;
		float fAlive = fCur;

		ReplyToCommand(client, "[坦克视野] %N 存活时间 %.0f -> %.0f 秒 | 范围 %.0f | 接管=%s | 存活加成=%s",
			i, fAlive, fNew, VisionRangeByAlive(fNew),
			VisionTakeover(fNew) ? "是" : "否",
			(VisionAliveTime() > 0.0 && fNew >= VisionAliveTime()) ? "是" : "否");

		VisionLog("%N 存活时间被调试指令改为 %.0f 秒", i, fNew);
	}

	if (iShown == 0)
	{
		ReplyToCommand(client, "[坦克视野] 当前没有活着的真人坦克");
		return Plugin_Handled;
	}

	/* 说明: 改存活时间会重算判定范围(存活越久范围越小)。如果改小时间让范围变宽、坦克
	   又刚好看得见生还者, 插件会把它当"重新看见" -> "看不见"计时与扣控状态都会重新开始,
	   这是正常判定, 不是插件重置。想连续看各阶段的扣控数字, 先 sm_tankvision_set 1 固定
	   "看不见", 再只往大改时间(240 -> 270 -> 330 -> 390), 计时就不会断。 */
	ReplyToCommand(client, "[坦克视野] 提示: 改时间会重算判定范围; 若变宽后能看见生还者, \"看不见\"计时会重新开始");

	return Plugin_Handled;
}

/* 调试: 手动开关"跟踪石命中过生还者"加成, 用来测 6%/7% 那两档 */
Action Cmd_TankVisionTrac(int client, int args)
{
	int iShown = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsTank(i) || !IsPlayerAlive(i))
			continue;

		iShown++;

		if (args >= 1)
		{
			bool bOn = (GetCmdArgInt(1) != 0);

			g_bVisionTracHit[i] = bOn;
			g_fVisionTracAt[i]  = GetGameTime();

			ReplyToCommand(client, "[坦克视野] %N 跟踪石加成 = %s", i, bOn ? "开(测试)" : "关");
		}
		else
		{
			ReplyToCommand(client, "[坦克视野] %N 跟踪石加成 = %s", i, g_bVisionTracHit[i] ? "开" : "关");
		}
	}

	if (iShown == 0)
		ReplyToCommand(client, "[坦克视野] 当前没有活着的真人坦克");

	return Plugin_Handled;
}

Action Cmd_TankVisionFrust(int client, int args)
{
	int iShown = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsTank(i) || !IsPlayerAlive(i))
			continue;

		iShown++;

		if (args >= 1)
		{
			int iVal = GetCmdArgInt(1);
			if (iVal < 0)
				iVal = 0;
			if (iVal > TV_FRUSTRATION_MAX)
				iVal = TV_FRUSTRATION_MAX;

			SetEntProp(i, Prop_Send, "m_frustration", iVal);
			g_bVisionDropped[i] = false;

			ReplyToCommand(client, "[坦克视野] %N 怒气设为 %d (0=满控制权, 100=掉控), 掉控闩锁已解开", i, iVal);
		}
		else
		{
			ReplyToCommand(client, "[坦克视野] %N 怒气 %d/100", i, GetEntProp(i, Prop_Send, "m_frustration"));
		}
	}

	if (iShown == 0)
		ReplyToCommand(client, "[坦克视野] 当前没有活着的真人坦克");

	return Plugin_Handled;
}

/* 打开某个坦克的"怒气闸门"(CTerrorPlayer+偏移): 只有 >0 引擎才会累加怒气并触发掉控 */
void VisionOpenGate(int client, const char[] reason)
{
	if (GetEntityAddress(client) == Address_Null)
		return;

	Address addrGate = GetEntityAddress(client) + view_as<Address>(g_iTVGateOffset);
	float fGate = view_as<float>(LoadFromAddress(addrGate, NumberType_Int32));

	if (fGate <= 0.0)
	{
		StoreToAddress(addrGate, view_as<int>(1.0), NumberType_Int32);
		LogMessage("[tankvision] %N 怒气闸门 %.3f -> 1.0 (%s, 偏移 +0x%X)", client, fGate, reason, g_iTVGateOffset);
	}
}

/* 怒气满了但引擎不判掉控(它认为玩家坦克还看得见生还者)时, 由插件走原生换控:
   1) 有排队的感染者玩家 -> L4D_ReplaceTank(tank, 玩家) = 二控(同一辆坦克控制权交给下一位);
   2) 没有玩家、场上又感染者 AI(bot) -> 交给 bot = 变 AI;
   3) 都没有 -> 保持怒气满, 等引擎自己处理。 */
void VisionForceDrop(int tank)
{
	int target = 0;
	bool bBot = false;

	if (GetFeatureStatus(FeatureType_Native, "GetTankSelection") == FeatureStatus_Available)
	{
		int sel = GetTankSelection();

		if (sel > 0 && sel <= MaxClients && sel != tank && IsClientInGame(sel)
			&& !IsFakeClient(sel) && GetClientTeam(sel) == 3)
			target = sel;
	}

	if (target == 0)
	{
		for (int j = 1; j <= MaxClients; j++)
		{
			if (j == tank || !IsClientInGame(j) || !IsFakeClient(j))
				continue;
			if (GetClientTeam(j) != 3)
				continue;

			target = j;
			bBot = true;
			break;
		}
	}

	if (target == 0)
	{
		LogMessage("[tankvision] %N 怒气已满, 但引擎不判掉控且没有可接手的玩家/AI -> 保持怒气满", tank);
		return;
	}

	if (GetFeatureStatus(FeatureType_Native, "L4D_ReplaceTank") != FeatureStatus_Available)
	{
		LogMessage("[tankvision] %N 怒气已满, 但 L4D_ReplaceTank 不可用 -> 无法强制掉控", tank);
		return;
	}

	PrintToChatAll("%s坦克 {lightgreen}%N{default} 控制权由插件收回(%s)", TAG, tank, bBot ? "交给 AI" : "二控给下一位");
	LogMessage("[tankvision] %N 强制掉控 -> %N (bot=%d)", tank, target, bBot ? 1 : 0);

	L4D_ReplaceTank(tank, target);
}

/* 让引擎也认为"这辆坦克很久没看见生还者": 把 CTerrorPlayer 里记录的
   「最后看见生还者时刻」往老里写。引擎下一次 UpdateZombieFrustration 就会按
   "看不见"处理 -> 怒气累加到 100 -> 原生掉控(有玩家=二控, 没玩家=AI)。 */
void VisionForceBlind(int tank)
{
	if (GetEntityAddress(tank) == Address_Null)
		return;

	Address addr = GetEntityAddress(tank) + view_as<Address>(g_iTVLastSeenOffset);
	float fOld = GetGameTime() - 60.0;

	StoreToAddress(addr, view_as<int>(fOld), NumberType_Int32);
}

Action Timer_TankVision(Handle timer)
{
	if (!Apex[APEX_TV_ENABLE].BoolValue)
	{
		VisionClearAll();
		return Plugin_Continue;
	}

	float fNow = GetGameTime();
	int   iDebug = Apex[APEX_TV_DEBUG].IntValue;

	/* 测试指令的强制范围到期后自动回到阶梯逻辑 */
	if (g_fVisionRangeOverrideUntil > 0.0 && fNow >= g_fVisionRangeOverrideUntil)
	{
		g_fVisionRangeOverride = 0.0;
		g_fVisionRangeOverrideUntil = 0.0;
		CPrintToChatAll("%s[坦克视野] 测试强制范围已到期, 回到阶梯逻辑", TAG);
	}

	for (int i = 1; i <= MaxClients; i++)
	{
		/* 只接管"活着的坦克"; 尸体也会保留坦克职业, 所以必须判 IsPlayerAlive。
		   这里用 IsTankEntity(含 AI 坦克): AI 坦克不写怒气, 但"这辆坦克活了多久"要继续记,
		   二控/给克交给玩家时存活计时才接得上。 */
		if (!IsTankEntity(i) || !IsPlayerAlive(i))
		{
			/* 掉控(还活着但已经不是坦克): 这辆坦克的存活秒数不丢, 存成孤儿交给下一位控制者;
			   坦克死了就不存 —— 这辆坦克结束了, 新 spawn 的那辆要从 0 开始算。
			   已经通过交接钩子交出去的, 不再重复存(否则这份孤儿会串到别的坦克上)。 */
			if (g_fTankCtrlStart[i] > 0.0 && IsPlayerAlive(i) && !g_bVisionCarriedOut[i])
				VisionStashTankAge(VisionAliveSeconds(i));

			VisionClearTracking(i);
			/* 掉控标记故意不在这里清: 掉控后玩家可能短暂变成幽灵, 引擎若又把控制权还回来
			   而没触发新的 spawn, 每 tick 清标记会让"回控"重新发生。标记只在 Reset() 里清。 */
			continue;
		}

		/* AI 坦克(掉控后引擎接管的那辆): 只延续存活计时, 不写怒气、不判视野 */
		if (IsFakeClient(i))
		{
			if (g_fTankCtrlStart[i] <= 0.0)
			{
				bool bHandover = false;
				int	 iMeterBot = GetEntProp(i, Prop_Send, "m_frustration");

				g_fVisionAliveBias[i]	 = VisionTakeHandoverAge(i, fNow, bHandover);
				g_fTankCtrlStart[i]	   = fNow;
				g_fVisionSampleAt[i]	 = fNow;
				g_bVisionCarriedOut[i] = false;

				/* 这一段的状态按"新控制段"初始化: bot 槽位可能随时被加入的玩家顶替,
				   届时玩家接手的是干净状态(存活计时照旧延续) */
				g_iVisionMeter[i]	  = iMeterBot;
				g_fVisionMeterF[i]	  = float(iMeterBot);
				g_bVisionDropped[i]	  = false;
				g_bVisionWroteFull[i] = false;
				g_bVisionDropTried[i] = false;
				g_fVisionFullAt[i]	  = 0.0;
				g_fVisionUnseenAt[i]  = 0.0;
				g_bVisionPenalty[i]	  = false;
				g_bVisionAnnounced[i] = false;
				g_bVisionTracHit[i]	  = false;
				g_fVisionTracAt[i]	  = 0.0;
				g_fVisionEngineAt[i]  = 0.0;
			}
			else if (g_fVisionAliveBias[i] <= 0.0)
			{
				/* 接手那一帧孤儿记录还没写下来(同一 tick 内的处理顺序问题): 这里补上 */
				bool  bHandover = false;
				float fCarryAge = VisionTakeHandoverAge(i, fNow, bHandover);

				if (fCarryAge > 0.0)
					g_fVisionAliveBias[i] = fCarryAge;
			}

			continue;
		}

		/* 第一次看到这个玩家开坦克 = 开一个新的控制权段; 换人/重开都靠这个自动重算。
		   存活计时在交接时延续(见 VisionCarryTankAge / VisionStashTankAge),
		   二控只清这一段的闩锁, 不清存活计时。 */
		if (g_fTankCtrlStart[i] <= 0.0)
			VisionBeginControlSegment(i, fNow);

		float fDt = fNow - g_fVisionSampleAt[i];
		if (fDt < 0.01)
			fDt = 0.01;
		g_fVisionSampleAt[i] = fNow;

		float fAlive = VisionAliveSeconds(i);
		float fRange = VisionRangeByAlive(fAlive);

		/* 跟踪石加速状态到期(tankcontrol_trac_after > 0 时是限时的; 0 = 直到死亡/交接) */
		if (g_bVisionTracHit[i])
		{
			float fTracAfter = VisionTracAfter();
			if (fTracAfter > 0.0 && g_fVisionTracAt[i] > 0.0 && (fNow - g_fVisionTracAt[i]) >= fTracAfter)
			{
				g_bVisionTracHit[i] = false;
				VisionLog("%N 跟踪石加速时长已到(%.0f 秒), 恢复基础幅度", i, fTracAfter);
			}
		}

		if (Apex[APEX_TV_NOTIFY].BoolValue)
			VisionNotifyRange(i, fRange, fAlive);

		int iMeter = GetEntProp(i, Prop_Send, "m_frustration");

		/* 真的掉控过(tank_frustrated 事件) -> 这条命不再写怒气, 否则引擎会把控制权还回玩家 */
		if (g_bVisionDropped[i])
		{
			g_iVisionMeter[i] = iMeter;
			continue;
		}

		/* 怒气满了但引擎还没掉控: 很常见, 坦克刚出生有 z_frustration_spawn_delay(这里 30 秒)
		   的保护期, 期间引擎不处理掉控(除非这段时间对生还者造成伤害)。
		   这是我们自己写上去的 100, 不能当成"已经掉控"去闩锁, 否则这辆坦克这条命就再也不会扣了。 */
		if (iMeter >= TV_FRUSTRATION_MAX && !g_bVisionWroteFull[i])
		{
			g_bVisionWroteFull[i] = true;

			if (iDebug >= 1)
				LogMessage("[tankvision] %N 怒气已满: 等坦克玩家自己看不到生还者约 1 秒(z_frustration_los_delay)后, 引擎才判无控制权(有玩家=二控, 无玩家=AI)", i);
		}

		/* 判断"游戏自己是不是在掉控": 在不是本插件写入的情况下怒气上涨 = 引擎判定看不到生还者。
		   (本插件写入后会同步 g_iVisionMeter, 所以自己的写不会被算成引擎的) */
		int iEngDelta = iMeter - g_iVisionMeter[i];
		if (iEngDelta > 0)
		{
			g_fVisionEngineAt[i] = fNow;
			g_fVisionEngAcc[i]  += float(iEngDelta);
		}

		g_fVisionEngSpan[i] += fDt;
		if (g_fVisionEngSpan[i] >= 2.0)
		{
			g_fVisionEngRate[i] = g_fVisionEngAcc[i] / g_fVisionEngSpan[i];
			g_fVisionEngAcc[i]  = 0.0;
			g_fVisionEngSpan[i] = 0.0;
		}

		g_iVisionMeter[i] = iMeter;

		/* 怒气闸门: 插件刷出来的坦克这个字段常是 0, 引擎会每帧把怒气清 0 ->
		   既不会累加也不会触发掉控(插件写 100 也会被抹掉).
		     gate=1 常开: 引擎恢复原生累积(会提前掉控);
		     gate=2 只在插件扣满 100 时打开: 平时引擎不累积(不提前掉控), 到点点闸门让引擎掉控. */
		if (Apex[APEX_TV_GATE].IntValue == 1)
			VisionOpenGate(i, "gate=1 常开");

		float fNearest = 0.0;
		bool  bSee = VisionCanSeeSurvivor(i, fRange, fNearest);

		/* ---------------- 看得见: 怒气写回 0, 不掉控 ---------------- */
		if (bSee)
		{
			if (g_fVisionUnseenAt[i] > 0.0)
			{
				g_fVisionUnseenAt[i] = 0.0;
				g_bVisionPenalty[i]  = false;

				VisionLog("%N 重新看见生还者, 停止扣控制权(范围 %d)", i, RoundToNearest(fRange));
			}

			if (Apex[APEX_TV_SEEN_CLEAR].BoolValue && iMeter > 0)
				SetEntProp(i, Prop_Send, "m_frustration", 0);

			g_iVisionMeter[i] = Apex[APEX_TV_SEEN_CLEAR].BoolValue ? 0 : iMeter;

			if (iDebug >= 1 && (fNow - g_fVisionChatAt[i]) >= 1.0)
			{
				g_fVisionChatAt[i] = fNow;
				CPrintToChatAll("%s[tankvision] {lightgreen}%N{default} 存活 %d 秒 | 范围 %d | 看得见{green}是{default}(最近 %d) | 怒气 %d(已清 0, 不扣)",
					TAG, i, RoundToNearest(fAlive), RoundToNearest(fRange), RoundToNearest(fNearest), iMeter);
			}

			continue;
		}

		/* ---------------- 看不见: 插件接管控制权 ---------------- */
		if (g_fVisionUnseenAt[i] <= 0.0)
			g_fVisionUnseenAt[i] = fNow;

		float fUnseen = fNow - g_fVisionUnseenAt[i];

		/* 接管门槛: 存活满 start_time(默认 3.5 分钟)之前完全不碰怒气 */
		if (!VisionTakeover(fAlive))
		{
			g_bVisionPenalty[i] = false;
			continue;
		}

		float fRate = VisionRate(i, fAlive);

		/* 游戏自己也在掉怒气(引擎判定看不到)时:
		   force=1(默认) -> 插件仍然按自己的速率接管, 读数会覆盖引擎那点累积, 保证每秒 5/6/7;
		   force=0        -> 让位, 用游戏原生的掉控节奏。 */
		bool bGameDeducting = (g_fVisionEngineAt[i] > 0.0) && ((fNow - g_fVisionEngineAt[i]) <= 2.0);

		if (bGameDeducting && !Apex[APEX_TV_FORCE].BoolValue)
		{
			g_bVisionPenalty[i] = false;

			if (iDebug >= 1 && (fNow - g_fVisionChatAt[i]) >= 1.0)
			{
				g_fVisionChatAt[i] = fNow;
				CPrintToChatAll("%s[tankvision] {lightgreen}%N{default} 看不见 %d 秒 | 范围 %d | 怒气 %d | 游戏自己在掉控(插件让位, 原生约 5%%/秒) | 插件速率应为 %d%%/秒",
					TAG, i, RoundToNearest(fUnseen), RoundToNearest(fRange), iMeter, RoundToNearest(fRate));
			}

			continue;
		}

		if (!g_bVisionPenalty[i])
		{
			g_bVisionPenalty[i] = true;
			g_fVisionMeterF[i]  = float(iMeter);

			/* 全服播报每辆坦克只发一次.
			   g_bVisionPenalty 会在“重新看见生还者”“接管门槛未到”“游戏自己在掉控(force=0)”几处被清回 false,
			   坦克“看得见 <-> 看不见”反复切换时就会反复进这个分支 -> 全服反复刷同一条.
			   所以播报挂在独立的一次性标记 g_bVisionAnnounced 上, 它只在
			   Reset()/坦克出生/死亡/断线/新的控制权段 里清(见 VisionClearTracking 与 Timer_TankVision 的起点块),
			   因此同一辆坦克只会播一次, 下一辆坦克仍然照常播报. */
			if (Apex[APEX_TV_NOTIFY].BoolValue && !g_bVisionAnnounced[i])
			{
				g_bVisionAnnounced[i] = true;

				CPrintToChatAll("%s坦克 {lightgreen}%N{default} 存活已满 {lightgreen}%d{default} 秒, 插件接管控制权: 每秒 {lightgreen}%d%%{default}{default}%s",
					TAG, i, RoundToNearest(VisionStartTime()), RoundToNearest(fRate),
					bGameDeducting ? " (游戏也在掉控, 读数按插件速率覆盖)" : "");
			}

			/* 日志故意保持“每次进入接管阶段都记”: 只有 debug>=2 才写, 而它正是排查
			   “penalty 反复切换/速率变化”的唯一证据链, 只记一次反而看不出反复. */
			VisionLog("%N 存活 %.0f 秒 -> 插件接管控制权: %d%%/秒 (引擎自己在掉控=%s)",
				i, fAlive, RoundToNearest(fRate), bGameDeducting ? "是" : "否");
		}

		/* 怒气被引擎/别的插件大幅回填(变小很多) -> 把插件读数重新对齐, 免得下一秒跳回高位 */
		if (float(iMeter) < g_fVisionMeterF[i] - 5.0)
			g_fVisionMeterF[i] = float(iMeter);

		/* 接管: 用插件自己的读数(每秒 +fRate)直接覆盖 m_frustration,
		   这样不管引擎那点累积, 面板上看到的就是 5/6/7% 每秒。 */
		g_fVisionMeterF[i] += fRate * fDt;
		if (g_fVisionMeterF[i] < 0.0)
			g_fVisionMeterF[i] = 0.0;
		if (g_fVisionMeterF[i] > float(TV_FRUSTRATION_MAX))
			g_fVisionMeterF[i] = float(TV_FRUSTRATION_MAX);

		int iWant = RoundToNearest(g_fVisionMeterF[i]);
		if (iWant != iMeter)
			SetEntProp(i, Prop_Send, "m_frustration", iWant);

		g_iVisionMeter[i] = iWant;

		/* 让引擎也判定"看不见"(不依赖玩家自己跑到盲区): 写老"最后看见时间" */
		if (Apex[APEX_TV_FORCE_BLIND].BoolValue)
			VisionForceBlind(i);

		/* 扣到顶: 打开闸门, 让引擎自己走"tank_frustrated -> 掉控/二控" */
		if (iWant >= TV_FRUSTRATION_MAX && Apex[APEX_TV_GATE].IntValue >= 2)
			VisionOpenGate(i, "插件扣满 100, 让引擎掉控");

		/* 满 100 后给引擎 1 秒自己处理(玩家坦克自己看不见时会走原生掉控);
		   还没掉就由插件走原生换控: 有玩家->二控, 没玩家->AI */
		if (iWant >= TV_FRUSTRATION_MAX)
		{
			if (g_fVisionFullAt[i] <= 0.0)
				g_fVisionFullAt[i] = fNow;

			if (!g_bVisionDropTried[i] && Apex[APEX_TV_FORCE_DROP].BoolValue
				&& (fNow - g_fVisionFullAt[i]) >= 1.0)
			{
				g_bVisionDropTried[i] = true;
				VisionForceDrop(i);
			}
		}



		if (iDebug >= 1 && (fNow - g_fVisionChatAt[i]) >= 1.0)
		{
			g_fVisionChatAt[i] = fNow;
			CPrintToChatAll("%s[tankvision] {lightgreen}%N{default} 看不见 %d 秒 | 范围 %d | 怒气 {lightgreen}%d{default} -> {lightgreen}%d{default} (+%d/秒 = 基础 %d + 存活 %s + 跟踪石 %s) | 游戏自己在掉控=%s",
				TAG, i, RoundToNearest(fUnseen), RoundToNearest(fRange), iMeter, iWant,
				RoundToNearest(fRate), RoundToNearest(VisionBaseStep()),
				(VisionAliveTime() > 0.0 && fAlive >= VisionAliveTime()) ? "1" : "0",
				g_bVisionTracHit[i] ? "1" : "0",
				bGameDeducting ? "是" : "否");
		}
	}

	return Plugin_Continue;
}
