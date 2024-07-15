#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <openfortress>
#include <morecolors>
#include <updater>

#define PLUGIN_VERSION "d1.1a"
#define UPDATE_URL "http://insecuregit.ohaa.xyz/ratest/openfrags/raw/branch/duels/updatefile.txt"
#define MAX_LEADERBOARD_NAME_LENGTH 32
#define RATING_COLOR_TOP1 "{mediumpurple}"
#define RATING_COLOR_TOP5 "{gold}"
#define RATING_COLOR_TOP10 "{immortal}"
#define RATING_COLOR_TOP100 "{snow}"
#define RATING_COLOR_UNRANKED "{gray}"

#define QUERY_CREATETABLESTATS "CREATE TABLE IF NOT EXISTS `stats_duels` ( \
												  `steamid2` varchar(32) NOT NULL, \
												  `name` varchar(64) DEFAULT 'None', \
												  `color` int(11) DEFAULT 0, \
												  `frags` int(11) DEFAULT 0, \
												  `deaths` int(11) DEFAULT 0, \
												  `kdr` float DEFAULT 0, \
												  `powerup_kills` int(11) DEFAULT 0, \
												  `melee_kills` int(11) DEFAULT 0, \
												  `railgun_headshots` int(11) DEFAULT 0, \
												  `railgun_bodyshots` int(11) DEFAULT 0, \
												  `railgun_misses` int(11) DEFAULT 0, \
												  `railgun_headshotrate` float DEFAULT 0, \
												  `rocketlauncher_airshots` int(11) DEFAULT 0, \
												  `chinalake_airshots` int(11) DEFAULT 0, \
												  `ssg_meatshots` int(11) DEFAULT 0, \
												  `ssg_normalshots` int(11) DEFAULT 0, \
												  `ssg_misses` int(11) DEFAULT 0, \
												  `matches` int(11) DEFAULT 0, \
												  `wins` int(11) DEFAULT 0, \
												  `winrate` float DEFAULT 0, \
												  `join_count` int(11) DEFAULT 0, \
												  `playtime` int(11) DEFAULT 0, \
												  `highest_killstreak` smallint(6) DEFAULT 0, \
												  `highest_killstreak_map` varchar(64) DEFAULT 'None', \
												  `damage_dealt` bigint(20) DEFAULT 0, \
												  `damage_taken` bigint(20) DEFAULT 0, \
												  `elo` int(11) DEFAULT 1000, \
												  `perfects` int(11) DEFAULT 0, \
												  `notified` tinyint(1) DEFAULT 0, \
												  PRIMARY KEY (`steamid2`) \
												) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_general_ci;"
#define QUERY_CREATETABLEBANS "CREATE TABLE IF NOT EXISTS `bans` ( \
												  `steamid2` varchar(32) NOT NULL, \
												  `name` varchar(64) DEFAULT NULL, \
												  `is_banned` tinyint(1) DEFAULT NULL, \
												  `ban_reason` varchar(64) DEFAULT NULL, \
												  `timestamp` int(11) DEFAULT NULL, \
												  `expiration` int(11) DEFAULT NULL, \
												  `bannedby` varchar(32) DEFAULT NULL, \
												  PRIMARY KEY (`steamid2`) \
												) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_general_ci;"
#define QUERY_INSERTPLAYER "INSERT IGNORE INTO stats_duels ( \
												steamid2, \
												name, \
												color \
												) \
												VALUES ( \
												'%s', \
												'%s', \
												%i \
												);"
#define QUERY_GETPLAYERELO "SELECT \
									steamid2, \
									name, \
									color, \
									elo, \
									(SELECT rating_place FROM \
										(SELECT ROW_NUMBER() OVER (ORDER BY elo DESC) \
												rating_place, \
												elo, \
												steamid2, \
												name \
												FROM stats_duels) \
											AS rating_place WHERE steamid2 = '%s') \
										AS rating_place \
									FROM stats_duels \
									WHERE steamid2 = '%s';"
									
#define QUERY_GETELOLEADERBOARD "SELECT \
									steamid2, \
									name, \
									color, \
									elo \
									FROM stats_duels \
									WHERE steamid2 = '%s' \
									ORDER BY elo DESC \
									LIMIT 0, 10;"

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

ConVar g_cvarNotifyElos = null;

Database g_hSQL;

bool g_bFirstConnectionEstabilished = false;
// for checking if the connection fails; don't want to spam the server error log with the same error over and over
bool g_bThrewErrorAlready = false;
bool g_abInitializedClients[MAXPLAYERS];
int g_aiKillstreaks[MAXPLAYERS];
bool g_abPlayerDied[MAXPLAYERS];
int g_aiPlayerJoinTimes[MAXPLAYERS];
int g_aiPlayerDamageDealtStore[MAXPLAYERS];
int g_aiPlayerDamageTakenStore[MAXPLAYERS];
bool g_abPlayerJoinedBeforeHalfway[MAXPLAYERS];
int g_aiElos[MAXPLAYERS];
bool g_abPlayerNotifiedOfOF[MAXPLAYERS];
int g_iCurrentDuelers[2];
bool g_bRoundGoing = true;
int g_timeRoundStart = 0;
bool g_bSvTagsChangedDebounce = false;
int g_nCurrentRoundMutator = 0;

// for weapons like the ssg which can trigger multiple misses on 1 attack
bool g_abSSGHitDebounce[MAXPLAYERS];

public Plugin myinfo = {
	name = "OpenFrags-Duels",
	author = "ratest & Oha",
	description = "Keeps track of your stats!",
	version = PLUGIN_VERSION,
	url = "https://git.ohaa.xyz/ratest/openfrags/src/branch/duels"
};

public void OnPluginStart() {
	LoadTranslations("openfrags.phrases.txt");
	
	g_cvarNotifyElos = CreateConVar("sm_openfrags_announce_elos", "1", "Announce player ELOs each time a round starts", 0, true, 0.0, true, 1.0);
	
	RegConsoleCmd("sm_openfrags", Command_AboutPlugin, "Information on OpenFrags-Duels");
	RegConsoleCmd("sm_openfrags_duels", Command_AboutPlugin, "Information on OpenFrags-Duels");
	RegConsoleCmd("sm_openfrags_stats", Command_ViewStats, "View your stats (or someone else's)");
	RegConsoleCmd("sm_openfrags_top", Command_ViewTop, "View the top players");
	RegConsoleCmd("sm_openfrags_leaderboard", Command_ViewTop, "View the top players");
	RegConsoleCmd("sm_openfrags_optout", Command_OptOut, "Delete all the data stored associated with the caller and permanently opt out of the stat tracking");
	RegConsoleCmd("sm_openfrags_eligibility", Command_TestEligibility, "Check for if the server is eligible for stat tracking");
	
	RegAdminCmd("sm_openfrags_myscore", Command_MyScore, ADMFLAG_CHAT, "Print your current score/frags");
	RegAdminCmd("sm_openfrags_test_query", Command_TestIncrementField, ADMFLAG_CONVARS, "Run a test query to see if the plugin works. Should only be ran by a user and not the server!");

	SQL_TConnect(Callback_DatabaseConnected, "openfrags-duels");
	
	CreateTimer(60.0, Loop_ConnectionCheck);
	AddServerTagRat("openfrags-duels");
	FindConVar("sv_tags").AddChangeHook(Event_SvTagsChanged);
	
	if(LibraryExists("updater")) {
		Updater_AddPlugin(UPDATE_URL);
	}
}

public OnLibraryAdded(const char[] szName)
{
    if(StrEqual(szName, "updater"))
    {
        Updater_AddPlugin(UPDATE_URL)
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
			
			//g_hSQL.Query(Callback_None, QUERY_CREATETABLESTATS, 813, DBPrio_High);
			//g_hSQL.Query(Callback_None, QUERY_CREATETABLEBANS, 814, DBPrio_High);

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
		SQL_TConnect(Callback_DatabaseConnected, "openfrags-duels");
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
	// screw u rodrigo286 https://forums.alliedmods.net/showthread.php?t=196136
	// int iTimePassed = GameRules_GetProp("m_iRoundTime");
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
	g_hSQL.Query(Callback_InitPlayerData_Check, szQueryCheckPlayerBan, iClient, DBPrio_High);
}

void Callback_InitPlayerData_Check(Database hSQL, DBResultSet hResults, const char[] szErr, any iClientUncasted) {
	int iClient = view_as<int>(iClientUncasted);
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
	Format(szQueryInsertNewPlayer, 512, QUERY_INSERTPLAYER, szAuth, szClientNameSafe, GetPlayerColor(iClient));
	g_hSQL.Query(Callback_InitPlayerData_GetElo, szQueryInsertNewPlayer, iClient, DBPrio_High);
}

void Callback_InitPlayerData_GetElo(Database hSQL, DBResultSet hResults, const char[] szErr, any iClientUncasted) {
	int iClient = view_as<int>(iClientUncasted);
	
	char szAuth[32];
	GetClientAuthId(iClient, AuthId_Steam2, szAuth, 32);
	
	char szQueryGetElo[512];
	Format(szQueryGetElo, 512, QUERY_GETPLAYERELO, szAuth, szAuth);
	g_hSQL.Query(Callback_InitPlayerData_Final, szQueryGetElo, iClient, DBPrio_High);
}

void Callback_InitPlayerData_Final(Database hSQL, DBResultSet hResults, const char[] szErr, any iClientUncasted) {
	int iClient = view_as<int>(iClientUncasted);
	
	g_abInitializedClients[iClient] = true;
	hResults.FetchRow();
	g_aiElos[iClient] = hResults.FetchInt(3);
	
	char szAuth[32];
	GetClientAuthId(iClient, AuthId_Steam2, szAuth, 32);
	
	char szClientName[64];
	char szClientNameSafe[129];
	GetClientName(iClient, szClientName, 64);
	SQL_EscapeString(g_hSQL, szClientName, szClientNameSafe, 64);
	
	int iPlayerColor = GetPlayerColor(iClient);
	char szQueryUpdatePlayer[256];
	Format(szQueryUpdatePlayer, 256, "UPDATE stats_duels SET name = '%s', color = %i, join_count = join_count + 1 WHERE steamid2 = '%s'", szClientNameSafe, iPlayerColor, szAuth);
	g_hSQL.Query(Callback_None, szQueryUpdatePlayer, 5, DBPrio_Low);
	
	OnClientDataInitialized(iClient);
}

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
	Format(szQuery, 512, "UPDATE stats_duels SET \
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
	GetCurrentMap(szMap, 64);
	Format(szQueryUpdate, 512, "UPDATE stats_duels SET highest_killstreak = CASE WHEN highest_killstreak < %i THEN %i ELSE highest_killstreak END, \
												highest_killstreak_map = CASE WHEN (highest_killstreak = %i AND highest_killstreak > 0) THEN '%s' ELSE highest_killstreak_map END \
												WHERE steamid2 = '%s';",
												iKillstreak, iKillstreak, iKillstreak, szMap, szAuth);

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
	Format(szQueryCheckNotifiedChatAlready, 128, "SELECT steamid2, name, notified FROM stats_duels WHERE steamid2 = '%s'", szAuth);
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
	
	if(!bNotified) {
		CPrintToChat(iClient, "%t %t", "OpenFrags-Duels ChatPrefix", "OpenFrags-Duels Notify");
		PrintToConsole(iClient, "[OFD] Available commands:\n/stats to see your stats\n/top to view the leaderboard\n/elos to see the current players' Elos\n/elo to see your Elo\n/optout to completely opt out of the stat tracking");
	}
	else {
		PrintToConsole(iClient, "[OFD] This server is running OpenFrags-Duels");
		PrintToConsole(iClient, "[OFD] Available commands:\n/stats to see your stats\n/top to view the leaderboard\n/elos to see the current players' Elos\n/elo to see your Elo\n/optout to completely opt out of the stat tracking");
	}
	
	char szAuth[32];
	hResults.FetchString(0, szAuth, 32);
	
	char szQuerySetNotified[128];
	Format(szQuerySetNotified, 128, "UPDATE stats_duels SET notified=1 WHERE steamid2 = '%s'", szAuth);
	g_hSQL.Query(Callback_None, szQuerySetNotified, 38, DBPrio_Low);
}

public void OnClientPutInServer(int iClient) {
	SDKHook(iClient, SDKHook_OnTakeDamage, Event_PlayerDamaged);
}

void Event_PlayerDisconnect(Event event, const char[] szEventName, bool bDontBroadcast) {
	int iClient = GetClientOfUserId(GetEventInt(event, "userid"));
	char szDisconectReason[128];
	GetEventString(event, "reason", szDisconectReason, 128);
	
	if(g_abPlayerJoinedBeforeHalfway[iClient] && IsRoundHalfwayDone() && g_bRoundGoing && (StrContains(szDisconectReason, "timed out", false) == -1 && StrContains(szDisconectReason, "kicked", false) == -1 && StrContains(szDisconectReason, "connection closing", false) == -1)) {
		IncrementField(iClient, "matches");
		if(g_iCurrentDuelers[0] != -1 && g_iCurrentDuelers[1] != -1) {
			int iWinner = g_iCurrentDuelers[0] == iClient ? g_iCurrentDuelers[1] : g_iCurrentDuelers[0];
			int iLoser = g_iCurrentDuelers[0] == iClient ? g_iCurrentDuelers[0] : g_iCurrentDuelers[1];
			
			IncrementField(iWinner, "matches");
			IncrementField(iWinner, "wins");
	
			UpdatePlayerElo(iWinner, GetExpectedScore(iWinner, iLoser), true);
			UpdatePlayerElo(iLoser, GetExpectedScore(iLoser, iWinner), false);
		}
	}
	
	ResetKillstreak(iClient);
	UpdateStoredStats(iClient);
	g_abInitializedClients[iClient] = false;
	g_aiPlayerJoinTimes[iClient] = 0;
	g_aiElos[iClient] = 0;
	g_iCurrentDuelers[0] = -1;
	g_iCurrentDuelers[1] = -1;
	g_abPlayerJoinedBeforeHalfway[iClient] = false;
	g_abPlayerNotifiedOfOF[iClient] = false;
}

public void OnMapStart() {
	AddServerTagRat("openfrags-duels");
	g_bRoundGoing = true;
	g_timeRoundStart = GetTime();
	g_nCurrentRoundMutator = GetConVarInt(FindConVar("of_mutator"));
	g_iCurrentDuelers[0] = -1;
	g_iCurrentDuelers[1] = -1;
	for(int i = 0; i < MAXPLAYERS; ++i) {
		g_aiKillstreaks[i] = 0;
		g_abPlayerDied[i] = false;
	}
}

public void OnMapEnd() {
	g_nCurrentRoundMutator = 0;
	g_iCurrentDuelers[0] = -1;
	g_iCurrentDuelers[1] = -1;
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
		g_abPlayerDied[i] = false;
		if(i < MaxClients)
			g_abPlayerJoinedBeforeHalfway[i] = true;
	}
	
	CreateTimer(1.0, Delayed_PrintDuelersElos);

	UpdateStoredStats();
}

Action Delayed_PrintDuelersElos(Handle hTimer) {
	if(GameRules_GetProp("m_bInWaitingForPlayers"))
		return Plugin_Handled;
	if(!GetConVarBool(g_cvarNotifyElos))
		return Plugin_Handled;
	
	int iClient1 = -1;
	int iClient2 = -1;
	for(int i = 1; i < MaxClients; ++i) {
		if(IsPlayerAlive(i)) {
			if(iClient1 == -1)
				iClient1 = i;
			else {
				iClient2 = i;
				break;
			}
		}
	}
	if(iClient1 == -1 || iClient2 == -1) {
		LogError("Couldn't find the duel players to print their elos");
		return Plugin_Handled;
	}
	g_iCurrentDuelers[0] = iClient1;
	g_iCurrentDuelers[1] = iClient2;
	char szClient1[64];
	char szClient2[64];
	GetClientName(iClient1, szClient1, 64);
	GetClientName(iClient2, szClient2, 64);
	char szColor1[12];
	char szColor2[12];
	ColorIntToHex(GetPlayerColor(iClient1), szColor2, 12);
	ColorIntToHex(GetPlayerColor(iClient2), szColor2, 12);
	
	CPrintToChatAll("%t %t", "OpenFrags-Duels ChatPrefix", "OpenFrags-Duels RoundStartElos", szClient1, szColor1, g_aiElos[iClient1], szClient2, szColor2, g_aiElos[iClient2]);
	
	return Plugin_Handled;
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
		Format(szUpdateRatesQuery, 512, "UPDATE stats_duels SET \
													kdr = (frags / CASE WHEN deaths = 0 THEN 1 ELSE deaths END), \
													railgun_headshotrate = (railgun_headshots / (CASE WHEN railgun_headshots + railgun_bodyshots + railgun_misses = 0 THEN 1 ELSE railgun_headshots + railgun_bodyshots + railgun_misses END)), \
													winrate = (wins / CASE WHEN matches = 0 THEN 1 ELSE matches END) \
													WHERE steamid2='%s';", szAuth);
		
		g_hSQL.Query(Callback_None, szUpdateRatesQuery, 420, DBPrio_Low);
	}
}

void Event_PlayerHurt(Event event, const char[] szEventName, bool bDontBroadcast) {
	int iAttacker = GetClientOfUserId(GetEventInt(event, "attacker"));
	int iVictim = GetClientOfUserId(GetEventInt(event, "userid"));

	int iDamageTaken = GetEventInt(event, "damageamount");
	if(iDamageTaken > 500 || iDamageTaken < -500)
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
	
	int iVictim = GetClientOfUserId(iVictimId);
	int iClient = GetClientOfUserId(iAttackerId);
	
	if((!g_abInitializedClients[iVictim] || !g_abInitializedClients[iClient]) && !IsFakeClient(iVictim))
		return;
	
	char szWeapon[128];
	GetEventString(event, "weapon", szWeapon, 128);
	
	IncrementField(iVictim, "deaths");
	ResetKillstreak(iVictim);
	g_abPlayerDied[iVictim] = true;
	if(iVictim != iClient) {
		IncrementField(iClient, "frags");
		
		if(StrEqual(szWeapon, "crowbar", false) || StrEqual(szWeapon, "lead_pipe", false) || StrEqual(szWeapon, "combatknife", false) || StrEqual(szWeapon, "claws", false))
			IncrementField(iClient, "melee_kills");
		
		if(iClient > 0) {
			if(TF2_IsPlayerInCondition(iClient, TFCond_CritPowerup) || TF2_IsPlayerInCondition(iClient, TFCond_Haste) || TF2_IsPlayerInCondition(iClient, TFCond_Shield) || TF2_IsPlayerInCondition(iClient, TFCond_Berserk) || TF2_IsPlayerInCondition(iClient, TFCond_InvisPowerup))
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

float GetExpectedScore(int iClient1, int iClient2) {
	if(iClient1 < 1 || iClient2 < 1) {
		LogError("GetExpectedScore: invalid client (%i, %i)", iClient1, iClient2);
		return 0.0;
	}
	if(g_aiElos[iClient1] == 0 || g_aiElos[iClient2] == 0) {
		return 0.0;
	}
	float flEloDiff = float(g_aiElos[iClient2]) - float(g_aiElos[iClient1]);
	float flWinProbability = flEloDiff / 400.0;
	return (1.0/(1 + Pow(10.0, flWinProbability)));
}

void UpdatePlayerElo(int iClient, float flExpectedScore, bool bWon) {
	if(flExpectedScore == 0.0)
		return;
	
	if(iClient < 1) {
		LogError("UpdatePlayerElo: invalid client (%i)", iClient);
		return;
	}
	
	if(g_aiElos[iClient] == 0)
		return;
	
	char szAuth[32];
	GetClientAuthId(iClient, AuthId_Steam2, szAuth, 32);
	
	float flDevelopmentFactor = (-g_aiElos[iClient]+600)/33.33333 + 40;
	if(flDevelopmentFactor > 40.0)
		flDevelopmentFactor = 40.0;
	if(flDevelopmentFactor < 10.0)
		flDevelopmentFactor = 10.0;
	
	g_aiElos[iClient] = RoundToCeil(float(g_aiElos[iClient]) + flDevelopmentFactor*((bWon ? 1.0 : 0.0) - flExpectedScore));
	if(g_aiElos[iClient] < 100)
		g_aiElos[iClient] = 100;
	
	char szUpdateEloQuery[256];
	Format(szUpdateEloQuery, 256, "UPDATE stats_duels SET \
													elo = %i \
													WHERE steamid2='%s';", g_aiElos[iClient], szAuth);
		
	g_hSQL.Query(Callback_None, szUpdateEloQuery, 888, DBPrio_Low);
}

void Event_RoundEnd(Event event, const char[] szEventName, bool bDontBroadcast) {
	if(g_iCurrentDuelers[0] > 0)
		IncrementField(g_iCurrentDuelers[0], "matches");
	if(g_iCurrentDuelers[1] > 0)
		IncrementField(g_iCurrentDuelers[1], "matches");

	for(int i = 1; i < MaxClients; ++i) {
		if(!IsClientInGame(i))
			continue;
			
		if(!g_abInitializedClients[i])
			continue;

		ResetKillstreak(i);
		UpdateStoredStats(i);
	}
	
	int iTop1Client = GetEventInt(event, "player_1");
	int iTop2Client = GetEventInt(event, "player_2");
	
	IncrementField(iTop1Client, "wins");
	
	UpdatePlayerElo(iTop1Client, GetExpectedScore(iTop1Client, iTop2Client), true);
	UpdatePlayerElo(iTop2Client, GetExpectedScore(iTop2Client, iTop1Client), false);

	if(!g_abPlayerDied[iTop1Client])
		IncrementField(iTop1Client, "perfects");
	
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
				CPrintToChat(iClient, "%t %t", "OpenFrags-Duels ChatPrefix", "OpenFrags UninitializedSelf");
			else
				CPrintToChat(iClient, "%t %t", "OpenFrags-Duels ChatPrefix", "OpenFrags UninitializedPlayer", szClientName);
			return;
		}
		
		GetClientAuthId(iStatsOwner, AuthId_Steam2, szAuthToUse, 32);
	} else {
		strcopy(szAuthToUse, 32, szAuthArg);
	}
	
	DataPack hDatapack = new DataPack();
	hDatapack.WriteCell(iClient);
	hDatapack.WriteString(szAuthToUse);

	char szQuery[128];
	Format(szQuery, 128, "SELECT * FROM stats_duels WHERE steamid2 = '%s'", szAuthToUse);
	g_hSQL.Query(Callback_PrintPlayerStats_Check, szQuery, hDatapack, DBPrio_Normal);
	
}

void Callback_PrintPlayerStats_Check(Database hSQL, DBResultSet hResults, const char[] szErr, any hDatapackUncasted) {
	DataPack hDatapack = view_as<DataPack>(hDatapackUncasted);
	if(hResults.RowCount < 1 && !g_bPrintPlayerStatsScrewedUp) {
		hDatapack.Reset();
		int iClient = hDatapack.ReadCell();
		g_bPrintPlayerStatsScrewedUp = true;
		char szAuthToUse[32];
		char szQuery[128];
		GetClientAuthId(iClient, AuthId_Steam2, szAuthToUse, 32);

		CloseHandle(hDatapack);
		DataPack hNewDatapack = new DataPack();
		hNewDatapack.WriteCell(iClient);
		hNewDatapack.WriteString(szAuthToUse);
		
		Format(szQuery, 128, "SELECT * FROM stats_duels WHERE steamid2 = '%s'", szAuthToUse);
		g_hSQL.Query(Callback_PrintPlayerStats_Check, szQuery, hNewDatapack, DBPrio_Normal);
	} else if(hResults.RowCount < 1) {
		hDatapack.Reset();
		int iClient = hDatapack.ReadCell();
		CPrintToChat(iClient, "%t %t", "OpenFrags-Duels ChatPrefix", "OpenFrags StatsError");
		CloseHandle(hDatapack);
		return;
	} else {
		g_bPrintPlayerStatsScrewedUp = false;
		hDatapack.WriteCell(CloneHandle(hResults));

		SQL_FetchRow(hResults);
		if(hResults.FetchInt(26) == 0) {
			Callback_PrintPlayerStats_Finish(hSQL, view_as<DBResultSet>(INVALID_HANDLE), szErr, hDatapack);
		} else {
			char szAuthToUse[32];
			hResults.FetchString(0, szAuthToUse, 32);
			char szQuery[512];
			Format(szQuery, 512, "SELECT * FROM (select ROW_NUMBER() OVER (ORDER BY elo DESC) rating_place, elo, steamid2, name FROM stats_duels) AS gnarp WHERE steamid2 = '%s';", szAuthToUse);
			g_hSQL.Query(Callback_PrintPlayerStats_Finish, szQuery, hDatapack, DBPrio_Normal);
		}
	}
}

void Callback_PrintPlayerStats_Finish(Database hSQL, DBResultSet hResultsRatingPlace, const char[] szErr, any hDatapackUncasted) {
	if(strlen(szErr) > 0) {
		LogError("Couldn't query for Elo place: %s");
	}
	DataPack hDatapack = view_as<DataPack>(hDatapackUncasted);
	hDatapack.Reset();
	int iClient = hDatapack.ReadCell();
	char szQueriedAuth[32];
	hDatapack.ReadString(szQueriedAuth, 32);
	DBResultSet hResults = hDatapack.ReadCell();
	
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
	int iPlaytime = hResults.FetchInt(21);
	float flPlaytimeHours = iPlaytime / 60.0 / 60.0;
	int iPlaytimeHoursHigh = RoundFloat(flPlaytimeHours * 10) / 10;
	int iPlaytimeHoursLow = RoundFloat(flPlaytimeHours * 10) % 10;
	int iHighestKS = hResults.FetchInt(22);
	char szHighestKSMap[64];
	hResults.FetchString(23, szHighestKSMap, 64);
	int iDamageDealt = hResults.FetchInt(24);
	int iDamageTaken = hResults.FetchInt(25);
	int iRating = hResults.FetchInt(26);
	int iRatingPlace = 0;
	char szRatingColor[32];
	if(IsValidHandle(hResultsRatingPlace)) {
		hResultsRatingPlace.FetchRow();
		iRatingPlace = hResultsRatingPlace.FetchInt(0);
	}
	// i completely forgor about this
	CloseHandle(hResults);
	
	if(iRatingPlace == 1)
		strcopy(szRatingColor, 32, RATING_COLOR_TOP1);
	else if(iRatingPlace < 1)
		strcopy(szRatingColor, 32, RATING_COLOR_UNRANKED);
	else if(iRatingPlace <= 5)
		strcopy(szRatingColor, 32, RATING_COLOR_TOP5);
	else if(iRatingPlace <= 10)
		strcopy(szRatingColor, 32, RATING_COLOR_TOP10);
	else if(iRatingPlace <= 100)
		strcopy(szRatingColor, 32, RATING_COLOR_TOP100);
	else
		strcopy(szRatingColor, 32, RATING_COLOR_UNRANKED);
	
	if(bSelfRequest)
		CPrintToChat(iClient, "%t %t", "OpenFrags-Duels ChatPrefix", "OpenFrags YourStats", szStatOwnerAuth);
	else
		CPrintToChat(iClient, "%t %t", "OpenFrags-Duels ChatPrefix", "OpenFrags PlayerStats", szName, szColor, szStatOwnerAuth);

	CPrintToChat(iClient, "%t", "OpenFrags StatsRating", iRating, iRatingPlace, szRatingColor);
	CPrintToChat(iClient, "%t", "OpenFrags StatsMatches", iWins, iMatches);
	CPrintToChat(iClient, "%t", "OpenFrags StatsPlaytime", iPlaytimeHoursHigh, iPlaytimeHoursLow);
	CPrintToChat(iClient, "%t", "OpenFrags StatsKD", iFrags, iDeaths, flKDR);
	CPrintToChat(iClient, "%t", "OpenFrags StatsMeleeAndPowerupKills", iMeleeKills, iPowerupKills);
	CPrintToChat(iClient, "%t", "OpenFrags StatsSSG", iSSGMeatshots, iSSGNormalShots, iSSGMisses);
	CPrintToChat(iClient, "%t", "OpenFrags StatsRGHeadshots", iRGHeadshots, iRGHeadshotPercentageHigh, iRGHeadshotPercentageLow);
	CPrintToChat(iClient, "%t", "OpenFrags StatsAirshots", iRLAirshots, iGLAirshots);
	CPrintToChat(iClient, "%t", "OpenFrags StatsHighestKillstreak", iHighestKS, szHighestKSMap);
	CPrintToChat(iClient, "%t", "OpenFrags StatsDamage", iDamageDealt, iDamageTaken);
}

void PrintPlayerElo(int iClient, int iStatsOwner, char[] szAuthArg = "") {
	g_bPrintPlayerStatsScrewedUp = false;
	bool bSelfRequest = iClient == iStatsOwner;
	char szAuthToUse[32];
	if(iStatsOwner != -1) {
		if(!g_abInitializedClients[iStatsOwner]) {
			char szClientName[64];
			GetClientName(iStatsOwner, szClientName, 64);
			
			if(bSelfRequest)
				CPrintToChat(iClient, "%t %t", "OpenFrags-Duels ChatPrefix", "OpenFrags UninitializedSelf");
			else
				CPrintToChat(iClient, "%t %t", "OpenFrags-Duels ChatPrefix", "OpenFrags UninitializedPlayer", szClientName);
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
	if(hResults.RowCount < 1 && !g_bPrintPlayerStatsScrewedUp) {
		hDatapack.Reset();
		int iClient = hDatapack.ReadCell();
		g_bPrintPlayerStatsScrewedUp = true;
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
		CPrintToChat(iClient, "%t %t", "OpenFrags-Duels ChatPrefix", "OpenFrags StatsError");
		CloseHandle(hDatapack);
		return;
	} else {
		g_bPrintPlayerStatsScrewedUp = false;
		hDatapack.WriteCell(hResults);
		
		PrintPlayerElo_Finish(hDatapack);
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
	char szEloPlaceColor[12];
	
	if(iEloPlace == 1)
		strcopy(szEloPlaceColor, 32, RATING_COLOR_TOP1);
	else if(iEloPlace < 1)
		strcopy(szEloPlaceColor, 32, RATING_COLOR_UNRANKED);
	else if(iEloPlace <= 5)
		strcopy(szEloPlaceColor, 32, RATING_COLOR_TOP5);
	else if(iEloPlace <= 10)
		strcopy(szEloPlaceColor, 32, RATING_COLOR_TOP10);
	else if(iEloPlace <= 100)
		strcopy(szEloPlaceColor, 32, RATING_COLOR_TOP100);
	else
		strcopy(szEloPlaceColor, 32, RATING_COLOR_UNRANKED);
	
	if(bSelfRequest)
		CPrintToChat(iClient, "%t %t %s[#%i]", "OpenFrags-Duels ChatPrefix", "OpenFrags-Duels YourElo", iElo, szEloPlaceColor, iEloPlace);
	else
		CPrintToChat(iClient, "%t %t %s[#%i]", "OpenFrags-Duels ChatPrefix", "OpenFrags-Duels PlayerElo", szName, szColor, iElo, szEloPlaceColor, iEloPlace);
}

void PrintPlayerElos(int iClient) {
	char szQuery[4096];
	Format(szQuery, 4096, "SELECT steamid2, name, color, elo FROM stats_duels WHERE ");
	for(int i = 1; i < MaxClients; ++i) {
		if(!IsClientInGame(i))
			continue;
		
		char szAuth[32];
		GetClientAuthId(i, AuthId_Steam2, szAuth, 32);
		Format(szQuery, 4096, "%s steamid2='%s' OR", szQuery, szAuth);
	}
	Format(szQuery, strlen(szQuery)-2, "%s", szQuery);
	Format(szQuery, 4096, "%s ORDER BY elo DESC;", szQuery);
	g_hSQL.Query(Callback_PrintPlayerElos_Finish, szQuery, iClient);
}

void Callback_PrintPlayerElos_Finish(Database hSQL, DBResultSet hResults, const char[] szErr, any iClientUncasted) {
	int iClient = view_as<int>(iClientUncasted);
	if(strlen(szErr) > 0)
		LogError("An error occured while querying for current player ELOs: %s", szErr);
	
	CPrintToChat(iClient, "%t %t", "OpenFrags-Duels ChatPrefix", "OpenFrags-Duels PlayersElos");
	for(int i = 0; i < hResults.RowCount; ++i) {
		hResults.FetchRow();
		char szName[64];
		hResults.FetchString(1, szName, 64);
		char szColor[12];
		ColorIntToHex(hResults.FetchInt(2), szColor, 12);
		int iElo = hResults.FetchInt(3);
		CPrintToChat(iClient, "%t", "OpenFrags-Duels PlayersElo", i+1, szName, szColor, iElo);
	}
}

int iLeaderboardPlayerCount = 0;
char aszLeaderboardPlayerAuth[5][32];
char aszLeaderboardPlayerName[5][64];
char aszLeaderboardPlayerColor[5][12];
int aiLeaderboardPlayerElo[5];

void PrintTopPlayers(int iClient) {
	iLeaderboardPlayerCount = 0;
	
	char szQuery[512];
	Format(szQuery, 512, "SELECT steamid2, name, color, elo FROM stats_duels ORDER BY elo DESC LIMIT 0, 5;");
	g_hSQL.Query(Callback_PrintTopPlayers_ReceivedTopRated, szQuery, iClient);
}

void Callback_PrintTopPlayers_ReceivedTopRated(Database hSQL, DBResultSet hResults, const char[] szErr, any iClient) {
	for(int i = 0; i < hResults.RowCount; ++i) {
		SQL_FetchRow(hResults);
		hResults.FetchString(0, aszLeaderboardPlayerAuth[i], 32);
		hResults.FetchString(1, aszLeaderboardPlayerName[i], 64);
		ColorIntToHex(hResults.FetchInt(2), aszLeaderboardPlayerColor[i], 12);
		aiLeaderboardPlayerElo[i] = hResults.FetchInt(3);
		if(strlen(aszLeaderboardPlayerName[i]) > MAX_LEADERBOARD_NAME_LENGTH)
			strcopy(aszLeaderboardPlayerName[i][MAX_LEADERBOARD_NAME_LENGTH-5], 4, "...");
		iLeaderboardPlayerCount++;
	}
	
	CPrintToChat(iClient, "%t %t", "OpenFrags-Duels ChatPrefix", "OpenFrags-Duels Leaderboard");	
	for(int i = 0; i < iLeaderboardPlayerCount; ++i) {
		CPrintToChat(iClient, "%t", "OpenFrags-Duels LeaderboardPlayer", i, aszLeaderboardPlayerName[i], aszLeaderboardPlayerColor[i], aiLeaderboardPlayerElo[i]);
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
	if(StrEqual(szChatCommand, "optout", false) || StrEqual(szChatCommand, "opt-out", false)) {
		Command_OptOut(iClient, 0);
		return retval;
	}
	if(StrEqual(szChatCommand, "elo", false) && iArgs == 1) {
		PrintPlayerElo(iClient, iClient);
		return retval;
	}
	if(StrEqual(szChatCommand, "elos", false)) {
		PrintPlayerElos(iClient);
		return retval;
	}
	if(StrEqual(szChatCommand, "elo", false)) {
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

Action Command_ViewTop(int iClient, int iArgs) {
	PrintTopPlayers(iClient);
	return Plugin_Handled;
}

Action Command_AboutPlugin(int iClient, int iArgs) {
	if(iClient != 0)
		CPrintToChat(iClient, "%t %t", "OpenFrags-Duels ChatPrefix", "OpenFrags-Duels About", PLUGIN_VERSION);
	else {
		char szAbout[256];
		Format(szAbout, 256, "%t %t", "OpenFrags-Duels ChatPrefix", "OpenFrags-Duels About", PLUGIN_VERSION);
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
		CPrintToChat(iClient, "%t %t", "OpenFrags-Duels ChatPrefix", "OpenFrags UninitializedSelf");
	}
	
	if(!g_bOptOutConfirm) {
		g_bOptOutConfirm = true;
		CPrintToChat(iClient, "%t %t", "OpenFrags-Duels ChatPrefix", "OpenFrags OptOutConfirm");
		CreateTimer(10.0, Delayed_OptOutCancel);
		return Plugin_Handled;
	}
	
	g_bThrewOptOutErrorAlready = false;
	
	CPrintToChat(iClient, "%t %t", "OpenFrags-Duels ChatPrefix", "OpenFrags OptingOut");
	
	char szAuth[32];
	GetClientAuthId(iClient, AuthId_Steam2, szAuth, 32);
	
	char szClientName[64];
	char szClientNameSafe[129];
	GetClientName(iClient, szClientName, 64);
	SQL_EscapeString(g_hSQL, szClientName, szClientNameSafe, 64);
	
	char szQueryOptOut[512];
	Format(szQueryOptOut, 512, "DELETE FROM stats_duels WHERE steamid2 = '%s';", szAuth);
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
			CPrintToChat(iClient, "%t %t", "OpenFrags-Duels ChatPrefix", "OpenFrags Error");
			
		g_bThrewOptOutErrorAlready = true;
		return;
	}
	
	g_iRemovedStatsQ++;
	if(g_iRemovedStatsQ > 0 && g_iAddedBanQ > 0) {
		CPrintToChat(iClient, "%t %t", "OpenFrags-Duels ChatPrefix", "OpenFrags OptedOut");
		g_abInitializedClients[iClient] = false;
		g_iRemovedStatsQ -= 1;
		g_iAddedBanQ -= 1;
	}
}

void Callback_OptOut_AddedBan(Database hSQL, DBResultSet hResults, const char[] szErr, any iClientUncasted) {
	int iClient = view_as<int>(iClientUncasted);
	if(!IsValidHandle(hSQL) || strlen(szErr) > 0) {
		if(!g_bThrewOptOutErrorAlready)
			CPrintToChat(iClient, "%t %t", "OpenFrags-Duels ChatPrefix", "OpenFrags Error");
		
		g_bThrewOptOutErrorAlready = true;
		return;
	}
	
	g_iAddedBanQ++;
	if(g_iRemovedStatsQ > 0 && g_iAddedBanQ > 0) {
		CPrintToChat(iClient, "%t %t", "OpenFrags-Duels ChatPrefix", "OpenFrags OptedOut");
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
	Format(szQuery, 700, "UPDATE stats_duels SET \
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

Action Command_MyScore(int iClient, int iArgs) {
	if(iClient <= 0) {
		ReplyToCommand(iClient, "[OF] This command cannot be ran as the server");
		return Plugin_Handled;
	}
	
	ReplyToCommand(iClient, "[OF] Your score: %i", GetPlayerFrags(iClient));
	return Plugin_Handled;
}

void Event_SvTagsChanged(ConVar cvarTags, const char[] szOld, const char[] szNew) {
	if(g_bSvTagsChangedDebounce)
		return;
	
	g_bSvTagsChangedDebounce = true;
	CreateTimer(0.5, Delayed_SvTagsChangedDebounce);
	AddServerTagRat("openfrags-duels");
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
