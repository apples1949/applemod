#if defined _l4d2_fix_team_shuffle_edi_included_
	#endinput
#endif
#define _l4d2_fix_team_shuffle_edi_included_

/**
 * 当队伍修正完成（所有玩家已归位到正确队伍）时触发。
 * 此时可以安全地执行依赖队伍状态的后续操作。
 */
forward void L4D2_FixTeamShuffle_OnFixComplete();

/**
 * 查询队伍修正是否已完成。
 *
 * @return  true  = 修正已完成，所有玩家在正确队伍
 *          false = 修正尚未完成或正在进行中
 */
native bool L4D2_FixTeamShuffle_IsFixComplete();

public SharedPlugin __pl_l4d2_fix_team_shuffle_edi =
{
	name = "l4d2_fix_team_shuffle_edi",
	file = "l4d2_fix_team_shuffle_edi.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_l4d2_fix_team_shuffle_edi_SetNTVOptional()
{
	MarkNativeAsOptional("L4D2_FixTeamShuffle_IsFixComplete");
}
#endif
