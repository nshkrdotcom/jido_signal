defmodule Jido.Signal.Bus.Stream do
  @moduledoc """
  Provides streaming functionality for the signal bus.

  This module contains functions for filtering, processing, and publishing
  signals through the bus streaming interface. It supports operations like
  filtering signals by type pattern and timestamp, as well as publishing
  signals to subscribers.
  """

  alias Jido.Signal
  alias Jido.Signal.Bus.RecordedSignal
  alias Jido.Signal.Bus.State, as: BusState
  alias Jido.Signal.Dispatch
  alias Jido.Signal.ID
  alias Jido.Signal.Router

  require Logger

  @doc """
  Filters signals from the bus state's log based on type pattern and timestamp.
  The type pattern is used for matching against the signal's type field.
  """
  @spec filter(BusState.t(), String.t(), integer() | nil, keyword()) ::
          {:ok, list(Jido.Signal.Bus.RecordedSignal.t())} | {:error, atom()}
  def filter(state, type_pattern, start_timestamp \\ nil, opts \\ [])

  def filter(%BusState{} = state, type_pattern, opts, []) when is_list(opts) do
    filter(state, type_pattern, nil, opts)
  end

  def filter(%BusState{} = state, type_pattern, start_timestamp, opts) do
    batch_size = Keyword.get(opts, :batch_size, 1_000)
    correlation_id = Keyword.get(opts, :correlation_id)

    entries =
      state.log
      |> Enum.sort_by(fn {log_id, _signal} -> log_id end)
      |> maybe_filter_by_timestamp(start_timestamp)
      |> maybe_filter_by_correlation_id(correlation_id)

    case Router.Validator.validate_path(type_pattern) do
      {:ok, _} ->
        filtered_signals =
          entries
          |> Enum.filter(fn {_log_id, signal} -> Router.matches?(signal.type, type_pattern) end)
          |> Enum.take(batch_size)
          |> Enum.map(&to_recorded_signal/1)

        {:ok, filtered_signals}

      {:error, reason} ->
        Logger.error("Invalid pattern: #{inspect(reason)}")
        {:error, :invalid_pattern}
    end
  rescue
    error ->
      Logger.error("Error filtering signals: #{inspect(error)}")
      {:error, :filter_failed}
  end

  defp maybe_filter_by_timestamp(entries, start_timestamp) when is_integer(start_timestamp) do
    Enum.filter(entries, fn {log_id, signal} ->
      timestamp_from_log_or_signal(log_id, signal) > start_timestamp
    end)
  end

  defp maybe_filter_by_timestamp(entries, _start_timestamp), do: entries

  defp maybe_filter_by_correlation_id(entries, nil), do: entries

  defp maybe_filter_by_correlation_id(entries, correlation_id) do
    Enum.filter(entries, fn {_log_id, signal} ->
      correlation_id_from_signal(signal) == correlation_id
    end)
  end

  defp to_recorded_signal({log_id, signal}) do
    %RecordedSignal{
      id: log_id,
      type: signal.type,
      created_at: created_at_from_log_or_signal(log_id, signal),
      signal: signal
    }
  end

  defp created_at_from_log_or_signal(log_id, signal) do
    case extract_log_timestamp(log_id) do
      {:ok, timestamp} ->
        DateTime.from_unix!(timestamp, :millisecond)

      :error ->
        case parse_signal_time(signal) do
          {:ok, datetime} -> datetime
          :error -> DateTime.utc_now()
        end
    end
  end

  defp timestamp_from_log_or_signal(log_id, signal) do
    case extract_log_timestamp(log_id) do
      {:ok, timestamp} ->
        timestamp

      :error ->
        case parse_signal_time(signal) do
          {:ok, datetime} -> DateTime.to_unix(datetime, :millisecond)
          :error -> 0
        end
    end
  end

  defp extract_log_timestamp(log_id) when is_binary(log_id) do
    {:ok, ID.extract_timestamp(log_id)}
  rescue
    _ -> :error
  end

  defp extract_log_timestamp(_log_id), do: :error

  defp parse_signal_time(%Signal{time: time}) when is_binary(time) do
    case DateTime.from_iso8601(time) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> :error
    end
  end

  defp parse_signal_time(_signal), do: :error

  defp correlation_id_from_signal(%Signal{extensions: extensions}) when is_map(extensions) do
    Map.get(extensions, "correlation_id") ||
      Map.get(extensions, :correlation_id) ||
      correlation_extension_id(extensions)
  end

  defp correlation_id_from_signal(_signal), do: nil

  defp correlation_extension_id(extensions) do
    case Map.get(extensions, "correlation") || Map.get(extensions, :correlation) do
      correlation when is_map(correlation) ->
        Map.get(correlation, "correlation_id") ||
          Map.get(correlation, :correlation_id) ||
          Map.get(correlation, "trace_id") ||
          Map.get(correlation, :trace_id)

      _ ->
        nil
    end
  end

  @doc """
  Publishes signals to the bus, recording them and routing them to subscribers.
  Each signal is routed based on its own type field.
  Only accepts proper Jido.Signal structs to ensure system integrity.
  Signals are recorded and routed in the exact order they are received.
  """
  @spec publish(BusState.t(), list(Signal.t())) :: {:ok, BusState.t()} | {:error, atom()}
  def publish(%BusState{} = _state, []) do
    {:error, :empty_signal_list}
  end

  def publish(%BusState{} = state, signals) when is_list(signals) do
    with :ok <- validate_signals(signals),
         {:ok, new_state, _new_signals} <- BusState.append_signals(state, signals) do
      route_signals_to_subscribers(signals, new_state.subscriptions)
      {:ok, new_state}
    end
  end

  defp route_signals_to_subscribers(signals, subscriptions) do
    Enum.each(signals, fn signal ->
      dispatch_to_matching_subscriptions(signal, subscriptions)
    end)
  end

  defp dispatch_to_matching_subscriptions(signal, subscriptions) do
    Enum.each(subscriptions, fn {_id, subscription} ->
      if Router.matches?(signal.type, subscription.path) do
        Dispatch.dispatch(signal, subscription.dispatch)
      end
    end)
  end

  @doc """
  Acknowledges a signal for a given subscription.
  """
  @spec ack(BusState.t(), String.t(), Signal.t()) :: {:ok, BusState.t()} | {:error, atom()}
  def ack(%BusState{} = state, subscription_id, %Signal{} = signal) do
    case BusState.get_subscription(state, subscription_id) do
      nil ->
        {:error, :subscription_not_found}

      subscription ->
        if subscription.persistent? && subscription.persistence_pid do
          # Send ack to persistent subscription process
          GenServer.cast(subscription.persistence_pid, {:ack, signal.id})
          {:ok, state}
        else
          # Non-persistent subscriptions don't need acks
          {:ok, state}
        end
    end
  end

  @doc """
  Truncates the signal log to the specified maximum size.
  Keeps the most recent signals and discards older ones.
  """
  @spec truncate(BusState.t(), non_neg_integer()) :: {:ok, BusState.t()}
  def truncate(%BusState{} = state, max_size) when is_integer(max_size) and max_size >= 0 do
    BusState.truncate_log(state, max_size)
  end

  @doc """
  Clears all signals from the log.
  """
  @spec clear(BusState.t()) :: {:ok, BusState.t()}
  def clear(%BusState{} = state) do
    BusState.clear_log(state)
  end

  @spec validate_signals(list(term())) :: :ok | {:error, term()}
  defp validate_signals(signals) do
    invalid_signals =
      Enum.reject(signals, fn signal ->
        is_struct(signal, Signal)
      end)

    case invalid_signals do
      [] -> :ok
      _ -> {:error, :invalid_signals}
    end
  end
end
