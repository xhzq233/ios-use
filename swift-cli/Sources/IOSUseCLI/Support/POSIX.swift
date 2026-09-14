#if os(Linux)
import Glibc
let posixStreamSocketType = Int32(SOCK_STREAM.rawValue)
let posixClose = Glibc.close
let posixWrite = Glibc.write
#else
import Darwin
let posixStreamSocketType = SOCK_STREAM
let posixClose = Darwin.close
let posixWrite = Darwin.write
#endif

func posixSocketWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    #if os(Linux)
    return Glibc.send(fd, buffer, count, Int32(MSG_NOSIGNAL))
    
#else
    return Darwin.write(fd, buffer, count)
    
#endif
}

/// Nonblocking connect keeps the same deadline on Darwin and Linux.
func posixConnect(
    _ fd: Int32, _ address: UnsafePointer<sockaddr>?, _ length: socklen_t,
    timeoutSeconds: Int
) -> Bool {
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
    defer { _ = fcntl(fd, F_SETFL, flags) }
    #if os(Linux)
    let result = Glibc.connect(fd, address, length)
    
#else
    let result = Darwin.connect(fd, address, length)
    
#endif
    if result == 0 { return true }
    guard errno == EINPROGRESS else { return false }
    var event = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    let ready = poll(&event, 1, Int32(timeoutSeconds * 1000))
    guard ready > 0 else {
        if ready == 0 { errno = ETIMEDOUT }
        return false
    }
    var socketError: Int32 = 0
    var size = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0 else { return false }
    if socketError != 0 { errno = socketError; return false }
    return true
}
