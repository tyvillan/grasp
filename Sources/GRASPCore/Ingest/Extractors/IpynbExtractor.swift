import Foundation

/// Plain-text extraction for Jupyter notebooks: concatenates markdown and
/// code cell source in order, fencing code so it doesn't get mistaken for
/// prose by the reflow/pair-parser pass downstream.
public enum IpynbExtractor {
    private struct Notebook: Decodable {
        let cells: [Cell]
    }

    private struct Cell: Decodable {
        let cellType: String
        let source: String

        enum CodingKeys: String, CodingKey {
            case cellType = "cell_type"
            case source
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            cellType = (try? container.decode(String.self, forKey: .cellType)) ?? "markdown"
            // nbformat allows `source` as either a single string or an
            // array of lines to join -- both appear in the vault's own
            // notebooks depending on which tool wrote them.
            if let lines = try? container.decode([String].self, forKey: .source) {
                source = lines.joined()
            } else {
                source = (try? container.decode(String.self, forKey: .source)) ?? ""
            }
        }
    }

    public static func extractText(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let notebook = try? JSONDecoder().decode(Notebook.self, from: data)
        else { return nil }

        return notebook.cells
            .map { cell in cell.cellType == "code" ? "```\n\(cell.source)\n```" : cell.source }
            .joined(separator: "\n\n")
    }
}
