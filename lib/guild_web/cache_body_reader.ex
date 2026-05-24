defmodule GuildWeb.CacheBodyReader do
  @moduledoc """
  A custom body reader for Plug.Parsers that caches the raw request body
  in conn.private[:raw_body] so it can be used for HMAC signature verification.
  """

  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        conn = Plug.Conn.put_private(conn, :raw_body, body)
        {:ok, body, conn}

      {:more, partial, conn} ->
        conn = Plug.Conn.put_private(conn, :raw_body, partial)
        {:more, partial, conn}

      error ->
        error
    end
  end
end
