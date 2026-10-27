import Foundation

/// Starter suggestions, not a judgement about productivity. Match curated
/// identifiers only; browser names, aliases and arbitrary page titles never match.
public enum ServiceCategoryDefaults {
    private struct Rule {
        let category: String
        let apps: Set<String>
        let domains: Set<String>
    }

    private static let rules: [Rule] = [
        Rule(category: "work", apps: [
            "com.openai.chat", "com.openai.codex", "com.anthropic.claudefordesktop",
            "notion.id", "com.figma.desktop", "com.microsoft.vscode", "com.apple.dt.xcode",
            "dev.warp.warp-stable", "com.googlecode.iterm2", "com.apple.terminal",
            "com.microsoft.word", "com.microsoft.excel", "com.microsoft.powerpoint"
        ], domains: [
            "chatgpt.com", "chat.openai.com", "claude.ai", "notion.so", "notion.com",
            "figma.com", "github.com", "gitlab.com", "linear.app", "vscode.dev",
            "docs.google.com", "drive.google.com", "atlassian.net", "trello.com",
            "asana.com", "miro.com", "canva.com", "vercel.com", "netlify.com"
        ]),
        Rule(category: "learning", apps: [], domains: [
            "wikipedia.org", "coursera.org", "udemy.com", "edx.org", "khanacademy.org",
            "duolingo.com", "arxiv.org", "researchgate.net", "ieeexplore.ieee.org",
            "scholar.google.com", "stackoverflow.com", "developer.apple.com",
            "developer.mozilla.org", "news.hada.io"
        ]),
        Rule(category: "communication", apps: [
            "com.kakao.kakaotalkmac", "com.tinyspeck.slackmacgap", "com.apple.mail",
            "com.apple.ichat", "com.microsoft.outlook", "com.microsoft.teams2",
            "com.microsoft.teams", "us.zoom.xos", "com.hnc.discord",
            "ru.keepcoder.telegram", "net.whatsapp.whatsapp"
        ], domains: [
            "slack.com", "mail.google.com", "outlook.live.com", "outlook.office.com",
            "teams.microsoft.com", "meet.google.com", "zoom.us", "discord.com",
            "web.telegram.org", "web.whatsapp.com", "mail.naver.com"
        ]),
        Rule(category: "social", apps: [], domains: [
            "instagram.com", "linkedin.com", "facebook.com", "x.com", "twitter.com",
            "threads.net", "threads.com", "reddit.com", "bsky.app", "pinterest.com"
        ]),
        Rule(category: "entertainment", apps: [
            "com.spotify.client", "com.apple.music", "com.apple.tv", "com.valvesoftware.steam"
        ], domains: [
            "youtube.com", "youtu.be", "spotify.com", "netflix.com", "twitch.tv",
            "disneyplus.com", "tiktok.com", "music.apple.com", "tv.apple.com",
            "steampowered.com", "watcha.com", "tving.com", "wavve.com"
        ]),
        Rule(category: "personal", apps: [
            "com.apple.ical", "com.apple.reminders", "com.apple.photos", "com.apple.maps"
        ], domains: [
            "calendar.google.com", "maps.google.com", "amazon.com", "coupang.com",
            "hyundaihmall.com", "shop.pulmuone.co.kr", "shopping.naver.com",
            "booking.com", "airbnb.com"
        ])
    ]

    public static func categoryID(for source: Source) -> String? {
        let identifier = source.identifier.lowercased()
        return rules.first { rule in
            if source.kind == .app { return rule.apps.contains(identifier) }
            return rule.domains.contains { identifier == $0 || identifier.hasSuffix("." + $0) }
        }?.category
    }
}
