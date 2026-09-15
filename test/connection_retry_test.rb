require "minitest/autorun"
require "zoho_hub"

class ConnectionRetryTest < Minitest::Test
  class Adapter < Faraday::Adapter
    class << self
      attr_accessor :statuses, :calls
    end

    def call(env)
      super
      self.class.calls << [env.method, env.url.path]
      status = self.class.statuses.shift || 200
      save_response(env, status, '{"data":[{"id":"1"}]}', "content-type" => "application/json")
      @app.call(env)
    end
  end

  def setup
    @original_adapter = Faraday.default_adapter
    Faraday.default_adapter = Adapter
    Adapter.calls = []
    ZohoHub.configuration.debug = false
    @connection = ZohoHub::Connection.new(access_token: "test")
  end

  def teardown
    Faraday.default_adapter = @original_adapter
  end

  def test_coql_retries_429_and_503_on_v8
    Adapter.statuses = [429, 503, 200]
    assert_equal "1", @connection.post("coql", select_query: "SELECT id FROM Contacts").dig(:data, 0, :id)
    assert_equal [[:post, "/crm/v8/coql"]] * 3, Adapter.calls
  end

  def test_record_creates_are_not_replayed_on_500
    Adapter.statuses = [500, 200]
    assert_raises(ZohoHub::ZohoAPIError) { @connection.post("Contacts", data: [{}]) }
    assert_equal 1, Adapter.calls.size
  end

  def test_get_retries_and_preserves_failure_after_exhaustion
    Adapter.statuses = [503] * 4
    assert_raises(ZohoHub::ZohoAPIError) { @connection.get("Contacts") }
    assert_equal 4, Adapter.calls.size
  end
end
