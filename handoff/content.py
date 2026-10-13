"""
content.py — the single source of truth for what she's being asked to make.

The PDF and the video are both generated from this file, so they cannot drift apart. Change a
count or a character here and both deliverables follow.

Two lists:

  **What to letter** — the character set from `font_character_set.md`, with its three tiers
  expressed as amounts a person can act on rather than exact numbers. She is drawing roughly
  1,320 glyphs; "twenty" and "eight" and "three" are targets, not a contract.

  **What to record** — the test footage the pipeline has never been run against. Everything so
  far has run on fixtures written to match the same assumptions the code makes, which is a
  blind spot by construction.
"""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class Group:
    """One row of the lettering list."""
    title: str
    glyphs: str
    note: str = ""


@dataclass
class Tier:
    amount: str             # what to write, in her terms
    target: str             # the number behind it, for anyone who wants it
    blurb: str
    groups: list[Group] = field(default_factory=list)


# --------------------------------------------------------------------------------------
# What to letter
# --------------------------------------------------------------------------------------

TIERS: list[Tier] = [
    Tier(
        amount="As many as you can stand",
        target="aim for twenty each",
        blurb="These carry the whole thing. Twenty versions means a letter can appear twenty "
              "times before it repeats itself — which is the difference between handwriting "
              "and a font.",
        groups=[
            Group("Digits", "0 1 2 3 4 5 6 7 8 9",
                  "Highest priority of the lot. A recipe is full of 350°F, 100%, 2:00, 1100 — "
                  "repeated digits sitting side by side, where a repeat shows most."),
            Group("The common lowercase", "e t a o i n s r h l d c u m"),
            Group("The common uppercase", "A C D E F G H I M N O P R S T W"),
        ],
    ),
    Tier(
        amount="A sheet's worth",
        target="about eight each",
        blurb="Common enough to repeat in a sentence, rare enough that eight covers it.",
        groups=[
            Group("The rest of the lowercase", "b f g j k p q v w x y z"),
            Group("The rest of the uppercase", "B J K L Q U V X Y Z"),
            Group("Everyday punctuation", ". , ' \" ! ? : ; -"),
            Group("Tick and cross", "✓ ✗",
                  "Drawn as letters so they sit on the line with the text. Used constantly in "
                  "the this-works / this-doesn't comparisons."),
        ],
    ),
    Tier(
        amount="Just a couple",
        target="three each is plenty",
        blurb="Rare enough that three will never show a repeat. Don't labour these.",
        groups=[
            Group("Brackets and dashes", "( ) [ ] / – — … & % + = < > * # @ $",
                  "The – is an en dash for ranges (75–80°F). The — is an em dash. Both differ "
                  "from the hyphen."),
            Group("Measurement", "° ℃ ℉ ± × ÷ ~ ≈ ≤ ≥ ′ ″ −",
                  "× is a multiplication sign, not the letter x — 2 × 4 should never be "
                  "lettered with an x. The − is a true minus, drawn longer than a hyphen: in "
                  "−20°C a hyphen reads as a typo."),
            Group("Fractions", "½ ⅓ ⅔ ¼ ¾ ⅛ ⅜ ⅝ ⅞", "Baking runs on these."),
            Group("Chemistry", "₀ ₁ ₂ ₃ ₄ ₅ ₆ ₇ ₈ ₉   ⁰ ¹ ² ³ ⁴ ⁵ ⁶ ⁷ ⁸ ⁹ ⁺ ⁻",
                  "Subscripts and superscripts. Without them every formula — C₆H₁₂O₆, CO₂ — "
                  "falls back to another font mid-word, and it is instantly visible."),
            Group("Arrows", "→ ← ↔ ⇌ ↑ ↓ ⟶",
                  "⇌ is the important one. Fermentation and enzyme reactions are equilibria; "
                  "a one-way → where a ⇌ belongs is a factual error, not a typographic one."),
            Group("Greek", "α β Δ μ λ π", "α and β for glucose anomers, Δ for change, μ for micro."),
            Group("Accents", "é è ê à â ç ñ ü ö", "sauté, purée, pâte, crème, jalapeño."),
        ],
    ),
]

# The single most useful shortcut available, so it is said before the list rather than after.
CAPS_ONLY_NOTE = (
    "If you letter in capitals — and most block lettering is — then do all 26 capitals at "
    "twenty each and skip the lowercase tiers entirely. That is a third of the work for the "
    "same result."
)

LETTERING_RULES = [
    ("One marker, one sitting, per character",
     "Twenty e's drawn across three days in three moods read as three different fonts. "
     "Twenty drawn in a row read as one hand."),
    ("Leave the mess in",
     "The bleed, the skips where the marker lifted, the wobble — those are the parts that "
     "make it yours. Tidying them defeats the whole exercise."),
    ("Scan at 1200 dpi, untouched",
     "No threshold, no cleanup, no sharpening. Send the file exactly as the scanner made it."),
]


# --------------------------------------------------------------------------------------
# What to record
# --------------------------------------------------------------------------------------

@dataclass
class Recording:
    title: str
    length: str
    why: str
    steps: list[str] = field(default_factory=list)


RECORDINGS: list[Recording] = [
    Recording(
        title="Two minutes of you talking",
        length="2 minutes",
        why="Nothing in this pipeline has ever met real speech. It has been tested entirely "
            "against synthetic audio I wrote to match my own assumptions, which finds nothing.",
        steps=[
            "Shoot it at 24p. Not 30 — the whole timeline runs at 24 and 30 would make every "
            "graphic land at the wrong moment.",
            "Real location, real microphone, the way you'd actually shoot.",
            "Talk about anything. Yeast, the weather, what you had for lunch.",
            "Leave your natural pauses in. Don't perform tightly.",
            "Fluff two or three lines on purpose — start a sentence, stop, and say it again. "
            "That's the thing I most need to see it handle.",
            "Don't edit it. Send the original file.",
        ],
    ),
    Recording(
        title="One minute of room tone",
        length="60 seconds",
        why="Silence under every cut. Digital silence between sentences is the loudest tell "
            "that a machine made the edit, so real room tone runs underneath.",
        steps=[
            "Same room, same mic, same settings, immediately after the talking.",
            "Nobody speaks. Don't move. Just let it run.",
            "Once per location — if you shoot in the kitchen and at the table, that's two.",
        ],
    ),
    Recording(
        title="The grey card, on each camera",
        length="10 minutes",
        why="The T3i is a 2011 body and is visibly greener and flatter than the R100 and RP. "
            "One correction across all three would make cuts between cameras read as a mistake.",
        steps=[
            "Same scene, same light, same white balance — only the camera changes.",
            "Grey card and colour checker filling a good part of the frame.",
            "A few seconds on each of the three bodies: T3i, R100, RP.",
            "Label which is which, or shoot them in that order and tell me.",
        ],
    ),
]

CLOSING = (
    "Send everything however's easiest. Originals, not screenshots, and nothing that "
    "re-compresses on the way."
)


# --------------------------------------------------------------------------------------
# Narration — the video script, timed by the words themselves
# --------------------------------------------------------------------------------------

@dataclass
class Scene:
    kicker: str
    headline: str
    lines: list[str] = field(default_factory=list)
    glyphs: str = ""            # a character strip to animate in
    accent: str = "rust"
    say: str = ""


SCENES: list[Scene] = [
    Scene(kicker="", headline="Two lists", accent="sage",
          lines=["What to letter.", "What to film."],
          say="Two lists. What to letter, and what to film."),

    Scene(kicker="The lettering", headline="Start with\nthe digits", accent="rust",
          glyphs="0123456789",
          lines=["As many versions as you can stand.", "Twenty is the target."],
          say="Start with the digits, and do as many versions of each as you can stand. "
              "Twenty is the target."),

    Scene(kicker="The lettering", headline="Why digits\nfirst", accent="rust",
          glyphs="350°F  100%  2:00",
          lines=["Three fifty. A hundred percent.", "Repeated digits, side by side —",
                 "where a repeat shows most."],
          say="Recipes are full of numbers with repeated digits sitting right next to each "
              "other. That's where a repeat shows most."),

    Scene(kicker="The lettering", headline="Then the\ncommon letters", accent="rust",
          glyphs="etaoinsrhldcum",
          lines=["Twenty each, same as the digits."],
          say="Then the common letters — e, t, a, o, i, n and the rest. Twenty each, "
              "same as the digits."),

    Scene(kicker="Shortcut", headline="Caps only?", accent="sage",
          lines=["Do all twenty-six capitals at twenty.", "Skip lowercase entirely.",
                 "A third of the work."],
          say="And if you letter in capitals, just do all twenty six capitals at twenty and "
              "skip lowercase completely. That's a third of the work."),

    Scene(kicker="The lettering", headline="A sheet each", accent="rust",
          glyphs="bfgjkpqvwxyz . , ' ? ! ✓ ✗",
          lines=["The rest of the alphabet,", "everyday punctuation, tick and cross.",
                 "About eight versions each."],
          say="The rest of the alphabet, the everyday punctuation, and a tick and a cross. "
              "About eight versions of each."),

    Scene(kicker="The lettering", headline="Then a couple\nof everything else", accent="rust",
          glyphs="½ ¾ ° × − ⇌ → α Δ é ñ ₂ ⁴",
          lines=["Fractions, degrees, arrows,", "chemistry, accents.",
                 "Three each is plenty."],
          say="Then just a couple of everything else. Fractions, degrees, arrows, the "
              "chemistry subscripts, accents. Three each is plenty."),

    Scene(kicker="Don't skip", headline="⇌", accent="rust",
          lines=["Fermentation is an equilibrium.", "A one-way arrow where this belongs",
                 "is a factual error, not a typo."],
          say="Don't skip the double arrow. Fermentation is an equilibrium, and a one way "
              "arrow where that belongs is a factual error, not a typo."),

    Scene(kicker="The lettering", headline="One marker,\none sitting", accent="rust",
          lines=["Per character.", "And leave the mess in —",
                 "the bleed and the skips are the point."],
          say="One marker, one sitting, per character. And leave the mess in. The bleed and "
              "the skips are the point."),

    Scene(kicker="The filming", headline="Two minutes\nof you talking", accent="moss",
          lines=["Shot at twenty-four p. Not thirty.", "Real room, real mic.",
                 "Fluff a few lines on purpose."],
          say="Now the filming. Two minutes of you talking, shot at twenty four p — not "
              "thirty. Real room, real mic. And fluff a few lines on purpose."),

    Scene(kicker="The filming", headline="One minute\nof silence", accent="moss",
          lines=["Same room, same mic, nobody speaks.", "It runs under every cut."],
          say="Then one minute of room tone. Same room, same mic, nobody talking. That runs "
              "underneath every cut."),

    Scene(kicker="The filming", headline="Grey card,\nall three cameras", accent="moss",
          lines=["Same light, same scene.", "T3i, R100, RP.",
                 "A few seconds each."],
          say="And the grey card on all three cameras, same light, same scene. A few seconds "
              "on each."),

    Scene(kicker="", headline="That's it.", accent="sage",
          lines=["Originals, not screenshots.", "Send them whenever."],
          say="That's it. Originals, not screenshots. Send them over whenever you have them."),
]
