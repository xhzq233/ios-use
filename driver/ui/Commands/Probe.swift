import Foundation
import Fory

enum ProbeCommands {
    private static func describeError(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain)(\(nsError.code)): \(nsError.localizedDescription)"
    }

    static func probeFetch(_ args: ForyProbeFetchArgs) throws -> ForyResponseFrame {
        guard let url = URL(string: args.url) else {
            throw DriverError.invalidArgs("invalid url: \(args.url)")
        }

        let timeout = max(1, min(args.timeout > 0 ? args.timeout : 10, 30))
        NSLog("[probe] fetch start url=\(url.absoluteString) timeout=\(timeout)s")

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)

        let sem = DispatchSemaphore(value: 0)
        var result: ForyResponseFrame?

        let task = session.dataTask(with: request) { data, response, error in
            defer { sem.signal() }

            if let error {
                let message = describeError(error)
                NSLog("[probe] fetch error url=\(url.absoluteString) error=\(message)")
                result = Codec.foryError("probeFetch failed: \(message)")
                return
            }

            guard let http = response as? HTTPURLResponse else {
                NSLog("[probe] fetch error url=\(url.absoluteString) error=non-http-response")
                result = Codec.foryError("probeFetch failed: non-http-response")
                return
            }

            let bodyBytes = data?.count ?? 0
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            let previewData = data?.prefix(120) ?? Data()
            let preview = String(data: previewData, encoding: .utf8)?
                .replacingOccurrences(of: "\n", with: "\\n")
                ?? "<non-utf8>"

            NSLog("[probe] fetch response url=\(url.absoluteString) status=\(http.statusCode) bytes=\(bodyBytes) contentType=\(contentType) preview=\(preview)")

            let payload = ForyProbePayload(
                statusCode: Int32(http.statusCode),
                bodyBytes: Int32(bodyBytes),
                contentType: contentType
            )
            result = (try? Codec.foryOK(payload)) ?? Codec.foryError("probeFetch: serialization failed")
        }

        task.resume()

        let waitResult = sem.wait(timeout: .now() + timeout + 5)
        if waitResult == .timedOut {
            task.cancel()
            session.invalidateAndCancel()
            NSLog("[probe] fetch timeout url=\(url.absoluteString)")
            return Codec.foryError("probeFetch timed out after \(timeout)s")
        }

        session.finishTasksAndInvalidate()
        return result ?? Codec.foryError("probeFetch failed: no result")
    }
}
