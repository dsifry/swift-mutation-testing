struct MutationRewriter: Sendable {
    func rewrite(source: String, applying mutation: MutationPoint) -> String {
        let sourceData = source.data(using: .utf8)!
        let originalData = mutation.originalText.data(using: .utf8)!
        let mutatedData = mutation.mutatedText.data(using: .utf8)!

        let offset = mutation.utf8Offset

        guard offset >= 0, offset + originalData.count <= sourceData.count
        else { return source }

        var result = sourceData
        result.replaceSubrange(offset ..< offset + originalData.count, with: mutatedData)
        return String(data: result, encoding: .utf8)!
    }

    func rewrite(mutant: MutantDescriptor, in source: String) -> MutantDescriptor? {
        let point = MutationPoint(
            operatorIdentifier: mutant.operatorIdentifier,
            filePath: mutant.filePath,
            line: mutant.line,
            column: mutant.column,
            utf8Offset: mutant.utf8Offset,
            originalText: mutant.originalText,
            mutatedText: mutant.mutatedText,
            replacement: mutant.replacementKind,
            description: mutant.description
        )
        let content = rewrite(source: source, applying: point)
        guard content != source else { return nil }

        return MutantDescriptor(
            id: mutant.id,
            filePath: mutant.filePath,
            line: mutant.line,
            column: mutant.column,
            utf8Offset: mutant.utf8Offset,
            originalText: mutant.originalText,
            mutatedText: mutant.mutatedText,
            operatorIdentifier: mutant.operatorIdentifier,
            replacementKind: mutant.replacementKind,
            description: mutant.description,
            isSchematizable: mutant.isSchematizable,
            mutatedSourceContent: content
        )
    }
}
