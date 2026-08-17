# FV_Bounce

Проект: подбор параметров стратегии отскока (Bounce) на основе уровней + ATR.

- Содержит ноутбук `bounce_atr_opt_colab.ipynb`, скрипты и скомпилированный `FV_Bounce.ex5`.
- В ноутбуке выполнены правки: защита `BounceStrategy.next` от отсутствия `broker`, и переименование `trailing_atr_*` → `tp_atr_*`.

Как отправить на GitHub (пример):

```bash
# 1) создать репозиторий на GitHub (через сайт или `gh repo create`)
# 2) добавить remote и запушить
git remote add origin git@github.com:YOUR_USER/YOUR_REPO.git
git push -u origin main
```

Если хотите, могу попытаться создать репозиторий и запушить автоматически (требуется `gh` и ваша авторизация).
