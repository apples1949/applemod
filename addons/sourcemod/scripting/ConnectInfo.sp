#pragma newdecls required
#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <protobuf>
#include <multicolors>
#include <geoip>

#define SOUNDFILE_PATH_LEN 256
#define MSG_MAXLEN 512
#define GEO_NAME_CN_FILE "data/connectinfo_geoname_cn.txt"
#define GEO_UNMAPPED_FILE "data/connectinfo_unmapped.txt"

// ============ 内置消息模板（原 cannounce_settings.txt 文案硬编码） ============
// 加入：2=国家+地区/城市，1=仅有国家，0=无地理信息
#define JOIN_MSG_FULL "来自{GREEN}{PLAYERCOUNTRY}{DEFAULT}({LIGHTGREEN}{PLAYERCOUNTRYSHORT3}{DEFAULT} ){LIGHTGREEN}{PLAYERREGION} {PLAYERCITY}的{DEFAULT}[{GREEN}{PLAYERNAME}{DEFAULT}] 加入游戏，IP：[{GREEN}{PLAYERIP}{DEFAULT}]"
#define JOIN_MSG_COUNTRY "来自{GREEN}{PLAYERCOUNTRY}{DEFAULT}的{DEFAULT}[{GREEN}{PLAYERNAME}{DEFAULT}] 加入游戏"
#define JOIN_MSG_MINIMAL "来自{GREEN}{PLAYERCOUNTRY}{DEFAULT} {LIGHTGREEN}{PLAYERREGION}{DEFAULT}的{DEFAULT}[{GREEN}{PLAYERNAME}{DEFAULT}] 加入游戏"
// 离开：有地区/城市用完整模板，否则用简版；原因始终显示（已翻译为中文）
#define DISC_MSG_FULL "来自{LIGHTGREEN}{PLAYERREGION} {PLAYERCITY}{DEFAULT}的[{GREEN}{PLAYERNAME}{DEFAULT}]离开游戏，原因为: {GREEN}{DISC_REASON}"
#define DISC_MSG_NOGEO "[{GREEN}{PLAYERNAME}{DEFAULT}]离开游戏，原因为: {GREEN}{DISC_REASON}"

// 英->中 地理名称映射表（data/connectinfo_geoname_cn.txt）
Handle g_hGeoNameKV = null;
char g_GeoNamePath[PLATFORM_MAX_PATH];
char g_UnmappedPath[PLATFORM_MAX_PATH];

// ============ 声音相关（沿用 cannounce/joinmsg.sp 的配置） ============
ConVar g_CvarPlaySound;
ConVar g_CvarPlaySoundFile;
ConVar g_CvarPlayDiscSound;
ConVar g_CvarPlayDiscSoundFile;
ConVar g_CvarMapStartNoSound;

bool g_bNoSoundPeriod;

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
    
    // cannounce 声音配置
    SetupJoinMsgSounds();
    
    // 加载 英->中 地理名称映射表
    g_hGeoNameKV = CreateKeyValues("GeoNameCn");
    BuildPath(Path_SM, g_GeoNamePath, sizeof(g_GeoNamePath), GEO_NAME_CN_FILE);
    if (!FileToKeyValues(g_hGeoNameKV, g_GeoNamePath)) {
        LogError("[ConnectInfo] 无法加载地理中文映射表: %s", g_GeoNamePath);
    }
    
    // 未匹配英文记录文件的路径
    BuildPath(Path_SM, g_UnmappedPath, sizeof(g_UnmappedPath), GEO_UNMAPPED_FILE);
    
    // AutoExecConfig 必须在所有 CreateConVar 之后，确保生成的 cfg 包含全部 cvar
    AutoExecConfig(true, "connectinfo");
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

public void OnPluginEnd() {
    if (g_hGeoNameKV != null) {
        CloseHandle(g_hGeoNameKV);
        g_hGeoNameKV = null;
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
        
        char country[64], region[64], city[64];
        GetCountryName(i, country, sizeof(country));
        GetRegion(i, region, sizeof(region));
        GetCity(i, city, sizeof(city));
        
        char geo[192];
        if (!IsGeoFieldEmpty(g_ClientGeo[i].region) && !IsGeoFieldEmpty(g_ClientGeo[i].city)) {
            Format(geo, sizeof(geo), "%s %s %s", country, region, city);
        } else if (!IsGeoFieldEmpty(g_ClientGeo[i].region)) {
            Format(geo, sizeof(geo), "%s %s", country, region);
        } else if (!IsGeoFieldEmpty(g_ClientGeo[i].city)) {
            Format(geo, sizeof(geo), "%s %s", country, city);
        } else {
            Format(geo, sizeof(geo), "%s", country);
        }
        
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

// 用 geoip 本地库（GeoIP.ext + GeoLite2）查询 IP 归属地，再经中文对照表翻译
void LookupGeoip(int client) {
    if (client <= 0 || client > MaxClients || g_ClientIPs[client][0] == '\0') {
        return;
    }
    
    // geoip 扩展未加载时跳过（native 为可选，避免报错）
    if (GetFeatureStatus(FeatureType_Native, "GeoipCountry") != FeatureStatus_Available) {
        return;
    }
    
    char ip[36];
    strcopy(ip, sizeof(ip), g_ClientIPs[client]);
    
    // geoip 库取英文名（client 参数默认 -1 = 英文）
    char country[64] = "", code[3] = "", region[64] = "", city[64] = "";
    GeoipCountry(ip, country, sizeof(country));
    GeoipCode2(ip, code);
    GeoipRegion(ip, region, sizeof(region));
    GeoipCity(ip, city, sizeof(city));
    
    strcopy(g_ClientGeo[client].countryName, sizeof(g_ClientGeo[].countryName), country);
    strcopy(g_ClientGeo[client].countryCode, sizeof(g_ClientGeo[].countryCode), code);
    strcopy(g_ClientGeo[client].region, sizeof(g_ClientGeo[].region), region);
    strcopy(g_ClientGeo[client].city, sizeof(g_ClientGeo[].city), city);
    
    // 英文名翻译为中文（本身已是中文/非 ASCII 则直接显示）
    LocalizeGeo(client);
}

// 将 g_ClientGeo 中的英文国家/地区/城市名通过映射表翻译为中文；找不到保留原文
void LocalizeGeo(int client) {
    if (g_hGeoNameKV == null) {
        return;
    }
    
    TranslateGeoNameSection("countries", g_ClientGeo[client].countryName, sizeof(g_ClientGeo[].countryName));
    TranslateGeoNameSection("china_regions", g_ClientGeo[client].region, sizeof(g_ClientGeo[].region));
    TranslateGeoNameSection("cities", g_ClientGeo[client].city, sizeof(g_ClientGeo[].city));
}

// 在 KV 的指定 section 内查找英文名并替换为中文；找不到则保留原文，并记录到未匹配文件（去重）
void TranslateGeoNameSection(const char[] section, char[] buffer, int maxlen) {
    if (strlen(buffer) == 0 || StrEqual(buffer, "Unknown", false)) {
        return;
    }
    
    // 返回的已是中文（或任何非 ASCII 本地语言）：直接显示，不查映射、不记录
    if (!IsAsciiString(buffer)) {
        return;
    }
    
    bool found = false;
    char cn[128];
    
    KvRewind(g_hGeoNameKV);
    if (KvJumpToKey(g_hGeoNameKV, section, false)) {
        KvGetString(g_hGeoNameKV, buffer, cn, sizeof(cn), "");
        if (cn[0] != '\0') {
            strcopy(buffer, maxlen, cn);
            found = true;
        }
    }
    
    // 未匹配：保留原英文，并记录到后台文件（已有的不重复记录）
    if (!found) {
        RecordUnmappedName(buffer);
    }
}

// 判断字符串是否全部为 ASCII（纯英文）；含非 ASCII（如中文）返回 false
bool IsAsciiString(const char[] str) {
    for (int i = 0; str[i] != '\0'; i++) {
        if (str[i] & 0x80) {
            return false;
        }
    }
    return true;
}

// 将未匹配的英文地名记录到 data/connectinfo_unmapped.txt（去除已有重复），文件不存在则创建
void RecordUnmappedName(const char[] english) {
    if (strlen(english) == 0 || g_UnmappedPath[0] == '\0') {
        return;
    }
    
    // 读取已有记录，检查是否已存在
    if (FileExists(g_UnmappedPath)) {
        File fh = OpenFile(g_UnmappedPath, "r");
        if (fh != null) {
            char line[128];
            while (!IsEndOfFile(fh) && fh.ReadLine(line, sizeof(line))) {
                TrimString(line);
                if (StrEqual(line, english, false)) {
                    delete fh;
                    return; // 已记录过，跳过
                }
            }
            delete fh;
        }
    }
    
    // 追加记录
    File fw = OpenFile(g_UnmappedPath, "a");
    if (fw != null) {
        fw.WriteLine("%s", english);
        delete fw;
    }
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
