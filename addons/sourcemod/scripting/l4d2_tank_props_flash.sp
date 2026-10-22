/**
 * ============================================================================
 *  l4d2_tank_props_flash.sp  -  坦克出现时全场高亮「可被坦克拍飞的移动物品」
 * ============================================================================
 *  需求：
 *    场上新出现坦克时，向【全场】（生还者 / 特感 / 旁观）显示所有可被坦克
 *    拍飞的移动物品的轮廓发光，持续 5 秒（可配）。
 *
 *  判定「可被坦克拍飞的移动物品」：
 *    1) prop_physics 系列 且 m_hasTankGlow == 1
 *       —— 引擎自己就是用这个标记认定「坦克能拍飞 / 能触发坦克专属高亮」的道具
 *          （油桶类、垃圾箱、叉车、路障、汽车零件等）
 *    2) prop_car_alarm —— 汽车警报器，坦克可以拍飞（也可被子弹打爆）
 *
 *  实现方式（沿用 MoYu / Forgetest "l4d2_tank_support" 的做法）：
 *    直接给道具本体写 m_iGlowType 会和引擎自己的「坦克瞄准高亮」抢同一个字段，
 *    因此这里给每个可拍飞道具生成一个「隐形克隆模型」：
 *      prop_dynamic_override + 同一个模型 + RENDER_TRANSCOLOR 全透明（模型看不见）
 *      + m_iGlowType=3（常亮）+ 发光颜色/距离 + SetParent 挂到道具本体上
 *    → 道具被拍飞/滚动时轮廓跟着动；克隆不参与碰撞、不挡子弹。
 *
 *    MoYu 原插件用 SDKHook_SetTransmit 只放行特感 / 旁观；本插件要「全场都看到」，
 *    因此不做任何队伍过滤（所有客户端都收到克隆实体）。
 *
 *  ConVar（全部可热改，改颜色 / 距离下一次坦克出现即生效）：
 *    l4d2_tankpropsflash_enable        1     总开关
 *    l4d2_tankpropsflash_duration      5.0   发光持续秒数
 *    l4d2_tankpropsflash_color         "255 200 0"  发光颜色 RGB
 *    l4d2_tankpropsflash_range         3250  轮廓可见距离（HU），0 = 无限
 *    l4d2_tankpropsflash_min_range     250   该距离内不再画轮廓
 *    l4d2_tankpropsflash_flashing      0     1 = 轮廓闪烁
 *
 *  调试命令：sm_tankpropsflash  —— 手动触发一次（不必等坦克出现）
 * ============================================================================
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>

#define PLUGIN_VERSION  "1.0.0"

// 与 MoYu l4d2_tank_support 一致的克隆实体类名
#define CLONE_CLASSNAME "prop_dynamic_override"

#define GLOW_CONSTANT   3   // L4D2Glow_Constant

ConVar g_cvEnable;
ConVar g_cvDuration;
ConVar g_cvColor;
ConVar g_cvRange;
ConVar g_cvRangeMin;
ConVar g_cvFlashing;
ConVar g_cvMaxProps;

ArrayList g_aClones;          // 克隆实体的 EntRef 列表
Handle    g_hCleanupTimer;    // 到点清场的 timer
int       g_iColor;           // 解析后的 RGB 整数（m_glowColorOverride）

float     g_vZero[3];         // {0,0,0}，SetParent 后把本地变换归零用

public Plugin myinfo =
{
	name        = "L4D2 Tank Props Flash",
	author      = "apples1949",
	description = "坦克出现时，向全场显示所有可被坦克拍飞的移动物品的轮廓 5 秒",
	version     = PLUGIN_VERSION,
	url         = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	if (GetEngineVersion() != Engine_Left4Dead2)
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 2.");
		return APLRes_SilentFailure;
	}

	return APLRes_Success;
}

public void OnPluginStart()
{
	g_cvEnable = CreateConVar("l4d2_tankpropsflash_enable", "1",
		"1=坦克出现时向全场高亮所有可被坦克拍飞的移动物品。0=关闭",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvDuration = CreateConVar("l4d2_tankpropsflash_duration", "5.0",
		"高亮持续秒数（默认 5 秒）",
		FCVAR_NOTIFY, true, 0.1, true, 60.0);

	g_cvColor = CreateConVar("l4d2_tankpropsflash_color", "255 200 0",
		"轮廓发光颜色，三个 0-255 的整数用空格分开（R G B）",
		FCVAR_NOTIFY);

	g_cvRange = CreateConVar("l4d2_tankpropsflash_range", "3250",
		"轮廓可见距离（HU），0=无限距离",
		FCVAR_NOTIFY, true, 0.0, true, 20000.0);

	g_cvRangeMin = CreateConVar("l4d2_tankpropsflash_min_range", "250",
		"小于该距离（HU）时不画轮廓，避免贴脸时满屏发光",
		FCVAR_NOTIFY, true, 0.0, true, 20000.0);

	g_cvFlashing = CreateConVar("l4d2_tankpropsflash_flashing", "0",
		"1=轮廓闪烁，0=常亮",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvMaxProps = CreateConVar("l4d2_tankpropsflash_max_props", "64",
		"一次最多高亮多少个道具（防止道具极多的地图在刷坦克瞬间产生网络尖峰）。0=不限制",
		FCVAR_NOTIFY, true, 0.0, true, 512.0);

	CreateConVar("l4d2_tankpropsflash_version", PLUGIN_VERSION,
		"l4d2_tank_props_flash 版本号",
		FCVAR_NOTIFY|FCVAR_DONTRECORD);

	// 本服惯例：参数写在模式 cfg 里，不自动生成 cfg/sourcemod/*.cfg
	//AutoExecConfig(true, "l4d2_tank_props_flash");

	g_cvColor.AddChangeHook(OnColorConVarChanged);
	ParseColor();

	g_aClones = new ArrayList();

	HookEvent("tank_spawn", Event_TankSpawn, EventHookMode_Post);
	HookEvent("round_start", Event_RoundReset, EventHookMode_PostNoCopy);
	HookEvent("round_end", Event_RoundReset, EventHookMode_PostNoCopy);

	RegAdminCmd("sm_tankpropsflash", Cmd_ManualFlash, ADMFLAG_GENERIC,
		"手动触发一次「可拍飞物品高亮」（调试用，不必等坦克出现）");
}

public void OnPluginEnd()
{
	ClearAllClones();
}

public void OnMapEnd()
{
	delete g_hCleanupTimer;
	g_hCleanupTimer = null;

	ClearAllClones();
}

// ===========================================================================
//  事件
// ===========================================================================

public void Event_RoundReset(Event event, const char[] name, bool dontBroadcast)
{
	delete g_hCleanupTimer;
	g_hCleanupTimer = null;

	ClearAllClones();
}

public void Event_TankSpawn(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnable.BoolValue)
	{
		return;
	}

	// 12v12 里可能同时 / 连续刷多只坦克，或者补位产生新坦克：
	// 直接按「新的一批」重来，并重置倒计时，行为可预期。
	StartFlash();
}

public Action Cmd_ManualFlash(int client, int args)
{
	if (!g_cvEnable.BoolValue)
	{
		ReplyToCommand(client, "[坦克道具高亮] 插件已关闭（l4d2_tankpropsflash_enable 0）");
		return Plugin_Handled;
	}

	int iCount = StartFlash();

	ReplyToCommand(client, "[坦克道具高亮] 已高亮 %d 个可被坦克拍飞的道具，持续 %.1f 秒",
		iCount, g_cvDuration.FloatValue);

	return Plugin_Handled;
}

/**
 * 重新开始一次「全场高亮」。
 * @return 本次高亮覆盖的道具数量
 */
int StartFlash()
{
	delete g_hCleanupTimer;
	g_hCleanupTimer = null;

	ClearAllClones();

	ParseColor();

	int iCount = CreateGlowForAllHittables();

	if (iCount <= 0)
	{
		return 0;
	}

	g_hCleanupTimer = CreateTimer(g_cvDuration.FloatValue, Timer_ClearAllClones, 0,
		TIMER_FLAG_NO_MAPCHANGE);

	return iCount;
}

public Action Timer_ClearAllClones(Handle timer)
{
	g_hCleanupTimer = null;

	ClearAllClones();

	return Plugin_Stop;
}

// ===========================================================================
//  扫描 / 克隆
// ===========================================================================

int CreateGlowForAllHittables()
{
	int iCreated = 0;
	int iMax = GetMaxEntities();
	int iCap = g_cvMaxProps.IntValue;   // 0 = 不限制

	for (int i = MaxClients + 1; i < iMax; i++)
	{
		if (iCap > 0 && iCreated >= iCap)
		{
			break;
		}

		if (!IsValidEntity(i))
		{
			continue;
		}

		if (!IsTankHittable(i))
		{
			continue;
		}

		if (CreateGlowClone(i) > 0)
		{
			iCreated++;
		}
	}

	return iCreated;
}

/**
 * 是否「坦克能拍飞的移动物品」。
 * 与 MoYu / Forgetest 的 IsTankHittable 判定保持一致：
 *   prop_physics* 且 m_hasTankGlow == 1，外加 prop_car_alarm。
 */
bool IsTankHittable(int iEntity)
{
	char sClass[64];

	if (!GetEdictClassname(iEntity, sClass, sizeof(sClass)))
	{
		return false;
	}

	if (StrContains(sClass, "prop_physics", false) == 0)
	{
		// 只有 CPhysicsProp 系列才有这个属性；道具被打碎/重建后可能没有属性
		if (!HasEntProp(iEntity, Prop_Send, "m_hasTankGlow"))
		{
			return false;
		}

		return GetEntProp(iEntity, Prop_Send, "m_hasTankGlow", 1) != 0;
	}

	if (StrEqual(sClass, "prop_car_alarm", false))
	{
		return true;
	}

	return false;
}

int CreateGlowClone(int iProp)
{
	char sModel[PLATFORM_MAX_PATH];

	sModel[0] = '\0';

	if (!GetEntPropString(iProp, Prop_Data, "m_ModelName", sModel, sizeof(sModel)))
	{
		return -1;
	}

	if (sModel[0] == '\0')
	{
		return -1;
	}

	int iClone = CreateEntityByName(CLONE_CLASSNAME);

	if (iClone <= 0 || !IsValidEntity(iClone))
	{
		return -1;
	}

	SetEntityModel(iClone, sModel);
	DispatchSpawn(iClone);

	// 不参与碰撞、不挡子弹
	SetEntProp(iClone, Prop_Send, "m_CollisionGroup", 0);
	SetEntProp(iClone, Prop_Send, "m_nSolidType", 0);

	// 模型全透明：只留下轮廓发光（轮廓走独立发光通路，不受 alpha 影响）
	SetEntityRenderMode(iClone, RENDER_TRANSCOLOR);
	SetEntityRenderColor(iClone, 0, 0, 0, 0);

	// 这个类没有发光属性（极少数自定义道具）：不生成垃圾实体
	if (!HasEntProp(iClone, Prop_Send, "m_iGlowType"))
	{
		RemoveEntity(iClone);

		return -1;
	}

	ApplyGlowProps(iClone);

	// 挂到道具本体上：道具被坦克拍飞、滚动时轮廓跟着动。
	// 注意顺序：SetParent 之后 m_vecOrigin / m_angRotation 变成本地坐标，
	// 所以必须先挂父、再把本地变换归零；否则克隆会被整体平移「父道具世界坐标」
	// 那么远，轮廓画到地图外，表现就是「根本没发光」。
	// （引擎若已自行补偿世界变换，这一步就是幂等空操作）
	SetVariantString("!activator");
	AcceptEntityInput(iClone, "SetParent", iProp);
	TeleportEntity(iClone, g_vZero, g_vZero, NULL_VECTOR);

	// StartGlowing 可能按 m_iInitialGlowState 重刷一遍发光属性，
	// 这里在输入之后再幂等补写一次，避免「实体生成了但不发光」。
	AcceptEntityInput(iClone, "StartGlowing");
	ApplyGlowProps(iClone);

	// 不做 SDKHook_SetTransmit 过滤 => 全场所有客户端都能看到（需求就是全场可见）
	g_aClones.Push(EntIndexToEntRef(iClone));

	return iClone;
}

/**
 * 幂等写入轮廓发光属性。
 */
void ApplyGlowProps(int iEntity)
{
	SetEntProp(iEntity, Prop_Send, "m_iGlowType", GLOW_CONSTANT);
	SetEntProp(iEntity, Prop_Send, "m_nGlowRange", g_cvRange.IntValue);
	SetEntProp(iEntity, Prop_Send, "m_nGlowRangeMin", g_cvRangeMin.IntValue);
	SetEntProp(iEntity, Prop_Send, "m_glowColorOverride", g_iColor);

	if (HasEntProp(iEntity, Prop_Send, "m_bFlashing"))
	{
		SetEntProp(iEntity, Prop_Send, "m_bFlashing", g_cvFlashing.BoolValue ? 1 : 0);
	}
}

void ClearAllClones()
{
	if (g_aClones == null)
	{
		return;
	}

	int iSize = g_aClones.Length;

	for (int i = 0; i < iSize; i++)
	{
		int iEnt = EntRefToEntIndex(g_aClones.Get(i));

		if (iEnt > 0 && iEnt != INVALID_ENT_REFERENCE && IsValidEntity(iEnt))
		{
			RemoveEntity(iEnt);
		}
	}

	g_aClones.Clear();
}

// ===========================================================================
//  工具
// ===========================================================================

void OnColorConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	ParseColor();
}

void ParseColor()
{
	char sValue[64];

	g_cvColor.GetString(sValue, sizeof(sValue));
	TrimString(sValue);

	g_iColor = GetColorValue(sValue);
}

/**
 * 解析 "R G B" -> m_glowColorOverride 整数。
 * 逐字符取三个数字，连续空格 / 逗号都能正确解析（ExplodeString 遇到
 * "255  200 0" 这种连续空格会切出空字段，导致颜色变成 0 = 看不见轮廓）。
 * 解析失败时退回白色，避免整屏黑轮廓。
 */
int GetColorValue(const char[] sValue)
{
	int iValues[3];
	int iCount = 0;
	int iLen = strlen(sValue);
	int i = 0;

	while (i < iLen && iCount < 3)
	{
		// 跳过所有分隔符
		while (i < iLen && !IsColorDigit(sValue[i]))
		{
			i++;
		}

		if (i >= iLen)
		{
			break;
		}

		int iStart = i;

		while (i < iLen && IsColorDigit(sValue[i]))
		{
			i++;
		}

		char sNum[8];
		int n = i - iStart;

		if (n > 7)
		{
			n = 7;
		}

		for (int k = 0; k < n; k++)
		{
			sNum[k] = sValue[iStart + k];
		}

		sNum[n] = '\0';

		iValues[iCount] = StringToInt(sNum);
		iCount++;
	}

	if (iCount != 3)
	{
		return 0xFFFFFF;
	}

	int iR = iValues[0];
	int iG = iValues[1];
	int iB = iValues[2];

	if (iR < 0) iR = 0;
	if (iR > 255) iR = 255;
	if (iG < 0) iG = 0;
	if (iG > 255) iG = 255;
	if (iB < 0) iB = 0;
	if (iB > 255) iB = 255;

	return iR + (iG * 256) + (iB * 65536);
}

bool IsColorDigit(const char c)
{
	return (c >= '0' && c <= '9');
}
