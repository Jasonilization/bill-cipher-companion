#!/usr/bin/env python3
"""GIF review gallery — serves docs/gifs/*.gif on a local page with each
GIF's source family, frame count and size, so every preview can be checked
in the browser. Usage: python3 Scripts/gif_gallery.py [port]"""
import json
import pathlib
import re
import sys
from http.server import HTTPServer, SimpleHTTPRequestHandler
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
GIFS = ROOT / "docs" / "gifs"
MANIFEST = json.load(open(ROOT / "Sources/Bill/Resources/Packs/packs_manifest.json"))

# Which family each gif renders (keep in sync with the generator choices).
FAMILY = {
    "bill": ("walk", "powersurge"), "sans": ("stool-chup", "down"),
    "sansdt": ("happy", "laugh"), "papyrus": ("silly", "walk-left"),
    "toriel": ("chair", "down"), "frisk": ("drop-water", "down"),
    "flowey": ("face-grow", "face-shrink"), "temmie": ("hoivs", "walk-left"),
    "monsterkid": ("right-face-fall-stand-left-face-fall", "walk-left"),
    "annoyingdog": ("eat-bone", "sit"), "niko": ("spin", "forward-walk"),
    "knight": ("nail_slash", "walk"), "hornet": ("jump", "throw_side"),
    "weaver": ("idle", "crawl"), "kris": ("battle-attack-intro", "walk-forward"),
    "ralsei": ("spin-scarf", "wave-hi"), "susie": ("eat-chalk", "rude-buster"),
}

cards = []
for char, families in FAMILY.items():
    for idx, fam in enumerate(families):
        name = f"{char}.gif" if idx == 0 else f"{char}-2.gif"
        path = GIFS / name
        if not path.exists():
            continue
        im = Image.open(path)
        fam_count = MANIFEST.get(char, {}).get("families", {}).get(fam, "?")
        cards.append(f'''
        <div class="card">
          <div class="head"><b>{char}</b><span>{name}</span></div>
          <img src="/docs/gifs/{name}" alt="{char} {fam}">
          <div class="meta">family: <code>{fam}</code> · manifest frames: {fam_count}
            · gif frames: {im.n_frames} · {im.size[0]}x{im.size[1]}</div>
        </div>''')

html = f"""<!DOCTYPE html><html><head><meta charset="utf-8">
<title>GIF review — Bill & Friends</title>
<style>
  body {{ background: #16162a; color: #e8e8f0; font: 15px -apple-system, sans-serif; margin: 0; padding: 24px; }}
  h1 {{ font-size: 20px; }} p {{ color: #9b9aa5; }}
  .grid {{ display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 16px; }}
  .card {{ background: #1a1a22; border: 1px solid #2c2c36; padding: 14px; }}
  .head {{ display: flex; justify-content: space-between; margin-bottom: 8px; font-size: 14px; }}
  .head span {{ color: #9b9aa5; font-size: 12px; }}
  img {{ image-rendering: pixelated; max-width: 100%; height: auto; display: block; margin: 0 auto; }}
  .meta {{ margin-top: 8px; font-size: 12px; color: #9b9aa5; }}
  code {{ color: #fac726; }}
</style></head><body>
<h1>GIF review — every preview, from the shipped frames</h1>
<p>Transparent GIFs rendered from the exact PNGs in Sources/Bill/Resources. If one looks wrong, note the character + family and it's a one-line swap.</p>
<div class="grid">{''.join(cards)}</div>
</body></html>"""

(ROOT / "docs" / "gif-review.html").write_text(html)
print(f"wrote docs/gif-review.html with {len(cards)} cards")

port = int(sys.argv[1]) if len(sys.argv) > 1 else 8481
class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=str(ROOT), **kw)
    def log_message(self, *a): pass

print(f"serving at http://localhost:{port} — Ctrl+C to stop")
HTTPServer(("127.0.0.1", port), Handler).serve_forever()
