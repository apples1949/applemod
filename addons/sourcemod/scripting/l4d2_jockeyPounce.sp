#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <multicolors>

#define HUNTER_DAMAGE_POUNCE_MSGID  12

ConVar g_hEnabled;
ConVar g_hBlindAmount;
ConVar g_hPounceScale;
ConVar g_hPounceCap;
ConVar g_hPounceMinShow;
ConVar g_hPounceDisplay;
ConVar g_hPounceDisplayMax;

float startPosition[MAXPLAYERS + 1][3];
float endPosition[MAXPLAYERS + 1][3];

UserMsg g_FadeUserMsgId;

public Plugin myinfo =
{
	name = "L4D2 Jockey Pounce Damage Confogl Edition",
	author = "apples1949",
	description = "Inflicts distance bonus damage to the jockey's victim if the latter has been pounced from a great height.",
	version = "1.1"
};

public void OnPluginStart()
{
	g_hEnabled			= CreateConVar("l4d2_JockeyPounce_enabled", "1", "启用/禁用插件");
	g_hBlindAmount		= CreateConVar("l4d2_JockeyPounce_blind", "200", "jockey使玩家致盲的程度 (0: 不致盲, 255:完全致盲 RGB值)");
	g_hPounceScale		= CreateConVar("l4d2_JockeyPounce_scale", "1.0", "jockey突袭伤害倍数 (例子: 0.5 为正常突袭伤害的一半, 5 为正常突袭伤害的5倍)");
	g_hPounceCap		= CreateConVar("l4d2_JockeyPounce_cap", "25", "突袭最大伤害");
	g_hPounceMinShow	= CreateConVar("l4d2_JockeyPounce_minshow", "1", "至少造成多少突袭伤害才会显示相关提示信息");
	g_hPounceDisplay	= CreateConVar("l4d2_JockeyPounce_display", "1", "如何显示相关提示信息, 0 - 关闭, 1 - 聊天框, 2 - 屏幕中心");
	g_hPounceDisplayMax	= CreateConVar("l4d2_JockeyPounce_display_max", "0", "是否显示突袭伤害上限");

	HookEvent("jockey_ride", Event_JockeyRide);
	HookEvent("jockey_ride_end", Event_JockeyRideEnd);
	HookEvent("player_incapacitated", Event_Incap);
	HookEvent("player_jump", Event_JockeyJump);

	g_FadeUserMsgId = GetUserMessageId("Fade");
}

public Action Event_JockeyJump(Event event, const char[] name, bool dontBroadcast)
{
	if (g_hEnabled.BoolValue)
	{
		char ClientModel[128];
		int client = GetClientOfUserId(event.GetInt("userid"));
		GetClientModel(client, ClientModel, sizeof(ClientModel));
		if (StrContains(ClientModel, "jockey", false) >= 0)
		{
			GetClientAbsOrigin(client, startPosition[client]);
		}
	}
	return Plugin_Continue;
}

public Action Event_Incap(Event event, const char[] name, bool dontBroadcast)
{
	if (g_hEnabled.BoolValue)
	{
		int client = GetClientOfUserId(event.GetInt("userid"));
		PerformBlind(client, 0);
	}
	return Plugin_Continue;
}

public Action Event_JockeyRideEnd(Event event, const char[] name, bool dontBroadcast)
{
	if (g_hEnabled.BoolValue)
	{
		int victim = GetClientOfUserId(event.GetInt("victim"));
		PerformBlind(victim, 0);
	}
	return Plugin_Continue;
}

public Action Event_JockeyRide(Event event, const char[] name, bool dontBroadcast)
{
	if (g_hEnabled.BoolValue)
	{
		int client = GetClientOfUserId(event.GetInt("userid"));
		int victim = GetClientOfUserId(event.GetInt("victim"));

		GetClientAbsOrigin(client, endPosition[client]);
		DistanceJumped(client, victim);
		PerformBlind(victim, g_hBlindAmount.IntValue);
	}
	return Plugin_Continue;
}

void DistanceJumped(int client, int victim)
{
	int damage = RoundFloat(startPosition[client][2] - endPosition[client][2]); // 简单粗暴 猴子高度差除100再平方就是高扑伤害了 难怪有伤害倍数

	if (damage < 0)
	{
		return;
	}

	damage = RoundFloat(damage / 100.0);
	damage = RoundFloat((((damage * damage) * 0.8) + 1) * g_hPounceScale.FloatValue);

	if (damage > g_hPounceCap.IntValue)
	{
		damage = g_hPounceCap.IntValue;
	}

	if (damage >= g_hPounceMinShow.IntValue)
	{
		char max[64];
		if (g_hPounceDisplayMax.BoolValue)
		{
			Format(max, sizeof(max), "突袭伤害上限为 %d", g_hPounceCap.IntValue);
		}
		else
		{
			Format(max, sizeof(max), "");
		}
		if (!IsFakeClient(client))
		{
			if (g_hPounceDisplay.IntValue == 1)
			{
				CPrintToChatAll("{blue}[{default}JockeyPounce{blue}]{default} {green}%N{default} ({olive}jockey{default}) 突袭 {green}%N{default} 造成了 {olive}%d{default} 伤害 %s", client, victim, damage, max);
			}
			if (g_hPounceDisplay.IntValue == 2)
			{
				PrintHintTextToAll("[JockeyPounce] %N (jockey)突袭 %N 造成了 %d 伤害 %s", client, victim, damage, max);
			}
		}
	}

	// timer idea by dirtyminuth, damage dealing by pimpinjuice http://forums.alliedmods.net/showthread.php?t=111684
	// added some L4D2 specific checks
	DataPack pack = CreateDataPack();
	pack.WriteCell(damage);
	pack.WriteCell(victim);
	pack.WriteCell(client);

	CreateTimer(0.1, timer_stock_applyDamage, pack);
}

public Action timer_stock_applyDamage(Handle timer, DataPack pack)
{
	pack.Reset();
	int damage = pack.ReadCell();
	int victim = pack.ReadCell();
	int attacker = pack.ReadCell();
	delete pack;

	if (!IsClientInGame(victim))
	{
		return Plugin_Continue;
	}

	float victimPos[3];
	char strDamage[16];
	char strDamageTarget[16];

	GetClientEyePosition(victim, victimPos);
	IntToString(damage, strDamage, sizeof(strDamage));
	Format(strDamageTarget, sizeof(strDamageTarget), "hurtme%d", victim);

	int entPointHurt = CreateEntityByName("point_hurt");
	if (entPointHurt == -1)
	{
		return Plugin_Continue;
	}

	// Config, create point_hurt
	DispatchKeyValue(victim, "targetname", strDamageTarget);
	DispatchKeyValue(entPointHurt, "DamageTarget", strDamageTarget);
	DispatchKeyValue(entPointHurt, "Damage", strDamage);
	DispatchKeyValue(entPointHurt, "DamageType", "0"); // DMG_GENERIC
	DispatchSpawn(entPointHurt);

	// Teleport, activate point_hurt
	TeleportEntity(entPointHurt, victimPos, NULL_VECTOR, NULL_VECTOR);
	AcceptEntityInput(entPointHurt, "Hurt", (attacker && attacker < MaxClients && IsClientInGame(attacker)) ? attacker : -1);

	// Config, delete point_hurt
	DispatchKeyValue(entPointHurt, "classname", "point_hurt");
	DispatchKeyValue(victim, "targetname", "null");
	RemoveEdict(entPointHurt);

	// Dispatch global UserMessage notification of the event
	GlobalPounceAnnouncement(attacker, victim, damage);

	return Plugin_Continue;
}

void PerformBlind(int target, int amount)
{
	int targets[2];
	targets[0] = target;

	Handle message = StartMessageEx(g_FadeUserMsgId, targets, 1);
	if (message == null)
	{
		return;
	}

	BfWriteShort(message, 1536);
	BfWriteShort(message, 1536);

	if (amount == 0)
	{
		BfWriteShort(message, (0x0001 | 0x0010));
	}
	else
	{
		BfWriteShort(message, (0x0002 | 0x0008));
	}

	BfWriteByte(message, 0);
	BfWriteByte(message, 0);
	BfWriteByte(message, 0);
	BfWriteByte(message, amount);

	EndMessage();
}

void GlobalPounceAnnouncement(int attacker, int victim, int damage)
{
	Handle bf = StartMessageAll("PZDmgMsg");
	if (bf == null)
	{
		return;
	}

	BfWriteByte(bf, HUNTER_DAMAGE_POUNCE_MSGID);
	BfWriteShort(bf, GetClientUserId(attacker));
	BfWriteShort(bf, GetClientUserId(victim));
	BfWriteShort(bf, 0);    // Unknown
	BfWriteShort(bf, damage);

	EndMessage();
}
