import AppKit
import CoreImage
import Foundation
import MiscKitCore
import Vision

/// 二维码导入：读截图或图片里的 `otpauth://`。
/// 用 Vision 的 `VNDetectBarcodesRequest`——不需要屏幕录制/辅助功能任何权限，
/// 也不要求图片来自相机，用户从聊天里存的截图直接就能解。
enum OTPQRReader {
    enum ReadError: LocalizedError, Sendable {
        case unreadable
        case noBarcode

        var errorDescription: String? {
            switch self {
            case .unreadable: return L10n.OTP.QR.unreadable
            case .noBarcode: return L10n.OTP.QR.noBarcode
            }
        }
    }

    typealias Parsed = (entries: [OTPEntry], failures: [OTPFailure],
                        batches: [OTPMigration.BatchProgress])

    static func readAsync(url: URL) async -> Result<Parsed, ReadError> {
        let language = L10n.effectiveLanguage
        return await Task.detached(priority: .userInitiated) {
            L10n.withLanguage(language) {
                read(url: url)
            }
        }.value
    }

    static func readAsync(image: NSImage) async -> Result<Parsed, ReadError> {
        let language = L10n.effectiveLanguage
        let tiff = image.tiffRepresentation
        return await Task.detached(priority: .userInitiated) {
            L10n.withLanguage(language) {
                guard let tiff else { return .failure(.unreadable) }
                return read(tiffData: tiff)
            }
        }.value
    }

    static func read(url: URL) -> Result<Parsed, ReadError> {
        guard let image = CIImage(contentsOf: url) else { return .failure(.unreadable) }
        return read(image: image)
    }

    static func read(image: NSImage) -> Result<Parsed, ReadError> {
        guard let tiff = image.tiffRepresentation else { return .failure(.unreadable) }
        return read(tiffData: tiff)
    }

    private static func read(tiffData: Data) -> Result<Parsed, ReadError> {
        guard let source = CGImageSourceCreateWithData(tiffData as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return .failure(.unreadable)
        }
        return read(image: CIImage(cgImage: cg))
    }

    private static func read(image ci: CIImage) -> Result<Parsed, ReadError> {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(ciImage: ci, options: [:])
        guard (try? handler.perform([request])) != nil else { return .failure(.unreadable) }
        guard let results = request.results else { return .failure(.unreadable) }
        let payloads = results.compactMap { $0.payloadStringValue }
        guard !payloads.isEmpty else { return .failure(.noBarcode) }
        // 有的服务把长链接切成多帧二维码，单帧解不全时把全部帧拼起来再试一次
        let joined = payloads.joined(separator: "\n")
        let parsed = OtpAuthURI.parseBatchDetailed(joined)
        guard !parsed.entries.isEmpty || !parsed.failures.isEmpty || !parsed.batches.isEmpty else {
            return .failure(.noBarcode)
        }
        return .success((parsed.entries, parsed.failures, parsed.batches))
    }
}
