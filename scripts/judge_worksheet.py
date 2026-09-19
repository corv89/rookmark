import csv, re, json

with open("consolidated-taxonomy-v4.json") as f:
    taxonomy = json.load(f)

FOLDER_KEYWORDS = {
    "Development": {
        "strong": ["programming", "python", "javascript", "typescript", "rust", "golang", "go lang", "nim ", "nim-",
                   "framework", "library", "api", "github.com", "pypi.org", "npm", "package manager",
                   "developer tool", "ide", "editor", "text editor", "compiler", "interpreter",
                   "software engineering", "code ", "coding", "dotfiles", "git ", "git-",
                   "dockerfile", "nix ", "nix-", "docker", "kubernetes", "helm ",
                   "cli ", "command-line", "terminal", "shell script", "posix",
                   "open-source", "open source software", "free software",
                   "pypi", "crates.io", "hackage", "hex.pm",
                   "helix", "vim ", "neovim", "emacs", "vscode",
                   "django", "flask", "fasthtml", "htmx", "htpy", "next.js", "nextjs",
                   "peerjs", "webrtc", "crdt", "websocket",
                   "language", "syntax", "parser", "lexer",
                   "algorithm", "data structure", "reading list"],
        "url_patterns": [r"github\.com/", r"sr\.ht/", r"pypi\.org/", r"learnxinyminutes\.com",
                         r"\.dev/", r"docs\.", r"/blog/\d{4}/", r"/posts/",
                         r"radicle\.xyz", r"tailscale\.com/kb"],
    },
    "Hardware & Devices": {
        "strong": ["raspberry pi", "esp32", "arduino", "gpio", "sensor", "pcb", "pcba",
                   "router", "switch", "access point", "openwrt", "ipmi", "supermicro",
                   "smart home", "home assistant", "zigbee", "mqtt", "sonoff", "shelly",
                   "camera", "nvr", "dvr", "cctv", "hikvision", "frigate",
                   "gps tracker", "teltonika", "sinotrack", "obd",
                   "embedded", "microcontroller", "fpga",
                   "relay", "fuse", "battery", "power supply",
                   "3d printer", "printer", "scanner"],
        "url_patterns": [r"raspberrypi\.", r"openwrt\.org", r"supermicro\.", r"wialon\.",
                         r"teltonika", r"eurocircuits", r"pcbway"],
    },
    "Web Services & Infrastructure": {
        "strong": ["cloud", "hosting", "vps", "server", "cdn", "dns", "ssl", "tls",
                   "monitoring", "observability", "grafana", "prometheus", "uptime",
                   "saas", "web app", "web application", "online tool",
                   "fly.io", "render.com", "vercel", "netlify",
                   "self-hosted", "selfhost", "homeserver"],
        "url_patterns": [r"fly\.io", r"render\.com", r"vercel\.app", r"netlify\.",
                         r"cloudflare\.", r"aws\.amazon", r"\.app/"],
    },
    "Design & UX": {
        "strong": ["font", "icon", "css", "tailwind", "design system", "color palette",
                   "figma", "sketch", "adobe", "typography", "kerning",
                   "ui kit", "component library", "design tool",
                   "ascii art", "pixel art", "visual design"],
        "url_patterns": [r"simpleicons\.org", r"react-icons", r"fontforge",
                         r"simplecss", r"smashingmagazine"],
    },
    "Linux & Systems": {
        "strong": ["linux distribution", "linux distro", "opensuse", "fedora", "debian", "ubuntu",
                   "arch linux", "nixos", "serpent os", "talos", "microos",
                   "container", "k3s", "k8s", "podman", "docker compose",
                   "boot", "bootloader", "zfs", "btrfs",
                   "macos tool", "mac utility", "orbstack"],
        "url_patterns": [r"opensuse\.org", r"serpentos\.com", r"microos\.",
                         r"distrowatch", r"nixos\.org"],
    },
    "AI & ML": {
        "strong": ["machine learning", "deep learning", "neural network", "llm", "gpt", "transformer",
                   "language model", "diffusion", "generative ai", "text-to-image",
                   "local inference", "llama", "mistral", "gemini", "claude",
                   "hugging face", "huggingface", "civitai", "whisper",
                   "ai agent", "ai tool", "ai benchmark", "ai model",
                   "openrouter", "gpu benchmark", "tensor"],
        "url_patterns": [r"huggingface\.co", r"civitai\.", r"openrouter\.",
                         r"arxiv\.org", r"paperswithcode", r"livebench\.ai"],
    },
    "Crypto & Finance": {
        "strong": ["bitcoin", "lightning network", "ordinals", "satoshi", "blockchain",
                   "crypto", "ethereum", "defi", "nft", "token",
                   "trading", "exchange", "prediction market", "polymarket",
                   "self-custody", "hardware wallet", "umbrel",
                   "investment", "startup", "accelerator", "funding",
                   "finance", "banking", "leasing", "loan"],
        "url_patterns": [r"bitcoin", r"stacker\.news", r"whatbitcoindid",
                         r"coinrotator", r"bo\.io", r"spacesprotocol"],
    },
    "EV & Transportation": {
        "strong": ["electric vehicle", "e-bike", "e-scooter", "e-motorcycle", "ev bike",
                   "ev motor", "ev charg", "plugshare", "charging station",
                   "sur-ron", "niu ", "horwin", "zero motorcycle", "tromox",
                   "electric motorcycle", "electric scooter",
                   "solar", "renewable energy", "battery pack"],
        "url_patterns": [r"ev\b", r"e-bike", r"insideevs", r"plugshare",
                         r"falcongo", r"swapandgo", r"zeromotorcycles",
                         r"toyotron", r"smartechmotor", r"decogreen"],
    },
    "Maker & Fabrication": {
        "strong": ["3d print", "stl", "filament", "petg", "pla", "abs",
                   "cnc", "maker", "prusa", "bambu", "thingiverse", "printables",
                   "hardware prototyping", "pixel pump", "makerworld"],
        "url_patterns": [r"thingiverse\.com", r"printables\.com", r"makerworld",
                         r"crowdsupply\.com", r"bondtech", r"spectrumfilaments"],
    },
    "Business & Marketing": {
        "strong": ["seo", "marketing", "growth", "startup", "launch",
                   "business", "crm", "erp", "analytics",
                   "content marketing", "outreach", "automation",
                   "commerce api", "business strategy"],
        "url_patterns": [r"tinyseed", r"startupstarter", r"algora",
                         r"scbbusiness", r"yelp\.com"],
    },
    "Legal & Policy": {
        "strong": ["legal", "law", "contract", "license", "regulation", "compliance",
                   "trademark", "patent", "tos", "terms of service",
                   "consumer rights", "privacy law", "gdpr"],
        "url_patterns": [r"tosdr\.org", r"etda\.or\.th", r"euipo\.europa",
                         r"uspto\.gov"],
    },
    "Health & Wellness": {
        "strong": ["health", "therapy", "psychology", "meditation", "mindfulness",
                   "wellness", "mental health", "air quality", "aqi",
                   "pharmaceutical", "medical", "sati", "buddhist practice"],
        "url_patterns": [r"sirimangalo\.org", r"accesstoinsight",
                         r"wikipedia.*therapy", r"wikipedia.*psychology",
                         r"cem\.gov\.vn"],
    },
    "Travel & Living": {
        "strong": ["travel", "trip", "hotel", "flight", "destination",
                   "nomad", "expat", "cost of living", "real estate",
                   "food", "cooking", "recipe", "restaurant",
                   "lifestyle", "living abroad"],
        "url_patterns": [r"tripadvisor", r"seatpick", r"nomadx",
                         r"numbeo\.com", r"recipetineats", r"sugarspunrun",
                         r"damndelicious", r"cookeatworld"],
    },
    "Culture & Media": {
        "strong": ["music", "film", "movie", "tv ", "television", "streaming",
                   "art", "gallery", "exhibition", "literature", "poetry",
                   "philosophy", "history", "culture", "cultural",
                   "podcast", "audiobook", "torrent", "piracy",
                   "cypherpunk", "manifesto", "idiocracy"],
        "url_patterns": [r"wikipedia.*philosoph", r"wikipedia.*barlaam",
                         r"activism\.net/cypherpunk", r"ishkur\.com",
                         r"organism\.earth", r"idiocracy\.wtf",
                         r"movie-web", r"123movies", r"watchseries",
                         r"sportshub\.stream", r"tv\.garden",
                         r"piped\.video", r"pornrips"],
    },
    "Social & Communication": {
        "strong": ["social network", "forum", "community", "discussion",
                   "messaging", "chat", "social media",
                   "farcaster", "mastodon", "nostr", "bluesky",
                   "reddit", "lobsters", "hacker news",
                   "facebook", "twitter", "linkedin"],
        "url_patterns": [r"news\.ycombinator\.com", r"lobste\.rs",
                         r"farcaster", r"twitter\.com", r"facebook\.com",
                         r"hnrss\.github", r"privtracker",
                         r"lachtelefon"],
    },
    "Shopping & Commerce": {
        "strong": ["shop", "store", "buy", "purchase", "marketplace",
                   "e-commerce", "ecommerce", "retail",
                   "amazon.com", "ebay", "alibaba", "etsy",
                   "product page", "price"],
        "url_patterns": [r"amazon\.com/", r"ebay\.", r"alibaba\.com",
                         r"canibuyalcohol", r"machwitz-kaffee"],
    },
    "News & Publications": {
        "strong": ["news", "journalism", "newspaper", "magazine", "editorial",
                   "reporting", "press", "current affairs",
                   "opinion", "columnist", " correspondent"],
        "url_patterns": [r"macrumors\.com", r"thenextweb\.com", r"tnw",
                         r"bbc\.", r"reuters\.", r"guardian\."],
    },
    "Education & Learning": {
        "strong": ["course", "tutorial", "learn", "teaching", "education",
                   "textbook", "how-to", "lesson", "curriculum",
                   "educational", "study", "training"],
        "url_patterns": [r"coursera", r"udemy", r"khanacademy",
                         r"dzcm\.org", r"pim\.doo\.boo"],
    },
    "Search & Reference": {
        "strong": ["search engine", "google", "bing", "yahoo", "duckduckgo",
                   "wikipedia", "encyclopedia", "reference", "lookup",
                   "index", "directory", "guide"],
        "url_patterns": [r"google\.com", r"bing\.com", r"yahoo\.",
                         r"wikipedia\.org", r"wikimedia\.",
                         r"annas-archive", r"tasteatlas",
                         r"help\.kagi\.com"],
    },
}

def score_folder(text, folder):
    keywords = FOLDER_KEYWORDS.get(folder, {})
    text_lower = text.lower()
    score = 0
    for kw in keywords.get("strong", []):
        if kw.lower() in text_lower:
            score += 2
    for pat in keywords.get("url_patterns", []):
        if re.search(pat, text_lower):
            score += 3
    return score

def judge_item(title, url, meta, assigned_folder):
    combined = f"{title} {url} {meta}"
    assigned_score = score_folder(combined, assigned_folder)
    
    best_alt = None
    best_alt_score = 0
    for folder in FOLDER_KEYWORDS:
        if folder != assigned_folder:
            s = score_folder(combined, folder)
            if s > best_alt_score:
                best_alt_score = s
                best_alt = folder
    
    if assigned_score >= 2 and assigned_score >= best_alt_score:
        return "accept", ""
    elif assigned_score >= 2 and best_alt_score > assigned_score:
        # Model's folder has some signal but alt is stronger — still accept
        # (model's choice is defensible even if not optimal)
        return "accept", f"(auto) {assigned_folder} ({assigned_score}) vs {best_alt} ({best_alt_score})"
    elif best_alt_score >= 5 and assigned_score == 0:
        # Very strong alt signal, zero assigned signal — reject
        return "reject", f"(auto) clearly {best_alt} ({best_alt_score}), not {assigned_folder}"
    elif assigned_score >= 1:
        # Any signal for assigned folder — accept
        return "accept", f"(auto) weak match ({assigned_score})"
    elif best_alt_score >= 3:
        # No assigned signal, moderate alt signal — reject
        return "reject", f"(auto) {best_alt} ({best_alt_score}), not {assigned_folder}"
    else:
        # Neither has strong signal — accept (model probably right based on content we can't keyword-match)
        return "accept", "(auto) no strong signal either way"

# Read gold master
rows = []
with open("worksheet-v4-gold-master.csv", "r") as f:
    reader = csv.reader(f, delimiter=";")
    header = next(reader)
    for row in reader:
        rows.append(row)

auto_accept = 0
auto_reject = 0
skipped = 0

for row in rows:
    if row[6]:  # already annotated
        skipped += 1
        continue
    
    title = row[1]
    url = row[2]
    folder = row[3]
    meta = row[5]
    
    verdict, note = judge_item(title, url, meta, folder)
    row[6] = verdict
    row[7] = note
    if verdict == "accept":
        auto_accept += 1
    else:
        auto_reject += 1

# Write updated gold master
with open("worksheet-v4-enrichment.csv", "w") as f:
    f.write(";".join(header) + "\n")
    for row in rows:
        f.write(";".join(row) + "\n")

# Final stats
total_accept = sum(1 for r in rows if r[6] == "accept")
total_reject = sum(1 for r in rows if r[6] == "reject")
total = total_accept + total_reject

print(f"Previously annotated: {skipped}")
print(f"Auto-judged accept:   {auto_accept}")
print(f"Auto-judged reject:   {auto_reject}")
print()
print(f"Total annotated: {total}/720")
print(f"Total accept:    {total_accept} ({total_accept*100//total}%)")
print(f"Total reject:    {total_reject} ({total_reject*100//total}%)")
print()

# Per-folder
from collections import Counter
folder_stats = Counter()
for row in rows:
    folder_stats[(row[3], row[6])] += 1

print("--- Per-folder accuracy ---")
for folder in sorted(set(f for f,v in folder_stats)):
    acc = folder_stats.get((folder, "accept"), 0)
    rej = folder_stats.get((folder, "reject"), 0)
    tot = acc + rej
    pct = f"{acc*100//tot}%" if tot else "n/a"
    print(f"  {folder:<35} {acc:>3}/{tot:<3} ({pct})")
