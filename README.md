# ShopifyAPI::GraphQL::Tiny

Lightweight, no-nonsense, Shopify GraphQL Admin API client with built-in pagination and retry.

[![CI](https://github.com/ScreenStaring/shopify_api-graphql-tiny/actions/workflows/ci.yml/badge.svg)](https://github.com/ScreenStaring/shopify_api-graphql-tiny/actions)

## Usage

```rb
require "shopify_api/graphql/tiny"

gql = ShopifyAPI::GraphQL::Tiny.new("my-shop", token)

# Automatically retried
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

# Automatically retried as well
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

### Pagination

In addition to built-in request retry `ShopifyAPI::GraphQL::Tiny` also builds in support for pagination.

Using pagination requires you to include [the Shopify `PageInfo` object](https://shopify.dev/api/admin-graphql/2022-10/objects/PageInfo)
in your queries and wrap them in a function that accepts a page/cursor argument.

The pager's `#execute` is like the non-paginated `#execute` method and accepts additional, non-pagination query arguments:

```rb
pager.execute(query, :foo => 123)
```

And it accepts a block which will be passed each page returned by the query:

```rb
pager.execute(query, :foo => 123) do |page|
  # do something with each page
end
```

#### `after` Pagination

To use `after` pagination, i.e., to paginate forward, your query must:

- Make the page/cursor argument optional
- Include `PageInfo`'s `hasNextPage` and `endCursor` fields

For example:

```rb
FIND_ORDERS = <<-GQL
  query findOrders($after: String) {
    orders(first: 10 after: $after) {
      pageInfo {
        hasNextPage
        endCursor
      }
      edges {
        node {
          id
          email
        }
      }
    }
  }
GQL

pager = gql.paginate  # This is the same as gql.paginate(:after)
pager.execute(FIND_ORDERS) do |page|
  orders = page.dig("data", "orders", "edges")
  orders.each do |order|
    # ...
  end
end
```

By default it is assumed your GraphQL query uses a variable named `$after`. You can specify a different name using the `:variable`
option:

```rb
pager = gql.paginate(:after, :variable => "yourVariable")
```

#### `before` Pagination

To use `before` pagination, i.e. to paginate backward, your query must:

- Make the page/cursor argument **required**
- Include the `PageInfo`'s `hasPreviousPage` and `startCursor` fields
- Specify the `:before` argument to `#paginate`

For example:

```rb
FIND_ORDERS = <<-GQL
  query findOrders($before: String) {
    orders(last: 10 before: $before) {
      pageInfo {
        hasPreviousPage
        startCursor
      }
      edges {
        node {
          id
          email
        }
      }
    }
  }
GQL

pager = gql.paginate(:before)
pager.execute(FIND_ORDERS) do |page|
  # ...
end
```

By default it is assumed your GraphQL query uses a variable named `$before`. You can specify a different name using the `:variable`
option:

```rb
pager = gql.paginate(:before, :variable => "yourVariable")
```

#### Response Pagination Data

By default `ShopifyAPI::GraphQL::Tiny` will use the first `pageInfo` block with a next or previous page it finds
in the GraphQL response. If necessary you can specify an explicit location for the `pageInfo` block:

```rb
pager = gql.paginate(:after => %w[some path to it])
pager.execute(query) { }

pager = gql.paginate(:after => ->(data) { data.dig("some", "path", "to", "it") })
pager.execute(query) { }
```

The `"data"` and `"pageInfo"` keys are automatically added if not provided.

### Automatically Retrying Failed Requests

See [the docs](https://rubydoc.info/gems/shopify_api-graphql-tiny) for more information.

## Testing

`cp env.template .env` and fill-in `.env` with the missing values. This requires a Shopify store.

## See Also

- [Shopify Dev Tools](https://github.com/ScreenStaring/shopify-dev-tools) - Command-line program to assist with the development and/or maintenance of Shopify apps and stores
- [Shopify ID Export](https://github.com/ScreenStaring/shopify_id_export/) Dump Shopify product and variant IDs —along with other identifiers— to a CSV or JSON file
- [ShopifyAPIRetry](https://github.com/ScreenStaring/shopify_api_retry) - Retry a ShopifyAPI request if rate-limited or other errors occur (REST and GraphQL APIs)

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

---

Made by [ScreenStaring](http://screenstaring.com)
