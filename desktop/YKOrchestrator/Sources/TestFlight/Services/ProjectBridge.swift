import Foundation

/// Genel proje (DB `APIClient.ProjectInfo`) → FlightKit `AppProject` köprüsü.
///
/// TestFlight artık ayrı bir katalog (FKProjectStore JSON) tutmaz; app'ler genel
/// projelerden türetilir. `AppProject` ve FlightKit view'ları değişmeden çalışır.
enum ProjectBridge {

    /// DB projesinden bir `AppProject` üretir. `id = String(Project.id)` —
    /// ASC API key keychain'i bu string id ile saklanır.
    static func appProject(from info: APIClient.ProjectInfo) -> AppProject {
        let container = resolveContainerPath(info)
        let envs = decodeEnvironments(info.xcode_environments)
        return AppProject(
            id: String(info.id),
            displayName: info.name,
            containerPath: container,
            schemeName: info.xcode_scheme ?? "",
            configuration: info.xcode_configuration ?? "",
            bundleIdentifier: info.xcode_bundle_id ?? "",
            teamId: info.xcode_team_id ?? "",
            environments: envs
        )
    }

    /// TestFlight'a yayınlanabilir mi? Container + scheme + en az bir environment dolu olmalı.
    static func isPublishReady(_ p: AppProject) -> Bool {
        !p.containerPath.isEmpty
            && !p.schemeName.isEmpty
            && !p.resolvedEnvironments.contains(where: { $0.bundleIdentifier.isEmpty })
            && !p.resolvedEnvironments.isEmpty
    }

    // MARK: - Internals

    /// `xcode_container_path` doluysa onu; değilse `local_repo_path` altında
    /// `.xcworkspace` (öncelik) → `.xcodeproj` arar.
    private static func resolveContainerPath(_ info: APIClient.ProjectInfo) -> String {
        if let c = info.xcode_container_path, !c.isEmpty { return c }
        return findContainer(inDirectory: info.local_repo_path) ?? ""
    }

    /// Bir klasör altında `.xcworkspace` (öncelik) → `.xcodeproj` arar.
    /// TestFlight yapılandırmasında klasör tekrar sorulmasın diye kullanılır.
    static func findContainer(inDirectory root: String) -> String? {
        guard !root.isEmpty else { return nil }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return nil }
        if let ws = entries.first(where: { $0.hasSuffix(".xcworkspace") }) {
            return (root as NSString).appendingPathComponent(ws)
        }
        if let proj = entries.first(where: { $0.hasSuffix(".xcodeproj") }) {
            return (root as NSString).appendingPathComponent(proj)
        }
        return nil
    }

    private static func decodeEnvironments(_ json: String?) -> [AppEnvironment]? {
        guard let json, !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([AppEnvironment].self, from: data)
    }

    /// `[AppEnvironment]` → JSON string (DB `xcode_environments` için).
    static func encodeEnvironments(_ envs: [AppEnvironment]) -> String {
        guard let data = try? JSONEncoder().encode(envs),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }
}
