#!/usr/bin/env python3
"""
MASTER REBUILD — the single source of truth pipeline.

1. Rebuilds all workbench-labeled characters from the USER'S rects in
   build-assets/workbench_export.json (authoritative — overrides everything).
2. Re-canvases sansdt (battle Sans) from his idle family.
3. Processes ALL Hollow Knight enemies + NPCs from build-assets/extracted
   into Resources/Packs/hollowknight (row01 -> "idle", others keep row names).
4. Regenerates packs_manifest.json ENTIRELY from the files on disk.
5. Updates CharacterDefinition.swift geometry from the manifest and emits
   GeneratedRoster.swift with every enemy + NPC as a real roster entry.

Run AFTER any workbench labeling session. Never run process_pack_sprites.py
again — its MAPPINGS are obsolete and it clobbers user labels.
"""
import json
import pathlib
import re
import shutil
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

ROOT = pathlib.Path(__file__).resolve().parent.parent
SHEETS = pathlib.Path.home() / "Downloads" / "sprite sheets"
PACKS = ROOT / "Sources/Bill/Resources/Packs"
MANIFEST_PATH = PACKS / "packs_manifest.json"
EXTRACTED = ROOT / "build-assets/extracted"

NEAREST = 0  # PIL resampling: NEAREST (pixel art)

# The workbench's exact background conventions (port of
# Scripts/sprite-labeler/workbench.py `detect_sprites`) — the user's labeled
# rects are raw sheet crops, so background removal MUST happen here.
PURPLE_DARK = np.array([138, 90, 157])
PURPLE_LIGHT = np.array([195, 134, 255])


def detect_sheet_background(arr):
    """One background color per FULL sheet, or None when the sheet carries
    no significant solid background (already-transparent sheets).
    Purple convention (Undertale) first, then dominant opaque color."""
    h, w = arr.shape[:2]
    alpha = arr[:, :, 3] > 30

    def close_to(target, tol=45):
        return (np.abs(arr[:, :, :3].astype(int) - target[None, None, :])
                .max(axis=2) <= tol) & alpha

    purple = close_to(PURPLE_DARK) | close_to(PURPLE_LIGHT)
    if purple.sum() > w * h * 0.10:
        return "purple"
    if alpha.sum() > w * h * 0.60:
        # Mostly-opaque sheet: its dominant opaque color is the background.
        from collections import Counter
        opaque = arr[alpha][:, :3]
        if len(opaque) == 0:
            return None
        return np.array(Counter(map(tuple, opaque)).most_common(1)[0][0])
    if alpha.sum() > w * h * 0.05:
        # Mixed sheet (e.g. Deltarune: transparent overworld + solid-bg
        # battle rows): dominant opaque color among OPAQUE pixels is the
        # battle background — it always outnumbers the sprites.
        from collections import Counter
        opaque = arr[alpha][:, :3]
        return np.array(Counter(map(tuple, opaque)).most_common(1)[0][0])
    return None


def remove_frame_background(crop, sheet_bg):
    """Erase the sheet background from one frame crop: pixels matching the
    sheet's background (purple convention set, or the detected dominant
    color) that are edge-connected get zero alpha. Mirrors the workbench
    flood logic at frame scale. Frames with no edge-connected background
    match are left untouched."""
    if sheet_bg is None:
        return crop
    h, w = crop.shape[:2]
    alpha = crop[:, :, 3] > 30
    if alpha.sum() == 0:
        return crop

    if sheet_bg == "purple":
        candidates, tol = [PURPLE_DARK, PURPLE_LIGHT], 45
    else:
        candidates, tol = [np.asarray(sheet_bg)], 40

    for target in candidates:
        match = (np.abs(crop[:, :, :3].astype(int) - target[None, None, :])
                 .max(axis=2) <= tol) & alpha
        if match.sum() == 0:
            continue
        # Flood from the crop's borders: only edge-connected matches are bg.
        lbl, _ = ndimage.label(match)
        border = set(np.unique(lbl[0, :])) | set(np.unique(lbl[-1, :]))
        border |= set(np.unique(lbl[:, 0])) | set(np.unique(lbl[:, -1]))
        border.discard(0)
        if not border:
            continue
        bg_mask = np.isin(lbl, list(border))
        if bg_mask.sum() >= w * h * 0.90:
            continue  # would erase nearly the whole frame — not a background
        crop = crop.copy()
        crop[bg_mask, 3] = 0
        alpha = crop[:, :, 3] > 30
    return crop

# sheet filename -> (character id, pack)
SHEET_CHAR = {
    "PC _ Computer - Undertale - Non-Playable Characters - Sans.png": ("sans", "undertale"),
    "PC _ Computer - Undertale - Non-Playable Characters - Papyrus.png": ("papyrus", "undertale"),
    "PC _ Computer - Undertale - Non-Playable Characters - Toriel.png": ("toriel", "undertale"),
    "PC _ Computer - Undertale - Non-Playable Characters - Flowey.png": ("flowey", "undertale"),
    "PC _ Computer - Undertale - Non-Playable Characters - Temmie.png": ("temmie", "undertale"),
    "PC _ Computer - Undertale - Non-Playable Characters - Monster Kid.png": ("monsterkid", "undertale"),
    "PC _ Computer - Undertale - Non-Playable Characters - Annoying Dog.png": ("annoyingdog", "undertale"),
    "PC _ Computer - Undertale - Playable Characters - Frisk.png": ("frisk", "undertale"),
    "PC _ Computer - Deltarune - Playable Characters - Kris (Chapter 1 + 2).png": ("kris", "deltarune"),
    "PC _ Computer - Deltarune - Playable Characters - Ralsei (Chapter 1 + 2).png": ("ralsei", "deltarune"),
    "PC _ Computer - Deltarune - Playable Characters - Susie (Chapter 1 + 2).png": ("susie", "deltarune"),
    "PC _ Computer - OneShot (2014, Freeware) - Playable Characters - Niko.png": ("niko", "oneshot"),
    "Custom _ Edited - OneShot Customs - Niko - Niko (Deltarune-Style).png": ("niko", "oneshot"),
    "Custom _ Edited - Undertale Customs - Sans - Sans (Deltarune Battle-Style, Expanded).png": ("sansdt", "undertale"),
}

CORE_CANDIDATES = [
    "idle", "idle_still", "down", "forward", "forward-walk",
    "walk-forward", "walk", "default",
]

# HK NPC display names + which are enemies vs NPCs
NPC_NAMES = {
    "bretta": "Bretta", "brumm": "Brumm", "cloth": "Cloth", "cornifer": "Cornifer",
    "divine": "Divine", "elderbug": "Elderbug", "godseeker": "Godseeker",
    "grub": "Grub", "grubfather": "Grubfather", "iselda": "Iselda", "jiji": "Jiji",
    "lemm": "Lemm", "marissa": "Marissa", "midwife": "Midwife",
    "millibelle": "Millibelle", "myla": "Myla", "nailsmith": "Nailsmith",
    "quirrel": "Quirrel", "salubra": "Salubra", "seer": "Seer", "sly": "Sly",
    "tiso": "Tiso", "willoh": "Willoh", "zote": "Zote",
}


def fam_name(label):
    s = re.sub(r"[^a-z0-9]+", "-", label.strip().lower())
    return s.strip("-")


def content_bounds(arr):
    al = arr[:, :, 3] > 30
    ys, xs = np.where(al)
    if len(ys) == 0:
        return None
    return xs.min(), ys.min(), xs.max(), ys.max()


def load_sheet(name):
    p = SHEETS / name
    if not p.exists():
        sys.exit(f"FATAL: missing sheet {p}")
    image = Image.open(str(p)).convert("RGBA")
    arr = np.asarray(image)
    bg = detect_sheet_background(arr)
    kind = "purple" if bg == "purple" else ("none" if bg is None else f"rgb{tuple(bg)}")
    print(f"    sheet bg [{name[:48]}]: {kind}")
    return (image, bg)


def bottom_anchor(crop, max_w, max_h):
    """Place crop bottom-center in a max_w x max_h transparent canvas,
    downscaling (NEAREST) if it exceeds the canvas."""
    ch, cw = crop.shape[:2]
    if cw > max_w or ch > max_h:
        scale = min(max_w / cw, max_h / ch)
        crop = np.asarray(
            Image.fromarray(crop).resize(
                (max(1, int(cw * scale)), max(1, int(ch * scale))), NEAREST
            )
        )
    canvas = np.zeros((max_h, max_w, 4), dtype=np.uint8)
    fh, fw = crop.shape[:2]
    canvas[max_h - fh:max_h, (max_w - fw) // 2:(max_w - fw) // 2 + fw] = crop
    return canvas


def recanvas_files(files, out_dir, prefix, core_bounds):
    """Re-fit every frame to a canvas sized from core_bounds x padding."""
    x0, y0, x1, y1 = core_bounds
    core_w, core_h = x1 - x0 + 1, y1 - y0 + 1
    max_w = max(int(core_w * 1.35), core_w)
    max_h = max(int(core_h * 1.12), core_h)
    n = 0
    for f in sorted(files):
        arr = np.asarray(Image.open(str(f)).convert("RGBA"))
        b = content_bounds(arr)
        if b is None:
            continue
        x0, y0, x1, y1 = b
        crop = arr[y0:y1 + 1, x0:x1 + 1]
        Image.fromarray(bottom_anchor(crop, max_w, max_h)).save(out_dir / f.name)
        n += 1
    return n, max_w, max_h, core_h


def rebuild_workbench_character(char, labels, sheets_cache):
    """char: id -> (pack, {family: [(sheet, rect)...]})"""
    pack, fams = labels
    out_dir = PACKS / pack / "Sprites"
    out_dir.mkdir(parents=True, exist_ok=True)
    # CLEAN SLATE — remove every old file of this character first
    for old in out_dir.glob(f"{char}_*.png"):
        old.unlink()

    # gather raw frames per family (uncropped, from sheet rects),
    # with the sheet's background removed (the workbench flood logic —
    # the user's rects are raw sheet crops, NOT transparent sprites).
    raw = {}
    for label, data in fams.items():
        fam = fam_name(label)
        frames = []
        for fr in data["frames"]:
            img, sheet_bg = sheets_cache[data["sheet"]]
            rect = (fr["x"], fr["y"], fr["x"] + fr["w"], fr["y"] + fr["h"])
            crop = np.asarray(img.crop(rect))
            frames.append(remove_frame_background(crop, sheet_bg))
        raw[fam] = frames

    # core family for canvas sizing
    core = next((c for c in CORE_CANDIDATES if c in raw), sorted(raw)[0])
    cb = None
    for arr in raw[core]:
        b = content_bounds(arr)
        if b:
            cb = b if cb is None else (
                min(cb[0], b[0]), min(cb[1], b[1]),
                max(cb[2], b[2]), max(cb[3], b[3]),
            )
    if cb is None:
        print(f"  {char}: NO CONTENT — skipped")
        return None

    x0, y0, x1, y1 = cb
    core_w, core_h = x1 - x0 + 1, y1 - y0 + 1
    max_w = max(int(core_w * 1.35), core_w)
    max_h = max(int(core_h * 1.12), core_h)

    fam_counts = {}
    for fam, frames in sorted(raw.items()):
        for i, arr in enumerate(frames, 1):
            b = content_bounds(arr)
            if b is None:
                continue
            crop = arr[b[1]:b[3] + 1, b[0]:b[2] + 1]
            Image.fromarray(bottom_anchor(crop, max_w, max_h)).save(
                out_dir / f"{char}_{fam}_{i:02d}.png"
            )
        fam_counts[fam] = len(frames)
    return {
        "canvas": [int(max_w), int(max_h)],
        "idle_h": int(core_h),
        "families": {k: int(v) for k, v in fam_counts.items()},
    }


def rebuild_hk_named_frames(char_id, zip_glob, inner_path, out_prefix):
    """HK characters shipped as '<Char> - <anim><NN>.png' inside the Google
    Drive Unity dumps: the frames are ALREADY MADE and their animation ids
    are IN THE FILENAMES — used VERBATIM (uniform canvas preserved, family
    names = the ids, '#' atlas-reference duplicates of a frame number are
    hash-deduped; the largest-content copy wins if variants differ).

    zip_glob: glob under ~/Downloads (e.g. 'Bosses-*.zip').
    inner_path: path prefix inside the zip (e.g. 'Bosses/Hornet/').
    """
    import zipfile
    candidates = sorted(pathlib.Path.home().joinpath("Downloads").glob(zip_glob))
    if not candidates:
        sys.exit(f"FATAL: no zip matches {zip_glob}")
    entries = None
    used_zip = None
    for z in candidates:
        with zipfile.ZipFile(z) as zf:
            names = [n for n in zf.namelist()
                     if n.startswith(inner_path) and n.endswith(".png")
                     and "atlas" not in n]
            if names:
                entries, used_zip = names, z
                break
    if not entries:
        sys.exit(f"FATAL: no named frames under {inner_path} in {zip_glob}")

    out_dir = PACKS / "hollowknight" / "Sprites"
    out_dir.mkdir(parents=True, exist_ok=True)
    for old in out_dir.glob(f"{out_prefix}_*.png"):
        old.unlink()

    # Group by animation id + frame number; dedup '#' atlas references.
    frame_re = re.compile(r"^.+? - (?P<anim>[^0-9#]+?)(?P<num>\d+)(?: #(?P<ref>\d+))?\.png$")
    grouped = {}
    for name in entries:
        m = frame_re.match(name.rsplit("/", 1)[-1])
        if not m:
            continue
        grouped.setdefault((m["anim"], int(m["num"])), []).append(name)

    import io
    # Pass 1: decode every variant, learn the majority canvas size —
    # the '#' atlas references include content-cropped copies at DIFFERENT
    # canvas sizes; mixing them breaks the shared-canvas convention
    # (resize:false renders every frame at the first frame's node size).
    with zipfile.ZipFile(used_zip) as zf:
        variant_info = {}  # (anim, num) -> [(canvas, opaque, name)]
        for (anim, num), names in sorted(grouped.items()):
            for n in names:
                arr = np.asarray(Image.open(io.BytesIO(zf.read(n))).convert("RGBA"))
                op = int((arr[:, :, 3] > 30).sum())
                variant_info.setdefault((anim, num), []).append(
                    ((arr.shape[1], arr.shape[0]), op, n))
        from collections import Counter
        size_votes = Counter(
            v[0] for variants in variant_info.values() for v in variants
        )
        if not size_votes:
            sys.exit(f"FATAL: {char_id}: no frames decoded")
        majority_canvas = size_votes.most_common(1)[0][0]
        # Pass 2: per frame, keep only majority-canvas variants, most-opaque.
        fam_files = {}
        dropped = 0
        for (anim, num), variants in sorted(variant_info.items()):
            same_size = [v for v in variants if v[0] == majority_canvas]
            if not same_size:
                dropped += 1
                continue
            best = max(same_size, key=lambda v: v[1])
            fam_files.setdefault(anim, []).append((num, best[2]))
        if dropped:
            print(f"    {char_id}: dropped {dropped} frame number(s) with no "
                  f"variant at the majority canvas {majority_canvas}")
        canvas = majority_canvas
        # Write frames in frame-number order — verbatim bytes, no re-canvas.
        fam_counts = {}
        for anim, frames in sorted(fam_files.items()):
            frames.sort(key=lambda x: x[0])
            for i, (_, n) in enumerate(frames, 1):
                (out_dir / f"{out_prefix}_{anim}_{i:02d}.png").write_bytes(zf.read(n))
            fam_counts[anim] = len(frames)
    if canvas is None:
        sys.exit(f"FATAL: {char_id}: no frames decoded")
    print(f"  {char_id} [hollowknight] NAMED-VERBATIM: {len(fam_counts)} families, "
          f"{sum(fam_counts.values())} frames, canvas {canvas[0]}x{canvas[1]} "
          f"(from {used_zip.name})")
    return {
        "canvas": [int(canvas[0]), int(canvas[1])],
        "idle_h": int(canvas[1]),
        "families": {k: int(v) for k, v in sorted(fam_counts.items())},
    }


def rebuild_knight_verbatim():
    """The Knight, VERBATIM from the user's zip — the authoritative audit.

    The zip (~/Downloads/sprite sheets/PC _ Computer - Hollow Knight -
    Playable Characters - The Knight (Ghost).zip) ships 71 named animation
    folders of individual pre-aligned PNGs on a uniform 349x186 canvas:
    feet bottom-anchored, content centered by the author. Processing them
    means: family = folder name VERBATIM, frames in natural filename order,
    pixels UNTOUCHED (no crop, no re-canvas, no background removal — they
    are already transparent). Any "improvement" here destroys the
    author's frame alignment (the historical walk/slash misalignment bug).

    `_ effects/` holds the labeled OVERLAY effect sequences (slash arcs,
    dash trails, charge particles) — extracted as `fx-<name>` families on
    their own per-effect canvases. The rig composites the matching one on
    top of the body animation when it plays ("the effects go on top of
    whichever animation they correspond to").
    `_ unnamed/` is 96 identical 162-byte placeholder PNGs — skipped.
    """
    import zipfile
    zip_path = SHEETS / (
        "PC _ Computer - Hollow Knight - Playable Characters - The Knight (Ghost).zip"
    )
    if not zip_path.exists():
        sys.exit(f"FATAL: knight zip missing at {zip_path}")
    out_dir = PACKS / "hollowknight" / "Sprites"
    out_dir.mkdir(parents=True, exist_ok=True)
    for old in out_dir.glob("knight_*.png"):
        old.unlink()

    def natkey(p):
        return [int(t) if t.isdigit() else t
                for t in re.split(r"(\d+)", p.name)]

    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        with zipfile.ZipFile(zip_path) as zf:
            zf.extractall(tmp)
        root = pathlib.Path(tmp)
        # The zip nests everything under one folder (the_knight/).
        char_dirs = [d for d in root.iterdir() if d.is_dir()]
        base = char_dirs[0] if len(char_dirs) == 1 else root
        folders = sorted(
            d for d in base.iterdir()
            if d.is_dir() and not d.name.startswith("_")
        )
        fam_counts = {}
        canvas = None
        for folder in folders:
            frames = sorted(folder.glob("*.png"), key=natkey)
            if not frames:
                continue
            first = np.asarray(Image.open(str(frames[0])).convert("RGBA"))
            if canvas is None:
                canvas = (first.shape[1], first.shape[0])
            elif (first.shape[1], first.shape[0]) != canvas:
                print(f"  knight/{folder.name}: NON-UNIFORM canvas "
                      f"{first.shape[1]}x{first.shape[0]} vs {canvas} — kept as-is")
            for i, f in enumerate(frames, 1):
                shutil.copy(str(f), out_dir / f"knight_{folder.name}_{i:02d}.png")
            fam_counts[folder.name] = len(frames)
        if canvas is None:
            sys.exit("FATAL: knight zip contained no animation folders")

        # Labeled overlay effects: `_ effects/<name>/` → `fx-<name>`
        # families, frames VERBATIM on their own per-effect canvases (the
        # rig's fx node composites them over the matching animation).
        effects_dir = base / "_ effects"
        fx_count = 0
        if effects_dir.is_dir():
            for folder in sorted(d for d in effects_dir.iterdir() if d.is_dir()):
                frames = sorted(folder.glob("*.png"), key=natkey)
                if not frames:
                    continue
                for i, f in enumerate(frames, 1):
                    shutil.copy(str(f), out_dir / f"knight_fx-{folder.name}_{i:02d}.png")
                fam_counts[f"fx-{folder.name}"] = len(frames)
                fx_count += len(frames)
        if fx_count:
            print(f"  knight: {fx_count} overlay effect frames "
                  f"across {sum(1 for k in fam_counts if k.startswith('fx-'))} fx families")
    return {
        "canvas": [int(canvas[0]), int(canvas[1])],
        "idle_h": int(canvas[1]),  # uniform canvas: scale = 185/186 ≈ 1.0
        "families": {k: int(v) for k, v in sorted(fam_counts.items())},
    }


def recanvas_existing(char, pack):
    """Re-fit an already-processed character (sansdt, hornet)."""
    out_dir = PACKS / pack / "Sprites"
    files = sorted(out_dir.glob(f"{char}_*.png"))
    if not files:
        return None
    fam_files = {}
    for f in files:
        m = re.match(rf"^{char}_(.+)_(\d+)\.png$", f.name)
        if m:
            fam_files.setdefault(m.group(1), []).append(f)
    core = next((c for c in CORE_CANDIDATES if c in fam_files), sorted(fam_files)[0])
    cb = None
    for f in fam_files[core]:
        b = content_bounds(np.asarray(Image.open(str(f)).convert("RGBA")))
        if b:
            cb = b if cb is None else (
                min(cb[0], b[0]), min(cb[1], b[1]),
                max(cb[2], b[2]), max(cb[3], b[3]),
            )
    if cb is None:
        return None
    n, max_w, max_h, core_h = recanvas_files(files, out_dir, char, cb)
    return {
        "canvas": [int(max_w), int(max_h)],
        "idle_h": int(core_h),
        "families": {k: int(len(v)) for k, v in sorted(fam_files.items())},
    }


def process_rows_character(src, prefix, pack="hollowknight"):
    """Process a row-folder character (HK enemies + NPCs):
    row01 -> family "idle", rowNN -> "rowNN"."""
    out_dir = PACKS / pack / "Sprites"
    rows = sorted(src.glob("row*"))
    if not rows:
        return None
    for old in out_dir.glob(f"{prefix}_*.png"):
        old.unlink()
    # collect all frames per row
    row_frames = {}
    for row in rows:
        if not row.is_dir():
            continue
        row_frames[row.name] = sorted(row.glob("*.png"))
    # core bounds from row01
    cb = None
    for f in row_frames.get("row01", []) or next(iter(row_frames.values())):
        b = content_bounds(np.asarray(Image.open(str(f)).convert("RGBA")))
        if b:
            cb = b if cb is None else (
                min(cb[0], b[0]), min(cb[1], b[1]),
                max(cb[2], b[2]), max(cb[3], b[3]),
            )
    if cb is None:
        return None
    fam_counts = {}
    for row, files in sorted(row_frames.items()):
        fam = "idle" if row == "row01" else row
        for i, f in enumerate(files, 1):
            arr = np.asarray(Image.open(str(f)).convert("RGBA"))
            b = content_bounds(arr)
            if b is None:
                continue
            crop = arr[b[1]:b[3] + 1, b[0]:b[2] + 1]
            x0, y0, x1, y1 = cb
            max_w = max(int((x1 - x0 + 1) * 1.35), x1 - x0 + 1)
            max_h = max(int((y1 - y0 + 1) * 1.12), y1 - y0 + 1)
            Image.fromarray(bottom_anchor(crop, max_w, max_h)).save(
                out_dir / f"{prefix}_{fam}_{i:02d}.png"
            )
        fam_counts[fam] = len(files)
    x0, y0, x1, y1 = cb
    core_h = y1 - y0 + 1
    max_w = max(int((x1 - x0 + 1) * 1.35), x1 - x0 + 1)
    max_h = max(int((y1 - y0 + 1) * 1.12), core_h)
    return {
        "canvas": [int(max_w), int(max_h)],
        "idle_h": int(core_h),
        "families": {k: int(v) for k, v in sorted(fam_counts.items())},
    }


def main():
    wb = json.load(open(ROOT / "build-assets/workbench_export.json"))
    sheets_cache = {}

    # group labels per character id
    per_char = {}
    for char_id, labels in wb.items():
        if char_id.startswith("_"):
            continue
        entry = per_char.setdefault(char_id, {})
        for label, data in labels.items():
            sheet = data.get("sheet", "")
            if sheet not in SHEET_CHAR:
                print(f"  WARN {char_id}/{label}: unknown sheet '{sheet}' — skipped")
                continue
            cid, pack = SHEET_CHAR[sheet]
            entry.setdefault((cid, pack), {}).setdefault(label, data)

    manifest = {}

    # 1. workbench characters — USER'S LABELS ARE FINAL
    print("== workbench characters ==")
    for char_id in sorted(per_char):
        for (cid, pack), fams in per_char[char_id].items():
            for s in {d["sheet"] for d in fams.values()}:
                if s not in sheets_cache:
                    sheets_cache[s] = load_sheet(s)
            info = rebuild_workbench_character(cid, (pack, fams), sheets_cache)
            if info:
                manifest[cid] = info
                total = sum(info["families"].values())
                print(f"  {cid} [{pack}]: {len(info['families'])} families, "
                      f"{total} frames, canvas {info['canvas']}")

    # 2. The Knight VERBATIM from the zip; Hornet + Weaver VERBATIM from
    #    their named frames in the Drive dumps; sansdt re-fit.
    print("== recanvas existing ==")
    knight_info = rebuild_knight_verbatim()
    manifest["knight"] = knight_info
    print(f"  knight [hollowkit] VERBATIM: {len(knight_info['families'])} families, "
          f"{sum(knight_info['families'].values())} frames, canvas {knight_info['canvas']}")
    hornet_info = rebuild_hk_named_frames("hornet", "Bosses-*.zip", "Bosses/Hornet/", "hornet")
    manifest["hornet"] = hornet_info
    weaver_info = rebuild_hk_named_frames("weaver", "NPCs-*.zip", "NPCs/Weavers/", "weaver")
    manifest["weaver"] = weaver_info
    for cid, pack in [("sansdt", "undertale")]:
        info = recanvas_existing(cid, pack)
        if info:
            manifest[cid] = info
            print(f"  {cid} [{pack}]: {len(info['families'])} families, "
                  f"{sum(info['families'].values())} frames, canvas {info['canvas']}")

    # 3. HK enemies + NPCs: DELIBERATELY NOT PROCESSED. The extracted
    # row folders are not reliably labeled — row-slicing produced garbage
    # frames ("flipped random frames"). They stay in build-assets/extracted
    # (never in Resources) until they are properly labeled in the workbench
    # like every other character. Knight + Hornet (from the verified zip)
    # continue to ship.

    # 4. write manifest (atomic-ish: temp then replace)
    tmp = MANIFEST_PATH.with_suffix(".tmp")
    json.dump(manifest, open(tmp, "w"), indent=1, sort_keys=True)
    tmp.replace(MANIFEST_PATH)
    print(f"manifest written: {len(manifest)} characters")

    # 5. update roster geometry for existing hand-written definitions.
    #    Scale: target ~185pt visible height, CAPPED at 4.0 — beyond that
    #    small-pixel art (kris/sans/niko, 20-40px sheets) renders as huge
    #    mushy blocks ("too pixelated low res"). Crisp beats big.
    def_source = ROOT / "Sources/Bill/Packs/CharacterDefinition.swift"
    text = def_source.read_text()
    n_updated = 0
    for cid, info in manifest.items():
        cw, chh = info["canvas"]
        scale = round(min(185.0 / info["idle_h"], 4.0), 2)
        pattern = (rf'(spritePrefix: "{cid}", canvasSize: '
                   rf'CGSize\(width: )\d+(, height: )\d+(\), displayScale: )[0-9.]+')
        new_text, n = re.subn(
            pattern,
            rf"\g<1>{cw}\g<2>{chh}\g<3>{scale}",
            text, count=1,
        )
        if n:
            text = new_text
            n_updated += 1
    def_source.write_text(text)
    print(f"roster geometry updated: {n_updated} entries")

    # 6. GeneratedRoster.swift — EMPTY for now: HK enemies/NPCs are
    # deliberately hidden until their rows are properly labeled in the
    # workbench (the row-slice extraction produced garbage frames).
    # When that labeling exists, re-enable section 3 above.
    lines = [
        "// Generated by Scripts/rebuild_from_workbench.py — do not edit by hand.",
        "//",
        "// DELIBERATELY EMPTY: Hollow Knight enemies and NPCs are hidden",
        "// until their sprites are properly labeled in the Sprite Workbench.",
        "// The extracted row folders are not reliable frame data (row-sliced",
        "// garbage). They live in build-assets/extracted/ and build-assets/",
        "// hk_staging/, never in Resources. Knight and Hornet ship normally",
        "// from the verified zip.",
        "",
        "import Foundation",
        "",
        "extension CharacterRoster {",
        "    static let generatedEnemies: [CharacterDefinition] = []",
        "}",
        "",
    ]
    gen_path = ROOT / "Sources/Bill/Packs/GeneratedRoster.swift"
    gen_path.write_text("\n".join(lines))
    print("GeneratedRoster.swift: 0 definitions (HK enemies/NPCs hidden)")


if __name__ == "__main__":
    main()
