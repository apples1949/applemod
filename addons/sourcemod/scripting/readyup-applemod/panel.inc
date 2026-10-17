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

static Handle s_menuRefreshTimer, s_menuCmdTimer;

void StopReadyPanelTimers()
{
	delete s_menuRefreshTimer;
	delete s_menuCmdTimer;
}

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
		cmdFooter.Add("!swapto 1/2/3/4 按路程切换灵魂位置");
		cmdFooter.Add("!tankhud 坦克在场时开关坦克状态hud");
		cmdFooter.Add("!spechud 旁观hud开关");
		cmdFooter.Add("!pt 查看所有玩家的游戏时长及lerp值");
	}

	StopReadyPanelTimers();
	curCmd = 0;
	s_menuRefreshTimer = CreateTimer(1.0, MenuRefresh_Timer, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
	s_menuCmdTimer = CreateTimer(4.0, MenuCmd_Timer, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
}

int DummyHandler(Handle menu, MenuAction action, int param1, int param2) { return 1; }

Action MenuRefresh_Timer(Handle timer)
{
	if (inReadyUp)
	{
		UpdatePanel();
		return Plugin_Continue;
	}
	s_menuRefreshTimer = null;
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
	s_menuCmdTimer = null;
	return Plugin_Stop;
}

// SourceMod radio panels share a 511-byte payload, including newlines.
// Keep UTF-8 characters intact and account for every DrawText newline.
void RU_CopyPanelText(const char[] source, char[] output, int maxlen, int budget)
{
	output[0] = '\0';
	if (budget > maxlen - 1) budget = maxlen - 1;
	if (budget <= 0) return;
	int length = strlen(source);
	bool shortened = length > budget;
	int limit = shortened ? budget - 1 : budget;
	int pos = 0;
	while (pos < length)
	{
		int bytes = GetCharBytes(source[pos]);
		if (bytes < 1 || pos + bytes > length || pos + bytes > limit) break;
		for (int i = 0; i < bytes; i++) output[pos + i] = source[pos + i];
		pos += bytes;
	}
	if (pos < length && pos < budget) output[pos++] = '~';
	output[pos] = '\0';
}

void RU_DrawPanelText(Panel panel, const char[] text, int limit = 510)
{
	int remaining = panel.TextRemaining - 1;
	if (remaining <= 0) return;
	if (limit > remaining) limit = remaining;
	char line[512];
	RU_CopyPanelText(text, line, sizeof(line), limit);
	panel.DrawText(line);
}

void RU_GetPanelName(int client, char[] name, int maxlen)
{
	GetClientFixedName(client, name, maxlen);
	ReplaceString(name, maxlen, "#", "_");
	ReplaceString(name, maxlen, "\n", " ");
	ReplaceString(name, maxlen, "\r", " ");
}

void UpdatePanel()
{
	int players[MAXPLAYERS + 1], count, survivors, infected, spectators, casters, afkCount;
	char name[128], info[64], row[256], headings[2][64];
	int fullBytes, plainBytes;
	for (int team = L4D2Team_Survivor; team <= L4D2Team_Infected; team++)
	{
		for (int client = 1; client <= MaxClients; client++)
		{
			if (!IsClientInGame(client) || IsFakeClient(client) || GetClientTeam(client) != team) continue;
			players[count++] = client;
			if (team == L4D2Team_Survivor) survivors++; else infected++;
			RU_GetPanelName(client, name, sizeof(name));
			GetPlayerGametimeDisplay(client, info, sizeof(info));
			bool afk = IsPlayerAfk(client);
			if (afk) afkCount++;
			FormatEx(row, sizeof(row), "%s %s%s", (readyUpMode == ReadyMode_AutoStart ? "•" : readySymbol[view_as<int>(IsPlayerReady(client))]), name, afk ? " [AFK]" : "");
			plainBytes += strlen(row) + 1;
			fullBytes += strlen(row) + strlen(info) + 1;
			if (!inLiveCountdown && readyUpMode != ReadyMode_AutoStart)
			{
				if (readyUpMode == ReadyMode_TeamReady)
					PrintHintText(client, "%s", teamHintPhrase[view_as<int>(IsTeamReady(team))]);
				else PrintHintText(client, "%s", hintPhrase[view_as<int>(IsPlayerReady(client))]);
			}
		}
	}
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || IsFakeClient(client) || IsPlayer(client)) continue;
		if (casterSystemAvailable && IsClientCaster(client)) casters++; else spectators++;
	}

	Panel menuPanel = new Panel();
	char cfgName[96], text[160];
	GetReadyCfgName(cfgName, sizeof(cfgName));
	FormatEx(text, sizeof(text), "配置: %s", cfgName);
	RU_DrawPanelText(menuPanel, text, count > 8 ? 31 : 63);
	switch (readyUpMode)
	{
		case ReadyMode_PlayerReady: RU_DrawPanelText(menuPanel, l4d_ready_unbalanced_start.BoolValue ? "足额全员准备 F1/F2 | !pt" : "满队全员准备 F1/F2 | !pt");
		case ReadyMode_TeamReady: RU_DrawPanelText(menuPanel, "各队1人准备 F1/F2 | !pt");
		case ReadyMode_AutoStart: RU_DrawPanelText(menuPanel, "自动开始 | !pt详情");
	}

	int headingBytes;
	if (survivors)
	{
		FormatEx(headings[0], sizeof(headings[]), "幸存者%s (%d)", readyUpMode == ReadyMode_TeamReady ? teamReadySymbol[view_as<int>(IsTeamReady(L4D2Team_Survivor))] : "", survivors);
		headingBytes += strlen(headings[0]) + 1;
	}
	if (infected)
	{
		FormatEx(headings[1], sizeof(headings[]), "感染者%s (%d)", readyUpMode == ReadyMode_TeamReady ? teamReadySymbol[view_as<int>(IsTeamReady(L4D2Team_Infected))] : "", infected);
		headingBytes += strlen(headings[1]) + 1;
	}
	char specSummary[64];
	int specBytes;
	if (spectators || casters)
	{
		FormatEx(specSummary, sizeof(specSummary), "旁观:%d 解说:%d", spectators, casters);
		specBytes = strlen(specSummary) + 1;
	}
	int footerBytes, allFooterBytes;
	char moreFooter[64], firstFooter[MAX_FOOTER_LEN];
	if (nativeFooter.Length)
	{
		RU_CopyPanelText(FooterGet(nativeFooter, 0), firstFooter, sizeof(firstFooter), 48);
		footerBytes = strlen(firstFooter) + 1;
		if (nativeFooter.Length > 1)
		{
			FormatEx(moreFooter, sizeof(moreFooter), "另%d条页脚未展开", nativeFooter.Length - 1);
			footerBytes += strlen(moreFooter) + 1;
		}
		for (int i = 0; i < nativeFooter.Length; i++) allFooterBytes += strlen(FooterGet(nativeFooter, i)) + 1;
		if (allFooterBytes < footerBytes) footerBytes = allFooterBytes;
	}
	int reserved = headingBytes + specBytes + footerBytes;
	int available = menuPanel.TextRemaining - reserved;
	bool showInfo = fullBytes <= available;
	bool compact = false;
	int visible = count, nameBudget = 127;
	char compactNote[] = "~缩名 *AFK；!pt详情";
	if (!showInfo)
	{
		available -= strlen(compactNote) + 1;
		compact = plainBytes > available;
		if (compact && count)
		{
			// One ready marker + space + optional '*' + newline; keep >=5 name bytes.
			nameBudget = (available - count * 5 - afkCount) / count;
			if (nameBudget < 5)
			{
				available -= 40; // explicit remaining-player summary, including newline
				visible = available / 11;
				if (visible < 0) visible = 0;
				if (visible > count) visible = count;
				nameBudget = 5;
			}
		}
		RU_DrawPanelText(menuPanel, compactNote);
	}
	else if (cmdFooter.Length && fullBytes + reserved + strlen(FooterGet(cmdFooter, curCmd)) + 1 <= menuPanel.TextRemaining)
	{
		RU_DrawPanelText(menuPanel, FooterGet(cmdFooter, curCmd));
	}

	int lastTeam;
	for (int i = 0; i < visible; i++)
	{
		int client = players[i], team = GetClientTeam(client);
		if (team != lastTeam)
		{
			RU_DrawPanelText(menuPanel, headings[team - L4D2Team_Survivor]);
			lastTeam = team;
		}
		RU_GetPanelName(client, name, sizeof(name));
		char shortName[128];
		RU_CopyPanelText(name, shortName, sizeof(shortName), nameBudget);
		info[0] = '\0';
		if (showInfo) GetPlayerGametimeDisplay(client, info, sizeof(info));
		FormatEx(row, sizeof(row), "%s %s%s%s", (readyUpMode == ReadyMode_AutoStart ? "•" : readySymbol[view_as<int>(IsPlayerReady(client))]), shortName, IsPlayerAfk(client) ? (compact ? "*" : " [AFK]") : "", info);
		RU_DrawPanelText(menuPanel, row);
	}
	if (visible < count)
	{
		if (survivors && !lastTeam) RU_DrawPanelText(menuPanel, headings[0]);
		if (infected && lastTeam != L4D2Team_Infected) RU_DrawPanelText(menuPanel, headings[1]);
		FormatEx(text, sizeof(text), "另%d名玩家未展开", count - visible);
		RU_DrawPanelText(menuPanel, text);
	}
	if (specBytes)
	{
		RU_DrawPanelText(menuPanel, specSummary);
		// Preserve spectator names when the full list fits; otherwise the count is explicit.
		int namesBytes;
		for (int client = 1; client <= MaxClients; client++)
		{
			if (!IsClientInGame(client) || IsFakeClient(client) || IsPlayer(client)) continue;
			RU_GetPanelName(client, name, sizeof(name));
			namesBytes += strlen(name) + 1;
		}
		if (count + spectators + casters <= l4d_ready_max_players.IntValue && namesBytes + footerBytes <= menuPanel.TextRemaining)
		{
			for (int client = 1; client <= MaxClients; client++)
			{
				if (!IsClientInGame(client) || IsFakeClient(client) || IsPlayer(client)) continue;
				RU_GetPanelName(client, name, sizeof(name));
				RU_DrawPanelText(menuPanel, name);
			}
		}
	}
	if (nativeFooter.Length)
	{
		if (allFooterBytes <= menuPanel.TextRemaining)
		{
			for (int i = 0; i < nativeFooter.Length; i++) RU_DrawPanelText(menuPanel, FooterGet(nativeFooter, i));
		}
		else
		{
			RU_DrawPanelText(menuPanel, firstFooter);
			if (moreFooter[0]) RU_DrawPanelText(menuPanel, moreFooter);
		}
	}

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || IsFakeClient(client) || IsPlayerHiddenPanel(client)) continue;
		if (BuiltinVote_IsVoteInProgress() && IsClientInBuiltinVotePool(client)) continue;
		if (Game_IsVoteInProgress())
		{
			int voteteam = Game_GetVoteTeam();
			if (voteteam == -1 || voteteam == GetClientTeam(client)) continue;
		}
		switch (GetClientMenu(client))
		{
			case MenuSource_External, MenuSource_Normal: continue;
		}
		menuPanel.Send(client, DummyHandler, 1);
	}
	delete menuPanel;
}

// 在准备状态下显示玩家的游戏时长和 Lerp 值 (数据来自 GetPlayerGametime 插件)
// 两个时长都拿到: " [12.57/11.98/15.6]"          (主页/成就 顺序固定, 不加文字)
// 只拿到主页:     " [主页12.57/15.6]"
// 只拿到成就:     " [成就11.98/15.6]"
// (时长=小时两位小数, Lerp=毫秒一位小数; 两个时长都没有则不显示)
void GetPlayerGametimeDisplay(int client, char[] buffer, int maxlen)
{
	buffer[0] = '\0';

	// GetPlayerGametime 是可选依赖(inc 中 required = 0), 插件不在时不要调用它的 native
	if (!LibraryExists("GetPlayerGametime"))
		return;

	int iProfile = GetPlayerGametime_GetProfileTime(client);
	int iStat = GetPlayerGametime_GetStatTime(client);
	if (iProfile <= 0 && iStat <= 0)
		return;

	float fLerp = GetPlayerGametime_GetLerp(client) * 1000.0; // 秒 -> 毫秒

	if (iProfile > 0 && iStat > 0) FormatEx(buffer, maxlen, " [%.2f/%.2f/%.1f]", float(iProfile) / 3600.0, float(iStat) / 3600.0, fLerp);
	else if (iProfile > 0) FormatEx(buffer, maxlen, " [主页%.2f/%.1f]", float(iProfile) / 3600.0, fLerp);
	else FormatEx(buffer, maxlen, " [成就%.2f/%.1f]", float(iStat) / 3600.0, fLerp);
}