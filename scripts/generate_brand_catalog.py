#!/usr/bin/env python3
"""Generate curated offline brand_logos.json for GlassOTPCore from Simple Icons."""

import json
import re
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUTPUT_PATH = (
    ROOT
    / "Packages"
    / "GlassOTPCore"
    / "Sources"
    / "GlassOTPCore"
    / "Resources"
    / "brand_logos.json"
)

V16_DATA_URL = "https://cdn.jsdelivr.net/npm/simple-icons@16.38.1/data/simple-icons.json"
V11_DATA_URL = "https://cdn.jsdelivr.net/npm/simple-icons@11.15.0/_data/simple-icons.json"

# (slug, title, hex_override_or_none, category, domain, aliases)
SERVICES = [
    # --- Dev & Code ---
    ("github", "GitHub", None, "dev", "github.com", ["github", "github.com", "gh"]),
    ("gitlab", "GitLab", None, "dev", "gitlab.com", ["gitlab", "gitlab.com", "gitlab.vero.io"]),
    ("bitbucket", "Bitbucket", None, "dev", "bitbucket.org", ["bitbucket", "bitbucket.org"]),
    ("npm", "npm", None, "dev", "npmjs.com", ["npm", "npmjs", "npmjs.com"]),
    ("pypi", "PyPI", None, "dev", "pypi.org", ["pypi", "pypi.org", "python package index"]),
    ("rubygems", "RubyGems", None, "dev", "rubygems.org", ["rubygems", "rubygems.org"]),
    ("docker", "Docker", None, "dev", "docker.com", ["docker", "docker hub", "docker.com"]),
    ("vercel", "Vercel", None, "dev", "vercel.com", ["vercel", "vercel.com", "zeit"]),
    ("netlify", "Netlify", None, "dev", "netlify.com", ["netlify", "netlify.com"]),
    ("supabase", "Supabase", None, "dev", "supabase.com", ["supabase", "supabase.com"]),
    ("firebase", "Firebase", None, "dev", "firebase.google.com", ["firebase"]),
    ("sentry", "Sentry", None, "dev", "sentry.io", ["sentry", "sentry.io"]),
    ("datadog", "Datadog", None, "dev", "datadoghq.com", ["datadog", "datadoghq"]),
    ("grafana", "Grafana", None, "dev", "grafana.com", ["grafana", "grafana.com"]),
    ("pagerduty", "PagerDuty", None, "dev", "pagerduty.com", ["pagerduty", "pagerduty.com"]),
    ("postman", "Postman", None, "dev", "postman.com", ["postman", "postman.com"]),
    ("jetbrains", "JetBrains", None, "dev", "jetbrains.com", ["jetbrains", "jetbrains.com"]),
    ("linear", "Linear", None, "dev", "linear.app", ["linear", "linear.app"]),
    ("figma", "Figma", None, "dev", "figma.com", ["figma", "figma.com"]),
    ("openai", "OpenAI", "10A37F", "dev", "openai.com", ["openai", "chatgpt", "platform.openai.com"]),
    ("anthropic", "Anthropic", None, "dev", "anthropic.com", ["anthropic", "claude", "claude.ai"]),
    ("huggingface", "Hugging Face", None, "dev", "huggingface.co", ["huggingface", "hugging face"]),
    ("openrouter", "OpenRouter", None, "dev", "openrouter.ai", ["openrouter", "openrouter.ai"]),
    ("mongodb", "MongoDB", None, "dev", "mongodb.com", ["mongodb", "mongo", "mongodb atlas"]),
    ("elastic", "Elastic", None, "dev", "elastic.co", ["elastic", "elasticsearch", "elastic cloud"]),
    ("snowflake", "Snowflake", None, "dev", "snowflake.com", ["snowflake"]),
    ("twilio", "Twilio", None, "dev", "twilio.com", ["twilio", "twilio.com", "sendgrid"]),
    ("auth0", "Auth0", None, "dev", "auth0.com", ["auth0"]),
    ("okta", "Okta", None, "dev", "okta.com", ["okta", "okta.com"]),
    ("algolia", "Algolia", None, "dev", "algolia.com", ["algolia", "algolia.com"]),
    ("render", "Render", None, "dev", "render.com", ["render", "render.com"]),
    ("railway", "Railway", None, "dev", "railway.app", ["railway", "railway.app"]),
    ("flydotio", "Fly.io", None, "dev", "fly.io", ["fly.io", "flydotio"]),
    ("planetscale", "PlanetScale", None, "dev", "planetscale.com", ["planetscale"]),
    ("raycast", "Raycast", None, "dev", "raycast.com", ["raycast"]),
    ("expo", "Expo", None, "dev", "expo.dev", ["expo", "expo.dev"]),
    ("codecov", "Codecov", None, "dev", "codecov.io", ["codecov"]),
    ("snyk", "Snyk", None, "dev", "snyk.io", ["snyk"]),
    ("sonarqube", "SonarQube", None, "dev", "sonarsource.com", ["sonarqube", "sonarcloud", "sonarsource"]),
    ("circleci", "CircleCI", None, "dev", "circleci.com", ["circleci"]),
    ("travisci", "Travis CI", None, "dev", "travis-ci.com", ["travis ci", "travis-ci"]),
    ("gitea", "Gitea", None, "dev", "gitea.io", ["gitea"]),
    ("forgejo", "Forgejo", None, "dev", "forgejo.org", ["forgejo"]),
    ("launchpad", "Launchpad", None, "dev", "launchpad.net", ["launchpad"]),
    ("codeberg", "Codeberg", None, "dev", "codeberg.org", ["codeberg"]),
    ("resend", "Resend", None, "dev", "resend.com", ["resend"]),
    ("postmark", "Postmark", None, "dev", "postmarkapp.com", ["postmark"]),
    ("hashicorp", "HashiCorp", None, "dev", "hashicorp.com", ["hashicorp", "terraform", "vault"]),

    # --- Cloud & Infra ---
    ("amazonaws", "AWS", "FF9900", "cloud", "aws.amazon.com", ["aws", "amazon web services", "amazonaws", "aws.amazon.com"]),
    ("googlecloud", "Google Cloud", None, "cloud", "cloud.google.com", ["google cloud", "gcp", "cloud.google.com"]),
    ("microsoftazure", "Microsoft Azure", None, "cloud", "portal.azure.com", ["azure", "microsoft azure", "portal.azure.com"]),
    ("cloudflare", "Cloudflare", None, "cloud", "cloudflare.com", ["cloudflare", "dash.cloudflare.com"]),
    ("digitalocean", "DigitalOcean", None, "cloud", "digitalocean.com", ["digitalocean", "digital ocean"]),
    ("hetzner", "Hetzner", None, "cloud", "hetzner.com", ["hetzner", "hetzner cloud", "hetzner.de"]),
    ("ovh", "OVHcloud", None, "cloud", "ovhcloud.com", ["ovh", "ovhcloud", "ovh.com", "ovh.fr"]),
    ("scaleway", "Scaleway", None, "cloud", "scaleway.com", ["scaleway", "online.net"]),
    ("linode", "Linode", None, "cloud", "linode.com", ["linode", "akamai"]),
    ("vultr", "Vultr", None, "cloud", "vultr.com", ["vultr"]),
    ("heroku", "Heroku", None, "cloud", "heroku.com", ["heroku", "id.heroku.com"]),
    ("oracle", "Oracle Cloud", None, "cloud", "cloud.oracle.com", ["oracle", "oracle cloud", "oci"]),
    ("tailscale", "Tailscale", None, "cloud", "tailscale.com", ["tailscale", "login.tailscale.com"]),
    ("synology", "Synology", None, "cloud", "synology.com", ["synology", "dsm", "nas"]),
    ("proxmox", "Proxmox", None, "cloud", "proxmox.com", ["proxmox", "proxmox ve"]),
    ("ubiquiti", "Ubiquiti", None, "cloud", "ui.com", ["ubiquiti", "unifi", "ui.com"]),
    ("homeassistant", "Home Assistant", None, "cloud", "home-assistant.io", ["home assistant", "homeassistant", "hass"]),
    ("truenas", "TrueNAS", None, "cloud", "truenas.com", ["truenas", "freenas"]),
    ("pfsense", "pfSense", None, "cloud", "pfsense.org", ["pfsense"]),
    ("opnsense", "OPNsense", None, "cloud", "opnsense.org", ["opnsense"]),
    ("namecheap", "Namecheap", None, "cloud", "namecheap.com", ["namecheap"]),
    ("porkbun", "Porkbun", None, "cloud", "porkbun.com", ["porkbun"]),
    ("gandi", "Gandi", None, "cloud", "gandi.net", ["gandi", "gandi.net"]),
    ("godaddy", "GoDaddy", None, "cloud", "godaddy.com", ["godaddy"]),
    ("infomaniak", "Infomaniak", None, "cloud", "infomaniak.com", ["infomaniak"]),
    ("portainer", "Portainer", None, "cloud", "portainer.io", ["portainer"]),
    ("backblaze", "Backblaze", None, "cloud", "backblaze.com", ["backblaze"]),
    ("wasabi", "Wasabi", None, "cloud", "wasabi.com", ["wasabi"]),
    ("b2", "Cloudflare R2 / B2", None, "cloud", "backblaze.com", []),
    ("unraid", "Unraid", None, "cloud", "unraid.net", ["unraid"]),
    ("mikrotik", "MikroTik", None, "cloud", "mikrotik.com", ["mikrotik"]),
    ("linux", "Linux / SSH", None, "cloud", "kernel.org", ["linux", "ubuntu", "debian", "ssh"]),

    # --- Work & Productivity ---
    ("slack", "Slack", None, "work", "slack.com", ["slack", "slack.com"]),
    ("atlassian", "Atlassian", None, "work", "atlassian.com", ["atlassian", "id.atlassian.com"]),
    ("jira", "Jira", None, "work", "atlassian.com", ["jira"]),
    ("confluence", "Confluence", None, "work", "atlassian.com", ["confluence"]),
    ("notion", "Notion", None, "work", "notion.so", ["notion", "notion.so"]),
    ("microsoft", "Microsoft", "00A4EF", "work", "microsoft.com", ["microsoft", "office", "office 365", "microsoft 365", "entra", "live.com"]),
    ("zoom", "Zoom", None, "work", "zoom.us", ["zoom", "zoom.us"]),
    ("salesforce", "Salesforce", None, "work", "salesforce.com", ["salesforce"]),
    ("zendesk", "Zendesk", None, "work", "zendesk.com", ["zendesk"]),
    ("intercom", "Intercom", None, "work", "intercom.com", ["intercom"]),
    ("hubspot", "HubSpot", None, "work", "hubspot.com", ["hubspot"]),
    ("asana", "Asana", None, "work", "asana.com", ["asana"]),
    ("trello", "Trello", None, "work", "trello.com", ["trello"]),
    ("clickup", "ClickUp", None, "work", "clickup.com", ["clickup"]),
    ("mondaydotcom", "monday.com", None, "work", "monday.com", ["monday", "monday.com"]),
    ("airtable", "Airtable", None, "work", "airtable.com", ["airtable"]),
    ("miro", "Miro", None, "work", "miro.com", ["miro"]),
    ("loom", "Loom", None, "work", "loom.com", ["loom"]),
    ("calendly", "Calendly", None, "work", "calendly.com", ["calendly"]),
    ("docusign", "DocuSign", None, "work", "docusign.com", ["docusign"]),
    ("dropbox", "Dropbox", None, "work", "dropbox.com", ["dropbox"]),
    ("box", "Box", None, "work", "box.com", ["box.com"]),
    ("evernote", "Evernote", None, "work", "evernote.com", ["evernote"]),
    ("todoist", "Todoist", None, "work", "todoist.com", ["todoist"]),
    ("adobe", "Adobe", None, "work", "adobe.com", ["adobe", "adobe id"]),
    ("canva", "Canva", None, "work", "canva.com", ["canva"]),
    ("linkedin", "LinkedIn", None, "work", "linkedin.com", ["linkedin"]),
    ("fiverr", "Fiverr", None, "work", "fiverr.com", ["fiverr"]),
    ("upwork", "Upwork", None, "work", "upwork.com", ["upwork"]),
    ("deel", "Deel", None, "work", "deel.com", ["deel"]),
    ("webflow", "Webflow", None, "work", "webflow.com", ["webflow"]),
    ("framer", "Framer", None, "work", "framer.com", ["framer"]),
    ("zapier", "Zapier", None, "work", "zapier.com", ["zapier"]),
    ("make", "Make", None, "work", "make.com", ["make.com", "integromat"]),
    ("n8n", "n8n", None, "work", "n8n.io", ["n8n"]),

    # --- Finance & Crypto ---
    ("stripe", "Stripe", None, "finance", "stripe.com", ["stripe", "dashboard.stripe.com"]),
    ("paypal", "PayPal", None, "finance", "paypal.com", ["paypal", "paypal.com"]),
    ("revolut", "Revolut", None, "finance", "revolut.com", ["revolut"]),
    ("wise", "Wise", None, "finance", "wise.com", ["wise", "transferwise"]),
    ("n26", "N26", None, "finance", "n26.com", ["n26"]),
    ("coinbase", "Coinbase", None, "finance", "coinbase.com", ["coinbase"]),
    ("binance", "Binance", None, "finance", "binance.com", ["binance"]),
    ("americanexpress", "American Express", None, "finance", "americanexpress.com", ["american express", "amex"]),
    ("robinhood", "Robinhood", None, "finance", "robinhood.com", ["robinhood"]),
    ("chase", "Chase", None, "finance", "chase.com", ["chase"]),
    ("bankofamerica", "Bank of America", None, "finance", "bankofamerica.com", ["bank of america"]),
    ("venmo", "Venmo", None, "finance", "venmo.com", ["venmo"]),
    ("cashapp", "Cash App", None, "finance", "cash.app", ["cash app", "cashapp"]),
    ("bunq", "bunq", None, "finance", "bunq.com", ["bunq"]),
    ("monzo", "Monzo", None, "finance", "monzo.com", ["monzo"]),
    ("starlingbank", "Starling Bank", None, "finance", "starlingbank.com", ["starling"]),
    ("interactivebrokers", "Interactive Brokers", None, "finance", "interactivebrokers.com", ["interactive brokers", "ibkr"]),
    ("etoro", "eToro", None, "finance", "etoro.com", ["etoro"]),
    ("kucoin", "KuCoin", None, "finance", "kucoin.com", ["kucoin"]),
    ("bybit", "Bybit", None, "finance", "bybit.com", ["bybit"]),
    ("okx", "OKX", None, "finance", "okx.com", ["okx", "okex"]),
    ("bitstamp", "Bitstamp", None, "finance", "bitstamp.net", ["bitstamp"]),
    ("gemini", "Gemini Exchange", None, "finance", "gemini.com", ["gemini exchange"]),
    ("trezor", "Trezor", None, "finance", "trezor.io", ["trezor"]),

    # --- Security & Privacy ---
    ("1password", "1Password", None, "security", "1password.com", ["1password", "onepassword"]),
    ("bitwarden", "Bitwarden", None, "security", "bitwarden.com", ["bitwarden", "vaultwarden"]),
    ("proton", "Proton", None, "security", "proton.me", ["proton", "protonvpn", "proton drive", "proton pass", "proton.me"]),
    ("protonmail", "Proton Mail", None, "security", "mail.proton.me", ["protonmail", "proton mail"]),
    ("dashlane", "Dashlane", None, "security", "dashlane.com", ["dashlane"]),
    ("lastpass", "LastPass", None, "security", "lastpass.com", ["lastpass"]),
    ("nordvpn", "NordVPN", None, "security", "nordvpn.com", ["nordvpn", "nordaccount", "nord"]),
    ("mullvad", "Mullvad", None, "security", "mullvad.net", ["mullvad"]),
    ("expressvpn", "ExpressVPN", None, "security", "expressvpn.com", ["expressvpn"]),
    ("surfshark", "Surfshark", None, "security", "surfshark.com", ["surfshark"]),
    ("nextdns", "NextDNS", None, "security", "nextdns.io", ["nextdns"]),
    ("adguard", "AdGuard", None, "security", "adguard.com", ["adguard"]),
    ("simplelogin", "SimpleLogin", None, "security", "simplelogin.io", ["simplelogin"]),
    ("keepassxc", "KeePassXC", None, "security", "keepassxc.org", ["keepassxc", "keepass"]),
    ("yubico", "Yubico", None, "security", "yubico.com", ["yubico", "yubikey"]),
    ("duo", "Duo Security", None, "security", "duo.com", ["duo"]),
    ("tuta", "Tuta", None, "security", "tuta.com", ["tuta", "tutanota"]),
    ("tresorit", "Tresorit", None, "security", "tresorit.com", ["tresorit"]),
    ("mega", "MEGA", None, "security", "mega.nz", ["mega", "mega.nz"]),

    # --- Social & Media ---
    ("discord", "Discord", None, "social", "discord.com", ["discord", "discordapp"]),
    ("x", "X (Twitter)", None, "social", "x.com", ["x", "twitter", "x.com"]),
    ("instagram", "Instagram", None, "social", "instagram.com", ["instagram"]),
    ("facebook", "Facebook", None, "social", "facebook.com", ["facebook", "fb"]),
    ("meta", "Meta", None, "social", "meta.com", ["meta", "meta.com", "oculus"]),
    ("reddit", "Reddit", None, "social", "reddit.com", ["reddit"]),
    ("twitch", "Twitch", None, "social", "twitch.tv", ["twitch"]),
    ("youtube", "YouTube", None, "social", "youtube.com", ["youtube"]),
    ("spotify", "Spotify", None, "social", "spotify.com", ["spotify"]),
    ("netflix", "Netflix", None, "social", "netflix.com", ["netflix"]),
    ("plex", "Plex", None, "social", "plex.tv", ["plex", "plex.tv"]),
    ("telegram", "Telegram", None, "social", "telegram.org", ["telegram"]),
    ("signal", "Signal", None, "social", "signal.org", ["signal"]),
    ("whatsapp", "WhatsApp", None, "social", "whatsapp.com", ["whatsapp"]),
    ("bluesky", "Bluesky", None, "social", "bsky.app", ["bluesky", "bsky"]),
    ("mastodon", "Mastodon", None, "social", "joinmastodon.org", ["mastodon"]),
    ("tiktok", "TikTok", None, "social", "tiktok.com", ["tiktok"]),
    ("snapchat", "Snapchat", None, "social", "snapchat.com", ["snapchat"]),
    ("pinterest", "Pinterest", None, "social", "pinterest.com", ["pinterest"]),
    ("patreon", "Patreon", None, "social", "patreon.com", ["patreon"]),
    ("substack", "Substack", None, "social", "substack.com", ["substack"]),
    ("medium", "Medium", None, "social", "medium.com", ["medium"]),
    ("vimeo", "Vimeo", None, "social", "vimeo.com", ["vimeo"]),
    ("soundcloud", "SoundCloud", None, "social", "soundcloud.com", ["soundcloud"]),
    ("crunchyroll", "Crunchyroll", None, "social", "crunchyroll.com", ["crunchyroll"]),
    ("threads", "Threads", None, "social", "threads.net", ["threads"]),
    ("tumblr", "Tumblr", None, "social", "tumblr.com", ["tumblr"]),
    ("flickr", "Flickr", None, "social", "flickr.com", ["flickr"]),
    ("goodreads", "Goodreads", None, "social", "goodreads.com", ["goodreads"]),
    ("letterboxd", "Letterboxd", None, "social", "letterboxd.com", ["letterboxd"]),

    # --- Gaming ---
    ("steam", "Steam", None, "gaming", "steampowered.com", ["steam", "valve", "steampowered"]),
    ("playstation", "PlayStation", None, "gaming", "playstation.com", ["playstation", "psn", "sony playstation"]),
    ("xbox", "Xbox", None, "gaming", "xbox.com", ["xbox"]),
    ("nintendo", "Nintendo", None, "gaming", "nintendo.com", ["nintendo", "my nintendo"]),
    ("epicgames", "Epic Games", None, "gaming", "epicgames.com", ["epic games", "epicgames", "fortnite"]),
    ("battledotnet", "Battle.net", None, "gaming", "battle.net", ["battle.net", "battlenet", "blizzard"]),
    ("riotgames", "Riot Games", None, "gaming", "riotgames.com", ["riot", "riot games", "valorant", "league of legends"]),
    ("ubisoft", "Ubisoft", None, "gaming", "ubisoft.com", ["ubisoft", "uplay"]),
    ("ea", "EA", None, "gaming", "ea.com", ["ea", "electronic arts", "origin"]),
    ("roblox", "Roblox", None, "gaming", "roblox.com", ["roblox"]),
    ("gogdotcom", "GOG.com", None, "gaming", "gog.com", ["gog", "gog.com"]),
    ("humblebundle", "Humble Bundle", None, "gaming", "humblebundle.com", ["humble bundle", "humble"]),
    ("itchdotio", "itch.io", None, "gaming", "itch.io", ["itch.io", "itch"]),
    ("minecraft", "Minecraft", None, "gaming", "minecraft.net", ["minecraft", "mojang"]),
    ("faceit", "FACEIT", None, "gaming", "faceit.com", ["faceit"]),
    ("curseforge", "CurseForge", None, "gaming", "curseforge.com", ["curseforge"]),
    ("nexusmods", "Nexus Mods", None, "gaming", "nexusmods.com", ["nexus mods", "nexusmods"]),
    ("chessdotcom", "Chess.com", None, "gaming", "chess.com", ["chess.com", "chess"]),
    ("lichess", "Lichess", None, "gaming", "lichess.org", ["lichess"]),
    ("vrchat", "VRChat", None, "gaming", "vrchat.com", ["vrchat"]),
    ("rockstargames", "Rockstar Games", None, "gaming", "rockstargames.com", ["rockstar", "rockstar games"]),
    ("squareenix", "Square Enix", None, "gaming", "square-enix.com", ["square enix", "ffxiv"]),
    ("bungie", "Bungie", None, "gaming", "bungie.net", ["bungie", "destiny"]),

    # --- Shopping & Travel ---
    ("amazon", "Amazon", None, "shopping", "amazon.com", ["amazon", "amazon.com", "amazon.fr", "amazon.de", "amazon.co.uk"]),
    ("ebay", "eBay", None, "shopping", "ebay.com", ["ebay"]),
    ("shopify", "Shopify", None, "shopping", "shopify.com", ["shopify"]),
    ("airbnb", "Airbnb", None, "shopping", "airbnb.com", ["airbnb"]),
    ("uber", "Uber", None, "shopping", "uber.com", ["uber", "uber eats"]),
    ("vinted", "Vinted", None, "shopping", "vinted.com", ["vinted"]),
    ("ikea", "IKEA", None, "shopping", "ikea.com", ["ikea"]),
    ("airfrance", "Air France", None, "shopping", "airfrance.com", ["air france", "airfrance"]),
    ("sncf", "SNCF", None, "shopping", "sncf-connect.com", ["sncf", "sncf connect", "oui.sncf"]),
    ("bookingdotcom", "Booking.com", None, "shopping", "booking.com", ["booking", "booking.com"]),
    ("expedia", "Expedia", None, "shopping", "expedia.com", ["expedia"]),
    ("aliexpress", "AliExpress", None, "shopping", "aliexpress.com", ["aliexpress"]),
    ("etsy", "Etsy", None, "shopping", "etsy.com", ["etsy"]),
    ("walmart", "Walmart", None, "shopping", "walmart.com", ["walmart"]),
    ("target", "Target", None, "shopping", "target.com", ["target"]),
    ("zalando", "Zalando", None, "shopping", "zalando.com", ["zalando"]),
    ("fnac", "Fnac", None, "shopping", "fnac.com", ["fnac"]),
    ("deliveroo", "Deliveroo", None, "shopping", "deliveroo.com", ["deliveroo"]),
    ("doordash", "DoorDash", None, "shopping", "doordash.com", ["doordash"]),
    ("ryanair", "Ryanair", None, "shopping", "ryanair.com", ["ryanair"]),
    ("easyjet", "easyJet", None, "shopping", "easyjet.com", ["easyjet"]),
    ("lufthansa", "Lufthansa", None, "shopping", "lufthansa.com", ["lufthansa"]),
    ("klm", "KLM", None, "shopping", "klm.com", ["klm"]),
    ("britishairways", "British Airways", None, "shopping", "britishairways.com", ["british airways"]),
    ("delta", "Delta", None, "shopping", "delta.com", ["delta"]),
    ("unitedairlines", "United Airlines", None, "shopping", "united.com", ["united airlines"]),

    # --- Personal & Identity ---
    ("google", "Google", None, "personal", "google.com", ["google", "gmail", "googlemail", "google account"]),
    ("apple", "Apple", None, "personal", "apple.com", ["apple", "apple id", "apple account"]),
    ("icloud", "iCloud", None, "personal", "icloud.com", ["icloud"]),
    ("yahoo", "Yahoo", None, "personal", "yahoo.com", ["yahoo"]),
    ("maildotru", "Mail.ru", None, "personal", "mail.ru", ["mail.ru"]),
    ("gmx", "GMX", None, "personal", "gmx.net", ["gmx"]),
    ("wordPress", "WordPress", None, "personal", "wordpress.com", ["wordpress"]),
    ("nextcloud", "Nextcloud", None, "personal", "nextcloud.com", ["nextcloud"]),
    ("owncloud", "ownCloud", None, "personal", "owncloud.com", ["owncloud"]),
    ("bitly", "Bitly", None, "personal", "bitly.com", ["bitly"]),
    ("gravatar", "Gravatar", None, "personal", "gravatar.com", ["gravatar"]),
    ("duolingo", "Duolingo", None, "personal", "duolingo.com", ["duolingo"]),
    ("strava", "Strava", None, "personal", "strava.com", ["strava"]),
    ("garmin", "Garmin", None, "personal", "garmin.com", ["garmin"]),
    ("withings", "Withings", None, "personal", "withings.com", ["withings"]),
    ("fitbit", "Fitbit", None, "personal", "fitbit.com", ["fitbit"]),
    ("tesla", "Tesla", None, "personal", "tesla.com", ["tesla"]),
    ("philipshue", "Philips Hue", None, "personal", "meethue.com", ["philips hue", "hue"]),
    ("ring", "Ring", None, "personal", "ring.com", ["ring"]),
    ("sonos", "Sonos", None, "personal", "sonos.com", ["sonos"]),
    ("flickr", "Flickr", None, "personal", "flickr.com", []),
    ("wikimedia", "Wikimedia", None, "personal", "wikimedia.org", ["wikipedia", "wikimedia"]),
    ("stackexchange", "Stack Exchange", None, "personal", "stackexchange.com", ["stack exchange", "stackoverflow", "stack overflow"]),
]

# Services without Simple Icons vector SVGs (or web-logo-only services) still get exact category, color, aliases, and domain!
WEB_ONLY_SERVICES = [
    ("fastmail", "Fastmail", "2E5AAC", "security", "fastmail.com", ["fastmail", "fastmail.com"]),
    ("kraken", "Kraken", "5741D9", "finance", "kraken.com", ["kraken", "kraken.com"]),
    ("ledger", "Ledger", "1C1C1E", "finance", "ledger.com", ["ledger", "ledger live"]),
    ("qonto", "Qonto", "6D4AFF", "finance", "qonto.com", ["qonto"]),
    ("boursobank", "BoursoBank", "D6006E", "finance", "boursobank.com", ["boursobank", "boursorama"]),
    ("bnpparibas", "BNP Paribas", "00965E", "finance", "mabanque.bnpparibas", ["bnp", "bnp paribas", "bnpparibas"]),
    ("societegenerale", "Societe Generale", "E60028", "finance", "particuliers.sg.fr", ["societe generale", "sg.fr"]),
    ("creditagricole", "Credit Agricole", "007D8F", "finance", "credit-agricole.fr", ["credit agricole", "ca-"]),
    ("fortuneo", "Fortuneo", "00A859", "finance", "fortuneo.fr", ["fortuneo"]),
    ("lydia", "Lydia / Sumeria", "007AFF", "finance", "lydia-app.com", ["lydia", "sumeria"]),
    ("doctolib", "Doctolib", "107ACA", "personal", "doctolib.fr", ["doctolib"]),
    ("ameli", "Ameli", "0071B9", "personal", "ameli.fr", ["ameli", "cpam"]),
    ("impots", "impots.gouv.fr", "003B73", "finance", "impots.gouv.fr", ["impots", "impots.gouv"]),
    ("franceconnect", "FranceConnect", "000091", "personal", "franceconnect.gouv.fr", ["franceconnect", "france connect"]),
    ("swile", "Swile", "222222", "work", "swile.co", ["swile"]),
    ("alan", "Alan", "3E64FF", "work", "alan.com", ["alan", "alan.eu"]),
    ("vero", "VERO", "00A79D", "work", "vero.co", ["vero", "vero.io", "verolabs", "ojingo"]),
    ("leboncoin", "Leboncoin", "FF6E14", "shopping", "leboncoin.fr", ["leboncoin"]),
    ("blablacar", "BlaBlaCar", "00AFF5", "shopping", "blablacar.fr", ["blablacar"]),
    ("free", "Free", "CD1E25", "personal", "free.fr", ["freebox", "mobile.free.fr"]),
    ("orange", "Orange", "FF7900", "personal", "orange.fr", ["orange.fr", "sosh"]),
]


def fetch_json(url: str):
    req = urllib.request.Request(url, headers={"User-Agent": "GlassOTP/1.0"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read().decode("utf-8"))


def index_icons(raw):
    items = raw if isinstance(raw, list) else raw.get("icons", [])
    by_slug = {}
    for item in items:
        slug = item.get("slug")
        if not slug:
            title = item["title"].lower()
            slug = (
                title.replace("+", "plus")
                .replace(".", "dot")
                .replace("&", "and")
                .replace(" ", "")
                .replace("-", "")
            )
        by_slug[slug.lower()] = item
    return by_slug


def fetch_svg_path(slug: str, ver: str) -> str | None:
    url = f"https://cdn.jsdelivr.net/npm/simple-icons@{ver}/icons/{slug}.svg"
    req = urllib.request.Request(url, headers={"User-Agent": "GlassOTP/1.0"})
    try:
        svg = urllib.request.urlopen(req, timeout=15).read().decode("utf-8")
    except Exception:
        return None
    paths = re.findall(r'<path[^>]*\sd="([^"]+)"', svg)
    if not paths:
        return None
    return " ".join(paths)


def main():
    print("Fetching Simple Icons catalogs (v16.38.1 + v11.15.0 fallback)...")
    v16 = index_icons(fetch_json(V16_DATA_URL))
    v11 = index_icons(fetch_json(V11_DATA_URL))

    seen_slugs = set()
    tasks = []
    entries = {}

    for raw_slug, title, hex_override, category, domain, aliases in SERVICES:
        slug = raw_slug.lower()
        if slug in seen_slugs:
            continue
        seen_slugs.add(slug)

        if slug in v16:
            meta = v16[slug]
            ver = "16.38.1"
        elif slug in v11:
            meta = v11[slug]
            ver = "11.15.0"
        else:
            print(f"WARN: slug '{slug}' not found in v16 or v11, skipping", file=sys.stderr)
            continue

        canonical_slug = meta.get("slug", slug).lower()
        hex_code = (hex_override or meta["hex"]).lstrip("#").upper()
        entries[slug] = {
            "slug": slug,
            "title": title,
            "hex": hex_code,
            "category": category,
            "domain": domain,
            "aliases": sorted(set(a.lower() for a in aliases if a)),
            "svgPath": None,
        }
        tasks.append((slug, canonical_slug, ver))

    print(f"Fetching {len(tasks)} SVG vector paths...")
    with ThreadPoolExecutor(max_workers=20) as pool:
        future_map = {
            pool.submit(fetch_svg_path, canonical_slug, ver): slug
            for slug, canonical_slug, ver in tasks
        }
        missing_svg = []
        for fut in as_completed(future_map):
            slug = future_map[fut]
            path = fut.result()
            if path:
                entries[slug]["svgPath"] = path
            else:
                missing_svg.append(slug)

    if missing_svg:
        print(f"WARN: missing SVG paths for: {missing_svg}", file=sys.stderr)

    for slug, title, hex_code, category, domain, aliases in WEB_ONLY_SERVICES:
        if slug in seen_slugs:
            continue
        seen_slugs.add(slug)
        entries[slug] = {
            "slug": slug,
            "title": title,
            "hex": hex_code.lstrip("#").upper(),
            "category": category,
            "domain": domain,
            "aliases": sorted(set(a.lower() for a in aliases if a)),
            "svgPath": None,
        }

    ordered = sorted(entries.values(), key=lambda x: x["title"].lower())
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(json.dumps(ordered, separators=(",", ":")), encoding="utf-8")

    with_svg = sum(1 for e in ordered if e["svgPath"])
    size_kb = OUTPUT_PATH.stat().st_size / 1024
    print(f"Wrote {len(ordered)} brands ({with_svg} with offline SVG paths) to {OUTPUT_PATH} ({size_kb:.1f} KB)")


if __name__ == "__main__":
    main()
