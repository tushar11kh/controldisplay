import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let menuController = MenuController()
_ = menuController

app.run()
