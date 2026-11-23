/**
 * applemod_ent_info.sp —— 准心/周边实体信息查询（写 stripper 用）
 *
 * 命令（管理员，ADMFLAG_GENERIC）：
 *   sm_entinfo            打印准心所指实体的完整信息（含 hammerid）
 *   sm_entnear [半径]     列出自己周围的所有 prop_* 实体（默认 256），含 origin / hammerid
 *   sm_entmodel <片段>    列出全场 model 或 classname 含该片段的实体
 *
 * 输出字段：index / classname / hammerid / targetname / model / origin / angles /
 *           solid / spawnflags / health / physdamagescale / parent / owner
 *
 * 说明：
 *   · hammerid 只有地图自带的实体才有（stripper add 出来的实体没有 hammerid，
 *     用 origin + model 匹配）；brush 实体（func_brush 等）也有自己的 hammerid。
 *   · 打在纯世界几何上时看不到 hammerid —— 改用 sm_entnear / sm_entmodel。
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "1.0.0"

#define MAX_LISTED 64

public Plugin myinfo =
{
	name        = "Applemod Aim Entity Info",
	author      = "apples1949",
	description = "打印准心实体信息(含 hammerid)，用于编写 stripper 配置",
	version     = PLUGIN_VERSION,
	url         = ""
};

public void OnPluginStart()
{
	RegConsoleCmd("sm_entinfo", Cmd_Aim, "打印准心所指实体信息（含 hammerid）");
	RegConsoleCmd("sm_ent_info", Cmd_Aim, "同 sm_entinfo");
	RegConsoleCmd("sm_entnear", Cmd_Near, "sm_entnear [半径]：列出周围 prop_* 实体（含 hammerid）");
	RegConsoleCmd("sm_entmodel", Cmd_Model, "sm_entmodel <片段>：列出 model/classname 含该片段的实体");
}

bool HasAccess(int client)
{
	if (client == 0)
		return true;

	return CheckCommandAccess(client, "sm_entinfo", ADMFLAG_GENERIC, true);
}

// ---------------------------------------------------------------- aim trace

public bool TraceFilter_IgnoreClient(int entity, int mask, any data)
{
	return entity != data;
}

Action Cmd_Aim(int client, int args)
{
	if (!HasAccess(client))
		return Plugin_Handled;

	if (client == 0)
	{
		ReplyToCommand(client, "[entinfo] 该命令只能在游戏内使用。");
		return Plugin_Handled;
	}

	float fEye[3], fAng[3];
	GetClientEyePosition(client, fEye);
	GetClientEyeAngles(client, fAng);

	Handle hTrace = TR_TraceRayFilterEx(fEye, fAng, MASK_SHOT, RayType_Infinite, TraceFilter_IgnoreClient, client);

	if (hTrace == null || !TR_DidHit(hTrace))
	{
		if (hTrace != null)
			delete hTrace;

		PrintToChat(client, "\x04[entinfo]\x01 准心没打到任何东西。");
		return Plugin_Handled;
	}

	int entity = TR_GetEntityIndex(hTrace);
	float fHit[3];
	TR_GetEndPosition(fHit, hTrace);

	float fDist = GetVectorDistance(fEye, fHit);
	delete hTrace;

	if (entity <= 0)
	{
		// 打在 worldspawn 上：世界几何没有 hammerid，给几个近处的 prop 作参考
		PrintToConsole(client, "[entinfo] 命中：世界几何(worldspawn)，距离 %.1f，坐标 %.1f %.1f %.1f", fDist, fHit[0], fHit[1], fHit[2]);
		PrintToConsole(client, "[entinfo] 世界几何没有 hammerid；用 sm_entnear 或 sm_entmodel 找目标 prop。");
		PrintToChat(client, "\x04[entinfo]\x01 打到的是世界几何（无 hammerid），试 \x03!entnear\x01。");
		return Plugin_Handled;
	}

	DumpEntity(client, entity, fDist);
	PrintToChat(client, "\x04[entinfo]\x01 实体 \x03#%d\x01 (%s) 已打印到控制台。", entity, "");
	return Plugin_Handled;
}

int GetPropIntAny(int entity, const char[] prop, int defValue)
{
	if (HasEntProp(entity, Prop_Data, prop))
		return GetEntProp(entity, Prop_Data, prop);
	if (HasEntProp(entity, Prop_Send, prop))
		return GetEntProp(entity, Prop_Send, prop);
	return defValue;
}

float GetPropFloatAny(int entity, const char[] prop, float defValue)
{
	if (HasEntProp(entity, Prop_Data, prop))
		return GetEntPropFloat(entity, Prop_Data, prop);
	if (HasEntProp(entity, Prop_Send, prop))
		return GetEntPropFloat(entity, Prop_Send, prop);
	return defValue;
}

void GetPropVectorAny(int entity, const char[] prop, float vec[3], bool bSendFirst)
{
	if (bSendFirst)
	{
		if (HasEntProp(entity, Prop_Send, prop))
		{
			GetEntPropVector(entity, Prop_Send, prop, vec);
			return;
		}
		if (HasEntProp(entity, Prop_Data, prop))
		{
			GetEntPropVector(entity, Prop_Data, prop, vec);
			return;
		}
	}
	else
	{
		if (HasEntProp(entity, Prop_Data, prop))
		{
			GetEntPropVector(entity, Prop_Data, prop, vec);
			return;
		}
		if (HasEntProp(entity, Prop_Send, prop))
		{
			GetEntPropVector(entity, Prop_Send, prop, vec);
			return;
		}
	}

	vec[0] = vec[1] = vec[2] = 0.0;
}

void DumpEntity(int client, int entity, float fDist)
{
	char sClass[64], sTarget[128], sModel[PLATFORM_MAX_PATH], sParent[64];
	GetEdictClassname(entity, sClass, sizeof(sClass));
	GetEntPropString(entity, Prop_Data, "m_iName", sTarget, sizeof(sTarget));
	GetEntPropString(entity, Prop_Data, "m_ModelName", sModel, sizeof(sModel));

	float fOrigin[3], fAngles[3];
	GetPropVectorAny(entity, "m_vecOrigin", fOrigin, true);
	GetPropVectorAny(entity, "m_angRotation", fAngles, false);

	int hammerid   = GetPropIntAny(entity, "m_iHammerID", 0);
	int solid      = GetPropIntAny(entity, "m_nSolidType", -1);
	int spawnflags = GetPropIntAny(entity, "m_spawnflags", -1);
	int health     = GetPropIntAny(entity, "m_iHealth", -1);
	float physscale = GetPropFloatAny(entity, "m_impactEnergyScale", -1.0);

	// 父实体 / 拥有者
	int parent = GetEntPropEnt(entity, Prop_Data, "m_pParent");
	int owner  = GetEntPropEnt(entity, Prop_Data, "m_hOwnerEntity");

	if (parent > 0)
	{
		char sPClass[64];
		GetEdictClassname(parent, sPClass, sizeof(sPClass));
		FormatEx(sParent, sizeof(sParent), "#%d(%s)", parent, sPClass);
	}
	else
		FormatEx(sParent, sizeof(sParent), "-");

	char sAngles[32];
	FormatEx(sAngles, sizeof(sAngles), "%.1f %.1f %.1f", fAngles[0], fAngles[1], fAngles[2]);

	PrintToConsole(client, "===== entinfo #%d%s =====", entity, fDist >= 0.0 ? " (准心命中)" : "");
	if (fDist >= 0.0)
		PrintToConsole(client, "[entinfo] 距离: %.1f", fDist);
	PrintToConsole(client, "[entinfo] classname : %s", sClass);
	PrintToConsole(client, "[entinfo] hammerid  : %d%s", hammerid, hammerid > 0 ? "" : "  (0 = 非地图自带实体 / stripper add 出来的)");
	PrintToConsole(client, "[entinfo] targetname: %s", sTarget[0] != '\0' ? sTarget : "(空)");
	PrintToConsole(client, "[entinfo] model     : %s", sModel[0] != '\0' ? sModel : "(无)");
	PrintToConsole(client, "[entinfo] origin    : %.3f %.3f %.3f", fOrigin[0], fOrigin[1], fOrigin[2]);
	PrintToConsole(client, "[entinfo] angles    : %s", sAngles);
	PrintToConsole(client, "[entinfo] solid     : %d", solid);
	PrintToConsole(client, "[entinfo] spawnflags: %d", spawnflags);
	if (health >= 0)
		PrintToConsole(client, "[entinfo] health    : %d", health);
	if (physscale >= 0.0)
		PrintToConsole(client, "[entinfo] physdamagescale: %.3f", physscale);
	PrintToConsole(client, "[entinfo] parent    : %s", sParent);
	PrintToConsole(client, "[entinfo] owner     : %d", owner);

	// 直接给出可粘进 stripper 的 match 片段
	if (sModel[0] != '\0')
	{
		PrintToConsole(client, "[entinfo] --- stripper match 片段 ---");
		PrintToConsole(client, "[entinfo] \"classname\" \"%s\"", sClass);
		PrintToConsole(client, "[entinfo] \"model\" \"%s\"", sModel);
		if (hammerid > 0)
			PrintToConsole(client, "[entinfo] \"hammerid\" \"%d\"", hammerid);
		else
			PrintToConsole(client, "[entinfo] \"origin\" \"%.3f %.3f %.3f\"", fOrigin[0], fOrigin[1], fOrigin[2]);
	}
}

// ---------------------------------------------------------------- near list

Action Cmd_Near(int client, int args)
{
	if (!HasAccess(client))
		return Plugin_Handled;

	if (client == 0)
	{
		ReplyToCommand(client, "[entinfo] 该命令只能在游戏内使用。");
		return Plugin_Handled;
	}

	float fRadius = 256.0;
	if (args >= 1)
	{
		char sArg[16];
		GetCmdArg(1, sArg, sizeof(sArg));
		fRadius = StringToFloat(sArg);
	}

	if (fRadius <= 0.0 || fRadius > 4096.0)
		fRadius = 256.0;

	float fPos[3];
	GetClientAbsOrigin(client, fPos);

	int maxEntities = GetMaxEntities();
	int count = 0;

	PrintToConsole(client, "===== entnear 半径 %.0f @ %.1f %.1f %.1f =====", fRadius, fPos[0], fPos[1], fPos[2]);

	for (int i = MaxClients + 1; i < maxEntities && count < MAX_LISTED; i++)
	{
		if (!IsValidEdict(i))
			continue;

		char sClass[64];
		GetEdictClassname(i, sClass, sizeof(sClass));
		if (strncmp(sClass, "prop_", 5) != 0 && strncmp(sClass, "func_", 5) != 0)
			continue;

		float fOrigin[3];
		GetPropVectorAny(i, "m_vecOrigin", fOrigin, true);

		float fDist = GetVectorDistance(fPos, fOrigin);
		if (fDist > fRadius)
			continue;

		char sModel[PLATFORM_MAX_PATH], sTarget[128];
		GetEntPropString(i, Prop_Data, "m_ModelName", sModel, sizeof(sModel));
		GetEntPropString(i, Prop_Data, "m_iName", sTarget, sizeof(sTarget));
		int hammerid = GetPropIntAny(i, "m_iHammerID", 0);

		PrintToConsole(client, "#%-5d %-24s hammerid=%-8d %-6.0f %-44s %-22s %s",
			i, sClass, hammerid, fDist, sModel, sTarget[0] != '\0' ? sTarget : "-",
			"");
		count++;
	}

	if (count == 0)
		PrintToConsole(client, "[entinfo] 半径内没有 prop_* / func_* 实体，试试放大半径：sm_entnear 1024");
	else
		PrintToConsole(client, "[entinfo] 共 %d 个（上限 %d）。", count, MAX_LISTED);

	return Plugin_Handled;
}

// ---------------------------------------------------------------- by model

Action Cmd_Model(int client, int args)
{
	if (!HasAccess(client))
		return Plugin_Handled;

	if (client == 0 && args < 1)
	{
		ReplyToCommand(client, "[entinfo] 用法：sm_entmodel <模型名或 classname 片段>");
		return Plugin_Handled;
	}

	if (args < 1)
	{
		PrintToChat(client, "\x04[entinfo]\x01 用法：\x03!entmodel trashbin\x01（模型名或 classname 片段）");
		return Plugin_Handled;
	}

	char sNeedle[128];
	GetCmdArgString(sNeedle, sizeof(sNeedle));
	TrimString(sNeedle);

	if (sNeedle[0] == '\0')
		return Plugin_Handled;

	int maxEntities = GetMaxEntities();
	int count = 0;

	PrintToConsole(client, "===== entmodel \"%s\" =====", sNeedle);

	for (int i = MaxClients + 1; i < maxEntities && count < MAX_LISTED; i++)
	{
		if (!IsValidEdict(i))
			continue;

		char sClass[64], sModel[PLATFORM_MAX_PATH];
		GetEdictClassname(i, sClass, sizeof(sClass));
		GetEntPropString(i, Prop_Data, "m_ModelName", sModel, sizeof(sModel));

		if (StrContains(sClass, sNeedle, false) == -1 && StrContains(sModel, sNeedle, false) == -1)
			continue;

		float fOrigin[3];
		GetPropVectorAny(i, "m_vecOrigin", fOrigin, true);
		int hammerid = GetPropIntAny(i, "m_iHammerID", 0);

		char sTarget[128];
		GetEntPropString(i, Prop_Data, "m_iName", sTarget, sizeof(sTarget));

		PrintToConsole(client, "#%-5d %-24s hammerid=%-8d %-40s %-40s %s",
			i, sClass, hammerid, sModel, sTarget[0] != '\0' ? sTarget : "-", "");
		PrintToConsole(client, "        origin \"%.3f %.3f %.3f\"", fOrigin[0], fOrigin[1], fOrigin[2]);
		count++;
	}

	if (count == 0)
		PrintToConsole(client, "[entinfo] 没有匹配 \"%s\" 的实体。", sNeedle);
	else
		PrintToConsole(client, "[entinfo] 共 %d 个（上限 %d）。", count, MAX_LISTED);

	return Plugin_Handled;
}
