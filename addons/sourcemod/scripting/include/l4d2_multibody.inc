#if defined _l4d2_multibody_included
    #endinput
#endif
#define _l4d2_multibody_included

#define G14_TEAM_SIZE 12
#define G14_HUMAN_LIMIT 24
#define G14_BODY_COUNT 12
#define G14_VERSION "0.1.4"

// Bodies survive client replacement. Body IDs are scoped to a half (epoch).
native int G14_GetBody(int client);
native int G14_GetBodyClient(int body);
// Original engine bodies retained for population bootstrap/compatibility.
// Route scoring includes all fourteen bodies, without captain privileges.
// G14_TEAM_SIZE/G14_BODY_COUNT are 12 and G14_HUMAN_LIMIT 24 (previously
// 14/14/28); route scoring follows G14_BODY_COUNT automatically.
// Slot is 0..3; returns zero until the initial population is identified.
native int G14_GetCaptainBody(int slot);
native int G14_GetEpoch();
native int G14_GetCampaign();
native int G14_GetLogicalTeam(int client);
native int G14_GetSurvivorLogicalTeam();
native bool G14_IsRoundActive();
native bool G14_IsPopulationReady();
native bool G14_CanAllocateClient(bool essential = false);
native void G14_MarkNewCampaign();

forward void G14_OnNewCampaign(int campaign);
forward void G14_OnRoundBegin(int epoch);
forward void G14_OnPopulationReady(int epoch);
forward void G14_OnFirstExit(int epoch);
forward void G14_OnBodyTransfer(int body, int oldClient, int newClient);

public SharedPlugin __pl_l4d2_multibody_core =
{
    name = "l4d2_multibody_core",
    file = "l4d2_multibody_core.smx",
#if defined REQUIRE_PLUGIN
    required = 1
#else
    required = 0
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_l4d2_multibody_core_SetNTVOptional()
{
    MarkNativeAsOptional("G14_GetBody");
    MarkNativeAsOptional("G14_GetBodyClient");
    MarkNativeAsOptional("G14_GetCaptainBody");
    MarkNativeAsOptional("G14_GetEpoch");
    MarkNativeAsOptional("G14_GetCampaign");
    MarkNativeAsOptional("G14_GetLogicalTeam");
    MarkNativeAsOptional("G14_GetSurvivorLogicalTeam");
    MarkNativeAsOptional("G14_IsRoundActive");
    MarkNativeAsOptional("G14_IsPopulationReady");
    MarkNativeAsOptional("G14_CanAllocateClient");
    MarkNativeAsOptional("G14_MarkNewCampaign");
}
#endif
