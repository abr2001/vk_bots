# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require_relative "unu_client"

# Автоаппрув отчётов UNU: раз в INTERVAL_SECONDS находит активные задачи,
# берёт их отчёты со статусом 2 («на проверке») и аппрувит (оплачивает).
# О каждом аппруве и об ошибках пишет в stdout и, если заданы
# TELEGRAM_WATCHER_TOKEN + TELEGRAM_ADMIN_IDS в .env, дублирует в Telegram.
#
# Запуск: ruby unu_autoapprove.rb           — бесконечный цикл
#         ruby unu_autoapprove.rb --once    — один проход (для теста)
class UnuAutoapprove
  INTERVAL_SECONDS = 300
  TG_API = "https://api.telegram.org"

  def initialize(env_path: ".env")
    @unu = UnuClient.new(env_path: env_path)
    config = TelegramWatcherConfig.load(env_path)
    @tg_token = config["TELEGRAM_WATCHER_TOKEN"]
    @admin_ids = config["TELEGRAM_ADMIN_IDS"].to_s.split(",").map { |id| id.strip.to_i }.reject(&:zero?)
  end

  def run
    loop do
      pass
      sleep INTERVAL_SECONDS
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError => e
      log "ошибка сети: #{e.class}: #{e.message} — повтор через 60 сек"
      sleep 60
    end
  end

  def pass
    task_ids = active_task_ids
    log "активных задач: #{task_ids.size}"
    return if task_ids.empty?

    reports = pending_reports(task_ids)
    log "отчётов на проверке: #{reports.size}"

    reports.each { |report| approve(report) }
  rescue UnuClient::ApiError => e
    log "ошибка API: #{e.message}"
    notify_admin("Автоаппрув UNU: ошибка API: #{e.message}")
  end

  private

  def active_task_ids
    tasks = @unu.get_tasks(status: 4)["tasks"] || []
    tasks.map { |t| t["id"] }
  end

  # get_reports принимает несколько task_id через запятую
  def pending_reports(task_ids)
    reports = @unu.get_reports(task_id: task_ids)["reports"] || []
    reports.select { |r| r["status"].to_i == 2 }
  end

  def approve(report)
    @unu.approve_report(report_id: report["id"])
    log "аппрув: отчёт ##{report["id"]}, задача ##{report["task_id"]}, исполнитель #{report["worker_id"]}"
    notify_admin("UNU: аппрув отчёта ##{report["id"]} (задача ##{report["task_id"]})")
  rescue UnuClient::ApiError => e
    log "ошибка аппрува отчёта ##{report["id"]}: #{e.message}"
    notify_admin("UNU: ошибка аппрува отчёта ##{report["id"]}: #{e.message}")
  end

  def notify_admin(text)
    return if @tg_token.to_s.empty? || @admin_ids.empty?

    @admin_ids.each do |admin_id|
      uri = URI("#{TG_API}/bot#{@tg_token}/sendMessage")
      Net::HTTP.post_form(uri, "chat_id" => admin_id, "text" => text)
    rescue => e
      warn "не удалось уведомить админа #{admin_id}: #{e.class}: #{e.message}"
    end
  end

  def log(text)
    puts "[#{Time.now.strftime("%Y-%m-%d %H:%M:%S")}] #{text}"
  end
end

# Чтение .env без зависимости от telegram_watcher_bot.rb
class TelegramWatcherConfig
  def self.load(env_path)
    return {} unless File.exist?(env_path)

    File.readlines(env_path).to_h do |line|
      key, value = line.chomp.split("=", 2)
      [key.to_s.strip, value.to_s.strip]
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  $stdout.sync = true
  bot = UnuAutoapprove.new
  if ARGV.include?("--once")
    bot.pass
  else
    bot.run
  end
end
