import Foundation

struct DockerContainer: Identifiable, Equatable {
    let id: String
    let name: String
    let image: String
    let state: String       // running, exited, paused, ...
    let status: String      // "Up 2 hours", "Exited (0) 3 days ago"
    var cpu: Double?        // percent of one core, as `docker stats` reports it
    var memory: String?     // "11.66MiB"
    var isRunning: Bool { state == "running" }
}

enum Docker {
    /// Docker Desktop, OrbStack, Colima and Homebrew all ship a `docker` CLI in one of these places.
    static let cli: String? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "\(home)/.orbstack/bin/docker",
                "/Applications/Docker.app/Contents/Resources/bin/docker"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// All containers with live stats for the running ones, or nil if the Docker engine isn't running.
    static func containers() async -> [DockerContainer]? {
        guard let cli,
              let output = await Shell.run(cli, ["ps", "-a", "--format", "{{json .}}"], requireSuccess: true)
        else { return nil }

        var containers = jsonLines(output).compactMap { row -> DockerContainer? in
            guard let id = row["ID"] as? String else { return nil }
            return DockerContainer(id: id, name: row["Names"] as? String ?? id,
                                   image: row["Image"] as? String ?? "",
                                   state: row["State"] as? String ?? "",
                                   status: row["Status"] as? String ?? "")
        }
        guard containers.contains(where: \.isRunning),
              let stats = await Shell.run(cli, ["stats", "--no-stream", "--format", "{{json .}}"], requireSuccess: true)
        else { return containers }

        for row in jsonLines(stats) {
            guard let id = row["ID"] as? String,
                  let index = containers.firstIndex(where: { $0.id.hasPrefix(id) || id.hasPrefix($0.id) })
            else { continue }
            containers[index].cpu = (row["CPUPerc"] as? String).flatMap { Double($0.replacingOccurrences(of: "%", with: "")) }
            containers[index].memory = (row["MemUsage"] as? String)?
                .components(separatedBy: " / ").first
        }
        return containers
    }

    static func start(_ id: String) async { _ = await run(["start", id]) }
    static func stop(_ id: String) async { _ = await run(["stop", id]) }

    private static func run(_ arguments: [String]) async -> String? {
        guard let cli else { return nil }
        return await Shell.run(cli, arguments, requireSuccess: true)
    }

    private static func jsonLines(_ text: String) -> [[String: Any]] {
        text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }
}

// MARK: - Disk usage

struct DockerDiskUsage: Identifiable, Equatable {
    let type: String          // Images, Containers, Local Volumes, Build Cache
    let count: Int
    let size: String
    let reclaimable: String   // "1.438GB (97%)"
    var id: String { type }

    var title: String {
        switch type {
        case "Images": "Unused images"
        case "Containers": "Stopped containers"
        case "Local Volumes": "Unused volumes"
        case "Build Cache": "Build cache"
        default: type
        }
    }

    var detail: String {
        switch type {
        case "Local Volumes": "Deletes data stored in them"
        case "Images": "Not used by any container"
        default: "\(count) item\(count == 1 ? "" : "s"), \(size) total"
        }
    }

    /// Reclaimable bytes, parsed from Docker's "1.438GB (97%)" format.
    var reclaimableBytes: UInt64 {
        let text = reclaimable.components(separatedBy: " ").first ?? ""
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("B", 1)]
        for (unit, factor) in units where text.hasSuffix(unit) {
            return UInt64((Double(text.dropLast(unit.count)) ?? 0) * factor)
        }
        return 0
    }

    var pruneArguments: [String] {
        switch type {
        case "Images": ["image", "prune", "-a", "-f"]
        case "Containers": ["container", "prune", "-f"]
        case "Local Volumes": ["volume", "prune", "-a", "-f"]
        default: ["builder", "prune", "-a", "-f"]
        }
    }
}

extension Docker {
    static func diskUsage() async -> [DockerDiskUsage]? {
        guard let cli, let output = await Shell.run(cli, ["system", "df", "--format", "{{json .}}"], requireSuccess: true)
        else { return nil }
        return jsonLines(output).compactMap { row in
            guard let type = row["Type"] as? String else { return nil }
            return DockerDiskUsage(type: type, count: Int(row["TotalCount"] as? String ?? "") ?? 0,
                                   size: row["Size"] as? String ?? "", reclaimable: row["Reclaimable"] as? String ?? "")
        }
    }

    static func prune(_ usage: DockerDiskUsage) async {
        _ = await run(usage.pruneArguments)
    }
}
