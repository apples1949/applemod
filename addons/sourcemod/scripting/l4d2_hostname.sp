#pragma semicolon 1
//強制1.7以後的新語法
#pragma newdecls required
#include <sourcemod>
#include <sdktools>
#undef REQUIRE_PLUGIN
#include <confogl>

#define PLUGIN_VERSION	"1.2.0"

ConVar g_hHostName, g_hCfgName;
char g_sPath[PLATFORM_MAX_PATH], g_sFileLine[PLATFORM_MAX_PATH];

public Plugin myinfo = 
{
	name 			= "l4d2_hostname",
	author 			= "apples1949",
	description 	= "管理员!host重载服名或设置新服名; 服名后缀跟随当前配置 (applemod→进阶包抗, zonemod→zonemod, nextmod→nextmod)",
	version 		= PLUGIN_VERSION,
	url 			= "N/A"
}

public void OnPluginStart()
{
	RegConsoleCmd("sm_host", Addhostname, "重载服名或设置新服名");
	g_hHostName = FindConVar("hostname");
	FindCfgNameConVar();
	IsGetSetHostName();//获取文件里的内容.
	CreateTimer(5.0, Timer_RefreshServerName, _, TIMER_REPEAT);//定时核对服名(配置切换兜底).
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
	IsGetSetHostName();//获取文件里的内容.
}

public Action Addhostname(int client, int args)
{
	if(IsCheckClientAccess(client))
	{
		if(args == 0)
		{
			IsGetSetHostName();//获取文件里的内容.
			PrintToChat(client, "\x04[提示]\x05已重新加载配置文件(使用指令!host空格+内容设置新服名).");
		}
		else
		{
			char arg[64];
			GetCmdArgString(arg, sizeof(arg));
			IsWriteServerName(arg);//写入内容到文件里.
			PrintToChat(client, "\x04[提示]\x05已设置新服名为\x04:\x05(\x03%s\x05)\x04.", arg);
		}
	}
	else
		PrintToChat(client, "\x04[提示]\x05只限管理员使用该指令.");
	return Plugin_Handled;
}

//获取文件里的服名.
void IsGetSetHostName()
{
	BuildPath(Path_SM, g_sPath, sizeof(g_sPath), "configs/hostname/l4d2_hostname.txt");
	if(FileExists(g_sPath))//判断文件是否存在.
		IsSetSetHostName();//文件已存在,获取文件里的内容.
	else
		IsWriteServerName("猜猜这个是谁的萌新服?");//文件不存在,创建文件并写入默认内容.
}

//获取文件里的内容.
void IsSetSetHostName()
{
	File file = OpenFile(g_sPath, "rb");

	if(file)
	{
		while(!file.EndOfFile())
			file.ReadLine(g_sFileLine, sizeof(g_sFileLine));
		delete file;
		TrimString(g_sFileLine);//整理获取到的字符串.
	}
	SetServerName();//设置服名并追加当前配置名称.
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
		FormatEx(buffer, maxlen, "%s[%s]", g_sFileLine, sCfgName);
	else
		strcopy(buffer, maxlen, g_sFileLine);
}

//配置标识→显示名映射: applemod→进阶包抗, zonemod→zonemod, nextmod→nextmod (大小写不敏感).
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

//写入内容到文件里.
void IsWriteServerName(char []arg)
{
	File file = OpenFile(g_sPath, "w");
	strcopy(g_sFileLine, sizeof(g_sFileLine), arg);
	TrimString(g_sFileLine);//写入内容前整理字符串.

	if(file)
	{
		WriteFileString(file, g_sFileLine, false);//这个方法写入内容不会自动添加换行符.
		SetServerName();//设置新服名并追加当前配置名称.
		delete file;
	}
}

bool IsCheckClientAccess(int client)
{
	if(GetUserFlagBits(client) & ADMFLAG_ROOT)
		return true;
	return false;
}
