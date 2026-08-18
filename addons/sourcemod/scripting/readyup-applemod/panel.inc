#if defined _readyup_panel_included
 #endinput
#endif
#define _readyup_panel_included

static Footer
	cmdFooter;

static int
	curCmd;

static const char
	hintPhrase[2][] = {"你还没有准备\n输入 !ready / 按 F1 确认准备", "你已经准备了\n输入 !unready / 按 F2 取消准备"},
	// 团队模式 (l4d_ready_enabled=3) 专用提示: 一人准备即可代表团队准备
	teamHintPhrase[2][] = {"输入 !ready / 按 F1 确认团队准备", "团队已准备\n输入 !unready / 按 F2 取消团队准备"},
	readySymbol[2][] = {"☐", "☑"},
	teamReadySymbol[2][] = {" [X]", " [√]"};

void InitPanel()
{
	if (cmdFooter == null)
	{
		cmdFooter = new Footer();
		cmdFooter.Add("!ready|!r / !unready|!nr 准备/取消准备");
		cmdFooter.Add("!return 准备状态挂边自救及返回安全区域");
		cmdFooter.Add("!lerps 查看lerp值");
		cmdFooter.Add("!match 切换比赛配置");
		cmdFooter.Add("!rmatch 关闭重置比赛配置");
		cmdFooter.Add("!s 旁观");
		cmdFooter.Add("!cur 查看路程进度");
		cmdFooter.Add("!health 查看目前奖励分情况 如有");
		cmdFooter.Add("!maplist mixmap下查看地图列表");
		cmdFooter.Add("!kickspecs 投票踢出非管理旁观玩家");
		cmdFooter.Add("!swapto 1/2/3/4 灵魂特感切换到相当于路程哪个玩家位置");
		cmdFooter.Add("!tankhud 坦克在场时开关坦克状态hud");
		cmdFooter.Add("!spechud 旁观hud开关");
		cmdFooter.Add("!playertime 查看所有玩家的真实时长及lerp值");
	}

	curCmd = 0;
	CreateTimer(1.0, MenuRefresh_Timer, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
	CreateTimer(4.0, MenuCmd_Timer, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
}

int DummyHandler(Handle menu, MenuAction action, int param1, int param2) { return 1; }

Action MenuRefresh_Timer(Handle timer)
{
	if (inReadyUp)
	{
		UpdatePanel();
		return Plugin_Continue;
	}
	return Plugin_Stop;
}

Action MenuCmd_Timer(Handle timer)
{
	if (inReadyUp)
	{
		if (cmdFooter.Length)
		{
			curCmd = (curCmd + 1) % cmdFooter.Length;
		}
		return Plugin_Continue;
	}
	return Plugin_Stop;
}

void UpdatePanel()
{
	char survivorBuffer[600] = "";
	char infectedBuffer[600] = "";
	char casterBuffer[300] = "";
	char specBuffer[200] = "";
	int playerCount = 0;
	int casterCount = 0;
	int specCount = 0;

	Panel menuPanel = new Panel();

	char ServerBuffer[128];
	char cfgName[96];

	bool isTeamReadyMode = readyUpMode == ReadyMode_TeamReady;
	int survivorReady = IsTeamReady(L4D2Team_Survivor);
	int infectedReady = IsTeamReady(L4D2Team_Infected);

	// 配置名: 优先直接读当前 confogl 配置的 confogl.cfg (UTF-8, 中文可用),
	// 回退到 l4d_ready_cfg_name 变量 (引擎从 cfg 文件解析会丢弃中文字符)
	GetReadyCfgName(cfgName, sizeof(cfgName));
	FormatEx(ServerBuffer, sizeof(ServerBuffer), "▸ 配置: %s", cfgName);
	menuPanel.DrawText(ServerBuffer);

	menuPanel.DrawText(" ");
	menuPanel.DrawText("▸ 指令:");
	menuPanel.DrawText(FooterGet(cmdFooter, curCmd));

	menuPanel.DrawText(" ");
	
	// 准备条件提示: 显示在指令行下方
	if (readyUpMode == ReadyMode_PlayerReady)
	{
		menuPanel.DrawText("每个队伍满人且所有人准备（F1/!ready）以开始游戏");
	}
	else if (readyUpMode == ReadyMode_TeamReady)
	{
		menuPanel.DrawText("每个队伍至少一人准备（F1/!ready）开始游戏");
	}
	
	menuPanel.DrawText(" ");

	char nameBuf[64];
	
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client) && !IsFakeClient(client))
		{
			++playerCount;
			GetClientFixedName(client, nameBuf, sizeof(nameBuf));
			
			if (IsPlayer(client))
			{
				bool type = (GetClientTeam(client) == L4D2Team_Survivor);
				int isReady = view_as<int>(IsPlayerReady(client));

				char infoBuf[32];
				GetPlayerGametimeDisplay(client, infoBuf, sizeof(infoBuf));

				switch (readyUpMode)
				{
					case ReadyMode_PlayerReady:
					{
						if (!inLiveCountdown) PrintHintText(client, "%s", hintPhrase[isReady]);
						Format(nameBuf, sizeof(nameBuf), "%s %s%s%s\n", readySymbol[isReady], nameBuf, IsPlayerAfk(client) ? " [AFK]" : "", infoBuf);
					}
					case ReadyMode_AutoStart:
					{
						Format(nameBuf, sizeof(nameBuf), "%s%s%s\n", nameBuf, IsPlayerAfk(client) ? " [AFK]" : "", infoBuf);
					}
					case ReadyMode_TeamReady:
					{
						// 团队模式专用提示: 跟随团队准备状态 (一人准备即可代表团队准备)
						if (!inLiveCountdown) PrintHintText(client, "%s", teamHintPhrase[type ? survivorReady : infectedReady]);
						Format(nameBuf, sizeof(nameBuf), "%s %s%s%s\n", readySymbol[isReady], nameBuf, IsPlayerAfk(client) ? " [AFK]" : "", infoBuf);
					}
				}
				type ? StrCat(survivorBuffer, sizeof(survivorBuffer), nameBuf) : StrCat(infectedBuffer, sizeof(infectedBuffer), nameBuf);
			}
			else
			{
				++specCount;
				if (casterSystemAvailable && IsClientCaster(client))
				{
					++casterCount;
					Format(nameBuf, sizeof(nameBuf), "%s\n", nameBuf);
					StrCat(casterBuffer, sizeof(casterBuffer), nameBuf);
				}
				else
				{
					if (playerCount <= l4d_ready_max_players.IntValue)
					{
						Format(nameBuf, sizeof(nameBuf), "%s\n", nameBuf);
						StrCat(specBuffer, sizeof(specBuffer), nameBuf);
					}
				}
			}
		}
	}
	
	int textCount = 0;
	int bufLen = strlen(survivorBuffer);
	if (bufLen != 0)
	{
		survivorBuffer[bufLen] = '\0';
		ReplaceString(survivorBuffer, sizeof(survivorBuffer), "#", "_");
		FormatEx(nameBuf, sizeof(nameBuf), "->%d. 幸存者%s", ++textCount, isTeamReadyMode ? teamReadySymbol[survivorReady] : "");
		menuPanel.DrawText(nameBuf);
		menuPanel.DrawText(survivorBuffer);
	}

	bufLen = strlen(infectedBuffer);
	if (bufLen != 0)
	{
		infectedBuffer[bufLen] = '\0';
		ReplaceString(infectedBuffer, sizeof(infectedBuffer), "#", "_");
		FormatEx(nameBuf, sizeof(nameBuf), "->%d. 感染者%s", ++textCount, isTeamReadyMode ? teamReadySymbol[infectedReady] : "");
		menuPanel.DrawText(nameBuf);
		menuPanel.DrawText(infectedBuffer);
	}
	
	if (specCount && textCount) menuPanel.DrawText(" ");

	if (casterSystemAvailable)
	{
		bufLen = strlen(casterBuffer);
		if (bufLen != 0)
		{
			casterBuffer[bufLen] = '\0';
			FormatEx(nameBuf, sizeof(nameBuf), "->%d. 解说%s", ++textCount, casterCount > 1 ? "s" : "");
			menuPanel.DrawText(nameBuf);
			ReplaceString(casterBuffer, sizeof(casterBuffer), "#", "_", true);
			menuPanel.DrawText(casterBuffer);
		}
	}
	
	bufLen = strlen(specBuffer);
	if (bufLen != 0)
	{
		specBuffer[bufLen] = '\0';
		FormatEx(nameBuf, sizeof(nameBuf), "->%d. 旁观%s", ++textCount, specCount > 1 ? "s" : "");
		menuPanel.DrawText(nameBuf);
		ReplaceString(specBuffer, sizeof(specBuffer), "#", "_");
		if (playerCount > l4d_ready_max_players.IntValue && specCount - casterCount > 1)
			FormatEx(specBuffer, sizeof(specBuffer), "**过多** (%d)", specCount - casterCount);
		menuPanel.DrawText(specBuffer);
	}

	if (nativeFooter.Length)
	{
		menuPanel.DrawText(" ");
		for (int i = 0; i < nativeFooter.Length; i++)
		{
			menuPanel.DrawText(FooterGet(nativeFooter, i));
		}
	}

	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client) && !IsFakeClient(client) && !IsPlayerHiddenPanel(client)) 
		{
			if (BuiltinVote_IsVoteInProgress() && IsClientInBuiltinVotePool(client))
			{
				continue;
			}
			
			if (Game_IsVoteInProgress())
			{
				int voteteam = Game_GetVoteTeam();
				if (voteteam == -1 || voteteam == GetClientTeam(client))
				{
					continue;
				}
			}
			
			switch (GetClientMenu(client))
			{
				case MenuSource_External, MenuSource_Normal: continue;
			}
			
			menuPanel.Send(client, DummyHandler, 1);
		}
	}

	delete menuPanel;
}

// 在准备状态下显示玩家的游戏时长和 Lerp 值 (数据来自 GetPlayerGametime 插件)
// 格式: " 12h/lerp15.6" ; 未获取到时长为空
void GetPlayerGametimeDisplay(int client, char[] buffer, int maxlen)
{
	buffer[0] = '\0';

	int iTime = GetPlayerGametime_GetTime(client);
	if (iTime <= 0)
		return;

	float fLerp = GetPlayerGametime_GetLerp(client) * 1000.0; // 秒 -> 毫秒
	FormatEx(buffer, maxlen, " [%dh/%.1f]", iTime / 3600, fLerp);
}