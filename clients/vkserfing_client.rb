# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

# Клиент для API VKSerfing (https://vkserfing.ru/api).
# API-ключ читается из переменной окружения VKSERFING-API-KEY или из файла .env.
class VkserfingClient
  API_URL = 'https://vkserfing.ru/api'

  class ApiError < StandardError; end

  attr_reader :api_key

  def initialize(api_key: nil, env_path: '.env')
    @api_key = api_key || self.class.load_key_from_env(env_path)
    raise ArgumentError, 'API-ключ VKSerfing не найден (VKSERFING-API-KEY)' if @api_key.nil? || @api_key.empty?
  end

  def self.load_key_from_env(env_path)
    return ENV['VKSERFING-API-KEY'] if ENV['VKSERFING-API-KEY'] && !ENV['VKSERFING-API-KEY'].empty?

    return nil unless File.exist?(env_path)

    File.readlines(env_path).each do |line|
      key, value = line.chomp.split('=', 2)
      return value&.strip if key&.strip == 'VKSERFING-API-KEY'
    end
    nil
  end

  # Базовый вызов: GET https://vkserfing.ru/api/<method>?token=...
  # Возвращает содержимое поля "data". Бросает ApiError при status == "error".
  # Массивы и вложенные хеши сериализуются в HTTP Array (votes[0][index]=1, country_id[]=1).
  def call(method, params = {})
    query = flatten_params({ token: api_key }.merge(params))
    uri = URI("#{API_URL}/#{method}")
    uri.query = URI.encode_www_form(query)

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      http.get(uri.request_uri)
    end

    raise ApiError, "HTTP #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    data = JSON.parse(response.body)
    if data.is_a?(Hash) && data['status'] == 'error'
      err = data['error'] || {}
      raise ApiError, "#{err['code']}: #{err['message']}"
    end

    data['data']
  end

  # --- Пользователь ---

  def user_balance
    call('user.balance')
  end

  # --- Заказы (campaign) ---

  # Поля заказа: id, name, type, link, status, targeting, money (spent/per_user),
  # users (limit_total/current/left), project
  def campaign_get(count: nil, offset: nil)
    call('campaign.get', compact(count:, offset:))
  end

  def campaign_get_by_id(id:)
    call('campaign.getById', { id: })
  end

  # Список исполнителей, выполнивших заказ: log_id, user_id, name, photo, time
  def campaign_logs(id:, count: nil, offset: nil)
    call('campaign.logs', compact({ id: }.merge(count:, offset:)))
  end

  # Создание заказа. Обязательные: type, link, status, order_id,
  # amount_users_limit (кроме типа vk_poll).
  # type: vk_like, vk_comment, vk_community, vk_share, vk_poll, vk_view, vk_video,
  #       vk_friends, vk_automatic_like, telegram_follower и др. (см. документацию)
  # status: "on" — запустить сразу, "pause" — создать на паузе.
  # order_id — произвольный ID в вашей системе (до 36 символов) для защиты от дублей.
  # Таргетинг и опции — через options: sex, age_from, age_to, country_id, city_id,
  # amount_users_limit_of_day, votes, comments и т.д.
  def campaign_add(type:, link:, status:, order_id:, amount_users_limit: nil, name: nil, project_id: nil, **options)
    call('campaign.add', stringify({
      type:, link:, status:, order_id:,
      amount_users_limit:, name:, project_id:
    }.merge(options)))
  end

  # Редактирование заказа (например campaign_edit(id: 1, status: "pause") — пауза)
  def campaign_edit(id:, **options)
    call('campaign.edit', stringify({ id: }.merge(options)))
  end

  # --- Папки (project) ---

  def project_get(count: nil, offset: nil)
    call('project.get', compact(count:, offset:))
  end

  def project_add(name:)
    call('project.add', { name: })
  end

  def project_edit(id:, name:)
    call('project.edit', { id:, name: })
  end

  def project_delete(id:)
    call('project.delete', { id: })
  end

  # --- Справочники ---

  def util_get_countries(id: nil, name: nil)
    call('util.getCountries', compact(id:, name:))
  end

  # country — ID или название страны; name — поиск по подстроке в названии города
  def util_get_cities(id: nil, name: nil, country: nil, count: nil, offset: nil)
    call('util.getCities', compact(id:, name:, country:, count:, offset:))
  end

  private

  def compact(hash)
    hash.reject { |_, v| v.nil? }.transform_keys(&:to_s)
  end

  def stringify(hash)
    hash.transform_keys(&:to_s)
  end

  def flatten_params(hash, prefix = nil)
    hash.reject { |_, v| v.nil? }.flat_map do |key, value|
      name = prefix ? "#{prefix}[#{key}]" : key.to_s
      case value
      when Hash
        flatten_params(value, name)
      when Array
        value.each_with_index.flat_map do |element, i|
          element.is_a?(Hash) ? flatten_params(element, "#{name}[#{i}]") : [["#{name}[]", element]]
        end
      else
        [[name, value]]
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  client = VkserfingClient.new
  puts JSON.pretty_generate(client.user_balance)
end
