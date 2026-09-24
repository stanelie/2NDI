// Prints what the Syphon server directory can see, for checking discovery independently
// of the app's UI.
import Cocoa

let deadline = Date().addingTimeInterval(3)
while Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
}
let servers = SyphonServerDirectory.shared().servers
print("\(servers.count) Syphon server(s)")
for server in servers {
    let app = server[SyphonServerDescriptionAppNameKey] as? String ?? ""
    let name = server[SyphonServerDescriptionNameKey] as? String ?? ""
    print("--- app=\"\(app)\" name=\"\(name)\"")
    // Everything the directory publishes, to see whether orientation is knowable.
    for key in server.keys.sorted() {
        let value: Any = server[key] ?? "nil"
        var text = String(describing: value)
        if text.count > 300 { text = String(text.prefix(300)) + "…" }
        print("    \(key) = \(text)")
    }
}
