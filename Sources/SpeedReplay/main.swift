import Foundation
import SpeedCore

func run() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    if args == ["--benchmark"] { try runBenchmark(); return }
    guard let path = args.first, args.count <= 2, args.count == 1 || args[1] == "--mounted" else {
        FileHandle.standardError.write(Data("Usage: speed-replay INPUT.jsonl [--mounted] | --benchmark\nOutputs one estimate per input event as JSONL.\n".utf8))
        exit(64)
    }
    var replay = SpeedReplay(mode: args.contains("--mounted") ? .mounted : .handheld)
    let data = try String(contentsOfFile: path, encoding: .utf8)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    for (index, line) in data.split(separator: "\n").enumerated() {
        do {
            let event = try ReplayEvent.decode(Data(line.utf8))
            let output = try replay.consume(event)
            FileHandle.standardOutput.write(try encoder.encode(output))
            FileHandle.standardOutput.write(Data([10]))
        } catch {
            FileHandle.standardError.write(Data("Line \(index + 1): \(error)\n".utf8))
            exit(65)
        }
    }
}
do { try run() } catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
