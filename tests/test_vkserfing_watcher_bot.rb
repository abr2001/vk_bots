# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../bots/vkserfing_watcher_bot'

# Фейковый клиент VKSerfing: записывает вызовы campaign_add, может кидать ApiError.
class FakeVkserfing
  attr_reader :calls
  attr_accessor :error

  def initialize
    @calls = []
  end

  def campaign_add(**params)
    @calls << params
    raise @error if @error

    { 'id' => 99_999 }
  end
end

class VkserfingWatcherBotTest < Minitest::Test
  LINK = 'https://vk.ru/wall1106804372_42?reply=45'

  def setup
    FileUtils.rm_f(ENV.fetch('VKS_WATCHER_OFFSET_FILE', nil))
    FileUtils.rm_f(ENV.fetch('VKS_WATCHER_SEEN_LINKS_FILE', nil))
    @vks = FakeVkserfing.new
    @sent = []
    @bot = VkserfingWatcherBot.new(env_path: '/nonexistent', token: 'tok', admin_ids: [111, 222], vks: @vks)
    # Перехват отправки в Telegram
    @bot.define_singleton_method(:send_message) { |chat_id, text| @sent << [chat_id, text] }
    @bot.instance_variable_set(:@sent, @sent)
  end

  def make_update(text, id: 1, chat_title: 'Тестовый чат')
    {
      'update_id' => id,
      'message' => { 'text' => text, 'chat' => { 'id' => -100, 'title' => chat_title } }
    }
  end

  # --- Парсинг ссылок ---

  def extract(text)
    @bot.send(:extract_links, text)
  end

  def test_extract_plain_link
    assert_equal [LINK], extract("смотри #{LINK} лайкни")
  end

  def test_extract_vk_com_and_www
    assert_equal 1, extract('https://www.vk.com/wall1_2?reply=3').size
  end

  def test_extract_link_with_thread_param
    assert_equal 1, extract('https://vk.ru/wall1_2?reply=3&thread=4').size
  end

  def test_extract_multiple_links_deduped
    links = extract("#{LINK} и #{LINK} и https://vk.ru/wall5_6?reply=7")
    assert_equal [LINK, 'https://vk.ru/wall5_6?reply=7'], links
  end

  def test_extract_ignores_non_reply_links
    assert_empty extract('https://vk.ru/wall1_2 без reply')
    assert_empty extract('https://t.me/channel/123')
    assert_empty extract('просто текст')
  end

  def test_extract_skips_already_seen
    @bot.instance_variable_get(:@seen_links) << LINK
    assert_empty extract(LINK)
  end

  # --- order_id ---

  def test_order_id_deterministic_and_unique_per_link
    id1 = @bot.send(:order_id_for, LINK)
    assert_equal id1, @bot.send(:order_id_for, LINK)
    refute_equal id1, @bot.send(:order_id_for, 'https://vk.ru/wall9_9?reply=9')
    assert_match(/\Avkbot-[0-9a-f]{20}\z/, id1)
  end

  # --- handle_update / process_link ---

  def test_handle_update_creates_campaign_with_targeting
    @bot.send(:handle_update, make_update(LINK))
    assert_equal 1, @vks.calls.size
    params = @vks.calls.first
    assert_equal 'vk_like', params[:type]
    assert_equal LINK, params[:link]
    assert_includes 5..15, params[:amount_users_limit]
    assert_equal 2, params[:sex]
    assert_equal 22, params[:age_from]
    assert_equal 30, params[:friends_from]
    assert_equal 1, params[:country_id]
    assert_equal @bot.send(:order_id_for, LINK), params[:order_id]
  end

  def test_handle_update_notifies_all_admins
    @bot.send(:handle_update, make_update(LINK))
    assert_equal [111, 222], @sent.map(&:first)
    assert_includes @sent.first.last, 'заказ #99999 создан'
    assert_includes @sent.first.last, LINK
  end

  def test_handle_update_saves_offset
    @bot.send(:handle_update, make_update(LINK, id: 41))
    assert_equal 42, File.read(ENV.fetch('VKS_WATCHER_OFFSET_FILE', nil)).to_i
  end

  def test_duplicate_link_creates_no_campaign
    @bot.send(:handle_update, make_update(LINK, id: 1))
    @bot.send(:handle_update, make_update(LINK, id: 2))
    assert_equal 1, @vks.calls.size
  end

  def test_order_exists_skips_silently
    @vks.error = VkserfingClient::ApiError.new('ORDER_EXISTS: dup')
    @bot.send(:handle_update, make_update(LINK))
    assert_empty @sent
  end

  def test_other_api_error_notifies_admins
    @vks.error = VkserfingClient::ApiError.new('NO_MONEY: недостаточно средств')
    @bot.send(:handle_update, make_update(LINK))
    assert_equal 2, @sent.size
    assert_includes @sent.first.last, 'NO_MONEY'
  end

  def test_update_without_message_or_text_ignored
    @bot.send(:handle_update, { 'update_id' => 5 })
    @bot.send(:handle_update, { 'update_id' => 6, 'message' => { 'chat' => {} } })
    assert_empty @vks.calls
  end

  def test_channel_post_with_caption_processed
    update = {
      'update_id' => 7,
      'channel_post' => { 'caption' => LINK, 'chat' => { 'id' => -100, 'title' => 'Канал' } }
    }
    @bot.send(:handle_update, update)
    assert_equal 1, @vks.calls.size
  end
end
