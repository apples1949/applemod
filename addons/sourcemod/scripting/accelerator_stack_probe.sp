/**
 * Accelerator stack probe.
 *
 * Runs the same walk Accelerator records in a crash report, so the capture can
 * be checked on a live server instead of waiting for a crash to prove it.
 *
 *   sm_accel_stack              prints the live SourcePawn call stack
 *   sm_accel_crash confirm      crashes the server on purpose
 *
 * For an unattended run:
 *
 *   srcds ... +neko_acceltest_autostart 1 +neko_acceltest_autocrash 1
 *
 * which logs the stack shortly after the map starts and then crashes, leaving a
 * report under addons/sourcemod/data/dumps/ to inspect.
 */
#pragma newdecls required
#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <accelerator>

public Plugin myinfo =
{
	name = "Accelerator stack probe",
	author = "Neko",
	description = "Verifies Accelerator's SourcePawn crash stack capture.",
	version = "1.0.0",
	url = "https://github.com/MatthewNeko/accelerator"
};

ConVar g_AutoStart;
ConVar g_AutoCrash;
bool g_Scheduled = false;

public void OnPluginStart()
{
	// Do not test LibraryExists("accelerator"): a library can be registered by a
	// build that knows nothing about this native. Ask for the native itself, which
	// is the only thing this plugin cannot work without. It is declared optional in
	// accelerator.inc, so this plugin loads either way and can explain itself.
	if (GetFeatureStatus(FeatureType_Native, "Accelerator_GetPluginStack") != FeatureStatus_Available)
	{
		SetFailState("Accelerator_GetPluginStack is unavailable: accelerator.ext is either not loaded (see sm exts list) or is a build without the SourcePawn stack capture.");
	}

	RegAdminCmd("sm_accel_stack", Command_PrintStack, ADMFLAG_ROOT, "Print the live SourcePawn call stack.");
	RegAdminCmd("sm_accel_crash", Command_Crash, ADMFLAG_ROOT, "Crash the server on purpose. Needs the word 'confirm'.");

	g_AutoStart = CreateConVar("neko_acceltest_autostart", "0", "Log the live SourcePawn stack shortly after map start.", FCVAR_NONE, true, 0.0, true, 1.0);
	g_AutoCrash = CreateConVar("neko_acceltest_autocrash", "0", "Crash the server shortly after map start.", FCVAR_NONE, true, 0.0, true, 1.0);
}

public void OnAllPluginsLoaded()
{
	HookConVarChange(g_AutoCrash, OnAutoCrashChanged);
	HookConVarChange(g_AutoStart, OnAutoCrashChanged);
}

public void OnMapStart()
{
	// Command line +cvar values land after the plugin loads, so check both here
	// and on change.
	TryScheduleAutoTests();
}

public void OnAutoCrashChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	TryScheduleAutoTests();
}

void TryScheduleAutoTests()
{
	if (g_Scheduled)
		return;

	if (!g_AutoStart.BoolValue && !g_AutoCrash.BoolValue)
		return;

	g_Scheduled = true;
	// Long enough for the map, plugins and Accelerator's own startup to finish.
	CreateTimer(10.0, Timer_RunAutoTests);
}

public Action Timer_RunAutoTests(Handle timer, any data)
{
	LogStack("auto");

	if (g_AutoCrash.BoolValue)
	{
		LogMessage("auto-crash requested through neko_acceltest_autocrash");
		CrashNestedMiddle();
	}

	return Plugin_Handled;
}

/**
 * @brief Writes the live stack to the SourceMod log.
 *
 * Called from a plugin context, so a working capture has to show this plugin's
 * own frames: zero frames here would mean the walk is not measuring what it
 * claims to measure.
 */
void LogStack(const char[] tag)
{
	char stack[8192];
	int frames = Accelerator_GetPluginStack(stack, sizeof(stack));

	LogMessage("[accelerator probe] %s: %d frame(s)", tag, frames);
	if (frames > 0)
	{
		LogExcerpt(stack);
	}
	else if (frames == 0)
	{
		LogError("[accelerator probe] 0 frames while a plugin was running - the capture is not working");
	}
	else
	{
		LogError("[accelerator probe] the VM could not be asked for a stack: %s", stack);
	}

	PrintToServer("[accelerator probe] %s: %d frame(s)\n%s", tag, frames, stack);
}

/**
 * @brief Copies the trace into the log line by line.
 *
 * LogMessage takes one line, and a single multi-line call would be cut short.
 * Built a character at a time because SourcePawn has no substring slices.
 */
void LogExcerpt(const char[] stack)
{
	char line[512];
	int column = 0;
	int length = strlen(stack);

	// One past the end is visited too, so the final line gets flushed.
	for (int i = 0; i <= length; i++)
	{
		char ch = (i < length) ? stack[i] : '\n';
		bool breakLine = (ch == '\n' || column == sizeof(line) - 1);

		if (breakLine)
		{
			line[column] = '\0';
			if (column > 0)
			{
				LogMessage("[accelerator probe] %s", line);
			}
			column = 0;
		}

		if (!breakLine)
		{
			line[column] = ch;
			column++;
		}
	}
}

public Action Command_PrintStack(int client, int args)
{
	char stack[8192];
	int frames = Accelerator_GetPluginStack(stack, sizeof(stack));

	if (frames < 0)
	{
		ReplyToCommand(client, "[accelerator] the VM could not be asked for a stack: %s", stack);
		return Plugin_Handled;
	}

	if (frames == 0)
	{
		ReplyToCommand(client, "[accelerator] 0 frames while a plugin command was running - the capture is not measuring what it claims.");
		return Plugin_Handled;
	}

	ReplyToCommand(client, "[accelerator] %d frame(s):", frames);
	ReplyToCommand(client, "%s", stack);
	return Plugin_Handled;
}

/**
 * @brief Jumps to address 1 through the sdktools SDKCall native.
 *
 * This is the shape of the crashes that matter: the fault happens in C++ code
 * reached from a native, so the machine stack shows sdktools and nothing about
 * which plugin asked for it. Only the VM's own invoke stack does that.
 */
void CrashInsideNative()
{
	StartPrepSDKCall(SDKCall_Raw);
	if (!PrepSDKCall_SetAddress(view_as<Address>(1)))
	{
		LogError("PrepSDKCall_SetAddress refused, cannot crash this way");
		return;
	}

	Handle call = EndPrepSDKCall();
	if (call == INVALID_HANDLE)
	{
		LogError("EndPrepSDKCall failed, cannot crash this way");
		return;
	}

	// SDKCall_Raw takes a this pointer as its first argument. sdktools rejects a
	// null one, and anything below 0x10000 (vcaller.cpp: "ThisPtr address cannot be
	// null" / VALID_MINIMUM_MEMORY_ADDRESS). Without it this is a plugin exception,
	// not a crash - the process keeps running and no report is written, which is
	// exactly the wrong outcome for a test whose purpose is to produce a report.
	// The value is never dereferenced by us: the call itself jumps to 0x1 and faults.
	SDKCall(call, view_as<Address>(0x10000));
	delete call;
}

void CrashNestedMiddle()
{
	CrashInsideNative();
}

public Action Command_Crash(int client, int args)
{
	char arg[16];
	GetCmdArg(1, arg, sizeof(arg));
	if (strcmp(arg, "confirm") != 0)
	{
		ReplyToCommand(client, "[accelerator] this ends the server process. Re-run as: sm_accel_crash confirm");
		return Plugin_Handled;
	}

	LogMessage("deliberate crash requested through sm_accel_crash");
	PrintToServer("[accelerator] crashing now; look for the SOURCEPAWN STACK section in the next report");

	// Two scripted frames deep so the recorded trace has visible depth.
	CrashNestedMiddle();
	return Plugin_Handled;
}
