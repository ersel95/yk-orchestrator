#!/usr/bin/env python3
"""appcast.xml içine yeni release item'ı ekle/güncelle (Sparkle update feed).

CI release job DMG'yi Sparkle'ın `sign_update` (EdDSA) ile imzalar, sonra bunu
çağırıp `SUFeedURL`'nin gösterdiği feed'e yeni sürümü ekler. Aynı sürüm için
yeniden çalışırsa eski item'ı düşürür → idempotent.

Usage:
  update_appcast.py --version 0.2.0 \\
    --url https://github.com/ersel95/yk-orchestrator/releases/download/v0.2.0/YKOrchestrator-0.2.0.dmg \\
    --length 109051904 --signature 'BASE64==' [--notes-url URL] [--min-system 13.0] \\
    [--appcast appcast.xml]
"""
import argparse
from datetime import datetime, timezone
from email.utils import format_datetime
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)


def sk(tag: str) -> str:
    return f"{{{SPARKLE_NS}}}{tag}"


def load_or_create(path: str):
    try:
        tree = ET.parse(path)
        root = tree.getroot()
        if root.find("channel") is None:
            ET.SubElement(root, "channel")
        return tree, root
    except (FileNotFoundError, ET.ParseError):
        root = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(root, "channel")
        ET.SubElement(channel, "title").text = "YK Orchestrator"
        ET.SubElement(channel, "link").text = "https://github.com/ersel95/yk-orchestrator"
        ET.SubElement(channel, "description").text = "YK Orchestrator updates"
        return ET.ElementTree(root), root


def build_item(args) -> ET.Element:
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"YK Orchestrator {args.version}"
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc))
    # sparkle:version → CFBundleVersion (build number, monotonik artan integer).
    # Sparkle'ın sürüm karşılaştırması bu alandadır.
    # sparkle:shortVersionString → kullanıcıya gösterilen marketing version.
    ET.SubElement(item, sk("version")).text = str(args.build)
    ET.SubElement(item, sk("shortVersionString")).text = args.version
    ET.SubElement(item, sk("minimumSystemVersion")).text = args.min_system
    if args.notes_url:
        ET.SubElement(item, sk("releaseNotesLink")).text = args.notes_url
    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", args.url)
    enclosure.set("length", str(args.length))
    enclosure.set("type", "application/octet-stream")
    enclosure.set(sk("edSignature"), args.signature)
    return item


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--version", required=True, help="Marketing version (örn 0.4.1)")
    p.add_argument("--build", required=True, type=int,
                   help="CFBundleVersion (monotonik artan integer — Sparkle bunu karşılaştırır)")
    p.add_argument("--url", required=True)
    p.add_argument("--length", required=True, type=int)
    p.add_argument("--signature", required=True)
    p.add_argument("--notes-url", default="")
    p.add_argument("--min-system", default="13.0")
    p.add_argument("--appcast", default="appcast.xml")
    args = p.parse_args()

    tree, root = load_or_create(args.appcast)
    channel = root.find("channel")

    # Aynı marketing version için var olan item'ı düş (idempotent re-run)
    for it in channel.findall("item"):
        if it.findtext(sk("shortVersionString")) == args.version:
            channel.remove(it)

    item = build_item(args)
    first_item = channel.find("item")
    if first_item is not None:
        channel.insert(list(channel).index(first_item), item)  # en yeni başta
    else:
        channel.append(item)

    ET.indent(tree, space="  ")
    tree.write(args.appcast, encoding="utf-8", xml_declaration=True)
    print(f"appcast.xml updated for {args.version}")


if __name__ == "__main__":
    main()
