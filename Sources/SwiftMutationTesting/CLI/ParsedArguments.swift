struct ParsedArguments: Sendable {
    init(
        projectPath: String = ".",
        showVersion: Bool = false,
        showHelp: Bool = false,
        showInit: Bool = false,
        build: BuildOptions = BuildOptions(),
        reporting: ReportingOptions = ReportingOptions(),
        filter: FilterOptions = FilterOptions(),
        cache: CacheOptions = CacheOptions()
    ) {
        self.projectPath = projectPath
        self.showVersion = showVersion
        self.showHelp = showHelp
        self.showInit = showInit
        self.build = build
        self.reporting = reporting
        self.filter = filter
        self.cache = cache
    }

    var projectPath: String
    var showVersion: Bool
    var showHelp: Bool
    var showInit: Bool
    var build: BuildOptions
    var reporting: ReportingOptions
    var filter: FilterOptions
    var cache: CacheOptions

    struct CacheOptions: Sendable {
        enum Mode: Sendable {
            case legacy
            case legacyBenchmark
            case prepare
            case target
            case recover
            case simulatorPrepare
            case simulatorCleanup
        }

        init(
            mode: Mode = .legacy,
            buildCacheRoot: String? = nil,
            compatibilityID: String? = nil,
            projectInputManifest: String? = nil,
            testEnumerationOutput: String? = nil,
            mutantInventoryOutput: String? = nil,
            mutantSelectionManifest: String? = nil,
            evidenceOutput: String? = nil,
            custodyFD: Int? = nil,
            invocationNonce: String? = nil,
            simulatorRegistration: String? = nil,
            buildCountEvidenceOutput: String? = nil,
            guideLockFD: Int? = nil,
            wrapperLeaseFD: Int? = nil,
            runOrdinal: Int? = nil,
            attemptOrdinal: Int? = nil
        ) {
            self.mode = mode
            self.buildCacheRoot = buildCacheRoot
            self.compatibilityID = compatibilityID
            self.projectInputManifest = projectInputManifest
            self.testEnumerationOutput = testEnumerationOutput
            self.mutantInventoryOutput = mutantInventoryOutput
            self.mutantSelectionManifest = mutantSelectionManifest
            self.evidenceOutput = evidenceOutput
            self.custodyFD = custodyFD
            self.invocationNonce = invocationNonce
            self.simulatorRegistration = simulatorRegistration
            self.buildCountEvidenceOutput = buildCountEvidenceOutput
            self.guideLockFD = guideLockFD
            self.wrapperLeaseFD = wrapperLeaseFD
            self.runOrdinal = runOrdinal
            self.attemptOrdinal = attemptOrdinal
        }

        var mode: Mode
        var buildCacheRoot: String?
        var compatibilityID: String?
        var projectInputManifest: String?
        var testEnumerationOutput: String?
        var mutantInventoryOutput: String?
        var mutantSelectionManifest: String?
        var evidenceOutput: String?
        var custodyFD: Int?
        var invocationNonce: String?
        var simulatorRegistration: String?
        var buildCountEvidenceOutput: String?
        var guideLockFD: Int?
        var wrapperLeaseFD: Int?
        var runOrdinal: Int?
        var attemptOrdinal: Int?
    }

    struct BuildOptions: Sendable {
        init(
            scheme: String? = nil,
            destination: String? = nil,
            testTarget: String? = nil,
            timeout: Double? = nil,
            concurrency: Int? = nil,
            noCache: Bool = false,
            testingFramework: String? = nil
        ) {
            self.scheme = scheme
            self.destination = destination
            self.testTarget = testTarget
            self.timeout = timeout
            self.concurrency = concurrency
            self.noCache = noCache
            self.testingFramework = testingFramework
        }

        var scheme: String?
        var destination: String?
        var testTarget: String?
        var timeout: Double?
        var concurrency: Int?
        var noCache: Bool
        var testingFramework: String?
    }

    struct ReportingOptions: Sendable {
        init(output: String? = nil, htmlOutput: String? = nil, sonarOutput: String? = nil, quiet: Bool = false) {
            self.output = output
            self.htmlOutput = htmlOutput
            self.sonarOutput = sonarOutput
            self.quiet = quiet
        }

        var output: String?
        var htmlOutput: String?
        var sonarOutput: String?
        var quiet: Bool
    }

    struct FilterOptions: Sendable {
        init(
            sourcesPath: String? = nil,
            excludePatterns: [String] = [],
            operators: [String] = [],
            disabledMutators: [String] = []
        ) {
            self.sourcesPath = sourcesPath
            self.excludePatterns = excludePatterns
            self.operators = operators
            self.disabledMutators = disabledMutators
        }

        var sourcesPath: String?
        var excludePatterns: [String]
        var operators: [String]
        var disabledMutators: [String]
    }
}
