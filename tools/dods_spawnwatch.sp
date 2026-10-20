// SPDX-FileCopyrightText: 2026 Twelve Actors contributors
// SPDX-License-Identifier: MPL-2.0
#include <sourcemod>

#define CP3_X -554.0
#define CP3_Y -101.0
#define CP3_Z -12.0

public Plugin myinfo =
{
    name = "dods spawnwatch",
    author = "admin",
    description = "Logs spawn and death positions so bot spawn-camping can be measured",
    version = "1.0",
    url = ""
};

public void OnPluginStart()
{
    HookEvent("player_spawn", Ev_Spawn, EventHookMode_Post);
    HookEvent("player_death", Ev_Death, EventHookMode_Post);
    RegServerCmd("sm_posdump", Cmd_Pos, "dump every client origin and distance to the donner tank flag");
    char map[64];
    GetCurrentMap(map, sizeof(map));
    PrintToServer("[sw] spawnwatch loaded map=%s dTank_ref=%.0f,%.0f,%.0f", map, CP3_X, CP3_Y, CP3_Z);
}

float DistTank(const float o[3])
{
    float dx = o[0] - CP3_X, dy = o[1] - CP3_Y, dz = o[2] - CP3_Z;
    return SquareRoot(dx * dx + dy * dy + dz * dz);
}

public Action Ev_Spawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || !IsClientInGame(client))
        return Plugin_Continue;

    float o[3];
    GetClientAbsOrigin(client, o);
    PrintToServer("[sw] SPAWN %N team=%d bot=%d pos=%.0f %.0f %.0f dTank=%.0f",
                  client, GetClientTeam(client), IsFakeClient(client), o[0], o[1], o[2], DistTank(o));
    return Plugin_Continue;
}

public Action Ev_Death(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    if (victim <= 0 || !IsClientInGame(victim))
        return Plugin_Continue;

    float vo[3];
    GetClientAbsOrigin(victim, vo);

    char atk[64] = "world";
    float ao[3];
    float ad = -1.0;
    if (attacker > 0 && attacker != victim && IsClientInGame(attacker))
    {
        Format(atk, sizeof(atk), "%N", attacker);
        GetClientAbsOrigin(attacker, ao);
        float dx = ao[0] - vo[0], dy = ao[1] - vo[1], dz = ao[2] - vo[2];
        ad = SquareRoot(dx * dx + dy * dy + dz * dz);
    }

    PrintToServer("[sw] DEATH %N team=%d bot=%d pos=%.0f %.0f %.0f dTank=%.0f killer=%s dKiller=%.0f",
                  victim, GetClientTeam(victim), IsFakeClient(victim), vo[0], vo[1], vo[2],
                  DistTank(vo), atk, ad);
    return Plugin_Continue;
}

public Action Cmd_Pos(int args)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
            continue;

        float o[3];
        GetClientAbsOrigin(i, o);
        PrintToServer("[sw] DUMP %N team=%d bot=%d alive=%d pos=%.0f %.0f %.0f dTank=%.0f",
                      i, GetClientTeam(i), IsFakeClient(i), !IsPlayerAlive(i) ? 0 : 1,
                      o[0], o[1], o[2], DistTank(o));
    }
    return Plugin_Handled;
}
