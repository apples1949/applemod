#if defined _l4d2_multibody_score_policy_included
    #endinput
#endif
#define _l4d2_multibody_score_policy_included

// Route scoring follows the server's existing mapinfo convention:
//
//   mapinfo.txt[map]["max_distance"]   four-survivor base score (M)
//   one survivor's full route          = M / 4
//   team full route                    = M / 4 * G14_BODY_COUNT
//
//   M = 300 -> 75 per survivor -> 300 (4 survivors) / 900 (12 survivors)
//   M = 500 -> 125 per survivor -> 500 (4 survivors) / 1500 (12 survivors)
//
// The engine expresses per-survivor completion in its own four-slot scale: one
// slot saturates at vs_max_completion_score / 4, whatever that value currently
// is. Samples are therefore converted into route units against the current
// engine value instead of assuming a fixed unit for it.
#define G14_ESCAPE_ROUTE_POINTS 25

// Team route maximum, in route points.
stock int G14_TeamRouteCap(int baseScore)
{
    if (baseScore <= 0) return 0;
    return baseScore / 4 * G14_BODY_COUNT;
}

// One survivor's full route, in route points (base score / 4).
stock int G14_BodyRouteCap(int baseScore)
{
    if (baseScore <= 0) return 0;
    return baseScore / 4;
}

// Full-scale value of the per-survivor completion native. The engine keeps four
// 8-bit survivor slots per team whose sum is the team distance, so one slot
// saturates at engineMax / 4. Override it from a ConVar when a build returns a
// different scale; 0 means "derive from the engine" (default).
stock int G14_RawRouteCap(int engineMax, int overrideCap)
{
    if (overrideCap > 0) return overrideCap;
    if (engineMax <= 0) return 0;
    return engineMax / 4;
}

// Convert one raw native sample into route points.
stock int G14_ConvertSample(int raw, int rawCap, int bodyCap)
{
    if (rawCap <= 0 || bodyCap <= 0 || raw <= 0) return 0;
    return raw * bodyCap / rawCap;
}

// Convert a route total back to the engine's own distance scale.
stock int G14_ToEngineScale(int route, int teamCap, int engineMax)
{
    if (teamCap <= 0 || engineMax <= 0) return 0;
    return route * engineMax / teamCap;
}

// Keep native integer route units until the team sum. Never truncate each
// body's fractional 1/14 share separately (400 / 14 must not become 14 * 28).
stock int G14_RouteHighWater(int previous, int sample, int unitLimit)
{
    if (unitLimit <= 0) return previous;
    if (sample < 0) sample = 0;
    if (sample > unitLimit) sample = unitLimit;
    return sample > previous ? sample : previous;
}

// Retained for callers that still rescale a previously stored sample.
stock int G14_NormalizeRoute(int sample, int fromUnitLimit, int toUnitLimit)
{
    if (fromUnitLimit <= 0 || toUnitLimit <= 0) return 0;
    return sample * toUnitLimit / fromUnitLimit;
}

// Team route is the plain sum of the per-survivor high-water marks: every
// survivor owns one quarter of the map's four-survivor base, so the team total
// scales with population and is never normalized back to the engine maximum.
stock int G14_WeightedRoute(const int[] points, int unitLimit, int mapMaximum)
{
    if (unitLimit <= 0 || mapMaximum <= 0) return 0;
    int sum;
    for (int body = 1; body <= G14_BODY_COUNT; body++)
        sum += G14_RouteHighWater(0, points[body], unitLimit);
    // Official-map score ranges fit integer multiplication. Apply integer
    // division once, after all fourteen raw contributions have been added.
    // The two lines above describe the earlier policy, which re-normalized the
    // sum back to the engine maximum. The sum is now the score itself, so that
    // division is gone and no per-body truncation can creep in.
    return sum;
}

// The native network property has four slots per team. Only project the
// aggregate into them; they are no longer individual survivor accounts.
// Each slot is 8 bit, so values above 255 are clamped instead of wrapping.
stock int G14_RouteDisplayBucket(int engineScore, int slot)
{
    if (engineScore <= 0) return 0;
    int bucket = engineScore / 4 + (slot < engineScore % 4 ? 1 : 0);
    return bucket > 255 ? 255 : bucket;
}
