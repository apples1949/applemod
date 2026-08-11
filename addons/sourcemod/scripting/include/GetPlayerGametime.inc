#if defined _GetPlayerGametime_included
 #endinput
#endif
#define _GetPlayerGametime_included

/**
 * 获取玩家的真实游戏时长 (由 GetPlayerGametime 插件提供)
 *
 * @param client    Client index
 * @return          玩家真实游戏时长(秒); 0 = 未获取/未知, -1 = 获取中, -2 = 获取失败
 */
native int GetPlayerGametime_GetTime(int client);

/**
 * 获取玩家的 Lerp 值 (由 GetPlayerGametime 插件提供)
 *
 * @param client    Client index
 * @return          Lerp 值(秒, 例如 0.0156); 未获取到时返回 0.0
 */
native float GetPlayerGametime_GetLerp(int client);

public SharedPlugin __pl_GetPlayerGametime =
{
	name = "GetPlayerGametime",
	file = "GetPlayerGametime.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_GetPlayerGametime_SetNTVOptional()
{
	MarkNativeAsOptional("GetPlayerGametime_GetTime");
	MarkNativeAsOptional("GetPlayerGametime_GetLerp");
}
#endif
