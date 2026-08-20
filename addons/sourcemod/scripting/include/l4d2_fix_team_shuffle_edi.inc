#if defined _l4d2_fix_team_shuffle_edi_included_
	#endinput
#endif
#define _l4d2_fix_team_shuffle_edi_included_

/**
 * 当队伍还原流程结束（全部还原成功、5 秒检查通过、超时或主动中止且允许
 * 触发前向）时触发。
 *
 * L4D2_FixTeamShuffle_IsFixComplete 仍返回 false。若回调中需要切换队伍，
 * 请在前向返回后延迟到下一帧执行。
 */
forward void L4D2_FixTeamShuffle_OnFixComplete();

/**
 * 立即记录当前全部人类玩家的队伍，供下一次启动还原使用。
 *
 * @noreturn
 */
native void L4D2_FixTeamShuffle_Keep();

/**
 * 立即启动队伍还原（锁队并把玩家放回记录队伍）。
 * @note 需要先调用 L4D2_FixTeamShuffle_Keep 记录队伍。
 *
 * @noreturn
 */
native void L4D2_FixTeamShuffle_Start();

/**
 * 立即中止队伍还原。
 *
 * @param fireForward   是否触发 L4D2_FixTeamShuffle_OnFixComplete 前向并公告；
 *                      false 时静默清空。
 *
 * @noreturn
 */
native void L4D2_FixTeamShuffle_Abort(bool fireForward = true);

/**
 * 查询队伍还原是否已完成。
 *
 * @return  true  = 未锁定，还原流程已完成/不在进行中
 *          false = 还原进行中，换队被锁定
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
	MarkNativeAsOptional("L4D2_FixTeamShuffle_Keep");
	MarkNativeAsOptional("L4D2_FixTeamShuffle_Start");
	MarkNativeAsOptional("L4D2_FixTeamShuffle_Abort");
	MarkNativeAsOptional("L4D2_FixTeamShuffle_IsFixComplete");
}
#endif
