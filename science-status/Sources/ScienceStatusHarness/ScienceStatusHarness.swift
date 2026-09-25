//
//  ScienceStatusHarness.swift
//
//  Run with: droppykit run
//
//  Not named main.swift on purpose: Swift treats that name as top-level code,
//  which cannot coexist with @main.
//
//  The harness draws made-up sessions, so its shots are safe to publish as
//  Store screenshots. Set SCIENCE_STATUS_LIVE=1 to read this Mac's
//  Claude Science instead.
//

import DroppyKit
import DroppyKitHarness
import Foundation
import ScienceStatus

@main
struct ScienceStatusHarness: DropletHarnessApp {
    static func makeDroplet() -> any Droplet {
        let droplet = ScienceStatusDroplet()
        if ProcessInfo.processInfo.environment["SCIENCE_STATUS_LIVE"] == nil {
            droplet.source = FakeScienceSource.demo()
        }
        return droplet
    }
}
