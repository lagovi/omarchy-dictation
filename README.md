# Omarchy Push-to-Talk ASR (NVIDIA Parakeet TDT INT8)

Fast local speech-to-text pipeline for Omarchy Linux / Hyprland optimized for Intel Ivy Bridge:
- **Engine:** NVIDIA Parakeet TDT 0.6B v3 (ONNX INT8, 2 threads pinned to physical cores).
- **PTT Hotkey:** Right Shift hold to talk, release to paste.
- **RAM Saver:** Triple-tap Right Shift unloads the engine from memory (~1.4 GB freed). Triple-tap again reloads it.
- **Auto-recovery:** Captures audio even if engine is offline, transcribes and pastes automatically once loaded.
