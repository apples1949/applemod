#pragma semicolon 1
#pragma newdecls required

#include <colors>
#include <readyup>
#include <sourcemod>
#include <left4dhooks>

/* =========================================================================
   本文件是 l4d_tank_control_eq.sp 的修改版(修改: apples1949)
   原版负责"谁当坦克"(队列 / 强制窗口 / 掉线坦克的控制权与 grace 继承), 本版在其上
   接管"跟踪石命中生还者后的坦克控制权调整" —— 这套逻辑原先写在 Apex.sp 里
   (Apex 每帧观察引擎改动并按 base->step 比例补正 + 钉值), 现整体迁到本插件, 理由:
     1. 控制权(m_frustration 与紧跟其后的 m_frustrationTimer)的读写、钳制、
        交接/重置语义集中在一个插件里, 不再由两个插件各写一套;
     2. Apex 只负责"跟踪石发生了什么"(命中 / 退还 / 打碎 / 掷出扣血), 命中时通过
        forward Apex_OnTracRockHit(tank, victim) 通知本插件(不需要 include, 无依赖);
     3. 控制权相关参数就是本插件自己的 cvar: tankcontrol_trac_base / _step / _debug
        (不额外生成 cfg 文件, 要改就在控制台或 confogl 的 cfg 里 confogl_addcvar 设置)。
     4. 每格怒气的"有效幅度"由三条规则取最大值决定(不叠加): 基线 5% / 坦克存活满
        tankcontrol_trac_longlife_time 秒后 longlife_step / 跟踪石命中状态 step。
        默认值全部中性(不加速), 这套加速只在 12v12 配置里由 confogl_addcvar 打开。
        幅度提升时会私聊通知坦克本人(tankcontrol_trac_notify)。

   命名口径提醒: 原版的"控制权/frustration"是 GetTankFrustration = 100 - m_frustration,
   而下面跟踪石那套逻辑直接操作引擎原始值 m_frustration(与引擎以及 l4d2_tankrage /
   godframes 等怒气插件同一口径), 注释里都写明是"原始 m_frustration"。
   ========================================================================= */
#define CTRL_PUSH_BACK_MAX    5         /* 同一轮补正最多压回几次(防止和引擎每帧对拉) */

#define TEAM_SPECTATOR          1
#define TEAM_INFECTED           3
#define ZOMBIECLASS_TANK        8
#define IS_SPECTATOR(%1)        (GetClientTeam(%1) == TEAM_SPECTATOR)
#define IS_INFECTED(%1)         (GetClientTeam(%1) == TEAM_INFECTED)
#define IS_VALID_INFECTED(%1)   (IsClientInGame(%1) && IS_INFECTED(%1))
#define IS_VALID_SPECTATOR(%1)  (IsClientInGame(%1) && IS_SPECTATOR(%1))

ArrayList h_whosHadTank;
ArrayList h_tankQueue;

ConVar 
    hTankPrint,
    hTankWindow, 
    hTracCtrlBase,          /* 基线: 引擎日常的怒气步进幅度(%), 只用于换算比例 */
    hTracCtrlStep,          /* 跟踪石命中状态: 每格怒气的扣除幅度(%) */
    hTracCtrlAfter,         /* 跟踪石: 命中后持续按 step% 扣的时长(秒, 0=直到坦克死亡/换控) */
    hTracCtrlLongLifeTime,  /* 长存活门限(秒): 坦克从拿到控制权起存活满这么久仍未死亡 */
    hTracCtrlLongLifeStep,  /* 长存活状态: 满门限后每格怒气的扣除幅度(%) */
    hTracCtrlNotify;        /* 1 = 每格怒气消耗幅度提升时私聊通知坦克本人 */

GlobalForward
    hForwardOnTryOfferingTankBot,
    hForwardOnTankSelection;

char 
    queuedTankSteamId[64],
    tankInitiallyChosen[64];

float 
    fTankGrace,
    initialTankLeft,
    gotTankAt;

int dcedTankFrustration = -1;

/* ---------------- 跟踪石命中后的持续状态(自 Apex.sp 迁入) ---------------- */
int   g_iTracWantMeter[MAXPLAYERS + 1];   /* 我们补正后的 m_frustration(目标值) */
int   g_iTracKnownMeter[MAXPLAYERS + 1];  /* 我们最后认可/写入的 m_frustration(检测基准) */
int   g_iTracEngineMeter[MAXPLAYERS + 1]; /* 引擎最后一次自己写入的 m_frustration(识别补正被写回) */
int   g_iTracPushBacks[MAXPLAYERS + 1];   /* 本轮补正被写回后压回去的次数(防止和引擎每帧对拉) */
bool  g_bTracAfter[MAXPLAYERS + 1];       /* 是否处于"跟踪石命中后每格怒气按 step% 扣"的状态 */
float g_fTracAfterUntil[MAXPLAYERS + 1];  /* 持续状态截止(0 = 直到坦克死亡/控制权交接) */
bool  g_bTracTracking[MAXPLAYERS + 1];    /* 是否已进入补正状态机(跟踪石 或 长存活, 任一成立即需要) */

/* ---------------- 坦克"长存活"状态(存活满 N 秒后每格怒气幅度加大) ----------------
   gotTankAt 是原版给"强制窗口(tankcontrol_force_window)"用的单值全局变量, 只记"最后一个
   拿到坦克的人", 12v12 同时存在多辆坦克时不够用; 而且强制窗口那套语义不能动, 所以长存活
   规则另外开一份按客户端索引的记录, 与 gotTankAt 互不影响:
     g_fTankGotAt  —— 这辆坦克"真正拿到控制权"的 GetGameTime 时刻(0 = 当前没在跟踪);
     g_bTankLongLife —— 是否已经存满门限(闩锁: 一旦成立就保持到死亡/交接/换回合)。 */
float g_fTankGotAt[MAXPLAYERS + 1];
bool  g_bTankLongLife[MAXPLAYERS + 1];

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    /* 原版忘了注册库名(include 里 SharedPlugin 声明的是 name = "l4d_tank_control_eq"),
       这里补上, 让 LibraryExists("l4d_tank_control_eq") 与依赖机制(RECOMMENDED: 消费方仍应按可选依赖写)生效 */
    RegPluginLibrary("l4d_tank_control_eq");

    CreateNative("GetTankSelection", Native_GetTankSelection);

    hForwardOnTryOfferingTankBot = new GlobalForward("TankControl_OnTryOfferingTankBot", ET_Ignore, Param_String);
    hForwardOnTankSelection = new GlobalForward("TankControl_OnTankSelection", ET_Ignore, Param_String);

    return APLRes_Success;
}

int Native_GetTankSelection(Handle plugin, int numParams) { return getInfectedPlayerBySteamId(queuedTankSteamId); }

public Plugin myinfo = 
{
    name = "L4D2 Tank Control",
    author = "apples1949 (原版: arti, Sheo, Sir, Altair-Sossai)",
    description = "Distributes the role of the tank evenly throughout the team, allows for overrides. (Includes forwards) [修改版: 跟踪石命中后怒气每格按 step% 扣; 无日志无控制台输出]",
    version = "0.0.31-applemod",
    url = "https://github.com/SirPlease/L4D2-Competitive-Rework"
}

public void OnPluginStart()
{
    LoadTranslation("l4d_tank_control_eq.phrases");
    LoadTranslations("common.phrases");
    
    // Event hooks
    HookEvent("player_left_start_area", PlayerLeftStartArea_Event, EventHookMode_PostNoCopy);
    HookEvent("round_start", RoundStart_Event, EventHookMode_PostNoCopy);
    HookEvent("round_end", RoundEnd_Event, EventHookMode_PostNoCopy);
    HookEvent("player_team", PlayerTeam_Event, EventHookMode_Post);
    HookEvent("player_death", PlayerDeath_Event, EventHookMode_Post);
    /* tank_spawn: 坦克本体出现的时刻。L4D2_OnTankPassControl 只在"换控"时触发, 回合里第一辆
       坦克拿到控制权不会走那条 forward, 靠这个事件补上长存活的计时起点。 */
    HookEvent("tank_spawn", TankSpawn_Event, EventHookMode_Post);
    
    // Initialise the tank arrays/data values
    h_whosHadTank = new ArrayList(ByteCountToCells(64));
    h_tankQueue = new ArrayList(ByteCountToCells(64));

    // Admin commands
    RegAdminCmd("sm_tankshuffle", TankShuffle_Cmd, ADMFLAG_SLAY, "Re-picks at random someone to become tank.");
    RegAdminCmd("sm_givetank", GiveTank_Cmd, ADMFLAG_SLAY, "Gives the tank to a selected player");

    // Register the boss commands
    RegConsoleCmd("sm_tank", Tank_Cmd, "Shows who is becoming the tank.");
    RegConsoleCmd("sm_boss", Tank_Cmd, "Shows who is becoming the tank.");
    RegConsoleCmd("sm_witch", Tank_Cmd, "Shows who is becoming the tank.");
    
    // Cvars
    hTankPrint  = CreateConVar("tankcontrol_print_all", "0", "Who gets to see who will become the tank? (0 = Infected, 1 = Everyone)");
    hTankWindow = CreateConVar("tankcontrol_force_window", "0.0", "Give player that was initially going to be Tank (or was Tank and dced) back the Tank this long after Tank was given to somebody else (0 = Off)");

    /* 跟踪石命中生还者后的控制权调整(自 Apex.sp 迁入; 直接操作引擎原始 m_frustration)
       注: 按需求不生成 cfg 文件, 参数用本组 cvar 的默认值; 要临时改就在控制台设,
           或在 confogl 的 cfg 里 confogl_addcvar tankcontrol_trac_step 6 这样覆盖。

       每格怒气的"有效幅度"取以下三者的最大值(不叠加):
         基线 base(5%) / 长存活 longlife_step / 跟踪石命中状态 step
       两个条件同时成立时仍然是 max, 不是相加。

       【生效范围】"消耗加速"只在 12v12 配置里实装:
         step / longlife_time / longlife_step 的源码默认值都是中性的
         (step=base=5.0, longlife_time=0=关闭, longlife_step=5.0),
         只有 cfg/cfgogl/applemod12v12/applemod12v12.cfg 用 confogl_addcvar
         把它们设成 7.0 / 240.0 / 6.0。别的模式即使加载本插件也不会加速掉控。

       【通知】有效幅度提升时(跟踪石命中 / 存活满门限)私聊通知坦克本人,
         由 tankcontrol_trac_notify 开关(默认 1)。 */
    hTracCtrlBase  = CreateConVar("tankcontrol_trac_base", "5.0", "基线: 引擎日常的怒气步进幅度(%%). 只用于换算比例(max 语义的基准), 不会写进游戏");
    /* 默认值必须是中性的(与基线相同 = 不加速): 这套"消耗加速"只在 12v12 配置里生效,
       由 cfg/cfgogl/applemod12v12/applemod12v12.cfg 的 confogl_addcvar 抬高到 7.0。
       这样别的模式/配置就算也加载了本插件, 也不会莫名其妙掉控更快。 */
    hTracCtrlStep  = CreateConVar("tankcontrol_trac_step", "5.0", "跟踪石命中后, 每格怒气的扣除幅度(%%): 引擎每落一格怒气就补成该幅度. 命中本身不扣任何东西. 该值也是每格幅度的上限. 默认 5.0 = 与基线相同(不加速), 仅 12v12 配置里由 confogl_addcvar 设为 7.0");
    hTracCtrlAfter = CreateConVar("tankcontrol_trac_after", "0.0", "跟踪石命中后, 持续按 step%% 扣的时长(秒). 0 = 直到坦克死亡或控制权交接");

    /* 长存活规则: 坦克从"真正拿到控制权"起存活满 longlife_time 秒仍未死亡, 之后每格怒气
       幅度提升到 longlife_step%. longlife_time <= 0 关闭这条规则(不影响跟踪石那条)。
       与跟踪石状态取 max, 不叠加。默认 0 = 关闭, 仅 12v12 配置里由 confogl_addcvar 开启(240 秒)。 */
    hTracCtrlLongLifeTime = CreateConVar("tankcontrol_trac_longlife_time", "0.0", "坦克拿到控制权后存活满这么多秒仍未死亡, 该坦克每格怒气幅度提升到 longlife_step%%. <=0 关闭这条规则. 默认 0 = 关闭, 仅 12v12 配置里由 confogl_addcvar 设为 240.0");
    hTracCtrlLongLifeStep = CreateConVar("tankcontrol_trac_longlife_step", "5.0", "存活满 longlife_time 秒后, 每格怒气的扣除幅度(%%). 默认 5.0 = 与基线相同(不加速), 仅 12v12 配置里由 confogl_addcvar 设为 6.0");
    hTracCtrlNotify = CreateConVar("tankcontrol_trac_notify", "1", "每格怒气消耗幅度提升时(跟踪石命中 / 存活时间达到门限), 是否私聊通知坦克本人. 0=不通知 1=通知", _, true, 0.0, true, 1.0);
}


/*=========================================================================
|                            Left4Dhooks                                  |
=========================================================================*/


public void L4D2_OnTankPassControl(int iOldTank, int iNewTank, int iPassCount)
{
    /*
    * As the Player switches to AI on disconnect/team switch, we have to make sure we're only checking this if the old Tank was AI.
    * Then apply the previous' Tank's Frustration and Grace Period (if it still had Grace)
    * We'll also be keeping the same Tank pass, which resolves Tanks that dc on 1st pass resulting into the Tank instantly going to 2nd pass.
    */
    if (dcedTankFrustration != -1 && IsFakeClient(iOldTank))
    {
        SetTankFrustration(iNewTank, dcedTankFrustration);
        CTimer_Start(GetFrustrationTimer(iNewTank), fTankGrace);
        L4D2Direct_SetTankPassedCount(L4D2Direct_GetTankPassedCount() - 1);
    }

    /* 控制权交接: 两边都没走完的跟踪石观察/钉值作废(钉住的目标属于旧坦克那一段) */
    ResetTracCtrl(iOldTank);
    ResetTracCtrl(iNewTank);

    gotTankAt = GetGameTime();

    /* 长存活计时: 交接时旧坦克的计时作废, 从这一刻重新给新坦克起算
       (新坦克是"刚拿到控制权", 不该继承旧坦克已经存活的时长) */
    ResetTankLongLife(iOldTank);
    MarkTankGotControl(iNewTank);
}

/**
 * Make sure we give the tank to our queued player.
 */
public Action L4D_OnTryOfferingTankBot(int tank_index, bool &enterStatis)
{
    // Reset the tank's frustration if need be
    if (!IsFakeClient(tank_index)) 
    {
        PrintHintText(tank_index, "%t", "HintText");
        for (int i = 1; i <= MaxClients; i++) 
        {
            if (!IS_VALID_INFECTED(i) && !IS_VALID_SPECTATOR(i))
                continue;

            if (tank_index == i) 
                CPrintToChat(i, "%t %t", "TagRage", "RefilledBot");
            else 
                CPrintToChat(i, "%t %t", "TagRage", "Refilled", tank_index);
        }
        
        SetTankFrustration(tank_index, 100);
        L4D2Direct_SetTankPassedCount(L4D2Direct_GetTankPassedCount() + 1);

        ResetTracCtrl(tank_index);      /* 怒气被重置为满, 旧的观察/钉值状态作废 */

        /* 怒气回满只是"补正基准"要重来, 不重置长存活的存活计时: 引擎这次只是回填怒气,
           坦克并没有死也没有换人, 把它当成新的存活起点会让"存活满 N 秒"这条规则
           因为反复回填怒气而永远到不了。仅在没有起点的兜底情况下补一个起点。 */
        if (g_fTankGotAt[tank_index] <= 0.0)
            g_fTankGotAt[tank_index] = GetGameTime();

        return Plugin_Handled;
    }

    // Allow third party plugins to override tank selection
    char sOverrideTank[64];
    sOverrideTank[0] = '\0';
    Call_StartForward(hForwardOnTryOfferingTankBot);
    Call_PushStringEx(sOverrideTank, sizeof(sOverrideTank), SM_PARAM_STRING_UTF8, SM_PARAM_COPYBACK);
    Call_Finish();

    if (!StrEqual(sOverrideTank, ""))
        strcopy(queuedTankSteamId, sizeof(queuedTankSteamId), sOverrideTank);
    
    // If we don't have a queued tank, choose one
    if (StrEqual(queuedTankSteamId, ""))
        chooseTank(0);
    
    // Mark the player as having had tank
    if (!StrEqual(queuedTankSteamId, ""))
    {
        setTankTickets(queuedTankSteamId, 20000);

        if (h_whosHadTank.FindString(queuedTankSteamId) == -1)
            h_whosHadTank.PushString(queuedTankSteamId);

        int index = h_tankQueue.FindString(queuedTankSteamId);
        if (index != -1)
            h_tankQueue.Erase(index);
    }
    
    return Plugin_Continue;
}

public void L4D_OnLeaveStasis(int tank)
{
    // Tank is always AI here, delay by a frame.
    RequestFrame(L4D_OnLeaveStasis_Post, GetClientUserId(tank));
}

void L4D_OnLeaveStasis_Post(int userid)
{
    int tank = GetClientOfUserId(userid);
    // Tank passed from AI to a player, nothing to do here.
    if (!tank || !IsClientInGame(tank))
        return;
    
    // @Forgetest: 
    //   AI Tank may have committed suicide at the moment
    if (!IsPlayerAlive(tank) || GetEntProp(tank, Prop_Send, "m_isIncapacitated")) // Thanks to @sheo for noting the tank incap
        return;

    int newTank = getInfectedPlayerBySteamId(queuedTankSteamId);

    // Still no candidates, give up.
    if (newTank == -1)
        return;

    L4D_ReplaceTank(tank, newTank);
    L4D2Direct_SetTankPassedCount(1); // Otherwise the Tank gets 3 controls.
}

/*=========================================================================
|                                 Events                                  |
=========================================================================*/


/**
 * When a new game starts, reset the tank pool.
 */
void RoundStart_Event(Event hEvent, const char[] eName, bool dontBroadcast)
{
    CreateTimer(10.0, newGame);
    dcedTankFrustration = -1;
    gotTankAt = 0.0;
    tankInitiallyChosen = "";

    /* 新回合不继承跟踪石的控制权观察/钉值状态, 也不继承上一回合的存活计时 */
    ResetAllTracCtrl();
    ResetAllTankLongLife();
}

Action newGame(Handle timer)
{
    int teamAScore = L4D2Direct_GetVSCampaignScore(0);
    int teamBScore = L4D2Direct_GetVSCampaignScore(1);

    // If it's a new game, reset the tank pool
    if (teamAScore == 0 && teamBScore == 0)
    {
        h_whosHadTank.Clear();
        h_tankQueue.Clear();
        queuedTankSteamId = "";
        tankInitiallyChosen = "";
    }

    return Plugin_Stop;
}

/**
 * When the round ends, reset the active tank.
 */
void RoundEnd_Event(Event hEvent, const char[] eName, bool dontBroadcast)
{
    queuedTankSteamId = "";
    tankInitiallyChosen = "";

    ResetAllTracCtrl();
    ResetAllTankLongLife();
}

/**
 * When a player leaves the start area, choose a tank and output to all.
 */
void PlayerLeftStartArea_Event(Event hEvent, const char[] eName, bool dontBroadcast)
{
    tankInitiallyChosen = "";

    chooseTank(0);
    outputTankToAll(0);
}

/**
 * When the queued tank switches teams, choose a new one
 */
void PlayerTeam_Event(Event hEvent, const char[] name, bool dontBroadcast)
{
    int team = hEvent.GetInt("team");
    int oldTeam = hEvent.GetInt("oldteam");
    int client = GetClientOfUserId(hEvent.GetInt("userid"));
    char tmpSteamId[64];

    if (client < 1 || client > MaxClients)
        return;

    if (oldTeam == TEAM_INFECTED)
    {
        /*
        * Triggers for disconnects as well as forced-swaps and whatnot.
        * Allows us to always reliably detect when the current Tank player loses control due to unnatural reasons.
        */
        if (!IsFakeClient(client))
        {
            int zombieClass = GetEntProp(client, Prop_Send, "m_zombieClass");
            if (zombieClass == ZOMBIECLASS_TANK)
            {
                dcedTankFrustration = GetTankFrustration(client);
                fTankGrace = CTimer_GetRemainingTime(GetFrustrationTimer(client));

                // Slight fix due to the timer seemingly always getting stuck between 0.5s~1.2s even after Grace period has passed.
                // CTimer_IsElapsed still returns false as well.
                if (fTankGrace < 0.0 || dcedTankFrustration < 100) 
                    fTankGrace = 0.0;
            }
        }

        GetClientAuthId(client, AuthId_Steam2, tmpSteamId, sizeof(tmpSteamId));

        if (StrEqual(tankInitiallyChosen, tmpSteamId))
            initialTankLeft = GetGameTime();

        if (StrEqual(queuedTankSteamId, tmpSteamId))
        {
            RequestFrame(chooseTank, 0);
            RequestFrame(outputTankToAll, 0);
        }
    }

    if (team == TEAM_INFECTED && !IsFakeClient(client) && !StrEqual(tankInitiallyChosen, ""))
    {
        GetClientAuthId(client, AuthId_Steam2, tmpSteamId, sizeof(tmpSteamId));
        if (StrEqual(tankInitiallyChosen, tmpSteamId))
        {
            /* Not touching multiple tanks with a ten-foot pole.
            Could technically be done though.. TODO? */
            int tank = getTankPlayer();

            float window = hTankWindow.FloatValue;
            if (window > 0.0 && L4D2_GetTankCount() == 1 && tank != -1 && (gotTankAt - initialTankLeft) < window)
            {
                // Delay by a frame as player needs to "settle in"
                RequestFrame(ReplaceTank, client);
            }
            else
            {
                strcopy(queuedTankSteamId, sizeof(queuedTankSteamId), tankInitiallyChosen);
                RequestFrame(outputTankToAll, 0);
            }
        }
    }
}

/**
 * Replaces the current tank with the initially chosen Tank.
 * And requeues the old Tank.
 * 
 * @param deservingTank
 *      The player to give the Tank to.
 */
void ReplaceTank(int deservingTank)
{
    int oldTank = getTankPlayer();

    if (oldTank != -1 && IS_INFECTED(deservingTank))
    {
        L4D_ReplaceTank(oldTank, deservingTank);

        char steamId[64];

        // Requeue the old tank        
        GetClientAuthId(oldTank, AuthId_Steam2, steamId, sizeof(steamId));
        if (h_tankQueue.FindString(steamId) == -1)
        {
            h_tankQueue.ShiftUp(0);
            h_tankQueue.SetString(0, steamId);
        }

        int index = h_whosHadTank.FindString(steamId);
        if (index != -1)
            h_whosHadTank.Erase(index);

        // Remove the deserving tank from the queue if they're in it
        GetClientAuthId(deservingTank, AuthId_Steam2, steamId, sizeof(steamId));
        index = h_tankQueue.FindString(steamId);
        if (index != -1)
            h_tankQueue.Erase(index);

        index = h_whosHadTank.FindString(steamId);
        if (index == -1)
            h_whosHadTank.PushString(steamId);                
    }
}

/**
 * 坦克本体出现的时刻: 长存活规则的计时起点。
 * 为什么需要它: L4D2_OnTankPassControl 只在"控制权从一个人交给另一个人"时触发,
 *   回合里第一辆坦克拿到控制权不走那条 forward, 只用它会漏掉第一辆坦克。
 * tank_spawn 的 tankid 是实体 index, userid 才是玩家(userid 转 client 后校验)。
 */
void TankSpawn_Event(Event hEvent, const char[] eName, bool dontBroadcast)
{
    int tank = GetClientOfUserId(hEvent.GetInt("userid"));

    if (!IsTankClient(tank))
        return;

    /* 同一辆坦克在"AI 坦克 -> 人类接管"时可能再次触发 tank_spawn, 已有计时就不要重置,
       否则计时会被无限推后("存活满 4 分钟"永远到不了) */
    if (g_fTankGotAt[tank] > 0.0)
        return;

    MarkTankGotControl(tank);
}

/**
 * When the tank dies, requeue a player to become tank (for finales)
 */
void PlayerDeath_Event(Event hEvent, const char[] eName, bool dontBroadcast)
{
    int victim = GetClientOfUserId(hEvent.GetInt("userid"));
    
    if (victim && IS_VALID_INFECTED(victim) && gotTankAt > 0.0)
    {
        int zombieClass = GetEntProp(victim, Prop_Send, "m_zombieClass");
        if (zombieClass == ZOMBIECLASS_TANK) 
        {
            ResetTracCtrl(victim);      /* 坦克死了, 丢掉它没走完的控制权观察/钉值 */
            ResetTankLongLife(victim);  /* 长存活计时也一并作废(下一辆坦克重新起算) */
            tankInitiallyChosen = "";
            chooseTank(0);
            gotTankAt = 0.0;
            dcedTankFrustration = -1;
        }
    }
}

/*=========================================================================
|                               Commands                                  |
=========================================================================*/


/**
 * When a player wants to find out whos becoming tank,
 * output to them.
 */
Action Tank_Cmd(int client, int args)
{
    // Only output if client is in-game and we have a queued tank
    if (!client || !IsClientInGame(client) || StrEqual(queuedTankSteamId, ""))
        return Plugin_Handled;
    
    int tankClientId = getInfectedPlayerBySteamId(queuedTankSteamId);

    if (tankClientId != -1 && (hTankPrint.BoolValue || IS_INFECTED(client) || IS_SPECTATOR(client)))
    {
        if (client == tankClientId) 
            CPrintToChat(client, "%t %t", "TagSelection", "YouBecomeTank");
        else 
            CPrintToChat(client, "%t %t", "TagSelection", "BecomeTank", tankClientId);
    }
    
    return Plugin_Handled;
}

/**
 * Shuffle the tank (randomly give to another player in
 * the pool.
 */
Action TankShuffle_Cmd(int client, int args)
{
    tankInitiallyChosen = "";

    chooseTank(0);
    outputTankToAll(0);
    
    return Plugin_Handled;
}

/**
 * Give the tank to a specific player.
 */
Action GiveTank_Cmd(int client, int args)
{
    if (client && !IsClientInGame(client))
        return Plugin_Handled;

    // Who are we targetting?
    char arg1[32];
    GetCmdArg(1, arg1, sizeof(arg1));
    
    // Try and find a matching player
    int target = FindTarget(client, arg1);

    if (target == -1 || !IsClientInGame(target) || IsFakeClient(target))
    {
        CReplyToCommand(client, "%t %t", "TagControl", "InvalidTarget");
        return Plugin_Handled;
    }

    // Checking if on our desired team
    if (!IS_INFECTED(target))
    {
        CReplyToCommand(client, "%t %t", "TagControl", "NoInfected", target);
        return Plugin_Handled;
    }
    
    // Set the tank
    char steamId[64];
    GetClientAuthId(target, AuthId_Steam2, steamId, sizeof(steamId));

    strcopy(queuedTankSteamId, sizeof(queuedTankSteamId), steamId);
    strcopy(tankInitiallyChosen, sizeof(tankInitiallyChosen), steamId);

    outputTankToAll(0);
    
    return Plugin_Handled;
}


/*=========================================================================
|                                 Stocks                                  |
=========================================================================*/


/**
 * Selects a player on the infected team from random who hasn't been
 * tank and gives it to them.
 */
void chooseTank(any data)
{
    // Allow other plugins to override tank selection.
    char sOverrideTank[64];
    sOverrideTank[0] = '\0';
    Call_StartForward(hForwardOnTankSelection);
    Call_PushStringEx(sOverrideTank, sizeof(sOverrideTank), SM_PARAM_STRING_UTF8, SM_PARAM_COPYBACK);
    Call_Finish();

    if (!StrEqual(sOverrideTank, ""))
    {
        strcopy(queuedTankSteamId, sizeof(queuedTankSteamId), sOverrideTank);
        return;
    }

    queuedTankSteamId = "";

    int nextTankIndex = PeekNextTankIndexInTheQueue();

    if (nextTankIndex == -1)
    {
        EnqueueNewInfectedPlayers();
        nextTankIndex = PeekNextTankIndexInTheQueue();
    }

    if (nextTankIndex == -1)
    {
        RemoveAllInfectedFrom(h_tankQueue);
        RemoveAllInfectedFrom(h_whosHadTank);
        EnqueueNewInfectedPlayers();
        nextTankIndex = PeekNextTankIndexInTheQueue();
    }

    if (nextTankIndex == -1)
        return;

    char steamId[64];

    h_tankQueue.GetString(nextTankIndex, steamId, sizeof(steamId));

    strcopy(queuedTankSteamId, sizeof(queuedTankSteamId), steamId);

    if (StrEqual(tankInitiallyChosen, ""))
        strcopy(tankInitiallyChosen, sizeof(tankInitiallyChosen), steamId);
}

/**
 * Sets the amount of tickets for a particular player, essentially giving them tank.
 */
void setTankTickets(const char[] steamId, int tickets)
{
    int tankClientId = getInfectedPlayerBySteamId(steamId);
    
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IS_VALID_INFECTED(i) && !IsFakeClient(i))
            L4D2Direct_SetTankTickets(i, (i == tankClientId) ? tickets : 0);
    }
}

/**
 * Output who will become tank
 */
void outputTankToAll(any data)
{
    int tankClientId = getInfectedPlayerBySteamId(queuedTankSteamId);
    
    if (tankClientId != -1)
    {
        for (int i = 1; i <= MaxClients; i++) 
        {
            if (!IsClientInGame(i) || (!hTankPrint.BoolValue && !IS_INFECTED(i) && !IS_SPECTATOR(i)))
                continue;

            if (tankClientId == i) 
                CPrintToChat(i, "%t %t", "TagSelection", "YouBecomeTank");
            else 
                CPrintToChat(i, "%t %t", "TagSelection", "BecomeTank", tankClientId);
        }
    }
}

/**
 * Retrieves the current Tank player.
 * 
 * @return
 *     The tank's client index or -1 if not found.
 */
int getTankPlayer()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || !IS_INFECTED(i) || IsFakeClient(i))
            continue;
        
        int zombieClass = GetEntProp(i, Prop_Send, "m_zombieClass");
        
        if (zombieClass == ZOMBIECLASS_TANK)
            return i;
    }

    return -1;
}

/**
 * Retrieves a player's client index by their steam id.
 * 
 * @param steamId
 *     The steam id string to look for.
 * 
 * @return
 *     The player's client index or -1 if not found.
 */
int getInfectedPlayerBySteamId(const char[] steamId) 
{
    char tmpSteamId[64];
   
    for (int i = 1; i <= MaxClients; i++) 
    {
        if (!IS_VALID_INFECTED(i))
            continue;

        GetClientAuthId(i, AuthId_Steam2, tmpSteamId, sizeof(tmpSteamId));
        
        if (StrEqual(steamId, tmpSteamId))
            return i;
    }
    
    return -1;
}

void SetTankFrustration(int iTankClient, int iFrustration) 
{
    if (iFrustration >= 0 && iFrustration <= 100)
        SetEntProp(iTankClient, Prop_Send, "m_frustration", 100-iFrustration);
}

int GetTankFrustration(int iTankClient) 
{
    return 100 - GetEntProp(iTankClient, Prop_Send, "m_frustration");
}

CountdownTimer GetFrustrationTimer(int client)
{
    static int s_iOffs_m_frustrationTimer = -1;

    if (s_iOffs_m_frustrationTimer == -1)
        s_iOffs_m_frustrationTimer = FindSendPropInfo("CTerrorPlayer", "m_frustration") + 4;
    
    return view_as<CountdownTimer>(GetEntityAddress(client) + view_as<Address>(s_iOffs_m_frustrationTimer));
}

/*=========================================================================
|          跟踪石命中后的坦克控制权调整(自 Apex.sp 迁入)
|
|  需求: **跟踪石命中生还者本身不扣任何控制权**, 它只把坦克切成"快速掉怒气"状态 ——
|        从命中那一刻起, 引擎每落一格怒气都按 step%(默认 6%)扣, 而不是日常的 base%(5%),
|        直到坦克死亡 / 控制权交接(可用 tankcontrol_trac_after 改成限时)。
|
|  机制(服务器控制台日志 + server.dll 实测):
|    * m_frustration 是 netprop, 怒气 = 100 - m_frustration; 它后面 +4 字节是怒气计时器;
|    * 引擎 CTerrorPlayer::UpdateZombieFrustration 按计时器落"怒气步进": m_frustration += 约 base
|      (本服务器 5), 面板(sm_tankhud 的"怒气")上看到的就是一格 5%;
|    * 跟踪石命中时引擎会把计时器赋值成约 2.0 秒, 于是约 2 秒后落下一格;
|      怒气满(0)时这次命中不改怒气; 怒气不满时引擎会把怒气回填到 100%(命中奖励)。
|
|  实现(命中只当开关, 不做任何补扣):
|    1. 命中 -> 标记该坦克进入持续状态, 基准 = 命中瞬间的怒气值;
|    2. 之后引擎每落一格怒气(相对我们最后认可的值约 +base) -> 补成 step 点;
|    3. 引擎回填/重置怒气(命中奖励那种, m_frustration 变小或幅度远超一格) -> 不补扣, 只把基准挪过去;
|    4. 引擎把怒气又写回它自己那个值(覆盖我们的补正) -> 压回我们的值, 单轮最多 CTRL_PUSH_BACK_MAX 次;
|    5. 怒气计时器一律不动也不写回 —— 引擎对它是"赋值", 我们插不上手;
|    6. 坦克死亡 / 控制权交接 / 回合结束都会清掉持续状态(ResetTracCtrl)。

  长存活规则(存活满 tankcontrol_trac_longlife_time 秒后幅度提升):
    7. 计时起点是"坦克真正拿到控制权"的时刻, 由 tank_spawn 事件 +
       L4D2_OnTankPassControl + 怒气回满 三处共同打点, 并在 OnGameFrame 里兜底
       (看到人类坦克却没有起点就以当前时刻起算); 每辆坦克各自记录(g_fTankGotAt 按 client 索引),
       12v12 同时存在多辆坦克互不影响;
    8. 满门限后闩锁(g_bTankLongLife 保持为 true), 直到坦克死亡 / 交接 / 换回合才清;
    9. 生效那一刻只是"取当前怒气作为新基准", 从下一格怒气开始才按新幅度补正
       (即: 不追溯、不补扣满门限之前已经落过的怒气);
   10. 两个条件都成立时取最大幅度(7%), 不叠加成 8%; 有效幅度被 clamp 在
       [base, max(base, step, longlife_step)], 配置写反也不会扣得比引擎少。
=========================================================================*/

/* Apex 的通知: 跟踪石命中了一名生还者(tank = 掷石坦克, victim = 被命中的生还者, 本插件只用 tank) */
public void Apex_OnTracRockHit(int tank, int victim)
{
    if (tank < 1 || tank > MaxClients || !IsClientInGame(tank))
        return;

    float effBefore = TracEffectiveStep(tank);

    StartTracCtrlAfter(tank);

    NotifyTracStepRaised(tank, effBefore, "跟踪石命中生还者");
}

/* 命中只做一件事: 把坦克切成"之后每格怒气按 step% 扣"的持续状态(不扣任何怒气、不输出任何信息) */
void StartTracCtrlAfter(int tank)
{
    if (!TracCtrlAdjustEnabled())
        return;

    float now = GetGameTime();

    g_bTracAfter[tank]      = true;
    g_fTracAfterUntil[tank] = (hTracCtrlAfter.FloatValue > 0.0) ? now + hTracCtrlAfter.FloatValue : 0.0;

    /* 检测基准: 命中瞬间的怒气值(引擎这次命中之后的写入都会被当成"引擎改动") */
    ArmTracCtrl(tank, GetEntProp(tank, Prop_Send, "m_frustration"));
}

/* 进入补正状态机: 以 baseMeter 这一刻的原始 m_frustration 作为检测基准。
   关键点 —— 进入生效状态之前的怒气变化一律不追溯(不补扣), 只从这一刻往后算。 */
void ArmTracCtrl(int tank, int baseMeter)
{
    g_iTracKnownMeter[tank]   = baseMeter;
    g_iTracEngineMeter[tank]  = -1;
    g_iTracWantMeter[tank]    = baseMeter;
    g_iTracPushBacks[tank]    = 0;
    g_bTracTracking[tank]     = true;
}

/* 是否具备补正能力: 只需要基线 > 0(其它幅度 <= 基线时, 每辆坦克算出来的 ratio 会是 0,
   OnGameFrame 里自然就不写值了, 不必在这里提前判断) */
bool TracCtrlAdjustEnabled()
{
    return (hTracCtrlBase.FloatValue > 0.0);
}

/* 长存活门限是否开启(time <= 0 关闭这条规则) */
bool TracLongLifeEnabled()
{
    return (hTracCtrlLongLifeTime.FloatValue > 0.0);
}

/* 该坦克当前"每格怒气"的有效幅度 = 三个候选值取最大(不叠加):
     基线 base / 长存活 longlife_step(已存满门限) / 跟踪石 step(处于命中持续状态)
   结果天然落在 [base, max(base, step, longlife_step)] 内; 再显式 clamp 一次, 是为了在
   配置写反(比如 longlife_step < base)时也不会出现"扣得比引擎还少"的反向补正。 */
float TracEffectiveStep(int client)
{
    float base     = hTracCtrlBase.FloatValue;
    float eff      = base;
    float llStep   = hTracCtrlLongLifeStep.FloatValue;
    float tracStep = hTracCtrlStep.FloatValue;

    if (g_bTankLongLife[client] && llStep > eff)
        eff = llStep;

    if (g_bTracAfter[client] && tracStep > eff)
        eff = tracStep;

    float hi = base;
    if (llStep > hi)
        hi = llStep;
    if (tracStep > hi)
        hi = tracStep;

    if (eff < base)
        eff = base;
    if (eff > hi)
        eff = hi;

    return eff;
}

/* 每格怒气消耗幅度提升时(跟踪石命中 / 存活满门限), 只私聊告诉坦克本人。
   只在"有效幅度真的变大"时提示: 两个规则取 max, 已经在 7% 的坦克再命中一次不会再提示;
   幅度没有提升(默认中性配置 / 配置被调回基线)时全程静默。 */
void NotifyTracStepRaised(int client, float effBefore, const char[] reason)
{
    if (hTracCtrlNotify == null || !hTracCtrlNotify.BoolValue)
        return;

    if (client < 1 || client > MaxClients || !IsClientInGame(client))
        return;

    float effAfter = TracEffectiveStep(client);

    if (effAfter <= effBefore + 0.001)
        return;

    CPrintToChat(client, "{olive}[{red}!{olive}]{default} 控制权消耗提升: {red}%s{default} → 每格怒气扣除 {green}%.0f%%{default} (原 {green}%.0f%%{default}), 掉控会更快",
        reason, effAfter, effBefore);
}

/* 每帧: 对每个坦克算"有效每格幅度 eff", 只有 eff > 基线时才去补正
   (命中本身不扣任何东西, 也不输出信息; 未生效的坦克直接跳过, 不做任何属性读写) */
public void OnGameFrame()
{
    /* 没有补正能力(基线被设成 0/负)时什么都不做, 也避免除零 */
    if (!TracCtrlAdjustEnabled())
        return;

    float now     = GetGameTime();
    float base    = hTracCtrlBase.FloatValue;
    float llTime  = hTracCtrlLongLifeTime.FloatValue;
    bool  llOn    = TracLongLifeEnabled();

    for (int i = 1; i <= MaxClients; i++)
    {
        /* IsTankClient 只看"是不是人类 + 特感坦克职业", 尸体会一直是坦克职业, 所以这里还要
           判 IsPlayerAlive —— 否则死掉的那辆坦克会一直在计时里, 同一个人下次当坦克时会被
           直接判成"已存活满 4 分钟"(12v12 的 finale 连续坦克很容易撞上)。 */
        if (!IsTankClient(i) || !IsPlayerAlive(i))
        {
            /* 这一格已经不再是(人类)坦克: 死亡 / 变成别的特感 / 掉线 / 换图残留,
               立刻丢弃它的存活起点与补正状态 —— 否则同一个人下次当坦克时会带着上一段的
               存活时间直接被判成"已存活满 4 分钟" */
            if (g_fTankGotAt[i] > 0.0 || g_bTankLongLife[i] || g_bTracTracking[i])
                ResetTankLongLife(i);

            continue;
        }

        /* 长存活判定: 只对"有拿到控制权时刻"的坦克生效; 满门限后闩锁住,
           之后不会因为 now 变化再反复计算(也不会自己解除, 直到死亡/交接/换回合) */
        if (g_fTankGotAt[i] <= 0.0)
        {
            /* 兜底: 看到"是人类坦克但没有起点"就把这一刻当起点(晚加载插件、没收到 tank_spawn /
               pass control、或某条清理路径把它清成 0 的情况)。
               宁可晚起算(少扣), 也绝不能凭空认为它已经存活满门限。 */
            g_fTankGotAt[i]    = now;
            g_bTankLongLife[i] = false;
        }

        if (!llOn)
        {
            g_bTankLongLife[i] = false;
        }
        else if (!g_bTankLongLife[i] && g_fTankGotAt[i] > 0.0 && (now - g_fTankGotAt[i]) >= llTime)
        {
            /* 闩锁前先记下有效幅度, 用来只在"真的变快"时通知坦克本人 */
            float effBefore = TracEffectiveStep(i);

            g_bTankLongLife[i] = true;

            NotifyTracStepRaised(i, effBefore, "存活时间达到门限");
        }

        /* 跟踪石持续状态(限时的那种)到点作废 */
        if (g_bTracAfter[i] && g_fTracAfterUntil[i] > 0.0 && now >= g_fTracAfterUntil[i])
            g_bTracAfter[i] = false;

        /* 两个条件都不成立 -> 回落到基线, 退出状态机, 不写任何属性 */
        if (!g_bTracAfter[i] && !g_bTankLongLife[i])
        {
            if (g_bTracTracking[i])
                ResetTracCtrl(i);

            continue;
        }

        /* 有效幅度没超过基线时(或配置写反)不补正: ratio 为 0 时不能进补正流程,
           否则下面的 "extra 为 0 就强制给 1" 会造成凭空多扣。
           若此时状态机还挂着(比如曾经生效、现在被改回基线), 把基准挪到当前值,
           免得之后重新生效时拿一个过期的基准去算改动量(同时保留 trac/长存活标志)。 */
        float eff = TracEffectiveStep(i);
        if (eff <= base)
        {
            if (g_bTracTracking[i])
            {
                int curMeter = GetEntProp(i, Prop_Send, "m_frustration");

                if (curMeter != g_iTracKnownMeter[i])
                    ArmTracCtrl(i, curMeter);
            }

            continue;
        }

        float ratio = (eff / base) - 1.0;   /* 需要额外补的比例(5->6 即 +20%, 5->7 即 +40%) */

        int cur = GetEntProp(i, Prop_Send, "m_frustration");

        /* 怒气被重置/回填成满(m_frustration 变成 0) = 这一段控制权重开:
           丢掉补正状态, 用满怒气作为新基准。这一格绝不能补扣(否则会凭空扣掉怒气)。 */
        if (cur == 0)
        {
            if (g_bTracTracking[i])
                ArmTracCtrl(i, cur);

            continue;
        }
        /* 刚刚进入生效状态(最常见的是"存活满 4 分钟"那一刻): 用当前值做基准, 从下一格开始算 */
        if (!g_bTracTracking[i])
        {
            ArmTracCtrl(i, cur);
            continue;
        }

        if (cur == g_iTracEngineMeter[i] && g_iTracEngineMeter[i] != g_iTracWantMeter[i]
            && g_iTracPushBacks[i] < CTRL_PUSH_BACK_MAX)
        {
            /* 怒气又变回"引擎自己写入的那个值" -> 我们的补正被盖掉了, 压回我们的值。
               (怒气正常只会按步进往上走, 正好回到引擎那个旧值只可能是引擎自己写的;
                 次数有上限, 免得和每帧重算的引擎对拉) */
            g_iTracPushBacks[i]++;

            SetEntProp(i, Prop_Send, "m_frustration", g_iTracWantMeter[i]);
            continue;
        }

        if (cur == g_iTracKnownMeter[i])
            continue;

        /* 引擎(或别的插件)写了新值: 相对我们最后认可的值算出改动量 */
        int delta = cur - g_iTracKnownMeter[i];
        int want;

        /* 怒气步进只会让 m_frustration 变大(怒气变小); 变小或幅度远超一格的都是
           引擎的回填/重置(命中奖励、控制权重置), 一律不补扣, 只把基准挪过去 */
        if (delta < 0 || FloatAbs(float(delta)) > base * 1.5)
        {
            want = cur;
        }
        else
        {
            int extra = RoundToNearest(float(delta) * ratio);
            if (extra == 0)
                extra = 1;

            want = cur + extra;
        }

        if (want > 100)
            want = 100;
        if (want < 0)
            want = 0;

        SetEntProp(i, Prop_Send, "m_frustration", want);

        g_iTracEngineMeter[i] = cur;
        g_iTracKnownMeter[i]  = want;
        g_iTracWantMeter[i]   = want;
        g_iTracPushBacks[i]   = 0;
    }
}

/* 是否是人类坦克(与 Apex 侧的判断一致: 技能只有人类坦克能用) */
bool IsTankClient(int client)
{
    return (client > 0 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client)
            && GetClientTeam(client) == TEAM_INFECTED
            && GetEntProp(client, Prop_Send, "m_zombieClass") == ZOMBIECLASS_TANK);
}

/* 清掉某个坦克的跟踪石持续状态(回合结束、坦克死亡、控制权交接、重置怒气时调用) */
void ResetTracCtrl(int client)
{
    if (client < 1 || client > MaxClients)
        return;

    g_iTracWantMeter[client]  = 0;
    g_iTracKnownMeter[client] = 0;
    g_iTracEngineMeter[client]= -1;
    g_iTracPushBacks[client]  = 0;
    g_bTracAfter[client]      = false;
    g_fTracAfterUntil[client] = 0.0;
    g_bTracTracking[client]   = false;
}

/* 记下"这辆坦克真正拿到控制权"的时刻, 供长存活规则计时。
   取值口径是 GetGameTime(); 调用点覆盖: 坦克首次出现(tank_spawn) / 控制权交接
   (L4D2_OnTankPassControl) / 掉线后 AI 换控 / 换控重建。重置为 0 表示不跟踪。 */
void MarkTankGotControl(int client)
{
    if (client < 1 || client > MaxClients)
        return;

    g_fTankGotAt[client]   = GetGameTime();
    g_bTankLongLife[client] = false;

    /* 新的控制权段: 之前那一段的补正基准作废, 从这一刻重新算(避免把上一段当"一格"补扣) */
    ResetTracCtrl(client);
}

/* 清掉某辆坦克的长存活计时(死亡 / 失去控制权 / 换回合 / 已不是坦克) */
void ResetTankLongLife(int client)
{
    if (client < 1 || client > MaxClients)
        return;

    g_fTankGotAt[client]    = 0.0;
    g_bTankLongLife[client] = false;

    ResetTracCtrl(client);
}

/* 回合起止时把所有坦克的长存活计时与补正状态一起清掉(这些数组在换图后不会重新归零) */
void ResetAllTankLongLife()
{
    for (int i = 1; i <= MaxClients; i++)
        ResetTankLongLife(i);
}

void ResetAllTracCtrl()
{
    for (int i = 1; i <= MaxClients; i++)
        ResetTracCtrl(i);
}

int PeekNextTankIndexInTheQueue()
{
    if (h_tankQueue.Length == 0)
        return -1;

    char steamId[64];

    for (int i = 0; i < h_tankQueue.Length; i++)
    {
        h_tankQueue.GetString(i, steamId, sizeof(steamId));

        int client = getInfectedPlayerBySteamId(steamId);
        if (client != -1)
            return i;
    }

    return -1;
}

void EnqueueNewInfectedPlayers()
{
    char steamId[64];

    int start = h_tankQueue.Length;
    int end = -1;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client) || GetClientTeam(client) != TEAM_INFECTED)
            continue;
        
        GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));

        if (h_tankQueue.FindString(steamId) != -1 || h_whosHadTank.FindString(steamId) != -1)
            continue;

        h_tankQueue.PushString(steamId);

        end = h_tankQueue.Length - 1;
    }

    if (end != -1)
        ShuffleArray(h_tankQueue, start, end);
}

void RemoveAllInfectedFrom(ArrayList arrayList)
{
    char steamId[64];

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client) || GetClientTeam(client) != TEAM_INFECTED)
            continue;
        
        GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));

        int index = arrayList.FindString(steamId);
        if (index != -1)
            arrayList.Erase(index);
    }
}

void ShuffleArray(ArrayList arrayList, int start, int end)
{
    if (start == end)
        return;

    int swaps = (end - start + 1) * 2;

    for (int i = 0; i < swaps; i++)
    {
        int index1 = GetRandomInt(start, end);
        int index2 = GetRandomInt(start, end);

        if (index1 == index2)
            continue;

        arrayList.SwapAt(index1, index2);
    }
}

/**
 * Check if the translation file exists
 *
 * @param translation	Translation name.
 * @noreturn
 */
stock void LoadTranslation(const char[] translation)
{
	char
		sPath[PLATFORM_MAX_PATH],
		sName[64];

	FormatEx(sName, sizeof(sName), "translations/%s.txt", translation);
	BuildPath(Path_SM, sPath, sizeof(sPath), sName);
	if (!FileExists(sPath))
		SetFailState("Missing translation file %s.txt", translation);

	LoadTranslations(translation);
}