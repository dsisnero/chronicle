require "json"

module Chronicle
  # Provider-boundary helpers shared by the shipped LLM providers (CONTRACT
  # v1.3 #3). Two concerns live here, both Sans-IO:
  #
  # **Tool-name sanitization.** Pack-scoped tools carry canonical dotted names
  # (`diligence.fetch_company_docs`); the OpenAI/Anthropic wire alphabet is
  # `^[a-zA-Z0-9_-]+$`, so a dotted name would be rejected. Canonical names
  # stay canonical everywhere inside the runtime and are rewritten only on the
  # wire: `.` becomes `__` on the way out, and returned tool calls map back
  # through an explicit per-request table (never a blind string replace).
  #
  # **Exception classification.** The v0.6 #11 reason taxonomy collapses
  # non-rate-limit provider failures into `llm.network_error` (transient,
  # retried). CONTRACT v1.3 #3 splits it: `llm.auth_error` and
  # `llm.request_error` are terminal; `llm.network_error` and
  # `llm.rate_limited` stay transient. Anything unrecognized stays
  # `llm.network_error` so unknown failure shapes keep pre-v1.3 retry
  # behavior.
  module Wire
    extend self

    private WIRE_SAFE = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"

    # Rewrite a canonical tool name into the providers' wire alphabet.
    # `.` (the pack-scope separator) becomes `__`; any other character outside
    # `[a-zA-Z0-9_-]` becomes `_`. Names already wire-safe pass through
    # unchanged, so non-pack tools are byte-identical to pre-v1.3 requests.
    def sanitize_tool_name(name : String) : String
      return name if name.each_char.all? { |char| WIRE_SAFE.includes?(char) }

      String.build do |io|
        name.each_char do |char|
          case char
          when '.'
            io << "__"
          else
            if WIRE_SAFE.includes?(char)
              io << char
            else
              io << '_'
            end
          end
        end
      end
    end

    # Map wire-safe names back to canonical names for one request. Collisions
    # (two canonical names sanitizing to the same wire name, e.g. `pack.tool`
    # alongside a literal `pack__tool`) raise `ToolNameCollisionError` —
    # silently dispatching the wrong tool would corrupt the event log's
    # causality. Accepts each tool definition as its canonical JSON string.
    def build_tool_name_map(tools : Array(String)) : Hash(String, String)
      mapping = {} of String => String
      tools.each do |tool_json|
        tool = JSON.parse(tool_json).as_h
        original = definition_name(tool)
        wire = sanitize_tool_name(original)
        if existing = mapping[wire]?
          raise ToolNameCollisionError.new(
            "tool names #{existing.inspect} and #{original.inspect} both sanitize " \
            "to #{wire.inspect} on the provider wire. Rename one of them — " \
            "the provider API only accepts [a-zA-Z0-9_-] names, and an ambiguous " \
            "reverse mapping would dispatch the wrong tool."
          )
        end
        mapping[wire] = original
      end
      mapping
    end

    # Reverse-map a wire tool name to its canonical form. Unknown names pass
    # through unchanged — the model can only call tools it was offered, so a
    # miss means the name was already canonical (no sanitization this request).
    def restore_tool_name(name : String, name_map : Hash(String, String)? = nil) : String
      return name unless name_map
      name_map[name]? || name
    end

    # Map a provider-SDK exception to a v0.6 #11 / v1.3 #3 reason code. Order
    # matters: rate-limit first (also a 4xx), then auth, then other 4xx request
    # errors, then network. The fallback for anything unrecognized is
    # `llm.network_error` — the transient code — so unknown failure shapes keep
    # their pre-v1.3 retry behavior rather than being silently promoted to
    # terminal.
    def classify_provider_exception(exc : Exception) : String
      status = exc.responds_to?(:status_code) ? exc.status_code.try(&.to_i) : nil
      classify_provider_failure(
        exc.class.to_s,
        exc.message || "",
        status_code: status,
      )
    end

    # Pure classification from the observable failure shape (name, message,
    # optional status code). The provider adapters extract these before
    # calling; anything unrecognized stays `llm.network_error`.
    def classify_provider_failure(
      name : String,
      message : String,
      *,
      status_code : Int32? = nil,
    ) : String
      name_l = name.downcase
      return "llm.rate_limited" if rate_limit?(name_l, message, status_code)
      return "llm.auth_error" if auth_error?(name_l, status_code)
      return "llm.request_error" if request_error?(name_l, status_code)
      "llm.network_error"
    end

    private def rate_limit?(name_l : String, message : String, status_code : Int32?) : Bool
      name_l.includes?("ratelimit") || status_code == 429 || message.includes?("429")
    end

    private def auth_error?(name_l : String, status_code : Int32?) : Bool
      name_l.includes?("authentication") || name_l.includes?("permissiondenied") ||
        status_code == 401 || status_code == 403
    end

    private def request_error?(name_l : String, status_code : Int32?) : Bool
      if code = status_code
        return true if 400 <= code < 500
      end
      name_l.includes?("badrequest") || name_l.includes?("unprocessableentity") || name_l.includes?("notfounderror")
    end

    # Terminal reasons are never retried (retrying identical credentials or
    # identical request bytes cannot succeed); transient ones stay in the
    # retry set. CONTRACT v1.3 #3.
    def terminal_reason?(reason : String) : Bool
      reason == "llm.auth_error" || reason == "llm.request_error"
    end

    # Extract the name from either tool-definition shape. The framework shape
    # is `{name, description, input_schema}`; the OpenAI passthrough shape
    # nests it under `function`.
    private def definition_name(tool : Hash(String, JSON::Any)) : String
      if tool["type"]?.try(&.as_s) == "function"
        if function = tool["function"]?.try(&.as_h)
          return function["name"]?.try(&.as_s) || ""
        end
      end
      tool["name"]?.try(&.as_s) || ""
    end
  end
end
