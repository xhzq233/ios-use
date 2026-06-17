public extension IOSUseProtocol {
    enum XCConstants {
        // MARK: Driver payload sentinels

        public static let coordinateElementTypeRawValue: Int32 = 1
        public static let swipeDirectionUnspecified: Int32 = -1
        public static let swipeDirectionForth: Int32 = 0
        public static let swipeDirectionBack: Int32 = 1
        public static let defaultAlertButtonIndex: Int32 = -1

        // MARK: Real-device XCTest lifecycle

        public static let minimumRealDeviceIOSMajorVersion = 17
        public static let xctestHolderRunLoopIntervalSeconds = 0.25
        public static let xctestHolderStartResultTimeoutSeconds = 10.0
        public static let xctestHolderStartPollMicroseconds = 100_000
        public static let xctestHolderControlListenBacklog: Int32 = 8
        public static let xctestHolderControlReadTimeoutSeconds = 5.0
        public static let xctestHolderControlReadPollSeconds = 0.05
        public static let xctestHolderStopRequestTimeoutSeconds = 5.0
        public static let xctestHolderStopWaitTimeoutSeconds = 10.0
        public static let xctestProcessTerminateWaitSeconds = 10.0
        public static let xctestProcessKillWaitSeconds = 2.0
        public static let xctestProcessExitPollMicroseconds = 100_000
        public static let xctestTunnelCloseTimeoutSeconds = 1.0
        public static let xctestRunnerConfigurationTimeoutSeconds = 20.0
        public static let xctestCallbackReadTimeoutSeconds = 1.0

        public static let xctestManagerDaemonRSDServiceName = "com.apple.dt.testmanagerd.remote"
        public static let xctestManagerIDEInterfaceIdentifier = "XCTestManager_IDEInterface"
        public static let xctestManagerDaemonConnectionIdentifier = "XCTestManager_DaemonConnectionInterface"
        public static let xctestManagerProtocolVersion = 36

        public static let xctestConfigurationFormatVersion = 2
        public static let xctestConfigurationFallbackTargetAppPath = "/tmp/XCTestTargetApp.app"
        public static let xctestAutomationFrameworkPath = "/Developer/Library/PrivateFrameworks/XCTAutomationSupport.framework"
        public static let xctestSystemAttachmentLifetime = 2
        public static let xctestUserAttachmentLifetime = 1
        public static let nsKeyedArchiveVersion = 100_000
        public static let nsKeyedArchiveMaxUID = 512

        // MARK: CoreDevice / RemoteXPC

        public static let lockdownPort = 62_078
        public static let lockdownRequestTimeoutSeconds = 5.0
        public static let lockdownMaxPlistSizeBytes = 10 * 1024 * 1024

        public static let coreDeviceProxyServiceName = "com.apple.internal.devicecompute.CoreDeviceProxy"
        public static let coreDeviceAppServiceName = "com.apple.coredevice.appservice"
        public static let coreDeviceOpenStdIOServiceName = "com.apple.coredevice.openstdiosocket"
        public static let coreDeviceAppServiceVersion = "325.3"
        public static let coreDeviceFeatureLaunchApplication = "com.apple.coredevice.feature.launchapplication"
        public static let coreDeviceFeatureListProcesses = "com.apple.coredevice.feature.listprocesses"
        public static let coreDeviceFeatureListProcessesTokensPath = "com.apple.coredevice.feature.listprocesses.processTokens"
        public static let coreDeviceFeatureSendSignalToProcess = "com.apple.coredevice.feature.sendsignaltoprocess"
        public static let coreDeviceDDIProtocolVersion: Int64 = 0
        public static let coreDeviceLaunchApplicationTimeoutSeconds = 30.0
        public static let coreDeviceRequestTimeoutSeconds = 10.0

        public static let remoteServiceDiscoveryPort = 58_783
        public static let remoteXPCDefaultHandshakeTimeoutSeconds = 3.0
        public static let remoteXPCDirectTunnelHandshakeTimeoutSeconds = 15.0
        public static let remoteXPCDefaultRequestTimeoutSeconds = 10.0
        public static let remoteXPCPeerInfoTimeoutSeconds = 10.0

        public static let coreDeviceTunnelRequestedMTU = 16_000
        public static let coreDeviceTunnelMaxPayloadSize = 64 * 1024
        public static let coreDeviceTunnelHandshakeTimeoutSeconds = 10.0
        public static let coreDeviceTunnelPacketReadTimeoutSeconds = 10.0
        public static let coreDeviceTunnelRouterReadTimeoutSeconds = 1.0
        public static let coreDeviceRoutePacketQueueLimit = 512
        public static let coreDeviceTunnelIPv6HeaderByteCount = 40
        public static let coreDeviceTunnelIPv6MaxPacketBytes = 256 * 1024
        public static let userspaceTCPLocalPortLowerBound: UInt16 = 49_152
        public static let userspaceTCPLocalPortUpperBound: UInt16 = 65_000
        public static let userspaceTCPDefaultMaxSegmentPayload = 1_200
        public static let userspaceTCPConnectTimeoutSeconds = 10.0
        public static let openStdIOIdentifierByteCount = 16
        public static let openStdIOIdentifierReadTimeoutSeconds = 10.0
        public static let openStdIODrainMaxBytes = 4_096
        public static let openStdIODrainReadTimeoutSeconds = 1.0
        public static let openStdIODrainIdleSleepMicroseconds = 50_000

        // MARK: Real-device usbmux / install transport

        public static let usbmuxSocketPath = "/var/run/usbmuxd"
        public static let usbmuxProgramName = "ios-use"
        public static let usbmuxClientVersion = "1.0"
        public static let usbmuxListDevicesMessageType = "ListDevices"
        public static let usbmuxConnectMessageType = "Connect"
        public static let usbmuxUSBConnectionType = "USB"
        public static let usbmuxFrameHeaderByteCount = 16
        public static let usbmuxProtocolVersion: UInt32 = 1
        public static let usbmuxPlistMessageType: UInt32 = 8
        public static let usbmuxListDevicesTag: UInt32 = 0
        public static let usbmuxConnectTag: UInt32 = 1
        public static let usbmuxReadTimeoutSeconds = 5.0
        public static let usbmuxMaxResponseBytes = 10 * 1024 * 1024
        public static let deviceStreamWriteChunkBytes = 1024 * 1024

        public static let afcServiceName = "com.apple.afc"
        public static let afcPacketMagic = "CFA6LPAA"
        public static let afcHeaderByteCount = 40
        public static let afcInitialWriteChunkSize = 512 * 1024
        public static let afcFallbackWriteChunkSize = 64 * 1024
        public static let afcFileOpenModeWriteOnly: UInt64 = 3
        public static let afcWriteRequestHeaderLength: UInt64 = 48
        public static let afcReadTimeoutSeconds = 30.0
        public static let afcMaxResponseBytes: UInt64 = 256 * 1024 * 1024

        public static let installationProxyServiceName = "com.apple.mobile.installation_proxy"
        public static let installationProxyFrameHeaderByteCount = 4
        public static let installationProxyDefaultTimeoutSeconds = 30.0
        public static let installationProxyProgressTimeoutSeconds = 120.0
        public static let installationProxyMaxResponseBytes = 100 * 1024 * 1024

        public static let localFDProxyListenBacklog: Int32 = 1
        public static let localFDProxyBridgeBufferBytes = 16 * 1024

        // MARK: DTX / Instruments

        public static let dvtInstrumentsRSDServiceName = "com.apple.instruments.dtservicehub"
        public static let dvtTerminationCallbackCapability = "com.apple.instruments.client.processcontrol.capability.terminationCallback"
        public static let dvtBlockCompressionCapability = "com.apple.private.DTXBlockCompression"
        public static let dvtConnectionCapability = "com.apple.private.DTXConnection"
    }
}
