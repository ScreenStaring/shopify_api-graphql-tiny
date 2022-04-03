# frozen_string_literal: true
require "json"
require "net/http"

require "shopify_api_retry"
require "shopify_api/graphql/tiny/version"

module ShopifyAPI
  module GraphQL
    ##
    # Client to make Shopify GraphQL Admin API requests with built-in retries.
    #
    class Tiny
      Error = Class.new(StandardError)
      ConnectionError = Class.new(Error)
      GraphQLError = Class.new(Error)

      class HTTPError < Error
        attr_reader :code

        def initialize(message, code)
          super(message)
          @code = code
        end
      end

      class RateLimitError < Error
        attr_reader :response

        def initialize(message, response)
          super(message)
          @response = response
        end
      end

      SHOPIFY_DOMAIN = ".myshopify.com"

      ACCESS_TOKEN_HEADER = "X-Shopify-Access-Token"
      QUERY_COST_HEADER = "X-GraphQL-Cost-Include-Fields"
      DEFAULT_RETRY_OPTIONS = { ConnectionError => { :wait => 3, :tries => 20 }, HTTPError => { :wait => 3, :tries => 20 } }
      DEFAULT_HEADERS = { "Content-Type" => "application/json" }.freeze
      ENDPOINT = "https://%s/admin/api%s/graphql.json"       # Note that we omit the "/" after API for the case where there's no version.

      ##
      #
      # Create a new GraphQL client.
      #
      # === Arguments
      #
      # [shop (String)] Shopify domain to make requests against
      # [token (String)] Shopify Admin API GraphQL token
      # [options (Hash)] Client options. Optional.
      #
      # === Options
      #
      # [:retry (Boolean|Hash)] +Hash+ can be retry config options. For the format see {ShopifyAPIRetry}[https://github.com/ScreenStaring/shopify_api_retry/#usage]. Defaults to +true+
      # [:version (String)] Shopify API version to use. Defaults to the latest version.
      # [:debug (Boolean)] Output the HTTP request/response to +STDERR+. Defaults to +false+.
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
        @headers[QUERY_COST_HEADER] = "true" if retry?

        @endpoint = URI(sprintf(ENDPOINT, @domain, !@options[:version].to_s.strip.empty? ? "/#{@options[:version]}" : ""))
      end

      #
      # Execute a GraphQL query or mutation.
      #
      # === Arguments
      #
      # [q (String)] Query or mutation to execute
      # [variables (Hash)] Optional. Variable to pass to the query or mutation given by +q+
      #
      # === Errors
      #
      # ConnectionError, HTTPError, RateLimitError, GraphQLError
      #
      # * An HTTPError is raised of the response does not have 200 status code
      # * A RateLimitError is raised if rate-limited and retries are disabled or if still rate-limited after the configured number of retry attempts
      # * A GraphQLError is raised if the response contains an +errors+ property that is not a rate-limit error
      #
      # === Returns
      #
      # [Hash] The GraphQL response. Unmodified.

      def execute(q, variables = nil)
        config = retry? ? @options[:retry] || DEFAULT_RETRY_OPTIONS : {}
        ShopifyAPIRetry::GraphQL.retry(config) { post(q, variables) }
      end

      private

      def retry?
        @options[:retry] != false
      end

      def shopify_domain(host)
        domain = host.sub(%r{\Ahttps?://}i, "")
        domain << SHOPIFY_DOMAIN unless domain.end_with?(SHOPIFY_DOMAIN)
        domain
      end

      def post(query, variables = nil)
        begin
          # Newer versions of Ruby
          # response = Net::HTTP.post(@endpoint, query, @headers)
          params = { :query => query }
          params[:variables] = variables if variables

          post = Net::HTTP::Post.new(@endpoint.path)
          post.body = params.to_json

          @headers.each { |k,v| post[k] = v }

          request = Net::HTTP.new(@endpoint.host, @endpoint.port)
          request.use_ssl = true
          request.set_debug_output($stderr) if @options[:debug]

          response = request.start { |http| http.request(post) }
        rescue => e
          raise ConnectionError, "request to #@endpoint failed: #{e}"
        end

        # TODO: Even if non-200 check if JSON. See: https://shopify.dev/api/admin-graphql
        prefix = "failed to execute query for #@domain: "
        raise HTTPError.new("#{prefix}#{response.body}", response.code) if response.code != "200"

        json = JSON.parse(response.body)
        return json unless json.include?("errors")

        errors = json["errors"].map { |e| e["message"] }.join(", ")
        if json.dig("errors", 0, "extensions", "code") == "THROTTLED"
          raise RateLimitError.new(errors, json) unless retry?
          return json
        end

        raise GraphQLError, prefix + errors
      end
    end
  end

  GQL = GraphQL
end
