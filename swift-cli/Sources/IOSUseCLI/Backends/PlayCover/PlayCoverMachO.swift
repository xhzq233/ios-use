import Foundation
import PlayCoverUpstream

/// IOSUseCLI facade over the pinned PlayCover Macho.swift and inject sources.
///
/// Conversion and injection intentionally live in the auditable upstream
/// package. This file only maps its evidence model into the CLI model.
public enum PlayCoverMachO {
    public static let platformIPhoneOS: UInt32 = 2
    public static let platformMacCatalyst: UInt32 =
        PlayCoverUpstreamEngine.platformMacCatalyst
    public static let runtimeLoadPath =
        "@executable_path/Frameworks/IOSUsePlayRuntime.framework/IOSUsePlayRuntime"

    public static func isThinArm64MachO(at url: URL) throws -> Bool {
        do {
            return try PlayCoverUpstreamEngine.inspectMachO(
                at: url,
                relativePath: url.lastPathComponent
            ).container == .thin
        } catch let error as PlayCoverUpstreamError {
            switch error {
            case .unsupportedMachO:
                return false
            default:
                throw map(error)
            }
        }
    }

    public static func inspect(
        at url: URL,
        injectedRuntimePath: String = runtimeLoadPath
    ) throws -> PlayCoverMachOInspection {
        do {
            let upstream = try PlayCoverUpstreamEngine.inspectMachO(
                at: url,
                relativePath: url.lastPathComponent
            )
            return PlayCoverMachOInspection(
                upstream,
                appPath: url.deletingLastPathComponent().path
            )
        } catch let error as PlayCoverUpstreamError {
            throw map(error)
        }
    }

    @discardableResult
    public static func convert(
        at url: URL,
        injectRuntime: Bool,
        injectedRuntimePath: String = runtimeLoadPath
    ) throws -> PlayCoverMachOInspection {
        do {
            let upstream = try PlayCoverUpstreamEngine.convertMachO(
                at: url,
                relativePath: url.lastPathComponent,
                injectRuntime: injectRuntime,
                runtimeLoadPath: injectedRuntimePath
            )
            return PlayCoverMachOInspection(
                upstream,
                appPath: url.deletingLastPathComponent().path
            )
        } catch let error as PlayCoverUpstreamError {
            throw map(error)
        }
    }

    static func map(_ error: PlayCoverUpstreamError) -> PlayCoverBackendError {
        switch error {
        case .invalidApp(let message):
            return .invalidApp(message)
        case .malformedMachO(let message):
            return .malformedMachO(message)
        case .unsupportedMachO(let message):
            return .unsupportedMachO(message)
        case .encryptedMachO(let path):
            return .encryptedMachO(path)
        case .duplicateRuntimeLoad(let path):
            return .duplicateRuntimeLoad(path)
        case .insufficientMachOPadding(let message):
            return .unsupportedMachO(message)
        case .injectionFailed(let message):
            return .machOTransformFailed(message)
        case .entitlementFailed(let message):
            return .entitlementFailed(message)
        case .signingFailed(let message):
            return .codeSigningFailed(message)
        case .commandFailed(let message):
            return .prepareFailed(message)
        case .verificationFailed(let message):
            return .verificationFailed(message)
        case .sourceMutated(let expected, let actual):
            return .prepareFailed(
                "source mutated: expected \(expected), got \(actual)"
            )
        }
    }
}
