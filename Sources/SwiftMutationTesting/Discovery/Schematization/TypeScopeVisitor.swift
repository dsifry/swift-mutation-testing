import SwiftSyntax

final class TypeScopeVisitor: SyntaxVisitor {

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    private(set) var scopes: [FunctionBodyScope] = []
    private var exactOnlyScopes: [FunctionBodyScope] = []

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        record(body: node.body)
        return .visitChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        recordExactOnly(body: node.body)
        return .visitChildren
    }

    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        record(body: node.body)
        return .visitChildren
    }

    override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind {
        recordExactOnly(body: node.body)
        return .visitChildren
    }

    override func visit(_ node: AccessorBlockSyntax) -> SyntaxVisitorContinueKind {
        if case .getter(let statements) = node.accessors {
            recordExactOnly(
                bodyStartOffset: node.position.utf8Offset,
                bodyEndOffset: node.endPosition.utf8Offset,
                statementsStartOffset: statements.position.utf8Offset,
                statementsEndOffset: statements.endPosition.utf8Offset
            )
        }
        return .visitChildren
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        let offset = node.position.utf8Offset
        if node.signature == nil, !isExactOnly(utf8Offset: offset), !isSchematizable(utf8Offset: offset) {
            record(
                bodyStartOffset: offset,
                bodyEndOffset: node.endPosition.utf8Offset,
                statementsStartOffset: node.statements.position.utf8Offset,
                statementsEndOffset: node.statements.endPosition.utf8Offset
            )
        }
        return .visitChildren
    }

    private func record(body: CodeBlockSyntax?) {
        guard let body else { return }
        record(
            bodyStartOffset: body.position.utf8Offset,
            bodyEndOffset: body.endPosition.utf8Offset,
            statementsStartOffset: body.statements.position.utf8Offset,
            statementsEndOffset: body.statements.endPosition.utf8Offset
        )
    }

    private func recordExactOnly(body: CodeBlockSyntax?) {
        guard let body else { return }
        recordExactOnly(
            bodyStartOffset: body.position.utf8Offset,
            bodyEndOffset: body.endPosition.utf8Offset,
            statementsStartOffset: body.statements.position.utf8Offset,
            statementsEndOffset: body.statements.endPosition.utf8Offset
        )
    }

    private func recordExactOnly(
        bodyStartOffset: Int,
        bodyEndOffset: Int,
        statementsStartOffset: Int,
        statementsEndOffset: Int
    ) {
        exactOnlyScopes.append(FunctionBodyScope(
            bodyStartOffset: bodyStartOffset,
            bodyEndOffset: bodyEndOffset,
            statementsStartOffset: statementsStartOffset,
            statementsEndOffset: statementsEndOffset
        ))
    }

    private func isExactOnly(utf8Offset: Int) -> Bool {
        exactOnlyScopes.contains {
            $0.bodyStartOffset <= utf8Offset && utf8Offset < $0.bodyEndOffset
        }
    }

    private func record(
        bodyStartOffset: Int,
        bodyEndOffset: Int,
        statementsStartOffset: Int,
        statementsEndOffset: Int
    ) {
        scopes.append(
            FunctionBodyScope(
                bodyStartOffset: bodyStartOffset,
                bodyEndOffset: bodyEndOffset,
                statementsStartOffset: statementsStartOffset,
                statementsEndOffset: statementsEndOffset
            )
        )
    }

    func isSchematizable(utf8Offset: Int) -> Bool {
        !isExactOnly(utf8Offset: utf8Offset) && scopes.contains {
            $0.bodyStartOffset <= utf8Offset && utf8Offset < $0.bodyEndOffset
        }
    }

    func innermostScope(containing utf8Offset: Int) -> FunctionBodyScope? {
        scopes
            .filter { $0.bodyStartOffset <= utf8Offset && utf8Offset < $0.bodyEndOffset }
            .min { ($0.bodyEndOffset - $0.bodyStartOffset) < ($1.bodyEndOffset - $1.bodyStartOffset) }
    }
}
