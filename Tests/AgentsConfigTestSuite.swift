import Testing

/// Global seams (AppPaths and AppSettings) are shared across all child suites.
/// Serializing individual sibling suites does not exclude an async sibling;
/// this common parent makes their entire lifetimes mutually exclusive.
@Suite("AgentsConfig isolated tests", .serialized)
struct AgentsConfigTestSuite {}
