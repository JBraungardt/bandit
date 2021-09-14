defmodule HTTP2ProtocolTest do
  use ExUnit.Case, async: true

  use Bitwise
  use ServerHelpers

  setup :https_server

  describe "frame splitting / merging" do
    test "it should handle cases where the request arrives in small chunks", context do
      socket = SimpleH2Client.tls_client(context)

      # Send connection preface, client settings & ping frame one byte at a time
      ("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" <>
         <<0, 0, 0, 4, 0, 0, 0, 0, 0>> <> <<0, 0, 8, 6, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>)
      |> Stream.unfold(fn
        <<>> -> nil
        <<byte::binary-size(2), rest::binary>> -> {byte, rest}
      end)
      |> Enum.each(fn byte -> :ssl.send(socket, byte) end)

      assert :ssl.recv(socket, 9) == {:ok, <<0, 0, 0, 4, 0, 0, 0, 0, 0>>}
      assert :ssl.recv(socket, 9) == {:ok, <<0, 0, 0, 4, 1, 0, 0, 0, 0>>}
      assert :ssl.recv(socket, 17) == {:ok, <<0, 0, 8, 6, 1, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>}
    end

    test "it should handle cases where multiple frames arrive in the same packet", context do
      socket = SimpleH2Client.tls_client(context)

      # Send connection preface, client settings & ping frame all in one
      :ssl.send(
        socket,
        "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" <>
          <<0, 0, 0, 4, 0, 0, 0, 0, 0>> <> <<0, 0, 8, 6, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>
      )

      assert :ssl.recv(socket, 9) == {:ok, <<0, 0, 0, 4, 0, 0, 0, 0, 0>>}
      assert :ssl.recv(socket, 9) == {:ok, <<0, 0, 0, 4, 1, 0, 0, 0, 0>>}
      assert :ssl.recv(socket, 17) == {:ok, <<0, 0, 8, 6, 1, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>}
    end
  end

  describe "errors and unexpected frames" do
    @tag capture_log: true
    test "it should ignore unknown frame types", context do
      socket = SimpleH2Client.setup_connection(context)
      :ssl.send(socket, <<0, 0, 0, 254, 0, 0, 0, 0, 0>>)
      assert SimpleH2Client.connection_alive?(socket)
    end

    @tag capture_log: true
    test "it should shut down the connection gracefully when encountering a connection error",
         context do
      socket = SimpleH2Client.tls_client(context)
      SimpleH2Client.exchange_prefaces(socket)
      # Send a bogus SETTINGS frame
      :ssl.send(socket, <<0, 0, 0, 4, 0, 0, 0, 0, 1>>)
      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 1}
    end
  end

  describe "connection preface handling" do
    @tag capture_log: true
    test "closes with an error if the HTTP/2 connection preface is not present", context do
      socket = SimpleH2Client.tls_client(context)
      :ssl.send(socket, "PRI * NOPE/2.0\r\n\r\nSM\r\n\r\n")
      assert :ssl.recv(socket, 0) == {:error, :closed}
    end

    test "the server should send a SETTINGS frame at start of the connection", context do
      socket = SimpleH2Client.tls_client(context)
      :ssl.send(socket, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
      assert :ssl.recv(socket, 9) == {:ok, <<0, 0, 0, 4, 0, 0, 0, 0, 0>>}
    end
  end

  describe "DATA frames" do
    test "sends end of stream when there is a single data frame", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :get, "/body_response", context.port)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}
    end

    def body_response(conn) do
      conn |> send_resp(200, "OK")
    end

    test "sends multiple DATA frames with last one end of stream when chunking", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :get, "/chunk_response", context.port)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, false, "OK"}
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, false, "DOKEE"}
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, ""}
    end

    def chunk_response(conn) do
      conn
      |> send_chunked(200)
      |> chunk("OK")
      |> elem(1)
      |> chunk("DOKEE")
      |> elem(1)
    end

    test "reads a zero byte body if none is sent", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :get, "/echo", context.port)

      # A zero byte body being written will cause end_stream to be set on the header frame
      assert SimpleH2Client.successful_response?(socket, 1, true)
    end

    def echo(conn) do
      {:ok, body, conn} = read_body(conn)
      conn |> send_resp(200, body)
    end

    @tag capture_log: true
    test "rejects DATA frames received on an idle stream", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_body(socket, 1, true, "OK")

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 1}
    end

    test "reads a one frame body if one frame is sent", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :post, "/echo", context.port)
      SimpleH2Client.send_body(socket, 1, true, "OK")

      {:ok, 0, _} = SimpleH2Client.recv_window_update(socket)
      {:ok, 1, _} = SimpleH2Client.recv_window_update(socket)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}
    end

    test "reads a multi frame body if many frames are sent", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :post, "/echo", context.port)
      SimpleH2Client.send_body(socket, 1, false, "OK")
      SimpleH2Client.send_body(socket, 1, true, "OK")

      {:ok, 0, _} = SimpleH2Client.recv_window_update(socket)
      {:ok, 1, _} = SimpleH2Client.recv_window_update(socket)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OKOK"}
    end

    @tag capture_log: true
    test "rejects DATA frames received on a remote closed stream", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :get, "/echo", context.port)
      SimpleH2Client.send_body(socket, 1, true, "OK")

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 1, 1}
    end

    @tag capture_log: true
    test "rejects DATA frames received on a zero stream id", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_body(socket, 0, true, "OK")

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 1}
    end

    @tag capture_log: true
    test "rejects DATA frames received on an invalid stream id", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_body(socket, 2, true, "OK")

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 1}
    end
  end

  describe "HEADERS frames" do
    test "sends end of stream headers when there is no body", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :get, "/no_body_response", context.port)

      assert {:ok, 1, true,
              [{":status", "200"}, {"cache-control", "max-age=0, private, must-revalidate"}],
              _ctx} = SimpleH2Client.recv_headers(socket)
    end

    def no_body_response(conn) do
      conn |> send_resp(200, <<>>)
    end

    test "sends non-end of stream headers when there is a body", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :get, "/body_response", context.port)

      assert {:ok, 1, false,
              [{":status", "200"}, {"cache-control", "max-age=0, private, must-revalidate"}],
              _ctx} = SimpleH2Client.recv_headers(socket)

      assert(SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"})
    end

    test "accepts well-formed headers without padding or priority", context do
      socket = SimpleH2Client.setup_connection(context)
      headers = headers_for_header_read_test(context)

      # Send unadorned headers
      :ssl.send(socket, [<<0, 0, byte_size(headers), 1, 0x05, 0, 0, 0, 1>>, headers])

      assert {:ok, 1, false,
              [{":status", "200"}, {"cache-control", "max-age=0, private, must-revalidate"}],
              _ctx} = SimpleH2Client.recv_headers(socket)

      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}
    end

    test "accepts well-formed headers with priority", context do
      socket = SimpleH2Client.setup_connection(context)
      headers = headers_for_header_read_test(context)

      # Send headers with priority
      :ssl.send(socket, [
        <<0, 0, byte_size(headers) + 5, 1, 0x25, 0, 0, 0, 1>>,
        <<0, 0, 0, 1, 5>>,
        headers
      ])

      assert {:ok, 1, false,
              [{":status", "200"}, {"cache-control", "max-age=0, private, must-revalidate"}],
              _ctx} = SimpleH2Client.recv_headers(socket)

      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}
    end

    test "accepts well-formed headers with padding", context do
      socket = SimpleH2Client.setup_connection(context)
      headers = headers_for_header_read_test(context)

      # Send headers with padding
      :ssl.send(socket, [
        <<0, 0, byte_size(headers) + 5, 1, 0x0D, 0, 0, 0, 1>>,
        <<4>>,
        headers,
        <<1, 2, 3, 4>>
      ])

      assert {:ok, 1, false,
              [{":status", "200"}, {"cache-control", "max-age=0, private, must-revalidate"}],
              _ctx} = SimpleH2Client.recv_headers(socket)

      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}
    end

    test "accepts well-formed headers with padding and priority", context do
      socket = SimpleH2Client.setup_connection(context)
      headers = headers_for_header_read_test(context)

      # Send headers with padding and priority
      :ssl.send(socket, [
        <<0, 0, byte_size(headers) + 10, 1, 0x2D, 0, 0, 0, 1>>,
        <<4, 0, 0, 0, 0, 1>>,
        headers,
        <<1, 2, 3, 4>>
      ])

      assert {:ok, 1, false,
              [{":status", "200"}, {"cache-control", "max-age=0, private, must-revalidate"}],
              _ctx} = SimpleH2Client.recv_headers(socket)

      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}
    end

    def headers_for_header_read_test(context) do
      headers = [
        {":method", "HEAD"},
        {":path", "/header_read_test"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {"x-request-header", "Request"}
      ]

      ctx = HPack.Table.new(4096)
      {:ok, _, headers} = HPack.encode(headers, ctx)
      headers
    end

    def header_read_test(conn) do
      assert get_req_header(conn, "x-request-header") == ["Request"]

      conn |> send_resp(200, "OK")
    end

    @tag capture_log: true
    test "closes with an error when receiving a zero stream ID",
         context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 0, :get, "/echo", context.port)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 1}
    end

    @tag capture_log: true
    test "closes with an error when receiving an even stream ID",
         context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 2, :get, "/echo", context.port)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 1}
    end

    @tag capture_log: true
    test "closes with an error when receiving a stream ID we've already seen",
         context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 99, :get, "/echo", context.port)
      SimpleH2Client.send_simple_headers(socket, 99, :get, "/echo", context.port)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 99, 1}
    end

    @tag capture_log: true
    test "closes with an error on a header frame with undecompressable header block", context do
      socket = SimpleH2Client.setup_connection(context)

      :ssl.send(socket, <<0, 0, 11, 1, 0x2C, 0, 0, 0, 1, 2, 1::1, 12::31, 34, 1, 2, 3, 4, 5>>)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 9}
    end

    test "returns a stream error if sent headers with uppercase names", context do
      socket = SimpleH2Client.setup_connection(context)

      # HPack won't encode capitalized headers so take example from H2Spec
      headers =
        <<130, 135, 68, 137, 98, 114, 209, 65, 226, 240, 123, 40, 147, 65, 139, 8, 157, 92, 11,
          129, 112, 220, 109, 199, 26, 127, 64, 6, 88, 45, 84, 69, 83, 84, 2, 111, 107>>

      :ssl.send(socket, [<<byte_size(headers)::24, 1::8, 5::8, 0::1, 1::31>>, headers])

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end

    test "returns a stream error if sent headers with invalid pseudo headers", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "HEAD"},
        {":path", "/"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {":bogus", "bogus"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end

    test "returns a stream error if sent headers with response pseudo headers", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "HEAD"},
        {":path", "/"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {":status", "200"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end

    test "returns a stream error if pseudo headers appear after regular ones", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "HEAD"},
        {":path", "/"},
        {":scheme", "https"},
        {"regular-header", "boring"},
        {":authority", "localhost:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end

    test "returns an error if (almost) any hop-by-hop headers are present", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "HEAD"},
        {":path", "/"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {"connection", "close"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end

    test "accepts TE header with a value of trailer", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "HEAD"},
        {":path", "/no_body_response"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {"te", "trailers"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.successful_response?(socket, 1, true)
    end

    test "returns an error if TE header is present with a value other than trailers", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "HEAD"},
        {":path", "/"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {"te", "trailers, deflate"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end

    test "returns a stream error if :method pseudo header is missing", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":path", "/"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end

    test "returns a stream error if multiple :method pseudo headers are received", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "HEAD"},
        {":method", "HEAD"},
        {":path", "/"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end

    test "returns a stream error if :scheme pseudo header is missing", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "HEAD"},
        {":path", "/"},
        {":authority", "localhost:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end

    test "returns a stream error if multiple :scheme pseudo headers are received", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "HEAD"},
        {":path", "/"},
        {":scheme", "https"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end

    test "returns a stream error if :path pseudo header is missing", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "HEAD"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end

    test "returns a stream error if multiple :path pseudo headers are received", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "HEAD"},
        {":path", "/"},
        {":path", "/"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end

    test "returns a stream error if :path pseudo headers is empty", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "HEAD"},
        {":path", ""},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end

    test "combines Cookie headers per RFC7540§8.1.2.5", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/cookie_check"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {"cookie", "a=b"},
        {"cookie", "c=d"},
        {"cookie", "e=f"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}
    end

    def cookie_check(conn) do
      assert get_req_header(conn, "cookie") == ["a=b; c=d; e=f"]

      conn |> send_resp(200, "OK")
    end

    test "breaks Cookie headers up per RFC7540§8.1.2.5", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/cookie_write_check"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert {:ok, 1, false,
              [
                {":status", "200"},
                {"cache-control", "max-age=0, private, must-revalidate"},
                {"cookie", "a=b"},
                {"cookie", "c=d"},
                {"cookie", "e=f"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)

      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}
    end

    def cookie_write_check(conn) do
      conn |> put_resp_header("cookie", "a=b; c=d; e=f") |> send_resp(200, "OK")
    end
  end

  describe "PRIORITY frames" do
    test "receives PRIORITY frames without complaint (and does nothing)", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_priority(socket, 1, 3, 4)

      assert SimpleH2Client.connection_alive?(socket)
    end

    test "rejects PRIORITY frames which depend on itself", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_priority(socket, 1, 1, 4)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
      assert SimpleH2Client.connection_alive?(socket)
    end
  end

  describe "RST_STREAM frames" do
    @tag capture_log: true
    test "sends RST_FRAME with no error if stream task ends without closed stream", context do
      socket = SimpleH2Client.setup_connection(context)

      # Send headers with end_stream bit cleared
      SimpleH2Client.send_simple_headers(socket, 1, :post, "/body_response", context.port)
      SimpleH2Client.recv_headers(socket)
      SimpleH2Client.recv_body(socket)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 0}
      assert SimpleH2Client.connection_alive?(socket)
    end

    @tag capture_log: true
    test "sends RST_FRAME with error if stream task crashes", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :get, "/crasher", context.port)
      SimpleH2Client.recv_headers(socket)
      SimpleH2Client.recv_body(socket)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 2}
      assert SimpleH2Client.connection_alive?(socket)
    end

    def crasher(conn) do
      conn
      |> send_chunked(200)
      |> chunk("OK")

      raise "boom"
    end

    @tag capture_log: true
    test "rejects RST_STREAM frames received on an idle stream", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_rst_stream(socket, 1, 0)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 1}
    end

    test "shuts down the stream task on receipt of an RST_STREAM frame", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :get, "/sleeper", context.port)
      SimpleH2Client.recv_headers(socket)
      {:ok, 1, false, "OK"} = SimpleH2Client.recv_body(socket)

      assert Process.whereis(:sleeper) |> Process.alive?()

      SimpleH2Client.send_rst_stream(socket, 1, 0)

      Process.sleep(100)

      assert Process.whereis(:sleeper) == nil
      assert SimpleH2Client.connection_alive?(socket)
    end

    def sleeper(conn) do
      Process.register(self(), :sleeper)

      conn
      |> send_chunked(200)
      |> chunk("OK")

      Process.sleep(:infinity)
    end
  end

  describe "SETTINGS frames" do
    test "the server should acknowledge a client's SETTINGS frames", context do
      socket = SimpleH2Client.tls_client(context)
      SimpleH2Client.exchange_prefaces(socket)
      :ssl.send(socket, <<0, 0, 0, 4, 0, 0, 0, 0, 0>>)
      assert :ssl.recv(socket, 9) == {:ok, <<0, 0, 0, 4, 1, 0, 0, 0, 0>>}
    end
  end

  describe "PUSH_PROMISE frames" do
    @tag capture_log: true
    test "the server should reject any received PUSH_PROMISE frames", context do
      socket = SimpleH2Client.tls_client(context)
      SimpleH2Client.exchange_prefaces(socket)
      :ssl.send(socket, <<0, 0, 7, 5, 0, 0, 0, 0, 1, 0, 0, 0, 3, 1, 2, 3>>)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 1}
    end
  end

  describe "PING frames" do
    test "the server should acknowledge a client's PING frames", context do
      socket = SimpleH2Client.setup_connection(context)
      :ssl.send(socket, <<0, 0, 8, 6, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>)
      assert :ssl.recv(socket, 17) == {:ok, <<0, 0, 8, 6, 1, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>}
    end
  end

  describe "GOAWAY frames" do
    test "the server should send a GOAWAY frame when shutting down", context do
      socket = SimpleH2Client.setup_connection(context)

      assert SimpleH2Client.connection_alive?(socket)

      Process.sleep(100)

      ThousandIsland.stop(context.server_pid)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 0}
    end

    test "the server should close the connection upon receipt of a GOAWAY frame", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_goaway(socket, 0, 0)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 0}
    end

    test "the server should return the last received stream id in the GOAWAY frame", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 99, :get, "/echo", context.port)
      SimpleH2Client.send_goaway(socket, 0, 0)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 99, 0}
    end
  end

  describe "WINDOW_UPDATE frames (upload direction)" do
    test "issues a large receive window update on first uploaded DATA frame", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :post, "/echo", context.port)
      SimpleH2Client.send_body(socket, 1, true, "OK")

      expected_adjustment = (1 <<< 31) - 1 - 65_535 + 2

      {:ok, 0, ^expected_adjustment} = SimpleH2Client.recv_window_update(socket)
      {:ok, 1, ^expected_adjustment} = SimpleH2Client.recv_window_update(socket)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}
    end

    test "manages connection and stream receive windows separately", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :post, "/echo", context.port)
      SimpleH2Client.send_body(socket, 1, true, "OK")

      expected_adjustment = (1 <<< 31) - 1 - 65_535 + 2

      {:ok, 0, ^expected_adjustment} = SimpleH2Client.recv_window_update(socket)
      {:ok, 1, ^expected_adjustment} = SimpleH2Client.recv_window_update(socket)

      assert {:ok, 1, false, [{":status", "200"} | _], ctx} = SimpleH2Client.recv_headers(socket)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}

      SimpleH2Client.send_simple_headers(socket, 3, :post, "/echo", context.port)
      SimpleH2Client.send_body(socket, 3, true, "OK")

      expected_adjustment = (1 <<< 31) - 1 - 65_535 + 2

      # We should only see a stream update here
      {:ok, 3, ^expected_adjustment} = SimpleH2Client.recv_window_update(socket)

      assert SimpleH2Client.successful_response?(socket, 3, false, ctx)
      assert SimpleH2Client.recv_body(socket) == {:ok, 3, true, "OK"}
    end

    test "does not issue a subsequent update until receive window goes below 2^30", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :post, "/large_post", context.port)

      window = 65_535

      # Send a single byte to get the window moved up and ensure we see a window update
      SimpleH2Client.send_body(socket, 1, false, "a")
      window = window - 1

      {:ok, 0, adjustment} = SimpleH2Client.recv_window_update(socket)
      {:ok, 1, ^adjustment} = SimpleH2Client.recv_window_update(socket)

      window = window + adjustment
      assert window == (1 <<< 31) - 1

      # Send 2^15 - 1 chunks of 2^15 bytes to end up just shy of expecting a
      # window update (we expect one when our window goes below 2^30).
      iters = (1 <<< 15) - 1
      chunk = String.duplicate("a", 1 <<< 15)

      for _n <- 1..iters do
        SimpleH2Client.send_body(socket, 1, false, chunk)
      end

      # Adjust our window down for the frames we just sent
      window = window - iters * byte_size(chunk)

      assert window >= 1 <<< 30

      # Ensure we have not received a window update by pinging
      assert SimpleH2Client.connection_alive?(socket)

      # Now send one more chunk and update our window size
      SimpleH2Client.send_body(socket, 1, true, chunk)
      window = window - byte_size(chunk)

      # We should now be below 2^30 and so we expect an update
      assert window < 1 <<< 30
      {:ok, 0, adjustment} = SimpleH2Client.recv_window_update(socket)
      {:ok, 1, ^adjustment} = SimpleH2Client.recv_window_update(socket)
      window = window + adjustment
      assert window == (1 <<< 31) - 1

      assert SimpleH2Client.successful_response?(socket, 1, false)

      assert SimpleH2Client.recv_body(socket) ==
               {:ok, 1, true, "#{1 + (iters + 1) * byte_size(chunk)}"}
    end

    def large_post(conn) do
      do_large_post(conn, 0)
    end

    defp do_large_post(conn, size) do
      case read_body(conn) do
        {:ok, body, conn} -> conn |> send_resp(200, "#{size + byte_size(body)}")
        {:more, body, conn} -> do_large_post(conn, size + byte_size(body))
      end
    end

    test "properly handles cases where client misbehaves and overruns the window", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :post, "/echo", context.port)
      SimpleH2Client.send_window_update(socket, 0, 1_000_000)
      SimpleH2Client.send_window_update(socket, 1, 1_000_000)

      # Send more than the open window (65_535 initially) to overrun on purpose
      body = String.duplicate("a", 100_000)
      SimpleH2Client.send_body(socket, 1, true, body)

      expected_adjustment = (1 <<< 31) - 1

      {:ok, 0, ^expected_adjustment} = SimpleH2Client.recv_window_update(socket)
      {:ok, 1, ^expected_adjustment} = SimpleH2Client.recv_window_update(socket)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, body}
    end
  end

  describe "WINDOW_UPDATE frames (download direction)" do
    test "respects the remaining space in the connection's send window", context do
      socket = SimpleH2Client.setup_connection(context)

      data = String.duplicate("a", 65_535 + 100 + 1)
      SimpleH2Client.send_simple_headers(socket, 1, :post, "/echo", context.port)

      # Give ourselves lots of room on the stream
      SimpleH2Client.send_window_update(socket, 1, 1_000_000)

      SimpleH2Client.send_body(socket, 1, true, data)
      assert {:ok, 0, _} = SimpleH2Client.recv_window_update(socket)
      assert {:ok, 1, _} = SimpleH2Client.recv_window_update(socket)
      assert SimpleH2Client.successful_response?(socket, 1, false)

      # Expect 65_535 bytes as that is our initial connection window
      expected_data = String.duplicate("a", 65_535)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, false, expected_data}

      # Grow the connection window by 100 and observe that we get 100 more bytes
      SimpleH2Client.send_window_update(socket, 0, 100)
      expected_data = String.duplicate("a", 100)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, false, expected_data}

      # Grow the connection window by another 100 and observe that we get the rest of the response
      # Also note that we receive end_of_stream here
      SimpleH2Client.send_window_update(socket, 0, 100)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "a"}
    end

    test "respects the remaining space in the stream's send window", context do
      socket = SimpleH2Client.setup_connection(context)

      # Give ourselves lots of room on the connection
      SimpleH2Client.send_window_update(socket, 0, 1_000_000)

      data = String.duplicate("a", 65_535 + 100 + 1)
      SimpleH2Client.send_simple_headers(socket, 1, :post, "/echo", context.port)
      SimpleH2Client.send_body(socket, 1, true, data)
      assert {:ok, 0, _} = SimpleH2Client.recv_window_update(socket)
      assert {:ok, 1, _} = SimpleH2Client.recv_window_update(socket)
      assert SimpleH2Client.successful_response?(socket, 1, false)

      # Expect 65_535 bytes as that is our initial stream window
      expected_data = String.duplicate("a", 65_535)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, false, expected_data}

      # Grow the stream window by 100 and observe that we get 100 more bytes
      SimpleH2Client.send_window_update(socket, 1, 100)
      expected_data = String.duplicate("a", 100)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, false, expected_data}

      # Grow the stream window by another 100 and observe that we get the rest of the response
      # Also note that we receive end_of_stream here
      SimpleH2Client.send_window_update(socket, 1, 100)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "a"}
    end

    test "respects both stream and connection windows in complex scenarios", context do
      socket = SimpleH2Client.setup_connection(context)

      data = String.duplicate("a", 65_535 + 100)
      SimpleH2Client.send_simple_headers(socket, 1, :post, "/echo", context.port)

      SimpleH2Client.send_body(socket, 1, true, data)
      assert {:ok, 0, _} = SimpleH2Client.recv_window_update(socket)
      assert {:ok, 1, _} = SimpleH2Client.recv_window_update(socket)

      assert {:ok, 1, false, [{":status", "200"} | _], ctx} = SimpleH2Client.recv_headers(socket)

      # Expect 65_535 bytes as that is our initial connection window
      expected_data = String.duplicate("a", 65_535)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, false, expected_data}

      # Start a second stream and observe that it gets blocked right away
      SimpleH2Client.send_simple_headers(socket, 3, :post, "/echo", context.port)

      SimpleH2Client.send_body(socket, 3, true, data)
      assert {:ok, 3, _} = SimpleH2Client.recv_window_update(socket)
      assert SimpleH2Client.successful_response?(socket, 3, false, ctx)

      # Grow the connection window by 65_535 and observe that we get bytes on 3
      # since 1 is blocked on its stream window
      SimpleH2Client.send_window_update(socket, 0, 65_535)
      expected_data = String.duplicate("a", 65_535)
      assert SimpleH2Client.recv_body(socket) == {:ok, 3, false, expected_data}

      # Grow the stream windows such that we expect to see 100 bytes from 1 and 50 bytes from
      # 3 (note that 1 is queued at a higher priority than 3 due to FIFO ordering) Also note that
      # we receive end_of_stream on stream 1 here
      SimpleH2Client.send_window_update(socket, 3, 100)
      SimpleH2Client.send_window_update(socket, 1, 100)
      SimpleH2Client.send_window_update(socket, 0, 150)
      expected_data = String.duplicate("a", 100)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, expected_data}
      expected_data = String.duplicate("a", 50)
      assert SimpleH2Client.recv_body(socket) == {:ok, 3, false, expected_data}

      # Finally grow our connection window and verify we get the last of stream 3
      SimpleH2Client.send_window_update(socket, 0, 50)
      assert SimpleH2Client.recv_body(socket) == {:ok, 3, true, expected_data}
    end

    @tag :skip
    test "updates stream send window based on SETTINGS frames", _context do
    end
  end

  describe "CONTINUATION frames" do
    test "accumulates header fragments over multiple CONTINUATION frames", context do
      socket = SimpleH2Client.setup_connection(context)

      <<header1::binary-size(20), header2::binary-size(20), header3::binary>> =
        headers_for_header_read_test(context)

      :ssl.send(socket, [<<0, 0, byte_size(header1), 1, 0x01, 0, 0, 0, 1>>, header1])
      :ssl.send(socket, [<<0, 0, byte_size(header2), 9, 0x00, 0, 0, 0, 1>>, header2])
      :ssl.send(socket, [<<0, 0, byte_size(header3), 9, 0x04, 0, 0, 0, 1>>, header3])

      assert {:ok, 1, false,
              [{":status", "200"}, {"cache-control", "max-age=0, private, must-revalidate"}],
              _ctx} = SimpleH2Client.recv_headers(socket)

      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}
      assert SimpleH2Client.connection_alive?(socket)
    end

    @tag capture_log: true
    test "rejects non-CONTINUATION frames received when end_headers is false", context do
      socket = SimpleH2Client.setup_connection(context)

      <<header1::binary-size(20), _header2::binary-size(20), _header3::binary>> =
        headers_for_header_read_test(context)

      :ssl.send(socket, [<<0, 0, byte_size(header1), 1, 0x01, 0, 0, 0, 1>>, header1])
      :ssl.send(socket, <<0, 0, 8, 6, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 1}
    end

    @tag capture_log: true
    test "rejects non-CONTINUATION frames received when from other streams", context do
      socket = SimpleH2Client.setup_connection(context)

      <<header1::binary-size(20), header2::binary-size(20), _header3::binary>> =
        headers_for_header_read_test(context)

      :ssl.send(socket, [<<0, 0, byte_size(header1), 1, 0x01, 0, 0, 0, 1>>, header1])
      :ssl.send(socket, [<<0, 0, byte_size(header2), 9, 0x00, 0, 0, 0, 2>>, header2])

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 1}
    end

    @tag capture_log: true
    test "rejects CONTINUATION frames received when not expected", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = headers_for_header_read_test(context)

      :ssl.send(socket, [<<0, 0, byte_size(headers), 9, 0x04, 0, 0, 0, 1>>, headers])

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 1}
    end
  end
end
