FROM ruby:3.3-slim

WORKDIR /app

# Внешних гемов нет — только stdlib, bundler не нужен
COPY unu_client.rb telegram_watcher_bot.rb unu_autoapprove.rb vkserfing_client.rb vkserfing_watcher_bot.rb ./

CMD ["ruby", "vkserfing_watcher_bot.rb"]
