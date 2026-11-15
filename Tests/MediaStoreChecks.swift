import Foundation

@main
struct MediaStoreChecks {
    static func expect(_ value: Bool, _ message: String) {
        precondition(value, message)
    }

    static func main() throws {
        let fm = FileManager.default
        let testHome = fm.temporaryDirectory.appendingPathComponent("StreamBrowser-store-tests-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: testHome, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: testHome) }
        let store = MediaStore(home: testHome)
        let payload = Data("downloaded-video-test-payload".utf8)

        // Process death after intent is durable but before moving the file.
        let firstID = UUID()
        let first = try store.webDestination(firstID, ext: "mp4")
        try payload.write(to: first)
        let firstIntent = try store.prepareImport(first, id: firstID, kind: .file, name: "first")
        try store.cleanup(LibraryData(), jobs: [:])
        expect(fm.fileExists(atPath: first.path), "Cleanup deleted a prepared private download")
        var firstResult = LibraryData()
        try store.recoverImports(&firstResult)
        expect(firstResult.media.count == 1, "Prepared import was not recovered")
        try expect(Data(contentsOf: store.resolve(firstIntent.item.location)) == payload, "Recovered bytes changed")

        // Process death after move, before the library commit.
        let secondID = UUID()
        let second = try store.webDestination(secondID, ext: "mp4")
        try payload.write(to: second)
        let secondIntent = try store.prepareImport(second, id: secondID, kind: .file, name: "second")
        _ = try store.finalFile(second, id: secondID)
        try store.cleanup(firstResult, jobs: [:])
        var afterMove = firstResult
        try store.recoverImports(&afterMove)
        expect(afterMove.media.count == 2, "Moved file was lost before commit")
        try expect(Data(contentsOf: store.resolve(secondIntent.item.location)) == payload, "Moved bytes were lost")

        // Process death after committing the index, before deleting the marker.
        let thirdID = UUID()
        let third = try store.webDestination(thirdID, ext: "mp4")
        try payload.write(to: third)
        let thirdIntent = try store.prepareImport(third, id: thirdID, kind: .file, name: "third")
        _ = try store.finalFile(third, id: thirdID)
        var committed = afterMove
        committed.media.append(thirdIntent.item)
        try store.writeLibrary(committed)
        var replayed = try store.readLibrary()
        try store.recoverImports(&replayed)
        expect(replayed.media.filter { $0.id == thirdID }.count == 1, "Replay duplicated an already committed import")
        expect(!store.hasPendingImport(thirdID), "Committed marker was not removed")

        // A cancelled intent must never become a saved item on relaunch.
        let cancelledID = UUID()
        let cancelledSource = try store.webDestination(cancelledID, ext: "mp4")
        try payload.write(to: cancelledSource)
        let cancelledIntent = try store.prepareImport(cancelledSource, id: cancelledID, kind: .file, name: "cancelled")
        _ = try store.finalFile(cancelledSource, id: cancelledID)
        var excludingCancelled = replayed
        try store.recoverImports(&excludingCancelled, excluding: [cancelledID])
        expect(!excludingCancelled.media.contains { $0.id == cancelledID }, "Cancelled file was imported")
        try store.discardImport(cancelledID, library: replayed)
        try expect(!fm.fileExists(atPath: store.resolve(cancelledIntent.item.location).path), "Cancelled final file survived")
        expect(!store.hasPendingImport(cancelledID), "Cancelled marker survived")

        // Broken index recovery preserves the corrupt evidence and restores bytes.
        let index = store.root.appendingPathComponent("library.json")
        try Data("{ broken index".utf8).write(to: index)
        let repaired = try store.repairLibrary()
        expect(repaired.media.count == 3, "Backup recovery lost committed entries")
        let recoveryFolder = store.root.appendingPathComponent("Recovery")
        try expect(fm.contentsOfDirectory(atPath: recoveryFolder.path).count == 1, "Corrupt index was not preserved")

        // Without a backup, reconstruct finalized files instead of erasing them.
        try store.removeRecoveryCopies()
        try Data("bad index again".utf8).write(to: index)
        let rebuilt = try store.repairLibrary()
        expect(rebuilt.media.count == 3, "Finalized files were not reconstructed")

        // Existing journals decode without the new optional pause field.
        let legacy = Data("{\"mode\":\"hls\",\"ready\":false,\"cancelled\":false}".utf8)
        let oldJob = try JSONDecoder().decode(SystemJob.self, from: legacy)
        expect(oldJob.paused == nil, "Existing journal compatibility broke")

        // Paths may never escape the app container.
        for ref in ["../outside.mp4", "/outside.mp4", "Library/../../outside"] {
            expect((try? store.resolve(ref)) == nil, "Path traversal was accepted")
        }

        // If one recovery succeeds and the next fails, keep the successful commit
        // in memory as well as on disk. Retrying must not overwrite it.
        let goodID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let badID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let goodSource = try store.webDestination(goodID, ext: "mp4")
        let badSource = try store.webDestination(badID, ext: "mp4")
        try payload.write(to: goodSource)
        try payload.write(to: badSource)
        _ = try store.prepareImport(goodSource, id: goodID, kind: .file, name: "recoverable")
        _ = try store.prepareImport(badSource, id: badID, kind: .file, name: "missing")
        try store.remove(badSource)
        var partial = rebuilt
        do {
            try store.recoverImports(&partial)
            preconditionFailure("Recovery accepted a missing file")
        } catch {
            expect(partial.media.contains { $0.id == goodID }, "Later failure rolled back in-memory success")
            try expect(store.readLibrary().media.contains { $0.id == goodID }, "Later failure lost disk commit")
            expect(store.hasPendingImport(badID), "Failed recovery discarded its intent")
        }
        print("Media store recovery checks passed (9 scenarios)")
    }
}
