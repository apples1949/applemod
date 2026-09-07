/**
 * l4d2_scripted_hud include
 * ==========================
 * Shared function declarations for the [L4D2] Scripted HUD plugin.
 *
 * Use REQUIRED_PLUGIN-style optional linking like this in consumers:
 *     #undef REQUIRE_PLUGIN
 *     #include <l4d2_scripted_hud>
 * and guard every call with `LibraryExists("l4d2_scripted_hud")`.
 *
 * Original code by Mart / apples1949.
 */

#if defined _l4d2_scripted_hud_included
	#endinput
#endif
#define _l4d2_scripted_hud_included

/**
 * Shows a round-end "fun fact" in the "team fix" HUD slot (HUD_TICKER).
 * The text is broadcast to every client for `hideTime` seconds, then hidden.
 * If the team-fix flow starts while the fun fact is showing, the fix prompt
 * takes over and the fun fact is cancelled.
 *
 * @param text     The fun-fact text to display. Empty/NULL => no-op.
 * @param hideTime Seconds to keep the text visible before hiding it (<=0 uses default).
 *
 * @return 1 on success (accepted / shown), 0 otherwise (e.g. team fix in progress).
 */
native int ScriptedHud_ShowRoundFunFact(const char[] text, float hideTime);