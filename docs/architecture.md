# Architecture

Chronicle is a conventional Crystal shard. Library code is loaded through
`src/chronicle.cr`; tests use `spec/spec_helper.cr` and mirror public behavior.

The public version constant is `Chronicle::VERSION`.
