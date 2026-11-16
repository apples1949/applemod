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

// ============ Steam 认证（NoSteam）判定用的占位值 ============
// SourceMod 的 GetClientAuthId 拿不到"已校验"的 SteamID 时，会先把缓冲区预置成哨兵串
// （core/logic/smn_players.cpp 的 SteamIdToLocal 开头就 StringToLocal("STEAM_ID_STOP_IGNORING_RETVALS")，
// 之后取不到真实 SteamID 就直接 return 0，缓冲区就留在哨兵串上），SteamID3 与 SteamID64 都是这样。
// 所以"读到这个串" == 引擎的 IsClientFullyAuthenticated() 没通过 == 玩家没完成 Steam 认证。
#define NOAUTH_SENTINEL "STEAM_ID_STOP_IGNORING_RETVALS"
// 认证还没跑完时 SourceMod 给出的占位值，同样不算通过认证
#define NOAUTH_PENDING "STEAM_ID_PENDING"
// 局域网服务器（sv_lan 1）不校验 Steam 票据，引擎统一报这个值 —— 与玩家无关，要放行
#define NOAUTH_LAN "STEAM_ID_LAN"

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

// ============ 连接期缓存（供加载失败/未完成授权的玩家使用） ============
// 加载失败（连接超时、被拒、Steam 验证失败等）的玩家不会走到 OnClientPostAdminCheck，
// 而 player_disconnect 事件派发时引擎往往已经清掉该 client 的 in-game 状态，
// 于是 ResolvePlaceholders 里的 IsClientInGame(client) 为假，{PLAYERNAME} 退化成
// 空串或 "Unknown" —— 这就是「加载失败的玩家名字显示不出来」的根因。
// 这里在 player_connect 阶段把引擎持有的原始名字与地址缓存下来做兜底。
// 注意 client 槽位会被复用，所以每个槽位额外记录 userid（引擎内单调递增、不复用），
// 读取时必须 userid 对得上，避免把上一个玩家的名字套到下一个玩家身上。
char g_ConnectNames[MAXPLAYERS+1][MAX_NAME_LENGTH];
int g_ConnectUserIds[MAXPLAYERS+1];

// ============ 未通过 Steam 认证（NoSteam）的提醒状态 ============
ConVar g_CvarNoAuthWarn;      // 总开关
ConVar g_CvarNoAuthDelay;     // 进服后多久做第一次判定（给正常授权留时间，避免误报）
ConVar g_CvarNoAuthInterval;  // 没通过时重复提醒的间隔

// 每个槽位当前挂着的定时器（先是一次性"首次判定"，判定没通过后换成循环提醒）
Handle g_hNoAuthTimer[MAXPLAYERS+1];
// 上面那个句柄是否"还活着"：定时器跑完/被 Stop 后引擎会关掉句柄，
// 此时变量里的值仍非 null，直接 KillTimer 会报 Invalid timer handle，所以单独记状态。
bool g_bNoAuthTimerAlive[MAXPLAYERS+1];
// 已经提醒过几次（只用于日志和提示文案）
int g_iNoAuthRemindCount[MAXPLAYERS+1];

public Plugin myinfo = {
    name = "Connect info",
    author = "HoongDou apples1949",
    description = "Print SteamID, IP and geo location (geoip) on player connect/disconnect",
    version = "2.5",
    url = ""
};

public void OnPluginStart() {
    // player_connect 早于授权与进游戏，此时引擎仍持有玩家在连接界面的原始名字与地址，
    // 用它做缓存给 player_disconnect 兜底（加载失败的玩家拿不到 in-game 客户端名字）。
    // 两个事件都挂：player_connect_client 是新版事件（来源较可靠），
    // player_connect 是旧版事件（额外携带 address 字段），两者先后触发时按 userid 幂等处理。
    HookEventEx("player_connect_client", Event_PlayerConnect, EventHookMode_Pre);
    HookEventEx("player_connect", Event_PlayerConnect, EventHookMode_Pre);
    HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Pre);
    
    // 显示在场所有玩家归属地
    RegConsoleCmd("sm_ip", Command_ShowGeo, "显示在场所有玩家的归属地");
    RegConsoleCmd("sm_geo", Command_ShowGeo, "显示在场所有玩家的归属地");
    
    // 查询指定 IP 的归属地（客户端与服务端控制台均可用）
    RegConsoleCmd("sm_tip", Command_QueryIp, "查询指定 IP 的归属地，用法: sm_tip <IP>");
    
    // cannounce 声音配置
    SetupJoinMsgSounds();
    
    // 未通过 Steam 认证（NoSteam）的提醒配置
    SetupNoAuthReminders();
    
    // 直接指定中文语言：geoip native 只能通过 client 参数指定语言，
    // 这里解析简体中文语言号，配合 GeoLangSource() 强制返回中文地名
    g_iChineseLang = GetLanguageByCode("chi");
    if (g_iChineseLang == -1) {
        LogError("[ConnectInfo] SourceMod 语言列表中未找到简体中文(chi)，地名将回退为服务器默认语言");
    }
    
    // AutoExecConfig 必须在所有 CreateConVar 之后，确保生成的 cfg 包含全部 cvar
    AutoExecConfig(true, "connectinfo");
    
    // 晚加载（plugin_manager 在比赛模式里动态 load 本插件）时，场上已有的玩家不会再有
    // OnClientPutInServer，这里补一次，保证他们同样被认证检查覆盖。
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientConnected(i) && IsClientInGame(i)) {
            ScheduleNoAuthCheck(i);
        }
    }
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

// 玩家进入游戏（还没走完 Steam 授权也算进来）。
// NoSteam 玩家永远等不到 OnClientPostAdminCheck：SourceMod 只在引擎
// IsClientFullyAuthenticated() 为真时才会授权，否则会把他一直留在授权队列里。
// 所以"连接后查有没有通过 Steam 认证"必须挂在这里，不能挂在 OnClientPostAdminCheck。
public void OnClientPutInServer(int client) {
    ScheduleNoAuthCheck(client);
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

// ============ 连接期缓存写入 ============

// 清空某个槽位的 geo（同一槽位换人时调用，避免把上一位玩家的归属地串给下一位）
void ClearClientGeo(int client) {
    g_ClientGeo[client].countryName[0] = '\0';
    g_ClientGeo[client].countryCode[0] = '\0';
    g_ClientGeo[client].region[0] = '\0';
    g_ClientGeo[client].city[0] = '\0';
}

// player_connect 的 address 形如 "1.2.3.4:27005"；IPv6 形如 "2001:db8::1"。
// 只有「恰好一个冒号、且冒号后全是数字」才判定为 IPv4:端口 并去掉端口部分。
void NormalizeAddress(char[] address) {
    TrimString(address);
    int first = FindCharInString(address, ':');
    if (first <= 0) {
        return;
    }
    if (FindCharInString(address, ':', true) != first) {
        return; // 多个冒号 → IPv6，原样保留
    }
    for (int i = first + 1; address[i] != '\0'; i++) {
        if (address[i] < '0' || address[i] > '9') {
            return;
        }
    }
    address[first] = '\0';
}

// userid 已从引擎客户端表移除时 GetClientOfUserId 返回 0，
// 用连接期记录的 userid 反查槽位，让加载失败的玩家也能正常播报。
int FindClientSlotByUserId(int userid) {
    if (userid <= 0) {
        return 0;
    }
    for (int i = 1; i <= MaxClients; i++) {
        if (g_ConnectUserIds[i] == userid) {
            return i;
        }
    }
    return 0;
}

// player_connect / player_connect_client 回调：缓存玩家在连接界面的原始名字与地址。
// 加载失败（连接超时、被拒、Steam 验证失败等）的玩家不会走到 OnClientPostAdminCheck，
// 而 player_disconnect 事件派发时该 client 通常已经不在游戏内（IsClientInGame 为假），
// GetClientName 取不到名字 —— 这份缓存就是为了让这类断开也能显示正确名字。
public void Event_PlayerConnect(Event event, const char[] name, bool dontBroadcast) {
    int userid = GetEventInt(event, "userid");

    // player_connect 自带 index（客户端槽位）；拿不到时再用 userid 反查
    int client = GetEventInt(event, "index");
    if (client <= 0 || client > MaxClients) {
        client = GetClientOfUserId(userid);
    }
    // player_connect 在"客户端还没真正连上"时也会派发（例如 l4d_superversus 的
    // CreateFakeClient / L4D2_SpawnSpecial 这条 SDKCall 调用链里同步触发的连接），
    // 此时直接调 IsFakeClient 会抛 "Exception reported: Client N is not connected"。
    // 必须先确认已连接，再问是不是 Bot；未连接的直接忽略（Bot 本来也不需要缓存 IP/geo）。
    if (client <= 0 || client > MaxClients || !IsClientConnected(client)) {
        return;
    }
    if (IsFakeClient(client)) {
        return;
    }

    // 同一槽位换人了：先清掉上一位玩家残留的 geo / IP，避免串数据
    if (g_ConnectUserIds[client] != userid) {
        g_ConnectUserIds[client] = userid;
        g_ConnectNames[client][0] = '\0';
        g_ClientIPs[client][0] = '\0';
        ClearClientGeo(client);
    }

    char rawName[MAX_NAME_LENGTH];
    GetEventString(event, "name", rawName, sizeof(rawName));
    TrimString(rawName);
    // 只在拿到有效名字时覆盖：后续事件（player_connect_client）字段为空时不能冲掉已缓存的名字
    if (rawName[0] != '\0' && !StrEqual(rawName, "unconnected", false)) {
        strcopy(g_ConnectNames[client], sizeof(g_ConnectNames[]), rawName);
    }

    char rawAddress[64];
    GetEventString(event, "address", rawAddress, sizeof(rawAddress));
    if (rawAddress[0] == '\0') {
        GetEventString(event, "ip", rawAddress, sizeof(rawAddress));
    }
    NormalizeAddress(rawAddress);
    // 只缓存看起来像 IP 的值：address 也可能是 "loopback"/"localhost" 之类，
    // 那种值显示在 {PLAYERIP} 里没有意义，留给后面的 GetClientIP 覆盖即可。
    if (rawAddress[0] != '\0' && IsValidIpString(rawAddress)) {
        // 授权完成后 OnClientPostAdminCheck 会用 GetClientIP 覆盖为权威值，
        // 但从未完成授权的玩家只能靠这里的地址显示 {PLAYERIP}
        strcopy(g_ClientIPs[client], sizeof(g_ClientIPs[]), rawAddress);
    }
}

// 解析断开播报用的玩家名：事件 name 字段 → 连接期缓存 → 客户端实时名字。
void ResolveDisconnectName(Event event, int client, int userid, char[] buffer, int maxlen) {
    buffer[0] = '\0';

    char eventName[MAX_NAME_LENGTH];
    GetEventString(event, "name", eventName, sizeof(eventName));
    TrimString(eventName);
    if (eventName[0] != '\0' && !StrEqual(eventName, "unconnected", false) && !StrEqual(eventName, "Console", false)) {
        strcopy(buffer, maxlen, eventName);
        return;
    }

    if (client > 0 && client <= MaxClients) {
        if (g_ConnectUserIds[client] == userid && g_ConnectNames[client][0] != '\0') {
            strcopy(buffer, maxlen, g_ConnectNames[client]);
            return;
        }
        if (IsClientConnected(client) || IsClientInGame(client)) {
            GetClientName(client, buffer, maxlen);
            TrimString(buffer);
            if (buffer[0] != '\0') {
                return;
            }
        }
    }

    strcopy(buffer, maxlen, "Unknown");
}

public void Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast) {
    SetEventBroadcast(event, true);

    // userid 可能在事件派发前就已从引擎客户端表移除（加载失败/连接中断的玩家尤其如此），
    // 此时 GetClientOfUserId 返回 0，但事件里仍然带着 userid / name / networkid，
    // 所以这里不再用「client 无效就直接 return」的写法，而是靠 userid + 连接期缓存兜底。
    int userid = GetEventInt(event, "userid");
    int client = GetClientOfUserId(userid);
    if (client <= 0 || client > MaxClients) {
        // 用连接期记录的 userid 反查槽位（仅用于读缓存，不代表客户端还在线）
        client = FindClientSlotByUserId(userid);
    }
    if (client > 0 && client <= MaxClients && IsClientConnected(client) && IsFakeClient(client)) {
        return;
    }

    // 解析显示名：事件 name → 连接期缓存 → 客户端实时名字。
    // 加载失败的玩家走前两条，避免名字被填成空串 / Unknown。
    char playerName[MAX_NAME_LENGTH];
    ResolveDisconnectName(event, client, userid, playerName, sizeof(playerName));

    // 机器人网络名同样以 BOT 结尾，客户端已失效时靠事件 networkid 判定
    char steamId[32];
    steamId[0] = '\0';
    if (client > 0 && client <= MaxClients && (IsClientConnected(client) || IsClientInGame(client))) {
        GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));
    } else {
        GetEventString(event, "networkid", steamId, sizeof(steamId));
    }
    // 机器人的 auth 是字面量 "BOT"；客户端已失效时靠事件 networkid 判定。
    // 注意这里不能用「steamId 为空就 return」：加载失败的真人玩家也可能取不到 auth，
    // 那样反而把要修的播报整个吞掉。
    if (StrEqual(steamId, "BOT", false) || StrContains(steamId, "BOT", false) != -1) {
        return;
    }

    // 播放断开声音
    PlayDisconnectSound();

    char reason[128];
    GetEventString(event, "reason", reason, sizeof(reason));
    // 去除换行，替换为空格（与 cannounce 一致）
    ReplaceString(reason, sizeof(reason), "\n", " ");

    // 原因翻译为中文
    char reasonZh[128];
    GetReasonInChinese(reason, reasonZh, sizeof(reasonZh));

    // 内置 cannounce 风格离开消息（有地区/城市用完整模板，否则用简版），原因始终显示
    char message[MSG_MAXLEN];
    if (client > 0 && client <= MaxClients && GetGeoLevel(client) >= 2) {
        strcopy(message, sizeof(message), DISC_MSG_FULL);
    } else {
        strcopy(message, sizeof(message), DISC_MSG_NOGEO);
    }
    ResolvePlaceholders(message, sizeof(message), client, reasonZh, playerName);

    // 用 multicolors（L4D1/2 修复版）输出，标签 {GREEN} 等自动按 L4D2 色码渲染
    CPrintToChatAll("%s", message);

    LogMessage("[Connect Info] Player %s <%s> left the game: %s", playerName, steamId, reason);
}

public void OnClientDisconnect(int client) {
    // 认证提醒的定时器必须立刻杀掉：槽位会被下一位玩家复用，
    // 留着的定时器会把上一位的提醒套到新玩家身上。
    // 放在最前面，Bot 断线时也照清一遍（本来就不会有定时器，纯属兜底）。
    StopNoAuthTimer(client);

    if (IsFakeClient(client)) {
        return;
    }

    // 不能在此时立即清数据：player_disconnect 的 Pre hook 与 OnClientDisconnect 的先后顺序
    // 取决于引擎的实现路径，若本回调先跑，播报里的名字/地区/IP 就会被提前抹掉。
    // 因此延后一帧再清，保证本次断开的播报一定用得上这些数据。
    CreateTimer(0.0, Timer_ClearDisconnectedClient, client, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_ClearDisconnectedClient(Handle timer, any client) {
    if (client < 1 || client > MaxClients) {
        return Plugin_Stop;
    }

    // 该槽位已被新玩家占用（player_connect 已写入新数据）：不能清，否则串数据
    if (IsClientConnected(client) || IsClientInGame(client)) {
        return Plugin_Stop;
    }

    g_ClientIPs[client][0] = '\0';
    ClearClientGeo(client);
    // g_ConnectNames / g_ConnectUserIds 故意不在这里清：
    // 引擎的 userid 单调递增且永不复用，缓存里的旧 userid 不可能再匹配到新玩家，
    // 所以留着不会串数据（Event_PlayerConnect 在该槽位换人时会整体重置），
    // 却能让任何晚到的断开播报仍拿得到名字。
    return Plugin_Stop;
}

// ==================== Steam 认证（NoSteam）检查与提醒 ====================

void SetupNoAuthReminders() {
    g_CvarNoAuthWarn = CreateConVar("sm_connectinfo_noauth_warn", "1",
        "玩家没通过 Steam 认证时是否提醒他（0=关闭 1=开启）", FCVAR_NONE, true, 0.0, true, 1.0);
    // 第一次判定要等一会儿：正常玩家的 Steam 票据校验需要 1~3 秒，
    // 立刻判定会把"还在授权中"的正常玩家误判成 NoSteam；
    // 但也不能太大，否则可能赶不上引擎的 "No Steam logon" 踢出。
    g_CvarNoAuthDelay = CreateConVar("sm_connectinfo_noauth_delay", "8.0",
        "玩家进服后多少秒做第一次 Steam 认证判定", FCVAR_NONE, true, 0.0);
    g_CvarNoAuthInterval = CreateConVar("sm_connectinfo_noauth_interval", "30.0",
        "没通过 Steam 认证时重复提醒的间隔（秒）", FCVAR_NONE, true, 1.0);
}

// 为某个槽位安排"进服后第一次认证判定"。已通过认证的玩家不会真的被提醒：
// 定时器到点时先用 IsSteamAuthPassed() 复核，通过就直接结束。
void ScheduleNoAuthCheck(int client) {
    if (client <= 0 || client > MaxClients) {
        return;
    }
    if (!IsClientConnected(client) || IsFakeClient(client)) {
        return;
    }

    // 同一个槽位可能因为换图 / 重连再次进来：先清掉上一轮的定时器，避免重复提醒
    StopNoAuthTimer(client);
    g_iNoAuthRemindCount[client] = 0;

    if (g_CvarNoAuthWarn == null || !g_CvarNoAuthWarn.BoolValue) {
        return;
    }

    // 故意不加 TIMER_FLAG_NO_MAPCHANGE：带这个标记的定时器会在换图时被引擎杀掉
    // （TimerSys.cpp 的 KillMapchangeTimers），而玩家换图后仍然是"没通过认证"的状态，
    // 提醒必须跨图继续。同一槽位重复安排时 ScheduleNoAuthCheck / StopNoAuthTimer 会先杀旧定时器，
    // 所以就算换图后 OnClientPutInServer 再调一次也不会出现双份提醒。
    g_hNoAuthTimer[client] = CreateTimer(g_CvarNoAuthDelay.FloatValue, Timer_NoAuthFirstCheck,
                                        GetClientUserId(client));
    g_bNoAuthTimerAlive[client] = (g_hNoAuthTimer[client] != null);
}

// 第一次判定：正常玩家这个时候早就该授权完成了，还没完成的才是 NoSteam / Steam 掉线。
public Action Timer_NoAuthFirstCheck(Handle timer, any userid) {
    int client = GetClientOfUserId(userid);
    if (client == 0) {
        // 玩家已经离开：OnClientDisconnect 里已经把定时器清干净了
        return Plugin_Stop;
    }

    // 这次是一次性定时器，句柄即将被引擎回收，只清记录，不能再 KillTimer
    ForgetNoAuthTimer(client);

    if (IsSteamAuthPassed(client)) {
        return Plugin_Stop;
    }

    // 第一次提醒 + 换成循环提醒（每 g_CvarNoAuthInterval 秒一次，直到通过认证或离开）
    PrintNoAuthReminder(client);
    StartNoAuthRepeatTimer(client);

    return Plugin_Stop;
}

void StartNoAuthRepeatTimer(int client) {
    // 同上：不加 TIMER_FLAG_NO_MAPCHANGE，循环提醒要跟着玩家跨图继续
    g_hNoAuthTimer[client] = CreateTimer(g_CvarNoAuthInterval.FloatValue, Timer_NoAuthRepeatCheck,
                                        GetClientUserId(client), TIMER_REPEAT);
    g_bNoAuthTimerAlive[client] = (g_hNoAuthTimer[client] != null);
}

// 循环判定：一通过认证立刻停手（不再打扰）；还是没通过就再提醒一次。
public Action Timer_NoAuthRepeatCheck(Handle timer, any userid) {
    int client = GetClientOfUserId(userid);
    if (client == 0) {
        return Plugin_Stop;
    }

    if (IsSteamAuthPassed(client)) {
        // 自己返回 Plugin_Stop，句柄由引擎回收，这里只清记录
        ForgetNoAuthTimer(client);
        return Plugin_Stop;
    }

    PrintNoAuthReminder(client);

    return Plugin_Continue;
}

// 判断客户端是否已经通过 Steam 认证（Steam 后端确认过这张 auth ticket）。
//
// 判定依据（SourceMod core/PlayerManager.cpp 的 RunAuthChecks 与
// core/logic/smn_players.cpp 的 SteamIdToLocal）：
//   1) 只有引擎 IsClientFullyAuthenticated() 为真时，SourceMod 才会把客户端标记为已授权
//      （IsClientAuthorized）。这是最权威、也是本函数的主判据。
//   2) GetClientAuthId() 取不到已校验的 SteamID 时返回 false，并把缓冲区留在预置的哨兵串
//      "STEAM_ID_STOP_IGNORING_RETVALS" 上；SteamID3 和 SteamID64 都是这个行为。
//      这就是需求里说的"查 SteamID3 / SteamID64 是不是这个值"。
//   3) 局域网服务器（sv_lan 1）上引擎根本不校验票据：SourceMod 会直接把玩家授权，
//      引擎网络 ID 统一是 STEAM_ID_LAN，SteamID64 那条路更是直接 return 0。
//      这属于服务器配置而不是玩家的问题，必须当作"已通过"放行，否则整服玩家都会被刷屏。
bool IsSteamAuthPassed(int client) {
    if (client <= 0 || client > MaxClients) {
        return true;
    }
    if (!IsClientConnected(client) || IsFakeClient(client)) {
        return true;
    }

    // validate=false：取引擎当前报告的原始 ID，用来识别"局域网服务器"这种不可判定场景
    char steam3[MAX_AUTHID_LENGTH] = "";
    char steam64[MAX_AUTHID_LENGTH] = "";
    GetClientAuthId(client, AuthId_Steam3, steam3, sizeof(steam3), false);
    GetClientAuthId(client, AuthId_SteamID64, steam64, sizeof(steam64), false);
    if (StrEqual(steam3, NOAUTH_LAN, false)) {
        return true;
    }

    // 主判据：SourceMod 的授权状态
    if (!IsClientAuthorized(client)) {
        return false;
    }

    // 复核（需求指定的判据）：SteamID3 与 SteamID64 都还是占位值，同样算没通过。
    // 这一步专门兜住 core.cfg 关掉 SteamAuthstringValidation 的情况：
    // 那时 SourceMod 会把没验证过的玩家直接授权，只有 ID 还停在哨兵串上。
    if (IsPlaceholderAuthId(steam3) && IsPlaceholderAuthId(steam64)) {
        return false;
    }

    return true;
}

// SteamID 是否还是"没拿到真实 SteamID"的占位值。
// 注意 STEAM_ID_LAN 不算：局域网服务器上它表示服务器关了 Steam 校验，与玩家无关。
bool IsPlaceholderAuthId(const char[] auth) {
    return auth[0] == '\0'
        || StrEqual(auth, NOAUTH_SENTINEL, false)
        || StrEqual(auth, NOAUTH_PENDING, false);
}

// 提醒玩家：说清现象、给出可操作步骤、说明不处理的后果
void PrintNoAuthReminder(int client) {
    if (client <= 0 || client > MaxClients || !IsClientInGame(client)) {
        return;
    }

    g_iNoAuthRemindCount[client]++;

    CPrintToChat(client, "{default}[服务器] {red}你没有通过 Steam 认证{DEFAULT}，服务器会把你当成 NoSteam 客户端。");
    CPrintToChat(client, "{default}[服务器] 请{green}用加速器加速 Steam{DEFAULT}，然后{green}重启 Steam 和游戏{DEFAULT}，再重新进服。");
    CPrintToChat(client, "{default}[服务器] 否则你会被服务器以 {red}No Steam logon{DEFAULT} 的原因自动踢出（第 %d 次提醒）。",
                 g_iNoAuthRemindCount[client]);

    // 服务端日志：把实际读到的两个 ID 记下来，
    // 方便事后区分"玩家没登录 Steam"和"服务器/网络侧的 Steam 连接问题"
    char steam3[MAX_AUTHID_LENGTH] = "";
    char steam64[MAX_AUTHID_LENGTH] = "";
    GetClientAuthId(client, AuthId_Steam3, steam3, sizeof(steam3), false);
    GetClientAuthId(client, AuthId_SteamID64, steam64, sizeof(steam64), false);

    // NoSteam 玩家走不到 OnClientPostAdminCheck，g_ClientIPs 可能只有 player_connect 缓存的地址，
    // 缓存也没有时现场取一次，保证日志里始终有 IP
    char ip[36];
    if (g_ClientIPs[client][0] != '\0') {
        strcopy(ip, sizeof(ip), g_ClientIPs[client]);
    } else {
        GetClientIP(client, ip, sizeof(ip));
        strcopy(g_ClientIPs[client], sizeof(g_ClientIPs[]), ip);
    }

    LogMessage("[ConnectInfo] 玩家 %N 未通过 Steam 认证（SteamID3=\"%s\"，SteamID64=\"%s\"，IP=%s），第 %d 次提醒",
               client, steam3, steam64, ip, g_iNoAuthRemindCount[client]);
}

// 只清记录，不动句柄（在定时器自己的回调里用：句柄马上就要被引擎回收）
void ForgetNoAuthTimer(int client) {
    g_hNoAuthTimer[client] = null;
    g_bNoAuthTimerAlive[client] = false;
}

// 外部清理（断线、换图后重新安排）：真的把定时器杀掉
void StopNoAuthTimer(int client) {
    if (client <= 0 || client > MaxClients) {
        return;
    }
    if (g_bNoAuthTimerAlive[client] && g_hNoAuthTimer[client] != null) {
        KillTimer(g_hNoAuthTimer[client]);
    }
    ForgetNoAuthTimer(client);
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
// nameOverride 非空时优先用作 {PLAYERNAME}（断开播报传入连接期缓存的名字，
// 因为此时 IsClientInGame 往往已为假，GetClientName 取不到有效名字）
void ResolvePlaceholders(char[] message, int maxlen, int client, const char[] reason = "", const char[] nameOverride = "") {
    char buffer[128];
    bool clientValid = (client > 0 && client <= MaxClients && IsClientInGame(client));

    // geo / IP 的读取统一走「槽位合法性」判断，而不是 clientValid：
    // 加载失败的玩家不在游戏内，但连接期缓存里仍有其 IP，仍应显示出来
    bool slotValid = (client > 0 && client <= MaxClients);

    if (StrContains(message, "{PLAYERNAME}") != -1) {
        if (nameOverride[0] != '\0') {
            strcopy(buffer, sizeof(buffer), nameOverride);
        } else if (clientValid) {
            GetClientName(client, buffer, sizeof(buffer));
        } else if (slotValid && g_ConnectNames[client][0] != '\0') {
            strcopy(buffer, sizeof(buffer), g_ConnectNames[client]);
        } else {
            strcopy(buffer, sizeof(buffer), "Unknown");
        }
        ReplaceString(message, maxlen, "{PLAYERNAME}", buffer);
    }

    if (StrContains(message, "{STEAMID}") != -1) {
        buffer[0] = '\0';
        if (client > 0 && client <= MaxClients && (IsClientConnected(client) || IsClientInGame(client))) {
            // 取不到时 buffer 保持空串，下面统一回退，避免输出上一次循环/上一次调用残留的内容
            GetClientAuthId(client, AuthId_Steam2, buffer, sizeof(buffer));
        }
        if (buffer[0] == '\0') {
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
