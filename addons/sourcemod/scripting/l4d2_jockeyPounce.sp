#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <multicolors>

#define HUNTER_DAMAGE_POUNCE_MSGID  12

#define Z_JOCKEY                    5
#define TEAM_INFECTED               3

/* 落地宽限期(秒): Jockey 落地那一下贴到生还者身上时 FL_ONGROUND 可能先置位,
   这段时间内仍然沿用落地前的高度; 超出即判定为普通(地面)突袭, 高度按 0 计 */
#define POUNCE_LAND_GRACE           0.3

/* 参考 Hunter 高扑机制: 落差不足 300u 不产生高扑伤害, 1300u 达到伤害曲线峰值(= cap, 默认 25) */
#define POUNCE_MIN_HEIGHT           300.0
#define POUNCE_MAX_HEIGHT           1300.0

ConVar g_hEnabled;
ConVar g_hBlindAmount;
ConVar g_hPounceScale;
ConVar g_hPounceCap;
ConVar g_hPounceMinShow;
ConVar g_hPounceDisplay;
ConVar g_hPounceDisplayMax;
ConVar g_hPounceShowHeight;

/* 高扑高度基准: 只在"离地 → 落地"这一段连续滞空期内有效,
   落地(或不再是可以取扑的 Jockey: 阵亡/变回幽灵/换阵营)立即作废, 防止沿用旧高度 */
float startPosition[MAXPLAYERS + 1][3];
bool isAirborne[MAXPLAYERS + 1];
float landTime[MAXPLAYERS + 1];

UserMsg g_FadeUserMsgId;

public Plugin myinfo =
{
	name = "L4D2 Jockey Pounce Damage Confogl Edition",
	author = "apples1949",
	description = "Inflicts distance bonus damage to the jockey's victim if the latter has been pounced from a great height.",
	version = "1.3"
};

public void OnPluginStart()
{
	g_hEnabled			= CreateConVar("l4d2_JockeyPounce_enabled", "1", "启用/禁用插件");
	g_hBlindAmount		= CreateConVar("l4d2_JockeyPounce_blind", "200", "jockey使玩家致盲的程度 (0: 不致盲, 255:完全致盲 RGB值)");
	g_hPounceScale		= CreateConVar("l4d2_JockeyPounce_scale", "0.5", "实际伤害倍数 (伤害曲线参考 Hunter 高扑: 300u 起算, 1300u 到峰值; 0.5 = 实际伤害减半)");
	g_hPounceCap		= CreateConVar("l4d2_JockeyPounce_cap", "25", "高扑伤害上限 (同时是 1300u 落差时的曲线峰值)");
	g_hPounceMinShow	= CreateConVar("l4d2_JockeyPounce_minshow", "1", "至少造成多少突袭伤害才会显示相关提示信息");
	g_hPounceDisplay	= CreateConVar("l4d2_JockeyPounce_display", "1", "如何显示相关提示信息, 0 - 关闭, 1 - 聊天框, 2 - 屏幕中心");
	g_hPounceDisplayMax	= CreateConVar("l4d2_JockeyPounce_display_max", "0", "是否显示突袭伤害上限");
	g_hPounceShowHeight	= CreateConVar("l4d2_JockeyPounce_display_height", "1", "是否显示高扑高度");

	HookEvent("jockey_ride", Event_JockeyRide);
	HookEvent("jockey_ride_end", Event_JockeyRideEnd);
	HookEvent("player_incapacitated", Event_Incap);
	HookEvent("player_jump", Event_JockeyJump);

	g_FadeUserMsgId = GetUserMessageId("Fade");
}

/* -----------------------------------------------------------
	事件回调
----------------------------------------------------------- */

/* Jockey 起跳(技能突袭也走这个事件): 记录本段滞空期的起点 */
public Action Event_JockeyJump(Event event, const char[] name, bool dontBroadcast)
{
	if (g_hEnabled.BoolValue)
	{
		int client = GetClientOfUserId(event.GetInt("userid"));

		/* 已经滞空时只有在"还踩在地面上"的起跳才刷新起点,
		   避免空中重复起跳把高度基准压低(落地漏检时这里也能兜住) */
		if (IsJockey(client) && (!isAirborne[client] || (GetEntityFlags(client) & FL_ONGROUND) != 0))
		{
			GetClientAbsOrigin(client, startPosition[client]);
			isAirborne[client] = true;
		}
	}
	return Plugin_Continue;
}

public Action Event_Incap(Event event, const char[] name, bool dontBroadcast)
{
	if (g_hEnabled.BoolValue)
	{
		int client = GetClientOfUserId(event.GetInt("userid"));
		if (client > 0)
		{
			PerformBlind(client, 0);
		}
	}
	return Plugin_Continue;
}

public Action Event_JockeyRideEnd(Event event, const char[] name, bool dontBroadcast)
{
	if (g_hEnabled.BoolValue)
	{
		int victim = GetClientOfUserId(event.GetInt("victim"));
		if (victim > 0)
		{
			PerformBlind(victim, 0);
		}
	}
	return Plugin_Continue;
}

public Action Event_JockeyRide(Event event, const char[] name, bool dontBroadcast)
{
	if (g_hEnabled.BoolValue)
	{
		int client = GetClientOfUserId(event.GetInt("userid"));
		int victim = GetClientOfUserId(event.GetInt("victim"));

		if (IsJockey(client))
		{
			/* 结算前先刷新一次滞空状态: 已经落地就不再沿用落地前的起跳点 */
			TrackAirborne(client);
			DistanceJumped(client, victim);
		}

		if (victim > 0)
		{
			PerformBlind(victim, g_hBlindAmount.IntValue);
		}
	}
	return Plugin_Continue;
}

/* 每帧跟踪 Jockey 的滞空状态(人类/BOT 都会走到这里):
   只有"离地 → 落地"这段连续滞空期内的起点才允许用作高扑高度.
   这里不看 enabled: 状态必须一直跟着走, 中途开关插件才不会串数据 */
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	TrackAirborne(client);
	return Plugin_Continue;
}

/* -----------------------------------------------------------
	高扑高度
----------------------------------------------------------- */

void TrackAirborne(int client)
{
	if (!IsJockey(client))
	{
		/* 幽灵/阵亡/换阵营: 之前记录的滞空期一律作废 */
		isAirborne[client] = false;
		landTime[client] = 0.0;
		return;
	}

	/* 梯子不算滞空(爬梯下降不能当成坠落高度) */
	bool onGround = (GetEntityFlags(client) & FL_ONGROUND) != 0 || GetEntityMoveType(client) == MOVETYPE_LADDER;

	if (onGround)
	{
		if (isAirborne[client])
		{
			isAirborne[client] = false;
			landTime[client] = GetGameTime();
		}
	}
	else if (!isAirborne[client])
	{
		/* 刚离地(走下落差/被击飞/起跳): 以当前位置作为本段滞空期的高度基准 */
		isAirborne[client] = true;
		GetClientAbsOrigin(client, startPosition[client]);
	}
}

/* 本次骑乘的有效高扑高度(游戏单位): 没有连续滞空期且不在落地宽限期内时返回 0 */
float GetPounceHeight(int client)
{
	if (!isAirborne[client])
	{
		/* 落地宽限: 落地和取扑几乎同帧时(刚落地就贴到生还者)仍沿用落地前的高度.
		   时间差必须为正, 换图后游戏时间归零也不会把旧时间戳误判成"刚落地" */
		float sinceLanded = GetGameTime() - landTime[client];

		if (!(landTime[client] > 0.0 && sinceLanded >= 0.0 && sinceLanded <= POUNCE_LAND_GRACE))
		{
			return 0.0;
		}
	}

	float position[3];
	GetClientAbsOrigin(client, position);

	return startPosition[client][2] - position[2];
}

void DistanceJumped(int client, int victim)
{
	/* 高扑高度(游戏单位): 只认本次连续滞空期内的落差 */
	float pounceHeight = GetPounceHeight(client);

	/* 参考 Hunter 高扑机制: 落差不足 300u 没有高扑伤害;
	   300u → 1300u 线性涨到曲线峰值(cap, 默认 25), 落差再大也只取峰值;
	   最后乘 scale 得到实际伤害(默认 0.5 = 减半) */
	float actualDamage = 0.0;
	if (pounceHeight >= POUNCE_MIN_HEIGHT)
	{
		float ratio = (pounceHeight - POUNCE_MIN_HEIGHT) / (POUNCE_MAX_HEIGHT - POUNCE_MIN_HEIGHT);
		if (ratio > 1.0)
		{
			ratio = 1.0;
		}

		actualDamage = ratio * g_hPounceCap.FloatValue * g_hPounceScale.FloatValue;

		/* scale > 1 时兜底: 实际伤害同样不超过上限 */
		if (actualDamage > g_hPounceCap.FloatValue)
		{
			actualDamage = g_hPounceCap.FloatValue;
		}
	}

	int damage = RoundFloat(actualDamage);

	/* 不足 1 点(含 < 300u 的非高扑): 不结算、不提示、不发特感伤害数字 */
	if (damage <= 0)
	{
		return;
	}

	if (damage >= g_hPounceMinShow.IntValue)
	{
		char extra[128];
		extra[0] = '\0';

		if (g_hPounceDisplayMax.BoolValue)
		{
			Format(extra, sizeof(extra), "突袭伤害上限为 %d", g_hPounceCap.IntValue);
		}

		if (g_hPounceShowHeight.BoolValue)
		{
			char heightInfo[64];
			Format(heightInfo, sizeof(heightInfo), "高扑高度 %.0f", pounceHeight);

			if (extra[0] != '\0')
			{
				StrCat(extra, sizeof(extra), " ");
			}
			StrCat(extra, sizeof(extra), heightInfo);
		}

		if (!IsFakeClient(client))
		{
			if (g_hPounceDisplay.IntValue == 1)
			{
				CPrintToChatAll("{blue}[{default}JockeyPounce{blue}]{default} {green}%N{default} ({olive}jockey{default}) 突袭 {green}%N{default} 造成了 {olive}%d{default} 伤害 %s", client, victim, damage, extra);
			}
			if (g_hPounceDisplay.IntValue == 2)
			{
				PrintHintTextToAll("[JockeyPounce] %N (jockey)突袭 %N 造成了 %d 伤害 %s", client, victim, damage, extra);
			}
		}
	}

	// timer idea by dirtyminuth, damage dealing by pimpinjuice http://forums.alliedmods.net/showthread.php?t=111684
	// added some L4D2 specific checks
	DataPack pack = CreateDataPack();
	pack.WriteCell(damage);
	pack.WriteCell(victim);
	pack.WriteCell(client);

	CreateTimer(0.1, timer_stock_applyDamage, pack, TIMER_FLAG_NO_MAPCHANGE);
}

/* -----------------------------------------------------------
	伤害结算 / 提示
----------------------------------------------------------- */

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

/* -----------------------------------------------------------
	工具
----------------------------------------------------------- */

/* 是否是"可以取扑的 Jockey"(幽灵状态不算) */
bool IsJockey(int client)
{
	return (client > 0
		&& client <= MaxClients
		&& IsClientInGame(client)
		&& GetClientTeam(client) == TEAM_INFECTED
		&& GetEntProp(client, Prop_Send, "m_zombieClass") == Z_JOCKEY
		&& !GetEntProp(client, Prop_Send, "m_isGhost", 1));
}
