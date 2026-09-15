require "minitest/autorun"
require "zoho_hub"

class CoqlTest < Minitest::Test
  Record = Struct.new(:data)

  def query(body, **options)
    request = ZohoHub::Coql.new(Record, "SELECT id FROM Contacts WHERE id is not null", options.delete(:all_pages) || false, **options)
    request.define_singleton_method(:post) { |_, payload| body.call(payload[:select_query]) }
    request
  end

  def test_full_pagination_stops_on_false_without_duplicate_or_extra_request
    queries = []
    request = query(->(sql) {
      queries << sql
      {data: [{id: queries.size}], info: {more_records: queries.size < 3}}
    }, all_pages: true)
    assert_equal [1, 2, 3], request.call.map { |r| r.data[:id] }
    assert_equal ["LIMIT 0, 2000", "LIMIT 2000, 2000", "LIMIT 4000, 2000"], queries.map { |q| q[/LIMIT.*/] }
  end

  def test_single_page_exposes_more_records_and_explicit_offset
    seen = nil
    data, more = query(->(sql) {
      seen = sql
      {data: [{id: 7}], info: {more_records: true}}
    }, offset: 200, per_page: 2000).call
    assert_equal 7, data.first.data[:id]
    assert more
    assert_match(/LIMIT 200, 2000$/, seen)
  end

  def test_raw_count_is_not_instantiated_and_uses_one_row
    seen = nil
    rows = query(->(sql) {
      seen = sql
      {data: [{count: 2400}]}
    }, raw: true).call
    assert_equal [{count: 2400}], rows
    assert_match(/LIMIT 0, 1$/, seen)
  end

  def test_empty_response
    assert_empty query(->(_) {}, all_pages: true).call
    assert_equal [[], false], query(->(_) { {} }, page: 1).call
  end

  def test_error_does_not_become_an_empty_success
    assert_raises(ZohoHub::ZohoAPIError) { query(->(_) { {code: "NO_PERMISSION", message: "denied"} }).call }
  end

  def test_invalid_page_parameters
    assert_raises(ArgumentError) { query(->(_) {}, per_page: 2001) }
    assert_raises(ArgumentError) { query(->(_) {}, page: 0) }
    assert_raises(ArgumentError) { query(->(_) {}, offset: -1) }
    assert_raises(ArgumentError) { query(->(_) {}, page: 1, offset: 0) }
  end

  def test_empty_page_cannot_loop_forever
    assert_raises(ZohoHub::ZohoAPIError) { query(->(_) { {data: [], info: {more_records: true}} }, all_pages: true).call }
  end
end
