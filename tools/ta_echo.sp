// SPDX-FileCopyrightText: 2026 Twelve Actors contributors
// SPDX-License-Identifier: MPL-2.0
// Diagnostic: report back to the player (in chat) every command the server
// actually receives from the voice/radio/mic family, so a press can be
// confirmed or ruled out immediately. Safe to remove at any time.
#pragma semicolon 1
#include <sourcemod>

#define LOGFILE "data/twelveactors/ta_echo.tsv"

public Plugin myinfo = {
    name = "Twelve Actors Echo",
    author = "Twelve Actors",
    description = "Echoes radio/voice client commands back in chat",
    version = "0.0.2",
    url = ""
};

// Commands the player-facing radio / mic path could plausibly use.
char g_menu[][ ] = {
    "voicemenu", "voicemenu1", "voicemenu2", "voicemenu3", "voicemenu4",
    "menuselect",
    "voice_menu", "voice_menu_1", "voice_menu_2", "voice_menu_3",
    "cmd1", "cmd2", "cmd3",
    "radio1", "radio2", "radio3"
};

// Mic key: server sees the key press, never the audio.
char g_mic[][ ] = { "+voicerecord", "-voicerecord" };

// Chat: logged silently so it does not spam the chat log twice.
char g_chat[][ ] = { "say", "say_team" };

bool g_bFirst[MAXPLAYERS + 1];

public void OnPluginStart()
{
    for (int i = 0; i < sizeof(g_menu); i++)
        AddCommandListener(OnMenu, g_menu[i]);
    for (int i = 0; i < sizeof(g_mic); i++)
        AddCommandListener(OnMic, g_mic[i]);
    for (int i = 0; i < sizeof(g_chat); i++)
        AddCommandListener(OnChat, g_chat[i]);

    RegConsoleCmd("sm_ta_echo", Command_Echo, "Twelve Actors: prove the server hears your console");
    LogMessage("[echo] armed, %d menu + %d mic + %d chat commands",
        view_as<int>(sizeof(g_menu)), view_as<int>(sizeof(g_mic)), view_as<int>(sizeof(g_chat)));
}

public void OnClientPutInServer(int client)
{
    g_bFirst[client] = true;
}

void Record(const char[] what, int client, const char[] command, const char[] args)
{
    char name[MAX_NAME_LENGTH] = "console";
    if (client > 0 && client <= MaxClients && IsClientInGame(client))
        GetClientName(client, name, sizeof(name));

    char stamp[32];
    FormatTime(stamp, sizeof(stamp), "%H:%M:%S");
    LogToFile(LOGFILE, "%s\t%d\t%s\t%s\t%s\t%s", stamp, client, name, what, command, args);
}

public Action OnMenu(int client, const char[] command, int argc)
{
    char args[256];
    GetCmdArgString(args, sizeof(args));
    Record("menu", client, command, args);
    if (client > 0 && client <= MaxClients && IsClientInGame(client))
        PrintToChat(client, "[TA] heard %s (args: %s)", command, args);
    return Plugin_Continue;
}

public Action OnMic(int client, const char[] command, int argc)
{
    Record("mic", client, command, "");
    if (client > 0 && client <= MaxClients && IsClientInGame(client))
        PrintToChat(client, "[TA] heard %s - the key registers, but voice audio never reaches the server", command);
    return Plugin_Continue;
}

public Action OnChat(int client, const char[] command, int argc)
{
    char args[256];
    GetCmdArgString(args, sizeof(args));
    Record("chat", client, command, args);
    return Plugin_Continue;
}

public Action Command_Echo(int client, int argc)
{
    Record("manual", client, "sm_ta_echo", "");
    if (client > 0 && client <= MaxClients && IsClientInGame(client))
        PrintToChat(client, "[TA] echo ok - server sees your commands");
    return Plugin_Handled;
}
