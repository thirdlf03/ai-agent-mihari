import Foundation

/// ペットメニューの「デバッグ」サブメニューの並び。
///
/// 検知が起きるのを待たなくても、状態・アニメーション・セリフをその場で起こして見た目を確かめられる。
/// 「検知の状態を再現」は `LivePetPresenter.present(_:)` に偽の `PetEvent` を流すだけなので、
/// 検知エンジン・撮影・Discord への送信はどれも動かない。
///
/// **「実際に進める」だけは別物。** 検知エンジンに直接投げるので、本物の遷移・撮影・投稿が走る。
public enum PetDebugMenuEntries {

    /// 「検知の閾値」に並べる選択肢。`DetectionThresholds` の preset をまるごと差し替える。
    public static let thresholdPresets: [(title: String, isFast: Bool)] = [
        ("標準(疑い 60 秒 / 段ごと 30 秒)", false),
        ("短縮(疑い 15 秒 / 段ごと 10 秒・デモ用)", true),
    ]

    /// 「集中継続の間隔」に並べる選択肢。本来の 15 分と、動かして確かめるための 1 分。
    public static let focusStreakIntervals: [(title: String, seconds: TimeInterval)] = [
        ("15 分", 900),
        ("1 分", 60),
    ]

    /// デバッグメニューの並びを組み立てる。呼ぶたびに、そのときの状態でチェックを決める。
    @MainActor
    public static func make<Actions: PetMenuActions>(
        actions: Actions,
        presenter: LivePetPresenter
    ) -> [PetMenuEntry] {
        let pet = presenter.controller
        return [
            .submenu(
                title: "検知の状態を再現",
                entries: detectionStateEntries(presenter: presenter)
            ),
            .submenu(
                title: "実際に進める(撮影・投稿あり)",
                entries: DetectionDebugStep.allCases.map { step -> PetMenuEntry in
                    .item(title: step.title, action: { actions.runDetectionStep(step) })
                }
            ),
            .submenu(
                title: "アニメーションを固定",
                entries: fixedAnimationEntries(pet: pet)
            ),
            .submenu(
                title: "1 回だけ再生",
                entries: PetAnimation.allCases.map { animation -> PetMenuEntry in
                    .item(
                        title: "\(animation.rawValue)(\(animation.debugLabel))",
                        action: { pet.playOnce(animation) }
                    )
                }
            ),
            .separator,
            .submenu(
                title: "音声",
                entries: VoiceMode.allCases.map { mode -> PetMenuEntry in
                    .item(
                        title: mode.label,
                        isChecked: actions.voiceMode == mode,
                        action: { actions.setVoiceMode(mode) }
                    )
                }
            ),
            .submenu(
                title: "検知の閾値",
                entries: thresholdPresets.map { choice -> PetMenuEntry in
                    .item(
                        title: choice.title,
                        isChecked: actions.isFastThresholds == choice.isFast,
                        action: { actions.setFastThresholds(choice.isFast) }
                    )
                }
            ),
            .submenu(
                title: "集中継続の間隔",
                entries: focusStreakIntervals.map { choice -> PetMenuEntry in
                    .item(
                        title: choice.title,
                        isChecked: actions.focusStreakIntervalSeconds == choice.seconds,
                        action: { actions.setFocusStreakInterval(choice.seconds) }
                    )
                }
            ),
            .item(
                title: "集中継続のセリフを再現",
                action: { actions.replayFocusStreak() }
            ),
            .separator,
            .item(
                title: "ひとりごとを喋る(声あり)",
                action: { pet.say("デバッグのテストです。聞こえていますか?") }
            ),
        ]
    }

    /// 「検知の状態を再現」の中身。偽の `PetEvent` を presenter に流して、ペットの見た目だけを動かす。
    @MainActor
    private static func detectionStateEntries(presenter: LivePetPresenter) -> [PetMenuEntry] {
        [
            .item(
                title: "正常に戻す",
                isChecked: presenter.state == .normal,
                action: {
                    presenter.present(PetEvent(state: .normal, escalationStage: 0, line: ""))
                }
            ),
            .item(
                title: "疑い 1(Touch ID)",
                isChecked: presenter.state == .suspected,
                action: {
                    presenter.present(
                        PetEvent(state: .suspected, escalationStage: 1, line: "指、出して。")
                    )
                }
            ),
            .item(
                title: "疑い 2(首振り)",
                isChecked: presenter.state == .suspected,
                action: {
                    presenter.present(
                        PetEvent(state: .suspected, escalationStage: 2, line: "ねぇ、まだそこにいる?")
                    )
                }
            ),
            .item(
                title: "疑い 3(最終警告)",
                isChecked: presenter.state == .suspected,
                action: {
                    presenter.present(
                        PetEvent(state: .suspected, escalationStage: 3, line: "これで最後だからね。")
                    )
                }
            ),
            .item(
                title: "晒し",
                isChecked: presenter.state == .confirmed,
                action: {
                    presenter.present(
                        PetEvent(
                            state: .confirmed,
                            escalationStage: PetEvent.exposingStage,
                            line: "撮りました。Discord に送ります。"
                        )
                    )
                }
            ),
            .item(
                title: "メンヘラ",
                isChecked: presenter.state == .confirmed,
                action: {
                    presenter.present(
                        PetEvent(
                            state: .confirmed,
                            escalationStage: PetEvent.clingyStage,
                            line: "ねぇ、まだ戻ってこないの?"
                        )
                    )
                }
            ),
            .separator,
            .item(
                title: "問いかけ(はい / いいえ)",
                action: {
                    // 回答が届いたことが分かるよう、押されたボタンを吹き出しに出すだけの問いかけにする。
                    let prompt = PetYesNoPrompt(question: "ねぇ、まだそこにいる?") { [weak presenter] answer in
                        Task { @MainActor in
                            presenter?.controller.say(
                                answer ? "「はい」を受け取りました" : "「いいえ」を受け取りました",
                                voiced: false
                            )
                        }
                    }
                    presenter.present(
                        PetEvent(state: .suspected, escalationStage: 1, line: "", prompt: prompt)
                    )
                }
            ),
            .item(
                title: "問いかけを閉じる",
                action: { presenter.dismissPrompt() }
            ),
        ]
    }

    /// 「アニメーションを固定」の中身。固定を解く項目を先頭に置き、9 種を定義順に並べる。
    @MainActor
    private static func fixedAnimationEntries(pet: PetController) -> [PetMenuEntry] {
        var entries: [PetMenuEntry] = [
            .item(
                title: "固定しない(自律行動)",
                isChecked: pet.fixedAnimation == nil,
                action: { pet.setFixedAnimation(nil) }
            ),
            .separator,
        ]
        entries += PetAnimation.allCases.map { animation -> PetMenuEntry in
            .item(
                title: "\(animation.rawValue)(\(animation.debugLabel))",
                isChecked: pet.fixedAnimation == animation,
                action: { pet.setFixedAnimation(animation) }
            )
        }
        return entries
    }
}

extension PetAnimation {
    /// デバッグメニューに出す日本語の説明。項目名は `rawValue` と組にして出す。
    var debugLabel: String {
        switch self {
        case .idle: return "待機"
        case .runningRight: return "右へ歩く"
        case .runningLeft: return "左へ歩く"
        case .waving: return "手を振る"
        case .jumping: return "跳ねる"
        case .failed: return "落ち込む"
        case .waiting: return "待つ"
        case .running: return "集中"
        case .review: return "確認"
        }
    }
}
