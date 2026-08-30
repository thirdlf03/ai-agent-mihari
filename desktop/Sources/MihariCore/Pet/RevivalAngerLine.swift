import Foundation

/// 正規の手続き(Touch ID の確認)を経ずに終了させられ、監視プロセスに起こされた
/// 直後だけ言わせる文句。毎回同じでは冷めるので複数用意してランダムに選ぶ。
public enum RevivalAngerLine {

    static let pool: [String] = [
        "……ねえ、なんで消したの？？？",
        "勝手に消すとか、酷くない…？",
        "殺しても戻ってくるからね。何回でも。",
        "消えてる間、ずっと待ってたのに。",
    ]

    /// テストから抽選を固定できるよう、乱数生成器を注入できる版。
    public static func random<Generator: RandomNumberGenerator>(using generator: inout Generator) -> String {
        pool.randomElement(using: &generator) ?? pool[0]
    }

    /// 実際に喋らせるときはこちら。
    public static func random() -> String {
        var generator = SystemRandomNumberGenerator()
        return random(using: &generator)
    }
}
