import Testing

@testable import SwiftMutationTesting

@Suite("TypeScopeVisitor")
struct TypeScopeVisitorTests {
    @Test("Given function with body, when walked, then records one scope")
    func functionWithBodyRecordsOneScope() {
        let visitor = makeTypeScopeVisitor("func f() { let x = 1 }")
        #expect(visitor.scopes.count == 1)
    }

    @Test("Given protocol function requirement without body, when walked, then records no scope")
    func functionWithoutBodyRecordsNoScope() {
        let visitor = makeTypeScopeVisitor("protocol P { func f() }")
        #expect(visitor.scopes.isEmpty)
    }

    @Test("Given two functions, when walked, then records two scopes")
    func twoFunctionsRecordTwoScopes() {
        let visitor = makeTypeScopeVisitor("func f() { } func g() { }")
        #expect(visitor.scopes.count == 2)
    }

    @Test("Given nested function, when walked, then records two scopes")
    func nestedFunctionRecordsTwoScopes() {
        let code = "func outer() { func inner() { let x = 1 } }"
        let visitor = makeTypeScopeVisitor(code)
        #expect(visitor.scopes.count == 2)
    }

    @Test("Given Guide-shaped initializer, logical points remain exact-only")
    func initializerDoesNotRecordSchematizableScope() {
        let code = """
        actor Store {
            let defaults: Bool
            let key: Bool
            init(enabled: Bool?) {
                defaults = enabled ?? false
                key = defaults && enabled != nil
                guard defaults == false, let enabled else { return }
                _ = enabled
            }
        }
        """
        let visitor = makeTypeScopeVisitor(code)
        let point = code.utf8.distance(
            from: code.utf8.startIndex,
            to: code.range(of: "defaults &&")!.lowerBound.samePosition(in: code.utf8)!)
        #expect(visitor.scopes.isEmpty)
        #expect(!visitor.isSchematizable(utf8Offset: point))
    }

    @Test("Given mutation offset inside function body, when checked, then isSchematizable returns true")
    func offsetInsideFunctionBodyIsSchematizable() {
        let code = "func f() { let x = true }"
        let source = makeParsedSource(code)
        let visitor = TypeScopeVisitor()
        visitor.walk(source.syntax)

        let mutation = BooleanLiteralReplacement().mutations(in: source)[0]
        #expect(visitor.isSchematizable(utf8Offset: mutation.utf8Offset))
    }

    @Test("Given mutation at file scope, when checked, then isSchematizable returns false")
    func offsetAtFileScopeIsNotSchematizable() {
        let code = "let x = true"
        let source = makeParsedSource(code)
        let visitor = TypeScopeVisitor()
        visitor.walk(source.syntax)

        let mutation = BooleanLiteralReplacement().mutations(in: source)[0]
        #expect(!visitor.isSchematizable(utf8Offset: mutation.utf8Offset))
    }

    @Test("Given result-builder getter, nested closure mutations remain exact-only")
    func resultBuilderGetterAndNestedClosureAreExactOnly() {
        let code = """
        struct View {
            @Builder var body: some Content {
                Group { enabled && visible }
            }
        }
        """
        let source = makeParsedSource(code)
        let visitor = TypeScopeVisitor()
        visitor.walk(source.syntax)

        let mutations = LogicalOperatorReplacement().mutations(in: source)
        #expect(mutations.count == 1)
        #expect(!visitor.isSchematizable(utf8Offset: mutations[0].utf8Offset))
    }

    @Test("Given computed property with implicit getter, mutation remains exact-only")
    func computedPropertyImplicitGetterIsExactOnly() {
        let code = "struct S { var x: Bool { return true } }"
        let source = makeParsedSource(code)
        let visitor = TypeScopeVisitor()
        visitor.walk(source.syntax)

        let mutation = BooleanLiteralReplacement().mutations(in: source)[0]
        #expect(!visitor.isSchematizable(utf8Offset: mutation.utf8Offset))
    }

    @Test("Given computed property with explicit getter, mutation remains exact-only")
    func computedPropertyExplicitGetterIsExactOnly() {
        let code = "struct S { var x: Bool { get { return true } } }"
        let source = makeParsedSource(code)
        let visitor = TypeScopeVisitor()
        visitor.walk(source.syntax)

        let mutation = BooleanLiteralReplacement().mutations(in: source)[0]
        #expect(!visitor.isSchematizable(utf8Offset: mutation.utf8Offset))
    }

    @Test("Given mutation inside global-scope closure, when checked, then isSchematizable returns true")
    func mutationInsideGlobalScopeClosureIsSchematizable() {
        let code = "let compute: () -> Bool = { return true }"
        let source = makeParsedSource(code)
        let visitor = TypeScopeVisitor()
        visitor.walk(source.syntax)

        let mutation = BooleanLiteralReplacement().mutations(in: source)[0]
        #expect(visitor.isSchematizable(utf8Offset: mutation.utf8Offset))
    }

    @Test("Given deinitializer with body, when walked, then records one scope")
    func deinitializerRecordsScope() {
        let visitor = makeTypeScopeVisitor("class C { deinit { let x = 1 } }")
        #expect(visitor.scopes.count == 1)
    }

    @Test("Given computed property observer, mutation remains exact-only")
    func computedPropertyObserverIsExactOnly() {
        let code = "class C { var x: Int = 0 { didSet { let enabled = true; _ = enabled } } }"
        let source = makeParsedSource(code)
        let visitor = TypeScopeVisitor()
        visitor.walk(source.syntax)

        let mutations = BooleanLiteralReplacement().mutations(in: source)
        #expect(!mutations.isEmpty)
        #expect(mutations.allSatisfy { !visitor.isSchematizable(utf8Offset: $0.utf8Offset) })
    }

    @Test("Given offset outside all scopes, when innermostScope queried, then returns nil")
    func innermostScopeReturnsNilForOffsetOutsideAllScopes() {
        let visitor = makeTypeScopeVisitor("func f() { let x = 1 }")
        #expect(visitor.innermostScope(containing: 99999) == nil)
    }

    @Test("Given nested function, when innermostScope queried, then returns smallest containing scope")
    func innermostScopeReturnsSmallestContainingScope() {
        let code = "func outer() { func inner() { let x = 1 } }"
        let source = makeParsedSource(code)
        let visitor = TypeScopeVisitor()
        visitor.walk(source.syntax)

        let innerSource = makeParsedSource("func outer() { func inner() { let x = true } }")
        let innerVisitor = TypeScopeVisitor()
        innerVisitor.walk(innerSource.syntax)

        guard let innerMutation = BooleanLiteralReplacement().mutations(in: innerSource).first,
            let scope = innerVisitor.innermostScope(containing: innerMutation.utf8Offset)
        else {
            Issue.record("Expected a mutation and scope")
            return
        }

        let outerScope = innerVisitor.scopes.max {
            ($0.bodyEndOffset - $0.bodyStartOffset) < ($1.bodyEndOffset - $1.bodyStartOffset)
        }!

        #expect(scope.bodyStartOffset > outerScope.bodyStartOffset)
    }
}
