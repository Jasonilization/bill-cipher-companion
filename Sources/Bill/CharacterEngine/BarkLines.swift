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

    static let userReturned = [
        "Oh, you're back. I was just about to stage a coup.",
        "Ah, life returns to the meat sack. Welcome back.",
    ]

    static func random(from lines: [String]) -> String {
        lines.randomElement() ?? ""
    }
}
