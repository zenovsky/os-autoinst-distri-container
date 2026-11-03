# Grafana для результатов openQA

Стек: **InfluxDB 2.x** (хранилище) + **Grafana** (дашборд `openQA: тесты и стабильность`, подключается автоматически).

```
openQA job ──► ci/run-openqa-tests.sh ──► ci/steps-to-influx.pl ──► InfluxDB ──► Grafana
                (результат, длительность,   (line protocol)          bucket        дашборд
                 steps-*.json, метаданные CI)                        openqa
```

## 1. Запуск стека

```bash
cd monitoring
cp .env.example .env          # задайте пароли и токен (openssl rand -hex 32)
docker compose up -d
```

- Grafana: http://localhost:3000 (логин/пароль из `.env`), дашборд в папке **openQA**.
- InfluxDB: http://localhost:8086.
- Бакет, организация и токен создаются при первом старте из `.env`. Если позже поменяете токен в `.env`,
  InfluxDB его не обновит (он создаётся один раз): либо создайте новый токен в UI InfluxDB, либо
  пересоздайте том `docker compose down -v` (данные будут потеряны).

## 2. Подключение пайплайна

В GitLab: Settings -> CI/CD -> Variables:

| Переменная | Значение |
|---|---|
| `INFLUX_TOKEN` | тот же токен, что в `monitoring/.env` (Masked) |
| `INFLUX_URL` | адрес InfluxDB, доступный с раннера (по умолчанию в `.gitlab-ci.yml`: `http://localhost:8086`) |

Если `INFLUX_URL` или `INFLUX_TOKEN` не заданы, скрипт пропускает отправку, на результат тестов это не влияет.
Метрики уходят и при упавших тестах. Строки в формате line protocol сохраняются как артефакт `metrics/metrics.lp`.

## 3. Какие данные пишутся

| Measurement | Теги | Поля |
|---|---|---|
| `openqa_job` | `scenario`, `result`, `branch` | `duration_s`, `job_id`, `pipeline_id`, `commit`, `openqa_url`, `gitlab_url` |
| `openqa_step` | `suite`, `step`, `status`, `branch`, `qase_id` | `duration_s`, `failed` (0/1), `job_id`, `pipeline_id` |

Время точки `openqa_job` = момент завершения job'а, `openqa_step` = начало шага.

## 4. Панели дашборда

Успешность, число и падения прогонов, средняя длительность; результаты и стабильность по дням; длительность job'ов и шагов;
таблицы флаки-шагов (и проходили, и падали за период), чаще всего падающих и самых долгих шагов; последние прогоны со
ссылками на openQA и GitLab. Фильтры: сценарий, набор шагов (suite), ветка.

## Ограничения

- «Флаки» считаются по доле падений шага за выбранный период (строго между 0 и 100%). Это приближение: оно не отличает
  нестабильный тест от реальной регрессии в другом коммите. Для точности сужайте период или выбирайте одну ветку.
- Для ручной проверки: `curl -H "Authorization: Token $INFLUX_TOKEN" "http://localhost:8086/api/v2/query?org=openqa" ...`
  или раздел Data Explorer в UI InfluxDB.
