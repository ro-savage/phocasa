import XCTest
import ImageIO
@testable import Phocasa

/// Rating and keyword writes into HEIF files (task D): the XMP item's packet replaced, every other item, box and
/// byte kept (`HEIFMetadata`). Each test proves it with `HEIFProof.assertLossless`, which reads both files with
/// `TestHEIF` (an ISO BMFF reader written apart from the app's) and with ImageIO: item tables, item data, boxes,
/// pixels, auxiliary images, the thumbnail, every property and XMP value, and the rating and keywords read back from
/// the file with no sidecar.
final class HEIFMetadataTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("phocasa-heif-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dir = base.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        if let dir { try FileManager.default.removeItem(at: dir) }
    }

    private typealias Refusal = HEIFMetadata.Refusal

    private func write(_ heif: Data, rating: Int, keywords: [String]) -> Result<HEIFMetadata.Written, Refusal> {
        HEIFMetadata.writingXMP(in: heif) { MetadataService.xmpPacket(rating: rating, keywords: keywords, updating: $0) }
    }

    private static let manyKeywords = ["new", "people:ann example", "places:paris", "events:holiday 2024", "flowers"]

    /// Writes the rating and keywords, checks how, proves nothing was lost, and reads them back from a file on disk
    /// with no sidecar (ImageIO, and `MetadataService.readMetadata`).
    @discardableResult
    private func assertWrites(_ original: Data, rating: Int = 4, keywords: [String] = manyKeywords,
                              _ change: HEIFMetadata.Change?, file: StaticString = #filePath, line: UInt = #line) -> Data? {
        let result = write(original, rating: rating, keywords: keywords)
        guard case .success(let written) = result else {
            XCTFail("the write is refused: \(result)", file: file, line: line)
            return nil
        }
        if let change { XCTAssertEqual(written.change, change, "how the packet was written", file: file, line: line) }
        XCTAssertEqual(HEIFMetadata.replacingXMP(in: original) { MetadataService.xmpPacket(rating: rating, keywords: keywords, updating: $0) },
                       written.data, "replacingXMP gives the same bytes", file: file, line: line)
        HEIFProof.assertLossless(original: original, output: written.data, rating: rating, keywords: keywords, file: file, line: line)

        let url = dir.appendingPathComponent("\(UUID().uuidString).heic")
        XCTAssertNoThrow(try written.data.write(to: url), file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.xmpSidecarURL.path), "no sidecar", file: file, line: line)
        let read = MetadataService.shared.readMetadata(from: url.path)
        XCTAssertEqual(read.rating, rating, "readMetadata's rating, from the file", file: file, line: line)
        XCTAssertEqual(read.keywords, keywords, "readMetadata's keywords, from the file", file: file, line: line)
        return written.data
    }

    private func refusal(_ heif: Data, file: StaticString = #filePath, line: UInt = #line) -> Refusal? {
        guard case .failure(let refusal) = write(heif, rating: 3, keywords: ["k"]) else { return nil }
        XCTAssertNil(HEIFMetadata.replacingXMP(in: heif) { MetadataService.xmpPacket(rating: 3, keywords: ["k"], updating: $0) },
                     file: file, line: line)
        return refusal
    }

    private func model(_ heif: Data) throws -> HEIFModel {
        try XCTUnwrap(TestHEIF(heif).flatMap(HEIFModel.init), "fixture: the test reader and builder read it")
    }

    // MARK: - Recognising HEIF

    func testRecognisesHEIFByItsBrands() throws {
        let heic = HEIFFixtures.heic(width: 320, height: 240)
        XCTAssertTrue(HEIFMetadata.isHEIF(heic))
        XCTAssertTrue(HEIFMetadata.isHEIF(HEIFFixtures.heic(width: 320, height: 240, type: "public.avif")), "AV1 in HEIF")
        XCTAssertTrue(HEIFMetadata.isHEIF((Data(repeating: 7, count: 13) + heic).dropFirst(13)), "a slice")
        XCTAssertFalse(HEIFMetadata.isHEIF(MetadataJPEGPreservationTests.imageIOJPEG()))
        XCTAssertFalse(HEIFMetadata.isHEIF(Data()))
        XCTAssertFalse(HEIFMetadata.isHEIF(Data(HEIFModel.box("ftyp", Array("isom".utf8) + [0, 0, 2, 0] + Array("isommp41".utf8)))),
                       "an MP4")
    }

    // MARK: - ImageIO's (and the iPhone's) HEICs

    /// A HEIC as Apple's writer lays it out, rich with metadata and auxiliary images, with another app's XMP item.
    func testAHEICWithAnXMPItemGetsTheNewPacketAppendedAndKeepsEverything() throws {
        let original = HEIFFixtures.heic(auxiliary: true)
        let heif = try XCTUnwrap(TestHEIF(original))
        XCTAssertEqual(heif.primaryXMP.count, 1, "fixture: an XMP item for the primary image")
        XCTAssertTrue(heif.items.contains { $0.type == "grid" }, "fixture: a grid of tiles")
        XCTAssertEqual(heif.references.filter { $0.type == "auxl" }.count, 3, "fixture: depth, gain map and matte")
        XCTAssertEqual(heif.references.filter { $0.type == "thmb" }.count, 1, "fixture: a thumbnail")
        XCTAssertEqual(MetadataService.shared.readMetadata(from: try fileURL(original)).rating, 2, "fixture: rated 2 by another app")

        let output = try XCTUnwrap(assertWrites(original, .appended))

        // The old packet is still in the file, unreferenced; the new one is in a new mdat at the end.
        let after = try XCTUnwrap(TestHEIF(output))
        let oldPacket = try XCTUnwrap(heif.data(of: heif.primaryXMP[0].id))
        XCTAssertNotNil(output.range(of: Data(oldPacket)), "the old packet's bytes stay where they were")
        XCTAssertEqual(after.top.map(\.type), ["ftyp", "meta", "mdat", "mdat"])
        XCTAssertEqual(output.count, original.count + 8 + (after.data(of: heif.primaryXMP[0].id)?.count ?? 0))
    }

    private func fileURL(_ data: Data) throws -> String {
        let url = dir.appendingPathComponent("\(UUID().uuidString).heic")
        try data.write(to: url)
        return url.path
    }

    /// Without an XMP item for the primary image (the auxiliary images have theirs), a new item is added: meta grows,
    /// and every item after it moves.
    func testAHEICWithoutAnXMPItemGetsANewOne() throws {
        let original = HEIFFixtures.heic(xmp: nil, auxiliary: true)
        let heif = try XCTUnwrap(TestHEIF(original))
        XCTAssertTrue(heif.primaryXMP.isEmpty, "fixture: no XMP for the primary image")
        XCTAssertEqual(heif.xmpItems.count, 3, "fixture: the auxiliary images' XMP items")

        let output = try XCTUnwrap(assertWrites(original, .newItem))

        let after = try XCTUnwrap(TestHEIF(output))
        let growth = after.meta.end - heif.meta.end
        XCTAssertGreaterThan(growth, 0, "meta grew")
        for location in heif.locations where location.method == 0 {
            let before = try XCTUnwrap(heif.ranges(of: location.id)), now = try XCTUnwrap(after.ranges(of: location.id))
            XCTAssertEqual(now.map(\.lowerBound), before.map { $0.lowerBound + growth }, "item \(location.id) moved with meta")
        }
        XCTAssertEqual(after.primaryXMP.first?.id, (heif.items.map(\.id).max() ?? 0) + 1, "the next free ID")
    }

    /// A HEIC with pixels only: no Exif, thumbnail or XMP, and so no `iref` at all.
    func testAHEICWithNoMetadataGetsAnItemAndAReferenceBox() throws {
        let original = HEIFFixtures.heic(width: 320, height: 240, xmp: nil, exif: false, thumbnail: false)
        XCTAssertNil(try XCTUnwrap(TestHEIF(original)).node("iref"), "fixture: no iref")

        let output = try XCTUnwrap(assertWrites(original, .newItem))

        XCTAssertNotNil(try XCTUnwrap(TestHEIF(output)).node("iref"))
    }

    /// An iPhone-sized photo: 4032×3024 in 48 tiles, a thumbnail, depth, an HDR gain map and a matte.
    func testAnIPhoneSizedHEIC() throws {
        let original = HEIFFixtures.heic(width: 4032, height: 3024, auxiliary: true)
        XCTAssertEqual(try XCTUnwrap(TestHEIF(original)).references.first { $0.type == "dimg" }?.to.count, 48,
                       "fixture: 48 tiles")
        let once = try XCTUnwrap(assertWrites(original, .appended))
        assertWrites(once, rating: 1, keywords: ["a"], .inPlace)
        let noXMP = HEIFFixtures.heic(width: 4032, height: 3024, xmp: nil, auxiliary: true)
        assertWrites(noXMP, .newItem)
    }

    /// An HDR photo with an ISO 21496-1 gain map: a `tmap` item in `idat` and an `altr` entity group, whose ID the new
    /// item must not take.
    func testAnHDRPhotoWithAnISOGainMap() throws {
        guard #available(macOS 15, *) else { throw XCTSkip("ISO gain maps need macOS 15") }
        let original = HEIFFixtures.isoGainMapHEIC()
        let heif = try XCTUnwrap(TestHEIF(original))
        XCTAssertTrue(heif.items.contains { $0.type == "tmap" }, "fixture: a tone-map item")
        let group = try XCTUnwrap(heif.groups.first, "fixture: an entity group")
        XCTAssertEqual(group.type, "altr")
        XCTAssertNotNil(HEIFProof.auxiliary(original)[kCGImageAuxiliaryDataTypeISOGainMap as String], "fixture: ImageIO sees the gain map")

        let output = try XCTUnwrap(assertWrites(original, .newItem))

        let id = try XCTUnwrap(TestHEIF(output)?.primaryXMP.first?.id)
        XCTAssertEqual(id, max(heif.items.map(\.id).max() ?? 0, group.id) + 1, "an ID no item or group has")

        var withXMP = try model(original)
        withXMP.addXMP(HEIFFixtures.otherAppXMP, id: max(withXMP.maxID, group.id) + 1)
        assertWrites(withXMP.bytes(), .tail)  // the builder puts the new item's data last
    }

    /// A spatial photo: two images in a `ster` group, which has a property association of its own.
    func testASpatialPhoto() throws {
        let original = HEIFFixtures.stereoHEIC()
        let heif = try XCTUnwrap(TestHEIF(original))
        let group = try XCTUnwrap(heif.groups.first { $0.type == "ster" }, "fixture: a stereo pair")
        XCTAssertTrue(heif.associations.contains { $0.id == group.id }, "fixture: ipma names the group")

        let output = try XCTUnwrap(assertWrites(original, .newItem))

        let id = try XCTUnwrap(TestHEIF(output)?.primaryXMP.first?.id)
        XCTAssertNotEqual(id, group.id)
        XCTAssertEqual(id, max(heif.items.map(\.id).max() ?? 0, group.id) + 1)

        var withXMP = try model(original)
        withXMP.addXMP(HEIFFixtures.otherAppXMP, id: max(withXMP.maxID, group.id) + 1)
        assertWrites(withXMP.bytes(), .tail)  // the builder puts the new item's data last
    }

    /// AV1 in HEIF (ImageIO can't write HEVC's sibling AVC): the codec doesn't matter.
    func testAHEIFWithAnotherCodec() throws {
        let original = HEIFFixtures.heic(width: 640, height: 480, type: "public.avif")
        XCTAssertTrue(try XCTUnwrap(TestHEIF(original)).items.contains { $0.type == "av01" }, "fixture: AV1")
        assertWrites(original, nil)
        let noXMP = HEIFFixtures.heic(width: 640, height: 480, xmp: nil, type: "public.avif")
        assertWrites(noXMP, .newItem)
    }

    func testWorksOnADataSlice() throws {
        let original = HEIFFixtures.heic(width: 320, height: 240)
        let slice = (Data(repeating: 0xAA, count: 21) + original).dropFirst(21)
        XCTAssertNotEqual(slice.startIndex, 0)
        let fromSlice = try write(slice, rating: 5, keywords: ["s"]).get().data
        XCTAssertEqual(fromSlice, try write(original, rating: 5, keywords: ["s"]).get().data)
    }

    // MARK: - Repeated writes

    func testRepeatedWritesStayBoundedAndStable() throws {
        for original in [HEIFFixtures.heic(auxiliary: true), HEIFFixtures.heic(xmp: nil, auxiliary: true)] {
            var current = original
            var largestPacket = 0
            var growths = 0
            let lists: [[String]] = [["a"], Self.manyKeywords, [], (0..<30).map { "keyword \($0)" }, ["b"], [], Self.manyKeywords]
            for (step, keywords) in lists.enumerated() {
                let rating = step % 6
                let written = try write(current, rating: rating, keywords: keywords).get()
                HEIFProof.assertLossless(original: current, output: written.data, rating: rating, keywords: keywords)
                // The packet moves to the end of the file at most once; then it's replaced there.
                if [.appended, .newItem].contains(written.change) { growths += 1 }
                XCTAssertLessThanOrEqual(growths, 1, "step \(step): \(written.change)")
                let after = try XCTUnwrap(TestHEIF(written.data))
                let packet = try XCTUnwrap(after.data(of: try XCTUnwrap(after.primaryXMP.first).id)).count
                largestPacket = max(largestPacket, packet)
                let metaGrowth = after.meta.end - (TestHEIF(original)?.meta.end ?? 0)
                XCTAssertLessThanOrEqual(written.data.count, original.count + metaGrowth + 8 + largestPacket,
                                         "step \(step): the file holds at most one new packet")
                // The same values again change nothing.
                XCTAssertEqual(try write(written.data, rating: rating, keywords: keywords).get().data, written.data, "step \(step)")
                current = written.data
            }
        }
    }

    // MARK: - Every legal layout

    private struct Variant {
        let name: String
        let layout: HEIFModel.Layout
        var xmpInIdat = false
        var noIdat = false
    }

    private static var variants: [Variant] {
        var v: [Variant] = []
        func add(_ name: String, xmpInIdat: Bool = false, noIdat: Bool = false, _ change: (inout HEIFModel.Layout) -> Void) {
            var layout = HEIFModel.Layout()
            change(&layout)
            v.append(Variant(name: name, layout: layout, xmpInIdat: xmpInIdat, noIdat: noIdat))
        }
        add("iloc v1 4/4/0 (ImageIO's)") { _ in }
        add("iloc v0 4/4/0", noIdat: true) { $0.ilocVersion = 0 }
        add("iloc v0 8/8/8 with base offsets", noIdat: true) {
            $0.ilocVersion = 0; $0.offsetSize = 8; $0.lengthSize = 8; $0.baseOffsetSize = 8; $0.useBaseOffsets = true
        }
        add("iloc v1 8/8/0") { $0.offsetSize = 8; $0.lengthSize = 8 }
        add("iloc v1 4/4/4 with base offsets") { $0.baseOffsetSize = 4; $0.useBaseOffsets = true }
        add("iloc v1 0/4/4, all in base offsets") { $0.offsetSize = 0; $0.baseOffsetSize = 4; $0.useBaseOffsets = true }
        add("iloc v2 4/8/8") { $0.ilocVersion = 2; $0.lengthSize = 8; $0.baseOffsetSize = 8 }
        add("iinf v1, iref v1") { $0.iinfVersion = 1; $0.irefVersion = 1 }
        add("mdat before meta") { $0.mdatBeforeMeta = true }
        add("free box after meta") { $0.freeAfterMeta = 64 }
        add("iloc before iinf (libheif's order)") { $0.ilocFirst = true }
        add("free box in meta") { $0.freeInMeta = 32 }
        add("mdat to the end of the file") { $0.mdatToEnd = true }
        add("mdat with a 64-bit size") { $0.mdatLargeSize = true }
        add("XMP in idat", xmpInIdat: true) { _ in }
        return v
    }

    private func variantModel(_ base: HEIFModel, _ variant: Variant) -> HEIFModel {
        var model = base
        for i in model.items.indices {
            if variant.noIdat { model.items[i].inIdat = false }
            if variant.xmpInIdat, model.items[i].contentType == "application/rdf+xml",
               model.references.contains(where: { $0.type == "cdsc" && $0.from == model.items[i].id && $0.to == [model.primary] }) {
                model.items[i].inIdat = true
            }
        }
        return model
    }

    @MainActor func testEveryLayoutWithAnXMPItem() throws {
        let original = HEIFFixtures.heic(auxiliary: true)
        let base = try model(original)
        for variant in Self.variants {
            let file = variantModel(base, variant).bytes(variant.layout)
            XCTAssertTrue(HEIFProof.pixels(file) == HEIFProof.pixels(original), "\(variant.name): fixture decodes like ImageIO's")
            XCTAssertEqual(HEIFProof.auxiliary(file), HEIFProof.auxiliary(original), "\(variant.name): fixture's auxiliary images")
            XCTContext.runActivity(named: variant.name) { _ in
                let once = assertWrites(file, nil)
                if let once { assertWrites(once, rating: 2, keywords: ["x"], nil) }
            }
        }
    }

    @MainActor func testEveryLayoutWithoutAnXMPItem() throws {
        var base = try model(HEIFFixtures.heic(auxiliary: true))
        base.removeXMP()
        for variant in Self.variants where !variant.xmpInIdat {
            let file = variantModel(base, variant).bytes(variant.layout)
            XCTContext.runActivity(named: variant.name) { _ in
                let once = assertWrites(file, .newItem)
                if let once { assertWrites(once, rating: 2, keywords: ["x"], nil) }
            }
        }
    }

    /// A packet with room to spare (XMP padding) is overwritten where it is: nothing else in the file changes.
    func testAPaddedPacketIsOverwrittenInPlace() throws {
        var model = try model(HEIFFixtures.heic(auxiliary: true))
        model.removeXMP()
        let padded = HEIFFixtures.otherAppXMP.replacingOccurrences(
            of: "<?xpacket end", with: String(repeating: " ", count: 4000) + "\n<?xpacket end")
        model.addXMP(padded)
        let original = model.bytes()
        let heif = try XCTUnwrap(TestHEIF(original))
        let packet = try XCTUnwrap(heif.ranges(of: heif.primaryXMP[0].id)?.first)

        let output = try XCTUnwrap(assertWrites(original, .inPlace))

        XCTAssertEqual(output.count, original.count, "the same size")
        XCTAssertEqual(output.subdata(in: 0..<packet.lowerBound), original.subdata(in: 0..<packet.lowerBound),
                       "every byte before the packet")
        XCTAssertEqual(output.subdata(in: packet.upperBound..<output.count), original.subdata(in: packet.upperBound..<original.count),
                       "every byte after it")
    }

    /// A packet at the end of the file is replaced there: the file doesn't grow by the old packet.
    func testAPacketAtTheEndOfTheFileIsReplacedThere() throws {
        let base = try model(HEIFFixtures.heic(auxiliary: true))
        let xmpID = try XCTUnwrap(TestHEIF(HEIFFixtures.heic(auxiliary: true))?.primaryXMP.first?.id)
        for mdatToEnd in [false, true] {
            var layout = HEIFModel.Layout()
            layout.last = [xmpID]
            layout.mdatToEnd = mdatToEnd
            let original = base.bytes(layout)
            let old = try XCTUnwrap(TestHEIF(original)?.data(of: xmpID))

            let output = try XCTUnwrap(assertWrites(original, .tail))

            let new = try XCTUnwrap(TestHEIF(output)?.data(of: xmpID))
            XCTAssertEqual(output.count, original.count - old.count + new.count)
        }
    }

    // MARK: - The last resort: what's refused

    func testRefusesWhatIsNotHEIF() {
        XCTAssertEqual(refusal(MetadataJPEGPreservationTests.imageIOJPEG()), .notHEIF)
        XCTAssertEqual(refusal(Data("not an image".utf8)), .notHEIF)
    }

    func testRefusesMalformedFiles() throws {
        let original = HEIFFixtures.heic(width: 320, height: 240)
        XCTAssertEqual(refusal(original.dropLast(40)), .malformed, "truncated: an extent past the end")
        var oversized = original
        oversized[oversized.startIndex] = 0x7F  // ftyp's size runs past the file
        XCTAssertEqual(refusal(oversized), .notHEIF)
        var longFtyp = original
        longFtyp[longFtyp.startIndex + 3] = 0xFF  // ftyp runs into meta
        XCTAssertEqual(refusal(longFtyp), .malformed)
        var metaSize = original
        let meta = try XCTUnwrap(TestHEIF(original)?.meta)
        metaSize[meta.start + 3] &+= 1  // meta's children no longer fill it
        XCTAssertEqual(refusal(metaSize), .malformed)
    }

    /// An image sequence (`.heics`, and a burst or animation saved as HEIC) has a `moov` whose sample tables hold
    /// absolute offsets.
    func testRefusesAnImageSequence() {
        XCTAssertEqual(refusal(HEIFFixtures.sequenceHEICS()), .unsupportedTopLevelBox("moov"))
    }

    /// A Samsung motion photo keeps its video in a top-level `mpvd` box; `uuid` boxes can hold anything.
    func testRefusesTopLevelBoxesItDoesNotKnow() throws {
        let base = try model(HEIFFixtures.heic(width: 320, height: 240))
        for type in ["mpvd", "uuid", "moof"] {
            var layout = HEIFModel.Layout()
            layout.trailingBox = (type, [UInt8](repeating: 1, count: 40))
            XCTAssertEqual(refusal(base.bytes(layout)), .unsupportedTopLevelBox(type), type)
        }
    }

    /// Google's and Samsung's motion photos find their video by its distance from the end of the file.
    func testRefusesAMotionPhoto() throws {
        var model = try model(HEIFFixtures.heic(width: 320, height: 240))
        model.removeXMP()
        model.addXMP(HEIFFixtures.otherAppXMP.replacingOccurrences(
            of: "acme:Flag=\"keep-me\"",
            with: "acme:Flag=\"keep-me\" xmlns:GCamera=\"http://ns.google.com/photos/1.0/camera/\" GCamera:MicroVideo=\"1\" GCamera:MicroVideoOffset=\"4000\""))
        XCTAssertEqual(refusal(model.bytes()), .appendedData)
    }

    func testRefusesMetaBoxesItDoesNotKnow() throws {
        let base = try model(HEIFFixtures.heic(width: 320, height: 240))
        var layout = HEIFModel.Layout()
        layout.extraMetaChild = HEIFModel.box("ipro", [0, 0, 0, 0, 0, 0])
        XCTAssertEqual(refusal(base.bytes(layout)), .unsupportedMetaBox("ipro"), "item protection")
    }

    /// ImageIO reads no `iloc` with extent indexes (`index_size` > 0, legal in versions 1 and 2): a file it can't read
    /// isn't written.
    func testRefusesAFileImageIOCannotRead() throws {
        var layout = HEIFModel.Layout()
        layout.ilocVersion = 2
        layout.indexSize = 4
        let file = try model(HEIFFixtures.heic(width: 320, height: 240)).bytes(layout)
        XCTAssertNil(HEIFProof.pixels(file), "fixture: ImageIO can't decode it")
        XCTAssertEqual(refusal(file), .unreadable)
    }

    func testRefusesVersionsItDoesNotKnow() throws {
        let original = HEIFFixtures.heic(width: 320, height: 240)
        let iloc = try XCTUnwrap(TestHEIF(original)?.node("iloc"))
        var future = original
        future[iloc.bodyStart] = 3
        XCTAssertEqual(refusal(future), .unsupportedVersion("iloc"))
    }

    func testRefusesItemsInOtherFiles() throws {
        var model = try model(HEIFFixtures.heic(width: 320, height: 240))
        let exif = try XCTUnwrap(model.items.firstIndex { $0.type == "Exif" })
        model.items[exif].dataReference = 1
        XCTAssertEqual(refusal(model.bytes()), .externalData)
    }

    func testRefusesItemsLocatedInsideOtherItems() throws {
        var model = try model(HEIFFixtures.heic(width: 320, height: 240))
        let exif = try XCTUnwrap(model.items.firstIndex { $0.type == "Exif" })
        model.items[exif].method = 2
        XCTAssertEqual(refusal(model.bytes()), .unsupportedConstruction)
    }

    func testRefusesExtentsOfLengthZero() throws {
        var model = try model(HEIFFixtures.heic(width: 320, height: 240))
        let exif = try XCTUnwrap(model.items.firstIndex { $0.type == "Exif" })
        model.items[exif].zeroLength = true
        XCTAssertEqual(refusal(model.bytes()), .unboundedExtent)
    }

    /// An item whose data is inside meta can't be moved with it; with an XMP item to replace, meta doesn't grow.
    func testRefusesToGrowMetaOverItemData() throws {
        var model = try model(HEIFFixtures.heic(width: 320, height: 240))
        model.items.append(HEIFModel.Item(id: model.maxID + 1, type: "zzzz", flags: 1, data: [UInt8](repeating: 0, count: 8),
                                          absoluteOffset: model.ftyp.count + 12))
        XCTAssertEqual(refusal(model.bytes()), nil, "with an XMP item, meta doesn't grow")
        model.removeXMP()
        XCTAssertEqual(refusal(model.bytes()), .itemDataInsideMeta)
    }

    func testRefusesSeveralXMPItemsOrOneThatDescribesNothing() throws {
        var model = try model(HEIFFixtures.heic(width: 320, height: 240))
        model.addXMP(HEIFFixtures.otherAppXMP)
        XCTAssertEqual(refusal(model.bytes()), .ambiguousXMP, "two XMP items for the primary image")

        model.removeXMP()
        model.addXMP(HEIFFixtures.otherAppXMP, describing: [])
        model.references.removeAll { $0.to.isEmpty }
        XCTAssertEqual(refusal(model.bytes()), .ambiguousXMP, "an XMP item that describes nothing")
    }

    func testRefusesAnEncodedXMPItem() throws {
        var model = try model(HEIFFixtures.heic(width: 320, height: 240))
        let xmp = try XCTUnwrap(model.items.firstIndex { $0.contentType == "application/rdf+xml" })
        model.items[xmp].contentEncoding = "deflate"
        XCTAssertEqual(refusal(model.bytes()), .encodedXMP)
    }

    func testRefusesAnXMPItemInSeveralExtents() throws {
        var model = try model(HEIFFixtures.heic(width: 320, height: 240))
        let xmp = try XCTUnwrap(model.items.firstIndex { $0.contentType == "application/rdf+xml" })
        model.items[xmp].extents = 2
        XCTAssertEqual(refusal(model.bytes()), .xmpInSeveralExtents)
    }

    /// A new item needs a free ID: past 65,535 it doesn't fit a version-0 or -1 `iloc`.
    func testRefusesAnItemIDThatDoesNotFit() throws {
        var model = try model(HEIFFixtures.heic(width: 320, height: 240))
        model.removeXMP()
        let exif = try XCTUnwrap(model.items.firstIndex { $0.type == "Exif" })
        let old = model.items[exif].id
        model.items[exif].id = 0xFFFF
        for i in model.references.indices where model.references[i].from == old { model.references[i].from = 0xFFFF }
        XCTAssertEqual(refusal(model.bytes()), .fieldTooSmall)
    }

    func testPassesTheOldPacketToUpdateAndRefusesWhatItRefuses() throws {
        let original = HEIFFixtures.heic(width: 320, height: 240)
        let heif = try XCTUnwrap(TestHEIF(original))
        var seen: [Data?] = []
        let result = HEIFMetadata.writingXMP(in: original) { seen.append($0); return nil }
        XCTAssertEqual(result.map(\.change), .failure(.updateRefused))
        XCTAssertEqual(seen, [Data(try XCTUnwrap(heif.data(of: heif.primaryXMP[0].id)))], "the old packet")
        let noXMP = HEIFFixtures.heic(width: 320, height: 240, xmp: nil)
        seen = []
        _ = HEIFMetadata.writingXMP(in: noXMP) { seen.append($0); return nil }
        XCTAssertEqual(seen, [nil], "no old packet")
    }
}
