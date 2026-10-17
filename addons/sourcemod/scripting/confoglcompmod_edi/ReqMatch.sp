#if defined __reg_match_included
	#endinput
#endif
#define __reg_match_included

#define RM_DEBUG	   false
#define RM_MODULE_NAME "ReqMatch"

#define MAPRESTARTTIME 3.0
#define RESETMINTIME   60.0

static bool
	RM_bDebugEnabled = RM_DEBUG,
	// RM_bMatchRequest[2] = {false, ...},
	RM_bIsMatchModeLoaded = false,
	RM_bIsAMatchActive	  = false,
	RM_bIsPluginsLoaded	  = false,
	RM_bIsMapRestarted	  = false,
	RM_bRestorePending    = false,
	RM_bIsChmatchRequest = false;

static Handle
	RM_hRestartTimer = null,
	RM_hFwdMatchLoad   = null,
	RM_hFwdMatchUnload = null;

static char
	RM_sPendingConfig[128],
	RM_sPendingMap[PLATFORM_MAX_PATH];

static ConVar
	RM_hSbAllBotGame	   = null,
	RM_hDoRestart		   = null,
	// RM_hAllowVoting = null,
	RM_hReloaded		   = null,
	RM_hChangeMap		   = null,
	RM_hAutoLoad		   = null,
	RM_hAutoCfg			   = null,
	RM_hPersistentActive   = null,
	RM_hConfigFile_On	   = null,
	RM_hConfigFile_Plugins = null,
	RM_hConfigFile_Off	   = null;

void RM_APL()
{
	RM_hFwdMatchLoad   = CreateGlobalForward("LGO_OnMatchModeLoaded", ET_Ignore);
	RM_hFwdMatchUnload = CreateGlobalForward("LGO_OnMatchModeUnloaded", ET_Ignore);

	CreateNative("LGO_IsMatchModeLoaded", native_IsMatchModeLoaded);
}

void RM_OnModuleStart()
{
	RM_hDoRestart		   = CreateConVarEx("match_restart", "1", "Sets whether the plugin will restart the map upon match mode being forced or requested", _, true, 0.0, true, 1.0);
	// RM_hAllowVoting = CreateConVarEx("match_allowvoting", "1", "Sets whether players can vote/request for match mode", _, true, 0.0, true, 1.0);
	RM_hAutoLoad		   = CreateConVarEx("match_autoload", "0", "Has match mode start up automatically when a player connects and the server is not in match mode", _, true, 0.0, true, 1.0);
	RM_hAutoCfg			   = CreateConVarEx("match_autoconfig", "", "Specify which config to load if the autoloader is enabled");
	RM_hConfigFile_On	   = CreateConVarEx("match_execcfg_on", "confogl.cfg", "Execute this config file upon match mode starts and every map after that.");
	// RM_hConfigFile_Plugins = CreateConVarEx("match_execcfg_plugins", "confogl_plugins.cfg", "Execute this config file upon match mode starts. This will only get executed once and meant for plugins that needs to be loaded."); //original
	RM_hConfigFile_Plugins = CreateConVarEx("match_execcfg_plugins", "generalfixes.cfg;confogl_plugins.cfg;sharedplugins.cfg", "Execute this config file upon match mode starts. This will only get executed once and meant for plugins that needs to be loaded.");	   // rework
	RM_hConfigFile_Off	   = CreateConVarEx("match_execcfg_off", "confogl_off.cfg", "Execute this config file upon match mode ends.");

	// RegConsoleCmd("sm_match", RM_Cmd_Match);
	RegAdminCmd("sm_forcematch", RM_Cmd_ForceMatch, ADMFLAG_CONFIG, "Forces the game to use match mode");
	RegAdminCmd("sm_fm", RM_Cmd_ForceMatch, ADMFLAG_CONFIG, "Forces the game to use match mode");
	RegAdminCmd("sm_resetmatch", RM_Cmd_ResetMatch, ADMFLAG_CONFIG, "Forces match mode to turn off REGRADLESS for always on or forced match");
	RegAdminCmd("sm_forcechangematch", RM_CMD_ChangeMatch, ADMFLAG_CONFIG, "Forces the match to be changed");
	RegAdminCmd("sm_fchmatch", RM_CMD_ChangeMatch, ADMFLAG_CONFIG, "Forces the match to be changed");
	RegAdminCmd("sm_confoglstatus", RM_Cmd_Status, ADMFLAG_CONFIG, "Show the loaded config, match state and CVar commit status");

	RM_hSbAllBotGame = FindConVar("sb_all_bot_game");
	// Engine ConVars survive a plugin reload; never include this in tracked match settings.
	RM_hPersistentActive = CreateConVarEx("match_active", "0", "Internal match recovery state. Do not change.", FCVAR_DONTRECORD | FCVAR_UNLOGGED);

	RM_hReloaded	 = FindConVarEx("match_reloaded");
	if (RM_hReloaded == null)
	{
		RM_hReloaded = CreateConVarEx("match_reloaded", "0", "DONT TOUCH THIS CVAR! This is to prevent match feature keep looping, however the plugin takes care of it. Don't change it!", FCVAR_DONTRECORD | FCVAR_UNLOGGED);
	}

	RM_hChangeMap = FindConVarEx("match_map");
	if (RM_hChangeMap == null)
	{
		RM_hChangeMap = CreateConVarEx("match_map", "", "DONT TOUCH THIS CVAR! This is to store the map that we'll be changing to", FCVAR_DONTRECORD | FCVAR_UNLOGGED);
	}

}

void RM_OnAllModulesStarted()
{
	if (!RM_hReloaded.BoolValue && !RM_hPersistentActive.BoolValue)
	{
		return;
	}

	RM_bIsPluginsLoaded = true;
	RM_bIsMapRestarted = !RM_hReloaded.BoolValue;
	RM_bRestorePending = true;
	// A late load also receives OnMapStart after OnPluginStart. Restore once,
	// after that callback, so it cannot queue the entry CFG a second time.
	RequestFrame(RM_RestoreMatchAfterLoad);
}

void RM_RestoreMatchAfterLoad()
{
	if (!RM_bRestorePending)
	{
		return;
	}
	RM_bRestorePending = false;

	if (RM_hReloaded.BoolValue)
	{
		if (RM_bDebugEnabled || IsDebugEnabled())
		{
			LogMessage("[%s] Plugin was reloaded from match mode, executing match load", RM_MODULE_NAME);
		}

		RM_hReloaded.SetInt(0);
		RM_Match_Load();
	}
	else if (RM_hPersistentActive.BoolValue)
	{
		// A normal framework reload must rebuild tracking, without restarting the map.
		char sConfig[PLATFORM_MAX_PATH];
		Configs_GetConfigName(sConfig, sizeof(sConfig));
		LogMessage("[%s] Restoring active match after framework reload (mode='%s')", RM_MODULE_NAME, sConfig);
		RM_Match_Load();
	}
}

void RM_OnMapStart()
{
	if (!RM_bIsMatchModeLoaded)
	{
		return;
	}

	if (RM_bDebugEnabled || IsDebugEnabled())
	{
		LogMessage("[%s] New map, executing match config...", RM_MODULE_NAME);
	}

	RM_Match_Load();
}

void RM_OnMapEnd()
{
	// A pending restart belongs to the old map, not the map loaded by another plugin.
	if (RM_hRestartTimer) RM_bIsMapRestarted = true;
	delete RM_hRestartTimer;
}

void RM_OnClientPutInServer()
{
	if (!RM_hAutoLoad.BoolValue || RM_bIsAMatchActive || RM_bRestorePending || RM_bIsChmatchRequest)
	{
		return;
	}

	char buffer[128];
	RM_hAutoCfg.GetString(buffer, sizeof(buffer));

	if (RM_UpdateCfgOn(buffer))
	{
		RM_Match_Load();
	}
}

static void RM_Match_Load()
{
	if (RM_bDebugEnabled || IsDebugEnabled())
	{
		LogMessage("[%s] Match Load", RM_MODULE_NAME);
	}

	char sBuffer[128];
	RM_hConfigFile_On.GetString(sBuffer, sizeof(sBuffer));
	if (!Configs_CfgExists(sBuffer))
	{
		char sConfig[PLATFORM_MAX_PATH];
		Configs_GetConfigName(sConfig, sizeof(sConfig));
		LogError("[%s] Match mode '%s': entry config '%s' is missing. No new settings were committed; loaded=%d.", RM_MODULE_NAME, sConfig, sBuffer, RM_bIsMatchModeLoaded);
		if (!RM_bIsMatchModeLoaded)
		{
			RM_hPersistentActive.SetInt(0);
			RM_hReloaded.SetInt(0);
			RM_bIsAMatchActive = false;
		}
		return;
	}

	if (!RM_bIsAMatchActive)
	{
		RM_bIsAMatchActive = true;
	}

	RM_hSbAllBotGame.SetInt(1);

	if (!RM_bIsPluginsLoaded)
	{
		if (RM_bDebugEnabled || IsDebugEnabled())
		{
			LogMessage("[%s] Loading plugins and reload self", RM_MODULE_NAME);
		}

		RM_hReloaded.SetInt(1);
		RM_hConfigFile_Plugins.GetString(sBuffer, sizeof(sBuffer));

		// ExecuteCfg(sBuffer); //original
		// rework
		char sPieces[32][256];
		int	 iNumPieces = ExplodeString(sBuffer, ";", sPieces, sizeof(sPieces), sizeof(sPieces[]));

		// Unlocking and Unloading Plugins.
		ServerCommand("sm plugins load_unlock");
		ServerCommand("sm plugins unload_all");

		// Restore the overflow fallback before any plugin CFG. The 12v12 CFGs are
		// also chained in bounded chunks: retrying after overflow alone cannot
		// guarantee ordering against commands already in the engine queue.
		ServerCommand("sm plugins load fixes/command_buffer.smx");

		// Loading Plugins.
		for (int i = 0; i < iNumPieces; i++)
		{
			ExecuteCfg(sPieces[i]);
		}
		// rework end

		return;
	}

	RM_hConfigFile_On.GetString(sBuffer, sizeof(sBuffer));
	if (!ExecuteCfg(sBuffer))
	{
		if (!RM_bIsMatchModeLoaded)
		{
			RM_hPersistentActive.SetInt(0);
			RM_bIsAMatchActive = false;
		}
		return;
	}
	RM_hPersistentActive.SetInt(1);
	CreateTimer(0.5, RM_CheckConfigCommit, _, TIMER_FLAG_NO_MAPCHANGE);

	if (RM_bDebugEnabled || IsDebugEnabled())
	{
		LogMessage("[%s] Match config executed", RM_MODULE_NAME);
	}

	if (RM_bIsMatchModeLoaded)
	{
		return;
	}

	if (RM_bDebugEnabled || IsDebugEnabled())
	{
		LogMessage("[%s] Setting match mode active", RM_MODULE_NAME);
	}

	RM_bIsMatchModeLoaded = true;
	IsPluginEnabled(true, true);

	// PrintToChatAll("\x01[\x05Confogl\x01] Match mode loaded!");
	CPrintToChatAll("{blue}[{default}Confogl{blue}]{default} Match mode loaded!");

	// Restart is scheduled by RM_CheckConfigCommit after queued CFGs execute.
	// Reading match_restart here could still see the previous mode's value.
	if (RM_bDebugEnabled || IsDebugEnabled())
	{
		LogMessage("[%s] Match mode loaded!", RM_MODULE_NAME);
	}

	RM_bIsChmatchRequest = false;

	Call_StartForward(RM_hFwdMatchLoad);
	Call_Finish();
}

static void RM_QueueMapRestart()
{
	if (RM_bIsMatchModeLoaded && !RM_bIsMapRestarted && !RM_hRestartTimer && RM_hDoRestart.BoolValue)
	{
		char sMap[PLATFORM_MAX_PATH];
		RM_hChangeMap.GetString(sMap, sizeof(sMap));

		if (strlen(sMap) > 0)
		{
			CPrintToChatAll("{blue}[{default}Confogl{blue}]{default} Changing map to {green}%s{default}!", sMap);
		}
		else {
			GetCurrentMap(sMap, sizeof(sMap));

			// PrintToChatAll("\x01[\x05Confogl\x01] Restarting map!");
			CPrintToChatAll("{blue}[{default}Confogl{blue}]{default} Restarting map!");
		}

		DataPack hDp;
		RM_hRestartTimer = CreateDataTimer(MAPRESTARTTIME, RM_Match_MapRestart_Timer, hDp, TIMER_FLAG_NO_MAPCHANGE);
		hDp.WriteString(sMap);
	}
}

static void RM_Match_Unload(bool bForced = false)
{
	bool bIsHumansOnServer = IsHumansOnServer();

	if (!bIsHumansOnServer || bForced)
	{
		if (RM_bDebugEnabled || IsDebugEnabled())
		{
			LogMessage("[%s] Match is no longer active, sb_all_bot_game reset to 0, IsHumansOnServer %b, bForced %b", RM_MODULE_NAME, bIsHumansOnServer, bForced);
		}

		RM_bIsAMatchActive = false;
		RM_hSbAllBotGame.SetInt(0);
	}

	if (bIsHumansOnServer && !bForced)
	{
		return;
	}

	if (RM_bDebugEnabled || IsDebugEnabled())
	{
		LogMessage("[%s] Unloading match mode...", RM_MODULE_NAME);
	}

	char sBuffer[128];
	delete RM_hRestartTimer;
	RM_bIsMatchModeLoaded = false;
	IsPluginEnabled(true, false);
	RM_bIsMapRestarted	= false;
	RM_bIsPluginsLoaded = false;
	RM_bRestorePending = false;
	RM_hPersistentActive.SetInt(0);
	RM_hReloaded.SetInt(0);

	Call_StartForward(RM_hFwdMatchUnload);
	Call_Finish();

	// PrintToChatAll("\x01[\x05Confogl\x01] Match mode unloaded!");
	CPrintToChatAll("{blue}[{default}Confogl{blue}]{default} Match mode unloaded!");

	RM_hConfigFile_Off.GetString(sBuffer, sizeof(sBuffer));

	if (!RM_bIsChmatchRequest)
	{
		ExecuteCfg(sBuffer);
		// The off-config path has already been queued; forget the selected mode on reset.
		SetCustomCfg("");
	}
	else
	{
		// if we are using chmatch, don't let predictable_unloader_edi unload confogl itself.
		// all plugins will be unload and load when the new config excuted.
		ServerCommand("sm plugins load_unlock");
		ServerCommand("sm plugins unload optional/another/predictable_unloader_edi.smx");
		ExecuteCfg(sBuffer);
	}

	if (RM_bDebugEnabled || IsDebugEnabled())
	{
		LogMessage("[%s] Match mode unloaded!", RM_MODULE_NAME);
	}
}

static Action RM_CheckConfigCommit(Handle timer)
{
	if (!RM_bIsMatchModeLoaded) return Plugin_Stop;
#if MODULE_CVARSETTINGS
	if (RM_bIsMatchModeLoaded && !CVS_IsTrackingStarted())
	{
		char sConfig[PLATFORM_MAX_PATH];
		Configs_GetConfigName(sConfig, sizeof(sConfig));
		LogError("[%s] Mode '%s' is active but its CVar settings were not committed. Check the exec chain and confogl_setcvars; run sm_confoglstatus.", RM_MODULE_NAME, sConfig);
		return Plugin_Stop;
	}
#endif
	RM_QueueMapRestart();
	return Plugin_Stop;
}

static Action RM_Cmd_Status(int client, int args)
{
	char sFile[PLATFORM_MAX_PATH], sConfig[PLATFORM_MAX_PATH], sEntry[128], sAuto[128];
	GetPluginFilename(null, sFile, sizeof(sFile));
	Configs_GetConfigName(sConfig, sizeof(sConfig));
	RM_hConfigFile_On.GetString(sEntry, sizeof(sEntry));
	RM_hAutoCfg.GetString(sAuto, sizeof(sAuto));
	ReplyToCommand(client, "[Confogl] v%s | file=%s | cfg='%s' | entry=%s | autoconfig='%s'", PLUGIN_VERSION, sFile, sConfig, sEntry, sAuto);
	ReplyToCommand(client, "[Confogl] enabled=%d | active=%d | loaded=%d | plugins=%d | reloaded=%d | recovery=%d | restoring=%d | restarted=%d", IsPluginEnabled(), RM_bIsAMatchActive, RM_bIsMatchModeLoaded, RM_bIsPluginsLoaded, RM_hReloaded.IntValue, RM_hPersistentActive.IntValue, RM_bRestorePending, RM_bIsMapRestarted);
	ReplyToCommand(client, "[Confogl] restart_enabled=%d | restart_pending=%d", RM_hDoRestart.IntValue, RM_hRestartTimer != null);
#if MODULE_CVARSETTINGS
	CVS_ReplyStatus(client);
#endif
	return Plugin_Handled;
}

static Action RM_Match_MapRestart_Timer(Handle hTimer, DataPack hDp)
{
	if (hTimer != RM_hRestartTimer) return Plugin_Stop;
	RM_hRestartTimer = null;
	if (!RM_bIsMatchModeLoaded || RM_bIsMapRestarted) return Plugin_Stop;
#if MODULE_CVARSETTINGS
	if (!CVS_IsTrackingStarted())
	{
		LogError("[%s] Match restart/load_lock cancelled: confogl_setcvars has not committed the mode settings.", RM_MODULE_NAME);
		return Plugin_Stop;
	}
#endif
	ServerCommand("sm plugins load_lock");	  // rework

	if (RM_bDebugEnabled || IsDebugEnabled())
	{
		LogMessage("[%s] Restarting map...", RM_MODULE_NAME);
	}

	char sMap[PLATFORM_MAX_PATH];
	hDp.Reset();
	hDp.ReadString(sMap, sizeof(sMap));

	RM_bIsMapRestarted = true;
	ForceChangeLevel(sMap, "Match restart");

	return Plugin_Stop;
}

static bool RM_UpdateCfgOn(const char[] cfgfile, bool bIsPrint = true)
{
	if (SetCustomCfg(cfgfile))
	{
		// PrintToChatAll("\x01[\x05Confogl\x01] Using \"\x04%s\x01\" config.", cfgfile);
		CPrintToChatAll("{blue}[{default}Confogl{blue}]{default} Loading '{olive}%s{default}'.", cfgfile);

		if (RM_bDebugEnabled || IsDebugEnabled())
		{
			LogMessage("[%s] Starting match on config %s", RM_MODULE_NAME, cfgfile);
		}

		return true;
	}

	if (bIsPrint)
	{
		// PrintToChatAll("\x01[\x05Confogl\x01] Config \"\x04%s\x01\" not found, using default config!", cfgfile);
		CPrintToChatAll("{blue}[{default}Confogl{blue}]{default} Config '{olive}%s{default}' not found, using default config!", cfgfile);
	}

	return false;
}

static Action RM_Cmd_ForceMatch(int client, int args)
{
	if (RM_bIsMatchModeLoaded || RM_bRestorePending || RM_bIsChmatchRequest)
	{
		return Plugin_Handled;
	}

	if (RM_bDebugEnabled || IsDebugEnabled())
	{
		LogMessage("[%s] Match mode forced to load!", RM_MODULE_NAME);
	}

	if (args < 1)
	{
		// SetCustomCfg(""); //old code
		// RM_Match_Load(); //old code

		if (client == 0)
		{
			PrintToServer("[Confogl] Please specify a config to load.");
		}
		else {
			// PrintToChat(client, "\x01[\x05Confogl\x01] Please specify a \x04config\x01 to load.");
			CPrintToChat(client, "{blue}[{default}Confogl{blue}]{default} Please specify a {olive}config{default} to load.");
		}
		return Plugin_Handled;
	}

	char sBuffer[128];
	GetCmdArg(1, sBuffer, sizeof(sBuffer));

	// RM_UpdateCfgOn(sBuffer); //old code

	if (!Configs_CustomCfgExists(sBuffer))
	{
		if (client == 0)
		{
			PrintToServer("[Confogl] Config %s not found!", sBuffer);
		}
		else {
			// PrintToChat(client, "\x01[\x05Confogl\x01] Please specify a \"\x04%s\x01\" to load.", sBuffer);
			CPrintToChat(client, "{blue}[{default}Confogl{blue}]{default} Config '{olive}%s{default}' not found!", sBuffer);
		}

		return Plugin_Handled;
	}

	char sMap[PLATFORM_MAX_PATH], sDisplayName[PLATFORM_MAX_PATH];

	if (args == 2)
	{
		GetCmdArg(2, sMap, sizeof(sMap));

		if (FindMap(sMap, sDisplayName, sizeof(sDisplayName)) == FindMap_NotFound)
		{
			if (client == 0)
			{
				PrintToServer("[Confogl] Map %s not found!", sMap);
			}
			else {
				CPrintToChat(client, "{blue}[{default}Confogl{blue}]{default} Map '{olive}%s{default}' not found!", sMap);
			}
			return Plugin_Handled;
		}

		GetMapDisplayName(sDisplayName, sDisplayName, sizeof(sDisplayName));
	}
	if (!RM_UpdateCfgOn(sBuffer, false))
	{
		return Plugin_Handled;
	}
	RM_hChangeMap.SetString(sDisplayName);

	RM_Match_Load();

	return Plugin_Handled;
}

static Action RM_Cmd_ResetMatch(int client, int args)
{
	if (!RM_bIsMatchModeLoaded && !RM_bRestorePending && !RM_bIsChmatchRequest)
	{
		return Plugin_Handled;
	}

	if (RM_bDebugEnabled || IsDebugEnabled())
	{
		LogMessage("[%s] Match mode forced to unload!", RM_MODULE_NAME);
	}

	RM_bIsChmatchRequest = false;
	RM_sPendingConfig[0] = 0;
	RM_sPendingMap[0] = 0;
	RM_Match_Unload(true);

	return Plugin_Handled;
}

static Action RM_CMD_ChangeMatch(int client, int args)
{
	if (args < 1)
	{
		if (client == 0)
		{
			PrintToServer("[Confogl] Please specify a config to load.");
		}
		else {
			CPrintToChat(client, "{blue}[{default}Confogl{blue}]{default} Please specify a {olive}config{default} to load.");
		}
		return Plugin_Handled;
	}

	char sBuffer[128];
	GetCmdArg(1, sBuffer, sizeof(sBuffer));

	if (!Configs_CustomCfgExists(sBuffer))
	{
		if (client == 0)
		{
			PrintToServer("[Confogl] Config %s not found!", sBuffer);
		}
		else {
			CPrintToChat(client, "{blue}[{default}Confogl{blue}]{default} Config '{olive}%s{default}' not found!", sBuffer);
		}

		return Plugin_Handled;
	}

	char sMap[PLATFORM_MAX_PATH], sDisplayName[PLATFORM_MAX_PATH];

	if (args == 2)
	{
		GetCmdArg(2, sMap, sizeof(sMap));

		if (FindMap(sMap, sDisplayName, sizeof(sDisplayName)) == FindMap_NotFound)
		{
			if (client == 0)
			{
				PrintToServer("[Confogl] Map %s not found!", sMap);
			}
			else {
				CPrintToChat(client, "{blue}[{default}Confogl{blue}]{default} Map '{olive}%s{default}' not found!", sMap);
			}
			return Plugin_Handled;
		}

		GetMapDisplayName(sDisplayName, sDisplayName, sizeof(sDisplayName));
	}

	// Unload
	if (!RM_bIsMatchModeLoaded && !RM_bRestorePending)
	{
		return Plugin_Handled;
	}

	if (RM_bDebugEnabled || IsDebugEnabled())
	{
		LogMessage("[%s] Match mode forced to unload! [Change in this case!]", RM_MODULE_NAME);
	}

	RM_bIsChmatchRequest = true;
	// Keep the old resolver until its off-config has been queued. The new
	// target must not redirect cleanup or survive a failed map validation.
	strcopy(RM_sPendingConfig, sizeof(RM_sPendingConfig), sBuffer);
	strcopy(RM_sPendingMap, sizeof(RM_sPendingMap), sDisplayName);

	RM_Match_Unload(true);

	// give time to fully finish unloading.
	CreateTimer(1.0, Timer_DelayToLoadMatchMode);

	return Plugin_Handled;
}

static Action Timer_DelayToLoadMatchMode(Handle timer)
{
	// Load
	if (RM_bIsMatchModeLoaded || !strlen(RM_sPendingConfig))
	{
		return Plugin_Handled;
	}
	if (!RM_UpdateCfgOn(RM_sPendingConfig, false))
	{
		LogError("[%s] Pending match config '%s' is no longer available; match remains inactive", RM_MODULE_NAME, RM_sPendingConfig);
		RM_sPendingConfig[0] = 0;
		RM_sPendingMap[0] = 0;
		RM_bIsChmatchRequest = false;
		return Plugin_Handled;
	}
	RM_hChangeMap.SetString(RM_sPendingMap);
	RM_sPendingConfig[0] = 0;
	RM_sPendingMap[0] = 0;
	// The old off-config finished. A missing new entry must leave an inactive,
	// retryable match rather than retain the transition guard indefinitely.
	RM_bIsChmatchRequest = false;

	if (RM_bDebugEnabled || IsDebugEnabled())
	{
		LogMessage("[%s] Match mode forced to load! [Change in this case!]", RM_MODULE_NAME);
	}

	RM_Match_Load();

	return Plugin_Handled;
}

/*static Action RM_Cmd_Match(int client, int args)
{
	if (RM_bIsMatchModeLoaded || (!IsVersus() && !IsScavenge()) || !RM_hAllowVoting.BoolValue) {
		return Plugin_Handled;
	}

	int iTeam = GetClientTeam(client);
	if ((iTeam == L4D2Team_Survivor || iTeam == L4D2Team_Infected) && !RM_bMatchRequest[iTeam - 2]) {
		RM_bMatchRequest[iTeam - 2] = true;
	} else {
		return Plugin_Handled;
	}

	if (RM_bMatchRequest[0] && RM_bMatchRequest[1]) {
		//PrintToChatAll("\x01[\x05Confogl\x01] Both teams have agreed to start a competitive match!");
		CPrintToChatAll("{blue}[{default}Confogl{blue}]{default} Both teams have agreed to start a competitive match!");

		RM_Match_Load();
	} else if (RM_bMatchRequest[0] || RM_bMatchRequest[1]) {
		//PrintToChatAll("\x01[\x05Confogl\x01] The \x04%s\x01 have requested to start a competitive match. The \x04%s\x01 must accept with match command!",
								//g_sTeamName[iTeam + 4], g_sTeamName[iTeam + 3]);
		CPrintToChatAll("{blue}[{default}Confogl{blue}]{default} The {olive}%s{default} have requested to start a competitive match. The {olive}%s{default} must accept with match command!", \
								g_sTeamName[iTeam + 4], g_sTeamName[iTeam + 3]);

		if (args > 0) { // cfgfile specified
			char sBuffer[128];
			GetCmdArg(1, sBuffer, sizeof(sBuffer));
			RM_UpdateCfgOn(sBuffer);
		} else {
			SetCustomCfg("");
		}

		CreateTimer(30.0, RM_MatchRequestTimeout);
	}

	return Plugin_Handled;
}

static Action RM_MatchRequestTimeout(Handle hTimer)
{
	RM_ResetMatchRequest();

	return Plugin_Stop;
}*/

void RM_OnClientDisconnect(int client)
{
	if (!RM_bIsMatchModeLoaded || IsFakeClient(client))
	{
		return;
	}

	CreateTimer(RESETMINTIME, RM_MatchResetTimer);
}

static Action RM_MatchResetTimer(Handle hTimer)
{
	RM_Match_Unload();

	return Plugin_Stop;
}

/*static void RM_ResetMatchRequest()
{
	RM_hConfigFile_On.RestoreDefault();

	RM_bMatchRequest[0] = false;
	RM_bMatchRequest[1] = false;
}*/

stock bool IsAMatchActive()
{
	return RM_bIsAMatchActive;
}

static int native_IsMatchModeLoaded(Handle plugin, int numParams)
{
	return RM_bIsMatchModeLoaded;
}
