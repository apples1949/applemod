/*
 * ============================================================================
 * L4D2 Bot Low HP Guard (12v12)
 *
 * 面向 applemod12v12 配置：只处理"非玩家操控的生还者"（AI 生还者 / bot）。
 *
 * 核心逻辑：
 *   当 AI 生还者的"总血量"（实血 m_iHealth + 虚血 / 临时血量 healthBuffer）
 *   合计 <= 阈值（1.2.0 起默认 10）时进入"守护状态"：
 *     1. 间歇性闪【白色】轮廓（参考 l4d2_tank_defib_revive / LMC_Black_and_White_Notifier
 *        的写法：m_iGlowType=3 + m_glowColorOverride + m_nGlowRange，
 *        1.1.0 起再补 m_nGlowRangeMin（witch_glow 同款）+ m_bFlashing，
 *        由定时器按固定节奏开关，形成"闪"的效果）；
 *     2. 免疫任何伤害（SDKHook_OnTakeDamage 直接 Handled，参考 rygive 的 OnTakeDamage）；
 *     3. 免疫任何特殊感染者的控制技能（舌头/扑击/骑乘/冲撞，走 Left4DHooks 的前置
 *        forward，参考 rygive 的 ReleaseControl 用法）；
 *     4. 若进入守护状态时已经被控住，立即解控（舌头拖拽 / 猎人扑倒 / 猴子骑乘 /
 *        牛冲撞与捶打）；
 *     5. 虚血冻结：守护期间虚血不再自然流失（按定时器把 healthBuffer 写回原值）。
 *
 *   另外（与血量无关的兜底）：
 *     未被玩家操控的生还者倒地后自动救起，每次数上限（默认 1 次 / 回合）。
 *     这条是为了应付"生还者被控倒地后玩家离开服务器，变成无人接管的 bot，
 *     没人来救"的情况。次数在回合开始时重置。
 *
 *   1.1.0 变更（按玩家反馈）：
 *     - 蓝色轮廓在游戏里看不出来 -> 改成白色（默认 "255 255 255"），并补上
 *       m_nGlowRangeMin（witch_glow 用的是 type3+color+rangeMin+range 四件套）；
 *       去掉 1.0.0 里那道 HasEntProp 门（它把整段发光静默跳过了），
 *       改成直接写属性（与 LMC / extendedsight / witch_glow 同款做法）。
 *     - 闪烁：默认同时写 m_bFlashing 让引擎闪，并由定时器按 0.9s 节奏开关兜底。
 *     - 新规则：场上"非玩家操控的生还者"数量 **超过** l4d2_bot_guard_max_bots（默认 3）时，
 *       免伤 / 免控 / 自动救起 全部不生效（轮廓仍保留，方便看出谁血量低）。
 *     - 新增排查命令 sm_botguard_status / sm_botguard_test（管理员）。
 *
 *   1.2.2 变更（玩家反馈修复）：
 *     - "其他生还者死完了、三个人机还无敌"：可守护数计算新增前置判定——
 *       场上没有任何"玩家操控的存活生还者"（真人全灭/全在旁观）时，可守护数直接 0。
 *     - "无敌状态还会被牛概率撞伤/概率扛走"：守护期间除了 SDKHook_OnTakeDamage，
 *       同时把 m_takedamage 置 0（引擎层免伤，rygive 的 god mode 同款），
 *       离开守护/插件卸载时恢复原值；并新增 L4D2_OnSlammedSurvivor 前置拦截，
 *       挡掉牛把守护中的生还者撞墙致残的那条路径。
 *
 *   1.3.4 变更（按需求）：计算「在场未倒地生还者」时排除终点安全屋内的生还者
 *     - 旧口径：未倒地生还者数 = 存活生还者总数 - 倒地人数（全队 team 2）。
 *     - 新口径：未倒地生还者数 = 存活 + 未倒地 + **不在本关终点安全屋**。
 *       终点安全屋用 Left4DHooks 的 L4D_IsInLastCheckpoint(client) 判定
 *       （left4dhooks.inc:3977-3984：用 info_changelevel 实体的 mins/maxs 做体积判定），
 *       它判的是"结束安全屋"，起点安全屋是另一个 native（L4D_IsInFirstCheckpoint），不会混淆。
 *     - 只改 ratio 的**分子**，分母仍是「存活生还者总数」（用户字面要求只排除这一项）。
 *       因此 ratio 只会持平或变小 → 可守护数只会持平或变少，不会因为这次改动变大。
 *     - 开关 l4d2_bot_guard_exclude_end_saferoom（默认 1），=0 完全回到旧口径。
 *     - 救援关（终局图）没有 info_changelevel 也就没有终点安全屋 → 一律不排除；
 *       native 拿不到时同样自动退回旧口径，不会出现"所有人都在安全屋、守护数为 0"的误判。
 *     - 已经进屋的人只是**不参与名额计算**，不会被强行取消守护（名额缩小时仍按
 *       UpdateGuardSet 的"已守护优先保留"规则处理，不额外踢人）。
 *
 *   1.3.3 变更（按需求）：守护中的 AI 生还者不得自行使用医疗物品
 *     - 接 Actions 扩展（可选依赖，缺失时插件照常工作、只跳过拦截）拦两个引擎 action：
 *         SurvivorTakePills —— 吃药(weapon_pain_pills) 与打针(weapon_adrenaline) 共用这一个
 *                              action（server.dll 里没有独立的 SurvivorUseAdrenaline）；
 *         SurvivorHealSelf  —— 给自己打包(weapon_first_aid_kit)。
 *       OnStart / Update 里直接 result.type = DONE 取消动作（Update 兜住"动作开始后
 *       才进入守护"的情况）；**不拦** SurvivorHealFriend / SurvivorGivePillsToFriend，
 *       那是给队友包扎/递药，守护中的人机照样可以做。
 *     - player_bot_replace 兜底（参考 l4d2_block_bot_pills.sp）：玩家离开、身体交给 bot
 *       接管时，bot 会"继承"玩家手里正在被使用的止痛药/肾上腺素并立刻吃掉。新 bot 满足
 *       ShouldGuard() 且手持 weapon_pain_pills / weapon_adrenaline 时，先 Kill 掉当前物品
 *       实体，再 CreateEntityByName + DispatchSpawn + EquipPlayerWeapon 换一件同款新物品，
 *       打断这次自动服用（物品种类与数量都不变，只是换了实体）。
 *     - 新增 cvar l4d2_bot_guard_block_items（默认 1，中文描述），sm_botguard_status
 *       增加一行显示物品拦截开关 + Actions 扩展是否可用。
 *
 *   1.3.2 变更（按需求）：提示音/文字节流(l4d2_bot_guard_warn_cooldown)默认 3 秒改 1 秒，
 *     打无敌 bot 的提示更及时。
 *
 *   1.3.1 修复（用户实测日志报"音效不存在"，但音效确实存在）：
 *     - 取消 RefreshWarnSound 里的 FileExists 门禁：srcds 端 FileExists（valve 文件系统 +
 *       普通文件系统）对 ui/beep_error01.wav 都返回 false，但 EmitSoundToClient 照样能播
 *       （库存音效由客户端本地文件提供）。现在不再刷假报错、也不再因此跳过预缓存/播放；
 *       诊断结果只由 sm_botguard_status / sm_botguard_warntest 打印。
 *
 *   1.3.0 变更（玩家反馈"打无敌 bot 一脸懵"）：
 *     - 玩家操控的特殊感染者攻击"守护中的 AI 生还者"时，给该特感玩家三渠道提示：
 *         ① 聊天框  ② PrintHintText 屏幕提示  ③ HUD 文字（SetHudTextParams/ShowHudText）
 *       三渠道各自有开关（l4d2_bot_guard_warn_chat / _hint / _hud），默认全开。
 *     - 同时播放"投票失败提示音"（默认 ui/beep_error01.wav，与本仓库 l4d_votes_5_VS
 *       的投票未通过音效同一个文件；可用 l4d2_bot_guard_warn_sound 换成任意 game_sounds 路径）。
 *     - 提示音与文字共用一条节流：同一名特感玩家默认 1 秒内只会被提示一次
 *       （l4d2_bot_guard_warn_cooldown，0 = 不节流），避免连点爪击时刷屏刷音。
 *     - 覆盖的触发点：SDKHook_OnTakeDamage（守护中吃伤害 / 保命判定）、
 *       舌头 / 扑击 / 骑乘 / 牛抱人 / 牛捶打 / 牛撞墙 六个前置拦截 forward。
 *     - 新增管理员命令 sm_botguard_warntest [目标]，不节流地演示一遍提示（验证音效是否存在）。
 *
 *   1.2.0 变更（四条新需求，全部实装）：
 *     - 需求1 移速（**1.6.0 已整段删除**，见下）：
 *       原实现把未接管生还者的 m_flLaggedMovementValue 放大到
 *       l4d2_bot_guard_bot_speed / l4d2_bot_guard_base_speed（330 / 220 = 1.5）。
 *       1.6.0 按用户要求取消：插件不再写 m_flLaggedMovementValue，也不再有这两个 cvar；
 *       人机移动速度完全交还引擎/其它插件。
 *     - 需求2 守护上限：同一时刻最多 l4d2_bot_guard_max_count（默认 3）个未接管生还者
 *       处于守护状态（免疫 / 免控 / 自动救起那套）。**删除** 1.1.0 的
 *       "AI 生还者数量 > l4d2_bot_guard_max_bots 就全部关掉"旧规则（它和新阶梯矛盾），
 *       cvar 同时改名成 l4d2_bot_guard_max_count，语义 = 守护数量硬上限。
 *     - 需求3 守护名额：1.2.1 起改为**按比例**分配（1.2.0 的三条固定阶梯 cvar 已删除）
 *         base  = min(l4d2_bot_guard_max_count(3), 当前存活未接管生还者数量)
 *         ratio = 未倒地生还者数 / 存活生还者总数
 *         可守护数 = round(base * ratio)
 *       两条硬约束：
 *         ① 只剩 1 个（或 0 个）生还者没倒地 -> 取消最后一个守护，直接 0；
 *         ② 还有 >= 2 个生还者站着 -> 至少保留 1 个守护。
 *       推演（12 人满编）：
 *         9 真人 + 3 bot：倒地 0~2 -> 3；3~6 -> 2；7~10 -> 1；11+ -> 0
 *         10 真人 + 2 bot：倒地 0~3 -> 2；4~10 -> 1；11 -> 0
 *       名额分配：已处于守护状态的优先保留；剩余名额按「总血量升序 -> 客户端索引升序」
 *       挑选；名额变少时用 LeaveGuard 释放多余的人（连同发光 netprop 一起还原）。
 *     - 需求4 触发条件：阈值 l4d2_bot_guard_health 默认改为 10（总血量 <= 10 进入守护）；
 *       另外在 SDKHook_OnTakeDamage 里加"保命"：非玩家操控 + 存活未倒地 +
 *       本次伤害 >= 当前总血量 + 还有守护名额 -> 吃掉本次伤害（damage=0 / Handled）、
 *       把虚血清 0、实血设为阈值（默认 10）并立即进入守护状态。
 *       不在守护名额内的 bot 不做保命，照常掉血 / 倒地（否则全队 bot 永远打不死）。
 *
 *   1.4.0 变更（按需求：无限救起 + 轮询所有生还者状态 + 修"挂边卡无敌"）：
 *     - 需求1 无限救起：l4d2_bot_guard_revive_times 语义改成
 *         -1 = 不限次数（新的默认值，无限救起）；0 = 关闭自动救起；>0 = 每回合上限。
 *       原语义（0=关闭、1=每回合一次）里 0 的含义保持不变，避免旧配置被静默改写。
 *     - 需求2 救起后"当作没倒地过"：救起时把 m_currentReviveCount 与 m_bIsOnThirdStrike
 *       一起清零。前者决定"下一次倒地是不是第三次打击"，后者就是黑白/直接死的那个标记，
 *       只清前者会留下黑白状态，两个都清才等于"从没倒过"。
 *     - 需求3 改成循环定时轮询：不再靠 player_incapacitated 事件 + 一次性 timer 救起，
 *       改为由 0.1s 的保护线程持续扫描"所有生还者"的状态（倒地 / 挂边 / 低血 / 挂边坠落），
 *       倒地的 bot 只要符合守护条件就立刻救起（倒地/挂边的判定完全不依赖事件是否漏接，
 *       插件晚加载、bot 早就在地上躺着的情况一样能救）。
 *       救起延迟仍由 l4d2_bot_guard_revive_delay 控制（0 = 发现即救）。
 *     - 需求4 修"挂边死亡坠落状态被守护 → 卡原地无敌"（玩家反馈）：
 *         现象：12 人局里两个 bot 挂在边缘没进守护，等她们挂边到时间往下掉、
 *               进入"坠落死亡"状态时反而进了守护 ⇒ 免伤 + 血量回锁把引擎的死亡流程冻住，
 *               人卡在原地无敌，直到有玩家接管身体才结束，接管瞬间立刻死亡。
 *         根因：守护的挂载条件只看"存活 + 未倒地 + 总血量 <= 阈值"。挂边（m_isHangingFromLedge）
 *               不写 m_isIncapacitated，掉边坠落（m_isFallingFromLedge）更是引擎已经在走
 *               死亡流程 —— 这两种状态都被当成"正常站立的低血 bot"送进了守护。
 *         修复：① ShouldGuard 明确排除挂边 / 掉边坠落（新增 IsOnLedge()）；
 *               ② 保护线程（0.1s）里加硬保险：守护中的人一旦倒地 / 挂边 / 坠落 / 死亡
 *                  立刻 LeaveGuard，把 m_takedamage 与血量锁一起还原，绝不可能冻结死亡流程；
 *               ③ 不再对"掉边坠落"中的人做任何救起/守护写入（那是引擎的死亡流程）。
 *
 *   1.5.0 变更（三条玩家需求，全部实装）：
 *     - 需求1 修"倒地玩家手动旁观 / 掉线 → 再加入游戏 → 白拿一次自动起身"的漏洞：
 *         根因：真人生还者倒地后切到旁观（或掉线被托管），引擎会把他的身体交给一个 bot
 *               顶着（此时 IsFakeClient()==true），并在该 player 实体的 m_humanSpectatorUserID
 *               里记下那个真人的 userid。旧逻辑只认"fake client + 生还者队 + 倒地"，
 *               于是照样把这具"有主的身体"救起来 —— 玩家再加入（身体原样还给他）就是白起身，
 *               而且这具身体当时如果被守护，还会白得一段免伤/免控/发光。
 *         做法：新增 IsIdleBody()（L4D_GetIdlePlayerOfBot -> 属主 userid -> GetClientOfUserId
 *               -> 确认那个 userid 还是个在服务器里旁观队的真人），自动起身与守护（免伤/免控/发光）
 *               都跳过这类身体；真人彻底掉线（userid 失效）时判定不成立，
 *               "无人接管就地兜底起身"的老用途不变。
 *               开关 l4d2_bot_guard_skip_idle_bodies 默认 1；=0 完全回到 1.4.0 的行为。
 *               （1.6.0 起本插件已不再写移速，这条"移速不排除空闲身体"的取舍随之作废。）
 *     - 需求2 自动起身血量默认 30 -> 1（l4d2_bot_guard_revive_health 下界仍是 1）：
 *         起身后实血写成 1 点、虚血一并清 0（否则"总血量"不是 1），并保持"当作没倒地过"
 *         （m_currentReviveCount + m_bIsOnThirdStrike 在引擎起身之后清零，顺序不要调换）。
 *         血量 1 会让 bot 起身瞬间就可能被再次打倒，与 0.1s 轮询叠加会变成
 *         "起身 -> 倒地 -> 再起身"的循环，因此起身成功后开一个极短的伤害保护窗口
 *         （REVIVE_PROTECT_TIME，只挡"这一下会当场再打倒他"的伤害；一个到期时间戳，无累积状态）。
 *     - 需求3 起身提示文案去掉"无限/不限"的口径（玩家反馈"现在是无限起身"）：
 *         旧文案在 revive_times<0 时写"倒地次数已清零"、状态页写"不限(无限救起)"，
 *         读起来像"无限起身"。统一成"已自动起身（血量 N，倒地次数已清零）"，
 *         有限次数模式保留剩余次数；cvar 描述与 sm_botguard_status 改成"不设上限"口径。
 *
 *   1.6.0 变更（用户两条要求，全部实装）：
 *     - 需求1 起身提示不再输出"倒地次数已清零"：
 *         1.5.0 把每一次成功起身都写成"已自动起身（血量 N，倒地次数已清零）"，
 *         玩家反馈这句不该出现。现在文案只报"血量 N"（有限次数模式仍报剩余/已用完），
 *         不再提倒地次数；属性照旧清零（m_currentReviveCount / m_bIsOnThirdStrike），
 *         只是**不显示**，行为不变。
 *     - 需求2 取消修改人机移速：删除 1.2.0 的整套移速逻辑
 *         （l4d2_bot_guard_bot_speed / l4d2_bot_guard_base_speed 两个 cvar、
 *          GetBotSpeedScale / ShouldApplyBotSpeed / UpdateBotSpeed、g_bSpeedApplied、
 *          卸载与换图时的还原、OnConVarChanged 里的立即重写、sm_botguard_status 的移速读数）。
 *         插件从此不再写 m_flLaggedMovementValue，人机移速完全按引擎原版。
 *         注意：cfg 里原来那两行 confogl_addcvar 也一并删掉 —— cvar 不存在时 confogl 会把它
 *         记成"pending late-bind"并在每次 confogl_setcvars 报 missing，留着会刷日志。
 *   1.6.1 修复（用户反馈"有时守护状态下的人机不会正确提示守护"）：
 *     - 根因1（主因）：节流表按「攻击者」一维存放（g_fWarnLast[attacker]）。
 *       同一名特感玩家在 l4d2_bot_guard_warn_cooldown（默认 1 秒）内攻击**第二只**守护中的人机时，
 *       整条提示（提示音 + 三渠道文字）被直接吞掉；而节流命中前又已经记过时间戳，
 *       玩家看到的上一条提示里写的还是上一只 bot 的名字 —— 表现就是"有时打了守护中的人机却没正确提示"。
 *       12v12 同时最多 3 只人机处于守护，这条路径很容易踩到。
 *       修复：节流表改成 g_fWarnLast[attacker][victim] 二维表，按「攻击者 × 目标 bot」成对计时；
 *       同一只 bot 仍然按冷却节流（防连点爪击刷屏刷音），换一只 bot 立刻重新提示，名字一定是刚打的那只。
 *     - 根因2：提示只挂在"伤害被拦截"和六个前置 forward 上，**强制解控**这条路完全不提示。
 *       典型场景：低血人机还没轮到守护（Timer_Tick 每 0.9 秒一轮），特感先扑住 / 拖走它，
 *       下一轮进入守护时由 EnterGuard / Timer_Protect / Timer_Tick 里的 ReleaseControl 强行解控 ——
 *       技能凭空失效，特感玩家却收不到任何提示。
 *       修复：ReleaseControl 现在返回被解掉的控制者，三个调用点用它补发同一条提示（仍然走节流，不会刷屏）。
 *     - 未改动：免疫判定、守护名额分配、发光、自动起身逻辑一律不动；
 *       提示仍然只发给"玩家操控的特感"（IsWarnTarget），AI 特感不刷屏。
 *
 * 安全设计（重要，改动前请先读）：
 *   - 守护状态只对"存活且未倒地、未挂边、未掉边坠落"的 bot 生效。倒地后守护会自动关闭，
 *     避免"倒地 + 免伤 + 不能流血死亡"造成永久卡关；倒地由自动起身兜底
 *     （1.4.0 起默认不设每回合上限）。
 *   - 1.5.0：守护与自动起身都**不碰**"有真人主控的空闲身体"（IsIdleBody）：
 *     玩家倒地后自己切旁观 / 掉线时，身体会被引擎托管成 bot，替它起身或免伤等于让玩家
 *     "旁观一下再加入"白赚一次起身 + 一段无敌。开关 l4d2_bot_guard_skip_idle_bodies（默认 1）。
 *   - 起身血量默认 1 点（l4d2_bot_guard_revive_health），起身后 1 秒内只挡"会当场再打倒他"
 *     的伤害（REVIVE_PROTECT_TIME），避免 1 血起身 -> 立刻倒地 -> 又起身的循环。
 *   - 保护线程里有一道硬保险：守护中的人一旦倒地/挂边/坠落/死亡，立刻退出守护。
 *     1.5.0 起再加一条 0.1s 级的 ShouldGuard 复核（空闲身体 / 真人接管在 0.1 秒内撤守护）。
 *     这是防止"卡原地无敌"的最后一道闸，不要为了省开销删掉。
 *   - 守护结束时会把进入守护前的四个发光 netprop 原值写回去，
 *     避免污染其它插件的发光效果。
 *   - 1.6.0 起本插件**不写** m_flLaggedMovementValue（人机移速交给引擎/其它插件），
 *     所以没有任何移速状态需要在退出/卸载时还原。
 * ============================================================================
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>

// 1.3.3：Actions 扩展（可选依赖）—— 用来拦"守护中的 AI 生还者自行吃药/打针/打包"。
// 用 SourceMod 的标准写法把扩展降级成"可选"：REQUIRE_EXTENSIONS 未定义时，
// actions.inc 里的 __ext_actions 以 required=0 注册、并把原生函数全部 MarkNativeAsOptional，
// 于是扩展缺失时插件照常加载、其余功能照常工作，只有物品拦截不生效
// （OnPluginStart 里用 LibraryExists("actionslib") 判定，缺失时只打一条控制台提示）。
#undef REQUIRE_EXTENSIONS
#include <actions>
#define REQUIRE_EXTENSIONS

#define PLUGIN_VERSION		"1.6.1"

// 1.4.0：起身提示的全局节流（秒）。次数不设上限时如果每救一次就刷一条，12v12 会刷屏。
#define REVIVE_NOTIFY_COOLDOWN	3.0
// 1.4.0：救起失败（引擎没把人拉起来）时的重试间隔（秒），避免每 tick 空转。
#define REVIVE_RETRY_INTERVAL	0.5

// 1.5.0：自动起身后的极短伤害保护窗口（秒）。
// 起身血量默认只有 1 点，起身瞬间被任何一下摸到就会立刻再倒地；配合 0.1s 轮询 +
// revive_delay 会变成"起身 -> 倒地 -> 再起身"的循环（聊天框反复刷提示、人机原地抽搐）。
// 窗口内只挡"这一下会当场把他再打倒"的伤害（见 Hook_OnTakeDamage），不吞小伤害；
// 状态就是一个到期时间戳（g_fReviveProtectUntil），到点自动失效，不累积、不需要清理。
#define REVIVE_PROTECT_TIME	1.0

#define TEAM_SURVIVOR		2
#define TEAM_INFECTED		3
// 1.5.0：旁观队（IsIdleBody 判定"真人正在旁观托管"用）。
// 本文件不 include l4d2util，这里按 l4d2util_constants.inc 的同名值自己定义一份。
#define TEAM_SPECTATOR		1

// m_iGlowType = 3 是 L4D2 的"常亮轮廓"（参考 l4d2_tank_defib_revive 的写法）
#define GLOW_TYPE_CONSTANT	3

ConVar g_cvEnabled;			// 总开关
ConVar g_cvHealth;			// 触发阈值（实血 + 虚血 合计 <= 该值）
ConVar g_cvGlow;			// 是否闪白色轮廓
ConVar g_cvGlowColor;		// 轮廓颜色 "R G B"
ConVar g_cvGlowRange;		// 轮廓可见距离上限
ConVar g_cvGlowRangeMin;	// 轮廓可见距离下限（witch_glow 同款，不写这个有的图不显示）
ConVar g_cvGlowFlash;		// 是否额外写 m_bFlashing（交给引擎闪）
ConVar g_cvInterval;		// 检测/闪烁节奏（秒）
ConVar g_cvProtectInterval;	// 1.2.3：守护中 bot 的解控/血量回锁节奏（秒），与闪烁节奏分开
ConVar g_cvInvincible;		// 免疫任何伤害
ConVar g_cvBlockControl;	// 免疫特感控制 + 已控则解控
ConVar g_cvMaxCount;		// 1.2.0：同时处于守护状态的未接管生还者数量硬上限（原 max_bots）
ConVar g_cvExcludeEndSaferoom;	// 1.3.4：计算守护名额时排除终点安全屋内的生还者
ConVar g_cvReviveTimes;		// 每回合自动起身次数上限（-1 = 不设上限）
ConVar g_cvReviveHealth;	// 自动起身后的血量
ConVar g_cvReviveDelay;		// 倒地后延迟多久起身（秒）
ConVar g_cvNotify;			// 自动起身时是否聊天框提示
ConVar g_cvSkipIdleBodies;	// 1.5.0：跳过"有真人主控的空闲 bot 身体"（旁观/掉线托管）

// 1.3.0：玩家特感攻击"守护中的 AI 生还者"时的提示（提示音 + 三渠道文字）
ConVar g_cvWarn;			// 总开关
ConVar g_cvWarnCooldown;	// 同一名特感玩家的提示间隔下限（秒），默认 1.0
ConVar g_cvWarnSound;		// 提示音路径（相对 sound/ 目录）
ConVar g_cvWarnChat;		// 渠道① 聊天框
ConVar g_cvWarnHint;		// 渠道② PrintHintText
ConVar g_cvWarnHud;			// 渠道③ HUD 文字

// 1.3.3：守护中的 AI 生还者禁止自行吃药/打针/打包（需要 Actions 扩展）
ConVar g_cvBlockItems;	// 是否拦截"守护中自行使用医疗物品"

bool	g_bGuarded[MAXPLAYERS + 1];			// 当前是否处于守护状态（只看血量）
bool	g_bGlowProps[MAXPLAYERS + 1];		// 该客户端是否有完整的发光 netprop（仅作诊断用，不再作为写入门的开关）
int		g_iOrigGlowType[MAXPLAYERS + 1];	// 进入守护前的 m_iGlowType
int		g_iOrigGlowColor[MAXPLAYERS + 1];	// 进入守护前的 m_glowColorOverride
int		g_iOrigGlowRange[MAXPLAYERS + 1];	// 进入守护前的 m_nGlowRange
int		g_iOrigGlowRangeMin[MAXPLAYERS + 1];	// 进入守护前的 m_nGlowRangeMin
int		g_iOrigTakeDamage[MAXPLAYERS + 1];		// 进入守护前的 m_takedamage（1.2.2：守护期间引擎层免伤）
float	g_fTempStash[MAXPLAYERS + 1];		// 守护开始时冻结的虚血值
int		g_iReviveLeft[MAXPLAYERS + 1];		// 本回合剩余的自动起身次数（-1 = 不设每回合上限）
float	g_fTestGlowUntil[MAXPLAYERS + 1];	// 调试用：到该时刻前强制给该客户端上轮廓

// 1.4.0：轮询式救起的状态
//   g_fReviveAt        计划救起的游戏时间（0 = 当前没有计划）
//   g_bReviveCounted   本次倒地/挂边是否已经扣过救起次数（失败重试时不重复扣）
float	g_fReviveAt[MAXPLAYERS + 1];
bool	g_bReviveCounted[MAXPLAYERS + 1];
float	g_fNotifyNextAt;					// 1.4.0：救起提示的全局节流时间戳

// 1.5.0：起身后的极短伤害保护窗口（REVIVE_PROTECT_TIME）。
// 0 / 过期 = 没有保护；只有一个时间戳，到点自动失效，不会残留状态。
float	g_fReviveProtectUntil[MAXPLAYERS + 1];

// 1.6.1：节流表从「按攻击者」的一维表改成「攻击者 × 目标 bot」二维表。
// 一维表会让同一名特感玩家在冷却内打第二只守护中的人机时整条提示被吞掉（见文件头 1.6.1）。
float	g_fWarnLast[MAXPLAYERS + 1][MAXPLAYERS + 1];	// [attacker][victim] 上次收到"打不动"提示的游戏时间
char	g_sWarnSound[PLATFORM_MAX_PATH];	// 1.3.0：解析后的提示音路径（空 = 不播放）

int		g_iGlowColorPacked;					// 打包后的颜色值（R | G<<8 | B<<16）
bool	g_bBlinkPhase;						// 闪烁相位（每 tick 取反）

// 1.3.3：Actions 扩展是否可用（LibraryExists("actionslib")，含晚加载/卸载刷新）。
// false 时物品拦截整段跳过，插件其余功能完全不受影响。
bool g_bActionsAvailable;

// 1.2.0：守护名额相关的统计值（每 tick 刷新，sm_botguard_status 直接读）
int		g_iAiSurvivors;						// 当前"存活且未被玩家接管"的生还者数量
int		g_iDownCount;						// 全队（team 2）倒地人数（m_isIncapacitated=1）
int		g_iGuardAllowed;					// 可守护数（1.2.1 起按比例计算，见 ComputeAllowedGuards）
int		g_iGuardCount;						// 当前实际处于守护状态的人数

Handle	g_hTickTimer;
Handle	g_hProtectTimer;					// 1.2.3：高频保护定时器（守护中的 bot 每 0.1s 解控 + 血量回锁）
int		g_iGuardHealth[MAXPLAYERS + 1];		// 守护期间锁定的实血值（挡住不走 OnTakeDamage 的掉血，例如 spitter 酸液）

// 1.3.4：终点安全屋排除的运行期状态
//   g_bNtvLastCheckpoint   L4D_IsInLastCheckpoint 是否可用（inc 里是 MarkNativeAsOptional）
//   g_bHasEndSaferoom      本图是否存在终点安全屋（存在 info_changelevel 实体才算）
//   g_bEndSaferoomChecked  本回合是否已经算过上面两项（换图 / round_start 会重置）
bool g_bNtvLastCheckpoint;
bool g_bHasEndSaferoom;
bool g_bEndSaferoomChecked;
bool g_bNtvLastCheckpointWarned;	// "native 不可用"的控制台提示只打一次

public Plugin myinfo =
{
	name        = "L4D2 Bot Low HP Guard (12v12)",
	author      = "apples1949",
	description = "非玩家操控的生还者总血量<=阈值时闪白色轮廓（可闪烁）/免疫伤害/免疫特感控制/被控即解控，并支持自动起身（默认不设每回合上限，轮询所有生还者状态并在倒地/挂边时立刻起身）；1.2.0 追加守护数量阶梯；1.3.0 追加玩家特感攻击守护中的人机时的投票失败提示音+三渠道无敌提示（1.3.2 起节流默认 1 秒）；1.3.3 追加守护中禁止吃药/打包/打针（需 Actions 扩展）；1.3.4 计算在场未倒地生还者时排除终点安全屋内的生还者；1.4.0 修复挂边/掉边坠落被守护导致卡原地无敌；1.5.0 跳过有真人主控的空闲 bot 身体（旁观/掉线托管不再白拿起身与守护）、起身血量默认 1 点；1.6.0 取消修改人机移速（不再写 m_flLaggedMovementValue）、起身提示不再显示倒地次数；1.6.1 修复「有时守护中的人机不提示」：提示节流改为按「攻击者 × 目标人机」成对计时，并补上强制解控时的提示",
	version     = PLUGIN_VERSION,
	url         = "N/A"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	if (GetEngineVersion() != Engine_Left4Dead2)
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 2.");
		return APLRes_SilentFailure;
	}

	return APLRes_Success;
}

public void OnPluginStart()
{
	g_cvEnabled = CreateConVar("l4d2_bot_guard_enabled",
		"1",
		"总开关. 0=关闭, 1=启用.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// 1.2.0：触发阈值默认 25 -> 10（总血量 = 实血 + 虚血）
	g_cvHealth = CreateConVar("l4d2_bot_guard_health",
		"10",
		"AI 生还者总血量(实血 + 虚血)低于或等于该值时进入守护状态（1.2.0 起默认 10）.",
		FCVAR_NOTIFY, true, 1.0, true, 200.0);

	g_cvGlow = CreateConVar("l4d2_bot_guard_glow",
		"1",
		"守护状态下是否间歇闪蓝色轮廓. 0=关闭, 1=启用.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvGlowColor = CreateConVar("l4d2_bot_guard_glow_color",
		"255 255 255",
		"轮廓颜色, 格式 \"R G B\"（默认 255 255 255 = 白色）.");

	g_cvGlowRange = CreateConVar("l4d2_bot_guard_glow_range",
		"800",
		"轮廓可见距离上限（游戏单位）.",
		FCVAR_NOTIFY, true, 0.0, true, 10000.0);

	g_cvGlowRangeMin = CreateConVar("l4d2_bot_guard_glow_range_min",
		"0",
		"轮廓可见距离下限（游戏单位）: 0=从贴身就开始显示（与 witch_glow 同样写 m_nGlowRangeMin）.",
		FCVAR_NOTIFY, true, 0.0, true, 10000.0);

	g_cvGlowFlash = CreateConVar("l4d2_bot_guard_glow_flash",
		"1",
		"1=同时写 m_bFlashing 让引擎自己闪（默认）；0=只靠定时器开关轮廓来闪.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvInterval = CreateConVar("l4d2_bot_guard_interval",
		"0.9",
		"检测与闪烁节奏（秒）: 每该间隔检查一次状态并切换一次轮廓开关（默认 0.9 = 约 1.1Hz 闪烁，太快的开关会让人以为没光）.",
		FCVAR_NOTIFY, true, 0.05, true, 5.0);

	// 1.2.3：上面那条是"状态检测 + 闪烁"节奏（0.9s），拿来做保护太慢 ——
	// charger 捶打/扛走、spitter 酸液在这 0.9s 里仍然能生效。所以单独开一条高频线程，
	// 只做"立刻解控 + 血量回锁"两件事，开销极小（每个守护中的 bot 两次属性读写）。
	g_cvProtectInterval = CreateConVar("l4d2_bot_guard_protect_interval",
		"0.1",
		"守护中 bot 的解控/血量回锁节奏（秒）。默认 0.1：被 charger 捶打/扛走、被 spitter 酸液掉血都会在 0.1 秒内被纠正.",
		FCVAR_NOTIFY, true, 0.02, true, 1.0);

	g_cvInvincible = CreateConVar("l4d2_bot_guard_invincible",
		"1",
		"守护状态下免疫任何伤害. 0=关闭, 1=启用.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvBlockControl = CreateConVar("l4d2_bot_guard_block_control",
		"1",
		"守护状态下免疫特感控制(舌头/扑击/骑乘/冲撞), 且已被控时立即解控. 0=关闭, 1=启用.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// 1.2.0：l4d2_bot_guard_max_bots 改名成 l4d2_bot_guard_max_count，
	// 语义从"AI 数量超过就全关"改成"同时守护的数量硬上限"
	g_cvMaxCount = CreateConVar("l4d2_bot_guard_max_count",
		"3",
		"同时处于守护状态的未接管生还者数量硬上限（1.2.0 由 l4d2_bot_guard_max_bots 改名而来）。默认 3.",
		FCVAR_NOTIFY, true, 0.0, true, 24.0);

	// 1.3.4：计算「在场未倒地生还者」时排除已经进入终点安全屋的人
	// （只影响分子，分母仍是存活生还者总数；关掉即完全回到 1.3.3 的口径）
	g_cvExcludeEndSaferoom = CreateConVar("l4d2_bot_guard_exclude_end_saferoom",
		"1",
		"计算可守护名额时，是否把「已经进入本关终点安全屋」的生还者从『未倒地生还者数』里排除. 1=排除(默认): 进屋的人不再计入分子(分母仍是存活生还者总数), 可守护数只会持平或变少; 0=旧口径(存活 - 倒地). 救援关/终局图没有终点安全屋时自动不排除.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// 1.2.1：可守护数改为"按比例"计算（见 ComputeAllowedGuards），
	// 1.2.0 的三条固定阶梯 cvar（down_tier1/2/3）已删除
	// 1.6.0：1.2.0 的两个移速 cvar（l4d2_bot_guard_bot_speed / l4d2_bot_guard_base_speed）
	//        已整段删除，插件不再写 m_flLaggedMovementValue —— 人机移速交还引擎。

	g_cvReviveTimes = CreateConVar("l4d2_bot_guard_revive_times",
		"-1",
		"AI 生还者每回合可自动起身的次数上限：-1=不设每回合上限（默认）；0=关闭自动起身；>0=每回合上限。这里的次数上限与引擎的倒地计数无关.",
		FCVAR_NOTIFY, true, -1.0, true, 99.0);

	// 1.5.0：默认血量 30 -> 1（用户要求"至少将人机自动起身的血量改成 1 点"）。
	// 下界仍是 1：写 0 会让起身的人立刻死亡，不如直接用 revive_times=0 关掉。
	g_cvReviveHealth = CreateConVar("l4d2_bot_guard_revive_health",
		"1",
		"自动起身后设置的血量（实血；虚血会被一起清 0，保证起身瞬间总血量就是该值）. 默认 1 = 起身后只剩 1 点血.",
		FCVAR_NOTIFY, true, 1.0, true, 100.0);

	g_cvReviveDelay = CreateConVar("l4d2_bot_guard_revive_delay",
		"1.0",
		"AI 生还者倒地后延迟多少秒自动起身.",
		FCVAR_NOTIFY, true, 0.0, true, 30.0);

	g_cvNotify = CreateConVar("l4d2_bot_guard_notify",
		"1",
		"自动起身时是否在聊天框提示. 0=关闭, 1=启用.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// 1.5.0：跳过"有真人主控的空闲 bot 身体"（倒地后自己切旁观 / 掉线被托管的身体）。
	// 这类身体虽然 IsFakeClient()==true，但归属于某个真人：替他起身 = 玩家旁观一下再
	// 加回来就白赚一次起身（还会白拿一段守护），所以自动起身与守护都跳过它。
	g_cvSkipIdleBodies = CreateConVar("l4d2_bot_guard_skip_idle_bodies",
		"1",
		"跳过「有真人主控的空闲 bot 身体」（玩家倒地后自己切旁观/掉线，身体被引擎交给 bot 顶着）. 1=跳过(默认): 不替这种身体自动起身、也不给它免伤/免控/发光, 玩家重新加入不会白拿起身; 0=旧行为(1.4.0). 注意: 真人彻底掉线(userid 失效)后该身体重新算无人接管, 照常兜底起身.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// 1.3.0：玩家特感打守护中的 bot 时，提示音 + 三渠道文字
	g_cvWarn = CreateConVar("l4d2_bot_guard_warn",
		"1",
		"玩家特感攻击守护中的 AI 生还者时, 是否给该特感玩家提示(提示音 + 三渠道文字). 0=关闭, 1=启用.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvWarnCooldown = CreateConVar("l4d2_bot_guard_warn_cooldown",
		"1.0",
		"同一名特感玩家对同一只 AI 生还者两次提示的最小间隔(秒)；按「攻击者 × 目标人机」成对计时：打另一只守护中的人机会立刻重新提示。默认 1.0 = 1 秒，防止连点爪击时刷屏。0 = 不节流。",
		FCVAR_NOTIFY, true, 0.0, true, 60.0);

	g_cvWarnSound = CreateConVar("l4d2_bot_guard_warn_sound",
		"ui/beep_error01.wav",
		"提示音路径(相对游戏 sound/ 目录). 默认 ui/beep_error01.wav = 服务器现有投票插件[l4d_votes_5_VS]投票未通过用的同一个音效; 留空 = 不播放.",
		FCVAR_NOTIFY);

	g_cvWarnChat = CreateConVar("l4d2_bot_guard_warn_chat",
		"1",
		"提示渠道①: 聊天框(只发给攻击的特感玩家). 0=关闭, 1=启用.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvWarnHint = CreateConVar("l4d2_bot_guard_warn_hint",
		"1",
		"提示渠道②: 屏幕提示(PrintHintText, 只发给攻击的特感玩家). 0=关闭, 1=启用.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvWarnHud = CreateConVar("l4d2_bot_guard_warn_hud",
		"1",
		"提示渠道③: HUD 文字(ShowHudText, 画面上方, 只发给攻击的特感玩家). 0=关闭, 1=启用.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// 按 workspace 约定：不生成插件 cfg（不用 AutoExecConfig），
	// 全部参数由 applemod12v12 的 confogl_addcvar 下发
	ParseGlowColor();
	// 1.3.3：守护中的 AI 生还者禁止自行吃药/打针/打包
	// （超管想让人机自己吃药时把它关掉；关闭不影响其它任何功能）
	g_cvBlockItems = CreateConVar("l4d2_bot_guard_block_items",
		"1",
		"守护中的 AI 生还者是否禁止自行使用医疗物品(吃药/打针/打包). 0=关闭, 1=启用. 需要服务器的 Actions 扩展.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvGlowColor.AddChangeHook(OnConVarChanged);
	g_cvInterval.AddChangeHook(OnConVarChanged);
	g_cvProtectInterval.AddChangeHook(OnConVarChanged);
	// 1.6.0：移速 cvar 已删除，这里不再挂"倍率改了立刻重写"的钩子
	// 1.3.0：提示音路径改了要重新解析/预缓存
	g_cvWarnSound.AddChangeHook(OnConVarChanged);

	// 1.3.3：Actions 扩展是**可选**的 —— 没有它插件其余功能全部照常，
	// 只是不拦"守护中的 AI 生还者自行吃药/打针/打包"（绝不 SetFailState）
	g_bActionsAvailable = LibraryExists("actionslib");

	if (!g_bActionsAvailable)
	{
		PrintToServer("[BotGuard] 未检测到 Actions 扩展 (actionslib)：守护中的 AI 生还者仍会自行吃药/打针/打包。插件其余功能不受影响。");
	}

	// 1.4.0：不再挂 player_incapacitated —— 倒地/挂边的判定改成保护线程里的轮询
	// （见 ProcessBotRevives：不依赖事件，晚加载 / 挂边一样能救）。
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);

	// 1.3.3：玩家离开、身体被 bot 接管时，打断"继承"过来的自动吃药/打针
	HookEvent("player_bot_replace", Event_PlayerBotReplace, EventHookMode_Post);

	// 晚加载：已经连进来的客户端也要补挂伤害钩子
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
			OnClientPutInServer(i);
	}

	// 排查/验证用（不给玩家用）：状态查询 + 强制上轮廓
	RegAdminCmd("sm_botguard_status", Cmd_Status, ADMFLAG_GENERIC,
		"打印低血 AI 生还者守护状态：血量、存活未接管数量、倒地数、可守护数、守护名单");
	RegAdminCmd("sm_botguard_test", Cmd_TestGlow, ADMFLAG_GENERIC,
		"强制给目标客户端闪轮廓，用于确认发光是否可见: sm_botguard_test <#userid|名字> [秒]");

	// 1.3.0：不节流地演示一遍"打守护 bot"的提示（提示音 + 三渠道文字），用来验证音效是否存在
	RegAdminCmd("sm_botguard_warntest", Cmd_WarnTest, ADMFLAG_GENERIC,
		"演示一次守护拦截提示(提示音+三渠道文字), 不节流: sm_botguard_warntest [目标 #userid|名字]，默认发给自己");

	// 1.3.4：终点安全屋排除的运行期条件先算一次（换图/每回合由 OnMapStart + round_start 重算）
	RefreshEndSaferoomState();

	StartTickTimer();
	StartProtectTimer();
}

// 1.3.3：Actions 扩展晚加载 / 被卸载时刷新可用标记。
// 插件本体绝不因为扩展缺失而 SetFailState —— 只把物品拦截整段跳过。
public void OnLibraryAdded(const char[] name)
{
	if (strcmp(name, "actionslib") == 0)
		g_bActionsAvailable = true;
}

public void OnLibraryRemoved(const char[] name)
{
	if (strcmp(name, "actionslib") == 0)
		g_bActionsAvailable = false;
}

// 1.3.0：配置(cfg)下发完后再解析一次提示音路径，保证拿到的是 confogl_addcvar 之后的值
public void OnConfigsExecuted()
{
	RefreshWarnSound(false);
}

public void OnMapStart()
{
	g_bBlinkPhase = false;
	g_iAiSurvivors = 0;
	g_iDownCount = 0;
	g_iGuardAllowed = 0;
	g_iGuardCount = 0;

	// 1.3.4：换图后终点安全屋实体重建，等下一次 round_start 重新判定
	g_bHasEndSaferoom = false;
	g_bEndSaferoomChecked = false;

	// 1.3.0：解析 + 预缓存提示音（换图后重置节流时间戳）
	RefreshWarnSound(true);

	for (int i = 0; i <= MaxClients; i++)
	{
		g_bGuarded[i] = false;
		g_fTempStash[i] = 0.0;
		ResetWarnLast(i);
		// 1.4.0：轮询式救起的计划全部作废
		g_fReviveAt[i] = 0.0;
		g_bReviveCounted[i] = false;
		// 1.5.0：起身保护窗口用的是 GetGameTime()（换图归零），必须一起清掉
		g_fReviveProtectUntil[i] = 0.0;
	}

	g_fNotifyNextAt = 0.0;
}

public void OnPluginEnd()
{
	if (g_hTickTimer != null)
	{
		delete g_hTickTimer;
		g_hTickTimer = null;
	}

	if (g_hProtectTimer != null)
	{
		delete g_hProtectTimer;
		g_hProtectTimer = null;
	}

	// 卸载时把轮廓恢复成进入守护前的样子，避免残留
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && g_bGuarded[i])
		{
			SetEntProp(i, Prop_Send, "m_iGlowType", g_iOrigGlowType[i]);
			SetEntProp(i, Prop_Send, "m_glowColorOverride", g_iOrigGlowColor[i]);
			SetEntProp(i, Prop_Send, "m_nGlowRange", g_iOrigGlowRange[i]);
			SetEntProp(i, Prop_Send, "m_nGlowRangeMin", g_iOrigGlowRangeMin[i]);

			// 1.2.2：卸载时也必须把引擎层受击状态恢复，否则会留下永久 god mode
			SetEntProp(i, Prop_Data, "m_takedamage", g_iOrigTakeDamage[i] > 0 ? g_iOrigTakeDamage[i] : 2, 1);

			if (g_cvGlowFlash.BoolValue)
				SetEntProp(i, Prop_Send, "m_bFlashing", 0, 1);

			g_bGuarded[i] = false;
		}
	}

	// 1.6.0：本插件不再写 m_flLaggedMovementValue，卸载时没有移速要还原
}

public void OnClientPutInServer(int client)
{
	g_bGuarded[client] = false;
	g_bGlowProps[client] = false;
	g_fTempStash[client] = 0.0;
	g_iReviveLeft[client] = g_cvReviveTimes.IntValue;
	ResetWarnLast(client);
	// 1.4.0：轮询式救起的计划
	g_fReviveAt[client] = 0.0;
	g_bReviveCounted[client] = false;
	// 1.5.0：起身保护窗口跟着客户端一起重置
	g_fReviveProtectUntil[client] = 0.0;

	// 每个客户端都要挂伤害钩子（r ygive 同款做法：进服即挂）
	SDKHook(client, SDKHook_OnTakeDamage, Hook_OnTakeDamage);
}

public void OnClientDisconnect(int client)
{
	g_bGuarded[client] = false;
	g_bGlowProps[client] = false;
	g_fTempStash[client] = 0.0;
	g_iReviveLeft[client] = 0;
	ResetWarnLast(client);
	g_fReviveAt[client] = 0.0;
	g_bReviveCounted[client] = false;
	g_fReviveProtectUntil[client] = 0.0;
}

public void OnConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (convar == g_cvGlowColor)
	{
		ParseGlowColor();
		for (int i = 1; i <= MaxClients; i++)
		{
			if (g_bGuarded[i])
				ApplyGlow(i, true);
		}
	}
	else if (convar == g_cvInterval)
	{
		StartTickTimer();
	}
	else if (convar == g_cvProtectInterval)
	{
		StartProtectTimer();
	}
	else if (convar == g_cvWarnSound)
	{
		// 1.3.0：换提示音后立刻重新解析（这张图已经开过，不再预缓存，音效文件本身是库存音效）
		RefreshWarnSound(false);
	}
}

void StartTickTimer()
{
	if (g_hTickTimer != null)
	{
		delete g_hTickTimer;
		g_hTickTimer = null;
	}

	float fInterval = g_cvInterval.FloatValue;
	if (fInterval < 0.05)
		fInterval = 0.05;

	g_hTickTimer = CreateTimer(fInterval, Timer_Tick, _, TIMER_REPEAT);
}

void StartProtectTimer()
{
	if (g_hProtectTimer != null)
	{
		delete g_hProtectTimer;
		g_hProtectTimer = null;
	}

	float fInterval = g_cvProtectInterval.FloatValue;
	if (fInterval < 0.02)
		fInterval = 0.02;

	g_hProtectTimer = CreateTimer(fInterval, Timer_Protect, _, TIMER_REPEAT);
}

/* 1.2.3：高频保护（默认 0.1s 一次）。守护中的 bot：
   ① 立刻解掉任何控制 —— charger 的「捶打/扛走」引擎没有"开始捶打"的前置 forward 可拦，
      只能靠这条快线程抢在伤害与位移之前打断（舌头/扑击/骑乘/撞墙另有一级前置拦截）；
   ② 血量回锁 —— spitter 酸液这类伤害不一定经过 OnTakeDamage（SDKHook 拦不到），
      这里把实血顶回进入守护时的值，保证"守护中绝不掉血"。

   1.4.0：这条线程同时承担两件事：
   ③ 硬保险 —— 守护中的人一旦倒地 / 挂边 / 掉边坠落 / 死亡，立刻 LeaveGuard。
      玩家的"挂边坠落卡原地无敌"就是缺了这一步：倒地/坠落时 m_takedamage 还是 0、
      血量还被回锁着，引擎的死亡流程走不完，人就永远卡在那里。这条检查必须在
      伤害/血量回锁之前做，绝不能省。
   ④ 轮询救起 —— 扫描所有生还者状态（倒地 / 挂边），到点立刻救起（见 ProcessBotRevives）。

   1.5.0：③ 后面再加一道 ⑤ —— 用 ShouldGuard 复核"这具身体现在到底该不该被守护"。
   新出现的失效情形是"身体已经有真人主控"（IsIdleBody）：玩家倒地后自己切旁观 / 掉线，
   身体交给 bot 顶着，此时给免伤就是让玩家旁观一下白拿保护；0.1s 的粒度保证
   "玩家一切旁观，无敌在 0.1 秒内就撤掉"，不会留一个无敌的空闲身体在场上。
   用的是与 Timer_Tick 同一个 ShouldGuard，两条线程口径不会打架。 */
public Action Timer_Protect(Handle timer)
{
	if (!g_cvEnabled.BoolValue)
		return Plugin_Continue;

	bool bBlockControl = g_cvBlockControl.BoolValue;
	bool bInvincible   = g_cvInvincible.BoolValue;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!g_bGuarded[i])
			continue;

		// 1.4.0 ③：硬保险。注意顺序：先判断要不要退出守护，再谈解控/回血。
		if (!IsClientInGame(i) || !IsPlayerAlive(i) || IsIncapacitated(i) || IsOnLedge(i))
		{
			LeaveGuard(i);
			continue;
		}

		// 1.5.0 ⑤：用 ShouldGuard 再做一道 0.1s 级的复核（1.4.0 只在 0.9s 的 Timer_Tick 里查）。
		//   新增的失效情形有两个，都是"身体已经有真人主控，不该再白给无敌"：
		//     ① 空闲身体：玩家倒地后自己切旁观 / 掉线，身体交给 bot 顶着（IsIdleBody）；
		//     ② 玩家已经重新加入并接管（IsFakeClient 变 false，ShouldGuard 里直接排除）。
		//   顺手也能把"血量回升到阈值以上"的守护在 0.1s 内撤掉，与 Timer_Tick 的判定完全一致，
		//   不会出现两条口径打架。
		if (!ShouldGuard(i))
		{
			LeaveGuard(i);
			continue;
		}

		if (bBlockControl)
			NotifyGuardBlocked(ReleaseControl(i), i);

		if (bInvincible && g_iGuardHealth[i] > 0 && GetClientHealth(i) < g_iGuardHealth[i])
			SetEntityHealth(i, g_iGuardHealth[i]);
	}

	// 1.4.0 ④：轮询所有生还者状态，倒地/挂边的 bot 立刻救起
	ProcessBotRevives();

	return Plugin_Continue;
}

// ============================================================================
// 状态机
// ============================================================================

public Action Timer_Tick(Handle timer)
{
	// 1.3.4：本回合还没判定过「终点安全屋」（插件晚加载 / 漏接 round_start）→ 这里补一次，
	// 每回合只会真正扫一次实体（g_bEndSaferoomChecked 为 true 后直接跳过）。
	if (!g_bEndSaferoomChecked)
		RefreshEndSaferoomState();

	// 1.2.1：先统计"存活未接管生还者数量"与"倒地人数"，再按比例算出可守护名额。
	// 1.1.0 的"AI 生还者数量 > max_bots 就全部关掉"规则与 1.2.0 的固定阶梯都已删除。
	g_iAiSurvivors = CountAiSurvivors();
	g_iDownCount = CountDownedSurvivors();
	g_iGuardAllowed = ComputeAllowedGuards();

	// 1.4.0：轮询所有生还者状态 —— 倒地 / 挂边的 bot 在这里被救起（0.1s 保护线程里也在跑，
	// 这里再跑一次是为了"救起 + 纳入守护"能在同一个 tick 里完成）。
	// 救起会改变存活/倒地人数，所以救完要重算一遍名额。
	if (ProcessBotRevives())
	{
		g_iAiSurvivors = CountAiSurvivors();
		g_iDownCount = CountDownedSurvivors();
		g_iGuardAllowed = ComputeAllowedGuards();
	}

	// 第一步：先释放"已经不该守护"的人（死亡 / 倒地 / 被真人接管 / 血量回升 / 总开关关闭）
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
		{
			g_bGuarded[i] = false;
			continue;
		}

		if (g_bGuarded[i] && !ShouldGuard(i))
			LeaveGuard(i);
	}

	// 第二步：按名额重新分配（已守护优先保留，其余按 总血量升序 -> 索引升序）
	UpdateGuardSet(g_iGuardAllowed);

	g_iGuardCount = CountGuarded();

	// 第三步：守护中的每个 bot 做维护 —— 虚血冻结 + 已被控则立即解控
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !g_bGuarded[i])
			continue;

		// 虚血冻结：引擎会按时间自然扣减 healthBuffer，
		// 这里按节奏把它写回守护开始时的值（L4D_SetTempHealth 同时刷新 m_healthBufferTime）
		if (g_fTempStash[i] > 0.0 && L4D_GetTempHealth(i) < g_fTempStash[i])
			L4D_SetTempHealth(i, g_fTempStash[i]);

		// 已被控住的立即解控（"被控时血量掉到阈值及以下就取消控制"）
		if (g_cvBlockControl.BoolValue)
			NotifyGuardBlocked(ReleaseControl(i), i);
	}

	// 第四步：1.6.0 起不再有移速那一步（插件不写 m_flLaggedMovementValue）

	// 间歇闪烁：每 tick 翻转一次相位（闪烁不受名额限制影响，只受 g_cvGlow 控制）
	if (g_cvGlow.BoolValue)
	{
		g_bBlinkPhase = !g_bBlinkPhase;

		float fNow = GetGameTime();

		for (int i = 1; i <= MaxClients; i++)
		{
			if (!IsClientInGame(i))
				continue;

			if (g_bGuarded[i] || fNow < g_fTestGlowUntil[i])
				ApplyGlow(i, g_bBlinkPhase);
		}
	}

	return Plugin_Continue;
}

// ============================================================================
// 1.2.0：守护名额统计与分配
// ============================================================================

// 场上非玩家操控的生还者数量（只看存活、在生还者队的 bot）
// 1.2.0：同时作为"当前存活未接管生还者数量"，参与可守护数的 min() 收敛
int CountAiSurvivors()
{
	int iCount = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
			continue;

		if (GetClientTeam(i) != TEAM_SURVIVOR)
			continue;

		if (!IsFakeClient(i))
			continue;

		if (!IsPlayerAlive(i))
			continue;

		iCount++;
	}

	return iCount;
}

// 1.2.0：全队（team 2）里 m_isIncapacitated=1 的人数 —— 阶梯的唯一输入
int CountDownedSurvivors()
{
	int iCount = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
			continue;

		// 真人、bot 都算（需求写的是"全队 team 2 里 m_isIncapacitated=1 的人数"）
		if (GetClientTeam(i) != TEAM_SURVIVOR)
			continue;

		if (IsIncapacitated(i))
			iCount++;
	}

	return iCount;
}

// 1.2.1：全队（team 2）存活生还者数量（真人 + bot，含倒地者）
int CountAliveSurvivors()
{
	int iCount = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
			continue;

		if (GetClientTeam(i) != TEAM_SURVIVOR)
			continue;

		if (IsPlayerAlive(i))
			iCount++;
	}

	return iCount;
}

// 1.2.2：全队（team 2）存活且"玩家操控"的生还者数量（排除 bot）。
// 用来判定"真人已经全灭/全在旁观"——那种情况下不该再给 AI 无敌。
int CountAliveHumanSurvivors()
{
	int iCount = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
			continue;

		if (GetClientTeam(i) != TEAM_SURVIVOR)
			continue;

		if (IsFakeClient(i))
			continue;

		if (IsPlayerAlive(i))
			iCount++;
	}

	return iCount;
}

// ============================================================================
// 1.3.4：终点安全屋排除
// ============================================================================

// 该客户端此刻是否在「本关终点安全屋」的体积内。
//
// 判定用 Left4DHooks 的 L4D_IsInLastCheckpoint(client)
// （left4dhooks.inc:3977-3984：@brief Returns true when the specified Survivor or Special
//   Infected is in the ending checkpoint area；@remarks This uses the "info_changelevel"
//   entity, and checks the player is within the vector mins and vector maxs of the entity）。
// 也就是关卡终点安全屋的触发体积：站在门口体积外、门还没开、还没走进去都不算在屋里。
// 起点安全屋是另一个 native（L4D_IsInFirstCheckpoint），两者不会混淆。
//
// 三层安全门（任何一条不满足就退回旧口径，绝不硬判）：
//   ① cvar l4d2_bot_guard_exclude_end_saferoom = 0；
//   ② 运行期拿不到 L4D_IsInLastCheckpoint（inc 里 MarkNativeAsOptional，left4dhooks 缺失/太旧）；
//   ③ 本图没有 info_changelevel → 是救援关/终局图，没有"终点安全屋"这个概念。
bool IsInEndSaferoom(int client)
{
	if (!g_cvExcludeEndSaferoom.BoolValue)
		return false;

	if (!g_bNtvLastCheckpoint || !g_bHasEndSaferoom)
		return false;

	return L4D_IsInLastCheckpoint(client);
}

// 1.3.4：新口径「在场未倒地生还者数」= 存活 + 未倒地 + 不在终点安全屋。
// 它就是 ComputeAllowedGuards() 里 ratio 的分子（旧写法是 CountAliveSurvivors() - CountDownedSurvivors()）。
// cvar 关掉 / native 不可用 / 本图没有终点安全屋时，结果与旧写法完全一致。
//
// 注意：这里**不**把已经进屋的人从守护状态里踢出去 —— 本函数只决定名额，
// 名额分配仍走 UpdateGuardSet（已守护者优先保留）。见开头 1.3.4 的说明。
int CountStandingSurvivors()
{
	int iCount = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
			continue;

		if (GetClientTeam(i) != TEAM_SURVIVOR)
			continue;

		if (!IsPlayerAlive(i))
			continue;

		// 倒地："未倒地"的定义与旧口径完全一致（只看 m_isIncapacitated，挂边不算倒地）
		if (IsIncapacitated(i))
			continue;

		// 1.3.4：已经进了终点安全屋的人不算"在场"，不参与名额计算
		if (IsInEndSaferoom(i))
			continue;

		iCount++;
	}

	return iCount;
}

// 1.3.4：只给 sm_botguard_status 用 —— 有多少"存活未倒地"的人被终点安全屋排除掉了。
// 与 CountStandingSurvivors 的跳过条件严格对应，保证 存活未倒地 - 排除 = 在场未倒地。
int CountExcludedInEndSaferoom()
{
	int iCount = 0;

	if (!g_cvExcludeEndSaferoom.BoolValue || !g_bNtvLastCheckpoint || !g_bHasEndSaferoom)
		return 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
			continue;

		if (GetClientTeam(i) != TEAM_SURVIVOR)
			continue;

		if (!IsPlayerAlive(i) || IsIncapacitated(i))
			continue;

		if (L4D_IsInLastCheckpoint(i))
			iCount++;
	}

	return iCount;
}

// 1.3.4：刷新「native 在不在 / 本图有没有终点安全屋」这两个运行期条件。
// 每回合（round_start）重算一次即可：那时地图实体一定已经加载完（和 1.2.1 的区域侦测同理）。
//
// 为什么用 info_changelevel 来判断"有没有终点安全屋"：
//   L4D_IsInLastCheckpoint 本身就是拿 info_changelevel 的 mins/maxs 做体积判定
//   （见上面 native 的 @remarks），所以图里没有这个实体时它必然对所有人返回 false。
//   救援关/终局图只有 trigger_finale / 救援载具，没有 info_changelevel，在这里被识别出来，
//   于是不排除任何人 —— 避免"全员被判成在安全屋 → 可守护数变 0"的误判。
void RefreshEndSaferoomState()
{
	g_bEndSaferoomChecked = true;
	g_bHasEndSaferoom = false;

	// native 可用性每回合复核一次：left4dhooks 可能比本插件晚注册 native，
	// OnPluginStart 那一刻查不到，等它注册完成后这里就能拿到。
	g_bNtvLastCheckpoint = (GetFeatureStatus(FeatureType_Native, "L4D_IsInLastCheckpoint") == FeatureStatus_Available);

	if (!g_bNtvLastCheckpoint)
	{
		// 只有真的要用"排除"功能时才提示；cvar=0 的服不该看到这条噪音
		if (g_cvExcludeEndSaferoom.BoolValue && !g_bNtvLastCheckpointWarned)
		{
			g_bNtvLastCheckpointWarned = true;
			PrintToServer("[BotGuard] 未检测到 L4D_IsInLastCheckpoint（Left4DHooks 缺失或版本太旧）：l4d2_bot_guard_exclude_end_saferoom 不生效，仍按旧口径（存活 - 倒地）计算守护名额。");
		}

		return;
	}

	// 不管 cvar 当前开没开都记下"本图有没有终点安全屋"，
	// 这样管理员运行中把 cvar 从 0 改成 1 也能立刻生效（不用等下一回合）。
	if (FindEntityByClassname(-1, "info_changelevel") != -1)
		g_bHasEndSaferoom = true;
}

// 1.2.1：可守护数 —— 按比例算（取代 1.2.0 的三条固定阶梯）
//
//   基础名额 base = min(max_count, 当前存活未接管生还者数量)
//   比例 ratio   = 未倒地生还者数 / 存活生还者总数
//   可守护数     = round(base * ratio)
//
// 两条硬约束（用户明确要求）：
//   ① 只剩 1 个（或 0 个）生还者没倒地 -> 取消最后一个守护，直接 0；
//   ② 还有 >= 2 个生还者站着 -> 至少保留 1 个守护（避免"全员都在爬"时保护突然清零）。
//
// 推演（12 人满编，base = 未接管生还者数，取 min(3, base)）：
//   9 真人 + 3 bot：倒地 0~2 -> 3；3~6 -> 2；7~10 -> 1；11+ -> 0
//   10 真人 + 2 bot：倒地 0~3 -> 2；4~10 -> 1；11 -> 0
int ComputeAllowedGuards()
{
	int iAlive = CountAliveSurvivors();

	// 1.3.4：分子从「存活 - 倒地」改成「在场未倒地」（= 存活 + 未倒地 + 不在终点安全屋）。
	// 分母 iAlive 保持「存活生还者总数」不变 —— 用户只要求排除"未倒地生还者"这一项。
	// 这样 ratio 只会持平或变小，可守护数只会持平或变少，不会出现守护数异常变大。
	int iStanding = CountStandingSurvivors();
	int iBots = CountAiSurvivors();

	int iBase = g_cvMaxCount.IntValue;

	if (iBots < iBase)
		iBase = iBots;

	if (iBase <= 0 || iAlive <= 0)
		return 0;

	// 1.2.2：场上已经没有任何"玩家操控的生还者"（真人全灭 / 全在旁观）时，
	// 不能再让几个人机靠无敌顶着 —— 玩家反馈过"其他生还者死完了，三个人机还无敌"。
	if (CountAliveHumanSurvivors() <= 0)
		return 0;

	// 只剩一个（或零个）人没倒：连最后一个守护也取消
	if (iStanding <= 1)
		return 0;

	float fRatio = float(iStanding) / float(iAlive);

	int iAllowed = RoundHalfUp(float(iBase) * fRatio);

	// 还有两个人以上站着就至少留一个守护
	if (iAllowed < 1)
		iAllowed = 1;

	if (iAllowed > iBase)
		iAllowed = iBase;

	return iAllowed;
}

// 1.2.1：四舍五入（.5 一律进位）
// SourceMod 的 RoundToNearest 是 IEEE 银行家舍入（2.5 -> 2、1.5 -> 2），
// 而这里要的是 2.5 -> 3（否则"12 人满编、倒地 2 人"就从 3 个守护掉到 2 个，与需求示例不符）
int RoundHalfUp(float fValue)
{
	int iFloor = RoundToFloor(fValue);

	if (fValue - float(iFloor) >= 0.5)
		iFloor++;

	return iFloor;
}

// 1.2.1：当前实际处于守护状态的人数
int CountGuarded()
{
	int iCount = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && g_bGuarded[i])
			iCount++;
	}

	return iCount;
}

// 1.2.0：按名额重新分配守护状态
//   - 已处于守护状态的人优先保留名额
//   - 剩余名额按「总血量升序 -> 客户端索引升序」分配给其它候选
//   - 名额不够时，多出来的已守护者用 LeaveGuard 完整释放（发光 netprop 一并还原）
void UpdateGuardSet(int iAllowed)
{
	int aCandidates[MAXPLAYERS + 1];
	int iCount = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!ShouldGuard(i))
			continue;

		aCandidates[iCount++] = i;
	}

	SortGuardCandidates(aCandidates, iCount);

	int iSlots = iAllowed;

	// 第一轮：已守护的优先保留
	for (int k = 0; k < iCount; k++)
	{
		int iClient = aCandidates[k];

		if (!g_bGuarded[iClient])
			continue;

		if (iSlots > 0)
		{
			iSlots--;
			continue;
		}

		LeaveGuard(iClient);
	}

	// 第二轮：剩余名额发给未守护的候选（已按总血量/索引排好序）
	for (int k = 0; k < iCount; k++)
	{
		if (iSlots <= 0)
			break;

		int iClient = aCandidates[k];

		if (g_bGuarded[iClient])
			continue;

		EnterGuard(iClient);
		iSlots--;
	}
}

// 1.2.0：候选排序（插入排序，最多 24 个元素，不值得走 SortCustom1D）
// 排序键：总血量升序 -> 客户端索引升序
void SortGuardCandidates(int[] aCandidates, int iCount)
{
	for (int i = 1; i < iCount; i++)
	{
		int iKey = aCandidates[i];
		int iKeyHealth = GetTotalHealth(iKey);
		int j = i - 1;

		while (j >= 0 && IsCandidateBefore(iKey, iKeyHealth, aCandidates[j]))
		{
			aCandidates[j + 1] = aCandidates[j];
			j--;
		}

		aCandidates[j + 1] = iKey;
	}
}

// 1.2.0：iClient 是否应排在 iOther 前面（总血量更少，或血量相同但索引更小）
bool IsCandidateBefore(int iClient, int iHealth, int iOther)
{
	int iOtherHealth = GetTotalHealth(iOther);

	if (iHealth != iOtherHealth)
		return iHealth < iOtherHealth;

	return iClient < iOther;
}

// ============================================================================
// 1.3.0：玩家特感攻击"守护中的 AI 生还者"时的提示
//
//   - 提示音：默认 ui/beep_error01.wav（= 本仓库 l4d_votes_5_VS 投票未通过用的同一个
//     音效文件，服务器上绝对存在）。改 l4d2_bot_guard_warn_sound 可换成任意
//     game_sounds 路径（相对 sound/ 目录），留空则不播。
//   - 三渠道文字：①聊天框 ② PrintHintText ③ HUD 文字，各自有开关。
//   - 1.6.1 节流口径：按「攻击者 × 目标 bot」成对计时（默认 1 秒），不是按攻击者一个人计时。
//     旧口径下同一名特感玩家在冷却内打第二只守护中的人机，整条提示（音效 + 三渠道文字）
//     会被吞掉，而且提示里写的还是上一只 bot 的名字 —— 这是"有时不提示"的主因。
//   - 覆盖的触发点：SDKHook_OnTakeDamage（守护中吃伤害 / 保命判定），
//     舌头 / 扑击 / 骑乘 / 牛抱人 / 牛捶打 / 牛撞墙六个前置拦截 forward，
//     以及 1.6.1 补上的「强制解控」路径（ReleaseControl：EnterGuard / Timer_Protect / Timer_Tick）。
// ============================================================================

// 解析 l4d2_bot_guard_warn_sound，并（在地图开始时可）预缓存。
//
// 1.3.1 修复（用户实测：日志报"音效不存在: ui/beep_error01.wav"，但游戏里确实有这个音效）：
//   **不再**用 FileExists 当门禁。实测该文件在服务器上 FileExists（valve 文件系统 +
//   普通文件系统两条路）都返回 false —— srcds 端的音效可能只存在于 VPK、或纯靠
//   客户端本地文件播放，服务器端查文件既不可靠，又会在每次换图刷一条假报错。
//   现在：
//     - 播放不做存在性检查，直接 EmitSoundToClient（路径写错最多是没声音，文字提示照常）；
//     - 预缓存照做（自定义音效要预缓存才能下发，库存音效是 no-op）；
//     - 诊断只在 sm_botguard_status / sm_botguard_warntest 里打印，且明确说明
//       "服务器端查不到 ≠ 播放不了"。
void RefreshWarnSound(bool bPrecache)
{
	g_cvWarnSound.GetString(g_sWarnSound, sizeof(g_sWarnSound));

	if (g_sWarnSound[0] == '\0')
		return;

	if (bPrecache)
		PrecacheSound(g_sWarnSound, true);
}

// 仅用于诊断显示：服务器端能否找到这个音效文件（false 也不代表播放不了）
bool WarnSoundFoundOnServer()
{
	if (g_sWarnSound[0] == '\0')
		return false;

	char sDiskPath[PLATFORM_MAX_PATH];
	Format(sDiskPath, sizeof(sDiskPath), "sound/%s", g_sWarnSound);

	if (FileExists(sDiskPath, true) || FileExists(sDiskPath))
		return true;

	// 兼容"配置里自己带了 sound/ 前缀"的写法
	if (FileExists(g_sWarnSound, true) || FileExists(g_sWarnSound))
		return true;

	return false;
}

// 只有"玩家操控的特感"才需要提示（AI 特感不刷屏）
bool IsWarnTarget(int client)
{
	if (client < 1 || client > MaxClients)
		return false;

	if (!IsClientInGame(client) || IsFakeClient(client))
		return false;

	return GetClientTeam(client) == TEAM_INFECTED;
}

// 1.6.1：清掉某个客户端在节流表里的整行（作为攻击者）与整列（作为目标 bot）。
// 换图 / 进服 / 离服都要清 —— 二维表必须行列一起清，否则客户端槽位被复用时会带着
// 上一个玩家的冷却时间戳，又变成"有时不提示"。
void ResetWarnLast(int client)
{
	for (int i = 0; i <= MaxClients; i++)
	{
		g_fWarnLast[client][i] = 0.0;
		g_fWarnLast[i][client] = 0.0;
	}
}

// 带节流的入口：守护中的 AI 生还者被玩家特感攻击时调用
void NotifyGuardBlocked(int attacker, int victim)
{
	if (!g_cvWarn.BoolValue)
		return;

	if (!IsWarnTarget(attacker))
		return;

	// 1.6.1：提示只针对"打到某一只具体的人机"。目标索引无效（世界伤害 / 实体伤害）直接返回，
	//   同时也避免下面二维节流表用非法索引越界。
	if (victim < 1 || victim > MaxClients)
		return;

	float fNow = GetGameTime();
	float fCooldown = g_cvWarnCooldown.FloatValue;
	if (fCooldown < 0.0)
		fCooldown = 0.0;

	// 1.6.1：节流按「攻击者 × 目标 bot」成对计时。旧实现只有 g_fWarnLast[attacker] 一维表，
	//   同一名特感玩家 1 秒内打第二只守护中的人机时整条提示被吞掉，而且提示文案里的名字
	//   还是上一只 bot 的 —— 玩家反馈的"有时守护状态下的人机不会正确提示守护"就是这条路。
	//   现在：同一只 bot 仍然按 warn_cooldown 节流（防连点刷屏），换一只 bot 立刻重新提示。
	if (fCooldown > 0.0 && g_fWarnLast[attacker][victim] > 0.0
		&& fNow - g_fWarnLast[attacker][victim] < fCooldown)
		return;

	g_fWarnLast[attacker][victim] = fNow;

	ShowGuardBlockedHint(attacker, victim);
}

// 真正发提示（节流在 NotifyGuardBlocked 里做；管理员命令 sm_botguard_warntest 直接调它）
void ShowGuardBlockedHint(int attacker, int victim)
{
	if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker))
		return;

	// 被守护的生还者名字（找不到就退化成通用说法，管理员命令单独测试时也好看）
	char sName[MAX_NAME_LENGTH];
	if (victim > 0 && victim <= MaxClients && IsClientInGame(victim))
		Format(sName, sizeof(sName), "%N", victim);
	else
		strcopy(sName, sizeof(sName), "该 AI 生还者");

	// 提示音（默认 = 投票失败音效）
	if (g_sWarnSound[0] != '\0')
		EmitSoundToClient(attacker, g_sWarnSound, SOUND_FROM_PLAYER, SNDCHAN_AUTO,
			SNDLEVEL_NORMAL, SND_NOFLAGS, 1.0);

	// 渠道① 聊天框
	if (g_cvWarnChat.BoolValue)
	{
		PrintToChat(attacker, "\x04[人机守护]\x01 \x03%s\x01 处于守护状态：\x04免疫伤害 / 免疫控制\x01，攻击与技能都不会生效。",
			sName);
	}

	// 渠道② 屏幕提示（PrintHintText）
	if (g_cvWarnHint.BoolValue)
	{
		PrintHintText(attacker, "人机守护中：%s 无敌（免疫伤害与控制）", sName);
	}

	// 渠道③ HUD 文字（画面上方，2.5 秒）
	if (g_cvWarnHud.BoolValue)
	{
		SetHudTextParams(-1.0, 0.12, 2.5, 255, 80, 80, 255, 0, 0.0, 0.0, 0.0);
		ShowHudText(attacker, -1, "[人机守护] %s 免疫伤害 / 免疫控制", sName);
	}
}

// sm_botguard_warntest [目标]：不节流地演示一遍提示，用来确认音效文件是否存在、三渠道是否都能看到
public Action Cmd_WarnTest(int client, int args)
{
	int target = client;

	if (args >= 1)
	{
		char sArg[MAX_NAME_LENGTH];
		GetCmdArg(1, sArg, sizeof(sArg));

		target = FindTarget(client, sArg, false, false);
		if (target == -1)
			return Plugin_Handled;
	}

	if (target < 1 || target > MaxClients || !IsClientInGame(target))
	{
		ReplyToCommand(client, "\x04[BotGuard]\x01 目标无效或不在游戏中。");
		return Plugin_Handled;
	}

	// 找一个当前守护中的 bot 当作"被打的对象"，没有就用通用文案
	int victim = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && g_bGuarded[i])
		{
			victim = i;
			break;
		}
	}

	for (int i = 0; i <= MaxClients; i++)
		g_fWarnLast[target][i] = 0.0;
	ShowGuardBlockedHint(target, victim);

	ReplyToCommand(client, "\x04[BotGuard]\x01 已向 #%d 发送一次演示提示（音效=%s，服务器端文件探测=%d，节流已跳过）。",
		target, (g_sWarnSound[0] != '\0') ? g_sWarnSound : "无", WarnSoundFoundOnServer() ? 1 : 0);
	ReplyToCommand(client, "\x04[BotGuard]\x01 注意：探测=0 不代表播放不了（srcds 上的库存音效常常只存在于 VPK / 由客户端本地提供）；以耳朵听到的为准。");

	return Plugin_Handled;
}

// 是否应该进入守护状态
// bIgnoreIdleBody：唯一给 1.3.3 的"接管时打断继承吃药"用的口子 —— 那件事发生在
// player_bot_replace（玩家离开身体 / 切旁观）的瞬间，判断依据应该是"这具身体的血量
// 够不够守护"，与"它现在是不是空闲身体"无关；否则闲置身体会继承玩家手里的药并把药吃掉。
// 其它调用点（UpdateGuardSet / Timer_Protect / Timer_Tick）一律用默认 false。
bool ShouldGuard(int client, bool bIgnoreIdleBody = false)
{
	if (!g_cvEnabled.BoolValue)
		return false;

	if (!IsClientInGame(client))
		return false;

	// 只处理生还者队伍里"非玩家操控"的那些
	if (GetClientTeam(client) != TEAM_SURVIVOR)
		return false;

	if (!IsFakeClient(client))
		return false;

	if (!IsPlayerAlive(client))
		return false;

	// 倒地后守护关闭：倒地 + 免伤 + 不能流血会造成永久卡关，
	// 倒地统一交给下面的"自动救起"处理
	if (IsIncapacitated(client))
		return false;

	// 1.4.0：挂边 / 挂边坠落同样不能进守护。
	//   挂边（m_isHangingFromLedge）不写 m_isIncapacitated，所以以前会被当成"正常的低血 bot"；
	//   挂边到时间往下掉（m_isFallingFromLedge）时引擎已经在走死亡流程，此时给
	//   m_takedamage=0 + 血量回锁会把死亡流程冻住 —— 这就是玩家反馈的
	//   "挂边的 bot 卡在原地无敌，直到有人接管才结束，接管瞬间就死"。
	if (IsOnLedge(client))
		return false;

	// 1.5.0（需求1）：有真人主控的空闲身体（玩家倒地后自己切旁观 / 掉线托管）不给守护。
	//   理由与自动起身相同：替它免伤 = 让玩家"旁观 -> 再加入"白拿一段无敌。
	//   玩家重新加入并接管后 IsFakeClient 变 false，上面那道判断已经先排除了，
	//   因此接管后不会出现"又补一次守护"的情况。
	//   bIgnoreIdleBody 只给"接管瞬间打断继承吃药"用，见函数头注释。
	if (!bIgnoreIdleBody && IsIdleBody(client))
		return false;

	return GetTotalHealth(client) <= g_cvHealth.IntValue;
}

void EnterGuard(int client)
{
	g_bGuarded[client] = true;

	// HasEntProp 结果只用于诊断（sm_botguard_status 里显示），
	// **不再**作为是否写发光的开关 —— 1.0.0 把它当门用过，结果顾客反馈"看不到光"：
	// 发光属性挂在 DT_BaseEntity 的嵌套表 m_Glow 里，HasEntProp 对嵌套表判 false 时
	// 整个发光就被静默跳过了。其它成熟插件（LMC / extendedsight / defib_revive）
	// 都是直接 SetEntProp，没有这道门。
	g_bGlowProps[client] = HasEntProp(client, Prop_Send, "m_iGlowType")
		&& HasEntProp(client, Prop_Send, "m_glowColorOverride")
		&& HasEntProp(client, Prop_Send, "m_nGlowRange");

	// 记录进入守护前的发光状态，退出时原样写回
	g_iOrigGlowType[client] = GetEntProp(client, Prop_Send, "m_iGlowType");
	g_iOrigGlowColor[client] = GetEntProp(client, Prop_Send, "m_glowColorOverride");
	g_iOrigGlowRange[client] = GetEntProp(client, Prop_Send, "m_nGlowRange");
	g_iOrigGlowRangeMin[client] = GetEntProp(client, Prop_Send, "m_nGlowRangeMin");

	// 冻结当前虚血
	g_fTempStash[client] = L4D_GetTempHealth(client);

	// 1.2.3：锁定实血。守护期间 Timer_Protect 会把实血顶回这个值，
	// 挡住 spitter 酸液这类不经过 OnTakeDamage 的掉血
	g_iGuardHealth[client] = GetClientHealth(client);
	if (g_iGuardHealth[client] < 1)
		g_iGuardHealth[client] = 1;

	// 1.2.2：引擎层免伤。只用 SDKHook_OnTakeDamage 拦截挡不住所有路径
	// （玩家反馈"无敌状态下 charger 概率造成伤害/概率控中"），这里同时把
	// m_takedamage 置 0（rygive 的 god mode 同款写法），让引擎自己就不接伤害。
	g_iOrigTakeDamage[client] = GetEntProp(client, Prop_Data, "m_takedamage", 1);
	SetEntProp(client, Prop_Data, "m_takedamage", 0, 1);

	if (g_cvGlow.BoolValue)
		ApplyGlow(client, true);

	// 进入守护的瞬间若正被控制，立即解控
	// 1.2.0：名额已经由 UpdateGuardSet / OnTakeDamage 判定过，这里不再看旧的数量开关
	if (g_cvBlockControl.BoolValue)
	{
		// 1.6.1：进守护时若正被控制，解控的同时把"守护中"提示发给控制者。
		//   以前这里是静默解控：特感玩家眼看技能生效又被凭空解开，却没有任何提示。
		NotifyGuardBlocked(ReleaseControl(client), client);
	}
}

void LeaveGuard(int client)
{
	g_bGuarded[client] = false;
	g_fTempStash[client] = 0.0;
	g_iGuardHealth[client] = 0;

	if (!IsClientInGame(client))
		return;

	// 1.2.2：恢复引擎层受击状态（进入守护前的值；取不到就按正常 2 = DAMAGE_AIM）
	int iTakeDamage = g_iOrigTakeDamage[client];

	if (iTakeDamage <= 0)
		iTakeDamage = 2;

	SetEntProp(client, Prop_Data, "m_takedamage", iTakeDamage, 1);

	// 恢复进入守护前的发光 netprop
	SetEntProp(client, Prop_Send, "m_iGlowType", g_iOrigGlowType[client]);
	SetEntProp(client, Prop_Send, "m_glowColorOverride", g_iOrigGlowColor[client]);
	SetEntProp(client, Prop_Send, "m_nGlowRange", g_iOrigGlowRange[client]);
	SetEntProp(client, Prop_Send, "m_nGlowRangeMin", g_iOrigGlowRangeMin[client]);

	if (g_cvGlowFlash.BoolValue)
		SetEntProp(client, Prop_Send, "m_bFlashing", 0, 1);
}

// ============================================================================
// 白色轮廓（参考 l4d2_tank_defib_revive / LMC_Black_and_White_Notifier 的写法）
// ============================================================================

void ApplyGlow(int client, bool bOn)
{
	if (bOn)
	{
		SetEntProp(client, Prop_Send, "m_iGlowType", GLOW_TYPE_CONSTANT);
		SetEntProp(client, Prop_Send, "m_glowColorOverride", g_iGlowColorPacked);
		SetEntProp(client, Prop_Send, "m_nGlowRange", g_cvGlowRange.IntValue);
		// 1.1.0：补上 m_nGlowRangeMin —— 服务器上已经在跑的 witch_glow 就是
		// type3 + color + rangeMin + range 这套，缺 rangeMin 时不一定显示
		SetEntProp(client, Prop_Send, "m_nGlowRangeMin", g_cvGlowRangeMin.IntValue);

		// m_bFlashing 是 1 bit 属性，必须显式传 size=1（LMC 同款写法）
		if (g_cvGlowFlash.BoolValue)
			SetEntProp(client, Prop_Send, "m_bFlashing", 1, 1);
	}
	else
	{
		// 闪的"灭"相位：只关类型，颜色留着不动，减少无意义写属性
		SetEntProp(client, Prop_Send, "m_iGlowType", 0);

		if (g_cvGlowFlash.BoolValue)
			SetEntProp(client, Prop_Send, "m_bFlashing", 0, 1);
	}
}

// 把 "R G B" 解析成 L4D2 的打包颜色（R | G<<8 | B<<16，与 LMC 的 GetColor 同口径）
void ParseGlowColor()
{
	char sBuffer[64];
	g_cvGlowColor.GetString(sBuffer, sizeof(sBuffer));

	char sParts[3][8];
	int iR = 255;
	int iG = 255;
	int iB = 255;

	// 手工解析，避免多参数刷屏；解析失败时回落白色（绝不能回落 0 = 黑色，那等于没光）
	if (ExplodeString(sBuffer, " ", sParts, sizeof(sParts), sizeof(sParts[])) == 3)
	{
		iR = ClampInt(StringToInt(sParts[0]));
		iG = ClampInt(StringToInt(sParts[1]));
		iB = ClampInt(StringToInt(sParts[2]));
	}

	g_iGlowColorPacked = iR | (iG << 8) | (iB << 16);

	// 纯黑等于"看不见"，直接把 0 当无效值纠正成白色，避免配置写错后静默失效
	if (g_iGlowColorPacked == 0)
		g_iGlowColorPacked = 0xFFFFFF;
}

int ClampInt(int iValue)
{
	if (iValue < 0)
		return 0;
	if (iValue > 255)
		return 255;
	return iValue;
}

// ============================================================================
// 免疫伤害（参考 rygive 的 OnTakeDamage god mode）
// ============================================================================

public Action Hook_OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage,
	int &damagetype, int &weapon, float damageForce[3], float damagePosition[3], int damagecustom)
{
	if (victim <= 0 || victim > MaxClients)
		return Plugin_Continue;

	// 已在守护状态：任何伤害一律吃掉，虚血继续冻结（保持 1.1.0 的原有逻辑）
	// 1.2.0 起不再有"AI 数量超限就整段失效"的开关，改由名额本身控制谁能进守护
	if (g_cvInvincible.BoolValue && g_bGuarded[victim])
	{
		// 1.5.0：这具身体如果已经变成"有真人主控的空闲身体"（玩家倒地后自己切旁观 / 掉线），
		// 先退出守护再放行这次伤害 —— 否则"旁观一下"就能让身体一直无敌下去。
		// （Timer_Protect 的 0.1s 复核也会撤，这里多一道，保证伤害路径上绝不吃错守护。）
		if (IsIdleBody(victim) || !IsFakeClient(victim))
		{
			LeaveGuard(victim);
			return Plugin_Continue;
		}

		// 1.4.0：守护中的人若已经进入倒地/挂边/坠落状态，先退出守护再放行这次伤害，
		// 否则会把引擎的死亡流程一起吃掉（卡原地无敌）。
		if (IsIncapacitated(victim) || IsOnLedge(victim))
		{
			LeaveGuard(victim);
			return Plugin_Continue;
		}

		// 1.3.0：告诉攻击的玩家特感"这只人机是无敌的"（提示音 + 三渠道文字，带 1 秒节流）
		NotifyGuardBlocked(attacker, victim);

		damage = 0.0;
		return Plugin_Handled;
	}

	// 1.5.0：自动起身后的极短保护窗口（REVIVE_PROTECT_TIME，见 ReviveBotNow）。
	//   起身血量默认只有 1 点，同一波尸潮里"起身 -> 立刻再被摸倒 -> 又起身"会变成循环
	//   （聊天框反复刷提示、人机在地上反复抽搐）。这里只挡"这一下会当场把他再打倒"的
	//   伤害：不吞小伤害，也不写 m_takedamage，所以不是第二套无敌；
	//   窗口只是一个到期时间戳，到点自动失效；玩家重新接管身体后 IsGuardTarget 返回 false。
	//   条件顺序按"最便宜、最常为假"排：g_fReviveProtectUntil 几乎总是 0，先短路掉，
	//   不给每一发子弹都去读血量/属性。
	//   位置说明：它排在守护分支之后 —— 已守护的 bot 走上面那条（含"打不动"提示），
	//   互不干扰；同时又排在 l4d2_bot_guard_invincible 之外，因为它是"自动起身"这条
	//   需求自带的防循环措施，与"免伤"开关无关（关掉免伤也照样防这 1 秒的"起身即倒"）。
	if (g_cvEnabled.BoolValue
		&& g_fReviveProtectUntil[victim] > 0.0 && GetGameTime() < g_fReviveProtectUntil[victim]
		&& damage > 0.0 && IsGuardTarget(victim)
		&& !IsIncapacitated(victim) && !IsOnLedge(victim)
		&& damage >= float(GetTotalHealth(victim)))
	{
		damage = 0.0;
		return Plugin_Handled;
	}

	if (!g_cvInvincible.BoolValue)
		return Plugin_Continue;

	// 1.2.0 需求4："保命"判定
	// 只有非玩家操控、存活未倒地的生还者才可能被保命
	if (!IsGuardTarget(victim))
		return Plugin_Continue;

	if (IsIncapacitated(victim))
		return Plugin_Continue;

	// 1.4.0：挂边 / 挂边坠落的人不做"保命"。挂边坠落已经是引擎在执行的死亡流程，
	// 这时候把他打进守护（m_takedamage=0 + 血量回锁）就会冻住死亡流程 —— 玩家反馈的
	// "挂边的 bot 卡在原地无敌，直到有人接管才结束"就是从这里进去的。
	if (IsOnLedge(victim))
		return Plugin_Continue;

	// 0 伤害的"记分"事件不是真伤害，不参与保命判定
	if (damage <= 0.0)
		return Plugin_Continue;

	// 本次伤害是否"足够把他打成倒地"（伤害 >= 当前总血量）
	int iTotal = GetTotalHealth(victim);

	if (damage < float(iTotal))
		return Plugin_Continue;

	// 名额判定：现算一遍（不等下一 tick），当前守护人数 < 可守护数才保命。
	// 不在名额内的 bot 不做保命，照常掉血 / 倒地（否则全队 bot 永远打不死）。
	// 顺手刷新状态缓存，让 sm_botguard_status 立刻能看到最新数字
	g_iAiSurvivors = CountAiSurvivors();
	g_iDownCount = CountDownedSurvivors();
	g_iGuardAllowed = ComputeAllowedGuards();

	int iAllowed = g_iGuardAllowed;

	if (CountGuarded() >= iAllowed)
		return Plugin_Continue;

	// 吃伤害 -> 虚血清 0 -> 实血设为阈值（默认 10）-> 立即进入守护状态
	damage = 0.0;

	L4D_SetTempHealth(victim, 0.0);

	int iHealth = g_cvHealth.IntValue;
	if (iHealth < 1)
		iHealth = 1;

	SetEntityHealth(victim, iHealth);

	EnterGuard(victim);
	g_iGuardCount = CountGuarded();

	// 1.3.0：这一击被"保命"吃掉并当场进入守护，同样提示攻击的玩家特感
	NotifyGuardBlocked(attacker, victim);

	return Plugin_Handled;
}

// ============================================================================
// 免控 / 解控
// ============================================================================

// 参考 rygive.sp: ReleaseControl()
//
// 1.6.1：返回值 = 本次被"守护"强行解掉的控制者里第一个玩家特感的客户端索引（没有则 0）。
//   "技能被守护挡掉"也是需要提示的一件事。以前只有六个前置 forward 与伤害拦截会提示，
//   "已经在控 / 刚进守护时被强制解控"这条路完全静默：低血人机在轮到守护之前被扑住、
//   拖走，下一轮进入守护时由这里解开，特感玩家毫无反馈。
//   调用点用返回值补发同一条提示，节流仍然生效，不会刷屏。
int ReleaseControl(int victim)
{
	int attacker;
	int iController = 0;

	attacker = GetEntPropEnt(victim, Prop_Send, "m_tongueOwner");
	if (attacker > 0 && attacker <= MaxClients)
	{
		L4D_Smoker_ReleaseVictim(victim, attacker);

		if (iController == 0)
			iController = attacker;
	}

	attacker = GetEntPropEnt(victim, Prop_Send, "m_pounceAttacker");
	if (attacker > 0 && attacker <= MaxClients)
	{
		L4D_Hunter_ReleaseVictim(victim, attacker);

		if (iController == 0)
			iController = attacker;
	}

	attacker = GetEntPropEnt(victim, Prop_Send, "m_jockeyAttacker");
	if (attacker > 0 && attacker <= MaxClients)
	{
		L4D2_Jockey_EndRide(victim, attacker);

		if (iController == 0)
			iController = attacker;
	}

	attacker = GetEntPropEnt(victim, Prop_Send, "m_carryAttacker");
	if (attacker > 0 && attacker <= MaxClients)
	{
		L4D2_Charger_EndCarry(victim, attacker);

		if (iController == 0)
			iController = attacker;
	}

	attacker = GetEntPropEnt(victim, Prop_Send, "m_pummelAttacker");
	if (attacker > 0 && attacker <= MaxClients)
	{
		L4D2_Charger_EndPummel(victim, attacker);

		if (iController == 0)
			iController = attacker;
	}

	return iController;
}

// 舌头：前置 forward 拦下等于"抓不到"
public Action L4D_OnGrabWithTongue(int victim, int attacker)
{
	if (BlockControlOn(victim))
	{
		NotifyGuardBlocked(attacker, victim);
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

// 猎人扑击
public Action L4D_OnPouncedOnSurvivor(int victim, int attacker)
{
	if (BlockControlOn(victim))
	{
		NotifyGuardBlocked(attacker, victim);
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

// 猴子骑乘
public Action L4D2_OnJockeyRide(int victim, int attacker)
{
	if (BlockControlOn(victim))
	{
		NotifyGuardBlocked(attacker, victim);
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

// 牛冲撞抱人
public Action L4D2_OnStartCarryingVictim(int victim, int attacker)
{
	if (BlockControlOn(victim))
	{
		NotifyGuardBlocked(attacker, victim);
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

// 牛捶打（charger pummel）：1.2.3 新增。left4dhooks 有前置 forward（注意参数顺序是 attacker, victim），
// 拦下来比"被捶打后再 EndPummel"干净 —— 玩家反馈守护中的 bot 仍会被牛捶打/拖走就是这个缺口
public Action L4D2_OnPummelVictim(int attacker, int victim)
{
	if (BlockControlOn(victim))
	{
		NotifyGuardBlocked(attacker, victim);
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

// 牛把人撞到墙上（会造成倒地/致残伤害）：守护中的生还者直接吃掉这次撞墙
public Action L4D2_OnSlammedSurvivor(int victim, int attacker, bool &bWallSlam, bool &bDeadlyCharge)
{
	if (BlockControlOn(victim))
	{
		NotifyGuardBlocked(attacker, victim);
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

bool BlockControlOn(int victim)
{
	if (!g_cvBlockControl.BoolValue)
		return false;

	if (victim <= 0 || victim > MaxClients)
		return false;

	// 1.2.0：守护名额已经保证"最多 max_count 个"，不需要再另设数量开关
	return g_bGuarded[victim];
}

// ============================================================================
// 1.4.0：自动起身（轮询式；次数默认 -1 = 不设每回合上限）
//
// 与旧实现的区别（这三点都是玩家反馈逼出来的）：
//   ① 旧实现"每回合每人只有 1 次"，次数用完倒地就只能流血死 —— 现在默认 -1 = 不设每回合上限。
//   ② 旧实现只在 player_incapacitated 事件里排一个一次性 timer：事件漏接（插件晚加载、
//      事件在插件就绪前发生）、或者人是"挂边"而不是"倒地"，就完全不会救。
//      现在改成由 0.1s 的保护线程持续扫描**所有生还者**的状态 —— 只要看到
//      "倒地 / 挂边" 且是本插件该管的 bot，就走救起流程，不依赖任何事件。
//   ③ 旧实现救起后不管"倒地次数"，救起来的人仍然算"已经倒地过"（下一次倒地可能直接
//      进黑白甚至直接死）。现在起身时把 m_currentReviveCount 与 m_bIsOnThirdStrike
//      一起清零 = 当作没倒地过。
//
// 1.5.0：目标判定（IsGuardCandidate）里排除了"有真人主控的空闲身体"（IsIdleBody），
//        所以"倒地 -> 自己切旁观 -> 身体被 bot 顶着 -> 插件替他起身 -> 再加入游戏"这条
//        白拿起身的路子没有了。候选一旦失效（含玩家重新接管，IsFakeClient 变 false），
//        下面第一道判断就会把 g_fReviveAt / g_bReviveCounted 清掉，不会"排期完再补一次"。
//
// 状态机（每个生还者各自一份）：
//   g_fReviveAt           计划起身的时间；发现"需要起身"时排期（= 现在 + revive_delay）
//   g_bReviveCounted      本次倒地/挂边是否已经扣过次数；起身失败会重试，重试不重复扣
//   g_fReviveProtectUntil 起身成功后的极短伤害保护窗口（1.5.0，默认 1 秒，到期自动失效）
// ============================================================================

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	// 回合开始时重置每名客户端的自动救起次数（-1 = 不设每回合上限）
	for (int i = 0; i <= MaxClients; i++)
	{
		g_iReviveLeft[i] = g_cvReviveTimes.IntValue;
		g_fReviveAt[i] = 0.0;
		g_bReviveCounted[i] = false;
		// 1.5.0：起身保护窗口不跨回合（它只有 1 秒，跨回合保留没有意义还会误挡）
		g_fReviveProtectUntil[i] = 0.0;
	}

	g_fNotifyNextAt = 0.0;

	// 1.3.4：本回合重新判定「终点安全屋」的运行期条件
	// （native 可用性 + 本图有没有 info_changelevel；救援关会自动识别成"没有"）。
	RefreshEndSaferoomState();
}

// 1.4.0：轮询所有生还者状态，把"倒地 / 挂边"的 bot 救起来。
// 返回 true 表示本次至少救起了一个人（调用方可据此重算守护名额）。
bool ProcessBotRevives()
{
	if (!g_cvEnabled.BoolValue)
		return false;

	// 0 = 关闭自动起身
	if (g_cvReviveTimes.IntValue == 0)
		return false;

	float fNow = GetGameTime();

	float fDelay = g_cvReviveDelay.FloatValue;
	if (fDelay < 0.0)
		fDelay = 0.0;

	bool bAnyRevived = false;

	for (int i = 1; i <= MaxClients; i++)
	{
		// 不是本插件该管的生还者（真人 / 已接管 / 已死亡 / 非生还者队 / 1.5.0 有真人主控的空闲身体）
		// → 清状态，不救。
		// 1.5.0：这条同时是"接管前排期、接管后补起身"的封堵点 —— 玩家重新加入接管后
		//   IsFakeClient 变 false，候选立刻失效，排期（g_fReviveAt）与扣次标记（g_bReviveCounted）
		//   在这里被清零，绝不会隔一帧再补一次起身。
		// 注意顺序：这一道必须先于 NeedsReviveNow —— 它内部会读 m_isIncapacitated 等
		// Prop_Send，对"已经不在游戏中 / 非生还者队"的索引读属性是错的，不能拿它当前置过滤。
		if (!IsGuardCandidate(i))
		{
			g_fReviveAt[i] = 0.0;
			g_bReviveCounted[i] = false;
			continue;
		}

		// 现在不需要起身（站着 / 或者已经掉边坠落交给引擎）→ 结束这一轮，清状态
		if (!NeedsReviveNow(i))
		{
			g_fReviveAt[i] = 0.0;
			g_bReviveCounted[i] = false;
			continue;
		}

		// 1.5.0：起身保护窗口内不重复起身。正常情况下窗口内打不倒他；
		// 万一被不经过 OnTakeDamage 的伤害（例如酸液）打回倒地，也至少隔一个窗口再起身，
		// 保证"起身-倒地"的频率有上界。（窗口是时间戳，过期即失效，不会卡住救起）
		if (g_fReviveProtectUntil[i] > 0.0 && fNow < g_fReviveProtectUntil[i])
		{
			g_fReviveAt[i] = 0.0;
			continue;
		}

		if (!HasReviveLeft(i))
		{
			// 次数用完（仅在 >0 的有限模式里出现）：保留倒地状态，按正常规则流血死亡
			g_fReviveAt[i] = 0.0;
			continue;
		}

		// 第一次发现 → 排期（revive_delay = 0 时就是"发现即救"）
		if (g_fReviveAt[i] <= 0.0)
			g_fReviveAt[i] = fNow + fDelay;

		if (fNow < g_fReviveAt[i])
			continue;

		// 本次倒地只扣一次次数：救起失败会在 REVIVE_RETRY_INTERVAL 后重试，不能重复扣
		if (!g_bReviveCounted[i])
		{
			if (g_cvReviveTimes.IntValue > 0 && g_iReviveLeft[i] > 0)
				g_iReviveLeft[i]--;

			g_bReviveCounted[i] = true;
		}

		bool bRevived = ReviveBotNow(i);

		if (bRevived)
		{
			g_fReviveAt[i] = 0.0;
			bAnyRevived = true;
		}
		else
		{
			// 没救起来（引擎拒绝 / 还挂在边缘上）：稍后重试
			float fRetry = (fDelay > REVIVE_RETRY_INTERVAL) ? fDelay : REVIVE_RETRY_INTERVAL;
			g_fReviveAt[i] = fNow + fRetry;
		}
	}

	return bAnyRevived;
}

// 1.4.0：立刻救起一个"倒地 / 挂边"的 bot，并把倒地次数清零（当作没倒地过）。
// 返回 true = 救完之后复查，确实已经不在倒地/挂边状态了（引擎已把人拉起来）。
//
// 注意收尾（血量 / 倒地次数）是**无条件**写的，不等复查通过：
// 引擎有时要下一帧才清 m_isIncapacitated，如果等复查通过才写，这一次救起的收尾就会漏掉
// （人已经站起来，但血还是倒地时的 1，倒地次数也没清）。重复写这些属性是无害的。
//
// 1.5.0 顺序说明（不要调换）：L4D_ReviveSurvivor -> SetEntityHealth -> 清虚血 ->
//   清 m_currentReviveCount / m_bIsOnThirdStrike -> 开保护窗口。
//   引擎在 ReviveSurvivor 内部会按"黑白/第三人称打击"的规则重写这几个值，所以清零必须
//   放在它之后；这两个属性都是 Prop_Send（netprop-dump：m_currentReviveCount 8bit、
//   m_bIsOnThirdStrike 1bit），后者是位属性，必须显式传 size=1。
bool ReviveBotNow(int client)
{
	if (!IsClientInGame(client) || !IsPlayerAlive(client))
		return false;

	// 1.5.0 最后一道闸（需求1）：真到了"动手拉人"的这一刻，再复核一次这具身体
	//   还归不归本插件管 —— 玩家可能刚好在这一帧重新加入了（IsFakeClient 变 false），
	//   也可能身体已经被挂机托管（IsIdleBody）。两种都不许替他把人拉起来。
	//   返回 false 后调用方会在 REVIVE_RETRY_INTERVAL 后再试，下一轮候选判定就会把
	//   g_fReviveAt / g_bReviveCounted 清掉，因此不会出现"接管后补一次起身"。
	if (!IsFakeClient(client) || IsIdleBody(client))
		return false;

	// Left4DHooks: 让倒地/挂边生还者起身
	// （left4dhooks.inc 的 @brief：Revives an incapacitated survivor, also from ledge hanging）
	L4D_ReviveSurvivor(client);

	if (!IsClientInGame(client) || !IsPlayerAlive(client))
		return false;

	int iHealth = g_cvReviveHealth.IntValue;
	if (iHealth < 1)
		iHealth = 1;

	SetEntityHealth(client, iHealth);

	// 1.5.0：起身血量默认改成 1 点。只写实血不够 —— "总血量"是本插件 GetTotalHealth
	// 的口径（实血 + 虚血），引擎起身时会留一段虚血，虚血留着的话"1 点血"就只是名义上的
	// 1 点（总血可能还是几十）。这里把虚血一起清 0，保证起身瞬间真的是 1 点血。
	L4D_SetTempHealth(client, 0.0);

	// 1.4.0 需求：起身后"当作没倒地过"。
	//   m_currentReviveCount  已经倒地过几次 —— 决定下一次倒地是不是"第三次打击"
	//   m_bIsOnThirdStrike    第三次打击（黑白 / 再倒直接死）的标记位
	// 两个都要清：只清前者的话黑白画面和"再倒就死"的判定还会留着。
	SetEntProp(client, Prop_Send, "m_currentReviveCount", 0);
	SetEntProp(client, Prop_Send, "m_bIsOnThirdStrike", 0, 1);

	// 复查：引擎拒绝（例如挂边的人拉不上来）时状态不会变，交给调用方稍后重试
	if (NeedsReviveNow(client))
		return false;

	// 1.5.0：起身成功 -> 开一个极短的伤害保护窗口（默认 1 秒）。
	// 血量 1 点 + 0.1s 轮询 = 起身那一瞬间被摸到就立刻再倒地，再被轮询到又起身，
	// 形成"起身-倒地"循环（聊天反复刷提示、人机原地抽搐）。窗口只挡"这一下会当场把他
	// 再打倒"的伤害（见 Hook_OnTakeDamage），不吞小伤害、不写 m_takedamage，
	// 所以不是第二套无敌；它只是 1 个到期时间戳，到点自动失效，也不需要额外的清理逻辑。
	g_fReviveProtectUntil[client] = GetGameTime() + REVIVE_PROTECT_TIME;

	NotifyBotRevived(client);

	return true;
}

// 1.4.0：起身提示（全局节流 REVIVE_NOTIFY_COOLDOWN，次数不设上限时不会刷屏）。
// 1.5.0：文案去掉"无限/不限"的口径（玩家反馈"现在是无限起身"，旧文案读起来像无限）。
// 1.6.0：**不再输出"倒地次数已清零"**（用户要求）—— 属性照旧清零，只是不显示。
//   现行口径：
//     - 次数不设上限（cvar < 0）："[提示] AI 生还者 %N 已自动起身（血量 %d）。"
//     - 有限次数还有剩余的：追加"本回合剩余自动起身 %d 次"
//     - 有限次数已用完的：追加"本回合自动起身次数已用完"（这一次是最后一次）
void NotifyBotRevived(int client)
{
	if (!g_cvNotify.BoolValue)
		return;

	float fNow = GetGameTime();

	if (fNow < g_fNotifyNextAt)
		return;

	g_fNotifyNextAt = fNow + REVIVE_NOTIFY_COOLDOWN;

	// 起身后的血量就是 cvar 的值（下界 1），文案里直接报出来，方便服主对照
	int iHealth = g_cvReviveHealth.IntValue;
	if (iHealth < 1)
		iHealth = 1;

	if (g_cvReviveTimes.IntValue < 0)
	{
		PrintToChatAll("\x03[提示] \x01AI 生还者 %N 已自动起身（血量 %d）。",
			client, iHealth);
	}
	else if (g_iReviveLeft[client] > 0)
	{
		PrintToChatAll("\x03[提示] \x01AI 生还者 %N 已自动起身（血量 %d；本回合剩余自动起身 %d 次）。",
			client, iHealth, g_iReviveLeft[client]);
	}
	else
	{
		PrintToChatAll("\x03[提示] \x01AI 生还者 %N 已自动起身（血量 %d；本回合自动起身次数已用完）。",
			client, iHealth);
	}
}

// ============================================================================
// 1.3.3：守护中的 AI 生还者禁止自行使用医疗物品（吃药 / 打针 / 打包）
//
//   Actions 扩展把引擎里生还者的"行为动作"暴露成具名 action，拦截手法就是给对应的
//   action 挂 OnStart / Update 回调，把 result.type 设成 DONE 来取消这个动作：
//     - SurvivorTakePills  吃药(weapon_pain_pills) 与 打针(weapon_adrenaline) 共用
//                          这一个 action —— server.dll 里没有独立的 SurvivorUseAdrenaline；
//     - SurvivorHealSelf   给自己打包(weapon_first_aid_kit)。
//   **不拦** SurvivorHealFriend / SurvivorGivePillsToFriend：那是给队友包扎/递药，
//   需求只要求"守护中不得自行使用"，救队友的行为保持原样。
//
//   参考实现：仓库里的 l4d2_block_bot_pills.sp（SurvivorTakePills 的 OnStart 拦截）
//   与 l4d_bot_healing.sp（SurvivorHealSelf / SurvivorTakePills 的 OnStart 写法）。
// ============================================================================

// 该 actor 的"自行用药"动作是否要拦：扩展可用 + 两个开关都开着 + 确实处于守护状态
bool ShouldBlockItemUse(int client)
{
	if (!g_bActionsAvailable || !g_cvBlockItems.BoolValue || !g_cvEnabled.BoolValue)
		return false;

	if (client < 1 || client > MaxClients)
		return false;

	// 只拦"守护中"的人机（守护状态由主状态机维护，见 EnterGuard / LeaveGuard）
	return g_bGuarded[client];
}

// 每个动作创建时挂回调。
// 注意：这里不能只按 g_bGuarded 决定挂不挂 —— 动作有可能在进入守护之前就创建好了，
// 所以按"动作名"挂上，真正是否拦截放到回调里用 ShouldBlockItemUse() 再判一次。
public void OnActionCreated(BehaviorAction action, int actor, const char[] name)
{
	if (!g_bActionsAvailable || !g_cvBlockItems.BoolValue)
		return;

	if (actor < 1 || actor > MaxClients || !IsClientInGame(actor))
		return;

	// 只关心"给自己用医疗物品"的两个 action（吃药/打针 共用 SurvivorTakePills）
	if (strcmp(name, "SurvivorTakePills") != 0 && strcmp(name, "SurvivorHealSelf") != 0)
		return;

	action.OnStart = OnGuardItemActionStart;
	action.Update  = OnGuardItemActionUpdate;
}

// 动作开始：守护中的直接取消（result.type = DONE）
public Action OnGuardItemActionStart(BehaviorAction action, int actor, BehaviorAction priorAction, ActionResult result)
{
	if (!ShouldBlockItemUse(actor))
		return Plugin_Continue;

	result.type = DONE;
	return Plugin_Changed;
}

// 动作进行中：守护状态可能在动作开始之后才生效（例如刚好被"保命"打进守护），
// 这里再拦一次，避免"已经开始吃"的人机把药吃完/把包打完。
public Action OnGuardItemActionUpdate(BehaviorAction action, int actor, float interval, ActionResult result)
{
	if (!ShouldBlockItemUse(actor))
		return Plugin_Continue;

	result.type = DONE;
	return Plugin_Changed;
}

// player_bot_replace 兜底（参考 l4d2_block_bot_pills.sp 的同名处理）：
// 玩家离开、身体交给 bot 接管时，bot 会"继承"玩家手里正在被使用的那件止痛药/肾上腺素，
// 于是刚接管的人机立刻把药吃掉。这里把新 bot 手上那件物品的实体换掉，打断这次自动服用。
public void Event_PlayerBotReplace(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnabled.BoolValue || !g_cvBlockItems.BoolValue)
		return;

	int bot = GetClientOfUserId(event.GetInt("bot"));

	if (bot < 1 || bot > MaxClients || !IsClientInGame(bot))
		return;

	// 只处理"接管后应当被守护"的人机（总血量已经掉到阈值以下的那批）
	// 1.5.0：这里必须 bIgnoreIdleBody=true —— player_bot_replace 的这一刻，身体刚刚变成
	// "有真人主控的空闲身体"，若跟着 IsIdleBody 一起跳过，玩家临走前手里正在吃的药/针
	// 会被 bot 服完（1.3.3 修过的问题会回来）。判断依据只该是"血量低到值得守护"。
	if (!ShouldGuard(bot, true))
		return;

	RefreshHeldHealItem(bot);
}

// 把 client 手上正拿着的止痛药/肾上腺素换成一件同款新实体（打断"继承"过来的使用动作）。
//   - 只看 slot 4（L4D2 的临时物品槽，止痛药与肾上腺素都在这一格），医疗包/除颤器不动；
//   - 先取类名再 Kill（Kill 之后旧实体句柄就悬空了）；
//   - 物品种类与数量都不变，只是换了个实体，bot 之后照样能用（只是这一口吃不成了）。
void RefreshHeldHealItem(int client)
{
	char sWeapon[64];
	GetClientWeapon(client, sWeapon, sizeof(sWeapon));

	// 只处理会"自动吃"的两件（药与针共用 SurvivorTakePills）
	if (strcmp(sWeapon, "weapon_pain_pills") != 0 && strcmp(sWeapon, "weapon_adrenaline") != 0)
		return;

	int iOld = GetPlayerWeaponSlot(client, 4);

	if (iOld <= 0 || !IsValidEntity(iOld))
		return;

	char sClass[64];
	GetEdictClassname(iOld, sClass, sizeof(sClass));

	if (sClass[0] == '\0')
		return;

	AcceptEntityInput(iOld, "Kill");

	int iNew = CreateEntityByName(sClass);

	if (iNew <= 0 || !IsValidEntity(iNew))
		return;

	DispatchSpawn(iNew);
	EquipPlayerWeapon(client, iNew);
}

// ============================================================================
// 工具
// ============================================================================

// 1.5.0：判断"这具身体虽然现在是 bot，但其实有真人主控"（= 空闲/托管身体）。
//
// 场景（需求1 的根因）：真人生还者倒地后自己切旁观（team 1）或掉线，引擎会把他的身体
// 交给一个 bot 顶着 —— 这一刻该 player 实体满足 IsFakeClient()==true，但它的
// m_humanSpectatorUserID（Prop_Send，integer/bits 32，netprop-dump 里
// SurvivorBot(DT_SurvivorBot) 那一项，offset 17188）会记下那个真人的 userid，
// 于是角色头顶显示"闲置：某某"。
// 旧逻辑只认"fake client + 生还者队 + 倒地"，于是照样替他起身 —— 玩家再加入游戏重新
// 接管身体时，人已经是站着的，等于"旁观一下就能白起身"。
//
// 判定手法与本仓库既有写法保持一致（l4d2_player_suicide.sp 的 IsClientIdle /
// IsGetBotOfIdlePlayer、l4d2_fix_team_shuffle_edi.sp 的 HasIdlePlayer、以及
// Left4DHooks 的 L4D_GetIdlePlayerOfBot 都是同一套）：
//   ① HasEntProp 先探测：m_humanSpectatorUserID 只在"正被托管"的 player 实体上才有，
//      未托管的 bot 直接读会抛 'Property "m_humanSpectatorUserID" not found'；
//   ② GetClientOfUserId 把 userid 换回客户端索引；
//   ③ 还要确认"这个索引确实还是个真人客户端"（>0、在游戏中、!IsFakeClient），
//      并且他此刻**在旁观队**（= 人不在操控任何身体，身体交给 AI 顶着）。
//      这样真人**彻底掉线**（userid 失效 -> GetClientOfUserId 返回 0）时判定不成立，
//      "没人接管的 bot 倒地就兜底起身"这个老用途完全不受影响。
//
//   实际取属主用的是 Left4DHooks 的 stock `L4D_GetIdlePlayerOfBot(bot)`
//   （left4dhooks_stocks.inc:525，官方注释 "Returns idle survivor player of survivor bot"）——
//   它内部就是 GetEntityNetClass + FindSendPropInfo("m_humanSpectatorUserID") + GetClientOfUserId，
//   与本仓库手写的那几份（l4d2_player_suicide.sp 的 IsClientIdle、l4d2_fix_team_shuffle_edi.sp
//   的 HasIdlePlayer）是同一套判定，找不到时返回 -1，不会读不存在的属性。
//   取到属主之后仍然自己复核"在游戏中 / 不是 bot / 在旁观队"，不直接信这个返回值。
//
// 取舍（为什么守护/起身排除它）：
//   本 cvar 的目标是"别让玩家靠旁观白拿东西"。自动起身和守护（免伤/免控/发光）都是
//   **实打实的收益**，给了就等于让玩家"旁观 -> 再加入"白赚一次起身 + 一段无敌，所以必须排除。
//   （1.6.0 起插件不再修改人机移速，所以"空闲身体要不要吃移速"这条取舍已经不存在了。）
bool IsIdleBody(int bot)
{
	// cvar = 0 时完全回到 1.4.0 的行为（方便服主临时对照）
	if (!g_cvSkipIdleBodies.BoolValue)
		return false;

	if (bot <= 0 || bot > MaxClients || !IsClientInGame(bot))
		return false;

	// 只有"身体现在是 bot"时才有托管这回事；真人正在操控的身体不走这条路径
	if (!IsFakeClient(bot))
		return false;

	// Left4DHooks 的 stock：取"这具 bot 身体是哪个闲置玩家的"
	// （left4dhooks_stocks.inc:525 L4D_GetIdlePlayerOfBot，内部就是
	//   FindSendPropInfo("m_humanSpectatorUserID") + GetClientOfUserId，找不到返回 -1）
	int iOwner = L4D_GetIdlePlayerOfBot(bot);

	if (iOwner <= 0 || iOwner > MaxClients || !IsClientInGame(iOwner))
		return false;

	// 属主必须还是个真人（不是另一个 bot），而且不能是这具身体自己
	if (iOwner == bot || IsFakeClient(iOwner))
		return false;

	// 属主此刻在旁观队（= 人不在操控任何身体，身体交给 AI 顶着：
	// 无论是自己按旁观 / 挂机闲置，还是倒地后切旁观，引擎都会把 m_humanSpectatorUserID
	// 指到他身上）。与本仓库既有写法一致（l4d2_fix_team_shuffle_edi.sp 的 HasIdlePlayer：
	// owner>0 && IsClientInGame && !IsFakeClient && GetClientTeam(owner)==TEAM_SPECTATOR；
	// l4d2_player_suicide.sp 的 IsGetBotOfIdlePlayer 用 IsClientIdle(i)==client 反查，本质相同）。
	// 真人彻底掉线时 userid 失效 -> GetClientOfUserId 返回 0，上面那步已经放过，
	// 所以"没人接管的 bot 倒地就兜底起身"这个老用途完全不受影响。
	// 这里**不**接受 team 2：属主若还在生还者队，说明那条托管链接是残留
	// （l4d_superversus.sp 的 ClearIdleLink 就是在清这种残留），不该因此少救一个真 AI。
	return GetClientTeam(iOwner) == TEAM_SPECTATOR;
}

// 是否是"非玩家操控的生还者"（自动起身的目标）
bool IsGuardTarget(int client)
{
	if (client <= 0 || client > MaxClients)
		return false;

	if (!IsClientInGame(client))
		return false;

	if (GetClientTeam(client) != TEAM_SURVIVOR)
		return false;

	if (!IsFakeClient(client))
		return false;

	if (!IsPlayerAlive(client))
		return false;

	// 1.5.0：有真人主控的空闲身体不算"无人接管的生还者"。
	// 这里与 IsGuardCandidate 必须同时排除，否则"保命"（OnTakeDamage）与救起保护窗口
	// 会绕开自动起身那道门，继续把无敌/保护送给可被玩家重新接管的身体。
	// 放在"存活"判断之后：先做最便宜的检查，再碰 netprop。
	if (IsIdleBody(client))
		return false;

	return true;
}

bool IsIncapacitated(int client)
{
	return GetEntProp(client, Prop_Send, "m_isIncapacitated", 1) != 0;
}

// 1.2.0：是否挂在边缘（挂边的人不算"站着的低血 bot"，不进守护、也不参与自动起身）
bool IsHangingFromLedge(int client)
{
	return GetEntProp(client, Prop_Send, "m_isHangingFromLedge", 1) != 0;
}

// 1.4.0：是否已经"从边缘掉下去了"（挂边超时 → 坠落死亡）。
// 这是引擎正在执行的死亡流程，不是可救/可守护的状态：
// 此时任何减伤或血量回写都会让死亡流程走不完，人卡在原地。
bool IsFallingFromLedge(int client)
{
	return GetEntProp(client, Prop_Send, "m_isFallingFromLedge", 1) != 0;
}

// 1.4.0：挂边 或 挂边坠落 —— 两种状态都不允许进守护（见 ShouldGuard）
bool IsOnLedge(int client)
{
	return IsHangingFromLedge(client) || IsFallingFromLedge(client);
}

// 1.4.0：守护候选 —— 只看"这个生还者是不是本插件该管的（非玩家操控的存活生还者）"，
// 不看血量 / 倒地 / 挂边。倒地、挂边的人要做的是"立刻起身"而不是"免伤"。
//
// 1.5.0（需求1）：再排除"有真人主控的空闲身体"（IsIdleBody）。
//   两种时机都覆盖：
//     ① 真人正在旁观：身体是 fake client（IsFakeClient 为 true），但 m_humanSpectatorUserID
//        指向那个真人 -> IsIdleBody 返回 true -> 这里排除，不替他起身、也不给他守护；
//     ② 真人已经重新加入并接管：IsFakeClient 变 false -> 上面那道判断直接排除；
//        另外 ProcessBotRevives 的候选失效分支会把 g_fReviveAt / g_bReviveCounted 清零，
//        所以"接管前一帧刚排好期"也不会在接管后补一次起身（见 ProcessBotRevives 注释）。
//   cvar l4d2_bot_guard_skip_idle_bodies = 0 时 IsIdleBody 恒 false，完全回到 1.4.0 行为。
bool IsGuardCandidate(int client)
{
	if (!g_cvEnabled.BoolValue)
		return false;

	if (client <= 0 || client > MaxClients)
		return false;

	if (!IsClientInGame(client))
		return false;

	if (GetClientTeam(client) != TEAM_SURVIVOR)
		return false;

	// 被真人接管后 IsFakeClient 会变 false，这里直接排除（接管的身体不归本插件管）
	if (!IsFakeClient(client))
		return false;

	if (!IsPlayerAlive(client))
		return false;

	// 1.5.0：还是 fake client，但其实是"有真人主控的空闲身体"（旁观 / 掉线托管）-> 同样排除
	if (IsIdleBody(client))
		return false;

	return true;
}

// 1.4.0：这个 bot 现在要不要救起 —— 倒地 或 挂边。
//   挂边坠落（IsFallingFromLedge）不在里面：那是引擎的死亡流程，人已经"掉下去"了，
//   此时救起只会把她从死亡流程里硬拽回来（玩家反馈的卡死就是这条路）。
bool NeedsReviveNow(int client)
{
	if (IsFallingFromLedge(client))
		return false;

	return IsIncapacitated(client) || IsHangingFromLedge(client);
}

// 1.4.0：还有没有起身次数。cvar < 0 = 不设每回合上限（1.5.0 起文案不再叫"不限/无限"）
bool HasReviveLeft(int client)
{
	if (g_cvReviveTimes.IntValue < 0)
		return true;

	return g_iReviveLeft[client] > 0;
}

// 总血量 = 实血 + 虚血（临时血量，已扣减自然衰减）
int GetTotalHealth(int client)
{
	int iReal = GetClientHealth(client);
	float fTemp = L4D_GetTempHealth(client);

	if (iReal < 0)
		iReal = 0;

	if (fTemp < 0.0)
		fTemp = 0.0;

	return iReal + RoundToNearest(fTemp);
}

// 1.5.0：当前场上有几个"有真人主控的空闲身体"（只给 sm_botguard_status 做读数用）。
// 判定与 IsIdleBody 完全一致，所以这里的数字就是被自动起身 / 守护排除掉的那批身体。
int CountIdleBodies()
{
	int iCount = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsIdleBody(i))
			iCount++;
	}

	return iCount;
}

// ============================================================================
// 排查 / 验证命令（管理员）
// ============================================================================

// sm_botguard_status：把插件"眼里的状态"全部打印出来。
// 之前出现"看不到光"时只能猜，这条命令让排查变成读数：
//   - 存活未接管生还者数量 / 倒地人数 / 可守护数 / 当前守护名单 / 阈值
//   - 每个 bot 的实血、虚血、总血、是否被接管、是否空闲身体（1.5.0）、守护状态、剩余起身次数
//   - （1.6.0 起不再显示移速：插件已不修改人机移速）
//   - 发光 netprop 当前值 + HasEntProp 结果（false 说明该客户端读不到属性表，但插件仍会照写）
public Action Cmd_Status(int client, int args)
{
	// 1.4.0：自动起身次数改成"cvar < 0 时不设上限"的写法
	// 1.5.0：文案从"不限(无限救起)"改成"不设上限"（玩家反馈"现在是无限起身"）
	char sReviveTimes[32];
	if (g_cvReviveTimes.IntValue < 0)
		strcopy(sReviveTimes, sizeof(sReviveTimes), "不设上限");
	else
		IntToString(g_cvReviveTimes.IntValue, sReviveTimes, sizeof(sReviveTimes));

	ReplyToCommand(client, "\x04[BotGuard]\x01 版本 %s | 开关=%d 阈值=%d 轮廓=%d(颜色=%d) 闪烁=%d 节奏=%.2fs | 免伤=%d 免控=%d 每回合起身上限=%s | 守护上限=%d（按未倒地比例分配） | 人机移速=引擎原版（本插件不修改）",
		PLUGIN_VERSION,
		g_cvEnabled.IntValue,
		g_cvHealth.IntValue,
		g_cvGlow.IntValue,
		g_iGlowColorPacked,
		g_cvGlowFlash.IntValue,
		g_cvInterval.FloatValue,
		g_cvInvincible.IntValue,
		g_cvBlockControl.IntValue,
		sReviveTimes,
		g_cvMaxCount.IntValue);

	// 1.5.0：空闲身体排除（需求1）的生效条件 + 现场读数。
	//   空闲身体 = 有真人主控的 bot 身体（玩家倒地后自己切旁观 / 掉线，身体被引擎托管）。
	//   这些身体的 idle=1，插件不会替它们起身、也不给守护。
	//   现场验证方法：玩家倒地 -> 自己切旁观 -> 这里 idle 应该变 1、且不会出现起身提示；
	//   玩家重新加入接管后 idle 变回 0（身体已经不归插件管，IsFakeClient=0）。
	ReplyToCommand(client, "\x04[BotGuard]\x01 跳过空闲身体: 开关=%d | 当前空闲身体数=%d（idle=1 的身体不参与自动起身/守护/免伤）| 起身保护窗口=%.1fs",
		g_cvSkipIdleBodies.IntValue,
		CountIdleBodies(),
		REVIVE_PROTECT_TIME);

	// 1.3.0：打守护 bot 的提示配置（提示音路径 + 三渠道开关 + 节流）
	// 1.3.1：附上"服务器端文件探测"结果，仅作诊断（0 也可能正常播放）
	ReplyToCommand(client, "\x04[BotGuard]\x01 拦截提示: 开关=%d 节流=%.1fs 音效=%s (服务器端探测=%d) | 渠道 聊天=%d 屏幕=%d HUD=%d",
		g_cvWarn.IntValue,
		g_cvWarnCooldown.FloatValue,
		(g_sWarnSound[0] != '\0') ? g_sWarnSound : "（无）",
		WarnSoundFoundOnServer() ? 1 : 0,
		g_cvWarnChat.IntValue,
		g_cvWarnHint.IntValue,
		g_cvWarnHud.IntValue);

	// 1.3.3：守护中禁止自行使用医疗物品（吃药 / 打针 / 打包）—— 需要 Actions 扩展
	ReplyToCommand(client, "\x04[BotGuard]\x01 物品拦截: 开关=%d 实际生效=%d | Actions 扩展=%d (actionslib) | %s",
		g_cvBlockItems.IntValue,
		(g_cvBlockItems.BoolValue && g_bActionsAvailable) ? 1 : 0,
		g_bActionsAvailable ? 1 : 0,
		g_bActionsAvailable ? "拦截 SurvivorTakePills(吃药/打针) + SurvivorHealSelf(打包)" : "扩展缺失，不拦截（其余功能正常）");

	// 1.2.0：当前守护名单（#client 索引列表）
	char sGuardList[256];
	int iPos = 0;
	int iGuardNameCount = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !g_bGuarded[i])
			continue;

		if (iGuardNameCount > 0)
			iPos += Format(sGuardList[iPos], sizeof(sGuardList) - iPos, ", #%d", i);
		else
			iPos += Format(sGuardList[iPos], sizeof(sGuardList) - iPos, "#%d", i);

		iGuardNameCount++;
	}

	if (iGuardNameCount == 0)
		strcopy(sGuardList, sizeof(sGuardList), "（无）");

	ReplyToCommand(client, "\x04[BotGuard]\x01 倒地人数=%d / 存活生还者=%d（在场未倒地 %d，终点安全屋内已排除 %d）→ 可守护数=%d；存活未接管生还者=%d；当前守护人数=%d 名单: %s",
		g_iDownCount,
		CountAliveSurvivors(),
		CountStandingSurvivors(),
		CountExcludedInEndSaferoom(),
		g_iGuardAllowed,
		g_iAiSurvivors,
		g_iGuardCount,
		sGuardList);

	// 1.3.4：终点安全屋排除的生效条件（排查用）
	ReplyToCommand(client, "\x04[BotGuard]\x01 终点安全屋排除: 开关=%d native可用=%d 本图有终点安全屋=%d（救援关/终局图没有 info_changelevel，自动不排除）",
		g_cvExcludeEndSaferoom.IntValue,
		g_bNtvLastCheckpoint ? 1 : 0,
		g_bHasEndSaferoom ? 1 : 0);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR)
			continue;

		char sName[MAX_NAME_LENGTH];
		GetClientName(i, sName, sizeof(sName));

		// 1.4.0：补 hang / fall 两个挂边状态位，并显示"剩余起身"，不设上限时写文案
		// 1.5.0：不设上限的文案改成"不设上限"（不再写"不限"）
		char sLeft[32];
		if (g_cvReviveTimes.IntValue < 0)
			strcopy(sLeft, sizeof(sLeft), "不设上限");
		else
			IntToString(g_iReviveLeft[i], sLeft, sizeof(sLeft));

		ReplyToCommand(client,
			"\x04[BotGuard]\x01 #%d %s 接管=%d bot=%d alive=%d incap=%d hang=%d fall=%d idle=%d | 实血=%d 虚血=%.1f 总血=%d | 守护=%d(免伤位=%d) 本回合剩余起身=%s | glow type=%d color=%d range=%d rangeMin=%d flash=%d | 属性存在=%d",
			i, sName,
			IsFakeClient(i) ? 0 : 1,
			IsFakeClient(i) ? 1 : 0,
			IsPlayerAlive(i) ? 1 : 0,
			IsIncapacitated(i) ? 1 : 0,
			IsHangingFromLedge(i) ? 1 : 0,
			IsFallingFromLedge(i) ? 1 : 0,
			IsIdleBody(i) ? 1 : 0,
			GetClientHealth(i),
			L4D_GetTempHealth(i),
			GetTotalHealth(i),
			g_bGuarded[i] ? 1 : 0,
			GetEntProp(i, Prop_Data, "m_takedamage", 1),
			sLeft,
			GetEntProp(i, Prop_Send, "m_iGlowType"),
			GetEntProp(i, Prop_Send, "m_glowColorOverride"),
			GetEntProp(i, Prop_Send, "m_nGlowRange"),
			GetEntProp(i, Prop_Send, "m_nGlowRangeMin"),
			GetEntProp(i, Prop_Send, "m_bFlashing", 1),
			g_bGlowProps[i] ? 1 : 0);
	}

	return Plugin_Handled;
}

// sm_botguard_test <#userid|名字> [秒]：不管血量，强制给目标闪轮廓若干秒（默认 30），
// 用来单独验证"发光到底能不能被看见"，不用等血量掉到阈值。
public Action Cmd_TestGlow(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "\x04[BotGuard]\x01 用法: sm_botguard_test <#userid|名字> [秒]");
		return Plugin_Handled;
	}

	char sTarget[64];
	GetCmdArg(1, sTarget, sizeof(sTarget));

	int iTarget = FindTarget(client, sTarget, false, false);

	if (iTarget <= 0)
		return Plugin_Handled;

	float fSeconds = 30.0;

	if (args >= 2)
	{
		char sSeconds[16];
		GetCmdArg(2, sSeconds, sizeof(sSeconds));

		float fValue = StringToFloat(sSeconds);

		if (fValue > 0.0)
			fSeconds = fValue;
	}

	g_fTestGlowUntil[iTarget] = GetGameTime() + fSeconds;

	ReplyToCommand(client, "\x04[BotGuard]\x01 已对 %N 强制开启轮廓 %.1f 秒（颜色=%d，闪烁=%d）",
		iTarget, fSeconds, g_iGlowColorPacked, g_cvGlowFlash.IntValue);

	return Plugin_Handled;
}
