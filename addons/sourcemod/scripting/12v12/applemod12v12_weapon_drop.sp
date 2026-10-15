/**
 * Applemod 12v12 - 开局丢枪（替代枪柜）
 *
 * 开局（round_start 与 player_spawn 都发生后延迟 N 秒）把指定武器生成在
 * 「任意一名随机生还者脚下」，每个回合一次。
 *
 * 参考实现：
 *   1) Silvers - [L4D2] Melee In The Saferoom (l4d2_melee_in_the_saferoom.sp)
 *      · round_start / player_spawn 双标志 + CreateTimer(N, ...) 的生成时机
 *      · GetClientAbsOrigin() 取脚下坐标 + 随机抖动 + 随机偏航
 *   2) Silvers - [L4D & L4D2] Gun Cabinet (l4d_gun_cabinet.sp) 的 CreateWeapon()
 *      · L4D2 可拾取枪械实体的正确建法：solid 6 / rendermode 3 / disableshadows 1
 *      · TeleportEntity 后再 DispatchSpawn、m_iExtraPrimaryAmmo 给弹药、MOVETYPE_NONE 防滚
 *
 * 注意：
 *   · 生成时间必须晚于框架 (ConfoglCompMod) 在 round_start+0.3s 的武器清理扫描，
 *     所以默认 delay = 1.0 秒；配合 confogl_remove_chainsaw 0，电锯才不会被删。
 *   · 不生成 cfg（不用 AutoExecConfig），全部 cvar 由 confogl 的 12v12 配置下发。
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "1.0.0"

ConVar g_hEnable, g_hWeapons, g_hMode, g_hDelay, g_hSpread, g_hDebug;
ConVar g_hAmmoRifle, g_hAmmoChainsaw, g_hAmmoSniper;

bool g_bRoundStart, g_bPlayerSpawn, g_bSpawned;

public Plugin myinfo =
{
	name = "Applemod 12v12 Weapon Drop",
	author = "apples1949",
	version = PLUGIN_VERSION,
	description = "12v12 开局把指定武器（默认电锯/SG552/AWP/鸟狙）生成在随机生还者脚下；参考 Silvers 的 Melee In The Saferoom + Gun Cabinet",
	url = "https://github.com/apples1949/applemod"
};

public void OnPluginStart()
{
	CreateConVar("am12v12_wdrop_version", PLUGIN_VERSION, "开局丢枪插件版本", FCVAR_NOTIFY|FCVAR_DONTRECORD);
	g_hEnable  = CreateConVar("am12v12_wdrop_enable",  "1", "是否启用", _, true, 0.0, true, 1.0);
	g_hWeapons = CreateConVar("am12v12_wdrop_weapons", "weapon_chainsaw,weapon_rifle_sg552,weapon_sniper_awp,weapon_sniper_scout",
							  "开局生成的武器类名，英文逗号分隔（默认：电锯/SG552/AWP/鸟狙）");
	g_hMode    = CreateConVar("am12v12_wdrop_mode",    "0", "0=全部生成在同一名随机生还者脚下；1=每把各挑一名随机生还者", _, true, 0.0, true, 1.0);
	g_hDelay   = CreateConVar("am12v12_wdrop_delay",   "1.0", "回合开始后延迟多少秒生成（要晚于框架 round_start+0.3s 的武器清理）", _, true, 0.0, true, 30.0);
	g_hSpread  = CreateConVar("am12v12_wdrop_spread",  "20.0", "同一位置生成多把武器时的散开半径（避免叠在一起）", _, true, 0.0, true, 200.0);
	g_hDebug   = CreateConVar("am12v12_wdrop_debug",   "0", "1=在服务端控制台打印生成了什么、生成在谁脚下", _, true, 0.0, true, 1.0);

	// 弹药取游戏自己的 cvar（与枪柜插件同一套），取不到就不写该属性
	g_hAmmoRifle    = FindConVar("ammo_assaultrifle_max");
	g_hAmmoChainsaw = FindConVar("ammo_chainsaw_max");
	g_hAmmoSniper   = FindConVar("ammo_sniperrifle_max");

	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_PostNoCopy);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
}

public void OnMapEnd()
{
	ResetRound();
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	g_bRoundStart = true;
	TrySchedule();
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	g_bPlayerSpawn = true;
	TrySchedule();
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	ResetRound();
}

void ResetRound()
{
	g_bRoundStart = false;
	g_bPlayerSpawn = false;
	g_bSpawned = false;
}

// round_start 与 player_spawn 都发生后才排定生成（两者顺序在 L4D2 里不固定）
void TrySchedule()
{
	if (g_bSpawned || !g_bRoundStart || !g_bPlayerSpawn)
		return;

	g_bSpawned = true;
	CreateTimer(g_hDelay.FloatValue, Timer_SpawnWeapons, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_SpawnWeapons(Handle timer)
{
	if (!g_hEnable.BoolValue)
		return Plugin_Continue;

	char sList[512];
	g_hWeapons.GetString(sList, sizeof(sList));

	char aWeapons[16][64];
	int iCount = ExplodeString(sList, ",", aWeapons, sizeof(aWeapons), sizeof(aWeapons[]));
	if (iCount <= 0)
		return Plugin_Continue;

	// 清掉空格
	int iValid;
	for (int i = 0; i < iCount; i++)
	{
		TrimString(aWeapons[i]);
		if (aWeapons[i][0] == '\0')
			continue;

		if (i != iValid)
			strcopy(aWeapons[iValid], sizeof(aWeapons[]), aWeapons[i]);
		iValid++;
	}
	if (iValid <= 0)
		return Plugin_Continue;

	int iAnchor = GetRandomSurvivor();
	if (iAnchor <= 0)
	{
		if (g_hDebug.BoolValue)
			PrintToServer("[12v12 wdrop] 没有可用的生还者，跳过本回合生成");
		return Plugin_Continue;
	}

	float fSpread = g_hSpread.FloatValue;
	float vBase[3];
	GetClientAbsOrigin(iAnchor, vBase);

	// 方形散布（最多 4 把按四角摆放；超过 4 把的用随机抖动兜底）
	float fOff[4][2];
	fOff[0][0] = -fSpread; fOff[0][1] = -fSpread;
	fOff[1][0] =  fSpread; fOff[1][1] = -fSpread;
	fOff[2][0] = -fSpread; fOff[2][1] =  fSpread;
	fOff[3][0] =  fSpread; fOff[3][1] =  fSpread;

	for (int i = 0; i < iValid; i++)
	{
		int iTarget = iAnchor;
		if (g_hMode.IntValue == 1)
		{
			int iRand = GetRandomSurvivor();
			if (iRand > 0)
				iTarget = iRand;
		}

		float vPos[3];
		GetClientAbsOrigin(iTarget, vPos);
		vPos[2] += 15.0;                       // 抬到脚下略上方，避免卡进地板

		if (i < 4)
		{
			vPos[0] += fOff[i][0];
			vPos[1] += fOff[i][1];
		}
		else
		{
			vPos[0] += GetRandomFloat(-fSpread, fSpread);
			vPos[1] += GetRandomFloat(-fSpread, fSpread);
		}
		vPos[2] += GetRandomFloat(0.0, 5.0);

		SpawnWeapon(aWeapons[i], vPos, iTarget);
	}

	if (g_hDebug.BoolValue)
		PrintToServer("[12v12 wdrop] 已在 %N 脚下生成 %d 把武器（mode=%d）", iAnchor, iValid, g_hMode.IntValue);

	return Plugin_Continue;
}

void SpawnWeapon(const char[] sClassname, const float vPos[3], int iTarget)
{
	int iEntity = CreateEntityByName(sClassname);
	if (iEntity == -1)
	{
		LogError("[12v12 wdrop] 创建实体失败: %s", sClassname);
		return;
	}

	// 与枪柜插件 CreateWeapon() 一致：world 武器实体、不投影阴影
	DispatchKeyValue(iEntity, "solid", "6");
	DispatchKeyValue(iEntity, "rendermode", "3");
	DispatchKeyValue(iEntity, "disableshadows", "1");

	float vAng[3], vPos2[3];
	vPos2 = vPos;
	vAng[0] = 0.0;
	vAng[1] = GetRandomFloat(0.0, 360.0);
	vAng[2] = 0.0;

	TeleportEntity(iEntity, vPos2, vAng, NULL_VECTOR);
	DispatchSpawn(iEntity);

	int iAmmo = GetAmmoFor(sClassname);
	if (iAmmo >= 0)
		SetEntProp(iEntity, Prop_Send, "m_iExtraPrimaryAmmo", iAmmo, 4);

	SetEntityMoveType(iEntity, MOVETYPE_NONE);   // 防滚动/掉落（枪柜同做法）

	if (g_hDebug.BoolValue)
		PrintToServer("[12v12 wdrop]   %s 生成于 %N 脚下 (%.1f %.1f %.1f), 弹药 %d", sClassname, iTarget, vPos2[0], vPos2[1], vPos2[2], iAmmo);
}

// 弹药：步枪类走 ammo_assaultrifle_max；AWP/鸟狙/猎狙走 ammo_sniperrifle_max；电锯走 ammo_chainsaw_max
// 取不到对应 cvar 时返回 -1（不写属性，保留实体自身默认）
int GetAmmoFor(const char[] sClassname)
{
	if (StrEqual(sClassname, "weapon_chainsaw", false))
		return (g_hAmmoChainsaw != null) ? g_hAmmoChainsaw.IntValue : -1;

	if (StrEqual(sClassname, "weapon_sniper_awp", false)
		|| StrEqual(sClassname, "weapon_sniper_scout", false)
		|| StrEqual(sClassname, "weapon_hunting_rifle", false)
		|| StrEqual(sClassname, "weapon_sniper_military", false))
		return (g_hAmmoSniper != null) ? g_hAmmoSniper.IntValue : -1;

	if (StrEqual(sClassname, "weapon_smg", false)
		|| StrEqual(sClassname, "weapon_smg_silenced", false)
		|| StrEqual(sClassname, "weapon_smg_mp5", false))
	{
		ConVar hSmg = FindConVar("ammo_smg_max");
		return (hSmg != null) ? hSmg.IntValue : -1;
	}

	if (StrEqual(sClassname, "weapon_pumpshotgun", false)
		|| StrEqual(sClassname, "weapon_shotgun_chrome", false)
		|| StrEqual(sClassname, "weapon_autoshotgun", false)
		|| StrEqual(sClassname, "weapon_shotgun_spas", false))
	{
		ConVar hShotgun = FindConVar("ammo_shotgun_max");
		return (hShotgun != null) ? hShotgun.IntValue : -1;
	}

	// 其余（步枪类，含 rifle_sg552）
	return (g_hAmmoRifle != null) ? g_hAmmoRifle.IntValue : -1;
}

// 随机取一名在游戏内的生还者（优先活着的；都没有就返回 0）
int GetRandomSurvivor()
{
	int aAlive[MAXPLAYERS + 1], aAny[MAXPLAYERS + 1];
	int iAlive, iAny;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != 2)
			continue;

		aAny[iAny++] = i;
		if (IsPlayerAlive(i))
			aAlive[iAlive++] = i;
	}

	if (iAlive > 0)
		return aAlive[GetRandomInt(0, iAlive - 1)];
	if (iAny > 0)
		return aAny[GetRandomInt(0, iAny - 1)];

	return 0;
}
