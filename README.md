# ShopifyAPI::GraphQL::Tiny

Lightweight, no-nonsense, Shopify GraphQL Admin API client with built-in pagination and retry

[![CI](https://github.com/ScreenStaring/shopify_api-graphql-tiny/actions/workflows/ci.yml/badge.svg)](https://github.com/ScreenStaring/shopify_api-graphql-tiny/actions)

## Installation

Add this line to your application's `Gemfile`:

```ruby
gem "shopify_api-graphql-tiny"
```

And then execute:

```sh
bundle
```

Or install it yourself as:

```sh
gem install shopify_api-graphql-tiny
```

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

### Automatically Retrying Failed Requests

There are 2 types of retries: 1) request is rate-limited by Shopify 2) request fails due to an exception or non-200 HTTP response.

When a request is rate-limited by Shopify retry occurs according to [Shopify's `throttleStatus`](https://shopify.dev/docs/api/admin-graphql/unstable#rate-limits)

When a request fails due to an exception or non-200 HTTP status a retry will be attempted after an exponential backoff waiting period.
This is controlled by `ShopifyAPI::GraphQL::Tiny::DEFAULT_BACKOFF_OPTIONS`. It contains:

* `:base_delay` - `0.5`
* `:jitter` - `true`
* `:max_attempts` - `10`
* `:max_delay` - `60`
* `:multiplier` - `2.0`

`:max_attempts` dictates how many retry attempts will be made **for all** types of retries.

These can be overridden globally (by assigning to the constant) or per instance:

```rb
gql = ShopifyAPI::GraphQL::Tiny.new(shop, token, :max_attempts => 20, :max_delay => 90)
```

`ShopifyAPI::GraphQL::Tiny::DEFAULT_RETRY_ERRORS` determines what is retried. It contains and HTTP statuses codes, Shopify GraphQL errors codes, and exceptions.
By default it contains:

* `"5XX"` - Any HTTP 5XX status
* `"INTERNAL_SERVER_ERROR"` - Shopify GraphQL error code
* `"TIMEOUT"` - Shopify GraphQL error code
* `EOFError`
* `Errno::ECONNABORTED`
* `Errno::ECONNREFUSED`
* `Errno::ECONNRESET`
* `Errno::EHOSTUNREACH`
* `Errno::EINVAL`
* `Errno::ENETUNREACH`
* `Errno::ENOPROTOOPT`
* `Errno::ENOTSOCK`
* `Errno::EPIPE`
* `Errno::ETIMEDOUT`
* `Net::HTTPBadResponse`
* `Net::HTTPHeaderSyntaxError`
* `Net::ProtocolError`
* `Net::ReadTimeout`
* `OpenSSL::SSL::SSLError`
* `SocketError`
* `Timeout::Error`

These can be overridden globally (by assigning to the constant) or per instance:

```rb
# Only retry on 2 errors
gql = ShopifyAPI::GraphQL::Tiny.new(shop, token, :retry => [SystemCallError, "500"])
```

#### Disabling Automatic Retry

To disable retries set the `:retry` option to `false`:

```rb
gql = ShopifyAPI::GraphQL::Tiny.new(shop, token, :retry => false)
```

### Pagination

In addition to built-in request retry `ShopifyAPI::GraphQL::Tiny` also builds in support for pagination.

Using pagination requires you to include [the Shopify `PageInfo` object](https://shopify.dev/api/admin-graphql/2022-10/objects/PageInfo)
in your queries and wrap them in a function that accepts a page/cursor argument.

The pager's `#execute` is like the non-paginated `#execute` method and accepts additional, non-pagination query arguments:

```rb
gql = ShopifyAPI::GraphQL::Tiny.new("my-shop", token)
pager = gql.paginate
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
pager.execute(query) { |page| }

pager = gql.paginate(:after => ->(data) { data.dig("some", "path", "to", "it") })
pager.execute(query) { |page| }
```

The `"data"` and `"pageInfo"` keys are automatically added if not provided.

## Testing

`cp env.template .env` and fill-in `.env` with the missing values. This requires a Shopify store.

To elicit a request that will be rate-limited by Shopify run following Rake task:

```sh
bundle exec rake rate_limit SHOPIFY_DOMAIN=your-domain SHOPIFY_TOKEN=your-token
```

## See Also

- [Shopify Dev Tools](https://github.com/ScreenStaring/shopify-dev-tools) - Command-line program to assist with the development and/or maintenance of Shopify apps and stores
- [Shopify ID Export](https://github.com/ScreenStaring/shopify_id_export/) - Dump Shopify product and variant IDs —along with other identifiers— to a CSV or JSON file
- [`TinyGID`](https://github.com/sshaw/tiny_gid/) - Build Global ID (gid://) URI strings from scalar values

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

---

Made by [ScreenStaring](http://screenstaring.com)
