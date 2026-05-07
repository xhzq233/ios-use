import Foundation

enum ProbeCommands {
    static func probeFetch(_ rawArgs: AnyCodable?) throws -> ResponseFrame {
        let args = try decodeArgs(rawArgs, as: ProbeFetchArgs.self)
        guard let url = URL(string: args.url) else {
            throw DriverError.invalidArgs("invalid url: \(args.url)")
        }

        let timeout = max(1, min(args.timeout ?? 10, 30))
        NSLog("[probe] fetch start url=\(url.absoluteString) timeout=\(timeout)s")

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let sem = DispatchSemaphore(value: 0)
        var result: ResponseFrame?

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { sem.signal() }

            if let error {
                NSLog("[probe] fetch error url=\(url.absoluteString) error=\(error.localizedDescription)")
                result = Codec.makeError("probeFetch failed: \(error.localizedDescription)")
                return
            }

            guard let http = response as? HTTPURLResponse else {
                NSLog("[probe] fetch error url=\(url.absoluteString) error=non-http-response")
                result = Codec.makeError("probeFetch failed: non-http-response")
                return
            }

            let bodyBytes = data?.count ?? 0
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            let previewData = data?.prefix(120) ?? Data()
            let preview = String(data: previewData, encoding: .utf8)?
                .replacingOccurrences(of: "\n", with: "\\n")
                ?? "<non-utf8>"

            NSLog("[probe] fetch response url=\(url.absoluteString) status=\(http.statusCode) bytes=\(bodyBytes) contentType=\(contentType) preview=\(preview)")

            result = Codec.makeOK([
                "statusCode": http.statusCode,
                "bodyBytes": bodyBytes,
                "contentType": contentType,
            ])
        }

        task.resume()

        let waitResult = sem.wait(timeout: .now() + timeout + 5)
        if waitResult == .timedOut {
            task.cancel()
            NSLog("[probe] fetch timeout url=\(url.absoluteString)")
            return Codec.makeError("probeFetch timed out after \(timeout)s")
        }

        return result ?? Codec.makeError("probeFetch failed: no result")
    }
}
