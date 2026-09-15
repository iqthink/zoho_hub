require "zoho_hub/response"
require "zoho_hub/with_connection"

module ZohoHub
  class Coql
    include WithConnection

    COQL_REQUEST_PATH = "coql"
    PAGE_SIZE = 2000
    MAX_OFFSET = 100000

    def initialize(klass, query, all_pages = false, page: nil, per_page: nil, offset: nil, raw: false)
      @klass = klass
      @query = query
      @all_pages = all_pages
      @page = page
      default_size = (all_pages || page || offset) ? PAGE_SIZE : 200
      @per_page = per_page || (raw ? 1 : default_size)
      raise ArgumentError, "per_page must be an integer from 1 to 2000" unless @per_page.is_a?(Integer) && (1..PAGE_SIZE).cover?(@per_page)
      raise ArgumentError, "page must be a positive integer" if page && (!page.is_a?(Integer) || page < 1)
      raise ArgumentError, "page and offset cannot be combined" if page && offset
      raise ArgumentError, "all_pages cannot be combined with page or offset" if all_pages && (page || offset)

      @offset = offset || ((page || 1) - 1) * @per_page
      raise ArgumentError, "offset must be a nonnegative integer" unless @offset.is_a?(Integer) && @offset >= 0

      @raw = raw
      @single_page = !page.nil? || !offset.nil?
    end

    def call
      records = []
      loop do
        raise InvalidQuery, "COQL offset limit reached; narrow the criteria before continuing" if @offset >= MAX_OFFSET

        body = post(COQL_REQUEST_PATH, select_query: "#{@query} LIMIT #{@offset}, #{@per_page}")
        rows, more_records = parse(body)
        data = @raw ? rows : rows.map { |row| @klass.new(row) }
        return [data, more_records] if @single_page

        records.concat(data)
        break unless @all_pages && more_records
        raise ZohoAPIError, "COQL returned an empty page with more_records=true" if rows.empty?

        @offset += @per_page
      end
      records
    end

    private

    def parse(body)
      return [[], false] if body.nil? || body.empty?
      raise ZohoAPIError, "Unexpected COQL response" unless body.is_a?(Hash)

      response = Response.new(body)
      raise InternalError, response.msg if response.internal_error?
      raise InvalidQuery, response.msg if response.invalid_query?
      raise SyntaxError, response.msg if response.syntax_error?
      raise ZohoAPIError, (body[:message] || body[:code] || "Unexpected COQL response").to_s unless body[:data].is_a?(Array)

      [body[:data], body.fetch(:info, {})[:more_records] == true]
    end
  end
end
