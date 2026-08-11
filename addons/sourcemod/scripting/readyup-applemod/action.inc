#if defined _readyup_action_included
 #endinput
#endif
#define _readyup_action_included

static int
	s_readyDelay,
	s_autoStartDelay,
	s_expireTime;

static Handle
	s_readyCountdownTimer,
	s_autoStartTimer;

void InitiateReadyUp(bool real = true)
{
	if (real)
	{
		readyUpMode = l4d_ready_enabled.IntValue;
		if (!readyUpMode) return;
		
		UTIL_WrapperForward(g_hPreInitiateForward);
		
		for (int i = 1; i <= MaxClients; i++)
		{
			SetPlayerReady(i, false);
		}
		
		InitPanel();
		UpdatePanel();
	}
	
	inReadyUp = true;
	inLiveCountdown = false;
	isForceStart = false;
	s_readyCountdownTimer = null;
	
	fStartTimestamp = GetGameTime();
	
	SetAllowSpawns(l4d_ready_disable_spawns.BoolValue);
	CreateTimer(0.3, Timer_RestartCountdowns, false, TIMER_FLAG_NO_MAPCHANGE);
	
	sv_infinite_primary_ammo.SetBool(true, .notify = false);
	god.SetBool(true, .notify = false);
	sb_stop.SetBool(true, .notify = false);
	
	if (real)
	{
		nativeFooter.Clear();
		
		ToggleCommandListeners(true);
		
		if (readyUpMode == ReadyMode_AutoStart)
		{
			s_expireTime = l4d_ready_autostart_wait.IntValue;
			CreateTimer(1.0, Timer_AutoStartHelper, _, TIMER_FLAG_NO_MAPCHANGE | TIMER_REPEAT);
		}
		
		UTIL_WrapperForward(g_hInitiateForward);
	}
}

void InitiateLive(bool real = true)
{
	if (real)
	{
		UTIL_WrapperForward(g_hPreLiveForward);
	}
	
	inReadyUp = false;
	inLiveCountdown = false;
	isForceStart = false;
	
	SetTeamFrozen(L4D2Team_Survivor, false);
	
	sv_infinite_primary_ammo.SetBool(false, .notify = false);
	god.SetBool(false, .notify = false);
	sb_stop.SetBool(false, .notify = false);
	
	ToggleCommandListeners(false);
	
	if (real)
	{
		ClearSurvivorProgress();
		ResetSurvivorState();
		RestartCountdowns(true);
		
		UTIL_WrapperForward(g_hLiveForward);
	}
	
	s_readyCountdownTimer = null;
}

void InitiateLiveCountdown()
{
	if (s_readyCountdownTimer == null)
	{
		UTIL_WrapperForward(g_hPreCountdownForward);
		
		ReturnTeamToSaferoom(L4D2Team_Survivor);
		PrintHintTextToAll("比赛即将开始！\n输入 !unready / 按 F2 中断倒数");
		inLiveCountdown = true;
		s_readyDelay = l4d_ready_delay.IntValue + l4d_ready_force_extra.IntValue * view_as<int>(isForceStart);
		s_readyCountdownTimer = CreateTimer(1.0, ReadyCountdownDelay_Timer, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
	
		UTIL_WrapperForward(g_hCountdownForward);
	}
}

static Action ReadyCountdownDelay_Timer(Handle timer)
{
	if (s_readyDelay == 0)
	{
		PrintHintTextToAll("比赛开始！");
		InitiateLive();
		PlayLiveSound();
		s_readyCountdownTimer = null;
		return Plugin_Stop;
	}

	PrintHintTextToAll("请各就各位：%d\n输入 !unready / 按 F2 中断倒数", s_readyDelay);
	PlayCountdownSound();
	s_readyDelay--;
	return Plugin_Continue;
}

static Action Timer_AutoStartHelper(Handle timer)
{
	if (GetSeriousClientCount(true) <= GetMaxAllowedPlayers() * l4d_ready_autostart_min.FloatValue)
	{
		// not enough players in game
		s_expireTime = l4d_ready_autostart_wait.IntValue;
		PrintHintTextToAll("玩家数量不足...");
		return Plugin_Continue;
	}

	if (IsAnyPlayerLoading())
	{
		if (s_expireTime > 0)
		{
			s_expireTime--;
			PrintHintTextToAll("等待玩家加入...");
			return Plugin_Continue;
		}
	}
	
	CreateTimer(8.0, Timer_InitiateAutoStart, _, TIMER_FLAG_NO_MAPCHANGE);
	return Plugin_Stop;
}

static Action Timer_InitiateAutoStart(Handle timer)
{
	InitiateAutoStart();
	return Plugin_Stop;
}

void InitiateAutoStart(bool real = true)
{
	if (!real)
	{
		s_autoStartTimer = null;
		return;
	}
	
	if (s_autoStartTimer == null)
	{
		PrintHintTextToAll("游戏将会自动开始！");
		s_autoStartDelay = l4d_ready_autostart_delay.IntValue;
		s_autoStartTimer = CreateTimer(1.0, AutoStartDelay_Timer, _, TIMER_FLAG_NO_MAPCHANGE | TIMER_REPEAT);
	}
}

static Action AutoStartDelay_Timer(Handle timer)
{
	if (s_autoStartDelay == 0)
	{
		s_autoStartTimer = null;
		InitiateLiveCountdown();
		return Plugin_Stop;
	}
	
	PrintHintTextToAll("游戏开始于：%d", s_autoStartDelay);
	PlayAutoStartSound();
	s_autoStartDelay--;
	return Plugin_Continue;
}

bool CheckFullReady()
{
	if (readyUpMode == ReadyMode_AutoStart)
		return false;
	
	int survReadyCount = 0, infReadyCount = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && IsPlayerReady(i))
		{
			switch (GetClientTeam(i))
			{
				case L4D2Team_Survivor: survReadyCount++;
				case L4D2Team_Infected: infReadyCount++;
			}
		}
	}
	
	// 团队模式 (l4d_ready_enabled=3): 一人准备即可代表团队准备, 双方各至少 1 名玩家已准备则开始倒计时
	if (readyUpMode == ReadyMode_TeamReady)
		return survReadyCount && infReadyCount;
	
	int survLimit = survivor_limit.IntValue;
	int zombLimit = z_max_player_zombies.IntValue;
	
	if (l4d_ready_unbalanced_start.BoolValue)
	{
		int iBaseline = l4d_ready_unbalanced_min.IntValue;
		
		if (iBaseline > survLimit) iBaseline = survLimit;
		if (iBaseline > zombLimit) iBaseline = zombLimit;
		
		int survCount = GetTeamHumanCount(L4D2Team_Survivor);
		int infCount = GetTeamHumanCount(L4D2Team_Infected);
		
		return (iBaseline <= survCount && survCount <= survReadyCount)
			&& (iBaseline <= infCount && infCount <= infReadyCount);
	}
	
	return (survReadyCount + infReadyCount) >= survLimit + zombLimit;
}

void CancelFullReady(int client, disruptType type)
{
	if (readyUpMode == ReadyMode_AutoStart)
		return;
	
	if (s_readyCountdownTimer != null)
	{
		delete s_readyCountdownTimer;
		InitiateReadyUp(false);
		
		SetTeamFrozen(L4D2Team_Survivor, l4d_ready_survivor_freeze.BoolValue);
		if (type == teamShuffle) // fix spectating
			SetClientFrozen(client, false);
		
		PrintHintTextToAll("倒数中止！");
		CPrintToChatAllEx(client, "{default}[{green}!{default}] {green}倒数中止！ {default}({teamcolor}%N {olive}%s{default})", client, g_sDisruptReason[type]);
		
		if (g_hCountdownCancelledForward.FunctionCount)
		{
			Call_StartForward(g_hCountdownCancelledForward);
			Call_PushCell(client);
			Call_PushString(g_sDisruptReason[type]);
			Call_Finish();
		}
	}
}
