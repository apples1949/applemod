#pragma newdecls required
#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <ripext>
#include <protobuf>
#include <multicolors>

#define DEBUG

#define SOUNDFILE_PATH_LEN 256
#define MSG_MAXLEN 512

// ============ 内置消息模板（原 cannounce_settings.txt 文案硬编码） ============
// 加入：2=国家+地区/城市，1=仅有国家，0=无地理信息
#define JOIN_MSG_FULL "来自{GREEN}{PLAYERCOUNTRY}{DEFAULT}({LIGHTGREEN}{PLAYERCOUNTRYSHORT3}{DEFAULT} ){LIGHTGREEN}{PLAYERREGION} {PLAYERCITY}的{DEFAULT}[{GREEN}{PLAYERNAME}{DEFAULT}] 加入游戏，IP：[{GREEN}{PLAYERIP}{DEFAULT}]"
#define JOIN_MSG_COUNTRY "来自{GREEN}{PLAYERCOUNTRY}{DEFAULT}的{DEFAULT}[{GREEN}{PLAYERNAME}{DEFAULT}] 加入游戏"
#define JOIN_MSG_MINIMAL "[{GREEN}{PLAYERNAME}{DEFAULT}] 加入游戏"
// 离开：有地区/城市用完整模板，否则用简版；原因始终显示（已翻译为中文）
#define DISC_MSG_FULL "来自{LIGHTGREEN}{PLAYERREGION} {PLAYERCITY}{DEFAULT}的[{GREEN}{PLAYERNAME}{DEFAULT}]离开游戏，原因为: {GREEN}{DISC_REASON}"
#define DISC_MSG_NOGEO "[{GREEN}{PLAYERNAME}{DEFAULT}]离开游戏，原因为: {GREEN}{DISC_REASON}"

ConVar g_hAPIKey;
ConVar g_hGeocodeAPIKey;

// ============ 声音相关（沿用 cannounce/joinmsg.sp 的配置） ============
ConVar g_CvarPlaySound;
ConVar g_CvarPlaySoundFile;
ConVar g_CvarPlayDiscSound;
ConVar g_CvarPlayDiscSoundFile;
ConVar g_CvarMapStartNoSound;

bool g_bNoSoundPeriod;

// ============ cannounce 风格消息输出 ============

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
    description = "Print SteamID and IP in chat via HTTP requests with REST in Pawn",
    version = "2.3",
    url = ""
};

public void OnPluginStart() {
    AutoExecConfig(true, "ip_data_api");
    g_hAPIKey = CreateConVar("sm_ipdata_apikey", "", "API key for ipdata.co", FCVAR_PROTECTED | FCVAR_NOTIFY);
    g_hGeocodeAPIKey = CreateConVar("sm_geocode_apikey", "", "API key for geocode.maps.co", FCVAR_PROTECTED | FCVAR_NOTIFY);
    
    g_hAPIKey.AddChangeHook(OnAPIKeyChanged);
    g_hGeocodeAPIKey.AddChangeHook(OnGeocodeAPIKeyChanged);
    
    HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Pre);
    
    // cannounce 声音配置
    SetupJoinMsgSounds();
}

public void OnMapStart() {
    // 预缓存并设置声音文件下载（声音缓存）
    LoadSoundFilesAll();
    
    // 地图开始后一段时间内忽略加入声音
    OnMapStart_JoinMsg();
}

public void OnClientPutInServer(int client) {
    char apiKey[64];
    g_hAPIKey.GetString(apiKey, sizeof(apiKey));

    if (!IsFakeClient(client) && strlen(apiKey) > 0) {
        char ipAddress[32];
        GetClientIP(client, ipAddress, sizeof(ipAddress));
        
        strcopy(g_ClientIPs[client], sizeof(g_ClientIPs[]), ipAddress);
        
        char url[512];
        Format(url, sizeof(url), "%s?api-key=%s", ipAddress, apiKey);

        HTTPClient clientObj = new HTTPClient("https://api.ipdata.co");
        clientObj.SetHeader("User-Agent", "Mozilla/5.0 (compatible; MyBot/1.0)");

        clientObj.Get(url, HttpRequestCallback, client);
    }
}

// 玩家完成授权进入游戏后播放加入声音（与 cannounce 播放时机一致）
public void OnClientPostAdminCheck(int client) {
    if (IsFakeClient(client)) {
        return;
    }
    
    PlayJoinSound();
}

public void HttpRequestCallback(HTTPResponse response, int client) {
    if (response.Status != HTTPStatus_OK) {
        PrintToChat(client, "HTTP 请求失败（状态码: %d）", response.Status);
        
        if (response.Status == HTTPStatus_BadRequest) {
            char responseBody[4096];
            response.Data.ToString(responseBody, sizeof(responseBody));
            JSONObject jsonObject = JSONObject.FromString(responseBody);
            if (jsonObject != null) {
                char errorMessage[256];
                jsonObject.GetString("message", errorMessage, sizeof(errorMessage));
                LogError("HTTP 400 Bad Request: %s", errorMessage);
                delete jsonObject;
            }
        }
        return;
    }

    char responseBody[4096];
    response.Data.ToString(responseBody, sizeof(responseBody));

    JSONObject jsonObject = JSONObject.FromString(responseBody);
    if (jsonObject == null) {
        PrintToChat(client, "无法解析服务器响应。");
        return;
    }

    char countryCode[8], countryName[64], region[64], city[64];
    jsonObject.GetString("country_code", countryCode, sizeof(countryCode));
    jsonObject.GetString("country_name", countryName, sizeof(countryName));
    jsonObject.GetString("region", region, sizeof(region));
    jsonObject.GetString("city", city, sizeof(city));
    
    // 保存 geo 信息供消息模板占位符使用
    strcopy(g_ClientGeo[client].countryCode, sizeof(g_ClientGeo[].countryCode), countryCode);
    strcopy(g_ClientGeo[client].countryName, sizeof(g_ClientGeo[].countryName), countryName);
    strcopy(g_ClientGeo[client].region, sizeof(g_ClientGeo[].region), region);
    strcopy(g_ClientGeo[client].city, sizeof(g_ClientGeo[].city), city);

    if (strlen(city) == 0 || StrEqual(city, "null", false)) {
        float latitude = jsonObject.GetFloat("latitude");
        float longitude = jsonObject.GetFloat("longitude");
        
        delete jsonObject;
        
        if (latitude != 0.0 && longitude != 0.0) {
            char geocodeAPIKey[64];
            g_hGeocodeAPIKey.GetString(geocodeAPIKey, sizeof(geocodeAPIKey));
            
            if (strlen(geocodeAPIKey) > 0) {
                char geocodeUrl[512];
                Format(geocodeUrl, sizeof(geocodeUrl), "/reverse?lat=%.10f&lon=%.10f&api_key=%s", latitude, longitude, geocodeAPIKey);
                
                HTTPClient geocodeClient = new HTTPClient("https://geocode.maps.co");
                geocodeClient.SetHeader("User-Agent", "Mozilla/5.0 (compatible; MyBot/1.0)");
                
                geocodeClient.Get(geocodeUrl, GeocodeRequestCallback, client);
                
                return;
            }
        }
        
        strcopy(city, sizeof(city), "Unknown");
        strcopy(g_ClientGeo[client].city, sizeof(g_ClientGeo[].city), city);
    } else {
        delete jsonObject;
    }
    
    PrintJoinMessage(client);
}

public void GeocodeRequestCallback(HTTPResponse response, int client) {
    char city[64] = "Unknown";
    char region[64] = "";
    
    if (response.Status == HTTPStatus_OK) {
        char responseBody[4096];
        response.Data.ToString(responseBody, sizeof(responseBody));
        
        JSONObject jsonObject = JSONObject.FromString(responseBody);
        if (jsonObject != null) {
            JSONObject address = view_as<JSONObject>(jsonObject.Get("address"));
            if (address != null) {
                address.GetString("state", region, sizeof(region));
                address.GetString("city", city, sizeof(city));
                
                if (strlen(city) == 0) {
                    address.GetString("district", city, sizeof(city));
                }
                
                delete address;
            }
            delete jsonObject;
        }
    }
    
    if (strlen(city) == 0) {
        strcopy(city, sizeof(city), "Unknown");
    }
    
    strcopy(g_ClientGeo[client].region, sizeof(g_ClientGeo[].region), region);
    strcopy(g_ClientGeo[client].city, sizeof(g_ClientGeo[].city), city);
    
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

public void OnAPIKeyChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
    LogMessage("IP API key changed from '%s' to '%s'", oldValue, newValue);
}

public void OnGeocodeAPIKeyChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
    LogMessage("Geocode API key changed from '%s' to '%s'", oldValue, newValue);
}

// ==================== cannounce 风格消息输出 ====================

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

// ==================== geo 信息取值（空值回退） ====================

void GetCountryName(int client, char[] buffer, int maxlen) {
    if (g_ClientGeo[client].countryName[0] != '\0') {
        strcopy(buffer, maxlen, g_ClientGeo[client].countryName);
    } else if (g_ClientGeo[client].countryCode[0] != '\0') {
        strcopy(buffer, maxlen, g_ClientGeo[client].countryCode);
    } else {
        strcopy(buffer, maxlen, "Unknown");
    }
}

void GetCountryCode(int client, char[] buffer, int maxlen) {
    if (g_ClientGeo[client].countryCode[0] != '\0') {
        strcopy(buffer, maxlen, g_ClientGeo[client].countryCode);
    } else {
        strcopy(buffer, maxlen, "Unknown");
    }
}

void GetCity(int client, char[] buffer, int maxlen) {
    if (g_ClientGeo[client].city[0] != '\0') {
        strcopy(buffer, maxlen, g_ClientGeo[client].city);
    } else {
        strcopy(buffer, maxlen, "Unknown");
    }
}

void GetRegion(int client, char[] buffer, int maxlen) {
    if (g_ClientGeo[client].region[0] != '\0') {
        strcopy(buffer, maxlen, g_ClientGeo[client].region);
    } else {
        strcopy(buffer, maxlen, "");
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
