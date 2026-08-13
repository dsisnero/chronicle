module Chronicle
  # Base URL for error doc pages (CONTRACT v1.0 #C6). Single swap point.
  DOCS_BASE_URL = "https://docs.activegraph.ai"

  # Base URL for filing framework-bug reports.
  GITHUB_NEW_ISSUE_URL = "https://github.com/yoheinakajima/activegraph/issues/new"

  # Root of every framework error (CONTRACT v1.0 #4). Subclasses construct
  # with a one-line summary plus the three structured fields
  # (what_failed/why/how_to_fix) and any error-specific context. `#to_s`
  # produces the locked format:
  #
  #     <ErrorClass>: <one-line summary>
  #
  #     What failed:
  #       <specific thing that went wrong, with names>
  #
  #     Why:
  #       <root cause, not the symptom>
  #
  #     How to fix:
  #       <concrete action>
  #
  #     More:
  #       https://docs.activegraph.ai/errors/<slug>
  #
  # Legacy single-argument construction renders the message verbatim until
  # every leaf is migrated to the structured form.
  class ActiveGraphError < ArgumentError
    DOC_SLUG = "active-graph-error"

    getter what_failed : String
    getter why : String
    getter how_to_fix : String
    getter context : Hash(String, JSON::Any)

    def initialize(
      summary_or_message : String,
      *,
      what_failed : String? = nil,
      why : String? = nil,
      how_to_fix : String? = nil,
      context : Hash(String, JSON::Any)? = nil,
    )
      @what_failed = what_failed || ""
      @why = why || ""
      @how_to_fix = how_to_fix || ""
      @context = context || {} of String => JSON::Any
      @summary = summary_or_message
      if structured?
        super(format_message)
      else
        super(summary_or_message)
      end
    end

    # True when the three structured fields are populated.
    def structured? : Bool
      !@what_failed.empty? && !@why.empty? && !@how_to_fix.empty?
    end

    # Per-subclass doc slug; each category sets its own.
    def self.doc_slug : String
      DOC_SLUG
    end

    def doc_url : String
      "#{DOCS_BASE_URL}/errors/#{self.class.doc_slug}"
    end

    private def format_message : String
      "#{self.class.name.split("::").last}: #{@summary}\n\n" \
      "What failed:\n  #{indent_continuation(@what_failed)}\n\n" \
      "Why:\n  #{indent_continuation(@why)}\n\n" \
      "How to fix:\n  #{indent_continuation(@how_to_fix)}\n\n" \
      "More:\n  #{doc_url}"
    end

    # Re-indent a multi-line block so every line after the first sits under
    # the same column as the first (two-space lock-in column).
    private def indent_continuation(text : String) : String
      lines = text.split("\n")
      return text if lines.size == 1

      lines[0] + "\n" + lines[1..].map { |line| line.empty? ? line : "  #{line}" }.join("\n")
    end

    # Produce uniform structured fields for an internal-bug exception
    # (PR-G normalization). Used by the three framework-bug raise sites.
    # Returns the kwargs dict that a structured ActiveGraphError
    # initializer consumes.
    def self.internal_bug_fields(
      *,
      summary : String,
      what_happened : String,
      why_invariant : String,
      location : String,
      extra_context : Hash(String, JSON::Any)? = nil,
    ) : Hash(String, JSON::Any)
      ctx = {
        "internal"                => JSON::Any.new(true),
        "internal_error_location" => JSON::Any.new(location),
        "report_url"              => JSON::Any.new(GITHUB_NEW_ISSUE_URL),
      }
      if extra_context
        extra_context.each { |key, value| ctx[key] = value }
      end
      {
        "summary"     => JSON::Any.new(summary),
        "what_failed" => JSON::Any.new(what_happened),
        "why"         => JSON::Any.new(why_invariant),
        "how_to_fix"  => JSON::Any.new(
          "This is a framework bug, not a problem with your code.\n" \
          "Please file an issue and include the framework version, the\n" \
          "internal error location, and the full message above:\n" \
          "    #{GITHUB_NEW_ISSUE_URL}\n" \
          "\n" \
          "  internal location:   #{location}"
        ),
        "context" => JSON::Any.new(ctx),
      }
    end
  end

  # Base class for invalid inputs rejected by the deterministic core.
  # All framework errors inherit from ActiveGraphError; DomainError keeps
  # the ArgumentError ancestry for existing rescue sites.
  class DomainError < ActiveGraphError
  end

  # Runtime construction problems: invalid budget, malformed store URL,
  # missing required configuration (CONTRACT v1.0 #4b). Fires before any
  # work runs — never as a behavior.failed event.
  class ConfigurationError < ActiveGraphError
    DOC_SLUG = "configuration-error"

    def self.doc_slug : String
      DOC_SLUG
    end
  end

  # Caller-provided configuration is invalid: confusing arguments, missing
  # required argument, out-of-range value (CONTRACT v1.0 PR-F). Raised at
  # runtime construction / binding — never as a behavior.failed event.
  # Ported from activegraph.runtime.config_errors.InvalidRuntimeConfiguration.
  #
  # The cross-provider LLM mismatch shape (CONTRACT v1.0.2 #1 (b), upstream
  # _live._validate_one): a behavior pinned a model name that belongs to a
  # different shipped provider family than the one configured on this
  # Runtime. Constructed with the provider names so the recovery prose can
  # point the caller at the concrete swap.
  class InvalidRuntimeConfiguration < ConfigurationError
    DOC_SLUG = "invalid-runtime-configuration"

    def initialize(*, behavior_name : String, model : String, provider_class : String, claimed_by : String)
      @behavior_name = behavior_name
      @model = model
      @provider_class = provider_class
      @claimed_by = claimed_by
      summary = (
        "@llm_behavior(name=#{behavior_name.inspect}, model=#{model.inspect}) " \
        "names a #{claimed_by}-family model, but the runtime is configured " \
        "with #{provider_class}"
      )
      super(
        summary,
        what_failed: (
          "The behavior #{behavior_name.inspect} pinned model=#{model.inspect}. " \
          "That name belongs to #{claimed_by}'s model family, but this Runtime " \
          "was constructed with a #{provider_class} instance. Sending the name " \
          "to the wrong provider produces an HTTP 404 (or equivalent 'unknown " \
          "model' response) at first LLM call, with no hint that the mismatch " \
          "is the cause."
        ),
        why: (
          "v1.0.2 #1 validates explicit model names at both binding moments " \
          "(Runtime construction and register()/decoration) against each " \
          "shipped provider's recognizes_model() method. The configured " \
          "provider doesn't claim this name, but another shipped provider " \
          "does — that's a configuration mismatch worth surfacing before the " \
          "first network call rather than after."
        ),
        how_to_fix: (
          "Either swap the provider — Runtime(graph, llm_provider=#{claimed_by}()) — " \
          "or set a #{provider_class}-compatible model name."
        ),
        context: {
          "behavior"            => JSON::Any.new(behavior_name),
          "model"               => JSON::Any.new(model),
          "configured_provider" => JSON::Any.new(provider_class),
          "claimed_by_provider" => JSON::Any.new(claimed_by),
        },
      )
    end

    def self.doc_slug : String
      DOC_SLUG
    end
  end

  # Behavior, tool, or pack registration problems: conflicts at
  # registration time, version mismatches, missing providers.
  class RegistrationError < ActiveGraphError
    DOC_SLUG = "registration-error"

    def self.doc_slug : String
      DOC_SLUG
    end
  end

  # Runtime execution problems: behavior failures, budget exhausted, tool
  # failures during a goal run.
  class ExecutionError < ActiveGraphError
    DOC_SLUG = "execution-error"

    def self.doc_slug : String
      DOC_SLUG
    end
  end

  # Replay and fork problems: cache hash mismatches, type-stream divergence
  # between recorded and re-run event logs. Fires only during replay/fork.
  class ReplayError < ActiveGraphError
    DOC_SLUG = "replay-error"

    def self.doc_slug : String
      DOC_SLUG
    end
  end

  # A ctx method (e.g. ctx.propose_object) was called from a behavior whose
  # context isn't bound to a runtime. Fires at execution time, inside a
  # running behavior. Ported from
  # activegraph.runtime.exec_errors.RuntimeContextRequiredError.
  class RuntimeContextRequiredError < ExecutionError
    DOC_SLUG = "runtime-context-required-error"

    getter method : String

    def initialize(@method : String = "ctx.propose_object")
      super(
        "#{@method} requires a runtime-bound context",
        what_failed: (
          "A behavior called #{@method} on a behavior context that " \
          "was constructed without a Runtime — likely a test fixture " \
          "that invokes the handler directly instead of through " \
          "Runtime.run_goal / run_until_idle."
        ),
        why: (
          "ctx.propose_object (and other ctx methods) defer work to the " \
          "runtime: approval routing, durable event emission, and pack " \
          "state all live on the Runtime. A context without one cannot " \
          "perform those actions, so the framework raises rather than " \
          "silently no-op'ing."
        ),
        how_to_fix: (
          "Invoke the behavior through a Runtime (run_goal / run_until_idle) " \
          "so the context is runtime-bound. In a test, construct the " \
          "Runtime, load the pack, and run it rather than calling the " \
          "handler closure directly."
        ),
        context: {"method" => JSON::Any.new(@method)},
      )
    end

    def self.doc_slug : String
      DOC_SLUG
    end
  end

  # Pattern subscription problems: invalid Cypher syntax, unsupported
  # features, malformed WHERE clauses (CONTRACT v0.7 #8). Defined in
  # patterns.cr as a DomainError subclass; `PatternError < DomainError <
  # ActiveGraphError` so it is transitively a category base.

  class InvalidEventError < DomainError
  end

  class EventSequenceError < DomainError
  end

  class DuplicateEventError < DomainError
  end

  class CausalParentError < DomainError
  end

  class InvalidRoutingPolicyError < DomainError
  end

  class NoRouteError < DomainError
  end

  class ProviderNotAvailableError < DomainError
  end

  # A platform-edge provider failure that may safely advance a pre-recorded
  # fallback list. Configuration, policy, and capability errors are not this.
  class RetryableProviderError < DomainError
  end

  class OverrideNotAllowedError < DomainError
  end

  class NoLocalTargetError < DomainError
  end

  class ContextBudgetError < DomainError
  end

  class GraphProjectionError < DomainError
  end

  # A behavior tried to inject a reserved field (e.g. provenance) through
  # object/relation data. Ported from activegraph's ReservedFieldError.
  class ReservedFieldError < DomainError
  end

  # Raised when a replay (replay_strict) or a fork produces an event stream
  # that does not match the recorded log. event_id pins the first divergence
  # point; expected/actual describe recorded vs re-run. Ported from
  # activegraph.runtime.errors.ReplayDivergenceError (under ReplayError).
  #
  # The reference error class for the v1.0 message rewrite series. The
  # keyword-only signature `(event_id:, expected:, actual:)` builds a
  # structured message with a `kind` discriminator inferred from the inputs:
  #
  #   - expected starts with "prompt_hash="    -> prompt_hash_mismatch
  #   - expected starts with "embedding_hash=" -> embedding_hash_mismatch
  #   - expected == "<no recorded event>" or actual is nil -> length_mismatch
  #   - otherwise -> type_mismatch
  #
  # The legacy message-plus-attrs constructor (`new(message, event_id:, ...)`)
  # is preserved verbatim for pre-structured call sites.
  class ReplayDivergenceError < ReplayError
    DOC_SLUG = "replay-divergence-error"

    NO_RECORDED_EVENT = "<no recorded event>"

    getter event_id : String
    getter expected : String
    getter actual : String?
    getter kind : String

    def initialize(message : String, *, event_id : String = "", expected : String = "", actual : String? = nil)
      @event_id = event_id
      @expected = expected
      @actual = actual
      @kind = ""
      super(message)
    end

    def initialize(*, event_id : String, expected : String, actual : String?)
      @event_id = event_id
      @expected = expected
      @actual = actual
      built = self.class.build_message(event_id: event_id, expected: expected, actual: actual)
      @kind = built[:kind]
      super(
        built[:summary],
        what_failed: built[:what_failed],
        why: built[:why],
        how_to_fix: built[:how_to_fix],
        context: {
          "event_id" => JSON::Any.new(event_id),
          "kind"     => JSON::Any.new(built[:kind]),
          "expected" => JSON::Any.new(expected),
          "actual"   => actual.nil? ? JSON::Any.new(nil) : JSON::Any.new(actual),
        },
      )
    end

    # Returns `(kind, summary, what_failed, why, how_to_fix)` for the four
    # replay-divergence shapes (upstream `_build_message`). The discriminator
    # is the input shape. Public so call sites and tests can render the same
    # diagnostics without constructing the error.
    def self.build_message(*, event_id : String, expected : String, actual : String?) : NamedTuple(kind: String, summary: String, what_failed: String, why: String, how_to_fix: String)
      if expected.starts_with?("prompt_hash=")
        prompt_hash_message(event_id, expected, actual)
      elsif expected.starts_with?("embedding_hash=")
        embedding_hash_message(event_id, expected, actual)
      elsif expected == NO_RECORDED_EVENT || actual.nil?
        length_message(event_id, expected, actual)
      else
        type_message(event_id, expected, actual)
      end
    end

    def self.doc_slug : String
      DOC_SLUG
    end

    private def self.prompt_hash_message(event_id : String, expected : String, actual : String?) : NamedTuple(kind: String, summary: String, what_failed: String, why: String, how_to_fix: String)
      actual_str = actual || "<no live response>"
      {
        kind:        "prompt_hash_mismatch",
        summary:     "replay diverged at #{event_id}: LLM prompt hash mismatch",
        what_failed: (
          "Event #{event_id} (an `llm.requested` event in the recorded log) had a " \
          "different prompt hash during this replay than the parent run recorded:\n" \
          "  recorded:  #{expected}\n" \
          "  live:      #{actual_str}"
        ),
        why: (
          "The replay cache keys on the full prompt hash, so any change to an LLM " \
          "behavior's code, a prompt template, a system message, or a tool's input " \
          "arguments produces a mismatch. The framework refuses to silently substitute " \
          "a stale cached response under a new prompt — that would break the audit " \
          "trail the cache is designed to preserve."
        ),
        how_to_fix: (
          "If the change was intentional (you edited a behavior or a prompt template),\n" \
          "re-record the cache from the divergence point:\n" \
          "    activegraph fork <parent-run> --at-event #{event_id} --record\n" \
          "\n" \
          "If the change was unintentional, diff your code against the recorded run's\n" \
          "pack version and revert the change:\n" \
          "    activegraph inspect <parent-run> --pack-version\n" \
          "\n" \
          "To see the full recorded prompt for this event:\n" \
          "    activegraph inspect <parent-run> --event #{event_id}"
        ),
      }
    end

    private def self.embedding_hash_message(event_id : String, expected : String, actual : String?) : NamedTuple(kind: String, summary: String, what_failed: String, why: String, how_to_fix: String)
      actual_str = actual || "<no live request>"
      {
        kind:        "embedding_hash_mismatch",
        summary:     "replay diverged at #{event_id}: embedding input hash mismatch",
        what_failed: (
          "Event #{event_id} rebuilt a different runtime-owned embedding " \
          "request than the recorded run:\n" \
          "  recorded:  #{expected}\n" \
          "  live:      #{actual_str}"
        ),
        why: (
          "Embedding replay keys on the model and complete ordered text " \
          "batch. Serving recorded vectors under a different content hash " \
          "would silently corrupt retrieval results and provenance."
        ),
        how_to_fix: (
          "Restore the recorded model/text construction or intentionally " \
          "fork before this request and record a new embedding response."
        ),
      }
    end

    private def self.type_message(event_id : String, expected : String, actual : String?) : NamedTuple(kind: String, summary: String, what_failed: String, why: String, how_to_fix: String)
      actual_str = actual || "<no live event>"
      {
        kind:        "type_mismatch",
        summary:     "replay diverged at #{event_id}: event type mismatch",
        what_failed: (
          "At the stream position pinned to event #{event_id}, the live re-run " \
          "produced a different event type than recorded:\n" \
          "  recorded:  #{expected.inspect}\n" \
          "  live:      #{actual_str.inspect}"
        ),
        why: (
          "Strict replay compares the type stream of non-lifecycle events between the " \
          "recorded log and the live re-run. A type mismatch means the behavior graph " \
          "took a different branch — usually because a behavior's `where` filter, a " \
          "pattern subscription, or a conditional `graph.emit` changed since the " \
          "recorded run."
        ),
        how_to_fix: (
          "Identify the behavior that produced event #{event_id} in the recorded log:\n" \
          "    activegraph inspect <parent-run> --event #{event_id}\n" \
          "\n" \
          "Diff that behavior against your current source. If the change was\n" \
          "intentional, re-run without `replay_strict=True` (or fork with --record\n" \
          "from the divergence point). If unintentional, revert the behavior."
        ),
      }
    end

    private def self.length_message(event_id : String, expected : String, actual : String?) : NamedTuple(kind: String, summary: String, what_failed: String, why: String, how_to_fix: String)
      if actual.nil?
        {
          kind:        "length_mismatch",
          summary:     "replay diverged at #{event_id}: live re-run finished early",
          what_failed: (
            "The recorded log contained event #{event_id} (type #{expected.inspect}) at this " \
            "position, but the live re-run terminated before producing it.\n" \
            "  recorded:  #{expected.inspect}\n" \
            "  live:      <no event produced>"
          ),
          why: (
            "Strict replay requires the live re-run to produce the same number and " \
            "shape of non-lifecycle events as the recording. A short live re-run means " \
            "a behavior that fired in the recorded run no longer fires, or short-" \
            "circuits earlier — usually because a pattern subscription, a `where` " \
            "filter, or a guard condition was tightened since the recording."
          ),
          how_to_fix: (
            "Identify the behavior that produced #{event_id} in the recorded log:\n" \
            "    activegraph inspect <parent-run> --event #{event_id}\n" \
            "\n" \
            "Compare that behavior's current trigger conditions against the recorded\n" \
            "run's. If the change was intentional, fork with --record from the\n" \
            "divergence point to refresh the recording. If unintentional, revert."
          ),
        }
      else
        {
          kind:        "length_mismatch",
          summary:     "replay diverged at #{event_id}: live re-run produced an unrecorded event",
          what_failed: (
            "At the position pinned to event #{event_id}, the live re-run produced an " \
            "event of type #{actual.inspect}, but the recorded log had no event here.\n" \
            "  recorded:  <no event recorded>\n" \
            "  live:      #{actual.inspect}"
          ),
          why: (
            "Strict replay requires the live re-run's event stream to match the " \
            "recording position-for-position. An extra live event means a behavior " \
            "fires now that did not fire in the recorded run — usually because a new " \
            "behavior was added, or a pattern subscription was loosened."
          ),
          how_to_fix: (
            "List the behaviors currently registered and compare against the recorded\n" \
            "pack version:\n" \
            "    activegraph inspect <parent-run> --behaviors\n" \
            "\n" \
            "If the new behavior is intentional, re-record from this position:\n" \
            "    activegraph fork <parent-run> --at-event #{event_id} --record\n" \
            "\n" \
            "If the behavior shouldn't fire here, tighten its trigger conditions."
          ),
        }
      end
    end
  end

  class ApprovalError < DomainError
  end

  class InvalidLogEncodingError < DomainError
  end

  # Base class for storage-layer failures. Ported from activegraph's
  # StorageError category.
  class StorageError < DomainError
    DOC_SLUG = "storage-error"

    def self.doc_slug : String
      DOC_SLUG
    end
  end

  # A payload value could not be JSON-encoded (encode-side failure).
  # Ported from activegraph.store.serde.NonSerializableEventError. In Crystal
  # this is a compile-time guarantee for well-typed payloads (JSON::Any /
  # String can't hold non-JSON values), so the error is the fail-fast gate
  # surface rather than a commonly-reached runtime error.
  class NonSerializableEventError < StorageError
  end

  # A stored event payload could not be decoded as JSON (decode-side failure).
  # Ported from activegraph.store.errors.CorruptedEventPayloadError. Distinct
  # from NonSerializableEventError: corruption-on-load, not encode failure.
  class CorruptedEventPayloadError < StorageError
  end

  # Two canonical tool names sanitize to the same wire-safe name, so an
  # ambiguous reverse mapping would dispatch the wrong tool. Ported from
  # activegraph.llm.wire.build_tool_name_map's ValueError (CONTRACT v1.3 #3).
  class ToolNameCollisionError < DomainError
  end

  # A `prompt_template=` references a placeholder other than {system},
  # {view}, {event}, {instruction}. Ported from activegraph llm/prompt.py
  # assemble_prompt's ValueError.
  class PromptTemplateError < DomainError
  end

  # Structured failure from inside an LLM behavior / provider. Carries a
  # reason code from the CONTRACT v0.6 #11 taxonomy plus a free-form message
  # and payload extras the runtime folds into the emitted behavior.failed
  # event. Ported from activegraph.llm.errors.LLMBehaviorError.
  class LLMBehaviorError < DomainError
    getter reason : String
    getter payload_extras : Hash(String, JSON::Any)

    def initialize(
      @reason : String,
      message : String,
      @payload_extras : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
      super(message)
    end
  end

  class PackError < DomainError
    DOC_SLUG = "pack-error"

    def self.doc_slug : String
      DOC_SLUG
    end
  end

  # A tool call failed: unpermitted external I/O, network error, or timeout.
  # Ported from activegraph's ToolError. Carries a `reason` code from the
  # CONTRACT v0.7 #6 taxonomy (tool.timeout, tool.network_error,
  # tool.invalid_input, tool.invalid_output, tool.execution_error,
  # tool.unknown_tool, tool.fixture_missing, ...) plus free-form message and
  # payload extras the runtime folds into the tool.responded error payload.
  class ToolError < DomainError
    getter reason : String
    getter payload_extras : Hash(String, JSON::Any)

    def initialize(
      @reason : String,
      message : String,
      @payload_extras : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
      super(message)
    end
  end

  # A dev.override request or receipt that violates run-local, log-backed
  # governance rules. Ported from activegraph's ValueError on
  # validate_override_request / gate_is_forbidden.
  class DevOverrideError < DomainError
  end

  # A runtime operation requires a state the runtime is not in (e.g.
  # `fork` on a non-SQLite-backed runtime). Ported from activegraph's
  # IncompatibleRuntimeState.
  class IncompatibleRuntimeState < DomainError
  end

  # An event id referenced by an operation does not exist in the run.
  # Ported from activegraph's EventNotFoundError.
  class EventNotFoundError < DomainError
  end

  # A promote() plan contained one or more both-sides/referential-integrity
  # conflicts; nothing was mutated. Ported from activegraph's
  # PromoteConflictError (CONTRACT v1.3 #4).
  class PromoteConflictError < DomainError
    getter conflicts : Array(PromoteConflict)

    def initialize(conflicts : Array(PromoteConflict))
      @conflicts = conflicts
      super("promote conflicts: #{conflicts.map(&.id).join(", ")}")
    end
  end

  # promote() called with a fork whose store lineage does not record this run
  # as its direct parent. Ported from activegraph's PromoteLineageError.
  class PromoteLineageError < DomainError
  end
end
