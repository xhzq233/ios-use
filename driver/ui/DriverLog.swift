import os.log

enum DriverLog {
    static func info(_ message: String) {
        os_log("%{public}@", log: .default, type: .info, message)
    }

    static func error(_ message: String) {
        os_log("%{public}@", log: .default, type: .error, message)
    }
}
