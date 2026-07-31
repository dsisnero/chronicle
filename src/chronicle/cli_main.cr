require "./cli"

# Binary entry point for the `chronicle-cli` target. Keeping this out of
# cli.cr means requiring the library never executes the CLI.
Chronicle::CLI.exec(ARGV, STDOUT)
