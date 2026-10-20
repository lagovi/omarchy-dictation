#!/bin/bash
RUNTIME_BASE="${XDG_RUNTIME_DIR:-/run/user/$UID}"
PID_FILE="$RUNTIME_BASE/dictate_ptt.pid"
TIME_FILE="$RUNTIME_BASE/dictate_ptt.time"
WAV_FILE="$RUNTIME_BASE/dictate.wav"
PENDING_WAV="$RUNTIME_BASE/dictate_pending.wav"
CLICKS_FILE="$RUNTIME_BASE/dictate_clicks.txt"
SOCK="/tmp/gigaam.sock"
LOG_FILE="/tmp/dictate_ptt.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S.%3N')] $1" >> "$LOG_FILE"
}

get_engine_state() {
    if [ -S "$SOCK" ]; then
        echo "READY"
    elif systemctl --user is-active --quiet dictation; then
        echo "LOADING"
    else
        echo "STOPPED"
    fi
}

auto_recover_pending() {
    (
        for i in {1..120}; do
            if [ -S "$SOCK" ]; then
                log "STATE: Model ready. Processing pending audio..."
                if [ -s "$PENDING_WAV" ]; then
                    notify-send -t 2500 -u low "⚡ Расшифровка" "Модель готова! Обрабатываю наговорённую речь..." -h string:x-canonical-private-synchronous:dictate
                    TEXT=$(echo "$PENDING_WAV" | nc -U -N -w 180 "$SOCK")
                    if [ -n "$TEXT" ]; then
                        wl-copy "$TEXT "
                        wtype -M ctrl -k v -m ctrl
                        notify-send -t 3000 -u normal "✅ Восстановлено и вставлено" "$TEXT" -h string:x-canonical-private-synchronous:dictate
                        rm -f "$PENDING_WAV"
                    fi
                else
                    notify-send -t 2500 -u low "🟢 ASR готов к работе" "Модель успешно загружена в память" -h string:x-canonical-private-synchronous:dictate
                fi
                break
            fi
            sleep 0.5
        done
    ) &
}

handle_triple_click() {
    local state
    state=$(get_engine_state)
    log "ACTION: Triple-click confirmed! State: $state"

    case "$state" in
        READY)
            log "Action: STOPPING engine"
            systemctl --user stop --no-block dictation
            rm -f "$SOCK"
            notify-send -t 2500 -u normal "💤 ASR выгружен из RAM" "Освобождено ~1.4 ГБ оперативной памяти" -h string:x-canonical-private-synchronous:dictate
            ;;
        LOADING)
            log "Action: Already loading, ignoring"
            notify-send -t 3000 -u normal "⏳ Модель уже загружается!" "Идёт считывание весов с накопителя в RAM, подождите завершения..." -h string:x-canonical-private-synchronous:dictate
            ;;
        STOPPED)
            log "Action: STARTING engine"
            notify-send -t 4000 -u normal "⏳ Запуск ASR..." "Задача принята: считывание модели в RAM (~15-25 сек)..." -h string:x-canonical-private-synchronous:dictate
            systemctl --user start dictation
            auto_recover_pending
            ;;
    esac
}

case "$1" in
    start)
        NOW=$(date +%s%3N)
        echo "$NOW" > "$TIME_FILE"

        # 1. ДЕТЕКЦИЯ ТРОЙНОГО НАЖАТИЯ ПО НАЖАТИЮ КЛАВИШИ (ОКНО 1200 МС)
        echo "$NOW" >> "$CLICKS_FILE"
        awk -v cutoff=$((NOW - 1200)) '$1 > cutoff' "$CLICKS_FILE" > "${CLICKS_FILE}.tmp" 2>/dev/null && mv "${CLICKS_FILE}.tmp" "$CLICKS_FILE"
        CLICK_COUNT=$(wc -l < "$CLICKS_FILE" 2>/dev/null || echo 0)

        # Если это 3-й клик — мгновенно переключаем сервис
        if [ "$CLICK_COUNT" -ge 3 ]; then
            rm -f "$CLICKS_FILE"
            if [ -f "$PID_FILE" ]; then
                PID=$(cat "$PID_FILE" 2>/dev/null)
                rm -f "$PID_FILE"
                [ -n "$PID" ] && kill -INT "$PID" 2>/dev/null
                rm -f "$WAV_FILE"
            fi
            handle_triple_click
            exit 0
        fi

        # 2. ОБЫЧНОЕ НАЖАТИЕ (ЕСЛИ НЕ ТРОЙНОЙ КЛИК)
        STATE=$(get_engine_state)
        case "$STATE" in
            READY)
                rm -f "$WAV_FILE"
                pw-record --rate 48000 --channels 1 "$WAV_FILE" 2>> "$LOG_FILE" &
                echo $! > "$PID_FILE"
                notify-send -t 1500 -u low "🟢 Готов к записи" "Говорите (удерживайте Shift)..." -h string:x-canonical-private-synchronous:dictate
                ;;
            LOADING)
                rm -f "$WAV_FILE"
                pw-record --rate 48000 --channels 1 "$WAV_FILE" 2>> "$LOG_FILE" &
                echo $! > "$PID_FILE"
                notify-send -t 2500 -u low "⏳ Запись идёт (ASR загружается)" "Речь сохранится и распознается автоматически" -h string:x-canonical-private-synchronous:dictate
                ;;
            STOPPED)
                # При кликах 1 и 2 тихо молчим, чтобы не спамить экран
                ;;
        esac
        ;;

    stop)
        STOP_TIME=$(date +%s%3N)

        START_TIME=$(cat "$TIME_FILE" 2>/dev/null || echo "")
        rm -f "$TIME_FILE"

        if [[ ! "$START_TIME" =~ ^[0-9]+$ ]]; then
            DURATION_MS=0
        else
            DURATION_MS=$((STOP_TIME - START_TIME))
        fi
        log "Stop called. Duration: ${DURATION_MS} ms"

        # Короткий клик (< 450 мс) — это часть последовательности кликов или случайный нажим
        if [ "$DURATION_MS" -lt 450 ]; then
            if [ -f "$PID_FILE" ]; then
                PID=$(cat "$PID_FILE" 2>/dev/null)
                rm -f "$PID_FILE"
                [ -n "$PID" ] && kill -INT "$PID" 2>/dev/null
                rm -f "$WAV_FILE"
            fi
            exit 0
        fi

        # Если клавишу держали долго (>= 450 мс) — сбрасываем историю кликов (это диктовка)
        rm -f "$CLICKS_FILE"

        STATE=$(get_engine_state)

        # Если сервис выключен, а клавишу зажали долго — напоминаем
        if [ "$STATE" = "STOPPED" ]; then
            notify-send -t 2500 -u low "⏸️ ASR выключен" "Для загрузки в память нажмите Shift 3 раза быстро" -h string:x-canonical-private-synchronous:dictate
            exit 0
        fi

        if [ ! -f "$PID_FILE" ]; then
            exit 0
        fi
        PID=$(cat "$PID_FILE" 2>/dev/null)
        rm -f "$PID_FILE"
        [ -z "$PID" ] && exit 0

        kill -INT "$PID" 2>/dev/null
        for i in {1..25}; do
            kill -0 "$PID" 2>/dev/null || break
            sleep 0.04
        done

        if [ ! -s "$WAV_FILE" ]; then
            log "WARN: WAV is empty"
            exit 0
        fi

        cp "$WAV_FILE" "$PENDING_WAV"

        if [ "$STATE" = "LOADING" ]; then
            log "Audio saved to pending while model is loading"
            notify-send -t 3000 -u low "💾 Речь сохранена" "Ожидание завершения загрузки модели..." -h string:x-canonical-private-synchronous:dictate
            auto_recover_pending
            exit 0
        fi

        notify-send -t 2000 -u low "⚡ Распознавание..." "Обработка речи..." -h string:x-canonical-private-synchronous:dictate

        log "Sending WAV to server..."
        T_START=$(date +%s%3N)
        TEXT=$(echo "$WAV_FILE" | nc -U -N -w 180 "$SOCK")
        T_END=$(date +%s%3N)
        ELAPSED=$((T_END - T_START))

        log "Result: '$TEXT' in ${ELAPSED}ms"

        if [ -n "$TEXT" ]; then
            rm -f "$PENDING_WAV"
            wl-copy "$TEXT "
            wtype -M ctrl -k v -m ctrl
            notify-send -t 2500 -u low "✅ Готово (${ELAPSED} мс)" "$TEXT" -h string:x-canonical-private-synchronous:dictate
        else
            log "WARN: Empty text returned"
            notify-send -t 2000 -u normal "❓ Пустой результат" "Речь не распознана" -h string:x-canonical-private-synchronous:dictate
        fi
        ;;
esac
