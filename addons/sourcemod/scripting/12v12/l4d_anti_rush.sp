/*
*	Anti Rush
*	Copyright (C) 2024 Silvers
*
*	This program is free software: you can redistribute it and/or modify
*	it under the terms of the GNU General Public License as published by
*	the Free Software Foundation, either version 3 of the License, or
*	(at your option) any later version.
*
*	This program is distributed in the hope that it will be useful,
*	but WITHOUT ANY WARRANTY; without even the implied warranty of
*	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
*	GNU General Public License for more details.
*
*	You should have received a copy of the GNU General Public License
*	along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

#define PLUGIN_VERSION 		"1.21"
#define DEBUG_BENCHMARK		0			// 0=Off. 1=Benchmark logic function.

/*======================================================================================
	Plugin Info:

*	Name	:	[L4D & L4D2] Anti Rush
*	Author	:	SilverShot
*	Descrp	:	Slowdown or teleport rushers and slackers back to the group. Uses flow distance for accuracy.
*	Link	:	https://forums.alliedmods.net/showthread.php?t=322392
*	Plugins	:	https://sourcemod.net/plugins.php?exact=exact&sortby=title&search=1&author=Silvers

========================================================================================
	Change Log:

12v12 (applemod) - 定制修改:
	- 限速值改为黄血瘸腿速度: 引擎 cvar "survivor_limp_walk_speed" = 85, 故 "l4d_anti_rush_slow" 默认 85.0 (原 100.0).
	  运行时还会读取 survivor_limp_walk_speed, 若它比 l4d_anti_rush_slow 更低则以它为准, 保证限速不超过黄血瘸腿速度.
	- 坦克存活时不限速: "l4d_anti_rush_tanks" 默认值由 1 改为 0 (0=有坦克时暂停防跑图). 需要坦克在场也限速时设为 1.
	- 距离参数 (range_last/range_lead/warn_last/warn_lead) 保持原版默认值不变.
	- 不生成 cfg (AutoExecConfig 保持注释), 全部行为由代码内默认值决定.
	- 修正 TimerTest 中 CheckCommandAccess 误用未初始化变量 client 的问题.

1.21 (28-Jan-2024)
	- Fixed memory leak caused by clearing StringMap/ArrayList data instead of deleting.

1.20 (10-Jan-2024)
	- Changed the plugins on/off/mode cvars to use the "Left 4 DHooks" method instead of creating an entity.

1.19 (10-Mar-2023)
	- Added cvar "l4d_anti_rush_health" to hurt players who are rushing. Requested by "Voevoda".
	- Changed cvar "l4d_anti_rush_type" to allow disabling teleport or slowdown, to only enable health drain.
	- Translation phrases updated to support the health drain only type. Thanks to "Voevoda" and "HarryPotter" for updating Russian and Chinese translations.

1.18 (01-Jun-2022)
	- L4D1: Fixed throwing errors.
	- L4D2: Added map "c5m5_bridge" to the data config.

1.17 (04-Dec-2021)
	- Changes to fix warnings when compiling on SourceMod 1.11.

1.16 (19-Oct-2021)
	- Plugin now ignores players who are being healed or revived, or players healing or reviving someone. Requested to "Psyk0tik".

1.15 (09-Sep-2021)
	- Fixed the last update breaking the plugin in L4D1.

1.14 (25-Aug-2021)
	- Plugin now ignores players being carried by the Charger. Thanks to "Darkwob" for reporting.

1.13 (30-Jun-2021)
	- Plugin now ignores players inside elevators.

1.12 (16-Jun-2021)
	- L4D1: Fixed throwing errors about missing property "m_type". Thanks to "Dragokas" for reporting.

1.11 (20-Apr-2021)
	- Added cvars "l4d_anti_rush_flags" and "l4d_anti_rush_ignore" to make players with certain flags immune to the plugins actions. Requested by "Shadowart".

1.10a (12-Apr-2021)
	- Updated data config "data/l4d_anti_rush.cfg" with new triggers. Thanks to "jeremyvillanueva" for providing.

1.10 (23-Mar-2021)
	- Cleaning source code from last update.
	- Fixed potentially using the wrong "add" range from the config.

1.9 (22-Mar-2021)
	- Added optional config "data/l4d_anti_rush.cfg" to extend the trigger detection range during certain crescendo events. Requested by "SilentBr".

1.8 (09-Oct-2020)
	- Changed cvar "l4d_anti_rush_finale" to allow working in Gauntlet type finales only. Thanks to "Xanaguy" for requesting.
	- Renamed cvar "l4d_anti_rush_inacpped" to "l4d_anti_rush_incapped" fixing spelling mistake.

1.7 (09-Oct-2020)
	- Added cvar "l4d_anti_rush_tanks" to control if the plugins active when any tank is alive.
	- Fixed not resetting slowdown on team change or player death (optimization).

1.6 (15-Jul-2020)
	- Optionally added left4dhooks forwards "L4D_OnGetCrouchTopSpeed" and "L4D_OnGetWalkTopSpeed" to modify speed when walking or crouched.
	- Uncomment the section and recompile if you want to enable. Only required to slowdown players more than default.
	- Thanks to "SilentBr" for reporting.

1.5 (10-May-2020)
	- Added Traditional Chinese and Simplified Chinese translations. Thanks to "fbef0102".
	- Extra checks to prevent "IsAllowedGameMode" throwing errors.
	- Various changes to tidy up code.

1.4 (10-Apr-2020)
	- Added Hungarian translations. Thanks to "KasperH" for providing.
	- Added Russian translations. Thanks to "Dragokas" for updating with new phrases.
	- Added cvar "l4d_anti_rush_incapped" to ignored incapped players from being used to calculate rushers or slackers distance.
	- Added cvars "l4d_anti_rush_warn_last" and "l4d_anti_rush_warn_lead" to warn players about being teleported or slowed down.
	- Added cvar "l4d_anti_rush_warn_time" to control how often someone is warned.
	- Removed minimum value being set for "l4d_anti_rush_range_lead" cvar which prevented turning off lead feature.
	- The cvars "l4d_anti_rush_range_last" and "l4d_anti_rush_range_lead" minimum values are now set internally (1500.0).
	- Translation files and plugin updated.

1.3 (09-Apr-2020)
	- Added reset slowdown in case players are out-of-bound or have invalid flow distances to calculate the range.
	- Increased minimum value of "l4d_anti_rush_range_lead" cvar from 500.0 to 1000.0.
	- Removed minimum value being set for "l4d_anti_rush_range_last" cvar. Thanks to "Alex101192" for reporting.

1.2 (08-Apr-2020)
	- Added cvar "l4d_anti_rush_finale" to allow or disallow the plugin in finales.

1.1 (07-Apr-2020)
	- Changed how the plugin functions. Now calculates rushers/slackers by their flow distance to the nearest half of Survivors.
	- Fixed not accounting for multiple rushers with "type 2" setting.
	- Fixed "IsAllowedGameMode" from throwing errors when the "_tog" cvar was changed before MapStart.

======================================================================================*/

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
//#include <sdktools>
//#include <sdkhooks>
#include <left4dhooks>

#if DEBUG_BENCHMARK
#include <profiler>
Handle g_Prof;
float g_fBenchMin;
float g_fBenchMax;
float g_fBenchAvg;
float g_iBenchTicks;
#endif

#define CVAR_FLAGS			FCVAR_NOTIFY
#define MINIMUM_RANGE		1500.0			// Minimum range for last and lead cvars.
#define EVENTS_CONFIG		"data/l4d_anti_rush.cfg"
#define LIMP_WALK_SPEED		85.0			// 黄血(瘸腿)移动速度 = 引擎 cvar "survivor_limp_walk_speed" 默认值 (survivor_limp_health = 40 以下进入瘸腿).

ConVar g_hCvarAllow, g_hCvarMPGameMode, g_hCvarModes, g_hCvarModesOff, g_hCvarModesTog, g_hCvarFinale, g_hCvarFlags, g_hCvarIgnore, g_hCvarIncap, g_hCvarPlayers, g_hCvarRangeLast, g_hCvarRangeLead, g_hCvarSlow, g_hCvarTank, g_hCvarType, g_hCvarWarnLast, g_hCvarWarnLead, g_hCvarWarnTime, g_hCvarLimpSpeed;
float g_fCvarRangeLast, g_fCvarRangeLead, g_fCvarSlow, g_fCvarWarnLast, g_fCvarWarnLead, g_fCvarWarnTime;
int g_iCvarFinale, g_iCvarFlags, g_iCvarIgnore, g_iCvarIncap, g_iCvarPlayers, g_iCvarTank, g_iCvarType;
bool g_bCvarAllow, bCvarAllow, g_bMapStarted, g_bLeft4Dead2;

bool g_bInhibit[MAXPLAYERS+1];
float g_fExecute[MAXPLAYERS+1], g_fHintWarn[MAXPLAYERS+1], g_fLastFlow[MAXPLAYERS+1];
float g_fPos[3];
Handle g_hTimer;

char g_sMap[PLATFORM_MAX_PATH];
bool g_bFoundMap;
bool g_bEventStarted;
float g_fEventExtended;

ArrayList g_hElevators;

// ====================================================================================================
//					PLUGIN INFO / START / END
// ====================================================================================================
public Plugin myinfo =
{
	name = "[L4D & L4D2] Anti Rush (12v12)",
	author = "SilverShot, X光",
	description = "Slowdown or teleport rushers and slackers back to the group. Uses flow distance for accuracy. 12v12 定制: 限速值取黄血瘸腿速度, 坦克存活时暂停.",
	version = PLUGIN_VERSION,
	url = "https://forums.alliedmods.net/showthread.php?t=322392"
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	EngineVersion test = GetEngineVersion();

	if (test == Engine_Left4Dead)
		g_bLeft4Dead2 = false;
	else if (test == Engine_Left4Dead2)
		g_bLeft4Dead2 = true;
	else
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 1 & 2.");
		return APLRes_SilentFailure;
	}

	return APLRes_Success;
}

public void OnPluginStart()
{
	RegAdminCmd("sm_fpt", CmdAntiRush, ADMFLAG_ROOT, "插件开关.");
	CreateConVar("l4d_anti_rush_version", PLUGIN_VERSION, "Anti Rush plugin version.", FCVAR_NOTIFY|FCVAR_DONTRECORD);

	g_hCvarAllow =		CreateConVar("l4d_anti_rush_allow",			"1",							"0=插件关闭, 1=插件启用.", CVAR_FLAGS);
	g_hCvarModes =		CreateConVar("l4d_anti_rush_modes",			"",								"在这些游戏模式下打开插件, 并用逗号分隔开(无=空格), (空=全部).", CVAR_FLAGS);
	g_hCvarModesOff =	CreateConVar("l4d_anti_rush_modes_off",		"",								"在这些游戏模式下, 请关闭插件, 并以逗号分隔(无=空格), (空=无).", CVAR_FLAGS);
	g_hCvarModesTog =	CreateConVar("l4d_anti_rush_modes_tog",		"0",							"在这些游戏模式下启用插件. 0=所有, 1=战役, 2=生还者, 4=对抗, 8=清道夫. 同时启用将数字加起来.", CVAR_FLAGS);
	g_hCvarFinale =		CreateConVar("l4d_anti_rush_finale",		g_bLeft4Dead2 ? "1" : "0",		"该插件是否在救援关激活.0=关闭, 1=所有结局, 2=Gauntlet type finales (L4D2 only).", CVAR_FLAGS);
	g_hCvarFlags =		CreateConVar("l4d_anti_rush_flags",			"",								"带有Z标志的玩家将不会在落后时向前移动或在前进时减慢移动速度.", CVAR_FLAGS);
	g_hCvarIgnore =		CreateConVar("l4d_anti_rush_ignore",		"0",							"带有免疫标志的玩家是否应计入总移动距离. 0=忽略它们, 1=包括它们.", CVAR_FLAGS);
	g_hCvarIncap =		CreateConVar("l4d_anti_rush_incapped",		"0",							"0=关闭. 在计算反跑图中有多少幸存者必须检测在忽略他们之前.", CVAR_FLAGS);
	g_hCvarPlayers =	CreateConVar("l4d_anti_rush_players",		"3",							"该功能启动之前的存活幸存者最少数量. 必须为3或更大, 否则无法检测到跑图/落后的平均值. (即存活人数低于这个数插件自动失效).", CVAR_FLAGS, true, 3.0);
	g_hCvarRangeLast =	CreateConVar("l4d_anti_rush_range_last",	"2500.0",						"0.0=关闭. 某人在被传送之前可以落后幸存者的平均距离多远.", CVAR_FLAGS);
	g_hCvarRangeLead =	CreateConVar("l4d_anti_rush_range_lead",	"3000.0",						"0.0=关闭. 某人在被传送或减速之前可以领先幸存者的平均距离多远.", CVAR_FLAGS, true, MINIMUM_RANGE);
	g_hCvarSlow =		CreateConVar("l4d_anti_rush_slow",			"85.0",							"跑图玩家减速时能走动的最大速度. 默认 85.0 = 黄血瘸腿速度 (引擎 cvar \"survivor_limp_walk_speed\").", CVAR_FLAGS, true, 20.0);
	g_hCvarTank =		CreateConVar("l4d_anti_rush_tanks",			"0",							"0=坦克存活时暂停防跑图(默认, 不限速不传送). 1=坦克在场也照常执行.", CVAR_FLAGS);
	g_hCvarType =		CreateConVar("l4d_anti_rush_type",			"1",							"对于跑图领先的玩家怎么处罚. 1=当跑图玩家向前冲时降低他们的移动速度. 2=传送回团队.", CVAR_FLAGS);
	g_hCvarWarnLast =	CreateConVar("l4d_anti_rush_warn_last",		"2000.0",						"0.0=关闭. 在被提示并执行传送前, 玩家能落后平均幸存者位置多远距离.", CVAR_FLAGS, true, MINIMUM_RANGE);
	g_hCvarWarnLead =	CreateConVar("l4d_anti_rush_warn_lead",		"2500.0",						"0.0=关闭. 在被提示并执行减速或传送前, 玩家能领先平均幸存者位置多远距离.", CVAR_FLAGS, true, MINIMUM_RANGE);
	g_hCvarWarnTime =	CreateConVar("l4d_anti_rush_warn_time",		"10.0",							"0.0=关闭. 多久提示玩家一次, 当跑图或落后时会被减速或传送.", CVAR_FLAGS);

	//AutoExecConfig(true, "l4d_anti_rush");

	g_hCvarMPGameMode = FindConVar("mp_gamemode");
	g_hCvarMPGameMode.AddChangeHook(ConVarChanged_Allow);
	g_hCvarModes.AddChangeHook(ConVarChanged_Allow);
	g_hCvarModesOff.AddChangeHook(ConVarChanged_Allow);
	g_hCvarModesTog.AddChangeHook(ConVarChanged_Allow);
	g_hCvarAllow.AddChangeHook(ConVarChanged_Allow);
	g_hCvarFinale.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarFlags.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarIgnore.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarIncap.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarPlayers.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarRangeLast.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarRangeLead.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarTank.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarSlow.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarType.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarWarnLast.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarWarnLead.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarWarnTime.AddChangeHook(ConVarChanged_Cvars);

	g_hElevators = new ArrayList();

	// 12v12: 黄血(瘸腿)移动速度, 引擎 cvar, 运行时读取, 避免 cfg 改了 survivor_limp_walk_speed 后限速值不同步.
	g_hCvarLimpSpeed = FindConVar("survivor_limp_walk_speed");

	#if DEBUG_BENCHMARK
	g_Prof = CreateProfiler();
	#endif
}

// ====================================================================================================
//					CVARS
// ====================================================================================================
public void OnConfigsExecuted()
{
	IsAllowed();
}

void ConVarChanged_Allow(Handle convar, const char[] oldValue, const char[] newValue)
{
	IsAllowed();
}

void ConVarChanged_Cvars(Handle convar, const char[] oldValue, const char[] newValue)
{
	GetCvars();
}

void GetCvars()
{
	char sTemp[32];
	g_hCvarFlags.GetString(sTemp, sizeof(sTemp));
	g_iCvarFlags = ReadFlagString(sTemp);
	g_iCvarIgnore = g_hCvarIgnore.IntValue;

	g_iCvarFinale = g_hCvarFinale.IntValue;
	g_iCvarIncap = g_hCvarIncap.IntValue;
	g_iCvarPlayers = g_hCvarPlayers.IntValue;
	g_iCvarTank = g_hCvarTank.IntValue;
	g_fCvarSlow = g_hCvarSlow.FloatValue;
	g_iCvarType = g_hCvarType.IntValue;
	g_fCvarRangeLast = g_hCvarRangeLast.FloatValue;
	g_fCvarRangeLead = g_hCvarRangeLead.FloatValue;
	g_fCvarWarnLast = g_hCvarWarnLast.FloatValue;
	g_fCvarWarnLead = g_hCvarWarnLead.FloatValue;
	g_fCvarWarnTime = g_hCvarWarnTime.FloatValue;

	// 12v12: 限速上限 = 黄血(瘸腿)速度 survivor_limp_walk_speed (引擎默认 85), 运行时同步, 防止 cfg 改过该值后不同步.
	if (g_hCvarLimpSpeed == null)
		g_hCvarLimpSpeed = FindConVar("survivor_limp_walk_speed");

	float fLimp = g_hCvarLimpSpeed != null ? g_hCvarLimpSpeed.FloatValue : LIMP_WALK_SPEED;

	if (fLimp > 0.0 && g_fCvarSlow > fLimp)
		g_fCvarSlow = fLimp;

	if (g_fCvarRangeLast && g_fCvarRangeLast < MINIMUM_RANGE)
		g_fCvarRangeLast = MINIMUM_RANGE;

	if (g_fCvarRangeLead && g_fCvarRangeLead < MINIMUM_RANGE)
		g_fCvarRangeLead = MINIMUM_RANGE;

	if (g_fCvarWarnLast && g_fCvarWarnLast < MINIMUM_RANGE)
		g_fCvarWarnLast = MINIMUM_RANGE;

	if (g_fCvarWarnLead && g_fCvarWarnLead < MINIMUM_RANGE)
		g_fCvarWarnLead = MINIMUM_RANGE;
}

void IsAllowed()
{
	bCvarAllow = g_hCvarAllow.BoolValue;
	bool bAllowMode = IsAllowedGameMode();
	GetCvars();

	if (g_bCvarAllow == false && bCvarAllow == true && bAllowMode == true)
	{
		g_bCvarAllow = true;

		HookEvent("round_start",				Event_RoundStart);
		HookEvent("round_end",					Event_RoundEnd);
		HookEvent("finale_win",					Event_RoundEnd);
		HookEvent("finale_vehicle_leaving",		Event_RoundEnd);
		HookEvent("player_death",				Event_PlayerDeath);
		HookEvent("player_team",				Event_PlayerTeam);

		Event_RoundStart(null, "", false);
	}

	else if (g_bCvarAllow == true && (bCvarAllow == false || bAllowMode == false))
	{
		g_bCvarAllow = false;

		UnhookEvent("round_start",				Event_RoundStart);
		UnhookEvent("round_end",				Event_RoundEnd);
		UnhookEvent("finale_win",				Event_RoundEnd);
		UnhookEvent("finale_vehicle_leaving",	Event_RoundEnd);
		UnhookEvent("player_death",				Event_PlayerDeath);
		UnhookEvent("player_team",				Event_PlayerTeam);

		ResetSlowdown();
		ResetPlugin();
	}
}

int g_iCurrentMode;
public void L4D_OnGameModeChange(int gamemode)
{
	g_iCurrentMode = gamemode;
}

bool IsAllowedGameMode()
{
	if (g_hCvarMPGameMode == null)
		return false;

	int iCvarModesTog = g_hCvarModesTog.IntValue;
	if (iCvarModesTog != 0)
	{
		if (g_iCurrentMode == 0)
			g_iCurrentMode = L4D_GetGameModeType();

		if (g_iCurrentMode == 0)
			return false;

		switch (g_iCurrentMode) // Left4DHooks values are flipped for these modes, sadly
		{
			case 2:
				g_iCurrentMode = 4;
			case 4:
				g_iCurrentMode = 2;
		}

		if (!(iCvarModesTog & g_iCurrentMode))
			return false;
	}

	char sGameModes[64], sGameMode[64];
	g_hCvarMPGameMode.GetString(sGameMode, sizeof(sGameMode));
	Format(sGameMode, sizeof(sGameMode), ",%s,", sGameMode);

	g_hCvarModes.GetString(sGameModes, sizeof(sGameModes));
	if (sGameModes[0])
	{
		Format(sGameModes, sizeof(sGameModes), ",%s,", sGameModes);
		if (StrContains(sGameModes, sGameMode, false) == -1)
			return false;
	}

	g_hCvarModesOff.GetString(sGameModes, sizeof(sGameModes));
	if (sGameModes[0])
	{
		Format(sGameModes, sizeof(sGameModes), ",%s,", sGameModes);
		if (StrContains(sGameModes, sGameMode, false) != -1)
			return false;
	}

	return true;
}

Action CmdAntiRush(int client, int args)
{
	g_hCvarAllow.BoolValue = !bCvarAllow;
	PrintToChat(client, "\x04[提示]\x05防跑图功能已\x03%s\x05.", bCvarAllow ? "开启" : "关闭");

	return Plugin_Handled;
}

// ====================================================================================================
//					HOOK CUSTOM ARLARM EVENTS
// ====================================================================================================
int g_iSectionLevel;

void LoadEventConfig()
{
	g_bFoundMap = false;

	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), EVENTS_CONFIG);

	if (FileExists(sPath))
		ParseConfigFile(sPath);
}

bool ParseConfigFile(const char[] file)
{
	SMCParser parser = new SMCParser();
	SMC_SetReaders(parser, ColorConfig_NewSection, ColorConfig_KeyValue, ColorConfig_EndSection);
	parser.OnEnd = ColorConfig_End;

	char error[128];
	int line = 0, col = 0;
	SMCError result = parser.ParseFile(file, line, col);

	if (result != SMCError_Okay)
	{
		parser.GetErrorString(result, error, sizeof(error));
		SetFailState("%s on line %d, col %d of %s [%d]", error, line, col, file, result);
	}

	delete parser;
	return (result == SMCError_Okay);
}

SMCResult ColorConfig_NewSection(Handle parser, const char[] section, bool quotes)
{
	g_iSectionLevel++;

	// Map
	if (g_iSectionLevel == 2 && strcmp(section, g_sMap) == 0)
		g_bFoundMap = true;
	else
		g_bFoundMap = false;

	return SMCParse_Continue;
}

SMCResult ColorConfig_KeyValue(Handle parser, const char[] key, const char[] value, bool key_quotes, bool value_quotes)
{
	// On / Off
	if (g_iSectionLevel == 2 && g_bFoundMap)
	{
		if (strcmp(key, "add") == 0)
			g_fEventExtended = StringToFloat(value);
		else
		{
			static char sSplit[3][64];

			int len = ExplodeString(value, ":", sSplit, sizeof(sSplit), sizeof(sSplit[]));
			if (len != 3)
				LogError("Malformed string in l4d_anti_rush.cfg. Section [%s] key [%s] value [%s].", g_sMap, key, value);
			else
			{
				int entity = FindByClassTargetName(sSplit[0], sSplit[1]);
				if (entity != INVALID_ENT_REFERENCE)
				{
					if (strcmp(key, "1") == 0)
						HookSingleEntityOutput(entity, sSplit[2], OutputStart);
					else if (strcmp(key, "0") == 0)
						HookSingleEntityOutput(entity, sSplit[2], OutputStop);
				}
			}
		}
	}

	return SMCParse_Continue;
}

void OutputStart(const char[] output, int caller, int activator, float delay)
{
	g_bEventStarted = true;
}

void OutputStop(const char[] output, int caller, int activator, float delay)
{
	g_bEventStarted = false;
}


SMCResult ColorConfig_EndSection(Handle parser)
{
	g_iSectionLevel--;
	return SMCParse_Continue;
}

void ColorConfig_End(Handle parser, bool halted, bool failed)
{
	if (failed)
		SetFailState("Error: Cannot load the config file: \"%s\"", EVENTS_CONFIG);
}

int FindByClassTargetName(const char[] sClass, const char[] sTarget)
{
	char sName[64];
	int entity = INVALID_ENT_REFERENCE;

	// Is targetname numeric?
	bool numeric = true;
	for (int i = 0; i < strlen(sTarget); i++)
	{
		if (IsCharNumeric(sTarget[i]) == false)
		{
			numeric = false;
			break;
		}
	}

	// Search by hammer ID or targetname
	while ((entity = FindEntityByClassname(entity, sClass)) != INVALID_ENT_REFERENCE)
	{
		if (numeric)
		{
			if (GetEntProp(entity, Prop_Data, "m_iHammerID") == StringToInt(sTarget))
				return entity;
		}
		else
		{
			GetEntPropString(entity, Prop_Data, "m_iName", sName, sizeof(sName));
			if (strcmp(sTarget, sName) == 0)
				return entity;
		}
	}

	return INVALID_ENT_REFERENCE;
}

// ====================================================================================================
//					EVENTS
// ====================================================================================================
void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	delete g_hTimer;

	// Finales allowed, or not finale
	if (g_iCvarFinale || (g_iCvarFinale == 0 && L4D_IsMissionFinalMap() == false))
	{
		// Gauntlet finale only
		if (g_iCvarFinale == 2 && g_bLeft4Dead2)
		{
			int entity = FindEntityByClassname(-1, "trigger_finale");
			if (entity != -1)
			{
				if (GetEntProp(entity, Prop_Data, "m_type") != 1)
					return;
			}
		}

		g_hTimer = CreateTimer(1.0, TimerTest, _, TIMER_REPEAT);

		LoadEventConfig();
	}

	// Get elevators
	// .Clear() is creating a memory leak
	// g_hElevators.Clear();
	delete g_hElevators;
	g_hElevators = new ArrayList();

	int entity = -1;
	while ((entity = FindEntityByClassname(entity, "func_elevator")) != INVALID_ENT_REFERENCE)
	{
		g_hElevators.Push(EntIndexToEntRef(entity));
	}
}

void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	ResetSlowdown();
	ResetPlugin();
}

void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	if (client)
		ResetClient(client);
}

void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	if (client)
		ResetClient(client);
}

public void OnMapStart()
{
	GetCurrentMap(g_sMap, sizeof(g_sMap));
	g_bMapStarted = true;
}

public void OnMapEnd()
{
	g_bMapStarted = false;
	ResetPlugin();
}

void ResetPlugin()
{
	for (int i = 1; i <= MAXPLAYERS; i++)
	{
		ResetClient(i);
	}

	delete g_hTimer;

	// .Clear() is creating a memory leak
	// g_hElevators.Clear();
	delete g_hElevators;
	g_hElevators = new ArrayList();

	g_fEventExtended = 0.0;
	g_bEventStarted = false;
}

void ResetClient(int i)
{
	g_bInhibit[i] = false;
	g_fExecute[i] = 0.0;
	g_fHintWarn[i] = 0.0;
	g_fLastFlow[i] = 0.0;

	SDKUnhook(i, SDKHook_PreThinkPost, PreThinkPost);
}

void ResetSlowdown()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (g_bInhibit[i] && IsClientInGame(i))
		{
			SDKUnhook(i, SDKHook_PreThinkPost, PreThinkPost);
		}

		g_bInhibit[i] = false;
	}
}

bool FlowJudgment()
{
	static int client;
	static float flow;
	flow = (client = L4D_GetHighestFlowSurvivor()) != -1 ? L4D2Direct_GetFlowDistance(client) : L4D2_GetFurthestSurvivorFlow();
	if (flow / L4D2Direct_GetMapMaxFlowDistance() * 100 > 0.0)
		return true;

	return false;
}

// ====================================================================================================
//					LOGIC
// ====================================================================================================
Action TimerTest(Handle timer)
{
	if (!g_bMapStarted || !FlowJudgment())
		return Plugin_Continue;

	#if DEBUG_BENCHMARK
	StartProfiling(g_Prof);
	#endif

	// 12v12: 坦克存活时完全不限速/不传送 (默认 l4d_anti_rush_tanks=0; bTanks 记录状态, 首次检测到坦克时解除已有减速).
	static bool bTanks;
	if (g_iCvarTank == 0)
	{
		if (L4D2_GetTankCount() > 0)
		{
			if (!bTanks)
			{
				bTanks = true;
				ResetSlowdown();
			}
			return Plugin_Continue;
		}
		else
			bTanks = false;
	}

	float flow;
	int count, countflow, index;

	// Get survivors flow distance
	ArrayList aList = new ArrayList(2);

	// Account for incapped
	int clients[MAXPLAYERS+1];
	int incapped, client;

	// Check valid survivors, count incapped
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i))
		{
			// Immune players - ignore from flow calculations
			if (g_iCvarFlags != 0 && g_iCvarIgnore == 0 && CheckCommandAccess(i, "", g_iCvarFlags, true))
			{
				continue;
			}

			// Count
			clients[count++] = i;

			if (g_iCvarIncap)
			{
				if (GetEntProp(i, Prop_Send, "m_isIncapacitated", 1))
					incapped++;
			}
		}
	}

	for (int i = 0; i < count; i++)
	{
		client = clients[i];
		// Ignore incapped
		if (g_iCvarIncap && incapped >= g_iCvarIncap && GetEntProp(client, Prop_Send, "m_isIncapacitated", 1))
			continue;

		// Ignore healing / using stuff
		if (g_bLeft4Dead2 && GetEntPropEnt(client, Prop_Send, "m_useActionTarget") > 0)
			continue;

		// Ignore reviving
		if (GetEntPropEnt(client, Prop_Send, "m_reviveOwner") > 0 || GetEntPropEnt(client, Prop_Send, "m_reviveTarget") > 0)
			continue;

		// Ignore pinned by Charger
		if (g_bLeft4Dead2 && GetEntPropEnt(client, Prop_Send, "m_carryAttacker") != -1)
			continue;

		// Ignore in Elevator
		int lift = GetEntPropEnt(client, Prop_Send, "m_hGroundEntity");

		if (lift > MaxClients)
		{
			lift = EntIndexToEntRef(lift);
			if (g_hElevators.FindValue(lift) != -1)
				continue;
		}

		// Get flow
		flow = L4D2Direct_GetFlowDistance(client);
		if (flow && flow != -9999.0) // Invalid flows
		{
			countflow++;
			index = aList.Push(flow);
			aList.Set(index, client, 1);
		}
		// Reset slowdown if players flow is invalid
		else if (g_bInhibit[client] == true)
		{
			g_bInhibit[client] = false;
			SDKUnhook(client, SDKHook_PreThinkPost, PreThinkPost);
		}
	}

	// In case not enough players or some have invalid flow distance, we still need an average.
	if (countflow >= g_iCvarPlayers)
	{
		aList.Sort(Sort_Descending, Sort_Float);

		int clientAvg;
		float lastFlow;
		float distance;

		// Detect rushers
		if (g_fCvarRangeLead)
		{
			// Loop through survivors from highest flow
			for (int i = 0; i < countflow; i++)
			{
				client = aList.Get(i, 1);
				// Immune players
				if (g_iCvarFlags != 0 && g_iCvarIgnore == 1 && CheckCommandAccess(client, "", g_iCvarFlags, true))
				{
					continue;
				}

				bool flowBack = true;
				// Only check nearest half of survivor pack.
				if (i < countflow / 2)
				{
					flow = aList.Get(i, 0);
					// Loop through from next survivor to mid-way through the pack.
					for (int x = i + 1; x <= countflow / 2; x++)
					{
						lastFlow = aList.Get(x, 0);
						distance = flow - lastFlow;
						if (g_bEventStarted) distance -= g_fEventExtended;

						// Warn ahead hint
						if (g_fCvarWarnTime && g_fCvarWarnLead && distance > g_fCvarWarnLead && distance < g_fCvarRangeLead && g_fHintWarn[client] < GetGameTime())
						{
							g_fHintWarn[client] = GetGameTime() + g_fCvarWarnTime;

							if (g_iCvarType == 1)
								PrintToChat(client, "\x04[提示]\x05你\x03领先\x05幸存者队伍太远\x03请回退\x05,否则将被限速.");
							else
								PrintToChat(client, "\x04[提示]\x05你\x03领先\x05幸存者队伍太远\x03请回退\x05,否则将被传送遣返.");
						}

						// Compare higher flow with next survivor, they're rushing
						if (distance > g_fCvarRangeLead)
						{
							// PrintToServer("RUSH: %N %f", client, distance);
							flowBack = false;
							// Slowdown enabled?
							if (g_iCvarType == 1)
							{
								// Inhibit moving forward
								// Only check > or < because when == the same flow distance, they're either already being slowed or running back, so we don't want to change/affect them within the same flow NavMesh.
								if (flow > g_fLastFlow[client])
								{
									g_fLastFlow[client] = flow;

									if (g_iCvarType == 1 && g_bInhibit[client] == false)
									{
										g_bInhibit[client] = true;
										SDKHook(client, SDKHook_PreThinkPost, PreThinkPost);
									}

									if (g_fExecute[client] < GetGameTime())
									{
										g_fExecute[client] = GetGameTime() + g_fCvarWarnTime;
										PrintToChat(client, "\x04[提示]\x05你\x03领先\x05幸存者队伍太远\x04已限速\x05,请回退队伍.");
									}
								}
								else if (flow < g_fLastFlow[client])
								{
									flowBack = true;
									g_fLastFlow[client] = flow;
								}
							}

							// Teleport enabled?
							if (g_iCvarType == 2 && SurvivorsState(client) && !SurvivorsUnderControl(client))
							{
								clientAvg = aList.Get(x, 1);
								float vPos[3];
								GetClientAbsOrigin(clientAvg, vPos);
								SetEntProp(client, Prop_Send, "m_bDucked", 1);
								SetEntityFlags(client, GetEntityFlags(client)|FL_DUCKING);
								TeleportEntity(client, vPos, NULL_VECTOR, NULL_VECTOR);
								PrintToChat(client, "\x04[提示]\x05你\x03领先\x05幸存者队伍太远,\x04已传送\x05回队伍.");
							}
							break;
						}
					}
				}

				// Running back, allow full speed
				if (flowBack && g_bInhibit[client] == true)
				{
					g_bInhibit[client] = false;
					SDKUnhook(client, SDKHook_PreThinkPost, PreThinkPost);
				}
			}
		}

		// Teleport slacker
		if (g_fCvarRangeLast)
		{
			// Loop through survivors from lowest flow to mid-way through the pack.
			for (int i = countflow - 1; i > countflow / 2; i--)
			{
				client = aList.Get(i, 1);
				// Immune players
				if (g_iCvarFlags != 0 && g_iCvarIgnore == 1 && CheckCommandAccess(client, "", g_iCvarFlags, true))
				{
					continue;
				}

				flow = aList.Get(i, 0);
				// Loop through from next survivor to mid-way through the pack.
				for (int x = i - 1; x < countflow; x++)
				{
					lastFlow = aList.Get(x, 0);
					distance = lastFlow - flow;
					if (g_bEventStarted)
						distance -= g_fEventExtended;

					// Warn behind hint
					if (g_fCvarWarnTime && g_fCvarWarnLast && distance > g_fCvarWarnLast && distance < g_fCvarRangeLast && g_fHintWarn[client] < GetGameTime())
					{
						g_fHintWarn[client] = GetGameTime() + g_fCvarWarnTime;
						PrintToChat(client, "\x04[提示]\x05你\x03落后\x05幸存者队伍太远\x03请加速\x05,尽快跟上队伍.");
					}

					// Compare lower flow with next survivor, they're behind
					if (distance > g_fCvarRangeLast && SurvivorsState(client) && !SurvivorsUnderControl(client) && g_fExecute[client] < GetGameTime())
					{
						// PrintToServer("SLOW: %N %f", client, distance);
						g_fExecute[client] = GetGameTime() + g_fCvarWarnTime;
						clientAvg = aList.Get(x, 1);
						float vPos[3];
						GetClientAbsOrigin(clientAvg, vPos);

						g_fPos = vPos;
						BackwardTransmissionMenu(client);
						PrintToChat(client, "\x04[提示]\x05你\x03落后\x05幸存者队伍太远,使用\x04菜单\x05选择传送.");
						break;
					}
				}
			}
		}
	}
	else
		ResetSlowdown();

	delete aList;

	#if DEBUG_BENCHMARK
	StopProfiling(g_Prof);
	float speed = GetProfilerTime(g_Prof);

	if (speed < g_fBenchMin)
		g_fBenchMin = speed;

	if (speed > g_fBenchMax)
		g_fBenchMax = speed;

	g_fBenchAvg += speed;
	g_iBenchTicks++;

	PrintToServer("Anti Rush benchmark: %f (Min %f. Avg %f. Max %f)", speed, g_fBenchMin, g_fBenchAvg / g_iBenchTicks, g_fBenchMax);
	#endif

	return Plugin_Continue;
}

void BackwardTransmissionMenu(int client)
{
	Menu menu = new Menu(BackwardTransmissionHandleMenu);

	menu.SetTitle("落后传送回队伍");
	menu.AddItem("", "确定");
	menu.AddItem("", "取消");

	menu.ExitButton = true;
	menu.Display(client, 30);
}

int BackwardTransmissionHandleMenu(Menu menu, MenuAction action, int client, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			if (param2 == 0 && IsPlayerAlive(client))
			{
				if (SurvivorsState(client) && !SurvivorsUnderControl(client))
				{
					SetEntProp(client, Prop_Send, "m_bDucked", 1);
					SetEntityFlags(client, GetEntityFlags(client)|FL_DUCKING);
					TeleportEntity(client, g_fPos, NULL_VECTOR, NULL_VECTOR);
					PrintToChat(client, "\x04[提示]\x05你已\x04传送\x05回幸存者队伍.");
				}
				else
				{
					BackwardTransmissionMenu(client);
					PrintToChat(client, "\x04[提示]\x03正常状态\x05才能使用传送功能.");
				}
			}
		}
		case MenuAction_End:
			delete menu;
	}

	return 0;
}

void PreThinkPost(int client)
{
	SetEntPropFloat(client, Prop_Send, "m_flMaxspeed", g_fCvarSlow);
}

bool SurvivorsState(int client)
{
	return !GetEntProp(client, Prop_Send, "m_isIncapacitated") && !GetEntProp(client, Prop_Send, "m_isHangingFromLedge");
}

bool SurvivorsUnderControl(int client)
{
	if (GetEntPropEnt(client, Prop_Send, "m_tongueOwner") > 0)
		return true;

	if (GetEntPropEnt(client, Prop_Send, "m_pounceAttacker") > 0)
		return true;

	if (GetEntPropEnt(client, Prop_Send, "m_jockeyAttacker") > 0)
		return true;

	if (GetEntPropEnt(client, Prop_Send, "m_carryAttacker") > 0 || GetEntPropEnt(client, Prop_Send, "m_pummelAttacker") > 0)
		return true;

	return false;
}