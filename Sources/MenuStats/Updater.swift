import AppKit
import UserNotifications

enum UpdateKey {
    static let checkAutomatically = "updates.checkAutomatically"
    static let installAutomatically = "updates.installAutomatically"
    static let notifiedVersion = "updates.notifiedVersion"
}

/// Checks GitHub for a newer release and installs it through Homebrew when MenuStats was
/// installed that way; otherwise it opens the release page to download it.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
        case updating
        case failed(String)
    }

    @Published private(set) var state = State.idle
    @Published private(set) var lastChecked: Date?

    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    private static let repo = "stephanevdb/menustats"
    private static let releasesPage = URL(string: "https://github.com/\(repo)/releases/latest")!
    private static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/MenuStats-update.log")
    private var timer: Timer?

    private var checkAutomatically: Bool {
        UserDefaults.standard.object(forKey: UpdateKey.checkAutomatically) as? Bool ?? true
    }

    private var installAutomatically: Bool {
        UserDefaults.standard.bool(forKey: UpdateKey.installAutomatically)
    }

    var availableVersion: String? {
        if case .available(let version) = state { return version }
        return nil
    }

    /// Checks shortly after launch and then every 6 hours, while automatic checks are on.
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.automaticCheck() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.automaticCheck() }
    }

    private func automaticCheck() {
        guard checkAutomatically else { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool = true) async {
        guard state != .checking, state != .updating else { return }
        state = .checking
        guard let latest = await Self.latestVersion() else {
            state = userInitiated ? .failed("Couldn't reach GitHub") : .idle
            return
        }
        lastChecked = Date()
        guard Self.isNewer(latest, than: currentVersion) else {
            state = .upToDate
            return
        }
        state = .available(latest)
        if !userInitiated {
            if installAutomatically && Self.brew != nil {
                update()
            } else {
                notifyOnce(about: latest)
            }
        }
    }

    // MARK: Installing

    /// The Homebrew binary, if MenuStats was installed as a Homebrew cask.
    static var brew: String? {
        for prefix in ["/opt/homebrew", "/usr/local"]
        where FileManager.default.fileExists(atPath: "\(prefix)/Caskroom/menustats") {
            let brew = "\(prefix)/bin/brew"
            if FileManager.default.isExecutableFile(atPath: brew) { return brew }
        }
        return nil
    }

    func update() {
        guard let brew = Self.brew else {
            NSWorkspace.shared.open(Self.releasesPage)
            return
        }
        state = .updating
        // Homebrew won't quit an app it's running inside, so it replaces the app on disk and
        // this script then restarts it: stop the old process, wait for it to exit, open the new
        // copy. Auto-remove stays off so the upgrade can't uninstall other packages, and the
        // log shows what happened if it fails.
        let appPath = Bundle.main.bundlePath
        let script = """
        {
          "$0" update --quiet
          HOMEBREW_NO_AUTOREMOVE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 "$0" upgrade --cask menustats
          status=$?
          if [ $status -eq 0 ]; then
            kill "$3" 2>/dev/null
            while kill -0 "$3" 2>/dev/null; do sleep 0.2; done
            /usr/bin/open "$1"
          fi
          exit $status
        } > "$2" 2>&1
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, brew, appPath, Self.logURL.path,
                             String(ProcessInfo.processInfo.processIdentifier)]
        do {
            try process.run()
        } catch {
            state = .failed("Couldn't start Homebrew")
            return
        }
        // If the app is still running after a few minutes, the upgrade didn't go through.
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
            guard let self, self.state == .updating else { return }
            self.state = .failed("Update didn't finish, see ~/Library/Logs/MenuStats-update.log")
        }
    }

    // MARK: Helpers

    private static func latestVersion() async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { return nil }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// Compares dotted version numbers, e.g. 1.0.10 is newer than 1.0.9.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// One notification per new version, so a skipped update doesn't nag every 6 hours.
    private func notifyOnce(about version: String) {
        guard Bundle.main.bundleIdentifier != nil,
              UserDefaults.standard.string(forKey: UpdateKey.notifiedVersion) != version
        else { return }
        UserDefaults.standard.set(version, forKey: UpdateKey.notifiedVersion)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "MenuStats \(version) is available"
        content.body = "Open MenuStats and click Update to install it."
        center.add(UNNotificationRequest(identifier: "update.\(version)", content: content, trigger: nil))
    }
}
