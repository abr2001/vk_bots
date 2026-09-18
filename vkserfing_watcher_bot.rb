# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "set"
require "digest"
require_relative "vkserfing_client"

# Telegram-бот-наблюдатель над VKSerfing: аналог telegram_watcher_bot.rb,
# но вместо задачи UNU создаёт заказ VKSerfing (тип vk_like) со случайным
# лимитом 5–15 лайков. В наблюдаемый чат бот ничего не пишет: и успехи,
# и ошибки уходят админам в личку.
#
# ВНИМАНИЕ: одновременно с telegram_watcher_bot.rb запускать нельзя —
# оба поллят один и тот же TELEGRAM_WATCHER_TOKEN и будут красть друг у друга
# апдейты. Файлы состояния у этого бота свои (VKS_*), поэтому переключение
# туда-сюда безопасно.
#
# Конфиг в .env:
#   TELEGRAM_WATCHER_TOKEN — токен бота от @BotFather
#   TELEGRAM_ADMIN_IDS     — Telegram user id админов через запятую
#   VKSERFING-API-KEY      — ключ VKSerfing (используется VkserfingClient)
class VkserfingWatcherBot
  TG_API = "https://api.telegram.org"
  LINK_RE = %r{https?://(?:www\.)?vk\.(?:com|ru)/wall-?\d+_\d+\?\S*reply=\d+}i
  LIKES_RANGE = (5..15).freeze
  CAMPAIGN_TYPE = "vk_like"
  POLL_TIMEOUT = 30
  OFFSET_FILE = ENV.fetch("VKS_WATCHER_OFFSET_FILE", ".vks_watcher_offset")
  SEEN_LINKS_FILE = ENV.fetch("VKS_WATCHER_SEEN_LINKS_FILE", ".vks_watcher_seen_links")
  SEEN_LINKS_MAX = 5000

  def initialize(env_path: ".env")
    config = self.class.load_env(env_path)
    @token = config["TELEGRAM_WATCHER_TOKEN"]
    raise ArgumentError, "Нет TELEGRAM_WATCHER_TOKEN в .env (создайте отдельного бота через @BotFather)" if @token.to_s.empty?

    @admin_ids = config["TELEGRAM_ADMIN_IDS"].to_s.split(",").map { |id| id.strip.to_i }.reject(&:zero?)

    @vks = VkserfingClient.new(env_path: env_path)
    @offset = load_offset
    @seen_links = load_seen_links
  end

  def self.load_env(env_path)
    return {} unless File.exist?(env_path)

    File.readlines(env_path).to_h do |line|
      key, value = line.chomp.split("=", 2)
      [key.to_s.strip, value.to_s.strip]
    end
  end

  def run
    puts "VKSerfing-наблюдатель запущен (long polling)"
    skip_backlog if @offset.zero?
    loop do
      get_updates.each { |update| handle_update(update) }
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError, JSON::ParserError => e
      warn "Ошибка сети: #{e.class}: #{e.message} — повтор через 5 сек"
      sleep 5
    end
  end

  private

  # Свежий запуск без offset-файла: подтверждаем весь накопившийся бэклог,
  # не обрабатывая его (Telegram хранит неподтверждённые апдейты до 24 ч).
  def skip_backlog
    updates = tg_request("getUpdates", "offset" => -1, "timeout" => 0)
    last = updates.map { |u| u["update_id"] }.max
    return unless last

    @offset = last + 1
    save_offset
    puts "Свежий запуск: бэклог до update_id=#{last} пропущен"
  end

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
    save_seen_links
    limit = rand(LIKES_RANGE)
    campaign_id = create_like_campaign(link, limit)
    notify_admin("VKSerfing: заказ ##{campaign_id} создан (#{limit} лайков)\n#{link}\nЧат: #{chat_label}")
  rescue VkserfingClient::ApiError => e
    if e.message.include?("ORDER_EXISTS")
      warn "VKSerfing: заказ для #{link} уже существует, пропуск"
    else
      warn "Ошибка VKSerfing для #{link}: #{e.message}"
      notify_admin("VKSerfing: ошибка для #{link} (чат #{chat_label}): #{e.message}")
    end
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

  def create_like_campaign(link, limit)
    result = @vks.campaign_add(
      type: CAMPAIGN_TYPE,
      link: link,
      name: "Лайк комментария ВК",
      status: "on",
      order_id: order_id_for(link),
      amount_users_limit: limit
    )
    result["id"] || result
  end

  # Детерминированный order_id: защита от дублей на стороне VKSerfing
  # (повторный заказ с тем же order_id вернёт ORDER_EXISTS)
  def order_id_for(link)
    "vkbot-#{Digest::SHA256.hexdigest(link)[0, 20]}"
  end

  def load_seen_links
    return Set.new unless File.exist?(SEEN_LINKS_FILE)

    Set.new(JSON.parse(File.read(SEEN_LINKS_FILE)))
  rescue JSON::ParserError
    Set.new
  end

  def save_seen_links
    @seen_links = Set.new(@seen_links.to_a.last(SEEN_LINKS_MAX)) if @seen_links.size > SEEN_LINKS_MAX
    File.write(SEEN_LINKS_FILE, JSON.generate(@seen_links.to_a))
  rescue => e
    warn "Не удалось сохранить список ссылок: #{e.class}: #{e.message}"
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
  VkserfingWatcherBot.new.run
end
