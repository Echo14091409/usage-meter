import Foundation

/// A Claude login the app shows limits for. The main one is Claude Code's normal login (`~/.claude`).
/// Each added one is a second Claude Code login kept in a folder of its own inside the app's data, so
/// nothing about the main login changes. Claude Code picks the folder up from `CLAUDE_CONFIG_DIR`.
struct Account: Codable, Identifiable, Equatable {
    var id: String
    var name: String
}

enum Accounts {
    static let mainID = "main"
    static var file: URL { Paths.support.appendingPathComponent("accounts.json") }

    /// The main account first, then the added ones in the order they were added.
    static func load() -> [Account] {
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Account].self, from: $0) } ?? []
        let main = saved.first { $0.id == mainID } ?? Account(id: mainID, name: "Main account")
        return [main] + saved.filter { $0.id != mainID }
    }

    static func save(_ a: [Account]) {
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(a) { try? d.write(to: file, options: .atomic) }
    }

    /// Where an account's limits, history and `/usage` notes are kept.
    static func dataDir(_ id: String) -> URL {
        id == mainID ? Paths.support : Paths.support.appendingPathComponent("accounts/\(id)")
    }

    /// The Claude Code login folder of an added account; nil for the main one (Claude Code's default).
    static func configDir(_ id: String) -> URL? {
        id == mainID ? nil : dataDir(id).appendingPathComponent("claude")
    }

    /// Environment that makes `claude` use this account's login.
    static func environment(_ id: String) -> [String: String] {
        configDir(id).map { ["CLAUDE_CONFIG_DIR": $0.path] } ?? [:]
    }

    /// Creates the folders for one more account and saves it. Signing in is a separate step.
    static func add() -> Account {
        var all = load()
        let n = (all.compactMap { a in a.name.hasPrefix("Account ") ? Int(a.name.dropFirst(8)) : nil }.max() ?? 1) + 1
        let a = Account(id: String(UUID().uuidString.prefix(8)).lowercased(), name: "Account \(max(n, all.count + 1))")
        try? FileManager.default.createDirectory(at: configDir(a.id)!, withIntermediateDirectories: true)
        all.append(a)
        save(all)
        return a
    }

    static func rename(_ id: String, to name: String) {
        var all = load()
        guard let i = all.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        all[i].name = name
        save(all)
    }

    /// Takes an added account off the list and moves its folder to the Trash (deleted outright if that fails).
    static func remove(_ id: String) {
        guard id != mainID else { return }
        save(load().filter { $0.id != id })
        let dir = dataDir(id)
        if (try? FileManager.default.trashItem(at: dir, resultingItemURL: nil)) == nil {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// What Terminal runs to sign an added account in: Claude Code's own `auth login`, pointed at the account's folder.
    static func signInScript(for id: String, claude: String) -> String {
        let c = shellQuote(claude)
        return """
        #!/bin/zsh
        export CLAUDE_CONFIG_DIR=\(shellQuote(configDir(id)?.path ?? ""))
        clear
        echo "Usage Meter: sign in to the Claude account you want to add."
        echo "Claude Code opens your browser. Your main Claude Code login is not changed."
        echo
        \(c) auth login --claudeai
        echo
        echo "You can close this window. Usage Meter shows the account within a few seconds of a successful sign-in."

        """
    }

    /// Writes the script as a `.command` file (Terminal opens those on a double click or `open`).
    static func writeSignInCommand(for id: String, claude: String) throws -> URL {
        let url = dataDir(id).appendingPathComponent("Sign in to Claude.command")
        try FileManager.default.createDirectory(at: dataDir(id), withIntermediateDirectories: true)
        try Data(signInScript(for: id, claude: claude).utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    struct Status { var loggedIn = false; var email: String?; var plan: String? }

    /// Reads the JSON `claude auth status` prints.
    static func parseStatus(_ text: String) -> Status {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return Status() }
        return Status(loggedIn: o["loggedIn"] as? Bool ?? false, email: o["email"] as? String,
                      plan: o["subscriptionType"] as? String)
    }

    /// Asks Claude Code whether this account is signed in.
    static func status(_ id: String) -> Status {
        guard let claude = Limits.claudePath() else { return Status() }
        return parseStatus(Limits.runProcess(claude, ["auth", "status"], env: environment(id), timeout: 20).out)
    }

    /// Signs an added account out (so its saved login is removed too), then removes it.
    static func signOutAndRemove(_ id: String) {
        guard id != mainID else { return }
        if let claude = Limits.claudePath() {
            _ = Limits.runProcess(claude, ["auth", "logout"], env: environment(id), timeout: 20)
        }
        remove(id)
    }
}
