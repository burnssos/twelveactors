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

#define PLUGIN_VERSION "0.2.0"

// DoD:S team indices.
#define TA_TEAM_ANY     0
#define TA_TEAM_ALLIES  2
#define TA_TEAM_AXIS    3

// Positional class argument for `rcbotd addbot <class> <team> <name>`. The team
// and name are what this module needs; the class is filler that RCBot2 resolves
// itself, and ta_botjoin spawns the bot properly on player_spawn regardless.
// Verified live with both 0 and 1: identical outcome. Candidate for a convar.
#define TA_ADDBOT_CLASS 0

ConVar g_cvTarget;
ConVar g_cvEnabled;
bool g_bRcbot2;
int g_iAppliedTarget = -1;
int g_iPasses;
StringMap g_hVoiced;
ArrayList g_hOrder;      // cast names in voiced.txt order (C5: deterministic)
int g_iTyped;            // how many carry a team (0 => pre-v2 file)

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

    // Presence check only. FindConVar asks VALVE'S cvar registry whether a
    // convar of that name has been registered by anyone; it is a question to
    // the engine, not a reach into RCBot2. The handle is deliberately not
    // retained, so this module holds no reference to anything of RCBot2's.
    g_bRcbot2 = (FindConVar("rcbot_bot_quota_interval") != null);

    if (!g_bRcbot2) {
        LogMessage("[twelveactors] RCBot2 not present — bot module idle");
        return;
    }

    // Auto-quota would fight our bounds; min/max become the only logic.
    //
    // Issued as a console command rather than written through a convar handle,
    // so that EVERY action this module takes is a string handed to Valve's
    // parser — one an administrator could type by hand, with no handle held
    // and nothing of RCBot2's addressed directly. The behaviour is identical;
    // the boundary is not.
    ServerCommand("rcbot_bot_quota_interval -1");

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
    int strays[MAXPLAYERS + 1];
    int strayCount = 0;
    StringMap seen = new StringMap();

    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i) || !IsFakeClient(i)) continue;
        char name[MAX_NAME_LENGTH];
        GetClientName(i, name, sizeof(name));
        // Unvoiced, or a second bot wearing a persona that is already on the
        // server: RCBot2 re-adds a profile it lost track of, so "John" can be
        // there twice while "Thomas" is missing. Counting clients instead of
        // personas made that look like a full roster and blocked the add.
        // Case: StringMap keys are exact, StrEqual below is case-insensitive.
        // Three different policies on one name used to coexist, so a bot named
        // "john" was simultaneously NOT on the voiced list (a stray) and
        // OCCUPYING "John" (making it unavailable) -- one impostor removing a
        // persona from circulation and guaranteeing a stray that can never be
        // named. Canonicalise to the cast's own spelling before any lookup.
        char canon[MAX_NAME_LENGTH];
        if (Canonical(name, canon, sizeof(canon))) strcopy(name, sizeof(name), canon);
        if (enforce && (!g_hVoiced.ContainsKey(name) || seen.ContainsKey(name))) {
            if (strayCount < sizeof(strays)) strays[strayCount++] = i;
            continue;
        }
        seen.SetValue(name, 1);
        voiced++;
    }
    delete seen;

    // Anyone not on the voiced list is renamed onto a free persona instead of
    // being kicked: every kick costs a death notice in the kill feed and sends
    // RCBot2 straight back into its add path, which is the add/kick churn.
    //
    // EVERY stray is handled in this pass, and the add below still runs. An
    // earlier version renamed one and returned, so each bot cost two 10 s
    // passes -- add on pass n, name on pass n+1 -- and a twelve-bot fill took
    // ~240 s with launcher names visible in the scoreboard, in team chat and
    // in the kill feed the whole time. That is the same class of problem
    // BOT-JOIN-FIX.md records as the "ERRORNAME" spam.
    int repaired = 0;
    for (int s2 = 0; s2 < strayCount; s2++) {
        int c = strays[s2];
        if (!IsClientInGame(c)) continue;
        char persona[MAX_NAME_LENGTH];
        // Match the stray's current team, so repairing a name cannot put a
        // German persona on an Allied bot.
        if (FindFreeVoiced(persona, sizeof(persona), GetClientTeam(c))
            && SetClientName(c, persona)) {
            LogMessage("[twelveactors] renamed stray bot (slot %d) to %s", c, persona);
            voiced++;
            repaired++;
        } else {
            ServerCommand("kickid %d", GetClientUserId(c));
            LogMessage("[twelveactors] no free persona; removed unvoiced bot (slot %d)", c);
        }
    }
    if (repaired > 0 && voiced >= target) return Plugin_Continue;

    if (voiced < target) {
        // Name and team at creation, in one console string. Verified on the live
        // server 21 Oct 2026: `rcbotd addbot <class> <team> <name>` honours all
        // three, and the name PERSISTS -- a bot added as ZZTest3 was still
        // ZZTest3 after 37 s with this module disabled. (Earlier renames to
        // Frank/Walter were this module's own stray path, not RCBot2 reclaiming
        // the name from a profile.)
        //
        // This matters beyond tidiness: a bot created with the right name on the
        // right team is never briefly wrong, so there is no window in which the
        // daemon can see a persona it does not recognise.
        int want = ShortestTeam(target);
        char persona[MAX_NAME_LENGTH];
        if (want != TA_TEAM_ANY && FindFreeVoiced(persona, sizeof(persona), want)) {
            char add[128];
            Format(add, sizeof(add), "rcbotd addbot %d %d %s", TA_ADDBOT_CLASS, want, persona);
            ServerCommand(add);
            LogMessage("[twelveactors] adding %s to team %d (%d/%d voiced)", persona, want, voiced, target);
        } else {
            // No team data in the cast, or no free persona for the short side:
            // let RCBot2 pick, and the stray path above will rename or remove.
            ServerCommand("rcbotd addbot");
        }
    } else if (voiced > target) {
        // Take the surplus from whichever side is over its share, not simply the
        // first bot found: kicking off the short team leaves the roster the same
        // size and still unbalanced, and the next pass does it again.
        int over = ShortestTeam(target);
        if (over == TA_TEAM_ALLIES) over = TA_TEAM_AXIS;
        else if (over == TA_TEAM_AXIS) over = TA_TEAM_ALLIES;

        for (int pass = 0; pass < 2; pass++) {
            for (int i = 1; i <= MaxClients; i++) {
                if (!IsClientInGame(i) || !IsFakeClient(i)) continue;
                if (pass == 0 && over != TA_TEAM_ANY && GetClientTeam(i) != over) continue;
                ServerCommand("kickid %d", GetClientUserId(i));
                LogMessage("[twelveactors] over target (%d > %d), removed a bot from team %d",
                    voiced, target, GetClientTeam(i));
                return Plugin_Continue;
            }
            if (over == TA_TEAM_ANY) break;
        }
    }
    return Plugin_Continue;
}

// Find a persona that no BOT is currently wearing. `team` is DoD:S team index
// (2 Allies, 3 Axis) to restrict the search to that faction's cast, or
// TA_TEAM_ANY for no restriction.
//
// Personas carry no team when voiced.txt has no second column (a pre-v2 file),
// in which case every persona matches every team and this behaves exactly as it
// did before -- the compatibility direction that matters, since an old data file
// with a new plugin must keep working.
// Map any casing of a cast name to the cast's own spelling. Returns false when
// the name is not a cast member at all.
bool Canonical(const char[] name, char[] out, int len)
{
    if (g_hOrder == null) return false;
    for (int i = 0; i < g_hOrder.Length; i++) {
        char cast[MAX_NAME_LENGTH];
        g_hOrder.GetString(i, cast, sizeof(cast));
        if (StrEqual(cast, name, false)) { strcopy(out, len, cast); return true; }
    }
    return false;
}

bool FindFreeVoiced(char[] out, int len, int team = TA_TEAM_ANY)
{
    if (g_hVoiced == null || g_hVoiced.Size == 0) return false;
    if (g_hOrder == null || g_hOrder.Length == 0) return false;
    bool found = false;
    // File order, via g_hOrder. A StringMapSnapshot iterates hash-bucket
    // order, which is neither voiced.txt order nor stable across SourceMod
    // versions -- so persona assignment was arbitrary, contradicting README's
    // "adds bots one at a time, in profile order".
    for (int i = 0; i < g_hOrder.Length; i++) {
        char name[MAX_NAME_LENGTH];
        g_hOrder.GetString(i, name, sizeof(name));

        // Wrong faction for the slot being filled. A German persona on an Allied
        // bot used to be prevented by the team= line cmd_bootstrap wrote into
        // RCBot2's profile files; that writing is gone, so the cast's own team
        // data has to carry it.
        int pteam = TA_TEAM_ANY;
        g_hVoiced.GetValue(name, pteam);
        if (team != TA_TEAM_ANY && pteam != TA_TEAM_ANY && pteam != team) continue;

        bool used = false;
        for (int c = 1; c <= MaxClients; c++) {
            if (!IsClientInGame(c)) continue;
            // Bots only. Without this, a HUMAN who names themselves after a
            // cast member marks that persona permanently unavailable -- and
            // because the steady state is every persona in use, the stray
            // branch then finds nothing free and kicks a legitimate bot every
            // 10 s, with a death notice each pass, for as long as that player
            // stays connected.
            if (!IsFakeClient(c)) continue;
            char current[MAX_NAME_LENGTH];
            GetClientName(c, current, sizeof(current));
            if (StrEqual(current, name, false)) { used = true; break; }
        }
        if (!used) { strcopy(out, len, name); found = true; break; }
    }
    return found;
}

// How many bots of each faction are wearing a persona, and which faction is
// furthest below its share of the target. Returns TA_TEAM_ANY when the cast
// carries no team data, so the caller falls back to letting RCBot2 choose.
int ShortestTeam(int target)
{
    if (g_hVoiced == null || g_hVoiced.Size == 0) return TA_TEAM_ANY;

    // Does the cast carry team data at all? A pre-v2 voiced.txt has none;
    // g_iTyped is counted once at load rather than rescanned every pass.
    if (g_iTyped == 0) return TA_TEAM_ANY;

    int onAllies = 0, onAxis = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i) || !IsFakeClient(i)) continue;
        char name[MAX_NAME_LENGTH];
        GetClientName(i, name, sizeof(name));
        if (!g_hVoiced.ContainsKey(name)) continue;
        int t = GetClientTeam(i);
        if (t == TA_TEAM_ALLIES) onAllies++;
        else if (t == TA_TEAM_AXIS) onAxis++;
    }

    // cmd_bootstrap alternates US/DE when it assembles the cast, so an even
    // split is the intended shape; the odd bot goes to Allies.
    int wantAllies = (target + 1) / 2;
    int wantAxis   = target - wantAllies;

    if (onAllies < wantAllies && (wantAllies - onAllies) >= (wantAxis - onAxis)) return TA_TEAM_ALLIES;
    if (onAxis < wantAxis) return TA_TEAM_AXIS;
    if (onAllies < wantAllies) return TA_TEAM_ALLIES;
    return TA_TEAM_ANY;
}

void LoadVoiced()
{
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "data/twelveactors/voiced.txt");
    // Reset both together and BEFORE the missing-file return below: otherwise
    // g_hVoiced ends up empty while g_hOrder still holds the previous cast,
    // and the two disagree about who is in it.
    delete g_hVoiced;
    g_hVoiced = new StringMap();
    delete g_hOrder;
    g_hOrder = new ArrayList(ByteCountToCells(MAX_NAME_LENGTH));
    g_iTyped = 0;

    File f = OpenFile(path, "r");
    if (f == null) {
        LogMessage("[twelveactors] voiced.txt missing at %s — voiced-only enforcement OFF", path);
        return;
    }
    // Format, v2:  <name> TAB <team>     team = 2 Allies, 3 Axis
    // Format, v1:  <name>                no team; every persona matches any team
    //
    // The whole trimmed line used to become the key, which is why this split
    // has to be deployed BEFORE any voiced.txt gains a second column: an old
    // .smx reading a new file would key on "John<TAB>2" and name a bot that,
    // and the failure is silent all the way to the daemon speaking as a
    // character the scoreboard does not show.
    char line[96];
    int typed = 0;
    while (!f.EndOfFile() && f.ReadLine(line, sizeof(line))) {
        TrimString(line);
        if (line[0] == '\0' || line[0] == '#') continue;

        char parts[2][MAX_NAME_LENGTH];
        int n = ExplodeString(line, "\t", parts, sizeof(parts), sizeof(parts[]));
        TrimString(parts[0]);
        if (parts[0][0] == '\0') continue;

        int team = TA_TEAM_ANY;
        if (n > 1) {
            TrimString(parts[1]);
            int t = StringToInt(parts[1]);
            if (t == TA_TEAM_ALLIES || t == TA_TEAM_AXIS) { team = t; typed++; }
        }
        g_hVoiced.SetValue(parts[0], team);
        g_hOrder.PushString(parts[0]);   // file order, for deterministic choice
    }
    delete f;
    g_iTyped = typed;
    LogMessage("[twelveactors] voiced roster loaded: %d characters (%d with a team)",
        g_hVoiced.Size, typed);
}

public Action Command_ReloadVoiced(int client, int args)
{
    LoadVoiced();
    ReplyToCommand(client, "[twelveactors] voiced roster: %d characters", g_hVoiced.Size);
    return Plugin_Handled;
}

public Action Command_Status(int client, int args)
{
    ReplyToCommand(client, "[twelveactors] module=%s rcbot2=%d enabled=%d target=%d applied=%d bots=%d cast=%d typed=%d",
        "rcbot2", g_bRcbot2 ? 1 : 0, g_cvEnabled.IntValue, g_cvTarget.IntValue,
        g_iAppliedTarget, Native_Count(INVALID_HANDLE, 0),
        g_hOrder == null ? 0 : g_hOrder.Length, g_iTyped);
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

