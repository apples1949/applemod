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

/*
	Discord webhook reports.

	Optional: needs the REST in Pawn extension (ripext). Without it, or
	without a webhook URL, every function here does nothing.

	Reports are queued and sent one at a time, spaced out to stay under
	Discord's rate limit, and never block the server.
*/

#if defined _ripext_included_

#define DISCORD_QUEUE_MAX          25
#define DISCORD_PAYLOAD_SIZE       4096
#define DISCORD_SEND_SPACING       2.0   /* Seconds between two requests. */
#define DISCORD_SUSPECT_COOLDOWN   60.0  /* Per player and cheat. */
#define DISCORD_MAX_ATTEMPTS       2
#define DISCORD_INFLIGHT_TIMEOUT   30.0  /* Longer than any request can take. */

#define DISCORD_COLOR_BAN          15548997 /* Red. */
#define DISCORD_COLOR_KICK         15105570 /* Orange. */
#define DISCORD_COLOR_SUSPECT      16705372 /* Yellow. */

/* Layout of one entry in discord_meta. */
#define DISCORD_META_USERID        0
#define DISCORD_META_CHEAT         1
#define DISCORD_META_OUTCOME       2
#define DISCORD_META_ATTEMPTS      3
#define DISCORD_META_TEST          4
#define DISCORD_META_SIZE          5

static ArrayList discord_payloads = null; /* JSON strings waiting to be sent. */
static ArrayList discord_meta = null;     /* One DISCORD_META_SIZE block per payload. */
static bool discord_inflight = false;     /* The first entry is being sent. */
static float discord_inflight_since = 0.0;
static bool discord_disabled = false;     /* The webhook was refused, stop until it changes. */
static float discord_next_send = 0.0;
static float discord_last_suspect[MAXPLAYERS + 1][CHEAT_MAX + 1];

/* Extra evidence lines a module adds for Discord only. Kept per cheat, so
 * the lines of one cheat never show up on another's report. */
static char discord_extra[MAXPLAYERS + 1][256];
static int discord_extra_cheat[MAXPLAYERS + 1];

void lilac_discord_init()
{
	discord_payloads = new ArrayList(ByteCountToCells(DISCORD_PAYLOAD_SIZE));
	discord_meta = new ArrayList(DISCORD_META_SIZE);

	CreateTimer(1.0, timer_discord_flush, _, TIMER_REPEAT);
}

void lilac_discord_reset_client(int client)
{
	for (int i = 0; i <= CHEAT_MAX; i++)
		discord_last_suspect[client][i] = 0.0;

	discord_extra[client][0] = '\0';
	discord_extra_cheat[client] = -1;
}

void lilac_discord_set_extra(int client, int cheat, const char[] text)
{
	strcopy(discord_extra[client], sizeof(discord_extra[]), text);
	discord_extra_cheat[client] = cheat;
}

void lilac_discord_reset()
{
	discord_disabled = false;
}

static bool discord_available()
{
	return NATIVE_EXISTS("HTTPRequest.HTTPRequest");
}

static bool discord_url_valid(const char[] url)
{
	return StrContains(url, "https://", false) == 0
		&& StrContains(url, "/api/webhooks/", false) > 0;
}

/* Escape the characters Discord would read as markdown. */
static void discord_escape(const char[] src, char[] dst, int maxlen)
{
	int n = 0;

	for (int i = 0; src[i] != '\0' && n < maxlen - 2; i++) {
		switch (src[i]) {
		case '\\', '*', '_', '~', '`', '|', '>', '[', ']', '(', ')': {
			dst[n++] = '\\';
		}
		}

		dst[n++] = src[i];
	}

	dst[n] = '\0';
}

/* ISO 8601 in UTC. FormatTime() would use the server's time zone. */
static void discord_utc(char[] buffer, int maxlen)
{
	int now = GetTime();
	int days = now / 86400;
	int secs = now % 86400;

	/* Days since 1970-01-01 to a civil date. */
	int z = days + 719468;
	int era = z / 146097;
	int doe = z - era * 146097;
	int yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
	int year = yoe + era * 400;
	int doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
	int mp = (5 * doy + 2) / 153;
	int day = doy - (153 * mp + 2) / 5 + 1;
	int month = (mp < 10) ? mp + 3 : mp - 9;

	if (month <= 2)
		year++;

	FormatEx(buffer, maxlen, "%04d-%02d-%02dT%02d:%02d:%02dZ",
		year, month, day, secs / 3600, (secs % 3600) / 60, secs % 60);
}

static void discord_get_address(char[] buffer, int maxlen)
{
	hcvar[CVAR_DISCORD_ADDRESS].GetString(buffer, maxlen);

	if (buffer[0] != '\0')
		return;

	ConVar hostip = FindConVar("hostip");
	ConVar hostport = FindConVar("hostport");

	if (hostip == null || hostport == null)
		return;

	int ip = hostip.IntValue;

	if (ip == 0)
		return;

	FormatEx(buffer, maxlen, "%d.%d.%d.%d:%d",
		(ip >> 24) & 0xFF, (ip >> 16) & 0xFF, (ip >> 8) & 0xFF, ip & 0xFF,
		hostport.IntValue);
}

static bool discord_is_digits(const char[] value)
{
	if (value[0] == '\0')
		return false;

	for (int i = 0; value[i] != '\0'; i++) {
		if (value[i] < '0' || value[i] > '9')
			return false;
	}

	return true;
}

static void discord_add_field(JSONArray fields, const char[] name, const char[] value, bool wide)
{
	JSONObject field = new JSONObject();

	field.SetString("name", name);

	/* Fails on invalid UTF-8, don't let one bad name lose the report. */
	if (!field.SetString("value", value))
		field.SetString("value", "-");

	/* "Inline" fields share a row, the others take the full width. */
	field.SetBool("inline", !wide);

	fields.Push(field);
	delete field;
}

static void discord_format_duration(float seconds, char[] buffer, int maxlen)
{
	int total = RoundToFloor(seconds);

	if (total >= 3600)
		FormatEx(buffer, maxlen, "%dh %02dm", total / 3600, (total % 3600) / 60);
	else
		FormatEx(buffer, maxlen, "%dm %02ds", total / 60, total % 60);
}

/* Short summary of the player's state, same data as the extra log line. */
static void discord_client_context(int client, char[] buffer, int maxlen)
{
	char weapon[64], shown[64], team[16], connected[16];

	GetClientWeapon(client, weapon, sizeof(weapon));
	strcopy(shown, sizeof(shown), weapon);
	ReplaceString(shown, sizeof(shown), "weapon_", "");

	if (shown[0] == '\0')
		strcopy(shown, sizeof(shown), "none");

	lilac_team_name(GetClientTeam(client), team, sizeof(team));
	discord_format_duration(GetClientTime(client), connected, sizeof(connected));

	FormatEx(buffer, maxlen,
		"Weapon: %s | Team: %s\nPing: %.0fms | Loss: %.1f%%/%.1f%% | Choke: %.1f%%/%.1f%%\nConnected: %s",
		shown, team,
		GetClientAvgLatency(client, NetFlow_Outgoing) * 1000.0,
		GetClientAvgLoss(client, NetFlow_Incoming) * 100.0,
		GetClientAvgLoss(client, NetFlow_Outgoing) * 100.0,
		GetClientAvgChoke(client, NetFlow_Incoming) * 100.0,
		GetClientAvgChoke(client, NetFlow_Outgoing) * 100.0,
		connected);
}

/* Builds the embed from plain values. An empty steamid means it is unavailable. */
static JSONObject discord_build_payload(const char[] name, const char[] steamid, const char[] cheat_name, const char[] details, const char[] extra, const char[] context, int outcome)
{
	char safe_name[MAX_NAME_LENGTH * 3], map[128], matchid[64];
	char server[128], address[64], logo[512], role[32];
	/* A field value can't be over 1024 characters, the code block adds 12. */
	char evidence[1000], value[1100], timestamp[32], footer[96];

	bool has_steamid = (steamid[0] != '\0');

	discord_escape(name, safe_name, sizeof(safe_name));

	GetCurrentMap(map, sizeof(map));

	ConVar hostname = FindConVar("hostname");

	if (hostname != null)
		hostname.GetString(server, sizeof(server));

	if (server[0] == '\0')
		strcopy(server, sizeof(server), "Server");

	discord_get_address(address, sizeof(address));

	matchid[0] = '\0';
	if (icvar[CVAR_AR] && NATIVE_EXISTS("AR_GetMatchID"))
		AR_GetMatchID(matchid, sizeof(matchid));

	hcvar[CVAR_DISCORD_LOGO].GetString(logo, sizeof(logo));
	if (StrContains(logo, "http", false) != 0)
		logo[0] = '\0';

	/* The details Lilac logged for this player (never the IP), one per line. */
	strcopy(evidence, sizeof(evidence), details);
	ReplaceString(evidence, sizeof(evidence), " | ", "\n");

	if (evidence[0] == '\0')
		strcopy(evidence, sizeof(evidence), "The detector reached its configured threshold.");

	if (extra[0] != '\0') {
		StrCat(evidence, sizeof(evidence), "\n");
		StrCat(evidence, sizeof(evidence), extra);
	}

	ReplaceString(evidence, sizeof(evidence), "```", "'''");

	int color = DISCORD_COLOR_SUSPECT;
	char punishment[128];

	switch (outcome) {
	case DISCORD_BANNED: {
		color = DISCORD_COLOR_BAN;
		strcopy(punishment, sizeof(punishment), "The player was banned.");
	}
	case DISCORD_KICKED: {
		color = DISCORD_COLOR_KICK;
		strcopy(punishment, sizeof(punishment), "The player was kicked.");
	}
	default: {
		strcopy(punishment, sizeof(punishment), "None yet. Suspected detection, the player was not punished.");
	}
	}

	discord_utc(timestamp, sizeof(timestamp));
	FormatEx(footer, sizeof(footer), "Lilac %s • Detection report", PLUGIN_VERSION);

	JSONArray fields = new JSONArray();

	if (has_steamid)
		FormatEx(value, sizeof(value), "[%s](https://steamcommunity.com/profiles/%s)", safe_name, steamid);
	else
		strcopy(value, sizeof(value), safe_name);
	discord_add_field(fields, "Player", value, false);

	if (has_steamid)
		FormatEx(value, sizeof(value), "||%s||", steamid);
	else
		strcopy(value, sizeof(value), "Unavailable");
	discord_add_field(fields, "STEAMID64", value, false);

	FormatEx(value, sizeof(value), "`%s`", cheat_name);
	discord_add_field(fields, "Detection", value, true);

	FormatEx(value, sizeof(value), "```text\n%s\n```", evidence);
	discord_add_field(fields, "Evidence", value, true);

	if (context[0] != '\0') {
		FormatEx(value, sizeof(value), "```text\n%s\n```", context);
		discord_add_field(fields, "Context", value, true);
	}

	discord_add_field(fields, "Punishment", punishment, true);

	FormatEx(value, sizeof(value), "`%s`", map);
	discord_add_field(fields, "Map", value, false);

	if (address[0] != '\0') {
		FormatEx(value, sizeof(value), "`%s`", address);
		discord_add_field(fields, "Address", value, false);
	}

	if (matchid[0] != '\0') {
		FormatEx(value, sizeof(value), "`%s`", matchid);
		discord_add_field(fields, "MatchID", value, false);
	}

	JSONObject embed = new JSONObject();

	JSONObject author = new JSONObject();
	if (!author.SetString("name", server))
		author.SetString("name", "Server");
	if (logo[0] != '\0')
		author.SetString("icon_url", logo);
	embed.Set("author", author);
	delete author;

	embed.SetInt("color", color);

	if (logo[0] != '\0') {
		JSONObject thumbnail = new JSONObject();
		thumbnail.SetString("url", logo);
		embed.Set("thumbnail", thumbnail);
		delete thumbnail;
	}

	embed.Set("fields", fields);
	delete fields;

	embed.SetString("timestamp", timestamp);

	JSONObject footer_obj = new JSONObject();
	footer_obj.SetString("text", footer);
	if (logo[0] != '\0')
		footer_obj.SetString("icon_url", logo);
	embed.Set("footer", footer_obj);
	delete footer_obj;

	JSONArray embeds = new JSONArray();
	embeds.Push(embed);
	delete embed;

	JSONObject root = new JSONObject();
	root.SetString("username", "Lilac");
	root.Set("embeds", embeds);
	delete embeds;

	/* Never let a player name ping anyone, only the configured role, on bans. */
	JSONObject allowed = new JSONObject();
	JSONArray parse = new JSONArray();
	allowed.Set("parse", parse);
	delete parse;

	hcvar[CVAR_DISCORD_ROLE].GetString(role, sizeof(role));
	if (outcome == DISCORD_BANNED && discord_is_digits(role)) {
		FormatEx(value, sizeof(value), "<@&%s>", role);
		root.SetString("content", value);

		JSONArray roles = new JSONArray();
		roles.PushString(role);
		allowed.Set("roles", roles);
		delete roles;
	}

	root.Set("allowed_mentions", allowed);
	delete allowed;

	return root;
}

static JSONObject discord_build(int client, int cheat, int outcome, const char[] details)
{
	char name[MAX_NAME_LENGTH], steamid[32], cheat_name[64];

	GetClientName(client, name, sizeof(name));

	if (!GetClientAuthId(client, AuthId_SteamID64, steamid, sizeof(steamid), true))
		steamid[0] = '\0';

	cheat_name[0] = '\0';

	if (cheat == DISCORD_CHEAT_TICKBASE)
		strcopy(cheat_name, sizeof(cheat_name), "Tickbase");
	else
		GetCheatName(cheat, cheat_name, sizeof(cheat_name));

	char context[256], extra[256];
	extra[0] = '\0';

	discord_client_context(client, context, sizeof(context));

	if (discord_extra_cheat[client] == cheat)
		strcopy(extra, sizeof(extra), discord_extra[client]);

	return discord_build_payload(name, steamid, cheat_name, details, extra, context, outcome);
}

/* Drop the queued suspect reports this ban makes redundant. The first entry
 * is skipped while it is being sent. */
static void discord_drop_suspects(int userid, int cheat)
{
	int meta[DISCORD_META_SIZE];

	for (int i = discord_payloads.Length - 1; i >= (discord_inflight ? 1 : 0); i--) {
		discord_meta.GetArray(i, meta);

		if (meta[DISCORD_META_USERID] == userid
			&& meta[DISCORD_META_CHEAT] == cheat
			&& meta[DISCORD_META_OUTCOME] == DISCORD_SUSPECT) {
			discord_payloads.Erase(i);
			discord_meta.Erase(i);
		}
	}
}

/* Queue a report with the details Lilac saved for this player. Safe to call
 * whenever, it decides on its own if anything should be sent. */
void lilac_discord_report(int client, int cheat, int outcome)
{
	discord_report(client, cheat, outcome, playerinfo_detected[client]);
}

/* Same, with details given by the caller. */
void lilac_discord_report_details(int client, int cheat, int outcome, const char[] details)
{
	discord_report(client, cheat, outcome, details);
}

static void discord_report(int client, int cheat, int outcome, const char[] details)
{
	char url[512];

	if (!icvar[CVAR_DISCORD] || discord_disabled || discord_payloads == null)
		return;

	if (outcome == DISCORD_SUSPECT && icvar[CVAR_DISCORD] < 2)
		return;

	if (cheat < 0 || cheat > DISCORD_CHEAT_TICKBASE)
		return;

	if (!is_player_valid(client) || IsFakeClient(client))
		return;

	if (!discord_available())
		return;

	hcvar[CVAR_DISCORD_WEBHOOK].GetString(url, sizeof(url));
	if (!discord_url_valid(url))
		return;

	int userid = GetClientUserId(client);

	if (outcome == DISCORD_SUSPECT) {
		float now = GetEngineTime();

		if (discord_last_suspect[client][cheat] > 0.0
			&& now - discord_last_suspect[client][cheat] < DISCORD_SUSPECT_COOLDOWN)
			return;

		discord_last_suspect[client][cheat] = now;
	}
	else {
		discord_drop_suspects(userid, cheat);
	}

	discord_enqueue(discord_build(client, cheat, outcome, details), userid, cheat, outcome, false);
}

/* Serialize and queue a report. Takes ownership of root. */
static bool discord_enqueue(JSONObject root, int userid, int cheat, int outcome, bool test)
{
	char payload[DISCORD_PAYLOAD_SIZE];
	bool ok = root.ToString(payload, sizeof(payload), JSON_COMPACT);
	delete root;

	if (!ok)
		return false;

	/* Full, forget the oldest one that isn't being sent. */
	if (discord_payloads.Length >= DISCORD_QUEUE_MAX) {
		int oldest = discord_inflight ? 1 : 0;

		discord_payloads.Erase(oldest);
		discord_meta.Erase(oldest);
	}

	int meta[DISCORD_META_SIZE];
	meta[DISCORD_META_USERID] = userid;
	meta[DISCORD_META_CHEAT] = cheat;
	meta[DISCORD_META_OUTCOME] = outcome;
	meta[DISCORD_META_ATTEMPTS] = 0;
	meta[DISCORD_META_TEST] = test ? 1 : 0;

	discord_payloads.PushString(payload);
	discord_meta.PushArray(meta);

	return true;
}

/* lilac_discord_test [ban|kick|suspect]
 * Sends a sample report, to check the webhook and how it looks without
 * waiting for a real detection. Works even when lilac_discord is 0. */
public Action lilac_discord_test(int args)
{
	char arg[16], url[512], role[32];
	int outcome = DISCORD_SUSPECT;

	if (args >= 1) {
		GetCmdArg(1, arg, sizeof(arg));

		if (StrEqual(arg, "ban", false))
			outcome = DISCORD_BANNED;
		else if (StrEqual(arg, "kick", false))
			outcome = DISCORD_KICKED;
		else if (!StrEqual(arg, "suspect", false)) {
			PrintToServer("Usage: lilac_discord_test [ban|kick|suspect]");
			return Plugin_Handled;
		}
	}

	if (!discord_available()) {
		PrintToServer("[Lilac] The REST in Pawn extension isn't loaded.");
		return Plugin_Handled;
	}

	hcvar[CVAR_DISCORD_WEBHOOK].GetString(url, sizeof(url));
	if (!discord_url_valid(url)) {
		PrintToServer("[Lilac] lilac_discord_webhook isn't a valid Discord webhook URL (https://discord.com/api/webhooks/...).");
		return Plugin_Handled;
	}

	/* Try again, whatever made the last request fail may be fixed. */
	discord_disabled = false;

	JSONObject root = discord_build_payload("Lilac Test", "76561197960265728", "Test",
		"This is a test report from lilac_discord_test.\nIf you can read it, the webhook works.",
		"Extra: lines a module adds to its evidence.",
		"Weapon: pistol | Team: Survivor\nPing: 62ms | Loss: 0.0%/0.0% | Choke: 0.0%/0.0%\nConnected: 8m 12s",
		outcome);

	if (!discord_enqueue(root, 0, 0, outcome, true)) {
		PrintToServer("[Lilac] Could not build the test report.");
		return Plugin_Handled;
	}

	PrintToServer("[Lilac] Test report queued, the result is printed here in a few seconds.");

	hcvar[CVAR_DISCORD_ROLE].GetString(role, sizeof(role));
	if (outcome == DISCORD_BANNED && discord_is_digits(role))
		PrintToServer("[Lilac] Note: a ban report mentions the role set in lilac_discord_role.");

	if (!icvar[CVAR_DISCORD])
		PrintToServer("[Lilac] Note: lilac_discord is 0, so real reports are off.");

	return Plugin_Handled;
}

static void discord_drop_first()
{
	discord_payloads.Erase(0);
	discord_meta.Erase(0);
}

public Action timer_discord_flush(Handle timer)
{
	if (discord_payloads == null || discord_payloads.Length == 0)
		return Plugin_Continue;

	/* Turned off, forget the waiting reports, but still deliver a test. */
	if (!icvar[CVAR_DISCORD]) {
		int meta[DISCORD_META_SIZE];

		for (int i = discord_payloads.Length - 1; i >= (discord_inflight ? 1 : 0); i--) {
			discord_meta.GetArray(i, meta);

			if (!meta[DISCORD_META_TEST]) {
				discord_payloads.Erase(i);
				discord_meta.Erase(i);
			}
		}

		if (discord_payloads.Length == 0)
			return Plugin_Continue;
	}

	/* No answer at all, never leave the queue stuck behind one request. */
	if (discord_inflight && GetEngineTime() - discord_inflight_since > DISCORD_INFLIGHT_TIMEOUT) {
		discord_inflight = false;
		discord_drop_first();
		return Plugin_Continue;
	}

	if (discord_inflight || discord_disabled || GetEngineTime() < discord_next_send)
		return Plugin_Continue;

	char url[512];
	hcvar[CVAR_DISCORD_WEBHOOK].GetString(url, sizeof(url));

	if (!discord_available() || !discord_url_valid(url))
		return Plugin_Continue;

	char payload[DISCORD_PAYLOAD_SIZE];
	discord_payloads.GetString(0, payload, sizeof(payload));

	JSONObject body = JSONObject.FromString(payload);

	if (body == null) {
		discord_drop_first();
		return Plugin_Continue;
	}

	HTTPRequest request = new HTTPRequest(url);
	request.Timeout = 10;

	discord_inflight = true;
	discord_inflight_since = GetEngineTime();

	/* Post() closes the request by itself. */
	request.Post(body, discord_on_response);
	delete body;

	return Plugin_Continue;
}

public void discord_on_response(HTTPResponse response, any value, const char[] error)
{
	discord_inflight = false;
	discord_next_send = GetEngineTime() + DISCORD_SEND_SPACING;

	/* The queue was cleared while this was being sent. */
	if (discord_payloads.Length == 0)
		return;

	HTTPStatus status = HTTPStatus_Invalid;
	if (error[0] == '\0')
		status = response.Status;

	int meta[DISCORD_META_SIZE];
	discord_meta.GetArray(0, meta);

	if (status >= HTTPStatus_OK && status < HTTPStatus_MultipleChoices) {
		if (meta[DISCORD_META_TEST])
			PrintToServer("[Lilac] Discord test report delivered (HTTP %d).", view_as<int>(status));

		discord_drop_first();
		return;
	}

	/* The URL is wrong or was revoked, retrying is pointless. */
	if (status == HTTPStatus_Unauthorized
		|| status == HTTPStatus_Forbidden
		|| status == HTTPStatus_NotFound) {
		discord_disabled = true;
		discord_payloads.Clear();
		discord_meta.Clear();

		PrintToServer("[Lilac] Discord webhook refused (HTTP %d). Reports are off until lilac_discord_webhook changes.", view_as<int>(status));
		return;
	}

	if (++meta[DISCORD_META_ATTEMPTS] >= DISCORD_MAX_ATTEMPTS) {
		PrintToServer("[Lilac] A Discord report was dropped (HTTP %d).", view_as<int>(status));
		discord_drop_first();
		return;
	}

	discord_meta.SetArray(0, meta);

	/* Rate limited or a hiccup, try again once. */
	float wait = 5.0;

	if (status == HTTPStatus_TooManyRequests) {
		char retry[16];

		wait = 2.0;
		if (response.GetHeader("Retry-After", retry, sizeof(retry)))
			wait = StringToFloat(retry);

		if (wait < 1.0)
			wait = 1.0;
		else if (wait > 60.0)
			wait = 60.0;
	}

	discord_next_send = GetEngineTime() + wait;
}

#else /* ripext isn't available in this build, keep the callers compiling. */

void lilac_discord_init() {}
void lilac_discord_reset() {}

void lilac_discord_reset_client(int client)
{
	#pragma unused client
}

void lilac_discord_report(int client, int cheat, int outcome)
{
	#pragma unused client
	#pragma unused cheat
	#pragma unused outcome
}

void lilac_discord_report_details(int client, int cheat, int outcome, const char[] details)
{
	#pragma unused client
	#pragma unused cheat
	#pragma unused outcome
	#pragma unused details
}

void lilac_discord_set_extra(int client, int cheat, const char[] text)
{
	#pragma unused client
	#pragma unused cheat
	#pragma unused text
}

public Action lilac_discord_test(int args)
{
	#pragma unused args
	PrintToServer("[Lilac] This build was compiled without the REST in Pawn include, Discord reports are unavailable.");
	return Plugin_Handled;
}

#endif
