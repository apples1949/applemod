/*
 *	l4d2_pipebomb_duration - 土制炸弹时长 = 引擎默认值 + 偏移量（默认 +1 秒），无输出
 *
 *	做法：启动 / 每次配置执行 / 换图时，用 GetConVarDefault() 读出 pipe_bomb_timer_duration
 *	的引擎默认值，再把当前值写成 默认 + l4d2_pipebomb_duration_offset。
 *	插件卸载时静默恢复引擎默认值。
 *
 *	不注册 cfg（不用 AutoExecConfig），参数由模式配置指定；不打印任何文字。
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define PLUGIN_VERSION "1.0.0"

ConVar g_hTarget;
ConVar g_hEnable;
ConVar g_hOffset;
bool   g_bApplied;

public Plugin myinfo =
{
	name = "l4d2_pipebomb_duration",
	author = "apples1949",
	description = "土制炸弹时长 = 引擎默认值 + 偏移（默认 +1 秒），无输出",
	version = PLUGIN_VERSION,
	url = "https://github.com/apples1949"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	if (GetEngineVersion() != Engine_Left4Dead2)
		return APLRes_SilentFailure;

	return APLRes_Success;
}

public void OnPluginStart()
{
	g_hTarget = FindConVar("pipe_bomb_timer_duration");
	if (g_hTarget == null)
		SetFailState("找不到 pipe_bomb_timer_duration");

	g_hEnable = CreateConVar("l4d2_pipebomb_duration_enable", "1",
		"1=把土雷时长设为「引擎默认+偏移」；0=不处理", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hOffset = CreateConVar("l4d2_pipebomb_duration_offset", "1.0",
		"在引擎默认时长上增加的秒数", FCVAR_NOTIFY, true, 0.0, true, 30.0);

	ApplyDuration();
}

public void OnConfigsExecuted()
{
	ApplyDuration();
}

public void OnMapStart()
{
	ApplyDuration();
}

public void OnPluginEnd()
{
	if (g_bApplied)
	{
		g_hTarget.RestoreDefault(false, false);
		g_bApplied = false;
	}
}

void ApplyDuration()
{
	if (g_hTarget == null || g_hEnable == null || !g_hEnable.BoolValue)
		return;

	char sDefault[32];
	GetConVarDefault(g_hTarget, sDefault, sizeof(sDefault));

	float fWant = StringToFloat(sDefault) + g_hOffset.FloatValue;
	if (fWant < 0.0)
		fWant = 0.0;

	if (g_hTarget.FloatValue != fWant)
		g_hTarget.SetFloat(fWant, false, false);

	g_bApplied = true;
}
