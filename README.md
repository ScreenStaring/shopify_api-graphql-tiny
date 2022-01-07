# ShopifyAPI::GraphQL::Tiny

Lightweight, no-nonsense, Shopify GraphQL Admin API client with built-in retry.

## Usage

```rb
require "shopify_api/graphql/tiny"

gql = ShopifyAPI::GraphQL::Tiny.new("my-shop", token)
result = gql.execute(<<-GQL, :id => "gid://shopify/Customer/1283599123")
  query findCustomer($id: ID!) {
    customer(id: $id) {
      id
      tags
      metafields(first: 10 namespace: "foo") {
        edges {
          node {
            id
            key
            value
          }
        }
      }
    }
  }
GQL

customer = result["data"]["customer"]
p customer["tags"]
p customer.dig("metafields", "edges", 0, "node")["value"]

updates = { :id => customer["id"], :tags => customer["tags"] + %w[foo bar] }
result = gql.execute(<<-GQL, :input => updates)
  mutation customerUpdate($input: CustomerInput!) {
    customerUpdate(input: $input) {
      customer {
        id
      }
      userErrors {
        field
        message
      }
    }
  }
GQL

p result.dig("data", "customerUpdate", "userErrors")
```

## Testing

`cp env.template .env` and fill-in `.env` with the missing values. This requires a Shopify store.

## See Also

- [Shopify Dev Tools](https://github.com/ScreenStaring/shopify-dev-tools) - Command-line program to assist with the development and/or maintenance of Shopify apps and stores
- [ShopifyAPIRetry](https://github.com/ScreenStaring/shopify_api_retry) - Retry a ShopifyAPI request if rate-limited or other errors occur (REST and GraphQL APIs)

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

---

Made by [ScreenStaring](http://screenstaring.com)
