# Custom Dispatch Adapters

This guide covers creating custom dispatch adapters to extend Jido.Signal's capabilities. You'll learn how to implement the `Jido.Signal.Dispatch.Adapter` behaviour, handle validation and delivery, and build production-ready adapters.

## Understanding Dispatch Adapters

Dispatch adapters are responsible for delivering signals to external systems. They implement two core functions:

- **`validate_opts/1`** - Validates configuration options before use
- **`deliver/2`** - Handles the actual signal delivery

All built-in adapters follow this pattern, from simple console output to complex HTTP webhooks.

## The Adapter Behaviour

Every custom adapter must implement the `Jido.Signal.Dispatch.Adapter` behaviour:

```elixir
defmodule MyApp.CustomAdapter do
  @behaviour Jido.Signal.Dispatch.Adapter

  @impl true
  def validate_opts(opts) do
    # Validate configuration options
    # Return {:ok, validated_opts} or {:error, reason}
  end

  @impl true
  def deliver(signal, opts) do
    # Deliver the signal using validated options
    # Return :ok or {:error, reason}
  end
end
```

## Implementing validate_opts/1

The `validate_opts/1` callback validates and normalizes configuration options. It's called once when the adapter is configured, not on every signal delivery.

### Basic Validation

```elixir
def validate_opts(opts) do
  required_field = Keyword.get(opts, :required_field)
  
  if required_field do
    {:ok, opts}
  else
    {:error, "required_field is missing"}
  end
end
```

### Comprehensive Validation

```elixir
def validate_opts(opts) do
  with {:ok, url} <- validate_url(Keyword.get(opts, :url)),
       {:ok, timeout} <- validate_timeout(Keyword.get(opts, :timeout, 5000)),
       {:ok, format} <- validate_format(Keyword.get(opts, :format, :json)) do
    {:ok, [url: url, timeout: timeout, format: format]}
  end
end

defp validate_url(nil), do: {:error, "url is required"}
defp validate_url(url) when is_binary(url) do
  case URI.parse(url) do
    %URI{scheme: scheme, host: host} when not is_nil(scheme) and not is_nil(host) ->
      {:ok, url}
    _ ->
      {:error, "invalid url format"}
  end
end

defp validate_timeout(timeout) when is_integer(timeout) and timeout > 0 do
  {:ok, timeout}
end
defp validate_timeout(_), do: {:error, "timeout must be a positive integer"}

defp validate_format(format) when format in [:json, :xml, :text] do
  {:ok, format}
end
defp validate_format(invalid), do: {:error, "invalid format: #{inspect(invalid)}"}
```

## Implementing deliver/2

The `deliver/2` callback handles the actual signal delivery. It receives the signal and validated options from `validate_opts/1`.

### Basic Delivery

```elixir
def deliver(signal, opts) do
  try do
    # Perform delivery logic
    do_delivery(signal, opts)
    :ok
  rescue
    error -> {:error, {:delivery_failed, error}}
  end
end
```

### Error Handling

Always handle errors gracefully and return descriptive error messages:

```elixir
def deliver(signal, opts) do
  case do_delivery(signal, opts) do
    :ok -> :ok
    {:error, :timeout} -> {:error, :timeout}
    {:error, :connection_refused} -> {:error, :connection_refused}
    {:error, other} -> {:error, {:delivery_failed, other}}
  end
end
```

## Complete Working Examples

### File Writing Adapter

This adapter writes signals to files, useful for logging or audit trails:

```elixir
defmodule MyApp.FileAdapter do
  @moduledoc """
  Adapter for writing signals to files.
  
  ## Configuration Options
  
  * `:path` - (required) File path to write to
  * `:format` - (optional) Output format, one of [:json, :text], defaults to :json
  * `:append` - (optional) Whether to append to file, defaults to true
  * `:create_dirs` - (optional) Whether to create parent directories, defaults to true
  
  ## Examples
  
      config = {MyApp.FileAdapter, [
        path: "/var/log/signals.log",
        format: :json,
        append: true
      ]}
  """
  
  @behaviour Jido.Signal.Dispatch.Adapter
  require Logger

  @valid_formats [:json, :text]

  @impl true
  def validate_opts(opts) do
    with {:ok, path} <- validate_path(Keyword.get(opts, :path)),
         {:ok, format} <- validate_format(Keyword.get(opts, :format, :json)),
         {:ok, append} <- validate_boolean(Keyword.get(opts, :append, true), :append),
         {:ok, create_dirs} <- validate_boolean(Keyword.get(opts, :create_dirs, true), :create_dirs) do
      validated_opts = [
        path: path,
        format: format,
        append: append,
        create_dirs: create_dirs
      ]
      {:ok, validated_opts}
    end
  end

  @impl true
  def deliver(signal, opts) do
    path = Keyword.fetch!(opts, :path)
    format = Keyword.fetch!(opts, :format)
    append = Keyword.fetch!(opts, :append)
    create_dirs = Keyword.fetch!(opts, :create_dirs)

    with :ok <- maybe_create_directories(path, create_dirs),
         {:ok, content} <- format_signal(signal, format),
         :ok <- write_to_file(path, content, append) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Private helper functions

  defp validate_path(nil), do: {:error, "path is required"}
  defp validate_path(path) when is_binary(path), do: {:ok, path}
  defp validate_path(invalid), do: {:error, "path must be a string, got: #{inspect(invalid)}"}

  defp validate_format(format) when format in @valid_formats, do: {:ok, format}
  defp validate_format(invalid), do: {:error, "invalid format: #{inspect(invalid)}. Must be one of #{inspect(@valid_formats)}"}

  defp validate_boolean(value, _field) when is_boolean(value), do: {:ok, value}
  defp validate_boolean(invalid, field), do: {:error, "#{field} must be a boolean, got: #{inspect(invalid)}"}

  defp maybe_create_directories(_path, false), do: :ok
  defp maybe_create_directories(path, true) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, reason}}
    end
  end

  defp format_signal(signal, :json) do
    case Jason.encode(signal) do
      {:ok, json} -> {:ok, json <> "\n"}
      {:error, reason} -> {:error, {:json_encode_failed, reason}}
    end
  end

  defp format_signal(signal, :text) do
    timestamp = DateTime.to_iso8601(signal.time)
    content = """
    [#{timestamp}] #{signal.type} from #{signal.source}
    Data: #{inspect(signal.data, pretty: true)}
    
    """
    {:ok, content}
  end

  defp write_to_file(path, content, append) do
    mode = if append, do: [:append], else: [:write]
    
    case File.write(path, content, mode) do
      :ok -> :ok
      {:error, reason} -> {:error, {:file_write_failed, reason}}
    end
  end
end
```

### Database Storage Adapter

This adapter stores signals in a database using Ecto:

```elixir
defmodule MyApp.DatabaseAdapter do
  @moduledoc """
  Adapter for storing signals in a database.
  
  ## Configuration Options
  
  * `:repo` - (required) Ecto repository module
  * `:table` - (optional) Table name, defaults to "signals"
  * `:batch_size` - (optional) Batch insert size, defaults to 1
  
  ## Examples
  
      config = {MyApp.DatabaseAdapter, [
        repo: MyApp.Repo,
        table: "audit_signals",
        batch_size: 100
      ]}
  """
  
  @behaviour Jido.Signal.Dispatch.Adapter
  require Logger

  @impl true
  def validate_opts(opts) do
    with {:ok, repo} <- validate_repo(Keyword.get(opts, :repo)),
         {:ok, table} <- validate_table(Keyword.get(opts, :table, "signals")),
         {:ok, batch_size} <- validate_batch_size(Keyword.get(opts, :batch_size, 1)) do
      validated_opts = [
        repo: repo,
        table: table,
        batch_size: batch_size
      ]
      {:ok, validated_opts}
    end
  end

  @impl true
  def deliver(signal, opts) do
    repo = Keyword.fetch!(opts, :repo)
    table = Keyword.fetch!(opts, :table)

    # Convert signal to database record
    record = %{
      id: signal.id,
      type: signal.type,
      source: signal.source,
      data: signal.data,
      time: signal.time,
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    # Insert using dynamic query
    query = """
    INSERT INTO #{table} (id, type, source, data, time, inserted_at, updated_at)
    VALUES ($1, $2, $3, $4, $5, $6, $7)
    """

    case repo.query(query, [
      record.id,
      record.type,
      record.source,
      Jason.encode!(record.data),
      record.time,
      record.inserted_at,
      record.updated_at
    ]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, {:database_insert_failed, reason}}
    end
  end

  # Private helper functions

  defp validate_repo(nil), do: {:error, "repo is required"}
  defp validate_repo(repo) when is_atom(repo) do
    if Code.ensure_loaded?(repo) and function_exported?(repo, :query, 2) do
      {:ok, repo}
    else
      {:error, "repo must be a valid Ecto repository"}
    end
  end
  defp validate_repo(invalid), do: {:error, "repo must be a module name, got: #{inspect(invalid)}"}

  defp validate_table(table) when is_binary(table) and table != "", do: {:ok, table}
  defp validate_table(invalid), do: {:error, "table must be a non-empty string, got: #{inspect(invalid)}"}

  defp validate_batch_size(size) when is_integer(size) and size > 0, do: {:ok, size}
  defp validate_batch_size(invalid), do: {:error, "batch_size must be a positive integer, got: #{inspect(invalid)}"}
end
```

### Custom API Integration Adapter

This adapter integrates with external APIs with authentication and retry logic:

```elixir
defmodule MyApp.APIAdapter do
  @moduledoc """
  Adapter for integrating with external APIs.
  
  ## Configuration Options
  
  * `:url` - (required) API endpoint URL
  * `:auth` - (optional) Authentication config map
  * `:headers` - (optional) Custom headers
  * `:timeout` - (optional) Request timeout in milliseconds
  * `:retry` - (optional) Retry configuration
  
  ## Examples
  
      config = {MyApp.APIAdapter, [
        url: "https://api.example.com/events",
        auth: %{type: :bearer, token: "secret-token"},
        headers: [{"x-source", "jido-signal"}],
        timeout: 10_000,
        retry: %{max_attempts: 3, base_delay: 1000}
      ]}
  """
  
  @behaviour Jido.Signal.Dispatch.Adapter
  require Logger

  @default_timeout 5000
  @default_retry %{max_attempts: 3, base_delay: 1000, max_delay: 5000}

  @impl true
  def validate_opts(opts) do
    with {:ok, url} <- validate_url(Keyword.get(opts, :url)),
         {:ok, auth} <- validate_auth(Keyword.get(opts, :auth)),
         {:ok, headers} <- validate_headers(Keyword.get(opts, :headers, [])),
         {:ok, timeout} <- validate_timeout(Keyword.get(opts, :timeout, @default_timeout)),
         {:ok, retry} <- validate_retry(Keyword.get(opts, :retry, @default_retry)) do
      validated_opts = [
        url: url,
        auth: auth,
        headers: headers,
        timeout: timeout,
        retry: retry
      ]
      {:ok, validated_opts}
    end
  end

  @impl true
  def deliver(signal, opts) do
    url = Keyword.fetch!(opts, :url)
    auth = Keyword.fetch!(opts, :auth)
    headers = Keyword.fetch!(opts, :headers)
    timeout = Keyword.fetch!(opts, :timeout)
    retry_config = Keyword.fetch!(opts, :retry)

    # Prepare request
    body = Jason.encode!(signal)
    headers = build_headers(headers, auth)

    # Make request with retry
    do_request_with_retry(url, headers, body, timeout, retry_config)
  end

  # Private helper functions

  defp validate_url(nil), do: {:error, "url is required"}
  defp validate_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when not is_nil(scheme) and not is_nil(host) ->
        {:ok, url}
      _ ->
        {:error, "invalid url format"}
    end
  end
  defp validate_url(invalid), do: {:error, "url must be a string, got: #{inspect(invalid)}"}

  defp validate_auth(nil), do: {:ok, nil}
  defp validate_auth(%{type: :bearer, token: token}) when is_binary(token) do
    {:ok, %{type: :bearer, token: token}}
  end
  defp validate_auth(%{type: :basic, username: user, password: pass}) 
       when is_binary(user) and is_binary(pass) do
    {:ok, %{type: :basic, username: user, password: pass}}
  end
  defp validate_auth(invalid), do: {:error, "invalid auth configuration: #{inspect(invalid)}"}

  defp validate_headers(headers) when is_list(headers) do
    if Enum.all?(headers, fn {k, v} -> is_binary(k) and is_binary(v) end) do
      {:ok, headers}
    else
      {:error, "headers must be a list of string tuples"}
    end
  end
  defp validate_headers(invalid), do: {:error, "headers must be a list, got: #{inspect(invalid)}"}

  defp validate_timeout(timeout) when is_integer(timeout) and timeout > 0 do
    {:ok, timeout}
  end
  defp validate_timeout(invalid), do: {:error, "timeout must be a positive integer, got: #{inspect(invalid)}"}

  defp validate_retry(%{max_attempts: max, base_delay: base, max_delay: max_delay} = retry)
       when is_integer(max) and max > 0 and is_integer(base) and base > 0 and is_integer(max_delay) and max_delay > 0 do
    {:ok, retry}
  end
  defp validate_retry(invalid), do: {:error, "invalid retry configuration: #{inspect(invalid)}"}

  defp build_headers(base_headers, nil) do
    [{"content-type", "application/json"} | base_headers]
  end
  defp build_headers(base_headers, %{type: :bearer, token: token}) do
    auth_header = {"authorization", "Bearer #{token}"}
    [{"content-type", "application/json"}, auth_header | base_headers]
  end
  defp build_headers(base_headers, %{type: :basic, username: user, password: pass}) do
    credentials = Base.encode64("#{user}:#{pass}")
    auth_header = {"authorization", "Basic #{credentials}"}
    [{"content-type", "application/json"}, auth_header | base_headers]
  end

  defp do_request_with_retry(url, headers, body, timeout, retry_config, attempt \\ 1) do
    case make_http_request(url, headers, body, timeout) do
      :ok ->
        :ok

      {:error, reason} = error ->
        if should_retry?(attempt, retry_config, reason) do
          delay = calculate_delay(attempt, retry_config)
          Logger.warning("API request failed, retrying in #{delay}ms: #{inspect(reason)}")
          Process.sleep(delay)
          do_request_with_retry(url, headers, body, timeout, retry_config, attempt + 1)
        else
          Logger.error("API request failed after #{attempt} attempts: #{inspect(reason)}")
          error
        end
    end
  end

  defp make_http_request(url, headers, body, timeout) do
    case HTTPoison.post(url, body, headers, timeout: timeout) do
      {:ok, %HTTPoison.Response{status_code: code}} when code >= 200 and code < 300 ->
        :ok
      {:ok, %HTTPoison.Response{status_code: code, body: body}} ->
        {:error, {:http_error, code, body}}
      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, {:http_error, reason}}
    end
  end

  defp should_retry?(attempt, %{max_attempts: max_attempts}, reason) do
    attempt < max_attempts and retryable_error?(reason)
  end

  defp retryable_error?({:http_error, code, _body}) when code >= 500, do: true
  defp retryable_error?({:http_error, :timeout}), do: true
  defp retryable_error?({:http_error, :econnrefused}), do: true
  defp retryable_error?(_), do: false

  defp calculate_delay(attempt, %{base_delay: base_delay, max_delay: max_delay}) do
    delay = base_delay * :math.pow(2, attempt - 1) |> trunc()
    min(delay, max_delay)
  end
end
```

## Error Handling and Retry Logic

### Implementing Retry Logic

```elixir
defp do_with_retry(operation, retry_config, attempt \\ 1) do
  case operation.() do
    :ok -> :ok
    {:error, reason} = error ->
      if should_retry?(attempt, retry_config, reason) do
        delay = calculate_delay(attempt, retry_config)
        Logger.warning("Operation failed, retrying in #{delay}ms: #{inspect(reason)}")
        Process.sleep(delay)
        do_with_retry(operation, retry_config, attempt + 1)
      else
        error
      end
  end
end
```

### Error Classification

```elixir
defp classify_error(:timeout), do: :retryable
defp classify_error(:connection_refused), do: :retryable  
defp classify_error({:http_error, code}) when code >= 500, do: :retryable
defp classify_error({:http_error, code}) when code < 500, do: :permanent
defp classify_error(_), do: :permanent

defp should_retry?(attempt, %{max_attempts: max}, reason) do
  attempt < max and classify_error(reason) == :retryable
end
```

## Testing Custom Adapters

### Basic Test Structure

```elixir
defmodule MyApp.FileAdapterTest do
  use ExUnit.Case, async: true
  
  alias MyApp.FileAdapter
  
  @temp_dir System.tmp_dir!()
  
  describe "validate_opts/1" do
    test "validates required path" do
      assert {:error, "path is required"} = FileAdapter.validate_opts([])
    end
    
    test "validates valid configuration" do
      opts = [path: "/tmp/test.log", format: :json]
      assert {:ok, validated} = FileAdapter.validate_opts(opts)
      assert Keyword.get(validated, :path) == "/tmp/test.log"
      assert Keyword.get(validated, :format) == :json
    end
  end
  
  describe "deliver/2" do
    setup do
      # Create unique temp file for each test
      file_path = Path.join(@temp_dir, "test_#{:rand.uniform(10000)}.log")
      on_exit(fn -> File.rm(file_path) end)
      
      signal = %Jido.Signal{
        id: "test_123",
        type: "test.signal",
        source: "test",
        time: DateTime.utc_now(),
        data: %{message: "test"}
      }
      
      {:ok, file_path: file_path, signal: signal}
    end
    
    test "writes signal to file", %{file_path: file_path, signal: signal} do
      opts = [path: file_path, format: :json, append: true, create_dirs: true]
      
      assert :ok = FileAdapter.deliver(signal, opts)
      assert File.exists?(file_path)
      
      content = File.read!(file_path)
      assert String.contains?(content, signal.id)
      assert String.contains?(content, signal.type)
    end
    
    test "handles file write errors", %{signal: signal} do
      # Try to write to invalid path
      opts = [path: "/invalid/path/file.log", format: :json, append: true, create_dirs: false]
      
      assert {:error, _reason} = FileAdapter.deliver(signal, opts)
    end
  end
end
```

### Integration Testing

```elixir
defmodule MyApp.APIAdapterIntegrationTest do
  use ExUnit.Case
  
  alias MyApp.APIAdapter
  
  @moduletag :integration
  
  setup do
    # Start a mock HTTP server
    {:ok, server} = start_mock_server()
    
    on_exit(fn -> stop_mock_server(server) end)
    
    signal = %Jido.Signal{
      id: "test_123",
      type: "test.signal", 
      source: "test",
      time: DateTime.utc_now(),
      data: %{message: "integration test"}
    }
    
    {:ok, server: server, signal: signal}
  end
  
  test "delivers signal to mock API", %{server: server, signal: signal} do
    opts = [
      url: "http://localhost:#{server.port}/events",
      timeout: 5000,
      retry: %{max_attempts: 1, base_delay: 100, max_delay: 100}
    ]
    
    assert :ok = APIAdapter.deliver(signal, opts)
    
    # Verify the mock server received the request
    assert_receive {:http_request, %{body: body}}
    decoded = Jason.decode!(body)
    assert decoded["id"] == signal.id
  end
end
```

## Best Practices and Performance Considerations

### 1. Validation Performance

- Validate expensive operations once in `validate_opts/1`, not in `deliver/2`
- Cache compiled regexes and parsed configurations
- Use pattern matching for fast validation

```elixir
# Good: Validate and compile regex once
def validate_opts(opts) do
  pattern = Keyword.get(opts, :pattern, ".*")
  case Regex.compile(pattern) do
    {:ok, compiled_regex} -> 
      {:ok, Keyword.put(opts, :compiled_pattern, compiled_regex)}
    {:error, reason} -> 
      {:error, {:invalid_pattern, reason}}
  end
end

# Use compiled regex in deliver/2
def deliver(signal, opts) do
  compiled_pattern = Keyword.fetch!(opts, :compiled_pattern)
  # ... use compiled_pattern
end
```

### 2. Connection Pooling

For HTTP-based adapters, use connection pooling:

```elixir
# In your adapter's validate_opts/1
def validate_opts(opts) do
  # Configure HTTP client with connection pooling
  hackney_opts = [
    pool: :my_adapter_pool,
    max_connections: 100
  ]
  
  validated_opts = Keyword.put(opts, :http_opts, hackney_opts)
  {:ok, validated_opts}
end
```

### 3. Batching for Performance

Implement batching for high-volume scenarios:

```elixir
def deliver_batch(signals, opts) when is_list(signals) do
  batch_size = Keyword.get(opts, :batch_size, 100)
  
  signals
  |> Enum.chunk_every(batch_size)
  |> Enum.each(fn batch ->
    deliver_batch_chunk(batch, opts)
  end)
end
```

### 4. Telemetry and Monitoring

Add telemetry events for observability:

```elixir
def deliver(signal, opts) do
  start_time = System.monotonic_time()
  
  result = do_deliver(signal, opts)
  
  :telemetry.execute(
    [:my_app, :adapter, :deliver],
    %{duration: System.monotonic_time() - start_time},
    %{adapter: __MODULE__, result: result}
  )
  
  result
end
```

### 5. Circuit Breaker Pattern

For external service integrations:

```elixir
defmodule MyApp.CircuitBreaker do
  use GenServer
  
  def call(name, fun) do
    case GenServer.call(name, :state) do
      :open -> {:error, :circuit_open}
      :closed -> 
        case fun.() do
          :ok -> :ok
          {:error, _} = error ->
            GenServer.cast(name, :failure)
            error
        end
    end
  end
  
  # ... GenServer implementation
end
```

## Using Your Custom Adapter

Once implemented, use your custom adapter in routing configurations:

```elixir
# In your router definition
routes = [
  {"user.created", {MyApp.FileAdapter, [
    path: "/var/log/user-events.log",
    format: :json
  ]}},
  
  {"order.**", {MyApp.APIAdapter, [
    url: "https://api.example.com/orders",
    auth: %{type: :bearer, token: System.get_env("API_TOKEN")},
    retry: %{max_attempts: 5, base_delay: 1000, max_delay: 10000}
  ]}},
  
  {"audit.*", {MyApp.DatabaseAdapter, [
    repo: MyApp.Repo,
    table: "audit_logs"
  ]}}
]
```

## Conclusion

Custom dispatch adapters provide powerful extensibility for Jido.Signal. By following the patterns in this guide, you can create robust, performant adapters that integrate seamlessly with the signal system.

Key takeaways:

- Always validate configuration in `validate_opts/1` 
- Handle errors gracefully in `deliver/2`
- Implement retry logic for transient failures
- Use connection pooling and batching for performance
- Add comprehensive tests for both success and failure scenarios
- Include telemetry for monitoring and debugging

Your custom adapters can handle any delivery mechanism - from simple file writes to complex API integrations with authentication, retries, and circuit breakers.
