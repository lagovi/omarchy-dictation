#!/usr/bin/env bash
# Универсальная очистка осиротевших блобов и неиспользуемых весов Hugging Face
set -e

HUB_DIR="$HOME/.cache/huggingface/hub"
BLOBS_DIR="$HUB_DIR/blobs"

if [ ! -d "$BLOBS_DIR" ]; then
    echo "Кэш Hugging Face пуст или не найден: $BLOBS_DIR"
    exit 0
fi

echo "=== Очистка кэша Hugging Face ==="
echo "Размер кэша ДО очистки: $(du -sh "$HUB_DIR" | cut -f1)"

# 1. Сбор всех активных симлинков из всех существующих моделей
echo "1. Поиск используемых блобов через симлинки..."
mapfile -t VALID_BLOBS < <(find "$HUB_DIR" -path "*/snapshots/*" -type l -exec readlink -f {} + | sort -u)

echo "   Найдено активных файлов: ${#VALID_BLOBS[@]}"

# 2. Удаление осиротевших файлов в подпапках blobs/
echo "2. Удаление неиспользуемых файлов..."
DELETED_COUNT=0
FREED_BYTES=0

while IFS= read -r file; do
    keep=0
    for valid in "${VALID_BLOBS[@]}"; do
        if [ "$file" = "$valid" ]; then
            keep=1
            break
        fi
    done

    if [ $keep -eq 0 ]; then
        size_bytes=$(stat -c%s "$file" 2>/dev/null || echo 0)
        FREED_BYTES=$((FREED_BYTES + size_bytes))
        rm -f "$file"
        DELETED_COUNT=$((DELETED_COUNT + 1))
    fi
done < <(find "$BLOBS_DIR" -type f)

# 3. Удаление пустых директорий в blobs
find "$BLOBS_DIR" -mindepth 1 -type d -empty -delete 2>/dev/null || true

FREED_MB=$((FREED_BYTES / 1024 / 1024))
echo "   Удалено файлов: $DELETED_COUNT (освобождено ~$FREED_MB МБ)"
echo "Размер кэша ПОСЛЕ очистки: $(du -sh "$HUB_DIR" | cut -f1)"
echo "=== Очистка завершена ==="
