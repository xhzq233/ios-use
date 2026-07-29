import Foundation
import XCTest

final class MediaTests: XCTestCase {
    override func tearDown() {
        MediaCommands.resetTestingHooks()
        super.tearDown()
    }

    func testAllowedImportSkipsAuthorizationAndPrompt() throws {
        let library = FakeMediaPhotoLibrary(status: .allowed)
        let prompt = FakePhotosPromptHandler()
        MediaCommands.photoLibraryFactoryForTesting = { library }
        MediaCommands.promptHandlerForTesting = prompt

        let response = try execute(args: photoArgs())
        let payload = try ForyRegistry.create().deserialize(
            response.payload,
            as: ForyMediaImportPayload.self
        )

        XCTAssertTrue(response.ok)
        XCTAssertEqual(library.requestCount, 0)
        XCTAssertEqual(prompt.handleCount, 0)
        XCTAssertEqual(library.createCount, 1)
        XCTAssertEqual(payload.assetLocalIdentifier, "asset-1")
        XCTAssertFalse(payload.permissionPromptHandled)
    }

    func testDeniedImportFailsWithoutRequestPromptOrMutation() throws {
        let library = FakeMediaPhotoLibrary(status: .denied)
        let prompt = FakePhotosPromptHandler()
        MediaCommands.photoLibraryFactoryForTesting = { library }
        MediaCommands.promptHandlerForTesting = prompt

        let response = try execute(args: photoArgs())
        let error = try errorPayload(response)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(error.category, IOSUseErrorCategory.authorization)
        XCTAssertEqual(error.code, IOSUseErrorCode.photosAddPermissionDenied)
        XCTAssertEqual(error.phase, IOSUseErrorPhase.authorization)
        XCTAssertEqual(library.requestCount, 0)
        XCTAssertEqual(prompt.handleCount, 0)
        XCTAssertEqual(library.createCount, 0)
    }

    func testRestrictedImportFailsWithoutRequestPromptOrMutation() throws {
        let library = FakeMediaPhotoLibrary(status: .restricted)
        let prompt = FakePhotosPromptHandler()
        MediaCommands.photoLibraryFactoryForTesting = { library }
        MediaCommands.promptHandlerForTesting = prompt

        let response = try execute(args: photoArgs())
        let error = try errorPayload(response)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(error.category, IOSUseErrorCategory.authorization)
        XCTAssertEqual(error.code, IOSUseErrorCode.photosAddPermissionRestricted)
        XCTAssertEqual(error.phase, IOSUseErrorPhase.authorization)
        XCTAssertEqual(library.requestCount, 0)
        XCTAssertEqual(prompt.handleCount, 0)
        XCTAssertEqual(library.createCount, 0)
    }

    func testNotDeterminedRequestsOnceHandlesPromptAndImports() throws {
        let library = FakeMediaPhotoLibrary(status: .notDetermined)
        let prompt = FakePhotosPromptHandler()
        prompt.handler = { trigger, completion in
            trigger()
            library.completeAuthorization(.allowed)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                completion(.handled(text: "Photos", button: "Allow"))
            }
        }
        MediaCommands.photoLibraryFactoryForTesting = { library }
        MediaCommands.promptHandlerForTesting = prompt

        let response = try execute(args: photoArgs())
        let payload = try ForyRegistry.create().deserialize(
            response.payload,
            as: ForyMediaImportPayload.self
        )

        XCTAssertTrue(response.ok)
        XCTAssertEqual(library.requestCount, 1)
        XCTAssertEqual(prompt.handleCount, 1)
        XCTAssertEqual(library.createCount, 1)
        XCTAssertTrue(payload.permissionPromptHandled)
    }

    func testNotDeterminedExternalAuthorizationReportsPromptNotHandled() throws {
        let library = FakeMediaPhotoLibrary(status: .notDetermined)
        let prompt = FakePhotosPromptHandler()
        prompt.handler = { _, completion in
            library.completeAuthorization(.allowed)
            completion(.notHandled)
        }
        MediaCommands.photoLibraryFactoryForTesting = { library }
        MediaCommands.promptHandlerForTesting = prompt

        let response = try execute(args: photoArgs())
        let payload = try ForyRegistry.create().deserialize(
            response.payload,
            as: ForyMediaImportPayload.self
        )

        XCTAssertTrue(response.ok)
        XCTAssertEqual(library.requestCount, 0)
        XCTAssertEqual(prompt.handleCount, 1)
        XCTAssertEqual(library.createCount, 1)
        XCTAssertFalse(payload.permissionPromptHandled)
    }

    func testUnsafeFirstPromptReturnsInteractionRequiredWithoutImport() throws {
        let library = FakeMediaPhotoLibrary(status: .notDetermined)
        let prompt = FakePhotosPromptHandler()
        prompt.handler = { trigger, completion in
            trigger()
            completion(.interactionRequired(
                code: IOSUseErrorCode.alertAmbiguous,
                diagnostic: "buttons were ambiguous",
                alert: ForyAlertPayload(
                    surface: "springboard",
                    kind: "alert",
                    buttonCount: 2,
                    requestedSelection: "visualPrimary",
                    reason: "buttons were ambiguous"
                )
            ))
        }
        MediaCommands.photoLibraryFactoryForTesting = { library }
        MediaCommands.promptHandlerForTesting = prompt

        let response = try execute(args: photoArgs())
        let error = try errorPayload(response)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(error.category, IOSUseErrorCategory.authorization)
        XCTAssertEqual(error.code, IOSUseErrorCode.alertAmbiguous)
        XCTAssertEqual(error.alert?.buttonCount, 2)
        XCTAssertTrue(response.error.contains("buttons were ambiguous"))
        XCTAssertEqual(library.requestCount, 1)
        XCTAssertEqual(library.createCount, 0)
    }

    func testPreexistingAlertPreventsAuthorizationRequestAndImport() throws {
        let library = FakeMediaPhotoLibrary(status: .notDetermined)
        let prompt = FakePhotosPromptHandler()
        prompt.handler = { _, completion in
            completion(.interactionRequired(
                code: IOSUseErrorCode.preexistingAlert,
                diagnostic: "pre-existing alert",
                alert: ForyAlertPayload(
                    surface: "springboard",
                    kind: "alert",
                    buttonCount: 1,
                    requestedSelection: "visualPrimary",
                    reason: "pre-existing alert"
                )
            ))
        }
        MediaCommands.photoLibraryFactoryForTesting = { library }
        MediaCommands.promptHandlerForTesting = prompt

        let response = try execute(args: photoArgs())
        let error = try errorPayload(response)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(error.code, IOSUseErrorCode.preexistingAlert)
        XCTAssertEqual(error.alert?.reason, "pre-existing alert")
        XCTAssertEqual(library.requestCount, 0)
        XCTAssertEqual(library.createCount, 0)
    }

    func testHandledPromptStillFailsWhenAuthorizationBecomesDenied() throws {
        let library = FakeMediaPhotoLibrary(status: .notDetermined)
        let prompt = FakePhotosPromptHandler()
        prompt.handler = { trigger, completion in
            trigger()
            library.completeAuthorization(.denied)
            completion(.handled(text: "permission", button: "primary"))
        }
        MediaCommands.photoLibraryFactoryForTesting = { library }
        MediaCommands.promptHandlerForTesting = prompt

        let response = try execute(args: photoArgs())
        let error = try errorPayload(response)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(error.code, IOSUseErrorCode.photosAddPermissionDenied)
        XCTAssertEqual(library.requestCount, 1)
        XCTAssertEqual(library.createCount, 0)
    }

    func testMediaKindMustMatchUniformType() throws {
        let library = FakeMediaPhotoLibrary(status: .allowed)
        MediaCommands.photoLibraryFactoryForTesting = { library }
        let args = ForyMediaImportArgs(
            kind: "video",
            originalFilename: "fixture.png",
            uniformTypeIdentifier: "public.png",
            byteCount: 3,
            data: Data([1, 2, 3])
        )

        let response = try execute(args: args)
        let error = try errorPayload(response)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(error.code, IOSUseErrorCode.unsupportedMediaType)
        XCTAssertEqual(library.createCount, 0)
    }

    private func photoArgs() -> ForyMediaImportArgs {
        ForyMediaImportArgs(
            kind: "photo",
            originalFilename: "fixture.png",
            uniformTypeIdentifier: "public.png",
            byteCount: 3,
            data: Data([1, 2, 3])
        )
    }

    private func execute(args: ForyMediaImportArgs) throws -> ForyResponseFrame {
        let completion = XCTestExpectation(description: "media command completed")
        let lock = NSLock()
        var result: Result<ForyResponseFrame, Error>?
        DispatchQueue.global().async {
            do {
                let response = try MediaCommands.importMedia(args)
                lock.lock()
                result = .success(response)
                lock.unlock()
            } catch {
                lock.lock()
                result = .failure(error)
                lock.unlock()
            }
            completion.fulfill()
        }
        wait(for: [completion], timeout: 2)
        lock.lock()
        let captured = result
        lock.unlock()
        return try XCTUnwrap(captured).get()
    }

    private func errorPayload(_ response: ForyResponseFrame) throws -> ForyErrorPayload {
        try ForyRegistry.create().deserialize(response.payload, as: ForyErrorPayload.self)
    }
}

private final class FakeMediaPhotoLibrary: MediaPhotoLibrary {
    private(set) var status: MediaPhotoAuthorizationStatus
    private(set) var requestCount = 0
    private(set) var createCount = 0
    private var authorizationCompletion: ((MediaPhotoAuthorizationStatus) -> Void)?

    init(status: MediaPhotoAuthorizationStatus) {
        self.status = status
    }

    func authorizationStatus() -> MediaPhotoAuthorizationStatus {
        status
    }

    func requestAuthorization(_ completion: @escaping (MediaPhotoAuthorizationStatus) -> Void) {
        requestCount += 1
        authorizationCompletion = completion
    }

    func completeAuthorization(_ status: MediaPhotoAuthorizationStatus) {
        self.status = status
        authorizationCompletion?(status)
        authorizationCompletion = nil
    }

    func supports(kind: String) -> Bool {
        kind == "photo" || kind == "video"
    }

    func createAsset(
        args: ForyMediaImportArgs,
        completion: @escaping (String?, String?) -> Void
    ) {
        createCount += 1
        completion("asset-\(createCount)", nil)
    }
}

private final class FakePhotosPromptHandler: PhotosPermissionPromptHandling {
    var handler: ((
        _ trigger: @escaping () -> Void,
        _ completion: @escaping (PhotosPermissionPromptOutcome) -> Void
    ) -> Void)?
    private(set) var handleCount = 0

    func handle(
        deadline: Date,
        canTrigger: @escaping () -> Bool,
        trigger: @escaping () -> Void,
        shouldStop: @escaping () -> Bool,
        completion: @escaping (PhotosPermissionPromptOutcome) -> Void
    ) {
        handleCount += 1
        guard canTrigger() else {
            completion(.notHandled)
            return
        }
        handler?(trigger, completion)
    }
}
