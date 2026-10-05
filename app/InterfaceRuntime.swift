import AppKit
import Foundation

func makeInterfaceRefreshTimer(_ refresh: @escaping () -> Void) -> Timer {
    let timer = Timer(timeInterval: 0.25, repeats: true) { _ in refresh() }
    timer.tolerance = 0.025
    RunLoop.main.add(timer, forMode: .common)
    return timer
}

final class InterfaceInstanceLock {
    let acquired: Bool
    private var descriptor: Int32 = -1
    init(path: String) throws {
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw appError("Не удалось открыть блокировку интерфейса") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            close(fd); throw appError("Небезопасный файл блокировки интерфейса")
        }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { descriptor = fd; acquired = true }
        else {
            let failure = errno; close(fd)
            guard failure == EWOULDBLOCK else { throw appError("Не удалось заблокировать интерфейс") }
            acquired = false
        }
    }
    deinit { if descriptor >= 0 { close(descriptor) } }
}

let showInterfaceNotification = Notification.Name("local.matvey.RUWiFi.ShowInterface")
let interfaceShownNotification = Notification.Name("local.matvey.RUWiFi.InterfaceShown")

func acquireInterface(path: String, background: Bool) throws -> InterfaceInstanceLock? {
    let instance = try InterfaceInstanceLock(path: path)
    if instance.acquired { return instance }
    if background { return nil }
    let center = DistributedNotificationCenter.default(), request = UUID().uuidString
    var acknowledged = false
    let observer = center.addObserver(forName: interfaceShownNotification, object: request, queue: .main) { _ in acknowledged = true }
    defer { center.removeObserver(observer) }
    let deadline = Date().addingTimeInterval(2)
    repeat {
        center.postNotificationName(showInterfaceNotification, object: path, userInfo: ["reply": request], deliverImmediately: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        if acknowledged { return nil }
        // The owner may have exited between our open request and activation.
        let retry = try InterfaceInstanceLock(path: path)
        if retry.acquired { return retry }
    } while Date() < deadline
    throw appError("Интерфейс уже запущен, но не ответил. Повторите открытие приложения.")
}
