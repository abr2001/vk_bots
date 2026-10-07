# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../clients/vkserfing_client'

class VkserfingClientTest < Minitest::Test
  def setup
    @client = VkserfingClient.new(api_key: 'testkey')
  end

  def stub_api(body, status: 200)
    body = JSON.generate(body) unless body.is_a?(String)
    stub_request(:get, %r{vkserfing\.ru/api/}).to_return(status:, body:)
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
    stub_api({ 'status' => 'ok', 'data' => { 'balance' => 88.0 } })
    result = @client.user_balance
    assert_equal({ 'balance' => 88.0 }, result)
    assert_requested(:get, %r{vkserfing\.ru/api/user\.balance}) do |req|
      query_params(req)['token'] == 'testkey'
    end
  end

  def test_call_raises_api_error_on_error_status
    stub_api({ 'status' => 'error', 'error' => { 'code' => 'ORDER_EXISTS', 'message' => 'dup' } })
    error = assert_raises(VkserfingClient::ApiError) { @client.user_balance }
    assert_equal 'ORDER_EXISTS: dup', error.message
  end

  def test_call_raises_on_http_failure
    stub_api('oops', status: 500)
    error = assert_raises(VkserfingClient::ApiError) { @client.user_balance }
    assert_includes error.message, 'HTTP 500'
  end

  def test_campaign_add_sends_all_params_with_targeting
    stub_api({ 'status' => 'ok', 'data' => { 'id' => 12_345 } })
    @client.campaign_add(
      type: 'vk_like', link: 'https://vk.ru/wall1_2?reply=3', status: 'on',
      order_id: 'vkbot-abc', amount_users_limit: 10, name: 'test',
      sex: 2, age_from: 22, country_id: 1
    )
    assert_requested(:get, %r{vkserfing\.ru/api/campaign\.add}) do |req|
      q = query_params(req)
      q['type'] == 'vk_like' &&
        q['link'] == 'https://vk.ru/wall1_2?reply=3' &&
        q['amount_users_limit'] == '10' &&
        q['sex'] == '2' &&
        q['age_from'] == '22' &&
        q['country_id'] == '1'
    end
  end
end
