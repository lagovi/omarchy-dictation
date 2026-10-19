#!/bin/bash
PID_FILE="/tmp/dictate_ptt.pid"
TIME_FILE="/tmp/dictate_ptt.time"
WAV_FILE="/tmp/dictate.wav"
PENDING_WAV="/tmp/dictate_pending.wav"
SOCK="/tmp/gigaam.sock"
LOG_FILE="/tmp/dictate_ptt.log"
CLICKS_FILE="/tmp/dictate_clicks.txt"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S.%3N')] $1" >> "$LOG_FILE"
}

# Фоновый обработчик отложенной записи (после подъема сервера)
auto_recover_pending() {
    if [ -s "$PENDING_WAV" ]; then
        (
            # Ждем появления сокета до 20 секунд (пока загружается Parakeet)
            for i in {1..40}; do
                if [ -S "$SOCK" ]; then
                    log "RECOVERY: Socket available. Sending pending audio..."
                    notify-send -t 2000 -u low "⚡ Восстановление" "Расшифровываю сохранённую запись..." -h string:x-canonical-private-synchronous:dictate
                    
                    TEXT=$(echo "$PENDING_WAV" | nc -U -N -w 180 "$SOCK")
                    if [ -n "$TEXT" ]; then
                        wl-copy "$TEXT "
                        wtype -M ctrl -k v -m ctrl
                        notify-send -t 3000 -u normal "✅ Восстановлено и вставлено" "$TEXT" -h string:x-canonical-private-synchronous:dictate
                        rm -f "$PENDING_WAV"
                    fi
                    break
                fi
                sleep 0.5
            done
        ) &
    fi
}

# Функция переключения состояния сервиса (Тройной клик)
toggle_service() {
    if systemctl --user is-active --quiet dictation; then
        log "ACTION: Triple-click -> STOPPING dictation"
        systemctl --user stop dictation
        notify-send -t 2500 -u normal "💤 ASR выгружен из RAM" "Освобождено ~1.4 ГБ оперативной памяти" -h string:x-canonical-private-synchronous:dictate
    else
        log "ACTION: Triple-click -> STARTING dictation"
        notify-send -t 3000 -u normal "⏳ Загрузка ASR в память..." "Подождите ~10-12 сек..." -h string:x-canonical-private-synchronous:dictate
        systemctl --user start dictation
        # Если была сохраненная запись — автоматически расшифровать, как только поднимется сокет
        auto_recover_pending
    fi
}

case "$1" in
    start)
        NOW=$(date +%s%3N)
        echo "$NOW" > "$TIME_FILE"

        # Детекция тройного нажатия (окно 750 мс)
        echo "$NOW" >> "$CLICKS_FILE"
        awk -v cutoff=$((NOW - 750)) '$1 > cutoff' "$CLICKS_FILE" > "${CLICKS_FILE}.tmp" 2>/dev/null && mv "${CLICKS_FILE}.tmp" "$CLICKS_FILE"
        CLICK_COUNT=$(wc -l < "$CLICKS_FILE" 2>/dev/null || echo 0)

        if [ "$CLICK_COUNT" -ge 3 ]; then
            rm -f "$CLICKS_FILE" "$PID_FILE" "$TIME_FILE"
            toggle_service
            exit 0
        fi

        # Если сервис выгружен пользователем — напоминаем и не пишем впустую
        if ! systemctl --user is-active --quiet dictation; then
            notify-send -t 1500 -u low "⏸️ ASR выключен" "Нажмите Shift 3 раза для загрузки в RAM" -h string:x-canonical-private-synchronous:dictate
            exit 0
        fi

        rm -f "$WAV_FILE"
        # Запускаем запись
        pw-record --rate 48000 --channels 1 "$WAV_FILE" 2>> "$LOG_FILE" &
        REC_PID=$!
        echo "$REC_PID" > "$PID_FILE"

        notify-send -t 1500 -u low "🟢 Готов к записи" "Говорите (удерживайте Shift)..." -h string:x-canonical-private-synchronous:dictate
        ;;

    stop)
        STOP_TIME=$(date +%s%3N)

        # Атомарная защита от двойного срабатывания XKB
        if [ ! -f "$PID_FILE" ]; then
            exit 0
        fi
        PID=$(cat "$PID_FILE" 2>/dev/null)
        rm -f "$PID_FILE"
        [ -z "$PID" ] && exit 0

        START_TIME=$(cat "$TIME_FILE" 2>/dev/null)
        rm -f "$TIME_FILE"

        DURATION_MS=$((STOP_TIME - START_TIME))
        log "Stop called. Duration: ${DURATION_MS} ms"

        # Мягко гасим pw-record
        kill -INT "$PID" 2>/dev/null
        for i in {1..25}; do
            kill -0 "$PID" 2>/dev/null || break
            sleep 0.04
        done

        # Фильтр коротких кликов (< 500 мс). 
        # Если нажали кратковременно — это случайное касание или часть тройного клика.
        if [ "$DURATION_MS" -lt 500 ]; then
            rm -f "$WAV_FILE"
            exit 0
        fi

        # Если файл пуст даже после удержания > 500 мс — просто сообщаем, но НЕ ломаем PipeWire
        if [ ! -s "$WAV_FILE" ]; then
            log "WARN: WAV is empty after ${DURATION_MS}ms"
            notify-send -t 1500 -u low "⚠️ Слишком короткая речь" "Удерживайте Shift во время всей фразы" -h string:x-canonical-private-synchronous:dictate
            exit 0
        fi

        # Звук записан! Сохраняем в PENDING_WAV (страховка от потери)
        cp "$WAV_FILE" "$PENDING_WAV"

        # Проверяем готовность сокета модели
        if [ ! -S "$SOCK" ]; then
            log "WARN: Socket missing. Audio backed up to $PENDING_WAV"
            notify-send -t 3000 -u normal "💾 Запись сохранена" "Сервер не готов. Нажмите 3x Shift для старта" -h string:x-canonical-private-synchronous:dictate
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
            # Успешно распознано — удаляем страховку
            rm -f "$PENDING_WAV"
            wl-copy "$TEXT "
            wtype -M ctrl -k v -m ctrl
            notify-send -t 2500 -u low "✅ Готово (${ELAPSED} мс)" "$TEXT" -h string:x-canonical-private-synchronous:dictate
        else
            log "WARN: Empty text returned by engine"
            notify-send -t 2000 -u normal "❓ Пустой результат" "Речь не распознана" -h string:x-canonical-private-synchronous:dictate
        fi
        ;;
esac
