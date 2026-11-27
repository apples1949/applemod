
/*
 *
 *	该插件参考作者lakwsh的连服封禁.
 *	这个是他的仓库(https://github.com/lakwsh/sm_bandb).
 *
 *	v1.0.0
 *
 *	1:初始版本发布.
 *	2:如果要正常使用该插件需要替换平台自带的封禁插件.
 *	3:该插件使用的是平台自带的数据库,门槛更低,但不能跨服使用.
 *	4:有可能第一个玩家加入服务器后数据库会出现查询延迟的问题.
 *
 *	v1.0.1
 *
 *	1:新增玩家加入时ID获取失败的会被踢出游戏.
 *
 *	v1.0.2
 *
 *	1:永久封禁的玩家下次加入游戏时显示被封禁的时间.
 *
 *	v1.1.2
 *
 *	1:新增兼容平台自带的sm_addban封禁指令.
 *
 *	v1.2.2
 *
 *	1:重新包装一下BanClient()封禁玩家函数,用于兼容该插件.
 *
 *	v1.3.2
 *
 *	1:新增聊天窗显示解封提示.
 *
 *	v1.4.2
 *
 *	1:封禁函数类型数量跟官方保持一致.
 *	2:把平台自带的封禁STEAMID的函数也重新封装一下用于适配该插件.
 *
 *	v1.4.3
 *
 *	1:重新封装的封禁函数BanPlayers(BanClient)默认添加禁用踢出玩家的功能.
 *
 *	v1.4.4
 *
 *	1:封禁函数BanClient没有添加禁用踢出玩家功能(BANFLAG_NOKICK)时使用平台自带的封禁功能.
 *	2:加载平台自带的封禁玩家列表(平台一直以来的一个BUG,不手动加载的话重开服后封禁列表就失效了).
 *
 *	v1.5.4
 *
 *	1:非永久封禁提示添加解封时间显示.
 *
 *	v1.6.5
 *
 *	1:添加一个封禁时间显示.
 *	2:修复聊天窗解封时间写成封禁时间.
 *	3:添加封禁数据时如果玩家已经是非永久封禁状态则自动改为追加封禁时长.
 *
 *	v1.7.5
 *
 *	1:新增配置文件选择使用MySQL数据库版本.
 *
 *	v2.7.5
 *
 *	1:新增管理员菜单删除封禁列表功能.
 *
 *
 *	v2.8.0
 *
 *	1:封禁身份统一改用 17 位 SteamID64(AuthId_SteamID64)，表列 SteamID 改为存 SteamID64。
 *	2:兼容老数据：查询时把 SteamID64 与该玩家的 legacy STEAM_X:Y:Z 一起放进 IN 里查，
 *	  命中老记录后可按配置把主键原地升级成 SteamID64（升级前先确认新主键不存在，避免撞主键丢数据）。
 *	3:**数据库彻底连不上时固定放行**（服主要求，不做配置开关）：
 *	  · 本地暂存封禁(configs/l4d2_banned_pending.txt)仍然在玩家连接时先行拦截；
 *	  · "连上了但语句报错"这条路径仍然踢出，不放行。
 *	4:sm_banip 的 IP 身份保持 IP 语义，不参与 64 位换算。
 *
 *	v2.8.1（迁移期修正）
 *
 *	1:sm_ban / sm_addban / sm_unban 写库结果**回显给执行命令的管理员**（聊天框 + 控制台）：
 *	  [库✓]/[库✗] 前缀，直接看到"新增了几行/更新了几行/删了几行"，不再只能翻服务器控制台。
 *	2:更新封禁（追加时长/改原因）改成 WHERE SteamID IN (…) —— 阶段一之后同一玩家名下有
 *	  "老格式行 + 64 位行"两条，原来只更新命中的那一条，另一条留着旧时长/旧原因，列表对不上。
 *	3:新增封禁时按配置**再写一条老格式镜像行**（默认开）：还在跑 2.7.5 的服务器只认
 *	  STEAM_X:Y:Z 精确匹配，只写 64 位会让那些服"查不到 = 封了不拦"。
 *	  阶段二（全服升到 2.8.x、库里只剩 64 位）后把配置键置 0。
 */
#pragma semicolon 1
//強制1.7以後的新語法
#pragma newdecls required
#pragma dynamic 40960	//增加堆栈空间.
#include <sourcemod>
#undef REQUIRE_PLUGIN	//adminmenu 设为可选：没加载时只是少一个「封禁列表」菜单入口，插件照常工作
#include <adminmenu>
#define REQUIRE_PLUGIN

#define PLUGIN_VERSION	"2.8.1"	//插件的版本.
#define MAX_LENGTH		128		//字符串最大值.
#define STEAM64_BASE "76561197960265728"	//普通账号 SteamID64 基址(0x01100001_00000000)，换算老 STEAM_X:Y:Z 用
#define AUTH_IN_MAX 2048					//SQL IN 候选列表缓冲(5 个候选 × 128 字符 × 转义翻倍，留余量)

Database g_dbSQL;

bool g_bLateLoad;
bool g_bDatabaseType = false;//设置创建配置文件默认使用的数据库类型,false=Sqlite,true=MySQL.
bool g_bLegacyUpgrade = true;//回退命中老 STEAM_X:Y:Z 记录后，是否把主键自动升级成 SteamID64（配置项见 IsReadFileValues）.
/* 数据库连不上时：**固定放行**（服主要求，不做配置开关）。
 * 理由：库跨机房公网部署、抖动是常态，用"锁服"换"封禁不漏"不划算。
 * 此时仍然生效的两道保险：
 *   ① 断线期间新封的人写进本地暂存 configs/l4d2_banned_pending.txt，玩家重连时先查暂存；
 *   ② "连上了但语句报错"另一条路径照样踢（见 BanCheckFailed），只有"彻底连不上"才放行。 */
/* 迁移期"双写"（默认 1）：新增封禁时，除 17 位主键外**再补一条老格式 STEAM_1:Y:Z 镜像行**。
 * 为什么需要：库里现在是"老行 + 64 位副本"的双行状态，还没升级到 2.8.0 的服务器
 * 只按 SteamID = 'STEAM_1:0:xxx' 精确查 —— 新封禁若只写 64 位，那些服查不到 = 封了不拦。
 * 阶段二（删老行、全服都是 2.8.0）之后把它置 0，库就只剩 64 位。
 * 配置键见 IsReadFileValues："新增封禁时同时写一条老格式镜像行. 1=双写(迁移期), 0=只写64位". */
bool g_bDualWriteLegacy = true;
bool g_bButton[MAXPLAYERS+1];

char g_skvPath[PLATFORM_MAX_PATH];
char g_sPlayerData[5][MAXPLAYERS+1][32];

enum struct esBanned 
{
	bool g_bBanStatus;
	char sBanTime[128];
	char sUnBanTime[128];
	char sBanReason[128];
	char sBanDuration[128];
}
esBanned g_eBanned[MAXPLAYERS + 1];

enum struct esBanList 
	{
		char esSteamID[128];
		char esBanReason[128];
		int eiBanTime;
		int eiTimesTamp;
	}

TopMenu g_hTopMenu;
TopMenuObject hOtherFeatures = INVALID_TOPMENUOBJECT;

/* ==== 断线重连 + 离线封禁暂存 ==== */
#define RECONNECT_INTERVAL	30.0
Handle g_hReconnectTimer = null;
StringMap g_hPendingBans = null;			// auth -> "分钟|时间戳|原因"
char g_sPendingPath[PLATFORM_MAX_PATH];

/* banned_user.cfg 几百条 banid 一次性 exec 会触发 Cbuf_AddText: buffer overflow，改成分批下发 */
#define BAN_FILE_CHUNK	40
ArrayList g_hBanFileLines = null;
Handle g_hBanFileTimer = null;
int g_iBanFileIndex = 0;

/* 统一的"回显给谁"助手：client > 0 走原版 ReplyToCommand（聊天/控制台各按回复源），
 * client == 0（rcon / 服务器控制台）一律额外 PrintToServer。
 * 只靠 ReplyToCommand 时，rcon 执行带 %t 的翻译串、或客户端索引非法时会静默丢弃。 */
stock void ReplyBoth(int client, const char[] format, any ...)
{
	char buffer[512];
	VFormat(buffer, sizeof(buffer), format, 3);

	if (client > 0 && client <= MaxClients && IsClientInGame(client))
	{
		ReplyToCommand(client, "%s", buffer);
		return;
	}

	PrintToServer("%s", buffer);
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) 
{
	CreateNatives();
	g_bLateLoad = late;
	RegPluginLibrary("l4d2_banned");
	return APLRes_Success;
}
void CreateNatives()
{
	CreateNative("BanPlayers", BanNativePlayers);
}
int BanNativePlayers(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	int time = GetNativeCell(2);
	int flags = GetNativeCell(3);
	char[] reason = new char[MAX_LENGTH];
	char[] kick_message = new char[MAX_LENGTH];
	char[] command = new char[MAX_LENGTH];
	GetNativeString(4, reason, MAX_LENGTH);
	GetNativeString(5, kick_message, MAX_LENGTH);
	GetNativeString(6, command, MAX_LENGTH);
	any source = GetNativeCell(7);
	return BanClient(client, time, flags|BANFLAG_NOKICK, reason, kick_message, command, source);//BANFLAG_NOKICK的作用是禁用封禁函数自带的踢出玩家功能.
}
//定义插件信息.
public Plugin myinfo =  
{
	name = "l4d2_banned",
	author = "豆瓣酱な",
	description = "监听平台自带的封禁和解封函数",
	version = PLUGIN_VERSION,
	url = "N/A"
};
//插件开始时.
public void OnPluginStart() 
{
	RegAdminCmd("sm_banlist", Command_BanList, ADMFLAG_GENERIC, "封禁列表(管理员).");
	RegAdminCmd("sm_bandb", Command_BanDb, ADMFLAG_ROOT, "数据库封禁自检: 连接/类型/库名/条数/表结构/rcon 可见.");
	RegAdminCmd("sm_bandb_check", Command_BanDb, ADMFLAG_ROOT, "同 sm_bandb.");
	
	BuildPath(Path_SM, g_skvPath, sizeof(g_skvPath), "configs/l4d2_banned.cfg");
	IsReadFileValues();

	BuildPath(Path_SM, g_sPendingPath, sizeof(g_sPendingPath), "configs/l4d2_banned_pending.txt");
	LoadPendingBans();

	if (!g_dbSQL)
		IniSQLite();
	else
		FlushPendingBans();

	if (g_bLateLoad)//如果插件是延迟加载.
		SQL_LoadAll();//读取所有玩家数据.

	TopMenu topmenu;
	if (LibraryExists("adminmenu") && ((topmenu = GetAdminTopMenu()) != null))
		OnAdminMenuReady(topmenu);
}
//封禁列表.
public Action Command_BanList(int client, int args)
{
	/* rcon / 服务器控制台（client == 0）下菜单无法显示，改成把列表打到服务器控制台。 */
	if (client <= 0)
	{
		PrintBanListToServer();
		return Plugin_Handled;
	}

	OpenBanListMenu(client, 0, false);
	return Plugin_Handled;
}

/* sm_banlist 的 rcon 版本：按 timestamp 倒序列出前 100 条。 */
void PrintBanListToServer()
{
	if (g_dbSQL == null)
	{
		PrintToServer("[l4d2_banned] 数据库未连接，无法读取封禁列表（用 sm_bandb 看连接状态）。");
		return;
	}

	/* 先查总数再查列表：不在同一个连接上同时开着两个未取完的结果集
	 * （MySQL 驱动下 CALL/多结果集必须先处理完才能发下一条）。 */
	int iNow = GetTime();
	int iTotal = -1;

	DBResultSet rsCount = SQL_Query(g_dbSQL, "SELECT COUNT(*) FROM l4d2_banned;");
	if (rsCount != null && rsCount.FetchRow())
		iTotal = rsCount.FetchInt(0);
	delete rsCount;

	DBResultSet rs = SQL_Query(g_dbSQL, "SELECT SteamID, banreason, bantime, timestamp FROM l4d2_banned ORDER BY timestamp DESC LIMIT 100;");
	if (rs == null)
	{
		char error[1024];
		SQL_GetError(g_dbSQL, error, sizeof(error));
		PrintToServer("[l4d2_banned] 查询封禁列表失败: %s", error);
		return;
	}

	int iFetched = rs.RowCount;
	int iShown = 0, iActive = 0;

	PrintToServer("[l4d2_banned] ===== 封禁列表（本页 %d 条，库内共 %d 条）=====",
		iFetched, (iTotal >= 0) ? iTotal : iFetched);

	while (rs.FetchRow())
	{
		char sAuth[64], sReason[128];
		rs.FetchString(0, sAuth, sizeof(sAuth));
		rs.FetchString(1, sReason, sizeof(sReason));
		int iBanTime = rs.FetchInt(2);
		int iStamp = rs.FetchInt(3);

		bool bActive = (iBanTime <= 0) || (iBanTime * 60 + iStamp > iNow);
		if (bActive)
			iActive++;

		if (iBanTime <= 0)
			PrintToServer("  %s | 永久 | 封禁于 %s | %s", sAuth, GetDateTime(iStamp), sReason);
		else
			PrintToServer("  %s | %d 分钟 | 封禁于 %s | 解封 %s | %s",
				sAuth, iBanTime, GetDateTime(iStamp),
				GetDateTime(iStamp + iBanTime * 60), sReason);

		if (++iShown >= 100)
			break;
	}
	delete rs;

	PrintToServer("[l4d2_banned] ===== 其中仍生效 %d 条 =====", iActive);
}

/* ======================================================================
 *  sm_bandb / sm_bandb_check —— 数据库可用性自检
 *  连接状态、驱动类型、库名、连接耗时、总条数、最近一条、表结构、
 *  断线重连状态与待上传暂存条数。rcon 下同样可见（全部 PrintToServer）。
 * ==================================================================== */
public Action Command_BanDb(int client, int args)
{
	char sDriver[32] = "未连接", sProduct[32] = "-", sDbName[128] = "-";
	float fConnectCost = 0.0;
	bool bTableOK = true;
	int iTotal = -1, iLastStamp = 0;
	char sLastAuth[64] = "", sLastReason[128] = "";

	ReplyBoth(client, "[l4d2_banned] ===== 数据库自检 =====");
	ReplyBoth(client, "[l4d2_banned] 配置类型(configs/l4d2_banned.cfg): %s", g_bDatabaseType ? "MySQL" : "SQLite");
	ReplyBoth(client, "[l4d2_banned] 连接状态: %s", (g_dbSQL != null) ? "已连接" : "未连接");
	ReplyBoth(client, "[l4d2_banned] 断线重连: %s；待上传暂存: %d 条", (g_hReconnectTimer != null) ? "进行中（每 30 秒重试）" : "未启用", (g_hPendingBans != null) ? g_hPendingBans.Size : 0);

	if (g_dbSQL == null)
	{
		ReplyBoth(client, "[l4d2_banned] 当前无连接，接着尝试一次连接（最多 5 秒）...");

		char error[1024];
		float fStart = GetEngineTime();
		Database db = IniSQLiteTry(error, sizeof(error));
		fConnectCost = GetEngineTime() - fStart;

		if (db == null)
		{
			ReplyBoth(client, "[l4d2_banned] 连接失败（耗时 %.3f 秒）：%s", fConnectCost, error);
			ReplyBoth(client, "[l4d2_banned] ===== 自检结束（不健康）=====");
			return Plugin_Handled;
		}

		g_dbSQL = db;
		ReplyBoth(client, "[l4d2_banned] 连接成功（耗时 %.3f 秒），已恢复全局连接。", fConnectCost);
		FlushPendingBans();
	}
	else
	{
		/* 已有连接：发一条轻量查询测一下往返耗时，确认连接没半死。 */
		float fStart = GetEngineTime();
		DBResultSet rs = SQL_Query(g_dbSQL, "SELECT 1;");
		fConnectCost = GetEngineTime() - fStart;

		if (rs != null)
		{
			delete rs;
			ReplyBoth(client, "[l4d2_banned] 连接存活（往返耗时 %.3f 秒）。", fConnectCost);
		}
		else
		{
			char error[1024];
			SQL_GetError(g_dbSQL, error, sizeof(error));
			ReplyBoth(client, "[l4d2_banned] 连接已失效：%s（下次查询起走暂存/重连）", error);
		}
	}

	/* 驱动类型 / 库名（不打印账号密码）。 */
	DBDriver driver = g_dbSQL.Driver;
	if (driver != null)
	{
		driver.GetIdentifier(sDriver, sizeof(sDriver));
		driver.GetProduct(sProduct, sizeof(sProduct));
	}

	if (g_bDatabaseType)
	{
		/* MySQL：库名从 databases.cfg 的 default 节取。 */
		char sCfgPath[PLATFORM_MAX_PATH];
		GetDbConfigPath(sCfgPath, sizeof(sCfgPath));

		KeyValues kv = new KeyValues("Databases");
		if (kv.ImportFromFile(sCfgPath))
		{
			if (kv.JumpToKey("default"))
				kv.GetString("database", sDbName, sizeof(sDbName), "(未填写)");
		}
		delete kv;
	}
	else
	{
		strcopy(sDbName, sizeof(sDbName), "l4d2_banned.sq3 (data/sqlite)");
	}

	ReplyBoth(client, "[l4d2_banned] 驱动: %s (%s)；库: %s", sProduct, sDriver, sDbName);

	/* 表结构 + 总条数 + 最近一条。 */
	DBResultSet rs = SQL_Query(g_dbSQL, "SELECT COUNT(*) AS c FROM l4d2_banned;");
	if (rs != null && rs.FetchRow())
	{
		iTotal = rs.FetchInt(0);
	}
	else
	{
		char error[1024];
		SQL_GetError(g_dbSQL, error, sizeof(error));
		bTableOK = false;
		ReplyBoth(client, "[l4d2_banned] 表 l4d2_banned 不可用：%s", error);
	}
	delete rs;

	if (iTotal >= 0)
	{
		ReplyBoth(client, "[l4d2_banned] 总条数: %d", iTotal);

		rs = SQL_Query(g_dbSQL, "SELECT SteamID, banreason, bantime, timestamp FROM l4d2_banned ORDER BY timestamp DESC LIMIT 1;");
		if (rs != null && rs.FetchRow())
		{
			rs.FetchString(0, sLastAuth, sizeof(sLastAuth));
			rs.FetchString(1, sLastReason, sizeof(sLastReason));
			iLastStamp = rs.FetchInt(3);
			ReplyBoth(client, "[l4d2_banned] 最近一条: %s | %s | 时长 %d 分钟 | %s",
				sLastAuth, sLastReason, rs.FetchInt(2), GetDateTime(iLastStamp));
		}
		else
		{
			ReplyBoth(client, "[l4d2_banned] 最近一条: （表为空）");
		}
		delete rs;

		/* 表结构核对：SteamID / banreason / bantime / timestamp 四个字段都得在。 */
		rs = SQL_Query(g_dbSQL, "SELECT SteamID, banreason, bantime, timestamp FROM l4d2_banned LIMIT 0;");
		if (rs == null)
		{
			bTableOK = false;
			char error[1024];
			SQL_GetError(g_dbSQL, error, sizeof(error));
			ReplyBoth(client, "[l4d2_banned] 表结构不匹配：%s", error);
		}
		else
		{
			char sWant[4][16];
			strcopy(sWant[0], sizeof(sWant[]), "SteamID");
			strcopy(sWant[1], sizeof(sWant[]), "banreason");
			strcopy(sWant[2], sizeof(sWant[]), "bantime");
			strcopy(sWant[3], sizeof(sWant[]), "timestamp");

			for (int i = 0; i < 4; i++)
			{
				int field;
				if (!rs.FieldNameToNum(sWant[i], field))
				{
					bTableOK = false;
					ReplyBoth(client, "[l4d2_banned] 表结构缺少字段: %s", sWant[i]);
				}
			}
			delete rs;
		}

		ReplyBoth(client, "[l4d2_banned] 表结构: %s（SteamID/banreason/bantime/timestamp）", bTableOK ? "匹配" : "不匹配");

		/* SteamID 格式体检：v2.8.0 起只写 17 位 SteamID64；老格式还能被回退匹配，
		 * 但建议按 私人文件/docs/封禁改SteamID64_迁移方案.md 换算掉。
		 * 只有 MySQL 支持 REGEXP（SQLite 分支没有这个函数，直接跳过）。 */
		if (g_bDatabaseType)
		{
			rs = SQL_Query(g_dbSQL, "SELECT COUNT(*) FROM l4d2_banned WHERE SteamID REGEXP '^[0-9]{17}$';");
			if (rs != null && rs.FetchRow())
			{
				int iIs64 = rs.FetchInt(0);
				ReplyBoth(client, "[l4d2_banned] SteamID64(17 位) 记录: %d / %d 条；其余为老 STEAM 格式或 IP 串", iIs64, iTotal);
			}
			else
			{
				char error2[256];
				SQL_GetError(g_dbSQL, error2, sizeof(error2));
				ReplyBoth(client, "[l4d2_banned] SteamID64 格式统计查询失败: %s", error2);
			}
			delete rs;
		}
	}

	ReplyBoth(client, "[l4d2_banned] ===== 自检结束（%s）=====", (g_dbSQL != null && bTableOK) ? "健康" : "异常");

	return Plugin_Handled;
}
public void OnLibraryRemoved(const char[] name)
{
	if (StrEqual(name, "adminmenu"))
		g_hTopMenu = null;
}
 
public void OnAdminMenuReady(Handle aTopMenu)
{
	TopMenu topmenu = TopMenu.FromHandle(aTopMenu);

	if (topmenu == g_hTopMenu)
		return;
	
	g_hTopMenu = topmenu;
	
	TopMenuObject hTopMenuObject = FindTopMenuCategory(g_hTopMenu, "OtherFeatures");
	if (hTopMenuObject == INVALID_TOPMENUOBJECT)
		hTopMenuObject = AddToTopMenu(g_hTopMenu, "OtherFeatures", TopMenuObject_Category, hMenuHandler, INVALID_TOPMENUOBJECT);
	
	hOtherFeatures = AddToTopMenu(g_hTopMenu,"sm_banlist",TopMenuObject_Item, hHandlerMenu, hTopMenuObject,"sm_banlist",ADMFLAG_GENERIC);
}

void hMenuHandler(Handle topmenu, TopMenuAction action, TopMenuObject object_id, int param, char[] buffer, int maxlength)
{
	if (action == TopMenuAction_DisplayTitle)
	{
		Format(buffer, maxlength, "选择功能:", param);
	}
	else if (action == TopMenuAction_DisplayOption)
	{
		Format(buffer, maxlength, "其它功能", param);
	}
}

void hHandlerMenu(Handle topmenu, TopMenuAction action, TopMenuObject object_id, int param, char[] buffer, int maxlength)
{
	if (action == TopMenuAction_DisplayOption)
	{
		if (object_id == hOtherFeatures)
			Format(buffer, maxlength, "封禁列表", param);
	}
	else if (action == TopMenuAction_SelectOption)
	{
		if (object_id == hOtherFeatures)
		{
			OpenBanListMenu(param, 0, true);
		}
	}
}
void IsReadFileValues()
{
	char sDatabaseType[MAX_LENGTH];
	KeyValues kv = new KeyValues("DatabaseType");
	if (!FileExists(g_skvPath))
	{
		File file = OpenFile(g_skvPath, "w");//读取指定文件.
		if (!file)//读取文件失败.
			LogError("无法读取文件: \"%s\"", g_skvPath);//显示错误信息.
		IntToString(g_bDatabaseType, sDatabaseType, sizeof(sDatabaseType));
		kv.SetString("设置数据库类型. 0=Sqlite, 1=MySQL.", sDatabaseType);//写入指定的内容.
		IntToString(view_as<int>(g_bLegacyUpgrade), sDatabaseType, sizeof(sDatabaseType));
		kv.SetString("回退命中老STEAM格式记录时自动升级成SteamID64主键. 1=升级, 0=只读兼容.", sDatabaseType);
		IntToString(view_as<int>(g_bDualWriteLegacy), sDatabaseType, sizeof(sDatabaseType));
		kv.SetString("新增封禁时同时写一条老格式镜像行. 1=双写(迁移期, 兼容未升级的服务器), 0=只写64位.", sDatabaseType);
		kv.Rewind();//返回上一层.
		kv.ExportToFile(g_skvPath);//把数据写入到文件.
		delete file;//删除句柄.
	}
	else if (kv.ImportFromFile(g_skvPath)) //文件存在就导入kv数据,false=文件存在但是读取失败.
	{
		// 获取Kv文本内信息写入变量中.
		IntToString(g_bDatabaseType, sDatabaseType, sizeof(sDatabaseType));
		kv.GetString("设置数据库类型. 0=Sqlite, 1=MySQL.", sDatabaseType, sizeof(sDatabaseType), sDatabaseType);//获取文件里指定的内容.
		g_bDatabaseType = view_as<bool>(StringToInt(sDatabaseType));
		/* 老格式记录是否自动升级成 64 位主键（默认 1=升级）。 */
		IntToString(view_as<int>(g_bLegacyUpgrade), sDatabaseType, sizeof(sDatabaseType));
		kv.GetString("回退命中老STEAM格式记录时自动升级成SteamID64主键. 1=升级, 0=只读兼容.", sDatabaseType, sizeof(sDatabaseType), sDatabaseType);
		g_bLegacyUpgrade = view_as<bool>(StringToInt(sDatabaseType));
		IntToString(view_as<int>(g_bDualWriteLegacy), sDatabaseType, sizeof(sDatabaseType));
		kv.GetString("新增封禁时同时写一条老格式镜像行. 1=双写(迁移期, 兼容未升级的服务器), 0=只写64位.", sDatabaseType, sizeof(sDatabaseType), sDatabaseType);
		g_bDualWriteLegacy = view_as<bool>(StringToInt(sDatabaseType));
	}
	delete kv;//删除句柄.
}
//所有插件加载完成后执行一次(延迟加载插件也会执行一次).
public void OnAllPluginsLoaded()   
{
	ExecBannedUserCfgChunked();//加载服务器封禁列表（分批，避免 Cbuf_AddText 溢出）.
}
//创建数据库或表.
/* ======================================================================
 *  断线重连 + 离线封禁暂存
 *  · 连不上库：不卸载插件，每 30 秒重连一次
 *  · 期间封禁：本服照常踢人，记录写进 configs/l4d2_banned_pending.txt
 *  · 重连成功：把暂存记录全部 INSERT 进库，然后清空暂存文件
 * ==================================================================== */
void StartReconnectTimer()
{
	if (g_hReconnectTimer != null)
		return;

	g_hReconnectTimer = CreateTimer(RECONNECT_INTERVAL, Timer_Reconnect, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_Reconnect(Handle timer)
{
	if (g_dbSQL != null)
	{
		g_hReconnectTimer = null;
		return Plugin_Stop;
	}

	IniSQLite();

	if (g_dbSQL == null)
		return Plugin_Continue;

	PrintToServer("[l4d2_banned] 数据库已重新连接，开始上传离线期间的封禁记录。");
	FlushPendingBans();
	SQL_LoadAll();
	g_hReconnectTimer = null;

	return Plugin_Stop;
}

void QueuePendingBan(const char[] auth, int time, const char[] reason)
{
	if (g_hPendingBans == null)
		g_hPendingBans = new StringMap();

	char sReason[MAX_LENGTH];
	strcopy(sReason, sizeof(sReason), reason);
	ReplaceString(sReason, sizeof(sReason), "|", "/");
	ReplaceString(sReason, sizeof(sReason), "\t", " ");
	ReplaceString(sReason, sizeof(sReason), "\n", " ");
	ReplaceString(sReason, sizeof(sReason), "\r", " ");

	char sValue[512];
	FormatEx(sValue, sizeof(sValue), "%d|%d|%s", time, GetTime(), sReason);
	g_hPendingBans.SetString(auth, sValue, true);

	SavePendingBans();

	PrintToServer("[l4d2_banned] 数据库未连接，封禁已暂存：%s（%d 分钟，原因：%s）", auth, time, sReason);
}

bool IsPendingBanned(const char[] auth)
{
	char sValue[512];
	return (g_hPendingBans != null && g_hPendingBans.GetString(auth, sValue, sizeof(sValue)));
}

void SavePendingBans()
{
	if (g_hPendingBans == null)
		return;

	File f = OpenFile(g_sPendingPath, "w");
	if (f == null)
	{
		LogError("[l4d2_banned] 无法写入暂存文件: %s", g_sPendingPath);
		return;
	}

	StringMapSnapshot snap = g_hPendingBans.Snapshot();
	char sKey[MAX_LENGTH], sValue[512];

	for (int i = 0; i < snap.Length; i++)
	{
		snap.GetKey(i, sKey, sizeof(sKey));
		if (g_hPendingBans.GetString(sKey, sValue, sizeof(sValue)))
			f.WriteLine("%s\t%s", sKey, sValue);
	}

	delete snap;
	delete f;
}

void LoadPendingBans()
{
	if (g_hPendingBans == null)
		g_hPendingBans = new StringMap();

	if (!FileExists(g_sPendingPath))
		return;

	File f = OpenFile(g_sPendingPath, "r");
	if (f == null)
		return;

	char sLine[768];
	int count = 0;

	while (!f.EndOfFile() && f.ReadLine(sLine, sizeof(sLine)))
	{
		TrimString(sLine);
		if (sLine[0] == '\0')
			continue;

		char sParts[2][512];
		if (ExplodeString(sLine, "\t", sParts, 2, sizeof(sParts[])) != 2)
			continue;

		g_hPendingBans.SetString(sParts[0], sParts[1], true);
		count++;
	}

	delete f;

	if (count > 0)
		PrintToServer("[l4d2_banned] 已载入 %d 条离线待上传封禁记录。", count);
}

void FlushPendingBans()
{
	if (g_hPendingBans == null || g_hPendingBans.Size == 0)
	{
		if (FileExists(g_sPendingPath))
			DeleteFile(g_sPendingPath);

		return;
	}

	StringMapSnapshot snap = g_hPendingBans.Snapshot();
	char sKey[MAX_LENGTH], sValue[512];
	char sParts[3][MAX_LENGTH];
	int sent = 0;

	for (int i = 0; i < snap.Length; i++)
	{
		snap.GetKey(i, sKey, sizeof(sKey));
		if (!g_hPendingBans.GetString(sKey, sValue, sizeof(sValue)))
			continue;

		if (ExplodeString(sValue, "|", sParts, 3, sizeof(sParts[])) != 3)
			continue;

		/* 暂存文件里可能还是老格式(STEAM_X:Y:Z)键：换算成 SteamID64 再上传，
		 * 同时把老键作为回退身份传进去，避免库里已有老记录时插出重复行。 */
		char sAuth[MAX_LENGTH];
		strcopy(sAuth, sizeof(sAuth), sKey);

		if (!IsSteamID64Auth(sAuth))
		{
			char s64[MAX_LENGTH];

			if (AuthStringToSteam64(sAuth, s64, sizeof(s64)))
				strcopy(sAuth, sizeof(sAuth), s64);
		}

		SQL_Load(StringToInt(sParts[0]), sAuth, sParts[2], true, sKey);
		PrintToServer("[l4d2_banned] 上传离线封禁: %s（%s 分钟）", sKey, sParts[0]);
		sent++;
	}

	delete snap;
	g_hPendingBans.Clear();

	if (FileExists(g_sPendingPath))
		DeleteFile(g_sPendingPath);

	PrintToServer("[l4d2_banned] 离线封禁上传完成，共 %d 条。", sent);
}

/* ======================================================================
 *  banned_user.cfg 分批下发
 *  文件里几百条 banid 一次性 exec 会让引擎刷 Cbuf_AddText: buffer overflow，
 *  这里每 0.1 秒下发 40 条，效果相同但不再刷错误。
 * ==================================================================== */
void ExecBannedUserCfgChunked()
{
	if (g_hBanFileTimer != null || g_hBanFileLines != null)
		return; // 已经有一轮在跑

	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), "../../cfg/banned_user.cfg");

	if (!FileExists(sPath))
		return;

	File f = OpenFile(sPath, "r");
	if (f == null)
		return;

	ArrayList lines = new ArrayList(ByteCountToCells(256));
	char sLine[256];

	while (!f.EndOfFile() && f.ReadLine(sLine, sizeof(sLine)))
	{
		TrimString(sLine);

		if (sLine[0] == '\0' || StrContains(sLine, "//") == 0)
			continue;

		if (StrContains(sLine, "banid", false) != 0 && StrContains(sLine, "banip", false) != 0)
			continue;

		lines.PushString(sLine);
	}

	delete f;

	if (lines.Length == 0)
	{
		delete lines;
		return;
	}

	if (lines.Length <= BAN_FILE_CHUNK)
	{
		/* 少量：照旧整体 exec */
		delete lines;
		ServerCommand("exec banned_user.cfg");
		return;
	}

	g_hBanFileLines = lines;
	g_iBanFileIndex = 0;
	g_hBanFileTimer = CreateTimer(0.1, Timer_ExecBanFile, _, TIMER_REPEAT);

	PrintToServer("[l4d2_banned] banned_user.cfg 共 %d 条，分批加载中（每 0.1 秒 %d 条）...", lines.Length, BAN_FILE_CHUNK);
}

public Action Timer_ExecBanFile(Handle timer)
{
	if (g_hBanFileLines == null)
	{
		g_hBanFileTimer = null;
		return Plugin_Stop;
	}

	char sLine[256];
	int iTotal = g_hBanFileLines.Length;
	int iEnd = g_iBanFileIndex + BAN_FILE_CHUNK;

	for (; g_iBanFileIndex < iEnd && g_iBanFileIndex < iTotal; g_iBanFileIndex++)
	{
		g_hBanFileLines.GetString(g_iBanFileIndex, sLine, sizeof(sLine));
		ServerCommand("%s", sLine);
	}

	if (g_iBanFileIndex >= iTotal)
	{
		PrintToServer("[l4d2_banned] banned_user.cfg 分批加载完成（%d 条）。", iTotal);
		delete g_hBanFileLines;
		g_hBanFileLines = null;
		g_hBanFileTimer = null;
		return Plugin_Stop;
	}

	return Plugin_Continue;
}

public void OnMapEnd()
{
	/* 换图时把还没发完的分批任务清掉，避免句柄/内存悬挂 */
	if (g_hBanFileTimer != null)
	{
		KillTimer(g_hBanFileTimer);
		g_hBanFileTimer = null;
	}

	if (g_hBanFileLines != null)
	{
		delete g_hBanFileLines;
		g_hBanFileLines = null;
	}
}

void IniSQLite() 
{	
	/* 已经有连接（例如 sm_bandb 手动连上过）就不再重复建连，免得把好连接换成坏连接。 */
	if (g_dbSQL != null)
		return;

	char error[1024];
	Database db = IniSQLiteTry(error, sizeof(error));

	if (db == null)
	{
		if (g_bDatabaseType == false)
			SetFailState("Could not connect to the database \"l4d2_banned\" at the following error:\n%s", error);

		/* MySQL 连不上就重试，绝不卸载插件：否则这段时间的封禁会静默丢失。 */
		PrintToServer("[l4d2_banned] 数据库连接失败: %s（%.0f 秒后重试；期间封禁在本服执行并暂存，连上后自动上传）", error, RECONNECT_INTERVAL);
		StartReconnectTimer();
		return;
	}

	g_dbSQL = db;
}

/* 只负责"连一次、必要时建表"，成功返回 Database，失败返回 null（不 SetFailState）。
 * sm_bandb 用它做按需连接，IniSQLite 用它做启动连接。 */
Database IniSQLiteTry(char[] error, int maxlength)
{
	Database db;

	if (g_bDatabaseType == false)
	{
		db = SQLite_UseDatabase("l4d2_banned", error, maxlength);//创建指定名称的数据库.
		if (db == null)
			return null;

		/* SteamID 列存 17 位 SteamID64（AuthId_SteamID64）；老数据可能是 STEAM_X:Y:Z，
		 * 由 SQL_Load 的回退查询兼容，列名/类型不动。 */
		SQL_FastQuery(db, "CREATE TABLE IF NOT EXISTS l4d2_banned\
		(\
		SteamID NVARCHAR(32) NOT NULL DEFAULT '', \
		banreason NVARCHAR(32) NOT NULL DEFAULT '', \
		bantime INT NOT NULL DEFAULT 0, \
		timestamp INT NOT NULL DEFAULT 0);\
		");

		return db;
	}

	db = SQL_DefConnect(error, maxlength, true);
	if (db == null)
		return null;

	/* 先切 utf8mb4 再建表：让建表语句里的中文列注释按 utf8mb4 解析。 */
	if (!SQL_SetCharset(db, "utf8mb4"))
	{
		SQL_GetError(db, error, maxlength);
		db.Close();
		return null;
	}

	/* 表列 SteamID 现在存 17 位 SteamID64（AuthId_SteamID64）。
	 * 列名/类型一律不动：varchar(32) 装 17 位十进制绰绰有余，主键长度没变化，
	 * 老库不需要改结构，只需要把数据换算成 64 位（见 私人文件/docs/封禁改SteamID64_迁移方案.md）。
	 * banreason 与线上库/运维脚本对齐成 varchar(128)：线上表本来就是 128，
	 * 这里只是在"全新库"上建表时不会建成 32 而把长原因截断（表已存在时 CREATE 不生效）。 */
	SQL_FastQuery(db, "CREATE TABLE IF NOT EXISTS `l4d2_banned`  (\
								`SteamID` varchar(32) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL COMMENT '17位SteamID64(老数据可能是STEAM_X:Y:Z)',\
								`banreason` varchar(128) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL DEFAULT '',\
								`bantime` int NOT NULL,\
								`timestamp` int NOT NULL,\
								PRIMARY KEY (`SteamID`) USING BTREE\
								) ENGINE = InnoDB CHARACTER SET = utf8mb4 COLLATE = utf8mb4_general_ci ROW_FORMAT = DYNAMIC;");

	return db;
}

/* databases.cfg 的绝对路径，只用于 sm_bandb 打印库名（不打印账号密码）。 */
stock void GetDbConfigPath(char[] path, int maxlength)
{
	BuildPath(Path_SM, path, maxlength, "configs/databases.cfg");
}
//读取所有玩家数据.
stock void SQL_LoadAll() 
{
	for (int i = 1; i <= MaxClients; i++) 
	{
		if (IsClientConnected(i) && !IsFakeClient(i)) 
		{
			char auth[MAX_LENGTH];
			if (GetClientAuthId(i, AuthId_SteamID64, auth, sizeof(auth))) 
				SQL_Load(0, auth, "", false);//读取玩家数据.
			else
				KickClient(i, "你已被踢出.\n踢出原因:ID获取失败(拿不到 SteamID64).\n你的ID为:%s.", "未知");
		}
	}
}
//地图开始.
public void OnMapStart()
{
	IsReadFileValues();
	ExecBannedUserCfgChunked();//加载服务器封禁列表（分批，避免 Cbuf_AddText 溢出）.
	//PrintToServer("[地图开始](%f)(%d).", GetEngineTime(), g_bAllAllowReadingData);
}
//玩家连接游戏并完全进入游戏时.
public void OnClientPostAdminCheck(int client)
{
	if (!IsFakeClient(client) && g_eBanned[client].g_bBanStatus)
	{
		g_eBanned[client].g_bBanStatus = false;
		PrintToChat(client, "\x04[提示]\x05你已解封.");
		PrintToChat(client, "\x04[提示]\x05封禁时长:%s.", g_eBanned[client].sBanDuration);
		PrintToChat(client, "\x04[提示]\x05封禁时间:%s.", g_eBanned[client].sBanTime);
		PrintToChat(client, "\x04[提示]\x05解封时间:%s.", g_eBanned[client].sUnBanTime);
		PrintToChat(client, "\x04[提示]\x05封禁原因:%s.", g_eBanned[client].sBanReason);
	}
}
//玩家成功连接游戏时.
public void OnClientAuthorized(int client, const char[] auth)
{
	if (IsFakeClient(client))
		return;

	char sAuth[MAX_LENGTH];
	char sSteam2[MAX_LENGTH];
	g_eBanned[client].g_bBanStatus = false;

	/* 身份统一取 17 位 SteamID64；老库里还是 STEAM_X:Y:Z 的记录靠 SQL_Load 里的
	 * 回退查询命中，这里把 Steam2 一起取出来做回退身份（取不到就只查 64 位）。 */
	if (!ClientAuthPair(client, sAuth, sizeof(sAuth), sSteam2, sizeof(sSteam2)))
	{
		KickClient(client, "你已被踢出.\n踢出原因:ID获取失败(拿不到 SteamID64).\n你的ID为:%s.", auth[0] == '\0' ? "未知" : auth);
		return;
	}

	/* 离线暂存里可能还有老格式(STEAM_X:Y:Z)的键，两种都查一遍再决定放不放行。 */
	if (IsPendingBanned(sAuth) || (sSteam2[0] != '\0' && IsPendingBanned(sSteam2)))
	{
		KickClient(client, "你已被封禁.\n踢出原因:封禁记录正在同步.");
		return;
	}

	SQL_Load(0, sAuth, "", false, sSteam2);//读取玩家数据.
}
/* 读取/写入玩家数据（写入与进服校验共用）。
 * 查询策略：一条 SELECT 里用 IN 把「SteamID64」和「同一玩家的 legacy STEAM_X:Y:Z」一起查，
 * 64 位不存在时会命中老记录（迁移期兼容）；一条语句查完，不会出现"回退查询半途失败"的中间态。 */
stock void SQL_Load(int time, const char[] auth, const char[] reason, bool write, const char[] sAlso = "", int iNotify = 0) 
{
	if (!g_dbSQL)
	{
		/* 数据库断线：封禁先暂存到本地，连上后由 FlushPendingBans() 统一下发。 */
		if (write)
		{
			QueuePendingBan(auth, time, reason);
			return;
		}

		/* 进服校验：**固定放行**（服主要求，无开关）。
		 * 本地暂存封禁已经在 OnClientAuthorized 里单独查过，命中照样踢，不受这里影响；
		 * 只有"连上了但语句报错"那条路径才会踢（见 BanCheckFailed）。 */
		PrintToServer("[l4d2_banned] 数据库未连接，无法校验 %s 的封禁状态（策略固定=放行）", auth);
		return;
	}

	/* 回退身份：auth 是 64 位就取该玩家的 Steam2，auth 是 Steam2 就取 64 位；
	 * IP/自定义身份取不到（不做回退，也绝不把 IP 当 64 位 ID 去换算）。 */
	char sAlt[MAX_LENGTH];
	if (!GetAltAuth(auth, sAlt, sizeof(sAlt)))
		sAlt[0] = '\0';

	char sIn[AUTH_IN_MAX];
	AuthInList(auth, sAlt, sAlso, sIn, sizeof(sIn));

	char query[4096];
	FormatEx(query, sizeof query, "SELECT * FROM l4d2_banned WHERE SteamID IN (%s);", sIn);

	DataPack hPack = new DataPack();
	hPack.WriteCell(time);
	hPack.WriteCell(write);
	hPack.WriteString(auth);
	hPack.WriteString(reason);
	hPack.WriteCell(iNotify);		// 发起这次写库的管理员槽位（0 = rcon/服务器控制台）：结果回显给他
	g_dbSQL.Query(SQLQueryCallback, query, hPack);
}
//数据库查询回调（第一跳：SteamID64 + legacy 一起查，取"最严"的那一条）。
void SQLQueryCallback(Database db, DBResultSet results, const char[] error, DataPack hPack) 
{
	hPack.Reset();
	int time = hPack.ReadCell();
	bool write = view_as<bool>(hPack.ReadCell());

	char auth[MAX_LENGTH];
	hPack.ReadString(auth, sizeof(auth));
	
	char reason[MAX_LENGTH];
	hPack.ReadString(reason, sizeof(reason));

	int iNotify = hPack.ReadCell();		// v2.8.1：写库结果要回显给发起命令的管理员

	if (!db || !results) 
	{
		LogError("[l4d2_banned] 查询封禁记录失败: %s（身份:%s）", error, auth);

		/* 查不清就一定不放行（进服路径），写入则转入离线暂存，避免"封了但没入库"。 */
		BanCheckFailed(auth, time, write, reason);
		delete hPack;
		return;
	}

	int iNowTime = GetTime();
	int iBestRank = 0;      // 0=没有记录 1=已过期 2=生效中 3=永久
	int iBestBanTime = 0;
	int iBestStamp = 0;
	char sBestKey[MAX_LENGTH];
	char sBestReason[MAX_LENGTH];
	sBestKey[0] = '\0';
	sBestReason[0] = '\0';

	/* 同一玩家可能同时存在 64 位与老格式两条记录（迁移期），逐条比较取"最严"的：
	 * 永久 > 生效中 > 已过期；同级别取解封时间更晚的那条。 */
	while (results.FetchRow())
	{
		char sKey[MAX_LENGTH];
		char sReason[MAX_LENGTH];
		results.FetchString(0, sKey, sizeof(sKey));
		results.FetchString(1, sReason, sizeof(sReason));
		int iBanTime = results.FetchInt(2);
		int iStamp = results.FetchInt(3);
		int iExpire = (iBanTime <= 0) ? 0 : (iStamp + iBanTime * 60);

		int iRank;
		if (iBanTime <= 0)
			iRank = 3;
		else if (iExpire > iNowTime)
			iRank = 2;
		else
			iRank = 1;

		bool bBetter = false;
		if (iRank > iBestRank)
			bBetter = true;
		else if (iRank == iBestRank && iRank != 3 && iExpire > iBestBanTime * 60 + iBestStamp)
			bBetter = true;

		if (bBetter)
		{
			iBestRank = iRank;
			iBestBanTime = iBanTime;
			iBestStamp = iStamp;
			strcopy(sBestKey, sizeof(sBestKey), sKey);
			strcopy(sBestReason, sizeof(sBestReason), sReason);
		}
	}

	if (iBestRank == 0)
	{
		/* 64 位与老格式都没有记录 → 确实没被封。 */
		if (write)
			InsertNewBan(auth, time, reason, iNowTime, iNotify);

		delete hPack;
		return;
	}

	bool bLegacyKey = !StrEqual(sBestKey, auth, false);

	HandleBanHit(auth, sBestKey, time, write, reason, sBestReason, iBestBanTime, iBestStamp, iNotify);

	/* 命中的是老格式主键 → 记录还在（永久/生效中/刚写入）就顺手把主键升级成 64 位。
	 * 已过期且只读的情况上面已经把这行删掉了，不必再升级。 */
	if (bLegacyKey && g_bLegacyUpgrade && !(iBestRank == 1 && !write))
		QueryUpgradeKey(auth, sBestKey);

	delete hPack;
}
/* 把老格式主键升级成 SteamID64。
 * 先 SELECT 确认新主键不存在（避免主键冲突：MySQL 更新会报错，SQLite 没有主键则多出重复行），
 * 确认不存在才 UPDATE；UPDATE 失败只记日志，老记录保留，封禁照常生效，绝不删数据。 */
void QueryUpgradeKey(const char[] auth, const char[] sLegacyKey)
{
	if (g_dbSQL == null || !IsSteamID64Auth(auth) || IsSteamID64Auth(sLegacyKey))
		return;

	char query[512];
	FormatEx(query, sizeof(query), "SELECT COUNT(*) FROM l4d2_banned WHERE SteamID = '%s';", auth);

	DataPack hUp = new DataPack();
	hUp.WriteString(auth);
	hUp.WriteString(sLegacyKey);
	g_dbSQL.Query(SQL_UpgradeCheckCallback, query, hUp);
}
//老记录升级成 64 位主键之前的"新主键是否已存在"检查回调.
void SQL_UpgradeCheckCallback(Database db, DBResultSet results, const char[] error, DataPack hPack)
{
	hPack.Reset();

	char auth[MAX_LENGTH];
	hPack.ReadString(auth, sizeof(auth));

	char sLegacyKey[MAX_LENGTH];
	hPack.ReadString(sLegacyKey, sizeof(sLegacyKey));
	delete hPack;

	if (!db || !results || !results.FetchRow())
	{
		LogError("[l4d2_banned] 升级主键前的存在性检查失败: %s（%s → %s）", error, sLegacyKey, auth);
		return;
	}

	if (results.FetchInt(0) > 0)
	{
		PrintToServer("[l4d2_banned] %s 对应的 64 位记录(%s)已存在，不动主键（两条记录请按迁移方案合并）", sLegacyKey, auth);
		return;
	}

	/* 上面 COUNT 已经排除了"新主键已存在"，这里再加一层 IGNORE：
	 * 万一期间有别处插了 64 位记录，MySQL 的 UPDATE IGNORE / SQLite 的 UPDATE OR IGNORE
	 * 会跳过冲突行而不是报错/写坏数据，老记录原样保留。 */
	char query[512];
	if (g_bDatabaseType)
		FormatEx(query, sizeof(query), "UPDATE IGNORE l4d2_banned SET SteamID = '%s' WHERE SteamID = '%s';", auth, sLegacyKey);
	else
		FormatEx(query, sizeof(query), "UPDATE OR IGNORE l4d2_banned SET SteamID = '%s' WHERE SteamID = '%s';", auth, sLegacyKey);

	if (SQL_FastQuery(g_dbSQL, query))
	{
		PrintToServer("[l4d2_banned] 老封禁记录已升级为 SteamID64: %s → %s", sLegacyKey, auth);
	}
	else
	{
		char sErr[256];
		SQL_GetError(g_dbSQL, sErr, sizeof(sErr));
		LogError("[l4d2_banned] 升级主键失败(保留老记录，封禁照常生效): %s → %s，错误: %s", sLegacyKey, auth, sErr);
	}
}
/* 查询链路走不通（连接掉了/语句报错）：写入走离线暂存，进服校验一律不放行。 */
stock void BanCheckFailed(const char[] auth, int time, bool write, const char[] reason)
{
	if (write)
	{
		QueuePendingBan(auth, time, reason);
		PrintToServer("[l4d2_banned] 封禁写库失败，已转入离线暂存: %s", auth);
		return;
	}

	KickEntity(auth, "你已被踢出.\n踢出原因:封禁状态校验失败(数据库查询出错)，请稍后重连.\n你的ID为:%s.", auth);
}
/* 命中一条封禁记录：sHitAuth 是这条记录在库里的主键（64 位或迁移期的老格式），
 * auth 是本次查询用的身份（只用来找回玩家索引/踢人）。 */
stock void HandleBanHit(const char[] auth, const char[] sHitAuth, int time, bool write, const char[] reason, const char[] sBanReason, int iBanTime, int iTimeStamp, int iNotify = 0)
{
	int iNowTime = GetTime();

	if (iBanTime <= 0)
	{
		if (write)
			NotifyBanAction(iNotify, true, "该玩家已有永久封禁，本次未改动库记录: %s", sHitAuth);

		KickEntity(auth, "你已被封禁.\n封禁时长:永久封禁.\n封禁时间:%s.\n封禁原因:%s", GetDateTime(iTimeStamp), sBanReason);
		return;
	}

	if (iBanTime * 60 + iTimeStamp > iNowTime)
	{
		int iSurplus = iBanTime * 60 - (iNowTime - iTimeStamp);

		if (write)
		{
			SQL_Save(time + iBanTime, iTimeStamp, sHitAuth, reason, auth, iNotify);//已存在数据就追加时长.
			return;
		}

		KickEntity(auth, "你已被封禁.\n剩余时长:%s.\n封禁时长:%s.\n封禁时间:%s.\n解封时间:%s.\n封禁原因:%s", 
			StandardizeTime(iSurplus), StandardizeTime(iBanTime * 60), 
			GetDateTime(iTimeStamp), GetDateTime(iTimeStamp + iBanTime * 60), sBanReason);
		return;
	}

	/* 记录已过期 */
	if (write)
	{
		SQL_Save(time, iNowTime, sHitAuth, reason, auth, iNotify);//重新封禁，重置时间.
		return;
	}

	SQL_Delete(sHitAuth, auth, iNotify);//删除过期记录(64 位与老主键一起删).

	int client = GetClientAuthIndex(auth);
	if (client != 0)
	{
		g_eBanned[client].g_bBanStatus = true;
		strcopy(g_eBanned[client].sBanTime, sizeof(esBanned::sBanTime), GetDateTime(iTimeStamp));
		strcopy(g_eBanned[client].sBanReason, sizeof(esBanned::sBanReason), sBanReason);
		strcopy(g_eBanned[client].sUnBanTime, sizeof(esBanned::sUnBanTime), GetDateTime(iTimeStamp + iBanTime * 60));
		strcopy(g_eBanned[client].sBanDuration, sizeof(esBanned::sBanDuration), StandardizeTime(iBanTime * 60));
	}
}
/* 库里没有记录 → 新增一条。主键用 auth（正常就是 17 位 SteamID64）；
 * 写库失败不静默吞：转入离线暂存，连上后自动补，避免"封了但没入库"。 */
stock void InsertNewBan(const char[] auth, int time, const char[] reason, int iNowTime, int iNotify = 0)
{
	char sReason[MAX_LENGTH];
	if (reason[0] == '\0')
		strcopy(sReason, sizeof(sReason), "未填写封禁原因");
	else
		strcopy(sReason, sizeof(sReason), reason);

	char sAuthEsc[MAX_LENGTH * 2];
	char sReasonEsc[MAX_LENGTH * 2];
	EscapeSql(auth, sAuthEsc, sizeof(sAuthEsc));
	EscapeSql(sReason, sReasonEsc, sizeof(sReasonEsc));

	char query[1024];
	FormatEx(query, sizeof query, "INSERT INTO l4d2_banned(SteamID, banreason, bantime, timestamp) VALUES ('%s', '%s', %d, %d);", sAuthEsc, sReasonEsc, time, iNowTime);

	if (!SQL_FastQuery(g_dbSQL, query))
	{
		char sErr[256];
		SQL_GetError(g_dbSQL, sErr, sizeof(sErr));
		PrintToServer("[l4d2_banned] 新增封禁记录失败: %s（%s），已转入离线暂存", auth, sErr);
		NotifyBanAction(iNotify, false, "新增封禁记录失败: %s（%s）；已转入离线暂存，重连后自动补写", auth, sErr);
		QueuePendingBan(auth, time, reason);
		return;
	}

	/* 迁移期双写：再补一条老格式镜像行，让还在跑 2.7.5 的服务器也查得到这条封禁。
	 * 用 INSERT IGNORE —— 万一该玩家名下已有同名老行（阶段一留下的），不报错也不覆盖。 */
	char sMirrorNote[96];
	sMirrorNote[0] = '\0';

	if (g_bDualWriteLegacy && IsSteamID64Auth(auth))
	{
		char sSteam2[MAX_LENGTH];
		if (Steam64ToSteam2(auth, sSteam2, sizeof(sSteam2)))
		{
			char sMirrorEsc[MAX_LENGTH * 2];
			EscapeSql(sSteam2, sMirrorEsc, sizeof(sMirrorEsc));

			char sMirrorQuery[1024];
			FormatEx(sMirrorQuery, sizeof(sMirrorQuery),
				"INSERT IGNORE INTO l4d2_banned(SteamID, banreason, bantime, timestamp) VALUES ('%s', '%s', %d, %d);",
				sMirrorEsc, sReasonEsc, time, iNowTime);

			if (SQL_FastQuery(g_dbSQL, sMirrorQuery))
				FormatEx(sMirrorNote, sizeof(sMirrorNote), "，并写入老格式镜像行 %s", sSteam2);
			else
			{
				char sErr2[256];
				SQL_GetError(g_dbSQL, sErr2, sizeof(sErr2));
				LogError("[l4d2_banned] 写老格式镜像行失败(不影响 64 位主键): %s -> %s，错误: %s", auth, sSteam2, sErr2);
			}
		}
	}

	NotifyBanAction(iNotify, true, "已新增库记录: %s（%s）%s", auth, time <= 0 ? "永久" : StandardizeTime(time * 60), sMirrorNote);

	if (time <= 0)
		KickEntity(auth, "你已被封禁.\n封禁时长:永久封禁.\n封禁时间:%s.\n封禁原因:%s", 
			GetDateTime(iNowTime), sReason);
	else
		KickEntity(auth, "你已被封禁.\n封禁时长:%s.\n封禁时间:%s.\n解封时间:%s.\n封禁原因:%s", 
			StandardizeTime(time * 60), GetDateTime(iNowTime), GetDateTime(time * 60 + iNowTime), sReason);
}
stock char[] GetDateTime(int stamp = -1)
{
	char sDate[128];
	FormatTime(sDate, sizeof(sDate), "%Y-%m-%d %H:%M:%S", stamp);
	return sDate;
}
stock void KickEntity(const char[] auth, const char[] format="", any ...)
{
	int client = GetClientAuthIndex(auth);
	
	if(client != 0)
	{
		char buffer[255];
		VFormat(buffer, sizeof(buffer), format, 3);//第四个参数表示(any ...)所在的位置.
		KickClient(client, "%s", buffer);
	}
}
/* ======================================================================
 *  身份工具：SteamID64 ↔ legacy STEAM_X:Y:Z（迁移期兼容用）
 *  · 64 位值放不进 SourcePawn 的 32 位 int，换算一律用十进制字符串运算
 *    （DecAdd / DecDoubleAddSmall + 常量 76561197960265728），不依赖 int64 native。
 *  · 76561197960265728 = 0x01100001_00000000，普通账号(user1/type1)的基址；
 *    STEAM_X:Y:Z 的 X 只表示 universe，STEAM_0 / STEAM_1 都映射到同一个 64 位值，故忽略 X。
 *  · 只在"兼容老数据"的路径上用；新封禁一律直接用 AuthId_SteamID64。
 * ==================================================================== */


//取玩家的两套身份串(17 位 SteamID64 + legacy Steam2);返回值表示是否拿到了 64 位.
stock bool ClientAuthPair(int client, char[] s64, int i64Max, char[] s2, int i2Max)
{
	s64[0] = '\0';
	s2[0] = '\0';
	GetClientAuthId(client, AuthId_Steam2, s2, i2Max);//拿不到就是空串(未认证/无 Steam).
	return GetClientAuthId(client, AuthId_SteamID64, s64, i64Max);
}
/* 给出同一个玩家的"另一套 ID"（64 ↔ STEAM_1:Y:Z / [U:1:Z]），纯算术换算，
 * 不依赖该玩家是否在线——离线解封/离线补传暂存也能把两种写法一起清掉。
 * IP 串 / 自定义身份没有对应写法，返回 false。 */
stock bool GetAltAuth(const char[] auth, char[] sAlt, int maxlen)
{
	sAlt[0] = '\0';

	if (auth[0] == '\0')
		return false;

	if (IsSteamID64Auth(auth))
		return Steam64ToSteam2(auth, sAlt, maxlen);

	if (!IsSteamID64Auth(auth) && !IsIPAddressLike(auth))
		return AuthStringToSteam64(auth, sAlt, maxlen);

	return false;
}
//17 位纯数字 = SteamID64;IP 串 / legacy STEAM_X:Y:Z / [U:1:x] 都不算.
stock bool IsSteamID64Auth(const char[] auth)
{
	int iLen = strlen(auth);

	if (iLen != 17)
		return false;

	for (int i = 0; i < iLen; i++)
	{
		if (!IsCharNumeric(auth[i]))
			return false;
	}

	return true;
}
//粗略判断 IPv4 串(三个点 + 全数字);只用来区分"IP 身份"，不做严格校验.
stock bool IsIPAddressLike(const char[] auth)
{
	int iDots = 0;

	for (int i = 0; auth[i] != '\0'; i++)
	{
		if (auth[i] == '.')
		{
			iDots++;
			continue;
		}

		if (!IsCharNumeric(auth[i]))
			return false;
	}

	return (iDots == 3);
}
//十进制字符串 ×2 再加一个个位数(0..9)。
stock bool DecDoubleAddSmall(const char[] sIn, int iAdd, char[] out, int maxlen)
{
	int iLen = strlen(sIn);

	if (iLen <= 0 || iLen + 2 > maxlen)
		return false;

	int iCarry = iAdd, iPos = 0;
	char sTmp[64];

	for (int i = iLen - 1; i >= 0; i--)
	{
		if (!IsCharNumeric(sIn[i]))
			return false;

		int iVal = (sIn[i] - '0') * 2 + iCarry;
		iCarry = iVal / 10;
		sTmp[iPos++] = view_as<char>('0' + (iVal % 10));
	}

	if (iCarry > 0)
		sTmp[iPos++] = view_as<char>('0' + iCarry);

	int j = 0;
	for (int i = iPos - 1; i >= 0; i--)
		out[j++] = sTmp[i];

	out[j] = '\0';
	return true;
}
//十进制字符串加法(out = a + b)。
stock bool DecAdd(const char[] a, const char[] b, char[] out, int maxlen)
{
	int iA = strlen(a) - 1;
	int iB = strlen(b) - 1;
	int iCarry = 0, iPos = 0;
	char sTmp[64];

	while ((iA >= 0 || iB >= 0 || iCarry > 0) && iPos < sizeof(sTmp) - 1)
	{
		int iVal = iCarry;

		if (iA >= 0)
		{
			if (!IsCharNumeric(a[iA]))
				return false;

			iVal += a[iA] - '0';
			iA--;
		}

		if (iB >= 0)
		{
			if (!IsCharNumeric(b[iB]))
				return false;

			iVal += b[iB] - '0';
			iB--;
		}

		iCarry = iVal / 10;
		sTmp[iPos++] = view_as<char>('0' + (iVal % 10));
	}

	if (iPos + 1 > maxlen)
		return false;

	int j = 0;
	for (int i = iPos - 1; i >= 0; i--)
		out[j++] = sTmp[i];

	out[j] = '\0';
	return true;
}
/* legacy STEAM_X:Y:Z → 17 位 SteamID64。
 * 公式：76561197960265728 + Z*2 + Y（X 只表示 universe，忽略）。 */
stock bool Steam2ToSteam64(const char[] sSteam2, char[] sOut, int maxlen)
{
	char sPart[3][64];
	if (ExplodeString(sSteam2, ":", sPart, 3, sizeof(sPart[])) != 3)
		return false;

	if (strncmp(sPart[0], "STEAM_", 6) != 0)
		return false;

	if (strlen(sPart[1]) != 1 || (sPart[1][0] != '0' && sPart[1][0] != '1'))
		return false;

	char sAcc[64];
	if (!DecDoubleAddSmall(sPart[2], sPart[1][0] - '0', sAcc, sizeof(sAcc)))
		return false;

	return DecAdd(STEAM64_BASE, sAcc, sOut, maxlen);
}
/* Steam3 [U:1:accountid] → 17 位 SteamID64（accountid 就是账号号，不用 ×2）。 */
stock bool Steam3ToSteam64(const char[] sSteam3, char[] sOut, int maxlen)
{
	char sPart[3][64];
	if (ExplodeString(sSteam3, ":", sPart, 3, sizeof(sPart[])) != 3)
		return false;

	if (!StrEqual(sPart[0], "[U", false) || !StrEqual(sPart[1], "1"))
		return false;

	char sAcc[64];
	strcopy(sAcc, sizeof(sAcc), sPart[2]);

	int iLen = strlen(sAcc);
	if (iLen <= 0)
		return false;

	if (sAcc[iLen - 1] == ']')
		sAcc[iLen - 1] = '\0';

	return DecAdd(STEAM64_BASE, sAcc, sOut, maxlen);
}
//十进制字符串减法(out = a - b，要求 a >= b)。
stock bool DecSub(const char[] a, const char[] b, char[] out, int maxlen)
{
	int iA = strlen(a) - 1;
	int iB = strlen(b) - 1;
	int iBorrow = 0, iPos = 0;
	char sTmp[64];

	while (iA >= 0)
	{
		if (!IsCharNumeric(a[iA]))
			return false;

		int iVal = (a[iA] - '0') - iBorrow;

		if (iB >= 0)
		{
			if (!IsCharNumeric(b[iB]))
				return false;

			iVal -= (b[iB] - '0');
			iB--;
		}

		if (iVal < 0)
		{
			iVal += 10;
			iBorrow = 1;
		}
		else
			iBorrow = 0;

		if (iPos >= sizeof(sTmp) - 1)
			return false;

		sTmp[iPos++] = view_as<char>('0' + iVal);
		iA--;
	}

	if (iBorrow != 0)
		return false;//a < b

	if (iPos + 1 > maxlen)
		return false;

	int j = 0;
	bool bLeading = true;
	for (int i = iPos - 1; i >= 0; i--)
	{
		if (bLeading && sTmp[i] == '0' && i > 0)
			continue;

		bLeading = false;
		out[j++] = sTmp[i];
	}

	out[j] = '\0';
	return true;
}
//十进制字符串除以 2（out = a / 2），返回余数（0 或 1）。
stock int DecHalfRem(const char[] a, char[] out, int maxlen)
{
	int iLen = strlen(a);
	if (iLen <= 0 || iLen + 1 > maxlen)
		return -1;

	int iRem = 0, j = 0;
	bool bLeading = true;

	for (int i = 0; i < iLen; i++)
	{
		if (!IsCharNumeric(a[i]))
			return -1;

		int iCur = iRem * 10 + (a[i] - '0');
		int iDigit = iCur / 2;
		iRem = iCur % 2;

		if (bLeading && iDigit == 0 && i < iLen - 1)
			continue;

		bLeading = false;
		out[j++] = view_as<char>('0' + iDigit);
	}

	out[j] = '\0';
	return iRem;
}
/* 17 位 SteamID64 → legacy STEAM_1:Y:Z（逆向换算）。
 * 先减基址 76561197960265728，再除 2：余数=Y，商=Z。 */
stock bool Steam64ToSteam2(const char[] sSteam64, char[] sOut, int maxlen)
{
	if (!IsSteamID64Auth(sSteam64))
		return false;

	char sDiff[64];
	if (!DecSub(sSteam64, STEAM64_BASE, sDiff, sizeof(sDiff)))
		return false;

	char sZ[64];
	int iY = DecHalfRem(sDiff, sZ, sizeof(sZ));

	if (iY < 0)
		return false;

	FormatEx(sOut, maxlen, "STEAM_1:%d:%s", iY, sZ);
	return true;
}
//Steam2 / Steam3 两种字符串身份 → SteamID64（其它格式返回 false）。
stock bool AuthStringToSteam64(const char[] auth, char[] sOut, int maxlen)
{
	if (StrEqual(auth, "[U", false) || strncmp(auth, "[U:", 3) == 0)
		return Steam3ToSteam64(auth, sOut, maxlen);

	return Steam2ToSteam64(auth, sOut, maxlen);
}
//把一个身份串加进 SQL IN 候选列表：跳过空/重复；STEAM_0: 与 STEAM_1: 两种写法都加。
stock void AddAuthCand(char sCand[][MAX_LENGTH], int &iCount, int iMax, const char[] sVal)
{
	if (sVal[0] == '\0' || iCount >= iMax)
		return;

	for (int i = 0; i < iCount; i++)
	{
		if (StrEqual(sCand[i], sVal, false))
			return;
	}

	strcopy(sCand[iCount], MAX_LENGTH, sVal);
	iCount++;

	if (strncmp(sVal, "STEAM_0:", 8) == 0 || strncmp(sVal, "STEAM_1:", 8) == 0)
	{
		char sSwap[MAX_LENGTH];
		FormatEx(sSwap, sizeof(sSwap), "%s%s", (sVal[6] == '0') ? "STEAM_1:" : "STEAM_0:", sVal[8]);
		AddAuthCand(sCand, iCount, iMax, sSwap);
	}
}
/* SQL 字符串转义：封禁原因里出现单引号/反斜杠会把拼出来的 SQL 弄坏。
 * MySQL 驱动用 SQL_EscapeString（' → \' 与 \\ 都处理），SQLite 分支同样走它。
 * 没有连接（离线暂存路径）时原样复制：那时根本不拼 SQL。 */
stock void EscapeSql(const char[] sIn, char[] sOut, int maxlen)
{
	if (g_dbSQL != null)
		SQL_EscapeString(g_dbSQL, sIn, sOut, maxlen);
	else
		strcopy(sOut, maxlen, sIn);
}
//拼出 SQL 的 IN 列表：'a', 'b', ...（自动去重、自动补另一种 universe 写法）。
stock void AuthInList(const char[] a1, const char[] a2, const char[] a3, char[] sOut, int maxlen)
{
	char sCand[6][MAX_LENGTH];
	int iCount = 0;

	AddAuthCand(sCand, iCount, 6, a1);
	AddAuthCand(sCand, iCount, 6, a2);
	AddAuthCand(sCand, iCount, 6, a3);

	sOut[0] = '\0';

	char sEsc[MAX_LENGTH * 2];

	for (int i = 0; i < iCount; i++)
	{
		if (i > 0)
			StrCat(sOut, maxlen, ", ");

		EscapeSql(sCand[i], sEsc, sizeof(sEsc));

		StrCat(sOut, maxlen, "'");
		StrCat(sOut, maxlen, sEsc);
		StrCat(sOut, maxlen, "'");
	}
}
//获取Auth对应的玩家索引(SteamID64 与 legacy Steam2 两种写法都认).
stock int GetClientAuthIndex(const char[] auth) 
{
	if (auth[0] == '\0')
		return 0;

	for (int i = 1; i <= MaxClients; i++) 
	{
		if (IsClientConnected(i) && !IsFakeClient(i))
		{	
			char s64[MAX_LENGTH], s2[MAX_LENGTH];
			ClientAuthPair(i, s64, sizeof(s64), s2, sizeof(s2));

			if (s64[0] != '\0' && StrEqual(auth, s64, false))
				return i;

			if (s2[0] != '\0' && StrEqual(auth, s2, false))
				return i;
		}
	}

	return 0;
}
//删除指定的玩家数据(64 位与老 Steam2 主键一起删，迁移期不会漏删).
stock void SQL_Delete(const char[] auth, const char[] sAlso = "", int iNotify = 0) 
{
	if (g_dbSQL == null)
	{
		/* 断线期间 sm_unban 不能静默吞掉：明确告诉管理员这次没删库。 */
		PrintToServer("[l4d2_banned] 数据库未连接，无法删除库记录: %s（本地封禁仍会移除）", auth);
		NotifyBanAction(iNotify, false, "数据库未连接，没能删除库记录: %s（本地封禁已移除）", auth);
		return;
	}

	char sAlt[MAX_LENGTH];
	if (!GetAltAuth(auth, sAlt, sizeof(sAlt)))
		sAlt[0] = '\0';

	char sIn[AUTH_IN_MAX];
	AuthInList(auth, sAlt, sAlso, sIn, sizeof(sIn));

	char query[4096];
	FormatEx(query, sizeof query, "DELETE FROM l4d2_banned WHERE SteamID IN (%s);", sIn);

	DataPack hPack = new DataPack();
	hPack.WriteString(auth);
	hPack.WriteCell(iNotify);
	g_dbSQL.Query(SQL_CallbackDelOld, query, hPack);
}
//删除数据回调.
void SQL_CallbackDelOld(Database db, DBResultSet results, const char[] error, any data) 
{
	char auth[128];
	int iNotify = 0;
	DataPack hPack = view_as<DataPack>(data);
	if (hPack != null)
	{
		hPack.Reset();
		hPack.ReadString(auth, sizeof(auth));
		iNotify = hPack.ReadCell();
		delete hPack;
	}

	if (!db || !results) 
	{
		PrintToServer("[l4d2_banned] 删除库记录失败: %s（%s）", auth, error);
		LogError("[l4d2_banned] 删除库记录失败: %s（%s）", auth, error);
		NotifyBanAction(iNotify, false, "删除库记录失败: %s（%s）", auth, error);
		return;
	}

	/* AffectedRows == 0 是"库里本来就没这条"，也要说清楚，避免误以为删成功。
	 * v2.8.1：同时回显给执行 sm_unban 的管理员（阶段一双行状态下正常应删 2 行）。 */
	PrintToServer("[l4d2_banned] 已删除库记录: %s（影响 %d 行）", auth, results.AffectedRows);

	if (results.AffectedRows > 0)
		NotifyBanAction(iNotify, true, "已删除库记录: %s（影响 %d 行）", auth, results.AffectedRows);
	else
		NotifyBanAction(iNotify, false, "库里没有匹配的记录: %s（0 行被删；若确认封过，请检查 ID 写法）", auth);
}
/* 更新玩家数据。
 * auth 传的是这条记录在库里的主键（64 位或迁移期的老格式）；
 * sAlso 是同一个玩家的另一种写法（阶段一的双行状态）——
 * 用 WHERE SteamID IN (…) 一次性更新两行，否则会出现"64 位行改了、老行还是旧时长/旧原因"，
 * 封禁列表里两条记录对不上（v2.8.1 修）。
 * iNotify 是发起这次写库的管理员槽位：结果回显给他，不再只打到服务器控制台。 */
stock void SQL_Save(int time, int iNowTime, const char[] auth, const char[] reason, const char[] sAlso = "", int iNotify = 0) 
{
	if (!g_dbSQL)
	{
		NotifyBanAction(iNotify, false, "数据库未连接，更新没写进库: %s", auth);
		return;
	}

	char sReasonEsc[MAX_LENGTH * 2];
	EscapeSql(reason[0] == '\0' ? "无" : reason, sReasonEsc, sizeof(sReasonEsc));

	/* 主键列表：命中的那一行 + 同一玩家的另一种写法（含 STEAM_0/STEAM_1 互换）。 */
	char sAlt[MAX_LENGTH];
	if (!GetAltAuth(auth, sAlt, sizeof(sAlt)))
		sAlt[0] = '\0';

	char sIn[AUTH_IN_MAX];
	AuthInList(auth, sAlt, sAlso, sIn, sizeof(sIn));

	char query[4096];
	FormatEx(query, sizeof query, "UPDATE l4d2_banned SET banreason = '%s', bantime = %d, timestamp = %d WHERE SteamID IN (%s);", sReasonEsc, time, iNowTime, sIn);

	if (!SQL_FastQuery(g_dbSQL, query))
	{
		char sErr[256];
		SQL_GetError(g_dbSQL, sErr, sizeof(sErr));
		PrintToServer("[l4d2_banned] 更新封禁记录失败: %s（%s）", auth, sErr);
		NotifyBanAction(iNotify, false, "更新封禁记录失败: %s（%s）", auth, sErr);
	}
	else
	{
		/* SQL_FastQuery 不返回结果集，拿不到影响行数；这里用一次轻量 COUNT 复核，
		 * 让管理员能看到"库里确实有这条/共几行被同步"。 */
		char sCheck[4096];
		FormatEx(sCheck, sizeof(sCheck), "SELECT COUNT(*) FROM l4d2_banned WHERE SteamID IN (%s);", sIn);
		DBResultSet rsChk = SQL_Query(g_dbSQL, sCheck);
		if (rsChk != null && rsChk.FetchRow())
			NotifyBanAction(iNotify, true, "已更新库记录: %s（库里该玩家名下 %d 行已同步）", auth, rsChk.FetchInt(0));
		else
			NotifyBanAction(iNotify, true, "已更新库记录: %s", auth);
		delete rsChk;
	}

	if(time == 0)
		KickEntity(auth, "你已被封禁.\n封禁时长:永久封禁.\n封禁时间:%s.\n封禁原因:%s.", GetDateTime(iNowTime), reason[0] == '\0' ? "无" : reason);
	else
		KickEntity(auth, "你已被封禁.\n额外时长:%s.\n封禁时间:%s.\n解封时间:%s.\n封禁原因:%s.", StandardizeTime(time * 60), GetDateTime(time * 60 + iNowTime), reason[0] == '\0' ? "无" : reason);
}
/* 把"库里到底写没写成功"回显给执行命令的人（v2.8.1）。
 *   · iNotify > 0  ：聊天框 + 控制台都给（管理员在游戏里执行 sm_ban / sm_addban 时看得到）；
 *   · iNotify == 0 ：只打服务器控制台（rcon / 服务器控制台执行，本来就在看控制台）。
 * 成功标 [库✓]、失败标 [库✗]，一眼能分清"命令执行了"和"库里真的写进去了"。 */
stock void NotifyBanAction(int iNotify, bool bOk, const char[] format, any ...)
{
	char sDetail[384];
	VFormat(sDetail, sizeof(sDetail), format, 4);

	char sLine[448];
	FormatEx(sLine, sizeof(sLine), "[l4d2_banned] %s %s", bOk ? "[库✓]" : "[库✗]", sDetail);

	PrintToServer("%s", sLine);

	if (iNotify > 0 && iNotify <= MaxClients && IsClientInGame(iNotify) && !IsFakeClient(iNotify))
		PrintToChat(iNotify, "\x04[l4d2_banned]\x01 %s %s", bOk ? "库✓" : "库✗", sDetail);
}
//float fTime[] = {31536000.0, 2626560.0, 86400.0, 3600.0, 60.0};
//https://forums.alliedmods.net/showthread.php?t=288686
stock char[] StandardizeTime(int iRunTime)
{
	int iTemp[4];
	char sData[128], sTime[sizeof(iTemp)][32];
	float remainder = float(iRunTime);
	float fTime[] = {86400.0, 3600.0, 60.0};
	char sDate[][] = {"天", "小时", "分钟", "秒"};
	
	iTemp[0] = RoundToFloor(remainder / fTime[0]);
	remainder = remainder - float(iTemp[0]) * fTime[0];

	iTemp[1] = RoundToFloor(remainder / fTime[1]);
	remainder = remainder - float(iTemp[1]) * fTime[1];

	iTemp[2] = RoundToFloor(remainder / fTime[2]);
	remainder = remainder - float(iTemp[2]) * fTime[2];

	iTemp[3] = RoundToFloor(remainder);

	if(iTemp[0] > 0)
		FormatEx(sTime[0], sizeof(sTime[]), "%d%s", iTemp[0], sDate[0]);
	else
	{
		for (int i = 0; i < sizeof(sTime); i++)
			if(iTemp[i] > 0)
				FormatEx(sTime[i], sizeof(sTime[]), "%d%s", iTemp[i], sDate[i]);
	}
	ImplodeStrings(sTime, sizeof(sTime), "", sData, sizeof(sData));//打包字符串.
	return sData;
}
void OpenBanListMenu(int client, int index, bool bButton = false)
{
	char sLine[128], sData[32];
	Menu menu = new Menu(MenuBanListHandler);
	Format(sLine, sizeof(sLine), "封禁列表:\n ");
	IntToString(bButton, sData, sizeof(sData));
	menu.SetTitle("%s", sLine);
	menu.AddItem(sData, "到期封禁");
	menu.AddItem(sData, "临时封禁");
	menu.AddItem(sData, "永久封禁");
	menu.ExitButton = true;//默认值:true,设置为:false,则不显示退出选项.
	menu.ExitBackButton = bButton;//菜单首页显示数字8返回上一页选项.
	menu.DisplayAt(client, index, MENU_TIME_FOREVER);
}

int MenuBanListHandler(Menu menu, MenuAction action, int client, int itemNum)
{
	switch(action)
	{
		case MenuAction_Select:
		{
			char sItem[128], sName[32];
			menu.GetItem(itemNum, sItem, sizeof(sItem), _, sName, sizeof(sName));
			SQL_QueryBanList(client, 0, view_as<bool>(StringToInt(sItem)), itemNum, sName);
		}
		case MenuAction_Cancel:
		{
			if (itemNum == MenuCancel_ExitBack && g_hTopMenu != null)
				g_hTopMenu.Display(client, TopMenuPosition_LastCategory);
		}
		case MenuAction_End:
			delete menu;
	}
	return 0;
}
//查询封禁列表.
void SQL_QueryBanList(int client, int iIndex, bool bButton, int type, char[] sName)
{
	if (!g_dbSQL)
		return;
	
	char query[1024];

	switch(type)
	{
		case 0:
			FormatEx(query, sizeof(query), "SELECT * FROM l4d2_banned WHERE bantime > 0 ORDER BY timestamp DESC;");//到期封禁.
		case 1:
			FormatEx(query, sizeof(query), "SELECT * FROM l4d2_banned WHERE bantime > 0 ORDER BY timestamp DESC;");//临时封禁.
		case 2:
			FormatEx(query, sizeof(query), "SELECT * FROM l4d2_banned WHERE bantime = 0 ORDER BY timestamp DESC;");//永久封禁.
		
		
	}
	DataPack hPack = new DataPack();
	hPack.WriteCell(GetClientUserId(client));
	hPack.WriteCell(iIndex);
	hPack.WriteCell(bButton);
	hPack.WriteCell(type);
	hPack.WriteString(sName);
	g_dbSQL.Query(SQL_CallbackAllLoad, query, hPack);
}
//查询结果回调.
void SQL_CallbackAllLoad(Database db, DBResultSet results, const char[] error, DataPack hPack) 
{
	int client;
	hPack.Reset();
	if (!(client = GetClientOfUserId(hPack.ReadCell())))
	{
		delete hPack;
		return;
	}
	if (!db || !results) 
	{
		delete hPack;
		LogError("[错误]%N查询封禁信息时出现错误,原因:%s", client, error);
		return;
	}
	int iIndex = hPack.ReadCell();
	bool bButton = view_as<bool>(hPack.ReadCell());
	g_bButton[client] = bButton;
	int type = hPack.ReadCell();
	char sName[32];
	hPack.ReadString(sName, sizeof(sName));

	esBanList banlist;
	ArrayList ListArray = new ArrayList(sizeof(banlist));

	while (results.FetchRow())
	{
		char sSteamID[128];
		results.FetchString(0, sSteamID, sizeof(sSteamID));
		char sBanReason[128];
		results.FetchString(1, sBanReason, sizeof(sBanReason));
		int iBanTime = results.FetchInt(2);
		int iTimesTamp = results.FetchInt(3);
		int iNowTime = GetTime();

		switch(type)
		{
			case 0:
			{
				if(iBanTime * 60 + iTimesTamp <= iNowTime)
				{
					strcopy(banlist.esSteamID, sizeof(esBanList::esSteamID), sSteamID);
					strcopy(banlist.esBanReason, sizeof(esBanList::esBanReason), sBanReason);
					banlist.eiBanTime = iBanTime;
					banlist.eiTimesTamp = iTimesTamp;
					ListArray.PushArray(banlist);//推送数据到动态数组末尾.
				}
			}
			case 1:
			{
				if(iBanTime * 60 + iTimesTamp > iNowTime)
				{
					strcopy(banlist.esSteamID, sizeof(esBanList::esSteamID), sSteamID);
					strcopy(banlist.esBanReason, sizeof(esBanList::esBanReason), sBanReason);
					banlist.eiBanTime = iBanTime;
					banlist.eiTimesTamp = iTimesTamp;
					ListArray.PushArray(banlist);//推送数据到动态数组末尾.
				}
			}
			case 2:
			{
				strcopy(banlist.esSteamID, sizeof(esBanList::esSteamID), sSteamID);
				strcopy(banlist.esBanReason, sizeof(esBanList::esBanReason), sBanReason);
				banlist.eiBanTime = iBanTime;
				banlist.eiTimesTamp = iTimesTamp;
				ListArray.PushArray(banlist);//推送数据到动态数组末尾.
			}
		}
	}
	delete hPack;
	DisplayBanListMenu(client, iIndex, bButton, type, ListArray, sName);
}
void DisplayBanListMenu(int client, int iIndex, bool bButton, int type, ArrayList ListArray, char[] sName)
{
	if(ListArray.Length == 0)
	{
		delete ListArray;
		PrintToChat(client, "\x04[提示]\x05没有查询到\x03%s\x05.", sName);
		OpenBanListMenu(client, 0, bButton);
		return;
	}

	esBanList banlist;
	char sLine[128], sData[256], sInfo[8][128];
	Menu menu = new Menu(MenuDisplayBanListHandler);
	Format(sLine, sizeof(sLine), "%s:\n ", sName);
	menu.SetTitle("%s", sLine);

	for (int i = 0; i < ListArray.Length; i++)
	{
		ListArray.GetArray(i, banlist);

		Format(sInfo[0], sizeof(sInfo[]), "%s", banlist.esSteamID);
		Format(sInfo[1], sizeof(sInfo[]), "%s", banlist.esBanReason);
		Format(sInfo[2], sizeof(sInfo[]), "%d", banlist.eiBanTime);
		Format(sInfo[3], sizeof(sInfo[]), "%d", banlist.eiTimesTamp);
		Format(sInfo[4], sizeof(sInfo[]), "%d", bButton);
		Format(sInfo[5], sizeof(sInfo[]), "%d", iIndex);
		Format(sInfo[6], sizeof(sInfo[]), "%s", sName);
		Format(sInfo[7], sizeof(sInfo[]), "%d", type);
		ImplodeStrings(sInfo, sizeof(sInfo), "|", sData, sizeof(sData));//打包字符串.

		switch(type)
		{
			case 0:
				Format(sLine, sizeof(sLine), "解封:(%s),玩家:(%s)", GetDateTime(StringToInt(sInfo[2]) * 60 + StringToInt(sInfo[3])), sInfo[0]);
			case 1:
				Format(sLine, sizeof(sLine), "玩家:(%s),剩余:(%s)", sInfo[0], StandardizeTime(StringToInt(sInfo[2]) * 60 - (GetTime() - StringToInt(sInfo[3]))));
			case 2:
				Format(sLine, sizeof(sLine), "封禁:(%s),玩家:(%s)", GetDateTime(StringToInt(sInfo[3])), sInfo[0]);
		}
		menu.AddItem(sData, sLine);
	}
	menu.ExitButton = true;//默认值:true,设置为:false,则不显示退出选项.
	menu.ExitBackButton = true;//菜单首页显示数字8返回上一页选项.
	menu.DisplayAt(client, iIndex, MENU_TIME_FOREVER);
	delete ListArray;
}
//菜单回调.
int MenuDisplayBanListHandler(Menu menu, MenuAction action, int client, int itemNum)
{
	switch(action)
	{
		case MenuAction_End:
			delete menu;
		case MenuAction_Select:
		{
			char sItem[256], sName[128];
			menu.GetItem(itemNum, sItem, sizeof(sItem), _, sName, sizeof(sName));
			OpenDeleteBanDataMenu(client, sItem, menu.Selection);
		}
		case MenuAction_Cancel:
			if (itemNum == MenuCancel_ExitBack)
				OpenBanListMenu(client, 0, g_bButton[client]);
	}
	return 0;
}
void OpenDeleteBanDataMenu(int client, char[] sItem, int iIndex)
{
	int iNowTime = GetTime();
	char sLine[128], sInfo[8][128];
	ExplodeString(sItem, "|", sInfo, sizeof(sInfo), sizeof(sInfo[]));//拆分字符串.

	Format(g_sPlayerData[0][client], sizeof(g_sPlayerData[][]), "%s", sInfo[0]);
	Format(g_sPlayerData[1][client], sizeof(g_sPlayerData[][]), "%s", sInfo[4]);
	Format(g_sPlayerData[2][client], sizeof(g_sPlayerData[][]), "%d", iIndex);
	Format(g_sPlayerData[3][client], sizeof(g_sPlayerData[][]), "%s", sInfo[6]);
	Format(g_sPlayerData[4][client], sizeof(g_sPlayerData[][]), "%s", sInfo[7]);

	int time = StringToInt(sInfo[2]) * 60 - (iNowTime - StringToInt(sInfo[3]));
	Panel panel = new Panel();

	Format(sLine, sizeof(sLine), "封禁类型:(%s)", StringToInt(sInfo[2]) == 0 ? "永封" : time <= iNowTime ? "临封" : "解封");
	panel.SetTitle(sLine);
	Format(sLine, sizeof(sLine), "剩余时长:(%s)", StringToInt(sInfo[2]) == 0 ? "永封" : StringToInt(sInfo[2]) * 60 + StringToInt(sInfo[3]) > iNowTime ? StandardizeTime(time) : "解封");
	panel.DrawItem(sLine, ITEMDRAW_DISABLED|ITEMDRAW_RAWLINE);
	Format(sLine, sizeof(sLine), "封禁时长:(%s)", StringToInt(sInfo[2]) == 0 ? "永久封禁" : StandardizeTime(StringToInt(sInfo[2]) * 60));
	panel.DrawItem(sLine, ITEMDRAW_DISABLED|ITEMDRAW_RAWLINE);
	Format(sLine, sizeof(sLine), "解封时间:(%s)", StringToInt(sInfo[2]) == 0 ? "永久封禁" : time > iNowTime ? StandardizeTime(time) : GetDateTime(StringToInt(sInfo[2]) * 60 + StringToInt(sInfo[3])));
	panel.DrawItem(sLine, ITEMDRAW_DISABLED|ITEMDRAW_RAWLINE);
	Format(sLine, sizeof(sLine), "封禁时间:(%s)", GetDateTime(StringToInt(sInfo[3])));
	panel.DrawItem(sLine, ITEMDRAW_DISABLED|ITEMDRAW_RAWLINE);
	Format(sLine, sizeof(sLine), "玩家名称:(%s)", sInfo[0]);
	panel.DrawItem(sLine, ITEMDRAW_DISABLED|ITEMDRAW_RAWLINE);
	Format(sLine, sizeof(sLine), "封禁原因:(%s)", sInfo[1]);
	panel.DrawItem(sLine, ITEMDRAW_DISABLED|ITEMDRAW_RAWLINE);

	panel.DrawText(" \n");
	panel.DrawItem("删除");
	panel.DrawItem(" ", ITEMDRAW_SPACER);
	panel.DrawItem(" ", ITEMDRAW_SPACER);
	panel.DrawItem(" ", ITEMDRAW_SPACER);
	panel.DrawItem(" ", ITEMDRAW_SPACER);
	panel.DrawItem(" ", ITEMDRAW_SPACER);
	panel.DrawItem(" ", ITEMDRAW_SPACER);
	panel.DrawItem("返回");
		
	panel.DrawText(" \n");
	panel.DrawItem("0. 退出", ITEMDRAW_DISABLED|ITEMDRAW_RAWLINE);
	panel.Send(client, MenuDeleteBanDataHandler, MENU_TIME_FOREVER);
}
//菜单回调.
int MenuDeleteBanDataHandler(Menu menu, MenuAction action, int client, int itemNum)
{
	switch(action)
	{
		case MenuAction_End:
			delete menu;
		case MenuAction_Select:
		{
			switch(itemNum)
			{
				case 1:
					SQL_DeleteBanData(client, g_sPlayerData[0][client]);
				case 8:
					SQL_QueryBanList(client, StringToInt(g_sPlayerData[2][client]), view_as<bool>(StringToInt(g_sPlayerData[1][client])), StringToInt(g_sPlayerData[4][client]), g_sPlayerData[3][client]);//重新打开菜单.
			}
		}
	}
	return 0;
}
//删除指定的密钥数据(菜单里删的那条；迁移期连同一玩家的老格式记录一起删).
stock void SQL_DeleteBanData(int client, const char[] sSteamID) 
{
	if (g_dbSQL == null)
	{
		PrintToServer("[l4d2_banned] 数据库未连接，无法删除库记录: %s", sSteamID);
		return;
	}

	char sAlt[MAX_LENGTH];
	if (!GetAltAuth(sSteamID, sAlt, sizeof(sAlt)))
		sAlt[0] = '\0';

	char sIn[AUTH_IN_MAX];
	AuthInList(sSteamID, sAlt, "", sIn, sizeof(sIn));

	char query[4096];
	FormatEx(query, sizeof query, "DELETE FROM l4d2_banned WHERE SteamID IN (%s);", sIn);
	g_dbSQL.Query(SQL_CallbackBanData, query, GetClientUserId(client));
}
//删除数据回调.
void SQL_CallbackBanData(Database db, DBResultSet results, const char[] error, any client) 
{
	/* 删除失败/没删到行都要说清楚，避免"点了一下以为删了"。 */
	if (!db || !results)
	{
		PrintToServer("[l4d2_banned] 菜单删除封禁记录失败: %s", error);
		LogError("[l4d2_banned] 菜单删除封禁记录失败: %s", error);
	}
	else if (results.AffectedRows == 0)
	{
		PrintToServer("[l4d2_banned] 菜单删除：库里已经没有这条记录（0 行受影响）");
	}
	else
	{
		PrintToServer("[l4d2_banned] 菜单删除：已删除 %d 行", results.AffectedRows);
	}

	if ((client = GetClientOfUserId(client)))
		SQL_QueryBanList(client, StringToInt(g_sPlayerData[2][client]), view_as<bool>(StringToInt(g_sPlayerData[1][client])), StringToInt(g_sPlayerData[4][client]), g_sPlayerData[3][client]);//重新打开菜单.
}
//监听封禁函数.
public Action OnBanClient(int client, int time, int flags, const char[] reason, const char[] kick_message, const char[] command, any source)
{
	/* 数据库断线时：本服照样踢人 + 记录暂存（SQL_Load 里会入队），连上后自动上传。 */
	if (g_dbSQL == null)
	{
		if (client > 0 && IsClientInGame(client))
			KickClient(client, "你已被封禁.\n踢出原因:%s", reason[0] == '\0' ? "无" : reason);

		if (flags & BANFLAG_NOKICK)
		{
			char auth[MAX_LENGTH];
			if (GetClientAuthId(client, AuthId_SteamID64, auth, sizeof(auth)))
			{
				PrintToServer("[l4d2_banned] 库未连接，封禁先暂存: %s | %d 分钟 | %s", auth, time, reason[0] == '\0' ? "无" : reason);
				QueuePendingBan(auth, time, reason[0] == '\0' ? "无" : reason);

				int iNotify = view_as<int>(source);
				NotifyBanAction(iNotify, false, "数据库未连接，%s 的封禁已存入本地暂存，重连后自动写库", auth);
			}

			return Plugin_Handled;
		}

		return Plugin_Continue;
	}

	if(flags & BANFLAG_NOKICK)//封禁玩家函数添加了禁用踢出玩家功能时使用此插件的数据库方式记录封禁信息.
	{
		char auth[128];
		if (GetClientAuthId(client, AuthId_SteamID64, auth, sizeof(auth)))
		{
			/* 入库一律用 17 位 SteamID64；日志里把 legacy Steam2 一起打出来，
			 * 方便按老习惯拿 STEAM_X:Y:Z 去库里/控制台对账。 */
			char sSteam2[MAX_LENGTH];
			if (GetClientAuthId(client, AuthId_Steam2, sSteam2, sizeof(sSteam2)))
				PrintToServer("[l4d2_banned] 封禁入库: %s (SteamID64) / %s (legacy) | %d 分钟 | %s", auth, sSteam2, time, reason[0] == '\0' ? "无" : reason);
			else
				PrintToServer("[l4d2_banned] 封禁入库: %s (SteamID64) | %d 分钟 | %s", auth, time, reason[0] == '\0' ? "无" : reason);

			/* v2.8.1：source 是 BanPlayers(...) 的最后一个参数 = 执行 sm_ban 的管理员槽位，
			 * 带进异步回调好把"库里写没写进去"回显给他（target 是 client，别搞混）。 */
			int iNotify = view_as<int>(source);
			if (iNotify < 0 || iNotify > MaxClients)
				iNotify = 0;

			SQL_Load(time, auth, reason[0] == '\0' ? "无" : reason, true, "", iNotify);//读取玩家数据.
		}
		else if (client > 0 && IsClientInGame(client))
			KickClient(client, "你已被踢出.\n踢出原因:ID获取失败(拿不到 SteamID64).");

		return Plugin_Handled;//阻止写入封禁信息.
	}

	return Plugin_Continue;//允许写入封禁信息.
}
//监听封禁函数.
public Action OnBanIdentity(const char[] auth, int time, int flags, const char[] reason, const char[] command, any source)
{
	/* auth 可能是 17 位 SteamID64 / legacy STEAM_X:Y:Z / [U:1:x] / IP（sm_banip 传的就是 IP）。
	 * IP 不是 64 位 ID：原样按 IP 串入库（老行为，varchar(32) 存得下），插件不做换算，
	 * 也绝不把某人的 SteamID64 跟 IP 串混在一起比。 */
	if (StrEqual(auth, "STEAM_ID_STOP_IGNORING_RETVALS", false))
	{
		KickEntity(auth, "你已被踢出.\n踢出原因:ID获取失败.你的ID为:%s.", auth);//执行踢出玩家并显示原因.
		return Plugin_Handled;
	}

	char sAuth[MAX_LENGTH];
	char sAlso[MAX_LENGTH];
	strcopy(sAuth, sizeof(sAuth), auth);
	sAlso[0] = '\0';

	if (IsIPAddressLike(auth))
	{
		PrintToServer("[l4d2_banned] 身份是 IP 串(%s)：按 IP 原样入库；进服校验只按 SteamID64 / 老 STEAM 记录匹配，IP 记录不会拦人。", auth);
	}
	else if (!IsSteamID64Auth(auth))
	{
		/* 老格式(STEAM_X:Y:Z / [U:1:x])先换算成 SteamID64 入库，新数据就都是 64 位了；
		 * 换算不了的自定义身份保持原样。 */
		char s64[MAX_LENGTH];
		if (AuthStringToSteam64(auth, s64, sizeof(s64)))
		{
			PrintToServer("[l4d2_banned] 封禁身份 %s 已换算成 SteamID64: %s", auth, s64);
			strcopy(sAlso, sizeof(sAlso), auth);
			strcopy(sAuth, sizeof(sAuth), s64);
		}
		else
		{
			PrintToServer("[l4d2_banned] 身份不是 17 位 SteamID64(%s)：按原串入库，玩家进服时靠回退查询仍能命中。", auth);
		}
	}

	/* v2.8.1：把发起命令的管理员槽位带进异步回调 —— 写库结果要回显给他本人。
	 * source 是 BanIdentity()/BanClient() 的最后一个参数（basebans 传的就是命令行执行者）。 */
	int iNotify = view_as<int>(source);
	if (iNotify < 0 || iNotify > MaxClients)
		iNotify = 0;

	SQL_Load(time, sAuth, reason[0] == '\0' ? "无" : reason, true, sAlso, iNotify);//读取玩家数据.
	return Plugin_Handled;//阻止写入封禁信息.
}
//监听解封函数.
public Action OnRemoveBan(const char[] auth, int flags, const char[] command, any source)
{
	/* 断线期间解封：把还没上传的暂存记录也删掉，避免重连后又把人封回去。 */
	if (g_hPendingBans != null && g_hPendingBans.Remove(auth))
	{
		SavePendingBans();
		PrintToServer("[l4d2_banned] 已从离线待上传列表中移除: %s", auth);
	}

	/* 老的暂存文件里可能是 STEAM_X:Y:Z 键：换算后一起清。 */
	char sAlso[MAX_LENGTH];
	sAlso[0] = '\0';
	if (!IsSteamID64Auth(auth))
	{
		char s64[MAX_LENGTH];
		if (AuthStringToSteam64(auth, s64, sizeof(s64)))
			strcopy(sAlso, sizeof(sAlso), s64);
	}

	if (sAlso[0] != '\0' && g_hPendingBans != null && g_hPendingBans.Remove(sAlso))
	{
		SavePendingBans();
		PrintToServer("[l4d2_banned] 已从离线待上传列表中移除(换算后): %s", sAlso);
	}

	int iNotify = view_as<int>(source);
	if (iNotify < 0 || iNotify > MaxClients)
		iNotify = 0;

	SQL_Delete(auth, sAlso, iNotify);//删除指定的记录(64 位与老主键一起删).
	return Plugin_Continue;//允许删除封禁信息.
}