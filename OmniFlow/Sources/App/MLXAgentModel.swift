import Foundation
import CryptoKit

/// Qualified snapshot: only safetensors and declarative tokenizer/configuration files.
enum MLXAgentModel {
    static let revision = "1454cffb1a21737e162f508e5bc70be9def89276"
    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "OmniFlow/Models/GLM-4.7-Flash-4bit")
    }
    static let manifest: [String: String] = [
        "chat_template.jinja": "d63ad536c3c81880043e22ec7fd08db42b4d8fb7c89c7138bc562bfa25281375",
        "config.json": "e105c6e474c01bbb07a8b307cdb1b1c32ab66bb18eaad28104326186731da1cf",
        "generation_config.json": "e19f4eb8be12cdb62a3737b52a332c7c142cbf5ee24a5de7d806f6132b782425",
        "model-00001-of-00004.safetensors": "540741ab088c32f7338636c82c601399c0db6c11c965ac2c2865e9400d32dd8b",
        "model-00002-of-00004.safetensors": "28749aa10a019ffa2a68e12a94c3883e5102942b310937667bb359221a4d4a8d",
        "model-00003-of-00004.safetensors": "5c6896cb4c209344aac52eb9784d34145bf752aa99653d480d211f8261d5449b",
        "model-00004-of-00004.safetensors": "48361cae86bb6d78ac246a1a23ec92e863eef276e9bc285ec6a7cbb5f8bc0f07",
        "model.safetensors.index.json": "f32b02d7114cf3c83a3d5b2094144f4d5f8a22501fb83981e2eb303e0f2209f5",
        "tokenizer.json": "ad47af68eb0dfcc868258957578831a793a15858b88e2f8325d644fc77f4fb1c",
        "tokenizer_config.json": "c8ee8927ebec39b93edf7333e7ded950299c643a569a601bb7bac9dc94d1f648",
    ]

    static func verify(_ directory: URL, manifest: [String: String] = manifest) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { throw MetalAgentError.modelMissing }
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let loadable = Set(files.filter { ["safetensors", "json", "jinja"].contains($0.pathExtension) }.map(\.lastPathComponent))
        guard loadable == Set(manifest.keys) else { throw MetalAgentError.unverifiedModel }
        for (name, expected) in manifest.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            let handle = try FileHandle(forReadingFrom: directory.appendingPathComponent(name))
            defer { try? handle.close() }
            var digest = SHA256()
            while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                digest.update(data: chunk)
            }
            let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw MetalAgentError.unverifiedModel }
        }
    }
}
