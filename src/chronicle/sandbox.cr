require "json"

module Chronicle
  # Sandbox trial execution value types (upstream activegraph/sandbox/executor.py
  # + __init__.py, CONTRACT v1.8 #9–#12): the provider-neutral trial
  # specification, isolation guarantees, budget/artifact/event-log/failure
  # references, and the structured trial result with the legacy report lift.
  # Sans-IO — these are pure value types (serialization + validation); the
  # subprocess executor / child runner stay at the platform edge.
  module Sandbox
    # Where the child materializes the candidate pack from.
    struct PackSource
      include JSON::Serializable
      property root_dir : String
      property expected_bundle_hash : String = ""
      property? manifest_required : Bool = true

      def initialize(@root_dir : String, @expected_bundle_hash : String = "", @manifest_required : Bool = true)
      end
    end

    # The trial's resource nets. Zero/None disables a given net; `max_llm_calls`
    # defaults to 0 so key-freedom is structural.
    struct TrialLimits
      include JSON::Serializable
      property wall_clock_seconds : Float64 = 120.0
      property max_rss_bytes : Int64? = nil
      property max_events : Int32? = 2000
      property max_llm_calls : Int32? = 0
      property env_passthrough : Array(String) = [] of String

      def initialize(@wall_clock_seconds : Float64 = 120.0, @max_rss_bytes : Int64? = nil, @max_events : Int32? = 2000, @max_llm_calls : Int32? = 0, @env_passthrough : Array(String) = [] of String)
      end
    end

    # What a trial produced. Store-derived numbers, child-signaled shape.
    struct TrialReport
      include JSON::Serializable
      property outcome : String
      property fork_run_id : String
      property events_appended : Int32
      property behavior_failures : Int32
      property detail : String = ""
      property exit_code : Int32? = nil
      property warnings : Array(String) = [] of String

      def initialize(
        @outcome : String,
        @fork_run_id : String,
        @events_appended : Int32,
        @behavior_failures : Int32,
        @detail : String = "",
        @exit_code : Int32? = nil,
        @warnings : Array(String) = [] of String,
      )
      end
    end

    # An executor's explicit process and host-isolation claims.
    struct TrialIsolationGuarantees
      include JSON::Serializable
      property process : String
      property filesystem : String
      property network : String
      property syscalls : String
      property environment : String
      property? security_sandbox : Bool
      property notes : Array(String) = [] of String

      def initialize(
        @process : String,
        @filesystem : String,
        @network : String,
        @syscalls : String,
        @environment : String,
        @security_sandbox : Bool,
        @notes : Array(String) = [] of String,
      )
      end
    end

    # The default local-subprocess isolation posture: crash and parent-state
    # isolation only, no security sandbox.
    LOCAL_SUBPROCESS_ISOLATION = TrialIsolationGuarantees.new(
      process: "fresh_interpreter_subprocess",
      filesystem: "shared_host_filesystem",
      network: "unconfined",
      syscalls: "unconfined",
      environment: "closed_allowlist_plus_explicit_code_paths",
      security_sandbox: false,
      notes: [
        "crash and parent-state isolation only",
        "resource limits are platform-dependent and reported when degraded",
      ],
    )

    # Versioned, JSON-serializable intent for one pinned trial (upstream
    # `TrialSpecification`). `to_json` emits canonical versioned JSON;
    # `from_json` validates it (bad JSON, wrong schema version, missing
    # required fields, malformed pack sources / limits / extra packs).
    class TrialSpecification
      getter store_path : String
      getter parent_run_id : String
      getter at_event : String
      getter pack_source : PackSource
      getter scenario : String
      getter limits : TrialLimits
      getter label : String
      getter extra_packs : Array(PackSource)
      getter schema_version : Int32

      def initialize(
        @store_path : String,
        @parent_run_id : String,
        @at_event : String,
        @pack_source : PackSource,
        @scenario : String = "",
        @limits : TrialLimits = TrialLimits.new,
        @label : String = "trial",
        @extra_packs : Array(PackSource) = [] of PackSource,
        @schema_version : Int32 = 1,
      )
      end

      # Serialize as canonical versioned JSON (upstream
      # `json.dumps(sort_keys=True, separators=(",", ":"))`).
      def to_json : String
        payload = {
          "schema_version" => JSON::Any.new(schema_version),
          "store_path"     => JSON::Any.new(store_path),
          "parent_run_id"  => JSON::Any.new(parent_run_id),
          "at_event"       => JSON::Any.new(at_event),
          "pack_source"    => JSON.parse(pack_source.to_json),
          "scenario"       => JSON::Any.new(scenario),
          "limits"         => JSON.parse(limits.to_json),
          "label"          => JSON::Any.new(label),
          "extra_packs"    => JSON::Any.new(extra_packs.map { |source| JSON.parse(source.to_json) }),
        }
        Prompt.canonical_json(JSON::Any.new(payload))
      end

      # Parse and validate a versioned serialized specification.
      def self.from_json(serialized : String) : TrialSpecification
        payload = begin
          JSON.parse(serialized).as_h?
        rescue JSON::ParseException
          raise ArgumentError.new("trial specification must be valid JSON")
        end
        raise ArgumentError.new("trial specification must be a JSON object") if payload.nil?

        version = payload["schema_version"]?.try(&.as_i)
        raise ArgumentError.new("unsupported trial specification schema_version #{version.inspect}") unless version == 1

        store_path = required_string(payload, "store_path")
        parent_run_id = required_string(payload, "parent_run_id")
        at_event = required_string(payload, "at_event")
        label = required_string(payload, "label")
        scenario = payload["scenario"]?.try(&.as_s?) || ""

        pack_source_value = payload["pack_source"]?
        raise ArgumentError.new("missing required field pack_source") if pack_source_value.nil?
        pack_source = PackSource.from_json(pack_source_value.to_json)

        extra_payload = payload["extra_packs"]?.try(&.as_a?) || [] of JSON::Any
        extra_packs = extra_payload.map { |item| PackSource.from_json(item.to_json) }

        limits_value = payload["limits"]? || TrialLimits.new.to_json
        limits = TrialLimits.from_json(limits_value.to_json)

        new(
          store_path: store_path,
          parent_run_id: parent_run_id,
          at_event: at_event,
          pack_source: pack_source,
          scenario: scenario,
          limits: limits,
          label: label,
          extra_packs: extra_packs,
          schema_version: 1,
        )
      end

      private def self.required_string(payload : Hash(String, JSON::Any), key : String) : String
        value = payload[key]?.try(&.as_s?)
        raise ArgumentError.new("missing required field #{key}") if value.nil?

        value
      end
    end

    # Store-authoritative work counts plus the requested limit set.
    struct TrialBudgetUse
      getter events_appended : Int32
      getter behavior_failures : Int32
      getter limits : TrialLimits

      def initialize(@events_appended : Int32, @behavior_failures : Int32, @limits : TrialLimits)
      end
    end

    # Reference to one artifact produced by an executor.
    struct TrialArtifactReference
      getter name : String
      getter uri : String
      getter media_type : String?
      getter digest : String?

      def initialize(@name : String, @uri : String, @media_type : String? = nil, @digest : String? = nil)
      end
    end

    # Location of the event/log authority for one trial.
    struct TrialEventLogReference
      getter store_path : String
      getter run_id : String

      def initialize(@store_path : String, @run_id : String)
      end
    end

    # Structured terminal failure information.
    struct TrialFailureDetails
      getter kind : String
      getter message : String
      getter exit_code : Int32?

      def initialize(@kind : String, @message : String, @exit_code : Int32? = nil)
      end
    end

    # Provider-neutral structured result returned by a TrialExecutor (upstream
    # `TrialResult`), with the legacy report lift (`from_report`) and lossless
    # `to_report`.
    class TrialResult
      getter status : String
      getter budget_use : TrialBudgetUse
      getter artifacts : Array(TrialArtifactReference)
      getter event_log : TrialEventLogReference
      getter failure : TrialFailureDetails?
      getter isolation : TrialIsolationGuarantees
      getter detail : String
      getter exit_code : Int32?
      getter warnings : Array(String)

      def initialize(
        @status : String,
        @budget_use : TrialBudgetUse,
        @artifacts : Array(TrialArtifactReference),
        @event_log : TrialEventLogReference,
        @failure : TrialFailureDetails?,
        @isolation : TrialIsolationGuarantees,
        @detail : String = "",
        @exit_code : Int32? = nil,
        @warnings : Array(String) = [] of String,
      )
      end

      # Lift a legacy local report into the provider-neutral result.
      def self.from_report(
        report : TrialReport,
        *,
        specification : TrialSpecification,
        isolation : TrialIsolationGuarantees,
        artifacts : Array(TrialArtifactReference) = [] of TrialArtifactReference,
      ) : TrialResult
        failure = report.outcome == "completed" ? nil : TrialFailureDetails.new(report.outcome, report.detail, report.exit_code)
        new(
          status: report.outcome,
          budget_use: TrialBudgetUse.new(report.events_appended, report.behavior_failures, specification.limits),
          artifacts: artifacts,
          event_log: TrialEventLogReference.new(specification.store_path, report.fork_run_id),
          failure: failure,
          isolation: isolation,
          detail: report.detail,
          exit_code: report.exit_code,
          warnings: report.warnings,
        )
      end

      # Return the lossless legacy `run_forked_trial` report shape.
      def to_report : TrialReport
        TrialReport.new(
          outcome: status,
          fork_run_id: event_log.run_id,
          events_appended: budget_use.events_appended,
          behavior_failures: budget_use.behavior_failures,
          detail: detail,
          exit_code: exit_code,
          warnings: warnings,
        )
      end
    end
  end
end
