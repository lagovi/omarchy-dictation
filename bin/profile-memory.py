#!/usr/bin/env python3
import os
import sys
import subprocess
from collections import defaultdict

def get_service_pid():
    # Пробуем получить PID через systemd
    try:
        out = subprocess.check_output(
            ["systemctl", "--user", "show", "-p", "MainPID", "--value", "dictation"],
            stderr=subprocess.DEVNULL
        ).decode().strip()
        if out and out != "0":
            return int(out)
    except Exception:
        pass

    # Фоллбэк на pgrep
    try:
        out = subprocess.check_output(["pgrep", "-f", "gigaam-server.py"]).decode().strip()
        lines = out.split()
        if lines:
            return int(lines[0])
    except Exception:
        pass
    return None

def categorize_mapping(path):
    if not path or path == "[heap]" or path.startswith("[anon") or "anon_inode" in path:
        return "1. ONNX Dynamic Arena & Heap (буферы, тензоры, активации)"
    if any(ext in path for ext in [".onnx", "nemo-parakeet", ".model", ".bin"]):
        return "2. Файлы модели (ONNX веса / mmap)"
    if "onnxruntime" in path or "libonnxruntime" in path:
        return "3. Библиотеки ONNX Runtime (C++ движок)"
    if "python" in path or "site-packages" in path:
        return "4. Python рантайм, NumPy и скрипт сервера"
    if path.startswith("/usr/lib") or path.startswith("/lib"):
        return "5. Системные C/C++ библиотеки (glibc, libstdc++, libm)"
    if path.startswith("[stack"):
        return "6. Стеки потоков (Thread Stacks)"
    return "7. Прочие отображения"

def parse_smaps(pid):
    smaps_path = f"/proc/{pid}/smaps"
    if not os.path.exists(smaps_path):
        print(f"Ошибка: процесс {pid} не найден или нет доступа к {smaps_path}")
        sys.exit(1)

    categories = defaultdict(lambda: {"rss": 0, "pss": 0, "swap": 0, "private": 0})
    total_stats = {"rss": 0, "pss": 0, "swap": 0}

    current_cat = None
    with open(smaps_path, "r") as f:
        for line in f:
            line = line.strip()
            # Заголовок маппинга: address perms offset dev inode pathname
            if " " in line and line.count(":") >= 1 and not line.endswith("kB"):
                parts = line.split(maxsplit=5)
                path = parts[5] if len(parts) > 5 else ""
                current_cat = categorize_mapping(path)
                continue

            if not current_cat:
                continue

            if line.startswith("Rss:"):
                val = int(line.split()[1])
                categories[current_cat]["rss"] += val
                total_stats["rss"] += val
            elif line.startswith("Pss:"):
                val = int(line.split()[1])
                categories[current_cat]["pss"] += val
                total_stats["pss"] += val
            elif line.startswith("Swap:"):
                val = int(line.split()[1])
                categories[current_cat]["swap"] += val
                total_stats["swap"] += val
            elif line.startswith("Private_Dirty:"):
                val = int(line.split()[1])
                categories[current_cat]["private"] += val

    return categories, total_stats

def main():
    pid = get_service_pid()
    if not pid:
        print("❌ Сервис dictation не запущен! Запустите его командой: systemctl --user start dictation")
        sys.exit(1)

    # Читаем команду запуска
    try:
        with open(f"/proc/{pid}/cmdline", "r") as f:
            cmd = f.read().replace('\0', ' ')
    except Exception:
        cmd = "python gigaam-server.py"

    categories, totals = parse_smaps(pid)

    print("\n" + "=" * 78)
    print(f"📊 АНАЛИЗ ПАМЯТИ ASR СЕРВИСА (PID: {pid})")
    print(f"   Команда: {cmd[:65]}...")
    print("=" * 78)
    print(f"{'Компонент сервиса':<52} | {'Физич. RAM (RSS)':<10} | {'В свопе (ZRAM)':<10}")
    print("-" * 78)

    # Сортируем категории
    for cat_name in sorted(categories.keys()):
        data = categories[cat_name]
        rss_mb = data["rss"] / 1024
        swap_mb = data["swap"] / 1024
        # Выводим строку, если компонент занимает хотя бы 0.1 МБ
        if rss_mb > 0.05 or swap_mb > 0.05:
            print(f"{cat_name:<52} | {rss_mb:8.1f} МБ | {swap_mb:8.1f} МБ")

    print("-" * 78)
    total_rss = totals['rss'] / 1024
    total_swap = totals['swap'] / 1024
    total_alloc = total_rss + total_swap

    print(f"{'ИТОГО В ФИЗИЧЕСКОЙ ПАМЯТИ (Real RAM RSS):':<52} | {total_rss:8.1f} МБ |")
    print(f"{'ИТОГО В СВОПЕ / ZRAM (Swapped Out):':<52} | {'':<10} | {total_swap:8.1f} МБ")
    print(f"{'ПОЛНЫЙ ОБЪЁМ ВЫДЕЛЕННОЙ ПАМЯТИ (RAM + Swap):':<52} | {total_alloc:8.1f} МБ |")
    print("=" * 78 + "\n")

    # Выводы
    python_mem = categories.get("4. Python рантайм, NumPy и скрипт сервера", {}).get("rss", 0) / 1024
    onnx_mem = (
        categories.get("1. ONNX Dynamic Arena & Heap (буферы, тензоры, активации)", {}).get("rss", 0) +
        categories.get("2. Файлы модели (ONNX веса / mmap)", {}).get("rss", 0) +
        categories.get("3. Библиотеки ONNX Runtime (C++ движок)", {}).get("rss", 0)
    ) / 1024

    print("💡 ИНЖЕНЕРНЫЕ ВЫВОДЫ:")
    if onnx_mem > 0:
        pct_onnx = (onnx_mem / max(total_rss, 1)) * 100
        pct_py = (python_mem / max(total_rss, 1)) * 100
        print(f"  • C++ ядро ONNX Runtime и веса модели занимают: {onnx_mem:.1f} МБ ({pct_onnx:.1f}% физической RAM)")
        print(f"  • Сам интерпретатор Python со всеми библиотеками: {python_mem:.1f} МБ ({pct_py:.1f}% физической RAM)")
        print(f"  • Переписывание на Rust теоретически могло бы высвободить не более ~{python_mem - 10:.0f} МБ.")
    if total_swap > 50:
        print(f"  • ⚠️ Внимание: {total_swap:.1f} МБ модели сейчас лежит в свопе. Первый инференс может быть с задержкой.")
    else:
        print(f"  • ✅ Сервис 'горячий': модель почти целиком удерживается в физической оперативной памяти.")
    print("")

if __name__ == "__main__":
    main()
