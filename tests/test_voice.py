#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
"""Per-bot voice is core behaviour; distance falloff is an optional module.

The split is the point of these checks. A future edit that drops proximity math
back into twelveactors.sp makes every bark positional for everyone with no way to
turn it off, and an edit that removes the forward silently strands the module:
no error, the barks just keep playing flat. Neither shows up in a compile, so
they are pinned here.

Compilation is checked too when spcomp is reachable (SM_SCRIPTING, or the usual
/srv/dods location); a machine without the game server skips that part.
"""

import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
CORE = ROOT / "plugin" / "twelveactors.sp"
MODULE = ROOT / "plugin" / "ta_proximity.sp"
INSTALL = ROOT / "install.sh"
VOICE_INSTALL = ROOT / "install-voice.sh"
DIST = ROOT / "make-dist.sh"
VOICES = ROOT / "config" / "voices.example.tsv"


def text(p):
    return p.read_text(encoding="utf-8")


def main():
    results = []

    def check(name, ok, detail=""):
        results.append((name, ok, detail))

    core = text(CORE) if CORE.exists() else ""
    mod = text(MODULE) if MODULE.exists() else ""

    check("module exists", bool(mod), str(MODULE))
    check("core creates the Ta_OnBotVoice forward",
          'CreateGlobalForward("Ta_OnBotVoice", ET_Hook' in core)
    check("core pushes speaker, clip, pitch and gain",
          all(s in core for s in ("Call_PushCell(speakerId)", "Call_PushString(clip)",
                                  "Call_PushCell(pitch)", "Call_PushFloat(gain)")))
    check("core honours a module's handled result",
          "if (res != Plugin_Continue)" in core)
    check("core still has a flat fallback when nothing handles the bark",
          "EmitSoundToAll(clip, SOUND_FROM_PLAYER" in core)
    check("core carries no distance/volume math",
          "GetVectorDistance" not in core and "Falloff(" not in core,
          "proximity belongs in the module")
    check("core exposes per-bot pitch as a cvar",
          'CreateConVar("sm_ta_voice_pitch"' in core)
    check("core lists assigned voices for verification",
          "sm_ta_voices" in core)

    sig = re.search(r"public\s+Action\s+Ta_OnBotVoice\s*\(([^)]*)\)", mod)
    params = [p.strip() for p in sig.group(1).split(",")] if sig else []
    check("module implements the forward with the core's argument types",
          len(params) == 4
          and params[0].startswith("int")
          and "char[]" in params[1]
          and params[2].startswith("int")
          and params[3].startswith("float"),
          ", ".join(params))
    check("module claims the bark so core stays silent",
          "return Plugin_Handled;" in mod)
    check("module hands a departed speaker back to core",
          "return Plugin_Continue;" in mod)
    check("module emits per listener",
          "EmitSoundToClient(i, clip" in mod)
    check("module's engine level does not double-attenuate",
          "SNDLEVEL_NONE" in mod)
    check("module has its own dials",
          all(f'CreateConVar("sm_ta_proximity_{n}"' in mod
              for n in ("enable", "near", "far", "minvol", "team_only")))
    # Audience is a default, not a detail: proximity without this would silently
    # halve who hears a callout the moment the module is loaded.
    check("module lets every player hear barks by default",
          'CreateConVar("sm_ta_proximity_team_only", "0"' in mod,
          "team_only must default to 0")
    check("module still offers the team-only restriction",
          "!g_cvTeamOnly.BoolValue" in mod and "sv_alltalk" in mod)

    inst = text(INSTALL) if INSTALL.exists() else ""
    check("installer compiles the module",
          "ta_proximity" in inst and "for f in" in inst)
    check("installer does not enable it by default",
          'if [ -f "$SM/plugins/ta_proximity.smx" ]' in inst
          and '"$SM/plugins/disabled/"' in inst)

    vi = text(VOICE_INSTALL) if VOICE_INSTALL.exists() else ""
    check("voice installer exists and can toggle the module",
          "--with-proximity" in vi and "--without-proximity" in vi)
    check("voice installer can restore team-only audio",
          "--team-only" in vi)
    check("voice installer migrates an old team_only cfg",
          "sm_ta_proximity_team_only" in vi and "sed -i" in vi)

    dist = text(DIST) if DIST.exists() else ""
    check("distributable ships the curated pitch file",
          "voices.example.tsv" in dist)
    check("distributable ships the voice installer",
          "install-voice.sh" in dist)

    if VOICES.exists():
        rows = []
        for line in text(VOICES).splitlines():
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) >= 2:
                rows.append((parts[0], int(parts[1])))
        pitches = [p for _, p in rows]
        check("curated pitches are distinct",
              len(pitches) == len(set(pitches)), f"{len(pitches)} personas")
        check("curated pitches stay inside the documented band",
              all(92 <= p <= 112 for p in pitches),
              f"{min(pitches)}..{max(pitches)}" if pitches else "empty")

    sm = os.environ.get("SM_SCRIPTING") or "/srv/dods/dod/addons/sourcemod/scripting"
    spcomp = pathlib.Path(sm) / "spcomp"
    include = pathlib.Path(sm) / "include"
    if spcomp.is_file() and os.access(spcomp, os.X_OK):
        for name in ("twelveactors", "ta_proximity"):
            out = ROOT / "build"
            out.mkdir(exist_ok=True)
            p = subprocess.run(
                [str(spcomp), f"-i{include}", "-o", str(out / f"{name}.smx"),
                 str(ROOT / "plugin" / f"{name}.sp")],
                capture_output=True, text=True,
            )
            warns = [l for l in (p.stdout + p.stderr).splitlines()
                     if "warning" in l.lower() or "error" in l.lower()]
            check(f"{name}.sp compiles without warnings",
                  p.returncode == 0 and not warns,
                  "; ".join(warns[:3]))
    else:
        print(f"skip: no spcomp at {spcomp}")

    # The live cfg an older install wrote has team_only "1" in it and SourceMod
    # never rewrites an existing cfg, so the installer's sed is the only thing
    # that flips an upgraded server to "everyone hears barks". Run the line the
    # installer actually carries, through bash, against a real cfg fragment --
    # a sed that silently misses leaves the running box team-only.
    sed_lines = [l.strip() for l in vi.splitlines()
                 if l.strip().startswith("sed -i -E")
                 and "sm_ta_proximity_team_only" in l]
    check("voice installer migrates the old team_only cfg",
          len(sed_lines) == 1, f"{len(sed_lines)} sed line(s)")
    samples = [
        ('sm_ta_proximity_team_only "1"', 'sm_ta_proximity_team_only "0"'),
        ('sm_ta_proximity_team_only 1', 'sm_ta_proximity_team_only "0"'),
        ('sm_ta_proximity_team_only "0"', 'sm_ta_proximity_team_only "0"'),
        ('sm_ta_proximity_far "1200"', 'sm_ta_proximity_far "1200"'),
    ]
    missed = []
    if len(sed_lines) == 1:
        cmd = sed_lines[0].replace('"$CFG"', '"$1"')
        import tempfile
        for before, want in samples:
            with tempfile.NamedTemporaryFile("w", suffix=".cfg", delete=False) as fh:
                fh.write(before + "\n")
                path = fh.name
            subprocess.run(["bash", "-c", f"WANT=0; {cmd}", "_", path],
                           capture_output=True, text=True)
            got = pathlib.Path(path).read_text().strip()
            pathlib.Path(path).unlink(missing_ok=True)
            if got != want:
                missed.append(f"{before!r} -> {got!r} (want {want!r})")
    check("cfg migration handles quoted, bare and unrelated lines",
          not missed, "; ".join(missed))

    bad = [r for r in results if not r[1]]
    for name, ok, detail in results:
        print(f"{'ok  ' if ok else 'FAIL'}  {name}" + (f"  ({detail})" if detail and not ok else ""))
    print(f"\n{len(results) - len(bad)}/{len(results)} voice-module checks pass")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
