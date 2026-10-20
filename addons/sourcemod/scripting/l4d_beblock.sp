/**
 * ============================================================================
 *  [L4D2] 个人屏蔽（语音 / 文字）        sm_bequiet / sm_quite / sm_bizhi / sm_bz
 * ============================================================================
 *  指令（任意一个都能呼出菜单，游戏内用 !bz 也可以）：
 *     sm_bequiet / sm_quite / sm_bizhi / sm_bz
 *
 *  功能：
 *   1. 菜单顶部显示「选择要屏蔽的玩家」，下面列出服务器内全部真人玩家
 *      （只显示玩家名，不含自己与 Bot，不显示屏蔽状态）。
 *   2. 选中某位玩家后显示两行：接收语音 / 接收文字，
 *      行首按当前屏蔽状态显示 [√]（正常接收）或 [×]（已屏蔽）；
 *      再选一次 [×] 那一行即取消屏蔽。
 *   3. 标记为 [×] 之后：不再接收该玩家的语音（SetListenOverride，
 *      只影响自己，不影响别人）与文字聊天（按接收者过滤聊天输出）。
 *   4. 目标与自己不同队、并且没有开启全体语音时，不显示「接收语音」行。
 *   5. 同一队伍的玩家进服后立刻开始说话、并“连续”说满 20 秒
 *      （进服窗口默认 sm_beblock_automute_joinwindow 秒；中途只要停止说话
 *      就重新计时，所以这条只针对开自由麦/一直连麦的人，正常说话会被忽略），
 *      自动把该玩家的语音屏蔽给同队玩家；被屏蔽者本人不受影响。
 *      解除方式有三种：同队玩家自己用 !bz 把这一项改回 [√]；
 *      或该玩家安静满 60 秒自动恢复（AUTOMUTE_QUIET_RESTORE）；
 *      或同队玩家用「解除全部屏蔽」一次清空。
 *      （自动屏蔽同样按 SteamID 记录：该玩家只是断线/换图的话，屏蔽会保留，
 *        等他重新进服仍然是被屏蔽状态，直到上面三种解除之一发生。）
 *
 *  屏蔽状态存放（1.4.0 起：按 SteamID 跨章节保存）：
 *    - 运行期用 g_iBlockFlags[listener][speaker] 按客户端索引加速；
 *    - 权威副本在 StringMap g_hPersist 里：键 "请求者auth|被屏蔽者auth"、值 = 位掩码，
 *      所以换章节 / 半场重开 / 断线重连之后照样认得是同一个人。
 *      （旧版只按索引存，换图必丢：SM 在 LevelShutdown 会对所有在线客户端投递
 *        OnClientDisconnect，旧代码在这里把整张表清空了，详见 OnClientDisconnect 注释。）
 *    - 只存在插件内存里，不写文件、不用数据库、不依赖 clientprefs；
 *      插件重载/服务器重启后清空（有意为之：不落盘，也不跨服务器串数据）。
 *    - auth 取 GetClientAuthId：Steam2 → Steam3 → “名字+IP”兜底
 *      （纯 LAN / 无 Steam 环境；走兜底时改名会被当成另一个人）。
 *    - 记录只在“本人自己解除屏蔽”时删除（菜单改回 [√]、清空全部；
 *      自动屏蔽静默恢复撤掉的是它自己写的那一位，同样按解除处理）。
 *      断线/换图/换服都不删，等本人下次进服自动恢复。
 *    - sm_beblock_persist 0 可退回旧行为（只按索引，换图即失效）。
 *
 *  依赖：
 *    - SourceMod 1.11+（使用 OnClientSpeaking / OnClientSpeakingEnd）
 *    - 可选 hextags：本服聊天由 hextags_lite 统一输出，联用时文字过滤
 *      在它的输出环节生效（见 BeBlock_CanSeeChat native）
 * ============================================================================
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <beblock_voice>
#include <sdktools>
#include <colors>

#define PLUGIN_VERSION "1.4.0"
#define CVAR_FLAGS     FCVAR_NOTIFY

/* 屏蔽状态位 */
#define BLOCK_TEXT   (1 << 0)   /**< 屏蔽文字聊天 */
#define BLOCK_VOICE  (1 << 1)   /**< 屏蔽语音 */
#define BLOCK_AUTO   (1 << 2)   /**< 该语音屏蔽由“进服语音自动屏蔽”写入，安静够久会自动撤销 */

/* 菜单行首标记：√ = 正常接收，× = 已屏蔽 */
#define MARK_RECEIVE "[√]"
#define MARK_BLOCKED "[×]"

/* 菜单项 info */
#define ITEM_VOICE       "v"
#define ITEM_TEXT        "t"
#define ITEM_UNBLOCK_ALL "u"

/* 自动屏蔽（进服语音）判定：必须是“连续”说话，中途一停就重新计时 */
#define AUTOMUTE_SECONDS       20.0   /**< 进服后连续说话达到该秒数即自动屏蔽 */
#define AUTOMUTE_QUIET_RESTORE 60.0   /**< 被自动屏蔽者安静该秒数后自动恢复接收 */
#define AUTOMUTE_INTERVAL       0.5   /**< 说话时长累计检测间隔 */

ConVar g_hCvarEnable, g_hCvarAutoMute, g_hCvarAutoWindow, g_hCvarAllTalk, g_hCvarPersist;

bool  g_bEnable, g_bAutoMute, g_bPersist;
float g_fAutoWindow;

/* 会话状态（按客户端索引的加速副本；权威副本见下面的持久层） */
int  g_iBlockFlags[MAXPLAYERS+1][MAXPLAYERS+1];
int  g_iVoiceOwn[MAXPLAYERS+1][MAXPLAYERS+1];   /**< 本插件下发语音屏蔽时记住的原覆盖值+1，0 = 未下发 */
int  g_iMenuTarget[MAXPLAYERS+1];                /**< 二级菜单正在处理的玩家 userid */

/* ---- 跨章节持久层 ----
   键 = "请求者auth|被屏蔽者auth"，值 = BLOCK_TEXT/BLOCK_VOICE/BLOCK_AUTO 位掩码。
   stringmap 里没有任何“地图/回合”概念，所以换图、半场重开都不会动它；
   只有本人自己解除屏蔽时才会删掉对应键。 */
#define AUTH_KEY_MAX  MAX_AUTHID_LENGTH            /**< 单个 auth 键最大长度（Steam2/Steam3 都远小于它） */
#define FALLBACK_KEY_MAX 160                       /**< “名字+IP”兜底键最大长度 */
#define PAIR_KEY_MAX  (FALLBACK_KEY_MAX * 2 + 2)   /**< "authA|authB" 最大长度 */

StringMap g_hPersist;                              /**< "authA|authB" -> int 位掩码 */
char      g_sAuthKey[MAXPLAYERS+1][FALLBACK_KEY_MAX];  /**< 本次会话的 auth 键，空 = 尚未就绪 */

/* 自动屏蔽（进服语音） */
float  g_fJoinTime[MAXPLAYERS+1];      /**< 进服时刻，-1 = 不再纳入判定 */
bool   g_bAutoTracked[MAXPLAYERS+1];   /**< 已成为“候选”（进服窗口内说过话） */
bool   g_bSpeaking[MAXPLAYERS+1];
float  g_fSpokenTime[MAXPLAYERS+1];
float  g_fSilenceAt[MAXPLAYERS+1];     /**< 最近的停止说话时刻，-1 = 未知 */
bool   g_bAutoDone[MAXPLAYERS+1];      /**< 本局已自动屏蔽过，不重复触发 */
Handle g_hAutoTimer;
GlobalForward g_hVoiceChanged;
float  g_fTimerLast;                   /**< 上一次自动屏蔽检测的时刻，用于按真实时间累计 */

/* 外部插件状态 */
bool g_bChatPluginLoaded;   /**< 已有插件（hextags）统一输出聊天 */

public Plugin myinfo =
{
	name = "[L4D2] BeBlock - 个人屏蔽(语音/文字)",
	author = "apples1949",
	description = "玩家自助屏蔽指定玩家的语音与文字聊天（含进服语音自动屏蔽）",
	version = PLUGIN_VERSION,
	url = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	EngineVersion test = GetEngineVersion();
	if (test != Engine_Left4Dead2 && test != Engine_Left4Dead)
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 1/2.");
		return APLRes_SilentFailure;
	}

	/* native 先创建，再注册库名，避免别的插件拿到库名后调用到未绑定的 native */
	CreateNative("BeBlock_CanSeeChat", Native_CanSeeChat);
	CreateNative("BeBlock_HasChatBlocker", Native_HasChatBlocker);
    CreateNative("BeBlock_IsVoiceBlocked", Native_IsVoiceBlocked);
    CreateNative("BeBlock_SetVoiceBlocked", Native_SetVoiceBlocked);
    g_hVoiceChanged = new GlobalForward("BeBlock_OnVoiceChanged", ET_Ignore, Param_Cell, Param_Cell, Param_Cell);
	RegPluginLibrary("beblock");
	return APLRes_Success;
}

public void OnPluginStart()
{
	LoadTranslations("beblock.phrases");

	CreateConVar("sm_beblock_version", PLUGIN_VERSION, "[L4D2] 个人屏蔽插件版本", CVAR_FLAGS | FCVAR_DONTRECORD);

	g_hCvarEnable     = CreateConVar("sm_beblock_enable", "1", "是否启用个人屏蔽插件 (1 启用 / 0 关闭)", CVAR_FLAGS, true, 0.0, true, 1.0);
	g_hCvarAutoMute   = CreateConVar("sm_beblock_automute", "1", "是否自动屏蔽“进服后立刻持续说话”的玩家语音 (1 启用 / 0 关闭)", CVAR_FLAGS, true, 0.0, true, 1.0);
	g_hCvarAutoWindow = CreateConVar("sm_beblock_automute_joinwindow", "20.0", "进服后多少秒内开始说话才纳入自动屏蔽判定", CVAR_FLAGS, true, 1.0, true, 600.0);
	g_hCvarPersist    = CreateConVar("sm_beblock_persist", "1", "屏蔽状态是否按 SteamID 跨章节保存 (1 保存，过关/重连后仍然屏蔽 / 0 关闭，旧行为：只按客户端索引，换图即失效)", CVAR_FLAGS, true, 0.0, true, 1.0);
	g_hCvarAllTalk    = FindConVar("sv_alltalk");

	g_hPersist = new StringMap();

	GetCvars();
	g_hCvarEnable.AddChangeHook(ConVarChanged);
	g_hCvarAutoMute.AddChangeHook(ConVarChanged);
	g_hCvarAutoWindow.AddChangeHook(ConVarChanged);
	g_hCvarPersist.AddChangeHook(ConVarChanged);

	RegConsoleCmd("sm_bequiet", Command_BeBlock, "打开个人屏蔽菜单，屏蔽指定玩家的语音/文字");
	RegConsoleCmd("sm_quite",   Command_BeBlock, "打开个人屏蔽菜单，屏蔽指定玩家的语音/文字");
	RegConsoleCmd("sm_bizhi",   Command_BeBlock, "打开个人屏蔽菜单，屏蔽指定玩家的语音/文字");
	RegConsoleCmd("sm_bz",      Command_BeBlock, "打开个人屏蔽菜单，屏蔽指定玩家的语音/文字");

	/* 运行期数组只是加速副本：换图/断线时会被清掉，靠 g_hPersist 在 OnClientAuthorized
	   里恢复。这里不再假设“换图不掉线所以状态留着”（那个假设是旧版的 bug 根源）。 */
	for (int i = 1; i <= MAXPLAYERS; i++)
	{
		g_iMenuTarget[i] = 0;
		g_fJoinTime[i]   = -1.0;
		g_fSilenceAt[i]  = -1.0;
		g_sAuthKey[i][0] = '\0';
	}
}

public void OnAllPluginsLoaded()
{
	g_bChatPluginLoaded = LibraryExists("hextags");
}

public void OnLibraryAdded(const char[] name)
{
	if (StrEqual(name, "hextags"))
		g_bChatPluginLoaded = true;
}

public void OnLibraryRemoved(const char[] name)
{
	if (StrEqual(name, "hextags"))
		g_bChatPluginLoaded = false;
}

public void OnPluginEnd()
{
	/* 卸载/重载时还原本插件下发过的语音屏蔽，避免残留 */
	RevertAllVoiceOverrides();

	/* 持久层是本插件自己的运行期数据：插件要走了，句柄必须归还。
	   注意这不影响“换地图”，换地图不会重载插件。 */
	if (g_hPersist != null)
	{
		delete g_hPersist;
		g_hPersist = null;
	}
}

public void OnMapStart()
{
	/* 换图后引擎会重新初始化语音状态，这里重新下发一遍
	   （重复下发是幂等的，且只动本插件自己下发过的组合） */
	ReapplyAllVoice();

	/* 说话检测状态跨图不可信（OnClientSpeakingEnd 可能在换图时丢失），
	   全部复位；进服判定窗口也在本图关闭，避免跨图误判。
	   安静时长从本图重新开始算：被自动屏蔽的人下一张图继续安静，
	   AUTOMUTE_QUIET_RESTORE 秒后就会自动恢复 */
	for (int i = 1; i <= MaxClients; i++)
	{
		g_bSpeaking[i]    = false;
		g_fSpokenTime[i]  = 0.0;
		g_bAutoTracked[i] = false;
		g_fJoinTime[i]    = -1.0;
		g_fSilenceAt[i]   = IsValidClient(i) ? GetGameTime() : -1.0;
	}

	/* 兜底：万一某张图上客户端没有重新走一遍 OnClientAuthorized（引擎/平台差异），
	   地图开始 2 秒后再按当前在线名单把持久层恢复一遍。幂等，重复恢复不会多出屏蔽 */
	CreateTimer(2.0, Timer_RestoreAllPersisted, _, TIMER_FLAG_NO_MAPCHANGE);
}

/* 按在线名单整体恢复一次（兜底路径，见 OnMapStart） */
public Action Timer_RestoreAllPersisted(Handle timer)
{
	if (!g_bPersist || g_hPersist == null)
		return Plugin_Stop;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsValidClient(i))
			continue;

		if (g_sAuthKey[i][0] == '\0')
			BuildAuthKey(i);   /* 这张图上还没建过键：现在 auth 一定拿得到 */

		if (g_sAuthKey[i][0] == '\0')
			continue;

		RestoreForClient(i);
	}

	return Plugin_Stop;
}

public void OnConfigsExecuted()
{
	/* 配置执行完毕（地图初始化之后）再补一次，防止等级初始化阶段清空覆盖 */
	ReapplyAllVoice();
}

void ConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	bool bWasEnable = g_bEnable;
	bool bWasPersist = g_bPersist;
	GetCvars();

	if (g_bEnable != bWasEnable)
	{
		/* 总开关切换：打开时补下发，关闭时撤销本插件下发过的语音屏蔽 */
		if (g_bEnable)
			ReapplyAllVoice();
		else
			RevertAllVoiceOverrides();
	}

	if (g_bPersist != bWasPersist)
	{
		if (g_bPersist)
		{
			/* 打开：把当前运行期状态直接写进持久层，免得下一次换图才生效 */
			PersistAllRuntime();
		}
		else if (g_hPersist != null)
		{
			/* 关闭：丢掉持久层，回到旧行为（只按索引），避免以后再打开时复活旧数据 */
			g_hPersist.Clear();
		}
	}
}

void GetCvars()
{
	g_bEnable        = g_hCvarEnable.BoolValue;
	g_bAutoMute      = g_hCvarAutoMute.BoolValue;
	g_fAutoWindow    = g_hCvarAutoWindow.FloatValue;
	g_bPersist       = (g_hCvarPersist != null) ? g_hCvarPersist.BoolValue : true;
}

/* ==========================================================================
 *  跨章节持久层：auth 键 / 读写 / 恢复
 * ========================================================================== */

/* 生成并缓存本客户端的 auth 键。
   Steam2 → Steam3 → “名字+IP”三级兜底，保证任何一种环境都有键可用、且互相不污染。 */
void BuildAuthKey(int client)
{
	/* 先做范围检查再动数组，避免越界写 */
	if (client < 1 || client > MaxClients)
		return;

	g_sAuthKey[client][0] = '\0';

	if (!IsClientConnected(client))
		return;

	if (IsFakeClient(client))
		return;

	char sAuth[FALLBACK_KEY_MAX];

	/* validate=true（默认）：只认引擎/Steam 已经确认过的身份，避免拿到中间态的空值 */
	if (GetClientAuthId(client, AuthId_Steam2, sAuth, sizeof(sAuth)) && sAuth[0] != '\0')
	{
		strcopy(g_sAuthKey[client], sizeof(g_sAuthKey[]), sAuth);
		return;
	}

	if (GetClientAuthId(client, AuthId_Steam3, sAuth, sizeof(sAuth)) && sAuth[0] != '\0')
	{
		strcopy(g_sAuthKey[client], sizeof(g_sAuthKey[]), sAuth);
		return;
	}

	/* 纯 LAN / 无 Steam：退化成“名字+IP”。
	   键里绝不能出现分隔符 '|'，否则会和 "请求者|被屏蔽者" 的格式打架。 */
	char sName[MAX_NAME_LENGTH], sIp[32];
	GetClientName(client, sName, sizeof(sName));
	GetClientIP(client, sIp, sizeof(sIp), false);
	ReplaceString(sName, sizeof(sName), "|", "_", false);
	ReplaceString(sIp, sizeof(sIp), "|", "_", false);

	FormatEx(g_sAuthKey[client], sizeof(g_sAuthKey[]), "%s@%s", sName, sIp);
}

void MakePairKey(const char[] sRequester, const char[] sTarget, char[] key, int maxlen)
{
	FormatEx(key, maxlen, "%s|%s", sRequester, sTarget);
}

/* 把 (requester 屏蔽 target) 的当前状态写回持久层；掩码为 0 就删键（= 本人解除了屏蔽） */
void PersistPair(int requester, int target)
{
	if (!g_bPersist || g_hPersist == null)
		return;

	if (requester < 1 || requester > MaxClients || target < 1 || target > MaxClients || requester == target)
		return;

	/* 有一方 auth 还没就绪：本次只在运行期生效，等它 Authorized 后会由
	   PersistAllRuntime()/后续操作补上，不会写出半截键 */
	if (g_sAuthKey[requester][0] == '\0' || g_sAuthKey[target][0] == '\0')
		return;

	char key[PAIR_KEY_MAX];
	MakePairKey(g_sAuthKey[requester], g_sAuthKey[target], key, sizeof(key));

	int iFlags = g_iBlockFlags[requester][target];
	if (iFlags == 0)
		g_hPersist.Remove(key);
	else
		g_hPersist.SetValue(key, iFlags);
}

/* 把当前所有在线玩家的运行期状态整体刷进持久层（打开 cvar / 收尾用） */
void PersistAllRuntime()
{
	if (g_hPersist == null)
		return;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsValidClient(i) || g_sAuthKey[i][0] == '\0')
			continue;

		for (int j = 1; j <= MaxClients; j++)
		{
			if (i == j || !IsValidClient(j) || g_sAuthKey[j][0] == '\0')
				continue;

			PersistPair(i, j);
		}
	}
}

/* 删掉“某人自己作为请求者”的全部持久记录（本人解除屏蔽 / 清空全部时用） */
void ClearPersistedRequester(int client)
{
	if (g_hPersist == null || client < 1 || client > MaxClients || g_sAuthKey[client][0] == '\0')
		return;

	char sPrefix[FALLBACK_KEY_MAX + 2];
	FormatEx(sPrefix, sizeof(sPrefix), "%s|", g_sAuthKey[client]);
	int iPrefixLen = strlen(sPrefix);

	char key[PAIR_KEY_MAX];
	StringMapSnapshot snap = g_hPersist.Snapshot();
	for (int i = 0; i < snap.Length; i++)
	{
		snap.GetKey(i, key, sizeof(key));
		if (strncmp(key, sPrefix, iPrefixLen) == 0)
			g_hPersist.Remove(key);
	}
	delete snap;
}

/* auth 键 → 在线客户端索引（0 = 这人不在服务器里） */
int FindClientByAuthKey(const char[] sAuth)
{
	if (sAuth[0] == '\0')
		return 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientConnected(i) || IsFakeClient(i) || g_sAuthKey[i][0] == '\0')
			continue;

		if (StrEqual(g_sAuthKey[i], sAuth, false))
			return i;
	}

	return 0;
}

/* 恢复“我屏蔽了谁” */
void RestoreRequesterSide(int client)
{
	if (!g_bPersist || g_hPersist == null || client < 1 || client > MaxClients || g_sAuthKey[client][0] == '\0')
		return;

	char sPrefix[FALLBACK_KEY_MAX + 2];
	FormatEx(sPrefix, sizeof(sPrefix), "%s|", g_sAuthKey[client]);
	int iPrefixLen = strlen(sPrefix);

	char key[PAIR_KEY_MAX];
	StringMapSnapshot snap = g_hPersist.Snapshot();
	for (int i = 0; i < snap.Length; i++)
	{
		snap.GetKey(i, key, sizeof(key));
		if (strncmp(key, sPrefix, iPrefixLen) != 0)
			continue;

		int target = FindClientByAuthKey(key[iPrefixLen]);
		if (target <= 0)
			continue;   /* 对方还不在服务器里：等他 Authorized 时由 RestoreTargetSide 补 */

		int iFlags;
		if (!g_hPersist.GetValue(key, iFlags))
			continue;

		g_iBlockFlags[client][target] = iFlags;
	}
	delete snap;
}

/* 恢复“谁屏蔽了我”（对方可能后进服，所以两边各自恢复一次） */
void RestoreTargetSide(int client)
{
	if (!g_bPersist || g_hPersist == null || client < 1 || client > MaxClients || g_sAuthKey[client][0] == '\0')
		return;

	char sSuffix[FALLBACK_KEY_MAX + 2];
	FormatEx(sSuffix, sizeof(sSuffix), "|%s", g_sAuthKey[client]);
	int iSuffixLen = strlen(sSuffix);

	char key[PAIR_KEY_MAX];
	StringMapSnapshot snap = g_hPersist.Snapshot();
	for (int i = 0; i < snap.Length; i++)
	{
		snap.GetKey(i, key, sizeof(key));

		int iLen = strlen(key);
		if (iLen <= iSuffixLen)
			continue;

		if (!StrEqual(key[iLen - iSuffixLen], sSuffix, false))
			continue;

		char sRequester[FALLBACK_KEY_MAX];
		strcopy(sRequester, sizeof(sRequester), key);
		sRequester[iLen - iSuffixLen] = '\0';

		int requester = FindClientByAuthKey(sRequester);
		if (requester <= 0)
			continue;

		int iFlags;
		if (!g_hPersist.GetValue(key, iFlags))
			continue;

		g_iBlockFlags[requester][client] = iFlags;
	}
	delete snap;
}

/* 对某个客户端，双向重新下发一次语音覆盖（新图/重连后必须补，别只靠 OnMapStart） */
void ReapplyVoiceForClient(int client)
{
	if (client < 1 || client > MaxClients)
		return;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (i == client || !IsClientConnected(i))
			continue;

		ApplyVoiceOverride(client, i);   /* 我屏蔽了谁 */
		ApplyVoiceOverride(i, client);   /* 谁屏蔽了我 */
	}
}

public Action Timer_ReapplyClientVoice(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client < 1 || client > MaxClients || !IsClientConnected(client))
		return Plugin_Stop;

	ReapplyVoiceForClient(client);
	return Plugin_Stop;
}

void RestoreForClient(int client)
{
	if (client < 1 || client > MaxClients || g_sAuthKey[client][0] == '\0')
		return;

	RestoreRequesterSide(client);
	RestoreTargetSide(client);

	/* 立刻试一次；此刻可能还没 fully in-game（SetListenOverride 投递不了），
	   所以再排一个 1 秒后的补发（OnConfigsExecuted 的 ReapplyAllVoice 也会兜一次） */
	ReapplyVoiceForClient(client);
	CreateTimer(1.0, Timer_ReapplyClientVoice, GetClientUserId(client));
}

/* ==========================================================================
 *  客户端事件
 * ========================================================================== */

public void OnClientPutInServer(int client)
{
	/* 索引可能刚被上一位玩家用过，先清掉残留的“运行期”状态。
	   注意：只清运行期，不动持久层 —— 真正的屏蔽关系等 OnClientAuthorized 再恢复。 */
	ResetClientState(client);

	if (IsFakeClient(client))
		return;

	g_fJoinTime[client] = GetGameTime();
}

/* 【为什么状态会丢 / 根因】
   SourceMod 在每次地图结束时（LevelShutdown → PlayerManager::OnSourceModLevelEnd）会对
   **所有仍在线**的客户端投递 OnClientDisconnect + OnClientDisconnect_Post，并把
   CPlayer 的 connected/authorized/authid 全部清空。旧版这里直接 ResetClientState(整表清零)，
   而屏蔽状态只存在于按索引的数组里、没有任何持久副本 → 换章节即全丢，必须重新屏蔽。
   （“客户端换图不掉线、索引不变”这句旧注释只说对了一半：人确实没走，但 SM 确实把
     客户端当成断线处理了一遍，所以靠索引数组跨图是不可能的。）
   现在：这里只清运行期缓存，持久层保留；本人下次进服时 OnClientAuthorized 恢复。 */
public void OnClientDisconnect(int client)
{
	ResetClientState(client);

	/* auth 键属于“本次连接”，连接结束就丢弃；持久层记录不动 */
	g_sAuthKey[client][0] = '\0';
}

/* 【为什么挂 OnClientAuthorized 而不是 OnClientPutInServer】
   PutInServer 只是“人进了服务器”，此时 Steam 身份常常还没确认：
   GetClientAuthId(..., validate=true) 会失败，键就会退化到“名字+IP”，
   甚至拿到空串 —— 那样每次进服算出来的键都不一样，等于没存。
   OnClientAuthorized 才是引擎确认过身份之后的时点，Steam2/Steam3 稳定可取，
   每次进服、每张新图（SM 在新图会重新 Connect 已在线客户端）都会触发一次，
   正好是“把持久层恢复进运行期 + 重新下发语音屏蔽”的正确时机。 */
public void OnClientAuthorized(int client, const char[] auth)
{
	if (!g_bPersist || IsFakeClient(client))
		return;

	BuildAuthKey(client);
	RestoreForClient(client);
}

void ResetClientState(int client)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		g_iBlockFlags[client][i] = 0;
		g_iBlockFlags[i][client] = 0;
		NotifyVoiceState(client, i, false);
		if (i != client) NotifyVoiceState(i, client, false);
		/* 引擎在本玩家断线时已自动清掉与他相关的 ListenOverride，这里同步清掉记录 */
		g_iVoiceOwn[client][i] = 0;
		g_iVoiceOwn[i][client] = 0;
	}

	g_iBlockFlags[client][client] = 0;
	g_iVoiceOwn[client][client]   = 0;
	g_iMenuTarget[client] = 0;
	g_fJoinTime[client]   = -1.0;
	g_fSilenceAt[client]  = -1.0;
	g_bAutoTracked[client] = false;
	g_bSpeaking[client]    = false;
	g_fSpokenTime[client]  = 0.0;
	g_bAutoDone[client]    = false;
}

/* ==========================================================================
 *  屏蔽状态：查询 / 切换 / 下发
 * ========================================================================== */

bool IsBlocked(int listener, int speaker, int iFlag)
{
	return (g_iBlockFlags[listener][speaker] & iFlag) != 0;
}

bool HasAnyBlock(int client)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (i != client && g_iBlockFlags[client][i] != 0)
			return true;
	}
	return false;
}

/** 自己能否听到对方语音（同队，或已开启全体语音 / 全体收听 / 对方全体发言） */
bool CanHearVoice(int listener, int speaker)
{
	if (GetClientTeam(listener) == GetClientTeam(speaker))
		return true;

	if (g_hCvarAllTalk == null)
		g_hCvarAllTalk = FindConVar("sv_alltalk");

	if (g_hCvarAllTalk != null && g_hCvarAllTalk.IntValue != 0)
		return true;

	/* 自己开了“收听全体”，或对方开了“全体发言” */
	if ((GetClientListeningFlags(listener) & VOICE_LISTENALL) != 0)
		return true;

	if ((GetClientListeningFlags(speaker) & VOICE_SPEAKALL) != 0)
		return true;

	return false;
}

/** 真正会被这条聊天消息送达的接收者里，有没有人屏蔽了发言者 */
bool HasChatBlocker(int speaker, bool bTeamChat)
{
	int iSpeakerTeam = GetClientTeam(speaker);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (i == speaker || !IsValidClient(i))
			continue;

		if (bTeamChat)
		{
			int iTeam = GetClientTeam(i);
			/* 队内聊天：同队玩家 + 旁观者（与本服聊天插件的接收范围一致） */
			if (iTeam != iSpeakerTeam && iTeam != 1)
				continue;
		}

		if (IsBlocked(i, speaker, BLOCK_TEXT))
			return true;
	}
	return false;
}

void ToggleBlock(int client, int target, int iFlag)
{
	bool bBlocked = IsBlocked(client, target, iFlag);

	char sName[MAX_NAME_LENGTH];
	GetClientName(target, sName, sizeof(sName));
	StripColorTags(sName, sizeof(sName));

	if (bBlocked)
		g_iBlockFlags[client][target] &= ~iFlag;
	else
		g_iBlockFlags[client][target] |= iFlag;

	if (iFlag & BLOCK_VOICE)
	{
		/* 玩家手动操作过这一项后，就不再算“自动屏蔽”，也不会被自动恢复 */
		g_iBlockFlags[client][target] &= ~BLOCK_AUTO;
		ApplyVoiceOverride(client, target);
	}

	/* 写回持久层：掩码归 0 时 PersistPair 会删键（这就是“本人自己解除屏蔽”的那条路径） */
	PersistPair(client, target);

	if (iFlag & BLOCK_VOICE)
		CPrintToChat(client, "%t", bBlocked ? "Msg_Voice_Unblocked" : "Msg_Voice_Blocked", sName);
	else
		CPrintToChat(client, "%t", bBlocked ? "Msg_Text_Unblocked" : "Msg_Text_Blocked", sName);
}

void UnblockAll(int client)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (i == client)
			continue;

		g_iBlockFlags[client][i] = 0;
		ApplyVoiceOverride(client, i);   /* 撤销本插件下发过的语音屏蔽 */
	}

	g_iBlockFlags[client][client] = 0;

	/* 本人清空全部：把持久层里“我作为请求者”的记录一并删掉
	   （连对方当前不在线的那些也删，否则他一进服又会把屏蔽恢复出来） */
	ClearPersistedRequester(client);

	CPrintToChat(client, "%t", "Msg_Unblock_All");
}

// Both !bz and SpecLister use these flags; only this plugin writes their shared override.
public int Native_IsVoiceBlocked(Handle plugin, int numParams)
{
    int listener = GetNativeCell(1), speaker = GetNativeCell(2);
    if (!ValidVoicePair(listener, speaker)) return false;
    return g_bEnable && IsBlocked(listener, speaker, BLOCK_VOICE);
}

public int Native_SetVoiceBlocked(Handle plugin, int numParams)
{
    int listener = GetNativeCell(1), speaker = GetNativeCell(2);
    if (!g_bEnable || !ValidVoicePair(listener, speaker)) return false;
    if (GetNativeCell(3)) g_iBlockFlags[listener][speaker] |= BLOCK_VOICE;
    else g_iBlockFlags[listener][speaker] &= ~BLOCK_VOICE;
    g_iBlockFlags[listener][speaker] &= ~BLOCK_AUTO;
    ApplyVoiceOverride(listener, speaker);
    /* 外部插件（SpecLister 等）改这一位也要写回持久层，否则换图后又“复活”成旧值 */
    PersistPair(listener, speaker);
    // Also notify when the requested state was already clear.
    NotifyVoiceState(listener, speaker, IsBlocked(listener, speaker, BLOCK_VOICE));
    return true;
}

bool ValidVoicePair(int listener, int speaker)
{
    return listener > 0 && listener <= MaxClients && speaker > 0 && speaker <= MaxClients
        && listener != speaker && IsClientConnected(listener) && IsClientConnected(speaker);
}

void NotifyVoiceState(int listener, int speaker, bool blocked)
{
    if (g_hVoiceChanged == null) return;
    Call_StartForward(g_hVoiceChanged);
    Call_PushCell(listener);
    Call_PushCell(speaker);
    Call_PushCell(blocked);
    Call_Finish();
}

/** 下发 / 撤销 (listener 听 speaker) 的语音屏蔽 */
void ApplyVoiceOverride(int listener, int speaker)
{
	if (listener == speaker || listener < 1 || speaker < 1)
		return;

	if (!IsClientConnected(listener) || !IsClientConnected(speaker))
		return;

	if (!g_bEnable)
		return;

	if (IsBlocked(listener, speaker, BLOCK_VOICE))
	{
		/* first time: 记住原来的覆盖值，撤销时还原，避免覆盖其它插件
		   （如 SpecLister）对同一组合的设置 */
		if (g_iVoiceOwn[listener][speaker] == 0)
			g_iVoiceOwn[listener][speaker] = view_as<int>(GetListenOverride(listener, speaker)) + 1;

		SetListenOverride(listener, speaker, Listen_No);
		NotifyVoiceState(listener, speaker, true);
	}
	else if (g_iVoiceOwn[listener][speaker] != 0)
	{
		SetListenOverride(listener, speaker, view_as<ListenOverride>(g_iVoiceOwn[listener][speaker] - 1));
		g_iVoiceOwn[listener][speaker] = 0;
		NotifyVoiceState(listener, speaker, false);
	}
}

/** 撤销本插件下发过的全部语音屏蔽（还原为下发前的覆盖值） */
void RevertAllVoiceOverrides()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientConnected(i))
			continue;

		for (int j = 1; j <= MaxClients; j++)
		{
			if (i == j || g_iVoiceOwn[i][j] == 0)
				continue;

			if (IsClientConnected(j))
				SetListenOverride(i, j, view_as<ListenOverride>(g_iVoiceOwn[i][j] - 1));

			g_iVoiceOwn[i][j] = 0;
		}
	}
}

void ReapplyAllVoice()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientConnected(i))
			continue;

		for (int j = 1; j <= MaxClients; j++)
		{
			if (i == j || !IsClientConnected(j))
				continue;

			ApplyVoiceOverride(i, j);
		}
	}
}

/* ==========================================================================
 *  菜单
 * ========================================================================== */

public Action Command_BeBlock(int client, int args)
{
	if (!client)
	{
		ReplyToCommand(client, "[BeBlock] 该指令只能在游戏内使用。");
		return Plugin_Handled;
	}

	if (!g_bEnable)
	{
		CPrintToChat(client, "%t", "Msg_Disabled");
		return Plugin_Handled;
	}

	ShowPlayerMenu(client);
	return Plugin_Handled;
}

void ShowPlayerMenu(int client)
{
	char sUserId[16], sName[MAX_NAME_LENGTH], sLabel[128];
	int iItems = 0;

	Menu menu = new Menu(MenuHandler_Players);
	menu.SetTitle("%T", "Menu_Title", client);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsValidClient(i) || i == client)
			continue;

		/* 一级菜单只列玩家名，不显示任何屏蔽状态 */
		GetClientName(i, sName, sizeof(sName));

		IntToString(GetClientUserId(i), sUserId, sizeof(sUserId));
		menu.AddItem(sUserId, sName);
		iItems++;
	}

	bool bAnyBlock = HasAnyBlock(client);

	if (bAnyBlock)
	{
		FormatEx(sLabel, sizeof(sLabel), "%T", "Menu_Unblock_All", client);
		menu.AddItem(ITEM_UNBLOCK_ALL, sLabel);
	}

	menu.ExitButton = true;

	if (iItems == 0 && !bAnyBlock)
	{
		delete menu;
		CPrintToChat(client, "%t", "Msg_No_Players");
		return;
	}

	menu.Display(client, MENU_TIME_FOREVER);
}

void ShowTargetMenu(int client, int target)
{
	char sTitle[128], sName[MAX_NAME_LENGTH];

	GetClientName(target, sName, sizeof(sName));

	Menu menu = new Menu(MenuHandler_Target);
	FormatEx(sTitle, sizeof(sTitle), "%T", "Menu_Target_Title", client, sName);
	menu.SetTitle("%s", sTitle);   /* 玩家名可能含 %，不能当格式串用 */
	menu.ExitBackButton = true;
	menu.ExitButton = true;

	/* 不同队且没开全体语音时，本来就听不到对方语音 → 不显示该行 */
	if (CanHearVoice(client, target))
	{
		FormatEx(sTitle, sizeof(sTitle), "%s %T",
			IsBlocked(client, target, BLOCK_VOICE) ? MARK_BLOCKED : MARK_RECEIVE,
			"Menu_Receive_Voice", client);
		menu.AddItem(ITEM_VOICE, sTitle);
	}

	FormatEx(sTitle, sizeof(sTitle), "%s %T",
		IsBlocked(client, target, BLOCK_TEXT) ? MARK_BLOCKED : MARK_RECEIVE,
		"Menu_Receive_Text", client);
	menu.AddItem(ITEM_TEXT, sTitle);

	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Players(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char sInfo[16];
			menu.GetItem(param2, sInfo, sizeof(sInfo));

			if (StrEqual(sInfo, ITEM_UNBLOCK_ALL))
			{
				UnblockAll(param1);
				ShowPlayerMenu(param1);
				return 0;
			}

			int target = GetClientOfUserId(StringToInt(sInfo));

			if (!IsValidClient(target))
			{
				CPrintToChat(param1, "%t", "Msg_Target_Left");
				ShowPlayerMenu(param1);
				return 0;
			}

			g_iMenuTarget[param1] = GetClientUserId(target);
			ShowTargetMenu(param1, target);
		}

		case MenuAction_End:
		{
			delete menu;
		}
	}

	return 0;
}

public int MenuHandler_Target(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char sInfo[8];
			menu.GetItem(param2, sInfo, sizeof(sInfo));

			int target = GetClientOfUserId(g_iMenuTarget[param1]);

			if (!IsValidClient(target))
			{
				CPrintToChat(param1, "%t", "Msg_Target_Left");
				ShowPlayerMenu(param1);
				return 0;
			}

			if (StrEqual(sInfo, ITEM_VOICE))
				ToggleBlock(param1, target, BLOCK_VOICE);
			else if (StrEqual(sInfo, ITEM_TEXT))
				ToggleBlock(param1, target, BLOCK_TEXT);

			/* 重新显示，让玩家立刻看到 [√]/[×] 变化 */
			ShowTargetMenu(param1, target);
		}

		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack)
				ShowPlayerMenu(param1);
		}

		case MenuAction_End:
		{
			delete menu;
		}
	}

	return 0;
}

/* ==========================================================================
 *  文字聊天：按接收者过滤
 *  - 本服由 hextags_lite 统一输出聊天，它会在输出前调用 BeBlock_CanSeeChat
 *  - 没有该类插件时，本插件自己接管输出（下面 OnClientSayCommand）
 * ========================================================================== */

public int Native_CanSeeChat(Handle plugin, int numParams)
{
	int listener = GetNativeCell(1);
	int speaker  = GetNativeCell(2);

	if (!g_bEnable || listener == speaker || listener < 1 || speaker < 1)
		return true;

	if (!IsValidClient(listener) || !IsValidClient(speaker))
		return true;

	return !IsBlocked(listener, speaker, BLOCK_TEXT);
}

public int Native_HasChatBlocker(Handle plugin, int numParams)
{
	int speaker = GetNativeCell(1);
	bool bTeamChat = view_as<bool>(GetNativeCell(2));

	if (!g_bEnable || !IsValidClient(speaker))
		return false;

	return HasChatBlocker(speaker, bTeamChat);
}

public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
	/* 有插件统一输出聊天时，由它按接收者过滤，本插件不重复输出 */
	if (g_bChatPluginLoaded || !g_bEnable || !IsValidClient(client))
		return Plugin_Continue;

	char sMessage[MAX_MESSAGE_LENGTH];
	strcopy(sMessage, sizeof(sMessage), sArgs);
	StripQuotes(sMessage);

	if (sMessage[0] == '\0')
		return Plugin_Continue;

	/* !cmd / /cmd 交给 SourceMod 自己处理 */
	if (sMessage[0] == '!' || sMessage[0] == '/')
		return Plugin_Continue;

	bool bTeamChat = StrEqual(command, "say_team", false);

	if (!HasChatBlocker(client, bTeamChat))
		return Plugin_Continue;   /* 没人屏蔽他 → 保持游戏原版显示 */

	PrintFilteredChat(client, bTeamChat, sMessage);
	return Plugin_Handled;
}

void PrintFilteredChat(int speaker, bool bTeamChat, const char[] sMessage)
{
	char sName[MAX_NAME_LENGTH];
	char sClean[MAX_MESSAGE_LENGTH];

	GetClientName(speaker, sName, sizeof(sName));
	StripColorTags(sName, sizeof(sName));

	strcopy(sClean, sizeof(sClean), sMessage);
	StripColorTags(sClean, sizeof(sClean));

	int iSpeakerTeam = GetClientTeam(speaker);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
			continue;

		if (bTeamChat)
		{
			int iTeam = GetClientTeam(i);
			if (iTeam != iSpeakerTeam && iTeam != 1)
				continue;
		}

		if (i != speaker && IsBlocked(i, speaker, BLOCK_TEXT))
			continue;

		CPrintToChatEx(i, speaker, "{teamcolor}%s{default} : %s", sName, sClean);
	}
}

/** 去掉 colors.inc 会解析的颜色标签，避免玩家名字/聊天内容注入颜色或触发异常 */
void StripColorTags(char[] text, int maxlen)
{
	static const char sColorTags[][] = {
		"{default}", "{darkred}", "{green}", "{lightgreen}", "{red}", "{blue}",
		"{olive}", "{lime}", "{lightred}", "{purple}", "{grey}", "{orange}",
		"{teamcolor}"
	};

	for (int i = 0; i < sizeof(sColorTags); i++)
		ReplaceString(text, maxlen, sColorTags[i], "", false);
}

/* ==========================================================================
 *  自动屏蔽：进服后立刻开始、且连续说满 N 秒的语音
 * ========================================================================== */

public void OnClientSpeaking(int client)
{
	g_bSpeaking[client] = true;
	g_fSilenceAt[client] = -1.0;

	if (!g_bAutoMute || !IsValidClient(client) || IsFakeClient(client))
		return;

	/* 已经判定过 / 不在进服窗口内 / 旁观者不参与 */
	if (g_bAutoDone[client] || g_bAutoTracked[client] || g_fJoinTime[client] < 0.0)
		return;

	if (GetClientTeam(client) < 2)
		return;

	if (GetGameTime() - g_fJoinTime[client] > g_fAutoWindow)
	{
		g_fJoinTime[client] = -1.0;
		return;
	}

	g_bAutoTracked[client] = true;
	g_fSpokenTime[client] = 0.0;
	EnsureAutoTimer();
}

public void OnClientSpeakingEnd(int client)
{
	g_bSpeaking[client] = false;
	g_fSilenceAt[client] = GetGameTime();
}

void EnsureAutoTimer()
{
	if (g_hAutoTimer != null)
		return;

	g_hAutoTimer = CreateTimer(AUTOMUTE_INTERVAL, Timer_AutoMuteCheck, _, TIMER_REPEAT);
}

public Action Timer_AutoMuteCheck(Handle timer)
{
	bool bKeep = false;
	float fNow = GetGameTime();
	float fDelta = (g_fTimerLast > 0.0) ? (fNow - g_fTimerLast) : AUTOMUTE_INTERVAL;
	g_fTimerLast = fNow;

	if (fDelta < 0.0)
		fDelta = 0.0;

	for (int i = 1; i <= MaxClients; i++)
	{
		/* 1) “进服后连续说话”判定 */
		if (g_bAutoTracked[i])
		{
			if (!g_bAutoMute || !IsValidClient(i) || IsFakeClient(i))
			{
				g_bAutoTracked[i] = false;
			}
			else
			{
				bKeep = true;

				if (g_bSpeaking[i])
				{
					g_fSpokenTime[i] += fDelta;

					if (g_fSpokenTime[i] >= AUTOMUTE_SECONDS)
					{
						g_bAutoTracked[i] = false;
						TriggerAutoMute(i);
					}
				}
				else
				{
					/* 要求“连续”：中途只要停止说话就重新计时。
					   开自由麦的玩家语音流是全程连续的，不会被这里打断 */
					g_bAutoTracked[i] = false;
					g_fSpokenTime[i] = 0.0;
				}
			}
		}

		/* 2) 被自动屏蔽的人安静够久 → 自动恢复接收其语音 */
		if (!HasAutoVoiceBlock(i))
			continue;

		bKeep = true;

		if (!g_bSpeaking[i] && g_fSilenceAt[i] >= 0.0 && fNow - g_fSilenceAt[i] >= AUTOMUTE_QUIET_RESTORE)
			RestoreAutoBlocks(i);
	}

	if (!bKeep)
	{
		g_hAutoTimer = null;
		g_fTimerLast = 0.0;
		return Plugin_Stop;
	}

	return Plugin_Continue;
}

/** 是否有人正被本插件的“进服语音自动屏蔽”屏蔽着 */
bool HasAutoVoiceBlock(int speaker)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (i != speaker && (g_iBlockFlags[i][speaker] & BLOCK_AUTO))
			return true;
	}
	return false;
}

/** 安静够久了：撤掉所有由自动屏蔽写入的语音屏蔽（手动屏蔽过的别人不动） */
void RestoreAutoBlocks(int speaker)
{
	int iSeconds = RoundToNearest(AUTOMUTE_QUIET_RESTORE);

	char sName[MAX_NAME_LENGTH];
	GetClientName(speaker, sName, sizeof(sName));
	StripColorTags(sName, sizeof(sName));

	for (int i = 1; i <= MaxClients; i++)
	{
		if (i == speaker || !(g_iBlockFlags[i][speaker] & BLOCK_AUTO))
			continue;

		g_iBlockFlags[i][speaker] &= ~(BLOCK_VOICE | BLOCK_AUTO);
		ApplyVoiceOverride(i, speaker);
		PersistPair(i, speaker);   /* 自动恢复也要写回：这一位撤掉后就该真的不再保留 */

		if (IsValidClient(i))
			CPrintToChat(i, "%t", "Msg_AutoMute_Restored", sName, iSeconds);
	}

	LogAction(0, speaker, "[BeBlock] 自动恢复接收语音: 已安静 %d 秒", iSeconds);
}

void TriggerAutoMute(int speaker)
{
	if (!IsValidClient(speaker))
		return;

	g_bAutoDone[speaker] = true;

	char sName[MAX_NAME_LENGTH];
	GetClientName(speaker, sName, sizeof(sName));
	StripColorTags(sName, sizeof(sName));

	/* 只写入同队玩家的个人屏蔽名单：进入 [×] 状态，
	   玩家仍旧可以用 !bz 打开菜单自行解除，不做全服禁语音 */
	int iTeam = GetClientTeam(speaker);
	int iSeconds = RoundToNearest(AUTOMUTE_SECONDS);
	bool bAny = false;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsValidClient(i) || i == speaker || GetClientTeam(i) != iTeam)
			continue;

		if (IsBlocked(i, speaker, BLOCK_VOICE))
			continue;

		g_iBlockFlags[i][speaker] |= (BLOCK_VOICE | BLOCK_AUTO);
		ApplyVoiceOverride(i, speaker);
		PersistPair(i, speaker);   /* 自动屏蔽同样要跨章节保留，否则过关后还会再被念一遍 */
		CPrintToChat(i, "%t", "Msg_AutoMute_Team", sName, iSeconds);
		bAny = true;
	}

	if (bAny)
	{
		LogAction(0, speaker, "[BeBlock] 自动屏蔽语音(同队): 进服 %.1f 秒内开始说话并连续 %d 秒",
			GetGameTime() - g_fJoinTime[speaker], iSeconds);
	}
}

/* ==========================================================================
 *  工具函数
 * ========================================================================== */

bool IsValidClient(int client)
{
	return (client > 0 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client));
}
