// SPDX-FileCopyrightText: 2026 Twelve Actors contributors
// SPDX-License-Identifier: MPL-2.0 OR GPL-3.0-or-later
//
// Dual-offered because this plugin is compiled against SourceMod (GPL-3.0) via
// #include <sourcemod>, so the compiled .smx is a combination rather than a
// merely-loaded file. MPL-2.0 §3.3 permits distributing such a Larger Work
// under a Secondary License; this file carries no "Incompatible With Secondary
// Licenses" notice, so that route is open. The file itself remains MPL-2.0 for
// anyone who wants it on those terms.
// Temporary diagnostic: log every client command in the voice/chat family so we
// can see exactly what the DoD:S client sends when a player uses the radio menu,
// the microphone key, or chat.
#pragma semicolon 1
#include <sourcemod>

#define LOGFILE "data/twelveactors/cmdspy.tsv"

public Plugin myinfo = {
    name = "Twelve Actors CmdSpy",
    author = "Twelve Actors",
    description = "Logs radio/voice/chat client commands for diagnosis",
    version = "0.0.1",
    url = ""
};

public void OnPluginStart()
{
    char cmds[][] = {
        "voicemenu", "voicemenu1", "voicemenu2", "voicemenu3", "voicemenu4",
        "radio", "radio1", "radio2", "radio3", "vmenu", "voice",
        "voice_menu", "cmdmenu", "menuselect",
        "say", "say_team", "say_team_dod"
    };
    for (int i = 0; i < sizeof(cmds); i++) {
        AddCommandListener(OnAny, cmds[i]);
    }
    LogMessage("[cmdspy] armed, watching %d commands", view_as<int>(sizeof(cmds)));
}

public Action OnAny(int client, const char[] command, int argc)
{
    char name[MAX_NAME_LENGTH] = "Console";
    char args[256];
    GetCmdArgString(args, sizeof(args));
    if (client > 0 && client <= MaxClients && IsClientInGame(client))
        GetClientName(client, name, sizeof(name));

    char stamp[32];
    FormatTime(stamp, sizeof(stamp), "%H:%M:%S");

    File f = OpenFile(LOGFILE, "a");
    if (f != null) {
        f.WriteLine("%s\t%d\t%s\t%s\t%d\t%s", stamp, client, name, command, argc, args);
        delete f;
    }
    LogMessage("[cmdspy] %s client=%d(%s) argc=%d args=\"%s\"", command, client, name, argc, args);
    return Plugin_Continue;
}
