# frozen_string_literal: true
require "json"
require "net/http"

require "net_http_timeout_errors"
require "shopify_api/graphql/tiny/version"

module ShopifyAPI
  module GraphQL
    ##
    # Lightweight, no-nonsense, Shopify GraphQL Admin API client with built-in pagination and retry
    #
    class Tiny
      Error = Class.new(StandardError)
      ConnectionError = Class.new(Error)

      ERROR_CODE_THROTTLED = "THROTTLED"
      ERROR_CODE_TIMEOUT = "TIMEOUT"
      ERROR_CODE_SERVER_ERROR = "INTERNAL_SERVER_ERROR"

      class GraphQLError < Error
        # Hash of failed GraphQL response
        attr_reader :response

        def initialize(message, response)
          super(message)
          @response = response
        end
      end

      RateLimitError = Class.new(GraphQLError)

      class HTTPError < Error
        attr_reader :code

        def initialize(message, code)
          super(message)
          @code = code
        end
      end

      USER_AGENT = "ShopifyAPI::GraphQL::Tiny v#{VERSION} (Ruby v#{RUBY_VERSION})"

      SHOPIFY_DOMAIN = ".myshopify.com"

      ACCESS_TOKEN_HEADER = "X-Shopify-Access-Token"
      QUERY_COST_HEADER = "X-GraphQL-Cost-Include-Fields"

      DEFAULT_HEADERS = { "Content-Type" => "application/json" }.freeze

      DEFAULT_BACKOFF_OPTIONS = {
        :base_delay => 0.5,
        :jitter => true,
        :max_attempts => 10,
        :max_delay => 60,
        :multiplier => 2.0
      }

      DEFAULT_RETRY_ERRORS = [
        "5XX",
        ERROR_CODE_SERVER_ERROR,
        ERROR_CODE_TIMEOUT,
        *NetHttpTimeoutErrors.all
      ]

      ENDPOINT = "https://%s/admin/api%s/graphql.json"       # Note that we omit the "/" after API for the case where there's no version.

      ##
      #
      # Create a new GraphQL client
      #
      # === Arguments
      #
      # [shop (String)] Shopify domain to make requests against
      # [token (String)] Shopify Admin API GraphQL token
      # [options (Hash)] Client options. Optional.
      #
      # === Options
      #
      # [:retry (Boolean|Array)] If +false+ disable retries or an +Array+ of errors to retry. Can be HTTP status codes, GraphQL errors, or exception classes.
      # [:version (String)] Shopify API version to use. Defaults to the latest version.
      # [:max_attempts (Integer)] Maximum number of retry attempts across all errors. Defaults to +10+
      # [:base_delay (Float)] Exponential backoff base delay. Defaults to +0.5+
      # [:jitter (Boolean)] Exponential backoff jitter (random delay added to backoff). Defaults to +true+
      # [:multiplier (Float)] Exponential backoff multiplier. Defaults to +2.0+
      # [:debug (Boolean|IO)] Output the HTTP request/response to +STDERR+ or to its value if it's an +IO+. Defaults to +false+.
      #
      # === Errors
      #
      # ArgumentError if no +shop+ or +token+ is provided.
      #

      def initialize(shop, token, options = nil)
        raise ArgumentError, "shop required" unless shop
        raise ArgumentError, "token required" unless token

        @domain = shopify_domain(shop)
        @options = options || {}

        @headers = DEFAULT_HEADERS.dup
        @headers[ACCESS_TOKEN_HEADER] = token
        @headers[QUERY_COST_HEADER] = "true" unless @options[:retry] == false

        @endpoint = URI(sprintf(ENDPOINT, @domain, !@options[:version].to_s.strip.empty? ? "/#{@options[:version]}" : ""))
        @backoff_options = DEFAULT_BACKOFF_OPTIONS.merge(@options.slice(*DEFAULT_BACKOFF_OPTIONS.keys))

        if @options[:debug]
          @debug = @options[:debug].is_a?(IO) ? @options[:debug] : $stderr
        end

        case @options[:retry]
        when false
          @retryable = []
        when Array
          @retryable = @options[:retry]
        else
          @retryable = DEFAULT_RETRY_ERRORS
        end
      end

      #
      # Execute a GraphQL query or mutation
      #
      # === Arguments
      #
      # [q (String)] Query or mutation to execute
      # [variables (Hash)] Optional. Variable to pass to the query or mutation given by +q+
      #
      # === Errors
      #
      # ArgumentError, ConnectionError, HTTPError, RateLimitError, GraphQLError
      #
      # Outside of ArgumentError these are raised after exhausing the configured retry.
      #
      # * An ShopifyAPI::GraphQL::Tiny::HTTPError is raised of the response does not have 200 status code
      # * A ShopifyAPI::GraphQL::Tiny::RateLimitError is raised if rate-limited and retries are disabled or if still
      #   rate-limited after the configured number of retry attempts
      # * A ShopifyAPI::GraphQL::Tiny::GraphQLError is raised if the response contains an +errors+ property that is
      #   not a rate-limit error
      #
      # === Returns
      #
      # [Hash] The GraphQL response. Unmodified.

      def execute(q, variables = nil)
        raise ArgumentError, "query required" if q.nil? || q.to_s.strip.empty?

        @request_attempts = 0

        make_request(q, variables)
      end

      ##
      # Create a pager to execute a paginated query:
      #
      #  pager = gql.paginate  # This is the same as gql.paginate(:after)
      #  pager.execute(query, :id => id) do |page|
      #    page.dig("data", "product", "title")
      #  end
      #
      # The block is called for each page.
      #
      # Using pagination requires you to include the
      # {PageInfo}[https://shopify.dev/api/admin-graphql/2022-10/objects/PageInfo]
      # object in your queries and wrap them in a function that accepts a page/cursor argument.
      # See the README for more information.
      #
      # === Arguments
      #
      # [direction (Symbol)] The direction to paginate, either +:after+ or +:before+. Optional, defaults to +:after:+
      # [options (Hash)] Pagination options. Optional.
      #
      # === Options
      #
      # [:after (Array|Proc)] The location of {PageInfo}[https://shopify.dev/api/admin-graphql/2022-10/objects/PageInfo]
      #                       block.
      #
      #                       An +Array+ will be passed directly to <code>Hash#dig</code>. A +TypeError+ resulting
      #                       from the +#dig+ call will be raised as an +ArgumentError+.
      #
      #                       The <code>"data"</code> and <code>"pageInfo"</code> keys are automatically added if not provided.
      #
      #                       A +Proc+ must accept the GraphQL response +Hash+ as its argument and must return the
      #                       +pageInfo+ block to use for pagination.
      #
      # [:before (Array|Proc)] See the +:after+ option
      # [:variable (String)] Name of the GraphQL variable to use as the "page" argument.
      #                      Defaults to <code>"before"</code> or <code>"after"</code>, depending on the pagination
      #                      direction.
      #
      # === Errors
      #
      # ArgumentError

      def paginate(*options)
        Pager.new(self, options)
      end

      private

      def make_request(query, variables = nil)
        response = nil
        exceptions = @retryable.select { |target| target.is_a?(Class) }

        begin
          @request_attempts += 1
          response = post(query, variables)
        rescue *exceptions => e
          retry if wait_to_retry
          raise ConnectionError.new("failed to execute query for #@domain: #{e.message}")
        end

        if response.code != "200"
          return make_request(query, variables) if handle_http_error(response.code)
          raise HTTPError.new("failed to execute query for #@domain: #{response.body}", response.code)
        end

        json = parse_json(response.body)
        return json unless json.include?("errors")

        return make_request(query, variables) if handle_graphql_error(json)

        message = error_message(json["errors"])
        raise GraphQLError.new("failed to execute query for #@domain: #{message}", json)
      end

      def post(query, variables = nil)
        # Newer versions of Ruby:
        # response = Net::HTTP.post(@endpoint, query, @headers)
        params = { :query => query }
        params[:variables] = variables if variables

        post = Net::HTTP::Post.new(@endpoint.path)
        post.body = params.to_json
        post["User-Agent"] = USER_AGENT

        @headers.each { |k,v| post[k] = v }

        request = Net::HTTP.new(@endpoint.host, @endpoint.port)
        request.use_ssl = true
        request.set_debug_output(@debug) if @debug

        request.start { |http| http.request(post) }
      end

      def handle_graphql_error(json)
        errors = json["errors"]
        codes = errors.map { |error| error.dig("extensions", "code") }

        if codes.include?(ERROR_CODE_THROTTLED)
          return true if wait_for_shopify_retry(json.dig("extensions", "cost"))

          raise RateLimitError.new(error_message(errors), json)
        end

        return true if @retryable.any? { |error| codes.include?(error) } && wait_to_retry

        false
      end

      def handle_http_error(status)
        return false unless @retryable.include?(status) || @retryable.any? { |error| error.is_a?(String) && error.size == 3 && error.end_with?("XX") && error[0] == status[0] }

        wait_to_retry
      end

      def wait_to_retry
        return false unless request_attempts_remain?

        backoff(@request_attempts)

        true
      end

      def wait_for_shopify_retry(cost)
        return false if cost.nil? || cost["actualQueryCost"] || !request_attempts_remain?

        status = cost["throttleStatus"]
        time = (cost["requestedQueryCost"] - status["currentlyAvailable"]) / status["restoreRate"]

        debug("retrying rate-limited request (retry count: #@request_attempts, status: #{status}, sleep: #{time})")

        sleep(time)

        true
      end

      def backoff(attempts)
        delay = @backoff_options[:base_delay] * (@backoff_options[:multiplier] ** (attempts - 1))
        delay = [delay, @backoff_options[:max_delay]].min if @backoff_options[:max_delay]
        delay = rand * delay if @backoff_options[:jitter]

        debug("backoff sleeping for #{delay}")

        sleep(delay)
      end

      def shopify_domain(host)
        domain = host.sub(%r{\Ahttps?://}i, "")
        domain << SHOPIFY_DOMAIN unless domain.end_with?(SHOPIFY_DOMAIN)
        domain
      end

      def parse_json(json)
        JSON.parse(json)
      rescue JSON::ParserError => e
        raise Error, "failed to parse JSON response: #{e.message}"
      end

      def error_message(errors)
        errors.map do |e|
          message = e["message"]

          path = e["path"]
          message << sprintf(" at %s", path.join(".")) if path

          message
        end.join(", ")
      end

      def request_attempts_remain?
        @request_attempts < @backoff_options[:max_attempts]
      end

      def debug(message)
        return unless @debug

        @debug.puts "#{self.class}: #{message}"
      end
    end

    class Pager  # :nodoc:
      NEXT_PAGE_KEYS = {
        :before => %w[hasPreviousPage startCursor].freeze,
        :after  => %w[hasNextPage endCursor].freeze
      }.freeze

      def initialize(gql, *options)
        @gql = gql
        @options = normalize_options(options)
      end

      def execute(q, variables = nil)
        unless pagination_variable_exists?(q)
          raise ArgumentError, "query does not contain the pagination variable '#{@options[:variable]}'"
        end

        variables ||= {}
        pagination_finder = @options[@options[:direction]]

        loop do
          page = @gql.execute(q, variables)

          yield page

          cursor = pagination_finder[page]
          break unless cursor

          next_page_variables = variables.dup
          next_page_variables[@options[:variable]] = cursor
          #break unless next_page_variables != variables

          variables = next_page_variables
        end
      end

      private

      def normalize_options(options)
        normalized = {}

        options.flatten!
        options.each do |option|
          case option
          when Hash
            normalized.merge!(normalize_hash_option(option))
          when *NEXT_PAGE_KEYS.keys
            normalized[:direction] = option
          else
            raise ArgumentError, "invalid pagination option #{option}"
          end
        end

        normalized[:direction] ||= :after
        normalized[normalized[:direction]] ||= method(:default_pagination_finder)

        normalized[:variable] ||= normalized[:direction].to_s
        normalized[:variable] = normalized[:variable].sub(%r{\A\$}, "")

        normalized
      end

      def normalize_hash_option(option)
        normalized = option.dup

        NEXT_PAGE_KEYS.each do |key, _|
          next unless option.include?(key)

          normalized[:direction] = key

          case option[key]
          when Proc
            normalized[key] = ->(data) { extract_cursor(option[key][data]) }
          when Array
            path = pagination_path(option[key])
            normalized[key] = ->(data) do
              begin
                extract_cursor(data.dig(*path))
              rescue TypeError => e
                # Use original path in error as not to confuse
                raise ArgumentError, "invalid pagination path #{option[key]}: #{e}"
              end
            end
          else
            raise ArgumentError, "invalid pagination locator #{option[key]}"
          end
        end

        normalized
      end

      def pagination_path(user_path)
        path = user_path.dup

        # No need for this, we check for this key ourselves
        path.pop if path[-1] == "pageInfo"

        # Must always include this (sigh)
        path.unshift("data") if path[0] != "data"

        path
      end

      def pagination_variable_exists?(query)
        name = Regexp.quote(@options[:variable])
        query.match?(%r{\$#{name}\s*:})
      end

      def extract_cursor(data)
        return unless data.is_a?(Hash)

        has_next, next_cursor = NEXT_PAGE_KEYS[@options[:direction]]

        pi = data["pageInfo"]
        return unless pi && pi[has_next]

        pi[next_cursor]
      end

      def default_pagination_finder(data)
        cursor = nil

        case data
        when Hash
          cursor = extract_cursor(data)
          return cursor if cursor

          data.values.each do |v|
            cursor = default_pagination_finder(v)
            break if cursor
          end
        when Array
          data.each do |v|
            cursor = default_pagination_finder(v)
            break if cursor
          end
        end

        cursor
      end
    end
  end

  GQL = GraphQL
end
