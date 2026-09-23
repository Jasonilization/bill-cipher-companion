import AppKit

setvbuf(stdout, nil, _IONBF, 0)

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
