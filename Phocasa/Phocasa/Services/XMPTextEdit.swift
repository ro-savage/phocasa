import Foundation

/// XMP namespaces the text edit and the scan need.
enum XMPNamespace {
    static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    static let xmp = "http://ns.adobe.com/xap/1.0/"
    static let dc = "http://purl.org/dc/elements/1.1/"
    static let meta = "adobe:ns:meta/"
    static let xml = "http://www.w3.org/XML/1998/namespace"
}

// MARK: - An independent reading of the XML

/// An XMP packet read as XML with Foundation's `XMLParser` (namespace-aware; a DTD or an external entity is refused),
/// independently of ImageIO: Phocasa's two properties wherever they are, and every other property name and leaf value.
///
/// It checks a rewrite against the packet itself rather than against ImageIO's model of it, which drops what it
/// doesn't model without saying so: empty values, `rdf:nodeID` and `parseType="Literal"` properties, `rdf:datatype`,
/// qualifiers on a rewrite, and it renames aliases (`exif:DateTimeOriginal` becomes `photoshop:DateCreated`). Its
/// lenient parser also reads XML that isn't well-formed and skips what follows the error; this one refuses it.
struct XMPPacketScan {
    /// Every `xmp:Rating`: an attribute's value or an element's text, in document order.
    fileprivate(set) var ratings: [String] = []
    /// Every `dc:subject`: its array items' text.
    fileprivate(set) var subjects: [[String]] = []
    /// `{namespace}name` of every other property, qualifier and RDF term that carries data. The structure isn't here:
    /// `x:xmpmeta`, `rdf:RDF`, `rdf:Description`, the arrays and their items, `rdf:about`, `rdf:parseType`, `x:xmptk`.
    fileprivate(set) var names: Set<String> = []
    /// Every other non-empty leaf value (attribute values, `rdf:about`, the text of elements without children), with
    /// how many times it occurs.
    fileprivate(set) var leaves: [String: Int] = [:]

    /// Nil when `packet` isn't well-formed XML, or has a DOCTYPE.
    init?(_ packet: Data) {
        guard packet.range(of: Data("<!DOCTYPE".utf8)) == nil else { return nil }
        let delegate = ScanDelegate()
        let parser = XMLParser(data: packet)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.refused, delegate.stack.isEmpty else { return nil }
        self = delegate.scan
    }

    /// Whether `other` holds every name and leaf value of this packet (Phocasa's two properties apart).
    func isKept(in other: XMPPacketScan) -> Bool {
        names.isSubset(of: other.names) && leaves.allSatisfy { other.leaves[$0.key, default: 0] >= $0.value }
    }
}

private final class ScanDelegate: NSObject, XMLParserDelegate {
    var scan = XMPPacketScan(empty: ())
    var refused = false

    struct Frame {
        let namespace: String
        let name: String
        /// Inside `xmp:Rating` or `dc:subject`.
        let phocasas: Bool
        let isRating: Bool
        /// This element is a `dc:subject`, an array directly in one, or an item of such an array: the subject's index.
        let subject: Int?
        let subjectArray: Int?
        let subjectItem: Int?
        var children = 0
        var text = ""
    }
    var stack: [Frame] = []
    private var prefixes: [String: [String]] = [:]

    private static let structuralElements: Set<String> = [
        "{\(XMPNamespace.meta)}xmpmeta", "{\(XMPNamespace.meta)}xapmeta", "{\(XMPNamespace.rdf)}RDF",
        "{\(XMPNamespace.rdf)}Description", "{\(XMPNamespace.rdf)}Bag", "{\(XMPNamespace.rdf)}Seq",
        "{\(XMPNamespace.rdf)}Alt", "{\(XMPNamespace.rdf)}li",
    ]
    private static let structuralAttributes: Set<String> = [
        "{\(XMPNamespace.rdf)}about", "{\(XMPNamespace.rdf)}parseType", "{\(XMPNamespace.meta)}xmptk",
        "{\(XMPNamespace.meta)}xaptk",
    ]
    private static let arrays: Set<String> = ["Bag", "Seq", "Alt"]

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        prefixes[prefix, default: []].append(namespaceURI)
    }

    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
        prefixes[prefix]?.removeLast()
    }

    private func namespace(ofAttribute qName: String) -> (String, String)? {
        guard let colon = qName.firstIndex(of: ":") else { return ("", qName) }
        let prefix = String(qName[..<colon]), name = String(qName[qName.index(after: colon)...])
        if prefix == "xml" { return (XMPNamespace.xml, name) }
        guard let uri = prefixes[prefix]?.last else { return nil }
        return (uri, name)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let ns = namespaceURI ?? ""
        let parent = stack.last
        if !stack.isEmpty { stack[stack.count - 1].children += 1 }
        let isRating = ns == XMPNamespace.xmp && elementName == "Rating"
        let isSubject = ns == XMPNamespace.dc && elementName == "subject"
        let phocasas = (parent?.phocasas ?? false) || isRating || isSubject
        var subject: Int?
        if isSubject {
            scan.subjects.append([])
            subject = scan.subjects.count - 1
        }
        let isRDF = ns == XMPNamespace.rdf
        let subjectArray = isRDF && Self.arrays.contains(elementName) ? parent?.subject : nil
        let subjectItem = isRDF && elementName == "li" ? parent?.subjectArray : nil
        let key = "{\(ns)}\(elementName)"
        if !phocasas && !Self.structuralElements.contains(key) { scan.names.insert(key) }

        for (attribute, value) in attributes {
            guard let (attributeNS, name) = namespace(ofAttribute: attribute) else { refused = true; continue }
            if attributeNS == XMPNamespace.xmp && name == "Rating" { scan.ratings.append(value); continue }
            if attributeNS == XMPNamespace.dc && name == "subject" { scan.subjects.append([value]); continue }
            guard !phocasas else { continue }
            let attributeKey = "{\(attributeNS)}\(name)"
            if Self.structuralAttributes.contains(attributeKey) {
                if name == "about", !value.isEmpty { scan.leaves[value, default: 0] += 1 }
                continue
            }
            scan.names.insert(attributeKey)
            if !value.isEmpty { scan.leaves[value, default: 0] += 1 }
        }
        stack.append(Frame(namespace: ns, name: elementName, phocasas: phocasas, isRating: isRating, subject: subject,
                           subjectArray: subjectArray, subjectItem: subjectItem))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !stack.isEmpty { stack[stack.count - 1].text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if !stack.isEmpty { stack[stack.count - 1].text += String(decoding: CDATABlock, as: UTF8.self) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let frame = stack.popLast() else { refused = true; return }
        if frame.isRating { scan.ratings.append(frame.children == 0 ? frame.text : "\u{0}structure") }
        if let item = frame.subjectItem { scan.subjects[item].append(frame.text) }
        if !frame.phocasas, frame.children == 0, !frame.text.isEmpty { scan.leaves[frame.text, default: 0] += 1 }
    }

    // A DTD could redefine what the text means.
    func parser(_ parser: XMLParser, foundElementDeclarationWithName elementName: String, model: String) { refused = true }
    func parser(_ parser: XMLParser, foundAttributeDeclarationWithName attributeName: String, forElement elementName: String,
                type: String?, defaultValue: String?) { refused = true }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { refused = true }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?,
                systemID: String?) { refused = true }
    func parser(_ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String, publicID: String?,
                systemID: String?, notationName: String?) { refused = true }
    func parser(_ parser: XMLParser, foundNotationDeclarationWithName name: String, publicID: String?, systemID: String?) {
        refused = true
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        refused = true
        return nil
    }
}

private extension XMPPacketScan {
    init(empty: Void) {}
}

// MARK: - The text edit

/// Sets `xmp:Rating` and `dc:subject` in an XMP packet by editing its text, so every other byte of it stays as it is
/// (the technique that changes the fewest bytes, and the only one that can't lose what ImageIO's model leaves out).
///
/// - A rating or keywords that are already there are changed where they are: an `xmp:Rating` attribute's value or
///   element's text, a `dc:subject` element's content (an empty array when there are no keywords, so the next
///   keywords go back in the same place and the packet doesn't grow).
/// - What isn't there yet is added in an `rdf:Description` of its own, after the last one, with the packet's
///   `rdf:about` and its own namespace declarations.
/// - A packet that ends in writable padding (`<?xpacket end="w"?>`) keeps its length: the edit takes its bytes from
///   the padding, or gives them back, as long as there is enough.
///
/// Refused (nil) unless the packet is well-formed UTF-8 XML with no DTD, has one `rdf:RDF` whose children are all
/// `rdf:Description`s about the same resource, and holds each of the two properties at most once, as a property of
/// one of those descriptions in a form edited in place (an attribute, or an element with nothing but text or an
/// array in it). The result is checked by reading it again (`XMPPacketScan`): the new values, and every other
/// property name and value of the original.
enum XMPTextEdit {
    /// What an empty keyword list writes where the packet has no `dc:subject`: nothing, or an empty one, which a
    /// reader takes as "no keywords" rather than falling back to the IPTC-IIM keywords (MWG 2.0 §4.2.3.2, and
    /// ImageIO). An existing `dc:subject` is emptied either way. (ImageIO's rewrite, `leaveOut`, removes it.)
    enum EmptyKeywords { case leaveOut, emptyBag }

    struct Result {
        let packet: Data
        /// Whether a new `rdf:Description` (with its own namespace declarations) was added; otherwise only the two
        /// properties' values changed, in place, and nothing else in the XML's structure.
        let addedDescription: Bool
    }

    static func setting(rating: Int, keywords: [String], emptyKeywords: EmptyKeywords = .leaveOut, in packet: Data) -> Result? {
        let bytes = [UInt8](packet)
        guard !bytes.contains(0), String(bytes: bytes, encoding: .utf8) != nil,
              keywords.allSatisfy(isXMLText), let before = XMPPacketScan(packet),
              let tree = XMLTree(bytes), let (edits, added) = plan(tree, rating: rating, keywords: keywords, emptyKeywords: emptyKeywords),
              tree.ratings.count == before.ratings.count, tree.subjects.count == before.subjects.count else { return nil }
        guard let result = apply(edits + padding(tree, for: edits), to: bytes) else { return nil }

        let data = Data(result)
        let subjects = keywords.isEmpty && emptyKeywords == .leaveOut && tree.subjects.isEmpty ? [] : [keywords]
        guard let after = XMPPacketScan(data), after.ratings == ["\(rating)"], after.subjects == subjects,
              before.isKept(in: after) else { return nil }
        return Result(packet: data, addedDescription: added)
    }

    // MARK: Planning

    private struct Edit {
        let range: Range<Int>
        let bytes: [UInt8]
    }

    private static func plan(_ tree: XMLTree, rating: Int, keywords: [String],
                             emptyKeywords: EmptyKeywords) -> (edits: [Edit], added: Bool)? {
        guard let last = tree.descriptions.last else { return nil }
        let afterLast = tree.elements[last].end?.upperBound ?? tree.elements[last].start.upperBound
        // Every description must be about the same resource (XMP Part 1 §7.4), and the new one too.
        let abouts = Set(tree.descriptions.map { tree.attribute(XMPNamespace.rdf, "about", of: $0).map { Array(tree.bytes[$0.value]) } ?? [] })
        guard abouts.count == 1, let about = abouts.first, !about.contains(UInt8(ascii: "\"")) else { return nil }

        var edits: [Edit] = []
        var addRating = false, addSubject = false
        switch tree.ratings.first {
        case nil:
            addRating = true
        case .attribute(let element, let attribute) where tree.ratings.count == 1 && tree.isDescription(element):
            edits.append(Edit(range: tree.elements[element].attributes[attribute].value, bytes: Array("\(rating)".utf8)))
        case .element(let element) where tree.ratings.count == 1 && tree.isEditableProperty(element, allowArray: false):
            guard let content = tree.content(of: element) else { return nil }
            edits.append(Edit(range: content, bytes: Array("\(rating)".utf8)))
        default:
            return nil
        }
        switch tree.subjects.first {
        case nil:
            addSubject = !keywords.isEmpty || emptyKeywords == .emptyBag
        case .element(let element) where tree.subjects.count == 1 && tree.isEditableProperty(element, allowArray: true):
            guard let content = tree.content(of: element), let prefix = tree.prefix(for: XMPNamespace.rdf, at: element)
            else { return nil }
            edits.append(Edit(range: content, bytes: bag(keywords, rdf: prefix)))
        default:
            return nil
        }
        if addRating || addSubject {
            var block = "<rdf:Description xmlns:rdf=\"\(XMPNamespace.rdf)\" rdf:about=\"" + String(decoding: about, as: UTF8.self) + "\""
            if addRating { block += " xmlns:xmp=\"\(XMPNamespace.xmp)\" xmp:Rating=\"\(rating)\"" }
            if addSubject {
                block += " xmlns:dc=\"\(XMPNamespace.dc)\"><dc:subject>" + String(decoding: bag(keywords, rdf: "rdf"), as: UTF8.self)
                    + "</dc:subject></rdf:Description>"
            } else {
                block += "/>"
            }
            edits.append(Edit(range: afterLast..<afterLast, bytes: Array(block.utf8)))
        }
        return (edits, addRating || addSubject)
    }

    /// `<rdf:Bag>` with one `<rdf:li>` per keyword, with the given prefix for the RDF namespace.
    private static func bag(_ keywords: [String], rdf prefix: String) -> [UInt8] {
        let p = prefix.isEmpty ? "" : prefix + ":"
        guard !keywords.isEmpty else { return Array("<\(p)Bag/>".utf8) }
        return Array(("<\(p)Bag>" + keywords.map { "<\(p)li>\(escaped($0))</\(p)li>" }.joined() + "</\(p)Bag>").utf8)
    }

    /// Text for element content: markup characters escaped, and carriage returns as references (an XML parser would
    /// turn a literal one into a line feed).
    private static func escaped(_ text: String) -> String {
        var out = ""
        for c in text.unicodeScalars {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\r": out += "&#xD;"
            default: out.unicodeScalars.append(c)
            }
        }
        return out
    }

    /// Whether XML 1.0 can hold `text` (no control characters other than tab, line feed and carriage return).
    private static func isXMLText(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { c in
            c == "\t" || c == "\n" || c == "\r" || (c.value >= 0x20 && c.value != 0xFFFE && c.value != 0xFFFF)
        }
    }

    /// With writable padding before the trailer, the edit that keeps the packet's length: padding taken for growth
    /// (when there is enough) or given back for shrinkage.
    private static func padding(_ tree: XMLTree, for edits: [Edit]) -> [Edit] {
        guard let padding = tree.writablePadding else { return [] }
        let growth = edits.reduce(0) { $0 + $1.bytes.count - $1.range.count }
        if growth > 0 && growth <= padding.count {
            return [Edit(range: (padding.upperBound - growth)..<padding.upperBound, bytes: [])]
        }
        if growth < 0 {
            return [Edit(range: padding.upperBound..<padding.upperBound, bytes: [UInt8](repeating: 0x20, count: -growth))]
        }
        return []
    }

    private static func apply(_ edits: [Edit], to bytes: [UInt8]) -> [UInt8]? {
        let sorted = edits.sorted { ($0.range.lowerBound, $0.range.upperBound) < ($1.range.lowerBound, $1.range.upperBound) }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + 512)
        var at = 0
        for edit in sorted {
            guard edit.range.lowerBound >= at, edit.range.upperBound <= bytes.count else { return nil }
            out += bytes[at..<edit.range.lowerBound]
            out += edit.bytes
            at = edit.range.upperBound
        }
        out += bytes[at...]
        return out
    }
}

// MARK: - The tags and elements, with their byte ranges

/// The elements of a well-formed XML document (already checked by `XMPPacketScan`), with the byte range of each tag
/// and attribute value and the namespaces in scope, for `XMPTextEdit`. Refuses (nil) what it doesn't expect: a DTD or
/// other `<!` declaration, a declared encoding other than UTF-8, an attribute value with an entity or character
/// reference in a namespace declaration, or tags that don't pair up.
private struct XMLTree {
    struct Attribute {
        let namespace: String
        let name: String
        let isNamespaceDeclaration: Bool
        /// Between the quotes.
        let value: Range<Int>
    }

    struct Element {
        let namespace: String
        let name: String
        let qualifiedName: ArraySlice<UInt8>
        let parent: Int?
        /// The start tag, `<` to `>`.
        let start: Range<Int>
        /// The end tag; nil when the start tag closes itself.
        var end: Range<Int>?
        var children: [Int] = []
        let attributes: [Attribute]
        /// Prefix to namespace, in scope at this element ("" is the default namespace).
        let scope: [String: String]
    }

    enum Occurrence {
        case attribute(element: Int, index: Int)
        case element(Int)
    }

    let bytes: [UInt8]
    private(set) var elements: [Element] = []
    private(set) var ratings: [Occurrence] = []
    private(set) var subjects: [Occurrence] = []
    /// The one `rdf:RDF` element.
    private(set) var rdf: Int?
    /// The `rdf:Description` children of `rdf:RDF`.
    private(set) var descriptions: [Int] = []
    /// The whitespace before a `<?xpacket end="w"?>` trailer that ends the packet.
    private(set) var writablePadding: Range<Int>?
    /// Several `rdf:RDF` elements, or a child of it that isn't an `rdf:Description` (a typed node).
    private var unexpectedRDF = false

    /// The byte strings the tokenizer looks for.
    private enum T {
        static let pi = Array("<?".utf8), piEnd = Array("?>".utf8), xmlDecl = Array("<?xml ".utf8)
        static let xmlDeclTab = Array("<?xml\t".utf8), trailer = Array("<?xpacket end".utf8)
        static let comment = Array("<!--".utf8), commentEnd = Array("-->".utf8), cdata = Array("<![CDATA[".utf8)
        static let cdataEnd = Array("]]>".utf8), declaration = Array("<!".utf8)
    }

    init?(_ bytes: [UInt8]) {
        self.bytes = bytes
        var open: [Int] = []
        var lastTagEnd = 0
        var trailer: Range<Int>?
        var i = 0
        let n = bytes.count
        func starts(_ u: [UInt8], at k: Int) -> Bool {
            guard k + u.count <= n else { return false }
            for m in 0..<u.count where bytes[k + m] != u[m] { return false }
            return true
        }
        func find(_ u: [UInt8], from k: Int) -> Int? {
            var j = k
            while j + u.count <= n {
                if bytes[j] == u[0] && starts(u, at: j) { return j }
                j += 1
            }
            return nil
        }
        while i < n {
            guard bytes[i] == UInt8(ascii: "<") else { i += 1; continue }
            if starts(T.pi, at: i) {
                guard let end = find(T.piEnd, from: i + 2) else { return nil }
                if starts(T.xmlDecl, at: i) || starts(T.xmlDeclTab, at: i) {
                    let declaration = String(decoding: bytes[i..<end], as: UTF8.self).lowercased()
                    if let range = declaration.range(of: "encoding") {
                        let rest = declaration[range.upperBound...].drop { $0 == " " || $0 == "=" || $0 == "\"" || $0 == "'" }
                        guard rest.hasPrefix("utf-8") else { return nil }
                    }
                }
                if starts(T.trailer, at: i) { trailer = i..<(end + 2) }
                i = end + 2
                continue
            }
            if starts(T.comment, at: i) {
                guard let end = find(T.commentEnd, from: i + 4) else { return nil }
                i = end + 3
                continue
            }
            if starts(T.cdata, at: i) {
                guard let end = find(T.cdataEnd, from: i + 9) else { return nil }
                i = end + 3
                continue
            }
            guard !starts(T.declaration, at: i) else { return nil }
            guard let tag = Self.tag(bytes, at: i) else { return nil }
            if tag.isEnd {
                guard let top = open.popLast(), elements[top].qualifiedName.elementsEqual(tag.name) else { return nil }
                elements[top].end = tag.range
            } else {
                guard let element = makeElement(tag, parent: open.last) else { return nil }
                elements.append(element)
                let index = elements.count - 1
                if let parent = open.last { elements[parent].children.append(index) }
                note(index)
                if !tag.selfClosing { open.append(index) }
            }
            lastTagEnd = tag.range.upperBound
            i = tag.range.upperBound
        }
        guard open.isEmpty, !elements.isEmpty, !unexpectedRDF else { return nil }
        if let trailer, trailer.lowerBound >= lastTagEnd,
           bytes[trailer.upperBound...].allSatisfy(Self.isSpace), Self.isWritable(bytes[trailer]) {
            var start = trailer.lowerBound
            while start > lastTagEnd, Self.isSpace(bytes[start - 1]) { start -= 1 }
            writablePadding = start..<trailer.lowerBound
        }
    }

    // MARK: Queries

    func attribute(_ namespace: String, _ name: String, of element: Int) -> Attribute? {
        elements[element].attributes.first { !$0.isNamespaceDeclaration && $0.namespace == namespace && $0.name == name }
    }

    func isDescription(_ element: Int) -> Bool { descriptions.contains(element) }

    /// A property element directly in one of the top descriptions, whose start tag declares nothing but namespaces
    /// and doesn't close itself, holding only text or (with `allowArray`) elements.
    func isEditableProperty(_ element: Int, allowArray: Bool) -> Bool {
        let e = elements[element]
        guard let parent = e.parent, isDescription(parent), e.end != nil,
              e.attributes.allSatisfy(\.isNamespaceDeclaration) else { return false }
        return allowArray || e.children.isEmpty
    }

    /// Between an element's start and end tags.
    func content(of element: Int) -> Range<Int>? {
        let e = elements[element]
        return e.end.map { e.start.upperBound..<$0.lowerBound }
    }

    /// A prefix bound to `namespace` at `element`: "rdf" if it is, else any other ("" for the default namespace).
    func prefix(for namespace: String, at element: Int) -> String? {
        let scope = elements[element].scope
        if scope["rdf"] == namespace { return "rdf" }
        return scope.filter { $0.value == namespace }.keys.sorted().first
    }

    // MARK: Building

    private mutating func note(_ index: Int) {
        let e = elements[index]
        if e.namespace == XMPNamespace.xmp && e.name == "Rating" { ratings.append(.element(index)) }
        if e.namespace == XMPNamespace.dc && e.name == "subject" { subjects.append(.element(index)) }
        for (k, a) in e.attributes.enumerated() where !a.isNamespaceDeclaration {
            if a.namespace == XMPNamespace.xmp && a.name == "Rating" { ratings.append(.attribute(element: index, index: k)) }
            if a.namespace == XMPNamespace.dc && a.name == "subject" { subjects.append(.attribute(element: index, index: k)) }
        }
        if e.namespace == XMPNamespace.rdf && e.name == "RDF" {
            if rdf == nil { rdf = index } else { unexpectedRDF = true }
        }
        if let parent = e.parent, parent == rdf {
            if e.namespace == XMPNamespace.rdf && e.name == "Description" { descriptions.append(index) } else { unexpectedRDF = true }
        }
    }

    private func makeElement(_ tag: Tag, parent: Int?) -> Element? {
        var scope = parent.map { elements[$0].scope } ?? [:]
        for (name, value) in tag.attributes {
            let text = bytes[value]
            if name.elementsEqual("xmlns".utf8) || name.starts(with: "xmlns:".utf8) {
                guard !text.contains(UInt8(ascii: "&")) else { return nil }
                let prefix = name.count > 6 ? String(decoding: name.dropFirst(6), as: UTF8.self) : ""
                scope[prefix] = String(decoding: text, as: UTF8.self)
            }
        }
        func split(_ q: ArraySlice<UInt8>) -> (prefix: String?, name: String) {
            guard let colon = q.firstIndex(of: UInt8(ascii: ":")) else { return (nil, String(decoding: q, as: UTF8.self)) }
            return (String(decoding: q[q.startIndex..<colon], as: UTF8.self), String(decoding: q[(colon + 1)...], as: UTF8.self))
        }
        let (elementPrefix, elementName) = split(tag.name)
        guard let elementNS = scope[elementPrefix ?? ""] ?? (elementPrefix == nil ? "" : nil) else { return nil }
        var attributes: [Attribute] = []
        for (name, value) in tag.attributes {
            let isDeclaration = name.elementsEqual("xmlns".utf8) || name.starts(with: "xmlns:".utf8)
            let (prefix, local) = split(name)
            let ns: String
            if isDeclaration { ns = "" } else if let prefix {
                if prefix == "xml" { ns = XMPNamespace.xml } else if let uri = scope[prefix] { ns = uri } else { return nil }
            } else {
                ns = ""
            }
            attributes.append(Attribute(namespace: ns, name: local, isNamespaceDeclaration: isDeclaration, value: value))
        }
        return Element(namespace: elementNS, name: elementName, qualifiedName: tag.name, parent: parent, start: tag.range,
                       attributes: attributes, scope: scope)
    }

    private struct Tag {
        let range: Range<Int>
        let name: ArraySlice<UInt8>
        let attributes: [(name: ArraySlice<UInt8>, value: Range<Int>)]
        let isEnd: Bool
        let selfClosing: Bool
    }

    private static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D }

    private static func isNameByte(_ b: UInt8) -> Bool {
        !isSpace(b) && b != UInt8(ascii: "/") && b != UInt8(ascii: ">") && b != UInt8(ascii: "=")
            && b != UInt8(ascii: "<") && b != UInt8(ascii: "\"") && b != UInt8(ascii: "'")
    }

    private static func isWritable(_ trailer: ArraySlice<UInt8>) -> Bool {
        let text = String(decoding: trailer, as: UTF8.self).replacingOccurrences(of: " ", with: "")
        return text.contains("end=\"w\"") || text.contains("end='w'")
    }

    /// The start or end tag at `i` (a `<`).
    private static func tag(_ b: [UInt8], at start: Int) -> Tag? {
        let n = b.count
        var i = start + 1
        let isEnd = i < n && b[i] == UInt8(ascii: "/")
        if isEnd { i += 1 }
        let nameStart = i
        while i < n, isNameByte(b[i]) { i += 1 }
        guard i > nameStart else { return nil }
        let name = b[nameStart..<i]
        var attributes: [(ArraySlice<UInt8>, Range<Int>)] = []
        while true {
            while i < n, isSpace(b[i]) { i += 1 }
            guard i < n else { return nil }
            if b[i] == UInt8(ascii: ">") {
                return Tag(range: start..<(i + 1), name: name, attributes: attributes, isEnd: isEnd, selfClosing: false)
            }
            if b[i] == UInt8(ascii: "/"), i + 1 < n, b[i + 1] == UInt8(ascii: ">"), !isEnd {
                return Tag(range: start..<(i + 2), name: name, attributes: attributes, isEnd: false, selfClosing: true)
            }
            guard !isEnd else { return nil }
            let attributeStart = i
            while i < n, isNameByte(b[i]) { i += 1 }
            guard i > attributeStart else { return nil }
            let attributeName = b[attributeStart..<i]
            while i < n, isSpace(b[i]) { i += 1 }
            guard i < n, b[i] == UInt8(ascii: "=") else { return nil }
            i += 1
            while i < n, isSpace(b[i]) { i += 1 }
            guard i < n, b[i] == UInt8(ascii: "\"") || b[i] == UInt8(ascii: "'") else { return nil }
            let quote = b[i]
            let valueStart = i + 1
            guard let close = b[valueStart...].firstIndex(of: quote) else { return nil }
            attributes.append((attributeName, valueStart..<close))
            i = close + 1
        }
    }
}
