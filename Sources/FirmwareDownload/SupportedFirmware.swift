import Darwin
import Foundation
import NS58Core
import ZIPFoundation

/// A pinned, previously verified release. This is not a claim about the newest
/// firmware available from GuliKit; new releases need a reviewed device profile.
public enum SupportedFirmware {
    public static let version = "3.7"
    public static let officialPage = URL(string: "https://www.gulikit.com/newsinfo/1071651.html")!
    public static let downloadURL = URL(string: "https://fichiers.touslesdrivers.com/84388/NS58_Elves2_V3.7.zip")!
    public static let archiveSHA256 = "b2a447203f7329e8981050717cfc1aa143a00dd18d50015e9cfdad389e645784"
    public static let maxArchiveBytes = 512 * 1024

    public static func isAllowedDownloadURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == downloadURL.host
            && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil
            && url.path == downloadURL.path && url.query == nil && url.fragment == nil
    }

    public static func download() async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        let session = URLSession(configuration: config, delegate: DownloadPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: downloadURL)
        request.setValue("GuliKitUpdater/0.1", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let finalURL = http.url, isAllowedDownloadURL(finalURL) else {
            throw NS58Error.invalid("Firmware download did not return a permitted HTTPS success response")
        }
        guard response.expectedContentLength <= Int64(maxArchiveBytes) else {
            throw NS58Error.invalid("Firmware package exceeds the download limit")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maxArchiveBytes else {
                throw NS58Error.invalid("Firmware package exceeds the download limit")
            }
            data.append(byte)
        }
        return try extract(from: data)
    }

    public static func extract(from archiveData: Data) throws -> Data {
        guard !archiveData.isEmpty, archiveData.count <= maxArchiveBytes,
              NS58FAT12.sha256(archiveData) == archiveSHA256 else {
            throw NS58Error.invalid("Downloaded package does not match the verified NS58 V3.7 ZIP")
        }
        // Decode only the pinned package bytes, and extract no archive paths to disk.
        let archive = try Archive(data: archiveData, accessMode: .read)
        let candidates = archive.filter { $0.path == NS58Constants.firmwareName }
        guard candidates.count == 1, let entry = candidates.first, entry.type == .file,
              entry.uncompressedSize == UInt64(NS58Constants.firmwareSize) else {
            throw NS58Error.invalid("The package does not contain exactly one expected NS58 firmware file")
        }
        var firmware = Data()
        let crc = try archive.extract(entry, bufferSize: 16 * 1024) { chunk in
            guard chunk.count <= NS58Constants.firmwareSize - firmware.count else {
                throw NS58Error.invalid("Extracted firmware exceeds its expected size")
            }
            firmware.append(chunk)
        }
        guard crc == entry.checksum else { throw NS58Error.invalid("Firmware ZIP CRC mismatch") }
        try NS58FAT12.verifyFirmware(firmware, filename: NS58Constants.firmwareName)
        return firmware
    }

    /// Publish the verified BIN atomically. An existing file or symlink is never replaced.
    public static func saveVerified(_ firmware: Data, in directory: URL) throws -> URL {
        try NS58FAT12.verifyFirmware(firmware, filename: NS58Constants.firmwareName)
        let destination = directory.appendingPathComponent(NS58Constants.firmwareName)
        let temporary = directory.appendingPathComponent(".gulikit-\(UUID().uuidString).tmp")
        try firmware.write(to: temporary, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let result = temporary.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target in
                renameatx_np(AT_FDCWD, source!, AT_FDCWD, target!, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return destination
    }
}

private final class DownloadPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.map(SupportedFirmware.isAllowedDownloadURL) == true ? request : nil)
    }
}
