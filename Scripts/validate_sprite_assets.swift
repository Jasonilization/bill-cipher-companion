// Sprite asset validator — the automated gate for the user's hand-labeled
// sprite data (see .opencode/skills/sprite-asset-mandate).
//
// Runs with the stock Command Line Tools toolchain (no XCTest available in
// this environment — no Xcode installed):
//
//     swift Scripts/validate_sprite_assets.swift
//
// Exits 0 only when every check passes. Every failure names the exact
// character/family and the invariant that broke, because every serious
// sprite bug in this repo has been one of exactly these classes:
//   1. rects read with the wrong convention (x,y,w,h vs left,upper,right,lower)
//   2. manifest disagreeing with the files on disk
//   3. roster geometry disagreeing with the manifest (invisible/wrong-size)
//   4. frames not bottom-anchored (characters floating above the floor)
//   5. missing directional walk rows (wrong-direction walking)
//   6. background not removed (colored boxes around sprites)

import Foundation
import CoreGraphics
import ImageIO

let fm = FileManager.default

// MARK: - Paths

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
    .resolvingSymlinksInPath()
var repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let packsRoot = repoRoot.appendingPathComponent("Sources/Bill/Resources/Packs")
let exportURL = repoRoot.appendingPathComponent("build-assets/workbench_export.json")
let sheetsRoot = fm.homeDirectoryForCurrentUser
    .appendingPathComponent("Downloads/sprite sheets")
let rosterURL = repoRoot.appendingPathComponent("Sources/Bill/Packs/CharacterDefinition.swift")

// MARK: - Failure accounting

var failures = 0
var checks = 0

func fail(_ message: String) {
    failures += 1
    print("  ✗ FAIL: \(message)")
}

func check(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { fail(message) }
}

// MARK: - Loading

struct JSON: Decodable {}
func loadJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(type, from: data)
}

struct Animation: Decodable {
    struct Frame: Decodable { let x: Int; let y: Int; let w: Int; let h: Int }
    let frames: [Frame]
    let sheet: String
}
typealias Export = [String: [String: Animation]]

struct ManifestEntry: Decodable {
    let canvas: [Int]
    let idle_h: Int?
    let families: [String: Int]
}
typealias Manifest = [String: ManifestEntry]

let export = (try? loadJSON(Export.self, from: exportURL)) ?? [:]
check(!export.isEmpty, "workbench_export.json failed to decode at \(exportURL.path)")
let manifest = (try? loadJSON(Manifest.self, from: packsRoot.appendingPathComponent("packs_manifest.json"))) ?? [:]
check(!manifest.isEmpty, "packs_manifest.json failed to decode")

/// {character: pack} — which pack directory holds this character's frames.
/// Derived from the manifest's ids (never from filename guessing: "sans"
/// vs "sansdt" prefixes make a regex split ambiguous).
func detectPacks() -> [String: String] {
    var result: [String: String] = [:]
    for id in manifest.keys.sorted() {
        for pack in ["undertale", "deltarune", "oneshot", "hollowknight"] {
            let dir = packsRoot.appendingPathComponent(pack).appendingPathComponent("Sprites")
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            // Exact prefix boundary: "sans_" must not match "sansdt_".
            if names.contains(where: { $0.hasPrefix("\(id)_") && $0.hasSuffix(".png") }) {
                result[id] = pack
                break
            }
        }
    }
    return result
}
let packOf = detectPacks()

func diskFamilies(character: String, pack: String) -> [String: Int] {
    let dir = packsRoot.appendingPathComponent(pack).appendingPathComponent("Sprites")
    guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [:] }
    var counts: [String: Int] = [:]
    for name in names where name.hasPrefix("\(character)_") && name.hasSuffix(".png") {
        let stem = name.dropLast(4)
        let parts = stem.dropFirst(character.count + 1)
        guard let lastUnderscore = parts.lastIndex(of: "_"),
              let frameNumber = Int(parts[lastUnderscore...].dropFirst())
        else { continue }
        guard (1...99).contains(frameNumber) else { continue }
        let family = String(parts[..<lastUnderscore])
        counts[family, default: 0] += 1
    }
    return counts
}

// MARK: - PNG analysis

func pngImage(at url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

// MARK: - Check 1: every labeled rect inside its sheet

print("1. Workbench rects within sheet bounds")
do {
    var sizeCache: [String: (Int, Int)] = [:]
    for (character, animations) in export.sorted(by: { $0.key < $1.key }) where !character.hasPrefix("_") {
        for (label, animation) in animations.sorted(by: { $0.key < $1.key }) {
            let key = animation.sheet
            if sizeCache[key] == nil {
                let url = sheetsRoot.appendingPathComponent(key)
                if let image = pngImage(at: url) {
                    sizeCache[key] = (image.width, image.height)
                } else {
                    fail("\(character)/\(label): sheet unreadable — \(url.path)")
                    sizeCache[key] = (0, 0)
                }
            }
            guard let (sw, sh) = sizeCache[key] else { continue }
            for frame in animation.frames {
                check(frame.x >= 0 && frame.y >= 0 && frame.w > 0 && frame.h > 0,
                      "\(character)/\(label): degenerate rect \(frame)")
                check(frame.x + frame.w <= sw && frame.y + frame.h <= sh,
                      "\(character)/\(label): rect \(frame) exceeds sheet \(sw)x\(sh)")
            }
        }
    }
}

// MARK: - Check 2: manifest agrees with disk

print("2. Manifest families match disk files")
let workbenchCharacters = ["sans", "papyrus", "toriel", "frisk", "flowey", "temmie",
                           "monsterkid", "annoyingdog", "kris", "ralsei", "susie", "niko"]
for character in workbenchCharacters {
    guard let pack = packOf[character] else {
        fail("\(character): no sprite files on disk in any pack")
        continue
    }
    let disk = diskFamilies(character: character, pack: pack)
    guard let entry = manifest[character] else {
        fail("\(character): missing from packs_manifest.json")
        continue
    }
    let diskOnly = Set(disk.keys).subtracting(entry.families.keys)
    let manifestOnly = Set(entry.families.keys).subtracting(disk.keys)
    check(diskOnly.isEmpty, "\(character): families on disk but not in manifest: \(diskOnly.sorted())")
    check(manifestOnly.isEmpty, "\(character): families in manifest but not on disk: \(manifestOnly.sorted())")
    for (family, count) in entry.families.sorted(by: { $0.key < $1.key }) {
        check(count == disk[family],
              "\(character)/\(family): manifest says \(count) frames, disk has \(disk[family] ?? 0)")
    }
}

// MARK: - Check 3: roster geometry (parsed from source) agrees with manifest

print("3. Roster geometry matches manifest")
do {
    let rosterSource = try String(contentsOf: rosterURL, encoding: .utf8)
    // Matches: spritePrefix: "id", canvasSize: CGSize(width: W, height: H), displayScale: S
    let pattern = #"spritePrefix:\s*"([^"]+)",\s*canvasSize:\s*CGSize\(width:\s*(\d+),\s*height:\s*(\d+)\),\s*displayScale:\s*([0-9.]+)"#
    let regex = try NSRegularExpression(pattern: pattern)
    let range = NSRange(rosterSource.startIndex..., in: rosterSource)
    var found = 0
    for match in regex.matches(in: rosterSource, range: range) {
        guard let idRange = Range(match.range(at: 1), in: rosterSource),
              let wRange = Range(match.range(at: 2), in: rosterSource),
              let hRange = Range(match.range(at: 3), in: rosterSource),
              let sRange = Range(match.range(at: 4), in: rosterSource) else { continue }
        let id = String(rosterSource[idRange])
        let w = Int(rosterSource[wRange]) ?? -1
        let h = Int(rosterSource[hRange]) ?? -1
        let scale = Double(rosterSource[sRange]) ?? -1
        found += 1
        guard id != "bill" else { continue }
        guard let entry = manifest[id] else {
            fail("\(id): in roster but missing from manifest")
            continue
        }
        check(entry.canvas == [w, h],
              "\(id): roster canvas \(w)x\(h) ≠ manifest \(entry.canvas)")
        if let idleH = entry.idle_h {
            // Target ~185pt visible height, capped at 4.0 so small-pixel
            // art stays crisp instead of rendering as mushy blocks.
            let expected = (min(185.0 / Double(idleH), 4.0) * 100).rounded() / 100
            check(abs(scale - expected) < 0.03,
                  "\(id): displayScale \(scale) ≠ min(185/\(idleH), 4.0) = \(expected)")
        }
    }
    check(found >= workbenchCharacters.count,
          "roster parse found only \(found) geometry entries (expected ≥ \(workbenchCharacters.count))")
}

// MARK: - Check 4: bottom anchoring + background removal

print("4. Idle frames bottom-anchored and background-free")
struct CornerScan {
    var bottomPadding = 0
    var cornersTransparent = true
    var uniformOpaqueRing = false
}
    func analyze(_ url: URL) -> CornerScan? {
        guard let image = pngImage(at: url),
              let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let w = image.width, h = image.height
        let bpr = image.bytesPerRow
        let bpp = image.bitsPerPixel / 8
        guard image.bitsPerPixel == 32 else { return nil }
        func alphaAt(_ x: Int, _ y: Int) -> Int {
            let row = h - 1 - y // CG origin is bottom-left
            return Int(bytes[row * bpr + x * bpp + 3])
        }
        var result = CornerScan()
        scan: for y in 0..<h {
            for x in 0..<w where alphaAt(x, y) > 30 {
                result.bottomPadding = y
                break scan
            }
        }
        // Border ring: a leftover sheet background shows up as a mostly-
        // opaque, near-uniform color ringing the whole frame.
        var ringSamples: [Int] = []
        if w >= 4 && h >= 4 {
            for x in 0..<w { ringSamples.append(alphaAt(x, 0)); ringSamples.append(alphaAt(x, h - 1)) }
            for y in 0..<h { ringSamples.append(alphaAt(0, y)); ringSamples.append(alphaAt(w - 1, y)) }
            let opaque = ringSamples.filter { $0 > 30 }.count
            let ringCount = 2 * (w + h)
            if opaque > ringCount * 9 / 10 { result.uniformOpaqueRing = true }
        }
        for (x, y) in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)] {
            if alphaAt(x, y) > 10 { result.cornersTransparent = false }
        }
        return result
    }
let anchorCheckList: [(String, String)] = [
    ("sans", "undertale"), ("toriel", "undertale"), ("frisk", "undertale"),
    ("papyrus", "undertale"), ("temmie", "undertale"), ("flowey", "undertale"),
    ("annoyingdog", "undertale"), ("monsterkid", "undertale"),
    ("kris", "deltarune"), ("ralsei", "deltarune"), ("susie", "deltarune"),
    ("niko", "oneshot"), ("knight", "hollowknight"), ("hornet", "hollowknight"),
    ("sansdt", "undertale"),
]
for (character, pack) in anchorCheckList {
    let families = diskFamilies(character: character, pack: pack)
    guard let family = ["idle", "idle_still", "down", "forward-walk", "walk"]
        .first(where: { families[$0] != nil }) ?? families.keys.sorted().first else {
        fail("\(character): no families on disk at all")
        continue
    }
    let url = packsRoot.appendingPathComponent(pack).appendingPathComponent("Sprites")
        .appendingPathComponent("\(character)_\(family)_01.png")
    guard let analysis = analyze(url) else {
        fail("\(character)/\(family): idle PNG unreadable at \(url.path)")
        continue
    }
    // Workbench characters are bottom-anchored by OUR pipeline (must be 0);
    // HK sheets are aligned BY THE AUTHOR (game pivots, gaps up to ~55px on
    // uniform canvases) — the window geometry compensates rest gaps at
    // runtime (CharacterSpriteCatalog.restGap), so large gaps are legal.
    let maxGap: Int = pack == "hollowknight" ? 60 : 0
    check(analysis.bottomPadding <= maxGap,
          "\(character)/\(family): content floats \(analysis.bottomPadding)px above the canvas bottom (allowed ≤ \(maxGap))")
    check(analysis.cornersTransparent,
          "\(character)/\(family): canvas corners opaque — background not removed")
}

print("4b. Every family frame free of leftover background rings")
for character in workbenchCharacters + ["sansdt", "knight", "hornet"] {
    guard let pack = packOf[character] else { continue }
    let families = diskFamilies(character: character, pack: pack)
    for (family, count) in families.sorted(by: { $0.key < $1.key }) {
        // First frame of every family: no uniform opaque border ring
        // (the signature of an un-removed sheet background).
        let url = packsRoot.appendingPathComponent(pack).appendingPathComponent("Sprites")
            .appendingPathComponent("\(character)_\(family)_01.png")
        guard let analysis = analyze(url) else { continue }
        check(!analysis.uniformOpaqueRing,
              "\(character)/\(family): uniform opaque border ring — sheet background not removed (\(count) frames)")
    }
}

// MARK: - Check 5: directional walk rows

print("5. Directional walk families exist where labeled")
let fourDir: [(String, String, String, String, String, String)] = [
    ("frisk", "undertale", "down", "up", "left", "right"),
    ("sans", "undertale", "down", "up", "left", "right"),
    ("toriel", "undertale", "down", "up", "left", "right"),
    ("kris", "deltarune", "walk-forward", "walk-back", "walk-left", "walk-right"),
    ("ralsei", "deltarune", "light-walk-down", "light-walk-up", "walk-left", "walk-right"),
    ("susie", "deltarune", "walk-down-dark-face", "walk-up-dark", "walk-left", "walk-right"),
    ("niko", "oneshot", "forward-walk", "walk-backwards", "left-walk", "right-walk"),
]
for (character, pack, down, up, left, right) in fourDir {
    let families = diskFamilies(character: character, pack: pack)
    for (direction, family) in [("down", down), ("up", up), ("left", left), ("right", right)] {
        check(families[family] != nil,
              "\(character): \(direction) walk family '\(family)' missing (has: \(families.keys.sorted()))")
    }
}

// MARK: - Check 6: every manifest character has a rest-capable family

print("6. Every manifest character resolvable to a rest pose")
for (character, entry) in manifest.sorted(by: { $0.key < $1.key }) {
    let hasRest = entry.families["idle"] != nil
        || entry.families["down"] != nil
        || entry.families["idle_still"] != nil
        || entry.families["idle-still"] != nil
        || !entry.families.isEmpty
    check(hasRest, "\(character): no rest-capable family in manifest")
}

// MARK: - Verdict

print("")
if failures == 0 {
    print("SPRITE VALIDATION PASSED — \(checks) checks, 0 failures")
    exit(0)
} else {
    print("SPRITE VALIDATION FAILED — \(failures) failure(s) out of \(checks) checks")
    exit(1)
}
