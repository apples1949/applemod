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

#define PLUGIN_VERSION 		"1.22-12v12"
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

12v12 1.22 修复:
	- 只在对抗模式运行；按全部有效存活身体的平均 flow 判定，治疗/救人不再改变统计样本。
	- 修复模式掩码缓存翻转；坦克暂停、无效 flow、半场重置统一解除限速。
	- 同步瘸腿速度 CVar，限速只降低速度，不覆盖更低的引擎速度。

12v12 (applemod) - 定制修改:
	- 限速值改为黄血瘸腿速度: 引擎 cvar "survivor_limp_walk_speed" = 85, 故 "l4d_anti_rush_slow" 默认 85.0 (原 100.0).
	  运行时还会读取 survivor_limp_walk_speed, 若它比 l4d_anti_rush_slow 更低则以它为准, 保证限速不超过黄血瘸腿速度.
	- 坦克存活时不限速: "l4d_anti_rush_tanks" 默认值由 1 改为 0 (0=有坦克时暂停防跑图). 需要坦克在场也限速时设为 1.
	- 不生成 cfg (AutoExecConfig 保持注释), 全部行为由代码内默认值决定.
	- 修正 TimerTest 中 CheckCommandAccess 误用未初始化变量 client 的问题.

12v12 (applemod) - 阈值与处罚行为调整:
	- "l4d_anti_rush_range_lead" 默认值 3000.0 -> 1500.0 (更早介入跑图).
	- "l4d_anti_rush_range_last" 默认值 2500.0 -> 0.0, 并重新定义语义:
	  0.0 = 不按距离做落后判定 (默认, 只按 range_lead 判定跑图); 大于 0 时才启用落后判定.
	  原版 "0.0=关闭" 与新默认值是同一含义, 因此不再冲突.
	  注意: range_lead/warn_last/warn_lead 的 CreateConVar 最小值限制已移除, 否则填 0 会被引擎抬到 1500
	  而无法关闭; 非 0 但小于 1500 的值仍在 GetCvars() 内部被抬到 1500 (MINIMUM_RANGE).
	- 倒地(incapacitated)/挂边(hanging from ledge) 的幸存者一律计入队伍平均流距离, 不再豁免:
	  删除原 cvar "l4d_anti_rush_incapped" (原语义为"倒地人数达到 N 人后才开始忽略倒地者",
	  与"倒地者不能被豁免"直接冲突, 且找不到第二种自洽语义); 现在没有任何开关可以把倒地者排除出距离计算.
	- 检测到跑图即刻限速: 去掉原版"必须 flow 比上一 tick 更大才挂限速钩子"的判断
	  (该判断会导致坦克战后 / 有效人数不足后 / 失去 flow 后 g_bInhibit 已清而 g_fLastFlow 仍是旧值,
	  玩家明明在跑图却永远不再被限速). 现在一旦判定领先超过 range_lead, 立刻挂 SDKHook_PreThinkPost
	  并当场写 m_flMaxspeed = l4d_anti_rush_slow (= 瘸腿速度), 不等下一帧、不等警告;
	  每个 tick 结束时统一解除"本 tick 未被判定为跑图"的限速, 不再依赖 flow 增减猜测.
	- 落后玩家不再弹出"落后传送回队伍"菜单: 删除菜单本体 BackwardTransmissionMenu 及其处理函数
	  与全局 g_fPos, 只保留聊天提示. 配合 range_last 默认 0.0, 默认配置下不会出现任何落后传送面板.
	- "l4d_anti_rush_warn_last" / "l4d_anti_rush_warn_lead" 默认值改为 0.0 (关闭预提示):
	  预提示只有在 warn_* < range_* 时才可能触发, 而 range_lead 默认已是紧阈值 1500,
	  内部又有 1500 的最小值抬升, 默认不可能形成预提示区间, 故默认关闭;
	  需要"先提示后处罚"时把 range_lead 调大, 再把 warn_lead 设在两者之间.
	- 聊天提示改为受 warn_time 控制: warn_time = 0 时不再发送任何提示 (原版会在 0 时每次都发).
	- 全部 cvar 说明改写为中文, 写清默认值含义与关闭方式.

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

ConVar g_hCvarAllow, g_hCvarMPGameMode, g_hCvarModes, g_hCvarModesOff, g_hCvarModesTog, g_hCvarFinale, g_hCvarFlags, g_hCvarIgnore, g_hCvarPlayers, g_hCvarRangeLast, g_hCvarRangeLead, g_hCvarSlow, g_hCvarTank, g_hCvarType, g_hCvarWarnLast, g_hCvarWarnLead, g_hCvarWarnTime, g_hCvarLimpSpeed;
float g_fCvarRangeLast, g_fCvarRangeLead, g_fCvarSlow, g_fCvarWarnLast, g_fCvarWarnLead, g_fCvarWarnTime;
int g_iCvarFinale, g_iCvarFlags, g_iCvarIgnore, g_iCvarPlayers, g_iCvarTank, g_iCvarType;
bool g_bCvarAllow, bCvarAllow, g_bMapStarted, g_bLeft4Dead2;

bool g_bInhibit[MAXPLAYERS+1];
float g_fExecute[MAXPLAYERS+1], g_fHintWarn[MAXPLAYERS+1];
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

	g_hCvarAllow =		CreateConVar("l4d_anti_rush_allow",			"1",							"插件总开关. 0=关闭(解除所有限速并停用检测), 1=启用. 默认 1.", CVAR_FLAGS);
	g_hCvarModes =		CreateConVar("l4d_anti_rush_modes",			"",								"白名单: 只在这些游戏模式下启用插件. 逗号分隔多个模式名, 空=不限制. 默认空.", CVAR_FLAGS);
	g_hCvarModesOff =	CreateConVar("l4d_anti_rush_modes_off",		"",								"黑名单: 在这些游戏模式下禁用插件. 逗号分隔多个模式名, 空=无. 默认空.", CVAR_FLAGS);
	g_hCvarModesTog =	CreateConVar("l4d_anti_rush_modes_tog", "4", "模式掩码: 0=不额外限制, 1=战役, 2=生还者, 4=对抗, 8=清道夫. 本构建仅用于对抗模式, 默认 4.", CVAR_FLAGS);
	g_hCvarFinale =		CreateConVar("l4d_anti_rush_finale",		g_bLeft4Dead2 ? "1" : "0",		"救援关是否生效. 0=救援关不生效, 1=全部救援关生效(默认), 2=仅 Gauntlet 类型救援关(L4D2).", CVAR_FLAGS);
	g_hCvarFlags =		CreateConVar("l4d_anti_rush_flags",			"",								"豁免: 拥有这些管理标志位的玩家既不会被限速也不会被传送. 填标志字符串(如 \"z\"), 空=无人豁免. 默认空.", CVAR_FLAGS);
	g_hCvarIgnore =		CreateConVar("l4d_anti_rush_ignore",		"0",							"配合 flags 使用. 0=默认, 被豁免的玩家不计入队伍平均距离; 1=仍把被豁免玩家计入平均距离.", CVAR_FLAGS);
	g_hCvarPlayers =	CreateConVar("l4d_anti_rush_players",		"3",							"检测门槛: 存活幸存者(含倒地/挂边)少于该人数时插件不判定跑图, 并解除全部限速. 最小 3. 默认 3.", CVAR_FLAGS, true, 3.0);
	g_hCvarRangeLast =	CreateConVar("l4d_anti_rush_range_last",	"0.0",							"落后判定距离: 某人落后队伍平均流距离超过多少才算落后. 0.0=不按距离判定落后(默认, 只判定跑图); 大于 0 才启用落后判定, 非 0 值最小 1500.", CVAR_FLAGS);
	g_hCvarRangeLead =	CreateConVar("l4d_anti_rush_range_lead",	"1500.0",						"跑图判定距离: 某人领先队伍平均流距离超过多少即判定为跑图. 0.0=关闭跑图判定; 非 0 值最小 1500. 默认 1500.", CVAR_FLAGS);
	g_hCvarSlow =		CreateConVar("l4d_anti_rush_slow",			"85.0",							"被判定跑图后立即限制到的最大移动速度. 默认 85.0 = 黄血瘸腿速度(引擎 cvar \"survivor_limp_walk_speed\"). 实际生效值不会超过 survivor_limp_walk_speed. 最小 20.0.", CVAR_FLAGS, true, 20.0);
	g_hCvarTank =		CreateConVar("l4d_anti_rush_tanks",			"0",							"坦克存活时是否照常判定. 0=坦克存活时暂停防跑图并解除已有减速(默认), 1=坦克在场也照常限速/传送.", CVAR_FLAGS);
	g_hCvarType =		CreateConVar("l4d_anti_rush_type",			"1",							"跑图处罚方式: 1=立即限速到 l4d_anti_rush_slow(默认), 2=传送回队伍. 两种都不影响落后判定.", CVAR_FLAGS);
	g_hCvarWarnLast =	CreateConVar("l4d_anti_rush_warn_last",		"0.0",							"落后预提示距离: 落后超过该值但未达 range_last 时先发聊天提示. 0.0=关闭(默认); 由于 range_last 默认 0.0, 落后判定默认整体关闭, 本项也随之无效.", CVAR_FLAGS);
	g_hCvarWarnLead =	CreateConVar("l4d_anti_rush_warn_lead",		"0.0",							"跑图预提示距离: 领先超过该值但未达 range_lead 时先发聊天提示. 0.0=关闭(默认); 若 range_lead 用默认 1500, 预提示区间不存在, 无提示.", CVAR_FLAGS);
	g_hCvarWarnTime =	CreateConVar("l4d_anti_rush_warn_time",		"10.0",							"聊天提示的最小间隔(秒). 0.0=完全不发提示. 默认 10.0. 注意: 不影响限速/传送是否生效, 检测到即处罚.", CVAR_FLAGS);

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
	if (g_hCvarLimpSpeed != null)
		g_hCvarLimpSpeed.AddChangeHook(ConVarChanged_Cvars);

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
	if (g_bMapStarted && g_hCvarAllow != null)
		IsAllowed();
}

bool IsAllowedGameMode()
{
	if (g_hCvarMPGameMode == null || !L4D_IsVersusMode())
		return false;

	int iCvarModesTog = g_hCvarModesTog.IntValue;
	if (iCvarModesTog != 0)
	{
		if (g_iCurrentMode == 0)
			g_iCurrentMode = L4D_GetGameModeType();

		if (g_iCurrentMode == 0)
			return false;

		int modeMask = g_iCurrentMode;
		switch (modeMask) // Convert locally; never rewrite the cached Left4DHooks mode.
		{
			case 2:
				modeMask = 4;
			case 4:
				modeMask = 2;
		}

		if (!(iCvarModesTog & modeMask))
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
	ReplyToCommand(client, "[防跑图] 功能已%s。", bCvarAllow ? "开启" : "关闭");

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
	ResetPlugin();
	GetCurrentMap(g_sMap, sizeof(g_sMap));

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

public void OnClientDisconnect(int client)
{
	ResetClient(client);
}

public void OnPluginEnd()
{
	ResetSlowdown();
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
	if (g_bInhibit[i] && i <= MaxClients && IsClientInGame(i))
		SDKUnhook(i, SDKHook_PreThinkPost, PreThinkPost);

	g_bInhibit[i] = false;
	g_fExecute[i] = 0.0;
	g_fHintWarn[i] = 0.0;
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
	if (L4D2Direct_GetMapMaxFlowDistance() > 0.0 && flow > 0.0)
		return true;

	return false;
}

// ====================================================================================================
//					LOGIC
// ====================================================================================================
// Keep every living body in the distance sample. Temporary inability to move
// affects punishment only, never the team's reference distance.
bool CanPunishSurvivor(int client)
{
	if (!IsClientInGame(client) || GetClientTeam(client) != 2 || !IsPlayerAlive(client)
		|| !SurvivorsState(client) || SurvivorsUnderControl(client))
		return false;
	if (GetEntPropEnt(client, Prop_Send, "m_useActionTarget") > 0
		|| GetEntPropEnt(client, Prop_Send, "m_reviveOwner") > 0
		|| GetEntPropEnt(client, Prop_Send, "m_reviveTarget") > 0)
		return false;
	int ground = GetEntPropEnt(client, Prop_Send, "m_hGroundEntity");
	return ground <= MaxClients || g_hElevators.FindValue(EntIndexToEntRef(ground)) == -1;
}

Action TimerTest(Handle timer)
{
	if (!g_bMapStarted || !FlowJudgment() || (g_iCvarTank == 0 && L4D2_GetTankCount() > 0))
	{
		ResetSlowdown();
		return Plugin_Continue;
	}

	#if DEBUG_BENCHMARK
	StartProfiling(g_Prof);
	#endif

	int clients[MAXPLAYERS + 1], count;
	float flows[MAXPLAYERS + 1], totalFlow;
	bool punishable[MAXPLAYERS + 1], rushing[MAXPLAYERS + 1];
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || GetClientTeam(client) != 2 || !IsPlayerAlive(client))
			continue;
		bool immune = g_iCvarFlags != 0 && CheckCommandAccess(client, "", g_iCvarFlags, true);
		if (immune && g_iCvarIgnore == 0)
			continue;
		float flow = L4D2Direct_GetFlowDistance(client);
		if (flow < 0.0) // Zero is a valid start-of-map sample.
			continue;
		clients[count] = client;
		flows[count++] = flow;
		totalFlow += flow;
		punishable[client] = !immune && CanPunishSurvivor(client);
	}

	if (count >= g_iCvarPlayers)
	{
		float averageFlow = totalFlow / float(count);
		float extension = g_bEventStarted ? g_fEventExtended : 0.0;
		float now = GetGameTime();
		for (int i = 0; i < count; i++)
		{
			int client = clients[i];
			if (!punishable[client])
				continue;
			float lead = flows[i] - averageFlow - extension;
			float behind = averageFlow - flows[i] - extension;
			if (g_fCvarRangeLead > 0.0 && lead > g_fCvarRangeLead)
			{
				if (g_iCvarType == 1)
				{
					rushing[client] = true;
					if (!g_bInhibit[client])
					{
						g_bInhibit[client] = true;
						SDKHook(client, SDKHook_PreThinkPost, PreThinkPost);
					}
					PreThinkPost(client);
					if (g_fCvarWarnTime > 0.0 && g_fExecute[client] < now)
					{
						g_fExecute[client] = now + g_fCvarWarnTime;
						PrintToChat(client, "\x04[提示]\x05你领先队伍平均位置太远，已限速，请回退队伍。");
					}
				}
				else if (g_iCvarType == 2)
				{
					// Choose a mobile, unpinned teammate near the mean; never teleport to a hanging body.
					int target;
					float nearest = 999999.0;
					for (int x = 0; x < count; x++)
					{
						float delta = FloatAbs(flows[x] - averageFlow);
						if (clients[x] != client && flows[x] < flows[i] && delta < nearest
							&& CanPunishSurvivor(clients[x]))
						{
							target = clients[x];
							nearest = delta;
						}
					}
					if (target > 0)
					{
						float pos[3];
						GetClientAbsOrigin(target, pos);
						SetEntProp(client, Prop_Send, "m_bDucked", 1);
						SetEntityFlags(client, GetEntityFlags(client) | FL_DUCKING);
						TeleportEntity(client, pos, NULL_VECTOR, NULL_VECTOR);
						if (g_fCvarWarnTime > 0.0 && g_fExecute[client] < now)
						{
							g_fExecute[client] = now + g_fCvarWarnTime;
							PrintToChat(client, "\x04[提示]\x05你领先队伍太远，已传送回队伍。");
						}
					}
				}
			}
			else if (g_fCvarWarnTime > 0.0 && g_fCvarRangeLead > 0.0 && g_fCvarWarnLead > 0.0
				&& lead > g_fCvarWarnLead && g_fHintWarn[client] < now)
			{
				g_fHintWarn[client] = now + g_fCvarWarnTime;
				PrintToChat(client, "\x04[提示]\x05你领先队伍太远，请回退队伍。");
			}
			if (g_fCvarWarnTime > 0.0 && g_fCvarRangeLast > 0.0
				&& (behind > g_fCvarRangeLast || (g_fCvarWarnLast > 0.0 && behind > g_fCvarWarnLast))
				&& g_fExecute[client] < now)
			{
				g_fExecute[client] = now + g_fCvarWarnTime;
				PrintToChat(client, "\x04[提示]\x05你落后队伍太远，请尽快跟上队伍。");
			}
		}
	}
	for (int client = 1; client <= MaxClients; client++)
	{
		if (g_bInhibit[client] && !rushing[client])
			ResetClient(client);
	}

	#if DEBUG_BENCHMARK
	StopProfiling(g_Prof);
	float speed = GetProfilerTime(g_Prof);
	if (speed < g_fBenchMin) g_fBenchMin = speed;
	if (speed > g_fBenchMax) g_fBenchMax = speed;
	g_fBenchAvg += speed;
	g_iBenchTicks++;
	PrintToServer("Anti Rush benchmark: %f (Min %f. Avg %f. Max %f)", speed, g_fBenchMin, g_fBenchAvg / g_iBenchTicks, g_fBenchMax);
	#endif
	return Plugin_Continue;
}

void PreThinkPost(int client)
{
	if (!CanPunishSurvivor(client))
	{
		ResetClient(client);
		return;
	}
	// A cap must not raise an engine/other-plugin speed that is already lower.
	if (GetEntPropFloat(client, Prop_Send, "m_flMaxspeed") > g_fCvarSlow)
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
