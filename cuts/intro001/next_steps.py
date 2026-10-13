"""
next_steps.py — what to do with the footage that now exists.

The scene list for the second vertical handoff video. `handoff/content.py` was what to make
before there was any footage; this is what the twelve-minute cut is asking for. Rendered by
`handoff/build_video.py --content` — same renderer, same voice, different script.

The order is the order to work in, and it is not the order of importance: the inserts come
first because they are the only item that unblocks nothing else and yet fixes the biggest
problem, and because a shoot day is easier to schedule than a chemistry review.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "handoff"))

from content import Scene  # noqa: E402  the dataclass the renderer expects


SCENES: list[Scene] = [
    Scene(kicker="", headline="The cut\nexists", accent="sage",
          lines=["Twelve minutes, twenty-three seconds.", "Cut, scored, and read back."],
          say="Good news first. There's a twelve minute cut, it's scored, and I've listened back to every word it says."),

    Scene(kicker="The one big problem", headline="Nothing to\nlook at", accent="rust",
          lines=["Twelve minutes.", "One woman, one table.", "Zero cutaways."],
          say="Here's the problem. Twelve minutes of one person at one table, and not a single cutaway. That's the job now."),

    Scene(kicker="Shoot first", headline="The five jars", accent="rust",
          glyphs="mead · instant · dry · fresh",
          lines=["You hold up five. We can read none.", "Same table, same light."],
          say="Shoot this first. She picks up five jars and the camera can't read one label. Get a close up of each, same table, same light."),

    Scene(kicker="Shoot first", headline="The bubbling\njar", accent="rust",
          lines=["The first line of the video", "promises it out loud."],
          say="Then the bubbling jar. The first line of the video says, this is yeast bubbling in action. Right now you can't see any."),

    Scene(kicker="Shoot first", headline="Two doughs", accent="rust",
          lines=["One plain. One with fat and salt.", "Same clock, side by side."],
          say="Then two doughs proofing side by side. One plain, one with fat and salt, same clock. That shot proves what she spends two minutes explaining."),

    Scene(kicker="Shoot first", headline="Stretchy\nversus short", accent="rust",
          lines=["Windowpane both.", "Cut both loaves.", "Show the failure, then the fix."],
          say="Same trick for the gluten. Windowpane both, cut both loaves. Show the failure, then the fix."),

    Scene(kicker="Say again", headline="The chemistry", accent="rust",
          glyphs="starch → sucrose → CO₂",
          lines=["Her notes were not finished.", "She says so, on camera."],
          say="One thing has to be recorded again. The enzyme section. She says on tape her notes aren't complete enough, and it shows. Don't patch that in the edit."),

    Scene(kicker="Say again", headline="Four short\npickups", accent="rust",
          lines=["A hook that names a mistake.", "An outro with one next step.",
                 "Two lines she trailed off on."],
          say="Four short pickups with it. A hook that names a mistake. An outro, because there isn't one. And two lines she trailed off on."),

    Scene(kicker="Katie", headline="Eight claims\nto check", accent="sage",
          glyphs="1838   90%   54°F   140°F",
          lines=["A name, a date, three numbers,", "and one mechanism."],
          say="Katie, eight things need your eyes. The name and date for Meyen. The ninety percent. The three temperatures. The glutathione. Once a number is a graphic, it's a claim."),

    Scene(kicker="Scan", headline="One blank\nsheet", accent="sage",
          lines=["Twelve hundred dpi. Untouched.", "Nothing renders without it."],
          say="Two scans unblock everything else. One blank sheet of your paper at twelve hundred dpi. Every graphic is built on that grain."),

    Scene(kicker="Scan", headline="The lettering", accent="sage",
          glyphs="0123456789",
          lines=["Digits first. Twenty each.", "Then the common letters."],
          say="Then the lettering. Digits first, twenty versions of each. That hasn't changed, and it's still the long pole."),

    Scene(kicker="Record", headline="Thirty minutes\nof table", accent="sage",
          glyphs="tap · slide · squeak",
          lines=["Cardboard taps. Paper slides.", "Every graphic gets a sound."],
          say="Then thirty minutes of table sounds. Taps, slides, squeaks. Every graphic gets one, and it's the cheapest thing on this list."),

    Scene(kicker="One technical thing", headline="Shoot at\ntwenty-four", accent="rust",
          lines=["The intro was shot at thirty.", "It is the only clip that was."],
          say="One technical note. The intro was shot at thirty frames and everything else is twenty four. It's fourteen seconds, so just shoot it again."),

    Scene(kicker="", headline="In that order", accent="sage",
          lines=["Shoot the inserts.", "Re-record the chemistry.", "Scan the paper."],
          say="So. Shoot the inserts, re-record the chemistry, scan the paper. In that order. Everything else can wait."),
]
