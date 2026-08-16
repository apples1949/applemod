/*
 * vim: set ts=4 :
 * =============================================================================
 * Left 4 Dead Vocalize Guard
 * Guards against Player's Abusing the Vocalize System
 * Variation of the 'Left 4 Dead Vote Gaurd Plugin by CrimsonGT
 * SourceMod (C)2004-2007 AlliedModders LLC.  All rights reserved.
 * =============================================================================
 *
 * This program is free software; you can redistribute it and/or modify it under
 * the terms of the GNU General Public License, version 3.0, as published by the
 * Free Software Foundation.
 * 
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
 * details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * As a special exception, AlliedModders LLC gives you permission to link the
 * code of this program (as well as its derivative works) to "Half-Life 2," the
 * "Source Engine," the "SourcePawn JIT," and any Game MODs that run on software
 * by the Valve Corporation.  You must obey the GNU General Public License in
 * all respects for all other code used.  Additionally, AlliedModders LLC grants
 * this exception to all derivative works.  AlliedModders LLC defines further
 * exceptions, found in LICENSE.txt (as of this writing, version JULY-31-2007),
 * or <http://www.sourcemod.net/license.php>.
 *
 */

#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "1.2"

int g_VocalCalled[MAXPLAYERS+1];
float g_LastVocalTime[MAXPLAYERS+1];

/* CVARS */
ConVar cEnabled = null;
ConVar cVocalLimit = null;
ConVar cVocalDelay = null;

public Plugin myinfo = 
{
	name = "L4D Vocalize Guard",
	author = "apples1949",
	description = "Left 4 Dead Vocalize Spam Blocker",
	version = PLUGIN_VERSION,
	url = "http://www.sourcemod.net/"
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) 
{
	EngineVersion test = GetEngineVersion();
	
	if( test != Engine_Left4Dead && test != Engine_Left4Dead2 )
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 1 & 2.");
		return APLRes_SilentFailure;
	}
	
	
	if( !IsDedicatedServer() )
	{
		strcopy(error, err_max, "Get a dedicated server. This plugin does not work on Listen servers.");
		return APLRes_SilentFailure;
	}

	return APLRes_Success; 
}

public void OnPluginStart()
{
	RegConsoleCmd("vocalize", Command_CallVocal);

	cEnabled = CreateConVar("sm_vocalize_guard_enabled", "1", "启用/禁用插件 [0 = 禁用, 1 = 启用]", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	cVocalLimit = CreateConVar("sm_vocalize_guard_vlimit", "1", "时间窗口内最多允许几次语音表单（窗口从第一次使用开始计算）", FCVAR_NOTIFY, true, 1.0);
	cVocalDelay = CreateConVar("sm_vocalize_guard_vdelay", "5", "玩家使用语音表单的时间窗口（秒）[0 = 关闭]", FCVAR_NOTIFY, true, 0.0);
	
	//AutoExecConfig(true, "vocal_block");
	HookEvent("player_disconnect", Event_PlayerDisconnect);
}

public void OnMapStart()
{
	for(int i=1;i<=MaxClients;i++)
	{
		g_VocalCalled[i] = 0;
		g_LastVocalTime[i] = 0.0;
	}
}

public void Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast) 
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client == 0) return;
	
	g_VocalCalled[client] = 0;
	g_LastVocalTime[client] = 0.0;
}

public Action Command_CallVocal(int client, int args)
{
	if (client == 0 || !IsClientInGame(client) || !cEnabled.BoolValue) return Plugin_Continue;

	float flTimeDelay = cVocalDelay.FloatValue;
	if (flTimeDelay <= 0.0) return Plugin_Continue;

	int iMaxCalls = cVocalLimit.IntValue;
	float flNow = GetEngineTime();
	float flElapsed = flNow - g_LastVocalTime[client];

	/* 第一次使用，或上一个时间窗口已结束：开启新窗口并放行 */
	if (g_VocalCalled[client] == 0 || flElapsed >= flTimeDelay)
	{
		g_LastVocalTime[client] = flNow;
		g_VocalCalled[client] = 1;
		return Plugin_Continue;
	}

	/* 窗口内还有剩余次数：放行并计数 */
	if (g_VocalCalled[client] < iMaxCalls)
	{
		g_VocalCalled[client]++;
		return Plugin_Continue;
	}

	/* 窗口内次数已用完：拦截 */
	int iTimeLeft = RoundToCeil(flTimeDelay - flElapsed);
	PrintToChat(client, "\x04[SM] \x01你已达到使用语音表单的最大数量，必须等待 %d 秒后再次使用", iTimeLeft);
	
	return Plugin_Handled;
}