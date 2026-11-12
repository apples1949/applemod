#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>

/**
 * [L4D2] Survivor Body Guard
 *
 * 针对 12v12 服务器上"玩家实体模型与动画序列号错配 → SlerpBones 越界崩溃"的两道安全网：
 *
 *   1) 钳制 m_survivorCharacter（人类玩家）
 *      12v12 下 survivor_limit > 8 时，引擎给玩家随机分配的 m_survivorCharacter 会落到
 *      8..11（L4D2 只有 0..7 八个角色，8 会在日志里显示成 "Unknown"）。这种身体生成时是
 *      <Survivor><Unknown><DEAD>，既不正常占位又让 SuperVersus 的入队重试陷入 Join_Wait 循环。
 *      SuperVersus 的 PrepareSurvivorModel() 只修 bot，不修人类玩家，所以这里补上。
 *
 *   2) 进生还者队后把 m_nSequence 复位为 0
 *      CBaseAnimating::SetSequence() 写 m_nSequence 时没有任何边界检查，而 SlerpBones() 用它
 *      直接索引虚拟模型序列表（pStudioHdr->m_pVModel->m_seq[]）也不检查长度。只要实体因为
 *      换队/换模型而短暂停留在"旧序列号 + 新模型"的组合上，下一次命中盒测试就会越界崩服。
 *      进队后一拍把序列号复位，可以让这个窗口不携带越界值。
 *
 * 说明：
 *   - 只处理人类玩家（IsFakeClient 跳过）；bot 的角色 ID 由 SuperVersus 自己修，避免两个插件抢同一件事。
 *   - 属性名与类型已按 L4D2 netprop dump 核对：
 *       m_survivorCharacter  Prop_Send  integer 8bit   (offset 11188)
 *       m_nSequence          Prop_Send  integer 12bit  (offset 1152)
 */

#define PLUGIN_VERSION "1.0"

#define TEAM_SURVIVOR           2
#define MAX_SURVIVOR_CHARS      8       // L4D2 角色 0..7，8 及以上为非法("Unknown")

ConVar g_cvClampChar;
ConVar g_cvResetSeq;
ConVar g_cvLog;

public Plugin myinfo =
{
	name        = "[L4D2] Survivor Body Guard",
	author      = "apples1949",
	description = "把人类玩家越界的 m_survivorCharacter 钳回 0..7，并在进生还者队后复位 m_nSequence（防 SlerpBones 越界崩溃）",
	version     = PLUGIN_VERSION,
	url         = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	if (GetEngineVersion() != Engine_Left4Dead2)
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 2.");
		return APLRes_SilentFailure;
	}
	return APLRes_Success;
}

public void OnPluginStart()
{
	g_cvClampChar = CreateConVar("l4d2_bodyguard_clamp_char", "1",
		"1=把人类玩家越界的 m_survivorCharacter 钳回 0..7；0=关闭", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvResetSeq = CreateConVar("l4d2_bodyguard_reset_seq", "1",
		"1=玩家进入生还者队后把 m_nSequence 复位为 0；0=关闭", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvLog = CreateConVar("l4d2_bodyguard_log", "1",
		"1=修复时写服务端日志；0=安静模式", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	CreateConVar("l4d2_bodyguard_version", PLUGIN_VERSION, "插件版本", FCVAR_NOTIFY | FCVAR_DONTRECORD);

	HookEvent("player_team", Event_PlayerTeam, EventHookMode_Post);

	// 晚加载 / 重载：把已经在场的玩家补挂 Spawn 钩子，并立刻修一次
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
			OnClientPutInServer(i);
	}
}

public void OnClientPutInServer(int client)
{
	// 出生前/出生后各修一次：引擎选角色发生在"进队 → 选角色 → 生成"之间，
	// 两个时机都盖住，才能保证真正生成时用的是合法角色号。
	SDKHook(client, SDKHook_Spawn, OnClientSpawn);
	SDKHook(client, SDKHook_SpawnPost, OnClientSpawnPost);
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
		return;

	if (event.GetInt("team") != TEAM_SURVIVOR)
		return;

	// 进队这一刻先修角色号（此时模型可能还没设置）
	ClampCharacter(client);

	// 角色号/模型都落定之后再复位序列号与再兜一次角色号
	RequestFrame(Frame_PostJoin, GetClientUserId(client));
}

public Action OnClientSpawn(int client)
{
	ClampCharacter(client);
	return Plugin_Continue;
}

public void OnClientSpawnPost(int client)
{
	ClampCharacter(client);
	ResetSequence(client);
}

void Frame_PostJoin(int userid)
{
	int client = GetClientOfUserId(userid);
	if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
		return;

	ClampCharacter(client);
	ResetSequence(client);
}

/**
 * 把越界的 m_survivorCharacter 钳回 0..7。
 * 优先挑一个当前没被其他生还者占用的角色；都被占满时随机一个（12v12 本来就会重角色）。
 */
void ClampCharacter(int client)
{
	if (!g_cvClampChar.BoolValue)
		return;

	if (client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
		return;

	if (GetClientTeam(client) != TEAM_SURVIVOR)
		return;

	if (!HasEntProp(client, Prop_Send, "m_survivorCharacter"))
		return;

	int character = GetEntProp(client, Prop_Send, "m_survivorCharacter");
	if (character >= 0 && character < MAX_SURVIVOR_CHARS)
		return;

	int fixed = PickFreeCharacter(client);
	SetEntProp(client, Prop_Send, "m_survivorCharacter", fixed);

	if (g_cvLog.BoolValue)
		LogMessage("[BodyGuard] %L: m_survivorCharacter %d -> %d (非法角色号，已钳回)", client, character, fixed);
}

int PickFreeCharacter(int exclude)
{
	bool used[MAX_SURVIVOR_CHARS];
	for (int i = 0; i < MAX_SURVIVOR_CHARS; i++)
		used[i] = false;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (i == exclude || !IsClientInGame(i))
			continue;
		if (GetClientTeam(i) != TEAM_SURVIVOR)
			continue;

		int c = GetEntProp(i, Prop_Send, "m_survivorCharacter");
		if (c >= 0 && c < MAX_SURVIVOR_CHARS)
			used[c] = true;
	}

	for (int i = 0; i < MAX_SURVIVOR_CHARS; i++)
	{
		if (!used[i])
			return i;
	}

	// 八个角色全被占了（12v12 常见）：随机一个即可，引擎允许重复角色
	return GetRandomInt(0, MAX_SURVIVOR_CHARS - 1);
}

/**
 * 进生还者队后把 m_nSequence 复位。
 * 只复位一次、且只对生还者队的人类玩家，避免干扰正在播放的正常动画。
 */
void ResetSequence(int client)
{
	if (!g_cvResetSeq.BoolValue)
		return;

	if (client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
		return;

	if (GetClientTeam(client) != TEAM_SURVIVOR)
		return;

	if (!HasEntProp(client, Prop_Send, "m_nSequence"))
		return;

	int sequence = GetEntProp(client, Prop_Send, "m_nSequence");
	if (sequence == 0)
		return;

	SetEntProp(client, Prop_Send, "m_nSequence", 0);

	if (g_cvLog.BoolValue)
		LogMessage("[BodyGuard] %L: m_nSequence %d -> 0 (进队后复位，防模型/序列错配)", client, sequence);
}
