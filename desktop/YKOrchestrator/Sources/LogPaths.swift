import Foundation

enum LogPaths {
    static func appDir() -> URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let dir = lib.appendingPathComponent("Logs").appendingPathComponent("YK Orchestrator")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func apiLog() -> URL {
        appDir().appendingPathComponent("api.log")
    }

    static func swiftLog() -> URL {
        appDir().appendingPathComponent("app.log")
    }
}

enum AppSupportPaths {
    static func dir() -> URL {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YK Orchestrator")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func configJSON() -> URL {
        dir().appendingPathComponent("config.json")
    }
}
