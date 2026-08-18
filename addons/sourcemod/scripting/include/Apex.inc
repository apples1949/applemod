#if defined _Apex_included
 #endinput
#endif
#define _Apex_included

/**
 * @brief 查询当前玩家是否开启了 Apex 坦克自动连跳。
 *
 * @param client    Client index
 * @return          true 为开启，false 为关闭。
 */
native bool Apex_IsBhopEnabled(int client);

/**
 * @brief 查询当前玩家是否开启了 Apex 坦克跟踪石头。
 *
 * @param client    Client index
 * @return          true 为开启，false 为关闭。
 */
native bool Apex_IsTracEnabled(int client);

public SharedPlugin __pl_Apex =
{
	name = "Apex",
	file = "Apex.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_Apex_SetNTVOptional()
{
	MarkNativeAsOptional("Apex_IsBhopEnabled");
	MarkNativeAsOptional("Apex_IsTracEnabled");
}
#endif