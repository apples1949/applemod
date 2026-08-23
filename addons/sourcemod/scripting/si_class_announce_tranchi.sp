#include <sourcemod>
#include <colors>
#undef REQUIRE_PLUGIN
#include <readyup>
#define REQUIRE_PLUGIN

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.0.6"

public Plugin myinfo =
{
    name = "Special Infected Class Announce (tranchi)",
    author = "apples1949",
    description = "Report what SI classes are up when the round starts.",
    version = PLUGIN_VERSION,
    url = "none"
}

// tranchi 修正版：
// 原版 ProcessSIString 用 %T + LANG_SERVER 取聊天前缀，服务器语言为 en 时
// 中文翻译(translations/chi/)永远不生效。现改为按接收者客户端语言取前缀：
// 中文客户端看到"特殊感染者: "，英文客户端看到"Special Infected: "。
// readyup 底部(footer)是共享字符串，仍用服务器语言(LANG_SERVER)。

#define ZC_SMOKER               1
#define ZC_BOOMER               2
#define ZC_HUNTER               3
#define ZC_SPITTER              4
#define ZC_JOCKEY               5
#define ZC_CHARGER              6
#define ZC_WITCH                7
#define ZC_TANK                 8

#define TEAM_SPECTATOR			1
#define TEAM_SURVIVOR			2
#define TEAM_INFECTED			3

#define MAXSPAWNS               8

#define CHAT_FLAG        (1 << 0)
#define HINT_FLAG        (1 << 1)

static const char g_csSIClassName[][] =
{
	"",
	"Smoker",
	"(Boomer)",
	"Hunter",
	"(Spitter)",
	"Jockey",
	"Charger",
	"",
	""
};

Handle
	g_hAddFooterTimer;
	
ConVar
	g_hCvarFooter,
	g_hCvarPrint;
	
bool
	g_bRoundStarted,
	g_bAllowFooter,
	g_bMessagePrinted;

public void OnPluginStart()
{
	LoadTranslation("si_class_announce.phrases");
	g_hCvarFooter	= CreateConVar(	"si_announce_ready_footer",
									"1",
									"Enable si class string be added to readyup panel as footer (if available).",
									FCVAR_NOTIFY, true, 0.0, true, 1.0);
	
	g_hCvarPrint	= CreateConVar(	"si_announce_print",
									"1",
									"Decide where the plugin prints the announce. (0: Disable, 1: Chat, 2: Hint, 3: Chat and Hint)",
									FCVAR_NOTIFY, true, 0.0, true, 3.0);
									
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
	HookEvent("player_left_start_area", Event_PlayerLeftStartArea, EventHookMode_Post);
	HookEvent("player_team", Event_PlayerTeam);
}

public void OnMapEnd()
{
	g_bRoundStarted = false;
}

void ProcessReadyupFooter()
{
	if( GetFeatureStatus(FeatureType_Native, "AddStringToReadyFooter") == FeatureStatus_Available )
	{
		g_hAddFooterTimer = CreateTimer(7.0, UpdateReadyUpFooter, _, TIMER_FLAG_NO_MAPCHANGE);
	}
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	g_bMessagePrinted = false;
	g_bRoundStarted = true;
	
	if (g_hCvarFooter.BoolValue)
	{
		g_bAllowFooter = true;
		ProcessReadyupFooter();
	}
	else
	{
		g_bAllowFooter = false;
	}
}

void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	g_bRoundStarted = false;
}

void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_bAllowFooter) return;
	
	if (!g_bRoundStarted) return;
	
	if (g_hAddFooterTimer != null) return;
	
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!client) return;
	
	if (event.GetInt("team") == TEAM_INFECTED)
	{
		g_hAddFooterTimer = CreateTimer(1.0, UpdateReadyUpFooter, _, TIMER_FLAG_NO_MAPCHANGE);
	}
}

Action UpdateReadyUpFooter(Handle timer)
{
	g_hAddFooterTimer = null;
	
	if (!IsInfectedTeamFullAlive() || !g_bAllowFooter)
		return Plugin_Stop;
	
	int iSpawnClass[MAXSPAWNS];
	int iSpawns = CollectSIClasses(iSpawnClass);
	
	char msg[65];
	if (ProcessSIString(0, iSpawnClass, iSpawns, msg, sizeof(msg), true))
		g_bAllowFooter = !(AddStringToReadyFooter(msg) != -1);

	return Plugin_Stop;
}

public void OnRoundIsLive()
{
	if (g_hCvarPrint.IntValue == 0)
		return;
	
	// announce SI classes up now
	int iSpawnClass[MAXSPAWNS];
	int iSpawns = CollectSIClasses(iSpawnClass);
	if (iSpawns)
	{
		AnnounceSIClasses(iSpawnClass, iSpawns);
		g_bMessagePrinted = true;
	}
}

void Event_PlayerLeftStartArea(Event event, const char[] name, bool dontBroadcast)
{
	// if no readyup, use this as the starting event
	if (!g_bMessagePrinted) {
		int iSpawnClass[MAXSPAWNS];
		int iSpawns = CollectSIClasses(iSpawnClass);
		if (iSpawns && g_hCvarPrint.IntValue != 0)
			AnnounceSIClasses(iSpawnClass, iSpawns);
			
		// no matter printed or not, we won't bother the game since survivor leaves saferoom.
		g_bMessagePrinted = true;
	}
}

#define COLOR_PARAM "%s{red}%s{default}"
#define NORMA_PARAM "%s%s"

/**
 * 收集当前在线的特感职业（排除 Witch/Tank），返回数量。
 * 从原 ProcessSIString 中拆出，与接收者无关，只扫描一次。
 */
int CollectSIClasses(int iSpawnClass[MAXSPAWNS])
{
	// get currently active SI classes
	int iSpawns = 0;
	
	for (int i = 1; i <= MaxClients && iSpawns < MAXSPAWNS; i++) {
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_INFECTED || !IsPlayerAlive(i)) { continue; }
		
		iSpawnClass[iSpawns] = GetEntProp(i, Prop_Send, "m_zombieClass");
		
		if (iSpawnClass[iSpawns] != ZC_WITCH && iSpawnClass[iSpawns] != ZC_TANK)
			iSpawns++;
	}
	
	return iSpawns;
}

/**
 * 构建播报字符串。
 * 聊天前缀按接收者客户端语言取词（client 为实际客户端索引），
 * 中文客户端显示"特殊感染者: "，其余显示"Special Infected: "。
 * readyup 底部(footer)为共享字符串，仍用服务器语言 LANG_SERVER。
 */
bool ProcessSIString(int client, const int[] iSpawnClass, int iSpawns, char[] msg, int maxlength, bool footer = false)
{
	// found nothing :/
	if (iSpawns <= 0) {
		return false;
	}

	char translate[32];

	if(footer)
	{
		FormatEx(translate, sizeof(translate), "%T", "SI", LANG_SERVER);
		strcopy(msg, maxlength, translate);
	}
	else
	{
		// 修正：%T 用接收者语言而非 LANG_SERVER，中文翻译才能按玩家生效
		FormatEx(translate, sizeof(translate), "%T", "SpecialInfected", client);
		strcopy(msg, maxlength, translate);
	}
	
	int printFlags = g_hCvarPrint.IntValue;
	bool useColor = !footer && (printFlags & CHAT_FLAG);
	
	// format classes, according to amount of spawns found
	for (int i = 0; i < iSpawns; i++) {
		if (i) StrCat(msg, maxlength, ", ");
		
		Format(	msg,
				maxlength,
				(useColor ? COLOR_PARAM : NORMA_PARAM),
				msg,
				g_csSIClassName[iSpawnClass[i]]
		);
	}
	
	return true;
}

/**
 * 修正版：不再广播同一份字符串，而是逐接收者按各自语言构建后再发送。
 */
void AnnounceSIClasses(const int[] iSpawnClass, int iSpawns)
{
	int printFlags = g_hCvarPrint.IntValue;
	
	for (int i = 1; i <= MaxClients; i++) {
		if (!IsClientInGame(i) || GetClientTeam(i) == TEAM_INFECTED || (IsFakeClient(i) && !IsClientSourceTV(i))) { continue; }

		char msg[128];
		if (!ProcessSIString(i, iSpawnClass, iSpawns, msg, sizeof(msg)))
			continue;

		if (printFlags & CHAT_FLAG) CPrintToChat(i, msg);
		if (printFlags & HINT_FLAG)
		{
			CRemoveTags(msg, sizeof msg);
			PrintHintText(i, msg);
		}
	}
}

stock bool IsInfectedTeamFullAlive()
{
	static ConVar cMaxZombies;
	if (!cMaxZombies) cMaxZombies = FindConVar("z_max_player_zombies");
	
	int players = 0;
	for (int i = 1; i <= MaxClients; i++) {
		if (IsClientInGame(i) && GetClientTeam(i) == TEAM_INFECTED && IsPlayerAlive(i)) players++;
	}
	return players == cMaxZombies.IntValue;
}

/**
 * Check if the translation file exists
 *
 * @param translation	Translation name.
 * @noreturn
 */
stock void LoadTranslation(const char[] translation)
{
	char
		sPath[PLATFORM_MAX_PATH],
		sName[64];

	FormatEx(sName, sizeof(sName), "translations/%s.txt", translation);
	BuildPath(Path_SM, sPath, sizeof(sPath), sName);
	if (!FileExists(sPath))
		SetFailState("Missing translation file %s.txt", translation);

	LoadTranslations(translation);
}
