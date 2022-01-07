require "json"
require "shopify_api_retry"

RSpec.describe ShopifyAPI::GraphQL::Tiny do
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
      client = described_class.new(ENV["SHOPIFY_DOMAIN"], ENV["SHOPIFY_TOKEN"])
      client.execute("query { shop { id } }")

      endpoint = "https://%s/admin/api/graphql.json" % ENV["SHOPIFY_DOMAIN"]
      expect(WebMock).to have_requested(:post, endpoint)
    end

    it "sets the endpoint for the given API version" do
      client = described_class.new(ENV["SHOPIFY_DOMAIN"], ENV["SHOPIFY_TOKEN"], :version => "2021-10")
      client.execute("query { shop { id } }")

      endpoint = "https://%s/admin/api/2021-10/graphql.json" % ENV["SHOPIFY_DOMAIN"]
      expect(WebMock).to have_requested(:post, endpoint)
    end
  end

  describe ".execute" do
    before { @client = described_class.new(ENV["SHOPIFY_DOMAIN"], ENV["SHOPIFY_TOKEN"]) }

    it "executes queries" do
      result = @client.execute(<<-GQL)
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

      result = @client.execute(<<-GQL, :id => id)
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

      result = @client.execute(<<-GQL, :input => input)
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
                                            with(
                                              described_class::ConnectionError => { :wait => 3, :tries => 20 },
                                              described_class::HTTPError => { :wait => 3, :tries => 20 }
                                            ).
                                            and_call_original

      result = @client.execute("query { shop { id } }")
      expect(result.dig("data", "shop", "id")).to be_a(String)
    end

    it "retries failed requests using the user provided options" do
      client = described_class.new(
        ENV["SHOPIFY_DOMAIN"],
        ENV["SHOPIFY_TOKEN"],
        :retry => { described_class::ConnectionError => { :wait => 1, :tries => 5 } }
      )

      expect(ShopifyAPIRetry::GraphQL).to receive(:retry).
                                            with(described_class::ConnectionError => { :wait => 1, :tries => 5 }).
                                            and_call_original

      result = client.execute("query { shop { id } }")
      expect(result.dig("data", "shop", "id")).to be_a(String)
    end

    it "raises a RateLimitError when retry is disabled" do
      client = described_class.new(ENV["SHOPIFY_DOMAIN"], ENV["SHOPIFY_TOKEN"], :retry => false)

      stub_request(:post, %r{\.myshopify\.com}).to_return(
        :status => 200,
        :headers => { "Content-Type" => "application/json" },
        :body => { :errors => [ :extensions => { :code => "THROTTLED" } ] }.to_json
      )

      expect { client.execute("query { shop { id } }") }.to raise_error(described_class::RateLimitError)
    end

    it "raises an HTTPError when the response does not have a 200 status" do
      client = described_class.new(ENV["SHOPIFY_DOMAIN"], ENV["SHOPIFY_TOKEN"], :retry => false)

      stub_request(:post, %r{\.myshopify\.com}).to_return(:status => 503, :body => "NGINX blah blah")

      expect { client.execute("query { shop { id } }") }.to raise_error(described_class::HTTPError)
    end

    it "includes the Shopify GraphQL cost HTTP header" do
      @client.execute("query { shop { id } }")

      expect(WebMock).to have_requested(:post, %r{\.myshopify\.com}).with(:headers => {"X-GraphQL-Cost-Include-Fields" => "true"})
    end
  end
end
