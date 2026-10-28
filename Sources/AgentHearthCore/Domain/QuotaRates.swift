import Foundation

/// A model's list prices per token. Kept only to weigh token types against one
/// another when relating them to quota points — the subscription is not billed
/// by the token, but its quota tracks compute, and list prices are the public
/// measure of that.
public struct ModelPrice: Equatable, Sendable {
    public let input: Double
    public let cacheRead: Double
    public let cacheWrite: Double
    public let output: Double

    static func perMillion(input: Double, cacheRead: Double, cacheWrite: Double, output: Double) -> ModelPrice {
        ModelPrice(input: input / 1e6, cacheRead: cacheRead / 1e6, cacheWrite: cacheWrite / 1e6, output: output / 1e6)
    }

    /// What one token of input that was not read from cache costs. History
    /// stores fresh input and cache writes together. Claude Code's is almost
    /// entirely cache writes, mostly one-hour ones, so it is priced as such;
    /// OpenAI does not charge for writes, so for Codex it is plain input.
    func uncachedInput(for provider: AgentProviderID) -> Double {
        provider == .claudeCode ? cacheWrite : input
    }
}

public enum ModelPricing {
    /// First-party API list prices per million tokens (LiteLLM, 2026-10-13),
    /// for the models seen in use. Claude's cache write is the one-hour rate.
    /// A model missing here is left out of calibration rather than guessed at.
    static let table: [String: ModelPrice] = [
        "claude-opus-5-5": .perMillion(input: 4, cacheRead: 0.2, cacheWrite: 8, output: 20),
        "claude-opus-5": .perMillion(input: 5, cacheRead: 0.5, cacheWrite: 10, output: 25),
        "claude-fable-5-1": .perMillion(input: 10, cacheRead: 0.25, cacheWrite: 20, output: 50),
        "claude-fable-5": .perMillion(input: 10, cacheRead: 1, cacheWrite: 20, output: 50),
        "claude-sonnet-5-5": .perMillion(input: 2, cacheRead: 0.1, cacheWrite: 4, output: 10),
        "claude-sonnet-5": .perMillion(input: 2, cacheRead: 0.2, cacheWrite: 4, output: 10),
        "claude-sonnet-4-6": .perMillion(input: 3, cacheRead: 0.3, cacheWrite: 6, output: 15),
        "claude-haiku-5-5": .perMillion(input: 0.1, cacheRead: 0.01, cacheWrite: 0.2, output: 0.5),
        "claude-haiku-4-5-20251001": .perMillion(input: 1, cacheRead: 0.1, cacheWrite: 2, output: 5),
        "gpt-6.1-sol": .perMillion(input: 2, cacheRead: 0.1, cacheWrite: 2.5, output: 10),
        "gpt-6-sol": .perMillion(input: 2, cacheRead: 0.2, cacheWrite: 2.5, output: 10),
        "gpt-6-astra": .perMillion(input: 10, cacheRead: 1, cacheWrite: 12.5, output: 50),
        "gpt-6-luna": .perMillion(input: 0.1, cacheRead: 0.01, cacheWrite: 0.125, output: 0.5),
        "gpt-5.6-sol": .perMillion(input: 4, cacheRead: 0.4, cacheWrite: 5, output: 20),
        "gpt-5.6-terra": .perMillion(input: 2, cacheRead: 0.2, cacheWrite: 2.5, output: 12),
        "gpt-5.6-luna": .perMillion(input: 0.2, cacheRead: 0.02, cacheWrite: 0.25, output: 1.2),
    ]

    public static func price(for model: String?) -> ModelPrice? {
        model.flatMap { table[$0] }
    }
}

/// Tokens recorded for one request (or one turn, for agents recorded that way).
public struct TokenSpend: Equatable, Sendable {
    public let occurredAt: Date
    public let model: String?
    public let uncachedInput: Int
    public let cacheRead: Int
    public let output: Int

    public init(occurredAt: Date, model: String?, uncachedInput: Int, cacheRead: Int, output: Int) {
        self.occurredAt = occurredAt
        self.model = model
        self.uncachedInput = uncachedInput
        self.cacheRead = cacheRead
        self.output = output
    }

    var tokens: Int { uncachedInput + cacheRead + output }
}

/// Share of a usage window, in points, consumed per million tokens of each type.
public struct TokenTypeRates: Equatable, Sendable {
    public let uncachedInput: Double
    public let cacheRead: Double
    public let output: Double
}

/// What one point of a usage window costs, measured on recorded history.
public struct QuotaRateEstimate: Identifiable, Equatable, Sendable {
    public let providerID: AgentProviderID
    public let windowID: String
    public let windowLabel: String
    /// The model whose prices convert points into per-type rates: the one that
    /// carried most of the recorded tokens.
    public let referenceModel: String
    /// API-equivalent dollars per point of the window.
    public let dollarsPerPoint: Double
    /// Tokens of every type per point, at the observed mix.
    public let tokensPerPoint: Double
    /// Points of the window per million tokens of each type, at the reference
    /// model's prices — the figures to project another workload with.
    public let pointsPerMillion: TokenTypeRates
    public let cacheReadShare: Double
    public let increases: Int
    public let points: Double
    /// Spread of the kept increases, first to third quartile.
    public let dollarsPerPointRange: ClosedRange<Double>
    public let from: Date
    public let to: Date

    public var id: String { "\(providerID.rawValue):\(windowID)" }
}

/// Relates a usage window's rises to the tokens recorded while it rose.
///
/// Every rise of at least ``minimumRise`` points, between readings of the same
/// window period, becomes one measurement: the API-equivalent dollars of the
/// tokens recorded meanwhile, divided by the points gained. Percentages are
/// whole numbers, so shorter rises would be mostly rounding.
///
/// The window is account-wide while the tokens are only what this machine (and
/// any monitored host) recorded: use elsewhere — claude.ai, another computer, a
/// server — raises the window with no token to show for it, and can only make
/// a point look cheaper than it is. The quarter of rises cheapest per point,
/// the ones most likely to contain such use, are therefore left out, as are
/// rises with no recorded token at all. What remains is still an upper bound
/// on the share of the window a token takes, but a far tighter one.
public enum QuotaRateCalibrator {
    static let minimumRise = 3.0
    static let minimumKeptRises = 3

    public static func estimate(
        timeline: UsageTimeline,
        spends: [TokenSpend]
    ) -> QuotaRateEstimate? {
        let points = timeline.points.sorted { $0.measuredAt < $1.measuredAt }
        guard let first = points.first, let last = points.last else { return nil }
        let spends = spends.sorted { $0.occurredAt < $1.occurredAt }
        let times = spends.map(\.occurredAt)

        guard let reference = referenceModel(in: spends),
              let referencePrice = ModelPricing.price(for: reference)
        else { return nil }

        // A spend with no model is priced as the reference one; a model with no
        // known price is left out — it is usually a fallback, like Codex's
        // reserve, that draws on a different limit altogether.
        func cost(_ spend: TokenSpend) -> Double? {
            let price = spend.model.map { ModelPricing.price(for: $0) } ?? referencePrice
            guard let price else { return nil }
            return Double(spend.uncachedInput) * price.uncachedInput(for: timeline.providerID)
                + Double(spend.cacheRead) * price.cacheRead
                + Double(spend.output) * price.output
        }

        struct Rise { let points: Double; let dollars: Double; let tokens: Double; let cacheRead: Double }
        var rises: [Rise] = []
        var start = first
        for (previous, current) in zip(points, points.dropFirst()) {
            if current.usedFraction < previous.usedFraction - 0.005 {
                // The window reset; a rise cannot span two periods.
                start = current
                continue
            }
            let gained = (current.usedFraction - start.usedFraction) * 100
            guard gained >= minimumRise else { continue }
            let lower = upperBound(times, start.measuredAt)
            let upper = upperBound(times, current.measuredAt)
            var dollars = 0.0, tokens = 0.0, cacheRead = 0.0
            for spend in spends[lower..<upper] {
                guard let spent = cost(spend) else { continue }
                dollars += spent
                tokens += Double(spend.tokens)
                cacheRead += Double(spend.cacheRead)
            }
            if tokens > 0 {
                rises.append(Rise(points: gained, dollars: dollars, tokens: tokens, cacheRead: cacheRead))
            }
            start = current
        }

        let ranked = rises.sorted { $0.dollars / $0.points < $1.dollars / $1.points }
        let kept = Array(ranked.dropFirst(ranked.count / 4))
        guard kept.count >= minimumKeptRises else { return nil }

        let gained = kept.reduce(0) { $0 + $1.points }
        let dollars = kept.reduce(0) { $0 + $1.dollars }
        let tokens = kept.reduce(0) { $0 + $1.tokens }
        let cacheRead = kept.reduce(0) { $0 + $1.cacheRead }
        guard gained > 0, dollars > 0 else { return nil }
        let dollarsPerPoint = dollars / gained
        let perPoint = kept.map { $0.dollars / $0.points }

        return QuotaRateEstimate(
            providerID: timeline.providerID,
            windowID: timeline.windowID,
            windowLabel: timeline.label,
            referenceModel: reference,
            dollarsPerPoint: dollarsPerPoint,
            tokensPerPoint: tokens / gained,
            pointsPerMillion: TokenTypeRates(
                uncachedInput: referencePrice.uncachedInput(for: timeline.providerID) * 1e6 / dollarsPerPoint,
                cacheRead: referencePrice.cacheRead * 1e6 / dollarsPerPoint,
                output: referencePrice.output * 1e6 / dollarsPerPoint
            ),
            cacheReadShare: tokens > 0 ? cacheRead / tokens : 0,
            increases: kept.count,
            points: gained,
            dollarsPerPointRange: quartile(perPoint, 0.25)...quartile(perPoint, 0.75),
            from: first.measuredAt,
            to: last.measuredAt
        )
    }

    /// The priced model that carried most of the recorded tokens.
    static func referenceModel(in spends: [TokenSpend]) -> String? {
        var tokensByModel: [String: Int] = [:]
        for spend in spends {
            guard let model = spend.model, ModelPricing.price(for: model) != nil else { continue }
            tokensByModel[model, default: 0] += spend.tokens
        }
        return tokensByModel.max { $0.value < $1.value }?.key
    }

    /// Index of the first time strictly after `date`.
    private static func upperBound(_ times: [Date], _ date: Date) -> Int {
        var low = 0, high = times.count
        while low < high {
            let middle = (low + high) / 2
            if times[middle] <= date { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private static func quartile(_ values: [Double], _ q: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let position = q * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }
}
