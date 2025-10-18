import SwiftUI

struct HomeView: View {
    @ObservedObject var app: AppState

    var body: some View {
        VStack(spacing: 24) {
            Text("Choose a Tool")
                .font(.largeTitle)
            HStack(spacing: 24) {
                toolCard(title: "Lyric Tool", systemImage: "text.quote") {
                    app.switchTool(.lyrics)
                }
                toolCard(title: "Image Flash", systemImage: "photo.on.rectangle") {
                    app.switchTool(.imageFlash)
                }
                toolCard(title: "Scramble Clip", systemImage: "film") {
                    app.switchTool(.scrambleClip)
                }
            }
            .frame(maxWidth: 720)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private func toolCard(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: systemImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                Text(title)
                    .font(.title2)
            }
            .frame(width: 280, height: 200)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(NSColor.windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.gray.opacity(0.3)))
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 16))
        
    }
}


