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
end
