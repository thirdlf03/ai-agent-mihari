import AppKit
import SwiftUI

/// ペットの表示倍率。メニューに並べる 3 段階。
enum PetScale: CGFloat, CaseIterable, Identifiable {
    case small = 0.5
    case medium = 0.75
    case large = 1.0

    var id: CGFloat { rawValue }

    /// メニューに出す表示名。
    var label: String {
        switch self {
        case .small: return "小"
        case .medium: return "中"
        case .large: return "大"
        }
    }
}

/// デスクトップペットの表示状態とふるまいをまとめて管理する。
@Observable
@MainActor
final class PetController {
    /// 選択できるペットの一覧。同梱ペットとユーザーのカスタムペットを含む。
    private(set) var pets: [PetDefinition]
    /// いま表示しているペット。
    private(set) var currentPet: PetDefinition?
    /// いま表示すべきコマ。
    private(set) var currentFrame: CGImage?
    /// 再生中のアニメーション。
    private(set) var animation: PetAnimation = .idle
    /// ペットを画面に出しているか。
    private(set) var isAwake: Bool
    /// 表示倍率。セルサイズにこれを掛けたものがウィンドウの大きさになる。
    private(set) var scale: CGFloat
    /// 外部から与えられたステータス。nil のときは自律行動する。
    private(set) var status: PetStatus?
    /// いま吹き出しに出しているセリフ。非 nil のあいだ吹き出しを表示する。
    private(set) var speechText: String?
    /// スプライトシートの読み込みに失敗したときの理由。
    private(set) var loadErrorMessage: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var atlas: PetAtlas?
    @ObservationIgnored private var window: PetWindow?
    @ObservationIgnored private var speechWindow: PetSpeechWindow?
    @ObservationIgnored private var speechLines: PetSpeechLines = .builtIn
    @ObservationIgnored private var speechTimer: Timer?
    @ObservationIgnored private var lastSpeechAt: Date?
    @ObservationIgnored private var lastSpokenStatus: PetStatus?
    @ObservationIgnored private var frameIndex = 0
    @ObservationIgnored private var frameTimer: Timer?
    @ObservationIgnored private var gesture: PetAnimation?
    @ObservationIgnored private var autonomy: Autonomy = .idle
    @ObservationIgnored private var idleDeadline: Date?
    @ObservationIgnored private var isDragging = false
    @ObservationIgnored private var dragMotion: DragMotion = .still
    @ObservationIgnored private var lastDragMoveAt: Date?
    @ObservationIgnored private var hasAppliedLaunchState = false

    /// ステータス指定が無いときの自律行動。
    private enum Autonomy {
        /// その場で待機している。
        case idle
        /// 左右へ歩いている。`remaining` は残りの移動距離(pt)。
        case walking(towardRight: Bool, remaining: CGFloat)
        /// review を 1 周だけ再生している。
        case reviewing
    }

    /// ドラッグでウィンドウを動かしている向き。
    private enum DragMotion {
        /// 動かしていない。
        case still
        /// 右へ動かしている。
        case right
        /// 左へ動かしている。
        case left
    }

    private enum DefaultsKey {
        static let petID = "pet.selectedPetID"
        static let isAwake = "pet.isAwake"
        static let scale = "pet.scale"
        static let originX = "pet.originX"
        static let originY = "pet.originY"
    }

    /// 歩く速さ(pt/秒)。
    private static let walkSpeed: CGFloat = 60
    /// 1 回の歩行距離の範囲(pt)。
    private static let walkDistanceRange: ClosedRange<CGFloat> = 80...240
    /// idle のまま待つ時間の範囲(秒)。
    private static let idleDurationRange: ClosedRange<TimeInterval> = 4...10
    /// idle のあとに review を選ぶ確率。
    private static let reviewProbability = 0.3
    /// 画面の端からあける余白(pt)。
    private static let screenMargin: CGFloat = 24
    /// ドラッグで動いたと見なす x の変化量(pt)。
    private static let dragMoveThreshold: CGFloat = 1
    /// 最後に動かしてから走りを続ける時間(秒)。
    private static let dragMotionTimeout: TimeInterval = 0.2
    /// セリフ 1 文字あたりの表示時間(秒)。
    private static let speechSecondsPerCharacter: TimeInterval = 0.08
    /// 文字数によらず確保する表示時間(秒)。
    private static let speechBaseSeconds: TimeInterval = 1.5
    /// セリフの表示時間の下限と上限(秒)。
    private static let speechDurationRange: ClosedRange<TimeInterval> = 2...6
    /// ドラッグを始めたときにセリフを言う確率。
    private static let dragSpeechProbability = 0.3
    /// 待機に入ったときにひとりごとを言う確率。
    private static let idleSpeechProbability = 0.2
    /// ひとりごとを言うために空けておく、直前のセリフからの間隔(秒)。
    private static let idleSpeechInterval: TimeInterval = 20

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let pets = PetLibrary.availablePets()
        self.pets = pets
        self.currentPet = PetLibrary.pet(id: defaults.string(forKey: DefaultsKey.petID), in: pets)
        self.isAwake = defaults.object(forKey: DefaultsKey.isAwake) as? Bool ?? true
        self.scale = Self.restoredScale(from: defaults)
        self.speechLines = PetSpeechLines.load(from: self.currentPet?.speechURL)
    }

    // MARK: - 表示

    /// 起動時に一度だけ呼ぶ。前回しまわれていなければペットを出し直す。
    func applyLaunchState() {
        guard !hasAppliedLaunchState else { return }
        hasAppliedLaunchState = true
        guard isAwake else { return }
        showWindow()
    }

    /// ペットを表示する。
    func wake() {
        guard !isAwake else { return }
        isAwake = true
        defaults.set(true, forKey: DefaultsKey.isAwake)
        showWindow()
        say(.wake)
    }

    /// ペットをしまう。
    func tuckAway() {
        guard isAwake else { return }
        isAwake = false
        defaults.set(false, forKey: DefaultsKey.isAwake)
        hideWindow()
    }

    /// 表示・非表示を切り替える。
    func toggle() {
        if isAwake {
            tuckAway()
        } else {
            wake()
        }
    }

    /// 表示するペットを切り替える。セリフもそのペットのものに読み替える。
    func select(pet: PetDefinition) {
        guard pet.id != currentPet?.id else { return }
        currentPet = pet
        defaults.set(pet.id, forKey: DefaultsKey.petID)
        atlas = nil
        speechLines = PetSpeechLines.load(from: pet.speechURL)
        loadAtlasIfNeeded()
        restartAnimation()
    }

    /// 表示倍率を変える。ウィンドウは左下を保ったまま拡縮する。
    func setScale(_ newScale: CGFloat) {
        guard newScale != scale else { return }
        scale = newScale
        defaults.set(Double(newScale), forKey: DefaultsKey.scale)

        guard let window else { return }
        window.setContentSize(contentSize)
        if let bounds = Self.visibleFrame(for: window) {
            window.setFrameOrigin(Self.clamp(origin: window.frame.origin, size: window.frame.size, in: bounds))
        }
        persistOrigin()
        // 子ウィンドウは移動には追従するが、ペットの大きさが変わったときは置き直す。
        speechWindow?.reposition(above: window)
    }

    /// メインウィンドウを前面に出す。
    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }

    // MARK: - ステータス

    /// 外部ステータスを設定する。`ready` は 1 周だけ再生してから自動で解除される。
    func setStatus(_ newStatus: PetStatus) {
        gesture = nil
        // 同じステータスが続けて来たときは言い直さない。
        if newStatus != lastSpokenStatus {
            lastSpokenStatus = newStatus
            say(newStatus.speechKind)
        }
        // アニメーションを止めている間は 1 周分を再生できないので、一度きりのステータスはその場で解除する。
        status = (isReduceMotionEnabled && newStatus.isMomentary) ? nil : newStatus
        if status == nil {
            beginIdle()
        }
        restartAnimation()
    }

    /// 外部ステータスを解除し、自律行動に戻す。
    func clearStatus() {
        lastSpokenStatus = nil
        guard status != nil else { return }
        status = nil
        beginIdle()
        restartAnimation()
    }

    // MARK: - 操作

    /// クリックに応じて手を振り、挨拶する。
    func wave() {
        say(.greeting)
        playOnce(.waving)
    }

    /// ダブルクリックに応じて跳ねる。
    func jump() {
        playOnce(.jumping)
    }

    /// ドラッグ開始。動かしている間は自律歩行を止める。
    func beginDrag() {
        isDragging = true
        dragMotion = .still
        lastDragMoveAt = nil
        gesture = nil
        if status == nil {
            beginIdle()
        }
        // 毎回だとうるさいので、たまにだけ声を出す。
        if Double.random(in: 0..<1) < Self.dragSpeechProbability {
            say(.dragging)
        }
        restartAnimation()
    }

    /// ドラッグ中にウィンドウを動かす。画面の外へは出さない。
    func moveWindow(to origin: CGPoint) {
        guard let window else { return }
        let previousX = window.frame.origin.x
        if let bounds = Self.visibleFrame(containing: origin) ?? Self.visibleFrame(for: window) {
            window.setFrameOrigin(Self.clamp(origin: origin, size: window.frame.size, in: bounds))
        } else {
            window.setFrameOrigin(origin)
        }
        updateDragMotion(from: previousX, to: window.frame.origin.x)
    }

    /// ドラッグ終了。位置を保存し、元の状態へ戻す。
    func endDrag() {
        isDragging = false
        dragMotion = .still
        lastDragMoveAt = nil
        persistOrigin()
        restartAnimation()
    }

    /// 実際に動いた x の差分から向きを更新する。動いていなければ何もしない。
    private func updateDragMotion(from previousX: CGFloat, to currentX: CGFloat) {
        let delta = currentX - previousX
        if delta > Self.dragMoveThreshold {
            dragMotion = .right
        } else if delta < -Self.dragMoveThreshold {
            dragMotion = .left
        } else {
            return
        }
        lastDragMoveAt = Date()
        applyAnimationChange()
    }

    /// 現在のウィンドウ原点(スクリーン座標の左下)。
    var windowOrigin: CGPoint {
        window?.frame.origin ?? .zero
    }

    // MARK: - セリフ

    /// 指定したセリフを吹き出しに出す。表示中のセリフは差し替えて、時間を計り直す。
    func say(_ text: String, duration: TimeInterval = 3) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAwake, !line.isEmpty, let window else { return }

        speechText = line
        lastSpeechAt = Date()

        let panel = speechWindow ?? PetSpeechWindow()
        speechWindow = panel
        // 「視差効果を減らす」ときは吹き出し自体は出し、フェードだけ省く。
        panel.show(text: line, above: window, animated: !isReduceMotionEnabled)
        scheduleSpeechTimer(duration: duration)
    }

    /// 種類に応じたセリフをランダムに 1 つ選んで言う。候補が無ければ何もしない。
    func say(_ kind: PetSpeechLines.Kind) {
        guard let line = speechLines.randomLine(for: kind) else { return }
        say(line, duration: Self.speechDuration(for: line))
    }

    /// 待機に入ったときのひとりごと。うるさくならないよう確率と間隔で絞る。
    private func sayIdleLineIfNeeded() {
        guard isAwake else { return }
        if let lastSpeechAt, Date().timeIntervalSince(lastSpeechAt) < Self.idleSpeechInterval { return }
        guard Double.random(in: 0..<1) < Self.idleSpeechProbability else { return }
        say(.idle)
    }

    /// 吹き出しを消す。
    private func endSpeech() {
        speechTimer?.invalidate()
        speechTimer = nil
        guard speechText != nil else { return }
        speechText = nil
        speechWindow?.hide(animated: !isReduceMotionEnabled)
    }

    /// 表示時間が過ぎたら吹き出しを消すタイマーを張り直す。
    private func scheduleSpeechTimer(duration: TimeInterval) {
        speechTimer?.invalidate()
        let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.endSpeech()
            }
        }
        // メニュー操作中などでも消えるよう common モードで回す。
        RunLoop.main.add(timer, forMode: .common)
        speechTimer = timer
    }

    /// 文字数から表示時間を決める。短すぎ・長すぎにならないよう幅を決めておく。
    private static func speechDuration(for text: String) -> TimeInterval {
        let estimated = Double(text.count) * speechSecondsPerCharacter + speechBaseSeconds
        return min(max(estimated, speechDurationRange.lowerBound), speechDurationRange.upperBound)
    }

    // MARK: - ウィンドウ

    /// 表示倍率を反映したウィンドウの中身の大きさ。
    private var contentSize: CGSize {
        CGSize(
            width: PetSpriteGrid.cellSize.width * scale,
            height: PetSpriteGrid.cellSize.height * scale
        )
    }

    private func showWindow() {
        loadAtlasIfNeeded()

        let panel = window ?? PetWindow(controller: self)
        window = panel
        panel.setContentSize(contentSize)
        panel.setFrameOrigin(restoredOrigin(size: panel.frame.size))
        panel.orderFrontRegardless()

        gesture = nil
        beginIdle()
        restartAnimation()
    }

    private func hideWindow() {
        frameTimer?.invalidate()
        frameTimer = nil
        endSpeech()
        window?.orderOut(nil)
    }

    /// アトラスが未読み込みなら読み込む。失敗しても表示自体は続ける。
    private func loadAtlasIfNeeded() {
        guard atlas == nil, let currentPet else { return }
        do {
            atlas = try PetAtlas(definition: currentPet)
            loadErrorMessage = nil
        } catch {
            atlas = nil
            loadErrorMessage = error.localizedDescription
        }
    }

    /// 保存された位置を復元する。どの画面にも収まらなければ visibleFrame の右下に置く。
    private func restoredOrigin(size: CGSize) -> CGPoint {
        if let stored = storedOrigin(),
            let screen = NSScreen.screens.first(where: {
                $0.visibleFrame.intersects(CGRect(origin: stored, size: size))
            })
        {
            return Self.clamp(origin: stored, size: size, in: screen.visibleFrame)
        }

        let bounds = NSScreen.main?.visibleFrame ?? .zero
        return CGPoint(
            x: bounds.maxX - size.width - Self.screenMargin,
            y: bounds.minY + Self.screenMargin
        )
    }

    private func storedOrigin() -> CGPoint? {
        guard let x = defaults.object(forKey: DefaultsKey.originX) as? Double,
            let y = defaults.object(forKey: DefaultsKey.originY) as? Double
        else {
            return nil
        }
        return CGPoint(x: x, y: y)
    }

    private func persistOrigin() {
        guard let window else { return }
        defaults.set(Double(window.frame.origin.x), forKey: DefaultsKey.originX)
        defaults.set(Double(window.frame.origin.y), forKey: DefaultsKey.originY)
    }

    private static func restoredScale(from defaults: UserDefaults) -> CGFloat {
        guard let stored = defaults.object(forKey: DefaultsKey.scale) as? Double,
            let matched = PetScale(rawValue: CGFloat(stored))
        else {
            return PetScale.small.rawValue
        }
        return matched.rawValue
    }

    private static func clamp(origin: CGPoint, size: CGSize, in bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(origin.x, bounds.minX), max(bounds.maxX - size.width, bounds.minX)),
            y: min(max(origin.y, bounds.minY), max(bounds.maxY - size.height, bounds.minY))
        )
    }

    private static func visibleFrame(for window: NSWindow) -> CGRect? {
        window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
    }

    private static func visibleFrame(containing point: CGPoint) -> CGRect? {
        NSScreen.screens.first { $0.frame.contains(point) }?.visibleFrame
    }

    // MARK: - アニメーション

    /// システムの「視差効果を減らす」設定。true の間は静止画にして自律歩行もしない。
    private var isReduceMotionEnabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// いま再生すべきアニメーション。ドラッグ中 > クリック操作 > 外部ステータス > 自律行動 の順に優先する。
    private var intendedAnimation: PetAnimation {
        if isDragging { return draggingAnimation }
        if let gesture { return gesture }
        if let status { return status.animation }
        switch autonomy {
        case .idle: return .idle
        case .walking(let towardRight, _): return towardRight ? .runningRight : .runningLeft
        case .reviewing: return .review
        }
    }

    /// ドラッグ中に再生するアニメーション。動かした向きへ走り、手が止まると待機に戻る。
    private var draggingAnimation: PetAnimation {
        guard let lastDragMoveAt, Date().timeIntervalSince(lastDragMoveAt) <= Self.dragMotionTimeout else {
            return .idle
        }
        switch dragMotion {
        case .still: return .idle
        case .right: return .runningRight
        case .left: return .runningLeft
        }
    }

    /// 望ましいアニメーションへ即座に切り替える。変わらないときはコマ送りをそのまま続ける。
    private func applyAnimationChange() {
        let previous = animation
        refreshAnimation()
        guard animation != previous else { return }
        updateCurrentFrame()
        scheduleFrameTimer()
    }

    /// 一度きりのアニメーションを割り込ませる。1 周したら元の状態へ戻る。
    private func playOnce(_ animation: PetAnimation) {
        guard isAwake, !isReduceMotionEnabled else { return }
        gesture = animation
        restartAnimation()
    }

    /// 望ましいアニメーションをコマ 0 から再生し直す。
    private func restartAnimation() {
        animation = intendedAnimation
        frameIndex = 0
        updateCurrentFrame()
        scheduleFrameTimer()
    }

    /// 望ましいアニメーションと再生中のものが違えば、コマ 0 から切り替える。
    private func refreshAnimation() {
        let next = intendedAnimation
        guard next != animation else { return }
        animation = next
        frameIndex = 0
    }

    private func updateCurrentFrame() {
        guard let atlas else {
            currentFrame = nil
            return
        }
        currentFrame = isReduceMotionEnabled ? atlas.frame(.idle, at: 0) : atlas.frame(animation, at: frameIndex)
    }

    /// いま表示しているコマの表示時間が過ぎたら `tick` を呼ぶタイマーを張り直す。
    private func scheduleFrameTimer() {
        frameTimer?.invalidate()
        frameTimer = nil
        guard isAwake, !isReduceMotionEnabled else { return }

        let duration = animation.frameDurations[min(frameIndex, animation.frameCount - 1)]
        let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick(elapsed: duration)
            }
        }
        // メニュー操作中などでもコマ送りが止まらないよう common モードで回す。
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    /// コマを 1 つ進める。歩行の移動や一度きりの再生の終了もここで処理する。
    private func tick(elapsed: TimeInterval) {
        advanceAutonomy(elapsed: elapsed)

        frameIndex += 1
        let didLoop = frameIndex >= animation.frameCount
        if didLoop {
            frameIndex = 0
            finishAnimationLoop()
        }

        refreshAnimation()
        updateCurrentFrame()
        scheduleFrameTimer()
    }

    /// 経過時間ぶんだけ自律行動を進める。
    private func advanceAutonomy(elapsed: TimeInterval) {
        guard gesture == nil, status == nil, !isDragging else { return }
        switch autonomy {
        case .idle:
            if let idleDeadline, Date() >= idleDeadline {
                beginNextAutonomy()
            }
        case .walking(let towardRight, let remaining):
            step(towardRight: towardRight, remaining: remaining, elapsed: elapsed)
        case .reviewing:
            break
        }
    }

    /// 一度きりのアニメーションが 1 周し終わったときの後始末。
    private func finishAnimationLoop() {
        if gesture != nil {
            gesture = nil
            return
        }
        if let status, status.isMomentary {
            self.status = nil
            beginIdle()
            return
        }
        if case .reviewing = autonomy {
            beginIdle()
        }
    }

    private func beginIdle() {
        autonomy = .idle
        idleDeadline = Date().addingTimeInterval(.random(in: Self.idleDurationRange))
        sayIdleLineIfNeeded()
    }

    /// idle が終わったあとの行動を抽選する。
    private func beginNextAutonomy() {
        idleDeadline = nil
        if Double.random(in: 0..<1) < Self.reviewProbability {
            autonomy = .reviewing
        } else {
            autonomy = .walking(towardRight: .random(), remaining: .random(in: Self.walkDistanceRange))
        }
    }

    /// 歩行を 1 コマ分進める。画面の端に達したら向きを反転する。
    private func step(towardRight: Bool, remaining: CGFloat, elapsed: TimeInterval) {
        guard let window, let bounds = Self.visibleFrame(for: window) else {
            beginIdle()
            return
        }

        let travel = min(Self.walkSpeed * CGFloat(elapsed), remaining)
        let minX = bounds.minX
        let maxX = max(bounds.maxX - window.frame.width, bounds.minX)
        let target = towardRight ? window.frame.origin.x + travel : window.frame.origin.x - travel

        var nextTowardRight = towardRight
        if target < minX || target > maxX {
            nextTowardRight.toggle()
        }

        var origin = window.frame.origin
        origin.x = min(max(target, minX), maxX)
        window.setFrameOrigin(origin)

        let rest = remaining - travel
        if rest <= 0 {
            persistOrigin()
            beginIdle()
        } else {
            autonomy = .walking(towardRight: nextTowardRight, remaining: rest)
        }
    }
}
