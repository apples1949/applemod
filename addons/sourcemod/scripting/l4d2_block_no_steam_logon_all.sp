/*
 * [L4D2] Block No Steam Logon - All Codes (engine memory patch)
 *
 * 完全阻止 "No Steam logon" 踢出（EAuthSessionResponse codes 1/6/7/8）。
 *
 * 逆向依据 (engine_srv.so, md5 0ee571682d63f798ac07d4bc238beb4f, 45/103 同款):
 *   CSteam3Server::OnValidateAuthTicketResponseHelper @ 0x2010e0
 *   0x201148: cmp dword ptr [edi + 0x98], 1   ; m_bShuttingDown 检查
 *   0x20114f: je  0x201170                   ; ==1 跳过踢出
 *   0x201153: mov [ebp+0xc], 0x2b5566        ; "No Steam logon"
 *   ... jmp [vtable+0x3c]                    ; CBaseClient::Disconnect
 *
 *   switch(EauthSessionResponse) [0x2b5a80]  (9 entries, code 0-8):
 *     0 -> 0x2011f0  Disconnect("Client dropped by server")   [OK path]
 *     1 -> 0x201148  Disconnect("No Steam logon")             [guarded, patched]
 *     2 -> 0x201180  Disconnect("This Steam account does not own this game...")
 *     3 -> 0x2011a0  Disconnect("VAC banned from secure server")  [guarded, MUST KICK]
 *     4 -> 0x2011b8  Disconnect("This Steam account is being used in another game...") [guarded]
 *     5 -> 0x2011d0  Disconnect("Client timed out")           [optional patch]
 *     6 -> 0x201148  Disconnect("No Steam logon")             [guarded, patched]
 *     7 -> 0x201148  Disconnect("No Steam logon")             [guarded, patched]
 *     8 -> 0x201148  Disconnect("No Steam logon")             [guarded, patched]
 *
 *   guarded = the branch first does  cmp [edi+0x98],1 ; je skip  (m_bShuttingDown).
 *   Patch 1 flips that je -> jmp so codes 1/6/7/8 always take the "do not kick" path.
 *   Codes 2/3/4 are left intact (no license / VAC ban / logged in elsewhere).
 *
 * 补丁: 把 0x20114f 的 je (0x74 0x1F) 改成 jmp (0xEB 0x1F),
 *       使 code 1/6/7/8 全部走 m_bShuttingDown==1 的"不踢"路径。
 * 可选补丁: 0x2011d0 改写为 jmp 0x201170, 拦 code 5 "Client timed out"。
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sourcescramble>

#define GAMEDATA_FILE "l4d2_block_no_steam_logon_all"
#define PATCH_1678     "OnValidateAuthTicketResponseHelper::SkipNoSteamLogonKick"
#define PATCH_CODE5    "OnValidateAuthTicketResponseHelper::SkipClientTimedOut"

#define PLUGIN_VERSION "1.0.0"

MemoryPatch g_hPatch_1678;
MemoryPatch g_hPatch_Code5;
ConVar g_hCvar_Enable;
ConVar g_hCvar_BlockCode5;
bool g_bEnabled;
bool g_bBlockCode5;

public Plugin myinfo =
{
	name        = "[L4D2] Block No Steam Logon (All Codes)",
	author      = "apples1949",
	description = "Engine memory patch: fully blocks 'No Steam logon' kicks (codes 1/6/7/8) + optional code 5",
	version     = PLUGIN_VERSION,
	url         = ""
};

public void OnPluginStart()
{
	CreateConVar("l4d2_block_no_steam_logon_all_version", PLUGIN_VERSION, "Plugin version.", FCVAR_NONE | FCVAR_DONTRECORD);

	g_hCvar_Enable = CreateConVar("l4d2_block_no_steam_logon_all_enable", "1",
		"[0=off/1=on] Block 'No Steam logon' kicks (auth codes 1/6/7/8).", FCVAR_NONE, true, 0.0, true, 1.0);
	g_hCvar_Enable.AddChangeHook(OnEnableChange);

	g_hCvar_BlockCode5 = CreateConVar("l4d2_block_no_steam_logon_all_block_code5", "0",
		"[0=off/1=on] Also block code 5 kick ('Client timed out', VAC check timeout).", FCVAR_NONE, true, 0.0, true, 1.0);
	g_hCvar_BlockCode5.AddChangeHook(OnEnableChange);

	AutoExecConfig(true, "l4d2_block_no_steam_logon_all");

	InitPatch();
	ApplyPatchState();
}

void OnEnableChange(ConVar convar, const char[] oldValue, const char[] newValue)
{
	ApplyPatchState();
}

void InitPatch()
{
	GameData gd = new GameData(GAMEDATA_FILE);
	if (!gd)
		SetFailState("Missing or invalid gamedata: %s.txt", GAMEDATA_FILE);

	g_hPatch_1678 = MemoryPatch.CreateFromConf(gd, PATCH_1678);
	if (g_hPatch_1678 == null)
		SetFailState("Failed to create patch: %s", PATCH_1678);

	g_hPatch_Code5 = MemoryPatch.CreateFromConf(gd, PATCH_CODE5);
	if (g_hPatch_Code5 == null)
		SetFailState("Failed to create patch: %s", PATCH_CODE5);

	delete gd;
}

void ApplyPatchState()
{
	bool want = g_hCvar_Enable.BoolValue;
	bool wantCode5 = g_hCvar_BlockCode5.BoolValue;

	if (want)
	{
		if (!g_hPatch_1678.Validate())
			SetFailState("Patch verify failed (engine mismatch?): %s", PATCH_1678);
		if (!g_hPatch_1678.Enable())
			SetFailState("Patch enable failed: %s", PATCH_1678);
		g_bEnabled = true;
		LogMessage("[BlockNoSteamLogonAll] Patch enabled: auth codes 1/6/7/8 will NOT kick ('No Steam logon' blocked)");
	}
	else if (g_bEnabled)
	{
		g_hPatch_1678.Disable();
		g_bEnabled = false;
		LogMessage("[BlockNoSteamLogonAll] Patch disabled");
	}

	if (wantCode5)
	{
		if (!g_hPatch_Code5.Validate())
			SetFailState("Patch verify failed (engine mismatch?): %s", PATCH_CODE5);
		if (!g_hPatch_Code5.Enable())
			SetFailState("Patch enable failed: %s", PATCH_CODE5);
		g_bBlockCode5 = true;
		LogMessage("[BlockNoSteamLogonAll] Code5 patch enabled: auth code 5 ('Client timed out') will NOT kick");
	}
	else if (g_bBlockCode5)
	{
		g_hPatch_Code5.Disable();
		g_bBlockCode5 = false;
		LogMessage("[BlockNoSteamLogonAll] Code5 patch disabled");
	}
}
