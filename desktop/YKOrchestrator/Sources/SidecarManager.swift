import Foundation
import Combine

/// Backend (ykorch-api) process'ini yönetir:
/// - Bundle.main.resourcePath/backend/ykorch-api altındaki PyInstaller onedir binary'sini başlatır
/// - Boş bir TCP portu seçer, --port ile geçer
/// - /health endpoint'ini polling ile bekler
/// - stdout/stderr ~/Library/Logs/YK Orchestrator/api.log'a yönlendirir
/// - App quit'te SIGTERM gönderir
@MainActor
final class SidecarManager: ObservableObject {

    /// AppDelegate.applicationWillTerminate'ten erişmek için.
    /// Sadece ana pencere açıkken yaratılır, tek instance.
    static private(set) weak var shared: SidecarManager?

    enum State: Equatable {
        case idle, starting, waitingHealth, ready, failed, stopped
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var apiBaseURL: URL?
    @Published private(set) var lastError: String?

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var healthTask: Task<Void, Never>?
    private var logHandle: FileHandle?

    init() {
        Self.shared = self
    }

    // MARK: - Public API

    func start(config: ConfigSnapshot) {
        guard state == .idle || state == .failed || state == .stopped else { return }
        state = .starting
        lastError = nil

        do {
            let port = try Self.findFreePort()
            let baseURL = URL(string: "http://127.0.0.1:\(port)")!
            self.apiBaseURL = baseURL

            let launch = try resolveBackendLaunch(port: port)
            let env = buildEnvironment(config: config, isDev: launch.isDev)

            let proc = Process()
            proc.executableURL = launch.executable
            proc.arguments = launch.args
            if let cwd = launch.cwd { proc.currentDirectoryURL = cwd }
            proc.environment = env

            let stdout = Pipe()
            let stderr = Pipe()
            proc.standardOutput = stdout
            proc.standardError = stderr
            self.stdoutPipe = stdout
            self.stderrPipe = stderr

            let logFile = LogPaths.apiLog()
            if !FileManager.default.fileExists(atPath: logFile.path) {
                FileManager.default.createFile(atPath: logFile.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logFile)
            handle.seekToEndOfFile()
            self.logHandle = handle
            forwardPipe(stdout, to: handle)
            forwardPipe(stderr, to: handle)

            proc.terminationHandler = { [weak self] _ in
                Task { @MainActor in
                    self?.handleTermination()
                }
            }

            try proc.run()
            self.process = proc

            state = .waitingHealth
            startHealthPolling(baseURL: baseURL)
        } catch {
            self.lastError = "Backend başlatılamadı: \(error.localizedDescription)"
            self.state = .failed
        }
    }

    func stop() {
        healthTask?.cancel()
        healthTask = nil
        guard let proc = process, proc.isRunning else {
            state = .stopped
            return
        }
        proc.terminate()
        let pid = proc.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) {
            kill(pid, SIGKILL)
        }
        state = .stopped
    }

    func restart(config: ConfigSnapshot) {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.start(config: config)
        }
    }

    // MARK: - Internals

    private func handleTermination() {
        if state != .stopped {
            lastError = "Backend beklenmedik şekilde kapandı (exit \(process?.terminationStatus ?? -1))"
            state = .failed
        }
        process = nil
        try? logHandle?.close()
        logHandle = nil
    }

    private func startHealthPolling(baseURL: URL) {
        healthTask?.cancel()
        let url = baseURL.appendingPathComponent("health")
        healthTask = Task { [weak self] in
            for attempt in 1...60 {
                if Task.isCancelled { return }
                do {
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 2.0
                    let (_, resp) = try await URLSession.shared.data(for: req)
                    if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                        await MainActor.run { self?.state = .ready }
                        return
                    }
                } catch {
                    // bekle, tekrar dene
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if attempt == 60 {
                    await MainActor.run {
                        self?.lastError = "Backend 60 saniye içinde hazır olmadı"
                        self?.state = .failed
                    }
                }
            }
        }
    }

    private func forwardPipe(_ pipe: Pipe, to handle: FileHandle) {
        pipe.fileHandleForReading.readabilityHandler = { reader in
            let data = reader.availableData
            if !data.isEmpty {
                try? handle.write(contentsOf: data)
            }
        }
    }

    private struct BackendLaunch {
        let executable: URL
        let args: [String]
        let cwd: URL?
        let isDev: Bool   // true → venv/uvicorn (canlı kaynak), false → PyInstaller binary
    }

    private func resolveBackendLaunch(port: Int) throws -> BackendLaunch {
        let portArgs = ["--host", "127.0.0.1", "--port", "\(port)"]

        // 1) Bundle içinden (release / Xcode Run with bundled resources)
        // build-app.sh: cp -R dist/ykorch-api → Resources/backend
        if let resourcePath = Bundle.main.resourcePath {
            let bundled = URL(fileURLWithPath: resourcePath)
                .appendingPathComponent("backend")
                .appendingPathComponent("ykorch-api")
            if FileManager.default.isExecutableFile(atPath: bundled.path) {
                return BackendLaunch(executable: bundled, args: portArgs, cwd: nil, isDev: false)
            }
        }

        let root = URL(fileURLWithPath: "/Users/\(NSUserName())/Desktop/Automated Report")

        // 2) Dev (en hızlı): lokal .venv + uvicorn ile canlı kaynaktan çalış.
        //    Python değişikliği PyInstaller rebuild gerektirmez — sadece app restart.
        let venvPy = root.appendingPathComponent(".venv/bin/python")
        let apiDir = root.appendingPathComponent("apps/api")
        if FileManager.default.isExecutableFile(atPath: venvPy.path),
           FileManager.default.fileExists(atPath: apiDir.appendingPathComponent("app/main.py").path) {
            return BackendLaunch(
                executable: venvPy,
                args: ["-m", "uvicorn", "app.main:app"] + portArgs,
                cwd: apiDir,
                isDev: true
            )
        }

        // 3) Eski dev fallback: PyInstaller dist binary
        let distBinary = root.appendingPathComponent("build/dist/ykorch-api/ykorch-api")
        if FileManager.default.isExecutableFile(atPath: distBinary.path) {
            return BackendLaunch(executable: distBinary, args: portArgs, cwd: nil, isDev: false)
        }

        throw NSError(domain: "YKOrchestrator", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "ykorch-api başlatılamadı (bundle / .venv / dist yollarının hiçbiri bulunamadı)"
        ])
    }

    private func buildEnvironment(config: ConfigSnapshot, isDev: Bool) -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        // Keychain'den token'lar
        let tokens = KeychainStore.shared.readAllAsEnv()
        for (k, v) in tokens { env[k] = v }

        // Config'den ENV override
        for (k, v) in config.envOverrides { env[k] = v }

        // Bundled mod (paths.py is_frozen=true zorlamasa da emniyet)
        env["YKORCH_DEV"] = "0"

        if isDev {
            // Venv backend kaynak ağacından çalışır → paths.py dev moda düşerdi.
            // Gerçek bundled config/DB/log'a bağlamak için override geç.
            let appSupport = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("YK Orchestrator")
            let logs = FileManager.default
                .urls(for: .libraryDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Logs/YK Orchestrator")
            if let appSupport { env["YKORCH_DATA_DIR"] = appSupport.path }
            if let logs { env["YKORCH_LOG_DIR"] = logs.path }
        }

        return env
    }

    // MARK: - Port discovery

    private static func findFreePort() throws -> Int {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw NSError(domain: "YKOrchestrator", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "socket() başarısız"])
        }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult >= 0 else {
            throw NSError(domain: "YKOrchestrator", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "bind() başarısız"])
        }

        var assignedAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getResult = withUnsafeMutablePointer(to: &assignedAddr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(sock, sa, &len)
            }
        }
        guard getResult >= 0 else {
            throw NSError(domain: "YKOrchestrator", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "getsockname() başarısız"])
        }
        return Int(UInt16(bigEndian: assignedAddr.sin_port))
    }
}
