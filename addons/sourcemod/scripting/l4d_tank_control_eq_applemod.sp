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
    hTracCtrlBase,      /* 跟踪石: 游戏日常的怒气步进幅度(%) */
    hTracCtrlStep,      /* 跟踪石: 命中后每格怒气的扣除幅度(%) */
    hTracCtrlAfter;     /* 跟踪石: 命中后持续按 step% 扣的时长(秒, 0=直到坦克死亡/换控) */

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
    version = "0.0.30-applemod",
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
           或在 confogl 的 cfg 里 confogl_addcvar tankcontrol_trac_step 6 这样覆盖 */
    hTracCtrlBase  = CreateConVar("tankcontrol_trac_base", "5.0", "游戏日常的怒气步进幅度(%). 只用于换算比例, 不会写进游戏");
    hTracCtrlStep  = CreateConVar("tankcontrol_trac_step", "6.0", "跟踪石命中后, 每格怒气的扣除幅度(%%): 引擎每落一格怒气(日常 base%%)就补成 step%%. 命中本身不扣任何东西. 等于 base 则不调整");
    hTracCtrlAfter = CreateConVar("tankcontrol_trac_after", "0.0", "跟踪石命中后, 持续按 step%% 扣的时长(秒). 0 = 直到坦克死亡或控制权交接");
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

    /* 新回合不继承跟踪石的控制权观察/钉值状态 */
    ResetAllTracCtrl();
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
=========================================================================*/

/* Apex 的通知: 跟踪石命中了一名生还者(tank = 掷石坦克, victim = 被命中的生还者, 本插件只用 tank) */
public void Apex_OnTracRockHit(int tank, int victim)
{
    if (tank < 1 || tank > MaxClients || !IsClientInGame(tank))
        return;

    StartTracCtrlAfter(tank);
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
    g_iTracKnownMeter[tank]  = GetEntProp(tank, Prop_Send, "m_frustration");
    g_iTracEngineMeter[tank] = -1;
    g_iTracWantMeter[tank]   = g_iTracKnownMeter[tank];
    g_iTracPushBacks[tank]   = 0;
}

bool TracCtrlAdjustEnabled()
{
    float base = hTracCtrlBase.FloatValue;
    float step = hTracCtrlStep.FloatValue;

    return (base > 0.0 && step > 0.0 && step != base);
}

/* 每帧: 处于持续状态的坦克, 把引擎落的每一格怒气补成 step%(命中本身不扣任何东西, 也不输出信息) */
public void OnGameFrame()
{
    float now   = GetGameTime();
    float base  = hTracCtrlBase.FloatValue;
    float step  = hTracCtrlStep.FloatValue;
    float ratio = (step / base) - 1.0;   /* 需要额外补的比例(5->6 即 +20%) */

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsTankClient(i))
            continue;

        if (g_bTracAfter[i] && g_fTracAfterUntil[i] > 0.0 && now >= g_fTracAfterUntil[i])
            g_bTracAfter[i] = false;

        if (!g_bTracAfter[i] || !TracCtrlAdjustEnabled())
            continue;

        int cur = GetEntProp(i, Prop_Send, "m_frustration");

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