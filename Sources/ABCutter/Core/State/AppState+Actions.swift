import Foundation
import SwiftUI

/// Which inspector the right-hand column is showing.
///
/// Everything used to be stacked in one scroll, which made a seven-card column
/// out of settings that are consulted at four different moments.
enum InspectorTab: String, CaseIterable, Identifiable {
    case clips
    case cover
    case export

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clips: "Clips"
        case .cover: "Titelbild"
        case .export: "Export"
        }
    }

    var symbol: String {
        switch self {
        case .clips: "scissors"
        case .cover: "photo"
        case .export: "square.and.arrow.up"
        }
    }
}

// MARK: - Bindings shared by the inspector panels

extension AppState {
    /// Writes an export setting and re-applies it to the preview, so the look
    /// controls and the burnt-in furniture stay in step with what will be
    /// encoded.
    func exportBinding<Value>(_ keyPath: WritableKeyPath<ExportSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.project.export[keyPath: keyPath] },
            set: { newValue in
                self.project.export[keyPath: keyPath] = newValue
                self.applyPlayerSettings()
            }
        )
    }

    /// Writes into the *selected clip's* look and re-applies the preview.
    /// Reading with no clip selected returns defaults; writing then is a
    /// no-op, and the panel disables itself before it comes to that.
    func lookBinding<Value>(_ keyPath: WritableKeyPath<ClipLook, Value>) -> Binding<Value> {
        Binding(
            get: { (self.selectedClip?.look ?? ClipLook())[keyPath: keyPath] },
            set: { newValue in
                guard var clip = self.selectedClip else { return }
                clip.look[keyPath: keyPath] = newValue
                self.updateClip(clip)
                self.refreshPreviewLabels()
                self.refreshTitleCardPreview()
            }
        )
    }

    /// Writes a cover-image setting and re-renders its preview.
    func stillBinding<Value>(_ keyPath: WritableKeyPath<StillSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.project.stills[keyPath: keyPath] },
            set: { newValue in
                self.project.stills[keyPath: keyPath] = newValue
                self.refreshTitleCardPreview()
            }
        )
    }
}

// MARK: - Actions the menus drive

extension AppState {
    var hasSelectedClip: Bool { selectedClip != nil }

    func deleteSelectedClip() {
        guard let clip = selectedClip else { return }
        removeClip(clip)
    }

    /// Steps through clips in timeline order rather than creation order, which
    /// is what the eye expects when they have been dragged about.
    func selectAdjacentClip(offset: Int) {
        guard !project.clips.isEmpty else { return }
        let ordered = project.clips.sorted { $0.start < $1.start }
        guard let current = ordered.firstIndex(where: { $0.id == selectedClipID }) else {
            selectClip(ordered[0])
            return
        }
        let target = min(max(current + offset, 0), ordered.count - 1)
        selectClip(ordered[target])
    }

    func goToSelectedClipStart() {
        guard let clip = selectedClip else { return }
        player.seek(to: clip.start)
    }

    func goToSelectedClipSplit() {
        guard let clip = selectedClip else { return }
        player.seek(to: clip.splitTime)
    }

    func goToSelectedClipEnd() {
        guard let clip = selectedClip else { return }
        player.seek(to: clip.end)
    }

    /// Which source the A or B side resolves to right now, following the
    /// clip's override and then the project default.
    func resolvedSideID(before: Bool) -> UUID? {
        if let clip = selectedClip {
            return before ? project.beforeSource(for: clip)?.id : project.afterSource(for: clip)?.id
        }
        return before
            ? (project.defaultBeforeSourceID ?? project.audioSources.first?.id)
            : (project.defaultAfterSourceID ?? project.audioSources.first?.id)
    }

    /// Solos one side of the A/B outright, or returns to following the
    /// switches when that side is already soloed. A straight comparison is
    /// what an ear wants, and it is also the quickest way to tell whether a
    /// source is audible at all.
    func monitorOnlySide(before: Bool) {
        guard let id = resolvedSideID(before: before) else { return }
        if case .single(let current) = player.monitorMode, current == id {
            player.monitorMode = .followSplit
        } else {
            player.monitorMode = .single(id)
        }
        applyPlayerSettings()
    }

    func setPreviewFormat(_ format: SocialFormat?) {
        player.previewFormat = format
        applyPlayerSettings()
    }

    func zoomTimeline(by factor: Double) {
        zoom = min(max(zoom * factor, 1), 400)
    }

    func showInspector(_ tab: InspectorTab) {
        inspectorTab = tab
    }

    /// A one-line summary of where the project stands, for the status bar.
    var summaryLine: String {
        guard project.hasVideo else { return status }
        let enabled = project.clips.filter { $0.isEnabled && $0.duration > 0 }.count
        var parts = ["\(project.clips.count) Clip\(project.clips.count == 1 ? "" : "s")"]
        if enabled != project.clips.count { parts.append("\(enabled) aktiv") }
        parts.append("\(project.audioSources.count) Tonspuren")
        if let folder = project.export.outputFolderURL {
            parts.append("→ \(folder.lastPathComponent)")
        }
        return parts.joined(separator: " · ")
    }
}
