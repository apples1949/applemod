#pragma newdecls required
#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <protobuf>
#include <multicolors>
#include <geoip>

#define SOUNDFILE_PATH_LEN 256
#define MSG_MAXLEN 512

// ============ 内置消息模板（原 cannounce_settings.txt 文案硬编码） ============
// 加入：2=国家+地区/城市，1=仅有国家，0=无地理信息
#define JOIN_MSG_FULL "来自{GREEN}{PLAYERCOUNTRY}{DEFAULT}({LIGHTGREEN}{PLAYERCOUNTRYSHORT3}{DEFAULT} ){LIGHTGREEN}{PLAYERREGION} {PLAYERCITY}的{DEFAULT}[{GREEN}{PLAYERNAME}{DEFAULT}] 加入游戏，IP：[{GREEN}{PLAYERIP}{DEFAULT}]"
#define JOIN_MSG_COUNTRY "来自{GREEN}{PLAYERCOUNTRY}{DEFAULT}的{DEFAULT}[{GREEN}{PLAYERNAME}{DEFAULT}] 加入游戏"
#define JOIN_MSG_MINIMAL "来自{GREEN}{PLAYERCOUNTRY}{DEFAULT} {LIGHTGREEN}{PLAYERREGION}{DEFAULT}的{DEFAULT}[{GREEN}{PLAYERNAME}{DEFAULT}] 加入游戏"
// 离开：有地区/城市用完整模板，否则用简版；原因始终显示（已翻译为中文）
#define DISC_MSG_FULL "来自{LIGHTGREEN}{PLAYERREGION} {PLAYERCITY}{DEFAULT}的[{GREEN}{PLAYERNAME}{DEFAULT}]离开游戏，原因为: {GREEN}{DISC_REASON}"
#define DISC_MSG_NOGEO "[{GREEN}{PLAYERNAME}{DEFAULT}]离开游戏，原因为: {GREEN}{DISC_REASON}"

// ============ 声音相关（沿用 cannounce/joinmsg.sp 的配置） ============
ConVar g_CvarPlaySound;
ConVar g_CvarPlaySoundFile;
ConVar g_CvarPlayDiscSound;
ConVar g_CvarPlayDiscSoundFile;
ConVar g_CvarMapStartNoSound;

bool g_bNoSoundPeriod;

// geoip 查询固定使用的中文语言（简体中文，OnPluginStart 时解析）
int g_iChineseLang = -1;

// ============ 客户端归属地信息 ============

// 每个客户端的 geo 信息（供 {PLAYERCOUNTRY} {PLAYERREGION} {PLAYERCITY} 等占位符使用）
enum struct ClientGeo {
    char countryName[64];
    char countryCode[8];
    char region[64];
    char city[64];
}

ClientGeo g_ClientGeo[MAXPLAYERS+1];
char g_ClientIPs[MAXPLAYERS+1][36];

public Plugin myinfo = {
    name = "Connect info",
    author = "HoongDou apples1949",
    description = "Print SteamID, IP and geo location (geoip) on player connect/disconnect",
    version = "2.3",
    url = ""
};

public void OnPluginStart() {
    HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Pre);
    
    // 显示在场所有玩家归属地
    RegConsoleCmd("sm_ip", Command_ShowGeo, "显示在场所有玩家的归属地");
    RegConsoleCmd("sm_geo", Command_ShowGeo, "显示在场所有玩家的归属地");
    
    // 查询指定 IP 的归属地（客户端与服务端控制台均可用）
    RegConsoleCmd("sm_tip", Command_QueryIp, "查询指定 IP 的归属地，用法: sm_tip <IP>");
    
    // cannounce 声音配置
    SetupJoinMsgSounds();
    
    // 直接指定中文语言：geoip native 只能通过 client 参数指定语言，
    // 这里解析简体中文语言号，配合 GeoLangSource() 强制返回中文地名
    g_iChineseLang = GetLanguageByCode("chi");
    if (g_iChineseLang == -1) {
        LogError("[ConnectInfo] SourceMod 语言列表中未找到简体中文(chi)，地名将回退为服务器默认语言");
    }
    
    // AutoExecConfig 必须在所有 CreateConVar 之后，确保生成的 cfg 包含全部 cvar
    AutoExecConfig(true, "connectinfo");
}

// 返回用于 geoip 查询的语言来源参数，保证返回中文地名。
// geoip native 的语言只能通过第 4 个 client 参数间接指定（-1=英文 / 0=服务器语言 / >=1=玩家语言），
// 没有直接传语言代码的参数，因此：
//   1) 服务器语言已是中文 → 用 LANG_SERVER
//   2) 服务器语言不是中文 → 借用一名中文客户端（不依赖 core.cfg 设置）
//   3) 没有中文语言/客户端 → 回退 LANG_SERVER
int GeoLangSource() {
    if (g_iChineseLang == -1) {
        return LANG_SERVER;
    }
    
    if (GetServerLanguage() == g_iChineseLang) {
        return LANG_SERVER;
    }
    
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && GetClientLanguage(i) == g_iChineseLang) {
            return i;
        }
    }
    
    return LANG_SERVER;
}

public void OnMapStart() {
    // 预缓存并设置声音文件下载（声音缓存）
    LoadSoundFilesAll();
    
    // 地图开始后一段时间内忽略加入声音
    OnMapStart_JoinMsg();
}

// 玩家完成授权进入游戏：geoip 查询归属地 + 播放加入声音 + 播报
public void OnClientPostAdminCheck(int client) {
    if (IsFakeClient(client)) {
        return;
    }
    
    // 记录 IP 供 {PLAYERIP} 使用
    char ipAddress[32];
    GetClientIP(client, ipAddress, sizeof(ipAddress));
    strcopy(g_ClientIPs[client], sizeof(g_ClientIPs[]), ipAddress);
    
    // 播放加入声音（与 cannounce 播放时机一致）
    PlayJoinSound();
    
    // geoip 本地库查询 + 中文对照翻译
    LookupGeoip(client);
    
    // 播报加入消息
    PrintJoinMessage(client);
}

public void Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast) {
    SetEventBroadcast(event, true);
    
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (client <= 0 || client > MaxClients || IsFakeClient(client)) {
        return;
    }
    
    // 播放断开声音
    PlayDisconnectSound();
    
    char steamId[32];
    GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));
    
    if (StrEqual(steamId, "BOT", false)) {
        return;
    }
    
    char reason[128];
    GetEventString(event, "reason", reason, sizeof(reason));
    // 去除换行，替换为空格（与 cannounce 一致）
    ReplaceString(reason, sizeof(reason), "\n", " ");
    
    // 原因翻译为中文
    char reasonZh[128];
    GetReasonInChinese(reason, reasonZh, sizeof(reasonZh));
    
    // 内置 cannounce 风格离开消息（有地区/城市用完整模板，否则用简版），原因始终显示
    char message[MSG_MAXLEN];
    if (GetGeoLevel(client) >= 2) {
        strcopy(message, sizeof(message), DISC_MSG_FULL);
    } else {
        strcopy(message, sizeof(message), DISC_MSG_NOGEO);
    }
    ResolvePlaceholders(message, sizeof(message), client, reasonZh);
    
    // 用 multicolors（L4D1/2 修复版）输出，标签 {GREEN} 等自动按 L4D2 色码渲染
    CPrintToChatAll("%s", message);
    
    LogMessage("[Connect Info] Player %s <%s> left the game: %s", name, steamId, reason);
}

public void OnClientDisconnect(int client) {
    if (!IsFakeClient(client)) {
        g_ClientIPs[client][0] = '\0';
        g_ClientGeo[client].countryName[0] = '\0';
        g_ClientGeo[client].countryCode[0] = '\0';
        g_ClientGeo[client].region[0] = '\0';
        g_ClientGeo[client].city[0] = '\0';
    }
}

// ==================== 消息输出 ====================

void PrintJoinMessage(int client) {
    if (client <= 0 || client > MaxClients || !IsClientInGame(client)) {
        return;
    }
    
    char message[MSG_MAXLEN];
    int geoLevel = GetGeoLevel(client);
    if (geoLevel >= 2) {
        strcopy(message, sizeof(message), JOIN_MSG_FULL);
    } else if (geoLevel == 1) {
        strcopy(message, sizeof(message), JOIN_MSG_COUNTRY);
    } else {
        strcopy(message, sizeof(message), JOIN_MSG_MINIMAL);
    }
    ResolvePlaceholders(message, sizeof(message), client);
    
    // 用 multicolors（L4D1/2 修复版）输出，标签 {GREEN} 等自动按 L4D2 色码渲染
    CPrintToChatAll("%s", message);
}

// 地理信息分级：2=国家+地区/城市，1=仅有国家，0=无地理信息
int GetGeoLevel(int client) {
    if (g_ClientGeo[client].region[0] != '\0' || g_ClientGeo[client].city[0] != '\0') {
        return 2;
    }
    if (g_ClientGeo[client].countryName[0] != '\0' || g_ClientGeo[client].countryCode[0] != '\0') {
        return 1;
    }
    return 0;
}

// sm_ip / sm_geo：显示在场所有玩家的归属地（数据缺失时现场查询补齐）
public Action Command_ShowGeo(int client, int args) {
    int count = 0;
    
    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i) || IsFakeClient(i)) {
            continue;
        }
        
        // 没有数据时现场用 geoip 查询
        if (GetGeoLevel(i) == 0) {
            char ipAddress[32];
            GetClientIP(i, ipAddress, sizeof(ipAddress));
            strcopy(g_ClientIPs[i], sizeof(g_ClientIPs[]), ipAddress);
            LookupGeoip(i);
        }
        
        char ip[32];
        GetClientIP(i, ip, sizeof(ip));
        
        char geo[192];
        FormatGeoDisplay(g_ClientGeo[i].countryName, g_ClientGeo[i].countryCode,
                         g_ClientGeo[i].region, g_ClientGeo[i].city, geo, sizeof(geo));
        
        count++;
        if (client == 0) {
            PrintToServer("%d. %N (IP: %s) - %s", count, i, ip, geo);
        } else {
            CPrintToChat(client, "{green}%d. {lightgreen}%N{default} (IP: {green}%s{default}) - {lightgreen}%s", count, i, ip, geo);
        }
    }
    
    if (client == 0) {
        PrintToServer("当前在场玩家: %d 名", count);
    } else {
        CPrintToChat(client, "{default}当前在场玩家: %d 名", count);
    }
    
    return Plugin_Handled;
}

// sm_tip <IP>：查询指定 IP 的归属地（客户端与服务端控制台均可用）
public Action Command_QueryIp(int client, int args) {
    if (args < 1) {
        ReplyToCommand(client, "[ConnectInfo] 用法: sm_tip <IP>    例如: sm_tip 223.5.5.5");
        return Plugin_Handled;
    }
    
    char ip[64];
    GetCmdArg(1, ip, sizeof(ip));
    TrimString(ip);
    
    if (!IsValidIpString(ip)) {
        ReplyToCommand(client, "[ConnectInfo] IP 格式无效: %s", ip);
        return Plugin_Handled;
    }
    
    char geo[192];
    // 语言固定为服务器语言（中文）
    QueryGeoDisplay(ip, geo, sizeof(geo));
    
    if (client == 0) {
        PrintToServer("[ConnectInfo] %s - %s", ip, geo);
    } else {
        CPrintToChat(client, "{default}[ConnectInfo] {green}%s{default} - {lightgreen}%s", ip, geo);
    }
    
    return Plugin_Handled;
}

// 组装归属地显示串：国家(代码) 地区 城市；缺失部分自动省略，全部缺失显示"未知国家"
// note 非空时，在"只有国家、无省市"的情况下附加该诊断标注（sm_tip 用；sm_ip 传空保持简洁）
void FormatGeoDisplay(const char[] country, const char[] code, const char[] region, const char[] city, char[] out, int maxlen, const char[] note = "") {
    bool hasCountry = !IsGeoFieldEmpty(country) || !IsGeoFieldEmpty(code);
    bool hasRegion = !IsGeoFieldEmpty(region);
    bool hasCity = !IsGeoFieldEmpty(city);
    
    // 完全查不到：区分"库中无记录"与普通未知
    if (!hasCountry && !hasRegion && !hasCity) {
        strcopy(out, maxlen, "未知国家");
        if (note[0] != '\0') {
            StrCat(out, maxlen, " [库中无记录]");
        }
        return;
    }
    
    // 国家部分：有名称则 "名称(代码)"，只有代码则只显示代码
    char countryPart[96];
    if (!IsGeoFieldEmpty(country) && !IsGeoFieldEmpty(code)) {
        Format(countryPart, sizeof(countryPart), "%s(%s)", country, code);
    } else if (!IsGeoFieldEmpty(country)) {
        strcopy(countryPart, sizeof(countryPart), country);
    } else {
        strcopy(countryPart, sizeof(countryPart), code);
    }
    
    if (hasRegion && hasCity) {
        Format(out, maxlen, "%s %s %s", countryPart, region, city);
    } else if (hasRegion) {
        Format(out, maxlen, "%s %s", countryPart, region);
    } else if (hasCity) {
        Format(out, maxlen, "%s %s", countryPart, city);
    } else {
        strcopy(out, maxlen, countryPart);
    }
    
    // 只有国家、库里没有省市：附加诊断标注
    if (note[0] != '\0' && !hasRegion && !hasCity) {
        StrCat(out, maxlen, " ");
        StrCat(out, maxlen, note);
    }
}

// 查询任意 IP 的归属地并组装为显示串（geoip 本地库）；带数据诊断标注
// 语言由 GeoLangSource() 指定为中文
void QueryGeoDisplay(const char[] ip, char[] out, int maxlen) {
    // geoip 扩展未加载
    if (GetFeatureStatus(FeatureType_Native, "GeoipCountry") != FeatureStatus_Available) {
        strcopy(out, maxlen, "geoip 扩展未加载");
        return;
    }
    
    bool hasCountryExNative = (GetFeatureStatus(FeatureType_Native, "GeoipCountryEx") == FeatureStatus_Available);
    bool hasCodeNative = (GetFeatureStatus(FeatureType_Native, "GeoipCode2") == FeatureStatus_Available);
    bool hasRegionNative = (GetFeatureStatus(FeatureType_Native, "GeoipRegion") == FeatureStatus_Available);
    bool hasCityNative = (GetFeatureStatus(FeatureType_Native, "GeoipCity") == FeatureStatus_Available);
    
    int langSrc = GeoLangSource();
    char country[64] = "", code[3] = "", region[64] = "", city[64] = "";
    
    // 指定中文语言 → 返回中文地名（库内含 zh-CN）
    if (hasCountryExNative) {
        GeoipCountryEx(ip, country, sizeof(country), langSrc);
    } else {
        GeoipCountry(ip, country, sizeof(country));
    }
    if (hasCodeNative) {
        GeoipCode2(ip, code);
    }
    if (hasRegionNative) {
        GeoipRegion(ip, region, sizeof(region), langSrc);
    }
    if (hasCityNative) {
        GeoipCity(ip, city, sizeof(city), langSrc);
    }
    
    // 诊断标注：区分"扩展不支持"与"库里没有数据"
    char note[64] = "";
    if (!hasRegionNative && !hasCityNative) {
        strcopy(note, sizeof(note), "[geoip 扩展不支持城市查询]");
    } else if (IsGeoFieldEmpty(region) && IsGeoFieldEmpty(city)) {
        strcopy(note, sizeof(note), "[库中无省市数据]");
    }
    
    FormatGeoDisplay(country, code, region, city, out, maxlen, note);
}

// 校验 IP 字符串（IPv4 四段 0-255 / IPv6 含冒号），避免非法输入送进 geoip
bool IsValidIpString(const char[] ip) {
    int len = strlen(ip);
    if (len < 3 || len > 45) {
        return false;
    }
    
    // 字符集：仅允许 0-9 a-f A-F . :
    for (int i = 0; i < len; i++) {
        char c = ip[i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') || c == '.' || c == ':')) {
            return false;
        }
    }
    
    // IPv6：含冒号即视为合法形式
    if (StrContains(ip, ":") != -1) {
        return true;
    }
    
    // IPv4：必须四段、每段 1-3 位纯数字且 0-255
    char parts[4][8];
    if (ExplodeString(ip, ".", parts, 4, 8) != 4) {
        return false;
    }
    
    for (int i = 0; i < 4; i++) {
        int partLen = strlen(parts[i]);
        if (partLen < 1 || partLen > 3) {
            return false;
        }
        for (int j = 0; j < partLen; j++) {
            if (parts[i][j] < '0' || parts[i][j] > '9') {
                return false;
            }
        }
        if (StringToInt(parts[i]) > 255) {
            return false;
        }
    }
    
    return true;
}

// 替换消息模板占位符
void ResolvePlaceholders(char[] message, int maxlen, int client, const char[] reason = "") {
    char buffer[128];
    bool clientValid = (client > 0 && client <= MaxClients && IsClientInGame(client));
    
    if (StrContains(message, "{PLAYERNAME}") != -1) {
        if (clientValid) {
            GetClientName(client, buffer, sizeof(buffer));
        } else {
            strcopy(buffer, sizeof(buffer), "Unknown");
        }
        ReplaceString(message, maxlen, "{PLAYERNAME}", buffer);
    }
    
    if (StrContains(message, "{STEAMID}") != -1) {
        if (clientValid) {
            GetClientAuthId(client, AuthId_Steam2, buffer, sizeof(buffer));
        } else {
            strcopy(buffer, sizeof(buffer), "Unknown");
        }
        ReplaceString(message, maxlen, "{STEAMID}", buffer);
    }
    
    if (StrContains(message, "{PLAYERCOUNTRY}") != -1) {
        GetCountryName(client, buffer, sizeof(buffer));
        ReplaceString(message, maxlen, "{PLAYERCOUNTRY}", buffer);
    }
    
    if (StrContains(message, "{PLAYERCOUNTRYSHORT}") != -1) {
        GetCountryCode(client, buffer, sizeof(buffer));
        ReplaceString(message, maxlen, "{PLAYERCOUNTRYSHORT}", buffer);
    }
    
    if (StrContains(message, "{PLAYERCOUNTRYSHORT3}") != -1) {
        GetCountryCode(client, buffer, sizeof(buffer));
        ReplaceString(message, maxlen, "{PLAYERCOUNTRYSHORT3}", buffer);
    }
    
    if (StrContains(message, "{PLAYERCITY}") != -1) {
        GetCity(client, buffer, sizeof(buffer));
        ReplaceString(message, maxlen, "{PLAYERCITY}", buffer);
    }
    
    if (StrContains(message, "{PLAYERREGION}") != -1) {
        GetRegion(client, buffer, sizeof(buffer));
        ReplaceString(message, maxlen, "{PLAYERREGION}", buffer);
    }
    
    if (StrContains(message, "{PLAYERIP}") != -1) {
        if (g_ClientIPs[client][0] != '\0') {
            strcopy(buffer, sizeof(buffer), g_ClientIPs[client]);
        } else {
            strcopy(buffer, sizeof(buffer), "Unknown");
        }
        ReplaceString(message, maxlen, "{PLAYERIP}", buffer);
    }
    
    if (StrContains(message, "{PLAYERTYPE}") != -1) {
        ReplaceString(message, maxlen, "{PLAYERTYPE}", "");
    }
    
    if (StrContains(message, "{DISC_REASON}") != -1) {
        ReplaceString(message, maxlen, "{DISC_REASON}", reason);
    }
}

// ==================== geo 信息取值（空值回退为中文） ====================

void GetCountryName(int client, char[] buffer, int maxlen) {
    if (!IsGeoFieldEmpty(g_ClientGeo[client].countryName)) {
        strcopy(buffer, maxlen, g_ClientGeo[client].countryName);
    } else if (!IsGeoFieldEmpty(g_ClientGeo[client].countryCode)) {
        strcopy(buffer, maxlen, g_ClientGeo[client].countryCode);
    } else {
        strcopy(buffer, maxlen, "未知国家");
    }
}

void GetCountryCode(int client, char[] buffer, int maxlen) {
    if (!IsGeoFieldEmpty(g_ClientGeo[client].countryCode)) {
        strcopy(buffer, maxlen, g_ClientGeo[client].countryCode);
    } else {
        strcopy(buffer, maxlen, "未知国家");
    }
}

void GetCity(int client, char[] buffer, int maxlen) {
    if (!IsGeoFieldEmpty(g_ClientGeo[client].city)) {
        strcopy(buffer, maxlen, g_ClientGeo[client].city);
    } else {
        strcopy(buffer, maxlen, "未知地区");
    }
}

void GetRegion(int client, char[] buffer, int maxlen) {
    if (!IsGeoFieldEmpty(g_ClientGeo[client].region)) {
        strcopy(buffer, maxlen, g_ClientGeo[client].region);
    } else {
        strcopy(buffer, maxlen, "未知地区");
    }
}

// 判断 geo 字段是否为空（空字符串、Unknown、null 均视为空）
bool IsGeoFieldEmpty(const char[] field) {
    return field[0] == '\0' || StrEqual(field, "Unknown", false) || StrEqual(field, "null", false);
}

// ==================== geoip 本地库查询 ====================

// 用 geoip 本地库（GeoIP.ext + GeoLite2 Country/City）查询 IP 归属地
void LookupGeoip(int client) {
    if (client <= 0 || client > MaxClients || g_ClientIPs[client][0] == '\0') {
        return;
    }
    
    // geoip 扩展未加载时跳过
    if (GetFeatureStatus(FeatureType_Native, "GeoipCountry") != FeatureStatus_Available) {
        return;
    }
    
    char ip[36];
    strcopy(ip, sizeof(ip), g_ClientIPs[client]);
    
    // 所有 geoip native 都是可选的，逐个检查存在性，避免扩展版本不支持时调用抛异常。
    // 语言参数由 GeoLangSource() 指定为中文
    int langSrc = GeoLangSource();
    char country[64] = "", code[3] = "", region[64] = "", city[64] = "";
    
    if (GetFeatureStatus(FeatureType_Native, "GeoipCountryEx") == FeatureStatus_Available) {
        GeoipCountryEx(ip, country, sizeof(country), langSrc);
    } else {
        GeoipCountry(ip, country, sizeof(country));
    }
    
    if (GetFeatureStatus(FeatureType_Native, "GeoipCode2") == FeatureStatus_Available) {
        GeoipCode2(ip, code);
    }
    if (GetFeatureStatus(FeatureType_Native, "GeoipRegion") == FeatureStatus_Available) {
        GeoipRegion(ip, region, sizeof(region), langSrc);
    }
    // 城市级查询需要扩展支持 + configs/geoip/GeoLite2-City.mmdb 存在
    if (GetFeatureStatus(FeatureType_Native, "GeoipCity") == FeatureStatus_Available) {
        GeoipCity(ip, city, sizeof(city), langSrc);
    }
    
    strcopy(g_ClientGeo[client].countryName, sizeof(g_ClientGeo[].countryName), country);
    strcopy(g_ClientGeo[client].countryCode, sizeof(g_ClientGeo[].countryCode), code);
    strcopy(g_ClientGeo[client].region, sizeof(g_ClientGeo[].region), region);
    strcopy(g_ClientGeo[client].city, sizeof(g_ClientGeo[].city), city);
}

// 将常见的离开原因翻译为中文；无法识别时保留原文，空原因显示"未知原因"
void GetReasonInChinese(const char[] rawReason, char[] buffer, int maxlen) {
    if (StrEqual(rawReason, "Disconnect by user.", false)) {
        strcopy(buffer, maxlen, "玩家主动离开");
    } else if (StrContains(rawReason, "Connection lost", false) != -1) {
        strcopy(buffer, maxlen, "网络连接中断");
    } else if (StrContains(rawReason, "timed out", false) != -1) {
        strcopy(buffer, maxlen, "连接超时");
    } else if (StrContains(rawReason, "No Steam logon", false) != -1) {
        strcopy(buffer, maxlen, "未通过 Steam 验证");
    } else if (StrContains(rawReason, "banned", false) != -1) {
        strcopy(buffer, maxlen, "被封禁");
    } else if (StrContains(rawReason, "kicked", false) != -1) {
        int idx = StrContains(rawReason, ":", false);
        if (idx != -1) {
            char custom[96];
            strcopy(custom, sizeof(custom), rawReason[idx + 1]);
            TrimString(custom);
            Format(buffer, maxlen, "被踢出：%s", custom);
        } else {
            strcopy(buffer, maxlen, "被管理员踢出");
        }
    } else if (StrContains(rawReason, "Server shutting down", false) != -1) {
        strcopy(buffer, maxlen, "服务器关闭");
    } else if (strlen(rawReason) == 0) {
        strcopy(buffer, maxlen, "未知原因");
    } else {
        strcopy(buffer, maxlen, rawReason);
    }
}

// ==================== 声音系统（移植自 cannounce/joinmsg.sp） ====================

void SetupJoinMsgSounds() {
    g_CvarPlaySound = CreateConVar("sm_ca_playsound", "1", "玩家连接时播放指定的 (sm_ca_playsoundfile) 声音");
    g_CvarPlaySoundFile = CreateConVar("sm_ca_playsoundfile", "ambient\\alarms\\klaxon1.wav", "sm_ca_playsound = 1 时玩家连接播放的声音");
    
    g_CvarPlayDiscSound = CreateConVar("sm_ca_playdiscsound", "0", "玩家断开连接时播放指定的 (sm_ca_playdiscsoundfile) 声音");
    g_CvarPlayDiscSoundFile = CreateConVar("sm_ca_playdiscsoundfile", "weapons\\cguard\\charging.wav", "sm_ca_playdiscsound = 1 时玩家断开连接播放的声音");
    
    g_CvarMapStartNoSound = CreateConVar("sm_ca_mapstartnosound", "30.0", "地图加载后忽略所有玩家加入声音的时间");
}

void OnMapStart_JoinMsg() {
    float waitPeriod;
    
    g_bNoSoundPeriod = false;
    
    waitPeriod = g_CvarMapStartNoSound.FloatValue;
    
    if (waitPeriod > 0) {
        g_bNoSoundPeriod = true;
        CreateTimer(waitPeriod, Timer_MapStartNoSound);
    }
}

void PlayJoinSound() {
    char soundfile[SOUNDFILE_PATH_LEN];
    
    if (g_CvarPlaySound.BoolValue) {
        g_CvarPlaySoundFile.GetString(soundfile, sizeof(soundfile));
        
        if (strlen(soundfile) > 0 && !g_bNoSoundPeriod) {
            EmitSoundToAll(soundfile);
        }
    }
}

void PlayDisconnectSound() {
    char soundfile[SOUNDFILE_PATH_LEN];
    
    if (g_CvarPlayDiscSound.BoolValue) {
        g_CvarPlayDiscSoundFile.GetString(soundfile, sizeof(soundfile));
        
        if (strlen(soundfile) > 0) {
            EmitSoundToAll(soundfile);
        }
    }
}

// 声音缓存：下载表 + 预缓存（加入/断开声音）
void LoadSoundFilesAll() {
    char c_soundFile[SOUNDFILE_PATH_LEN];
    char c_soundFileFullPath[SOUNDFILE_PATH_LEN + 6];
    
    char dc_soundFile[SOUNDFILE_PATH_LEN];
    char dc_soundFileFullPath[SOUNDFILE_PATH_LEN + 6];
    
    // download and cache connect sound
    if (g_CvarPlaySound.BoolValue) {
        g_CvarPlaySoundFile.GetString(c_soundFile, sizeof(c_soundFile));
        Format(c_soundFileFullPath, sizeof(c_soundFileFullPath), "sound/%s", c_soundFile);
        
        if (FileExists(c_soundFileFullPath)) {
            AddFileToDownloadsTable(c_soundFileFullPath);
            
            PrecacheSound(c_soundFile);
        }
    }
    
    // cache disconnect sound
    if (g_CvarPlayDiscSound.BoolValue) {
        g_CvarPlayDiscSoundFile.GetString(dc_soundFile, sizeof(dc_soundFile));
        Format(dc_soundFileFullPath, sizeof(dc_soundFileFullPath), "sound/%s", dc_soundFile);
        
        if (FileExists(dc_soundFileFullPath)) {
            AddFileToDownloadsTable(dc_soundFileFullPath);
            
            PrecacheSound(dc_soundFile);
        }
    }
}

public Action Timer_MapStartNoSound(Handle timer) {
    g_bNoSoundPeriod = false;
    
    return Plugin_Handled;
}
