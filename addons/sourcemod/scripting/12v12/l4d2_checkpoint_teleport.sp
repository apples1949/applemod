/**
 * ============================================================================
 *  l4d2_checkpoint_teleport.sp  -  Setpoint / saferoom / rescue auto-teleport
 * ============================================================================
 *  applemod12v12 (12v12 versus) 定制插件
 *
 *  需求：
 *    在「安全屋 / 救援点 / 地图中途集合点」这些区域，剩余存活生还者的指定
 *    百分比到齐后开始倒计时；倒计时结束时把还没到的生还者传送进该区域，
 *    并开启对应的机关（电梯按钮 / 开关等）。
 *    —— 绝不改动安全门（safe room door）的 spawnflags / lock 状态，
 *       救援车人齐与否由游戏自己判定。
 *    —— 1.2.1 起唯一的例外说明：过关判定本身在引擎里，安全门必须处于「已开启」
 *       状态，引擎才会走「全员进屋 -> 关门 -> 换图」这条链。所以倒计时传送把
 *       人送进关底安全屋之后，如果门是完全关闭的，就对该门发一次标准 Open
 *       输入（等价于玩家自己开门）。仍然不改 spawnflags / lock，不解锁、不锁门，
 *       也不做任何硬换图。可用 l4d2_cptele_saferoom_opendoor 0 关闭。
 *
 *  两类区域：倒计时、到齐比例、提示文案互相独立。 ---------------------------------
 *    A) 安全屋 + 救援点：l4d2_cptele_time              （默认 60 秒）
 *                        l4d2_cptele_percent           （默认 50%）
 *                        —— 1.2.6 起默认 50%（原 66%），12v12 的 cfg 也显式下发 50
 *    B) 地图中途集合点：l4d2_cptele_checkpoint_time    （默认 30 秒）
 *                        l4d2_cptele_checkpoint_percent（默认 50%）
 *
 *  集合点区域来源（按优先级；命中高优先级就不再往下一层找中途集合点）： --------
 *    1) 预设地图配置   addons/sourcemod/configs/l4d2_cptele_presets.cfg
 *                      （KeyValues，按地图预置：targetname 实体 / 坐标+半径 /
 *                        固定传送点）。命中本图即以预设为准。
 *    2) 原版按地点检测 配置表（configs/l4d2_cptele_legacy.cfg，1.3.1 起从
 *       代码里的 GetLegacySite 搬进 cfg），数据搬自 alasfourom
 *                      "L4D Elevator Teleport" 的「地图 → 机关实体 + 传送点」，
 *                      只在预设没有命中本图时才启用。
 *    3) 运行时自动侦测 安全屋 info_changelevel（退回 trigger_changelevel）、
 *                      救援关 m_iEntireTeam == 2 的 trigger_multiple、
 *                      玩家按下「锁住的」func_button 时登记该按钮
 *                      （监听 func_button 的 OnUseLocked 输出）。
 *
 *    安全屋 / 救援点区域始终由第 3 层自动侦测提供（这两类全图通用），
 *    预设文件也可以显式指定 saferoom / rescue 类型的区域。
 *    第 1、2 层一旦提供中途集合点，动态按钮登记会被忽略，避免同一张图上
 *    出现两个互相竞争的集合点。l4d2_cptele_verbose 1 时控制台会打印
 *    每个区域最终走的哪条路径（预设 / 原版地点 / 自动侦测）与回落原因。
 *    排错命令：sm_cptele 查看每个区域的「类型 / 来源 / 已到达人数」，
 *              sm_cptele_reload 重读预设文件并立即重新侦测。
 *
 *  「是否已到达」判定：
 *    - 安全屋 / 救援点 / trigger 类区域：L4D_IsTouchingTrigger(区域实体, client)
 *      （left4dhooks 内部就是 CBaseTrigger::IsTouching，与
 *        L4D_IsInLastCheckpoint 用的是同一条路径）
 *    - 按钮 / 坐标类集合点：玩家到区域中心的三维距离 <= 半径
 *      （半径 = 预设里的 radius；未写时用 l4d2_cptele_mech_radius）
 *
 *  传送目标点（优先级从高到低）：
 *    1) 预设 / 原版内置表给的固定传送点（dest）
 *    2) 已经站在区域内的存活生还者位置（一定可以站立）
 *    3) 区域实体 / 区域中心，用 L4D_GetNearestNavArea +
 *       L4D_FindRandomSpot 取该 nav area 上的随机点
 *    4) 都失败则退化为区域原点本身
 *    传送后统一调用 L4D_WarpToValidPositionIfStuck 兜底。全程不触碰安全门。
 *
 *  状态机：
 *    round_start(延时 3s) -> 侦测区域（预设 -> 原版地点 -> 自动侦测）
 *      -> 1s/次 监控 timer -> 某区域到达人数 >= ceil(该类型比例% × 存活生还者数)
 *      -> 开始该类型的倒计时 -> 倒计时结束 -> 传送未到者 + 开机关
 *      -> 该区域标记为已触发
 *      -> [仅关底安全屋] 传送落位 0.2s 后复核安全门状态，门是完全关闭的
 *         就补发一次标准 Open 输入（1.2.1，见 ScheduleSaferoomDoorFix）
 *    同一区域每回合只会触发一次；换图 / round_start / round_end 全部重置。
 *
 *  1.2.0 修复「集合完就往前走」被传送回来（c5m2 之类机关集合点）：
 *    - 倒计时期间每秒记录「到过集合点」的生还者（g_bSeen）。
 *      倒计时结束时只传送「一次都没到过」的人；已经到过、随后离开继续推进
 *      的生还者不再被传送回来（l4d2_cptele_skip_seen 1，默认）。
 *    - 全员都到过集合点 = 集合完毕：倒计时立刻结束（不再空转到 0），
 *      并且一个人都不传送（只把机关按钮解锁按下）。
 *      → 1.2.9 起「立刻结束」这一半已取消，改为走满倒计时后再结算（见 1.2.9 段）。
 *    旧行为（只按「倒计时结束时是否还在区域内」判定）可用
 *    l4d2_cptele_skip_seen 0 还原。
 *
 *  1.2.1 修复「安全门关着时传送后不过关」（需求 #7）：
 *    - 现象：倒计时结束把人传送进关底安全屋，但安全门当时是「完全关闭」状态时，
 *      人已经在屋里却永远不换图；门是开着的时候同样的传送就能正常过关。
 *    - 根因：过关不是插件判定的，而是引擎 info_changelevel 实体的流程。
 *      datamap 里 info_changelevel 带 CheckpointDoorOpened / CheckpointDoorClosed
 *      两个实体输入（引擎 InfoChangelevel::OnCheckpointDoorClosed 里还会逐个
 *      用 CBaseTrigger::IsTouching 判「谁还在安全屋外面」）。门一直处于关闭
 *      状态 = 门没有任何状态变化 = 这两个输入一次都不会触发，引擎的过关链
 *      没有起点，所以人进屋也不会换图。
 *    - 修复：传送落位 0.2 秒后（等物理/触发体积稳定）复核安全屋里确实有人，
 *      再看门 prop_door_rotating_checkpoint 的 m_eDoorState：
 *      不是 DOOR_STATE_OPENED 就对该门发一次标准 Open 输入，把门恢复到
 *      「玩家开门进屋」这个引擎认识的正常状态，后续关门 + 换图交回引擎。
 *      只发 Open，不动 spawnflags / lock / 不解锁不锁门，不调用任何硬换图。
 *    - 相关开关：l4d2_cptele_saferoom_opendoor（默认 1）。
 *
 *  1.2.2 需求 #7 的第二轮补强 + 安全屋区域选点修复：
 *    - 开门不一定够：正常游戏里过关还要"门再关上"那一下（引擎靠
 *      CheckpointDoorClosed 进来才做 IsTouching 逐人检查，然后 ChangelevelThink 换图）。
 *      倒计时传送没人去关门，所以新增第二层：Open 之后 0.6 秒，若**全部存活生还者**
 *      都在安全屋体积内，就把门物理关回去，并补发一次 CheckpointDoorClosed。
 *      少一个人都不发（伪造事件没用，还会误导排查）。
 *      开关：l4d2_cptele_saferoom_forcedoor（默认 1）。
 *    - 安全屋区域原来取"第一个 changelevel"，实测官方图 10 张有 2 个候选、其中 7 张图
 *      第一个是"往回走"那个（spawnflags=2，map 指向上一张图/本图/空），会让区域指到
 *      开局安全屋（开局全员在屋里 -> 立刻算集合完毕 -> 关底传送静默失效）。
 *      现在按 spawnflags & 2 剔回退项 -> m_mapName 指向下一张图 -> nav 最后检查点 ->
 *      最后一个安全门 的顺序判定（见 FindLastChangelevel）。
 *
 *  1.2.3 需求 #7 第三轮修复：两个仍会漏的洞 + 改成状态机 -----------------------
 *    - 用户回报的两种残留现象：
 *        A) 「传送到安全屋后，如果门开着，不会关」
 *        B) 「关着门，可能不会结算」
 *    - A 的根因：1.2.2 的 Timer_SaferoomDoorFix 在门已经是 DOOR_STATE_OPENED 时
 *      直接 return —— 它只考虑"门关着要开"，从来没考虑"门开着要关"。而引擎的过关链
 *      需要的是「Opened + Closed」两次状态变化，门本来就开着时只缺 Closed，
 *      于是永远没人去关，人齐也不会换图。
 *    - B 的根因：1.2.2 的补发关门是 0.2s 后的一次性 0.6s timer，且要求那一瞬间
 *      「全部存活生还者都在安全屋体积内」才发。12v12 有 12 个人挤一个体积，
 *      只要有人被挤出触发体积（引擎挤压/地形很容易做到），这一次就永久放弃，
 *      再也没有第二次机会。
 *    - 修复：把两个一次性 timer 换成一个 0.25s 轮询的状态机（SAFEROOM_SETTLE_TICK），
 *      按「等门开到位 -> 等全员进体积（不够就补传，可重试）-> 关门 -> 等门关到位 ->
 *      补发 CheckpointDoorClosed」推进；每步幂等、有重试上限、有 10 秒超时兜底；
 *      门本来就开着时记成"已开启"后**继续往下走**，不再提前退出。
 *      FinishCountdownAllSeen（人齐、倒计时提前结束）这条路径原来完全不碰门，
 *      现在也接入状态机 —— B 现象有一大半是从这里来的。
 *      仍然只发标准 Open/Close/Teleport 输入，不改 spawnflags / lock，不硬换图。
 *    - 新增开关沿用原有的 l4d2_cptele_saferoom_opendoor / l4d2_cptele_saferoom_forcedoor：
 *      opendoor=0 时完全不动门（连状态机都不启动），兼容"不想让插件碰门"的用法。
 *
 *  1.2.5 修复「安全屋倒计时被提前判定为全员已进入，掉队者留在外面，最后还得
 *        玩家自己再开关一次门才过关」（2026-10-30）：
 *    - 根因一：提前结束判定用的是"本次倒计时期间到过区域内"（g_bSeen）。
 *      安全屋/救援点里，玩家进过又跑出去（拿补给、捡枪）也算"到过"，
 *      于是全员瞬间都算到过 -> FinishCountdownAllSeen -> 一个人都不传送。
 *      现在安全屋/救援点改成"此刻全员都在区域内"(CountArrivedSurvivors) 才算集合完毕；
 *      中途集合点仍是"到过就算"（1.2.0 的 c5m2 修复不受影响）。
 *    - 根因二：倒计时真正到点时的传送会跳过 g_bSeen 的人。安全屋类型下，
 *      "到过又出去"的掉队者因此永远留在门外；随后补门状态机因为
 *      「不是全员在屋内」不肯关门，引擎的 CheckpointDoorClosed 也就没来过，
 *      表现为"最后还得自己开关一次门"。现在安全屋类型不再跳过这类人，一律传送进屋。
 *
 *  1.2.6 12v12 微调（2026-11-09）：
 *    - 安全屋 / 救援点到齐比例默认值 l4d2_cptele_percent：66% -> 50%。
 *      中途集合点的 l4d2_cptele_checkpoint_percent 本来就是 50%，未改动。
 *      模式配置 cfg/cfgogl/applemod12v12/applemod12v12.cfg 同步改成 50（两条路径一致）。
 *
 *  1.2.7 需求「有玩家进入集合区域时，向所有玩家提示可触发传送」（2026-11-11）：
 *    - Timer_Monitor 里新增「进入跳变侦测」（UpdateEnterNotices）：
 *      逐区域 × 逐玩家记录上一 tick 是否在区域内，只在「不在 -> 在」这一次
 *      跳变时播报，绝不每 tick 刷屏；同一玩家同一次进入只播一次。
 *    - 播报内容严格按用户给定格式（两个通道同文案）：
 *        \x05[集合点]\x01 %d/%d 名生还者已进入%s（需要 %d 名触发传送）
 *      参数 = 已进入人数 / 当前存活生还者数 / 区域名（安全屋·救援点·集合点）/
 *             触发所需人数（AreaRequiredCount，与倒计时判定同一口径）。
 *    - 通道：聊天框 PrintToChatAll（受 l4d2_cptele_chat 控制）+
 *            屏幕下方居中 PrintHintTextToAll（沿用本插件既有 HUD 通道）。
 *      新开关 l4d2_cptele_enter_notice（默认 1）。
 *    - StartCountdown 里原来那条「%d/%d 名生还者已进入…，N 秒后…」的长句
 *      按用户要求拆成两条：第一条是上面那个严格格式，第二条只留倒计时信息。
 *    - 边界：逃离阶段 / 救援车未到位 / 区域已触发或实体消失时不播报，
 *      但仍静默记录在场状态（区域恢复可用时不会「集体进入」）；
 *      换图 / round_start / round_end / 玩家断线都会清状态。
 *
 *  1.2.8 修复「触发过一次传送之后，再走进集合区域就再也不提示了」（需求 #7 续）：
 *    - 现象：倒计时结束、把掉队者传送进区域之后，本回合剩下的时间里任何玩家
 *      再进入该区域都没有任何进入提示（但「全员已进入 / 提前集合完毕」那条还在）。
 *    - 根因：1.2.7 的 UpdateEnterNotices 把 g_bAreaFired 写进了静默条件：
 *        bool bQuiet = g_bAreaFired[i] || !IsAreaAlive(i);
 *      而 g_bAreaFired 只在 FinishCountdown（传送完毕）/ FinishCountdownAllSeen
 *      （提前集合完毕）里被置 true，之后只有换回合 / 换图（ResetRound）或
 *      重新登记区域（AddArea）才会清 —— 于是「触发过一次 = 本回合永不再提示」，
 *      这正是用户报的现象。
 *    - 修复：静默条件只保留「区域实体已经消失」（!IsAreaAlive(i)），
 *      已触发过的区域照常播报进入提示；进入侦测本身仍是「不在 -> 在」跳变播报，
 *      频率不变（同一玩家同一次进入仍只播一次，抖动仍由 ENTER_NOTICE_REPEAT 抑制）。
 *    - 同时补一个不刷屏的细节：插件自己把人传送进区域的那一次（FinishCountdown
 *      的主传送、安全屋结算状态机 SettleGatherSurvivors 的补传）不算「玩家走进来」，
 *      由 SuppressEnterNoticeForTeleport 预先登记成已在区域内，不会紧接着多播一条
 *      「N/N 名生还者已进入…」。玩家自己走进来照常播报。
 *    - 「提前集合完毕」那条提示（FinishCountdownAllSeen 的
 *      「全员已进入%s，倒计时提前结束，无人需要传送」/「全员已到达集合点…」）
 *      完全未改动。
 *      → 1.2.9 起这条提示只在倒计时**自然走满**后出现（不再有「提前结束」），
 *        文案同步改成「倒计时结束，全员已进入%s，无需传送」（见 1.2.9 段）。
 *
 *  1.2.9 需求「倒计时期间不刷进入提示 / 集合完成又离开要继续倒计时」（2026-11-18）：
 *    - 需求一、倒计时期间不显示「生还者进入集合点 / 安全屋」的提示。
 *      · 现象：一触发传送倒计时，每有一个生还者走进区域就全服播一条
 *        「N/M 名生还者已进入…」（聊天框 + 屏幕下方两条通道各来一条），
 *        和每秒的倒计时提示混在一起，屏幕上一直是重复的同一句话。
 *      · 根因：1.2.7 的 UpdateEnterNotices 由 Timer_Monitor 每秒无条件调用，
 *        而且调用点放在「倒计时期间直接 return」之前 —— 倒计时跑着的时候，
 *        「不在 -> 在」的跳变照播不误。1.2.8 放开 g_bAreaFired 这个静默条件之后
 *        更明显（触发过的区域也照播）。
 *      · 做法：UpdateEnterNotices 里把 g_bCountingDown 并入静默条件（聊天框与
 *        PrintHintTextToAll 两条通道都不发），但**仍然每秒更新 g_bAreaPresence**
 *        ——「静默但不丢状态」：如果连状态更新一起跳过，倒计时一结束就会把整段
 *        倒计时里走进来的人当成同一 tick 的集体进入，反而一次性刷屏。
 *        Timer_Monitor 的调用点同时挪到「倒计时判定」之后：触发倒计时的同一 tick
 *        就已经是静默的，那条「N/M 名生还者已进入…」交给 StartCountdown 的首播
 *        给出（文案完全相同），同一秒不会出现两条一模一样的话。
 *        倒计时结束（FinishCountdown）/ 取消（CancelCountdown）时再调
 *        SyncEnterNoticePresence，按此刻真实在场情况同步一次，跨过结束边界的
 *        那一次进入也不会补播；此后玩家再走进来照常播报（恢复不受影响）。
 *    - 需求二、提前集合完成不再结束倒计时，「集合了一下又离开」要接着走。
 *      · 现象：倒计时还没走完，全员在集合点 / 安全屋集合了一下又散开去补给，
 *        倒计时立刻结束、区域被标记成「已触发」；掉队者再也不会被传送，
 *        关底安全屋凑不齐人，最后还得玩家自己开关一次门才过关。
 *      · 根因：1.2.0（中途集合点「到过就算」）/ 1.2.5（安全屋「此刻全员在屋内」）
 *        都在 Timer_Countdown 里判「全员到齐」就调 FinishCountdownAllSeen
 *        提前结束倒计时，并顺手把 g_bAreaFired 置 true —— 该区域本回合唯一的一次
 *        倒计时机会，被这次「集合了一下又走」用掉了。
 *      · 做法：删掉 Timer_Countdown 里这条提前结束分支，倒计时一律走满。
 *        到点时仍由 FinishCountdown 按那一刻的真实情况结算：
 *        g_cvSkipSeen 对中途集合点「到过就不再被传送回来」的语义不变；
 *        安全屋 / 救援点仍然只按「此刻必须在屋里」把掉队者传进来（1.2.5 不变）；
 *        全员都在区域内时 moved == 0，照常走「全员已进入%s，无需传送」。
 *        FinishCountdownAllSeen 保留下来换了个身份：不再是「结束器」，
 *        只作为 FinishCountdown 在「无人需要传送」时的播报收尾（文案不变），
 *        既保住「全员已到齐」这条信息，也不会留下未使用函数的 warning 203。
 *        l4d2_cptele_skip_seen 的 cvar 描述同步改掉「立即结束」那半句。
 *
 *  1.3.0 需求「c5m2 中途集合点全员集合完毕后倒计时还在跑」（2026-11-19）：
 *    - 现象：c5m2 中间的集合点上，所有生还者都到过集合点、机关也已经被玩家
 *      自己触发之后，屏幕上的「N 秒后传送未到集合点的生还者」还在继续走；
 *      倒计时走满时因为全员都到过（g_cvSkipSeen）一个人都不传送，
 *      只播一条「全员已到达集合点，无需传送」——倒计时等于空转。
 *    - 根因：1.2.9「需求二」为了让「集合一下又散开去补给」还能继续倒计时，
 *      把 Timer_Countdown 里「全员到齐就提前结束」的分支整条删掉了，
 *      倒计时一律走满。于是「集合完毕」这件事只能在倒计时自然结束时才被承认。
 *    - 做法（**只作用于中途集合点 AREA_CHECKPOINT**，安全屋 / 救援点仍是 1.2.9
 *      的「走满再结算」，1.2.5 / 1.2.9 的语义一个字都没动）：
 *      Timer_Countdown 每秒判一次 IsCheckpointGatherComplete()：
 *        本次倒计时期间「所有当前存活的生还者都已经到过该集合点」
 *        （CountSeenSurvivors() >= CountAliveSurvivors()）就算集合完毕，
 *        立刻走 FinishCheckpointGathered()：结束倒计时、把区域标记成本回合已触发、
 *        照常开机关（电梯按钮之类）、播报「全员已集合完毕，传送倒计时结束」。
 *      判定与 g_cvSkipSeen 绑定：只有「到过就不再被传送回来」这一语义生效时，
 *      「全员到过」才等于「没人需要传送」，否则提前结束会把到过又离开的人漏掉。
 *      新开关 l4d2_cptele_checkpoint_finish_all_seen（默认 1）；设 0 = 回到 1.2.9
 *      的「集合完毕也把倒计时走满」，安全屋 / 救援点始终不受本开关影响。
 *    - 边界：区域已触发（g_bAreaFired）后 monitor 不会再起倒计时，不会出现
 *      「提前结束 -> 下一秒重新开始」的循环；全员集合完毕时 moved 必然为 0，
 *      不传送任何人，也不会触发安全屋关门状态机。
 *
 *  1.3.1 修复「c4m2 电梯上人齐 / 按按钮都不触发传送倒计时」+ 原版地点表搬进 cfg
 *        （2026-11-23）：
 *    - 现象（用户回报）：c4m2_sugarmill_a 甘蔗田尽头那台货运电梯，无论按按钮
 *      还是全员到齐，屏幕都不出「N 秒后传送未到集合点的生还者」，电梯机关也不会
 *      被插件打开。
 *    - 根因一（数据选错实体）：内置表给 c4m2 的集合点是车厢里的
 *      button_inelevator。实测 c4m2_sugarmill_a.bsp 的实体块：
 *        · button_inelevator  func_button  parentname=elevator  origin z≈170
 *          （车厢开局停在井底 z=154，top=634），并且 OnPressed 里有 "!self Kill"
 *          自删；
 *        · 上面那层（z≈660）真正的集合按钮是 button_callelevator（无父级，
 *          OnPressed → elevator Movetofloor top，即「把车厢叫上来」）。
 *      生还者到达的是顶层，插件盯的却是井底车厢里的按钮。
 *    - 根因二（父实体坐标不世界化，**这条是主因，影响 5 张图**）：
 *      父实体（parentname）下的 m_vecOrigin 是相对父级的局部坐标——引擎
 *      SetParent 时已经把父实体的原点/角度减掉了。GetEntityCenter() 以前直接
 *      把 m_vecOrigin 当世界坐标 + (mins+maxs)/2，于是这些条目的区域中心全部
 *      塌到「局部坐标」（≈ 地图原点附近，几个单位），生还者站在电梯上离那个
 *      幻影中心还有几千 HU，CountArrivedSurvivors() 恒为 0，
 *      Timer_Monitor 永远达不到 ceil(50% × 存活) 的到齐人数 → 倒计时永不触发。
 *      受影响的条目（都是父实体的子按钮）：c1m1_hotel elevator_button
 *      （parent elevator_1）、c1m4_atrium button_elev_3rdfloor（parent elevator）、
 *      c3m1_plankcountry ferry_tram_button（parent ferry_tram）、
 *      c4m2/c4m3 button_inelevator（parent elevator）。唯一没出问题的是
 *      c5m2_park 的 trigger_multiple（走 L4D_IsTouchingTrigger，与坐标无关），
 *      这也解释了此前所有修复反馈为什么都集中在 c5m2。
 *    - 做法：
 *      ① GetEntityWorldOrigin()：沿 m_pParent 链逐级还原世界坐标（每级的局部
 *         偏移先按该父实体的角度旋转），层数上限 8 层防循环父级；
 *         GetEntityCenter() 改用它，所有读实体的判定（距离 / nav 落点）一起修好。
 *      ② GetAreaCenter()：半径类区域的判定中心改成**每次实时算**——电梯/渡轮
 *         一动，快照坐标立刻过期；纯坐标区域仍用预设给的坐标，实体消失时退回快照。
 *         IsClientInArea() / GetAreaDestination() / sm_cptele 全部改走它。
 *      ③ 数据修正：c4m2 的集合实体改成顶层 button_callelevator（radius 700），
 *         c4m3 保留车厢按钮（那一关生还者本来就在井下，按它才上行）。
 *      ④ 顺手把判定中心打进 sm_cptele 输出，再遇到同类问题一眼能看出是
 *         「中心塌到 0」还是「实体找不到」。
 *    - 原版地点表搬进 cfg（用户要求）：删掉 GetLegacySite() 的硬编码表，
 *      改成读 configs/l4d2_cptele_legacy.cfg（新 ConVar
 *      l4d2_cptele_legacy_file）。键名与 l4d2_cptele_presets.cfg 完全一致，
 *      两张表共用同一个槽位解析器 LoadConfigSlot()（只靠 source 区分
 *      SRC_PRESET / SRC_LEGACY）；文件不存在时静默回落到运行时侦测，
 *      改完 sm_cptele_reload 即时生效，不用重编译。
 *    - 边界：本图预设一旦提供中途集合点，原版地点表整份跳过（与旧行为一致）；
 *      ResetRound / OnMapStart / OnMapEnd / sm_cptele_reload 都会释放并重读两张表；
 *      原版地点表解析失败只写一条 error 日志，不影响安全屋 / 救援点的自动侦测。
 *
 *  1.3.2 需求「c6m3_port 也要能正常集合」+ 救援区忽略名单（2026-11-23）：
 *    - 现象/结论：c6m3_port 不写任何条目时，安全屋层不注册（唯一的
 *      info_changelevel 是 spawnflags=2、map 指向自己的回退项，见
 *      FindLastChangelevel 的注释），中途集合点是空集，只剩救援层；而救援层是
 *      按「trigger_multiple + m_iEntireTeam == 2」整类抓的，这张图有两个这样的
 *      体积：trigger_escape(8 -2832 48) 和 generator_elevator_trigger(-760 -580 344)。
 *      于是终局流程（升罐电梯 → 发电机）之前完全没有倒计时，逃离阶段一开始又要
 *      和「升罐电梯」那个体积抢倒计时，抢到就先把掉队者往起点侧传。
 *    - 做法一（数据）：预设表新增 c6m3_port 的集合点 —— **坐标型**，取升罐电梯
 *      顶层平台（-760 -580 340，radius 700）。刻意不绑 generator_elevator_button：
 *      那个按钮 parentname=generator_elevator、spawnflags=3073 锁住，地图自己的
 *      generator_elevator_trigger 会在全员上台时 Unlock 它；插件绑它就会在倒计时
 *      结束时替玩家 unlock+use，把 12v12 里没到场的一半人留在下面（1.2.4 的老问题）。
 *      命中预设后 g_bSiteAuthority=true，动态按钮登记也一并被抑制。
 *    - 做法二（代码）：新增「救援区忽略名单」。两张配置表都支持保留段
 *      （段名以 '_' 或 '#' 开头一律不登记成集合点），其中
 *        "_ignore" { "rescue" "名字1,名字2" }
 *      会在 DetectAreas 注册 AREA_RESCUE 之前按 targetname（m_iName，大小写
 *      不敏感、逗号/空格/分号分隔）过滤掉整个team触发体积；名单最多 8 条，
 *      随回合清空、随配置重读，verbose 下会打出每个被忽略的实体。
 *    - 边界：忽略名单只作用于救援层，不影响安全屋 / 中途集合点；名单随预设表 /
 *      原版地点表一起读取，那两张表被关掉（l4d2_cptele_preset 0 /
 *      l4d2_cptele_legacy 0）时名单也不生效；超过 8 条只写一条 error 不刷屏。
 *
 *  1.3.3 修复「生还者还没进集合点，集合点机关就被提前触发 / 人被卡在集合点」
 *        （2026-11-23）：
 *    - 现象（用户回报）：人还没到齐，电梯按钮 / 升降台开关这类集合点机关就被
 *      提前打开，导致一大批生还者被卡在集合点。
 *    - 根因一（主因，1.3.0 起就有、被 1.3.1 的坐标修复「解锁」）：提前结束
 *      倒计时的判据是 IsCheckpointGatherComplete() 的
 *      CountSeenSurvivors() >= total ——「本次倒计时期间**都到过**」，不是
 *      「此刻都在里面」。cfg 下发 l4d2_cptele_checkpoint_percent 50
 *      => 6/12 人就起 30 秒倒计时，中途 12 个人先后路过集合点半径就满足了
 *      「都到过」，于是 FinishCheckpointGathered() 立刻调 OpenAreaMechanism()
 *      把按钮按下去 —— 这时往往还有一半人在外面。1.3.0 及以前这些按钮类条目
 *      的区域中心全塌在地图原点（父实体局部坐标 bug），到达人数恒为 0，这条
 *      路径根本走不到，所以「上一版没问题」；1.3.1/1.3.2 把中心修好之后立刻暴露。
 *    - 根因二：FinishCountdown() 的传送按 g_cvSkipSeen 跳过「到过」的人，
 *      紧接着无条件 OpenAreaMechanism()。机关一动作（电梯上行 / 升降台离开），
 *      这些被刻意留在外面的人就再也进不来。
 *    - 根因三：倒计时期间玩家自己抢先按下机关（func_button 的 OnPressed）
 *      插件完全不介入，机关先动、人还在外面；倒计时结束后插件还会再按一次。
 *    - 做法：
 *      ① IsCheckpointGatherComplete() 的判据换成「存活生还者**此刻**都在区域内」；
 *      ② OpenAreaMechanism() 在按按钮之前复核「区域外存活人数」，还有人在外面
 *         就只 unlock 不 use（玩家仍可自己按），并留一条 error 日志；
 *      ③ 传送口径：本区域是「插件按按钮」型机关时，倒计时结束的补传无视
 *         g_cvSkipSeen，先把所有人拉进来再谈开机关（抽成
 *         TeleportStragglersToArea()）；
 *      ④ 玩家抢按：OnPressed 命中当前倒计时区域自己的按钮时，立刻终止倒计时、
 *         把外面的人补传进来、并放弃插件自己那一次按键（
 *         PlayerPressedActiveMechanism()），本回合该区域不再起倒计时。
 *    - 边界：机关只在「比例达标 + 本区域倒计时跑完 + 全员此刻在区域内」后由插件
 *      触发一次；安全屋 / 救援点（非按钮机关）路径完全不变；不改任何 cfg。
 *
 *  1.3.8 修复「c1m1_hotel 人还没走到电梯集合点，倒计时就开始了」（2026-11-26）：
 *    - 现象（用户回报，历史上出现过多次）：Dead Center 1 的电梯集合点，生还者
 *      还在电梯厅外面的走廊/上层平台上捡枪、打架，屏幕上就已经开始
 *      「30 秒后传送未到集合点的生还者」。
 *    - 根因（数据）：c1m1 的中途集合点来自**原版地点表**
 *      （l4d2_cptele_legacy.cfg 的 c1m1_hotel / cp_elevator），槽位只写了
 *      classname + targetname，没写 radius → 判定半径退化成
 *      l4d2_cptele_mech_radius 600。而 elevator_button 是挂在 func_elevator
 *      轿厢上的壁挂面板，1.3.1 的父实体坐标修正算出的世界中心是
 *      (2244.3, 5723.2, 2503.4)（轿厢顶部站位层的西南角）。
 *      600 半径的三维球体不认墙也不认楼层，把下面这些「还没到电梯」的位置全
 *      圈了进来（数值由 BSP 实体与 applemod12v12 的 stripper 配置反查）：
 *        (1920,5394,2475) 电梯前房间的武器位  → 463 HU
 *        (2155,5367,2487) 电梯前房间的枪位    → 368 HU
 *        (2357,5644,2630) 电梯井旁上层窗台    → 188 HU
 *      12 人局 l4d2_cptele_checkpoint_percent 50 => 只要 6 人在这片区域里
 *      （捡枪/等电梯时的常态），倒计时就起；接着 1.3.4 的
 *      l4d2_cptele_checkpoint_teleport_all 会把整队拉进轿厢并按按钮，
 *      电梯提前下行 —— 玩家感受到的就是「还没走到就开始了」。
 *    - 已排除的方向（逐条核实过，不是本次根因）：
 *      · OnUseLocked 动态登记：c1m1 由原版地点表提供集合点 => g_bSiteAuthority
 *        为真 => RegisterMechanism 直接 return，动态登记根本没发生；
 *        而且 elevator_button 的解锁来自地图自己的 *27 entireteam 触发体积，
 *        玩家在别处按不动它。
 *      · 区域中心塌到原点：1.3.1 已修好父实体世界坐标，本图中心就是轿厢面板
 *        （不是 0,0,0）。
 *      · 安全屋/救援点误登记：c1m1 只有一个 info_changelevel，是底面真正的
 *        关底安全屋 (1840..2288, 4288..4656, z 1184..1312)；救援区只在终局图登记。
 *      · 人数口径：need = ceil(50% × 当前存活生还者数)，12 人 = 6 人，代码正确；
 *        它只是把上面那个过大的判定球放大成「6 人就够」。
 *    - 做法一（数据，主修）：预设表与原版地点表里的 c1m1_hotel 都改成
 *      **轿厢精确方框**：square = 轿厢 brush *41 的世界脚印
 *      (2064..2272, 5713..5912) 四周各放 4 HU + zmin/zmax 2450/2600（等于顶层的轿厢站位层）。
 *      只有真正站进轿厢的人才算「已到达」，电梯厅外面的走廊、上层窗台都不再计数。
 *      dest 沿用原条目 2171 5810 2529（轿车内地板）。
 *    - 做法二（代码，通用兜底）：新增 l4d2_cptele_checkpoint_core_radius（默认 200）：
 *      **半径判定**的中途集合点起倒计时前，必须至少有 1 名存活生还者在这个
 *      「核心半径」内（真的贴着机关），否则本 tick 不起倒计时。方框 / 触发体积
 *      类区域本来就是精确体积，不受影响。0 = 关闭该门槛（回到 1.3.7 行为）。
 *      这样别的图（c1m4 / c3m1 / c8m4 这类只有按钮、没写方框的条目）也不会
 *      再被「隔着一堵墙的房间里的 6 个人」触发。
 *    - 边界：c1m1 的轿厢会下行到 z≈1216，方框固定在上层站位层，电梯开走后区域
 *      自然变空（本回合已触发，不会再起倒计时）；pause_when_empty 不变。
 *
 *  API 运行期依赖：left4dhooks 的若干 native 在 include 里是
 *  MarkNativeAsOptional，因此 OnAllPluginsLoaded 里用 GetFeatureStatus
 *  逐个复核，关键 native 缺失时自动关掉功能并写日志，而不是崩服。
 * ============================================================================
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#define PLUGIN_VERSION      "1.3.8"

#define SOUND_COUNTDOWN     "buttons/blip1.wav"

#define TEAM_SURVIVOR       2
#define TEAM_INFECTED       3

#define MAX_AREAS           32          // 一张图最多同时监控的区域数
#define MONITOR_INTERVAL    1.0         // 区域监控间隔（秒）
// 1.2.7：同一玩家短时间内反复进出同一区域（站在触发体积 / 半径边界上来回抖）
// 只播报第一次，避免聊天框刷屏。秒。
#define ENTER_NOTICE_REPEAT 3.0
#define INIT_DELAY          3.0         // round_start 后延迟多久侦测实体
#define CANCEL_COOLDOWN     10.0        // 倒计时被取消后，该区域的冷静期
#define INFECTED_CLEAR_RADIUS 300.0     // 清理传送点周围特感的半径
#define DEST_JITTER         32.0        // 固定传送点附近的散开抖动（HU）
#define ANCHOR_MAX_DIST     160.0       // 半径类区域：只有离中心这么近的队友才算"已经在集合点"，可当传送锚点

#define PRESET_DEFAULT_FILE "l4d2_cptele_presets.cfg"   // 预设文件名（相对 configs/）
#define LEGACY_DEFAULT_FILE "l4d2_cptele_legacy.cfg"    // 原版地点表文件名（相对 configs/，1.3.1 起从代码搬到 cfg）

// 安全门修复：传送落位后等多久再去检查 / 动门（等一帧以上，让 TeleportEntity
// 与 L4D_WarpToValidPositionIfStuck 的落点、以及引擎的触发体积 touching 状态稳定）
#define SAFEROOM_DOOR_DELAY     0.2

// ↑1.2.3 起 SAFEROOM_DOOR_DELAY 已不再被使用（原来那个 0.2s 一次性复核被状态机取代）。
//   保留定义只是为了不删历史注释里的引用；新逻辑请用下面的 SAFEROOM_SETTLE_*。

// 1.2.3：安全屋「结算」改成一个轮询状态机（见 Timer_SaferoomDoorFix 的注释）。
// 原来的两个一次性 timer（0.2s 复核 + 0.6s 补发）有两个覆盖不到的漏洞：
//   ① 门本来就开着 -> Timer_SaferoomDoorFix 直接 return，永远没人去关门，
//      引擎等的那次「门关闭」事件一次都不会来（用户报的「开着门不会关」）；
//   ② 0.6s 太短：门还在开的过程中收到 Close 会被引擎忽略；而且 12v12 有 12 个
//      生还者，只要有一瞬间有 1 个人被挤出安全屋体积，就永远发不出关闭事件
//      （用户报的「关着门可能不会结算」）。
#define SAFEROOM_SETTLE_TICK        0.25    // 状态机轮询间隔（秒）
#define SAFEROOM_SETTLE_TIMEOUT     10.0    // 状态机总超时（秒），超时留日志收尾，不会无限跑
#define SAFEROOM_SETTLE_RETRY_MAX   3       // 掉队者最多补传几次（12 人挤一个体积必然有人被挤出）
#define SAFEROOM_SETTLE_RETRY_DELAY 1.0     // 第 N 次补传最早在第 N*该值 秒之后（给物理/挤压留时间）

// 安全门修复：门到 info_changelevel 体积中心的最大距离（HU）。
// 与 left4dhooks 里 L4D_GetCheckpointLast 判断「末尾那道门」用的是同一个量级
// （DOOR_RANGE_TOLLERANCE = 2000）。超过这个距离说明找到的门不是这间安全屋的，
// 宁可不开门也不能误开别处的门（例如起点安全屋的门）。
#define SAFEROOM_DOOR_MAX_DIST  2000.0

// 配置槽位解析结果：LoadConfigSlot 的返回值（预设表与原版地点表共用）
#define PRESET_SLOT_NONE        0       // 未登记（配置写错 / 实体找不到 / 区域已满）
#define PRESET_SLOT_OTHER       1       // 登记了安全屋 / 救援点
#define PRESET_SLOT_CHECKPOINT  2       // 登记了中途集合点

// ---------------------------------------------------------------------------
// 区域类型：决定用哪一组 cvar 与哪一套提示文案
// ---------------------------------------------------------------------------
enum
{
	AREA_SAFEROOM = 0,      // 关底安全屋（info_changelevel / trigger_changelevel）
	AREA_RESCUE,            // 救援点（终局救援车 / 救援关触发器）
	AREA_CHECKPOINT         // 地图中途集合点（预设点 / 原版地点 / 机关按钮）
};

// ---------------------------------------------------------------------------
// 区域来源：只影响日志与 sm_cptele 的显示，说明走了哪条检测路径
// ---------------------------------------------------------------------------
enum
{
	SRC_AUTO = 0,           // 运行时自动侦测
	SRC_LEGACY,             // 原版按地点检测（配置表）
	SRC_PRESET              // 预设地图配置
};

// ---------------------------------------------------------------------------
// ConVar
// ---------------------------------------------------------------------------
ConVar g_cvEnable;
ConVar g_cvPercent;             // 安全屋 / 救援点 到齐比例
ConVar g_cvTime;                // 安全屋 / 救援点 倒计时
ConVar g_cvCpPercent;           // 中途集合点 到齐比例
ConVar g_cvCpTime;              // 中途集合点 倒计时
ConVar g_cvCpFinishAllSeen;     // 1.3.0：中途集合点全员到过即结束倒计时
ConVar g_cvCpTeleportAll;       // 1.3.4：中途集合点倒计时结束时把全员传送到位
ConVar g_cvPauseWhenEmpty;      // 1.3.6：集合点里没人时暂停倒计时
ConVar g_cvCpCoreRadius;        // 1.3.8：半径类集合点起倒计时前，至少 1 人必须在这个核心半径内
ConVar g_cvResetOnLeave;
ConVar g_cvSkipSeen;
ConVar g_cvSound;
ConVar g_cvChat;
ConVar g_cvEnterNotice;         // 1.2.7：有人首次进入集合区域时向全服提示
ConVar g_cvSaferoom;
ConVar g_cvSaferoomDoor;        // 关底安全门关闭时，传送后发 Open 让引擎能过关（1.2.1）
ConVar g_cvSaferoomForceDoor;   // 门开不了/开过之后仍不过关时，补发一次 CheckpointDoorClosed（1.2.2）
ConVar g_cvRescue;
ConVar g_cvMechanism;
ConVar g_cvMechanismUnlocked;
ConVar g_cvMechRadius;
ConVar g_cvPreset;              // 预设地图检测
ConVar g_cvPresetFile;
ConVar g_cvLegacy;              // 原版按地点检测（配置表）
ConVar g_cvLegacyFile;
ConVar g_cvRevive;
ConVar g_cvReleaseSi;
ConVar g_cvRemoveInfected;
ConVar g_cvRescueForce;
ConVar g_cvVerbose;

// ---------------------------------------------------------------------------
// 区域数据（用 EntRef 保存，跨帧/跨回调安全）
// ---------------------------------------------------------------------------
int   g_iAreaRef[MAX_AREAS];        // 0 = 纯坐标区域（无实体）
int   g_iAreaType[MAX_AREAS];       // AREA_*
int   g_iAreaSource[MAX_AREAS];     // SRC_*
bool  g_bAreaFired[MAX_AREAS];
bool  g_bAreaCoord[MAX_AREAS];      // 纯坐标区域，不依赖实体
bool  g_bAreaRadius[MAX_AREAS];     // 用距离判定（否则用 L4D_IsTouchingTrigger）
float g_vAreaPos[MAX_AREAS][3];     // 距离判定的中心点
float g_fAreaRadius[MAX_AREAS];     // 距离判定的半径（<=0 用 l4d2_cptele_mech_radius）
bool  g_bAreaBox[MAX_AREAS];        // 1.3.7：用 2D 方框判定（square 写法），优先于半径
float g_vAreaBox[MAX_AREAS][4];     // xmin, xmax, ymin, ymax
float g_fAreaZMin[MAX_AREAS];       // 方框模式的 z 下限（可选）
float g_fAreaZMax[MAX_AREAS];       // 方框模式的 z 上限（可选）
bool  g_bAreaDest[MAX_AREAS];       // 是否带固定传送点
float g_vAreaDest[MAX_AREAS][3];    // 固定传送点
float g_fAreaCooldown[MAX_AREAS];
int   g_iAreaCount;

// ---------------------------------------------------------------------------
// 预设地图配置（每张图读一次，换图释放）
// ---------------------------------------------------------------------------
KeyValues g_hPresets;
bool      g_bPresetsTried;

// ---------------------------------------------------------------------------
// 原版地点表（1.3.1 起从 GetLegacySite 的硬编码搬到 configs/l4d2_cptele_legacy.cfg）
// ---------------------------------------------------------------------------
KeyValues g_hLegacy;
bool      g_bLegacyTried;

// ---------------------------------------------------------------------------
// 倒计时 / 监控状态
// ---------------------------------------------------------------------------
Handle g_hMonitor;              // 1s 重复监控 timer
Handle g_hCountdown;            // 1s 重复倒计时 timer
bool   g_bCountingDown;
int    g_iSecondsLeft;
int    g_iActiveArea = -1;

// 1.2.1 安全门复核的挂起状态。一张图最多一个关底安全屋区域，同一时刻也只会
// 有一个倒计时在跑，所以用单槽即可；换图 / 换回合由 ResetRound 统一清掉。
Handle g_hDoorFix;              // 安全屋结算状态机的轮询 timer（1.2.4 起是「一次性 timer 逐 tick 续命」）
int    g_iDoorFixArea = -1;     // 挂起中的区域索引（-1 = 没有挂起）
int    g_iDoorFixRef;           // 挂起中区域实体的 EntRef（防跨回合残影）

// 1.2.4：状态机 timer 的「世代号」，用来根治运行期这条报错：
//   [SM] Invalid timer handle <h> (error 1) during timer end, displayed function is
//        timer callback ... Unable to call function "Timer_SaferoomDoorFix"
// 根因是同一个 timer handle 被**关闭两次**，具体两条路径：
//   ① 这个重复 timer 原来带 TIMER_FLAG_NO_MAPCHANGE —— 换图时引擎会**自动关闭**它，
//      而 ResetRound() 又在 OnMapEnd/OnMapStart 里 delete 一次，第二次关闭作用在
//      已经失效的 handle 上，正是 "Invalid timer handle" 的来源；
//   ② SourceMod 的 handle 值会被复用，对着一个已失效的旧 handle 做 delete，
//      有可能顺手关掉**旁边刚新建的那个 timer**（更危险，会让别的 timer 静默消失）。
// 做法：状态机改成「一次性 timer 每 tick 自己续命」，不再用 TIMER_REPEAT，
// 也**不再带 TIMER_FLAG_NO_MAPCHANGE**（生命周期完全由我们显式管）；
// 每次启动/收尾都让世代号 +1，回调只认自己那一代，过期的直接退出且绝不碰 handle。
// 这样引擎不会背着我们关 timer，我们自己的 delete 也永远只作用在有效 handle 上。
int    g_iSettleGen;

// 1.2.3 安全屋结算状态机的进度（原 1.2.2 的两个一次性 timer 已被它取代）
float  g_fSettleDeadline;       // 绝对超时时刻（GetGameTime 口径）
int    g_iSettleRetry;          // 已经补传掉队生还者的次数
float  g_fSettleNextRetry;      // 下次允许补传的时刻
int    g_iSettleOpenTries;      // 已经发过几次 Open（门被锁时用来止损，不无限重发）
float  g_fSettleNextOpenTry;    // 下次允许重发 Open 的时刻（给引擎 think 留时间，避免每 tick 判死）
bool   g_bSettleDoorOpened;     // 门已经历过「开启」（本来就开着也算）
bool   g_bSettleDoorClosed;     // 已经对该门发过 Close
bool   g_bSettleEventFired;     // 已经向 info_changelevel 发过 CheckpointDoorClosed

// 本次倒计时期间「到过该区域」的生还者。倒计时结束时只传送「一次都没到过」的人，
// 已经到过、随后离开继续推进的人不再被传送回来（1.2.0 修复）。
bool   g_bSeen[MAXPLAYERS+1];

// 1.2.7「有人进入区域」提示的逐区域 × 逐玩家状态：
//   g_bAreaPresence[i][client]  上一 tick 该生还者是否在区域 i 内（只用来抓「不在 -> 在」的跳变）
//   g_fAreaEnterAt[i][client]   该玩家上次被播报「进入区域 i」的时刻（抑制边界抖动刷屏）
//   g_bAreaNoticePrimed[i]      区域 i 是否已经做过第一次静默登记
bool   g_bAreaPresence[MAX_AREAS][MAXPLAYERS+1];
float  g_fAreaEnterAt[MAX_AREAS][MAXPLAYERS+1];
bool   g_bAreaNoticePrimed[MAX_AREAS];

bool   g_bMapStarted;
bool   g_bLateLoad;
bool   g_bSacrificeFinale;
bool   g_bRescueReady;          // 救援车是否已到位（finale_vehicle_ready）
bool   g_bSiteAuthority;        // 本图集合点已由「预设 / 原版地点」提供

// ---------------------------------------------------------------------------
// 1.3.2：救援区忽略名单（按地图，写在预设表 / 原版地点表的 "_ignore" 段里）
//
// 背景：救援层是按「trigger_multiple + m_iEntireTeam == 2」整类抓的，而终局图上
// 满足这个字段的体积往往不止逃生点一个 —— 例如 c6m3_port 既有桥尾的
// trigger_escape，也有升罐电梯上的 generator_elevator_trigger（它只是用来在全员
// 站上升降台时 Unlock 车厢按钮）。后者被当成救援区后，逃离阶段一旦对冲就先起
// 60 秒倒计时，把掉队者往「起点侧」传送。cfg 里删条目删不掉它（它不是 cfg 登记
// 的区域），所以在注册阶段加一层名单过滤。
//
// 名单随预设表 / 原版地点表一起读取，换图 / 换回合清空后重新解析；
// 名字比较大小写不敏感，与目标实体的 targetname（m_iName）对齐。
// ---------------------------------------------------------------------------
#define RESCUE_IGNORE_MAX   8
#define RESCUE_IGNORE_LEN   128
#define RESCUE_IGNORE_SECTION "_ignore"   // 保留段名：_ignore { "rescue" "名字,名字" }

int  g_iRescueIgnoreCount;
char g_sRescueIgnore[RESCUE_IGNORE_MAX][RESCUE_IGNORE_LEN];
bool g_bRescueIgnoreOverflowLogged;   // 名单超长只 warn 一次（每张图），不按回合刷日志

// ---------------------------------------------------------------------------
// 运行期 native 可用性
// ---------------------------------------------------------------------------
bool g_bNtvTouch;               // L4D_IsTouchingTrigger
bool g_bNtvFinalMap;            // L4D_IsMissionFinalMap
bool g_bNtvEscape;              // L4D_IsFinaleEscapeInProgress
bool g_bNtvNav;                 // L4D_GetNearestNavArea + L4D_FindRandomSpot
bool g_bNtvRevive;              // L4D_ReviveSurvivor
bool g_bNtvWarp;                // L4D_WarpToValidPositionIfStuck
bool g_bNtvDominating;          // L4D2_GetSpecialInfectedDominatingMe
bool g_bNtvRelease;             // 4 个解控 native
bool g_bNtvRescueVehicle;       // L4D2_SendInRescueVehicle
bool g_bNtvDoorLast;            // L4D_GetCheckpointLast（找关底安全门）
bool g_bNtvLastCp;              // L4D_IsPositionInLastCheckpoint（挑关底那个 info_changelevel）

bool g_bReady;                  // 关键 native 齐全

public Plugin myinfo =
{
	name        = "L4D2 Checkpoint Teleport",
	author      = "apples1949",
	description = "安全屋/救援点/中途集合点按类型分别倒计时，结束时传送未到者并开启机关",
	version     = PLUGIN_VERSION,
	url         = ""
};

// ===========================================================================
//  插件生命周期
// ===========================================================================

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	if (GetEngineVersion() != Engine_Left4Dead2)
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 2.");
		return APLRes_SilentFailure;
	}

	g_bLateLoad = late;

	return APLRes_Success;
}

public void OnPluginStart()
{
	g_cvEnable = CreateConVar("l4d2_cptele_enable", "1",
		"1=启用「集合点/安全屋/救援关倒计时传送」插件。0=完全关闭（不侦测区域、不传送）",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// ---- A 组：安全屋 / 救援点（保持插件原有名字与默认值） -----------------
	g_cvPercent = CreateConVar("l4d2_cptele_percent", "50",
		"[安全屋/救援点] 触发倒计时所需的到达比例（%）。所需人数 = 向上取整(该比例 × 当前存活生还者数)。默认 50。中途集合点请用 l4d2_cptele_checkpoint_percent",
		FCVAR_NOTIFY, true, 1.0, true, 100.0);

	g_cvTime = CreateConVar("l4d2_cptele_time", "60",
		"[安全屋/救援点] 到达比例达标后的倒计时秒数，倒计时结束时传送未到达的生还者。默认 60（原有设定）。中途集合点请用 l4d2_cptele_checkpoint_time",
		FCVAR_NOTIFY, true, 1.0, true, 600.0);

	// ---- B 组：地图中途集合点（预设点 / 原版地点 / 机关按钮） --------------
	g_cvCpPercent = CreateConVar("l4d2_cptele_checkpoint_percent", "50",
		"[中途集合点] 触发倒计时所需的到达比例（%）。所需人数 = 向上取整(该比例 × 当前存活生还者数)。默认 50",
		FCVAR_NOTIFY, true, 1.0, true, 100.0);

	g_cvCpTime = CreateConVar("l4d2_cptele_checkpoint_time", "30",
		"[中途集合点] 到达比例达标后的倒计时秒数，倒计时结束时传送未到达的生还者并开启机关。默认 30",
		FCVAR_NOTIFY, true, 1.0, true, 600.0);

	// 1.3.0 需求（c5m2）：中途集合点「全员集合完毕」后不再让倒计时空转。
	// 只影响中途集合点（AREA_CHECKPOINT）；安全屋 / 救援点仍是「走满再结算」。
	g_cvCpFinishAllSeen = CreateConVar("l4d2_cptele_checkpoint_finish_all_seen", "1",
		"[中途集合点] 1=本次倒计时期间所有当前存活的生还者都到过该集合点（判定口径同 l4d2_cptele_skip_seen）时，立刻结束倒计时并开机关，不再空转到 0 之后再播「无需传送」。仅在 l4d2_cptele_skip_seen 1 时生效。0=回到旧行为（集合完毕也把倒计时走满）。安全屋/救援点不受本开关影响",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// 1.3.4（玩家反馈）：中途集合点倒计时结束时，半径判定（l4d2_cptele_mech_radius）
	// 会把"离机关几百单位"的队友也算成已在集合点 → 只传送 2 个人、其它人原地卡着。
	// 1=集合点结算时把**全体存活生还者**都传送到落点（已经真正站在落点上的也只是被抖动几十单位）；
	// 0=只传送判定为"在区域外"的人（旧行为）。安全屋/救援点不受本开关影响。
	g_cvCpTeleportAll = CreateConVar("l4d2_cptele_checkpoint_teleport_all", "1",
		"[中途集合点] 1=倒计时结束时把全体存活生还者都传送到落点（解决半径判定把远处队友误判为已到、只传少数人的问题）；0=只传判定在区域外的人。安全屋/救援点不受影响",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// 1.3.6（玩家反馈 c4m2）：集合点里一个生还者都没有时暂停倒计时。
	// 否则会对着空电梯倒计时，到点后没有"区域内的队友"可当落点，
	// 只能传送到区域中心/nav 点 → 容易落到电梯井外摔死。
	g_cvPauseWhenEmpty = CreateConVar("l4d2_cptele_pause_when_empty", "1",
		"[中途集合点] 1=倒计时期间集合点内没有任何存活生还者时暂停倒计时（保留剩余秒数），等人进去后自动继续；0=不暂停（旧行为）",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// 1.3.8（玩家反馈 c1m1）：半径判定（l4d2_cptele_mech_radius）不认墙也不认楼层，
	// 写 600 就会把集合点外面一整片走廊/上层平台都算成「已到场」，12 人局 50% 只要
	// 6 人正好在那片区域（捡枪、路过、打架）就起倒计时。这里加一道硬门槛：
	// 必须至少有 1 名存活生还者真的在机关身边（核心半径内），否则不起倒计时。
	// 方框（square）/ 触发体积类区域本来就是精确体积，不受这条影响。
	g_cvCpCoreRadius = CreateConVar("l4d2_cptele_checkpoint_core_radius", "200.0",
		"[中途集合点] 半径判定的集合点在起倒计时前，至少要有一名存活生还者离判定中心这么近（HU，三维距离）才算「真的到过机关旁边」，否则不起倒计时。预设里用 square 方框或触发体积判定的区域不受影响。0=关闭该门槛",
		FCVAR_NOTIFY, true, 0.0, true, 2000.0);

	// ---- 检测来源 ---------------------------------------------------------
	g_cvPreset = CreateConVar("l4d2_cptele_preset", "1",
		"1=优先使用预设地图配置（configs 下的 KeyValues 文件）判定地图中途集合点，命中后不再走原版地点表与动态按钮登记。0=不读预设文件",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvPresetFile = CreateConVar("l4d2_cptele_preset_file", PRESET_DEFAULT_FILE,
		"预设地图配置文件名，相对 addons/sourcemod/configs/。文件不存在时静默跳过（不报错），自动回落到原版地点表 / 运行时侦测",
		FCVAR_NOTIFY);

	g_cvLegacy = CreateConVar("l4d2_cptele_legacy", "1",
		"1=启用「原版按地点检测」配置表（configs/l4d2_cptele_legacy.cfg：地图名 → 机关实体 targetname + 传送点，搬自 L4D Elevator Teleport，1.3.1 起从代码搬到 cfg）。仅在预设没有命中本图时生效。0=只用预设与运行时侦测",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvLegacyFile = CreateConVar("l4d2_cptele_legacy_file", LEGACY_DEFAULT_FILE,
		"原版地点表文件名，相对 addons/sourcemod/configs/。文件不存在时静默跳过（不报错、不打日志刷屏），自动回落到运行时侦测。改完 sm_cptele_reload 即可生效，不用重编译",
		FCVAR_NOTIFY);

	// ---- 通用行为 ---------------------------------------------------------
	g_cvResetOnLeave = CreateConVar("l4d2_cptele_reset_on_leave", "0",
		"0=倒计时开始后即使到达人数掉回比例以下也继续倒计时（默认）。1=掉回比例以下时取消本次倒计时，等人数再次达标后重新开始",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvSkipSeen = CreateConVar("l4d2_cptele_skip_seen", "1",
		"1=倒计时期间已经到过集合点（哪怕随后离开、继续往前走）的生还者，倒计时结束时不再被传送回来（安全屋/救援点仍按「此刻必须在屋内」把掉队者传进来）。中途集合点在全员都到过时会立刻结束倒计时，见 l4d2_cptele_checkpoint_finish_all_seen；安全屋/救援点仍走满再结算。0=旧行为（只看倒计时结束那一刻是否还在区域内，全员到过也不会提前结束倒计时）",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvSound = CreateConVar("l4d2_cptele_sound", "1",
		"1=倒计时期间每秒给全队播放提示音 buttons/blip1.wav。0=静音",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvChat = CreateConVar("l4d2_cptele_chat", "1",
		"1=倒计时开始与结束时在聊天框输出一行提示（HUD 提示不受此开关影响）。0=只留 HUD 提示",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// 1.2.7 需求：有生还者「首次进入」集合区域时，向所有玩家提示可触发传送。
	// 1.2.8：该区域本回合已经触发过传送之后仍然继续提示（1.2.7 曾经触发一次就永久静音）；
	//        插件自己把人传送进来的那一次不算「进入」，不会额外多播一条。
	g_cvEnterNotice = CreateConVar("l4d2_cptele_enter_notice", "1",
		"1=有生还者进入安全屋/救援点/集合点区域时，向所有玩家在聊天框和屏幕下方提示可触发传送（只在进入那一刻播报，不会每 tick 刷屏；该区域已触发过传送后仍继续提示，插件自己的传送不算进入；传送倒计时进行期间自动静音，倒计时结束/取消后恢复播报）。0=不播报",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvSaferoom = CreateConVar("l4d2_cptele_saferoom", "1",
		"1=启用关底安全屋（info_changelevel / trigger_changelevel）的集合传送。0=不处理安全屋。注意：本插件永远不会改动安全门本身",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// 需求 #7：安全门关着时，倒计时传送把人送进屋也不会过关（引擎侧要门先「已开启」）。
	// 这里默认 1，传送后只对「完全关闭」的安全门发一次标准 Open 输入。
	g_cvSaferoomDoor = CreateConVar("l4d2_cptele_saferoom_opendoor", "1",
		"1=倒计时传送把生还者送进关底安全屋后，若安全门处于完全关闭状态，对该门发送标准 Open 输入（等价玩家开门，不改 spawnflags/lock），让引擎的过关判定能触发。0=完全不碰安全门",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// 1.2.2：光开门不一定够（有的图门开完没人去关，引擎的 CheckpointDoorClosed 就不会来），
	// 所以再补一层「所有存活生还者都在屋内时，补发一次引擎自己的 CheckpointDoorClosed」。
	g_cvSaferoomForceDoor = CreateConVar("l4d2_cptele_saferoom_forcedoor", "1",
		"1=断电补救：安全门原本是关闭状态（说明过关链没起来）时，在全员都进到安全屋体积后，向 info_changelevel 补发一次 CheckpointDoorClosed 输入（就是引擎在门关闭时自己发的那个输入），并把门物理关回去。0=只做 Open，不补发关门事件",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvRescue = CreateConVar("l4d2_cptele_rescue", "1",
		"1=启用救援关（终局图 m_iEntireTeam==2 的 trigger_multiple）的集合传送。0=不处理救援关",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvMechanism = CreateConVar("l4d2_cptele_mechanism", "1",
		"1=启用「运行时自动侦测」的机关集合点：玩家按下被锁住的 func_button 时把该按钮登记为集合点，比例达标后倒计时并自动解锁+按下按钮。预设或原版地点已覆盖本图时不生效",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvMechanismUnlocked = CreateConVar("l4d2_cptele_mechanism_unlocked", "0",
		"1=额外把「未上锁」的 func_button 正常按下（OnPressed）也当作机关集合点。默认 0：避免地图上普通按钮被误登记后把全队传送。仅在确认地图池存在未上锁的必经机关按钮时才建议打开",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvMechRadius = CreateConVar("l4d2_cptele_mech_radius", "600.0",
		"按钮/坐标类集合点的默认判定半径（三维距离，单位 HU）。生还者到区域中心的距离小于该值即视为「已到达」。预设里写了 radius 时以预设为准",
		FCVAR_NOTIFY, true, 50.0, true, 5000.0);

	g_cvRevive = CreateConVar("l4d2_cptele_revive", "1",
		"1=传送前自动把挂在边缘（ledge hang）的生还者救起，避免传送到空中摔死。0=不处理",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvReleaseSi = CreateConVar("l4d2_cptele_release_si", "1",
		"1=传送前自动解除特感对生还者的控制（Smoker 拖拽 / Hunter 扑倒 / Jockey 骑乘 / Charger 冲撞与砸击），不杀死特感。0=不处理",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvRemoveInfected = CreateConVar("l4d2_cptele_remove_infected", "0",
		"1=传送结束后清理传送点周围 300 HU 内的 infected / witch。0=不清理（默认）",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvRescueForce = CreateConVar("l4d2_cptele_rescue_force", "0",
		"1=救援关倒计时结束时额外调用一次 L4D2_SendInRescueVehicle（强制叫车）。0=交给游戏自己判定（默认，推荐）",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvVerbose = CreateConVar("l4d2_cptele_verbose", "0",
		"1=在服务端控制台输出区域侦测（走了预设 / 原版地点 / 自动侦测哪条路径）与状态流转日志，用于进服排错。0=安静",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	CreateConVar("l4d2_cptele_version", PLUGIN_VERSION,
		"l4d2_checkpoint_teleport 版本号",
		FCVAR_NOTIFY|FCVAR_DONTRECORD);

	// 本仓库 12v12 插件的惯例：参数由模式 cfg 指定，不自动生成 cfg/sourcemod/*.cfg
	//AutoExecConfig(true, "l4d2_checkpoint_teleport");

	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
	HookEvent("finale_vehicle_ready", Event_FinaleVehicleReady, EventHookMode_PostNoCopy);

	// 机关集合点：OnUseLocked = 按下「被锁住的」按钮，这是参考A 的主路径，
	// 也是本插件真正想要的信号：游戏本来要求全员到齐才能按，插件给
	// 部分到场的玩家一条「倒计时后自动传送 + 开机关」的路。
	HookEntityOutput("func_button", "OnUseLocked", OnButtonUseLocked);

	// OnPressed = 按钮正常按下（未上锁的机关按钮走这条）。
	// 全局 hook OnPressed 有误报风险：地图上任何普通按钮被按一下都会被
	// 登记成集合点，随后路过的人凑够比例就会把全队传过去。
	// 因此默认关闭（l4d2_cptele_mechanism_unlocked=0），只在地图池里确实
	// 存在「未上锁的必经机关按钮」时才建议打开。
	HookEntityOutput("func_button", "OnPressed", OnButtonPressedOutput);

	RegConsoleCmd("sm_cptele", Cmd_Status, "查看集合点传送插件的区域侦测状态");
	RegAdminCmd("sm_cptele_reload", Cmd_ReloadPresets, ADMFLAG_GENERIC,
		"重新读取预设地图配置并立即重新侦测区域（测试/排错用）");
	RegAdminCmd("sm_cptele_force", Cmd_Force, ADMFLAG_GENERIC,
		"强制为最后一个侦测到的区域立刻开始倒计时（测试用）");

	ResetRound();
}

public void OnAllPluginsLoaded()
{
	// include 里这些都是 MarkNativeAsOptional，必须运行期复核
	g_bNtvTouch         = NtvAvailable("L4D_IsTouchingTrigger");
	g_bNtvFinalMap      = NtvAvailable("L4D_IsMissionFinalMap");
	g_bNtvEscape        = NtvAvailable("L4D_IsFinaleEscapeInProgress");
	g_bNtvRevive        = NtvAvailable("L4D_ReviveSurvivor");
	g_bNtvWarp          = NtvAvailable("L4D_WarpToValidPositionIfStuck");
	g_bNtvDominating    = NtvAvailable("L4D2_GetSpecialInfectedDominatingMe");
	g_bNtvRescueVehicle = NtvAvailable("L4D2_SendInRescueVehicle");
	g_bNtvDoorLast      = NtvAvailable("L4D_GetCheckpointLast");
	g_bNtvLastCp        = NtvAvailable("L4D_IsPositionInLastCheckpoint");

	g_bNtvNav = NtvAvailable("L4D_GetNearestNavArea") && NtvAvailable("L4D_FindRandomSpot");

	g_bNtvRelease = NtvAvailable("L4D_Smoker_ReleaseVictim")
	             && NtvAvailable("L4D_Hunter_ReleaseVictim")
	             && NtvAvailable("L4D2_Jockey_EndRide")
	             && NtvAvailable("L4D2_Charger_EndCarry")
	             && NtvAvailable("L4D2_Charger_EndPummel");

	// 关键：没有 IsTouchingTrigger 就无法判定安全屋 / 救援关
	g_bReady = g_bNtvTouch && g_bNtvFinalMap;

	if (!g_bReady)
	{
		LogError("[cptele] left4dhooks 关键 native 不可用 (L4D_IsTouchingTrigger=%d, L4D_IsMissionFinalMap=%d)，插件功能已停用。",
			g_bNtvTouch, g_bNtvFinalMap);
	}
	else if (g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] native 检查通过: touch=%d finalmap=%d nav=%d revive=%d warp=%d dom=%d release=%d rescue=%d doorlast=%d",
			g_bNtvTouch, g_bNtvFinalMap, g_bNtvNav, g_bNtvRevive,
			g_bNtvWarp, g_bNtvDominating, g_bNtvRelease, g_bNtvRescueVehicle, g_bNtvDoorLast);
	}
}

public void OnMapStart()
{
	g_bMapStarted = true;
	g_bSacrificeFinale = false;

	PrecacheSound(SOUND_COUNTDOWN, true);

	// 换图重新读预设文件（文件可能刚被改过）
	delete g_hPresets;
	g_hPresets = null;
	g_bPresetsTried = false;

	// 1.3.1：原版地点表同样是「每张图读一次」，换图 / 重载一并释放
	delete g_hLegacy;
	g_hLegacy = null;
	g_bLegacyTried = false;

	// 1.3.2：救援区忽略名单的「超长已告警」标记按图重置
	g_bRescueIgnoreOverflowLogged = false;

	ResetRound();

	// 插件晚加载（sm plugins load / 换图后手动加载）：此时本图的
	// round_start 早就过去了，不会再有事件，必须立刻补一次侦测，
	// 否则本回合完全不起作用。
	if (g_bLateLoad)
	{
		g_bLateLoad = false;
		CreateTimer(1.0, Timer_InitAreas, 0, TIMER_FLAG_NO_MAPCHANGE);
	}

	if (g_cvVerbose.BoolValue)
	{
		char sMap[128];
		GetCurrentMap(sMap, sizeof(sMap));
		PrintToServer("[cptele] OnMapStart: %s", sMap);
	}
}

public void OnMapEnd()
{
	ResetRound();

	delete g_hPresets;
	g_hPresets = null;
	g_bPresetsTried = false;

	// 1.3.1：原版地点表同样是「每张图读一次」，换图 / 重载一并释放
	delete g_hLegacy;
	g_hLegacy = null;
	g_bLegacyTried = false;

	g_bMapStarted = false;
	g_bSacrificeFinale = false;
}

// ===========================================================================
//  回合事件
// ===========================================================================

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	ResetRound();

	// 延迟侦测：等实体与 nav 稳定（参考 safearea_teleport 的延后初始化）
	CreateTimer(INIT_DELAY, Timer_InitAreas, 0, TIMER_FLAG_NO_MAPCHANGE);
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	ResetRound();
}

/**
 * 槽位复用防御：g_bSeen 按客户端索引记录，掉线后新玩家复用同一槽位时
 * 会被误当成「已经到过集合点」（该传不传，甚至提前判定全员到齐）。
 * 连接 / 断线两个时机都清掉，确保标记只属于当前占用该槽位的人。
 */
public void OnClientConnected(int client)
{
	if (client > 0 && client <= MaxClients)
	{
		g_bSeen[client] = false;

		// 1.2.7：client 槽位可能是被复用的，进入区域提示的状态也要一起清
		ClearEnterNoticeForClient(client);
	}
}

public void OnClientDisconnect(int client)
{
	if (client > 0 && client <= MaxClients)
	{
		g_bSeen[client] = false;

		ClearEnterNoticeForClient(client);
	}
}

/**
 * 救援车到位。在此之前「救援关区域」不参与判定：
 * 终局战斗期间救援车触发器就在地图上，但那时候它没有任何意义，
 * 提前触发只会把正在打坦克的生还者直接传走。
 */
public void Event_FinaleVehicleReady(Event event, const char[] name, bool dontBroadcast)
{
	g_bRescueReady = true;

	if (g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] 救援车已到位，救援关区域开始参与判定");
	}
}

// ===========================================================================
//  区域侦测入口
// ===========================================================================

public Action Timer_InitAreas(Handle timer)
{
	if (!g_bMapStarted || !g_bReady || !g_cvEnable.BoolValue)
	{
		return Plugin_Stop;
	}

	DetectAreas();

	// 注意：监控 timer 必须无条件启动。终局救援图可能侦测不到安全屋区域，
	// 而机关集合点是玩家按按钮时才动态登记的，不能依赖 g_iAreaCount > 0。
	EnsureMonitor();

	return Plugin_Stop;
}

/**
 * 幂等地确保监控 timer 在跑。
 * Timer_InitAreas 与 OnButtonUseLocked 都会调用，保证动态登记的区域也能被监控。
 */
void EnsureMonitor()
{
	if (g_hMonitor != null)
	{
		return;
	}

	g_hMonitor = CreateTimer(MONITOR_INTERVAL, Timer_Monitor, 0,
		TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
}

/**
 * 侦测顺序（重要）：
 *   1) 预设地图配置   —— 优先
 *   2) 原版按地点检测 —— 仅当预设没有给出中途集合点
 *   3) 运行时自动侦测 —— 安全屋 / 救援点始终走这条；中途集合点由
 *                        OnUseLocked 动态登记（受 g_bSiteAuthority 抑制）
 */
void DetectAreas()
{
	// 只追加、不清空：机关集合点可能在 INIT_DELAY 之前就被按下登记，
	// 清空会丢掉它们。整份列表由 ResetRound() / OnMapEnd 统一重置。
	g_bSacrificeFinale = false;
	g_bSiteAuthority = false;

	int iSiteAreas = 0;     // 预设/原版地点总共贡献多少个区域
	int iSiteCp = 0;        // 其中「中途集合点」有多少个（决定是否抑制动态登记）

	char sSiteOwner[32];
	strcopy(sSiteOwner, sizeof(sSiteOwner), "运行时侦测");

	// ---- 1) 预设地图配置 ------------------------------------------------
	if (g_cvPreset.BoolValue)
	{
		int iPresetCp = 0;

		iSiteAreas += LoadPresetAreas(iPresetCp);

		if (iPresetCp > 0)
		{
			iSiteCp += iPresetCp;
			strcopy(sSiteOwner, sizeof(sSiteOwner), "预设配置");
		}
	}

	// ---- 2) 原版按地点检测（配置表 configs/l4d2_cptele_legacy.cfg） --------
	if (iSiteCp == 0 && g_cvLegacy.BoolValue)
	{
		int iLegacyCp = 0;
		int iLegacy = LoadLegacyAreas(iLegacyCp);

		iSiteAreas += iLegacy;

		if (iLegacyCp > 0)
		{
			iSiteCp += iLegacyCp;
			strcopy(sSiteOwner, sizeof(sSiteOwner), "原版地点表");
		}
	}

	g_bSiteAuthority = (iSiteCp > 0);

	if (g_bSiteAuthority && g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] 本图中途集合点来源: %s，忽略动态按钮登记", sSiteOwner);
	}

	// ---- 3a) 关底安全屋 --------------------------------------------------
	if (g_cvSaferoom.BoolValue)
	{
		// 1.2.2：不能只取第一个 changelevel —— 官方图里有 7 张图第一个 changelevel 是
		// 「起点」安全屋体积，取第一个会让安全屋区域指到开局那间屋（见 FindLastChangelevel 注释）
		int entity = FindLastChangelevel();

		if (entity != -1)
		{
			AddArea(entity, AREA_SAFEROOM, SRC_AUTO, NULL_VECTOR, 0.0, NULL_VECTOR, false);

			if (g_cvVerbose.BoolValue)
			{
				char sClass[64];
				GetEntityClassname(entity, sClass, sizeof(sClass));
				PrintToServer("[cptele] 安全屋区域: entity #%d (%s)", entity, sClass);
			}
		}
		else if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 未找到 info_changelevel / trigger_changelevel");
		}
	}

	// ---- 3b) 救援关 -----------------------------------------------------
	if (g_cvRescue.BoolValue && g_bNtvFinalMap && L4D_IsMissionFinalMap())
	{
		// 牺牲结局（c8m3 之类）没有救援车，直接跳过
		int finale = FindEntityByClassname(-1, "trigger_finale");

		if (finale != -1)
		{
			// m_bIsSacrificeFinale 是 (1 Bytes) 字段，必须显式传 size=1，
			// 否则会按默认 4 字节越界读取，把相邻字段的位读进来
			g_bSacrificeFinale = view_as<bool>(
				GetEntProp(finale, Prop_Data, "m_bIsSacrificeFinale", 1));
		}

		if (g_bSacrificeFinale)
		{
			if (g_cvVerbose.BoolValue)
			{
				PrintToServer("[cptele] 终局图为牺牲结局，跳过救援关区域");
			}
		}
		else
		{
			int entity = -1;

			while ((entity = FindEntityByClassname(entity, "trigger_multiple")) != -1)
			{
				if (GetEntProp(entity, Prop_Data, "m_iEntireTeam") != TEAM_SURVIVOR)
				{
					continue;
				}

				/* 1.3.2：忽略名单过滤。终局图上 entireteam==2 的体积经常不止逃生点
				 * 一个（c6m3_port 的 generator_elevator_trigger 只是「全员站上升降台
				 * 就 Unlock 车厢按钮」），被当成救援区后会在逃离阶段抢先把掉队者
				 * 往起点侧传送。名单写在预设 / 原版地点表的 "_ignore" 段。 */
				char sTarget[128];
				sTarget[0] = '\0';
				GetEntPropString(entity, Prop_Data, "m_iName", sTarget, sizeof(sTarget));

				if (IsRescueTargetIgnored(sTarget))
				{
					if (g_cvVerbose.BoolValue)
					{
						PrintToServer("[cptele] 救援区忽略: trigger_multiple[%s] #%d", sTarget, entity);
					}

					continue;
				}

				AddArea(entity, AREA_RESCUE, SRC_AUTO, NULL_VECTOR, 0.0, NULL_VECTOR, false);

				if (g_cvVerbose.BoolValue)
				{
					PrintToServer("[cptele] 救援关区域: trigger_multiple[%s] #%d", sTarget, entity);
				}
			}
		}
	}

	if (g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] 本轮侦测到 %d 个区域（其中预设/原版地点贡献 %d 个，集合点权威=%d）",
			g_iAreaCount, iSiteAreas, g_bSiteAuthority);

		char sType[16];
		char sSrc[16];

		for (int i = 0; i < g_iAreaCount; i++)
		{
			GetAreaTypeName(g_iAreaType[i], sType, sizeof(sType));
			GetAreaSourceName(g_iAreaSource[i], sSrc, sizeof(sSrc));

			PrintToServer("[cptele]   区域 #%d 类型=%s 来源=%s 实体=%d 距离判定=%d 固定传送点=%d",
				i, sType, sSrc, GetAreaEntity(i), g_bAreaRadius[i], g_bAreaDest[i]);

			/* 1.3.1：半径类实体区域把「快照中心」和「原始 m_vecOrigin」一起打出来。
			 * 父实体下的按钮，两者会差一个父实体原点——这就是 1.3.0 及以前区域中心
			 * 塌到地图原点附近、到达人数恒为 0 的根因。排错时看这一行即可确认。 */
			if (g_bAreaRadius[i] && !g_bAreaCoord[i])
			{
				int entity = GetAreaEntity(i);

				if (entity != -1)
				{
					float vCenter[3];
					float vRaw[3];

					GetAreaCenter(i, vCenter);
					GetEntPropVector(entity, Prop_Send, "m_vecOrigin", vRaw);

					PrintToServer("[cptele]     世界中心 %.1f %.1f %.1f | 原始 m_vecOrigin %.1f %.1f %.1f | 父实体=%d",
						vCenter[0], vCenter[1], vCenter[2],
						vRaw[0], vRaw[1], vRaw[2], GetEntityParent(entity));
				}
			}
		}
	}
}

/**
 * 1.3.7：把区域的判定方式切换成 2D 方框（square）。
 * 坐标可以直接抄 spit_block_square 那一行的四个数，顺序随意（会自动排序）。
 * zmin/zmax 可选：给了就只在那个高度区间内算"在区域内"（电梯上下两层不会互相误判）。
 *
 * @return true = 设置成功
 */
bool SetAreaBox(int index, float x1, float y1, float x2, float y2, bool bHasZ, float zmin, float zmax)
{
	if (index < 0 || index >= g_iAreaCount)
	{
		return false;
	}

	g_vAreaBox[index][0] = (x1 < x2) ? x1 : x2;
	g_vAreaBox[index][1] = (x1 < x2) ? x2 : x1;
	g_vAreaBox[index][2] = (y1 < y2) ? y1 : y2;
	g_vAreaBox[index][3] = (y1 < y2) ? y2 : y1;

	if (g_vAreaBox[index][1] - g_vAreaBox[index][0] < 8.0
		|| g_vAreaBox[index][3] - g_vAreaBox[index][2] < 8.0)
	{
		if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 区域 #%d 的 square 太小（<8 HU），忽略该写法，退回半径判定", index);
		}

		g_vAreaBox[index][0] = g_vAreaBox[index][1] = 0.0;
		g_vAreaBox[index][2] = g_vAreaBox[index][3] = 0.0;
		g_bAreaBox[index] = false;

		return false;
	}

	if (bHasZ)
	{
		g_fAreaZMin[index] = (zmin < zmax) ? zmin : zmax;
		g_fAreaZMax[index] = (zmin < zmax) ? zmax : zmin;
	}
	else
	{
		g_fAreaZMin[index] = -100000.0;
		g_fAreaZMax[index] = 100000.0;
	}

	g_bAreaBox[index] = true;

	return true;
}

/**
 * 登记一个区域。
 *
 * @param entity    区域实体；<=0 表示「纯坐标区域」（预设里只写了 origin/radius）
 * @param type      AREA_SAFEROOM / AREA_RESCUE / AREA_CHECKPOINT
 * @param source    SRC_AUTO / SRC_LEGACY / SRC_PRESET
 * @param vPos      纯坐标区域的中心点（有实体时传 NULL_VECTOR）
 * @param fRadius   距离判定半径（<=0 用 l4d2_cptele_mech_radius）
 * @param vDest     固定传送点（无则传 NULL_VECTOR）
 * @param bHasDest  是否真的带固定传送点
 * @return          新区域的索引，重复/非法/已满返回 -1
 */
int AddArea(int entity, int type, int source, const float vPos[3],
	float fRadius, const float vDest[3], bool bHasDest)
{
	bool bCoord = (entity <= 0);

	if (!bCoord && !IsValidEntity(entity))
	{
		return -1;
	}

	if (g_iAreaCount >= MAX_AREAS)
	{
		LogError("[cptele] 区域数量超过上限 %d，忽略 entity #%d", MAX_AREAS, entity);
		return -1;
	}

	// 纯坐标区域必须给一个像样的坐标，(0,0,0) 视作配置写错
	if (bCoord && vPos[0] == 0.0 && vPos[1] == 0.0 && vPos[2] == 0.0)
	{
		return -1;
	}

	int ref = bCoord ? 0 : EntIndexToEntRef(entity);

	if (!bCoord)
	{
		for (int i = 0; i < g_iAreaCount; i++)
		{
			if (g_iAreaRef[i] != 0 && g_iAreaRef[i] == ref)
			{
				return -1;
			}
		}
	}

	int index = g_iAreaCount;

	g_iAreaRef[index] = ref;
	g_iAreaType[index] = type;
	g_iAreaSource[index] = source;
	g_bAreaFired[index] = false;
	g_bAreaCoord[index] = bCoord;
	g_bAreaDest[index] = bHasDest;
	g_bAreaBox[index] = false;
	g_fAreaZMin[index] = -100000.0;
	g_fAreaZMax[index] = 100000.0;
	g_fAreaCooldown[index] = 0.0;

	for (int j = 0; j < 4; j++)
	{
		g_vAreaBox[index][j] = 0.0;
	}

	g_fAreaRadius[index] = (fRadius > 0.0) ? fRadius : 0.0;   // <=0 表示用全局默认半径

	for (int j = 0; j < 3; j++)
	{
		g_vAreaPos[index][j] = 0.0;
		g_vAreaDest[index][j] = 0.0;
	}

	if (bHasDest)
	{
		CopyVec(vDest, g_vAreaDest[index]);
	}

	// ---- 判定方式：trigger / changelevel 用 IsTouching，其余用距离 --------
	if (bCoord)
	{
		CopyVec(vPos, g_vAreaPos[index]);
		g_bAreaRadius[index] = true;
	}
	else
	{
		char sClass[64];

		if (GetEntityClassname(entity, sClass, sizeof(sClass)) && IsTouchModeClass(sClass))
		{
			g_bAreaRadius[index] = false;
		}
		else
		{
			g_bAreaRadius[index] = true;
			GetEntityCenter(entity, g_vAreaPos[index]);
		}
	}

	g_iAreaCount++;

	return index;
}

/**
 * 把 EntRef 解析成当前有效的实体索引，失效返回 -1。
 */
int GetAreaEntity(int index)
{
	int ref = g_iAreaRef[index];

	if (ref == 0)
	{
		return -1;
	}

	int entity = EntRefToEntIndex(ref);

	if (entity <= 0 || entity == INVALID_ENT_REFERENCE || !IsValidEntity(entity))
	{
		return -1;
	}

	return entity;
}

/**
 * 区域是否还活着：纯坐标区域永远活着，实体区域要看实体是否还在。
 */
bool IsAreaAlive(int index)
{
	if (g_bAreaCoord[index])
	{
		return true;
	}

	return GetAreaEntity(index) != -1;
}

// ===========================================================================
//  检测路径 1：预设地图配置（KeyValues）
// ===========================================================================

/**
 * 读取预设文件。文件不存在属于正常情况（不报错、不打日志刷屏），
 * 交由上一级回落到原版地点表 / 运行时侦测。
 */
void LoadPresets()
{
	g_bPresetsTried = true;

	delete g_hPresets;
	g_hPresets = null;

	char sFile[PLATFORM_MAX_PATH];
	char sPath[PLATFORM_MAX_PATH];

	g_cvPresetFile.GetString(sFile, sizeof(sFile));
	TrimString(sFile);

	if (sFile[0] == '\0')
	{
		strcopy(sFile, sizeof(sFile), PRESET_DEFAULT_FILE);
	}

	BuildPath(Path_SM, sPath, sizeof(sPath), "configs/%s", sFile);

	if (!FileExists(sPath, false))
	{
		if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 未找到预设文件 %s，自动回落到原版地点表 / 运行时侦测", sPath);
		}

		return;
	}

	KeyValues kv = CreateKeyValues("cptele_presets");

	if (!FileToKeyValues(kv, sPath))
	{
		delete kv;
		LogError("[cptele] 预设文件 %s 解析失败（KeyValues 语法错误？），本图忽略预设配置", sPath);
		return;
	}

	g_hPresets = kv;

	if (g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] 已载入预设文件 %s", sPath);
	}
}

/**
 * 从预设文件里取出当前地图的区域。
 *
 * @param iCheckpoints  输出：其中「中途集合点」类型的个数
 * @return              成功登记的区域总数
 */
int LoadPresetAreas(int &iCheckpoints)
{
	iCheckpoints = 0;

	if (!g_cvPreset.BoolValue)
	{
		return 0;
	}

	if (g_hPresets == null)
	{
		if (g_bPresetsTried)
		{
			return 0;
		}

		LoadPresets();

		if (g_hPresets == null)
		{
			return 0;
		}
	}

	char sMap[128];
	GetCurrentMap(sMap, sizeof(sMap));

	g_hPresets.Rewind();

	if (!g_hPresets.JumpToKey(sMap))
	{
		if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 预设文件里没有本图 %s 的配置，回落到原版地点表 / 运行时侦测", sMap);
		}

		// 回到根节点，避免下次 Rewind 之外的读取踩到子节点
		g_hPresets.Rewind();

		return 0;
	}

	if (!g_hPresets.GotoFirstSubKey())
	{
		g_hPresets.Rewind();
		return 0;
	}

	int iAdded = 0;

	do
	{
		char sSlot[64];
		g_hPresets.GetSectionName(sSlot, sizeof(sSlot));

		// 1.3.2：保留段（_ignore / _comment 之类）不登记成集合点
		if (IsReservedSlotName(sSlot))
		{
			LoadReservedSlot(g_hPresets, sMap, sSlot);

			continue;
		}

		int iResult = LoadConfigSlot(g_hPresets, sMap, sSlot, SRC_PRESET);

		if (iResult > 0)
		{
			iAdded++;

			if (iResult == PRESET_SLOT_CHECKPOINT)
			{
				iCheckpoints++;
			}
		}
	}
	while (g_hPresets.GotoNextKey());

	g_hPresets.Rewind();

	return iAdded;
}

/**
 * 解析并登记一张配置表里的一个槽位（一个槽位 = 一个集合点）。
 *
 * 预设表（l4d2_cptele_presets.cfg）与原版地点表（l4d2_cptele_legacy.cfg）
 * 格式完全一致，共用本函数，只靠 source 参数区分登记来源。
 *
 * 支持两种写法：
 *   1) 坐标写法：origin + radius，地图上没有任何合适实体时也能用
 *   2) 实体写法：classname（+ 可选 targetname），站到该实体附近即算到达
 * 两者都支持可选的 dest（倒计时结束时统一传送到该坐标）。
 *
 * @param kv        已经停在某个槽位键上的 KeyValues（g_hPresets / g_hLegacy）
 * @param sMap      地图名，仅用于日志
 * @param sSlot     槽位名，仅用于日志
 * @param source    区域来源：SRC_PRESET = 预设表，SRC_LEGACY = 原版地点表
 * @return PRESET_SLOT_NONE = 未登记；PRESET_SLOT_OTHER = 登记了安全屋/救援点；
 *         PRESET_SLOT_CHECKPOINT = 登记了中途集合点
 */
int LoadConfigSlot(KeyValues kv, const char[] sMap, const char[] sSlot, int source)
{
	char sType[32];
	kv.GetString("type", sType, sizeof(sType), "checkpoint");

	int type = AREA_CHECKPOINT;

	if (StrEqual(sType, "saferoom", false))
	{
		type = AREA_SAFEROOM;
	}
	else if (StrEqual(sType, "rescue", false))
	{
		type = AREA_RESCUE;
	}

	int iResult = (type == AREA_CHECKPOINT) ? PRESET_SLOT_CHECKPOINT : PRESET_SLOT_OTHER;

	// 1.3.7：方框写法（直接抄 spit_block_square 的四个数），比半径精确得多
	char sSquare[128];
	float vBox[4];
	bool bHasBox = false;

	kv.GetString("square", sSquare, sizeof(sSquare), "");

	if (sSquare[0] != '\0')
	{
		if (ParseSquare(sSquare, vBox))
			bHasBox = true;
		else if (g_cvVerbose.BoolValue)
			PrintToServer("[cptele] 预设 %s/%s 的 square \"%s\" 解析失败，退回半径判定", sMap, sSlot, sSquare);
	}

	bool bHasZ = false;
	float fZMin = 0.0;
	float fZMax = 0.0;
	char sZBuf[64];

	kv.GetString("zmin", sZBuf, sizeof(sZBuf), "");

	if (sZBuf[0] != '\0' && ParseFloatToken(sZBuf, fZMin))
	{
		kv.GetString("zmax", sZBuf, sizeof(sZBuf), "");

		if (sZBuf[0] != '\0' && ParseFloatToken(sZBuf, fZMax))
			bHasZ = true;
	}

	// 半径：预设没写就用全局默认
	float fRadius = kv.GetFloat("radius", 0.0);

	if (fRadius <= 0.0)
	{
		fRadius = g_cvMechRadius.FloatValue;
	}

	// 固定传送点（可选）
	char sDest[128];
	float vDest[3];
	bool bHasDest = false;

	kv.GetString("dest", sDest, sizeof(sDest), "");

	if (sDest[0] != '\0')
	{
		bHasDest = ParseVec(sDest, vDest);

		if (!bHasDest && g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 预设 %s/%s 的 dest \"%s\" 解析失败，忽略该传送点", sMap, sSlot, sDest);
		}
	}

	// ---- 1) 坐标写法（优先：有 origin 就不去找实体） ----------------------
	char sOrigin[128];
	float vPos[3];

	kv.GetString("origin", sOrigin, sizeof(sOrigin), "");

	if (sOrigin[0] != '\0')
	{
		if (!ParseVec(sOrigin, vPos))
		{
			if (g_cvVerbose.BoolValue)
			{
				PrintToServer("[cptele] 预设 %s/%s 的 origin \"%s\" 解析失败，跳过该区域", sMap, sSlot, sOrigin);
			}

			return PRESET_SLOT_NONE;
		}

		int iNewIndex = AddArea(0, type, source, vPos, fRadius, vDest, bHasDest);

		if (iNewIndex != -1 && bHasBox)
			SetAreaBox(iNewIndex, vBox[0], vBox[1], vBox[2], vBox[3], bHasZ, fZMin, fZMax);

		if (iNewIndex == -1)
		{
			if (g_cvVerbose.BoolValue)
			{
				PrintToServer("[cptele] 预设 %s/%s 未登记（坐标无效或区域已满）", sMap, sSlot);
			}

			return PRESET_SLOT_NONE;
		}

		if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 预设坐标区域 %s/%s: %.0f %.0f %.0f 半径 %.0f",
				sMap, sSlot, vPos[0], vPos[1], vPos[2], fRadius);
		}

		return iResult;
	}

	// ---- 2) 实体写法：classname + targetname（targetname 可空） ----------
	char sClass[64];
	char sTarget[128];

	kv.GetString("classname", sClass, sizeof(sClass), "func_button");
	kv.GetString("targetname", sTarget, sizeof(sTarget), "");

	int entity = FindEntityByClassTargetName(sClass, sTarget);

	if (entity == -1)
	{
		if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 预设 %s/%s 找不到实体 %s[%s]，跳过", sMap, sSlot, sClass, sTarget);
		}

		return PRESET_SLOT_NONE;
	}

	int iEntityIndex = AddArea(entity, type, source, NULL_VECTOR, fRadius, vDest, bHasDest);

	if (iEntityIndex != -1 && bHasBox)
		SetAreaBox(iEntityIndex, vBox[0], vBox[1], vBox[2], vBox[3], bHasZ, fZMin, fZMax);

	if (iEntityIndex == -1)
	{
		if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 预设 %s/%s 未登记（实体无效或区域已满）", sMap, sSlot);
		}

		return PRESET_SLOT_NONE;
	}

	if (g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] 预设实体区域 %s/%s: %s[%s] #%d", sMap, sSlot, sClass, sTarget, entity);
	}

	return iResult;
}

// ===========================================================================
//  配置表里的「保留段」与救援区忽略名单（1.3.2）
// ===========================================================================

/**
 * 段名是不是保留段（`_` 或 `#` 开头）。
 *
 * 预设表 / 原版地点表里每个子段默认都被当成「一个集合点」去解析实体，
 * 所以说明性的、控制性的段必须排除掉，否则 "_comment" 这种段会被当成
 * 「classname 默认 func_button、targetname 为空」，进而把地图上第一个
 * func_button 登记成集合点。
 */
bool IsReservedSlotName(const char[] sName)
{
	return (sName[0] == '_' || sName[0] == '#');
}

void ClearRescueIgnore()
{
	g_iRescueIgnoreCount = 0;
}

/**
 * 解析救援区忽略名单：`"rescue" "名字1,名字2"`，逗号 / 空格 / 分号 / Tab 都能分隔。
 */
void ParseRescueIgnoreList(const char[] sMap, const char[] sList)
{
	int len = strlen(sList);
	int i = 0;

	while (i < len)
	{
		while (i < len && (sList[i] == ' ' || sList[i] == '\t' || sList[i] == ',' || sList[i] == ';'))
		{
			i++;
		}

		if (i >= len)
		{
			break;
		}

		int start = i;

		while (i < len && sList[i] != ' ' && sList[i] != '\t' && sList[i] != ',' && sList[i] != ';')
		{
			i++;
		}

		int n = i - start;

		if (n <= 0)
		{
			continue;
		}

		if (n > RESCUE_IGNORE_LEN - 1)
		{
			n = RESCUE_IGNORE_LEN - 1;
		}

		if (g_iRescueIgnoreCount >= RESCUE_IGNORE_MAX)
		{
			// 每张图只报一次：DetectAreas 每回合都会重新解析，按回合刷 error 日志没意义
			if (!g_bRescueIgnoreOverflowLogged)
			{
				g_bRescueIgnoreOverflowLogged = true;
				LogError("[cptele] %s 的救援区忽略名单超过 %d 条，多余条目已忽略", sMap, RESCUE_IGNORE_MAX);
			}

			return;
		}

		char sToken[RESCUE_IGNORE_LEN];

		for (int k = 0; k < n; k++)
		{
			sToken[k] = sList[start + k];
		}

		sToken[n] = '\0';

		strcopy(g_sRescueIgnore[g_iRescueIgnoreCount], RESCUE_IGNORE_LEN, sToken);
		g_iRescueIgnoreCount++;

		if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 救援区忽略名单（%s）：%s", sMap, sToken);
		}
	}
}

/**
 * 这个 targetname 是否在救援区忽略名单里（大小写不敏感）。
 */
bool IsRescueTargetIgnored(const char[] sTarget)
{
	if (g_iRescueIgnoreCount <= 0 || sTarget[0] == '\0')
	{
		return false;
	}

	for (int i = 0; i < g_iRescueIgnoreCount; i++)
	{
		if (StrEqual(g_sRescueIgnore[i], sTarget, false))
		{
			return true;
		}
	}

	return false;
}

/**
 * 处理保留段。目前只认 `_ignore`：
 *   "_ignore"
 *   {
 *       "rescue" "generator_elevator_trigger"
 *   }
 * 其余 `_` / `#` 开头的段只在 verbose 下提示一下，不做任何登记。
 */
void LoadReservedSlot(KeyValues kv, const char[] sMap, const char[] sSlot)
{
	if (StrEqual(sSlot, RESCUE_IGNORE_SECTION, false))
	{
		char sList[256];
		kv.GetString("rescue", sList, sizeof(sList), "");

		if (sList[0] != '\0')
		{
			ParseRescueIgnoreList(sMap, sList);
		}

		return;
	}

	if (g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] 配置段 %s/%s 是保留段（_ / # 开头），不作为集合点登记", sMap, sSlot);
	}
}

// ===========================================================================
//  检测路径 2：原版按地点检测（配置表）
// ===========================================================================
//
//  1.3.1 起这张表从代码里搬到 configs/l4d2_cptele_legacy.cfg（原来的
//  GetLegacySite() 硬编码表已删除）：
//    · 改地图不用重编译，管理员改完 sm_cptele_reload 立刻生效；
//    · 与 l4d2_cptele_presets.cfg 用同一套键名、同一个槽位解析器
//      （type / origin / radius / classname / targetname / dest），
//      只是根节点叫 "cptele_legacy"、区域来源标记为 SRC_LEGACY；
//    · 文件不存在 = 正常情况（静默回落到运行时侦测），不报错、不刷日志。
//
//  表里的数据搬自 alasfourom "L4D Elevator Teleport"（参考插件）：把
//  「地图名 → 机关实体（classname + targetname） + 统一传送点坐标」写在一起，
//  玩家站在该机关附近（三维距离 <= 该槽位 radius / l4d2_cptele_mech_radius）
//  即视为到达集合点。
//
//  ⚠ 给新地图选实体时的硬要求：**优先挑不动的按钮**
//    父实体（parentname）下的 m_vecOrigin 是相对父级的局部坐标，引擎在
//    SetParent 时就换算过了。1.3.0 及以前 GetEntityCenter() 直接把它当世界
//    坐标用，于是 c1m1 / c1m4 / c3m1 / c4m2 / c4m3 这些「映射到电梯/渡轮上的
//    按钮」的条目中心全部塌到地图原点附近 → 到达人数恒为 0 → 倒计时永不触发。
//    1.3.1 已在 GetEntityWorldOrigin() 里做父实体感知（并且会跟着移动的电梯
//    实时重算），但选实体时仍应优先挑固定不动的那个：例如 c4m2 该用顶层的
//    button_callelevator，而不是车厢里的 button_inelevator（后者按一次还会自删）。

/**
 * 载入原版地点表文件（每张图只读一次，换图 / 重载时释放）。
 * 文件不存在属于正常情况，与预设文件同策略：静默跳过。
 */
void LoadLegacyConfig()
{
	g_bLegacyTried = true;

	delete g_hLegacy;
	g_hLegacy = null;

	char sFile[PLATFORM_MAX_PATH];
	char sPath[PLATFORM_MAX_PATH];

	g_cvLegacyFile.GetString(sFile, sizeof(sFile));
	TrimString(sFile);

	if (sFile[0] == '\0')
	{
		strcopy(sFile, sizeof(sFile), LEGACY_DEFAULT_FILE);
	}

	BuildPath(Path_SM, sPath, sizeof(sPath), "configs/%s", sFile);

	if (!FileExists(sPath, false))
	{
		if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 未找到原版地点表 %s，自动回落到运行时侦测", sPath);
		}

		return;
	}

	KeyValues kv = CreateKeyValues("cptele_legacy");

	if (!FileToKeyValues(kv, sPath))
	{
		delete kv;
		LogError("[cptele] 原版地点表 %s 解析失败（KeyValues 语法错误？），本图忽略该表", sPath);
		return;
	}

	g_hLegacy = kv;

	if (g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] 已载入原版地点表 %s", sPath);
	}
}

/**
 * 从原版地点表里取出当前地图的区域；地图上没有对应实体时安静回落。
 *
 * @param iCheckpoints  输出：其中「中途集合点」类型的个数
 * @return              成功登记的区域总数
 */
int LoadLegacyAreas(int &iCheckpoints)
{
	iCheckpoints = 0;

	if (!g_cvLegacy.BoolValue)
	{
		return 0;
	}

	if (g_hLegacy == null)
	{
		if (g_bLegacyTried)
		{
			return 0;
		}

		LoadLegacyConfig();

		if (g_hLegacy == null)
		{
			return 0;
		}
	}

	char sMap[128];
	GetCurrentMap(sMap, sizeof(sMap));

	g_hLegacy.Rewind();

	if (!g_hLegacy.JumpToKey(sMap))
	{
		if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 原版地点表里没有本图 %s 的条目，回落到运行时侦测", sMap);
		}

		// 回到根节点，避免下次读取踩到子节点
		g_hLegacy.Rewind();

		return 0;
	}

	if (!g_hLegacy.GotoFirstSubKey())
	{
		g_hLegacy.Rewind();
		return 0;
	}

	int iAdded = 0;

	do
	{
		char sSlot[64];
		g_hLegacy.GetSectionName(sSlot, sizeof(sSlot));

		// 1.3.2：保留段（_ignore / _comment 之类）不登记成集合点
		if (IsReservedSlotName(sSlot))
		{
			LoadReservedSlot(g_hLegacy, sMap, sSlot);

			continue;
		}

		int iResult = LoadConfigSlot(g_hLegacy, sMap, sSlot, SRC_LEGACY);

		if (iResult != PRESET_SLOT_NONE)
		{
			iAdded++;

			if (iResult == PRESET_SLOT_CHECKPOINT)
			{
				iCheckpoints++;
			}
		}
	}
	while (g_hLegacy.GotoNextKey());

	g_hLegacy.Rewind();

	return iAdded;
}

// ===========================================================================
//  检测路径 3：运行时自动侦测 —— 按下被锁住的 func_button
// ===========================================================================

public void OnButtonPressedOutput(const char[] output, int caller, int activator, float delay)
{
	// 1.3.3：倒计时期间玩家抢先按下了集合点自己的机关 —— 机关已经动作，
	// 立刻把外面的人补传进来并放弃插件自己那一次按键。
	// 放在 cvar 守卫之前：即使 l4d2_cptele_mechanism_unlocked 0（本服如此），
	// 这条「防卡人」的保护也必须生效。
	if (PlayerPressedActiveMechanism(caller))
	{
		return;
	}

	if (!g_cvMechanismUnlocked.BoolValue)
	{
		return;
	}

	RegisterMechanism(caller, activator);
}

public void OnButtonUseLocked(const char[] output, int caller, int activator, float delay)
{
	RegisterMechanism(caller, activator);
}

void RegisterMechanism(int caller, int activator)
{
	if (!g_bMapStarted || !g_bReady || !g_cvEnable.BoolValue || !g_cvMechanism.BoolValue)
	{
		return;
	}

	if (caller <= 0 || caller > GetMaxEntities() || !IsValidEntity(caller))
	{
		return;
	}

	char sClass[64];

	if (!GetEntityClassname(caller, sClass, sizeof(sClass)))
	{
		return;
	}

	if (!StrEqual(sClass, "func_button"))
	{
		return;
	}

	// 预设 / 原版地点已经给了本图的集合点，就不要再加一个竞争的
	if (g_bSiteAuthority)
	{
		if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 本图集合点已由预设/原版地点提供，忽略动态按钮登记 (func_button #%d)", caller);
		}

		return;
	}

	int index = AddArea(caller, AREA_CHECKPOINT, SRC_AUTO, NULL_VECTOR, 0.0, NULL_VECTOR, false);

	if (index == -1)
	{
		// 已经登记过（同一按钮被反复按），交给监控 timer 处理
		EnsureMonitor();
		return;
	}

	// 首次登记：保证监控 timer 在跑（本图可能一个静态区域都没侦测到）
	EnsureMonitor();

	if (g_cvVerbose.BoolValue)
	{
		float vPos[3];
		GetEntityCenter(caller, vPos);
		PrintToServer("[cptele] 注册机关集合点 #%d (func_button #%d @ %.0f %.0f %.0f)",
			index, caller, vPos[0], vPos[1], vPos[2]);
	}

	if (g_cvChat.BoolValue && activator > 0 && activator <= MaxClients && IsClientInGame(activator))
	{
		PrintToChatAll("\x05[集合点]\x01 机关按钮已被按下，需要 %d%% 的生还者到场（%d 秒倒计时）。",
			g_cvCpPercent.IntValue, g_cvCpTime.IntValue);
	}
}

// ===========================================================================
//  监控 + 倒计时
// ===========================================================================

public Action Timer_Monitor(Handle timer)
{
	if (!g_bMapStarted)
	{
		g_hMonitor = null;
		return Plugin_Stop;
	}

	if (!g_bReady || !g_cvEnable.BoolValue)
	{
		return Plugin_Continue;
	}

	// 是否处于逃离阶段：安全屋 / 集合点没必要再集合。
	// 但救援关正是「逃离阶段车辆到位后」才需要把掉队的传过去，
	// 所以这一条只对非救援区域生效（在下面的循环里逐区域判断）。
	// 1.2.7：这一行提到守卫之前算，因为下面的「进入区域提示」也要用它判断可见性。
	bool bEscape = g_bNtvEscape && L4D_IsFinaleEscapeInProgress();

	// 1.2.7 需求：有生还者「首次进入」某个集合区域时，向全服提示可触发传送。
	// 1.2.9：实际调用点挪到本函数末尾的「倒计时判定」之后（见那里的注释）。
	//        倒计时期间仍然每秒调用一次，但那时 UpdateEnterNotices 只静默更新
	//        在场状态、不播报（用户需求：倒计时期间不显示进入提示）。
	// 本函数只做提示，不碰倒计时 / 传送逻辑。
	if (g_bCountingDown || g_iAreaCount == 0)
	{
		// 倒计时期间由倒计时 timer 负责判人，这里不重复判；
		// 但进入提示的在场状态必须继续跟踪，否则倒计时结束会出现「集体进入」
		// 的假跳变并一次性刷屏（1.2.9 的「静默但不丢状态」硬约束）。
		UpdateEnterNotices(bEscape);

		return Plugin_Continue;
	}

	int total = CountAliveSurvivors();

	if (total <= 0)
	{
		return Plugin_Continue;
	}

	for (int i = 0; i < g_iAreaCount; i++)
	{
		if (g_bAreaFired[i])
		{
			continue;
		}

		// 中途集合点：倒计时开始前就要开始累积「到过」标记，
		// 这样「倒计时期间已经走过集合点、跑到前面去」的人不会被传送回来。
		if (g_cvSkipSeen.BoolValue && g_iAreaType[i] == AREA_CHECKPOINT)
		{
			MarkSeenInArea(i);
		}

		if (GetGameTime() < g_fAreaCooldown[i])
		{
			continue;
		}

		if (!IsAreaAlive(i))
		{
			continue;
		}

		if (g_iAreaType[i] == AREA_RESCUE)
		{
			// 救援车到位之前，终局战斗里那座区域的触发器没有任何意义，
			// 提前触发会把正在打坦克的人直接传走。
			// bEscape 兜底：插件晚加载 / 漏接 finale_vehicle_ready 时，
			// 「逃离阶段已开始」本身就说明救援车已经到位了。
			if (!g_bRescueReady && !bEscape)
			{
				continue;
			}
		}
		else if (bEscape)
		{
			continue;
		}

		// 安全屋/救援点与中途集合点用不同的到齐比例，必须逐区域算
		int need = AreaRequiredCount(g_iAreaType[i], total);
		int reached = CountArrivedSurvivors(i);

		if (reached >= need)
		{
			/* 1.3.8（玩家反馈 c1m1「人还没走到电梯集合点倒计时就开始了」）：
			 * 比例达标还不够 —— 半径判定的集合点会因为半径写成 600 而把整片
			 * 电梯厅外面的走廊/上层平台都圈进来（不认墙、不认楼层），12 人局
			 * 只要 6 人正好路过那片区域就起倒计时。
			 * 这里再要求「至少 1 名存活生还者真的在机关身边」（核心半径内），
			 * 才允许起倒计时。方框 / 触发体积类区域判定本身就是精确体积，
			 * 不需要这道门槛（g_bAreaBox / !g_bAreaRadius）。
			 * 门槛只作用于「起倒计时那一刻」，倒计时期间的暂停逻辑
			 * （l4d2_cptele_pause_when_empty）与结算逻辑完全不变。 */
			if (!HasCoreSurvivor(i))
			{
				if (g_cvVerbose.BoolValue)
				{
					PrintToServer("[cptele] 区域 #%d 比例已达标（%d/%d 需要 %d），但核心半径 %.0f 内没有生还者，暂不起倒计时",
						i, reached, total, need, g_cvCpCoreRadius.FloatValue);
				}

				continue;
			}

			StartCountdown(i, reached, total);
			break;
		}
	}

	// 1.2.9：进入提示放到倒计时判定**之后**。
	// 这一 tick 如果刚好开始跑倒计时，g_bCountingDown 已经是 true，本 tick 就
	// 不会再播一条「N/M 名生还者已进入…」；这条信息由 StartCountdown 自己的
	// 首播给出（文案完全相同），因此同一秒不会出现两条一模一样的话。
	// 反过来，本函数在倒计时期间也照常被调用 —— 只静默更新在场状态，不播报。
	UpdateEnterNotices(bEscape);

	return Plugin_Continue;
}

/**
 * 1.2.7：有人「首次进入」集合区域时的全服提示。
 *
 * 只做状态跟踪 + 播报，不做任何传送 / 计时：
 *   - 逐区域 × 逐玩家记录上一 tick 是否在区域内，只在「不在 -> 在」跳变那一次播报，
 *     所以不会每 tick 刷屏，同一玩家同一次进入也只播一次。
 *   - 多人几乎同时进入时，本 tick 只要有新人进来就用「当前已进入人数」播一次，
 *     天然就是「按人数变化逐次提示」。
 *   - 同一玩家 3 秒内反复进出同一区域（站在触发体积 / 半径边界上抖动）只播第一次。
 *   - 区域刚被侦测出来的那一刻，已经在里面的人算「侦测前就在场」，只静默登记不播报。
 *   - 1.2.8：该区域本回合已经触发过传送（g_bAreaFired）之后**仍然照常播报**。
 *     1.2.7 曾把 g_bAreaFired 当静默条件，等于「触发一次 = 本回合再也不提示」，
 *     正是用户报的现象；现在只有「区域实体已经消失」才静默。
 *   - 1.2.8：插件自己把人传进区域的那一次不算「走进来」，由
 *     SuppressEnterNoticeForTeleport 在传送后预先登记，不会紧跟倒计时结束提示
 *     再刷一条「N/N 名生还者已进入…」。
 *   - 1.2.9（需求：倒计时期间不显示进入提示）：从倒计时开始到结束（含被取消 /
 *     提前结束）之间**一条都不播**，聊天框与 PrintHintTextToAll 两条通道都不发；
 *     但 g_bAreaPresence 仍然每秒照常更新 ——「静默但不丢状态」是硬约束，跳过
 *     更新会让倒计时结束时把整段倒计时里的进入当成一次集体跳变，反而刷屏。
 *     结束 / 取消那一刻由 SyncEnterNoticePresence 再按真实在场情况同步一次，
 *     跨过结束边界的那一次进入也不会补播。
 *
 * 由 Timer_Monitor 每秒调用一次（g_bCountingDown 期间也调用，但那时不播报）。
 *
 * @param bEscape   本帧是否处于逃离阶段（与 Timer_Monitor 的可见性规则共用）
 */
void UpdateEnterNotices(bool bEscape)
{
	if (!g_cvEnterNotice.BoolValue || g_iAreaCount == 0)
	{
		return;
	}

	int total = CountAliveSurvivors();

	if (total <= 0)
	{
		return;
	}

	float fNow = GetGameTime();

	for (int i = 0; i < g_iAreaCount; i++)
	{
		// 1.2.8：只有「区域实体已经消失」才静默。
		// 1.2.7 这里还带着 g_bAreaFired[i]，而它只在倒计时结束时被置 true、
		// 且只有换回合才会清 —— 结果一旦触发过传送，本回合剩下的时间里再走进
		// 集合区域就再也不提示（用户报的现象）。
		// 现在已触发过的区域照常播报，频率仍是「不在 -> 在」跳变播一次。
		// 静默不等于不记录：下面照样更新 g_bAreaPresence，区域恢复时不会「集体进入」。
		//
		// 1.2.9：倒计时期间同样静默（用户需求：触发传送倒计时后不再播进入提示，
		// 否则倒计时提示与「N/M 名生还者已进入…」两条通道互相刷屏）。
		// 这里**只**关播报，下面的 g_bAreaPresence 更新一律照常执行 ——
		// 少了那一步，倒计时结束时会出现「集体进入」的假跳变并一次性刷屏。
		bool bQuiet = g_bCountingDown || !IsAreaAlive(i);

		if (!bQuiet)
		{
			// 与 Timer_Monitor 的可见性规则保持一致：
			// 逃离阶段不提示非救援区域；救援车没到位时不提示救援区域。
			if (g_iAreaType[i] == AREA_RESCUE)
			{
				bQuiet = (!g_bRescueReady && !bEscape);
			}
			else
			{
				bQuiet = bEscape;
			}
		}

		// 区域第一次参与判定：这一刻已经在区域里的人属于「侦测前就在场」，
		// 不是「走进来」，只静默登记。
		if (!g_bAreaNoticePrimed[i])
		{
			g_bAreaNoticePrimed[i] = true;
			bQuiet = true;
		}

		int reached = 0;
		int announced = 0;

		for (int c = 1; c <= MaxClients; c++)
		{
			bool bIn = IsAliveSurvivor(c) && IsClientInArea(c, i);

			if (bIn)
			{
				reached++;
			}

			if (!bIn)
			{
				g_bAreaPresence[i][c] = false;
				continue;
			}

			if (g_bAreaPresence[i][c])
			{
				continue;
			}

			// 这一刻是「不在 -> 在」的跳变 = 一次进入
			g_bAreaPresence[i][c] = true;

			if (bQuiet)
			{
				continue;
			}

			// 边界抖动抑制：同一玩家短时间内重复「进入」同一区域不重复播报
			if (fNow - g_fAreaEnterAt[i][c] < ENTER_NOTICE_REPEAT)
			{
				continue;
			}

			g_fAreaEnterAt[i][c] = fNow;
			announced++;
		}

		if (announced > 0)
		{
			AnnounceAreaEnter(i, reached, total);
		}
	}
}

/**
 * 播报「有生还者进入集合区域」：聊天框 + 屏幕下方居中提示，内容格式固定。
 *
 *   聊天：\x05[集合点]\x01 %d/%d 名生还者已进入%s（需要 %d 名触发传送）
 *   屏幕：同文案纯文本（PrintHintTextToAll 不支持颜色转义）
 *
 * %d/%d = 已进入人数 / 当前存活生还者数（与倒计时判定同一口径）；
 * %s     = 区域名（安全屋 / 救援点 / 集合点，取 GetAreaTypeName）；
 * 末尾 %d = 触发传送所需人数（AreaRequiredCount）。
 */
void AnnounceAreaEnter(int index, int reached, int total)
{
	int type = g_iAreaType[index];
	int need = AreaRequiredCount(type, total);

	char sName[32];
	char sMsg[192];

	GetAreaTypeName(type, sName, sizeof(sName));

	/* 1.2.8：本区域本回合**已经触发过传送**（g_bAreaFired）之后，进入提示照常播报，
	   但文案不能再写"（需要 %d 名触发传送）" —— 这个区域本回合不会再触发倒计时了，
	   写"需要 N 名"会让玩家以为还要继续集合。改成直接说明已触发过。 */
	bool bFired = (index >= 0 && index < MAX_AREAS && index < g_iAreaCount) ? g_bAreaFired[index] : false;

	if (bFired)
	{
		if (g_cvChat.BoolValue)
		{
			PrintToChatAll("\x05[集合点]\x01 %d/%d 名生还者已进入%s（本集合点本回合已触发过传送）",
				reached, total, sName);
		}

		Format(sMsg, sizeof(sMsg), "[集合点] %d/%d 名生还者已进入%s（本集合点本回合已触发过传送）",
			reached, total, sName);

		PrintHintTextToAll("%s", sMsg);

		if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 进入提示（已触发过传送）：区域 #%d (type=%d) reached=%d total=%d",
				index, type, reached, total);
		}

		return;
	}

	if (g_cvChat.BoolValue)
	{
		PrintToChatAll("\x05[集合点]\x01 %d/%d 名生还者已进入%s（需要 %d 名触发传送）",
			reached, total, sName, need);
	}

	Format(sMsg, sizeof(sMsg), "[集合点] %d/%d 名生还者已进入%s（需要 %d 名触发传送）",
		reached, total, sName, need);

	PrintHintTextToAll("%s", sMsg);

	if (g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] 进入提示：区域 #%d (type=%d) reached=%d total=%d need=%d",
			index, type, reached, total, need);
	}
}

void StartCountdown(int index, int reached, int total)
{
	if (g_bCountingDown)
	{
		return;
	}

	if (index < 0 || index >= g_iAreaCount)
	{
		return;
	}

	int type = g_iAreaType[index];
	int need = AreaRequiredCount(type, total);
	int seconds = AreaCountdownSeconds(type);

	if (seconds <= 0)
	{
		return;
	}

	g_bCountingDown = true;
	g_iActiveArea = index;
	g_iSecondsLeft = seconds;

	// 新一轮倒计时：重新记录「到过区域」的人（开局就在区域里的人算已到过）
	//
	// 中途集合点不清零：倒计时「开始之前」就已经走过集合点的人同样算到过，
	// 否则他们会在倒计时结束时被传送回集合点（正是要修的 bug）。
	// 安全屋 / 救援点必须清零：那两类区域在 round_start 时全员可能都站在里面，
	// 不清零会让「全员已到过」立刻成立、功能等于被废掉。
	if (IsSafeAreaType(g_iAreaType[index]))
	{
		ClearSeenFlags();
	}

	MarkSeenInArea(index);

	char sName[32];
	char sHint[192];

	GetAreaTypeName(type, sName, sizeof(sName));

	if (IsSafeAreaType(type))
	{
		// ---- A 组文案：安全屋 / 救援点 ----
		// 1.2.7：按用户要求把原来那条「进入 + 倒计时」长句拆成两条 ——
		// 第一条严格使用用户给定格式（不夹带任何倒计时信息），
		// 第二条只留倒计时信息。
		if (g_cvChat.BoolValue)
		{
			PrintToChatAll("\x05[集合点]\x01 %d/%d 名生还者已进入%s（需要 %d 名触发传送）",
				reached, total, sName, need);
			PrintToChatAll("\x05[集合点]\x01 %d 秒后把未进入%s的生还者传送进来。", seconds, sName);
		}

		Format(sHint, sizeof(sHint), "%d 秒后把未进入%s的生还者传送进来", seconds, sName);
	}
	else
	{
		// ---- B 组文案：地图中途集合点 ----
		// 同上：第一条严格用户格式，第二条只留倒计时信息。
		if (g_cvChat.BoolValue)
		{
			PrintToChatAll("\x05[集合点]\x01 %d/%d 名生还者已进入%s（需要 %d 名触发传送）",
				reached, total, sName, need);
			PrintToChatAll("\x05[集合点]\x01 %d 秒后传送未到集合点的生还者并开启机关。", seconds);
		}

		Format(sHint, sizeof(sHint), "%d 秒后传送未到集合点的生还者", seconds);
	}

	PrintHintTextToAll("%s", sHint);

	if (g_cvSound.BoolValue)
	{
		EmitCountdownSound();
	}

	if (g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] 区域 #%d 开始倒计时 (type=%d source=%d reached=%d total=%d need=%d seconds=%d)",
			index, type, g_iAreaSource[index], reached, total, need, seconds);
	}

	delete g_hCountdown;
	g_hCountdown = CreateTimer(1.0, Timer_Countdown, 0,
		TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_Countdown(Handle timer)
{
	if (!g_bCountingDown)
	{
		g_hCountdown = null;
		return Plugin_Stop;
	}

	int index = g_iActiveArea;

	if (index < 0 || index >= g_iAreaCount)
	{
		CancelCountdown(-1);
		g_hCountdown = null;
		return Plugin_Stop;
	}

	int type = g_iAreaType[index];

	// 记录「本次倒计时期间到过集合点」的人：他们已完成集合这一步，
	// 倒计时结束时不再被传送回来（c5m2 这类「集合完就往前走」地图的修复点）
	MarkSeenInArea(index);

	// 1.3.0 需求（c5m2 中途集合点）：**中途集合点全员集合完毕就立刻结束倒计时**。
	// 现象：所有生还者都到过集合点、机关也被玩家自己触发之后，屏幕上还在刷
	// 「N 秒后传送未到集合点的生还者」，倒计时走满时因为全员都到过（g_cvSkipSeen）
	// 一个人都不传送，只播一条「无需传送」——纯空转。
	// 判定口径与 g_cvSkipSeen 严格一致：只有「到过就不再被传送回来」成立时，
	// 「全员都到过」才等于「没人需要传送」，所以两者都用才提前结束。
	// **只作用于 AREA_CHECKPOINT**：安全屋 / 救援点仍是 1.2.9 的「走满再结算」，
	// 1.2.5（此刻全员在屋内才算集合完毕）与 1.2.9（集合一下又散开要继续倒计时）
	// 的语义一个字都没动。
	// 提前结束后 g_bAreaFired = true，monitor 不会再为同一区域起倒计时，
	// 不会出现「结束 -> 下一秒重开」的循环。
	if (IsCheckpointGatherComplete(index, type))
	{
		FinishCheckpointGathered(index, type);
		g_hCountdown = null;
		return Plugin_Stop;
	}

	// 1.2.9 需求：安全屋 / 救援点**不再「全员到齐就提前结束倒计时」**（用户需求：
	// 集合完成又离开要接着倒计时）。
	// 1.2.0~1.2.8 在这里判「全员到过（中途集合点）/ 全员此刻在区域内（安全屋、
	// 救援点）」就调 FinishCountdownAllSeen 立刻结束倒计时，并把区域置成已触发
	// （g_bAreaFired）。于是「倒计时中途集合完毕、随后又散开去补给 / 继续推进」
	// 会把该区域本回合唯一的一次集合机会用掉：本回合不再倒计时，掉队者永远
	// 不会被传送，关底安全屋凑不齐人。
	// 现在安全屋 / 救援点倒计时一律走满，到点时由 FinishCountdown 按**那一刻**的
	// 真实情况结算：
	//   · 中途集合点：g_cvSkipSeen 的「到过就不再被传送回来」语义完全不变
	//     （FinishCountdown 里按 g_bSeen 跳过已经到过的人）；
	//   · 安全屋 / 救援点：仍然只按「此刻必须在屋里」把掉队者补传进来（1.2.5 不变）；
	//   · 全员此刻都在区域内时 moved == 0，FinishCountdown 会打
	//     「全员已进入%s，无需传送」——「全员已到齐」这条信息价值保留，
	//     只是不再抢在倒计时结束之前说出来。
	// g_bSeen 的累积仍由上面的 MarkSeenInArea 每秒做。

	// 掉回比例以下的处理策略
	if (g_cvResetOnLeave.BoolValue)
	{
		int total = CountAliveSurvivors();
		int need = AreaRequiredCount(type, total);
		int reached = CountArrivedSurvivors(index);

		if (total <= 0 || reached < need)
		{
			char sName[32];
			GetAreaTypeName(type, sName, sizeof(sName));

			if (IsSafeAreaType(type))
			{
				if (g_cvChat.BoolValue)
				{
					PrintToChatAll("\x05[集合点]\x01 到场人数降到 %d/%d（需要 %d 名），%s传送倒计时取消。",
						reached, total, need, sName);
				}

				PrintHintTextToAll("到场人数不足，%s传送倒计时取消", sName);
			}
			else
			{
				if (g_cvChat.BoolValue)
				{
					PrintToChatAll("\x05[集合点]\x01 到场人数降到 %d/%d（需要 %d 名），集合点传送倒计时取消。",
						reached, total, need);
				}

				PrintHintTextToAll("到场人数不足，集合点传送倒计时取消");
			}

			CancelCountdown(index);
			g_hCountdown = null;
			return Plugin_Stop;
		}
	}

	// 1.3.6：中途集合点里没人 → 暂停倒计时（不递减），等人进去再继续
	if (type == AREA_CHECKPOINT && g_cvPauseWhenEmpty.BoolValue
		&& CountArrivedSurvivors(index) <= 0)
	{
		char sPauseName[32];

		GetAreaTypeName(type, sPauseName, sizeof(sPauseName));
		PrintHintTextToAll("%s暂时没有生还者到场，倒计时已暂停（剩余 %d 秒）", sPauseName, g_iSecondsLeft);

		return Plugin_Continue;
	}

	// 先递减再判断，保证总时长精确等于该类型的倒计时 cvar，
	// 且不会与 StartCountdown 里那次首播重复播报同一个秒数
	g_iSecondsLeft--;

	if (g_iSecondsLeft <= 0)
	{
		FinishCountdown(index);
		g_hCountdown = null;
		return Plugin_Stop;
	}

	char sName[32];
	char sHint[192];

	GetAreaTypeName(type, sName, sizeof(sName));

	if (IsSafeAreaType(type))
	{
		Format(sHint, sizeof(sHint), "%d 秒后把未进入%s的生还者传送进来", g_iSecondsLeft, sName);
	}
	else
	{
		Format(sHint, sizeof(sHint), "%d 秒后传送未到集合点的生还者", g_iSecondsLeft);
	}

	PrintHintTextToAll("%s", sHint);

	if (g_cvSound.BoolValue)
	{
		EmitCountdownSound();
	}

	return Plugin_Continue;
}

/**
 * 1.3.0：中途集合点是不是已经「全员集合完毕」。
 *
 * 判定口径 = 本次倒计时期间「所有**当前存活**的生还者此刻都在该区域**内**」。
 *
 * 1.3.3 修正（1.3.0~1.3.2 用的是 CountSeenSurvivors() >= total，即「本次倒计时
 * 期间都**到过**」）：g_bSeen 记的是**历史上**到过的人，倒计时第 5 秒走过集合点
 * 半径、然后跑到前面去的人也算。cfg 下发 l4d2_cptele_checkpoint_percent 50
 * => 6/12 人就起 30 秒倒计时，中途 12 个人先后路过一次就满足「都到过」，
 * FinishCheckpointGathered() 立刻 OpenAreaMechanism() 把电梯/机关按下去 ——
 * 这时往往还有一半人在外面，机关一动作他们就被卡死在集合点。
 * 「到过」只能当「不需要传送」的判据（g_cvSkipSeen），不能当「机关可以开了」
 * 的判据：本函数现在要求那一刻真实在场，机关因此不可能抢在到齐之前动作。
 *
 * 三条硬约束，缺一不可：
 *   1) 只对 AREA_CHECKPOINT 生效。安全屋 / 救援点必须保持 1.2.9 的「走满再结算」：
 *      它们要的是「此刻全员在屋内」（1.2.5），提前结束会让掉队者留在门外、
 *      关门状态机也不启动，正是 1.2.5 / 1.2.9 修过的那两个 bug。
 *   2) l4d2_cptele_checkpoint_finish_all_seen = 0 时完全走旧行为（走满再结算）。
 *   3) l4d2_cptele_skip_seen = 0 时不生效：那种模式下「到过」不再等于
 *      「不需要传送」，提前结束会把"到过又离开"的人漏在外面，语义自相矛盾。
 *
 * @param index 区域索引
 * @param type  区域类型
 * @return true = 集合完毕，可以立刻结束倒计时
 */
bool IsCheckpointGatherComplete(int index, int type)
{
	if (index < 0 || index >= g_iAreaCount)
	{
		return false;
	}

	if (type != AREA_CHECKPOINT)
	{
		return false;
	}

	if (!g_cvCpFinishAllSeen.BoolValue || !g_cvSkipSeen.BoolValue)
	{
		return false;
	}

	int total = CountAliveSurvivors();

	if (total <= 0)
	{
		return false;
	}

	// 1.3.3：必须是「此刻全员都在区域内」，不是「本次倒计时期间都到过」。
	// 只有这样才能保证 FinishCheckpointGathered -> OpenAreaMechanism 按下机关时
	// 没有人在外面被卡住。
	return CountArrivedSurvivors(index) >= total;
}

/**
 * 1.3.0：中途集合点「全员集合完毕」的收尾 —— 结束倒计时，一个人都不传送。
 *
 * 与 FinishCountdown 的区别（为什么不直接复用它）：
 *   · FinishCountdown 要多走一整轮传送判定（逐人算 IsClientInArea / g_bSeen /
 *     固定传送点抖动）再得出 moved == 0；这里已经确定「没人需要传送」，
 *     不需要那套判定，也就不会误碰安全屋关门状态机（ScheduleSaferoomDoorFix
 *     只在 moved > 0 时启动）。
 *   · 播报文案不同：这里是「全员已集合完毕，倒计时结束」，不是倒计时走满之后
 *     的「全员已到达集合点，无需传送」——用户能一眼看出是集合完毕主动收的。
 *
 * 收尾动作与 FinishCountdown 保持一致的部分：
 *   · g_bAreaFired = true：本回合该集合点不再起倒计时（monitor 会跳过），
 *     避免「结束 -> 下一秒重开」的循环；
 *   · SyncEnterNoticePresence：跨过结束边界的那一次进入不补播（1.2.9 约束）；
 *   · OpenAreaMechanism：机关照常开（电梯按钮这类地图靠这一步才走得了）。
 *
 * @param index 区域索引（调用方已校验范围）
 * @param type  区域类型
 */
void FinishCheckpointGathered(int index, int type)
{
	g_bCountingDown = false;
	g_iSecondsLeft = 0;
	g_iActiveArea = -1;
	g_bAreaFired[index] = true;

	SyncEnterNoticePresence(index);

	/* 1.3.4：半径判定（l4d2_cptele_mech_radius）会把离机关几百单位的队友也算成
	 * "已在集合点"，于是这里会在人还没真到齐时就开机关。开启全员传送时，先把
	 * 所有人都拉到落点，再开机关。 */
	if (type == AREA_CHECKPOINT && g_cvCpTeleportAll.BoolValue)
	{
		float vDest[3];

		if (GetCheckpointPoint(index, vDest))
			TeleportStragglersToArea(index, vDest, false, true);
	}

	OpenAreaMechanism(index, type);

	char sMsg[192];

	if (g_cvChat.BoolValue)
	{
		PrintToChatAll("\x05[集合点]\x01 全员已集合完毕，集合传送倒计时结束，无需传送。");
	}

	Format(sMsg, sizeof(sMsg), "全员已集合完毕，传送倒计时结束");
	PrintHintTextToAll("%s", sMsg);

	if (g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] 区域 #%d 全员集合完毕，倒计时提前结束 (type=%d source=%d 到过=%d 存活=%d)",
			index, type, g_iAreaSource[index], CountSeenSurvivors(), CountAliveSurvivors());
	}
}

void CancelCountdown(int index)
{
	g_bCountingDown = false;
	g_iSecondsLeft = 0;
	g_iActiveArea = -1;

	if (index >= 0 && index < g_iAreaCount)
	{
		g_fAreaCooldown[index] = GetGameTime() + CANCEL_COOLDOWN;

		// 1.2.9：倒计时一取消，进入提示立刻恢复播报。先按此刻真实在场情况同步
		// 一次，倒计时期间走进来的生还者不会被下一 tick 当成「集体进入」补播。
		SyncEnterNoticePresence(index);
	}

	if (g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] 倒计时取消 (区域 #%d)", index);
	}
}

void FinishCountdown(int index)
{
	if (index < 0 || index >= g_iAreaCount)
	{
		g_bCountingDown = false;
		g_iSecondsLeft = 0;
		g_iActiveArea = -1;
		return;
	}

	g_bCountingDown = false;
	g_iSecondsLeft = 0;
	g_iActiveArea = -1;
	g_bAreaFired[index] = true;

	// 1.2.9：倒计时结束 = 进入提示恢复播报。先按此刻真实在场情况同步一次，
	// 免得倒计时期间走进来的生还者在下一 tick 被当成「集体进入」补播一条
	// （本次传送进区域的那些人，下面还会逐个 SuppressEnterNoticeForTeleport）。
	SyncEnterNoticePresence(index);

	int type = g_iAreaType[index];

	// 1.3.3：本区域的机关是不是「插件按下按钮」那种（电梯 / 升降台）。
	// 这种机关一动作，留在区域外的生还者就再也进不来了，所以传送口径要更严：
	// 必须把所有人拉进来再谈开机关，g_cvSkipSeen 的「到过就不再拉回来」在这里让位。
	bool bButtonMech = HasButtonMechanism(index, type);

	float vDest[3];
	bool bForceAll = (type == AREA_CHECKPOINT && g_cvCpTeleportAll.BoolValue);
	bool bHasDest = bForceAll ? GetCheckpointPoint(index, vDest) : GetAreaDestination(index, vDest);
	int moved = 0;

	if (bHasDest)
	{
		/* 全员传送：不管谁在哪、到过没到过，一律传到集合点落点，然后才开机关。 */
		moved = TeleportStragglersToArea(index, vDest, bForceAll ? false : !bButtonMech, bForceAll);
	}

	// ---- 开机关 ---------------------------------------------------------
	OpenAreaMechanism(index, type);

	// ---- 关底安全屋：门没经历「开 -> 关」就不过关（1.2.1 / 需求 #7）-------
	// 1.2.4（需求 #6 回归修复）：触发条件收回成「本次倒计时 **真的传送了人**（moved > 0）」。
	// 1.2.3 曾放宽为 `moved > 0 || CountArrivedSurvivors(index) > 0`，等于「只要有人站在
	// 判定体积里就动门」。这在终局图（c6m3_port 电梯下来到罐油发电机那一片）会把玩家
	// 正常路过当成「全员进安全屋」，进而关门+补发 CheckpointDoorClosed => 直接结算换边。
	// 只有「倒计时传送过掉队者」这一种情况才需要我们补引擎缺的那两次门状态变化；
	// 玩家自己走进去时，门是他们自己开合的，引擎链路本来是通的。
	if (moved > 0)
	{
		ScheduleSaferoomDoorFix(index);
	}

	if (g_cvRemoveInfected.BoolValue && bHasDest)
	{
		RemoveInfectedAround(vDest);
	}

	char sName[32];
	char sMsg[192];

	GetAreaTypeName(type, sName, sizeof(sName));

	if (moved <= 0)
	{
		// 一个都没传送：要么全员都到过，要么压根拿不到传送目标
		if (!bHasDest)
		{
			// 区域实体在倒计时期间消失 / 拿不到 nav area：不能假装"无需传送"
			LogError("[cptele] 区域 #%d (%s) 拿不到传送目标，本次未传送任何生还者", index, sName);

			if (g_cvChat.BoolValue)
			{
				PrintToChatAll("\x05[集合点]\x01 倒计时结束，但找不到%s的传送位置，本次不传送。", sName);
			}

			Format(sMsg, sizeof(sMsg), "找不到%s的传送位置，本次不传送", sName);
		}
		else
		{
			// 1.2.9：倒计时**自然走满**时无人需要传送 —— 要么全员此刻都在区域内
			// （安全屋 / 救援点），要么中途集合点全员都到过（g_cvSkipSeen 语义）。
			// 这条「全员已到齐，无需传送」的结算统一交给 FinishCountdownAllSeen：
			// 它现在只负责播报，不再结束倒计时、不再改 g_bAreaFired / 不动机关与门。
			FinishCountdownAllSeen(index);

			if (g_cvVerbose.BoolValue)
			{
				PrintToServer("[cptele] 区域 #%d 完成 (type=%d source=%d moved=0 dest=1)",
					index, type, g_iAreaSource[index]);
			}

			return;
		}
	}
	else if (IsSafeAreaType(type))
	{
		if (g_cvChat.BoolValue)
		{
			PrintToChatAll("\x05[集合点]\x01 倒计时结束，已把 %d 名生还者传送到%s。", moved, sName);
		}

		Format(sMsg, sizeof(sMsg), "已把 %d 名生还者传送到%s", moved, sName);
	}
	else
	{
		if (g_cvChat.BoolValue)
		{
			PrintToChatAll("\x05[集合点]\x01 倒计时结束，已把 %d 名生还者传送到集合点。", moved);
		}

		Format(sMsg, sizeof(sMsg), "已把 %d 名生还者传送到集合点", moved);
	}

	PrintHintTextToAll("%s", sMsg);

	if (g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] 区域 #%d 完成 (type=%d source=%d moved=%d dest=%d)",
			index, type, g_iAreaSource[index], moved, bHasDest);
	}
}

// ===========================================================================
//  1.3.3：机关前置条件 / 补传 / 玩家抢按接管
// ===========================================================================

/**
 * 1.3.3：本区域是不是「由插件按下按钮」来开机关的集合点。
 *
 * 只有这种区域才需要「按下之前必须全员到齐」的额外约束：按钮一按，电梯 / 升降台
 * 立刻动作，外面的人再也进不来。坐标型区域（c6m3）和触发体积型（c5m2）的
 * OpenAreaMechanism() 本来就是空操作，不存在卡人的问题。
 *
 * @param index 区域索引
 * @param type  区域类型
 * @return true = 中途集合点 + 实体是按钮类
 */
bool HasButtonMechanism(int index, int type)
{
	if (type != AREA_CHECKPOINT)
	{
		return false;
	}

	int entity = GetAreaEntity(index);

	if (entity == -1)
	{
		return false;
	}

	char sClass[64];

	return GetEntityClassname(entity, sClass, sizeof(sClass)) && IsButtonClass(sClass);
}

/**
 * 1.3.3：此刻还有多少名存活生还者不在该区域内。
 * 用于「机关能不能按」的判定（> 0 就不能按）。
 */
int CountSurvivorsOutside(int index)
{
	int count = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsAliveSurvivor(i) && !IsClientInArea(i, index))
		{
			count++;
		}
	}

	return count;
}

/**
 * 1.3.3：把仍在区域外的存活生还者传送到 vDest。
 *
 * 从 FinishCountdown() 里抽出来，让两条路径共用同一套落点 / 抖动 / 提示抑制逻辑：
 *   · FinishCountdown()            —— 倒计时正常走满；
 *   · PlayerPressedActiveMechanism() —— 倒计时期间玩家抢先按下了机关。
 *
 * @param index        区域索引
 * @param vDest        落点（调用方已用 GetAreaDestination 拿到）
 * @param bRespectSeen true = 尊重 g_cvSkipSeen（本次倒计时期间「到过」的人不拉回来）
 * @return 实际传送人数
 */
int TeleportStragglersToArea(int index, const float vDest[3], bool bRespectSeen, bool bForceAll = false)
{
	// 本次倒计时期间已经到过集合点的人：视为已集合完毕，
	// 不再把人从前方传送回来（这就是「集合完就往前走」的修复点）
	// 1.2.5：安全屋 / 救援点例外 —— 那边要的是"此刻人在屋里"，
	// 进过又跑出去的掉队者必须被传回来，否则关门时引擎逐个 IsTouching
	// 会发现"还有人在外面"而中止过关（玩家只能自己再开关一次门）。
	bool bSkipSeen = bRespectSeen && !IsSafeAreaType(g_iAreaType[index]) && g_cvSkipSeen.BoolValue;

	// 固定传送点要「每人一份抖动」：12v12 最多 11 个掉队的
	// 同时落地，全挤在一个坐标上会互相挤出去 / 卡进几何体。
	bool bFixedDest = g_bAreaDest[index];
	int moved = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsAliveSurvivor(i))
		{
			continue;
		}

		/* bForceAll：不管判定结果，全员都拉到落点（集合点专用） */
		if (!bForceAll && IsClientInArea(i, index))
		{
			continue;
		}

		if (!bForceAll && bSkipSeen && g_bSeen[i])
		{
			continue;
		}

		float vClientDest[3];

		CopyVec(vDest, vClientDest);

		if (bFixedDest || bForceAll)
		{
			/* 全员传送时落点是同一个 nav 点，必须给每个人散开，否则 12 个人叠一起 */
			vClientDest[0] += GetRandomFloat(-DEST_JITTER, DEST_JITTER);
			vClientDest[1] += GetRandomFloat(-DEST_JITTER, DEST_JITTER);
		}

		TeleportSurvivor(i, vClientDest);

		// 1.2.8：这一次进入是插件传送造成的，不算玩家自己「走进来」，
		// 登记成已在区域内，避免倒计时结束提示之后再多播一条进入提示。
		SuppressEnterNoticeForTeleport(index, i);

		moved++;
	}

	return moved;
}

/**
 * 1.3.3：倒计时期间玩家抢先按下了集合点自己的机关按钮。
 *
 * 这是「机关已动作、人还在外面」最直接的来源：引擎不等插件，按钮一按，电梯 /
 * 升降台立刻就动了，倒计时结束后插件再按一次也补不回来。
 * 处理方式（需求给的两个选项里取后者）：
 *   1) 终止本区域倒计时，并且**不再**由插件补按机关 —— 机关已经动作，
 *      重复按下只会让电梯再来一次 / 状态错乱；
 *   2) 立刻把仍在区域外的存活生还者传送到集合点，并且**无视 g_cvSkipSeen**
 *      （「到过又离开」的人留在原地就是被卡死）；
 *   3) g_bAreaFired = true，本回合不再为该区域起倒计时（放弃后续触发）。
 *
 * 只在「本区域正在倒计时」时接管：比例没到之前谁按地图上的按钮都不算，
 * 否则一个先到的生还者按一下电梯按钮就会把全队传过来。
 *
 * @param caller 被按下的 func_button 实体索引
 * @return true = 已接管（调用方不要再走机关登记）
 */
bool PlayerPressedActiveMechanism(int caller)
{
	if (!g_cvEnable.BoolValue || !g_bCountingDown)
	{
		return false;
	}

	if (g_iActiveArea < 0 || g_iActiveArea >= g_iAreaCount)
	{
		return false;
	}

	int index = g_iActiveArea;

	if (GetAreaEntity(index) != caller)
	{
		return false;
	}

	int type = g_iAreaType[index];

	g_bCountingDown = false;
	g_iSecondsLeft = 0;
	g_iActiveArea = -1;
	g_bAreaFired[index] = true;

	// 倒计时一结束，进入提示立刻恢复播报：先按此刻真实在场情况同步一次。
	SyncEnterNoticePresence(index);

	float vDest[3];
	int moved = 0;

	if (GetAreaDestination(index, vDest))
	{
		moved = TeleportStragglersToArea(index, vDest, false);
	}

	char sName[32];
	GetAreaTypeName(type, sName, sizeof(sName));

	if (g_cvChat.BoolValue)
	{
		if (moved > 0)
		{
			PrintToChatAll("\x05[集合点]\x01 机关已被提前按下，已把 %d 名生还者传送到%s，本次不再自动开机关。",
				moved, sName);
		}
		else
		{
			PrintToChatAll("\x05[集合点]\x01 机关已被提前按下，本次不再自动开机关。");
		}
	}

	if (g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] 区域 #%d 倒计时期间机关被玩家按下：终止倒计时并补传 %d 人 (type=%d source=%d 仍在外面=%d)",
			index, moved, type, g_iAreaSource[index], CountSurvivorsOutside(index));
	}

	return true;
}

/**
 * 「无人需要传送」的收尾播报：倒计时自然走满时全员都在区域内 / 全员都到过。
 *
 * 1.2.9 的语义变更（用户需求：集合完成又离开要继续倒计时）：
 *   - 1.2.0~1.2.8：本函数在倒计时中途判定「全员到齐」时被调用，**直接结束倒计时**
 *     并把区域标记成已触发（g_bAreaFired = true），本回合不再倒计时；
 *     结果「集合完就走」的人把区域用掉了，掉队者再也不会被传送，安全屋凑不齐人。
 *   - 1.2.9 起：那条提前结束的路径已删除。本函数不再是「结束器」，只是
 *     FinishCountdown 在倒计时走满、moved == 0（此刻无需传送）时调用的播报收尾：
 *     不再改 g_bCountingDown / g_iSecondsLeft / g_iActiveArea / g_bAreaFired，
 *     也不再动机关与安全门 —— 这些统一由 FinishCountdown 处理（机关已在它里面
 *     按过一次，这里再按一次会让按钮重复触发）。
 *
 * 保留本函数（而不是删掉）的理由：
 *   · 「全员已到齐，无需传送」这条信息与 FinishCountdown 的「已把 N 名生还者
 *     传送过去」并列，文案只保留在这一处，不会随两处代码漂移；
 *   · 函数仍然被 FinishCountdown 调用，不会产生 warning 203（symbol is never used）。
 *
 * @param index 区域索引（调用方 FinishCountdown 已校验过范围）
 */
void FinishCountdownAllSeen(int index)
{
	if (index < 0 || index >= g_iAreaCount)
	{
		return;
	}

	int type = g_iAreaType[index];

	char sName[32];
	char sMsg[192];

	GetAreaTypeName(type, sName, sizeof(sName));

	if (IsSafeAreaType(type))
	{
		if (g_cvChat.BoolValue)
		{
			PrintToChatAll("\x05[集合点]\x01 倒计时结束，全员已进入%s，无需传送。", sName);
		}

		Format(sMsg, sizeof(sMsg), "全员已进入%s，无需传送", sName);
	}
	else
	{
		if (g_cvChat.BoolValue)
		{
			PrintToChatAll("\x05[集合点]\x01 倒计时结束，全员已到达集合点，无需传送。");
		}

		Format(sMsg, sizeof(sMsg), "全员已到达集合点，无需传送");
	}

	PrintHintTextToAll("%s", sMsg);

	if (g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] 区域 #%d 全员到齐（倒计时自然结束，无需传送）(type=%d source=%d 到过=%d 此刻在区域内=%d 存活=%d)",
			index, type, g_iAreaSource[index],
			CountSeenSurvivors(), CountArrivedSurvivors(index), CountAliveSurvivors());
	}
}

/**
 * 倒计时结束时要开的机关。
 * 只对「按钮类」实体做 unlock+use：就算管理员误把门写进预设，
 * 这里也不会去动任何门（尤其是安全门）的 lock 状态。
 * 与 alasfourom "L4D Elevator Teleport" 一致：先解锁再按下。
 */
void OpenAreaMechanism(int index, int type)
{
	if (type == AREA_CHECKPOINT)
	{
		int entity = GetAreaEntity(index);

		if (entity == -1)
		{
			return;
		}

		char sClass[64];

		if (GetEntityClassname(entity, sClass, sizeof(sClass)) && IsButtonClass(sClass))
		{
			// 1.3.3：机关（电梯按钮 / 升降台开关）一按就动作，按下那一刻还站在
			// 外面的生还者就再也进不来了 —— 用户报的「机关提前触发、一堆人被卡在
			// 集合点」正是这条路。所以按下之前必须确认此刻**全员**都在区域内。
			//
			// unlock 无论如何都发：被 spawnflags 锁住的按钮只有解锁后玩家才能按，
			// 「不自动按」不等于「让人按不了」，后者才会真的把队伍卡死。
			AcceptEntityInput(entity, "unlock");

			int outside = CountSurvivorsOutside(index);

			if (outside > 0)
			{
				char sTypeName[32];
				GetAreaTypeName(type, sTypeName, sizeof(sTypeName));

				LogError("[cptele] 区域 #%d (%s) 仍有 %d 名存活生还者在区域外，已解锁但不自动按下机关",
					index, sTypeName, outside);

				if (g_cvChat.BoolValue)
				{
					PrintToChatAll("\x05[集合点]\x01 还有 %d 名生还者未到%s，本次不自动开启机关（可手动按下按钮）。",
						outside, sTypeName);
				}

				return;
			}

			AcceptEntityInput(entity, "use");
		}
	}
	else if (type == AREA_RESCUE && g_cvRescueForce.BoolValue && g_bNtvRescueVehicle)
	{
		// 默认关闭：救援车人齐由游戏自己触发
		L4D2_SendInRescueVehicle();
	}

	// AREA_SAFEROOM：什么都不做。绝不触碰安全门的 spawnflags / lock 状态。
	// 1.2.1：安全门「关着导致不过关」的问题不在这里处理，而是传送全部落位后
	// 由 ScheduleSaferoomDoorFix 复核一次安全门状态（只发标准 Open 输入，
	// 同样不改 spawnflags / lock，不解锁、不锁门）。
}

// ===========================================================================
//  关底安全门状态修复（1.2.1 / 需求 #7；1.2.3 改为状态机）
// ===========================================================================
//
//  为什么需要这一整块（引擎侧的根因，三条都已在 server.dll 的 datamap 上核对过）：
//    ① 过关不是插件判定的，是引擎 info_changelevel 实体的流程。datamap 里
//       info_changelevel 带 CheckpointDoorOpened / CheckpointDoorClosed 两个实体输入，
//       引擎 InfoChangelevel::OnCheckpointDoorClosed 里还会逐个用 CBaseTrigger::IsTouching
//       判「谁还在安全屋外面」，然后才走 ChangelevelThink 换图。
//    ② 也就是说过关是**由安全门的状态变化驱动**的：门一直不动 -> 两个输入一次都不来
//       -> 人虽然被传送进屋，引擎根本不会开始过关判定。
//    ③ 正常游戏里这两次状态变化是玩家自己提供的：开门进屋（Opened）、人齐后关门（Closed）。
//       倒计时传送是把人 TeleportEntity 直接塞进屋里，门从来没被开过、也没人去关，
//       于是卡死。表现出来就是用户报的两种现象：
//         · 门开着 -> 没人去关它 -> 引擎等 CheckpointDoorClosed 永远等不到（"开着门不会关"）；
//         · 门关着 -> 门没有任何状态变化 -> 引擎连判定都没开始（"关着门可能不会结算"）。

/**
 * 倒计时传送结束后，启动「安全屋结算」状态机。
 *
 * 只有一种情况会走到这里：区域类型是关底安全屋，并且这次倒计时真的传送了人。
 * 其余类型（救援点 / 中途集合点）一律不碰门。
 *
 * 与 1.2.2 的区别（1.2.2 为什么不够 —— 这两个漏洞正是本次要修的）：
 *   · 1.2.2 的 Timer_SaferoomDoorFix 在「门已经开着」时直接 return，
 *     于是**没有任何东西会去关门**——这正是用户报的「开着门不会关」；
 *   · 1.2.2 的补发关门是 0.2s 后的一个一次性 0.6s timer，而且要求「全部存活生还者
 *     都在屋内」才发。12v12 有 12 个人挤一个安全屋体积，只要那一瞬间有 1 个人被
 *     挤出触发体积（引擎的挤压/地形很容易做到），这一次就永久放弃，再也没有第二次机会
 *     ——这正是「关着门可能不会结算」。
 *
 * 状态机做三件事，每一步都幂等、可重试，且有超时兜底：
 *   1) 让门真正经历一次「开启」（本来就开着的跳过）—— 补上引擎缺的 Opened；
 *   2) 把掉队的人补传回安全屋体积内（最多 SAFEROOM_SETTLE_RETRY_MAX 次，间隔递增），
 *      只有「全员都在屋内」才继续 —— 伪造事件没用，引擎会自己查出谁在屋外；
 *   3) 关门并补发 CheckpointDoorClosed —— 补上引擎缺的 Closed，触发真正的过关链。
 *
 * 安全边界（逐条都有守卫，不改任何地图实体的开关状态）：
 *   · 只发标准实体输入（Open / Close / 传送），绝不改 spawnflags / lock，
 *     不解锁、不锁门、不调用任何硬换图；
 *   · 区域索引 / EntRef 双重校验，换回合、换图后 ResetRound 会清空区域表，
 *     timer 残留时索引对不上就直接放弃；
 *   · 门实体必须存在且 classname 在门类白名单里，才对它发输入；
 *   · 安全屋里一个存活生还者都没有时不做任何动作（说明传送其实没落地）；
 *   · 门被锁住导致 Open 无效时，重发次数有上限（SAFEROOM_SETTLE_RETRY_MAX），
 *     不无限刷，并留一条错误日志说明本回合可能无法过关。
 *
 * @param index 区域索引（timer 每一步都会重新校验，防止跨回合残留）
 */
void ScheduleSaferoomDoorFix(int index)
{
	if (!g_cvEnable.BoolValue || !g_cvSaferoomDoor.BoolValue)
	{
		return;
	}

	if (index < 0 || index >= g_iAreaCount || g_iAreaType[index] != AREA_SAFEROOM)
	{
		return;
	}

	// 1.2.4（需求 #6）硬护栏：终局图（c6m3_port / c7m3_port 这类，引擎里有
	// trigger_finale）**一律不做**「关门 + 补发 CheckpointDoorClosed」。
	// 终局图的过关不靠 info_changelevel，而是 trigger_finale 的逃生流程；对它发
	// CheckpointDoorClosed 会让引擎真的换图 => 玩家在电梯/发电机附近就「直接结算分数
	// 并换边/进下一关」。这条与 FindLastChangelevel 的修复互为双保险：
	// 即使某张终局图被误判出关底安全屋，这里也绝不会真的去触发换图。
	if (g_bNtvFinalMap && L4D_IsMissionFinalMap())
	{
		if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 安全屋结算跳过：本图是终局图（走 trigger_finale，不发 CheckpointDoorClosed）");
		}

		return;
	}

	// 纯坐标区域没有实体，也就没有 info_changelevel 可对照，直接跳过
	if (g_iAreaRef[index] == 0)
	{
		return;
	}

	// 已经在跑：不重复启动（同一区域 FinishCountdown 只会走一次，
	// 这里再挡一层，避免任何异常路径下叠加状态机）
	if (g_hDoorFix != null)
	{
		return;
	}

	g_iDoorFixArea     = index;
	g_iDoorFixRef      = g_iAreaRef[index];
	g_fSettleDeadline  = GetGameTime() + SAFEROOM_SETTLE_TIMEOUT;
	g_iSettleRetry     = 0;
	g_fSettleNextRetry = 0.0;
	g_iSettleOpenTries = 0;
	g_fSettleNextOpenTry  = 0.0;
	g_bSettleDoorOpened   = false;
	g_bSettleDoorClosed   = false;
	g_bSettleEventFired   = false;

	// 1.2.4：世代号 +1 让之前所有在途的旧 tick 立即作废（换图/重入都不会有残留动作）。
	// 用**一次性** timer 而不是 TIMER_REPEAT，也**不带 TIMER_FLAG_NO_MAPCHANGE**：
	// 生命周期完全由我们显式管，引擎不会背着我们关它（重复关闭正是报错的来源）。
	g_iSettleGen++;
	g_hDoorFix = CreateTimer(SAFEROOM_SETTLE_TICK, Timer_SaferoomDoorFix, g_iSettleGen);

	if (g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] 启动安全屋结算状态机（区域 #%d，区域实体 #%d）", index, g_iDoorFixRef);
	}
}

/**
 * 安全屋结算状态机（每 SAFEROOM_SETTLE_TICK 跑一步）。
 *
 * 返回值约定：
 *   Plugin_Continue -> 还没结束，下个 tick 继续；
 *   Plugin_Stop     -> 结束（成功、无需处理、或超时），timer 会被回收。
 */
public Action Timer_SaferoomDoorFix(Handle timer, any gen)
{
	// 一次性 timer 已经触发 => 这个 handle 由引擎回收，我们立刻放开引用，
	// 后面无论走哪条路径都**不要再 delete 它**（这正是 "Invalid timer handle" 的根源）。
	g_hDoorFix = null;

	// 过期的 tick（换图 / 重新启动 / 已收尾）直接退出，绝不碰任何状态
	if (gen != g_iSettleGen)
	{
		return Plugin_Stop;
	}

	int index = g_iDoorFixArea;
	int ref   = g_iDoorFixRef;

	// 每一 tick 都重新校验：换图 / 换回合后区域表已被清空，残留 timer 必须立刻退出，
	// 否则会拿着旧索引去读别人的区域数据（甚至越界）
	if (!g_bMapStarted || !g_cvEnable.BoolValue || !g_bReady)
	{
		SettleFinish("地图已结束 / 插件已关闭");
		return Plugin_Stop;
	}

	if (index < 0 || index >= g_iAreaCount)
	{
		SettleFinish("区域表已重置");
		return Plugin_Stop;
	}

	if (g_iAreaRef[index] != ref || g_iAreaType[index] != AREA_SAFEROOM)
	{
		SettleFinish("区域索引/EntRef 对不上（已换回合或换图）");
		return Plugin_Stop;
	}

	int changelevel = GetAreaEntity(index);

	if (changelevel == -1)
	{
		SettleFinish("区域实体已删除");
		return Plugin_Stop;
	}

	// ---- 超时兜底：宁可留一条明确的日志，也不让 timer 无限跑 ----------------
	if (GetGameTime() >= g_fSettleDeadline)
	{
		LogError("[cptele] 安全屋结算超时（%.1f 秒）：区域 #%d，屋内 %d/%d 人，已开门=%d 已关门=%d 已补发事件=%d。本回合可能没有结算，请用 l4d2_cptele_verbose 1 复现并检查门是否被锁",
			SAFEROOM_SETTLE_TIMEOUT, index, CountArrivedSurvivors(index), CountAliveSurvivors(),
			g_bSettleDoorOpened, g_bSettleDoorClosed, g_bSettleEventFired);

		SettleFinish("超时");
		return Plugin_Stop;
	}

	int arrived = CountArrivedSurvivors(index);

	// 传送明明送过人，落位后安全屋里却一个人都没有：说明落点被引擎的
	// WarpToValidPositionIfStuck / 几何体挤到了体积外，这种情况开门关门也救不回来，
	// 直接报错留证据，不假装处理了
	if (arrived <= 0)
	{
		LogError("[cptele] 安全屋结算：区域 #%d 传送后安全屋内没有任何存活生还者，落点可能不在安全屋触发体积内", index);

		SettleFinish("屋内无人");
		return Plugin_Stop;
	}

	int door = FindSaferoomDoor(changelevel);

	if (door == -1)
	{
		// 找不到门就没法提供引擎需要的两次状态变化。仍把事件补发出去，
		// 因为「全员已在屋内」这件事本身对引擎是有意义的输入（引擎会自己再判 IsTouching）。
		if (!g_bSettleEventFired && CountArrivedSurvivors(index) >= CountAliveSurvivors())
		{
			FireCheckpointClosed(changelevel, door, index, arrived, "找不到门，仅补发事件");
		}
		else if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 安全屋结算：找不到本图的安全门实体（区域 #%d），等待全员到齐后只补发事件", index);
		}

		// 门都找不到，继续等下去也不会有进展
		SettleFinish("找不到安全门");
		return Plugin_Stop;
	}

	char sClass[64];

	if (!GetEntityClassname(door, sClass, sizeof(sClass)) || !IsSafeDoorClass(sClass))
	{
		LogError("[cptele] 安全屋结算：实体 #%d 的 classname 是 \"%s\"，不是门类实体，忽略", door, sClass);

		SettleFinish("门类不符");
		return Plugin_Stop;
	}

	// ---- 第 1 步：让门真正经历一次「开启」（补上引擎缺的 Opened）-------------
	// 这一步修的是「门本来就开着，没人去关」那一半：
	// 门本来就开着时我们不需要再开它，但也**不能直接 return**（1.2.2 的 bug），
	// 而是要把它记成「已经开过」，继续往下走关门流程。
	if (!g_bSettleDoorOpened)
	{
		int state = GetEntProp(door, Prop_Data, "m_eDoorState");

		if (state == DOOR_STATE_OPENED)
		{
			// 门已经是「已开启」：这正是玩家开门进屋后引擎能正常过关的状态。
			// 记下来，接着去关门 —— 关键区别就在这，不再提前退出。
			g_bSettleDoorOpened = true;

			if (g_cvVerbose.BoolValue)
			{
				PrintToServer("[cptele] 安全门 #%d 本来就处于开启状态，跳过 Open，继续走关门流程（区域 #%d）", door, index);
			}
		}
		else if (state == DOOR_STATE_OPENING_IN_PROGRESS)
		{
			// 门正在开：等它开到 DOOR_STATE_OPENED 再继续，否则现在发 Close 会被引擎丢掉
			if (g_cvVerbose.BoolValue)
			{
				PrintToServer("[cptele] 安全门 #%d 正在开启中，等待开到位（区域 #%d）", door, index);
			}

			return SettleContinue(gen);
		}
		else if (state == DOOR_STATE_CLOSING_IN_PROGRESS)
		{
			// 门正在关：等它关到位，下一 tick 会重新走 Open 分支
			if (g_cvVerbose.BoolValue)
			{
				PrintToServer("[cptele] 安全门 #%d 正在关闭中，等待关到位（区域 #%d）", door, index);
			}

			return SettleContinue(gen);
		}
		else
		{
			// state == DOOR_STATE_CLOSED：完全关闭，补一次标准 Open（等价玩家开门进屋）
			// 重发之间要留时间给引擎的 think：Open 被接受后 m_eDoorState 通常下一帧就变
			// DOOR_STATE_OPENING_IN_PROGRESS，但门是被锁住还是被别的插件压回去，得给
			// 引擎几个 tick 才看得出来。间距用 SAFEROOM_SETTLE_RETRY_DELAY，别每 0.25s 就判死。
			if (GetGameTime() < g_fSettleNextOpenTry)
			{
				return SettleContinue(gen);
			}

			if (g_iSettleOpenTries >= SAFEROOM_SETTLE_RETRY_MAX)
			{
				// Open 反复无效：门被锁了。仅作诊断记录，绝不解锁
				LogError("[cptele] 安全门 #%d 发送 %d 次 Open 仍然无法开启（locked=%d），本回合可能无法过关；请确认该地图安全门是否被锁住",
					door, g_iSettleOpenTries, view_as<bool>(GetEntProp(door, Prop_Data, "m_bLocked")));

				// 门开不了也要把「全员在屋内」的事件发出去，尽最大努力让引擎能判过关
				if (CountArrivedSurvivors(index) >= CountAliveSurvivors() && !g_bSettleEventFired)
				{
					FireCheckpointClosed(changelevel, door, index, arrived, "门无法开启，仅补发事件");
				}

				SettleFinish("门无法开启");
				return Plugin_Stop;
			}

			g_iSettleOpenTries++;
			g_fSettleNextOpenTry = GetGameTime() + SAFEROOM_SETTLE_RETRY_DELAY;

			AcceptEntityInput(door, "Open");

			if (g_cvVerbose.BoolValue)
			{
				PrintToServer("[cptele] 安全门 #%d 已发送 Open（第 %d 次，state=%d），等待开启完成（区域 #%d）",
					door, g_iSettleOpenTries, state, index);
			}

			return SettleContinue(gen);
		}
	}

	// ---- 第 1.5 步：等门真的开到位，再进入关门 ------------------------------
	// 门还在开的过程中就发 Close，引擎会把这次 Close 丢掉（关门动作被打断），
	// 于是「关门 -> 引擎收到 Closed」这条链又断了。必须等 DOOR_STATE_OPENED。
	if (!g_bSettleDoorClosed)
	{
		int state = GetEntProp(door, Prop_Data, "m_eDoorState");

		if (state != DOOR_STATE_OPENED)
		{
			if (g_cvVerbose.BoolValue)
			{
				PrintToServer("[cptele] 安全门 #%d 尚未完全开启（state=%d），暂不关门（区域 #%d）", door, state, index);
			}

			return SettleContinue(gen);
		}
	}

	// ---- 第 2 步：把掉队的人补传回安全屋体积内 --------------------------------
	// 引擎的 OnCheckpointDoorClosed 会逐个 IsTouching 判「谁还在屋外」，只要有一个
	// 人被挤出体积，这一次关门就等于白关。12v12 有 12 个人，挤出去很正常，
	// 所以这里允许补传若干次（间隔递增），把所有人真正塞进体积内再关门。
	int alive = CountAliveSurvivors();

	if (alive > 0 && arrived < alive)
	{
		if (g_iSettleRetry >= SAFEROOM_SETTLE_RETRY_MAX)
		{
			// 补传次数用尽还有人在屋外：说明这些人的落点确实进不了体积
			// （或者他们正在被特感拖走 / 挂在边缘）。不伪造事件，留日志收尾。
			LogError("[cptele] 安全屋结算：补传 %d 次后屋内仍只有 %d/%d 人（区域 #%d），本回合可能无法结算；请检查落点是否在安全屋触发体积内、以及是否有生还者被特感控制",
				SAFEROOM_SETTLE_RETRY_MAX, arrived, alive, index);

			SettleFinish("补传后仍不齐");
			return Plugin_Stop;
		}

		if (GetGameTime() < g_fSettleNextRetry)
		{
			// 还没到下次补传的时间（给物理挤压 / 引擎落位留时间）
			return SettleContinue(gen);
		}

		g_iSettleRetry++;
		g_fSettleNextRetry = GetGameTime() + SAFEROOM_SETTLE_RETRY_DELAY * float(g_iSettleRetry);

		int moved = SettleGatherSurvivors(index);

		if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 安全屋结算：第 %d 次补传，把 %d 名掉队生还者重新送进安全屋（原屋内 %d/%d 人，区域 #%d）",
				g_iSettleRetry, moved, arrived, alive, index);
		}

		// 传完这一批等下一 tick 重新统计，不要在同一 tick 里连续传
		return SettleContinue(gen);
	}

	// ---- 第 3 步：关门 + 补发 CheckpointDoorClosed（补上引擎缺的 Closed）-----
	// 走到这里说明：门已经开到位、所有存活生还者都在安全屋体积内。
	// g_cvSaferoomForceDoor 管的就是"这一层"（1.2.2 起就是这个语义：只做 Open 不补关门）：
	//   0 = 只开门，门交给玩家自己关（老用法），1 = 由插件把关门 + 补发事件做完。
	// 1.2.3 起它管的是整个"关门 + 补发事件"阶段，而不只是 0.6s 后那一次补发。
	if (!g_cvSaferoomForceDoor.BoolValue)
	{
		SettleFinish("forcedoor=0，只开门不补发关门事件");
		return Plugin_Stop;
	}

	if (!g_bSettleDoorClosed)
	{
		// 物理关门是最"正统"的触发源：门自己的 OnClose 只会在关门完成时把事件送给
		// info_changelevel，引擎认这个。发完仍会再补一次实体输入，双保险。
		AcceptEntityInput(door, "Close");
		g_bSettleDoorClosed = true;

		if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 安全屋结算：已对门 #%d 发送 Close，等待关门完成（屋内 %d/%d 人，区域 #%d）",
				door, arrived, alive, index);
		}

		return SettleContinue(gen);
	}

	// 关门动作有自己的动画时间（约 0.5~1 秒）。门还没关到位就发事件，
	// 引擎那边 IsTouching 判定是对的，但门自己的 OnClose 会在之后重复发一次事件，
	// 这本身无害（引擎侧 ChangelevelThink 会去重），但为了让画面与逻辑一致，等关到位再发。
	int state = GetEntProp(door, Prop_Data, "m_eDoorState");

	// 门又被玩家（或引擎）开回去了：重发一次 Close，回到「等关门完成」这一步。
	// 不重发的话会一直等到 10 秒超时，白白丢掉一次过关机会。
	if (state == DOOR_STATE_OPENED || state == DOOR_STATE_OPENING_IN_PROGRESS)
	{
		g_bSettleDoorClosed = false;

		if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 安全屋结算：门 #%d 被重新打开（state=%d），重新关门（区域 #%d）", door, state, index);
		}

		return SettleContinue(gen);
	}

	// 还在关：等它关到位再发事件
	if (state == DOOR_STATE_CLOSING_IN_PROGRESS)
	{
		if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 安全屋结算：等待门 #%d 关到位（state=%d，区域 #%d）", door, state, index);
		}

		return SettleContinue(gen);
	}

	if (!g_bSettleEventFired)
	{
		FireCheckpointClosed(changelevel, door, index, arrived, "关门完成");
	}

	SettleFinish("完成");
	return Plugin_Stop;
}

/**
 * 把安全屋外（或体积判定失败）的存活生还者重新传送进区域，返回实际传送人数。
 *
 * 与 FinishCountdown 里的主传送的区别：这里**不看** g_bSeen / g_cvSkipSeen。
 * 那些开关的语义是「已经到过集合点的人不要再被传回来」，针对的是中途集合点和
 * 已经继续推进的生还者；而这里是终局安全屋结算的最后一步，任何人不在体积内
 * 都会导致引擎判「还有人在屋外」而不换图，所以必须把人补齐。
 */
int SettleGatherSurvivors(int index)
{
	float vDest[3];

	if (!GetAreaDestination(index, vDest))
	{
		return 0;
	}

	bool bFixedDest = g_bAreaDest[index];
	int moved = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsAliveSurvivor(i))
		{
			continue;
		}

		if (IsClientInArea(i, index))
		{
			continue;
		}

		float vClientDest[3];

		CopyVec(vDest, vClientDest);

		if (bFixedDest)
		{
			vClientDest[0] += GetRandomFloat(-DEST_JITTER, DEST_JITTER);
			vClientDest[1] += GetRandomFloat(-DEST_JITTER, DEST_JITTER);
		}

		TeleportSurvivor(i, vClientDest);

		// 1.2.8：同 FinishCountdown，补传也不算「玩家走进来」（进入提示照常，但不重复播）
		SuppressEnterNoticeForTeleport(index, i);

		moved++;
	}

	return moved;
}

/**
 * 向 info_changelevel 补发「门关闭」这个引擎自己的输入。
 *
 * datamap 里 CBaseTrigger-info_changelevel 那两条 Input 的名字在 dump 里写成
 * "OnCheckpointDoorOpened / OnCheckpointDoorClosed"（同一份 dump 里其它 Input 都带
 * "Input" 前缀，这两条没有），所以两种拼法都发一遍：未知输入会被引擎静默忽略，
 * 不会报错，也不会重复触发过关（引擎侧有 ChangelevelThink 去重）。
 */
void FireCheckpointClosed(int changelevel, int door, int index, int arrived, const char[] sReason)
{
	AcceptEntityInput(changelevel, "OnCheckpointDoorClosed");
	AcceptEntityInput(changelevel, "CheckpointDoorClosed");

	g_bSettleEventFired = true;

	if (g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] 已补发 CheckpointDoorClosed（%s）：门 #%d，info_changelevel #%d，屋内 %d 人（区域 #%d）",
			sReason, door, changelevel, arrived, index);
	}
}

/**
 * 状态机「继续下一 tick」：重新挂一个一次性 timer，并把当前这一代传下去。
 *
 * 为什么不用 TIMER_REPEAT：重复 timer 在换图时会被引擎按 TIMER_FLAG_NO_MAPCHANGE
 * 自动关闭，而 ResetRound 又 delete 一次 => 同一个 handle 被关闭两次，运行期就会报
 *   "Invalid timer handle <h> (error 1) during timer end, unable to call function
 *    Timer_SaferoomDoorFix"
 * 改成一次性 timer 逐 tick 续命后，**每个 handle 只会被关闭一次**（触发即由引擎回收，
 * 我们只管放开引用），重复关闭的窗口彻底消失。
 *
 * @param gen 发起续命的那一代；若期间已经换图/收尾（世代号变了）就不再续命
 * @return 恒为 Plugin_Stop —— 结束当前这一次性 timer（这是正常行为，不是出错）
 */
Action SettleContinue(int gen)
{
	// 期间已经换图 / 已收尾 / 已重新启动：不再续命，静静结束
	if (gen != g_iSettleGen)
	{
		return Plugin_Stop;
	}

	g_hDoorFix = CreateTimer(SAFEROOM_SETTLE_TICK, Timer_SaferoomDoorFix, gen);

	return Plugin_Stop;
}

/**
 * 收尾：把状态机挂起槽全部清干净。
 *
 * 这个函数只会从 Timer_SaferoomDoorFix 里调用，而调用点全部紧跟着 return Plugin_Stop，
 * 所以**不能**在这里 delete timer —— 正在执行的重复 timer 由 Plugin_Stop 自己回收。
 * 这里只负责把引用与进度字段清空，让 ScheduleSaferoomDoorFix 的下一次调用能重新启动。
 */
void SettleFinish(const char[] sReason)
{
	if (g_cvVerbose.BoolValue && g_iDoorFixArea >= 0)
	{
		PrintToServer("[cptele] 安全屋结算结束（%s）：区域 #%d", sReason, g_iDoorFixArea);
	}

	// 世代号 +1：让所有在途的旧 tick 立刻作废（它们看到 gen 不匹配会自己退出）
	g_iSettleGen++;

	g_hDoorFix = null;

	g_iDoorFixArea        = -1;
	g_iDoorFixRef         = 0;
	g_fSettleDeadline     = 0.0;
	g_iSettleRetry        = 0;
	g_fSettleNextRetry    = 0.0;
	g_iSettleOpenTries    = 0;
	g_fSettleNextOpenTry  = 0.0;
	g_bSettleDoorOpened   = false;
	g_bSettleDoorClosed   = false;
	g_bSettleEventFired   = false;
}

/**
 * 找出「关底」那一个 changelevel 实体（作为安全屋区域）。
 *
 * 为什么不能只取第一个（1.2.1 及以前的做法）：
 *   直接遍历 .bsp 的实体 lump 扫了全部官方图，10 张图有 2 个 changelevel 候选，
 *   其中 7 张图的**第一个**是「起点 / 往回走」那个（spawnflags=2，map 指向上一张图、
 *   本图自己或空）：
 *     c1m2_streets     info map=c1m2_streets  flags=2   <- 第一个是回退
 *     c2m4_barns       info map=c2m3_coaster  flags=2   <- 第一个是回退
 *     c3m2_swamp       info map=c3m1_plankcountry flags=2
 *     c3m3_shantytown  info map=c3m2_shantytown flags=2
 *     c5m3_cemetery    info map=c5m3_cemetery flags=2
 *     c5m2_park / c5m4_quarter / c2m3_coaster 同样是 flags=2 的回退项在前
 *   取第一个会让「安全屋区域」指到开局那间屋：开局全员本来就在里面 -> 计数立刻达标
 *   -> 倒计时被立刻结束 -> 关底安全屋传送静默失效（这就是"以为是插件没生效"的真因）。
 *
 * 选择顺序（都基于上表实测出来的特征，有唯一解就早退，绝不靠猜）：
 *   1) 只保留 spawnflags & 2 == 0 的候选（剔掉"往回走"的那个）；
 *   2) 仍多于一个时，用 m_mapName 再筛：关底那个指向"下一张图"，回退项指向本图 / 空
 *      （c1m3_mall 是唯一两张都是 flags=0 的图，就靠这一条区分）；
 *   3) 还多于一个时，用 nav 的「最后一个检查点」判中心点（L4D_IsPositionInLastCheckpoint）；
 *   4) 再不行用「离最后一个安全门最近」（L4D_GetCheckpointLast，2000 HU 内）；
 *   5) 全都不成立才回落到第一个，并打 verbose 提示。
 *
 * @return changelevel 实体索引；一个都没有返回 -1
 */
int FindLastChangelevel()
{
	int aCand[16];
	int iCand = 0;
	int entity = -1;

	while ((entity = FindEntityByClassname(entity, "info_changelevel")) != -1)
	{
		if (iCand < sizeof(aCand))
		{
			aCand[iCand++] = entity;
		}
	}

	// 没有 info_changelevel 才回落到老的 trigger_changelevel
	if (iCand == 0)
	{
		entity = -1;

		while ((entity = FindEntityByClassname(entity, "trigger_changelevel")) != -1)
		{
			if (iCand < sizeof(aCand))
			{
				aCand[iCand++] = entity;
			}
		}
	}

	if (iCand <= 0)
	{
		return -1;
	}

	// 1.2.4（需求 #6）：单候选**不能**直接返回 —— 唯一那个可能正是「往回走」的
	// 回退触发（spawnflags & 2）。实测 c6m3_port.bsp 全图只有 1 个 info_changelevel：
	//   spawnflags=2, map=c6m3_port(指向自己), landmark=c6m2-c6m3_landmark
	// 也就是「从 c6m3 往回走到 c6m2」那个触发，绝不是关底安全屋。旧代码在这里直接
	// return，把它注册成 AREA_SAFEROOM，于是玩家正常路过后半段（电梯下来到罐油发电机
	// 那一片正好在这个体积里）就会被当成「全员进入安全屋」，进而触发关门 +
	// CheckpointDoorClosed，让引擎真的换图 —— 这正是用户报的「c6m3 电梯附近直接结算
	// 分数并换边/进下一关」。
	// 走下面的统一过滤（剔 spawnflags & 2），一个都不剩就当这张图没有关底安全屋。

	// ---- 1) 剔掉"往回走"的候选（spawnflags & 2）--------------------------
	int aPool[16];
	int iPool = 0;

	for (int i = 0; i < iCand; i++)
	{
		if ((GetEntProp(aCand[i], Prop_Data, "m_spawnflags") & 2) == 0)
		{
			aPool[iPool++] = aCand[i];
		}
	}

	// 一个都没剩下（全被标成"往回走"）：**不要**无条件退化成全集。
	// 1.2.4（需求 #6）：这里原来直接拿全集兜底，等于把刚才那次过滤又撤销了 ——
	// c6m3_port 只有 1 个 info_changelevel 且 spawnflags=2，兜底后它照样被当成
	// 关底安全屋，修复失效。现在改成：只有在「确实存在指向别的图」的候选时才兜底，
	// 否则判定这张图压根没有关底安全屋（终局图走 trigger_finale，本来也没有）。
	if (iPool <= 0)
	{
		char sCur[64];
		GetCurrentMap(sCur, sizeof(sCur));

		for (int i = 0; i < iCand; i++)
		{
			if (!HasEntProp(aCand[i], Prop_Data, "m_mapName"))
			{
				continue;
			}

			char sTgt[64];

			if (GetEntPropString(aCand[i], Prop_Data, "m_mapName", sTgt, sizeof(sTgt)) <= 0)
			{
				continue;
			}

			// 指向自己 / 空的都是「往回走」的回退项，不算关底
			if (sTgt[0] == '\0' || StrEqual(sTgt, sCur, false))
			{
				continue;
			}

			aPool[iPool++] = aCand[i];
		}

		if (iPool <= 0)
		{
			if (g_cvVerbose.BoolValue)
			{
				PrintToServer("[cptele] 全部 %d 个 changelevel 都是「往回走」的回退项且不指向别的图，判定本图无关底安全屋（终局图走 trigger_finale）", iCand);
			}

			// 重要：返回 -1 让上层不注册 AREA_SAFEROOM，从而不会误触发
			// 「开门 -> 关门 -> CheckpointDoorClosed」这条换图链
			return -1;
		}
	}

	if (iPool == 1)
	{
		if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 关底 changelevel 判定: entity #%d（按 spawnflags 剔掉回退项，候选 %d 个）",
				aPool[0], iCand);
		}

		return aPool[0];
	}

	// ---- 2) 用 m_mapName 再筛：关底那个指向"下一张图" --------------------
	char sCurrent[64];
	GetCurrentMap(sCurrent, sizeof(sCurrent));

	int aNext[16];
	int iNext = 0;

	for (int i = 0; i < iPool; i++)
	{
		// m_mapName 是 datamap 字段（char[32]），老版本引擎读不到时跳过，走后面的兜底
		if (!HasEntProp(aPool[i], Prop_Data, "m_mapName"))
		{
			continue;
		}

		char sTarget[64];

		if (GetEntPropString(aPool[i], Prop_Data, "m_mapName", sTarget, sizeof(sTarget)) <= 0)
		{
			continue;
		}

		if (sTarget[0] == '\0' || StrEqual(sTarget, sCurrent, false))
		{
			continue;
		}

		aNext[iNext++] = aPool[i];
	}

	if (iNext == 1)
	{
		if (g_cvVerbose.BoolValue)
		{
			PrintToServer("[cptele] 关底 changelevel 判定: entity #%d（按 m_mapName 命中下一张图，候选 %d 个）",
				aNext[0], iPool);
		}

		return aNext[0];
	}

	// 后面两步在"m_mapName 筛过之后仍有多个"时，优先在筛过的集合里挑
	if (iNext > 1)
	{
		iPool = iNext;

		for (int i = 0; i < iNext; i++)
		{
			aPool[i] = aNext[i];
		}
	}

	// ---- 3) 中心点是否在「最后一个检查点」体积内 --------------------------
	if (g_bNtvLastCp)
	{
		for (int i = 0; i < iPool; i++)
		{
			float vCenter[3];
			GetEntityCenter(aPool[i], vCenter);

			if (L4D_IsPositionInLastCheckpoint(vCenter))
			{
				if (g_cvVerbose.BoolValue)
				{
					PrintToServer("[cptele] 关底 changelevel 判定: entity #%d 落在最后一个检查点内",
						aPool[i]);
				}

				return aPool[i];
			}
		}
	}

	// ---- 4) 离「最后一个安全门」最近 --------------------------------------
	if (g_bNtvDoorLast)
	{
		int door = L4D_GetCheckpointLast();

		if (door > 0 && IsValidEntity(door))
		{
			float vDoor[3];
			GetEntPropVector(door, Prop_Send, "m_vecOrigin", vDoor);

			int best = -1;
			float fBest = 0.0;

			for (int i = 0; i < iPool; i++)
			{
				float vCenter[3];
				GetEntityCenter(aPool[i], vCenter);

				float fDist = GetVectorDistance(vDoor, vCenter);

				if (best == -1 || fDist < fBest)
				{
					best = aPool[i];
					fBest = fDist;
				}
			}

			if (best != -1 && fBest <= SAFEROOM_DOOR_MAX_DIST)
			{
				if (g_cvVerbose.BoolValue)
				{
					PrintToServer("[cptele] 关底 changelevel 判定: entity #%d 距最后一个安全门 %.0f HU",
						best, fBest);
				}

				return best;
			}
		}
	}

	// ---- 5) 回落 ---------------------------------------------------------
	if (g_cvVerbose.BoolValue)
	{
		PrintToServer("[cptele] 无法判定关底 changelevel（候选 %d 个，剩余 %d 个），回落到 entity #%d；若本图安全屋传送无效请先查这里",
			iCand, iPool, aPool[0]);
	}

	return aPool[0];
}

/**
 * 找关底安全屋对应的那道安全门。
 *
 * 1) left4dhooks 的 L4D_GetCheckpointLast()：按流量距离挑「接近地图末尾」的
 *    安全门（DOOR_RANGE_TOLLERANCE = 2000 HU），官方图 / 三方图通用；
 * 2) 回落：离 info_changelevel 体积中心最近的 prop_door_rotating_checkpoint。
 *
 * @return 安全门实体索引；找不到返回 -1
 */
int FindSaferoomDoor(int changelevel)
{
	float vCenter[3];

	GetEntityCenter(changelevel, vCenter);

	if (g_bNtvDoorLast)
	{
		int door = L4D_GetCheckpointLast();

		if (door > 0 && IsValidEntity(door))
		{
			// 距离校验：这道门必须就在 info_changelevel 这间安全屋旁边。
			// L4D_GetCheckpointLast 用的是「离地图末尾最近」的粗略判定，
			// 万一判错（三方图常见），宁可回落到下一层，也不去开别处的门。
			float vDoor[3];

			GetEntPropVector(door, Prop_Send, "m_vecOrigin", vDoor);

			if (GetVectorDistance(vDoor, vCenter) <= SAFEROOM_DOOR_MAX_DIST)
			{
				return door;
			}

			if (g_cvVerbose.BoolValue)
			{
				PrintToServer("[cptele] L4D_GetCheckpointLast 返回的门 #%d 离安全屋 %.0f HU，超出 %.0f，改用最近门判定",
					door, GetVectorDistance(vDoor, vCenter), SAFEROOM_DOOR_MAX_DIST);
			}
		}
	}

	int best = -1;
	float fBest = 0.0;
	int entity = -1;

	while ((entity = FindEntityByClassname(entity, "prop_door_rotating_checkpoint")) != -1)
	{
		float vOrigin[3];

		GetEntPropVector(entity, Prop_Send, "m_vecOrigin", vOrigin);

		float fDist = GetVectorDistance(vOrigin, vCenter);

		if (best == -1 || fDist < fBest)
		{
			best = entity;
			fBest = fDist;
		}
	}

	// 最近的那道门也离得太远：说明这间安全屋压根没有 prop_door_rotating_checkpoint
	// （部分三方图用普通门 / func_door），交回调用方只记日志，不乱发输入。
	if (best != -1 && fBest > SAFEROOM_DOOR_MAX_DIST)
	{
		return -1;
	}

	return best;
}

/**
 * 门类实体白名单。「Open」是 CBasePropDoor / CBaseDoor 的标准输入，
 * 只有这几类 classname 接受它；不对其它实体乱发输入。
 */
stock bool IsSafeDoorClass(const char[] sClass)
{
	return StrEqual(sClass, "prop_door_rotating_checkpoint", false)
	    || StrEqual(sClass, "prop_door_rotating", false)
	    || StrEqual(sClass, "func_door", false)
	    || StrEqual(sClass, "func_door_rotating", false);
}

// ===========================================================================
//  计数
// ===========================================================================

void ClearSeenFlags()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		g_bSeen[i] = false;
	}
}

/**
 * 1.2.7：清掉「进入区域提示」的全部状态（换图 / 换回合）。
 * 不清会残留「该玩家已经在区域里」的判断，导致下回合第一次进入不再提示。
 */
void ClearEnterNoticeState()
{
	for (int i = 0; i < MAX_AREAS; i++)
	{
		g_bAreaNoticePrimed[i] = false;

		for (int c = 0; c <= MaxClients; c++)
		{
			g_bAreaPresence[i][c] = false;
			g_fAreaEnterAt[i][c] = 0.0;
		}
	}
}

/**
 * 1.2.7：清掉某个 client 槽位在「进入区域提示」里的状态（连接 / 断线时用）。
 * client index 会被新玩家或 bot 复用，不清会漏掉「复用者」的第一次进入提示。
 */
void ClearEnterNoticeForClient(int client)
{
	for (int i = 0; i < MAX_AREAS; i++)
	{
		g_bAreaPresence[i][client] = false;
		g_fAreaEnterAt[i][client] = 0.0;
	}
}

/**
 * 1.2.8：把「插件自己把人传进区域」这一次移动登记成「已经在区域内」。
 *
 * 1.2.8 起已触发过传送的区域仍然照常播报进入提示，于是插件自己的传送原本会被
 * 下一秒的侦测当成一次「不在 -> 在」跳变，紧跟倒计时结束提示再多刷一条
 * 「N/N 名生还者已进入…」。这里在传送后立刻登记，把这种情况压掉：
 *   - g_bAreaPresence 预先置 true：下一秒看不到跳变，不播报；
 *   - g_fAreaEnterAt 记成当前时刻：万一落点其实不在判定体积内（固定传送点写偏了），
 *     也不会紧接着补一条提示（与 ENTER_NOTICE_REPEAT 的抖动抑制同一口径）。
 * 传送失败 / 落点确实在体积外时，下一秒的侦测会把 g_bAreaPresence 自动修正回 false，
 * 玩家之后自己走进来仍然照常播报 —— 这里只是「这一次不算走进来」，不是永久闩锁。
 *
 * 只影响进入提示的状态，不碰倒计时 / 传送 / 区域判定。
 */
void SuppressEnterNoticeForTeleport(int index, int client)
{
	if (index < 0 || index >= MAX_AREAS)
	{
		return;
	}

	if (client <= 0 || client > MaxClients)
	{
		return;
	}

	g_bAreaPresence[index][client] = true;
	g_fAreaEnterAt[index][client] = GetGameTime();
}

/**
 * 1.2.9：把某个区域的「进入提示」在场状态按此刻真实情况同步一次。
 *
 * 用途：倒计时结束（FinishCountdown）/ 取消（CancelCountdown）的那一刻调用。
 * 倒计时期间 UpdateEnterNotices 是静默的（只更新 g_bAreaPresence 不播报），
 * 如果这期间有人刚好跨过判定边界走进来、或者插件自己把人传送进区域，结束后的
 * 第一条 tick 很容易把「整段倒计时里的进入」当成一次跳变补播出去。这里先对齐：
 *   - 此刻在区域内的存活生还者：登记成「已经在里面」，并刷新播报时刻 —— 这就是
 *     SuppressEnterNoticeForTeleport 的同一套思路，只是按「所有人」做一遍；
 *   - 此刻不在区域内的：清成 false，玩家之后真的走进来仍然照常播报。
 *
 * 只影响进入提示的状态，不碰倒计时 / 传送 / 区域判定。
 */
void SyncEnterNoticePresence(int index)
{
	if (index < 0 || index >= MAX_AREAS)
	{
		return;
	}

	float fNow = GetGameTime();

	for (int c = 1; c <= MaxClients; c++)
	{
		if (!IsAliveSurvivor(c))
		{
			continue;
		}

		if (IsClientInArea(c, index))
		{
			g_bAreaPresence[index][c] = true;
			g_fAreaEnterAt[index][c] = fNow;
		}
		else
		{
			g_bAreaPresence[index][c] = false;
		}
	}
}

/**
 * 把当前站在区域里的存活生还者标记为「本次倒计时期间到过」。
 * 每秒调用一次，标记后不会再被清掉（离开区域也算到过）。
 */
void MarkSeenInArea(int index)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (g_bSeen[i] || !IsAliveSurvivor(i))
		{
			continue;
		}

		if (IsClientInArea(i, index))
		{
			g_bSeen[i] = true;
		}
	}
}

int CountSeenSurvivors()
{
	int count = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (g_bSeen[i] && IsAliveSurvivor(i))
		{
			count++;
		}
	}

	return count;
}

stock bool IsAliveSurvivor(int client)
{
	return IsClientInGame(client)
	    && GetClientTeam(client) == TEAM_SURVIVOR
	    && IsPlayerAlive(client);
}

/**
 * 安全屋 / 救援点属于同一类（共用 l4d2_cptele_time / l4d2_cptele_percent），
 * 中途集合点是另一类（l4d2_cptele_checkpoint_time / _percent）。
 */
stock bool IsSafeAreaType(int type)
{
	return type == AREA_SAFEROOM || type == AREA_RESCUE;
}

stock int AreaCountdownSeconds(int type)
{
	return IsSafeAreaType(type) ? g_cvTime.IntValue : g_cvCpTime.IntValue;
}

stock int AreaPercentValue(int type)
{
	return IsSafeAreaType(type) ? g_cvPercent.IntValue : g_cvCpPercent.IntValue;
}

/**
 * 区域类型的中文名，同时用于提示文案与 sm_cptele 输出。
 */
stock void GetAreaTypeName(int type, char[] sName, int iLen)
{
	switch (type)
	{
		case AREA_SAFEROOM:   strcopy(sName, iLen, "安全屋");
		case AREA_RESCUE:     strcopy(sName, iLen, "救援点");
		case AREA_CHECKPOINT: strcopy(sName, iLen, "集合点");
		default:              strcopy(sName, iLen, "未知");
	}
}

stock void GetAreaSourceName(int source, char[] sName, int iLen)
{
	switch (source)
	{
		case SRC_PRESET:      strcopy(sName, iLen, "预设");
		case SRC_LEGACY:      strcopy(sName, iLen, "原版地点");
		default:              strcopy(sName, iLen, "自动侦测");
	}
}

int CountAliveSurvivors()
{
	int count = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsAliveSurvivor(i))
		{
			count++;
		}
	}

	return count;
}

int CountArrivedSurvivors(int index)
{
	int count = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsAliveSurvivor(i) && IsClientInArea(i, index))
		{
			count++;
		}
	}

	return count;
}

/**
 * 某类型区域在这次需要多少人到场。
 * 安全屋/救援点用 l4d2_cptele_percent，中途集合点用
 * l4d2_cptele_checkpoint_percent。
 */
int AreaRequiredCount(int type, int total)
{
	if (total <= 0)
	{
		return 1;
	}

	int need = RoundToCeil(AreaPercentValue(type) / 100.0 * float(total));

	if (need < 1)
	{
		need = 1;
	}

	if (need > total)
	{
		need = total;
	}

	return need;
}

/**
 * 1.3.8：半径判定的中途集合点，是否已有生还者「真的贴着机关」。
 *
 * 存在的理由（玩家反馈 c1m1「人还没走到电梯集合点，倒计时就开始了」）：
 *   半径判定用的是三维球体，不认墙、不认楼层。c1m1 的原版地点表条目只写了
 *   func_button + targetname，没写 radius，于是退化成 l4d2_cptele_mech_radius
 *   600 —— 一个以轿厢内壁面板为中心、半径 600 的球，把电梯厅外面的走廊、
 *   电梯前放枪的房间、电梯井旁的上层窗台全圈了进来。12 人局 50% 只要 6 人
 *   正好在那片区域（捡枪、等电梯、打架时的常态）比例就达标，倒计时于是
 *   在谁都没进轿厢的时候就开始跑；接着 1.3.4 的全员传送会把整队拉进轿厢
 *   并按按钮，电梯提前下行。
 *
 * 本函数给出最后一道门槛：比例达标之后，还必须有至少 1 名存活生还者
 * 落在「核心半径」（l4d2_cptele_checkpoint_core_radius，默认 200 HU）内。
 *   · 方框区域（g_bAreaBox）：方框本身已经精确，直接放行；
 *   · 触发体积区域（!g_bAreaRadius）：L4D_IsTouchingTrigger 本来就精确，放行；
 *   · 纯半径区域：要求有人真的贴着判定中心，否则本 tick 不起倒计时。
 *
 * @param index 区域索引（调用方已校验范围）
 * @return true = 可以起倒计时
 */
bool HasCoreSurvivor(int index)
{
	// 只约束「中途集合点」：安全屋 / 救援点的 1.2.5 / 1.2.9 语义一个字都不动
	if (g_iAreaType[index] != AREA_CHECKPOINT)
	{
		return true;
	}

	// 方框 / 触发体积类判定本身就是精确体积，不需要这道门槛
	if (g_bAreaBox[index] || !g_bAreaRadius[index])
	{
		return true;
	}

	// 0 = 关闭该门槛（回到 1.3.7 的行为）
	float fCore = g_cvCpCoreRadius.FloatValue;

	if (fCore <= 0.0)
	{
		return true;
	}

	/* 核心半径不允许超过判定半径本身太多（写错了也不至于把整片区域都算核心） */
	float fArea = g_fAreaRadius[index] > 0.0 ? g_fAreaRadius[index] : g_cvMechRadius.FloatValue;

	if (fCore > fArea)
	{
		fCore = fArea;
	}

	float vCenter[3];

	GetAreaCenter(index, vCenter);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsAliveSurvivor(i))
		{
			continue;
		}

		float vClient[3];

		GetClientAbsOrigin(i, vClient);

		if (GetVectorDistance(vClient, vCenter) <= fCore)
		{
			return true;
		}
	}

	return false;
}

bool IsClientInArea(int client, int index)
{
	/* 1.3.7：方框判定（预设里写 square）—— 与 spit_block_square 用同一套坐标，
	 * 判定"人是否真的站在电梯轿厢/平台上"，比 600 半径准得多。 */
	if (g_bAreaBox[index])
	{
		float vClient[3];

		GetClientAbsOrigin(client, vClient);

		if (vClient[2] < g_fAreaZMin[index] || vClient[2] > g_fAreaZMax[index])
			return false;

		return (vClient[0] >= g_vAreaBox[index][0] && vClient[0] <= g_vAreaBox[index][1]
		     && vClient[1] >= g_vAreaBox[index][2] && vClient[1] <= g_vAreaBox[index][3]);
	}

	if (g_bAreaRadius[index])
	{
		float vClient[3];
		float vCenter[3];
		float fNeeded = g_fAreaRadius[index];

		if (fNeeded <= 0.0)
		{
			fNeeded = g_cvMechRadius.FloatValue;
		}

		GetClientAbsOrigin(client, vClient);

		/* 1.3.1：中心实时算（父实体感知 + 跟随移动的电梯），不再用回合开始时的快照 */
		GetAreaCenter(index, vCenter);

		return GetVectorDistance(vClient, vCenter) <= fNeeded;
	}

	int entity = GetAreaEntity(index);

	if (entity == -1 || !g_bNtvTouch)
	{
		return false;
	}

	return L4D_IsTouchingTrigger(entity, client);
}

// ===========================================================================
//  传送
// ===========================================================================

/**
 * 1.3.6：取一个"确实站在集合点里"的生还者坐标当传送锚点。
 * 只在人真的落在区域内时有效 —— 半径类区域要求离中心 ANCHOR_MAX_DIST 以内，
 * 避免把 600 半径边缘的人当锚点（那就是"传送到集合点外面"的根因）。
 *
 * @return true = 拿到锚点（vDest 已写入，附带 ±24 抖动）
 */
bool GetSurvivorAnchor(int index, float vDest[3], bool bStrict = true)
{
	int candidates[MAXPLAYERS];
	int count = 0;
	float vCenter[3];
	bool bRadius = g_bAreaRadius[index];

	if (bRadius)
		GetAreaCenter(index, vCenter);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsAliveSurvivor(i) || !IsClientInArea(i, index))
			continue;

		if (bRadius && bStrict)
		{
			float vOrigin[3];

			GetClientAbsOrigin(i, vOrigin);

			if (GetVectorDistance(vOrigin, vCenter) > ANCHOR_MAX_DIST)
				continue;
		}

		/* 挂边 / 倒地的人不能当锚点：传过去也是半空中 */
		if (GetEntProp(i, Prop_Send, "m_isIncapacitated", 1) != 0
			|| GetEntProp(i, Prop_Send, "m_isHangingFromLedge", 1) != 0)
			continue;

		candidates[count++] = i;
	}

	if (count <= 0)
		return false;

	int pick = candidates[GetRandomInt(0, count - 1)];

	GetClientAbsOrigin(pick, vDest);
	vDest[0] += GetRandomFloat(-24.0, 24.0);
	vDest[1] += GetRandomFloat(-24.0, 24.0);

	return true;
}

/**
 * 1.3.6：集合点全员传送的落点。
 * 优先「此刻确实在集合点里的队友位置」（1.3.6 起两档：先 160 HU 内严格锚点，
 * 退一步用区域内任意队友），拿不到才用预设固定点，最后才是区域中心/nav 点。
 */
bool GetCheckpointPoint(int index, float vDest[3])
{
	/* 1.3.6（玩家反馈 c4m2 摔死）：优先落到"此刻确实在集合点里的生还者身上"，
	 * 找不到人再用预设固定点，最后才用区域中心/nav 点。这样传送目标永远是
	 * 人站得住的地方，不会把轿厢外的人丢到电梯井/悬崖下面。 */
	if (GetSurvivorAnchor(index, vDest, true))
		return true;

	/* 第二档：集合点判定半径（如 c4m2 的 700）内没有"贴着中心"的人，
	 * 就退一步用任意一个在区域内的队友位置 —— 仍然是"有人站的地方"，
	 * 总比拿预设点/区域中心当落点安全（预设点可能在电梯井外）。 */
	if (GetSurvivorAnchor(index, vDest, false))
		return true;

	if (g_bAreaDest[index])
	{
		CopyVec(g_vAreaDest[index], vDest);

		return true;
	}

	float vOrigin[3];

	if (g_bAreaCoord[index] || g_bAreaRadius[index] || g_bAreaBox[index])
		GetAreaCenter(index, vOrigin);
	else
	{
		int entity = GetAreaEntity(index);

		if (entity == -1)
			return false;

		GetEntityCenter(entity, vOrigin);
	}

	if (g_bNtvNav)
	{
		int nav = view_as<int>(L4D_GetNearestNavArea(vOrigin, 1000.0, true));

		if (nav)
		{
			L4D_FindRandomSpot(nav, vDest);

			if (vDest[0] != 0.0 || vDest[1] != 0.0 || vDest[2] != 0.0)
				return true;
		}
	}

	CopyVec(vOrigin, vDest);

	return true;
}

bool GetAreaDestination(int index, float vDest[3])
{
	// ---- 0) 预设 / 原版内置表给的固定传送点（最准，优先） ----------------
	// 抖动由 FinishCountdown 按人加，这里只给准确坐标
	if (g_bAreaDest[index])
	{
		CopyVec(g_vAreaDest[index], vDest);

		return true;
	}

	int candidates[MAXPLAYERS];
	int count = 0;
	bool bRadiusArea = g_bAreaRadius[index];
	float vAreaCenter[3];

	if (bRadiusArea)
		GetAreaCenter(index, vAreaCenter);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsAliveSurvivor(i) || !IsClientInArea(i, index))
		{
			continue;
		}

		/* 1.3.4：半径类区域的"在区域内"可能离机关几百单位，拿这种人当锚点会把
		 * 其他人传到半路上（玩家反馈的"传送不到位"）。只认贴着中心的人。 */
		if (bRadiusArea)
		{
			float vClientOrigin[3];

			GetClientAbsOrigin(i, vClientOrigin);

			if (GetVectorDistance(vClientOrigin, vAreaCenter) > ANCHOR_MAX_DIST)
			{
				continue;
			}
		}

		candidates[count++] = i;
	}

	// ---- 1) 已经站在区域内的生还者位置（最可靠） -------------------------
	if (count > 0)
	{
		int pick = candidates[GetRandomInt(0, count - 1)];
		GetClientAbsOrigin(pick, vDest);

		// 轻微抖动，避免整队叠在一个点上互相挤
		vDest[0] += GetRandomFloat(-24.0, 24.0);
		vDest[1] += GetRandomFloat(-24.0, 24.0);

		return true;
	}

	// ---- 2) 区域原点 -> 最近 nav area 的随机点 ---------------------------
	float vOrigin[3];

	if (g_bAreaCoord[index] || g_bAreaRadius[index] || g_bAreaBox[index])
	{
		/* 1.3.1：半径类区域（按钮 / 坐标）走实时中心，电梯移动后落点才不会
		 * 还是回合开始时的位置；纯坐标区域没有实体，GetAreaCenter 会用快照。 */
		GetAreaCenter(index, vOrigin);
	}
	else
	{
		int entity = GetAreaEntity(index);

		if (entity == -1)
		{
			return false;
		}

		GetEntityCenter(entity, vOrigin);
	}

	if (g_bNtvNav)
	{
		int nav = view_as<int>(L4D_GetNearestNavArea(vOrigin, 1000.0, true));

		if (nav)
		{
			L4D_FindRandomSpot(nav, vDest);

			if (vDest[0] != 0.0 || vDest[1] != 0.0 || vDest[2] != 0.0)
			{
				return true;
			}
		}
	}

	// ---- 3) 兜底：直接站在区域原点 ---------------------------------------
	CopyVec(vOrigin, vDest);

	return true;
}

void TeleportSurvivor(int client, const float vDest[3])
{
	if (g_cvReleaseSi.BoolValue)
	{
		ReleaseDominated(client);
	}

	if (g_cvRevive.BoolValue && g_bNtvRevive && L4D_IsPlayerHangingFromLedge(client))
	{
		L4D_ReviveSurvivor(client);
	}

	// 解冻 + 缩小碰撞体积，避免传送进天花板 / 卡在几何体里
	SetEntityMoveType(client, MOVETYPE_WALK);
	SetEntityFlags(client, GetEntityFlags(client) & ~FL_FROZEN);
	SetEntProp(client, Prop_Send, "m_bDucked", 1);
	SetEntityFlags(client, GetEntityFlags(client) | FL_DUCKING);

	TeleportEntity(client, vDest, NULL_VECTOR, NULL_VECTOR);

	if (g_bNtvWarp)
	{
		L4D_WarpToValidPositionIfStuck(client);
	}
}

/**
 * 解除特感对生还者的控制。不杀死任何玩家。
 */
void ReleaseDominated(int client)
{
	if (!g_bNtvDominating || !g_bNtvRelease)
	{
		return;
	}

	int attacker = L4D2_GetSpecialInfectedDominatingMe(client);

	if (attacker < 1 || attacker > MaxClients)
	{
		return;
	}

	if (!IsClientInGame(attacker) || GetClientTeam(attacker) != TEAM_INFECTED)
	{
		return;
	}

	if (GetEntProp(attacker, Prop_Send, "m_tongueVictim") > 0)
	{
		L4D_Smoker_ReleaseVictim(client, attacker);
	}
	else if (GetEntProp(attacker, Prop_Send, "m_pounceVictim") > 0)
	{
		L4D_Hunter_ReleaseVictim(client, attacker);
	}
	else if (GetEntProp(attacker, Prop_Send, "m_jockeyVictim") > 0)
	{
		L4D2_Jockey_EndRide(client, attacker);
	}
	else if (GetEntProp(attacker, Prop_Send, "m_carryVictim") > 0)
	{
		L4D2_Charger_EndCarry(client, attacker);
	}
	else if (GetEntProp(attacker, Prop_Send, "m_pummelVictim") > 0)
	{
		L4D2_Charger_EndPummel(client, attacker);
	}
}

void RemoveInfectedAround(const float vPos[3])
{
	float vEnt[3];
	int maxEntities = GetMaxEntities();

	for (int i = MaxClients + 1; i < maxEntities; i++)
	{
		if (!IsValidEntity(i))
		{
			continue;
		}

		char sClass[64];

		if (!GetEntityClassname(i, sClass, sizeof(sClass)))
		{
			continue;
		}

		if (!StrEqual(sClass, "infected") && !StrEqual(sClass, "witch"))
		{
			continue;
		}

		GetEntPropVector(i, Prop_Send, "m_vecOrigin", vEnt);

		if (GetVectorDistance(vEnt, vPos) <= INFECTED_CLEAR_RADIUS)
		{
			KillEntNextFrame(i);
		}
	}
}

// ===========================================================================
//  指令 / 工具
// ===========================================================================

public Action Cmd_Status(int client, int args)
{
	char sType[16];
	char sSrc[16];
	int total = CountAliveSurvivors();

	ReplyToCommand(client, "[cptele] enable=%d ready=%d 区域数=%d 存活生还者=%d 集合点来源=%s",
		g_cvEnable.BoolValue, g_bReady, g_iAreaCount, total,
		g_bSiteAuthority ? "预设/原版地点" : "运行时侦测");

	ReplyToCommand(client, "[cptele] 安全屋/救援点: %d%%(%d名) %d秒 | 中途集合点: %d%%(%d名) %d秒",
		g_cvPercent.IntValue, AreaRequiredCount(AREA_SAFEROOM, total), g_cvTime.IntValue,
		g_cvCpPercent.IntValue, AreaRequiredCount(AREA_CHECKPOINT, total), g_cvCpTime.IntValue);

	// 1.3.0：集合完毕提前结束的口径也一并打出来，排错时一眼能看出「为什么倒计时自己停了」
	ReplyToCommand(client, "[cptele] 中途集合点全员到过即结束倒计时=%d（需 skip_seen=1，当前 %d）| 已到过=%d",
		g_cvCpFinishAllSeen.BoolValue, g_cvSkipSeen.BoolValue, CountSeenSurvivors());

	for (int i = 0; i < g_iAreaCount; i++)
	{
		GetAreaTypeName(g_iAreaType[i], sType, sizeof(sType));
		GetAreaSourceName(g_iAreaSource[i], sSrc, sizeof(sSrc));

		/* 1.3.1：把判定中心一起打出来。父实体下的按钮如果中心塌到接近 (0,0,0)，
		 * 一眼就能看出是「实体坐标不世界化」的问题，不用再靠猜。 */
		float vCenter[3];
		GetAreaCenter(i, vCenter);

		ReplyToCommand(client, "  #%d %s/%s ent=%d 距离判定=%d 方框判定=%d 中心=%.0f %.0f %.0f 已到达=%d 已触发=%d",
			i, sType, sSrc, GetAreaEntity(i), g_bAreaRadius[i], g_bAreaBox[i],
			vCenter[0], vCenter[1], vCenter[2],
			CountArrivedSurvivors(i), g_bAreaFired[i]);

		if (g_bAreaBox[i])
		{
			ReplyToCommand(client, "      方框 x[%.0f..%.0f] y[%.0f..%.0f] z[%.0f..%.0f]",
				g_vAreaBox[i][0], g_vAreaBox[i][1], g_vAreaBox[i][2], g_vAreaBox[i][3],
				g_fAreaZMin[i], g_fAreaZMax[i]);
		}

		/* 1.3.8：半径类集合点起倒计时还要过一道「核心半径内必须有人」的门槛。
		 * 比例达标但倒计时不起时，看这一行就能判断是不是被这道门槛挡住
		 * （这也是 c1m1「还没走到电梯就起倒计时」的修复点）。 */
		if (g_bAreaRadius[i] && !g_bAreaBox[i])
		{
			bool bCore = HasCoreSurvivor(i);

			ReplyToCommand(client, "      核心半径 %.0f 内有人=%d（%s）",
				g_cvCpCoreRadius.FloatValue, bCore ? 1 : 0,
				bCore ? "允许起倒计时" : "比例达标也不起倒计时");
		}
	}

	if (g_bCountingDown)
	{
		GetAreaTypeName(g_iAreaType[g_iActiveArea], sType, sizeof(sType));
		ReplyToCommand(client, "  倒计时进行中：区域 #%d（%s），剩余 %d 秒",
			g_iActiveArea, sType, g_iSecondsLeft);
	}

	return Plugin_Handled;
}

public Action Cmd_ReloadPresets(int client, int args)
{
	delete g_hPresets;
	g_hPresets = null;
	g_bPresetsTried = false;

	// 1.3.1：原版地点表同样是「每张图读一次」，换图 / 重载一并释放
	delete g_hLegacy;
	g_hLegacy = null;
	g_bLegacyTried = false;

	// ResetRound() 会清掉 g_bRescueReady，但排错时重读配置不该把
	// 「救援车已到位」这个事实一起忘掉，否则终局图会重新等一次事件。
	bool bRescueReady = g_bRescueReady;

	ResetRound();
	g_bRescueReady = bRescueReady;

	DetectAreas();
	EnsureMonitor();

	ReplyToCommand(client, "[cptele] 已重新读取预设配置并重新侦测，当前区域数=%d（集合点来源=%s）",
		g_iAreaCount, g_bSiteAuthority ? "预设/原版地点" : "运行时侦测");

	return Plugin_Handled;
}

public Action Cmd_Force(int client, int args)
{
	if (!g_bReady)
	{
		ReplyToCommand(client, "[cptele] 插件未就绪（left4dhooks native 缺失）");
		return Plugin_Handled;
	}

	if (!g_cvEnable.BoolValue)
	{
		ReplyToCommand(client, "[cptele] 插件总开关已关闭（l4d2_cptele_enable 0）");
		return Plugin_Handled;
	}

	if (g_iAreaCount == 0)
	{
		ReplyToCommand(client, "[cptele] 还没有侦测到任何区域");
		return Plugin_Handled;
	}

	if (g_bCountingDown)
	{
		ReplyToCommand(client, "[cptele] 已经在倒计时中（区域 #%d，剩余 %d 秒），忽略",
			g_iActiveArea, g_iSecondsLeft);
		return Plugin_Handled;
	}

	// 可用 sm_cptele_force <区域序号> 指定区域；省略时取最后一个
	int index = g_iAreaCount - 1;

	if (args >= 1)
	{
		index = GetCmdArgInt(1);

		if (index < 0 || index >= g_iAreaCount)
		{
			ReplyToCommand(client, "[cptele] 区域序号越界，有效范围 0..%d", g_iAreaCount - 1);
			return Plugin_Handled;
		}
	}

	int total = CountAliveSurvivors();

	StartCountdown(index, CountArrivedSurvivors(index), total);

	ReplyToCommand(client, "[cptele] 已强制对区域 #%d 开始倒计时", index);

	return Plugin_Handled;
}

stock bool NtvAvailable(const char[] name)
{
	return GetFeatureStatus(FeatureType_Native, name) == FeatureStatus_Available;
}

/**
 * 播放倒计时提示音。
 *
 * 逐个客户端调用 EmitSoundToClient，而不是 EmitSoundToAll(…, SOUND_FROM_PLAYER …)：
 * SOUND_FROM_PLAYER(-2) 语义是「以接收者自身为发声实体」，只有单客户端调用时
 * 才能被正确解析；一次性传给多个客户端时 -2 不是合法实体索引，表现为听不到声。
 * 参考A / 参考B 也都是逐客户端播放的。
 */
stock void EmitCountdownSound()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
		{
			continue;
		}

		EmitSoundToClient(i, SOUND_COUNTDOWN, SOUND_FROM_PLAYER, SNDCHAN_STATIC,
			SNDLEVEL_NORMAL, SND_NOFLAGS, SNDVOL_NORMAL, SNDPITCH_NORMAL);
	}
}

stock void CopyVec(const float src[3], float dst[3])
{
	dst[0] = src[0];
	dst[1] = src[1];
	dst[2] = src[2];
}

/**
 * trigger / changelevel 这类「体积判定」实体，用 L4D_IsTouchingTrigger；
 * 其余（func_button 等点状实体）与纯坐标区域用距离判定。
 */
stock bool IsTouchModeClass(const char[] sClass)
{
	return StrEqual(sClass, "trigger_multiple", false)
	    || StrEqual(sClass, "trigger_once", false)
	    || StrEqual(sClass, "trigger_hurt", false)
	    || StrEqual(sClass, "trigger_push", false)
	    || StrEqual(sClass, "info_changelevel", false)
	    || StrEqual(sClass, "trigger_changelevel", false);
}

/**
 * 可以「解锁并按下」的按钮类实体。
 * 限定白名单，避免误配时对门 / 其它带 use 输入的实体动手。
 */
stock bool IsButtonClass(const char[] sClass)
{
	return StrEqual(sClass, "func_button", false)
	    || StrEqual(sClass, "func_rot_button", false)
	    || StrEqual(sClass, "prop_button", false);
}

/**
 * 从字符串里读下一个数字（以空格 / 制表符 / 逗号分隔）。
 * 用逐字符扫描而不是 SplitString：SplitString 不改写源串，
 * 遇到连续空格会产生空字段，把 "1  2 3" 解析成 1/0/2。
 */
stock bool NextNumberToken(const char[] sBuf, int &iPos, float &fValue)
{
	int iLen = strlen(sBuf);
	int i = iPos;

	while (i < iLen && (sBuf[i] == ' ' || sBuf[i] == '\t' || sBuf[i] == ','))
	{
		i++;
	}

	if (i >= iLen)
	{
		iPos = i;
		return false;
	}

	int iStart = i;

	while (i < iLen && sBuf[i] != ' ' && sBuf[i] != '\t' && sBuf[i] != ',')
	{
		i++;
	}

	char sNum[48];
	int n = i - iStart;

	if (n >= sizeof(sNum))
	{
		n = sizeof(sNum) - 1;
	}

	for (int k = 0; k < n; k++)
	{
		sNum[k] = sBuf[iStart + k];
	}

	sNum[n] = '\0';
	fValue = StringToFloat(sNum);
	iPos = i;

	return true;
}

/**
 * 解析 "x y z"（也接受 "x,y,z"）。
 */
/**
 * 1.3.7：解析 "x1 y1 x2 y2"（spit_block_square 那四个数，顺序随意）。
 */
stock bool ParseSquare(const char[] sValue, float vOut[4])
{
	int iPos = 0;

	for (int i = 0; i < 4; i++)
	{
		if (!NextNumberToken(sValue, iPos, vOut[i]))
			return false;
	}

	return true;
}

stock bool ParseFloatToken(const char[] sValue, float &fOut)
{
	char sTrim[64];

	strcopy(sTrim, sizeof(sTrim), sValue);
	TrimString(sTrim);

	if (sTrim[0] == '\0' || (sTrim[0] != '-' && sTrim[0] != '+' && (sTrim[0] < '0' || sTrim[0] > '9')))
		return false;

	fOut = StringToFloat(sTrim);

	return true;
}

stock bool ParseVec(const char[] sValue, float vOut[3])
{
	int iPos = 0;

	for (int i = 0; i < 3; i++)
	{
		if (!NextNumberToken(sValue, iPos, vOut[i]))
		{
			return false;
		}
	}

	return true;
}

/**
 * 按 classname（+ 可选 targetname）找实体。
 * targetname 为空时返回该类第一个实体。
 */
stock int FindEntityByClassTargetName(const char[] sClass, const char[] sTarget)
{
	if (sClass[0] == '\0')
	{
		return -1;
	}

	char sName[128];
	int entity = -1;

	while ((entity = FindEntityByClassname(entity, sClass)) != -1)
	{
		if (sTarget[0] == '\0')
		{
			return entity;
		}

		sName[0] = '\0';

		if (!GetEntPropString(entity, Prop_Data, "m_iName", sName, sizeof(sName)))
		{
			continue;
		}

		if (StrEqual(sName, sTarget, false))
		{
			return entity;
		}
	}

	return -1;
}

/**
 * 取实体的父实体索引（没有父级返回 -1）。
 *
 * m_pParent 在 datamap 里是 edict 句柄，换图 / 实体回收后会残留，
 * 所以这里统一做「越界 / 自指 / 无效」三重校验，避免顺着残影往上爬。
 */
stock int GetEntityParent(int entity)
{
	if (entity <= 0 || !IsValidEntity(entity))
	{
		return -1;
	}

	if (!HasEntProp(entity, Prop_Data, "m_pParent"))
	{
		return -1;
	}

	int parent = GetEntPropEnt(entity, Prop_Data, "m_pParent");

	if (parent <= 0 || parent == entity || parent == INVALID_ENT_REFERENCE || !IsValidEntity(parent))
	{
		return -1;
	}

	return parent;
}

/**
 * 把「父实体局部坐标系里的偏移」旋成世界方向。
 *
 * Source 的局部轴就是三个基准向量：局部 X = 父的前向，Y = 父的右向，Z = 父的上向。
 */
stock void RotateLocalOffset(const float vOffset[3], const float vAngles[3], float vOut[3])
{
	float vForward[3];
	float vRight[3];
	float vUp[3];

	GetAngleVectors(vAngles, vForward, vRight, vUp);

	/* vOffset 可能与 vOut 是同一块内存（就地旋转），逐元素写不会互相踩：
	 * 读到 vOffset[1] 时 vOut[1] 还没被写，vOffset[2] 同理。 */
	for (int i = 0; i < 3; i++)
	{
		vOut[i] = vForward[i] * vOffset[0] + vRight[i] * vOffset[1] + vUp[i] * vOffset[2];
	}
}

/**
 * 取实体的「世界坐标原点」（父实体感知）。
 *
 * 1.3.1 新增。**这是 1.3.0 及以前最致命的坑**：父实体（parentname）下的
 * m_vecOrigin 是相对父级的局部坐标——引擎在 SetParent 时把世界坐标减掉了
 * 父实体的原点与角度，之后 GetAbsOrigin() / CalcAbsolutePosition() 才按父级
 * 变换算回世界坐标。插件以前直接读 m_vecOrigin 当世界坐标用，于是
 *
 *   c1m1_hotel    elevator_button        (parent elevator_1)
 *   c1m4_atrium   button_elev_3rdfloor   (parent elevator)
 *   c3m1_plankcountry ferry_tram_button  (parent ferry_tram)
 *   c4m2/c4m3     button_inelevator      (parent elevator)
 *
 * 这些条目的区域中心全部塌到「局部坐标」（≈ 几个单位，接近地图原点），
 * 生还者站到电梯上距离那个幻影中心还有几千 HU，CountArrivedSurvivors()
 * 恒为 0 → Timer_Monitor 永远达不到到齐比例 → 传送倒计时永不触发。
 * 表现就是「电梯上人齐也不倒计时，按按钮也没反应」。
 *
 * 处理方式：从实体自身往上逐级累加父实体的世界原点，并且每一级的局部
 * 偏移先按该父实体的角度旋转（电梯/渡轮这类父实体角度通常是 0，旋转只是
 * 兜底，保证换了模型朝向的图也不会算错）。层数上限 8 层，足够覆盖地图里
 * 的「按钮→车厢→门框」这类三级挂接，同时防止循环父级把服务器卡死。
 */
stock void GetEntityWorldOrigin(int entity, float vOut[3])
{
	GetEntPropVector(entity, Prop_Send, "m_vecOrigin", vOut);

	int current = entity;

	for (int depth = 0; depth < 8; depth++)
	{
		int parent = GetEntityParent(current);

		if (parent == -1)
		{
			break;
		}

		float vParentOrigin[3];
		float vParentAngles[3];

		GetEntPropVector(parent, Prop_Send, "m_vecOrigin", vParentOrigin);

		if (HasEntProp(parent, Prop_Send, "m_angRotation"))
		{
			GetEntPropVector(parent, Prop_Send, "m_angRotation", vParentAngles);
		}
		else
		{
			vParentAngles[0] = 0.0;
			vParentAngles[1] = 0.0;
			vParentAngles[2] = 0.0;
		}

		RotateLocalOffset(vOut, vParentAngles, vOut);

		for (int i = 0; i < 3; i++)
		{
			vOut[i] += vParentOrigin[i];
		}

		current = parent;
	}
}

/**
 * 取实体的「几何中心」（世界坐标）。
 *
 * brush 实体（trigger_multiple / info_changelevel / trigger_finale）的
 * m_vecOrigin 往往是 (0,0,0)，真正的体积写在 m_vecMins / m_vecMaxs 里，
 * 而且这两个值已经是世界坐标。点实体（如部分 func_button）反过来是
 * m_vecOrigin 有值、mins/maxs 为 0。
 *
 * center = 世界原点 + (mins + maxs) / 2 同时覆盖两种情况：
 * 点实体因为 mins = maxs = 0，结果就是世界原点。
 *
 * 1.3.1：原点的读取换成 GetEntityWorldOrigin()（父实体感知）。
 * mins/maxs 的半宽没有跟着父级角度旋转——它的量级只有实体自身的尺寸
 * （按钮这类 ≤ 十几 HU），旋转与否对「距离 <= 半径」的判定没有影响。
 */
stock void GetEntityCenter(int entity, float vCenter[3])
{
	float vOrigin[3];
	float vMins[3];
	float vMaxs[3];

	GetEntityWorldOrigin(entity, vOrigin);
	GetEntPropVector(entity, Prop_Send, "m_vecMins", vMins);
	GetEntPropVector(entity, Prop_Send, "m_vecMaxs", vMaxs);

	for (int i = 0; i < 3; i++)
	{
		vCenter[i] = vOrigin[i] + (vMins[i] + vMaxs[i]) * 0.5;
	}
}

/**
 * 取区域的判定中心（世界坐标），**每次调用实时算**。
 *
 * 1.3.1 新增。电梯 / 渡轮 / 移动平台当集合点时，按钮跟着父实体一起走，
 * 回合开始时快照下来的 g_vAreaPos 会在车一动之后立刻过期。所以：
 *   · 纯坐标区域（预设里只写了 origin）：用存下来的坐标；
 *   · 实体区域：实时按 GetEntityCenter() 重算（父实体原地不动时结果相同）。
 * 实体已经消失（例如 c4m2 的车厢按钮按下后自删）时退回快照坐标。
 */
stock void GetAreaCenter(int index, float vCenter[3])
{
	if (g_bAreaBox[index])
	{
		vCenter[0] = (g_vAreaBox[index][0] + g_vAreaBox[index][1]) * 0.5;
		vCenter[1] = (g_vAreaBox[index][2] + g_vAreaBox[index][3]) * 0.5;
		vCenter[2] = (g_fAreaZMin[index] + g_fAreaZMax[index]) * 0.5;

		return;
	}

	if (!g_bAreaCoord[index])
	{
		int entity = GetAreaEntity(index);

		if (entity != -1)
		{
			GetEntityCenter(entity, vCenter);
			return;
		}
	}

	CopyVec(g_vAreaPos[index], vCenter);
}

void ResetRound()
{
	delete g_hCountdown;
	g_hCountdown = null;

	delete g_hMonitor;
	g_hMonitor = null;

	// 安全屋结算状态机（1.2.4 起是「一次性 timer 逐 tick 续命」）。
	// 先让世代号 +1：所有在途的旧 tick 会看到 gen 不匹配而立即退出，不会再续命。
	// 再 delete 挂起的那一个（此时它一定是我们刚挂上、还没触发的，关闭只会发生一次）。
	// 注意顺序：必须**先**改世代号再 delete，否则 delete 之后引擎仍可能投递已排队的 tick。
	g_iSettleGen++;
	if (g_hDoorFix != null)
	{
		delete g_hDoorFix;
	}
	g_hDoorFix = null;
	g_iDoorFixArea = -1;
	g_iDoorFixRef = 0;
	g_fSettleDeadline = 0.0;
	g_iSettleRetry = 0;
	g_fSettleNextRetry = 0.0;
	g_iSettleOpenTries = 0;
	g_fSettleNextOpenTry = 0.0;
	g_bSettleDoorOpened = false;
	g_bSettleDoorClosed = false;
	g_bSettleEventFired = false;

	g_bCountingDown = false;
	g_iSecondsLeft = 0;
	g_iActiveArea = -1;
	g_bRescueReady = false;
	g_bSiteAuthority = false;

	ClearSeenFlags();

	// 1.3.2：救援区忽略名单也跟着回合清空，等 DetectAreas 读配置时重新解析
	ClearRescueIgnore();

	// 1.2.7：进入区域提示的在场/播报状态也要清（换图、换回合）
	ClearEnterNoticeState();

	for (int i = 0; i < MAX_AREAS; i++)
	{
		g_iAreaRef[i] = 0;
		g_iAreaType[i] = AREA_SAFEROOM;
		g_iAreaSource[i] = SRC_AUTO;
		g_bAreaFired[i] = false;
		g_bAreaCoord[i] = false;
		g_bAreaRadius[i] = false;
		g_bAreaDest[i] = false;
		g_fAreaCooldown[i] = 0.0;
		g_fAreaRadius[i] = 0.0;

		for (int j = 0; j < 3; j++)
		{
			g_vAreaPos[i][j] = 0.0;
			g_vAreaDest[i][j] = 0.0;
		}
	}

	g_iAreaCount = 0;
}

// ===========================================================================
//  延迟删除：把删实体推迟到下一帧，避免在引擎回调/实体遍历中途删（崩溃排查用）
//  RequestFrame 在 SM 1.12 支持带 any data 参数，比 CreateTimer(0.0) 更贴近"下一帧"，
//  也不会额外创建 timer 对象。
// ===========================================================================
void KillEntNextFrame(int entity)
{
	if (entity <= 0 || !IsValidEntity(entity))
		return;

	RequestFrame(Frame_KillEntNextFrame, EntIndexToEntRef(entity));
}

public void Frame_KillEntNextFrame(any ref)
{
	int ent = EntRefToEntIndex(ref);
	if (ent != INVALID_ENT_REFERENCE && ent > 0 && IsValidEntity(ent))
		AcceptEntityInput(ent, "Kill");
}
