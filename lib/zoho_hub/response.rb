# frozen_string_literal: true

module ZohoHub
  class Response
    def initialize(params)
      @params = params || {}
    end

    def invalid_data?
      error_code?('INVALID_DATA')
    end

    def invalid_token?
      error_code?('INVALID_TOKEN')
    end

    def invalid_query?
      error_code?('INVALID_QUERY')
    end

    def internal_error?
      error_code?('INTERNAL_ERROR')
    end

    def authentication_failure?
      error_code?('AUTHENTICATION_FAILURE')
    end

    def invalid_module?
      error_code?('INVALID_MODULE')
    end

    def no_permission?
      error_code?('NO_PERMISSION')
    end

    def mandatory_not_found?
      error_code?('MANDATORY_NOT_FOUND')
    end

    def record_in_blueprint?
      error_code?('RECORD_IN_BLUEPRINT')
    end

    def syntax_error?
      error_code?('SYNTAX_ERROR')
    end

    def empty?
      @params.empty?
    end

    def data
      data = @params[:data] if @params[:data]
      data || @params
    end

    def info
      info = @params[:info] if @params[:info]
      info || @params
    end

    def parsed_data
      data.is_a?(Array) ? data.first : data
    end

    def status
      parsed_data[:status]
    end

    def code
      parsed_data[:code]
    end

    def msg
      msg = parsed_data[:message]

      if parsed_data.dig(:details, :expected_data_type)
        expected = parsed_data.dig(:details, :expected_data_type)
        field = parsed_data.dig(:details, :api_name)
        parent_api_name = parsed_data.dig(:details, :parent_api_name)

        msg << ", expected #{expected} for '#{field}'"
        msg << " in #{parent_api_name}" if parent_api_name
      elsif parsed_data.dig(:details, :clause)
        clause = parsed_data.dig(:details, :clause)
        msg << ": #{clause.upcase}"
      end

      msg
    end

    # Error response examples:
    # {"data":[{"code":"INVALID_DATA","details":{},"message":"the id given...","status":"error"}]}
    # {:code=>"INVALID_TOKEN", :details=>{}, :message=>"invalid oauth token", :status=>"error"}
    def error_code?(code)
      if data.is_a?(Array)
        return false if data.empty? || data.size > 1

        return data.first[:code] == code
      end

      data[:code] == code
    end
  end
end
