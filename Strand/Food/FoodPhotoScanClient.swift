import Foundation

// MARK: - AI food photo scan (Claude vision, bring-your-own-key)
//
// A photo of a plate → an estimated food entry, the same shape a barcode lookup or online search
// result already produces (name + per-100g macros + a portion estimate), so it slots into
// `LogMealSheet`'s existing "select a result" flow without a new UI mode. Reuses the Anthropic key
// already stored by `AIKeyStore` (AI Coach, `Strand/AI/`) rather than a second, parallel key — one
// key, managed in one place (More → AI Coach), used by both features.

/// One AI-estimated food, in the same per-100g shape `FoodItemRow` already uses.
struct ScannedFood {
    let name: String
    let kcalPer100g: Double
    let proteinPer100g: Double
    let carbsPer100g: Double
    let fatPer100g: Double
    /// The model's guess at the portion size actually on the plate — prefills the quantity field,
    /// which stays fully editable before the entry is saved.
    let estimatedGrams: Double
}

enum FoodPhotoScanError: LocalizedError {
    case noKey
    case noFoodRecognized
    case badKey
    case rateLimited
    case server(Int, String)
    case network(String)
    case decode

    var errorDescription: String? {
        switch self {
        case .noKey:
            return "Add your Anthropic API key in More → AI Coach first to use photo scanning."
        case .noFoodRecognized:
            return "Couldn't recognize a food in that photo. Try a clearer, closer shot, or enter it by hand."
        case .badKey:
            return "That API key was rejected. Check it under More → AI Coach."
        case .rateLimited:
            return "Anthropic is rate-limiting requests right now. Wait a moment and try again."
        case .server(let code, let detail):
            let extra = detail.isEmpty ? "" : " - \(detail)"
            return "The provider returned an error (\(code))\(extra)."
        case .network(let detail):
            return "Network problem: \(detail)."
        case .decode:
            return "Couldn't read the estimate. Try again."
        }
    }

    /// Maps the shared HTTP-layer error (`AICoachError`, from `performRequest`) onto this file's own
    /// error type, so callers only ever handle one. `.noKey`/`.emptyQuestion`/`.keySaveFailed`/
    /// `.badCustomURL` never reach here — this file's own `AIKeyStore` guard runs first — but every
    /// case is still covered so this stays exhaustive if `AICoachError` grows a case later.
    fileprivate init(_ e: AICoachError) {
        switch e {
        case .badKey: self = .badKey
        case .rateLimited: self = .rateLimited
        case .server(let code, let detail): self = .server(code, detail)
        case .network(let detail): self = .network(detail)
        case .decode, .emptyReply: self = .decode
        case .noKey, .emptyQuestion, .keySaveFailed, .badCustomURL: self = .decode
        }
    }
}

enum FoodPhotoScanClient {
    private static let model = "claude-haiku-4-5-20251001"

    private static let prompt = """
    Identify the food in this photo and estimate its nutrition. Reply with ONLY a JSON object, no \
    other text, in exactly this shape:
    {"name": string, "kcalPer100g": number, "proteinPer100g": number, "carbsPer100g": number, \
    "fatPer100g": number, "estimatedGrams": number}

    - "name": a short, natural name for the food (e.g. "Grilled chicken breast with rice").
    - The four "...Per100g" fields: your best estimate for this type of food, per 100g.
    - "estimatedGrams": your best estimate of the actual portion size visible in the photo.
    - If multiple distinct foods are visible, combine them into one entry with blended per-100g \
    values and the total estimated weight.
    - If NO food is recognizable in the photo, reply with exactly: {"name": null}
    """

    /// Sends `imageData` (already downscaled by the caller) to Claude and parses the estimate.
    /// Requires an Anthropic key already stored via `AIKeyStore` (AI Coach's settings).
    static func scan(imageData: Data, session: URLSession = .shared) async throws -> ScannedFood {
        guard let key = AIKeyStore.read(), AIKeyStore.ownerProvider == AIProvider.anthropic.rawValue else {
            throw FoodPhotoScanError.noKey
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image", "source": [
                        "type": "base64", "media_type": "image/jpeg",
                        "data": imageData.base64EncodedString()
                    ]],
                    ["type": "text", "text": prompt]
                ]
            ]]
        ]

        var req = URLRequest(url: AIProvider.anthropic.endpoint)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json: [String: Any]
        do {
            // Reuses the same status-code → error mapping every other AI provider client uses
            // (`Strand/AI/AIProvider.swift`), just remapped to this file's own error type below so
            // callers only ever handle `FoodPhotoScanError`.
            json = try await performRequest(req, session: session)
        } catch let e as AICoachError {
            throw FoodPhotoScanError(e)
        }
        guard let content = json["content"] as? [[String: Any]],
              let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String
        else { throw FoodPhotoScanError.decode }

        return try parse(text)
    }

    /// Pure: extract the JSON object from the model's reply (tolerating stray whitespace or, rarely,
    /// a wrapping code fence) and decode it. No network — unit-testable.
    static func parse(_ text: String) throws -> ScannedFood {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            trimmed = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            if let firstBrace = trimmed.firstIndex(of: "{") { trimmed = String(trimmed[firstBrace...]) }
        }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw FoodPhotoScanError.decode }

        guard let name = obj["name"] as? String, !name.isEmpty else {
            throw FoodPhotoScanError.noFoodRecognized
        }
        func num(_ key: String) -> Double { (obj[key] as? NSNumber)?.doubleValue ?? 0 }
        return ScannedFood(
            name: name,
            kcalPer100g: num("kcalPer100g"),
            proteinPer100g: num("proteinPer100g"),
            carbsPer100g: num("carbsPer100g"),
            fatPer100g: num("fatPer100g"),
            estimatedGrams: max(1, num("estimatedGrams"))
        )
    }
}
