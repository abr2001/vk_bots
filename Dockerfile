FROM ruby:3.3-slim

WORKDIR /app

# Внешних гемов нет — только stdlib, bundler не нужен
COPY clients ./clients
COPY telegram_watcher_bot.rb unu_autoapprove.rb vkserfing_watcher_bot.rb ./

CMD ["ruby", "vkserfing_watcher_bot.rb"]
