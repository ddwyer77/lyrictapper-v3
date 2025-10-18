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
                VStack(spacing: 8) {
                    ScrambleClipTapView(app: app)
                    if app.showLogs { LogsPanelView(logger: app.logger) }
                }
            case .scrambleEdit:
                VStack(spacing: 8) {
                    ScrambleClipEditView(app: app)
                    if app.showLogs { LogsPanelView(logger: app.logger) }
                }
            case .scrambleExport:
                VStack(spacing: 8) {
                    ScrambleClipExportView(app: app)
                    if app.showLogs { LogsPanelView(logger: app.logger) }
                }
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



// Temporary stubs to unblock build if ScrambleClip files are not linked into target
// Remove once LoadVideosView/ScrambleClip* files are present in the project target.
private struct _ScrambleStubView: View {
    var label: String
    var body: some View { Text("\(label) (stub)").foregroundColor(.secondary).padding() }
}

@available(macOS 13.0, *)
struct LoadVideosView: View { let app: AppState; var body: some View { _ScrambleStubView(label: "LoadVideosView") } }
@available(macOS 13.0, *)
struct ScrambleClipTapView: View { let app: AppState; var body: some View { _ScrambleStubView(label: "ScrambleClipTapView") } }
@available(macOS 13.0, *)
struct ScrambleClipEditView: View { let app: AppState; var body: some View { _ScrambleStubView(label: "ScrambleClipEditView") } }
@available(macOS 13.0, *)
struct ScrambleClipExportView: View { let app: AppState; var body: some View { _ScrambleStubView(label: "ScrambleClipExportView") } }
