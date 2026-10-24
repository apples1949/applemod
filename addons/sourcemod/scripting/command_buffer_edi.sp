/*
*	[ANY] Command and ConVar - Buffer Overflow Fixer
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



#define PLUGIN_VERSION 		"2.9.3-applefix"

/*======================================================================================
	Plugin Info:

*	Name	:	[ANY] Command and ConVar - Buffer Overflow Fixer
*	Author	:	SilverShot and Peace-Maker
*	Descrp	:	Fixes incorrect ConVars values due to 'Cbuf_AddText: buffer overflow' console error on servers.
*	Link	:	https://forums.alliedmods.net/showthread.php?t=309656
*	Plugins	:	https://sourcemod.net/plugins.php?exact=exact&sortby=title&search=1&author=Silvers

========================================================================================
	Change Log:

2.9 (23-Jan-2024)
	- Fixed memory leak from clearing ArrayList handles. Thanks to "HarryPotter" for help solving.

2.8b (11-Feb-2023)
	- Updated GameData signature for CS:GO. Thanks to "foxsay" for reporting.

2.8 (19-Jan-2022)
	- Fixed leaking handles when triggered to fix buffer issues.

2.7 (06-Dec-2021)
	- Fixed the last version breaking plugin functionality. Thanks to "sorallll" for reporting.

2.6 (27-Nov-2021)
	- Fixed "Failed to grow array" error. Thanks to "azureblue" for reporting.

2.5a (16-Jun-2021)
	- L4D2: Compatibility update for "2.2.1.3" update. Thanks to "ProjectSky" for reporting and "bedildewo" for fixing.
	- GameData .txt file and plugin updated.

2.5 (03-May-2021)
	- Fixed errors when inputting a string with format specifiers. Thanks to "sorallll" for reporting and "Dragokas" for fix.

2.4 (10-May-2020)
	- Added better error log message when gamedata file is missing.
	- Various changes to tidy up code.

2.3 (03-Feb-2020)
	- Fixed debugging using the wrong methodmap. Thanks to "Caaine" for reporting.

2.2 (03-Feb-2020) by Dragokas
	- Added delete to an unused handle.
	- Changed "char" to "static char" in "OnNextFrame" to optimize performance.

2.1 (07-Aug-2018)
	- Added support for GoldenEye and other games using the OrangeBox engine on Windows and Linux.
	- Added support for Left4Dead2 Windows - not required from my testing on a Dedicated Server.
	- Gamedata .txt and plugin updated.

2.0.1 (02-Aug-2018)
	- Turned off debugging.

2.0 (02-Aug-2018)
	- Now fixes all ConVars from being set to incorrect values.
	- Supports CSGO (win/nix), L4D1 (win/nix) and L4D2 (nix).
	- Other games with issues please request support.

1.0 (27-Jun-2018)
	- Initial release.

======================================================================================*/

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <dhooks>

#define GAMEDATA			"command_buffer.games"
#define ARGS_BUFFER_LENGTH	1024
#define MAX_REPLAY_COMMAND  (ARGS_BUFFER_LENGTH - 3)
#define RETRY_CELL          (ARGS_BUFFER_LENGTH / 4)
#define MAX_REPLAY_ATTEMPTS 32

#define DEBUGGING			0
#if DEBUGGING
#define MAX_CVARS			5000
#endif

bool g_NextFrame;
ArrayList g_aCommandList;
int g_ReplayAttempt;
int g_QueuedCommands;
int g_FailedReplays;

public Plugin myinfo =
{
	name = "[ANY] Command and ConVar - Buffer Overflow Fixer",
	author = "SilverShot and Peace-Maker",
	description = "Fixes the 'Cbuf_AddText: buffer overflow' console error on servers, which causes ConVars to use their default value.",
	version = PLUGIN_VERSION,
	url = "https://forums.alliedmods.net/showthread.php?t=309656"
}

public void OnPluginStart()
{
	ConVar version = CreateConVar("command_buffer_version", PLUGIN_VERSION, "Command and ConVar - Buffer Overflow Fixer plugin version.", FCVAR_NOTIFY|FCVAR_DONTRECORD);
	version.SetString(PLUGIN_VERSION);
	RegAdminCmd("sm_bufferstatus", BufferStatus, ADMFLAG_CONFIG, "Show buffered command retry status");

	g_aCommandList = new ArrayList(RETRY_CELL + 1);

	// ====================================================================================================
	// Detour - Anytime convars are added to the buffer this will fire
	// ====================================================================================================
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), "gamedata/%s.txt", GAMEDATA);
	if( FileExists(sPath) == false ) SetFailState("\n==========\nMissing required file: \"%s\".\nRead installation instructions again.\n==========", sPath);

	Handle hGameData = LoadGameConfigFile(GAMEDATA);
	if( hGameData == null ) SetFailState("Failed to load \"%s.txt\" gamedata.", GAMEDATA);

	Handle hDetour = DHookCreateFromConf(hGameData, "CCommandBuffer::InsertCommand");
	delete hGameData;

	if( !hDetour )
		SetFailState("Failed to find \"CCommandBuffer::InsertCommand\" signature.");

	if( !DHookEnableDetour(hDetour, true, InsertCommandPost) )
		SetFailState("Failed to detour post \"CCommandBuffer::InsertCommand\".");

	delete hDetour;

	// Debug
	#if DEBUGGING
		char cvar[64];
		for( int i = 0; i < MAX_CVARS; i++ )
		{
			FormatEx(cvar, sizeof(cvar), "sm_cvar_test_%d", i);
			CreateConVar(cvar, "0");
		}
		AutoExecConfig(true, "sm_cvar_test");
		RegAdminCmd("sm_cvar_test", sm_cvar_test, ADMFLAG_ROOT);
	#endif
}

#if DEBUGGING
Action sm_cvar_test(int client, int args)
{
	int cv;
	ConVar cvar;
	char temp[64];
	for( int i = 0; i < MAX_CVARS; i++ )
	{
		FormatEx(temp, sizeof(temp), "sm_cvar_test_%d", i);
		cvar = FindConVar(temp);
		if( cvar != null && cvar.IntValue != 1 ) cv++;
	}
	ReplyToCommand(client, "%d out of %d cvars are wrong.", cv, MAX_CVARS);
	return Plugin_Handled;
}
#endif

// ====================================================================================================
// Detour
// ====================================================================================================
Action BufferStatus(int client, int args)
{
	ReplyToCommand(client, "[Buffer] v%s | pending=%d queued=%d exhausted=%d", PLUGIN_VERSION,
		g_aCommandList.Length, g_QueuedCommands, g_FailedReplays);
	return Plugin_Handled;
}

MRESReturn InsertCommandPost(Handle hReturn, Handle hParams)
{
	// See if the server was able to insert the command just fine.
	bool bSuccess = DHookGetReturn(hReturn);
	if( bSuccess )
		return MRES_Ignored;

	// pArgS points into the remaining CFG, NOT a null-terminated single command.
	// Copy exactly nCommandSize bytes; copying the tail duplicates later loads and
	// is then truncated by SourceMod's 1024-byte InsertServerCommand formatter.
	int length = DHookGetParam(hParams, 2);
	if (length <= 0 || length > MAX_REPLAY_COMMAND)
	{
		LogError("Cannot replay command of %d bytes (transport maximum %d); not treating an overlong command as buffer pressure.", length, MAX_REPLAY_COMMAND);
		return MRES_Ignored;
	}
	if (g_ReplayAttempt >= MAX_REPLAY_ATTEMPTS)
	{
		g_FailedReplays++;
		LogError("Command replay failed after %d attempts (%d bytes). Check sm_bufferstatus and startup logs.", g_ReplayAttempt, length);
		return MRES_Ignored;
	}
	char command[ARGS_BUFFER_LENGTH];
	DHookGetParamString(hParams, 1, command, length + 1);
	command[length] = '\0';

	// The command buffer overflowed. Add the commands again on the next frame.
	if( !g_NextFrame )
	{
		g_NextFrame = true;
		RequestFrame(OnNextFrame);
	}

	// Debug print
	#if DEBUGGING
		PrintToServer("Fix: [%s]", command);
	#endif

	int row = g_aCommandList.PushString(command);
	g_aCommandList.Set(row, g_ReplayAttempt + 1, RETRY_CELL);
	g_QueuedCommands++;

	// Prevent "Cbuf_AddText: buffer overflow" message
	DHookSetReturn(hReturn, true);
	return MRES_Override;
}

// ====================================================================================================
// Reinsert the convars/commands that failed to be executed on the last frame now.
// Doesn't get called when servers hibernating, eg on first start up, until server wakes.
// ====================================================================================================
void OnNextFrame(any na)
{
	// Remove next frame so if they fail it will create the request and execute again on next frame
	g_NextFrame = false;

	// Swap the buffers so we don't add to the list we're currently processing in our InsertServerCommand hook.
	// Executes the ConVars/commands in the order they were.
	ArrayList aCmdList = g_aCommandList.Clone();

	// g_aCommandList.Clear(); // Does not free memory, delete and re-create.
	delete g_aCommandList;
	g_aCommandList = new ArrayList(RETRY_CELL + 1);

	static char sCommand[ARGS_BUFFER_LENGTH];

	int length = aCmdList.Length;
	for( int i = 0; i < length; i++ )
	{
		// Debug print
		#if DEBUGGING
			static int iCount;
			PrintToServer("Ins: %d %s", iCount++, sCommand);
		#endif

		// Insert only this command. Do not propagate its retry count to commands
		// generated by the plugins/CFGs executed during ServerExecute below.
		aCmdList.GetString(i, sCommand, sizeof(sCommand));
		g_ReplayAttempt = aCmdList.Get(i, RETRY_CELL);
		InsertServerCommand("%s", sCommand);
		g_ReplayAttempt = 0;

		// Flush the command buffer now. Outside of loop doesn't work - the convars would remain incorrect.
		ServerExecute();

		// If this replay (or a command it executed) overflowed again, keep the
		// rest behind it. Otherwise a consumer could run before its provider on
		// the same frame, despite both originally being queued in the right order.
		if (g_aCommandList.Length > 0)
		{
			for (int remaining = i + 1; remaining < length; remaining++)
			{
				aCmdList.GetString(remaining, sCommand, sizeof(sCommand));
				int row = g_aCommandList.PushString(sCommand);
				g_aCommandList.Set(row, aCmdList.Get(remaining, RETRY_CELL), RETRY_CELL);
			}
			break;
		}
	}

	delete aCmdList;
}
