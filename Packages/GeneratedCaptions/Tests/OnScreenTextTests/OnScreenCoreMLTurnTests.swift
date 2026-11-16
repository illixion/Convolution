import Foundation
import Testing
@testable import OnScreenText

@Suite struct OnScreenCoreMLTurnTests {
    /// Records how many bodies run at once, and in what order they ran.
    private actor Probe {
        var running = 0, most = 0
        var order: [Int] = []
        func enter(_ i: Int) { running += 1; most = max(most, running); order.append(i) }
        func leave() { running -= 1 }
    }

    @Test func runsOneBodyAtATime() async {
        let turn = OnScreenCoreMLTurn()
        let probe = Probe()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<12 {
                group.addTask {
                    await turn.run {
                        await probe.enter(i)
                        try? await Task.sleep(for: .milliseconds(5))
                        await probe.leave()
                    }
                }
            }
        }
        #expect(await probe.most == 1)
        #expect(await probe.order.count == 12)
    }

    /// A cancelled task still waits its turn: its prediction can't be
    /// stopped, so what comes after must not overlap it.
    @Test func aCancelledHolderStillFinishesBeforeTheNext() async {
        let turn = OnScreenCoreMLTurn()
        let probe = Probe()
        let first = Task {
            await turn.run {
                await probe.enter(0)
                // Not cancellable, like a Core ML prediction under way.
                let until = Date().addingTimeInterval(0.05)
                while Date() < until { await Task.yield() }
                await probe.leave()
            }
        }
        try? await Task.sleep(for: .milliseconds(10))
        first.cancel()
        await turn.run {
            await probe.enter(1)
            await probe.leave()
        }
        await first.value
        #expect(await probe.most == 1)
        #expect(await probe.order == [0, 1])
    }

    @Test func releasesWhenTheBodyThrows() async {
        let turn = OnScreenCoreMLTurn()
        struct Failure: Error {}
        _ = try? await turn.run { throw Failure() }
        let ran = await turn.run { true }
        #expect(ran)
    }
}
