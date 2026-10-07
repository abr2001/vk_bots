# frozen_string_literal: true

require 'minitest/autorun'
require 'webmock/minitest'
require 'tmpdir'
require 'fileutils'
require 'json'

# Файлы состояния ботов — во временную директорию, чтобы тесты не трогали продовые.
TEST_TMP = Dir.mktmpdir('vk_bot_test')
ENV['VKS_WATCHER_OFFSET_FILE'] = File.join(TEST_TMP, '.vks_watcher_offset')
ENV['VKS_WATCHER_SEEN_LINKS_FILE'] = File.join(TEST_TMP, '.vks_watcher_seen_links')
ENV['TASK_LINKS_FILE'] = File.join(TEST_TMP, 'task_links.json')

Minitest.after_run { FileUtils.remove_entry(TEST_TMP) }

# Декодирует form-encoded тело POST-запроса в хэш.
def form_body(request)
  URI.decode_www_form(request.body).to_h
end

# Декодирует query GET-запроса в хэш.
def query_params(request)
  URI.decode_www_form(request.uri.query.to_s).to_h
end
