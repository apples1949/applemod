#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <colors>

#include <l4d2_skill_detect>

// 同一嘲讽类型 30 秒内只输出一次
#define TAUNT_COOLDOWN          30.0

// ===== 嘲讽类型 =====
enum TauntType
{
	TAUNT_INCAP,                // 生还者BOT嘲讽倒地真人
	TAUNT_DOOR_CLOSE,           // 生还者BOT嘲讽进安全屋
	TAUNT_BOOMER_POP,           // BoomerBOT被真人击杀
	TAUNT_BOOMER_VOMIT,         // BoomerBOT喷到真人
	TAUNT_TANK_ROCK,            // 生还者BOT嘲讽真人吃石头
	TAUNT_TANK_HIT,             // TankBOT砸中真人
	TAUNT_CAR_ALARM,            // 生还者BOT嘲讽真人打警报
	TAUNT_HUNTER_POUNCE,        // HunterBOT扑中真人
	TAUNT_SKEET,                // 生还者BOT空爆
	TAUNT_SKEET_MELEE,          // 生还者BOT近战空爆
	TAUNT_SKEET_MELEE_HURT,     // 生还者BOT近战空爆(残血)
	TAUNT_SKEET_SNIPER,         // 生还者BOT狙击空爆
	TAUNT_SKEET_SNIPER_HURT,    // 生还者BOT狙击空爆(残血)
	TAUNT_HUNTER_DEADSTOP,      // 生还者BOT推扑
	TAUNT_FRIENDLY_FIRE,        // BOT被真人误伤
	TAUNT_HEAL,                 // BOT被真人打包
	TAUNT_HIGH_POUNCE,          // 生还者BOT嘲讽真人被高扑
	TAUNT_RESCUED,              // 生还者BOT嘲讽进救援
	TAUNT_WITCH,                // Witch嘲讽秒妹失败真人
	TAUNT_TYPES
};

bool	g_bLateLoad;
bool	g_bIsRoundEnd;
bool	g_bDoorClosed;
float	g_fLastTaunt[TAUNT_TYPES];
char	g_sBotChat[256];

// ===== 各嘲讽类型的文案（二维数组存储）=====
char g_sIncapTaunts[][128] =
{
	"%N，你打的就是个JB，倒地还比老子快！",
	"好家伙，又倒了，你是不是哈皮？",
	"太弱太弱，这个生还者不行的啊",
	"nmmdw，怎么又有个哈皮倒地了？",
	"%N，我是你爸爸，快叫爸我来扶你起来",
	"%N好厉害哦，倒地都是第一哦，真的是太棒了呢",
	"%N，你再倒地我们电脑人就开始跑分了，太菜了受不了了",
	"%N你玩的是个JB，我都比你厉害",
	"%N，你先躺着不要动，我去给你买几个橘子",
	"%N，NTMD又倒地了，WBNMSL真的！",
	"%N哥哥好棒哦~ 倒地都是第一个呢~ 这就是大佬吗，i了i了",
	"电脑人请求踢出：%N",
	"会不会玩？不会玩赶紧退了",
	"你打的就是个锤子",
	"好像有个人倒地了，算了不管了",
	"CNM，拖累我们速度",
	"你咋不去死一死啊",
	"啥东西啊，咋又倒了",
	"你是不是脑子有点问题？",
	"我要在你的头上拉屎！",
	"性感 %N 在线倒地",
	"WRNM",
	"能不能不扶他啊，每次都是他倒麻烦的一批",
	"求求你了，别倒地了 SB",
	"看看 %N 摔了个狗啃泥",
	"哇塞，那么牛逼的吗",
	"嗯哼 嗯哼",
	"跑分了，告辞",
	"这波啊，这波是满地找牙",
	"你在赣深麽",
	"欸，小老板你很骚啊",
	"WDNMD",
	"臭傻逼，你妈死了",
	"你说你倒地，犯了错，你给我的信心动了火",
	"希望之花~~",
	"不要停下来啊！",
	"只见那霹雳闪电，一个人便倒了地"
};

char g_sDoorCloseTaunts[][128] =
{
	"对面特感太菜了！",
	"SB特感给爷爬",
	"我们电脑人都能进屋",
	"弱智特感不灵的",
	"好家伙，对面这特感我狂吃两大碗",
	"这波啊，这波是特感太弱我们强",
	"求求你们了，别让我们进屋吧",
	"嗨，对面简直不值一提",
	"GG，NT，WP，GL，开玩笑的，怎么可能呢",
	"年度大戏：为什么电脑能跑进屋，原来是特感太菜了啊",
	"加油加油接着送，我就喜欢这些，继续",
	"对面智商就在地下19层，连魔鬼都比他们聪明",
	"就这？就这？就这？"
};

char g_sBoomerPopTaunts[][128] =
{
	"什么sb胖子",
	"我打死了新手胖子?不会吧会不会?"
};

char g_sBoomerVomitTaunts[][128] =
{
	"什么sb玩意都能被我电脑喷到?"
};

char g_sTankRockTaunts[][128] =
{
	"好吃，真好吃",
	"你是饿了吗，这么急着找屎吃？",
	"%N别吃了别吃了，吃不下了都",
	"没吃饭吗？",
	"这个饼真香啊，让你都要去恰一恰",
	"别看了，别看了，赶紧卡控去吧，傻逼",
	"弱智，你TMD去躲着会死吗？",
	"又吃了个饼，真棒呢~ 再多吃点啊~",
	"说吧，对面给了你多少钱？",
	"你是不是腿脚不利索啊？",
	"下一届大胃王比赛没你我不看",
	"打不中就躲着嘛，恰饼干嘛？",
	"？",
	"我滚你妈的",
	"对面控制条被这傻逼回满了",
	"He Will He Will Rock You！",
	"我请你吃饭，你不要再吃饼了啦",
	"你这不随机硬辩一波？",
	"吃了几个了，嗨搁那吃吃吃呢",
	"咋不吃死你呢",
	"对面得亏碰到了这铁脑瘫",
	"走位，走位，欸嘿",
	"答应我，不要再吃了好不好",
	"绝对弱智，实属傻逼",
	"这石头你能吃到，你这是在地下十八层呢",
	"小老板很皮哦",
	"白给少年他来了"
};

char g_sTankHitTaunts[][128] =
{
	"好家伙，我个电脑Tank都能砸中你，你反思下",
	"全垒打！",
	"吃我跟踪石头！",
	"能吃上我电脑的石头，你不是一个人",
	"哇塞",
	"WoW，我竟然扔中人了",
	"Cyka Blyat！",
	"Idi Nahui!",
	"握着我的抱枕~",
	"OH Shit",
	"黑人抬走",
	"我要再砸十个！",
	"好球",
	"你听听这声，多完美啊",
	"Rock You！",
	"C U Again!",
	"只因我刚好遇见你~",
	"我没想到，你会因为我吃了石头~",
	"第一天，第一次呼吸畅快~",
	"吼吼哈嘿~"
};

char g_sCarAlarmTaunts[][128] =
{
	"你打你马警报呢",
	"我把你妈杀了，咋把警报打了",
	"%N，别打了别打了",
	"你牛逼，能打警报",
	"SB东西，给爷爬",
	"这60秒的警报你来负责，我们在旁边看戏",
	"要不是我打人没友伤，你早就倒了",
	"快滚吧，别玩了"
};

char g_sHunterPounceTaunts[][128] =
{
	"好家伙，我个电脑Hunter都能扑中你，你反思下",
	"没想到，我电脑Hunter也有扑中人的一天",
	"感谢老哥帮我实现扑中人的愿望",
	"诶呀，舒服列",
	"这波啊，这波是肉蛋冲击",
	"走位，走位，欸嘿，打不着",
	"建议生还者直接自杀",
	"我这灵巧的走位帅不帅"
};

char g_sSkeetTaunts[][128] =
{
	"被我电脑空爆咯，好气哦~",
	"这个Hunter有点菜",
	"这个Hunter的轨迹堪称完美~",
	"EZ，我要打十个！",
	"这个Hunter飞的跟个憨憨一样",
	"傻逼Hunter，你别玩了",
	"这个Hunter很牛逼，牛逼在很像牛逼",
	"Boom，NiceShot！",
	"太菜了，太菜了！",
	"感谢Hunter送上的一个空爆",
	"就很舒服，欸嘿",
	"你看看你像话吗",
	"没有劲！这么直飞还想要来高扑！",
	"WA，我可真厉害"
};

char g_sSkeetMeleeTaunts[][128] =
{
	"被我电脑近战空爆咯，好气哦~",
	"这个Hunter有点菜，我拿近战都能打死他",
	"这个Hunter的轨迹堪称完美~",
	"好家伙，这Hunter直接撞我近战上",
	"Nice Melee-skeet！",
	"好好反思你为什么会被电脑近战空爆",
	"白嫖25分爽到",
	"这个Hunter太憨了"
};

char g_sSkeetMeleeHurtTaunts[][128] =
{
	"被我电脑近战空爆咯，好气哦~",
	"这个Hunter有点菜，我拿近战都能打死他",
	"这个Hunter的轨迹堪称完美~",
	"好家伙，这Hunter直接撞我近战上",
	"Nice Melee-skeet！",
	"好好反思你为什么会被电脑近战空爆",
	"白嫖25分爽到",
	"这个Hunter太憨了"
};

char g_sSkeetSniperTaunts[][128] =
{
	"被我电脑爆头空爆咯，好气哦~",
	"这个Hunter有点菜",
	"这个Hunter的轨迹堪称完美~",
	"Nice！！！",
	"看看我这自瞄，吴姐！",
	"这个Hunter飞的太常规了！",
	"来嘛，来嘛！",
	"Boom，HeadShot！"
};

char g_sSkeetSniperHurtTaunts[][128] =
{
	"被我电脑爆头空爆咯，好气哦~",
	"这个Hunter有点菜",
	"这个Hunter的轨迹堪称完美~",
	"Nice！！！",
	"看看我这自瞄，吴姐！",
	"这个Hunter飞的太常规了！",
	"来嘛，来嘛！",
	"Boom，HeadShot！"
};

char g_sHunterDeadstopTaunts[][128] =
{
	"被我电脑推掉咯，好气哦~",
	"随手一推，Hunter白飞",
	"看看我这反应，把Hunter都推掉了",
	"小Hunter，再飞一个看看",
	"别飞了，别飞了，我一手就把你整下来了",
	"你的飞扑很精彩，我的推特更牛逼",
	"我要推十个！",
	"Bye~See yar Later~",
	"再强的Hunter在我的推下也得甘拜下风",
	"听说你想要25？",
	"我可真是太牛了",
	"这不把对面推翻天？"
};

char g_sFriendlyFireTaunts[][128] =
{
	"会不会开枪啊？",
	"CNMD打的是友军！",
	"TMD，快停火！",
	"你是不是眼睛有点问题？",
	"不会用枪建议不要拿枪",
	"别打了，别打了，爸爸疼",
	"你的子弹完美的划过曲线，击中了友军",
	"把你那子弹打在丧尸上而不是我！！"
};

char g_sHealTaunts[][128] =
{
	"我谢谢你哦，给电脑打包真奢侈",
	"滚蛋滚蛋，我稀罕你那破包？",
	"不用了不用了，真不用了",
	"你是不是按错键了？",
	"大哥大哥，不至于不至于",
	"我惊了，当儿子的竟然会给爸爸打包",
	"你这包还不如给你自己用",
	"拜托，我只是个电脑人，没那必要",
	"请把包留给有需要的人，谢谢",
	"推脱几下，BALABALA，好了快打包吧",
	"感谢这个生还者送上的急救包",
	"看我生龙活虎虐翻对面"
};

char g_sHighPounceTaunts[][128] =
{
	"看看天上吧，弱智",
	"好家伙，直接被砸了个25",
	"%N您可光心关心四周吧",
	"真好看，真好看",
	"你是弱智吗？这个Hunter都搞不定",
	"不会看路直接把眼睛扣下来",
	"又被砸了个25呢，真棒呢~ 再被多砸点啊~",
	"SB",
	"Hunter在天上，不是地上！",
	"埋了吧，没救了",
	"这波我看你怎么解释",
	"司马玩意，滚"
};

char g_sRescuedTaunts[][128] =
{
	"太弱太弱，就这？就这？",
	"好家伙，我狂吃十大碗饭",
	"特感太菜了，救援都上了，超分了咯",
	"小葱拌豆腐，轻轻松松",
	"弱智特感滚回去玩你的战役吧",
	"傻逼特感，给爷爬"
};

char g_sWitchTaunts[][128] =
{
	"大哥会不会秒妹？",
	"NMLGBD",
	"我都秒不掉你去死吧",
	"走位，走位，欸嘿，来一爪",
	"哇塞",
	"好活，整的挺好",
	"你别拿你那破枪了",
	"Idi Nahui!",
	"握着我的抱枕~",
	"OH Shit",
	"黑人抬走",
	"你打的是个什么JB~",
	"SB东西，给爷死",
	"听说秒妹都不会的人脑壳都有点问题哦",
	"我拿喷子都比你会秒妹",
	"这波啊，这波是秒妹失败",
	"你脑子有点问题，不过别担心，我给你P好了",
	"整活带屎",
	"NMMDW",
	"全体起立！",
	"你可以去死了",
	"想想你的队伍，怎么会出了你这么一个弱智",
	"秒妹都整不明白，你滚蛋吧",
	"还别说，你挺厉害的",
	"不是把啊Sir，这都秒不掉",
	"Cyka Blyat！",
	"我替你队友说一句，WCNM",
	"绝对弱智，实属傻逼，人间极品，康复脑瘫",
	"不会秒妹就不要秒妹",
	"我服了你了",
	"你这表现放我这里你可以死114514回了",
	"是谁，在敲打我窗",
	"我直接一抓把你这个憨批打飞",
	"不好意思，刚刚把你妈打没了，请见谅",
	"因为机枪秒不掉妹所以UZI不行",
	"魔兽世界！这也秒不掉！",
	"好送",
	"不会吧，真有人连妹子都秒不掉吧",
	"wwwwwwwww",
	"(*^_^*)",
	"Cool",
	"弱智",
	"傻逼",
	"脑瘫",
	"丢人，你给我退出服务器！",
	"你妈死了",
	"你打你妈呢",
	"GGWP",
	"嗯哼，嗯哼",
	"替你的队伍感到担心，居然有智障"
};

// ===== 工具函数 =====

bool IsValidPlayer(int client)
{
	return 0 < client && client <= MaxClients && IsClientConnected(client) && IsClientInGame(client);
}

bool IsWitch(int entity)
{
	if (!IsValidEntity(entity))
		return false;

	char classname[24];
	GetEdictClassname(entity, classname, sizeof(classname));
	return strcmp(classname, "witch") == 0;
}

bool isPlayerIncap(int client)
{
	return GetEntProp(client, Prop_Send, "m_isIncapacitated") != 0;
}

// 该类型嘲讽是否已过冷却（30 秒），过了则刷新冷却时间
bool CanTaunt(TauntType type)
{
	if (GetGameTime() - g_fLastTaunt[type] < TAUNT_COOLDOWN)
		return false;
	g_fLastTaunt[type] = GetGameTime();
	return true;
}

// 从数组中随机取一句并广播（带 [BOT] 前缀）
// prefix 为空时用 %N 玩家名，否则用类名（Tank/Hunter/Witch/Boomer）
void SayBotTaunt(TauntType type, int client, const char[][] taunts, int count, const char[] prefix = "")
{
	if (!CanTaunt(type))
		return;

	Format(g_sBotChat, sizeof(g_sBotChat), taunts[GetRandomInt(0, count - 1)], client);
	if (prefix[0] == 0)
		CPrintToChatAll("{blue}[BOT]%N{default} :  %s", client, g_sBotChat);
	else
		CPrintToChatAll("{red}[BOT]%s{default} :  %s", prefix, g_sBotChat);
}

// 随机挑一个生还者BOT，没有则返回 -1
int GetRandomSurvivorBot()
{
	int bots[MAXPLAYERS + 1];
	int count;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && IsFakeClient(i) && GetClientTeam(i) == 2)
			bots[count++] = i;
	}
	if (!count)
		return -1;
	return bots[GetRandomInt(0, count - 1)];
}

// ===== 插件信息 =====

public Plugin myinfo =
{
	name = "L4D2 Bot Troll & Tank Sound",
	author = "Blazers Team",
	description = "Bot is now taunt?",
	version = "1.0",
	url = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	g_bLateLoad = late;
	return APLRes_Success;
}

public void OnPluginStart()
{
	HookEvent("survivor_rescued", SurvivorRescued);
	HookEvent("player_incapacitated", PlayerIncap);
	HookEvent("door_close", DoorClose);
	HookEvent("lunge_pounce", HunterCapped);
	HookEvent("player_entered_checkpoint", OnReachSafe);
	HookEvent("door_open", DoorOpen);
	HookEvent("friendly_fire", FriendlyFire);
	HookEvent("heal_begin", HealBegin);
	HookEvent("round_start", OnRoundStart);

	if (g_bLateLoad)
	{
		for (int client = 1; client <= MaxClients; client++)
		{
			if (IsClientInGame(client))
				SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamageByWitch);
		}
	}
}

public void OnRoundStart(Event event, const char[] name, bool dontBroadcast)
{
	g_bIsRoundEnd = false;
	g_bDoorClosed = false;
}

public void OnClientPostAdminCheck(int client)
{
	SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamageByWitch);
}

public void OnClientDisconnect(int client)
{
	SDKUnhook(client, SDKHook_OnTakeDamage, OnTakeDamageByWitch);
}

// ===== 事件回调 =====

public void OnReachSafe(Event event, const char[] name, bool dontBroadcast)
{
	g_bIsRoundEnd = true;
}

public void PlayerIncap(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (IsValidPlayer(client) && GetClientTeam(client) == 2 && !IsFakeClient(client))
	{
		int bot = GetRandomSurvivorBot();
		if (bot != -1)
			SayBotTaunt(TAUNT_INCAP, client, g_sIncapTaunts, sizeof(g_sIncapTaunts) / sizeof(g_sIncapTaunts[]));
	}
}

public void DoorOpen(Event event, const char[] name, bool dontBroadcast)
{
	if (GetEventBool(event, "checkpoint"))
		g_bDoorClosed = false;
}

public void DoorClose(Event event, const char[] name, bool dontBroadcast)
{
	if (GetEventBool(event, "checkpoint") && g_bIsRoundEnd && !g_bDoorClosed)
	{
		g_bDoorClosed = true;
		int bot = GetRandomSurvivorBot();
		if (bot != -1)
			SayBotTaunt(TAUNT_DOOR_CLOSE, bot, g_sDoorCloseTaunts, sizeof(g_sDoorCloseTaunts) / sizeof(g_sDoorCloseTaunts[]));
	}
}

public void OnBoomerPop(int survivor, int boomer, int shoveCount, float timeAlive)
{
	if (IsValidPlayer(survivor) && IsValidPlayer(boomer) && !IsFakeClient(survivor) && IsFakeClient(boomer))
		SayBotTaunt(TAUNT_BOOMER_POP, boomer, g_sBoomerPopTaunts, sizeof(g_sBoomerPopTaunts) / sizeof(g_sBoomerPopTaunts[]), "Boomer");
}

public void OnBoomerVomitLanded(int boomer, int amount)
{
	if (IsValidPlayer(boomer) && IsFakeClient(boomer) && amount > 0)
		SayBotTaunt(TAUNT_BOOMER_VOMIT, boomer, g_sBoomerVomitTaunts, sizeof(g_sBoomerVomitTaunts) / sizeof(g_sBoomerVomitTaunts[]), "Boomer");
}

public void OnTankRockEaten(int tank, int survivor)
{
	// 生还者BOT嘲讽吃到石头的真人
	if (IsValidPlayer(tank) && IsValidPlayer(survivor) && !IsFakeClient(survivor))
	{
		int bot = GetRandomSurvivorBot();
		if (bot != -1)
			SayBotTaunt(TAUNT_TANK_ROCK, survivor, g_sTankRockTaunts, sizeof(g_sTankRockTaunts) / sizeof(g_sTankRockTaunts[]));
	}
	// TankBOT砸中真人
	if (IsValidPlayer(tank) && IsFakeClient(tank) && IsValidPlayer(survivor) && !IsFakeClient(survivor))
		SayBotTaunt(TAUNT_TANK_HIT, tank, g_sTankHitTaunts, sizeof(g_sTankHitTaunts) / sizeof(g_sTankHitTaunts[]), "Tank");
}

public void OnCarAlarmTriggered(int survivor, int infected, CarAlarmTriggerReason reason)
{
	if (IsValidPlayer(survivor) && !IsFakeClient(survivor))
	{
		int bot = GetRandomSurvivorBot();
		if (bot != -1)
			SayBotTaunt(TAUNT_CAR_ALARM, survivor, g_sCarAlarmTaunts, sizeof(g_sCarAlarmTaunts) / sizeof(g_sCarAlarmTaunts[]));
	}
}

public void HunterCapped(Event event, const char[] name, bool dontBroadcast)
{
	int hunter = GetClientOfUserId(GetEventInt(event, "userid"));
	int victim = GetClientOfUserId(GetEventInt(event, "victim"));

	if (IsValidPlayer(hunter) && IsValidPlayer(victim) && IsFakeClient(hunter) && !IsFakeClient(victim))
		SayBotTaunt(TAUNT_HUNTER_POUNCE, hunter, g_sHunterPounceTaunts, sizeof(g_sHunterPounceTaunts) / sizeof(g_sHunterPounceTaunts[]), "Hunter");
}

public void OnSkeet(int survivor, int hunter)
{
	if (IsValidPlayer(survivor) && IsValidPlayer(hunter) && IsFakeClient(survivor) && GetClientTeam(survivor) == 2 && !IsFakeClient(hunter))
		SayBotTaunt(TAUNT_SKEET, survivor, g_sSkeetTaunts, sizeof(g_sSkeetTaunts) / sizeof(g_sSkeetTaunts[]));
}

public void OnSkeetMelee(int survivor, int hunter)
{
	if (IsValidPlayer(survivor) && IsValidPlayer(hunter) && IsFakeClient(survivor) && GetClientTeam(survivor) == 2 && !IsFakeClient(hunter))
		SayBotTaunt(TAUNT_SKEET_MELEE, survivor, g_sSkeetMeleeTaunts, sizeof(g_sSkeetMeleeTaunts) / sizeof(g_sSkeetMeleeTaunts[]));
}

public void OnSkeetMeleeHurt(int survivor, int hunter, int damage, bool isOverkill)
{
	if (IsValidPlayer(survivor) && IsValidPlayer(hunter) && IsFakeClient(survivor) && GetClientTeam(survivor) == 2 && !IsFakeClient(hunter))
		SayBotTaunt(TAUNT_SKEET_MELEE_HURT, survivor, g_sSkeetMeleeHurtTaunts, sizeof(g_sSkeetMeleeHurtTaunts) / sizeof(g_sSkeetMeleeHurtTaunts[]));
}

public void OnSkeetSniper(int survivor, int hunter)
{
	if (IsValidPlayer(survivor) && IsValidPlayer(hunter) && IsFakeClient(survivor) && GetClientTeam(survivor) == 2 && !IsFakeClient(hunter))
		SayBotTaunt(TAUNT_SKEET_SNIPER, survivor, g_sSkeetSniperTaunts, sizeof(g_sSkeetSniperTaunts) / sizeof(g_sSkeetSniperTaunts[]));
}

public void OnSkeetSniperHurt(int survivor, int hunter, int damage, bool isOverkill)
{
	if (IsValidPlayer(survivor) && IsValidPlayer(hunter) && IsFakeClient(survivor) && GetClientTeam(survivor) == 2 && !IsFakeClient(hunter))
		SayBotTaunt(TAUNT_SKEET_SNIPER_HURT, survivor, g_sSkeetSniperHurtTaunts, sizeof(g_sSkeetSniperHurtTaunts) / sizeof(g_sSkeetSniperHurtTaunts[]));
}

public void OnHunterDeadstop(int survivor, int hunter)
{
	if (IsValidPlayer(survivor) && IsValidPlayer(hunter) && IsFakeClient(survivor) && GetClientTeam(survivor) == 2 && !IsFakeClient(hunter))
		SayBotTaunt(TAUNT_HUNTER_DEADSTOP, survivor, g_sHunterDeadstopTaunts, sizeof(g_sHunterDeadstopTaunts) / sizeof(g_sHunterDeadstopTaunts[]));
}

public void OnHunterHighPounce(int hunter, int survivor, int actualDamage, float calculatedDamage, float height, bool reportedHigh)
{
	if (IsValidPlayer(hunter) && IsValidPlayer(survivor) && !IsFakeClient(survivor) && height > 400.0)
	{
		int bot = GetRandomSurvivorBot();
		if (bot != -1)
			SayBotTaunt(TAUNT_HIGH_POUNCE, survivor, g_sHighPounceTaunts, sizeof(g_sHighPounceTaunts) / sizeof(g_sHighPounceTaunts[]));
	}
}

public void SurvivorRescued(Event event, const char[] name, bool dontBroadcast)
{
	int bot = GetRandomSurvivorBot();
	if (bot != -1)
		SayBotTaunt(TAUNT_RESCUED, bot, g_sRescuedTaunts, sizeof(g_sRescuedTaunts) / sizeof(g_sRescuedTaunts[]));
}

public void FriendlyFire(Event event, const char[] name, bool dontBroadcast)
{
	int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
	int victim = GetClientOfUserId(GetEventInt(event, "victim"));
	if (IsValidPlayer(attacker) && IsValidPlayer(victim) && !IsFakeClient(attacker) && IsFakeClient(victim) && GetClientTeam(victim) == 2)
		SayBotTaunt(TAUNT_FRIENDLY_FIRE, victim, g_sFriendlyFireTaunts, sizeof(g_sFriendlyFireTaunts) / sizeof(g_sFriendlyFireTaunts[]));
}

public void HealBegin(Event event, const char[] name, bool dontBroadcast)
{
	int healer = GetClientOfUserId(GetEventInt(event, "userid"));
	int victim = GetClientOfUserId(GetEventInt(event, "subject"));
	if (IsValidPlayer(healer) && IsValidPlayer(victim) && !IsFakeClient(healer) && IsFakeClient(victim) && GetClientTeam(victim) == 2)
		SayBotTaunt(TAUNT_HEAL, victim, g_sHealTaunts, sizeof(g_sHealTaunts) / sizeof(g_sHealTaunts[]));
}

public Action OnTakeDamageByWitch(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
	if (IsValidPlayer(victim) && !IsFakeClient(victim) && IsWitch(attacker) && !isPlayerIncap(victim))
		SayBotTaunt(TAUNT_WITCH, victim, g_sWitchTaunts, sizeof(g_sWitchTaunts) / sizeof(g_sWitchTaunts[]), "Witch");

	return Plugin_Continue;
}
