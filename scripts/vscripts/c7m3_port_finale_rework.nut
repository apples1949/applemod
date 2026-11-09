//-----------------------------------------------------
// This script handles the logic for the Port / Bridge
// finale in the River Campaign. 
//
//-----------------------------------------------------
Msg("Initiating c7m3_port_finale rework script\n");

//-----------------------------------------------------
// 12v12(applemod12v12)改动说明 —— 2026-11
//
// 1) 三个 TANK 阶段(第 2/5/7 阶段)在 12v12 下每个同时刷 3 辆坦克:
//      机制 = DirectorOptions 的 A_CustomFinaleValueX 在 TANK 阶段就是"刷几辆"
//             (Valve wiki: TANK | 1 | Spawn tank(s), with the value as the number of tanks
//              to spawn), 这个值优先于任何坦克数量 cvar, 光调 TankLimit 没用;
//      配套 = TankLimit / cm_TankLimit >= 3("同时在场坦克上限"; cm_ 键优先级更高,
//             被别处写成 1 时会压住 TankLimit)。
//    12v12 判定用 survivor_limit >= 12, 非 12v12 完全保持原样(每阶段 1 辆)。
//
// 2) "第 3 个坦克不刷" 的核对结论(脚本侧):
//      - 本脚本没有硬编码"只刷 2 辆"的计数; 三个阶段号 2/5/7 都是 TANK, 每次进阶段由
//        director 按 A_CustomFinaleValueX 刷车, 阶段值原本全是 1(所以本来就只有 1 辆/阶段);
//      - 阶段推进靠 GeneratorButtonPressed + Update(): 第 4 阶段的按键会连推两次
//        (4 -> 5 -> 6), 第 6 阶段(DELAY 9999)靠 QueuedDelayAdvances 自动前进到第 7 阶段,
//        这条链路本身能到第 7 阶段(TANK);
//      - 因此"第 3 辆不刷"更可能来自脚本以外: 见下.
//
// 3) 需要到服务器上核对的外部因素(本脚本动不了):
//      a) cfg/stripper/applemod12v12/maps/c7m3_port.cfg 给 bridge_start_button 加了
//         OnPressed -> relay_outro_start:Trigger. 这个按钮正是推进终局阶段用的那颗,
//         按键同时触发 outro 中继, 可能让终局提前进入 escape, 第 7 阶段的坦克就没了;
//      b) confogl_remove_escape_tank 1 (applemod12v12/shared_cvars.cfg:33) 会移除
//         "救援车到达时刷出来的坦克", 如果第 3 辆被算成 escape tank 就会被删;
//      c) 其它脚本/模式是否把 DirectorOptions.TankLimit / cm_TankLimit 改回 1
//         (阶段开始时会打印 expect N 的日志, 用 director_debug 1 对照实际数量).
//-----------------------------------------------------


//-----------------------------------------------------
ERROR		<- -1
PANIC 		<- 0
TANK 		<- 1
DELAY 		<- 2

//-----------------------------------------------------

// This keeps track of the number of times the generator button has been pressed. 
// Init to 1, since one button press has been used to start the finale and run 
// this script. 
ButtonPressCount <- 1

// This stores the stage number that we last
// played the "Press the Button!" VO
LastVOButtonStageNumber <- 0

// We use this to keep from running a bunch of queued advances really quickly. 
// Init to true because we are starting a finale from a button press in the pre-finale script 
// see GeneratorButtonPressed in c7m3_port.nut
PendingWaitAdvance <- true	

// We use three generator button presses to push through
// 8 stages. We have to queue up state advances
// depending on the state of the finale when buttons are pressed
QueuedDelayAdvances <- 0


// Tracking current finale states
CurrentFinaleStageNumber <- ERROR
CurrentFinaleStageType <- ERROR

// The finale is 3 phases. 
// We randomize the event types in the first two
local RandomFinaleStage1 = 0
local RandomFinaleStage2 = 0
local RandomFinaleStage4 = 0
local RandomFinaleStage5 = 0

// PHASE 1 EVENTS
// Rework - remove the RNG from the event, make horde always spawn before a tank
RandomFinaleStage1 = PANIC
RandomFinaleStage2 = TANK
RandomFinaleStage4 = PANIC
RandomFinaleStage5 = TANK


// We want to give the survivors a little of extra time to 
// get on their feet before the escape, since you have to fight through 
// the sacrifice.

PreEscapeDelay <- 0
if ( Director.GetGameModeBase() == "coop" || Director.GetGameModeBase() == "realism" )
{
	PreEscapeDelay <- 5
}
else if ( Director.GetGameModeBase() == "versus" )
{
	PreEscapeDelay <- 15
}

//-----------------------------------------------------
// 12v12(多人配置)判定 —— 与 c14m2_lighthouse_finale.nut / c1m4_atrium.nut 同款做法:
//   读游戏自己的 survivor_limit(12v12 配置设 12, 4v4 是 4),
//   不用 l4d_superversus 的 l4d_survivor_limit(那个默认就是 12, 插件卸载后值还会留着,
//   会把 4v4 误判成多人)。
//   注意: L4D2 的 Convars 表只有 SetValue / GetStr / GetFloat / GetClientConvarValue,
//   没有 GetInt(用 GetInt 会报 "the index 'GetInt' does not exist", 整份脚本作废)。
//   用 root 表槽位(<-)而不是 local, 保证后面的 OnBeginCustomFinaleStage() 能读到。
//-----------------------------------------------------
local survivorLimit = Convars.GetFloat( "survivor_limit" );
bIs12v12 <- ( survivorLimit != null && survivorLimit >= 12 );

// 每个 TANK 阶段同时刷几个坦克。
//   A_CustomFinaleValueX 在 TANK 阶段就是"刷几辆坦克"(Valve wiki: TANK | 1 | Spawn tank(s),
//   with the value as the number of tanks to spawn) —— 它优先于任何坦克数量 cvar,
//   所以想让 12v12 同时出现 3 辆坦克, 必须改这里, 光调 TankLimit 没用。
//   非 12v12 保持原样(1), 不动 4v4/战役的平衡。
//   同样用 root 表槽位: 后面 OnBeginCustomFinaleStage() 里要读。
TanksPerTankStage <- 1
if ( bIs12v12 )
{
	TanksPerTankStage = 3
}

DirectorOptions <-
{	
	 
	A_CustomFinale_StageCount = 8
	 
	// PHASE 1
	A_CustomFinale1 = RandomFinaleStage1
	A_CustomFinaleValue1 = 1
	A_CustomFinale2 = RandomFinaleStage2
	A_CustomFinaleValue2 = TanksPerTankStage
	A_CustomFinale3 = DELAY
	A_CustomFinaleValue3 = 9999
	
	
	// PHASE 2
	A_CustomFinale4 = RandomFinaleStage4
	A_CustomFinaleValue4 = 1
	A_CustomFinale5 = RandomFinaleStage5
	A_CustomFinaleValue5 = TanksPerTankStage	
	A_CustomFinale6 = DELAY
	A_CustomFinaleValue6 = 9999 	 
	
	
	// PHASE 3
	A_CustomFinale7 = TANK
	A_CustomFinaleValue7 = TanksPerTankStage	 	 		 
	A_CustomFinale8 = DELAY
	A_CustomFinaleValue8 = PreEscapeDelay
	 
	 
	 
	TankLimit = 4
	WitchLimit = 0
	CommonLimit = 20	
	HordeEscapeCommonLimit = 15	
	EscapeSpawnTanks = false
	//SpecialRespawnInterval = 80

}

//-----------------------------------------------------
// 12v12: 同时在场的坦克上限
//   TankLimit = "同时在场的坦克上限"(Valve wiki: Maximum number of Tanks allowed to be in play
//   simultaneously, 默认 -1 = 不限制)。脚本原本写 4, 12v12 要"同时 3 辆"就必须不小于 3。
//   cm_TankLimit 的优先级高于 TankLimit(cm_ 系列键覆盖同名普通键), 有些模式/变更脚本会把它
//   写成 1, 那样阶段值写 3 也只会有 1 辆 —— 12v12 下两个键一起显式抬高, 免得被别处的键压住。
//   非 12v12 完全不动(仍然是阶段值 1)。
//-----------------------------------------------------
if ( bIs12v12 )
{
	DirectorOptions.TankLimit = 4
	DirectorOptions.cm_TankLimit <- 4
	Msg( " 12v12: c7m3 tank stage -> " + TanksPerTankStage + " tanks at once (TankLimit/cm_TankLimit = 4) \n" );
}


function OnBeginCustomFinaleStage( num, type )
{
	printl( "*!* Beginning custom finale stage " + num + " of type " + type );
	printl( "*!* PendingWaitAdvance " + PendingWaitAdvance + ", QueuedDelayAdvances " + QueuedDelayAdvances );
	
	// Store off the state... 
	CurrentFinaleStageNumber = num
	CurrentFinaleStageType = type
	
	// 12v12: 每进一次 TANK 阶段都再确认一次"同时在场的坦克上限", 并打印预期数量。
	//   DirectorOptions 在阶段切换时可能被别的脚本/模式重写, 只在文件开头赋一次不够稳;
	//   而 A_CustomFinaleValueX 是阶段开始时才读的, 数量写在表里就够。
	//   排查"第 3 个坦克不刷"时看这行日志: 能看到预期 3 辆, 实际数量用 director_debug 1 看。
	if ( type == TANK && bIs12v12 )
	{
		DirectorOptions.TankLimit = 4
		DirectorOptions.cm_TankLimit <- 4
		Msg( " 12v12: tank stage " + num + " -> expect " + TanksPerTankStage + " tanks at once \n" );
	}
	
	// Acknowledge the state advance
	PendingWaitAdvance = false
}


function GeneratorButtonPressed()
{
    printl( "*!* GeneratorButtonPressed finale stage " + CurrentFinaleStageNumber + " of type " +CurrentFinaleStageType );
	printl( "*!* PendingWaitAdvance " + PendingWaitAdvance + ", QueuedDelayAdvances " + QueuedDelayAdvances );
	
	
	ButtonPressCount++
	
	
	local ImmediateAdvances = 0
	
	
	if ( CurrentFinaleStageNumber == 1 || CurrentFinaleStageNumber == 4 )
	{		
		// First stage of a phase, so next stage is an "action" stage too.
		// Advance to next action stage, and then queue an advance to the 
		// next delay.
		QueuedDelayAdvances++
		ImmediateAdvances = 1
	}
	else if ( CurrentFinaleStageNumber == 2 || CurrentFinaleStageNumber == 5 )
	{
		// Second stage of a phase, so next stage is a "delay" stage.
		// We need to immediately advance past the delay and into an action state. 
		
		//QueuedDelayAdvances++	// NOPE!
		ImmediateAdvances = 2
	}
	else if ( CurrentFinaleStageNumber == 3 || CurrentFinaleStageNumber == 6 )
	{
		// Wait states... (very long delay)
		// Advance immediately into an action state
		
		//QueuedDelayAdvances++
		ImmediateAdvances = 1
	}
	else if ( CurrentFinaleStageNumber == -1 || 
              CurrentFinaleStageNumber == 0 )
	{
		// the finale is *just* about to start... 
		// we can get this if all the buttons are hit at once at the beginning
		// Just queue a wait advance
		QueuedDelayAdvances++
		ImmediateAdvances = 0
	}
	else
	{
		printl( "*!* Unhandled generator button press! " );
	}

	if ( ImmediateAdvances > 0 )
	{	
		EntFire( "generator_start_model", "Enable" )
		
		
		if ( ImmediateAdvances == 1 )
		{
			printl( "*!* GeneratorButtonPressed Advancing State ONCE");
			EntFire( "generator_start_model", "AdvanceFinaleState" )
		}
		else if ( ImmediateAdvances == 2 )
		{
			printl( "*!* GeneratorButtonPressed Advancing State TWICE");
			EntFire( "generator_start_model", "AdvanceFinaleState" )
			EntFire( "generator_start_model", "AdvanceFinaleState" )
		}
		
		EntFire( "generator_start_model", "Disable" )
		
		PendingWaitAdvance = true
	}
	
}

function Update()
{
	// Should we advance the finale state?
	// 1. If we're in a DELAY state
	// 2. And we have queued advances.... 
	// 3. And we haven't just tried to advance the advance the state.... 
	if ( CurrentFinaleStageType == DELAY && QueuedDelayAdvances > 0 && !PendingWaitAdvance )
	{
		// If things are calm (relatively), jump to the next state
		if ( !Director.IsTankInPlay() && !Director.IsAnySurvivorInCombat() )
		{
			if ( Director.GetPendingMobCount() < 1 && Director.GetCommonInfectedCount() < 5 )
			{
				printl( "*!* Update Advancing State finale stage " + CurrentFinaleStageNumber + " of type " +CurrentFinaleStageType );
				printl( "*!* PendingWaitAdvance " + PendingWaitAdvance + ", QueuedDelayAdvances " + QueuedDelayAdvances );
		
				QueuedDelayAdvances--
				EntFire( "generator_start_model", "Enable" )
				EntFire( "generator_start_model", "AdvanceFinaleState" )
				EntFire( "generator_start_model", "Disable" )
				PendingWaitAdvance = true
			}
		}
	}
	
	// Should we fire the director event to play the "Press the button!" Nag VO?	
	// If we're on an infinite delay stage...
	if ( CurrentFinaleStageType == DELAY && CurrentFinaleStageNumber > 1 && CurrentFinaleStageNumber < 7 )	
	{		
		// 1. We haven't nagged for this stage yet
		// 2. There are button presses remaining
		if ( CurrentFinaleStageNumber != LastVOButtonStageNumber && ButtonPressCount < 3 )
		{
			// We're not about to process a wait advance..
			if ( QueuedDelayAdvances == 0 && !PendingWaitAdvance )
			{
				// If things are pretty calm, run the event
				if ( Director.GetPendingMobCount() < 1 && Director.GetCommonInfectedCount() < 1 )
				{
					if ( !Director.IsTankInPlay() && !Director.IsAnySurvivorInCombat() )
					{
						printl( "*!* Update firing event 1 (VO Prompt)" )
						LastVOButtonStageNumber = CurrentFinaleStageNumber
						Director.UserDefinedEvent1()
					}
				}
			}
		}
	}
	
}


function EnableEscapeTanks()
{
	printl( "*!* EnableEscapeTanks finale stage " + CurrentFinaleStageNumber + " of type " +CurrentFinaleStageType );
	
	//Msg( "\n*****\nMapScript.DirectorOptions:\n" );
	//foreach( key, value in MapScript.DirectorOptions )
	//{
	//	Msg( "    " + key + " = " + value + "\n" );
	//}

	MapScript.DirectorOptions.EscapeSpawnTanks <- true
}
