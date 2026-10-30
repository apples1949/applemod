/*
	Little Anti-Cheat
	Copyright (C) 2026-2026 Ferks-FK

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

/*
	Survivor burst-damage exploit detector.

	Tracks damage per (attacker, weapon) instead of per victim class — the
	weapon is what has a physical rate-of-fire ceiling, not the target.
	Thresholds below are real per-weapon maximums from a week of production
	calibration, +5% margin. Fire/explosive weapons have no threshold entry
	on purpose (see the threshold gate below) since a cheat can't meaningfully
	boost AoE damage the way it can a weapon's fire rate.
	Tank only for now — widen once other classes are calibrated.
*/

#define SURV_DMG_WINDOW      1.0
#define SURV_DMG_BUF_SIZE    128
#define SURV_DMG_CLOCK_COOLDOWN 5.0

/* IsPlayerAlive()/tank_killed don't reliably catch the Tank's death
 * animation window; m_isIncapacitated does, same fix used by the
 * already-working l4d_tank_damage_announce.sp. */
static int g_iOffsetTankIncapacitated = -1;

static bool surv_dmg_tank_is_dying(int tank)
{
	if (g_iOffsetTankIncapacitated == -1)
		g_iOffsetTankIncapacitated = FindSendPropInfo("Tank", "m_isIncapacitated");

	if (g_iOffsetTankIncapacitated <= 0)
		return false;

	return view_as<bool>(GetEntData(tank, g_iOffsetTankIncapacitated));
}

static StringMap weapon_dmg_threshold = null;

static float surv_dmg_time      [MAXPLAYERS + 1][SURV_DMG_BUF_SIZE];
static float surv_dmg_etime     [MAXPLAYERS + 1][SURV_DMG_BUF_SIZE];
static float surv_dmg_clock_last[MAXPLAYERS + 1];
static int   surv_dmg_amount    [MAXPLAYERS + 1][SURV_DMG_BUF_SIZE];
static int   surv_dmg_head      [MAXPLAYERS + 1];
static int   surv_dmg_detections[MAXPLAYERS + 1];

static char surv_dmg_weapon[MAXPLAYERS + 1][64];

void lilac_survivor_damage_reset_client(int client)
{
	surv_dmg_head[client]       = 0;
	surv_dmg_detections[client] = 0;
	surv_dmg_weapon[client][0]  = '\0';
	surv_dmg_clock_last[client] = 0.0;

	for (int i = 0; i < SURV_DMG_BUF_SIZE; i++)
	{
		surv_dmg_time  [client][i] = 0.0;
		surv_dmg_etime [client][i] = 0.0;
		surv_dmg_amount[client][i] = 0;
	}
}

static void lilac_survivor_damage_init_maps()
{
	if (weapon_dmg_threshold != null)
		return;

	weapon_dmg_threshold = new StringMap();

	/* Firearms. */
	weapon_dmg_threshold.SetValue("pistol", 294);
	weapon_dmg_threshold.SetValue("pistol_magnum", 332);
	weapon_dmg_threshold.SetValue("smg", 340);
	weapon_dmg_threshold.SetValue("smg_silenced", 429);
	weapon_dmg_threshold.SetValue("pumpshotgun", 504);
	weapon_dmg_threshold.SetValue("shotgun_chrome", 502);
	weapon_dmg_threshold.SetValue("prop_minigun_l4d1", 403);

	/* Melee. */
	weapon_dmg_threshold.SetValue("melee", 588);
	weapon_dmg_threshold.SetValue("chainsaw", 1155);
}

public Action event_player_hurt_survivor_dmg(Event event, const char[] name, bool dontBroadcast)
{
    if (!icvar[CVAR_ENABLE] || !icvar[CVAR_SURVIVOR_DMG])
        return Plugin_Continue;

    lilac_survivor_damage_init_maps();

    int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
    int victim   = GetClientOfUserId(GetEventInt(event, "userid"));
    int damage   = GetEventInt(event, "dmg_health");

    if (!is_player_valid(attacker) || IsFakeClient(attacker))
        return Plugin_Continue;

    if (!is_player_valid(victim) || damage <= 0)
        return Plugin_Continue;

    if (GetClientTeam(attacker) != 2 || GetClientTeam(victim) != 3)
        return Plugin_Continue;

    if (!IsPlayerAlive(victim))
        return Plugin_Continue;

    if (GetEntProp(victim, Prop_Send, "m_zombieClass") != L4D2_ZC_TANK)
        return Plugin_Continue;

    if (surv_dmg_tank_is_dying(victim))
        return Plugin_Continue;

    if (playerinfo_banned_flags[attacker][CHEAT_SURVIVOR_DMG])
        return Plugin_Continue;

    if (skip_due_to_loss(attacker))
        return Plugin_Continue;

    /* GetEventString, not GetClientWeapon() — the latter is whatever the
     * attacker currently holds, which misattributes delayed damage (molotov
     * fire ticks, bile) to the wrong weapon. */
    char weapon[64];
    GetEventString(event, "weapon", weapon, sizeof(weapon));
    if (weapon[0] == '\0')
        return Plugin_Continue;

    if (!StrEqual(weapon, surv_dmg_weapon[attacker]))
    {
        strcopy(surv_dmg_weapon[attacker], sizeof(surv_dmg_weapon[]), weapon);

        for (int i = 0; i < SURV_DMG_BUF_SIZE; i++)
        {
            surv_dmg_time  [attacker][i] = 0.0;
            surv_dmg_etime [attacker][i] = 0.0;
            surv_dmg_amount[attacker][i] = 0;
        }

        surv_dmg_head[attacker] = 0;
    }

    /* Not deduplicated by tick like lilac_infected_damage.sp — pellets
     * landing in the same tick are exactly the pattern being measured. */
    float now = GetGameTime();
    int   slot = surv_dmg_head[attacker];

    surv_dmg_time  [attacker][slot] = now;
    surv_dmg_amount[attacker][slot] = damage;
    surv_dmg_head  [attacker]       = (slot + 1) % SURV_DMG_BUF_SIZE;

    /* Same hits on the real clock, for the damage clock log only. */
    float real_now = GetEngineTime();
    surv_dmg_etime[attacker][slot] = real_now;

    int total = 0;
    int real_total = 0;

    for (int i = 0; i < SURV_DMG_BUF_SIZE; i++)
    {
        if (surv_dmg_time[attacker][i] > 0.0
            && now - surv_dmg_time[attacker][i] <= SURV_DMG_WINDOW)
        {
            total += surv_dmg_amount[attacker][i];
        }

        if (surv_dmg_etime[attacker][i] > 0.0
            && real_now - surv_dmg_etime[attacker][i] <= SURV_DMG_WINDOW)
        {
            real_total += surv_dmg_amount[attacker][i];
        }
    }

    int threshold = 0;
    weapon_dmg_threshold.GetValue(weapon, threshold);

    if (threshold > 0 && real_total > threshold)
        lilac_survivor_damage_clock_note(attacker, weapon, threshold, total, real_total);

    if (threshold > 0 && total > threshold)
        lilac_survivor_damage_flag(attacker, victim, weapon, total, damage, threshold);

    return Plugin_Continue;
}

/* Log only. Writes when the real clock total is over the limit. */
static void lilac_survivor_damage_clock_note(int attacker, const char[] weapon, int threshold, int total, int real_total)
{
    if (!(icvar[CVAR_TELEMETRY] & TELEMETRY_DAMAGE))
        return;

    float real_now = GetEngineTime();

    if (real_now - surv_dmg_clock_last[attacker] < SURV_DMG_CLOCK_COOLDOWN)
        return;

    surv_dmg_clock_last[attacker] = real_now;

    char sNet[192], sMsg[448];
    float ahead = GetGameTime() - (float(GetGameTickCount()) * GetTickInterval());
    int cmds = lilac_recent_cmd_count(attacker, GetGameTime());

    lilac_network_format(attacker, sNet, sizeof(sNet));

    FormatEx(sMsg, sizeof(sMsg),
        "Weapon: %s | Threshold: %d | GameClock: %d | RealClock: %d | ClockAhead: %.2f | Cmds1s: %d | ServerLag: %s | %s",
        weapon, threshold, total, real_total, ahead, cmds,
        lilac_server_is_lagging() ? "yes" : "no", sNet);

    lilac_log_damage_clock(attacker, sMsg);
}

/* Detection/ban pipeline, mirrors lilac_infected_damage_flag's structure. */
static void lilac_survivor_damage_flag(int attacker, int victim, const char[] weapon, int total, int last_hit, int threshold)
{
	if (lilac_forward_allow_cheat_detection(attacker, CHEAT_SURVIVOR_DMG) == false)
		return;

	/* Reset the window after flagging so a single burst doesn't keep firing. */
	for (int i = 0; i < SURV_DMG_BUF_SIZE; i++)
	{
		surv_dmg_time  [attacker][i] = 0.0;
		surv_dmg_etime [attacker][i] = 0.0;
		surv_dmg_amount[attacker][i] = 0;
	}

	CreateTimer(600.0, timer_decrement_survivor_dmg, GetClientUserId(attacker),
		TIMER_FLAG_NO_MAPCHANGE);

	++surv_dmg_detections[attacker];

	char sDetails[256];
	Format(sDetails, sizeof(sDetails),
		"Detection: %d | Weapon: %s | DmgInWindow: %d | Threshold: %d | LastHit: %d | Victim: %N",
		surv_dmg_detections[attacker], weapon, total,
		threshold, last_hit, victim);

	lilac_save_player_details(attacker, sDetails);
	lilac_forward_client_cheat(attacker, CHEAT_SURVIVOR_DMG);

	/* First detection: only forward, don't warn or log yet.
	 * A single spike can happen on high-loss servers. */
	if (surv_dmg_detections[attacker] < 2)
		return;

	lilac_discord_report(attacker, CHEAT_SURVIVOR_DMG, DISCORD_SUSPECT);

	if (icvar[CVAR_CHEAT_WARN])
		lilac_warn_admins(attacker, CHEAT_SURVIVOR_DMG, surv_dmg_detections[attacker]);

	if (icvar[CVAR_LOG])
	{
		lilac_log_setup_client(attacker);
		Format(line_buffer, sizeof(line_buffer),
			"%s is suspected of using a survivor damage exploit (%s).",
			line_buffer, sDetails);

		lilac_log(true);

		if (icvar[CVAR_LOG_EXTRA] == 2)
			lilac_log_extra(attacker);
	}

	database_log(attacker, "survivor_damage", surv_dmg_detections[attacker],
		float(total), float(threshold));

	if (surv_dmg_detections[attacker] >= icvar[CVAR_SURVIVOR_DMG]
		&& icvar[CVAR_SURVIVOR_DMG] >= SURVIVOR_DMG_BAN_MIN)
	{
		if (icvar[CVAR_LOG])
		{
			lilac_log_setup_client(attacker);
			Format(line_buffer, sizeof(line_buffer),
				"%s %s for using a survivor damage exploit.", line_buffer, LILAC_BANNED_TEXT(CHEAT_SURVIVOR_DMG));

			lilac_log(true);

			if (icvar[CVAR_LOG_EXTRA])
				lilac_log_extra(attacker);
		}

		database_log(attacker, "survivor_damage", DATABASE_BAN);

		playerinfo_banned_flags[attacker][CHEAT_SURVIVOR_DMG] = true;
		lilac_ban_client(attacker, CHEAT_SURVIVOR_DMG);
	}
}

public Action timer_decrement_survivor_dmg(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);

	if (is_player_valid(client) && surv_dmg_detections[client] > 0)
		surv_dmg_detections[client]--;

	return Plugin_Continue;
}
