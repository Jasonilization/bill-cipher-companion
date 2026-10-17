import SpriteKit
import AppKit

/// Loads one character's pixel-art frame families on demand — the pack
/// counterpart of `BillSpriteCatalog`. Every frame already shares the
/// character's one canvas size and bottom-center alignment (baked by
/// `Scripts/process_pack_sprites.py`), so the anti-snap guarantees of the
/// Bill pipeline carry over unchanged, and nearest-neighbor filtering keeps
/// every pixel crisp at any `displayScale`.
///
/// Textures are cached per family on first use; a family the character
/// simply doesn't have resolves to `[]` and `CharacterAnimationLibrary`
/// falls back gracefully — a missing beat never crashes or stalls.
@MainActor
final class CharacterSpriteCatalog {
    let definition: CharacterDefinition
    private var cache: [String: [SKTexture]] = [:]
    /// Set once at init; every state settles back onto it.
    let restTexture: SKTexture
    /// The rest frame's transparent bottom margin in source pixels — see
    /// the init's doc comment; the window geometry compensates it.
    private(set) var restGap: Int = 0

    /// Rows of transparent padding under the content at the texture's
    /// bottom edge. SpriteKit textures have their origin at the bottom-left.
    private static func pixelBottomGap(of texture: SKTexture) -> Int {
        let cg = texture.cgImage()
        guard let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
        guard cg.bitsPerPixel == 32 else { return 0 }
        let bpr = cg.bytesPerRow, bpp = 4
        let w = cg.width, h = cg.height
        // Scan rows from the bottom for the first opaque pixel.
        for y in 0..<h {
            let row = y // bitmap row 0 IS the bottom row for CG images
            var x = 0
            while x < w {
                if bytes[row * bpr + x * bpp + 3] > 30 { return y }
                x += 1
            }
        }
        return h
    }

    init(definition: CharacterDefinition) {
        self.definition = definition
        // Try "idle" first, then common workbench-label alternatives,
        // then ANY family's first frame — a character with no visible
        // rest texture is invisible on screen (the "characters don't
        // show" bug: workbench labels used names like "down" for idle).
        var restCandidates = ["idle", "idle_still", "idle-still", "down", "default", "defualt"]
        var idle: [SKTexture] = []
        for name in restCandidates {
            idle = Self.load(definition: definition, family: name)
            if !idle.isEmpty { break }
        }
        if idle.isEmpty {
            // Try every family until we find any frames at all
            for name in Self.allFamilyNames(definition: definition) {
                idle = Self.load(definition: definition, family: name)
                if !idle.isEmpty { break }
            }
        }
        if let first = idle.first {
            restTexture = first
        } else {
            print("CharacterSpriteCatalog: \(definition.id) has NO frames — invisible")
            restTexture = SKTexture(image: NSImage(size: NSSize(width: 1, height: 1)))
        }
        cache["idle"] = idle
        // The rest frame's bottom gap, in source pixels: uniform-canvas
        // sheets (Hollow Knight's named frames) position content per the
        // game's pivot, NOT at the canvas bottom — a 27px gap here would
        // read as the character floating that far off the floor. The
        // window geometry subtracts `restGapPoints` from the body anchor
        // so visual feet land where everyone else's do. Workbench
        // characters are bottom-anchored, so this is 0 for them.
        restGap = Self.pixelBottomGap(of: restTexture)
    }

    /// Every family this character ships with, from the manifest.
    var familyNames: [String] {
        Self.allFamilyNames(definition: definition)
    }

    /// Scans the bundle for every family this character ships with.
    private static func allFamilyNames(definition: CharacterDefinition) -> [String] {
        var names: [String] = []
        guard let dirURL = Bundle.module.url(
            forResource: "packs_manifest",
            withExtension: "json",
            subdirectory: "Packs"
        ), let data = try? Data(contentsOf: dirURL),
           let manifest = try? JSONDecoder().decode([String: ManifestInfo].self, from: data),
           let info = manifest[definition.id]
        else { return names }
        return info.families.keys.sorted()
    }

    private struct ManifestInfo: Codable {
        let canvas: [Int]
        let idle_h: Int?
        let families: [String: Int]
    }

    /// The frames of `family`, in order. Empty when the family is absent.
    func frames(_ family: String) -> [SKTexture] {
        if let cached = cache[family] { return cached }
        let loaded = Self.load(definition: definition, family: family)
        cache[family] = loaded
        return loaded
    }

    private static func load(definition: CharacterDefinition, family: String) -> [SKTexture] {
        var textures: [SKTexture] = []
        var index = 1
        while true {
            let name = String(format: "%@_%@_%02d", definition.spritePrefix, family, index)
            guard
                let url = Bundle.module.url(
                    forResource: name,
                    withExtension: "png",
                    subdirectory: "Packs/\(definition.packID)/Sprites"
                ),
                let image = NSImage(contentsOf: url)
            else { break }
            let texture = SKTexture(image: image)
            texture.filteringMode = .nearest
            textures.append(texture)
            index += 1
        }
        return textures
    }
}
