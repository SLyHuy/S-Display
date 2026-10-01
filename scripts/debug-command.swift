#!/usr/bin/env swift
// Sends a command to a running Debug build of S-Display, then prints what it logged.
// Usage: swift scripts/debug-command.swift dump
//        swift scripts/debug-command.swift off 4 | on 4 | all-on | size 4 2560 | hidpi-install 4 | hidpi-remove 4

import Foundation

let command = CommandLine.arguments.dropFirst().joined(separator: " ")
guard !command.isEmpty else {
    print("usage: debug-command.swift dump | off <display> | on <display> | all-on | size <display> <width> | hidpi-install <display> | hidpi-remove <display>")
    exit(1)
}
let started = Date()
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.huyly.sdisplay.debug-command"), object: command, userInfo: nil, deliverImmediately: true
)

// Wait for the app's "dump done" line (the dump runs after the command finishes), then print the log.
let formatter = DateFormatter()
formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
let since = formatter.string(from: started.addingTimeInterval(-1))
let waitSeconds = Int(ProcessInfo.processInfo.environment["WAIT"] ?? "") ?? 60
for _ in 0 ..< waitSeconds {
    Thread.sleep(forTimeInterval: 1)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    process.arguments = ["show", "--info", "--style", "compact", "--start", since, "--predicate", "subsystem == \"com.huyly.sdisplay\""]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    if output.contains("dump done") {
        for line in output.split(separator: "\n") where line.contains("S-Display") {
            // Drop the timestamp/process prefix, keep the message.
            print(line.components(separatedBy: "] ").dropFirst().joined(separator: "] "))
        }
        exit(0)
    }
}
print("no answer after \(waitSeconds) s; is a Debug build of S-Display running?")
exit(1)
