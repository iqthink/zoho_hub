require "minitest/autorun"
require "zoho_hub"

class NotesTest < Minitest::Test
  class Contact < ZohoHub::BaseRecord
    request_path "Contacts"
    attributes :id
  end

  def test_related_notes_include_v8_required_fields_and_keep_note_response_shape
    contact = Contact.new(id: "123")
    seen = []
    contact.define_singleton_method(:get) do |path, params|
      seen << [path, params]
      {data: [{id: "456", Note_Title: "Agent Note", Note_Content: "Body", Owner: {name: "Owner"}}], info: {more_records: false}}
    end
    response = contact.get_notes
    assert_equal "Contacts/123/Notes", seen.first.first
    assert_equal %w[id Note_Title Note_Content Created_Time Modified_Time Owner Created_By Modified_By Parent_Id], seen.first.last[:fields].split(",")
    assert_equal 200, seen.first.last[:per_page]
    assert_equal "Body", response.data.first[:Note_Content]
  end

  def test_notes_follow_numbered_pages_and_tokens_until_more_records_is_false
    contact = Contact.new(id: "123")
    calls = []
    responses = [
      {data: 200.times.map { |i| {id: i.to_s} }, info: {more_records: true}},
      {data: [{id: "200"}], info: {more_records: true, next_page_token: "cursor"}},
      {data: [{id: "201"}], info: {more_records: false, next_page_token: "ignored"}}
    ]
    contact.define_singleton_method(:get) do |_, params|
      calls << params
      responses.shift
    end
    response = contact.get_notes
    assert_equal 202, response.data.size
    assert_equal 202, response.data.map { |note| note[:id] }.uniq.size
    assert_equal [1, 2, nil], calls.map { |params| params[:page] }
    assert_equal "cursor", calls.last[:page_token]
    assert_equal false, response.info[:more_records]
    assert_empty responses
  end

  def test_notes_with_no_content_preserve_empty_data_array
    contact = Contact.new(id: "123")
    contact.define_singleton_method(:get) { |_, _| nil }
    assert_empty contact.get_notes.data
  end
end
