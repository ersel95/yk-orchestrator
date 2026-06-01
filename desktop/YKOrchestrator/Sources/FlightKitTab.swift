import SwiftUI

/// MainView içinde TestFlight tab'ını FlightKit'in FKContentView'e bağlayan wrapper.
/// FKProjectStore @State olarak burada doğar — view yeniden render'larında kaybolmaz.
@MainActor
struct FlightKitTab: View {
    @State private var store = FKProjectStore()

    var body: some View {
        FKContentView(store: store)
    }
}
