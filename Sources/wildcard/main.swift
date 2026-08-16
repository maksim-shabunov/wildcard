import Foundation
import WildcardKit

// The helper binary. One executable, two faces:
//
//   wildcard mcp        an MCP server on stdin/stdout, for Claude Code, Codex,
//                       or any other agent
//   wildcard <command>  the command line
//
// Both go through `Service`, so neither can do anything the other cannot, and
// neither can apply a change on its own.

setvbuf(stdout, nil, _IOLBF, 0)

let argv = Array(CommandLine.arguments.dropFirst())

if argv.first == "mcp" {
    // stdout belongs to the protocol from here on. Anything else written to it
    // would corrupt the JSON-RPC stream.
    MCPServer(service: Service()).run()
    exit(0)
}

exit(CLI(args: Args(argv)).run())
