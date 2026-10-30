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

#define INF_DMG_BUF_SIZE    128
#define INF_DMG_MAX_FACTOR  4.0

/* Max damage one survivor can take from one infected in one second, by
 * zombie class. 0 disables the class. */
static const int inf_dmg_threshold[9] = {0, 15, 0, 50, 60, 10, 40, 0, 60};

/* Damage cvars of the server, with the value they had when the limits above
 * were measured. If one is raised, the limit of its class goes up by the
 * same ratio. */
static const char inf_dmg_cvar_name[][] = {
	"tongue_choke_damage_amount", "tongue_drag_damage_amount", "smoker_pz_claw_dmg",
	"z_pounce_damage", "z_hunter_max_pounce_bonus_damage", "hunter_pz_claw_dmg",
	"z_jockey_ride_damage", "z_jockey_ride_damage_interval", "jockey_pz_claw_dmg",
	"z_charger_pound_dmg", "z_charge_max_damage", "charger_pz_claw_dmg",
	"vs_tank_damage"
};

static const float inf_dmg_cvar_ref[] = {
	5.0, 3.0, 4.0,
	5.0, 24.0, 6.0,
	2.0, 0.5, 4.0,
	15.0, 10.0, 10.0,
	24.0
};

static const int inf_dmg_cvar_class[] = {
	1, 1, 1,
	3, 3, 3,
	5, 5, 5,
	6, 6, 6,
	8
};

/* Intervals: smaller means more damage. */
static const bool inf_dmg_cvar_interval[] = {
	false, false, false,
	false, false, false,
	false, true, false,
	false, false, false,
	false
};

static const char inf_dmg_class_name[9][] = {
	"None", "Smoker", "Boomer", "Hunter", "Spitter", "Jockey", "Charger", "Witch", "Tank"
};

static ConVar inf_dmg_cvar_handle[13];
static bool   inf_dmg_cvars_found = false;
static float  inf_dmg_last_factor[9];

static void lilac_infected_damage_find_cvars()
{
	if (inf_dmg_cvars_found)
		return;

	inf_dmg_cvars_found = true;

	for (int i = 0; i < sizeof(inf_dmg_last_factor); i++)
		inf_dmg_last_factor[i] = 1.0;

	for (int i = 0; i < sizeof(inf_dmg_cvar_name); i++)
		inf_dmg_cvar_handle[i] = FindConVar(inf_dmg_cvar_name[i]);
}

/* How much the cvars of this class are above the measured values. */
static float lilac_infected_damage_factor(int zclass)
{
	float factor = 1.0;

	lilac_infected_damage_find_cvars();

	for (int i = 0; i < sizeof(inf_dmg_cvar_name); i++) {
		if (inf_dmg_cvar_class[i] != zclass || inf_dmg_cvar_handle[i] == null)
			continue;

		float live = inf_dmg_cvar_handle[i].FloatValue;

		if (live <= 0.0)
			continue;

		float ratio = inf_dmg_cvar_interval[i]
			? (inf_dmg_cvar_ref[i] / live)
			: (live / inf_dmg_cvar_ref[i]);

		if (ratio > factor)
			factor = ratio;
	}

	return (factor > INF_DMG_MAX_FACTOR) ? INF_DMG_MAX_FACTOR : factor;
}

static int lilac_inf_threshold(int zclass)
{
	if (zclass < 1 || zclass > 8 || inf_dmg_threshold[zclass] == 0)
		return 0;

	float factor = lilac_infected_damage_factor(zclass);
	int limit = RoundToCeil(float(inf_dmg_threshold[zclass]) * factor);

	/* Log when the limit of a class changes. */
	if (FloatAbs(factor - inf_dmg_last_factor[zclass]) > 0.01) {
		inf_dmg_last_factor[zclass] = factor;

		if (icvar[CVAR_LOG]) {
			char date[64];

			FormatTime(date, sizeof(date), dateformat, GetTime());
			FormatEx(line_buffer, sizeof(line_buffer),
				"%s [Version %s] Infected damage limit of %s is %d (damage cvars x%.2f).",
				date, PLUGIN_VERSION, inf_dmg_class_name[zclass], limit, factor);

			lilac_log(false);
		}
	}

	return limit;
}

/* For the status command. */
void lilac_infected_damage_print_limits()
{
	PrintToServer("Infected damage limits (damage in one second):");

	for (int zclass = 1; zclass <= 8; zclass++) {
		if (inf_dmg_threshold[zclass] == 0)
			continue;

		float factor = lilac_infected_damage_factor(zclass);

		PrintToServer("\t%s: %d (measured %d, damage cvars x%.2f)",
			inf_dmg_class_name[zclass], RoundToCeil(float(inf_dmg_threshold[zclass]) * factor),
			inf_dmg_threshold[zclass], factor);
	}
}

static int   inf_dmg_tick       [MAXPLAYERS + 1][INF_DMG_BUF_SIZE];
static int   inf_dmg_amount     [MAXPLAYERS + 1][INF_DMG_BUF_SIZE];
static int   inf_dmg_victim     [MAXPLAYERS + 1][INF_DMG_BUF_SIZE];
static int   inf_dmg_head       [MAXPLAYERS + 1];
static int   inf_dmg_detections [MAXPLAYERS + 1];

void lilac_infected_damage_reset_client(int client)
{
	inf_dmg_head[client]       = 0;
	inf_dmg_detections[client] = 0;

	for (int i = 0; i < INF_DMG_BUF_SIZE; i++)
	{
		inf_dmg_tick  [client][i] = 0;
		inf_dmg_amount[client][i] = 0;
	}
}

public Action event_player_hurt(Event event, const char[] name, bool dontBroadcast)
{
    if (!icvar[CVAR_ENABLE] || !icvar[CVAR_INFECTED_DMG])
        return Plugin_Continue;

    int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
    int victim   = GetClientOfUserId(GetEventInt(event, "userid"));
    int damage   = GetEventInt(event, "dmg_health");

    if (!is_player_valid(attacker) || IsFakeClient(attacker))
        return Plugin_Continue;

    if (!is_player_valid(victim) || damage <= 0)
        return Plugin_Continue;

    /* Attacker must be infected team (3), victim must be survivor team (2). */
    if (GetClientTeam(attacker) != 3 || GetClientTeam(victim) != 2)
        return Plugin_Continue;

    if (playerinfo_banned_flags[attacker][CHEAT_INFECTED_DMG])
        return Plugin_Continue;

    /* High packet loss can cause burst events — skip to avoid false positives. */
    if (skip_due_to_loss(attacker))
        return Plugin_Continue;

    int zclass    = GetEntProp(attacker, Prop_Send, "m_zombieClass");
    int threshold = lilac_inf_threshold(zclass);

    if (threshold == 0)
        return Plugin_Continue;

    if (tick_rate <= 0)
        return Plugin_Continue;

    /* Tank: thrown objects hit much harder than a punch, skip them. */
    if (zclass == L4D2_ZC_TANK
        && damage > RoundToCeil(30.0 * lilac_infected_damage_factor(zclass)))
        return Plugin_Continue;

    /* Damage this victim took in the last second. Hits on other survivors
     * don't count, so one swing on several of them is not several swings. */
    int current_tick = GetGameTickCount();
    int total = damage;
    int hits  = 1;

    for (int i = 0; i < INF_DMG_BUF_SIZE; i++)
    {
        if (inf_dmg_tick[attacker][i] <= 0 || inf_dmg_victim[attacker][i] != victim)
            continue;

        int age = current_tick - inf_dmg_tick[attacker][i];

        if (age == 0)
            return Plugin_Continue;

        if (age > 0 && age <= tick_rate)
        {
            total += inf_dmg_amount[attacker][i];
            hits++;
        }
    }

    int slot = inf_dmg_head[attacker];

    inf_dmg_tick  [attacker][slot] = current_tick;
    inf_dmg_amount[attacker][slot] = damage;
    inf_dmg_victim[attacker][slot] = victim;
    inf_dmg_head  [attacker]       = (slot + 1) % INF_DMG_BUF_SIZE;

    if (total > threshold)
    {
        char weapon[32];
        GetEventString(event, "weapon", weapon, sizeof(weapon));

        lilac_infected_damage_flag(attacker, victim, zclass, total, damage, threshold, hits, weapon);
    }

    return Plugin_Continue;
}

static void lilac_infected_damage_flag(int attacker, int victim, int zclass, int total, int last_hit, int threshold, int hits, const char[] weapon)
{
	if (lilac_forward_allow_cheat_detection(attacker, CHEAT_INFECTED_DMG) == false)
		return;

	/* Reset the window after flagging so a single burst doesn't keep firing. */
	for (int i = 0; i < INF_DMG_BUF_SIZE; i++)
	{
		inf_dmg_tick  [attacker][i] = 0;
		inf_dmg_amount[attacker][i] = 0;
	}

	CreateTimer(600.0, timer_decrement_infected_dmg, GetClientUserId(attacker),
		TIMER_FLAG_NO_MAPCHANGE);

	++inf_dmg_detections[attacker];

	char class_name[16];
	strcopy(class_name, sizeof(class_name), inf_dmg_class_name[zclass]);

	char sDetails[256];
	Format(sDetails, sizeof(sDetails),
		"Detection: %d | Class: %s | DmgInWindow: %d | Threshold: %d | LastHit: %d | Hits: %d | Weapon: %s | Victim: %N",
		inf_dmg_detections[attacker], class_name, total,
		threshold, last_hit, hits, weapon, victim);

	lilac_save_player_details(attacker, sDetails);
	lilac_forward_client_cheat(attacker, CHEAT_INFECTED_DMG);

	/* First detection: only forward, don't warn or log yet.
	 * A single spike can happen on high-loss servers. */
	if (inf_dmg_detections[attacker] < 2)
		return;

	lilac_discord_report(attacker, CHEAT_INFECTED_DMG, DISCORD_SUSPECT);

	if (icvar[CVAR_CHEAT_WARN])
		lilac_warn_admins(attacker, CHEAT_INFECTED_DMG, inf_dmg_detections[attacker]);

	if (icvar[CVAR_LOG])
	{
		lilac_log_setup_client(attacker);
		Format(line_buffer, sizeof(line_buffer),
			"%s is suspected of using an infected damage exploit (%s).",
			line_buffer, sDetails);

		lilac_log(true);

		if (icvar[CVAR_LOG_EXTRA] == 2)
			lilac_log_extra(attacker);
	}

	database_log(attacker, "infected_damage", inf_dmg_detections[attacker],
		float(total), float(threshold));

	if (inf_dmg_detections[attacker] >= icvar[CVAR_INFECTED_DMG]
		&& icvar[CVAR_INFECTED_DMG] >= INFECTED_DMG_BAN_MIN)
	{
		if (icvar[CVAR_LOG])
		{
			lilac_log_setup_client(attacker);
			Format(line_buffer, sizeof(line_buffer),
				"%s %s for using an infected damage exploit.", line_buffer, LILAC_BANNED_TEXT(CHEAT_INFECTED_DMG));

			lilac_log(true);

			if (icvar[CVAR_LOG_EXTRA])
				lilac_log_extra(attacker);
		}

		database_log(attacker, "infected_damage", DATABASE_BAN);

		playerinfo_banned_flags[attacker][CHEAT_INFECTED_DMG] = true;
		lilac_ban_client(attacker, CHEAT_INFECTED_DMG);
	}
}

public Action timer_decrement_infected_dmg(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);

	if (is_player_valid(client) && inf_dmg_detections[client] > 0)
		inf_dmg_detections[client]--;

	return Plugin_Continue;
}