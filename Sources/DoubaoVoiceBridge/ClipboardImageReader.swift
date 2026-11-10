import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ClipboardImageError: LocalizedError {
    case noImage, multipleFiles, unreadableFile, unsupportedImage, tooLarge

    var errorDescription: String? {
        switch self {
        case .noImage: return "剪贴板中没有图片；可在访达选择一张图片后按 ⌘C。"
        case .multipleFiles: return "一次只支持一张图片，请在访达只选择一张图片后复制。"
        case .unreadableFile: return "无法读取复制的图片文件，请确认文件仍在本机且可以打开。"
        case .unsupportedImage: return "复制的文件不是可读取的图片，请选择 PNG、JPEG、HEIC 等图片。"
        case .tooLarge: return "图片过大：文件最多 64 MiB、3200 万像素，转换后的 PNG 最多 16 MiB。"
        }
    }
}

enum ClipboardImageReader {
    static let maximumFileBytes = 64 * 1024 * 1024

    static func png(from pasteboard: NSPasteboard) throws -> Data {
        // Finder may publish a TIFF of the file icon. File URLs MUST take priority.
        let hasFileURLs = pasteboard.types?.contains(.fileURL) == true
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL] ?? []
        if hasFileURLs || !urls.isEmpty {
            guard urls.count == 1 else {
                throw urls.isEmpty ? ClipboardImageError.unreadableFile : .multipleFiles
            }
            return try png(fromFile: urls[0])
        }
        if let png = pasteboard.data(forType: .png) { return png }
        if let tiff = pasteboard.data(forType: .tiff),
           let image = NSBitmapImageRep(data: tiff),
           let png = image.representation(using: .png, properties: [:]) { return png }
        throw ClipboardImageError.noImage
    }

    static func png(fromFile url: URL) throws -> Data {
        guard url.isFileURL else { throw ClipboardImageError.unreadableFile }
        let file = url.resolvingSymlinksInPath()
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize else {
            throw ClipboardImageError.unreadableFile
        }
        guard size > 0, size <= maximumFileBytes else { throw ClipboardImageError.tooLarge }
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary), let type = CGImageSourceGetType(source),
              UTType(type as String)?.conforms(to: .image) == true,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { throw ClipboardImageError.unsupportedImage }
        // Check dimensions before decoding; division avoids overflowing malformed sizes.
        guard width <= ScreenshotPolicy.maximumPixels / height else { throw ClipboardImageError.tooLarge }
        // Preserve full resolution and apply EXIF orientation (JPEG/HEIC).
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height)
        ] as CFDictionary),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ClipboardImageError.unsupportedImage
        }
        guard png.count <= ScreenshotPolicy.maximumPNGBytes else { throw ClipboardImageError.tooLarge }
        return png
    }
}
