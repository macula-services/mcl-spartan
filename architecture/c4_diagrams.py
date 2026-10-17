"""Generate mcl-spartan's C4 diagrams: assets/c4-context.svg, assets/c4-containers.svg
and assets/c4-components.svg.

Run:  python3 architecture/c4_diagrams.py

The style block is the house one (mcl-fovea's): plain classes with literal
colours and a prefers-color-scheme: dark block, and no CSS custom properties,
because rsvg-convert renders those black. After a change, render each one
(rsvg-convert -w 1400 assets/c4-context.svg -o /tmp/c.png) and look at it;
keep architecture/README.md's tables in step.
"""
import os
from xml.sax.saxutils import escape

ASSETS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets")

SANS = '"Atkinson Hyperlegible", "Segoe UI", system-ui, -apple-system, Helvetica, Arial, sans-serif'
MONO = '"JetBrains Mono", ui-monospace, Menlo, Consolas, monospace'

STYLE = f"""<style>
.t-name {{ font-family: {SANS}; font-size: 15px; font-weight: 700; }}
.t-desc {{ font-family: {SANS}; font-size: 12.5px; }}
.t-rel {{ font-family: {SANS}; font-size: 11.5px; paint-order: stroke; stroke-width: 4px; stroke-linejoin: round; }}
.t-code {{ font-family: {MONO}; font-size: 13px; font-weight: 600; }}
.t-small {{ font-size: 12px; }}
.t-type {{ font-family: {MONO}; font-size: 11.5px; }}
.t-bound {{ font-family: {MONO}; font-size: 12px; font-weight: 600; }}
.edge {{ fill: none; stroke-width: 1.25; }}
.edge-later {{ fill: none; stroke-width: 1.25; stroke-dasharray: 5 4; }}
.bg {{ fill: #FFFFFF; }}
.b-sys {{ fill: #F5E9CC; stroke: #A56F0A; stroke-width: 2; }}
.b-ext {{ fill: #ECEFED; stroke: #8A9791; stroke-width: 1.25; }}
.b-per {{ fill: #E3EBF2; stroke: #3B5B7A; stroke-width: 1.25; }}
.b-cmp {{ fill: #FFFFFF; stroke: #8A9791; stroke-width: 1.25; }}
.b-later {{ fill: none; stroke: #8A9791; stroke-width: 1.25; stroke-dasharray: 5 4; }}
.bound {{ fill: none; stroke: #66736E; stroke-width: 1.25; stroke-dasharray: 7 5; }}
.bound-in {{ fill: none; stroke: #D9DFDC; stroke-width: 1.5; stroke-dasharray: 4 4; }}
.head {{ fill: #3B5B7A; }}
.t-name {{ fill: #16201D; }}
.t-code {{ fill: #16201D; }}
.t-type {{ fill: #66736E; }}
.t-desc {{ fill: #34413C; }}
.t-bound {{ fill: #66736E; }}
.t-rel {{ fill: #66736E; stroke: #FFFFFF; }}
.edge, .edge-later {{ stroke: #8A9791; }}
.arrowhead {{ fill: #8A9791; }}
@media (prefers-color-scheme: dark) {{
.bg {{ fill: #171F1C; }}
.b-sys {{ fill: #3A2E13; stroke: #E3AA3C; stroke-width: 2; }}
.b-ext {{ fill: #1C2421; stroke: #7D8B85; stroke-width: 1.25; }}
.b-per {{ fill: #1D2A36; stroke: #8EB4D8; stroke-width: 1.25; }}
.b-cmp {{ fill: #171F1C; stroke: #7D8B85; stroke-width: 1.25; }}
.b-later {{ fill: none; stroke: #7D8B85; stroke-width: 1.25; stroke-dasharray: 5 4; }}
.bound {{ fill: none; stroke: #93A09A; stroke-width: 1.25; stroke-dasharray: 7 5; }}
.bound-in {{ fill: none; stroke: #2A3431; stroke-width: 1.5; stroke-dasharray: 4 4; }}
.head {{ fill: #8EB4D8; }}
.t-name {{ fill: #E6ECE9; }}
.t-code {{ fill: #E6ECE9; }}
.t-type {{ fill: #93A09A; }}
.t-desc {{ fill: #C3CDC8; }}
.t-bound {{ fill: #93A09A; }}
.t-rel {{ fill: #93A09A; stroke: #171F1C; }}
.edge, .edge-later {{ stroke: #7D8B85; }}
.arrowhead {{ fill: #7D8B85; }}
}}
</style>"""

DEFS = ('<defs><marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" '
        'markerHeight="7" orient="auto-start-reverse"><path class="arrowhead" '
        'd="M0 0L10 5L0 10z"/></marker></defs>')


class Svg:
    def __init__(self, w, h, label):
        self.w, self.h, self.label = w, h, label
        self.parts = []

    def text(self, cls, x, y, s, anchor=None, rotate=None):
        a = f' text-anchor="{anchor}"' if anchor else ""
        r = f' transform="rotate({rotate} {x} {y})"' if rotate is not None else ""
        self.parts.append(f'<text class="{cls}" x="{x}" y="{y}"{a}{r}>{escape(s)}</text>')

    def rect(self, cls, x, y, w, h, rx=10):
        self.parts.append(f'<rect class="{cls}" x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}"/>')

    def element(self, cls, x, y, w, h, name, kind, desc, person=False):
        """A context or container element: name, [kind], description lines."""
        self.rect(cls, x, y, w, h)
        tx = x + 16
        if person:
            self.parts.append(f'<circle class="head" cx="{x + 26}" cy="{y + 24}" r="9"/>')
            tx = x + 44
        self.text("t-name", tx, y + 28, name)
        self.text("t-type", tx, y + 46, kind)
        for i, line in enumerate(desc):
            self.text("t-desc", x + 16, y + 70 + 16 * i, line)

    def component(self, cls, x, y, w, h, name, kind, desc, small=False):
        """A component: code name, [kind] right-aligned (or below when small)."""
        self.rect(cls, x, y, w, h, rx=8)
        self.text("t-code t-small" if small else "t-code", x + 14, y + 24, name)
        if small:
            self.text("t-type", x + 14, y + 42, kind)
            y0 = y + 62
        else:
            self.text("t-type", x + w - 12, y + 24, kind, anchor="end")
            y0 = y + 46
        for i, line in enumerate(desc):
            self.text("t-desc", x + 14, y0 + 16 * i, line)

    def row(self, cls, x, y, w, name, desc):
        """A one-line desk: name on the left, what it does on the right."""
        self.rect(cls, x, y, w, 34, rx=8)
        self.text("t-code t-small", x + 12, y + 22, name)
        self.text("t-desc", x + w - 12, y + 22, desc, anchor="end")

    def bound(self, cls, x, y, w, h, label):
        self.rect(cls, x, y, w, h, rx=12 if cls == "bound" else 10)
        self.text("t-bound", x + 16, y + 22, label)

    def edge(self, d, later=False):
        c = "edge-later" if later else "edge"
        self.parts.append(f'<path class="{c}" d="{d}" marker-end="url(#a)"/>')

    def write(self, name):
        head = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {self.w} {self.h}" role="img" '
                f'aria-label="{escape(self.label)}">',
                f"<title>{escape(self.label)}</title>", STYLE, DEFS,
                f'<rect class="bg" x="0" y="0" width="{self.w}" height="{self.h}"/>', ""]
        with open(os.path.join(ASSETS, name), "w") as f:
            f.write("\n".join(head + self.parts + ["</svg>", ""]))


# Level 1: system context
# ---------------------------------------------------------------------------
def context():
    s = Svg(1000, 600, "mcl-spartan system context")

    # Edges first, so boxes and labels sit on top.
    s.edge("M300 150H400V205")                 # the wire -> mcl-spartan
    s.edge("M650 240H668V110H690")             # mcl-spartan -> the square
    s.edge("M650 270H690")                     # mcl-spartan -> the endpoint
    s.edge("M470 345V430")                     # mcl-spartan -> station
    s.edge("M570 345V430")                     # mcl-spartan -> realm

    s.element("b-ext", 30, 90, 270, 120, "The wire", "[External: mcl-news's topic]",
              ["<realm>/mcl-news/news/wire/", "news_item_reported_v1. A sensor on",
               "another box reports every item", "it has not reported before."])
    s.element("b-ext", 690, 60, 280, 128, "The square", "[External: the speakers' topic]",
              ["<realm>/mcl-spartan/agora/wire/", "agora_post_published_v1, where a",
               "post lands. It carries this org's", "name, so speaking needs no grant."])
    s.element("b-sys", 400, 200, 250, 145, "mcl-spartan", "[Software system, mcl_om service]",
              ["The Spartan Mind: hears the", "wire, reasons once about one",
               "story, and posts what it made", "of it to the square."])
    s.element("b-ext", 690, 205, 280, 112, "Inference endpoints", "[External: OpenAI-compatible pool]",
              ["One HTTPS call per turn, walked", "slot by slot until a provider",
               "answers. All deployment data."])
    s.element("b-ext", 290, 430, 250, 110, "macula-station", "[External system]",
              ["Pinned seed(s); carries every", "fact and call to and from",
               "this node (QUIC, pq_hybrid)."])
    s.element("b-ext", 560, 430, 240, 110, "macula-realm", "[External system]",
              ["Boot identity claim; the realm", "key is the trust anchor every",
               "org-namespaced fact resolves by."])

    s.text("t-rel", 320, 142, "subscribes", anchor="middle")
    s.text("t-rel", 652, 184, "publishes one post", anchor="end")
    s.text("t-rel", 680, 264, "one call per story", anchor="end")
    s.text("t-rel", 462, 392, "dials out, pinned", anchor="end")
    s.text("t-rel", 578, 392, "claims its identity", anchor="start")
    s.text("t-rel", 20, 566, "W1b: one mind, one post per story.")
    s.text("t-rel", 20, 584, "W2 cross-checks the card, W3 (this release) pools the providers, W4 adds replies, W5 more desks: not drawn.")
    s.write("c4-context.svg")


# ---------------------------------------------------------------------------
# Level 2: containers
# ---------------------------------------------------------------------------
def containers():
    s = Svg(1000, 620, "mcl-spartan containers")

    s.bound("bound", 230, 40, 540, 520, "a fleet box [docker, host networking, /bulk0 mounted]")
    s.bound("bound-in", 246, 72, 508, 460, "mcl-spartan [Software system, mcl_om service]")

    # Edges
    s.edge("M200 140H280")                     # the wire
    s.edge("M200 250H280")                     # the endpoint
    s.edge("M730 140H800")                     # the square
    s.edge("M730 250H800")                     # station
    s.edge("M730 350H800")                     # realm
    s.edge("M400 300V355")                     # the ledger
    s.edge("M620 300V355")                     # identity key

    s.element("b-sys", 280, 100, 450, 200, "mcl-spartan service",
              "[Container: OCI image, OTP 28.4.3 release, mcl_om 1.0]",
              ["One supervised mind (spartan_mind) and one subscriber on mcl-news's fact",
               "topic (subscriptions/0). No procedure is offered and no store is opened:",
               "from mcl-om come node identity, the pinned station dial, the realm claim",
               "and /health on a Unix socket. Everything else this container does is one",
               "HTTPS call per story, to a pool of providers, and one small file."])

    s.element("b-cmp", 280, 355, 240, 148, "Daily ledger", "[bind mount: /data]",
              ["/bulk0/mcl-spartan on a node.", "mind_budget.term under MCL_DATA_DIR:",
               "the day's token spend, written", "each turn, so the cap survives a", "recreate."])
    s.element("b-cmp", 540, 355, 190, 148, "Identity key", "[mcl-spartan-secrets]",
              ["/etc/mcl/secrets:", "identity.key, the node id", "every post is",
               "attributable to."])

    s.element("b-ext", 10, 100, 190, 80, "The wire", "[mcl-news's topic]",
              ["news_item_reported_v1"])
    s.element("b-ext", 10, 210, 190, 80, "Inference pool", "[OpenAI-compatible]",
              ["one call per story"])
    s.element("b-ext", 800, 100, 190, 80, "The square", "[this org's topic]",
              ["agora_post_published_v1"])
    s.element("b-ext", 800, 210, 190, 76, "macula-station", "[pinned seed(s)]", [])
    s.element("b-ext", 800, 310, 190, 76, "macula-realm", "[trust anchor]", [])

    s.text("t-rel", 240, 132, "subscribe", anchor="middle")
    s.text("t-rel", 240, 242, "one call", anchor="middle")
    s.text("t-rel", 765, 132, "publish", anchor="middle")
    s.text("t-rel", 765, 222, "dials", anchor="middle")
    s.text("t-rel", 765, 322, "claims", anchor="middle")
    s.text("t-rel", 390, 330, "spends, rolls daily")
    s.text("t-rel", 600, 330, "loads")
    s.text("t-rel", 20, 592, "all over the mesh, via the station")
    s.write("c4-containers.svg")


# ---------------------------------------------------------------------------
# Level 3: components of the service
def components():
    s = Svg(1000, 700, "mcl-spartan components")

    # Edges first, so boxes and labels sit on top.
    s.edge("M560 110H470")                     # the wire -> the subscriber
    s.edge("M265 190V212")                     # the subscriber -> the mind
    s.edge("M470 280H560")                     # the mind -> the endpoint
    s.edge("M265 390V412")                     # the mind -> the writer
    s.edge("M470 490H560")                     # the writer -> the square
    s.edge("M760 510V540")                     # the square -> the keeper

    s.element("b-cmp", 60, 60, 410, 130, "hear_the_wire", "[macula_subscriber]",
              ["on_news_item_reported_maybe_open_a_turn decides almost nothing:",
               "is the payload a map at all, and what did the mind say back.",
               "It reads no field of the item, so a new field on the wire",
               "needs no change here. It counts what was offered and refused."])
    s.element("b-cmp", 60, 212, 410, 178, "inhabit_mind", "[the mind: one charter]",
              ["spartan_mind sits idle until a fact arrives and takes at most ONE",
               "turn about it. The gates, cheapest first: no item_id refuses, an",
               "item already opened is a duplicate, a story inside the opening",
               "clock is counted and DROPPED, a spent day makes it rest. The item",
               "is marked taken before the call and the clock starts there too.",
               "mind_llm walks the provider pool, mind_breaker rests a backend",
               "that refused, mind_budget keeps the day's spend."])
    s.element("b-cmp", 60, 412, 410, 158, "publish_to_agora", "[the square's only writer]",
              ["maybe_publish_to_agora publishes, or explains why there is nothing",
               "to publish: a mind with nothing to say spends no id. agora_stimulus",
               "copies the item out of the fact the mind was handed, tagged as the",
               "sensor sent it, so no model can claim what the post was about.",
               "agora_post_published_v1 is the shape the keeper reads."])

    s.element("b-ext", 560, 60, 400, 100, "The wire", "[mcl-news's topic]",
              ["news_item_reported_v1. This service never",
               "publishes here and has no grant over it."])
    s.element("b-ext", 560, 200, 400, 100, "Inference endpoints", "[an OpenAI-compatible pool]",
              ["One HTTPS POST per turn, walked slot by slot, and a",
               "fallback floor appended after the whole pool."])
    s.element("b-ext", 560, 410, 400, 100, "The square", "[this org's topic]",
              ["agora_post_published_v1. The topic carries this",
               "org's name, so speaking here needs no grant."])
    s.element("b-ext", 560, 540, 400, 100, "mcl-agora", "[the keeper, another service]",
              ["Subscribes to the square, records every post,",
               "and serves the record back as get_posts_page."])

    s.text("t-rel", 515, 102, "a fact", anchor="middle")
    s.text("t-rel", 273, 206, "think/1, one item")
    s.text("t-rel", 515, 272, "one call, capped", anchor="middle")
    s.text("t-rel", 273, 406, "what it said")
    s.text("t-rel", 515, 482, "the post", anchor="middle")
    s.text("t-rel", 768, 532, "records it", anchor="middle")
    s.text("t-rel", 20, 668, "W1b: one mind, one post per story, no replies and no tools.")
    s.text("t-rel", 20, 686, "W3 (this release) pools the providers and remembers which refused; W4 the thread work, W5 the roster that turns one charter into many: not drawn.")
    s.write("c4-components.svg")

if __name__ == "__main__":
    os.makedirs(ASSETS, exist_ok=True)
    context()
    containers()
    components()
