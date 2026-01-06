require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

task :default => :spec

desc "Elicit a Shopify rate limit"
task :rate_limit do
  require "shopify_api/graphql/tiny"

  query =<<-GQL
    query {
      products(first: 50, sortKey: UPDATED_AT, reverse: true) {
        pageInfo {
          hasNextPage
          endCursor
        }
        edges {
          node {
            id
            title
            handle
            status
            createdAt
            updatedAt
            publishedAt
            vendor
            productType
            tags
            descriptionHtml
            description
            onlineStoreUrl
            options(first: 3) {
              id
              name
              position
              values
            }
            variants(first: 80) {
              edges {
                node {
                  id
                  title
                  price
                  compareAtPrice
                  sku
                  barcode
                  inventoryItem {
                    id
                    unitCost {
                      amount
                      currencyCode
                    }
                    countryCodeOfOrigin
                    harmonizedSystemCode
                  }
                  inventoryPolicy
                  taxable
                  availableForSale
                  metafields(first: 20) {
                    edges {
                      node {
                        id
                        namespace
                        key
                        value
                        type
                        description
                      }
                    }
                  }
                }
              }
            }
            media(first: 20) {
              edges {
                node {
                  __typename
                  alt
                  status
                  ... on MediaImage {
                    id
                    preview {
                      image {
                        url
                      }
                    }
                    image {
                      id
                      url
                      width
                      height
                      altText
                    }
                  }
                  ... on Video {
                    id
                    sources {
                      url
                      format
                      height
                      width
                    }
                  }
                  ... on ExternalVideo {
                    id
                    originUrl
                    embedUrl
                  }
                }
              }
            }
            images(first: 20) {
              edges {
                node {
                  id
                  url
                  altText
                  width
                  height
                }
              }
            }
            seo {
              title
              description
            }
            metafields(first: 30) {
              edges {
                node {
                  id
                  namespace
                  key
                  value
                  type
                  ownerType
                }
              }
            }
            collections(first: 10) {
              edges {
                node {
                  id
                  title
                  handle
                }
              }
            }
          }
        }
      }
    }
  GQL

  threads = 5.times.map do
    Thread.new do
      gql = ShopifyAPI::GQL::Tiny.new(ENV.fetch("SHOPIFY_DOMAIN"), ENV.fetch("SHOPIFY_TOKEN"), :debug => true)
      pp gql.execute(query).dig("extensions", "cost", "throttleStatus")
    end
  end

  threads.each(&:join)
end
