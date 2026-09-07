import Foundation

/// ペットのメニューから呼ぶアプリ全体の操作。
///
/// メニュー（`PetMenuEntries`）はこの protocol と `PetController` だけを知っていればよく、
/// 監視・在席・休憩・設定画面の実体を知らなくてよい。アプリ側の取りまとめ役が適合する。
@MainActor
public protocol PetMenuActions: AnyObject, ObservableObject {
    /// 監視中か。メニューの表示を「監視を止める / 監視を再開する」で切り替えるのに使う。
    var isWatching: Bool { get }
    /// 休憩中か。メニューの表示を「休憩する / 休憩を終える」で切り替えるのに使う。
    var isOnBreak: Bool { get }
    /// 状態パネルを出しているか。メニューのチェックに使う。
    var isStatusPanelVisible: Bool { get }
    /// スクショに写り込むか。メニューのチェックに使う。
    var isPhotobombEnabled: Bool { get }
    /// いまの音声モード。デバッグメニューのチェックに使う。
    var voiceMode: VoiceMode { get }
    /// 集中継続を褒める間隔(秒)。デバッグメニューのチェックに使う。
    var focusStreakIntervalSeconds: TimeInterval { get }
    /// 検知の閾値が短縮(`DetectionThresholds.fast`)か。デバッグメニューのチェックに使う。
    var isFastThresholds: Bool { get }

    /// 監視を始める。
    func startWatching()
    /// 監視を止める。
    func stopWatching()
    /// 在席スタンプ（Touch ID）を押す。
    func stampAttendance()
    /// 休憩を始める。
    func startBreak()
    /// 休憩を終える。
    func endBreak()
    /// Discord 設定の画面を開く。
    func openDiscordSettings()
    /// 仕事の依頼窓を開く。
    func openJobRequest()
    /// 作業部屋でいま追っている仕事。無ければ `nil`。
    var roomJob: RoomJobSummary? { get }
    /// 走っている仕事へ追記する窓を開く。
    func followUpRoomJob()
    /// 仕事の詳細パネル(記憶の候補・成果物)を開く。
    func openRoomJobDetail()
    /// 走っている仕事を中断する。
    func cancelRoomJob()
    /// 成果物の URL を開く。http/https だけを開く。
    func openRoomArtifact(_ url: URL)
    /// 記憶の候補を承認する。
    func approveRoomMemory(candidateID: String)
    /// 記憶の候補を却下する。
    func rejectRoomMemory(candidateID: String)
    /// 静的プレビューを指定バージョンに戻す。
    func rollbackRoomArtifact(version: String)
    /// 権限の確認画面を開く。
    func openPermissions()
    /// 状態パネルの表示を切り替える。
    func toggleStatusPanel()
    /// スクショへの写り込みを入れる / 切る。
    func setPhotobombEnabled(_ enabled: Bool)
    /// 音声モードを切り替える。再起動なしで効く。
    func setVoiceMode(_ mode: VoiceMode)
    /// 集中継続を褒める間隔を変える。
    func setFocusStreakInterval(_ seconds: TimeInterval)
    /// 検知の閾値を標準 / 短縮で切り替える。次の評価から新しい秒数で動く。
    func setFastThresholds(_ enabled: Bool)
    /// 集中継続のセリフをその場で喋らせる(デバッグ用)。
    func replayFocusStreak()
    /// 検知エンジンを実際に次の段へ進める(デバッグ用)。
    /// 見た目だけの再現と違い、**本物の撮影・投稿が走る。**
    func runDetectionStep(_ step: DetectionDebugStep)
}
