# The pack system: bundles of object types, relation types, behaviors,
# tools, prompts, and policies for a domain. Ported from activegraph
# activegraph/packs/* (revision 148e12c2969f18fa12a1a3c2e75f3affd9aa0616).
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
require "./packs/diligence"
