import Foundation

/// Where this copy of the app runs from: a copy opened straight from its
/// disk image can't update itself (the image is read-only) and lives on in
/// it after an uninstall (29.10: Install Update sent the owner to GitHub,
/// and a wipe left the copy in the open image running). The part that needs
/// no AppKit; MoveToApplications.swift asks and moves.
enum AppPlace {
    /// On a disk image (a read-only volume), or in the read-only copy macOS
    /// makes of a quarantined app opened where it was downloaded (App
    /// Translocation).
    static func needsMove(path: String, readOnlyVolume: Bool) -> Bool {
        readOnlyVolume || path.contains("/AppTranslocation/")
    }

    /// The disk image to eject once this copy has quit: the volume it runs
    /// from, when that's one under /Volumes and among the mounted `images`
    /// (hdiutil's mount points: a read-only stick or share stays; a
    /// translocated copy's volume is macOS's own, left alone too).
    static func imageToEject(path: String, volume: String?, images: [String]) -> String? {
        guard let volume, volume.hasPrefix("/Volumes/"), !path.contains("/AppTranslocation/") else { return nil }
        let root = volume.hasSuffix("/") ? String(volume.dropLast()) : volume
        let mounted = images.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        return path.hasPrefix(root + "/") && mounted.contains(root) ? root : nil
    }

    /// The copy already in Applications: none or an older one is replaced,
    /// the same version or a newer one opened instead.
    static func replaces(installed: String?, with version: String) -> Bool {
        guard let installed else { return true }
        return UpdateCheck.isNewer(version, than: installed)
    }
}
