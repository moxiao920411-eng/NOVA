# NOVA — 本機智慧助理 MVP

NOVA 是一個 Windows 本機優先的智慧助理雛形，目標是逐步成為可以協助控制電腦與家電的個人 AI。現在採用「本機前端 + 本機 PowerShell 後端」：前端只從 `127.0.0.1` 連線，並不是公開網站；後端保留所有權限、白名單、語音與實際操作控制。

## 目前包含

- 本機前端對話介面與 CLI 模式
- 後端監聽狀態即時映射到前端：待機、喚醒、辨識、執行結果與錯誤
- 3D 正方線條體持續旋轉；喚醒及辨識期間停止轉動
- 本機 Whisper small STT + Windows 本機 TTS 語音控制
- 自動喚醒詞：「嘿 NOVA」；喚醒後 10 秒內接收下一句指令
- 標點/空白辨識結果會丟棄；重複喚醒與重複語音命令會抑制，避免誤開瀏覽器或程式
- 語音命令由獨立工作程序執行，Ollama 或瀏覽器操作較慢時，後端監聽與前端狀態仍保持可連線
- YouTube 搜尋/播放指令：播放類語句會優先交給 Ollama 做語義分析，再把抽出的歌曲、歌手或主題交給瀏覽器代理執行；Ollama 暫時不可用時才使用備援規則
- Ollama 本機模型支援，預設 `deepseek-r1:8b`
- 中文意圖解析：開啟程式、控制家電、顯示狀態、查看習慣
- 「開啟瀏覽器」會使用 Windows 預設瀏覽器
- 「關閉瀏覽器」會依 Windows 預設 HTTP 程式關聯送出正常關閉指令
- NOVA 無法由本機工具處理的問題（例如天氣或一般資訊）會自動用預設瀏覽器搜尋
- 電腦控制採白名單：記事本、計算機、小畫家、檔案總管；應用程式名稱比對不分大小寫，也可用 `.exe` 名稱或包含名稱的說法
- Home Assistant 本機 REST 連線入口（需在 `config.json` 設定）
- 每次互動寫入 `%LOCALAPPDATA%\NOVA\events.jsonl`
- 根據重複使用時間與指令產生習慣建議
- 長期記憶代號：例如「設定代號 A 是開啟設定」，下次說「代號 A」即可套用
- 關機、刪除、關閉程式等高風險動作預設需要人工確認
- 所有資料留在本機；第一版不把對話送到外部服務

語音模式預設關閉，只有按「啟動語音」才會開啟麥克風；停止、重啟或重新整理後端不會自動收音。首次啟動語音時會在 `%LOCALAPPDATA%\NOVA\whisper` 快取 Whisper small，之後說「嘿 NOVA」，聽到回應後再說指令。STT 不依賴 Windows 語音辨識器；TTS 使用 Windows 本機語音合成。語音執行狀態會由後端事件佇列同步到前端。

首次啟動會詢問是否允許搜尋本機固定磁碟。選擇同意後，可說「搜尋檔案 報告」；搜尋只使用目前 Windows 使用者權限，結果不會上傳。

例如說「幫我開啟 YouTube」會用預設瀏覽器搜尋 YouTube；說「幫我播放小幸運」時，模型會抽出「小幸運」作為搜尋詞，再開啟 YouTube、找到結果並以適當速度點擊播放。歌曲名稱不是寫死的；瀏覽器可能因 autoplay 政策要求點一下第一個結果。

## 白名單密語

已在白名單內的程式可直接使用；要新增未授權程式時，NOVA 會先要求密語。按桌面上的「設定密語」輸入兩次密語，例如 `ABCD1234`，之後可在文字框輸入 `ABCD1234`，或在「嘿 NOVA」喚醒後直接說出密語。密語只儲存雜湊，不會寫入事件紀錄。

再次變更密語時，設定視窗會先要求輸入前次密語並按「驗證前次密語」；驗證成功後才會顯示新密語欄位。前次密語不正確就不會更新。長期記憶會自動匯出到 `%LOCALAPPDATA%\NOVA\memory.json`，前端也提供「匯出長期記憶 JSON」按鈕。該檔案只包含代號、事實與偏好欄位，不包含密語雜湊。

新增程式時建議說完整 `.exe` 路徑，例如「開啟 C:\\Apps\\Example\\Example.exe」。對已建立 Windows 開始功能表捷徑或 App Paths 登錄的桌面程式，也可以直接說程式名稱（例如「開啟 LINE」）；密語確認成功後，NOVA 只會將解析到且實際存在的 `.exe` 加入白名單並啟動。

## 長期記憶代號

輸入或說出「設定代號 A 是開啟設定」。NOVA 會把代號與原始指令儲存在本機 `config.json` 的 `MemoryAliases`，之後說「A」或「代號 A」都會展開成「開啟設定」，並繼續經過白名單檢查。

## 啟動

直接雙擊 `Start-NOVA.cmd`，它會保留一個可見的 `NOVA Backend` CMD 視窗持續監聽，並開啟 `http://127.0.0.1:24808/` 前端。即使沒有語音或指令，後端也不會因閒置自行關閉。也可以在 PowerShell 執行：

```powershell
powershell -ExecutionPolicy Bypass -File .\NOVA.ps1 -Server
```

CLI 範例：

```powershell
powershell -ExecutionPolicy Bypass -File .\NOVA.ps1 -Cli -Text "開啟記事本"
powershell -ExecutionPolicy Bypass -File .\NOVA.ps1 -Cli -Text "顯示習慣"
```

第一次啟動會在 `%LOCALAPPDATA%\NOVA` 建立設定檔。可以編輯專案內的 `config.example.json`，再把內容合併到實際設定檔。

## Ollama

請先安裝 Ollama，並在本機執行：

```powershell
ollama pull deepseek-r1:8b
ollama run deepseek-r1:8b
```

NOVA 透過 `http://127.0.0.1:11434/api/chat` 呼叫 `deepseek-r1:8b`。模型只輸出受限的意圖 JSON，所有實際操作仍由 NOVA 白名單執行。若 Ollama 尚未安裝、未啟動或模型不存在，NOVA 會自動退回內建規則解析，不會中斷桌面程式。

## Home Assistant 設定

在 `%LOCALAPPDATA%\NOVA\config.json` 設定：

```json
{
  "HomeAssistant": {
    "Enabled": true,
    "BaseUrl": "http://homeassistant.local:8123",
    "Token": "你的長期存取權杖"
  },
  "Devices": [
    {
      "Name": "客廳燈",
      "Aliases": ["客廳燈", "大廳燈"],
      "EntityId": "light.living_room",
      "Domain": "light"
    }
  ]
}
```

可使用「打開客廳燈」、「關掉客廳燈」等說法。未設定 Home Assistant 時，NOVA 只會說明尚未連線，不會假裝已控制設備。

## 規劃與安全邊界

### Phase 1：可控的本機 MVP（目前）

先打通桌面介面、意圖解析、白名單工具、家電連接器、記錄與習慣觀察。這個階段的原則是「可解釋、可撤銷、可確認」。

### Phase 2：本機模型與工具系統

加入 Ollama 等本機模型適配器，讓模型只負責理解語句與規劃；實際操作仍必須透過 NOVA 的工具白名單與權限閘門。每個工具要定義輸入 schema、風險等級、回滾方式與審計紀錄。

### Phase 3：習慣學習與自動化

從事件中抽取時間、頻率、裝置與前置條件，先生成建議，再由使用者核准成為 routine。未經核准不自動執行；涉及門鎖、瓦斯、付款、刪除資料等永遠需要確認。

### Phase 4：長期可靠性

補上 Windows 工作排程、斷線重試、權限分級、加密秘密、測試、撤銷紀錄與可匯出/刪除的個人資料管理。

## 下一步建議

1. 先確認本機 MVP 可啟動，並測試「開啟記事本」與「顯示習慣」。
2. 設定一個 Home Assistant 裝置，確認家電控制鏈路。
3. 再決定是否安裝本機模型；不建議一開始就讓模型直接執行任意 shell 指令。
