// SPDX-FileCopyrightText: 2026 Twelve Actors contributors
// SPDX-License-Identifier: MPL-2.0
/**
 * ta_humancap — reserve the server's bot slots by capping human connections.
 *
 * Why: RCBot2 keeps a fixed bot cast (sm_ta_bots_target, currently 12). The
 * server has 24 slots. If humans fill all 24, bots get pushed out, and any
 * population module that re-adds them fights the engine for the last slot.
 * Capping humans at 12 leaves exactly 12 slots for the bot cast, so bots are
 * never displaced and never churn.
 *
 * Behaviour: a connection attempt beyond the cap is rejected at connect time
 * (before the client is put in server), with a message the client can read.
 * Bots, SourceTV and Replay are never counted or blocked.
 */

#pragma semicolon 1
#include <sourcemod>

#define PLUGIN_VERSION "1.0.0"

ConVar g_cvCap;

public Plugin myinfo =
{
    name        = "Twelve Actors Human Cap",
    author      = "Twelve Actors",
    description = "Caps human slots so the bot cast always fits",
    version     = PLUGIN_VERSION,
    url         = ""
};

public void OnPluginStart()
{
    g_cvCap = CreateConVar("sm_ta_humancap", "12",
        "Maximum simultaneous human players (0 = unlimited). Bots use the remaining slots.",
        FCVAR_NOTIFY, true, 0.0, true, 31.0);
    AutoExecConfig(true, "ta_humancap");
    LogMessage("[ta_humancap] active, cap=%d", g_cvCap.IntValue);
}

public bool OnClientConnect(int client, char[] rejectmsg, int maxlen)
{
    if (IsFakeClient(client)) return true;

    int cap = g_cvCap.IntValue;
    if (cap <= 0) return true;

    int humans = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (i == client) continue;
        if (IsClientInGame(i) && !IsFakeClient(i)) humans++;
    }

    if (humans >= cap) {
        FormatEx(rejectmsg, maxlen,
            "Server full: %d human slots, %d reserved for bots.", cap, MaxClients - cap);
        char name[MAX_NAME_LENGTH];
        GetClientName(client, name, sizeof(name));
        LogMessage("[ta_humancap] rejected \"%s\" (%d/%d humans)", name, humans, cap);
        return false;
    }
    return true;
}

public void OnClientPutInServer(int client)
{
    if (IsFakeClient(client)) return;
    int humans = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && !IsFakeClient(i)) humans++;
    }
    LogMessage("[ta_humancap] humans now %d/%d", humans, g_cvCap.IntValue);
}
