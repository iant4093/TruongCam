import CoreGraphics
import Foundation
import Synchronization
#if canImport(XCTest)
@testable import TruongCam
#endif

private final class Drive55Preferences: PreferenceStoring, @unchecked Sendable {
    private struct State {
        var composition = CompositionPreferences()
        var sequence = SequencePlanPreferences()
        var speed = CaptureSpeed.single
        var writes = [0, 0, 0]
    }
    private let state = Mutex(State())
    var writes: [Int] { state.withLock { $0.writes } }
    func loadCompositionPreferences() -> CompositionPreferences? { state.withLock { $0.composition } }
    func storeCompositionPreferences(_ value: CompositionPreferences) { state.withLock { $0.composition = value; $0.writes[0] += 1 } }
    func loadSequencePreferences() -> SequencePlanPreferences? { state.withLock { $0.sequence } }
    func storeSequencePreferences(_ value: SequencePlanPreferences) { state.withLock { $0.sequence = value; $0.writes[1] += 1 } }
    func loadCaptureSpeed() -> CaptureSpeed { state.withLock { $0.speed } }
    func storeCaptureSpeed(_ value: CaptureSpeed) { state.withLock { $0.speed = value; $0.writes[2] += 1 } }
}

enum CameraLayout55Suite {
    static let suite = TCSuite(id: "CameraLayout55", title: "Unobscured framing, bounded latest-photo metadata and drive setup", cases: [
        TCCase(id: "CL55L", title: "Compact, standard and large phone safe areas keep the whole image clear of fixed controls") { r in
            // Actual point sizes, minus representative inherited safe areas. This
            // validates geometry, not actual hardware or a screenshot of each phone.
            let phones: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (320, 568, 20, 0), (375, 667, 20, 0), (375, 812, 44, 34),
                (390, 844, 47, 34), (402, 874, 62, 34), (430, 932, 59, 34), (440, 956, 62, 34)]
            for (w, h, top, bottom) in phones {
                for ax in [false, true] {
                    let safeHeight = h - top - bottom
                    let p = CameraScreenLayout(size: CGSize(width: w, height: safeHeight), bottomSafeArea: bottom, accessibility: ax)
                    let label = "\(w)x\(h), AX=\(ax)"
                    r.close("full portrait aspect \(label)", Double(p.preview.width / p.preview.height), 0.75)
                    r.check("whole portrait stays in safe content \(label)", CGRect(x: 0, y: 0, width: w, height: safeHeight).contains(p.preview))
                    r.check("solid controls clear preview \(label)", p.controls.minY - p.preview.maxY >= 7.999)
                    r.close("shutter remains centered \(label)", Double(p.controls.midX), Double(w / 2))
                    r.check("well remains operable \(label)", p.adjustmentViewportHeight >= 44)
                    r.check("caption is the only safe-area extension \(label)", p.controls.maxY <= safeHeight + min(18, max(0, bottom - 12)))
                    let shutterBottom = p.controls.maxY - 20
                    r.check("interactive shutter clears bottom safe boundary \(label)", shutterBottom <= safeHeight - 2)
                    let fits = p.preview.width <= w && p.preview.height >= 300
                    r.check("minimum compact image preserved \(label)", fits)
                    let lsize = CGSize(width: h - top - max(top, bottom), height: w - (bottom > 0 ? 21 : 0))
                    let l = CameraScreenLayout(size: lsize, bottomSafeArea: bottom > 0 ? 21 : 0, accessibility: ax)
                    let lbounds = CGRect(origin: .zero, size: lsize)
                    r.close("full landscape aspect \(label)", Double(l.preview.width / l.preview.height), 4.0 / 3)
                    r.check("whole landscape and controls inside safe bounds \(label)", lbounds.contains(l.preview) && lbounds.contains(l.controls))
                    r.check("no landscape overlap \(label)", !l.preview.intersects(l.controls))
                    r.check("landscape rail keeps full shutter and readouts \(label)", l.controls.width >= 245 && l.parameterHeight >= 44)
                }
            }
            for value in [CGFloat.nan, .infinity, -1, 0] {
                let p = CameraScreenLayout(size: CGSize(width: value, height: value), bottomSafeArea: value, accessibility: false)
                r.check("invalid geometry never propagates NaN", p.preview.width.isFinite && p.preview.height.isFinite && p.controls.height.isFinite)
            }
        },
        TCCase(id: "CL55P", title: "Drive setup writes only changed preferences while preserving timer and bracket exclusion") { r in
            guard let h = await StorageHarness.make(name: "cl55-drive") else { r.check("fixture", false); return }
            let preferences = Drive55Preferences()
            let (model, _) = await CaptureFormatUISuite.makeModel(h: h, capability: CaptureFormatUISuite.capability(), preferences: preferences)
            let initial = preferences.writes
            await model.setCaptureSpeed(.fps5)
            r.equal("no unchanged composition JSON write", preferences.writes[0], initial[0])
            r.equal("no unchanged sequence JSON write", preferences.writes[1], initial[1])
            r.equal("speed is persisted once", preferences.writes[2], initial[2] + 1)
            let configured = preferences.writes
            await model.setCaptureSpeed(.fps5)
            r.equal("reselecting same speed does no persistence", preferences.writes, configured)
            await model.setTimerSeconds(3)
            let timer = preferences.writes
            await model.setCaptureSpeed(.fps2)
            r.equal("an actual armed timer is cleared once", preferences.writes[0], timer[0] + 1)
            r.equal("unrelated sequence is not rewritten", preferences.writes[1], timer[1])
            r.equal("timer is disabled", await model.timerSeconds, nil)
            await model.setExposureBracketEnabled(true)
            let bracket = preferences.writes
            await model.setCaptureSpeed(.fps1)
            r.equal("actual bracket mode is cleared once", preferences.writes[1], bracket[1] + 1)
            r.equal("unchanged timer is not rewritten", preferences.writes[0], bracket[0])
            r.equal("drive cannot launch an old bracket", await model.activeShutterMode, .single)
            await model.stop()
        },
        TCCase(id: "CL55S", title: "Actual SQLite latest photo is the newest sequence member, independent of its older gallery cover") { r in
            guard let h = await StorageHarness.make(name: "cl55-latest") else { r.check("fixture", false); return }
            let directory = StorageFixture.temporaryDirectory("cl55-latest"), sequence = SequenceID()
            let db = SQLiteIndex(databaseURL: directory.appendingPathComponent("index.sqlite"))
            do {
                try await db.reset(libraryID: h.libraryID, generation: h.generation)
                let ordinary = StorageFixture.cards(count: 12, libraryID: h.libraryID, startingAt: StorageFixture.fixedDate)
                let members = (0..<3).map { i in LibrarySourceCard(captureID: CaptureID(), libraryID: h.libraryID,
                    relativeOriginalPath: "originals/member-\(i).dng", capturedAtUTC: StorageFixture.fixedDate.addingTimeInterval(Double(i + 1)),
                    capturedAtProvenance: .captureMetadata, availability: .local, classification: .verifiedOriginal,
                    rawDimensions: nil, byteCount: nil, sequenceID: sequence, sequenceIndex: i, sequenceKind: .interval,
                    isTruongCamCapture: true, modificationFingerprint: "member-\(i)") }
                try await db.upsert(scanned: ordinary + members)
                let first = try await db.firstPage(size: 2)
                r.equal("newest actual original is last member", first.newestOriginal?.captureID, members[2].captureID)
                r.equal("total still includes every original", first.totalCommittedOriginalCount, 15)
                if case .sequenceCover(_, let cover) = first.cards.first?.kind {
                    r.equal("gallery cover remains first ordinal", cover?.captureID, members[0].captureID)
                } else { r.check("sequence remains grouped", false) }
                if let cursor = first.nextCursor {
                    let next = try await db.page(after: cursor, size: 2)
                    r.equal("later pages do not query/publish another newest photo", next.newestOriginal, nil)
                } else { r.check("actual cursor exists", false) }
                let model = await LibraryViewModel(index: db, store: h.store)
                await model.loadFirstPage()
                r.equal("camera candidate is the actual newest original", await model.newestThumbnailSource?.captureID, members[2].captureID)
                let warm = await model.firstThumbnailSources
                r.equal("warm newest first", warm.first?.captureID, members[2].captureID)
                r.equal("warm list stays bounded", warm.count, 9)
                r.equal("warm list has no duplicates", Set(warm.map(\.captureID)).count, warm.count)
                try await db.reset(libraryID: h.libraryID, generation: h.generation)
                try await db.upsert(scanned: ordinary)
                await model.loadFirstPage()
                r.equal("reconciled deletion picks latest remaining", await model.newestThumbnailSource?.captureID, ordinary[0].captureID)
                await h.store.releaseRoot()
                r.equal("root release hides old thumbnail metadata immediately", await model.newestThumbnailSource, nil)
                await model.invalidateRoot()
                r.equal("invalidated model has no stale warm list", await model.firstThumbnailSources.count, 0)
            } catch { r.check("real SQLite latest metadata", false, String(describing: error)) }
            await db.closeDatabase(); StorageFixture.removeDirectory(directory)
        },
        TCCase(id: "CL55E", title: "Empty and replaced root metadata cannot provide another folder's camera thumbnail") { r in
            guard let h = await StorageHarness.make(name: "cl55-empty") else { r.check("fixture", false); return }
            let directory = StorageFixture.temporaryDirectory("cl55-empty")
            let db = SQLiteIndex(databaseURL: directory.appendingPathComponent("index.sqlite"))
            do {
                try await db.reset(libraryID: h.libraryID, generation: h.generation)
                let model = await LibraryViewModel(index: db, store: h.store)
                await model.loadFirstPage()
                r.equal("empty SQLite has no newest original", await model.newestThumbnailSource, nil)
                let cards = StorageFixture.cards(count: 1, libraryID: h.libraryID, startingAt: StorageFixture.fixedDate)
                try await db.upsert(scanned: cards); await model.loadFirstPage()
                r.equal("new commit publication supplies the shortcut", await model.newestThumbnailSource?.captureID, cards[0].captureID)
                try await db.reset(libraryID: h.libraryID, generation: h.generation); await model.loadFirstPage()
                r.equal("delete-all publication restores icon fallback", await model.newestThumbnailSource, nil)
                try await db.reset(libraryID: LibraryID(), generation: RootGeneration.next(h.generation))
                try await db.upsert(scanned: StorageFixture.cards(count: 1, libraryID: LibraryID(), startingAt: StorageFixture.fixedDate))
                await model.loadFirstPage()
                r.equal("wrong-root index cannot publish a shortcut", await model.newestThumbnailSource, nil)
            } catch { r.check("empty/replaced metadata", false, String(describing: error)) }
            await db.closeDatabase(); StorageFixture.removeDirectory(directory)
        }
    ])
}
