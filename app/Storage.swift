import Foundation
import Darwin

func appError(_ text: String) -> NSError { NSError(domain: "RUWiFi", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }

private func directoryFD(_ path: String) throws -> Int32 {
    let components = path.split(separator: "/").map(String.init)
    guard path.hasPrefix("/"), !components.contains("..") else { throw appError("Недопустимый путь") }
    var fd = open("/", O_RDONLY | O_DIRECTORY)
    guard fd >= 0 else { throw appError("Не удалось открыть корневой каталог") }
    do {
        for name in components {
            let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw appError("Недоступный или небезопасный каталог: \(name)") }
            close(fd); fd = next
        }
        return fd
    } catch { close(fd); throw error }
}

func checkedRead(_ path: String, owner: uid_t, limit: Int = 1_048_576) throws -> Data {
    guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw appError("Недопустимый путь") }
    let url = URL(fileURLWithPath: path)
    let parent = try directoryFD(url.deletingLastPathComponent().path); defer { close(parent) }
    let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { throw appError("Файл недоступен: \(url.lastPathComponent)") }; defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == owner,
          info.st_mode & 0o022 == 0, info.st_size >= 0, info.st_size <= limit else { throw appError("Небезопасный файл: \(url.lastPathComponent)") }
    var result = Data(), buffer = [UInt8](repeating: 0, count: 16384)
    while true {
        let count = read(fd, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        guard count >= 0 else { throw appError("Не удалось прочитать файл") }
        if count == 0 { break }
        result.append(contentsOf: buffer.prefix(count))
        guard result.count <= limit else { throw appError("Файл слишком большой") }
    }
    return result
}

func durableWrite(_ data: Data, to path: String, mode: mode_t = 0o600) throws {
    let url = URL(fileURLWithPath: path)
    let parent = try directoryFD(url.deletingLastPathComponent().path); defer { close(parent) }
    var old = stat()
    if fstatat(parent, url.lastPathComponent, &old, AT_SYMLINK_NOFOLLOW) == 0 {
        guard old.st_mode & S_IFMT == S_IFREG, old.st_uid == getuid() else { throw appError("Небезопасная цель записи: \(url.lastPathComponent)") }
    } else if errno != ENOENT { throw appError("Не удалось проверить файл перед записью") }
    let temporary = ".ruwifi-" + UUID().uuidString
    let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
    guard fd >= 0 else { throw appError("Не удалось создать временный файл") }
    defer { close(fd); unlinkat(parent, temporary, 0) }
    guard fchmod(fd, mode) == 0 else { throw appError("Не удалось установить права файла") }
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let size = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if size < 0 && errno == EINTR { continue }
            guard size > 0 else { throw appError("Ошибка записи") }; offset += size
        }
    }
    guard fsync(fd) == 0, renameat(parent, temporary, parent, url.lastPathComponent) == 0 else { throw appError("Ошибка сохранения файла") }
    _ = fsync(parent)
}

func writeJSON<T: Encodable>(_ value: T, _ path: String, mode: mode_t = 0o600) throws {
    try durableWrite(JSONEncoder().encode(value), to: path, mode: mode)
}
func optionalFile(_ path: String) throws -> Data? {
    var info = stat()
    if lstat(path, &info) != 0 {
        if errno == ENOENT { return nil }; throw appError("Не удалось проверить \(path)")
    }
    return try checkedRead(path, owner: getuid())
}
func removeOwnedFile(_ path: String) throws {
    let url = URL(fileURLWithPath: path), parent = try directoryFD(URL(fileURLWithPath: path).deletingLastPathComponent().path)
    defer { close(parent) }
    var info = stat()
    if fstatat(parent, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) != 0 {
        if errno == ENOENT { return }; throw appError("Не удалось проверить файл для удаления")
    }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), unlinkat(parent, url.lastPathComponent, 0) == 0 else { throw appError("Не удалось удалить принадлежащий приложению файл") }
    _ = fsync(parent)
}
struct OwnedFileRecord: Codable { var original: Data?; var installed: Data; var mode: UInt16 }
final class OwnedFile {
    let path: String; let journal: String
    init(_ path: String, journal: String) { self.path = path; self.journal = journal }
    func apply(_ data: Data) throws {
        let current = try optionalFile(path)
        let record: OwnedFileRecord
        if let saved = try optionalFile(journal) {
            record = try JSONDecoder().decode(OwnedFileRecord.self, from: saved)
            guard current == record.installed || current == record.original else { throw appError("Настройки изменены вне приложения: \(path)") }
            guard record.installed == data else { throw appError("Сначала восстановите прежние настройки") }
        } else {
            var info = stat(); let mode: UInt16 = lstat(path, &info) == 0 ? UInt16(info.st_mode & 0o777) : 0o644
            record = OwnedFileRecord(original: current, installed: data, mode: mode)
            try writeJSON(record, journal)
        }
        if current != data { try durableWrite(data, to: path, mode: 0o644) }
    }
    func restore() throws {
        guard let saved = try optionalFile(journal) else { return }
        let record = try JSONDecoder().decode(OwnedFileRecord.self, from: saved)
        let current = try optionalFile(path)
        if current == record.original { try removeOwnedFile(journal); return }
        guard restorationDecision(current: current, installed: record.installed) == .restore else { throw appError("Сохранены внешние изменения: \(path)") }
        if let original = record.original { try durableWrite(original, to: path, mode: mode_t(record.mode)) }
        else { try removeOwnedFile(path) }
        try removeOwnedFile(journal)
    }
}

func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 8) throws -> String {
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "HOME": NSHomeDirectory()]
    process.standardOutput = output; process.standardError = output
    defer { try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close() }
    try process.run()
    let fd = output.fileHandleForReading.fileDescriptor
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
    while true {
        let count = read(fd, &buffer, buffer.count)
        if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
        else if !process.isRunning { break }
        if data.count > 2_097_152 || ProcessInfo.processInfo.systemUptime > deadline {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }; process.waitUntilExit()
            throw appError("Превышено время или размер ответа: \(URL(fileURLWithPath: executable).lastPathComponent)")
        }
        if count <= 0 { Thread.sleep(forTimeInterval: 0.01) }
    }
    process.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else { throw appError(String(text.prefix(600)).isEmpty ? "Команда завершилась с ошибкой" : String(text.prefix(600))) }
    return text
}

struct FileSnapshot {
    let path: String
    let data: Data?
    let mode: mode_t
    init(_ path: String) throws {
        self.path = path
        var info = stat()
        if lstat(path, &info) == 0 {
            data = try checkedRead(path, owner: getuid(), limit: 268_435_456)
            mode = info.st_mode & 0o777
        } else {
            guard errno == ENOENT else { throw appError("Не удалось сохранить предыдущую установку") }
            data = nil; mode = 0o600
        }
    }
    func restore() throws {
        if let data { try durableWrite(data, to: path, mode: mode) }
        else { try removeOwnedFile(path) }
    }
}

func ensureDirectory(_ path: String, mode: mode_t = 0o755) throws {
    var info = stat()
    if lstat(path, &info) == 0 {
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else { throw appError("Небезопасный каталог: \(path)") }
    } else {
        guard errno == ENOENT, mkdir(path, mode) == 0 else { throw appError("Не удалось создать каталог \(path)") }
    }
    let descriptor = try directoryFD(path); defer { close(descriptor) }
    guard fchmod(descriptor, mode) == 0 else { throw appError("Не удалось установить права каталога") }
}
