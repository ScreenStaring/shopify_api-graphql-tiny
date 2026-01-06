require "json"
require "shopify_api_retry"

RSpec.describe ShopifyAPI::GraphQL::Tiny do
  def client(options = {})
    described_class.new(ENV.fetch("SHOPIFY_DOMAIN"), ENV.fetch("SHOPIFY_TOKEN"), options)
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
      client(:version => "2021-10").execute("query { shop { id } }")

      endpoint = "https://%s/admin/api/2021-10/graphql.json" % ENV["SHOPIFY_DOMAIN"]
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
      input = {
        :namespace => "shopify_api_gql_tiny",
        :key => "testsuite",
        :valueInput => {
          :valueType => "STRING",
          :value => Time.now.to_i.to_s
        }
      }

      result = client.execute(<<-GQL, :input => input)
        mutation privateMetafieldUpsert($input: PrivateMetafieldInput!) {
          privateMetafieldUpsert(input: $input) {
            privateMetafield {
              key
              namespace
            }
          }
        }
      GQL

      data = result.dig("data", "privateMetafieldUpsert", "privateMetafield")
      expect(data).to eq("key" => "testsuite", "namespace" => "shopify_api_gql_tiny")
    end

    it "retries failed requests by default" do
      expect(ShopifyAPIRetry::GraphQL).to receive(:retry).
                                            with({
                                              described_class::ConnectionError => { :wait => 3, :tries => 20 },
                                              described_class::HTTPError => { :wait => 3, :tries => 20 }
                                            }).
                                            and_call_original

      result = client.execute("query { shop { id } }")
      expect(result.dig("data", "shop", "id")).to be_a(String)
    end

    it "retries failed requests using the user provided options" do
      client = described_class.new(
        ENV["SHOPIFY_DOMAIN"],
        ENV["SHOPIFY_TOKEN"],
        :retry => { described_class::ConnectionError => { :wait => 1, :tries => 5 } }
      )

      expect(ShopifyAPIRetry::GraphQL).to receive(:retry).
                                            with({described_class::ConnectionError => { :wait => 1, :tries => 5 }}).
                                            and_call_original

      result = client.execute("query { shop { id } }")
      expect(result.dig("data", "shop", "id")).to be_a(String)
    end

    it "raises a RateLimitError when retry is disabled" do
      stub_request(:post, %r{\.myshopify\.com}).to_return(
        :status => 200,
        :headers => { "Content-Type" => "application/json" },
        :body => { :errors => [ :extensions => { :code => "THROTTLED" } ] }.to_json
      )

      expect { client(:retry => false).execute("query { shop { id } }") }.to raise_error(described_class::RateLimitError)
    end

    it "raises an HTTPError when the response does not have a 200 status" do
      stub_request(:post, %r{\.myshopify\.com}).to_return(:status => 503, :body => "NGINX blah blah")

      expect { client(:retry => false).execute("query { shop { id } }") }.to raise_error(described_class::HTTPError)
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
