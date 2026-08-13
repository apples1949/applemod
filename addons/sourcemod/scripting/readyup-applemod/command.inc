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
