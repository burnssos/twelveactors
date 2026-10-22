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
 * twelveactors.sp — cross-source NPC conversation, core plugin.
 *
 * The plugin is deliberately thin: it emits what happened (chat, deaths, round
 * starts) as TSV lines into data/twelveactors/in.tsv and plays back whatever the
 * Python daemon writes to data/twelveactors/out.tsv. All language, memory and
 * persona logic lives in the daemon, so this file has no HTTP, no JSON and no
 * per-game branching beyond the profile the daemon loads.
 *
 * TSV was chosen over JSON because SourcePawn has no stdlib JSON parser and a
 * hand-rolled one is a bug farm for arbitrary player text.
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "0.3.0"
#define MAX_LINE 512
// Optional per-persona voice tuning, read from data/twelveactors/voices.tsv at load
// and on sm_ta_reload. Small fixed table: the cast is a dozen names, and a
// linear scan once per bark is cheaper than an ADT lookup.
#define MAX_TUNED 32

// Every named voice command the DoD:S server implements (strings pulled from
// bin/server_srv.so), plus the microphone key and the HL2-style voicemenu.
char g_sVoiceCmds[][] = {
    "voice_gogogo", "voice_hold", "voice_cover", "voice_coverflanks",
    "voice_sticktogether", "voice_usesmoke", "voice_usegrens", "voice_ceasefire",
    "voice_fallback", "voice_fireleft", "voice_fireright", "voice_left",
    "voice_right", "voice_attack", "voice_tank", "voice_movewithtank",
    "voice_yessir", "voice_negative", "voice_backup", "voice_fireinhole",
    "voice_grenade", "voice_sniper", "voice_niceshot", "voice_thanks",
    "voice_areaclear", "voice_dropweapons", "voice_displace", "voice_mgahead",
    "voice_enemybehind", "voice_moveupmg", "voice_needammo", "voice_usebazooka",
    "voice_bazookaspotted", "voice_takeammo", "voice_medic", "voice_wegothim",
    "voice_wtf"
};

ConVar g_cvEnable;
ConVar g_cvSpeak;
ConVar g_cvDebug;
ConVar g_cvAutoBind;
ConVar g_cvRadioKeys;
ConVar g_cvRequireHuman;
ConVar g_cvTeamChat;
ConVar g_cvVoicePitch;
int g_iGated;
float g_fLastMenu[MAXPLAYERS + 1];
float g_fLastVoice[MAXPLAYERS + 1];
char g_sInFile[PLATFORM_MAX_PATH];
char g_sOutFile[PLATFORM_MAX_PATH];
char g_sClipsFile[PLATFORM_MAX_PATH];
char g_sRosterFile[PLATFORM_MAX_PATH];
int g_iSeq;
int g_iLastOut;
Handle g_hPoll;
Handle g_hRoster;
bool g_bClipsPrecached;
char g_sTunedName[MAX_TUNED][MAX_NAME_LENGTH];
int g_iTunedPitch[MAX_TUNED];
float g_fTunedGain[MAX_TUNED];
int g_iTuned;
// Playback forward. A module that wants to own how a bark reaches the listener
// (ta_proximity does distance falloff) defines a public Ta_OnBotVoice and
// returns Plugin_Handled; the core then stays out of the sound path entirely.
// A global forward reaches whatever plugins currently define that function, so
// this works whether the module loads before or after the core.
Handle g_hVoiceForward;

public Plugin myinfo = {
    name = "Twelve Actors Core",
    author = "Twelve Actors",
    description = "NPC conversation bridge: events out, voiced lines in",
    version = PLUGIN_VERSION,
    url = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    // ET_Hook: the first module that handles the bark stops the chain, so two
    // playback modules can never both emit the same line.
    g_hVoiceForward = CreateGlobalForward("Ta_OnBotVoice", ET_Hook,
        Param_Cell, Param_String, Param_Cell, Param_Float);
    return APLRes_Success;
}

public void OnPluginStart()
{
    BuildPath(Path_SM, g_sInFile, sizeof(g_sInFile), "data/twelveactors/in.tsv");
    BuildPath(Path_SM, g_sOutFile, sizeof(g_sOutFile), "data/twelveactors/out.tsv");
    BuildPath(Path_SM, g_sClipsFile, sizeof(g_sClipsFile), "data/twelveactors/clips.txt");
    BuildPath(Path_SM, g_sRosterFile, sizeof(g_sRosterFile), "data/twelveactors/roster.tsv");

    g_cvEnable = CreateConVar("sm_ta_enable", "1", "Enable the Twelve Actors bridge", FCVAR_NOTIFY);
    g_cvSpeak = CreateConVar("sm_ta_speak", "1", "Play voice clips for generated lines");
    g_cvDebug = CreateConVar("sm_ta_debug", "0", "Log bridge traffic");
    g_cvAutoBind = CreateConVar("sm_ta_autobind", "1", "Bind the radio menu keys on join");
    // Which keys to take. DoD:S puts voice on V by default, so the old C/V/B
    // default silently removed a player's microphone key five seconds after
    // they connected. 1/2/3 are the weapon slots, which most players leave
    // unused in favour of the mousewheel. Neither choice is free — the server
    // cannot read a client's binds (there is no engine mechanism for it), so
    // autobind always overwrites blind. Hence a convar: a server owner who
    // disagrees changes this rather than the source, and setting it empty
    // binds nothing at all.
    //
    // Accepts "123" or "cvb" (one key per character) or a comma-separated
    // list for named keys, e.g. "MOUSE4,MOUSE5,b".
    g_cvRadioKeys = CreateConVar("sm_ta_radio_keys", "123",
        "Keys bound to the radio menu pages; empty binds none", FCVAR_NOTIFY);
    // With no human connected there is nobody to hear a bark, so the whole
    // pipeline (event capture, daemon LLM turn, clip playback) is wasted work.
    // Default on: the server idles with 12 bots and generates nothing.
    g_cvRequireHuman = CreateConVar("sm_ta_require_human", "1",
        "Only run bot dialog while at least one human player is connected", FCVAR_NOTIFY);
    // Bot lines used to be printed with PrintToChatAll in white, which reads as
    // a server announcement. Sending them as say_team from the bot's own client
    // puts them in team chat with the bot's name and team colour, and hides
    // them from the other team the way a player's team chat would be.
    g_cvTeamChat = CreateConVar("sm_ta_team_chat", "1",
        "Deliver bot lines as say_team from the bot instead of white all-chat", FCVAR_NOTIFY);

    // Voice shaping. DoD:S ships one male US voice and one male German voice,
    // so every American bot sounds identical. A per-persona pitch offset buys
    // distinct voices with no new assets and no client download: pitch is sent
    // in the sound packet, not baked into the file. This is core behaviour, on
    // by default; distance attenuation is an optional module (ta_proximity)
    // that hooks the Ta_OnBotVoice forward.
    g_cvVoicePitch = CreateConVar("sm_ta_voice_pitch", "1",
        "Give each bot its own clip pitch (data/twelveactors/voices.tsv overrides)", FCVAR_NOTIFY);

    RegConsoleCmd("sm_ta", Command_Status, "Twelve Actors status");
    RegConsoleCmd("sm_ta_status", Command_Status, "Twelve Actors status");
    RegConsoleCmd("sm_ta_reload", Command_Reload, "Twelve Actors: re-read clips.txt");
    RegConsoleCmd("sm_ta_test", Command_Test, "Twelve Actors: force a voice act, e.g. sm_ta_test attack");
    RegConsoleCmd("sm_ta_say", Command_Say, "Twelve Actors: send text to the daemon as yourself");
    RegConsoleCmd("sm_ta_radio", Command_Radio, "Twelve Actors: open a radio page (0=orders 1=reply 2=tactical)");
    RegConsoleCmd("sm_ta_radiosim", Command_RadioSim, "Twelve Actors: simulate a radio pick by index, e.g. sm_ta_radiosim 14");
    RegConsoleCmd("sm_ta_voices", Command_Voices, "Twelve Actors: list each client's voice pitch and gain");

    // DoD:S implements the radio menu with named client commands
    // (voice_attack, voice_hold, ...) rather than the HL2 "voicemenu <m> <i>"
    // pair; C/V/B only send voicemenu1/2/3 to open the menu client-side. Hook
    // both families and dedupe, so one press yields exactly one event.
    AddCommandListener(OnClientVoiceMenu, "voicemenu");
    for (int i = 0; i < sizeof(g_sVoiceCmds); i++) {
        AddCommandListener(OnClientVoice, g_sVoiceCmds[i]);
    }
    AddCommandListener(OnClientVoice, "+voicerecord");
    AddCommandListener(OnClientVoice, "-voicerecord");
    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);
    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);

    // Adopt the highest out.tsv seq at load time as well: a plugin reload does
    // not fire OnMapStart, and starting from 0 replays every historical bark.
    g_iLastOut = HighestOutSeq();

    StartTimers();
    EnsureDataDir();
    LoadVoices();
    LoadTranslations("common.phrases");
}

public void OnMapStart()
{
    // Never replay lines from before this map: adopt the highest seq on disk.
    g_iLastOut = HighestOutSeq();
    g_bClipsPrecached = false;
    CreateTimer(1.0, Timer_Precache);
    // A repeating timer does not survive a map change here, and a dead poll
    // timer means the daemon's barks are written but never played, so rebuild
    // both timers on every map start (killing any surviving copy first).
    StartTimers();
}

void StartTimers()
{
    // A TIMER_FLAG_NO_MAPCHANGE timer is closed by the engine at the map
    // change, but the variable still holds the dead handle value, so
    // KillTimer() on it throws "Invalid timer handle" and aborts this
    // function before the new timers exist. Check validity first.
    if (g_hPoll != null && IsValidHandle(g_hPoll)) { KillTimer(g_hPoll); }
    g_hPoll = null;
    if (g_hRoster != null && IsValidHandle(g_hRoster)) { KillTimer(g_hRoster); }
    g_hRoster = null;
    g_hPoll = CreateTimer(0.4, Timer_Poll, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    g_hRoster = CreateTimer(3.0, Timer_Roster, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

int HighestOutSeq()
{
    File f = OpenFile(g_sOutFile, "r");
    if (f == null) return 0;
    char line[MAX_LINE];
    int best = 0;
    while (!f.EndOfFile() && f.ReadLine(line, sizeof(line))) {
        int seq = StringToInt(line);
        if (seq > best) best = seq;
    }
    delete f;
    return best;
}

void EnsureDataDir()
{
    // CreateDirectory needs each level; data/ exists in every SourceMod install.
    BuildPath(Path_SM, g_sInFile, sizeof(g_sInFile), "data/twelveactors");
    if (!DirExists(g_sInFile)) {
        CreateDirectory(g_sInFile, 0755);
    }
    BuildPath(Path_SM, g_sInFile, sizeof(g_sInFile), "data/twelveactors/in.tsv");
    BuildPath(Path_SM, g_sOutFile, sizeof(g_sOutFile), "data/twelveactors/out.tsv");
}

public Action Timer_Precache(Handle timer)
{
    if (g_bClipsPrecached) return Plugin_Stop;
    File f = OpenFile(g_sClipsFile, "r");
    if (f == null) {
        LogMessage("[twelveactors] no clips.txt at %s — voice disabled", g_sClipsFile);
        return Plugin_Stop;
    }
    char line[PLATFORM_MAX_PATH];
    int n;
    while (!f.EndOfFile() && f.ReadLine(line, sizeof(line))) {
        TrimString(line);
        if (line[0] == '\0') continue;
        PrecacheSound(line, true);
        n++;
    }
    delete f;
    g_bClipsPrecached = true;
    LogMessage("[twelveactors] precached %d voice clips", n);
    return Plugin_Stop;
}

// The bot module is optional: if it is not loaded, the core still works with
// whatever fake clients exist (built-in bots on other engines, or none).
native bool TaBots_Available();
native int TaBots_Count();
native int TaBots_GetTarget();

bool BotsPresent()
{
    return GetFeatureStatus(FeatureType_Native, "TaBots_Available") == FeatureStatus_Available;
}

public Action Timer_Roster(Handle timer)
{
    // Watchdog: a repeating timer can die without OnMapStart firing in between
    // (a plugin reload only calls OnPluginStart), and a dead poll timer means
    // the daemon keeps writing barks that are never read or played. Rebuild it
    // here as well, so no single missed hook can silence playback for good.
    if (g_hPoll == null) {
        g_hPoll = CreateTimer(0.4, Timer_Poll, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
        if (g_cvDebug.BoolValue) LogMessage("[twelveactors] poll timer was gone, rebuilt by roster watchdog");
    }
    if (!g_cvEnable.BoolValue) return Plugin_Continue;
    File f = OpenFile(g_sRosterFile, "w");
    if (f == null) return Plugin_Continue;
    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i)) continue;
        char name[MAX_NAME_LENGTH];
        GetClientName(i, name, sizeof(name));
        for (int c = 0; name[c] != '\0'; c++) {
            if (name[c] == '\t' || name[c] == '\n' || name[c] == '\r') name[c] = ' ';
        }
        f.WriteLine("%s\t%d\t%d", name, GetClientTeam(i), IsFakeClient(i) ? 1 : 0);
    }
    delete f;
    return Plugin_Continue;
}

// ---------------------------------------------------------------- outbound

void Emit(const char[] fmt, any ...)
{
    if (!g_cvEnable.BoolValue) return;
    // Gate at the source, not at the daemon: with no human in game nothing
    // downstream needs to run. Bot deaths and round starts fire constantly on
    // an idle server, and each one would otherwise cost a daemon turn even
    // though the only listeners are bots.
    if (g_cvRequireHuman.BoolValue && CountHumans() == 0) {
        g_iGated++;
        return;
    }
    char line[MAX_LINE];
    VFormat(line, sizeof(line), fmt, 2);

    File f = OpenFile(g_sInFile, "a");
    if (f == null) {
        LogError("[twelveactors] cannot open %s for append", g_sInFile);
        return;
    }
    f.WriteLine("%s", line);
    delete f;
    if (g_cvDebug.BoolValue) LogMessage("[twelveactors] out: %s", line);
}

public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
    if (!g_cvEnable.BoolValue || client <= 0 || client > MaxClients) return Plugin_Continue;
    if (sArgs[0] == '\0' || sArgs[0] == '/' || sArgs[0] == '!') return Plugin_Continue;

    char name[MAX_NAME_LENGTH];
    char text[MAX_LINE];
    GetClientName(client, name, sizeof(name));
    Sanitize(sArgs, text, sizeof(text));

    g_iSeq++;
    Emit("%d\tsay\t%d\t%s\t%d\t%d\t%s", g_iSeq, GetClientUserId(client), name,
         GetClientTeam(client), IsFakeClient(client) ? 1 : 0, text);
    return Plugin_Continue;
}

// Quick-key radio (C / V / B): pressing the key sends voicemenu1/2/3 with no
// arguments (the client opens its own menu), and picking an item either sends
// "voicemenu <menu> <item>" or a named command such as voice_hold. Both paths
// land here; a 0.75s window per client keeps a single press to one event.
public Action OnClientVoiceMenu(int client, const char[] command, int argc)
{
    if (!g_cvEnable.BoolValue || client <= 0 || client > MaxClients) return Plugin_Continue;
    // RCBot2 bots press these same commands (voice_grenade, voice_backup) and
    // each press used to become a line in in.tsv. Nothing downstream wants a
    // bot's radio call: the daemon refuses it and the label file is for humans.
    if (IsFakeClient(client)) return Plugin_Continue;
    if (argc < 1) return Plugin_Continue;  // menu open, nothing chosen yet
    float now = GetGameTime();
    if (g_fLastVoice[client] > 0.0 && now - g_fLastVoice[client] < 0.75) return Plugin_Continue;

    char menu[16], item[16], name[MAX_NAME_LENGTH];
    GetCmdArg(1, menu, sizeof(menu));
    GetCmdArg(2, item, sizeof(item));
    if (menu[0] == '\0') menu[0] = '0';
    if (item[0] == '\0') item[0] = '0';
    GetClientName(client, name, sizeof(name));

    g_iSeq++;
    Emit("%d\tradio\t%d\t%s\t%d\t%s\t%s", g_iSeq, GetClientUserId(client), name,
         GetClientTeam(client), menu, item);
    g_fLastMenu[client] = now;
    return Plugin_Continue;
}

public Action OnClientVoice(int client, const char[] command, int argc)
{
    if (!g_cvEnable.BoolValue || client <= 0 || client > MaxClients) return Plugin_Continue;
    if (IsFakeClient(client)) return Plugin_Continue;  // bot callout, not a player order
    float now = GetGameTime();
    if (g_fLastMenu[client] > 0.0 && now - g_fLastMenu[client] < 0.75) return Plugin_Continue;

    char name[MAX_NAME_LENGTH];
    GetClientName(client, name, sizeof(name));
    g_iSeq++;
    Emit("%d\tvoice\t%d\t%s\t%d\t%s", g_iSeq, GetClientUserId(client), name,
         GetClientTeam(client), command);
    g_fLastVoice[client] = now;
    return Plugin_Continue;
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnable.BoolValue) return;
    int victim = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    char vname[MAX_NAME_LENGTH], aname[MAX_NAME_LENGTH], weapon[64];
    if (victim > 0) GetClientName(victim, vname, sizeof(vname));
    if (attacker > 0) GetClientName(attacker, aname, sizeof(aname));
    event.GetString("weapon", weapon, sizeof(weapon));

    g_iSeq++;
    Emit("%d\tdeath\t%d\t%s\t%d\t%s\t%s", g_iSeq, victim, vname,
         GetClientTeam(victim), aname, weapon);
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnable.BoolValue) return;
    g_iSeq++;
    char map[64];
    GetCurrentMap(map, sizeof(map));
    Emit("%d\tround\t0\t-\t0\t-\t%s", g_iSeq, map);
    if (g_cvDebug.BoolValue) {
        LogMessage("[twelveactors] round start, bot module=%s bots=%d target=%d",
            BotsPresent() ? "rcbot2" : "none", CountBots(),
            BotsPresent() ? TaBots_GetTarget() : 0);
    }
}

// ----------------------------------------------------------------- inbound

public Action Timer_Poll(Handle timer)
{
    if (!g_cvEnable.BoolValue) return Plugin_Continue;

    // Nobody to hear it: keep advancing the read cursor without printing or
    // playing. Draining instead of pausing means a line written just before
    // the last human left can never be replayed to whoever joins next.
    bool quiet = g_cvRequireHuman.BoolValue && CountHumans() == 0;

    File f = OpenFile(g_sOutFile, "r");
    if (f == null) return Plugin_Continue;

    char line[MAX_LINE];
    int processed;
    while (!f.EndOfFile() && processed < 24 && f.ReadLine(line, sizeof(line))) {
        TrimString(line);
        if (line[0] == '\0') continue;

        char parts[4][MAX_LINE];
        int n = ExplodeString(line, "\t", parts, sizeof(parts), sizeof(parts[]));
        if (n < 2) continue;
        int seq = StringToInt(parts[0]);
        if (seq <= g_iLastOut) continue;
        g_iLastOut = seq;
        processed++;
        if (quiet) continue;

        char speaker[MAX_NAME_LENGTH], clip[PLATFORM_MAX_PATH], text[MAX_LINE];
        strcopy(speaker, sizeof(speaker), parts[1]);
        strcopy(clip, sizeof(clip), n > 2 ? parts[2] : "");
        strcopy(text, sizeof(text), n > 3 ? parts[3] : "");

        if (text[0] != '\0') {
            // Say it as the bot, not as the server: say_team from the bot's
            // own client gives team chat, the bot's name, its team colour and
            // team-only visibility. White all-chat stays as the fallback for a
            // line whose speaker has since left (no client, no team to pick).
            int speakerId = FindSpeaker(speaker);
            char sayLine[MAX_LINE];
            SaySafe(text, sayLine, sizeof(sayLine));
            if (g_cvTeamChat.BoolValue && speakerId > 0 && GetClientTeam(speakerId) > 1) {
                FakeClientCommand(speakerId, "say_team %s", sayLine);
            } else {
                PrintToChatAll(" \x07%s\x01 :  %s", speaker, sayLine);
            }
        }
        if (g_cvSpeak.BoolValue && clip[0] != '\0') {
            PlayBark(speaker, clip);
        }
        if (g_cvDebug.BoolValue) LogMessage("[twelveactors] in: %d %s %s %s", seq, speaker, clip, text);
    }
    delete f;
    return Plugin_Continue;
}

void Sanitize(const char[] src, char[] dst, int maxlen)
{
    int j;
    for (int i = 0; src[i] != '\0' && j < maxlen - 1; i++) {
        char c = src[i];
        if (c == '\t' || c == '\r' || c == '\n') c = ' ';
        dst[j++] = c;
    }
    dst[j] = '\0';
}

// A generated line goes through the client command parser, where a quote ends
// the argument and ';' starts a new command. Strip both rather than trust the
// model's punctuation.
void SaySafe(const char[] src, char[] dst, int maxlen)
{
    int j;
    for (int i = 0; src[i] != '\0' && j < maxlen - 1; i++) {
        char c = src[i];
        if (c == '"' || c == ';' || c == '\r' || c == '\n' || c == '\t') c = ' ';
        dst[j++] = c;
    }
    dst[j] = '\0';
}

// The daemon writes the persona name, not a client index, because a bot can
// reconnect between the reply and the poll. Resolve it here every time.
int FindSpeaker(const char[] name)
{
    char cname[MAX_NAME_LENGTH];
    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i) || IsClientSourceTV(i)) continue;
        GetClientName(i, cname, sizeof(cname));
        if (StrEqual(cname, name, false)) return i;
    }
    return 0;
}

// ------------------------------------------------------------ voice shaping

// voices.tsv: "<persona>\t<pitch>\t<gain>" (gain optional, 0..1). Missing
// persona falls back to a pitch derived from the name, so the same cast keeps
// the same voices across restarts and maps with no file at all.
void LoadVoices()
{
    g_iTuned = 0;
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "data/twelveactors/voices.tsv");
    File f = OpenFile(path, "r");
    if (f == null) {
        LogMessage("[twelveactors] no voices.tsv — per-bot pitch derived from names");
        return;
    }
    char line[128];
    while (g_iTuned < MAX_TUNED && !f.EndOfFile() && f.ReadLine(line, sizeof(line))) {
        TrimString(line);
        if (line[0] == '\0' || line[0] == '#' || line[0] == ';') continue;
        char parts[3][64];
        int n = ExplodeString(line, "\t", parts, sizeof(parts), sizeof(parts[]));
        if (n < 2) continue;
        TrimString(parts[0]);
        if (parts[0][0] == '\0') continue;
        int pitch = StringToInt(parts[1]);
        if (pitch < 1 || pitch > 255) pitch = SNDPITCH_NORMAL;
        float gain = (n > 2) ? StringToFloat(parts[2]) : 1.0;
        if (gain < 0.0) gain = 0.0;
        if (gain > 1.0) gain = 1.0;
        strcopy(g_sTunedName[g_iTuned], MAX_NAME_LENGTH, parts[0]);
        g_iTunedPitch[g_iTuned] = pitch;
        g_fTunedGain[g_iTuned] = gain;
        g_iTuned++;
    }
    delete f;
    LogMessage("[twelveactors] voice tuning: %d persona(s) from voices.tsv", g_iTuned);
}

void PersonaVoice(const char[] name, int &pitch, float &gain)
{
    for (int i = 0; i < g_iTuned; i++) {
        if (StrEqual(g_sTunedName[i], name, false)) {
            pitch = g_iTunedPitch[i];
            gain = g_fTunedGain[i];
            return;
        }
    }
    // FNV-1a: deterministic, no file needed, and 90..110 is one or two
    // semitones either way -- enough to tell two soldiers apart, not enough to
    // sound like a cartoon. Same 92..112 band the curated table uses.
    int h = 2166136261;
    for (int i = 0; name[i] != '\0'; i++) {
        h ^= name[i];
        h *= 16777619;
    }
    pitch = 92 + ((h & 0x7FFFFFFF) % 21);
    gain = 1.0;
}

// A bark is emitted with the speaker's own pitch and gain. Distance attenuation
// is not core behaviour: if a playback module (ta_proximity) is loaded it
// handles the sound and returns handled; otherwise every listener hears the
// line at the same volume, the way the game's own radio barks work.
void PlayBark(const char[] speaker, const char[] clip)
{
    int pitch = SNDPITCH_NORMAL;
    float gain = 1.0;
    if (g_cvVoicePitch.BoolValue) PersonaVoice(speaker, pitch, gain);
    int speakerId = FindSpeaker(speaker);

    if (g_hVoiceForward != null) {
        Action res = Plugin_Continue;
        Call_StartForward(g_hVoiceForward);
        Call_PushCell(speakerId);
        Call_PushString(clip);
        Call_PushCell(pitch);
        Call_PushFloat(gain);
        Call_Finish(res);
        if (res != Plugin_Continue) {
            if (g_cvDebug.BoolValue) {
                LogMessage("[twelveactors] bark %s (pitch %d gain %.2f) played by module", speaker, pitch, gain);
            }
            return;
        }
    }

    EmitSoundToAll(clip, SOUND_FROM_PLAYER, SNDCHAN_AUTO, SNDLEVEL_NORMAL,
                   SND_NOFLAGS, gain, pitch);
    if (g_cvDebug.BoolValue) {
        LogMessage("[twelveactors] bark %s (pitch %d gain %.2f) played by core", speaker, pitch, gain);
    }
}

int CountBots()
{
    int n;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && IsFakeClient(i)) n++;
    }
    return n;
}

// Human = in game, not a bot, not SourceTV. Mirrors the daemon's roster gate:
// the two must agree or the plugin would keep posting events the daemon drops.
int CountHumans()
{
    int n;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && !IsFakeClient(i) && !IsClientSourceTV(i)) n++;
    }
    return n;
}

// ---------------------------------------------------------------- commands

public Action Command_Status(int client, int args)
{
    ReplyToCommand(client, "[twelveactors] enable=%d speak=%d team_chat=%d seq=%d last_out=%d clips_precached=%d humans=%d require_human=%d gated=%d",
        g_cvEnable.IntValue, g_cvSpeak.IntValue, g_cvTeamChat.IntValue, g_iSeq, g_iLastOut, g_bClipsPrecached ? 1 : 0,
        CountHumans(), g_cvRequireHuman.IntValue, g_iGated);
    ReplyToCommand(client, "[twelveactors] voice pitch=%d proximity_module=%s tuned=%d",
        g_cvVoicePitch.IntValue, FindConVar("sm_ta_proximity_enable") != null ? "loaded" : "absent", g_iTuned);
    return Plugin_Handled;
}

// Proof that each bot got its own voice, and a way to see what the cast
// actually sounds like without joining. Read-only, safe to run any time.
public Action Command_Voices(int client, int args)
{
    int n;
    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i) || IsClientSourceTV(i)) continue;
        char name[MAX_NAME_LENGTH];
        GetClientName(i, name, sizeof(name));
        int pitch = SNDPITCH_NORMAL;
        float gain = 1.0;
        PersonaVoice(name, pitch, gain);
        ReplyToCommand(client, "[twelveactors] %s  pitch=%d gain=%.2f  %s", name, pitch, gain,
            IsFakeClient(i) ? "bot" : "human");
        n++;
    }
    if (n == 0) ReplyToCommand(client, "[twelveactors] no clients in game");
    return Plugin_Handled;
}

public Action Command_Reload(int client, int args)
{
    g_bClipsPrecached = false;
    CreateTimer(0.1, Timer_Precache);
    LoadVoices();
    ReplyToCommand(client, "[twelveactors] re-reading clips.txt and voices.tsv");
    return Plugin_Handled;
}

public Action Command_Test(int client, int args)
{
    char act[32] = "ack";
    if (args >= 1) GetCmdArg(1, act, sizeof(act));
    char name[MAX_NAME_LENGTH] = "Twelve Actors";
    if (client > 0) GetClientName(client, name, sizeof(name));
    g_iSeq++;
    Emit("%d\ttest\t0\t%s\t1\t0\t%s", g_iSeq, name, act);
    ReplyToCommand(client, "[twelveactors] test act '%s' queued", act);
    return Plugin_Handled;
}

// The DoD:S client-side radio menu never reaches the server: ta_cmdspy saw
// zero voicemenu / voice_* events from a live player pressing C, V and B. So
// the client binds those keys to "sm_ta_radio <page>" instead and the choice
// is made in a server-side menu, whose menuselect does arrive.
char g_sRadioCmd[18][32] = {
    "voice_gogogo", "voice_hold", "voice_coverflanks", "voice_sticktogether",
    "voice_cover", "voice_fallback",
    "voice_yessir", "voice_negative", "voice_backup", "voice_fireinhole",
    "voice_grenade", "voice_sniper",
    "voice_enemybehind", "voice_moveupmg", "voice_needammo", "voice_usebazooka",
    "voice_displace", "voice_niceshot"
};
char g_sRadioText[18][64] = {
    "Go go go!", "Hold this position!", "Squad, flank them!", "Stick together!",
    "Covering fire!", "Fall back!",
    "Yes Sir!", "Negative!", "I need backup!", "Fire in the hole!",
    "Grenade, take cover!", "Sniper!",
    "Enemy behind us!", "We need an MG up here!", "I need ammo!", "Use the bazooka!",
    "Displace!", "Nice shot!"
};

public Action Command_Radio(int client, int args)
{
    if (client <= 0) {
        ReplyToCommand(client, "[twelveactors] sm_ta_radio only works in-game");
        return Plugin_Handled;
    }
    if (!g_cvEnable.BoolValue) return Plugin_Handled;

    int page = 0;
    if (args >= 1) {
        char a[8];
        GetCmdArg(1, a, sizeof(a));
        page = StringToInt(a);
    }
    if (page < 0 || page > 2) page = 0;

    Menu m = new Menu(MenuHandler_Radio);
    char title[64];
    Format(title, sizeof(title), "Radio %d/3", page + 1);
    m.SetTitle(title);
    for (int i = 0; i < 6; i++) {
        m.AddItem(g_sRadioCmd[page * 6 + i], g_sRadioText[page * 6 + i]);
    }
    m.ExitButton = true;
    m.Display(client, 20);
    return Plugin_Handled;
}

public int MenuHandler_Radio(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_Select) {
        if (client <= 0 || client > MaxClients || !IsClientInGame(client)) return 0;
        char cmd[32], text[64];
        menu.GetItem(item, cmd, sizeof(cmd), _, text, sizeof(text));
        // Deliberately identical to a typed chat line: the daemon's "say"
        // handler is the one path proven to produce a reply, so the radio
        // menu writes the same event rather than a separate voice event.
        EmitSay(client, text, true);
        if (g_cvDebug.BoolValue) LogMessage("[twelveactors] radio %s -> chat '%s'", cmd, text);
    } else if (action == MenuAction_End) {
        delete menu;
    }
    return 0;
}

// Emit a chat event for a client without needing the client to type anything.
// Shared by the radio menu and its console test. The trailing radio flag tells
// the daemon this was a deliberate order rather than idle chatter, so it always
// answers instead of rolling unprompted_chance.
void EmitSay(int client, const char[] text, bool radio = false)
{
    char name[MAX_NAME_LENGTH] = "Console", clean[MAX_LINE];
    int team = 2, uid = 0;
    if (client > 0 && client <= MaxClients) {
        GetClientName(client, name, sizeof(name));
        team = GetClientTeam(client);
        uid = GetClientUserId(client);
    }
    Sanitize(text, clean, sizeof(clean));
    g_iSeq++;
    Emit("%d\tsay\t%d\t%s\t%d\t0\t%s\t%d", g_iSeq, uid, name, team, clean, radio ? 1 : 0);
}

public Action Command_RadioSim(int client, int args)
{
    // Console-testable proof that a menu pick reaches the daemon: same EmitSay
    // the real menu uses, without needing a live player to press a key.
    int idx = -1;
    if (args >= 1) {
        char a[8];
        GetCmdArg(1, a, sizeof(a));
        idx = StringToInt(a);
    }
    if (idx < 0 || idx >= sizeof(g_sRadioText)) {
        ReplyToCommand(client, "[twelveactors] usage: sm_ta_radiosim <0..17>");
        return Plugin_Handled;
    }
    EmitSay(client, g_sRadioText[idx], true);
    ReplyToCommand(client, "[twelveactors] radiosim %d '%s' -> %s", idx, g_sRadioText[idx], g_sRadioCmd[idx]);
    return Plugin_Handled;
}

// ------------------------------------------------------------- key binding
// The DoD:S client's own radio menu never reaches the server, so the keys are
// pointed at the server-side menu. ClientCommand() makes the game run the bind
// in the player's console, so nothing has to be typed by hand.

public void OnClientPutInServer(int client)
{
    CreateTimer(5.0, Timer_AutoBind, GetClientUserId(client));
}

// Also bind anyone already connected when the plugin (re)loads, so a reload by
// itself is enough — no reconnect needed after installing an update.
public void OnConfigsExecuted()
{
    if (!g_cvAutoBind.BoolValue || !g_cvEnable.BoolValue) return;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && !IsFakeClient(i)) {
            CreateTimer(2.0, Timer_AutoBind, GetClientUserId(i));
        }
    }
}

// Parse sm_ta_radio_keys into up to three key names. A comma-separated value
// allows named keys ("MOUSE4,MOUSE5,b"); without a comma each character is one
// key, so "123" and "cvb" both behave as expected.
int ParseRadioKeys(char[][] keys, int maxKeys, int maxLen)
{
    char raw[64];
    g_cvRadioKeys.GetString(raw, sizeof(raw));
    TrimString(raw);
    if (raw[0] == '\0') return 0;

    if (StrContains(raw, ",") != -1) {
        int n = ExplodeString(raw, ",", keys, maxKeys, maxLen);
        int out;
        for (int i = 0; i < n; i++) {
            TrimString(keys[i]);
            if (keys[i][0] == '\0') continue;
            if (out != i) strcopy(keys[out], maxLen, keys[i]);
            out++;
        }
        return out;
    }

    int count;
    for (int i = 0; raw[i] != '\0' && count < maxKeys; i++) {
        if (raw[i] == ' ') continue;
        keys[count][0] = raw[i];
        keys[count][1] = '\0';
        count++;
    }
    return count;
}

public Action Timer_AutoBind(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client)) return Plugin_Stop;
    if (!g_cvAutoBind.BoolValue || !g_cvEnable.BoolValue) return Plugin_Stop;

    char keys[3][32];
    int n = ParseRadioKeys(keys, sizeof(keys), 32);
    if (n == 0) return Plugin_Stop;   // sm_ta_radio_keys empty: bind nothing

    static const char sLabels[][] = { "orders", "replies", "tactical" };
    char cmd[80], summary[160];
    for (int i = 0; i < n; i++) {
        Format(cmd, sizeof(cmd), "bind %s \"sm_ta_radio %d\"", keys[i], i);
        ClientCommand(client, cmd);
        Format(summary, sizeof(summary), "%s%s%s %s",
            summary, i ? ", " : "", keys[i], sLabels[i]);
    }
    PrintToChat(client, "[twelveactors] radio keys bound: %s. Choose 1-6.", summary);
    PrintToChat(client, "[twelveactors] not what you wanted? your server can set sm_ta_autobind 0.");
    if (g_cvDebug.BoolValue) LogMessage("[twelveactors] auto-bound %s for %L", summary, client);
    return Plugin_Stop;
}

public Action Command_Say(int client, int args)
{
    if (args < 1) {
        ReplyToCommand(client, "usage: sm_ta_say <text>");
        return Plugin_Handled;
    }
    char text[MAX_LINE];
    GetCmdArgString(text, sizeof(text));
    Sanitize(text, text, sizeof(text));
    char name[MAX_NAME_LENGTH] = "Console";
    int team = 2;
    if (client > 0) {
        GetClientName(client, name, sizeof(name));
        team = GetClientTeam(client);
    }
    g_iSeq++;
    Emit("%d\tsay\t%d\t%s\t%d\t0\t%s", g_iSeq, client > 0 ? GetClientUserId(client) : 0,
         name, team, text);
    ReplyToCommand(client, "[twelveactors] sent");
    return Plugin_Handled;
}
