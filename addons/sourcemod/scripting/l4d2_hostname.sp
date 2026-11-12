/*
 *	v1.3.3
 *
 *	1:修正引擎直读报错/崩坏: SDKCall_Raw会先把第1个参数解引用当this指针(普通C函数必须用SDKCall_Static),
 *	  参数改用SDKType_String+SDKPass_Pointer(会传插件缓冲区的真实指针), 缓冲给24字节.
 *	2:引擎直读改到定时器里执行: 万一调用失败/抛错只影响该回调, 不再打断OnPluginStart/OnConfigsExecuted(之前会导致服名完全不生效).
 *	3:服名配置按"IP:端口"分服(configs/hostname/l4d2_hostname.txt), 旧版单行文本会自动迁移成default键.
 *	4:IP识别顺序: 手动指定 -> 引擎签名直读NET_GetPublicAdr(默认开启) -> net_public_adr
 *	                -> status(备选) -> ip/hostip绑定地址兜底 -> 0.0.0.0.
 *	5:l4d2_hostname_ip 手动指定IP; l4d2_hostname_engine 引擎签名直读开关(默认1).
 *	6:服务器控制台(客户端为0)也能用!host, 提示里会显示当前配置键.
 *
 */
#pragma semicolon 1
//強制1.7以後的新語法
#pragma newdecls required
#include <sourcemod>
#include <sdktools>
#undef REQUIRE_PLUGIN
#include <confogl>

#define PLUGIN_VERSION	"1.3.3"
#define MAX_SIZEOF		128	//服名字符串大小.
#define DEFAULT_NAME	"猜猜这个是谁的萌新服?"	//默认服名.
#define KV_ROOT			"hostname"	//配置文件根节点.
#define DEFAULT_KEY		"default"	//默认配置键.
#define WILDCARD_IP		"*"	//通配IP,给同一端口的所有服务器设置同一个服名.
#define UNSET_IP		"0.0.0.0"	//识别不到IP时使用的值.
#define STATUS_SIZE		2048	//status输出的缓冲区大小.
#define DETECT_TRIES	6	//识别IP的最多尝试次数.
#define DETECT_INTERVAL	3.0	//识别IP的重试间隔(秒).

ConVar g_hHostName, g_hCfgName, g_hHostPort, g_hHostIP, g_hHostIpInt, g_hHostPublicAdr, g_hKeyIP, g_hEngineMode;
Handle g_hGetPublicAdr;				//引擎直读公网地址的SDKCall.
char g_sPath[PLATFORM_MAX_PATH];
char g_sBaseName[MAX_SIZEOF];		//配置文件里属于当前服务器的服名.
char g_sServerKey[MAX_SIZEOF];		//当前服务器的配置键(IP:端口).
char g_sLocalKey[MAX_SIZEOF];		//status里本地绑定地址的配置键(IP:端口).
char g_sWildcardKey[MAX_SIZEOF];	//通配配置键(*:端口).
char g_sStatusIP[64];				//status里的公网地址.
char g_sStatusPort[16];				//status里的端口.
char g_sLocalIP[64];				//status里的本地绑定地址.
char g_sEngineIP[64];				//引擎签名直读到的公网地址.
char g_sEnginePort[16];				//引擎签名直读到的端口.
bool g_bEngineReadScheduled;		//是否已经安排过引擎直读定时器.
bool g_bEngineReadOk;				//引擎直读是否已经成功过.
bool g_bEngineAdrFailed;			//签名/数据准备是否已经失败过(失败过就不再每图重试).
bool g_bIPDetected;					//status是否已经给出可用IP.
bool g_bDetectRunning;				//识别定时器是否在运行.
int g_iDetectTries;					//已经尝试识别的次数.

public Plugin myinfo = 
{
	name 			= "l4d2_hostname",
	author 			= "apples1949",
	description 	= "管理员!host重载服名或设置新服名; 配置文件按IP:端口分服; 服名后缀跟随当前配置 (applemod→进阶包抗, zonemod→zonemod, nextmod→nextmod)",
	version 		= PLUGIN_VERSION,
	url 			= "N/A"
}

public void OnPluginStart()
{
	RegConsoleCmd("sm_host", Addhostname, "重载服名或设置新服名");
	g_hHostName = FindConVar("hostname");
	g_hHostPort = FindConVar("hostport");
	g_hHostIP = FindConVar("ip");
	g_hHostIpInt = FindConVar("hostip");
	g_hHostPublicAdr = FindConVar("net_public_adr");

	if(g_hHostName == null)
	{
		SetFailState("找不到hostname指令,插件无法运行.");
		return;
	}

	//手动指定识别服务器用的IP,应急用.
	g_hKeyIP = CreateConVar("l4d2_hostname_ip", "", "手动指定识别服务器用的IP,留空则自动识别(签名优先,status兜底)", FCVAR_NONE);
	g_hKeyIP.AddChangeHook(KeyIPChanged);

	//引擎签名直读开关: 默认开启,拿不到再走status.
	g_hEngineMode = CreateConVar("l4d2_hostname_engine", "1", "1=优先用引擎函数NET_GetPublicAdr取公网地址(默认),0=不读(直接走status)", FCVAR_NONE);
	g_hEngineMode.AddChangeHook(EngineModeChanged);

	if(g_hEngineMode.IntValue != 0)
		LoadEngineAdr();

	FindCfgNameConVar();
	LoadServerName();//读取当前服务器的服名.
	CreateTimer(5.0, Timer_RefreshServerName, _, TIMER_REPEAT);//定时核对服名(配置切换兜底).
	StartEngineReadTimer();//签名直读放到定时器里,失败也不会打断插件启动.
	StartDetectTimer();//签名和变量里都拿不到IP时用status收集.
}

public void OnAllPluginsLoaded()
{
	FindCfgNameConVar();
}

public void OnLibraryAdded(const char[] name)
{
	if(StrEqual(name, "readyup") || StrEqual(name, "confogl"))
	{
		FindCfgNameConVar();
		SetServerName();//readyup/confogl加载后重新挂接并设置服名.
	}
}

public void OnLibraryRemoved(const char[] name)
{
	if(StrEqual(name, "readyup"))
		g_hCfgName = null;//配置名称ConVar随readyup卸载而失效.
	if(StrEqual(name, "confogl"))
		SetServerName();//confogl卸载后回退到变量值重新计算服名.
}

public void OnConfigsExecuted()
{
	if(g_hEngineMode != null && g_hEngineMode.IntValue != 0)
		LoadEngineAdr();

	if(!g_bEngineReadOk)//签名还没成功就再安排一次(服务器刚起时Steam可能还没给公网地址).
		g_bEngineReadScheduled = false;

	LoadServerName();//获取当前服务器在文件里的服名.
	StartEngineReadTimer();
	StartDetectTimer();//还没识别到IP时继续用status收集.
}

//手动指定IP的变量改变后重新识别.
public void KeyIPChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	LoadServerName();
}

//引擎直读开关改变后重新准备SDKCall并重读服名.
public void EngineModeChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if(g_hEngineMode.IntValue != 0)
	{
		g_bEngineAdrFailed = false;//重新打开就再试一次.
		g_bEngineReadOk = false;
		g_bEngineReadScheduled = false;
		LoadEngineAdr();
		StartEngineReadTimer();
	}

	LoadServerName();
}

public Action Addhostname(int client, int args)
{
	if(!IsCheckClientAccess(client))
	{
		ReplyToClient(client, "只限管理员使用该指令.");
		return Plugin_Handled;
	}

	if(args == 0)
	{
		LoadServerName();//重新读取文件里的服名.

		if(HasDetectedIP())
			ReplyToClient(client, "已重新加载配置文件,当前配置键(%s).", g_sServerKey);
		else
			ReplyToClient(client, "已重新加载配置文件,当前配置键(%s),还没识别到IP(签名和变量里没有,status仍在重试).", g_sServerKey);
	}
	else
	{
		char arg[MAX_SIZEOF];
		GetCmdArgString(arg, sizeof(arg));
		StripQuotes(arg);//带引号输入时去掉引号.
		TrimString(arg);

		if(arg[0] == '\0')
		{
			ReplyToClient(client, "服名不能为空,用法: !host 新服名.");
			return Plugin_Handled;
		}

		strcopy(g_sBaseName, sizeof(g_sBaseName), arg);
		SaveServerName(arg, g_sServerKey);//写进当前服务器的配置键.
		ReplyToClient(client, "已设置配置键(%s)的服名为(%s).", g_sServerKey, arg);
	}
	return Plugin_Handled;
}

//读取当前服务器的服名:按"IP:端口"->本地IP:端口->*:端口->default的顺序查找.
void LoadServerName()
{
	char sName[MAX_SIZEOF];
	char sSource[MAX_SIZEOF];
	bool bFound = false;

	BuildServerKey();
	BuildPath(Path_SM, g_sPath, sizeof(g_sPath), "configs/hostname/l4d2_hostname.txt");

	if(!FileExists(g_sPath))//没有配置文件:创建默认内容.
	{
		strcopy(g_sBaseName, sizeof(g_sBaseName), DEFAULT_NAME);
		SaveServerName(DEFAULT_NAME, DEFAULT_KEY);
		return;
	}

	KeyValues kv = new KeyValues(KV_ROOT);

	if(!kv.ImportFromFile(g_sPath))
	{
		delete kv;

		if(FileHasBrace(g_sPath))//看着是新格式却解析失败:不覆盖用户文件,先用默认服名.
		{
			LogError("配置文件(%s)解析失败,请检查格式,服名先用默认值.", g_sPath);
			strcopy(g_sBaseName, sizeof(g_sBaseName), DEFAULT_NAME);
			SetServerName();
			return;
		}

		if(!ReadLegacyName(sName, sizeof(sName)))//旧版是一行纯文本,迁移成按IP:端口分服的格式.
			strcopy(sName, sizeof(sName), DEFAULT_NAME);

		strcopy(g_sBaseName, sizeof(g_sBaseName), sName);
		LogMessage("旧版配置文件已迁移成按IP:端口分服的格式,服名(%s)写到default键.", sName);
		SaveServerName(sName, DEFAULT_KEY);
		return;
	}

	sSource[0] = '\0';

	if(kv.JumpToKey(g_sServerKey, false))//1:当前服务器的键(IP:端口).
	{
		strcopy(sSource, sizeof(sSource), g_sServerKey);
		bFound = true;
	}
	else if(g_sLocalKey[0] != '\0' && kv.JumpToKey(g_sLocalKey, false))//2:本地绑定地址的键(IP:端口).
	{
		strcopy(sSource, sizeof(sSource), g_sLocalKey);
		bFound = true;
	}
	else if(g_sWildcardKey[0] != '\0' && kv.JumpToKey(g_sWildcardKey, false))//3:同一端口的通配键(*:端口).
	{
		strcopy(sSource, sizeof(sSource), g_sWildcardKey);
		bFound = true;
	}
	else if(kv.JumpToKey(DEFAULT_KEY, false))//4:默认键.
	{
		strcopy(sSource, sizeof(sSource), DEFAULT_KEY);
		bFound = true;
	}

	if(bFound)
		kv.GetString("ServerName", g_sBaseName, sizeof(g_sBaseName), DEFAULT_NAME);

	delete kv;

	if(!bFound || g_sBaseName[0] == '\0')//文件里没有对应键:补一个default键.
	{
		strcopy(g_sBaseName, sizeof(g_sBaseName), DEFAULT_NAME);
		SaveServerName(DEFAULT_NAME, DEFAULT_KEY);
		return;
	}

	LogMessage("当前配置键(%s),服名来源(%s),基础服名(%s).", g_sServerKey, sSource, g_sBaseName);
	SetServerName();
}

//读旧版单行文本配置(取最后一个非空行).
bool ReadLegacyName(char[] sName, int maxlen)
{
	File file = OpenFile(g_sPath, "r");

	if(!file)
		return false;

	char sLine[MAX_SIZEOF];
	bool bRead = false;

	while(!file.EndOfFile())
	{
		if(!file.ReadLine(sLine, sizeof(sLine)))
			break;

		TrimString(sLine);

		if(sLine[0] != '\0')
		{
			strcopy(sName, maxlen, sLine);
			bRead = true;
		}
	}

	delete file;
	return bRead;
}

//判断文件里有没有大括号(有就是新的配置格式,不是旧版纯文本).
bool FileHasBrace(const char[] sFile)
{
	File file = OpenFile(sFile, "r");

	if(!file)
		return false;

	char sLine[MAX_SIZEOF];
	bool bFound = false;

	while(!file.EndOfFile())
	{
		if(!file.ReadLine(sLine, sizeof(sLine)))
			break;

		if(StrContains(sLine, "{") != -1 || StrContains(sLine, "}") != -1)
		{
			bFound = true;
			break;
		}
	}

	delete file;
	return bFound;
}

//把服名写进配置文件:sKey为空时写到default键.
void SaveServerName(const char[] sName, const char[] sKey)
{
	char sSection[MAX_SIZEOF];
	KeyValues kv = new KeyValues(KV_ROOT);

	if(FileExists(g_sPath) && !kv.ImportFromFile(g_sPath))
	{
		if(FileHasBrace(g_sPath))//新格式却解析失败:不覆盖用户文件.
		{
			LogError("配置文件(%s)解析失败,请检查格式,本次没有写入.", g_sPath);
			delete kv;
			return;
		}

		//旧版文本文件:按空配置重建(服名已由ReadLegacyName取走).
		delete kv;
		kv = new KeyValues(KV_ROOT);
	}

	if(sKey[0] != '\0')
		strcopy(sSection, sizeof(sSection), sKey);
	else
		strcopy(sSection, sizeof(sSection), DEFAULT_KEY);

	if(!kv.JumpToKey(sSection, true))//没有这个键就创建.
	{
		LogError("无法在配置文件里创建(%s)键.", sSection);
		delete kv;
		return;
	}

	kv.SetString("ServerName", sName);
	kv.Rewind();//返回上一层.

	if(!kv.ExportToFile(g_sPath))//把数据写入到文件.
	{
		LogError("写入配置文件(%s)失败.", g_sPath);
		delete kv;
		return;
	}

	delete kv;

	LogMessage("已把配置键(%s)的服名写成(%s).", sSection, sName);
	SetServerName();
}

//生成配置键:主键(IP:端口)、本地键、通配键.
void BuildServerKey()
{
	char sIP[64];
	char sPort[16];

	GetKeyPort(sPort, sizeof(sPort));
	GetKeyIP(sIP, sizeof(sIP));

	FormatEndPoint(sIP, sPort, g_sServerKey, sizeof(g_sServerKey));

	if(IsValidIP(g_sLocalIP) && !StrEqual(g_sLocalIP, sIP))//status里的本地绑定地址当备用键.
		FormatEndPoint(g_sLocalIP, sPort, g_sLocalKey, sizeof(g_sLocalKey));
	else
		g_sLocalKey[0] = '\0';

	if(sPort[0] != '\0')
		FormatEx(g_sWildcardKey, sizeof(g_sWildcardKey), "%s:%s", WILDCARD_IP, sPort);
	else
		strcopy(g_sWildcardKey, sizeof(g_sWildcardKey), WILDCARD_IP);
}

//准备引擎直读的SDKCall(签名在 gamedata/l4d2_hostname.txt).
void LoadEngineAdr()
{
	if(g_hGetPublicAdr != null || g_bEngineAdrFailed)
		return;

	if(g_hEngineMode == null || g_hEngineMode.IntValue == 0)
		return;

	GameData gd = new GameData("l4d2_hostname");

	if(gd == null)
	{
		g_bEngineAdrFailed = true;
		LogError("找不到 gamedata/l4d2_hostname.txt,引擎直读不可用,改用status.");
		return;
	}

	Address addr = gd.GetAddress("NET_GetPublicAdr");
	delete gd;

	if(addr == Address_Null)
	{
		g_bEngineAdrFailed = true;
		LogError("NET_GetPublicAdr签名没有命中(不是Linux服或游戏已更新),引擎直读不可用,改用status.");
		return;
	}

	StartPrepSDKCall(SDKCall_Static);//NET_GetPublicAdr是普通C函数,没有this指针(SDKCall_Raw会把第1个参数当this).
	PrepSDKCall_SetAddress(addr);
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);//String+Pointer会把插件缓冲区的真实指针传给引擎.
	g_hGetPublicAdr = EndPrepSDKCall();

	if(g_hGetPublicAdr == null)
	{
		g_bEngineAdrFailed = true;
		LogError("NET_GetPublicAdr的SDKCall创建失败,改用status.");
	}
	else
		LogMessage("引擎直读已启用:NET_GetPublicAdr(%x).", addr);
}

//安排一次引擎直读:放到定时器里执行,万一SDKCall抛异常也只死这一个回调,不会打断OnPluginStart/OnConfigsExecuted.
void StartEngineReadTimer()
{
	if(g_hGetPublicAdr == null || g_bEngineReadOk || g_bEngineReadScheduled)
		return;

	if(g_hEngineMode == null || g_hEngineMode.IntValue == 0)
		return;

	g_bEngineReadScheduled = true;
	CreateTimer(2.0, Timer_ReadEngineAdr, _, TIMER_FLAG_NO_MAPCHANGE);
}

//引擎直读回调:拿到地址就按新的配置键重读服名.
public Action Timer_ReadEngineAdr(Handle timer)
{
	char sIP[64];
	char sPort[16];
	char sOldKey[MAX_SIZEOF];

	g_bEngineReadScheduled = false;

	if(!ReadEngineAdr(sIP, sizeof(sIP), sPort, sizeof(sPort)))//这次没拿到(比如服务器刚起,Steam还没给公网地址).
	{
		g_bEngineReadScheduled = true;//下一个换图后再试.
		return Plugin_Stop;
	}

	g_bEngineReadOk = true;

	if(!StrEqual(g_sEngineIP, sIP) || !StrEqual(g_sEnginePort, sPort))
	{
		strcopy(g_sEngineIP, sizeof(g_sEngineIP), sIP);
		strcopy(g_sEnginePort, sizeof(g_sEnginePort), sPort);
	}

	strcopy(sOldKey, sizeof(sOldKey), g_sServerKey);
	BuildServerKey();

	if(!StrEqual(sOldKey, g_sServerKey))
	{
		LogMessage("配置键从(%s)变成(%s),重新读取服名.", sOldKey, g_sServerKey);
		LoadServerName();
	}

	return Plugin_Stop;
}

//调用引擎函数取公网地址: 缓冲24字节,IP在+4..+7(点分顺序),端口在+8..+9(大端).
bool ReadEngineAdr(char[] sIP, int iIPMax, char[] sPort, int iPortMax)
{
	char sBuf[24];//netadr_t是12字节,Steam分支会写到+0x10,所以给24字节.
	int iPort;

	sIP[0] = '\0';
	sPort[0] = '\0';

	if(g_hGetPublicAdr == null)
		return false;

	for(int i = 0; i < sizeof(sBuf); i++)//调用前先清空,status那边也是这样初始化netadr_s的.
		sBuf[i] = 0;

	sBuf[0] = 3;//NA_IP.

	if(!SDKCall(g_hGetPublicAdr, sBuf))//返回false: 没连上Steam/不是专用服务器/net_public_adr也没设.
		return false;

	if(sBuf[0] != 3)//NA_IP.
		return false;

	FormatEx(sIP, iIPMax, "%d.%d.%d.%d", sBuf[4] & 0xFF, sBuf[5] & 0xFF, sBuf[6] & 0xFF, sBuf[7] & 0xFF);

	if(!IsValidIP(sIP))
	{
		sIP[0] = '\0';
		return false;
	}

	iPort = ((sBuf[8] & 0xFF) << 8) | (sBuf[9] & 0xFF);//大端端口.

	if(iPort > 0)
		FormatEx(sPort, iPortMax, "%d", iPort);

	static char sLastLog[80];
	char sNow[80];

	FormatEx(sNow, sizeof(sNow), "%s:%s", sIP, sPort);

	if(!StrEqual(sLastLog, sNow))//只在变化时记一条,方便进服确认.
	{
		strcopy(sLastLog, sizeof(sLastLog), sNow);
		LogMessage("引擎直读到公网地址(%s).", sNow);
	}

	return true;
}

//取识别服务器用的IP:首选项(手动/签名/net_public_adr)->status(备选)->绑定地址->0.0.0.0.
void GetKeyIP(char[] sIP, int maxlen)
{
	GetDirectIP(sIP, maxlen);

	if(IsValidIP(sIP))
		return;

	if(IsValidIP(g_sStatusIP))//status里的公网地址.
	{
		strcopy(sIP, maxlen, g_sStatusIP);
		return;
	}

	if(IsValidIP(g_sLocalIP))//status里的本地绑定地址.
	{
		strcopy(sIP, maxlen, g_sLocalIP);
		return;
	}

	GetBindIP(sIP, maxlen);//最后才用绑定地址兜底.

	if(IsValidIP(sIP))
		return;

	strcopy(sIP, maxlen, UNSET_IP);
}

//首选项取IP(不执行status):手动指定->引擎签名直读->net_public_adr.
void GetDirectIP(char[] sIP, int maxlen)
{
	char sValue[64];
	char sPort[16];

	sIP[0] = '\0';

	if(g_hKeyIP != null)//1:管理员手动指定.
	{
		g_hKeyIP.GetString(sValue, sizeof(sValue));
		TrimString(sValue);

		if(IsValidIP(sValue))
		{
			strcopy(sIP, maxlen, sValue);
			return;
		}
	}

	//引擎地址由定时器(Timer_ReadEngineAdr)读好后缓存,这里只取缓存,避免在回调里直接调引擎.
	if(IsValidIP(g_sEngineIP))//2:引擎签名直读的公网地址(status里public段的来源).
	{
		strcopy(sIP, maxlen, g_sEngineIP);
		return;
	}

	if(g_hHostPublicAdr != null)//3:管理员声明的公网地址(可能写成"IP:端口").
	{
		g_hHostPublicAdr.GetString(sValue, sizeof(sValue));
		TrimString(sValue);

		if(SplitEndPoint(sValue, sIP, maxlen, sPort, sizeof(sPort)) && IsValidIP(sIP))
			return;

		sIP[0] = '\0';
	}
}

//绑定地址兜底:ip(启动参数)->hostip(引擎实际绑定).
void GetBindIP(char[] sIP, int maxlen)
{
	char sValue[64];

	sIP[0] = '\0';

	if(g_hHostIP != null)
	{
		g_hHostIP.GetString(sValue, sizeof(sValue));
		TrimString(sValue);

		if(IsValidIP(sValue))
		{
			strcopy(sIP, maxlen, sValue);
			return;
		}
	}

	if(g_hHostIpInt != null)
	{
		int iIP = g_hHostIpInt.IntValue;

		//0/-1是没绑定,-1062731518(192.168.0.2)是hostip的引擎占位默认值,这几种都不要用.
		if(iIP != 0 && iIP != -1 && iIP != -1062731518)
		{
			FormatEx(sIP, maxlen, "%d.%d.%d.%d", (iIP >> 24) & 0xFF, (iIP >> 16) & 0xFF, (iIP >> 8) & 0xFF, iIP & 0xFF);

			if(IsValidIP(sIP))
				return;
		}
	}

	sIP[0] = '\0';
}

//当前是否已经拿到真实IP(签名/变量里的或status里的).
bool HasDetectedIP()
{
	char sIP[64];

	GetKeyIP(sIP, sizeof(sIP));
	return IsValidIP(sIP);
}

//取端口:先用hostport,没有再用引擎直读的,最后用status里的.
void GetKeyPort(char[] sPort, int maxlen)
{
	GetServerPort(sPort, maxlen);

	if(sPort[0] == '\0' && g_sEnginePort[0] != '\0')
		strcopy(sPort, maxlen, g_sEnginePort);

	if(sPort[0] == '\0' && g_sStatusPort[0] != '\0')
		strcopy(sPort, maxlen, g_sStatusPort);
}

//取hostport变量里的端口,拿不到就留空.
void GetServerPort(char[] sPort, int maxlen)
{
	char sValue[16];

	sPort[0] = '\0';

	if(g_hHostPort == null)
		return;

	g_hHostPort.GetString(sValue, sizeof(sValue));
	TrimString(sValue);

	if(sValue[0] == '\0')
		return;

	if(!IsNumericChar(sValue))//正常情况下端口一定是数字.
	{
		LogError("hostport(%s)不是有效的端口号.", sValue);
		return;
	}

	strcopy(sPort, maxlen, sValue);
}

//首选项拿不到可用IP时,用status收集(备选).
void StartDetectTimer()
{
	char sIP[64];

	if(g_bDetectRunning || g_bIPDetected)
		return;

	GetDirectIP(sIP, sizeof(sIP));

	if(IsValidIP(sIP))//首选项已经有IP,不用去解析status.
		return;

	g_bDetectRunning = true;
	g_iDetectTries = 0;

	CreateTimer(DETECT_INTERVAL, Timer_DetectIP, _, TIMER_REPEAT);
}

public Action Timer_DetectIP(Handle timer)
{
	g_iDetectTries++;

	if(g_iDetectTries <= 2)//前两轮顺便再试一次签名(服务器刚起时Steam可能还没给公网地址).
		StartEngineReadTimer();

	if(DetectServerIP())//识别成功.
	{
		g_bDetectRunning = false;
		return Plugin_Stop;
	}

	if(g_iDetectTries >= DETECT_TRIES)//重试次数用完.
	{
		g_bDetectRunning = false;
		LogError("用status收集IP失败了%d次,配置键先用(%s).", g_iDetectTries, g_sServerKey);
		return Plugin_Stop;
	}

	return Plugin_Continue;
}

//执行status并解析,拿到IP后按新的配置键重新读服名.
bool DetectServerIP()
{
	char sOutput[STATUS_SIZE];
	char sOldKey[MAX_SIZEOF];

	strcopy(sOldKey, sizeof(sOldKey), g_sServerKey);

	ServerCommandEx(sOutput, sizeof(sOutput), "status");//执行status并把输出收进缓冲区.

	if(!ParseStatus(sOutput))
		return false;

	g_bIPDetected = true;

	BuildServerKey();

	if(!StrEqual(sOldKey, g_sServerKey))//配置键变了,按新键重新读一次服名.
	{
		LogMessage("配置键从(%s)变成(%s),重新读取服名.", sOldKey, g_sServerKey);
		LoadServerName();
	}

	return true;
}

//解析status输出里的"udp/ip"行:udp/ip  : 0.0.0.0:24085 [ public 180.188.24.113:24085 ]
bool ParseStatus(const char[] sOutput)
{
	int iPos = StrContains(sOutput, "udp/ip");

	if(iPos == -1)
	{
		LogMessage("status输出里没有udp/ip信息.");
		return false;
	}

	char sLine[256];
	char sToken[64];
	char sLocal[64];
	char sPublic[64];
	char sIP[64];
	char sPort[16];
	bool bFound = false;

	CopyFrom(sOutput, iPos, sLine, sizeof(sLine));//先复制,再截断到行尾.
	CutLine(sLine);

	sLocal[0] = '\0';
	sPublic[0] = '\0';

	if(GetLineToken(sLine, 2, sToken, sizeof(sToken)) && !StrEqual(sToken, "["))//第2个单词是本地绑定地址.
		strcopy(sLocal, sizeof(sLocal), sToken);

	for(int i = 3; i < 8; i++)//往后找"public"后面那个单词.
	{
		if(!GetLineToken(sLine, i, sToken, sizeof(sToken)))
			break;

		if(StrEqual(sToken, "public", false))
		{
			if(GetLineToken(sLine, i + 1, sToken, sizeof(sToken)) && !StrEqual(sToken, "]"))
				strcopy(sPublic, sizeof(sPublic), sToken);

			break;
		}
	}

	LogMessage("status信息:本地(%s),公网(%s).", sLocal, sPublic);

	strcopy(g_sStatusIP, sizeof(g_sStatusIP), "");
	strcopy(g_sLocalIP, sizeof(g_sLocalIP), "");

	if(SplitEndPoint(sLocal, sIP, sizeof(sIP), sPort, sizeof(sPort)))//本地绑定地址.
	{
		strcopy(g_sLocalIP, sizeof(g_sLocalIP), sIP);

		if(g_sStatusPort[0] == '\0' && sPort[0] != '\0')
			strcopy(g_sStatusPort, sizeof(g_sStatusPort), sPort);
	}

	if(SplitEndPoint(sPublic, sIP, sizeof(sIP), sPort, sizeof(sPort)))//公网地址(没有公网时这里是n/a或same).
	{
		strcopy(g_sStatusIP, sizeof(g_sStatusIP), sIP);

		if(sPort[0] != '\0')
			strcopy(g_sStatusPort, sizeof(g_sStatusPort), sPort);

		bFound = true;
	}

	if(!bFound)
		bFound = IsValidIP(g_sLocalIP);

	return bFound;
}

//拼接"IP:端口",IPv6地址用[]包起来.
stock void FormatEndPoint(const char[] sIP, const char[] sPort, char[] sOut, int maxlen)
{
	if(sPort[0] == '\0')
	{
		strcopy(sOut, maxlen, sIP);
		return;
	}

	if(StrContains(sIP, ":") != -1)
		FormatEx(sOut, maxlen, "[%s]:%s", sIP, sPort);
	else
		FormatEx(sOut, maxlen, "%s:%s", sIP, sPort);
}

//把"IP:端口"拆成IP和端口,拆不出来返回false.
stock bool SplitEndPoint(const char[] sText, char[] sIP, int iIPMax, char[] sPort, int iPortMax)
{
	char sValue[64];
	int iPos;

	sIP[0] = '\0';
	sPort[0] = '\0';

	strcopy(sValue, sizeof(sValue), sText);
	TrimString(sValue);
	StripAddressJunk(sValue);//去掉[]和句号之类的多余字符.

	if(sValue[0] == '\0')
		return false;

	iPos = FindCharInString(sValue, ':', true);//从后往前找冒号.

	if(iPos == -1)//没有端口,只当IP用.
	{
		strcopy(sIP, iIPMax, sValue);
		return IsValidIP(sIP);
	}

	if(sValue[iPos + 1] == '\0')
		return false;

	for(int i = iPos + 1; sValue[i] != '\0'; i++)//冒号后面必须是纯数字.
	{
		if(!IsCharNumeric(sValue[i]))
			return false;
	}

	CopyFrom(sValue, iPos + 1, sPort, iPortMax);//先把端口取出来.
	sValue[iPos] = '\0';//到这里sValue只剩IP部分.
	strcopy(sIP, iIPMax, sValue);
	StripAddressJunk(sIP);//去掉IPv6可能带的[].

	return IsValidIP(sIP);
}

//去掉地址两端的多余字符(如status里的[]和句号).
stock void StripAddressJunk(char[] sText)
{
	int iLen = strlen(sText);
	int iStart = 0;

	while(iLen > 0)//去掉末尾的[]句号等.
	{
		char c = sText[iLen - 1];

		if(IsCharAlpha(c) || IsCharNumeric(c) || c == ':')
			break;

		sText[iLen - 1] = '\0';
		iLen--;
	}

	while(sText[iStart] != '\0')//去掉开头的[]等.
	{
		char c = sText[iStart];

		if(IsCharAlpha(c) || IsCharNumeric(c) || c == ':')
			break;

		iStart++;
	}

	if(iStart > 0)
	{
		int i = 0;

		while(sText[iStart + i] != '\0')
		{
			sText[i] = sText[iStart + i];
			i++;
		}

		sText[i] = '\0';
	}
}

//判断能不能用来识别服务器的IP(IPv4或IPv6).
stock bool IsValidIP(const char[] sIP)
{
	if(sIP[0] == '\0')
		return false;

	if(StrEqual(sIP, UNSET_IP) || StrEqual(sIP, "::") || StrEqual(sIP, "0") || StrEqual(sIP, WILDCARD_IP))
		return false;

	if(StrContains(sIP, ":") != -1)//IPv6.
		return true;

	if(StrContains(sIP, ".") == -1)//既没有冒号也没有点,不是IP.
		return false;

	for(int i = 0; sIP[i] != '\0'; i++)
	{
		if(!IsCharNumeric(sIP[i]) && sIP[i] != '.')
			return false;
	}

	return true;
}

//取一行里第iIndex个空格分开的单词(从0算起).
stock bool GetLineToken(const char[] sLine, int iIndex, char[] sToken, int maxlen)
{
	int i = 0;
	int iCount = 0;
	int iLen = 0;

	sToken[0] = '\0';

	while(sLine[i] != '\0')
	{
		while(sLine[i] == ' ' || sLine[i] == '\t')
			i++;

		if(sLine[i] == '\0')
			break;

		if(iCount == iIndex)
		{
			while(sLine[i] != '\0' && sLine[i] != ' ' && sLine[i] != '\t')
			{
				if(iLen < maxlen - 1)
				{
					sToken[iLen] = sLine[i];
					iLen++;
				}

				i++;
			}

			sToken[iLen] = '\0';
			return iLen > 0;
		}

		while(sLine[i] != '\0' && sLine[i] != ' ' && sLine[i] != '\t')
			i++;

		iCount++;
	}

	return false;
}

//从字符串指定位置开始复制到缓冲区.
stock void CopyFrom(const char[] sSrc, int iStart, char[] sDest, int maxlen)
{
	int i = 0;

	while(sSrc[iStart + i] != '\0' && i < maxlen - 1)
	{
		sDest[i] = sSrc[iStart + i];
		i++;
	}

	sDest[i] = '\0';
}

//把字符串截断到行尾.
stock void CutLine(char[] sLine)
{
	for(int i = 0; sLine[i] != '\0'; i++)
	{
		if(sLine[i] == '\n' || sLine[i] == '\r')
		{
			sLine[i] = '\0';
			return;
		}
	}
}

//查找当前配置名称ConVar并挂接变更钩子.
void FindCfgNameConVar()
{
	if(g_hCfgName == null && (g_hCfgName = FindConVar("l4d_ready_cfg_name")) != null)
		g_hCfgName.AddChangeHook(CfgNameChanged);
}

//在设置的服名后追加[当前配置名称].
void SetServerName()
{
	FindCfgNameConVar();

	char sServerName[PLATFORM_MAX_PATH];
	ComputeServerName(sServerName, sizeof(sServerName));
	g_hHostName.SetString(sServerName);
}

//计算当前应显示的服名: 基础名 + [配置显示名].
void ComputeServerName(char[] buffer, int maxlen)
{
	char sCfgName[PLATFORM_MAX_PATH];
	if(g_hCfgName != null)
		g_hCfgName.GetString(sCfgName, sizeof(sCfgName));
	TrimString(sCfgName);

	GetDisplayCfgName(sCfgName, sizeof(sCfgName));//配置标识→显示名映射.

	if(sCfgName[0] != '\0')
		FormatEx(buffer, maxlen, "%s[%s]", g_sBaseName, sCfgName);
	else
		strcopy(buffer, maxlen, g_sBaseName);
}

//配置标识→显示名映射: applemod12v12→多人包抗, applemod→进阶包抗, zonemod→zonemod, nextmod→nextmod (大小写不敏感).
//匹配来源: ①confogl当前配置文件夹名(如 applemod/zonemod/nextmod2v2, 中文配置名被引擎从cfg剥掉时仍可识别)
//         ②l4d_ready_cfg_name变量值(如 "ZoneMod v2.9.1b" / "2v2 NextMod v1.0.5").
void GetDisplayCfgName(char[] sCfgName, int maxlen)
{
	char sRaw[PLATFORM_MAX_PATH];
	strcopy(sRaw, maxlen, sCfgName);

	//①confogl配置文件夹名
	char sConfigName[PLATFORM_MAX_PATH];
	if(GetConfoglConfigName(sConfigName, sizeof(sConfigName)) && ApplyCfgNameMapping(sConfigName, sCfgName, maxlen))
		return;

	//②l4d_ready_cfg_name变量值
	if(ApplyCfgNameMapping(sRaw, sCfgName, maxlen))
		return;

	//无匹配: 保持原值.
	strcopy(sCfgName, maxlen, sRaw);
}

//大小写不敏感关键词映射, 命中返回true并写入显示名.
bool ApplyCfgNameMapping(const char[] source, char[] buffer, int maxlen)
{
	//applemod 的 12v12 子配置必须先判, 否则会被下面的 "applemod" 规则吃掉显示成"进阶包抗".
	//匹配来源同时覆盖两种: confogl 配置文件夹名 "applemod12v12" 与 l4d_ready_cfg_name 里的 "... 12v12".
	if(StrContains(source, "12v12", false) != -1)
	{
		strcopy(buffer, maxlen, "多人包抗");
		return true;
	}
	if(StrContains(source, "applemod", false) != -1)
	{
		strcopy(buffer, maxlen, "进阶包抗");
		return true;
	}
	if(StrContains(source, "zonemod", false) != -1)
	{
		strcopy(buffer, maxlen, "zonemod");
		return true;
	}
	if(StrContains(source, "nextmod", false) != -1)
	{
		strcopy(buffer, maxlen, "nextmod");
		return true;
	}
	return false;
}

//获取confogl当前配置文件夹名(如applemod), 未加载/无自定义配置时返回false.
bool GetConfoglConfigName(char[] buffer, int maxlen)
{
	if(!LibraryExists("confogl"))
		return false;
	if(GetFeatureStatus(FeatureType_Native, "LGO_GetConfigName") != FeatureStatus_Available)
		return false;

	LGO_GetConfigName(buffer, maxlen);
	return true;
}

void CfgNameChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	SetServerName();//配置名称变化时重新设置服名.
}

//定时核对: 中文配置间切换时l4d_ready_cfg_name可能保持空值不触发变更钩子, 需按confogl文件夹名重新计算.
public Action Timer_RefreshServerName(Handle timer)
{
	char sCur[PLATFORM_MAX_PATH], sNew[PLATFORM_MAX_PATH];
	g_hHostName.GetString(sCur, sizeof(sCur));
	ComputeServerName(sNew, sizeof(sNew));
	if(!StrEqual(sCur, sNew))
		g_hHostName.SetString(sNew);
	return Plugin_Continue;
}

//回复提示:玩家用聊天栏,服务器控制台用控制台.
stock void ReplyToClient(int client, const char[] sMsg, any ...)
{
	char sBuffer[256];
	VFormat(sBuffer, sizeof(sBuffer), sMsg, 3);

	if(client == 0 || !IsClientInGame(client))
		PrintToServer("[l4d2_hostname] %s", sBuffer);
	else
		PrintToChat(client, "\x04[提示]\x05%s", sBuffer);
}

bool IsCheckClientAccess(int client)
{
	if(client == 0)//服务器控制台和rcon.
		return true;

	if(!IsClientInGame(client) || IsFakeClient(client))
		return false;

	if(GetUserFlagBits(client) & ADMFLAG_ROOT)
		return true;
	return false;
}

//判断字符串是纯数字.
stock bool IsNumericChar(const char[] chr)
{
	for(int i = 0; i < strlen(chr); i++)//创建循环.
		if(!IsCharNumeric(chr[i]))
			return false;
	return true;
}
