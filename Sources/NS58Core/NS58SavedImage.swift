import Darwin
import Foundation

/// An immutable snapshot of a saved NS58 virtual disk or contiguous prefix.
/// This reader never mounts a file system or reads from an open USB session.
public struct NS58SavedImage: Sendable {
    // The captured device exposes 119 sectors, but its FAT boot record
    // describes 123. Accept saved prefixes and images padded to either size.
    public static let maximumByteCount = 123 * NS58Constants.bytesPerSector
    public static let minimumPlanByteCount =
        (NS58Constants.firmwareStartLBA + NS58Constants.firmwareBlocks) * NS58Constants.bytesPerSector

    public let bytes: Data

    public init(contentsOf url: URL) throws {
        guard url.isFileURL else {
            throw NS58Error.invalid("Image input must be a local file")
        }
        let (descriptor, expectedCount) = try url.withUnsafeFileSystemRepresentation { path -> (Int32, Int) in
            guard let path else { throw NS58Error.invalid("Invalid image path") }
            // Reject devices, FIFOs, directories, and symbolic links before
            // opening. Recheck the opened descriptor in case of a path change.
            var original = stat()
            guard Darwin.lstat(path, &original) == 0 else { throw Self.posixError() }
            guard original.st_mode & S_IFMT == S_IFREG else {
                throw NS58Error.invalid("Image input must be a regular file, not a device or symbolic link")
            }
            let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw Self.posixError() }
            var opened = stat()
            guard Darwin.fstat(descriptor, &opened) == 0 else {
                let error = Self.posixError()
                _ = Darwin.close(descriptor)
                throw error
            }
            guard opened.st_mode & S_IFMT == S_IFREG,
                  original.st_dev == opened.st_dev,
                  original.st_ino == opened.st_ino else {
                _ = Darwin.close(descriptor)
                throw NS58Error.invalid("Image input changed before it could be opened")
            }
            guard opened.st_size > 0, opened.st_size <= Int64(Self.maximumByteCount) else {
                _ = Darwin.close(descriptor)
                throw NS58Error.invalid("Image input must contain 1 to \(Self.maximumByteCount) bytes")
            }
            return (descriptor, Int(opened.st_size))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var snapshot = Data()
        while let chunk = try handle.read(upToCount: min(16 * 1024, expectedCount - snapshot.count + 1)),
              !chunk.isEmpty {
            guard chunk.count <= expectedCount - snapshot.count else {
                throw NS58Error.invalid("Image input grew while reading")
            }
            snapshot.append(chunk)
        }
        guard snapshot.count == expectedCount else {
            throw NS58Error.invalid("Image input shrank while reading")
        }
        bytes = snapshot
    }

    public enum PlanBaseline: Equatable, Sendable {
        case matching
        case tooShort(requiredBytes: Int)
        case rejected(reason: String)
    }

    /// An observation from the saved image only: neither a model identity
    /// check, nor authorization for live firmware writes.
    public struct Inspection: Equatable, Sendable {
        public let version: NS58VersionObservation
        public let baseline: PlanBaseline
    }

    public func inspect() throws -> Inspection {
        let version = try NS58VersionProbe.inspect(bytes)
        let baseline: PlanBaseline
        do {
            _ = try NS58FAT12.inspectBaseline(bytes)
            baseline = bytes.count >= Self.minimumPlanByteCount
                ? .matching : .tooShort(requiredBytes: Self.minimumPlanByteCount)
        } catch {
            baseline = .rejected(reason: String(describing: error))
        }
        return Inspection(version: version, baseline: baseline)
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
