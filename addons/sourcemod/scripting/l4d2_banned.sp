
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
 */
#pragma semicolon 1
//強制1.7以後的新語法
#pragma newdecls required
#pragma dynamic 40960	//增加堆栈空间.
#include <sourcemod>
#undef REQUIRE_PLUGIN	//adminmenu 设为可选：没加载时只是少一个「封禁列表」菜单入口，插件照常工作
#include <adminmenu>
#define REQUIRE_PLUGIN

#define PLUGIN_VERSION	"2.7.5"	//插件的版本.
#define MAX_LENGTH		128		//字符串最大值.

Database g_dbSQL;

bool g_bLateLoad;
bool g_bDatabaseType = false;//设置创建配置文件默认使用的数据库类型,false=Sqlite,true=MySQL.
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

		SQL_Load(StringToInt(sParts[0]), sKey, sParts[2], true);
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

	SQL_FastQuery(db, "CREATE TABLE IF NOT EXISTS `l4d2_banned`  (\
								`SteamID` varchar(32) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL,\
								`banreason` varchar(32) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL,\
								`bantime` int NOT NULL,\
								`timestamp` int NOT NULL,\
								PRIMARY KEY (`SteamID`) USING BTREE\
								) ENGINE = InnoDB CHARACTER SET = utf8mb4 COLLATE = utf8mb4_general_ci ROW_FORMAT = DYNAMIC;");

	if (!SQL_SetCharset(db, "utf8mb4"))
	{
		SQL_GetError(db, error, maxlength);
		db.Close();
		return null;
	}

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
			if (GetClientAuthId(i, AuthId_Steam2, auth, sizeof(auth))) 
				SQL_Load(0, auth, "", false);//读取玩家数据.
			else
				KickClient(i, "你已被踢出.\n踢出原因:ID获取失败.\n你的ID为:%s.", auth);
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
	if (!IsFakeClient(client))
	{
		char sAuth[MAX_LENGTH];
		g_eBanned[client].g_bBanStatus = false;
		if (GetClientAuthId(client, AuthId_Steam2, sAuth, sizeof(sAuth)))
		{
			if (IsPendingBanned(sAuth))
			{
				KickClient(client, "你已被封禁.\n踢出原因:封禁记录正在同步.");
				return;
			}

			SQL_Load(0, auth, "", false);//读取玩家数据.
		}
		else
			KickClient(client, "你已被踢出.\n踢出原因:ID获取失败.\n你的ID为:%s.", auth);//执行踢出玩家并显示原因.
	}
}
//读取玩家数据.
stock void SQL_Load(int time, const char[] auth, const char[] reason, bool write) 
{
	if (!g_dbSQL)
	{
		/* 数据库断线：封禁先暂存到本地，连上后由 FlushPendingBans() 统一下发。 */
		if (write)
			QueuePendingBan(auth, time, reason);

		return;
	}

	char query[1024];
	FormatEx(query, sizeof query, "SELECT * FROM l4d2_banned WHERE SteamId = '%s';", auth);
	DataPack hPack = new DataPack();
	hPack.WriteCell(time);
	hPack.WriteCell(write);
	hPack.WriteString(auth);
	hPack.WriteString(reason);
	g_dbSQL.Query(SQLQueryCallback, query, hPack);
}
//数据库查询回调.
void SQLQueryCallback(Database db, DBResultSet results, const char[] error, DataPack hPack) 
{
	hPack.Reset();
	int time = hPack.ReadCell();
	bool write = view_as<bool>(hPack.ReadCell());

	char auth[MAX_LENGTH];
	hPack.ReadString(auth, sizeof(auth));
	
	char reason[MAX_LENGTH];
	hPack.ReadString(reason, sizeof(reason));

	if (!db || !results) 
	{
		delete hPack;
		LogError(error);
		return;
	}

	int iNowTime = GetTime();

	if (results.FetchRow())
	{	
		char sBanReason[MAX_LENGTH];
		results.FetchString(1, sBanReason, sizeof(sBanReason));
		int iBanTime = results.FetchInt(2);
		int iTimeStamp = results.FetchInt(3);

		if(iBanTime <= 0)
		{
			KickEntity(auth, "你已被封禁.\n封禁时长:永久封禁.\n封禁时间:%s.\n封禁原因:%s", GetDateTime(iTimeStamp), sBanReason);
		}
		else
		{
			if(iBanTime * 60 + iTimeStamp > iNowTime)
			{
				int iSurplus = iBanTime * 60 - (iNowTime - iTimeStamp);
				if(write)
				{
					SQL_Save(time + iBanTime, iTimeStamp, auth, reason[0] == '\0' ? "未填写封禁原因" : reason);//如果已存在数据就更新.
					//PrintToChatAll("\x04[提示]\x05剩余时长(%s),解封时间(%s).", StandardizeTime((time + iBanTime) * 60 - (iNowTime - iTimeStamp)), GetDateTime((time + iBanTime) * 60 + iTimeStamp));
				}
				else
				{
					KickEntity(auth, "你已被封禁.\n剩余时长:%s.\n封禁时长:%s.\n封禁时间:%s.\n解封时间:%s.\n封禁原因:%s", 
					StandardizeTime(iSurplus), StandardizeTime(iBanTime * 60), 
					GetDateTime(iTimeStamp), GetDateTime(iTimeStamp + iBanTime * 60), sBanReason);
				}
			}
			else
			{
				if(write)
					SQL_Save(time, iNowTime, auth, reason[0] == '\0' ? "未填写封禁原因" : reason);//如果已存在数据就更新.
				else
				{
					SQL_Delete(auth);//删除指定的玩家数据.
					int client = GetClientAuthIndex(auth);
	
					if(client != 0)
					{
						g_eBanned[client].g_bBanStatus = true;
						strcopy(g_eBanned[client].sBanTime, sizeof(esBanned::sBanTime), GetDateTime(iTimeStamp));
						strcopy(g_eBanned[client].sBanReason, sizeof(esBanned::sBanReason), sBanReason);
						strcopy(g_eBanned[client].sUnBanTime, sizeof(esBanned::sUnBanTime), GetDateTime(iTimeStamp + iBanTime * 60));
						strcopy(g_eBanned[client].sBanDuration, sizeof(esBanned::sBanDuration), StandardizeTime(iBanTime * 60));
					}
				}
			}
		}
	}
	else 
	{
		if(write)
		{
			char query[1024];
			FormatEx(query, sizeof query, "INSERT INTO l4d2_banned(SteamID, banreason, bantime, timestamp) VALUES ('%s', '%s', %d, %d);", auth, reason[0] == '\0' ? "未填写封禁原因" : reason, time, iNowTime);
			SQL_FastQuery(g_dbSQL, query);

			if(time <= 0)
				KickEntity(auth, "你已被封禁.\n封禁时长:永久封禁.\n封禁时间:%s.\n封禁原因:%s", 
				GetDateTime(iNowTime), reason[0] == '\0' ? "未填写封禁原因" : reason);
			else
				KickEntity(auth, "你已被封禁.\n封禁时长:%s.\n封禁时间:%s.\n解封时间:%s.\n封禁原因:%s", 
				StandardizeTime(time * 60), GetDateTime(iNowTime), GetDateTime(time * 60 + iNowTime), reason[0] == '\0' ? "未填写封禁原因" : reason);
		}
	}
	delete hPack;
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
//获取Auth对应的玩家索引.
stock int GetClientAuthIndex(const char[] auth) 
{
	for (int i = 1; i <= MaxClients; i++) 
	{
		if (IsClientConnected(i) && !IsFakeClient(i))
		{	
			char Auth[MAX_LENGTH];
			if (GetClientAuthId(i, AuthId_Steam2, Auth, sizeof(Auth)))
				if(strcmp(auth, Auth) == 0)//对比字符串.
					return i;
		}
	}
	return 0;
}
//删除指定的玩家数据.
stock void SQL_Delete(const char[] auth) 
{
	if (g_dbSQL == null)
	{
		/* 断线期间 sm_unban 不能静默吞掉：明确告诉管理员这次没删库。 */
		PrintToServer("[l4d2_banned] 数据库未连接，无法删除库记录: %s（本地封禁仍会移除）", auth);
		return;
	}

	char query[1024];
	FormatEx(query, sizeof query, "DELETE FROM l4d2_banned WHERE SteamID = '%s';", auth);
	DataPack hPack = new DataPack();
	hPack.WriteString(auth);
	g_dbSQL.Query(SQL_CallbackDelOld, query, hPack);
}
//删除数据回调.
void SQL_CallbackDelOld(Database db, DBResultSet results, const char[] error, any data) 
{
	char auth[128];
	DataPack hPack = view_as<DataPack>(data);
	if (hPack != null)
	{
		hPack.Reset();
		hPack.ReadString(auth, sizeof(auth));
		delete hPack;
	}

	if (!db || !results) 
	{
		PrintToServer("[l4d2_banned] 删除库记录失败: %s（%s）", auth, error);
		LogError("[l4d2_banned] 删除库记录失败: %s（%s）", auth, error);
		return;
	}

	/* AffectedRows == 0 是"库里本来就没这条"，也要说清楚，避免误以为删成功。 */
	PrintToServer("[l4d2_banned] 已删除库记录: %s（影响 %d 行）", auth, results.AffectedRows);
}
//更新玩家数据.
stock void SQL_Save(int time, int iNowTime, char[] auth, char[] reason) 
{
	if (!g_dbSQL)
		return;

	char query[1024];
	FormatEx(query, sizeof query, "UPDATE l4d2_banned SET banreason = '%s', bantime = %d, timestamp = %d WHERE SteamID = '%s';", reason[0] == '\0' ? "无" : reason, time, iNowTime, auth);
	SQL_FastQuery(g_dbSQL, query);

	if(time == 0)
		KickEntity(auth, "你已被封禁.\n封禁时长:永久封禁.\n封禁时间:%s.\n封禁原因:%s.", GetDateTime(iNowTime), reason[0] == '\0' ? "无" : reason);
	else
		KickEntity(auth, "你已被封禁.\n额外时长:%s.\n封禁时间:%s.\n解封时间:%s.\n封禁原因:%s.", StandardizeTime(time * 60), GetDateTime(time * 60 + iNowTime), reason[0] == '\0' ? "无" : reason);
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
//删除指定的密钥数据.
stock void SQL_DeleteBanData(int client, const char[] sSteamID) 
{
	char query[1024];
	FormatEx(query, sizeof query, "DELETE FROM l4d2_banned WHERE SteamID = '%s';", sSteamID);
	g_dbSQL.Query(SQL_CallbackBanData, query, GetClientUserId(client));
}
//删除数据回调.
void SQL_CallbackBanData(Database db, DBResultSet results, const char[] error, any client) 
{
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
			if (GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth)))
				QueuePendingBan(auth, time, reason[0] == '\0' ? "无" : reason);

			return Plugin_Handled;
		}

		return Plugin_Continue;
	}

	if(flags & BANFLAG_NOKICK)//封禁玩家函数添加了禁用踢出玩家功能时使用此插件的数据库方式记录封禁信息.
	{
		char auth[128];
		if (GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth)))
			SQL_Load(time, auth, reason[0] == '\0' ? "无" : reason, true);//读取玩家数据.
		else
			KickClient(client, "你已被踢出.\n踢出原因:ID获取失败.你的ID为:%s.", auth);
		//PrintToChat(client, "\x04[提示]\x05有禁用踢出功能%d|%d.", flags, BANFLAG_NOKICK);
		return Plugin_Handled;//阻止写入封禁信息.
	}
	//PrintToChat(client, "\x04[提示]\x05无禁用踢出功能%d|%d.", flags, BANFLAG_NOKICK);
	return Plugin_Continue;//允许写入封禁信息.
}
//监听封禁函数.
public Action OnBanIdentity(const char[] auth, int time, int flags, const char[] reason, const char[] command, any source)
{
	if (!StrEqual(auth, "STEAM_ID_STOP_IGNORING_RETVALS", false))
		SQL_Load(time, auth, reason[0] == '\0' ? "无" : reason, true);//读取玩家数据.
	else
		KickEntity(auth, "你已被踢出.\n踢出原因:ID获取失败.你的ID为:%s.", auth);//执行踢出玩家并显示原因.
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

	SQL_Delete(auth);//删除指定的记录.
	return Plugin_Continue;//允许删除封禁信息.
}