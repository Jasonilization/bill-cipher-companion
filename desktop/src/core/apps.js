// Port of SystemMonitor/AppCategoryMapper.swift + SpecialAppMapper.swift.
//
// The Mac app keys everything off bundle identifiers. Here an app's id is its
// lowercased executable name on Windows ("code.exe"), its WM_CLASS / .desktop
// id on Linux ("code", "org.gnome.nautilus"), "uwp:<title>" for Store apps,
// and "web:<name>" for well-known web apps running in a browser tab — the
// counterpart of the Safari web apps the Mac tables are full of.

const CATEGORIES = ['coding', 'gaming', 'browsing', 'music', 'creative', 'finder', 'communication', 'productivity', 'aiChat', 'tinkering'];
const CATEGORY_NAMES = {
  coding: 'Coding', gaming: 'Gaming', browsing: 'Browsing', music: 'Music', creative: 'Creative apps',
  finder: 'File manager', communication: 'Communication', productivity: 'Productivity', aiChat: 'AI chat',
  tinkering: 'Tinkering',
};

const table = (map) => {
  const out = new Map();
  for (const [category, names] of Object.entries(map)) for (const name of names.split('|')) out.set(name, category);
  return out;
};

/** Exact matches on the id stem (no ".exe", no "uwp:"/"web:" prefix). */
const CATEGORY_BY_STEM = table({
  coding: 'code|code - insiders|code-insiders|code-oss|vscodium|codium|cursor|windsurf|zed|dev.zed.zed|devenv|windowsterminal|wt|cmd|powershell|pwsh|powershell_ise|conhost|mintty|git-bash|idea64|idea|pycharm64|pycharm|clion64|clion|webstorm64|webstorm|rider64|rider|goland64|goland|phpstorm64|rustrover64|datagrip64|studio64|sublime_text|subl|notepad++|atom|neovide|nvim-qt|gvim|emacs|kate|org.kde.kate|geany|lapce|qtcreator|eclipse|netbeans64|gnome-builder|org.gnome.builder|gnome-terminal|gnome-terminal-server|org.gnome.terminal|org.gnome.console|kgx|org.gnome.ptyxis|ptyxis|konsole|org.kde.konsole|xterm|uxterm|alacritty|kitty|wezterm|wezterm-gui|org.wezfurlong.wezterm|tilix|com.gexperts.tilix|terminator|xfce4-terminal|foot|ghostty|com.mitchellh.ghostty|warp|dev.warp.warp|hyper|tabby|githubdesktop|github desktop|gitkraken|docker desktop|docker-desktop|sourcetree|fork|postman|insomnia|dbeaver',
  gaming: 'steam|steamwebhelper|epicgameslauncher|battle.net|galaxyclient|origin|eadesktop|ubisoftconnect|upc|riotclientux|riotclientservices|leagueclient|leagueclientux|valorant|minecraft|minecraftlauncher|minecraft-launcher|prismlauncher|org.prismlauncher.prismlauncher|lutris|net.lutris.lutris|heroic|com.heroicgameslauncher.hgl|playnite.desktopapp|xboxapp|gamingapp|robloxplayerbeta|roblox|undertale|deltarune|hollow_knight|hollow knight|cult of the lamb|cultofthelamb|itch|retroarch|dolphin-emu|wow|gamescope|osu!|bottles|com.usebottles.bottles',
  browsing: 'chrome|google-chrome|google-chrome-stable|msedge|microsoft-edge|microsoft-edge-stable|firefox|firefox-esr|navigator|org.mozilla.firefox|brave|brave-browser|opera|opera_gx|vivaldi|vivaldi-stable|arc|chromium|chromium-browser|org.chromium.chromium|librewolf|zen|zen-browser|app.zen_browser.zen|waterfox|floorp|thorium|thorium-browser|epiphany|org.gnome.epiphany|falkon|konqueror|qutebrowser|midori|iexplore|tor browser|duckduckgo',
  music: 'spotify|com.spotify.client|itunes|applemusic|foobar2000|winamp|musicbee|aimp|tidal|deezer|amazon music|rhythmbox|org.gnome.rhythmbox3|lollypop|clementine|strawberry|audacious|elisa|org.kde.elisa|amberol|io.bassi.amberol|cider|youtube music|wmplayer|uwp:media player|uwp:groove music|org.gnome.music|gnome-music',
  creative: 'photoshop|illustrator|afterfx|adobe premiere pro|indesign|lightroom|figma|gimp|gimp-2.10|gimp-3.0|org.gimp.gimp|inkscape|org.inkscape.inkscape|krita|org.kde.krita|blender|org.blender.blender|aseprite|libresprite|pixelorama|paintdotnet|mspaint|uwp:paint|photo|designer|publisher|resolve|obs64|obs|com.obsproject.studio|audacity|kdenlive|org.kde.kdenlive|shotcut|godot|unity|unityhub|unrealeditor|clipstudiopaint|sai2|darktable|rawtherapee|mypaint|freecad|sketchup|fl64|ableton live|reaper|lmms|ardour|capcut|canva',
  finder: 'explorer|nautilus|org.gnome.nautilus|dolphin|org.kde.dolphin|thunar|nemo|pcmanfm|pcmanfm-qt|caja|cosmic-files|com.system76.cosmicfiles|totalcmd64|totalcmd|doublecmd|files|io.elementary.files|spacefm',
  communication: 'outlook|olk|hxoutlook|uwp:mail|thunderbird|org.mozilla.thunderbird|teams|ms-teams|msteams|zoom|slack|discord|discordcanary|vesktop|telegram|telegramdesktop|org.telegram.desktop|whatsapp|whatsapp.root|signal|skype|element|element-desktop|wechat|weixin|qq|line|messenger|viber|mattermost|geary|org.gnome.geary|evolution|org.gnome.evolution|kmail|mailspring|webex|ciscocollabhost|thunderbird-esr',
  productivity: 'winword|excel|powerpnt|onenote|notepad|uwp:notepad|uwp:sticky notes|notion|obsidian|md.obsidian.obsidian|soffice|soffice.bin|libreoffice|libreoffice-writer|libreoffice-calc|libreoffice-impress|libreoffice-startcenter|wps|wpp|et|acrobat|acrord32|sumatrapdf|evince|org.gnome.evince|org.gnome.papers|okular|org.kde.okular|todoist|evernote|logseq|joplin|anki|calibre|calibre-gui|zotero|gedit|org.gnome.gedit|org.gnome.texteditor|gnome-text-editor|kwrite|org.kde.kwrite|mousepad|xed|org.gnome.calendar|gnome-calendar|uwp:calendar|uwp:microsoft to do|onlyoffice|desktopeditors',
  aiChat: 'chatgpt|claude|copilot|uwp:copilot|uwp:microsoft copilot|codex|perplexity|ollama|ollama app|lm studio|jan|msty|poe',
  tinkering: 'wireshark|org.wireshark.wireshark|sdr++|sdrpp|sdrsharp|satdump|satdump-ui|gqrx|rpi-imager|org.raspberrypi.rpi-imager|balenaetcher|balena-etcher|etcher|qflipper|virtualbox|virtualboxvm|virtualbox manager|virtualbox machine|vmware|vmplayer|vmware-view|virt-manager|gnome-boxes|org.gnome.boxes|utm|vmconnect|putty|kitty_portable|winscp|kicad|arduino ide|arduino-ide|hxd|ghidra|x64dbg|ida64|cheatengine-x86_64|regedit|procexp64|procexp|gparted|cutecom|filezilla',
});

const CATEGORY_PREFIXES = [
  ['jetbrains-', 'coding'], ['qemu', 'tinkering'], ['rufus', 'tinkering'], ['steam_app_', 'gaming'],
  ['gimp', 'creative'], ['libreoffice', 'productivity'], ['affinity', 'creative'], ['adobe ', 'creative'],
];

/** Where games live when nothing else identifies them. */
const GAME_PATHS = ['\\steamapps\\common\\', '/steamapps/common/', '\\epic games\\', '\\gog games\\', '\\riot games\\', '\\xboxgames\\', '/gog games/', '/heroic/'];

/** freedesktop.org menu categories -> ours, in priority order (the Mac's LSApplicationCategoryType map). */
function fromDesktopCategories(categories) {
  if (!categories || !categories.length) return null;
  const has = (name) => categories.includes(name);
  if (has('Game')) return 'gaming';
  if (has('WebBrowser')) return 'browsing';
  if (has('Email') || has('InstantMessaging') || has('Chat') || has('Telephony') || has('VideoConference') || has('IRCClient')) return 'communication';
  if (has('FileManager')) return 'finder';
  if (has('TerminalEmulator') || has('Development') || has('IDE')) return 'coding';
  if (has('Music') || has('Player') || (has('Audio') && !has('AudioVideoEditing'))) return 'music';
  if (has('Graphics') || has('AudioVideoEditing') || has('Video') || has('Photography')) return 'creative';
  if (has('Office') || has('Education') || has('TextEditor') || has('Calendar')) return 'productivity';
  return null;
}

const stemOf = (id) => String(id || '').toLowerCase().replace(/^(uwp|web):/, '').replace(/\.exe$/, '');

/** AppCategoryMapper.category */
function category(app) {
  if (app.webCategory) return app.webCategory;
  const id = String(app.id || '').toLowerCase();
  const stem = stemOf(id);
  const hit = CATEGORY_BY_STEM.get(id) || CATEGORY_BY_STEM.get(stem);
  if (hit) return hit;
  for (const [prefix, cat] of CATEGORY_PREFIXES) if (stem.startsWith(prefix)) return cat;
  const exe = String(app.exe || '').toLowerCase();
  if (exe && GAME_PATHS.some((p) => exe.includes(p))) return 'gaming';
  return fromDesktopCategories(app.desktopCategories);
}

// ------------------------------------------------------------ special apps
const SPECIAL_BY_STEM = table({
  trickster: 'undertale',
  darkWorld: 'deltarune',
  hollowed: 'hollow_knight|hollow knight|hollowknight',
  cultLeader: 'cult of the lamb|cultofthelamb',
  scanning: 'sdr++|sdrpp|sdrsharp|satdump|satdump-ui|gqrx',
  sneaking: 'wireshark|org.wireshark.wireshark',
  glitching: 'virtualbox|virtualboxvm|virtualbox manager|virtualbox machine|vmware|vmplayer|virt-manager|gnome-boxes|org.gnome.boxes|utm|vmconnect',
  charged: 'qflipper',
  transferring: 'rpi-imager|org.raspberrypi.rpi-imager|balenaetcher|balena-etcher|etcher',
  summoning: 'docker desktop|docker-desktop',
  sculpting: 'blender|org.blender.blender',
  kinship: 'pixelorama',
  dispatching: 'outlook|olk|hxoutlook|mail|thunderbird|thunderbird-esr|org.mozilla.thunderbird|geary|org.gnome.geary|evolution|org.gnome.evolution|kmail|mailspring',
  ambushed: 'microsoft store|winstore.app|gnome-software|org.gnome.software|plasma-discover|org.kde.discover|io.elementary.appcenter|pamac-manager|software-center|mintinstall|snap-store',
  stressed: 'taskmgr|task manager|gnome-system-monitor|org.gnome.systemmonitor|plasma-systemmonitor|org.kde.plasma-systemmonitor|ksysguard|mate-system-monitor|xfce4-taskmanager|procexp|procexp64|resmon|perfmon|missioncenter|io.missioncenter.missioncenter',
  watched: 'settings|systemsettings|gnome-control-center|org.gnome.settings|org.kde.systemsettings|xfce4-settings-manager|cinnamon-settings|control',
  flinching: 'camera|windowscamera|cheese|org.gnome.cheese|snapshot|org.gnome.snapshot|kamoso|org.kde.kamoso|guvcview|webcamoid',
  huffy: 'bcuninstaller|revouninstaller|revouninpro|iobit uninstaller|iobituninstaler|ccleaner|ccleaner64|bleachbit|org.bleachbit.bleachbit|geek|stacer|installed apps',
  browsingStore: 'steam|steamwebhelper',
  dancing: 'spotify|com.spotify.client',
});
const SPECIAL_PREFIXES = [['qemu', 'glitching'], ['rufus', 'transferring'], ['vmware', 'glitching']];

/** Name matches, in the Mac's order — these are the web apps and the bundle-id-less games. */
const SPECIAL_BY_NAME = [
  ['baldi', 'spooked'], ['canva', 'presenting'], ['duolingo', 'guilty'], ['shrewsbury', 'dreading'],
  ['socs', 'dreading'], ['student', 'dreading'], ['classroom', 'dreading'], ['youtube', 'grooving'],
  ['github', 'pushingCode'], ['mandelbrot', 'fractaling'], ['undertale', 'trickster'], ['deltarune', 'darkWorld'],
  ['hollow knight', 'hollowed'], ['cult of the lamb', 'cultLeader'], ['docker desktop', 'summoning'],
  ['raspberry pi imager', 'transferring'], ['wireshark', 'sneaking'], ['virtualbox', 'glitching'],
];

/** SpecialAppMapper.state */
function specialState(id, name) {
  const stem = stemOf(id);
  const hit = SPECIAL_BY_STEM.get(stem);
  if (hit) return hit;
  for (const [prefix, state] of SPECIAL_PREFIXES) if (stem.startsWith(prefix)) return state;
  const lowered = String(name || '').toLowerCase();
  const byName = SPECIAL_BY_NAME.find(([match]) => lowered.includes(match));
  return byName ? byName[1] : null;
}

// ---------------------------------------------------------------- web apps
// On the Mac, sites like Classroom or YouTube are installed as Safari web
// apps and so arrive as apps in their own right. Elsewhere they are a browser
// tab, so the tab's title is matched against this fixed list. Only the
// canonical name below is ever recorded — never the title itself.
const WEB_APPS = [
  [/\byoutube music\b/, 'YouTube Music', 'music'],
  [/\byoutube\b/, 'YouTube', 'music'],
  [/\bgithub\b/, 'GitHub', 'coding'],
  [/\bgoogle docs\b/, 'Google Docs', 'productivity'],
  [/\bgoogle sheets\b/, 'Google Sheets', 'productivity'],
  [/\bgoogle slides\b/, 'Google Slides', 'productivity'],
  [/\bgoogle classroom\b|\bclassroom\.google\b/, 'Google Classroom', 'productivity'],
  [/\bgoogle drive\b/, 'Google Drive', 'productivity'],
  [/\bduolingo\b/, 'Duolingo', 'productivity'],
  [/\bshrewsbury\b/, 'Shrewsbury', 'productivity'],
  [/\bsocs\b/, 'SOCS', 'productivity'],
  [/\bcanva\b/, 'Canva', 'creative'],
  [/\bgmail\b/, 'Gmail', 'communication'],
  [/\bchatgpt\b/, 'ChatGPT', 'aiChat'],
  [/\bclaude\b/, 'Claude', 'aiChat'],
  [/\bdiscord\b/, 'Discord', 'communication'],
  [/\bwhatsapp\b/, 'WhatsApp', 'communication'],
];

/**
 * Turns the raw foreground window into the app Bill reacts to: either the
 * program itself, or — for a browser showing a known site — that site.
 */
function identify(fg) {
  const base = { id: fg.id, name: fg.name, pid: fg.pid, windowId: fg.windowId, exe: fg.exe, desktopCategories: fg.desktopCategories, title: fg.title || '' };
  const baseCategory = category(base);
  if (baseCategory === 'browsing' && fg.title) {
    const title = fg.title.toLowerCase();
    const web = WEB_APPS.find(([pattern]) => pattern.test(title));
    if (web) {
      const [, name, webCategory] = web;
      return { ...base, id: `web:${name.toLowerCase()}`, name, category: webCategory, webCategory, browserName: fg.name };
    }
  }
  return { ...base, category: baseCategory };
}

module.exports = { CATEGORIES, CATEGORY_NAMES, category, specialState, identify, stemOf };
