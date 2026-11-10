import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ClipboardImageReaderTests {
    static func run() -> [String] {
        var failures: [String] = []
        func expect(_ value: Bool, _ message: String) {
            if !value { failures.append(message) }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pasteboard = NSPasteboard.withUniqueName()
        defer {
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: directory)
        }
        func rejects(_ label: String) {
            let count = pasteboard.changeCount
            do { _ = try ClipboardImageReader.png(from: pasteboard); failures.append(label) }
            catch { expect(pasteboard.changeCount == count, "failure changed copied content") }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 7, pixelsHigh: 3,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            for y in 0..<3 { for x in 0..<7 { bitmap.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: x, y: y) } }
            let png = bitmap.representation(using: .png, properties: [:])!
            let file = directory.appendingPathComponent("图片 空格.png")
            try png.write(to: file)
            let item = NSPasteboardItem()
            item.setString(file.absoluteString, forType: .fileURL)
            // Simulate Finder exposing its icon as TIFF alongside a real file URL.
            let icon = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            item.setData(icon.tiffRepresentation!, forType: .tiff)
            pasteboard.writeObjects([item])
            let generation = pasteboard.changeCount
            let actual = NSBitmapImageRep(data: try ClipboardImageReader.png(from: pasteboard))!
            expect(actual.pixelsWide == 7 && actual.pixelsHigh == 3, "Finder file replaced by icon")
            expect(pasteboard.changeCount == generation, "reader modified clipboard")
            expect((actual.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB)?.redComponent ?? 0) > 0.9, "file pixel content lost")

            let jpeg = directory.appendingPathComponent("rotated.jpg")
            let destination = CGImageDestinationCreateWithURL(jpeg as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, bitmap.cgImage!, [kCGImagePropertyOrientation: 6] as CFDictionary)
            expect(CGImageDestinationFinalize(destination), "JPEG fixture failed")
            let rotated = NSBitmapImageRep(data: try ClipboardImageReader.png(fromFile: jpeg))!
            expect(rotated.pixelsWide == 3 && rotated.pixelsHigh == 7, "JPEG orientation lost")

            pasteboard.clearContents(); pasteboard.writeObjects([file as NSURL, jpeg as NSURL])
            rejects("multiple files silently accepted")
            pasteboard.clearContents(); pasteboard.writeObjects([directory as NSURL])
            rejects("directory accepted as an image")
            let corrupt = directory.appendingPathComponent("corrupt.png")
            try Data("not an image".utf8).write(to: corrupt)
            pasteboard.clearContents(); pasteboard.writeObjects([corrupt as NSURL])
            rejects("corrupt image accepted")
            try FileManager.default.removeItem(at: corrupt)
            rejects("missing image accepted")
            let large = directory.appendingPathComponent("large.png")
            FileManager.default.createFile(atPath: large.path, contents: nil)
            let handle = try FileHandle(forWritingTo: large)
            try handle.truncate(atOffset: UInt64(ClipboardImageReader.maximumFileBytes + 1)); try handle.close()
            pasteboard.clearContents(); pasteboard.writeObjects([large as NSURL])
            rejects("oversized file accepted")

            pasteboard.clearContents(); pasteboard.setData(png, forType: .png)
            expect(try ClipboardImageReader.png(from: pasteboard) == png, "raw PNG changed")
            pasteboard.clearContents(); pasteboard.setData(bitmap.tiffRepresentation!, forType: .tiff)
            let tiffResult = NSBitmapImageRep(data: try ClipboardImageReader.png(from: pasteboard))!
            expect(tiffResult.pixelsWide == 7 && tiffResult.pixelsHigh == 3, "TIFF regression")
            pasteboard.clearContents(); pasteboard.setString("plain text", forType: .string)
            rejects("text accepted as image")
        } catch { failures.append("Clipboard image fixture failed: \(error)") }
        return failures
    }
}
