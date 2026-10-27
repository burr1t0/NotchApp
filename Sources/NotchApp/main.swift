import AppKit

setvbuf(stdout, nil, _IONBF, 0)
// A hook/tool client that hangs up before we answer must not kill the app.
signal(SIGPIPE, SIG_IGN)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
