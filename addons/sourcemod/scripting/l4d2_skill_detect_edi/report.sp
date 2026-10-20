#if defined _skill_detect_edi_report_included
	#endinput
#endif
#define _skill_detect_edi_report_included

// EDI version: all report strings are hardcoded Chinese, inlined from
// translations/chi/l4d2_skill_detect.phrases.txt. No percent-t, no translation lookup.
// Every string below was kept byte-for-byte identical (colors, brackets,
// spaces, decimals) to what the translation version printed.
//   {green}★{default}          = "Tag+"      (★ x1)
//   {green}★★{default}         = "Tag++"     (★ x2)
//   {green}★★★{default}        = "Tag+++"    (★ x3)
//   {green}★★★★{default}       = "Tag++++"   (★ x4)
//   "Empty"/"PluralCount" were empty phrases -> replaced by "" (or dropped
//   entirely where the phrase text never referenced them).

/**
 * Hardcoded version of the "Melee"/"HeadShot"/"Grenade"/"Empty" phrase keys used
 * by the skeet report. Same precedence as the ternary chain of the translation
 * version: melee > sniper > GL > (nothing).
 *
 * @param bMelee        melee skeet
 * @param bSniper       sniper/magnum headshot skeet
 * @param bGL           direct grenade launcher hit
 * @param sBuffer       destination
 * @param iMaxLen       destination size
 * @return              nothing
 */
stock void GetSkeetTypeName(bool bMelee, bool bSniper, bool bGL, char[] sBuffer, int iMaxLen)
{
	if (bMelee)
		strcopy(sBuffer, iMaxLen, "近战");
	else if (bSniper)
		strcopy(sBuffer, iMaxLen, "爆头");
	else if (bGL)
		strcopy(sBuffer, iMaxLen, "投掷武器");
	else
		sBuffer[0] = '\0';
}

// boomer pop
stock void HandlePop(int attacker, int victim, int shoveCount, float timeAlive)
{
	// report?
	if (g_cvarReport.BoolValue && g_cvarRepPop.BoolValue)
	{
		if (IsValidClientInGame(attacker) && IsValidClientInGame(victim) && !IsFakeClient(victim))
			CPrintToChatAll("{green}★{default} {olive}%N{default} 悄无声息解决了 {olive}%N{default}.", attacker, victim);
		else if (IsValidClientInGame(attacker))
			CPrintToChatAll("{green}★{default} {olive}%N{default} 悄无声息解决了一只 boomer.", attacker);
	}

	Call_StartForward(g_hForwardBoomerPop);
	Call_PushCell(attacker);
	Call_PushCell(victim);
	Call_PushCell(shoveCount);
	Call_PushFloat(timeAlive);
	Call_Finish();
}

// charger level
stock void HandleLevel(int attacker, int victim)
{
	// report?
	if (g_cvarReport.BoolValue && g_cvarRepLevel.BoolValue)
	{
		if (IsValidClientInGame(attacker) && IsValidClientInGame(victim) && !IsFakeClient(victim))
			CPrintToChatAll("{green}★★★{default} {olive}%N{default} 使用 {blue}近战满血秒杀{default} {olive}%N{default}", attacker, victim);
		else if (IsValidClientInGame(attacker))
			CPrintToChatAll("{green}★★★{default} {olive}%N{default} 使用 {blue}近战满血秒杀{default}{olive} 一只 charger{default}", attacker);
	}

	// call forward
	Call_StartForward(g_hForwardLevel);
	Call_PushCell(attacker);
	Call_PushCell(victim);
	Call_Finish();
}
// charger level hurt
stock void HandleLevelHurt(int attacker, int victim, int damage)
{
	// report?
	if (g_cvarReport.BoolValue && g_cvarRepHurtLevel.BoolValue)
	{
		if (IsValidClientInGame(attacker) && IsValidClientInGame(victim) && !IsFakeClient(victim))
			CPrintToChatAll("{green}★{default} {olive}%N{default} 使用 {blue}近战砍死{default} 正在 {olive}冲锋的%N{default} ({blue}%d 伤害{default})", attacker, victim, damage);
		else if (IsValidClientInGame(attacker))
			CPrintToChatAll("{green}★{default} {olive}%N{default} 使用 {blue}近战砍死{default} 一只正在 {olive}冲锋的牛 {default}({blue}%d 伤害{default})", attacker, damage);
	}

	// call forward
	Call_StartForward(g_hForwardLevelHurt);
	Call_PushCell(attacker);
	Call_PushCell(victim);
	Call_PushCell(damage);
	Call_Finish();
}

// deadstops
stock void HandleDeadstop(int attacker, int victim)
{
	// report?
	if (g_cvarReport.BoolValue && g_cvarRepDeadStop.BoolValue)
	{
		if (IsValidClientInGame(attacker) && IsValidClientInGame(victim) && !IsFakeClient(victim))
			CPrintToChatAll("{green}★{default} {olive}%N{default} {blue}推停了{default} {olive}%N{default}", attacker, victim);
		else if (IsValidClientInGame(attacker))
			CPrintToChatAll("{green}★{default} {olive}%N{default} {blue}推停了{default} {olive}一只 hunter{default}", attacker);
	}

	Call_StartForward(g_hForwardHunterDeadstop);
	Call_PushCell(attacker);
	Call_PushCell(victim);
	Call_Finish();
}

stock void HandleShove(int attacker, int victim, int zombieClass)
{
	// report?
	if (g_cvarReport.BoolValue && g_cvarRepShove.BoolValue)
	{
		if (IsValidClientInGame(attacker) && IsValidClientInGame(victim) && !IsFakeClient(victim))
			CPrintToChatAll("{green}★{default} {olive}%N{default} {blue}推到了{default} {olive}%N{default}.", attacker, victim);
		else if (IsValidClientInGame(attacker))
			CPrintToChatAll("{green}★{default} {olive}%N{default} {blue}推到了{default} 一个 {olive}特感{default}.", attacker);
	}

	Call_StartForward(g_hForwardSIShove);
	Call_PushCell(attacker);
	Call_PushCell(victim);
	Call_PushCell(zombieClass);
	Call_Finish();
}

// real skeet
stock void HandleSkeet(int attacker, int victim, bool bMelee = false, bool bSniper = false, bool bGL = false)
{
	// report?
	if (g_cvarReport.BoolValue && g_cvarRepSkeet.BoolValue)
	{
		if (attacker == -2)
		{
			// team skeet sets to -2
			if (IsValidClientInGame(victim) && !IsFakeClient(victim))
				CPrintToChatAll("{green}★{default} {olive}%N{default} 被 {blue}团队空爆{default}.", victim);
			else
				CPrintToChatAll("{green}★{default} {olive}Hunter{default} 被 {blue}团队空爆{default}.");
		}
		else
		{
			// "Melee"/"HeadShot"/"Grenade"/"Empty" phrase -> hardcoded text ("" for Empty)
			char sType[16];
			GetSkeetTypeName(bMelee, bSniper, bGL, sType, sizeof(sType));

			if (IsValidClientInGame(attacker) && IsValidClientInGame(victim) && !IsFakeClient(victim))
				CPrintToChatAll("{green}★★{default} {olive}%N{default} {blue}%s空爆{default} 了 {olive}%N{default}.", attacker, sType, victim);
			else if (IsValidClientInGame(attacker))
				CPrintToChatAll("{green}★{default} {olive}%N{default} {blue}%s空爆{default} 了 {olive}一只hunter{default}.", attacker, sType);
		}
	}

	// call forward
	if (bSniper)
	{
		Call_StartForward(g_hForwardSkeetSniper);
		Call_PushCell(attacker);
		Call_PushCell(victim);
		Call_Finish();
	}
	else if (bGL)
	{
		Call_StartForward(g_hForwardSkeetGL);
		Call_PushCell(attacker);
		Call_PushCell(victim);
		Call_Finish();
	}
	else if (bMelee)
	{
		Call_StartForward(g_hForwardSkeetMelee);
		Call_PushCell(attacker);
		Call_PushCell(victim);
		Call_Finish();
	}
	else
	{
		Call_StartForward(g_hForwardSkeet);
		Call_PushCell(attacker);
		Call_PushCell(victim);
		Call_Finish();
	}
}

// hurt skeet / non-skeet
//  NOTE: bSniper not set yet, do this
stock void HandleNonSkeet(int attacker, int victim, int damage, bool bOverKill = false, bool bMelee = false, bool bSniper = false)
{
	// report?
	//  NOTE: the "Unchipped"/"Empty" phrase argument of the translation version was
	//  never referenced by the phrase text, so it produced no output and is dropped here.
	if (g_cvarReport.BoolValue && g_cvarRepHurtSkeet.BoolValue)
	{
		if (IsValidClientInGame(victim))
			CPrintToChatAll("{green}★{default} {olive}%N{default} 被 {green}残血空爆{default} ({blue}%d{default} 伤害).", victim, damage);
		else
			CPrintToChatAll("{green}★{default} {olive}Hunter{default} 被 {green}残血空爆{default} ({blue}%d{default} 伤害).", damage);
	}

	// call forward
	if (bSniper)
	{
		Call_StartForward(g_hForwardSkeetSniperHurt);
		Call_PushCell(attacker);
		Call_PushCell(victim);
		Call_PushCell(damage);
		Call_PushCell(bOverKill);
		Call_Finish();
	}
	else if (bMelee)
	{
		Call_StartForward(g_hForwardSkeetMeleeHurt);
		Call_PushCell(attacker);
		Call_PushCell(victim);
		Call_PushCell(damage);
		Call_PushCell(bOverKill);
		Call_Finish();
	}
	else
	{
		Call_StartForward(g_hForwardSkeetHurt);
		Call_PushCell(attacker);
		Call_PushCell(victim);
		Call_PushCell(damage);
		Call_PushCell(bOverKill);
		Call_Finish();
	}
}

// crown
void HandleCrown(int attacker, int damage)
{
	// report?
	if (g_cvarReport.BoolValue && g_cvarRepCrow.BoolValue)
	{
		if (IsValidClientInGame(attacker))
			CPrintToChatAll("{green}★★{default} {olive}%N{default} 秒了女巫 ({blue}%d{default} 伤害).", attacker, damage);
		else
			CPrintToChatAll("女巫 {blue}被秒了{default}.");
	}

	// call forward
	Call_StartForward(g_hForwardCrown);
	Call_PushCell(attacker);
	Call_PushCell(damage);
	Call_Finish();
}
// drawcrown
void HandleDrawCrown(int attacker, int damage, int chipdamage)
{
	// report?
	if (g_cvarReport.BoolValue && g_cvarRepDrawCrow.BoolValue)
	{
		if (IsValidClientInGame(attacker))
			CPrintToChatAll("{green}★★{default} {olive}%N{default} 引秒了一个女巫 ({blue}%d{default} 伤害, {olive}%d{default} 引秒伤害).", attacker, damage, chipdamage);
		else
			CPrintToChatAll("Witch 被引秒 ({blue}%d{default} 伤害, {olive}%d{default} 引秒伤害).", damage, chipdamage);
	}

	// call forward
	Call_StartForward(g_hForwardDrawCrown);
	Call_PushCell(attacker);
	Call_PushCell(damage);
	Call_PushCell(chipdamage);
	Call_Finish();
}

// smoker clears
void HandleTongueCut(int attacker, int victim)
{
	// report?
	if (g_cvarReport.BoolValue && g_cvarRepTongueCut.BoolValue)
	{
		if (IsValidClientInGame(attacker) && IsValidClientInGame(victim) && !IsFakeClient(victim))
			CPrintToChatAll("{green}★★★{default} {olive}%N{default} {blue}砍断{default} {olive}%N{default}的舌头", attacker, victim);
		else if (IsValidClientInGame(attacker))
			CPrintToChatAll("{green}★★★{default} {olive}%N{default} {blue}砍断{default} smoker 的舌头", attacker);
	}

	// call forward
	Call_StartForward(g_hForwardTongueCut);
	Call_PushCell(attacker);
	Call_PushCell(victim);
	Call_Finish();
}

void HandleSmokerSelfClear(int attacker, int victim, bool withShove = false)
{
	// report?
	if (g_cvarReport.BoolValue && g_cvarRepSelfClear.BoolValue && (!withShove || g_cvarRepSelfClearShove.BoolValue))
	{
		// "Shoving" was " 用推" (leading space, part of the phrase); "Empty" was "".
		// both are kept so the {blue}...{default} pair around it stays intact
		char sShoveText[16];
		if (withShove)
			strcopy(sShoveText, sizeof(sShoveText), " 用推");
		else
			sShoveText[0] = '\0';

		if (IsValidClientInGame(attacker) && IsValidClientInGame(victim) && !IsFakeClient(victim))
			CPrintToChatAll("{green}★★{default} {olive}%N{default} 从 {olive}%N{default}的舌头下 {blue}%s{default} {blue}自救{default} ", attacker, victim, sShoveText);
		else if (IsValidClientInGame(attacker))
			CPrintToChatAll("{green}★★{default} {olive}%N{default} 从 {olive}smoker{default}的舌头下 {blue}%s{default} {blue}自救{default} ", attacker, sShoveText);
	}

	// call forward
	Call_StartForward(g_hForwardSmokerSelfClear);
	Call_PushCell(attacker);
	Call_PushCell(victim);
	Call_PushCell(withShove);
	Call_Finish();
}

// rocks
void HandleRockEaten(int attacker, int victim)
{
	Call_StartForward(g_hForwardRockEaten);
	Call_PushCell(attacker);
	Call_PushCell(victim);
	Call_Finish();
}
void HandleRockSkeeted(int attacker, int victim)
{
	// report?
	if (g_cvarReport.BoolValue && g_cvarRepRockSkeet.BoolValue)
	{
		if (!IsValidClientInGame(attacker))
			return;

		if (g_cvarRepRockName.BoolValue && IsValidClientInGame(victim) && !IsFakeClient(victim))
			CPrintToChatAll("{green}★{default} {olive}%N{default} {blue}空爆{default} 了 {olive}%N{default} 的 石头.", attacker, victim);
		else
			CPrintToChatAll("{green}★{default} {olive}%N{default} {blue}空爆{default} 了 tank 石头", attacker);
	}

	Call_StartForward(g_hForwardRockSkeeted);
	Call_PushCell(attacker);
	Call_PushCell(victim);
	Call_Finish();
}

// highpounces
stock void HandleHunterDP(int attacker, int victim, int actualDamage, float calculatedDamage, float height, bool playerIncapped = false)
{
	// report?
	if (g_cvarReport.BoolValue && g_cvarRepHunterDP.BoolValue && height >= g_cvarHunterDPThresh.FloatValue && !playerIncapped)
	{
		if (IsValidClientInGame(attacker) && IsValidClientInGame(victim) && !IsFakeClient(attacker))
			CPrintToChatAll("{green}★★{default} {olive}%N{default} {red}高扑{default} {olive}%N{default} ({red}%d{default} 伤害, 高度: {red}%d{default})", attacker, victim, RoundFloat(calculatedDamage), RoundFloat(height));
		else if (IsValidClientInGame(victim))
			CPrintToChatAll("{green}★★{default} {olive}Hunter{default} {red}高扑{default} {olive}%N{default} ({red}%d{default} 伤害, 高度: {red}%d{default})", victim, RoundFloat(calculatedDamage), RoundFloat(height));
	}

	Call_StartForward(g_hForwardHunterDP);
	Call_PushCell(attacker);
	Call_PushCell(victim);
	Call_PushCell(actualDamage);
	Call_PushFloat(calculatedDamage);
	Call_PushFloat(height);
	Call_PushCell((height >= g_cvarHunterDPThresh.FloatValue) ? 1 : 0);
	Call_PushCell((playerIncapped) ? 1 : 0);
	Call_Finish();
}
stock void HandleJockeyDP(int attacker, int victim, float height)
{
	// report?
	if (g_cvarReport.BoolValue && g_cvarRepJockeyDP.BoolValue && height >= g_cvarJockeyDPThresh.FloatValue)
	{
		if (IsValidClientInGame(attacker) && IsValidClientInGame(victim) && !IsFakeClient(attacker))
			CPrintToChatAll("{green}★★★{default} {olive}%N{default} {red}高处掉下骑了{default} {olive}%N{default} ({red}高度{default}: {red}%d{default})", attacker, victim, RoundFloat(height));
		else if (IsValidClientInGame(victim))
			CPrintToChatAll("{green}★★★{default} {olive}Jockey{default} {red}高处掉下骑了{default} {olive}%N{default} ({red}高度{default}: {red}%d{default})", victim, RoundFloat(height));
	}

	Call_StartForward(g_hForwardJockeyDP);
	Call_PushCell(victim);
	Call_PushCell(attacker);
	Call_PushFloat(height);
	Call_PushCell((height >= g_cvarJockeyDPThresh.FloatValue) ? 1 : 0);
	Call_Finish();
}

// deathcharges
stock void HandleDeathCharge(int attacker, int victim, float height, float distance, bool bCarried = true)
{
	// report?
	if (g_cvarReport.BoolValue && g_cvarRepDeathCharge.BoolValue && height >= g_cvarDeathChargeHeight.FloatValue)
	{
		// "Bowling" = "保龄球式撞击", "Empty" = "" -> carried victims print "()", bowling prints "(保龄球式撞击)"
		char sImpactText[24];
		if (bCarried)
			sImpactText[0] = '\0';
		else
			strcopy(sImpactText, sizeof(sImpactText), "保龄球式撞击");

		if (IsValidClientInGame(attacker) && IsValidClientInGame(victim) && !IsFakeClient(attacker))
			CPrintToChatAll("{green}★★★★{default} {olive}%N{default} {red}冲锋{default} 造成 {olive}%N 死亡{default} (%s)({red}高度{default}: {red}%d{default})", attacker, victim, sImpactText, RoundFloat(height));
		else if (IsValidClientInGame(victim))
			CPrintToChatAll("{green}★★★★{default} {olive}Charger{default} {red}冲锋{default} 造成 {olive}%N{default} 死亡(%s)({red}高度{default}: {red}%d{default})", victim, sImpactText, RoundFloat(height));
	}

	Call_StartForward(g_hForwardDeathCharge);
	Call_PushCell(attacker);
	Call_PushCell(victim);
	Call_PushFloat(height);
	Call_PushFloat(distance);
	Call_PushCell((bCarried) ? 1 : 0);
	Call_Finish();
}

// SI clears    (cleartimeA = pummel/pounce/ride/choke, cleartimeB = tongue drag, charger carry)
stock void HandleClear(int attacker, int victim, int pinVictim, int zombieClass, float clearTimeA, float clearTimeB, bool bWithShove = false)
{
	// sanity check:
	if (clearTimeA < 0 && clearTimeA != -1.0)
		clearTimeA = 0.0;

	if (clearTimeB < 0 && clearTimeB != -1.0)
		clearTimeB = 0.0;

	PrintDebug("Clear: %i freed %i from %i: time: %.2f / %.2f -- class: %s (with shove? %i)", attacker, pinVictim, victim, clearTimeA, clearTimeB, g_csSIClassName[zombieClass], bWithShove);

	if (g_cvarRepInstanClear.IntValue && attacker != pinVictim)
	{
		float fMinTime	 = g_cvarInstaTime.FloatValue;
		float fClearTime = clearTimeA;
		if (zombieClass == ZC_CHARGER || zombieClass == ZC_SMOKER) { fClearTime = clearTimeB; }

		if (fClearTime != -1.0 && fClearTime <= fMinTime)
		{
			if (IsValidClientInGame(attacker) && IsValidClientInGame(victim) && !IsFakeClient(victim))
			{
				if (IsValidClientInGame(pinVictim))
					CPrintToChatAll("{green}★{default} {olive}%N{default} 只用了 {blue}%.2f秒{default} 杀死了 {olive}%N{default} 的 %s， 解控了 {olive}%N{default} ", attacker, fClearTime, victim, g_csSIClassName[zombieClass], pinVictim);
				else
					CPrintToChatAll("{green}★{default} {olive}%N{default} 只用了 {blue}%.2f秒{default} 杀死了 {olive}%N{default}的 %s", attacker, fClearTime, victim, g_csSIClassName[zombieClass]);
			}
			else if (IsValidClientInGame(attacker))
			{
				if (IsValidClientInGame(pinVictim))
					CPrintToChatAll("{green}★{default} {olive}%N{default} 只用了 {blue}%.2f秒{default} 杀死了 {olive}一只%s{default}， 解控了 {olive}%N{default} ", attacker, fClearTime, g_csSIClassName[zombieClass], pinVictim);
				else
					CPrintToChatAll("{green}★{default} {olive}%N{default} 只用了 {blue}%.2f秒{default} 杀死了 {olive}一只%s{default}", attacker, fClearTime, g_csSIClassName[zombieClass]);
			}
		}
	}

	Call_StartForward(g_hForwardClear);
	Call_PushCell(attacker);
	Call_PushCell(victim);
	Call_PushCell(pinVictim);
	Call_PushCell(zombieClass);
	Call_PushFloat(clearTimeA);
	Call_PushFloat(clearTimeB);
	Call_PushCell((bWithShove) ? 1 : 0);
	Call_Finish();
}

// booms
stock void HandleVomitLanded(int attacker, int boomCount)
{
	Call_StartForward(g_hForwardVomitLanded);
	Call_PushCell(attacker);
	Call_PushCell(boomCount);
	Call_Finish();
}

// bhaps
stock void HandleBHopStreak(int survivor, int streak, float maxVelocity)
{
	// the "PluralCount"/"Empty" phrase argument of the translation version was never
	// referenced by the phrase text, so it produced no output and is dropped here.
	if (g_cvarRepBhopStreak.BoolValue && IsValidClientInGame(survivor) && !IsFakeClient(survivor) && streak >= g_cvarBHopMinStreak.IntValue)
		CPrintToChat(survivor, "{green}★{default} {olive}你{default} 成功完成一次 {blue}%d 连跳 ({blue}最高速度{default}: {olive}%.1f{default})", streak, maxVelocity);

	Call_StartForward(g_hForwardBHopStreak);
	Call_PushCell(survivor);
	Call_PushCell(streak);
	Call_PushFloat(maxVelocity);
	Call_Finish();
}

// car alarms
stock void HandleCarAlarmTriggered(int survivor, int infected, int reason)
{
	if (g_cvarRepCarAlarm.BoolValue && IsValidClientInGame(survivor) && !IsFakeClient(survivor))
	{
		if (reason == CALARM_HIT)
			CPrintToChatAll("{green}★{default} {olive}%N{default} 触发了一辆警报车.", survivor);
		else if (reason == CALARM_TOUCHED)
		{
			// if a survivor touches an alarmed car, it might be due to a special infected...
			if (IsValidInfected(infected))
			{
				if (!IsFakeClient(infected))
					CPrintToChatAll("{green}★{default} {olive}%N{default} 让 {olive}%N{default} 触发警报.", infected, survivor);
				else
				{
					switch (GetEntProp(infected, Prop_Send, "m_zombieClass"))
					{
						case ZC_SMOKER:
							CPrintToChatAll("{green}★{default} {olive}Hunter{default} 让 {olive}%N{default} 触发警报.", survivor);
						case ZC_JOCKEY:
							CPrintToChatAll("{green}★{default} {olive}Jockey{default} 让 {olive}%N{default} 触发警报.", survivor);
						case ZC_CHARGER:
							// baseline passed `survivor` where a phrase name belonged (the
							// "CalarmTouchedCharger" phrase was never printed); restoring the
							// string that phrase file defined for this branch
							CPrintToChatAll("{green}★{default} {olive}Charger{default} 让 {olive}%N{default} 触发警报.", survivor);
						default:
							CPrintToChatAll("{green}★{default} {olive}Bot infected{default} 让 {olive}%N{default} 触发警报.", survivor);
					}
				}
			}
			else
				CPrintToChatAll("{green}★{default} {olive}%N{default} 触发了一辆警报车.", survivor);
		}
		else if (reason == CALARM_EXPLOSION)
			CPrintToChatAll("{green}★{default} {olive}%N{default} 用爆炸触发一辆警报车.", survivor);
		else if (reason == CALARM_BOOMER)
		{
			if (IsValidInfected(infected) && !IsFakeClient(infected))
				CPrintToChatAll("{green}★{default} {olive}%N{default} 杀了一只 boomer {olive}%N{default} 触发了一辆警报车.", survivor, infected);
			else
				CPrintToChatAll("{green}★{default} {olive}%N{default} 杀了一只 {olive}boomer{default}触发了一辆警报车.", survivor);
		}
		else
			CPrintToChatAll("{green}★{default} {olive}%N{default} 触发了一辆警报车.", survivor);
	}

	Call_StartForward(g_hForwardAlarmTriggered);
	Call_PushCell(survivor);
	Call_PushCell(infected);
	Call_PushCell(reason);
	Call_Finish();
}
