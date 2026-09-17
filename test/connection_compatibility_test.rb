# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/mock'
require 'timeout'
require 'zoho_hub'

class ConnectionCompatibilityTest < Minitest::Test
  class Adapter < Faraday::Adapter
    class << self
      attr_accessor :responses, :calls, :responder
    end

    def call(env)
      super
      self.class.calls << [env.method, env.url.path, env.request_headers['Authorization']]
      if self.class.responder
        status, body, headers = self.class.responder.call(env)
      else
        status, body, headers = self.class.responses.shift
      end
      save_response(env, status, body, headers)
      @app.call(env)
    end
  end

  class Contact < ZohoHub::BaseRecord
    request_path 'Contacts'
    attributes :id, :subject
  end

  def setup
    @original_adapter = Faraday.default_adapter
    @original_connection = ZohoHub.connection
    Faraday.default_adapter = Adapter
    Adapter.calls = []
    Adapter.responder = nil
    ZohoHub.configuration.debug = false
    @connection = ZohoHub::Connection.new(access_token: 'old', refresh_token: 'refresh')
    ZohoHub.instance_variable_set(:@connection, @connection)
  end

  def teardown
    Faraday.default_adapter = @original_adapter
    ZohoHub.instance_variable_set(:@connection, @original_connection)
  end

  def json_response(status, data)
    [status, JSON.generate(data), { 'content-type' => 'application/json' }]
  end

  def test_note_create_includes_multi_module_parent_without_changing_related_route
    Adapter.responder = lambda do |env|
      assert_equal :post, env.method
      assert_equal '/crm/v8/Contacts/123/Notes', env.url.path
      payload = JSON.parse(env.body).fetch('data').first
      assert_equal 'Agent Note', payload['Note_Title']
      assert_equal 'Follow up', payload['Note_Content']
      assert_equal({ 'module' => { 'api_name' => 'Contacts' }, 'id' => '123' },
                   payload['Parent_Id'])
      json_response(201, data: [{ code: 'SUCCESS', status: 'success', details: { id: '456' } }])
    end
    response = Contact.add_note(id: '123', title: 'Agent Note', content: 'Follow up')
    assert_equal 'SUCCESS', response.dig(:data, 0, :code)
    assert_equal 1, Adapter.calls.size
  end

  def test_attachment_list_requests_required_metadata_fields
    Adapter.responder = lambda do |env|
      assert_equal '/crm/v8/Contacts/123/Attachments', env.url.path
      fields = URI.decode_www_form(env.url.query).to_h.fetch('fields').split(',')
      assert_includes fields, 'id'
      assert_includes fields, 'File_Name'
      assert_includes fields, 'Parent_Id'
      json_response(200, data: [{ id: '456', File_Name: 'benefits.pdf' }])
    end
    assert_equal 'benefits.pdf', Contact.related_attachments(parent_id: '123').first.file_name
  end

  def test_new_auth_grants_cover_coql_and_user_reads_without_changing_oauth_version
    uri = Addressable::URI.parse(ZohoHub::Auth.auth_url)
    scopes = uri.query_values.fetch('scope').split(',')
    assert_includes scopes, 'ZohoCRM.coql.READ'
    assert_includes scopes, 'ZohoCRM.users.READ'
    assert_equal '/oauth/v2/auth', uri.path
  end

  def test_structured_validation_errors_keep_their_existing_exception_type
    Adapter.responses = [json_response(400,
                                       data: [{ code: 'MANDATORY_NOT_FOUND',
                                                message: 'required field not found',
                                                details: {} }])]
    error = assert_raises(ZohoHub::MandatoryNotFound) { Contact.create(subject: '') }
    assert_equal 'required field not found', error.message
    assert_equal 1, Adapter.calls.size
  end

  def test_structured_coql_errors_reach_the_query_error_handler
    Adapter.responses = [json_response(400, code: 'INVALID_QUERY', message: 'invalid query',
                                            details: {})]
    assert_raises(ZohoHub::InvalidQuery) { Contact.query('SELECT invalid FROM Contacts') }
  end

  def test_html_gateway_failure_retries_before_json_decoding
    Adapter.responses = [[502, '<html>Bad Gateway</html>', { 'content-type' => 'text/html' }],
                         json_response(200, data: [{ id: '1' }])]
    assert_equal '1', @connection.get('Contacts').dig(:data, 0, :id)
    assert_equal 2, Adapter.calls.size
  end

  def test_exhausted_html_gateway_failure_is_not_an_empty_success
    Adapter.responses = Array.new(4) do
      [502, '<html>Bad Gateway</html>', { 'content-type' => 'text/html' }]
    end
    assert_raises(ZohoHub::ZohoAPIError) { @connection.get('Contacts') }
    assert_equal 4, Adapter.calls.size
  end

  def test_binary_download_refreshes_token_without_parsing_pdf_bytes
    pdf = "%PDF-1.4\n\x00\xFF".b
    Adapter.responses = [json_response(401, code: 'INVALID_TOKEN', message: 'expired'),
                         [200, pdf, { 'content-type' => 'application/pdf' }]]
    ZohoHub::Auth.stub(:refresh_token, { access_token: 'new' }) do
      response = @connection.get_binary('Products/1/actions/download_fields_attachment',
                                        fields_attachment_id: '2')
      assert_equal pdf, response.body
      assert_equal 'application/pdf', response.headers['content-type']
    end
    assert_equal ['Zoho-oauthtoken old', 'Zoho-oauthtoken new'], Adapter.calls.map(&:last)
  end

  def test_base_adapter_keeps_faraday_api_and_uses_current_token
    Adapter.responses = [[200, 'pdf', {}], [200, 'pdf', {}]]
    assert_kind_of Faraday::Connection, @connection.base_adapter
    @connection.base_adapter.get('Products/1/Attachments/2')
    @connection.access_token = 'new'
    @connection.base_adapter.get('Products/1/Attachments/2')
    assert_equal ['Zoho-oauthtoken old', 'Zoho-oauthtoken new'], Adapter.calls.map(&:last)
  end

  def test_field_attachment_uses_refresh_aware_download
    Adapter.responses = [json_response(401, code: 'INVALID_TOKEN', message: 'expired'),
                         [200, '%PDF-content',
                          { 'content-disposition' => "attachment; filename*=UTF-8''benefits.pdf",
                            'content-type' => 'application/pdf' }]]
    file = nil
    ZohoHub::Auth.stub(:refresh_token, { access_token: 'new' }) do
      file = Contact.field_attachment(id: '1', attachment_id: '2')
      file.rewind
      assert_equal '%PDF-content', file.read
    end
    expected_path = '/crm/v8/Contacts/1/actions/download_fields_attachment'
    assert_equal([expected_path] * 2, Adapter.calls.map { |call| call[1] })
  ensure
    file&.close!
  end

  def test_related_attachment_retries_and_returns_metadata_and_pdf
    Adapter.responses = [
      json_response(200, data: [{ id: '2', File_Name: 'benefits.pdf' }]),
      [503, '<html>Unavailable</html>', { 'content-type' => 'text/html' }],
      [200, '%PDF-related', { 'content-type' => 'application/pdf' }]
    ]
    attachment = Contact.download_attachment(parent_id: '1', attachment_id: '2')
    assert_equal 'benefits.pdf', attachment.file_name
    assert_equal 'application/pdf', attachment.content_type
    assert_equal '%PDF-related', attachment.file.read
    assert_equal 3, Adapter.calls.size
  ensure
    attachment&.file&.close!
  end

  def test_rate_limited_creates_are_not_replayed
    Adapter.responses = [json_response(429, code: 'TOO_MANY_REQUESTS', message: 'limited'),
                         json_response(201, data: [])]
    assert_raises(ZohoHub::ZohoAPIError) { Contact.create(subject: 'Call') }
    assert_equal 1, Adapter.calls.size
  end

  def test_binary_permission_error_never_becomes_a_downloaded_file
    Adapter.responses = [json_response(403, code: 'NO_PERMISSION', message: 'denied')]
    assert_raises(ZohoHub::ZohoAPIError) { Contact.field_attachment(id: '1', attachment_id: '2') }
  end

  def test_concurrent_expired_requests_only_refresh_once
    setup_concurrent_test
    execute_concurrent_requests
    assert_single_refresh
  ensure
    cleanup_threads
  end

  private

  def setup_concurrent_test
    @arrived = Queue.new
    @release = Queue.new
    @refreshes = 0
    @threads = []
  end

  def execute_concurrent_requests
    Adapter.responder = method(:responder_for_concurrent_test)
    ZohoHub::Auth.stub(:refresh_token, method(:increment_refresh)) do
      Timeout.timeout(3) do
        @threads = Array.new(2) { Thread.new { @connection.get('Contacts') } }
        2.times { @arrived.pop }
        2.times { @release << true }
        results = @threads.map { |t| t.value.dig(:data, 0, :id) }
        assert_equal(%w[1 1], results)
      end
    end
  end

  def responder_for_concurrent_test(env)
    if env.request_headers['Authorization'].end_with?(' old')
      @arrived << true
      @release.pop
      json_response(401, code: 'INVALID_TOKEN', message: 'expired')
    else
      json_response(200, data: [{ id: '1' }])
    end
  end

  def increment_refresh(*_args)
    @refreshes += 1
    { access_token: 'new' }
  end

  def assert_single_refresh
    assert_equal 1, @refreshes
  end

  def cleanup_threads
    @threads&.each { |thread| thread.kill if thread.alive? }
  end
end
