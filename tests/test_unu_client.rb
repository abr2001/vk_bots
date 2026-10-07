# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../clients/unu_client'

class UnuClientTest < Minitest::Test
  API_URL = 'https://unu.im/api'

  def setup
    @client = UnuClient.new(api_key: 'testkey')
  end

  def stub_api(body, status: 200)
    stub_request(:post, API_URL).to_return(status:, body: JSON.generate(body))
  end

  def test_raises_without_key
    assert_raises(ArgumentError) { UnuClient.new(api_key: '', env_path: '/nonexistent') }
    assert_raises(ArgumentError) { UnuClient.new(env_path: '/nonexistent') }
  end

  def test_call_posts_api_key_and_action
    stub_api({ 'success' => 1, 'balance' => 10.5 })
    result = @client.get_balance
    assert_equal 10.5, result['balance']
    assert_requested(:post, API_URL) do |req|
      form = form_body(req)
      form['api_key'] == 'testkey' && form['action'] == 'get_balance'
    end
  end

  def test_call_raises_on_success_zero
    stub_api({ 'success' => 0, 'errors' => 'bad key' })
    error = assert_raises(UnuClient::ApiError) { @client.get_balance }
    assert_includes error.message, 'bad key'
  end

  def test_get_tasks_joins_arrays_with_comma
    stub_api({ 'success' => 1 })
    @client.get_tasks(status: [1, 4], task_id: [10, 20])
    assert_requested(:post, API_URL) do |req|
      form = form_body(req)
      form['status'] == '1,4' && form['task_id'] == '10,20'
    end
  end

  def test_get_reports_joins_task_ids
    stub_api({ 'success' => 1 })
    @client.get_reports(task_id: [7, 8, 9])
    assert_requested(:post, API_URL) do |req|
      form_body(req)['task_id'] == '7,8,9'
    end
  end

  def test_add_task_start_merges_options
    stub_api({ 'success' => 1 })
    @client.add_task_start(add_to_limit: 10, name: 'n', descr: 'd', need_for_report: 'r',
                           price: 0.5, tarif_id: 1, folder_id: 2, country_id: 1)
    assert_requested(:post, API_URL) do |req|
      form = form_body(req)
      form['action'] == 'add_task_start' && form['add_to_limit'] == '10' && form['country_id'] == '1'
    end
  end
end
