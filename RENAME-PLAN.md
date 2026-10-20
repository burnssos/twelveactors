<!--
SPDX-FileCopyrightText: 2026 Twelve Actors contributors
SPDX-License-Identifier: MPL-2.0
-->

# Rename plan: bivouac → twelveactors

Target name: **twelveactors** (lowercase, importable), display **Twelve Actors**,
plugin/cvar prefix **ta_**.

Status: **executed in the source tree on 2026-10-20** — the tree in this commit
is already renamed; `git log` shows two commits, the first a pre-rename
snapshot, so `git diff HEAD~1` is the rename itself. The numbers below were
counted against the pre-rename tree and are kept as the record of what moved.
The live migration (§9, `install-rename.sh`) has **not** been run: `/srv` and
`/opt` still carry the old names until someone runs that script with sudo.

---

## 0. Why the ordering matters

Five layers carry the name and they fail differently:

| Layer | What breaks if done alone |
|---|---|
| Text | nothing — cosmetic until paths move |
| Paths | imports, unit, installers all break at once |
| Deployment | daemon starts on an empty data dir, silently |
| cvars / env | live cfg files stop applying, silently |
| plugin prefix | cross-plugin natives fail, silently |

The last three fail **without an error line**. That is why this plan
sequences them and why every layer gets a verification gate rather than a
"looks right".

---

## 1. Verified inventory

### Tree (git: 126 tracked files, 4.5 MB, zero commits, no remote)

| Item | Count |
|---|---|
| Files containing `bivouac` (case-insensitive) | 98 |
| Total occurrences | 1064 |
| — lowercase `bivouac` | 823 |
| — `Bivouac` | 184 |
| — `BIVOUAC` | 57 |
| Files containing `bivouac` **or** `biv_` | 69 |
| `biv_` occurrences | 370 |
| — of which `sm_biv_` | 186 |
| — of which `sm_bivouac_` | 45 |
| Distinct cvars (`sm_biv_*` + `sm_bivouac_*`) | 29 |
| Distinct console commands (`sm_biv*`) | 11 |
| Env vars (`BIVOUAC_*`, 5 names) | 36 |
| `bivouac_bots_rcbot2` module refs | 49 |
| `/opt/bivouac` | 86 |
| `data/bivouac` | 79 |
| `/home/admin1/bivouac` (20 files) | 41 |
| Name-bearing tracked paths | 21 |
| `.sp` sources | 13 (5 `build/`, 7 `plugin/`, 1 `tools/`) |
| `.smx` binaries | 8 |
| `Plugin myinfo` display names | 6 |
| `.rcw` waypoints | 26 (9 `waypoints-final`, 9 `-improved`, 8 `-v2`) — **unaffected** |

Baseline: all 7 test files pass when run directly (`python3 tests/test_X.py`);
pytest is not installed in this environment, so no pytest run.

### Live server

| Item | State |
|---|---|
| `/opt/bivouac` | present: `/opt/bivouac/bivouac` is the package, and six `bivouac.bak.*` package copies are nested inside it (not beside it) |
| `bivouac.service` | enabled, `ExecStart=/usr/bin/python3 -m bivouac` |
| Data dir | 19 files, incl. `state.sqlite` (1.1 MB) + `state.sqlite-wal` (**4.1 MB**, un-checkpointed) + `clips.sqlite` |
| Ours in `plugins/` | `bivouac.smx`, `bivouac_bots_rcbot2.smx`, `biv_botjoin.smx`, `biv_humancap.smx`, `biv_proximity.smx`, `biv_cmdspy.smx`, `dods_spawnwatch.smx` (stays) |
| `.bak` in `plugins/` | 13 × `*.smx.bak.<stamp>` — **ignored by SourceMod**, extension is not `.smx` |
| Ours in `scripting/` | `bivouac.sp`, `bivouac_bots_rcbot2.sp`, `biv_proximity.sp` |
| Cfgs | `biv_humancap.cfg` (`sm_biv_humancap 12`), `biv_proximity.cfg` (6 cvars), 3 `.bak` |
| Warmode | `sm_warmode_on.cfg` loads `bivouac_bots_rcbot2.smx` + `bivouac.smx` **by filename** |

---

## 2. Canonical mapping

| Layer | From | To |
|---|---|---|
| Package / module | `bivouac` | `twelveactors` |
| Display / prose | `Bivouac` | `Twelve Actors` |
| Docs + env prefix | `BIVOUAC` | `TWELVEACTORS` |
| Plugin files | `bivouac.sp` / `bivouac.smx` | `twelveactors.sp` / `twelveactors.smx` |
| Module | `bivouac_bots_rcbot2` | `ta_bots_rcbot2` |
| Other plugins | `biv_<x>` | `ta_<x>` |
| Core cvars | `sm_bivouac_<x>` | `sm_ta_<x>` |
| Plugin cvars / cmds | `sm_biv_<x>` | `sm_ta_<x>` |
| Cross-plugin natives | `BivBots_*` | `TaBots_*` |
| Install dir | `/opt/bivouac` | `/opt/twelveactors` |
| Data dir | `data/bivouac` | `data/twelveactors` |
| Unit | `bivouac.service` | `twelveactors.service` |
| Archives | `bivouac-1.0.0.*` | `twelveactors-1.0.0.*` |

The OS user stays `dod`; port stays 8377; data **filenames** inside the dir
stay (`in.tsv`, `out.tsv`, `state.sqlite`, `clips.sqlite`, `voices.tsv`,
`personas.json`, `roster.tsv`, `voiced.txt`, `config.json`, `radio_map.json`).

### 29 cvars

Core (7): `enable`, `debug`, `speak`, `require_human`, `team_chat`,
`voice_pitch`, `autobind` — `sm_bivouac_<x>` → `sm_ta_<x>`.

Plugins (22): `status`, `bots`, `bots_enable`, `bots_target`, `bots_reload`,
`voices`, `radio`, `radiosim`, `prox`, `reload`, `say`, `test`, `humancap`,
`botjoin_enable`, `botjoin_debug`, `botjoin_mode`, `proximity_enable`,
`proximity_near`, `proximity_far`, `proximity_minvol`, `proximity_team_only`,
`proximity_debug` — `sm_biv_<x>` → `sm_ta_<x>`.

`sm_bivouac_team_route` is **not** in the source; it survives only inside
`revert-team-routing.sh`. It is not migrated (no-op either way).

Collision check on the flattened `sm_ta_` namespace: **none**. `sm_ta_enable`
(core) and `sm_ta_bots_enable` stay distinct.

### 5 env vars

`BIVOUAC_API_BASE` → `TWELVEACTORS_API_BASE`;
`BIVOUAC_API_KEY` → `TWELVEACTORS_API_KEY`;
`BIVOUAC_MODEL` → `TWELVEACTORS_MODEL`;
`BIVOUAC_DATA` → `TWELVEACTORS_DATA`;
`BIVOUAC_RESOURCE` → `TWELVEACTORS_RESOURCE`.

Installers keep accepting the old names for one release, warning on stderr, so
an existing install command does not silently drop a key.

### 21 paths

```
BIVOUAC-HANDOFF.md                    → TWELVEACTORS-HANDOFF.md
BIVOUAC-WORK-PERFORMED.md             → TWELVEACTORS-WORK-PERFORMED.md
bivouac/ (13 files)                   → twelveactors/
build/bivouac.sp                      → build/twelveactors.sp
build/bivouac.smx                     → build/twelveactors.smx    (rebuilt)
build/bivouac_bots_rcbot2.sp          → build/ta_bots_rcbot2.sp
build/bivouac_bots_rcbot2.smx         → build/ta_bots_rcbot2.smx (rebuilt)
plugin/bivouac.sp                     → plugin/twelveactors.sp
plugin/bivouac.smx                    → plugin/twelveactors.smx   (rebuilt)
plugin/bivouac_bots_rcbot2.sp         → plugin/ta_bots_rcbot2.sp
systemd/bivouac.service               → systemd/twelveactors.service
```

Plus, by the `biv_` rule: `plugin/biv_botjoin.sp` → `ta_botjoin.sp`,
`biv_botjoin_experimental.sp` → `ta_botjoin_experimental.sp`,
`biv_humancap.sp` → `ta_humancap.sp`, `biv_proximity.sp` → `ta_proximity.sp`,
`biv_cmdspy.sp` → `ta_cmdspy.sp`, all matching `build/` and `.smx` names, and
`tools/install-biv-echo.sh` → `tools/install-ta-echo.sh`.

Plugin display names after the pass: `Twelve Actors Core`,
`Twelve Actors Bots (RCBot2)`, `Twelve Actors Bot Join Fix`,
`Twelve Actors Human Cap`, `Twelve Actors Proximity Voice`,
`Twelve Actors CmdSpy`.

---

## 3. Layer 0 — safety net (do first)

Git has **zero commits**, so `git checkout` cannot undo a bad rename. Two
options; take both:

1. `tar czf ~/twelveactors-pre-rename-$(date +%Y%m%d-%H%M).tar.gz -C ~ bivouac`
2. Make the initial commit **before** the rename, so the rename lands as a
   reviewable, revertable diff (`git diff` shows every replaced string).

Step 2 needs your approval to commit, since nothing has been committed so far.

---

## 4. Layers 1–2 — text, paths, imports

Run against **text files only**. Never `sed` a `.smx`, `.sqlite`, `.pyc`,
`.rcw`, `.log`, `.ini` backup or `.vpk`.

### Exact replacement ladder (ordered, longest/most specific first)

```
1  bivouac_bots_rcbot2   → ta_bots_rcbot2
2  BivBots_              → TaBots_
3  sm_bivouac_           → sm_ta_
4  BIVOUAC               → TWELVEACTORS
5  Bivouac               → Twelve Actors
6  data/bivouac          → data/twelveactors
7  /opt/bivouac          → /opt/twelveactors
8  bivouac               → twelveactors
9  biv_                  → ta_
```

Rule 1 must precede rule 8 or the module name becomes `twelveactors_bots_rcbot2`.
Rule 2 is the one the first rehearsal missed: the ladder alone leaves
**28 live `BivBots_*` references** (13 in the bots plugin, 15 across core and
its `build/` copy) and `GetFeatureStatus(FeatureType_Native, "BivBots_Available")`
then reports unavailable with no error. Rule 3 must precede rule 9, or the core
cvars become `sm_twelveactors_*`. Rules 4 and 5 are case-disjoint; order is for
readability.

There is deliberately **no rule mapping `bivouac.sp` to `ta_core.sp`**: the bare
token `bivouac` means the *core plugin* as well as the *project* in two places
(`install.sh`'s compile loop, `tests/test_voice.py`'s compile tuple), so a
filename special case would need two hand edits that the next contributor
undoes. Letting rule 8 carry the core plugin to `twelveactors.sp` keeps the
ladder total and makes both sites correct by construction. See §12 — this was
proven in rehearsal, and the alternative failed.

File set: `.py .sh .sp .md .json .cfg .service .tsv .txt .example` —
explicitly **excluding** `logs/`, `state/` logs, `backup-rename-20261019-115826/`,
`*.smx`, `*.sqlite*`, `*.pyc`, `*.rcw`, and the two process documents
`RENAME-PLAN.md` and `install-rename.sh`.

Those two are excluded because the old names in them are **literal data, not
prose**. `install-rename.sh` has to match `/srv/.../data/bivouac`,
`/opt/bivouac`, `biv_humancap.cfg`, `biv_proximity.cfg` and the
`sm_bivouac_`/`sm_biv_` sed patterns on a server that still carries the old
names. Rewrite them and the script becomes a no-op that exits cleanly: the
`mv` moves a directory onto itself, the cfg conversion writes `sm_ta_` from
`sm_ta_`, and the old cfg filenames stop matching so the files are skipped —
three silent failures with no error line, which is the failure class §0 exists
to prevent. The script now carries two preflight tripwires that `die` if the
pass ever touches it. `RENAME-PLAN.md` is excluded for the same reason: it
quotes the old strings as patterns and its counts only mean anything against
the pre-rename tree.

Then:
`git mv` every path in §2, `mv ~/bivouac ~/twelveactors`,
`rm -rf twelveactors/__pycache__`.

### Imports and interpreters

- 5 `from bivouac import ...` lines (`tests/test_scope.py`, `tests/test_db.py`
  ×2, `tests/test_prompt.py`, `tools/preflight.py`) → `from twelveactors import`.
- `python3 -m bivouac` → `python3 -m twelveactors` in the unit, README,
  HANDOFF, HERMES-REBUILD, `bivouac/server.py` message, `__main__.py` `prog=`.
- Log tag `[bivouac]` → `[twelveactors]`; bridge thread name
  `bivouac-bridge` → `twelveactors-bridge`.

### Hardcoded home path (fix in the same pass — 41 refs, 20 files)

`/home/admin1/bivouac/...` breaks when the tree moves and is wrong for anyone
who clones the repo. Replace with self-location, not a new hardcoded path:

- `.sh`: `HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)`
- `.py`: `ROOT = pathlib.Path(__file__).resolve().parents[1]`

Files: `fix-bot-churn-v2.sh`, `fix-bot-quota-reassert.sh`,
`fix-human-cap-12.sh`, `fix-voice-menu.sh`, `install-all.sh`,
`install-botjoin-fix.sh`, `install-dialog-gate.sh`, `install-radio-menu.sh`,
`install-source-build.sh`, `install-timer-fix.sh`, `install-waypoints.sh`,
`install-waypoints-v2.sh`, `rename-bots.sh`, `tools/deploy-voice-fix.sh`,
`tools/install-biv-echo.sh`, `tools/install-cmdspy.sh`,
`tools/improve_waypoints2.py`, `tools/scorecard.py`,
`tools/verify_waypoints2.py`, `tools/verify_waypoints.py`.

---

## 5. Layer 3 — deployment paths in the source

- `systemd/twelveactors.service`: `Description`, `PYTHONPATH`,
  `WorkingDirectory`, `ExecStart`, `ReadWritePaths` all move to
  `/opt/twelveactors` and `data/twelveactors`.
- `install.sh`: `SRC`/`BUILD`/`SM` derivation, plugin compile list
  (`twelveactors`, `ta_bots_rcbot2`, `ta_botjoin`, `ta_humancap`,
  `ta_proximity`), install loop, `ta_proximity.smx` disabled-branch, unit
  install name.
- `make-dist.sh`: archive stem `twelveactors-1.0.0`.
- `tools/make-source-zip.sh`, `tools/make-handoff-zip.sh`: same stem.
- `tools/check-secrets.py`: nothing name-specific — verify it still scans.
- `bivouac/__main__.py` default data dir → `data/twelveactors`.
- `plugin/ta_cmdspy.sp` `#define LOGFILE "data/twelveactors/cmdspy.tsv"`.
- 12 `BuildPath(..., "data/bivouac/…")` sites across `twelveactors.sp` and
  `ta_bots_rcbot2.sp`.

---

## 6. Layer 4 — admin surface

Already covered by the ladder, but this is the layer that must be *paired*
with the live cfg files in the same maintenance window, or the server runs on
compiled defaults with no error. Old values that are lost if missed:

| Cfg | Setting | Lost behaviour |
|---|---|---|
| `biv_humancap.cfg` | `sm_biv_humancap 12` | cap falls back to plugin default |
| `biv_proximity.cfg` | `sm_biv_proximity_enable 1` | proximity voice off |
| `biv_proximity.cfg` | `near 150` / `far 1200` / `minvol 0.0` | falloff shape reverts |
| `biv_proximity.cfg` | `team_only 0`, `debug 0` | minor |

Public API note for the README: every cvar an admin has ever typed changes.
Ship a one-table migration list (this section) so a returning operator can
`sed` their own configs.

---

## 7. Layer 5 — plugin prefix and cross-plugin API

- 6 plugin files rename; 6 `myinfo` display names change; `/srv` must not keep
  the old `.smx` (**duplicate load**).
- **Cross-plugin natives**: `twelveactors.sp` consumes `BivBots_Available`,
  `BivBots_GetTarget` (and declares `BivBots_Count`) from the bots plugin via
  `GetFeatureStatus(FeatureType_Native, ...)`. Rename to `TaBots_*` on both
  sides in the same pass. Miss one side and `BotsPresent()` returns false with
  no error — dialogue gating and bark targeting silently degrade, and
  `sm_ta_status` reports 0 bots.
- Console commands: `sm_biv*` → `sm_ta*` (11 of them), plus the `sm_biv` root
  command. Keep `sm_ta_status`, `sm_ta_voices`, `sm_ta_radio`, `sm_ta_say`,
  `sm_ta_test`, `sm_ta_reload`, `sm_ta_radiosim`, `sm_ta_prox`, `sm_ta_bots`,
  `sm_ta_bots_reload`.
- Load-order side effect: today `bivouac.smx` sorts before
  `bivouac_bots_rcbot2.smx` (`.` < `_`), so core loads first. After the rename
  `ta_bots_rcbot2.smx` sorts before `twelveactors.smx` (`a` < `w`), reversing
  it. Verified harmless: the dependency runs core → bots through optional
  natives, and core handles `FeatureStatus_Unavailable`. Re-check the SM log
  after migration for "native not found".

---

## 8. Verification gates (each must pass before the next layer)

1. `grep -rn "bivouac\|biv_\|BivBots_\|BIVOUAC\|Bivouac" --exclude-dir=.git --exclude-dir=logs .`
   → only the historical `backup-rename-*` dir, `revert-team-routing.sh`,
   `RENAME-PLAN.md` and `install-rename.sh` (both excluded by design, §4).
2. **Positive assertion** — the exclusion was real, not an accident:
   `grep -c '/data/bivouac' install-rename.sh` → ≥1 and
   `grep -c 'sm_bivouac_/sm_ta_' install-rename.sh` → ≥1. If either is 0 the
   pass rewrote the migration script; revert it before proceeding.
3. `python3 tools/preflight.py` → all checks pass.
4. All 7 test files run directly → same pass counts as baseline.
5. `python3 tools/check-secrets.py` → clean.
6. `python3 -c "import twelveactors"` from the tree → no error.
7. `./make-dist.sh` → `~/share/twelveactors-1.0.0.{tar.gz,zip}`, 63 files,
   secrets check clean, archives contain no `bivouac` path.
8. `bash -n` on every `.sh`; `spcomp` compile of all 5 installed plugins.

---

## 9. Live migration — `install-rename.sh` (staged, not run)

Prepared at `~/twelveactors/install-rename.sh`; dry-run by default, `--apply`
to execute. It must run as root (`sudo bash install-rename.sh --apply`), since
this session has no sudo. Order:

1. Preflight: root; `/opt/bivouac` exists; `/opt/twelveactors` absent; data dir
   present; `twelveactors.smx` built. Refuse otherwise.
2. `systemctl disable --now bivouac.service` — **stop before touching the data
   dir**; the 4.1 MB `state.sqlite-wal` is un-checkpointed and copying a live
   WAL DB is how state gets lost.
3. `mv /srv/.../data/bivouac /srv/.../data/twelveactors` (whole dir, all 19
   files, ownership `dod:dod` preserved incl. `config.json` 0600).
4. `mv /opt/bivouac /opt/twelveactors`; `mv /opt/twelveactors/bivouac
   /opt/twelveactors/twelveactors`; drop `__pycache__`. The six `bivouac.bak.*`
   package copies are nested inside `/opt/bivouac/`, so they travel with the
   move and stay as rollback material under the old name.
5. Install `twelveactors.service` **before** removing the old unit file;
   `daemon-reload`; `enable --now`.
6. Plugins: install `twelveactors.smx`, `ta_bots_rcbot2.smx`,
   `ta_botjoin.smx`, `ta_humancap.smx`, `ta_proximity.smx`, `ta_cmdspy.smx`
   into `plugins/`;
   **remove** `bivouac.smx`, `bivouac_bots_rcbot2.smx`, `biv_botjoin.smx`,
   `biv_humancap.smx`, `biv_proximity.smx`, `biv_cmdspy.smx` (removal, not
   shadowing — SourceMod loads every `.smx` present). The 13 `.smx.bak.*`
   files are inert and may stay.
7. `scripting/`: install the new `.sp`, remove `bivouac.sp`,
   `bivouac_bots_rcbot2.sp`, `biv_proximity.sp`.
8. Cfgs: write `ta_humancap.cfg` and `ta_proximity.cfg` with `sm_ta_*` names
   from the old files' values; move `biv_humancap.cfg` / `biv_proximity.cfg`
   to `*.pre-rename` so nothing sets a dead cvar name.
9. Rewrite `sm_warmode_on.cfg` load lines to `ta_bots_rcbot2.smx` + `twelveactors.smx`.
10. `systemctl restart dods`.
11. Verify: `systemctl is-active twelveactors`; health endpoint on 127.0.0.1:8377
    reports humans/dialog_open/gated; SM log shows 6 plugins loaded, zero
    "native not found"; `sm_ta_status` (in-game or via console log) reports 12
    bots and a non-zero voiced count.

Rollback: stop `twelveactors.service`; restore `/opt/bivouac` and
`data/bivouac` from the `bivouac.bak.*` / `.pre-rename` copies; `systemctl
enable --now bivouac.service`; reinstall the old `.smx` set; restart `dods`.

---

## 10. Risks, ranked

1. **Silent cvar mismatch** — old cfg + new plugin = defaults, no error. Highest
   risk; mitigated by steps 8–9 above and gate 11.
2. **Data dir moved while the daemon runs** — loses WAL. Mitigated by step 2.
3. **Duplicate plugins** — old `.smx` left beside new ones. Mitigated by removal.
4. **Renamed native on one side only** — `BotsPresent()` false, no error.
5. **Sed over a binary** — corrupt `.smx`/`.sqlite`. Mitigated by the text-only
   file set.
6. **No git commits** — no revert path. Mitigated by §3.
7. **Warmode cfg** loading removed filenames — cosmetic error in log, but fix it.
8. **Hardcoded `/home/admin1/bivouac`** — breaks on move and for every clone.

---

## 11. Decisions this plan assumes (override any of them)

1. Core plugin file is `twelveactors.sp` / `twelveactors.smx` (display "Twelve
   Actors Core"), not `ta_core`. The five module plugins take the `ta_` prefix.
   This is a rehearsal result, not a preference — see §12.
2. Flat `sm_ta_*` for both core and plugins, no second namespace.
3. Env vars take the `TWELVEACTORS_` prefix (uppercase of the full name, not
   `TA_`), because they are read by shell installers, not by the plugin.
4. Docs become `TWELVEACTORS-HANDOFF.md` / `TWELVEACTORS-WORK-PERFORMED.md`.
5. `dods_spawnwatch` is a diagnostic, not part of the product — **not**
   renamed.

---

## 12. Rehearsal evidence (throwaway copy, 2026-10-20)

Two full source-side passes were run on copies under
`~/.hermes/cache/scratch/`, never on `~/bivouac`.

**Rehearsal A** — ladder with `bivouac.sp → ta_core.sp` and no native rule:

- leftovers: 28 `BivBots_*` references in `ta_core.sp`, `ta_bots_rcbot2.sp`
  and their `build/` copies.
- `tests/test_voice.py`: **28/29** — it tried to compile
  `plugin/twelveactors.sp`, which does not exist, because the bare token
  `bivouac` in its compile tuple had been caught by the catch-all rule.
  `install.sh`'s compile loop had the same mismatch.

**Rehearsal B** — ladder as printed in §4 (adds `BivBots_ → TaBots_`, drops the
filename special case):

| Gate | Result |
|---|---|
| Leftover `bivouac` / `biv_` / `BivBots_` / `BIVOUAC` / `Bivouac` | **none** |
| `test_db` | pass — 6 payloads stored as data, gate reason injection |
| `test_preflight` | pass — 8/8 |
| `test_prompt` | pass |
| `test_rcon` | pass — 7/7 |
| `test_scope` | pass — 36 refusal lines across 12 personas, 0 problems |
| `test_secrets` | pass — 9/9 |
| `test_voice` | **29/29**, including a real `spcomp` compile of
  `twelveactors.sp` and `ta_proximity.sp` with zero warnings |
| `tools/preflight.py` | `preflight ok` |
| `import twelveactors` | ok |
| `bash -n` on every `.sh` | all parse |
| `make-dist.sh` (`OUT=` scratch) | `twelveactors-1.0.0.tar.gz`, **63 files**,
  secrets scan clean, zero `bivouac`/`biv_` paths inside the archive |

The archive listing confirms the resulting plugin set:
`twelveactors.sp`, `ta_bots_rcbot2.sp`, `ta_botjoin.sp`, `ta_botjoin_experimental.sp`,
`ta_cmdspy.sp`, `ta_humancap.sp`, `ta_proximity.sp`.

What the rehearsal does **not** cover: the `.smx` binaries (they are rebuilt by
`install.sh`'s compile step, hence stale in the copy), the live `/srv`
migration, and the systemd change. Those are §9, and they need `sudo`.

---

## 13. Repo visibility, and the two process documents

Decision (user, 2026-10-20): the repository is created **private** first, and
`RENAME-PLAN.md` + `install-rename.sh` are committed to it as part of the
record. Neither is in `.gitignore`, and both are excluded from the text pass
(§4) so they still read as a description of the old→new mapping.

Removing them before a public flip needs one piece of care: `git rm` in a later
commit does **not** take a file out of history. A private repo flipped to
public exposes every commit it has, so a file deleted in commit 2 is still
readable in the tree of commit 1. With this history being one or two local
commits, the cheap routes are:

1. **Recreate** — delete the private repo on GitHub and push a fresh tree
   without the two files. Nothing depends on this history yet, so this costs
   nothing but is the only route that is certainly clean.
2. **Amend before the first push** — `git rm --cached` the two files, amend the
   single commit (`git commit --amend --no-edit`), push once. Works only while
   there is exactly one commit and no remote, i.e. right now.
3. **Keep them public** — harmless (no credentials; the secrets scan covers
   them), just noise, and a pre-rename document that a stranger may read as a
   live instruction.

The route that must not be taken: leave them in the private repo, flip it
public, then `git rm` them. That looks like it worked and does not.

