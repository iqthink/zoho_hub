# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/mock'
require 'zoho_hub'

class RecordsV8Test < Minitest::Test
  class Contact < ZohoHub::BaseRecord
    request_path 'Contacts'
    attributes :id, :first_name
  end

  def test_all_sends_required_fields_without_mutating_caller_params
    params = { per_page: 10 }
    seen = nil
    Contact.stub(:get, lambda { |path, options|
      seen = [path, options]
      { data: [{ id: '1', First_Name: 'Test' }] }
    }) do
      assert_equal 'Test', Contact.all(params).first.first_name
    end
    assert_equal 'id,First_Name', seen.last[:fields]
    assert_equal({ per_page: 10 }, params)
  end

  def test_page_token_does_not_add_conflicting_page_number
    Contact.stub(:get, lambda { |_, options|
      refute options.key?(:page)
      assert_equal 'cursor', options[:page_token]
      { data: [] }
    }) do
      assert_empty Contact.all(fields: 'id', page_token: 'cursor')
    end
  end

  def test_wide_record_fetch_requires_explicit_fields_instead_of_silent_truncation
    fields = 51.times.map { |index| "Field#{index}" }
    assert_raises(ArgumentError) { Contact.record_fields(fields) }
  end

  def test_unknown_api_error_is_never_returned_as_successful_data
    error = assert_raises(ZohoHub::ZohoAPIError) do
      Contact.build_response(code: 'REQUIRED_PARAM_MISSING', status: 'error',
                             message: 'fields is required')
    end
    assert_match(/fields/, error.message)
  end

  def test_users_paginates_without_dropping_owners_after_200_items
    calls = []
    ZohoHub::User.stub(:get, lambda { |_, params|
      calls << params
      count = params[:page] == 1 ? 200 : 3
      { users: count.times.map do |n|
        { id: "#{params[:page]}-#{n}" }
      end, info: { more_records: params[:page] == 1 } }
    }) do
      users = ZohoHub::User.all
      assert_equal 203, users.size
      assert_equal 203, users.map(&:id).uniq.size
    end
    assert_equal([1, 2], calls.map { |params| params[:page] })
  end
end
