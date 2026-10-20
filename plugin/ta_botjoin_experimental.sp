// SPDX-FileCopyrightText: 2026 Twelve Actors contributors
// SPDX-License-Identifier: MPL-2.0
/**
 * ta_botjoin.sp — stop the RCBot2 "join suicide" that shows up as
 * "ERRORNAME committed suicide" in every client's kill feed.
 *
 * Measured on dod_donner (RCBot2 + DoD:S):
 *   [sw] SPAWN  Kowalski team=0 bot=1 pos=0 0 -132      <- fake client spawned alive in team 0
 *          "Kowalski<408><BOT><Unassigned>" joined team "Allies"
 *          "Kowalski<408><BOT><Allies>" committed suicide with "world"   <- team change kills the alive body
 *   [sw] DEATH  Kowalski team=2 bot=1 pos=0 0 -74 killer=world
 *          "Kowalski<408><BOT><Allies>" changed role to "#class_allied_garand"
 *
 * RCBot2 changes a bot's team before it sends the class command, and DoD:S kills
 * the alive spectator body on the team change. The death notice is broadcast
 * before clients have the bot's name, so they render it as ERRORNAME.
 *
 * Fix: keep the fake client in LIFE_DEAD until it has a real team, so the team
 * change has nothing to kill; the class command then spawns it normally.
 *
 * mode 1 (default): hold lifeState dead until team join (no death event).
 * mode 2: kill the bot at connect instead (fallback, still emits a notice).
 * mode 0: off.
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "0.1.0"

ConVar g_cvMode;
ConVar g_cvDebug;

public Plugin myinfo = {
    name = "Twelve Actors Bot Join Fix",
    author = "Twelve Actors",
    description = "Prevents the classless team-join suicide that shows as ERRORNAME",
    version = PLUGIN_VERSION,
    url = ""
};

public void OnPluginStart()
{
    g_cvMode = CreateConVar("sm_ta_botjoin_mode", "4",
        "0=off, 1=hold fake clients dead until they join a team, 2=kill fake clients at connect",
        FCVAR_NOTIFY, true, 0.0, true, 2.0);
    g_cvDebug = CreateConVar("sm_ta_botjoin_debug", "1", "Log what the fix does (0/1)", FCVAR_NOTIFY);
    HookEvent("player_spawn", Ev_PlayerSpawn, EventHookMode_Post);
    LogMessage("[botjoin] loaded, mode=%d", g_cvMode.IntValue);
}

public void OnClientPutInServer(int client)
{
    if (!IsFakeClient(client)) return;

    int mode = g_cvMode.IntValue;
    if (mode == 0 || mode == 4) return;

    if (mode == 2) {
        FakeClientCommand(client, "kill");
        if (g_cvDebug.BoolValue) LogMessage("[botjoin] mode2: killed fake client slot %d at connect", client);
        return;
    }

    if (mode == 3) {
        SetEntProp(client, Prop_Send, "m_iDesiredPlayerClass", 1);
        if (g_cvDebug.BoolValue)
            LogMessage("[botjoin] slot %d connect: desired class set to %d", client,
                GetEntProp(client, Prop_Send, "m_iDesiredPlayerClass"));
        CreateTimer(0.05, Timer_SetDesired, GetClientUserId(client), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
        return;
    }

    SetEntProp(client, Prop_Send, "m_lifeState", 2);
    if (g_cvDebug.BoolValue)
        LogMessage("[botjoin] slot %d connect: lifeState forced to %d", client,
            GetEntProp(client, Prop_Send, "m_lifeState"));
    CreateTimer(0.05, Timer_HoldDead, GetClientUserId(client), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public Action Ev_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || !IsFakeClient(client)) return Plugin_Continue;
    if (GetClientTeam(client) > 1) return Plugin_Continue;
    SetEntProp(client, Prop_Send, "m_lifeState", 2);
    if (g_cvDebug.BoolValue)
        LogMessage("[botjoin] spawn hook: slot %d team=0 -> lifeState=%d", client,
            GetEntProp(client, Prop_Send, "m_lifeState"));
    return Plugin_Continue;
}

public Action Timer_SetDesired(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientInGame(client) || !IsFakeClient(client))
        return Plugin_Stop;
    if (GetClientTeam(client) > 1)
        return Plugin_Stop;
    SetEntProp(client, Prop_Send, "m_iDesiredPlayerClass", 1 /* rifleman */);
    return Plugin_Continue;
}

public Action Timer_HoldDead(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientInGame(client) || !IsFakeClient(client))
        return Plugin_Stop;
    if (GetClientTeam(client) > 1) {
        if (g_cvDebug.BoolValue)
            LogMessage("[botjoin] slot %d joined team %d (lifeState was %d)",
                client, GetClientTeam(client), GetEntProp(client, Prop_Send, "m_lifeState"));
        return Plugin_Stop;   // real team assigned: let the class command spawn it
    }

    SetEntProp(client, Prop_Send, "m_lifeState", 2 /* LIFE_DEAD */);
    if (g_cvDebug.BoolValue)
        LogMessage("[botjoin] slot %d team=%d life=%d -> forced dead",
            client, GetClientTeam(client), GetEntProp(client, Prop_Send, "m_lifeState"));
    return Plugin_Continue;
}

public void OnMapStart()
{
    // bots live in the same slots after a map change; re-arm the hold for any
    // fake client that is still classless.
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientConnected(i) && IsFakeClient(i) && GetClientTeam(i) <= 1)
            CreateTimer(0.05, Timer_HoldDead, GetClientUserId(i), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    }
}
