#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <builtinvotes>
#include <sdktools_sound>
#include <colors>
#include <left4dhooks>
#include <sdktools>

#define MAX_STR_LEN 30
#define MIN_MIX_START_COUNT 2

#define COND_HAS_ALREADY_VOTED 0
#define COND_NEED_MORE_VOTES 1
#define COND_START_MIX 2
#define COND_START_MIX_ADMIN 3
#define COND_NO_PLAYERS 4

#define STATE_FIRST_CAPT 0
#define STATE_SECOND_CAPT 1
#define STATE_NO_MIX 2
#define STATE_PICK_TEAMS 3
#define STATE_RANDOM 4

int	currentState = STATE_NO_MIX,
	maxVoteCount = 0,
	pickCount = 0,
	survivorsPick = 0;
	
ConVar survivor_limit;

Menu mixMenu;

StringMap	hVoteResultsTrie,
			hSwapWhitelist,
			hPlayers;

char	currentMaxVotedCaptAuthId[MAX_STR_LEN],
		survCaptainAuthId[MAX_STR_LEN],
		infCaptainAuthId[MAX_STR_LEN];

bool	isMixAllowed = false,
		isPickingCaptain = false;
		
Handle	mixStartedForward,
		mixStoppedForward,
		captainVoteTimer = null,
		mixrandomTimer = null,
		hVoteMix = null,
		hVoteMixRd = null;


public Plugin myinfo =
{
    name = "L4D2 Mix Manager",
    author = "Luckylock,modified by Bred",
    description = "Provides ability to pick captains and teams through menus",
    version = "2.2",
    url = "https://github.com/LuckyServ/"
};

public void OnPluginStart()
{
	SetRandomSeed(view_as<int>(GetEngineTime()));
	survivor_limit = FindConVar("survivor_limit");
	
	RegConsoleCmd("sm_mix", Cmd_MixStart, "Mix command");
	RegConsoleCmd("sm_mixrd", Cmd_MixRdStart, "Mix command");
	RegConsoleCmd("sm_mixrandom", Cmd_MixRdStart, "Mix command");
	RegAdminCmd("sm_stopmix", Cmd_MixStop, ADMFLAG_ROOT, "Mix command");
	RegAdminCmd("sm_fmix", Admin_MixStart, ADMFLAG_ROOT, "Mix command");
	RegAdminCmd("sm_forcemix", Admin_MixStart, ADMFLAG_ROOT, "Mix command");
	
	AddCommandListener(Cmd_OnPlayerJoinTeam, "jointeam");
	
	hVoteResultsTrie = CreateTrie();
	hSwapWhitelist = CreateTrie();
	hPlayers = CreateTrie();
	
	mixStartedForward = CreateGlobalForward("OnMixStarted", ET_Event);
	mixStoppedForward = CreateGlobalForward("OnMixStopped", ET_Event);
	PrecacheSound("buttons/blip1.wav");
	
	LoadTranslations("l4d2_mix.phrases");
}

public void OnMapStart()
{
	isMixAllowed = true;
	StopMix();
}

public void OnRoundIsLive() 
{
	isMixAllowed = false;
	StopMix();
}

public void StartMix()
{
	Call_StartForward(mixStartedForward);
	Call_Finish();
	EmitSoundToAll("buttons/blip1.wav"); 
}

public void StopMix()
{
	currentState = STATE_NO_MIX;
	Call_StartForward(mixStoppedForward);
	Call_Finish();

	if (isPickingCaptain && captainVoteTimer != null) 
	{
		KillTimer(captainVoteTimer);
		captainVoteTimer = null;
	}
	
	if (mixrandomTimer != null) 
	{
		KillTimer(mixrandomTimer);
		mixrandomTimer = null;
	}
}

public Action Cmd_OnPlayerJoinTeam(int client, const char[] command, int argc)
{
	char authId[MAX_STR_LEN];
	char cmdArgBuffer[MAX_STR_LEN];
	int allowedTeam;
	int newTeam;

	if (argc >= 1) 
	{
		GetCmdArg(1, cmdArgBuffer, MAX_STR_LEN);
		newTeam = StringToInt(cmdArgBuffer);

		if (currentState != STATE_NO_MIX && newTeam != 1 && IsHuman(client)) 
		{
			GetClientAuthId(client, AuthId_SteamID64, authId, MAX_STR_LEN); 

			if (!hSwapWhitelist.GetValue(authId, allowedTeam) || allowedTeam != newTeam) 
			{
				CPrintToChat(client, "%t", "cant_join_no_pick");
				return Plugin_Stop;
			}
		}
	}
	return Plugin_Continue; 
}

public void OnClientPutInServer(int client)
{
	char authId[MAX_STR_LEN];

	if (currentState != STATE_NO_MIX && IsHuman(client))
	{
		GetClientAuthId(client, AuthId_SteamID64, authId, MAX_STR_LEN);
		ChangeClientTeamEx(client, 1);
	}
}

public Action Cmd_MixStop(int client, any args) 
{
	if (currentState != STATE_NO_MIX) 
	{
		StopMix();
		CPrintToChatAll("%t", "admin_stop", client);
	} 
	else 
	{
		CPrintToChat(client, "%t", "no_start_stop");
	}
	
	return Plugin_Continue;
}

public Action Cmd_MixStart(int client, int Args)
{
	if (StartMixVote(client))
	{
		CPrintToChatAll("%t", "pvote_to_start", client);
		//caller is voting for
		FakeClientCommand(client, "Vote Yes");
    } 
	return Plugin_Handled;
}

public Action Admin_MixStart(int client, int Args)
{
	if (currentState != STATE_NO_MIX) 
	{
		CPrintToChat(client, "%t", "start_start");
    } 
	else if (!isMixAllowed) 
	{
		CPrintToChat(client, "%t", "not_allow_round_live");
	}
	else if (survivor_limit.IntValue == 1)
	{
		CPrintToChat(client, "%t", "start_condition_1v1");
	}
	else if (!SavePlayers())
	{
		CPrintToChat(client, "%t", "start_condition", survivor_limit.IntValue * 2);
	}
	else
	{
		CPrintToChatAll("%t", "admin_start", client);
		currentState = STATE_FIRST_CAPT;
		StartMix();
		SwapAllPlayersToSpec();
		// Initialise values
		hVoteResultsTrie.Clear();
		hSwapWhitelist.Clear();
		maxVoteCount = 0;
		strcopy(currentMaxVotedCaptAuthId, MAX_STR_LEN, " ");
		pickCount = 0;

		if (Menu_Initialise()) 
		{
			Menu_AddAllSpectators();
			Menu_DisplayToAllSpecs();
		}

		captainVoteTimer = CreateTimer(20.0, Menu_StateHandler, _, TIMER_REPEAT); 
		isPickingCaptain = true;
	}
	return Plugin_Handled;
}

bool StartMixVote(int client)
{
	if (GetClientTeam(client) <= 1) 
	{
		CPrintToChat(client, "%t", "Spec_Start");
		return false;
	}
	if (currentState != STATE_NO_MIX) 
	{
		CPrintToChat(client, "%t", "start_start");
		return false;
    } 
	if (!isMixAllowed) 
	{
		CPrintToChat(client, "%t", "not_allow_round_live");
		return false;
	}
	if (survivor_limit.IntValue == 1)
	{
		CPrintToChat(client, "%t", "start_condition_1v1");
		return false;
	}
	if (!SavePlayers())
	{
		CPrintToChat(client, "%t", "start_condition", survivor_limit.IntValue * 2);
		return false;
	}
	
	if (!IsBuiltinVoteInProgress())
	{
		int iNumPlayers;
		int[] iPlayers = new int[MaxClients];
		for (int i = 1; i <= MaxClients; i++)
		{
			if (!IsHuman(i) || (GetClientTeam(i) <= 1))
			{
				continue;
			}
			iPlayers[iNumPlayers++] = i;
		}
			
		char cVoteTitle[32];
		Format(cVoteTitle, sizeof(cVoteTitle), "%T", "Vote_Tittle", LANG_SERVER);

		hVoteMix = CreateBuiltinVote(VoteMixActionHandler, BuiltinVoteType_Custom_YesNo, BuiltinVoteAction_Cancel | BuiltinVoteAction_VoteEnd | BuiltinVoteAction_End);

		SetBuiltinVoteArgument(hVoteMix, cVoteTitle);
		SetBuiltinVoteInitiator(hVoteMix, client);
		SetBuiltinVoteResultCallback(hVoteMix, VoteMixResultHandler);
		DisplayBuiltinVote(hVoteMix, iPlayers, iNumPlayers, 20);
		
		return true;
	}
	
	CPrintToChat(client, "%t", "already_vote");
	return false;
}

public void VoteMixActionHandler(Handle vote, BuiltinVoteAction action, int param1, int param2)
{
	switch (action) 
	{
		case BuiltinVoteAction_End: 
		{
			delete vote;
			hVoteMix = null;
		}
		case BuiltinVoteAction_Cancel: 
		{
			DisplayBuiltinVoteFail(vote, view_as<BuiltinVoteFailReason>(param1));
		}
	}
}

public void VoteMixResultHandler(Handle vote, int num_votes, int num_clients, const int[][] client_info, int num_items, const int[][] item_info)
{
	for (int i = 0; i < num_items; i++) {
		if (item_info[i][BUILTINVOTEINFO_ITEM_INDEX] == BUILTINVOTES_VOTE_YES) 
		{
			if (item_info[i][BUILTINVOTEINFO_ITEM_VOTES] > (num_votes / 2))
			{
				char tVotePass[32];
				Format(tVotePass, sizeof(tVotePass), "%T", "Vote_Pass_Tittle", LANG_SERVER);
				
				DisplayBuiltinVotePass(vote, tVotePass);
				
				currentState = STATE_FIRST_CAPT;
				StartMix();
				SwapAllPlayersToSpec();
				// Initialise values
				hVoteResultsTrie.Clear();
				hSwapWhitelist.Clear();
				maxVoteCount = 0;
				strcopy(currentMaxVotedCaptAuthId, MAX_STR_LEN, " ");
				pickCount = 0;

				if (Menu_Initialise()) 
				{
					Menu_AddAllSpectators();
					Menu_DisplayToAllSpecs();
				}

				captainVoteTimer = CreateTimer(20.0, Menu_StateHandler, _, TIMER_REPEAT); 
				isPickingCaptain = true;
				return;
			}
		}
	}

	DisplayBuiltinVoteFail(vote, BuiltinVoteFail_Loses);
}

// =========================================================
// =================== Mix Randomly ========================
// =========================================================

public Action Cmd_MixRdStart(int client, int Args)
{
	if (StartMixRdVote(client))
	{
		CPrintToChatAll("%t", "pvote_to_start_rd", client);
		//caller is voting for
		FakeClientCommand(client, "Vote Yes");
    } 
	return Plugin_Handled;
}

bool StartMixRdVote(int client)
{
	if (GetClientTeam(client) <= 1) 
	{
		CPrintToChat(client, "%t", "Spec_Start");
		return false;
	}
	if (currentState != STATE_NO_MIX) 
	{
		CPrintToChat(client, "%t", "start_start");
		return false;
    } 
	if (!isMixAllowed) 
	{
		CPrintToChat(client, "%t", "not_allow_round_live");
		return false;
	}
	if (survivor_limit.IntValue == 1)
	{
		CPrintToChat(client, "%t", "start_condition_1v1");
		return false;
	}
	if (!SavePlayers())
	{
		CPrintToChat(client, "%t", "start_condition", survivor_limit.IntValue * 2);
		return false;
	}
	
	if (!IsBuiltinVoteInProgress())
	{
		int iNumPlayers;
		int[] iPlayers = new int[MaxClients];
		for (int i = 1; i <= MaxClients; i++)
		{
			if (!IsHuman(i) || (GetClientTeam(i) <= 1))
			{
				continue;
			}
			iPlayers[iNumPlayers++] = i;
		}
			
		char cVoteRdTitle[32];
		Format(cVoteRdTitle, sizeof(cVoteRdTitle), "Mix randomly ?");

		hVoteMixRd = CreateBuiltinVote(VoteMixRdActionHandler, BuiltinVoteType_Custom_YesNo, BuiltinVoteAction_Cancel | BuiltinVoteAction_VoteEnd | BuiltinVoteAction_End);

		SetBuiltinVoteArgument(hVoteMixRd, cVoteRdTitle);
		SetBuiltinVoteInitiator(hVoteMixRd, client);
		SetBuiltinVoteResultCallback(hVoteMixRd, VoteMixRdResultHandler);
		DisplayBuiltinVote(hVoteMixRd, iPlayers, iNumPlayers, 20);
		
		return true;
	}
	
	CPrintToChat(client, "%t", "already_vote");
	return false;
}

public void VoteMixRdActionHandler(Handle vote, BuiltinVoteAction action, int param1, int param2)
{
	switch (action) 
	{
		case BuiltinVoteAction_End: 
		{
			delete vote;
			hVoteMixRd = null;
		}
		case BuiltinVoteAction_Cancel: 
		{
			DisplayBuiltinVoteFail(vote, view_as<BuiltinVoteFailReason>(param1));
		}
	}
}

public void VoteMixRdResultHandler(Handle vote, int num_votes, int num_clients, const int[][] client_info, int num_items, const int[][] item_info)
{
	for (int i = 0; i < num_items; i++) {
		if (item_info[i][BUILTINVOTEINFO_ITEM_INDEX] == BUILTINVOTES_VOTE_YES) 
		{
			if (item_info[i][BUILTINVOTEINFO_ITEM_VOTES] > (num_votes / 2))
			{
				char tVotePass[32];
				Format(tVotePass, sizeof(tVotePass), "%T", "Vote_Pass_Tittle", LANG_SERVER);
				
				DisplayBuiltinVotePass(vote, tVotePass);
				
				currentState = STATE_RANDOM;
				StartMix();
				SwapAllPlayersToSpec();
				
				// Initialise values
				hSwapWhitelist.Clear();
				
				CPrintToChatAll("%t", "Time_Mix_Random");
				mixrandomTimer = CreateTimer(5.0, Timer_MixRandom);
				return;
			}
		}
	}

	DisplayBuiltinVoteFail(vote, BuiltinVoteFail_Loses);
}

public Action Timer_MixRandom(Handle timer)
{
	char clientAuthId[MAX_STR_LEN];
	int teamindex;
	int surcount = 0;
	int infcount = 0;
	
	for (int client = 1; client <= MaxClients; ++client) 
	{
		if (IsHuman(client) && IsClientInPlayers(client)) 
		{
			GetClientAuthId(client, AuthId_SteamID64, clientAuthId, MAX_STR_LEN);
			if (surcount == survivor_limit.IntValue || infcount == survivor_limit.IntValue) 
			{
				surcount == survivor_limit.IntValue ? SwapPlayerToTeam(clientAuthId, 3, 0) : SwapPlayerToTeam(clientAuthId, 2, 0);
				continue;
			}
			teamindex = GetRandomInt(2, 3);
			if (SwapPlayerToTeam(clientAuthId, teamindex, 0)) teamindex == 2 ? surcount++ : infcount++;
		}  
	}
	
	StopMix();
	CPrintToChatAll("%t", "Down_Mix_Random");
	
	return Plugin_Handled;
}
	
	

public bool SavePlayers() 
{
	char clientAuthId[MAX_STR_LEN];

	ClearTrie(hPlayers);

	for (int client = 1; client <= MaxClients; client++) 
	{
		if (IsSurvivor(client) || IsInfected(client)) 
		{
			GetClientAuthId(client, AuthId_SteamID64, clientAuthId, MAX_STR_LEN);
			SetTrieValue(hPlayers, clientAuthId, true);
		}
	}
	return  GetTrieSize(hPlayers) == (survivor_limit.IntValue * 2);
}

public bool Menu_Initialise()
{
	if (currentState == STATE_NO_MIX) return false;

	mixMenu = new Menu(Menu_MixHandler, MENU_ACTIONS_ALL);
	mixMenu.ExitButton = false;

	if (currentState == STATE_FIRST_CAPT || 
		currentState == STATE_SECOND_CAPT || 
		currentState == STATE_PICK_TEAMS) 
		return true;

	CloseHandle(mixMenu);
	return false;
}

public void Menu_AddAllSpectators()
{
	char clientName[MAX_STR_LEN];
	char clientId[MAX_STR_LEN];

	mixMenu.RemoveAllItems();

	for (int client = 1; client <= MaxClients; ++client) 
	{
		if (IsClientSpec(client) && IsClientInPlayers(client)) 
		{
			GetClientAuthId(client, AuthId_SteamID64, clientId, MAX_STR_LEN);
			GetClientName(client, clientName, MAX_STR_LEN);
			mixMenu.AddItem(clientId, clientName);
		}  
	}
}

public bool IsClientInPlayers(int client) 
{
	bool dummy;
	char clientAuthId[MAX_STR_LEN];
	GetClientAuthId(client, AuthId_SteamID64, clientAuthId, MAX_STR_LEN);
	return GetTrieValue(hPlayers, clientAuthId, dummy);
}

public void Menu_AddTestSubjects()
{
	mixMenu.AddItem("test", "test");
}

public void Menu_DisplayToAllSpecs()
{
	for (int client = 1; client <= MaxClients; ++client) 
	{
		if (IsClientSpec(client) && IsClientInPlayers(client)) 
		{
			switch (currentState)
			{
				case STATE_FIRST_CAPT:
				{
					mixMenu.SetTitle("%T", "tittle_1st_cap", client);
				}
				case STATE_SECOND_CAPT:
				{
					mixMenu.SetTitle("%T", "tittle_2nd_cap", client);
				}
			}
			mixMenu.Display(client, 20);
		}
	}
}

public int Menu_MixHandler(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select) 
	{
		if (currentState == STATE_FIRST_CAPT || currentState == STATE_SECOND_CAPT) 
		{
			char authId[MAX_STR_LEN];
			menu.GetItem(param2, authId, MAX_STR_LEN);

			int voteCount = 0;

			if (!GetTrieValue(hVoteResultsTrie, authId, voteCount)) 
			{
				voteCount = 0;
			}

			SetTrieValue(hVoteResultsTrie, authId, ++voteCount, true);

			if (voteCount > maxVoteCount) 
			{
				strcopy(currentMaxVotedCaptAuthId, MAX_STR_LEN, authId);
				maxVoteCount = voteCount;
			}

        }
		else if (currentState == STATE_PICK_TEAMS)
		{
			char authId[MAX_STR_LEN]; 
			menu.GetItem(param2, authId, MAX_STR_LEN);
			int team = GetClientTeam(param1);

			if (team == 1 || (team == 3 && survivorsPick == 1) || (team == 2 && survivorsPick == 0)) 
			{
				CPrintToChatAll("%t", "wrong_team_stop", param1);
				StopMix();
            }
			else
			{
                if (SwapPlayerToTeam(authId, team, 0)) 
				{
					pickCount++;
					if (pickCount == 2 || pickCount == 4) 
					{
                        // Do not switch picks 
                    } 
					else if (	(survivor_limit.IntValue == 4 && pickCount > 5) || 
								(survivor_limit.IntValue == 3 && pickCount > 3) || 
								(survivor_limit.IntValue == 2 && pickCount > 1))
					{
						CPrintToChatAll("%t", "teams_picked");
						StopMix();
					}
					else
					{
						survivorsPick = survivorsPick == 1 ? 0 : 1;
					} 
                }
				else
				{
					CPrintToChatAll("%t", "not_found_stop", param1);
					StopMix();
				}
			}
		}
	}

	return 0;
}

public Action Menu_StateHandler(Handle timer, Handle hndl)
{
	switch(currentState)
	{
		case STATE_FIRST_CAPT:
		{
			int numVotes = 0;
			GetTrieValue(hVoteResultsTrie, currentMaxVotedCaptAuthId, numVotes);
			ClearTrie(hVoteResultsTrie);
           
			if (SwapPlayerToTeam(currentMaxVotedCaptAuthId, 2, numVotes))
			{
				strcopy(survCaptainAuthId, MAX_STR_LEN, currentMaxVotedCaptAuthId);
				currentState = STATE_SECOND_CAPT;
				maxVoteCount = 0;

				if (Menu_Initialise())
				{
					Menu_AddAllSpectators();
					Menu_DisplayToAllSpecs();
				}
			}
			else
			{
				CPrintToChatAll("%t", "1stcap_novote_stop");
				StopMix();
			}

			strcopy(currentMaxVotedCaptAuthId, MAX_STR_LEN, " ");
		}

		case STATE_SECOND_CAPT:
		{
			int numVotes = 0;
			GetTrieValue(hVoteResultsTrie, currentMaxVotedCaptAuthId, numVotes);
			ClearTrie(hVoteResultsTrie);

			if (SwapPlayerToTeam(currentMaxVotedCaptAuthId, 3, numVotes))
			{
				strcopy(infCaptainAuthId, MAX_STR_LEN, currentMaxVotedCaptAuthId);
				currentState = STATE_PICK_TEAMS;
				CreateTimer(0.5, Menu_StateHandler); 
			}
			else
			{
				CPrintToChatAll("%t", "2ndcap_novote_stop");
				StopMix();
			}

			strcopy(currentMaxVotedCaptAuthId, MAX_STR_LEN, " ");
		}

		case STATE_PICK_TEAMS:
		{
			isPickingCaptain = false;
			survivorsPick = GetURandomInt() & 1;            
			CreateTimer(1.0, Menu_TeamPickHandler, _, TIMER_REPEAT);
		}
	}

	if (currentState == STATE_NO_MIX || currentState == STATE_PICK_TEAMS)
	{
		return Plugin_Stop; 
	}
	else
	{
		return Plugin_Handled;
	}
}

public Action Menu_TeamPickHandler(Handle timer)
{
	if (currentState == STATE_PICK_TEAMS)
	{
		if (Menu_Initialise())
		{
			Menu_AddAllSpectators();
			int captain;

			if (survivorsPick == 1)
			{
				captain = GetClientFromAuthId(survCaptainAuthId); 
			}
			else
			{
				captain = GetClientFromAuthId(infCaptainAuthId); 
			}

			if (captain > 0)
			{
				if (GetSpectatorsCount() > 0)
				{
					mixMenu.SetTitle("%T", "tittle_pteammate", captain);
					mixMenu.Display(captain, 1); 
				}
				else
				{
					CPrintToChatAll("%t", "no_pick_stop");
					StopMix();
					return Plugin_Stop;
				}
			}
			else
			{
				CPrintToChatAll("%t", "no_cap_stop");
				StopMix();
				return Plugin_Stop;
			}

			return Plugin_Continue;
		}
	}
	return Plugin_Stop;
}

public void SwapAllPlayersToSpec()
{
	for (int client = 1; client <= MaxClients; ++client)
	{
		if (IsClientInGame(client) && !IsFakeClient(client))
		{
			ChangeClientTeamEx(client, 1);
		}
	}
}

public bool SwapPlayerToTeam(const char[] authId, int team, int numVotes)
{
	int client = GetClientFromAuthId(authId);
	bool foundClient = client > 0;

	if (foundClient)
	{
		hSwapWhitelist.SetValue(authId, team);
		ChangeClientTeamEx(client, team);

		switch(currentState)
		{
			case STATE_FIRST_CAPT:
			{
				CPrintToChatAll("%t", "1stcap_confirm", client, numVotes);
			}
            
			case STATE_SECOND_CAPT:
			{
				CPrintToChatAll("%t", "2ndcap_confirm", client, numVotes);
			}

			case STATE_PICK_TEAMS:
			{
				if (survivorsPick == 1)
				{
					CPrintToChatAll("%t", "1stcap_pteammate", client);
				}
				else
				{
					CPrintToChatAll("%t", "2ndcap_pteammate", client);
				}
			}
		}
	}

	return foundClient;
}

public void OnClientDisconnect(int client)
{
	if (currentState != STATE_NO_MIX && IsClientInPlayers(client))
	{
		CPrintToChatAll("%t", "pleft_stop", client);
		StopMix();
	}
}

public bool IsPlayerCaptain(int client)
{
	return GetClientFromAuthId(survCaptainAuthId) == client || GetClientFromAuthId(infCaptainAuthId) == client;
}

public int GetClientFromAuthId(const char[] authId)
{
	char clientAuthId[MAX_STR_LEN];
	int client = 0;
	int i = 0;

	while (client == 0 && i < MaxClients)
	{
		++i;

		if (IsClientInGame(i) && !IsFakeClient(i))
		{
			GetClientAuthId(i, AuthId_SteamID64, clientAuthId, MAX_STR_LEN); 

			if (StrEqual(authId, clientAuthId))
			{
				client = i;
			}
		}
	}

	return client;
}

public bool IsClientSpec(int client)
{
	return IsClientInGame(client) && !IsFakeClient(client) && GetClientTeam(client) == 1;
}

public int GetSpectatorsCount()
{
	int count = 0;

	for (int client = 1; client <= MaxClients; ++client)
	{
		if (IsClientSpec(client))
		{
			++count;
		}
	}

	return count;
}

stock bool ChangeClientTeamEx(int client, int team)
{
	if (GetClientTeam(client) == team)
	{
		return true;
	}

	if (team != 2)
	{
		ChangeClientTeam(client, team);
		return true;
	}
	else
	{
		int bot = FindSurvivorBot();

		if (bot > 0)
		{
			int flags = GetCommandFlags("sb_takecontrol");
			SetCommandFlags("sb_takecontrol", flags & ~FCVAR_CHEAT);
			FakeClientCommand(client, "sb_takecontrol");
			SetCommandFlags("sb_takecontrol", flags);
			return true;
		}
	}
	return false;
}

stock int FindSurvivorBot()
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if(IsClientInGame(client) && IsFakeClient(client) && GetClientTeam(client) == 2)
		{
			return client;
		}
	}
	return -1;
}

stock bool IsSurvivor(int client)                                                   
{                                                                               
	return IsHuman(client) && GetClientTeam(client) == 2; 
}

stock bool IsInfected(int client)                                                   
{                                                                               
	return IsHuman(client) && GetClientTeam(client) == 3; 
}

public bool IsHuman(int client)
{
	return IsClientInGame(client) && !IsFakeClient(client);
}