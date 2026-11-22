import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Minimální XML strom – eSCL odpovědi jsou malé, stačí nám jednoduchý DOM.
/// Jména elementů ukládáme bez prefixu jmenného prostoru (`scan:Platen` → `Platen`).
public final class XElement {
    public let name: String
    public let qualifiedName: String
    public var attributes: [String: String]
    public var text: String = ""
    public var children: [XElement] = []

    init(qualifiedName: String, attributes: [String: String]) {
        self.qualifiedName = qualifiedName
        self.name = qualifiedName.split(separator: ":").last.map(String.init) ?? qualifiedName
        self.attributes = attributes
    }

    public var value: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    public func child(_ name: String) -> XElement? { children.first { $0.name == name } }

    public func children(_ name: String) -> [XElement] { children.filter { $0.name == name } }

    /// Všichni potomci (v libovolné hloubce) s daným jménem, v pořadí dokumentu.
    public func descendants(_ name: String) -> [XElement] {
        var out: [XElement] = []
        for c in children {
            if c.name == name { out.append(c) }
            out.append(contentsOf: c.descendants(name))
        }
        return out
    }

    public func first(_ name: String) -> XElement? {
        for c in children {
            if c.name == name { return c }
            if let d = c.first(name) { return d }
        }
        return nil
    }

    public func int(_ name: String) -> Int? { first(name).flatMap { Int($0.value) } }
}

public enum XMLTreeError: Error, CustomStringConvertible {
    case parseFailed(String)
    public var description: String {
        switch self { case .parseFailed(let m): return "Neplatná XML odpověď: \(m)" }
    }
}

public enum XMLTree {
    public static func parse(_ data: Data) throws -> XElement {
        let builder = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw XMLTreeError.parseFailed(parser.parserError?.localizedDescription ?? "prázdný dokument")
        }
        return root
    }
}

private final class TreeBuilder: NSObject, XMLParserDelegate {
    var root: XElement?
    private var stack: [XElement] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let el = XElement(qualifiedName: elementName, attributes: attributeDict)
        if let parent = stack.last { parent.children.append(el) } else { root = el }
        stack.append(el)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        _ = stack.popLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }
}
