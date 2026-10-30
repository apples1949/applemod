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

#define NATIVE_EXISTS(%0)   (GetFeatureStatus(FeatureType_Native, %0) == FeatureStatus_Available)

/* Log text for a ban, true to what really happens (lilac_ban 0, log only). */
#define LILAC_BANNED_TEXT(%0)           (lilac_ban_active(%0) ? "was banned" : "would have been banned")
#define LILAC_DETECTED_BANNED_TEXT(%0)  (lilac_ban_active(%0) ? "was detected and banned" : "would have been banned")

#define CMD_LENGTH   330

#define CVAR_ENABLE                 0
#define CVAR_WELCOME                1
#define CVAR_SB                     2
#define CVAR_MA                     3
#define CVAR_AR                     4
#define CVAR_LOG                    5
#define CVAR_LOG_EXTRA              6
#define CVAR_LOG_MISC               7
#define CVAR_LOG_DATE               8
#define CVAR_BAN                    9
#define CVAR_BAN_LENGTH             10
#define CVAR_BAN_LANGUAGE          11
#define CVAR_CHEAT_WARN            12
#define CVAR_ANGLES                13
#define CVAR_PATCH_ANGLES          14
#define CVAR_CHAT                  15
#define CVAR_CONVAR                16
#define CVAR_NOLERP                17
#define CVAR_BHOP                  18
#define CVAR_AIMBOT                19
#define CVAR_AIMBOT_AUTOSHOOT      20
#define CVAR_AIMLOCK               21
#define CVAR_AIMLOCK_LIGHT         22
#define CVAR_BACKTRACK_PATCH       23
#define CVAR_BACKTRACK_TOLERANCE   24
#define CVAR_MAX_PING              25
#define CVAR_MAX_PING_SPEC         26
#define CVAR_MAX_LERP              27
#define CVAR_MACRO                 28
#define CVAR_MACRO_WARNING         29
#define CVAR_MACRO_DEAL_METHOD     30
#define CVAR_MACRO_MODE            31
#define CVAR_FILTER_NAME           32
#define CVAR_FILTER_CHAT           33
#define CVAR_LOSS_FIX              34
#define CVAR_SOURCEIRC             35
#define CVAR_DATABASE              36
#define CVAR_SPEEDHACK             37
#define CVAR_INFECTED_DMG          38
#define CVAR_NET_VETO              39
#define CVAR_SURVIVOR_DMG          40
#define CVAR_DISCORD               41
#define CVAR_DISCORD_WEBHOOK       42
#define CVAR_DISCORD_ROLE          43
#define CVAR_DISCORD_ADDRESS       44
#define CVAR_DISCORD_LOGO          45
#define CVAR_TELEMETRY             46
#define CVAR_MAX                   47

/* Bits of lilac_telemetry. Measurement and debug only, they never change a
 * decision. */
#define TELEMETRY_AIMBOT           (1 << 0)
#define TELEMETRY_SPEEDHACK        (1 << 1)
#define TELEMETRY_NETWORK          (1 << 2)
#define TELEMETRY_DAMAGE           (1 << 3)

/* What happened to the player, for Discord reports. */
#define DISCORD_BANNED             0
#define DISCORD_KICKED             1
#define DISCORD_SUSPECT            2

/* Report type that isn't a Lilac cheat (kept after the real ones). */
#define DISCORD_CHEAT_TICKBASE     CHEAT_MAX

#define BHOP_INDEX_MIN     0
#define BHOP_INDEX_JUMP    1
#define BHOP_INDEX_MAX     2
#define BHOP_INDEX_TOTAL   3
#define BHOP_INDEX_AIR     4
#define BHOP_MAX           5

#define BHOP_MODE_DISABLED     0
#define BHOP_MODE_RESERVED_1   1
#define BHOP_MODE_RESERVED_2   2
#define BHOP_MODE_CUSTOM       3
#define BHOP_MODE_LOW          4
#define BHOP_MODE_MEDIUM       5
#define BHOP_MODE_HIGH         6

#define MACRO_LOG_LENGTH   200

#define MACRO_AUTOJUMP    0
#define MACRO_AUTOSHOOT   1
#define MACRO_ARRAY       2

#define ACTION_SHOT   1

#define QUERY_MAX_FAILURES   24
#define QUERY_TIMEOUT        30
#define QUERY_TIMER          5.0

#define AIMLOCK_BAN_MIN   5

/* Third-person/emote/dance plugins (and some scripted sequences) force the
 * camera external via m_TimeForceExternalView — a standard engine prop, not
 * anything specific to one plugin. While it's active the player isn't
 * actually controlling their view, so the sent viewangles sit frozen —
 * indistinguishable from a real aimlock. Grace period covers the short
 * window right after it ends too, since aimlock's own analysis looks at
 * ~0.6s of angle history that can still span the forced period. */
#define CAMERA_FORCED_GRACE_SECS  1.0

/* L4D2 infected are placed by the game while in ghost state and materialize
 * or get teleported facing a survivor, which looks like an aimlock. Grace
 * covers the angle history that still spans the ghost period. */
#define GHOST_GRACE_SECS  2.0
#define AIMLOCK_REPEAT_SECS  1.0
#define AIMLOCK_MIN_TRACK_DEG  0.1

#define INFECTED_DMG_BAN_MIN 3
#define SURVIVOR_DMG_BAN_MIN 3

/* L4D2 zombie classes (m_zombieClass). */
#define L4D2_ZC_SMOKER   1
#define L4D2_ZC_BOOMER   2
#define L4D2_ZC_HUNTER   3
#define L4D2_ZC_SPITTER  4
#define L4D2_ZC_JOCKEY   5
#define L4D2_ZC_CHARGER  6
#define L4D2_ZC_WITCH    7
#define L4D2_ZC_TANK     8

#define AIMBOT_BAN_MIN           5
#define AIMBOT_MAX_TOTAL_DELTA   (180.0 * 2.5)
#define AIMBOT_FLAG_REPEAT       (1 << 0)
#define AIMBOT_FLAG_AUTOSHOOT    (1 << 1)
#define AIMBOT_FLAG_SNAP         (1 << 2)
#define AIMBOT_FLAG_SNAP2        (1 << 3)
#define AIMBOT_FLAG_SMOOTH       (1 << 4) /* Monotonic convergence: counters AimStep-style evasion. */
#define AIMBOT_FLAG_JITTER       (1 << 5) /* High pre-shot angle variance combined with an accurate shot. */

#define SPEEDHACK_BAN_MIN    3
#define SPEEDHACK_CMD_RATIO  1.9 /* Flag if cmds/sec > tickrate * this value. */

/* Network safety veto. This is not a detector: it suppresses punishment when
 * the connection makes timing-based analysis unreliable. Aggregation is by
 * maximum, not mean — a single spike inside the window is enough to
 * distrust the sample. */
#define NET_SAMPLES      50      /* 50 samples @ 10Hz = 5 second window */
#define NET_MAX_PING     150.0
#define NET_MAX_JITTER   25.0
#define NET_MAX_LOSS     0.02
/* Commands run per tick, last 64 ticks with commands. Needs 8 to report. */
#define NET_BURST_SAMPLES  64
#define NET_BURST_MIN      8
/* Choke is a rate/bandwidth-budget artifact (client throttling its own send
 * rate versus cl_cmdrate/cl_updaterate), not a direct measure of link
 * instability the way loss/jitter/ping are — a client that never tuned these
 * for a high-tickrate server can sit here permanently without anything
 * actually being wrong with its connection. It is also under the client's
 * control, so a low threshold would let a cheater dodge detections by
 * lowering cl_cmdrate. Only extreme values veto. */
#define NET_MAX_CHOKE    0.90
/* Choke is a fraction from 0 to 1. A higher value is impossible on a real
 * connection: tickbase manipulation corrupts the netchan accounting and
 * inflates it to thousands of percent. Such a value is not evidence of a bad
 * connection, so it must not veto detections (the cheat would blind them). */
#define NET_CHOKE_VALID_MAX  1.0

#define STRFLAG_NEWLINE          (1 << 0) /* Carriage return or Newline. */
#define STRFLAG_WIDE_CHAR_SPAM   (1 << 1) /* Lots of wide character spam. */

#define DATABASE_BAN 0
#define DATABASE_KICK -1
#define DATABASE_LOG_ONLY -2

#define TICKBASE_CLAMP_SECS   2
#define TICKBASE_LOG_SECS    25

/* Tickbase running ahead of the server, not behind. Log-only, see
 * lilac_tickbase_fix_log_ahead(). */
#define TICKBASE_AHEAD_LOG_SECS  2

/* A client this far ahead has corrupted loss/choke stats, so they must not
 * veto its detections. The Discord alert is for the extreme cases. */
#define TICKBASE_RUNAWAY_SECS        5
#define TICKBASE_RUNAWAY_ALERT_SECS  10
#define TICKBASE_RUNAWAY_GRACE_SECS  60.0

/* It also has to keep growing: a stable lead is a stutter or low FPS. */
#define TICKBASE_RUNAWAY_GROWTH_SECS    2
#define TICKBASE_RUNAWAY_GROWTH_WINDOW  10.0

/* Right after a server stall the leads are not manipulation. */
#define TICKBASE_RUNAWAY_LAG_GRACE_SECS 30.0

#define PLUGIN_NAME      "[Lilac] Little Anti-Cheat"
#define PLUGIN_AUTHOR    "J_Tanzanite, Ferks-FK"
#define PLUGIN_DESC      "An opensource Anti-Cheat"
#define PLUGIN_VERSION   "1.8.5"
#define PLUGIN_URL       "https://github.com/J-Tanzanite/Little-Anti-Cheat"

/* Set to 0 to remove all shadow-metric code from the build. */
#define LILAC_ANGLE_METRIC_DEBUG 1

// ============================================================
// Server lag detection
// ============================================================
#define SERVER_LAG_TPS_HIGH_MULT    1.5
#define SERVER_LAG_TPS_LOW_MULT     0.75 // tickspersec below rolling baseline*this = stall/tick-drop
#define SERVER_LAG_PAUSE_SECS       5.0
#define SERVER_LAG_MAP_START_WAIT   15.0
#define SERVER_LAG_CALIB_SAMPLES    15   // seconds of seeding before the rolling baseline goes live
#define SERVER_LAG_CALIB_MIN_RATIO  0.5  // seed samples below nominal*this are rejected
#define SERVER_LAG_BASELINE_ALPHA   0.05 // EWMA weight per healthy window (~20s to fully track a new sustained level)

// TPS counting
int   g_iTicksThisSecond = 0;
float g_fTPSWindowStart   = 0.0;
int   g_iCurrentTPS       = 0;
int   g_iTriggerTPS       = 0;
int   g_iServerTickrate   = 0;

// Rolling baseline — the ongoing "recent normal" TPS. Seeded once via a short
// calibration after map start, then EWMA-updated every window that wasn't
// itself flagged as anomalous, so it drifts to match sustained load changes
// (more players, heavier map) without needing a hand-tuned fixed number.
float g_fTPSBaselineEWMA  = 0.0;
int   g_iTPSCalibSum      = 0;
int   g_iTPSCalibSamples  = 0;

// Lag pause state
float g_fTimeSinceMapStart   = 0.0;
float g_fServerLagPauseUntil = 0.0;
bool  g_bServerLagLogged     = false;

// Tracks whether the TPS window has been armed after the grace period.
bool  g_bTPSWindowArmed      = false;

// Tracks whether the server is currently in a lag pause state.
float g_flTickbaseLastLog[MAXPLAYERS + 1];
float g_flTickbaseAheadLastLog[MAXPLAYERS + 1];
float g_flTickbaseRunawayStart[MAXPLAYERS + 1];
float g_flTickbaseRunawayLast[MAXPLAYERS + 1];
float g_flTickbaseRunawayBaseTime[MAXPLAYERS + 1];
int   g_iTickbaseRunawayBase[MAXPLAYERS + 1];
bool  g_bTickbaseRunawayConfirmed[MAXPLAYERS + 1];
bool  g_bTickbaseRunawayAlerted[MAXPLAYERS + 1];

/* Convars. */
Convar hcvar[CVAR_MAX]; /* ConVar = built in SourceMod  |  Convar = kidfearless's convar_class */
int icvar[CVAR_MAX];
int sv_cheats = 0;
int time_sv_cheats = 0;
int force_disable_bhop = 0;

/* Banlength overwrite. */
int ban_length_overwrite[CHEAT_MAX];

/* Database. */
Database lil_db;
char sql_buffer[1500]; /* It's probably bigger than what you need, but better be safe than sorry I guess. */
char db_name[64]; /* Database config name from hcvar[CVAR_DATABASE]. */

/* Misc. */
EngineVersion g_bGame;

int tick_rate;
int macro_max;
int bhop_settings[BHOP_MAX];
int bhop_settings_min[BHOP_MAX];

char line_buffer[2048];
char dateformat[512] = "%Y/%m/%d %H:%M:%S";
char log_file[PLATFORM_MAX_PATH];
char smooth_telemetry_log_file[PLATFORM_MAX_PATH];
char angle_metric_log_file[PLATFORM_MAX_PATH];
char speedhack_shadow_log_file[PLATFORM_MAX_PATH];
char damage_clock_log_file[PLATFORM_MAX_PATH];
float max_angles[3] = {89.01, 0.0, 50.01};
Handle forwardhandle = INVALID_HANDLE;
Handle forwardhandleban = INVALID_HANDLE;
Handle forwardhandleallow = INVALID_HANDLE;

/* Logging.
 * Todo: Might wanna move a lot of this variables to
 * their own files if they are only used there.
 * Just so the code gets a lot cleaner. */
int playerinfo_index[MAXPLAYERS + 1];
int playerinfo_buttons[MAXPLAYERS + 1][CMD_LENGTH];
int playerinfo_actions[MAXPLAYERS + 1][CMD_LENGTH];
int playerinfo_aimlock_sus[MAXPLAYERS + 1];
int playerinfo_aimlock[MAXPLAYERS + 1];
float playerinfo_time_bumpercart[MAXPLAYERS + 1];
float playerinfo_time_teleported[MAXPLAYERS + 1];
float playerinfo_time_camera_forced[MAXPLAYERS + 1];
float playerinfo_time_ghost[MAXPLAYERS + 1];
float playerinfo_time_aimlock[MAXPLAYERS + 1];
float playerinfo_time_aimlock_hit[MAXPLAYERS + 1];
float playerinfo_time_process_aimlock[MAXPLAYERS + 1];
float playerinfo_angles[MAXPLAYERS + 1][CMD_LENGTH][3];
float playerinfo_time_usercmd[MAXPLAYERS + 1][CMD_LENGTH];
float playerinfo_time_forward[MAXPLAYERS + 1][CHEAT_MAX];
bool playerinfo_banned_flags[MAXPLAYERS + 1][CHEAT_MAX];
char playerinfo_detected[MAXPLAYERS + 1][1024];

float playerinfo_net_ping[MAXPLAYERS + 1][NET_SAMPLES];
bool  playerinfo_net_valid[MAXPLAYERS + 1][NET_SAMPLES];
int   playerinfo_net_index[MAXPLAYERS + 1];
int   playerinfo_net_count[MAXPLAYERS + 1];

int   playerinfo_burst_ring[MAXPLAYERS + 1][NET_BURST_SAMPLES];
int   playerinfo_burst_index[MAXPLAYERS + 1];
int   playerinfo_burst_count[MAXPLAYERS + 1];
int   playerinfo_burst_tick[MAXPLAYERS + 1];
int   playerinfo_burst_cur[MAXPLAYERS + 1];

/* Forward declarations so we don't need third-party include files. */

#define MA_BAN_STEAM  1

#define BAN_BACKEND_BASEBANS       0
#define BAN_BACKEND_SOURCEBANS     1
#define BAN_BACKEND_SOURCEBANSPP   2
#define BAN_BACKEND_MATERIALADMIN  3

native Function IRC_MsgFlaggedChannels(const char[] flag, const char[] format, any ...);
native Function MABanPlayer(int iClient, int iTarget, int iType, int iTime, char[] sReason);
native Function SBBanPlayer(int client, int target, int time, const char[] reason);
native Function SBPP_BanPlayer(int iAdmin, int iTarget, int iTime, const char[] sReason);
native bool AR_GetMatchID(char[] matchID, int maxlen);

/* Optional, from the SourceTV Manager extension. */
native bool SourceTV_IsActive();
native bool SourceTV_IsRecording();
native int SourceTV_GetRecordingTick();
