require "../spec_helper"

# StoreURL parsing specs. Ported from activegraph tests/test_store_url.py
# (revision 148e12c2969f18fa12a1a3c2e75f3affd9aa0616).

describe Chronicle do
  describe ".parse_store_url" do
    it "parses an absolute sqlite path (four slashes)" do
      u = Chronicle.parse_store_url("sqlite:////tmp/run.db")
      u.scheme.should eq("sqlite")
      u.sqlite_path.should eq("/tmp/run.db")
    end

    it "parses a relative sqlite path (three slashes)" do
      u = Chronicle.parse_store_url("sqlite:///relative/path.db")
      u.scheme.should eq("sqlite")
      u.sqlite_path.should eq("relative/path.db")
    end

    it "parses a dot-relative sqlite path" do
      u = Chronicle.parse_store_url("sqlite:///./relative/path.db")
      u.scheme.should eq("sqlite")
      u.sqlite_path.should eq("./relative/path.db")
    end

    it "parses a postgres URL and preserves the raw form" do
      u = Chronicle.parse_store_url("postgres://u:p@host:5432/dbname")
      u.scheme.should eq("postgres")
      u.raw.should eq("postgres://u:p@host:5432/dbname")
    end

    it "normalizes the postgresql alias to postgres" do
      u = Chronicle.parse_store_url("postgresql://localhost/db")
      u.scheme.should eq("postgres")
    end

    it "rejects a bare path with a helpful message" do
      expect_raises(Chronicle::InvalidStoreURL, /no scheme/) do
        Chronicle.parse_store_url("run.db")
      end
      expect_raises(Chronicle::InvalidStoreURL, /sqlite:\/\/\/run\.db/) do
        Chronicle.parse_store_url("run.db")
      end
    end

    it "rejects an empty URL" do
      expect_raises(Chronicle::InvalidStoreURL) do
        Chronicle.parse_store_url("")
      end
    end

    it "rejects an unsupported scheme" do
      expect_raises(Chronicle::InvalidStoreURL, /mysql/) do
        Chronicle.parse_store_url("mysql://host/db")
      end
    end

    it "rejects a sqlite URL with no path" do
      expect_raises(Chronicle::InvalidStoreURL) do
        Chronicle.parse_store_url("sqlite://")
      end
    end

    it "rejects a postgres URL with no host or database" do
      expect_raises(Chronicle::InvalidStoreURL) do
        Chronicle.parse_store_url("postgres://")
      end
    end
  end
end
