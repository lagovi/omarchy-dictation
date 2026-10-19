#!/usr/bin/env python3
import os
import sys
import time
import socket
import subprocess
import psutil
import onnxruntime as ort
import onnx_asr

# 1. Привязываем процесс строго к физическим ядрам процессора (убираем давку HT)
try:
    cores = {}
    for i in range(psutil.cpu_count(logical=True)):
        try:
            with open(f"/sys/devices/system/cpu/cpu{i}/topology/core_id") as f:
                cid = f.read().strip()
                if cid not in cores:
                    cores[cid] = i
        except Exception:
            pass
    phys_cores = list(cores.values()) if len(cores) >= 2 else [0, 2]
    psutil.Process().cpu_affinity(phys_cores)
    print(f"🎯 Процесс зафиксирован на физических ядрах: {phys_cores}", flush=True)
except Exception as e:
    print(f"⚠️ Не удалось задать affinity: {e}", flush=True)

# 2. Тюнинг параметров сессии ONNX
opts = ort.SessionOptions()
opts.intra_op_num_threads = 2
opts.inter_op_num_threads = 1
opts.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
opts.enable_cpu_mem_arena = True
opts.add_session_config_entry("session.intra_op.allow_spinning", "1")
opts.add_session_config_entry("session.set_denormal_as_zero", "1")

print("⏳ Загрузка NVIDIA Parakeet v3 INT8 в память...", flush=True)
t0 = time.perf_counter()
model = onnx_asr.load_model("nemo-parakeet-tdt-0.6b-v3", quantization="int8", sess_options=opts)
load_time = time.perf_counter() - t0
print(f"✅ Parakeet готов за {load_time:.2f} сек!", flush=True)

# Оповещение о готовности на экран
try:
    subprocess.run([
        "notify-send", "-t", "3000", "-u", "normal",
        "🎙️ Голосовой ввод готов",
        f"NVIDIA Parakeet v3 в памяти ({load_time:.1f} сек)"
    ], check=False)
except Exception:
    pass

SOCKET_PATH = "/tmp/gigaam.sock"
if os.path.exists(SOCKET_PATH):
    os.remove(SOCKET_PATH)

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(SOCKET_PATH)
server.listen(1)

while True:
    conn, _ = server.accept()
    wav_path = conn.recv(1024).decode().strip()
    if wav_path and os.path.exists(wav_path):
        t_start = time.perf_counter()
        try:
            text = model.recognize(wav_path)
            elapsed = (time.perf_counter() - t_start) * 1000
            print(f"⚡ [РАСПОЗНАНО за {elapsed:5.1f} мс]: {text}", flush=True)
            conn.sendall(text.encode() if text else b"")
        except Exception as e:
            print(f"⚠️ Ошибка инференса: {e}", flush=True)
            conn.sendall(b"")
    conn.close()
