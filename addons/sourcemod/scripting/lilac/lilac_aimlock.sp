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

static int aimlock_cursor = 1;

static bool aimlock_skip_player(int client)
{
	if (!is_player_valid(client)
		|| IsFakeClient(client)
		|| !IsPlayerAlive(client)
		|| GetClientTeam(client) < 2 /* Not on a valid team. */
		|| GetGameTime() - playerinfo_time_teleported[client] < 2.0 /* Player recently teleported. */
		|| lilac_network_vetoed(client)
		|| playerinfo_banned_flags[client][CHEAT_AIMLOCK]) /* Already banned/logged. */
		return true;

	/* Stamp while active so the grace check below still covers the short
	 * window right after the camera is released, not just while forced.
	 * Only safe to read the entity prop now that client is confirmed valid. */
	if (lilac_camera_forced_external(client))
		playerinfo_time_camera_forced[client] = GetGameTime();

	if (GetGameTime() - playerinfo_time_camera_forced[client] < CAMERA_FORCED_GRACE_SECS) /* Forced external view (emote/dance/etc). */
		return true;

	if (lilac_player_is_ghost(client))
		playerinfo_time_ghost[client] = GetGameTime();

	if (GetGameTime() - playerinfo_time_ghost[client] < GHOST_GRACE_SECS) /* Ghost spawn/teleport faces a survivor. */
		return true;

	/* Lightweight mode is enabled, don't process players who aren't in que. */
	if (icvar[CVAR_AIMLOCK_LIGHT] == 1 && lilac_is_player_in_aimlock_que(client) == false)
		return true;

	return false;
}

static bool aimlock_skip_target(int client, int target)
{
	return (client == target
		|| !is_player_valid(target)
		|| GetClientTeam(client) == GetClientTeam(target)
		|| !IsPlayerAlive(target)
		|| GetClientTeam(target) < 2 /* Target isn't in a valid team. */
		|| GetGameTime() - playerinfo_time_teleported[target] < 2.0); /* Teleported. */
}

public Action timer_check_aimlock(Handle timer)
{
	float pos[3], pos2[3];
	int players_processed = 0;

	if (!icvar[CVAR_ENABLE] || !icvar[CVAR_AIMLOCK])
		return Plugin_Continue;

	/* Process up to 5 players per call and advance the cursor so the next
	 * call continues from where this one stopped, covering all players
	 * across successive calls. Light mode additionally restricts which
	 * players are eligible via aimlock_skip_player. */
	int batch_size = 5;

	for (int i = 0; i < MaxClients; i++) {
		int client = (aimlock_cursor - 1 + i) % MaxClients + 1;

		if (players_processed >= batch_size) {
			aimlock_cursor = client;
			return Plugin_Continue;
		}

		if (aimlock_skip_player(client))
			continue;

		players_processed++;
		GetClientEyePosition(client, pos);

		bool detected = false;
		bool process = true;
		int hit_target = 0, hit_locked = 0;
		float hit_dist = 0.0, hit_snap = 0.0, hit_tracked = 0.0;

		for (int target = 1; process && target <= MaxClients; target++) {
			if (aimlock_skip_target(client, target))
				continue;

			GetClientEyePosition(target, pos2);

			/* Too close to an enemy, don't report aimlock
			 * detections and stop processing this player. */
			if (GetVectorDistance(pos, pos2) < 300.0) {
				detected = false;
				process = false;
				continue;
			}

			/* Player has already been detected of using aimlock,
			 * don't check for aimlock again, only check
			 * if the player is too close to other enemies. */
			if (detected)
				continue;

			float snap, tracked;
			int locked;

			if (is_aimlocking(client, pos, pos2, snap, locked, tracked)) {
				detected = true;
				hit_target = target;
				hit_dist = GetVectorDistance(pos, pos2);
				hit_snap = snap;
				hit_locked = locked;
				hit_tracked = tracked;
			}
		}

		if (detected)
			lilac_detected_aimlock(client, hit_target, hit_dist, hit_snap, hit_locked, hit_tracked);
	}

	/* Completed a full sweep — restart cursor from the beginning. */
	aimlock_cursor = 1;
	return Plugin_Continue;
}

static bool is_aimlocking(int client, float pos[3], float pos2[3], float &snap, int &locked, float &tracked)
{
	float ideal[3], lang[3], ang[3];
	float laimdist, aimdist;
	float path = 0.0;
	int lock = 0;
	int ind;

	aim_at_point(pos, pos2, ideal);

	ind = playerinfo_index[client];
	for (int i = 0; i < time_to_ticks(0.5 + 0.1); i++) {
		if (ind < 0)
			ind += CMD_LENGTH;

		/* Only process aimlock time. */
		if (GetGameTime() - playerinfo_time_usercmd[client][ind] < 0.5 + 0.1) {
			get_player_log_angles(client, ind, false, ang);
			laimdist = angle_delta(ang, ideal);

			if (i) {
				if (aimdist < 5.0) {
					lock++;

					/* Both ticks on target, add how much the aim moved. */
					if (laimdist < 5.0)
						path += angle_delta(ang, lang);
				}
				else {
					lock = 0;
					path = 0.0;
				}

				/* A frozen view (cutscene) has a lock but no tracking. */
				if (aimdist < laimdist * 0.1
					&& angle_delta(ang, lang) > 20.0
					&& lock > time_to_ticks(0.1)
					&& path >= AIMLOCK_MIN_TRACK_DEG) {
					snap = angle_delta(ang, lang);
					locked = lock;
					tracked = path;
					return true;
				}
			}

			lang = ang;
			aimdist = laimdist;
		}

		ind--;
	}

	return false;
}

static void lilac_detected_aimlock(int client, int target, float distance, float snap, int locked, float tracked)
{
	if (playerinfo_banned_flags[client][CHEAT_AIMLOCK])
		return;

	/* The same snap stays in the check window for a while, count it once. */
	if (GetGameTime() - playerinfo_time_aimlock_hit[client] < AIMLOCK_REPEAT_SECS)
		return;

	playerinfo_time_aimlock_hit[client] = GetGameTime();

	/* Suspicions reset after 3 minutes.
	 * This means you need to get two aimlocks within
	 * three minutes of each other to get a single detection. */
	if (GetGameTime() - playerinfo_time_aimlock[client] < 180.0)
		playerinfo_aimlock_sus[client]++;
	else
		playerinfo_aimlock_sus[client] = 1;

	playerinfo_time_aimlock[client] = GetGameTime();

	if (playerinfo_aimlock_sus[client] < 2)
		return;

	playerinfo_aimlock_sus[client] = 0;

	if (lilac_forward_allow_cheat_detection(client, CHEAT_AIMLOCK) == false)
		return;

	/* Detection expires in 10 minutes. */
	CreateTimer(600.0, timer_decrement_aimlock, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);

	char sDetails[512];
	Format(sDetails, sizeof(sDetails), "Detection: %d", playerinfo_aimlock[client]);

	lilac_save_player_details(client, sDetails);
	lilac_forward_client_cheat(client, CHEAT_AIMLOCK);

	/* Don't log the first detection. */
	if (++playerinfo_aimlock[client] < 2)
		return;

	char sInfo[256];
	sInfo[0] = '\0';

	if (target > 0 && IsClientInGame(target)) {
		char sExtra[256], sTarget[MAX_NAME_LENGTH], sTeam[16];

		GetClientName(target, sTarget, sizeof(sTarget));
		lilac_team_name(GetClientTeam(target), sTeam, sizeof(sTeam));

		FormatEx(sExtra, sizeof(sExtra), "Target: %s (%s)\nDistance: %.0f\nSnap: %.1f deg\nLockedTicks: %d\nTracked: %.1f deg",
			sTarget, sTeam, distance, snap, locked, tracked);
		lilac_discord_set_extra(client, CHEAT_AIMLOCK, sExtra);

		FormatEx(sInfo, sizeof(sInfo), "Target: %s (%s), Distance: %.0f, Snap: %.1f deg, Locked: %d ticks, Tracked: %.1f deg",
			sTarget, sTeam, distance, snap, locked, tracked);
	}

	lilac_discord_report(client, CHEAT_AIMLOCK, DISCORD_SUSPECT);

	if (icvar[CVAR_CHEAT_WARN])
		lilac_warn_admins(client, CHEAT_AIMLOCK, playerinfo_aimlock[client]);

	if (icvar[CVAR_LOG]) {
		lilac_log_setup_client(client);

		if (sInfo[0])
			Format(line_buffer, sizeof(line_buffer),
				"%s is suspected of using an aimlock (%s, %s).",
				line_buffer, sDetails, sInfo);
		else
			Format(line_buffer, sizeof(line_buffer),
				"%s is suspected of using an aimlock (%s).",
				line_buffer, sDetails);

		lilac_log(true);

		if (icvar[CVAR_LOG_EXTRA] == 2)
			lilac_log_extra(client);
	}
	database_log(client, "aimlock", playerinfo_aimlock[client]);

	if (playerinfo_aimlock[client] >= icvar[CVAR_AIMLOCK]
		&& icvar[CVAR_AIMLOCK] >= AIMLOCK_BAN_MIN) {
		playerinfo_banned_flags[client][CHEAT_AIMLOCK] = true;

		if (icvar[CVAR_LOG]) {
			lilac_log_setup_client(client);
			Format(line_buffer, sizeof(line_buffer),
				"%s %s for Aimlock.", line_buffer, LILAC_BANNED_TEXT(CHEAT_AIMLOCK));

			lilac_log(true);

			if (icvar[CVAR_LOG_EXTRA])
				lilac_log_extra(client);
		}
		database_log(client, "aimlock", DATABASE_BAN);

		lilac_ban_client(client, CHEAT_AIMLOCK);
	}
}

void lilac_aimlock_light_test(int client)
{
	int ind;
	float lastang[3], ang[3];

	/* Player recently teleported, spawned or taunted. Ignore. */
	if (GetGameTime() - playerinfo_time_teleported[client] < 3.0)
		return;

	ind = playerinfo_index[client];
	for (int i = 0; i < time_to_ticks(0.5); i++) {
		if (ind < 0)
			ind += CMD_LENGTH;

		get_player_log_angles(client, ind, false, ang);

		if (i) {
			/* This player has a somewhat big delta,
			 * test this player for aimlock for 200 seconds. */
			if (angle_delta(lastang, ang) > 20.0) {
				playerinfo_time_process_aimlock[client] = GetGameTime() + 200.0;
				return;
			}
		}

		lastang = ang;
		ind--;
	}
}

static bool lilac_is_player_in_aimlock_que(int client)
{
	/* Test for aimlock on players who: */
	return (GetGameTime() < playerinfo_time_process_aimlock[client] /* Are in the que. */
		|| playerinfo_aimlock[client] /* Already has a detection. */
		|| lilac_aimbot_get_client_detections(client) > 1 /* Already have been detected for aimbot twice. */
		|| GetClientTime(client) < 240.0 /* Client just joined the game. */
		|| (GetGameTime() - playerinfo_time_aimlock[client] < 180.0
			&& playerinfo_time_aimlock[client] > 1.0)); /* Had one aimlock the past three minutes. */
}

public Action timer_decrement_aimlock(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);

	if (!is_player_valid(client))
		return Plugin_Continue;

	if (playerinfo_aimlock[client] > 0)
		playerinfo_aimlock[client]--;

	return Plugin_Continue;
}
