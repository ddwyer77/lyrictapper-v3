import SwiftUI

struct ContentView: View {
    @ObservedObject var app: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView(app: app)
                .frame(minWidth: 220)
        } detail: {
            switch app.stage {
            case .home:
                ProjectsLandingView(app: app)
            case .dashboard:
                ProjectsLandingView(app: app)
            case .trimAudio:
                AudioTrimView(app: app)
            case .lyricTakes:
                LyricTakesView(app: app)
            case .loadAudio:
                LoadAudioView(app: app)
            case .enterLyrics:
                LoadLyricsView(app: app)
            case .tap:
                VStack(spacing: 8) {
                    TapView(app: app)
                    if app.showLogs {
                        LogsPanelView(logger: app.logger)
                    }
                }
            case .edit:
                VStack(spacing: 8) {
                    EditView(app: app)
                    if app.showLogs {
                        LogsPanelView(logger: app.logger)
                    }
                }
            case .export:
                VStack(spacing: 8) {
                    ExportView(app: app)
                    if app.showLogs {
                        LogsPanelView(logger: app.logger)
                    }
                }
            case .imageTakes:
                ImageTakesView(app: app)
            case .loadImages:
                LoadImagesView(app: app)
            case .imageTap:
                VStack(spacing: 8) {
                    ImageFlashTapView(app: app)
                    if app.showLogs { LogsPanelView(logger: app.logger) }
                }
            case .imageEdit:
                VStack(spacing: 8) {
                    ImageFlashEditView(app: app)
                    if app.showLogs { LogsPanelView(logger: app.logger) }
                }
            case .imageExport:
                VStack(spacing: 8) {
                    ImageFlashExportView(app: app)
                    if app.showLogs { LogsPanelView(logger: app.logger) }
                }
            case .scrambleTakes:
                Text("Scramble Takes - TBD")
            case .loadVideos:
                LoadVideosView(app: app)
            case .scrambleTap:
                Text("Scramble Tap - TBD")
            case .scrambleEdit:
                Text("Scramble Edit - TBD")
            case .scrambleExport:
                Text("Scramble Export - TBD")
            case .mergeExport:
                VStack(spacing: 8) {
                    MergeExportView(app: app)
                    if app.showLogs { LogsPanelView(logger: app.logger) }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) { Toggle(isOn: $app.showLogs) { Text("Logs") } }
            ToolbarItem(placement: .status) {
                HStack(spacing: 8) {
                    if app.projectManager.dirty { Text("• Unsaved").foregroundColor(.secondary) } else { Text("Saved •").foregroundColor(.secondary) }
                }
            }
        }
    }
}


