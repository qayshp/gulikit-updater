import Darwin
import Foundation
import NS58Core
import FirmwareDownload

@main
enum GuliKitCLI {
    static func main() async {
        do {
            try await run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run(_ arguments: [String]) async throws {
        guard let command = arguments.first else {
            printUsage()
            return
        }
        switch command {
        case "help", "--help", "-h":
            printUsage()
        case "verify":
            guard arguments.count == 2 else {
                throw NS58Error.invalid("usage: gulikit verify /path/to/NS58_Elves2_V3.7.bin")
            }
            let url = try regularFile(arguments[1])
            let firmware = try Data(contentsOf: url)
            try NS58FAT12.verifyFirmware(firmware, filename: url.lastPathComponent)
            print("Firmware: \(url.lastPathComponent)")
            print("Size: \(firmware.count) bytes")
            print("SHA-256: \(NS58FAT12.sha256(firmware))")
            print("Verified NS58 Elves 2 V3.7 firmware")
        case "download":
            guard arguments.count == 3, arguments[1] == "--directory" else {
                throw NS58Error.invalid("usage: gulikit download --directory /existing/output/directory")
            }
            let directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
            guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw NS58Error.invalid("download destination must be an existing directory")
            }
            print("Downloading supported NS58 V\(SupportedFirmware.version) from \(SupportedFirmware.downloadURL.host!)")
            let firmware = try await SupportedFirmware.download()
            let saved = try SupportedFirmware.saveVerified(firmware, in: directory)
            print("Saved: \(saved.path)")
            print("SHA-256: \(NS58FAT12.sha256(firmware))")
            print("Verified package and firmware; no device opened")
        case "plan":
            let options = try parsePlanOptions(Array(arguments.dropFirst()))
            let imageURL = try regularFile(options.image)
            let firmwareURL = try regularFile(options.firmware)
            let baseline = try Data(contentsOf: imageURL)
            let firmware = try Data(contentsOf: firmwareURL)
            let inspection = try NS58FAT12.inspectBaseline(baseline)
            let plan = try NS58FAT12.makeUpdatePlan(
                baseline: baseline,
                firmware: firmware,
                firmwareFilename: firmwareURL.lastPathComponent
            )
            print("Volume: \(inspection.volumeLabel)")
            print("Sector size: \(inspection.bytesPerSector) bytes")
            print("1. Firmware: LBA \(NS58Constants.firmwareStartLBA), \(NS58Constants.firmwareBlocks) blocks, \(plan.firmwarePayload.count) bytes")
            print("   SHA-256: \(NS58FAT12.sha256(plan.firmwarePayload))")
            print("2. FAT and root: LBA \(NS58Constants.metadataStartLBA), \(NS58Constants.metadataBlocks) blocks, \(plan.metadataPayload.count) bytes")
            print("   SHA-256: \(NS58FAT12.sha256(plan.metadataPayload))")
            print("Offline plan prepared; no device opened")
        default:
            throw NS58Error.invalid("unknown command \(command); run gulikit --help")
        }
    }

    private static func regularFile(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw NS58Error.invalid("input must be a regular file: \(url.path)")
        }
        return url
    }

    private static func parsePlanOptions(_ arguments: [String]) throws -> (image: String, firmware: String) {
        var options: [String: String] = [:]
        guard arguments.count == 4 else {
            throw NS58Error.invalid("usage: gulikit plan --image PATH --firmware PATH")
        }
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let name = arguments[index]
            guard ["--image", "--firmware"].contains(name), options[name] == nil else {
                throw NS58Error.invalid("unknown or repeated option: \(name)")
            }
            options[name] = arguments[index + 1]
        }
        guard let image = options["--image"], let firmware = options["--firmware"] else {
            throw NS58Error.invalid("both --image and --firmware are required")
        }
        return (image, firmware)
    }

    private static func printUsage() {
        print("""
        GuliKit offline firmware tools

        gulikit verify /path/to/NS58_Elves2_V3.7.bin
        gulikit download --directory /existing/output/directory
        gulikit plan --image /path/to/baseline.img --firmware /path/to/NS58_Elves2_V3.7.bin

        USB access and updating are provided by the GuliKitUpdater app.
        """)
    }
}
