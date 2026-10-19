# Инструкция по работе с кэшем Hugging Face и очистке моделей

## 1. Архитектурная ловушка кэша Hugging Face Hub

Кэш моделей в `~/.cache/huggingface/hub/` устроен по принципу дедупликации (Content-Addressable Storage):

1. **Каталоги `models--<org>--<repo>/`:**  
   Содержат только текстовые метаданные, конфиги и **символические ссылки (симлинки)** в подпапках `snapshots/<commit_hash>/`. Сами по себе они весят единицы килобайт.
2. **Каталог `blobs/XX/<sha256>`:**  
   Здесь физически хранятся все гигабайты бинарных данных, разделенные по двузначным подкаталогам (например, `blobs/88/...`).
3. **Главная проблема удаления:**  
   Если удалить модель через `rm -rf models--<имя>`, **реальные файлы весов из папки `blobs/` НЕ удаляются**. Они превращаются в «осиротевшие блобы» (orphaned blobs), которые не видны в списке моделей, но забивают диск.

---

## 2. Ловушка неиспользуемых точностей (FP32 vs INT8)

При вызове `onnx_asr.load_model("nemo-parakeet-tdt-0.6b-v3", quantization="int8")`:
* Библиотека скачивает из репозитория Hugging Face **все файлы оптом**, включая тяжелые варианты полной точности (`encoder-model.onnx` и `encoder-model.onnx.data` на 2.5–3.0 ГБ).
* Сервер загружает только квантованные файлы (`.int8.onnx`), а версия FP32 остаётся лежать балластом.

### Ручное удаление FP32-балласта (если скачалась лишняя точность):
```bash
SNAPSHOT_DIR=~/.cache/huggingface/hub/models--<имя_модели>/snapshots/*

# Находим реальный файл через readlink и удаляем вместе с симлинком:
for f in "$SNAPSHOT_DIR"/encoder-model.onnx "$SNAPSHOT_DIR"/encoder-model.onnx.data "$SNAPSHOT_DIR"/decoder_joint-model.onnx; do
    if [ -L "$f" ]; then
        real_file=$(readlink -f "$f")
        rm -f "$real_file" "$f"
    fi
done
```

---

## 3. Регламент проведения экспериментов с новыми моделями

Когда тестируется новая модель ASR (GigaAM, Whisper, Qwen, Nemotron):

1. **Перед тестом:**  
   Зафиксировать текущий размер: `du -sh ~/.cache/huggingface/hub`
2. **Если модель не подошла:**  
   Удалить её каталог-снапшот:
   ```bash
   rm -rf ~/.cache/huggingface/hub/models--<ненужная_модель>
   ```
3. **Запустить очистку осиротевших блобов:**
   ```bash
   ./bin/clean-hf-cache.sh
   ```
   Скрипт рекурсивно проверит все файлы в `blobs/`. Всё, на что больше не ссылается ни одна активная модель из `snapshots/`, будет автоматически и безопасно удалено.

---

## 4. Диагностические команды

* Посмотреть все тяжелые файлы в кэше с их размерами:
  ```bash
  find ~/.cache/huggingface/hub/blobs/ -type f -exec du -h {} + | sort -h
  ```
* Проверить, какие реальные блобы использует активная модель Parakeet:
  ```bash
  find ~/.cache/huggingface/hub/models--istupakov--parakeet-tdt-0.6b-v3-onnx/ -type l -exec readlink -f {} +
  ```
