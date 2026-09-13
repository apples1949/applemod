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
 * Shows a round-end "fun fact" on the scripted HUD, in its own dedicated slot
 * (slot 2, boxed single line, positioned below the team-fix prompt).
 * The text is broadcast to every client and re-sent every 0.5s for `hideTime`
 * seconds, so it cannot be wiped by the game's own HUD writes; if the next round
 * starts while it is still showing, it is kept for a few more seconds so that it
 * is readable after the round-end scoreboard/intermission.
 *
 * Chat colour codes (\x01-\x05) are stripped: the scripted HUD does not parse them.
 *
 * @param text     The fun-fact text to display. Empty/NULL => no-op.
 * @param hideTime Seconds to keep the text visible (<=0 uses a 5s default).
 *
 * @return 1 on success (accepted / shown), 0 otherwise (no text, or a team fix is running).
 */
native int ScriptedHud_ShowRoundFunFact(const char[] text, float hideTime);

public SharedPlugin __pl_l4d2_scripted_hud =
{
	name = "l4d2_scripted_hud",
	file = "l4d2_scripted_hud.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_l4d2_scripted_hud_SetNTVOptional()
{
	MarkNativeAsOptional("ScriptedHud_ShowRoundFunFact");
}
#endif