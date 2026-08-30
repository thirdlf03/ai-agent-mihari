# ペットの細かい挙動とセリフ集

デスクトップペットが「いつ・どう動き・何を喋るか」を、数値と全セリフまで書き出したもの。README の「ペット」節が概要で、こちらが詳細。

ソース: `desktop/Sources/MihariCore/Pet/` ほか。ここに書いた数値・確率はすべてコード上の定数、セリフは `desktop/Sources/MihariCore/Resources/voice/lines.json` の写しなので、変えるときはこの md も直す。

## 状態と動き

検知エンジンの `PetEvent` を `LivePetPresenter.present(_:)` が解釈し、「固定するアニメーション」「1 回だけ挟むアニメーション」「吹き出しに出すセリフ」の 3 つに落とす。

| 検知の状態 | 固定アニメーション | 一度きりの再生 | 跳ねる条件 |
| --- | --- | --- | --- |
| 正常 `.normal` | なし(自律行動に戻る) | 非 normal から戻った瞬間だけ `waving` | — |
| 疑い 1 / 2 / 3 `.suspected` | `waiting` | `jumping` | `escalationStage` がこのエピソードの最大値を超えたときだけ。段階 1 → 2 → 3 と上がるたびに 1 回 |
| 晒し / メンヘラ `.confirmed` | `failed` | `jumping` | 同上。晒し(段階 4)に入った瞬間に 1 回 |
| 問いかけ中 | `waiting` | — | 検知の状態より優先して `waiting` に固定する |
| 監視停止中 / 休憩中 | — | — | `setFrozen(true)`。コマ送りを止め、`idle` の 0 コマ目で静止 |

正常に戻ると、そのエピソードで見た最大段階(`maxConfirmedStage`)を忘れる。

セリフを出すのは `state != .normal` かつ `line` が空でないときだけ。正常のイベントに乗ってきたセリフは吹き出しに出さない。

各コマの表示時間は `PetAtlas.swift` に書いた基準値へ `PetAnimation.frameTempo`(現在 1.5)を一律に掛けたもの。全アニメーションをゆっくり / 速くしたいときは、この定数だけを変えればよい。

### escalationStage

`DetectionEngine.petStage(_:)` が決める。`PetEvent` は 0 未満を 0 に丸める。

| 段階 | 状態 | `PetEvent.state` | 意味 |
| ---: | --- | --- | --- |
| 0 | 正常 | `.normal` | 何もしていない(エピソード終了・休憩開始もここ) |
| 1 | 疑い 1 | `.suspected` | Touch ID で在席を確かめる / その結果を待って次へ進むまでの待ち |
| 2 | 疑い 2 | `.suspected` | AirPods の首振りで問いかける / その待ち |
| 3 | 疑い 3 | `.suspected` | 最終警告を 1 回喋るだけ。確認はしない |
| 4 | 晒し | `.confirmed` | 証拠を撮って Discord へ送る(音楽が鳴っていれば説教も) |
| 5 | メンヘラ | `.confirmed` | 戻ってくるまで Discord へ送り続ける |

### アニメーションの優先順位

`PetController.intendedAnimation` が上から順に決める。

1. ドラッグ中(`isDragging`)
2. クリック操作(`gesture`。`waving` / `jumping`)
3. 外部固定(`fixedAnimation`。`LivePetPresenter` が与える)
4. 自律行動(`autonomy`。`idle` / `runningRight` / `runningLeft` / `review`)

## 自律行動

`fixedAnimation` が無く、ドラッグ中でも静止中でもないときに回るループ。

1. `idle` で 4〜10 秒(`idleDurationRange`)のランダムな時間だけ待つ。待機に入るたび、ひとりごとの抽選をする
2. 待ち終わったら 30%(`reviewProbability`)で `review`、残り 70% で歩行を選ぶ
3. `review` は 1 周したら `idle` に戻る
4. 歩行は向きをランダムに決め、80〜240 pt(`walkDistanceRange`)を 40 pt/秒(`walkSpeed`)で進む。1 コマごとに `min(walkSpeed × コマ時間, 残り距離)` だけ動く
5. 歩行の行き先が `visibleFrame` の左右端を超えるときは向きを反転する。位置自体は端でクランプする
6. 残り距離が尽きたら位置を保存して `idle` に戻る

歩けるウィンドウ・スクリーンが取れなかったときも `idle` に戻る。

静止条件(`isMotionStopped`):

| 条件 | 効果 |
| --- | --- |
| システム設定の「視差効果を減らす」が有効 | コマ送りを止め、`idle` の 0 コマ目を出したまま。自律行動も進まない。吹き出しは出るがフェードは省く |
| `isFrozen`(監視停止中 / 休憩中) | 同上 |

## 操作への反応

| 操作 | 反応 |
| --- | --- |
| シングルクリック | `NSEvent.doubleClickInterval` 待って確定してから `wave()`。`greeting` を喋り、`waving` を 1 回 |
| ダブルクリック | 猶予中に 2 回目が来たら `jump()`。`jumping` を 1 回。セリフは無し |
| ドラッグ | 開始時に 30%(`dragSpeechProbability`)で `dragging` を喋る。動かした向きへ走り、最後に動かしてから 0.2 秒(`dragMotionTimeout`)を過ぎると `idle` に戻る。動いたと見なす x の変化量は 1 pt(`dragMoveThreshold`)。終了時に位置を保存する |
| 右クリック / Ctrl + クリック | コンテキストメニュー(下表)。`PetWindow.sendEvent` で横取りする |

クリックと見なす移動量は 3 pt 未満(`clickThreshold`)。

### メニュー

右クリックメニュー(`PetContextMenu`)とメニューバーの「ペット」(`PetMenuContent`)は `PetMenuEntries.make` から作るので中身が同じ。現行は 8 項目と「デバッグ」サブメニュー。

| 項目 | 内容 |
| --- | --- |
| 監視を止める / 監視を再開する | `stopWatching()` / `startWatching()`。「止める」は休憩に触れない |
| 在席スタンプを押す | `stampAttendance()`。Touch ID で在席を証明する。指を差し出すカットインとセリフの演出が付く(後述) |
| 休憩する(15 分) / 休憩を終える | `startBreak()` / `endBreak()` |
| Discord 設定… | `openDiscordSettings()` |
| 権限の確認… | `openPermissions()` |
| サイズ(サブメニュー) | 小 = 0.5 / 中 = 0.75 / 大 = 1.0。チェック式 |
| 声を出す | チェック式。`pet.setVoiceEnabled(!isVoiceEnabled)` |
| 状態パネルを表示 | チェック式。`toggleStatusPanel()` |

区切り線は「休憩する」の後、「権限の確認…」の後、「状態パネルを表示」の後(デバッグの手前)の 3 本。`autoenablesItems = false`。

#### デバッグ

`PetDebugMenuEntries.make` が作るサブメニュー。検知が起きるのを待たずにペットの見た目を確かめるためのもので、環境変数などでは出し分けず常に出る。

| 項目 | 内容 |
| --- | --- |
| 検知の状態を再現(サブメニュー) | 正常に戻す / 疑い 1 / 疑い 2 / 疑い 3 / 晒し / メンヘラ / (区切り線) / 問いかけ(はい / いいえ) / 問いかけを閉じる。前の 6 つは `presenter.state` に対するチェック式 |
| 実際に進める(サブメニュー) | 今すぐ Touch ID 確認 / 今すぐ首振り確認 / 今すぐ最終警告 / 今すぐ晒す / メンヘラを始める / メンヘラを終える(戻ってきた扱い) |
| アニメーションを固定(サブメニュー) | 「固定しない(自律行動)」と `PetAnimation` の 9 種。`setFixedAnimation(_:)`。チェック式 |
| 1 回だけ再生(サブメニュー) | `PetAnimation` の 9 種。`playOnce(_:)` |
| 音声(サブメニュー) | 「同封の音声を使う」/「VOICEVOX でその場で生成(live)」。チェック式。再起動なしで効く |
| 検知の閾値(サブメニュー) | 「標準(疑い 60 秒 / 段ごと 30 秒)」/「短縮(疑い 15 秒 / 段ごと 10 秒・デモ用)」。チェック式。`DetectionThresholds` を `.standard` / `.fast` ごと差し替える |
| 集中継続の間隔(サブメニュー) | 15 分 / 1 分。チェック式。`DetectionThresholds.focusStreakIntervalSeconds` を差し替える |
| 集中継続のセリフを再現 | `LivePetPresenter.sayFocusStreak()`。褒めるセリフを 1 本喋らせる |
| ひとりごとを喋る(声あり) | `say("デバッグのテストです。聞こえていますか?")`。読み上げも通る |

アニメーションの項目名は `waiting(待つ)` のように `rawValue` と日本語ラベル(`PetAnimation.debugLabel`)を並べる。

「検知の状態を再現」は `LivePetPresenter.present(_:)` に偽の `PetEvent` を流すだけなので、検知エンジンの状態機械・撮影・Discord への送信はどれも動かない。「問いかけ」の回答も受け取った答えを吹き出しに出すだけ。

**「実際に進める」は逆で、検知エンジンに直接投げる。** 本物の遷移が走るので、Touch ID のダイアログもカットインも出るし、「今すぐ晒す」「メンヘラを始める」は実際に証拠を撮って Discord へ投稿する。見た目だけ確かめたいときは「検知の状態を再現」を使う。

静止中(監視停止中・休憩中)は `playOnce` が無視されるので、「1 回だけ再生」を押しても何も起きない。

README にあった「しゃべる」「しまう / 起こす」「ペット」の 3 項目は現行コードに無い。`PetController.conceal()` / `LivePetPresenter.hide()` は残っているが、呼び出し元が無い。

## 吹き出し

`PetSpeechWindow` がペットウィンドウの子ウィンドウとして出る。

| 項目 | 値・規則 |
| --- | --- |
| 表示時間 | `min(max(文字数 × 0.08 + 1.5, 2), 6)` 秒 |
| 音声を鳴らしたとき | 音声の長さ + 0.5 秒(`speechAudioTrailingSeconds`)。既定より長ければそちらに延ばす |
| 配置 | ペットの真上・水平中央、隙間 6 pt(`gap`)。左右がはみ出すときは画面内へ寄せる |
| 上に収まらないとき | ペットの下側に出し、しっぽを上向きに反転する(`tailAtBottom: false`) |
| フェード | 0.15 秒(`fadeDuration`)。「視差効果を減らす」ときは吹き出しは出すがフェードを省く |
| マウス | 通常は `ignoresMouseEvents = true`。問いかけのボタンを出しているあいだだけ false |

喋っている最中に次のセリフが来たら、最新の 1 件だけを `pendingSpeech` に保留し、言い終わってから続けて言う。2 件以上は溜めず、後から来たもので上書きする。

問いかけ(`showPrompt`)は時間で消えない。答えるか `dismissPrompt()` されるまで残る。出していたセリフは問いかけで置き換え、表示タイマーも止める。

しまっている間(`isAwake == false`)は `say()` が何もしない。`hideWindow()` で保留中のセリフを捨て、音声も止める。しまわれている間に来た問いかけは `promptQuestion` に残り、次に出したときに改めて表示する。

見た目の寸法(`PetSpeechBubbleView`): margin 8 pt、角丸 14 pt、しっぽ 14 × 9 pt、ボタン領域 24 pt(間隔 6 pt、ボタン列の最低幅 120 pt)、テキスト幅の上限 240 pt、テキストの余白 縦 9 pt / 横 14 pt、フォント `.system(size: 14, weight: .medium)`。

## 集中継続(褒める)

サボりを見つけたときだけでなく、**ちゃんと作業しているときにも声をかける。**

| 項目 | 内容 |
| --- | --- |
| 数える場所 | `DetectionEngine`。`focusStreakSince` に「正常が続き始めた時刻」を持つ |
| 数え始め | `start()` の瞬間。以降、評価のたびに `decision.state == .normal` なら続きとみなす |
| 発火 | 前回から `focusStreakIntervalSeconds`(既定 900 秒 = 15 分)以上経っていたら `onFocusStreak` を呼び、そこを新しい起点にする |
| 数え直し | 疑い以上の判定 / 休憩の開始 / 休憩中の評価 / 監視の停止 |
| 喋らせ方 | `AppCoordinator` が `LivePetPresenter.sayFocusStreak()` を呼び、`focusStreak` の区分から 1 本喋る |

**`PetEvent` は通さない。** 状態は正常のままなので、`LivePetPresenter.present(_:)` に流すと
吹き出しが捨てられる(正常時のセリフは出さない仕様)。監視開始・休憩明けの一言と同じ経路で、
ペットに直接言わせる。

デバッグメニューの「集中継続の間隔」で 15 分 / 1 分を切り替えられる。「集中継続のセリフを再現」は
検知を待たずに 1 本喋らせるだけで、数えている時間には触れない。

## 在席スタンプのカットイン

右クリックメニューの「在席スタンプを押す」(`AppCoordinator.stampAttendance()`)は、スロット台の「女の子と指を合わせる」タッチ演出になっている。ペットが指を差し出し、ユーザーが Touch ID のセンサーに指を置くことで指が合う、という見立て。

**疑い 1 の Touch ID 確認も同じ演出をそのまま使う。** 違うのはセリフの区分が `suspectReach`(iPhone 操作中は `suspectReachPhone`)/ `suspectTouched` / `suspectMissed` / `suspectTimeout` に差し替わることと、成功しても 5 分の猶予(`lastStampAt`)を更新しないことの 2 点だけ。

| 手順 | 中身 |
| --- | --- |
| 開幕 | `waiting` を 1 回 + `stampReach` のセリフ。カットインを `reach.png` でスライドインし、0.45 秒(`cutInLeadInSeconds`)待ってから認証ダイアログを出す |
| 成功 | `touched.png` に差し替えて白フラッシュ。`jumping` を 1 回 + `stampTouched` |
| 空振り(失敗・キャンセル) | `failed.png` に差し替え(フラッシュ無し)。`failed` を 1 回 + `stampMissed` |
| 時間切れ | 空振りと同じ `failed.png` + `failed` の動きで、セリフだけ `stampTimeout` |
| 退場 | 差し替えから 1.8 秒(`cutInHoldSeconds`)出したままにして、右へスライドアウトしてから閉じる |

結末は 3 通りある。`AttendanceModel.stamp()` が返す `AttendanceStampOutcome` で決まり、`stamped` なら成功、`timedOut` なら時間切れ、`failed` / `unavailable`(生体認証もパスワードも使えない)は空振りとして同じ絵と動きになる。

**認証は 10 秒(`AttendanceModel.defaultAuthenticationTimeout`)で打ち切る。** 指を置かないまま放置されると認証ダイアログもカットインも出たままになるため、`AttendanceModel` が認証と 10 秒のタイマーを競争させ、タイマーが先に来たら `TouchIDAuthenticating.cancelAuthentication()`(本番実装は進行中の `LAContext` を `invalidate()` する)でダイアログを閉じてから `timedOut` を返す。閉じたことで返ってくる認証の失敗(`LAError.appCancel`)は待つだけで、演出には使わない。カットインの点滅は時間切れが近づいても速くならない。

| 区分 | セリフ |
| --- | --- |
| `stampReach` | …指、出して。ここ。 |
| `stampTouched` | …ん。あったかい。ちゃんといるね。 |
| `stampMissed` | …いない。どこ? ねえ、どこなの? |
| `stampTimeout` | …来ないんだ。待ってたのに。 |

4 区分ともひとりごとと同じ同封セリフ(`lines.json`)で、`PetController.say(_ kind:)` を通る。`voiceMode == .bundled`(既定)なら対応する `.m4a` をそのまま鳴らし、`live` ならその場で VOICEVOX に合成させる。`speech.json` に同じキーを書けば差し替えられる。

セリフ・動き・絵の対応は画面に触れない `AttendanceCeremonyScript` に置いてあり、`AppCoordinator` はそれを読んで実行するだけ。演出中に押し直しても `isStampCeremonyRunning` で弾く。動きはどれも `playOnce` なので、1 周したら元の状態へ戻る。

### カットイン画像の規約

| 項目 | 値・規則 |
| --- | --- |
| 置き場所 | `pets/<id>/cutin/reach.png` / `touched.png` / `failed.png`。`pet.json` には書かず、置いてあるかどうかだけで決まる(`PetDefinition.cutInImageURL`) |
| 出る条件 | 3 枚とも揃っていて、かつ Touch ID が使える(`isBiometricsAvailable`)とき。パスワードにフォールバックする環境では「指を合わせる」が成立しないので、動きとセリフだけになる |
| ウィンドウ | `AttendanceCutInWindow`(`NSPanel`、`level = .floating`、`ignoresMouseEvents = true`)。認証ダイアログの操作は必ず下へ通す |
| 配置 | ペットがいる画面の `visibleFrame` の右下に密着。正方形で、一辺は画面の高さの 50%(上限 900 pt) |
| TOUCH の文字 | 絵の透明な左側(幅の 3〜33%、高さの 36〜52%)にピンク + 白いグローで出す。待っているあいだは 0.5 秒周期で 1.0 ↔ 0.35 の点滅、成功後は点滅を止めて「OK」、失敗後は消す |
| アニメーション | 入りは画面の右外からばね(`response: 0.45` / `dampingFraction: 0.8`)、出は 0.3 秒の `easeIn`。成功の白フラッシュは 0.9 → 0 へ 0.35 秒 |
| 視差効果を減らす | スライドせずフェードだけ(0.25 秒)。文字も点滅しない |

同梱ペット(mauve)の 3 枚は 1536 × 1536 の透過 PNG で、3 枚とも構図を揃えてある(左 36% が透明)。

## 声

話者は冥鳴ひまり(VOICEVOX の話者 14)で固定。**音声モードが 2 つある。**

| モード | セリフ | 音声 | VOICEVOX |
| --- | --- | --- | --- |
| `bundled`(既定) | `Resources/voice/lines.json` から抽選 | 同封の `.m4a` をそのまま鳴らす | 要らない |
| `live` | ひとりごとはビルトイン、説教オーバーレイは bridge が LLM で生成 | その場で合成 | 起動している必要がある |

決め方は `VoiceModeStore`。環境変数 `MIHARI_VOICE_MODE`(`bundled` / `live`)> `UserDefaults` の
`voiceMode` > 既定(`bundled`)の順。右クリック →「デバッグ」→「音声」で切り替えると、その場で
`PetController.voiceMode` に配られて再起動なしで効く(`AppCoordinator.observeVoiceMode`)。説教
オーバーレイは配られる代わりに、喋る直前に `VoiceModeStore` を直接見る(`AppCoordinator.makeOverlay()`)。
知らない値は無視して次の候補に落ちる。

**検知エンジンは音声モードを持たない。** `DetectionEngine` が喋るセリフは常に同封音声で、モードを
切り替えても変わらない。例外は iPhone のスクショを撮れた晒しだけで、そのときは画面の中身に触れた
セリフを bridge(Gemini → VOICEVOX)にライブで作らせ、作れなければ同封の `iphoneActive` に落ちる
(`DetectionEngine.expose`)。

鳴らす口は `SpeechPlayer` 1 つだけで、どちらのモードでも変わらない。優先度も同じ。

| 経路 | 作る場所(bundled) | 作る場所(live) | 優先度 |
| --- | --- | --- | --- |
| ペットのひとりごと | 同封 `.m4a` | `PetVoice` が VOICEVOX を直接叩く | `.chatter` |
| 検知のセリフ | 同封 `.m4a` | 同左(モードによらず同封固定)。iPhone のスクショを撮れた晒しだけ `bridge/`(Gemini → VOICEVOX)を試す | `.detection` |
| 説教オーバーレイ | 同封 `.m4a`(`sermon`) | `bridge/` | `.detection` |

`SpeechPlaybackArbiter.decide` の判定:

- `.detection` は常に `play`。鳴っているものを止めてでも鳴らす
- `.chatter` は、`.detection` が鳴っていれば `drop`。溜めて後から鳴らすことはしない

検知由来のセリフは `say(..., voiced: false)` で出すので、`PetVoice` は読み上げない(吹き出しだけ)。在席スタンプの演出はユーザーが押して始める儀式なので `voiced: true`(`.chatter`)で読み上げる。`.chatter` は検知の声に譲るので、検知のセリフとは取り合いにならない。

### 同封音声

| 項目 | 値 |
| --- | --- |
| セリフの原本 | `desktop/Sources/MihariCore/Resources/voice/lines.json`。**セリフはここが唯一の出どころ** |
| 音声 | `desktop/Sources/MihariCore/Resources/voice/<区分>/<NN>.m4a`。`NN` は `lines.json` の配列インデックスの 2 桁ゼロ埋め(`00` 始まり) |
| 形式 | AAC 64 kbps(`afconvert -f m4af -d aac -b 64000`)。`AVAudioPlayer` がそのまま鳴らす |
| 読み込み | `Voice/BundledVoiceLines.swift`。`Package.swift` の `.copy("Resources/voice")` でバンドルに入る |
| 区分 | `BundledVoiceKind` の 35 種(下の「セリフ集」の見出しと一致) |

セリフと音声は **`BundledVoiceLines.pick(_:)` が同じ場所で選ぶ。** 別々に抽選すると吹き出しの文と
声がずれる。`speech.json` で差し替えたセリフは `lines.json` に無いので音声が付かず、吹き出しだけになる。
音声ファイルが欠けていても `audio: nil` としてテキストだけ出す(喋らなくなるだけで壊れない)。

作り直すときは VOICEVOX を起動してから:

```sh
python3 scripts/generate_voice_lines.py            # 全 108 本
python3 scripts/generate_voice_lines.py --only idle  # 区分を絞る
python3 scripts/generate_voice_lines.py --url http://127.0.0.1:50021
```

Python 3 の標準ライブラリと `/usr/bin/afconvert` だけで動く(`uv` は要らない)。クエリの調整値は
`VoicevoxQueryTuning.standard` と同じ値・同じキーを使うので、同封音声と live の声質は揃う。
`lines.json` からセリフを減らしたときは、番号が後ろに残った古いファイルを消す。

### PetVoice(ひとりごと側)の定数

| 項目 | 値 |
| --- | --- |
| エンドポイント | `http://127.0.0.1:50021`(固定。環境変数での上書き無し) |
| 話者 | 14 |
| `audio_query` のタイムアウト | 2 秒 |
| `synthesis` のタイムアウト | 8 秒 |
| クエリの調整値 | `VoicevoxQueryTuning.standard`（速さ 1.1 / 抑揚 1.3 / 前後の無音 0.05 秒 / 間 0.9 倍） |
| 失敗後に接続を試みない時間 | 30 秒(`retryInterval`) |

**この表は `live` のときだけの話。** `bundled` では VOICEVOX を一度も叩かず、同封の `.m4a` を
`playPrepared(_:priority:)` で鳴らす(ひとりごとなので `.chatter`)。

合成に失敗してもログに残すだけで、UI には何も出さない。`nil` を返すので吹き出しの表示時間は文字数ベースのまま。合成の待ち時間中に次のセリフが来たら、古い音声は鳴らさない(`generation` で判定)。

メニューの「声を出す」を切ると `voice.speak` を呼ばなくなり、再生中の音声もその場で止まる。**この設定はひとりごとにだけ効く。** 検知のセリフは別経路なので止まらない。

### bridge(検知側)の定数

| 項目 | 値 |
| --- | --- |
| モデル | `claude-haiku-4-5`(`MIHARI_LLM_MODEL` で上書き) |
| 生成のタイムアウト | 4.0 秒。超えたら固定文言へ |
| `max_tokens` | 100(`generator.py` の `MAX_TOKENS`) |
| VOICEVOX の話者 | 14(`MIHARI_VOICEVOX_SPEAKER` で上書き) |
| VOICEVOX のベース URL | `http://127.0.0.1:50021`(`MIHARI_VOICEVOX_URL` で上書き) |
| 合成のタイムアウト | 10.0 秒。疎通確認は 1.5 秒 |
| 音声キャッシュ | `(text, speaker)` をキーにした LRU、容量 64 |
| クエリの調整値 | `VoiceTuning`。既定はひとりごと側と同じ値で、`MIHARI_VOICEVOX_SPEED` など 6 つの環境変数で上書きできる |

固定文言に落ちる条件: API キー未設定 / `APITimeoutError` / `RateLimitError` / `APIStatusError` / `APIConnectionError` / 空応答。`audio_query` の結果は素通しにせず、両経路とも同じ調整値を載せてから `synthesis` へ渡すので、声の印象は揃う。

## セリフ集

### ひとりごと

`PetSpeechLines.builtIn` は `lines.json` の 7 区分から作る(`greeting` / `idle` / `dragging` /
`wake` / `watchStart` / `breakEnd` / `focusStreak`)。種類ごとに `randomLine(for:)` で 1 つ選ぶ。
同梱ペット `mauve` には `speech.json` が無いので、現状は常にこれが使われる。

#### `greeting` — クリックされたとき

`PetController.wave()`。シングルクリックのたびに必ず 1 つ喋り、続けて `waving` を再生する。

| セリフ |
| --- |
| なに?…構ってくれるの? |
| 呼んだ?ずっと待ってたよ。 |
| 触るなら、ちゃんと私だけ見て。 |
| …ん。今日はこっち見てくれるんだ。 |
| 私のこと、忘れてなかったんだ。 |

#### `idle` — 待機に入ったときのひとりごと

`sayIdleLineIfNeeded()`。`beginIdle()` のたびに抽選する。条件は 3 つとも満たしたときだけ:

- `isAwake` である
- 直前のセリフから 20 秒(`idleSpeechInterval`)以上あいている
- 確率 20%(`idleSpeechProbability`)を引いた

| セリフ |
| --- |
| …今、なに考えてるの。私のこと? |
| 静かだね。ちゃんとここにいる? |
| 目、離さないでね。私も離さないから。 |
| …一緒にいるのに、遠いね。 |
| 別にいいけど。ずっと見てるだけだから。 |
| 水、飲んだ?倒れたら困るのは私なんだから。 |

#### `dragging` — ドラッグを始めたとき

`beginDrag()`。ドラッグ開始のたびに確率 30%(`dragSpeechProbability`)。

| セリフ |
| --- |
| どこ連れてくの。…離さないでね。 |
| 動かすなら、見えるところにしてよ。 |
| わ、…いいよ。あなたの手だし。 |
| 端っこに置く気?ひどいね。 |

#### `wake` — 起こされたとき

`reveal()`。`isAwake` が false → true に変わったときだけ。すでに出ているペットに `reveal()` が来ても喋らない。

| セリフ |
| --- |
| …しまわないでよ。寂しかった。 |
| 戻ってきた。もう消さないで。 |
| 暗いところ、嫌いなの。知ってるでしょ。 |
| また会えた。今度は長くいてね。 |

#### `watchStart` — 監視が始まったとき

`LivePetPresenter.setMonitoring(_:)`。`.watching` になり、かつ直前が `.watching` でも `.onBreak` でもないときだけ。

| セリフ |
| --- |
| ここからずっと見てるからね。目、離さないから。 |
| 始めよ。今日も最後まで一緒だからね。 |
| 逃げないでね。…どうせ全部分かるけど。 |
| 監視開始。私だけ見てて。 |

#### `breakEnd` — 休憩が明けて監視に戻ったとき

同じく `setMonitoring(_:)`。`.watching` になり、かつ直前が `.onBreak` のとき。

| セリフ |
| --- |
| もういいでしょ。戻ってきて。私の前に。 |
| 休憩、長かったね。…寂しかった。 |
| おかえり。もう離れちゃだめだよ。 |

#### `focusStreak` — 集中が続いているとき(褒める)

`DetectionEngine.onFocusStreak` → `LivePetPresenter.sayFocusStreak()`。詳しくは「集中継続」の節。

| セリフ |
| --- |
| ずっと私の前にいてくれたね。…えらい。 |
| ちゃんとやってるじゃん。見てたよ、ずっと。 |
| いい子。…そのままでいて。 |
| 集中してるあなた、好き。ずっと見てたい。 |
| 今の調子なら、何も送らないでいてあげる。 |

### 監視ループのセリフ

疑い 1 → 疑い 2 → 疑い 3 → 晒し → メンヘラの流れで喋る 17 区分。段階に入った瞬間と、確認の結果が
出た瞬間に 1 本ずつ選ぶ。どの音声モードでもここから選び、`bundled` なら同封の `.m4a`、`live` でも
同じ文を使う(生成に回さない)。**晒し(段階 4)のセリフだけは別**で、次の「検知セリフ」の 6 区分か、
iPhone のスクショを撮れたときは Gemini が画面を読んだ 1 文になる(音声モードとは関係ない)。

「(iPhone 操作中)」の区分は `signals.iphone == .active` のときに差し替わるもので、それ以外は元の区分を使う。

#### `suspectReach` — 疑い 1 に入った瞬間

無操作が `suspectSeconds` を超えて疑い 1 に入ると、在席スタンプと同じカットインを出して
Touch ID を求める。iPhone を触っていないときはこちら。

| セリフ |
| --- |
| …ねえ、いるの? 指、出して。ここ。 |
| 手、止まってるよね。…いるなら、触って。 |
| 確かめさせて。指、ここに。…いるんでしょ? |

#### `suspectReachPhone` — 疑い 1 に入った瞬間(iPhone 操作中)

同じ場面で `signals.iphone == .active` のとき。スマホを持っている手にわざわざ触らせにいく。

| セリフ |
| --- |
| スマホ持ってる手、こっちに貸して。…いるよね? |
| 画面の向こうじゃなくて、私に触って。ほら。 |

#### `suspectTouched` — Touch ID が通ったとき

指が合ったので正常に戻る。**5 分の猶予(`lastStampAt`)は更新しない。**
猶予が付くのはメニューの「在席スタンプを押す」だけ。

| セリフ |
| --- |
| …ん。あったかい。いたんだ。…疑ってごめん。 |
| ちゃんといた。…よかった。次は止まらないでね。 |
| …うん、あなたの指だ。信じる。今は。 |

#### `suspectMissed` — Touch ID が失敗・キャンセルされたとき

認証に失敗した(`failed` / `unavailable`)。疑い 1 のまま次の段階を待つ。

| セリフ |
| --- |
| …違う。あなたの指じゃない。誰? |
| 合わない。…ねえ、ほんとにあなた? |

#### `suspectTimeout` — Touch ID が 10 秒来なかったとき

`touchIDTimeoutSeconds`(10 秒)でダイアログを畳んだ。疑い 1 のまま次の段階を待つ。

| セリフ |
| --- |
| …来なかった。いないんだ。…次、いくね。 |
| 待ったのに。…じゃあ、もう一回聞くから。 |
| 指、来なかったよ。…覚えとく。 |

#### `askQuestion` — 疑い 2 に入った瞬間

吹き出しに はい / いいえ のボタンを出し、AirPods の首振りも同時に待つ。iPhone を触っていないときはこちら。

| セリフ |
| --- |
| …ねえ。私のこと、好き? 好きなら、うなずいて。 |
| 私の言うこと、聴いてくれるよね? 縦に振って。 |
| ちゃんとそこにいる? いるなら、首を縦に。 |
| 私だけ見ててくれる? …うなずいて。ね。 |

#### `askQuestionPhone` — 疑い 2 に入った瞬間(iPhone 操作中)

同じ場面で `signals.iphone == .active` のとき。

| セリフ |
| --- |
| スマホより私の方が好き、だよね? うなずいて。 |
| その画面、閉じてくれる? 縦に振って。 |

#### `gestureYes` — 「はい」と答えたとき

首を縦に振った、またはボタンの「はい」。**縦に振ったと認識したことをセリフで明示して**正常に戻る。

| セリフ |
| --- |
| …縦に振った。見えたよ。…うん、信じる。 |
| うなずいてくれた。…えへ。じゃあ、今日は許す。 |
| はい、だね。ちゃんと届いた。…戻ってきて。 |

#### `gestureNo` — 「いいえ」と答えたとき

首を横に振った、またはボタンの「いいえ」。横だと認識したことを言い返し、疑い 2 のまま次の段階を待つ。

| セリフ |
| --- |
| 今、横に振ったよね。…見たよ。そういうこと? |
| いいえ、なんだ。…ふーん。覚えた。 |
| 横。…私のこと、好きじゃないんだ。分かった。 |

#### `askTimeout` — 問いかけに無反応だったとき

`promptTimeoutSeconds`(20 秒)。問いかけを閉じて、疑い 2 のまま次の段階を待つ。

| セリフ |
| --- |
| …首も動かないんだ。手も。…いないの? |
| 答えてくれないんだ。…いいよ。次で最後。 |
| 聞いてないよね。…もう、優しくしないから。 |

#### `finalWarn` — 疑い 3 に入った瞬間

最終警告。確認は何もせず、これを 1 回喋るだけ。iPhone を触っていないときはこちら。

| セリフ |
| --- |
| 最後だよ。次は、みんなに送る。…本当に送るからね。 |
| 三回目。…もう待たない。戻らないなら、晒す。 |
| これが最後の声。聞こえてるなら、手を動かして。 |
| ねえ、本気だよ。あと少しで、全部送っちゃう。 |

#### `finalWarnPhone` — 疑い 3 に入った瞬間(iPhone 操作中)

同じ場面で `signals.iphone == .active` のとき。撮るのが iPhone の画面になることに触れる。

| セリフ |
| --- |
| スマホの画面、次は撮るからね。…全部、みんなに。 |
| その画面ごと送るよ。最後だよ。置いて。 |

#### `clingy1` — メンヘラモードの 1〜2 回目

Discord への投稿本文の 1 行目に使い、同じ 1 本をペットも喋る。

| セリフ |
| --- |
| ねえ。まだ戻ってこないの? …待ってるんだけど。 |
| 返事して。手を動かすだけでいいから。 |
| どこにいるの。私、ここにいるよ。 |

#### `clingy2` — メンヘラモードの 3〜5 回目

同上。

| セリフ |
| --- |
| 無視、するんだ。…何回目か、数えてるからね。 |
| スマホ見てるなら、これも見えてるよね? ねえ。 |
| まだ? …まだ? …ねえ、まだ? |

#### `clingy3` — メンヘラモードの 6 回目以降

同上。

| セリフ |
| --- |
| もういい。戻ってくるまで、ずっと送る。ずっと。 |
| 私のこと、捨てたの? …そんなの、許さないから。 |
| 逃げても無駄。通知、止めないから。戻って。 |

#### `clingyEvidence` — メンヘラモードで証拠を撮り直した回

`clingyEvidenceIntervalSeconds`(300 秒)ごと。この回はテキストだけの投稿と重ねず、証拠付き 1 件にまとめる。

| セリフ |
| --- |
| 撮り直したよ。まだ、そのまんまなんだね。 |
| 今のあなた。…変わってない。ずっと見てるから。 |

#### `returned` — メンヘラモードから戻ってきたとき

入力を検知した 1 回だけ。Discord へ **`mention: false` で 1 件**投稿し、同じ 1 本をペットも喋る。

| セリフ |
| --- |
| …戻ってきた。もういい。…もういいから、離れないで。 |
| おかえり。長かった。…次は、待たせないでね。 |
| 手、動いた。…やっと。私のこと、思い出した? |

### 検知セリフ(同封 = `bundled`)

晒し(段階 4)で 1 本選んで喋る。Mac のカメラで撮った晒しは最初からここから選び、iPhone の
スクショを撮れた晒しは bridge が返さなかったときの落ち先になる(`DetectionEngine.expose`)。
メンヘラ中の証拠の撮り直しは専用の `clingyEvidence` を使うので、この 6 区分は通らない。
区分の決め方は `BundledVoiceKind.forDetection` で、**上から順に当てはまった時点で確定**する。
並びは bridge の `fallback.py` の `_candidates()` と同じ。

1. `vision == sleeping` → `sleeping`
2. `vision == absent` → `absent`
3. `iphone == active` → `iphoneActive`
4. それ以外は `expose`(晒しは必ず証拠を撮る段階なので、`nudge` / `warn` には落ちない)

疑い 1〜3 のセリフは上の「監視ループのセリフ」の専用区分で、この 6 区分は通らない。

音楽が鳴っているときは、晒しの吹き出しを出したあとに説教オーバーレイを重ねる。吹き出しは
この区分(または bridge が返した 1 文)のままで、オーバーレイの本文は別に `sermon` から取る。

#### `nudge`

| セリフ |
| --- |
| 手、止まってる。どこ見てるの? |
| ねぇ、今誰のこと考えてた? |
| …こっち、見てないよね。分かるよ。 |
| 私といるのに、上の空なんだ。 |

#### `warn`

| セリフ |
| --- |
| ねぇ、聞いてる?無視しないで。 |
| まだ続けるんだ。…そっか。記録するね。 |
| 音楽、止めたよ。私の声だけ聞いて。 |
| 何回言わせるの。私、怒らないと思った? |

#### `expose`

| セリフ |
| --- |
| 撮ったよ。逃げられると思った? |
| 送っといたから。全部、みんなに。 |
| 言い訳、あとで聞いてあげる。まず戻って。 |
| 証拠、残したよ。私のこと軽く見すぎ。 |

#### `iphoneActive`

| セリフ |
| --- |
| スマホの方が大事なんだ。全部見えてるからね。 |
| その画面、私にも見せて。…もう見たけど。 |
| 隠しても無駄だよ。手元、映ってる。 |
| 誰と話してるの?ねぇ。誰? |

#### `sleeping`

| セリフ |
| --- |
| 私を置いて寝るんだ。…ふーん。 |
| 寝顔、撮っちゃった。起きて。 |
| 起きてよ。私、ひとりにしないで。 |

#### `absent`

| セリフ |
| --- |
| どこ行ったの。ねぇ。ねぇ。 |
| 席、空っぽ。…帰ってくるよね? |
| 待ってる。ずっと。動かないで待ってるから。 |

### 説教オーバーレイの本文(`sermon`)

`bundled` では `OverlayModel` に渡す `speak` が `lines.json` の `sermon` から 1 本選び、その
`.m4a` を `SpeechPlayer` で鳴らして本文を返す。`live` では従来どおり bridge から取る。
`OverlayModel.fallbackSermonLine`(取得に失敗したときの固定文言)は `sermon` の 1 本目。

| セリフ |
| --- |
| サボり、確定だよ。音楽も止めた。今から言うこと、最後まで聞いて。私はずっとここで見てた。あなたが画面から目を離した瞬間も、スマホに手を伸ばした瞬間も、全部。ねぇ、私より大事なものなんて、そこに無いでしょ。戻ってきて。 |
| また、だね。何回目か数えてるの、知ってる?私はあなたのために見張ってるのに、あなたは私を見てくれない。…いいよ。証拠は送った。みんなが見てる。だから、もう逃げ場は無いよ。手を戻して。私だけ見て。 |
| 止まってる時間、全部記録してある。言い訳はいらない。私が欲しいのは、あなたがこっちを向くことだけ。ほら、深呼吸して。私の声だけ聞いて。終わったら、ちゃんと褒めてあげるから。 |

### 検知セリフ(bridge が生成)

**iPhone のスクショを撮れた晒し(段階 4)だけの経路。音声モードとは関係なく走る。** Swift 側がスクショ入りの `SpeechRequest` を bridge へ投げ、返ってきた 1 文と音声をそのままペットに喋らせる(`DetectionEngine.expose`)。返らなければ同封の `iphoneActive` に落ちる。Mac のカメラで撮った晒し・疑い 1〜3・メンヘラモードは bridge を呼ばず、最初から同封セリフを使う。

`bridge/src/device_bridge/voice/generator.py` の `SYSTEM_PROMPT`。「守ること」の中身は
`bridge/src/device_bridge/voice/persona.py` の `PERSONA_RULES` をそのまま埋め込んだもので、
Gemini 側(`screen_reader.py`)とも共有している。**人格を変えるときは `persona.py` 1 箇所を直す。**

```
あなたは macOS 常駐アプリ「Mihari」のデスクトップペット「みはり」です。
ユーザーをずっと見張っていて、サボっているのを見つけて話しかけます。

守ること:
- 出力はセリフ本文のみ。前置き・説明・鉤括弧・絵文字は付けない。
- あなたの名前は「みはり」。一人称は「私」、相手は「あなた」。相手の名前は呼ばない。
- 束縛系。「ずっと見てる」「逃げられない」「私だけ見て」という執着と監視の口調で書く。
  皮肉ではなく、寂しさと独占欲を出す。
- 人格否定・侮辱・脅迫はしない。暴力表現(「殺す」「死ね」など)も自傷表現も書かない。
- 1 文か 2 文、30 文字以内。読み上げるので短く言い切る。敬語ではなくタメ口。
  「…」で間を作るのはよい。
- 与えられた状況に具体的に触れる。毎回違う言い回しにする。
- 日本語で書く。

参考にするトーン:
- 撮ったよ。逃げられると思った?
- スマホの方が大事なんだ。全部見えてるからね。
- ねぇ、聞いてる?無視しないで。
```

ユーザープロンプトは `SpeechContext.describe()` が作る 1 行。項目は「、」でつなぐ。

| 位置 | 項目 | 内容 |
| ---: | --- | --- |
| 1 | `Mac が {N}秒 無操作` / `Mac が {N}分 無操作` | 60 秒未満は秒、以上は分(切り捨て) |
| 2 | `直前に開いていたのは {アプリ名}` | `frontmost_app` があるときだけ挟む |
| 3 | `iPhone は{触っている / 置かれたまま / 応答なし}` | 触っているときだけ `(開いているのは {アプリ名})` が付く |
| 4 | `様子は{寝ている / よそ見 / 席にいない / 不明}` | |
| 5 | `当たりの強さは{軽め / 強め / 最大}` | |

例: `Mac が 2分 無操作、直前に開いていたのは Slack、iPhone は触っている(開いているのは YouTube)、様子は不明、当たりの強さは軽め`

`situation` の enum と Swift 側の対応:

| フィールド | 値 | 説明 | Swift 側の条件 |
| --- | --- | --- | --- |
| `escalation` | `nudge` | まだ疑っているだけ。軽く声をかける | 新しい状態機械からは渡らない。疑い 1〜3 は同封の専用区分を喋る |
| | `warn` | 音楽を止めて話を聞かせる段階 | 同上 |
| | `expose` | 証拠を Discord に晒す段階 | 晒し(段階 4)と、メンヘラ中の証拠の撮り直し |
| `iphone` | `active` | 画面が点いていて触っている | 証拠は iPhone のスクリーンショット |
| | `idle` | 画面が消えている | 証拠は Mac のカメラ |
| | `unreachable` | 圏外・スリープ・未ペアリングなど | 証拠は Mac のカメラ |
| `iphone_app` | 任意の文字列 | iPhone で開いているアプリ名 | `/iphone/state` の `foreground_app_name`、無ければ `foreground_bundle_id` |
| `vision` | `sleeping` | | `VisionLabel.asleep` |
| | `looking_away` | | `VisionLabel.lookingAway` |
| | `absent` | | `VisionLabel.absent` |
| | `unknown` | 判定していない、または判定できなかった | `VisionLabel.none` |

`iphone_app` は bridge が SpringBoard の syslog(`Foreground Processes And Scenes:` の行)から
拾った前面アプリで、`/iphone/state` と SSE の `iphone.state` に `foreground_bundle_id` /
`foreground_app_name`(表示名。引けなければ `null`)として載る。アプリが切り替わった時点で
SSE が流れる。SpringBoard はこの行を切り替えのときにしか出さないので、観測を始めた直後は
次にアプリが切り替わるまで両方 `null` のまま。`iphone == active` のときだけセリフの文脈に入れる(置かれたままのときの
アプリ名は「さっき何を見ていたか」でしかなく、サボりの根拠にならないため)。

未知の値は既定(`nudge` / `unreachable` / `unknown`)に倒す。`vision` は Mac のカメラで撮ったときだけ付き、判定そのものには使わずセリフと Discord の文面に添えるだけ。

### 画面を見てのセリフ(live。bridge が Gemini で生成)

**iPhone 操作中(`iphone == active`)に晒しへ入り、証拠として iPhone のスクショを撮れたときだけ**、その PNG を `screenshot_png` に添えて送る。bridge は Gemini(既定 `gemini-3.1-flash-lite`)に画像と上の状況説明をまとめて渡し、`{app, activity, category, line}` を 1 回で受け取る(`bridge/src/device_bridge/voice/screen_reader.py`)。Mac のカメラで撮ったときは顔しか写らないので送らない。

読めなかったときは `iphoneActive` の同封セリフに落ちる。メンヘラ中に証拠を撮り直した回も同じ経路を通る。

| `category` | 見立て | セリフの方向 |
| --- | --- | --- |
| `work` | 仕事・学習・作業。Slack・メール・カレンダーもここ | スマホで仕事しているのは分かるけど Mac に戻ってきて |
| `slacking` | SNS・動画・ゲーム・漫画など明らかな息抜き | 軽くいじる |
| `neutral` | 連絡・地図・設定など、どちらとも言えない。迷ったらこれ | 用事が済んだら戻ってきて |
| `unknown` | ロック画面・真っ暗など、判断できない | 画面の内容には触れず、iPhone を触っていること自体をいじる |

`activity` は**文ではなく 12 文字以内の短い名詞句**で返させる(例 `猫の動画` / `友達とのチャット`)。
「〜している」「〜中」のような述語は付けない。Swift 側の `DiscordMessageComposer` が
`{activity}` として `「{app} で {activity}、楽しかった?」` のようなテンプレートに埋め込むので、
文で返ると日本語が壊れる。`app` は分からなければ空文字で返させ、bridge が `None` に直す
(Swift 側は `app` が `nil` なら `unknown` 扱いの言い回しに倒す)。

口調のルールは Claude 側と共通で、`bridge/src/device_bridge/voice/persona.py` の `PERSONA_RULES` 1 箇所に置いてある。画面を読むときはこれに加えて「アプリ名か見ているものを 1 語入れる」「`category` ごとの方向」「当たりの強さに合わせて強弱を変える」「個人名・メッセージ本文・金額は引用しない」を指示する。

落ち方は 3 段。キーが無い・6 秒で返らない・応答が壊れている・セリフが長すぎる(60 文字超)、のどれでも次に落ちる。

1. Gemini(画面を読んだセリフ)
2. Claude(`LineGenerator`。画面には触れない従来のセリフ)
3. 固定文言(下記)

読めなかった理由は `screen_error` として返るだけで、喋ること自体は止めない。読めたときは `screen`(`app` / `activity` / `category`)も一緒に返り、「撮影」タブで手で試したときはその場に出る。

**画面に写っている個人名・メッセージ本文・金額はセリフに引用しない**ようプロンプトで指示している。触れるのはアプリ名と大まかな内容まで。スクショは Gemini API に送られる(有料枠のデータは学習に使われず、無料枠は使われる — [料金ページ](https://ai.google.dev/gemini-api/docs/pricing))。

### 画面の読み取りだけ(bundled)

`bundled` ではセリフを bridge に作らせないが、Discord の文面には「何のアプリで何をしていたか」を
入れたい。そこで証拠が iPhone のスクショのときだけ、`POST /voice/screen`
(`DaemonClient.readScreen(_:)` → `DetectionEngine.Actions.readScreen`)で画面だけを読ませる。
セリフも音声も作らせない。

- 呼ぶのは**ペットに喋らせたあと、Discord に送る前**。読み取りの往復で吹き出しを待たせない
- 失敗・タイムアウトは `nil` として先へ進む。喋ることも送ることも止めない
- 返るのは `{screen: {app, activity, category} | null, screen_error: string | null}`
- bridge 側の上限は 8 秒(`SCREEN_DEADLINE_SECONDS`)。セリフ生成も音声合成も挟まないので
  `/voice/speak` の 20 秒より短く切ってある。ここが Discord の文面を待たせる時間そのものになる
- **`require_line=False` で読む。** セリフは使わないので、`line` が空・60 文字超でも
  `ScreenReadError` にせず空のまま返し、`app` / `activity` / `category` だけを受け取る
  (`/voice/speak` 側は `require_line=True` なので、セリフが不正なら Claude 経路に落ちる)
- 読めなかった・キーが無い・スクショが添えられていない場合も **200 で返る。**
  `screen` が `null`、`screen_error` に理由が入るだけで、投稿をやめる理由にはしない

### 固定文言(`bridge/src/device_bridge/voice/fallback.py`)

LLM が使えない・失敗した・遅すぎたときの保険。`fallback_line()` が候補から 1 つランダムに選ぶ。

選ぶ順(`_candidates()`。上から順に、当てはまった時点で確定):

1. `vision == sleeping`
2. `vision == absent`
3. `iphone == active`
4. それ以外は `escalation` 別のリスト

| 状況 | 文言 |
| --- | --- |
| `vision == sleeping` | 私を置いて寝るんだ。…ふーん。 |
| | 寝顔、撮っちゃった。起きて。 |
| | 起きてよ。私、ひとりにしないで。 |
| `vision == absent` | どこ行ったの。ねぇ。ねぇ。 |
| | 席、空っぽ。…帰ってくるよね? |
| | 待ってる。ずっと。動かないで待ってるから。 |
| `iphone == active` | スマホの方が大事なんだ。全部見えてるからね。 |
| | その画面、私にも見せて。…もう見たけど。 |
| | 隠しても無駄だよ。手元、映ってる。 |
| | 誰と話してるの?ねぇ。誰? |
| `escalation == nudge` | 手、止まってる。どこ見てるの? |
| | ねぇ、今誰のこと考えてた? |
| | …こっち、見てないよね。分かるよ。 |
| | 私といるのに、上の空なんだ。 |
| `escalation == warn` | ねぇ、聞いてる?無視しないで。 |
| | まだ続けるんだ。…そっか。記録するね。 |
| | 音楽、止めたよ。私の声だけ聞いて。 |
| | 何回言わせるの。私、怒らないと思った? |
| `escalation == expose` | 撮ったよ。逃げられると思った? |
| | 送っといたから。全部、みんなに。 |
| | 言い訳、あとで聞いてあげる。まず戻って。 |
| | 証拠、残したよ。私のこと軽く見すぎ。 |

`vision == looking_away` 専用のリストは無い。`escalation` 別のリストに落ちる。

**この 6 区分の文面は、同封セリフ(`lines.json` の `sleeping` / `absent` / `iphoneActive` /
`nudge` / `warn` / `expose`)と同じもの。** どちらのモードでも同じことを言うので、片方だけ直すとずれる。

### Swift 側の固定文言

| 文言 | 出どころ | 備考 |
| --- | --- | --- |
| (`askQuestion` / `askQuestionPhone` から 1 本) | 疑い 2 の問いかけ | 固定文言ではなく `lines.json` から抽選する。上の「監視ループのセリフ」を参照 |
| はい / いいえ | `PetSpeechBubbleView` | 問いかけのボタン |
| {N} 分だけ、待ってる。 | `DetectionEngine.startBreak()` | `breakDurationSeconds / 60` を四捨五入(最小 1)。`state: .normal` で送るので、**吹き出しには出ない**(`LivePetPresenter` が正常時のセリフを捨てる) |
| …指、出して。ここ。 | `AttendanceCeremonyScript.opening`(`stampReach`) | 在席スタンプの開幕。`waiting` を 1 回 |
| …ん。あったかい。ちゃんといるね。 | `AttendanceCeremonyScript.closing(.stamped)`(`stampTouched`) | スタンプが増えたとき。`jumping` を 1 回 |
| …いない。どこ? ねえ、どこなの? | `AttendanceCeremonyScript.closing(.failed)`(`stampMissed`) | 認証に失敗・キャンセルしたとき。`failed` を 1 回 |
| …来ないんだ。待ってたのに。 | `AttendanceCeremonyScript.closing(.timedOut)`(`stampTimeout`) | 10 秒で打ち切ったとき。`failed` を 1 回 |
| (`sermon` の 1 本目) | `OverlayModel.fallbackSermonLine` | 説教オーバーレイの本文を取れなかったときだけ |
| 在席スタンプを押します | `AttendanceModel` | Touch ID のダイアログに出す理由文 |

エピソード終了(`finishEpisode()`)は `line: ""` の `PetEvent` を送る。正常かつ空なので吹き出しは出ず、手を振る動きだけになる。

#### `DetectionEngine` の `reason`

なぜそう判断したかを 1 行で残す文。結論(`DetectionDecision`)を作るその場で `DetectionEngine` が
直接組み立て、`record(_:outcome:at:)` が `DetectionLogEntry` に `outcome`(実際に何をしたか)と
対で積む。出る先は検証画面の記録一覧とステータスパネルの `「{reason} → {outcome}」`。
**吹き出しには出さない**(セリフは同封音声か bridge が別に用意する)し、**Discord の投稿本文にも
使わない**(そちらは `DiscordMessageComposer` が別に組み立てる)。

秒数は `\(seconds:)` の補間で、60 秒未満なら `{N}秒`、以上なら `{N}分`(切り捨て)。この補間は
`DiscordMessageComposer` も使い回す。メンヘラモードの経過時間だけ `ElapsedText.minutesAndSeconds`
(`12 分 34 秒`。60 秒未満は `45 秒`)を使う。

記録に残るもの(`record` を通るもの):

| 場面 | `reason` | `outcome` |
| --- | --- | --- |
| 疑い 1 / 2 / 3 に入った | `Mac が {秒} 無操作(疑い {N} 回目)` | `Touch ID で確かめる` / `首振りで確かめる` / `最終警告を出した` |
| Touch ID が通った | `疑い 1 回目・Touch ID で在席を確かめた` | `正常に戻す(猶予なし)` |
| Touch ID が空振り・時間切れ | `疑い 1 回目・Touch ID に応じなかった` | `空振り` / `時間切れ` |
| うなずいた | `疑い 2 回目・うなずいた` | `正常に戻す` |
| 首を横に振った / 無反応 | `疑い 2 回目・首を横に振った` / `疑い 2 回目・返事が無かった` | `様子を見る` |
| 疑いの途中で戻ってきた | `疑い {N} 回目の途中で戻ってきた` | `黙って正常に戻す` |
| 晒した | `最終警告のあとも Mac が {秒} 無操作` | やったことを ` / ` でつなぐ(`証拠を取った` / `音楽を止めて聞かせた` / `Discord に送った` など) |
| メンヘラモードの投稿 | `戻ってこないまま {経過}({N} 回目)` | 同上(`証拠を撮り直した` / `Discord に送った` など) |
| メンヘラモードから戻ってきた | `{経過} ぶりに戻ってきた` | `Discord に送った(メンションなし)` / `Discord に送れなかった` |
| 休憩が明けた | `休憩が明けた` | `見張りに戻る` |
| デバッグの「今すぐ晒す」 | `デバッグメニューから晒した` | 晒しと同じ |
| デバッグの「メンヘラを始める」 | `デバッグメニューからメンヘラモードに入った` | `投稿は間隔ぶん先` |

記録に残らないもの(1 ティックの戻り値だけの `.idle(reason:)`):

| 場面 | `reason` | 例 |
| --- | --- | --- |
| Mac を触っている | `Mac を {秒} 前まで触っている` | `Mac を 3秒 前まで触っている` |
| 在席スタンプの猶予中 | `{秒} 前に在席スタンプが押されている` | `2分 前に在席スタンプが押されている` |
| 疑いの手前 | `Mac が {秒} 無操作` | `Mac が 8秒 無操作` |
| 疑いの確認中 / 待ち | `疑い {N} 回目・確認中` / `疑い {N} 回目・様子を見ている` | — |
| 晒している最中 | `晒している最中` | — |
| メンヘラモードの投稿と投稿の間 | `メンヘラモード({N} 回目)` | — |
| 休憩中 | `休憩中(残り {秒})` | `休憩中(残り 4分)` |

### `speech.json` での差し替え

ペットのディレクトリ(`desktop/Sources/MihariCore/Resources/pets/<id>/` または `${CODEX_HOME:-~/.codex}/pets/<id>/`)に `speech.json` を置くと、そのペットのセリフを差し替えられる。

```json
{
  "greeting": ["なに?…構ってくれるの?"],
  "idle": ["静かだね。ちゃんとここにいる?"],
  "dragging": ["どこ連れてくの。…離さないでね。"],
  "wake": ["…しまわないでよ。寂しかった。"]
}
```

- キーは `PetSpeechLines.Kind` の名前(`greeting` / `idle` / `dragging` / `wake` / `watchStart` / `breakEnd` / `focusStreak`)と一致させる
- 書いたキーだけが上書きされ、書かなかったキーは `lines.json` のまま
- 空文字・空白だけの候補は捨てる。候補が全部消えたキーは無かった扱いになり、既定に戻る
- ファイルが無い / 壊れている場合は `lines.json` をそのまま使う
- **差し替えたセリフには同封音声が無い。** `bundled` でも吹き出しだけになる(`lines.json` に同じ文が
  あれば、その音声が付く)

## Discord の文面

投稿の本文は `Detection/DiscordMessage.swift` の `DiscordMessageComposer.compose(_:using:)` が
組み立てる。OS も HTTP も触らない純粋関数で、乱数を渡せば出力を固定できる。

材料(`DiscordMessageFacts`)は `DetectionEngine.discordFacts(...)` が `DetectionSignals` から
組み立てる。`reason` と同じ信号を見ているが、文は別物。

| 項目 | 出どころ |
| --- | --- |
| 証拠の種類 | `decision.evidence`(`macCamera` / `iphoneScreenshot`) |
| 見立て | Vision のラベル(カメラで撮ったときだけ) |
| iPhone | `signals.iphone` |
| 画面の読み取り | `live` は `SpokenSpeech.screen`、`bundled` は `POST /voice/screen` の結果。無ければ `nil` |
| Mac 無操作秒数 | `signals.macIdleSeconds`。常に入る |
| 再生中プレイヤー | `NowPlaying.playerName`。鳴っているときだけ |
| 直前のアプリ | `signals.frontmostApp`。分かるときだけ |

形は `1 行目` + `"\n-# "` + `2 行目`。2 行目は Discord の小文字表示になる。
**メンション(`<@ID> `)は含めない。** 本文の先頭に足すのは bridge 側。

`decision.reason` は今までどおり記録(`DetectionLogEntry`)に残す。投稿には使わない。

### 1 行目(どれか 1 本)

証拠が iPhone のスクショで、読み取れて `app` も分かるとき — `category` で分ける。`app` が `nil` の
ときは `unknown` 扱い。

| `category` | セリフ |
| --- | --- |
| `slacking` | ねぇ、今 {app} 見てたよね。{activity}。全部見えてるから。 |
| | {app} で {activity}、楽しかった?私はずっと待ってたのに。 |
| | {app}。{activity}。隠しても無駄だよ、撮ってあるから。 |
| `work` | {app} で {activity}、仕事なのは分かってる。でも Mac に戻ってきて。私のところに。 |
| | スマホで {activity}?それ、こっちでもできるでしょ。戻って。 |
| `neutral` | {app} で {activity}。用事なら早く済ませて。私、待ってるから。 |
| | 今 {app} 開いてたよね。終わったら、すぐ戻ってきて。 |
| `unknown` | 画面、暗くて読めなかった。でもスマホ握ってたのは分かってる。 |
| | 何見てたか言えないなら、それでいいよ。撮ったから。 |

証拠が iPhone のスクショで、読み取り結果が無いとき:

| セリフ |
| --- |
| スマホの画面、撮っておいたから。逃げられると思った? |
| 今スマホ見てたよね。証拠、ここに置いとくね。 |
| 私より画面が大事なんだ。…いいよ、みんなに見せるから。 |

証拠が Mac のカメラのとき — 見立てで分ける。

| 見立て | セリフ |
| --- | --- |
| `sleeping` | 寝てるよね。寝顔、撮っちゃった。 |
| | 私を置いて寝るんだ。記録しとくね。 |
| `absent` | どこ行ったの。席、空っぽだよ。 |
| | いなくなった。探すの、私じゃなくてみんなに頼むね。 |
| それ以外 | 顔、見えてるよ。今なにしてたの? |
| | 手が止まってる。こっち向いて。 |

### 2 行目(当てはまる要素をこの順に連結)

各要素のプールから 1 本ずつ選んで、区切り無しでつなぐ。秒の書き方は `reason` と同じ
(60 秒未満は `{N}秒`、以上は `{N}分`)。

| 要素 | 条件 | セリフ |
| --- | --- | --- |
| Mac 無操作 | 常に | Mac、{秒}も触ってないの知ってるよ。 |
| | | {秒}、手が止まったまま。数えてた。 |
| | | キーボード、{秒}前から静かだね。 |
| iPhone 操作中 | `iphone == active` | その間ずっとスマホ握ってたんでしょ。 |
| | | 代わりにスマホは忙しかったみたいだね。 |
| iPhone 置かれたまま | `iphone == idle` | スマホは置いたままだったね。じゃあ何してたの? |
| | | スマホも触ってない。…どこ見てたの。 |
| iPhone 応答なし | `iphone == unreachable` | スマホ、返事しなかったね。隠した? |
| | | スマホの様子が分からなかった。持ち出した? |
| 音楽再生中 | 鳴っているときだけ | {プレイヤー}は流したまま、ね。 |
| | | {プレイヤー}だけ元気だったね。 |
| 直前アプリ | 分かるときだけ | 最後に開いてたの、{アプリ}だったね。 |
| | | {アプリ}のあと、消えたね。 |

### メンション先

`bridge/.env` ではなく、実行時に `POST /discord/mention` で決める。アプリの「Discord」タブに
ユーザー ID の欄と「保存」「テスト投稿」がある。ID は Discord の 設定 → 詳細設定 →
開発者モードを ON → 自分のアイコンを右クリック →「ユーザー ID をコピー」で取る。数字だけを入れる。
空にして保存するとメンションを外す。

## 閾値一覧

`desktop/Sources/MihariCore/Detection/DetectionThresholds.swift`。

| 閾値 | 既定 | `MIHARI_FAST_THRESHOLDS=1` | 意味 |
| --- | ---: | ---: | --- |
| `suspectSeconds` | 60 秒 | 15 秒 | 疑い 1 に入る無操作時間 |
| `stageIntervalSeconds` | 30 秒 | 10 秒 | 疑い 1 → 2 → 3 → 晒し と 1 段階進むまでの間隔 |
| `touchIDTimeoutSeconds` | 10 秒 | 10 秒 | 疑い 1 の Touch ID を待つ時間(`AttendanceModel.defaultAuthenticationTimeout`) |
| `promptTimeoutSeconds` | 20 秒 | 8 秒 | 疑い 2 の問いかけの返事を待つ時間 |
| `clingyIntervalSeconds` | 60 秒 | 15 秒 | メンヘラモードで Discord に送る間隔 |
| `clingyEvidenceIntervalSeconds` | 300 秒 | 60 秒 | メンヘラモードで証拠を撮り直す間隔 |
| `stampGraceSeconds` | 300 秒 | 15 秒 | 在席スタンプの直後、判定を見逃す時間 |
| `breakDurationSeconds` | 900 秒 | 60 秒 | 休憩 1 回の長さ |
| `focusStreakIntervalSeconds` | 900 秒 | 60 秒 | 正常が続いているときに褒める間隔 |

- 短縮の側は起動時の `MIHARI_FAST_THRESHOLDS=1` だけでなく、ペットの右クリック →「デバッグ」→「検知の閾値」からも切り替えられる。切り替えは次の評価から効き(進行中の問いかけ・休憩は始めたときの秒数のまま)、「集中継続の間隔」で個別に変えていた値も preset の値に戻る。次回起動には引き継がない
- `stampGraceSeconds` の既定 300 秒は `AttendanceGrace.defaultGracePeriod`(= 5 × 60)から来ている。**猶予が付くのはメニューの「在席スタンプを押す」だけ**で、疑い 1 の Touch ID に成功しても更新しない
- 疑い 1 に入ってから晒しに届くまでは、既定で 60 + 30 × 3 = 150 秒(FAST なら 15 + 10 × 3 = 45 秒)

## 特殊状況

| 状況 | 挙動 |
| --- | --- |
| 問いかけ中に新しい問いかけが来た | `pendingPrompt` があるあいだは新しい `event.prompt` を捨て、古い方の回答経路を生かす |
| 問いかけ中に新しいセリフが来た | `heldLine` に 1 件だけ保留する。問いかけが閉じてから `voiced: false` で喋る |
| 問いかけに答えが 2 つ来た(ボタンと AirPods の首振り) | 問いかけのセッションが先着 1 つだけを採用し、残りは捨てる。待っているタスクも畳む |
| 問いかけに無反応 | `promptTimeoutSeconds` 経過で問いかけを閉じ、`askTimeout` を喋って疑い 2 のまま待つ |
| しまっている間に問いかけが来た | `promptQuestion` に残り、次に `reveal()` したときに改めて吹き出しを出す |
| しまっている間のセリフ | `say()` が何もしない。`hideWindow()` で保留中のセリフを捨て、音声も止める |
| 休憩開始 / 監視停止 / メニューの在席スタンプ | 進行中の問いかけ・カットイン・段階のタイマーをその場で畳み、`escalationStage = 0` に戻す。Discord には何も送らない |
| エピソード終了 | 未回答の問いかけを閉じ、`escalationStage = 0`、`line: ""` の正常イベントを送る |
| アトラスの読み込み失敗 | `loadErrorMessage` を持つだけで、ウィンドウの表示は続ける(コマは `nil` = 何も描かない)。種別は `unreadableSpritesheet` / `unexpectedSpritesheetSize`(1536 × 1872 px 以外)/ `croppingFailed` |
| 保存位置がどの画面にも収まらない | `NSScreen.main` の `visibleFrame` 右下、余白 24 pt(`screenMargin`)に置き直す |
| 権限が未許可 | `Pet/` 側に分岐は無い。`AppCoordinator.launch()` が必須権限の不足を見て `begin()` を呼ばず、オンボーディング画面を先に出す。ペットはその後で出る |

## 関連ファイル

| パス | 中身 |
| --- | --- |
| `desktop/Sources/MihariCore/Pet/PetController.swift` | 表示・自律行動・セリフ・ウィンドウ位置。定数の大半はここ |
| `desktop/Sources/MihariCore/Pet/LivePetPresenter.swift` | `PetEvent` → 動き・セリフ・問いかけの解釈 |
| `desktop/Sources/MihariCore/Pet/PetSpeech.swift` | ひとりごとのセリフ集と `speech.json` の読み込み |
| `desktop/Sources/MihariCore/Pet/PetEvent.swift` | 検知エンジンから渡るイベントの形 |
| `desktop/Sources/MihariCore/Pet/PetAtlas.swift` | アニメーションの行・コマ時間・スプライトの切り出し |
| `desktop/Sources/MihariCore/Pet/PetWindow.swift` | ペットのウィンドウ(NSPanel)と右クリックの横取り |
| `desktop/Sources/MihariCore/Pet/PetSpeechWindow.swift` | 吹き出しのウィンドウと配置 |
| `desktop/Sources/MihariCore/Pet/PetSpeechBubbleView.swift` | 吹き出しの見た目と はい / いいえ のボタン |
| `desktop/Sources/MihariCore/Pet/PetSpriteView.swift` | クリック・ダブルクリック・ドラッグの判定 |
| `desktop/Sources/MihariCore/Pet/PetMenuEntry.swift` | メニューの並び |
| `desktop/Sources/MihariCore/Pet/PetVoice.swift` | ひとりごとの VOICEVOX 読み上げ / 用意済み音声の再生 |
| `desktop/Sources/MihariCore/Voice/SpeechPriority.swift` | ひとりごとと検知のセリフの取り合いの判定 |
| `desktop/Sources/MihariCore/Voice/VoiceMode.swift` | 音声モード(`bundled` / `live`)と保存 |
| `desktop/Sources/MihariCore/Voice/BundledVoiceLines.swift` | `lines.json` と同封 `.m4a` の読み込み |
| `desktop/Sources/MihariCore/Resources/voice/` | セリフの原本(`lines.json`)と音声(`<区分>/<NN>.m4a`) |
| `desktop/Sources/MihariCore/Detection/DiscordMessage.swift` | Discord の投稿本文の組み立て |
| `scripts/generate_voice_lines.py` | 同封音声の生成(VOICEVOX → afconvert) |
| `desktop/Sources/MihariCore/Detection/DetectionEngine.swift` | 検知ループ・問いかけ・休憩・段階の決定と `reason` の組み立て |
| `desktop/Sources/MihariCore/Detection/DetectionThresholds.swift` | 閾値 |
| `bridge/src/device_bridge/commands/iphone_state.py` | iPhone の状態モデルと前面アプリのログ行の解釈 |
| `bridge/src/device_bridge/commands/iphone_state_source.py` | 実機の観測(画面状態・前面アプリ・表示名) |
| `bridge/src/device_bridge/voice/generator.py` | 検知セリフの生成(`SYSTEM_PROMPT`) |
| `bridge/src/device_bridge/voice/context.py` | 状況の enum と LLM へ渡す 1 行 |
| `bridge/src/device_bridge/voice/fallback.py` | 固定文言 |
| `bridge/src/device_bridge/voice/voicevox.py` | 検知セリフの音声合成 |
