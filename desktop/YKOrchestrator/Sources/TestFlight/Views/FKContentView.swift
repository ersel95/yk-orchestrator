//
//  FKContentView.swift
//  FlightKit
//
//  Created by Mr. t.
//

import SwiftUI

@MainActor
struct FKContentView: View {
    @Bindable var store: FKProjectStore
    /// Soldaki ProjectSwitcher'dan gelen aktif proje (DB Project.id).
    let activeProjectId: Int?

    /// Ayrı bir proje listesi YOK — aktif proje (ProjectSwitcher dropdown) gösterilir.
    private var selectedProject: AppProject? {
        if let id = activeProjectId {
            return store.projects.first { $0.id == String(id) }
        }
        return store.projects.first
    }

    var body: some View {
        Group {
            if let project = selectedProject {
                FKProjectDetailView(project: project, store: store)
                    .id(project.id)
            } else {
                emptyDetail
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyDetail: some View {
        ContentUnavailableView {
            Label("TestFlight yapılandırılmadı", systemImage: "airplane.departure")
        } description: {
            Text("Bu projenin TestFlight bilgisi yok. Genel Ayarlar → Projeler → Düzenle → \"TestFlight yapılandır\" ile klasörü seçip otomatik keşfedin.")
        }
    }
}
