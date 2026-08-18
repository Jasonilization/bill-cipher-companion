import AppKit

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private weak var appDelegate: AppDelegate?
    private let characterEngine: CharacterEngine
    private let characterWindowController: CharacterWindowController
    private let chatPanelController: ChatPanelController
    private let settingsWindowController: SettingsWindowController
    private let dialogueRefreshLogWindowController: DialogueRefreshLogWindowController

    init(
        appDelegate: AppDelegate,
        characterEngine: CharacterEngine,
        characterWindowController: CharacterWindowController,
        chatPanelController: ChatPanelController,
        settingsWindowController: SettingsWindowController,
        dialogueRefreshLogWindowController: DialogueRefreshLogWindowController
    ) {
        self.appDelegate = appDelegate
        self.characterEngine = characterEngine
        self.characterWindowController = characterWindowController
        self.chatPanelController = chatPanelController
        self.settingsWindowController = settingsWindowController
        self.dialogueRefreshLogWindowController = dialogueRefreshLogWindowController
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configure()
    }

    private var studyModeItem: NSMenuItem!

    private func configure() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "eye.fill", accessibilityDescription: "Bill")
        }

        let menu = NSMenu()

        let talkItem = NSMenuItem(title: "Talk to Bill", action: #selector(talkToBill), keyEquivalent: "")
        talkItem.target = self
        menu.addItem(talkItem)
        let openChatItem = NSMenuItem(title: "Open Full Chat View…", action: #selector(openChat), keyEquivalent: "")
        openChatItem.target = self
        menu.addItem(openChatItem)
        let refreshContextItem = NSMenuItem(title: "Refresh Bill's Context Now", action: #selector(refreshDialogue), keyEquivalent: "")
        refreshContextItem.target = self
        menu.addItem(refreshContextItem)
        menu.addItem(.separator())

        // The only checkmark item in this menu. Its title carries the
        // remaining time while a session is running, so the menu bar answers
        // "how long left?" without opening anything.
        studyModeItem = NSMenuItem(title: "Study Mode", action: #selector(toggleStudyMode), keyEquivalent: "")
        studyModeItem.target = self
        menu.addItem(studyModeItem)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let debugItem = NSMenuItem(title: "Debug: Force State", action: nil, keyEquivalent: "")
        debugItem.submenu = makeDebugSubmenu()
        menu.addItem(debugItem)

        let dumpItem = NSMenuItem(title: "Debug: Dump State", action: #selector(dumpState), keyEquivalent: "")
        dumpItem.target = self
        menu.addItem(dumpItem)

        let barkItem = NSMenuItem(title: "Debug: Test Bark", action: #selector(testBark), keyEquivalent: "")
        barkItem.target = self
        menu.addItem(barkItem)

        let wanderItem = NSMenuItem(title: "Debug: Trigger Wander Now", action: #selector(triggerWander), keyEquivalent: "")
        wanderItem.target = self
        menu.addItem(wanderItem)

        let dialogueLogItem = NSMenuItem(title: "Debug: Show Dialogue Refresh Log", action: #selector(showDialogueRefreshLog), keyEquivalent: "")
        dialogueLogItem.target = self
        menu.addItem(dialogueLogItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Bill", action: #selector(AppDelegate.quit), keyEquivalent: "q")
        quitItem.target = appDelegate
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
        refreshStudyModeItem()
    }

    /// Keeps the checkmark and the remaining-time title honest. Called when
    /// the session starts/ends and every time the menu is about to open, which
    /// is cheaper and more reliable than a countdown timer just for a label.
    func refreshStudyModeItem() {
        guard let studyModeItem, let studyMode = appDelegate?.studyMode else { return }
        if studyMode.isActive {
            let minutes = Int((studyMode.remaining / 60).rounded(.up))
            studyModeItem.title = "Study Mode — \(minutes) min left"
            studyModeItem.state = .on
        } else {
            studyModeItem.title = "Study Mode (30 min)"
            studyModeItem.state = .off
        }
    }

    @objc private func toggleStudyMode() {
        guard let studyMode = appDelegate?.studyMode else { return }
        guard studyMode.isActive else {
            studyMode.start()
            return
        }
        // Cancelling costs a confirmation — see `StudyMode.cancel(confirmed:)`
        // for why it is possible at all.
        let minutes = Int((studyMode.remaining / 60).rounded(.up))
        let alert = NSAlert()
        alert.messageText = "End Study Mode early?"
        alert.informativeText = "There are \(minutes) minutes left. Bill will have opinions."
        alert.addButton(withTitle: "Keep Studying")
        alert.addButton(withTitle: "End Session")
        alert.alertStyle = .warning
        let confirmed = alert.runModal() == .alertSecondButtonReturn
        _ = studyMode.cancel(confirmed: confirmed)
    }

    private func makeDebugSubmenu() -> NSMenu {
        let submenu = NSMenu()
        for state in BillState.allCases {
            let item = NSMenuItem(title: state.rawValue.capitalized, action: #selector(forceState(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = state
            submenu.addItem(item)
        }
        return submenu
    }

    @objc private func talkToBill() {
        characterWindowController.talkToBill()
    }

    @objc private func openChat() {
        chatPanelController.toggle()
    }

    @objc private func refreshDialogue() {
        characterWindowController.refreshDialogueNow()
    }

    @objc private func openSettings() {
        settingsWindowController.show()
    }

    @objc private func forceState(_ sender: NSMenuItem) {
        guard let state = sender.representedObject as? BillState else { return }
        characterEngine.request(state, force: true)
    }

    @objc private func dumpState() {
        characterEngine.stateMachine.debugDump()
    }

    @objc private func testBark() {
        characterEngine.bark(BarkLines.random(from: BarkLines.coding))
    }

    @objc private func triggerWander() {
        characterWindowController.debugTriggerWander()
    }

    @objc private func showDialogueRefreshLog() {
        dialogueRefreshLogWindowController.show()
    }
}

extension StatusItemController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshStudyModeItem()
    }
}
