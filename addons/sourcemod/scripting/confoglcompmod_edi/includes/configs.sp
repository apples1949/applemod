#if defined __confogl_configs_included
	#endinput
#endif
#define __confogl_configs_included

#define CONFIGS_MODULE_NAME				"Configs"

static const char
	customCfgDir[] = "cfgogl";

static char
	DirSeparator = '\0',
	configsPath[PLATFORM_MAX_PATH] = "\0",
	cfgPath[PLATFORM_MAX_PATH] = "\0",
	customCfgPath[PLATFORM_MAX_PATH] = "\0",
	customCfgName[PLATFORM_MAX_PATH] = "\0";

static ConVar
	hCustomConfig = null;

void Configs_APL()
{
	CreateNative("LGO_BuildConfigPath", _native_BuildConfigPath);
	CreateNative("LGO_ExecuteConfigCfg", _native_ExecConfigCfg);
	CreateNative("LGO_GetConfigName", _native_GetConfigName);
}

void Configs_OnModuleStart()
{
	InitPaths();

	hCustomConfig = CreateConVarEx("customcfg", "", "DONT TOUCH THIS CVAR! This is more magic bullshit!", FCVAR_DONTRECORD|FCVAR_UNLOGGED);

	char cfgString[PLATFORM_MAX_PATH];
	hCustomConfig.GetString(cfgString, sizeof(cfgString));
	if (!SetCustomCfg(cfgString)) {
		LogError("[%s] Saved mode '%s' is unavailable; clearing stale config state", CONFIGS_MODULE_NAME, cfgString);
		SetCustomCfg("");
	}
}

static void InitPaths()
{
	BuildPath(Path_SM, configsPath, sizeof(configsPath), "configs/confogl/");
	BuildPath(Path_SM, cfgPath, sizeof(cfgPath), "../../cfg/");

	DirSeparator = cfgPath[(strlen(cfgPath) - 1)];
}

bool SetCustomCfg(const char[] cfgname)
{
	if (!strlen(cfgname)) {
		customCfgPath[0] = 0;
		customCfgName[0] = 0;
		hCustomConfig.RestoreDefault();

		if (IsDebugEnabled()) {
			LogMessage("[%s] Custom Config Path Reset - Using Default", CONFIGS_MODULE_NAME);
		}

		return true;
	}

	char targetCfgPath[PLATFORM_MAX_PATH];
	FormatEx(targetCfgPath, sizeof(targetCfgPath), "%s%s%c%s", cfgPath, customCfgDir, DirSeparator, cfgname);
	if (!DirExists(targetCfgPath)) {
		Debug_LogError(CONFIGS_MODULE_NAME, "Custom config directory %s does not exist!", targetCfgPath);
		return false;
	}

	int thislen = strlen(targetCfgPath);
	if ((thislen + 1) < sizeof(targetCfgPath)) {
		targetCfgPath[thislen] = DirSeparator;
		targetCfgPath[(thislen + 1)] = 0;
	} else {
		Debug_LogError(CONFIGS_MODULE_NAME, "Custom config directory %s path too long!", targetCfgPath);
		return false;
	}

	strcopy(customCfgPath, sizeof(customCfgPath), targetCfgPath);
	strcopy(customCfgName, sizeof(customCfgName), cfgname);
	hCustomConfig.SetString(cfgname);

	return true;
}

bool Configs_CustomCfgExists(const char[] cfgname)
{
	if (!strlen(cfgname)) {
		return false;
	}
	char sPath[PLATFORM_MAX_PATH];
	FormatEx(sPath, sizeof(sPath), "%s%s%c%s", cfgPath, customCfgDir, DirSeparator, cfgname);
	return strlen(sPath) + 1 < sizeof(sPath) && DirExists(sPath);
}

void BuildConfigPath(char[] buffer, const int maxlength, const char[] sFileName)
{
	if (customCfgPath[0]) {
		FormatEx(buffer, maxlength, "%s%s", customCfgPath, sFileName);

		if (FileExists(buffer)) {
			if (IsDebugEnabled()) {
				LogMessage("[%s] Built custom config path: %s", CONFIGS_MODULE_NAME, buffer);
			}

			return;
		} else {
			if (IsDebugEnabled()) {
				LogMessage("[%s] Custom config not available: %s", CONFIGS_MODULE_NAME, buffer);
			}
		}
	}

	FormatEx(buffer, maxlength, "%s%s", configsPath, sFileName);
	if (IsDebugEnabled()) {
		LogMessage("[%s] Built default config path: %s", CONFIGS_MODULE_NAME, buffer);
	}
}

bool Configs_CfgExists(const char[] sFileName)
{
	char sFilePath[PLATFORM_MAX_PATH];
	if (customCfgPath[0]) {
		FormatEx(sFilePath, sizeof(sFilePath), "%s%s", customCfgPath, sFileName);
		if (FileExists(sFilePath)) {
			return true;
		}
	}
	FormatEx(sFilePath, sizeof(sFilePath), "%s%s", cfgPath, sFileName);
	return strlen(sFileName) > 0 && FileExists(sFilePath);
}

void Configs_GetConfigName(char[] buffer, int maxlength)
{
	strcopy(buffer, maxlength, customCfgName);
}

bool ExecuteCfg(const char[] sFileName)
{
	if (strlen(sFileName) == 0) {
		LogError("[%s] Cannot execute an empty server config name", CONFIGS_MODULE_NAME);
		return false;
	}

	char sFilePath[PLATFORM_MAX_PATH];

	if (customCfgPath[0]) {
		FormatEx(sFilePath, sizeof(sFilePath), "%s%s", customCfgPath, sFileName);

		if (FileExists(sFilePath)) {
			if (IsDebugEnabled()) {
				LogMessage("[%s] Executing custom cfg file %s", CONFIGS_MODULE_NAME, sFilePath);
			}

			ServerCommand("exec %s%s", customCfgPath[strlen(cfgPath)], sFileName);

			return true;
		} else {
			if (IsDebugEnabled()) {
				LogMessage("[%s] Couldn't find custom cfg file %s, trying default", CONFIGS_MODULE_NAME, sFilePath);
			}
		}
	}

	FormatEx(sFilePath, sizeof(sFilePath), "%s%s", cfgPath, sFileName);

	if (FileExists(sFilePath)) {
		if (IsDebugEnabled()) {
			LogMessage("[%s] Executing default config %s", CONFIGS_MODULE_NAME, sFilePath);
		}

		ServerCommand("exec %s", sFileName);
		return true;
	} else {
		Debug_LogError(CONFIGS_MODULE_NAME, "Could not execute server config \"%s\", file not found", sFilePath);
		LogError("[%s] Could not execute config '%s' (mode='%s'): file not found", CONFIGS_MODULE_NAME, sFileName, customCfgName);
	}
	return false;
}

static int _native_BuildConfigPath(Handle plugin, int numParams)
{
	int iLen = 0;
	GetNativeStringLength(3, iLen);

	int iNewLen = iLen + 1;
	char[] sFileName = new char[iNewLen];
	GetNativeString(3, sFileName, iNewLen);

	iLen = GetNativeCell(2);

	char[] sBuf = new char[iLen];
	BuildConfigPath(sBuf, iLen, sFileName);
	SetNativeString(1, sBuf, iLen);

	return 1;
}

static int _native_ExecConfigCfg(Handle plugin, int numParams)
{
	int iLen = 0;
	GetNativeStringLength(1, iLen);

	int iNewLen = iLen + 1;
	char[] sFileName = new char[iNewLen];
	GetNativeString(1, sFileName, iNewLen);

	return ExecuteCfg(sFileName);
}

static int _native_GetConfigName(Handle plugin, int numParams)
{
	SetNativeString(1, customCfgName, GetNativeCell(2), true);
	return 1;
}
