import Foundation
import IOSUseProtocol

enum CoreDeviceDisplayInfoError: Error, CustomStringConvertible, Equatable {
    case missingOutput
    case invalidDisplays

    var description: String {
        switch self {
        case .missingOutput:
            return "CoreDevice deviceinfo response is missing CoreDevice.output"
        case .invalidDisplays:
            return "CoreDevice deviceinfo response has no usable displays"
        }
    }
}

struct CoreDeviceDisplayInfo: Codable, Equatable {
    struct Display: Codable, Equatable {
        let displayID: Int?
        let name: String?
        let primary: Bool
        let pointScale: Double?
        /// `[x, y, width, height]` in device pixels when supplied by CoreDevice.
        let bounds: [Double]?
        /// `[width, height]` in native device pixels when supplied by CoreDevice.
        let nativeSize: [Double]?
        let currentOrientation: String?
        let nativeOrientation: String?

        var pixelSize: [Double]? {
            if let nativeSize, nativeSize.count == 2,
               nativeSize[0] > 0, nativeSize[1] > 0 {
                return nativeSize
            }
            if let bounds, bounds.count == 4,
               bounds[2] > 0, bounds[3] > 0 {
                return [bounds[2], bounds[3]]
            }
            return nil
        }
    }

    let displays: [Display]
    let currentDeviceOrientation: String?
    let currentDeviceNonFlatOrientation: String?
    let orientationLocked: Bool?
    let backlightState: String?

    var primaryDisplay: Display? {
        displays.first(where: \.primary) ?? displays.first
    }
}

final class CoreDeviceDisplayInfoService {
    static let serviceName = IOSUseProtocol.XCConstants.coreDeviceDeviceInfoServiceName

    private let client: RemoteXPCClient
    private let uuidProvider: () -> String

    init(client: RemoteXPCClient, uuidProvider: @escaping () -> String = { UUID().uuidString }) {
        self.client = client
        self.uuidProvider = uuidProvider
    }

    func close() {
        client.close()
    }

    func getDisplayInfo() throws -> CoreDeviceDisplayInfo {
        let request = CoreDeviceRequestBuilder.make(
            featureIdentifier: IOSUseProtocol.XCConstants.coreDeviceFeatureGetDisplayInfo,
            versionString: IOSUseProtocol.XCConstants.coreDeviceAppServiceVersion,
            uuidProvider: uuidProvider
        )
        let response = try client.sendReceiveRequest(
            request,
            timeoutSeconds: IOSUseProtocol.XCConstants.coreDeviceDisplayInfoTimeoutSeconds
        )
        guard let output = response.dictionaryValue?["CoreDevice.output"] else {
            throw CoreDeviceDisplayInfoError.missingOutput
        }
        return try Self.decode(output)
    }

    static func decode(_ output: RemoteXPCValue) throws -> CoreDeviceDisplayInfo {
        guard let root = output.dictionaryValue,
              let displaysValue = root["displays"],
              case .array(let rawDisplays) = displaysValue else {
            throw CoreDeviceDisplayInfoError.invalidDisplays
        }

        let displays = rawDisplays.compactMap { value -> CoreDeviceDisplayInfo.Display? in
            guard let display = value.dictionaryValue else { return nil }
            return CoreDeviceDisplayInfo.Display(
                displayID: display["displayId"]?.intValue,
                name: display["name"]?.stringValue,
                primary: display["primary"]?.boolValue ?? false,
                pointScale: display["pointScale"]?.doubleValue,
                bounds: rect(display["bounds"]),
                nativeSize: pair(display["nativeSize"]),
                currentOrientation: display["currentOrientation"]?.stringValue,
                nativeOrientation: display["nativeOrientation"]?.stringValue
            )
        }
        guard !displays.isEmpty else {
            throw CoreDeviceDisplayInfoError.invalidDisplays
        }

        let orientation = root["orientation"]?.dictionaryValue
        return CoreDeviceDisplayInfo(
            displays: displays,
            currentDeviceOrientation: orientation?["currentDeviceOrientation"]?.stringValue,
            currentDeviceNonFlatOrientation: orientation?["currentDeviceNonFlatOrientation"]?.stringValue,
            orientationLocked: orientation?["currentDeviceOrientationLocked"]?.boolValue,
            backlightState: root["backlightState"]?.stringValue
        )
    }

    private static func pair(_ value: RemoteXPCValue?) -> [Double]? {
        guard let value, case .array(let values) = value, values.count == 2,
              let first = values[0].doubleValue,
              let second = values[1].doubleValue else {
            return nil
        }
        return [first, second]
    }

    private static func rect(_ value: RemoteXPCValue?) -> [Double]? {
        guard let value, case .array(let values) = value else { return nil }
        if values.count == 4,
           let x = values[0].doubleValue,
           let y = values[1].doubleValue,
           let width = values[2].doubleValue,
           let height = values[3].doubleValue {
            return [x, y, width, height]
        }
        guard values.count == 2,
              let origin = pair(values[0]),
              let size = pair(values[1]) else {
            return nil
        }
        return [origin[0], origin[1], size[0], size[1]]
    }
}
