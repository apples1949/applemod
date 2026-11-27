/**
 * vim: set ts=4 :
 * =============================================================================
 * SourceMod Basecommands
 * Functionality related to banning.
 *
 * SourceMod (C)2004-2008 AlliedModders LLC.  All rights reserved.
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
 * Version: $Id$
 */

void PrepareBan(int client, int target, int time, const char[] reason)
{
	int originalTarget = GetClientOfUserId(playerinfo[client].banTargetUserId);

	if (originalTarget != target)
	{
		if (client == 0)
		{
			PrintToServer("[SM] %t", "Player no longer available");
		}
		else
		{
			PrintToChat(client, "[SM] %t", "Player no longer available");
		}

		return;
	}

	char name[MAX_NAME_LENGTH];
	GetClientName(target, name, sizeof(name));

	if (!time)
	{
		if (reason[0] == '\0')
		{
			ShowActivity(client, "%t", "Permabanned player", name);
		}
		else
		{
			ShowActivity(client, "%t", "Permabanned player reason", name, reason);
		}
	}
	else
	{
		if (reason[0] == '\0')
		{
			ShowActivity(client, "%t", "Banned player", name, time);
		}
		else
		{
			ShowActivity(client, "%t", "Banned player reason", name, time, reason);
		}
	}

	/* 走数据库(l4d2_banned)的封禁，身份必须是 17 位 SteamID64 —— 库里 SteamID 列存的就是它。
	 * 取不到 64 位(无 Steam/未认证)就没法按 SteamID 入库，只能退回本地封禁，
	 * 本地 banned_user.cfg 写的是引擎原生格式 STEAM_X:Y:Z / IP，**不会**变成 64 位。 */
	char sSteam64[32];
	bool bHasSteam64 = GetClientAuthId(target, AuthId_SteamID64, sSteam64, sizeof(sSteam64));
	bool bUseDb = g_bLibraries && bHasSteam64;

	if (bUseDb)
		LogAction(client, target, "\"%L\" banned \"%L\" (minutes \"%d\") (steamid64 \"%s\") (reason \"%s\")", client, target, time, sSteam64, reason);
	else
		LogAction(client, target, "\"%L\" banned \"%L\" (minutes \"%d\") (reason \"%s\")", client, target, time, reason);

	if (!bUseDb)
	{
		if (g_bLibraries)
			PrintToServer("[basebans] %N 取不到 17 位 SteamID64，无法按 SteamID 入库：改走本地封禁(banned_user.cfg, 引擎格式 STEAM_X:Y:Z/IP)", target);
	}

	if (reason[0] == '\0')
	{
		// 装了 l4d2_banned(数据库封禁)且能取到 SteamID64 时走它的 native, 封禁写进数据库; 否则回退原版本地封禁.
		if(bUseDb)
		{
			/* flags 保持官方的 BANFLAG_AUTO（玩家有 Steam 身份时引擎本来就走身份封禁，不会退化成 IP）；
			 * 真正入库的 ID 由 l4d2_banned 的 OnBanClient 用 AuthId_SteamID64 取，跟这里的 flags 无关。 */
			BanPlayers(target, time, BANFLAG_AUTO, "Banned", "Banned", "sm_ban", client);
			PrintToServer("[basebans] sm_ban: %N (%d 分钟, SteamID64=%s) -> l4d2_banned 数据库", target, time, sSteam64);
		}
		else
		{
			BanClient(target, time, BANFLAG_AUTO, "Banned", "Banned", "sm_ban", client);
			PrintToServer("[basebans] sm_ban: %N (%d 分钟) -> 本地 banned_user.cfg（引擎格式 STEAM_X:Y:Z/IP）", target, time);
		}
	}
	else
	{
		if(bUseDb)
		{
			BanPlayers(target, time, BANFLAG_AUTO, reason, reason, "sm_ban", client);
			PrintToServer("[basebans] sm_ban: %N (%d 分钟, %s, SteamID64=%s) -> l4d2_banned 数据库", target, time, reason, sSteam64);
		}
		else
		{
			BanClient(target, time, BANFLAG_AUTO, reason, reason, "sm_ban", client);
			PrintToServer("[basebans] sm_ban: %N (%d 分钟, %s) -> 本地 banned_user.cfg（引擎格式 STEAM_X:Y:Z/IP）", target, time, reason);
		}
	}
}

void DisplayBanTargetMenu(int client)
{
	Menu menu = new Menu(MenuHandler_BanPlayerList);

	char title[100];
	Format(title, sizeof(title), "%T:", "Ban player", client);
	menu.SetTitle(title);
	menu.ExitBackButton = CheckCommandAccess(client, "sm_admin", ADMFLAG_GENERIC, false);

	AddTargetsToMenu2(menu, client, COMMAND_FILTER_NO_BOTS|COMMAND_FILTER_CONNECTED);

	menu.Display(client, MENU_TIME_FOREVER);
}

void DisplayBanTimeMenu(int client)
{
	Menu menu = new Menu(MenuHandler_BanTimeList);

	char title[100];
	Format(title, sizeof(title), "%T: %N", "Ban player", client, playerinfo[client].banTarget);
	menu.SetTitle(title);
	menu.ExitBackButton = true;

	menu.AddItem("0", "Permanent");
	menu.AddItem("10", "10 Minutes");
	menu.AddItem("30", "30 Minutes");
	menu.AddItem("60", "1 Hour");
	menu.AddItem("240", "4 Hours");
	menu.AddItem("1440", "1 Day");
	menu.AddItem("10080", "1 Week");

	menu.Display(client, MENU_TIME_FOREVER);
}

void DisplayBanReasonMenu(int client)
{
	Menu menu = new Menu(MenuHandler_BanReasonList);

	char title[100];
	Format(title, sizeof(title), "%T: %N", "Ban reason", client, playerinfo[client].banTarget);
	menu.SetTitle(title);
	menu.ExitBackButton = true;
	
	//Add custom chat reason entry first
	menu.AddItem("", "Custom reason (type in chat)");
	
	//Loading configurable entries from the kv-file
	char reasonName[100];
	char reasonFull[255];
	
	//Iterate through the kv-file
	g_hKvBanReasons.GotoFirstSubKey(false);
	do
	{
		g_hKvBanReasons.GetSectionName(reasonName, sizeof(reasonName));
		g_hKvBanReasons.GetString(NULL_STRING, reasonFull, sizeof(reasonFull));
		
		//Add entry
		menu.AddItem(reasonFull, reasonName);
		
	} while (g_hKvBanReasons.GotoNextKey(false));
	
	//Reset kvHandle
	g_hKvBanReasons.Rewind();

	menu.Display(client, MENU_TIME_FOREVER);
}

public void AdminMenu_Ban(TopMenu topmenu,
							  TopMenuAction action,
							  TopMenuObject object_id,
							  int param,
							  char[] buffer,
							  int maxlength)
{
	//Reset chat reason first
	playerinfo[param].isWaitingForChatReason = false;
	
	if (action == TopMenuAction_DisplayOption)
	{
		Format(buffer, maxlength, "%T", "Ban player", param);
	}
	else if (action == TopMenuAction_SelectOption)
	{
		DisplayBanTargetMenu(param);
	}
}

public int MenuHandler_BanReasonList(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Cancel)
	{
		if (param2 == MenuCancel_ExitBack && hTopMenu)
		{
			hTopMenu.Display(param1, TopMenuPosition_LastCategory);
		}
	}
	else if (action == MenuAction_Select)
	{
		if(param2 == 0)
		{
			//Chat reason
			playerinfo[param1].isWaitingForChatReason = true;
			PrintToChat(param1, "[SM] %t", "Custom ban reason explanation", "sm_abortban");
		}
		else
		{
			char info[64];
			
			menu.GetItem(param2, info, sizeof(info));
			
			PrepareBan(param1, playerinfo[param1].banTarget, playerinfo[param1].banTime, info);
		}
	}

	return 0;
}

public int MenuHandler_BanPlayerList(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Cancel)
	{
		if (param2 == MenuCancel_ExitBack && hTopMenu)
		{
			hTopMenu.Display(param1, TopMenuPosition_LastCategory);
		}
	}
	else if (action == MenuAction_Select)
	{
		char info[32], name[32];
		int userid, target;

		menu.GetItem(param2, info, sizeof(info), _, name, sizeof(name));
		userid = StringToInt(info);

		if ((target = GetClientOfUserId(userid)) == 0)
		{
			PrintToChat(param1, "[SM] %t", "Player no longer available");
		}
		else if (!CanUserTarget(param1, target))
		{
			PrintToChat(param1, "[SM] %t", "Unable to target");
		}
		else
		{
			playerinfo[param1].banTarget = target;
			playerinfo[param1].banTargetUserId = userid;
			DisplayBanTimeMenu(param1);
		}
	}

	return 0;
}

public int MenuHandler_BanTimeList(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Cancel)
	{
		if (param2 == MenuCancel_ExitBack && hTopMenu)
		{
			hTopMenu.Display(param1, TopMenuPosition_LastCategory);
		}
	}
	else if (action == MenuAction_Select)
	{
		char info[32];

		menu.GetItem(param2, info, sizeof(info));
		playerinfo[param1].banTime = StringToInt(info);

		DisplayBanReasonMenu(param1);
	}

	return 0;
}

public Action Command_Ban(int client, int args)
{
	if (args < 2)
	{
		if ((GetCmdReplySource() == SM_REPLY_TO_CHAT) && (client != 0) && (args == 0))
		{
			DisplayBanTargetMenu(client);
		}
		else
		{
			ReplyBoth(client, "[SM] Usage: sm_ban <#userid|name> <minutes|0> [reason]");
		}
		
		return Plugin_Handled;
	}

	int len, next_len;
	char Arguments[256];
	GetCmdArgString(Arguments, sizeof(Arguments));

	char arg[65];
	len = BreakString(Arguments, arg, sizeof(arg));

	int target = FindTarget(client, arg, true);
	if (target == -1)
	{
		return Plugin_Handled;
	}

	char s_time[12];
	if ((next_len = BreakString(Arguments[len], s_time, sizeof(s_time))) != -1)
	{
		len += next_len;
	}
	else
	{
		len = 0;
		Arguments[0] = '\0';
	}

	playerinfo[client].banTargetUserId = GetClientUserId(target);

	int time = StringToInt(s_time);
	PrepareBan(client, target, time, Arguments[len]);

	return Plugin_Handled;
}
