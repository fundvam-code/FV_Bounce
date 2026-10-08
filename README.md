# FV_Bounce — исследование стратегий «отскок от уровня» для MetaTrader 5

Pet-проект по алготрейдингу: идея торговли отскоков цены от торговых уровней, подбор параметров на Python (`backtesting.py`) и реализация советников на MQL5.

> **Честный статус.** Это исследовательский проект, а не готовая прибыльная система. Бэктест Level Reversal EA на EURUSD M5 (апрель–декабрь 2025) с параметрами по умолчанию даёт убыток (Profit Factor 0.52, win rate 35%, 522 сделки), walk-forward на отложенном периоде тоже отрицательный. Ценность проекта — в методике (уровни + ATR, перенос Python → MQL5, walk-forward) и в списке выводов ниже. Не является инвестиционной рекомендацией.

## Идея

1. **Bounce (`FV_Bounce`)** — лимитные ордера перед дневными уровнями (Camarilla / Pivot / DeMark): `Buy Limit = S + buffer·ATR`, `Sell Limit = R − buffer·ATR`, SL/TP/трейлинг кратны ATR. Вторая стратегия — пробой: стоп-ордер за SL отскока.
2. **Level Reversal** — сильные swing-уровни на H4 (≥N касаний) + тренд-фильтр (EMA + ADX), вход рыночным ордером по разворотному паттерну (pin bar, engulfing, doji) на M5/M15, SL = ATR·k, TP = SL·RR, одна позиция одновременно.

## Структура

| Путь | Назначение |
|---|---|
| `mql5/FV_Bounce.mq5` | Основной советник Bounce + пробой, кнопки управления, линии уровней (v1.37) |
| `mql5/level_reversal_ea.mq5` | Советник Level Reversal (уровни H4, паттерны M5/M15) |
| `mql5/FV_pattern_bounce.mq5` | Эксперимент: Bounce + подтверждение паттерном (v1.00, не оптимизирован) |
| `mql5/FV_Bounce_Risk.mq5` | Утилита: панель суммарного риска по отложенным ордерам |
| `mql5/MySignals.mq5` | Утилита: кнопки/напоминания/push, снятие ордеров, ATR-трейлинг |
| `mql5/export_rates.mq5` | Скрипт экспорта истории котировок в CSV для ноутбуков |
| `notebooks/bounce_atr_opt_colab.ipynb` | Подбор метода уровней и ATR-множителей для Bounce (3 прохода: лонг, шорт, финал) |
| `notebooks/bounce_only.ipynb`, `breakout_only.ipynb` | Раздельный анализ отскока и пробоя |
| `notebooks/level_reversal_opt.ipynb` | Бэктест, walk-forward и экспорт параметров Level Reversal |
| `notebooks/colab_rnn_WO_optune.ipynb` | Побочный эксперимент: GRU-сеть → ONNX для MT5 (не связан с EA выше) |
| `set/` | Наборы параметров (`.set`) для тестера MT5: `for_trade_EURUSD.set` (Level Reversal), `FV_Bounce_XAUUSD.set` |
| `docs/` | Планы и заметки: [QUICKSTART](docs/QUICKSTART.md), [PLAN_level_reversal_EA](docs/PLAN_level_reversal_EA.md), [PLAN_EA_improvements_v2](docs/PLAN_EA_improvements_v2.md), [XAUUSD_STRATEGY_RESEARCH](docs/XAUUSD_STRATEGY_RESEARCH.md) (гипотезы, не результаты) |

## Данные

Папка `content/` не хранится в репозитории (в `.gitignore`). Получить данные:

1. Скопировать `mql5/export_rates.mq5` в `MQL5/Scripts`, скомпилировать (F7).
2. Запустить на графике EURUSD нужного ТФ (M5, M15, H4, D1), задать период — в `Files` терминала появится CSV.
3. Положить файлы в `content/` как `EURUSD_<TF>_<начало>_<конец>.csv`.

Примечания: ноутбуки Bounce ожидают `EURUSD_H1_*.csv` (H1), Level Reversal — M5/M15/H4/D1; в использованном наборе M5 начинается только с 2025-04-15.

## Запуск

```bash
pip install -r requirements.txt
cd notebooks && jupyter notebook
```

Советники: скопировать `.mq5` в `MQL5/Experts`, скомпилировать в MetaEditor, тестировать в Strategy Tester и на демо-счёте. Параметры `.set` грузятся в тестере (вкладка Inputs → Load).

## Результаты и выводы

- Level Reversal, M5, параметры по умолчанию: Return −100%, PF 0.52, win rate 35.3%, 522 сделки (комиссии съели значительную часть — $830 при депозите $700 в симуляции).
- Walk-forward 70/30: train −16.4%, test −8.3% — переобучения нет, но нет и преимущества (edge).
- Ручной перебор 540 комбинаций в ноутбуке не завершён в сохранённом прогоне; значения в `set/for_trade_EURUSD.set` (Pass 1016) получены оптимизацией в тестере MT5 и в Python не воспроизведены.
- Bounce на H1 (`bounce_only.ipynb`): лучшие комбинации дают PF ≈ 1.7–2.9, но на 30–40 сделках — статистически слабо, нужна проверка out-of-sample.

## Известные ограничения и планы

- Малая история (≈8–24 месяца), нет учёта реалистичных спредов/проскальзывания в Python-бэктесте.
- Python-реализация и MQL5-советник могут расходиться в деталях (расчёт уровней, исполнение внутри бара) — нужна сверка сделок.
- Нет автоматических тестов; ячейка «Рекомендации» в `level_reversal_opt.ipynb` использует упрощённые пороги и не должна читаться как вывод.
- Идеи: v2 советника (режимы Pending/Pattern, см. `docs/PLAN_EA_improvements_v2.md`), перенос на XAUUSD, больше данных, Monte-Carlo.

## Риски

Торговля сопряжена с риском потери капитала. Всё — только на демо-счёте до подтверждения результата на отложенной выборке.
