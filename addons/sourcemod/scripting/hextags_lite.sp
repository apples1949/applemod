#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <colors>
#include <clientprefs>
#include <hextags>

#define PLUGIN_VERSION "1.2.0"

// ===== 全局变量 =====
CustomTags g_PlayerTags[MAXPLAYERS + 1];
// Handle g_hTagCookie;  // 暂未使用
Handle g_hVisibilityCookie;
bool g_bHideTag[MAXPLAYERS + 1];
char g_sConfigPath[PLATFORM_MAX_PATH];

// ===== Forwards =====
Handle g_fTagsUpdated;

// ===== 插件信息 =====
public Plugin myinfo = {
    name = "HexTags Lite",
    author = "东 (Simplified),apples1949",
    description = "轻量级称号插件",
    version = PLUGIN_VERSION,
    url = ""
};

// ===== API =====
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
    RegPluginLibrary("hextags");

    CreateNative("HexTags_SetClientTag", Native_SetClientTag);
    CreateNative("HexTags_ResetClientTag", Native_ResetClientTag);

    g_fTagsUpdated = new GlobalForward("HexTags_OnTagsUpdated", ET_Ignore, Param_Cell);

    return APLRes_Success;
}

// ===== 插件加载 =====
public void OnPluginStart() {
    LoadTranslations("common.phrases");
    LoadTranslations("hextags.phrases");

    // Cookie
    // g_hTagCookie = RegClientCookie("HexTags_Lite_SelectedTag", "Selected Tag ID", CookieAccess_Private);
    g_hVisibilityCookie = RegClientCookie("HexTags_Lite_Visibility", "Show or hide tags", CookieAccess_Private);

    // 命令
    RegAdminCmd("sm_reloadtags", Cmd_ReloadTags, ADMFLAG_GENERIC, "重新加载称号配置");
    RegConsoleCmd("sm_tagslist", Cmd_TagsList, "选择称号");
    RegConsoleCmd("sm_chenghao", Cmd_TagsList, "选择称号");
    RegConsoleCmd("sm_ch", Cmd_TagsList, "选择称号");
    RegConsoleCmd("sm_toggletags", Cmd_ToggleTags, "切换称号显示");

    // 配置路径
    BuildPath(Path_SM, g_sConfigPath, sizeof(g_sConfigPath), "configs/hextags_lite.cfg");

    // 加载配置
    LoadConfig();
}

// ===== 客户端事件 =====
public void OnClientPutInServer(int client) {
    ResetClientTags(client);
}

public void OnClientPostAdminCheck(int client) {
    if (!IsFakeClient(client)) {
        LoadClientTags(client);
    }
}

public void OnClientCookiesCached(int client) {
    if (!IsValidClient(client) || IsFakeClient(client)) return;

    char sValue[32];
    GetClientCookie(client, g_hVisibilityCookie, sValue, sizeof(sValue));
    g_bHideTag[client] = (sValue[0] != '\0' && StringToInt(sValue) == 0);

    LoadClientTags(client);
}

public void OnClientDisconnect(int client) {
    ResetClientTags(client);
}

// ===== 命令处理 =====
public Action Cmd_ReloadTags(int client, int args) {
    LoadConfig();

    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && !IsFakeClient(i)) {
            LoadClientTags(i);
        }
    }

    ReplyToCommand(client, "[HexTags] 配置重新加载完成！");
    return Plugin_Handled;
}

public Action Cmd_TagsList(int client, int args) {
    if (!client) {
        ReplyToCommand(client, "[HexTags] 该命令只能在游戏中使用。");
        return Plugin_Handled;
    }

    ShowTagsMenu(client);
    return Plugin_Handled;
}

public Action Cmd_ToggleTags(int client, int args) {
    if (!IsValidClient(client)) return Plugin_Handled;

    g_bHideTag[client] = !g_bHideTag[client];
    SetClientCookie(client, g_hVisibilityCookie, g_bHideTag[client] ? "0" : "1");

    if (g_bHideTag[client]) {
        ReplyToCommand(client, "[HexTags] 称号已隐藏");
    } else {
        ReplyToCommand(client, "[HexTags] 称号已显示");
        LoadClientTags(client);
    }

    return Plugin_Handled;
}

// ===== 聊天处理 =====
public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs) {
    if (!IsValidClient(client)) {
        return Plugin_Continue;
    }

    char sMessage[MAXLENGTH_MESSAGE];
    strcopy(sMessage, sizeof(sMessage), sArgs);
    StripQuotes(sMessage);

    if (strlen(sMessage) == 0) {
        return Plugin_Continue;
    }

    char sChatCommand[64];
    char sArguments[MAXLENGTH_MESSAGE];

    if (GetChatTriggerCommand(sMessage, sChatCommand, sizeof(sChatCommand), sArguments, sizeof(sArguments))) {
        if (IsVisibleChatCommand(sChatCommand)) {
            if (sMessage[0] == '!' && !g_bHideTag[client]) {
                PrintTaggedChatMessage(client, command, sMessage);
                return Plugin_Handled;
            }

            return Plugin_Continue;
        }

        return Plugin_Handled;
    }

    if (g_bHideTag[client]) {
        return Plugin_Continue;
    }

    PrintTaggedChatMessage(client, command, sMessage);
    return Plugin_Handled;
}

void PrintTaggedChatMessage(int client, const char[] command, const char[] message) {
    // 玩家名字与消息里的颜色标签先剥离，防止注入/叠加
    char sName[MAXLENGTH_NAME];
    GetClientName(client, sName, sizeof(sName));
    StripColorTags(sName, sizeof(sName));

    char sFullName[MAXLENGTH_NAME];
    FormatEx(sFullName, sizeof(sFullName), "%s%s%s",
        g_PlayerTags[client].ChatTag,
        g_PlayerTags[client].NameColor,
        sName);

    char sCleanMessage[MAXLENGTH_MESSAGE];
    strcopy(sCleanMessage, sizeof(sCleanMessage), message);
    StripColorTags(sCleanMessage, sizeof(sCleanMessage));

    char sFullMessage[MAXLENGTH_MESSAGE];
    FormatEx(sFullMessage, sizeof(sFullMessage), "%s%s",
        g_PlayerTags[client].ChatColor,
        sCleanMessage);

    // 配置里的 SayText2 标签（{lightgreen}/{red}/{blue}）预解析为 \x03，
    // 避免与 {teamcolor} 叠加触发 "two team colors" 崩溃；\x03 最终按发言人队伍着色
    ResolveTeamColorTags(sFullName, sizeof(sFullName));
    ResolveTeamColorTags(sFullMessage, sizeof(sFullMessage));

    int team = GetClientTeam(client);
    bool teamChat = StrEqual(command, "say_team");

    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i)) continue;

        int iTeam = GetClientTeam(i);

        // 队内聊天接收者：同队 + 旁观者（本服规则：旁观者可看两队队内聊天）
        if (teamChat && iTeam != team && iTeam != 1) continue;

        // 队伍前缀：公共聊天 *队伍名*，队内聊天 (队伍名)，不论有无称号都显示
        char sStatus[32];
        sStatus[0] = '\0';
        if (teamChat) {
            if (team == 1) {
                FormatEx(sStatus, sizeof(sStatus), "%T", "HexTags_TeamSpectator", i);
            } else if (team == 2) {
                FormatEx(sStatus, sizeof(sStatus), "%T", "HexTags_TeamSurvivor", i);
            } else if (team == 3) {
                FormatEx(sStatus, sizeof(sStatus), "%T", "HexTags_TeamInfected", i);
            }
        } else {
            if (team == 1) {
                FormatEx(sStatus, sizeof(sStatus), "%T", "HexTags_ChatSpectator", i);
            } else if (team == 2) {
                FormatEx(sStatus, sizeof(sStatus), "%T", "HexTags_ChatSurvivor", i);
            } else if (team == 3) {
                FormatEx(sStatus, sizeof(sStatus), "%T", "HexTags_ChatInfected", i);
            }
        }

        // CPrintToChatEx(author=发言人)：{teamcolor} 按发言人队伍给前缀着色。
        // 配置的 SayText2 标签已被 ResolveTeamColorTags 解析掉，不会触发
        // "two team colors" 崩溃
        CPrintToChatEx(i, client, "{teamcolor}%s{default}%s{default} : %s", sStatus, sFullName, sFullMessage);
    }
}

// 移除颜色标签（colors.inc 会把它们解析成颜色码）。玩家消息/名字里若包含
// {lightgreen}/{red}/{blue}/{teamcolor} 等标签，可能与称号颜色叠加成
// "两个队伍色" 导致 CFormat 抛异常，这里统一剥离，颜色只由配置控制。
void StripColorTags(char[] buffer, int maxlength) {
    static const char sColorTags[][] = {
        "{default}", "{darkred}", "{green}", "{lightgreen}", "{red}", "{blue}",
        "{olive}", "{lime}", "{lightred}", "{purple}", "{grey}", "{orange}", "{teamcolor}"
    };

    for (int i = 0; i < sizeof(sColorTags); i++) {
        ReplaceString(buffer, maxlength, sColorTags[i], "", false);
    }
}

// 把配置中的 SayText2 队伍色标签（{lightgreen}/{red}/{blue}）解析成 \x03。
// colors.inc 中这些标签需要 SayText2 author 才能着色，且同一条消息里与
// {teamcolor} 共存会抛 "two team colors" 异常；统一转成 \x03 后，
// 由 CPrintToChatEx 的 author（发言人）决定最终队伍色。
void ResolveTeamColorTags(char[] buffer, int maxlength) {
    ReplaceString(buffer, maxlength, "{lightgreen}", "\x03", false);
    ReplaceString(buffer, maxlength, "{red}", "\x03", false);
    ReplaceString(buffer, maxlength, "{blue}", "\x03", false);
}

// ===== 配置加载 =====
void LoadConfig() {
    KeyValues kv = new KeyValues("HexTags");

    if (!kv.ImportFromFile(g_sConfigPath)) {
        LogError("[HexTags] 无法加载配置文件: %s", g_sConfigPath);
        delete kv;
        return;
    }

    delete kv;
}

void LoadClientTags(int client) {
    if (!IsValidClient(client) || IsFakeClient(client) || g_bHideTag[client]) return;

    ResetClientTags(client);

    KeyValues kv = new KeyValues("HexTags");
    if (!kv.ImportFromFile(g_sConfigPath)) {
        delete kv;
        return;
    }

    // 解析配置
    if (kv.GotoFirstSubKey()) {
        do {
            char sSectionName[64];
            kv.GetSectionName(sSectionName, sizeof(sSectionName));

            if (CheckSelector(client, sSectionName, kv)) {
                // 读取称号数据
                kv.GetString("TagName", g_PlayerTags[client].TagName, 32, sSectionName);
                kv.GetString("ScoreTag", g_PlayerTags[client].ScoreTag, 32, "");
                kv.GetString("ChatTag", g_PlayerTags[client].ChatTag, MAXLENGTH_NAME, "");
                kv.GetString("ChatColor", g_PlayerTags[client].ChatColor, 32, "{default}");
                kv.GetString("NameColor", g_PlayerTags[client].NameColor, 32, "{teamcolor}");
                g_PlayerTags[client].ForceTag = (kv.GetNum("ForceTag", 1) == 1);

                // 处理变量替换
                ProcessTagVariables(client);

                break; // 只应用第一个匹配的
            }
        } while (kv.GotoNextKey());
    }

    delete kv;

    // 触发Forward
    Call_StartForward(g_fTagsUpdated);
    Call_PushCell(client);
    Call_Finish();
}

bool CheckSelector(int client, const char[] selector, KeyValues kv) {
    // 注意：kv参数保留用于未来扩展
    #pragma unused kv

    // 默认选择器
    if (StrEqual(selector, "default", false)) {
        return true;
    }

    // 人类玩家
    if (StrEqual(selector, "human", false) && !IsFakeClient(client)) {
        return true;
    }

    // Bot
    if (StrEqual(selector, "bot", false) && IsFakeClient(client)) {
        return true;
    }

    // SteamID
    if (strlen(selector) > 11 && StrContains(selector, "STEAM_", false) == 0) {
        char steamid[32];
        if (!GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid))) {
            return false;
        }

        if (StrEqual(steamid, selector)) {
            return true;
        }

        // 尝试反转 STEAM_0/STEAM_1
        steamid[6] = (steamid[6] == '1') ? '0' : '1';
        if (StrEqual(steamid, selector)) {
            return true;
        }
    }

    // 管理员标志 (单个字符)
    if (strlen(selector) == 1) {
        AdminId admin = GetUserAdmin(client);
        if (admin != INVALID_ADMIN_ID) {
            AdminFlag flag;
            if (FindFlagByChar(selector[0], flag) && admin.HasFlag(flag)) {
                return true;
            }
        }
    }

    // 管理员组 (@开头)
    if (selector[0] == '@') {
        AdminId admin = GetUserAdmin(client);
        if (admin != INVALID_ADMIN_ID) {
            char sGroup[32];
            GroupId group = admin.GetGroup(0, sGroup, sizeof(sGroup));
            if (group != INVALID_GROUP_ID && StrEqual(selector[1], sGroup)) {
                return true;
            }
        }
    }

    return false;
}

void ProcessTagVariables(int client) {
    // 时间
    char sTime[16];
    FormatTime(sTime, sizeof(sTime), "%H:%M");
    ReplaceString(g_PlayerTags[client].ScoreTag, 32, "{time}", sTime);
    ReplaceString(g_PlayerTags[client].ChatTag, MAXLENGTH_NAME, "{time}", sTime);
}

void ResetClientTags(int client) {
    g_PlayerTags[client].ScoreTag[0] = '\0';
    g_PlayerTags[client].ChatTag[0] = '\0';
    strcopy(g_PlayerTags[client].ChatColor, 32, "{default}");
    strcopy(g_PlayerTags[client].NameColor, 32, "{teamcolor}");
    g_PlayerTags[client].ForceTag = true;
    g_PlayerTags[client].TagName[0] = '\0';
    g_PlayerTags[client].SectionId = 0;
    g_bHideTag[client] = false;
}

// ===== 菜单 =====
void ShowTagsMenu(int client) {
    Menu menu = new Menu(TagsMenuHandler);
    menu.SetTitle("选择你的称号:");

    KeyValues kv = new KeyValues("HexTags");
    if (!kv.ImportFromFile(g_sConfigPath)) {
        delete kv;
        CPrintToChat(client, "{red}[HexTags] {default}配置文件加载失败");
        return;
    }

    int count = 0;
    if (kv.GotoFirstSubKey()) {
        do {
            char sSectionName[64];
            kv.GetSectionName(sSectionName, sizeof(sSectionName));

            if (CheckSelector(client, sSectionName, kv)) {
                char sTagName[64];
                kv.GetString("TagName", sTagName, sizeof(sTagName), sSectionName);

                char sInfo[8];
                IntToString(count, sInfo, sizeof(sInfo));
                menu.AddItem(sInfo, sTagName);
                count++;
            }
        } while (kv.GotoNextKey());
    }

    delete kv;

    if (count == 0) {
        CPrintToChat(client, "{red}[HexTags] {default}没有可用的称号");
        delete menu;
        return;
    }

    menu.ExitButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int TagsMenuHandler(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_Select) {
        LoadClientTags(param1);
        CPrintToChat(param1, "{green}[HexTags] {default}称号已更新！");
    } else if (action == MenuAction_End) {
        delete menu;
    }
    return 0;
}

// ===== Native实现 =====
public int Native_SetClientTag(Handle plugin, int numParams) {
    int client = GetNativeCell(1);
    if (!IsValidClient(client)) {
        return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client %d", client);
    }

    int tagType = GetNativeCell(2);
    char sTag[MAXLENGTH_NAME];
    GetNativeString(3, sTag, sizeof(sTag));

    switch (tagType) {
        case 0: strcopy(g_PlayerTags[client].ScoreTag, 32, sTag);           // ScoreTag
        case 1: strcopy(g_PlayerTags[client].ChatTag, MAXLENGTH_NAME, sTag); // ChatTag
        case 2: strcopy(g_PlayerTags[client].ChatColor, 32, sTag);          // ChatColor
        case 3: strcopy(g_PlayerTags[client].NameColor, 32, sTag);          // NameColor
    }

    return 0;
}

public int Native_ResetClientTag(Handle plugin, int numParams) {
    int client = GetNativeCell(1);
    if (!IsValidClient(client)) {
        return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client %d", client);
    }

    LoadClientTags(client);
    return 0;
}

// ===== 辅助函数 =====
bool IsValidClient(int client) {
    return (client > 0 && client <= MaxClients && IsClientConnected(client) && IsClientInGame(client));
}

// 提取聊天触发器命令，例如 !rygive -> rygive，/sm_ban -> sm_ban。
bool GetChatTriggerCommand(const char[] message, char[] command, int commandLen, char[] arguments, int argumentsLen) {
    command[0] = '\0';
    arguments[0] = '\0';

    if (message[0] != '!' && message[0] != '/') {
        return false;
    }

    char body[MAXLENGTH_MESSAGE];
    strcopy(body, sizeof(body), message[1]);
    TrimString(body);

    if (body[0] == '\0') {
        return false;
    }

    int next = BreakString(body, command, commandLen);
    TrimString(command);

    if (command[0] == '\0') {
        return false;
    }

    if (next != -1) {
        strcopy(arguments, argumentsLen, body[next]);
        TrimString(arguments);
    }

    return true;
}

// 白名单命令允许像普通聊天一样显示，其余 ! / 命令只执行不显示。
bool IsVisibleChatCommand(const char[] command) {
    char normalized[64];

    if (StrContains(command, "sm_", false) == 0) {
        strcopy(normalized, sizeof(normalized), command[3]);
    } else {
        strcopy(normalized, sizeof(normalized), command);
    }

    for (int i = 0; normalized[i] != '\0'; i++) {
        normalized[i] = CharToLower(normalized[i]);
    }

    static const char allowedCommands[][] = {
        "vote",
        "rtv",
        "nominate",
        "revote"
    };

    for (int i = 0; i < sizeof(allowedCommands); i++) {
        if (StrEqual(normalized, allowedCommands[i], false)) {
            return true;
        }
    }

    return false;
}
