//
//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.
//

import Foundation

@objc public class DisplayableText: NSObject {

    private struct Content {
        let attributedText: NSAttributedString
        let naturalAlignment: NSTextAlignment
    }

    private var fullContent: Content
    private var truncatedContent: Content?

    @objc
    public var fullAttributedText: NSAttributedString {
        return fullContent.attributedText
    }

    @objc
    public var fullTextNaturalAlignment: NSTextAlignment {
        return fullContent.naturalAlignment
    }

    @objc
    public var displayAttributedText: NSAttributedString {
        return truncatedContent?.attributedText ?? fullContent.attributedText
    }

    @objc
    public var displayTextNaturalAlignment: NSTextAlignment {
        return truncatedContent?.naturalAlignment ?? fullContent.naturalAlignment
    }

    @objc
    public var isTextTruncated: Bool {
        return truncatedContent != nil
    }

    @objc public let jumbomojiCount: UInt

    @objc
    static let kMaxJumbomojiCount: UInt = 5

    // This value is a bit arbitrary since we don't need to be 100% correct about 
    // rendering "Jumbomoji".  It allows us to place an upper bound on worst-case
    // performacne.
    @objc
    static let kMaxCharactersPerEmojiCount: UInt = 10

    // MARK: Initializers

    private init(fullContent: Content, truncatedContent: Content?) {
        self.fullContent = fullContent
        self.truncatedContent = truncatedContent
        self.jumbomojiCount = DisplayableText.jumbomojiCount(in: fullContent.attributedText.string)

        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: .ThemeDidChange,
            object: nil
        )
    }

    @objc private func themeDidChange() {
        // When the theme changes, we must refresh any mention attributes.
        let mutableFullText = NSMutableAttributedString(attributedString: fullAttributedText)
        Mention.refreshAttributes(in: mutableFullText)
        fullContent = Content(
            attributedText: mutableFullText,
            naturalAlignment: fullContent.naturalAlignment
        )

        if let truncatedContent = truncatedContent {
            let mutableTruncatedText = NSMutableAttributedString(attributedString: truncatedContent.attributedText)
            Mention.refreshAttributes(in: mutableTruncatedText)
            self.truncatedContent = Content(
                attributedText: mutableTruncatedText,
                naturalAlignment: truncatedContent.naturalAlignment
            )
        }
    }

    // MARK: Emoji

    // If the string is...
    //
    // * Non-empty
    // * Only contains emoji
    // * Contains <= kMaxJumbomojiCount emoji
    //
    // ...return the number of emoji (to be treated as "Jumbomoji") in the string.
    private class func jumbomojiCount(in string: String) -> UInt {
        if string == "" {
            return 0
        }
        if string.count > Int(kMaxJumbomojiCount * kMaxCharactersPerEmojiCount) {
            return 0
        }
        guard string.containsOnlyEmoji else {
            return 0
        }
        let emojiCount = string.glyphCount
        if UInt(emojiCount) > kMaxJumbomojiCount {
            return 0
        }
        return UInt(emojiCount)
    }

    // For perf we use a static linkDetector. It doesn't change and building DataDetectors is
    // surprisingly expensive. This should be fine, since NSDataDetector is an NSRegularExpression
    // and NSRegularExpressions are thread safe.
    private static let linkDetector: NSDataDetector? = {
        return try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    private static let hostRegex: NSRegularExpression? = {
        let pattern = "^(?:https?:\\/\\/)?([^:\\/\\s]+)(.*)?$"
        return try? NSRegularExpression(pattern: pattern)
    }()

    @objc
    public lazy var shouldAllowLinkification: Bool = {
        guard let linkDetector: NSDataDetector = DisplayableText.linkDetector else {
            owsFailDebug("linkDetector was unexpectedly nil")
            return false
        }

        func isValidLink(linkText: String) -> Bool {
            guard let hostRegex = DisplayableText.hostRegex else {
                owsFailDebug("hostRegex was unexpectedly nil")
                return false
            }

            guard let hostText = hostRegex.parseFirstMatch(inText: linkText) else {
                owsFailDebug("hostText was unexpectedly nil")
                return false
            }

            let strippedHost = hostText.replacingOccurrences(of: ".", with: "") as NSString

            if strippedHost.isOnlyASCII {
                return true
            } else if strippedHost.hasAnyASCII {
                // mix of ascii and non-ascii is invalid
                return false
            } else {
                // IDN
                return true
            }
        }

        let rawText = fullAttributedText.string

        for match in linkDetector.matches(in: rawText, options: [], range: NSRange(location: 0, length: rawText.utf16.count)) {
            guard let matchURL: URL = match.url else {
                continue
            }

            // We extract the exact text from the `fullText` rather than use match.url.host
            // because match.url.host actually escapes non-ascii domains into puny-code.
            //
            // But what we really want is to check the text which will ultimately be presented to
            // the user.
            let rawTextOfMatch = (rawText as NSString).substring(with: match.range)
            guard isValidLink(linkText: rawTextOfMatch) else {
                return false
            }
        }
        return true
    }()

    // MARK: Filter Methods

    @objc
    public class var empty: DisplayableText {
        return DisplayableText(
            fullContent: .init(attributedText: .init(string: ""), naturalAlignment: .natural),
            truncatedContent: nil
        )
    }

    @objc
    public class func displayableTextForTests(_ text: String) -> DisplayableText {
        return DisplayableText(
            fullContent: .init(attributedText: .init(string: text), naturalAlignment: text.naturalTextAlignment),
            truncatedContent: nil
        )
    }

    @objc
    public class func displayableText(withMessageBody messageBody: MessageBody, mentionStyle: Mention.Style, transaction: SDSAnyReadTransaction) -> DisplayableText {
        let fullAttributedText = messageBody.attributedBody(
            style: mentionStyle,
            attributes: [:],
            shouldResolveAddress: { _ in true }, // Resolve all mentions in messages.
            transaction: transaction.unwrapGrdbRead
        )
        let fullContent = Content(
            attributedText: fullAttributedText,
            naturalAlignment: fullAttributedText.string.naturalTextAlignment
        )

        // Only show up to N characters of text.
        let kMaxTextDisplayLength = 512
        let truncatedContent: Content?
        if fullAttributedText.string.count > kMaxTextDisplayLength {

            var mentionRange = NSRange()
            let possibleOverlappingMention = fullAttributedText.attribute(
                .mention,
                at: kMaxTextDisplayLength,
                longestEffectiveRange: &mentionRange,
                in: NSRange(location: 0, length: fullAttributedText.length)
            )

            var snippetLength = kMaxTextDisplayLength

            // There's a mention overlapping our normal truncate point, we want to truncate sooner
            // so we don't "split" the mention.
            if possibleOverlappingMention != nil && mentionRange.location < kMaxTextDisplayLength {
                snippetLength = mentionRange.location
            }

            // Trim whitespace before _AND_ after slicing the snipper from the string.
            let truncatedAttributedText = fullAttributedText
                .attributedSubstring(from: NSRange(location: 0, length: snippetLength))
                .ows_stripped()
                .stringByAppendingString("…")

            truncatedContent = Content(
                attributedText: truncatedAttributedText,
                naturalAlignment: truncatedAttributedText.string.naturalTextAlignment
            )
        } else {
            truncatedContent = nil
        }

        return DisplayableText(fullContent: fullContent, truncatedContent: truncatedContent)
    }
}
