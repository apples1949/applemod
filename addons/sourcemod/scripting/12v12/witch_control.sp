/*
 * @Author:             我是派蒙啊
 * @Last Modified by:   我是派蒙啊
 * @Create Date:        2023-06-28 11:33:15
 * @Last Modified time: 2023-08-02 00:55:07
 * @Github:             https://github.com/Paimon-Kawaii
 */

#pragma semicolon 1
#pragma newdecls required

#define DEBUG 0

// #include <menus>
#include <dhooks>
#include <actions>
#include <sdktools>
#include <sdkhooks>
// #include <paiutils>   // 原作者私有 include，仓库里没有附带；改用文件末尾内联的同语义 stock
#include <sourcemod>

#if DEBUG
    #include "vector_show.sp"
#endif

#define VERSION "2023.06.28"
#define MAXSIZE MAXPLAYERS + 1

// ===== 女巫动画序列号 =====
// 实测来源：从 l4d2 pak01_dir.vpk 取出 models/infected/anim_witch.mdl，解析 mstudioseqdesc_t 得到全表 100 个序列：
//   0 @Standing_Idle | 1 @Idle_Standing | 2 @Idle_Pre_Retreat | 3..7 a_Run* | 11..15 a_Walk*
//   44 @Melee_01 | 45 @Melee_02 | 49 a_Agitated_1 | 58 @Jump | 59..63 a_CrouchWalk* | 71 @Jump_Across_02
//   72 @Landing03 | 73..92 Climb* | 93 @Ladder_Descend | 95..99 @Death*/@deathpose_*
// 结论：模型里【没有"坐"这个独立动画】，蹲姿只有 a_CrouchWalkZero(59) 系列。
// 另外 m_nSequence 的索引基准可能整体偏移，用 witch_control_seq_offset 平移（默认 0，看日志再定）。
// 原值（作者写的，实测对不上模型表）：CRYING=2 SITTING=4 TARGET=6 ANGRY=29 FALL=54 RUN_JUMP=57
#define ANIM_STANDING_CRYING 0 // @Standing_Idle 站立哭
#define ANIM_SITTING 59        // a_CrouchWalkZero 蹲姿（模型唯一的蹲姿序列）
#define ANIM_CATCHING_TARGET 44 // @Melee_01 抓人
#define ANIM_SETTING_ANGRY 49  // a_Agitated_1 激怒
#define ANIM_FALL 71           // @Jump_Across_02 腾空
#define ANIM_RUN_JUMP 58       // @Jump
#define ANIM_RUN_ZERO 7        // a_RunZero —— 原地跑循环，走路该用它

#define POSE_NONE 0
#define POSE_SIT 1
#define POSE_STAND 2

#define INVALID_NAV_LADDER -1
#define MENU_DISPLAY_INFINITE 0

#define CAMERA_MODEL "models/editor/camera.mdl"

int
    g_iWitch[MAXSIZE] = { -1, ... },
    g_iCamera[MAXSIZE] = { -1, ... },
    g_iDamageBackup[MAXSIZE],     // 接管前人物的 m_takedamage，解除接管时还原
    g_iMaxHealthBackup[MAXSIZE],  // 接管前人物的 m_iMaxHealth，解除接管时还原
    g_iPose[MAXSIZE],             // POSE_NONE/坐/站（我们现在自己记账，不再靠读 m_nSequence 猜）
    g_iSeqWant[MAXSIZE] = { -1, ... },   // 本帧希望女巫播放的序列号
    g_iStompCount[MAXSIZE],       // AI 把我们的序列顶掉的次数（诊断用）
    g_iFlagFixCount[MAXSIZE],     // 引擎把 FL_DUCKING 改回去、我们又改回来的次数（诊断用）
    g_iSeqOverride[MAXSIZE] = { -1, ... }, // 调试命令强制指定的序列号
    g_iSitSeqEngine[MAXSIZE] = { -1, ... }, // 这局女巫"蹲着抱头"时的引擎序列号（接管时学到）
    g_iIdleSeqEngine[MAXSIZE] = { -1, ... }; // 这局女巫"抱头"idle 的引擎序列号（接管时学到，走路也用她）

float
    g_fLastLog[MAXSIZE],
    g_fCamBaseZ[MAXSIZE];     // 接管时相机"站立高度"基准（按下蹲/起身都从它算，避免累加钻地）

bool
    g_bPoseForced[MAXSIZE],   // 玩家是否按过 Ctrl（没按之前我们不动女巫原生动画）
    g_bDuckPrev[MAXSIZE],     // 自己记 Ctrl 上一帧状态
    g_bMoving[MAXSIZE];       // 本帧是否按着移动键（决定播走路循环还是站立 idle）（不能用 m_nOldButtons：我们清过 IN_DUCK，引擎会把它记成没按）

Handle
    g_hDebugLog;
char
    g_sDebugLogPath[PLATFORM_MAX_PATH];

ConVar
    g_hSpeed,
    g_hJumpSeq,
    g_hJumpPower,
    g_hAngryWalkSeq,
    g_hMaxTime,
    g_hAngryTime,
    g_hClawDamage,
    g_hMeleeSeq,
    g_hLadder,
    g_hLadderSpeed,
    g_hClimbSeq,
    g_hDebug,
    g_hSeqOffset,
    g_hAutoOffset,
    g_hIdleSeq,
    g_hWalkSeq,
    g_hSitSeq,
    g_hStandSeq,
    g_hThirdPerson,
    g_hTPDistance,
    g_hTPHeight,
    g_hTPSitDrop;

bool
    g_bThirdPerson = true;   // 全程第三人称（witch_control_thirdperson，默认开）

int
    g_iTPDistance = 130,
    g_iTPHeight = 80,
    g_iTPSitDrop = 20;

float
    g_fSpeedScale = 0.60,
    g_fJumpPower = 0.60,
    g_fClawDamage = 50.0,
    g_fAngryTime = 3.0,
    g_fControlStart[MAXSIZE],   // 本次接管开始时间（算接管时长）
    g_fAngryStart[MAXSIZE],     // 本次激怒开始时间（算激怒时长）
    g_fAttackAnimUntil[MAXSIZE], // 爪击动画维持到这个时间点
    g_fWitchLostSince[MAXSIZE],  // 女巫实体/血量失联的起始时间（0=正常）
    g_fDeadSince[MAXSIZE];       // 人物"未存活"的起始时间（0=正常）

int
    g_iIdleSeq = 11,    // 站立 idle（witch_control_idle_seq，实测选定 11=a_WalkSE）
    g_iWalkSeq = 11,    // 未激怒行走（witch_control_walk_seq，实测选定 11=a_WalkSE）
    g_iSitSeq = 59,     // 坐姿序列（witch_control_sit_seq）
    g_iStandSeq = -1,   // 站姿序列（witch_control_stand_seq，-1=不干预）
    g_iJumpSeq = 58,    // 起跳动画（witch_control_jump_seq，anim 表索引）
    g_iAngryWalkSeq = 3,// 激怒时行走动画（witch_control_angry_walk_seq，anim 表索引；-1=交给 AI）
    g_iMaxTime = 0,     // 接管最长秒数（witch_control_max_time，0=不限）
    g_iMeleeSeq = 44,   // 爪击动画（witch_control_melee_seq，anim 表索引）
    g_iClimbSeq = 75,   // 爬梯动画（witch_control_climb_seq，anim 表索引 73..92 是 Climb*）
    g_bLadderOn = 1,    // 允许爬梯（witch_control_ladder）
    g_iLadderSpeed = 200, // 爬梯上升速度（witch_control_ladder_speed）
    g_iSeqOffset = 4,   // m_nSequence 索引基准偏移：写 anim 表第 X 个要写 X+4（实测得出）
    g_iScanStep,
    g_iScanFrom,
    g_iScanTo = 99,
    g_iScanClient = -1;

Handle
    g_hScanTimer;

float
    g_fLiftHeight[MAXSIZE];

bool
    g_bWitchAngry[MAXSIZE],
    g_bAngryResume[MAXSIZE],
    g_bWitchControl[MAXSIZE];

ConVar
    g_hWitchWander,
    g_hWitchWalkSpeed,
    g_hGravity;

bool
    g_bWitchWanderBackup;

// Address
//     g_pCNavMesh;

Handle
    g_hGetNextBot,
    g_hGetLocomotion,

    // g_hClimbLadder,
    // g_hDescendLadder,
    // g_hFindNavAreaOrLadder,

    g_hResetStatus,
    g_hClimbUpToLedge,

    g_hSetZombieClass,
    g_hSetAcceleration,

    // g_hIsUsingLadder,
    g_hIsClimbingUpToLedge;

public Plugin myinfo =
{
    name = "Witch Control",
    author = "我是派蒙啊",
    description = "控制女巫",
    version = VERSION,
    url = "http://github.com/Paimon-Kawaii/L4D2-Plugins"
};

public void OnPluginStart()
{
    if(!InitGameData())
        SetFailState("Failed to load gamedata: \"witch_control.txt\", content incorrect.");

    LoadTranslations("witch_control.phrases");

    g_hWitchWander = FindConVar("witch_force_wander");
    if (g_hWitchWander != null)
    {
        g_bWitchWanderBackup = g_hWitchWander.BoolValue;
        g_hWitchWander.SetBool(false);
    } else LogError("ConVar not found: \"witch_force_wander\", witch may wander on its own.");
    // g_hWitchWalkSpeed = FindConVar("z_witch_speed");
    g_hWitchWalkSpeed = FindConVar("z_witch_speed_inured");
    if (g_hWitchWalkSpeed == null)
        SetFailState("ConVar not found: \"z_witch_speed_inured\", witch can't be moved.");
    g_hGravity = FindConVar("sv_gravity");
    if (g_hGravity == null)
        SetFailState("ConVar not found: \"sv_gravity\", witch can't jump or fall.");

    g_hDebug = CreateConVar("witch_control_debug", "1",
        "调试日志：0=关 1=关键事件+每秒状态 2=每帧细节（输出到 SM 日志/服务器控制台/受控玩家聊天）",
        FCVAR_NONE, true, 0.0, true, 2.0);
    g_hSeqOffset = CreateConVar("witch_control_seq_offset", "4",
        "索引基准偏移：实际写入 = anim表索引 + 本值。实测本引擎为 4（写 0 会冻结成直立无动画）",
        FCVAR_NONE, true, -20.0, true, 20.0);
    g_iSeqOffset = g_hSeqOffset.IntValue;
    g_hSeqOffset.AddChangeHook(OnSeqOffsetChanged);

    g_hStandSeq = CreateConVar("witch_control_stand_seq", "-1",
        "-1=起身时完全不干预（推荐，走路/扑击动画正常）；>=0=起身时强制播放这个序列号",
        FCVAR_NONE, true, -1.0, true, 199.0);
    g_iStandSeq = g_hStandSeq.IntValue;
    g_hStandSeq.AddChangeHook(OnSeqOffsetChanged);

    g_hIdleSeq = CreateConVar("witch_control_idle_seq", "11",
        "站着不动时播的 anim 表索引（实测选定：11=a_WalkSE；写入时 +seq_offset 即 15）",
        FCVAR_NONE, true, 0.0, true, 199.0);
    g_iIdleSeq = g_hIdleSeq.IntValue;
    g_hIdleSeq.AddChangeHook(OnSeqOffsetChanged);

    g_hWalkSeq = CreateConVar("witch_control_walk_seq", "11",
        "未激怒时行走播的 anim 表索引（实测选定：11=a_WalkSE；写入时 +seq_offset 即 15）",
        FCVAR_NONE, true, 0.0, true, 199.0);
    g_iWalkSeq = g_hWalkSeq.IntValue;
    g_hWalkSeq.AddChangeHook(OnSeqOffsetChanged);

    g_hSitSeq = CreateConVar("witch_control_sit_seq", "59",
        "坐下时播放的序列号（模型表索引，实测 59..63 是 a_CrouchWalk*；可用 sm_witchscan 试）",
        FCVAR_NONE, true, 0.0, true, 199.0);
    g_iSitSeq = g_hSitSeq.IntValue;
    g_hSitSeq.AddChangeHook(OnSeqOffsetChanged);

    g_hAutoOffset = CreateConVar("witch_control_auto_offset", "0",
        "1=接管时用引擎自己的空闲序列号反推索引偏移（推荐） 0=只用 witch_control_seq_offset", FCVAR_NONE, true, 0.0, true, 1.0);

    g_hSpeed = CreateConVar("witch_control_speed", "0.60",
        "受控女巫的移动速度倍率（1.0 = z_witch_speed_inured 原速，太快；默认 0.6）",
        FCVAR_NONE, true, 0.1, true, 3.0);
    g_fSpeedScale = g_hSpeed.FloatValue;
    g_hSpeed.AddChangeHook(OnSeqOffsetChanged);

    g_hJumpSeq = CreateConVar("witch_control_jump_seq", "58",
        "起跳时播的 anim 表索引（58=@Jump；写入时 +seq_offset）", FCVAR_NONE, true, 0.0, true, 199.0);
    g_iJumpSeq = g_hJumpSeq.IntValue;
    g_hJumpSeq.AddChangeHook(OnSeqOffsetChanged);

    g_hJumpPower = CreateConVar("witch_control_jump_height", "0.60",
        "跳跃高度：起跳初速 = sv_gravity × 本值（0.6≈原值，越大跳越高）",
        FCVAR_NONE, true, 0.10, true, 3.0);
    g_fJumpPower = g_hJumpPower.FloatValue;
    g_hJumpPower.AddChangeHook(OnSeqOffsetChanged);

    g_hAngryWalkSeq = CreateConVar("witch_control_angry_walk_seq", "3",
        "激怒状态下行走播的 anim 表索引（3=a_RunN；-1=完全交给 AI）",
        FCVAR_NONE, true, -1.0, true, 199.0);
    g_iAngryWalkSeq = g_hAngryWalkSeq.IntValue;
    g_hAngryWalkSeq.AddChangeHook(OnSeqOffsetChanged);

    g_hMaxTime = CreateConVar("witch_control_max_time", "0",
        "接管最长持续秒数（0=不限；到点自动解除接管）", FCVAR_NONE, true, 0.0, true, 3600.0);
    g_iMaxTime = g_hMaxTime.IntValue;
    g_hMaxTime.AddChangeHook(OnSeqOffsetChanged);

    g_hAngryTime = CreateConVar("witch_control_angry_time", "3.0",
        "激怒（左键扑击）最长持续秒数，到点或 rage 归零就归还控制（0=只等 rage 归零）",
        FCVAR_NONE, true, 0.0, true, 30.0);
    g_fAngryTime = g_hAngryTime.FloatValue;
    g_hAngryTime.AddChangeHook(OnSeqOffsetChanged);

    g_hClawDamage = CreateConVar("witch_control_claw_damage", "50.0",
        "爪击对门/道具的伤害（未激怒时左键对着门或道具就是爪它）",
        FCVAR_NONE, true, 0.0, true, 5000.0);
    g_fClawDamage = g_hClawDamage.FloatValue;
    g_hClawDamage.AddChangeHook(OnSeqOffsetChanged);

    g_hMeleeSeq = CreateConVar("witch_control_melee_seq", "44",
        "爪击时播的 anim 表索引（44=@Melee_01）", FCVAR_NONE, true, 0.0, true, 199.0);
    g_iMeleeSeq = g_hMeleeSeq.IntValue;
    g_hMeleeSeq.AddChangeHook(OnSeqOffsetChanged);

    g_hLadder = CreateConVar("witch_control_ladder", "1",
        "1=允许爬梯子（按 W 对着 func_useableladder/func_simpleladder 自动上爬）",
        FCVAR_NONE, true, 0.0, true, 1.0);
    g_bLadderOn = g_hLadder.IntValue;
    g_hLadder.AddChangeHook(OnSeqOffsetChanged);

    g_hLadderSpeed = CreateConVar("witch_control_ladder_speed", "200",
        "爬梯上升速度", FCVAR_NONE, true, 20.0, true, 600.0);
    g_iLadderSpeed = g_hLadderSpeed.IntValue;
    g_hLadderSpeed.AddChangeHook(OnSeqOffsetChanged);

    g_hClimbSeq = CreateConVar("witch_control_climb_seq", "75",
        "爬梯时播的 anim 表索引（73..92 是 a_Climb*）", FCVAR_NONE, true, 0.0, true, 199.0);
    g_iClimbSeq = g_hClimbSeq.IntValue;
    g_hClimbSeq.AddChangeHook(OnSeqOffsetChanged);

    g_hThirdPerson = CreateConVar("witch_control_thirdperson", "1",
        "1=全程第三人称（相机挂在女巫身后，默认开） 0=第一人称（原行为）",
        FCVAR_NONE, true, 0.0, true, 1.0);
    g_hTPDistance = CreateConVar("witch_control_tp_distance", "130",
        "第三人称相机往后拉的距离", FCVAR_NONE, true, 40.0, true, 400.0);
    g_hTPHeight = CreateConVar("witch_control_tp_height", "80",
        "第三人称相机在女巫头顶上方的高度", FCVAR_NONE, true, 0.0, true, 200.0);
    g_hTPSitDrop = CreateConVar("witch_control_tp_sit_drop", "20",
        "坐下时相机往下压多少（原来写死 38，蹲下时镜头会压到地面以下）",
        FCVAR_NONE, true, 0.0, true, 80.0);

    g_bThirdPerson = g_hThirdPerson.BoolValue;
    g_iTPDistance = g_hTPDistance.IntValue;
    g_iTPHeight = g_hTPHeight.IntValue;
    g_iTPSitDrop = g_hTPSitDrop.IntValue;
    g_hThirdPerson.AddChangeHook(OnViewModeChanged);
    g_hTPDistance.AddChangeHook(OnViewModeChanged);
    g_hTPHeight.AddChangeHook(OnViewModeChanged);
    g_hTPSitDrop.AddChangeHook(OnViewModeChanged);

    RegAdminCmd("sm_witchseq", Cmd_WitchSeq, ADMFLAG_CHEATS, "打印当前受控女巫的 seq/flags/pose");
    RegAdminCmd("sm_witchset", Cmd_WitchSet, ADMFLAG_CHEATS, "sm_witchset <序列号>|off 强制女巫播放某序列");
    RegAdminCmd("sm_witchtry", Cmd_WitchTry, ADMFLAG_CHEATS, "逐个试候选姿势（anim 表索引），数字打在聊天里");
    RegAdminCmd("sm_witchscan", Cmd_WitchScan, ADMFLAG_CHEATS, "从 0 到 99 每 1.2 秒换一个序列，找出真正的蹲/站/抓/跳");

    HookEvent("round_start", Event_RoundStart);
    HookEvent("witch_spawn", Event_WitchSpawned);
    AddNormalSoundHook(StopControlSound);

    OpenDebugLog();
    DebugLogEx(0, 1, 0.0, "==== 加载完成 debug=%d seq_offset=%d 视角=%s(距%d 高%d) ====",
        g_hDebug.IntValue, g_iSeqOffset, g_bThirdPerson ? "第三人称" : "第一人称",
        g_iTPDistance, g_iTPHeight);
    DebugLogEx(0, 1, 0.0,
        "女巫动画表(anim_witch.mdl 实测 100 个)：0 @Standing_Idle | 1 @Idle_Standing | 44 @Melee_01 | 49 a_Agitated_1 | 58 @Jump | 59..63 a_CrouchWalk* | 71 @Jump_Across_02 | 72 @Landing03 | 没有独立 sit 动画");
}

public void OnSeqOffsetChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    g_iSeqOffset = g_hSeqOffset.IntValue;
    g_iSitSeq = g_hSitSeq.IntValue;
    g_iStandSeq = g_hStandSeq.IntValue;
    g_fSpeedScale = g_hSpeed.FloatValue;
    g_iIdleSeq = g_hIdleSeq.IntValue;
    g_iWalkSeq = g_hWalkSeq.IntValue;
    g_iJumpSeq = g_hJumpSeq.IntValue;
    g_fJumpPower = g_hJumpPower.FloatValue;
    g_iAngryWalkSeq = g_hAngryWalkSeq.IntValue;
    g_iMaxTime = g_hMaxTime.IntValue;
    g_fAngryTime = g_hAngryTime.FloatValue;
    g_fClawDamage = g_hClawDamage.FloatValue;
    g_iMeleeSeq = g_hMeleeSeq.IntValue;
    g_bLadderOn = g_hLadder.IntValue;
    g_iLadderSpeed = g_hLadderSpeed.IntValue;
    g_iClimbSeq = g_hClimbSeq.IntValue;
}

// 第三人称相关 cvar 改动后立刻重排相机（不用重连也能生效）
public void OnViewModeChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    g_bThirdPerson = g_hThirdPerson.BoolValue;
    g_iTPDistance = g_hTPDistance.IntValue;
    g_iTPHeight = g_hTPHeight.IntValue;
    g_iTPSitDrop = g_hTPSitDrop.IntValue;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!g_bWitchControl[client] || !IsValidEntity(GetClientWitch(client))) continue;

        // 直接按新模式重建一次视角（TP 要 ClearParent，FP 要重新 SetParent）
        SetViewToWitch(client);
        g_fCamBaseZ[client] = GetCamOriginZ(GetClientCamera(client));
        g_fLiftHeight[client] = 0.0;
        DebugLogEx(client, 1, 0.0, "视角模式切换：thirdperson=%d dist=%d height=%d 相机基准Z=%.1f",
            g_bThirdPerson ? 1 : 0, g_iTPDistance, g_iTPHeight, g_fCamBaseZ[client]);
    }
}

public void OnPluginEnd()
{
    if (g_hWitchWander != null)
        g_hWitchWander.SetBool(g_bWitchWanderBackup);

    DebugLogEx(0, 1, 0.0, "==== 插件卸载 ====");
    CloseDebugLog();
}

bool InitGameData()
{
    GameData gamedata = new GameData("witch_control");
    if (gamedata == null)
        SetFailState("Gamedata not found: \"witch_control.txt\".");

    bool status = true;
    StartPrepSDKCall(SDKCall_Entity);
    if (PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "CBaseEntity::MyNextBotPointer"))
    {
        PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
        g_hGetNextBot = EndPrepSDKCall();
    } else LogError("Failed to find offset: \"CBaseEntity::MyNextBotPointer\"");
    if(!g_hGetNextBot) status = false;

    StartPrepSDKCall(SDKCall_Raw);
    if (PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "INextBot::GetLocomotionInterface"))
    {
        PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
        g_hGetLocomotion = EndPrepSDKCall();
    } else LogError("Failed to find offset: \"INextBot::GetLocomotionInterface\"");
    if(!g_hGetLocomotion) status = false;

    StartPrepSDKCall(SDKCall_Player);
    if (PrepSDKCall_SetFromConf(gamedata, SDKConf_Signature, "CTerrorPlayer::SetClass"))
    {
        PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
        g_hSetZombieClass = EndPrepSDKCall();
    } else LogError("Failed to load signature: \"CTerrorPlayer::SetClass\"");
    if(!g_hSetZombieClass) status = false;

    StartPrepSDKCall(SDKCall_Raw);
    if (PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "ILocomotion::Reset"))
    {
        PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
        g_hResetStatus = EndPrepSDKCall();
    } else LogError("Failed to find offset: \"ILocomotion::Reset\"");
    if(!g_hResetStatus) status = false;

    StartPrepSDKCall(SDKCall_Raw);
    if (PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "ILocomotion::SetAcceleration"))
    {
        PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
        g_hSetAcceleration = EndPrepSDKCall();
    } else LogError("Failed to find offset: \"ILocomotion::SetAcceleration\"");
    if(!g_hSetAcceleration) status = false;

    StartPrepSDKCall(SDKCall_Raw);
    if (PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "ILocomotion::ClimbUpToLedge"))
    {
        PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
        PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
        PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer);

        PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
        g_hClimbUpToLedge = EndPrepSDKCall();
    } else LogError("Failed to find offset: \"ILocomotion::ClimbUpToLedge\"");
    if(!g_hClimbUpToLedge) status = false;

    StartPrepSDKCall(SDKCall_Raw);
    if (PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "ILocomotion::IsClimbingUpToLedge"))
    {
        PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
        g_hIsClimbingUpToLedge = EndPrepSDKCall();
    } else LogError("Failed to find offset: \"ILocomotion::IsClimbingUpToLedge\"");
    if(!g_hIsClimbingUpToLedge) status = false;

    // StartPrepSDKCall(SDKCall_Raw);
    // if (PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "ILocomotion::ClimbLadder"))
    // {
    //     PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Pointer);
    //     PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Pointer);
    //     g_hClimbLadder = EndPrepSDKCall();
    // } else LogError("Failed to find offset: \"ILocomotion::ClimbLadder\"");
    // if(!g_hClimbLadder) status = false;

    // StartPrepSDKCall(SDKCall_Raw);
    // if (PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "ILocomotion::DescendLadder"))
    // {
    //     PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Pointer);
    //     PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Pointer);
    //     g_hDescendLadder = EndPrepSDKCall();
    // } else LogError("Failed to find offset: \"ILocomotion::DescendLadder\"");
    // if(!g_hDescendLadder) status = false;

    // StartPrepSDKCall(SDKCall_Raw);
    // if(PrepSDKCall_SetFromConf(gamedata, SDKConf_Signature, "CNavMesh::FindNavAreaOrLadderAlongRay"))
    // {
    //     PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
    //     PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
    //     PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_ByRef);
    //     PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_ByRef);
    //     PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_ByValue);

    //     PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_ByValue);
    //     g_hFindNavAreaOrLadder = EndPrepSDKCall();
    // } else LogError("Failed to find offset: \"CNavMesh::FindNavAreaOrLadderAlongRay\"");

    // StartPrepSDKCall(SDKCall_Raw);
    // if (PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "ILocomotion::IsUsingLadder"))
    // {
    //     PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
    //     g_hIsUsingLadder = EndPrepSDKCall();
    // } else LogError("Failed to find offset: \"ILocomotion::IsUsingLadder\"");
    // if(!g_hIsUsingLadder) status = false;

    // DynamicDetour enterGhostDetour = DynamicDetour.FromConf(gamedata, "L4DD::CTerrorPlayer::OnEnterGhostState");
    // if (!enterGhostDetour || !enterGhostDetour.Enable(Hook_Post, OnEnterGhostState))
    //     LogError("Failed to load detour: \"L4DD::CTerrorPlayer::OnEnterGhostState\"");
    // if(!enterGhostDetour) status = false;

    // g_pCNavMesh = GameConfGetAddress(gamedata, "TerrorNavMesh");
    // if(!g_pCNavMesh) status = false;
    delete gamedata;

    return status;
}

/*
MRESReturn OnEnterGhostState(int pThis, DHookReturn hReturn, DHookParam hParams)
{
    if (IsInfected(pThis) && !IsTank(pThis) && !IsFakeClient(pThis))
        CreateWitchMenu(pThis);

    return MRES_Ignored;
}
*/

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    for (int client = 1; client <= MaxClients; client++)
        ClearControlState(client);
}

// 清空接管状态并销毁相机实体（不处理自杀/传送等人物逻辑）
void ClearControlState(int client)
{
    int witch = GetClientWitch(client);
    if (IsValidEntity(witch)) SDKUnhook(witch, SDKHook_ThinkPost, WitchThinkPost);

    g_iPose[client] = POSE_NONE;
    g_bPoseForced[client] = false;
    g_bDuckPrev[client] = false;
    g_bMoving[client] = false;
    g_iSitSeqEngine[client] = -1;
    g_iIdleSeqEngine[client] = -1;
    g_fWitchLostSince[client] = 0.0;
    g_fDeadSince[client] = 0.0;
    g_fCamBaseZ[client] = 0.0;
    g_iSeqWant[client] = -1;
    g_iSeqOverride[client] = -1;
    g_iStompCount[client] = 0;
    g_iFlagFixCount[client] = 0;
    g_iWitch[client] = -1;
    g_fLiftHeight[client] = 0.0;
    g_bAngryResume[client] = g_bWitchAngry[client] = g_bWitchControl[client] = false;

    // 这里不用 GetClientCamera()：断线时 IsValidClient() 可能已经为 false，会导致相机实体泄漏
    int camera = EntRefToEntIndex(g_iCamera[client]);
    if (IsValidEntity(camera))
    {
        AcceptEntityInput(camera, "Disable");
        RemoveEntity(camera);
    }
    g_iCamera[client] = -1;
}

// https://forums.alliedmods.net/showthread.php?t=336724
void Event_WitchSpawned(Event event, const char[] name, bool dontBroadcast)
{
    int witch = event.GetInt("witchid");
    int target = CreateEntityByName("info_target");
    if(!IsValidEntity(witch) || !IsValidEntity(target))
    {
        if (IsValidEntity(target)) RemoveEntity(target);   // 女巫无效时别把刚建出来的 hint 目标实体漏掉
        return;
    }

    char buffer[64];
    float pos[3], ang[3], fwd[3];
    GetEntPropVector(witch, Prop_Send, "m_vecOrigin", pos);
    GetEntPropVector(witch, Prop_Send, "m_angRotation", ang);
    GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
    ScaleVector(fwd, 20.0);
    for(int i = 0; i < 3; i++)
        pos[i] += fwd[i];
    pos[2] += 20;

    Format(buffer, sizeof(buffer), "hint_target_%d", target);
    DispatchKeyValue(target, "targetname", buffer);
    DispatchKeyValue(target, "spawnflags", "1");
    DispatchSpawn(target);
    TeleportEntity(target, pos, NULL_VECTOR, NULL_VECTOR);
    SDKHook(target, SDKHook_SetTransmit, SetTransmit);

    Format(buffer, sizeof(buffer), "OnUser1 !self:Kill::%f:-1", 10.0);
    SetVariantString(buffer);
    AcceptEntityInput(target, "AddOutput");
    AcceptEntityInput(target, "FireUser1");

    int hint = CreateEntityByName("env_instructor_hint");
    DispatchKeyValue(hint, "hint_timeout", "0");
    DispatchKeyValue(hint, "hint_allow_nodraw_target", "1");
    Format(buffer, sizeof(buffer), "hint_target_%d", target);
    DispatchKeyValue(hint, "hint_target", buffer);
    DispatchKeyValue(hint, "hint_auto_start", "1");
    DispatchKeyValue(hint, "hint_color", "200 200 200");
    DispatchKeyValue(hint, "hint_icon_offscreen", "icon_tip");
    DispatchKeyValue(hint, "hint_instance_type", "0");
    DispatchKeyValue(hint, "hint_icon_onscreen", "icon_tip");
    Format(buffer, sizeof(buffer), "%T", "WitchControl", LANG_SERVER);
    DispatchKeyValue(hint, "hint_caption", buffer);
    DispatchKeyValue(hint, "hint_static", "0");
    DispatchKeyValue(hint, "hint_nooffscreen", "0");
    DispatchKeyValue(hint, "hint_icon_offset", "10");
    // DispatchKeyValue(hint, "hint_range", "800");
    DispatchKeyValue(hint, "hint_forcecaption", "1");

    DispatchSpawn(hint);
    TeleportEntity(hint, pos, NULL_VECTOR, NULL_VECTOR);
    AcceptEntityInput(hint, "ShowHint");

    Format(buffer, sizeof(buffer), "OnUser1 !self:Kill::%f:-1", 10.0);
    SetVariantString(buffer);
    AcceptEntityInput(hint, "AddOutput");
    AcceptEntityInput(hint, "FireUser1");

    // Format(buffer, sizeof(buffer), "witch_%d", witch);
    // DispatchKeyValue(witch, "targetname", buffer);
    // SetVariantString(buffer);
    // AcceptEntityInput(target, "SetParent");
    // SetVariantString(buffer);
    // AcceptEntityInput(hint, "SetParent");
}

Action SetTransmit(int entity, int client)
{
    if(!IsInfected(client))
        return Plugin_Handled;

    return Plugin_Continue;
}

Action StopControlSound(int clients[MAXPLAYERS], int &numClients, char sample[PLATFORM_MAX_PATH],
      int &entity, int &channel, float &volume, int &level, int &pitch, int &flags,
      char soundEntry[PLATFORM_MAX_PATH], int &seed)
{
    if (IsValidClient(entity) && g_bWitchControl[entity])
        return Plugin_Handled;

    return Plugin_Continue;
}

/*
void CreateWitchMenu(int client)
{
    char name[64], id[8];
    Format(name, sizeof(name), "%T", "MenuTitle", client);
    Menu menu = new Menu(HandleWitchMenu);
    menu.SetTitle(name);
    float cpos[3], wpos[3], distance;
    GetClientAbsOrigin(client, cpos);

    int witch = MaxClients + 1;
    while ((witch = FindEntityByClassname(witch, "witch")) && IsValidEntity(witch))
    {
        GetEntPropVector(witch, Prop_Send, "m_vecOrigin", wpos);
        distance = GetVectorDistance(cpos, wpos);
        IntToString(witch, id, sizeof(id));
        Format(name, sizeof(name), "Witch(%T: %.1f)", "MenuHintDistance", client, distance);
        menu.AddItem(id, name);
    }
    menu.ExitButton = true;
    menu.Display(client, MENU_DISPLAY_INFINITE);
}

int HandleWitchMenu(Menu menu, MenuAction action, int client, int item)
{
    if (!IsInfected(client)) return 0;
    if (action != MenuAction_Select) return 0;

    int witch;
    char info[32];
    menu.GetItem(item, info, sizeof(info));
    witch = StringToInt(info);

    for (int i = 1; i <= MaxClients; i++)
        if (GetClientWitch(i) == witch && i != client)
        {
            PrintToChat(client, "%T", "WitchBeenTaken", client, i);
            CreateWitchMenu(client);
            return 0;
        }

    SetClientWitch(client, witch);
    ResetPlayerState(client);
    SetViewToWitch(client);
    ShowControlHint(client);
    g_bWitchControl[client] = true;

    return 1;
}
*/

public void OnClientDisconnect(int client)
{
    ClearControlState(client);
}

void ShowControlHint(int client)
{
    DataPack data;
    ClientCommand(client, "gameinstructor_enable 1");

    data = new DataPack();
    data.WriteCell(client);
    data.WriteString("WitchAttack");
    data.WriteString("+attack");
    data.WriteCell(false);
    CreateTimer(0.1, Timer_ShowHint, data, TIMER_FLAG_NO_MAPCHANGE);

    data = new DataPack();
    data.WriteCell(client);
    data.WriteString("WitchSkill");
    data.WriteString("+attack2");
    data.WriteCell(false);
    CreateTimer(4.0, Timer_ShowHint, data, TIMER_FLAG_NO_MAPCHANGE);

    data = new DataPack();
    data.WriteCell(client);
    data.WriteString("WitchDuck");
    data.WriteString("+duck");
    data.WriteCell(false);
    CreateTimer(8.0, Timer_ShowHint, data, TIMER_FLAG_NO_MAPCHANGE);

    data = new DataPack();
    data.WriteCell(client);
    data.WriteString("WitchLose");
    data.WriteString("+use");
    data.WriteCell(true);
    CreateTimer(12.0, Timer_ShowHint, data, TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_ShowHint(Handle timer, DataPack data)
{
    data.Reset(false);
    int client = data.ReadCell();
    if (!IsValidClient(client))
        return Plugin_Stop;

    char msg[64], bind[64];
    data.ReadString(msg, sizeof(msg));
    data.ReadString(bind, sizeof(bind));
    bool final = data.ReadCell();
    Format(msg, sizeof(msg), "%T", msg, client);
    int hint = ShowInstructorHint(client, msg, sizeof(msg), bind);

    data.Reset();
    data.WriteCell(hint);
    data.WriteCell(client);
    data.WriteCell(final);
    CreateTimer(3.8, Timer_StopHint, data, TIMER_FLAG_NO_MAPCHANGE);

    return Plugin_Stop;
}

Action Timer_StopHint(Handle timer, DataPack data)
{
    data.Reset(false);
    int hint = data.ReadCell();
    int client = data.ReadCell();
    bool final = data.ReadCell();
    delete data;

    if (IsValidEntity(hint))
    {
        AcceptEntityInput(hint, "Kill");
        RemoveEntity(hint);
    }
    if (!IsValidClient(client) || !final) return Plugin_Stop;

    ClientCommand(client, "gameinstructor_enable 0");
    return Plugin_Stop;
}

public void OnActionCreated(BehaviorAction action, int actor, const char[] name)
{
    if (!strcmp(name, "WitchAngry"))
    {
        bool nobody = true;
        for (int client = 1; client <= MaxClients; client++)
            if (g_bWitchControl[client] && GetClientWitch(client) == actor)
            {
                // Witch 已被控制
                nobody = false;
                break;
            }
        if (nobody) return;

        action.OnUpdate = OnWitchAngryUpdate;
        action.OnEnd = OnWitchAngryEnd;
    }
}

Action OnWitchAngryUpdate(BehaviorAction action, int actor, float interval, ActionResult result)
{
    for (int client = 1; client <= MaxClients; client++)
        if (g_bWitchControl[client] && !g_bWitchAngry[client] &&
            GetClientWitch(client) == actor)
        {
            // 延续动作
            result.type = SUSPEND_FOR;
            g_bAngryResume[client] = true;
            SetEntProp(actor, Prop_Send, "m_mobRush", 0);
            SetEntPropFloat(actor, Prop_Send, "m_rage", 0.0);
            break;
        }

    return Plugin_Continue;
}

Action OnWitchAngryEnd(BehaviorAction action, int actor, float interval, ActionResult result)
{
    for (int client = 1; client <= MaxClients; client++)
        if (g_bWitchControl[client] && GetClientWitch(client) == actor)
        {
            g_bWitchAngry[client] = false;
            g_bAngryResume[client] = false;
            SetEntProp(actor, Prop_Send, "m_mobRush", 0);
            break;
        }

    return Plugin_Continue;
}

public void OnMapStart()
{
    if (!IsModelPrecached(CAMERA_MODEL))
        PrecacheModel(CAMERA_MODEL);
}

public Action OnPlayerRunCmd(int client, int &buttons,
    int &impulse, float velocity[3], float angles[3], int &weapon,
    int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
    if (!IsInfected(client) || IsFakeClient(client) || IsTank(client))
    {
        // 换队 / 变成 bot / 变成坦克时要清残留状态，
        // 否则 g_bWitchControl 会一直是 true（静音钩子永久生效）且相机实体泄漏
        if (g_bWitchControl[client])
        {
            DebugLogEx(client, 1, 0.0, "解除接管 原因=换队/变bot/变坦克 | 队伍=%d fake=%d class=%d",
                IsClientInGame(client) ? GetClientTeam(client) : -1,
                IsFakeClient(client) ? 1 : 0,
                IsClientInGame(client) ? GetEntProp(client, Prop_Send, "m_zombieClass") : -1);
            if (IsClientInGame(client))
                PrintToChat(client, "[女巫] 解除接管：换队/变成bot/变成坦克");

            ClearControlState(client);
            if (IsClientInGame(client))
                SetViewEntity(client, -1);
        }
        return Plugin_Continue;
    }

    if (!IsPlayerAlive(client))
    {
        // 单帧抖动不处理：连续 0.5 秒都不是存活状态才算真的掉了
        if (g_bWitchControl[client])
        {
            if (g_fDeadSince[client] == 0.0)
            {
                g_fDeadSince[client] = GetGameTime();
                DebugLogEx(client, 1, 0.0, "检测到人物未存活，先等 0.5s（lifeState=%d isGhost=%d）",
                    GetEntProp(client, Prop_Send, "m_lifeState"),
                    GetEntProp(client, Prop_Send, "m_isGhost"));
                return Plugin_Continue;
            }
            if ((GetGameTime() - g_fDeadSince[client]) < 0.5)
                return Plugin_Continue;

            g_fDeadSince[client] = 0.0;
            DebugLogEx(client, 1, 0.0,
                "解除接管 原因=人物未存活 | lifeState=%d isGhost=%d class=%d 已接管%.1fs",
                GetEntProp(client, Prop_Send, "m_lifeState"),
                GetEntProp(client, Prop_Send, "m_isGhost"),
                GetEntProp(client, Prop_Send, "m_zombieClass"),
                (g_fControlStart[client] > 0.0) ? GetGameTime() - g_fControlStart[client] : 0.0);
            if (IsClientInGame(client))
                PrintToChat(client, "[女巫] 解除接管：人物未存活/已死亡");

            ClearControlState(client);
            SetViewEntity(client, -1);
        }

        return Plugin_Continue;
    }

    int oldbtns = GetEntProp(client, Prop_Data, "m_nOldButtons");
    // 接管Witch
    if((buttons & IN_USE) && !(oldbtns & IN_USE) && !g_bWitchControl[client])
    {
        int witch = GetClientAimTarget(client, false);
        if(!IsValidEntity(witch)) return Plugin_Continue;
        char name[16];
        GetEntityClassname(witch, name, sizeof(name));
        if(strcmp(name, "witch")) return Plugin_Continue;

        char owner[MAX_NAME_LENGTH];
        for (int i = 1; i <= MaxClients; i++)
            if (GetClientWitch(i) == witch && i != client)
            {
                GetClientName(i, owner, sizeof(owner));
                PrintToChat(client, "%T", "WitchBeenTaken", client, owner);
                return Plugin_Continue;
            }

        SetClientWitch(client, witch);

        // 先判女巫是蹲着还是站着（SetViewToWitch 的相机高度要用它，原来只看 FL_DUCKING 会算错）
        int f0 = GetEntProp(witch, Prop_Send, "m_fFlags");
        int seq0 = GetEntProp(witch, Prop_Data, "m_nSequence");
        bool sitting = DetectWitchSitting(witch);
        g_iPose[client] = sitting ? POSE_SIT : POSE_STAND;
        g_bPoseForced[client] = false;
        g_bDuckPrev[client] = (buttons & IN_DUCK) != 0;

        // 她本来就蹲着（FL_DUCKING）时，引擎给的那个序列号就是"本机蹲姿"，直接记住它。
        // 比猜模型表索引可靠得多（模型表没有 sit 动画，索引基准也不确定）。
        if (sitting)
        {
            g_iSitSeqEngine[client] = seq0;
            g_iIdleSeqEngine[client] = seq0;
            DebugLogEx(client, 1, 0.0,
                "学到本机抱头序列：seq=%d（坐/站/走路都用它，保持女巫双手抱头的姿态）", seq0);
        }
        else if (seq0 >= 0)
        {
            g_iIdleSeqEngine[client] = seq0;
            DebugLogEx(client, 1, 0.0, "学到本机 idle 序列：seq=%d（走路沿用它）", seq0);
        }

        ResetPlayerState(client);
        SetViewToWitch(client);
        g_fCamBaseZ[client] = GetCamOriginZ(GetClientCamera(client)) + (sitting ? 38.0 : 0.0);
        ShowControlHint(client);
        g_bWitchControl[client] = true;

        // 接管成功：挂 ThinkPost，每帧在女巫自己的 think 之后再写一次动画，
        // 否则女巫的 NextBot AI 会把我们写的 m_nSequence 顶掉（这就是"按了没反应"的根因）
        SDKHook(witch, SDKHook_ThinkPost, WitchThinkPost);
        g_fControlStart[client] = GetGameTime();

        // 用引擎自己给空闲女巫的序列号反推索引基准：K = 引擎值 - ANIM_STANDING_CRYING
        if (g_hAutoOffset != null && g_hAutoOffset.BoolValue && !sitting && seq0 > 0)
        {
            int k = seq0 - ANIM_STANDING_CRYING;
            if (k < 0 || k > 20)
            {
                DebugLogEx(client, 1, 0.0,
                    "自动索引偏移跳过：接管时 seq=%d 不像空闲动画（当前 offset 保持 %d）", seq0, g_iSeqOffset);
            }
            else
            {
                g_iSeqOffset = k;
                g_hSeqOffset.IntValue = k;   // 同步到 cvar，日志/命令里看到的就是实际用的
                DebugLogEx(client, 1, 0.0,
                    "自动索引偏移：引擎空闲seq=%d - 表的 @Standing_Idle(%d) ⇒ seq_offset=%d",
                    seq0, ANIM_STANDING_CRYING, g_iSeqOffset);
            }
        }

        char model[128];
        GetEntPropString(witch, Prop_Data, "m_ModelName", model, sizeof(model));
        DebugLogEx(client, 1, 0.0,
            "接管 witch#%d model=%s seq=%d flags=%d 蹲着=%d 判定pose=%d 相机基准Z=%.1f 血量=%d 视角=%s seq_offset=%d",
            witch, model, seq0, f0, sitting ? 1 : 0, g_iPose[client],
            g_fCamBaseZ[client], GetEntProp(witch, Prop_Data, "m_iHealth"),
            g_bThirdPerson ? "第三人称" : "第一人称", g_iSeqOffset);

        return Plugin_Continue;
    }

    if(!g_bWitchControl[client]) return Plugin_Continue;

    // 每帧先算"是否在移动"，后面 ApplyPose 和激怒分支都要用
    g_bMoving[client] = (g_iPose[client] != POSE_SIT) &&
        (buttons & (IN_FORWARD | IN_BACK | IN_MOVELEFT | IN_MOVERIGHT)) != 0;

    int health, witch = GetClientWitch(client);
    if (IsValidEntity(witch)) health = GetEntProp(witch, Prop_Data, "m_iHealth");
    // 放弃接管 —— 每一条路径都把"为什么"记下来（这是"莫名取消接管"的取证点）
    char reason[96];
    reason[0] = '\0';
    if (g_iMaxTime > 0 && (GetGameTime() - g_fControlStart[client]) >= float(g_iMaxTime))
        Format(reason, sizeof(reason), "接管时长到(%d秒)", g_iMaxTime);
    else if ((buttons & IN_USE) && !(oldbtns & IN_USE))
        Format(reason, sizeof(reason), "又按了E");
    else if (!IsValidEntity(witch) || health <= 0)
    {
        if (g_fWitchLostSince[client] == 0.0)
        {
            g_fWitchLostSince[client] = GetGameTime();
            DebugLogEx(client, 1, 0.0, "女巫暂时失效（实体=%d 血量=%d），先等 0.4s 再决定",
                witch, health);
            return Plugin_Continue;
        }

        if ((GetGameTime() - g_fWitchLostSince[client]) < 0.4)
            return Plugin_Continue;

        Format(reason, sizeof(reason), !IsValidEntity(witch) ? "女巫实体失效" : "女巫血量<=0");
    }

    if (IsValidEntity(witch) && health > 0)
        g_fWitchLostSince[client] = 0.0;   // 恢复正常，清掉失联计时

    if (reason[0])
    {
        DebugLogEx(client, 1, 0.0,
            "解除接管 原因=%s | witch=%d 血量=%d 人物活着=%d 队伍=%d class=%d lifeState=%d 已接管%.1fs",
            reason, witch, health, IsPlayerAlive(client) ? 1 : 0, GetClientTeam(client),
            GetEntProp(client, Prop_Send, "m_zombieClass"),
            GetEntProp(client, Prop_Send, "m_lifeState"),
            GetGameTime() - g_fControlStart[client]);
        if (IsClientInGame(client))
            PrintToChat(client, "[女巫] 解除接管：%s", reason);
    }

    if (reason[0])
    {
        if (IsValidEntity(witch))
        {
            int flags = GetEntProp(witch, Prop_Send, "m_fFlags");
            SetEntProp(witch, Prop_Send, "m_fFlags", flags & ~FL_DUCKING);
            // 不再硬写序列：交给引擎自己恢复，硬塞一个值反而会让她卡在奇怪的动作上（你看到的"踉跄"）
            DebugLogEx(client, 1, 0.0, "解除接管 witch#%d 当前 seq=%d（不干预，交还 AI）", witch,
                GetEntProp(witch, Prop_Data, "m_nSequence"));
        }

        ScreenFade(client, 1, 1, { 0, 0, 0, 255 });
        RestorePlayerState(client);
        ClearControlState(client);
        float pos[3];
        GetClientAbsOrigin(client, pos);
        if (IsValidEntity(witch))
            GetEntPropVector(witch, Prop_Send, "m_vecOrigin", pos);
        TeleportEntity(client, { 0.0, 0.0, 0.0 }, NULL_VECTOR, NULL_VECTOR);
        ForcePlayerSuicide(client);
        SetViewEntity(client, -1);

        if (IsValidEntity(witch)) pos[2] += 60;
        TeleportEntity(client, pos, NULL_VECTOR, NULL_VECTOR);

        return Plugin_Continue;
    } else SetEntProp(client, Prop_Data, "m_iHealth", health);

    int camera = GetClientCamera(client);
    // 相机实体可能被地图/其它插件清掉，此时对它取属性/Teleport 会刷错误，这里先补建
    if (!IsValidEntity(camera))
    {
        EnableCamera(client);
        camera = GetClientCamera(client);
        if (!IsValidEntity(camera)) return Plugin_Continue;
    }
    int sequence = GetEntProp(witch, Prop_Data, "m_nSequence");   // （局部 flags 已不再需要：蹲/站改看 g_iPose）
    bool grounded = GetEntPropEnt(witch, Prop_Data, "m_hGroundEntity") != -1;

    // 攀爬时取消接管
    if (IsClimbingUpToLedge(witch))
    {
        UnlockCamera(client, camera, mouse);

        if (grounded) ResetStatus(witch);
        return Plugin_Continue;
    }

    // 攀爬
    if ((buttons & IN_ATTACK2) && !(oldbtns & IN_ATTACK2)
        && g_iPose[client] != POSE_SIT && !g_bWitchAngry[client] && !g_bAngryResume[client])
    {
        buttons &= ~IN_ATTACK;
        float start[3], temp[3], target[3], rotate[3], fwd[3];

        GetEntPropVector(camera, Prop_Send, "m_vecOrigin", temp);
        GetEntPropVector(witch, Prop_Send, "m_vecOrigin", start);
        start[2] += temp[2];

        for(int i = 0; i < 3; i++)
            temp[i] = start[i];
        temp[2] += 160;
        Handle trace = TR_TraceRayFilterEx(start, temp, MASK_SOLID,
            RayType_EndPoint, EntityIgnore_TraceFilter);
        if (TR_DidHit(trace))
        {
            int surface = TR_GetSurfaceFlags(trace);
            delete trace;

            if (!(surface & SURF_SKY) && !(surface & SURF_SKY2D))
            {
                PrintHintText(client, "%T", "NarrowSpace", client);
                return Plugin_Continue;
            }
        }

        // 计算目标点
        trace = TR_TraceRayFilterEx(start, angles,
            MASK_SOLID, RayType_Infinite, EntityIgnore_TraceFilter);
        if (TR_DidHit(trace))
        {
            TR_GetEndPosition(target, trace);
            delete trace;

            // 计算距离
            float distance = SquareRoot(Pow(target[0] - start[0],
                 2.0) + Pow(target[1] - start[1], 2.0));
            if (distance > 120)
            {
                PrintHintText(client, "%T", "TargetTooFar", client);
                return Plugin_Continue;
            }

            // 计算高度
            if (!(10 < target[2] - start[2] < 120 * 10))
            {
                PrintHintText(client, "%T", "TargetTooHigh", client);
                return Plugin_Continue;
            }
            GetEntPropVector(witch, Prop_Send, "m_angRotation", rotate);
            GetAngleVectors(rotate, fwd, NULL_VECTOR, NULL_VECTOR);
            NormalizeVector(fwd, fwd);

            target[2] += 20;
            for(int i = 0; i < 3; i++)
            {
                start[i] = target[i] + fwd[i] * 40;
                temp[i] = target[i] - fwd[i] * 40;
            }
            target[2] += 10;
#if DEBUG
            ShowPos(2, start, temp, 100.0, 0.0, 30.0, 30.0);
#endif
            // 计算阻挡
            trace = TR_TraceRayFilterEx(start, temp,
                MASK_SOLID, RayType_EndPoint, EntityIgnore_TraceFilter);
            if (TR_DidHit(trace))
            {
                PrintHintText(client, "%T", "TargetBlocked", client);
                return Plugin_Continue;
            }
            delete trace;
            bool result = ClimbUpToLedge(witch, target, fwd);

            if (result)
            {
                PrintHintText(client, "%T", "ClimbSuccess", client);
                return Plugin_Continue;
            }
        }
    }

    if (!g_bThirdPerson && g_fLiftHeight[client])
    {
        float pos[3];
        GetEntPropVector(camera, Prop_Send, "m_vecOrigin", pos);
        float delta = pos[2] - g_fLiftHeight[client];
        if (-0.1 < delta < 0.1)
        {
            pos[2] = g_fLiftHeight[client];
            g_fLiftHeight[client] = 0.0;
        }
        else pos[2] += delta > 0 ? -1 : 1;
        TeleportEntity(camera, pos, NULL_VECTOR, NULL_VECTOR);
    }

    if (g_bAngryResume[client])
    {
        // 原来只要 OnWitchAngryEnd 不触发就永久卡住（"被激怒就没法操作"）
        if (g_fAngryTime > 0.0 && (GetGameTime() - g_fAngryStart[client]) >= g_fAngryTime)
        {
            g_bAngryResume[client] = false;
            g_bWitchAngry[client] = false;
            SetEntPropFloat(witch, Prop_Send, "m_rage", 0.0);
            SetEntProp(witch, Prop_Send, "m_mobRush", 0);
            DebugLogEx(client, 1, 0.0, "激怒(Resume)超时 %.1fs，归还控制", g_fAngryTime);
        }
        else
        {
            UnlockCamera(client, camera, mouse);
            if (g_bThirdPerson) UpdateThirdPersonCamera(client, camera, angles);
            SetEntProp(witch, Prop_Data, "m_nSequence", Seq(ANIM_SETTING_ANGRY));

            return Plugin_Continue;
        }
    }

    float pos[3], ang[3];
    if (g_bWitchAngry[client])
    {
        // 激怒状态：默认交给 AI 演扑击；但如果正在移动且配了激怒行走姿势，就按配置播
        if (g_iAngryWalkSeq >= 0 && g_bMoving[client])
            SetEntProp(witch, Prop_Data, "m_nSequence", Seq(g_iAngryWalkSeq));

        float rage = GetEntPropFloat(witch, Prop_Send, "m_rage");
        float angryFor = GetGameTime() - g_fAngryStart[client];

        // 结束条件：rage 烧完，或超过 witch_control_angry_time
        if (rage < 0.01 || (g_fAngryTime > 0.0 && angryFor >= g_fAngryTime))
        {
            g_bWitchAngry[client] = false;
            g_bAngryResume[client] = false;
            SetEntPropFloat(witch, Prop_Send, "m_rage", 0.0);
            SetEntProp(witch, Prop_Send, "m_mobRush", 0);
            g_fLiftHeight[client] = 0.0;
            DebugLogEx(client, 1, 0.0, "激怒结束（rage=%.2f 用时%.1fs），归还控制", rage, angryFor);
            // 不 return：继续往下走正常控制流程
        }
        else
        {
            if (g_bThirdPerson) UpdateThirdPersonCamera(client, camera, angles);
            else TeleportEntity(camera, NULL_VECTOR, angles, NULL_VECTOR);
            return Plugin_Continue;
        }
    }

    GetEntPropVector(witch, Prop_Send, "m_vecOrigin", pos);
    TeleportEntity(client, pos, NULL_VECTOR, NULL_VECTOR);

    // 女巫 yaw 跟鼠标（两种视角都要）
    ang[0] = 0.0; ang[1] = angles[1];
    TeleportEntity(witch, NULL_VECTOR, ang, NULL_VECTOR);

    if (g_bThirdPerson)
        UpdateThirdPersonCamera(client, camera, angles);   // 绝对世界坐标摆放
    else
    {
        ang[0] = angles[0]; ang[1] = 0.0;
        TeleportEntity(camera, NULL_VECTOR, ang, NULL_VECTOR);
    }

    ApplyPose(client);
    DebugLogEx(client, 1, 1.0,
        "状态 已接管%.1fs max_time=%d seq(引擎)=%d seq(我们想写)=%d flags=%d(现读) pose=%d grounded=%d 顶序列=%d 顶FL_DUCKING=%d",
        (g_fControlStart[client] > 0.0) ? GetGameTime() - g_fControlStart[client] : 0.0, g_iMaxTime,
        sequence, g_iSeqWant[client], GetEntProp(witch, Prop_Send, "m_fFlags"),
        g_iPose[client], grounded ? 1 : 0, g_iStompCount[client], g_iFlagFixCount[client]);

    if ((buttons & IN_ATTACK) && !(oldbtns & IN_ATTACK))
    {
        buttons &= ~IN_ATTACK;
        // 对着门/道具就爪它，否则才是激怒扑击
        int clawTarget = FindClawTarget(witch);
        if (clawTarget != -1)
            ClawTarget(client, clawTarget);
        else
            WitchAngry(client);
    }

    if (g_bLadderOn && TryClimbLadder(client, witch, buttons))
        return Plugin_Continue;   // 爬梯时不做普通移动

    if (g_iPose[client] != POSE_SIT)
        WitchMove(client, buttons);

    if (grounded)
    {
        // 注意：不能用 oldbtns 判断"刚按下"——下面会把 IN_DUCK 从 buttons 里清掉，引擎随即把
        // m_nOldButtons 也记成"没按"，于是每帧都判定成新按下 ⇒ 一秒切换几十次（日志 00:19:56 就是这样）。
        bool duckNow = (buttons & IN_DUCK) != 0;
        if (duckNow && !g_bDuckPrev[client] && !g_fLiftHeight[client])
        {
            GetEntPropVector(camera, Prop_Send, "m_vecOrigin", pos);
            // 原来这里靠读 m_nSequence 猜"现在是不是坐着"，读到的永远是 AI 写的值 ⇒ 状态永远判断错，
            // 而且 FL_DUCKING + 一个错的序列号并不会让女巫真的换姿势（模型没有 sit 动画）。
            // 现在改成自己记 g_iPose，并把蹲姿换成模型里真实存在的 a_CrouchWalkZero(59)。
            g_bPoseForced[client] = true;
            g_iPose[client] = (g_iPose[client] == POSE_SIT) ? POSE_STAND : POSE_SIT;
            if (g_iPose[client] == POSE_SIT && g_iSitSeqEngine[client] < 0)
                g_iSitSeqEngine[client] = GetEntProp(witch, Prop_Data, "m_nSequence");   // 兜底：用当前值

            // 起身/坐下必须改 FL_DUCKING：她的"蹲着"是靠这个标志 + 蹲姿序列一起维持的，
            // 光改序列不清标志 ⇒ 模型仍蹲着（之前"起身只会抬镜头"的另一半原因）
            int fl = GetEntProp(witch, Prop_Send, "m_fFlags");
            if (g_iPose[client] == POSE_SIT)
                SetEntProp(witch, Prop_Send, "m_fFlags", fl | FL_DUCKING);
            else
                SetEntProp(witch, Prop_Send, "m_fFlags", fl & ~FL_DUCKING);
            // 第三人称由 UpdateThirdPersonCamera 每帧算高度；g_fLiftHeight 必须保持 0，
            // 否则 `!g_fLiftHeight[client]` 这个按下条件永远不成立 ⇒ 只能坐不能站（日志 00:15:09 之后就是这样）
            g_fLiftHeight[client] = g_bThirdPerson ? 0.0 : PoseLiftTarget(client);
            if (g_iPose[client] == POSE_SIT)
                TeleportEntity(camera, NULL_VECTOR, {30.0, -25.0, 0.0}, NULL_VECTOR);
            else
                TeleportEntity(camera, NULL_VECTOR, {30.0, 0.0, 0.0}, NULL_VECTOR);
            buttons &= ~IN_DUCK;
            ApplyPose(client);
            DebugLogEx(client, 1, 0.0,
                "Ctrl 切换：pose=%d 序列写入=%d 读回=%d%s",
                g_iPose[client], g_iSeqWant[client],
                GetEntProp(witch, Prop_Data, "m_nSequence"),
                g_bThirdPerson ? "（第三人称，相机高度由 tp_height 跟姿势算）" : "（第一人称）");
        }

        g_bDuckPrev[client] = duckNow;   // 记原始值，供下一帧做边沿检测

        if ((buttons & IN_JUMP) && !(oldbtns & IN_JUMP))
        {
            float vel[3];
            GetEntPropVector(witch, Prop_Data, "m_vecAbsOrigin", pos);
            pos[2] += 20;
            TeleportEntity(witch, pos, NULL_VECTOR, NULL_VECTOR);

            GetEntPropVector(witch, Prop_Data, "m_vecVelocity", vel);
            vel[2] += g_hGravity.FloatValue * g_fJumpPower;   // 跳跃高度
            SetEntProp(witch, Prop_Data, "m_nSequence", Seq(g_iJumpSeq));  // 跳跃姿势
            SetWitchAcceleration(witch, vel);
        }
    }
    else
    {
        float vel[3];
        GetEntPropVector(witch, Prop_Data, "m_vecVelocity", vel);
        vel[2] -= g_hGravity.FloatValue / 48;
        SetWitchAcceleration(witch, vel);
        SetEntProp(witch, Prop_Data, "m_nSequence", Seq(ANIM_FALL));
    }

    return Plugin_Changed;
}

void SetViewToWitch(int client)
{
    EnableCamera(client);
    int witch = GetClientWitch(client);
    int camera = GetClientCamera(client);
    if (!IsValidEntity(camera)) return;

    float origin[3], rotate[3], lookat[3];
    GetEntPropVector(witch, Prop_Send, "m_vecOrigin", origin);
    GetEntPropVector(witch, Prop_Send, "m_angRotation", rotate);
    GetAngleVectors(rotate, lookat, NULL_VECTOR, NULL_VECTOR);
    NormalizeVector(lookat, lookat);
    // ScaleVector(lookat, -10.0);
    // AddVectors(lookat, origin, origin);
    // origin[2] += 75;
    // if (GetEntityFlags(witch) & FL_DUCKING)
    //     origin[2] -= 38;
    // rotate[0] = 30.0;
    ScaleVector(lookat, 16.0);
    AddVectors(lookat, origin, origin);
    origin[2] += 56;
    // 原来只看 FL_DUCKING：女巫序列是蹲姿但 flag 没设时相机就会给高，之后按 Ctrl 再 -38 就钻地了
    if (g_iPose[client] == POSE_SIT)
        origin[2] -= 38;

    DispatchKeyValueVector(camera, "origin", origin);
    DispatchKeyValueVector(camera, "angles", rotate);

    char name[64];
    Format(name, sizeof(name), "witch_%d", witch);
    DispatchKeyValue(witch, "targetname", name);
    SetVariantString(name);
    AcceptEntityInput(camera, "SetParent");

    if (g_bThirdPerson)
    {
        // 第三人称必须解除父关系，否则引擎会把相机位置再换算一次（实测会飞到天上）
        AcceptEntityInput(camera, "ClearParent");
        float vang[3];
        GetClientEyeAngles(client, vang);
        UpdateThirdPersonCamera(client, camera, vang);
    }

    SetViewEntity(client, camera);
}

void UnlockCamera(int client, int camera, const int mouse[2])
{
    float ang[3];
    GetEntPropVector(camera, Prop_Send, "m_angRotation", ang);
    if (FloatAbs(ang[0]) < 89.0 || ang[0] * mouse[1] < 0)
        ang[0] += mouse[1] * 0.04;//上负下正
    else ang[0] = 89.0 * (ang[0] < 0 ? -1 : 1);
    ang[1] -= mouse[0] * 0.04;//左负右正
    TeleportEntity(camera, NULL_VECTOR, ang, NULL_VECTOR);
    // ang[1] = (180 - FloatAbs(ang[1])) * ang[1] > 0 ? -1.0 : 1.0;
    TeleportEntity(client, NULL_VECTOR, ang, NULL_VECTOR);
}

bool EntityIgnore_TraceFilter(int entity, int mask, int self)
{
    if (entity == self || IsValidEntity(entity))
        return false;

    return true;
}

void WitchMove(int client, int buttons)
{
    float vel[3] = { 0.0, ... }, rotate[3];
    if (buttons & IN_FORWARD)
        vel[0] += 1;
    if (buttons & IN_BACK)
        vel[0] += -1;
    if (buttons & IN_MOVERIGHT)
        vel[1] += 1;
    if (buttons & IN_MOVELEFT)
        vel[1] += -1;

    if (!vel[0] && !vel[1]) return;

    int witch = GetClientWitch(client);
    GetEntPropVector(witch, Prop_Send, "m_angRotation", rotate);
    float fwd[3], right[3], up[3], result[3];
    GetAngleVectors(rotate, fwd, right, up);

    ScaleVector(fwd, vel[0]);
    ScaleVector(right, vel[1]);
    ScaleVector(up, vel[2]);

    AddVectors(fwd, result, result);
    AddVectors(right, result, result);
    AddVectors(up, result, result);

    NormalizeVector(result, result);
    ScaleVector(result, g_hWitchWalkSpeed.FloatValue * g_fSpeedScale);

    // 序列统一由 ApplyPose 按"站/走/坐"决定（这里只负责给加速度）。
    // 原来这里写死 ANIM_CATCHING_TARGET(@Melee_01=44) 就是"行走踉跄"的来源。
    SetWitchAcceleration(witch, result);
}

void ResetPlayerState(int client)
{
    int witch = GetClientWitch(client);
    g_iDamageBackup[client] = GetEntProp(client, Prop_Data, "m_takedamage");
    g_iMaxHealthBackup[client] = GetEntProp(client, Prop_Data, "m_iMaxHealth");
    SetEntProp(client, Prop_Send, "m_isGhost", 0);
    SetEntProp(client, Prop_Send, "m_lifeState", 0);
    SetEntProp(client, Prop_Data, "m_iMaxHealth", IsValidEntity(witch) ?
        GetEntProp(witch, Prop_Data, "m_iMaxHealth") :
        GetEntProp(client, Prop_Data, "m_iMaxHealth"));
    SetEntProp(client, Prop_Send, "m_fFlags", GetEntityFlags(client) | FL_GODMODE);
    SetEntProp(client, Prop_Data, "m_takedamage", 0, 1);
    SetZombieClass(client, 9);
    SetEntityRenderMode(client, RENDER_TRANSCOLOR);
    SetEntityRenderColor(client, 0, 0, 0, 0);
    SetEntProp(client, Prop_Send, "m_iGlowType", 3);
    SetEntProp(client, Prop_Send, "m_glowColorOverride", 1);
    SetEntProp(client, Prop_Send, "m_fEffects", 0);
    int ability = MakeCompatEntRef(GetEntProp(client, Prop_Send, "m_customAbility"));
    if (IsValidEntity(ability))AcceptEntityInput(ability, "Kill");
    int weapon = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");
    if (IsValidEntity(weapon)) RemovePlayerItem(client, weapon);
}

// 解除接管时把人物的无敌/隐形/血量上限还原，避免这些状态跟着玩家带到下一次出生（变成无敌 SI）
void RestorePlayerState(int client)
{
    if (!IsClientInGame(client)) return;

    SetEntProp(client, Prop_Send, "m_fFlags", GetEntityFlags(client) & ~FL_GODMODE);
    SetEntProp(client, Prop_Data, "m_takedamage", g_iDamageBackup[client], 1);
    SetEntProp(client, Prop_Data, "m_iMaxHealth", g_iMaxHealthBackup[client]);
    SetEntityRenderMode(client, RENDER_NORMAL);
    SetEntityRenderColor(client, 255, 255, 255, 255);
    SetEntProp(client, Prop_Send, "m_iGlowType", 0);
    SetEntProp(client, Prop_Send, "m_glowColorOverride", 0);
}

int CreateCamera(int target)
{
    int camera = GetClientCamera(target);
    if (!IsValidEntity(camera))
        camera = CreateEntityByName("point_viewcontrol");
    if (!IsValidEntity(camera)) return -1;

    DispatchKeyValue(camera, "model", CAMERA_MODEL);
    DispatchSpawn(camera);
    ActivateEntity(camera);

    return camera;
}

void EnableCamera(int client)
{
    if (!IsValidClient(client))
        return;

    int camera = CreateCamera(client);
    if (!IsValidEntity(camera))
        return;

    SetClientCamera(client, camera);
    AcceptEntityInput(camera, "Enable");
}

int GetClientWitch(int client)
{
    if (!IsValidClient(client))
        return -1;

    return EntRefToEntIndex(g_iWitch[client]);
}

int SetClientWitch(int client, int entity)
{
    if (!IsValidClient(client))
        return false;

    g_iWitch[client] = IsValidEntity(entity) ? EntIndexToEntRef(entity) : -1;
    return true;
}

int GetClientCamera(int client)
{
    if (!IsValidClient(client))
        return -1;

    return EntRefToEntIndex(g_iCamera[client]);
}

bool SetClientCamera(int client, int entity)
{
    if (!IsValidClient(client))
        return false;

    g_iCamera[client] = IsValidEntity(entity) ? EntIndexToEntRef(entity) : -1;
    return true;
}

void SetViewEntity(int client, int view)
{
    // 第三人称看的是女巫本体，不要显示第一人称手臂模型
    SetEntProp(client, Prop_Send, "m_bDrawViewmodel", (g_bThirdPerson && view != -1) ? 0 : 1, 1);
    SetEntPropEnt(client, Prop_Send, "m_hViewEntity", view);
    SetClientViewEntity(client, IsValidEdict(view) ? view : client);
}

void WitchAngry(int client)
{
    g_bWitchAngry[client] = true;
    g_fAngryStart[client] = GetGameTime();
    int witch = GetClientWitch(client);
    int camera = GetClientCamera(client);
    float pos[3];
    // 第三人称不参与升降；否则 g_fLiftHeight 非 0 会一直挡住 Ctrl 切换
    if (g_bThirdPerson)
    {
        g_fLiftHeight[client] = 0.0;
    }
    else
    {
        GetEntPropVector(camera, Prop_Send, "m_vecOrigin", pos);
        g_fLiftHeight[client] = pos[2] + 24;
    }

    SetEntPropFloat(witch, Prop_Send, "m_rage", 1.0);
    SetEntProp(witch, Prop_Send, "m_mobRush", 1);
}

// // ILocomotion::IsUsingLadder(void)
// bool IsUsingLadder(int entity)
// {
//     Address locomotion = GetLocomotion(entity);
//     if (locomotion == Address_Null) return false;

//     return SDKCall(g_hIsUsingLadder, locomotion);
// }

// ILocomotion::IsClimbingUpToLedge(void)
bool IsClimbingUpToLedge(int entity)
{
    Address locomotion = GetLocomotion(entity);
    if (locomotion == Address_Null) return false;

    return SDKCall(g_hIsClimbingUpToLedge, locomotion);
}

// ILocomotion::Reset
bool ResetStatus(int entity)
{
    Address locomotion = GetLocomotion(entity);
    if (locomotion == Address_Null) return false;

    return SDKCall(g_hResetStatus, locomotion);
}


// ILocomotion::ClimbUpToLedge(Vector const&,Vector const&,CBaseEntity const*)
bool ClimbUpToLedge(int entity, const float target[3], const float fwd[3], int obstacle = 0)
{
    Address locomotion = GetLocomotion(entity);
    if (locomotion == Address_Null) return false;

    if (!obstacle) obstacle = entity;
    return SDKCall(g_hClimbUpToLedge, locomotion, target, fwd, obstacle);
}

// ILocomotion::SetAcceleration(Vector const&)
void SetWitchAcceleration(int entity, const float acceleration[3])
{
    Address locomotion = GetLocomotion(entity);
    if (locomotion == Address_Null) return;

    float vector[3];
    AddVectors(NULL_VECTOR, acceleration, vector);
    ScaleVector(vector, 100.0);
    SDKCall(g_hSetAcceleration, locomotion, vector);
}

// ======== From [L4D2] Witch Control
// https://forums.alliedmods.net/showthread.php?t=125591
void ScreenFade(int client, int duration, int time, const int color[4])
{
    Handle screen = StartMessageOne("Fade", client);

    if (screen != null)
    {
        BfWriteShort(screen, duration * 400);
        BfWriteShort(screen, time * 400);
        BfWriteShort(screen, 0x0001);
        BfWriteByte(screen, color[0]);    //R
        BfWriteByte(screen, color[1]);    //G
        BfWriteByte(screen, color[2]);    //B
        BfWriteByte(screen, color[3]);    //A
        EndMessage();
    }
}

int ShowInstructorHint(int entity, const char[] message, int lenth, const char[] bind)
{
    char[] hintMsg = new char[lenth];
    strcopy(hintMsg, lenth, message);
    ReplaceString(hintMsg, lenth, "\n", " ");

    char hintName[16];
    int hint = CreateEntityByName("env_instructor_hint");
    if (!IsValidEntity(hint)) return -1;

    Format(hintName, sizeof(hintName), "hint_%d", entity);
    if (IsValidEntity(entity))
    {
        DispatchKeyValue(entity, "targetname", hintName);
        DispatchKeyValue(hint, "hint_target", hintName);
    }

    DispatchKeyValue(hint, "hint_timeout", "3.6");
    DispatchKeyValue(hint, "hint_range", "0.01");
    DispatchKeyValue(hint, "hint_color", "255 255 255");
    DispatchKeyValue(hint, "hint_icon_onscreen", "use_binding");
    DispatchKeyValue(hint, "hint_caption", hintMsg);
    DispatchKeyValue(hint, "hint_binding", bind);

    DispatchSpawn(hint);
    AcceptEntityInput(hint, "ShowHint");

    return hint;
}

// CTerrorPlayer::SetClass(ZombieClassType)
void SetZombieClass(int client, int classtype)
{
    if (!IsValidClient(client)) return;

    SDKCall(g_hSetZombieClass, client, classtype);
}

// ======== ALL below are from BHaType
// https://forums.alliedmods.net/showthread.php?p=2771240
Address GetLocomotion(int entity)
{
    Address nextbot = SDKCall(g_hGetNextBot, entity);
    if (!nextbot) return Address_Null;

    return SDKCall(g_hGetLocomotion, nextbot);
}

// Address GetNextBotPointer(int entity)
// {
//     return SDKCall(g_hGetNextBot, entity);
// }

// Address GetLocomotionPointer(Address nextbot)
// {
//     return SDKCall(g_hGetLocomotion, nextbot);
// }

// ======== 爪击门/道具 + 爬梯（本次修改新增）

// 找她正前方 110 单位内可爪的门/道具
int FindClawTarget(int witch)
{
    if (g_fClawDamage <= 0.0) return -1;   // 伤害设 0 等于关掉爪击（左键永远只激怒）

    float wpos[3], ang[3], fwd[3];
    GetEntPropVector(witch, Prop_Send, "m_vecOrigin", wpos);
    GetEntPropVector(witch, Prop_Send, "m_angRotation", ang);
    GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);

    static const char classes[][] =
    {
        "prop_door_rotating", "func_door", "func_door_rotating",
        "prop_physics", "prop_dynamic", "physics_prop"
    };

    int best = -1;
    float bestDist = 110.0;

    for (int c = 0; c < sizeof(classes); c++)
    {
        int ent = -1;
        while ((ent = FindEntityByClassname(ent, classes[c])) != -1)
        {
            if (ent == witch) continue;

            float epos[3];
            GetEntPropVector(ent, Prop_Send, "m_vecOrigin", epos);
            float dist = GetVectorDistance(wpos, epos);
            if (dist > bestDist) continue;

            float dir[3];
            MakeVectorFromPoints(wpos, epos, dir);
            dir[2] = 0.0;
            NormalizeVector(dir, dir);
            if (GetVectorDotProduct(fwd, dir) < 0.35) continue;

            bestDist = dist;
            best = ent;
        }
    }

    return best;
}

void ClawTarget(int client, int target)
{
    char cls[64];
    GetEntityClassname(target, cls, sizeof(cls));

    int hp = GetEntProp(target, Prop_Data, "m_iHealth");
    if (hp > 0)
        SDKHooks_TakeDamage(target, client, client, g_fClawDamage, DMG_CLUB);
    else
        AcceptEntityInput(target, "Open");

    g_fAttackAnimUntil[client] = GetGameTime() + 0.6;
    DebugLogEx(client, 1, 0.0, "爪击 %s#%d（血量 %d，伤害 %.0f）", cls, target, hp, g_fClawDamage);
}

// 按 W 且身边有梯子时往上爬
bool TryClimbLadder(int client, int witch, int buttons)
{
    if (!(buttons & IN_FORWARD)) return false;

    float wpos[3], ang[3], fwd[3];
    GetEntPropVector(witch, Prop_Send, "m_vecOrigin", wpos);
    GetEntPropVector(witch, Prop_Send, "m_angRotation", ang);
    GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);

    static const char ladders[][] = { "func_useableladder", "func_simpleladder", "func_ladder" };

    int best = -1;
    float bestDist = 80.0;

    for (int c = 0; c < sizeof(ladders); c++)
    {
        int ent = -1;
        while ((ent = FindEntityByClassname(ent, ladders[c])) != -1)
        {
            float epos[3];
            GetEntPropVector(ent, Prop_Send, "m_vecOrigin", epos);
            float dist = GetVectorDistance(wpos, epos);
            if (dist < bestDist)
            {
                bestDist = dist;
                best = ent;
            }
        }
    }

    if (best == -1) return false;

    float vel[3];
    vel[0] = fwd[0] * 0.25;
    vel[1] = fwd[1] * 0.25;
    vel[2] = float(g_iLadderSpeed) / 250.0;
    NormalizeVector(vel, vel);
    ScaleVector(vel, float(g_iLadderSpeed));

    SetWitchAcceleration(witch, vel);
    SetEntProp(witch, Prop_Data, "m_nSequence", Seq(g_iClimbSeq));
    g_iSeqWant[client] = Seq(g_iClimbSeq);

    DebugLogEx(client, 2, 1.0, "爬梯：梯子#%d 距离%.0f 上升速度%d", best, bestDist, g_iLadderSpeed);
    return true;
}

// ======== 调试 & 姿势控制（本次修改新增）
// 用途：① 坐下/起身真的改姿势（不再只是相机上下）② 把"谁把序列顶掉了"变成可看的数据
int Seq(int anim)
{
    return anim + g_iSeqOffset;
}

void DebugLogEx(int client, int level, float throttle, const char[] fmt, any ...)
{
    if (g_hDebug == null || g_hDebug.IntValue < level) return;
    if (throttle > 0.0)
    {
        float now = GetGameTime();
        if (now - g_fLastLog[client] < throttle) return;
        g_fLastLog[client] = now;
    }

    char msg[256];
    VFormat(msg, sizeof(msg), fmt, 5);

    // ① 独立日志文件（你要的那份）
    if (g_hDebugLog != null)
    {
        char stamp[32];
        FormatTime(stamp, sizeof(stamp), "%m/%d %H:%M:%S");
        WriteFileLine(g_hDebugLog, "[%s] %s", stamp, msg);
        FlushFile(g_hDebugLog);
    }

    // ② 服务器控制台（不进玩家聊天，避免刷屏）
    PrintToServer("[witch] %s", msg);

    // ③ 只有 debug>=2 才顺带发到受控玩家聊天
    if (g_hDebug.IntValue >= 2 && client > 0 && client <= MaxClients && IsClientInGame(client))
        PrintToChat(client, "[女巫] %s", msg);
}

void OpenDebugLog()
{
    if (g_hDebugLog != null) return;

    BuildPath(Path_SM, g_sDebugLogPath, sizeof(g_sDebugLogPath), "logs/witch_control_debug.log");
    g_hDebugLog = OpenFile(g_sDebugLogPath, "a");
    if (g_hDebugLog == null)
        LogError("无法打开调试日志 %s", g_sDebugLogPath);
    else
    {
        WriteFileLine(g_hDebugLog, "---- 新会话 %s ----", g_sDebugLogPath);
        FlushFile(g_hDebugLog);
    }
}

void CloseDebugLog()
{
    if (g_hDebugLog != null)
    {
        delete g_hDebugLog;
        g_hDebugLog = null;
    }
}

// 第三人称：把相机放到女巫身后上方。父实体下 m_vecOrigin 是"本地坐标"，
// 直接写网络属性最稳（TeleportEntity→SetAbsOrigin 在父实体上可能按世界坐标解释，会把相机甩出地图）
// 第三人称：相机**不挂父**，每帧按女巫的世界坐标 + 玩家视角算绝对位置/角度。
// （挂父时写 m_vecOrigin 会被引擎再换算一次，实测相机会飞走）
void UpdateThirdPersonCamera(int client, int camera, const float viewAngles[3])
{
    int witch = GetClientWitch(client);
    if (!IsValidEntity(camera) || !IsValidEntity(witch)) return;

    float wpos[3], fwd[3], up[3], yaw[3] = {0.0, 0.0, 0.0};
    GetEntPropVector(witch, Prop_Send, "m_vecOrigin", wpos);
    yaw[1] = viewAngles[1];
    GetAngleVectors(yaw, fwd, NULL_VECTOR, up);

    float pos[3];
    pos[0] = wpos[0] - fwd[0] * float(g_iTPDistance);
    pos[1] = wpos[1] - fwd[1] * float(g_iTPDistance);
    // 蹲下时相机跟着压低（原来第三人称完全不降，导致"坐下看不出、起身镜头也不抬"）
    pos[2] = wpos[2] + float(g_iTPHeight) -
        ((g_iPose[client] == POSE_SIT) ? float(g_iTPSitDrop) : 0.0);
    if (pos[2] < wpos[2] + 20.0)   // 兜底：绝不低于她脚底上方 20（"蹲下相机在地下"就是这个）
        pos[2] = wpos[2] + 20.0;

    TeleportEntity(camera, pos, viewAngles, NULL_VECTOR);
}

float GetCamOriginZ(int camera)
{
    if (!IsValidEntity(camera)) return 0.0;

    float p[3];
    GetEntPropVector(camera, Prop_Send, "m_vecOrigin", p);
    return p[2];
}

// 女巫现在到底是不是蹲着：FL_DUCKING 或 序列号落在 a_CrouchWalk* 区间
bool DetectWitchSitting(int witch)
{
    if (GetEntProp(witch, Prop_Send, "m_fFlags") & FL_DUCKING)
        return true;

    int seq = GetEntProp(witch, Prop_Data, "m_nSequence");
    for (int i = g_iSitSeq; i <= g_iSitSeq + 4; i++)   // a_CrouchWalk* 区间（witch_control_sit_seq 起 5 个）
        if (seq == Seq(i))
            return true;

    return false;
}

// 坐下/起身的相机阶梯：永远从"接管时的站立高度"算，不在当前值上累加（否则会一路钻到地下）
float PoseLiftTarget(int client)
{
    float base = g_fCamBaseZ[client];

    // 第三人称：相机在身后，姿势靠动画表现，相机不再升降（避免镜头忽高忽低/钻地）
    if (g_bThirdPerson)
        return base;

    float target = (g_iPose[client] == POSE_SIT) ? base - 38.0 : base;

    // 只有确认是"相对坐标"（数值很小）时才夹住下限，世界坐标不动它
    if (FloatAbs(base) < 500.0 && target < 4.0)
        target = 4.0;

    return target;
}

// 把"想要的姿势"写进女巫：序列号 + FL_DUCKING
void ApplyPose(int client)
{
    int witch = GetClientWitch(client);
    if (!IsValidEntity(witch)) return;

    // 只在"坐"或调试强制时才硬写序列：
    //   POSE_STAND 时不写 —— 站起来就该把动画交还引擎，否则走路/扑击都没有动画（日志里 顶掉次数 暴涨就是这个）
    // 爪击动作优先维持 0.6 秒，否则下一帧就被状态动画顶掉
    if (g_fAttackAnimUntil[client] > GetGameTime())
    {
        SetEntProp(witch, Prop_Data, "m_nSequence", Seq(g_iMeleeSeq));
        g_iSeqWant[client] = Seq(g_iMeleeSeq);
        return;
    }

    // 接管期间**永远**给一个明确动画：站着不再放任引擎（放任的结果就是她一直播 seq=4 的半蹲 idle）
    int seq;
    if (g_iSeqOverride[client] >= 0)
        seq = g_iSeqOverride[client];
    else if (g_iPose[client] == POSE_SIT)
        seq = (g_iSitSeqEngine[client] >= 0) ? g_iSitSeqEngine[client] : Seq(ANIM_STANDING_CRYING);
    else if (g_iStandSeq >= 0)
        seq = g_iStandSeq;
    else if (g_bMoving[client])
        seq = g_iWalkSeq;                // 行走（默认 0 = 抱头行走）
    else
        seq = g_iIdleSeq;                // 站立 idle（默认 0 = 抱头站姿）

    int flags = GetEntProp(witch, Prop_Send, "m_fFlags");
    if (g_iPose[client] == POSE_SIT) flags |= FL_DUCKING;
    else if (g_iSeqOverride[client] < 0) flags &= ~FL_DUCKING;
    SetEntProp(witch, Prop_Send, "m_fFlags", flags);

    SetEntProp(witch, Prop_Data, "m_nSequence", seq);
    g_iSeqWant[client] = seq;
}

// 挂在被控制女巫身上的 ThinkPost：AI 的 think 跑完之后再写一次，防止被顶掉
public void WitchThinkPost(int witch)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!g_bWitchControl[client] || GetClientWitch(client) != witch) continue;
        if (g_bWitchAngry[client] || g_bAngryResume[client]) return; // 激怒/扑击时让 AI 自己演

        // 姿态标志每帧强制：日志里 pose=2 时 flags 仍是 8195，说明引擎/AI 每帧把它改回去
        if (g_bPoseForced[client])
        {
            int fl = GetEntProp(witch, Prop_Send, "m_fFlags");
            int want = (g_iPose[client] == POSE_SIT) ? (fl | FL_DUCKING) : (fl & ~FL_DUCKING);
            if (fl != want)
            {
                SetEntProp(witch, Prop_Send, "m_fFlags", want);
                g_iFlagFixCount[client]++;
            }
        }

        int cur = GetEntProp(witch, Prop_Data, "m_nSequence");
        if (g_iSeqWant[client] >= 0 && cur != g_iSeqWant[client])
            g_iStompCount[client]++;   // AI 把我们上一帧写的序列顶掉了（只在强写时统计）

        ApplyPose(client);
        return;
    }
}

int FindControlledClient()
{
    for (int i = 1; i <= MaxClients; i++)
        if (g_bWitchControl[i] && IsValidEntity(GetClientWitch(i)))
            return i;

    return -1;
}

public Action Cmd_WitchSeq(int client, int args)
{
    int who = FindControlledClient();
    if (who == -1)
    {
        ReplyToCommand(client, "[witch] 现在没有人控制女巫");
        return Plugin_Handled;
    }

    int witch = GetClientWitch(who);
    ReplyToCommand(client,
        "[witch] 控制者=%N witch#%d\n seq(现在)=%d seq(我们写)=%d flags=%d pose=%d override=%d 被顶次数=%d seq_offset=%d",
        who, witch,
        GetEntProp(witch, Prop_Data, "m_nSequence"), g_iSeqWant[who],
        GetEntProp(witch, Prop_Send, "m_fFlags"), g_iPose[who],
        g_iSeqOverride[who], g_iStompCount[who], g_iSeqOffset);
    return Plugin_Handled;
}

public Action Cmd_WitchSet(int client, int args)
{
    int who = FindControlledClient();
    if (who == -1)
    {
        ReplyToCommand(client, "[witch] 现在没有人控制女巫");
        return Plugin_Handled;
    }

    char arg[16];
    if (args < 1)
    {
        ReplyToCommand(client, "[witch] 用法: sm_witchset <0-99> | sm_witchset off");
        return Plugin_Handled;
    }
    GetCmdArg(1, arg, sizeof(arg));

    if (!strcmp(arg, "off", false))
    {
        g_iSeqOverride[who] = -1;
        ApplyPose(who);
        ReplyToCommand(client, "[witch] 已取消强制序列");
        return Plugin_Handled;
    }

    g_iSeqOverride[who] = StringToInt(arg);
    ApplyPose(who);
    int wit = GetClientWitch(who);
    ReplyToCommand(client, "[witch] 强制序列=%d 读回=%d", g_iSeqOverride[who],
        IsValidEntity(wit) ? GetEntProp(wit, Prop_Data, "m_nSequence") : -1);
    DebugLogEx(who, 1, 0.0, "sm_witchset %d", g_iSeqOverride[who]);
    return Plugin_Handled;
}

static const int g_iTryList[] = { 0, 1, 2, 11, 15, 33, 35, 37, 39, 41, 44, 49, 59, 63 };
int g_iTryIdx;

public Action Cmd_WitchTry(int client, int args)
{
    int who = FindControlledClient();
    if (who == -1)
    {
        ReplyToCommand(client, "[witch] 现在没有人控制女巫");
        return Plugin_Handled;
    }

    if (g_hScanTimer != null)
    {
        delete g_hScanTimer;
        g_hScanTimer = null;
    }

    g_iScanClient = who;
    g_iTryIdx = 0;
    g_bPoseForced[who] = true;
    g_hScanTimer = CreateTimer(2.5, Timer_TrySeq, _, TIMER_REPEAT);
    ReplyToCommand(client, "[witch] 开始试候选姿势（每 2.5 秒一个，数字会打在受控玩家聊天里）");
    return Plugin_Handled;
}

Action Timer_TrySeq(Handle timer)
{
    if (g_iScanClient == -1 || !g_bWitchControl[g_iScanClient] || g_iTryIdx >= sizeof(g_iTryList))
    {
        if (g_iScanClient != -1)
        {
            g_iSeqOverride[g_iScanClient] = -1;
            ApplyPose(g_iScanClient);
        }
        g_iScanClient = -1;
        g_hScanTimer = null;
        return Plugin_Stop;
    }

    int anim = g_iTryList[g_iTryIdx];
    g_iSeqOverride[g_iScanClient] = anim + g_iSeqOffset;
    ApplyPose(g_iScanClient);
    if (IsClientInGame(g_iScanClient))
        PrintToChat(g_iScanClient, "[女巫] 试姿势 anim=%d（写入 %d）", anim, anim + g_iSeqOffset);
    DebugLogEx(g_iScanClient, 1, 0.0, "试姿势 anim=%d 写入=%d", anim, anim + g_iSeqOffset);
    g_iTryIdx++;
    return Plugin_Continue;
}

public Action Cmd_WitchScan(int client, int args)
{
    int who = FindControlledClient();
    if (who == -1)
    {
        ReplyToCommand(client, "[witch] 现在没有人控制女巫");
        return Plugin_Handled;
    }

    if (g_hScanTimer != null)
    {
        delete g_hScanTimer;
        g_hScanTimer = null;
    }

    char a1[16], a2[16];
    g_iScanFrom = 0;
    g_iScanTo = 99;
    if (args >= 1) { GetCmdArg(1, a1, sizeof(a1)); g_iScanFrom = StringToInt(a1); }
    if (args >= 2) { GetCmdArg(2, a2, sizeof(a2)); g_iScanTo = StringToInt(a2); }

    g_iScanClient = who;
    g_iScanStep = g_iScanFrom;
    g_bPoseForced[who] = true;
    g_hScanTimer = CreateTimer(0.6, Timer_SeqScan, _, TIMER_REPEAT);
    ReplyToCommand(client, "[witch] 开始扫描序列 %d..%d（每 0.6 秒一个）。看到想要的姿势记下数字，sm_witchset <n> 固定",
        g_iScanFrom, g_iScanTo);
    return Plugin_Handled;
}

Action Timer_SeqScan(Handle timer)
{
    if (g_iScanClient == -1 || !g_bWitchControl[g_iScanClient] || g_iScanStep > g_iScanTo)
    {
        if (g_iScanClient != -1)
        {
            g_iSeqOverride[g_iScanClient] = -1;
            ApplyPose(g_iScanClient);
        }
        g_iScanClient = -1;
        g_hScanTimer = null;
        return Plugin_Stop;
    }

    int witch = GetClientWitch(g_iScanClient);
    if (!IsValidEntity(witch))
    {
        g_iScanClient = -1;
        g_hScanTimer = null;
        return Plugin_Stop;
    }

    g_iSeqOverride[g_iScanClient] = g_iScanStep;
    ApplyPose(g_iScanClient);
    if (IsClientInGame(g_iScanClient))
        PrintToChat(g_iScanClient, "[女巫] 扫描 seq=%d", g_iScanStep);
    DebugLogEx(g_iScanClient, 1, 0.0, "扫描 seq=%d 读回=%d", g_iScanStep,
        GetEntProp(witch, Prop_Data, "m_nSequence"));
    g_iScanStep++;
    return Plugin_Continue;
}

// ======== 内联自 <paiutils>
// https://github.com/Paimon-Kawaii/L4D2-Plugins/blob/main/Others/include/paiutils.inc
// 原插件 #include <paiutils>，但仓库里没有附带这个 include，用干净的 SourceMod 编译环境编不出来。
// 这里只搬进插件真正用到的三个判定函数，语义与原文件保持一致。
stock bool IsValidClient(int client)
{
    return (0 < client <= MaxClients && IsClientConnected(client) && IsClientInGame(client));
}

stock bool IsInfected(int client)
{
    return (IsValidClient(client) && GetClientTeam(client) == 3);
}

stock bool IsTank(int client)
{
    return (IsValidClient(client) && GetClientTeam(client) == 3 &&
        GetEntProp(client, Prop_Send, "m_zombieClass") == 8);   // 8 = ZC_Tank
}
