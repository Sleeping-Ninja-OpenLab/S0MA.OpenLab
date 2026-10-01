#!/usr/bin/env bash
set -euo pipefail

VENV="${HOME}/.cache/soma-gobilda-sync/venv"
PYTHON="${VENV}/bin/python"

if [[ ! -x "${PYTHON}" ]]; then
  echo "[goBILDA] First run: creating Python environment in ${VENV}"
  mkdir -p "$(dirname "${VENV}")"
  if ! python3 -m venv "${VENV}"; then
    echo >&2 "Could not create a Python venv. Install it with: sudo apt install python3-venv"
    exit 1
  fi
  "${VENV}/bin/pip" install --quiet --disable-pip-version-check --upgrade pip
  "${VENV}/bin/pip" install --quiet --disable-pip-version-check requests beautifulsoup4 rich
fi

exec "${PYTHON}" - "$@" <<'PY'
from __future__ import annotations

import argparse
import io
import json
import random
import re
import shutil
import sys
import tempfile
import time
from collections import Counter
import zipfile
from collections import deque
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import parse_qsl, urlencode, urljoin, urlsplit, urlunsplit

import requests
from bs4 import BeautifulSoup, Tag
from requests.adapters import HTTPAdapter
from rich.console import Console
from rich.progress import (
    BarColumn,
    MofNCompleteColumn,
    Progress,
    SpinnerColumn,
    TaskProgressColumn,
    TextColumn,
    TimeElapsedColumn,
)
from rich.table import Table
from urllib3.util.retry import Retry

BASE = "https://www.gobilda.com"
ROOTS = {
    "structure": (f"{BASE}/structure", "Structure"),
    "motion": (f"{BASE}/motion", "Motion"),
    "electronics": (f"{BASE}/electronics", "Electronics"),
    "hardware": (f"{BASE}/hardware", "Hardware"),
    "kits": (f"{BASE}/kits", "Kits"),
}

DEFAULT_VENDOR = Path("/mnt/d/Sauce/S0MA/CAD/Vendor/goBILDA")
DEFAULT_INVENTOR = Path("/mnt/d/Sauce/S0MA/CAD/goBILDA")

SKU_RE = re.compile(r"\b(\d{4}-\d{4}-\d{4})\b")
STEP_SUFFIXES = {".step", ".stp"}
INVENTOR_SUFFIXES = {".ipt", ".iam"}
SOLIDWORKS_SUFFIXES = {".sldasm", ".sldprt"}
BUNDLE_RE = re.compile(r"\bbundles?\b", re.I)
PRICE_RE = re.compile(r"\$\s*\d")

SKIP_PATH_PARTS = {
    "account", "cart", "checkout", "search", "login", "register", "wishlist",
    "wishlists", "compare", "contact", "support", "education", "ftc", "merch",
    "blog", "privacy", "terms", "returns", "shipping",
}

console = Console()

ERROR_LOG_PATH: Path | None = None


def configure_error_log(path: Path) -> None:
    global ERROR_LOG_PATH
    ERROR_LOG_PATH = path
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "timestamp\tlevel\tkind\tsku\tpage_url\tstep_url\tmessage\n",
        encoding="utf-8",
    )


def log_issue(
    kind: str,
    message: str,
    *,
    sku: str = "",
    page_url: str = "",
    step_url: str = "",
    level: str = "WARN",
) -> None:
    if ERROR_LOG_PATH is None:
        return
    clean = lambda v: str(v).replace("\t", " ").replace("\r", " ").replace("\n", " ")
    with ERROR_LOG_PATH.open("a", encoding="utf-8") as fh:
        fh.write(
            "\t".join([
                time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                clean(level), clean(kind), clean(sku), clean(page_url),
                clean(step_url), clean(message),
            ]) + "\n"
        )


@dataclass
class ExclusionRecord:
    sku: str
    url: str
    reason: str = ""


def load_exclusions(path: Path) -> dict[str, ExclusionRecord]:
    """Load SKU-keyed exclusions, including automatic migration of the older URL-only format."""
    if not path.exists():
        return {}

    out: dict[str, ExclusionRecord] = {}
    pending_sku = ""
    pending_reason = ""

    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line:
            continue

        if line.startswith("#"):
            # Legacy files wrote: # SKU | reason | date
            m = re.match(r"#\s*(\d{4}-\d{4}-\d{4})\s*\|\s*(.*?)\s*(?:\|\s*\d{4}-\d{2}-\d{2})?\s*$", line)
            if m:
                pending_sku = m.group(1)
                pending_reason = m.group(2).strip()
            continue

        # New canonical format: SKU|URL[|reason]
        parts = [x.strip() for x in line.split("|", 2)]
        if len(parts) >= 2 and SKU_RE.fullmatch(parts[0]):
            sku = parts[0]
            try:
                url = canonical_url(parts[1], keep_page_query=False)
            except Exception:
                url = parts[1]
            reason = parts[2] if len(parts) == 3 else ""
            out[sku] = ExclusionRecord(sku, url, reason)
            pending_sku = ""
            pending_reason = ""
            continue

        # Legacy URL-only data line; pair it with the preceding SKU comment.
        if pending_sku:
            try:
                url = canonical_url(line, keep_page_query=False)
            except Exception:
                url = line
            out[pending_sku] = ExclusionRecord(pending_sku, url, pending_reason)
            pending_sku = ""
            pending_reason = ""

    return out


def rewrite_exclusions(path: Path, excluded: dict[str, ExclusionRecord]) -> None:
    """Rewrite exclusions into the stable SKU-keyed format."""
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        "# goBILDA products intentionally skipped by SKU.",
        "# Format: SKU|last-known-product-URL|reason",
        "# SKU is the identity; URL is audit metadata only.",
        "# Delete a SKU line to force a future re-check.",
        "",
    ]
    for sku in sorted(excluded):
        rec = excluded[sku]
        reason = rec.reason.replace("|", "/").replace("\n", " ").strip()
        lines.append(f"{sku}|{rec.url}|{reason}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def append_exclusion(path: Path, excluded: dict[str, ExclusionRecord], url: str, sku: str, reason: str) -> None:
    c = canonical_url(url, keep_page_query=False)
    if sku in excluded:
        return
    excluded[sku] = ExclusionRecord(sku, c, reason)
    rewrite_exclusions(path, excluded)


@dataclass
class PageJob:
    url: str
    logical_dir: tuple[str, ...]
    is_root: bool = False
    same_dir: bool = False


@dataclass
class ProductRef:
    url: str
    sku: str | None
    name: str
    logical_dir: tuple[str, ...]
    cached_html: str | None = None


@dataclass
class StepJob:
    product_url: str
    step_url: str
    sku: str
    product_name: str
    logical_dir: tuple[str, ...]


def progress_columns():
    return [
        SpinnerColumn(),
        TextColumn("{task.description}"),
        BarColumn(bar_width=None),
        MofNCompleteColumn(),
        TaskProgressColumn(),
        TimeElapsedColumn(),
    ]


def sanitize_component(value: str) -> str:
    value = re.sub(r'[<>:"/\\|?*]', "-", value)
    value = re.sub(r"\s+", " ", value).strip().strip(".")
    return value[:120] or "Uncategorised"


def normalize_text(value: str) -> str:
    return re.sub(r"\s+", " ", value or "").strip()


def canonical_url(url: str, *, keep_page_query: bool = True) -> str:
    p = urlsplit(urljoin(BASE, url))
    path = re.sub(r"/{2,}", "/", p.path)
    if path != "/":
        path = path.rstrip("/")
    query = ""
    if keep_page_query and p.query:
        allowed = []
        for key, val in parse_qsl(p.query, keep_blank_values=True):
            if key.lower() in {"page", "limit"}:
                allowed.append((key, val))
        if allowed:
            query = urlencode(allowed)
    return urlunsplit(("https", p.netloc.lower(), path, query, ""))


def same_site(url: str) -> bool:
    return urlsplit(url).netloc.lower() in {"gobilda.com", "www.gobilda.com"}


def is_bundle(text: str, url: str = "") -> bool:
    return bool(BUNDLE_RE.search(text or "") or BUNDLE_RE.search(url or ""))


def is_file_like(url: str) -> bool:
    path = urlsplit(url).path.lower()
    return path.endswith((
        ".zip", ".step", ".stp", ".pdf", ".jpg", ".jpeg", ".png", ".gif",
        ".webp", ".svg", ".mp4", ".mov", ".dwg", ".dxf", ".csv", ".xml",
    ))


def is_skip_url(url: str) -> bool:
    p = urlsplit(url)
    if not same_site(url):
        return True
    parts = {x.lower() for x in p.path.split("/") if x}
    if parts & SKIP_PATH_PARTS:
        return True
    if p.path.startswith("/content/") or is_file_like(url):
        return True
    if p.query:
        keys = {k.lower() for k, _ in parse_qsl(p.query)}
        if not keys.issubset({"page", "limit"}):
            return True
    return False


def page_main(soup: BeautifulSoup) -> Tag:
    main = soup.find("main")
    if isinstance(main, Tag):
        return main
    main = soup.find(id=re.compile(r"main", re.I))
    if isinstance(main, Tag):
        return main
    body = soup.body
    return body if isinstance(body, Tag) else soup


def h1_text(soup: BeautifulSoup) -> str:
    h1 = page_main(soup).find("h1")
    return normalize_text(h1.get_text(" ", strip=True)) if h1 else ""


def product_sku(soup: BeautifulSoup) -> str | None:
    for node in soup.select('[itemprop="sku"], [data-product-sku], .productView-info-value'):
        val = normalize_text(node.get("content", "") if node.has_attr("content") else node.get_text(" ", strip=True))
        m = SKU_RE.search(val)
        if m:
            return m.group(1)

    main_text = page_main(soup).get_text(" ", strip=True)
    m = re.search(r"\bSKU\s*:\s*(\d{4}-\d{4}-\d{4})\b", main_text, re.I)
    if m:
        return m.group(1)

    # Product JSON-LD fallback.
    for script in soup.find_all("script", attrs={"type": "application/ld+json"}):
        raw = script.string or script.get_text("", strip=True)
        if not raw:
            continue
        try:
            data = json.loads(raw)
        except Exception:
            continue
        items = data if isinstance(data, list) else [data]
        for item in items:
            if isinstance(item, dict) and str(item.get("@type", "")).lower() == "product":
                m = SKU_RE.search(str(item.get("sku", "")))
                if m:
                    return m.group(1)
    return None


def nearest_card_text(anchor: Tag) -> str:
    direct = normalize_text(anchor.get_text(" ", strip=True))
    if SKU_RE.search(direct):
        return direct

    node = anchor.parent if isinstance(anchor.parent, Tag) else None
    for _ in range(5):
        if not isinstance(node, Tag):
            break
        cls = " ".join(node.get("class", []))
        if node.name in {"article", "li"} or re.search(r"(card|product|item|tile)", cls, re.I):
            text = normalize_text(node.get_text(" ", strip=True))
            if len(text) <= 1600 and SKU_RE.search(text):
                return text
        node = node.parent if isinstance(node.parent, Tag) else None
    return direct


def inside_paragraph(anchor: Tag) -> bool:
    return anchor.find_parent("p") is not None


def inside_navigation(anchor: Tag) -> bool:
    for parent in anchor.parents:
        if not isinstance(parent, Tag):
            continue
        if parent.name in {"header", "footer", "nav"}:
            return True
        cls = " ".join(parent.get("class", []))
        if re.search(r"\b(breadcrumb|header|footer|nav|menu)\b", cls, re.I):
            return True
        if parent.name == "main":
            break
    return False


def pagination_links(main: Tag, current_url: str) -> set[str]:
    out: set[str] = set()
    current_path = urlsplit(current_url).path.rstrip("/")
    for a in main.find_all("a", href=True):
        href = canonical_url(urljoin(current_url, a["href"]))
        p = urlsplit(href)
        if p.path.rstrip("/") == current_path and p.query and "page=" in p.query.lower():
            out.add(href)
    return out


def find_step_links(soup: BeautifulSoup, product_url: str) -> list[str]:
    links: list[str] = []
    for a in page_main(soup).find_all("a", href=True):
        text = normalize_text(a.get_text(" ", strip=True))
        href = urljoin(product_url, a["href"])
        path = urlsplit(href).path.lower()
        if (
            re.search(r"\bstep\s*file\b", text, re.I)
            or "/content/step_files/" in path
            or path.endswith((".step", ".stp"))
        ) and path.endswith((".zip", ".step", ".stp")):
            links.append(href)
    return list(dict.fromkeys(links))


def looks_like_cloudflare_challenge(response: requests.Response) -> bool:
    if response.headers.get("cf-mitigated", "").lower() == "challenge":
        return True
    if response.status_code not in {403, 429, 503}:
        return False
    ctype = response.headers.get("content-type", "").lower()
    if "html" not in ctype:
        return False
    sample = response.text[:20000].lower()
    return any(marker in sample for marker in (
        "just a moment", "cf-chl-", "challenge-platform", "cloudflare ray id",
        "verify you are human",
    ))


class RateLimitedSession:
    def __init__(self, delay: float, jitter: float, timeout: float, cf_retries: int, cf_backoff: float):
        self.delay = max(0.0, delay)
        self.jitter = max(0.0, jitter)
        self.timeout = timeout
        self.cf_retries = max(0, cf_retries)
        self.cf_backoff = max(1.0, cf_backoff)
        self.last_request = 0.0
        self.session = requests.Session()
        self.session.headers.update({
            "User-Agent": (
                "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                "Chrome/136.0 Safari/537.36"
            ),
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-GB,en;q=0.9",
            "Cache-Control": "no-cache",
        })
        retry = Retry(
            total=5,
            connect=5,
            read=5,
            status=5,
            backoff_factor=2.0,
            status_forcelist=(429, 500, 502, 503, 504, 520, 521, 522, 523, 524),
            allowed_methods=frozenset({"GET", "HEAD"}),
            respect_retry_after_header=True,
            raise_on_status=False,
        )
        adapter = HTTPAdapter(max_retries=retry)
        self.session.mount("https://", adapter)
        self.session.mount("http://", adapter)

    def _wait(self) -> None:
        wanted = self.delay + random.uniform(0.0, self.jitter)
        elapsed = time.monotonic() - self.last_request
        if elapsed < wanted:
            time.sleep(wanted - elapsed)

    def get(self, url: str, **kwargs) -> requests.Response:
        kwargs.setdefault("timeout", self.timeout)
        for attempt in range(self.cf_retries + 1):
            self._wait()
            response = self.session.get(url, **kwargs)
            self.last_request = time.monotonic()
            if not looks_like_cloudflare_challenge(response):
                return response
            if attempt >= self.cf_retries:
                return response
            wait = self.cf_backoff * (2 ** attempt) + random.uniform(0.0, 5.0)
            console.print(
                f"[yellow]Cloudflare challenge/rate limit detected.[/] "
                f"Waiting {wait:.0f}s before retry {attempt + 1}/{self.cf_retries}: {url}"
            )
            time.sleep(wait)
        return response


def load_html(client: RateLimitedSession, url: str, stats: dict) -> str | None:
    try:
        r = client.get(url)
        stats["http_requests"] += 1
    except requests.RequestException as exc:
        stats["page_errors"] += 1
        console.print(f"[red]Page error[/] {url}: {exc}")
        log_issue("PAGE_REQUEST", str(exc), page_url=url, level="ERROR")
        return None

    if looks_like_cloudflare_challenge(r):
        stats["cloudflare_blocks"] += 1
        stats["page_errors"] += 1
        console.print(f"[red]Cloudflare challenge still active after retries[/] {url}")
        log_issue("CLOUDFLARE", "Challenge still active after retries", page_url=url, level="ERROR")
        return None
    if r.status_code != 200:
        stats["page_errors"] += 1
        console.print(f"[red]HTTP {r.status_code}[/] {url}")
        log_issue("PAGE_HTTP", f"HTTP {r.status_code}", page_url=url, level="ERROR")
        return None

    ctype = r.headers.get("content-type", "").lower()
    if "html" not in ctype and "text" not in ctype:
        return None
    return r.text


def add_product(products: dict[str, ProductRef], ref: ProductRef) -> None:
    url = canonical_url(ref.url, keep_page_query=False)
    existing = products.get(url)
    if existing is None or len(ref.logical_dir) > len(existing.logical_dir):
        ref.url = url
        products[url] = ref
    elif existing.cached_html is None and ref.cached_html is not None:
        existing.cached_html = ref.cached_html
    if existing and not existing.sku and ref.sku:
        existing.sku = ref.sku


def discover_catalogue(client: RateLimitedSession, selected_roots: list[str], max_pages: int, stats: dict):
    queue: deque[PageJob] = deque()
    queued: set[str] = set()
    visited: set[str] = set()
    products: dict[str, ProductRef] = {}
    cache: dict[str, str] = {}

    for key in selected_roots:
        url, label = ROOTS[key]
        c = canonical_url(url)
        queue.append(PageJob(c, (label,), is_root=True))
        queued.add(c)

    with Progress(*progress_columns(), console=console) as progress:
        task = progress.add_task("1/5 Scanning goBILDA catalogue", total=max(1, len(queue)))
        processed = 0

        while queue:
            if processed >= max_pages:
                console.print(f"[yellow]Safety stop:[/] reached --max-pages={max_pages}")
                break

            job = queue.popleft()
            url = canonical_url(job.url)
            if url in visited:
                continue
            visited.add(url)
            processed += 1

            html = load_html(client, url, stats)
            progress.advance(task)
            if html is None:
                continue
            cache[url] = html
            soup = BeautifulSoup(html, "html.parser")
            title = h1_text(soup)

            if is_bundle(title, url):
                stats["bundles_ignored"] += 1
                continue

            sku = product_sku(soup)
            if sku:
                name = title or sku
                if is_bundle(name, url):
                    stats["bundles_ignored"] += 1
                    continue
                add_product(products, ProductRef(url, sku, name, job.logical_dir, html))
                stats["product_pages_found"] += 1
                continue

            stats["category_pages_scanned"] += 1
            main = page_main(soup)

            if job.is_root or job.same_dir:
                logical_dir = job.logical_dir
            else:
                name = sanitize_component(title or Path(urlsplit(url).path).name)
                logical_dir = job.logical_dir if (job.logical_dir and name.casefold() == job.logical_dir[-1].casefold()) else (*job.logical_dir, name)

            # Products directly listed on a category page, including pages such as Grid Plates.
            seen_product_hrefs: set[str] = set()
            for a in main.find_all("a", href=True):
                raw_href = a.get("href", "").strip()
                if not raw_href or raw_href.startswith(("#", "mailto:", "tel:", "javascript:")):
                    continue
                href = canonical_url(urljoin(url, raw_href), keep_page_query=False)
                if not same_site(href) or is_file_like(href):
                    continue
                card_text = nearest_card_text(a)
                m = SKU_RE.search(card_text)
                if not m:
                    continue
                if is_bundle(card_text, href):
                    stats["bundles_ignored"] += 1
                    continue
                if href in seen_product_hrefs:
                    continue
                seen_product_hrefs.add(href)
                add_product(products, ProductRef(href, m.group(1), normalize_text(a.get_text(" ", strip=True)) or card_text, logical_dir))

            for href in pagination_links(main, url):
                if href not in queued and href not in visited:
                    queue.append(PageJob(href, logical_dir, same_dir=True))
                    queued.add(href)

            # BigCommerce uses mostly flat URLs, so classify links after fetching them.
            for a in main.find_all("a", href=True):
                raw_href = a.get("href", "").strip()
                text = normalize_text(a.get_text(" ", strip=True))
                if not raw_href or raw_href.startswith(("#", "mailto:", "tel:", "javascript:")):
                    continue
                href = canonical_url(urljoin(url, raw_href))
                if href == url or href in queued or href in visited:
                    continue
                if is_skip_url(href) or is_bundle(text, href):
                    if is_bundle(text, href):
                        stats["bundles_ignored"] += 1
                    continue
                if inside_navigation(a) or inside_paragraph(a) or text.upper().startswith("SEE ALSO"):
                    continue
                if PRICE_RE.search(text) or SKU_RE.search(nearest_card_text(a)) or len(text) > 140:
                    continue
                queue.append(PageJob(href, logical_dir))
                queued.add(href)

            progress.update(task, total=max(progress.tasks[task].total or 0, len(visited) + len(queue)))

        progress.update(task, total=max(processed, 1), completed=processed)

    stats["catalogue_pages_visited"] = len(visited)
    stats["products_discovered"] = len(products)
    return products, cache


def sku_index(root: Path, suffixes: set[str]) -> dict[str, list[Path]]:
    out: dict[str, list[Path]] = {}
    if not root.exists():
        return out
    for p in root.rglob("*"):
        if not p.is_file() or p.suffix.lower() not in suffixes:
            continue
        m = SKU_RE.search(p.name)
        if m:
            out.setdefault(m.group(1), []).append(p)
    return out


def sku_folder_index(root: Path) -> dict[str, list[Path]]:
    """SKU-named directories represent native-CAD downloads (e.g. SolidWorks packs)."""
    out: dict[str, list[Path]] = {}
    if not root.exists():
        return out
    for p in root.rglob("*"):
        if not p.is_dir():
            continue
        m = SKU_RE.fullmatch(p.name)
        if m:
            out.setdefault(m.group(1), []).append(p)
    return out


def vendor_downloaded_index(root: Path) -> dict[str, list[Path]]:
    """All locally downloaded CAD SKUs: STEP/STP files plus SKU-named native-CAD folders."""
    out = sku_index(root, STEP_SUFFIXES)
    for sku, paths in sku_folder_index(root).items():
        out.setdefault(sku, []).extend(paths)
    return out


def ensure_logical_dirs(vendor_root: Path, inventor_root: Path, logical_dir: tuple[str, ...], stats: dict, dry_run: bool) -> None:
    parts = [sanitize_component(x) for x in logical_dir]
    for root, stat_key in ((vendor_root, "vendor_folders_created"), (inventor_root, "inventor_folders_created")):
        target = root.joinpath(*parts)
        if not target.exists():
            if not dry_run:
                target.mkdir(parents=True, exist_ok=True)
            stats[stat_key] += 1


def scan_product_steps(
    client: RateLimitedSession,
    products: dict[str, ProductRef],
    cache: dict[str, str],
    vendor_root: Path,
    inventor_root: Path,
    stats: dict,
    dry_run: bool,
    excluded_skus: dict[str, ExclusionRecord],
) -> list[StepJob]:
    existing_vendor = vendor_downloaded_index(vendor_root)
    jobs: dict[tuple[str, str], StepJob] = {}
    items = list(products.values())

    with Progress(*progress_columns(), console=console) as progress:
        task = progress.add_task("2/5 Building STEP download queue by SKU", total=max(1, len(items)))
        for ref in items:
            ensure_logical_dirs(vendor_root, inventor_root, ref.logical_dir, stats, dry_run)

            # The Vendor STEP tree is the resume mechanism.
            actual_sku = ref.sku
            name = ref.name or actual_sku or "Unknown product"

            # Rare fallback: catalogue cards normally contain the SKU already.
            if not actual_sku:
                html = ref.cached_html or cache.get(ref.url)
                if html is None:
                    html = load_html(client, ref.url, stats)
                if html is not None:
                    soup = BeautifulSoup(html, "html.parser")
                    actual_sku = product_sku(soup)
                    name = h1_text(soup) or name

            if not actual_sku:
                stats["product_without_sku"] += 1
                progress.advance(task)
                continue
            if is_bundle(name, ref.url):
                stats["bundles_ignored"] += 1
                progress.advance(task)
                continue
            if actual_sku in excluded_skus:
                stats["no_step_exclusions_skipped"] += 1
                old_url = excluded_skus[actual_sku].url
                current_url = canonical_url(ref.url, keep_page_query=False)
                if old_url and current_url != old_url:
                    stats["sku_url_changes"] += 1
                    log_issue(
                        "SKU_URL_CHANGED",
                        f"Excluded SKU appeared at a different catalogue URL; keeping SKU exclusion. Previous URL: {old_url}",
                        sku=actual_sku, page_url=current_url, level="INFO"
                    )
                progress.advance(task)
                continue
            if actual_sku in existing_vendor:
                stats["existing_sku_skipped"] += 1
                progress.advance(task)
                continue

            # goBILDA STEP downloads are SKU-addressed:
            # /content/step_files/<SKU>.zip
            # Build this directly instead of depending on product-page markup.
            step_url = f"{BASE}/content/step_files/{actual_sku}.zip"
            key = (actual_sku, step_url)
            jobs[key] = StepJob(ref.url, step_url, actual_sku, name, ref.logical_dir)
            progress.advance(task)

    stats["step_links_to_download"] = len(jobs)
    return list(jobs.values())


def staged_name(original: str, sku: str, multiple: bool) -> str:
    name = sanitize_component(Path(original).name)
    suffix = Path(name).suffix
    if suffix.lower() not in STEP_SUFFIXES:
        suffix = ".STEP"
    if SKU_RE.search(name):
        return name
    if multiple:
        return f"{sku}--{Path(name).stem}{suffix}"
    return f"{sku}{suffix}"


@dataclass
class ExtractedStep:
    source_name: str
    data: bytes
    sku_hint: str
    depth: int


def collect_step_entries_from_zip_bytes(
    payload: bytes,
    outer_sku: str,
    stats: dict,
    *,
    inherited_sku: str | None = None,
    depth: int = 0,
    max_depth: int = 8,
) -> list[ExtractedStep]:
    if depth > max_depth:
        log_issue("ZIP_DEPTH", f"Nested ZIP depth exceeded {max_depth}", sku=outer_sku, level="ERROR")
        return []

    entries: list[ExtractedStep] = []
    try:
        with zipfile.ZipFile(io.BytesIO(payload)) as zf:
            for member in zf.infolist():
                if member.is_dir():
                    continue
                member_name = member.filename
                suffix = Path(member_name).suffix.lower()
                try:
                    data = zf.read(member)
                except Exception as exc:
                    log_issue("ZIP_MEMBER_READ", f"{member_name}: {exc}", sku=outer_sku, level="ERROR")
                    continue

                if suffix in STEP_SUFFIXES:
                    m = SKU_RE.search(Path(member_name).name)
                    hint = m.group(1) if m else (inherited_sku or outer_sku)
                    entries.append(ExtractedStep(member_name, data, hint, depth))
                    continue

                if suffix == ".zip" or zipfile.is_zipfile(io.BytesIO(data)):
                    stats["nested_zip_archives"] += 1
                    m = SKU_RE.search(Path(member_name).name)
                    child_hint = m.group(1) if m else (inherited_sku or outer_sku)
                    child = collect_step_entries_from_zip_bytes(
                        data,
                        outer_sku,
                        stats,
                        inherited_sku=child_hint,
                        depth=depth + 1,
                        max_depth=max_depth,
                    )
                    if not child:
                        stats["nested_zips_without_step"] += 1
                    entries.extend(child)
    except zipfile.BadZipFile as exc:
        log_issue("BAD_NESTED_ZIP", str(exc), sku=outer_sku, level="ERROR")
    return entries


@dataclass
class ExtractedNative:
    relative_name: str
    data: bytes


def collect_native_entries_from_zip_bytes(
    payload: bytes,
    outer_sku: str,
    stats: dict,
    *,
    prefix: tuple[str, ...] = (),
    depth: int = 0,
    max_depth: int = 8,
) -> list[ExtractedNative]:
    """Collect SolidWorks assembly/part files, preserving safe archive structure.

    Nested ZIPs get their own directory named after the nested archive so
    identically named parts from separate packs cannot overwrite each other.
    """
    if depth > max_depth:
        log_issue("ZIP_DEPTH_NATIVE", f"Nested ZIP depth exceeded {max_depth}", sku=outer_sku, level="ERROR")
        return []

    entries: list[ExtractedNative] = []
    try:
        with zipfile.ZipFile(io.BytesIO(payload)) as zf:
            for member in zf.infolist():
                if member.is_dir():
                    continue
                raw_parts = [x for x in Path(member.filename.replace("\\", "/")).parts if x not in {"", ".", ".."}]
                if not raw_parts:
                    continue
                safe_parts = tuple(sanitize_component(x) for x in raw_parts)
                suffix = Path(raw_parts[-1]).suffix.lower()
                try:
                    data = zf.read(member)
                except Exception as exc:
                    log_issue("ZIP_MEMBER_READ_NATIVE", f"{member.filename}: {exc}", sku=outer_sku, level="ERROR")
                    continue

                if suffix in SOLIDWORKS_SUFFIXES:
                    rel = Path(*prefix, *safe_parts).as_posix()
                    entries.append(ExtractedNative(rel, data))
                    continue

                if suffix == ".zip" or zipfile.is_zipfile(io.BytesIO(data)):
                    stats["nested_zip_archives"] += 1
                    nested_name = sanitize_component(Path(raw_parts[-1]).stem)
                    entries.extend(collect_native_entries_from_zip_bytes(
                        data, outer_sku, stats, prefix=(*prefix, *safe_parts[:-1], nested_name),
                        depth=depth + 1, max_depth=max_depth
                    ))
    except zipfile.BadZipFile as exc:
        log_issue("BAD_NESTED_ZIP_NATIVE", str(exc), sku=outer_sku, level="ERROR")
    return entries


def write_native_entries(
    entries: list[ExtractedNative],
    vendor_root: Path,
    logical_dir: tuple[str, ...],
    sku: str,
    stats: dict,
) -> tuple[Path, int]:
    """Write a native CAD pack under <logical vendor dir>/<SKU>/... ."""
    target_root = vendor_root.joinpath(*[sanitize_component(x) for x in logical_dir], sku)
    target_root.mkdir(parents=True, exist_ok=True)
    written = 0
    for entry in entries:
        rel = Path(entry.relative_name)
        dest_dir = target_root.joinpath(*rel.parts[:-1])
        dest_dir.mkdir(parents=True, exist_ok=True)
        dest, identical = unique_destination(dest_dir / rel.name, entry.data)
        if identical:
            stats["native_files_identical"] += 1
        else:
            dest.write_bytes(entry.data)
            stats["native_files_new"] += 1
        written += 1
    return target_root, written


def unique_destination(dest: Path, data: bytes) -> tuple[Path, bool]:
    if not dest.exists():
        return dest, False
    try:
        if dest.read_bytes() == data:
            return dest, True
    except OSError:
        pass
    stem, suffix = dest.stem, dest.suffix
    for n in range(2, 1000):
        candidate = dest.with_name(f"{stem}--{n}{suffix}")
        if not candidate.exists():
            return candidate, False
        try:
            if candidate.read_bytes() == data:
                return candidate, True
        except OSError:
            pass
    raise OSError(f"Could not find unique destination for {dest}")


def write_step_entries(
    entries: list[ExtractedStep],
    vendor_root: Path,
    default_dir: tuple[str, ...],
    sku_dirs: dict[str, tuple[str, ...]],
    stats: dict,
) -> tuple[list[Path], set[str]]:
    written: list[Path] = []
    written_skus: set[str] = set()
    per_sku = Counter(e.sku_hint for e in entries)

    for entry in entries:
        sku = entry.sku_hint
        logical_dir = sku_dirs.get(sku, default_dir)
        target_dir = vendor_root.joinpath(*[sanitize_component(x) for x in logical_dir])
        target_dir.mkdir(parents=True, exist_ok=True)
        filename = staged_name(entry.source_name, sku, per_sku[sku] > 1)
        dest, identical = unique_destination(target_dir / filename, entry.data)
        if identical:
            stats["step_files_identical"] += 1
        else:
            dest.write_bytes(entry.data)
            stats["step_files_new"] += 1
        written.append(dest)
        written_skus.add(sku)
    return written, written_skus


def response_to_temp(response: requests.Response, sku: str, suffix: str) -> Path:
    with tempfile.NamedTemporaryFile(prefix=f"gobilda-{sku}-", suffix=suffix or ".bin", delete=False) as tmp:
        path = Path(tmp.name)
        for chunk in response.iter_content(chunk_size=256 * 1024):
            if chunk:
                tmp.write(chunk)
    return path


def get_step_response(client: RateLimitedSession, url: str, stats: dict) -> requests.Response | None:
    try:
        r = client.get(url, stream=True)
        stats["http_requests"] += 1
        return r
    except requests.RequestException as exc:
        stats["download_errors"] += 1
        log_issue("DOWNLOAD_REQUEST", str(exc), step_url=url, level="ERROR")
        return None


def page_step_links(client: RateLimitedSession, job: StepJob, stats: dict) -> list[str] | None:
    html = load_html(client, job.product_url, stats)
    if html is None:
        return None
    return find_step_links(BeautifulSoup(html, "html.parser"), job.product_url)


def download_steps(
    client: RateLimitedSession,
    jobs: list[StepJob],
    vendor_root: Path,
    inventor_root: Path,
    stats: dict,
    dry_run: bool,
    excluded_skus: dict[str, ExclusionRecord],
    exclusion_file: Path,
    sku_dirs: dict[str, tuple[str, ...]],
) -> None:
    existing_skus = set(vendor_downloaded_index(vendor_root))

    with Progress(*progress_columns(), console=console) as progress:
        task = progress.add_task("3/5 Downloading and extracting STEP files", total=max(1, len(jobs)))

        for job in jobs:
            ensure_logical_dirs(vendor_root, inventor_root, job.logical_dir, stats, dry_run)
            page_url = canonical_url(job.product_url, keep_page_query=False)

            if job.sku in excluded_skus:
                stats["no_step_exclusions_skipped"] += 1
                progress.advance(task)
                continue
            if job.sku in existing_skus:
                stats["existing_sku_skipped"] += 1
                progress.advance(task)
                continue
            if dry_run:
                stats["dry_run_downloads"] += 1
                progress.advance(task)
                continue

            candidate_urls = [job.step_url]
            attempted: set[str] = set()
            success = False

            while candidate_urls and not success:
                step_url = candidate_urls.pop(0)
                if step_url in attempted:
                    continue
                attempted.add(step_url)
                r = get_step_response(client, step_url, stats)
                if r is None:
                    console.print(f"[red]Download error[/] {job.sku} | page: {job.product_url}")
                    continue

                if looks_like_cloudflare_challenge(r):
                    stats["cloudflare_blocks"] += 1
                    stats["download_errors"] += 1
                    console.print(f"[red]Cloudflare challenge on STEP download[/] {job.sku}: {step_url}")
                    log_issue("CLOUDFLARE_STEP", "Challenge after retries", sku=job.sku, page_url=job.product_url, step_url=step_url, level="ERROR")
                    continue

                if r.status_code == 404:
                    stats["step_404s"] += 1
                    links = page_step_links(client, job, stats)
                    if links is None:
                        console.print(f"[yellow]STEP 404; product page could not be verified[/] {job.sku} | {job.product_url}")
                        log_issue("STEP_404_UNVERIFIED", "HTTP 404 and product page could not be loaded", sku=job.sku, page_url=job.product_url, step_url=step_url)
                        break
                    fresh = [u for u in links if u not in attempted and u not in candidate_urls]
                    if fresh:
                        stats["fallback_step_links_found"] += len(fresh)
                        candidate_urls.extend(fresh)
                        log_issue("STEP_404_FALLBACK", f"HTTP 404; product page exposed {len(fresh)} alternate STEP link(s)", sku=job.sku, page_url=job.product_url, step_url=step_url)
                        continue
                    if not links:
                        stats["products_without_step"] += 1
                        append_exclusion(exclusion_file, excluded_skus, job.product_url, job.sku, "404 for SKU ZIP and product page has no STEP link")
                        console.print(f"[yellow]No STEP[/] {job.sku} | {job.product_url}")
                        log_issue("NO_STEP_CONFIRMED", "HTTP 404 for SKU ZIP; product page has no STEP link", sku=job.sku, page_url=job.product_url, step_url=step_url)
                    else:
                        stats["download_errors"] += 1
                        console.print(f"[yellow]Broken advertised STEP link[/] {job.sku} | {job.product_url}")
                        log_issue("BROKEN_ADVERTISED_STEP", "Product page advertises STEP but all known links returned 404", sku=job.sku, page_url=job.product_url, step_url=step_url, level="ERROR")
                    break

                if r.status_code != 200:
                    stats["download_errors"] += 1
                    console.print(f"[red]HTTP {r.status_code}[/] STEP {job.sku}: {step_url}")
                    log_issue("STEP_HTTP", f"HTTP {r.status_code}", sku=job.sku, page_url=job.product_url, step_url=step_url, level="ERROR")
                    continue

                suffix = Path(urlsplit(step_url).path).suffix.lower()
                tmp_path: Path | None = None
                try:
                    tmp_path = response_to_temp(r, job.sku, suffix)
                    written: list[Path] = []
                    written_skus: set[str] = set()

                    if suffix == ".zip" or zipfile.is_zipfile(tmp_path):
                        payload = tmp_path.read_bytes()
                        entries = collect_step_entries_from_zip_bytes(payload, job.sku, stats, inherited_sku=job.sku)
                        if entries:
                            written, written_skus = write_step_entries(entries, vendor_root, job.logical_dir, sku_dirs, stats)
                        if not written:
                            native_entries = collect_native_entries_from_zip_bytes(payload, job.sku, stats)
                            if native_entries:
                                native_root, native_count = write_native_entries(
                                    native_entries, vendor_root, job.logical_dir, job.sku, stats
                                )
                                stats["native_archives"] += 1
                                stats["downloads_completed"] += 1
                                existing_skus.add(job.sku)
                                success = True
                                console.print(
                                    f"[green]Native SolidWorks CAD[/] {job.sku} | "
                                    f"{native_count} file(s) -> {native_root.relative_to(vendor_root)}"
                                )
                                log_issue(
                                    "NATIVE_CAD_ONLY",
                                    f"No STEP/STP; extracted {native_count} SolidWorks SLDASM/SLDPRT file(s) into SKU subfolder",
                                    sku=job.sku,
                                    page_url=job.product_url,
                                    step_url=step_url,
                                    level="INFO",
                                )
                            else:
                                stats["zip_without_step"] += 1
                                console.print(f"[yellow]No STEP/native CAD found at any ZIP depth[/] {job.sku} | {job.product_url}")
                                log_issue(
                                    "ZIP_WITHOUT_CAD",
                                    "Downloaded archive contained no STEP/STP or SolidWorks SLDASM/SLDPRT at any nested ZIP depth",
                                    sku=job.sku, page_url=job.product_url, step_url=step_url, level="ERROR"
                                )
                    elif suffix in STEP_SUFFIXES:
                        data = tmp_path.read_bytes()
                        entry = ExtractedStep(Path(urlsplit(step_url).path).name or f"{job.sku}.STEP", data, job.sku, 0)
                        written, written_skus = write_step_entries([entry], vendor_root, job.logical_dir, sku_dirs, stats)
                    else:
                        stats["download_errors"] += 1
                        console.print(f"[yellow]Unknown STEP download type[/] {step_url}")
                        log_issue("UNKNOWN_STEP_TYPE", "HTTP 200 but file type is not ZIP/STEP/STP", sku=job.sku, page_url=job.product_url, step_url=step_url, level="ERROR")

                    if written:
                        stats["downloads_completed"] += 1
                        existing_skus.update(written_skus)
                        success = True
                        # Assortments sometimes expose a STEP download that is only a container
                        # of child-SKU ZIPs. If there is no CAD for the outer SKU itself, remember
                        # that product page so later runs do not repeatedly download the container.
                        if job.sku not in written_skus:
                            stats["container_archives"] += 1
                            append_exclusion(
                                exclusion_file,
                                excluded_skus,
                                job.product_url,
                                job.sku,
                                "STEP archive is a container of child-SKU CAD; no direct STEP for outer SKU",
                            )
                            log_issue(
                                "CONTAINER_ARCHIVE",
                                f"Extracted {len(written)} child STEP file(s); no direct outer-SKU STEP",
                                sku=job.sku,
                                page_url=job.product_url,
                                step_url=step_url,
                                level="INFO",
                            )
                except (zipfile.BadZipFile, OSError) as exc:
                    stats["download_errors"] += 1
                    console.print(f"[red]Extract/write error[/] {job.sku}: {exc}")
                    log_issue("EXTRACT_WRITE", str(exc), sku=job.sku, page_url=job.product_url, step_url=step_url, level="ERROR")
                finally:
                    if tmp_path is not None:
                        try:
                            tmp_path.unlink(missing_ok=True)
                        except OSError:
                            pass

            progress.advance(task)

def mirror_vendor_folders(vendor_root: Path, inventor_root: Path, stats: dict, dry_run: bool) -> None:
    dirs = sorted(p for p in vendor_root.rglob("*") if p.is_dir()) if vendor_root.exists() else []
    with Progress(*progress_columns(), console=console) as progress:
        task = progress.add_task("4/5 Mirroring folders into Inventor library", total=max(1, len(dirs)))
        for src in dirs:
            rel = src.relative_to(vendor_root)
            dest = inventor_root / rel
            if not dest.exists():
                if not dry_run:
                    dest.mkdir(parents=True, exist_ok=True)
                stats["inventor_folders_created"] += 1
            progress.advance(task)


def compare_inventor(vendor_root: Path, inventor_root: Path, stats: dict):
    vendor_step_index = sku_index(vendor_root, STEP_SUFFIXES)
    vendor_native_index = sku_folder_index(vendor_root)
    vendor_index = vendor_downloaded_index(vendor_root)
    inventor_index = sku_index(inventor_root, INVENTOR_SUFFIXES)
    vendor_skus = set(vendor_index)
    inventor_skus = set(inventor_index)
    missing = sorted(vendor_skus - inventor_skus)

    vendor_no_sku = []
    if vendor_root.exists():
        vendor_no_sku = [
            p for p in vendor_root.rglob("*")
            if p.is_file() and p.suffix.lower() in STEP_SUFFIXES and not SKU_RE.search(p.name)
        ]

    with Progress(*progress_columns(), console=console) as progress:
        task = progress.add_task("5/5 Comparing Vendor CAD SKUs to Inventor", total=max(1, len(vendor_skus)))
        for _ in vendor_skus:
            progress.advance(task)

    stats["vendor_step_files"] = sum(len(v) for v in vendor_step_index.values()) + len(vendor_no_sku)
    stats["vendor_native_skus"] = len(vendor_native_index)
    stats["vendor_unique_skus"] = len(vendor_skus)
    stats["inventor_unique_skus"] = len(inventor_skus)
    stats["converted_skus"] = len(vendor_skus & inventor_skus)
    stats["not_converted_skus"] = len(missing)
    stats["vendor_steps_without_sku"] = len(vendor_no_sku)
    return missing, vendor_index


def print_stats(stats: dict, vendor_root: Path, inventor_root: Path, missing: list[str], vendor_index: dict[str, list[Path]]) -> None:
    table = Table(title="goBILDA CAD sync summary", show_header=True, header_style="bold")
    table.add_column("Metric")
    table.add_column("Count", justify="right")
    rows = [
        ("Catalogue pages visited", "catalogue_pages_visited"),
        ("Category pages scanned", "category_pages_scanned"),
        ("Products discovered", "products_discovered"),
        ("Existing Vendor SKUs skipped", "existing_sku_skipped"),
        ("New STEP links found", "step_links_to_download"),
        ("Bundles ignored", "bundles_ignored"),
        ("Confirmed no-STEP product pages", "products_without_step"),
        ("No-STEP exclusions skipped", "no_step_exclusions_skipped"),
        ("Excluded SKU URL changes observed", "sku_url_changes"),
        ("STEP 404 responses", "step_404s"),
        ("Fallback STEP links found", "fallback_step_links_found"),
        ("Nested ZIP archives opened", "nested_zip_archives"),
        ("Container archives", "container_archives"),
        ("Downloads completed", "downloads_completed"),
        ("Native SolidWorks archives", "native_archives"),
        ("Native CAD files added", "native_files_new"),
        ("Native CAD files already identical", "native_files_identical"),
        ("STEP files added", "step_files_new"),
        ("STEP files already identical", "step_files_identical"),
        ("Vendor folders created", "vendor_folders_created"),
        ("Inventor folders created/mirrored", "inventor_folders_created"),
        ("Cloudflare blocks after retries", "cloudflare_blocks"),
        ("Page/download errors", None),
        ("Vendor STEP files", "vendor_step_files"),
        ("Vendor native-CAD SKU folders", "vendor_native_skus"),
        ("Vendor unique CAD SKUs", "vendor_unique_skus"),
        ("Inventor unique SKUs", "inventor_unique_skus"),
        ("Converted/matched SKUs", "converted_skus"),
        ("Not converted to Inventor yet", "not_converted_skus"),
        ("Vendor STEP files with no SKU in filename", "vendor_steps_without_sku"),
    ]
    for label, key in rows:
        value = stats.get(key, 0) if key else stats.get("page_errors", 0) + stats.get("download_errors", 0)
        table.add_row(label, f"{value:,}")

    console.print()
    console.print(table)
    console.print(f"Vendor STEP root: [bold]{vendor_root}[/]")
    console.print(f"Inventor library root: [bold]{inventor_root}[/]")

    if missing:
        console.print()
        console.print(f"[bold yellow]SKUs still to convert ({len(missing):,})[/] - first 40:")
        for sku in missing[:40]:
            paths = vendor_index.get(sku, [])
            rel = paths[0].relative_to(vendor_root) if paths else Path(sku)
            shown = rel if (paths and paths[0].is_dir()) else rel.parent
            console.print(f"  {sku}  ->  {shown}")
        if len(missing) > 40:
            console.print(f"  ... plus {len(missing) - 40:,} more")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description=(
            "Slow, polite goBILDA CAD crawler. Every run rescans the catalogue; the Vendor CAD tree "
            "is the only resume mechanism. STEP/STP filenames and SKU-named native-CAD folders both count as downloaded."
        )
    )
    p.add_argument("--vendor", type=Path, default=DEFAULT_VENDOR, help=f"Vendor STEP root (default: {DEFAULT_VENDOR})")
    p.add_argument("--inventor", type=Path, default=DEFAULT_INVENTOR, help=f"Inventor root (default: {DEFAULT_INVENTOR})")
    p.add_argument("--root", action="append", choices=sorted(ROOTS), dest="roots", help="Limit to one or more roots; repeat flag")
    p.add_argument("--delay", type=float, default=2.0, help="Minimum seconds between requests (default: 2.0)")
    p.add_argument("--jitter", type=float, default=0.75, help="Additional random delay in seconds (default: 0.75)")
    p.add_argument("--timeout", type=float, default=45.0, help="HTTP timeout seconds (default: 45)")
    p.add_argument("--cf-retries", type=int, default=3, help="Cloudflare challenge retries (default: 3)")
    p.add_argument("--cf-backoff", type=float, default=30.0, help="Initial Cloudflare retry wait seconds (default: 30)")
    p.add_argument("--max-pages", type=int, default=5000, help="Crawler safety limit (default: 5000)")
    p.add_argument("--dry-run", action="store_true", help="Scan/report only; do not download or create folders")
    p.add_argument("--error-log", type=Path, default=None, help="Error/audit log path (default: <vendor>/gobilda-sync-errors.log)")
    p.add_argument("--no-step-exclusions", type=Path, default=None, help="Confirmed no-STEP SKU list (default: <vendor>/gobilda-no-step-exclusions.txt)")
    return p


def main() -> int:
    args = build_parser().parse_args()
    selected_roots = args.roots or ["structure", "motion", "electronics", "hardware", "kits"]
    error_log = args.error_log or (args.vendor / "gobilda-sync-errors.log")
    exclusion_file = args.no_step_exclusions or (args.vendor / "gobilda-no-step-exclusions.txt")
    excluded_skus = load_exclusions(exclusion_file)
    # Normalize legacy URL-keyed files immediately so future runs are SKU-stable.
    rewrite_exclusions(exclusion_file, excluded_skus)

    if not args.dry_run:
        configure_error_log(error_log)
        args.vendor.mkdir(parents=True, exist_ok=True)
        args.inventor.mkdir(parents=True, exist_ok=True)

    stats = {
        "http_requests": 0,
        "page_errors": 0,
        "download_errors": 0,
        "cloudflare_blocks": 0,
        "category_pages_scanned": 0,
        "product_pages_found": 0,
        "products_discovered": 0,
        "product_without_sku": 0,
        "bundles_ignored": 0,
        "products_without_step": 0,
        "no_step_exclusions_skipped": 0,
        "sku_url_changes": 0,
        "step_404s": 0,
        "fallback_step_links_found": 0,
        "nested_zip_archives": 0,
        "nested_zips_without_step": 0,
        "container_archives": 0,
        "native_archives": 0,
        "native_files_new": 0,
        "native_files_identical": 0,
        "existing_sku_skipped": 0,
        "step_links_to_download": 0,
        "downloads_completed": 0,
        "dry_run_downloads": 0,
        "zip_without_step": 0,
        "step_files_new": 0,
        "step_files_identical": 0,
        "vendor_folders_created": 0,
        "inventor_folders_created": 0,
    }

    client = RateLimitedSession(args.delay, args.jitter, args.timeout, args.cf_retries, args.cf_backoff)

    console.print("[bold]SOMA goBILDA CAD sync - SKU mode[/]")
    console.print("Roots: " + ", ".join(ROOTS[k][1] for k in selected_roots))
    console.print(f"Vendor:   {args.vendor}")
    console.print(f"Inventor: {args.inventor}")
    console.print(f"Polite crawl: {args.delay:.2f}s + 0-{args.jitter:.2f}s jitter between requests")
    console.print("Resume policy: [bold]none[/] - existing Vendor STEP SKU or SKU-named native-CAD folder = skip")
    console.print(f"Error/audit log: {error_log}")
    console.print(f"No-STEP SKU exclusions: {exclusion_file} ({len(excluded_skus):,} SKU exclusions loaded)")
    if args.dry_run:
        console.print("[yellow]Dry run: no files or folders will be written.[/]")

    try:
        products, cache = discover_catalogue(client, selected_roots, args.max_pages, stats)
        jobs = scan_product_steps(client, products, cache, args.vendor, args.inventor, stats, args.dry_run, excluded_skus)
        sku_dirs = {ref.sku: ref.logical_dir for ref in products.values() if ref.sku}
        download_steps(client, jobs, args.vendor, args.inventor, stats, args.dry_run, excluded_skus, exclusion_file, sku_dirs)
        mirror_vendor_folders(args.vendor, args.inventor, stats, args.dry_run)
        missing, vendor_index = compare_inventor(args.vendor, args.inventor, stats)
        print_stats(stats, args.vendor, args.inventor, missing, vendor_index)
    except KeyboardInterrupt:
        console.print("\n[yellow]Interrupted. Nothing to resume: rerun it and existing Vendor SKUs will be skipped.[/]")
        return 130

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY
