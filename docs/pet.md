# ペットの細かい挙動とセリフ集

デスクトップペットが「いつ・どう動き・何を喋るか」を、数値と全セリフまで書き出したもの。README の「ペット」節が概要で、こちらが詳細。

ソース: `desktop/Sources/MihariCore/Pet/` ほか。ここに書いた数値・確率・セリフはすべてコード上の定数なので、変えるときはこの md も直す。

## 状態と動き

検知エンジンの `PetEvent` を `LivePetPresenter.present(_:)` が解釈し、「固定するアニメーション」「1 回だけ挟むアニメーション」「吹き出しに出すセリフ」の 3 つに落とす。

| 検知の状態 | 固定アニメーション | 一度きりの再生 | 跳ねる条件 |
| --- | --- | --- | --- |
| 正常 `.normal` | なし(自律行動に戻る) | 非 normal から戻った瞬間だけ `waving` | — |
| 疑い `.suspected` | `waiting` | なし | — |
| サボり確定 `.confirmed` | `failed` | `jumping` | `escalationStage` がこのエピソードの最大値を超えたときだけ。3→2→3 の往復では跳ねない |
| 問いかけ中 | `waiting` | — | 検知の状態より優先して `waiting` に固定する |
| 監視停止中 / 休憩中 | — | — | `setFrozen(true)`。コマ送りを止め、`idle` の 0 コマ目で静止 |

正常に戻ると、そのエピソードで見た最大段階(`maxConfirmedStage`)を忘れる。

セリフを出すのは `state != .normal` かつ `line` が空でないときだけ。正常のイベントに乗ってきたセリフは吹き出しに出さない。

### escalationStage

`DetectionEngine.petStage(_:)` が決める。`PetEvent` は 0 未満を 0 に丸める。

| 段階 | 条件 | 意味 |
| ---: | --- | --- |
| 0 | 上記以外(正常・エピソード終了・休憩開始) | 何もしていない |
| 1 | `.suspected` | 疑っているだけ |
| 2 | `.confirmed` かつ evidence == `.none` | クールダウン中。撮り直さず声だけかける |
| 3 | `.confirmed` かつ evidence あり | 撮って Discord へ送る |

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
4. 歩行は向きをランダムに決め、80〜240 pt(`walkDistanceRange`)を 60 pt/秒(`walkSpeed`)で進む。1 コマごとに `min(walkSpeed × コマ時間, 残り距離)` だけ動く
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

右クリックメニュー(`PetContextMenu`)とメニューバーの「ペット」(`PetMenuContent`)は `PetMenuEntries.make` から作るので中身が同じ。現行は 8 項目。

| 項目 | 内容 |
| --- | --- |
| 監視を止める / 監視を再開する | `stopWatching()` / `startWatching()`。「止める」は休憩に触れない |
| 在席スタンプを押す | `stampAttendance()`。Touch ID で在席を証明する |
| 休憩する(15 分) / 休憩を終える | `startBreak()` / `endBreak()` |
| Discord 設定… | `openDiscordSettings()` |
| 権限の確認… | `openPermissions()` |
| サイズ(サブメニュー) | 小 = 0.5 / 中 = 0.75 / 大 = 1.0。チェック式 |
| 声を出す | チェック式。`pet.setVoiceEnabled(!isVoiceEnabled)` |
| 状態パネルを表示 | チェック式。`toggleStatusPanel()` |

区切り線は「休憩する」の後と「権限の確認…」の後の 2 本。`autoenablesItems = false`。

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

見た目の寸法(`PetSpeechBubbleView`): margin 8 pt、角丸 14 pt、しっぽ 14 × 9 pt、ボタン領域 24 pt(間隔 6 pt)、テキスト幅の上限 240 pt、テキストの余白 縦 9 pt / 横 14 pt、フォント `.system(size: 14, weight: .medium)`。

## 声

話者は冥鳴ひまり(VOICEVOX の話者 14)で固定。経路は 2 本ある。

| 経路 | 作る場所 | 鳴らす場所 | 優先度 |
| --- | --- | --- | --- |
| ペットのひとりごと | `PetSpeech.swift` のビルトイン | `PetVoice` が VOICEVOX を直接叩く | `.chatter` |
| 検知のセリフ | `bridge/`(Claude API → VOICEVOX) | 検知側の `SpeechPlayer` | `.detection` |

`SpeechPlaybackArbiter.decide` の判定:

- `.detection` は常に `play`。鳴っているものを止めてでも鳴らす
- `.chatter` は、`.detection` が鳴っていれば `drop`。溜めて後から鳴らすことはしない

検知由来のセリフと在席スタンプの返事は `say(..., voiced: false)` で出すので、`PetVoice` は読み上げない(吹き出しだけ)。

### PetVoice(ひとりごと側)の定数

| 項目 | 値 |
| --- | --- |
| エンドポイント | `http://127.0.0.1:50021`(固定。環境変数での上書き無し) |
| 話者 | 14 |
| `audio_query` のタイムアウト | 2 秒 |
| `synthesis` のタイムアウト | 8 秒 |
| 失敗後に接続を試みない時間 | 30 秒(`retryInterval`) |

合成に失敗してもログに残すだけで、UI には何も出さない。`nil` を返すので吹き出しの表示時間は文字数ベースのまま。合成の待ち時間中に次のセリフが来たら、古い音声は鳴らさない(`generation` で判定)。

メニューの「声を出す」を切ると `voice.speak` を呼ばなくなり、再生中の音声もその場で止まる。**この設定はひとりごとにだけ効く。** 検知のセリフは別経路なので止まらない。

### bridge(検知側)の定数

| 項目 | 値 |
| --- | --- |
| モデル | `claude-haiku-4-5`(`MIHARI_LLM_MODEL` で上書き) |
| 生成のタイムアウト | 4.0 秒。超えたら固定文言へ |
| `max_tokens` | 200 |
| VOICEVOX の話者 | 14(`MIHARI_VOICEVOX_SPEAKER` で上書き) |
| VOICEVOX のベース URL | `http://127.0.0.1:50021`(`MIHARI_VOICEVOX_URL` で上書き) |
| 合成のタイムアウト | 10.0 秒。疎通確認は 1.5 秒 |
| 音声キャッシュ | `(text, speaker)` をキーにした LRU、容量 64 |

固定文言に落ちる条件: API キー未設定 / `APITimeoutError` / `RateLimitError` / `APIStatusError` / `APIConnectionError` / 空応答。速度・ピッチは指定せず、`audio_query` の既定をそのまま `synthesis` へ渡す。

## セリフ集

### ひとりごと(`PetSpeech.swift` のビルトイン)

`PetSpeechLines.builtIn` に埋め込んである。種類ごとに `randomLine(for:)` で 1 つ選ぶ。同梱ペット `mauve` には `speech.json` が無いので、現状は常にこれが使われる。すべて `voiced: true` なので VOICEVOX で読み上げる。

#### `greeting` — クリックされたとき

`PetController.wave()`。シングルクリックのたびに必ず 1 つ喋り、続けて `waving` を再生する。

| セリフ |
| --- |
| こんにちは。 |
| 呼びました? |
| なんでしょう? |
| はい、ここに。 |
| お呼びですか? |
| ご用ですか? |
| 見ていましたよ。 |
| 何かお手伝いできますか? |
| 今日もよろしくお願いします。 |
| そんなに触ると、くすぐったいです。 |

#### `idle` — 待機に入ったときのひとりごと

`sayIdleLineIfNeeded()`。`beginIdle()` のたびに抽選する。条件は 3 つとも満たしたときだけ:

- `isAwake` である
- 直前のセリフから 20 秒(`idleSpeechInterval`)以上あいている
- 確率 20%(`idleSpeechProbability`)を引いた

| セリフ |
| --- |
| …。 |
| ふぅ。 |
| 今日はいい天気ですね。 |
| 退屈です。 |
| 静かですね。 |
| …ねむい。 |
| 何か起きるまで、ここにいます。 |
| お仕事、進んでいますか? |
| 水分、とりました? |
| 少し休みませんか? |
| 外は静かですね。 |
| 背伸び… |
| …あ、ごめんなさい、ぼーっとしていました。 |
| この辺り、落ち着きます。 |

#### `dragging` — ドラッグを始めたとき

`beginDrag()`。ドラッグ開始のたびに確率 30%(`dragSpeechProbability`)。

| セリフ |
| --- |
| わっ。 |
| どこへ行くんです? |
| 揺れます… |
| 持ち上げないでください。 |
| ゆっくりお願いします。 |
| そこでいいですか? |
| 高いところは、ちょっと… |

#### `wake` — 起こされたとき

`reveal()`。`isAwake` が false → true に変わったときだけ。すでに出ているペットに `reveal()` が来ても喋らない。

| セリフ |
| --- |
| おはようございます。 |
| ここにいますよ。 |
| 戻りました。 |
| 起きました。 |
| 呼ばれた気がして。 |
| はい、起きていますよ。 |
| また会えましたね。 |

#### `watchStart` — 監視が始まったとき

`LivePetPresenter.setMonitoring(_:)`。`.watching` になり、かつ直前が `.watching` でも `.onBreak` でもないときだけ。

| セリフ |
| --- |
| 作業開始ですね。ここから見ていますよ。 |
| 監視、始めます。作業に集中してくださいね。 |
| 作業スタートです。サボったら分かりますからね。 |
| いまから見張ります。がんばってください。 |

#### `breakEnd` — 休憩が明けて監視に戻ったとき

同じく `setMonitoring(_:)`。`.watching` になり、かつ直前が `.onBreak` のとき。

| セリフ |
| --- |
| 休憩はおしまいです。作業に戻りましょう。 |
| そろそろ戻りましょうか。見ていますよ。 |
| 休憩おわりです。続きをどうぞ。 |

### 未使用キー

`running` / `needsInput` / `ready` / `blocked` は旧デスクトップペット由来のキーで、**現在どこからも呼ばれない。** `speech.json` の互換のために定義とセリフだけ残してある。書いても読み込まれるだけで、どこでも喋らない。

#### `running`

| セリフ |
| --- |
| デバイスを探しています… |
| 少々お待ちを。 |
| いま確認しています。 |
| もう少しかかります。 |
| 順番に見ています。 |
| 接続を調べています… |
| もうすぐ終わります。 |
| 急かさないでくださいね。 |
| まだ探しています。 |

#### `needsInput`

| セリフ |
| --- |
| 確認をお願いします。 |
| どうしますか? |
| お返事を待っています。 |
| ここで止まっています。 |
| 指示をください。 |
| 続けてもいいですか? |
| 決めてもらえますか? |

#### `ready`

| セリフ |
| --- |
| 終わりました。 |
| 新しいデバイスが見えました! |
| お待たせしました。 |
| できました。 |
| 準備できました。 |
| 見つけましたよ。 |
| はい、どうぞ。 |
| うまくいきました。 |

#### `blocked`

| セリフ |
| --- |
| うまくいきませんでした… |
| エラーが出ています。 |
| もう一度試してみますか? |
| ここで詰まってしまいました。 |
| つながりませんでした… |
| 少し休んでから、もう一度どうぞ。 |
| ケーブルは挿さっていますか? |
| 見つかりませんでした。 |

### 検知セリフ(bridge が生成)

疑い・確定のたびに、Swift 側が `SpeechRequest` を bridge へ投げ、返ってきた 1 文をペットに喋らせる。生成できなければ `decision.reason` をそのまま吹き出しに出す(その場合は「喋れなかった」と記録が残る)。

`bridge/src/device_bridge/voice/generator.py` の `SYSTEM_PROMPT`:

```
あなたは macOS 常駐アプリ「Mihari」のマスコットです。
ユーザーがサボっているのを見つけて話しかけます。

守ること:
- 出力はセリフ本文のみ。前置き・説明・鉤括弧・絵文字は付けない。
- 1〜2 文、合計 60 文字以内。読み上げるので短くする。
- 皮肉混じりだが、人格否定・侮辱・脅迫はしない。あくまで軽口。
- 与えられた状況に具体的に触れる。毎回違う言い回しにする。
- 日本語で書く。
```

ユーザープロンプトは `SpeechContext.describe()` が作る 1 行。項目は「、」でつなぐ。

| 位置 | 項目 | 内容 |
| ---: | --- | --- |
| 1 | `Mac が {N}秒 無操作` / `Mac が {N}分 無操作` | 60 秒未満は秒、以上は分(切り捨て) |
| 2 | `直前に開いていたのは {アプリ名}` | `frontmost_app` があるときだけ挟む |
| 3 | `iPhone は{触っている / 置かれたまま / 応答なし}` | |
| 4 | `様子は{寝ている / よそ見 / 席にいない / 不明}` | |
| 5 | `当たりの強さは{軽め / 強め / 最大}` | |

例: `Mac が 2分 無操作、直前に開いていたのは Slack、iPhone は触っている、様子は不明、当たりの強さは軽め`

`situation` の enum と Swift 側の対応:

| フィールド | 値 | 説明 | Swift 側の条件 |
| --- | --- | --- | --- |
| `escalation` | `nudge` | まだ疑っているだけ。軽く声をかける | `.suspected`(= 段階 1) |
| | `warn` | サボり確定。音楽を止めて話を聞かせる段階 | `.confirmed` かつ evidence == `.none`(= 段階 2) |
| | `expose` | 証拠を Discord に晒す段階 | `.confirmed` かつ evidence あり(= 段階 3) |
| `iphone` | `active` | 画面が点いていて触っている | 証拠は iPhone のスクリーンショット |
| | `idle` | 画面が消えている | 証拠は Mac のカメラ |
| | `unreachable` | 圏外・スリープ・未ペアリングなど | 証拠は Mac のカメラ |
| `vision` | `sleeping` | | `VisionLabel.asleep` |
| | `looking_away` | | `VisionLabel.lookingAway` |
| | `absent` | | `VisionLabel.absent` |
| | `unknown` | 判定していない、または判定できなかった | `VisionLabel.none` |

未知の値は既定(`nudge` / `unreachable` / `unknown`)に倒す。`vision` は Mac のカメラで撮ったときだけ付き、判定そのものには使わずセリフと Discord の文面に添えるだけ。

### 固定文言(`bridge/src/device_bridge/voice/fallback.py`)

LLM が使えない・失敗した・遅すぎたときの保険。`fallback_line()` が候補から 1 つランダムに選ぶ。

選ぶ順(`_candidates()`。上から順に、当てはまった時点で確定):

1. `vision == sleeping`
2. `vision == absent`
3. `iphone == active`
4. それ以外は `escalation` 別のリスト

| 状況 | 文言 |
| --- | --- |
| `vision == sleeping` | 寝てますね。今、はっきり寝顔でしたよ。 |
| | おやすみのところ失礼します。まだ作業中のはずですが。 |
| | まぶた、完全に閉じてました。記録しておきますね。 |
| `vision == absent` | 誰もいませんね。どこ行きました？ |
| | 席、空っぽですよ。戻ってくる気ありますか？ |
| | 無人の椅子を見つめています。 |
| `iphone == active` | パソコンほったらかしでスマホですか。手元、見えてますよ。 |
| | その画面、あとで共有されても大丈夫なやつですか？ |
| | スマホの方が楽しいのは分かりますけど、こっちも見てますからね。 |
| `escalation == nudge` | 手が止まってますよ。ちょっと休憩しました？ |
| | そろそろ戻ってきませんか。待ってますよ。 |
| | 静かですね。まだ起きてます？ |
| `escalation == warn` | さすがに止まりすぎです。いったん話を聞いてください。 |
| | だいぶ放置されてますね。このままだと記録に残りますよ。 |
| | はい注目。手が完全に止まってます。 |
| `escalation == expose` | はい、証拠いただきました。共有しておきますね。 |
| | ここまでくると黙っていられません。みんなに見てもらいましょう。 |
| | 記録しました。あとで言い訳を考えておいてください。 |

`vision == looking_away` 専用のリストは無い。`escalation` 別のリストに落ちる。

### Swift 側の固定文言

| 文言 | 出どころ | 備考 |
| --- | --- | --- |
| 休憩中? | `DetectionEngine.breakQuestion` | 疑いに入った瞬間だけ出す問いかけ |
| はい / いいえ | `PetSpeechBubbleView` | 問いかけのボタン |
| {N} 分休むね | `DetectionEngine.startBreak()` | `breakDurationSeconds / 60` を四捨五入(最小 1)。`state: .normal` で送るので、**吹き出しには出ない**(`LivePetPresenter` が正常時のセリフを捨てる) |
| 在席、確認したよ | `AppCoordinator.stampAttendance()` | スタンプが増えたとき。`voiced: false` |
| 確認できなかった… | 同上 | スタンプが増えなかったとき。`voiced: false` |
| サボりが確定した。音楽は止めた。ここで最後まで聞いてから戻ってくること。 | `OverlayModel.fallbackSermonLine` | 説教オーバーレイの本文を bridge から取れなかったときだけ |
| 在席スタンプを押します | `AttendanceModel` | Touch ID のダイアログに出す理由文 |

エピソード終了(`finishEpisode()`)は `line: ""` の `PetEvent` を送る。正常かつ空なので吹き出しは出ず、手を振る動きだけになる。

#### `DetectionJudge` の `reason`

bridge がセリフを返せなかったときの代わりの文であり、そのまま Discord の投稿本文にも使う(固定のテンプレートは無い)。秒数は 60 秒未満なら `{N}秒`、以上なら `{N}分`(切り捨て)。

| 状態 | 組み立て | 例 |
| --- | --- | --- |
| 正常(何もしない) | `Mac を {秒} 前まで触っている` | `Mac を 3秒 前まで触っている` |
| 正常(スタンプ直後) | `{秒} 前に在席スタンプが押されている` | `2分 前に在席スタンプが押されている` |
| 正常(疑いの手前) | `Mac が {秒} 無操作` | `Mac が 8秒 無操作` |
| 疑い | `Mac が {秒} 無操作` | `Mac が 30秒 無操作` |
| 確定(クールダウン中) | `{秒} 前に証拠を取ったばかり` | `40秒 前に証拠を取ったばかり` |
| 確定 | 下記を ` / ` でつなぐ | `画面を 15秒 見ていない / Mac が 1分 無操作 / iPhone は応答なし` |

確定時に並べる要素(この順):

1. `画面を {秒} 見ていない` — 「見ていない」が続いたことが確定の理由のときだけ
2. `Mac が {秒} 無操作` — 常に入る
3. `iPhone は操作中` / `iPhone は置かれたまま` / `iPhone は応答なし`
4. `{プレイヤー名} が再生中` — 音楽が鳴っているときだけ
5. `直前は {アプリ名}` — 前面のアプリが分かるときだけ

### `speech.json` での差し替え

ペットのディレクトリ(`desktop/Sources/MihariCore/Resources/pets/<id>/` または `${CODEX_HOME:-~/.codex}/pets/<id>/`)に `speech.json` を置くと、そのペットのセリフを差し替えられる。

```json
{
  "greeting": ["こんにちは。", "呼びました?"],
  "idle": ["…。", "退屈です。"],
  "dragging": ["わっ。"],
  "wake": ["おはようございます。"]
}
```

- キーは `PetSpeechLines.Kind` の名前と一致させる
- 書いたキーだけが上書きされ、書かなかったキーは既定のまま
- 空文字・空白だけの候補は捨てる。候補が全部消えたキーは無かった扱いになり、既定に戻る
- ファイルが無い / 壊れている場合はビルトインをそのまま使う

## 閾値一覧

`desktop/Sources/MihariCore/Detection/DetectionThresholds.swift`。

| 閾値 | 既定 | `MIHARI_FAST_THRESHOLDS=1` | 意味 |
| --- | ---: | ---: | --- |
| `suspectSeconds` | 12 秒 | 10 秒 | 疑いに入る無操作時間 |
| `confirmSeconds` | 30 秒 | 25 秒 | サボり確定に入る無操作時間 |
| `gazeWatchSeconds` | 6 秒 | 5 秒 | カメラで視線を見始める無操作時間 |
| `notLookingDurationSeconds` | 15 秒 | 8 秒 | 「画面を見ていない」が続いたら確定にする長さ |
| `gazeFreshnessSeconds` | 10 秒 | 10 秒 | 視線の観測をいつまで有効と見なすか |
| `stampGraceSeconds` | 300 秒 | 15 秒 | 在席スタンプの直後、判定を見逃す時間 |
| `cooldownSeconds` | 180 秒 | 30 秒 | 証拠を撮り直さない間隔 |
| `breakDurationSeconds` | 900 秒 | 60 秒 | 休憩 1 回の長さ |
| `promptTimeoutSeconds` | 20 秒 | 8 秒 | 「休憩中?」の返事を待つ時間 |

- `suspectSeconds` / `confirmSeconds` / `gazeWatchSeconds` の既定は **一時的に短縮中**。本来は 120 / 300 / 60
- `stampGraceSeconds` の既定 300 秒は `AttendanceGrace.defaultGracePeriod`(= 5 × 60)から来ている
- `confirmSeconds` は `max(suspectSeconds, confirmSeconds)` に丸める。疑いより先に確定することはない
- `minimumIdleSeconds` = `min(suspectSeconds, gazeWatchSeconds)`。これ未満の無操作では判定を始めない

## 特殊状況

| 状況 | 挙動 |
| --- | --- |
| 問いかけ中に新しい問いかけが来た | `pendingPrompt` があるあいだは新しい `event.prompt` を捨て、古い方の回答経路を生かす |
| 問いかけ中に新しいセリフが来た | `heldLine` に 1 件だけ保留する。問いかけが閉じてから `voiced: false` で喋る |
| 問いかけに答えが 2 つ来た(ボタンと AirPods の首振り) | `BreakPromptSession.claim` で先着 1 つだけを採用し、残りは捨てる |
| 問いかけに無反応 | `promptTimeoutSeconds` 経過で問いかけを閉じ、監視を続ける(「いいえ」と同じ扱い) |
| しまっている間に問いかけが来た | `promptQuestion` に残り、次に `reveal()` したときに改めて吹き出しを出す |
| しまっている間のセリフ | `say()` が何もしない。`hideWindow()` で保留中のセリフを捨て、音声も止める |
| 休憩開始 | カメラ(`gazeMonitor`)を止め、`gaze = .none`、`escalationStage = 0` |
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
| `desktop/Sources/MihariCore/Pet/PetVoice.swift` | ひとりごとの VOICEVOX 読み上げ |
| `desktop/Sources/MihariCore/Voice/SpeechPriority.swift` | ひとりごとと検知のセリフの取り合いの判定 |
| `desktop/Sources/MihariCore/Detection/DetectionEngine.swift` | 検知ループ・問いかけ・休憩・段階の決定 |
| `desktop/Sources/MihariCore/Detection/DetectionJudge.swift` | サボり判定と `reason` の組み立て |
| `desktop/Sources/MihariCore/Detection/DetectionThresholds.swift` | 閾値 |
| `bridge/src/device_bridge/voice/generator.py` | 検知セリフの生成(`SYSTEM_PROMPT`) |
| `bridge/src/device_bridge/voice/context.py` | 状況の enum と LLM へ渡す 1 行 |
| `bridge/src/device_bridge/voice/fallback.py` | 固定文言 |
| `bridge/src/device_bridge/voice/voicevox.py` | 検知セリフの音声合成 |
