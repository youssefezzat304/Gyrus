import SwiftUI

struct ContentView: View {
    @StateObject private var session = BrainSession()

    var body: some View {
        BrainView(session: session)
            .overlay(alignment: .topLeading) {
                if session.canGoBack {
                    Button(action: session.goBack) {
                        Label("Back", systemImage: "arrow.left")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(.white.opacity(0.06), in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 28)
                    .padding(.top, 52)
                    .accessibilityHint("Return to the particle brain")
                }
            }
            .frame(minWidth: 900, minHeight: 600)
            .ignoresSafeArea()
            .background(Color(red: 3 / 255, green: 3 / 255, blue: 5 / 255))
            .preferredColorScheme(.dark)
    }
}
