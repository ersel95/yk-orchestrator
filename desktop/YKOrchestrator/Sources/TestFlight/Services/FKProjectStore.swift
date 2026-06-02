//
//  FKProjectStore.swift
//  FlightKit
//
//  Created by Mr. t.
//

import Foundation
import Observation

/// TestFlight app kataloğu — artık genel proje DB'sinden (`/api/projects`) türetilir.
/// FlightKit kendi JSON kataloğunu tutmaz; app'ler Genel Ayarlar'dan yönetilir.
/// `ProjectBridge` her DB projesini bir `AppProject`'e çevirir.
@MainActor
@Observable
final class FKProjectStore {
    private(set) var projects: [AppProject] = []
    private(set) var loadError: String?
    /// Bumped whenever a project's API key is saved/deleted. Views that show a
    /// credential indicator (the sidebar) read this so they re-check the Keychain.
    private(set) var credentialsRevision = 0

    private var client: APIClient?

    init() {}

    /// Genel projeleri DB'den çekip `AppProject` listesine türetir.
    func refresh(client: APIClient) async {
        self.client = client
        do {
            let resp = try await client.listProjects()
            projects = resp.projects
                .filter { !$0.is_archived }
                .map(ProjectBridge.appProject(from:))
            loadError = nil
        } catch {
            if error.isCancellation { return }
            loadError = error.localizedDescription
        }
    }

    /// Call after saving/deleting an API key so credential indicators refresh.
    func credentialsChanged() {
        credentialsRevision += 1
    }

    // App ekleme/silme/düzenleme artık Genel Ayarlar'da (DB). Bu metodlar
    // FlightKit'in eski editör çağrılarının derlenmesi için no-op olarak kalır.
    func add(_ project: AppProject) {}
    func update(_ project: AppProject) {}
    func delete(_ project: AppProject) {}
}
