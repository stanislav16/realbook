import Foundation

/// RealBook's Python server, which does the reading of books and the voices. It runs as long as this
/// app does: it ends when its stdin closes, however the app ends.
@MainActor
final class Engine {
    private var process: Process?
    private let toEngine = Pipe()

    /// Starts it and waits until it says which port it took.
    func start() async throws -> URL {
        let process = Process()
        if let dev = ProcessInfo.processInfo.environment["REALBOOK_ENGINE"] {  // while developing: the checkout's
            process.executableURL = URL(fileURLWithPath: dev)
        } else {
            process.executableURL = Bundle.main.resourceURL!.appendingPathComponent("engine/RealBook")
            process.arguments = ["--engine"]
        }
        let fromEngine = Pipe()
        process.standardOutput = fromEngine
        process.standardInput = toEngine
        try process.run()
        self.process = process
        let handle = fromEngine.fileHandleForReading
        let port = try await Task.detached { () -> Int in
            var line = Data()
            while true {
                let byte = handle.readData(ofLength: 1)
                if byte.isEmpty { throw AppError("The voice engine didn't start.") }
                if byte.first == 10 { break }
                line.append(byte)
            }
            struct Hello: Decodable { var port: Int }
            return try JSONDecoder().decode(Hello.self, from: line).port
        }.value
        handle.readabilityHandler = { _ = $0.availableData }  // anything more it says shouldn't fill the pipe
        return URL(string: "http://127.0.0.1:\(port)")!
    }
}

struct AppError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
