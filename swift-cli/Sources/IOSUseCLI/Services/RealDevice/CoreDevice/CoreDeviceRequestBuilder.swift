import Foundation
import IOSUseProtocol

enum CoreDeviceRequestBuilder {
    static func make(
        featureIdentifier: String,
        input: [String: RemoteXPCValue] = [:],
        versionString: String = IOSUseProtocol.XCConstants.coreDeviceAppServiceVersion,
        uuidProvider: () -> String = { UUID().uuidString }
    ) -> [String: RemoteXPCValue] {
        let request: [String: RemoteXPCValue] = [
            "CoreDevice.CoreDeviceDDIProtocolVersion": .int64(
                IOSUseProtocol.XCConstants.coreDeviceDDIProtocolVersion
            ),
            "CoreDevice.action": .dictionary([:]),
            "CoreDevice.coreDeviceVersion": version(versionString),
            "CoreDevice.deviceIdentifier": .string(uuidProvider()),
            "CoreDevice.featureIdentifier": .string(featureIdentifier),
            "CoreDevice.input": .dictionary(input),
            "CoreDevice.invocationIdentifier": .string(uuidProvider()),
        ]
        return request
    }

    static func version(_ version: String) -> RemoteXPCValue {
        let components = version.split(separator: ".").map { UInt64($0) ?? 0 }
        return .dictionary([
            "components": .array(components.map { .uint64($0) }),
            "originalComponentsCount": .int64(Int64(components.count)),
            "stringValue": .string(version),
        ])
    }
}
