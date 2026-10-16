# frozen_string_literal: true

require 'minitest/autorun'
require 'zoho_hub'

class NotesTest < Minitest::Test
  class Contact < ZohoHub::BaseRecord
    request_path 'Contacts'
    attributes :id
  end

  def test_related_notes_include_v8_required_fields_and_keep_note_response_shape
    contact = Contact.new(id: '123')
    seen = []
    contact.define_singleton_method(:get) do |path, params|
      seen << [path, params]
      {
        data: [
          { id: '456', Note_Title: 'Agent Note', Note_Content: 'Body', Owner: { name: 'Owner' } }
        ],
        info: { more_records: false }
      }
    end
    response = contact.get_notes
    assert_equal 'Contacts/123/Notes', seen.first.first
    assert_equal %w[
      id Note_Title Note_Content Created_Time Modified_Time Owner Created_By Modified_By Parent_Id
    ],
                 seen.first.last[:fields].split(',')
    assert_equal 200, seen.first.last[:per_page]
    assert_equal 'Body', response.data.first[:Note_Content]
  end

  def test_notes_follow_numbered_pages_and_ignore_page_tokens
    contact = Contact.new(id: '123')
    calls = []
    responses = [
      { data: 200.times.map { |i| { id: i.to_s } }, info: { more_records: true, next_page_token: 'cursor' } },
      { data: [{ id: '200' }], info: { more_records: false } }
    ]
    contact.define_singleton_method(:get) do |_, params|
      calls << params
      responses.shift
    end
    response = contact.get_notes
    assert_equal 201, response.data.size
    assert_equal([1, 2], calls.map { |params| params[:page] })
    assert(calls.none? { |params| params.key?(:page_token) })
    assert_equal false, response.info[:more_records]
    assert_empty responses
  end

  def test_notes_stop_when_zoho_repeats_a_page
    contact = Contact.new(id: '123')
    page = 200.times.map { |i| { id: i.to_s } }
    calls = 0
    contact.define_singleton_method(:get) do |_, _|
      calls += 1
      { data: page, info: { more_records: true, next_page_token: "t#{calls}" } }
    end
    response = contact.get_notes
    assert_equal 2, calls
    assert_equal 200, response.data.size
  end

  def test_notes_stop_at_max_pages
    contact = Contact.new(id: '123')
    calls = 0
    contact.define_singleton_method(:get) do |_, params|
      calls += 1
      { data: [{ id: params[:page].to_s }], info: { more_records: true } }
    end
    response = contact.get_notes
    assert_equal ZohoHub::BaseRecord::NOTES_MAX_PAGES, calls
    assert_equal true, response.info[:more_records]
  end

  def test_notes_with_no_content_preserve_empty_data_array
    contact = Contact.new(id: '123')
    contact.define_singleton_method(:get) { |_, _| nil }
    assert_empty contact.get_notes.data
  end
end
