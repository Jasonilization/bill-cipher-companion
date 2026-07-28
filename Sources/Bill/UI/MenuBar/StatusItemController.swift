import AppKit

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private weak var appDelegate: AppDelegate?
    private let characterEngine: CharacterEngine

    init(appDelegate: AppDelegate, characterEngine: CharacterEngine) {
        self.appDelegate = appDelegate
        self.characterEngine = characterEngine
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configure()
    }

    private func configure() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "eye.fill", accessibilityDescription: "Bill")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Chat", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        let debugItem = NSMenuItem(title: "Debug: Force State", action: nil, keyEquivalent: "")
        debugItem.submenu = makeDebugSubmenu()
        menu.addItem(debugItem)

        let dumpItem = NSMenuItem(title: "Debug: Dump State", action: #selector(dumpState), keyEquivalent: "")
        dumpItem.target = self
        menu.addItem(dumpItem)
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

    @objc private func forceState(_ sender: NSMenuItem) {
        guard let state = sender.representedObject as? BillState else { return }
        characterEngine.request(state, force: true)
    }

    @objc private func dumpState() {
        characterEngine.stateMachine.debugDump()
    }
}
