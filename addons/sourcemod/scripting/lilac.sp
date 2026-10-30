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

/* Uncomment below line to compile for Team Fortress 2 Classic.
 * You'll need SourceMod 1.12 to compile.
 * Note: Doing so means the compiled plugin won't work correctly
 * for other source games. 
 * SourceMod 1.12: https://www.sourcemod.net/downloads.php?branch=1.12 */

#include <sourcemod>
#include <sdktools_engine>
#include <sdktools_entoutput>
#include <convar_class>
#include <lilac>

#undef REQUIRE_PLUGIN /* ... */
#undef REQUIRE_EXTENSIONS
#tryinclude <ripext> /* Optional, only used by the Discord webhook. */
#define REQUIRE_PLUGIN
#define REQUIRE_EXTENSIONS

#pragma semicolon 1
#pragma newdecls required

#include "lilac/lilac_globals.sp" /* Must be at top, contains defines. */

#include "lilac/lilac_aimbot.sp"
#include "lilac/lilac_aimlock.sp"
#include "lilac/lilac_angles.sp"
#include "lilac/lilac_backtrack.sp"
#include "lilac/lilac_bhop.sp"
#include "lilac/lilac_config.sp"
#include "lilac/lilac_convar.sp"
#include "lilac/lilac_database.sp"
#include "lilac/lilac_discord.sp"
#include "lilac/lilac_lerp.sp"
#include "lilac/lilac_macro.sp"
#include "lilac/lilac_network.sp"
#include "lilac/lilac_ping.sp"
#include "lilac/lilac_speedhack.sp"
#include "lilac/lilac_infected_damage.sp"
#include "lilac/lilac_survivor_damage.sp"
#include "lilac/lilac_stock.sp"
#include "lilac/lilac_string.sp" /* String takes care of chat and names. */

public Plugin myinfo = {
	name = PLUGIN_NAME,
	author = PLUGIN_AUTHOR,
	description = PLUGIN_DESC,
	version = PLUGIN_VERSION,
	url = PLUGIN_URL
};

public APLRes AskPluginLoad2(Handle hMyself, bool bLate, char[] sError, int err_max)
{
    EngineVersion version = GetEngineVersion();

    if (version == Engine_Left4Dead || version == Engine_Left4Dead2 || version == Engine_CSS || version == Engine_DODS)
    {
        g_bGame = version;

        RegPluginLibrary("lilac");

        CreateNative("lilac_GetDetectedInfos", lilac_native_get_detected_infos);

        /* Been told this isn't needed, but just in case. */
        MarkNativeAsOptional("SBBanPlayer");
        MarkNativeAsOptional("SBPP_BanPlayer");
        MarkNativeAsOptional("MABanPlayer");
        MarkNativeAsOptional("IRC_MsgFlaggedChannels");
        MarkNativeAsOptional("AR_GetMatchID");
        MarkNativeAsOptional("SourceTV_IsActive");
        MarkNativeAsOptional("SourceTV_IsRecording");
        MarkNativeAsOptional("SourceTV_GetRecordingTick");

        /* Build the log path for the file in case the user has overridden sm_basepath. */
        BuildPath(Path_SM, log_file, sizeof(log_file), "logs/lilac.log");
        BuildPath(Path_SM, smooth_telemetry_log_file, sizeof(smooth_telemetry_log_file), "logs/lilac_smooth_telemetry.log");
        BuildPath(Path_SM, angle_metric_log_file, sizeof(angle_metric_log_file), "logs/lilac_angle_metric.log");
        BuildPath(Path_SM, speedhack_shadow_log_file, sizeof(speedhack_shadow_log_file), "logs/lilac_speedhack_shadow.log");
        BuildPath(Path_SM, damage_clock_log_file, sizeof(damage_clock_log_file), "logs/lilac_damage_clock.log");

        return APLRes_Success;
    }

    strcopy(sError, err_max, "This plugin only supports Source Engine games. If you are seeing this message, it means your game isn't supported.");
    return APLRes_SilentFailure;
}

public void OnPluginStart()
{
    LoadTranslations("lilac.phrases.txt");
    
    HookEvent("player_death", event_player_death, EventHookMode_Pre);
    HookEvent("player_spawn", event_teleported, EventHookMode_Post);
    HookEvent("player_changename", event_namechange, EventHookMode_Post);

    if (g_bGame == Engine_Left4Dead2) {
        HookEvent("player_hurt", event_player_hurt, EventHookMode_Post);
        HookEvent("player_hurt", event_player_hurt_survivor_dmg, EventHookMode_Post);
    }

    HookEntityOutput("trigger_teleport", "OnEndTouch", map_teleport);

    /* Default ban lengths are -1. (Global ConVar). */
    for (int i = 0; i < CHEAT_MAX; i++)
        ban_length_overwrite[i] = -1;

    /* Bans for Bhop are permanent by default. */
    ban_length_overwrite[CHEAT_BHOP] = 0;

    /* Bans for Macros are 15 minutes by default. */
    ban_length_overwrite[CHEAT_MACRO] = 15;

    /* Bans for Speedhack are permanent by default. */
    ban_length_overwrite[CHEAT_SPEEDHACK] = 0;

    /* If sv_maxupdaterate is changed mid-game and then this plugin
    * is loaded, then it could lead to false positives.
    * Reset all stats on all players already in-game, but ignore lerp. */
    for (int i = 1; i <= MaxClients; i++) {
        lilac_reset_client(i);
        lilac_lerp_ignore_nolerp_client(i);
    }

    forwardhandle = CreateGlobalForward("lilac_cheater_detected",
        ET_Ignore, Param_Cell, Param_Cell);
    forwardhandleban = CreateGlobalForward("lilac_cheater_banned",
        ET_Ignore, Param_Cell, Param_Cell);
    forwardhandleallow = CreateGlobalForward("lilac_allow_cheat_detection",
        ET_Event, Param_Cell, Param_Cell);

    CreateTimer(QUERY_TIMER, timer_query, _, TIMER_REPEAT);
    CreateTimer(5.0, timer_check_ping, _, TIMER_REPEAT);
    CreateTimer(5.0, timer_check_lerp, _, TIMER_REPEAT);
    CreateTimer(1.0, timer_check_speedhack, _, TIMER_REPEAT);
    CreateTimer(0.1, timer_check_aimlock, _, TIMER_REPEAT);
    CreateTimer(0.1, timer_sample_network, _, TIMER_REPEAT);
    CreateTimer(60.0 * 5.0, timer_decrement_macro, _, TIMER_REPEAT);

    lilac_discord_init();

    /* Just a fallback until OnGameFrame's first tick confirms the real,
     * settled tickrate below — the server may not have finished applying
     * it yet this early. */
    tick_rate = RoundToNearest(1.0 / GetTickInterval());
    lilac_apply_tick_settings();

    /* This sets up convars and such. */
    lilac_config_setup();

    if (icvar[CVAR_LOG])
        lilac_log_first_time_setup();
}

/* Everything derived from tick_rate. Called once from OnPluginStart (using
 * whatever GetTickInterval() reports that early, which can be wrong), then
 * again from OnGameFrame once g_iServerTickrate confirms the real, settled
 * value — see the correction there. */
static void lilac_apply_tick_settings()
{
    /* Ignore low tickrates. */
    macro_max = (tick_rate >= 60 && tick_rate <= MACRO_LOG_LENGTH) ? 20 : 0;

    if (tick_rate > 50) {
        bhop_settings_min[BHOP_INDEX_MIN] = 5;
        bhop_settings_min[BHOP_INDEX_MAX] = 10;
        bhop_settings_min[BHOP_INDEX_TOTAL] = 1;
    }
    else {
        bhop_settings_min[BHOP_INDEX_MIN] = 10;
        bhop_settings_min[BHOP_INDEX_MAX] = 20;
        bhop_settings_min[BHOP_INDEX_TOTAL] = 3;
    }
    bhop_settings_min[BHOP_INDEX_JUMP] = -1;
    bhop_settings_min[BHOP_INDEX_AIR] = 0;
}

public void OnAllPluginsLoaded()
{
    /* Startup message. */
    PrintToServer("[Little Anti-Cheat %s] Successfully loaded!", PLUGIN_VERSION);
}

public void OnClientPutInServer(int client)
{
	lilac_reset_client(client);
	lilac_string_check_name(client);

	CreateTimer(30.0, timer_welcome, GetClientUserId(client));
}

public Action event_teleported(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid", -1));

	if (is_player_valid(client))
		playerinfo_time_teleported[client] = GetGameTime();

	return Plugin_Continue;
}

public void map_teleport(const char[] output, int caller, int activator, float delay)
{
	if (!is_player_valid(activator) || IsFakeClient(activator))
		return;

	playerinfo_time_teleported[activator] = GetGameTime();
}

public Action timer_welcome(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);

	/* Todo: Considering there are log-only options now...
	 * Perhaps I should check if ANYTHING can ban at all. */
	if (is_player_valid(client) && icvar[CVAR_WELCOME]
		&& icvar[CVAR_ENABLE] && icvar[CVAR_BAN])
		PrintToChat(client, "[Lilac] %T", "welcome_msg", client, PLUGIN_VERSION);

	return Plugin_Continue;
}

public Action OnPlayerRunCmd(int client, int& buttons, int& impulse, float vel[3],
                float angles[3], int& weapon, int& subtype, int& cmdnum,
                int& tickcount, int& seed, int mouse[2])
{
    static int lbuttons[MAXPLAYERS + 1];

    if (!is_player_valid(client) || IsFakeClient(client))
        return Plugin_Continue;

    /* NaN/inf angles are never legitimate. Detect them (CSS/DoD:S only),
     * then fall back to the last stored angles so they never spread. */
    if (!are_angles_finite(angles)) {
        if (icvar[CVAR_ENABLE] && icvar[CVAR_ANGLES] && (g_bGame == Engine_CSS || g_bGame == Engine_DODS))
            lilac_angles_check(client, angles);

        get_player_log_angles(client, 0, true, angles);
    }

    lilac_network_burst_cmd(client);

    /* Increment the index. */
    if (++playerinfo_index[client] >= CMD_LENGTH)
        playerinfo_index[client] = 0;

    /* Store when the tick was processed. */
    playerinfo_time_usercmd[client][playerinfo_index[client]] = GetGameTime();

    /* Store information. */
    lilac_backtrack_store_tickcount(client, tickcount);
    set_player_log_angles(client, angles, playerinfo_index[client]);
    playerinfo_buttons[client][playerinfo_index[client]] = buttons;
    playerinfo_actions[client][playerinfo_index[client]] = 0;

    if ((buttons & IN_ATTACK) && bullettime_can_shoot(client))
        playerinfo_actions[client][playerinfo_index[client]] |= ACTION_SHOT;

    if (icvar[CVAR_ENABLE]) {
        /* Detect Angle-Cheats. */
        /* Only check for angles in CSS and DoD:S */
        if (icvar[CVAR_ANGLES] && (g_bGame == Engine_CSS || g_bGame == Engine_DODS))
            lilac_angles_check(client, angles);

        /* Detect Macros. */
        if (macro_max && icvar[CVAR_MACRO])
            lilac_macro_check(client, buttons, lbuttons[client]);

        /* Detect bhop. */
        if (!force_disable_bhop && icvar[CVAR_BHOP])
            lilac_bhop_check(client, buttons, lbuttons[client]);

        /* Command numbers, for the speedhack check. */
        if (icvar[CVAR_SPEEDHACK])
            lilac_speedhack_cmd(client, cmdnum);

        /* Patch Angle-Cheats. */
        if (icvar[CVAR_PATCH_ANGLES])
            lilac_angles_patch(angles);

        /* Patch Backtracking. */
        if (icvar[CVAR_BACKTRACK_PATCH])
            tickcount = lilac_backtrack_patch(client, tickcount);

        /* Clamp infected player tickbase to prevent burst-attack exploit. */
        lilac_tickbase_fix(client);
    }

    lbuttons[client] = buttons;

    return Plugin_Continue;
}

public void OnMapStart()
{
    g_fTimeSinceMapStart   = GetEngineTime();
    g_fServerLagPauseUntil = 0.0;
    g_bServerLagLogged     = false;
    g_iServerTickrate      = 0;
    g_iTicksThisSecond     = 0;
    g_fTPSWindowStart      = 0.0;
    g_iCurrentTPS          = 0;
    g_iTriggerTPS          = 0;

    g_fTPSBaselineEWMA     = 0.0;
    g_iTPSCalibSum         = 0;
    g_iTPSCalibSamples     = 0;

    g_bTPSWindowArmed      = false;
}

public void OnGameFrame()
{
    float engineNow = GetEngineTime();

    if (g_iServerTickrate == 0)
    {
        g_iServerTickrate   = RoundToNearest(1.0 / GetTickInterval());

        /* Correct tick_rate (and everything derived from it) if the early
         * OnPluginStart read above was wrong — g_iServerTickrate is the
         * trustworthy one, recomputed fresh per map. */
        if (tick_rate != g_iServerTickrate)
        {
            tick_rate = g_iServerTickrate;
            lilac_apply_tick_settings();
            lilac_bhop_set_preset();
        }
    }

    /* Grace period after map start — engine is still settling. */
    if (engineNow - SERVER_LAG_MAP_START_WAIT < g_fTimeSinceMapStart)
        return;

    /* Arm the TPS window exactly when the grace period ends.
     * Without this, g_fTPSWindowStart is still 0.0 and the first window
     * closes immediately with a single tick counted, producing a spurious
     * TPS=1 sample that contaminates calibration. */
    if (!g_bTPSWindowArmed)
    {
        g_bTPSWindowArmed  = true;
        g_fTPSWindowStart  = engineNow;
        g_iTicksThisSecond = 0;
        return;
    }

    g_iTicksThisSecond++;

    if (engineNow - 1.0 >= g_fTPSWindowStart)
    {
        g_fTPSWindowStart  = engineNow;
        g_iCurrentTPS      = g_iTicksThisSecond;
        g_iTicksThisSecond = 0;

        /* Seeding phase: gather an initial rolling baseline before tracking begins. */
        if (g_fTPSBaselineEWMA <= 0.0)
        {
            /* Reject samples that are implausibly low — a sample far below the
             * nominal tickrate means the server was lagging DURING seeding,
             * which would poison the initial baseline. Discard and keep sampling. */
            if (g_iCurrentTPS < RoundToFloor(float(g_iServerTickrate) * SERVER_LAG_CALIB_MIN_RATIO))
                return;

            g_iTPSCalibSum += g_iCurrentTPS;
            g_iTPSCalibSamples++;

            if (g_iTPSCalibSamples >= SERVER_LAG_CALIB_SAMPLES)
                g_fTPSBaselineEWMA = float(g_iTPSCalibSum) / float(g_iTPSCalibSamples);

            return;
        }

        /* Compare against the rolling baseline rather than a fixed, one-time
         * number — it tracks the server's actual recent load, so a sudden
         * departure from "recent normal" is flagged regardless of the
         * server's absolute tickrate or how busy it typically runs.
         *
         * LOW is the primary and more reliable signal: a stall guarantees a
         * reduced tick count in the window(s) it overlaps, whereas a
         * compensating catch-up spike afterward is not guaranteed to happen
         * (Source does not necessarily "replay" missed ticks in a burst).
         * HIGH is the secondary signal, catching that catch-up spike when it
         * does happen — the exact moment backlogged usercmds get flushed. */
        int tpsLow  = RoundToFloor(g_fTPSBaselineEWMA * SERVER_LAG_TPS_LOW_MULT);
        int tpsHigh = RoundToCeil(g_fTPSBaselineEWMA * SERVER_LAG_TPS_HIGH_MULT);

        if (g_iCurrentTPS < tpsLow || g_iCurrentTPS > tpsHigh)
        {
            /* Extend the pause on every qualifying window, even if a pause is
             * already active — sustained lag keeps detection paused instead
             * of reopening the false-positive window in between.
             *
             * Deliberately NOT folded into the baseline below: doing so would
             * let an ongoing lag episode drag "normal" down (or up) to match
             * itself, which would blind the very check meant to catch it. If
             * the server stays this way, the pause simply keeps renewing —
             * accepted trade-off, no auto-recovery timeout. */
            g_fServerLagPauseUntil = engineNow + SERVER_LAG_PAUSE_SECS;
            g_iTriggerTPS          = g_iCurrentTPS;
        }
        else
        {
            /* Healthy window — let the baseline drift toward it. This is what
             * makes the margin dynamic: a sustained new normal (more players,
             * a heavier map) gets absorbed over time instead of staying
             * permanently flagged against a stale calibration. */
            g_fTPSBaselineEWMA = (SERVER_LAG_BASELINE_ALPHA * float(g_iCurrentTPS))
                + ((1.0 - SERVER_LAG_BASELINE_ALPHA) * g_fTPSBaselineEWMA);
        }
    }
}