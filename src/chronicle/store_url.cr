require "uri"

# Store URL parsing. Ported from activegraph activegraph/store/url.py
# (revision 8aedb1866cf5dce056af97529152ffd6f468a1ed).
#
# URLs follow SQLAlchemy conventions:
#   sqlite:///absolute/path/to/run.db   (three slashes = relative)
#   sqlite:////abs/path                 (four slashes = absolute)
#   postgres://user:pass@host:port/dbname
#   postgresql://...                    (same scheme)
#
# A path with no scheme is rejected with a message pointing at the right form.
module Chronicle
  # Raised when a store URL is empty, missing a scheme, has an unsupported
  # scheme, or is otherwise malformed.
  class InvalidStoreURL < DomainError
  end

  struct StoreURL
    getter scheme : String
    getter raw : String
    getter sqlite_path : String?

    def initialize(@scheme : String, @raw : String, @sqlite_path : String? = nil)
    end
  end

  SQLITE_SCHEMES   = %w(sqlite)
  POSTGRES_SCHEMES = %w(postgres postgresql)

  # Parse a store URL, or raise InvalidStoreURL with a helpful message.
  def self.parse_store_url(url : String) : StoreURL
    raise InvalidStoreURL.new("store URL is empty") if url.empty?

    uri = URI.parse(url)
    scheme = uri.scheme.try(&.downcase)
    if scheme.nil? || scheme.empty?
      raise InvalidStoreURL.new(
        "store URL #{url.inspect} has no scheme; if it's a SQLite file use sqlite:///#{url}"
      )
    end

    case scheme
    when "sqlite"
      StoreURL.new(scheme: "sqlite", raw: url, sqlite_path: sqlite_path(url, uri))
    when "postgres", "postgresql"
      validate_postgres!(url, uri)
      StoreURL.new(scheme: "postgres", raw: url)
    else
      raise InvalidStoreURL.new("unsupported store URL scheme #{scheme.inspect} in #{url.inspect}")
    end
  end

  private def self.sqlite_path(url : String, uri : URI) : String
    path = uri.path || ""
    if (host = uri.host) && !host.empty?
      path = "//#{host}#{path}"
    end
    raise InvalidStoreURL.new("sqlite URL #{url.inspect} has no path") if path.empty?
    path = path[1..] if path.starts_with?('/')
    raise InvalidStoreURL.new("sqlite URL #{url.inspect} has no path") if path.empty?
    path
  end

  private def self.validate_postgres!(url : String, uri : URI) : Nil
    host_or_db = uri.host || (uri.path || "").lstrip('/')
    if host_or_db.nil? || host_or_db.empty?
      raise InvalidStoreURL.new("postgres URL #{url.inspect} has no host or database")
    end
  end
end
