// SPDX-FileCopyrightText: 2026 Twelve Actors contributors
// SPDX-License-Identifier: MPL-2.0 OR GPL-3.0-or-later
//
// Dual-offered because this plugin is compiled against SourceMod (GPL-3.0) via
// #include <sourcemod>, so the compiled .smx is a combination rather than a
// merely-loaded file. MPL-2.0 §3.3 permits distributing such a Larger Work
// under a Secondary License; this file carries no "Incompatible With Secondary
// Licenses" notice, so that route is open. The file itself remains MPL-2.0 for
// anyone who wants it on those terms.
/**
 * ta_botjoin.sp — stop the RCBot2 "join suicide" that clients render as
 * "ERRORNAME committed suicide" in the kill feed.
 *
 * Measured on dod_donner with RCBot2 1.5x + DoD:S:
 *   [sw] SPAWN  Kowalski team=0 bot=1 pos=0 0 -132      <- fake client spawned alive, no team
 *          "Kowalski<408><BOT><Unassigned>" joined team "Allies"
 *          "Kowalski<408><BOT><Allies>" committed suicide with "world"   <- team change kills the alive body
 *   [sw] DEATH  Kowalski team=2 bot=1 pos=0 0 -74 killer=world
 *          "Kowalski<408><BOT><Allies>" changed role to "#class_allied_garand"
 *
 * RCBot2 changes a bot's team before it sends the class command. DoD:S spawns
 * the bot on connect, so the team change kills a live body; the death notice
 * goes out before clients know the bot's name, hence ERRORNAME.
 *
 * Fix: fake clients in team 0 (no team) are put in LIFE_DEAD right after their
 * connect spawn, so the team change has nothing to kill. The class command then
 * spawns the bot normally at its team spawn point — no death, no kill feed line.
 * Verified on a sandbox server: 0 "committed suicide with world" lines while the
 * roster filled from 0 to 12, and every bot spawned alive at its team spawn.
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "1.0.0"
#define LIFE_DEAD 2

ConVar g_cvEnable;
ConVar g_cvDebug;

public Plugin myinfo = {
    name = "Twelve Actors Bot Join Fix",
    author = "Twelve Actors",
    description = "Stops the classless team-join suicide (ERRORNAME in the kill feed)",
    version = PLUGIN_VERSION,
    url = ""
};

public void OnPluginStart()
{
    g_cvEnable = CreateConVar("sm_ta_botjoin_enable", "1",
        "0/1 — keep teamless fake clients dead so the team change cannot kill them", FCVAR_NOTIFY);
    g_cvDebug = CreateConVar("sm_ta_botjoin_debug", "0",
        "0/1 — log every fake client the fix holds dead", FCVAR_NOTIFY);
    HookEvent("player_spawn", Ev_PlayerSpawn, EventHookMode_Post);
    LogMessage("[botjoin] loaded (enable=%d)", g_cvEnable.IntValue);
}

public Action Ev_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnable.BoolValue) return Plugin_Continue;

    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || !IsClientInGame(client) || !IsFakeClient(client))
        return Plugin_Continue;
    if (GetClientTeam(client) > 1)
        return Plugin_Continue;   // already on a team: normal spawn, leave it alone

    SetEntProp(client, Prop_Send, "m_lifeState", LIFE_DEAD);
    if (g_cvDebug.BoolValue)
        LogMessage("[botjoin] slot %d held dead until it joins a team", client);
    return Plugin_Continue;
}
