# NInfer Qwen3.8-27B / RTX 2080 Ti 22GB — Windows 懶人安裝

此文件對應 native Windows SM75 production package。

## 最簡單安裝

1. 完整解壓 release ZIP。
2. 確保 model drive 有足夠空間；全新下載會要求約 19 GiB 模型空間再加 2 GiB safety margin。
3. 雙擊 **START-HERE.bat**。
4. Installer 會自動驗證 Windows x64、RTX 2080 Ti / CC 7.5 / 20GB+ VRAM、NVIDIA driver branch R580+、package SHA-256；如有需要自動安裝 VC++ x64 runtime；之後安裝 runtime、續傳下載固定 revision 模型、驗 SHA-256 / v2 container、生成本機 API key、建立 shortcuts、啟動 Base mode，再驗證 /health 與 /v1/models。

一般 runtime **不需要** Python、PowerShell 7、Visual Studio、CMake、Ninja、vcpkg 或完整 CUDA Toolkit。Windows production build 使用 static CUDA runtime；用家需要 NVIDIA driver branch **R580 或更新**，以及 Microsoft Visual C++ 2015-2022 x64 runtime（缺少時 installer 會嘗試用 winget 自動安裝）。

## 預設路徑

有 D: 時：

~~~text
Runtime  D:\AI\NInfer-SM75
Model    D:\AI\models\qwen\qwen3_8_27b.ninfer
API      http://127.0.0.1:8080/v1
~~~

沒有 D: 時：

~~~text
Runtime  %LOCALAPPDATA%\NInfer-SM75
Model    <Runtime>\models\qwen3_8_27b.ninfer
~~~

模型固定大小 18,210,531,328 bytes，SHA-256：

~~~text
eec39564993d6e9c7d5e383382a760f093465c9d163ec9a1bd6b80199514bf3e
~~~

## 日常使用

~~~text
launchers\Start-NInfer.bat
launchers\Start-NInfer-MTP.bat
launchers\Start-NInfer-Vision.bat
launchers\Start-NInfer-MTP-Vision.bat
launchers\Stop-NInfer.bat
launchers\Status-NInfer.bat
launchers\Configure-NInfer.bat
launchers\Check-NInfer.bat
~~~

Base mode production baseline：

~~~text
host              127.0.0.1
port              8080
max-context       16384
max-concurrency   1
KV                INT8 / auto capacity
MTP               off
Vision            off
~~~

MTP shortcut 使用 MTP3 + optimized LM-head draft。Vision 應在 Base text path 正常後再開。

## API key

Installer 自動生成本機 key：

~~~text
<Runtime>\secrets\api-key.txt
~~~

Key 不會放入 ninfer-serve.exe command line；server process 只經 inherited environment 收到 key。

讀取 key：

~~~powershell
$key = (Get-Content "D:\AI\NInfer-SM75\secrets\api-key.txt" -Raw).Trim()
~~~

OpenAI-compatible endpoint：

~~~text
http://127.0.0.1:8080/v1
~~~

查實際 model ID：

~~~powershell
$key = (Get-Content "D:\AI\NInfer-SM75\secrets\api-key.txt" -Raw).Trim()
Invoke-RestMethod -Uri "http://127.0.0.1:8080/v1/models" -Headers @{ Authorization = "Bearer $key" }
~~~

DeepSeek Harness / Hermes 應以此 /v1 endpoint 作 custom OpenAI-compatible provider；不要將 API key 硬編碼入公開 config。

## 改設定

雙擊 launchers\Configure-NInfer.bat，或：

~~~powershell
.\install\first-run-wizard.ps1 -ModelDir "D:\AI\models\qwen" -Port 8080 -MaxContext 16384 -Device 0
~~~

正式 baseline 是 16K。8K / 32K / 64K 是 physical acceptance gates；128K 仍屬 experimental，不應當作 release SLA。

## 驗證

快速：

~~~powershell
.\install\verify-installation.ps1 -Fast
~~~

完整驗證（包括整個 18GB model SHA-256 及 8K physical GPU smoke test）：

~~~powershell
.\install\verify-installation.ps1 -Full
~~~

完整 production hardware acceptance：

~~~powershell
.\scripts\acceptance-windows-sm75.ps1 -Model "D:\AI\models\qwen\qwen3_8_27b.ninfer"
~~~

正式 acceptance 會做 8K / 32K / 64K semantic NIAH、OpenAI tool call、以及 MTP0 ↔ MTP3 generated-token-ID parity。

## Repair

只修 config / key / model：

~~~powershell
.\install\repair-ninfer-sm75.ps1 -DownloadModel -Restart
~~~

binary/package 損壞時，用原始 release 解壓目錄：

~~~powershell
.\install\repair-ninfer-sm75.ps1 -PackageRoot "X:\path\to\extracted-release" -Restart
~~~

## Uninstall

預設保留大型 model：

~~~powershell
.\install\uninstall-ninfer-sm75.ps1
~~~

連 model 一齊刪：

~~~powershell
.\install\uninstall-ninfer-sm75.ps1 -RemoveModel
~~~

## Developer：由 source 一鍵 build

只適用 source checkout，不會放入普通 runtime release package：

~~~text
install\BUILD-FROM-SOURCE.bat
~~~

它會用 winget 安裝/驗證：

~~~text
Git.Git
Kitware.CMake
Ninja-build.Ninja
Microsoft.VisualStudio.2022.BuildTools
Nvidia.CUDA 13.1
Microsoft.VCRedist.2015+.x64
~~~

然後執行 clean Qwen3.8-only / sm_75 build、binary startup check、package、package integrity verification。

## 安全設計

- 預設只 bind 127.0.0.1。
- 安裝版不會自動 expose LAN/WAN。
- API key 不出現在 child command line。
- 非 loopback plain HTTP 仍由原生 launcher 明確阻止，除非同時提供 key 與明確 insecure-remote opt-in。
- 對外使用應放在 TLS reverse proxy / VPN / SSH tunnel 後面。
