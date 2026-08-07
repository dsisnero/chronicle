# The pack system: bundles of object types, relation types, behaviors,
# tools, prompts, and policies for a domain. Ported from activegraph
# activegraph/packs/* (revision 8aedb1866cf5dce056af97529152ffd6f468a1ed).
#
# Pack-aware decorators in Python become Crystal annotations collected by the
# `Chronicle::Packs::DSL.pack` macro; nothing registers globally.
require "./packs/exceptions"
require "./packs/prompt"
require "./packs/settings"
require "./packs/behavior"
require "./packs/scheduler"
require "./packs/value_objects"
require "./packs/annotations"
require "./packs/discovery"
require "./packs/loader"
require "./packs/manifest"
require "./packs/scaffold"
