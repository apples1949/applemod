#if defined __cvar_settings_included
	#endinput
#endif
#define __cvar_settings_included

#define CVS_MODULE_NAME			"CvarSettings"

#define CVARS_DEBUG				0
#define CVS_CVAR_MAXLEN			64
// 每个被跟踪的 cvar 要在 CVSEntry 里存两份值(oldval/newval), 用定长数组.
// 原来取 1024, 而 CVSEntry 因此约 2KB/条, 521 条约 1.05MB —— 是服务器句柄内存里
// 除了 PLUGINSYS 之外最大的一块(占 confoglcompmod 全部 CellArray 的绝大部分).
// 实测全库 4746 行 confogl_addcvar(631 个唯一 cvar)里最长的值只有 72 字符
// (am12v12_wdrop_weapons 的武器白名单), p99=11, 只有 1 条超过 64 —— 128 给出约 1.8 倍余量.
// 128 时 CVSEntry 约 261 字节, 同样 521 条约 136KB, 直接省下约 0.9MB.
// 注意: 超过该长度的新值仍会被 AddCvar() 拒绝(见下方 strlens 检查)而不是静默截断;
// 旧值(oldval)超长时不保存(避免回写被截断的配置), 但**照常跟踪并应用配置值** —— 见 PushTrackedCvar.
// 2026-11-05 (128 → 256): 上面那次统计只看了 confogl_addcvar 这一侧的值, 漏掉了
// "跟踪开始时的当前值"也可以很长 —— 插件自己的默认值就是:
//   l4d2_extendedsight_modes_off 默认 152 字符(versus,teamversus,...,l4d1vs 模式黑名单),
//   而 cfg/cfgogl/applemod12v12/applemod12v12.cfg 给它的是 "none".
//   于是每张图执行 confogl_addcvar 时 PushTrackedCvar 读到 152 >= 128 就拒绝跟踪, 结果:
//     · 日志每次刷一条 error;
//     · 更要紧的是这条 confogl_addcvar 被整条跳过(连 cvar.SetString("none") 都不执行),
//       配置里写的 "none" 从未生效, 插件一直用那 152 字符的默认黑名单(versus 下被禁用).
//   取 256 覆盖现网所有单值(被跟踪 cvar 里最长的就是这条 152 字符, 次高 72);
//   CVSEntry 约 520 字节, 538 条约 273KB(比 128 时多约 134KB, 仍比最初的 1.05MB 小得多).
#define CVS_VALUE_MAXLEN			256

enum struct CVSEntry
{
	ConVar CVSE_cvar;
	char CVSE_oldval[CVS_VALUE_MAXLEN];
	char CVSE_newval[CVS_VALUE_MAXLEN];
	// 该 cvar 是否已经提示过"重复登记", 用来保证每个 cvar 只报一次(见 AddCvar)
	bool CVSE_dupWarned;
	// 是否保存了完整可回滚的旧值: 登记时当前值就超长的项为 false(ClearAllSettings 不回写它)
	bool CVSE_restorable;
}

enum struct CVSPending
{
	char CVSP_name[CVS_CVAR_MAXLEN];
	char CVSP_newval[CVS_VALUE_MAXLEN];
}

static bool
	bTrackingStarted = false,
	bCommitRequested = false;

static ArrayList
	CvarSettingsArray = null,
	PendingCvarsArray = null;

void CVS_OnModuleStart()
{
	CVSEntry cvsetting;
	CVSPending cvspending;

	CvarSettingsArray = new ArrayList(sizeof(cvsetting));
	PendingCvarsArray = new ArrayList(sizeof(cvspending));

	RegConsoleCmd("confogl_cvarsettings", CVS_CvarSettings_Cmd, "List all ConVars being enforced by Confogl");
	RegConsoleCmd("confogl_cvardiff", CVS_CvarDiff_Cmd, "List any ConVars that have been changed from their initialized values");

	RegServerCmd("confogl_addcvar", CVS_AddCvar_Cmd, "Add a ConVar to be set by Confogl");
	RegServerCmd("confogl_setcvars", CVS_SetCvars_Cmd, "Starts enforcing ConVars that have been added.");
	RegServerCmd("confogl_resetcvars", CVS_ResetCvars_Cmd, "Resets enforced ConVars.  Cannot be used during a match!");
}

void CVS_OnModuleEnd()
{
	ClearAllSettings();
}

void CVS_OnConfigsExecuted()
{
	ResolvePendingCvars();

	if (CVS_IsTrackingStarted() && IsPluginEnabled()) {
		SetEnforcedCvars();
	}
}

static Action CVS_SetCvars_Cmd(int args)
{
	if (!IsPluginEnabled()) {
		LogError("[%s] confogl_setcvars rejected: match mode is not active. Settings were NOT applied; run sm_confoglstatus.", CVS_MODULE_NAME);
		return Plugin_Handled;
	}

	if (bTrackingStarted) {
		PrintToServer("Tracking has already been started");
		return Plugin_Handled;
	}

#if CVARS_DEBUG
	LogMessage("[%s] No longer accepting new ConVars", CVS_MODULE_NAME);
#endif

	ResolvePendingCvars();
	bCommitRequested = true;
	if (CvarSettingsArray.Length == 0 && PendingCvarsArray.Length == 0) {
		// The engine's overflow recovery can deliver this command before the
		// registrations. Keep the request, but never report an empty commit.
		// 提示而非错误：bCommitRequested 已置位，之后每一次 AddCvar/PushTrackedCvar
		// 都会自己把值写下去并打开跟踪（bTrackingStarted = true），
		// CVS_OnConfigsExecuted 也会重放 SetEnforcedCvars()，所以这条不需要进 error log。
		LogMessage("[%s] confogl_setcvars received before any settings. Commit remains pending; late registrations will be applied. Run sm_confoglstatus.", CVS_MODULE_NAME);
		return Plugin_Handled;
	}
	SetEnforcedCvars();
	bTrackingStarted = true;
	PrintToServer("[Confogl] CVar settings committed: tracked=%d | pending=%d", CvarSettingsArray.Length, PendingCvarsArray.Length);
	if (PendingCvarsArray.Length > 0) {
		LogError("[%s] %d tracked CVar(s) are still missing after commit. Run sm_confoglstatus to see pending names.", CVS_MODULE_NAME, PendingCvarsArray.Length);
	}

	return Plugin_Handled;
}

bool CVS_IsTrackingStarted()
{
	return bTrackingStarted && (CvarSettingsArray.Length > 0 || PendingCvarsArray.Length > 0);
}

void CVS_ReplyStatus(int client)
{
	ReplyToCommand(client, "[Confogl] tracking=%d | tracked=%d | pending=%d | commit_requested=%d", CVS_IsTrackingStarted(), CvarSettingsArray.Length, PendingCvarsArray.Length, bCommitRequested);
	CVSPending pendingEntry;
	for (int i = 0; i < PendingCvarsArray.Length && i < 8; i++) {
		PendingCvarsArray.GetArray(i, pendingEntry, sizeof(pendingEntry));
		ReplyToCommand(client, "[Confogl] pending: %s=%s", pendingEntry.CVSP_name, pendingEntry.CVSP_newval);
	}
}

static Action CVS_AddCvar_Cmd(int args)
{
	if (args != 2) {
		PrintToServer("Usage: confogl_addcvar <cvar> <newValue>");

		if (IsDebugEnabled()) {
			char cmdbuf[MAX_NAME_LENGTH];
			GetCmdArgString(cmdbuf, sizeof(cmdbuf));
			Debug_LogError(CVS_MODULE_NAME, "Invalid Cvar Add: %s", cmdbuf);
		}

		return Plugin_Handled;
	}

	char cvar[CVS_CVAR_MAXLEN + 1], newval[CVS_VALUE_MAXLEN + 1];
	// A full output buffer may mean GetCmdArg truncated the argument. Reject
	// that boundary instead of registering a shortened CVar name or value.
	if (GetCmdArg(1, cvar, sizeof(cvar)) >= sizeof(cvar) - 1
		|| GetCmdArg(2, newval, sizeof(newval)) >= sizeof(newval) - 1) {
		LogError("[%s] confogl_addcvar argument exceeds the supported name/value buffer", CVS_MODULE_NAME);
		return Plugin_Handled;
	}

	AddCvar(cvar, newval);

	return Plugin_Handled;
}

static Action CVS_ResetCvars_Cmd(int args)
{
	if (IsPluginEnabled()) {
		PrintToServer("Can't reset tracking in the middle of a match");
		return Plugin_Handled;
	}

	ClearAllSettings();
	PrintToServer("Server CVar Tracking Information Reset!");

	return Plugin_Handled;
}

static Action CVS_CvarSettings_Cmd(int client, int args)
{
	if (!IsPluginEnabled()) {
		return Plugin_Handled;
	}

	if (!bTrackingStarted) {
		ReplyToCommand(client, "[Confogl] CVar tracking has not been started!! THIS SHOULD NOT OCCUR DURING A MATCH!");
		return Plugin_Handled;
	}

	char buffer[CVS_VALUE_MAXLEN], name[CVS_CVAR_MAXLEN];
	int cvscount = CvarSettingsArray.Length;

	ReplyToCommand(client, "[Confogl] Enforced Server CVars (Total %d)", cvscount);

	GetCmdArg(1, buffer, sizeof(buffer));
	int offset = StringToInt(buffer);

	if (offset < 0 || offset > cvscount) {
		return Plugin_Handled;
	}

	int temp = cvscount;
	if ((offset + 20) < cvscount) {
		temp = offset + 20;
	}

	CVSEntry cvsetting;

	for (int i = offset; i < temp && i < cvscount; i++) {
		CvarSettingsArray.GetArray(i, cvsetting, sizeof(cvsetting));

		(cvsetting.CVSE_cvar).GetString(buffer, sizeof(buffer));
		(cvsetting.CVSE_cvar).GetName(name, sizeof(name));

		ReplyToCommand(client, "[Confogl] Server CVar: %s, Desired Value: %s, Current Value: %s", name, cvsetting.CVSE_newval, buffer);
	}

	if ((offset + 20) < cvscount) {
		ReplyToCommand(client, "[Confogl] To see more CVars, use confogl_cvarsettings %d", offset + 20);
	}

	return Plugin_Handled;
}

static Action CVS_CvarDiff_Cmd(int client, int args)
{
	if (!IsPluginEnabled()) {
		return Plugin_Handled;
	}

	if (!bTrackingStarted) {
		ReplyToCommand(client, "[Confogl] CVar tracking has not been started!! THIS SHOULD NOT OCCUR DURING A MATCH!");
		return Plugin_Handled;
	}

	char buffer[CVS_VALUE_MAXLEN], name[CVS_CVAR_MAXLEN];
	int cvscount = CvarSettingsArray.Length;

	GetCmdArg(1, buffer, sizeof(buffer));
	int offset = StringToInt(buffer);

	if (offset > cvscount) {
		return Plugin_Handled;
	}

	int foundCvars = 0;

	CVSEntry cvsetting;

	while (offset < cvscount && foundCvars < 20) {
		CvarSettingsArray.GetArray(offset, cvsetting, sizeof(cvsetting));

		(cvsetting.CVSE_cvar).GetString(buffer, sizeof(buffer));
		(cvsetting.CVSE_cvar).GetName(name, sizeof(name));

		if (strcmp(cvsetting.CVSE_newval, buffer) != 0) {
			ReplyToCommand(client, "[Confogl] Server CVar: %s, Desired Value: %s, Current Value: %s", name, cvsetting.CVSE_newval, buffer);
			foundCvars++;
		}

		offset++;
	}

	if (offset < cvscount) {
		ReplyToCommand(client, "[Confogl] To see more CVars, use confogl_cvarsettings %d", offset);
	}

	return Plugin_Handled;
}

static void ClearAllSettings()
{
	bTrackingStarted = false;
	bCommitRequested = false;
	int iSize = CvarSettingsArray.Length;

	CVSEntry cvsetting;

	for (int i = 0; i < iSize; i++) {
		CvarSettingsArray.GetArray(i, cvsetting, sizeof(cvsetting));

		(cvsetting.CVSE_cvar).RemoveChangeHook(CVS_ConVarChange);
		// 旧值超长的项(CVSE_restorable=false)没有完整旧值可回写, 跳过而不是写半截值
		if (cvsetting.CVSE_restorable) {
			(cvsetting.CVSE_cvar).SetString(cvsetting.CVSE_oldval);
		}
	}

	CvarSettingsArray.Clear();
	PendingCvarsArray.Clear();
}

static void SetEnforcedCvars()
{
	int iSize = CvarSettingsArray.Length;

	CVSEntry cvsetting;

	for (int i = 0; i < iSize; i++) {
		CvarSettingsArray.GetArray(i, cvsetting, sizeof(cvsetting));

		#if CVARS_DEBUG
			char debug_buffer[CVS_CVAR_MAXLEN];
			(cvsetting.CVSE_cvar).GetName(debug_buffer, sizeof(debug_buffer));
			LogMessage("[%s] cvar = %s, newval = %s", CVS_MODULE_NAME, debug_buffer, cvsetting.CVSE_newval);
		#endif

		(cvsetting.CVSE_cvar).SetString(cvsetting.CVSE_newval);
	}
}

static void AddCvar(const char[] cvar, const char[] newval)
{
	if (strlen(cvar) >= CVS_CVAR_MAXLEN) {
		Debug_LogError(CVS_MODULE_NAME, "CVar Specified (%s) is longer than max cvar/value length (%d)", cvar, CVS_CVAR_MAXLEN);
		return;
	}

	if (strlen(newval) >= CVS_VALUE_MAXLEN) {
		Debug_LogError(CVS_MODULE_NAME, "New Value Specified (%s) is longer than max value length (%d)", newval, CVS_VALUE_MAXLEN);
		return;
	}

	char cvarBuffer[CVS_CVAR_MAXLEN];
	int iSize = CvarSettingsArray.Length;

	CVSEntry existingEntry;

	for (int i = 0; i < iSize; i++) {
		CvarSettingsArray.GetArray(i, existingEntry, sizeof(existingEntry));

		(existingEntry.CVSE_cvar).GetName(cvarBuffer, CVS_CVAR_MAXLEN);

		if (strcmp(cvar, cvarBuffer, false) == 0) {
			/* 同一 cvar 被重复登记是配置链的正常现象，不是每次都该报错的异常：
			   confogl 每换一张图都会重新执行整条 confogl_addcvar 链（confogl.cfg ->
			   shared_cvars.cfg -> applemod12v12.cfg -> shared_settings.cfg ->
			   startup/shared_settings_02..08.cfg），而本跟踪表只在 CVS_OnModuleEnd()
			   （插件卸载）和 confogl_resetcvars 时才清空，所以从第二张图起每个 cvar
			   都会走到这里一次。旧代码在这里无条件 Debug_LogError()，等于每张图刷
			   ~1254 行，一天（38 次配置执行）就把 errors_*.log 刷到 2MB。

			   现在：
			   · 每个 cvar 只提示一次（CVSE_dupWarned 标记，随表清空一起复位）；
			   · 且只有"重复登记的值与首次登记的值不同"时才提示 —— 那才是真正会
			     影响回落值(oldval/首次期望值)的情况；同值重复（跨图重跑）完全静默。 */
			if (!existingEntry.CVSE_dupWarned) {
				existingEntry.CVSE_dupWarned = true;
				CvarSettingsArray.SetArray(i, existingEntry, sizeof(existingEntry));

				if (strcmp(existingEntry.CVSE_newval, newval, false) != 0) {
					LogMessage("[%s] ConVar %s is registered twice with different values; keeping the first one (first: %s, ignored: %s).",
						CVS_MODULE_NAME, cvar, existingEntry.CVSE_newval, newval);
				}
			}
			return;
		}
	}

	int iPendingSize = PendingCvarsArray.Length;
	CVSPending pendingEntry;

	for (int i = 0; i < iPendingSize; i++) {
		PendingCvarsArray.GetArray(i, pendingEntry, sizeof(pendingEntry));

		if (strcmp(cvar, pendingEntry.CVSP_name, false) == 0) {
			// 未解析的挂起项每次配置执行都会被重新登记一次，同属正常重跑，只在 debug 下提示
			if (IsDebugEnabled()) {
				Debug_LogError(CVS_MODULE_NAME, "Attempt to track ConVar %s, which is already pending late-bind.", cvar);
			}
			return;
		}
	}

	ConVar newCvar = FindConVar(cvar);

	if (newCvar == null) {
		// Owning plugin may not be loaded yet; retry from CVS_OnConfigsExecuted.
		strcopy(pendingEntry.CVSP_name, CVS_CVAR_MAXLEN, cvar);
		strcopy(pendingEntry.CVSP_newval, CVS_VALUE_MAXLEN, newval);
		PendingCvarsArray.PushArray(pendingEntry, sizeof(pendingEntry));
		if (bCommitRequested && IsPluginEnabled()) {
			bTrackingStarted = true;
		}

	#if CVARS_DEBUG
		LogMessage("[%s] Pending late-bind for cvar = %s, newval = %s", CVS_MODULE_NAME, cvar, newval);
	#endif
		return;
	}

	PushTrackedCvar(newCvar, newval);
}

static void PushTrackedCvar(ConVar cvar, const char[] newval)
{
	// 读当前值(旧值)只用于"回滚": ClearAllSettings() 会把 CVSE_oldval 写回服务器,
	// 所以绝不能存被截断的半截值. 但旧值读不全只该影响"能不能回滚", 不该影响
	// "配置值要不要应用" —— 旧代码在这里直接 return, 结果是日志报一条错 +
	// confogl_addcvar 整条静默失效(l4d2_extendedsight_modes_off 的 152 字符默认值
	// 撞上 128 上限时就是这样: 配置写的 "none" 从来没生效过).
	char sCurrentValue[512];
	cvar.GetString(sCurrentValue, sizeof(sCurrentValue));

	int iOldLen = strlen(sCurrentValue);
	bool bRestorable = (iOldLen < CVS_VALUE_MAXLEN);

	if (!bRestorable) {
		char sOverflowName[CVS_CVAR_MAXLEN];
		cvar.GetName(sOverflowName, sizeof(sOverflowName));
		LogMessage("[%s] ConVar %s 的当前值长 %d 字符, 超过 CVS_VALUE_MAXLEN(%d): 配置值照常应用, 但不保存可回滚的旧值",
			CVS_MODULE_NAME, sOverflowName, iOldLen, CVS_VALUE_MAXLEN);
	}

	char cvarBuffer[CVS_VALUE_MAXLEN];
	if (bRestorable) {
		cvar.GetString(cvarBuffer, CVS_VALUE_MAXLEN);
	} else {
		cvarBuffer[0] = '\0';
	}

	CVSEntry newEntry;
	newEntry.CVSE_cvar = cvar;
	strcopy(newEntry.CVSE_oldval, CVS_VALUE_MAXLEN, cvarBuffer);
	strcopy(newEntry.CVSE_newval, CVS_VALUE_MAXLEN, newval);
	newEntry.CVSE_dupWarned = false;
	newEntry.CVSE_restorable = bRestorable;

#if CVARS_DEBUG
	char cvarName[CVS_CVAR_MAXLEN];
	cvar.GetName(cvarName, sizeof(cvarName));
	LogMessage("[%s] cvar = %s, newval = %s, oldval = %s", CVS_MODULE_NAME, cvarName, newval, cvarBuffer);
#endif

	CvarSettingsArray.PushArray(newEntry, sizeof(newEntry));
	// A delayed registration must not be discarded after an early commit.
	// Apply only this new entry: reapplying every entry would overwrite later
	// administrator changes. Duplicate registrations still keep the first value.
	if (bCommitRequested && IsPluginEnabled()) {
		cvar.SetString(newval);
		bTrackingStarted = true;
	}
	// Attach our reporting hook after the initial write, so replaying hundreds
	// of delayed registrations does not broadcast hundreds of change notices.
	cvar.AddChangeHook(CVS_ConVarChange);
}

static void ResolvePendingCvars()
{
	int iSize = PendingCvarsArray.Length;
	if (iSize == 0) {
		return;
	}

	CVSPending pendingEntry;

	// Reverse iteration so Erase() doesn't shift entries we haven't visited.
	for (int i = iSize - 1; i >= 0; i--) {
		PendingCvarsArray.GetArray(i, pendingEntry, sizeof(pendingEntry));

		ConVar resolved = FindConVar(pendingEntry.CVSP_name);
		if (resolved == null) {
			continue;
		}

		PushTrackedCvar(resolved, pendingEntry.CVSP_newval);
		PendingCvarsArray.Erase(i);
	}
}

static void CVS_ConVarChange(ConVar hConVar, const char[] sOldValue, const char[] sNewValue)
{
	if (bTrackingStarted) {
		char sName[CVS_CVAR_MAXLEN];
		hConVar.GetName(sName, sizeof(sName));

		PrintToServer("[Confogl] Tracked Server CVar '%s' changed from '%s' to '%s' !!!", sName, sOldValue, sNewValue);
		//PrintToChatAll("[Confogl] Tracked Server CVar '%s' changed from '%s' to '%s' !!!", sName, sOldValue, sNewValue);
		CPrintToChatAll("{blue}[{default}Confogl{blue}]{default} Tracked Server CVar '{green}%s{default}' changed from '{blue}%s{default}' to '{blue}%s{default}' !!!", sName, sOldValue, sNewValue);
	}
}
