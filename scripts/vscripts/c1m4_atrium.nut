// c1m4_atrium.nut  --  copy of the stock map script, with the can count made
// configurable for the 12v12 server.
//
// Stock script (decompiled) is:
//     Msg(" atrium map script ")
//     if ( Director.IsSinglePlayerGame() ) { NumCansNeeded <- 8 }
//     else                                 { NumCansNeeded <- 13 }
//     DirectorOptions <- { CommonLimit = 15 }
//     NavMesh.UnblockRescueVehicleNav()
//     EntFire( "progress_display", "SetTotalItems", NumCansNeeded )
//     function GasCanPoured(){}
//
// Why this file matters: the HUD denominator of the Dead Center finale is the
// netprop m_nTotalScavengeItems on entity progress_display
// (game_scavenge_progress_display); it is NOT stored in the BSP (the BSP only
// has "max" "1", which is exactly what you see when this script dies early:
// the HUD falls back to 1). The stock script above is what writes 13 into it
// at map load, so overriding this file is the clean way to change it.
//
// ORDERING RULE (learned the hard way): Squirrel aborts the WHOLE file on the
// first error, so everything essential must run BEFORE anything that could
// throw. The 12v12 block therefore sits at the very end: if the convar read
// ever fails, the map still behaves like stock (HUD 13) instead of dying.
//
// Keep this file ASCII-only.

Msg( " atrium map script (applemod12v12) " );

// number of cans needed to escape.
if ( Director.IsSinglePlayerGame() )
{
	NumCansNeeded <- 8;
}
else
{
	NumCansNeeded <- 13;
}

DirectorOptions <-
{
	CommonLimit = 15
}

NavMesh.UnblockRescueVehicleNav()

// *** essential: must run before anything risky ***
EntFire( "progress_display", "SetTotalItems", NumCansNeeded );

function GasCanPoured(){}

// ---------------------------------------------------------------------------
// 12v12 block -- last on purpose.
// 12v12 config sets survivor_limit 12; 4v4 configs keep 4.
// L4D2 vscript's Convars table only has SetValue / GetStr / GetFloat /
// GetClientConvarValue -- there is NO GetInt (that one aborted the file and
// left the HUD at 1). GetFloat returns null for a missing convar.
// ---------------------------------------------------------------------------
local sl = Convars.GetFloat( "survivor_limit" );

if ( sl != null && sl >= 12 )
{
	NumCansNeeded <- 19;
	EntFire( "progress_display", "SetTotalItems", NumCansNeeded );
	Msg( " 12v12: cans -> 19 " );
}
