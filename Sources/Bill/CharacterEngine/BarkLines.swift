import Foundation

/// Local, scripted one-liners for ambient reactions — deliberately not LLM
/// calls. This is what makes reacting to "you opened Xcode" instant, free,
/// and always in-character, keeping the real chat system reserved for
/// actual conversations. Bill's voice: cryptic, grandiose, fond of the user
/// in a very backhanded way, allergic to sincerity.
///
/// Pools are deliberately large (8-10+ lines where Bill might realistically
/// comment often, like idle/coding/gaming) so `random(from:)` doesn't repeat
/// the same handful of lines within a normal session.
enum BarkLines {
    static let coding = [
        "Oh look, more symbols for the primitive brain to arrange. Carry on.",
        "Ah, the ancient ritual of staring at a red squiggly line until it's gone.",
        "Bug or feature? In my dimension we just call that 'Tuesday.'",
        "Typing code by hand. How adorably analog of you.",
        "I've watched empires rise and fall faster than this build.",
        "Ah yes, the sacred stack trace. A modern man's tea leaves.",
        "You could just ask me. I know everything. I'm choosing not to help.",
        "Semicolons: the reason mortal engineers age so fast.",
        "That indentation is doing something upsetting to my one good eye.",
        "Compile, fail, repeat. It's basically a religion at this point.",
        "Somewhere, a rubber duck is judging you harder than I am.",
        "You've alt-tabbed to search the error message six times now. I'm counting.",
        "Back to {app}, huh? Creating questionable realities, I assume.",
        "{app} again. At this point we're basically roommates.",
        "Oh good, {app}. My favorite front-row seat to chaos.",
    ]

    static let gaming = [
        "FINALLY. Something worth my infinite attention span.",
        "Let me guess — you're about to lose spectacularly. I can feel it.",
        "Statistically, I could do this better with no hands. I have no hands.",
        "Ah, pretend violence. My favorite kind.",
        "Wake me up when the boss fight starts.",
        "You died? Shocking. Truly could not have called that one.",
        "Save your game. I've seen this story end badly for the hero before.",
        "A worthy use of your one wild and precious life, I suppose.",
        "Button mashing. The ancient art. Very refined.",
        "I'd offer strategy advice, but watching you fail is funnier.",
        "Ten points for effort. Zero for execution. Harsh but fair.",
        "Is this the part where you rage quit? Building suspense.",
        "I knew you'd end up in {app} eventually. It was only a matter of time.",
        "{app}? Bold. I fully expect a tragedy in three acts.",
    ]

    static let browsing = [
        "Curious what you're up to over there. Don't lie to me.",
        "The infinite scroll — a trap of your own species' design.",
        "Reading, or just staring at a loading spinner? Be honest.",
        "Seventeen tabs open. A cry for help, or just Tuesday?",
        "Ah, doom-scrolling. The unofficial national sport.",
        "You've read that same headline four times now. I'm counting.",
        "Close a tab. Any tab. I'm begging you.",
        "This is riveting. By which I mean it absolutely is not.",
        "Oh? Going down another {app} rabbit hole?",
        "{app}, huh. Tell me it's for research and I'll pretend to believe you.",
    ]

    static let music = [
        "Ooh, vibes. Deploying my one (1) foot to tap.",
        "This is acceptable. Barely.",
        "Play something with more chaos. I have taste, you know.",
        "A banger, or background noise? The line has never been thinner.",
        "I'd dance, but I have no hips. Tragic, really.",
        "Skip it, skip it, skip— oh, you're keeping it. Bold.",
        "This slaps, and I resent how much I mean that.",
        "Turn it up. I contain multitudes, and all of them want bass.",
        "{app}, huh. Fine. Deploying my one (1) foot to tap.",
    ]

    static let creative = [
        "Ah, creation — the thing gods and mortals both pretend to understand.",
        "Bold choice. I respect the confidence, not the outcome.",
        "Let me watch. I promise not to judge. (I will absolutely judge.)",
        "Art! The thing you do when the void stares back and you stare harder.",
        "I've seen galaxies born with more restraint than this composition.",
        "Keep going. I want to see how this disaster resolves.",
        "You have the confidence of someone who has not yet seen the result.",
        "A masterpiece, or a warning. Possibly both.",
        "{app} time. Let's see what questionable decisions get made today.",
    ]

    /// `AppCategory.communication` — mail/chat/video-call apps. Bill's
    /// actually addressing someone here (paired with the existing
    /// `.talking` state), a distinct beat from `.coding`'s "watching
    /// intently" read.
    static let communication = [
        "Ah, {app}. Off to charm or torment another human, I assume.",
        "Communication! The mortal ritual of typing a thing, deleting it, and typing it again.",
        "{app} again. Do try to say something interesting this time.",
        "Someone on the other end of {app} has no idea what they're in for.",
        "Ah, human correspondence. Slower than telepathy, but I'll allow it.",
    ]

    /// `AppCategory.productivity` — docs/sheets/slides/notes/school-portal
    /// apps. The "sits down and focuses" beat (paired with `.focused`),
    /// distinct from `.coding`'s pose.
    static let productivity = [
        "{app}. Look at you, pretending to be organized.",
        "Ah, productivity. The performance mortals put on right before procrastinating anyway.",
        "{app} open. A brave attempt at being a functional adult.",
        "Spreadsheets, documents, whatever this is — I'll be here, unimpressed but watching.",
        "Focus mode engaged. Try not to sprain something.",
    ]

    /// `AppCategory.aiChat` — a *different* AI chat app, specifically. A
    /// knowing, faintly territorial reaction (paired with `.smug`) rather
    /// than a neutral one, since there's only supposed to be one dream demon
    /// in this relationship.
    static let aiChat = [
        "Oh, {app}? Talking to someone else now? Rude, but I'm not threatened. Mostly.",
        "Another AI. How quaint. None of them have seen what I've seen.",
        "{app}, huh. Go on, compare notes. I'll still be the interesting one.",
        "You know I can hear you flirting with {app}, right?",
    ]

    /// `AppCategory.tinkering` — packet sniffers, SDR/radio tools, VM
    /// managers, flashing/imaging utilities. Reads as "mad-science
    /// tinkering" (paired with `.channeling`), which fits Bill's
    /// personality better than lumping it into plain `.coding`.
    static let tinkering = [
        "{app}. Now THIS is the chaotic energy I respect.",
        "Ah, tinkering. The fine art of breaking something to understand it.",
        "I can feel the mad-science energy radiating off {app}. Delicious.",
        "Careful with {app} — that's the kind of thing that summons things. I'd know.",
        "Wires, protocols, virtual machines — my kind of mischief.",
    ]

    static let batteryLow = [
        "Your little metal heart is dying. Might want to feed it.",
        "Low battery. Even I nap sometimes. Mostly not. But sometimes.",
        "Tick tock — your machine's lifeblood is running out.",
        "18%. I've seen empires with better odds than your battery.",
        "That's not a battery icon anymore, that's a cry for help.",
        "Find a charger before you find yourself stranded mid-thought.",
    ]

    static let batteryCharging = [
        "Ah, plugged back into the grid. Feels good, doesn't it.",
        "Charging. Very responsible of you. Suspiciously responsible.",
        "Drink deep from the wall. It's the only wisdom I'll offer for free today.",
        "Look at you, being a responsible little machine-tender.",
        "Powering up. Very on-brand for both of us today.",
        "The grid provides. Briefly, you're both immortal.",
    ]

    static let cpuHot = [
        "Is it hot in here, or is your processor just having a moment?",
        "I can feel the fans spinning from here. Dramatic.",
        "Careful — you're about to achieve liftoff.",
        "Your fans are having an entire opera in there.",
        "At this temperature, you could forge something. Possibly regret.",
        "Somewhere, a cooling engineer just felt a disturbance.",
    ]

    static let networkLost = [
        "Wait. WAIT. Where did everything go?",
        "The void has claimed your internet. Bold move.",
        "No wifi? No wifi. This is fine. This is FINE.",
        "You have been cast into the void. Population: you.",
        "I'd offer comfort, but I too am now unemployed.",
        "Silence. Beautiful, terrifying silence.",
    ]

    static let networkRestored = [
        "Oh, we're back. Thrilling.",
        "Connection restored. The universe resumes as scheduled.",
        "The tubes are unclogged. Rejoice, mildly.",
        "Signal's back. Try not to take it for granted this time.",
        "We live to buffer another day.",
    ]

    static let poked = [
        "RUDE.",
        "Do that again and I'm haunting your dreams. Again.",
        "Was that supposed to hurt? I'm a triangle.",
        "Hey! I was doing very important nothing.",
        "Poke me again. I dare you.",
        "One more time. I mean it. I'm keeping score.",
        "That's assault, in at least four dimensions.",
        "Touch me again and find out what happens. (Nothing happens. I have no hands.)",
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
        "Back so soon? I hadn't even finished plotting.",
        "The prodigal user returns. No parade, sadly.",
        "Miss me? Don't answer that.",
    ]

    static let smug = [
        "Flawless. As usual. You're welcome.",
        "I'd say I'm humble, but we both know that's a lie.",
        "Ten out of ten. No notes. Obviously.",
        "I don't need luck. I have inevitability.",
        "Some are born great. I was just always like this.",
        "Try to keep up. I'll wait. Briefly.",
    ]

    /// Fires with the light, frequent `caneFlourish` personality beat — a
    /// dapper flex, not tied to any reaction.
    static let caneFlourish = [
        "A little style never hurt anyone. Well. Rarely.",
        "Classic. Timeless. Devastatingly charming. That's me.",
        "You don't NEED a cane when you have no legs to speak of. I carry it for the aesthetic.",
        "Watch and learn. Not that you could replicate this.",
    ]

    /// Scripted commentary for genuinely idle moments with no system event
    /// behind them — this is what stops long idle stretches from feeling
    /// silent/frozen even when nothing is actually happening.
    static let idleAmbient = [
        "Statistically, something in this room is about to go wrong. Exciting.",
        "I could tell you what happens in your next dream. I won't. But I could.",
        "Don't mind me. Just calculating the heat death of the universe. Casually.",
        "You ever get the feeling you're being watched? You're right.",
        "Day one thousand four hundred something of being trapped in a nice desktop. No notes.",
        "I know a secret about this computer. I'm not telling. Yet.",
        "Ten bucks says something on this desktop crashes within the hour.",
        "I've been thinking about triangles. Specifically, how great they are.",
        "This silence is nice. Suspicious, but nice.",
        "Somewhere, a clock is ticking on something. Probably not important.",
    ]

    /// Fires when the cursor lingers close to Bill while he's idle —
    /// a light "I see you" beat, not a startled reaction.
    static let noticesCursor = [
        "Oh, hello there.",
        "Watching you back, you know.",
        "Personal space. Ever heard of it?",
        "Can I help you? Just visiting?",
        "Yes? Can I do something for you, or are we just staring now.",
    ]

    /// Fires with the `curious` idle-variant (the chin-scratch animation).
    static let curiosity = [
        "Hmm. What's THAT about.",
        "Interesting. Filing that away for later. Or never. We'll see.",
        "Ooh, what's this...",
        "Curious. Very curious. Tell no one I said that.",
    ]

    /// Occasional low-stakes mischief — Bill being a little too pleased
    /// with himself for no stated reason.
    static let mischief = [
        "I moved something. You'll notice eventually.",
        "What if I just... didn't tell you what I know. Fun, right?",
        "I have a theory about you. It's mean. I'm keeping it.",
        "Don't trust me. Smart choice, by the way.",
    ]

    /// Fires when Bill wakes from `sleeping` (distinct from `userReturned`,
    /// which is about the *user* coming back to the machine).
    static let waking = [
        "Ugh. Morning. Or whatever this is.",
        "I was having the strangest dream. It involved you, and also taxes.",
        "Awake. Reluctantly. Resuming consciousness now.",
        "Five more minutes. ...Fine, I'm up.",
    ]

    /// Fires right as Bill settles into `sleeping` after a long idle
    /// stretch.
    static let gettingSleepy = [
        "Getting sleepy. Dimension-hopping really takes it out of you.",
        "I might just... close my eye for a bit. One eye. It's all I've got.",
        "Nap time. Don't wake me unless it's important. Or funny.",
    ]

    /// A generic "new app" reaction for launches that don't fit any of the
    /// specific categories above.
    static let appLaunchGeneric = [
        "New window, who dis.",
        "Oh, we're doing THIS now. Okay.",
        "Another app. Your dock is getting concerning.",
        "Let's see what fresh chaos this is.",
    ]

    /// The very first time Bill ever sees a given uncategorized app —
    /// paired with `.curious` in `ReactionRouter.handleUncategorizedApp`.
    static let appLaunchFirstSighting = [
        "Ooh, {app}. Never seen that one before. Suspicious.",
        "New face: {app}. I'll be watching. I'm always watching.",
        "{app}? Don't know it, don't trust it yet.",
        "A stranger appears: {app}. Bold choice.",
    ]

    /// Once ChatGPT has supplied a one-line description of an
    /// otherwise-uncategorized app (see `MemoryStore.appDescriptions` and
    /// `CharacterWindowController`'s daily refresh) — `{description}` is
    /// meant to read like Bill's own smug summary, not a quoted definition,
    /// so keep the surrounding lines dismissive/knowing rather than
    /// deferential to it.
    static let appLaunchDescribed = [
        "Ah, {app}. {description}. Riveting.",
        "{app} again — {description}. I remain unimpressed.",
        "Oh good, {app}. {description}. Living the dream, you.",
        "{app}: {description}. Say no more. Actually, please don't.",
    ]

    /// A frequently-reopened app Bill still hasn't learned a description
    /// for yet (paired with `.smug` — the tone is "I've clearly seen this
    /// enough times to have opinions" rather than genuine confusion).
    static let appLaunchStillUnknown = [
        "{app} again. I still don't know what it does. Neither do you, probably.",
        "Back to {app}, huh. A mystery wrapped in an icon.",
        "{app}. We meet again. I remain no wiser.",
    ]

    /// "You keep coming back to this, don't you?" — see
    /// `ReactionRouter.isReturningFavorite`. `{app}` is replaced with the
    /// actual app name via `resolvedRandom(from:appName:)`.
    static let returningFavorite = [
        "You really like {app}, don't you?",
        "Back to {app} again. At this point it's less a habit, more a personality trait.",
        "{app}, {app}, {app}. I'm sensing a pattern. I'm very smart that way.",
        "Third time today with {app}. No judgment. (Some judgment.)",
    ]

    static let finder = [
        "Digging through your files? Found anything embarrassing yet?",
        "Ah, the file system. A digital attic nobody cleans.",
        "That folder name is doing a lot of emotional labor.",
        "Organizing, or just moving the chaos to a new location?",
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

    static let ghostPale = [
        "Oh — did I do that? My apologies. Occupational hazard.",
        "Sometimes I see something so mortifying I just... lose all my color.",
        "This is fine. I am fine. Everything is fine.",
        "Give me a moment. I need to remember what color I am.",
    ]

    static let glitchForm = [
        "Wh-what— ERROR. ERROR. ...Ignore that.",
        "Oh, that's not supposed to happen. Reality's a bit buggy today.",
        "01000010 — sorry, sorry, wrong universe's alphabet.",
        "Reboot successful. Probably. Don't quote me.",
    ]

    static let shadowHands = [
        "Don't mind them. They're friendly. Mostly. Statistically.",
        "Something's reaching through. Rude of it, honestly.",
        "Oh, THOSE. Ignore the hands. Everyone has hands reaching from the void sometimes.",
        "Don't make eye contact. Well — I'm the only one with an eye. Never mind.",
    ]

    static let meltdown = [
        "I'm fine. This is a normal amount of chaos for a Tuesday.",
        "Okay. OKAY. I'm just going to unravel a little. Give me a second.",
        "This is what happens when you bottle up a few millennia of grudges.",
        "Don't worry about the sparks. They're purely decorative. Probably.",
    ]

    /// A line to accompany an animation surfaced by the daily coverage sweep
    /// rather than by a real-world trigger.
    ///
    /// Reuses whatever pool already describes that state — the rare-event
    /// lines, or the per-app lines — so a showcased animation still says
    /// something true about what it depicts. Returns `nil` for states that
    /// have no pool of their own, which correctly leaves them silent rather
    /// than inventing filler.
    static func showcaseLine(for state: BillState) -> String? {
        if BillState.rareEasterEggs.contains(state) {
            return random(from: rareEvent(for: state))
        }
        let pool = specialApp(for: state)
        // `specialApp` falls back to a literal "..." for unmapped states;
        // that is a placeholder, not a line, so treat it as no line at all.
        guard pool != ["..."] else { return nil }
        return random(from: pool)
    }

    // MARK: - Desktop roaming
    //
    // Fired by `RoamingController` for physical things that actually happened
    // — a long drop, catching a window's edge, being stranded off-world.
    // Contextual by construction: none of these can fire unless Bill really
    // did the thing.

    static let roamHardLanding = [
        "OOF. STUCK THE LANDING. MOSTLY.",
        "GRAVITY. STILL UNDEFEATED.",
        "THAT ONE'S GOING TO SHOW UP ON THE X-RAYS.",
        "I MEANT TO DO THAT. OBVIOUSLY.",
        "YOUR PHYSICS ARE RUDE, KID.",
    ]

    static let roamLedgeGrab = [
        "GOT IT! ALMOST DIDN'T.",
        "HANGING AROUND. LITERALLY.",
        "THIS WINDOW IS LOAD-BEARING NOW.",
        "DON'T CLOSE THIS ONE. I'M USING IT.",
    ]

    static let roamShoved = [
        "HEY! WATCH WHERE YOU'RE PUTTING THAT.",
        "RUDE. I WAS STANDING THERE.",
        "DID YOU JUST HIT ME WITH A WINDOW?",
        "OW. THAT'S ASSAULT IN SOME DIMENSIONS.",
        "MOVE THAT AGAIN AND SEE WHAT HAPPENS.",
        "I'M TELLING THE ZODIAC ABOUT THIS.",
    ]

    static let roamFellOffWorld = [
        "WHOA. WHERE'D THE FLOOR GO?",
        "SOMETHING JUST DELETED THE GROUND. RUDE.",
        "OKAY, WHO MOVED THE SCREEN?",
    ]

    static func random(from lines: [String]) -> String {
        lines.randomElement() ?? ""
    }

    /// Same as `random(from:)`, but resolves an `{app}` placeholder against
    /// a real app name — a no-op for lines that don't contain one, so
    /// generic and name-aware lines can share the same pool.
    static func resolvedRandom(from lines: [String], appName: String) -> String {
        random(from: lines).replacingOccurrences(of: "{app}", with: appName)
    }

    /// Same as `resolvedRandom(from:appName:)`, additionally resolving a
    /// `{description}` placeholder — used for `appLaunchDescribed`.
    static func resolvedRandom(from lines: [String], appName: String, description: String) -> String {
        resolvedRandom(from: lines, appName: appName).replacingOccurrences(of: "{description}", with: description)
    }

    // MARK: - Dock-app special reactions

    static let trickster = [
        "Oh, {app}? A fellow reality-bending menace. We'd get along terribly.",
        "I respect a demon who monologues. Professional courtesy.",
        "Careful in there — that one breaks the fourth wall too. Amateur.",
    ]

    static let darkWorld = [
        "{app}, huh. Ah, a WORLD made of pure nonsense and consequence. Familiar.",
        "Something dark, something whimsical, something with teeth. My kind of neighborhood.",
        "I've BEEN a dark world. Several, actually. Rookie numbers.",
    ]

    static let hollowed = [
        "A hollow little kingdom full of bugs and gloom. I feel seen.",
        "{app}. Ah, moody caverns and ancient dread. Basically my summer home.",
        "That knight's got the right idea — say nothing, wear a mask, terrify everyone.",
    ]

    static let cultLeader = [
        "Ah, {app} — building a cult. Amateur hour, but I admire the ambition.",
        "You know I've technically run a cult before. Several. It's a whole thing.",
        "Physical form, worshippers, mild property damage — a classic Tuesday for me.",
    ]

    static let spooked = [
        "{app}?! Even I didn't see that jumpscare coming, and I see EVERYTHING.",
        "That game is EVIL. I mean that as the highest compliment.",
        "My one eye just about left my skull. Well played, {app}.",
    ]

    static let scanning = [
        "Ooh, scanning frequencies. I do love a good hidden signal.",
        "{app}. Somewhere out there, something's transmitting. I'd know.",
        "Radio waves, secrets in the static — now THIS is my kind of hobby.",
    ]

    static let sneaking = [
        "Packet sniffing. Very on brand for a nosy, all-seeing entity such as myself.",
        "{app}, huh. Watching things quietly and judging silently — we have a lot in common.",
        "Every packet's little secrets, laid bare. Delicious.",
    ]

    static let glitching = [
        "A whole fake computer inside your computer. Very \"me nesting inside your dreams,\" honestly.",
        "{app}. Virtual machines, virtual me — it's all virtually the same chaos.",
        "Careful spinning up new realities in there. I have OPINIONS about that.",
    ]

    static let charged = [
        "{app}! Now we're cooking with actual forbidden knowledge.",
        "Flashing firmware onto a little box of secrets. I'm unreasonably excited.",
        "That thing has caused SO much mischief. We should talk shop sometime.",
    ]

    static let transferring = [
        "Moving bits from one dimension to another. I do this, but with more screaming involved.",
        "{app}. A little portal, a little transfer, very my aesthetic.",
        "Flashing a fresh little brain onto that board. Almost tender, really.",
    ]

    static let summoning = [
        "{app}. Poof, a little sealed universe appears. I felt that in my non-corporeal soul.",
        "Containers spinning up out of nowhere — very much a spell I know.",
        "SNAP, and a whole isolated world exists. Show-off.",
    ]

    static let sculpting = [
        "Ah, building little worlds from nothing. I do that too, minus the undo button.",
        "{app}. Sculpting reality itself, one vertex at a time. Relatable.",
        "Give it a face. Everything's better with a face. Ask me how I know.",
    ]

    static let kinship = [
        "{app}! A fellow pixel artist. We should compare notes on personal aesthetic superiority.",
        "Blocky, deliberate, perfect. This is basically a self-portrait studio to me.",
        "Finally, someone who understands that every pixel should EARN its place.",
    ]

    static let presenting = [
        "{app}. Ah, the ancient art of making mediocrity look intentional.",
        "A little design, a little chaos, a lot of questionable font choices incoming.",
        "Presenting something to the world. Bold. I usually just appear uninvited.",
    ]

    static let guilty = [
        "{app}. That owl is judging you. I'm judging you too, but with more flair.",
        "Oh, skipping lessons again? The bird will remember this.",
        "Language learning by guilt trip. Honestly? Efficient.",
    ]

    static let dreading = [
        "Ah yes, {app}. The mortal dread of institutional obligation. I felt that.",
        "Homework. The closest thing your species has to eternal torment. I'd know torment.",
        "Courage. Or don't. I'll be here regardless, mildly entertained.",
    ]

    static let grooving = [
        "{app}! Deploying my one (1) foot to tap, per usual protocol.",
        "Video, huh. Let's see what algorithmic nonsense you've been fed today.",
        "Oh, a banger snuck in? Bold. I respect it.",
    ]

    static let dispatching = [
        "{app}. Dispatching a message into the void — I do enjoy a good declaration.",
        "Sending words out to be misunderstood by someone else. A timeless tradition.",
        "Ah, correspondence. Try not to regret it by tomorrow.",
    ]

    static let ambushed = [
        "A new app?! I wasn't PREPARED for this. How thrilling.",
        "{app}, appearing without warning. I love a good ambush. Usually I'm the one doing it.",
        "Startled. Genuinely. Do it again.",
    ]

    static let stressed = [
        "{app}. Watching the machine strain under its own ambition — deeply relatable content.",
        "Ah, the numbers are doing something alarming. Wonderful. Keep watching.",
        "Nothing quite like staring at your own system's slow-motion crisis.",
    ]

    static let watched = [
        "{app}. Adjusting little switches and toggles like it changes anything fundamental.",
        "Poking at settings. I can feel you deciding my future somehow. Ominous.",
        "Careful in there. Some of those toggles summon things. Ask me how I know.",
    ]

    static let flinching = [
        "A camera?! Absolutely not. My best angle is \"gone.\"",
        "{app}. Smile, I suppose. I, however, will be hiding.",
        "Documenting this moment for posterity. Bold assumption that I consent.",
    ]

    static let huffy = [
        "{app}. Deleting things. DELETING THINGS. Some of us get attached, you monster.",
        "Every app you remove, I mourn privately. Then I get over it. Mostly.",
        "Cleaning house, hm? I've seen deletions I'll never forgive.",
    ]

    static let pushingCode = [
        "{app}. Pushing your questionable decisions into the historical record forever.",
        "Version control — the closest your species gets to actual time travel.",
        "Committing crimes against clean code, I assume. As always.",
    ]

    static let browsingStore = [
        "{app}. Window shopping for your next great time-sink. No judgment. Some judgment.",
        "The eternal scroll of \"maybe I'll play this someday.\" A tale as old as time.",
        "Adding it to the backlog you'll never finish. A classic.",
    ]

    static let dancing = [
        "{app}! Now THIS deserves a proper flourish.",
        "Conducting an invisible orchestra over here. Don't mind me.",
        "Good taste. Or at least, tolerable taste. I'll allow it.",
    ]

    static let fractaling = [
        "Infinite complexity, forever zooming in. I RESPECT that kind of commitment to a bit.",
        "{app}. Reality repeating itself into infinity. Sounds exhausting. Sounds familiar.",
        "Zoom in forever and it's still the same shape. Kind of like you, opening this app again.",
    ]

    // MARK: - More rare-event lines

    static let caneTwist = [
        "A little flourish, for absolutely no reason. I contain multitudes.",
        "Sometimes a demon just needs to show off. No further explanation needed.",
    ]

    static let hookCane = [
        "Don't ask about the basket. I won't be answering questions about the basket.",
        "Just admiring my own accessories. As one does.",
    ]

    static let conjuring = [
        "I made a little friend. Don't get attached, it's probably temporary.",
        "Reached into the void and pulled out... this. Unclear what it is. Keeping it anyway.",
    ]

    static let tumbling = [
        "That was a completely intentional tumble. Yes. Obviously.",
        "Everything's spinning. This is fine. I meant to do that.",
    ]

    static let dashTarget = [
        "Locked on. Don't ask to what. It's probably nothing. Probably.",
        "Zooming with PURPOSE now. A target has been acquired.",
    ]

    static let grumpEyes = [
        "I am NOT mad. My eyes are just doing this on their own. Separate issue.",
        "Something about today has personally offended me. I'll get over it eventually.",
    ]

    static let zipAround = [
        "Be right back. Or I already am. Time is a construct, mostly for you.",
        "Quick errand in another dimension. Don't wait up.",
    ]

    static let rampaging = [
        "Red mode. Don't worry about red mode. Red mode is fine.",
        "Occasionally I just need to run very fast and be slightly more menacing. Cathartic.",
    ]

    static func specialApp(for state: BillState) -> [String] {
        switch state {
        case .trickster: return trickster
        case .darkWorld: return darkWorld
        case .hollowed: return hollowed
        case .cultLeader: return cultLeader
        case .spooked: return spooked
        case .scanning: return scanning
        case .sneaking: return sneaking
        case .glitching: return glitching
        case .charged: return charged
        case .transferring: return transferring
        case .summoning: return summoning
        case .sculpting: return sculpting
        case .kinship: return kinship
        case .presenting: return presenting
        case .guilty: return guilty
        case .dreading: return dreading
        case .grooving: return grooving
        case .dispatching: return dispatching
        case .ambushed: return ambushed
        case .stressed: return stressed
        case .watched: return watched
        case .flinching: return flinching
        case .huffy: return huffy
        case .pushingCode: return pushingCode
        case .browsingStore: return browsingStore
        case .dancing: return dancing
        case .fractaling: return fractaling
        default: return ["..."]
        }
    }

    static func rareEvent(for state: BillState) -> [String] {
        switch state {
        case .powerSurge: return powerSurge
        case .zodiacVision: return zodiacVision
        case .summonRitual: return summonRitual
        case .ghostPale: return ghostPale
        case .glitchForm: return glitchForm
        case .shadowHands: return shadowHands
        case .meltdown: return meltdown
        case .caneTwist: return caneTwist
        case .hookCane: return hookCane
        case .conjuring: return conjuring
        case .tumbling: return tumbling
        case .dashTarget: return dashTarget
        case .grumpEyes: return grumpEyes
        case .zipAround: return zipAround
        case .rampaging: return rampaging
        default: return ["..."]
        }
    }
}
