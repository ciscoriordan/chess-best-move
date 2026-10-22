#!/usr/bin/env python3
"""Regenerate the Watch's circular composition from the existing iPhone icon artwork."""

import copy
import json
from pathlib import Path
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "App/Resources/AppIcon.icon"
DESTINATION = ROOT / "WatchApp/Resources/AppIcon.icon"
SVG = "http://www.w3.org/2000/svg"
ET.register_namespace("", SVG)


def main():
    assets = DESTINATION / "Assets"
    assets.mkdir(parents=True, exist_ok=True)
    document = json.loads((SOURCE / "icon.json").read_text())
    # No exposed iPhone blue background around the Watch's larger circular canvas.
    document["fill"] = {"solid": "srgb:0.23137,0.22353,0.20784,1.00000"}
    document["supported-platforms"] = {"circles": ["watchOS"]}
    for group in document["groups"]:
        group["shadow"] = {"kind": "none", "opacity": 0.5}
    (DESTINATION / "icon.json").write_text(json.dumps(document, indent=2) + "\n")

    board = ET.parse(SOURCE / "Assets/board.svg").getroot()
    colors = [element.attrib["fill"] for element in board if element.tag == f"{{{SVG}}}rect"]
    # Watch uses a 1088-pixel canvas. Extend the board all the way to its circular mask.
    board = ET.Element(f"{{{SVG}}}svg", width="1088", height="1088", viewBox="0 0 1088 1088")
    for row in range(3):
        for column in range(3):
            ET.SubElement(board, f"{{{SVG}}}rect", x=f"{column * 1088 / 3:.6f}",
                          y=f"{row * 1088 / 3:.6f}", width="362.666667", height="362.666667",
                          fill=colors[(row + column) % 2])
    ET.ElementTree(board).write(assets / "board.svg", encoding="unicode", xml_declaration=True)

    source_arrow = ET.parse(SOURCE / "Assets/arrow.svg").getroot()
    arrow = ET.Element(f"{{{SVG}}}svg", width="1088", height="1088", viewBox="0 0 1088 1088")
    # Keep the entire L inside the circular safe area, optically centered on both axes.
    group = ET.SubElement(arrow, f"{{{SVG}}}g", transform="translate(283.5 143) scale(0.82)")
    for path in source_arrow:
        group.append(copy.deepcopy(path))
    ET.ElementTree(arrow).write(assets / "arrow.svg", encoding="unicode", xml_declaration=True)
    print("Generated Watch icon with a full-bleed board and centered move arrow")


if __name__ == "__main__":
    main()
