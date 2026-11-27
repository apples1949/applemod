#if defined _Evill4d2_banned
 #endinput
#endif
#define _Evill4d2_banned

public SharedPlugin __pl_l4d2_banned = 
{
	name = "l4d2_banned",
	file = "l4d2_banned.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_l4d2_banned_SetNTVOptional()
{
	MarkNativeAsOptional("BanPlayers");
}
#endif

/**
 * Bans a client(替换成使用平台自带的数据库记录封禁信息).
 *
 * 身份说明（v2.8.0 起）：本 native 写库时用的是 **17 位 SteamID64**
 * （GetClientAuthId(client, AuthId_SteamID64)），也就是 l4d2_banned 表 SteamID 列的内容。
 * 取不到 SteamID64（玩家未认证 / 非 Steam 客户端）时封禁失败，不会退化成 IP 记录。
 * 数据库里迁移前留下的老格式 STEAM_X:Y:Z 记录仍能被插件回退匹配，新记录一律 64 位。
 * 注意：只有在没装 l4d2_banned、退回官方 BanClient() 时才写本地 banned_user.cfg，
 * 那份是引擎原生格式 STEAM_X:Y:Z / IP，**不会**变成 64 位。
 *
 * @param client        Client being banned.
 * @param time          Time (in minutes) to ban (0 = permanent).
 * @param flags         Flags for controlling the ban mechanism.  If AUTHID 
 *                      is set and no AUTHID is available, the ban will fail (默认添加 BANFLAG_NOKICK 禁用踢出玩家功能)
 *                      unless AUTO is also flagged.
 * @param reason        Reason to ban the client for.
 * @param kick_message  Message to display to the user when kicking.
 * @param command       Command string to identify the source.  If this is left 
 *                      empty, then the OnBanClient forward will not be called.
 * @param source        A source value that could be interpreted as a player 
 *                      index of any sort (not actually checked by Core).
 * @return              True on success, false on failure.
 * @error               Invalid client index or client not in game.
 */
native bool BanPlayers(int client, int time, int flags, const char[] reason, const char[] kick_message="", const char[] command="", any source=0);
