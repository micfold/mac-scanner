import Foundation

#if canImport(FoundationXML)
  import FoundationXML
#endif

/// A tiny read-only XML tree. eSCL documents are small, so a DOM is simpler than SAX.
/// Element names are stored without their namespace prefix (`scan:Platen` → `Platen`).
public struct XElement: Sendable, Equatable {
  public let name: String
  public let attributes: [String: String]
  public let children: [XElement]
  /// Text content, trimmed of surrounding whitespace.
  public let value: String

  public func child(_ name: String) -> XElement? { children.first { $0.name == name } }

  /// First descendant (depth-first, document order) with the given name.
  public func first(_ name: String) -> XElement? {
    for child in children {
      if child.name == name { return child }
      if let match = child.first(name) { return match }
    }
    return nil
  }

  /// All descendants with the given name, in document order.
  public func all(_ name: String) -> [XElement] {
    children.flatMap { ($0.name == name ? [$0] : []) + $0.all(name) }
  }

  public func int(_ name: String) -> Int? { first(name).flatMap { Int($0.value) } }

  public static func parse(_ data: Data) throws -> XElement {
    let builder = TreeBuilder()
    let parser = XMLParser(data: data)
    parser.delegate = builder
    guard parser.parse(), let root = builder.root else {
      throw XMLError.malformed(parser.parserError?.localizedDescription ?? "empty document")
    }
    return root
  }
}

public enum XMLError: Error, Sendable, Equatable {
  case malformed(String)
}

private final class TreeBuilder: NSObject, XMLParserDelegate {
  private final class Node {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [XElement] = []
    init(name: String, attributes: [String: String]) {
      self.name = name
      self.attributes = attributes
    }
  }

  private var stack: [Node] = []
  private(set) var root: XElement?

  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
  ) {
    let localName = elementName.split(separator: ":").last.map(String.init) ?? elementName
    stack.append(Node(name: localName, attributes: attributeDict))
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    stack.last?.text += string
  }

  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    guard let node = stack.popLast() else { return }
    let element = XElement(
      name: node.name,
      attributes: node.attributes,
      children: node.children,
      value: node.text.trimmingCharacters(in: .whitespacesAndNewlines))
    if let parent = stack.last { parent.children.append(element) } else { root = element }
  }
}
