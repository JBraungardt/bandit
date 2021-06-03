defmodule Bandit.HTTP2.Adapter do
  @moduledoc false

  defstruct connection: nil, stream_id: nil

  @behaviour Plug.Conn.Adapter

  @impl Plug.Conn.Adapter
  def read_req_body(%__MODULE__{}, _opts) do
    # TODO receive as needed
    {:error, :not_supported}
  end

  @impl Plug.Conn.Adapter
  def send_resp(%__MODULE__{} = adapter, status, headers, body) do
    if byte_size(body) == 0 do
      send_headers(adapter, status, headers, true)
    else
      send_headers(adapter, status, headers, false)
      send_data(adapter, body, true)
    end

    {:ok, nil, adapter}
  end

  @impl Plug.Conn.Adapter
  def send_file(%__MODULE__{} = adapter, status, headers, path, offset, length) do
    %File.Stat{type: :regular, size: size} = File.stat!(path)
    length = if length == :all, do: size - offset, else: length

    cond do
      offset + length == size && offset == 0 ->
        send_chunked(adapter, status, headers)

        _ =
          File.stream!(path, [], 2048)
          |> Enum.reduce(adapter, fn chunk, adapter ->
            chunk(adapter, chunk)
          end)

        chunk(adapter, "")
        {:ok, nil, adapter}

      offset + length < size ->
        with {:ok, fd} <- :file.open(path, [:raw, :binary]),
             {:ok, data} <- :file.pread(fd, offset, length) do
          send_headers(adapter, status, headers, false)
          send_data(adapter, data, true)
          {:ok, nil, adapter}
        end

      true ->
        {:error,
         "Cannot read #{length} bytes starting at #{offset} as #{path} is only #{size} octets in length"}
    end
  end

  @impl Plug.Conn.Adapter
  def send_chunked(%__MODULE__{} = adapter, status, headers) do
    send_headers(adapter, status, headers, false)
    {:ok, nil, adapter}
  end

  @impl Plug.Conn.Adapter
  def chunk(%__MODULE__{} = adapter, chunk) do
    # Sending an empty chunk implicitly ends the stream. This is a bit of an undefined corner of
    # the Plug.Conn.Adapter behaviour (see https://github.com/elixir-plug/plug/pull/535 for
    # details) and closing the stream here carves closest to the underlying HTTP/1.1 behaviour
    # (RFC7230§4.1). The whole notion of chunked encoding is moot in HTTP/2 anyway (RFC7540§8.1)
    # so this entire section of the API is a bit slanty regardless.
    send_data(adapter, chunk, chunk == <<>>)
    :ok
  end

  @impl Plug.Conn.Adapter
  def inform(_req, _status, _headers) do
    # TODO send headers
    {:error, :not_supported}
  end

  @impl Plug.Conn.Adapter
  def push(_req, _path, _headers) do
    # TODO send PUSH_PROMISE
    {:error, :not_supported}
  end

  @impl Plug.Conn.Adapter
  def get_peer_data(%__MODULE__{}) do
    # TODO ask connection
    nil
  end

  @impl Plug.Conn.Adapter
  def get_http_protocol(%__MODULE__{}), do: :"HTTP/2"

  defp send_headers(adapter, status, headers, end_stream) do
    headers = [{":status", to_string(status)} | headers]

    GenServer.call(adapter.connection, {:send_headers, adapter.stream_id, headers, end_stream})
  end

  defp send_data(adapter, data, end_stream) do
    GenServer.call(adapter.connection, {:send_data, adapter.stream_id, data, end_stream})
  end
end
