import Foundation

/// Entry point of the `markio` command.
exit(Tool.run(arguments: Array(CommandLine.arguments.dropFirst()), io: .standard))
