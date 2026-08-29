import Foundation
import Testing

@testable import MihariCore

@Suite("セリフのキュー処理")
struct PetSpeechQueueTests {

    @Test("積んだ順に取り出せる")
    func dequeuesInOrder() {
        var queue = PetSpeechQueue()
        queue.enqueue("おはよう")
        queue.enqueue("戻ってきなよ")

        #expect(queue.dequeue() == "おはよう")
        #expect(queue.dequeue() == "戻ってきなよ")
        #expect(queue.dequeue() == nil)
    }

    @Test("空文字は積まない")
    func ignoresEmptyLine() {
        var queue = PetSpeechQueue()
        #expect(queue.enqueue("") == false)
        #expect(queue.isEmpty)
    }

    @Test("直前と全く同じセリフの連投は積まない")
    func dropsConsecutiveDuplicate() {
        var queue = PetSpeechQueue()
        #expect(queue.enqueue("戻ってきなよ") == true)
        #expect(queue.enqueue("戻ってきなよ") == false)
        #expect(queue.count == 1)
    }

    @Test("同じセリフでも間に別のセリフを挟めば積める")
    func allowsSameLineAfterAnother() {
        var queue = PetSpeechQueue()
        queue.enqueue("戻ってきなよ")
        queue.enqueue("聞いてる？")
        #expect(queue.enqueue("戻ってきなよ") == true)
        #expect(queue.count == 3)
    }

    @Test("上限を超えたら古いものから捨てる")
    func dropsOldestBeyondCapacity() {
        var queue = PetSpeechQueue()
        for index in 0..<(PetSpeechQueue.capacity + 2) {
            queue.enqueue("セリフ\(index)")
        }
        #expect(queue.count == PetSpeechQueue.capacity)
        #expect(queue.lines.first == "セリフ2")
        #expect(queue.lines.last == "セリフ\(PetSpeechQueue.capacity + 1)")
    }
}
