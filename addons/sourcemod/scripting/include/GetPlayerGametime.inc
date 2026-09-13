#if defined _GetPlayerGametime_included
 #endinput
#endif
#define _GetPlayerGametime_included

/**
 * 获取玩家的游戏时长 (由 GetPlayerGametime 插件提供)
 *
 * 优先采用成就统计时长, 成就拿不到时退化为主页时长(可用 GetPlayerGametime_GetSource 判断来源)
 *
 * @param client    Client index
 * @return          玩家游戏时长(秒); 0 = 未获取/未知, -1 = 获取中, -2 = 获取失败
 */
native int GetPlayerGametime_GetTime(int client);

/**
 * 获取玩家的 Lerp 值 (由 GetPlayerGametime 插件提供)
 *
 * @param client    Client index
 * @return          Lerp 值(秒, 例如 0.0156); 未获取到时返回 0.0
 */
native float GetPlayerGametime_GetLerp(int client);

/**
 * 获取玩家的主页(Steam 个人资料)游戏时长 (由 GetPlayerGametime 插件提供)
 *
 * 需要 ConVar GetPlayerGametimeAPIKey 与 CheckPlayerProfileCount 配置好, 否则恒为 0
 *
 * @param client    Client index
 * @return          主页游戏时长(秒); <=0 = 未获取/未知
 */
native int GetPlayerGametime_GetProfileTime(int client);

/**
 * 获取玩家的成就统计游戏时长 (由 GetPlayerGametime 插件提供)
 *
 * @param client    Client index
 * @return          成就统计游戏时长(秒); <=0 = 未获取/未知
 */
native int GetPlayerGametime_GetStatTime(int client);

/**
 * 获取 GetPlayerGametime_GetTime 当前采用的时长来源 (由 GetPlayerGametime 插件提供)
 *
 * @param client    Client index
 * @return          0 = 无数据, 1 = 主页时长, 2 = 成就统计时长
 */
native int GetPlayerGametime_GetSource(int client);

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
	MarkNativeAsOptional("GetPlayerGametime_GetProfileTime");
	MarkNativeAsOptional("GetPlayerGametime_GetStatTime");
	MarkNativeAsOptional("GetPlayerGametime_GetSource");
}
#endif
