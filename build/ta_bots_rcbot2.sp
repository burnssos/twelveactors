// SPDX-FileCopyrightText: 2026 Twelve Actors contributors
// SPDX-License-Identifier: MPL-2.0
/**
 * ta_bots_rcbot2.sp — the bot module (separate from the conversation core).
 *
 * Why separate: the conversation core must stay game-agnostic, while bot
 * population is always game-specific. On DoD:S the only bot system that exists
 * is RCBot2, a Metamod plugin with its own quota logic in config.ini. This
 * module owns that quota so nobody else has to, and exposes a tiny native API
 * the core can use when present.
 *
 * The kick/add loop this replaces: dods_botfill kicked to 11 while config.ini
 * held min_bots=max_bots=12, so RCBot2 re-added a bot every pass. Here a single
 * owner sets both bounds from one cvar and RCBot2 does the adding itself.
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "0.1.0"

ConVar g_cvTarget;
ConVar g_cvEnabled;
Handle g_hQuotaInterval;
bool g_bRcbot2;
int g_iAppliedTarget = -1;
int g_iPasses;
StringMap g_hVoiced;   // exact in-game names of voiced characters

public Plugin myinfo = {
    name = "Twelve Actors Bots (RCBot2)",
    author = "Twelve Actors",
    description = "Owns RCBot2 bot population and exposes the bot roster to the core",
    version = PLUGIN_VERSION,
    url = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    CreateNative("TaBots_Available", Native_Available);
    CreateNative("TaBots_Count", Native_Count);
    CreateNative("TaBots_GetInfo", Native_GetInfo);
    CreateNative("TaBots_Pick", Native_Pick);
    CreateNative("TaBots_SetTarget", Native_SetTarget);
    CreateNative("TaBots_GetTarget", Native_GetTarget);
    return APLRes_Success;
}

public void OnPluginStart()
{
    g_cvEnabled = CreateConVar("sm_ta_bots_enable", "1",
        "Let the Twelve Actors bot module own RCBot2 population", FCVAR_NOTIFY);
    g_cvTarget = CreateConVar("sm_ta_bots_target", "12",
        "Bots to keep on the server (both bounds of the RCBot2 quota)", FCVAR_NOTIFY,
        true, 0.0, true, 31.0);

    g_hQuotaInterval = FindConVar("rcbot_bot_quota_interval");
    g_bRcbot2 = (g_hQuotaInterval != null);

    if (!g_bRcbot2) {
        LogMessage("[twelveactors] RCBot2 not present — bot module idle");
        return;
    }

    // Auto-quota would fight our bounds; min/max become the only logic.
    SetConVarInt(g_hQuotaInterval, -1);

    LoadVoiced();
    HookConVarChange(g_cvTarget, OnTargetChanged);
    HookConVarChange(g_cvEnabled, OnTargetChanged);
    ApplyTarget(true);
    CreateTimer(10.0, Timer_Supervise, _, TIMER_REPEAT);
    RegConsoleCmd("sm_ta_bots", Command_Status, "Twelve Actors bot module status");
    RegConsoleCmd("sm_ta_bots_reload", Command_ReloadVoiced, "Reload voiced.txt");
    LogMessage("[twelveactors] bot module attached to RCBot2, target=%d", g_cvTarget.IntValue);
}

public void OnAllPluginsLoaded()
{
    if (g_bRcbot2 && g_cvEnabled.BoolValue) ApplyTarget(true);
}

public void OnTargetChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    ApplyTarget(true);
}

int CountHumans()
{
    int humans = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && !IsFakeClient(i) && !IsClientSourceTV(i))
            humans++;
    }
    return humans;
}

void ApplyTarget(bool force = false)
{
    if (!g_bRcbot2 || !g_cvEnabled.BoolValue) return;
    int target = g_cvTarget.IntValue;

    // RCBot2's max_bots is a TOTAL CLIENT cap, humans included — not a bot cap.
    // Writing max_bots = target while a human is connected leaves room for only
    // target-1 bots, so every "rcbotd addbot" this module issues is refused with
    // "Can't create bot, max_bots reached" while RCBot2 kicks to stay under the
    // cap: that is the kick/add churn. Budget the humans into the cap instead.
    int cap = target + CountHumans();
    if (cap > MaxClients) cap = MaxClients;

    // RCBot2 logs both values every time it accepts a write, so writing the
    // pair every 10 s floods the journal (~17k lines/day). Write when the number
    // changed, when a config exec may have overwritten it (force: plugin start,
    // OnConfigsExecuted, cvar change), and otherwise once every 12 passes as
    // drift correction. The property that matters is kept: a config.ini exec
    // that lands after plugin start cannot survive the next map's
    // OnConfigsExecuted.
    bool changed = (cap != g_iAppliedTarget);
    if (!force && !changed && ++g_iPasses < 12) return;
    g_iPasses = 0;

    char cmd[128];
    // min first: RCBot2 refuses any pair where max <= min, and a stale min from
    // a previous config would otherwise block the write.
    ServerCommand("rcbotd config min_bots 0");
    Format(cmd, sizeof(cmd), "rcbotd config max_bots %d", cap);
    ServerCommand(cmd);
    // Take free profiles in order (1,2,3...), so every added bot lands on a
    // persona slot instead of a random profile from the launcher set.
    ServerCommand("rcbot_nonrandom_profile 1");

    if (changed) {
        g_iAppliedTarget = cap;
        LogMessage("[twelveactors] RCBot2 quota idle (min 0 / max %d = %d bots + %d humans), module owns population",
            cap, target, cap - target);
    }
}

public void OnConfigsExecuted()
{
    // server.cfg and per-map configs run after OnPluginStart, and config.ini
    // carries its own min_bots/max_bots: re-assert once every map, after every
    // config exec, not just when our own number changes.
    ApplyTarget(true);
}

public Action Timer_Supervise(Handle timer)
{
    if (!g_bRcbot2 || !g_cvEnabled.BoolValue) return Plugin_Continue;
    // Guard against a config exec (server.cfg, map config) resetting the bounds,
    // and re-budget the human slots whenever someone joins or leaves: the cap is
    // humans + target, so a stale cap either strangles the roster or leaves
    // headroom for RCBot2 to add unvoiced profiles that then get kicked.
    ApplyTarget();

    bool enforce = (g_hVoiced != null && g_hVoiced.Size > 0);
    int target = g_cvTarget.IntValue;
    int voiced = 0;
    int stray = 0;
    StringMap seen = new StringMap();

    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i) || !IsFakeClient(i)) continue;
        char name[MAX_NAME_LENGTH];
        GetClientName(i, name, sizeof(name));
        // Unvoiced, or a second bot wearing a persona that is already on the
        // server: RCBot2 re-adds a profile it lost track of, so "John" can be
        // there twice while "Thomas" is missing. Counting clients instead of
        // personas made that look like a full roster and blocked the add.
        if (enforce && (!g_hVoiced.ContainsKey(name) || seen.ContainsKey(name))) {
            if (stray == 0) stray = i;
            continue;
        }
        seen.SetValue(name, 1);
        voiced++;
    }
    delete seen;

    // Anyone not on the voiced list is renamed onto a free persona instead of
    // being kicked: every kick costs a death notice in the kill feed and sends
    // RCBot2 straight back into its add path, which is the add/kick churn.
    if (stray > 0) {
        char persona[MAX_NAME_LENGTH];
        if (FindFreeVoiced(persona, sizeof(persona)) && SetClientName(stray, persona)) {
            LogMessage("[twelveactors] renamed stray bot (slot %d) to %s", stray, persona);
        } else {
            ServerCommand("kickid %d", GetClientUserId(stray));
            LogMessage("[twelveactors] no free persona; removed unvoiced bot (slot %d)", stray);
        }
        return Plugin_Continue;
    }

    if (voiced < target) {
        ServerCommand("rcbotd addbot");
    } else if (voiced > target) {
        for (int i = 1; i <= MaxClients; i++) {
            if (!IsClientInGame(i) || !IsFakeClient(i)) continue;
            ServerCommand("kickid %d", GetClientUserId(i));
            LogMessage("[twelveactors] over target (%d > %d), removed a bot", voiced, target);
            break;
        }
    }
    return Plugin_Continue;
}

bool FindFreeVoiced(char[] out, int len)
{
    if (g_hVoiced == null || g_hVoiced.Size == 0) return false;
    StringMapSnapshot snap = g_hVoiced.Snapshot();
    bool found = false;
    for (int i = 0; i < snap.Length; i++) {
        char name[MAX_NAME_LENGTH];
        snap.GetKey(i, name, sizeof(name));
        bool used = false;
        for (int c = 1; c <= MaxClients; c++) {
            if (!IsClientInGame(c)) continue;
            char current[MAX_NAME_LENGTH];
            GetClientName(c, current, sizeof(current));
            if (StrEqual(current, name, false)) { used = true; break; }
        }
        if (!used) { strcopy(out, len, name); found = true; break; }
    }
    delete snap;
    return found;
}

void LoadVoiced()
{
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "data/twelveactors/voiced.txt");
    delete g_hVoiced;
    g_hVoiced = new StringMap();

    File f = OpenFile(path, "r");
    if (f == null) {
        LogMessage("[twelveactors] voiced.txt missing at %s — voiced-only enforcement OFF", path);
        return;
    }
    char line[64];
    while (!f.EndOfFile() && f.ReadLine(line, sizeof(line))) {
        TrimString(line);
        if (line[0] == '\0' || line[0] == '#') continue;
        g_hVoiced.SetValue(line, 1);
    }
    delete f;
    LogMessage("[twelveactors] voiced roster loaded: %d characters", g_hVoiced.Size);
}

public Action Command_ReloadVoiced(int client, int args)
{
    LoadVoiced();
    ReplyToCommand(client, "[twelveactors] voiced roster: %d characters", g_hVoiced.Size);
    return Plugin_Handled;
}

public Action Command_Status(int client, int args)
{
    ReplyToCommand(client, "[twelveactors] module=%s rcbot2=%d enabled=%d target=%d applied=%d bots=%d",
        "rcbot2", g_bRcbot2 ? 1 : 0, g_cvEnabled.IntValue, g_cvTarget.IntValue,
        g_iAppliedTarget, Native_Count(INVALID_HANDLE, 0));
    return Plugin_Handled;
}

// ------------------------------------------------------------------ natives

any Native_Available(Handle plugin, int numParams)
{
    return g_bRcbot2;
}

any Native_Count(Handle plugin, int numParams)
{
    int n;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && IsFakeClient(i)) n++;
    }
    return n;
}

// index is 0-based over live bots; fills name + team
any Native_GetInfo(Handle plugin, int numParams)
{
    int wanted = GetNativeCell(1);
    int maxlen = GetNativeCell(3);
    int seen = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i) || !IsFakeClient(i)) continue;
        if (seen++ != wanted) continue;
        char name[MAX_NAME_LENGTH];
        GetClientName(i, name, sizeof(name));
        SetNativeString(2, name, maxlen);
        SetNativeCellRef(4, GetClientTeam(i));
        return i;
    }
    return 0;
}

// team 2/3, nearClient for future proximity preference (0 = anywhere)
any Native_Pick(Handle plugin, int numParams)
{
    int team = GetNativeCell(1);
    int near = GetNativeCell(2);
    int candidates[MAXPLAYERS + 1];
    int n;
    float nearPos[3];
    if (near > 0 && IsClientInGame(near)) GetClientAbsOrigin(near, nearPos);

    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i) || !IsFakeClient(i)) continue;
        if (team > 0 && GetClientTeam(i) != team) continue;
        candidates[n++] = i;
    }
    if (n == 0) return -1;
    if (near <= 0 || !IsClientInGame(near)) return candidates[GetRandomInt(0, n - 1)];

    int best = candidates[0];
    float bestDist = 1.0e9;
    for (int k = 0; k < n; k++) {
        float pos[3];
        GetClientAbsOrigin(candidates[k], pos);
        float d = GetVectorDistance(pos, nearPos);
        if (d < bestDist) { bestDist = d; best = candidates[k]; }
    }
    return best;
}

any Native_SetTarget(Handle plugin, int numParams)
{
    SetConVarInt(g_cvTarget, GetNativeCell(1));
    return 0;
}

any Native_GetTarget(Handle plugin, int numParams)
{
    return g_cvTarget.IntValue;
}

