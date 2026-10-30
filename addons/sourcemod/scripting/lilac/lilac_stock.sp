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

void lilac_warn_admins(int client, int cheat, int detections)
{
	char name[MAX_NAME_LENGTH];
	char type[16];
	int admins[MAXPLAYERS + 1];
	int n = 0;
	
	/* We'll assume the player is valid, as this function
	 * should never be called on invalid clients in the first place. */
	/* if (!is_player_valid(client))
		return; */
	
	/* Setup a list of admins. */
	for (int i = 1; i <= MaxClients; i++) {
		if (!is_player_valid(i))
			continue;
		
		if (IsFakeClient(i))
			continue;
		
		if (is_player_admin(i))
			admins[n++] = i;
	}
	
	/* No admins are on. */
	if (!n)
		return;
	
	switch (cheat) {
	case CHEAT_BHOP:      { strcopy(type, sizeof(type), "Bhop"); }
	case CHEAT_AIMBOT:    { strcopy(type, sizeof(type), "Aimbot"); }
	case CHEAT_AIMLOCK:   { strcopy(type, sizeof(type), "Aimlock"); }
	case CHEAT_SPEEDHACK:     { strcopy(type, sizeof(type), "Speedhack"); }
	case CHEAT_INFECTED_DMG:  { strcopy(type, sizeof(type), "Infected Damage Exploit"); }
	case CHEAT_SURVIVOR_DMG:  { strcopy(type, sizeof(type), "Survivor Damage Exploit"); }
	/* Macros have their own warning system. */
	default: { return; }
	}
	
	if (!GetClientName(client, name, sizeof(name)))
		strcopy(name, sizeof(name), "[NAME_ERROR]");
	
	for (int i = 0; i < n; i++)
		PrintToChat(admins[i],
			"[Lilac] %T", "admin_chat_warning_generic",
			admins[i], name, type, detections);
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
		Format(matchid_part, sizeof(matchid_part), " | MatchID: %s", matchid);

	FormatEx(line_buffer, sizeof(line_buffer),
		"%s [Version %s] {Name: \"%N\" | SteamID: %s | IP: %s%s}",
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
		FormatEx(burst, sizeof(burst), ", Burst={%s}", stats);
	}

	/* Latency in ms, Loss/Choke in % — same scale and precision as
	 * lilac_network_format(), instead of raw 0-1 fractions at the default
	 * 6 decimal places. */
	FormatEx(line_buffer, sizeof(line_buffer),
		"\tServerTick={%d}, Pos={%.0f,%.0f,%.0f}, Angles={%.5f,%.5f,%.5f}, Map=\"%s\", Team={%d}, Weapon=\"%s\", Latency={Inc:%.1f,Out:%.1f}, Loss={Inc:%.1f,Out:%.1f}, Choke={Inc:%.1f,Out:%.1f}%s, ConnectionTime={%.1f seconds}, GameTime={%.1f seconds}",
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
			"%s, DemoTick={%d}", line_buffer, demo_tick);

	lilac_log(false);
}

void lilac_log(bool cleanup)
{
	Handle file = OpenFile(log_file, "a");

	if (file == null) {
		PrintToServer("[Lilac] Cannot open log file.");
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
        PrintToServer("[Lilac] Cannot open smooth telemetry log file.");
        return;
    }

    char date[512];
    FormatTime(date, sizeof(date), dateformat, GetTime());

    WriteFileLine(file,
        "=========[Notice]=========\n\
Smooth Telemetry Log — Little Anti-Cheat %s\n\
Created: %s\n\n\
This log contains telemetry data for calibrating smooth aimbot detection thresholds.\n\
Smooth-Telemetry fields: Name | SteamID | IP | N | CV | Jerk | TotalDelta | FinalDist\n\
Bypass-Telemetry fields: Name | SteamID | IP | N | CV | Jerk | TotalDelta | FinalDist | PreConverge | PostConverge\n\
These are NOT detections — data is logged when values are near detection thresholds.\n\
Use this data to calibrate thresholds before enabling bans.\n\n",
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
        PrintToServer("[Lilac] Cannot open smooth telemetry log file.");
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
            "%s [Version %s] {Name: \"%N\" | SteamID: %s | IP: %s} Smooth-Telemetry | N: %d | CV: %.3f | Jerk: %.4f | TotalDelta: %.2f | FinalDist: %.2f",
            date, PLUGIN_VERSION, client, steamid, ip,
            sm_n, sm_cv, sm_avg_jerk, sm_total_delta, final_dist);
    }
    else {
        /* Bypass telemetry entry — includes pre/post convergence ratios. */
        FormatEx(telemetry_buffer, sizeof(telemetry_buffer),
            "%s [Version %s] {Name: \"%N\" | SteamID: %s | IP: %s} Bypass-Telemetry | N: %d | CV: %.3f | Jerk: %.4f | TotalDelta: %.2f | FinalDist: %.2f | PreConverge: %.2f | PostConverge: %.2f",
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
        PrintToServer("[Lilac] Cannot open speedhack shadow log file.");
        return;
    }

    char date[512];
    FormatTime(date, sizeof(date), dateformat, GetTime());

    WriteFileLine(file, "=========[Notice]=========");
    WriteFileLine(file, "Speedhack Shadow Log - Little Anti-Cheat %s", PLUGIN_VERSION);
    WriteFileLine(file, "Created: %s", date);
    WriteFileLine(file, "");
    WriteFileLine(file, "This log is for calibration. Nothing here is a detection or a ban.");
    WriteFileLine(file, "It only covers players with real choke of 10 percent or more, which the speedhack never bans today.");
    WriteFileLine(file, "Each player is compared with his own normal command rate, learned in his first 30 seconds.");
    WriteFileLine(file, "WOULD BAN: the per-player rule would have banned this player.");
    WriteFileLine(file, "not banned: the player went over the limit, but it looks normal for him.");
    WriteFileLine(file, "Fields: Detection | CmdsPerSec | Normal | Contrast | MedianContrast | AvgChoke | Observed | OthersFlagged");
    WriteFileLine(file, "OthersFlagged: other players over the limit in the last 3 seconds. Several at once points to a server event, not cheating.");
    WriteFileLine(file, "");

    CloseHandle(file);
}

void lilac_log_speedhack_shadow(int client, const char[] message)
{
    if (!icvar[CVAR_LOG] || !(icvar[CVAR_TELEMETRY] & TELEMETRY_SPEEDHACK))
        return;

    Handle file = OpenFile(speedhack_shadow_log_file, "a");

    if (file == null) {
        PrintToServer("[Lilac] Cannot open speedhack shadow log file.");
        return;
    }

    lilac_log_setup_client(client);
    Format(line_buffer, sizeof(line_buffer), "%s speedhack shadow: %s", line_buffer, message);

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
        PrintToServer("[Lilac] Cannot open damage clock log file.");
        return;
    }

    char date[512];
    FormatTime(date, sizeof(date), dateformat, GetTime());

    WriteFileLine(file, "=========[Notice]=========");
    WriteFileLine(file, "Damage Clock Log - Little Anti-Cheat %s", PLUGIN_VERSION);
    WriteFileLine(file, "Created: %s", date);
    WriteFileLine(file, "");
    WriteFileLine(file, "This log is for calibration. Nothing here is a detection or a ban.");
    WriteFileLine(file, "A line is written when a survivor's damage to a Tank in one second goes over the weapon limit on the real clock.");
    WriteFileLine(file, "GameClock: damage in 1 second on the player's own game clock (what the survivor damage module uses).");
    WriteFileLine(file, "RealClock: damage in 1 second of real time.");
    WriteFileLine(file, "ClockAhead: how far the player's clock is ahead of the server, in seconds.");
    WriteFileLine(file, "Cmds1s: commands received from the player in the last second (normal is about the tickrate).");
    WriteFileLine(file, "Fields: Weapon | Threshold | GameClock | RealClock | ClockAhead | Cmds1s | ServerLag | network info");
    WriteFileLine(file, "");

    CloseHandle(file);
}

void lilac_log_damage_clock(int client, const char[] message)
{
    if (!icvar[CVAR_LOG] || !(icvar[CVAR_TELEMETRY] & TELEMETRY_DAMAGE))
        return;

    Handle file = OpenFile(damage_clock_log_file, "a");

    if (file == null) {
        PrintToServer("[Lilac] Cannot open damage clock log file.");
        return;
    }

    lilac_log_setup_client(client);
    Format(line_buffer, sizeof(line_buffer), "%s damage clock: %s", line_buffer, message);

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
        PrintToServer("[Lilac] Cannot open angle metric log file.");
        return;
    }

    char date[512], steamid[64], buf[768];
    FormatTime(date, sizeof(date), dateformat, GetTime());
    GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid), true);

    FormatEx(buf, sizeof(buf),
        "%s {Name: \"%N\" | SteamID: %s} AngleMetric | Ticks: %d | Pitch: %.1f | \
Delta: %.2f/%.2f | TotalDelta: %.2f/%.2f | FinalDist: %.2f/%.2f | Flags: %d/%d | Ratio: %.3f%s",
        date, client, steamid, ticks, shot_pitch,
        eu_delta, tr_delta, eu_total, tr_total, eu_final, tr_final,
        eu_flags, tr_flags,
        (tr_total > 0.01) ? (eu_total / tr_total) : 0.0,
        (eu_flags != tr_flags) ? " <<< DISAGREE" : "");

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
"=========[Notice]=========\n\
Thank you for installing Little Anti-Cheat %s!\n\
Just a few notes about this Anti-Cheat:\n\n\
If a player is logged as \"suspected\" of using cheats, they are not necessarily cheating.\n\
If the suspicions logged are few and rare, they are likely false positives.\n\
An automatic ban is triggered by 5 or more \"suspicions\" or by one \"detection\".\n\
If you think a ban may be incorrect, please do not hesitate to let me know.\n\n\
That is all, have a wonderful day~\n\n\n", PLUGIN_VERSION);
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

bool is_player_admin(int client)
{
	return CheckCommandAccess(client, "", ADMFLAG_GENERIC | ADMFLAG_KICK | ADMFLAG_SLAY, true);
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

/* Returns true if speedhack detection should currently be paused. */
bool lilac_server_is_lagging()
{
    return (GetEngineTime() < g_fServerLagPauseUntil);
}

/* Logs the pause once per lag episode. Called from timer_check_speedhack
 * when lilac_server_is_lagging() is true. */
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
        "%s [Version %s] speedhack detection paused: server tps abnormal | tps: %d (baseline ~%d @ %dtick) | paused %.1fs",
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
        "%s tickbase manipulation: %d ticks (%.1fs) behind. Clamped.",
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
        "%s tickbase manipulation: %d ticks (%.1fs) ahead. Not clamped (monitoring only).",
        line_buffer, magnitude, float(magnitude) * GetTickInterval());

    lilac_log(true);

    if (icvar[CVAR_LOG_EXTRA])
        lilac_log_extra(client);
}