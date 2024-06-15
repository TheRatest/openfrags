#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <openfortress>
#include <morecolors>

#define PLUGIN_VERSION "1.1"
#define MIN_HEADSHOTS_LEADERBOARD 15
#define MAX_LEADERBOARD_NAME_LENGTH 32

Database g_hSQL;

bool g_bFirstConnectionEstabilished = false;
// for checking if the connection fails; don't want to spam the server error log with the same error over and over
bool g_bThrewErrorAlready = false;
bool g_abInitializedClients[MAXPLAYERS];
int g_aiKillstreaks[MAXPLAYERS];
int g_aiPlayerJoinTimes[MAXPLAYERS];

// for weapons like the ssg which can trigger multiple misses on 1 attack
bool g_abSSGHitDebounce[MAXPLAYERS];

public Plugin myinfo = {
	name = "Open Frags",
	author = "ratest & Oha",
	description = "Keeps track of your stats!",
	version = PLUGIN_VERSION,
	url = "http://openfrags.ohaa.xyz"
};

public void OnPluginStart() {
	LoadTranslations("openfrags.phrases.txt");

	RegConsoleCmd("sm_openfrags", Command_AboutPlugin, "Information on OpenFrags");
	RegConsoleCmd("sm_openfrags_stats", Command_ViewStats, "View your stats (or someone else's)");
	RegConsoleCmd("sm_openfrags_top", Command_ViewTop, "View the top players");
	RegConsoleCmd("sm_openfrags_leaderboard", Command_ViewTop, "Alias for sm_openfrags_top");

	SQL_TConnect(Callback_DatabaseConnected, "openfrags");
	
	CreateTimer(60.0, Loop_ConnectionCheck);
	AddServerTagRat("openfrags");
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
			
			HookEvent("player_hurt", Event_PlayerHurt);
			HookEvent("player_death", Event_PlayerDeath);
			HookEvent("teamplay_round_start", Event_RoundStart);
			HookEvent("teamplay_win_panel", Event_RoundEnd);
			
			g_bFirstConnectionEstabilished = true;
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

bool IsServerEligibleForStats() {
	int iBotCount = GetConVarInt(FindConVar("tf_bot_quota"));
	return (GetClientCount(true) - iBotCount >= 2 && iBotCount <= 3 && !GetConVarBool(FindConVar("sv_cheats")));
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

stock int GetPlayerFrags(int iClient) {
	int iFrags = GetEntProp(GetPlayerResourceEntity(), Prop_Send, "m_iScore", 4, iClient);
	return iFrags;
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

	// won't run if there's an existing entry for the player
	char szQueryInsertNewPlayer[1024];
	Format(szQueryInsertNewPlayer, 1024, "INSERT IGNORE INTO stats (steamid2,\
												name,\
												color,\
												frags,\
												deaths,\
												kdr,\
												powerup_kills,\
												melee_kills,\
												railgun_headshots,\
												railgun_bodyshots,\
												railgun_misses,\
												railgun_headshotrate,\
												rocketlauncher_airshots,\
												chinalake_airshots,\
												ssg_meatshots,\
												ssg_normalshots,\
												ssg_misses,\
												matches,\
												wins,\
												top3_wins,\
												winrate,\
												join_count,\
												playtime,\
												highest_killstreak,\
												highest_killstreak_map,\
												damage_dealt,\
												damage_taken,\
												score\
												)\
												VALUES (\
												'%s',\
												'%s',\
												0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,\
												'None',\
												0, 0, 0\
												);", szAuth, szClientNameSafe);
	g_hSQL.Query(Callback_None, szQueryInsertNewPlayer, 4, DBPrio_High);
	
	// check for a stat tracking ban
	char szQueryCheckPlayerBan[128];
	Format(szQueryCheckPlayerBan, 128, "SELECT * FROM bans WHERE steamid2 = '%s'", szAuth);
	g_hSQL.Query(Callback_InitPlayerData_Final, szQueryCheckPlayerBan, iClient, DBPrio_High);
}

void Callback_InitPlayerData_Final(Database hSQL, DBResultSet hResults, const char[] szErr, any iClient) {
	if(hResults.RowCount > 0) {
		hResults.FetchRow();
		bool bBanned = view_as<bool>(hResults.FetchInt(2));
		int iExpirationTime = hResults.FetchInt(5);
		CloseHandle(hResults);
		int iCurrentTime = GetTime();
		if(bBanned && iCurrentTime < iExpirationTime)
			return;
	}
	
	g_abInitializedClients[iClient] = true;
	
	char szAuth[32];
	GetClientAuthId(iClient, AuthId_Steam2, szAuth, 32);
	
	int iPlayerColor = GetPlayerColor(iClient);
	char szQueryUpdatePlayer[256];
	Format(szQueryUpdatePlayer, 256, "UPDATE stats SET color = %i, join_count = join_count + 1 WHERE steamid2 = '%s'", iPlayerColor, szAuth);
	g_hSQL.Query(Callback_None, szQueryUpdatePlayer, 5, DBPrio_Low);
	
	OnClientDataInitialized(iClient);
}

void IncrementField(int iClient, char[] szField, int iAdd = 1) {
	if(iClient <= 0 || iClient >= MAXPLAYERS)
		return;
		
	if(!g_abInitializedClients[iClient])
		return;
		
	if(!IsServerEligibleForStats())
		return;
	
	char szAuth[32];
	GetClientAuthId(iClient, AuthId_Steam2, szAuth, 32);
	
	char szQuery[512];
	Format(szQuery, 512, "UPDATE stats SET \
										%s = (%s + %i), \
										railgun_headshotrate = (railgun_headshots / (CASE WHEN railgun_headshots + railgun_bodyshots + railgun_misses = 0 THEN 1 ELSE railgun_headshots + railgun_bodyshots + railgun_misses END)), \
										kdr = (frags / CASE WHEN deaths = 0 THEN 1 ELSE deaths END), \
										winrate = (wins / CASE WHEN matches = 0 THEN 1 ELSE matches END) \
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
	Format(szQueryUpdate, 512, "UPDATE stats SET highest_killstreak = CASE WHEN highest_killstreak < %i THEN %i ELSE highest_killstreak END, \
												highest_killstreak_map = CASE WHEN highest_killstreak < %i THEN '%s' ELSE highest_killstreak_map END WHERE steamid2 = '%s'",
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
	
	InitPlayerData(iClient);
}

// resets everyone's join times whenever the server becomes eligible for stat tracking, and updates playtimes if it already is
void OnClientDataInitialized(int iClient) {
	if(IsServerEligibleForStats()) {
		for(int i = 1; i < MaxClients; ++i) {
			if(!IsClientInGame(i))
				continue;
				
			if(!g_abInitializedClients[i])
				continue;
	
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

public void OnClientPutInServer(int iClient) {
	SDKHook(iClient, SDKHook_OnTakeDamage, Event_PlayerDamaged);
}

public void OnClientDisconnect(int iClient) {
	ResetKillstreak(iClient);
	IncrementField(iClient, "playtime", g_aiPlayerJoinTimes[iClient] == 0 ? 0 : GetTime() - g_aiPlayerJoinTimes[iClient]);
	g_abInitializedClients[iClient] = false;
	g_aiPlayerJoinTimes[iClient] = 0;
}

public void OnMapStart() {
	for(int i = 0; i < MAXPLAYERS; ++i) {
		g_aiKillstreaks[i] = 0;
	}
}

public void OnMapEnd() {
	for(int i = 1; i < MAXPLAYERS; ++i) {
		IncrementField(i, "playtime", g_aiPlayerJoinTimes[i] == 0 ? 0 : GetTime() - g_aiPlayerJoinTimes[i]);
		g_aiPlayerJoinTimes[i] = GetTime();
	}
}

void Event_RoundStart(Event event, char[] szEventName, bool bDontBroadcast) {
	for(int i = 0; i < MAXPLAYERS; ++i) {
		g_aiKillstreaks[i] = 0;
		if(i == 0)
			continue;
		
		IncrementField(i, "playtime", g_aiPlayerJoinTimes[i] == 0 ? 0 : GetTime() - g_aiPlayerJoinTimes[i]);
		g_aiPlayerJoinTimes[i] = GetTime();
	}
}

void Event_PlayerHurt(Event event, const char[] szEvName, bool bDontBroadcast) {
	int iAttacker = GetClientOfUserId(GetEventInt(event, "attacker"));
	int iVictim = GetClientOfUserId(GetEventInt(event, "userid"));

	int iDamageTaken = GetEventInt(event, "damageamount");
	if(iDamageTaken > 300 || iDamageTaken < -300)
		return;
	
	IncrementField(iVictim, "damage_taken", iDamageTaken);
	
	if(iAttacker == iVictim || iAttacker == 0)
		return;
	
	IncrementField(iAttacker, "damage_dealt", GetEventInt(event, "damageamount"));
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

void Event_RoundEnd(Event event, const char[] szEventName, bool bDontBroadcast) {
	for(int i = 1; i < MaxClients; ++i) {
		if(!IsClientInGame(i))
			continue;
			
		if(!g_abInitializedClients[i])
			continue;
			
		IncrementField(i, "matches");
		ResetKillstreak(i);
		IncrementField(i, "playtime", g_aiPlayerJoinTimes[i] == 0 ? 0 : GetTime() - g_aiPlayerJoinTimes[i]);
		g_aiPlayerJoinTimes[i] = GetTime();
	}
	
	int iTop1Client = GetEventInt(event, "player_1");
	int iTop2Client = GetEventInt(event, "player_2");
	int iTop3Client = GetEventInt(event, "player_3");
	
	IncrementField(iTop1Client, "wins");
	IncrementField(iTop1Client, "top3_wins");
	IncrementField(iTop2Client, "top3_wins");
	IncrementField(iTop3Client, "top3_wins");
}

void PrintPlayerStats(int iClient, int iStatsOwner, char[] szAuthArg = "") {
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

	char szQuery[128];
	Format(szQuery, 128, "SELECT * FROM stats WHERE steamid2 = '%s'", szAuthToUse);
	g_hSQL.Query(Callback_PrintPlayerStats_Check, szQuery, iClient, DBPrio_Normal);
	
}

void Callback_PrintPlayerStats_Check(Database hSQL, DBResultSet hResults, const char[] szErr, any iClient) {
	if(hResults.RowCount < 1) {
		char szAuthToUse[32];
		char szQuery[128];
		GetClientAuthId(iClient, AuthId_Steam2, szAuthToUse, 32);
		Format(szQuery, 128, "SELECT * FROM stats WHERE steamid2 = '%s'", szAuthToUse);
		g_hSQL.Query(Callback_PrintPlayerStats_Finish, szQuery, iClient, DBPrio_Normal);
	} else
		Callback_PrintPlayerStats_Finish(hSQL, hResults, szErr, iClient);
}

void Callback_PrintPlayerStats_Finish(Database hSQL, DBResultSet hResults, const char[] szErr, any iClient) {
	SQL_FetchRow(hResults);
	
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
	//float flWinrate = hResults.FetchFloat(20);
	int iPlaytime = hResults.FetchInt(22);
	float flPlaytimeHours = iPlaytime / 60.0 / 60.0;
	int iPlaytimeHoursHigh = RoundFloat(flPlaytimeHours * 10) / 10;
	int iPlaytimeHoursLow = RoundFloat(flPlaytimeHours * 10) % 10;
	int iHighestKS = hResults.FetchInt(23);
	char szHighestKSMap[64];
	hResults.FetchString(24, szHighestKSMap, 64);
	int iDamageDealt = hResults.FetchInt(25);
	int iDamageTaken = hResults.FetchInt(26);
	//int iScore = hResults.FetchInt(27);
	
	if(bSelfRequest)
		CPrintToChat(iClient, "%t %t", "OpenFrags ChatPrefix", "OpenFrags YourStats", szStatOwnerAuth);
	else
		CPrintToChat(iClient, "%t %t", "OpenFrags ChatPrefix", "OpenFrags PlayerStats", szName, szColor, szStatOwnerAuth);

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
int iBestFraggerQ = 0;
char szBestFragger[128];
char szBestFraggerColor[12];
int iMostFrags = 0;

int iBestWinnerQ = 0;
char szBestWinner[64];
char szBestWinnerColor[12];
int iMostWins = 0;

int iBestHeadshotterQ = 0;
char szBestHeadshotter[64];
char szBestHeadshotterColor[12];
float flBestHSRate = 0.0;

int iBestKillstreakerQ = 0;
char szBestKillstreaker[64];
char szBestKillstreakerColor[12];
char szBestKillstreakerMap[64];
int iBestKillstreak = 0;

int iBestSSGerQ = 0;
char szBestSSGer[64];
char szBestSSGerColor[12];
int iMostMeatshots = 0;
int iSSGNormalShots = 0;
int iSSGMisses = 0;
int iSSGTotalShots = 0;

int iBestDamagerQ = 0;
char szBestDamager[64];
char szBestDamagerColor[12];
int iMostDamage = 0;

void PrintTopPlayers(int iClient) {
	char szQuery[256];
	
	// only once all the queries have finished the player will get the leaderboard
	Format(szQuery, 256, "SELECT * FROM stats WHERE (frags = (SELECT MAX(frags) FROM stats))");
	g_hSQL.Query(Callback_PrintTopPlayers_ReceivedTopFragger, szQuery, iClient);
	
	Format(szQuery, 256, "SELECT * FROM stats WHERE (wins = (SELECT MAX(wins) FROM stats))");
	g_hSQL.Query(Callback_PrintTopPlayers_ReceivedTopWinner, szQuery, iClient);

	Format(szQuery, 256, "SELECT * FROM stats WHERE (railgun_headshotrate = (SELECT MAX(railgun_headshotrate) FROM stats WHERE railgun_headshots > %i))", MIN_HEADSHOTS_LEADERBOARD);
	g_hSQL.Query(Callback_PrintTopPlayers_ReceivedTopHeadshotter, szQuery, iClient);

	Format(szQuery, 256, "SELECT * FROM stats WHERE (highest_killstreak = (SELECT MAX(highest_killstreak) FROM stats))");
	g_hSQL.Query(Callback_PrintTopPlayers_ReceivedTopKillstreaker, szQuery, iClient);

	Format(szQuery, 256, "SELECT * FROM stats WHERE (ssg_meatshots = (SELECT MAX(ssg_meatshots) FROM stats))");
	g_hSQL.Query(Callback_PrintTopPlayers_ReceivedTopSSGer, szQuery, iClient);

	Format(szQuery, 256, "SELECT * FROM stats WHERE (damage_dealt = (SELECT MAX(damage_dealt) FROM stats))");
	g_hSQL.Query(Callback_PrintTopPlayers_ReceivedTopDamager, szQuery, iClient);
}

void Callback_PrintTopPlayers_ReceivedTopFragger(Database hSQL, DBResultSet hResults, const char[] szErr, any iClient) {
	SQL_FetchRow(hResults);
	hResults.FetchString(1, szBestFragger, 64);
	ColorIntToHex(hResults.FetchInt(2), szBestFraggerColor);
	iMostFrags = hResults.FetchInt(3);
	if(strlen(szBestFragger) > MAX_LEADERBOARD_NAME_LENGTH)
		strcopy(szBestFragger[MAX_LEADERBOARD_NAME_LENGTH-5], 4, "...");
		
	iBestFraggerQ++;
	if(iBestFraggerQ > 0 && iBestWinnerQ > 0 && iBestHeadshotterQ && iBestKillstreakerQ > 0 && iBestSSGerQ > 0 && iBestDamagerQ > 0)
		PrintTopPlayers_Finish(view_as<int>(iClient));
}

void Callback_PrintTopPlayers_ReceivedTopWinner(Database hSQL, DBResultSet hResults, const char[] szErr, any iClient) {
	SQL_FetchRow(hResults);
	hResults.FetchString(1, szBestWinner, 64);
	ColorIntToHex(hResults.FetchInt(2), szBestWinnerColor);
	iMostWins = hResults.FetchInt(18);
	if(strlen(szBestWinner) > MAX_LEADERBOARD_NAME_LENGTH)
		strcopy(szBestWinner[MAX_LEADERBOARD_NAME_LENGTH-5], 4, "...");
	
	iBestWinnerQ++;
	if(iBestFraggerQ > 0 && iBestWinnerQ > 0 && iBestHeadshotterQ && iBestKillstreakerQ > 0 && iBestSSGerQ > 0 && iBestDamagerQ > 0)
		PrintTopPlayers_Finish(view_as<int>(iClient));
}

void Callback_PrintTopPlayers_ReceivedTopHeadshotter(Database hSQL, DBResultSet hResults, const char[] szErr, any iClient) {
	if(hResults.RowCount < 1) {
		char szQuery[128];
		Format(szQuery, 128, "SELECT * FROM stats WHERE (railgun_headshotrate = (SELECT MAX(railgun_headshotrate) FROM stats))");
		g_hSQL.Query(Callback_PrintTopPlayers_ReceivedTopHeadshotter, szQuery, iClient);
		return;
	}
	SQL_FetchRow(hResults);
	hResults.FetchString(1, szBestHeadshotter, 64);
	ColorIntToHex(hResults.FetchInt(2), szBestHeadshotterColor);
	flBestHSRate = hResults.FetchFloat(11);
	if(strlen(szBestHeadshotter) > MAX_LEADERBOARD_NAME_LENGTH)
		strcopy(szBestHeadshotter[MAX_LEADERBOARD_NAME_LENGTH-5], 4, "...");
	
	iBestHeadshotterQ++;
	if(iBestFraggerQ > 0 && iBestWinnerQ > 0 && iBestHeadshotterQ && iBestKillstreakerQ > 0 && iBestSSGerQ > 0 && iBestDamagerQ > 0)
		PrintTopPlayers_Finish(view_as<int>(iClient));
}

void Callback_PrintTopPlayers_ReceivedTopKillstreaker(Database hSQL, DBResultSet hResults, const char[] szErr, any iClient) {
	SQL_FetchRow(hResults);
	hResults.FetchString(1, szBestKillstreaker, 64);
	ColorIntToHex(hResults.FetchInt(2), szBestKillstreakerColor);
	iBestKillstreak = hResults.FetchInt(23);
	hResults.FetchString(24, szBestKillstreakerMap, 64);
	if(strlen(szBestKillstreaker) > MAX_LEADERBOARD_NAME_LENGTH)
		strcopy(szBestKillstreaker[MAX_LEADERBOARD_NAME_LENGTH-5], 4, "...");
	
	iBestKillstreakerQ++;
	if(iBestFraggerQ > 0 && iBestWinnerQ > 0 && iBestHeadshotterQ && iBestKillstreakerQ > 0 && iBestSSGerQ > 0 && iBestDamagerQ > 0)
		PrintTopPlayers_Finish(view_as<int>(iClient));
}

void Callback_PrintTopPlayers_ReceivedTopSSGer(Database hSQL, DBResultSet hResults, const char[] szErr, any iClient) {
	SQL_FetchRow(hResults);
	hResults.FetchString(1, szBestSSGer, 128);
	ColorIntToHex(hResults.FetchInt(2), szBestSSGerColor);
	iMostMeatshots = hResults.FetchInt(14);
	iSSGNormalShots = hResults.FetchInt(15);
	iSSGMisses = hResults.FetchInt(16);
	iSSGTotalShots = iMostMeatshots + iSSGNormalShots + iSSGMisses;
	if(iSSGTotalShots <= 0)
		iSSGTotalShots = 1;
	if(strlen(szBestSSGer) > MAX_LEADERBOARD_NAME_LENGTH)
		strcopy(szBestSSGer[MAX_LEADERBOARD_NAME_LENGTH-5], 4, "...");
	
	iBestSSGerQ++;
	if(iBestFraggerQ > 0 && iBestWinnerQ > 0 && iBestHeadshotterQ && iBestKillstreakerQ > 0 && iBestSSGerQ > 0 && iBestDamagerQ > 0)
		PrintTopPlayers_Finish(view_as<int>(iClient));
}

void Callback_PrintTopPlayers_ReceivedTopDamager(Database hSQL, DBResultSet hResults, const char[] szErr, any iClient) {
	SQL_FetchRow(hResults);
	hResults.FetchString(1, szBestDamager, 64);
	ColorIntToHex(hResults.FetchInt(2), szBestDamagerColor);
	iMostDamage = hResults.FetchInt(25);
	if(strlen(szBestDamager) > MAX_LEADERBOARD_NAME_LENGTH)
		strcopy(szBestDamager[MAX_LEADERBOARD_NAME_LENGTH-5], 4, "...");
	
	iBestDamagerQ++;
	if(iBestFraggerQ > 0 && iBestWinnerQ > 0 && iBestHeadshotterQ && iBestKillstreakerQ > 0 && iBestSSGerQ > 0 && iBestDamagerQ > 0)
		PrintTopPlayers_Finish(view_as<int>(iClient));
}

void PrintTopPlayers_Finish(int iClient) {
	int iMeatshotRateHigh = RoundFloat(((0.0 + iMostMeatshots) / iSSGTotalShots) * 1000.0) / 10;
	int iMeatshotRateLow = RoundFloat(((0.0 + iMostMeatshots) / iSSGTotalShots) * 1000.0) % 10;
	int iBestHSRateHigh = RoundFloat(flBestHSRate * 1000) / 10;
	int iBestHSRateLow = RoundFloat(flBestHSRate * 1000) % 10;
	
	CPrintToChat(iClient, "%t %t", "OpenFrags ChatPrefix", "OpenFrags TopPlayers");
	CPrintToChat(iClient, "%t", "OpenFrags TopFragger", szBestFragger, szBestFraggerColor, iMostFrags);
	CPrintToChat(iClient, "%t", "OpenFrags TopWinnerRate", szBestWinner, szBestWinnerColor, iMostWins);
	CPrintToChat(iClient, "%t", "OpenFrags TopHeadshotter", szBestHeadshotter, szBestHeadshotterColor, iBestHSRateHigh, iBestHSRateLow);
	CPrintToChat(iClient, "%t", "OpenFrags TopKillstreaker", szBestKillstreaker, szBestKillstreakerColor, iBestKillstreak, szBestKillstreakerMap);
	CPrintToChat(iClient, "%t", "OpenFrags TopSSGer", szBestSSGer, szBestSSGerColor, iMostMeatshots, iMeatshotRateHigh, iMeatshotRateLow);
	CPrintToChat(iClient, "%t", "OpenFrags TopDamager", szBestDamager, szBestDamagerColor, iMostDamage);
	
	iBestFraggerQ -= 1;
	iBestWinnerQ -= 1;
	iBestHeadshotterQ -= 1;
	iBestKillstreakerQ -= 1;
	iBestSSGerQ -= 1;
	iBestDamagerQ -= 1;
}

public Action OnClientSayCommand(int iClient, const char[] szCommand, const char[] szArg) {
	char szArgs[3][64];
	int iArgs = ExplodeString(szArg, " ", szArgs, 3, 64, true);
	char szChatCommand[63];
	strcopy(szChatCommand, 63, szArgs[0][1]);
	
	if(szArgs[0][0] != '/' && szArgs[0][0] != '!')
		return Plugin_Continue;
	
	if(StrEqual(szChatCommand, "stats", false) && iArgs == 1) {
		PrintPlayerStats(iClient, iClient);
		return Plugin_Continue;
	}
	if(StrEqual(szChatCommand, "top", false) || StrEqual(szChatCommand, "leaderboard", false)) {
		PrintTopPlayers(iClient);
		return Plugin_Continue;
	}
	if(StrEqual(szChatCommand, "stats", false)) {
		int aiTargets[1];
		char szTarget[64];
		bool bIsMLPhrase = false;
		int iTargetsFound = ProcessTargetString(szArgs[1], 0, aiTargets, 1, 0, szTarget, 128, bIsMLPhrase);
		if(iTargetsFound > 0) {
			PrintPlayerStats(iClient, aiTargets[0]);
			return Plugin_Continue;
		} else {
			char szAuth[32];
			strcopy(szAuth, 32, szArgs[1]);
			ReplaceString(szAuth, 32, "'", "");
			ReplaceString(szAuth, 32, ")", "");
			ReplaceString(szAuth, 32, "\"", "");
			ReplaceString(szAuth, 32, "\\", "");
			PrintPlayerStats(iClient, -1, szAuth);
			return Plugin_Continue;
		}
	}
	
	return Plugin_Continue;
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
				ReplyToCommand(iClient, "[OpenFrags] No target found; if you meant to use a SteamID2, you need to use quotes (e.g sm_playerstats_stats \"STEAM_0:1:522065531\")")
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
		CPrintToChat(iClient, "%t %t", "OpenFrags ChatPrefix", "OpenFrags About", PLUGIN_VERSION);
	else {
		char szAbout[256];
		Format(szAbout, 256, "%t %t", "OpenFrags ChatPrefix","OpenFrags About", PLUGIN_VERSION);
		CRemoveTags(szAbout, 256);
		PrintToServer(szAbout);
	}
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