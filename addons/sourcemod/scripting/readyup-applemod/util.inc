#if defined _readyup_util_included
 #endinput
#endif
#define _readyup_util_included

int GetMaxAllowedPlayers()
{
	int survLimit = survivor_limit.IntValue;
	
	if (L4D_GetGameModeType() & (GAMEMODE_VERSUS|GAMEMODE_SCAVENGE))
	{
		return survLimit + z_max_player_zombies.IntValue;
	}
	
	return survLimit;
}

// 团队就绪 (l4d_ready_enabled=3) = 队伍中有一名人类玩家已准备, 即代表整个团队已准备
// 要求队伍中至少存在一名人类玩家 (空队/全 bot 的队伍视为未准备)
bool IsTeamReady(int team)
{
	for (int i = 1; i <= MaxClients; ++i)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == team && IsPlayerReady(i))
		{
			return true;
		}
	}
	return false;
}

// 团队模式: 将队伍中所有玩家的准备状态复位 (有人取消准备时, 团队准备状态改回未准备)
void UnreadyTeam(int team)
{
	for (int i = 1; i <= MaxClients; ++i)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == team)
		{
			SetPlayerReady(i, false);
		}
	}
}

void UTIL_WrapperForward(GlobalForward fw)
{
	if (fw.FunctionCount)
	{
		Call_StartForward(fw);
		Call_Finish();
	}
}

bool IsEmptyString(const char[] str, int maxlength)
{
	int len = strlen(str);
	if (len == 0)
		return true;
	
	if (len > maxlength)
		len = maxlength;
	
	for (int i = 0; i < len; ++i)
	{
		if (IsCharSpace(str[i]))
			continue;
		
		if (str[i] == '\r' || str[i] == '\n')
			continue;
		
		return false;
	}
	
	return true;
}

bool IsAnyPlayerLoading()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i) && (!IsClientInGame(i) || GetClientTeam(i) == L4D2Team_None))
		{
			return true;
		}
	}
	return false;
}

int GetSeriousClientCount(bool inGame = false)
{
	int clients = 0;
	
	for (int i = 1; i <= MaxClients; i++)
	{
		if (inGame)
		{
			if (IsClientInGame(i) && !IsFakeClient(i)) clients++;
		}
		else
		{
			if (IsClientConnected(i) && !IsFakeClient(i)) clients++;
		}
	}
	
	return clients;
}

void ReturnTeamToSaferoom(int team)
{
	int warp_flags = GetCommandFlags("warp_to_start_area");
	SetCommandFlags("warp_to_start_area", warp_flags & ~FCVAR_CHEAT);

	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client) && GetClientTeam(client) == team)
		{
			ReturnPlayerToSaferoom(client, true);
		}
	}

	SetCommandFlags("warp_to_start_area", warp_flags);
}

void SetTeamFrozen(int team, bool freezeStatus)
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client) && GetClientTeam(client) == team)
		{
			SetClientFrozen(client, freezeStatus);
		}
	}
}

int GetTeamHumanCount(int team)
{
	int humans = 0;
	
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client) && !IsFakeClient(client) && GetClientTeam(client) == team)
		{
			humans++;
		}
	}
	
	return humans;
}

// ========================
//  配置显示名 (l4d_ready_cfg_name) 中文支持
// ========================
// L4D2 引擎从 cfg 文件解析命令时会丢弃非 ASCII 字节, 导致 confogl.cfg 里写的中文
// 配置名无法进入 l4d_ready_cfg_name 变量 (控制台手输可以, 因为绕过了文件解析)。
// 因此这里直接以 UTF-8 读取当前 confogl 配置的 confogl.cfg 文件来取配置名,
// 读不到时再回退到变量值 (兼容无 confogl / 控制台临时设置)。

// 在 confogl.cfg 中解析 "l4d_ready_cfg_name "xxx"" (兼容 sm_cvar / confogl_addcvar 前缀)
bool ReadCfgNameFromConfoglFile(char[] buffer, int maxlen)
{
	buffer[0] = '\0';
	
	if (!LibraryExists("confogl"))
		return false;
	if (GetFeatureStatus(FeatureType_Native, "LGO_GetConfigName") != FeatureStatus_Available)
		return false;
	
	char configName[64];
	LGO_GetConfigName(configName, sizeof(configName));
	if (configName[0] == '\0')
		return false;
	
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "../../cfg/cfgogl/%s/confogl.cfg", configName);
	
	File f = OpenFile(path, "r");
	if (f == null)
		return false;
	
	const int NAME_LEN = 18; // strlen("l4d_ready_cfg_name")
	bool found = false;
	char line[512];
	
	while (!f.EndOfFile() && f.ReadLine(line, sizeof(line)))
	{
		int idx = StrContains(line, "l4d_ready_cfg_name");
		if (idx == -1)
			continue;
		
		char tail[512];
		strcopy(tail, sizeof(tail), line[idx + NAME_LEN]);
		
		int q1 = FindCharInString(tail, '"');
		if (q1 == -1)
			continue;
		
		int q2 = FindCharInString(tail[q1 + 1], '"');
		if (q2 == -1)
			continue;
		
		if (q2 >= maxlen)
			q2 = maxlen - 1;
		
		strcopy(buffer, maxlen, tail[q1 + 1]);
		buffer[q2] = '\0';
		found = true;
		break;
	}
	
	delete f;
	return found;
}

// 取面板要显示的配置名: 优先 confogl.cfg 文件 (支持中文), 回退 l4d_ready_cfg_name 变量
void GetReadyCfgName(char[] buffer, int maxlen)
{
	if (ReadCfgNameFromConfoglFile(buffer, maxlen) && !IsEmptyString(buffer, maxlen))
		return;
	
	l4d_ready_cfg_name.GetString(buffer, maxlen);
}