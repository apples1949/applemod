/*
	Little Anti-Cheat
	Copyright (C) 2018-2023 J_Tanzanite

	This program is free software: you can redistribute it and/or modify
	it under the terms of the GNU General Public License as published by
	the Free Software Foundation, either version 3 of the License, or
	(at your option) any later version.

	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

void lilac_config_setup()
{
    ConVar tcvar;

    hcvar[CVAR_ENABLE] = new Convar("lilac_enable", "1",
        "启用 Little Anti-Cheat（Lilac 反作弊）。",
        FCVAR_PROTECTED, true, 0.0, true, 1.0);
    hcvar[CVAR_WELCOME] = new Convar("lilac_welcome", "0",
        "玩家连接时提示本服务器开启了反作弊保护。",
        FCVAR_PROTECTED, true, 0.0, true, 1.0);
    hcvar[CVAR_AR] = new Convar("lilac_autorecorder", "0",
        "启用 AutoRecorder 联动（若已安装 AutoRecorder，则把 MatchID 写入日志）。",
        FCVAR_PROTECTED, true, 0.0, true, 1.0);
    hcvar[CVAR_SB] = new Convar("lilac_sourcebans", "0",
        "通过 SourceBans++ 封禁玩家（若未安装，则回退为 basebans）。",
        FCVAR_PROTECTED, true, 0.0, true, 1.0);
    hcvar[CVAR_MA] = new Convar("lilac_materialadmin", "0",
        "通过 Material-Admin 封禁玩家（SourceBans++ 的分支；若未安装，则回退为 SourceBans++ 或 basebans）。",
        FCVAR_PROTECTED, true, 0.0, true, 1.0);
    hcvar[CVAR_SOURCEIRC] = new Convar("lilac_sourceirc", "0",
        "若 SourceIRC 可用，则把日志同步到带 \'lilac\' 标记的 SourceIRC 频道。",
        FCVAR_PROTECTED, true, 0.0, true, 1.0);
    hcvar[CVAR_DISCORD] = new Convar("lilac_discord", "0",
        "把举报发送到 Discord Webhook（需要 REST in Pawn 扩展，并填写 lilac_discord_webhook）。\n0 = 关闭。\n1 = 封禁与踢出。\n2 = 封禁、踢出以及疑似检测。",
        FCVAR_PROTECTED, true, 0.0, true, 2.0);
    hcvar[CVAR_DISCORD_WEBHOOK] = new Convar("lilac_discord_webhook", "",
        "Discord Webhook 地址。请务必保密，任何拿到它的人都能在你的频道里发言。",
        FCVAR_PROTECTED);
    hcvar[CVAR_DISCORD_ROLE] = new Convar("lilac_discord_role", "",
        "封禁玩家时要 @ 的 Discord 身份组 ID（留空 = 不 @）。",
        FCVAR_PROTECTED);
    hcvar[CVAR_DISCORD_ADDRESS] = new Convar("lilac_discord_address", "",
        "Discord 举报里显示的服务器地址（ip:port）（留空 = 从 hostip 与 hostport 自动推断）。",
        FCVAR_PROTECTED);
    hcvar[CVAR_DISCORD_LOGO] = new Convar("lilac_discord_logo", "",
        "Discord 举报里用作图标与缩略图的图片地址（留空 = 不显示）。",
        FCVAR_PROTECTED);
    hcvar[CVAR_LOG] = new Convar("lilac_log", "1",
        "启用作弊日志记录。",
        FCVAR_PROTECTED, true, 0.0, true, 1.0);
    hcvar[CVAR_LOG_EXTRA] = new Convar("lilac_log_extra", "1",
        "0 = 关闭。\n1 = 封禁玩家时记录额外信息。\n2 = 记录所有事件的额外信息。",
        FCVAR_PROTECTED, true, 0.0, true, 2.0);
    hcvar[CVAR_LOG_MISC] = new Convar("lilac_log_misc", "0",
        "记录玩家因杂项功能被踢出的日志，例如 interp 漏洞利用、ConVar 响应失败等。",
        FCVAR_PROTECTED, true, 0.0, true, 1.0);
    hcvar[CVAR_LOG_DATE] = new Convar("lilac_log_date", "{year}/{month}/{day} {hour}:{minute}:{second}",
        "写日志时使用的日期与时间格式。输入 \"lilac_date_list\" 可查看可用格式。",
        FCVAR_PROTECTED, false, 0.0, false, 0.0);
    hcvar[CVAR_BAN] = new Convar("lilac_ban", "1",
        "启用对作弊者的封禁；若想先试试 Lilac 效果再放心封禁，请设为 0。",
        FCVAR_PROTECTED, true, 0.0, true, 1.0);
    hcvar[CVAR_BAN_LENGTH] = new Convar("lilac_ban_length", "0",
        "封禁时长，单位分钟（0 = 永久）。",
        FCVAR_PROTECTED, true, 0.0, false, 0.0);
    hcvar[CVAR_BAN_LANGUAGE] = new Convar("lilac_ban_language", "1",
        "封禁理由使用的语言。\n0 = 使用服务器语言。\n1 = 使用作弊者自己的语言。",
        FCVAR_PROTECTED, true, 0.0, true, 1.0);
    hcvar[CVAR_CHEAT_WARN] = new Convar("lilac_cheat_warning", "1",
        "在聊天里提醒管理员注意可疑玩家。",
        FCVAR_PROTECTED, true, 0.0, true, 1.0);
    hcvar[CVAR_ANGLES] = new Convar("lilac_angles", "1",
        "检测角度类作弊（基础 Anti-Aim、合法反背刺、蹲行加速 Duckspeed）。\n-1 = 仅记录日志。\n0 = 关闭。\n1 = 开启。",
        FCVAR_PROTECTED, true, -1.0, true, 1.0);
    hcvar[CVAR_PATCH_ANGLES] = new Convar("lilac_angles_patch", "1",
        "修正角度类作弊（基础 Anti-Aim、合法反背刺、蹲行加速），使其失效。",
        FCVAR_PROTECTED, true, 0.0, true, 1.0);
    hcvar[CVAR_CHAT] = new Convar("lilac_chatclear", "1",
        "检测清空聊天（Chat-Clear）作弊。\n-1 = 仅记录日志。\n0 = 关闭。\n1 = 开启。",
        FCVAR_PROTECTED, true, -1.0, true, 1.0);
    hcvar[CVAR_CONVAR] = new Convar("lilac_convar", "1",
        "检测基础非法 ConVar。\n-1 = 仅记录日志。\n0 = 关闭。\n1 = 踢出。\n2 = 封禁。",
        FCVAR_PROTECTED, true, -1.0, true, 2.0);
    hcvar[CVAR_NOLERP] = new Convar("lilac_nolerp", "0",
        "检测 NoLerp（把插值 interp 设为 0）。\n-1 = 仅记录日志。\n0 = 关闭。\n1 = 开启。",
        FCVAR_PROTECTED, true, -1.0, true, 1.0);
    hcvar[CVAR_BHOP] = new Convar("lilac_bhop", "0",
        "连跳（Bhop）检测模式（负值 = 仅记录日志）。\n0 = 关闭。\n1、2 = 保留（无效）。\n3 = 自定义（解锁 lilac_bhop_set 命令）。\n4 = 低。\n5 = 中。\n6 = 高。",
        FCVAR_PROTECTED, true, -6.0, true, 6.0);
    hcvar[CVAR_AIMBOT] = new Convar("lilac_aimbot", "5",
        "检测基础自瞄（Aimbot）。\n0 = 关闭。\n1 = 仅记录日志。\n5 及以上 = 第 N 次检测到即封禁（最小只能填 5）",
        FCVAR_PROTECTED, true, 0.0, false, 0.0);
    hcvar[CVAR_AIMBOT_AUTOSHOOT] = new Convar("lilac_aimbot_autoshoot", "1",
        "检测自动开枪（Autoshoot）。",
        FCVAR_PROTECTED, true, 0.0, true, 1.0);
    hcvar[CVAR_AIMLOCK] = new Convar("lilac_aimlock", "10",
        "检测锁头（Aimlock）。\n0 = 关闭。\n1 = 仅记录日志。\n5 及以上 = 第 N 次检测到即封禁（最小只能填 5）。",
        FCVAR_PROTECTED, true, 0.0, false, 0.0);
    hcvar[CVAR_AIMLOCK_LIGHT] = new Convar("lilac_aimlock_light", "1",
        "锁头检测只处理瞄准行为可疑的玩家。\n0 = 关闭（检查所有玩家）。\n1 = 开启（只检查可疑玩家，推荐）。",
        FCVAR_PROTECTED, true, 0.0, true, 1.0);
    hcvar[CVAR_BACKTRACK_PATCH] = new Convar("lilac_backtrack_patch", "0",
        "修正回溯（Backtrack）作弊。\n0 = 关闭（推荐设置）。\n1 = 开启。",
        FCVAR_PROTECTED, true, 0.0, true, 1.0);
    hcvar[CVAR_BACKTRACK_TOLERANCE] = new Convar("lilac_backtrack_tolerance", "0",
        "回溯补丁对 tickcount 变化的容忍程度。\n0 = 不容忍（推荐）。\n1 及以上 = 容忍 n 个 tick。",
        FCVAR_PROTECTED, true, 0.0, true, 3.0);
    hcvar[CVAR_MAX_PING] = new Convar("lilac_max_ping", "0",
        "对延迟过高的玩家封禁 3 分钟。\n此功能用于对付伪造延迟（fakelatency），封禁时长只是为了不让玩家立刻重连。\n0 = 不限制延迟，最小只能填 100。",
        FCVAR_PROTECTED, true, 0.0, true, 1000.0);
    hcvar[CVAR_MAX_PING_SPEC] = new Convar("lilac_max_ping_spec", "0",
        "延迟过高的玩家会在该秒数后被移到观察者并收到警告（最小只能填 30）。",
        FCVAR_PROTECTED, true, 0.0, true, 90.0);
    hcvar[CVAR_MAX_LERP] = new Convar("lilac_max_lerp", "0",
        "踢出试图利用插值（interp）的玩家，任何高于该值的 interp 都会被踢出。\n最小只能填 105（游戏默认 interp = 100）。\n0 或小于 105 = 关闭。",
        FCVAR_PROTECTED, true, 0.0, true, 510.0); /* 500 is max possible. */
    hcvar[CVAR_MACRO] = new Convar("lilac_macro", "0",
        "检测宏（Macro）。\n-1 = 仅记录日志。\n0 = 关闭。\n1 = 开启。\n2 = 开启，但不写日志。",
        FCVAR_PROTECTED, true, -1.0, true, 2.0);
    hcvar[CVAR_MACRO_WARNING] = new Convar("lilac_macro_warning", "1",
        "宏检测的警告方式：\n0 = 不警告。\n1 = 警告使用宏的玩家。\n2 = 警告服务器内的管理员。\n3 = 警告所有人。",
        FCVAR_PROTECTED, true, 0.0, true, 3.0);
    hcvar[CVAR_MACRO_DEAL_METHOD] = new Convar("lilac_macro_method", "0",
        "对检测到使用宏的玩家如何处理：\n0 = 踢出。\n1 = 封禁。",
        FCVAR_PROTECTED, true, 0.0, true, 1.0);
    hcvar[CVAR_MACRO_MODE] = new Convar("lilac_macro_mode", "0",
        "检测哪一类宏：\n0 = 全部。\n1 = 自动跳跃。\n2 = 自动开枪。",
        FCVAR_PROTECTED, true, 0.0, true, 3.0);
    hcvar[CVAR_FILTER_NAME] = new Convar("lilac_filter_name", "2",
        "过滤非法昵称（会踢出昵称非法的玩家）。\n-1 = 仅记录日志。\n0 = 关闭。\n1 = 开启，仅踢出。\n2 = 昵称中含换行符的作弊者直接封禁。",
        FCVAR_PROTECTED, true, -1.0, true, 2.0);
    hcvar[CVAR_FILTER_CHAT] = new Convar("lilac_filter_chat", "1",
        "过滤聊天中的非法字符（拦截该条聊天消息）。",
        FCVAR_PROTECTED, true, 0.0, true, 1.0);
    hcvar[CVAR_LOSS_FIX] = new Convar("lilac_loss_fix", "1",
        "对丢包严重的玩家（与服务器连接质量差）忽略部分作弊检测。",
        FCVAR_PROTECTED, true, 0.0, true, 1.0);
    hcvar[CVAR_NET_VETO] = new Convar("lilac_network_veto", "1",
        "当玩家网络状况使基于时序的分析不可靠时（延迟、抖动、丢包或 choke），暂停自瞄、锁头与加速检测并作废其结果。",
        FCVAR_PROTECTED, true, 0.0, true, 1.0);
    hcvar[CVAR_DATABASE] = new Convar("lilac_database", "",
        "把检测结果记录到的数据库。\n留空 = 不写数据库\n数据库名 = 写入该数据库（支持 MySQL 与 SQLite）",
        FCVAR_PROTECTED);
    hcvar[CVAR_SPEEDHACK] = new Convar("lilac_speedhack", "3",
        "检测加速（Speedhack）。\n0 = 关闭。\n1 = 仅记录日志。\n3 及以上 = 第 N 次检测到即封禁（最小只能填 3）。",
        FCVAR_PROTECTED, true, 0.0, false, 0.0);
    hcvar[CVAR_INFECTED_DMG] = new Convar("lilac_infected_damage", "3",
        "检测感染者伤害漏洞（仅 L4D2）。\n0 = 关闭。\n1 = 仅记录日志。\n3 及以上 = 第 N 次检测到即封禁（最小只能填 3）。",
        FCVAR_PROTECTED, true, 0.0, false, 0.0);
    hcvar[CVAR_SURVIVOR_DMG] = new Convar("lilac_survivor_damage", "3",
        "检测生还者对坦克的爆发伤害漏洞（仅 L4D2）。\n0 = 关闭。\n1 = 仅记录日志。\n3 及以上 = 第 N 次检测到即封禁（最小只能填 3）。",
        FCVAR_PROTECTED, true, 0.0, false, 0.0);
    hcvar[CVAR_TELEMETRY] = new Convar("lilac_telemetry", "0",
        "测量与调试日志，永远不参与判定。\n0 = 关闭。\n1 = 自瞄（smooth 与角度指标文件）。\n2 = 加速（影子文件与额外检测字段）。\n4 = 网络（指令突发）。\n8 = 生还者伤害时钟文件。\n数值相加可组合使用（15 = 全部）。",
        FCVAR_PROTECTED, true, 0.0, true, 15.0);

    for (int i = 0; i < CVAR_MAX; i++) {
        if (i != CVAR_LOG_DATE)
            icvar[i] = hcvar[i].IntValue;

        hcvar[i].AddChangeHook(cvar_change);
    }

    if ((tcvar = FindConVar("sv_maxupdaterate")) != null) {
        tcvar.AddChangeHook(cvar_change);
        lilac_lerp_maxupdaterate_changed(tcvar.IntValue);
    }
    else {
        /* Assume the value is 0 if we can't fetch it. */
        lilac_lerp_maxupdaterate_changed(0);
    }

    /* If the server allows clients to set the interp ratio to
    *     whatever they want, then false positives become possible.
    * Thanks RoseTheFox / Bud for reporting this :) */
    if ((tcvar = FindConVar("sv_client_min_interp_ratio")) != null) {
        tcvar.AddChangeHook(cvar_change);
        lilac_lerp_ratio_changed(tcvar.IntValue);

        if ((tcvar = FindConVar("sv_client_max_interp_ratio")) != null) {
            tcvar.AddChangeHook(cvar_change);
            lilac_lerp_ratio_changed(tcvar.IntValue);
        }
        else {
            lilac_lerp_ratio_changed(0);
        }
    }
    else {
        lilac_lerp_ratio_changed(0);
    }

    if ((tcvar = FindConVar("sv_cheats")) != null) {
        tcvar.AddChangeHook(cvar_change);
        sv_cheats = tcvar.IntValue;
    }
    else {
        sv_cheats = 1;
    }

    RegServerCmd("lilac_date_list", lilac_date_list, "列出可用的日期格式选项", 0);
    RegServerCmd("lilac_set_ban_length", lilac_set_ban_length, "为特定作弊类型自定义封禁时长。", 0);
    RegServerCmd("lilac_get_bans_length", lilac_get_bans_length, "显示当前各作弊类型的封禁时长。", 0);
    RegServerCmd("lilac_ban_status", lilac_ban_status, "在服务器控制台打印当前封禁状态。", 0);
    RegServerCmd("lilac_bhop_set", lilac_bhop_set, "设置自定义连跳（Bhop）参数", 0);
    RegServerCmd("lilac_discord_test", lilac_discord_test, "向 Discord Webhook 发送一条测试举报。用法：lilac_discord_test [ban|kick|suspect]", 0);

    /* Legacy check, execute old config location.
    * Uses github.com/kidfearless/Auto-Exec-Config-Class */
    if (FileExists("cfg/lilac_config.cfg", false, NULL_STRING))
        Convar.CreateConfig("lilac_config", "");
    else
        Convar.CreateConfig("lilac_config", "sourcemod");
}

public void OnConfigsExecuted()
{
	static bool run_status_ban = true;

	if (run_status_ban)
		lilac_ban_status(0);

	/* We need to call this here, in case of a plugin reload. */
	lilac_bhop_set_preset();

	run_status_ban = false;

	Database_OnConfigExecuted();
}

public Action lilac_bhop_set(int args)
{
	char buffer[16];
	float fl = 0.0;
	int value = 0;
	int index = 0;

	if (intabs(icvar[CVAR_BHOP]) != BHOP_MODE_CUSTOM) {
		PrintToServer("Error: Must be in custom mode, set 'lilac_bhop' to %d.",
			BHOP_MODE_CUSTOM);
		return Plugin_Handled;
	}
	else if (args < 2) {
		PrintToServer("Error: too few arguments.\nUsage: lilac_bhop_set <type> <value>");
		PrintToServer("Examples:");
		PrintToServer("\tlilac_bhop_set min 7");
		PrintToServer("\tlilac_bhop_set ticks -1");
		PrintToServer("\tlilac_bhop_set max 15");
		PrintToServer("\tlilac_bhop_set air 0.3");
		PrintToServer("\tlilac_bhop_set total 4");
		PrintToServer("\nType list:");
		PrintToServer("\tmin   - Minimum consecutive perfect bhops to trigger a detection.");
		PrintToServer("\tticks - Jump tick buffer before min is ignored.");
		PrintToServer("\tmax   - Maximum consecutive perfect bhops to trigger an instant ban.");
		PrintToServer("\tair   - Minimum air-time between bhops in seconds.");
		PrintToServer("\ttotal - How many detections before banning.");
		PrintToServer("\n");
		print_current_bhop_settings();

		return Plugin_Handled;
	}

	GetCmdArg(2, buffer, sizeof(buffer));
	fl = StringToFloat(buffer);
	GetCmdArg(1, buffer, sizeof(buffer));

	/* Working with strings is always the least fun part ): */
	if (StrEqual(buffer, "min", false)
		|| StrEqual(buffer, "minimal", false)
		|| StrEqual(buffer, "minimum", false)) {
		index = BHOP_INDEX_MIN;
	}
	else if (StrEqual(buffer, "jump", false)
		|| StrEqual(buffer, "jumps", false)
		|| StrEqual(buffer, "tick", false)
		|| StrEqual(buffer, "ticks", false)
		|| StrEqual(buffer, "buf", false)
		|| StrEqual(buffer, "buff", false)
		|| StrEqual(buffer, "buffer", false)
		|| StrEqual(buffer, "jump_tick", false)
		|| StrEqual(buffer, "jump_ticks", false)
		|| StrEqual(buffer, "jumptick", false)
		|| StrEqual(buffer, "jumpticks", false)) {
		index = BHOP_INDEX_JUMP;
	}
	else if (StrEqual(buffer, "max", false)
		|| StrEqual(buffer, "maximal", false)
		|| StrEqual(buffer, "maximum", false)) {
		index = BHOP_INDEX_MAX;
	}
	else if (StrEqual(buffer, "air", false)
		|| StrEqual(buffer, "air-time", false)
		|| StrEqual(buffer, "airtime", false)) {
		index = BHOP_INDEX_AIR;
	}
	else if (StrEqual(buffer, "tot", false)
		|| StrEqual(buffer, "total", false)
		|| StrEqual(buffer, "all", false)
		|| StrEqual(buffer, "detection", false)
		|| StrEqual(buffer, "detections", false)) {
		index = BHOP_INDEX_TOTAL;
	}
	else {
		PrintToServer("Error: Unknown type \"%s\"", buffer);
		return Plugin_Handled;
	}

	if (index == BHOP_INDEX_AIR) {
		if (fl > 1.0)
			fl = 1.0;
		value = RoundToCeil(tick_rate * fl);
	}
	else {
		value = RoundToNearest(fl);
	}

	if (value < bhop_settings_min[index]) {
		/* Total setting CANNOT be set to be
		 * lower than the min, no matter what! */
		if (index == BHOP_INDEX_TOTAL) {
			value = bhop_settings_min[index];
		}
		else if (value != 0) {
			PrintToServer("Warning: Minimum value is %d, use '0' to disable feature.",
				bhop_settings_min[index]);
			value = bhop_settings_min[index];
		}
	}

	if (index == BHOP_INDEX_AIR)
		PrintToServer("[Lilac] Changed Bhop setting \"%s\" to %d ticks.",
			buffer, value);
	else
		PrintToServer("[Lilac] Changed Bhop setting \"%s\" to %d.",
			buffer, value);

	bhop_settings[index] = value;
	print_current_bhop_settings();

	/* Both being 0 means we won't detect anything, lol.
	 * So let's warn the admin :) */
	if (!bhop_settings[BHOP_INDEX_MIN] && !bhop_settings[BHOP_INDEX_MAX])
		PrintToServer("Warning: Min and Max are set to 0, bhop detection is now disabled!");

	return Plugin_Handled;
}

static void print_current_bhop_settings()
{
	/* Yeah, a little messy... */
	PrintToServer("Current Bhop values:");
	PrintToServer("    Type  : Min possible : Current");
	PrintToServer("    Min   : %2d           : %d", bhop_settings_min[BHOP_INDEX_MIN], bhop_settings[BHOP_INDEX_MIN]);
	if (bhop_settings[BHOP_INDEX_JUMP] == -1)
		PrintToServer("    Ticks : %2d           : %d", bhop_settings_min[BHOP_INDEX_JUMP], bhop_settings[BHOP_INDEX_JUMP]);
	else
		PrintToServer("    Ticks : %2d           : %d (+%d = %d total)", bhop_settings_min[BHOP_INDEX_JUMP], bhop_settings[BHOP_INDEX_JUMP], bhop_settings[BHOP_INDEX_MIN], bhop_settings[BHOP_INDEX_JUMP] + bhop_settings[BHOP_INDEX_MIN]);
	PrintToServer("    Max   : %2d           : %d", bhop_settings_min[BHOP_INDEX_MAX], bhop_settings[BHOP_INDEX_MAX]);
	PrintToServer("    Air   : %2d           : %d", bhop_settings_min[BHOP_INDEX_AIR], bhop_settings[BHOP_INDEX_AIR]);
	PrintToServer("    Total : %2d           : %d", bhop_settings_min[BHOP_INDEX_TOTAL], bhop_settings[BHOP_INDEX_TOTAL]);
}

public Action lilac_ban_status(int args)
{
    char tmp[24];

    PrintToServer("====[Little Anti-Cheat %s - Ban Status]====", PLUGIN_VERSION);
    PrintToServer("Checking ban plugins and third party plugins:");

    PrintToServer("AutoRecorder:");
    PrintToServer("\tLoaded: %s", ((LibraryExists("autorecorder")) ? "Yes" : "No"));
    PrintToServer("\tNative Exists: %s", ((NATIVE_EXISTS("AR_GetMatchID")) ? "Yes" : "No"));
    PrintToServer("\tConVar: lilac_autorecorder = %d", icvar[CVAR_AR]);

    PrintToServer("SourceTV Manager (demo tick in logs):");
    PrintToServer("\tNative Exists: %s", ((NATIVE_EXISTS("SourceTV_GetRecordingTick")) ? "Yes" : "No"));

    if (g_bGame == Engine_Left4Dead2)
        lilac_infected_damage_print_limits();

    PrintToServer("Material-Admin:");
    PrintToServer("\tLoaded: %s", ((LibraryExists("materialadmin")) ? "Yes" : "No"));
    PrintToServer("\tNative Exists: %s", ((NATIVE_EXISTS("MABanPlayer")) ? "Yes" : "No"));
    PrintToServer("\tConVar: lilac_materialadmin = %d", icvar[CVAR_MA]);

    PrintToServer("Sourcebans++:");
    PrintToServer("\tLoaded: %s", ((LibraryExists("sourcebans++")) ? "Yes" : "No"));
    PrintToServer("\tNative Exists: %s", ((NATIVE_EXISTS("SBPP_BanPlayer")) ? "Yes" : "No"));
    PrintToServer("\tConVar: lilac_sourcebans = %d", icvar[CVAR_SB]);

    PrintToServer("Sourcebans (Old):");
    PrintToServer("\tLoaded: %s", ((LibraryExists("sourcebans")) ? "Yes" : "No"));
    PrintToServer("\tNative Exists: %s", ((NATIVE_EXISTS("SBBanPlayer")) ? "Yes" : "No"));
    PrintToServer("\tConVar: lilac_sourcebans = %d", icvar[CVAR_SB]);

    PrintToServer("SourceIRC:");
    PrintToServer("\tNative Exists: %s", ((NATIVE_EXISTS("IRC_MsgFlaggedChannels")) ? "Yes" : "No"));
    PrintToServer("\tConVar: lilac_sourceirc = %d", icvar[CVAR_SOURCEIRC]);
    if (icvar[CVAR_SOURCEIRC] && NATIVE_EXISTS("IRC_MsgFlaggedChannels"))
        IRC_MsgFlaggedChannels("lilac", "[LILAC] is active and logging to SourceIRC!");

    switch (lilac_get_ban_backend()) {
    case BAN_BACKEND_BASEBANS: { strcopy(tmp, sizeof(tmp), "BaseBans"); }
    case BAN_BACKEND_SOURCEBANS: { strcopy(tmp, sizeof(tmp), "SourceBans (Old)"); }
    case BAN_BACKEND_SOURCEBANSPP: { strcopy(tmp, sizeof(tmp), "SourceBans++"); }
    case BAN_BACKEND_MATERIALADMIN: { strcopy(tmp, sizeof(tmp), "Material-Admin"); }
    default: return Plugin_Handled;
    }

    PrintToServer("\nBanning will go though %s.\n", tmp);

    return Plugin_Handled;
}

public Action lilac_set_ban_length(int args)
{
	char feature[32], length[32];
	int index = -1;
	int time;

	if (args < 2) {
		PrintToServer("Error: Too few arguments.\nUsage: lilac_set_ban_length <cheat> <minutes>");
		PrintToServer("Example:\n\tlilac_set_ban_length bhop 15\n\t(Sets bhop ban to 15 minutes)");
		PrintToServer("\nIf ban length is -1, then the ban length will be the ConVar lilac_ban_length's value.");
		PrintToServer("\nPossible cheat arguments:");
		PrintToServer("\tlilac_set_ban_length angles <minutes>");
		PrintToServer("\tlilac_set_ban_length chatclear <minutes>");
		PrintToServer("\tlilac_set_ban_length convar <minutes>");
		PrintToServer("\tlilac_set_ban_length nolerp <minutes>");
		PrintToServer("\tlilac_set_ban_length bhop <minutes>");
		PrintToServer("\tlilac_set_ban_length aimbot <minutes>");
		PrintToServer("\tlilac_set_ban_length aimlock <minutes>");
		PrintToServer("\tlilac_set_ban_length macro <minutes>");
		PrintToServer("\tlilac_set_ban_length speedhack <minutes>");
		PrintToServer("\tlilac_set_ban_length infected_damage <minutes>");
		PrintToServer("\tlilac_set_ban_length name <minutes>\n");

		return Plugin_Handled;
	}

	GetCmdArg(1, feature, sizeof(feature));

	if (StrEqual(feature, "angles", false) || StrEqual(feature, "angle", false)) {
		index = CHEAT_ANGLES;
	}
	else if (StrEqual(feature, "chat", false) || StrEqual(feature, "chatclear", false)) {
		index = CHEAT_CHATCLEAR;
	}
	else if (StrEqual(feature, "convar", false) || StrEqual(feature, "cvar", false)) {
		index = CHEAT_CONVAR;
	}
	else if (StrEqual(feature, "nolerp", false)) {
		index = CHEAT_NOLERP;
	}
	else if (StrEqual(feature, "bhop", false) || StrEqual(feature, "bunnyhop", false)) {
		index = CHEAT_BHOP;
	}
	else if (StrEqual(feature, "aimbot", false) || StrEqual(feature, "aim", false)) {
		index = CHEAT_AIMBOT;
	}
	else if (StrEqual(feature, "aimlock", false) || StrEqual(feature, "lock", false)) {
		index = CHEAT_AIMLOCK;
	}
	else if (StrEqual(feature, "macro", false)) {
		index = CHEAT_MACRO;
	}
	else if (StrEqual(feature, "speedhack", false)) {
		index = CHEAT_SPEEDHACK;
	}
	else if (StrEqual(feature, "infected_damage", false) || StrEqual(feature, "infected", false)) {
		index = CHEAT_INFECTED_DMG;
	}
	else if (StrEqual(feature, "survivor_damage", false) || StrEqual(feature, "survivor", false)) {
		index = CHEAT_SURVIVOR_DMG;
	}
	else if (StrEqual(feature, "name", false) || StrEqual(feature, "filter", false)) {
		index = CHEAT_NEWLINE_NAME;
	}
	else {
		PrintToServer("Error: Unknown cheat feature \"%s\"", feature);
		return Plugin_Handled;
	}

	GetCmdArg(2, length, sizeof(length));
	time = StringToInt(length, 10);

	/* Macro exception. */
	if (index == CHEAT_MACRO) {
		if (time > 60)
			time = 60;
		else if (time < 15)
			time = 15;
	}
	else if (time < -1)
		time = -1;

	ban_length_overwrite[index] = time;

	/* Show confirmation message with new ban length */
	char cheat_name[32];
	switch (index) {
		case CHEAT_ANGLES: strcopy(cheat_name, sizeof(cheat_name), "Angles");
		case CHEAT_CHATCLEAR: strcopy(cheat_name, sizeof(cheat_name), "Chat Clear");
		case CHEAT_CONVAR: strcopy(cheat_name, sizeof(cheat_name), "ConVar");
		case CHEAT_NOLERP: strcopy(cheat_name, sizeof(cheat_name), "NoLerp");
		case CHEAT_BHOP: strcopy(cheat_name, sizeof(cheat_name), "Bhop");
		case CHEAT_AIMBOT: strcopy(cheat_name, sizeof(cheat_name), "Aimbot");
		case CHEAT_AIMLOCK: strcopy(cheat_name, sizeof(cheat_name), "Aimlock");
		case CHEAT_MACRO: strcopy(cheat_name, sizeof(cheat_name), "Macro");
        case CHEAT_SPEEDHACK: strcopy(cheat_name, sizeof(cheat_name), "Speedhack");
		case CHEAT_NEWLINE_NAME: strcopy(cheat_name, sizeof(cheat_name), "Newline Name");
		case CHEAT_INFECTED_DMG: strcopy(cheat_name, sizeof(cheat_name), "Infected Damage Exploit");
		case CHEAT_SURVIVOR_DMG: strcopy(cheat_name, sizeof(cheat_name), "Survivor Damage Exploit");
		default: strcopy(cheat_name, sizeof(cheat_name), "Unknown");
	}
	
	if (time == -1) {
		PrintToServer("[Lilac] Changed %s ban length to use global ConVar 'lilac_ban_length' (%d minutes).", 
			cheat_name, icvar[CVAR_BAN_LENGTH]);
	} else if (time == 0) {
		PrintToServer("[Lilac] Changed %s ban length to permanent ban.", cheat_name);
	} else {
		PrintToServer("[Lilac] Changed %s ban length to %d minutes.", cheat_name, time);
	}

	return Plugin_Handled;
}

public Action lilac_get_bans_length(int args)
{
	PrintToServer("====[Little Anti-Cheat %s - Ban Length Status]====", PLUGIN_VERSION);
	PrintToServer("Current ban lengths for each cheat type:");
	PrintToServer("(Values in minutes, -1 = Use global ConVar 'lilac_ban_length')");
	PrintToServer("");

	PrintToServer("Cheat Type          : Custom Length : Effective Length");
	PrintToServer("------------------------------------------------");

	// Angles
	int effective_length = (ban_length_overwrite[CHEAT_ANGLES] <= -1) ? icvar[CVAR_BAN_LENGTH] : ban_length_overwrite[CHEAT_ANGLES];
	PrintToServer("Angles              : %-13d : %d", ban_length_overwrite[CHEAT_ANGLES], effective_length);

	// Chat Clear
	effective_length = (ban_length_overwrite[CHEAT_CHATCLEAR] <= -1) ? icvar[CVAR_BAN_LENGTH] : ban_length_overwrite[CHEAT_CHATCLEAR];
	PrintToServer("Chat Clear          : %-13d : %d", ban_length_overwrite[CHEAT_CHATCLEAR], effective_length);

	// ConVar
	effective_length = (ban_length_overwrite[CHEAT_CONVAR] <= -1) ? icvar[CVAR_BAN_LENGTH] : ban_length_overwrite[CHEAT_CONVAR];
	PrintToServer("ConVar              : %-13d : %d", ban_length_overwrite[CHEAT_CONVAR], effective_length);

	// NoLerp
	effective_length = (ban_length_overwrite[CHEAT_NOLERP] <= -1) ? icvar[CVAR_BAN_LENGTH] : ban_length_overwrite[CHEAT_NOLERP];
	PrintToServer("NoLerp              : %-13d : %d", ban_length_overwrite[CHEAT_NOLERP], effective_length);

	// Bhop
	effective_length = (ban_length_overwrite[CHEAT_BHOP] <= -1) ? icvar[CVAR_BAN_LENGTH] : ban_length_overwrite[CHEAT_BHOP];
	PrintToServer("Bhop                : %-13d : %d", ban_length_overwrite[CHEAT_BHOP], effective_length);

	// Aimbot
	effective_length = (ban_length_overwrite[CHEAT_AIMBOT] <= -1) ? icvar[CVAR_BAN_LENGTH] : ban_length_overwrite[CHEAT_AIMBOT];
	PrintToServer("Aimbot              : %-13d : %d", ban_length_overwrite[CHEAT_AIMBOT], effective_length);

	// Aimlock
	effective_length = (ban_length_overwrite[CHEAT_AIMLOCK] <= -1) ? icvar[CVAR_BAN_LENGTH] : ban_length_overwrite[CHEAT_AIMLOCK];
	PrintToServer("Aimlock             : %-13d : %d", ban_length_overwrite[CHEAT_AIMLOCK], effective_length);

	// Macro
	effective_length = (ban_length_overwrite[CHEAT_MACRO] <= -1) ? icvar[CVAR_BAN_LENGTH] : ban_length_overwrite[CHEAT_MACRO];
	PrintToServer("Macro               : %-13d : %d", ban_length_overwrite[CHEAT_MACRO], effective_length);

	// Newline Name
	effective_length = (ban_length_overwrite[CHEAT_NEWLINE_NAME] <= -1) ? icvar[CVAR_BAN_LENGTH] : ban_length_overwrite[CHEAT_NEWLINE_NAME];
	PrintToServer("Newline Name        : %-13d : %d", ban_length_overwrite[CHEAT_NEWLINE_NAME], effective_length);

	// Speedhack
	effective_length = (ban_length_overwrite[CHEAT_SPEEDHACK] <= -1) ? icvar[CVAR_BAN_LENGTH] : ban_length_overwrite[CHEAT_SPEEDHACK];
	PrintToServer("Speedhack           : %-13d : %d", ban_length_overwrite[CHEAT_SPEEDHACK], effective_length);

	// Infected Damage Exploit
	effective_length = (ban_length_overwrite[CHEAT_INFECTED_DMG] <= -1) ? icvar[CVAR_BAN_LENGTH] : ban_length_overwrite[CHEAT_INFECTED_DMG];
	PrintToServer("Infected Damage     : %-13d : %d", ban_length_overwrite[CHEAT_INFECTED_DMG], effective_length);

	PrintToServer("");
	PrintToServer("Global ConVar 'lilac_ban_length' = %d minutes", icvar[CVAR_BAN_LENGTH]);
	PrintToServer("(0 = permanent ban)");

	return Plugin_Handled;
}

public Action lilac_date_list(int args)
{
	PrintToServer("=======[Lilac Date Formatting]=======");
	PrintToServer("Manual formatting:");
	PrintToServer("\t{raw} = Skips the special formatting listed here");
	PrintToServer("\t        and lets you insert your own formatting");
	PrintToServer("\t        (see: http://www.cplusplus.com/reference/ctime/strftime/).");
	PrintToServer("Example:\n\t{raw}%%Y/%%m/%%d %%H:%%M:%%S");
	PrintToServer("Dates:");
	PrintToServer("\t{year}    = Numerical year  (2020).");
	PrintToServer("\t{month}   = Numerical month   (12).");
	PrintToServer("\t{day}     = Numerical day     (28).");
	PrintToServer("Time:");
	PrintToServer("\t{hour}    = 24 hour format.");
	PrintToServer("\t{hours}   = 24 hour format.");
	PrintToServer("\t{24hour}  = 24 hour format.");
	PrintToServer("\t{24hours} = 24 hour format.");
	PrintToServer("\t{12hour}  = 12 hour format.");
	PrintToServer("\t{12hours} = 12 hour format.");
	PrintToServer("\t{pm}      = Insert AM/PM.");
	PrintToServer("\t{am}      = Insert AM/PM.");
	PrintToServer("\t{minute}  = Minute.");
	PrintToServer("\t{minutes} = Minute.");
	PrintToServer("\t{second}  = Second.");
	PrintToServer("\t{seconds} = Second.");
	PrintToServer("Using flags example: {year}/{month}/{day} {hour}:{minute}:{second}");

	return Plugin_Continue;
}

public void cvar_change(ConVar convar, const char[] oldValue, const char[] newValue)
{
    char cvarname[64];
    char testdate[512];

    /* Thanks to MAGNAT2645 for informing me I could do this! */
    if (convar == hcvar[CVAR_ENABLE]) {
        icvar[CVAR_ENABLE] = StringToInt(newValue);
    }
    else if (convar == hcvar[CVAR_WELCOME]) {
        icvar[CVAR_WELCOME] = StringToInt(newValue);
    }
    else if (convar == hcvar[CVAR_AR]) {
        icvar[CVAR_AR] = StringToInt(newValue);
    }
    else if (convar == hcvar[CVAR_SB]) {
        icvar[CVAR_SB] = StringToInt(newValue);
    }
    else if (convar == hcvar[CVAR_MA]) {
        icvar[CVAR_MA] = StringToInt(newValue);
    }
    else if (convar == hcvar[CVAR_SOURCEIRC]) {
        icvar[CVAR_SOURCEIRC] = StringToInt(newValue);
    }
    else if (convar == hcvar[CVAR_LOG]) {
        icvar[CVAR_LOG] = StringToInt(newValue);
    }
    else if (convar == hcvar[CVAR_LOG_EXTRA]) {
        icvar[CVAR_LOG_EXTRA] = StringToInt(newValue);
    }
    else if (convar == hcvar[CVAR_LOG_MISC]) {
        icvar[CVAR_LOG_MISC] = StringToInt(newValue);
    }
    else if (convar == hcvar[CVAR_LOG_DATE]) {
        lilac_setup_date_format(newValue);
        
        FormatTime(testdate, sizeof(testdate), dateformat, GetTime());
        PrintToServer("Date Format Preview: %s", testdate);
    }
    else if (convar == hcvar[CVAR_BAN]) {
        icvar[CVAR_BAN] = StringToInt(newValue);

        if (!icvar[CVAR_BAN])
            PrintToServer("[Little Anti-Cheat %s] WARNING: 'lilac_ban' has been set to 0, banning of cheaters has been disabled.", PLUGIN_VERSION);
    }
    else if (convar == hcvar[CVAR_BAN_LENGTH]) {
        icvar[CVAR_BAN_LENGTH] = StringToInt(newValue);
    }
    else if (convar == hcvar[CVAR_BAN_LANGUAGE]) {
        icvar[CVAR_BAN_LANGUAGE] = StringToInt(newValue);
    }
    else if (convar == hcvar[CVAR_CHEAT_WARN]) {
        icvar[CVAR_CHEAT_WARN] = StringToInt(newValue);
    }
    else if (convar == hcvar[CVAR_ANGLES]) {
        icvar[CVAR_ANGLES] = StringToInt(newValue);
    }
    else if (convar == hcvar[CVAR_PATCH_ANGLES]) {
        icvar[CVAR_PATCH_ANGLES] = StringToInt(newValue);
    }
    else if (convar == hcvar[CVAR_CHAT]) {
        icvar[CVAR_CHAT] = StringToInt(newValue);
    }
    else if (convar == hcvar[CVAR_CONVAR]) {
        icvar[CVAR_CONVAR] = StringToInt(newValue);

        if (icvar[CVAR_CONVAR] > 2)
            icvar[CVAR_CONVAR] = 2;
    }
    else if (convar == hcvar[CVAR_NOLERP]) {
        icvar[CVAR_NOLERP] = StringToInt(newValue);
    }
    else if (convar == hcvar[CVAR_BHOP]) {
        icvar[CVAR_BHOP] = StringToInt(newValue);
        lilac_bhop_set_preset();
    }
    else if (convar == hcvar[CVAR_AIMBOT]) {
        icvar[CVAR_AIMBOT] = StringToInt(newValue);
        
        if (icvar[CVAR_AIMBOT] > 2 &&
            icvar[CVAR_AIMBOT] < AIMBOT_BAN_MIN)
            icvar[CVAR_AIMBOT] = AIMBOT_BAN_MIN;
    }
    else if (convar == hcvar[CVAR_AIMBOT_AUTOSHOOT]) {
        icvar[CVAR_AIMBOT_AUTOSHOOT] = StringToInt(newValue);
    }
    else if (convar == hcvar[CVAR_AIMLOCK]) {
        icvar[CVAR_AIMLOCK] = StringToInt(newValue);
        
        if (icvar[CVAR_AIMLOCK] > 2
            && icvar[CVAR_AIMLOCK] < AIMLOCK_BAN_MIN)
            icvar[CVAR_AIMLOCK] = AIMLOCK_BAN_MIN;
    }
    else if (convar == hcvar[CVAR_AIMLOCK_LIGHT]) {
        icvar[CVAR_AIMLOCK_LIGHT] = StringToInt(newValue);
    }
    else if (convar == hcvar[CVAR_BACKTRACK_PATCH]) {
        icvar[CVAR_BACKTRACK_PATCH] = StringToInt(newValue);
    }
    else if (convar == hcvar[CVAR_BACKTRACK_TOLERANCE]) {
        icvar[CVAR_BACKTRACK_TOLERANCE] = StringToInt(newValue);
        
        if (icvar[CVAR_BACKTRACK_TOLERANCE] > 2)
            PrintToServer("[Little Anti-Cheat %s] WARNING: It is not recommeded to set backtrack tolerance above 2, only do this if you understand what this means.", PLUGIN_VERSION);
    }
    else if (convar == hcvar[CVAR_MAX_PING]) {
        icvar[CVAR_MAX_PING] = StringToInt(newValue);
    }
    else if (convar == hcvar[CVAR_MAX_PING_SPEC]) {
        icvar[CVAR_MAX_PING_SPEC] = StringToInt(newValue);
        
        if (icvar[CVAR_MAX_PING_SPEC] < 30)
            icvar[CVAR_MAX_PING_SPEC] = 0;
    }
    else if (convar == hcvar[CVAR_MAX_LERP]) {
        icvar[CVAR_MAX_LERP] = StringToInt(newValue);
    }
    else if (convar == hcvar[CVAR_MACRO]) {
        icvar[CVAR_MACRO] = StringToInt(newValue);

        if (icvar[CVAR_MACRO] > 0)
            PrintToServer("[Little Anti-Cheat %s] WARNING: It's recommended to use log-only method for now.", PLUGIN_VERSION);

        /* Settings changed, reset counters. */
        for (int i = 1; i <= MaxClients; i++)
            lilac_macro_reset_client(i);
    }
    else if (convar == hcvar[CVAR_MACRO_WARNING]) {
        icvar[CVAR_MACRO_WARNING] = StringToInt(newValue);
    }
    else if (convar == hcvar[CVAR_MACRO_DEAL_METHOD]) {
        icvar[CVAR_MACRO_DEAL_METHOD] = StringToInt(newValue);
    }
    else if (convar == hcvar[CVAR_MACRO_MODE]) {
        icvar[CVAR_MACRO_MODE] = StringToInt(newValue);
    }
    else if (convar == hcvar[CVAR_FILTER_NAME]) {
        icvar[CVAR_FILTER_NAME] = StringToInt(newValue);
    }
    else if (convar == hcvar[CVAR_FILTER_CHAT]) {
        icvar[CVAR_FILTER_CHAT] = StringToInt(newValue);
    }
    else if (convar == hcvar[CVAR_LOSS_FIX]) {
        icvar[CVAR_LOSS_FIX] = StringToInt(newValue);
    }
    else if (convar == hcvar[CVAR_NET_VETO]) {
        icvar[CVAR_NET_VETO] = StringToInt(newValue);
    }
    else if (convar == hcvar[CVAR_SPEEDHACK]) {
        icvar[CVAR_SPEEDHACK] = StringToInt(newValue);
    }
    else if (convar == hcvar[CVAR_DATABASE]) {
        strcopy(db_name, sizeof(db_name), newValue);
    }
    else if (convar == hcvar[CVAR_INFECTED_DMG]) {
        icvar[CVAR_INFECTED_DMG] = StringToInt(newValue);
    }
    else if (convar == hcvar[CVAR_SURVIVOR_DMG]) {
        icvar[CVAR_SURVIVOR_DMG] = StringToInt(newValue);
    }
    else if (convar == hcvar[CVAR_TELEMETRY]) {
        int old = icvar[CVAR_TELEMETRY];

        icvar[CVAR_TELEMETRY] = StringToInt(newValue);

        if (!(old & TELEMETRY_NETWORK) && (icvar[CVAR_TELEMETRY] & TELEMETRY_NETWORK))
            lilac_network_burst_reset_all();

        lilac_log_telemetry_setup();
    }
    else if (convar == hcvar[CVAR_DISCORD]) {
        icvar[CVAR_DISCORD] = StringToInt(newValue);
    }
    else if (convar == hcvar[CVAR_DISCORD_WEBHOOK]) {
        /* A new URL may fix whatever made the last one fail. */
        lilac_discord_reset();
    }
    else {
        convar.GetName(cvarname, sizeof(cvarname));
        
        if (StrEqual(cvarname, "sv_autobunnyhopping", false)) {
            force_disable_bhop = StringToInt(newValue);
        }
        else if (StrEqual(cvarname, "sv_maxupdaterate", false)) {
            /* NoLerp checks need to know this value. */
            lilac_lerp_maxupdaterate_changed(StringToInt(newValue));

            /* Changing this convar mid-game can cause false positives.
            * Ignore players already in-game. */
            for (int i = 1; i <= MaxClients; i++)
                lilac_lerp_ignore_nolerp_client(i);
        }
        else if (StrEqual(cvarname, "sv_client_min_interp_ratio", false)) {
            lilac_lerp_ratio_changed(StringToInt(newValue));
        }
        else if (StrEqual(cvarname, "sv_client_max_interp_ratio", false)) {
            lilac_lerp_ratio_changed(StringToInt(newValue));
        }
        else if (StrEqual(cvarname, "sv_cheats", false)) {
            sv_cheats = StringToInt(newValue);
            
            /* Delay convar checks for 30 seconds. */
            time_sv_cheats = GetTime() + QUERY_TIMEOUT;
        }
    }
}

static int bclamp(int n, int idx)
{
	return ((n < bhop_settings_min[idx]) ? bhop_settings_min[idx] : n);
}

void lilac_bhop_set_preset()
{
	int mode = intabs(icvar[CVAR_BHOP]);

	switch (mode) {
	/* Backwards compatibility, mode 1 & 2 don't exist anymore.
	 * If a config is already set to use these, change mode to medium. */
	case BHOP_MODE_RESERVED_1, BHOP_MODE_RESERVED_2: {
		PrintToServer("[Lilac] Warning: Bhop mode 1 & 2 has been disabled, setting Bhop mode to %d (Medium).",
			BHOP_MODE_MEDIUM);
		hcvar[CVAR_BHOP].SetInt(BHOP_MODE_MEDIUM, false, false);
	}
	case BHOP_MODE_LOW, BHOP_MODE_CUSTOM: {
		/* Can't do switch fall-through in SourcePawn.
		 * Makes me miss C :( */
		if (mode == BHOP_MODE_CUSTOM) {
			PrintToServer("[Lilac] WARNING: DO NOT USE CUSTOM BHOP MODE UNLESS YOU KNOW WHAT YOU ARE DOING!");
		}

		/* Most of these clamps aren't necessary,
		 * but in-case I change the presets in the future,
		 * these are nice :) */
		bhop_settings[BHOP_INDEX_MIN] = bclamp(10, BHOP_INDEX_MIN);
		bhop_settings[BHOP_INDEX_JUMP] = 5;
		bhop_settings[BHOP_INDEX_MAX] = bclamp(25, BHOP_INDEX_MAX);
		bhop_settings[BHOP_INDEX_AIR] = RoundToCeil(tick_rate * 0.3);
		bhop_settings[BHOP_INDEX_TOTAL] = bclamp(5, BHOP_INDEX_TOTAL);
	}
	case BHOP_MODE_MEDIUM: {
		bhop_settings[BHOP_INDEX_MIN] = bclamp(7, BHOP_INDEX_MIN);
		bhop_settings[BHOP_INDEX_JUMP] = -1;
		bhop_settings[BHOP_INDEX_MAX] = bclamp(20, BHOP_INDEX_MAX);
		bhop_settings[BHOP_INDEX_AIR] = RoundToCeil(tick_rate * 0.3);
		bhop_settings[BHOP_INDEX_TOTAL] = bclamp(3, BHOP_INDEX_TOTAL);
	}
	case BHOP_MODE_HIGH: {
		bhop_settings[BHOP_INDEX_MIN] = bclamp(5, BHOP_INDEX_MIN);
		bhop_settings[BHOP_INDEX_JUMP] = 8; /* 5 for SMAC bypass, and 3 as buffer. */
		bhop_settings[BHOP_INDEX_MAX] = bclamp(20, BHOP_INDEX_MAX);
		bhop_settings[BHOP_INDEX_AIR] = RoundToCeil(tick_rate * 0.3);
		bhop_settings[BHOP_INDEX_TOTAL] = bclamp(1, BHOP_INDEX_TOTAL);
	}
	}

	print_current_bhop_settings();
}

static void lilac_setup_date_format(const char []format)
{
	strcopy(dateformat, sizeof(dateformat), format);

	if (ReplaceString(dateformat, sizeof(dateformat), "{raw}", "", false))
		return;

	ReplaceString(dateformat, sizeof(dateformat), "%%", "%%%%", false);

	ReplaceString(dateformat, sizeof(dateformat), "{year}", "%Y", false);
	ReplaceString(dateformat, sizeof(dateformat), "{month}", "%m", false);
	ReplaceString(dateformat, sizeof(dateformat), "{day}", "%d", false);

	ReplaceString(dateformat, sizeof(dateformat), "{hour}", "%H", false);
	ReplaceString(dateformat, sizeof(dateformat), "{hours}", "%H", false);
	ReplaceString(dateformat, sizeof(dateformat), "{24hour}", "%H", false);
	ReplaceString(dateformat, sizeof(dateformat), "{24hours}", "%H", false);
	ReplaceString(dateformat, sizeof(dateformat), "{12hour}", "%I", false);
	ReplaceString(dateformat, sizeof(dateformat), "{12hours}", "%I", false);
	ReplaceString(dateformat, sizeof(dateformat), "{pm}", "%p", false);
	ReplaceString(dateformat, sizeof(dateformat), "{am}", "%p", false);

	ReplaceString(dateformat, sizeof(dateformat), "{minute}", "%M", false);
	ReplaceString(dateformat, sizeof(dateformat), "{minutes}", "%M", false);
	ReplaceString(dateformat, sizeof(dateformat), "{second}", "%S", false);
	ReplaceString(dateformat, sizeof(dateformat), "{seconds}", "%S", false);
}
