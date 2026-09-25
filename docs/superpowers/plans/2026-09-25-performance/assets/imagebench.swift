// imagebench.swift — standalone benchmark of Phocasa's image-loading and editing paths.
// Mirrors Services/ImageLoader.swift and Services/ImageEditingService.swift. Measures only.
//
// Build:  swiftc -O -swift-version 5 imagebench.swift -o imagebench
// Run:    ./imagebench gen [noiseAmp] [quality] | copies | orient | thumb | detail | conc | ci | raw | clean

import Foundation
import ImageIO
import CoreImage
import CoreGraphics
import Metal
import UniformTypeIdentifiers

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Paths & utilities

let root = ProcessInfo.processInfo.environment["IMAGEBENCH_DIR"] ?? (NSTemporaryDirectory() + "phocasa-imagebench")
let dataDir = root + "/data"
try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
let masterPath = dataDir + "/master.jpg"
let nCopies = 200
func copyPath(_ i: Int) -> String { dataDir + "/copy_" + String(format: "%03d", i) + ".jpg" }

@inline(__always) func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
func timeMs<T>(_ body: () -> T) -> (T, Double) {
    let t = nowNs(); let r = body(); return (r, Double(nowNs() - t) / 1e6)
}
func cpuMs() -> Double {
    var u = rusage(); getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) * 1000 + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1000
}
/// Orientation 6 fix-up done on the CPU after a full-res decode (what the app would need if it keeps CreateImageAtIndex).
func rotateForOrientation6(_ img: CGImage) -> CGImage? {
    let w = img.height, h = img.width
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.translateBy(x: 0, y: CGFloat(h)); ctx.rotate(by: -.pi / 2)
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return ctx.makeImage()
}
func median(_ a: [Double]) -> Double {
    let s = a.sorted(); let n = s.count
    return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
}
func pct(_ a: [Double], _ p: Double) -> Double {
    let s = a.sorted(); return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
}
func f(_ x: Double, _ d: Int = 1) -> String { String(format: "%.\(d)f", x) }
func dims(_ cg: CGImage?) -> String { cg.map { "\($0.width)x\($0.height)" } ?? "nil" }
func mb(_ bytes: Int) -> String { f(Double(bytes) / 1_048_576, 1) + " MB" }
func fileSize(_ p: String) -> Int { (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? Int) ?? 0 }

let kAlways = kCGImageSourceCreateThumbnailFromImageAlways
let kIfAbsent = kCGImageSourceCreateThumbnailFromImageIfAbsent
let kMax = kCGImageSourceThumbnailMaxPixelSize
let kXform = kCGImageSourceCreateThumbnailWithTransform
let kCacheNow = kCGImageSourceShouldCacheImmediately

func source(_ path: String, noCache: Bool = false) -> CGImageSource? {
    let opts: CFDictionary? = noCache ? ([kCGImageSourceShouldCache: false] as CFDictionary) : nil
    return CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, opts)
}

/// Exactly ImageLoader.loadThumbnail's decode (minus NSImage/NSCache wrapping).
func appThumbnail(_ path: String, _ maxSize: CGFloat) -> CGImage? {
    autoreleasepool {
        guard let src = source(path) else { return nil }
        let opts: [CFString: Any] = [kAlways: true, kMax: maxSize, kXform: true, kCacheNow: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

// Page-cache control without root: msync(MS_INVALIDATE) evicts a file's pages (same trick as vmtouch -e on macOS);
// mincore() verifies residency.
func evict(_ path: String) {
    let fd = open(path, O_RDONLY); guard fd >= 0 else { return }
    defer { close(fd) }
    var st = stat(); fstat(fd, &st); let len = Int(st.st_size)
    guard let p = mmap(nil, len, PROT_READ, MAP_SHARED, fd, 0), p != MAP_FAILED else { return }
    msync(p, len, MS_INVALIDATE); munmap(p, len)
}
func residentFraction(_ path: String) -> Double {
    let fd = open(path, O_RDONLY); guard fd >= 0 else { return -1 }
    defer { close(fd) }
    var st = stat(); fstat(fd, &st); let len = Int(st.st_size)
    guard let p = mmap(nil, len, PROT_READ, MAP_SHARED, fd, 0), p != MAP_FAILED else { return -1 }
    defer { munmap(p, len) }
    let pages = (len + Int(vm_page_size) - 1) / Int(vm_page_size)
    var vec = [CChar](repeating: 0, count: pages)
    guard mincore(p, len, &vec) == 0 else { return -1 }
    return Double(vec.filter { $0 & 1 != 0 }.count) / Double(pages)
}
func warmRead(_ path: String) { _ = try? Data(contentsOf: URL(fileURLWithPath: path)) }

// MARK: - 1. Generate synthetic JPEG

struct RNG {
    var s: UInt64
    mutating func next() -> UInt64 { s ^= s >> 12; s ^= s << 25; s ^= s >> 27; return s &* 2685821657736338717 }
    mutating func u() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
}

func generate(noiseAmp: Double, quality: Double) {
    let W = 6000, H = 4000
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    var rng = RNG(s: 0x1234_5678_9ABC_DEF1)
    func c(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    let horizon = Double(H) * 0.45
    // Sky
    let sky = CGGradient(colorsSpace: cs, colors: [c(0.18, 0.36, 0.72), c(0.62, 0.74, 0.88), c(0.95, 0.85, 0.70)] as CFArray,
                         locations: [0, 0.6, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: Double(H)), end: CGPoint(x: 0, y: horizon),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // Ground
    ctx.saveGState(); ctx.clip(to: CGRect(x: 0, y: 0, width: Double(W), height: horizon))
    let ground = CGGradient(colorsSpace: cs, colors: [c(0.30, 0.42, 0.18), c(0.45, 0.35, 0.20), c(0.15, 0.22, 0.10)] as CFArray,
                            locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(ground, start: CGPoint(x: 0, y: horizon), end: CGPoint(x: Double(W), y: 0), options: [])
    ctx.restoreGState()
    // Soft radial blobs (clouds / bokeh)
    for _ in 0..<80 {
        let ctr = CGPoint(x: rng.u() * Double(W), y: rng.u() * Double(H)); let r = 100 + rng.u() * 900
        let g = CGGradient(colorsSpace: cs, colors: [c(rng.u(), rng.u(), rng.u(), 0.5 * rng.u()), c(0, 0, 0, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(g, startCenter: ctr, startRadius: 0, endCenter: ctr, endRadius: r, options: [])
    }
    // Hard-edged shapes (objects / buildings)
    for _ in 0..<500 {
        ctx.setFillColor(c(rng.u(), rng.u(), rng.u(), 0.4 + 0.6 * rng.u()))
        let rect = CGRect(x: rng.u() * Double(W), y: rng.u() * Double(H), width: 20 + rng.u() * 600, height: 20 + rng.u() * 600)
        if rng.u() < 0.5 { ctx.fill(rect) } else { ctx.fillEllipse(in: rect) }
    }
    // Fine texture (foliage / fabric)
    for _ in 0..<60_000 {
        ctx.setStrokeColor(c(rng.u(), rng.u(), rng.u(), 0.3 + 0.7 * rng.u()))
        ctx.setLineWidth(0.7 + rng.u() * 3)
        let x = rng.u() * Double(W), y = rng.u() * Double(H), a = rng.u() * 2 * .pi, l = 5 + rng.u() * 80
        ctx.move(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x + cos(a) * l, y: y + sin(a) * l)); ctx.strokePath()
    }
    // Sensor-like noise: luma (triangular) + weaker chroma
    let p = ctx.data!.bindMemory(to: UInt8.self, capacity: W * H * 4)
    @inline(__always) func cl(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
    for i in 0..<(W * H) {
        let v = rng.next()
        let l = (Double(v & 0xFF) + Double((v >> 8) & 0xFF) - 255) / 255 * noiseAmp
        let cr = (Double((v >> 16) & 0xFF) - 127.5) / 127.5 * noiseAmp * 0.3
        let cb = (Double((v >> 24) & 0xFF) - 127.5) / 127.5 * noiseAmp * 0.3
        let o = i * 4
        p[o] = cl(Double(p[o]) + l + cr); p[o + 1] = cl(Double(p[o + 1]) + l); p[o + 2] = cl(Double(p[o + 2]) + l + cb)
    }
    let img = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: masterPath) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    let props: [CFString: Any] = [
        kCGImagePropertyOrientation: 6,
        kCGImageDestinationLossyCompressionQuality: quality,
        kCGImageDestinationEmbedThumbnail: true,
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFOrientation: 6, kCGImagePropertyTIFFMake: "Bench", kCGImagePropertyTIFFModel: "Synthetic"],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifPixelXDimension: W, kCGImagePropertyExifPixelYDimension: H],
    ]
    CGImageDestinationAddImage(dest, img, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fatalError("finalize failed") }

    // Verify
    let src = source(masterPath)!
    let pr = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [String: Any]
    let embedded = CGImageSourceCreateThumbnailAtIndex(src, 0, [kIfAbsent: true] as CFDictionary)
    print("master.jpg: \(mb(fileSize(masterPath))) (\(fileSize(masterPath)) B), stored \(pr[kCGImagePropertyPixelWidth as String]!)x\(pr[kCGImagePropertyPixelHeight as String]!), orientation=\(pr[kCGImagePropertyOrientation as String] ?? "nil"), q=\(quality), noiseAmp=\(noiseAmp)")
    print("embedded thumbnail (IfAbsent, no max, no transform): \(dims(embedded))")
}

func makeCopies() {
    let d = try! Data(contentsOf: URL(fileURLWithPath: masterPath))
    for i in 0..<nCopies { try! d.write(to: URL(fileURLWithPath: copyPath(i))) }  // real copies, not APFS clones
    print("wrote \(nCopies) copies of \(mb(d.count))")
}

// MARK: - 2. Orientation

func orientTest() {
    let path = copyPath(0)
    let src = source(path)!
    let full = CGImageSourceCreateImageAtIndex(src, 0, [kCacheNow: true, kXform: true] as CFDictionary)
    let thumbX = CGImageSourceCreateThumbnailAtIndex(source(path)!, 0, [kAlways: true, kMax: 6000, kXform: true, kCacheNow: true] as CFDictionary)
    let thumbNoX = CGImageSourceCreateThumbnailAtIndex(source(path)!, 0, [kAlways: true, kMax: 6000, kCacheNow: true] as CFDictionary)
    let ci = CIImage(contentsOf: URL(fileURLWithPath: path))!
    let o = ci.properties[kCGImagePropertyOrientation as String] as? UInt32 ?? 1
    let ciO = ci.oriented(CGImagePropertyOrientation(rawValue: o) ?? .up)
    print("| Path | Output px |")
    print("|---|---|")
    print("| EXIF orientation tag | \(o) (display should be portrait 4000x6000) |")
    print("| CreateImageAtIndex [CacheImmediately, WithTransform] (app detail view) | \(dims(full)) |")
    print("| CreateThumbnailAtIndex [Always, max 6000, WithTransform] | \(dims(thumbX)) |")
    print("| CreateThumbnailAtIndex [Always, max 6000] (no transform) | \(dims(thumbNoX)) |")
    print("| CIImage(contentsOf:).oriented(...) (app edit path) | \(Int(ciO.extent.width))x\(Int(ciO.extent.height)) |")
}

// MARK: - 3. Thumbnail cost

func thumbTest() {
    let runs = 20
    for i in 0..<runs { warmRead(copyPath(i)) }
    print("| maxPx | Mode | Source opts | median ms | p90 ms | output px |")
    print("|---|---|---|---|---|---|")
    for size in [400, 800, 1200] {
        for (modeName, modeKey) in [("FromImageAlways", kAlways), ("FromImageIfAbsent", kIfAbsent)] {
            for noCache in [false, true] {
                var times: [Double] = []; var out = ""
                let opts: [CFString: Any] = [modeKey: true, kMax: size, kXform: true, kCacheNow: true]
                for r in 0..<(runs + 3) {
                    let path = copyPath(r % runs)
                    let (cg, ms) = timeMs { autoreleasepool { () -> CGImage? in
                        let src = source(path, noCache: noCache)!
                        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
                    } }
                    if r >= 3 { times.append(ms) }
                    out = dims(cg)
                }
                print("| \(size) | \(modeName) | \(noCache ? "ShouldCache:false" : "nil (app)") | \(f(median(times))) | \(f(pct(times, 0.9))) | \(out) |")
            }
        }
    }
}

// MARK: - 4. Detail view

func detailTest() {
    let runs = 10
    for i in 0..<runs { warmRead(copyPath(i)) }
    struct Cfg { let name: String; let make: (CGImageSource) -> CGImage? }
    let cfgs: [Cfg] = [
        Cfg(name: "CreateImageAtIndex full-res [CacheImmediately, WithTransform] (app)") {
            CGImageSourceCreateImageAtIndex($0, 0, [kCacheNow: true, kXform: true] as CFDictionary) },
        Cfg(name: "CreateThumbnailAtIndex max 2560 [Always, WithTransform, CacheImmediately]") {
            CGImageSourceCreateThumbnailAtIndex($0, 0, [kAlways: true, kMax: 2560, kXform: true, kCacheNow: true] as CFDictionary) },
        Cfg(name: "CreateThumbnailAtIndex max 3840 [Always, WithTransform, CacheImmediately]") {
            CGImageSourceCreateThumbnailAtIndex($0, 0, [kAlways: true, kMax: 3840, kXform: true, kCacheNow: true] as CFDictionary) },
        Cfg(name: "(extra) CreateThumbnailAtIndex max 6000 = oriented full-res") {
            CGImageSourceCreateThumbnailAtIndex($0, 0, [kAlways: true, kMax: 6000, kXform: true, kCacheNow: true] as CFDictionary) },
        Cfg(name: "(extra) CreateImageAtIndex full-res + CGContext rotate (oriented)") {
            CGImageSourceCreateImageAtIndex($0, 0, [kCacheNow: true] as CFDictionary).flatMap(rotateForOrientation6) },
        Cfg(name: "(extra) CreateImageAtIndex [SubsampleFactor 2, CacheImmediately] (unoriented)") {
            CGImageSourceCreateImageAtIndex($0, 0, [kCacheNow: true, kCGImageSourceSubsampleFactor: 2] as CFDictionary) },
    ]
    print("| Path | median ms | p90 ms | CPU ms/decode | output px | decoded bytes |")
    print("|---|---|---|---|---|---|")
    for cfg in cfgs {
        var times: [Double] = []; var out = ""; var bytes = 0
        let cpu0 = cpuMs()
        for r in 0..<(runs + 2) {
            let path = copyPath(r % runs)
            let (res, ms) = timeMs { autoreleasepool { () -> (String, Int) in
                let cg = cfg.make(source(path)!)
                return (dims(cg), (cg?.bytesPerRow ?? 0) * (cg?.height ?? 0))
            } }
            if r >= 2 { times.append(ms) }
            out = res.0; bytes = res.1
        }
        let cpu = (cpuMs() - cpu0) / Double(runs + 2)
        print("| \(cfg.name) | \(f(median(times))) | \(f(pct(times, 0.9))) | \(f(cpu)) | \(out) | \(mb(bytes)) |")
    }
}

// MARK: - 5. Concurrency

final class Counter {
    let lock = NSLock(); var inflight = 0; var peak = 0
    func enter() { lock.lock(); inflight += 1; if inflight > peak { peak = inflight }; lock.unlock() }
    func exit() { lock.lock(); inflight -= 1; lock.unlock() }
}
struct ConcRun { var total: Double; var last20: Double; var afterStop: Double; var peak: Int }

func summarize(_ t0: UInt64, _ req: UnsafeMutablePointer<UInt64>, _ done: UnsafeMutablePointer<UInt64>, _ n: Int, _ peak: Int) -> ConcRun {
    var mx: UInt64 = 0, mx20: UInt64 = 0
    for i in 0..<n { mx = max(mx, done[i]); if i >= n - 20 { mx20 = max(mx20, done[i]) } }
    return ConcRun(total: Double(mx - t0) / 1e6, last20: Double(mx20 - t0) / 1e6, afterStop: Double(mx20 - req[n - 1]) / 1e6, peak: peak)
}
@inline(__always) func waitUntil(_ t: UInt64) { while nowNs() < t { usleep(100) } }

/// (a) Current app behaviour: one block per request on a concurrent queue, no cancellation, FIFO-ish.
func runGCD(_ paths: [String], spacingNs: UInt64) -> ConcRun {
    let n = paths.count
    let q = DispatchQueue(label: "com.phocasa.imageloader.bench", qos: .userInitiated, attributes: .concurrent)
    let req = UnsafeMutablePointer<UInt64>.allocate(capacity: n), done = UnsafeMutablePointer<UInt64>.allocate(capacity: n)
    defer { req.deallocate(); done.deallocate() }
    let c = Counter(), g = DispatchGroup()
    let t0 = nowNs()
    for i in 0..<n {
        if spacingNs > 0 { waitUntil(t0 + UInt64(i) * spacingNs) }
        req[i] = nowNs(); g.enter()
        q.async { c.enter(); _ = appThumbnail(paths[i], concSize); done[i] = nowNs(); c.exit(); g.leave() }
    }
    g.wait()
    return summarize(t0, req, done, n, c.peak)
}

/// (b) Bounded worker pool (activeProcessorCount threads), newest request served first.
func runLIFO(_ paths: [String], spacingNs: UInt64, workers: Int) -> ConcRun {
    final class State { var stack: [Int] = []; var finished = false }
    let n = paths.count
    let req = UnsafeMutablePointer<UInt64>.allocate(capacity: n), done = UnsafeMutablePointer<UInt64>.allocate(capacity: n)
    defer { req.deallocate(); done.deallocate() }
    let cond = NSCondition(), st = State(), c = Counter(), g = DispatchGroup()
    for _ in 0..<workers {
        g.enter()
        let t = Thread {
            while true {
                cond.lock()
                while st.stack.isEmpty && !st.finished { cond.wait() }
                if st.stack.isEmpty { cond.unlock(); break }
                let i = st.stack.removeLast()
                cond.unlock()
                c.enter(); _ = appThumbnail(paths[i], concSize); done[i] = nowNs(); c.exit()
            }
            g.leave()
        }
        t.qualityOfService = .userInitiated; t.start()
    }
    usleep(20_000)  // let workers park
    let t0 = nowNs()
    if spacingNs == 0 {
        cond.lock(); for i in 0..<n { req[i] = t0; st.stack.append(i) }; st.finished = true; cond.broadcast(); cond.unlock()
    } else {
        for i in 0..<n {
            waitUntil(t0 + UInt64(i) * spacingNs)
            cond.lock(); req[i] = nowNs(); st.stack.append(i); cond.signal(); cond.unlock()
        }
        cond.lock(); st.finished = true; cond.broadcast(); cond.unlock()
    }
    g.wait()
    return summarize(t0, req, done, n, c.peak)
}

var concSize: CGFloat = 600
func concTest() {
    print("thumbnail size = \(Int(concSize)) px")
    let paths = (0..<nCopies).map(copyPath)
    let workers = ProcessInfo.processInfo.activeProcessorCount
    let spacing: UInt64 = 2_500_000  // 200 requests over 0.5 s
    func evictAll() -> Double { paths.forEach(evict); return paths.prefix(20).map(residentFraction).reduce(0, +) / 20 }
    func row(_ label: String, _ runs: [ConcRun]) {
        print("| \(label) | \(f(median(runs.map(\.total)), 0)) | \(f(median(runs.map(\.last20)), 0)) | \(f(median(runs.map(\.afterStop)), 0)) | \(runs.map(\.peak).max()!) |")
    }
    print("workers for (b) = activeProcessorCount = \(workers); spread = 200 requests at 2.5 ms intervals (0.5 s scroll)")
    print("| Scenario | total ms | last-20-done ms (from t0) | last-20 after last request ms | peak in-flight |")
    print("|---|---|---|---|---|")
    // Cold (pages evicted before each run)
    var r = evictAll(); print("<!-- residency after evict: \(f(r * 100))% -->")
    let coldA = runGCD(paths, spacingNs: 0)
    r = evictAll(); let coldB = runLIFO(paths, spacingNs: 0, workers: workers)
    r = evictAll(); let coldAs = runGCD(paths, spacingNs: spacing)
    r = evictAll(); let coldBs = runLIFO(paths, spacingNs: spacing, workers: workers)
    print("<!-- residency after last evict: \(f(r * 100))% -->")
    row("COLD (a) current GCD, all at once", [coldA]); row("COLD (b) bounded LIFO, all at once", [coldB])
    row("COLD (a) current GCD, spread", [coldAs]); row("COLD (b) bounded LIFO, spread", [coldBs])
    // Warm
    paths.forEach(warmRead); _ = runGCD(paths, spacingNs: 0)  // throwaway
    var a: [ConcRun] = [], b: [ConcRun] = [], aS: [ConcRun] = [], bS: [ConcRun] = []
    for _ in 0..<5 { a.append(runGCD(paths, spacingNs: 0)); b.append(runLIFO(paths, spacingNs: 0, workers: workers)) }
    for _ in 0..<3 { aS.append(runGCD(paths, spacingNs: spacing)); bS.append(runLIFO(paths, spacingNs: spacing, workers: workers)) }
    row("WARM (a) current GCD, all at once (median of 5)", a); row("WARM (b) bounded LIFO, all at once (median of 5)", b)
    row("WARM (a) current GCD, spread (median of 3)", aS); row("WARM (b) bounded LIFO, spread (median of 3)", bS)
    // Single-request reference
    var single: [Double] = []
    for i in 0..<20 { single.append(timeMs { appThumbnail(copyPath(i), concSize) }.1) }
    print("single \(Int(concSize))px thumbnail, warm, uncontended: median \(f(median(single))) ms")
}

// MARK: - 6. CoreImage (mirrors ImageEditingService.applyStandardFilters / applyPostRAWFilters)

struct Params {
    var exposure = 0.3, highlights = 30.0, shadows = 20.0, brightness = 10.0, contrast = 15.0, saturation = 10.0
    var vibrance = 20.0, sharpness = 40.0, clarity = 30.0, vignette = 25.0
}
func applyFilter(_ name: String, _ image: CIImage, _ params: [String: Any]) -> CIImage {
    guard let filter = CIFilter(name: name) else { return image }
    filter.setValue(image, forKey: kCIInputImageKey)
    for (k, v) in params { filter.setValue(v, forKey: k) }
    return filter.outputImage ?? image
}
func toneCurve(_ image: CIImage, _ h: Double, _ s: Double) -> CIImage {
    let hN = h / 100, sN = s / 100
    let p0y = max(0, sN * 0.08), p1y = min(1, max(0, 0.25 + sN * 0.20))
    let p3y = min(1, max(0, 0.75 - hN * 0.20)), p4y = min(1, max(0.3, 1 - hN * 0.30))
    return applyFilter("CIToneCurve", image, [
        "inputPoint0": CIVector(x: 0, y: p0y), "inputPoint1": CIVector(x: 0.25, y: p1y), "inputPoint2": CIVector(x: 0.5, y: 0.5),
        "inputPoint3": CIVector(x: 0.75, y: p3y), "inputPoint4": CIVector(x: 1, y: p4y)])
}
func standardChain(_ img: CIImage, _ p: Params) -> CIImage {
    var r = img
    r = applyFilter("CIExposureAdjust", r, ["inputEV": p.exposure])
    r = toneCurve(r, p.highlights, p.shadows)
    r = applyFilter("CIColorControls", r, ["inputBrightness": p.brightness / 100 * 0.3, "inputContrast": 1 + p.contrast / 100 * 0.5,
                                          "inputSaturation": 1 + p.saturation / 100 * 0.5])
    r = applyFilter("CIVibrance", r, ["inputAmount": p.vibrance / 100])
    r = applyFilter("CIUnsharpMask", r, ["inputRadius": 1.5, "inputIntensity": p.sharpness / 100 * 2])
    r = applyFilter("CIUnsharpMask", r, ["inputRadius": 20.0, "inputIntensity": p.clarity / 100])
    r = applyFilter("CIVignette", r, ["inputIntensity": p.vignette / 100 * 2, "inputRadius": 1.0])
    return r
}
func postRAWChain(_ img: CIImage, _ p: Params) -> CIImage {
    var r = img
    r = applyFilter("CIVibrance", r, ["inputAmount": p.vibrance / 100])
    r = applyFilter("CIColorControls", r, ["inputBrightness": 0.0, "inputContrast": 1.0, "inputSaturation": 1 + p.saturation / 100 * 0.5])
    r = toneCurve(r, p.highlights, p.shadows)
    r = applyFilter("CIUnsharpMask", r, ["inputRadius": 1.5, "inputIntensity": p.sharpness / 100 * 2])
    r = applyFilter("CIUnsharpMask", r, ["inputRadius": 20.0, "inputIntensity": p.clarity / 100])
    r = applyFilter("CIVignette", r, ["inputIntensity": p.vignette / 100 * 2, "inputRadius": 1.0])
    return r
}
func scaleToFit(_ image: CIImage, _ maxSize: CGSize) -> CIImage {
    let s = min(maxSize.width / image.extent.width, maxSize.height / image.extent.height)
    guard s < 1 else { return image }
    return image.transformed(by: CGAffineTransform(scaleX: s, y: s))
}
func orientedImage(_ image: CIImage) -> CIImage {
    let o = image.properties[kCGImagePropertyOrientation as String] as? UInt32 ?? 1
    return image.oriented(CGImagePropertyOrientation(rawValue: o) ?? .up)
}
let mtl = MTLCreateSystemDefaultDevice()!
func appContext(cacheIntermediates: Bool = false) -> CIContext {
    CIContext(mtlDevice: mtl, options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB(), .highQualityDownsample: true,
                                        .cacheIntermediates: cacheIntermediates])
}
var tick = 0
/// One "slider tick": new exposure value so nothing downstream can be reused.
func renderTick(_ ctx: CIContext, _ src: CIImage, box: CGSize?) -> CGImage? {
    autoreleasepool {
        tick += 1
        var p = Params(); p.exposure = 0.3 + Double(tick % 100) * 0.003
        var img = src
        if let box { img = scaleToFit(img, box) }
        img = standardChain(img, p)
        let cg = ctx.createCGImage(img, from: img.extent)
        _ = touchPixels(cg)  // large outputs are rendered lazily; force real pixels so timings are honest
        return cg
    }
}
struct Lat { var first: Double; var med: Double; var p90: Double; var out: String }
func measure(_ ctx: CIContext, _ src: CIImage, box: CGSize?, n: Int, warm: Int = 3) -> Lat {
    let (cg0, first) = timeMs { renderTick(ctx, src, box: box) }
    for _ in 0..<warm { _ = renderTick(ctx, src, box: box) }
    var t: [Double] = []
    for _ in 0..<n { t.append(timeMs { renderTick(ctx, src, box: box) }.1) }
    return Lat(first: first, med: median(t), p90: pct(t, 0.9), out: dims(cg0))
}

func ciTest() {
    let box = CGSize(width: 1600, height: 1100)
    for i in 0..<6 { warmRead(copyPath(i)) }
    // Sanity: is createCGImage synchronous (non-deferred)?
    do {
        let ctx = appContext(); let src = orientedImage(CIImage(contentsOf: URL(fileURLWithPath: copyPath(5)))!)
        _ = renderTick(ctx, src, box: box)
        let (cg, tCreate) = timeMs { renderTick(ctx, src, box: box) }
        let (_, tTouch) = timeMs { CFDataGetLength(cg!.dataProvider!.data) }
        print("<!-- sanity: createCGImage \(f(tCreate)) ms, then touching pixel data \(f(tTouch)) ms (small => render is not deferred) -->")
    }
    print("| Variant (preview to fit 1600x1100, 7-filter chain) | first render ms | median ms (n=30) | p90 ms | output px |")
    print("|---|---|---|---|---|")
    func row(_ l: String, _ r: Lat) { print("| \(l) | \(f(r.first)) | \(f(r.med)) | \(f(r.p90)) | \(r.out) |") }

    // (a) current
    let ctxA = appContext()
    let (ciA, initA) = timeMs { CIImage(contentsOf: URL(fileURLWithPath: copyPath(1)))! }
    let srcA = orientedImage(ciA)
    print("|   one-off CIImage(contentsOf:) init for (a) (decodes eagerly; paid in prepareStandard) | \(f(initA)) ms | | | |")
    let a = measure(ctxA, srcA, box: box, n: 30)
    row("(a) app: cached CIImage(contentsOf:) full-res, scaled per render", a)

    // (b) pre-downsampled once to 3200 via ImageIO
    var prep: [Double] = []
    var cgB: CGImage!
    for i in 0..<5 {
        let (cg, ms) = timeMs { CGImageSourceCreateThumbnailAtIndex(source(copyPath(2 + (i % 2)))!, 0,
            [kAlways: true, kMax: 3200, kXform: true, kCacheNow: true] as CFDictionary) }
        prep.append(ms); cgB = cg
    }
    let ctxB = appContext()
    let srcB = CIImage(cgImage: cgB)
    let b = measure(ctxB, srcB, box: box, n: 30)
    row("(b) ImageIO thumbnail 3200px once -> CIImage(cgImage:), reused", b)
    print("|   one-off prep for (b): ImageIO 3200px oriented decode | median \(f(median(prep))) ms | | | \(dims(cgB)) |")

    // (c) = (a) + cacheIntermediates
    let ctxC = appContext(cacheIntermediates: true)
    let srcC = orientedImage(CIImage(contentsOf: URL(fileURLWithPath: copyPath(3)))!)
    let c = measure(ctxC, srcC, box: box, n: 30)
    row("(c) = (a) with .cacheIntermediates: true", c)

    // (d) diagnostic: full-res decoded once to CGImage, scaled per render (separates JPEG re-decode from 24MP GPU downscale)
    let cgD = CGImageSourceCreateThumbnailAtIndex(source(copyPath(4))!, 0, [kAlways: true, kMax: 6000, kXform: true, kCacheNow: true] as CFDictionary)!
    let ctxD = appContext()
    let d = measure(ctxD, CIImage(cgImage: cgD), box: box, n: 30)
    row("(d) diag: full-res decoded ONCE to CGImage -> CIImage(cgImage:), scaled per render", d)

    print("")
    print("| Delayed 'full-res' pass | first ms | median ms | p90 ms | output px |")
    print("|---|---|---|---|---|")
    let full = measure(ctxA, srcA, box: nil, n: 8, warm: 1)
    row("app: native res from (a) source, no scale", full)
    let r3a = measure(ctxA, srcA, box: CGSize(width: 3000, height: 3000), n: 15, warm: 2)
    row("~3000px long edge from (a) full-res source", r3a)
    let r3b = measure(ctxB, srcB, box: CGSize(width: 3000, height: 3000), n: 15, warm: 2)
    row("~3000px long edge from (b) 3200px source", r3b)
}

/// Force pixels to exist: sum every 64th byte of the CGImage's backing data.
func touchPixels(_ cg: CGImage?) -> Int {
    guard let cg, let d = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(d) else { return -1 }
    var sum = 0; let n = CFDataGetLength(d); var i = 0
    while i < n { sum &+= Int(ptr[i]); i += 64 }
    return sum
}
func ciDiag() {
    for i in 6..<9 { warmRead(copyPath(i)) }
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    for (label, box) in [("preview 1600x1100", Optional(CGSize(width: 1600, height: 1100))), ("full native", nil)] {
        for mode in ["createCGImage (app)", "createCGImage + touch pixels", "createCGImage deferred:false", "render(toBitmap:)"] {
            let ctx = appContext()
            let (ci0, tInit) = timeMs { CIImage(contentsOf: URL(fileURLWithPath: copyPath(6)))! }
            let src = orientedImage(ci0)
            var times: [Double] = []; var first = 0.0; var chk = 0
            for r in 0..<9 {
                let t = timeMs { () -> Int in autoreleasepool {
                    tick += 1
                    var p = Params(); p.exposure = 0.3 + Double(tick % 100) * 0.003
                    var img = src
                    if let box { img = scaleToFit(img, box) }
                    img = standardChain(img, p)
                    let ext = img.extent
                    switch mode {
                    case "createCGImage (app)": return ctx.createCGImage(img, from: ext) == nil ? 0 : 1
                    case "createCGImage + touch pixels": return touchPixels(ctx.createCGImage(img, from: ext))
                    case "createCGImage deferred:false":
                        return touchPixels(ctx.createCGImage(img, from: ext, format: .RGBA8, colorSpace: sRGB, deferred: false))
                    default:
                        let w = Int(ext.width), h = Int(ext.height)
                        let buf = UnsafeMutableRawPointer.allocate(byteCount: w * h * 4, alignment: 64)
                        defer { buf.deallocate() }
                        ctx.render(img, toBitmap: buf, rowBytes: w * 4, bounds: ext, format: .RGBA8, colorSpace: sRGB)
                        return Int(buf.load(fromByteOffset: (h / 2) * w * 4 + (w / 2) * 4, as: UInt32.self))
                    }
                } }
                if r == 0 { first = t.1 } else { times.append(t.1) }
                chk = t.0
            }
            print("| \(label) | \(mode) | CIImage init \(f(tInit)) | first \(f(first)) | median \(f(median(times))) | chk \(chk) |")
        }
    }
}

// MARK: - 7. RAW (read-only)

func findRAW() -> String? {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
    p.arguments = ["kMDItemContentTypeTree == 'public.camera-raw-image'"]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    try? p.run()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    for line in out.split(separator: "\n").prefix(5) {
        let path = String(line)
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_flags & 0x4000_0000 == 0 /* SF_DATALESS */,
              st.st_size > 1_000_000, access(path, R_OK) == 0 else { continue }
        return path
    }
    return nil
}
func applyRAWParams(_ f: CIRAWFilter, _ p: Params) {
    // Same mapping as ImageEditingService.applyRAWParameters (temperature/tint/NR/etc. at their 0 defaults).
    f.exposure = Float(p.exposure); f.shadowBias = Float(p.shadows / 100); f.boostAmount = Float(max(0, p.brightness / 100))
    f.boostShadowAmount = Float(max(0, p.shadows / 100)); f.contrastAmount = Float(1 + p.contrast / 200)
    f.sharpnessAmount = Float(p.sharpness / 100); f.luminanceNoiseReductionAmount = 0; f.colorNoiseReductionAmount = 0
    f.localToneMapAmount = 0; f.moireReductionAmount = 0; f.isGamutMappingEnabled = true
    f.neutralTemperature = 6500; f.neutralTint = 0
}
func rawRender(_ ctx: CIContext, _ f: CIRAWFilter, draft: Bool, scaleFactor: Float, box: CGSize?) -> CGImage? {
    autoreleasepool {
        tick += 1
        var p = Params(); p.exposure = 0.3 + Double(tick % 100) * 0.003
        f.isDraftModeEnabled = draft; f.scaleFactor = scaleFactor
        applyRAWParams(f, p)
        guard var out = f.outputImage else { return nil }
        if let box { out = scaleToFit(out, box) }
        out = postRAWChain(out, p)
        let cg = ctx.createCGImage(out, from: out.extent)
        _ = touchPixels(cg)
        return cg
    }
}

func rawTest() {
    guard let path = findRAW() else { print("No local (non-dataless) camera RAW found — skipped."); return }
    let url = URL(fileURLWithPath: path)
    let src0 = source(path)!
    let pr = CGImageSourceCopyPropertiesAtIndex(src0, 0, nil) as? [String: Any] ?? [:]
    let w = pr[kCGImagePropertyPixelWidth as String] as? Int ?? 0, h = pr[kCGImagePropertyPixelHeight as String] as? Int ?? 0
    print("RAW: .\(url.pathExtension), \(mb(fileSize(path))), \(w)x\(h) (\(f(Double(w * h) / 1e6)) MP), opened read-only")

    print("| RAW thumbnail @600 [WithTransform, CacheImmediately] | first (cold-ish) ms | median ms (n=10) | output px |")
    print("|---|---|---|---|")
    for (name, key) in [("FromImageAlways", kAlways), ("FromImageIfAbsent", kIfAbsent)] {
        let opts = [key: true, kMax: 600, kXform: true, kCacheNow: true] as [CFString: Any]
        let (cg, first) = timeMs { autoreleasepool { CGImageSourceCreateThumbnailAtIndex(source(path)!, 0, opts as CFDictionary) } }
        var t: [Double] = []
        for _ in 0..<10 { t.append(timeMs { autoreleasepool { CGImageSourceCreateThumbnailAtIndex(source(path)!, 0, opts as CFDictionary) } }.1) }
        print("| \(name) | \(f(first)) | \(f(median(t))) | \(dims(cg)) |")
    }

    let ctx = appContext()
    let box = CGSize(width: 1600, height: 1100)
    let native = CIRAWFilter(imageURL: url)!.nativeSize
    let sf = Float(1600 / max(native.width, native.height))
    print("")
    print("CIRAWFilter nativeSize \(Int(native.width))x\(Int(native.height)); scaleFactor for ~1600px = \(f(Double(sf), 3))")
    print("| CIRAWFilter preview (+ post-RAW chain) | first render ms (new filter) | median ms (n=10, cached filter, exposure changes) | p90 ms | output px |")
    print("|---|---|---|---|---|")
    let variants: [(String, Bool, Float, CGSize?)] = [
        ("(i) full decode (draft off), scaleToFit 1600x1100", false, 1, box),
        ("(ii) isDraftModeEnabled = true, scaleToFit (app preview)", true, 1, box),
        ("(iii) scaleFactor ~1600px (draft off)", false, sf, box),
        ("(iv) draft + scaleFactor", true, sf, box),
    ]
    for (name, draft, s, b) in variants {
        let filt = CIRAWFilter(imageURL: url)!
        let (cg, first) = timeMs { rawRender(ctx, filt, draft: draft, scaleFactor: s, box: b) }
        for _ in 0..<2 { _ = rawRender(ctx, filt, draft: draft, scaleFactor: s, box: b) }
        var t: [Double] = []
        for _ in 0..<10 { t.append(timeMs { rawRender(ctx, filt, draft: draft, scaleFactor: s, box: b) }.1) }
        print("| \(name) | \(f(first)) | \(f(median(t))) | \(f(pct(t, 0.9))) | \(dims(cg)) |")
    }
    // App pattern: preview (draft on) -> 300 ms later full-res (draft off, no scale) on the same cached filter -> next preview
    let filt = CIRAWFilter(imageURL: url)!
    _ = rawRender(ctx, filt, draft: true, scaleFactor: 1, box: box)
    var fullT: [Double] = [], prevAfterFull: [Double] = []; var fullOut = ""
    for _ in 0..<3 {
        let (cg, tf) = timeMs { rawRender(ctx, filt, draft: false, scaleFactor: 1, box: nil) }
        fullT.append(tf); fullOut = dims(cg)
        prevAfterFull.append(timeMs { rawRender(ctx, filt, draft: true, scaleFactor: 1, box: box) }.1)
    }
    print("| app delayed full-res pass (draft off, native, same filter) | | \(f(median(fullT))) (n=3) | \(f(fullT.max()!)) | \(fullOut) |")
    print("| app preview immediately after a full-res pass (draft toggled back on) | | \(f(median(prevAfterFull))) (n=3) | \(f(prevAfterFull.max()!)) | |")
}

// MARK: - main

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "gen": generate(noiseAmp: args.count > 2 ? Double(args[2])! : 14, quality: args.count > 3 ? Double(args[3])! : 0.9)
case "copies": makeCopies()
case "orient": orientTest()
case "thumb": thumbTest()
case "thumbsizes":  // cross-check: app thumbnail options at sizes given in argument order
    for i in 0..<20 { warmRead(copyPath(i)) }
    for s in args.dropFirst(2).compactMap({ Double($0) }) {
        for r in 0..<3 { _ = appThumbnail(copyPath(r), s) }
        let t = (0..<20).map { r in timeMs { appThumbnail(copyPath(r), s) }.1 }
        print("maxPx \(Int(s)): median \(f(median(t))) ms, out \(dims(appThumbnail(copyPath(0), s)))")
    }
case "detail": detailTest()
case "conc": if args.count > 2 { concSize = CGFloat(Double(args[2])!) }; concTest()
case "ci": ciTest()
case "cidiag": ciDiag()
case "raw": rawTest()
case "clean": try? FileManager.default.removeItem(atPath: dataDir); print("removed data dir")
default: print("usage: imagebench gen [noise] [q] | copies | orient | thumb | detail | conc | ci | raw | clean")
}
