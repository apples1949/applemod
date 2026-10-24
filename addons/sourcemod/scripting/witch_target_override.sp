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
#define PLUGIN_VERSION "1.9.0"
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

int Enemy[MAXENTITY+1];
float ActionTime[MAXENTITY+1], EnemyTime[MAXENTITY+1], StuckTime[MAXENTITY+1], PauseTime[MAXENTITY+1], LastTime[MAXENTITY+1], 
    TargetDir[MAXENTITY+1][3], LastPos[MAXENTITY+1][3], LastSetPos[MAXENTITY+1][3];
bool bWitchScared[MAXENTITY+1], bWitchSit[MAXENTITY+1], bWitchFollowing[MAXENTITY+1];
Handle BurnWitchTimer[MAXENTITY+1] = {null};
bool ge_bInvalidTrace[MAXENTITY+1];
bool g_bFakeBurnHit[MAXENTITY+1];   // 本插件自己发出去的那一记 0 伤害 DMG_BURN，不算真着火
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
	z_witch_burn_time.AddChangeHook(ConVarChanged_Cvars);

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
	ResetTimer();
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
	#if DEBUG
		PrintToChatAll("witch attacking new target %N, her max health: %d, now health: %d", target, GetEntProp(witch, Prop_Data, "m_iMaxHealth"), GetEntProp(witch, Prop_Data, "m_iHealth"));
	#endif

	if(addHealth > 0)
	{
		SetEntProp(witch, Prop_Data, "m_iHealth", GetEntProp(witch, Prop_Data, "m_iHealth") + addHealth);
	}

	// 真着火判定：火焰状态标记（引擎给女巫点火时会写 m_bIsBurning）
	bool burning = (GetEntityFlags(witch) & FL_ONFIRE) != 0 || GetEntProp(witch, Prop_Send, "m_bIsBurning") != 0;

	if(burning)
	{
		ExtinguishEntity(witch);
		int flame = GetEntPropEnt(witch, Prop_Send, "m_hEffectEntity");
		if( flame != -1 )
		{
			AcceptEntityInput(flame, "Kill");
		}

		// 这一记 0 伤害只是为了骗引擎把 target 认成攻击者（女巫才会改追他），
		// 不是真的燃烧伤害；用标志位挡掉 OnTakeDamageWitchPost 里的"中弹着火"分支
		g_bFakeBurnHit[witch] = true;
		SDKHooks_TakeDamage(witch, target, target, 0.0, DMG_BURN);
		g_bFakeBurnHit[witch] = false;

		// recalculate_burn_time = 1：换目标时把烧伤时间重新计一遍（0 = 保持原定死亡时间）
		if (g_bCvarReCalculateBurnOverride && IsWitch(witch))
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
		int anim = GetEntProp(witch, Prop_Send, "m_nSequence");
		g_bFakeBurnHit[witch] = true;
		SDKHooks_TakeDamage(witch, target, target, 0.0, DMG_BURN);
		g_bFakeBurnHit[witch] = false;

		if (IsWitch(witch))   // 这一记万一把她打没了，后面的写入就别做了
		{
			SetEntProp(witch, Prop_Send, "m_nSequence", anim);
			SetEntProp(witch, Prop_Send, "m_bIsBurning", 0);
			SDKHook(witch, SDKHook_ThinkPost, PostThink);
		}
	}
}

public void PostThink(int witch)
{
	SDKUnhook(witch, SDKHook_ThinkPost, PostThink);

	ExtinguishEntity(witch);

	int flame = GetEntPropEnt(witch, Prop_Send, "m_hEffectEntity");
	if( flame != -1 )
	{
		AcceptEntityInput(flame, "Kill");
	}
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

	if (bFollow && g_bCvarAllow) StartHookWitch(witch);

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

	StopHookWitch(entity);
	bWitchScared[entity] = false;
	bWitchSit[entity] = false;
	bWitchFollowing[entity] = false;
	g_bFakeBurnHit[entity] = false;
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
    SDKUnhook(witch, SDKHook_ThinkPost, ThinkWitch);		
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

public Action ThinkWitch(int witch)
{
	if(bWitchScared[witch])
	{
		SDKUnhook(witch, SDKHook_ThinkPost, ThinkWitch);
		bWitchFollowing[witch] = false;
		return Plugin_Continue;
	}

	float time = GetEngineTime();
	float duration = time-LastTime[witch];
	if(duration>0.1) duration = 0.1;
	LastTime[witch] = time;
	
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
			SDKUnhook(witch, SDKHook_ThinkPost, ThinkWitch);
			bWitchFollowing[witch] = false;
			return Plugin_Continue;
		}
	}
	else
	{
		if( m_nSequence == 31 || ( 36 <= m_nSequence && m_nSequence <= 39) )
		{		
			SDKUnhook(witch, SDKHook_ThinkPost, ThinkWitch);
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
	// 被生还者打中 ⇒ 停掉"主动跟随"，把控制权交回引擎 AI
	// （原来是借用 EnemyTime > 0 当"曾跟随"的标志，现在用显式状态位，意图明确）
	if(bWitchFollowing[witch] && attacker > 0 && attacker <= MaxClients && IsClientInGame(attacker) && GetClientTeam(attacker) == L4D_TEAM_SURVIVORS)
	{
		StopHookWitch(witch);
	}

	// 本插件自己发的那记 0 伤害 DMG_BURN 只是为了让引擎把她换成 target 的攻击者，
	// 不是真的着火 —— 不能再拿它来建燃烧计时器（否则换完目标 15 秒后她会被自己打死）
	if(g_bFakeBurnHit[witch]) return;

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
	AcceptEntityInput(entity, "Kill");
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
		if (bWitchFollowing[entity])
			SDKUnhook(entity, SDKHook_ThinkPost, ThinkWitch);

		bWitchScared[entity] = false;
		bWitchSit[entity] = false;
		bWitchFollowing[entity] = false;
		g_bFakeBurnHit[entity] = false;
		ge_bInvalidTrace[entity] = false;
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