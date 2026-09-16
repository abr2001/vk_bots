# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "set"
require_relative "unu_client"

# Telegram-бот-наблюдатель: его добавляют в чат или канал (в канал — как администратора),
# и на каждую ссылку на комментарий VK вида https://vk.ru/wall711835918_3621?reply=3630
# он создаёт задачу в UNU (тариф «Лайки») со случайным лимитом 5–15 лайков.
# В наблюдаемый чат бот ничего не пишет: и успехи, и ошибки уходят админу в личку.
#
# Конфиг в .env:
#   TELEGRAM_WATCHER_TOKEN — токен отдельного бота от @BotFather
#   TELEGRAM_ADMIN_IDS     — Telegram user id админов через запятую, им бот шлёт все уведомления
#   UNU-API-KEy            — ключ UNU (используется UnuClient)
class TelegramWatcherBot
  TG_API = "https://api.telegram.org"
  LINK_RE = %r{https?://(?:www\.)?vk\.(?:com|ru)/wall-?\d+_\d+\?\S*reply=\d+}i
  LIKES_RANGE = (5..15).freeze
  TASK_PRICE_RUB = 1.0
  TASK_TARIF_ID = 1 # «Лайки»
  TASK_FOLDER_ID = 0 # «Мои задачи»
  POLL_TIMEOUT = 30
  OFFSET_FILE = ENV.fetch("WATCHER_OFFSET_FILE", ".watcher_offset")
  # task_id -> ссылка: реестр нужен автоаппруву для сводки (API ссылку не возвращает)
  TASK_LINKS_FILE = ENV.fetch("TASK_LINKS_FILE", "task_links.json")

  def initialize(env_path: ".env")
    config = self.class.load_env(env_path)
    @token = config["TELEGRAM_WATCHER_TOKEN"]
    raise ArgumentError, "Нет TELEGRAM_WATCHER_TOKEN в .env (создайте отдельного бота через @BotFather)" if @token.to_s.empty?

    @admin_ids = config["TELEGRAM_ADMIN_IDS"].to_s.split(",").map { |id| id.strip.to_i }.reject(&:zero?)

    @unu = UnuClient.new(env_path: env_path)
    @offset = load_offset
    @seen_links = Set.new
  end

  def self.load_env(env_path)
    return {} unless File.exist?(env_path)

    File.readlines(env_path).to_h do |line|
      key, value = line.chomp.split("=", 2)
      [key.to_s.strip, value.to_s.strip]
    end
  end

  def run
    puts "Наблюдатель запущен (long polling)"
    loop do
      get_updates.each { |update| handle_update(update) }
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
    raise "Telegram API #{method}: #{data["description"]}" unless data["ok"]

    data["result"]
  end

  def get_updates
    tg_request("getUpdates", "offset" => @offset, "timeout" => POLL_TIMEOUT)
  end

  def send_message(chat_id, text)
    tg_request("sendMessage", "chat_id" => chat_id, "text" => text)
  end

  # Посты каналов приходят как channel_post, сообщения групп — как message;
  # учитываем и редактирования, и подписи к медиа (caption).
  def handle_update(update)
    @offset = update["update_id"] + 1
    save_offset

    message = update["message"] || update["edited_message"] ||
              update["channel_post"] || update["edited_channel_post"]
    return unless message

    text = message["text"] || message["caption"]
    return unless text

    links = extract_links(text)
    return if links.empty?

    chat = message["chat"] || {}
    chat_label = chat["title"] || chat["username"] || chat["id"]
    links.each { |link| process_link(link, chat_label) }
  rescue => e
    warn "Ошибка обработки update #{update["update_id"]}: #{e.class}: #{e.message}"
  end

  def extract_links(text)
    text.scan(LINK_RE).uniq.reject { |link| @seen_links.include?(link) }
  end

  def process_link(link, chat_label)
    @seen_links << link
    limit = rand(LIKES_RANGE)
    task_id = create_like_task(link, limit)
    save_task_link(task_id, link)
    notify_admin("UNU: задача ##{task_id} создана (#{limit} лайков)\n#{link}\nЧат: #{chat_label}")
  rescue UnuClient::ApiError => e
    warn "Ошибка UNU для #{link}: #{e.message}"
    notify_admin("UNU: ошибка для #{link} (чат #{chat_label}): #{e.message}")
  end

  def notify_admin(text)
    if @admin_ids.empty?
      warn "TELEGRAM_ADMIN_IDS не задан, сообщение не доставлено: #{text}"
      return
    end

    @admin_ids.each do |admin_id|
      send_message(admin_id, text)
    rescue => e
      warn "Не удалось отправить сообщение админу #{admin_id}: #{e.class}: #{e.message}"
    end
  end

  def create_like_task(link, limit)
    result = @unu.add_task_start(
      name: "Лайк комментария ВК",
      descr: "Перейдите по ссылке и поставьте лайк комментарию: #{link}",
      link: link,
      need_for_report: "Скриншот поставленного лайка",
      need_screen: 1,
      price: TASK_PRICE_RUB,
      tarif_id: TASK_TARIF_ID,
      folder_id: TASK_FOLDER_ID,
      add_to_limit: limit
    )
    result["task_id"]
  end

  def save_task_link(task_id, link)
    links = File.exist?(TASK_LINKS_FILE) ? JSON.parse(File.read(TASK_LINKS_FILE)) : {}
    links[task_id.to_s] = link
    File.write(TASK_LINKS_FILE, JSON.pretty_generate(links))
  rescue => e
    warn "Не удалось сохранить ссылку задачи ##{task_id}: #{e.class}: #{e.message}"
  end

  def load_offset
    return 0 unless File.exist?(OFFSET_FILE)

    File.read(OFFSET_FILE).strip.to_i
  end

  def save_offset
    File.write(OFFSET_FILE, @offset.to_s)
  end
end

if __FILE__ == $PROGRAM_NAME
  $stdout.sync = true
  TelegramWatcherBot.new.run
end
