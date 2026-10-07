# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../clients/unu_client'

class UnuClientTest < Minitest::Test
  def setup
    @client = UnuClient.new(api_key: 'testkey')
  end

  def test_raises_without_key
    assert_raises(ArgumentError) { UnuClient.new(api_key: '', env_path: '/nonexistent') }
    assert_raises(ArgumentError) { UnuClient.new(env_path: '/nonexistent') }
  end

  def test_call_posts_api_key_and_action
    recorder = {}
    body = JSON.generate('success' => 1, 'balance' => 10.5)
    result = with_stubbed_post_form(recorder, fake_http_response(200, body)) do
      @client.get_balance
    end
    assert_equal 10.5, result['balance']
    assert_equal 'https://unu.im/api', recorder[:uri].to_s
    assert_equal 'testkey', recorder[:params]['api_key']
    assert_equal 'get_balance', recorder[:params]['action']
  end

  def test_call_raises_on_success_zero
    body = JSON.generate('success' => 0, 'errors' => 'bad key')
    error = assert_raises(UnuClient::ApiError) do
      with_stubbed_post_form({}, fake_http_response(200, body)) { @client.get_balance }
    end
    assert_includes error.message, 'bad key'
  end

  def test_get_tasks_joins_arrays_with_comma
    recorder = {}
    with_stubbed_post_form(recorder, fake_http_response(200, JSON.generate('success' => 1))) do
      @client.get_tasks(status: [1, 4], task_id: [10, 20])
    end
    assert_equal '1,4', recorder[:params]['status']
    assert_equal '10,20', recorder[:params]['task_id']
  end

  def test_get_reports_joins_task_ids
    recorder = {}
    with_stubbed_post_form(recorder, fake_http_response(200, JSON.generate('success' => 1))) do
      @client.get_reports(task_id: [7, 8, 9])
    end
    assert_equal '7,8,9', recorder[:params]['task_id']
  end

  def test_add_task_start_merges_options
    recorder = {}
    with_stubbed_post_form(recorder, fake_http_response(200, JSON.generate('success' => 1))) do
      @client.add_task_start(add_to_limit: 10, name: 'n', descr: 'd', need_for_report: 'r',
                             price: 0.5, tarif_id: 1, folder_id: 2, country_id: 1)
    end
    assert_equal 'add_task_start', recorder[:params]['action']
    assert_equal '10', recorder[:params]['add_to_limit'].to_s
    assert_equal '1', recorder[:params]['country_id'].to_s
  end
end
