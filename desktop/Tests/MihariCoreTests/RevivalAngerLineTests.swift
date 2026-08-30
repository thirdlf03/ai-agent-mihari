import Testing

@testable import MihariCore

@Suite("kill されて起こされたときの一言")
struct RevivalAngerLineTests {

    @Test("種を固定すれば同じ文句を返す")
    func randomIsDeterministicForFixedSeed() {
        var generatorA = SeededGenerator(seed: 42)
        var generatorB = SeededGenerator(seed: 42)

        let lineA = RevivalAngerLine.random(using: &generatorA)
        let lineB = RevivalAngerLine.random(using: &generatorB)

        #expect(lineA == lineB)
        #expect(RevivalAngerLine.pool.contains(lineA))
    }

    @Test("候補は空でない")
    func poolIsNotEmpty() {
        #expect(!RevivalAngerLine.pool.isEmpty)
    }
}
