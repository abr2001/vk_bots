# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'

# Файлы состояния ботов — во временную директорию, чтобы тесты не трогали продовые.
TEST_TMP = Dir.mktmpdir('vk_bot_test')
ENV['VKS_WATCHER_OFFSET_FILE'] = File.join(TEST_TMP, '.vks_watcher_offset')
ENV['VKS_WATCHER_SEEN_LINKS_FILE'] = File.join(TEST_TMP, '.vks_watcher_seen_links')
ENV['TASK_LINKS_FILE'] = File.join(TEST_TMP, 'task_links.json')

Minitest.after_run { FileUtils.remove_entry(TEST_TMP) }

# Фейковый HTTP-ответ Net::HTTP
def fake_http_response(code, body)
  klass = Net::HTTPResponse::CODE_TO_OBJ[code.to_s] || Net::HTTPUnknownResponse
  response = klass.new('1.1', code, 'reason')
  response.instance_variable_set(:@body, body)
  response.instance_variable_set(:@read, true)
  response
end

# Подменяет Net::HTTP.start на время блока; записывает URI запроса в recorder.
def with_stubbed_http_get(recorder, response)
  original = Net::HTTP.method(:start)
  Net::HTTP.define_singleton_method(:start) do |host, port, **_opts, &blk|
    recorder[:host] = host
    recorder[:port] = port
    blk&.call(FakeHttpConnection.new(recorder, response))
    response
  end
  yield
ensure
  Net::HTTP.define_singleton_method(:start, original)
end

class FakeHttpConnection
  def initialize(recorder, response)
    @recorder = recorder
    @response = response
  end

  def get(request_uri)
    @recorder[:request_uri] = request_uri
    @response
  end
end

# Подменяет Net::HTTP.post_form; записывает uri и params в recorder.
def with_stubbed_post_form(recorder, response)
  original = Net::HTTP.method(:post_form)
  Net::HTTP.define_singleton_method(:post_form) do |uri, params|
    recorder[:uri] = uri
    recorder[:params] = params
    response
  end
  yield
ensure
  Net::HTTP.define_singleton_method(:post_form, original)
end
