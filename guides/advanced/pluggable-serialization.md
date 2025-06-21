# Guide: Pluggable Serialization

Jido.Signal provides a pluggable serialization system that allows you to choose the most appropriate serialization format for your use case. Whether you need JSON interoperability, Erlang term performance, or compact binary formats, the serialization system adapts to your requirements.

## Overview

The serialization system is built around the `Jido.Signal.Serialization.Serializer` behaviour, which defines a common interface for different serialization strategies. This design allows you to:

- Switch between serialization formats without changing your application code
- Configure different serializers for different environments
- Implement custom serialization strategies
- Optimize for specific performance or compatibility requirements

## The Serializer Behaviour

The `Serializer` behaviour defines two core functions:

```elixir
@callback serialize(term(), keyword()) :: {:ok, binary()} | {:error, term()}
@callback deserialize(binary(), keyword()) :: {:ok, term()} | {:error, term()}
```

All serializers must implement these functions to provide consistent serialization and deserialization capabilities.

## Built-in Serializers

### JsonSerializer

The JSON serializer provides maximum interoperability with external systems and web services.

**Features:**
- Universal compatibility with JSON-supporting systems
- Human-readable output for debugging
- Web API friendly format
- Built on the fast Jason library

**Trade-offs:**
- Larger output size compared to binary formats
- Limited data type support (no atoms, tuples converted to lists)
- String-based keys only

**Usage:**

```elixir
alias Jido.Signal.Serialization.JsonSerializer

# Serialize a signal
signal = Jido.Signal.new(%{
  type: "user.created",
  source: "user_service",
  data: %{user_id: 123, email: "user@example.com"}
})

{:ok, json_binary} = JsonSerializer.serialize(signal)
{:ok, restored_signal} = JsonSerializer.deserialize(json_binary)
```

### ErlangTermSerializer

The Erlang term serializer provides the best performance and type fidelity for Erlang/Elixir systems.

**Features:**
- Perfect type preservation (atoms, tuples, PIDs, etc.)
- Optimal performance for Erlang/Elixir environments
- Compact binary representation
- Built-in compression support

**Trade-offs:**
- Erlang/Elixir specific format
- Not suitable for external system integration
- Binary format not human-readable

**Usage:**

```elixir
alias Jido.Signal.Serialization.ErlangTermSerializer

# Serialize with perfect type preservation
signal = Jido.Signal.new(%{
  type: "order.processed",
  source: "order_service",
  data: %{
    order_id: 12345,
    items: [{:product, "laptop", 999.99}, {:product, "mouse", 29.99}],
    status: :completed
  }
})

{:ok, binary} = ErlangTermSerializer.serialize(signal)
{:ok, restored_signal} = ErlangTermSerializer.deserialize(binary)

# All Erlang types are preserved exactly
assert restored_signal.data.status == :completed
assert is_tuple(Enum.at(restored_signal.data.items, 0))
```

### MsgpackSerializer

The MessagePack serializer offers a balance between compactness and interoperability.

**Features:**
- Compact binary format (smaller than JSON)
- Cross-platform compatibility
- Better type support than JSON
- Fast serialization/deserialization

**Trade-offs:**
- Requires MessagePack library support
- Some Elixir types converted (atoms to strings, tuples to arrays)
- Not human-readable

**Usage:**

```elixir
alias Jido.Signal.Serialization.MsgpackSerializer

# Serialize with compact binary format
signal = Jido.Signal.new(%{
  type: "metrics.collected",
  source: "metrics_service",
  data: %{
    timestamp: 1640995200,
    values: [1.2, 3.4, 5.6, 7.8],
    metadata: %{region: "us-west-2", instance: "i-123"}
  }
})

{:ok, msgpack_binary} = MsgpackSerializer.serialize(signal)
{:ok, restored_signal} = MsgpackSerializer.deserialize(msgpack_binary)
```

## Configuration

### Setting the Default Serializer

Configure the default serializer in your application configuration:

```elixir
# config/config.exs
config :jido, :default_serializer, Jido.Signal.Serialization.JsonSerializer

# For production Elixir-only systems
config :jido, :default_serializer, Jido.Signal.Serialization.ErlangTermSerializer

# For network-optimized scenarios
config :jido, :default_serializer, Jido.Signal.Serialization.MsgpackSerializer
```

### Runtime Configuration

You can also change the serializer at runtime:

```elixir
alias Jido.Signal.Serialization.Config

# Change default serializer
Config.set_default_serializer(Jido.Signal.Serialization.ErlangTermSerializer)

# Verify current configuration
Config.default_serializer()
#=> Jido.Signal.Serialization.ErlangTermSerializer
```

### Per-Operation Serializer Override

Override the serializer for specific operations:

```elixir
# Use JSON for external API integration
{:ok, json_binary} = Jido.Signal.serialize(signal, 
  serializer: Jido.Signal.Serialization.JsonSerializer)

# Use Erlang terms for internal processing
{:ok, term_binary} = Jido.Signal.serialize(signal, 
  serializer: Jido.Signal.Serialization.ErlangTermSerializer)

# Use MessagePack for network transmission
{:ok, msgpack_binary} = Jido.Signal.serialize(signal, 
  serializer: Jido.Signal.Serialization.MsgpackSerializer)
```

## Performance Comparison

### Serialization Performance

Different serializers have varying performance characteristics:

```elixir
# Benchmark different serializers
signal = Jido.Signal.new(%{
  type: "benchmark.test",
  source: "benchmark_service",
  data: %{
    payload: String.duplicate("x", 1000),
    numbers: Enum.to_list(1..1000)
  }
})

serializers = [
  {"JSON", Jido.Signal.Serialization.JsonSerializer},
  {"Erlang", Jido.Signal.Serialization.ErlangTermSerializer},
  {"MessagePack", Jido.Signal.Serialization.MsgpackSerializer}
]

Enum.each(serializers, fn {name, serializer} ->
  {time, {:ok, binary}} = :timer.tc(fn ->
    Jido.Signal.serialize(signal, serializer: serializer)
  end)
  
  IO.puts("#{name}: #{time}μs, #{byte_size(binary)} bytes")
end)
```

**Typical Performance Characteristics:**

| Serializer | Serialization Speed | Deserialization Speed | Output Size |
|------------|-------------------|---------------------|-------------|
| ErlangTermSerializer | Fastest | Fastest | Compact |
| MsgpackSerializer | Fast | Fast | Most Compact |
| JsonSerializer | Moderate | Moderate | Largest |

### Size Comparison

For a typical signal with mixed data types:

```elixir
signal = Jido.Signal.new(%{
  type: "user.profile.updated",
  source: "user_service",
  data: %{
    user_id: 12345,
    changes: %{
      email: "new@example.com",
      preferences: %{notifications: true, theme: "dark"}
    },
    timestamp: "2023-12-01T10:30:00Z"
  }
})

# Compare serialized sizes
{:ok, json} = Jido.Signal.serialize(signal, serializer: JsonSerializer)
{:ok, erlang} = Jido.Signal.serialize(signal, serializer: ErlangTermSerializer)
{:ok, msgpack} = Jido.Signal.serialize(signal, serializer: MsgpackSerializer)

IO.puts("JSON: #{byte_size(json)} bytes")       # ~280 bytes
IO.puts("Erlang: #{byte_size(erlang)} bytes")   # ~245 bytes
IO.puts("MessagePack: #{byte_size(msgpack)} bytes") # ~195 bytes
```

## Implementing Custom Serializers

Create custom serializers by implementing the `Serializer` behaviour:

```elixir
defmodule MyApp.CustomSerializer do
  @behaviour Jido.Signal.Serialization.Serializer

  @impl true
  def serialize(term, _opts \\ []) do
    try do
      # Your custom serialization logic
      custom_binary = your_serialization_function(term)
      {:ok, custom_binary}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  @impl true
  def deserialize(binary, _opts \\ []) do
    try do
      # Your custom deserialization logic
      term = your_deserialization_function(binary)
      {:ok, term}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp your_serialization_function(term) do
    # Implement your custom serialization
    # For example, using a custom compression algorithm
    term
    |> :erlang.term_to_binary()
    |> :zlib.compress()
  end

  defp your_deserialization_function(binary) do
    # Implement your custom deserialization
    binary
    |> :zlib.uncompress()
    |> :erlang.binary_to_term([:safe])
  end
end
```

### Using Custom Serializers

```elixir
# Register your custom serializer
config :jido, :default_serializer, MyApp.CustomSerializer

# Or use it explicitly
{:ok, binary} = Jido.Signal.serialize(signal, serializer: MyApp.CustomSerializer)
{:ok, restored} = Jido.Signal.deserialize(binary, serializer: MyApp.CustomSerializer)
```

## Complete Working Examples

### Multi-Environment Setup

```elixir
# config/config.exs - Base configuration
config :jido, :default_serializer, Jido.Signal.Serialization.JsonSerializer

# config/dev.exs - Development (human-readable)
config :jido, :default_serializer, Jido.Signal.Serialization.JsonSerializer

# config/prod.exs - Production (performance-optimized)
config :jido, :default_serializer, Jido.Signal.Serialization.ErlangTermSerializer

# config/test.exs - Testing (consistent, fast)
config :jido, :default_serializer, Jido.Signal.Serialization.ErlangTermSerializer
```

### API Integration Pattern

```elixir
defmodule MyApp.EventProcessor do
  alias Jido.Signal.Serialization.{JsonSerializer, ErlangTermSerializer}

  def process_external_event(json_payload) do
    # Deserialize from external JSON
    {:ok, signal} = JsonSerializer.deserialize(json_payload)
    
    # Process the signal
    processed_signal = transform_signal(signal)
    
    # Store internally using Erlang terms for performance
    {:ok, binary} = ErlangTermSerializer.serialize(processed_signal)
    store_in_database(binary)
  end

  def send_to_external_system(signal) do
    # Serialize to JSON for external API
    {:ok, json_payload} = JsonSerializer.serialize(signal)
    HTTPClient.post("/api/events", json_payload)
  end

  defp transform_signal(signal) do
    # Your signal transformation logic
    signal
  end

  defp store_in_database(binary) do
    # Your database storage logic
    :ok
  end
end
```

### High-Performance Batch Processing

```elixir
defmodule MyApp.BatchProcessor do
  alias Jido.Signal.Serialization.ErlangTermSerializer

  def process_batch(signals) when is_list(signals) do
    # Serialize entire batch at once for maximum performance
    {:ok, batch_binary} = ErlangTermSerializer.serialize(signals)
    
    # Store or transmit the batch
    store_batch(batch_binary)
    
    # Process each signal individually
    Enum.each(signals, &process_signal/1)
  end

  def restore_batch(batch_binary) do
    # Deserialize entire batch
    {:ok, signals} = ErlangTermSerializer.deserialize(batch_binary)
    
    # Validate all signals were restored correctly
    Enum.all?(signals, &match?(%Jido.Signal{}, &1))
  end

  defp process_signal(signal) do
    # Your signal processing logic
    IO.puts("Processing: #{signal.type}")
  end

  defp store_batch(binary) do
    # Your batch storage logic
    File.write("/tmp/batch_#{:os.system_time()}.bin", binary)
  end
end
```

## Best Practices

### Serializer Selection Guidelines

**Choose JsonSerializer when:**
- Integrating with external web services
- Debugging and development (human-readable output)
- Cross-platform compatibility is required
- Working with JavaScript/web frontends

**Choose ErlangTermSerializer when:**
- Building Elixir-only systems
- Performance is critical
- Type fidelity must be preserved
- Inter-node communication in Elixir clusters

**Choose MsgpackSerializer when:**
- Network bandwidth is limited
- Cross-platform binary format is needed
- Balanced performance and size requirements
- Integrating with MessagePack-supporting systems

### Configuration Best Practices

1. **Set environment-specific defaults:**
   ```elixir
   # Development: human-readable for debugging
   config :jido, :default_serializer, JsonSerializer
   
   # Production: performance-optimized
   config :jido, :default_serializer, ErlangTermSerializer
   ```

2. **Use explicit serializers for critical paths:**
   ```elixir
   # Always use Erlang terms for internal high-performance operations
   {:ok, binary} = Signal.serialize(signal, serializer: ErlangTermSerializer)
   ```

3. **Validate serializer compatibility:**
   ```elixir
   # Ensure configured serializer is available
   case Jido.Signal.Serialization.Config.validate() do
     :ok -> {:ok, "Configuration valid"}
     {:error, errors} -> {:error, "Configuration errors: #{inspect(errors)}"}
   end
   ```

### Error Handling

Always handle serialization errors gracefully:

```elixir
case Jido.Signal.serialize(signal, serializer: MySerializer) do
  {:ok, binary} -> 
    # Success case
    process_binary(binary)
    
  {:error, reason} -> 
    # Handle serialization failure
    Logger.error("Serialization failed: #{reason}")
    {:error, :serialization_failed}
end
```

### Testing Serialization

Test your serialization strategies thoroughly:

```elixir
defmodule MyApp.SerializationTest do
  use ExUnit.Case
  
  @serializers [
    Jido.Signal.Serialization.JsonSerializer,
    Jido.Signal.Serialization.ErlangTermSerializer,
    Jido.Signal.Serialization.MsgpackSerializer
  ]

  test "round-trip serialization preserves signal structure" do
    signal = Jido.Signal.new(%{
      type: "test.event",
      source: "test_service",
      data: %{key: "value"}
    })

    for serializer <- @serializers do
      {:ok, binary} = Jido.Signal.serialize(signal, serializer: serializer)
      {:ok, restored} = Jido.Signal.deserialize(binary, serializer: serializer)
      
      assert restored.type == signal.type
      assert restored.source == signal.source
      # Note: data comparison may vary by serializer type handling
    end
  end
end
```

The pluggable serialization system provides the flexibility to optimize your Jido.Signal implementation for any use case while maintaining a consistent API across your application.
