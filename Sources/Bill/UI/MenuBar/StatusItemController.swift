import AppKit

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private weak var appDelegate: AppDelegate?
    private let characterEngine: CharacterEngine
    private let characterWindowController: CharacterWindowController
    private let chatPanelController: ChatPanelController
    private let settingsWindowController: SettingsWindowController

    init(
        appDelegate: AppDelegate,
        characterEngine: CharacterEngine,
        characterWindowController: CharacterWindowController,
        chatPanelController: ChatPanelController,
        settingsWindowController: SettingsWindowController
    ) {
        self.appDelegate = appDelegate
        self.characterEngine = characterEngine
        self.characterWindowController = characterWindowController
        self.chatPanelController = chatPanelController
        self.settingsWindowController = settingsWindowController
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configure()
    }

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
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Bill", action: #selector(AppDelegate.quit), keyEquivalent: "q")
        quitItem.target = appDelegate
        menu.addItem(quitItem)

        statusItem.menu = menu
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
}
