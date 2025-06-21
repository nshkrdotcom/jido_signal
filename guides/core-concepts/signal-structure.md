# Guide: The Signal Structure

A `Jido.Signal` is the fundamental message unit in the system. It provides a standardized envelope that aligns with the CloudEvents specification, ensuring interoperability and consistency across your event-driven architecture.

## Anatomy of a Signal

Every signal contains the following fields:

### Required Fields

- **`id`** - Unique identifier for the signal (auto-generated if not provided)
- **`source`** - Identifies the context in which the signal occurred (e.g., "user_service", "payment_processor")
- **`type`** - Describes the type of event (e.g., "user.created", "payment.processed")
- **`data`** - The actual payload/content of the signal

### Optional Fields

- **`time`** - Timestamp when the signal was created (auto-generated if not provided)
- **`subject`** - The subject of the event (e.g., user ID, order ID)
- **`datacontenttype`** - MIME type of the data (defaults to "application/json")
- **`dataschema`** - URI reference to the schema of the data
- **`metadata`** - Additional key-value pairs for extensibility

## Creating Signals

### Basic Signal Creation

```elixir
# Simple signal with minimal required fields
signal = Jido.Signal.new(%{
  type: "user.created",
  source: "user_service",
  data: %{
    user_id: 123,
    email: "user@example.com"
  }
})
```

### Signal with Full Metadata

```elixir
signal = Jido.Signal.new(%{
  id: "custom-id-123",
  type: "user.profile.updated",
  source: "user_service",
  subject: "user:123",
  time: DateTime.utc_now(),
  data: %{
    user_id: 123,
    changes: %{email: "new@example.com"}
  },
  datacontenttype: "application/json",
  metadata: %{
    version: "1.0",
    region: "us-west-2"
  }
})
```

## Defining Custom Signal Types

For strongly-typed signals with built-in validation, use the `use Jido.Signal` macro:

```elixir
defmodule MyApp.UserCreatedSignal do
  use Jido.Signal,
    type: "user.created",
    schema: [
      user_id: [type: :integer, required: true],
      email: [type: :string, required: true],
      name: [type: :string, required: false],
      created_at: [type: :string, required: false]
    ]
end
```

### Using Custom Signal Types

```elixir
# This will validate the data against the schema
{:ok, signal} = MyApp.UserCreatedSignal.new(%{
  source: "user_service",
  data: %{
    user_id: 123,
    email: "user@example.com",
    name: "John Doe"
  }
})

# Invalid data will return an error
{:error, reason} = MyApp.UserCreatedSignal.new(%{
  source: "user_service",
  data: %{
    # Missing required user_id
    email: "user@example.com"
  }
})
```

## Schema Validation

The `:schema` option in custom signal types provides compile-time and runtime validation:

```elixir
defmodule MyApp.PaymentSignal do
  use Jido.Signal,
    type: "payment.processed",
    schema: [
      payment_id: [type: :string, required: true],
      amount: [type: :integer, required: true],
      currency: [type: :string, required: true, default: "USD"],
      customer_id: [type: :string, required: true],
      status: [type: :string, required: true, 
               in: ["pending", "completed", "failed"]]
    ]
end
```

### Schema Options

- **`type`** - Data type (`:string`, `:integer`, `:boolean`, `:map`, `:list`)
- **`required`** - Whether the field is mandatory
- **`default`** - Default value if not provided
- **`in`** - List of valid values
- **`format`** - Format validation (e.g., email, UUID)

## Signal Paths and Routing

The signal's `type` field is used for routing and subscription matching:

```elixir
# Exact match
"user.created"

# Single-level wildcard (matches one segment)
"user.*"          # Matches "user.created", "user.updated", etc.

# Multi-level wildcard (matches any number of segments)
"user.**"         # Matches "user.created", "user.profile.updated", etc.
```

## Best Practices

### Naming Conventions

Use hierarchical naming with dots as separators:

```elixir
# Good examples
"user.created"
"user.profile.updated"
"payment.transaction.completed"
"inventory.item.stock.low"

# Avoid
"userCreated"
"user_created"
"USER.CREATED"
```

### Source Identification

Make sources descriptive and consistent:

```elixir
# Good examples
"user_service"
"payment_processor"
"inventory_manager"
"notification_service"

# Avoid generic sources
"app"
"system"
"service"
```

### Data Structure

Keep data focused and avoid deeply nested structures:

```elixir
# Good - flat and focused
data: %{
  user_id: 123,
  email: "user@example.com",
  plan: "premium"
}

# Less ideal - deeply nested
data: %{
  user: %{
    profile: %{
      contact: %{
        email: "user@example.com"
      }
    }
  }
}
```

## CloudEvents Compatibility

Jido.Signal maps directly to CloudEvents fields:

| Jido.Signal | CloudEvents | Description |
|-------------|-------------|-------------|
| `id` | `id` | Unique event identifier |
| `source` | `source` | Event source context |
| `type` | `type` | Event type |
| `data` | `data` | Event payload |
| `time` | `time` | Event timestamp |
| `subject` | `subject` | Event subject |
| `datacontenttype` | `datacontenttype` | Content type |
| `dataschema` | `dataschema` | Schema reference |
| `metadata` | Extensions | Additional attributes |

This compatibility ensures your signals can be easily integrated with other CloudEvents-compliant systems.
