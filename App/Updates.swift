import Foundation

/// The manual update check. This is the only code in the app that touches the network, and it runs
/// only when the user presses "Check for updates": one HTTPS request for one public file of this
/// project's repository on GitHub, to read the latest version number. It sends nothing about the user,
/// keeps no cookies and no cache.
enum Updates {
    /// The app's own Info.plist as published on the main branch.
    static let source = URL(string: "https://raw.githubusercontent.com/Echo14091409/usage-meter/main/App/Info.plist")!
    /// Where a person reads how to update.
    static let page = URL(string: "https://github.com/Echo14091409/usage-meter#install")!

    static func version(inPlist data: Data) -> String? {
        guard let o = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return o["CFBundleShortVersionString"] as? String
    }

    /// Compares dotted version numbers part by part ("0.10.0" is newer than "0.9.9"). Unreadable = not newer.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ s: String) -> [Int]? {
            let p = s.split(separator: ".").map { Int($0) }
            return p.isEmpty || p.contains(nil) ? nil : p.compactMap { $0 }
        }
        guard let r = parts(remote), let l = parts(local) else { return false }
        for i in 0..<max(r.count, l.count) {
            let a = i < r.count ? r[i] : 0, b = i < l.count ? l[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// Asks GitHub for the latest version. Blocks for up to 15 seconds; call it off the main thread.
    static func latestVersion() throws -> String {
        let config = URLSessionConfiguration.ephemeral            // no cookies, no cache, nothing kept
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = ["User-Agent": "Usage Meter"]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: source)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let done = DispatchSemaphore(value: 0)
        var result: Result<String, Error> = .failure(Problem("No answer from GitHub."))
        session.dataTask(with: request) { data, response, error in
            if let error = error {
                result = .failure(Problem("Could not reach GitHub: \(error.localizedDescription)"))
            } else if let data = data, (response as? HTTPURLResponse)?.statusCode == 200, let v = version(inPlist: data) {
                result = .success(v)
            } else {
                result = .failure(Problem("GitHub answered, but not with a version number."))
            }
            done.signal()
        }.resume()
        done.wait()
        return try result.get()
    }
}
