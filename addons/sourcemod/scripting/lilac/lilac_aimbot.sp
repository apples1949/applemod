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

static int aimbot_detection[MAXPLAYERS + 1];
static int aimbot_autoshoot[MAXPLAYERS + 1];
static int aimbot_timertick[MAXPLAYERS + 1];
static int aimbot_smooth_streak[MAXPLAYERS + 1];

void lilac_aimbot_reset_client(int client)
{
	aimbot_detection[client] = 0;
	aimbot_autoshoot[client] = 0;
	aimbot_timertick[client] = 0;
	aimbot_smooth_streak[client] = 0;
}

int lilac_aimbot_get_client_detections(int client)
{
	return aimbot_detection[client];
}

public Action event_player_death(Event event, const char[] name, bool dontBroadcast)
{
	char wep[64];
	int attackerid;
	int victimid;
	int client;
	
	if (!icvar[CVAR_ENABLE])
		return Plugin_Continue;
	
	attackerid = GetEventInt(event, "attacker", -1);
	victimid = GetEventInt(event, "userid", -1);
	client = GetClientOfUserId(victimid);
	
	if (!is_player_valid(client))
		return Plugin_Continue;

	/* This prevents running multiple aimbot checks on the same tick.
	 * This can happen with explosives, like some projectiles.
	 * This variable gets set in the "shared event" function. */
	int attacker_client = GetClientOfUserId(attackerid);
	if (is_player_valid(attacker_client) && aimbot_timertick[attacker_client] == GetGameTickCount())
		return Plugin_Continue;

	/* Ignore kills performed with grenades. */
	GetEventString(event, "weapon", wep, sizeof(wep));
	if (strcmp(wep, "hegrenade") == 0)
		return Plugin_Continue;
	
	event_death_shared(attackerid,
		attacker_client,
		client, false);
	
	return Plugin_Continue;
}

void event_death_shared(int userid, int client, int victim, bool skip_delta)
{
	DataPack pack;
	float killpos[3], deathpos[3];
	int skip_snap = 0;

	if (client == victim
		|| !is_player_valid(client)
		/* || !is_player_valid(victim) Already checked. */
		|| IsFakeClient(client)
		|| !IsPlayerAlive(client)
		|| playerinfo_banned_flags[client][CHEAT_AIMBOT]
		|| GetClientTime(client) < 10.1)
		return;

	if (icvar[CVAR_AIMLOCK_LIGHT])
		lilac_aimlock_light_test(client);

	if (!icvar[CVAR_AIMBOT])
		return;

	/* Prevent multiple aimbot timer checks on the same tick. */
	aimbot_timertick[client] = GetGameTickCount();

	GetClientEyePosition(client, killpos);
	GetClientEyePosition(victim, deathpos);

	if (GetVectorDistance(killpos, deathpos) < 350.0 || skip_delta)
		skip_snap = 1;

	CreateDataTimer(0.5, timer_check_aimbot, pack);
	pack.WriteCell(userid);
	pack.WriteCell(skip_snap);
	pack.WriteCell(playerinfo_index[client]); /* Fallback to this tick if the shot isn't found. */
	pack.WriteFloat(killpos[0]);
	pack.WriteFloat(killpos[1]);
	pack.WriteFloat(killpos[2]);
	pack.WriteFloat(deathpos[0]);
	pack.WriteFloat(deathpos[1]);
	pack.WriteFloat(deathpos[2]);
}

public Action timer_check_aimbot(Handle timer, DataPack pack)
{
    int ind;
    int client;
    int fallback;
    int shotindex = -1;
    int detected = 0;
    float delta = 0.0;
    float tdelta = 0.0;
    float total_delta = 0.0;
    float aimdist, laimdist;
    float ideal[3], ang[3], lang[3];
    float killpos[3], deathpos[3];
    bool skip_snap = false;
    bool skip_autoshoot = false;
    bool skip_repeat = false;
    int total_analysis_ticks = 0;
    int converge_ticks = 0;

    int   sm_n = 0;
    int   sm_jerk_count = 0;
    float sm_sum = 0.0;
    float sm_sq  = 0.0;
    float sm_total_jerk = 0.0;
    float sm_last_tdelta = -1.0;
    float sm_total_delta = 0.0;

    #if LILAC_ANGLE_METRIC_DEBUG
        float tr_aimdist = 0.0, tr_laimdist = 0.0;
        float tr_delta = 0.0, tr_tdelta = 0.0, tr_total_delta = 0.0;
        int   tr_detected = 0;
        bool  tr_on = (icvar[CVAR_TELEMETRY] & TELEMETRY_AIMBOT) != 0;
    #endif

    /* Declared at function scope so bypass telemetry can access them
     * without recomputing inside the smooth block. */
    float sm_cv = 99.0;
    float sm_avg_jerk = 0.0;

    bool flag_smooth = false;
    bool flag_jitter = false;

    pack.Reset();
    client = GetClientOfUserId(pack.ReadCell());
    skip_snap = pack.ReadCell();
    fallback = pack.ReadCell();
    killpos[0] = pack.ReadFloat();
    killpos[1] = pack.ReadFloat();
    killpos[2] = pack.ReadFloat();
    deathpos[0] = pack.ReadFloat();
    deathpos[1] = pack.ReadFloat();
    deathpos[2] = pack.ReadFloat();

    /* Killer may have left the game, cancel. */
    if (!is_player_valid(client))
        return Plugin_Continue;

    /* Locate when the shot was fired. */
    ind = playerinfo_index[client];
    for (int i = 0; i < CMD_LENGTH - time_to_ticks(0.5 + 0.5 + 0.1); i++) {
        ind = wrap_index(ind - 1);

        if (GetGameTime() - playerinfo_time_usercmd[client][ind] < 0.3)
            continue;

        if (GetGameTime() - playerinfo_time_usercmd[client][ind] > 2.0)
            break;

        if ((playerinfo_actions[client][ind] & ACTION_SHOT)) {
            shotindex = ind;
            break;
        }
    }

    /* Shot not found, use fallback. */
    if (shotindex == -1) {
        shotindex = fallback;

        if (playerinfo_index[client] == fallback) {
            skip_autoshoot = true;
            skip_repeat = true;
        }
    }
    else {
        /* Don't detect the same shot twice. */
        playerinfo_actions[client][shotindex] = 0;
    }

    if (skip_snap)
        skip_repeat = true;

    float timeDiff = playerinfo_time_usercmd[client][shotindex] - playerinfo_time_teleported[client];
    if (-0.1 < timeDiff && timeDiff < 0.5 + 0.1)
        skip_snap = true;

    if (skip_snap)
        skip_repeat = true;

    /* Aimsnap and total delta test. */
    if (skip_snap == false) {
        aim_at_point(killpos, deathpos, ideal);

        ind = shotindex;
        float tick_scale = GetTickInterval() / (1.0 / 30.0);
        float min_total_delta = 4.0 * tick_scale;
        float min_tdelta = 0.1 * tick_scale;

        /* Check angle history 0.5 seconds prior to a shot. */
        for (int i = 0; i < time_to_ticks(0.5); i++) {
            ind = wrap_index(ind - 1);

            /* We're looking back further than 0.5 seconds prior to the shot, abort. */
            if (playerinfo_time_usercmd[client][shotindex] - playerinfo_time_usercmd[client][ind] > 0.5)
                break;

            laimdist = angle_delta(playerinfo_angles[client][ind], ideal);
            get_player_log_angles(client, ind, false, ang);

            #if LILAC_ANGLE_METRIC_DEBUG
                if (tr_on)
                    tr_laimdist = angle_delta_true(playerinfo_angles[client][ind], ideal);
            #endif

            /* Skip first iteration as we need angle deltas. */
            if (i) {
                tdelta = angle_delta(lang, ang);

                #if LILAC_ANGLE_METRIC_DEBUG
                    if (tr_on) {
                        tr_tdelta = angle_delta_true(lang, ang);
                        if (tr_tdelta > tr_delta)
                            tr_delta = tr_tdelta;
                        tr_total_delta += tr_tdelta;

                        /* Would the same rules have fired with the correct metric? */
                        if (tr_aimdist < tr_laimdist * 0.2 && tr_tdelta > 10.0)
                            tr_detected |= AIMBOT_FLAG_SNAP;
                        if (tr_aimdist < tr_laimdist * 0.1 && tr_tdelta > 5.0)
                            tr_detected |= AIMBOT_FLAG_SNAP2;
                    }
                #endif

                /* Store largest delta. */
                if (tdelta > delta)
                    delta = tdelta;

                total_delta += tdelta;

                if (aimdist < laimdist * 0.2 && tdelta > 10.0)
                    detected |= AIMBOT_FLAG_SNAP;

                if (aimdist < laimdist * 0.1 && tdelta > 5.0)
                    detected |= AIMBOT_FLAG_SNAP2;

                total_analysis_ticks++;

                /* Count ticks converging toward ideal — used for pre/post bypass ratio. */
                if (laimdist > aimdist)
                    converge_ticks++;

                if (laimdist > aimdist && tdelta > min_tdelta) {
                    sm_sum += tdelta;
                    sm_sq  += tdelta * tdelta;
                    sm_total_delta += tdelta;

                    if (sm_last_tdelta >= 0.0) {
                        sm_total_jerk += FloatAbs(tdelta - sm_last_tdelta);
                        sm_jerk_count++;
                    }
                    sm_last_tdelta = tdelta;
                    sm_n++;
                } else {
                    sm_last_tdelta = -1.0;
                }
            }

            lang = ang;
            aimdist = laimdist;

            #if LILAC_ANGLE_METRIC_DEBUG
                tr_aimdist = tr_laimdist;
            #endif
        }

        /* Calculated once here — used by both smooth block and bypass telemetry below. */
        float final_dist = angle_delta(playerinfo_angles[client][shotindex], ideal);

        #if LILAC_ANGLE_METRIC_DEBUG
            /* Log only what is worth calibrating: disagreements, real detections,
            * and high-movement shots. Everything else would flood the file. */
            if (tr_on && ((detected & (AIMBOT_FLAG_SNAP | AIMBOT_FLAG_SNAP2)) != tr_detected
                || detected
                || total_delta > 90.0))
            {
                float tr_final_dist = angle_delta_true(playerinfo_angles[client][shotindex], ideal);

                lilac_log_angle_metric(client,
                    delta, tr_delta,
                    total_delta, tr_total_delta,
                    final_dist, tr_final_dist,
                    playerinfo_angles[client][shotindex][0],
                    detected & (AIMBOT_FLAG_SNAP | AIMBOT_FLAG_SNAP2), tr_detected,
                    total_analysis_ticks);
            }
        #endif

        /* Smooth aimbot mathematical validation. */
        if (sm_n >= 5 && sm_jerk_count >= 3 && sm_total_delta >= min_total_delta) {
            float sm_mean = sm_sum / float(sm_n);
            float sm_var  = (sm_sq / float(sm_n)) - (sm_mean * sm_mean);
            sm_cv       = (sm_mean > 0.0) ? (SquareRoot(FloatAbs(sm_var)) / sm_mean) : 99.0;
            sm_avg_jerk = sm_total_jerk / float(sm_jerk_count);

            /* Log telemetry to a separate file for threshold calibration. */
            if (sm_cv < 0.28 && sm_avg_jerk < 0.04)
                lilac_log_smooth_telemetry(client, sm_n, sm_cv, sm_avg_jerk, sm_total_delta, final_dist);

            /* Counts towards a detection once it repeats, see below. */
            if (sm_cv < 0.20 && sm_avg_jerk < 0.022 && final_dist < 5.0)
                flag_smooth = true;
        }

        int post_converge_ticks = 0;
        int post_total_ticks    = 0;
        {
            float post_laimdist = final_dist;
            float post_aimdist;

            int post_ind = shotindex;

            for (int i = 0; i < time_to_ticks(0.3); i++) {
                post_ind = wrap_index(post_ind + 1);

                /* Don't read past the current tick. */
                if (post_ind == playerinfo_index[client])
                    break;

                /* Stop if we've moved more than 0.3s forward from the shot. */
                if (playerinfo_time_usercmd[client][post_ind] - playerinfo_time_usercmd[client][shotindex] > 0.3)
                    break;

                /* Uninitialized slot — stop. */
                if (playerinfo_time_usercmd[client][post_ind] == 0.0)
                    break;

                post_aimdist = angle_delta(playerinfo_angles[client][post_ind], ideal);

                if (post_laimdist > post_aimdist)
                    post_converge_ticks++;

                post_total_ticks++;
                post_laimdist = post_aimdist;
            }
        }

        /* Bypass telemetry — log only, no detection yet. */
        if (final_dist < 5.0
            && total_analysis_ticks >= time_to_ticks(0.2)
            && post_total_ticks >= time_to_ticks(0.1))
        {
            float pre_ratio  = float(converge_ticks)      / float(total_analysis_ticks);
            float post_ratio = float(post_converge_ticks) / float(post_total_ticks);

            lilac_log_smooth_telemetry(client, sm_n, sm_cv, sm_avg_jerk, sm_total_delta, final_dist,
                pre_ratio, post_ratio);
        }

        float jitter_threshold = 3.5 * tick_scale;
        if (total_analysis_ticks >= time_to_ticks(0.25)
            && total_delta / float(total_analysis_ticks) > jitter_threshold
            && angle_delta(playerinfo_angles[client][shotindex], ideal) < 5.0)
            flag_jitter = true;

        /* Smooth/Jitter alone aren't calibrated enough to ban on the first
         * hit. Only count them once they repeat, same idea as Autoshoot. */
        if (flag_smooth || flag_jitter) {
            if (detected || ++aimbot_smooth_streak[client] > 1)
                detected |= (flag_smooth ? AIMBOT_FLAG_SMOOTH : 0) | (flag_jitter ? AIMBOT_FLAG_JITTER : 0);
        }
        else {
            aimbot_smooth_streak[client] = 0;
        }
    }

    bool net_vetoed = lilac_network_vetoed(client);

    /* Angle-repeat test. */
    if (skip_repeat == false) {
        float post_ang[3], shot_ang_c[3];
        get_player_log_angles(client, wrap_index(shotindex - 1), false, ang);
        get_player_log_angles(client, wrap_index(shotindex + 1), false, post_ang);
        float surround_delta = angle_delta(ang, post_ang);
        get_player_log_angles(client, shotindex, false, shot_ang_c);

        if (surround_delta < 10.0 && angle_delta(ang, shot_ang_c) > 0.5
            && angle_delta(ang, shot_ang_c) > surround_delta * 5.0)
            detected |= AIMBOT_FLAG_REPEAT;

        /* Extended pre-shot window check. */
        {
            float pre2[3], pre3[3];
            get_player_log_angles(client, wrap_index(shotindex - 2), false, pre2);
            get_player_log_angles(client, wrap_index(shotindex - 3), false, pre3);

            float pre_spread = (angle_delta(ang, pre2) + angle_delta(pre2, pre3)) * 0.5;
            float shot_dev = angle_delta(ang, shot_ang_c);

            if (pre_spread < 2.5 && shot_dev > 12.0
                && angle_delta(shot_ang_c, ideal) < 5.0)
                detected |= AIMBOT_FLAG_REPEAT;
        }
    }

    /* Autoshoot test. */
    if (skip_autoshoot == false && icvar[CVAR_AIMBOT_AUTOSHOOT]) {
        int tmp = 0;
        ind = wrap_index(shotindex + 2);
        for (int i = 0; i < 5; i++) {
            ind = wrap_index(ind);

            if ((playerinfo_buttons[client][ind] & IN_ATTACK))
                tmp++;

            ind = wrap_index(ind - 1);
        }

        if (tmp == 1) {
            if (detected || ++aimbot_autoshoot[client] > 1)
                detected |= AIMBOT_FLAG_AUTOSHOOT;
        }
        else if (tmp == 2 && detected) {
            detected |= AIMBOT_FLAG_AUTOSHOOT;
        }
        else {
            aimbot_autoshoot[client] = 0;
        }
    }

    int log_flags = detected;
    if (flag_smooth) log_flags |= AIMBOT_FLAG_SMOOTH;
    if (flag_jitter) log_flags |= AIMBOT_FLAG_JITTER;

    if (detected || total_delta > AIMBOT_MAX_TOTAL_DELTA)
        lilac_detected_aimbot(client, delta, total_delta, log_flags, net_vetoed);

    return Plugin_Continue;
}

static void lilac_detected_aimbot(int client, float delta, float td, int flags, bool net_vetoed)
{
    if (playerinfo_banned_flags[client][CHEAT_AIMBOT])
        return;

    if (lilac_forward_allow_cheat_detection(client, CHEAT_AIMBOT) == false)
        return;

    char sNet[256];
    sNet[0] = '\0';

    if (net_vetoed) {
        char sNetData[192];
        lilac_network_format(client, sNetData, sizeof(sNetData));
        Format(sNet, sizeof(sNet), " | NETWORK VETO {%s}", sNetData);
    }

    char sDetails[512];
    Format(sDetails, sizeof(sDetails),
            "Detection: %d | Delta: %.0f | TotalDelta: %.0f | Detected:%s%s%s%s%s%s%s%s",
            aimbot_detection[client], delta, td,
            ((flags & AIMBOT_FLAG_SNAP)      ? " Aim-Snap"        : ""),
            ((flags & AIMBOT_FLAG_SNAP2)     ? " Aim-Snap2"       : ""),
            ((flags & AIMBOT_FLAG_AUTOSHOOT) ? " Autoshoot"       : ""),
            ((flags & AIMBOT_FLAG_REPEAT)    ? " Angle-Repeat"    : ""),
            ((flags & AIMBOT_FLAG_SMOOTH)    ? " Smooth-Converge" : ""),
            ((flags & AIMBOT_FLAG_JITTER)    ? " Jitter"          : ""),
            ((td > AIMBOT_MAX_TOTAL_DELTA)   ? " Total-Delta"     : ""),
            sNet);

    lilac_save_player_details(client, sDetails);

    /* Vetoed: log the evidence and the reason, then stop.
    * No counter increment, no forward, no database entry, no ban. */
    if (net_vetoed) {
        if (icvar[CVAR_LOG]) {
            lilac_log_setup_client(client);
            Format(line_buffer, sizeof(line_buffer),
                "%s triggered an aimbot detection that was vetoed by network conditions (%s).",
                line_buffer, sDetails);
            lilac_log(true);

            if (icvar[CVAR_LOG_EXTRA] == 2)
                lilac_log_extra(client);
        }

        return;
    }

    CreateTimer(600.0, timer_decrement_aimbot, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);

    lilac_forward_client_cheat(client, CHEAT_AIMBOT);

    /* Don't log the first detection. */
    if (++aimbot_detection[client] < 2)
        return;

    lilac_discord_report(client, CHEAT_AIMBOT, DISCORD_SUSPECT);

    if (icvar[CVAR_CHEAT_WARN])
        lilac_warn_admins(client, CHEAT_AIMBOT, aimbot_detection[client]);

    if (icvar[CVAR_LOG]) {
        lilac_log_setup_client(client);
        Format(line_buffer, sizeof(line_buffer),
            "%s is suspected of using an aimbot (%s).",
            line_buffer, sDetails);

        lilac_log(true);

        if (icvar[CVAR_LOG_EXTRA] == 2)
            lilac_log_extra(client);
    }
    database_log(client, "aimbot", aimbot_detection[client], float(flags), td);

    if (aimbot_detection[client] >= icvar[CVAR_AIMBOT]
        && icvar[CVAR_AIMBOT] >= AIMBOT_BAN_MIN) {

        if (icvar[CVAR_LOG]) {
            lilac_log_setup_client(client);
            Format(line_buffer, sizeof(line_buffer),
                "%s %s for Aimbot.", line_buffer, LILAC_BANNED_TEXT(CHEAT_AIMBOT));

            lilac_log(true);

            if (icvar[CVAR_LOG_EXTRA])
                lilac_log_extra(client);
        }
        database_log(client, "aimbot", DATABASE_BAN);

        playerinfo_banned_flags[client][CHEAT_AIMBOT] = true;
        lilac_ban_client(client, CHEAT_AIMBOT);
    }
}

public Action timer_decrement_aimbot(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);

	if (!is_player_valid(client))
		return Plugin_Continue;

	if (aimbot_detection[client] > 0)
		aimbot_detection[client]--;

	return Plugin_Continue;
}

int wrap_index(int ind) {
    if (ind < 0)
        return ind + CMD_LENGTH;
    if (ind >= CMD_LENGTH)
        return ind - CMD_LENGTH;
    return ind;
}
