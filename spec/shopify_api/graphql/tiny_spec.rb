require "json"

RSpec.describe ShopifyAPI::GraphQL::Tiny do
  def client(options = {})
    described_class.new(ENV.fetch("SHOPIFY_DOMAIN"), ENV.fetch("SHOPIFY_TOKEN"), options)
  end

  def stub_shopify
    stub_request(:post, %r{\.myshopify\.com})
  end

  def graphql_error(code)
    {
      :errors => [
        :message => "Looks like something went wrong on our end --AGAIN!",
        :extensions => { :code => code }
      ]
    }
  end

  def graphql_rate_limited(cost, available, restore)
    {
      :cost => {
        :requestedQueryCost => cost,
        :actualQueryCost => nil,
        :throttleStatus => {
          :maximumAvailable => available,
          :currentlyAvailable => 0,
          :restoreRate => restore
        }
      }
    }
  end

  before { WebMock.allow_net_connect! }
  after  { WebMock.reset! }

  it "requires a shop" do
    expect {
      described_class.new(nil, "foo")
    }.to raise_error(ArgumentError, "shop required")
  end

  it "requires a token" do
    expect {
      described_class.new("foo", nil)
    }.to raise_error(ArgumentError, "token required")
  end

  describe "API version" do
    it "defaults to the endpoint without an API version" do
      client.execute("query { shop { id } }")

      endpoint = "https://%s/admin/api/graphql.json" % ENV["SHOPIFY_DOMAIN"]
      expect(WebMock).to have_requested(:post, endpoint)
    end

    it "sets the endpoint for the given API version" do
      client(:version => "2025-10").execute("query { shop { id } }")

      endpoint = "https://%s/admin/api/2025-10/graphql.json" % ENV["SHOPIFY_DOMAIN"]
      expect(WebMock).to have_requested(:post, endpoint)
    end
  end

  describe "#execute" do
    it "executes queries" do
      result = client.execute(<<-GQL)
        query {
          shop {
            domains {
              host
            }
          }
        }
      GQL

      hosts = result.dig("data", "shop", "domains").map { |d| d["host"] }
      expect(hosts).to include(ENV["SHOPIFY_DOMAIN"])
    end

    it "executes queries with variables" do
      id = ENV.fetch("SHOPIFY_CUSTOMER_ID")
      id = "gid://shopify/Customer/#{id}"

      result = client.execute(<<-GQL, :id => id)
        query findCustomer($id: ID!) {
          customer(id: $id) {
            id
          }
        }
      GQL

      expect(result.dig("data", "customer", "id")).to eq id
    end

    it "executes mutations" do
      id = ENV.fetch("SHOPIFY_CUSTOMER_ID")
      value = Time.now.to_i.to_s
      input = {
        :ownerId => "gid://shopify/Customer/#{id}",
        :namespace => "shopify_api_gql_tiny",
        :key => "testsuite",
        :type => "single_line_text_field",
        :value => value
      }

      result = client.execute(<<-GQL, :metafields => [input])
        mutation metafieldsSet($metafields: [MetafieldsSetInput!]!) {
          metafieldsSet(metafields: $metafields) {
            metafields {
              key
              namespace
              value
            }
          }
        }
      GQL

      data = result.dig("data", "metafieldsSet", "metafields", 0)
      expect(data).to eq("key" => "testsuite", "namespace" => "shopify_api_gql_tiny", "value" => value)
    end

    it "retries only user-specified errors" do
      stub_shopify.
        to_return(:status => 404, :body => "Don't retry this at home!").
        to_raise(Timeout::Error.new).
        to_return(:body => graphql_error("TIMEOUT").to_json).
        to_return(:status => 500, :body => "Not retrying this!")

      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      expect {
        client(:jitter => false, :retry => ["4XX", Timeout::Error, "TIMEOUT"]).execute("query { shop { id } }")
      }.to raise_error(described_class::HTTPError, /Not retrying this!/)

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).to be_within(0.15).of(3.5)
    end

    context "given a response with non-successful HTTP status code" do
      it "retries using an exponential backoff" do
        stub_shopify.to_return(
          { :status => 500, :body => "Internal Server Error" },
          { :status => 502, :body => "Bad Gateway" },
          { :status => 500, :body => "Internal Server Error" },
          { :status => 200, :body => {:data => { :shop => { :id => "gid://shopify/Shop/123" }}}.to_json, :headers => { :content_type => "application/json" } }
        )

        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        # Since we're measuring delay don't use jitter
        result = client(:jitter => false).execute("query { shop { id } }")

        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).to be_within(0.15).of(3.5)
        expect(result.dig("data", "shop", "id")).to eq "gid://shopify/Shop/123"
      end

      it "raises an HTTPError when the max attempts are exhausted" do
        stub_shopify.to_return(
          { :status => 500, :body => "Internal Server Error" },
          { :status => 502, :body => "Bad Gateway" },
          { :status => 500, :body => "Internal Server Error" },
          { :status => 503, :body => "Service Unavailable" }
        )

        expect {
          client(:max_attempts => 4).execute("query { shop { id } }")
        }.to raise_error(described_class::HTTPError, "failed to execute query for #{ENV["SHOPIFY_DOMAIN"]}: Service Unavailable")
      end
    end

    context "given a request that raises an exception" do
      it "retries using an exponential backoff" do
        stub_shopify.
          to_raise(Timeout::Error.new("error 1")).
          to_raise(Net::ReadTimeout.new("error 2")).
          to_raise(Timeout::Error.new("error 3")).
          to_return(
            :status => 200,
            :body => {:data => { :shop => { :id => "gid://shopify/Shop/123" }}}.to_json,
            :headers => { :content_type => "application/json" }
          )

        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        # Since we're measuring delay don't use jitter
        result = client(:jitter => false).execute("query { shop { id } }")

        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).to be_within(0.15).of(3.5)
        expect(result.dig("data", "shop", "id")).to eq "gid://shopify/Shop/123"
      end

      it "raises a ConnectionError when the max attempts are exhausted" do
        stub_shopify.
          to_raise(Timeout::Error.new("error 1")).
          to_raise(Net::ReadTimeout.new("error 2")).
          to_raise(Timeout::Error.new("error 3")).
          to_raise(Net::ReadTimeout.new("error 4"))

        expect {
          client(:max_attempts => 4).execute("query { shop { id } }")
        }.to raise_error(described_class::ConnectionError, %|failed to execute query for #{ENV["SHOPIFY_DOMAIN"]}: Net::ReadTimeout with "error 4"|)
      end
    end

    context "given a response with a retryable GraphQL error code" do
      it "retries using an exponential backoff" do
        stub_shopify.to_return(
          {
            :status => 200,
            :body => graphql_error("INTERNAL_SERVER_ERROR").to_json,
            :headers => { "Content-Type" => "application/json" }
          },
          {
            :status => 200,
            :body => graphql_error("INTERNAL_SERVER_ERROR").to_json,
            :headers => { "Content-Type" => "application/json" }
          },
          {
            :status => 200,
            :body => graphql_error("TIMEOUT").to_json,
            :headers => { "Content-Type" => "application/json" }
          },
          {
            :status => 200,
            :body => {:data => { :shop => { :id => "gid://shopify/Shop/123" }}}.to_json,
            :headers => { :content_type => "application/json" }
          }
        )

        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        # Since we're measuring delay don't use jitter
        result = client(:jitter => false).execute("query { shop { id } }")

        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).to be_within(0.15).of(3.5)
        expect(result.dig("data", "shop", "id")).to eq "gid://shopify/Shop/123"
      end

      it "raises a GraphQLError when the max attempts are exhausted" do
        stub_shopify.to_return(
          {
            :status => 200,
            :body => graphql_error("INTERNAL_SERVER_ERROR").to_json,
            :headers => { "Content-Type" => "application/json" }
          },
          {
            :status => 200,
            :body => graphql_error("INTERNAL_SERVER_ERROR").to_json,
            :headers => { "Content-Type" => "application/json" }
          },
          {
            :status => 200,
            :body => graphql_error("TIMEOUT").to_json,
            :headers => { "Content-Type" => "application/json" }
          },
          {
            :status => 200,
            :body => graphql_error("INTERNAL_SERVER_ERROR").to_json,
            :headers => { "Content-Type" => "application/json" }
          },
        )

        expect {
          client(:max_attempts => 4).execute("query { shop { id } }")
        }.to raise_error(described_class::GraphQLError, "failed to execute query for #{ENV["SHOPIFY_DOMAIN"]}: Looks like something went wrong on our end --AGAIN!")
      end
    end

    context "given a response with a non-retryable GraphQL error code" do
      before do
        stub_shopify.to_return(
          :status => 200,
          :body => graphql_error("ACCESS_DENIED").to_json,
          :headers => { "Content-Type" => "application/json" }
        )
      end

      it "raises a GraphQLError" do
        expect {
          client.execute("query { shop { id } }")
        }.to raise_error(described_class::GraphQLError, "failed to execute query for #{ENV["SHOPIFY_DOMAIN"]}: Looks like something went wrong on our end --AGAIN!")
      end

      it "does not retry" do
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        expect {
          # Would take 60 seconds if we retried
          client(:max_attempts => 10, :jitter => false).execute("query { shop { id } }")
        }.to raise_error(described_class::GraphQLError)

        # Account for network delays, etc...
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).to be < 3
      end
    end

    context "given a response that's rate limited" do
      before do
        stub_shopify.to_return(
          {
            :status => 200,
            # Wait for 1 second to retry
            :body => graphql_error("THROTTLED").merge!(:extensions => graphql_rate_limited(100, 1000, 100)).to_json,
            :headers => { "Content-Type" => "application/json" }
          },
          {
            :status => 200,
            # Wait for 2 seconds to retry
            :body => graphql_error("THROTTLED").merge!(:extensions => graphql_rate_limited(200, 1000, 100)).to_json,
            :headers => { "Content-Type" => "application/json" }
          },
          {
            :status => 200,
            # Wait for 1 second to retry
            :body => graphql_error("THROTTLED").merge!(:extensions => graphql_rate_limited(100, 1000, 100)).to_json,
            :headers => { "Content-Type" => "application/json" }
          },
          {
            :status => 200,
            :body => {:data => { :shop => { :id => "gid://shopify/Shop/123" }}}.to_json,
            :headers => { :content_type => "application/json" }
          }
        )
      end

      it "retries using an exponential backoff" do
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        result = client.execute("query { shop { id } }")

        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).to be_within(0.15).of(4)
        expect(result.dig("data", "shop", "id")).to eq "gid://shopify/Shop/123"
      end

      it "raises a RateLimitError when the max attempts are exhausted" do
        expect {
          client(:max_attempts => 3).execute("query { shop { id } }")
        }.to raise_error(described_class::RateLimitError)
      end
    end

    context "given a response with a mix of exceptions, HTTP errors, and throttling" do
      before do
        @request = stub_shopify.
          to_return(
            :status => 200,
            :body => graphql_error("INTERNAL_SERVER_ERROR").to_json,
            :headers => { "Content-Type" => "application/json" }
          ).
          to_raise(Net::ReadTimeout.new("error 2")).
          to_return(:status => 503, :body => "Service Unavailable")
      end

      it "retries using an exponential backoff" do
        @request.to_return(
          :status => 200,
          :body => {:data => { :shop => { :id => "gid://shopify/Shop/123" }}}.to_json,
          :headers => { :content_type => "application/json" }
        )

        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        # Since we're measuring delay don't use jitter
        result = client(:jitter => false).execute("query { shop { id } }")

        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).to be_within(0.15).of(3.5)
        expect(result.dig("data", "shop", "id")).to eq "gid://shopify/Shop/123"
      end

      it "raises an exception based on the last error encountered" do
        expect {
          client(:max_attempts => 3).execute("query { shop { id } }")
        }.to raise_error(described_class::HTTPError)
      end
    end

    it "includes the Shopify GraphQL cost HTTP header" do
      client.execute("query { shop { id } }")

      expect(WebMock).to have_requested(:post, %r{\.myshopify\.com}).with(:headers => {"X-GraphQL-Cost-Include-Fields" => "true"})
    end
  end

  describe "#paginate" do
    VARIANT_COUNT_ERROR = "test using a Shopify product with more than 1 variant"

    def position_edge_at(at)
      ["data", "product", "variants", "edges", at]
    end

    def position_node_at(at)
      # Yay, GraphQL!
      position_edge_at(at) << "node"
    end

    def paginate_positions(pager, q, options)
      positions = []
      pager.execute(q, options) { |page| positions << page.dig(*position_node_at(0)).fetch("position") }
      positions
    end

    before do
      @id = "gid://shopify/Product/%s" % ENV.fetch("SHOPIFY_PRODUCT_ID")
    end

    it "paginates forward using an $after variable by default" do
      q = <<-GQL
        query product($id: ID! $after: String) {
          product(id: $id) {
            variants(first:1 sortKey: POSITION after: $after ) {
              pageInfo {
                hasNextPage
                endCursor
              }
              edges {
                node {
                  position
                }
              }
            }
          }
        }
      GQL

      pager = client.paginate
      positions = paginate_positions(pager, q, :id => @id)

      expect(positions.size).to be > 1, VARIANT_COUNT_ERROR
      expect(positions).to eq positions.sort
    end

    it "paginates forward using an $after variable when :after pagination is specified" do
      q = <<-GQL
        query product($id: ID! $after: String) {
          product(id: $id) {
            variants(first:1 sortKey: POSITION after: $after ) {
              pageInfo {
                hasNextPage
                endCursor
              }
              edges {
                node {
                  position
                }
              }
            }
          }
        }
      GQL

      pager = client.paginate(:after)
      positions = paginate_positions(pager, q, :id => @id)

      expect(positions.size).to be > 1, VARIANT_COUNT_ERROR
      expect(positions).to eq positions.sort
    end

    it "pages backward using a $before variable when :before pagination is specified" do
      q = <<-GQL
        query product($id: ID!) {
          product(id: $id) {
            variants(first: 10 sortKey: POSITION) {
              edges {
                cursor
                node {
                  position
                }
              }
            }
          }
        }
      GQL

      # Get to cursor to use for before pagination
      data = client.execute(q, :id => @id)
      before = data.dig(*position_edge_at(-1)).fetch("cursor")

      q = <<-GQL
        query product($id: ID! $before: String!) {
          product(id: $id) {
            variants(last:1 before: $before) {
              pageInfo {
                hasPreviousPage
                startCursor
              }
              edges {
                node {
                  position
                }
              }
            }
          }
        }
      GQL

      pager = client.paginate(:before)
      positions = paginate_positions(pager, q, :id => @id, :before => before)

      expect(positions.size).to be > 1, VARIANT_COUNT_ERROR
      expect(positions).to eq positions.sort.reverse
    end

    it "paginates forward using a custom page variable name" do
      q = <<-GQL
        query product($id: ID! $custom: String) {
          product(id: $id) {
            variants(first:1 sortKey: POSITION after: $custom ) {
              pageInfo {
                hasNextPage
                endCursor
              }
              edges {
                node {
                  position
                }
              }
            }
          }
        }
      GQL

      %w[custom $custom].each do |var|
        pager = client.paginate(:after, :variable => var)
        positions = paginate_positions(pager, q, :id => @id)

        expect(positions.size).to be > 1, VARIANT_COUNT_ERROR
        expect(positions).to eq positions.sort
      end
    end

    it "raises an error when the pagination variable does not exist in the query" do
      q = <<-GQL
        query product($id: ID! $afterX: String!) {
          product(id: $id) {
            variants(first:1 sortKey: after: $afterX) {
              pageInfo {
                hasNextPage
                endCursor
              }
              edges {
                node {
                  position
                }
              }
            }
          }
        }
      GQL

      pager = client.paginate(:after)
      expect {
        paginate_positions(pager, q, :id => @id)
      }.to raise_error(ArgumentError, "query does not contain the pagination variable 'after'")

      pager = client.paginate(:after, :variable => "afterx")
      expect {
        paginate_positions(pager, q, :id => @id)
      }.to raise_error(ArgumentError, "query does not contain the pagination variable 'afterx'")

      pager = client.paginate(:after, :variable => "XafterX")
      expect {
        paginate_positions(pager, q, :id => @id)
      }.to raise_error(ArgumentError, "query does not contain the pagination variable 'XafterX'")
    end

    describe "specifying a locator for the query's pagination data" do
      before do
        @query = <<-GQL
          query product($id: ID! $after: String) {
            product(id: $id) {
              collections(first:0) {
                pageInfo {
                  hasNextPage
                  endCursor
                }
                edges {
                  node {
                    id
                  }
                }
              }
              variants(first:1 sortKey: POSITION after: $after ) {
                pageInfo {
                  hasNextPage
                  endCursor
                }
                edges {
                  node {
                    position
                  }
                }
              }
            }
          }
        GQL
      end

      it "uses the return value from a Proc" do
        finder = ->(data) { data.dig("data", "product", "collections", "pageInfo") }
        pager = client.paginate(:after => finder)

        positions = paginate_positions(pager, @query, :id => @id)

        # Since it uses the collections' page info we only have 1 value
        expect(positions).to eq [1]
      end

      context "when using an Array" do
        it "can exclude the 'data' and 'pageInfo' keys" do
          pager = client.paginate(:after => %w[product collections])
          positions = paginate_positions(pager, @query, :id => @id)

          # Since it uses the collections' page info we only have 1 value
          expect(positions).to eq [1]
        end

        it "can include the 'data' and 'pageInfo' keys" do
          pager = client.paginate(:after => %w[data product collections pageInfo])
          positions = paginate_positions(pager, @query, :id => @id)

          # Since it uses the collections' page info we only have 1 value
          expect(positions).to eq [1]
        end

        it "raises an ArgumentError when the pagination location causes a TypeError" do
          path = %w[product variants edges TypeError_duuuude]
          pager = client.paginate(:after => path)

          expect {
            paginate_positions(pager, @query, :id => @id)
          }.to raise_error(ArgumentError, /\binvalid pagination path #{Regexp.escape(path.to_s)}:/)
        end
      end
    end
  end
end
