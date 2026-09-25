import Foundation

/// A one-lecture notes vault for trying GRASP without notes of your own:
/// the Windows app's "Try sample notes" and `grasp-check` both import it.
/// It's a real Matrix Theory lecture's shape -- key terms that become
/// cards, and a worked row reduction the overview figures can walk.
public enum SampleVault {
    public static let courseFolder = "College/Fall Semester 2026/Matrix Theory"
    public static let fileName = "2026-08-27_Lecture-02_Row-Reduction.md"

    public static let lecture = """
# 2026-08-27 · Lecture 2 - Row Reduction and Echelon Forms

## Key Terms

- **Echelon form** - a matrix with zero rows at the bottom, each leading entry right of the one above, and zeros below each leading entry.
- **Free variable** - a variable whose column holds no pivot, which may be assigned any value at all.
- **Pivot position** - a location corresponding to a leading 1 in the reduced echelon form.

## Worked Example

```
[ 1  -7   0   6 |  5 ]
[ 0   0   1  -2 | -3 ]
[ -1  7  -4   2 |  7 ]
```

**Step 1** - R₃ → R₃ + R₁. **Step 2** - R₃ → R₃ + 4·R₂, giving a zero row.

```
[ 1  -7   0   6 |  5 ]
[ 0   0   1  -2 | -3 ]
[ 0   0   0   0 |  0 ]
```

The basic variables are x₁ and x₃; x₂ and x₄ are free, so there are infinitely many solutions.
"""

    /// Writes the vault under `root` (creating folders as needed) and
    /// returns `root`, ready for `VaultScanner.scan(vaultRoot:)`.
    @discardableResult
    public static func write(to root: URL) throws -> URL {
        let course = root.appendingPathComponent(courseFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: course, withIntermediateDirectories: true)
        try Data(lecture.utf8).write(to: course.appendingPathComponent(fileName))
        return root
    }
}
