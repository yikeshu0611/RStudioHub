import AppKit

let app = NSApplication.shared
let delegate = RStudioHubApp()
app.delegate = delegate
app.run()
