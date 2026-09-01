# THE MOD CANNOT BE PUBLISHED, AND IT IS NOT OUR BUG

**This is the only thing standing between Server Works and a release.** The mod
itself is finished: V80, 230 checks passing, committed, pushed. Every attempt to
upload it dies in Scrap Mechanic's own `ContentCompiler.exe`.

Status as of **2026-09-01, 00:00**: unresolved. Six theories tested and killed by
measurement. Next step is a bug report to Axolot, because there is nothing left
on this machine to change.

---

## The failure

The Mod Tool shows **"Failed create mod cache, Please check ContentCompiler
log."** followed by a BugSplat crash dialog. In `ModTool-*.log`:

    ContentCompiler.exe --ugc=".../Mods/Server Works" --dont-overwrite-icons --cache
      exited with code: 3221225477
    ERROR: ASSERT: 'uExitCode == 0' : ModTool.cpp:458

`3221225477` is `0xC0000005` — an access violation.

In `ContentCompiler-*.log`, always the same three lines:

    -----------------------Generating Prefab Icons-----------------------
    FrameRenderTargets::createOrResize Main from: 0x0 to: 1280x720
    ERROR: BugSplatUtil.cpp:22 Bugsplat!

**One second between the render target and the crash.** Deterministic, every
run, ten runs across two mods.

## What it is NOT. Every one of these was measured, not reasoned about

| theory | how it died |
|---|---|
| **out of memory** | crashed with **6,424 MB free**. Started at 1,983 MB on the first run and 7,799 MB on a later one — same crash, same line. RAM was never the variable |
| **our mod** | **`Dimension Mechanic` — a different Custom Game, already published to the Workshop (fileId 3747160912) — crashes identically. Four times.** This is the control that settles it |
| **missing materials** | eight `Could not find material` errors looked promising. Two runs had **zero** of them and still crashed. Also: the GAME never reports them (0 of 14 recent `game-*.log`), only the Mod Tool does |
| **stale cache bundles** | 13 of 15 were dated 2026-08-01, older than the 2026-08-03 executable. Moved them aside; they rebuilt to **byte-identical sizes** (`survival_asset_physics.cbo` 8,409,408 both times). They were never stale |
| **corrupt game files** | Steam verify: **28 files failed and were reacquired** (Mod Tool: 66/66 clean). Still crashed. `ContentCompiler.exe` was not among them — same date, same 18,321,920 bytes |
| **GPU driver** | updated `32.0.15.8228` (2026-01-20) → `32.0.15.8266` (2026-06-09). Still crashed |

## What it IS

**The offscreen icon renderer.** Not prefabs, not blueprints — the renderer
itself. Proven by starving it:

- Parked `Survival/LocalPrefabs` (1,635 files) → **"Generating Prefab Icons"
  vanished from the log entirely** and the crash moved to the *next* phase.
- Parked `Survival/LocalBlueprints` and `ChallengeData/Blueprints` → still
  crashes at **"Generating Blueprint Icons"**.

Every phase opens with `FrameRenderTargets::createOrResize Main from: 0x0 to:
1280x720` and dies one second later. Take its input away and it just walks to
the next phase and does the same thing.

## Why it worked before

    2026-01-20   GPU driver installed          (worked fine after this)
    2026-06-18   Mod Tool runs CLEAN, 0 bugsplats, ContentCompiler exits 0
    2026-08-03   GAME UPDATE -> new ScrapMechanic.exe AND new ContentCompiler.exe
    2026-08-20   Mod Tool app update
    2026-09-01   crashes, every Custom Game, every run

**The 3 August game update is the only thing that changed between working and
broken**, and `ContentCompiler.exe` ships with the GAME (dated 2026-08-03,
identical timestamp to `ScrapMechanic.exe`) — so there is no older copy to roll
back to independently of the game itself.

Worth noting: **the June runs never reached any icon phase at all.** So it is
equally possible this render path was always broken on this hardware and the
August update simply started calling it.

## What to try next, in order

1. **Report it to Axolot.** This is an unusually strong report and it is the
   step that is actually likely to resolve it. Everything in the two tables
   above is reproducible evidence, and "a published Custom Game crashes the same
   way" is the sentence that makes it not a support ticket.
2. **Try it on another machine.** Different GPU, different driver. If it
   compiles elsewhere, that localises it to this hardware and Axolot can be told
   so. (Publish from your OWN account — a Workshop item belongs to whoever
   uploads it.)
3. **Watch for a Scrap Mechanic patch** and retry after each one.

## Do not waste time re-testing these

Adding RAM. Reinstalling the Mod Tool (66/66 files validate). Verifying the game
again (already done, 28 files reacquired, no change). Clearing the cache
(rebuilds identically). Changing anything in `mod/` — the control mod has none
of our content and fails the same way.

## The tool that parks game content

`dev/restore_prefabs.py` moves the folders the icon generator renders from out
of the game tree, and puts them back:

    python dev/restore_prefabs.py --park     take them out
    python dev/restore_prefabs.py            PUT THEM BACK

It moves, never deletes, and parks outside the Scrap Mechanic folder so nothing
scans them. Survival worlds are built from those prefabs, so they must go back.
**They were restored on 2026-09-01 at 00:00 and the game is whole.** Steam's
Verify integrity restores them too if the script is ever lost.

It got two phases further than doing nothing, so it is worth re-running if a
future patch fixes some phases and not others — but it is a probe, not a fix.

## What is NOT blocked

Everything else. The mod is done and on GitHub. `dev/publish_prep.py` has
already stripped the host's own 22.8 MB of state out of the mod folder, the
description leads with VERY EARLY TESTING and the AI disclosure, the gallery
images are cut and captioned, and `mod/description.json` has no `fileId` because
it has never been uploaded.

The moment the compiler works, publishing is one click and one commit.
