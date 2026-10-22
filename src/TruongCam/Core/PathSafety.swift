import Foundation

// CONTRACTS.md "Folder protocol hardening" and LIBRARY.md bounds. Every path that
// crosses the provider boundary is validated here before any file operation.
// The rules: relative only, no `..`, no absolute URL, no backslash, no NUL, no
// symlink escape outside the selected root, bounded length.

enum PathSafetyError: Error, Hashable, Sendable, CustomStringConvertible {
    case empty
    case absolute
    case containsParentTraversal(String)
    case containsBackslash
    case containsNUL
    case containsColon
    case tooLong(utf8Bytes: Int, limit: Int)
    case tooManyComponents(count: Int, limit: Int)
    case emptyComponent
    case escapesRoot(String)
    case symlinkEscape(String)

    var description: String {
        switch self {
        case .empty: return "Path is empty."
        case .absolute: return "Path must be relative to the library root."
        case .containsParentTraversal(let p): return "Path \(p) contains a parent-directory component."
        case .containsBackslash: return "Path contains a backslash."
        case .containsNUL: return "Path contains a NUL byte."
        case .containsColon: return "Path contains a colon, which is not a valid library filename character."
        case .tooLong(let b, let l): return "Path is \(b) UTF-8 bytes, above the \(l)-byte bound."
        case .tooManyComponents(let c, let l): return "Path has \(c) components, above the \(l)-component bound."
        case .emptyComponent: return "Path contains an empty component."
        case .escapesRoot(let p): return "Path \(p) resolves outside the library root."
        case .symlinkEscape(let p): return "Path \(p) resolves through a symlink that leaves the library root."
        }
    }
}

enum PathSafety {
    /// Validates a portable relative path string. Does not touch the filesystem.
    static func validateRelativePath(
        _ path: String,
        maxUTF8Bytes: Int = MetadataBounds.maxRelativePathUTF8Bytes,
        maxComponents: Int = MetadataBounds.maxPathComponents
    ) throws {
        if path.isEmpty { throw PathSafetyError.empty }
        if path.hasPrefix("/") { throw PathSafetyError.absolute }
        if path.utf8.contains(0) { throw PathSafetyError.containsNUL }
        if path.contains("\\") { throw PathSafetyError.containsBackslash }
        if path.contains(":") { throw PathSafetyError.containsColon }
        let byteCount = path.utf8.count
        if byteCount > maxUTF8Bytes {
            throw PathSafetyError.tooLong(utf8Bytes: byteCount, limit: maxUTF8Bytes)
        }
        // Reject Windows-style and URL-style absolute prefixes as well.
        if path.hasPrefix("~") || path.hasPrefix("file:") { throw PathSafetyError.absolute }

        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if components.count > maxComponents {
            throw PathSafetyError.tooManyComponents(count: components.count, limit: maxComponents)
        }
        for component in components {
            if component.isEmpty { throw PathSafetyError.emptyComponent }
            if component == "." || component == ".." {
                throw PathSafetyError.containsParentTraversal(path)
            }
        }
    }

    /// Resolves a validated relative path under a root and proves the result is
    /// still contained. Preserve the granted root URL for provider I/O; path
    /// comparison must not rewrite its filesystem alias or security authority.
    static func resolve(_ relativePath: String, under root: URL) throws -> URL {
        try validateRelativePath(relativePath)
        let candidate = root.appendingPathComponent(relativePath, isDirectory: false)
        let contained = try assertContained(candidate, in: root, relativePath: relativePath)
        try assertNoSymlinkComponents(relativePath, under: root)
        return contained
    }

    /// Lexical containment check. Foundation's standardizedFileURL can strip
    /// /private from an EXISTING root but leave it on a NOT-YET-EXISTING child.
    /// That makes a safe new dated destination appear outside its granted root.
    /// Normalize dot components without consulting the filesystem, and retain
    /// the original URL for I/O. resolve separately rejects symlink components.
    static func assertContained(_ candidate: URL, in root: URL, relativePath: String) throws -> URL {
        let rootComponents = lexicalComponents(root)
        let candidateComponents = lexicalComponents(candidate)
        guard candidateComponents.count > rootComponents.count else {
            throw PathSafetyError.escapesRoot(relativePath)
        }
        guard Array(candidateComponents.prefix(rootComponents.count)) == rootComponents else {
            throw PathSafetyError.escapesRoot(relativePath)
        }
        return candidate
    }

    private static func lexicalComponents(_ url: URL) -> [String] {
        var result: [String] = []
        for component in url.pathComponents {
            if component == "." { continue }
            if component == ".." {
                if result.last != "/", !result.isEmpty { result.removeLast() }
            } else {
                result.append(component)
            }
        }
        return result
    }

    /// True when the URL's last path component is a symlink. Callers use this to
    /// skip symlinks during scans rather than following them out of the root.
    static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType == .typeSymbolicLink
    }

    /// Component-wise symlink check for an existing path under `root`. Any
    /// symlink component fails, which is stricter than resolve-then-compare and
    /// avoids TOCTOU surprises inside a provider-managed directory.
    static func assertNoSymlinkComponents(_ relativePath: String, under root: URL) throws {
        try validateRelativePath(relativePath)
        var current = root
        for component in relativePath.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: false)
            if isSymlink(current) {
                throw PathSafetyError.symlinkEscape(relativePath)
            }
            guard FileManager.default.fileExists(atPath: current.path) else { return }
        }
    }
}
