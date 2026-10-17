#if defined _readyup_command_included
 #endinput
#endif
#define _readyup_command_included

void ToggleCommandListeners(bool hook)
{
	static bool hooked = false;
	if (hooked && !hook)
	{
		RemoveCommandListener(Vote_Callback, "Vote");
		hooked = false;
	}
	else if (!hooked && hook)
	{
		AddCommandListener(Vote_Callback, "Vote");
		hooked = true;
	}
}

// ========================
//  Ready Commands
// ========================

Action Ready_Cmd(int client, int args)
{
	if (DL_IsDoorLockReadyMode())
	{
		ReplyToCommand(client, "[ReadyUp] 当前为自动门锁准备：等待玩家加载后自动倒计时，无需 !ready。管理员可用 !fs 提前结束等待。");
		return Plugin_Handled;
	}
	if (inReadyUp && IsPlayer(client))
	{
		if (!SetPlayerReady(client, true))
			PlayNotifySound(client);
		if (l4d_ready_secret.BoolValue)
			DoSecrets(client);
		if (CheckFullReady())
			InitiateLiveCountdown();
	}
	return Plugin_Handled;
}

Action Unready_Cmd(int client, int args)
{
	if (DL_IsDoorLockReadyMode())
	{
		ReplyToCommand(client, "[ReadyUp] 当前为自动门锁准备，!unready 不会暂停自动倒计时。");
		return Plugin_Handled;
	}
	if (l4d_ready_autoready.BoolValue)
	{
		return Plugin_Handled;
	}

	if (inReadyUp && client)
	{
		bool hasflag = CheckCommandAccess(client, "sm_ban", ADMFLAG_BAN); // Check for specific admin flag
		
		if (isForceStart)
		{
			if (!hasflag) return Plugin_Handled;
			CancelFullReady(client, adminAbort);
			isForceStart = false;
		}
		else
		{
			if (IsPlayer(client))
			{
				SetButtonTime(client);
				if (SetPlayerReady(client, false))
					PlayNotifySound(client);

				// 团队模式: 一人取消准备即代表整个队伍取消准备
				if (readyUpMode == ReadyMode_TeamReady)
				{
					UnreadyTeam(GetClientTeam(client));
				}
			}
			else if (!hasflag)
			{
				return Plugin_Handled;
			}
			CancelFullReady(client, readyStatus);
		}
	}
	return Plugin_Handled;
}

Action ToggleReady_Cmd(int client, int args)
{
	if (DL_IsDoorLockReadyMode()) return Ready_Cmd(client, args);
	if (inReadyUp)
	{
		return IsPlayerReady(client) ? Unready_Cmd(client, 0) : Ready_Cmd(client, 0);
	}
	return Plugin_Handled;
}

// ========================
//  Admin Commands
// ========================

Action ForceStart_Cmd(int client, int args)
{
	if (DL_IsDoorLockReadyMode())
	{
		if (CheckCommandAccess(client, "sm_ban", ADMFLAG_BAN) && externalReadyActive && DL_g_hTimer)
		{
			DL_g_iCountDown = DL_g_bFirstRound ? DL_g_iPrepareTime1r : DL_g_iPrepareTime2r;
			ReplyToCommand(client, "[ReadyUp] 已请求开局，将在下一次门锁计时检查时解锁。");
		}
		else ReplyToCommand(client, "[ReadyUp] 当前没有可强制结束的门锁准备阶段；管理员可用 sm_readystatus 查看状态。");
		return Plugin_Handled;
	}
	if (inReadyUp && readyUpMode != ReadyMode_AutoStart)
	{
		// Check if admin always allowed to do so
		if (CheckCommandAccess(client, "sm_ban", ADMFLAG_BAN)) // Check for specific admin flag
		{
			isForceStart = true;
			InitiateLiveCountdown();
			CPrintToChatAll("{green}[{green}!{default}] {blue}管理员 {default}({olive}%N{default}) {green}强制{default}了{blue}游戏开始", client);
		}
	}
	return Plugin_Handled;
}

// ========================
//  Player Commands
// ========================

Action Hide_Cmd(int client, int args)
{
	if (inReadyUp)
	{
		SetPlayerHiddenPanel(client, true);
		CPrintToChat(client, "{olive}[Readyup{default}] 准备面板已 {red}关闭{default}");
	}
	return Plugin_Handled;
}

Action Show_Cmd(int client, int args)
{
	if (inReadyUp)
	{
		SetPlayerHiddenPanel(client, false);
		CPrintToChat(client, "{olive}[Readyup{default}] 准备面板已 {blue}开启{default}");
	}
	return Plugin_Handled;
}

Action Return_Cmd(int client, int args)
{
	if (inReadyUp
			&& client > 0
			&& GetClientTeam(client) == L4D2Team_Survivor)
	{
		ReturnPlayerToSaferoom(client, false);
	}
	return Plugin_Handled;
}
