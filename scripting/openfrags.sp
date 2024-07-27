#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <openfortress>
#include <morecolors>
#include <updater>

#define PLUGIN_VERSION "1.6b"
#define UPDATE_URL "http://insecuregit.ohaa.xyz/ratest/openfrags/raw/branch/main/updatefile.txt"
#define MIN_LEADERBOARD_HEADSHOTS 15
#define MIN_LEADERBOARD_MATCHES 3
#define MAX_LEADERBOARD_NAME_LENGTH 32
#define RATING_COLOR_TOP1 "{mediumpurple}"
#define RATING_COLOR_TOP5 "{gold}"
#define RATING_COLOR_TOP10 "{immortal}"
#define RATING_COLOR_TOP100 "{snow}"
#define RATING_COLOR_UNRANKED "{gray}"
#define THRESHOLD_RAGEQUIT_TIME 4
#define ELO_VALUE_D 400.0
#define ELO_VALUE_K 15.0

// defining only relatively large queries..
#define QUERY_INSERTPLAYER "INSERT IGNORE INTO stats (\
												steamid2, \
												name,\
												)\
												VALUES (\
												'%s', \
												'%s', \
												);"

#define QUERY_UPDATEPLAYER "UPDATE stats SET name = '%s', color = %i, join_count = join_count + 1 WHERE steamid2 = '%s'"

#define QUERY_UPDATERATES "UPDATE stats SET \
											kdr = (frags / CASE WHEN deaths = 0 THEN 1 ELSE deaths END), \
											railgun_headshotrate = (railgun_headshots / (CASE WHEN railgun_headshots + railgun_bodyshots + railgun_misses = 0 THEN 1 ELSE railgun_headshots + railgun_bodyshots + railgun_misses END)), \
											winrate = (wins / CASE WHEN matches = 0 THEN 1 ELSE matches END) \
										WHERE steamid2='%s';"

#define QUERY_UPDATEKILLSTREAK "UPDATE stats SET highest_killstreak = CASE WHEN highest_killstreak < %i THEN %i ELSE highest_killstreak END, \
												 highest_killstreak_map = CASE WHEN (highest_killstreak = %i AND highest_killstreak > 0) THEN '%s' ELSE highest_killstreak_map END, \
												 highest_killstreak_server = CASE WHEN (highest_killstreak = %i AND highest_killstreak > 0) THEN '%s' ELSE highest_killstreak_server END \
											 WHERE steamid2 = '%s';"

#define QUERY_UPDATESCORE "UPDATE stats SET \
											score = greatest(1000 \
											+ 8 * ((highest_killstreak-5)/5)+pow(greatest(highest_killstreak-3, 0)/8, 2) \
											+ 340 * pow(sqrt(winrate)*kdr, 1/2) \
											+ 0.675 * damage_dealt/deaths \
											+ 5 * pow(frags, 1/3) \
											+ 100 * least(2*(railgun_headshotrate*58/25-0.08), 1) \
											- 100 * ((1-pow(winrate, 1/4))/kdr*5-0.65) \
											, 100) \
										WHERE steamid2='%s' AND frags>=100 AND highest_killstreak>=1 AND kdr>0 AND playtime>=3600 AND matches>=2;"

#define QUERY_CALIBRATEELO "UPDATE stats SET \
											`elo` = 1000+(`score`-1000)/2 \
										 WHERE `steamid2`='%s' AND `elo`<100 AND `score`>0;"

// yes, this is basically selecting * from stats but i like having control of the field order
#define QUERY_GETPLAYERSTATS "SELECT \
									steamid2, \
									name, \
									color, \
									frags, \
									deaths, \
									kdr, \
									powerup_kills, \
									melee_kills, \
									railgun_headshots, \
									railgun_bodyshots, \
									railgun_misses, \
									railgun_headshotrate, \
									rocketlauncher_airshots, \
									chinalake_airshots, \
									ssg_meatshots, \
									ssg_normalshots, \
									ssg_misses, \
									matches, \
									wins, \
									top3_wins, \
									playtime, \
									highest_killstreak, \
									highest_killstreak_map, \
									damage_dealt, \
									damage_taken, \
									score, \
									dominations, \
									perfects \
								FROM stats WHERE steamid2 = '%s'"

// selects the score AND the player's place on the leaderboard
#define QUERY_GETPLAYERSCORE "SELECT * FROM \
											(SELECT \
													`steamid2`, \
													`name`, \
													`color`, \
													`score`, \
													ROW_NUMBER() OVER (ORDER BY `score` DESC) `rating_place` \
											FROM stats) \
										AS mmmm \
									WHERE steamid2='%s';"

// currently unused, for later DM elo implementation
#define QUERY_GETPLAYERELO "SELECT * FROM \
											(SELECT \
													`steamid2`, \
													`name`, \
													`color`, \
													`elo`, \
													ROW_NUMBER() OVER (ORDER BY `elo` DESC) `elo_place` \
											FROM stats) \
										AS mmmm \
									WHERE steamid2='%s';"

enum {
	OFMutator_None = 0,
	OFMutator_Instagib = 1,
	OFMutator_InstagibNoCrowbar = 2,
	OFMutator_ClanArena = 3,
	OFMutator_UnholyTrinity = 4,
	OFMutator_RocketArena = 5,
	OFMutator_Arsenal = 6,
	OFMutator_EternalShotguns = 7,
};

// this global variable list is so damn long

Database g_hSQL;
// TODO merge main and duels... into one plugin..
bool g_bDuels = false;
int g_aiCurrentDuelers[2];
char g_szTable[32];

bool g_bFirstConnectionEstabilished = false;
// for checking if the connection fails; don't want to spam the server error log with the same error over and over
bool g_bThrewErrorAlready = false;
// won't touch players that aren't tracked
bool g_abInitializedClients[MAXPLAYERS];
// duh
int g_aiKillstreaks[MAXPLAYERS];
// for perfects
bool g_abPlayerDied[MAXPLAYERS];
// for keeping track of playtime
int g_aiPlayerJoinTimes[MAXPLAYERS];
// saving bandwith by storing the damage and sending a query with all of it at once
int g_aiPlayerDamageDealtStore[MAXPLAYERS];
int g_aiPlayerDamageTakenStore[MAXPLAYERS];
// for deciding if a disconnect is a ragequit or not
int g_aiPlayerDeathTime[MAXPLAYERS];
// stat tracking eligiblity
bool g_abPlayerJoinedBeforeHalfway[MAXPLAYERS];
bool g_bRoundGoing = true;
int g_timeRoundStart = 0;
int g_nCurrentRoundMutator = 0;
// to not notify someone of OF multiple times
bool g_abPlayerNotifiedOfOF[MAXPLAYERS];
// to not enter an infinite sv_tags change loop
bool g_bSvTagsChangedDebounce = false;

// dm elo
float g_aflElos[MAXPLAYERS];
// when the round is over sort all the players by frags into this leaderboard
int g_iLeaderboardPlayers = 0;
int g_aiLeaderboardClients[MAXPLAYERS];
int g_aiLeaderboardScores[MAXPLAYERS];

// for weapons like the ssg which can trigger multiple misses on 1 attack
bool g_abSSGHitDebounce[MAXPLAYERS];

public Plugin myinfo = {
	name = "Open Frags",
	author = "ratest & Oha",
	description = "Keeps track of your stats!",
	version = PLUGIN_VERSION,
	url = "https://of.ohaa.xyz"
};

public OnLibraryAdded(const char[] szName)
{
    if(StrEqual(szName, "updater"))
    {
        Updater_AddPlugin(UPDATE_URL)
    }
}

public void OnPluginStart() {
	LoadTranslations("openfrags.phrases.txt");
	RegConsoleCmd("sm_openfrags", Command_AboutPlugin, "Information on OpenFrags");
	RegConsoleCmd("sm_openfrags_stats", Command_ViewStats, "View your stats (or someone else's)");
	RegConsoleCmd("sm_openfrags_elo", Command_ViewElo, "View your elo (or someone else's)");
	RegConsoleCmd("sm_openfrags_elos", Command_ViewElos, "View the current players' elos");
	RegConsoleCmd("sm_openfrags_top", Command_ViewTop, "View the top players");
	RegConsoleCmd("sm_openfrags_leaderboard", Command_ViewTop, "Alias for sm_openfrags_top");
	RegConsoleCmd("sm_openfrags_optout", Command_OptOut, "Delete all the data stored associated with the caller and permanently opt out of the stat tracking");
	RegConsoleCmd("sm_openfrags_eligibility", Command_TestEligibility, "Check for if the server is eligible for stat tracking");

	RegAdminCmd("sm_openfrags_test_query", Command_TestIncrementField, ADMFLAG_CONVARS, "Run a test query to see if the plugin works. Should only be ran by a user and not the server!");
	RegAdminCmd("sm_openfrags_test_elo", Command_TestEloUpdateAll, ADMFLAG_CONVARS, "Update everyone's DM elo as if the round ended");
	RegAdminCmd("sm_openfrags_cached_elos", Command_ViewCachedElos, ADMFLAG_CONVARS, "View the cached elos");

	SQL_TConnect(Callback_DatabaseConnected, "openfrags");
	
	CreateTimer(60.0, Loop_ConnectionCheck);
	AddServerTagRat("openfrags");
	FindConVar("sv_tags").AddChangeHook(Event_SvTagsChanged);
	
	if(LibraryExists("updater")) {
		Updater_AddPlugin(UPDATE_URL);
	}
}

void Callback_DatabaseConnected(Handle hDriver, Database hSQL, const char[] szErr, any unused) {
	if(IsValidHandle(hSQL)) {
		g_hSQL = hSQL;
		g_bThrewErrorAlready = false;
		if(!g_bFirstConnectionEstabilished) {
			for(int i = 1; i < MaxClients; ++i) {
				if(!IsClientInGame(i))
					continue;
					
				if(IsClientAuthorized(i)) {
					InitPlayerData(i);
					g_aiKillstreaks[i] = 0;
					
					SDKHook(i, SDKHook_OnTakeDamage, Event_PlayerDamaged);
				}
			}

			g_bFirstConnectionEstabilished = true;
			
			HookEvent("player_disconnect", Event_PlayerDisconnect);
			HookEvent("player_hurt", Event_PlayerHurt);
			HookEvent("player_death", Event_PlayerDeath);
			HookEvent("teamplay_round_start", Event_RoundStart);
			HookEvent("teamplay_win_panel", Event_RoundEnd);

			LogMessage("Successfully connected to the DB!");
		}
	}
	else {
		g_hSQL = view_as<Database>(INVALID_HANDLE);
		if(!g_bThrewErrorAlready) {
			LogError("<!> Couldn't connect to the OpenFrags DB: %s", szErr);
			g_bThrewErrorAlready = true;
		}
	}
}

Action Loop_ConnectionCheck(Handle hTimer) {
	if(!IsValidHandle(g_hSQL)) {
		SQL_TConnect(Callback_DatabaseConnected, "openfrags");
		CreateTimer(120.0, Loop_ConnectionCheck);
		return Plugin_Handled;
	}
	
	char szQueryPoke[128];
	Format(szQueryPoke, 128, "SELECT version()");
	SQL_TQuery(g_hSQL, Callback_ConnectionCheck, szQueryPoke);

	return Plugin_Handled;
}

void Callback_ConnectionCheck(Handle hSQL, Handle hResults, const char[] szErr, any unused) {
	if(!IsValidHandle(hSQL) || !IsValidHandle(hResults) || strlen(szErr) > 0) {
		g_hSQL = view_as<Database>(INVALID_HANDLE);

		LogError("<!> There was an error while checking the connection to the OpenFrags DB: %s", szErr);
	}
	
	CreateTimer(60.0, Loop_ConnectionCheck);
}

bool IsServerEligibleForStats(bool bIgnoreRoundState = false) {
	bool bMutator = g_nCurrentRoundMutator == OFMutator_None ||
					g_nCurrentRoundMutator == OFMutator_Arsenal ||
					g_nCurrentRoundMutator == OFMutator_ClanArena;
	bool bWaitingForPlayers = view_as<bool>(GameRules_GetProp("m_bInWaitingForPlayers"));
	
	return (GetClientCount(true) >= 2 &&
			(bIgnoreRoundState ? true : g_bRoundGoing) &&
			(bIgnoreRoundState ? true : !bWaitingForPlayers) &&
			bMutator &&
			!GetConVarBool(FindConVar("sv_cheats")));
}

int GetPlayerColor(int iClient) {
	char szRed[4];
	char szGreen[4];
	char szBlue[4];
	GetClientInfo(iClient, "of_color_r", szRed, 4);
	GetClientInfo(iClient, "of_color_g", szGreen, 4);
	GetClientInfo(iClient, "of_color_b", szBlue, 4);
	return ColorStringsToInt(szRed, szGreen, szBlue);
}

int ColorStringsToInt(char[] szRed, char[] szGreen, char[] szBlue) {
	int iRed = StringToInt(szRed);
	int iGreen = StringToInt(szGreen);
	int iBlue = StringToInt(szBlue);

	if(iRed < 0)
		iRed = 0;
	if(iRed > 255)
		iRed = 255;
	if(iGreen < 0)
		iGreen = 0;
	if(iGreen > 255)
		iGreen = 255;
	if(iBlue < 0)
		iBlue = 0;
	if(iBlue > 255)
		iBlue = 255;
	
	return (iBlue + iGreen * 256 + iRed * 256 * 256);
}

void ColorIntToHex(int iColor, char[] szColor, int iMaxLen = 10) {
	int iRed = iColor / 256 / 256;
	int iGreen = iColor / 256 % 256;
	int iBlue = iColor % 256;
	char szRed[4];
	char szGreen[4];
	char szBlue[4];
	if(iRed > 15)
		Format(szRed, 4, "%X", iRed);
	else
		Format(szRed, 4, "0%X", iRed);
		
	if(iGreen > 15)
		Format(szGreen, 4, "%X", iGreen);
	else
		Format(szGreen, 4, "0%X", iGreen);
		
	if(iBlue > 15)
		Format(szBlue, 4, "%X", iBlue);
	else
		Format(szBlue, 4, "0%X", iBlue);
	Format(szColor, iMaxLen, "%s%s%s%s", "\x07", szRed, szGreen, szBlue);
}

int GetPlayerFrags(int iClient) {
	int iFrags = GetEntProp(GetPlayerResourceEntity(), Prop_Send, "m_iScore", 4, iClient);
	return iFrags;
}

bool IsRoundHalfwayDone() {
	int iFragLimit = GetConVarInt(FindConVar("mp_fraglimit"));
	int iTimeLimitMinutes = GetConVarInt(FindConVar("mp_timelimit"));
	int iTimePassed = GetTime() - g_timeRoundStart;
	int iFragsHitMax = 0;
	for(int i = 1; i < MaxClients; ++i) {
		if(!IsClientInGame(i))
			continue;
		
		int iFrags = GetPlayerFrags(i);
		if(iFrags > iFragsHitMax)
			iFragsHitMax = iFrags;
		
		if(iFrags >= iFragLimit/2)
			break;
	}
	
	bool bTimeHalfwayDone = (iTimeLimitMinutes > 0) ? (iTimePassed / 60 >= iTimeLimitMinutes / 2) : false;
	bool bFragsHalfwayDone = (iFragLimit > 0) ? (iFragsHitMax >= iFragLimit / 2) : false;
	
	return (bTimeHalfwayDone || bFragsHalfwayDone);
}

bool IsPlayerActive(int iClient) {
	if(view_as<TFTeam>(GetClientTeam(iClient)) == TFTeam_Unassigned)
		return false;
	
	return ((GetPlayerFrags(iClient) > 0 || g_aiPlayerDamageDealtStore[iClient] > 0) && view_as<TFTeam>(GetClientTeam(iClient)) != TFTeam_Spectator);
}

void InitPlayerData(int iClient) {
	if(iClient <= 0 || iClient >= MAXPLAYERS)
		return;

	char szClientName[64];
	char szAuth[32];
	GetClientName(iClient, szClientName, 64);
	GetClientAuthId(iClient, AuthId_Steam2, szAuth, 32);
	
	if(StrEqual(szAuth, "STEAM_ID_PENDING", false) || StrEqual(szAuth, "STEAM_ID_LAN", false) || StrEqual(szAuth, "LAN", false) || StrEqual(szAuth, "BOT", false))
		return;
	
	if(!IsValidHandle(g_hSQL)) {
		LogError("<!> Invalid SQL database handle!");
		return;
	}
	
	// anyone who has a single quote in their name... i will find and frag
	char szClientNameSafe[129];
	SQL_EscapeString(g_hSQL, szClientName, szClientNameSafe, 64);
	
	// check for a stat tracking ban / opt-out
	char szQueryCheckPlayerBan[128];
	Format(szQueryCheckPlayerBan, 128, "SELECT * FROM bans WHERE steamid2 = '%s'", szAuth);
	g_hSQL.Query(Callback_InitPlayerData_ReceivedBanStatus, szQueryCheckPlayerBan, iClient, DBPrio_High);
}

void Callback_InitPlayerData_ReceivedBanStatus(Database hSQL, DBResultSet hResults, const char[] szErr, int iClient) {
	if(hResults.RowCount > 0) {
		hResults.FetchRow();
		bool bBanned = view_as<bool>(hResults.FetchInt(2));
		int iExpirationTime = hResults.FetchInt(5);

		int iCurrentTime = GetTime();
		if(bBanned && (iCurrentTime < iExpirationTime || iExpirationTime == 0))
			return;
	}
	
	char szAuth[32];
	GetClientAuthId(iClient, AuthId_Steam2, szAuth, 32);
	
	char szClientName[64];
	char szClientNameSafe[129];
	GetClientName(iClient, szClientName, 64);
	SQL_EscapeString(g_hSQL, szClientName, szClientNameSafe, 64);
	
	// won't run if there's an existing entry for the player
	char szQueryInsertNewPlayer[512];
	Format(szQueryInsertNewPlayer, 512, QUERY_INSERTPLAYER, szAuth, szClientNameSafe);
	g_hSQL.Query(Callback_InitPlayerData_InsertedPlayer, szQueryInsertNewPlayer, iClient, DBPrio_High);
}

void Callback_InitPlayerData_InsertedPlayer(Database hSQL, DBResultSet hResults, const char[] szErr, any iClientUncasted) {
	int iClient = view_as<int>(iClientUncasted);
	char szAuth[32];
	GetClientAuthId(iClient, AuthId_Steam2, szAuth, 32);
	char szQueryGetElo[512];
	Format(szQueryGetElo, 512, QUERY_GETPLAYERELO, szAuth);
	g_hSQL.Query(Callback_InitPlayerData_ReceivedElo, szQueryGetElo, iClient, DBPrio_High);
}

// Final callback of the chain
void Callback_InitPlayerData_ReceivedElo(Database hSQL, DBResultSet hResults, const char[] szErr, any iClientUncasted) {
	int iClient = view_as<int>(iClientUncasted);
	g_abInitializedClients[iClient] = true;
	
	hResults.FetchRow();
	g_aflElos[iClient] = hResults.FetchFloat(3);
	
	char szAuth[32];
	GetClientAuthId(iClient, AuthId_Steam2, szAuth, 32);
	
	char szClientName[64];
	char szClientNameSafe[129];
	GetClientName(iClient, szClientName, 64);
	SQL_EscapeString(g_hSQL, szClientName, szClientNameSafe, 64);
	
	int iPlayerColor = GetPlayerColor(iClient);
	char szQueryUpdatePlayer[256];
	Format(szQueryUpdatePlayer, 256, QUERY_UPDATEPLAYER, szClientNameSafe, iPlayerColor, szAuth);
	g_hSQL.Query(Callback_None, szQueryUpdatePlayer, 5, DBPrio_Low);
	
	OnClientDataInitialized(iClient);
}

// Pre 1.6 final callback
/*
void Callback_InitPlayerData_Final(Database hSQL, DBResultSet hResults, const char[] szErr, any iClientUncasted) {
	int iClient = view_as<int>(iClientUncasted);
	g_abInitializedClients[iClient] = true;
	
	char szAuth[32];
	GetClientAuthId(iClient, AuthId_Steam2, szAuth, 32);
	
	char szClientName[64];
	char szClientNameSafe[129];
	GetClientName(iClient, szClientName, 64);
	SQL_EscapeString(g_hSQL, szClientName, szClientNameSafe, 64);
	
	int iPlayerColor = GetPlayerColor(iClient);
	char szQueryUpdatePlayer[256];
	Format(szQueryUpdatePlayer, 256, QUERY_UPDATEPLAYER, szClientNameSafe, iPlayerColor, szAuth);
	g_hSQL.Query(Callback_None, szQueryUpdatePlayer, 5, DBPrio_Low);
	
	OnClientDataInitialized(iClient);
}
*/

void IncrementField(int iClient, char[] szField, int iAdd = 1) {
	if(iClient <= 0 || iClient >= MAXPLAYERS)
		return;
		
	if(!g_abInitializedClients[iClient])
		return;
	
	bool bIgnoreRoundState = StrEqual(szField, "playtime", false);
	if(!IsServerEligibleForStats(bIgnoreRoundState))
		return;
	
	char szAuth[32];
	GetClientAuthId(iClient, AuthId_Steam2, szAuth, 32);
	
	char szQuery[512];
	Format(szQuery, 512, "UPDATE stats SET \
										%s = (%s + %i) \
										WHERE steamid2 = '%s'", szField, szField, iAdd, szAuth);

	g_hSQL.Query(Callback_None, szQuery, 0, DBPrio_Low);
}

void ResetKillstreak(int iClient) {
	int iKillstreak = g_aiKillstreaks[iClient];
	g_aiKillstreaks[iClient] = 0;
	
	if(!g_abInitializedClients[iClient])
		return;
	
	if(!IsServerEligibleForStats())
		return;
	
	char szAuth[32];
	GetClientAuthId(iClient, AuthId_Steam2, szAuth, 32);
	
	char szQueryUpdate[512];
	char szMap[64];
	char szHostname[64];
	GetCurrentMap(szMap, 64);
	ConVar cvarHostname = FindConVar("hostname");
	if(cvarHostname != INVALID_HANDLE)
		GetConVarString(cvarHostname, szHostname, 64);
	else
		GetClientName(0, szHostname, 64);
	Format(szQueryUpdate, 512, QUERY_UPDATEKILLSTREAK, iKillstreak, iKillstreak, iKillstreak, szMap, iKillstreak, szHostname, szAuth);

	SQL_TQuery(g_hSQL, Callback_None, szQueryUpdate, 1);
}

// for threaded fast queries
void Callback_None(Database hSQL, DBResultSet hResults, const char[] szErr, any data) {
	if(!IsValidHandle(hSQL) || strlen(szErr) > 0) {
		LogError("<!> Threaded fast query failed (%i): %s", data, szErr);
	}
}

public void OnPluginEnd() {
	CloseHandle(g_hSQL);
}

public void OnClientAuthorized(int iClient, const char[] szAuth) {
	g_aiPlayerJoinTimes[iClient] = GetTime();
	g_aiKillstreaks[iClient] = 0;
	g_abPlayerJoinedBeforeHalfway[iClient] = IsRoundHalfwayDone();
	
	InitPlayerData(iClient);
}

// resets everyone's join times whenever the server becomes eligible for stat tracking, and updates playtimes if it already is
void OnClientDataInitialized(int iClient) {
	CreateTimer(60.0, Delayed_NotifyUserOfOpenFrags, iClient);
	if(IsServerEligibleForStats(true)) {
		for(int i = 1; i < MaxClients; ++i) {
			if(!IsClientInGame(i))
				continue;
				
			if(!g_abInitializedClients[i])
				continue;
			
			if(IsPlayerActive(i))
				IncrementField(i, "playtime", g_aiPlayerJoinTimes[i] == 0 ? 0 : GetTime() - g_aiPlayerJoinTimes[i]);
			g_aiPlayerJoinTimes[i] = GetTime();
		}
	} else {
		for(int i = 1; i < MaxClients; ++i) {
			if(!IsClientInGame(i))
				continue;
				
			g_aiPlayerJoinTimes[i] = GetTime();
		}
	}
}

Action Delayed_NotifyUserOfOpenFrags(Handle hTimer, int iClient) {
	if(!IsClientInGame(iClient))
		return Plugin_Handled;
	
	if(g_abPlayerNotifiedOfOF[iClient])
		return Plugin_Handled;
	g_abPlayerNotifiedOfOF[iClient] = true;
	
	char szAuth[32];
	GetClientAuthId(iClient, AuthId_Steam2, szAuth, 32);
	
	char szQueryCheckNotifiedChatAlready[128];
	Format(szQueryCheckNotifiedChatAlready, 128, "SELECT `steamid2`, `name`, `notified` FROM stats WHERE steamid2 = '%s'", szAuth);
	g_hSQL.Query(Callback_NotifyUserOfOpenFrags, szQueryCheckNotifiedChatAlready, iClient, DBPrio_High);
	
	return Plugin_Handled;
}

void Callback_NotifyUserOfOpenFrags(Database hSQL, DBResultSet hResults, const char[] szErr, any iClientUncasted) {
	int iClient = view_as<int>(iClientUncasted);
	
	if(!IsValidHandle(hSQL) || !IsValidHandle(hResults))
		return;
	
	if(hResults.RowCount <= 0)
		return;
	
	hResults.FetchRow();
	bool bNotified = view_as<bool>(hResults.FetchInt(2));
	
	if(!bNotified)
		CPrintToChat(iClient, "%t %t", "OpenFrags ChatPrefix", "OpenFrags Notify");
	else
		PrintToConsole(iClient, "[OF] This server is running OpenFrags, use /stats (or sm_openfrags_stats) to see your stats, /top (or sm_openfrags_top) to view the leaderboard and /optout (or sm_openfrags_optout) to completely opt out of the stat tracking");
	
	char szAuth[32];
	hResults.FetchString(0, szAuth, 32);
	
	char szQuerySetNotified[128];
	Format(szQuerySetNotified, 128, "UPDATE stats SET `notified`=1 WHERE `steamid2`='%s'", szAuth);
	g_hSQL.Query(Callback_None, szQuerySetNotified, 38, DBPrio_Low);
}

public void OnClientPutInServer(int iClient) {
	SDKHook(iClient, SDKHook_OnTakeDamage, Event_PlayerDamaged);
}

void Event_PlayerDisconnect(Event event, const char[] szEventName, bool bDontBroadcast) {
	int iClient = GetClientOfUserId(GetEventInt(event, "userid"));
	char szDisconectReason[128];
	GetEventString(event, "reason", szDisconectReason, 128);
	
	if(g_abPlayerJoinedBeforeHalfway[iClient] && IsRoundHalfwayDone() && g_bRoundGoing && (StrContains(szDisconectReason, "timed out", false) == -1 && StrContains(szDisconectReason, "kicked", false) == -1 && StrContains(szDisconectReason, "connection closing", false) == -1))
		IncrementField(iClient, "matches");

	if(g_aiPlayerDeathTime[iClient] + THRESHOLD_RAGEQUIT_TIME > GetTime())
		IncrementField(iClient, "ragequits");
	
	ResetKillstreak(iClient);
	UpdateStoredStats(iClient);
	g_abInitializedClients[iClient] = false;
	g_aiPlayerJoinTimes[iClient] = 0;
	g_aiPlayerDeathTime[iClient] = 0;
	g_aflElos[iClient] = 0.0;
	g_abPlayerJoinedBeforeHalfway[iClient] = false;
	g_abPlayerNotifiedOfOF[iClient] = false;
}

public void OnMapStart() {
	AddServerTagRat("openfrags");
	g_bRoundGoing = true;
	g_timeRoundStart = GetTime();
	g_nCurrentRoundMutator = GetConVarInt(FindConVar("of_mutator"));
	for(int i = 0; i < MAXPLAYERS; ++i) {
		g_aiKillstreaks[i] = 0;
		g_aiPlayerDeathTime[i] = 0;
		g_abPlayerDied[i] = false;
	}
}

public void OnMapEnd() {
	g_nCurrentRoundMutator = 0;
	for(int i = 0; i < MAXPLAYERS; ++i) {
		g_abPlayerJoinedBeforeHalfway[i] = false;
		g_abPlayerNotifiedOfOF[i] = false;
	}
	UpdateStoredStats();
}

void Event_RoundStart(Event event, char[] szEventName, bool bDontBroadcast) {
	g_bRoundGoing = true;
	g_timeRoundStart = GetTime();
	g_nCurrentRoundMutator = GetConVarInt(FindConVar("of_mutator"));
	for(int i = 0; i < MAXPLAYERS; ++i) {
		g_aiKillstreaks[i] = 0;
		g_aiPlayerDeathTime[i] = 0;
		g_abPlayerDied[i] = false;
		if(i < MaxClients)
			g_abPlayerJoinedBeforeHalfway[i] = true;
	}

	UpdateStoredStats();
}

void UpdateStoredStats(int iClient = -1) {
	if(iClient == -1) {
		for(int i = 1; i < MaxClients; ++i) {
			if(!IsClientInGame(i))
				continue;
				
			UpdateStoredStats(i);
		}
	} else {
		if(!g_abInitializedClients[iClient])
			return;
		
		if(!IsClientInGame(iClient))
			return;
		
		if(IsPlayerActive(iClient)) {
			IncrementField(iClient, "playtime", g_aiPlayerJoinTimes[iClient] == 0 ? 0 : GetTime() - g_aiPlayerJoinTimes[iClient]);
			IncrementField(iClient, "damage_dealt", g_aiPlayerDamageDealtStore[iClient]);
			IncrementField(iClient, "damage_taken", g_aiPlayerDamageTakenStore[iClient]);
		}
		
		g_aiPlayerJoinTimes[iClient] = GetTime();
		g_aiPlayerDamageDealtStore[iClient] = 0;
		g_aiPlayerDamageTakenStore[iClient] = 0;
		
		char szAuth[32];
		GetClientAuthId(iClient, AuthId_Steam2, szAuth, 32);
		
		char szUpdateRatesQuery[512];
		Format(szUpdateRatesQuery, 512, QUERY_UPDATERATES, szAuth)
		g_hSQL.Query(Callback_None, szUpdateRatesQuery, 420, DBPrio_Low);
		
		char szUpdateScoreQuery[512];
		Format(szUpdateScoreQuery, 512, QUERY_UPDATESCORE, szAuth)
		g_hSQL.Query(Callback_None, szUpdateScoreQuery, 421, DBPrio_Low);
		
		char szCalibrateEloQuery[512];
		Format(szCalibrateEloQuery, 512, QUERY_CALIBRATEELO, szAuth);
		g_hSQL.Query(Callback_None, szCalibrateEloQuery, 426, DBPrio_Low);
	}
}

void Event_PlayerHurt(Event event, const char[] szEventName, bool bDontBroadcast) {
	int iAttacker = GetClientOfUserId(GetEventInt(event, "attacker"));
	int iVictim = GetClientOfUserId(GetEventInt(event, "userid"));

	int iDamageTaken = GetEventInt(event, "damageamount");
	if(iDamageTaken > 300 || iDamageTaken < -300)
		return;

	g_aiPlayerDamageTakenStore[iVictim] += iDamageTaken;
	
	if(iAttacker == iVictim || iAttacker == 0)
		return;

	g_aiPlayerDamageDealtStore[iAttacker] += iDamageTaken;
}

public Action TF2_CalcIsAttackCritical(int iClient, int iWeapon, char[] szWeapon, bool& bResult) {
	if(StrEqual(szWeapon, "tf_weapon_railgun", false) || StrEqual(szWeapon, "railgun", false)) {
		IncrementField(iClient, "railgun_misses", 1);
		return Plugin_Continue;
	} else if(StrEqual(szWeapon, "tf_weapon_supershotgun", false) || StrEqual(szWeapon, "supershotgun", false)) {
		IncrementField(iClient, "ssg_misses", 1);
		return Plugin_Continue;
	}
	
	return Plugin_Continue;
}

Action Event_PlayerDamaged(int iVictim, int& iAttacker, int& iInflictor, float& flDamage, int& iDamageType, int& iWeapon, float vecDamageForce[3], float vecDamagePosition[3], int iDamageCustom) {
	if(iVictim <= 0 || iVictim > MaxClients || iAttacker < 0 || iAttacker > MaxClients)
		return Plugin_Continue;

	if(!g_abInitializedClients[iAttacker])
		return Plugin_Continue;

	if(iWeapon < 0)
		return Plugin_Continue;
	
	char szWeapon[128];
	GetEntityClassname(iWeapon, szWeapon, 128)
	if(StrEqual(szWeapon, "tf_weapon_railgun", false)) {
		if(iDamageCustom == 86 || iDamageCustom == 1) {
			IncrementField(iAttacker, "railgun_headshots");
		} else {
			IncrementField(iAttacker, "railgun_bodyshots");
		}
		IncrementField(iAttacker, "railgun_misses", -1);
	} else if (StrEqual(szWeapon, "tf_weapon_supershotgun", false)) {
		if(g_abSSGHitDebounce[iAttacker])
			return Plugin_Continue;
		
		g_abSSGHitDebounce[iAttacker] = true;
		CreateTimer(0.05, Timer_ResetHitDebounce, iAttacker);
		
		if(flDamage >= 100.0)
			IncrementField(iAttacker, "ssg_meatshots");
		else
			IncrementField(iAttacker, "ssg_normalshots");
			
		IncrementField(iAttacker, "ssg_misses", -1);
	}

	return Plugin_Continue;
}

Action Timer_ResetHitDebounce(Handle hTimer, int iClient) {
	g_abSSGHitDebounce[iClient] = false;
	return Plugin_Handled;
}

void Event_PlayerDeath(Event event, const char[] szEventName, bool bDontBroadcast) {
	int iVictimId = GetEventInt(event, "userid");
	int iAttackerId = GetEventInt(event, "attacker");
	bool bDominated = view_as<bool>(GetEventInt(event, "dominated"));
	
	int iVictim = GetClientOfUserId(iVictimId);
	int iClient = GetClientOfUserId(iAttackerId);
	
	if((!g_abInitializedClients[iVictim] || !g_abInitializedClients[iClient]) && !IsFakeClient(iVictim))
		return;
	
	char szWeapon[128];
	GetEventString(event, "weapon", szWeapon, 128);
	
	IncrementField(iVictim, "deaths");
	g_aiPlayerDeathTime[iVictim] = GetTime();
	ResetKillstreak(iVictim);
	g_abPlayerDied[iVictim] = true;
	if(iVictim != iClient) {
		IncrementField(iClient, "frags");
		
		if(bDominated)
			IncrementField(iClient, "dominations");
		
		if(StrEqual(szWeapon, "crowbar", false) || StrEqual(szWeapon, "lead_pipe", false) || StrEqual(szWeapon, "combatknife", false) || StrEqual(szWeapon, "claws", false))
			IncrementField(iClient, "melee_kills");
		
		if(iClient > 0) {
			if(TF2_IsPlayerInCondition(iClient, TFCond_CritPowerup) ||
				TF2_IsPlayerInCondition(iClient, TFCond_Haste) ||
				TF2_IsPlayerInCondition(iClient, TFCond_Shield) ||
				TF2_IsPlayerInCondition(iClient, TFCond_Berserk) ||
				TF2_IsPlayerInCondition(iClient, TFCond_InvisPowerup) ||
				TF2_IsPlayerInCondition(iClient, TFCond_JetpackPowerup))
				IncrementField(iClient, "powerup_kills");
		}
		
		g_aiKillstreaks[iClient] += 1;
	}
}

public void OnEntityCreated(int iEnt, const char[] szClassname) {
	if(!StrEqual(szClassname, "tf_projectile_rocket", false) && !StrEqual(szClassname, "tf_projectile_pipe", false))
		return;
		
	SDKHook(iEnt, SDKHook_StartTouch, Event_RocketTouch);
}

Action Event_RocketTouch(int iEntity, int iOther) {
	char szMyClassname[128];
	char szOtherClassname[128];
	GetEntityClassname(iEntity, szMyClassname, 128);
	GetEntityClassname(iOther, szOtherClassname, 128);
	
	if(!StrEqual(szOtherClassname, "player", false))
		return Plugin_Continue;
		
	int iAttacker = GetEntPropEnt(iEntity, Prop_Send, "m_hOwnerEntity");
	
	if(iAttacker == iOther)
		return Plugin_Continue;
	
	if(!(GetEntityFlags(iOther) & FL_ONGROUND)) {
		if(StrEqual(szMyClassname, "tf_projectile_rocket", false))
			IncrementField(iAttacker, "rocketlauncher_airshots");
		else if(StrEqual(szMyClassname, "tf_projectile_pipe", false))
			IncrementField(iAttacker, "chinalake_airshots");
	}
	
	return Plugin_Continue;
}

// TODO implement all this.
int Sort_CompareByFrags(int elem1, int elem2, const int[] array, Handle hndl) {
	int iDiff = GetPlayerFrags(elem2) - GetPlayerFrags(elem1);
	if(iDiff > 0)
		iDiff = 1;
	if(iDiff < 0)
		iDiff = -1;
	return iDiff;
}

int Elo_MakePlayerLeaderboard(int aiPlayers[MAXPLAYERS], int aiScores[MAXPLAYERS], bool bSort = true, bool bDebug = false) {
	int iClientCount = 0;
	for(int i = 1; i < MaxClients; ++i) {
		PrintToServer("Checking client %i", i);
		if(!IsClientInGame(i)) {
			if(bDebug)
				PrintToServer("Client %i is not in game, skipping", i);
			continue;
		}
		if(IsFakeClient(i)) {
			if(bDebug)
				PrintToServer("Client %i is fake, skipping", i);
			continue;
		}
		if(!g_abInitializedClients[i]) {
			if(bDebug)
				PrintToServer("Client %i is not initialized, skipping", i);
			continue;
		}
		if(!IsPlayerActive(i)) {
			if(bDebug)
				PrintToServer("Client %i is not active, skipping", i);
			continue;
		}
		if(g_aflElos[i] <= 99.9) {
			if(bDebug)
				PrintToServer("Client %i has below 100 elo, skipping", i);
			continue;
		}
		
		aiPlayers[iClientCount] = i;
		iClientCount++;
	}
	if(bSort)
		SortCustom1D(aiPlayers, iClientCount, Sort_CompareByFrags);
	for(int i = 0; i < iClientCount; ++i) {
		aiScores[i] = GetPlayerFrags(aiPlayers[i]);
	}
	return iClientCount;
}

// Everything's based on github.com/djcunningham0/multielo
int Elo_GetPermutationCount() {
	int iClientCount = GetClientCount(true);
	return (iClientCount*(iClientCount-1))/2;
}

float Elo_GetPlayerExpectedScore(int aiPlayers[MAXPLAYERS], int iClientCount, int iClientLeaderboardPlace) {
	if(!g_abInitializedClients[aiPlayers[iClientLeaderboardPlace]])
		return 0.0;
	if(iClientCount == 2) {
		return iClientLeaderboardPlace == 0 ? 1.0 : 0.0;
	}
	// exponent function, more weight for the 1st place
	float flNumerator = 0.0;
	for(int i = 0; i < iClientCount; ++i) {
		if(i == iClientLeaderboardPlace)
			continue;
		
		flNumerator += 1.0 / (1.0 + Pow(10.0, (g_aflElos[aiPlayers[i]] - g_aflElos[aiPlayers[iClientLeaderboardPlace]])/ELO_VALUE_D));
	}
	int flDenominator = Elo_GetPermutationCount();
	return flNumerator / float(flDenominator);
}

float Elo_GetPlayerScore(int aiPlayers[MAXPLAYERS], int iClientCount, int iClientLeaderboardPlace) {
	if(!g_abInitializedClients[aiPlayers[iClientLeaderboardPlace]])
		return 0.0;
	const float flBase = 2.0;
	float flNumerator = Pow(flBase, float(iClientCount - iClientLeaderboardPlace)) - 1;
	float flDenominator = 0.0;
	for(int i = 0; i < iClientCount; ++i) {
		flDenominator += Pow(flBase, float(iClientCount - i)) - 1;
	}
	return flNumerator / flDenominator;
}

void Elo_UpdatePlayerElo(int iClient, int iLeaderboardPlace, bool bDebug = false) {
	if(bDebug)
		PrintToServer("Updating elo for client %i, leaderboard place %i", iClient, iLeaderboardPlace+1);
	
	if(!g_abInitializedClients[iClient])
		return;
	
	float flPlayerScore = Elo_GetPlayerScore(g_aiLeaderboardClients, g_iLeaderboardPlayers, iLeaderboardPlace);
	float flExpectedScore = Elo_GetPlayerExpectedScore(g_aiLeaderboardClients, g_iLeaderboardPlayers, iLeaderboardPlace);
	float flEloAdd = ELO_VALUE_K * (g_iLeaderboardPlayers - 1) * (flPlayerScore - flExpectedScore);
	if(bDebug)
		PrintToServer("DeltaElo/Expected/Score: %f / %f / %f", flEloAdd, flExpectedScore, flPlayerScore);
	
	char szAuth[32];
	GetClientAuthId(iClient, AuthId_Steam2, szAuth, 32);
	char szQueryUpdateElo[512];
	// you gotta be calibrated with the legacy score system first to be able to elo your elo
	Format(szQueryUpdateElo, 512, "UPDATE `stats` SET `elo`=GREATEST(100, `elo`+%f) WHERE `steamid2`='%s' AND `elo`>0 AND `score`>0", flEloAdd, szAuth);
	if(bDebug)
		PrintToServer("Final query: %s", szQueryUpdateElo);
	g_hSQL.Query(Callback_UpdatedElo, szQueryUpdateElo, iClient);
}

void Callback_UpdatedElo(Database hSQL, DBResultSet hResults, const char[] szErr, any iClientUncasted) {
	if(!IsValidHandle(hResults) || strlen(szErr) > 0) {
		LogError("<!> Couldn't update elo for client %i: %s", szErr, iClientUncasted);
		return;
	}
	int iClient = view_as<int>(iClientUncasted);
	char szAuth[32];
	GetClientAuthId(iClient, AuthId_Steam2, szAuth, 32);
	char szQueryUpdateElo[512];
	// you gotta be calibrated with the legacy score system first to be able to elo your elo
	Format(szQueryUpdateElo, 512, "SELECT `elo` FROM `stats` WHERE `steamid2`='%s'", szAuth);
	g_hSQL.Query(Callback_ReceivedUpdatedElo, szQueryUpdateElo, iClient);
	
}

void Callback_ReceivedUpdatedElo(Database hSQL, DBResultSet hResults, const char[] szErr, any iClientUncasted) {
	int iClient = view_as<int>(iClientUncasted);
	if(!IsValidHandle(hResults) || strlen(szErr) > 0) {
		LogError("<!> Couldn't receive updated elo: %s", szErr);
		return;
	}
	if(hResults.RowCount < 1) {
		LogError("<!> Couldn't receive updated elo due to no rows being returned: %s", szErr);
		return;
	}
	hResults.FetchRow();
	g_aflElos[iClient] = hResults.FetchFloat(0);
}

void Elo_UpdateAll(bool bDebug = false) {
	int iClientCount = Elo_MakePlayerLeaderboard(g_aiLeaderboardClients, g_aiLeaderboardScores, true, bDebug);
	g_iLeaderboardPlayers = iClientCount;
	if(bDebug) {
		PrintToServer("Made leaderboard with %i players:", iClientCount);
		for(int i = 0; i <g_iLeaderboardPlayers; ++i) {
			char szClientName[64];
			GetClientName(g_aiLeaderboardClients[i], szClientName, 64);
			PrintToServer("%i. %i : %s", i+1, g_aiLeaderboardClients[i], szClientName);
		}
	}
	for(int i = 0; i < iClientCount; ++i) {
		Elo_UpdatePlayerElo(g_aiLeaderboardClients[i], i+1, bDebug);
	}
}

void Elo_UpdateDuels(int iWinner, int iLoser) {
	g_iLeaderboardPlayers = 2;
	g_aiLeaderboardClients[0] = iWinner;
	g_aiLeaderboardClients[1] = iLoser;
	g_aiLeaderboardScores[0] = GetPlayerFrags(iWinner);
	g_aiLeaderboardScores[1] = GetPlayerFrags(iLoser);
	Elo_UpdatePlayerElo(iWinner, 0);
	Elo_UpdatePlayerElo(iWinner, 1);
}

void Event_RoundEnd(Event event, const char[] szEventName, bool bDontBroadcast) {
	for(int i = 1; i < MaxClients; ++i) {
		if(!IsClientInGame(i))
			continue;
			
		if(!g_abInitializedClients[i])
			continue;

		if(g_abPlayerJoinedBeforeHalfway[i] && IsPlayerActive(i))
			IncrementField(i, "matches");
		
		g_aiPlayerDeathTime[i] = 0;
		ResetKillstreak(i);
		UpdateStoredStats(i);
	}
	
	if(!g_bDuels) {
		int iTop1Client = GetEventInt(event, "player_1");
		int iTop2Client = GetEventInt(event, "player_2");
		int iTop3Client = GetEventInt(event, "player_3");
		
		IncrementField(iTop1Client, "wins");
		
		IncrementField(iTop1Client, "top3_wins");
		IncrementField(iTop2Client, "top3_wins");
		IncrementField(iTop3Client, "top3_wins");
		
		if(!g_abPlayerJoinedBeforeHalfway[iTop1Client])
			IncrementField(iTop1Client, "matches");
		if(!g_abPlayerJoinedBeforeHalfway[iTop2Client])
			IncrementField(iTop2Client, "matches");
		if(!g_abPlayerJoinedBeforeHalfway[iTop3Client])
			IncrementField(iTop3Client, "matches");
	
		if(!g_abPlayerDied[iTop1Client])
			IncrementField(iTop1Client, "perfects");
		
		// Hope this doesn't break absolutely everything..
		Elo_UpdateAll();
	} else {
		if(g_aiCurrentDuelers[0] < 1 || g_aiCurrentDuelers[1] < 1) {
			g_bRoundGoing = false;
			return;
		}
		int iWinner = GetPlayerFrags(g_aiCurrentDuelers[0]) > GetPlayerFrags(g_aiCurrentDuelers[1]) ? g_aiCurrentDuelers[0] : g_aiCurrentDuelers[1];
		int iLoser = GetPlayerFrags(g_aiCurrentDuelers[0]) > GetPlayerFrags(g_aiCurrentDuelers[1]) ? g_aiCurrentDuelers[1] : g_aiCurrentDuelers[0];
		Elo_UpdateDuels(iWinner, iLoser);
		
		IncrementField(iWinner, "wins");
		IncrementField(iWinner, "matches");
		IncrementField(iLoser, "matches");
		g_aiCurrentDuelers[0] = -1;
		g_aiCurrentDuelers[1] = -1;
	}
	
	g_bRoundGoing = false;
}

bool g_bPrintPlayerStatsScrewedUp = false;
void PrintPlayerStats(int iClient, int iStatsOwner, char[] szAuthArg = "") {
	g_bPrintPlayerStatsScrewedUp = false;
	bool bSelfRequest = iClient == iStatsOwner;
	char szAuthToUse[32];
	if(iStatsOwner != -1) {
		if(!g_abInitializedClients[iStatsOwner]) {
			char szClientName[64];
			GetClientName(iStatsOwner, szClientName, 64);
			
			if(bSelfRequest)
				CPrintToChat(iClient, "%t %t", "OpenFrags ChatPrefix", "OpenFrags UninitializedSelf");
			else
				CPrintToChat(iClient, "%t %t", "OpenFrags ChatPrefix", "OpenFrags UninitializedPlayer", szClientName);
			return;
		}
		
		GetClientAuthId(iStatsOwner, AuthId_Steam2, szAuthToUse, 32);
	} else {
		strcopy(szAuthToUse, 32, szAuthArg);
	}
	
	DataPack hDatapack = new DataPack();
	hDatapack.WriteCell(iClient);
	hDatapack.WriteString(szAuthToUse);

	char szQuery[1024];
	Format(szQuery, 1024, QUERY_GETPLAYERSTATS, szAuthToUse);
	g_hSQL.Query(Callback_PrintPlayerStats_Check, szQuery, hDatapack, DBPrio_Normal);
	
}

// Basically... if the stats query fails, recurse and try again but for the caller
void Callback_PrintPlayerStats_Check(Database hSQL, DBResultSet hResults, const char[] szErr, any hDatapackUncasted) {
	DataPack hDatapack = view_as<DataPack>(hDatapackUncasted);
	// check if the requested user steamid2 exists
	if(hResults.RowCount < 1 && !g_bPrintPlayerStatsScrewedUp) {
		g_bPrintPlayerStatsScrewedUp = true;
		
		hDatapack.Reset();
		int iClient = hDatapack.ReadCell();
		
		char szAuthToUse[32];
		GetClientAuthId(iClient, AuthId_Steam2, szAuthToUse, 32);

		CloseHandle(hDatapack);
		DataPack hNewDatapack = new DataPack();
		hNewDatapack.WriteCell(iClient);
		hNewDatapack.WriteString(szAuthToUse);
		
		// forming a new query to get stats of the caller because we fucked up
		char szQuery[1024];
		Format(szQuery, 1024, QUERY_GETPLAYERSTATS, szAuthToUse);
		g_hSQL.Query(Callback_PrintPlayerStats_Check, szQuery, hNewDatapack, DBPrio_Normal);
	} else if(hResults.RowCount < 1) {
		// we couldn't get the caller's stats either.. oh well!
		hDatapack.Reset();
		int iClient = hDatapack.ReadCell();
		CPrintToChat(iClient, "%t %t", "OpenFrags ChatPrefix", "OpenFrags StatsError");
		CloseHandle(hDatapack);
		return;
	} else {
		g_bPrintPlayerStatsScrewedUp = false;
		hDatapack.WriteCell(CloneHandle(hResults));

		SQL_FetchRow(hResults);
		if(hResults.FetchInt(25) == 0) {
			Callback_PrintPlayerStats_Finish(hSQL, view_as<DBResultSet>(INVALID_HANDLE), szErr, hDatapack);
		} else {
			char szAuthToUse[32];
			hResults.FetchString(0, szAuthToUse, 32);
			char szQuery[512];
			Format(szQuery, 512, QUERY_GETPLAYERSCORE, szAuthToUse);
			g_hSQL.Query(Callback_PrintPlayerStats_Finish, szQuery, hDatapack, DBPrio_Normal);
		}
	}
}

// TODO update order
void Callback_PrintPlayerStats_Finish(Database hSQL, DBResultSet hResultsScorePlace, const char[] szErr, any hDatapackUncasted) {
	DataPack hDatapack = view_as<DataPack>(hDatapackUncasted);
	hDatapack.Reset();
	int iClient = hDatapack.ReadCell();
	char szQueriedAuth[32];
	hDatapack.ReadString(szQueriedAuth, 32);
	DBResultSet hResults = hDatapack.ReadCell();
	CloseHandle(hDatapack);
	
	char szAuth[32];
	char szStatOwnerAuth[32];
	hResults.FetchString(0, szStatOwnerAuth, 32);
	GetClientAuthId(iClient, AuthId_Steam2, szAuth, 32);
	bool bSelfRequest = strcmp(szAuth, szStatOwnerAuth) == 0;
	
	char szName[128];
	hResults.FetchString(1, szName, 128);
	int iColor = hResults.FetchInt(2);
	char szColor[12];
	ColorIntToHex(iColor, szColor, 12);
	int iFrags = hResults.FetchInt(3);
	int iDeaths = hResults.FetchInt(4);
	float flKDR = hResults.FetchFloat(5);
	int iPowerupKills = hResults.FetchInt(6);
	int iMeleeKills = hResults.FetchInt(7);
	int iRGHeadshots = hResults.FetchInt(8);
	float flRGHeadshotRate = hResults.FetchFloat(11);
	// i dont like how sourcemod outputs floats to chat so there's that
	int iRGHeadshotPercentageHigh = RoundFloat(flRGHeadshotRate * 1000) / 10;
	int iRGHeadshotPercentageLow = RoundFloat(flRGHeadshotRate * 1000) % 10;
	
	int iRLAirshots = hResults.FetchInt(12);
	int iGLAirshots = hResults.FetchInt(13);
	int iSSGMeatshots = hResults.FetchInt(14);
	int iSSGNormalShots = hResults.FetchInt(15);
	int iSSGMisses = hResults.FetchInt(16);
	int iMatches = hResults.FetchInt(17);
	int iWins = hResults.FetchInt(18);
	int iTop3Wins = hResults.FetchInt(19);
	int iPlaytime = hResults.FetchInt(20);
	float flPlaytimeHours = iPlaytime / 60.0 / 60.0;
	int iPlaytimeHoursHigh = RoundFloat(flPlaytimeHours * 10) / 10;
	int iPlaytimeHoursLow = RoundFloat(flPlaytimeHours * 10) % 10;
	int iHighestKS = hResults.FetchInt(21);
	char szHighestKSMap[64];
	hResults.FetchString(22, szHighestKSMap, 64);
	int iDamageDealt = hResults.FetchInt(23);
	int iDamageTaken = hResults.FetchInt(24);
	int iScore = hResults.FetchInt(25);
	CloseHandle(hResults);
	int iScorePlace = 0;
	char szScorePlaceColor[32];
	if(IsValidHandle(hResultsScorePlace)) {
		hResultsScorePlace.FetchRow();
		iScore = hResultsScorePlace.FetchInt(3);
		iScorePlace = hResultsScorePlace.FetchInt(4);
	}
	if(iScorePlace == 1)
		strcopy(szScorePlaceColor, 32, RATING_COLOR_TOP1);
	else if(iScorePlace < 1)
		strcopy(szScorePlaceColor, 32, RATING_COLOR_UNRANKED);
	else if(iScorePlace <= 5)
		strcopy(szScorePlaceColor, 32, RATING_COLOR_TOP5);
	else if(iScorePlace <= 10)
		strcopy(szScorePlaceColor, 32, RATING_COLOR_TOP10);
	else if(iScorePlace <= 100)
		strcopy(szScorePlaceColor, 32, RATING_COLOR_TOP100);
	else
		strcopy(szScorePlaceColor, 32, RATING_COLOR_UNRANKED);
	
	if(bSelfRequest)
		CPrintToChat(iClient, "%t %t", "OpenFrags ChatPrefix", "OpenFrags YourStats", szStatOwnerAuth);
	else
		CPrintToChat(iClient, "%t %t", "OpenFrags ChatPrefix", "OpenFrags PlayerStats", szName, szColor, szStatOwnerAuth);

	CPrintToChat(iClient, "%t", "OpenFrags StatsRating", iScore, iScorePlace, szScorePlaceColor);
	CPrintToChat(iClient, "%t", "OpenFrags StatsMatches", iWins, iTop3Wins, iMatches);
	CPrintToChat(iClient, "%t", "OpenFrags StatsPlaytime", iPlaytimeHoursHigh, iPlaytimeHoursLow);
	CPrintToChat(iClient, "%t", "OpenFrags StatsKD", iFrags, iDeaths, flKDR);
	CPrintToChat(iClient, "%t", "OpenFrags StatsMeleeAndPowerupKills", iMeleeKills, iPowerupKills);
	CPrintToChat(iClient, "%t", "OpenFrags StatsSSG", iSSGMeatshots, iSSGNormalShots, iSSGMisses);
	CPrintToChat(iClient, "%t", "OpenFrags StatsRGHeadshots", iRGHeadshots, iRGHeadshotPercentageHigh, iRGHeadshotPercentageLow);
	CPrintToChat(iClient, "%t", "OpenFrags StatsAirshots", iRLAirshots, iGLAirshots);
	CPrintToChat(iClient, "%t", "OpenFrags StatsHighestKillstreak", iHighestKS, szHighestKSMap);
	CPrintToChat(iClient, "%t", "OpenFrags StatsDamage", iDamageDealt, iDamageTaken);
}

// all of the vars below will have a queue system for tracking the threaded queries, and once everyone's !top request is fulfilled they will go back to null
int iBestRatedQ = 0;
char szBestRated[64];
char szBestRatedColor[12];
int iMostRating = 0;

int iBestFraggerQ = 0;
char szBestFragger[64];
char szBestFraggerColor[12];
int iMostFrags = 0;

int iBestHeadshotterQ = 0;
char szBestHeadshotter[64];
char szBestHeadshotterColor[12];
float flBestHSRate = 0.0;

int iBestKillstreakerQ = 0;
char szBestKillstreaker[64];
char szBestKillstreakerColor[12];
char szBestKillstreakerMap[64];
int iBestKillstreak = 0;

int iBestPlaytimerQ = 0;
char szBestPlaytimer[64];
char szBestPlaytimerColor[12];
float flMostPlaytimeHours = 0.0;

void PrintTopPlayers(int iClient) {
	char szQuery[512];
	
	// only once all the queries have finished the player will get the leaderboard
	Format(szQuery, 512, "SELECT steamid2, name, color, score FROM stats WHERE score = (SELECT MAX(score) FROM stats) AND matches >= %i ORDER BY score DESC;", MIN_LEADERBOARD_MATCHES);
	g_hSQL.Query(Callback_PrintTopPlayers_ReceivedTopRated, szQuery, iClient);
	
	Format(szQuery, 512, "SELECT steamid2, name, color, frags FROM stats WHERE (frags = (SELECT MAX(frags) FROM stats)) AND matches >= %i ORDER BY frags DESC;", MIN_LEADERBOARD_MATCHES);
	g_hSQL.Query(Callback_PrintTopPlayers_ReceivedTopFragger, szQuery, iClient);

	Format(szQuery, 512, "SELECT steamid2, name, color, railgun_headshotrate, railgun_headshots, railgun_bodyshots, railgun_misses FROM stats WHERE railgun_headshots >= %i AND matches >= %i ORDER BY railgun_headshotrate DESC;", MIN_LEADERBOARD_HEADSHOTS, MIN_LEADERBOARD_MATCHES);
	g_hSQL.Query(Callback_PrintTopPlayers_ReceivedTopHeadshotter, szQuery, iClient);

	Format(szQuery, 512, "SELECT steamid2, name, color, highest_killstreak, highest_killstreak_map, highest_killstreak_server FROM stats WHERE (highest_killstreak = (SELECT MAX(highest_killstreak) FROM stats)) AND matches >= %i ORDER BY highest_killstreak DESC;", MIN_LEADERBOARD_MATCHES);
	g_hSQL.Query(Callback_PrintTopPlayers_ReceivedTopKillstreaker, szQuery, iClient);
	
	Format(szQuery, 512, "SELECT steamid2, name, color, playtime FROM stats WHERE (playtime = (SELECT MAX(playtime) FROM stats)) AND matches >= %i ORDER BY playtime DESC;", MIN_LEADERBOARD_MATCHES);
	g_hSQL.Query(Callback_PrintTopPlayers_ReceivedTopPlaytimer, szQuery, iClient);
}

void Callback_PrintTopPlayers_ReceivedTopRated(Database hSQL, DBResultSet hResults, const char[] szErr, any iClient) {
	if(hResults.RowCount < 1) {
		char szQuery[512];
		Format(szQuery, 512, "SELECT steamid2, name, color, score FROM stats WHERE score = (SELECT MAX(score) FROM stats) AND matches >= %i ORDER BY score DESC;", 0);
		g_hSQL.Query(Callback_PrintTopPlayers_ReceivedTopRated, szQuery, iClient);
		return;
	}
	SQL_FetchRow(hResults);
	hResults.FetchString(1, szBestRated, 64);
	ColorIntToHex(hResults.FetchInt(2), szBestRatedColor);
	iMostRating = hResults.FetchInt(3);
	if(strlen(szBestRated) > MAX_LEADERBOARD_NAME_LENGTH)
		strcopy(szBestRated[MAX_LEADERBOARD_NAME_LENGTH-5], 4, "...");
		
	iBestRatedQ++;
	if(iBestRatedQ > 0 && iBestFraggerQ > 0 && iBestHeadshotterQ && iBestKillstreakerQ > 0 && iBestPlaytimerQ > 0)
		PrintTopPlayers_Finish(view_as<int>(iClient));
}

void Callback_PrintTopPlayers_ReceivedTopFragger(Database hSQL, DBResultSet hResults, const char[] szErr, any iClient) {
	if(hResults.RowCount < 1) {
		char szQuery[512];
		Format(szQuery, 512, "SELECT steamid2, name, color, frags FROM stats WHERE (frags = (SELECT MAX(frags) FROM stats)) AND matches >= %i ORDER BY frags DESC;", 0);
		g_hSQL.Query(Callback_PrintTopPlayers_ReceivedTopFragger, szQuery, iClient);
		return;
	}
	SQL_FetchRow(hResults);
	hResults.FetchString(1, szBestFragger, 64);
	ColorIntToHex(hResults.FetchInt(2), szBestFraggerColor);
	iMostFrags = hResults.FetchInt(3);
	if(strlen(szBestFragger) > MAX_LEADERBOARD_NAME_LENGTH)
		strcopy(szBestFragger[MAX_LEADERBOARD_NAME_LENGTH-5], 4, "...");
		
	iBestFraggerQ++;
	if(iBestRatedQ > 0 && iBestFraggerQ > 0 && iBestHeadshotterQ && iBestKillstreakerQ > 0 && iBestPlaytimerQ > 0)
		PrintTopPlayers_Finish(view_as<int>(iClient));
}

void Callback_PrintTopPlayers_ReceivedTopHeadshotter(Database hSQL, DBResultSet hResults, const char[] szErr, any iClient) {
	if(hResults.RowCount < 1) {
		char szQuery[512];
		Format(szQuery, 512, "SELECT steamid2, name, color, railgun_headshotrate, railgun_headshots, railgun_bodyshots, railgun_misses FROM stats WHERE railgun_headshots >= %i AND matches >= %i ORDER BY railgun_headshotrate DESC;", 0, 0);
		g_hSQL.Query(Callback_PrintTopPlayers_ReceivedTopHeadshotter, szQuery, iClient);
		return;
	}
	SQL_FetchRow(hResults);
	hResults.FetchString(1, szBestHeadshotter, 64);
	ColorIntToHex(hResults.FetchInt(2), szBestHeadshotterColor);
	flBestHSRate = hResults.FetchFloat(3);
	if(strlen(szBestHeadshotter) > MAX_LEADERBOARD_NAME_LENGTH)
		strcopy(szBestHeadshotter[MAX_LEADERBOARD_NAME_LENGTH-5], 4, "...");
	
	iBestHeadshotterQ++;
	if(iBestRatedQ > 0 && iBestFraggerQ > 0 && iBestHeadshotterQ && iBestKillstreakerQ > 0 && iBestPlaytimerQ > 0)
		PrintTopPlayers_Finish(view_as<int>(iClient));
}

void Callback_PrintTopPlayers_ReceivedTopKillstreaker(Database hSQL, DBResultSet hResults, const char[] szErr, any iClient) {
	if(hResults.RowCount < 1) {
		char szQuery[512];
		Format(szQuery, 512, "SELECT steamid2, name, color, highest_killstreak, highest_killstreak_map, highest_killstreak_server FROM stats WHERE (highest_killstreak = (SELECT MAX(highest_killstreak) FROM stats)) AND matches >= %i ORDER BY highest_killstreak DESC;", 0);
		g_hSQL.Query(Callback_PrintTopPlayers_ReceivedTopKillstreaker, szQuery, iClient);
		return;
	}
	SQL_FetchRow(hResults);
	hResults.FetchString(1, szBestKillstreaker, 64);
	ColorIntToHex(hResults.FetchInt(2), szBestKillstreakerColor);
	iBestKillstreak = hResults.FetchInt(3);
	hResults.FetchString(4, szBestKillstreakerMap, 64);
	if(strlen(szBestKillstreaker) > MAX_LEADERBOARD_NAME_LENGTH)
		strcopy(szBestKillstreaker[MAX_LEADERBOARD_NAME_LENGTH-5], 4, "...");
	
	iBestKillstreakerQ++;
	if(iBestRatedQ > 0 && iBestFraggerQ > 0 && iBestHeadshotterQ && iBestKillstreakerQ > 0 && iBestPlaytimerQ > 0)
		PrintTopPlayers_Finish(view_as<int>(iClient));
}

void Callback_PrintTopPlayers_ReceivedTopPlaytimer(Database hSQL, DBResultSet hResults, const char[] szErr, any iClient) {
	if(hResults.RowCount < 1) {
		char szQuery[512];
		Format(szQuery, 512, "SELECT steamid2, name, color, playtime FROM stats WHERE (playtime = (SELECT MAX(playtime) FROM stats)) AND matches >= %i ORDER BY playtime DESC;", 0);
		g_hSQL.Query(Callback_PrintTopPlayers_ReceivedTopPlaytimer, szQuery, iClient);
		return;
	}
	SQL_FetchRow(hResults);
	hResults.FetchString(1, szBestPlaytimer, 64);
	ColorIntToHex(hResults.FetchInt(2), szBestPlaytimerColor);
	flMostPlaytimeHours = hResults.FetchInt(3) / 3600.0;
	if(strlen(szBestPlaytimer) > MAX_LEADERBOARD_NAME_LENGTH)
		strcopy(szBestPlaytimer[MAX_LEADERBOARD_NAME_LENGTH-5], 4, "...");
	
	iBestPlaytimerQ++;
	if(iBestRatedQ > 0 && iBestFraggerQ > 0 && iBestHeadshotterQ && iBestKillstreakerQ > 0 && iBestPlaytimerQ > 0)
		PrintTopPlayers_Finish(view_as<int>(iClient));
}

void PrintTopPlayers_Finish(int iClient) {
	int iBestHSRateHigh = RoundFloat(flBestHSRate * 1000) / 10;
	int iBestHSRateLow = RoundFloat(flBestHSRate * 1000) % 10;
	int iMostPlaytimeHoursHigh = RoundFloat(flMostPlaytimeHours * 10) / 10;
	int iMostPlaytimeHoursLow = RoundFloat(flMostPlaytimeHours * 10) % 10;
	
	CPrintToChat(iClient, "%t %t", "OpenFrags ChatPrefix", "OpenFrags TopPlayers");
	CPrintToChat(iClient, "%t", "OpenFrags TopRating", szBestRated, szBestRatedColor, iMostRating);
	CPrintToChat(iClient, "%t", "OpenFrags TopFragger", szBestFragger, szBestFraggerColor, iMostFrags);
	CPrintToChat(iClient, "%t", "OpenFrags TopHeadshotter", szBestHeadshotter, szBestHeadshotterColor, iBestHSRateHigh, iBestHSRateLow);
	CPrintToChat(iClient, "%t", "OpenFrags TopKillstreaker", szBestKillstreaker, szBestKillstreakerColor, iBestKillstreak, szBestKillstreakerMap);
	CPrintToChat(iClient, "%t", "OpenFrags TopPlaytime", szBestPlaytimer, szBestPlaytimerColor, iMostPlaytimeHoursHigh, iMostPlaytimeHoursLow);
	
	iBestRatedQ -= 1;
	iBestFraggerQ -= 1;
	iBestHeadshotterQ -= 1;
	iBestKillstreakerQ -= 1;
	iBestPlaytimerQ -= 1;
}

bool g_bPrintPlayerEloScrewedUp = false;
void PrintPlayerElo(int iClient, int iStatsOwner, char[] szAuthArg = "") {
	g_bPrintPlayerEloScrewedUp = false;
	bool bSelfRequest = iClient == iStatsOwner;
	char szAuthToUse[32];
	if(iStatsOwner != -1) {
		if(!g_abInitializedClients[iStatsOwner]) {
			char szClientName[64];
			GetClientName(iStatsOwner, szClientName, 64);
			
			if(bSelfRequest)
				CPrintToChat(iClient, "%t %t", "OpenFrags ChatPrefix", "OpenFrags UninitializedSelf");
			else
				CPrintToChat(iClient, "%t %t", "OpenFrags ChatPrefix", "OpenFrags UninitializedPlayer", szClientName);
			return;
		}
		
		GetClientAuthId(iStatsOwner, AuthId_Steam2, szAuthToUse, 32);
	} else {
		strcopy(szAuthToUse, 32, szAuthArg);
	}
	
	DataPack hDatapack = new DataPack();
	hDatapack.WriteCell(iClient);
	hDatapack.WriteString(szAuthToUse);

	char szQuery[512];
	Format(szQuery, 512, QUERY_GETPLAYERELO, szAuthToUse, szAuthToUse);
	g_hSQL.Query(Callback_PrintPlayerElo_Check, szQuery, hDatapack, DBPrio_Normal);
}

void Callback_PrintPlayerElo_Check(Database hSQL, DBResultSet hResults, const char[] szErr, any hDatapackUncasted) {
	DataPack hDatapack = view_as<DataPack>(hDatapackUncasted);
	if(hResults.RowCount < 1 && !g_bPrintPlayerEloScrewedUp) {
		hDatapack.Reset();
		int iClient = hDatapack.ReadCell();
		g_bPrintPlayerEloScrewedUp = true;
		char szAuthToUse[32];
		char szQuery[512];
		GetClientAuthId(iClient, AuthId_Steam2, szAuthToUse, 32);

		CloseHandle(hDatapack);
		DataPack hNewDatapack = new DataPack();
		hNewDatapack.WriteCell(iClient);
		hNewDatapack.WriteString(szAuthToUse);
		
		Format(szQuery, 512, QUERY_GETPLAYERELO, szAuthToUse, szAuthToUse);
		g_hSQL.Query(Callback_PrintPlayerStats_Check, szQuery, hNewDatapack, DBPrio_Normal);
	} else if(hResults.RowCount < 1) {
		hDatapack.Reset();
		int iClient = hDatapack.ReadCell();
		CPrintToChat(iClient, "%t %t", "OpenFrags ChatPrefix", "OpenFrags StatsError");
		CloseHandle(hDatapack);
		return;
	} else {
		g_bPrintPlayerEloScrewedUp = false;
		hDatapack.WriteCell(hResults);
		
		PrintPlayerElo_Finish(hDatapack);
		CloseHandle(hDatapack);
	}
}

void PrintPlayerElo_Finish(DataPack hDatapack) {
	hDatapack.Reset();
	int iClient = hDatapack.ReadCell();
	char szQueriedAuth[32];
	hDatapack.ReadString(szQueriedAuth, 32);
	DBResultSet hResults = hDatapack.ReadCell();
	hResults.FetchRow();
	
	char szAuth[32];
	char szStatOwnerAuth[32];
	hResults.FetchString(0, szStatOwnerAuth, 32);
	GetClientAuthId(iClient, AuthId_Steam2, szAuth, 32);
	bool bSelfRequest = strcmp(szAuth, szStatOwnerAuth) == 0;
	
	char szName[64];
	hResults.FetchString(1, szName, 64);
	int iColor = hResults.FetchInt(2);
	char szColor[12];
	ColorIntToHex(iColor, szColor, 12);
	int iElo = hResults.FetchInt(3);
	int iEloPlace = hResults.FetchInt(4);
	char szEloPlaceColor[16];
	
	if(iEloPlace == 1)
		strcopy(szEloPlaceColor, 16, RATING_COLOR_TOP1);
	else if(iEloPlace < 1)
		strcopy(szEloPlaceColor, 16, RATING_COLOR_UNRANKED);
	else if(iEloPlace <= 5)
		strcopy(szEloPlaceColor, 16, RATING_COLOR_TOP5);
	else if(iEloPlace <= 10)
		strcopy(szEloPlaceColor, 16, RATING_COLOR_TOP10);
	else if(iEloPlace <= 100)
		strcopy(szEloPlaceColor, 16, RATING_COLOR_TOP100);
	else
		strcopy(szEloPlaceColor, 16, RATING_COLOR_UNRANKED);
	
	if(bSelfRequest)
		CPrintToChat(iClient, "%t %t %s[#%i]", "OpenFrags ChatPrefix", "OpenFrags YourElo", iElo, szEloPlaceColor, iEloPlace);
	else
		CPrintToChat(iClient, "%t %t %s[#%i]", "OpenFrags ChatPrefix", "OpenFrags PlayerElo", szName, szColor, iElo, szEloPlaceColor, iEloPlace);
}

void PrintPlayerElos(int iClient) {
	char szQuery[4096];
	Format(szQuery, 4096, "SELECT `steamid2`, `name`, `color`, `elo` FROM `stats` WHERE ");
	for(int i = 1; i < MaxClients; ++i) {
		if(!IsClientInGame(i))
			continue;
		
		char szAuth[32];
		GetClientAuthId(i, AuthId_Steam2, szAuth, 32);
		Format(szQuery, 4096, "%s `steamid2`='%s' OR", szQuery, szAuth);
	}
	Format(szQuery, strlen(szQuery)-2, "%s", szQuery);
	Format(szQuery, 4096, "%s ORDER BY `elo` DESC;", szQuery);
	g_hSQL.Query(Callback_PrintPlayerElos_Finish, szQuery, iClient);
}

void Callback_PrintPlayerElos_Finish(Database hSQL, DBResultSet hResults, const char[] szErr, any iClientUncasted) {
	int iClient = view_as<int>(iClientUncasted);
	if(strlen(szErr) > 0)
		LogError("An error occured while querying for current player Elos: %s", szErr);
	
	CPrintToChat(iClient, "%t %t", "OpenFrags ChatPrefix", "OpenFrags PlayersElos");
	for(int i = 0; i < hResults.RowCount; ++i) {
		hResults.FetchRow();
		char szName[64];
		hResults.FetchString(1, szName, 64);
		char szColor[12];
		ColorIntToHex(hResults.FetchInt(2), szColor, 12);
		int iElo = hResults.FetchInt(3);
		CPrintToChat(iClient, "%t", "OpenFrags PlayersElo", i+1, szName, szColor, iElo);
	}
}


public Action OnClientSayCommand(int iClient, const char[] szCommand, const char[] szArg) {
	char szArgs[3][64];
	int iArgs = ExplodeString(szArg, " ", szArgs, 3, 64, true);
	char szChatCommand[63];
	strcopy(szChatCommand, 63, szArgs[0][1]);
	
	Action retval = Plugin_Continue;
	if(szArgs[0][0] == '/') {
		retval = Plugin_Stop;
	} else if(szArgs[0][0] == '!') {
		retval = Plugin_Continue;
	} else {
		return Plugin_Continue;
	}
	
	if(StrEqual(szChatCommand, "stats", false) && iArgs == 1) {
		PrintPlayerStats(iClient, iClient);
		return retval;
	}
	if(StrEqual(szChatCommand, "top", false) || StrEqual(szChatCommand, "leaderboard", false)) {
		PrintTopPlayers(iClient);
		return retval;
	}
	// TODO add /rating as an alias
	if(StrEqual(szChatCommand, "elo", false) && iArgs == 1) {
		PrintPlayerElo(iClient, iClient);
		return retval;
	}
	// TODO add /ratings as an alias
	if(StrEqual(szChatCommand, "elos", false) && iArgs == 1) {
		PrintPlayerElos(iClient);
		return retval;
	}
	if(StrEqual(szChatCommand, "optout", false) || StrEqual(szChatCommand, "opt-out", false)) {
		Command_OptOut(iClient, 0);
		return retval;
	}
	// TODO add /rating as an alias
	if(StrEqual(szChatCommand, "elo", false)) {
		int aiTargets[1];
		char szTarget[64];
		bool bIsMLPhrase = false;
		int iTargetsFound = ProcessTargetString(szArgs[1], 0, aiTargets, 1, 0, szTarget, 128, bIsMLPhrase);
		if(iTargetsFound > 0) {
			PrintPlayerElo(iClient, aiTargets[0]);
			return retval;
		} else {
			char szAuth[32];
			strcopy(szAuth, 32, szArgs[1]);
			ReplaceString(szAuth, 32, "'", "");
			ReplaceString(szAuth, 32, ")", "");
			ReplaceString(szAuth, 32, "\"", "");
			ReplaceString(szAuth, 32, "\\", "");
			PrintPlayerElo(iClient, -1, szAuth);
			return retval;
		}
	}

	if(StrEqual(szChatCommand, "stats", false)) {
		int aiTargets[1];
		char szTarget[64];
		bool bIsMLPhrase = false;
		int iTargetsFound = ProcessTargetString(szArgs[1], 0, aiTargets, 1, 0, szTarget, 128, bIsMLPhrase);
		if(iTargetsFound > 0) {
			PrintPlayerStats(iClient, aiTargets[0]);
			return retval;
		} else {
			char szAuth[32];
			strcopy(szAuth, 32, szArgs[1]);
			ReplaceString(szAuth, 32, "'", "");
			ReplaceString(szAuth, 32, ")", "");
			ReplaceString(szAuth, 32, "\"", "");
			ReplaceString(szAuth, 32, "\\", "");
			PrintPlayerStats(iClient, -1, szAuth);
			return retval;
		}
	}
	
	return retval;
}

Action Command_ViewStats(int iClient, int iArgs) {
	if(iArgs == 0)
		PrintPlayerStats(iClient, iClient);
	else {
		char szTargetName[64];
		GetCmdArg(1, szTargetName, 64)
		int aiTargets[1];
		char szTarget[128];
		bool bIsMLPhrase = false;
		int iTargetsFound = ProcessTargetString(szTargetName, 0, aiTargets, 1, 0, szTarget, 128, bIsMLPhrase);
		
		if(iTargetsFound > 0) {
			PrintPlayerStats(iClient, aiTargets[0]);
			return Plugin_Handled;
		} else {
			char szAuth[32];
			GetCmdArg(1, szAuth, 32);
			if(strlen(szAuth) < 7) {
				ReplyToCommand(iClient, "[OF] No target found; if you meant to use a SteamID2, you need to use quotes (e.g sm_playerstats_stats \"STEAM_0:1:522065531\")")
				return Plugin_Handled;
			}
			ReplaceString(szAuth, 32, "'", "");
			ReplaceString(szAuth, 32, ")", "");
			ReplaceString(szAuth, 32, "\"", "");
			ReplaceString(szAuth, 32, "\\", "");
			PrintPlayerStats(iClient, -1, szAuth);
			return Plugin_Handled;
		}
	}
	
	return Plugin_Handled;
}

Action Command_ViewElo(int iClient, int iArgs) {
	if(iArgs == 0)
		PrintPlayerElo(iClient, iClient);
	else {
		char szTargetName[64];
		GetCmdArg(1, szTargetName, 64)
		int aiTargets[1];
		char szTarget[128];
		bool bIsMLPhrase = false;
		int iTargetsFound = ProcessTargetString(szTargetName, 0, aiTargets, 1, 0, szTarget, 128, bIsMLPhrase);
		
		if(iTargetsFound > 0) {
			PrintPlayerElo(iClient, aiTargets[0]);
			return Plugin_Handled;
		} else {
			char szAuth[32];
			GetCmdArg(1, szAuth, 32);
			if(strlen(szAuth) < 7) {
				ReplyToCommand(iClient, "[OF] No target found; if you meant to use a SteamID2, you need to use quotes (e.g sm_playerstats_stats \"STEAM_0:1:522065531\")")
				return Plugin_Handled;
			}
			ReplaceString(szAuth, 32, "'", "");
			ReplaceString(szAuth, 32, ")", "");
			ReplaceString(szAuth, 32, "\"", "");
			ReplaceString(szAuth, 32, "\\", "");
			PrintPlayerElo(iClient, -1, szAuth);
			return Plugin_Handled;
		}
	}
	
	return Plugin_Handled;
}

Action Command_ViewElos(int iClient, int iArgs) {
	PrintPlayerElos(iClient);
	
	return Plugin_Handled;
}


Action Command_ViewTop(int iClient, int iArgs) {
	PrintTopPlayers(iClient);
	return Plugin_Handled;
}

Action Command_AboutPlugin(int iClient, int iArgs) {
	if(iClient != 0)
		CPrintToChat(iClient, "%t %t", "OpenFrags ChatPrefix", "OpenFrags About", PLUGIN_VERSION);
	else {
		char szAbout[256];
		Format(szAbout, 256, "%t %t", "OpenFrags ChatPrefix", "OpenFrags About", PLUGIN_VERSION);
		CRemoveTags(szAbout, 256);
		PrintToServer(szAbout);
	}
	return Plugin_Handled;
}

// for confirmation
bool g_bOptOutConfirm = false;

int g_iRemovedStatsQ = 0;
int g_iAddedBanQ = 0;
bool g_bThrewOptOutErrorAlready = false;
Action Command_OptOut(int iClient, int iArgs) {
	if(iClient == 0) {
		ReplyToCommand(iClient, "You can't run this command as the server!");
		return Plugin_Handled;
	}
	
	if(!g_abInitializedClients) {
		CPrintToChat(iClient, "%t %t", "OpenFrags ChatPrefix", "OpenFrags UninitializedSelf");
	}
	
	if(!g_bOptOutConfirm) {
		g_bOptOutConfirm = true;
		CPrintToChat(iClient, "%t %t", "OpenFrags ChatPrefix", "OpenFrags OptOutConfirm");
		CreateTimer(10.0, Delayed_OptOutCancel);
		return Plugin_Handled;
	}
	
	g_bThrewOptOutErrorAlready = false;
	
	CPrintToChat(iClient, "%t %t", "OpenFrags ChatPrefix", "OpenFrags OptingOut");
	
	char szAuth[32];
	GetClientAuthId(iClient, AuthId_Steam2, szAuth, 32);
	
	char szClientName[64];
	char szClientNameSafe[129];
	GetClientName(iClient, szClientName, 64);
	SQL_EscapeString(g_hSQL, szClientName, szClientNameSafe, 64);
	
	char szQueryOptOut[512];
	Format(szQueryOptOut, 512, "DELETE FROM stats WHERE steamid2 = '%s';", szAuth);
	g_hSQL.Query(Callback_OptOut_RemovedStats, szQueryOptOut, iClient, DBPrio_High);

	Format(szQueryOptOut, 512, "INSERT INTO bans (steamid2, name, is_banned, ban_reason, timestamp, expiration) VALUES ('%s', '%s', 1, 'In-game opt-out', 0, 0);", szAuth, szClientNameSafe);
	g_hSQL.Query(Callback_OptOut_AddedBan, szQueryOptOut, iClient, DBPrio_High);
	return Plugin_Handled;
}

Action Delayed_OptOutCancel(Handle hTimer) {
	g_bOptOutConfirm = false;
	return Plugin_Handled;
}

void Callback_OptOut_RemovedStats(Database hSQL, DBResultSet hResults, const char[] szErr, any iClientUncasted) {
	int iClient = view_as<int>(iClientUncasted);
	if(!IsValidHandle(hSQL) || strlen(szErr) > 0) {
		if(!g_bThrewOptOutErrorAlready)
			CPrintToChat(iClient, "%t %t", "OpenFrags ChatPrefix", "OpenFrags Error");
			
		g_bThrewOptOutErrorAlready = true;
		return;
	}
	
	g_iRemovedStatsQ++;
	if(g_iRemovedStatsQ > 0 && g_iAddedBanQ > 0) {
		CPrintToChat(iClient, "%t %t", "OpenFrags ChatPrefix", "OpenFrags OptedOut");
		g_abInitializedClients[iClient] = false;
		g_iRemovedStatsQ -= 1;
		g_iAddedBanQ -= 1;
	}
}

void Callback_OptOut_AddedBan(Database hSQL, DBResultSet hResults, const char[] szErr, any iClientUncasted) {
	int iClient = view_as<int>(iClientUncasted);
	if(!IsValidHandle(hSQL) || strlen(szErr) > 0) {
		if(!g_bThrewOptOutErrorAlready)
			CPrintToChat(iClient, "%t %t", "OpenFrags ChatPrefix", "OpenFrags Error");
		
		g_bThrewOptOutErrorAlready = true;
		return;
	}
	
	g_iAddedBanQ++;
	if(g_iRemovedStatsQ > 0 && g_iAddedBanQ > 0) {
		CPrintToChat(iClient, "%t %t", "OpenFrags ChatPrefix", "OpenFrags OptedOut");
		g_abInitializedClients[iClient] = false;
		g_iRemovedStatsQ -= 1;
		g_iAddedBanQ -= 1;
	}
}

Action Command_TestEligibility(int iClient, int iArgs) {
	bool bEnoughPlayers = GetClientCount(true) >= 2;
	bool bMutator = g_nCurrentRoundMutator == OFMutator_None ||
					g_nCurrentRoundMutator == OFMutator_Arsenal ||
					g_nCurrentRoundMutator == OFMutator_ClanArena;
	bool bCheats = !GetConVarBool(FindConVar("sv_cheats"));
	bool bWaitingForPlayers = view_as<bool>(GameRules_GetProp("m_bInWaitingForPlayers"));
	
	if(!bEnoughPlayers)
		ReplyToCommand(iClient, "[OF] The server doens't have enough players (currently %i players, the requirement is %i or more)", GetClientCount(true), 2);
	
	if(bWaitingForPlayers)
		ReplyToCommand(iClient, "[OF] The round hasn't yet started");
		
	if(!g_bRoundGoing)
		ReplyToCommand(iClient, "[OF] The round has already ended");

	if(!bMutator)
		ReplyToCommand(iClient, "[OF] The server has an unacceptable mutator running (%i)", g_nCurrentRoundMutator);
	
	if(!bCheats)
		ReplyToCommand(iClient, "[OF] The server has sv_cheats enabled");
	
	if(bEnoughPlayers && bMutator && bCheats && !bWaitingForPlayers && g_bRoundGoing)
		ReplyToCommand(iClient, "[OF] This server is eligible for stat tracking! (%i)", IsServerEligibleForStats());
		
	return Plugin_Handled;
}

Action Command_TestEloUpdateAll(int iClient, int iArgs) {
	if(!IsServerEligibleForStats()) {
		ReplyToCommand(iClient, "[OF] This command can't be run on a non-eligible server");
		return Plugin_Handled;
	}
	if(g_bDuels) {
		ReplyToCommand(iClient, "[OF] This command can't be run on a duel server");
		return Plugin_Handled;
	}
	Elo_UpdateAll(true);
	return Plugin_Handled;
}

Action Command_ViewCachedElos(int iClient, int iArgs) {
	for(int i = 1; i < MaxClients; ++i) {
		if(!IsClientInGame(i))
			continue
		
		char szName[64];
		GetClientName(i, szName, 64);
		ReplyToCommand(iClient, "%i. %s: %f", i, szName, g_aflElos[i]);
	}
	return Plugin_Handled;
}

Action Command_TestIncrementField(int iClient, int iArgs) {
	ReplyToCommand(iClient, "[OF] Testing IncrementField 0/7");
	
	bool bThreadedQuery = true;
	if(iArgs > 0) {
		if (GetCmdArgInt(0) == 2)
			bThreadedQuery = false;
	}
	ReplyToCommand(iClient, "[OF] Checking for client validity (Client: %i)", iClient);
	if(iClient <= 0 || iClient >= MAXPLAYERS)
		return Plugin_Handled;
	
	ReplyToCommand(iClient, "[OF] Checking for if client's data is initialized");
	
	if(!g_abInitializedClients[iClient])
		return Plugin_Handled;
		
	ReplyToCommand(iClient, "[OF] Checking server for eligibility");
		
	if(!IsServerEligibleForStats())
		return Plugin_Handled;
		
	ReplyToCommand(iClient, "[OF] Getting client SteamID2");
	
	char szAuth[32];
	GetClientAuthId(iClient, AuthId_Steam2, szAuth, 32);
	
	ReplyToCommand(iClient, "[OF] Making query");
	
	char szField[64];
	strcopy(szField, 64, "damage_dealt");
	int iAdd = 1;
	char szQuery[700];
	Format(szQuery, 700, "UPDATE stats SET \
										%s = (%s + %i) \
										WHERE steamid2 = '%s'", szField, szField, iAdd, szAuth);
										
	ReplyToCommand(iClient, "[OF] Sending query to MySQL server");
	
	if(bThreadedQuery)
		g_hSQL.Query(Callback_None, szQuery, 0, DBPrio_Low);
	else {
		if(!SQL_FastQuery(g_hSQL, szQuery)) {
			char szErr[256];
			SQL_GetError(g_hSQL, szErr, 256);
			ReplyToCommand(iClient, "[OF] An error occured while sending the query: %s", szErr);
			return Plugin_Handled;
		}
	}
	
	ReplyToCommand(iClient, "[OF] TestingIncrementField Done!");
	return Plugin_Handled;
}

void Event_SvTagsChanged(ConVar cvarTags, const char[] szOld, const char[] szNew) {
	if(g_bSvTagsChangedDebounce)
		return;
	
	g_bSvTagsChangedDebounce = true;
	CreateTimer(0.5, Delayed_SvTagsChangedDebounce);
	AddServerTagRat("openfrags");
}

Action Delayed_SvTagsChangedDebounce(Handle hTimer) {
	g_bSvTagsChangedDebounce = false;
	return Plugin_Handled;
}
	
void AddServerTagRat(char[] strTag) {
	ConVar cvarTags = FindConVar("sv_tags");
	char strServTags[128];
	GetConVarString(cvarTags, strServTags, 128);
	
	int iServTagsLen = strlen(strServTags);
	int iTagLen = strlen(strTag);
	
	bool bFoundTag = StrContains(strServTags, strTag, false) != -1;
	if(bFoundTag) {
		return;
	}

	if(iServTagsLen + iTagLen+1 > 127) {
		return;
	}
	
	strServTags[iServTagsLen] = ',';
	strcopy(strServTags[iServTagsLen + 1], 64, strTag);
	
	int iFlags = GetConVarFlags(cvarTags)
	SetConVarFlags(cvarTags, iFlags & ~FCVAR_NOTIFY);
	SetConVarString(cvarTags, strServTags, false, false);
	SetConVarFlags(cvarTags, iFlags);
}

stock void RemoveServerTagRat(char[] strTag) {
	ConVar cvarTags = FindConVar("sv_tags");
	char strServTags[128];
	GetConVarString(cvarTags, strServTags, 128);
	
	int iFoundTagAt = StrContains(strServTags, strTag, false);
	if(iFoundTagAt == -1) {
		return;
	}
	
	ReplaceString(strServTags, 128, strTag, "", false);
	ReplaceString(strServTags, 128, ",,", ",", false);
	
	int iFlags = GetConVarFlags(cvarTags)
	SetConVarFlags(cvarTags, iFlags & ~FCVAR_NOTIFY);
	SetConVarString(cvarTags, strServTags, false, false);
	SetConVarFlags(cvarTags, iFlags);
}
