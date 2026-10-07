# vk_bot

Накрутка лайков на комментарии ВКонтакте через биржи заданий [UNU](https://unu.im) и [VKSerfing](https://vkserfing.ru). Telegram-бот следит за чатами/каналами, в которых он состоит, находит ссылки на комментарии ВК (`https://vk.ru/wallXXX_YYY?reply=ZZZ`) и автоматически создаёт задания на лайки.

## Состав

```
clients/
  unu_client.rb        # клиент UNU API (unu.im/api)
  vkserfing_client.rb  # клиент VKSerfing API (vkserfing.ru/api)
bots/
  vkserfing_watcher_bot.rb  # наблюдатель: слушает чаты, создаёт задания в VKSerfing (5–15 лайков, таргетинг: М, 22+, 30+ друзей, Россия)
  telegram_watcher_bot.rb   # старый наблюдатель для UNU (не запускать одновременно с vkserfing-ботом — один токен)
  telegram_bot.rb           # бот с командой /like <ссылки> — создаёт задачи в UNU вручную
  unu_autoapprove.rb        # раз в 5 минут аппрувит выполненные отчёты UNU, шлёт сводку админам
Dockerfile, compose.yaml    # контейнеризация
```

Все боты пишут ошибки и уведомления только админам (`TELEGRAM_ADMIN_IDS`), в чаты/каналы ничего не отправляют.

## Настройка

Создать `.env` по образцу `.env.example`:

```
UNU-API-KEy=...
VKSERFING-API-KEY=...
TELEGRAM_WATCHER_TOKEN=...   # токен бота от @BotFather
TELEGRAM_ADMIN_IDS=111,222   # id админов через запятую (узнать: @userinfobot)
DEPLOY_TO=root@<ip-сервера>
```

## Запуск локально

Нужен только Ruby (внешних гемов нет, только stdlib):

```bash
ruby bots/vkserfing_watcher_bot.rb   # наблюдатель
ruby bots/unu_autoapprove.rb         # автоаппрув UNU
```

Либо в Docker:

```bash
docker compose up -d --build
```

## Деплой

```bash
scp -r clients bots Dockerfile compose.yaml .env root@<сервер>:/root/vk_bot/
ssh root@<сервер> 'cd /root/vk_bot && docker compose up -d --build'
```

Поднимаются два контейнера: `vk-watcher-bot` (наблюдатель VKSerfing) и `vk-unu-autoapprove`. Состояние (offset Telegram, обработанные ссылки) хранится в named volume `watcher-data`, переживает пересоздание контейнеров.

## Линт и тесты

```bash
bundle install
rubocop clients/*.rb bots/*.rb tests/*.rb
bundle exec rake test   # юнит-тесты на minitest, HTTP стабается через WebMock — без сети и реальных ключей
```

CI: GitHub Actions (`.github/workflows/tests.yml`) гоняет тесты на каждый push.

Конфиг линтера — `.rubocop.yml` (имена методов совпадают с методами API бирж, лимиты Metrics ослаблены).
