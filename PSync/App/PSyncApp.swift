import SwiftUI

@main
struct PSyncApp: App {
    @StateObject private var sessionManager = SessionManager()

    var body: some Scene {
        WindowGroup {
            HomeView(session: sessionManager)
        }
    }
}
