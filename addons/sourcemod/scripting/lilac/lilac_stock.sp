/*
	Little Anti-Cheat
	Copyright (C) 2018-2023 J_Tanzanite

	This program is free software: you can redistribute it and/or modify
	it under the terms of the GNU General Public License as published by
	the Free Software Foundation, either version 3 of the License, or
	(at your option) any later version.

	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

void lilac_warn_all(int client, int cheat, int detections)
{
	char name[MAX_NAME_LENGTH];
	char type[64];
	
	/* We'll assume the player is valid, as this function
	 * should never be called on invalid clients in the first place. */
	/* if (!is_player_valid(client))
		return; */
	
	switch (cheat) {
	case CHEAT_BHOP:          { strcopy(type, sizeof(type), "「连跳（Bhop）」外挂"); }
	case CHEAT_AIMBOT:        { strcopy(type, sizeof(type), "「自瞄（Aimbot）」外挂"); }
	case CHEAT_AIMLOCK:       { strcopy(type, sizeof(type), "「锁头（Aimlock）」外挂"); }
	case CHEAT_SPEEDHACK:     { strcopy(type, sizeof(type), "「变速（Speedhack）」外挂"); }
	case CHEAT_INFECTED_DMG:  { strcopy(type, sizeof(type), "「特感伤害漏洞（Infected Damage）」"); }
	case CHEAT_SURVIVOR_DMG:  { strcopy(type, sizeof(type), "「生还者伤害漏洞（Survivor Damage）」"); }
	/* Macros have their own warning system. */
	default: { return; }
	}
	
	if (!GetClientName(client, name, sizeof(name)))
		strcopy(name, sizeof(name), "[NAME_ERROR]");
	
	/* 不只提醒管理员：把嫌疑提示广播给全体玩家。 */
	PrintToChatAll("[Lilac] 玩家 %s 疑似使用%s，累计检测 %d 次", name, type, detections);
}

/* Useless Todo: I should update this soon... But I won't :P */
bool bullettime_can_shoot(int client)
{
	int weapon;

	if (!IsPlayerAlive(client))
		return false;

	weapon = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");

	if (!IsValidEntity(weapon))
		return false;

	if (GetEntPropFloat(client, Prop_Data, "m_flSimulationTime") + GetTickInterval()
		>= GetEntPropFloat(weapon, Prop_Data, "m_flNextPrimaryAttack"))
		return true;

	return false;
}

void lilac_reset_client(int client)
{
    lilac_backtrack_reset_client(client);
    lilac_bhop_reset_client(client);
    lilac_macro_reset_client(client);
    lilac_aimbot_reset_client(client);
    lilac_speedhack_reset_client(client);
    lilac_infected_damage_reset_client(client);
    lilac_survivor_damage_reset_client(client);
    lilac_ping_reset_client(client);
    lilac_convar_reset_client(client);
    lilac_lerp_reset_client(client);
    lilac_network_reset_client(client);
    lilac_discord_reset_client(client);

    playerinfo_index[client] = 0;
    playerinfo_aimlock_sus[client] = 0;
    playerinfo_aimlock[client] = 0;
    playerinfo_time_bumpercart[client] = 0.0;
    playerinfo_time_teleported[client] = 0.0;
    playerinfo_time_camera_forced[client] = 0.0;
    playerinfo_time_ghost[client] = 0.0;
    playerinfo_time_aimlock[client] = 0.0;
    playerinfo_time_aimlock_hit[client] = -10.0;
    playerinfo_time_process_aimlock[client] = 0.0;
    Format(playerinfo_detected[client], sizeof(playerinfo_detected[]), "");

    for (int i = 0; i < CHEAT_MAX; i++) {
        playerinfo_time_forward[client][i] = 0.0;
        playerinfo_banned_flags[client][i] = false;
    }

    for (int i = 0; i < CMD_LENGTH; i++) {
        playerinfo_buttons[client][i] = 0;
        playerinfo_actions[client][i] = 0;
        playerinfo_time_usercmd[client][i] = 0.0;

        set_player_log_angles(client, view_as<float>({0.0, 0.0, 0.0}), i);
    }
}

void lilac_log_setup_client(int client)
{
	char date[512], steamid[64], ip[64];

	FormatTime(date, sizeof(date), dateformat, GetTime());

	GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid), true);
	GetClientIP(client, ip, sizeof(ip), true);

	char matchid[64], matchid_part[80];
	matchid_part[0] = '\0';

	if (icvar[CVAR_AR] && NATIVE_EXISTS("AR_GetMatchID") && AR_GetMatchID(matchid, sizeof(matchid)))
		Format(matchid_part, sizeof(matchid_part), " | 比赛ID: %s", matchid);

	FormatEx(line_buffer, sizeof(line_buffer),
		"%s [版本 %s] {玩家名: \"%N\" | SteamID: %s | IP: %s%s}",
		date, PLUGIN_VERSION, client, steamid, ip, matchid_part);
}

/* Tick of the running SourceTV demo, or -1 when there is none. */
static int lilac_demo_tick()
{
	if (!NATIVE_EXISTS("SourceTV_IsActive")
		|| !NATIVE_EXISTS("SourceTV_IsRecording")
		|| !NATIVE_EXISTS("SourceTV_GetRecordingTick"))
		return -1;

	if (!SourceTV_IsActive() || !SourceTV_IsRecording())
		return -1;

	return SourceTV_GetRecordingTick();
}

void lilac_log_extra(int client)
{
	float pos[3], ang[3];
	char map[128], weapon[64];

	GetClientAbsOrigin(client, pos);
	get_player_log_angles(client, 0, true, ang);
	GetCurrentMap(map, sizeof(map));
	GetClientWeapon(client, weapon, sizeof(weapon));

	char burst[112];
	burst[0] = '\0';

	if (icvar[CVAR_TELEMETRY] & TELEMETRY_NETWORK) {
		char stats[96];
		lilac_network_format_burst(client, stats, sizeof(stats));
		FormatEx(burst, sizeof(burst), ", 突发={%s}", stats);
	}

	/* Latency in ms, Loss/Choke in % — same scale and precision as
	 * lilac_network_format(), instead of raw 0-1 fractions at the default
	 * 6 decimal places. */
	FormatEx(line_buffer, sizeof(line_buffer),
		"\t服务器Tick={%d}, 坐标={%.0f,%.0f,%.0f}, 视角={%.5f,%.5f,%.5f}, 地图=\"%s\", 队伍={%d}, 武器=\"%s\", 延迟={入:%.1f,出:%.1f}, 丢包={入:%.1f,出:%.1f}, 阻塞={入:%.1f,出:%.1f}%s, 连接时长={%.1f 秒}, 游戏时长={%.1f 秒}",
		GetGameTickCount(),
		pos[0], pos[1], pos[2],
		ang[0], ang[1], ang[2],
		map, GetClientTeam(client), weapon,
		GetClientAvgLatency(client, NetFlow_Incoming) * 1000.0,
		GetClientAvgLatency(client, NetFlow_Outgoing) * 1000.0,
		GetClientAvgLoss(client, NetFlow_Incoming) * 100.0,
		GetClientAvgLoss(client, NetFlow_Outgoing) * 100.0,
		GetClientAvgChoke(client, NetFlow_Incoming) * 100.0,
		GetClientAvgChoke(client, NetFlow_Outgoing) * 100.0,
		burst, GetClientTime(client), GetGameTime());

	/* Where to jump in the SourceTV demo. */
	int demo_tick = lilac_demo_tick();

	if (demo_tick >= 0)
		Format(line_buffer, sizeof(line_buffer),
			"%s, 录像Tick={%d}", line_buffer, demo_tick);

	lilac_log(false);
}

void lilac_log(bool cleanup)
{
	Handle file = OpenFile(log_file, "a");

	if (file == null) {
		PrintToServer("[Lilac] 无法打开日志文件。");
		return;
	}

	/* Remove invalid characters.
	 * This doesn't care about invalid utf-8 formatting,
	 * only ASCII control characters. */
	if (cleanup) {
		for (int i = 0; line_buffer[i]; i++) {
			if (line_buffer[i] == '\n' || line_buffer[i] == 0x0d)
				line_buffer[i] = '*';
			else if (line_buffer[i] < 32)
				line_buffer[i] = '#';
		}
	}

	WriteFileLine(file, "%s", line_buffer);
	/* Just echo log lines to SourceIRC */
	if (icvar[CVAR_SOURCEIRC] && NATIVE_EXISTS("IRC_MsgFlaggedChannels")) {
		/* Note- SourceIRC Expects messages to be clean with no \r or \n, so clean it if not already done. */
		if (!cleanup) {
			for (int i = 0; line_buffer[i]; i++) {
				if (line_buffer[i] == '\n' || line_buffer[i] == 0x0d)
					line_buffer[i] = '*';
				else if (line_buffer[i] < 32)
					line_buffer[i] = '#';
			}
		}
		IRC_MsgFlaggedChannels("lilac", "[LILAC] %s", line_buffer);
	}
	CloseHandle(file);
}

void lilac_log_smooth_telemetry_setup()
{
    if (FileExists(smooth_telemetry_log_file, false, NULL_STRING))
        return;

    Handle file = OpenFile(smooth_telemetry_log_file, "a");

    if (file == null) {
        PrintToServer("[Lilac] 无法打开平滑自瞄监测日志文件。");
        return;
    }

    char date[512];
    FormatTime(date, sizeof(date), dateformat, GetTime());

    WriteFileLine(file,
        "=========[说明]=========\n\
平滑自瞄监测日志 — Little Anti-Cheat %s\n\
创建时间: %s\n\n\
本日志记录用于校准平滑自瞄检测阈值的数据。\n\
平滑监测（Smooth-Telemetry）字段：玩家名 | SteamID | IP | 样本数N | 变异系数CV | 抖动Jerk | 总偏转TotalDelta | 末段距离FinalDist\n\
绕过监测（Bypass-Telemetry）字段：玩家名 | SteamID | IP | 样本数N | 变异系数CV | 抖动Jerk | 总偏转TotalDelta | 末段距离FinalDist | 收敛前PreConverge | 收敛后PostConverge\n\
这些都不是检测结果 — 只有数值接近检测阈值时才会记录。\n\
请在开启封禁前，先用这些数据校准阈值。\n\n",
        PLUGIN_VERSION, date);

    CloseHandle(file);
}

void lilac_log_smooth_telemetry(int client, int sm_n, float sm_cv, float sm_avg_jerk,
    float sm_total_delta, float final_dist,
    float pre_ratio = -1.0, float post_ratio = -1.0)
{
    if (!(icvar[CVAR_TELEMETRY] & TELEMETRY_AIMBOT))
        return;

    Handle file = OpenFile(smooth_telemetry_log_file, "a");

    if (file == null) {
        PrintToServer("[Lilac] 无法打开平滑自瞄监测日志文件。");
        return;
    }

    char date[512], steamid[64], ip[64];
    FormatTime(date, sizeof(date), dateformat, GetTime());
    GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid), true);
    GetClientIP(client, ip, sizeof(ip), true);

    char telemetry_buffer[768];

    if (pre_ratio < 0.0) {
        /* Standard smooth aimbot entry. */
        FormatEx(telemetry_buffer, sizeof(telemetry_buffer),
            "%s [版本 %s] {玩家名: \"%N\" | SteamID: %s | IP: %s} 平滑监测 | 样本数: %d | 变异系数: %.3f | 抖动: %.4f | 总偏转: %.2f | 末段距离: %.2f",
            date, PLUGIN_VERSION, client, steamid, ip,
            sm_n, sm_cv, sm_avg_jerk, sm_total_delta, final_dist);
    }
    else {
        /* Bypass telemetry entry — includes pre/post convergence ratios. */
        FormatEx(telemetry_buffer, sizeof(telemetry_buffer),
            "%s [版本 %s] {玩家名: \"%N\" | SteamID: %s | IP: %s} 绕过监测 | 样本数: %d | 变异系数: %.3f | 抖动: %.4f | 总偏转: %.2f | 末段距离: %.2f | 收敛前: %.2f | 收敛后: %.2f",
            date, PLUGIN_VERSION, client, steamid, ip,
            sm_n, sm_cv, sm_avg_jerk, sm_total_delta, final_dist,
            pre_ratio, post_ratio);
    }

    /* Remove invalid characters — same pattern as lilac_log. */
    for (int i = 0; telemetry_buffer[i]; i++) {
        if (telemetry_buffer[i] == '\n' || telemetry_buffer[i] == 0x0d)
            telemetry_buffer[i] = '*';
        else if (telemetry_buffer[i] < 32)
            telemetry_buffer[i] = '#';
    }

    WriteFileLine(file, "%s", telemetry_buffer);
    CloseHandle(file);
}

void lilac_log_speedhack_shadow_setup()
{
    if (FileExists(speedhack_shadow_log_file, false, NULL_STRING))
        return;

    Handle file = OpenFile(speedhack_shadow_log_file, "a");

    if (file == null) {
        PrintToServer("[Lilac] 无法打开变速影子日志文件。");
        return;
    }

    char date[512];
    FormatTime(date, sizeof(date), dateformat, GetTime());

    WriteFileLine(file, "=========[说明]=========");
    WriteFileLine(file, "变速影子日志 - Little Anti-Cheat %s", PLUGIN_VERSION);
    WriteFileLine(file, "创建时间: %s", date);
    WriteFileLine(file, "");
    WriteFileLine(file, "本日志仅用于校准，这里没有任何检测或封禁结论。");
    WriteFileLine(file, "只覆盖真实阻塞（choke）在 10% 及以上的玩家，这类玩家目前不会因变速被封禁。");
    WriteFileLine(file, "每个玩家都与他自己的正常指令速率比较，该速率在他进服务器的前 30 秒内学习得到。");
    WriteFileLine(file, "WOULD BAN（本应封禁）：按单玩家规则，这名玩家会被封禁。");
    WriteFileLine(file, "未封禁：玩家超过了上限，但对他来说属于正常范围。");
    WriteFileLine(file, "字段：检测次数 | 每秒指令数 | 正常值 | 对比度 | 对比度中位数 | 平均阻塞 | 观察时长 | 其他被标记人数");
    WriteFileLine(file, "其他被标记人数：最近 3 秒内同样超限的其他玩家数。多人同时超限通常意味着服务器事件，而不是作弊。");
    WriteFileLine(file, "");

    CloseHandle(file);
}

void lilac_log_speedhack_shadow(int client, const char[] message)
{
    if (!icvar[CVAR_LOG] || !(icvar[CVAR_TELEMETRY] & TELEMETRY_SPEEDHACK))
        return;

    Handle file = OpenFile(speedhack_shadow_log_file, "a");

    if (file == null) {
        PrintToServer("[Lilac] 无法打开变速影子日志文件。");
        return;
    }

    lilac_log_setup_client(client);
    Format(line_buffer, sizeof(line_buffer), "%s 变速影子: %s", line_buffer, message);

    for (int i = 0; line_buffer[i]; i++) {
        if (line_buffer[i] == '\n' || line_buffer[i] == 0x0d)
            line_buffer[i] = '*';
        else if (line_buffer[i] < 32)
            line_buffer[i] = '#';
    }

    WriteFileLine(file, "%s", line_buffer);
    CloseHandle(file);
}

void lilac_log_damage_clock_setup()
{
    if (FileExists(damage_clock_log_file, false, NULL_STRING))
        return;

    Handle file = OpenFile(damage_clock_log_file, "a");

    if (file == null) {
        PrintToServer("[Lilac] 无法打开伤害时钟日志文件。");
        return;
    }

    char date[512];
    FormatTime(date, sizeof(date), dateformat, GetTime());

    WriteFileLine(file, "=========[说明]=========");
    WriteFileLine(file, "伤害时钟日志 - Little Anti-Cheat %s", PLUGIN_VERSION);
    WriteFileLine(file, "创建时间: %s", date);
    WriteFileLine(file, "");
    WriteFileLine(file, "本日志仅用于校准，这里没有任何检测或封禁结论。");
    WriteFileLine(file, "当生还者对坦克 1 秒内的伤害按真实时钟计算超过武器上限时，写入一行记录。");
    WriteFileLine(file, "GameClock（游戏时钟）：按玩家自身游戏时钟计算的 1 秒内伤害（生还者伤害模块采用的口径）。");
    WriteFileLine(file, "RealClock（真实时钟）：按真实时间计算的 1 秒内伤害。");
    WriteFileLine(file, "ClockAhead（时钟超前）：玩家的时钟领先服务器多少秒。");
    WriteFileLine(file, "Cmds1s（每秒指令）：最近 1 秒收到的该玩家指令数（正常约为 tickrate）。");
    WriteFileLine(file, "字段：武器 | 阈值 | 游戏时钟 | 真实时钟 | 时钟超前 | 每秒指令 | 服务器卡顿 | 网络信息");
    WriteFileLine(file, "");

    CloseHandle(file);
}

void lilac_log_damage_clock(int client, const char[] message)
{
    if (!icvar[CVAR_LOG] || !(icvar[CVAR_TELEMETRY] & TELEMETRY_DAMAGE))
        return;

    Handle file = OpenFile(damage_clock_log_file, "a");

    if (file == null) {
        PrintToServer("[Lilac] 无法打开伤害时钟日志文件。");
        return;
    }

    lilac_log_setup_client(client);
    Format(line_buffer, sizeof(line_buffer), "%s 伤害时钟: %s", line_buffer, message);

    for (int i = 0; line_buffer[i]; i++) {
        if (line_buffer[i] == '\n' || line_buffer[i] == 0x0d)
            line_buffer[i] = '*';
        else if (line_buffer[i] < 32)
            line_buffer[i] = '#';
    }

    WriteFileLine(file, "%s", line_buffer);
    CloseHandle(file);
}

void lilac_log_angle_metric(int client, float eu_delta, float tr_delta,
    float eu_total, float tr_total, float eu_final, float tr_final,
    float shot_pitch, int eu_flags, int tr_flags, int ticks)
{
    if (!(icvar[CVAR_TELEMETRY] & TELEMETRY_AIMBOT))
        return;

    Handle file = OpenFile(angle_metric_log_file, "a");

    if (file == null) {
        PrintToServer("[Lilac] 无法打开角度指标日志文件。");
        return;
    }

    char date[512], steamid[64], buf[768];
    FormatTime(date, sizeof(date), dateformat, GetTime());
    GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid), true);

    FormatEx(buf, sizeof(buf),
        "%s {玩家名: \"%N\" | SteamID: %s} 角度指标 | Tick数: %d | 俯仰角: %.1f | \
偏转: %.2f/%.2f | 总偏转: %.2f/%.2f | 末段距离: %.2f/%.2f | 标记: %d/%d | 比值: %.3f%s",
        date, client, steamid, ticks, shot_pitch,
        eu_delta, tr_delta, eu_total, tr_total, eu_final, tr_final,
        eu_flags, tr_flags,
        (tr_total > 0.01) ? (eu_total / tr_total) : 0.0,
        (eu_flags != tr_flags) ? " <<< DISAGREE（两者不一致）" : "");

    for (int i = 0; buf[i]; i++) {
        if (buf[i] == '\n' || buf[i] == 0x0d) buf[i] = '*';
        else if (buf[i] < 32) buf[i] = '#';
    }

    WriteFileLine(file, "%s", buf);
    CloseHandle(file);
}

void lilac_log_first_time_setup()
{
    /* Some admins may not understand how to interpret cheat logs
    * correctly, thus, we should warn them so they don't panic
    * over trivial stuff. */
    if (!FileExists(log_file, false, NULL_STRING)) {
        FormatEx(line_buffer, sizeof(line_buffer),
"=========[说明]=========\n\
感谢安装 Little Anti-Cheat %s！\n\
关于这个反作弊插件，有几点需要说明：\n\n\
如果某名玩家被记录为「疑似（suspected）」使用作弊，那并不代表他一定在作弊。\n\
如果记录的疑似次数很少、出现得很稀疏，那很可能是误报。\n\
自动封禁由 5 次及以上「疑似（suspicion）」或 1 次「检测（detection）」触发。\n\
如果你认为某次封禁可能有误，请随时告诉我。\n\n\
就这些，祝你游戏愉快~\n\n\n", PLUGIN_VERSION);
        lilac_log(false);
    }

    lilac_log_telemetry_setup();
}

/* Creates the files of the telemetry that is on. Also called when
 * lilac_telemetry changes. */
void lilac_log_telemetry_setup()
{
    if (icvar[CVAR_TELEMETRY] & TELEMETRY_AIMBOT)
        lilac_log_smooth_telemetry_setup();

    if (icvar[CVAR_TELEMETRY] & TELEMETRY_SPEEDHACK)
        lilac_log_speedhack_shadow_setup();

    if (icvar[CVAR_TELEMETRY] & TELEMETRY_DAMAGE)
        lilac_log_damage_clock_setup();
}

/* True when a detection of this cheat ends in a ban. */
bool lilac_ban_active(int cheat)
{
	/* Banning has been disabled. */
	if (!icvar[CVAR_BAN])
		return false;

	/* Log only mode of the module, in which case, don't ban. */
	switch (cheat) {
	case CHEAT_ANGLES: { return icvar[CVAR_ANGLES] >= 0; }
	case CHEAT_CHATCLEAR: { return icvar[CVAR_CHAT] >= 0; }
	case CHEAT_CONVAR: { return icvar[CVAR_CONVAR] >= 0; }
	case CHEAT_NOLERP: { return icvar[CVAR_NOLERP] >= 0; }
	case CHEAT_BHOP: { return icvar[CVAR_BHOP] >= 0; }
	case CHEAT_MACRO: { return icvar[CVAR_MACRO] >= 0; }
	case CHEAT_NEWLINE_NAME: { return icvar[CVAR_FILTER_NAME] >= 0; }
	}

	return true;
}

void lilac_ban_client(int client, int cheat)
{
	char reason[128];
	int lang = LANG_SERVER;

	/* Banning is disabled or log only, don't forward the ban and don't ban. */
	if (!lilac_ban_active(cheat))
		return;

	if (icvar[CVAR_BAN_LANGUAGE])
		lang = client;

	switch (cheat) {
	case CHEAT_ANGLES: { Format(reason, sizeof(reason),
		"[Little Anti-Cheat %s] %T", PLUGIN_VERSION, "ban_angle", lang); }
	case CHEAT_CHATCLEAR: { Format(reason, sizeof(reason),
		"[Little Anti-Cheat %s] %T", PLUGIN_VERSION, "ban_chat_clear", lang); }
	case CHEAT_CONVAR: { Format(reason, sizeof(reason),
		"[Little Anti-Cheat %s] %T", PLUGIN_VERSION, "ban_convar", lang, playerinfo_detected[client]); }
	case CHEAT_NOLERP: { Format(reason, sizeof(reason),
		"[Little Anti-Cheat %s] %T", PLUGIN_VERSION, "ban_nolerp", lang); }
	case CHEAT_BHOP: { Format(reason, sizeof(reason),
		"[Little Anti-Cheat %s] %T", PLUGIN_VERSION, "ban_bhop", lang); }
	case CHEAT_AIMBOT: { Format(reason, sizeof(reason),
		"[Little Anti-Cheat %s] %T", PLUGIN_VERSION, "ban_aimbot", lang); }
	case CHEAT_AIMLOCK: { Format(reason, sizeof(reason),
		"[Little Anti-Cheat %s] %T", PLUGIN_VERSION, "ban_aimlock", lang); }
	case CHEAT_MACRO: { Format(reason, sizeof(reason),
		"[Little Anti-Cheat %s] %T", PLUGIN_VERSION, "ban_macro", lang); }
	case CHEAT_NEWLINE_NAME: { Format(reason, sizeof(reason),
		"[Little Anti-Cheat %s] %T", PLUGIN_VERSION, "ban_name_newline", lang); }
	case CHEAT_SPEEDHACK: { Format(reason, sizeof(reason),
		"[Little Anti-Cheat %s] Speedhack", PLUGIN_VERSION); }
	case CHEAT_INFECTED_DMG: { Format(reason, sizeof(reason),
		"[Little Anti-Cheat %s] Infected Damage Exploit", PLUGIN_VERSION); }
	case CHEAT_SURVIVOR_DMG: { Format(reason, sizeof(reason),
		"[Little Anti-Cheat %s] Survivor Damage Exploit", PLUGIN_VERSION); }
	default: return;
	}

	lilac_forward_client_ban(client, cheat);
	lilac_discord_report(client, cheat, DISCORD_BANNED);

	switch (lilac_get_ban_backend()) {
	case BAN_BACKEND_MATERIALADMIN: {
		MABanPlayer(0, client, MA_BAN_STEAM, get_ban_length(cheat), reason);
	}
	case BAN_BACKEND_SOURCEBANSPP: {
		SBPP_BanPlayer(0, client, get_ban_length(cheat), reason);
	}
	case BAN_BACKEND_SOURCEBANS: {
		SBBanPlayer(0, client, get_ban_length(cheat), reason);
	}
	default: {
		BanClient(client, get_ban_length(cheat), BANFLAG_AUTO, reason, reason, "lilac", 0);
	}
	}

	CreateTimer(5.0, timer_kick, GetClientUserId(client));
}

/* Which plugin bans go through, in priority order: MaterialAdmin,
 * SourceBans++, SourceBans (old), and lastly BaseBans. Also used by
 * lilac_ban_status, so what it reports is what actually happens. */
int lilac_get_ban_backend()
{
	if (icvar[CVAR_MA] && NATIVE_EXISTS("MABanPlayer"))
		return BAN_BACKEND_MATERIALADMIN;

	if (icvar[CVAR_SB]) {
		if (NATIVE_EXISTS("SBPP_BanPlayer"))
			return BAN_BACKEND_SOURCEBANSPP;

		if (NATIVE_EXISTS("SBBanPlayer"))
			return BAN_BACKEND_SOURCEBANS;
	}

	return BAN_BACKEND_BASEBANS;
}

public Action timer_kick(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);

	if (is_player_valid(client))
		KickClient(client, "%T", "kick_ban_generic", client);

	return Plugin_Continue;
}

int get_ban_length(int cheat)
{
	return ((ban_length_overwrite[cheat] <= -1) ? icvar[CVAR_BAN_LENGTH] : ban_length_overwrite[cheat]);
}

void get_player_log_angles(int client, int tick, bool latest, float writeto[3])
{
	int i = tick;

	if (latest) {
		i = playerinfo_index[client];
	}
	else {
		while (i < 0)
			i += CMD_LENGTH;
		while (i >= CMD_LENGTH)
			i -= CMD_LENGTH;
	}

	writeto[0] = playerinfo_angles[client][i][0];
	writeto[1] = playerinfo_angles[client][i][1];
	writeto[2] = playerinfo_angles[client][i][2];
}

void set_player_log_angles(int client, float ang[3], int tick)
{
	int i = tick;

	/* Normalize tick. */
	while (i < 0)
		i += CMD_LENGTH;
	while (i >= CMD_LENGTH)
		i -= CMD_LENGTH;

	playerinfo_angles[client][i][0] = ang[0];
	playerinfo_angles[client][i][1] = ang[1];
	playerinfo_angles[client][i][2] = ang[2];
}

/* True when f is neither inf nor NaN. Checks the IEEE 754 exponent bits
 * directly, since any comparison against NaN is false and can't be trusted. */
bool is_float_finite(float f)
{
	return (view_as<int>(f) & 0x7F800000) != 0x7F800000;
}

bool are_angles_finite(const float ang[3])
{
	return is_float_finite(ang[0]) && is_float_finite(ang[1]) && is_float_finite(ang[2]);
}

/* Formats a float with %.2f, or as "NaN"/"inf"/"-inf" when non-finite.
 * SM 1.12's %f has undefined output for inf, so never pass it one. */
void format_float_safe(char[] buffer, int maxlen, float f)
{
	int bits = view_as<int>(f);

	if (is_float_finite(f))
		FormatEx(buffer, maxlen, "%.2f", f);
	else if (bits & 0x007FFFFF)
		strcopy(buffer, maxlen, "NaN");
	else
		strcopy(buffer, maxlen, (bits < 0) ? "-inf" : "inf");
}

float finite_or_zero(float f)
{
	return is_float_finite(f) ? f : 0.0;
}

void aim_at_point(const float p1[3], const float p2[3], float writeto[3])
{
	SubtractVectors(p2, p1, writeto);
	GetVectorAngles(writeto, writeto);

	while (writeto[0] > 90.0)
		writeto[0] -= 360.0;
	while (writeto[0] < -90.0)
		writeto[0] += 360.0;
	while (writeto[1] > 180.0)
		writeto[1] -= 360.0;
	while (writeto[1] < -180.0)
		writeto[1] += 360.0;

	writeto[2] = 0.0;
}

float angle_delta(float []a1, float []a2)
{
	int normal = 5;
	float p1[3], p2[3], delta;

	p1[0] = a1[0];
	p2[0] = a2[0];
	p2[1] = a2[1];
	p1[1] = a1[1];

	/* We don't care about roll. */
	p1[2] = 0.0;
	p2[2] = 0.0;

	delta = GetVectorDistance(p1, p2);

	/* Normalize maximum 5 times, yaw can sometimes be odd. */
	while (delta > 180.0 && normal > 0) {
		normal--;
		delta = FloatAbs(delta - 360.0);
	}

	return delta;
}

#define LILAC_RAD2DEG 57.29577951308232

/* True angular distance between two view angles (great-circle).
 * Uses atan2(|cross|, dot) instead of acos(dot): acos loses precision
 * catastrophically near dot=1.0, which is exactly the sub-degree range
 * the smooth/jerk analysis operates in. */
float angle_delta_true(const float a1[3], const float a2[3])
{
    float f1[3], f2[3], p1[3], p2[3], cross[3];

    p1[0] = a1[0]; p1[1] = a1[1]; p1[2] = 0.0;
    p2[0] = a2[0]; p2[1] = a2[1]; p2[2] = 0.0;

    GetAngleVectors(p1, f1, NULL_VECTOR, NULL_VECTOR);
    GetAngleVectors(p2, f2, NULL_VECTOR, NULL_VECTOR);

    GetVectorCrossProduct(f1, f2, cross);

    return ArcTangent2(GetVectorLength(cross), GetVectorDotProduct(f1, f2)) * LILAC_RAD2DEG;
}

/* Legacy loss-only check. Kept for infected_damage, which checks raw damage
 * values — not distorted by latency or jitter, so the simpler loss-only
 * check is enough. Aimbot, aimlock and speedhack use lilac_network_vetoed()
 * instead, since a connection stall can distort all three. */
bool skip_due_to_loss(int client, float threshold = 0.5, NetFlow flow = NetFlow_Both)
{
	if (icvar[CVAR_LOSS_FIX])
		return GetClientAvgLoss(client, flow) > threshold;

	return false;
}

/* Number of usercmds actually recorded for this client in the last real
 * second. Ground truth for "is this client actually still sending commands
 * on schedule" — independent of whatever the engine's own loss/choke stats
 * claim, since those are derived from netchannel bookkeeping that can be
 * tampered with client-side without touching real command delivery. */
int lilac_recent_cmd_count(int client, float now)
{
	int count = 0;
	int ind = playerinfo_index[client];

	for (int i = 0; i < CMD_LENGTH; i++) {
		ind = wrap_index(ind - 1);

		float t = playerinfo_time_usercmd[client][ind];

		if (t == 0.0)
			break;

		if (now - t > 1.0)
			break;

		count++;
	}

	return count;
}

int time_to_ticks(float time)
{
	if (time > 0.0)
		return RoundToNearest(time / GetTickInterval());

	return 0;
}

int intabs(int num)
{
	return ((num < 0) ? num * -1 : num);
}

bool is_player_valid(int client)
{
	return (client >= 1 && client <= MaxClients
		&& IsClientConnected(client) && IsClientInGame(client)
		&& !IsClientSourceTV(client));
}

/* True while this player's camera is being held in forced external/3rd
 * person view — a standard engine mechanic (m_TimeForceExternalView), used
 * by third-person/emote/dance plugins and some scripted sequences. Not tied
 * to any specific plugin: whoever set the prop, the player isn't actually
 * controlling their view while it's active, so their sent viewangles sit
 * frozen in a way that would otherwise look identical to a real aimlock. */
bool lilac_camera_forced_external(int client)
{
	return GetEntPropFloat(client, Prop_Send, "m_TimeForceExternalView") > GetGameTime();
}

/* Readable team name, for reports. */
void lilac_team_name(int team, char[] buffer, int maxlen)
{
	if (team <= 0)
		strcopy(buffer, maxlen, "None");
	else if (team == 1)
		strcopy(buffer, maxlen, "Spectator");
	else if (g_bGame == Engine_Left4Dead2 || g_bGame == Engine_Left4Dead)
		strcopy(buffer, maxlen, (team == 2) ? "Survivor" : "Infected");
	else
		FormatEx(buffer, maxlen, "Team %d", team);
}

/* True while an L4D2 infected is in ghost state (m_isGhost). */
bool lilac_player_is_ghost(int client)
{
	return g_bGame == Engine_Left4Dead2
		&& GetClientTeam(client) == 3
		&& GetEntProp(client, Prop_Send, "m_isGhost") != 0;
}

void lilac_save_player_details(int client, const char[] details)
{
	Format(playerinfo_detected[client], sizeof(playerinfo_detected[]), "%s", details);
}

void lilac_forward_client_cheat(int client, int cheat)
{
	int dummy;

	if (forwardhandle == null)
		return;

	Call_StartForward(forwardhandle);
	Call_PushCell(client);
	Call_PushCell(cheat);
	Call_Finish(dummy);
}

void lilac_forward_client_ban(int client, int cheat)
{
	int dummy;

	if (forwardhandleban == null)
		return;

	Call_StartForward(forwardhandleban);
	Call_PushCell(client);
	Call_PushCell(cheat);
	Call_Finish(dummy);
}

bool lilac_forward_allow_cheat_detection(int client, int cheat)
{
	Action result = Plugin_Continue;

	if (forwardhandleallow == null)
		return true;

	Call_StartForward(forwardhandleallow);
	Call_PushCell(client);
	Call_PushCell(cheat);
	Call_Finish(result);

	if (result == Plugin_Continue)
		return true;

	return false;
}

public int lilac_native_get_detected_infos(Handle hPlugin, int numParams)
{
	int client = GetNativeCell(1);
	if (!is_player_valid(client))
		return -1;

	if (!playerinfo_detected[client][0])
		return -1;

	int maxlen = GetNativeCell(3);
	if (SetNativeString(2, playerinfo_detected[client], maxlen) == SP_ERROR_NONE)
		return 1;

	return -1;
}

/* Returns true while the server TPS counts as abnormal (stall / catch-up burst).
 * 变速检测已不再使用它（SPEEDHACK_LAG_PAUSE_ENABLED = 0，暂停功能不编译）；
 * 现在只剩 tickbase 保护的日志抑制与网络 telemetry 在读。 */
bool lilac_server_is_lagging()
{
    return (GetEngineTime() < g_fServerLagPauseUntil);
}

/* Logs the pause once per lag episode. Called from timer_check_speedhack
 * when lilac_server_is_lagging() is true.
 * 仅当内部开关 SPEEDHACK_LAG_PAUSE_ENABLED = 1 时才会编译进来。 */
#if SPEEDHACK_LAG_PAUSE_ENABLED
void lilac_server_lag_log_once()
{
    if (g_bServerLagLogged)
        return;

    g_bServerLagLogged = true;

    if (!icvar[CVAR_LOG])
        return;

    char date[64];
    FormatTime(date, sizeof(date), dateformat, GetTime());

    FormatEx(line_buffer, sizeof(line_buffer),
        "%s [版本 %s] 变速检测已暂停：服务器 TPS 异常 | tps: %d（基线 ~%d @ %dtick）| 暂停 %.1fs",
        date, PLUGIN_VERSION,
        g_iTriggerTPS,
        RoundToNearest(g_fTPSBaselineEWMA),
        g_iServerTickrate,
        g_fServerLagPauseUntil - GetEngineTime());

    lilac_log(true);
}

/* Resets the log latch when the pause ends. */
void lilac_server_lag_reset_log()
{
    g_bServerLagLogged = false;
}
#endif

/* ===== Tickbase Fix (shared helper) =====
 * Clamps client tickbase when it deviates too far from the server tick.
 * Used by: speedhack module (grace period), infected_damage module (exploit prevention).
 *
 * Call lilac_tickbase_fix(client) from OnPlayerRunCmd or equivalent per-tick hook,
 * gated by CVAR_ENABLE plus at least one of the two consumers (CVAR_SPEEDHACK,
 * CVAR_INFECTED_DMG) — no point paying the clamp cost if neither cares. */

void lilac_tickbase_fix_reset_client(int client)
{
    g_flTickbaseLastLog[client]      = 0.0;
    g_flTickbaseAheadLastLog[client] = 0.0;
    g_flTickbaseRunawayStart[client] = 0.0;
    g_flTickbaseRunawayLast[client]  = 0.0;
    g_flTickbaseRunawayBaseTime[client] = 0.0;
    g_iTickbaseRunawayBase[client] = 0;
    g_bTickbaseRunawayConfirmed[client] = false;
    g_bTickbaseRunawayAlerted[client] = false;
}

void lilac_tickbase_fix(int client)
{
    if (!icvar[CVAR_SPEEDHACK] && !icvar[CVAR_INFECTED_DMG])
        return;

    if (!IsPlayerAlive(client))
        return;

    if (tick_rate <= 0)
        return;

    int serverTick = GetGameTickCount();
    int diff       = serverTick - GetEntProp(client, Prop_Send, "m_nTickBase");
    int clamp_threshold = tick_rate * TICKBASE_CLAMP_SECS;

    /* Client tickbase is behind — backlog being built up. */
    if (diff > clamp_threshold)
    {
        SetEntProp(client, Prop_Send, "m_nTickBase", serverTick);
        lilac_tickbase_fix_log(client, diff);
        return;
    }

    /* Ahead case: NOT clamped. Correcting it used to rubber-band legit
     * low-FPS/stuttering players, so this is log-only for now. */
    int ahead_threshold = tick_rate * TICKBASE_AHEAD_LOG_SECS;

    if (-diff > ahead_threshold)
        lilac_tickbase_fix_log_ahead(client, -diff);
}

static void lilac_tickbase_fix_log(int client, int magnitude)
{
    if (!icvar[CVAR_LOG] || magnitude <= tick_rate * TICKBASE_LOG_SECS)
        return;

    /* A fresh spawn naturally leaves a stale m_nTickBase behind (e.g. an
     * infected that just finished its respawn/ghost wait) — this is not
     * manipulation, so don't log it as such. The clamp above still applies. */
    if (GetGameTime() - playerinfo_time_teleported[client] < 3.0)
        return;

    /* A server-wide stall can push every client's tickbase out of sync too,
     * same root cause as the speedhack lag pause. Not manipulation either. */
    if (lilac_server_is_lagging())
        return;

    float now = GetGameTime();
    if (now - g_flTickbaseLastLog[client] < 5.0)
        return;

    g_flTickbaseLastLog[client] = now;
    lilac_log_setup_client(client);

    Format(line_buffer, sizeof(line_buffer),
        "%s tickbase（时钟基准）异常：落后 %d tick（%.1fs），已钳制。",
        line_buffer, magnitude, float(magnitude) * GetTickInterval());

    lilac_log(true);

    if (icvar[CVAR_LOG_EXTRA])
        lilac_log_extra(client);
}

static bool lilac_tickbase_runaway_active(int client)
{
    return g_flTickbaseRunawayLast[client] > 0.0
        && GetEngineTime() - g_flTickbaseRunawayLast[client] < TICKBASE_RUNAWAY_GRACE_SECS;
}

/* True while the client's tickbase is far ahead of the server and growing,
 * which is what the exploit does. A stable lead is not manipulation. */
bool lilac_tickbase_runaway(int client)
{
    return g_bTickbaseRunawayConfirmed[client] && lilac_tickbase_runaway_active(client);
}

static void lilac_tickbase_runaway_mark(int client, int magnitude)
{
    float now = GetEngineTime();

    /* Quiet for a while, so this is a new episode. */
    if (!lilac_tickbase_runaway_active(client)) {
        g_flTickbaseRunawayStart[client] = now;
        g_flTickbaseRunawayBaseTime[client] = now;
        g_iTickbaseRunawayBase[client] = magnitude;
        g_bTickbaseRunawayConfirmed[client] = false;
        g_bTickbaseRunawayAlerted[client] = false;
    }

    g_flTickbaseRunawayLast[client] = now;

    if (!g_bTickbaseRunawayConfirmed[client]) {
        if (magnitude >= g_iTickbaseRunawayBase[client] + tick_rate * TICKBASE_RUNAWAY_GROWTH_SECS) {
            g_bTickbaseRunawayConfirmed[client] = true;
        }
        else if (now - g_flTickbaseRunawayBaseTime[client] > TICKBASE_RUNAWAY_GROWTH_WINDOW) {
            /* Not growing fast enough, measure again from here. */
            g_flTickbaseRunawayBaseTime[client] = now;
            g_iTickbaseRunawayBase[client] = magnitude;
        }
    }

    if (!g_bTickbaseRunawayConfirmed[client]
        || g_bTickbaseRunawayAlerted[client]
        || magnitude < tick_rate * TICKBASE_RUNAWAY_ALERT_SECS
        || now - g_flTickbaseRunawayStart[client] < 1.0)
        return;

    g_bTickbaseRunawayAlerted[client] = true;

    char sDetails[128];
    FormatEx(sDetails, sizeof(sDetails), "Ahead: %d ticks (%.1fs) | Sustained: %.1fs",
        magnitude, float(magnitude) * GetTickInterval(), now - g_flTickbaseRunawayStart[client]);

    lilac_discord_report_details(client, DISCORD_CHEAT_TICKBASE, DISCORD_SUSPECT, sDetails);
}

/* Calibration-only. Can grow a detection counter/ban path once real data
 * shows where a stutter ends and sustained abuse begins. */
static void lilac_tickbase_fix_log_ahead(int client, int magnitude)
{
    if (GetGameTime() - playerinfo_time_teleported[client] < 3.0)
        return;

    if (lilac_server_is_lagging())
        return;

    if (magnitude > tick_rate * TICKBASE_RUNAWAY_SECS
        && GetEngineTime() >= g_fServerLagPauseUntil + TICKBASE_RUNAWAY_LAG_GRACE_SECS)
        lilac_tickbase_runaway_mark(client, magnitude);

    if (!icvar[CVAR_LOG])
        return;

    /* Real time: game time is the player's own clock here. */
    float now = GetEngineTime();
    if (now - g_flTickbaseAheadLastLog[client] < 5.0)
        return;

    g_flTickbaseAheadLastLog[client] = now;
    lilac_log_setup_client(client);

    Format(line_buffer, sizeof(line_buffer),
        "%s tickbase（时钟基准）异常：超前 %d tick（%.1fs），未钳制（仅监测）。",
        line_buffer, magnitude, float(magnitude) * GetTickInterval());

    lilac_log(true);

    if (icvar[CVAR_LOG_EXTRA])
        lilac_log_extra(client);
}