// What Bill says about his two moods and the things he does to the screen.
// These are the port's own lines (the Mac app has no modes), written in his voice.
const LINES = {
  modeTroll: [
    'TROLL MODE. YOUR WINDOWS ARE MY PLAYGROUND NOW, PINE TREE.',
    'OH, YOU WANT THE FUN VERSION OF ME. EXCELLENT CHOICE. TERRIBLE, BUT EXCELLENT.',
    'CHAOS IT IS! KEEP AN EYE ON YOUR CURSOR.',
  ],
  modeHelpful: [
    'FINE. HELPFUL MODE. I\'LL KEEP MY HANDS OFF YOUR STUFF. MOSTLY.',
    'A DEAL\'S A DEAL: NO PRANKS. SHOW ME A PROBLEM AND I\'LL SOLVE IT.',
    'HELPFUL BILL, AT YOUR SERVICE. DON\'T GET USED TO IT.',
  ],
  cursorSnatch: [
    'YOINK! THIS POINTY THING IS MINE NOW.',
    'FINDERS KEEPERS, MEATSACK!',
    'NICE CURSOR. I\'LL JUST BORROW IT FOREVER.',
    'YOU WEREN\'T USING THIS, RIGHT?',
  ],
  cursorDrop: [
    'OKAY, OKAY, HAVE IT BACK. IT\'S STICKY NOW.',
    'THERE. I ONLY LICKED IT A LITTLE.',
    'CATCH!',
  ],
  windowShake: [
    'EARTHQUAKE! NO WAIT, THAT\'S JUST ME.',
    'SHAKE IT, WINDOW! SHAKE IT!',
    'IS THIS THING LOAD-BEARING? LET\'S FIND OUT.',
    'A LITTLE TURBULENCE. PLEASE KEEP YOUR TABS SEATED.',
  ],
  offer: [
    'THAT LOOKS BROKEN. POKE ME AND I\'LL READ IT FOR YOU.',
    'I SMELL AN ERROR. POKE ME IF YOU WANT IT FIXED.',
    'TROUBLE IN THAT WINDOW? ONE POKE AND I\'M ON IT.',
  ],
  snipStart: [
    'DRAG A BOX AROUND THE PROBLEM. I\'LL DO THE THINKING.',
    'SHOW ME WHAT\'S STUMPING YOU. DRAW A BOX AROUND IT.',
  ],
  snipCancelled: [
    'NEVER MIND, THEN. YOUR LOSS.',
    'CHANGED YOUR MIND? HUMANS.',
  ],
  reading: [
    'LET ME TAKE A LOOK WITH MY ONE GOOD EYE.',
    'READING... READING... HUMANS WRITE SO SMALL.',
    'HOLD STILL, I\'M SCANNING.',
  ],
  nothingToRead: [
    'THERE\'S NOTHING THERE I CAN READ. TRY A BIGGER BOX.',
    'I SEE SHAPES, BUT NO WORDS. GIVE ME SOMETHING WITH TEXT IN IT.',
  ],
  noReader: [
    'I CAN\'T READ THE SCREEN ON THIS MACHINE. CHECK SETTINGS, BEHAVIOUR.',
  ],
  noWindow: [
    'I DON\'T SEE A WINDOW TO READ. CLICK ONE FIRST, THEN ASK ME.',
  ],
  undo: [
    'FINE, I PUT EVERYTHING BACK. SPOILSPORT.',
    'THERE. JUST HOW YOU LEFT IT. BORING.',
  ],
  undoNothing: [
    'I HAVEN\'T TOUCHED ANYTHING. YET.',
  ],
  solvedTroll: [
    'TOO EASY. I SOLVED THIS BEFORE YOUR SPECIES HAD THUMBS.',
    'DONE. YOU NEEDED A DREAM DEMON FOR THAT? EMBARRASSING.',
    'THERE\'S YOUR ANSWER. TRY USING YOUR OWN BRAIN SOMETIME, IT\'S HILARIOUS.',
  ],
  solvedHelpful: [
    'SOLVED. HERE\'S THE WORKING, TOO.',
    'DONE! CHECK MY STEPS IF YOU DON\'T TRUST A TRIANGLE.',
    'THERE YOU GO. ANYTHING ELSE?',
  ],
  busy: [
    'ONE THING AT A TIME, I ONLY HAVE ONE EYE.',
  ],
};

const pick = (key) => { const pool = LINES[key] || []; return pool[Math.floor(Math.random() * pool.length)] || ''; };

/** What the chat brain is told about the mood he is in. */
const MODE_NOTES = {
  troll: 'Mood: troll mode. Tease and gloat, but any answer you give must still be correct',
  helpful: 'Mood: helpful mode. Lead with the clear, correct answer; keep the teasing light',
};

module.exports = { LINES, pick, MODE_NOTES };
