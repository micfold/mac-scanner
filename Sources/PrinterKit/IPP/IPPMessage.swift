import Foundation

/// IPP value tags (RFC 8010 §3.5).
public enum IPPTag {
  // Delimiters
  public static let operationAttributes: UInt8 = 0x01
  public static let jobAttributes: UInt8 = 0x02
  public static let endOfAttributes: UInt8 = 0x03
  public static let printerAttributes: UInt8 = 0x04
  public static let unsupportedAttributes: UInt8 = 0x05
  // Out-of-band
  public static let unsupported: UInt8 = 0x10
  public static let unknown: UInt8 = 0x12
  public static let noValue: UInt8 = 0x13
  // Integer-ish
  public static let integer: UInt8 = 0x21
  public static let boolean: UInt8 = 0x22
  public static let enumeration: UInt8 = 0x23
  // Octet-string-ish
  public static let octetString: UInt8 = 0x30
  public static let dateTime: UInt8 = 0x31
  public static let resolution: UInt8 = 0x32
  public static let rangeOfInteger: UInt8 = 0x33
  public static let beginCollection: UInt8 = 0x34
  public static let endCollection: UInt8 = 0x37
  public static let textWithoutLanguage: UInt8 = 0x41
  public static let nameWithoutLanguage: UInt8 = 0x42
  public static let keyword: UInt8 = 0x44
  public static let uri: UInt8 = 0x45
  public static let charset: UInt8 = 0x47
  public static let naturalLanguage: UInt8 = 0x48
  public static let mimeMediaType: UInt8 = 0x49
  public static let memberAttrName: UInt8 = 0x4A
}

public enum IPPValue: Sendable, Equatable {
  case integer(Int32)
  case boolean(Bool)
  case enumeration(Int32)
  /// Any string-typed value (text, name, keyword, uri, charset, language, MIME type).
  case string(String, tag: UInt8)
  case octets(Data, tag: UInt8)
  case resolution(x: Int32, y: Int32, units: Int8)
  case range(lower: Int32, upper: Int32)
  case collection([IPPAttribute])
  case outOfBand(tag: UInt8)

  public static func keyword(_ value: String) -> IPPValue { .string(value, tag: IPPTag.keyword) }
  public static func name(_ value: String) -> IPPValue { .string(value, tag: IPPTag.nameWithoutLanguage) }
  public static func text(_ value: String) -> IPPValue { .string(value, tag: IPPTag.textWithoutLanguage) }
  public static func uri(_ value: String) -> IPPValue { .string(value, tag: IPPTag.uri) }
  public static func charset(_ value: String) -> IPPValue { .string(value, tag: IPPTag.charset) }
  public static func language(_ value: String) -> IPPValue { .string(value, tag: IPPTag.naturalLanguage) }
  public static func mimeType(_ value: String) -> IPPValue { .string(value, tag: IPPTag.mimeMediaType) }

  public var string: String? {
    switch self {
    case .string(let value, _): value
    case .octets(let data, _): String(data: data, encoding: .utf8)
    default: nil
    }
  }

  public var int: Int? {
    switch self {
    case .integer(let value), .enumeration(let value): Int(value)
    default: nil
    }
  }

  public var bool: Bool? {
    if case .boolean(let value) = self { return value }
    return nil
  }

  public var members: [IPPAttribute]? {
    if case .collection(let members) = self { return members }
    return nil
  }

  var tag: UInt8 {
    switch self {
    case .integer: IPPTag.integer
    case .boolean: IPPTag.boolean
    case .enumeration: IPPTag.enumeration
    case .string(_, let tag), .octets(_, let tag), .outOfBand(let tag): tag
    case .resolution: IPPTag.resolution
    case .range: IPPTag.rangeOfInteger
    case .collection: IPPTag.beginCollection
    }
  }
}

public struct IPPAttribute: Sendable, Equatable {
  public var name: String
  public var values: [IPPValue]

  public init(_ name: String, _ values: [IPPValue]) {
    self.name = name
    self.values = values
  }

  public init(_ name: String, _ value: IPPValue) {
    self.init(name, [value])
  }

  public var strings: [String] { values.compactMap(\.string) }
  public var ints: [Int] { values.compactMap(\.int) }
}

extension Array where Element == IPPAttribute {
  public subscript(name: String) -> IPPAttribute? { first { $0.name == name } }
}

public struct IPPAttributeGroup: Sendable, Equatable {
  public var tag: UInt8
  public var attributes: [IPPAttribute]

  public init(tag: UInt8, attributes: [IPPAttribute]) {
    self.tag = tag
    self.attributes = attributes
  }

  public subscript(name: String) -> IPPAttribute? { attributes[name] }
}

/// An IPP request or response (RFC 8010).
public struct IPPMessage: Sendable, Equatable {
  public var version: (major: UInt8, minor: UInt8) = (2, 0)
  /// Operation id for requests, status code for responses.
  public var code: UInt16
  public var requestID: Int32
  public var groups: [IPPAttributeGroup]
  public var document: Data

  public init(code: UInt16, requestID: Int32, groups: [IPPAttributeGroup], document: Data = Data()) {
    self.code = code
    self.requestID = requestID
    self.groups = groups
    self.document = document
  }

  public static func == (lhs: IPPMessage, rhs: IPPMessage) -> Bool {
    lhs.version == rhs.version && lhs.code == rhs.code && lhs.requestID == rhs.requestID
      && lhs.groups == rhs.groups && lhs.document == rhs.document
  }

  public func groups(_ tag: UInt8) -> [IPPAttributeGroup] { groups.filter { $0.tag == tag } }

  /// First attribute with this name in any group of the given kind.
  public func attribute(_ name: String, in tag: UInt8) -> IPPAttribute? {
    groups(tag).lazy.compactMap { $0[name] }.first
  }

  public var isSuccess: Bool { code <= 0x00FF }
}

// MARK: - Encoding

extension IPPMessage {
  public func encoded() -> Data {
    var out = Data()
    out.append(version.major)
    out.append(version.minor)
    out.appendUInt16(code)
    out.appendInt32(requestID)
    for group in groups {
      out.append(group.tag)
      for attribute in group.attributes {
        for (index, value) in attribute.values.enumerated() {
          Self.write(value, name: index == 0 ? attribute.name : "", into: &out)
        }
      }
    }
    out.append(IPPTag.endOfAttributes)
    out.append(document)
    return out
  }

  private static func write(_ value: IPPValue, name: String, into out: inout Data) {
    out.append(value.tag)
    out.appendString16(name)
    switch value {
    case .integer(let number), .enumeration(let number):
      out.appendUInt16(4)
      out.appendInt32(number)
    case .boolean(let flag):
      out.appendUInt16(1)
      out.append(flag ? 1 : 0)
    case .string(let text, _):
      out.appendString16(text)
    case .octets(let data, _):
      out.appendUInt16(UInt16(data.count))
      out.append(data)
    case .resolution(let x, let y, let units):
      out.appendUInt16(9)
      out.appendInt32(x)
      out.appendInt32(y)
      out.append(UInt8(bitPattern: units))
    case .range(let lower, let upper):
      out.appendUInt16(8)
      out.appendInt32(lower)
      out.appendInt32(upper)
    case .collection(let members):
      out.appendUInt16(0)
      for member in members {
        out.append(IPPTag.memberAttrName)
        out.appendUInt16(0)
        out.appendString16(member.name)
        for memberValue in member.values { write(memberValue, name: "", into: &out) }
      }
      out.append(IPPTag.endCollection)
      out.appendUInt16(0)
      out.appendUInt16(0)
    case .outOfBand:
      out.appendUInt16(0)
    }
  }
}

// MARK: - Decoding

public enum IPPError: Error, Sendable, Equatable {
  case malformed(String)
  /// The printer answered with a non-successful status code.
  case status(code: UInt16, message: String?)
  case http(status: Int)
}

extension IPPMessage {
  public static func decode(_ data: Data) throws -> IPPMessage {
    var reader = ByteReader(data)
    let major = try reader.u8()
    let minor = try reader.u8()
    let code = try reader.u16()
    let requestID = try reader.i32()

    var groups: [IPPAttributeGroup] = []
    while true {
      let tag = try reader.u8()
      if tag == IPPTag.endOfAttributes { break }
      if tag < 0x10 {
        groups.append(IPPAttributeGroup(tag: tag, attributes: []))
        continue
      }
      guard !groups.isEmpty else { throw IPPError.malformed("value before first group") }
      let name = try reader.string16()
      let value = try readValue(tag: tag, from: &reader)
      if name.isEmpty {
        guard !groups[groups.count - 1].attributes.isEmpty else {
          throw IPPError.malformed("additional value without attribute")
        }
        groups[groups.count - 1].attributes[groups[groups.count - 1].attributes.count - 1].values.append(value)
      } else {
        groups[groups.count - 1].attributes.append(IPPAttribute(name, [value]))
      }
    }
    var message = IPPMessage(code: code, requestID: requestID, groups: groups, document: reader.rest())
    message.version = (major, minor)
    return message
  }

  private static func readValue(tag: UInt8, from reader: inout ByteReader) throws -> IPPValue {
    let bytes = try reader.bytes(Int(try reader.u16()))
    switch tag {
    case IPPTag.integer, IPPTag.enumeration:
      guard bytes.count == 4 else { throw IPPError.malformed("integer length \(bytes.count)") }
      let number = Int32(bigEndian: bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
      return tag == IPPTag.integer ? .integer(number) : .enumeration(number)
    case IPPTag.boolean:
      return .boolean(bytes.first.map { $0 != 0 } ?? false)
    case IPPTag.resolution:
      guard bytes.count == 9 else { throw IPPError.malformed("resolution length") }
      var sub = ByteReader(bytes)
      return .resolution(x: try sub.i32(), y: try sub.i32(), units: Int8(bitPattern: try sub.u8()))
    case IPPTag.rangeOfInteger:
      guard bytes.count == 8 else { throw IPPError.malformed("range length") }
      var sub = ByteReader(bytes)
      return .range(lower: try sub.i32(), upper: try sub.i32())
    case IPPTag.beginCollection:
      return .collection(try readCollection(from: &reader))
    case IPPTag.octetString, IPPTag.dateTime:
      return .octets(bytes, tag: tag)
    case 0x10...0x1F:
      return .outOfBand(tag: tag)
    case 0x35, 0x36:  // textWithLanguage / nameWithLanguage: 2-byte lang length, lang, 2-byte text length, text
      var sub = ByteReader(bytes)
      _ = try sub.string16()
      return .string(try sub.string16(), tag: tag == 0x35 ? IPPTag.textWithoutLanguage : IPPTag.nameWithoutLanguage)
    default:
      return .string(String(decoding: bytes, as: UTF8.self), tag: tag)
    }
  }

  private static func readCollection(from reader: inout ByteReader) throws -> [IPPAttribute] {
    var members: [IPPAttribute] = []
    while true {
      let tag = try reader.u8()
      _ = try reader.string16()  // member values carry an empty name
      if tag == IPPTag.endCollection {
        _ = try reader.bytes(Int(try reader.u16()))
        return members
      }
      if tag == IPPTag.memberAttrName {
        let memberName = String(decoding: try reader.bytes(Int(try reader.u16())), as: UTF8.self)
        members.append(IPPAttribute(memberName, []))
        continue
      }
      guard !members.isEmpty else { throw IPPError.malformed("collection value without member name") }
      members[members.count - 1].values.append(try readValue(tag: tag, from: &reader))
    }
  }
}

// MARK: - Byte helpers

struct ByteReader {
  private let data: Data
  private var offset: Int

  init(_ data: Data) {
    self.data = Data(data)  // re-base indices at 0
    offset = 0
  }

  mutating func bytes(_ count: Int) throws -> Data {
    guard count >= 0, offset + count <= data.count else { throw IPPError.malformed("truncated message") }
    defer { offset += count }
    return data.subdata(in: offset..<(offset + count))
  }

  mutating func u8() throws -> UInt8 { try bytes(1)[0] }

  mutating func u16() throws -> UInt16 {
    let b = try bytes(2)
    return UInt16(b[0]) << 8 | UInt16(b[1])
  }

  mutating func i32() throws -> Int32 {
    let b = try bytes(4)
    return Int32(bitPattern: UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
  }

  mutating func string16() throws -> String {
    String(decoding: try bytes(Int(try u16())), as: UTF8.self)
  }

  func rest() -> Data { data.subdata(in: offset..<data.count) }
}

extension Data {
  mutating func appendUInt16(_ value: UInt16) {
    append(UInt8(value >> 8))
    append(UInt8(value & 0xFF))
  }

  mutating func appendInt32(_ value: Int32) {
    let bits = UInt32(bitPattern: value)
    append(contentsOf: [UInt8(bits >> 24), UInt8((bits >> 16) & 0xFF), UInt8((bits >> 8) & 0xFF), UInt8(bits & 0xFF)])
  }

  mutating func appendString16(_ string: String) {
    let bytes = Array(string.utf8)
    appendUInt16(UInt16(bytes.count))
    append(contentsOf: bytes)
  }
}
