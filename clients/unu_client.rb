# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

# Клиент для API UNU (https://unu.im/api-info).
# API-ключ читается из переменной окружения UNU-API-KEy или из файла .env.
class UnuClient
  API_URL = 'https://unu.im/api'

  class ApiError < StandardError; end

  attr_reader :api_key

  def initialize(api_key: nil, env_path: '.env')
    @api_key = api_key || self.class.load_key_from_env(env_path)
    raise ArgumentError, 'API-ключ UNU не найден (UNU-API-KEy)' if @api_key.nil? || @api_key.empty?
  end

  def self.load_key_from_env(env_path)
    return ENV['UNU-API-KEy'] if ENV['UNU-API-KEy'] && !ENV['UNU-API-KEy'].empty?

    return nil unless File.exist?(env_path)

    File.readlines(env_path).each do |line|
      key, value = line.chomp.split('=', 2)
      return value&.strip if key&.strip == 'UNU-API-KEy'
    end
    nil
  end

  # Базовый вызов: POST https://unu.im/api с api_key и action.
  # Возвращает распарсенный JSON (Hash). Бросает ApiError при success == 0.
  def call(action, params = {})
    uri = URI(API_URL)
    response = Net::HTTP.post_form(uri, { 'api_key' => api_key, 'action' => action }.merge(params))

    raise ApiError, "HTTP #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    data = JSON.parse(response.body)
    raise ApiError, data['errors'].to_s if data.is_a?(Hash) && [0, false, '0'].include?(data['success'])

    data
  end

  # --- Баланс и финансы ---

  def get_balance
    call('get_balance')
  end

  # date_from/date_to: строки вида "2019-11-01 13:00:00"
  def get_expenses(task_id: nil, folder_id: nil, date_from: nil, date_to: nil)
    call('get_expenses', compact(task_id:, folder_id:, date_from:, date_to:))
  end

  # --- Папки ---

  def get_folders
    call('get_folders')
  end

  def create_folder(name:)
    call('create_folder', { 'name' => name })
  end

  def del_folder(folder_id:)
    call('del_folder', { 'folder_id' => folder_id })
  end

  def move_task(task_id:, folder_id:)
    call('move_task', { 'task_id' => task_id, 'folder_id' => folder_id })
  end

  # --- Задачи ---

  # status/task_id можно передавать массивом — склеятся через запятую
  def get_tasks(folder_id: nil, status: nil, task_id: nil, offset: nil)
    call('get_tasks', compact(
                        folder_id:,
                        status: join_list(status),
                        task_id: join_list(task_id),
                        offset:
                      ))
  end

  # Создание задачи. Обязательные: name, descr, need_for_report, price, tarif_id, folder_id.
  # Остальные параметры (лимиты, таргетинг, расписание) — через options, см. https://unu.im/api-info
  def add_task(name:, descr:, need_for_report:, price:, tarif_id:, folder_id:, **options)
    call('add_task', stringify({
      name:, descr:, need_for_report:,
      price:, tarif_id:, folder_id:
    }.merge(options)))
  end

  # add_task + task_limit_add одним запросом (отдельный action в API)
  def add_task_start(add_to_limit:, name:, descr:, need_for_report:, price:, tarif_id:, folder_id:, **options)
    call('add_task_start', stringify({
      add_to_limit:, name:, descr:, need_for_report:,
      price:, tarif_id:, folder_id:
    }.merge(options)))
  end

  def task_limit_add(task_id:, add_to_limit:)
    call('task_limit_add', { 'task_id' => task_id, 'add_to_limit' => add_to_limit })
  end

  def task_limit_sub(task_id:, sub_to_limit:)
    call('task_limit_sub', { 'task_id' => task_id, 'sub_to_limit' => sub_to_limit })
  end

  def edit_task(task_id:, **options)
    call('edit_task', stringify({ task_id: }.merge(options)))
  end

  def del_task(task_id:)
    call('del_task', { 'task_id' => task_id })
  end

  def task_pause(task_id:)
    call('task_pause', { 'task_id' => task_id })
  end

  def task_play(task_id:)
    call('task_play', { 'task_id' => task_id })
  end

  def task_to_top(task_id:)
    call('task_to_top', { 'task_id' => task_id })
  end

  # --- Отчёты ---

  def get_reports(task_id:, offset: nil)
    call('get_reports', compact(task_id: join_list(task_id), offset:))
  end

  def approve_report(report_id:)
    call('approve_report', { 'report_id' => report_id })
  end

  # reject_type: 1 — на доработку, 2 — отказ
  def reject_report(report_id:, comment:, reject_type:)
    call('reject_report', { 'report_id' => report_id, 'comment' => comment, 'reject_type' => reject_type })
  end

  # --- Справочники ---

  def get_tariffs
    call('get_tariffs')
  end

  def get_countries
    call('get_countries')
  end

  # --- Чёрный / белый списки ---

  def add_blacklist(user_id)
    call('add_blacklist', { 'add_blacklist_id' => user_id })
  end

  def get_blacklist
    call('get_blacklist')
  end

  def del_blacklist(user_id)
    call('del_blacklist', { 'id_user_blacklist' => user_id })
  end

  def add_whitelist(user_id)
    call('add_whitelist', { 'add_whitelist_id' => user_id })
  end

  private

  def compact(hash)
    hash.compact.transform_keys(&:to_s)
  end

  def stringify(hash)
    hash.transform_keys(&:to_s)
  end

  def join_list(value)
    value.is_a?(Array) ? value.join(',') : value
  end
end

if __FILE__ == $PROGRAM_NAME
  client = UnuClient.new
  puts JSON.pretty_generate(client.get_balance)
end
