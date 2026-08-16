/// The one place the version number is written.
///
/// `build.sh` parses the literal below to stamp `CFBundleShortVersionString`,
/// and the release workflow checks it against the tag being built. It used to be
/// declared here *and* in the build script, an arrangement that works right up
/// until someone bumps one of them: `wildcard --version` then disagrees with the
/// About box, and neither is obviously the liar.
///
/// Keep the declaration on one line, as a plain string literal.
public enum WildcardVersion {
    public static let current = "1.0.0"
}
