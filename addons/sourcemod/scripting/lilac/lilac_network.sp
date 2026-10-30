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
	Network safety veto.

	Used by aimbot and aimlock, whose analysis depends on the order and
	timing of consecutive usercmds, and by speedhack — a burst caused by a
	client-side stall (loss/choke/jitter) looks identical to a real command
	flood, even though speedhack's own metric (cmds/sec) isn't timing-based
	the way aimbot's is. Infected damage checks raw damage values instead,
	which isn't distorted by latency or jitter, so it keeps using the
	simpler skip_due_to_loss().
*/

void lilac_network_reset_client(int client)
{
	playerinfo_net_index[client] = 0;
	playerinfo_net_count[client] = 0;

	for (int i = 0; i < NET_SAMPLES; i++) {
		playerinfo_net_ping[client][i] = 0.0;
		playerinfo_net_valid[client][i] = false;
	}

	lilac_network_burst_reset(client);
}

static void lilac_network_burst_reset(int client)
{
	playerinfo_burst_index[client] = 0;
	playerinfo_burst_count[client] = 0;
	playerinfo_burst_tick[client] = -1;
	playerinfo_burst_cur[client] = 0;
}

/* Forget the bursts seen before the network telemetry was switched on. */
void lilac_network_burst_reset_all()
{
	for (int i = 0; i <= MAXPLAYERS; i++)
		lilac_network_burst_reset(i);
}

/* Commands the server ran for this player in one tick. Telemetry only,
 * never used to veto. */
void lilac_network_burst_cmd(int client)
{
	if (!(icvar[CVAR_TELEMETRY] & TELEMETRY_NETWORK))
		return;

	/* A lagging server bursts every player. */
	if (lilac_server_is_lagging()) {
		playerinfo_burst_tick[client] = -1;
		playerinfo_burst_cur[client] = 0;
		return;
	}

	int tick = GetGameTickCount();

	if (tick == playerinfo_burst_tick[client]) {
		playerinfo_burst_cur[client]++;
		return;
	}

	if (playerinfo_burst_cur[client] > 0) {
		playerinfo_burst_ring[client][playerinfo_burst_index[client]] = playerinfo_burst_cur[client];

		if (++playerinfo_burst_index[client] >= NET_BURST_SAMPLES)
			playerinfo_burst_index[client] = 0;

		if (playerinfo_burst_count[client] < NET_BURST_SAMPLES)
			playerinfo_burst_count[client]++;
	}

	playerinfo_burst_tick[client] = tick;
	playerinfo_burst_cur[client] = 1;
}

/* Average, maximum and spread of the last bursts, plus the packets and
 * commands per second behind them. */
void lilac_network_format_burst(int client, char[] buffer, int maxlen)
{
	int n = playerinfo_burst_count[client];
	char stats[40];

	if (n < NET_BURST_MIN) {
		strcopy(stats, sizeof(stats), "n/a");
	}
	else {
		float sum = 0.0, sq = 0.0;
		int max = 0;

		for (int i = 0; i < n; i++) {
			int b = playerinfo_burst_ring[client][i];

			sum += float(b);
			sq += float(b * b);

			if (b > max)
				max = b;
		}

		float avg = sum / float(n);
		float sd = SquareRoot(FloatAbs(sq / float(n) - avg * avg));

		FormatEx(stats, sizeof(stats), "avg %.1f max %d sd %.1f", avg, max, sd);
	}

	FormatEx(buffer, maxlen, "%s pkts/s %.0f cmds/s %d", stats,
		GetClientAvgPackets(client, NetFlow_Incoming),
		lilac_recent_cmd_count(client, GetGameTime()));
}

public Action timer_sample_network(Handle timer)
{
	if (!icvar[CVAR_ENABLE])
		return Plugin_Continue;

	for (int i = 1; i <= MaxClients; i++) {
		if (!is_player_valid(i) || IsFakeClient(i))
			continue;

		int idx = playerinfo_net_index[i];
		float ping = GetClientAvgLatency(i, NetFlow_Outgoing) * 1000.0;

		/* reject negatives and absurd values. */
		playerinfo_net_valid[i][idx] = (ping >= 0.0 && ping < 10000.0);
		playerinfo_net_ping[i][idx] = ping;

		if (++playerinfo_net_index[i] >= NET_SAMPLES)
			playerinfo_net_index[i] = 0;

		if (playerinfo_net_count[i] < NET_SAMPLES)
			playerinfo_net_count[i]++;
	}

	return Plugin_Continue;
}

/* Mean absolute variation between consecutive ping samples.
 * The engine does not expose jitter, so it is derived from our own sampling.
 * Returns -1.0 when there is not enough contiguous valid data. */
float lilac_network_get_jitter(int client)
{
	float total = 0.0;
	float last = -1.0;
	int pairs = 0;
	int n = playerinfo_net_count[client];

	if (n < 2)
		return -1.0;

	/* Walk oldest to newest. */
	int start = (n < NET_SAMPLES) ? 0 : playerinfo_net_index[client];

	for (int k = 0; k < n; k++) {
		int i = (start + k) % NET_SAMPLES;

		if (!playerinfo_net_valid[client][i]) {
			last = -1.0; /* a gap breaks the chain */
			continue;
		}

		if (last >= 0.0) {
			total += FloatAbs(playerinfo_net_ping[client][i] - last);
			pairs++;
		}

		last = playerinfo_net_ping[client][i];
	}

	return (pairs > 0) ? (total / float(pairs)) : -1.0;
}

float lilac_network_get_max_ping(int client)
{
	float max = 0.0;

	for (int k = 0; k < playerinfo_net_count[client]; k++) {
		if (playerinfo_net_valid[client][k] && playerinfo_net_ping[client][k] > max)
			max = playerinfo_net_ping[client][k];
	}

	return max;
}

int lilac_network_get_invalid_count(int client)
{
	int invalid = 0;

	for (int k = 0; k < playerinfo_net_count[client]; k++) {
		if (!playerinfo_net_valid[client][k])
			invalid++;
	}

	return invalid;
}

/* Numbers behind the decision, so an admin can see why a detection
 * was not trusted — and so thresholds can be recalibrated from real data. */
void lilac_network_format(int client, char[] buffer, int maxlen)
{
	char burst[112];
	burst[0] = '\0';

	if (icvar[CVAR_TELEMETRY] & TELEMETRY_NETWORK) {
		char stats[96];
		lilac_network_format_burst(client, stats, sizeof(stats));
		FormatEx(burst, sizeof(burst), " | Burst: %s", stats);
	}

	FormatEx(buffer, maxlen,
		"Ping: %.0f | Jitter: %.1f | Loss: %.1f/%.1f | Choke: %.1f/%.1f | BadSamples: %d%s",
		lilac_network_get_max_ping(client),
		lilac_network_get_jitter(client),
		GetClientAvgLoss(client, NetFlow_Incoming) * 100.0,
		GetClientAvgLoss(client, NetFlow_Outgoing) * 100.0,
		GetClientAvgChoke(client, NetFlow_Incoming) * 100.0,
		GetClientAvgChoke(client, NetFlow_Outgoing) * 100.0,
		lilac_network_get_invalid_count(client), burst);
}

/* High choke that a real connection can produce. Values above
 * NET_CHOKE_VALID_MAX are corrupted data, not a bad connection. */
static bool lilac_network_choke_bad(float choke)
{
	return choke >= NET_MAX_CHOKE && choke <= NET_CHOKE_VALID_MAX;
}

/* True when the connection makes timing-based analysis unreliable. */
bool lilac_network_vetoed(int client)
{
	if (!icvar[CVAR_NET_VETO])
		return false;

	/* Not enough data yet. */
	if (playerinfo_net_count[client] < 2)
		return true;

	if (lilac_network_get_invalid_count(client) > 0)
		return true;

	float jitter = lilac_network_get_jitter(client);

	if (jitter < 0.0 || jitter >= NET_MAX_JITTER)
		return true;

	if (lilac_network_get_max_ping(client) >= NET_MAX_PING)
		return true;

	/* Loss and choke of a player far ahead in tickbase are corrupted. */
	if (lilac_tickbase_runaway(client))
		return false;

	if (GetClientAvgLoss(client, NetFlow_Incoming) >= NET_MAX_LOSS
		|| GetClientAvgLoss(client, NetFlow_Outgoing) >= NET_MAX_LOSS)
		return true;

	if (lilac_network_choke_bad(GetClientAvgChoke(client, NetFlow_Incoming))
		|| lilac_network_choke_bad(GetClientAvgChoke(client, NetFlow_Outgoing)))
		return true;

	return false;
}