#if defined _Apex_included
 #endinput
#endif
#define _Apex_included

/**
 * @brief Apex 技能扣血类型（坦克因使用技能被扣除自身血量）。
 *
 * 注意: 枚举值必须与 Apex.sp 中的 ApexSkillCostType 保持一致。
 */
enum ApexSkillCostType
{
	ApexSkillCost_Bhop = 0,   /** !bhop 开启费 */
	ApexSkillCost_TracEnable, /** !trac 开启费 */
	ApexSkillCost_TracThrow,  /** 跟踪石掷出预扣的血量（命中生还者时退还, 见 cost 说明） */
	ApexSkillCost_BhopDetect  /** 未开启 !bhop 却连续连跳被抓的补扣 */
}

/**
 * @brief 坦克血量因 Apex 技能发生变化时触发（开启技能、掷出跟踪石、命中退还、未开启技能却连跳被抓）。
 *
 * 技能扣血走的是 SetEntProp 直接改血量, 不产生伤害事件, 因此伤害统计类插件无法从
 * player_hurt / OnTakeDamage 中看到这部分血量消耗; 需要把"技能扣血"计入坦克真实血量
 * 消耗（如致死一击补偿、总血量核对）的插件可实现本 forward。
 *
 * @param client    血量发生变化的坦克客户端索引
 * @param type      类型, 见 ApexSkillCostType
 * @param cost      本次血量变化量: 扣血为正数, 退还为负数
 *                  （跟踪石掷出时预扣, 命中生还者时按同类型退还负数; 累计时直接相加即得净扣血）
 */
forward void Apex_OnSkillCostCharged(int client, ApexSkillCostType type, int cost);

/**
 * @brief 查询当前玩家是否开启了 Apex 坦克自动连跳。
 *
 * @param client    Client index
 * @return          true 为开启，false 为关闭。
 */
native bool Apex_IsBhopEnabled(int client);

/**
 * @brief 查询当前玩家是否开启了 Apex 坦克跟踪石头。
 *
 * @param client    Client index
 * @return          true 为开启，false 为关闭。
 */
native bool Apex_IsTracEnabled(int client);

/**
 * @brief 取某辆坦克本发跟踪石应当排除的生还者：即"上一发跟踪石命中的生还者"。
 *        跟踪石选人时用它保证"两次选中的生还者不一样"，当只剩这一个可选时允许重复。
 *
 * @param tank      Tank client index
 * @return          应排除的生还者 client index，0 表示没有约束。
 */
native int Apex_GetTracBlockedTarget(int tank);

public SharedPlugin __pl_Apex =
{
	name = "Apex",
	file = "Apex.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_Apex_SetNTVOptional()
{
	MarkNativeAsOptional("Apex_IsBhopEnabled");
	MarkNativeAsOptional("Apex_IsTracEnabled");
	MarkNativeAsOptional("Apex_GetTracBlockedTarget");
}
#endif