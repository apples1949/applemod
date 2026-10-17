#pragma newdecls required

#include <sourcemod>

/******************************************************************
*
* v1.0
* ------------------------
* ------- Details: -------
* ------------------------
* - Establishes Server Commands for the following:
* --> Unloading Plugins with the argument being the folder you want to unload the plugins from, leave the argument empty if you wish to unload just the main folder.
* --> Reserving Plugins, meaning these plugins will not be unloaded when the previously mentioned Plugin Unload is unloading the folder these plugins reside in.
* --> Unloading Reserved Plugins, this function will unload the reserved plugins in the order from "Last Reserved" to "First Reserved".

* v1.1
* ------------------------
* ------- Details: -------
* ------------------------
* - Overhauled it with keyCat's feedback in mind.
* --> Unloading Plugins with the pred_unload_plugins will push all currently loaded plugins to the Array and unloads them from Last loaded to First loaded. This way, dependencies should'nt be an issue.
* --> Removed the possibility of just Unloading Reserved Plugins... as there's no need for it?
*
*
* v1.2
* ------------------------
* ------- Details: -------
* ------------------------
* - Removed the unnecessary "ReservePlugin" function.
* - Added a failsafe after plugins are supposed to be unloaded, as we've seen some cases where this plugin would be the only one refusing to unload, thus never refreshing the plugins.
* - Added a less messy way of preventing double pushing, as this plugin is the only one that could possibly be double pushed. (StrEqual instead of FindInArray for every single plugin)
*
*
* v1.2.1
* ------------------------
* ------- Details: -------
* ------------------------
* - Removed the unnecessary "ReservePlugin" function.
* - Added a failsafe after plugins are supposed to be unloaded, as we've seen some cases where this plugin would be the only one refusing to unload, thus never refreshing the plugins.
* - Added a less messy way of preventing double pushing, as this plugin is the only one that could possibly be double pushed. (StrEqual instead of FindInArray for every single plugin)
*
* v1.2.2
* ------------------------
* ------- Details: -------
* ------------------------
* - Added sPlugin which will store this plugin's path on load, rather than looking it up during the "UnloadPlugins" function.
* - Added Timers for closing functionality of UnloadPlugins to ensure accuracy.
*
***************************************************************************************************************************************************************************************************
* ------------------------
* -------- NOTES: --------
* ------------------------
* - The plugin doesn't currently care about capitalization other than the Directory of the plugin, not sure if I can be bothered adding this :P
*
******************************************************************/

ArrayList aReservedPlugins;
char sPlugin[PLATFORM_MAX_PATH];
bool g_Unloading;
int g_Generation;

public Plugin myinfo = 
{
	name = "Predictable Plugin Unloader",
	author = "Sir (heavily influenced by keyCat)",
	version = "1.2.3-applefix",
	description = "Allows for unloading plugins from last to first."
}

public void OnPluginStart()
{
	RegServerCmd("pred_unload_plugins", UnloadPlugins, "Unload Plugins!");
	RegServerCmd("pred_unload_step", UnloadStep, "Internal ordered unload continuation");

	// Gotta reserve ourself of course.
	// - Supports moving the plugin to another folder. (INVALID_HANDLE simply gets the calling plugin)
	GetPluginFilename(INVALID_HANDLE, sPlugin, sizeof(sPlugin));

	// Reserved Plugins
	aReservedPlugins = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
}

Action UnloadPlugins(int args)
{
	if (g_Unloading) return Plugin_Handled;
	g_Unloading = true;
	g_Generation++;
	aReservedPlugins.Clear();

	char stockpluginname[PLATFORM_MAX_PATH];
	Handle pluginIterator = GetPluginIterator();
	Handle currentPlugin;

	while (MorePlugins(pluginIterator))
	{
		currentPlugin = ReadPlugin(pluginIterator);
		GetPluginFilename(currentPlugin, stockpluginname, sizeof(stockpluginname));

		// Keep the continuation handler alive until every other unload has executed.
		if (!StrEqual(sPlugin, stockpluginname))
			aReservedPlugins.PushString(stockpluginname);
	}

	// ReadPlugin returns a borrowed handle, not one owned by this plugin.
	CloseHandle(pluginIterator);

	// One unload plus its continuation at a time, including on empty servers.
	// Restart policy is owned by linux_auto_restart, not by a match-mode reset.
	InsertServerCommand("sm plugins load_unlock\npred_unload_step %d", g_Generation);

	return Plugin_Handled;
}

Action UnloadStep(int args)
{
	char token[16];
	GetCmdArg(1, token, sizeof(token));
	if (!g_Unloading || args != 1 || StringToInt(token) != g_Generation) return Plugin_Handled;
	if (aReservedPlugins.Length > 0)
	{
		char filename[PLATFORM_MAX_PATH];
		int last = aReservedPlugins.Length - 1;
		aReservedPlugins.GetString(last, filename, sizeof(filename));
		aReservedPlugins.Erase(last);
		InsertServerCommand("sm plugins unload \"%s\"\npred_unload_step %d", filename, g_Generation);
	}
	else
	{
		// Refresh/self-unload cannot overtake the unload commands as timers could.
		InsertServerCommand("sm plugins refresh\nsm plugins unload \"%s\"", sPlugin);
	}
	return Plugin_Handled;
}
