FROM ruby:3.3-slim

WORKDIR /app

# Внешних гемов нет — только stdlib, bundler не нужен
COPY clients ./clients
COPY bots ./bots

CMD ["ruby", "bots/vkserfing_watcher_bot.rb"]
