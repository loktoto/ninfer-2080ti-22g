NInfer Qwen3.8-27B / RTX 2080 Ti 22GB - START HERE
===================================================

Normal installation:
  1. Extract the entire ZIP.
  2. Double-click START-HERE.bat.
  3. The installer verifies RTX 2080 Ti / 20GB+ / CC 7.5 / NVIDIA R580+ driver, installs VC++ runtime if needed,
     downloads and SHA-256 verifies the pinned Qwen3.8 model, creates launchers,
     starts the local API server, and runs a health check.

Default paths:
  Runtime: D:\AI\NInfer-SM75 when D: exists, otherwise %LOCALAPPDATA%\NInfer-SM75
  Model:   D:\AI\models\qwen when D: exists, otherwise <runtime>\models

Daily use:
  launchers\Start-NInfer.bat          Conservative production baseline
  launchers\Start-NInfer-MTP.bat      MTP3 speculative decoding
  launchers\Start-NInfer-Vision.bat   Vision enabled
  launchers\Stop-NInfer.bat           Stop the tracked server
  launchers\Status-NInfer.bat         Status / health
  launchers\Configure-NInfer.bat      Change port/context/model/device
  launchers\Check-NInfer.bat          Full installation verification

Runtime requirements:
  NVIDIA driver branch R580 or newer + Microsoft VC++ 2015-2022 x64 runtime.
  The release statically links the CUDA runtime; a CUDA Toolkit is NOT required for normal use.

Security:
  The installer binds to 127.0.0.1 by default and generates a local API key.
  The key is stored outside command-line arguments and the key file ACL is restricted.

Important:
  128K context is experimental. 8K/32K/64K are the formal hardware-acceptance gates.
  Do not delete config\windows-sm75-artifacts.json; it pins the exact production artifact.
