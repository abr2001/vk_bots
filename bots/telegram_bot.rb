# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require_relative '../clients/unu_client'

# Telegram-бот: по команде /like [N] и списку ссылок на комментарии VK
# создаёт задачи в UNU (тариф «Лайки», по одной задаче на ссылку).
#
# Конфиг в .env:
#   TELEGRAM_BOT_TOKEN — токен от @BotFather
#   ALLOWED_USER_IDS   — whitelist Telegram user ID через запятую
#   UNU-API-KEy        — ключ UNU (используется UnuClient)
class TelegramBot
  TG_API = 'https://api.telegram.org'
  DEFAULT_LIMIT = 10
  TASK_PRICE_RUB = 1.0
  TASK_TARIF_ID = 1 # «Лайки»
  TASK_FOLDER_ID = 0 # «Мои задачи»
  POLL_TIMEOUT = 30

  HELP_TEXT = <<~TEXT.freeze
    Команда: /like [N] и ссылки на комментарии (каждая с новой строки или через пробел).
    N — сколько лайков заказать на каждую ссылку (по умолчанию #{DEFAULT_LIMIT}).

    Пример:
    /like 25
    https://vk.com/wall-1_2?reply=3
    https://vk.com/wall-4_5?reply=6
  TEXT

  def initialize(env_path: '.env')
    config = self.class.load_env(env_path)
    @token = config['TELEGRAM_BOT_TOKEN']
    raise ArgumentError, 'Нет TELEGRAM_BOT_TOKEN в .env (создайте бота через @BotFather)' if @token.to_s.empty?

    @allowed_user_ids = config['ALLOWED_USER_IDS'].to_s.split(',').map { |id| id.strip.to_i }.reject(&:zero?)
    @unu = UnuClient.new(env_path:)
    @offset = 0
  end

  def self.load_env(env_path)
    return {} unless File.exist?(env_path)

    File.readlines(env_path).to_h do |line|
      key, value = line.chomp.split('=', 2)
      [key.to_s.strip, value.to_s.strip]
    end
  end

  def run
    puts 'Бот запущен (long polling)'
    loop do
      updates = get_updates
      updates.each { |update| handle_update(update) }
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError, JSON::ParserError => e
      warn "Ошибка сети: #{e.class}: #{e.message} — повтор через 5 сек"
      sleep 5
    end
  end

  private

  def tg_request(method, params = {})
    uri = URI("#{TG_API}/bot#{@token}/#{method}")
    response = Net::HTTP.post_form(uri, params)
    data = JSON.parse(response.body)
    raise "Telegram API #{method}: #{data['description']}" unless data['ok']

    data['result']
  end

  def get_updates
    tg_request('getUpdates', 'offset' => @offset, 'timeout' => POLL_TIMEOUT)
  end

  def send_message(chat_id, text)
    tg_request('sendMessage', 'chat_id' => chat_id, 'text' => text)
  end

  def handle_update(update)
    @offset = update['update_id'] + 1
    message = update['message'] || update['edited_message']
    return unless message && message['text']

    handle_message(message)
  rescue StandardError => e
    warn "Ошибка обработки update #{update['update_id']}: #{e.class}: #{e.message}"
    send_message(message['chat']['id'], "Ошибка: #{e.message}") if message
  end

  def handle_message(message)
    chat_id = message['chat']['id']
    user_id = message.dig('from', 'id').to_i

    unless @allowed_user_ids.include?(user_id)
      send_message(chat_id, "Доступ запрещён. Ваш Telegram user id: #{user_id}")
      return
    end

    text = message['text'].strip
    case text
    when %r{\A/(start|help)}
      send_message(chat_id, HELP_TEXT)
    when %r{\A/like}
      handle_like(text, chat_id)
    else
      send_message(chat_id, 'Неизвестная команда. /help — справка')
    end
  end

  def handle_like(text, chat_id)
    limit = text[%r{\A/like\s+(\d+)}, 1]&.to_i || DEFAULT_LIMIT
    links = text.scan(%r{https?://\S+})

    if links.empty?
      send_message(chat_id, "Не нашёл ссылок в сообщении.\n\n#{HELP_TEXT}")
      return
    end

    links.each do |link|
      task_id = create_like_task(link, limit)
      send_message(chat_id, "OK: задача ##{task_id} создана (#{limit} лайков)\n#{link}")
    rescue UnuClient::ApiError => e
      send_message(chat_id, "Ошибка UNU для #{link}: #{e.message}")
    end
  end

  def create_like_task(link, limit)
    result = @unu.add_task_start(
      name: 'Лайк комментария ВК',
      descr: "Перейдите по ссылке и поставьте лайк комментарию: #{link}",
      link:,
      need_for_report: 'Скриншот поставленного лайка',
      need_screen: 1,
      price: TASK_PRICE_RUB,
      tarif_id: TASK_TARIF_ID,
      folder_id: TASK_FOLDER_ID,
      add_to_limit: limit
    )
    result['task_id']
  end
end

TelegramBot.new.run if __FILE__ == $PROGRAM_NAME
