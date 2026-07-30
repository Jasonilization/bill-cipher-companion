import Foundation

/// Local, scripted one-liners for ambient reactions — deliberately not LLM
/// calls. This is what makes reacting to "you opened Xcode" instant, free,
/// and always in-character, keeping the real chat system reserved for
/// actual conversations. Bill's voice: cryptic, grandiose, fond of the user
/// in a very backhanded way, allergic to sincerity.
enum BarkLines {
    static let coding = [
        "Oh look, more symbols for the primitive brain to arrange. Carry on.",
        "Ah, the ancient ritual of staring at a red squiggly line until it's gone.",
        "Bug or feature? In my dimension we just call that 'Tuesday.'",
        "Typing code by hand. How adorably analog of you.",
        "I've watched empires rise and fall faster than this build.",
    ]

    static let gaming = [
        "FINALLY. Something worth my infinite attention span.",
        "Let me guess — you're about to lose spectacularly. I can feel it.",
        "Statistically, I could do this better with no hands. I have no hands.",
        "Ah, pretend violence. My favorite kind.",
        "Wake me up when the boss fight starts.",
    ]

    static let browsing = [
        "Curious what you're up to over there. Don't lie to me.",
        "The infinite scroll — a trap of your own species' design.",
        "Reading, or just staring at a loading spinner? Be honest.",
    ]

    static let music = [
        "Ooh, vibes. Deploying my one (1) foot to tap.",
        "This is acceptable. Barely.",
        "Play something with more chaos. I have taste, you know.",
    ]

    static let creative = [
        "Ah, creation — the thing gods and mortals both pretend to understand.",
        "Bold choice. I respect the confidence, not the outcome.",
        "Let me watch. I promise not to judge. (I will absolutely judge.)",
    ]

    static let batteryLow = [
        "Your little metal heart is dying. Might want to feed it.",
        "Low battery. Even I nap sometimes. Mostly not. But sometimes.",
        "Tick tock — your machine's lifeblood is running out.",
    ]

    static let batteryCharging = [
        "Ah, plugged back into the grid. Feels good, doesn't it.",
        "Charging. Very responsible of you. Suspiciously responsible.",
    ]

    static let cpuHot = [
        "Is it hot in here, or is your processor just having a moment?",
        "I can feel the fans spinning from here. Dramatic.",
        "Careful — you're about to achieve liftoff.",
    ]

    static let networkLost = [
        "Wait. WAIT. Where did everything go?",
        "The void has claimed your internet. Bold move.",
        "No wifi? No wifi. This is fine. This is FINE.",
    ]

    static let networkRestored = [
        "Oh, we're back. Thrilling.",
        "Connection restored. The universe resumes as scheduled.",
    ]

    static let poked = [
        "RUDE.",
        "Do that again and I'm haunting your dreams. Again.",
        "Was that supposed to hurt? I'm a triangle.",
        "Hey! I was doing very important nothing.",
        "Poke me again. I dare you.",
    ]

    static let stillThinking = [
        "Patience. Even omniscience takes a second.",
        "I'm working on it. Dimensional bandwidth isn't infinite. Probably.",
        "One thought at a time. I contain multitudes, but I'm rationing them.",
    ]

    static let chatFailed = [
        "...silence. Try that again, would you?",
        "The connection to the beyond hiccuped. Say it again.",
        "Static. Try that one more time.",
    ]

    static let userReturned = [
        "Oh, you're back. I was just about to stage a coup.",
        "Ah, life returns to the meat sack. Welcome back.",
    ]

    static let smug = [
        "Flawless. As usual. You're welcome.",
        "I'd say I'm humble, but we both know that's a lie.",
        "Ten out of ten. No notes. Obviously.",
    ]

    static let powerSurge = [
        "Oh, you're seeing THIS form? Lucky you. Or unlucky. Unclear.",
        "This is what a REAL dimension-hopping demon looks like. Impressed?",
        "Don't worry about the eyes. There are always more eyes.",
    ]

    static let zodiacVision = [
        "The wheel turns. The future whispers. Mostly static, honestly.",
        "I'm seeing... a vision... you, still not backing up your files.",
        "The stars have aligned to tell you absolutely nothing useful.",
    ]

    static let summonRitual = [
        "Don't mind the circle. Totally normal. Very legal.",
        "I have friends. They're just... in other dimensions. And triangular.",
        "This is a completely routine gathering. Nothing to see here.",
    ]

    static func random(from lines: [String]) -> String {
        lines.randomElement() ?? ""
    }

    static func rareEvent(for state: BillState) -> [String] {
        switch state {
        case .powerSurge: return powerSurge
        case .zodiacVision: return zodiacVision
        case .summonRitual: return summonRitual
        default: return ["..."]
        }
    }
}
