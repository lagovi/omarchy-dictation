# Omarchy Push-to-Talk ASR (NVIDIA Parakeet TDT INT8)

Fast, resilient local speech-to-text pipeline for Omarchy Linux / Hyprland optimized for older dual-core mobile platforms (Intel Ivy Bridge):

- **Model Engine:** NVIDIA Parakeet TDT 0.6B v3 (`onnx-asr` INT8 quantization, pinned strictly to physical CPU cores).
- **PTT Hotkey:** Right Shift (`Shift_R`) hold to record, release to transcribe and paste.
- **RAM Saver:** Fast triple-tap on Right Shift unloads the model from memory (~1.4 GB freed). Triple-tap again triggers background reload.
- **Auto-Recovery:** Records audio even while the model is loading/offline; automatically transcribes and pastes once the engine is online.
- **Zero Flash Wear:** Audio buffers route entirely through in-RAM `$XDG_RUNTIME_DIR` (`tmpfs`), generating 0 write operations to physical NAND storage.
- **Zero-Overhead VAD:** Built-in RMS silence trimmer cuts leading/trailing silence (~1.5 ms overhead, 0 MB extra RAM), saving 25–35% inference time.

---

## ⚡ Priority & Real-Time Responsiveness Tuning

Under high system loads (browsers, background builds, heavy I/O), the service maintains real-time responsiveness and instant toggle capabilities via a three-tier priority configuration:

### 1. Cgroups v2 Resource Weights (`systemd/dictation.service`)
- **`CPUWeight=1000` / `StartupCPUWeight=1000`:** Allocates the maximum possible CPU time ratio (1000 vs. default 100) under CPU contention, ensuring inference threads are not starved by background tasks.
- **`IOWeight=1000`:** Grants top I/O scheduler priority when accessing memory pages.
- **`OOMScoreAdjust=-500` & `MemoryLow=800M`:** Protects the engine process from `systemd-oomd` and kernel OOM kills during swap-in transitions from zram.

### 2. Linux Scheduler Priority (`Nice=-10`)
Configured in `systemd/dictation.service` to give the inference process precedence over standard userland tasks. Requires granting privilege in `/etc/security/limits.d/99-dictation-priority.conf`:

```conf
uzzzver - nice -15
```

### 3. Non-Blocking Async Toggle
- **`systemctl --user stop --no-block dictation`:** When triple-tapping Right Shift to unload, the client script dispatches an asynchronous stop request. UI notifications and socket cleanup fire in < 10 ms without waiting for Python process teardown.
- **`TimeoutStopSec=3s`:** Forces a fast SIGKILL fallback if the C++ ONNX runtime hangs during shutdown under memory pressure.

---

## 🛠️ Repository Structure

```text
omarchy-dictation/
├── bin/
│   ├── dictate-ptt.sh       # Client PTT handler, triple-tap detector, and recovery worker
│   ├── gigaam-server.py      # Core Unix-socket ASR server with built-in NumPy VAD
│   ├── profile-memory.py    # Deep smaps diagnostic script for RAM/ZRAM inspection
│   └── clean-hf-cache.sh    # Recursive orphaned blob cleaner for Hugging Face cache
├── systemd/
│   └── dictation.service    # Systemd user service unit with priority and OOM protection
└── docs/
    └── huggingface-cache-cleanup.md  # Guide for experimenting with alternative models
```

## 🚀 Setup & Links

```bash
# Link scripts and systemd unit
ln -sf ~/Projects/omarchy-dictation/bin/dictate-ptt.sh ~/.local/bin/dictate-ptt.sh
ln -sf ~/Projects/omarchy-dictation/bin/gigaam-server.py ~/.local/bin/gigaam-server.py
ln -sf ~/Projects/omarchy-dictation/systemd/dictation.service ~/.config/systemd/user/dictation.service

# Reload and start
systemctl --user daemon-reload
systemctl --user enable --now dictation.service
```
