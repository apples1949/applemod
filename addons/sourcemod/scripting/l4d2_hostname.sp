#pragma semicolon 1
//強制1.7以後的新語法
#pragma newdecls required
#include <sourcemod>

#define PLUGIN_VERSION	"1.1.1"

ConVar g_hHostName, g_hCfgName;
char g_sPath[PLATFORM_MAX_PATH], g_sFileLine[PLATFORM_MAX_PATH];

public Plugin myinfo = 
{
	name 			= "l4d2_hostname",
	author 			= "apples1949",
	description 	= "管理员!host重载服名或设置新服名",
	version 		= PLUGIN_VERSION,
	url 			= "N/A"
}

public void OnPluginStart()
{
	RegConsoleCmd("sm_host", Addhostname, "重载服名或设置新服名");
	g_hHostName = FindConVar("hostname");
	FindCfgNameConVar();
	IsGetSetHostName();//获取文件里的内容.
}

public void OnAllPluginsLoaded()
{
	FindCfgNameConVar();
}

public void OnLibraryAdded(const char[] name)
{
	if(StrEqual(name, "readyup"))
	{
		FindCfgNameConVar();
		SetServerName();//readyup重新加载后重新挂接并设置服名.
	}
}

public void OnLibraryRemoved(const char[] name)
{
	if(StrEqual(name, "readyup"))
		g_hCfgName = null;//配置名称ConVar随readyup卸载而失效.
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

	char sCfgName[PLATFORM_MAX_PATH], sServerName[PLATFORM_MAX_PATH];
	if(g_hCfgName != null)
		g_hCfgName.GetString(sCfgName, sizeof(sCfgName));
	TrimString(sCfgName);

	if(sCfgName[0] != '\0')
		FormatEx(sServerName, sizeof(sServerName), "%s[%s]", g_sFileLine, sCfgName);
	else
		strcopy(sServerName, sizeof(sServerName), g_sFileLine);

	g_hHostName.SetString(sServerName);
}

void CfgNameChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	SetServerName();//配置名称变化时重新设置服名.
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