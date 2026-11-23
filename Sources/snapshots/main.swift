import AppFeature
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// Renders every screen with sample data to PNG, plus an animated GIF for the README.
//
//   swift run snapshots <output-directory>

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/snapshots", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let size = CGSize(width: 1280, height: 800)
let model = AppModel.preview()
await model.session.refresh()

/// Lays out the view in an off-screen window, lets it settle, and captures it.
@MainActor func capture(_ section: AppSection, appearance: NSAppearance.Name) async -> CGImage? {
  model.section = section
  let host = NSHostingView(rootView: RootView(model: model).frame(width: size.width, height: size.height))
  let window = NSWindow(
    contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView],
    backing: .buffered, defer: false)
  window.appearance = NSAppearance(named: appearance)
  window.contentView = host
  window.layoutIfNeeded()
  try? await Task.sleep(for: .milliseconds(1200))
  host.layoutSubtreeIfNeeded()
  guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
  host.cacheDisplay(in: host.bounds, to: rep)
  return rep.cgImage
}

func writePNG(_ image: CGImage, to url: URL) {
  guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
  else { return }
  CGImageDestinationAddImage(destination, image, nil)
  CGImageDestinationFinalize(destination)
}

let sections: [AppSection] = [.overview, .scan, .print, .jobs, .device]
var frames: [CGImage] = []
for appearance in [NSAppearance.Name.aqua, .darkAqua] {
  for section in sections {
    guard let image = await capture(section, appearance: appearance) else {
      print("failed: \(section)")
      continue
    }
    let name = "\(section.rawValue)-\(appearance == .aqua ? "light" : "dark").png"
    writePNG(image, to: output.appendingPathComponent(name))
    print("wrote \(name)")
    if appearance == .darkAqua && section != .device { frames.append(image) }
  }
}

// Animated GIF: ~2.5 s per screen, looping.
let gifURL = output.appendingPathComponent("demo.gif")
if let destination = CGImageDestinationCreateWithURL(
  gifURL as CFURL, UTType.gif.identifier as CFString, frames.count, nil)
{
  CGImageDestinationSetProperties(
    destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
  for frame in frames {
    let scaled = frame.scaled(toWidth: 960) ?? frame
    CGImageDestinationAddImage(
      destination, scaled, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 2.5]] as CFDictionary)
  }
  CGImageDestinationFinalize(destination)
  print("wrote demo.gif")
}

extension CGImage {
  func scaled(toWidth width: Int) -> CGImage? {
    let height = self.height * width / self.width
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.interpolationQuality = .high
    context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
  }
}
