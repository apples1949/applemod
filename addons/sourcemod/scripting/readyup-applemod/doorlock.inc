#if defined _readyup_doorlock_included
 #endinput
#endif
#define _readyup_doorlock_included

// ============================================================================
//  门锁模块（原 optional/12v12/l4d2_doorlock.smx，已并入准备模式插件）
//  - 保留全部 l4d2_dlock_* 参数名，配置不用改
//  - 不再使用 readyup_external native：直接调用本插件内部阶段函数
//  - 已去掉多语言：文本中文硬编码
//  - 符号统一 DL_ 前缀，避免与 readyup 侧重名
// ============================================================================

#define DL_PLUGIN_VERSION		"2.7.5-applefix"

#define DL_SOUND_COUNTDOWN		"buttons/blip1.wav"
#define DL_SOUND_MOVEOUT		"ui/survival_teamrec.wav"
#define DL_SOUND_BREAK1			"physics/metal/metal_box_break1.wav"
#define DL_SOUND_BREAK2			"physics/metal/metal_box_break2.wav"

// 诊断跟踪日志（排查崩溃用）：写到 addons/sourcemod/logs/l4d2_dlock_trace.log
// 崩溃是进程级 abort，最后一行就是"死前正在做什么"，因此每秒心跳 + 每次面板发送都记录。
#define DL_TRACE_FILE			"l4d2_dlock_trace.log"

// 中文文本（原 doorlock.phrases.txt 的 chi 行）
#define DL_TXT_MOVEOUT			"已解锁，可以开始."
#define DL_TXT_LOCKED			"安全门已锁定，请等待：%i秒."
#define DL_TXT_FROZEN			"已冻结，请等待：%i秒."
#define DL_TXT_MENU_HEADER		"---------加载状态---------"
#define DL_TXT_MENU_CONNECTING	"连接中"
#define DL_TXT_MENU_SURVIVOR	"生还者"
#define DL_TXT_MENU_INFECTED	"感染者"
#define DL_TXT_MENU_SPECTATOR	"旁观者"
#define DL_TXT_MENU_CASTER_FMT	"%s (%d, 含解说%d)"
#define DL_TXT_MENU_TIMEOUT_TAG	" [超时]"

// 状态面板分类：每个分类一栏，栏标题显示该分类人数。
// 归类口径：
//   连接中 = 已连接但还没进游戏（IsClientInGame 为假）；其中加载超时者
//            （DL_g_iTimeout >= l4d2_dlock_timeout）在 displaypanel=2 完整显示时仍留在本栏、
//            行尾加 DL_TXT_MENU_TIMEOUT_TAG 标记；displaypanel=1 隐藏连接失败玩家时整条不计不列。
//   生还者 = 在游戏且 GetClientTeam() == L4D2Team_Survivor
//   感染者 = 在游戏且 GetClientTeam() == L4D2Team_Infected
//   旁观者 = 在游戏且不属于上面两队（含 cvar 上的解说 caster，标题里额外给出解说人数）
#define DL_PANEL_GROUP_CONNECTING	0
#define DL_PANEL_GROUP_SURVIVOR		1
#define DL_PANEL_GROUP_INFECTED		2
#define DL_PANEL_GROUP_SPECTATOR	3
#define DL_PANEL_GROUP_COUNT		4

Handle DL_g_hTimer;
Handle DL_g_hRecoveryTimer;
Handle DL_g_hUnfreezeTimer;
int DL_g_iFreezeSerial;
float DL_g_fReleaseUntil;
int DL_g_iCurrentMode;
bool DL_g_bConfigsReady, DL_g_bRoundEnded, DL_g_bRoundLive;
bool DL_g_bOwnSbStop, DL_g_bOwnNbStop;
int DL_g_iSavedSbStop, DL_g_iSavedNbStop;
int DL_g_iFrozenUserId[MAXPLAYERS + 1];
int DL_g_iReleasedUserId[MAXPLAYERS + 1];

ConVar
	DL_g_cSbStop,
	DL_g_cNbStop,
	DL_g_cAllow,
	DL_g_cGameMode,
	DL_g_cModes,
	DL_g_cModesOff,
	DL_g_cModesTog,
	DL_g_cBreakTheDoor,
	DL_g_cPrepareTime1r,
	DL_g_cPrepareTime2r,
	DL_g_cClientTimeOut,
	DL_g_cDisplayMode,
	DL_g_cDisplayPanel,
	DL_g_cFreezeNodoor,
	DL_g_cTrace;

bool
	DL_g_bCvarAllow,
	DL_g_bMapStarted,
	DL_g_bFirstRound,
	DL_g_bBreakTheDoor,
	DL_g_bFreezeNodoor,
	DL_g_bFreezeAllowed,
	DL_g_bLifecycleStarted,
	DL_g_bIsLoading[MAXPLAYERS + 1];

int
	DL_g_iStartDoor,
	DL_g_iCountDown,
	DL_g_iRoundStart,
	DL_g_iPlayerSpawn,
	DL_g_iPrepareTime1r,
	DL_g_iPrepareTime2r,
	DL_g_iClientTimeOut,
	DL_g_iDisplayMode,
	DL_g_iDisplayPanel,
	DL_g_iTrace,
	DL_g_iTimeout[MAXPLAYERS + 1];

// ========================
//  阶段控制（原来通过 readyup_external native，现在直接走内部函数）
// ========================
void DL_BeginRoundLifecycle()
{
	DL_g_bLifecycleStarted = RU_ExternalPhaseBegin();
}

void DL_CompleteRoundLifecycle()
{
	DL_g_bRoundLive = true;
	if (DL_g_bLifecycleStarted)
		RU_ExternalPhaseLive();
	DL_g_bLifecycleStarted = false;
}

void DL_CancelRoundLifecycle()
{
	if (DL_g_bLifecycleStarted)
		RU_ExternalPhaseCancel();
	DL_g_bLifecycleStarted = false;
}

// 门锁准备模式是否启用：l4d_ready_enabled = 4（ReadyMode_DoorLock，合并后新增的模式）。
// 1/2/3 = ReadyUp 自己的准备模式；0 = 关闭。
bool DL_IsDoorLockReadyMode()
{
	return l4d_ready_enabled != null && l4d_ready_enabled.IntValue == ReadyMode_DoorLock;
}

// ========================
//  初始化 / 收尾
// ========================
void DL_OnPluginStart()
{
	CreateConVar("l4d2_dlock_version", DL_PLUGIN_VERSION, "门锁模块版本（已并入准备模式插件）", FCVAR_SPONLY|FCVAR_NOTIFY|FCVAR_REPLICATED);

	// 默认改为 0：合并后本插件被所有模式加载，只有显式开启的模式（12v12）才启用门锁流程
	DL_g_cAllow =		CreateConVar("l4d2_dlock_allow",		"0",	"0=门锁流程禁用, 1=门锁流程启用（准备模式由门锁接管）.", FCVAR_NOTIFY);
	DL_g_cModes =		CreateConVar("l4d2_dlock_modes",		"",		"在这些游戏模式中启用插件, 用英文逗号分割 (无空格),(无内容=全模式)", FCVAR_NOTIFY);
	DL_g_cModesOff =	CreateConVar("l4d2_dlock_modes_off",	"",		"在这些游戏模式中禁用插件, 用英文逗号分割 (无空格),(无内容=无)", FCVAR_NOTIFY);
	// 注意：这里的位值必须用 Left4DHooks 的 L4D_GetGameModeType() 口径（GAMEMODE_* 枚举）：
	// 1=战役(coop) 2=对抗(versus) 4=生存(survival) 8=清道夫(scavenge)。
	// 旧文案曾写成"4=对抗"，那是错的 —— 在对抗服写 4 会命中 4&2==0，门锁流程被静默禁用（本插件曾因此整场不跑）。
	DL_g_cModesTog =	CreateConVar("l4d2_dlock_modes_tog",	"0",	"在这些游戏模式中启用插件. 0=全模式, 1=战役coop, 2=对抗versus, 4=生存survival, 8=清道夫scavenge (对应 L4D_GetGameModeType() 的 GAMEMODE_* 位值). 多个模式则设置多个模式值的和", FCVAR_NOTIFY);
	DL_g_cBreakTheDoor =	CreateConVar("l4d2_dlock_weakdoor",		"1",	"如果为1，则安全屋的门开启后将会掉落.", FCVAR_NOTIFY);
	DL_g_cPrepareTime1r =	CreateConVar("l4d2_dlock_prepare1st",	"7",	"在所有玩家加载完毕后，插件将等待多少秒，然后开始在地图上进行第一轮游戏(适用于对抗类型的模式)", FCVAR_NOTIFY);
	DL_g_cPrepareTime2r =	CreateConVar("l4d2_dlock_prepare2nd",	"7",	"在所有玩家加载完毕后，插件将等待多少秒，然后开始在地图上进行第二轮游戏(适用于对抗类型的模式)", FCVAR_NOTIFY);
	DL_g_cClientTimeOut =	CreateConVar("l4d2_dlock_timeout",		"45",	"在地图开始后，插件会等待多少秒才会放弃等待连接中的玩家？", FCVAR_NOTIFY);
	DL_g_cDisplayMode =	CreateConVar("l4d2_dlock_displaymode",	"1",	"设置倒计时的显示模式。(0-隐藏,1-游戏提示,2-屏幕中心,3-聊天框.任何其他数值都可以隐藏倒计时)", FCVAR_NOTIFY);
	DL_g_cDisplayPanel =	CreateConVar("l4d2_dlock_displaypanel",	"2",	"玩家状态面板的显示模式,0-不显示，1-隐藏连接失败的玩家，2-完整显示", FCVAR_NOTIFY);
	DL_g_cFreezeNodoor =	CreateConVar("l4d2_dlock_freezenodoor",	"1",	"如果没有启动安全室的门，则冻结生还者", FCVAR_NOTIFY);
	DL_g_cTrace =		CreateConVar("l4d2_dlock_tracelog",		"1",	"诊断跟踪日志: 1=写入 logs/l4d2_dlock_trace.log (排查崩溃用, 每秒心跳+每次面板发送), 0=关闭", FCVAR_NOTIFY);

	DL_g_cSbStop =		FindConVar("sb_stop");
	DL_g_cNbStop =		FindConVar("nb_stop");
	DL_g_cGameMode =	FindConVar("mp_gamemode");
	if (DL_g_cGameMode != null)
		DL_g_cGameMode.AddChangeHook(DL_CvarChanged_Allow);
	DL_g_cModes.AddChangeHook(DL_CvarChanged_Allow);
	DL_g_cModesOff.AddChangeHook(DL_CvarChanged_Allow);
	DL_g_cModesTog.AddChangeHook(DL_CvarChanged_Allow);
	DL_g_cAllow.AddChangeHook(DL_CvarChanged_Allow);

	DL_g_cBreakTheDoor.AddChangeHook(DL_CvarChanged);
	DL_g_cPrepareTime1r.AddChangeHook(DL_CvarChanged);
	DL_g_cPrepareTime2r.AddChangeHook(DL_CvarChanged);
	DL_g_cClientTimeOut.AddChangeHook(DL_CvarChanged);
	DL_g_cDisplayMode.AddChangeHook(DL_CvarChanged);
	DL_g_cDisplayPanel.AddChangeHook(DL_CvarChanged);
	DL_g_cFreezeNodoor.AddChangeHook(DL_CvarChanged);
	DL_g_cTrace.AddChangeHook(DL_CvarChanged);
	// Observe round boundaries even while confogl has not committed the cvars.
	DL_HookEvents(true);
}

void DL_OnConfigsExecuted()
{
	DL_g_bConfigsReady = true;
	DL_IsAllowed();
}

void DL_OnPluginEnd()
{
	DL_ResetPlugin();
}

void DL_OnMapStart()
{
	DL_g_bMapStarted = true;
	DL_g_bFirstRound = true;
	DL_g_bConfigsReady = false;
	DL_g_bRoundEnded = false;
	DL_g_bRoundLive = false;
	DL_g_iCurrentMode = 0;

	PrecacheSound(DL_SOUND_BREAK1);
	PrecacheSound(DL_SOUND_BREAK2);
	PrecacheSound(DL_SOUND_MOVEOUT);
	PrecacheSound(DL_SOUND_COUNTDOWN);
}

void DL_OnMapEnd()
{
	DL_ResetPlugin();
	DL_g_bMapStarted = false;
	DL_g_bConfigsReady = false;
	DL_g_bCvarAllow = false;
}

void DL_OnClientDisconnect(int client)
{
	DL_Trace("disconnect: client=%d name-check skip", client);
	DL_g_iTimeout[client] = 0;
	DL_g_bIsLoading[client] = false;
	DL_g_iFrozenUserId[client] = 0;
	// Keep the old userid (never the slot identity) until the short release window
	// ends: bot_player_replace can arrive after the source bot disconnected.
}

void DL_CvarChanged_Allow(ConVar convar, const char[] oldValue, const char[] newValue)
{
	DL_IsAllowed();
}

void DL_CvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	DL_GetCvars();
}

void DL_GetCvars()
{
	bool last = DL_g_bBreakTheDoor;

	DL_g_bBreakTheDoor =	DL_g_cBreakTheDoor.BoolValue;
	DL_g_iPrepareTime1r =	DL_g_cPrepareTime1r.IntValue;
	DL_g_iPrepareTime2r =	DL_g_cPrepareTime2r.IntValue;
	DL_g_iClientTimeOut =	DL_g_cClientTimeOut.IntValue;
	DL_g_iDisplayMode =		DL_g_cDisplayMode.IntValue;
	DL_g_iDisplayPanel =	DL_g_cDisplayPanel.IntValue;
	DL_g_bFreezeNodoor =	DL_g_cFreezeNodoor.BoolValue;
	DL_g_iTrace =		DL_g_cTrace.IntValue;

	if (last != DL_g_bBreakTheDoor)
	{
		if (DL_g_iStartDoor && EntRefToEntIndex(DL_g_iStartDoor) != -1)
			UnhookSingleEntityOutput(DL_g_iStartDoor, "OnOpen", DL_OnOpen);
	}
}

//Silvers
void DL_IsAllowed()
{
	bool bCvarAllow = DL_g_cAllow.BoolValue && DL_IsDoorLockReadyMode();
	bool bAllowMode = DL_IsAllowedGameMode();
	DL_GetCvars();

	if (DL_g_bCvarAllow == false && bCvarAllow == true && bAllowMode == true)
	{
		DL_g_bCvarAllow = true;
	}
	else if (DL_g_bCvarAllow == true && (bCvarAllow == false || bAllowMode == false))
	{
		DL_g_bCvarAllow = false;
		DL_ResetPlugin();
	}
	DL_ScheduleRecovery();
}

void DL_L4D_OnGameModeChange(int gamemode)
{
	DL_g_iCurrentMode = gamemode;
	DL_IsAllowed();
}

bool DL_IsAllowedGameMode()
{
	if (!DL_g_cGameMode)
		return false;

	if (!DL_g_bMapStarted)
		return false;
	// Query after mp_gamemode changes instead of trusting the old mode cache.
	DL_g_iCurrentMode = L4D_GetGameModeType();

	int iCvarModesTog = DL_g_cModesTog.IntValue;
	if (iCvarModesTog && !(iCvarModesTog & DL_g_iCurrentMode))
		return false;

	char sGameModes[64], sGameMode[64];
	DL_g_cGameMode.GetString(sGameMode, sizeof sGameMode);
	Format(sGameMode, sizeof sGameMode, ",%s,", sGameMode);

	DL_g_cModes.GetString(sGameModes, sizeof sGameModes);
	if (sGameModes[0])
	{
		Format(sGameModes, sizeof sGameModes, ",%s,", sGameModes);
		if (StrContains(sGameModes, sGameMode, false) == -1)
			return false;
	}

	DL_g_cModesOff.GetString(sGameModes, sizeof sGameModes);
	if (sGameModes[0])
	{
		Format(sGameModes, sizeof sGameModes, ",%s,", sGameModes);
		if (StrContains(sGameModes, sGameMode, false) != -1)
			return false;
	}

	return true;
}

void DL_HookEvents(bool hook)
{
	if (hook)
	{
		HookEvent("round_end",		DL_Event_RoundEnd,		EventHookMode_PostNoCopy);
		HookEvent("round_start",	DL_Event_RoundStart,	EventHookMode_PostNoCopy);
		HookEvent("player_spawn",	DL_Event_PlayerSpawn);
		HookEvent("player_team",	DL_Event_PlayerTeam);
		HookEvent("player_bot_replace", DL_Event_PlayerReplace);
		HookEvent("bot_player_replace", DL_Event_PlayerReplace);
	}
	else
	{
		UnhookEvent("round_end",	DL_Event_RoundEnd,		EventHookMode_PostNoCopy);
		UnhookEvent("round_start",	DL_Event_RoundStart,	EventHookMode_PostNoCopy);
		UnhookEvent("player_spawn",	DL_Event_PlayerSpawn);
		UnhookEvent("player_team",	DL_Event_PlayerTeam);
		UnhookEvent("player_bot_replace", DL_Event_PlayerReplace);
		UnhookEvent("bot_player_replace", DL_Event_PlayerReplace);
	}
}

void DL_OnPlayerRunCmd(int client)
{
	if (client <= 0 || client > MaxClients) return;
	if (!DL_g_bFreezeAllowed && !DL_g_hUnfreezeTimer && !DL_g_iFrozenUserId[client]) return;
	DL_UpdateClientFreeze(client);
}

bool DL_IsPlayerFreezeActive()
{
	return DL_g_hTimer != null && DL_g_bFreezeAllowed;
}

bool DL_WasFrozenUserId(int userid)
{
	if (userid <= 0) return false;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (DL_g_iFrozenUserId[i] == userid
			|| (DL_g_fReleaseUntil > GetGameTime() && DL_g_iReleasedUserId[i] == userid))
			return true;
	}
	return false;
}

void DL_ReleaseClientFreeze(int client)
{
	if (!IsClientInGame(client)) return;
	int userid = GetClientUserId(client);
	if (DL_g_iFrozenUserId[client] != userid
		&& !(DL_g_fReleaseUntil > GetGameTime() && DL_g_iReleasedUserId[client] == userid)) return;
	if (GetEntityMoveType(client) == MOVETYPE_NONE)
		SetEntityMoveType(client, GetClientTeam(client) == 1 ? MOVETYPE_NOCLIP : MOVETYPE_WALK);
	if (DL_g_fReleaseUntil > GetGameTime()) DL_g_iReleasedUserId[client] = userid;
	DL_g_iFrozenUserId[client] = 0;
}

void DL_UpdateClientFreeze(int client)
{
	if (client <= 0 || client > MaxClients || !IsClientInGame(client)) return;
	if (DL_IsPlayerFreezeActive() && GetClientTeam(client) == 2 && IsPlayerAlive(client)
		&& GetEntityMoveType(client) != MOVETYPE_NOCLIP)
	{
		// Own immobilization throughout this preparation, including already-NONE
		// survivors and bot replacements. Input commands are not guaranteed to run.
		DL_g_iFrozenUserId[client] = GetClientUserId(client);
		if (GetEntityMoveType(client) != MOVETYPE_NONE)
			SetEntityMoveType(client, MOVETYPE_NONE);
	}
	else DL_ReleaseClientFreeze(client);
}

void DL_UpdatePlayerFreezes()
{
	for (int i = 1; i <= MaxClients; i++) DL_UpdateClientFreeze(i);
}

void DL_QueueFreezeCheck(int client, bool release)
{
	if (client <= 0 || client > MaxClients || !IsClientInGame(client)) return;
	DataPack pack = new DataPack();
	pack.WriteCell(GetClientUserId(client));
	pack.WriteCell(DL_g_iFreezeSerial);
	pack.WriteCell(release);
	RequestFrame(DL_FrameFreezeCheck, pack);
}

void DL_FrameFreezeCheck(DataPack pack)
{
	pack.Reset();
	int userid = pack.ReadCell();
	int serial = pack.ReadCell();
	bool release = pack.ReadCell() != 0;
	delete pack;
	if (serial != DL_g_iFreezeSerial) return;
	int client = GetClientOfUserId(userid);
	if (!client || !IsClientInGame(client)) return;
	if (!DL_IsPlayerFreezeActive() && release && DL_g_fReleaseUntil > GetGameTime())
		DL_g_iReleasedUserId[client] = userid;
	DL_UpdateClientFreeze(client);
}

void DL_Event_PlayerReplace(Event event, const char[] name, bool dontBroadcast)
{
	bool playerTakingOver = StrEqual(name, "bot_player_replace");
	int sourceUserid = event.GetInt(playerTakingOver ? "bot" : "player");
	int targetUserid = event.GetInt(playerTakingOver ? "player" : "bot");
	bool inherited = DL_WasFrozenUserId(sourceUserid);
	int source = GetClientOfUserId(sourceUserid);
	int target = GetClientOfUserId(targetUserid);
	// These events are also used by infected/tank replacements.
	bool freezing = DL_IsPlayerFreezeActive()
		&& ((source && IsClientInGame(source) && GetClientTeam(source) == 2)
			|| (target && IsClientInGame(target) && GetClientTeam(target) == 2));
	if (target && IsClientInGame(target) && (freezing || inherited || DL_WasFrozenUserId(targetUserid)))
	{
		if (inherited) DL_g_iFrozenUserId[target] = targetUserid;
		// The receiving human may still be on team 0/1 inside TakeOverBot.
		// Let the next-frame callback observe the final team before changing it.
		if (GetClientTeam(target) == 2) DL_UpdateClientFreeze(target);
		DL_QueueFreezeCheck(target, true);
	}
	if (source && IsClientInGame(source) && GetClientTeam(source) != 2)
		DL_ReleaseClientFreeze(source);
}

Action DL_tmrUnfreeze(Handle timer)
{
	if (timer != DL_g_hUnfreezeTimer) return Plugin_Stop;
	if (GetGameTime() >= DL_g_fReleaseUntil)
	{
		DL_g_hUnfreezeTimer = null;
		DL_g_fReleaseUntil = 0.0;
		for (int i = 1; i <= MaxClients; i++) DL_g_iReleasedUserId[i] = 0;
		return Plugin_Stop;
	}
	// Recheck only this preparation's userids, never new occupants of their slots.
	for (int i = 1; i <= MaxClients; i++) DL_ReleaseClientFreeze(i);
	return Plugin_Continue;
}

void DL_Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	DL_ResetPlugin();
	DL_g_bRoundEnded = true;
	DL_g_bFirstRound = false;
}

void DL_Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	DL_ResetPlugin();
	DL_g_bRoundEnded = false;
	DL_g_bRoundLive = false;
	DL_g_iRoundStart = 1;
	DL_IsAllowed();
}

void DL_Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	DL_g_iPlayerSpawn = 1;
	DL_ScheduleRecovery();
	if (event != null)
	{
		int client = GetClientOfUserId(event.GetInt("userid"));
		if (client && IsClientInGame(client)
			&& ((DL_IsPlayerFreezeActive() && GetClientTeam(client) == 2) || DL_WasFrozenUserId(event.GetInt("userid"))))
		{
			DL_UpdateClientFreeze(client);
			DL_QueueFreezeCheck(client, true);
		}
	}
}

void DL_ResetPlugin()
{
	delete DL_g_hRecoveryTimer;
	// Release the owned door/timer before forgetting their references.
	DL_UnLockDoor();
	if (DL_g_iStartDoor && EntRefToEntIndex(DL_g_iStartDoor) != -1)
		UnhookSingleEntityOutput(DL_g_iStartDoor, "OnOpen", DL_OnOpen);
	DL_DeleteTimer();
	DL_g_iCountDown = 0;
	DL_g_iStartDoor = 0;
	DL_g_iRoundStart = 0;
	DL_g_iPlayerSpawn = 0;
	DL_g_bFreezeAllowed = false;
}

bool DL_HasConfirmedHuman()
{
	for (int client = 1; client <= MaxClients; client++)
		if (IsClientInGame(client) && !IsFakeClient(client) && !IsClientInKickQueue(client) && IsClientAuthorized(client))
			return true;
	return false;
}

bool DL_HasLivingSurvivor()
{
	for (int client = 1; client <= MaxClients; client++)
		if (IsClientInGame(client) && !IsClientInKickQueue(client) && GetClientTeam(client) == 2 && IsPlayerAlive(client))
			return true;
	return false;
}

void DL_ScheduleRecovery()
{
	if (!DL_g_bMapStarted || !DL_g_bConfigsReady || !DL_g_bCvarAllow || DL_g_bRoundEnded || DL_g_bRoundLive || DL_g_hTimer || DL_g_hRecoveryTimer)
		return;
	DL_g_hRecoveryTimer = CreateTimer(0.5, DL_tmrRecover, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

Action DL_tmrRecover(Handle timer)
{
	if (timer != DL_g_hRecoveryTimer) return Plugin_Stop;
	if (!DL_g_bMapStarted || !DL_g_bCvarAllow || DL_g_bRoundEnded || DL_g_bRoundLive || DL_g_hTimer)
	{
		DL_g_hRecoveryTimer = null;
		return Plugin_Stop;
	}
	if (!DL_HasConfirmedHuman() || !DL_HasLivingSurvivor()) return Plugin_Continue;
	// A late reload must not freeze players who have already left the start area.
	if (L4D_HasAnySurvivorLeftSafeArea())
	{
		DL_g_bRoundLive = true;
		DL_g_hRecoveryTimer = null;
		return Plugin_Stop;
	}
	DL_g_hRecoveryTimer = null;
	DL_InitPlugin();
	return Plugin_Stop;
}

void DL_DeleteTimer()
{
	DL_CancelRoundLifecycle();
	delete DL_g_hUnfreezeTimer;
	DL_g_iFreezeSerial++;
	delete DL_g_hTimer;
	DL_UnFreezePlayers();
	DL_g_fReleaseUntil = 0.0;
	for (int i = 1; i <= MaxClients; i++) DL_g_iReleasedUserId[i] = 0;
	DL_UnFreezeSurBots();
}

void DL_Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client && IsClientInGame(client))
	{
		if (DL_g_iCountDown && !IsFakeClient(client)) DL_ResetLoadingState(client);
		if ((DL_IsPlayerFreezeActive() && event.GetInt("team") == 2) || DL_WasFrozenUserId(event.GetInt("userid")))
		{
			DL_UpdateClientFreeze(client);
			DL_QueueFreezeCheck(client, true);
		}
	}
}

void DL_ResetLoadingState(int client, bool state = false)
{
	DL_g_iTimeout[client] = 0;
	DL_g_bIsLoading[client] = state;
}

void DL_StartSequence()
{
	DL_DeleteTimer();

	for (int i = 1; i <= MaxClients; i++)
		DL_ResetLoadingState(i, true);

	if (DL_g_iStartDoor && EntRefToEntIndex(DL_g_iStartDoor) != -1)
	{
		DL_g_iCountDown = -1;
		DL_LockDoor();
		DL_FreezeSurBots();
		DL_g_hTimer = CreateTimer(1.0, DL_tmrLoading, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
		DL_BeginRoundLifecycle();
	}
	else if (DL_g_bFreezeNodoor)
	{
		DL_g_iCountDown = -1;
		DL_g_bFreezeAllowed = true;
		if (DL_g_cNbStop != null)
		{
			DL_g_iSavedNbStop = DL_g_cNbStop.IntValue;
			DL_g_bOwnNbStop = true;
			DL_g_cNbStop.SetInt(1);
		}
		DL_g_hTimer = CreateTimer(1.0, DL_tmrLoading, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
		DL_UpdatePlayerFreezes();
		DL_BeginRoundLifecycle();
	}
	else
	{
		// Let the other round_start handlers (including cosmetic setup) settle.
		// No gameplay freeze is applied on maps opting out of the no-door lock.
		DL_g_hTimer = CreateTimer(0.6, DL_tmrImmediateLive, _, TIMER_FLAG_NO_MAPCHANGE);
		DL_BeginRoundLifecycle();
	}
}

Action DL_tmrImmediateLive(Handle timer)
{
	if (timer != DL_g_hTimer) return Plugin_Stop;
	DL_g_hTimer = null;
	DL_CompleteRoundLifecycle();
	return Plugin_Stop;
}

Action DL_tmrLoading(Handle timer)
{
	if (timer != DL_g_hTimer) return Plugin_Stop;
	DL_Trace("tmr tick: countdown=%d panel=%d firstRound=%d", DL_g_iCountDown, DL_g_iDisplayPanel, DL_g_bFirstRound);
	if (DL_IsPlayerFreezeActive()) DL_UpdatePlayerFreezes();
	// The multiplayer plugin intentionally removes bots on empty servers.
	// Never consume the preparation period before a human has actually joined.
	if (!DL_HasConfirmedHuman() || !DL_HasLivingSurvivor())
	{
		DL_g_iCountDown = -1;
		return Plugin_Continue;
	}
	if (DL_g_iCountDown >= 0)
	{
		if (DL_g_iCountDown >= (DL_g_bFirstRound ? DL_g_iPrepareTime1r : DL_g_iPrepareTime2r))
		{
			DL_g_iCountDown = 0;

			DL_g_hTimer = null; // forwards may synchronously cancel/restart the phase
			if (DL_g_bFreezeAllowed) DL_g_fReleaseUntil = GetGameTime() + 1.0;
			DL_UnFreezePlayers();
			if (DL_g_fReleaseUntil > GetGameTime())
				DL_g_hUnfreezeTimer = CreateTimer(0.1, DL_tmrUnfreeze, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
			DL_UnFreezeSurBots();
			DL_UnLockDoor();
			DL_CompleteRoundLifecycle();

			DL_PlaySound(DL_SOUND_MOVEOUT);
			DL_PrintTextAll("%s", DL_TXT_MOVEOUT);

			return Plugin_Stop;
		}
		else
		{
			DL_PlaySound(DL_SOUND_COUNTDOWN);

			if (!DL_g_bFreezeAllowed)
				DL_PrintTextAll(DL_TXT_LOCKED, (DL_g_bFirstRound ? DL_g_iPrepareTime1r : DL_g_iPrepareTime2r) - DL_g_iCountDown);
			else
				DL_PrintTextAll(DL_TXT_FROZEN, (DL_g_bFirstRound ? DL_g_iPrepareTime1r : DL_g_iPrepareTime2r) - DL_g_iCountDown);

			DL_g_iCountDown++;
		}
	}
	else
		DL_g_iCountDown = DL_IsFinishedLoading() ? 0 : -1;

	// 加载状态面板：任何回合（含对抗第二回合 / 下半场）都要显示。
	// 旧版只在 g_bFirstRound 为真的回合里画，而对抗第二回合 g_bFirstRound 已经是 false
	// ⇒ 整段准备期一个面板都不发（用户反馈的「第二回合没显示」）。
	// 现在只要 displaypanel > 0，等加载阶段和倒计时阶段都发，回合序号不参与判断。
	if (DL_g_iDisplayPanel > 0)
		DL_LoadingPanel();

	return Plugin_Continue;
}

// 诊断跟踪：独立文件 + 立即 flush，崩溃后能读到"最后一步"。
// 不需要跟踪时把 l4d2_dlock_tracelog 设 0（几乎零开销）。
void DL_Trace(const char[] fmt, any ...)
{
	if (DL_g_iTrace <= 0)
		return;

	char buf[512];
	VFormat(buf, sizeof(buf), fmt, 2);
	LogToFileEx(DL_TRACE_FILE, "[%9.3f] %s", GetGameTime(), buf);
}

void DL_LoadingPanel()
{
	// 面板按 4 类分栏：连接中 / 生还者 / 感染者 / 旁观者，每栏标题带该类人数。
	// 只统计真人（排除 bot），与 readyup 主面板 panel.inc 的 UpdatePanel() 口径一致。
	// 归类口径见文件头 DL_PANEL_GROUP_* 处的注释。
	int clients[MAXPLAYERS + 1], groups[MAXPLAYERS + 1], count = 0;
	bool timedOut[MAXPLAYERS + 1];
	int totals[DL_PANEL_GROUP_COUNT] = {0};
	char name[128], text[192], headings[DL_PANEL_GROUP_COUNT][64];
	// 显式初始化：这三个是累加量，绝不能依赖「局部变量自动清零」这种实现细节。
	int fullBytes = 0, headingBytes = 0, tagBytes = 0;

	for (int group = 0; group < DL_PANEL_GROUP_COUNT; group++)
	{
		for (int client = 1; client <= MaxClients; client++)
		{
			if (!IsClientConnected(client) || IsFakeClient(client)) continue;

			bool isTimedOut;
			if (group == DL_PANEL_GROUP_CONNECTING)
			{
				if (IsClientInGame(client)) continue;
				// 加载超时的玩家本质上仍是「还没进游戏」，所以留在连接中一栏，行尾补 [超时] 标记。
				// l4d2_dlock_displaypanel=1（隐藏连接失败的玩家）时整条既不显示也不计数，保留原参数语义。
				// 与 DL_IsFinishedLoading() 里的判定条件保持完全一致（那里也是 timeout >= cvar 就放弃等待），
				// 否则面板显示的「是否超时」会和插件实际是否继续等脱节。
				isTimedOut = DL_g_iTimeout[client] >= DL_g_iClientTimeOut;
				if (isTimedOut && DL_g_iDisplayPanel < 2) continue;
			}
			else
			{
				if (!IsClientInGame(client)) continue;
				int team = GetClientTeam(client);
				if (group == DL_PANEL_GROUP_SURVIVOR)
				{
					if (team != L4D2Team_Survivor) continue;
				}
				else if (group == DL_PANEL_GROUP_INFECTED)
				{
					if (team != L4D2Team_Infected) continue;
				}
				else if (team == L4D2Team_Survivor || team == L4D2Team_Infected) continue; // 旁观/未分队
				isTimedOut = false;
			}

			clients[count] = client;
			groups[count] = group;
			timedOut[count++] = isTimedOut;
			totals[group]++;
			RU_GetPanelName(client, name, sizeof(name));
			FormatEx(text, sizeof(text), "->%d. %s%s", totals[group], name, isTimedOut ? DL_TXT_MENU_TIMEOUT_TAG : "");
			fullBytes += strlen(text) + 1; // +1 = 换行
			if (isTimedOut) tagBytes += strlen(DL_TXT_MENU_TIMEOUT_TAG);
		}
	}

	// 解说 caster 仍然算进旁观者人数（与 panel.inc 的「旁观:%d 解说:%d」口径一致），
	// 额外在旁观栏标题里报告解说人数，避免解说被当成普通观众。
	// caster_system 未加载时不调用其 native，否则会 "Native is not bound"。
	int casters = 0;
	if (casterSystemAvailable)
	{
		for (int client = 1; client <= MaxClients; client++)
		{
			if (!IsClientInGame(client) || IsFakeClient(client)) continue;
			int team = GetClientTeam(client);
			if (team == L4D2Team_Survivor || team == L4D2Team_Infected) continue;
			if (IsClientCaster(client)) casters++;
		}
	}

	Panel panel = new Panel();
	RU_DrawPanelText(panel, DL_TXT_MENU_HEADER);

	for (int group = 0; group < DL_PANEL_GROUP_COUNT; group++)
	{
		if (!totals[group]) continue;
		if (group == DL_PANEL_GROUP_CONNECTING)
			FormatEx(headings[group], sizeof(headings[]), "%s (%d)", DL_TXT_MENU_CONNECTING, totals[group]);
		else if (group == DL_PANEL_GROUP_SURVIVOR)
			FormatEx(headings[group], sizeof(headings[]), "%s (%d)", DL_TXT_MENU_SURVIVOR, totals[group]);
		else if (group == DL_PANEL_GROUP_INFECTED)
			FormatEx(headings[group], sizeof(headings[]), "%s (%d)", DL_TXT_MENU_INFECTED, totals[group]);
		else if (casters > 0)
			FormatEx(headings[group], sizeof(headings[]), DL_TXT_MENU_CASTER_FMT, DL_TXT_MENU_SPECTATOR, totals[group], casters);
		else
			FormatEx(headings[group], sizeof(headings[]), "%s (%d)", DL_TXT_MENU_SPECTATOR, totals[group]);
		headingBytes += strlen(headings[group]) + 1;
	}

	int available = panel.TextRemaining - headingBytes;
	int visible = count, nameBudget = 127;
	if (fullBytes > available && count)
	{
		// 缩略提示要同时说明名字截断与 [超时] 标记，否则玩家看不懂行尾标记。
		char note[64];
		if (tagBytes) FormatEx(note, sizeof(note), "~缩名 [超时]表示加载超时");
		else FormatEx(note, sizeof(note), "~表示名字缩略");
		available -= strlen(note) + 1;
		// 每行真实开销 = "->NN. "(7) + 名字 + [超时] + 换行(1)，故减 8。
		nameBudget = (available - tagBytes) / count - 8;
		if (nameBudget < 5)
		{
			// 连 5 字节的名字都放不下：只保留能塞下的行，剩余玩家和分组标题在末尾汇总。
			available -= 40; // 「另 N 名玩家未展开」最长情形 + 换行
			nameBudget = 5;
			visible = 0;
			int used = 0;
			for (int i = 0; i < count; i++)
			{
				int lineCost = 8 + nameBudget + (timedOut[i] ? strlen(DL_TXT_MENU_TIMEOUT_TAG) : 0);
				if (used + lineCost > available) break;
				used += lineCost;
				visible++;
			}
		}
		RU_DrawPanelText(panel, note);
	}

	int lastGroup = -1, ordinal = 0;
	for (int i = 0; i < visible; i++)
	{
		if (groups[i] != lastGroup)
		{
			lastGroup = groups[i];
			ordinal = 0;
			RU_DrawPanelText(panel, headings[lastGroup]);
		}
		RU_GetPanelName(clients[i], name, sizeof(name));
		char shortName[128];
		RU_CopyPanelText(name, shortName, sizeof(shortName), nameBudget);
		FormatEx(text, sizeof(text), "->%d. %s%s", ++ordinal, shortName, timedOut[i] ? DL_TXT_MENU_TIMEOUT_TAG : "");
		RU_DrawPanelText(panel, text);
	}
	if (visible < count)
	{
		// 未展开的行按分类计数：把被截断分类的标题补出来（标题已在 headingBytes 里预留过字节）。
		// visible==0 时 lastGroup 仍是 -1，这里会把 4 个分类标题全部补出 —— 正是期望行为：
		// 名字一个都放不下时，至少保住「每栏人数」这个核心信息。
		for (int group = lastGroup + 1; group < DL_PANEL_GROUP_COUNT; group++)
			if (totals[group]) RU_DrawPanelText(panel, headings[group]);
		FormatEx(text, sizeof(text), "另%d名玩家未展开", count - visible);
		RU_DrawPanelText(panel, text);
	}
	DL_Trace("panel: begin count=%d", count);
	for (int client = 1; client <= MaxClients; client++)
	{
		// 显示时长 2 秒：面板每秒重发一次，2 秒足够无缝衔接；而准备阶段结束时
		// 最后一次发送后最多 2 秒就自动消失，不会挡着开局的准星。
		bool canSend = DL_CanSendPanel(client);
		if (canSend)
		{
			int rc = panel.Send(client, DL_PanelHandler, 2);
			DL_Trace("panel: send client=%d rc=%d", client, rc);
		}
	}
	delete panel;
	DL_Trace("panel: deleted");
}

// 会不会「抢掉」玩家正在用的投票面板。
// 面板现在每秒重发一次、且贯穿整段准备期，所以必须先避开投票，否则会把投票 UI 关掉。
// 这里刻意**不**用 GetClientMenu 过滤：Panel 本身就是菜单，加了会把自己的面板判成
// 「客户端正在看菜单」而永久跳过重发，人数就不再刷新（原始 doorlock 也没有这层判断）。
bool DL_CanSendPanel(int client)
{
	if (!IsClientInGame(client) || IsFakeClient(client))
		return false;

	// 玩家用 !hide 隐藏了准备面板，就一并尊重：他显式要求「别挡着别的菜单」。
	// （同一个标记位由 readyup 侧的 !hide / !show 维护，见 command.inc:137/147）
	if (IsPlayerHiddenPanel(client))
		return false;

	if (BuiltinVote_IsVoteInProgress() && IsClientInBuiltinVotePool(client))
		return false;

	if (Game_IsVoteInProgress())
	{
		int voteteam = Game_GetVoteTeam();
		if (voteteam == -1 || voteteam == GetClientTeam(client))
			return false;
	}

	return true;
}

int DL_PanelHandler(Menu menu, MenuAction action, int param1, int param2)
{
	return 0;
}

void DL_LockDoor()
{
	DL_Trace("LockDoor: ref=%d idx=%d", DL_g_iStartDoor, DL_g_iStartDoor ? EntRefToEntIndex(DL_g_iStartDoor) : 0);
	if (DL_g_iStartDoor && EntRefToEntIndex(DL_g_iStartDoor) != -1)
		SetEntProp(DL_g_iStartDoor, Prop_Send, "m_spawnflags", DOOR_FLAG_SILENT|DOOR_FLAG_IGNORE_USE);
}

void DL_UnLockDoor()
{
	if (DL_g_iStartDoor && EntRefToEntIndex(DL_g_iStartDoor) != -1)
		SetEntProp(DL_g_iStartDoor, Prop_Send, "m_spawnflags", DOOR_FLAG_USE_CLOSES);
}

void DL_FreezeSurBots()
{
	if (DL_g_cSbStop != null)
	{
		DL_g_iSavedSbStop = DL_g_cSbStop.IntValue;
		DL_g_bOwnSbStop = true;
		DL_g_cSbStop.SetInt(1);
	}
}

void DL_UnFreezeSurBots()
{
	if (DL_g_bOwnSbStop && DL_g_cSbStop != null && DL_g_cSbStop.IntValue == 1)
		DL_g_cSbStop.SetInt(DL_g_iSavedSbStop);
	DL_g_bOwnSbStop = false;
}

void DL_UnFreezePlayers()
{
	// Catch survivors who appeared/froze without ever producing a user command.
	// A normal locked-door phase never adopts unrelated freezes.
	if (DL_g_bFreezeAllowed)
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsClientInGame(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i)
				&& GetEntityMoveType(i) == MOVETYPE_NONE)
				DL_g_iFrozenUserId[i] = GetClientUserId(i);
		}
	}
	// Disable the writer before restoring movement or firing cvar callbacks.
	DL_g_bFreezeAllowed = false;
	for (int i = 1; i <= MaxClients; i++)
	{
		DL_ReleaseClientFreeze(i);
		DL_g_iFrozenUserId[i] = 0;
	}

	if (DL_g_bOwnNbStop && DL_g_cNbStop != null && DL_g_cNbStop.IntValue == 1)
		DL_g_cNbStop.SetInt(DL_g_iSavedNbStop);
	DL_g_bOwnNbStop = false;
}

void DL_InitPlugin()
{
	// 只有门锁准备模式（l4d_ready_enabled = 4）才由门锁接管开局；
	// 1/2/3 交给 ReadyUp 自己的准备流程，0 表示两者都不跑。
	if (!DL_g_bCvarAllow || !DL_IsDoorLockReadyMode() || DL_g_bRoundEnded || DL_g_bRoundLive || DL_g_hTimer)
		return;
	if (DL_g_iCurrentMode == GAMEMODE_VERSUS)
		DL_g_bFirstRound = !GameRules_GetProp("m_bInSecondHalfOfRound");

	DL_g_iStartDoor = 0;
	int ent = L4D_GetCheckpointFirst();
	// A closed checkpoint can already be engine-unlocked on a late load.
	if (ent > MaxClients && IsValidEntity(ent) && HasEntProp(ent, Prop_Send, "m_eDoorState") && GetEntProp(ent, Prop_Send, "m_eDoorState") == 0)
	{
		DL_g_iStartDoor = EntIndexToEntRef(ent);
		if (!DL_g_bBreakTheDoor)
		{
			SetVariantString("OnOpen !self:Lock::0.0:-1");
			AcceptEntityInput(ent, "AddOutput");
		}
		else
			HookSingleEntityOutput(ent, "OnOpen", DL_OnOpen);
	}

	DL_StartSequence();
	// 日志里带上回合序号与面板开关：万一「第二回合没显示」再复发，看这一行就能立刻区分
	// 是「流程没启动」还是「面板被条件挡住」。
	LogMessage("[ReadyUp] DoorLock started: door=%d round_events=%d/%d first_round=%d half=%d displaypanel=%d",
		EntRefToEntIndex(DL_g_iStartDoor), DL_g_iRoundStart, DL_g_iPlayerSpawn,
		DL_g_bFirstRound, GameRules_GetProp("m_bInSecondHalfOfRound"), DL_g_iDisplayPanel);
}

//https://forums.alliedmods.net/showthread.php?p=2700212
void DL_OnOpen(const char[] output, int entity, int activator, float delay)
{
	if (entity <= MaxClients || !IsValidEntity(entity)) return;
	char sModel[PLATFORM_MAX_PATH];
	GetEntPropString(entity, Prop_Data, "m_ModelName", sModel, sizeof sModel);
	if (!sModel[0] || !IsModelPrecached(sModel))
	{
		LogError("[ReadyUp] Skipping physics door: model is not precached (%s)", sModel);
		return;
	}
	// Do not hide the working door until its replacement has actually spawned.
	int ent = CreateEntityByName("prop_physics");
	if (ent == -1)
	{
		LogError("[ReadyUp] Could not create physics door (entity limit)");
		return;
	}
	DispatchKeyValue(ent, "spawnflags", "4");
	DispatchKeyValue(ent, "model", sModel);
	if (!DispatchSpawn(ent))
	{
		RemoveEntity(ent);
		return;
	}

	float vPos[3], vAng[3], vDir[3];
	GetEntPropVector(entity, Prop_Data, "m_vecAbsOrigin", vPos);
	GetEntPropVector(entity, Prop_Send, "m_angRotation", vAng);

	// Make old door non-solid, so physics door does not collide and stutter
	// Collison group fixes "in solid list (not solid)"
	SetEntProp(entity, Prop_Send, "m_CollisionGroup", 1);
	SetEntProp(entity, Prop_Data, "m_CollisionGroup", 1);

	// Teleport up to prevent using and door shadow showing. Must stay alive or L4D1 crashes.
	vPos[2] += 10000.0;
	TeleportEntity(entity, vPos, NULL_VECTOR, NULL_VECTOR);
	vPos[2] -= 10000.0;

	// Hide old door
	SetEntityRenderMode(entity, RENDER_TRANSALPHA);
	SetEntityRenderColor(entity, 0, 0, 0, 0);

	UnhookSingleEntityOutput(entity, "OnOpen", DL_OnOpen);

	// Teleport to current door, ready to take it's attachments
	TeleportEntity(ent, vPos, vAng, NULL_VECTOR);

	// Handle fall animation from old door
	SetVariantString("unlock");
	AcceptEntityInput(entity, "SetAnimation");

	SetEntProp(entity, Prop_Send, "m_eDoorState", DOOR_STATE_CLOSING_IN_PROGRESS);
	SetEntProp(entity, Prop_Send, "m_spawnflags", DOOR_FLAG_SILENT|DOOR_FLAG_IGNORE_USE); // Prevent +USE + Door silent

	// Find attachments, swap to our new door
	entity = EntRefToEntIndex(entity);
	for (int att; att < 2048; att++)
	{
		if (IsValidEdict(att))
		{
			if (HasEntProp(att, Prop_Send, "moveparent") && GetEntPropEnt(att, Prop_Send, "moveparent") == entity)
			{
				SetVariantString("!activator");
				AcceptEntityInput(att, "SetParent", ent);
			}
		}
	}

	float dist = strcmp(sModel, "models/props_doors/checkpoint_door_-01.mdl") == 0 ? -10.0 : 10.0;

	// Tilt ang away
	GetAngleVectors(vAng, vDir, NULL_VECTOR, NULL_VECTOR);
	vPos[0] += (vDir[0] * dist);
	vPos[1] += (vDir[1] * dist);
	vAng[0] = dist;
	vDir[0] = 0.0;
	vDir[1] = vAng[1] < 270.0 ? 10.0 : -10.0 * dist;
	vDir[2] = 0.0;

	TeleportEntity(ent, vPos, vAng, vDir);

	EmitSoundToAll(GetRandomInt(0, 1) ? DL_SOUND_BREAK1 : DL_SOUND_BREAK2, ent);
}

bool DL_IsFinishedLoading()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i))
		{
			if (!IsClientInGame(i) && !IsFakeClient(i))
			{
				DL_g_iTimeout[i]++;
				if (DL_g_iTimeout[i] == 1)
					DL_g_bIsLoading[i] = true;

				if (DL_g_iTimeout[i] >= DL_g_iClientTimeOut)
					DL_g_bIsLoading[i] = false;
			}
			else
				DL_g_bIsLoading[i] = false;
		}
		else
			DL_g_bIsLoading[i] = false;
	}

	// 注意：面板不在这里画。旧版把 DL_LoadingPanel() 放在这里并附加「仅第一回合」条件，
	// 结果对抗第二回合整段都不显示面板。现在统一由 DL_tmrLoading 每 tick 调用，
	// 覆盖「等加载」+「锁门倒计时」整段准备期，且不再和回合序号绑定。

	return !DL_IsAnyClientLoading();
}

bool DL_IsAnyClientLoading()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (DL_g_bIsLoading[i])
			return true;
	}
	return false;
}

void DL_PrintTextAll(const char[] format, any ...)
{
	char buffer[254];
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
		{
			VFormat(buffer, sizeof buffer, format, 2);
			switch (DL_g_iDisplayMode)
			{
				case 1:
					PrintHintText(i, "%s", buffer);
				case 2:
					PrintCenterText(i, "%s", buffer);
				case 3:
					PrintToChat(i, "%s", buffer);
			}
		}
	}
}

void DL_PlaySound(const char[] sample)
{
	EmitSoundToAll(sample, SOUND_FROM_PLAYER, SNDCHAN_STATIC, SNDLEVEL_NORMAL, SND_NOFLAGS, SNDVOL_NORMAL, SNDPITCH_NORMAL, -1, NULL_VECTOR, NULL_VECTOR, true, 0.0);
}
