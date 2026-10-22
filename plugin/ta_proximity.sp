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
 * ta_proximity.sp — optional distance falloff for Twelve Actors bot voice.
 *
 * The core plugin (twelveactors.smx) plays every bark to everyone at the same
 * volume. That is the right default: DoD:S barks are radio-like callouts and
 * the server may have players in a spec slot or on a different objective. This
 * module is the opt-in half of that story: with it loaded, a bark is measured
 * against every human in game and each one hears it at the volume of its own
 * distance from the bot — but the audience stays the same, everyone.
 *
 * Optional by design:
 *   - file absent              -> nothing changes, core plays flat
 *   - file in plugins/disabled -> installed but not running
 *   - file in plugins/         -> proximity is live (sm_ta_proximity_enable)
 *
 * Wiring: the core calls the global forward
 *     Ta_OnBotVoice(speakerId, clip, pitch, gain)
 * and every plugin that defines a public function of that name receives it.
 * Returning Plugin_Handled tells the core the bark has been played, so the two
 * never emit the same line twice.
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "0.1.0"

ConVar g_cvEnable;
ConVar g_cvNear;
ConVar g_cvFar;
ConVar g_cvMinVol;
ConVar g_cvTeamOnly;
ConVar g_cvDebug;

// Last bark, so a console check can prove the curve ran without being in game.
int g_iLastHeard;
float g_fLastNearest;
float g_fLastFarthest;

public Plugin myinfo = {
    name = "Twelve Actors Proximity Voice",
    author = "Twelve Actors",
    description = "Distance-based volume for Twelve Actors bot voice (optional module)",
    version = PLUGIN_VERSION,
    url = ""
};

public void OnPluginStart()
{
    g_cvEnable = CreateConVar("sm_ta_proximity_enable", "1",
        "Scale bot bark volume by distance to each listener", FCVAR_NOTIFY);
    // 150 units is roughly arm's length to the next trench; 1200 is the next
    // street over on the stock maps. Beyond far, the bark is simply not sent.
    g_cvNear = CreateConVar("sm_ta_proximity_near", "150",
        "Distance (units) inside which a bark plays at full volume", _, true, 0.0);
    g_cvFar = CreateConVar("sm_ta_proximity_far", "1200",
        "Distance (units) at which a bark fades to sm_ta_proximity_minvol", _, true, 1.0);
    g_cvMinVol = CreateConVar("sm_ta_proximity_minvol", "0.0",
        "Volume at the far edge (0 = silent beyond far, 1 = no falloff at all)", _, true, 0.0, true, 1.0);
    // Everyone hears every bark by default: the volume already carries the
    // distance cue, and a callout that reaches only half the map is a worse
    // experience than one whose direction is audible. Operators who want the
    // old team-only behaviour set sm_ta_proximity_team_only 1; sv_alltalk 1
    // forces everyone regardless.
    g_cvTeamOnly = CreateConVar("sm_ta_proximity_team_only", "0",
        "Restrict a bark's audio to the speaker's own team (0 = everyone hears it; sv_alltalk 1 forces everyone)", FCVAR_NOTIFY);
    g_cvDebug = CreateConVar("sm_ta_proximity_debug", "0",
        "Log each listener's distance and volume");

    RegConsoleCmd("sm_ta_prox", Command_Status, "Twelve Actors proximity: settings and last bark");
    AutoExecConfig(true, "ta_proximity");

    LogMessage("[ta_prox] loaded: near=%.0f far=%.0f minvol=%.2f team_only=%d",
        g_cvNear.FloatValue, g_cvFar.FloatValue, g_cvMinVol.FloatValue, g_cvTeamOnly.IntValue);
}

// ---------------------------------------------------------------- the hook

public Action Ta_OnBotVoice(int speakerId, const char[] clip, int pitch, float gain)
{
    if (!g_cvEnable.BoolValue) return Plugin_Continue;   // core's flat playback
    if (clip[0] == '\0') return Plugin_Handled;          // nothing to play
    // The persona has left the server between the daemon writing the line and
    // the poll reading it: there is no position to measure, so let the core
    // fall back to its flat broadcast rather than swallow the bark.
    if (speakerId <= 0 || !IsClientInGame(speakerId)) return Plugin_Continue;

    float src[3];
    if (!GetClientAbsOrigin(speakerId, src)) return Plugin_Continue;

    float fNear = g_cvNear.FloatValue;
    float fFar = g_cvFar.FloatValue;
    float fMin = g_cvMinVol.FloatValue;
    if (fFar <= fNear + 1.0) fFar = fNear + 1.0;
    if (fMin > 1.0) fMin = 1.0;
    if (gain <= 0.0) gain = 1.0;

    int botTeam = GetClientTeam(speakerId);
    ConVar alltalk = FindConVar("sv_alltalk");
    bool everyone = !g_cvTeamOnly.BoolValue || (alltalk != null && alltalk.BoolValue);

    int heard;
    float nearest = -1.0;
    float farthest = -1.0;

    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i) || IsFakeClient(i) || IsClientSourceTV(i)) continue;
        int team = GetClientTeam(i);
        // Team 1 is spectator/unassigned: a spectator hears every bark, which
        // is also what makes the module observable from a spec slot.
        if (!everyone && team > 1 && team != botTeam) continue;

        float dst[3];
        if (!GetClientAbsOrigin(i, dst)) continue;
        float dist = GetVectorDistance(src, dst);
        float v = Falloff(dist, fNear, fFar, fMin) * gain;
        if (v <= 0.01) continue;
        if (v > 1.0) v = 1.0;

        // Level NONE keeps the engine's own attenuation out of the mix: the
        // volume computed here is already the distance curve, and stacking a
        // second engine curve on top would make mid-range barks inaudible.
        // The origin still spatialises the sound, so the listener gets stereo
        // direction along with the volume.
        EmitSoundToClient(i, clip, speakerId, SNDCHAN_AUTO, SNDLEVEL_NONE, SND_NOFLAGS,
                          v, pitch, -1, src, NULL_VECTOR, false);
        heard++;
        if (nearest < 0.0 || dist < nearest) nearest = dist;
        if (dist > farthest) farthest = dist;
        if (g_cvDebug.BoolValue) {
            LogMessage("[ta_prox] %N hears '%s' at %.0f units, volume %.2f",
                i, clip, dist, v);
        }
    }

    g_iLastHeard = heard;
    g_fLastNearest = nearest;
    g_fLastFarthest = farthest;
    if (g_cvDebug.BoolValue) {
        LogMessage("[ta_prox] bark '%s' pitch %d: %d listener(s), %.0f-%.0f units",
            clip, pitch, heard, nearest, farthest);
    }
    return Plugin_Handled;
}

// Linear in amplitude: 1.0 inside near, minvol at far and beyond.
float Falloff(float dist, float fNear, float fFar, float fMin)
{
    if (dist <= fNear) return 1.0;
    if (dist >= fFar) return fMin;
    float t = (dist - fNear) / (fFar - fNear);
    return 1.0 - t * (1.0 - fMin);
}

// ---------------------------------------------------------------- commands

public Action Command_Status(int client, int args)
{
    ReplyToCommand(client, "[ta_prox] enable=%d near=%.0f far=%.0f minvol=%.2f team_only=%d debug=%d",
        g_cvEnable.IntValue, g_cvNear.FloatValue, g_cvFar.FloatValue,
        g_cvMinVol.FloatValue, g_cvTeamOnly.IntValue, g_cvDebug.IntValue);
    ConVar alltalk = FindConVar("sv_alltalk");
    bool everyone = !g_cvTeamOnly.BoolValue || (alltalk != null && alltalk.BoolValue);
    ReplyToCommand(client, "[ta_prox] audience: %s (attenuated by distance either way)",
        everyone ? "everyone in game" : "speaker's own team");
    if (g_iLastHeard > 0) {
        ReplyToCommand(client, "[ta_prox] last bark: %d listener(s), %.0f-%.0f units",
            g_iLastHeard, g_fLastNearest, g_fLastFarthest);
    } else {
        ReplyToCommand(client, "[ta_prox] no bark played since load");
    }
    // RCBot2 plays its own stock radio voices straight from the engine, so they
    // never reach this module and stay at full volume at any distance. Say so
    // here rather than let it look like the falloff is broken.
    ConVar vc = FindConVar("rcbot_voice_cmds");
    if (vc != null && vc.BoolValue) {
        ReplyToCommand(client, "[ta_prox] note: rcbot_voice_cmds=1 -- RCBot2's own radio voices bypass proximity (set 0 to hear only Twelve Actors barks)");
    }
    return Plugin_Handled;
}
