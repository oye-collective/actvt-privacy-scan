//
//  main.swift
//  actvt-cli
//

import ActvtSessionsKit
import Foundation

let status = await CLIRunner.run(arguments: Array(CommandLine.arguments.dropFirst()))
exit(status.code)
