# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../clients/vkserfing_client'

class VkserfingClientTest < Minitest::Test
  def setup
    @client = VkserfingClient.new(api_key: 'testkey')
  end

  def test_raises_without_key
    assert_raises(ArgumentError) { VkserfingClient.new(api_key: '', env_path: '/nonexistent') }
    assert_raises(ArgumentError) { VkserfingClient.new(env_path: '/nonexistent') }
  end

  def test_flatten_params_scalars
    flat = @client.send(:flatten_params, { 'a' => 1, 'b' => 'x', 'c' => nil })
    assert_includes flat, ['a', 1]
    assert_includes flat, %w[b x]
    refute(flat.any? { |k, _| k == 'c' })
  end

  def test_flatten_params_array_http_style
    flat = @client.send(:flatten_params, { 'country_id' => [1, 2] })
    assert_equal [['country_id[]', 1], ['country_id[]', 2]], flat
  end

  def test_flatten_params_array_of_hashes
    flat = @client.send(:flatten_params, { 'votes' => [{ 'index' => 1, 'value' => 3 }] })
    assert_equal [['votes[0][index]', 1], ['votes[0][value]', 3]], flat
  end

  def test_call_returns_data_and_sends_token
    recorder = {}
    body = JSON.generate('status' => 'ok', 'data' => { 'balance' => 88.0 })
    result = with_stubbed_http_get(recorder, fake_http_response(200, body)) do
      @client.user_balance
    end
    assert_equal({ 'balance' => 88.0 }, result)
    assert_equal 'vkserfing.ru', recorder[:host]
    query = URI.decode_www_form(URI(recorder[:request_uri]).query).to_h
    assert_equal 'testkey', query['token']
    assert_includes recorder[:request_uri], '/api/user.balance'
  end

  def test_call_raises_api_error_on_error_status
    body = JSON.generate('status' => 'error', 'error' => { 'code' => 'ORDER_EXISTS', 'message' => 'dup' })
    error = assert_raises(VkserfingClient::ApiError) do
      with_stubbed_http_get({}, fake_http_response(200, body)) { @client.user_balance }
    end
    assert_equal 'ORDER_EXISTS: dup', error.message
  end

  def test_call_raises_on_http_failure
    error = assert_raises(VkserfingClient::ApiError) do
      with_stubbed_http_get({}, fake_http_response(500, 'oops')) { @client.user_balance }
    end
    assert_includes error.message, 'HTTP 500'
  end

  def test_campaign_add_sends_all_params_with_targeting
    recorder = {}
    body = JSON.generate('status' => 'ok', 'data' => { 'id' => 12_345 })
    with_stubbed_http_get(recorder, fake_http_response(200, body)) do
      @client.campaign_add(
        type: 'vk_like', link: 'https://vk.ru/wall1_2?reply=3', status: 'on',
        order_id: 'vkbot-abc', amount_users_limit: 10, name: 'test',
        sex: 2, age_from: 22, country_id: 1
      )
    end
    query = URI.decode_www_form(URI(recorder[:request_uri]).query).to_h
    assert_equal 'vk_like', query['type']
    assert_equal 'https://vk.ru/wall1_2?reply=3', query['link']
    assert_equal '10', query['amount_users_limit']
    assert_equal '2', query['sex']
    assert_equal '22', query['age_from']
    assert_equal '1', query['country_id']
  end
end
